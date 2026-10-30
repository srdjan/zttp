//! The canonical proof IR: the shape of a program, and nothing else.
//!
//! A certificate has to state what was proved about which part of the program,
//! and a consumer has to be able to re-derive that statement without the
//! compiler. Neither is possible against the parser IR: it is large, it carries
//! source positions, and every expression form in it is a member the consumer
//! would have to model.
//!
//! This lowering keeps the six node kinds totality depends on and collapses
//! everything else to a leaf. What survives is small enough that the consumer
//! re-runs the derivation itself rather than checking a producer's word for it,
//! and stable enough that moving a line does not move the proof identity.
//!
//! Six, not more, because six is what this subset's totality depends on. A
//! `match` is an expression here, so it can never be the construct that
//! returns; the same is true of a call. Modelling either would have added node
//! kinds and a rule that no real source could reach, and an alphabet member
//! nothing constructs is a check that never runs.
//!
//! The tag and rule numbering here mirrors the acceptance kernel's alphabet.
//! It is duplicated rather than imported because the kernel is a leaf and the
//! compiler must not become its dependency; `packages/runtime` imports both and
//! pins the two numberings against each other.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const translation_witness = @import("zts-engine").translation_witness;
const handler_function_mod = @import("handler_function.zig");
const module_facts_mod = @import("module_facts.zig");
const builtin_modules = @import("zts-engine").builtin_modules;
const engine_object = @import("zts-engine").object;
const engine_context = @import("zts-engine").context;

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;
const null_node = ir.null_node;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const node_domain = "zts-proof-ir-node-v1";

/// Mirrors `proof_system.NodeTag` in the acceptance kernel.
pub const Tag = enum(u16) {
    function = 1,
    sequence = 2,
    branch = 3,
    loop_node = 4,
    return_node = 5,
    plain = 6,
    /// A call to a capability export whose resource the compiler could not
    /// resolve. It contributes nothing to totality and exists so the consumer
    /// can count the guarded operations itself.
    capability_call = 7,
    /// `const b = <Result export call>`. `aux` is the binding ordinal.
    result_def = 9,
    /// The condition of an `if` is exactly `b.ok`.
    result_guard_ok = 10,
    /// The condition of an `if` is exactly `!b.ok`.
    result_guard_err = 11,
    /// `b.value` or `b.unwrap`, as a member or as a literal computed key.
    result_read_ok = 12,
    /// `b.error` or `b.errors`, as a member or as a literal computed key.
    result_read_err = 13,
    /// Every other use of a Result binding or of a Result call.
    result_escape = 14,
};

/// Mirrors `proof_system.Rule` in the acceptance kernel.
pub const Rule = enum(u16) {
    return_total = 1,
    branch_both_arms_total = 2,
    sequence_member_total = 3,
    loop_never_total = 4,
    result_reads_guarded = 9,
};

/// The most Result bindings the consumer accepts in one program.
pub const max_result_bindings: u32 = 64;

/// How the lowering learns that a call reaches a guarded capability export.
///
/// The compiler resolves the callee to a module and export; the caller turns
/// that into the consumer catalog's row index. The index, not the names, is
/// what the proof IR carries, so the consumer resolves the row from its own
/// table rather than from anything the producer wrote about it.
pub const Resolver = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, NodeIndex) ?u32,
    /// The atom table that names the imports of this parse. A resolver exists
    /// so that the lowering can classify Result bindings; without a table the
    /// lowering reads import names from the constant pool, as a standalone
    /// parse stores them.
    atoms: ?*engine_context.AtomTable = null,

    fn call(self: Resolver, node: NodeIndex) ?u32 {
        return self.resolve(self.context, node);
    }
};

pub const Node = struct {
    id: u32,
    tag: Tag,
    parent: u32,
    first_child: u32,
    child_count: u32,
    digest: [32]u8,
    /// The parser IR node this came from. Translation witnesses are recorded
    /// against parser indices, so this is how they attach.
    source: NodeIndex,
    /// The consumer catalog row for a `capability_call`. Zero for every other tag.
    aux: u32 = 0,
};

pub const ProofIr = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    /// The node id of the handler function, when the program declares one.
    handler_function: ?u32,
    /// Whether the lowering classified every Result binding of the program.
    /// False when no resolver was supplied, when the program holds more than
    /// `max_result_bindings` bindings, or when an expression nests deeper than
    /// the event walk reads. A program with this flag false carries no Result
    /// evidence, and no `proved` results edge may rest on it.
    results_classified: bool = false,

    pub fn deinit(self: *ProofIr) void {
        self.allocator.free(self.nodes);
        self.nodes = &.{};
    }

    /// The node a parser node lowered to. A node with no parser source, such as
    /// a Result event, has none, so no translation witness attaches to it.
    pub fn nodeFor(self: *const ProofIr, source: NodeIndex) ?u32 {
        if (source == null_node) return null;
        for (self.nodes) |node| {
            if (node.source == source) return node.id;
        }
        return null;
    }
};

pub const Error = error{
    OutOfMemory,
    /// The program nests deeper than the lowering will walk. A refusal, not a
    /// truncation: a partial proof IR would describe a different program.
    ProgramTooDeep,
};

pub const max_depth: u16 = 512;

// ---------------------------------------------------------------------------
// Lowering
// ---------------------------------------------------------------------------

const Tree = struct {
    tag: Tag,
    source: NodeIndex,
    /// Discriminator folded into a leaf's digest, so two different parser forms
    /// that both collapse to `plain` are still different members.
    leaf_kind: u16,
    aux: u32 = 0,
    children: std.ArrayList(Tree) = .empty,
    digest: [32]u8 = undefined,

    fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
    }
};

const mb = @import("zts-engine").module_binding;

/// The ambient globals that return a Result. `abi_types.zig` registers each of
/// them with `result_record`; a test below fails when the list differs.
const result_globals = @import("handler_verifier.zig").result_globals;

const ResultBinding = struct {
    scope_id: ir.ScopeId,
    slot: u16,
    name_atom: u16,
};

