//! M2, parse identity: two sources are the same program when their IR trees
//! agree modulo source positions and trivia (D3 section 4).
//!
//! This is the validator method for a rewrite that moves tokens without moving
//! structure. The semicolon a program relies on ASI to insert is the motivating
//! case: writing it makes the token stream longer and leaves the tree the
//! parser built exactly as it was, which is the unique-parse argument spec 5.5
//! makes, stated as something that runs.
//!
//! Three properties are load-bearing.
//!
//! It compares resolved values, never pool indices. A string literal is
//! compared as its text and an identifier as its atom, because a constant pool
//! is filled in parse order and two sources that differ anywhere before a
//! literal can give the same literal different indices. The atom table is
//! shared between the two parses on purpose: an atom id is then a function of
//! the name alone, so comparing ids is comparing names.
//!
//! The tag switch is exhaustive with no `else`. A new `NodeTag` fails the build
//! here rather than falling into a default arm that answers "identical" for a
//! construct nobody taught this file about. That answer is the one failure this
//! file must never produce: it would grade an arbitrary edit as an equivalence.
//!
//! A tag whose payload this file does not model answers `.unmodeled` rather
//! than `.identical`. Most of them name constructs the language refuses at
//! parse time - `try`, `while`, `switch`, `await`, a labeled statement - so
//! they cannot appear in a source that parsed; the rest are a bounded, named
//! list a caller can read rather than a silent gap.

const std = @import("std");
const engine = @import("zts-engine");

const parser_mod = engine.parser;
const source_frontend = engine.source_frontend;
const AtomTable = engine.atom_table.AtomTable;
const ir = parser_mod.ir;
const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const null_node = ir.null_node;
const ConstantPool = ir.ConstantPool;

/// Which of the two sources a side-specific answer is about.
pub const Side = enum { original, repaired };

pub const Verdict = union(enum) {
    /// The two trees agree everywhere this file compares.
    identical,
    /// They disagree, and the payload names where.
    differs: []const u8,
    /// A tag this file does not model was reached, so no answer was formed.
    unmodeled: NodeTag,
    /// One side did not strip or did not parse, so it has no tree.
    unparsable: Side,
};

pub const Options = struct {
    /// Recursion ceiling. The parser bounds its own descent at 512, so a tree
    /// it produced cannot exceed that; this exists so a malformed index cycle
    /// stops rather than smashes the stack.
    max_depth: u32 = 1024,
};

/// Compare two whole sources. `error.OutOfMemory` is the only failure: every
/// other outcome is a verdict, because "this did not parse" is an answer about
/// the input rather than a fault in the comparison.
pub fn compare(
    allocator: std.mem.Allocator,
    original: []const u8,
    repaired: []const u8,
    options: Options,
) error{OutOfMemory}!Verdict {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    var left = Parsed.init(allocator, original, &atoms, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoTree => return .{ .unparsable = .original },
    };
    defer left.deinit();

    var right = Parsed.init(allocator, repaired, &atoms, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoTree => return .{ .unparsable = .repaired },
    };
    defer right.deinit();

    var cmp = Comparer{
        .left = left.view(),
        .right = right.view(),
        .left_constants = &left.parser.constants,
        .right_constants = &right.parser.constants,
        .max_depth = options.max_depth,
    };
    return cmp.nodes(left.root, right.root, 0);
}

/// One side: the stripped text, the parser that owns the tree, and its root.
const Parsed = struct {
    allocator: std.mem.Allocator,
    prepared: source_frontend.PreparedSource,
    parser: parser_mod.JsParser,
    root: NodeIndex,

    const InitError = error{ OutOfMemory, NoTree };

    fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        atoms: *AtomTable,
        allow_asi: bool,
    ) InitError!Parsed {
        // The stripper runs first for the same reason the rest of the analyzer
        // runs it first: the parser reads JavaScript, and a `: T` it never saw
        // stripped is a syntax error rather than a type.
        var prepared = source_frontend.PreparedSource.init(allocator, source, "<identity>.ts", .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoTree,
        };
        errdefer prepared.deinit();

        var parser = try parser_mod.JsParser.init(allocator, prepared.parserInput());
        errdefer parser.deinit();
        parser.setAtomTable(atoms);
        // Both sides parse permissively, and the equivalence claim is tree
        // identity rather than either side's strictness.
        //
        // The unrepaired side has to: under spec 5.5 it does not parse at all,
        // which is the point of the repair. The repaired side has to for a
        // less obvious reason - a file missing three semicolons is repaired one
        // at a time, so every intermediate still has two missing. Requiring the
        // repaired side to parse strictly would refuse every repair in that
        // file and leave it with no mechanical exit, which is the opposite of
        // what the repair is for. What makes the claim sound is that the trees
        // are identical: same structure, more tokens.
        parser.allow_asi = allow_asi;

        const root = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NoTree,
        };

        return .{
            .allocator = allocator,
            .prepared = prepared,
            .parser = parser,
            .root = root,
        };
    }

    fn view(self: *Parsed) IrView {
        return IrView.fromIRStore(&self.parser.nodes, &self.parser.constants);
    }

    fn deinit(self: *Parsed) void {
        self.parser.deinit();
        self.prepared.deinit();
    }
};

