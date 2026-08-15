//! Strict Boolean Enforcement
//!
//! Static analysis pass that enforces boolean-typed values in boolean contexts:
//! - if/ternary conditions must be boolean
//! - && and || operands must be boolean
//! - ! operand must be boolean
//! - ?? LHS that is provably non-nullable triggers a warning
//!
//! Modeled on handler_verifier.zig: walks the IR tree inferring expression types.
//! When inferType returns .unknown, no diagnostic is emitted (escape hatch for
//! function calls, parameters, property accesses). Runtime VM assertions in the
//! interpreter catch those cases at execution time.

const std = @import("std");
const stripper = @import("zts-engine").stripper;
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const module_facts_mod = @import("module_facts.zig");
const type_checker_mod = @import("type_checker.zig");
const type_pool_mod = @import("type_pool.zig");
const node_types = @import("zts-engine").node_types;

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;

// ---------------------------------------------------------------------------
// Expression type inference
// ---------------------------------------------------------------------------

/// The inference lattice and the map it fills live in `node_types.zig` so
/// `parser/codegen.zig` can read type annotations without importing this
/// checker. Re-exported here because this is where they are produced and
/// where every caller already looks for them.
pub const ExprType = node_types.ExprType;

/// Unify two types into a single type. Returns .unknown if they're incompatible.
/// Handles optional promotion: string + undefined -> optional_string, etc.
fn unifyTypes(a: ExprType, b: ExprType) ExprType {
    if (a == b) return a;
    // Optional promotion: T + undefined -> optional_T
    if (a == .undefined) return makeNullable(b);
    if (b == .undefined) return makeNullable(a);
    // optional_T + T -> optional_T
    if (a == .optional_string and b == .string) return .optional_string;
    if (a == .string and b == .optional_string) return .optional_string;
    if (a == .optional_object and b == .object) return .optional_object;
    if (a == .object and b == .optional_object) return .optional_object;
    return .unknown;
}

/// Promote a type to its optional variant. Returns .unknown for types without optional variants.
fn makeNullable(t: ExprType) ExprType {
    return switch (t) {
        .string, .optional_string => .optional_string,
        .object, .optional_object => .optional_object,
        .undefined => .undefined,
        else => .unknown,
    };
}

/// Merge a new return type into an accumulator. Returns null if incompatible.
fn mergeReturnType(current: ?ExprType, new: ExprType) ?ExprType {
    if (current) |c| {
        if (c == new) return c;
        const unified = unifyTypes(c, new);
        return if (unified == .unknown) null else unified;
    }
    return new;
}

pub fn packBindingKey(scope_id: ir.ScopeId, slot: u16) u32 {
    return (@as(u32, scope_id) << 16) | @as(u32, slot);
}

fn bindingKey(binding: ir.BindingRef) u32 {
    return packBindingKey(binding.scope_id, binding.slot);
}

// ---------------------------------------------------------------------------
// Diagnostic types
// ---------------------------------------------------------------------------