const Lowerer = struct {
    allocator: std.mem.Allocator,
    view: IrView,
    resolver: ?Resolver = null,
    depth: u16 = 0,
    /// The import index, present when a resolver supplies the classification
    /// of Result bindings.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    /// The Result bindings of the program. A binding's index is its ordinal.
    bindings: []const ResultBinding = &.{},
    /// The expression bodies of function literals that sit at a `.result_fn`
    /// position of a builtin export. The export hands the Result that such a
    /// body returns on inside the Result it returns itself.
    callback_bodies: []const NodeIndex = &.{},
    results_active: bool = false,
    /// Set while a nested expression is built under a statement leaf that
    /// already collected the events of the whole statement.
    events_off: bool = false,
    /// Set when an expression nests deeper than the event walk reads.
    overflow: bool = false,

    /// Whether a subtree contains a guarded call.
    ///
    /// A guarded call can sit anywhere an expression can - inside a `return`,
    /// inside an initializer, inside a match arm - and the lowering must reach
    /// it wherever it is. It must also leave a handler with none exactly as it
    /// was, or every literal-only artifact's proof identity would move. So the
    /// descent below expression forms happens only along paths that lead to
    /// one.
    fn containsRelevantCall(self: *Lowerer, index: NodeIndex) bool {
        if (index == null_node) return false;
        if (self.resolver == null) return false;
        if (self.guardedIndex(index) != null) return true;
        var found = false;
        self.forEachSubNode(index, &found, struct {
            fn visit(ctx: *bool, lowerer: *Lowerer, child: NodeIndex) void {
                if (ctx.*) return;
                if (lowerer.containsRelevantCall(child)) ctx.* = true;
            }
        }.visit);
        return found;
    }

    fn guardedIndex(self: *Lowerer, index: NodeIndex) ?u32 {
        const resolver = self.resolver orelse return null;
        const tag = self.view.getTag(index) orelse return null;
        return switch (tag) {
            .call, .method_call => resolver.call(index),
            // exhaustive: only call nodes can be guarded; any other node is not a guarded call.
            else => null,
        };
    }

    /// Every node one node can hold, expressions included.
    ///
    /// `IrView.forEachChild` walks statements only, which is right for the
    /// totality fold and not enough to find a call inside a return. This covers
    /// the expression forms the subset admits; anything it misses is a guarded
    /// call the lowering cannot see, which is why the classifier in U5 refuses
    /// a form this walk does not reach.
    fn forEachSubNode(
        self: *Lowerer,
        index: NodeIndex,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), *Lowerer, NodeIndex) void,
    ) void {
        const tag = self.view.getTag(index) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.view.getBlock(index) orelse return;
                for (0..block.stmts_count) |i| {
                    visit(ctx, self, self.view.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                if (self.view.getExportDecl(index)) |decl| visit(ctx, self, decl.declaration);
            },
            .var_decl, .function_decl => {
                if (self.view.getVarDecl(index)) |decl| visit(ctx, self, decl.init);
            },
            .function_expr, .arrow_function => {
                if (self.view.getFunction(index)) |func| visit(ctx, self, func.body);
            },
            .if_stmt => {
                const stmt = self.view.getIfStmt(index) orelse return;
                visit(ctx, self, stmt.condition);
                visit(ctx, self, stmt.then_branch);
                visit(ctx, self, stmt.else_branch);
            },
            .for_of_stmt, .for_in_stmt => {
                const loop = self.view.getForIter(index) orelse return;
                visit(ctx, self, loop.iterable);
                visit(ctx, self, loop.body);
            },
            .for_stmt, .while_stmt, .do_while_stmt => {
                const loop = self.view.getLoop(index) orelse return;
                visit(ctx, self, loop.init);
                visit(ctx, self, loop.condition);
                visit(ctx, self, loop.update);
                visit(ctx, self, loop.body);
            },
            .return_stmt, .expr_stmt => {
                if (self.view.getOptValue(index)) |value| visit(ctx, self, value);
            },
            .assert_stmt => {
                const stmt = self.view.getAssertStmt(index) orelse return;
                visit(ctx, self, stmt.condition);
                visit(ctx, self, stmt.error_expr);
            },
            .binary_op => {
                const binary = self.view.getBinary(index) orelse return;
                visit(ctx, self, binary.left);
                visit(ctx, self, binary.right);
            },
            .unary_op => {
                if (self.view.getUnary(index)) |unary| visit(ctx, self, unary.operand);
            },
            .ternary => {
                const ternary = self.view.getTernary(index) orelse return;
                visit(ctx, self, ternary.condition);
                visit(ctx, self, ternary.then_branch);
                visit(ctx, self, ternary.else_branch);
            },
            .call, .method_call => {
                const call = self.view.getCall(index) orelse return;
                visit(ctx, self, call.callee);
                for (0..call.args_count) |i| {
                    visit(ctx, self, self.view.getListIndex(call.args_start, @intCast(i)));
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.view.getMember(index) orelse return;
                visit(ctx, self, member.object);
                visit(ctx, self, member.computed);
            },
            .assignment => {
                const assign = self.view.getAssignment(index) orelse return;
                visit(ctx, self, assign.target);
                visit(ctx, self, assign.value);
            },
            .array_literal => {
                const array = self.view.getArray(index) orelse return;
                for (0..array.elements_count) |i| {
                    visit(ctx, self, self.view.getListIndex(array.elements_start, @intCast(i)));
                }
            },
            .object_literal => {
                const object = self.view.getObject(index) orelse return;
                for (0..object.properties_count) |i| {
                    visit(ctx, self, self.view.getListIndex(object.properties_start, @intCast(i)));
                }
            },
            .object_property => {
                const property = self.view.getProperty(index) orelse return;
                visit(ctx, self, property.key);
                visit(ctx, self, property.value);
            },
            .match_expr => {
                const match = self.view.getMatchExpr(index) orelse return;
                visit(ctx, self, match.discriminant);
                for (0..match.arms_count) |i| {
                    visit(ctx, self, self.view.getListIndex(match.arms_start, @intCast(i)));
                }
            },
            .match_arm => {
                if (self.view.getMatchArm(index)) |arm| visit(ctx, self, arm.body);
            },
            .spread, .object_spread => {
                if (self.view.getOptValue(index)) |value| visit(ctx, self, value);
            },
            // exhaustive: the profile refuses the other child-bearing kinds (switch, try, throw, labeled, await, yield, comma, object methods, default exports; ZTS001 observed), and match patterns hold literals only.
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Result events
    //
    // A Result binding is a `var_decl` whose initializer is a direct call to a
    // builtin export that returns a Result. The lowering records where each
    // binding is defined, guarded, read, and used in any other way, and the
    // consumer decides from those events alone whether every read is guarded.
    // The default for a use the lowering does not model is an escape, which the
    // consumer refuses.
    // -----------------------------------------------------------------------

    const Reference = union(enum) {
        /// Not a Result binding.
        none,
        ordinal: u32,
        /// An upvalue whose name matches several Result bindings, or a key
        /// that two Result bindings share. The IR cannot say which one it is.
        ambiguous,
    };

    const Position = enum { other, discard, nullish_left, optional_object, result_arg };

    const MemberKind = enum { ok, value, failure, other };

    const max_event_depth: u16 = 1024;

    fn event(tag: Tag, ordinal: u32) Tree {
        return .{ .tag = tag, .source = null_node, .leaf_kind = 0, .aux = ordinal };
    }

    /// The builtin export that an identifier names, when it names an import.
    fn builtinExport(self: *Lowerer, identifier: NodeIndex) ?*const mb.FunctionBinding {
        const facts = self.facts orelse return null;
        if (self.view.getTag(identifier) != .identifier) return null;
        const binding = self.view.getBinding(identifier) orelse return null;
        const record = facts.importForReference(binding, .module_reference, .builtin, .first) orelse return null;
        const found = builtin_modules.findExport(record.module_specifier, record.imported_name) orelse return null;
        return found.func;
    }

    /// Whether an identifier names one of the ambient globals that return a
    /// Result. A local, argument, or upvalue that shadows the name is not the
    /// global, so only an undeclared global qualifies.
    fn isResultGlobal(self: *Lowerer, identifier: NodeIndex) bool {
        if (self.view.getTag(identifier) != .identifier) return false;
        const binding = self.view.getBinding(identifier) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const name = self.atomName(binding.name_atom) orelse return false;
        for (result_globals) |global| {
            if (std.mem.eql(u8, name, global)) return true;
        }
        return false;
    }

    fn atomName(self: *Lowerer, atom_index: u16) ?[]const u8 {
        const atom: engine_object.Atom = @fromBackingInt(@intCast(atom_index));
        if (self.resolver) |supplied| {
            if (supplied.atoms) |table| {
                if (atom.toPredefinedName()) |name| return name;
                return table.getName(atom);
            }
        }
        if (self.view.getString(atom_index)) |name| return name;
        return atom.toPredefinedName();
    }

    fn isResultCall(self: *Lowerer, node: NodeIndex) bool {
        const tag = self.view.getTag(node) orelse return false;
        if (tag != .call and tag != .method_call) return false;
        const call = self.view.getCall(node) orelse return false;
        if (self.isResultGlobal(call.callee)) return true;
        const func = self.builtinExport(call.callee) orelse return false;
        return func.returns == .result;
    }

    /// Which Result binding an identifier names. A reference inside a nested
    /// function is an upvalue, and the IR keeps the upvalue slot of the
    /// closure and the name, not the declaring scope. The reference resolves
    /// when exactly one Result binding has that name. A binding that is not a
    /// Result and shares the name only adds events to the closure, which the
    /// consumer treats as extra obligations and never as fewer.
    fn referenceOf(self: *Lowerer, identifier: NodeIndex) Reference {
        if (!self.results_active) return .none;
        if (self.view.getTag(identifier) != .identifier) return .none;
        const binding = self.view.getBinding(identifier) orelse return .none;
        var found: ?u32 = null;
        for (self.bindings, 0..) |declared, ordinal| {
            const same = if (binding.kind == .upvalue)
                declared.name_atom == binding.name_atom
            else
                declared.scope_id == binding.scope_id and declared.slot == binding.slot;
            if (!same) continue;
            if (found != null) return .ambiguous;
            found = @intCast(ordinal);
        }
        if (found) |ordinal| return .{ .ordinal = ordinal };
        return .none;
    }

    /// The ordinal of the binding that a declaration defines.
    fn definedOrdinal(self: *Lowerer, binding: ir.BindingRef) ?u32 {
        for (self.bindings, 0..) |declared, ordinal| {
            if (declared.scope_id == binding.scope_id and declared.slot == binding.slot) return @intCast(ordinal);
        }
        return null;
    }

    /// Number the Result bindings of the program. Returns false when the
    /// program cannot be classified: more bindings than the consumer accepts,
    /// or a namespace or default import of a builtin module, whose calls the
    /// classification does not resolve.
    fn classify(self: *Lowerer, list: *std.ArrayList(ResultBinding)) Error!bool {
        const facts = self.facts orelse return false;
        for (facts.imports.items) |record| {
            if (record.resolution == .builtin and record.import_kind != .named) return false;
        }
        const count = self.view.nodeCount();
        for (0..count) |position| {
            const node: NodeIndex = @intCast(position);
            if (self.view.getTag(node) != .var_decl) continue;
            const decl = self.view.getVarDecl(node) orelse continue;
            if (decl.init == null_node or !self.isResultCall(decl.init)) continue;
            if (list.items.len >= max_result_bindings) return false;
            try list.append(self.allocator, .{
                .scope_id = decl.binding.scope_id,
                .slot = decl.binding.slot,
                .name_atom = decl.binding.name_atom,
            });
        }
        return true;
    }

    /// Find the expression bodies of the function literals that sit at a
    /// `.result_fn` position. The parser wraps an arrow's expression body in a
    /// `return` node, and that node is listed. A block body is not listed: a
    /// `return` in it is an ordinary use.
    fn collectCallbackBodies(self: *Lowerer, list: *std.ArrayList(NodeIndex)) Error!void {
        for (0..self.view.nodeCount()) |position| {
            const node: NodeIndex = @intCast(position);
            const tag = self.view.getTag(node) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const call = self.view.getCall(node) orelse continue;
            const exported = self.builtinExport(call.callee) orelse continue;
            for (0..call.args_count) |index| {
                if (index >= exported.param_types.len or exported.param_types[index] != .result_fn) continue;
                const argument = self.view.getListIndex(call.args_start, @intCast(index));
                const argument_tag = self.view.getTag(argument) orelse continue;
                if (argument_tag != .arrow_function and argument_tag != .function_expr) continue;
                const function = self.view.getFunction(argument) orelse continue;
                const body_tag = self.view.getTag(function.body) orelse continue;
                if (body_tag != .return_stmt) continue;
                try list.append(self.allocator, function.body);
            }
        }
    }

    fn isCallbackBody(self: *Lowerer, index: NodeIndex) bool {
        for (self.callback_bodies) |body| {
            if (body == index) return true;
        }
        return false;
    }

    fn isEventSite(self: *Lowerer, index: NodeIndex) bool {
        if (self.view.getTag(index) != .identifier) return false;
        return switch (self.referenceOf(index)) {
            .ordinal, .ambiguous => true,
            .none => self.isResultGlobal(index) or
                (if (self.builtinExport(index)) |func| func.returns == .result else false),
        };
    }

    /// Whether a subtree holds any use of a Result binding or Result call.
    fn containsEventSite(self: *Lowerer, index: NodeIndex) bool {
        if (index == null_node or !self.results_active) return false;
        if (self.isEventSite(index)) return true;
        var children = self.view.expressionChildren(index);
        while (children.next()) |child| {
            if (self.containsEventSite(child)) return true;
        }
        return false;
    }

    /// Whether a subtree holds a function expression with an event inside.
    /// Such a function must become a function node, so that the events in its
    /// body reach the consumer.
    fn containsEventFunction(self: *Lowerer, index: NodeIndex) bool {
        if (index == null_node or !self.results_active) return false;
        const tag = self.view.getTag(index) orelse return false;
        if (tag == .function_expr or tag == .arrow_function) return self.containsEventSite(index);
        var children = self.view.expressionChildren(index);
        while (children.next()) |child| {
            if (self.containsEventFunction(child)) return true;
        }
        return false;
    }

    /// The guard event for an `if` condition that is exactly `b.ok` or
    /// `!b.ok`. Any other form of the condition is not a guard.
    fn guardEvent(self: *Lowerer, condition: NodeIndex) ?Tree {
        if (!self.results_active) return null;
        const tag = self.view.getTag(condition) orelse return null;
        var polarity: Tag = .result_guard_ok;
        var subject = condition;
        if (tag == .unary_op) {
            const unary = self.view.getUnary(condition) orelse return null;
            if (unary.op != .not) return null;
            polarity = .result_guard_err;
            subject = unary.operand;
        }
        if (self.view.getTag(subject) != .member_access) return null;
        const member = self.view.getMember(subject) orelse return null;
        if (member.computed != null_node or member.property != @backingInt(engine_object.Atom.ok)) return null;
        if (self.view.getTag(member.object) != .identifier) return null;
        return switch (self.referenceOf(member.object)) {
            .ordinal => |ordinal| event(polarity, ordinal),
            .none, .ambiguous => null,
        };
    }

    /// The events of one statement or expression, flat and in source order.
    /// The walk does not enter a nested function: that function is lowered as
    /// a node of its own and carries its own events.
    fn collectEvents(self: *Lowerer, out: *std.ArrayList(Tree), index: NodeIndex) Error!void {
        if (index == null_node) return;
        const tag = self.view.getTag(index) orelse return;
        switch (tag) {
            .var_decl => {
                const decl = self.view.getVarDecl(index) orelse return;
                if (decl.init == null_node) return;
                if (!self.isResultCall(decl.init)) return self.emitExpr(out, decl.init, .other, 0);
                if (self.definedOrdinal(decl.binding)) |ordinal| {
                    try out.append(self.allocator, event(.result_def, ordinal));
                }
                const call = self.view.getCall(decl.init) orelse return;
                try self.emitArguments(out, call, self.builtinExport(call.callee), 0);
            },
            .expr_stmt => {
                const operand = self.view.getOptValue(index) orelse return;
                try self.emitExpr(out, operand, .discard, 0);
            },
            else => {
                // The parser wraps the expression body of an arrow in a
                // `return`. At a `.result_fn` position the export consumes the
                // value that return carries.
                if (self.isCallbackBody(index)) {
                    const operand = self.view.getOptValue(index) orelse return;
                    return self.emitExpr(out, operand, .result_arg, 0);
                }
                try self.emitExpr(out, index, .other, 0);
            },
        }
    }

    fn emitExpr(
        self: *Lowerer,
        out: *std.ArrayList(Tree),
        node: NodeIndex,
        position: Position,
        depth: u16,
    ) Error!void {
        if (node == null_node) return;
        if (depth >= max_event_depth) {
            self.overflow = true;
            return;
        }
        const tag = self.view.getTag(node) orelse return;
        switch (tag) {
            .function_expr, .arrow_function, .function_decl => return,
            .identifier => switch (self.referenceOf(node)) {
                .ordinal => |ordinal| {
                    if (position != .result_arg) try out.append(self.allocator, event(.result_escape, ordinal));
                },
                .ambiguous => try out.append(self.allocator, event(.result_escape, 0)),
                .none => {
                    // A Result export named outside the callee position is an
                    // alias, and a call through the alias is not classified.
                    if (self.isResultGlobal(node)) try out.append(self.allocator, event(.result_escape, 0));
                    if (self.builtinExport(node)) |func| {
                        if (func.returns == .result) try out.append(self.allocator, event(.result_escape, 0));
                    }
                },
            },
            .member_access, .optional_chain, .computed_access => try self.emitMember(out, node, tag, position, depth),
            .binary_op => {
                const binary = self.view.getBinary(node) orelse return;
                const left: Position = if (binary.op == .nullish) .nullish_left else .other;
                try self.emitExpr(out, binary.left, left, depth + 1);
                try self.emitExpr(out, binary.right, .other, depth + 1);
            },
            .call, .method_call => try self.emitCall(out, node, position, depth),
            else => {
                var children = self.view.expressionChildren(node);
                while (children.next()) |child| try self.emitExpr(out, child, .other, depth + 1);
            },
        }
    }

    fn memberKind(self: *Lowerer, member: ir.Node.MemberExpr) MemberKind {
        if (member.computed != null_node) {
            if (self.view.getTag(member.computed) != .lit_string) return .other;
            const string_index = self.view.getStringIdx(member.computed) orelse return .other;
            const name = self.view.getString(string_index) orelse return .other;
            if (std.mem.eql(u8, name, "ok")) return .ok;
            if (std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "unwrap")) return .value;
            if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "errors")) return .failure;
            return .other;
        }
        if (member.property == @backingInt(engine_object.Atom.ok)) return .ok;
        if (member.property == @backingInt(engine_object.Atom.value) or member.property == @backingInt(engine_object.Atom.unwrap)) return .value;
        if (member.property == @backingInt(engine_object.Atom.@"error") or member.property == @backingInt(engine_object.Atom.errors)) return .failure;
        return .other;
    }

    fn emitMember(
        self: *Lowerer,
        out: *std.ArrayList(Tree),
        node: NodeIndex,
        tag: ir.NodeTag,
        position: Position,
        depth: u16,
    ) Error!void {
        const member = self.view.getMember(node) orelse return;
        const reference: Reference = if (self.view.getTag(member.object) == .identifier)
            self.referenceOf(member.object)
        else
            .none;
        switch (reference) {
            .none => {
                const object_position: Position = if (tag == .optional_chain) .optional_object else .other;
                try self.emitExpr(out, member.object, object_position, depth + 1);
            },
            .ambiguous => try out.append(self.allocator, event(.result_escape, 0)),
            .ordinal => |ordinal| switch (self.memberKind(member)) {
                .ok => {},
                .value => try out.append(self.allocator, event(.result_read_ok, ordinal)),
                .failure => {
                    // On an ok Result `.error` is undefined, so a read that
                    // supplies a fallback or chains optionally gets no payload.
                    if (position != .nullish_left and position != .optional_object) {
                        try out.append(self.allocator, event(.result_read_err, ordinal));
                    }
                },
                .other => try out.append(self.allocator, event(.result_escape, ordinal)),
            },
        }
        try self.emitExpr(out, member.computed, .other, depth + 1);
    }

    fn emitCall(
        self: *Lowerer,
        out: *std.ArrayList(Tree),
        node: NodeIndex,
        position: Position,
        depth: u16,
    ) Error!void {
        const call = self.view.getCall(node) orelse return;
        const exported = self.builtinExport(call.callee);
        if (self.isResultGlobal(call.callee)) {
            if (position != .discard and position != .result_arg) {
                try out.append(self.allocator, event(.result_escape, 0));
            }
        } else if (exported) |func| {
            // A Result nobody binds can only be discarded or passed to a
            // consumer that tests it. Anywhere else it flows on unchecked.
            if (func.returns == .result and position != .discard and position != .result_arg) {
                try out.append(self.allocator, event(.result_escape, 0));
            }
        } else {
            try self.emitExpr(out, call.callee, .other, depth + 1);
        }
        try self.emitArguments(out, call, exported, depth);
    }

    /// An argument at a position the export declares as a Result is read by
    /// that export, and each of those exports tests `ok` before it reads.
    fn emitArguments(
        self: *Lowerer,
        out: *std.ArrayList(Tree),
        call: ir.Node.CallExpr,
        exported: ?*const mb.FunctionBinding,
        depth: u16,
    ) Error!void {
        for (0..call.args_count) |position| {
            const argument = self.view.getListIndex(call.args_start, @intCast(position));
            var argument_position: Position = .other;
            if (exported) |func| {
                if (position < func.param_types.len) {
                    switch (func.param_types[position]) {
                        .result => argument_position = .result_arg,
                        .result_list => {
                            try self.emitResultList(out, argument, depth + 1);
                            continue;
                        },
                        // exhaustive: every other parameter kind passes no Result
                        // safely, so its argument is an ordinary use, emitted below.
                        else => {},
                    }
                }
            }
            try self.emitExpr(out, argument, argument_position, depth + 1);
        }
    }

    /// An array literal at a `.result_list` position holds Results that the
    /// export reads after it tests `ok`, so each element is a safe consumer
    /// position. Any other argument at the position is an ordinary use.
    fn emitResultList(
        self: *Lowerer,
        out: *std.ArrayList(Tree),
        argument: NodeIndex,
        depth: u16,
    ) Error!void {
        if (self.view.getTag(argument) != .array_literal) return self.emitExpr(out, argument, .other, depth);
        const array = self.view.getArray(argument) orelse return;
        for (0..array.elements_count) |position| {
            const element = self.view.getListIndex(array.elements_start, @intCast(position));
            try self.emitExpr(out, element, .result_arg, depth + 1);
        }
    }

    fn build(self: *Lowerer, index: NodeIndex) Error!Tree {
        if (self.depth >= max_depth) return error.ProgramTooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        const tag = self.view.getTag(index) orelse return self.leaf(.plain, index, 0);

        return switch (tag) {
            .program, .block => try self.sequence(index),
            .export_decl => blk: {
                const decl = self.view.getExportDecl(index) orelse break :blk try self.leaf(.plain, index, @backingInt(tag));
                var node = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(decl.declaration));
                break :blk node;
            },
            .function_decl => blk: {
                const decl = self.view.getVarDecl(index) orelse break :blk try self.leaf(.plain, index, @backingInt(tag));
                break :blk try self.build(decl.init);
            },
            .function_expr, .arrow_function => blk: {
                const func = self.view.getFunction(index) orelse break :blk try self.leaf(.plain, index, @backingInt(tag));
                var node = Tree{ .tag = .function, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                // The body is lowered on its own, so its statements collect
                // their own events even when an enclosing leaf collected the
                // events of the statement around this function.
                const saved_events_off = self.events_off;
                self.events_off = false;
                defer self.events_off = saved_events_off;
                try node.children.append(self.allocator, try self.build(func.body));
                break :blk node;
            },
            .if_stmt => blk: {
                const stmt = self.view.getIfStmt(index) orelse break :blk try self.leaf(.plain, index, @backingInt(tag));
                var branch = Tree{ .tag = .branch, .source = index, .leaf_kind = 0 };
                errdefer branch.deinit(self.allocator);
                try branch.children.append(self.allocator, try self.build(stmt.then_branch));
                // An `if` with no `else` has one arm, and one arm is exactly why
                // it cannot establish totality. The shape says so.
                if (stmt.else_branch != null_node) {
                    try branch.children.append(self.allocator, try self.build(stmt.else_branch));
                }
                // A condition that is exactly `b.ok` or `!b.ok` guards the
                // Result `b`. The guard heads a wrapper of two children, the
                // same shape that a guarded call in a condition gets.
                if (self.guardEvent(stmt.condition)) |guard| {
                    // The consumer reads an arm of a guarded branch only when
                    // the branch has two arms. An absent `else` becomes an
                    // empty statement, which returns nothing, exactly as the
                    // absent arm did.
                    if (stmt.else_branch == null_node) {
                        try branch.children.append(self.allocator, .{ .tag = .plain, .source = null_node, .leaf_kind = 0 });
                    }
                    var wrapper = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
                    errdefer wrapper.deinit(self.allocator);
                    try wrapper.children.append(self.allocator, guard);
                    try wrapper.children.append(self.allocator, branch);
                    break :blk wrapper;
                }
                if (!self.containsRelevantCall(stmt.condition) and !self.containsEventSite(stmt.condition)) break :blk branch;

                // Keep the branch's two-arm totality shape intact. The outer
                // sequence carries only the guarded condition path, which adds
                // the residual obligation without letting an expression claim
                // that either branch returns.
                var node = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(stmt.condition));
                try node.children.append(self.allocator, branch);
                break :blk node;
            },
            .for_of_stmt, .for_in_stmt => blk: {
                const loop = self.view.getForIter(index) orelse break :blk try self.leaf(.loop_node, index, @backingInt(tag));
                var node = Tree{ .tag = .loop_node, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try self.appendGuarded(&node, loop.iterable);
                try node.children.append(self.allocator, try self.build(loop.body));
                break :blk node;
            },
            .for_stmt, .while_stmt, .do_while_stmt => blk: {
                const loop = self.view.getLoop(index) orelse break :blk try self.leaf(.loop_node, index, @backingInt(tag));
                var node = Tree{ .tag = .loop_node, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try self.appendGuarded(&node, loop.init);
                try self.appendGuarded(&node, loop.condition);
                try self.appendGuarded(&node, loop.update);
                try node.children.append(self.allocator, try self.build(loop.body));
                break :blk node;
            },
            .return_stmt => try self.leaf(.return_node, index, @backingInt(tag)),
            else => try self.leaf(.plain, index, @backingInt(tag)),
        };
    }

    fn sequence(self: *Lowerer, index: NodeIndex) Error!Tree {
        const block = self.view.getBlock(index) orelse return self.leaf(.plain, index, 0);
        var node = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
        errdefer node.deinit(self.allocator);
        for (0..block.stmts_count) |i| {
            const child = self.view.getListIndex(block.stmts_start, @intCast(i));
            try node.children.append(self.allocator, try self.build(child));
        }
        return node;
    }

    fn appendGuarded(self: *Lowerer, parent: *Tree, child: NodeIndex) Error!void {
        if (child == null_node) return;
        if (!self.containsRelevantCall(child) and !self.containsEventSite(child)) return;
        try parent.children.append(self.allocator, try self.build(child));
    }

    /// A node with no structural children of its own.
    ///
    /// When its subtree holds a guarded call, the node keeps children after all:
    /// just the paths that lead to one. When it uses a Result binding, the
    /// events of the whole statement become its first children, flat and in
    /// source order. A handler with neither gets the leaf it got before, so its
    /// proof identity does not move.
    fn leaf(self: *Lowerer, tag: Tag, index: NodeIndex, kind: u16) Error!Tree {
        var events: std.ArrayList(Tree) = .empty;
        defer events.deinit(self.allocator);
        errdefer for (events.items) |*item| item.deinit(self.allocator);
        if (self.results_active and !self.events_off) try self.collectEvents(&events, index);

        if (self.guardedIndex(index)) |catalog_index| {
            const call = Tree{
                .tag = .capability_call,
                .source = index,
                .leaf_kind = kind,
                .aux = catalog_index,
            };
            if (events.items.len == 0) return call;
            // One node cannot be both a guarded call and the parent of events,
            // so a wrapper without a parser source holds both. The witness of
            // the call stays on the call.
            var wrapper = Tree{ .tag = .plain, .source = null_node, .leaf_kind = kind };
            errdefer wrapper.deinit(self.allocator);
            try wrapper.children.append(self.allocator, call);
            try wrapper.children.appendSlice(self.allocator, events.items);
            events.clearRetainingCapacity();
            return wrapper;
        }
        const descend = self.containsRelevantCall(index) or self.containsEventFunction(index);
        if (!descend and events.items.len == 0) {
            return .{ .tag = tag, .source = index, .leaf_kind = kind };
        }

        var node = Tree{ .tag = tag, .source = index, .leaf_kind = kind };
        errdefer node.deinit(self.allocator);
        try node.children.appendSlice(self.allocator, events.items);
        events.clearRetainingCapacity();
        if (!descend) return node;

        const Collector = struct {
            lowerer: *Lowerer,
            parent: *Tree,
            failed: ?Error = null,

            fn visit(ctx: *@This(), lowerer: *Lowerer, child: NodeIndex) void {
                if (ctx.failed != null) return;
                if (child == null_node) return;
                if (!lowerer.containsRelevantCall(child) and !lowerer.containsEventFunction(child)) return;
                // This leaf collected the events of the whole statement, so
                // the nodes below it collect none, until a function begins.
                const saved_events_off = lowerer.events_off;
                lowerer.events_off = true;
                defer lowerer.events_off = saved_events_off;
                const built = lowerer.build(child) catch |err| {
                    ctx.failed = err;
                    return;
                };
                ctx.parent.children.append(lowerer.allocator, built) catch |err| {
                    ctx.failed = err;
                };
            }
        };
        var collector = Collector{ .lowerer = self, .parent = &node };
        self.forEachSubNode(index, &collector, Collector.visit);
        if (collector.failed) |err| return err;
        return node;
    }
};

