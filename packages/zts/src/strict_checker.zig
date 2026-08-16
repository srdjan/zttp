//! Default strict ZigTS profile.
//!
//! This pass enforces the smaller "expert" subset that keeps handler code
//! explicit enough for proof-driven tooling. It runs after parsing and the
//! normal type/sound passes, and before handler verification/contract work.

const std = @import("std");
const stripper = @import("zts-engine").stripper;
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const type_env_mod = @import("type_env.zig");
const type_checker_mod = @import("type_checker.zig");
const type_pool_mod = @import("type_pool.zig");
const match_analysis_mod = @import("match_analysis.zig");
const bool_checker = @import("bool_checker.zig");
const repair_intent_mod = @import("repair_intent.zig");
const module_facts_mod = @import("module_facts.zig");
const abi_types = @import("abi_types.zig");
const builtin_modules = @import("zts-engine").builtin_modules;
const known_globals = @import("zts-base").known_globals;

pub const RepairIntent = repair_intent_mod.RepairIntent;

const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const TypeEnv = type_env_mod.TypeEnv;
const FunctionSig = type_env_mod.FunctionSig;
const TypeChecker = type_checker_mod.TypeChecker;
const null_type_idx = type_pool_mod.null_type_idx;

/// The closed severity set (spec 4.8). Only `.err` may fail a check: a
/// diagnostic that is not `.err` never changes an exit code, a success
/// verdict, or a proof property. `.advisory` is the idiom channel - it names a
/// better spelling for code that is already correct, so it is strictly weaker
/// than `.warning`, which reports a real defect the checker chose not to fail
/// on.
pub const Severity = enum {
    err,
    warning,
    advisory,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .advisory => "advisory",
        };
    }
};

test "advisory severity label" {
    try testing.expectEqualStrings("advisory", Severity.advisory.label());
}

test "advisory diagnostics do not count as errors" {
    var checker = try checkSource("function handler(req) { return Response.json({ ok: true }); }");
    defer checker.deinit();

    const before = countErrors(&checker);
    // No rule emits an advisory until the idiom channel is wired, so inject one
    // directly: the invariant under test is that the error count is blind to it.
    checker.addDiagnostic(.{
        .severity = .advisory,
        .kind = .canonical_redundant_bool_compare,
        .node = 0,
        .message = "test advisory",
        .help = null,
    });

    try testing.expectEqual(before, countErrors(&checker));
}

fn countErrors(checker: *const StrictChecker) usize {
    var count: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        if (diag.severity == .err) count += 1;
    }
    return count;
}

pub const DiagnosticKind = enum {
    implicit_unknown,
    unpublished_ambient_global,
    missing_public_annotation,
    dynamic_capability_access,
    non_exhaustive_profile_match,
    avoidable_let,
    computed_property_access,
    /// A raw built-in type appears in an exported function's parameter or
    /// return position. Cross-file contracts name declared types; internal
    /// functions keep inference-friendly raw types.
    raw_exported_boundary_type,
    mutable_live_iteration,
    canonical_arrow_helper,
    canonical_export_function_const,
    canonical_public_helper_effects,
    /// A module-internal function carries an `Effects<...>` ceiling. Spec 5.7
    /// makes placement decidable rather than a style choice: exported with a
    /// nonempty row MUST declare, module-internal MUST NOT.
    canonical_internal_helper_effects,
    canonical_public_helper_proof,
    canonical_ternary_impure,
    canonical_ternary_chain,
    canonical_compound_assignment,
    canonical_non_leading_spread,
    canonical_call_spread,
    canonical_redundant_bool_compare,
    /// An absence operator (`??` or `?.`) applied where the operand's static
    /// type can be `null`. Spec 5.3: both operators test `null` and
    /// `undefined` alike, so on such an operand they silently erase the
    /// distinction JSON fidelity depends on.
    nullish_operator_on_null,
    /// A `match` record pattern renames a field to the name it already has
    /// (`{ value: value }`). Spec 4.2.1 row `match binding field name`: the
    /// shorthand is the idiomatic spelling.
    canonical_redundant_pattern_rename,
    /// A `match` arm reads a field off the scrutinee instead of binding it in
    /// the pattern. Spec 4.2.1 row `matched field read`.
    canonical_unbound_field_read,
    /// An entry round trip through `dictEntries` and `dictFromEntries` that
    /// changes only values, or only drops entries. Spec 4.2.1 rows
    /// `dictionary map` and `dictionary filter`: `dictMapValues` and
    /// `dictFilter` say the same thing, keep the key set by construction, and
    /// return a `Dict` rather than a `Result` the caller must unwrap.
    canonical_dict_entry_round_trip,
    /// A `reduce` over `dictEntries(d)`. Spec 4.2.1 row `dictionary fold`:
    /// `dictFold` folds the dictionary directly, without materializing the
    /// entry array the reduce only walks once.
    canonical_dict_entries_reduce,
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    message_owned: bool = false,
    /// Typed repair primitive the agent uses to pick an apply step directly.
    /// `null` when no single canonical
    /// repair applies (e.g. implicit_unknown — needs a type annotation that
    /// can take several shapes).
    repair_intent: ?RepairIntent = null,
};

const ImportedFunction = struct {
    slot: u16,
    module: []const u8,
    name: []const u8,
};

/// What an expression built out of `dictEntries(d)` does to the entry list.
/// The transform is what decides which spec 4.2.1 row a round trip realizes,
/// and `callback` is the argument the key-preservation test reads.
const EntryChain = struct {
    transform: enum { map, filter, other },
    callback: NodeIndex,
};

fn functionSigCovers(sig: ?FunctionSig, params_count: u16) bool {
    const s = sig orelse return false;
    return s.return_type != null_type_idx and s.param_count >= params_count;
}