pub const Severity = enum {
    err,
    warning,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

pub const DiagnosticKind = enum {
    condition_not_boolean, // if/ternary condition is non-boolean
    logical_operand_not_boolean, // && or || operand is non-boolean
    not_operand_not_boolean, // ! operand is non-boolean
    nullish_on_non_nullable, // ?? LHS is provably non-nullable
    arithmetic_on_non_numeric, // arithmetic operator on provably non-numeric type
    mixed_type_add, // number + string or string + number
    add_on_non_addable, // + operator on non-numeric/non-string type
    tautological_comparison, // comparison is always true or always false
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    /// Whether the message was dynamically allocated (needs freeing).
    allocated: bool = false,
};

// ---------------------------------------------------------------------------
// BoolChecker
// ---------------------------------------------------------------------------

pub const NodeTypeMap = node_types.NodeTypeMap;

pub const BoolChecker = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    diagnostics: std.ArrayList(Diagnostic),
    /// Tracks inferred type for const/let bindings: packed(scope_id, slot) -> ExprType
    const_types: std.AutoHashMapUnmanaged(u32, ExprType),
    /// Tracks inferred return type for function bindings: packed(scope_id, slot) -> ExprType
    fn_return_types: std.AutoHashMapUnmanaged(u32, ExprType),
    /// Branch-scoped type narrowings from typeof guards.
    /// Checked before const_types in inferType for ALL binding kinds.
    /// Entries are temporary: installed before walking a branch, removed after.
    narrowed_types: std.AutoHashMapUnmanaged(u32, ExprType),
    /// Virtual module import binding tracking: local slot -> return type.
    /// Populated by scanImports before the main walk.
    module_fn_types: std.AutoHashMapUnmanaged(u16, ExprType),
    /// Local slots bound to Result-producing module functions (jwtVerify, etc.).
    /// Used in walkStmt to detect `const r = jwtVerify(...)` and track result_bindings.
    module_result_fn_slots: std.AutoHashMapUnmanaged(u16, void),
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the checker. Null means build a private one.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Binding slots that hold Result objects (from jwtVerify, validateJson, etc.).
    /// Used to infer result.ok as boolean. Key: packed(scope_id, slot).
    result_bindings: std.AutoHashMapUnmanaged(u32, void),
    /// Per-node type annotations for codegen specialization.
    /// Populated for binary ops where both operands have known types.
    node_types: NodeTypeMap,
    /// Full TypePool inference is the authority for boolean assignability.
    /// Direct checker tests may omit it, in which case the smaller local
    /// lattice still fails closed rather than admitting an unknown value.
    authoritative_type_checker: ?*const type_checker_mod.TypeChecker = null,
    /// Sticky failure for proof-relevant maps and diagnostic storage. The
    /// walkers are intentionally void-returning; `check` converts any failed
    /// state update into OutOfMemory before exposing counts. Formatting-only
    /// message duplication may still fall back to a static core diagnostic.
    allocation_failed: bool = false,

    const TypeofGuard = struct {
        binding_key: u32,
        narrowed_type: ExprType,
        op: ir.BinaryOp,
    };

    const MAX_NARROWINGS = 4;

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*context.AtomTable) BoolChecker {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .diagnostics = .empty,
            .const_types = .empty,
            .fn_return_types = .empty,
            .narrowed_types = .empty,
            .module_fn_types = .empty,
            .module_result_fn_slots = .empty,
            .result_bindings = .empty,
            .node_types = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *BoolChecker) void {
        // Free dynamically allocated diagnostic messages
        for (self.diagnostics.items) |diag| {
            if (diag.allocated) {
                self.allocator.free(diag.message);
            }
        }
        self.diagnostics.deinit(self.allocator);
        self.const_types.deinit(self.allocator);
        self.fn_return_types.deinit(self.allocator);
        self.narrowed_types.deinit(self.allocator);
        if (self.owned_facts) |*owned| owned.deinit();
        self.module_fn_types.deinit(self.allocator);
        self.module_result_fn_slots.deinit(self.allocator);
        self.result_bindings.deinit(self.allocator);
        self.node_types.deinit(self.allocator);
    }

    /// Run the checker on the given root node. Returns the number of errors.
    pub fn check(self: *BoolChecker, root: NodeIndex) !u32 {
        self.scanImports();
        self.walkStmt(root);
        if (self.allocation_failed) return error.OutOfMemory;
        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        return error_count;
    }

    pub fn getDiagnostics(self: *const BoolChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    // -----------------------------------------------------------------------
    // Diagnostic formatting (mirrors handler_verifier.zig)
    // -----------------------------------------------------------------------

    pub fn formatDiagnostics(self: *const BoolChecker, source: stripper.SourceView, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            try writer.print("{s}: {s}\n", .{ diag.severity.label(), diag.message });
            try source.writeLocation(loc.line, loc.column, writer);
            if (diag.help) |help| try writer.print("   = help: {s}\n", .{help});
            try writer.writeByte('\n');
        }
    }

    // -----------------------------------------------------------------------
    // Statement walking
    // -----------------------------------------------------------------------

    fn walkStmt(self: *BoolChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    self.walkStmt(stmt_idx);
                }
            },

            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;
                // S1: condition must have type boolean.
                self.requireBoolean(if_s.condition, "if");
                // A boolean-producing outer expression does not make its
                // operands boolean. Recurse so `!value` and `a && b` enforce
                // their own operand contracts.
                self.walkExpr(if_s.condition);

                // Extract explicit guards from the condition for branch-scoped
                // narrowing. Bare-value truthiness is not a guard.
                var guards: [MAX_NARROWINGS]TypeofGuard = undefined;
                var saved: [MAX_NARROWINGS]?ExprType = undefined;
                var is_negated = false;
                const guard_count = self.extractTypeofGuards(if_s.condition, &guards, &is_negated);
                const active = guards[0..guard_count];
                const saved_active = saved[0..guard_count];

                if (active.len > 0 and is_negated) {
                    // Negated guard: narrow in else-branch only
                    self.walkStmt(if_s.then_branch);
                    if (if_s.else_branch != null_node) {
                        self.walkStmtWithGuards(if_s.else_branch, active, saved_active);
                    }
                } else {
                    // Positive guard or no guard (install/restore are no-ops on empty slice)
                    self.walkStmtWithGuards(if_s.then_branch, active, saved_active);
                    if (if_s.else_branch != null_node) {
                        self.walkStmt(if_s.else_branch);
                    }
                }
            },

            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                // Walk the initializer expression for nested checks
                if (vd.init != null_node) {
                    self.walkExpr(vd.init);
                    // Track const and let binding types
                    // Let bindings are invalidated on reassignment (see .assignment handler)
                    if (vd.kind == .@"const" or vd.kind == .let) {
                        const inferred = self.inferType(vd.init);
                        const key = bindingKey(vd.binding);
                        self.const_types.put(self.allocator, key, inferred) catch self.markAllocationFailure();

                        // If binding is a function, try to infer its return type
                        if (inferred == .function) {
                            const ret_type = self.inferFunctionReturnType(vd.init);
                            if (ret_type != .unknown) {
                                self.fn_return_types.put(self.allocator, key, ret_type) catch self.markAllocationFailure();
                            }
                        }

                        // Track Result bindings: const r = jwtVerify(...)
                        if (inferred == .object) {
                            if (self.isResultCall(vd.init)) {
                                self.result_bindings.put(self.allocator, key, {}) catch self.markAllocationFailure();
                            }
                        }
                    }
                }
            },

            .return_stmt => {
                // Walk optional return value expression
                if (self.ir_view.getOptValue(node)) |ret_val| {
                    self.walkExpr(ret_val);
                }
            },

            .assert_stmt => {
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                self.requireBoolean(assert.condition, "assert");
                self.walkExpr(assert.condition);
                if (assert.error_expr != null_node) {
                    self.walkExpr(assert.error_expr);
                }
            },

            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    self.walkExpr(expr);
                }
            },

            .for_of_stmt, .for_in_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                self.walkExpr(fi.iterable);
                self.walkStmt(fi.body);
            },

            .switch_stmt => {
                const sw = self.ir_view.getSwitchStmt(node) orelse return;
                self.walkExpr(sw.discriminant);
                for (0..sw.cases_count) |i| {
                    const case_idx = self.ir_view.getListIndex(sw.cases_start, @intCast(i));
                    const cc = self.ir_view.getCaseClause(case_idx) orelse continue;
                    if (cc.test_expr != null_node) self.walkExpr(cc.test_expr);
                    for (0..cc.body_count) |j| {
                        const body_stmt = self.ir_view.getListIndex(cc.body_start, @intCast(j));
                        self.walkStmt(body_stmt);
                    }
                }
            },

            .function_decl => {
                const func = self.ir_view.getFunction(node) orelse return;
                // Track function return type for named declarations.
                // Use the binding's scope+slot as the key, not the raw name atom.
                // Two functions in different scopes with the same name share the same
                // name_atom but have different (scope_id, slot) pairs.
                const ret_type = self.inferFunctionReturnType(node);
                if (ret_type != .unknown) {
                    if (self.ir_view.getBinding(node)) |binding| {
                        const key = packBindingKey(binding.scope_id, binding.slot);
                        self.fn_return_types.put(self.allocator, key, ret_type) catch self.markAllocationFailure();
                        self.const_types.put(self.allocator, key, .function) catch self.markAllocationFailure();
                    } else if (func.name_atom != 0) {
                        // Fallback: top-level declarations with no binding info use name atom.
                        const key = @as(u32, func.name_atom);
                        self.fn_return_types.put(self.allocator, key, ret_type) catch self.markAllocationFailure();
                        self.const_types.put(self.allocator, key, .function) catch self.markAllocationFailure();
                    }
                }
                self.walkStmt(func.body);
            },

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                self.walkStmt(func.body);
            },

            .export_default => {
                if (self.ir_view.getOptValue(node)) |val| {
                    self.walkStmt(val);
                }
            },

            // Expression-position tags that can appear as statements
            .binary_op,
            .unary_op,
            .ternary,
            .call,
            .method_call,
            .assignment,
            .match_expr,
            .template_literal,
            => {
                self.walkExpr(node);
            },

            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Expression walking (checks boolean contexts + recurses)
    // -----------------------------------------------------------------------

    fn walkExpr(self: *BoolChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                switch (bin.op) {
                    // S2: && and || operands must be boolean
                    .and_op, .or_op => {
                        const op_name = if (bin.op == .and_op) "&&" else "||";
                        self.requireBoolean(bin.left, op_name);
                        self.requireBoolean(bin.right, op_name);
                    },
                    // S4: ?? LHS warning for non-nullable
                    .nullish => {
                        const lhs_type = self.inferType(bin.left);
                        if (lhs_type.isNonNullable()) {
                            self.addDiagnostic(.{
                                .severity = .warning,
                                .kind = .nullish_on_non_nullable,
                                .node = node,
                                .message = "left side of '??' is never undefined",
                                .help = "remove the '??' fallback; it is unreachable",
                            });
                        }
                    },
                    // S5: Arithmetic operators require numeric operands
                    .sub, .mul, .div, .mod, .pow => {
                        const op_name: []const u8 = switch (bin.op) {
                            .sub => "-",
                            .mul => "*",
                            .div => "/",
                            .mod => "%",
                            .pow => "**",
                            else => unreachable,
                        };
                        self.requireNumeric(bin.left, op_name);
                        self.requireNumeric(bin.right, op_name);
                    },
                    // S6: + operator requires matching types
                    .add => {
                        const left_type = self.inferType(bin.left);
                        const right_type = self.inferType(bin.right);
                        // Mixed type: number + string or string + number
                        if ((left_type == .number and right_type == .string) or
                            (left_type == .string and right_type == .number))
                        {
                            self.addDiagnostic(.{
                                .severity = .err,
                                .kind = .mixed_type_add,
                                .node = node,
                                .message = "implicit type coercion in '+'; number and string operands",
                                .help = "use template literal for string interpolation, or parseInt()/parseFloat() for numeric conversion",
                            });
                        } else {
                            // Check each operand is addable (number, string, or unknown)
                            self.requireAddable(bin.left, left_type);
                            self.requireAddable(bin.right, right_type);
                        }
                    },
                    // S7: Tautological comparisons
                    .strict_eq, .strict_neq => {
                        self.checkTautologicalComparison(node, bin);
                    },
                    else => {},
                }
                // Annotate binary op nodes for type-directed codegen.
                // Uses inferType results (cheap for leaf nodes; avoids redundancy
                // with the checks above for non-leaf cases).
                self.annotateNodeType(node, bin.op, self.inferType(bin.left), self.inferType(bin.right));
                // Recurse into sub-expressions
                self.walkExpr(bin.left);
                self.walkExpr(bin.right);
            },

            .unary_op => {
                const un = self.ir_view.getUnary(node) orelse return;
                // S3: ! operand must be boolean
                if (un.op == .not) {
                    self.requireBoolean(un.operand, "!");
                }
                self.walkExpr(un.operand);
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return;
                // S1: ternary condition must have type boolean.
                self.requireBoolean(t.condition, "ternary");
                self.walkExpr(t.condition);

                // Extract guards from condition for branch-scoped narrowing
                var guards: [MAX_NARROWINGS]TypeofGuard = undefined;
                var saved: [MAX_NARROWINGS]?ExprType = undefined;
                var is_negated = false;
                const guard_count = self.extractTypeofGuards(t.condition, &guards, &is_negated);
                const active = guards[0..guard_count];
                const saved_active = saved[0..guard_count];

                if (active.len > 0 and is_negated) {
                    self.walkExpr(t.then_branch);
                    self.walkExprWithGuards(t.else_branch, active, saved_active);
                } else {
                    self.walkExprWithGuards(t.then_branch, active, saved_active);
                    self.walkExpr(t.else_branch);
                }
            },

            .call => {
                const c = self.ir_view.getCall(node) orelse return;
                self.walkExpr(c.callee);
                for (0..c.args_count) |i| {
                    const arg = self.ir_view.getListIndex(c.args_start, @intCast(i));
                    self.walkExpr(arg);
                }
            },

            .method_call => {
                // method_call uses CallExpr layout: callee is the object.method member_access node
                const mc = self.ir_view.getCall(node) orelse return;
                self.walkExpr(mc.callee);
                for (0..mc.args_count) |i| {
                    const arg = self.ir_view.getListIndex(mc.args_start, @intCast(i));
                    self.walkExpr(arg);
                }
            },

            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return;
                self.walkExpr(asgn.value);
                // Invalidate let binding type on reassignment, then re-track
                const target_tag = self.ir_view.getTag(asgn.target) orelse return;
                if (target_tag == .identifier) {
                    const binding = self.ir_view.getBinding(asgn.target) orelse return;
                    const key = (@as(u32, binding.scope_id) << 16) | @as(u32, binding.slot);
                    // Invalidate branch-scoped narrowing on reassignment
                    _ = self.narrowed_types.remove(key);
                    // Re-infer from the new value (simple assignment only)
                    if (asgn.op == null) {
                        const new_type = self.inferType(asgn.value);
                        self.const_types.put(self.allocator, key, new_type) catch self.markAllocationFailure();
                    } else {
                        // Compound assignment - invalidate to unknown
                        _ = self.const_types.remove(key);
                    }
                }
            },

            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    const elem = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
                    self.walkExpr(elem);
                }
            },

            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop_data = self.ir_view.getProperty(prop) orelse continue;
                    self.walkExpr(prop_data.value);
                }
            },

            .match_expr => {
                const me = self.ir_view.getMatchExpr(node) orelse return;
                self.walkExpr(me.discriminant);
                for (0..me.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    self.walkExpr(arm.body);
                }
            },

            .template_literal => {
                const tpl = self.ir_view.getTemplate(node) orelse return;
                for (0..tpl.parts_count) |i| {
                    const part = self.ir_view.getListIndex(tpl.parts_start, @intCast(i));
                    const part_tag = self.ir_view.getTag(part) orelse continue;
                    if (part_tag == .template_part_expr) {
                        if (self.ir_view.getOptValue(part)) |expr| {
                            self.walkExpr(expr);
                        }
                    }
                }
            },

            // Function expressions: walk body for boolean checks
            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                self.walkStmt(func.body);
            },

            // Leaf expressions - no children to walk
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .identifier,
            .member_access,
            .computed_access,
            .optional_chain,
            .spread,
            => {},

            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // Type inference
    // -----------------------------------------------------------------------

    fn inferType(self: *BoolChecker, node: NodeIndex) ExprType {
        if (node == null_node) return .unknown;
        const tag = self.ir_view.getTag(node) orelse return .unknown;

        return switch (tag) {
            // Literals
            .lit_bool => .boolean,
            .lit_int, .lit_float => .number,
            .lit_string, .template_literal => .string,
            // `null` is not `undefined`. This lattice has no member for it, and
            // answering `.undefined` here would let a `null` value satisfy an
            // absence test it does not satisfy, so it answers "cannot tell".
            .lit_null => .unknown,
            .lit_undefined => .undefined,
            .object_literal, .array_literal => .object,
            .function_expr, .arrow_function, .function_decl => .function,

            .binary_op => self.inferBinaryType(node),
            .unary_op => self.inferUnaryType(node),

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return .unknown;
                const then_type = self.inferType(t.then_branch);
                const else_type = self.inferType(t.else_branch);
                return unifyTypes(then_type, else_type);
            },

            .identifier => {
                const binding = self.ir_view.getBinding(node) orelse return .unknown;
                const key = bindingKey(binding);
                // Branch-scoped narrowing (applies to ALL binding kinds including .argument)
                if (self.narrowed_types.get(key)) |t| return t;
                // Existing: const/let tracking (local/global only)
                if (binding.kind == .local or binding.kind == .global) {
                    if (self.const_types.get(key)) |t| return t;
                }
                return .unknown;
            },

            .match_expr => self.inferMatchType(node),

            .call => self.inferCallReturnType(node),

            .member_access => self.inferMemberAccessType(node),

            // Method calls, computed access - cannot determine statically
            .method_call,
            .computed_access,
            .optional_chain,
            .spread,
            => .unknown,

            else => .unknown,
        };
    }

    fn inferBinaryType(self: *BoolChecker, node: NodeIndex) ExprType {
        const bin = self.ir_view.getBinary(node) orelse return .unknown;

        return switch (bin.op) {
            // These are emitted only by the isolated comptime expression
            // profile. Treat an unexpected reach as unknown instead of
            // teaching the normal checker JavaScript coercion semantics.
            .loose_eq, .loose_neq => .unknown,

            // Comparisons always produce boolean
            .strict_eq, .strict_neq, .lt, .lte, .gt, .gte => .boolean,

            // Logical ops: both sides boolean -> boolean
            .and_op, .or_op => .boolean,

            // Arithmetic
            .sub, .mul, .div, .mod, .pow => .number,

            // Add: string if either side is string, number if both number, else unknown
            .add => {
                const left_type = self.inferType(bin.left);
                const right_type = self.inferType(bin.right);
                if (left_type == .string or right_type == .string) return .string;
                if (left_type == .number and right_type == .number) return .number;
                return .unknown;
            },

            // Bitwise ops
            .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => .number,

            // Nullish coalescing: Join(RemoveNullish(LHS), RHS)
            .nullish => {
                const left_type = self.inferType(bin.left);
                const right_type = self.inferType(bin.right);
                // optional_string ?? string -> string
                if (left_type == .optional_string and right_type == .string) return .string;
                if (left_type == .optional_object and right_type == .object) return .object;
                // optional_string ?? number -> unknown (mismatched base types)
                if (left_type == .optional_string and right_type != .string and right_type != .unknown) return .unknown;
                if (left_type == .optional_object and right_type != .object and right_type != .unknown) return .unknown;
                // Non-nullable ?? anything -> non-nullable (the RHS is dead code, warned above)
                if (left_type.isNonNullable()) return left_type;
                // undefined ?? T -> T
                if (left_type == .undefined) return right_type;
                // unknown ?? T -> unknown (conservative)
                return .unknown;
            },
        };
    }

    fn inferUnaryType(self: *const BoolChecker, node: NodeIndex) ExprType {
        const un = self.ir_view.getUnary(node) orelse return .unknown;

        return switch (un.op) {
            .not => .boolean,
            .neg, .bit_not => .number,
            .typeof_op => .string,
        };
    }

    /// Infer the type of a match expression by unifying arm body types.
    fn inferMatchType(self: *BoolChecker, node: NodeIndex) ExprType {
        const me = self.ir_view.getMatchExpr(node) orelse return .unknown;
        if (me.arms_count == 0) return .unknown;
        var result: ?ExprType = null;
        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse return .unknown;
            const arm_type = self.inferType(arm.body);
            result = mergeReturnType(result, arm_type) orelse return .unknown;
        }
        return result orelse .unknown;
    }

    // -----------------------------------------------------------------------
    // Function return type inference
    // -----------------------------------------------------------------------

    /// Infer the return type of a function expression or arrow function.
    /// Handles: single-expression arrows `(x) => x > 0` and block-bodied
    /// functions with a uniform return type across all return statements.
    fn inferFunctionReturnType(self: *BoolChecker, node: NodeIndex) ExprType {
        const tag = self.ir_view.getTag(node) orelse return .unknown;
        if (tag != .arrow_function and tag != .function_expr and tag != .function_decl) return .unknown;

        const func = self.ir_view.getFunction(node) orelse return .unknown;
        if (func.body == null_node) return .unknown;

        const body_tag = self.ir_view.getTag(func.body) orelse return .unknown;

        // Single-expression arrow: body is wrapped in a return_stmt by the parser
        if (body_tag == .return_stmt) {
            const ret_val = self.ir_view.getOptValue(func.body) orelse return .undefined;
            return self.inferType(ret_val);
        }

        // Other non-block body (shouldn't happen normally, but handle gracefully)
        if (body_tag != .block and body_tag != .program) {
            return self.inferType(func.body);
        }

        // Block body: collect return types
        return self.inferBlockReturnType(func.body);
    }

    /// Scan a block for return statements and infer a uniform return type.
    fn inferBlockReturnType(self: *BoolChecker, block_node: NodeIndex) ExprType {
        const block = self.ir_view.getBlock(block_node) orelse return .unknown;
        var return_type: ?ExprType = null;

        for (0..block.stmts_count) |i| {
            const stmt_idx = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
            const stmt_tag = self.ir_view.getTag(stmt_idx) orelse continue;

            switch (stmt_tag) {
                .return_stmt => {
                    const ret_val = self.ir_view.getOptValue(stmt_idx) orelse {
                        // bare return -> undefined
                        return_type = mergeReturnType(return_type, .undefined) orelse return .unknown;
                        continue;
                    };
                    const this_type = self.inferType(ret_val);
                    return_type = mergeReturnType(return_type, this_type) orelse return .unknown;
                },
                .if_stmt => {
                    // Recurse into if branches
                    const if_s = self.ir_view.getIfStmt(stmt_idx) orelse continue;
                    if (self.inferBranchReturnType(if_s.then_branch)) |tt| {
                        return_type = mergeReturnType(return_type, tt) orelse return .unknown;
                    }
                    if (if_s.else_branch != null_node) {
                        if (self.inferBranchReturnType(if_s.else_branch)) |et| {
                            return_type = mergeReturnType(return_type, et) orelse return .unknown;
                        }
                    }
                },
                else => {},
            }
        }

        return return_type orelse .unknown;
    }

    /// Infer return type from a branch (block or single statement).
    fn inferBranchReturnType(self: *BoolChecker, node: NodeIndex) ?ExprType {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag == .block or tag == .program) {
            const t = self.inferBlockReturnType(node);
            return if (t == .unknown) null else t;
        }
        if (tag == .return_stmt) {
            const ret_val = self.ir_view.getOptValue(node) orelse return .undefined;
            return self.inferType(ret_val);
        }
        return null;
    }

    /// Infer the return type of a call expression by looking up the callee.
    fn inferCallReturnType(self: *BoolChecker, node: NodeIndex) ExprType {
        const call = self.ir_view.getCall(node) orelse return .unknown;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return .unknown;

        if (callee_tag == .identifier) {
            const binding = self.ir_view.getBinding(call.callee) orelse return .unknown;

            // Check virtual module import bindings first
            if (self.module_fn_types.get(binding.slot)) |ret_type| return ret_type;

            // Then check locally-inferred function return types
            const key = bindingKey(binding);
            if (self.fn_return_types.get(key)) |ret_type| return ret_type;
        }

        return .unknown;
    }

    /// Check if a call node invokes a Result-producing function.
    fn isResultCall(self: *const BoolChecker, node: NodeIndex) bool {
        const call_tag = self.ir_view.getTag(node) orelse return false;
        if (call_tag != .call) return false;
        const call = self.ir_view.getCall(node) orelse return false;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return false;
        if (callee_tag != .identifier) return false;
        const binding = self.ir_view.getBinding(call.callee) orelse return false;
        return self.module_result_fn_slots.contains(binding.slot);
    }

    // -----------------------------------------------------------------------
    // Property access type inference (Phase 4)
    // -----------------------------------------------------------------------

    /// Known property types for Result objects: { ok: boolean, value: unknown, error?: string, errors?: unknown }
    fn resultPropertyType(self: *const BoolChecker, prop_atom: u16) ExprType {
        const name = self.resolveAtomName(prop_atom) orelse return .unknown;
        if (std.mem.eql(u8, name, "ok")) return .boolean;
        if (std.mem.eql(u8, name, "error")) return .string;
        if (std.mem.eql(u8, name, "errors")) return .unknown;
        if (std.mem.eql(u8, name, "value")) return .unknown;
        return .unknown;
    }

    /// Infer the type of a member access expression (obj.prop).
    fn inferMemberAccessType(self: *BoolChecker, node: NodeIndex) ExprType {
        const member = self.ir_view.getMember(node) orelse return .unknown;

        // Check if the object is an identifier with known shape
        const obj_tag = self.ir_view.getTag(member.object) orelse return .unknown;
        if (obj_tag != .identifier) return .unknown;

        const binding = self.ir_view.getBinding(member.object) orelse return .unknown;
        const key = bindingKey(binding);

        // Pattern B: Result object property access (result.ok -> boolean)
        if (self.result_bindings.contains(key)) {
            return self.resultPropertyType(member.property);
        }

        return .unknown;
    }

    // -----------------------------------------------------------------------
    // Boolean requirement check
    // -----------------------------------------------------------------------

    fn requireBoolean(self: *BoolChecker, node: NodeIndex, context_name: []const u8) void {
        const is_boolean = if (self.authoritative_type_checker) |checker| blk: {
            const inferred = checker.inferType(node);
            if (inferred == type_pool_mod.null_type_idx) break :blk false;
            break :blk checker.env.isAssignableTo(inferred, checker.env.pool.idx_boolean);
        } else self.inferType(node) == .boolean;
        if (is_boolean) return;

        // Select diagnostic kind based on operator context
        const kind: DiagnosticKind = if (std.mem.eql(u8, context_name, "&&") or std.mem.eql(u8, context_name, "||"))
            .logical_operand_not_boolean
        else if (std.mem.eql(u8, context_name, "!"))
            .not_operand_not_boolean
        else
            .condition_not_boolean;

        self.addDiagnostic(.{
            .severity = .err,
            .kind = kind,
            .node = node,
            .message = "boolean context requires a value of type boolean",
            .help = "compare the value explicitly so the expression has type boolean",
        });
    }

    // -----------------------------------------------------------------------
    // Node type annotation for codegen specialization
    // -----------------------------------------------------------------------

    fn annotateNodeType(self: *BoolChecker, node: NodeIndex, op: ir.BinaryOp, left_type: ExprType, right_type: ExprType) void {
        if (left_type == .number and right_type == .number) {
            switch (op) {
                .add, .sub, .mul, .div, .mod, .pow, .lt, .lte, .gt, .gte => {
                    self.node_types.put(self.allocator, node, .number) catch self.markAllocationFailure();
                },
                else => {},
            }
        } else if (op == .add and left_type == .string and right_type == .string) {
            self.node_types.put(self.allocator, node, .string) catch self.markAllocationFailure();
        }
    }

    // -----------------------------------------------------------------------
    // Numeric requirement check (type-directed arithmetic safety)
    // -----------------------------------------------------------------------

    fn requireNumeric(self: *BoolChecker, node: NodeIndex, op_name: []const u8) void {
        const inferred = self.inferType(node);
        switch (inferred) {
            .number, .unknown => return, // number is valid, unknown defers to runtime
            .boolean => {
                self.emitArithDiagnostic(node, "boolean", op_name, "use explicit conversion: (b ? 1 : 0)");
            },
            .string => {
                self.emitArithDiagnostic(node, "string", op_name, "use parseInt() or parseFloat() to convert");
            },
            .undefined => {
                self.emitArithDiagnostic(node, "undefined", op_name, "result is always NaN");
            },
            .object => {
                self.emitArithDiagnostic(node, "object", op_name, "objects cannot be used in arithmetic");
            },
            .function => {
                self.emitArithDiagnostic(node, "function", op_name, "functions cannot be used in arithmetic");
            },
            .optional_string => {
                self.emitArithDiagnostic(node, "optional string", op_name, "unwrap with ?? first, then use parseInt()");
            },
            .optional_object => {
                self.emitArithDiagnostic(node, "optional object", op_name, "objects cannot be used in arithmetic");
            },
        }
    }

    fn emitArithDiagnostic(self: *BoolChecker, node: NodeIndex, type_name: []const u8, op_name: []const u8, help: []const u8) void {
        // Build message: "'string' operand in '-' operator; arithmetic requires numbers"
        var msg_buf: [96]u8 = undefined;
        const prefix = "'";
        const mid = "' operand in '";
        const suffix = "' operator; arithmetic requires numbers";
        const msg_len = prefix.len + type_name.len + mid.len + op_name.len + suffix.len;
        if (msg_len <= msg_buf.len) {
            var pos: usize = 0;
            @memcpy(msg_buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(msg_buf[pos..][0..type_name.len], type_name);
            pos += type_name.len;
            @memcpy(msg_buf[pos..][0..mid.len], mid);
            pos += mid.len;
            @memcpy(msg_buf[pos..][0..op_name.len], op_name);
            pos += op_name.len;
            @memcpy(msg_buf[pos..][0..suffix.len], suffix);
            pos += suffix.len;
            if (self.allocator.dupe(u8, msg_buf[0..pos])) |message| {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .arithmetic_on_non_numeric,
                    .node = node,
                    .message = message,
                    .help = help,
                    .allocated = true,
                });
            } else |_| {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .arithmetic_on_non_numeric,
                    .node = node,
                    .message = "non-numeric operand in arithmetic operator",
                    .help = help,
                });
            }
        } else {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .arithmetic_on_non_numeric,
                .node = node,
                .message = "non-numeric operand in arithmetic operator",
                .help = help,
            });
        }
    }

    // -----------------------------------------------------------------------
    // Addable requirement check (type-directed + safety)
    // -----------------------------------------------------------------------

    fn requireAddable(self: *BoolChecker, node: NodeIndex, inferred: ExprType) void {
        switch (inferred) {
            .number, .string, .unknown => return, // valid operands for +
            .boolean => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'boolean' operand in '+' operator",
                    .help = "use explicit conversion: (b ? 1 : 0) for numeric addition, or `${b}` for string",
                });
            },
            .undefined => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'undefined' operand in '+' operator; result is always NaN",
                    .help = "check for undefined before using in addition",
                });
            },
            .object => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'object' operand in '+' operator",
                    .help = "objects cannot be used in addition",
                });
            },
            .function => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'function' operand in '+' operator",
                    .help = "functions cannot be used in addition",
                });
            },
            .optional_string => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'optional string' operand in '+' operator",
                    .help = "unwrap with ?? first: (val ?? \"default\")",
                });
            },
            .optional_object => {
                self.addDiagnostic(.{
                    .severity = .err,
                    .kind = .add_on_non_addable,
                    .node = node,
                    .message = "'optional object' operand in '+' operator",
                    .help = "objects cannot be used in addition",
                });
            },
        }
    }

    // -----------------------------------------------------------------------
    // Tautological comparison detection
    // -----------------------------------------------------------------------

    fn checkTautologicalComparison(self: *BoolChecker, node: NodeIndex, bin: Node.BinaryExpr) void {
        // Pattern 1: typeof x === "T" where x is provably T
        if (self.isTypeofTautology(bin)) |is_always_true| {
            const result_is_true = (bin.op == .strict_eq) == is_always_true;
            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .tautological_comparison,
                .node = node,
                .message = if (result_is_true)
                    "tautological typeof comparison: result is always true"
                else
                    "tautological typeof comparison: result is always false",
                .help = if (result_is_true)
                    "typeof check is unnecessary; type is already known"
                else
                    "this branch is dead code",
            });
            return;
        }

        // Pattern 2: x === undefined where x is provably non-optional
        if (self.isUndefinedTautology(bin)) |_| {
            const result_is_true = bin.op == .strict_neq;
            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .tautological_comparison,
                .node = node,
                .message = if (result_is_true)
                    "comparison with undefined is always true; value is never undefined"
                else
                    "comparison with undefined is always false; value is never undefined",
                .help = if (result_is_true)
                    "remove the undefined check; it is unreachable"
                else
                    "this branch is dead code",
            });
        }
    }

    /// Check if a typeof comparison is tautological.
    /// Returns true if the typeof matches the known type, false if it contradicts, null if unknown.
    fn isTypeofTautology(self: *BoolChecker, bin: Node.BinaryExpr) ?bool {
        // Look for: typeof x === "T" or "T" === typeof x
        const typeof_node, const lit_node = self.extractTypeofAndLiteral(bin) orelse return null;

        // Get the typeof operand
        const unary = self.ir_view.getUnary(typeof_node) orelse return null;
        if (unary.op != .typeof_op) return null;

        // Infer the type of the operand
        const operand_type = self.inferType(unary.operand);
        if (operand_type == .unknown) return null;

        // Get the string literal value
        const str_idx = self.ir_view.getStringIdx(lit_node) orelse return null;
        const lit_str = self.ir_view.getString(str_idx) orelse return null;

        // Map ExprType to typeof result string
        const expected_typeof: ?[]const u8 = switch (operand_type) {
            .boolean => "boolean",
            .number => "number",
            .string, .optional_string => "string",
            .undefined => "undefined",
            .object, .optional_object => "object",
            .function => "function",
            .unknown => null,
        };

        if (expected_typeof) |expected| {
            return std.mem.eql(u8, lit_str, expected);
        }
        return null;
    }

    /// Check if a comparison with undefined is tautological on a non-optional value.
    /// Returns true if one side is `undefined`, null if no tautology detected.
    fn isUndefinedTautology(self: *BoolChecker, bin: Node.BinaryExpr) ?bool {
        // Look for: x === undefined or undefined === x
        const left_tag = self.ir_view.getTag(bin.left) orelse return null;
        const right_tag = self.ir_view.getTag(bin.right) orelse return null;

        var value_node: NodeIndex = undefined;
        if (left_tag == .lit_undefined) {
            value_node = bin.right;
        } else if (right_tag == .lit_undefined) {
            value_node = bin.left;
        } else {
            return null;
        }

        // Get the type of the non-undefined side
        const value_type = self.inferType(value_node);
        if (value_type.isNonNullable()) {
            return true;
        }
        return null;
    }

    /// Extract typeof node and string literal from a comparison.
    /// Handles both `typeof x === "T"` and `"T" === typeof x`.
    fn extractTypeofAndLiteral(self: *BoolChecker, bin: Node.BinaryExpr) ?struct { NodeIndex, NodeIndex } {
        const left_tag = self.ir_view.getTag(bin.left) orelse return null;
        const right_tag = self.ir_view.getTag(bin.right) orelse return null;

        if (left_tag == .unary_op and right_tag == .lit_string) {
            return .{ bin.left, bin.right };
        }
        if (left_tag == .lit_string and right_tag == .unary_op) {
            return .{ bin.right, bin.left };
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Typeof guard extraction
    // -----------------------------------------------------------------------

    /// Map a typeof result string to an ExprType.
    fn typeStringToExprType(s: []const u8) ?ExprType {
        if (std.mem.eql(u8, s, "boolean")) return .boolean;
        if (std.mem.eql(u8, s, "number")) return .number;
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "object")) return .object;
        if (std.mem.eql(u8, s, "function")) return .function;
        if (std.mem.eql(u8, s, "undefined")) return .undefined;
        return null;
    }

    /// Extract a single typeof guard from a `typeof x === "T"` or `"T" === typeof x` pattern.
    /// Also extracts null/undefined equality guards: `x === null`, `x !== null`,
    /// `x === undefined`, `x !== undefined` (and reversed operand forms).
    /// Returns null if the node does not match any guard pattern.
    fn extractTypeofGuard(self: *BoolChecker, node: NodeIndex) ?TypeofGuard {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .binary_op) return null;

        const bin = self.ir_view.getBinary(node) orelse return null;
        if (bin.op != .strict_eq and bin.op != .strict_neq) return null;

        const left_tag = self.ir_view.getTag(bin.left) orelse return null;
        const right_tag = self.ir_view.getTag(bin.right) orelse return null;

        // Pattern 1: typeof x === "T" or "T" === typeof x
        if ((left_tag == .unary_op and right_tag == .lit_string) or
            (left_tag == .lit_string and right_tag == .unary_op))
        {
            const typeof_node = if (left_tag == .unary_op) bin.left else bin.right;
            const string_node = if (left_tag == .lit_string) bin.left else bin.right;

            // Verify the unary op is typeof
            const un = self.ir_view.getUnary(typeof_node) orelse return null;
            if (un.op != .typeof_op) return null;

            // Operand must be an identifier
            const operand_tag = self.ir_view.getTag(un.operand) orelse return null;
            if (operand_tag != .identifier) return null;

            const binding = self.ir_view.getBinding(un.operand) orelse return null;
            const key = packBindingKey(binding.scope_id, binding.slot);

            // Get the type string
            const str_idx = self.ir_view.getStringIdx(string_node) orelse return null;
            const type_str = self.ir_view.getString(str_idx) orelse return null;
            const narrowed = typeStringToExprType(type_str) orelse return null;

            return .{
                .binding_key = key,
                .narrowed_type = narrowed,
                .op = bin.op,
            };
        }

        // Pattern 2: x === undefined / undefined === x
        // For x !== undefined: narrow optional_T -> T (remove optionality)
        // For x === undefined: narrow to undefined in then-branch
        // `null` is deliberately not one of these. This lattice cannot spell
        // `T | null`, so treating `x !== null` as an absence test would strip
        // optionality the comparison never established. A `null` comparison
        // narrows through the type checker, over the real type pool.
        const ident_node = blk: {
            if (left_tag == .identifier and right_tag == .lit_undefined) {
                break :blk bin.left;
            } else if (left_tag == .lit_undefined and right_tag == .identifier) {
                break :blk bin.right;
            } else {
                return null;
            }
        };

        const binding = self.ir_view.getBinding(ident_node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);

        // For undefined guards, the narrowed_type is what the variable becomes
        // in the "positive" (===) branch. The guard system uses `op` to decide:
        //   op == strict_eq -> install narrowing in then-branch
        //   op == strict_neq -> install narrowing in else-branch
        //
        // x === undefined: then-branch -> undefined, else-branch -> removeNullish
        // x !== undefined: then-branch -> removeNullish, else-branch -> undefined
        //
        // We always store the "then-branch" narrowing and encode the op.
        if (bin.op == .strict_eq) {
            // x === undefined: then-branch narrowing is undefined
            return .{
                .binding_key = key,
                .narrowed_type = .undefined,
                .op = bin.op,
            };
        } else {
            // x !== undefined: then-branch narrowing is removeNullish (non-undefined)
            const current_type = self.lookupBindingType(key);
            const narrowed = current_type.removeNullish();
            // For x !== undefined with unknown type, narrow to unknown (still useful for flow)
            // For x !== undefined with non-nullable type, no narrowing needed
            if (narrowed == current_type and current_type.isNonNullable()) return null;
            return .{
                .binding_key = key,
                .narrowed_type = narrowed,
                // Encode as strict_eq so narrowing applies to then-branch
                // (x !== undefined -> then-branch has non-undefined x)
                .op = .strict_eq,
            };
        }
    }

    /// Look up the current type of a binding by key.
    fn lookupBindingType(self: *const BoolChecker, key: u32) ExprType {
        if (self.narrowed_types.get(key)) |t| return t;
        if (self.const_types.get(key)) |t| return t;
        return .unknown;
    }

    /// Extract typeof guards from a condition, handling &&-chained guards.
    /// Sets is_negated to true if a single !== guard is found.
    /// For && chains, only collects === guards (not !==) to stay sound.
    /// Returns the number of guards collected.
    fn extractTypeofGuards(
        self: *BoolChecker,
        node: NodeIndex,
        guards: *[MAX_NARROWINGS]TypeofGuard,
        is_negated: *bool,
    ) usize {
        is_negated.* = false;

        // Try single typeof/equality guard first
        if (self.extractTypeofGuard(node)) |guard| {
            guards[0] = guard;
            is_negated.* = (guard.op == .strict_neq);
            return 1;
        }

        // Try && chain of typeof guards
        const tag = self.ir_view.getTag(node) orelse return 0;
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(node) orelse return 0;
            if (bin.op == .and_op) {
                var count: usize = 0;
                self.collectAndGuards(bin.left, guards, &count);
                self.collectAndGuards(bin.right, guards, &count);
                if (count > 0) return count;
            }
        }

        return 0;
    }

    /// Recursively collect === typeof guards from an && chain.
    fn collectAndGuards(
        self: *BoolChecker,
        node: NodeIndex,
        guards: *[MAX_NARROWINGS]TypeofGuard,
        count: *usize,
    ) void {
        if (count.* >= MAX_NARROWINGS) return;

        // Check if this node is itself a typeof === guard
        if (self.extractTypeofGuard(node)) |guard| {
            if (guard.op == .strict_eq) {
                guards[count.*] = guard;
                count.* += 1;
            }
            return;
        }

        // Check if this is another && to recurse into
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag != .binary_op) return;
        const bin = self.ir_view.getBinary(node) orelse return;
        if (bin.op != .and_op) return;

        self.collectAndGuards(bin.left, guards, count);
        if (count.* >= MAX_NARROWINGS) return;
        self.collectAndGuards(bin.right, guards, count);
    }

    // -----------------------------------------------------------------------
    // Narrowing scope helpers
    // -----------------------------------------------------------------------

    /// Save current narrowed_types values for the guard keys, then install the narrowings.
    fn installGuards(self: *BoolChecker, guards: []const TypeofGuard, saved: []?ExprType) void {
        for (guards, 0..) |g, i| {
            saved[i] = self.narrowed_types.get(g.binding_key);
            self.narrowed_types.put(self.allocator, g.binding_key, g.narrowed_type) catch self.markAllocationFailure();
        }
    }

    /// Restore narrowed_types to saved values, removing entries that had no prior value.
    fn restoreGuards(self: *BoolChecker, guards: []const TypeofGuard, saved: []const ?ExprType) void {
        for (guards, 0..) |g, i| {
            if (saved[i]) |prev| {
                self.narrowed_types.put(self.allocator, g.binding_key, prev) catch self.markAllocationFailure();
            } else {
                _ = self.narrowed_types.remove(g.binding_key);
            }
        }
    }

    fn walkStmtWithGuards(
        self: *BoolChecker,
        node: NodeIndex,
        guards: []const TypeofGuard,
        saved: []?ExprType,
    ) void {
        self.installGuards(guards, saved);
        self.walkStmt(node);
        self.restoreGuards(guards, saved);
    }

    fn walkExprWithGuards(
        self: *BoolChecker,
        node: NodeIndex,
        guards: []const TypeofGuard,
        saved: []?ExprType,
    ) void {
        self.installGuards(guards, saved);
        self.walkExpr(node);
        self.restoreGuards(guards, saved);
    }

    // -----------------------------------------------------------------------
    // Import scanning for virtual module return types
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Virtual module return type table
    // -----------------------------------------------------------------------

    const builtin_modules = @import("zts-engine").builtin_modules;
    const mb = @import("zts-engine").module_binding;

    /// Return type entry derived from the module binding registry.
    const ModuleReturnEntry = struct {
        module: []const u8,
        name: []const u8,
        ret: ExprType,
        is_result: bool = false,
    };

    /// Look up a function's return type from the module binding registry.
    fn findModuleReturnEntry(module_str: []const u8, func_name: []const u8) ?ModuleReturnEntry {
        const entry = builtin_modules.findExport(module_str, func_name) orelse return null;
        return .{
            .module = entry.binding.specifier,
            .name = entry.func.name,
            .ret = returnKindToExprType(entry.func.returns),
            .is_result = entry.func.returns == .result,
        };
    }

    fn returnKindToExprType(kind: mb.ReturnKind) ExprType {
        return switch (kind) {
            .boolean => .boolean,
            .number => .number,
            .string => .string,
            .object => .object,
            .undefined => .undefined,
            .unknown => .unknown,
            .optional_string => .optional_string,
            .optional_object => .optional_object,
            // The lattice has no optional number; `.number` would claim the
            // value is always present, so `.unknown` is the true statement.
            .optional_number => .unknown,
            .result => .object, // Result objects are typed as object in ExprType
            // This lattice has no Dict member and the checker's own type pool
            // is where a Dict is really typed; `.object` is the closest true
            // statement here - a Dict is an object value, never absent.
            .dict => .object,
            // Same reading for the same reason: a Bytes is an object value at
            // run time and is never absent.
            .bytes => .object,
        };
    }

    /// Resolve the index to read: injected, or private on first use.
    fn resolveFacts(self: *BoolChecker) ?*const module_facts_mod.ModuleFacts {
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

    /// Map local binding slots to known return types.
    ///
    /// Reads only `.builtin` records. That is the exact translation of the
    /// legacy filter `builtin_modules.fromSpecifier(module) == null` skip:
    /// `fromSpecifier` searches `builtin_modules.all`, which is
    /// `builtins ++ extension_bindings.all`, and does NOT consult a manifest
    /// registry. So a partner-registered module was skipped before and must
    /// stay skipped, which is why `.partner` is excluded here alongside
    /// `.unresolved`.
    fn scanImports(self: *BoolChecker) void {
        const facts = self.resolveFacts() orelse return;
        for (facts.imports.items) |rec| {
            if (rec.resolution != .builtin) continue;
            const entry = findModuleReturnEntry(rec.module_specifier, rec.imported_name) orelse continue;
            self.module_fn_types.put(self.allocator, rec.slot, entry.ret) catch self.markAllocationFailure();
            if (entry.is_result) {
                self.module_result_fn_slots.put(self.allocator, rec.slot, {}) catch self.markAllocationFailure();
            }
        }
    }

    fn resolveAtomName(self: *const BoolChecker, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            // With atom table: predefined atoms first, then dynamic table
            const atom: object.Atom = @enumFromInt(atom_idx);
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        // Without atom table (standalone parser): predefined atoms and string
        // constants share the u16 index space. String constants take priority
        // because import specifiers (the main use case) go through addString.
        // Predefined atom names are keywords/builtins, never import specifier names.
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @enumFromInt(atom_idx);
        return atom.toPredefinedName();
    }

    fn addDiagnostic(self: *BoolChecker, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch {
            if (diag.allocated) self.allocator.free(diag.message);
            self.markAllocationFailure();
        };
    }

    fn markAllocationFailure(self: *BoolChecker) void {
        self.allocation_failed = true;
    }
};

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