fn digestTree(node: *Tree) void {
    for (node.children.items) |*child| digestTree(child);

    var hasher = Sha256.init(.{});
    hasher.update(node_domain);
    var tag_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &tag_le, @backingInt(node.tag), .little);
    hasher.update(&tag_le);
    var kind_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &kind_le, node.leaf_kind, .little);
    hasher.update(&kind_le);
    var aux_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &aux_le, node.aux, .little);
    hasher.update(&aux_le);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, @intCast(node.children.items.len), .little);
    hasher.update(&count_le);
    for (node.children.items) |child| hasher.update(&child.digest);
    node.digest = hasher.finalResult();
}

/// Lower a parsed program into the proof IR.
///
/// Node ids are assigned breadth first, so a node's children occupy one
/// contiguous id range and the wire form can address them with a start and a
/// count. Digests are computed bottom up over shape alone, so a source-line
/// change leaves the proof identity where it was and a structural change moves
/// it.
pub fn lower(
    allocator: std.mem.Allocator,
    view: IrView,
    root: NodeIndex,
    handler_source: ?NodeIndex,
    resolver: ?Resolver,
) Error!ProofIr {
    var lowerer = Lowerer{ .allocator = allocator, .view = view, .resolver = resolver };
    var facts: ?module_facts_mod.ModuleFacts = null;
    defer if (facts) |*value| value.deinit();
    var bindings: std.ArrayList(ResultBinding) = .empty;
    defer bindings.deinit(allocator);
    var callback_bodies: std.ArrayList(NodeIndex) = .empty;
    defer callback_bodies.deinit(allocator);
    if (resolver) |supplied| {
        facts = try module_facts_mod.ModuleFacts.build(allocator, view, supplied.atoms, null);
        lowerer.facts = &facts.?;
        if (try lowerer.classify(&bindings)) {
            try lowerer.collectCallbackBodies(&callback_bodies);
            lowerer.bindings = bindings.items;
            lowerer.callback_bodies = callback_bodies.items;
            lowerer.results_active = true;
        }
    }
    var tree = try lowerer.build(root);
    defer tree.deinit(allocator);
    digestTree(&tree);

    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    const Frame = struct { tree: *const Tree, id: u32, parent: u32 };
    var queue: std.ArrayList(Frame) = .empty;
    defer queue.deinit(allocator);

    try nodes.append(allocator, .{
        .id = 0,
        .tag = tree.tag,
        .parent = 0,
        .first_child = 0,
        .child_count = @intCast(tree.children.items.len),
        .digest = tree.digest,
        .source = tree.source,
        .aux = tree.aux,
    });
    try queue.append(allocator, .{ .tree = &tree, .id = 0, .parent = 0 });

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const frame = queue.items[head];
        const first_child: u32 = @intCast(nodes.items.len);
        nodes.items[frame.id].first_child = if (frame.tree.children.items.len == 0) 0 else first_child;
        for (frame.tree.children.items) |*child| {
            const id: u32 = @intCast(nodes.items.len);
            try nodes.append(allocator, .{
                .id = id,
                .tag = child.tag,
                .parent = frame.id,
                .first_child = 0,
                .child_count = @intCast(child.children.items.len),
                .digest = child.digest,
                .source = child.source,
                .aux = child.aux,
            });
            try queue.append(allocator, .{ .tree = child, .id = id, .parent = frame.id });
        }
    }

    const owned = try nodes.toOwnedSlice(allocator);
    var handler_function: ?u32 = null;
    if (handler_source) |source| {
        for (owned) |node| {
            if (node.source == source and node.tag == .function) {
                handler_function = node.id;
                break;
            }
        }
    }
    return .{
        .allocator = allocator,
        .nodes = owned,
        .handler_function = handler_function,
        .results_classified = lowerer.results_active and !lowerer.overflow,
    };
}