pub const StrictChecker = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    type_env: ?*const TypeEnv,
    type_checker: ?*const TypeChecker,
    diagnostics: std.ArrayList(Diagnostic),
    assigned_bindings: std.AutoHashMapUnmanaged(u32, void),
    annotated_function_bindings: std.AutoHashMapUnmanaged(u32, void),
    /// Every binding whose initializer is a function, annotated or not. A named
    /// helper handed to a callback slot is a body this checker cannot read, and
    /// the purity test has to refuse it rather than answer from its absence.
    function_valued_bindings: std.AutoHashMapUnmanaged(u32, void),
    static_literal_bindings: std.AutoHashMapUnmanaged(u32, void),
    /// Bindings whose initializer is built out of a `dictEntries(d)` call, so
    /// a round trip spelled across two statements is seen as one.
    entries_derived_bindings: std.AutoHashMapUnmanaged(u32, EntryChain),
    call_counts: std.AutoHashMapUnmanaged(u32, u32),
    imported_functions: std.ArrayList(ImportedFunction),
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the checker. Null means build a private one.
    ///
    /// A private index is built with no manifest registry, so a
    /// partner-registered module classifies as `unresolved` rather than
    /// `partner`. That is immaterial here: this checker records every import
    /// regardless of resolution, which is exactly why it needs the unfiltered
    /// collection.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Sticky failure for diagnostics and profile facts used to decide which
    /// strict rules fire. The void walkers may continue, but no partial result
    /// escapes `check`.
    allocation_failed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        type_env: ?*const TypeEnv,
        type_checker: ?*const TypeChecker,
    ) StrictChecker {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .type_env = type_env,
            .type_checker = type_checker,
            .diagnostics = .empty,
            .assigned_bindings = .empty,
            .annotated_function_bindings = .empty,
            .function_valued_bindings = .empty,
            .static_literal_bindings = .empty,
            .entries_derived_bindings = .empty,
            .call_counts = .empty,
            .imported_functions = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *StrictChecker) void {
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.message_owned) self.allocator.free(diagnostic.message);
        }
        if (self.owned_facts) |*owned| owned.deinit();
        self.imported_functions.deinit(self.allocator);
        self.call_counts.deinit(self.allocator);
        self.static_literal_bindings.deinit(self.allocator);
        self.entries_derived_bindings.deinit(self.allocator);
        self.annotated_function_bindings.deinit(self.allocator);
        self.function_valued_bindings.deinit(self.allocator);
        self.assigned_bindings.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn check(self: *StrictChecker, root: NodeIndex) !u32 {
        if (self.type_env) |env| try env.ensureHealthy();
        if (self.type_checker) |tc| try tc.ensureHealthy();
        self.scanImports();
        self.collectAnnotatedFunctions(root);
        self.collectStaticLiterals(root);
        self.collectEntriesDerivedBindings(root);
        self.collectAssignments(root);
        self.collectCallCounts(root);
        self.walkStmt(root);
        if (self.type_env) |env| try env.ensureHealthy();
        if (self.type_checker) |tc| try tc.ensureHealthy();
        if (self.allocation_failed) return error.OutOfMemory;

        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        return error_count;
    }

    pub fn getDiagnostics(self: *const StrictChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    /// Drop borrowed references to TypeEnv/TypeChecker after `check()` has
    /// finished. Once sealed, the checker only holds owned diagnostics so it
    /// is safe to move into longer-lived storage without UB if the original
    /// borrows go out of scope. Idempotent.
    pub fn seal(self: *StrictChecker) void {
        self.type_env = null;
        self.type_checker = null;
    }

    pub fn formatDiagnostics(self: *const StrictChecker, source: stripper.SourceView, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            try writer.print("strict {s}: {s}\n", .{ diag.severity.label(), diag.message });
            try source.writeLocation(loc.line, loc.column, writer);
            if (diag.help) |help| try writer.print("   = help: {s}\n", .{help});
            try writer.writeByte('\n');
        }
    }

    fn addDiagnostic(self: *StrictChecker, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch self.markAllocationFailure();
    }

    fn checkAmbientGlobal(self: *StrictChecker, node: NodeIndex) void {
        const binding = self.ir_view.getBinding(node) orelse return;
        if (binding.kind != .undeclared_global) return;
        const name = self.resolveAtomName(binding.name_atom) orelse return;
        if (isKnownGlobalFunction(name)) return;
        if (self.type_env) |env| {
            if (env.getTypeAlias(name)) |type_idx| {
                if (env.pool.isNominal(type_idx)) return;
            }
        }

        const message = std.fmt.allocPrint(
            self.allocator,
            "unpublished ambient global '{s}'",
            .{name},
        ) catch {
            self.markAllocationFailure();
            return;
        };
        self.diagnostics.append(self.allocator, .{
            .severity = .err,
            .kind = .unpublished_ambient_global,
            .node = node,
            .message = message,
            .help = ambientGlobalHelp(name),
            .message_owned = true,
        }) catch {
            self.allocator.free(message);
            self.markAllocationFailure();
        };
    }

    fn markAllocationFailure(self: *StrictChecker) void {
        self.allocation_failed = true;
    }

    fn canonicalSeverity(self: *const StrictChecker) Severity {
        _ = self;
        return .err;
    }

    fn walkStmt(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.walkStmt(self.ir_view.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                if (export_decl.declaration != null_node) {
                    self.checkExportedDeclaration(export_decl.declaration);
                    self.walkStmt(export_decl.declaration);
                }
            },
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.checkFunctionAnnotation(decl.init);
                if (self.ir_view.getFunction(decl.init)) |func| {
                    self.walkStmt(func.body);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.kind == .let and !self.assigned_bindings.contains(bindingKey(decl.binding))) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .avoidable_let,
                        .node = node,
                        .message = "let binding is never reassigned",
                        .help = "use const for bindings that do not change",
                        .repair_intent = .replace_let_with_const,
                    });
                }
                if (decl.kind == .@"const" and
                    self.ir_view.getTag(decl.init) == .arrow_function and
                    !self.isHandlerBinding(decl.binding) and
                    self.bindingCallCount(decl.binding) > 1)
                {
                    self.addDiagnostic(.{
                        .severity = self.canonicalSeverity(),
                        .kind = .canonical_arrow_helper,
                        .node = node,
                        .message = "reused arrow helper should be a named function",
                        .help = "rewrite reusable helpers as `function name(...) { ... }`; keep arrows for callbacks and local one-off values",
                        .repair_intent = .replace_arrow_with_function,
                    });
                }
                if (decl.init != null_node) {
                    if (self.isHandlerBinding(decl.binding) and self.isFunctionNode(decl.init)) {
                        self.checkFunctionAnnotation(decl.init);
                    }
                    self.walkExpr(decl.init);
                }
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return;
                self.walkExpr(if_stmt.condition);
                self.walkStmt(if_stmt.then_branch);
                self.walkStmt(if_stmt.else_branch);
            },
            .for_of_stmt => {
                const for_iter = self.ir_view.getForIter(node) orelse return;
                if (!for_iter.is_const) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .avoidable_let,
                        .node = node,
                        .message = "for-of binding uses let",
                        .help = "use `for (const item of items)` unless the loop binding itself is reassigned",
                        .repair_intent = .replace_let_with_const,
                    });
                }
                self.checkLiveMutation(node, for_iter);
                self.walkExpr(for_iter.iterable);
                self.walkStmt(for_iter.body);
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| self.walkExpr(value);
            },
            else => self.walkExpr(node),
        }
    }

    /// Spec 5.4: `condition ? whenTrue : whenFalse` is the idiomatic two-way
    /// pure value selection. Both arms MUST be pure, and a conditional
    /// expression MUST NOT appear as an arm of another conditional expression,
    /// parenthesized or not. Parentheses produce no IR node, so the tag test on
    /// each arm is exact.
    ///
    /// Chaining is reported instead of impurity when both apply: the nesting is
    /// the structural defect, and its repair subsumes the other.
    fn checkTernary(self: *StrictChecker, node: NodeIndex, ternary: anytype) void {
        if (self.isTernaryNode(ternary.then_branch) or self.isTernaryNode(ternary.else_branch)) {
            self.addDiagnostic(.{
                .severity = self.canonicalSeverity(),
                .kind = .canonical_ternary_chain,
                .node = node,
                .message = "a conditional expression may not appear as an arm of another conditional expression",
                .help = "use `match` over one scrutinee, or an if/else chain feeding a named function",
                .repair_intent = .replace_ternary_with_if,
            });
            return;
        }

        if (!self.isPureExpr(ternary.then_branch) or !self.isPureExpr(ternary.else_branch)) {
            self.addDiagnostic(.{
                .severity = self.canonicalSeverity(),
                .kind = .canonical_ternary_impure,
                .node = node,
                .message = "a ?: arm must be a pure value; effectful selection uses match or if",
                .help = "bind the effectful call first, or use `match` over the condition for an effectful two-way choice",
                .repair_intent = .replace_ternary_with_if,
            });
        }
    }

    fn isTernaryNode(self: *const StrictChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const tag = self.ir_view.getTag(node) orelse return false;
        return tag == .ternary;
    }

    // D2-interim: syntactic purity for ?: arms until the effects-and-purity
    // design doc (2026-07-30-015) defines the real predicate. Pure = literals,
    // identifiers, member reads, unary/binary operators, and template, array,
    // and object literals over pure parts. A call, method call, or assignment
    // is impure, and so is any composite containing one. Retire this when D2
    // lands and the inferred effect row replaces the syntactic class.
    fn isPureExpr(self: *const StrictChecker, node: NodeIndex) bool {
        if (node == null_node) return true;
        const tag = self.ir_view.getTag(node) orelse return true;
        return switch (tag) {
            .assignment => false,
            .call, .method_call => self.isPureModuleCall(node),
            // A callback's purity is its body's. Answering `true` for every
            // function node - which the `else` arm below used to do - made
            // `dictMapValues(d, () => cacheGet(...))` look like a pure
            // argument, so the export's own `.none` effect would have carried
            // a call that reaches storage into a `?:` arm.
            .arrow_function, .function_expr => blk: {
                const func = self.ir_view.getFunction(node) orelse break :blk false;
                break :blk self.isPureBody(func.body);
            },
            .ternary => blk: {
                const t = self.ir_view.getTernary(node) orelse break :blk true;
                break :blk self.isPureExpr(t.condition) and
                    self.isPureExpr(t.then_branch) and
                    self.isPureExpr(t.else_branch);
            },
            .binary_op => blk: {
                const bin = self.ir_view.getBinary(node) orelse break :blk true;
                break :blk self.isPureExpr(bin.left) and self.isPureExpr(bin.right);
            },
            .unary_op, .spread => blk: {
                const un = self.ir_view.getUnary(node) orelse break :blk true;
                break :blk self.isPureExpr(un.operand);
            },
            .member_access, .optional_chain => blk: {
                const member = self.ir_view.getMember(node) orelse break :blk true;
                break :blk self.isPureExpr(member.object);
            },
            .computed_access => blk: {
                const member = self.ir_view.getMember(node) orelse break :blk true;
                break :blk self.isPureExpr(member.object) and self.isPureExpr(member.computed);
            },
            .array_literal => blk: {
                const arr = self.ir_view.getArray(node) orelse break :blk true;
                for (0..arr.elements_count) |i| {
                    const el = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
                    if (!self.isPureExpr(el)) break :blk false;
                }
                break :blk true;
            },
            .object_literal => blk: {
                const obj = self.ir_view.getObject(node) orelse break :blk true;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop_tag = self.ir_view.getTag(prop_idx);
                    if (prop_tag != null and prop_tag.? == .object_spread) {
                        const value = self.ir_view.getOptValue(prop_idx) orelse continue;
                        if (!self.isPureExpr(value)) break :blk false;
                        continue;
                    }
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    if (!self.isPureExpr(prop.value)) break :blk false;
                }
                break :blk true;
            },
            .match_expr => blk: {
                const match = self.ir_view.getMatchExpr(node) orelse break :blk true;
                if (!self.isPureExpr(match.discriminant)) break :blk false;
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    if (!self.isPureExpr(arm.body)) break :blk false;
                }
                break :blk true;
            },
            else => true,
        };
    }

    /// A callback body is pure when every statement in it is. The statement
    /// kinds are enumerated and anything else answers false, which is the
    /// direction that matters: an unmodelled statement is one this walk could
    /// not read, and reporting an unread body pure is the fail-open the whole
    /// test exists to avoid. A concise arrow body is not a statement at all, so
    /// it falls through to the expression walk.
    fn isPureBody(self: *const StrictChecker, node: NodeIndex) bool {
        if (node == null_node) return true;
        const tag = self.ir_view.getTag(node) orelse return false;
        return switch (tag) {
            .program, .block => blk: {
                const block = self.ir_view.getBlock(node) orelse break :blk false;
                for (0..block.stmts_count) |i| {
                    if (!self.isPureBody(self.ir_view.getListIndex(block.stmts_start, @intCast(i)))) break :blk false;
                }
                break :blk true;
            },
            .return_stmt, .expr_stmt => blk: {
                const value = self.ir_view.getOptValue(node) orelse break :blk true;
                break :blk self.isPureExpr(value);
            },
            .var_decl => blk: {
                const decl = self.ir_view.getVarDecl(node) orelse break :blk false;
                break :blk self.isPureExpr(decl.init);
            },
            // Every remaining statement kind in the IR alphabet, named rather
            // than left to the expression walk below - which answers `true` for
            // a tag it does not model, and would therefore report a body it
            // could not read as pure. Most of these the profile does not admit
            // anyway; listing them means adding one to the alphabet lands here
            // as a refusal instead of silently as a pass.
            .if_stmt,
            .for_stmt,
            .for_of_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .assert_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .labeled_stmt,
            .function_decl,
            .import_decl,
            => false,
            // Not a statement: a concise arrow body, which the expression walk
            // decides.
            else => self.isPureExpr(node),
        };
    }

    /// True when the registry says this call selects a value rather than
    /// performing an effect.
    ///
    /// Every call used to answer false, which made spec 4.2.1's `two-way pure
    /// selection` row - whose precondition is "none" - refuse
    /// `c ? ok(a) : err(b)`. Both arms are calls to a zero-capability module
    /// that declares no effect, so the rule was refusing the spelling it
    /// exists to prefer.
    ///
    /// Three conditions, each closing a hole the others do not:
    ///
    /// The export declares `EffectClass.none`, which the registry documents as
    /// "compile-time only, no runtime effect".
    ///
    /// It reaches no capability. `Law.pure` is the wrong test here and would
    /// have been the tempting one: `env` declares `.pure` - the law is
    /// algebraic - while reaching `.env` and `.policy_check` and reading the
    /// host. The capability set is what says whether a call reaches for
    /// authority, and reaching for it in one branch only is exactly the
    /// conditional the rule wants spelled as `match` or `if`.
    ///
    /// Every argument is itself pure. This is what stops an effect entering
    /// through a callback: `dictMapValues` declares `.none` and runs whatever
    /// it is handed.
    ///
    /// A method call is never admitted, because `importedFunctionForCallee`
    /// resolves an identifier callee only. `s.toUpperCase()` in a `?:` arm is
    /// pure and still reported; deciding that needs a purity model for the
    /// ambient sequence methods, which does not exist here.
    fn isPureModuleCall(self: *const StrictChecker, node: NodeIndex) bool {
        const call = self.ir_view.getCall(node) orelse return false;
        const imported = self.importedFunctionForCallee(call.callee) orelse return false;
        const entry = builtin_modules.findExport(imported.module, imported.name) orelse return false;
        if (entry.func.effect != .none) return false;

        const caps = entry.func.required_capabilities orelse entry.binding.required_capabilities;
        if (caps.len > 0) return false;

        for (0..call.args_count) |i| {
            const arg = self.ir_view.getListIndex(call.args_start, @intCast(i));
            // A named helper in a callback slot is a body this walk cannot
            // read. Its identifier would otherwise answer pure by being a
            // leaf, which is the absence of information reported as a fact.
            if (self.namesFunction(arg)) return false;
            if (!self.isPureExpr(arg)) return false;
        }
        return true;
    }

    /// True when `node` is a bare identifier naming a function this walk
    /// cannot read the body of - a locally-declared one, or an import.
    ///
    /// `function_valued_bindings` is filled only from `.function_decl` and
    /// `.var_decl`, so an import was never in it and the identifier fell
    /// through to `isPureExpr`'s leaf arm, which answers pure. That made
    /// `flag ? dictMapValues(d, logInfo) : d` report clean: `dictMapValues`
    /// declares `.none` and no capability, and it runs whatever it is handed -
    /// here a `zttp:log` export that reaches `.clock` and `.stderr`. The rule
    /// that exists to forbid a conditional effect stayed silent on one.
    ///
    /// Refusing every named import in an argument slot is the conservative
    /// direction and the same one the local case already takes: an identifier
    /// is a name, not a body, and answering pure for it reports the absence of
    /// information as a fact.
    fn namesFunction(self: *const StrictChecker, node: NodeIndex) bool {
        if (self.ir_view.getTag(node) != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        if (self.function_valued_bindings.contains(bindingKey(binding))) return true;
        // Slot numbers are per-kind, so a local `const d` can carry the same
        // number as an import. Only a global binding can name one.
        if (binding.kind != .global) return false;
        return self.importedFunctionForSlot(binding.slot) != null;
    }

    fn walkExpr(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .identifier => self.checkAmbientGlobal(node),
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.checkRedundantBoolCompare(node, bin);
                if (bin.op == .nullish) self.checkAbsenceOperator(node, bin.left, "??");
                self.walkExpr(bin.left);
                self.walkExpr(bin.right);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return;
                self.walkExpr(un.operand);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return;
                self.checkTernary(node, ternary);
                self.walkExpr(ternary.condition);
                self.walkExpr(ternary.then_branch);
                self.walkExpr(ternary.else_branch);
            },
            .call, .method_call => {
                self.checkCall(node);
                self.checkDictIdioms(node);
                const call = self.ir_view.getCall(node) orelse return;
                self.walkExpr(call.callee);
                for (0..call.args_count) |i| {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    const arg_tag = self.ir_view.getTag(arg);
                    if (arg_tag != null and arg_tag.? == .spread) {
                        self.addDiagnostic(.{
                            .severity = self.canonicalSeverity(),
                            .kind = .canonical_call_spread,
                            .node = arg,
                            .message = "spread arguments are not part of canonical ZigTS",
                            .help = "pass positional arguments or widen the helper signature to accept the array directly",
                            .repair_intent = .widen_signature_drop_spread,
                        });
                    }
                    self.walkExpr(arg);
                }
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return;
                if (tag == .optional_chain) self.checkAbsenceOperator(node, member.object, "?.");
                self.walkExpr(member.object);
            },
            .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.walkExpr(member.object);
                if (member.computed != null_node) {
                    self.walkExpr(member.computed);
                    if (!self.isStaticComputedKey(member.computed)) {
                        self.addDiagnostic(.{
                            .severity = .err,
                            .kind = .computed_property_access,
                            .node = node,
                            .message = "dynamic computed property access is not part of strict ZigTS",
                            .help = "use a typed field, a literal key, or validate/narrow the object before indexing",
                        });
                    }
                }
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return;
                if (assign.op != null) {
                    self.addDiagnostic(.{
                        .severity = self.canonicalSeverity(),
                        .kind = .canonical_compound_assignment,
                        .node = node,
                        .message = "compound assignment is not part of canonical ZigTS",
                        .help = "write the update explicitly: `x = x + 1` instead of `x += 1`",
                        .repair_intent = .replace_compound_assign_with_explicit,
                    });
                }
                self.walkExpr(assign.target);
                self.walkExpr(assign.value);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    self.walkExpr(self.ir_view.getListIndex(arr.elements_start, @intCast(i)));
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop_tag = self.ir_view.getTag(prop_idx);
                    if (prop_tag != null and prop_tag.? == .object_spread) {
                        if (i > 0) {
                            self.addDiagnostic(.{
                                .severity = self.canonicalSeverity(),
                                .kind = .canonical_non_leading_spread,
                                .node = prop_idx,
                                .message = "object spread must appear before any explicit keys",
                                .help = "reorder so the spread is first: `{...base, x: 1}` instead of `{x: 1, ...base}`. Later keys still override.",
                                .repair_intent = .lead_with_spread,
                            });
                        }
                        if (self.ir_view.getOptValue(prop_idx)) |value| self.walkExpr(value);
                        continue;
                    }
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    self.walkExpr(prop.value);
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return;
                self.walkExpr(match.discriminant);
                self.checkMatchBindingIdioms(match);
                if (!self.matchIsCovered(match)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .non_exhaustive_profile_match,
                        .node = node,
                        .message = "match expression must be exhaustive in strict ZigTS",
                        .help = "cover every finite union member or add an explicit default when the type is not finite",
                        .repair_intent = .add_trailing_return,
                    });
                }
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    self.walkExpr(arm.body);
                }
            },
            .function_expr, .arrow_function => {
                self.checkFunctionAnnotation(node);
                if (self.ir_view.getFunction(node)) |func| self.walkStmt(func.body);
            },
            else => {},
        }
    }

    /// Checks rules whose scope is the exported declaration itself. ZTS061 is
    /// deliberately limited to `.function_decl`; function-valued constants
    /// remain under ZTS609 until their boundary semantics are specified.
    /// Annotation completeness is still handled by the normal statement walk,
    /// which avoids emitting ZTS601 twice for one `export function`.
    fn checkExportedDeclaration(self: *StrictChecker, node: NodeIndex) void {
        const tag = self.ir_view.getTag(node) orelse return;
        const decl = self.ir_view.getVarDecl(node) orelse return;
        if (tag == .function_decl and decl.init != null_node and self.isFunctionNode(decl.init)) {
            self.checkExportedBoundaryTypes(decl.init);
        }
        if (tag != .var_decl) return;
        if (decl.init == null_node or !self.isFunctionNode(decl.init)) return;
        if (decl.kind != .@"const") return;
        self.addDiagnostic(.{
            .severity = self.canonicalSeverity(),
            .kind = .canonical_export_function_const,
            .node = node,
            .message = "exported function-valued const should be an export function declaration",
            .help = "use `export function name(...) { ... }` unless the export is intentionally a first-class function value",
            .repair_intent = .replace_export_arrow_with_function,
        });
    }

    /// ZTS061: an exported signature is a contract another file reads, so its
    /// raw open types must be named. The source spelling is load-bearing: a
    /// structural scalar alias resolves to the same TypeIndex as its base.
    fn checkExportedBoundaryTypes(self: *StrictChecker, node: NodeIndex) void {
        const func = self.ir_view.getFunction(node) orelse return;
        const source_sig = self.functionSignature(node, func) orelse return;
        const sig = source_sig.sig;
        const env = self.type_env orelse return;

        // With an incomplete annotation list the remaining entries no longer
        // map one-to-one onto parameter nodes. ZTS601 owns that malformed
        // signature; do not guess which parameter an entry belonged to.
        if (sig.param_count == func.params_count) {
            for (0..func.params_count) |i| {
                const annotation = env.getSourceFnParamAnnotation(source_sig.line, @intCast(i)) orelse continue;
                const raw = rawBoundaryBase(annotation) orelse continue;
                const param = self.ir_view.getListIndex(func.params_start, @intCast(i));
                self.addRawBoundaryDiagnostic(param, "parameter", annotation, raw);
            }
        }

        if (env.getSourceFnReturnAnnotation(source_sig.line)) |annotation| {
            if (rawBoundaryBase(annotation)) |raw| {
                self.addRawBoundaryDiagnostic(node, "return", annotation, raw);
            }
        }
    }

    const SourceFunctionSig = struct {
        sig: FunctionSig,
        line: u32,
    };

    fn functionSignature(
        self: *const StrictChecker,
        node: NodeIndex,
        func: ir.Node.FunctionExpr,
    ) ?SourceFunctionSig {
        const env = self.type_env orelse return null;
        const loc = self.ir_view.getLoc(node) orelse return null;
        if (env.getFnSigByLoc(loc.line)) |sig| return .{ .sig = sig, .line = loc.line };
        if (func.name_atom == 0) return null;
        const name = self.resolveAtomName(func.name_atom) orelse return null;
        const sig = env.getSourceFnSigByName(name) orelse return null;
        const line = env.getSourceFnLineByName(name) orelse return null;
        return .{ .sig = sig, .line = line };
    }

    fn addRawBoundaryDiagnostic(
        self: *StrictChecker,
        node: NodeIndex,
        position: []const u8,
        annotation: []const u8,
        raw: []const u8,
    ) void {
        const displayed_annotation = std.mem.trim(u8, annotation, " \t\r\n");
        const message = std.fmt.allocPrint(
            self.allocator,
            "exported function {s} type `{s}` exposes raw `{s}`",
            .{ position, displayed_annotation, raw },
        ) catch {
            self.markAllocationFailure();
            return;
        };
        self.diagnostics.append(self.allocator, .{
            .severity = .err,
            .kind = .raw_exported_boundary_type,
            .node = node,
            .message = message,
            .help = "declare a nominal or structural alias and name it in the exported signature",
            .message_owned = true,
            .repair_intent = .declare_boundary_type,
        }) catch {
            self.allocator.free(message);
            self.markAllocationFailure();
        };
    }

    fn checkFunctionAnnotation(self: *StrictChecker, node: NodeIndex) void {
        const func = self.ir_view.getFunction(node) orelse return;
        if (!self.functionNeedsAnnotation(node, func)) return;

        const loc = self.ir_view.getLoc(node) orelse return;
        if (!self.hasCompleteFunctionAnnotation(func, loc.line)) {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .missing_public_annotation,
                .node = node,
                .message = "strict ZigTS requires explicit function parameter and return types",
                .help = "annotate each parameter and the return type, for example `function handler(req: Request): Response`",
            });
        }
    }

    /// ZTS620 canonical_redundant_bool_compare: detect a strict comparison of
    /// a statically-boolean value against a boolean literal (`x === true`,
    /// `x !== false`, and the operand-reversed forms). For a boolean `x` the
    /// comparison is exactly `x` or `!x`, so the literal comparison is a
    /// redundant spelling of the boolean test itself.
    ///
    /// The static-boolean guard is load-bearing for soundness: `x === true`
    /// is only equivalent to `x` when `x` is a boolean. For a non-boolean
    /// `x`, `x === true` is an identity test against the literal `true`,
    /// which differs from the truthiness test `x`. When type information is
    /// unavailable, or the value operand is not provably boolean, the rule
    /// does not fire.
    fn checkRedundantBoolCompare(self: *StrictChecker, node: NodeIndex, bin: ir.Node.BinaryExpr) void {
        if (bin.op != .strict_eq and bin.op != .strict_neq) return;

        const left_bool = self.boolLiteralValue(bin.left);
        const right_bool = self.boolLiteralValue(bin.right);

        // Exactly one operand must be a boolean literal. `true === false` is a
        // constant the optimizer handles; it is not the redundant-test shape.
        const lit_value: bool, const value_node: NodeIndex = blk: {
            if (left_bool != null and right_bool == null) break :blk .{ left_bool.?, bin.right };
            if (right_bool != null and left_bool == null) break :blk .{ right_bool.?, bin.left };
            return;
        };

        // Soundness guard: the non-literal operand must be statically boolean.
        //
        // Widened before the comparison because a `const` binding keeps its
        // literal type (`t_literal_bool`) while a `let` widens to `boolean` -
        // see `widenLiteral`, which exists to stop let bindings locking to a
        // value. Comparing by identity against `idx_boolean` therefore fired
        // for `let ready = true` and not for `const ready = true`, which made
        // canonicalization non-confluent: rewriting the binding to `const`
        // first disabled this row, so one program had two canonical forms.
        //
        // Widening does not loosen the guard. `t_literal_bool` widens only to
        // `idx_boolean`, so nothing non-boolean reaches the rewrite, and a
        // value of literal type `true` is a boolean - `x === true` is still
        // exactly `x`.
        const tc = self.type_checker orelse return;
        if (tc.env.pool.widenLiteral(tc.inferType(value_node)) != tc.env.pool.idx_boolean) return;

        // `=== true` / `!== false` reduce to `x`; `=== false` / `!== true`
        // reduce to `!x`.
        const positive = (bin.op == .strict_eq) == lit_value;
        const help = if (positive)
            "drop the comparison and use the boolean directly: `x`"
        else
            "drop the comparison and negate the boolean directly: `!x`";

        self.addDiagnostic(.{
            .severity = self.canonicalSeverity(),
            .kind = .canonical_redundant_bool_compare,
            .node = node,
            .message = "comparing a boolean against a boolean literal is not canonical ZigTS",
            .help = help,
            .repair_intent = .drop_redundant_bool_compare,
        });
    }

    /// The two spec 4.2.1 rows a `match` binding realizes.
    ///
    /// `match binding field name` (ZTS625): `{ value: value }` says the field name
    /// twice; the shorthand `{ value }` is the same pattern.
    ///
    /// `matched field read` (ZTS626): an arm that reads a field off the
    /// scrutinee is spelling by hand what a binding pattern field does, and
    /// the read is a second traversal of the same value.
    ///
    /// Both are advisory: the code they name is correct, and the row names a
    /// better spelling for it.
    fn checkMatchBindingIdioms(self: *StrictChecker, match: ir.Node.MatchExpr) void {
        const disc_binding: ?ir.BindingRef = if (self.ir_view.getTag(match.discriminant) == .identifier)
            self.ir_view.getBinding(match.discriminant)
        else
            null;

        for (0..match.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
            self.checkRedundantPatternRename(arm.pattern);
            if (disc_binding) |binding| self.checkUnboundFieldRead(arm.body, binding);
        }
    }

    fn checkRedundantPatternRename(self: *StrictChecker, pattern: NodeIndex) void {
        if (pattern == null_node) return;
        if (self.ir_view.getTag(pattern) != .match_pattern) return;
        const record = self.ir_view.getMatchPattern(pattern) orelse return;

        for (0..record.props_count) |i| {
            const prop_idx = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            if (prop.is_shorthand) continue;
            if (prop.value == null_node) continue;
            if (self.ir_view.getTag(prop.value) != .identifier) continue;

            const binding = self.ir_view.getBinding(prop.value) orelse continue;
            const bound_name = self.resolveAtomName(binding.name_atom) orelse continue;
            const key_str_idx = self.ir_view.getStringIdx(prop.key) orelse continue;
            const key_str = self.ir_view.getString(key_str_idx) orelse continue;
            if (!std.mem.eql(u8, bound_name, key_str)) continue;

            self.addDiagnostic(.{
                .severity = .advisory,
                .kind = .canonical_redundant_pattern_rename,
                .node = prop_idx,
                .message = "a pattern field renamed to its own name is the shorthand binding",
                .help = "drop the rename and write the field name once",
            });
        }
    }

    /// Report the first field read off `scrutinee` inside `body`. One per arm:
    /// the repair is the same one every time, and an arm that reads three
    /// fields does not need three advisories to say so.
    fn checkUnboundFieldRead(self: *StrictChecker, body: NodeIndex, scrutinee: ir.BindingRef) void {
        const found = self.findScrutineeFieldRead(body, scrutinee, 0) orelse return;
        self.addDiagnostic(.{
            .severity = .advisory,
            .kind = .canonical_unbound_field_read,
            .node = found,
            .message = "a match arm reads a field off the scrutinee instead of binding it",
            .help = "bind the field in the arm's pattern (`when { kind: \"echo\", text }:`) and read the bound name",
        });
    }

    fn findScrutineeFieldRead(self: *const StrictChecker, node: NodeIndex, scrutinee: ir.BindingRef, depth: u8) ?NodeIndex {
        if (node == null_node or depth > 16) return null;
        const tag = self.ir_view.getTag(node) orelse return null;

        switch (tag) {
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return null;
                if (self.ir_view.getTag(member.object) == .identifier) {
                    if (self.ir_view.getBinding(member.object)) |b| {
                        if (b.scope_id == scrutinee.scope_id and b.slot == scrutinee.slot) return node;
                    }
                }
                return self.findScrutineeFieldRead(member.object, scrutinee, depth + 1);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return null;
                return self.findScrutineeFieldRead(bin.left, scrutinee, depth + 1) orelse
                    self.findScrutineeFieldRead(bin.right, scrutinee, depth + 1);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return null;
                return self.findScrutineeFieldRead(un.operand, scrutinee, depth + 1);
            },
            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return null;
                return self.findScrutineeFieldRead(t.condition, scrutinee, depth + 1) orelse
                    self.findScrutineeFieldRead(t.then_branch, scrutinee, depth + 1) orelse
                    self.findScrutineeFieldRead(t.else_branch, scrutinee, depth + 1);
            },
            .call => {
                const call = self.ir_view.getCall(node) orelse return null;
                var i: u16 = 0;
                while (i < call.args_count) : (i += 1) {
                    const arg = self.ir_view.getListIndex(call.args_start, i);
                    if (self.findScrutineeFieldRead(arg, scrutinee, depth + 1)) |hit| return hit;
                }
                return null;
            },
            // exhaustive: the remaining tags are leaves, or they open a scope
            // of their own whose reads are not this arm's spelling choice.
            else => return null,
        }
    }

    /// The two spec 4.2.1 rows spec 6.2 names as rewrites over a `Dict`.
    ///
    /// ZTS627 `dictionary map` / `dictionary filter`: an entry round trip
    /// through `dictEntries` and `dictFromEntries` says in three steps what
    /// one bulk operation says in one, and pays for it - the round trip can
    /// produce a duplicate key, so `dictFromEntries` returns a `Result` and
    /// the caller handles a failure the transform could not cause.
    ///
    /// ZTS628 `dictionary fold`: a `reduce` over `dictEntries(d)` materializes
    /// an entry array to walk it once. `dictFold` folds the dictionary.
    ///
    /// Both are advisory: the code they name computes the right answer, and
    /// the row names a better spelling for it.
    fn checkDictIdioms(self: *StrictChecker, node: NodeIndex) void {
        const call = self.ir_view.getCall(node) orelse return;

        if (self.importedCollectionsFn(call.callee, "dictFromEntries")) {
            if (call.args_count != 1) return;
            const arg = self.ir_view.getListIndex(call.args_start, 0);
            const chain = self.entriesChain(arg, 0) orelse return;
            switch (chain.transform) {
                .map => {
                    // The `dictionary map` row rewrites a round trip that
                    // changes only values. A callback that computes a new key
                    // changes the key set, so the precondition does not hold
                    // and the row says nothing about it.
                    if (!self.preservesEntryKey(chain.callback)) return;
                    self.addDiagnostic(.{
                        .severity = .advisory,
                        .kind = .canonical_dict_entry_round_trip,
                        .node = node,
                        .message = "an entry round trip that changes only values is `dictMapValues`",
                        .help = "replace the whole site, including its `Result` handling, with `dictMapValues(d, f)`: it keeps the key set by construction and returns a `Dict`, so there is no duplicate-key error to unwrap",
                    });
                },
                .filter => self.addDiagnostic(.{
                    .severity = .advisory,
                    .kind = .canonical_dict_entry_round_trip,
                    .node = node,
                    .message = "an entry round trip that only drops entries is `dictFilter`",
                    .help = "replace the whole site, including its `Result` handling, with `dictFilter(d, p)`: dropping entries cannot introduce a duplicate key, so there is no error to unwrap",
                }),
                // A round trip with no transform at all is neither row: it
                // rebuilds the dictionary it started from, which is a
                // different observation and not one spec 4.2.1 makes.
                .other => {},
            }
            return;
        }

        if (self.ir_view.getTag(call.callee) != .member_access) return;
        const member = self.ir_view.getMember(call.callee) orelse return;
        const method = self.resolveAtomName(member.property) orelse return;
        if (!std.mem.eql(u8, method, "reduce")) return;
        // The receiver, not the whole chain: `dictEntries(d).filter(p).reduce(f)`
        // folds a filtered list, and `dictFold` over the unfiltered dictionary
        // is a different program.
        if (!self.isDictEntriesCall(member.object)) return;
        self.addDiagnostic(.{
            .severity = .advisory,
            .kind = .canonical_dict_entries_reduce,
            .node = node,
            .message = "a reduce over `dictEntries` is `dictFold`",
            .help = "fold the dictionary directly: `dictFold(d, (acc, value, key) => ..., init)`, which walks the entries without building the array first",
        });
    }

    fn importedCollectionsFn(self: *const StrictChecker, callee: NodeIndex, name: []const u8) bool {
        const imported = self.importedFunctionForCallee(callee) orelse return false;
        return std.mem.eql(u8, imported.module, "zttp:collections") and
            std.mem.eql(u8, imported.name, name);
    }

    fn isDictEntriesCall(self: *const StrictChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag != .call and tag != .method_call) return false;
        const call = self.ir_view.getCall(node) orelse return false;
        return self.importedCollectionsFn(call.callee, "dictEntries");
    }

    /// The `dictEntries` chain `node` is built out of, or null when it is not
    /// built out of one. Descends a member chain to the `dictEntries` call and
    /// reports, on the way back, the outermost `map` or `filter` applied to
    /// it. An identifier resolves through the bindings the pre-pass recorded,
    /// so the two-statement spelling of a round trip reads the same as the
    /// nested one.
    fn entriesChain(self: *const StrictChecker, node: NodeIndex, depth: u8) ?EntryChain {
        if (node == null_node or depth > 8) return null;
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(node) orelse return null;
                return self.entries_derived_bindings.get(bindingKey(binding));
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return null;
                const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
                if (callee_tag == .identifier) {
                    if (!self.importedCollectionsFn(call.callee, "dictEntries")) return null;
                    return .{ .transform = .other, .callback = null_node };
                }
                if (callee_tag != .member_access) return null;
                const member = self.ir_view.getMember(call.callee) orelse return null;
                const inner = self.entriesChain(member.object, depth + 1) orelse return null;
                const method = self.resolveAtomName(member.property) orelse return inner;
                const callback = if (call.args_count > 0)
                    self.ir_view.getListIndex(call.args_start, 0)
                else
                    null_node;
                if (std.mem.eql(u8, method, "map")) return .{ .transform = .map, .callback = callback };
                if (std.mem.eql(u8, method, "filter")) return .{ .transform = .filter, .callback = callback };
                return inner;
            },
            else => return null,
        }
    }

    /// True when `callback` hands back the pair's own key: `(p) => [p[0], v]`.
    /// Anything else in the key position - a literal, a computed name, the
    /// value - is a new key set, which is outside the `dictionary map` row.
    /// Unreadable shapes answer false, so an undecidable callback reports
    /// nothing rather than being advised into a rewrite that changes the
    /// program.
    fn preservesEntryKey(self: *const StrictChecker, callback: NodeIndex) bool {
        if (callback == null_node) return false;
        const func = self.ir_view.getFunction(callback) orelse return false;
        if (func.params_count == 0) return false;
        const param_idx = self.ir_view.getListIndex(func.params_start, 0);
        const param = self.ir_view.paramBinding(param_idx) orelse return false;

        const returned = self.returnedExpr(func.body, 0) orelse return false;
        if (self.ir_view.getTag(returned) != .array_literal) return false;
        const pair = self.ir_view.getArray(returned) orelse return false;
        if (pair.elements_count != 2) return false;

        const key_element = self.ir_view.getListIndex(pair.elements_start, 0);
        if (self.ir_view.getTag(key_element) != .computed_access) return false;
        const read = self.ir_view.getMember(key_element) orelse return false;
        if (!self.isBindingReference(read.object, param)) return false;
        const index = self.ir_view.getIntValue(read.computed) orelse return false;
        return index == 0;
    }

    /// The single expression a callback yields: the concise arrow body itself,
    /// or the value of a lone `return`. A body that yields on more than one
    /// path answers null, which the caller reads as undecidable.
    fn returnedExpr(self: *const StrictChecker, body: NodeIndex, depth: u8) ?NodeIndex {
        if (body == null_node or depth > 4) return null;
        const tag = self.ir_view.getTag(body) orelse return null;
        switch (tag) {
            .return_stmt => return self.ir_view.getOptValue(body),
            .program, .block => {
                const block = self.ir_view.getBlock(body) orelse return null;
                if (block.stmts_count != 1) return null;
                return self.returnedExpr(self.ir_view.getListIndex(block.stmts_start, 0), depth + 1);
            },
            else => return body,
        }
    }

    /// ZTS624 nullish_operator_on_null: `??` and `?.` test `null` and
    /// `undefined` alike, so on an operand whose static type can be `null`
    /// they erase the distinction spec 5.3 keeps. The operator stays the
    /// idiomatic spelling of `undefined`-absence on every concrete type
    /// without `null`; the refusal is exactly the case where its single
    /// meaning is not single.
    ///
    /// A generic parameter and `unknown` are refused for the same reason
    /// ahead of time: a later instantiation can admit `null` under source the
    /// checker has already accepted.
    fn checkAbsenceOperator(self: *StrictChecker, node: NodeIndex, operand: NodeIndex, spelling: []const u8) void {
        const tc = self.type_checker orelse return;
        const pool = tc.env.pool;
        const operand_type = tc.inferType(operand);
        // No inferred type is not the same answer as `unknown`. Inference
        // produced nothing here, so there is no claim to make either way.
        if (operand_type == null_type_idx) return;

        const admits_null = switch (pool.getTag(operand_type) orelse return) {
            .t_generic_param => true,
            else => tc.env.isAssignableTo(pool.idx_null, operand_type),
        };
        if (!admits_null) return;

        const help = if (std.mem.eql(u8, spelling, "??"))
            "test the value explicitly: `x === null ? fallback : x`, or `x === undefined ? fallback : x`, or take it apart with `match`"
        else
            "test the value explicitly before the read: `if (x !== null) { x.field }`, or take it apart with `match`";

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .nullish_operator_on_null,
            .node = node,
            .message = "an absence operator swallows `null` on an operand whose type admits it",
            .help = help,
            .repair_intent = .insert_guard_before_line,
        });
    }

    /// The value of a boolean literal node, or null when `node` is not a
    /// `lit_bool`. `IrView.getBoolValue` does not tag-check, so the tag gate
    /// here is required to avoid reading a non-boolean node's payload as a
    /// bool.
    fn boolLiteralValue(self: *const StrictChecker, node: NodeIndex) ?bool {
        if (self.ir_view.getTag(node) != .lit_bool) return null;
        return self.ir_view.getBoolValue(node);
    }

    /// Spec 12: mutable live iteration is replaced by snapshot iteration. A
    /// `for-of` body that mutates the collection it iterates changes the
    /// loop's own trip count, so neither finiteness nor cost is a property of
    /// the loop head. Only a directly named collection is checked: the
    /// iterable has to be an identifier for the body reference to be the same
    /// collection rather than a fresh one.
    fn checkLiveMutation(self: *StrictChecker, node: NodeIndex, for_iter: ir.Node.ForIterStmt) void {
        if (self.ir_view.getTag(for_iter.iterable) != .identifier) return;
        const target = self.ir_view.getBinding(for_iter.iterable) orelse return;
        if (!self.scanLiveMutation(for_iter.body, target)) return;

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .mutable_live_iteration,
            .node = node,
            .message = "the collection being iterated is mutated inside the loop",
            .help = "iterate a snapshot instead: bind the collection you are reading, and build the mutated one separately",
        });
    }

    /// Depth-first search for an in-place mutation of `target`. Mirrors
    /// `scanBindingRead`'s descent; the two differ only in what they look for
    /// at each node.
    fn scanLiveMutation(self: *const StrictChecker, node: NodeIndex, target: ir.BindingRef) bool {
        if (node == null_node) return false;
        if (self.isLiveMutationOf(node, target)) return true;
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return false;
                for (0..block.stmts_count) |i| {
                    if (self.scanLiveMutation(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), target)) return true;
                }
                return false;
            },
            .var_decl, .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return false;
                return self.scanLiveMutation(decl.init, target);
            },
            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return false;
                return self.scanLiveMutation(func.body, target);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return false;
                return self.scanLiveMutation(if_stmt.condition, target) or
                    self.scanLiveMutation(if_stmt.then_branch, target) or
                    self.scanLiveMutation(if_stmt.else_branch, target);
            },
            .for_of_stmt => {
                const inner = self.ir_view.getForIter(node) orelse return false;
                return self.scanLiveMutation(inner.iterable, target) or
                    self.scanLiveMutation(inner.body, target);
            },
            .return_stmt, .expr_stmt => {
                const value = self.ir_view.getOptValue(node) orelse return false;
                return self.scanLiveMutation(value, target);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return false;
                return self.scanLiveMutation(bin.left, target) or self.scanLiveMutation(bin.right, target);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return false;
                return self.scanLiveMutation(un.operand, target);
            },
            .ternary => {
                const tern = self.ir_view.getTernary(node) orelse return false;
                return self.scanLiveMutation(tern.condition, target) or
                    self.scanLiveMutation(tern.then_branch, target) or
                    self.scanLiveMutation(tern.else_branch, target);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return false;
                return self.scanLiveMutation(assign.value, target);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return false;
                if (self.scanLiveMutation(call.callee, target)) return true;
                for (0..call.args_count) |i| {
                    if (self.scanLiveMutation(self.ir_view.getListIndex(call.args_start, @intCast(i)), target)) return true;
                }
                return false;
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return false;
                if (self.scanLiveMutation(match.discriminant, target)) return true;
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    if (self.scanLiveMutation(arm.body, target)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// True when `node` mutates `target` in place: a mutating array method
    /// called on it, or an assignment through one of its members
    /// (`xs[i] = v`, `xs.length = 0`).
    fn isLiveMutationOf(self: *const StrictChecker, node: NodeIndex, target: ir.BindingRef) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return false;
                if (self.ir_view.getTag(call.callee) != .member_access) return false;
                const member = self.ir_view.getMember(call.callee) orelse return false;
                if (!self.isBindingReference(member.object, target)) return false;
                const name = self.resolveAtomName(member.property) orelse return false;
                return isArrayMutator(name);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return false;
                const target_tag = self.ir_view.getTag(assign.target) orelse return false;
                // `xs[i] = v` is `.computed_access`, `xs.length = 0` is
                // `.member_access`. Both write through the binding.
                if (target_tag != .member_access and target_tag != .computed_access) return false;
                const member = self.ir_view.getMember(assign.target) orelse return false;
                return self.isBindingReference(member.object, target);
            },
            else => return false,
        }
    }

    fn isBindingReference(self: *const StrictChecker, node: NodeIndex, target: ir.BindingRef) bool {
        if (self.ir_view.getTag(node) != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        return binding.scope_id == target.scope_id and binding.slot == target.slot;
    }

    fn functionNeedsAnnotation(self: *StrictChecker, node: NodeIndex, func: ir.Node.FunctionExpr) bool {
        if (func.name_atom != 0) return true;

        // Anonymous callbacks passed to proof-relevant helpers must also be
        // annotated. v1 detects those at the call site via implicit_unknown.
        const loc = self.ir_view.getLoc(node) orelse return false;
        _ = loc;
        return false;
    }

    fn hasCompleteFunctionAnnotation(self: *const StrictChecker, func: ir.Node.FunctionExpr, line: u32) bool {
        const env = self.type_env orelse return false;
        if (functionSigCovers(env.getFnSigByLoc(line), func.params_count)) return true;
        if (func.name_atom == 0) return false;
        const name = self.resolveAtomName(func.name_atom) orelse return false;
        return functionSigCovers(env.getFnSigByName(name), func.params_count);
    }

    fn checkCall(self: *StrictChecker, node: NodeIndex) void {
        const call = self.ir_view.getCall(node) orelse return;
        if (self.importedFunctionForCallee(call.callee)) |imported| {
            if (literalRequiredArg(imported.module, imported.name)) |arg_pos| {
                if (arg_pos < call.args_count) {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(arg_pos));
                    if (!self.isLiteralOrStaticTemplate(arg)) {
                        self.addDiagnostic(.{
                            .severity = .err,
                            .kind = .dynamic_capability_access,
                            .node = arg,
                            .message = "capability access must use a compiler-visible literal",
                            .help = "use a literal env key, cache namespace, SQL query name, egress URL, route path, or service name",
                        });
                    }
                }
            }
        }

        if (self.type_checker) |tc| {
            const inferred = tc.inferType(node);
            if (inferred == null_type_idx or inferred == tc.env.pool.idx_unknown) {
                if (self.isUserFunctionOrUnknownCall(call.callee)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .implicit_unknown,
                        .node = node,
                        .message = "call result has implicit unknown type",
                        .help = "add a return type annotation, use a modeled virtual module, or narrow with a type guard/assert",
                    });
                }
            }
        }
    }

    fn isUserFunctionOrUnknownCall(self: *StrictChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.ir_view.getBinding(callee) orelse return false;
        if (self.annotated_function_bindings.contains(bindingKey(binding))) return false;
        if (self.importedFunctionForSlot(binding.slot) != null) return false;
        // `slot` is an atom index only for global bindings; for local/argument/
        // upvalue bindings it is a scope-relative slot number, so resolving it
        // as an atom can collide with a predefined global-function name and
        // wrongly suppress the implicit_unknown diagnostic. Only consult it for
        // globals.
        if (binding.kind == .global or binding.kind == .undeclared_global) {
            if (self.resolveAtomName(binding.name_atom)) |name| {
                if (isKnownGlobalFunction(name)) return false;
            }
        }
        return true;
    }

    /// Resolve the index to read: injected, or private on first use.
    fn resolveFacts(self: *StrictChecker) ?*const module_facts_mod.ModuleFacts {
        if (self.facts) |f| return f;
        if (self.owned_facts == null) {
            self.owned_facts = module_facts_mod.ModuleFacts.build(
                self.allocator,
                self.ir_view,
                self.atoms,
                null,
            ) catch {
                self.markAllocationFailure();
                return null;
            };
        }
        return &self.owned_facts.?;
    }

    /// Record every import, unfiltered. This checker deliberately tracks
    /// imports from modules that are neither builtin nor partner-registered.
    fn scanImports(self: *StrictChecker) void {
        const facts = self.resolveFacts() orelse return;
        for (facts.imports.items) |rec| {
            self.imported_functions.append(self.allocator, .{
                .slot = rec.slot,
                .module = rec.module_specifier,
                .name = rec.imported_name,
            }) catch self.markAllocationFailure();
        }
    }

    fn collectAnnotatedFunctions(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        // Leaf action: record bindings whose initializer is an annotated
        // function. Structural descent (including into function bodies) is
        // handled by forEachChild below: for a .function_decl it descends into
        // decl.init (the function node), whose .function_expr arm then reaches
        // func.body - the same node the open-coded walk reached directly.
        switch (tag) {
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.function_valued_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
                if (self.functionHasAnnotation(decl.init)) {
                    self.annotated_function_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
                }
            },
            .var_decl => blk: {
                const decl = self.ir_view.getVarDecl(node) orelse break :blk;
                if (decl.init == null_node or !self.isFunctionNode(decl.init)) break :blk;
                self.function_valued_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
                if (self.functionHasAnnotation(decl.init)) {
                    self.annotated_function_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
                }
            },
            else => {},
        }
        self.ir_view.forEachChild(node, self, collectAnnotatedFunctions);
    }

    fn functionHasAnnotation(self: *const StrictChecker, node: NodeIndex) bool {
        const func = self.ir_view.getFunction(node) orelse return false;
        const loc = self.ir_view.getLoc(node) orelse return false;
        const sig = if (self.type_env) |env| env.getFnSigByLoc(loc.line) else null;
        return if (sig) |s|
            s.return_type != null_type_idx and s.param_count >= func.params_count
        else
            false;
    }

    fn collectAssignments(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.collectAssignments(self.ir_view.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                // Every handler a user writes is `export function handler`, and
                // without this arm no assignment inside one was ever recorded:
                // `walkStmt` descended through the export and this walk did
                // not, so a reassigned `let` there reported `avoidable_let` at
                // error severity.
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.collectAssignments(export_decl.declaration);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return;
                if (self.ir_view.getTag(assign.target) == .identifier) {
                    if (self.ir_view.getBinding(assign.target)) |binding| {
                        self.assigned_bindings.put(self.allocator, bindingKey(binding), {}) catch self.markAllocationFailure();
                    }
                }
                self.collectAssignments(assign.value);
            },
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.collectAssignments(decl.init);
            },
            .function_expr, .arrow_function => {
                if (self.ir_view.getFunction(node)) |func| self.collectAssignments(func.body);
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.collectAssignments(decl.init);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return;
                self.collectAssignments(if_stmt.condition);
                self.collectAssignments(if_stmt.then_branch);
                self.collectAssignments(if_stmt.else_branch);
            },
            .for_of_stmt => {
                const for_iter = self.ir_view.getForIter(node) orelse return;
                self.collectAssignments(for_iter.iterable);
                self.collectAssignments(for_iter.body);
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| self.collectAssignments(value);
            },
            else => self.collectExprAssignments(node),
        }
    }

    fn collectStaticLiterals(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        // Leaf action: record `const` bindings initialized to a literal or
        // static template; structural descent is handled by forEachChild, whose
        // child set matches this walk's open-coded recursion exactly.
        if (tag == .var_decl) {
            const decl = self.ir_view.getVarDecl(node) orelse return;
            if (decl.kind == .@"const" and self.isLiteralOrStaticTemplate(decl.init)) {
                self.static_literal_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
            }
        }
        self.ir_view.forEachChild(node, self, collectStaticLiterals);
    }

    /// Record bindings initialized from a `dictEntries` chain. A round trip is
    /// usually written across two statements - the transform bound to a name,
    /// then `dictFromEntries` over it - and without this the use site sees an
    /// identifier and nothing else. Source order is enough: the binding is
    /// declared before it is used.
    fn collectEntriesDerivedBindings(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag == .var_decl) {
            const decl = self.ir_view.getVarDecl(node) orelse return;
            if (decl.init != null_node) {
                if (self.entriesChain(decl.init, 0)) |chain| {
                    self.entries_derived_bindings.put(self.allocator, bindingKey(decl.binding), chain) catch
                        self.markAllocationFailure();
                }
            }
        }
        self.ir_view.forEachChild(node, self, collectEntriesDerivedBindings);
    }

    fn collectExprAssignments(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.collectAssignments(bin.left);
                self.collectAssignments(bin.right);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return;
                self.collectAssignments(un.operand);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return;
                self.collectAssignments(call.callee);
                for (0..call.args_count) |i| {
                    self.collectAssignments(self.ir_view.getListIndex(call.args_start, @intCast(i)));
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.collectAssignments(member.object);
                self.collectAssignments(member.computed);
            },
            else => {},
        }
    }

    fn collectCallCounts(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.collectCallCounts(self.ir_view.getListIndex(block.stmts_start, @intCast(i)));
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.collectCallCounts(export_decl.declaration);
            },
            .function_decl, .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.collectCallCounts(decl.init);
            },
            .function_expr, .arrow_function => {
                if (self.ir_view.getFunction(node)) |func| self.collectCallCounts(func.body);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return;
                self.collectCallCounts(if_stmt.condition);
                self.collectCallCounts(if_stmt.then_branch);
                self.collectCallCounts(if_stmt.else_branch);
            },
            .for_of_stmt => {
                const for_iter = self.ir_view.getForIter(node) orelse return;
                self.collectCallCounts(for_iter.iterable);
                self.collectCallCounts(for_iter.body);
            },
            .return_stmt, .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |value| self.collectCallCounts(value);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.collectCallCounts(bin.left);
                self.collectCallCounts(bin.right);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return;
                self.collectCallCounts(un.operand);
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return;
                self.collectCallCounts(ternary.condition);
                self.collectCallCounts(ternary.then_branch);
                self.collectCallCounts(ternary.else_branch);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return;
                self.recordCall(call.callee);
                self.collectCallCounts(call.callee);
                for (0..call.args_count) |i| {
                    self.collectCallCounts(self.ir_view.getListIndex(call.args_start, @intCast(i)));
                }
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.collectCallCounts(member.object);
                self.collectCallCounts(member.computed);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    self.collectCallCounts(self.ir_view.getListIndex(arr.elements_start, @intCast(i)));
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    self.collectCallCounts(prop.key);
                    self.collectCallCounts(prop.value);
                }
            },
            else => {},
        }
    }

    fn recordCall(self: *StrictChecker, callee: NodeIndex) void {
        if (self.ir_view.getTag(callee) != .identifier) return;
        const binding = self.ir_view.getBinding(callee) orelse return;
        const key = bindingKey(binding);
        const gop = self.call_counts.getOrPut(self.allocator, key) catch {
            self.markAllocationFailure();
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    fn bindingCallCount(self: *const StrictChecker, binding: ir.BindingRef) u32 {
        return self.call_counts.get(bindingKey(binding)) orelse 0;
    }

    fn importedFunctionForCallee(self: *const StrictChecker, callee: NodeIndex) ?ImportedFunction {
        if (self.ir_view.getTag(callee) != .identifier) return null;
        const binding = self.ir_view.getBinding(callee) orelse return null;
        return self.importedFunctionForSlot(binding.slot);
    }

    fn importedFunctionForSlot(self: *const StrictChecker, slot: u16) ?ImportedFunction {
        for (self.imported_functions.items) |func| {
            if (func.slot == slot) return func;
        }
        return null;
    }

    fn isHandlerBinding(self: *const StrictChecker, binding: ir.BindingRef) bool {
        const name = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, name, "handler");
    }

    fn isFunctionNode(self: *const StrictChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        return tag == .function_decl or tag == .function_expr or tag == .arrow_function;
    }

    fn matchHasDefault(self: *const StrictChecker, match: ir.Node.MatchExpr) bool {
        return match_analysis_mod.hasDefaultArm(self.ir_view, match);
    }

    /// Spec 5.5: a closed literal or discriminated union MUST be covered
    /// exactly and MUST NOT include `default`; an open domain MUST include
    /// one. This rule asked only whether a `default` arm was present, so the
    /// spelling the spec requires for a closed union - every member covered,
    /// no `default` - was the spelling it refused. Coverage is measured the
    /// same way the handler verifier measures it, and a `default` still
    /// answers for a domain no analysis can enumerate.
    fn matchIsCovered(self: *const StrictChecker, match: ir.Node.MatchExpr) bool {
        if (self.matchHasDefault(match)) return true;
        const tc = self.type_checker orelse return false;
        const disc_type = tc.inferType(match.discriminant);
        if (disc_type == null_type_idx) return false;
        const analysis = match_analysis_mod.MatchAnalysis.init(self.allocator, self.ir_view, tc.env.pool);
        return analysis.isMatchExhaustive(disc_type, match);
    }

    fn isStaticComputedKey(self: *const StrictChecker, node: NodeIndex) bool {
        return switch (self.ir_view.getTag(node) orelse return false) {
            .lit_string, .lit_int => true,
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk false;
                break :blk self.static_literal_bindings.contains(bindingKey(binding));
            },
            else => false,
        };
    }

    fn isLiteralOrStaticTemplate(self: *const StrictChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag == .lit_string) return true;
        if (tag == .lit_int) return true;
        if (tag == .identifier) {
            const binding = self.ir_view.getBinding(node) orelse return false;
            return self.static_literal_bindings.contains(bindingKey(binding));
        }
        return false;
    }

    fn resolveAtomName(self: *const StrictChecker, atom_value: u32) ?[]const u8 {
        const atom: object.Atom = @enumFromInt(atom_value);
        if (atom.isPredefined()) return atom.toPredefinedName();
        if (self.atoms) |table| return table.getName(atom);
        return null;
    }
};