pub fn getSourceLine(source: []const u8, target_line: u32) ?[]const u8 {
    var current_line: u32 = 1;
    var line_start: usize = 0;

    for (source, 0..) |c, i| {
        if (current_line == target_line) {
            var line_end = i;
            while (line_end < source.len and source[line_end] != '\n') {
                line_end += 1;
            }
            return source[line_start..line_end];
        }
        if (c == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }

    if (current_line == target_line and line_start < source.len) {
        return source[line_start..];
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BoolChecker fails closed when analysis state cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "if ({}) { const enabled = true; }");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = BoolChecker.init(failing.allocator(), view, null);
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

fn checkSource(source: []const u8, expect_errors: u32) !void {
    return checkSourceFull(source, expect_errors, null);
}

fn checkSourceFull(source: []const u8, expect_errors: u32, expect_warnings: ?u32) !void {
    const allocator = std.testing.allocator;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();

    const root = parser.parse() catch |err| return err;

    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = BoolChecker.init(allocator, ir_view, null);
    defer checker.deinit();

    const errors = try checker.check(root);
    try std.testing.expectEqual(expect_errors, errors);

    if (expect_warnings) |w| {
        var warning_count: u32 = 0;
        for (checker.getDiagnostics()) |diag| {
            if (diag.severity == .warning) warning_count += 1;
        }
        try std.testing.expectEqual(w, warning_count);
    }
}

// S1: if/ternary conditions

test "sound: boolean literal in if passes" {
    try checkSource("if (true) { let x = 1; }", 0);
}

test "sound: comparison in if passes" {
    try checkSource("let x = 5; if (x === 0) { let y = 1; }", 0);
}

test "sound: boolean && boolean in if passes" {
    try checkSource("let a = 1; let b = 2; if (a === 1 && b !== 3) { let c = 1; }", 0);
}

test "sound: tracked const boolean in if passes" {
    try checkSource("const done = 1 > 0; if (done) { let x = 1; }", 0);
}

test "sound: unknown function result in if fails closed" {
    try checkSource("const ok = validate(); if (ok) { let x = 1; }", 1);
}

test "sound: unknown parameter in ternary fails closed" {
    try checkSource("const f = (x) => x ? 1 : 2;", 1);
}

test "sound: number literal in if fails" {
    try checkSource("if (0) { let x = 1; }", 1);
}

test "sound: string literal in if fails" {
    try checkSource("if (\"hello\") { let x = 1; }", 1);
}

test "sound: undefined literal in if fails" {
    try checkSourceFull("if (undefined) { let x = 1; }", 1, 0);
}

test "sound: tracked const number in if fails" {
    try checkSource("const count = 42; if (count) { let x = 1; }", 1);
}

// S2: && and || operands

test "sound: number operands for && fail" {
    try checkSource("const r = 1 && 2;", 2);
}

test "sound: string operands for || fail" {
    try checkSource("const r = \"a\" || \"b\";", 2);
}

// S3: ! operand

test "sound: !0 fails" {
    try checkSource("const r = !0;", 1);
}

test "sound: !string fails" {
    try checkSource("const r = !\"str\";", 1);
}

test "sound: !boolean passes" {
    try checkSource("const r = !(1 > 0);", 0);
}

test "sound: assert requires a boolean condition" {
    try checkSource("assert 1;", 1);
    try checkSource("assert true;", 0);
}

// S4: ?? warnings

test "sound: non-nullable LHS for ?? warns" {
    try checkSourceFull("const r = 42 ?? 0;", 0, 1);
}

test "sound: string LHS for ?? warns" {
    try checkSourceFull("const r = \"str\" ?? \"default\";", 0, 1);
}

test "sound: unknown LHS for ?? no warning" {
    try checkSourceFull("const f = (x) => x ?? 0;", 0, 0);
}

// Combined

test "sound: nested number condition fails" {
    try checkSource(
        \\const flag = true;
        \\if (flag) {
        \\  const count = 5;
        \\  if (count) { let x = 1; }
        \\}
    , 1);
}

test "sound: complex boolean expression passes" {
    try checkSource(
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\if (a > 0 && b !== c || a === b) { let x = 1; }
    , 0);
}

// Let variable tracking

test "sound: tracked let number in if fails" {
    try checkSource("let count = 0; if (count) { let x = 1; }", 1);
}

test "sound: let reassigned to boolean passes" {
    try checkSource(
        \\let flag = 0;
        \\flag = 1 > 0;
        \\if (flag) { let x = 1; }
    , 0);
}

test "sound: let reassigned to number fails in if" {
    try checkSource(
        \\let flag = true;
        \\flag = 42;
        \\if (flag) { let x = 1; }
    , 1);
}

// Diagnostic context messages

// Function return type inference

test "sound: arrow function returning boolean - call site passes" {
    try checkSource(
        \\const isPositive = (n) => n > 0;
        \\if (isPositive(5)) { let x = 1; }
    , 0);
}

test "sound: arrow function returning number fails in if" {
    try checkSource(
        \\const double = (n) => n * 2;
        \\if (double(5)) { let x = 1; }
    , 1);
}

test "sound: block function returning boolean passes" {
    try checkSource(
        \\const check = (x) => {
        \\  return x > 0;
        \\};
        \\if (check(1)) { let y = 1; }
    , 0);
}

test "sound: block function with mixed return types fails closed" {
    try checkSource(
        \\const mixed = (x) => {
        \\  if (x > 0) { return true; }
        \\  return 0;
        \\};
        \\if (mixed(1)) { let y = 1; }
    , 1);
}

test "sound: untracked function call fails closed" {
    try checkSource("if (someFunc()) { let x = 1; }", 1);
}

// Diagnostic context messages

test "sound: diagnostic gives explicit boolean repair" {
    const allocator = std.testing.allocator;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "if ({}) { let x = 1; }");
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var checker = BoolChecker.init(allocator, ir_view, null);
    defer checker.deinit();

    _ = try checker.check(root);
    const diags = checker.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqual(DiagnosticKind.condition_not_boolean, diags[0].kind);
    try std.testing.expectEqualStrings("boolean context requires a value of type boolean", diags[0].message);
    try std.testing.expectEqualStrings("compare the value explicitly so the expression has type boolean", diags[0].help.?);
}

// Typeof guard narrowing

test "sound: typeof number guard still requires explicit comparison" {
    try checkSource(
        \\const f = (x) => {
        \\  if (typeof x === "number") {
        \\    if (x) { let y = 1; }
        \\  }
        \\  return true;
        \\};
    , 1);
}

test "sound: typeof guard narrows to boolean, used in boolean context" {
    try checkSource(
        \\const f = (x) => {
        \\  if (typeof x === "boolean") {
        \\    if (x) { let y = 1; }
        \\  }
        \\  return true;
        \\};
    , 0);
}

test "sound: reversed typeof number guard still requires explicit comparison" {
    try checkSource(
        \\const f = (x) => {
        \\  if ("number" === typeof x) {
        \\    if (x) { let y = 1; }
        \\  }
        \\  return true;
        \\};
    , 1);
}

test "sound: negated typeof number guard still requires explicit comparison" {
    try checkSource(
        \\const f = (x) => {
        \\  if (typeof x !== "number") {
        \\    let y = 1;
        \\  } else {
        \\    if (x) { let z = 1; }
        \\  }
        \\  return true;
        \\};
    , 1);
}

test "sound: typeof number guard rejects bare ternary condition" {
    try checkSource(
        \\const f = (x) => {
        \\  typeof x === "number" ? (x ? 1 : 0) : 0;
        \\  return true;
        \\};
    , 1);
}

test "sound: negated typeof number guard rejects bare ternary condition" {
    try checkSource(
        \\const f = (x) => {
        \\  typeof x !== "number" ? 0 : (x ? 1 : 0);
        \\  return true;
        \\};
    , 1);
}

test "sound: unknown outside typeof branch fails closed" {
    try checkSource(
        \\const f = (x) => {
        \\  if (typeof x === "number") {
        \\    let y = x;
        \\  }
        \\  if (x) { let z = 1; }
        \\  return true;
        \\};
    , 1);
}

test "sound: compound typeof guard does not permit number truthiness" {
    try checkSource(
        \\const f = (x, y) => {
        \\  if (typeof x === "number" && typeof y === "string") {
        \\    if (x) { let z = 1; }
        \\  }
        \\  return true;
        \\};
    , 1);
}

test "sound: typeof nested guards compose" {
    try checkSource(
        \\const f = (x, y) => {
        \\  if (typeof x === "boolean") {
        \\    if (typeof y === "boolean") {
        \\      const r = x && y;
        \\    }
        \\  }
        \\  return true;
        \\};
    , 0);
}

test "sound: non-typeof condition does not narrow" {
    // x === true is not a typeof guard, so x remains unknown and fails closed.
    try checkSource(
        \\const f = (x) => {
        \\  if (x === true) {
        \\    if (x) { let y = 1; }
        \\  }
        \\  return true;
        \\};
    , 1);
}

// Virtual module return type inference (Phase 1)

test "sound: virtual module boolean return type catches non-boolean use" {
    // verifyWebhookSignature returns boolean - using it in if is fine
    try checkSource(
        \\import { verifyWebhookSignature } from "zttp:auth";
        \\const ok = verifyWebhookSignature("payload", "secret", "sig");
        \\if (ok) { let x = 1; }
    , 0);
}

test "sound: virtual module number return type fails in boolean context" {
    try checkSource(
        \\import { cacheIncr } from "zttp:cache";
        \\const count = cacheIncr("ns", "key");
        \\if (count) { let x = 1; }
    , 1);
}

test "sound: virtual module string return type fails in boolean context" {
    try checkSource(
        \\import { sha256 } from "zttp:crypto";
        \\const hash = sha256("data");
        \\if (hash) { let x = 1; }
    , 1);
}

test "sound: virtual module object return type fails in boolean context" {
    // jwtVerify returns object (Result) - objects are always truthy, still an error
    try checkSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret");
        \\if (result) { let x = 1; }
    , 1);
}

