//! Default strict ZigTS profile.
//!
//! This pass enforces the smaller "expert" subset that keeps handler code
//! explicit enough for proof-driven tooling. It runs after parsing and the
//! normal type/sound passes, and before handler verification/contract work.

const std = @import("std");
const ir = @import("parser/ir.zig");
const object = @import("object.zig");
const context = @import("context.zig");
const type_env_mod = @import("type_env.zig");
const type_checker_mod = @import("type_checker.zig");
const type_pool_mod = @import("type_pool.zig");
const match_analysis_mod = @import("match_analysis.zig");
const bool_checker = @import("bool_checker.zig");
const repair_intent_mod = @import("repair_intent.zig");
const module_facts_mod = @import("module_facts.zig");
const known_globals = @import("known_globals.zig");

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
    missing_public_annotation,
    dynamic_capability_access,
    non_exhaustive_profile_match,
    avoidable_let,
    computed_property_access,
    mutable_live_iteration,
    canonical_arrow_helper,
    canonical_export_function_const,
    canonical_public_helper_effects,
    canonical_public_helper_proof,
    canonical_ternary_impure,
    canonical_ternary_chain,
    canonical_compound_assignment,
    canonical_non_leading_spread,
    canonical_template_complex_interp,
    canonical_call_spread,
    canonical_default_parameter,
    canonical_destructure_depth,
    canonical_unused_index_alias,
    canonical_redundant_bool_compare,
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
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
    static_literal_bindings: std.AutoHashMapUnmanaged(u32, void),
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
            .static_literal_bindings = .empty,
            .call_counts = .empty,
            .imported_functions = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *StrictChecker) void {
        if (self.owned_facts) |*owned| owned.deinit();
        self.imported_functions.deinit(self.allocator);
        self.call_counts.deinit(self.allocator);
        self.static_literal_bindings.deinit(self.allocator);
        self.annotated_function_bindings.deinit(self.allocator);
        self.assigned_bindings.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn check(self: *StrictChecker, root: NodeIndex) !u32 {
        if (self.type_checker) |tc| try tc.ensureHealthy();
        self.scanImports();
        self.collectAnnotatedFunctions(root);
        self.collectStaticLiterals(root);
        self.collectAssignments(root);
        self.collectCallCounts(root);
        self.walkStmt(root);
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

    pub fn formatDiagnostics(self: *const StrictChecker, source: []const u8, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            try writer.print("strict {s}: {s}\n", .{ diag.severity.label(), diag.message });
            try writer.print("  --> {d}:{d}\n", .{ loc.line, loc.column });
            if (getSourceLine(source, loc.line)) |line| {
                try writer.print("   |\n", .{});
                try writer.print("{d: >3} | {s}\n", .{ loc.line, line });
                try writer.print("   | ", .{});
                var col: u16 = 1;
                while (col < loc.column) : (col += 1) try writer.writeByte(' ');
                try writer.writeAll("^\n");
            }
            if (diag.help) |help| try writer.print("   = help: {s}\n", .{help});
            try writer.writeByte('\n');
        }
    }

    fn addDiagnostic(self: *StrictChecker, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch self.markAllocationFailure();
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
                self.checkFunctionParams(decl.init);
                if (self.ir_view.getFunction(decl.init)) |func| {
                    self.walkStmt(func.body);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.pattern != null_node) self.checkDestructurePattern(decl.pattern);
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
                self.checkUnusedIndexAlias(node, for_iter);
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
            .call, .method_call, .assignment => false,
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
            .template_literal => blk: {
                const tmpl = self.ir_view.getTemplate(node) orelse break :blk true;
                for (0..tmpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
                    const value = self.ir_view.getOptValue(part) orelse continue;
                    if (!self.isPureExpr(value)) break :blk false;
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

    fn walkExpr(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.checkRedundantBoolCompare(node, bin);
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
                    if (prop.is_computed and !self.isStaticComputedKey(prop.key)) {
                        self.addDiagnostic(.{
                            .severity = .err,
                            .kind = .computed_property_access,
                            .node = prop_idx,
                            .message = "dynamic computed object keys are not part of strict ZigTS",
                            .help = "use a literal field name so object shape stays compiler-visible",
                        });
                    }
                    self.walkExpr(prop.value);
                }
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(node) orelse return;
                for (0..tmpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
                    const value = self.ir_view.getOptValue(part) orelse continue;
                    const part_tag = self.ir_view.getTag(part);
                    const interp = part_tag != null and part_tag.? == .template_part_expr;
                    if (interp and !self.isSimpleTemplateInterp(value)) {
                        self.addDiagnostic(.{
                            .severity = self.canonicalSeverity(),
                            .kind = .canonical_template_complex_interp,
                            .node = part,
                            .message = "template interpolation must be an identifier or a literal-keyed property access",
                            .help = "hoist the expression into a `const` immediately above the template, then interpolate the new name",
                            .repair_intent = .name_const_above_template,
                        });
                    }
                    self.walkExpr(value);
                }
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return;
                self.walkExpr(match.discriminant);
                if (!self.matchHasDefault(match)) {
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
                self.checkFunctionParams(node);
                if (self.ir_view.getFunction(node)) |func| self.walkStmt(func.body);
            },
            .jsx_element => {
                const jsx = self.ir_view.getJsxElement(node) orelse return;
                for (0..jsx.props_count) |i| {
                    const attr_idx = self.ir_view.getListIndex(jsx.props_start, @intCast(i));
                    if (self.ir_view.getJsxAttr(attr_idx)) |attr| self.walkExpr(attr.value);
                }
                for (0..jsx.children_count) |i| {
                    self.walkExpr(self.ir_view.getListIndex(jsx.children_start, @intCast(i)));
                }
            },
            else => {},
        }
    }

    /// Checks only what being *exported* adds: ZTS609. Annotation is not
    /// checked here. `walkStmt`'s `.export_decl` arm walks the declaration
    /// right after this call, and that walk already reaches every function
    /// node - `.function_decl` directly, a function-valued initializer through
    /// `walkExpr`. Checking it here too emitted ZTS601 twice at one position
    /// for every `export function`.
    fn checkExportedDeclaration(self: *StrictChecker, node: NodeIndex) void {
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag != .var_decl) return;
        const decl = self.ir_view.getVarDecl(node) orelse return;
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

    /// Walk a destructuring pattern and flag nested binding patterns.
    /// `const {a: {b}} = obj` inflates review cost and tends to drift in
    /// agent output; canonical ZigTS keeps each destructure one level
    /// deep with intermediate `const` bindings for further drilling.
    fn checkDestructurePattern(self: *StrictChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .object_pattern, .array_pattern => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    const child = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
                    self.checkDestructurePattern(child);
                }
            },
            .pattern_element => {
                // `.pattern_rest` is excluded: rest elements never carry a
                // nested pattern (`elem.key` is always null_node for them),
                // so they cannot introduce destructure depth.
                const elem = self.ir_view.getPatternElem(node) orelse return;
                if (elem.key != null_node) {
                    self.addDiagnostic(.{
                        .severity = self.canonicalSeverity(),
                        .kind = .canonical_destructure_depth,
                        .node = node,
                        .message = "destructuring patterns must be at most one level deep",
                        .help = "destructure one level, then drill into the value with a follow-up `const`: `const {a} = obj; const {b} = a;`",
                        .repair_intent = .flatten_destructure,
                    });
                    self.checkDestructurePattern(elem.key);
                }
            },
            else => {},
        }
    }

    /// Walk a function's parameter list and flag canonical violations:
    /// default values at the signature site (ZTS617). Param walking is
    /// separate from `checkFunctionAnnotation` because parameter shape
    /// matters even when the function carries no type annotation - the
    /// canonical rules apply unconditionally.
    fn checkFunctionParams(self: *StrictChecker, node: NodeIndex) void {
        const func = self.ir_view.getFunction(node) orelse return;
        for (0..func.params_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const elem = self.ir_view.getPatternElem(param_idx) orelse continue;
            if (elem.default_value != null_node) {
                self.addDiagnostic(.{
                    .severity = self.canonicalSeverity(),
                    .kind = .canonical_default_parameter,
                    .node = param_idx,
                    .message = "default parameter values are not part of canonical ZigTS",
                    .help = "accept `(a: T | undefined)` and resolve the default in the body: `const resolved = a === undefined ? DEFAULT : a;`",
                    .repair_intent = .lift_default_to_body,
                });
            }
        }
    }

    /// ZTS619 canonical_unused_index_alias: detect for-of loops whose iterable
    /// is `<expr>.entries()` and whose body destructures the loop binding into
    /// `[<index>, <value>]` with `<index>` never read. The `.entries()` call
    /// and the destructure exist solely to introduce a name for the index;
    /// when that name is dead, iterating directly over `<expr>` collapses the
    /// loop body to a single binding and eliminates the alias-tracking branch
    /// the iterator-scope-confinement analysis would otherwise carry.
    fn checkUnusedIndexAlias(self: *StrictChecker, node: NodeIndex, for_iter: ir.Node.ForIterStmt) void {
        if (!self.isEntriesCall(for_iter.iterable)) return;
        if (for_iter.body == null_node) return;
        const body_tag = self.ir_view.getTag(for_iter.body) orelse return;

        // First statement of the loop body must be the destructuring binding.
        const first_stmt = if (body_tag == .block) blk: {
            const block = self.ir_view.getBlock(for_iter.body) orelse return;
            if (block.stmts_count == 0) return;
            break :blk self.ir_view.getListIndex(block.stmts_start, 0);
        } else for_iter.body;
        if (self.ir_view.getTag(first_stmt) != .var_decl) return;
        const decl = self.ir_view.getVarDecl(first_stmt) orelse return;
        if (decl.pattern == null_node) return;
        if (decl.init == null_node) return;

        // The destructure must source the loop binding directly: `const [...] = pair`
        // where `pair` is the for-of binding. Anything else is not the alias shape
        // ZTS619 targets.
        if (self.ir_view.getTag(decl.init) != .identifier) return;
        const init_binding = self.ir_view.getBinding(decl.init) orelse return;
        if (init_binding.scope_id != for_iter.binding.scope_id or
            init_binding.slot != for_iter.binding.slot) return;

        // Pattern must be a two-element array pattern: [index, value].
        if (self.ir_view.getTag(decl.pattern) != .array_pattern) return;
        const arr = self.ir_view.getArray(decl.pattern) orelse return;
        if (arr.elements_count != 2) return;

        const index_elem_idx = self.ir_view.getListIndex(arr.elements_start, 0);
        const index_elem = self.ir_view.getPatternElem(index_elem_idx) orelse return;
        if (index_elem.kind != .simple) return;

        // Conservative read check: if the index name appears anywhere in the
        // loop body as an identifier reference (other than its own binding
        // site), assume it's read and bail. This walks the body once.
        if (self.bindingReadInBody(for_iter.body, index_elem.binding)) return;

        self.addDiagnostic(.{
            .severity = self.canonicalSeverity(),
            .kind = .canonical_unused_index_alias,
            .node = node,
            .message = "for-of binds an index alias that is never read",
            .help = "drop `.entries()` and the destructure; iterate over the array directly",
            .repair_intent = .drop_unused_index_alias,
        });
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
        const tc = self.type_checker orelse return;
        if (tc.inferType(value_node) != tc.env.pool.idx_boolean) return;

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

    /// True when `node` is `<expr>.entries()` with no arguments.
    fn isEntriesCall(self: *const StrictChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag != .call and tag != .method_call) return false;
        const call = self.ir_view.getCall(node) orelse return false;
        if (call.args_count != 0) return false;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return false;
        if (callee_tag != .member_access) return false;
        const member = self.ir_view.getMember(call.callee) orelse return false;
        const method_name = self.resolveAtomName(member.property) orelse return false;
        return std.mem.eql(u8, method_name, "entries");
    }

    /// Walks `body` and returns true if `target` appears as an identifier
    /// reference. Bindings introduced inside the body (the var_decl that
    /// names `target` itself) do not count as reads; only identifier nodes
    /// that resolve to the binding do.
    fn bindingReadInBody(self: *const StrictChecker, body: NodeIndex, target: ir.BindingRef) bool {
        return self.scanBindingRead(body, target);
    }

    fn scanBindingRead(self: *const StrictChecker, node: NodeIndex, target: ir.BindingRef) bool {
        if (node == null_node) return false;
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(node) orelse return false;
                return binding.scope_id == target.scope_id and binding.slot == target.slot;
            },
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return false;
                for (0..block.stmts_count) |i| {
                    if (self.scanBindingRead(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), target)) return true;
                }
                return false;
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return false;
                // Skip the destructure pattern itself - the index name shows up
                // there as a binding site, not a read. Walk only the initializer.
                return self.scanBindingRead(decl.init, target);
            },
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return false;
                return self.scanBindingRead(decl.init, target);
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return false;
                return self.scanBindingRead(if_stmt.condition, target) or
                    self.scanBindingRead(if_stmt.then_branch, target) or
                    self.scanBindingRead(if_stmt.else_branch, target);
            },
            .for_of_stmt => {
                const inner = self.ir_view.getForIter(node) orelse return false;
                return self.scanBindingRead(inner.iterable, target) or
                    self.scanBindingRead(inner.body, target);
            },
            .return_stmt, .expr_stmt => {
                const value = self.ir_view.getOptValue(node) orelse return false;
                return self.scanBindingRead(value, target);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return false;
                return self.scanBindingRead(bin.left, target) or self.scanBindingRead(bin.right, target);
            },
            .unary_op, .spread => {
                const un = self.ir_view.getUnary(node) orelse return false;
                return self.scanBindingRead(un.operand, target);
            },
            .ternary => {
                const tern = self.ir_view.getTernary(node) orelse return false;
                return self.scanBindingRead(tern.condition, target) or
                    self.scanBindingRead(tern.then_branch, target) or
                    self.scanBindingRead(tern.else_branch, target);
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return false;
                return self.scanBindingRead(assign.target, target) or
                    self.scanBindingRead(assign.value, target);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return false;
                if (self.scanBindingRead(call.callee, target)) return true;
                for (0..call.args_count) |i| {
                    if (self.scanBindingRead(self.ir_view.getListIndex(call.args_start, @intCast(i)), target)) return true;
                }
                return false;
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return false;
                if (self.scanBindingRead(member.object, target)) return true;
                return self.scanBindingRead(member.computed, target);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return false;
                for (0..arr.elements_count) |i| {
                    if (self.scanBindingRead(self.ir_view.getListIndex(arr.elements_start, @intCast(i)), target)) return true;
                }
                return false;
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return false;
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    if (self.scanBindingRead(prop.value, target)) return true;
                }
                return false;
            },
            .template_literal => {
                const tmpl = self.ir_view.getTemplate(node) orelse return false;
                for (0..tmpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
                    if (self.ir_view.getOptValue(part)) |value| {
                        if (self.scanBindingRead(value, target)) return true;
                    }
                }
                return false;
            },
            .match_expr => {
                const match = self.ir_view.getMatchExpr(node) orelse return false;
                if (self.scanBindingRead(match.discriminant, target)) return true;
                for (0..match.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    if (self.scanBindingRead(arm.body, target)) return true;
                }
                return false;
            },
            else => return false,
        }
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
                if (self.functionHasAnnotation(decl.init)) {
                    self.annotated_function_bindings.put(self.allocator, bindingKey(decl.binding), {}) catch self.markAllocationFailure();
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init != null_node and self.isFunctionNode(decl.init) and self.functionHasAnnotation(decl.init)) {
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

    /// Canonical template interpolations are restricted to identifiers and
    /// chains of literal-keyed member access (`user.profile.name`). Anything
    /// else - function calls, arithmetic, ternaries, computed access - must
    /// be hoisted into a `const` above the template.
    fn isSimpleTemplateInterp(self: *const StrictChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        return switch (tag) {
            .identifier => true,
            .member_access => blk: {
                const member = self.ir_view.getMember(node) orelse break :blk false;
                if (member.computed != null_node) break :blk false;
                break :blk self.isSimpleTemplateInterp(member.object);
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
        if (tag != .template_literal) return false;
        const tmpl = self.ir_view.getTemplate(node) orelse return false;
        for (0..tmpl.parts_count) |i| {
            const part = self.ir_view.getListIndex(tmpl.parts_start, @intCast(i));
            if (self.ir_view.getTag(part) == .template_part_expr) return false;
        }
        return true;
    }

    fn resolveAtomName(self: *const StrictChecker, atom_value: u32) ?[]const u8 {
        const atom: object.Atom = @enumFromInt(atom_value);
        if (atom.isPredefined()) return atom.toPredefinedName();
        if (self.atoms) |table| return table.getName(atom);
        return null;
    }
};

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

fn bindingKey(binding: ir.BindingRef) u32 {
    return bool_checker.packBindingKey(binding.scope_id, binding.slot);
}

fn getSourceLine(source: []const u8, line_num: u32) ?[]const u8 {
    if (line_num == 0) return null;
    var current_line: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (current_line == line_num) return source[start..i];
            current_line += 1;
            start = i + 1;
        }
    }
    if (current_line == line_num) return source[start..];
    return null;
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
    const source = "function handler(req) { let x = 1; return Response.json({x}); }";
    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = StrictChecker.init(testing.allocator, view, null, null, null);
    defer checker.deinit();
    const errors = try checker.check(root);
    try testing.expect(errors > 0);
}