fn ambientGlobalHelp(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "fetchSync")) {
        return "Import `fetch` from `zttp:fetch` and call `fetch(...)`; raw `fetchSync` is outside the model-minimal ambient namespace.";
    }
    return "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names.";
}

fn literalRequiredArg(module: []const u8, name: []const u8) ?u8 {
    if (std.mem.eql(u8, module, "zttp:env") and std.mem.eql(u8, name, "env")) return 0;
    if (std.mem.eql(u8, module, "zttp:fetch") and
        (std.mem.eql(u8, name, "fetch") or std.mem.eql(u8, name, "fetchSync"))) return 0;
    if (std.mem.eql(u8, module, "zttp:service") and std.mem.eql(u8, name, "serviceCall")) return 0;
    if (std.mem.eql(u8, module, "zttp:sql")) return 0;
    if (std.mem.eql(u8, module, "zttp:cache")) return 0;
    return null;
}

const isKnownGlobalFunction = known_globals.isKnownGlobalFunction;

fn isArrayMutator(name: []const u8) bool {
    const names = [_][]const u8{
        "copyWithin",
        "fill",
        "pop",
        "push",
        "reverse",
        "shift",
        "sort",
        "splice",
        "unshift",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Return the raw open type at the base of `annotation`, or null when the
/// annotation names a declared/ABI/closed type. Arrays inherit the decision
/// from their element, including nested and readonly arrays.
fn rawBoundaryBase(annotation: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, annotation, " \t\r\n");
    if (std.mem.startsWith(u8, text, "readonly")) {
        const after = text["readonly".len..];
        if (after.len > 0 and std.ascii.isWhitespace(after[0])) {
            text = std.mem.trim(u8, after, " \t\r\n");
        }
    }

    while (stripOuterParens(text)) |inner| {
        text = inner;
    }
    while (text.len >= 2 and text[text.len - 2] == '[' and text[text.len - 1] == ']') {
        text = std.mem.trim(u8, text[0 .. text.len - 2], " \t\r\n");
        while (stripOuterParens(text)) |inner| {
            text = inner;
        }
    }

    var member_start: usize = 0;
    var found_union = false;
    var angle_depth: u32 = 0;
    var bracket_depth: u32 = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        switch (c) {
            '\'', '"', '`' => quote = c,
            '<' => angle_depth += 1,
            '>' => if (angle_depth > 0) {
                angle_depth -= 1;
            },
            '{', '[', '(' => bracket_depth += 1,
            '}', ']', ')' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '|' => if (angle_depth == 0 and bracket_depth == 0) {
                found_union = true;
                if (rawBoundaryBase(text[member_start..i])) |raw| return raw;
                member_start = i + 1;
            },
            else => {},
        }
    }
    if (found_union) return rawBoundaryBase(text[member_start..]);

    if (abi_types.isBoundaryTypeAnnotation(text)) return null;
    for ([_][]const u8{ "string", "number", "boolean", "object", "unknown" }) |raw| {
        if (std.mem.eql(u8, text, raw)) return raw;
    }
    return null;
}