test "sound: virtual module optional return type fails in boolean context" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const val = env("KEY");
        \\if (val) { let x = 1; }
    , 1);
}

test "sound: virtual module direct call in boolean context" {
    // timingSafeEqual returns boolean - direct call in if is fine
    try checkSource(
        \\import { timingSafeEqual } from "zttp:auth";
        \\if (timingSafeEqual("a", "b")) { let x = 1; }
    , 0);
}

test "sound: virtual module direct number call fails in boolean context" {
    try checkSource(
        \\import { cacheIncr } from "zttp:cache";
        \\if (cacheIncr("ns", "key")) { let x = 1; }
    , 1);
}

// Phase 2: Match expression type inference tests must run via `zig build test-zts`
// (standalone `zig test` on bool_checker.zig hangs when parsing match expressions).

// Phase 3: Optional union types

test "sound: string resolved by ?? still fails in boolean context" {
    try checkSourceFull(
        \\import { env } from "zttp:env";
        \\const val = env("KEY") ?? "default";
        \\if (val) { let x = 1; }
    , 1, 0);
}

test "sound: optional with ?? does not warn" {
    // env() ?? "default" - the ?? is legitimate because env() is optional
    try checkSourceFull(
        \\import { env } from "zttp:env";
        \\const val = env("KEY") ?? "default";
    , 0, 0); // no errors, no warnings
}