// ---------------------------------------------------------------------------
// Totality
// ---------------------------------------------------------------------------

/// Whether each node always returns, folded over the proof IR alone.
///
/// The consumer runs the same fold. This copy exists so the producer can tell,
/// before it writes a certificate, whether the claim it is about to make is one
/// the consumer will confirm - not so that the consumer can read the answer.
pub fn deriveTotality(
    allocator: std.mem.Allocator,
    proof: ProofIr,
    declared: []const u32,
) Error![]bool {
    const total = try allocator.alloc(bool, proof.nodes.len);
    errdefer allocator.free(total);
    @memset(total, false);

    // Children always have higher ids than their parent, so one reverse sweep
    // settles the fold.
    var index: usize = proof.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = proof.nodes[index];
        total[index] = switch (node.tag) {
            .return_node => true,
            .function => firstChildTotal(proof, total, node),
            .sequence => anyChildTotal(proof, total, node),
            .branch => node.child_count == 2 and allChildrenTotal(proof, total, node),
            .loop_node, .plain, .capability_call => false,
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => false,
        };
        for (declared) |declared_id| {
            if (declared_id == node.id) total[index] = true;
        }
    }
    return total;
}

fn firstChildTotal(proof: ProofIr, total: []const bool, node: Node) bool {
    if (node.child_count == 0) return false;
    return proof.nodes[node.first_child].tag != .function and total[node.first_child];
}