/// Strip one pair of parentheses only when it encloses the whole annotation.
fn stripOuterParens(annotation: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, annotation, " \t\r\n");
    if (text.len < 2 or text[0] != '(' or text[text.len - 1] != ')') return null;

    var depth: u32 = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (text, 0..) |c, i| {
        if (quote) |q| {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        switch (c) {
            '\'', '"', '`' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0 and i != text.len - 1) return null;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    return std.mem.trim(u8, text[1 .. text.len - 1], " \t\r\n");
}

fn bindingKey(binding: ir.BindingRef) u32 {
    return bool_checker.packBindingKey(binding.scope_id, binding.slot);
}

const testing = std.testing;

test "missing_public_annotation fires once for an exported function" {
    var checker = try checkSource("export function handler(req) { return Response.json({ok: true}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 1), countKind(&checker, .missing_public_annotation));
}

test "mutable_live_iteration fires when the loop pushes to the collection it reads" {
    var checker = try checkSource("function handler(req) { const xs = [1,2]; for (const x of xs) { xs.push(x); } return Response.json({}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 1), countKind(&checker, .mutable_live_iteration));
}

test "mutable_live_iteration fires on an indexed write to the iterated collection" {
    var checker = try checkSource("function handler(req) { const xs = [1,2]; for (const x of xs) { xs[0] = x; } return Response.json({}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 1), countKind(&checker, .mutable_live_iteration));
}

test "mutable_live_iteration fires from a nested statement in the loop body" {
    var checker = try checkSource("function handler(req) { const xs = [1,2]; for (const x of xs) { if (x > 1) { xs.pop(); } } return Response.json({}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 1), countKind(&checker, .mutable_live_iteration));
}

test "mutable_live_iteration does not fire when a different collection is built" {
    var checker = try checkSource("function handler(req) { const xs = [1,2]; const ys = []; for (const x of xs) { ys.push(x); } return Response.json({}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 0), countKind(&checker, .mutable_live_iteration));
}

test "mutable_live_iteration does not fire on a read of the iterated collection" {
    var checker = try checkSource("function handler(req) { const xs = [1,2]; for (const x of xs) { const n = xs.length; } return Response.json({}); }");
    defer checker.deinit();
    try testing.expectEqual(@as(usize, 0), countKind(&checker, .mutable_live_iteration));
}

test "missing_public_annotation count is the same exported and not" {
    var plain = try checkSource("function handler(req) { return Response.json({ok: true}); }");
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 1), countKind(&plain, .missing_public_annotation));
}

test "canonical_export_function_const survives the export annotation split" {
    var checker = try checkSource("export const handler = (req) => Response.json({ok: true});");
    defer checker.deinit();
    try expectKind(&checker, .canonical_export_function_const);
}

test "strict checker flags avoidable let" {
    const source = "function handler(req) { let x = 1; return Response.json({ x: x }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    const errors = try checker.check(root);
    try testing.expect(errors > 0);
}

test "strict checker accepts reassigned let" {
    const source = "function handler(req) { let x = 1; x = 2; return Response.json({ x: x }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    _ = try checker.check(root);
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .avoidable_let);
    }
}

test "strict checker accepts reassigned let inside an exported function" {
    // The test above passes with a bare `function handler`, and every handler
    // a user writes is `export function handler`. `collectAssignments` had no
    // `export_decl` arm - `walkStmt` did - so no assignment inside an exported
    // function was ever recorded and every `let` there read as never
    // reassigned, at error severity. `let` is an advertised admitted form with
    // no legal spelling until this descends.
    const source = "export function handler(req) { let x = 1; x = 2; return Response.json({ x: x }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    _ = try checker.check(root);
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .avoidable_let);
    }
}