test "sound: non-optional with ?? still warns" {
    // sha256() ?? "" - sha256 returns string (never undefined), so ?? is unreachable
    try checkSourceFull(
        \\import { sha256 } from "zttp:crypto";
        \\const val = sha256("data") ?? "";
    , 0, 1); // no errors, 1 warning
}

test "sound: optional cacheGet fails in boolean context" {
    try checkSource(
        \\import { cacheGet } from "zttp:cache";
        \\const val = cacheGet("ns", "key");
        \\if (val) { let x = 1; }
    , 1);
}

test "sound: function returning string or undefined fails in boolean context" {
    try checkSource(
        \\const find = (arr) => {
        \\  if (arr.length > 0) { return "found"; }
        \\  return undefined;
        \\};
        \\const r = find([1]);
        \\if (r) { let x = 1; }
    , 1);
}

// Phase 4: Property access on known shapes

test "sound: result.ok is boolean - passes in boolean context" {
    try checkSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret", "opts");
        \\if (result.ok) { let x = 1; }
    , 0);
}

test "sound: aliased result-producing import preserves result shape" {
    try checkSource(
        \\import { jwtVerify as verify } from "zttp:auth";
        \\const result = verify("token", "secret", "opts");
        \\if (result.ok) { let x = 1; }
    , 0);
}