fn anyChildTotal(proof: ProofIr, total: []const bool, node: Node) bool {
    var i: u32 = 0;
    while (i < node.child_count) : (i += 1) {
        const child = proof.nodes[node.first_child + i];
        // A function's body returns only when called, not when declared.
        if (child.tag != .function and total[child.id]) return true;
    }
    return false;
}

fn allChildrenTotal(proof: ProofIr, total: []const bool, node: Node) bool {
    if (node.child_count == 0) return false;
    var i: u32 = 0;
    while (i < node.child_count) : (i += 1) {
        const child = proof.nodes[node.first_child + i];
        if (child.tag == .function or !total[child.id]) return false;
    }
    return true;
}

/// The rule that discharges totality at `id`, when one does.
pub fn ruleAt(proof: ProofIr, total: []const bool, id: u32) ?Rule {
    const node = proof.nodes[id];
    return switch (node.tag) {
        .return_node => .return_total,
        .sequence => if (anyChildTotal(proof, total, node)) .sequence_member_total else null,
        .branch => if (node.child_count == 2 and allChildrenTotal(proof, total, node))
            .branch_both_arms_total
        else
            null,
        .loop_node => .loop_never_total,
        .function, .plain, .capability_call => null,
        .result_def,
        .result_guard_ok,
        .result_guard_err,
        .result_read_ok,
        .result_read_err,
        .result_escape,
        => null,
    };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// The depth limit of the consumer's walk from a read to its function.
const max_read_depth: u32 = 256;

/// Whether every read of a Result value in the proof IR is guarded, folded over
/// the proof IR alone.
///
/// The consumer runs the same pass. This copy exists so the producer can tell,
/// before it writes a certificate, whether the claim it is about to make is one
/// the consumer will confirm. It reads totality from a fold that ignores
/// declared nodes, as the consumer does, so an arm counts as returning only
/// when its own shape returns.
pub fn deriveResults(allocator: std.mem.Allocator, proof: ProofIr) Error!bool {
    if (!proof.results_classified) return false;

    const derived = try allocator.alloc(bool, proof.nodes.len);
    defer allocator.free(derived);
    @memset(derived, false);
    var index: usize = proof.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = proof.nodes[index];
        derived[index] = switch (node.tag) {
            .return_node => true,
            .function => firstChildTotal(proof, derived, node),
            .sequence => anyChildTotal(proof, derived, node),
            .branch => node.child_count == 2 and allChildrenTotal(proof, derived, node),
            .loop_node,
            .plain,
            .capability_call,
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => false,
        };
    }

    var defined = @as([max_result_bindings]bool, @splat(false));
    for (proof.nodes) |node| {
        switch (node.tag) {
            .result_escape => return false,
            .result_def, .result_guard_ok, .result_guard_err, .result_read_ok, .result_read_err => {
                if (node.aux >= max_result_bindings) return false;
            },
            .function, .sequence, .branch, .loop_node, .return_node, .plain, .capability_call => {},
        }
        switch (node.tag) {
            .result_def => {
                if (defined[node.aux]) return false;
                defined[node.aux] = true;
            },
            .result_guard_ok, .result_guard_err => {
                if (!guardWellFormed(proof, node)) return false;
            },
            .result_read_ok,
            .result_read_err,
            .result_escape,
            .function,
            .sequence,
            .branch,
            .loop_node,
            .return_node,
            .plain,
            .capability_call,
            => {},
        }
    }

    for (proof.nodes) |node| {
        if (node.tag != .result_read_ok and node.tag != .result_read_err) continue;
        if (!defined[node.aux]) return false;
        if (!readGuarded(proof, derived, node)) return false;
    }
    return true;
}

/// A guard is the first of exactly two children of a sequence, and the second
/// child is the branch it tests.
fn guardWellFormed(proof: ProofIr, guard: Node) bool {
    const parent = proof.nodes[guard.parent];
    if (parent.tag != .sequence or parent.child_count != 2 or parent.first_child != guard.id) return false;
    return proof.nodes[guard.id + 1].tag == .branch;
}

/// Walk from a read to the enclosing function. The read is covered when an
/// ancestor branch is an arm of a guard on the same binding, or when an earlier
/// statement is a guard whose then arm always returns. The walk stops at a
/// function: a closure never inherits a check from outside.
fn readGuarded(proof: ProofIr, derived: []const bool, read: Node) bool {
    var current = read;
    var steps: u32 = 0;
    while (current.id != 0) {
        steps += 1;
        if (steps > max_read_depth) return false;
        const parent = proof.nodes[current.parent];
        switch (parent.tag) {
            .function => return false,
            .branch => if (armCovers(proof, parent, current, read)) return true,
            .sequence => if (earlierGuardCovers(proof, derived, parent, current, read)) return true,
            .loop_node,
            .return_node,
            .plain,
            .capability_call,
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => {},
        }
        current = parent;
    }
    return false;
}

fn armCovers(proof: ProofIr, branch: Node, arm: Node, read: Node) bool {
    if (branch.child_count != 2) return false;
    const wrapper = proof.nodes[branch.parent];
    if (wrapper.tag != .sequence or wrapper.child_count != 2 or wrapper.first_child + 1 != branch.id) return false;
    const guard = proof.nodes[wrapper.first_child];
    if (guard.aux != read.aux) return false;
    const in_then = arm.id == branch.first_child;
    return switch (guard.tag) {
        .result_guard_ok => (read.tag == .result_read_ok) == in_then,
        .result_guard_err => (read.tag == .result_read_ok) != in_then,
        .function,
        .sequence,
        .branch,
        .loop_node,
        .return_node,
        .plain,
        .capability_call,
        .result_def,
        .result_read_ok,
        .result_read_err,
        .result_escape,
        => false,
    };
}

fn earlierGuardCovers(proof: ProofIr, derived: []const bool, sequence: Node, current: Node, read: Node) bool {
    var id = sequence.first_child;
    while (id < current.id) : (id += 1) {
        const sibling = proof.nodes[id];
        if (sibling.tag != .sequence or sibling.child_count != 2) continue;
        const guard = proof.nodes[sibling.first_child];
        if (guard.aux != read.aux) continue;
        const covers_ok = switch (guard.tag) {
            .result_guard_err => true,
            .result_guard_ok => false,
            .function,
            .sequence,
            .branch,
            .loop_node,
            .return_node,
            .plain,
            .capability_call,
            .result_def,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => continue,
        };
        if (covers_ok != (read.tag == .result_read_ok)) continue;
        const branch = proof.nodes[sibling.first_child + 1];
        if (branch.tag != .branch or branch.child_count == 0) continue;
        const then_arm = proof.nodes[branch.first_child];
        if (then_arm.tag != .function and derived[then_arm.id]) return true;
    }
    return false;
}