test "an exported function's let that is never reassigned is still flagged" {
    // The floor under the fix above: descending through `export_decl` must not
    // turn the rule off, only stop it firing on a binding that is assigned.
    const source = "export function handler(req) { let x = 1; return Response.json({ x: x }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    _ = try checker.check(root);
    var saw_let = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == .avoidable_let) saw_let = true;
    }
    try testing.expect(saw_let);
}

test "canonical profile warns on reused arrow helper" {
    const source = "const parse = (x) => x; function handler(req) { const a = parse(1); const b = parse(2); return Response.json({ a: a, b: b }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    const errors = try checker.check(root);
    try testing.expect(errors > 0);
    var saw = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == .canonical_arrow_helper) {
            saw = true;
            try testing.expectEqual(Severity.err, diag.severity);
        }
    }
    try testing.expect(saw);
}

test "canonical profile counts reused arrow helper after typed arrow" {
    const source =
        \\const load = (id: string): Response => Response.text(id);
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var stripped = try @import("zts-engine").stripper.strip(testing.allocator, source, .{});
    defer stripped.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, stripped.code);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = type_pool_mod.TypePool.init(testing.allocator);
    defer pool.deinit(testing.allocator);
    var env = TypeEnv.init(testing.allocator, &pool);
    defer env.deinit();
    env.populateFromTypeMap(&stripped.type_map);
    var tc = TypeChecker.init(testing.allocator, view, null, &env, null);
    defer tc.deinit();
    _ = try tc.check(root);
    var checker = StrictChecker.init(testing.allocator, view, null, &env, &tc);
    defer checker.deinit();
    _ = try checker.check(root);
    var saw = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == .canonical_arrow_helper) saw = true;
    }
    try testing.expect(saw);
}