test "strict checker accepts reassigned let" {
    const source = "function handler(req) { let x = 1; x = 2; return Response.json({x}); }";
    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
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

test "canonical profile warns on reused arrow helper" {
    const source = "const parse = (x) => x; function handler(req) { const a = parse(1); const b = parse(2); return Response.json({a,b}); }";
    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
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
        \\  return Response.json({ a, b });
        \\}
    ;
    var stripped = try @import("stripper.zig").strip(testing.allocator, source, .{});
    defer stripped.deinit();

    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, stripped.code);
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
    const source = "const parse = (x) => x; function handler(req) { const a = parse(1); return Response.json({a}); }";
    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
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

fn countKind(checker: *const StrictChecker, kind: DiagnosticKind) usize {
    var n: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == kind) n += 1;
    }
    return n;
}

test "StrictChecker fails closed when profile facts cannot allocate" {
    const allocator = testing.allocator;
    var parser = try @import("parser/root.zig").JsParser.init(allocator, "let answer = 42;");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = StrictChecker.init(failing.allocator(), view, null, null, null);
    defer checker.deinit();
    try testing.expectError(error.OutOfMemory, checker.check(root));
}

fn checkSource(source: []const u8) !StrictChecker {
    var parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
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
    parser: @import("parser/root.zig").JsParser,
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
    h.parser = try @import("parser/root.zig").JsParser.init(testing.allocator, source);
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
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 200 : 500; return Response.json({x}); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_ternary_impure);
        try testing.expect(diag.kind != .canonical_ternary_chain);
    }
}