/// Whether the proof IR holds any Result event.
pub fn hasResultEvents(proof: ProofIr) bool {
    for (proof.nodes) |node| {
        switch (node.tag) {
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => return true,
            .function, .sequence, .branch, .loop_node, .return_node, .plain, .capability_call => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------

/// Everything the producer knows about one compiled handler that a certificate
/// can carry, with the translation witnesses already moved onto proof-IR ids.
///
/// This is a carrier, not a claim. Whether it adds up is the consumer's
/// question, and the consumer re-derives the totality fold rather than reading
/// `total` from here.
pub const Evidence = struct {
    allocator: std.mem.Allocator,
    proof: ProofIr,
    /// The producer's own fold, kept so it can refuse to emit a certificate for
    /// a handler the consumer would reject.
    total: []bool,
    /// Nodes whose totality the certificate declares rather than proves.
    declared: []u32,
    /// Whether the proof IR holds Result events and the producer's copy of the
    /// consumer's pass accepts them. A program with no Result binding is not
    /// proved here: there is nothing for the pass to say about it.
    results_proved: bool,
    emissions: []Emission,
    jumps: []Jump,
    rewrites: []translation_witness.Rewrite,
    pre_optimization_len: u32,
    final_len: u32,

    pub fn deinit(self: *Evidence) void {
        self.proof.deinit();
        self.allocator.free(self.total);
        self.allocator.free(self.declared);
        self.allocator.free(self.emissions);
        self.allocator.free(self.jumps);
        self.allocator.free(self.rewrites);
    }

    /// Whether the handler function is total under this evidence.
    pub fn handlerIsTotal(self: *const Evidence) bool {
        const id = self.proof.handler_function orelse return false;
        return self.total[id];
    }
};

/// A translation witness whose subject is a proof-IR node rather than a parser
/// node.
pub const Emission = struct {
    /// Pre-order function position in the serialized bytecode stream. The
    /// runtime enumerates the same final function buffers independently.
    function_ordinal: u32,
    /// The function whose code buffer this offset is measured in, as a proof-IR
    /// node id. The module's own function is node 0.
    scope: u32,
    node: u32,
    code_start: u32,
    code_len: u32,
};

pub const Jump = struct {
    scope: u32,
    node: u32,
    instruction_offset: u32,
    target_node: u32,
    target_offset: u32,
};

/// Assemble the evidence for one compiled handler.
///
/// `recorder` is the translation evidence code generation captured, or null for
/// a compile that did not record any. A run with no recorder yields evidence
/// with no witnesses, which a certificate reports as a weaker translation edge
/// rather than as a stronger one with the offsets omitted.
pub fn buildEvidence(
    allocator: std.mem.Allocator,
    view: IrView,
    root: NodeIndex,
    handler_source: NodeIndex,
    recorder: ?*const translation_witness.Recorder,
    resolver: ?Resolver,
) Error!Evidence {
    var proof = try lower(allocator, view, root, handler_source, resolver);
    errdefer proof.deinit();

    // No node in this alphabet needs a declared edge: the fold decides every
    // one of the six tags. The field stays because the certificate format has
    // the concept and the kernel checks it; the producer has nothing to put in
    // it today, and saying so beats emitting an empty mechanism that looks used.
    const declared: []u32 = try allocator.alloc(u32, 0);
    errdefer allocator.free(declared);
    const total = try deriveTotality(allocator, proof, declared);
    errdefer allocator.free(total);
    const results_proved = hasResultEvents(proof) and try deriveResults(allocator, proof);

    var emissions: std.ArrayList(Emission) = .empty;
    errdefer emissions.deinit(allocator);
    var jumps: std.ArrayList(Jump) = .empty;
    errdefer jumps.deinit(allocator);
    var rewrites: std.ArrayList(translation_witness.Rewrite) = .empty;
    errdefer rewrites.deinit(allocator);

    var pre_len: u32 = 0;
    var final_len: u32 = 0;

    if (recorder) |rec| {
        for (rec.scopes.items, 0..) |scope, scope_index| {
            // The module's buffer is the proof IR's root; a nested function's
            // buffer is the node that function lowered to.
            const scope_id: u32 = if (scope.node == translation_witness.module_scope)
                0
            else
                proof.nodeFor(scope.node) orelse continue;

            if (scope.node == translation_witness.module_scope) {
                pre_len = scope.pre_optimization_len;
                final_len = scope.final_len;
            }

            for (scope.emissions.items) |emission| {
                const id = proof.nodeFor(emission.node) orelse continue;
                try emissions.append(allocator, .{
                    .function_ordinal = @intCast(scope_index),
                    .scope = scope_id,
                    .node = id,
                    .code_start = emission.code_start,
                    .code_len = emission.code_len,
                });
            }
            for (scope.jumps.items) |jump| {
                const id = proof.nodeFor(jump.node) orelse continue;
                // A jump's target is an offset, not a node. It is only a
                // relation the consumer can check when some member's code
                // starts exactly there - a jump past the end of a branch, or
                // into the middle of one, lands where nothing begins. Those are
                // dropped rather than pointed at a node they do not name: a
                // witness the consumer cannot check is worse than one absent,
                // because the absent one does not claim anything.
                var target_node: ?u32 = null;
                for (scope.emissions.items) |candidate| {
                    if (candidate.code_start != jump.target_offset) continue;
                    target_node = proof.nodeFor(candidate.node) orelse continue;
                    break;
                }
                try jumps.append(allocator, .{
                    .scope = scope_id,
                    .node = id,
                    .instruction_offset = jump.instruction_offset,
                    .target_node = target_node orelse continue,
                    .target_offset = jump.target_offset,
                });
            }
            try rewrites.appendSlice(allocator, scope.rewrites.items);
        }
    }

    return .{
        .allocator = allocator,
        .proof = proof,
        .total = total,
        .declared = declared,
        .results_proved = results_proved,
        .emissions = try emissions.toOwnedSlice(allocator),
        .jumps = try jumps.toOwnedSlice(allocator),
        .rewrites = try rewrites.toOwnedSlice(allocator),
        .pre_optimization_len = pre_len,
        .final_len = final_len,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = @import("zts-engine").parser.JsParser;

const Lowered = struct {
    allocator: std.mem.Allocator,
    parser: *JsParser,
    proof: ProofIr,

    fn deinit(self: *Lowered) void {
        self.proof.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
    }
};

/// A stand-in for the compiler's import resolution: every call site is the
/// guarded export named by `row`. The real resolver in `precompile` resolves the
/// callee to a module and export first; this one exists so the lowering itself
/// can be tested without the import machinery.
const EveryCallResolver = struct {
    row: u32,

    fn resolve(context: *const anyopaque, _: NodeIndex) ?u32 {
        const self: *const EveryCallResolver = @ptrCast(@alignCast(context));
        return self.row;
    }

    fn resolver(self: *const EveryCallResolver) Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};

fn parseAndLower(allocator: std.mem.Allocator, source: []const u8) !Lowered {
    return parseAndLowerWith(allocator, source, null);
}

fn parseAndLowerWith(
    allocator: std.mem.Allocator,
    source: []const u8,
    resolver: ?Resolver,
) !Lowered {
    const parser = try allocator.create(JsParser);
    errdefer allocator.destroy(parser);
    parser.* = try JsParser.initAdmission(allocator, allocator, source, .compile);
    errdefer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_source = handler_function_mod.findHandlerFunction(view, root);
    const proof = try lower(allocator, view, root, handler_source, resolver);
    return .{ .allocator = allocator, .parser = parser, .proof = proof };
}

test "a handler that always returns is total, and the shape says which rule" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return Response.text("ok");
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);

    try testing.expect(total[function_id]);
    const body = proof.nodes[function_id].first_child;
    try testing.expectEqual(Rule.sequence_member_total, ruleAt(proof, total, body).?);
}

test "an if without an else does not establish totality" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(!total[function_id]);
}

test "declaring a returning helper does not return from its enclosing handler" {
    for ([_][]const u8{
        "function handler(req) { function helper() { return Response.text(\"helper\"); } }",
        "function handler(req) { if (req.method === \"GET\") { function a() { return Response.text(\"a\"); } } else { function b() { return Response.text(\"b\"); } } }",
    }) |source| {
        var lowered = try parseAndLower(testing.allocator, source);
        defer lowered.deinit();
        const proof = lowered.proof;
        const total = try deriveTotality(testing.allocator, proof, &.{});
        defer testing.allocator.free(total);
        const handler = proof.handler_function orelse return error.TestUnexpectedResult;
        try testing.expect(!total[handler]);
        try testing.expectEqual(@as(?Rule, null), ruleAt(proof, total, proof.nodes[handler].first_child));
        for (proof.nodes) |node| {
            if (node.tag == .function and node.id != handler) try testing.expect(total[node.id]);
        }
    }
}

test "an if with both arms returning is total" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  } else {
        \\    return Response.text("no");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(total[function_id]);

    var branch_id: ?u32 = null;
    for (proof.nodes) |node| {
        if (node.tag == .branch) branch_id = node.id;
    }
    try testing.expectEqual(Rule.branch_both_arms_total, ruleAt(proof, total, branch_id.?).?);
}

test "a loop body never establishes totality" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  for (const item of req.items) {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(!total[function_id]);

    for (proof.nodes) |node| {
        if (node.tag != .loop_node) continue;
        try testing.expect(!total[node.id]);
        try testing.expectEqual(Rule.loop_never_total, ruleAt(proof, total, node.id).?);
    }
}

test "lowering is deterministic and children are contiguous" {
    const allocator = testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("a");
        \\  } else {
        \\    return Response.text("b");
        \\  }
        \\}
    ;
    var first = try parseAndLower(allocator, source);
    defer first.deinit();
    var second = try parseAndLower(allocator, source);
    defer second.deinit();

    try testing.expectEqual(first.proof.nodes.len, second.proof.nodes.len);
    for (first.proof.nodes, second.proof.nodes) |a, b| {
        try testing.expectEqual(a.tag, b.tag);
        try testing.expectEqual(a.first_child, b.first_child);
        try testing.expectEqual(a.child_count, b.child_count);
        try testing.expectEqualSlices(u8, &a.digest, &b.digest);
    }

    // Every child id sits inside its parent's declared range, and every parent
    // link points back. A wire form addressing children by start and count is
    // only meaningful while that holds.
    for (first.proof.nodes) |node| {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            const child = first.proof.nodes[node.first_child + i];
            try testing.expectEqual(node.id, child.parent);
            try testing.expect(child.id > node.id);
        }
    }
}