test "strict checker accepts one-off arrow helper value" {
    const source = "const parse = (x) => x; function handler(req) { const a = parse(1); return Response.json({ a: a }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    const errors = try checker.check(root);
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_arrow_helper);
    }
    // Other strict diagnostics may fire because this untyped fixture uses an
    // unannotated function; the canonical arrow-helper rule should not.
    _ = errors;
}

fn expectKind(checker: *const StrictChecker, kind: DiagnosticKind) !void {
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == kind) return;
    }
    return error.DiagnosticNotEmitted;
}

fn expectNoKind(checker: *const StrictChecker, kind: DiagnosticKind) !void {
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == kind) return error.UnexpectedDiagnostic;
    }
}

fn countKind(checker: *const StrictChecker, kind: DiagnosticKind) usize {
    var n: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == kind) n += 1;
    }
    return n;
}

test "StrictChecker fails closed when profile facts cannot allocate" {
    const allocator = testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "let answer = 42;");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = StrictChecker.init(failing.allocator(), view, null, null, null);
    defer checker.deinit();
    try testing.expectError(error.OutOfMemory, checker.check(root));
}

fn checkSource(source: []const u8) !StrictChecker {
    var parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    errdefer checker.deinit();
    _ = try checker.check(root);
    return checker;
}

/// Typed harness for rules that need inferred types (e.g. ZTS620's boolean
/// guard). Heap-allocated so the env/checker that capture `&pool`/`&env`
/// keep stable addresses across the returned handle. Caller calls `deinit`.
const TypedHarness = struct {
    parser: @import("zts-engine").parser.JsParser,
    pool: type_pool_mod.TypePool,
    env: TypeEnv,
    tc: TypeChecker,
    checker: StrictChecker,

    fn deinit(self: *TypedHarness) void {
        self.checker.deinit();
        self.tc.deinit();
        self.env.deinit();
        self.pool.deinit(testing.allocator);
        self.parser.deinit();
        testing.allocator.destroy(self);
    }
};

fn checkSourceTyped(source: []const u8) !*TypedHarness {
    const h = try testing.allocator.create(TypedHarness);
    errdefer testing.allocator.destroy(h);
    h.parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, source);
    const root = try h.parser.parse();
    const view = IrView.fromIRStore(&h.parser.nodes, &h.parser.constants);
    h.pool = type_pool_mod.TypePool.init(testing.allocator);
    h.env = TypeEnv.init(testing.allocator, &h.pool);
    h.tc = TypeChecker.init(testing.allocator, view, null, &h.env, null);
    _ = try h.tc.check(root);
    h.checker = StrictChecker.init(testing.allocator, view, null, &h.env, &h.tc);
    _ = try h.checker.check(root);
    return h;
}