test "ternary with a call arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? load(req) : 500; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "ternary with an assignment arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { let n = 0; const x = req.method === 'GET' ? (n = 1) : 500; return Response.json({x, n}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "ternary over pure composite arms is admitted" {
    // Array, object, and template arms are pure when every part is pure, so
    // the recursion must reach into them rather than defaulting to pure.
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? [req.url, 1] : [req.url, 2]; return Response.json({x}); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_ternary_impure);
    }
}

test "ternary with a call nested inside a composite arm fires impure diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? [load(req)] : [500]; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_impure);
}

test "chained ternary fires chain diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? 1 : req.method === 'POST' ? 2 : 3; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_chain);
}

test "chained ternary in the then branch fires chain diagnostic" {
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? (req.url === '/a' ? 1 : 2) : 3; return Response.json({x}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_ternary_chain);
}

test "canonical_compound_assignment fires on +=" {
    var checker = try checkSource("function handler(req) { let n = 0; n += 1; return Response.json({n}); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_compound_assignment);
}

test "canonical_compound_assignment does not fire on plain =" {
    var checker = try checkSource("function handler(req) { let n = 0; n = n + 1; return Response.json({n}); }");
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

test "canonical_template_complex_interp fires on a call inside interpolation" {
    var checker = try checkSource("function getName() { return 'x'; } function handler(req) { return Response.text(`hi ${getName()}`); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_template_complex_interp);
}

test "canonical_template_complex_interp accepts identifier and member access" {
    var checker = try checkSource("function handler(req) { const user = {name: 'a'}; return Response.text(`hi ${user.name}`); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_template_complex_interp);
    }
}

test "canonical_call_spread accepts positional args" {
    var checker = try checkSource("function send(a, b) { return a + b; } function handler(req) { return Response.json({n: send(1, 2)}); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_call_spread);
    }
}

test "canonical_default_parameter fires on a signature default" {
    var checker = try checkSource("function greet(name = 'world') { return name; } function handler(req) { return Response.text(greet()); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_default_parameter);
}

test "canonical_default_parameter accepts explicit undefined-resolved defaults" {
    var checker = try checkSource("function greet(name) { const resolved = name === undefined ? 'world' : name; return resolved; } function handler(req) { return Response.text(greet(undefined)); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_default_parameter);
    }
}

test "canonical_destructure_depth fires on nested object pattern" {
    var checker = try checkSource("function handler(req) { const payload = {user: {name: 'a'}}; const {user: {name}} = payload; return Response.text(name); }");
    defer checker.deinit();
    try expectKind(&checker, .canonical_destructure_depth);
}

test "canonical_destructure_depth accepts flat destructure" {
    var checker = try checkSource("function handler(req) { const payload = {user: 'a'}; const {user} = payload; return Response.text(user); }");
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_destructure_depth);
    }
}

test "canonical_ternary_impure diagnostic carries repair_intent = replace_ternary_with_if" {
    // Every veto-able strict diagnostic must populate the typed repair
    // primitive so the agent picks an apply step
    // directly. ZTS612 is the representative canonical-profile case.
    var checker = try checkSource("function handler(req) { const x = req.method === 'GET' ? load(req) : 500; return Response.json({x}); }");
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

test "canonical_unused_index_alias fires when index is never read" {
    var checker = try checkSource(
        \\function handler(req) {
        \\  const arr = [10, 20];
        \\  for (const pair of arr.entries()) {
        \\    const [_i, x] = pair;
        \\    const _used = x;
        \\  }
        \\  return Response.json({ok: true});
        \\}
    );
    defer checker.deinit();
    try expectKind(&checker, .canonical_unused_index_alias);
}

test "canonical_unused_index_alias does not fire when index is read" {
    var checker = try checkSource(
        \\function handler(req) {
        \\  const arr = [10, 20];
        \\  for (const pair of arr.entries()) {
        \\    const [i, x] = pair;
        \\    const _seen = i + x;
        \\  }
        \\  return Response.json({ok: true});
        \\}
    );
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_unused_index_alias);
    }
}

test "canonical_unused_index_alias does not fire on plain for-of" {
    var checker = try checkSource(
        \\function handler(req) {
        \\  const arr = [10, 20];
        \\  for (const x of arr) {
        \\    const _used = x;
        \\  }
        \\  return Response.json({ok: true});
        \\}
    );
    defer checker.deinit();
    for (checker.getDiagnostics()) |diag| {
        try testing.expect(diag.kind != .canonical_unused_index_alias);
    }
}

test "canonical_unused_index_alias diagnostic carries repair_intent" {
    var checker = try checkSource(
        \\function handler(req) {
        \\  const arr = [10, 20];
        \\  for (const pair of arr.entries()) {
        \\    const [_i, x] = pair;
        \\    const _used = x;
        \\  }
        \\  return Response.json({ok: true});
        \\}
    );
    defer checker.deinit();
    var saw = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind == .canonical_unused_index_alias) {
            saw = true;
            try testing.expectEqual(
                @as(?RepairIntent, .drop_unused_index_alias),
                diag.repair_intent,
            );
        }
    }
    try testing.expect(saw);
}

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
    var parser = try @import("parser/parse.zig").Parser.init(allocator, source);
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

    var parser = try @import("parser/parse.zig").Parser.init(allocator, source);
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