test "sound: result.error string fails in boolean context" {
    try checkSource(
        \\import { validateJson } from "zttp:validate";
        \\const result = validateJson("schema", "data");
        \\if (result.error) { let x = 1; }
    , 1);
}

test "sound: non-result object property fails closed" {
    try checkSource(
        \\const obj = { x: 1 };
        \\if (obj.x) { let y = 1; }
    , 1);
}

// Undefined equality narrowing

test "sound: x !== undefined narrows optional but string remains non-boolean" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const val = env("KEY");
        \\if (val !== undefined) {
        \\  if (val) { let x = 1; }
        \\}
    , 1);
}

test "sound: x !== undefined on string does not make it boolean" {
    try checkSource(
        \\import { sha256 } from "zttp:crypto";
        \\const hash = sha256("data");
        \\if (hash !== undefined) {
        \\  if (hash) { let x = 1; }
        \\}
    , 1);
}

test "sound: reversed undefined narrowing leaves string non-boolean" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const val = env("KEY");
        \\if (undefined !== val) {
        \\  if (val) { let x = 1; }
        \\}
    , 1);
}

test "sound: x === undefined narrows to undefined type in then-branch" {
    try checkSourceFull(
        \\import { env } from "zttp:env";
        \\const val = env("KEY");
        \\if (val === undefined) {
        \\  if (val) { let x = 1; }
        \\}
    , 1, 0);
}