test "canonical_redundant_bool_compare fires on `=== true` for a boolean" {
    var h = try checkSourceTyped(
        "function handler(req) { const ready = req.method === \"GET\"; if (ready === true) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_redundant_bool_compare);
}

test "canonical_redundant_bool_compare fires on `!== false` for a boolean" {
    var h = try checkSourceTyped(
        "function handler(req) { const ready = req.method === \"GET\"; if (ready !== false) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_redundant_bool_compare);
}

/// Strip, parse, and strict-check `source`, so the type env is populated from
/// the stripper's TypeMap the way the real pipeline populates it. The typed
/// harness above parses raw source and never strips, so it has no TypeMap and
/// cannot exercise annotation lookup at all.
const StrippedHarness = struct {
    stripped: @import("zts-engine").stripper.StripResult,
    parser: @import("zts-engine").parser.JsParser,
    pool: type_pool_mod.TypePool,
    env: TypeEnv,
    tc: TypeChecker,
    checker: StrictChecker,

    fn deinit(self: *StrippedHarness) void {
        self.checker.deinit();
        self.tc.deinit();
        self.env.deinit();
        self.pool.deinit(testing.allocator);
        self.parser.deinit();
        self.stripped.deinit();
        testing.allocator.destroy(self);
    }
};

fn checkStripped(source: []const u8) !*StrippedHarness {
    const h = try testing.allocator.create(StrippedHarness);
    errdefer testing.allocator.destroy(h);
    h.stripped = try @import("zts-engine").stripper.strip(testing.allocator, source, .{});
    h.parser = try @import("zts-engine").parser.JsParser.init(testing.allocator, h.stripped.code);
    const root = try h.parser.parse();
    const view = IrView.fromIRStore(&h.parser.nodes, &h.parser.constants);
    h.pool = type_pool_mod.TypePool.init(testing.allocator);
    h.env = TypeEnv.init(testing.allocator, &h.pool);
    h.env.populateFromTypeMap(&h.stripped.type_map);
    h.tc = TypeChecker.init(testing.allocator, view, null, &h.env, null);
    _ = try h.tc.check(root);
    h.checker = StrictChecker.init(testing.allocator, view, null, &h.env, &h.tc);
    _ = try h.checker.check(root);
    return h;
}

test "a multi-line signature is fully annotated" {
    // Annotations are stamped with the line their signature starts on, so a
    // signature split across lines assembles into one entry. Before that,
    // parameters and the return type landed in buckets keyed by their own
    // lines, neither held a complete signature, and a fully annotated function
    // was reported as missing its annotations.
    var h = try checkStripped(
        "function handler(\n    req: Request,\n): Response {\n  return Response.json({});\n}\n",
    );
    defer h.deinit();
    try expectNoKind(&h.checker, .missing_public_annotation);
}

test "a signature whose brace sits on the next line is fully annotated" {
    // The narrowest form of the same bug: the whole signature is on one line
    // and only the brace moved, which is enough to shift the function node's
    // line away from the annotations'.
    var h = try checkStripped(
        "function handler(req: Request): Response\n{\n  return Response.json({});\n}\n",
    );
    defer h.deinit();
    try expectNoKind(&h.checker, .missing_public_annotation);
}

test "a multi-line signature missing a parameter type still fails" {
    // The fix must not loosen the check: assembling the signature correctly is
    // the point, not accepting more.
    var h = try checkStripped(
        "function handler(\n    req,\n): Response {\n  return Response.json({});\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .missing_public_annotation);
}

test "a multi-line signature missing the return type still fails" {
    var h = try checkStripped(
        "function handler(\n    req: Request,\n) {\n  return Response.json({});\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .missing_public_annotation);
}

test "raw exported boundary types are refused in every specified shape" {
    const sources = [_][]const u8{
        "export function expose(value: string): string { return value; }",
        "export function expose(value: number): number { return value; }",
        "export function expose(value: boolean): boolean { return value; }",
        "export function expose(value: object): object { return value; }",
        "export function expose(value: unknown): unknown { return value; }",
        "export function expose(value: string[]): string[] { return value; }",
        "export function expose(value: readonly number[]): readonly number[] { return value; }",
    };
    for (sources) |source| {
        var h = try checkStripped(source);
        defer h.deinit();
        try testing.expectEqual(@as(usize, 2), countKind(&h.checker, .raw_exported_boundary_type));
    }
}

test "raw union members cannot hide behind a closed or ABI member" {
    const sources = [_][]const u8{
        "export function expose(value: string | \"fallback\"): string | \"fallback\" { return value; }",
        "export function expose(value: Request | string): Request | string { return value; }",
    };
    for (sources) |source| {
        var h = try checkStripped(source);
        defer h.deinit();
        try testing.expectEqual(@as(usize, 2), countKind(&h.checker, .raw_exported_boundary_type));
    }
}

test "exported function-valued constants stay outside ZTS061 scope" {
    var h = try checkStripped(
        "export const widen = (value: string): string => value;",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_export_function_const);
    try expectNoKind(&h.checker, .raw_exported_boundary_type);
}

test "raw exported boundary types are refused in a multi-line signature" {
    var h = try checkStripped(
        \\export function expose(
        \\    value: string[],
        \\): number {
        \\    return value.length;
        \\}
    );
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), countKind(&h.checker, .raw_exported_boundary_type));
}

test "raw exported boundaries survive a next-line function brace" {
    var h = try checkStripped(
        \\export function expose(value: string): string
        \\{
        \\    return value;
        \\}
    );
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), countKind(&h.checker, .raw_exported_boundary_type));
}

test "declared ABI and literal-union boundary types are admitted" {
    const sources = [_][]const u8{
        "structural Text = string; export function expose(value: Text): Text { return value; }",
        "nominal UserId = string; export function expose(value: UserId): UserId { return value; }",
        "structural Text = string; export function expose(value: Text[]): Text[] { return value; }",
        "nominal UserId = string; export function expose(value: readonly UserId[]): readonly UserId[] { return value; }",
        "export function expose(value: Request): Response { return Response.json({}); }",
        "export function expose(value: Bytes): Bytes { return value; }",
        "export function expose(value: Dict<string, number>): Dict<string, number> { return value; }",
        "export function expose(value: JsonValue): JsonValue { return value; }",
        "export function expose(value: Result<string, string>): Result<string, string> { return value; }",
        "export function expose(value: \"GET\" | \"POST\"): \"GET\" | \"POST\" { return value; }",
        "export function expose(value: Request | \"fallback\"): Request | \"fallback\" { return value; }",
    };
    for (sources) |source| {
        var h = try checkStripped(source);
        defer h.deinit();
        try expectNoKind(&h.checker, .raw_exported_boundary_type);
    }
}

test "raw internal function boundary types remain admitted" {
    var h = try checkStripped("function expose(value: string): string { return value; }");
    defer h.deinit();
    try expectNoKind(&h.checker, .raw_exported_boundary_type);
}

test "canonical_redundant_bool_compare fires for a const-bound literal boolean" {
    // A `const` binding keeps its literal type (`t_literal_bool`) while a `let`
    // widens to `boolean`. A guard comparing against `idx_boolean` by identity
    // saw the two differently, so this rule fired for the let form and not the
    // const form - which made canonicalization non-confluent: rewriting the
    // binding to `const` first disabled this row, leaving `x === true` in a
    // file that still passed `normalize --check`.
    var h = try checkSourceTyped(
        "function handler(req) { const ready = true; if (ready === true) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_redundant_bool_compare);
}

test "canonical_redundant_bool_compare fires for a let-bound literal boolean" {
    // The other half of the pair: both bindings must reach the same canonical
    // form, which is the property the confluence harness checks.
    var h = try checkSourceTyped(
        "function handler(req) { let ready = true; if (ready === true) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_redundant_bool_compare);
}

test "canonical_redundant_bool_compare does not fire on a non-boolean comparison" {
    // `n === 1` compares a number against a number literal, not a boolean
    // against a boolean literal: leave it alone.
    var h = try checkSourceTyped(
        "function handler(req) { const n = 1; if (n === 1) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer h.deinit();
    for (h.checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_redundant_bool_compare);
    }
}

test "canonical_redundant_bool_compare does not fire without type info" {
    // The null-type-checker harness cannot prove the operand is boolean, so
    // the soundness guard suppresses the rule rather than risk a non-boolean
    // identity comparison.
    var checker = try checkSource(
        "function handler(req) { const ready = req.method === \"GET\"; if (ready === true) { return Response.text(\"a\"); } return Response.text(\"b\"); }",
    );
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_redundant_bool_compare);
    }
}

test "pure ternary is admitted" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 200 : 500; return Response.json({ x: x }); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_ternary_impure);
        try testing.expect(diag.kind != .canonical_ternary_chain);
    }
}

test "ternary with a call arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? load(req) : 500; return Response.json({ x: x }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "ternary with an assignment arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { let n = 0; const x = req.method === 'GET' ? (n = 1) : 500; return Response.json({ x: x, n: n }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "ternary over pure composite arms is admitted" {
    // Array, object, and template arms are pure when every part is pure, so
    // the recursion must reach into them rather than defaulting to pure.
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? [req.url, 1] : [req.url, 2]; return Response.json({ x: x }); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_ternary_impure);
    }
}

test "ternary with a call nested inside a composite arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? [load(req)] : [500]; return Response.json({ x: x }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "a ternary over zero-capability module calls is admitted" {
    // Spec 4.2.1's `two-way pure selection` row has precondition "none", and
    // this is the shape it exists to prefer. Both arms call a module that
    // declares no effect and reaches no capability; the rule used to refuse it
    // because every call answered impure.
    var h = try checkStripped(
        "import { ok, err } from \"zttp:result\";\n" ++
            "function handler(req: Request): Response {\n  const n = 2;\n  const r = n > 0 ? ok(n) : err(\"negative\");\n  return Response.json({ ok: r.ok });\n}\n",
    );
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_ternary_impure);
}

test "a ternary over a capability-reaching call still fires" {
    // `sha256` declares no effect but reaches `.crypto`. Reaching for authority
    // in one branch only is the conditional the rule wants spelled out, and it
    // is why the capability set decides rather than the `pure` law - which
    // `env` declares while reading the host.
    var h = try checkStripped(
        "import { sha256 } from \"zttp:crypto\";\n" ++
            "function handler(req: Request): Response {\n  const n = 1;\n  const x = n > 0 ? sha256(\"a\") : \"\";\n  return Response.json({ x: x });\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_ternary_impure);
}

test "a pure callback keeps its call pure, an effectful one does not" {
    // `dictMapValues` declares `.none` and runs whatever it is handed, so the
    // export's own effect says nothing about the call. Answering `true` for
    // every function node - which the walk used to do - would admit both.
    var pure_cb = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, (v) => v * 2) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer pure_cb.deinit();
    try expectNoKind(&pure_cb.checker, .canonical_ternary_impure);

    var effectful_cb = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "import { cacheGet } from \"zttp:cache\";\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, (v) => cacheGet(\"ns\", \"k\")) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer effectful_cb.deinit();
    try expectKind(&effectful_cb.checker, .canonical_ternary_impure);
}

test "an imported function in a callback slot is refused like a local one" {
    // `function_valued_bindings` holds only locally-declared functions, so an
    // import fell through to the leaf arm and answered pure. `dictMapValues`
    // declares `.none` and runs whatever it is handed - here a `zttp:log`
    // export that reaches `.clock` and `.stderr` - so the rule that exists to
    // forbid a conditional effect reported nothing on one.
    var imported_cb = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "import { logInfo } from \"zttp:log\";\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, logInfo) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer imported_cb.deinit();
    try expectKind(&imported_cb.checker, .canonical_ternary_impure);

    // The control that keeps the refusal from being "refuse every call": the
    // two-way pure selection spec 4.2.1 prefers still passes, and its
    // arguments are locals rather than named functions.
    var pure_selection = try checkStripped(
        "import { ok, err } from \"zttp:result\";\n" ++
            "function handler(req: Request): Response {\n  const n = 1;\n  const r = n > 0 ? ok(1) : err(\"no\");\n  return Response.json({ ok: r.ok });\n}\n",
    );
    defer pure_selection.deinit();
    try expectNoKind(&pure_selection.checker, .canonical_ternary_impure);
}

test "a block-bodied callback is read statement by statement" {
    // The `const` and the `return` are both decidable, so the body is pure.
    var pure_block = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, (v) => { const doubled = v * 2; return doubled; }) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer pure_block.deinit();
    try expectNoKind(&pure_block.checker, .canonical_ternary_impure);

    // An `if` is a statement kind the purity walk does not model, and an
    // unmodelled statement is refused rather than assumed pure - here it hides
    // a call that reaches storage.
    var control_flow = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "import { cacheGet } from \"zttp:cache\";\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, (v) => { if (v > 0) { cacheGet(\"ns\", \"k\"); } return v; }) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer control_flow.deinit();
    try expectKind(&control_flow.checker, .canonical_ternary_impure);
}

test "a named helper in a callback slot is refused rather than assumed pure" {
    // The body is not readable from here, and an identifier is a leaf the walk
    // would otherwise answer `pure` for - the absence of information reported
    // as a fact.
    var h = try checkStripped(
        "import { dictEmpty, dictSet, dictMapValues, dictGet } from \"zttp:collections\";\n" ++
            "function double(v: number): number { return v * 2; }\n" ++
            "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const n = 1;\n  const out = n > 0 ? dictMapValues(d, double) : d;\n  return Response.json({ v: dictGet(out, \"a\") });\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .canonical_ternary_impure);
}

test "chained ternary fires chain diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 1 : req.method === 'POST' ? 2 : 3; return Response.json({ x: x }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_chain);
}

test "chained ternary in the then branch fires chain diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? (req.url === '/a' ? 1 : 2) : 3; return Response.json({ x: x }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_chain);
}

test "canonical_compound_assignment fires on +=" {
    var checker = try checkSource("function handler(req) { let n = 0; n += 1; return Response.json({ n: n }); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_compound_assignment);
}

test "canonical_compound_assignment does not fire on plain =" {
    var checker = try checkSource("function handler(req) { let n = 0; n = n + 1; return Response.json({ n: n }); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_compound_assignment);
    }
}

test "canonical_non_leading_spread fires when spread follows explicit keys" {
    var checker = try checkSource("function handler(req) { const base = {a: 1}; const next = {b: 2, ...base}; return Response.json(next); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_non_leading_spread);
}

test "canonical_non_leading_spread accepts leading spread" {
    var checker = try checkSource("function handler(req) { const base = {a: 1}; const next = {...base, b: 2}; return Response.json(next); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_non_leading_spread);
    }
}

test "canonical_call_spread accepts positional args" {
    var checker = try checkSource("function send(a, b) { return a + b; } function handler(req) { return Response.json({n: send(1, 2)}); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_call_spread);
    }
}

test "canonical_ternary_impure diagnostic carries repair_intent = replace_ternary_with_if" {
    // Every veto-able strict diagnostic must populate the typed repair
    // primitive so the agent picks an apply step
    // directly. ZTS612 is the representative canonical-profile case.
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? load(req) : 500; return Response.json({ x: x }); }");
    defer checker.deinit();
    var saw_ternary = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == .canonical_ternary_impure) {
            saw_ternary = true;
            try testing.expectEqual(
                @as(?RepairIntent, .replace_ternary_with_if),
                diag.repair_intent,
            );
        }
    }
    try testing.expect(saw_ternary);
}

// NOTE: a positive test for `f(...args)` is intentionally absent. The parser
// constructs the spread Node with `.data.unary` shape while the IR reader at
// parser/ir.zig:1107 expects `.data.opt_value`; the resulting safety panic
// prevents the detector from ever running. The detector here is in place so
// the rule fires automatically once the parser/IR mismatch is fixed.

const import_corpus = @import("tests/import_corpus.zig");