test "proof identity ignores source position and follows structure" {
    const allocator = testing.allocator;
    var plain = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return Response.text("ok");
        \\}
    );
    defer plain.deinit();
    var spaced = try parseAndLower(allocator,
        \\
        \\
        \\function handler(req) {
        \\
        \\  return Response.text("ok");
        \\
        \\}
    );
    defer spaced.deinit();
    try testing.expectEqualSlices(
        u8,
        &plain.proof.nodes[0].digest,
        &spaced.proof.nodes[0].digest,
    );

    var changed = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  } else {
        \\    return Response.text("no");
        \\  }
        \\}
    );
    defer changed.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &plain.proof.nodes[0].digest,
        &changed.proof.nodes[0].digest,
    ));
}

test "a match is an expression, so it never carries totality" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return match (req.method) {
        \\    when "GET": Response.text("get"),
        \\    default: Response.text("other")
        \\  };
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);

    // The `return` is what makes the handler total. The match under it is an
    // expression and contributes nothing, which is why the alphabet has no tag
    // for it: a tag here would be a member no rule could ever be checked
    // against.
    try testing.expect(total[function_id]);
    var returns: usize = 0;
    for (proof.nodes) |node| {
        if (node.tag == .return_node) returns += 1;
    }
    try testing.expectEqual(@as(usize, 1), returns);
}

test "a guarded call is reachable wherever an expression is" {
    const allocator = testing.allocator;
    var resolver_state = EveryCallResolver{ .row = 3 };
    const resolver = resolver_state.resolver();

    // Inside a return, which the fold treats as a leaf. Before this lowering
    // learned to descend, a guarded call here was invisible.
    var in_return = try parseAndLowerWith(allocator,
        \\function handler(req) {
        \\  return env("API_KEY");
        \\}
    , resolver);
    defer in_return.deinit();
    try testing.expectEqual(@as(usize, 1), countTag(in_return.proof, .capability_call));
    try testing.expectEqual(@as(u32, 3), guardedAux(in_return.proof).?);

    // Inside an initializer.
    var in_init = try parseAndLowerWith(allocator,
        \\function handler(req) {
        \\  const value = env("API_KEY");
        \\  return Response.text(value);
        \\}
    , resolver);
    defer in_init.deinit();
    try testing.expect(countTag(in_init.proof, .capability_call) >= 1);
    // EveryCallResolver admits every call, so the source's two calls, env and
    // Response.text, give two nodes, each at row 3.
    try testing.expectEqual(@as(usize, 2), countTag(in_init.proof, .capability_call));
    try testing.expectEqual(@as(u32, 3), guardedAux(in_init.proof).?);

    const control_flow_cases = [_][]const u8{
        \\function handler(req) {
        \\  if (env("API_KEY")) {
        \\    return "set";
        \\  } else {
        \\    return "missing";
        \\  }
        \\}
        ,
        \\function handler(req) {
        \\  for (const current of env("API_KEY")) {
        \\    return current;
        \\  }
        \\  return "missing";
        \\}
        ,
    };
    for (control_flow_cases, 0..) |source, index| {
        var lowered = parseAndLowerWith(allocator, source, resolver) catch |err| {
            std.debug.print("control-flow guard case {d} did not parse: {s}\n", .{ index, @errorName(err) });
            return err;
        };
        defer lowered.deinit();
        try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .capability_call));
    }

    // The handler is still total: a guarded call establishes nothing about
    // returning, and it must not take that away either.
    const function_id = in_return.proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, in_return.proof, &.{});
    defer allocator.free(total);
    try testing.expect(total[function_id]);
}

test "a handler with no guarded call lowers exactly as it did before" {
    const allocator = testing.allocator;
    var resolver_state = EveryCallResolver{ .row = 0 };
    const source =
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("a");
        \\  } else {
        \\    return Response.text("b");
        \\  }
        \\}
    ;

    var without = try parseAndLower(allocator, source);
    defer without.deinit();

    // With a resolver that guards nothing, the shape and the identity are the
    // same. A literal-only artifact's proof identity must not move because the
    // lowering gained the ability to see guarded calls.
    var never = NeverResolver{};
    var with_none = try parseAndLowerWith(allocator, source, never.resolver());
    defer with_none.deinit();

    try testing.expectEqual(without.proof.nodes.len, with_none.proof.nodes.len);
    try testing.expectEqualSlices(
        u8,
        &without.proof.nodes[0].digest,
        &with_none.proof.nodes[0].digest,
    );
    _ = &resolver_state;
}

test "a guarded call at a different catalog row is a different member" {
    const allocator = testing.allocator;
    const source =
        \\function handler(req) {
        \\  return env("API_KEY");
        \\}
    ;
    var row_one = EveryCallResolver{ .row = 1 };
    var row_two = EveryCallResolver{ .row = 2 };

    var first = try parseAndLowerWith(allocator, source, row_one.resolver());
    defer first.deinit();
    var second = try parseAndLowerWith(allocator, source, row_two.resolver());
    defer second.deinit();

    // The catalog row is folded into the digest, so pointing an operation at a
    // different guard changes the proof identity rather than passing silently.
    try testing.expect(!std.mem.eql(
        u8,
        &first.proof.nodes[0].digest,
        &second.proof.nodes[0].digest,
    ));
}

fn countTag(proof: ProofIr, tag: Tag) usize {
    var count: usize = 0;
    for (proof.nodes) |node| {
        if (node.tag == tag) count += 1;
    }
    return count;
}

fn guardedAux(proof: ProofIr) ?u32 {
    for (proof.nodes) |node| {
        if (node.tag == .capability_call) return node.aux;
    }
    return null;
}

const NeverResolver = struct {
    fn never(_: *const anyopaque, _: NodeIndex) ?u32 {
        return null;
    }

    fn resolver(self: *const NeverResolver) Resolver {
        return .{ .context = self, .resolve = never };
    }
};

test "every tag in the alphabet is reachable from real source" {
    const allocator = testing.allocator;
    var seen = std.EnumSet(Tag).empty;

    const sources = [_][]const u8{
        // function, sequence, return
        \\function handler(req) {
        \\  return Response.text("ok");
        \\}
        ,
        // branch
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("a");
        \\  } else {
        \\    return Response.text("b");
        \\  }
        \\}
        ,
        // loop, plain
        \\function handler(req) {
        \\  const items = [1, 2];
        \\  for (const item of items) {
        \\    const x = item;
        \\  }
        \\  return Response.text("ok");
        \\}
        ,
    };

    for (sources) |source| {
        var lowered = try parseAndLower(allocator, source);
        defer lowered.deinit();
        for (lowered.proof.nodes) |node| seen.insert(node.tag);
    }

    // The guarded tag needs a resolver to appear at all, which is the point:
    // without one the lowering cannot know a call is guarded, and it must not
    // guess.
    var guarded_resolver = EveryCallResolver{ .row = 0 };
    var guarded = try parseAndLowerWith(allocator,
        \\function handler(req) {
        \\  return env("API_KEY");
        \\}
    , guarded_resolver.resolver());
    defer guarded.deinit();
    for (guarded.proof.nodes) |node| seen.insert(node.tag);

    // The Result events need a resolver too, and a Result binding that the
    // handler uses in every way the lowering names.
    var never_resolver = NeverResolver{};
    var results = try parseAndLowerWith(allocator, result_source, never_resolver.resolver());
    defer results.deinit();
    for (results.proof.nodes) |node| seen.insert(node.tag);
    var positive = try parseAndLowerWith(allocator,
        \\import { validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  const r = validateJson("a", "b");
        \\  if (r.ok) {
        \\    return Response.text(r.value);
        \\  }
        \\  return Response.text("no");
        \\}
    , never_resolver.resolver());
    defer positive.deinit();
    for (positive.proof.nodes) |node| seen.insert(node.tag);

    // An alphabet member no source reaches is a rule that never runs. If a tag
    // is added here, a source that produces it belongs above.
    inline for (@typeInfo(Tag).@"enum".field_names) |field| {
        const tag: Tag = @fromBackingInt(@intCast(@backingInt(@field(Tag, field))));
        testing.expect(seen.contains(tag)) catch |err| {
            std.debug.print("proof IR tag '{s}' is unreachable from the corpus above\n", .{@tagName(tag)});
            return err;
        };
    }
}

test "a declared node is total even when no rule closes it" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    var branch_id: ?u32 = null;
    for (proof.nodes) |node| {
        if (node.tag == .branch) branch_id = node.id;
    }

    const declared = [_]u32{branch_id.?};
    const total = try deriveTotality(allocator, proof, &declared);
    defer allocator.free(total);
    try testing.expect(total[function_id]);
}