test "sound: narrowing does not leak outside undefined guard branch" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const val = env("KEY");
        \\if (val !== undefined) {
        \\  let y = val;
        \\}
        \\if (val) { let z = 1; }
    , 1);
}

// Boolean-only refusal tests

test "sound: if (42) fails" {
    try checkSource("if (42) { let x = 1; }", 1);
}

test "sound: if (0) fails" {
    try checkSource("if (0) { let x = 1; }", 1);
}

test "sound: if string fails" {
    try checkSource("if (\"hello\") { let x = 1; }", 1);
}

test "sound: if empty string fails" {
    try checkSource("if (\"\") { let x = 1; }", 1);
}

test "sound: if undefined fails" {
    try checkSourceFull("if (undefined) { let x = 1; }", 1, 0);
}

test "sound: if ({}) fails - object always truthy" {
    try checkSource("if ({}) { let x = 1; }", 1);
}

test "sound: if (fn) fails - function always truthy" {
    try checkSource("if (() => 1) { let x = 1; }", 1);
}

test "sound: if (named_object_literal) - static check rejects pointless condition" {
    // Regression: confirm the bool_checker correctly infers the type of a
    // named-local bound to an object literal and rejects the pointless
    // condition, matching the anonymous-literal case above.
    try checkSource(
        \\const found = { kind: "fake" };
        \\if (found) { let x = 1; }
    , 1);
}