test "the import scan records every specifier in order" {
    // Replaces the differential test that proved this scan matches the pre-C1
    // implementation. Expectations captured from that proven implementation.
    const allocator = std.testing.allocator;

    const source =
        \\import { sha256, hmacSha256 } from "zttp:crypto";
        \\import { thing } from "zttp-ext:unknown";
        \\import { env } from "zttp:env";
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var checker = StrictChecker.init(allocator, ir_view, &atoms, null, null);
    defer checker.deinit();
    checker.scanImports();

    // Node order, then specifier order within a declaration. The unresolved
    // module keeps its position rather than being dropped or moved.
    const want = [_][2][]const u8{
        .{ "zttp:crypto", "sha256" },
        .{ "zttp:crypto", "hmacSha256" },
        .{ "zttp-ext:unknown", "thing" },
        .{ "zttp:env", "env" },
    };
    try std.testing.expectEqual(want.len, checker.imported_functions.items.len);
    for (want, checker.imported_functions.items) |expected, got| {
        try std.testing.expectEqualStrings(expected[0], got.module);
        try std.testing.expectEqualStrings(expected[1], got.name);
    }
}

test "this checker records imports from unresolved modules" {
    // The filter difference that must survive the migration. See the same test
    // in effect_inference.zig; the other four analyzers record builtins only.
    const allocator = std.testing.allocator;
    const source = "import { thing } from \"zttp-ext:unknown\";\n";

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var checker = StrictChecker.init(allocator, ir_view, &atoms, null, null);
    defer checker.deinit();
    checker.scanImports();

    try std.testing.expectEqual(@as(usize, 1), checker.imported_functions.items.len);
    try std.testing.expectEqualStrings("zttp-ext:unknown", checker.imported_functions.items[0].module);
    try std.testing.expectEqualStrings("thing", checker.imported_functions.items[0].name);
}

// ---------------------------------------------------------------------------
// ZTS624 nullish_operator_on_null (spec 5.3 / phase 3 task 3)
// ---------------------------------------------------------------------------

test "`??` over a type that admits null is refused" {
    var h = try checkStripped(
        "function handler(req: Request): Response {\n  const name: string | null = req.url;\n  const shown = name ?? \"anonymous\";\n  return Response.json({ shown: shown });\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .nullish_operator_on_null);
}

test "`??` over an optional type stays idiomatic" {
    // The control for the test above. On a concrete type without `null` the
    // operator keeps exactly one meaning and is the idiomatic spelling of it,
    // so a rule that fired here would refuse the corpus rather than a defect.
    var h = try checkStripped(
        "function handler(req: Request): Response {\n  const name: string | undefined = req.url;\n  const shown = name ?? \"anonymous\";\n  return Response.json({ shown: shown });\n}\n",
    );
    defer h.deinit();
    try expectNoKind(&h.checker, .nullish_operator_on_null);
}

test "`?.` over a type that admits null is refused" {
    var h = try checkStripped(
        "function handler(req: Request): Response {\n  const row: { name: string } | null = undefined;\n  const shown = row?.name;\n  return Response.json({ shown: shown });\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .nullish_operator_on_null);
}

test "`?.` over a concrete record stays idiomatic" {
    var h = try checkStripped(
        "function handler(req: Request): Response {\n  const row: { name: string } | undefined = undefined;\n  const shown = row?.name;\n  return Response.json({ shown: shown });\n}\n",
    );
    defer h.deinit();
    try expectNoKind(&h.checker, .nullish_operator_on_null);
}

test "`??` over unknown is refused ahead of the instantiation" {
    // Spec 5.3 refuses `unknown` and a generic parameter for the same reason:
    // a later instantiation can admit `null` under source already accepted.
    var h = try checkStripped(
        "function handler(req: Request): Response {\n  const raw: unknown = req.url;\n  const shown = raw ?? \"anonymous\";\n  return Response.json({ ok: true });\n}\n",
    );
    defer h.deinit();
    try expectKind(&h.checker, .nullish_operator_on_null);
}

// ---------------------------------------------------------------------------
// Dict idioms, spec 4.2.1 rows / spec 6.2 (phase 4 task 6)
// ---------------------------------------------------------------------------

const dict_imports =
    "import { dictEmpty, dictSet, dictEntries, dictFromEntries, dictMapValues, dictFilter, dictFold } from \"zttp:collections\";\n";

fn expectMessageContains(checker: *const StrictChecker, kind: DiagnosticKind, needle: []const u8) !void {
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != kind) continue;
        if (std.mem.indexOf(u8, diag.message, needle) != null) return;
    }
    return error.DiagnosticNotEmitted;
}

test "a value-only entry round trip is advised to dictMapValues" {
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const pairs = dictEntries(d).map((p) => [p[0], p[1] * 2]);\n  const rebuilt = dictFromEntries(pairs);\n  return Response.json({ ok: rebuilt.ok });\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .canonical_dict_entry_round_trip);
    try expectMessageContains(&h.checker, .canonical_dict_entry_round_trip, "dictMapValues");
}

test "the nested spelling of the same round trip reads the same" {
    // The two-statement form above is the common one, and the nested form is
    // the same program. Seeing only one of them would make the row's coverage
    // a property of where the author put a `const`.
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const rebuilt = dictFromEntries(dictEntries(d).map((p) => [p[0], p[1] * 2]));\n  return Response.json({ ok: rebuilt.ok });\n}\n");
    defer h.deinit();
    try expectMessageContains(&h.checker, .canonical_dict_entry_round_trip, "dictMapValues");
}

test "a drop-only entry round trip is advised to dictFilter" {
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const kept = dictEntries(d).filter((p) => p[1] > 1);\n  const rebuilt = dictFromEntries(kept);\n  return Response.json({ ok: rebuilt.ok });\n}\n");
    defer h.deinit();
    try expectMessageContains(&h.checker, .canonical_dict_entry_round_trip, "dictFilter");
}

test "a round trip that changes the key set is advised nothing" {
    // The `dictionary map` row rewrites a round trip that changes only values.
    // This one computes a new key, so the precondition does not hold and the
    // rewrite would change the program - a duplicate key it can now produce is
    // exactly why `dictFromEntries` returns a `Result` at all.
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const pairs = dictEntries(d).map((p) => [\"fixed\", p[1]]);\n  const rebuilt = dictFromEntries(pairs);\n  return Response.json({ ok: rebuilt.ok });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_dict_entry_round_trip);
}

test "a reduce over dictEntries is advised to dictFold" {
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const total = dictEntries(d).reduce((acc, p) => acc + p[1], 0);\n  return Response.json({ total: total });\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .canonical_dict_entries_reduce);
}

test "the bulk operations themselves are advised nothing" {
    // The control for all three rows at once. A rule that fired here would
    // advise the idiomatic spelling to rewrite itself.
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const doubled = dictMapValues(d, (v, k) => v * 2);\n  const kept = dictFilter(d, (v, k) => v > 0);\n  const total = dictFold(d, (acc, v, k) => acc + v, 0);\n  return Response.json({ total: total, a: dictEntries(doubled).length, b: dictEntries(kept).length });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_dict_entry_round_trip);
    try expectNoKind(&h.checker, .canonical_dict_entries_reduce);
}

test "a reduce over a filtered entry list is not the fold row" {
    // `dictFold` folds the whole dictionary. Folding a filtered list is a
    // different program, so the row does not cover it and advising the rewrite
    // would be advising a behavior change.
    var h = try checkStripped(dict_imports ++
        "function handler(req: Request): Response {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const total = dictEntries(d).filter((p) => p[1] > 0).reduce((acc, p) => acc + p[1], 0);\n  return Response.json({ total: total });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_dict_entries_reduce);
}

// ---------------------------------------------------------------------------
// Match binding idioms, spec 4.2.1 rows (phase 3 task 5)
// ---------------------------------------------------------------------------

const command_union_source =
    "structural Command =\n  | { kind: \"echo\"; text: string }\n  | { kind: \"ping\" };\n";

test "a pattern field renamed to its own name is advised to the shorthand" {
    var h = try checkStripped(command_union_source ++
        "function run(command: Command): string {\n  return match (command) {\n    when { kind: \"echo\", text: text }: text\n    when { kind: \"ping\" }: \"pong\"\n  };\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .canonical_redundant_pattern_rename);
}

test "the shorthand itself is advised nothing" {
    var h = try checkStripped(command_union_source ++
        "function run(command: Command): string {\n  return match (command) {\n    when { kind: \"echo\", text }: text\n    when { kind: \"ping\" }: \"pong\"\n  };\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_redundant_pattern_rename);
    try expectNoKind(&h.checker, .canonical_unbound_field_read);
}

test "an arm reading the field off the scrutinee is advised to bind it" {
    var h = try checkStripped(command_union_source ++
        "function run(command: Command): string {\n  return match (command) {\n    when { kind: \"echo\" }: command.text\n    when { kind: \"ping\" }: \"pong\"\n  };\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .canonical_unbound_field_read);
}

test "a rename under a different name is not the redundant form" {
    var h = try checkStripped(command_union_source ++
        "function run(command: Command): string {\n  return match (command) {\n    when { kind: \"echo\", text: message }: message\n    when { kind: \"ping\" }: \"pong\"\n  };\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_redundant_pattern_rename);
}

test "a const initialized from a two-way effectful match passes the profile" {
    // Spec 5.5 names `match` with effectful named calls in its arms the
    // idiomatic effectful selection form, including for initializing a `const`
    // from a two-way effectful choice. The canonical profile refuses an impure
    // ternary (ZTS612) and points here, so a rule refusing this shape would
    // leave the author with nowhere to go.
    var h = try checkStripped("import { logInfo } from \"zttp:log\";\nfunction handler(req: Request): Response {\n  const chosen = match (req.method) {\n    when \"GET\": logInfo(\"read\")\n    default: logInfo(\"write\")\n  };\n  return Response.json({ ok: true });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .canonical_ternary_impure);
    try expectNoKind(&h.checker, .non_exhaustive_profile_match);
}

test "dropping one arm leaves the JsonValue match non-exhaustive" {
    // The floor under the phase 3 exit gate: a coverage check that answered
    // "exhaustive" for everything would pass the gate without measuring it.
    var h = try checkStripped("structural JsonValue =\n  | null\n  | boolean\n  | number\n  | string\n  | readonly JsonValue[];\nfunction depth(value: JsonValue): number {\n  return match (value) {\n    when null: 1\n    when boolean: 1\n    when number: 1\n    when string: 1\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ d: depth([1]) });\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .non_exhaustive_profile_match);
}

test "the five arms cover JsonValue without a default" {
    var h = try checkStripped("structural JsonValue =\n  | null\n  | boolean\n  | number\n  | string\n  | readonly JsonValue[];\nfunction depth(value: JsonValue): number {\n  return match (value) {\n    when null: 1\n    when boolean: 1\n    when number: 1\n    when string: 1\n    when array: 2\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ d: depth([1]) });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .non_exhaustive_profile_match);
}

test "dropping the Dict arm leaves the six-kind JsonValue non-exhaustive" {
    var h = try checkStripped("structural JsonValue =\n  | null\n  | boolean\n  | number\n  | string\n  | readonly JsonValue[]\n  | Dict<string, JsonValue>;\nfunction kindOf(value: JsonValue): string {\n  return match (value) {\n    when null: \"null\"\n    when boolean: \"boolean\"\n    when number: \"number\"\n    when string: \"string\"\n    when array: \"array\"\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ k: kindOf(1) });\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .non_exhaustive_profile_match);
}

test "a union carrying Bytes is exhaustive with its Bytes arm" {
    // Spec 5.5's type tests are six now, and `when Bytes:` is the sixth. A
    // union covered member by member needs no `default`.
    var h = try checkStripped("structural Payload = boolean | number | string | Bytes;\nfunction kindOf(value: Payload): string {\n  return match (value) {\n    when boolean: \"boolean\"\n    when number: \"number\"\n    when string: \"string\"\n    when Bytes: \"bytes\"\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ k: kindOf(1) });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .non_exhaustive_profile_match);
}

test "dropping the Bytes arm leaves that union non-exhaustive" {
    // The half that makes the test above mean something: without it, a checker
    // that ignored the arm entirely would pass the covered case too.
    var h = try checkStripped("structural Payload = boolean | number | string | Bytes;\nfunction kindOf(value: Payload): string {\n  return match (value) {\n    when boolean: \"boolean\"\n    when number: \"number\"\n    when string: \"string\"\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ k: kindOf(1) });\n}\n");
    defer h.deinit();
    try expectKind(&h.checker, .non_exhaustive_profile_match);
}

test "the six arms cover it" {
    var h = try checkStripped("structural JsonValue =\n  | null\n  | boolean\n  | number\n  | string\n  | readonly JsonValue[]\n  | Dict<string, JsonValue>;\nfunction kindOf(value: JsonValue): string {\n  return match (value) {\n    when null: \"null\"\n    when boolean: \"boolean\"\n    when number: \"number\"\n    when string: \"string\"\n    when array: \"array\"\n    when Dict: \"dict\"\n  };\n}\nfunction handler(req: Request): Response {\n  return Response.json({ k: kindOf(1) });\n}\n");
    defer h.deinit();
    try expectNoKind(&h.checker, .non_exhaustive_profile_match);
}