const Comparer = struct {
    left: IrView,
    right: IrView,
    left_constants: *const ConstantPool,
    right_constants: *const ConstantPool,
    max_depth: u32,

    fn nodes(self: *Comparer, a: NodeIndex, b: NodeIndex, depth: u32) Verdict {
        if (depth > self.max_depth) return .{ .differs = "the trees nest deeper than this comparison follows" };

        // Absence is decided by whether the index resolves to a node, not by
        // comparing it against `null_node`. The IR store packs several child
        // fields into fewer than 32 bits - a template literal's `tag` gets 24 -
        // so the parser's `null_node` sentinel does not survive the round trip
        // and an untagged template reads back as an index past the end of the
        // tree. Both spellings of "there is nothing here" have to answer the
        // same way, or every untagged template would report a difference.
        const a_present = self.left.isValid(a);
        const b_present = self.right.isValid(b);
        if (!a_present and !b_present) return .identical;
        if (a_present != b_present) {
            return .{ .differs = "one side has a child where the other has none" };
        }

        const a_tag = self.left.getTag(a) orelse return .{ .differs = "a node index on the original side resolves to nothing" };
        const b_tag = self.right.getTag(b) orelse return .{ .differs = "a node index on the repaired side resolves to nothing" };
        if (a_tag != b_tag) return .{ .differs = "the two trees carry different node tags at the same position" };

        // Exhaustive on purpose, and with no `else`: a new NodeTag has to be
        // classified here or the build fails. See the file header.
        switch (a_tag) {
            // ---- Leaves whose whole payload is the value they carry ----
            .lit_int => {
                const av = self.left.getIntValue(a) orelse return payloadMissing();
                const bv = self.right.getIntValue(b) orelse return payloadMissing();
                if (av != bv) return .{ .differs = "two integer literals hold different values" };
                return .identical;
            },
            .lit_float => {
                const ai = self.left.getFloatIdx(a) orelse return payloadMissing();
                const bi = self.right.getFloatIdx(b) orelse return payloadMissing();
                const av = self.left_constants.getFloat(ai) orelse return payloadMissing();
                const bv = self.right_constants.getFloat(bi) orelse return payloadMissing();
                // Bit equality, not numeric equality: `0` and `-0` are the same
                // number under `==` and are not the same literal, and NaN is
                // equal to nothing under `==` including itself.
                if (@as(u64, @bitCast(av)) != @as(u64, @bitCast(bv))) {
                    return .{ .differs = "two float literals hold different values" };
                }
                return .identical;
            },
            .lit_string, .template_part_string => {
                return self.strings(a, b, "two string literals hold different text");
            },
            .lit_bool => {
                const av = self.left.getBoolValue(a) orelse return payloadMissing();
                const bv = self.right.getBoolValue(b) orelse return payloadMissing();
                if (av != bv) return .{ .differs = "two boolean literals hold different values" };
                return .identical;
            },
            // `null` is explicit data in this language and `undefined` is the
            // absence sentinel; neither carries a payload, and the tag equality
            // above is the whole comparison.
            .lit_null, .lit_undefined, .empty_stmt => return .identical,
            // The parser's only construction site for either sets the label to
            // null, and `labeled_stmt` is unmodeled below, so there is no label
            // to compare. Measured, not assumed: parse.zig builds `break_stmt`
            // and `continue_stmt` with `.opt_label = null` and nothing else.
            .break_stmt, .continue_stmt => return .identical,

            .identifier => return self.bindings(a, b),

            // ---- Expressions ----
            .binary_op => {
                const av = self.left.getBinary(a) orelse return payloadMissing();
                const bv = self.right.getBinary(b) orelse return payloadMissing();
                if (av.op != bv.op) return .{ .differs = "two binary expressions use different operators" };
                return self.all(&.{
                    .{ av.left, bv.left },
                    .{ av.right, bv.right },
                }, depth);
            },
            .unary_op => {
                const av = self.left.getUnary(a) orelse return payloadMissing();
                const bv = self.right.getUnary(b) orelse return payloadMissing();
                if (av.op != bv.op) return .{ .differs = "two unary expressions use different operators" };
                return self.nodes(av.operand, bv.operand, depth + 1);
            },
            .ternary => {
                const av = self.left.getTernary(a) orelse return payloadMissing();
                const bv = self.right.getTernary(b) orelse return payloadMissing();
                return self.all(&.{
                    .{ av.condition, bv.condition },
                    .{ av.then_branch, bv.then_branch },
                    .{ av.else_branch, bv.else_branch },
                }, depth);
            },
            .call, .method_call, .optional_call => {
                const av = self.left.getCall(a) orelse return payloadMissing();
                const bv = self.right.getCall(b) orelse return payloadMissing();
                if (av.is_optional != bv.is_optional) {
                    return .{ .differs = "one call is optional and the other is not" };
                }
                if (av.args_count != bv.args_count) {
                    return .{ .differs = "two calls take different argument counts" };
                }
                const callee = self.nodes(av.callee, bv.callee, depth + 1);
                if (callee != .identical) return callee;
                return self.lists(av.args_start, bv.args_start, av.args_count, depth);
            },
            .member_access, .computed_access, .optional_chain => {
                const av = self.left.getMember(a) orelse return payloadMissing();
                const bv = self.right.getMember(b) orelse return payloadMissing();
                if (av.is_optional != bv.is_optional) {
                    return .{ .differs = "one member access is optional and the other is not" };
                }
                if (av.property != bv.property) {
                    return .{ .differs = "two member accesses name different properties" };
                }
                return self.all(&.{
                    .{ av.object, bv.object },
                    .{ av.computed, bv.computed },
                }, depth);
            },
            .assignment => {
                const av = self.left.getAssignment(a) orelse return payloadMissing();
                const bv = self.right.getAssignment(b) orelse return payloadMissing();
                if (av.op == null and bv.op != null) return assignOpDiffers();
                if (av.op != null and bv.op == null) return assignOpDiffers();
                if (av.op != null and bv.op != null and av.op.? != bv.op.?) return assignOpDiffers();
                return self.all(&.{
                    .{ av.target, bv.target },
                    .{ av.value, bv.value },
                }, depth);
            },
            .array_literal, .array_pattern, .object_pattern => {
                // All three carry an `ArrayExpr`: the two pattern tags reuse it
                // for their element list, which is what codegen reads.
                const av = self.left.getArray(a) orelse return payloadMissing();
                const bv = self.right.getArray(b) orelse return payloadMissing();
                if (av.has_spread != bv.has_spread) {
                    return .{ .differs = "one element list spreads and the other does not" };
                }
                if (av.elements_count != bv.elements_count) {
                    return .{ .differs = "two element lists hold different counts" };
                }
                return self.lists(av.elements_start, bv.elements_start, av.elements_count, depth);
            },
            .object_literal => {
                const av = self.left.getObject(a) orelse return payloadMissing();
                const bv = self.right.getObject(b) orelse return payloadMissing();
                if (av.properties_count != bv.properties_count) {
                    return .{ .differs = "two object literals hold different property counts" };
                }
                return self.lists(av.properties_start, bv.properties_start, av.properties_count, depth);
            },
            .object_property => {
                const av = self.left.getProperty(a) orelse return payloadMissing();
                const bv = self.right.getProperty(b) orelse return payloadMissing();
                if (av.is_computed != bv.is_computed) {
                    return .{ .differs = "one property key is computed and the other is not" };
                }
                // `is_shorthand` is deliberately not compared: `{ x }` and
                // `{ x: x }` are the same program, and the flag records only
                // which spelling the author used.
                return self.all(&.{
                    .{ av.key, bv.key },
                    .{ av.value, bv.value },
                }, depth);
            },
            .spread, .object_spread, .expr_stmt, .template_part_expr, .return_stmt => {
                // The payload is optional by construction: `return;` stores no
                // value and `getOptValue` answers null for it. Absent on both
                // sides is agreement, not a missing payload, and reporting it
                // as one made `compare(src, src)` call a source carrying a bare
                // `return` different from itself.
                const av = self.left.getOptValue(a);
                const bv = self.right.getOptValue(b);
                if (av == null and bv == null) return .identical;
                const a_value = av orelse return .{ .differs = "one side carries a value here and the other does not" };
                const b_value = bv orelse return .{ .differs = "one side carries a value here and the other does not" };
                return self.nodes(a_value, b_value, depth + 1);
            },
            .function_expr, .arrow_function => {
                const af = self.left.getFunction(a) orelse return payloadMissing();
                const bf = self.right.getFunction(b) orelse return payloadMissing();
                if (af.name_atom != bf.name_atom) {
                    return .{ .differs = "two functions carry different names" };
                }
                if (@as(u8, @bitCast(af.flags)) != @as(u8, @bitCast(bf.flags))) {
                    return .{ .differs = "two functions carry different flags" };
                }
                if (af.params_count != bf.params_count) {
                    return .{ .differs = "two functions take different parameter counts" };
                }
                const params = self.lists(af.params_start, bf.params_start, af.params_count, depth);
                if (params != .identical) return params;
                return self.nodes(af.body, bf.body, depth + 1);
            },
            .template_literal => {
                const av = self.left.getTemplate(a) orelse return payloadMissing();
                const bv = self.right.getTemplate(b) orelse return payloadMissing();
                if (av.parts_count != bv.parts_count) {
                    return .{ .differs = "two template literals hold different part counts" };
                }
                const tag = self.nodes(av.tag, bv.tag, depth + 1);
                if (tag != .identical) return tag;
                return self.lists(av.parts_start, bv.parts_start, av.parts_count, depth);
            },

            // ---- match ----
            .match_expr => {
                const av = self.left.getMatchExpr(a) orelse return payloadMissing();
                const bv = self.right.getMatchExpr(b) orelse return payloadMissing();
                if (av.arms_count != bv.arms_count) {
                    return .{ .differs = "two match expressions hold different arm counts" };
                }
                const disc = self.nodes(av.discriminant, bv.discriminant, depth + 1);
                if (disc != .identical) return disc;
                return self.lists(av.arms_start, bv.arms_start, av.arms_count, depth);
            },
            .match_arm => {
                const av = self.left.getMatchArm(a) orelse return payloadMissing();
                const bv = self.right.getMatchArm(b) orelse return payloadMissing();
                return self.all(&.{
                    .{ av.pattern, bv.pattern },
                    .{ av.body, bv.body },
                }, depth);
            },
            .match_pattern => {
                const av = self.left.getMatchPattern(a) orelse return payloadMissing();
                const bv = self.right.getMatchPattern(b) orelse return payloadMissing();
                if (av.props_count != bv.props_count) {
                    return .{ .differs = "two match patterns hold different field counts" };
                }
                return self.lists(av.props_start, bv.props_start, av.props_count, depth);
            },
            .match_type_test => {
                const av = self.left.getMatchTypeTest(a) orelse return payloadMissing();
                const bv = self.right.getMatchTypeTest(b) orelse return payloadMissing();
                if (av.kind != bv.kind) {
                    return .{ .differs = "two type-test patterns name different kinds" };
                }
                return self.nodes(av.predicate, bv.predicate, depth + 1);
            },

            // ---- Statements and declarations ----
            // A function declaration carries a `VarDecl` whose `init` is the
            // function node, which is how the parser binds the name. Grouping
            // it with `function_expr` and reading a `FunctionExpr` out of it
            // read a different payload's bits.
            .var_decl, .function_decl => {
                const av = self.left.getVarDecl(a) orelse return payloadMissing();
                const bv = self.right.getVarDecl(b) orelse return payloadMissing();
                if (av.kind != bv.kind) {
                    return .{ .differs = "two declarations use different binding keywords" };
                }
                const binding = self.bindingRefs(av.binding, bv.binding);
                if (binding != .identical) return binding;
                return self.all(&.{
                    .{ av.pattern, bv.pattern },
                    .{ av.init, bv.init },
                }, depth);
            },
            .if_stmt => {
                const av = self.left.getIfStmt(a) orelse return payloadMissing();
                const bv = self.right.getIfStmt(b) orelse return payloadMissing();
                return self.all(&.{
                    .{ av.condition, bv.condition },
                    .{ av.then_branch, bv.then_branch },
                    .{ av.else_branch, bv.else_branch },
                }, depth);
            },
            .for_of_stmt => {
                const av = self.left.getForIter(a) orelse return payloadMissing();
                const bv = self.right.getForIter(b) orelse return payloadMissing();
                if (av.is_for_in != bv.is_for_in) {
                    return .{ .differs = "one loop is for-in and the other is for-of" };
                }
                if (av.is_const != bv.is_const) {
                    return .{ .differs = "two loops bind with different keywords" };
                }
                const binding = self.bindingRefs(av.binding, bv.binding);
                if (binding != .identical) return binding;
                return self.all(&.{
                    .{ av.pattern, bv.pattern },
                    .{ av.iterable, bv.iterable },
                    .{ av.body, bv.body },
                }, depth);
            },
            .assert_stmt => {
                const av = self.left.getAssertStmt(a) orelse return payloadMissing();
                const bv = self.right.getAssertStmt(b) orelse return payloadMissing();
                return self.all(&.{
                    .{ av.condition, bv.condition },
                    .{ av.error_expr, bv.error_expr },
                }, depth);
            },
            .block, .program => {
                const av = self.left.getBlock(a) orelse return payloadMissing();
                const bv = self.right.getBlock(b) orelse return payloadMissing();
                if (av.stmts_count != bv.stmts_count) {
                    return .{ .differs = "two blocks hold different statement counts" };
                }
                if (av.scope_id != bv.scope_id) {
                    return .{ .differs = "two blocks open different scopes" };
                }
                return self.lists(av.stmts_start, bv.stmts_start, av.stmts_count, depth);
            },
            .pattern_element, .pattern_rest => {
                const av = self.left.getPatternElem(a) orelse return payloadMissing();
                const bv = self.right.getPatternElem(b) orelse return payloadMissing();
                if (av.kind != bv.kind) {
                    return .{ .differs = "two pattern elements are of different kinds" };
                }
                if (av.key_atom != bv.key_atom) {
                    return .{ .differs = "two pattern elements name different fields" };
                }
                const binding = self.bindingRefs(av.binding, bv.binding);
                if (binding != .identical) return binding;
                return self.all(&.{
                    .{ av.key, bv.key },
                    .{ av.default_value, bv.default_value },
                }, depth);
            },

            // ---- Modules ----
            .import_decl => {
                const av = self.left.getImportDecl(a) orelse return payloadMissing();
                const bv = self.right.getImportDecl(b) orelse return payloadMissing();
                const module = self.strings2(
                    av.module_idx,
                    bv.module_idx,
                    "two imports name different modules",
                );
                if (module != .identical) return module;
                if (av.specifiers_count != bv.specifiers_count) {
                    return .{ .differs = "two imports hold different specifier counts" };
                }
                return self.lists(av.specifiers_start, bv.specifiers_start, av.specifiers_count, depth);
            },
            .import_specifier => {
                const av = self.left.getImportSpec(a) orelse return payloadMissing();
                const bv = self.right.getImportSpec(b) orelse return payloadMissing();
                if (av.kind != bv.kind) {
                    return .{ .differs = "two import specifiers are of different kinds" };
                }
                if (av.imported_atom != bv.imported_atom) {
                    return .{ .differs = "two import specifiers name different exports" };
                }
                return self.bindingRefs(av.local_binding, bv.local_binding);
            },
            .export_decl => {
                const av = self.left.getExportDecl(a) orelse return payloadMissing();
                const bv = self.right.getExportDecl(b) orelse return payloadMissing();
                if (av.kind != bv.kind) {
                    return .{ .differs = "two exports are of different kinds" };
                }
                if (av.specifiers_count != bv.specifiers_count) {
                    return .{ .differs = "two exports hold different specifier counts" };
                }
                if (av.from_module_idx != 0 or bv.from_module_idx != 0) {
                    // A re-export resolves its module through the string pool
                    // the same way an import does, but nothing in the admitted
                    // subset produces one; refusing keeps this from being an
                    // untested path that answers "identical".
                    return .{ .unmodeled = a_tag };
                }
                const decl = self.nodes(av.declaration, bv.declaration, depth + 1);
                if (decl != .identical) return decl;
                return self.lists(av.specifiers_start, bv.specifiers_start, av.specifiers_count, depth);
            },

            // ---- Not modeled ----
            //
            // The first group names constructs the language refuses at parse
            // time, so a source that parsed carries none of them. The rest are
            // forms whose payload nothing here has been checked against; each
            // answers `.unmodeled`, which no caller may read as an equivalence.
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .switch_stmt,
            .case_clause,
            .for_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .throw_stmt,
            .try_stmt,
            .labeled_stmt,
            .debugger_stmt,
            .object_method,
            .object_getter,
            .object_setter,
            .pattern_default,
            .import_default,
            .import_namespace,
            .export_specifier,
            .export_default,
            .export_all,
            .param_list,
            .arg_list,
            .stmt_list,
            => return .{ .unmodeled = a_tag },
        }
    }

    /// Compare a run of `count` children drawn from each side's index list.
    fn lists(self: *Comparer, a_start: NodeIndex, b_start: NodeIndex, count: anytype, depth: u32) Verdict {
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const verdict = self.nodes(
                self.left.getListIndex(a_start, i),
                self.right.getListIndex(b_start, i),
                depth + 1,
            );
            if (verdict != .identical) return verdict;
        }
        return .identical;
    }

    /// Compare a fixed set of child pairs, stopping at the first difference.
    fn all(self: *Comparer, pairs: []const [2]NodeIndex, depth: u32) Verdict {
        for (pairs) |pair| {
            const verdict = self.nodes(pair[0], pair[1], depth + 1);
            if (verdict != .identical) return verdict;
        }
        return .identical;
    }

    fn bindings(self: *Comparer, a: NodeIndex, b: NodeIndex) Verdict {
        const av = self.left.getBinding(a) orelse return payloadMissing();
        const bv = self.right.getBinding(b) orelse return payloadMissing();
        return self.bindingRefs(av, bv);
    }

    /// Two references denote the same binding when they name the same thing and
    /// resolve the same way. The name is compared through the shared atom
    /// table, so this is a name comparison and not an index comparison.
    fn bindingRefs(self: *Comparer, a: ir.BindingRef, b: ir.BindingRef) Verdict {
        _ = self;
        if (a.name_atom != b.name_atom) return .{ .differs = "two references name different bindings" };
        if (a.kind != b.kind) return .{ .differs = "two references to one name resolve to different binding kinds" };
        if (a.scope_id != b.scope_id) return .{ .differs = "two references resolve in different scopes" };
        if (a.slot != b.slot) return .{ .differs = "two references resolve to different slots" };
        return .identical;
    }

    fn strings(self: *Comparer, a: NodeIndex, b: NodeIndex, message: []const u8) Verdict {
        const ai = self.left.getStringIdx(a) orelse return payloadMissing();
        const bi = self.right.getStringIdx(b) orelse return payloadMissing();
        return self.strings2(ai, bi, message);
    }

    fn strings2(self: *Comparer, a_idx: u16, b_idx: u16, message: []const u8) Verdict {
        const a = self.left_constants.getString(a_idx) orelse return payloadMissing();
        const b = self.right_constants.getString(b_idx) orelse return payloadMissing();
        if (!std.mem.eql(u8, a, b)) return .{ .differs = message };
        return .identical;
    }
};