// The parser refuses statement nesting beyond its own recursion limit (512
// frames, about two per nested block) with ZTS044. `lower` also counts two
// levels per nested block (the `if` node and its body), so its bound of
// `max_depth` is crossed first, by source the parser still admits at about 254
// nested blocks. This test walks
// the nesting upward, requires that `lower` first refuses such an admitted
// program with `ProgramTooDeep`, and requires that the refusal precedes the
// parser's own limit. A parser or lowerer limit change that moves the order
// fails here.
test "a program deeper than the walk bound is refused, not truncated" {
    const allocator = testing.allocator;
    var refused_at: ?usize = null;
    var parser_refused_at: ?usize = null;
    var n: usize = 200;
    while (n < 600) : (n += 1) {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, "function handler(req) {\n");
        var i: usize = 0;
        while (i < n) : (i += 1) try source.appendSlice(allocator, "  if (req.ok) {\n");
        try source.appendSlice(allocator, "    return Response.text(\"ok\");\n");
        i = 0;
        while (i < n) : (i += 1) try source.appendSlice(allocator, "  }\n");
        try source.appendSlice(allocator, "}\n");

        var parser = JsParser.initAdmission(allocator, allocator, source.items, .compile) catch {
            parser_refused_at = n;
            break;
        };
        defer parser.deinit();
        const root = parser.parse() catch {
            parser_refused_at = n;
            break;
        };
        const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        if (lower(allocator, view, root, null, null)) |lowered| {
            var owned = lowered;
            owned.deinit();
            try testing.expect(refused_at == null);
        } else |err| {
            try testing.expectEqual(error.ProgramTooDeep, err);
            if (refused_at == null) refused_at = n;
        }
    }
    try testing.expect(refused_at != null);
    try testing.expect(parser_refused_at != null);
    try testing.expect(refused_at.? < parser_refused_at.?);
}

const result_source =
    \\import { validateJson } from "zttp:validate";
    \\function handler(req) {
    \\  const r = validateJson("a", "b");
    \\  if (!r.ok) {
    \\    return Response.text(r.errors);
    \\  }
    \\  const alias = r;
    \\  return Response.text(r.value);
    \\}
;

test "a Result binding is defined, guarded, read, and escaped by its events" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, result_source, never.resolver());
    defer lowered.deinit();

    try testing.expect(lowered.proof.results_classified);
    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_def));
    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_guard_err));
    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_read_ok));
    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_read_err));
    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_escape));
    try testing.expect(!(try deriveResults(allocator, lowered.proof)));
}

test "a program with no resolver carries no Result events and is not classified" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator, result_source);
    defer lowered.deinit();

    try testing.expect(!lowered.proof.results_classified);
    try testing.expectEqual(@as(usize, 0), countTag(lowered.proof, .result_def));
    try testing.expectEqual(@as(usize, 0), countTag(lowered.proof, .result_escape));
    try testing.expect(!(try deriveResults(allocator, lowered.proof)));
}

test "an event node has no parser source, so no witness attaches to it" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, result_source, never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(?u32, null), lowered.proof.nodeFor(null_node));
}

test "a guarded read with an early return derives as proved" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator,
        \\import { validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  const r = validateJson("a", "b");
        \\  if (!r.ok) {
        \\    return Response.text("no");
        \\  }
        \\  return Response.text(r.value);
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expect(try deriveResults(allocator, lowered.proof));
}

/// One false-proof shape, with the event that stops the lowering from
/// deriving a proof for it. The verifier refuses the same shapes, and this
/// table shows the lowering does not depend on that refusal.
const FalseProofLowering = struct {
    name: []const u8,
    source: []const u8,
    event: Tag,
};

const false_proof_lowerings = [_]FalseProofLowering{
    .{ .name = "p_alias", .event = .result_escape, .source =
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  const alias = late;
    \\  return Response.text(alias.value);
    \\}
    },
    .{ .name = "p_obj", .event = .result_escape, .source =
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  const box = { r: late };
    \\  return Response.text(box.r.value);
    \\}
    },
    .{ .name = "p_chain", .event = .result_escape, .source =
    \\function handler(req) {
    \\  return Response.text(validateJson("todo", "{}").value);
    \\}
    },
    .{ .name = "p_sibling", .event = .result_read_ok, .source =
    \\function inner() {
    \\  const local = validateJson("todo", "{}");
    \\  return local.value;
    \\}
    \\function handler(req) {
    \\  return Response.text(inner());
    \\}
    },
    .{ .name = "p_eqvar", .event = .result_read_ok, .source =
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  const flag = req.method === "GET";
    \\  if (late.ok === flag) {
    \\    return Response.text(late.value);
    \\  }
    \\  return Response.text("no");
    \\}
    },
    .{ .name = "p_helper", .event = .result_escape, .source =
    \\function reader(r) {
    \\  return r.value;
    \\}
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  return Response.text(reader(late));
    \\}
    },
    .{ .name = "p_err", .event = .result_read_err, .source =
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  return Response.text(late.error);
    \\}
    },
    .{ .name = "p_errors", .event = .result_read_err, .source =
    \\function handler(req) {
    \\  const late = validateJson("todo", "{}");
    \\  return Response.text(late.errors);
    \\}
    },
    .{ .name = "p_spread", .event = .result_escape, .source =
    \\function handler(req) {
    \\  const r = validateJson("todo", "{}");
    \\  const box = { ...r };
    \\  return Response.text(box.value);
    \\}
    },
    .{ .name = "p_computed", .event = .result_escape, .source =
    \\function handler(req) {
    \\  const r = validateJson("todo", "{}");
    \\  const k = "value";
    \\  return Response.text(r[k]);
    \\}
    },
    .{ .name = "p_closure_dup2", .event = .result_escape, .source =
    \\function handler(req) {
    \\  if (req.method === "GET") {
    \\    const r = validateJson("todo", "{}");
    \\    if (!r.ok) {
    \\      return Response.text("bad");
    \\    }
    \\    return Response.text(r.value);
    \\  }
    \\  const r = validateJson("todo", "{}");
    \\  const read = () => {
    \\    return r.value;
    \\  };
    \\  return Response.text(read());
    \\}
    },
};

test "the lowering marks every false-proof shape and derives no proof for it" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    inline for (false_proof_lowerings) |probe| {
        var lowered = try parseAndLowerWith(allocator, "import { validateJson } from \"zttp:validate\";\n" ++ probe.source, never.resolver());
        defer lowered.deinit();
        testing.expect(lowered.proof.results_classified) catch |err| {
            std.debug.print("probe '{s}' was not classified\n", .{probe.name});
            return err;
        };
        testing.expect(countTag(lowered.proof, probe.event) > 0) catch |err| {
            std.debug.print("probe '{s}' carries no {s} event\n", .{ probe.name, @tagName(probe.event) });
            return err;
        };
        testing.expect(!(try deriveResults(allocator, lowered.proof))) catch |err| {
            std.debug.print("probe '{s}' derived a proof\n", .{probe.name});
            return err;
        };
    }
}

const combinator_import = "import { ok, err, collectAll, andThen } from \"zttp:result\";\n";

test "an array literal of Results at the collectAll position derives as proved" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, combinator_import ++
        \\function handler(req) {
        \\  const first = ok(1);
        \\  const all = collectAll([first, ok(2), err("x")]);
        \\  if (!all.ok) {
        \\    return Response.text("no");
        \\  }
        \\  return Response.text(all.value);
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 0), countTag(lowered.proof, .result_escape));
    try testing.expect(try deriveResults(allocator, lowered.proof));
}

test "a Result binding passed to collectAll outside an array literal escapes" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, combinator_import ++
        \\function handler(req) {
        \\  const first = ok(1);
        \\  const all = collectAll(first);
        \\  return Response.text("done");
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_escape));
    try testing.expect(!(try deriveResults(allocator, lowered.proof)));
}

test "a Result nested in the array that collectAll receives escapes" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, combinator_import ++
        \\function handler(req) {
        \\  const first = ok(1);
        \\  const all = collectAll([[first]]);
        \\  return Response.text("done");
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_escape));
}

test "an expression body that returns a Result to andThen is consumed" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, combinator_import ++
        \\function handler(req) {
        \\  const first = ok(1);
        \\  const next = andThen(first, (n) => ok(n + 1));
        \\  if (!next.ok) {
        \\    return Response.text("no");
        \\  }
        \\  return Response.text(next.value);
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 0), countTag(lowered.proof, .result_escape));
    try testing.expect(try deriveResults(allocator, lowered.proof));
}

test "a block body that returns a Result to andThen escapes" {
    const allocator = testing.allocator;
    var never = NeverResolver{};
    var lowered = try parseAndLowerWith(allocator, combinator_import ++
        \\function handler(req) {
        \\  const first = ok(1);
        \\  const next = andThen(first, (n) => { return ok(n); });
        \\  return Response.text("done");
        \\}
    , never.resolver());
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), countTag(lowered.proof, .result_escape));
}

test "the ambient Result globals match the ones abi_types registers" {
    const source = @embedFile("abi_types.zig");
    var registered: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "registerGlobalFn(env, \"") == null) continue;
        // `requestJson` registers the same record with a JSON `value`.
        if (std.mem.indexOf(u8, line, ", result_record);") == null and
            std.mem.indexOf(u8, line, ", json_result_record);") == null) continue;
        registered += 1;
        try testing.expect(std.mem.indexOf(u8, line, "\"requestJson\"") != null or
            std.mem.indexOf(u8, line, "\"requestText\"") != null);
    }
    try testing.expectEqual(result_globals.len, registered);
}