test "sound: bare optional does not narrow and fails" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const x = env("K");
        \\if (x) {
        \\  const upper = x;
        \\}
    , 1);
}

test "sound: negated optional does not narrow and fails" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const x = env("K");
        \\if (!x) {
        \\  let y = 1;
        \\}
    , 1);
}

test "sound: && with number and string rejects both operands" {
    try checkSource("if (1 && \"ok\") { let x = 1; }", 2);
}

test "sound: optional from function fails in boolean context" {
    try checkSource(
        \\const find = (arr) => {
        \\  if (arr.length > 0) { return "found"; }
        \\  return undefined;
        \\};
        \\const r = find([1]);
        \\if (r) { let x = r; }
    , 1);
}

// =========================================================================
// Type-directed arithmetic safety (S5)
// =========================================================================

test "sound: number - number passes" {
    try checkSource("const r = 5 - 3;", 0);
}

test "sound: number * number passes" {
    try checkSource("const r = 5 * 3;", 0);
}

test "sound: number / number passes" {
    try checkSource("const r = 10 / 2;", 0);
}

test "sound: number % number passes" {
    try checkSource("const r = 10 % 3;", 0);
}

test "sound: number ** number passes" {
    try checkSource("const r = 2 ** 3;", 0);
}

test "sound: string in subtraction fails" {
    try checkSource("const r = \"hello\" - 1;", 1);
}

test "sound: string in multiplication fails" {
    try checkSource("const r = \"hello\" * 2;", 1);
}

test "sound: boolean in arithmetic fails" {
    try checkSource("const r = true * 5;", 1);
}

test "sound: boolean both sides arithmetic fails" {
    try checkSource("const r = true - false;", 2);
}

test "sound: undefined in arithmetic fails" {
    try checkSource("const r = undefined / 2;", 1);
}

test "sound: object in arithmetic fails" {
    try checkSource("const r = {} - 1;", 1);
}

test "sound: function in arithmetic fails" {
    try checkSource("const r = (() => 1) * 2;", 1);
}

test "sound: optional string in arithmetic fails" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const r = env("X") * 1000;
    , 1);
}

test "sound: unknown in arithmetic passes" {
    try checkSource(
        \\const f = (x) => x - 1;
    , 0);
}

test "sound: tracked number in arithmetic passes" {
    try checkSource(
        \\const count = 42;
        \\const r = count * 2;
    , 0);
}

test "sound: cacheIncr (number return) in arithmetic passes" {
    try checkSource(
        \\import { cacheIncr } from "zttp:cache";
        \\const count = cacheIncr("ns", "key");
        \\const r = count * 2;
    , 0);
}

// =========================================================================
// Type-directed + safety (S6)
// =========================================================================

test "sound: number + number passes" {
    try checkSource("const r = 1 + 2;", 0);
}

test "sound: string + string passes" {
    try checkSource("const r = \"a\" + \"b\";", 0);
}

test "sound: number + string fails (mixed type)" {
    try checkSource("const r = 42 + \"px\";", 1);
}

test "sound: string + number fails (mixed type)" {
    try checkSource("const r = \"count: \" + 5;", 1);
}

test "sound: boolean in + fails" {
    try checkSource("const r = true + 1;", 1);
}

test "sound: undefined in + fails" {
    try checkSource("const r = undefined + 1;", 1);
}

test "sound: object in + fails" {
    try checkSource("const r = {} + 1;", 1);
}

test "sound: optional string in + fails" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const r = env("X") + "suffix";
    , 1);
}

test "sound: unknown + number passes (runtime decides)" {
    try checkSource(
        \\const f = (x) => x + 1;
    , 0);
}

test "sound: unknown + unknown passes" {
    try checkSource(
        \\const f = (x, y) => x + y;
    , 0);
}

// =========================================================================
// Tautological comparison detection (S7)
// =========================================================================

test "sound: typeof on known number is tautological" {
    try checkSourceFull(
        \\const x = 42;
        \\const r = typeof x === "number";
    , 0, 1);
}

test "sound: typeof on known string is tautological" {
    try checkSourceFull(
        \\const x = "hello";
        \\const r = typeof x === "string";
    , 0, 1);
}

test "sound: typeof mismatch on known number is tautological" {
    try checkSourceFull(
        \\const x = 42;
        \\const r = typeof x === "string";
    , 0, 1);
}

test "sound: typeof !== on known type is tautological" {
    try checkSourceFull(
        \\const x = 42;
        \\const r = typeof x !== "number";
    , 0, 1);
}

test "sound: typeof on unknown is not tautological" {
    try checkSourceFull(
        \\const f = (x) => typeof x === "number";
    , 0, 0);
}

test "sound: x === undefined on non-optional is tautological" {
    try checkSourceFull(
        \\const x = 42;
        \\const r = x === undefined;
    , 0, 1);
}

test "sound: x !== undefined on non-optional is tautological" {
    try checkSourceFull(
        \\import { sha256 } from "zttp:crypto";
        \\const h = sha256("data");
        \\const r = h !== undefined;
    , 0, 1);
}

test "sound: x === undefined on optional is not tautological" {
    try checkSourceFull(
        \\import { env } from "zttp:env";
        \\const v = env("K");
        \\const r = v === undefined;
    , 0, 0);
}

test "sound: typeof reversed operand order tautological" {
    try checkSourceFull(
        \\const x = true;
        \\const r = "boolean" === typeof x;
    , 0, 1);
}

// =========================================================================
// Phase 2: Type propagation through ?? and narrowing
// =========================================================================

test "sound: env() ?? default resolves to string, catches arithmetic" {
    // env() ?? "default" -> string. string - 1 -> error.
    try checkSource(
        \\import { env } from "zttp:env";
        \\const key = env("KEY") ?? "default";
        \\const r = key - 1;
    , 1);
}

test "sound: env() ?? default resolves to string, string + string passes" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const key = env("KEY") ?? "default";
        \\const r = key + "_suffix";
    , 0);
}

test "sound: bare optional condition does not narrow derived binding" {
    try checkSource(
        \\import { env } from "zttp:env";
        \\const val = env("K");
        \\if (val) {
        \\  const s = val;
        \\  const r = s + "_ok";
        \\}
    , 2);
}

test "sound: result.ok is boolean, catches arithmetic on it" {
    try checkSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret", "opts");
        \\const r = result.ok * 2;
    , 1);
}

test "sound: result.error is string, catches arithmetic on it" {
    try checkSource(
        \\import { validateJson } from "zttp:validate";
        \\const result = validateJson("schema", "data");
        \\const r = result.error - 1;
    , 1);
}

const import_corpus = @import("tests/import_corpus.zig");

test "the import scan maps builtin slots to return types in both atom modes" {
    // Replaces the differential that proved this scan matches the pre-C1
    // implementation (commit 383ea758). Both atom-table modes, because the
    // no-table path is where the two atom resolvers disagreed.
    const allocator = std.testing.allocator;

    for ([_]bool{ true, false }) |use_atoms| {
        var parser = try @import("zts-engine").parser.JsParser.init(allocator,
            \\import { env } from "zttp:env";
            \\import { jwtVerify } from "zttp:auth";
            \\import { thing } from "zttp-ext:unknown";
        );
        defer parser.deinit();
        var atoms = context.AtomTable.init(allocator);
        defer atoms.deinit();
        if (use_atoms) parser.setAtomTable(&atoms);
        _ = try parser.parse();
        const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

        var checker = BoolChecker.init(allocator, ir_view, if (use_atoms) &atoms else null);
        defer checker.deinit();
        checker.scanImports();

        // env and jwtVerify are builtins and typed; the unresolved module is
        // skipped, which is this analyzer's filter and differs from
        // strict_checker and effect_inference.
        std.testing.expectEqual(@as(u32, 2), checker.module_fn_types.count()) catch |err| {
            std.debug.print("\natoms={}: expected 2 typed slots, found {d}\n", .{ use_atoms, checker.module_fn_types.count() });
            return err;
        };
        // jwtVerify returns a Result; env returns an optional string.
        try std.testing.expectEqual(@as(u32, 1), checker.module_result_fn_slots.count());
    }
}