/// A tag whose accessor answered null is a tree this file cannot read, which is
/// a difference rather than an equality: answering "identical" for a payload
/// nothing could load is the fail-open this file exists to avoid.
fn payloadMissing() Verdict {
    return .{ .differs = "a node's payload did not load on one side" };
}

fn assignOpDiffers() Verdict {
    return .{ .differs = "two assignments use different operators" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "layout, comments, and quote style leave the tree alone" {
    const a =
        \\function handler(req: Request): Response {
        \\  const n = 1;
        \\  return Response.text("ok");
        \\}
    ;
    const b =
        \\// a comment the parser discards
        \\function handler(req: Request): Response {
        \\      const n   =   1;
        \\      return Response.text('ok');
        \\}
    ;
    try testing.expectEqual(Verdict.identical, try compare(testing.allocator, a, b, .{}));
}

test "a changed literal is a different tree" {
    const a = "function handler(req: Request): Response { return Response.text(\"ok\"); }";
    const b = "function handler(req: Request): Response { return Response.text(\"no\"); }";
    const verdict = try compare(testing.allocator, a, b, .{});
    try testing.expect(verdict == .differs);
}

test "a changed callee is a different tree" {
    // The case a text diff would call small and a validator must call large:
    // one property atom moves and the response changes shape.
    const a = "function handler(req: Request): Response { return Response.text(\"ok\"); }";
    const b = "function handler(req: Request): Response { return Response.json(\"ok\"); }";
    const verdict = try compare(testing.allocator, a, b, .{});
    try testing.expect(verdict == .differs);
}

test "an added statement is a different tree" {
    const a =
        \\function handler(req: Request): Response {
        \\  const n = 1;
        \\  return Response.text("ok");
        \\}
    ;
    const b =
        \\function handler(req: Request): Response {
        \\  const n = 1;
        \\  const m = 2;
        \\  return Response.text("ok");
        \\}
    ;
    const verdict = try compare(testing.allocator, a, b, .{});
    try testing.expect(verdict == .differs);
}

test "a renamed binding is a different tree" {
    // Slots alone would call these equal: both bind one local in one scope and
    // read it back. The name atom is what separates them, which is why the two
    // parses share an atom table.
    const a =
        \\function handler(req: Request): Response {
        \\  const first = "ok";
        \\  return Response.text(first);
        \\}
    ;
    const b =
        \\function handler(req: Request): Response {
        \\  const second = "ok";
        \\  return Response.text(second);
        \\}
    ;
    const verdict = try compare(testing.allocator, a, b, .{});
    try testing.expect(verdict == .differs);
}

test "a source that does not parse names its own side" {
    const good = "function handler(req: Request): Response { return Response.text(\"ok\"); }";
    const bad = "function handler(req: Request): Response { return Response.text(\"ok\"; }";

    const left = try compare(testing.allocator, bad, good, .{});
    try testing.expect(left == .unparsable);
    try testing.expectEqual(Side.original, left.unparsable);

    const right = try compare(testing.allocator, good, bad, .{});
    try testing.expect(right == .unparsable);
    try testing.expectEqual(Side.repaired, right.unparsable);
}

test "the constructs the unmodeled arm names cannot reach this file" {
    // What the unmodeled arm rests on, checked rather than asserted in prose:
    // the parser refuses these before a tree exists, so `compare` answers
    // `unparsable` and never has to decide them. That is the property worth
    // pinning. It replaces a version of this test that walked
    // `std.enums.values(NodeTag)` against a hand-copied duplicate of the arm's
    // 32 tags and asserted the copy's own length - which held whatever the
    // implementation did, including after a tag moved out of the arm.
    //
    // A behavioural check of the arm itself is not available: every tag in it
    // is either refused here or, like JSX, needs a strip mode `compare` does
    // not use, so no source reaches it. The arm is the answer for a tag that
    // becomes reachable later, and `nodes` stays exhaustive with no `else` so
    // that a new tag has to be classified rather than defaulting.
    const refused = [_][]const u8{
        "function f(x: number): number { while (x > 0) { x = x - 1; } return x; }",
        "function f(x: number): number { try { return x; } catch (e) { return 0; } }",
        "function f(x: number): number { switch (x) { case 1: return 1; } return 0; }",
        "function f(x: number): number { throw new Error(\"no\"); }",
    };
    for (refused) |source| {
        const verdict = try compare(testing.allocator, source, source, .{});
        if (verdict != .unparsable) {
            std.debug.print("expected unparsable, got {s}\n", .{@tagName(verdict)});
            return error.TestFailed;
        }
    }

    // The alphabet pin, read off the enum rather than off a list beside it.
    try testing.expectEqual(@as(usize, 76), std.enums.values(NodeTag).len);
}

/// One source exercising every form a handler is written in, used twice below:
/// once to prove nothing in it is refused, and once as the base for the
/// mutations that must be caught.
const admitted_surface =
    \\import { json } from "zttp:json";
    \\
    \\structural Order = { id: string; total: number };
    \\
    \\export function handler(req: Request): Response {
    \\  const orders: Order[] = [{ id: "a", total: 1 }, { id: "b", total: 2 }];
    \\  const { id } = orders[0];
    \\  const labels = orders.map((o: Order): string => `${o.id}:${o.total}`);
    \\  let sum = 0;
    \\  for (const o of orders) {
    \\    sum = sum + o.total;
    \\  }
    \\  const kind = match (id) {
    \\    when "a": "first"
    \\    default: "other"
    \\  };
    \\  const flag = sum > 0 ? true : false;
    \\  const merged = { ...orders[0], kind: kind };
    \\  assert sum >= 0, "sum is not negative";
    \\  if (flag) {
    \\    return Response.json({ labels: labels, merged: merged, json: json });
    \\  }
    \\  return Response.text("empty");
    \\}
;

test "the whole admitted surface compares rather than refusing" {
    // The floor for the switch above: a source exercising the forms handlers
    // are written in must reach `identical`, not `unmodeled`. Without this the
    // modeled set could shrink to nothing and every test above would still
    // pass, because a refusal is not a difference.
    const verdict = try compare(testing.allocator, admitted_surface, admitted_surface, .{});
    if (verdict != .identical) {
        switch (verdict) {
            .unmodeled => |tag| std.debug.print("unmodeled tag reached: {s}\n", .{@tagName(tag)}),
            .differs => |why| std.debug.print("differs: {s}\n", .{why}),
            .unparsable => |side| std.debug.print("unparsable: {s}\n", .{@tagName(side)}),
            .identical => unreachable,
        }
        return error.TestFailed;
    }
}

test "a change anywhere in the admitted surface is caught" {
    // The test above cannot fail when an arm reads the wrong payload field:
    // it compares a source with itself, so a misread compares garbage against
    // the same garbage and agrees. Each mutation here moves one field of one
    // arm, so an arm that reads the wrong bits stops noticing and fails.
    const mutations = [_]struct { from: []const u8, to: []const u8, what: []const u8 }{
        .{ .from = "sum + o.total", .to = "sum - o.total", .what = "a binary operator" },
        .{ .from = "when \"a\": \"first\"", .to = "when \"a\": \"second\"", .what = "a match arm body" },
        .{ .from = "when \"a\":", .to = "when \"b\":", .what = "a match arm pattern" },
        .{ .from = "`${o.id}:${o.total}`", .to = "`${o.total}:${o.id}`", .what = "template part order" },
        .{ .from = "{ ...orders[0], kind: kind }", .to = "{ kind: kind, ...orders[0] }", .what = "property order" },
        .{ .from = "orders[0];", .to = "orders[1];", .what = "an index literal" },
        .{ .from = "sum >= 0", .to = "sum > 0", .what = "an assert condition" },
        .{ .from = "sum > 0 ? true : false", .to = "sum > 0 ? false : true", .what = "ternary arms" },
        .{ .from = "let sum = 0;", .to = "const sum = 0;", .what = "a binding keyword" },
        .{ .from = "(o: Order): string =>", .to = "(other: Order): string =>", .what = "a parameter name" },
        .{ .from = "import { json }", .to = "import { jsonx as json }", .what = "an imported name" },
        .{ .from = "Response.json(", .to = "Response.rawJson(", .what = "a called property" },
    };

    for (mutations) |m| {
        const mutated = try std.mem.replaceOwned(u8, testing.allocator, admitted_surface, m.from, m.to);
        defer testing.allocator.free(mutated);
        if (std.mem.eql(u8, mutated, admitted_surface)) {
            // The mutation matched nothing, so the case below would compare a
            // source with itself and pass while testing nothing.
            std.debug.print("mutation for {s} matched no text\n", .{m.what});
            return error.TestFailed;
        }

        const verdict = try compare(testing.allocator, admitted_surface, mutated, .{});
        if (verdict != .differs) {
            switch (verdict) {
                .identical => std.debug.print("{s} changed and the trees still compared identical\n", .{m.what}),
                .unmodeled => |tag| std.debug.print("{s}: unmodeled {s}\n", .{ m.what, @tagName(tag) }),
                .unparsable => |side| std.debug.print("{s}: unparsable {s}\n", .{ m.what, @tagName(side) }),
                .differs => unreachable,
            }
            return error.TestFailed;
        }
    }
}
