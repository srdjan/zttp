//! Type Checker: validates types across the IR tree.
//!
//! Walks the IR tree produced by the parser, consulting the TypeEnv (populated
//! from the stripper's TypeMap) to check:
//! - Variable declarations match their type annotations
//! - Function call arguments match parameter types
//! - Property access on known record types
//! - Return values match declared return types
//! - Union types require narrowing before type-specific operations
//!
//! Architecture follows bool_checker.zig: a struct with walkStmt/walkExpr/inferType
//! methods that produces diagnostics.
//!
//! When a type cannot be determined statically, null_type_idx is returned (escape hatch).
//! Only annotated values are checked - unannotated code passes through unchecked.

const std = @import("std");
const stripper = @import("zts-engine").stripper;
const ir = @import("zts-engine").parser.ir;
const json_utils = @import("zts-base").json_utils;
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const type_pool_mod = @import("type_pool.zig");
const type_key = @import("type_key.zig");
const type_env_mod = @import("type_env.zig");
const abi_types = @import("abi_types.zig");
const service_types_mod = @import("zts-contracts").service_types;
const bool_checker_mod = @import("bool_checker.zig");
const match_analysis_mod = @import("match_analysis.zig");

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const TypeEnv = type_env_mod.TypeEnv;
const ServiceTypeContext = service_types_mod.ServiceTypeContext;

/// Max union members tracked during type inference (member access, return types, etc.).
/// The width of this file's stack scratch buffers when collecting branch types
/// before a join. It is not a limit on how wide a union may be: `addUnion`
/// normalizes on the heap and a schema enum is routinely wider than this.
const MAX_UNION_MEMBERS = 16;

pub const TypeCheckerError = type_pool_mod.TypePoolError || error{UnresolvedTypeBinding};

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
    type_mismatch, // declared type != inferred type
    missing_field, // property access on record missing field
    arg_count_mismatch, // wrong number of arguments
    arg_type_mismatch, // argument type doesn't match parameter
    return_type_mismatch, // return value doesn't match declared return type
    non_exhaustive_match, // match is not provably exhaustive
    invalid_type_predicate, // `v is T` whose body does not verify the claim
    ambiguous_type_argument, // a type parameter no argument position determines
    type_constraint_violation, // a type argument outside its `extends` bound
    type_argument_count_mismatch, // explicit type arguments, wrong count
    non_contractive_alias, // a recursive alias whose cycle no data constructor guards
    unencodable_json_payload, // a `Response.json` payload whose type cannot be JSON
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    /// Whether the message was dynamically allocated.
    allocated: bool = false,
};

// ---------------------------------------------------------------------------
// Type Checker
// ---------------------------------------------------------------------------

pub const TypeChecker = struct {
    const CallableMetadata = union(enum) {
        unavailable,
        signature: type_env_mod.FunctionSig,
    };

    const CompiledSchemaType = struct {
        name: []const u8,
        type_idx: TypeIndex,
    };

    const NarrowJournalEntry = struct {
        key: u64,
        /// What the key held before the change, or null when it held nothing.
        prev: ?TypeIndex,
    };

    const ActiveDeclaredType = struct {
        name_atom: u16,
        type_idx: TypeIndex,
        callable: CallableMetadata = .unavailable,
    };

    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    env: *TypeEnv,
    service_type_context: ?*const ServiceTypeContext,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    compiled_schemas: std.ArrayListUnmanaged(CompiledSchemaType),

    /// Inferred types for const/let bindings: packed(scope_id, slot) -> TypeIndex
    binding_types: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// Callable metadata for declarations keyed by packed(scope_id, slot).
    /// An explicit `unavailable` entry is significant: it prevents a local
    /// binding from inheriting an unrelated module signature by bare name.
    binding_callables: std.AutoHashMapUnmanaged(u64, CallableMetadata),
    /// Declared parameter types keyed by (scope_id, slot). Kept SEPARATE from
    /// `binding_types` deliberately: feeding parameter types into general
    /// identifier inference would subject every `req: Request` argument to
    /// module-signature assignability checks the pool cannot discharge yet.
    /// Consulted only where a declared parameter type is load-bearing:
    /// match-discriminant exhaustiveness.
    param_types: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// Next declaration occurrence for each name atom. The stripper records
    /// the same semantic occurrence, so annotation binding is coordinate-free.
    var_name_ordinals: std.AutoHashMapUnmanaged(u16, u32),
    /// Lexically active declarations, including untyped shadows. Upvalues use
    /// this stack to resolve the nearest declaration by name.
    active_declared_types: std.ArrayListUnmanaged(ActiveDeclaredType),
    bound_var_annotations: usize = 0,
    binding_resolution_failed: bool = false,
    /// Flow-sensitive narrowing: binding key -> narrowed TypeIndex
    narrowed: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// Type predicates whose bodies were read and found to prove what they
    /// claim, by function name. A declared predicate that is not in here
    /// installs no narrowing anywhere.
    admitted_predicates: std.StringHashMapUnmanaged(void),
    /// Undo log for `narrowed`, so a branch can restore every key it touched
    /// and not only the one its own guard installed.
    narrow_journal: std.ArrayListUnmanaged(NarrowJournalEntry),
    /// How many branch scopes are open. Nothing is journalled at zero.
    narrow_scopes: u32 = 0,
    /// Track current function's declared return type for return statement checking
    current_return_type: TypeIndex = null_type_idx,
    /// Sticky failure for proof-relevant type, narrowing, schema, parameter,
    /// and diagnostic state. Message-only formatting may retain a static
    /// fallback because the core diagnostic is still stored.
    allocation_failed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        env: *TypeEnv,
        service_type_context: ?*const ServiceTypeContext,
    ) TypeChecker {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .env = env,
            .service_type_context = service_type_context,
            .diagnostics = .empty,
            .compiled_schemas = .empty,
            .binding_types = .empty,
            .binding_callables = .empty,
            .param_types = .empty,
            .var_name_ordinals = .empty,
            .active_declared_types = .empty,
            .narrowed = .empty,
            .narrow_journal = .empty,
            .admitted_predicates = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        for (self.diagnostics.items) |diag| {
            if (diag.allocated) {
                self.allocator.free(diag.message);
            }
        }
        self.diagnostics.deinit(self.allocator);
        for (self.compiled_schemas.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.compiled_schemas.deinit(self.allocator);
        self.binding_types.deinit(self.allocator);
        self.binding_callables.deinit(self.allocator);
        self.param_types.deinit(self.allocator);
        self.var_name_ordinals.deinit(self.allocator);
        self.active_declared_types.deinit(self.allocator);
        self.narrowed.deinit(self.allocator);
        self.narrow_journal.deinit(self.allocator);
        self.admitted_predicates.deinit(self.allocator);
    }

    /// Run the checker on the given root node. Returns the number of errors.
    pub fn check(self: *TypeChecker, root: NodeIndex) !u32 {
        try self.ensureHealthy();
        // Before the main walk, so a call to a function declared later in the
        // file is checked against the arity that function actually accepts.
        self.recordDefaultArity(root, 0);
        // Before the main walk, so a call to a predicate declared later in the
        // file still narrows. A predicate whose body is not an admitted test is
        // rejected here and installs nothing anywhere.
        self.admitTypePredicates(root, 0);
        self.walkStmt(root);
        if (self.bound_var_annotations != self.env.varAnnotationCount()) {
            self.binding_resolution_failed = true;
        }
        try self.ensureHealthy();
        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        return error_count;
    }

    /// Reject proof/type results after either the checker or its shared pool
    /// encounters an operational allocation or compact-capacity failure.
    pub fn ensureHealthy(self: *const TypeChecker) TypeCheckerError!void {
        try self.env.pool.ensureHealthy();
        if (self.allocation_failed) return error.OutOfMemory;
        if (self.binding_resolution_failed) return error.UnresolvedTypeBinding;
    }

    pub fn getDiagnostics(self: *const TypeChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    // -------------------------------------------------------------------
    // Diagnostic formatting
    // -------------------------------------------------------------------

    pub fn formatDiagnostics(self: *const TypeChecker, source: stripper.SourceView, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            try writer.print("type {s}: {s}\n", .{ diag.severity.label(), diag.message });
            try source.writeLocation(loc.line, loc.column, writer);
            if (diag.help) |help| try writer.print("   = help: {s}\n", .{help});
            try writer.writeByte('\n');
        }
    }

    // -------------------------------------------------------------------
    // Statement walking
    // -------------------------------------------------------------------

    // -------------------------------------------------------------------
    // Flow-sensitive narrowing store (D1 section 5)
    //
    // `binding_types` is the declared or inferred type of a binding.
    // `narrowed` is the flow overlay, and killing a narrowing means dropping
    // the overlay entry rather than losing the declaration.
    // -------------------------------------------------------------------

    /// The type a binding has at this point in the walk: the narrowing if one
    /// is installed, the declared type otherwise.
    ///
    /// The fallback chain is `inferType`'s, and it has to be. A guard extractor
    /// that read only `binding_types` saw `const` and `let` declarations and
    /// nothing else - a function parameter is registered in `param_types` and
    /// in the environment, so no guard over a parameter ever installed. Every
    /// narrowing test in the profile's closed list is written over a parameter
    /// at least as often as over a local.
    fn currentBindingType(self: *const TypeChecker, binding: ir.BindingRef) ?TypeIndex {
        const key = bindingKey(binding);
        if (self.narrowed.get(key)) |t| return t;
        if (self.binding_types.get(key)) |t| return t;
        const declared = self.declaredTypeForBinding(binding);
        return if (declared == null_type_idx) null else declared;
    }

    /// Open a branch scope. Every narrowing written while it is open is undone
    /// by the matching `endNarrowScope`, so a narrowing established inside a
    /// conditional cannot describe the path where that conditional was false.
    ///
    /// Kill rule 5 alone does not cover this: it drops narrowings whose binding
    /// lives in the closing block's scope, and the binding a guard narrows is
    /// usually a parameter of the enclosing function. So a nested early return -
    /// `if (flag) { if (v === undefined) { return "x"; } }` - installed the
    /// forward narrowing `v -> string` and it survived past the outer `if`,
    /// where `v` is still `string | undefined`.
    fn beginNarrowScope(self: *TypeChecker) usize {
        self.narrow_scopes += 1;
        return self.narrow_journal.items.len;
    }

    fn endNarrowScope(self: *TypeChecker, mark: usize) void {
        var i = self.narrow_journal.items.len;
        while (i > mark) {
            i -= 1;
            const entry = self.narrow_journal.items[i];
            if (entry.prev) |prev| {
                self.narrowed.put(self.allocator, entry.key, prev) catch self.markAllocationFailure();
            } else {
                _ = self.narrowed.remove(entry.key);
            }
        }
        self.narrow_journal.items.len = mark;
        if (self.narrow_scopes > 0) self.narrow_scopes -= 1;
    }

    /// Record what `key` held before it is overwritten or removed, so the
    /// enclosing branch scope can put it back. Outside a branch scope there is
    /// nothing to undo to, and nothing is recorded.
    fn recordNarrowChange(self: *TypeChecker, key: u64) void {
        if (self.narrow_scopes == 0) return;
        self.narrow_journal.append(
            self.allocator,
            .{ .key = key, .prev = self.narrowed.get(key) },
        ) catch self.markAllocationFailure();
    }

    fn putNarrowed(self: *TypeChecker, key: u64, narrowed_type: TypeIndex) void {
        self.recordNarrowChange(key);
        self.narrowed.put(self.allocator, key, narrowed_type) catch self.markAllocationFailure();
    }

    fn restoreNarrowed(self: *TypeChecker, key: u64, saved: ?TypeIndex) void {
        if (saved) |s| {
            self.putNarrowed(key, s);
        } else {
            self.killNarrowing(key);
        }
    }

    /// Kill rule 1. Any assignment to a binding drops its narrowing: the guard
    /// that installed it described the old value. Nothing killed these before,
    /// so a guard installed by an early return survived a later reassignment.
    fn killNarrowing(self: *TypeChecker, key: u64) void {
        self.recordNarrowChange(key);
        _ = self.narrowed.remove(key);
    }

    /// Kill rule 5. Drop every narrowing whose binding lives in `scope_id`.
    fn killNarrowingsInScope(self: *TypeChecker, scope_id: ir.ScopeId) void {
        const prefix = @as(u64, scope_id) << 32;
        var it = self.narrowed.iterator();
        var doomed: [32]u64 = undefined;
        var count: usize = 0;
        while (it.next()) |entry| {
            if ((entry.key_ptr.* & 0xFFFFFFFF00000000) != prefix) continue;
            if (count == doomed.len) break;
            doomed[count] = entry.key_ptr.*;
            count += 1;
        }
        for (doomed[0..count]) |key| {
            self.recordNarrowChange(key);
            _ = self.narrowed.remove(key);
        }
        // More than the buffer holds is rare and the remainder is dropped on
        // the next pass over the same scope; a leftover entry can only make a
        // later binding read as narrower than it is, so sweep until empty.
        if (count == doomed.len) self.killNarrowingsInScope(scope_id);
    }

    /// Kill rule 4, the entry half. A narrowing established before a loop only
    /// survives the body if the body never assigns the binding, because the
    /// back edge re-enters with whatever the last iteration left.
    ///
    /// The walk is structural over the statement shapes the subset admits. A
    /// shape it does not reach costs precision, never soundness: the set this
    /// kills only ever grows, and a narrowing it fails to kill is caught by
    /// nothing, which is why the listed shapes are the ones that can hold an
    /// assignment.
    fn killNarrowingsAssignedIn(self: *TypeChecker, node: NodeIndex, depth: u8) void {
        if (node == null_node or depth > 32) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return;
                if (self.ir_view.getTag(asgn.target) == .identifier) {
                    if (self.ir_view.getBinding(asgn.target)) |binding| {
                        self.killNarrowing(bindingKey(binding));
                    }
                }
                self.killNarrowingsAssignedIn(asgn.value, depth + 1);
            },
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.killNarrowingsAssignedIn(
                        self.ir_view.getListIndex(block.stmts_start, @intCast(i)),
                        depth + 1,
                    );
                }
            },
            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;
                self.killNarrowingsAssignedIn(if_s.condition, depth + 1);
                self.killNarrowingsAssignedIn(if_s.then_branch, depth + 1);
                self.killNarrowingsAssignedIn(if_s.else_branch, depth + 1);
            },
            .expr_stmt, .return_stmt => {
                if (self.ir_view.getOptValue(node)) |value| {
                    self.killNarrowingsAssignedIn(value, depth + 1);
                }
            },
            .for_of_stmt, .for_in_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                self.killNarrowingsAssignedIn(fi.iterable, depth + 1);
                self.killNarrowingsAssignedIn(fi.body, depth + 1);
            },
            // exhaustive: the listed shapes are the ones that can contain an
            // assignment in this subset. A tag not reached here contributes no
            // kill, which costs precision and never soundness: the set this
            // function kills only ever grows, and over-killing a narrowing widens
            // a binding back to its declared type.
            else => {},
        }
    }

    fn walkStmt(self: *TypeChecker, node: NodeIndex) void {
        if (self.allocation_failed) return;
        self.env.pool.ensureHealthy() catch return;
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                const active_start = self.active_declared_types.items.len;
                defer self.active_declared_types.items.len = active_start;
                for (0..block.stmts_count) |i| {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    self.walkStmt(stmt_idx);
                }
                // Kill rule 5. A narrowing of a binding declared in this scope
                // has nothing left to describe once the scope closes, and the
                // key it occupies is (scope, slot) - so leaving it behind would
                // hand it to whatever occupies that slot next.
                self.killNarrowingsInScope(block.scope_id);
            },

            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                const declared = self.bindVarDeclaration(vd.binding);
                self.reportIfNonContractive(declared, node);
                self.bindCallableMetadata(vd.binding, .unavailable);
                if (vd.init != null_node) {
                    self.walkExpr(vd.init);
                    const inferred = self.inferType(vd.init);
                    self.bindCallableMetadata(vd.binding, self.callableMetadataForExpression(vd.init, inferred));

                    // Check: does the initializer type match the declared type?
                    const binding = vd.binding;
                    const key = bindingKey(binding);

                    if (declared != null_type_idx and inferred != null_type_idx) {
                        if (!self.env.isAssignableTo(inferred, declared)) {
                            self.addTypeMismatch(node, declared, inferred);
                        }
                    }

                    // Track inferred type for use in later expressions.
                    // When annotation is a base primitive (number, string, boolean) and
                    // the inferred type is the corresponding literal, keep the narrower
                    // literal. This gives `: Type` satisfies-like semantics for primitives.
                    // For unions and compound annotations, keep the declared type since
                    // the annotation carries semantic intent for exhaustiveness checking.
                    //
                    // Only for `const`. A `let` exists to be reassigned, and
                    // binding it to its initializer's literal type refused every
                    // reassignment as "type '7' is not assignable to type '0'":
                    // the narrower type is sound for a value that cannot change
                    // and is a refusal of the form for one that must.
                    //
                    // For let bindings without explicit type annotations, widen
                    // literal types to their base type so reassignment works.
                    var effective = blk: {
                        if (declared != null_type_idx and inferred != null_type_idx) {
                            if (vd.kind != .@"const") break :blk declared;
                            const dt = self.env.pool.getTag(declared) orelse break :blk declared;
                            const it = self.env.pool.getTag(inferred) orelse break :blk declared;
                            const is_literal_of_base =
                                (dt == .t_number and it == .t_literal_number) or
                                (dt == .t_string and it == .t_literal_string) or
                                (dt == .t_boolean and it == .t_literal_bool);
                            break :blk if (is_literal_of_base) inferred else declared;
                        }
                        break :blk if (declared != null_type_idx) declared else inferred;
                    };
                    if (effective != null_type_idx and declared == null_type_idx and vd.kind == .let) {
                        effective = self.env.pool.widenLiteral(effective);
                    }
                    if (effective != null_type_idx) {
                        self.binding_types.put(self.allocator, key, effective) catch self.markAllocationFailure();
                    }
                }
            },

            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;
                self.walkExpr(if_s.condition);

                // Narrow in both branches when the condition is an admitted
                // guard: if (x), if (!x), if (x !== undefined), a discriminant
                // test. The narrowing lives in the flow overlay, never in
                // `binding_types` - that map is the declared type, and
                // overwriting it is what made a narrowing impossible to kill
                // without losing the declaration.
                const narrow = self.extractNarrowingGuard(if_s.condition);
                if (narrow.key != null and narrow.narrowed_type != null_type_idx) {
                    const key = narrow.key.?;

                    // Each branch runs inside its own narrow scope, so every
                    // narrowing written while walking it - the guard's own and
                    // any a nested early return installs - is undone on the way
                    // out. Restoring only the guard's key let the nested one
                    // escape and describe the path where this condition was
                    // false.
                    const then_mark = self.beginNarrowScope();
                    // A negated guard means the then-branch runs when the test
                    // failed, so the narrowed type belongs to the else branch.
                    if (!narrow.negated) self.putNarrowed(key, narrow.narrowed_type);
                    self.walkStmt(if_s.then_branch);
                    self.endNarrowScope(then_mark);

                    if (if_s.else_branch != null_node) {
                        const else_mark = self.beginNarrowScope();
                        const else_narrowed = if (narrow.negated) narrow.narrowed_type else narrow.else_type;
                        if (else_narrowed != null_type_idx) self.putNarrowed(key, else_narrowed);
                        self.walkStmt(if_s.else_branch);
                        self.endNarrowScope(else_mark);
                    }

                    // Forward narrowing after early return:
                    // if (!x) { return; } narrows x to non-null after the block
                    // if (x.kind === "err") { return; } narrows x to excluded union
                    if (if_s.else_branch == null_node and self.branchAlwaysReturns(if_s.then_branch)) {
                        if (narrow.negated) {
                            self.putNarrowed(key, narrow.narrowed_type);
                        } else if (narrow.else_type != null_type_idx) {
                            self.putNarrowed(key, narrow.else_type);
                        }
                    }
                } else {
                    // A condition that installs no guard still opens a branch:
                    // a narrowing established inside it is no more valid on the
                    // way out than one installed by a guard.
                    const then_mark = self.beginNarrowScope();
                    self.walkStmt(if_s.then_branch);
                    self.endNarrowScope(then_mark);
                    if (if_s.else_branch != null_node) {
                        const else_mark = self.beginNarrowScope();
                        self.walkStmt(if_s.else_branch);
                        self.endNarrowScope(else_mark);
                    }
                }
            },

            .return_stmt => {
                if (self.ir_view.getOptValue(node)) |ret_val| {
                    self.walkExpr(ret_val);
                    // Check return type against declared return type
                    if (self.current_return_type != null_type_idx) {
                        const inferred = self.inferType(ret_val);
                        if (inferred != null_type_idx and !self.env.isAssignableTo(inferred, self.current_return_type)) {
                            self.addDiagnostic(.{
                                .severity = .err,
                                .kind = .return_type_mismatch,
                                .node = node,
                                .message = "return type does not match declared return type",
                                .help = null,
                            });
                        }
                    }
                }
            },

            .assert_stmt => {
                // Extract narrowing guard from the assert condition and install
                // it as permanent forward narrowing (no restore after).
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                self.walkExpr(assert.condition);
                if (assert.error_expr != null_node) {
                    self.walkExpr(assert.error_expr);
                }
                const narrow = self.extractNarrowingGuard(assert.condition);
                if (narrow.key) |key| {
                    if (narrow.narrowed_type != null_type_idx and !narrow.negated) {
                        self.putNarrowed(key, narrow.narrowed_type);
                    }
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
                // Kill rule 4. A narrowing established before the loop is only
                // valid inside it if the body never reassigns the binding, and
                // a narrowing established inside the body does not survive the
                // back edge.
                self.killNarrowingsAssignedIn(fi.body, 0);
                var before = self.narrowed.clone(self.allocator) catch {
                    self.markAllocationFailure();
                    self.walkStmt(fi.body);
                    return;
                };
                defer before.deinit(self.allocator);
                self.walkStmt(fi.body);
                self.narrowed.clearRetainingCapacity();
                var it = before.iterator();
                while (it.next()) |entry| {
                    self.putNarrowed(entry.key_ptr.*, entry.value_ptr.*);
                }
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
                const decl = self.ir_view.getVarDecl(node) orelse return;
                const func = self.ir_view.getFunction(decl.init) orelse return;
                self.pushActiveDeclared(decl.binding.name_atom, null_type_idx);
                const fn_name = self.resolveAtomName(decl.binding.name_atom);
                const sig = if (fn_name) |name| self.env.getSourceFnSigByName(name) else null;
                self.bindCallableMetadata(
                    decl.binding,
                    if (sig) |s| .{ .signature = s } else .unavailable,
                );
                const active_start = self.active_declared_types.items.len;
                defer self.active_declared_types.items.len = active_start;
                // Named declarations resolve signatures by binding identity.
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    // Proof markers (Spec/Proof/Effects capsules) are
                    // obligations for the verifier, not shapes the returned
                    // value can satisfy; compare returns against the value
                    // type only.
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.checkParamDefaults(func, sig orelse .{});
                self.walkStmt(func.body);
                self.current_return_type = saved_return;
            },

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                const active_start = self.active_declared_types.items.len;
                defer self.active_declared_types.items.len = active_start;
                const loc = self.ir_view.getLoc(node);
                const sig = if (loc) |l| self.env.getFnSigByLoc(l.line) else null;
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.checkParamDefaults(func, sig orelse .{});
                self.walkStmt(func.body);
                self.current_return_type = saved_return;
            },

            .export_default => {
                if (self.ir_view.getOptValue(node)) |val| {
                    self.walkStmt(val);
                }
            },

            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.walkStmt(export_decl.declaration);
            },

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

            // exhaustive: the remaining tags hold no sub-expression this
            // checker types. Not descending costs a type error that would have
            // been reported, never a proof: an untyped value reaches the
            // lattice top, and `TypePool.isAssignableTo` skips rather than
            // rejects against it.
            else => {},
        }
    }

    // -------------------------------------------------------------------
    // Expression walking
    // -------------------------------------------------------------------

    fn walkExpr(self: *TypeChecker, node: NodeIndex) void {
        if (self.allocation_failed) return;
        self.env.pool.ensureHealthy() catch return;
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .call => {
                const c = self.ir_view.getCall(node) orelse return;
                self.collectSchemaCompileCall(c) catch self.markAllocationFailure();
                self.walkExpr(c.callee);
                // Check argument types against function signature
                self.checkCallArgs(node, c);
                for (0..c.args_count) |i| {
                    const arg = self.ir_view.getListIndex(c.args_start, @intCast(i));
                    self.walkExpr(arg);
                }
            },

            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.walkExpr(bin.left);
                self.walkExpr(bin.right);
            },

            .unary_op => {
                const un = self.ir_view.getUnary(node) orelse return;
                self.walkExpr(un.operand);
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return;
                self.walkExpr(t.condition);
                self.walkExpr(t.then_branch);
                self.walkExpr(t.else_branch);
            },

            .method_call => {
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
                // Check assignment type matches target's declared type
                const target_tag = self.ir_view.getTag(asgn.target) orelse return;
                if (target_tag == .identifier) {
                    const binding = self.ir_view.getBinding(asgn.target) orelse return;
                    const key = bindingKey(binding);
                    // Kill rule 1: the guard that installed the narrowing
                    // described the value being overwritten.
                    self.killNarrowing(key);
                    if (self.binding_types.get(key)) |declared| {
                        if (asgn.op == null) {
                            const val_type = self.inferType(asgn.value);
                            if (val_type != null_type_idx and !self.env.isAssignableTo(val_type, declared)) {
                                self.addTypeMismatch(node, declared, val_type);
                            }
                        }
                    }
                } else if (target_tag == .member_access) {
                    // Check readonly field assignment
                    const member = self.ir_view.getMember(asgn.target) orelse return;
                    const obj_tag = self.ir_view.getTag(member.object) orelse return;
                    if (obj_tag == .identifier) {
                        const binding = self.ir_view.getBinding(member.object) orelse return;
                        // Through the narrowing overlay, not `binding_types`:
                        // the readonly record is usually reached by a guard
                        // (`if (v !== undefined) { v.id = "x"; }`), and reading
                        // the declaration finds the nullable node instead. A
                        // non-record tag yields no fields, so the write to a
                        // readonly field passed in silence.
                        if (self.currentBindingType(binding)) |obj_type| {
                            const prop_name = self.resolveAtomName(member.property) orelse return;
                            if (self.env.pool.lookupRecordField(obj_type, prop_name)) |field| {
                                if (field.readonly) {
                                    self.addDiagnostic(.{
                                        .severity = .err,
                                        .kind = .type_mismatch,
                                        .node = node,
                                        .message = "cannot assign to readonly property",
                                        .help = null,
                                    });
                                }
                            }
                        }
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
                self.walkMatchWithNarrowing(me);
                if (!self.isMatchExhaustive(me)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .non_exhaustive_match,
                        .node = node,
                        .message = "match expression is not provably exhaustive",
                        .help = "add 'default:' or 'when _:' arm, or cover every union variant",
                    });
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

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                const active_start = self.active_declared_types.items.len;
                defer self.active_declared_types.items.len = active_start;
                const loc = self.ir_view.getLoc(node);
                const sig = if (loc) |l| self.env.getFnSigByLoc(l.line) else null;
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.walkStmt(func.body);
                self.current_return_type = saved_return;
            },

            // exhaustive: same as the expression walker above - the statement
            // kinds not listed carry nothing this checker types, and a missed
            // type is a missed rejection, not a granted proof.
            else => {},
        }
    }

    fn collectSchemaCompileCall(self: *TypeChecker, call: Node.CallExpr) !void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .identifier or call.args_count < 2) return;

        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const name = self.resolveAtomName(binding.name_atom) orelse return;
        if (!std.mem.eql(u8, name, "schemaCompile")) return;

        const schema_name_node = self.ir_view.getListIndex(call.args_start, 0);
        const schema_name = self.getLiteralString(schema_name_node) orelse return;
        const schema_json_node = self.ir_view.getListIndex(call.args_start, 1);
        const schema_json = (try self.extractSchemaJson(schema_json_node)) orelse return;
        defer self.allocator.free(schema_json);

        const type_idx = try self.schemaJsonToType(schema_json);
        if (type_idx == null_type_idx) return;

        for (self.compiled_schemas.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, schema_name)) continue;
            entry.type_idx = type_idx;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, schema_name);
        errdefer self.allocator.free(owned_name);
        try self.compiled_schemas.append(self.allocator, .{
            .name = owned_name,
            .type_idx = type_idx,
        });
    }

    fn schemaJsonToType(self: *TypeChecker, schema_json: []const u8) !TypeIndex {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => {
                self.markAllocationFailure();
                return error.OutOfMemory;
            },
            // exhaustive: a schema that is not parseable JSON yields no type,
            // which constrains nothing downstream. The one error that must not
            // be treated that way, allocation failure, is marked above.
            else => return null_type_idx,
        };
        defer parsed.deinit();
        return self.schemaValueToType(parsed.value);
    }

    fn schemaValueToType(self: *TypeChecker, value_json: std.json.Value) TypeIndex {
        const pool = self.env.pool;
        const obj = switch (value_json) {
            .object => |o| o,
            // exhaustive: a schema node that is not an object describes no
            // shape, so unknown is the honest answer - the lattice top, which
            // permits nothing to be proved from it.
            else => return pool.idx_unknown,
        };

        if (obj.get("enum")) |enum_val| {
            if (enum_val == .array and enum_val.array.items.len > 0) {
                var members: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer members.deinit(self.allocator);
                for (enum_val.array.items) |item| {
                    const member = switch (item) {
                        .string => |s| pool.addLiteralString(self.allocator, s),
                        .integer => |i| blk: {
                            const lit = std.math.cast(i16, i) orelse break :blk pool.idx_number;
                            break :blk pool.addLiteralNumber(self.allocator, lit);
                        },
                        .float => pool.idx_number,
                        .bool => |b| pool.addLiteralBool(self.allocator, b),
                        else => pool.idx_unknown,
                    };
                    members.append(self.allocator, member) catch {
                        self.markAllocationFailure();
                        return pool.idx_unknown;
                    };
                }
                if (members.items.len > 0) return pool.addUnion(self.allocator, members.items);
            }
        }

        const type_name = if (obj.get("type")) |type_val|
            switch (type_val) {
                .string => |s| s,
                else => "",
            }
        else
            "";

        if (std.mem.eql(u8, type_name, "string")) return pool.idx_string;
        if (std.mem.eql(u8, type_name, "number")) return pool.idx_number;
        if (std.mem.eql(u8, type_name, "integer")) return pool.idx_number;
        if (std.mem.eql(u8, type_name, "boolean")) return pool.idx_boolean;
        if (std.mem.eql(u8, type_name, "array")) {
            if (obj.get("items")) |items| {
                const elem = self.schemaValueToType(items);
                return pool.addArray(self.allocator, if (elem == null_type_idx) pool.idx_unknown else elem);
            }
            return pool.addArray(self.allocator, pool.idx_unknown);
        }

        if (std.mem.eql(u8, type_name, "object") or obj.get("properties") != null) {
            const props = obj.get("properties") orelse return pool.idx_unknown;
            if (props != .object) return pool.idx_unknown;

            var required: std.ArrayList([]const u8) = .empty;
            defer required.deinit(self.allocator);
            if (obj.get("required")) |required_val| {
                if (required_val == .array) {
                    for (required_val.array.items) |item| {
                        if (item != .string) continue;
                        required.append(self.allocator, item.string) catch self.markAllocationFailure();
                    }
                }
            }

            var fields: std.ArrayListUnmanaged(type_pool_mod.RecordField) = .empty;
            defer fields.deinit(self.allocator);
            var it = props.object.iterator();
            while (it.next()) |entry| {
                const prop_type = self.schemaValueToType(entry.value_ptr.*);
                const name = pool.addName(self.allocator, entry.key_ptr.*);
                fields.append(self.allocator, .{
                    .name_start = name.start,
                    .name_len = name.len,
                    .type_idx = if (prop_type == null_type_idx) pool.idx_unknown else prop_type,
                    .optional = !json_utils.containsString(required.items, entry.key_ptr.*),
                }) catch {
                    self.markAllocationFailure();
                    return pool.idx_unknown;
                };
            }
            if (fields.items.len == 0) return pool.idx_unknown;
            return pool.addRecord(self.allocator, fields.items);
        }

        return pool.idx_unknown;
    }

    fn getLiteralString(self: *const TypeChecker, node_idx: NodeIndex) ?[]const u8 {
        const str_idx = self.ir_view.getStringIdx(node_idx) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    fn getJsonStringifyArg(self: *const TypeChecker, node_idx: NodeIndex) ?NodeIndex {
        const call = self.ir_view.getCall(node_idx) orelse return null;
        if (call.args_count != 1) return null;

        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .member_access) return null;

        const member = self.ir_view.getMember(call.callee) orelse return null;
        if (member.property != @intFromEnum(object.Atom.stringify)) return null;

        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        if (binding.kind != .global and binding.kind != .undeclared_global) return null;
        if (binding.name_atom != @intFromEnum(object.Atom.JSON)) return null;

        return self.ir_view.getListIndex(call.args_start, 0);
    }

    fn extractSchemaJson(self: *TypeChecker, node_idx: NodeIndex) !?[]u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        return switch (tag) {
            .lit_string => blk: {
                const raw = self.getLiteralString(node_idx) orelse break :blk null;
                break :blk try self.allocator.dupe(u8, raw);
            },
            .call => blk: {
                const json_arg = self.getJsonStringifyArg(node_idx) orelse break :blk null;
                break :blk try self.serializeJsonLiteral(json_arg);
            },
            // exhaustive: null means "not a literal the compiler can read", and
            // the caller treats an unreadable schema as dynamic rather than as
            // an absent one.
            else => null,
        };
    }

    fn serializeJsonLiteral(self: *TypeChecker, node_idx: NodeIndex) !?[]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &output);
        const ok = try self.writeJsonLiteralNode(node_idx, &aw.writer);
        if (!ok) {
            output.deinit(self.allocator);
            return null;
        }
        output = aw.toArrayList();
        return try output.toOwnedSlice(self.allocator);
    }

    fn writeJsonLiteralNode(self: *TypeChecker, node_idx: NodeIndex, writer: anytype) !bool {
        const tag = self.ir_view.getTag(node_idx) orelse return false;
        switch (tag) {
            .lit_int => {
                const value_int = self.ir_view.getIntValue(node_idx) orelse return false;
                try writer.print("{d}", .{value_int});
                return true;
            },
            .lit_float => {
                const float_idx = self.ir_view.getFloatIdx(node_idx) orelse return false;
                const value_float = self.ir_view.getFloat(float_idx) orelse return false;
                try writer.print("{d}", .{value_float});
                return true;
            },
            .lit_string => {
                const str = self.getLiteralString(node_idx) orelse return false;
                try writeJsonString(writer, str);
                return true;
            },
            .lit_bool => {
                const value_bool = self.ir_view.getBoolValue(node_idx) orelse return false;
                try writer.writeAll(if (value_bool) "true" else "false");
                return true;
            },
            .lit_null => {
                try writer.writeAll("null");
                return true;
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node_idx) orelse return false;
                if (unary.op != .neg) return false;
                try writer.writeByte('-');
                return self.writeJsonLiteralNode(unary.operand, writer);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node_idx) orelse return false;
                try writer.writeByte('[');
                for (0..arr.elements_count) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (!try self.writeJsonLiteralNode(self.ir_view.getListIndex(arr.elements_start, @intCast(i)), writer)) return false;
                }
                try writer.writeByte(']');
                return true;
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node_idx) orelse return false;
                try writer.writeByte('{');
                for (0..obj.properties_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse return false;
                    const key = self.getObjectPropertyKey(prop.key) orelse return false;
                    if (i > 0) try writer.writeAll(", ");
                    try writeJsonString(writer, key);
                    try writer.writeAll(": ");
                    if (!try self.writeJsonLiteralNode(prop.value, writer)) return false;
                }
                try writer.writeByte('}');
                return true;
            },
            // exhaustive: false means "this node is not a JSON literal", which
            // abandons the serialization. The caller then has no literal to
            // reason about, which is the conservative outcome.
            else => return false,
        }
    }

    fn getObjectPropertyKey(self: *const TypeChecker, node_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        return switch (tag) {
            .lit_string => self.getLiteralString(node_idx),
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node_idx) orelse break :blk null;
                break :blk self.resolveAtomName(binding.name_atom);
            },
            // exhaustive: an object key is a string literal or a bare
            // identifier; a computed key is not statically known, and null
            // stops the literal read rather than inventing a name.
            else => null,
        };
    }

    fn schemaTypeByName(self: *const TypeChecker, name: []const u8) ?TypeIndex {
        for (self.compiled_schemas.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.type_idx;
        }
        return null;
    }

    fn typedResultType(self: *const TypeChecker, inner: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const ok_name = pool.addName(self.allocator, "ok");
        const val_name = pool.addName(self.allocator, "value");
        const err_name = pool.addName(self.allocator, "error");
        const errs_name = pool.addName(self.allocator, "errors");
        return pool.addRecord(self.allocator, &.{
            .{ .name_start = ok_name.start, .name_len = ok_name.len, .type_idx = pool.idx_boolean, .optional = false },
            .{ .name_start = val_name.start, .name_len = val_name.len, .type_idx = inner, .optional = true },
            .{ .name_start = err_name.start, .name_len = err_name.len, .type_idx = pool.idx_string, .optional = true },
            .{ .name_start = errs_name.start, .name_len = errs_name.len, .type_idx = pool.idx_unknown, .optional = true },
        });
    }

    const ParsedServiceRoute = @import("system_linker.zig").ParsedServiceRoute;
    const parseServiceRoute = @import("system_linker.zig").parseServiceRoute;

    const ServiceCallInitInfo = struct {
        path_params: std.ArrayList([]const u8) = .empty,
        query_keys: std.ArrayList([]const u8) = .empty,
        header_keys: std.ArrayList([]const u8) = .empty,
        path_params_dynamic: bool = false,
        query_dynamic: bool = false,
        header_dynamic: bool = false,
        has_body: bool = false,
        body_dynamic: bool = false,

        fn deinit(self: *ServiceCallInitInfo, allocator: std.mem.Allocator) void {
            self.path_params.deinit(allocator);
            self.query_keys.deinit(allocator);
            self.header_keys.deinit(allocator);
        }
    };

    fn extractServiceObjectKeys(
        self: *const TypeChecker,
        node_idx: NodeIndex,
        target: *std.ArrayList([]const u8),
        dynamic_flag: *bool,
    ) void {
        const tag = self.ir_view.getTag(node_idx) orelse {
            dynamic_flag.* = true;
            return;
        };
        if (tag != .object_literal) {
            dynamic_flag.* = true;
            return;
        }

        const obj = self.ir_view.getObject(node_idx) orelse {
            dynamic_flag.* = true;
            return;
        };
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key = self.getObjectPropertyKey(prop.key) orelse {
                dynamic_flag.* = true;
                continue;
            };
            target.append(self.allocator, key) catch @constCast(self).markAllocationFailure();
        }
    }

    fn extractServiceCallInitInfo(self: *const TypeChecker, call: Node.CallExpr) ServiceCallInitInfo {
        var info = ServiceCallInitInfo{};
        if (call.args_count <= 2) return info;

        const init_idx = self.ir_view.getListIndex(call.args_start, 2);
        const tag = self.ir_view.getTag(init_idx) orelse {
            info.path_params_dynamic = true;
            info.query_dynamic = true;
            info.header_dynamic = true;
            info.body_dynamic = true;
            return info;
        };
        if (tag == .lit_null or tag == .lit_undefined) return info;
        if (tag != .object_literal) {
            info.path_params_dynamic = true;
            info.query_dynamic = true;
            info.header_dynamic = true;
            info.body_dynamic = true;
            return info;
        }

        const obj = self.ir_view.getObject(init_idx) orelse return info;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key = self.getObjectPropertyKey(prop.key) orelse continue;

            if (std.mem.eql(u8, key, "params")) {
                self.extractServiceObjectKeys(prop.value, &info.path_params, &info.path_params_dynamic);
            } else if (std.mem.eql(u8, key, "query")) {
                self.extractServiceObjectKeys(prop.value, &info.query_keys, &info.query_dynamic);
            } else if (std.mem.eql(u8, key, "headers")) {
                self.extractServiceObjectKeys(prop.value, &info.header_keys, &info.header_dynamic);
            } else if (std.mem.eql(u8, key, "body")) {
                const body_tag = self.ir_view.getTag(prop.value) orelse {
                    info.has_body = true;
                    info.body_dynamic = true;
                    continue;
                };
                if (body_tag == .lit_null or body_tag == .lit_undefined) continue;
                info.has_body = true;
                if (body_tag != .lit_string and body_tag != .object_literal and body_tag != .array_literal) {
                    info.body_dynamic = true;
                }
            }
        }
        return info;
    }

    const containsString = json_utils.containsString;

    fn addAllocatedDiagnostic(
        self: *TypeChecker,
        kind: DiagnosticKind,
        node: NodeIndex,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.markAllocationFailure();
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = kind,
            .node = node,
            .message = msg,
            .help = null,
            .allocated = true,
        });
    }

    fn validateServiceCallAgainstRoute(
        self: *TypeChecker,
        node: NodeIndex,
        call: Node.CallExpr,
        route: *const service_types_mod.RouteInfo,
    ) void {
        var init_info = self.extractServiceCallInitInfo(call);
        defer init_info.deinit(self.allocator);

        for (route.required_path_params) |name| {
            if (init_info.path_params_dynamic) {
                self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall cannot prove path param '{s}'", .{name});
                return;
            }
            if (!containsString(init_info.path_params.items, name)) {
                self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall is missing path param '{s}'", .{name});
                return;
            }
        }

        if (!route.request_dynamic) {
            for (route.required_query_params) |name| {
                if (init_info.query_dynamic) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall cannot prove query param '{s}'", .{name});
                    return;
                }
                if (!containsString(init_info.query_keys.items, name)) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall is missing query param '{s}'", .{name});
                    return;
                }
            }

            for (route.required_header_params) |name| {
                if (init_info.header_dynamic) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall cannot prove header '{s}'", .{name});
                    return;
                }
                if (!containsString(init_info.header_keys.items, name)) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall is missing header '{s}'", .{name});
                    return;
                }
            }

            if (route.requires_body) {
                if (init_info.body_dynamic) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall cannot prove request body presence", .{});
                    return;
                }
                if (!init_info.has_body) {
                    self.addAllocatedDiagnostic(.arg_type_mismatch, node, "serviceCall is missing required request body", .{});
                    return;
                }
            }
        }
    }

    fn buildServiceResponseMember(
        self: *const TypeChecker,
        response: service_types_mod.ResponseVariant,
    ) TypeIndex {
        const pool = self.env.pool;
        const status_name = pool.addName(self.allocator, "status");
        const ok_name = pool.addName(self.allocator, "ok");
        const json_name = pool.addName(self.allocator, "json");
        const text_name = pool.addName(self.allocator, "text");
        const headers_name = pool.addName(self.allocator, "headers");

        const status_int: i16 = @intCast(@min(response.status, std.math.maxInt(i16)));
        const status_type = pool.addLiteralNumber(self.allocator, status_int);
        const ok_type = pool.addLiteralBool(self.allocator, response.status >= 200 and response.status < 300);
        const json_return_type = blk: {
            if (response.dynamic) break :blk pool.idx_unknown;
            if (response.content_type) |content_type| {
                if (!std.mem.startsWith(u8, content_type, "application/json")) break :blk pool.idx_unknown;
            } else {
                break :blk pool.idx_unknown;
            }
            if (response.schema_json) |schema_json| {
                break :blk @constCast(self).schemaJsonToType(schema_json) catch {
                    @constCast(self).markAllocationFailure();
                    break :blk pool.idx_unknown;
                };
            }
            break :blk pool.idx_unknown;
        };
        const json_fn = pool.addFunction(self.allocator, &.{}, json_return_type);
        const text_fn = pool.addFunction(self.allocator, &.{}, pool.idx_string);

        return pool.addRecord(self.allocator, &.{
            .{ .name_start = status_name.start, .name_len = status_name.len, .type_idx = status_type, .optional = false },
            .{ .name_start = ok_name.start, .name_len = ok_name.len, .type_idx = ok_type, .optional = false },
            .{ .name_start = json_name.start, .name_len = json_name.len, .type_idx = json_fn, .optional = false },
            .{ .name_start = text_name.start, .name_len = text_name.len, .type_idx = text_fn, .optional = false },
            .{ .name_start = headers_name.start, .name_len = headers_name.len, .type_idx = pool.idx_unknown, .optional = false },
        });
    }

    fn inferServiceCallType(self: *const TypeChecker, call: Node.CallExpr) TypeIndex {
        const service_context = self.service_type_context orelse return null_type_idx;
        if (call.args_count < 2) return null_type_idx;

        const service_node = self.ir_view.getListIndex(call.args_start, 0);
        const route_node = self.ir_view.getListIndex(call.args_start, 1);
        const service_name = self.getLiteralString(service_node) orelse return null_type_idx;
        const route_pattern = self.getLiteralString(route_node) orelse return null_type_idx;
        const parsed = parseServiceRoute(route_pattern) orelse return null_type_idx;
        const route = service_context.lookupRoute(service_name, parsed.method, parsed.path) orelse return null_type_idx;
        if (route.responses.len == 0) return null_type_idx;

        var member_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
        var count: usize = 0;
        for (route.responses) |response| {
            if (count >= member_types.len) break;
            member_types[count] = self.buildServiceResponseMember(response);
            count += 1;
        }
        if (count == 0) return null_type_idx;
        if (count == 1) return member_types[0];
        return self.env.pool.addUnion(self.allocator, member_types[0..count]);
    }

    // -------------------------------------------------------------------
    // Type inference (TypePool-based)
    // -------------------------------------------------------------------

    /// Infer the TypeIndex of an expression. Returns null_type_idx for unknown.
    /// The deterministic join of spec 5.4, steps 1-5. It types `?:`, and
    /// anything else that has to pick one type for two branches.
    ///
    /// Step 2 asks for the canonical type identity from `type_key.zig`, not
    /// index equality: the pool does not intern, so two structurally identical
    /// records hold different indices, and index equality would fall through to
    /// step 3 and produce the right answer only by accident - and the wrong one
    /// as soon as a field is optional on one side.
    pub fn joinTypes(self: *const TypeChecker, when_true: TypeIndex, when_false: TypeIndex) TypeIndex {
        const pool = self.env.pool;

        // Outside the spec's join, which assumes both branches type: an
        // un-inferred branch contributes nothing, so defer to the other side
        // rather than widening the result to a union with a hole in it.
        if (when_true == null_type_idx) return when_false;
        if (when_false == null_type_idx) return when_true;

        // 1. Remove `never`.
        if (when_true == pool.idx_never) return when_false;
        if (when_false == pool.idx_never) return when_true;

        // 2. Structurally identical.
        if (type_key.structurallyEqual(pool, self.allocator, when_true, when_false)) return when_true;

        const true_to_false = pool.isAssignableTo(when_true, when_false);
        const false_to_true = pool.isAssignableTo(when_false, when_true);

        // 3. Mutually assignable: the whenTrue branch wins. A syntactic rule, so
        //    a reader reaches it without a type-identity oracle.
        if (true_to_false and false_to_true) return when_true;

        // 4. Assignable one way only: the receiving type wins.
        if (true_to_false) return when_false;
        if (false_to_true) return when_true;

        // 5. Otherwise the normalized union.
        return pool.addUnion(self.allocator, &.{ when_true, when_false });
    }

    pub fn inferType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        self.env.pool.ensureHealthy() catch return null_type_idx;
        if (node == null_node) return null_type_idx;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (tag) {
            .lit_bool => blk: {
                const val = self.ir_view.getBoolValue(node) orelse break :blk pool.idx_boolean;
                break :blk pool.addLiteralBool(self.allocator, val);
            },
            .lit_int => blk: {
                const val = self.ir_view.getIntValue(node) orelse break :blk pool.idx_number;
                const int_val = std.math.cast(i16, val) orelse break :blk pool.idx_number;
                break :blk pool.addLiteralNumber(self.allocator, int_val);
            },
            .lit_float => pool.idx_number,
            .lit_string => blk: {
                const str_idx = self.ir_view.getStringIdx(node) orelse break :blk pool.idx_string;
                const str = self.ir_view.getString(str_idx) orelse break :blk pool.idx_string;
                break :blk pool.addLiteralString(self.allocator, str);
            },
            .template_literal => pool.idx_string,
            .lit_null => pool.idx_null,
            .lit_undefined => pool.idx_undefined,
            .object_literal => self.inferObjectLiteralType(node),
            .array_literal => self.inferArrayLiteralType(node),
            .function_expr, .arrow_function, .function_decl => null_type_idx, // Function types handled via signatures

            .binary_op => self.inferBinaryType(node),
            .unary_op => self.inferUnaryType(node),

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return null_type_idx;
                return self.joinTypes(
                    self.inferType(t.then_branch),
                    self.inferType(t.else_branch),
                );
            },

            .identifier => {
                const binding = self.ir_view.getBinding(node) orelse return null_type_idx;
                const key = bindingKey(binding);
                // Check narrowing first
                if (self.narrowed.get(key)) |t| return t;
                // Check tracked binding types
                if (self.binding_types.get(key)) |t| return t;
                return self.declaredTypeForBinding(binding);
            },

            .member_access => self.inferMemberAccessType(node),

            .call => self.inferCallType(node),

            .match_expr => self.inferMatchType(node),

            // exhaustive: no inferred type. `TypePool.isAssignableTo` treats
            // null_type_idx as "inference produced no result, so skip rather
            // than reject", so an expression that lands here loses a type
            // error and gains nothing.
            else => null_type_idx,
        };
    }

    // -------------------------------------------------------------------
    // If-guard narrowing helpers
    // -------------------------------------------------------------------

    const NarrowingGuard = struct {
        /// Absent means the condition installed no guard. This used to be a `0`
        /// sentinel, which made the binding at scope 0 slot 0 the one binding
        /// in the program that could never narrow.
        key: ?u64 = null,
        narrowed_type: TypeIndex = null_type_idx,
        negated: bool = false,
        /// For discriminated unions: the type to install after the then-branch
        /// returns (the union with the matched member excluded).
        else_type: TypeIndex = null_type_idx,
    };

    /// Extract a narrowing guard from an if-condition.
    /// Handles: if (x), if (!x), if (x !== undefined), if (x === undefined)
    fn extractNarrowingGuard(self: *const TypeChecker, condition: NodeIndex) NarrowingGuard {
        const tag = self.ir_view.getTag(condition) orelse return .{};

        // if (x) - truthiness guard on nullable binding. Truthiness excludes
        // both absent values, which is why this one asks for `.either`.
        if (tag == .identifier) {
            const r = self.resolveAbsentBinding(condition, .either) orelse return .{};
            return .{ .key = r.key, .narrowed_type = r.inner, .negated = false };
        }

        // if (r.ok) - a bare boolean discriminant read. The `Result` idiom is
        // written this way as often as it is written `r.ok === true`, and only
        // the second form narrowed.
        if (tag == .member_access) {
            // `if (r.ok)` runs its then-branch when the field is true, so the
            // member being selected is the one whose discriminant is `true`.
            // The `!` form is handled by the negation wrapper below, which
            // swaps the two sides rather than asking for a different member.
            if (self.extractBooleanDiscriminantGuard(condition, true)) |guard| return guard;
        }

        // if (Array.isArray(x)), or a call to an admitted type predicate
        if (tag == .call) {
            if (self.extractIsArrayGuard(condition)) |guard| return guard;
            if (self.extractIsDictGuard(condition)) |guard| return guard;
            if (self.extractIsBytesGuard(condition)) |guard| return guard;
            if (self.extractTypePredicateGuard(condition)) |guard| return guard;
        }

        // if (x !== undefined), if (x === undefined), or if (x.prop === "literal")
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(condition) orelse return .{};
            if (bin.op != .strict_neq and bin.op != .strict_eq) return .{};

            const lhs_tag = self.ir_view.getTag(bin.left) orelse return .{};
            const rhs_tag = self.ir_view.getTag(bin.right) orelse return .{};

            // Pattern: x === undefined / x !== undefined, and the same shape
            // over `null`. Spec 5.3 makes the explicit comparison the way a
            // type carrying `null` is taken apart, so each test removes only
            // the value it names.
            const absent_kind: ?AbsentKind = blk: {
                if ((lhs_tag == .identifier and rhs_tag == .lit_undefined) or
                    (rhs_tag == .identifier and lhs_tag == .lit_undefined)) break :blk .undefined_only;
                if ((lhs_tag == .identifier and rhs_tag == .lit_null) or
                    (rhs_tag == .identifier and lhs_tag == .lit_null)) break :blk .null_only;
                break :blk null;
            };
            if (absent_kind) |kind| {
                const ident_node = if (lhs_tag == .identifier) bin.left else bin.right;
                const r = self.resolveAbsentBinding(ident_node, kind) orelse return .{};
                return .{
                    .key = r.key,
                    .narrowed_type = r.inner,
                    .negated = bin.op == .strict_eq, // === undefined is negated (narrows in else)
                };
            }

            // Pattern: typeof x === "string". This test lived only in
            // `bool_checker`'s coarse `ExprType` lattice, so the profile's
            // closed narrowing list had an entry the authoritative system
            // could not answer.
            if (self.extractTypeofGuard(bin)) |guard| return guard;

            // Pattern: x.prop === <literal> (discriminated union narrowing)
            const lhs_is_literal = lhs_tag == .lit_string or lhs_tag == .lit_int or lhs_tag == .lit_bool;
            const rhs_is_literal = rhs_tag == .lit_string or rhs_tag == .lit_int or rhs_tag == .lit_bool;
            if ((lhs_tag == .member_access and rhs_is_literal) or
                (rhs_tag == .member_access and lhs_is_literal))
            {
                const member_node = if (lhs_tag == .member_access) bin.left else bin.right;
                const literal_node = if (lhs_is_literal) bin.left else bin.right;
                if (self.extractDiscriminantGuard(member_node, literal_node, bin.op)) |guard| {
                    return guard;
                }
            }
        }

        // `!` of any admitted test. `if (!r.ok) return;` is the shape the
        // Result idiom depends on, and before this only `!x` on a nullable
        // binding was recognized.
        if (tag == .unary_op) {
            const un = self.ir_view.getUnary(condition) orelse return .{};
            if (un.op != .not) return .{};
            var inner = self.extractNarrowingGuard(un.operand);
            if (inner.key == null) return .{};
            inner.negated = !inner.negated;
            // The two sides swap with the sense of the test, so a discriminant
            // guard keeps describing the branch it actually applies to.
            const then_type = inner.narrowed_type;
            if (inner.else_type != null_type_idx) {
                inner.narrowed_type = inner.else_type;
                inner.else_type = then_type;
                inner.negated = !inner.negated;
            }
            return inner;
        }

        return .{};
    }

    /// `typeof x === "string"` and its `!==` form, over a binding whose type is
    /// a union. Members matching the named primitive stay in the then branch,
    /// the rest go to the else branch.
    fn extractTypeofGuard(self: *const TypeChecker, bin: anytype) ?NarrowingGuard {
        const lhs_tag = self.ir_view.getTag(bin.left) orelse return null;
        const rhs_tag = self.ir_view.getTag(bin.right) orelse return null;

        const typeof_node, const literal_node = if (lhs_tag == .unary_op and rhs_tag == .lit_string)
            .{ bin.left, bin.right }
        else if (rhs_tag == .unary_op and lhs_tag == .lit_string)
            .{ bin.right, bin.left }
        else
            return null;

        const un = self.ir_view.getUnary(typeof_node) orelse return null;
        if (un.op != .typeof_op) return null;
        if (self.ir_view.getTag(un.operand) != .identifier) return null;

        const binding = self.ir_view.getBinding(un.operand) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const wanted = self.getLiteralString(literal_node) orelse return null;
        const pool = self.env.pool;

        // Heap, not a sixteen-slot scratch buffer: a union wider than that is
        // representable and routine, and bailing out left it unnarrowable.
        var matched: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer matched.deinit(self.allocator);
        var rest: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer rest.deinit(self.allocator);

        const members = if (pool.getTag(current) == .t_union)
            pool.getUnionMembers(current)
        else
            &[_]TypeIndex{current};

        for (members) |candidate| {
            const hit = typeofNameOf(pool, candidate);
            const is_match = hit != null and std.mem.eql(u8, hit.?, wanted);
            if (is_match) {
                matched.append(self.allocator, candidate) catch return null;
            } else {
                rest.append(self.allocator, candidate) catch return null;
            }
        }
        if (matched.items.len == 0 or rest.items.len == 0) return null;

        return .{
            .key = key,
            .narrowed_type = pool.addUnion(self.allocator, matched.items),
            .negated = bin.op == .strict_neq,
            .else_type = pool.addUnion(self.allocator, rest.items),
        };
    }

    /// What `typeof` answers for a type, or null when the type has no single
    /// answer. A union member with no answer never matches, which keeps it on
    /// the else side rather than silently joining the narrowed branch.
    fn typeofNameOf(pool: *const TypePool, idx: TypeIndex) ?[]const u8 {
        return switch (pool.getTag(idx) orelse return null) {
            .t_string, .t_literal_string, .t_template_literal => "string",
            .t_number, .t_literal_number => "number",
            .t_boolean, .t_literal_bool => "boolean",
            .t_undefined, .t_void => "undefined",
            .t_function => "function",
            .t_record, .t_array, .t_tuple, .t_null => "object",
            // exhaustive: the remaining tags have no single `typeof` answer - a
            // generic parameter, an unresolved ref, an intersection, and a template
            // literal each stand for more than one runtime shape. Answering null
            // keeps such a member on the else side of the test, which is the
            // direction that cannot claim a narrowing the test did not prove.
            else => null,
        };
    }

    /// `if (r.ok)` over a union discriminated by a boolean field. Reuses the
    /// literal-discriminant machinery with the literal supplied rather than
    /// parsed, since there is no literal node to read.
    fn extractBooleanDiscriminantGuard(
        self: *const TypeChecker,
        member_node: NodeIndex,
        expect: bool,
    ) ?NarrowingGuard {
        const member = self.ir_view.getMember(member_node) orelse return null;
        if (self.ir_view.getTag(member.object) != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;
        if (self.env.pool.getTag(current) != .t_union) return null;

        const prop_name = self.resolveAtomName(member.property) orelse return null;
        const wanted = self.env.pool.addLiteralBool(self.allocator, expect);
        const opposite = self.env.pool.addLiteralBool(self.allocator, !expect);

        // The field has to be an actual discriminant before reading it can
        // select a member: every member must carry it, exactly one must fix it
        // to the value the branch tests for, and every other must fix it to the
        // opposite. Taking the first literal match instead treated any
        // `if (obj.field)` as a discriminant test, so in
        // `{ on: true, a: string } | { on: boolean, b: string }` the guard
        // selected the first member even though the second can also have
        // `on === true`, and `c.b` in the then-branch reported a missing
        // property on a correct program. A plain `boolean` field fixes nothing
        // and now installs no guard at all.
        var selected: TypeIndex = null_type_idx;
        for (self.env.pool.getUnionMembers(current)) |candidate| {
            const field = self.env.pool.lookupRecordField(candidate, prop_name) orelse return null;
            if (self.mutuallyAssignable(field.type_idx, wanted)) {
                if (selected != null_type_idx) return null;
                selected = candidate;
                continue;
            }
            if (!self.mutuallyAssignable(field.type_idx, opposite)) return null;
        }
        if (selected == null_type_idx) return null;

        return .{
            .key = key,
            .narrowed_type = selected,
            .negated = false,
            .else_type = self.env.pool.excludeUnionMember(self.allocator, current, selected),
        };
    }

    fn mutuallyAssignable(self: *const TypeChecker, a: TypeIndex, b: TypeIndex) bool {
        return self.env.isAssignableTo(a, b) and self.env.isAssignableTo(b, a);
    }

    // -------------------------------------------------------------------
    // Type predicates (`function isText(v: unknown): v is string`)
    //
    // The annotation is a claim, not a proof. A predicate installs a narrowing
    // at its call sites only when its body is a single `return` of tests this
    // checker can already verify - the closed narrowing list over the named
    // parameter, combined with `&&`, `||`, and `!`. Any other body keeps the
    // declaration and raises ZTS211, because a guard the compiler cannot check
    // is a narrowing the author asserted and nothing confirmed.
    // -------------------------------------------------------------------

    /// Walk declarations looking for type predicates, admitting the ones whose
    /// bodies check out and reporting the ones that do not.
    /// Record every source function's minimum arity before any call is
    /// checked, so a call that omits a trailing defaulted argument is not
    /// reported against the declared parameter count.
    ///
    /// The signature scan builds its parameter list from annotation text,
    /// which carries no default, so this is the only place the two facts meet.
    fn recordDefaultArity(self: *TypeChecker, node: NodeIndex, depth: u8) void {
        if (depth > 32) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.recordDefaultArity(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), depth + 1);
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.recordDefaultArity(export_decl.declaration, depth + 1);
            },
            // A function bound to a `const` resolves by name at its call sites
            // exactly as a declared one does, and its default was measured
            // against the full parameter list until this arm existed:
            // `const step = (base, delta = 5) => ...` reported "expected 2,
            // got 1" for `step(1)`. `recordOneDefaultArity` reads the
            // initializer, so a binding whose initializer is not a function
            // records nothing and costs one lookup.
            .function_decl, .var_decl => self.recordOneDefaultArity(node),
            // exhaustive: anything else carries no name a call resolves.
            else => {},
        }
    }

    fn recordOneDefaultArity(self: *TypeChecker, node: NodeIndex) void {
        const decl = self.ir_view.getVarDecl(node) orelse return;
        if (decl.init == null_node) return;
        // `getFunction` reads the node's payload without consulting its tag,
        // so asking it about `const x = 1;` returns a function-shaped view of
        // an integer: a parameter list at a nonsense offset, and a
        // `has_default_params` bit that is whatever that memory held. The tag
        // is the check. Without it this pass walked a bound literal's
        // "parameters" and panicked on an invalid enum value.
        switch (self.ir_view.getTag(decl.init) orelse return) {
            .function_expr, .arrow_function, .function_decl => {},
            // exhaustive: every other initializer binds a value that is not a
            // function, and a value has no parameters to record an arity for.
            // Recording nothing leaves the call site measured against its
            // declared signature, which is the answer for a non-function.
            else => return,
        }
        const func = self.ir_view.getFunction(decl.init) orelse return;
        if (!func.flags.has_default_params) return;
        const fn_name = self.resolveAtomName(decl.binding.name_atom) orelse return;
        const loc = self.ir_view.getLoc(decl.init) orelse return;

        // The first defaulted position bounds the minimum arity. A default in
        // any earlier position is refused by ZTS617, and reading only the
        // first one keeps this pass from claiming an arity that rule denies.
        var required: u8 = 0;
        while (required < func.params_count) : (required += 1) {
            const param_idx = self.ir_view.getListIndex(func.params_start, required);
            // A parameter that is not a pattern element carries no default, so
            // it is required and the scan continues past it.
            if (self.ir_view.getTag(param_idx) != .pattern_element) continue;
            const elem = self.ir_view.getPatternElem(param_idx) orelse continue;
            if (elem.default_value != null_node) break;
        }
        self.env.setRequiredParamCount(fn_name, loc.line, required);
    }

    fn admitTypePredicates(self: *TypeChecker, node: NodeIndex, depth: u8) void {
        if (depth > 32) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.admitTypePredicates(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), depth + 1);
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.admitTypePredicates(export_decl.declaration, depth + 1);
            },
            .function_decl => self.admitOneTypePredicate(node),
            // exhaustive: a type predicate is a named function declaration, so
            // only the forms that can carry one are descended into. Anything
            // else declares no predicate and needs no visit.
            else => {},
        }
    }

    fn admitOneTypePredicate(self: *TypeChecker, node: NodeIndex) void {
        const decl = self.ir_view.getVarDecl(node) orelse return;
        const func = self.ir_view.getFunction(decl.init) orelse return;
        const fn_name = self.resolveAtomName(decl.binding.name_atom) orelse return;
        const sig = self.env.getSourceFnSigByName(fn_name) orelse return;
        const predicate = sig.type_predicate orelse return;
        if (predicate.param_index >= func.params_count) return;

        const param_idx = self.ir_view.getListIndex(func.params_start, predicate.param_index);
        const param_binding = self.ir_view.paramBinding(param_idx) orelse return;

        // The guard extractors read the parameter's declared type, so register
        // the parameters for the length of the check and unwind after.
        const active_start = self.active_declared_types.items.len;
        defer self.active_declared_types.items.len = active_start;
        self.registerParamTypes(func, sig);

        if (self.predicateBodyProves(func.body, param_binding)) {
            self.admitted_predicates.put(self.allocator, fn_name, {}) catch self.markAllocationFailure();
            return;
        }
        self.addGenericDiagnostic(
            .invalid_type_predicate,
            node,
            "type predicate '{s}' is not verified by its body",
            .{fn_name},
            "a type predicate is not verified by its body",
            "Return one admitted narrowing test over the named parameter, combined with &&, || or !.",
        );
    }

    /// True when the body is exactly `return <admitted test tree>`.
    fn predicateBodyProves(self: *const TypeChecker, body: NodeIndex, param: ir.BindingRef) bool {
        var statement = body;
        if (self.ir_view.getTag(body) == .block) {
            const block = self.ir_view.getBlock(body) orelse return false;
            if (block.stmts_count != 1) return false;
            statement = self.ir_view.getListIndex(block.stmts_start, 0);
        }
        if (self.ir_view.getTag(statement) != .return_stmt) return false;
        const value = self.ir_view.getOptValue(statement) orelse return false;
        return self.predicateTestProves(value, param, 0);
    }

    fn predicateTestProves(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef, depth: u8) bool {
        if (depth > 16) return false;
        const tag = self.ir_view.getTag(node) orelse return false;

        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(node) orelse return false;
            if (bin.op == .and_op or bin.op == .or_op) {
                return self.predicateTestProves(bin.left, param, depth + 1) and
                    self.predicateTestProves(bin.right, param, depth + 1);
            }
        }
        if (tag == .unary_op) {
            const un = self.ir_view.getUnary(node) orelse return false;
            if (un.op == .not) return self.predicateTestProves(un.operand, param, depth + 1);
        }

        // A leaf must be one of the tests in the closed narrowing list, over the
        // parameter the predicate names. The check is on the form of the test,
        // not on whether that test would narrow this particular declared type:
        // `typeof x === "object"` over `x: unknown` narrows nothing today
        // because `unknown` is not a union, and it is still exactly the test the
        // predicate is allowed to be made of. A call to another function, a
        // comparison between two other values, or a bare `true` is not.
        return self.predicateLeafTestsParam(node, param);
    }

    fn predicateLeafTestsParam(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            // `if (x)` - truthiness, and `if (x.ok)` - a bare discriminant read.
            .identifier, .member_access => return self.operandNamesParam(node, param),
            // `Array.isArray(x)`
            .call => {
                const call = self.ir_view.getCall(node) orelse return false;
                if (call.args_count != 1) return false;
                if (self.ir_view.getTag(call.callee) != .member_access) return false;
                const callee = self.ir_view.getMember(call.callee) orelse return false;
                if (self.ir_view.getTag(callee.object) != .identifier) return false;
                const object_binding = self.ir_view.getBinding(callee.object) orelse return false;
                const object_name = self.resolveAtomName(object_binding.name_atom) orelse return false;
                if (!std.mem.eql(u8, object_name, "Array")) return false;
                const method = self.resolveAtomName(callee.property) orelse return false;
                if (!std.mem.eql(u8, method, "isArray")) return false;
                const arg = self.ir_view.getListIndex(call.args_start, 0);
                return self.operandNamesParam(arg, param);
            },
            // `typeof x === "..."`, `x === undefined`, `x.kind === "..."`, and
            // the `!==` form of each.
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return false;
                if (bin.op != .strict_eq and bin.op != .strict_neq) return false;
                const left_names = self.operandNamesParam(bin.left, param);
                const right_names = self.operandNamesParam(bin.right, param);
                if (left_names == right_names) return false;
                const other = if (left_names) bin.right else bin.left;
                return self.isComparableLiteral(other);
            },
            // exhaustive: every other expression form is outside the closed
            // narrowing list, so it cannot be part of a verified predicate.
            else => return false,
        }
    }

    /// True when the expression is the named parameter, `typeof` of it, or a
    /// property read off it - the three ways an admitted test mentions its
    /// subject.
    fn operandNamesParam(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        const target: NodeIndex = switch (tag) {
            .identifier => node,
            .member_access => blk: {
                const member = self.ir_view.getMember(node) orelse return false;
                break :blk member.object;
            },
            .unary_op => blk: {
                const un = self.ir_view.getUnary(node) orelse return false;
                if (un.op != .typeof_op) return false;
                break :blk un.operand;
            },
            // exhaustive: nothing else denotes the parameter directly.
            else => return false,
        };
        if (self.ir_view.getTag(target) != .identifier) return false;
        const binding = self.ir_view.getBinding(target) orelse return false;
        return bindingKey(binding) == bindingKey(param);
    }

    fn isComparableLiteral(self: *const TypeChecker, node: NodeIndex) bool {
        return switch (self.ir_view.getTag(node) orelse return false) {
            .lit_string, .lit_int, .lit_bool, .lit_undefined => true,
            // exhaustive: an admitted test compares against a literal or the
            // absent-value sentinel. Anything else is a value the compiler
            // cannot enumerate, so the comparison proves nothing.
            else => false,
        };
    }

    /// The predicate a call installs, when the callee is an admitted one and
    /// the narrowed argument is a plain identifier.
    fn extractTypePredicateGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;
        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const fn_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!self.admitted_predicates.contains(fn_name)) return null;

        const sig = self.env.getSourceFnSigByName(fn_name) orelse return null;
        const predicate = sig.type_predicate orelse return null;
        if (predicate.param_index >= call.args_count) return null;

        const arg = self.ir_view.getListIndex(call.args_start, predicate.param_index);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);

        // The else branch keeps whatever the narrowed type does not cover, and
        // only a union says what that is.
        const current = self.currentBindingType(binding) orelse null_type_idx;
        const else_type = if (self.env.pool.getTag(current) == .t_union)
            self.env.pool.excludeUnionMember(self.allocator, current, predicate.narrowed)
        else
            null_type_idx;

        return .{
            .key = key,
            .narrowed_type = predicate.narrowed,
            .negated = false,
            .else_type = else_type,
        };
    }

    /// `if (Array.isArray(x))`. Narrows to the union members that are arrays or
    /// tuples; when no member is, the guard is not installed rather than
    /// narrowing to `never`.
    fn extractIsArrayGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .member_access) return null;

        const callee = self.ir_view.getMember(call.callee) orelse return null;
        if (self.ir_view.getTag(callee.object) != .identifier) return null;
        const object_binding = self.ir_view.getBinding(callee.object) orelse return null;
        const object_name = self.resolveAtomName(object_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, object_name, "Array")) return null;
        // A shadowed `Array` is a different value. A declared binding has a
        // tracked type; the global does not.
        if (self.binding_types.get(bindingKey(object_binding)) != null) return null;
        const method = self.resolveAtomName(callee.property) orelse return null;
        if (!std.mem.eql(u8, method, "isArray")) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_array, .t_tuple => return .{ .key = key, .narrowed_type = current, .negated = false },
            .t_union => {
                // Heap, for the same reason as the other two guards.
                var arrays: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer arrays.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    const is_array = switch (pool.getTag(candidate) orelse continue) {
                        .t_array, .t_tuple => true,
                        else => false,
                    };
                    if (is_array) {
                        arrays.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (arrays.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, arrays.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: `Array.isArray` can only narrow a type that has an array
            // somewhere in it. A record, a primitive, or a function is never an
            // array, so the honest answer is no guard rather than a narrowing to
            // `never` that would make the branch unreachable by construction.
            else => return null,
        }
    }

    /// `isDict(x)` - the intrinsic guard spec 5.7 names, narrowing a union to
    /// its Dict members. It is a global call rather than a method call, which
    /// is the only shape difference from `Array.isArray`; the narrowing it
    /// installs is the same partition.
    fn extractIsDictGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;

        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const callee_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, callee_name, "isDict")) return null;
        // A shadowed `isDict` is a different function, and a declared binding
        // has a tracked type where the intrinsic does not.
        if (self.binding_types.get(bindingKey(callee_binding)) != null) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_dict => return .{ .key = key, .narrowed_type = current, .negated = false },
            // A guard over `unknown` refines it, which is what an intrinsic
            // type guard is for: after `isDict(x)` is true, `x` is a Dict. The
            // union case below partitions members; there are none here, and
            // answering "no guard" would leave the value unusable at exactly
            // the site the guard was written for - a parsed JSON document.
            .t_unknown_type => return .{
                .key = key,
                .narrowed_type = pool.addDict(self.allocator, pool.idx_unknown, pool.idx_unknown),
                .negated = false,
            },
            .t_union => {
                var dicts: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer dicts.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    if (pool.getTag(candidate) == .t_dict) {
                        dicts.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (dicts.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, dicts.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: same reasoning as the array guard - a type with no
            // Dict in it narrows to nothing, and answering `never` would make
            // the guarded branch unreachable by construction.
            else => return null,
        }
    }

    /// `isBytes(x)` - the intrinsic guard for `Bytes` (spec 6.3). Same shape
    /// as `isDict`: a global call, partitioning a union and refining `unknown`.
    ///
    /// The `unknown` case is not a convenience. A `Result`-returning export
    /// types its payload as `unknown`, so the guard is written at exactly the
    /// site where a member-less union would leave the value unusable - a body
    /// read off a request, or a decoded payload.
    fn extractIsBytesGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;

        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const callee_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, callee_name, "isBytes")) return null;
        // A shadowed `isBytes` is a different function, and a declared binding
        // has a tracked type where the intrinsic does not.
        if (self.binding_types.get(bindingKey(callee_binding)) != null) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_bytes => return .{ .key = key, .narrowed_type = current, .negated = false },
            .t_unknown_type => return .{
                .key = key,
                .narrowed_type = pool.idx_bytes,
                .negated = false,
            },
            .t_union => {
                var matched: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer matched.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    if (pool.getTag(candidate) == .t_bytes) {
                        matched.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (matched.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, matched.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: same reasoning as the array and Dict guards - a type
            // with no Bytes in it narrows to nothing, and answering `never`
            // would make the guarded branch unreachable by construction.
            else => return null,
        }
    }

    const NullableBinding = struct { key: u64, inner: TypeIndex };

    /// Which absent value a guard removes. Spec 5.3 keeps `null` and
    /// `undefined` distinct, so a test against one of them says nothing about
    /// the other: over `string | null | undefined`, `v !== undefined` leaves
    /// `string | null` and not `string`. `.either` is for truthiness, which is
    /// the one test that excludes both.
    const AbsentKind = enum {
        undefined_only,
        null_only,
        either,

        fn removes(self: AbsentKind, tag: type_pool_mod.TypeTag) bool {
            return switch (self) {
                .undefined_only => tag == .t_undefined,
                .null_only => tag == .t_null,
                .either => tag == .t_undefined or tag == .t_null,
            };
        }
    };

    /// If `ident_node` is an identifier bound to a type that may be absent in
    /// the way `kind` names, return its binding key and the type left after
    /// that absence is removed.
    fn resolveAbsentBinding(self: *const TypeChecker, ident_node: NodeIndex, kind: AbsentKind) ?NullableBinding {
        const binding = self.ir_view.getBinding(ident_node) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;
        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            // `t_nullable` is `T | undefined`. It carries no `null`, so a
            // `null` test over it removes nothing and installs no guard.
            .t_nullable => {
                if (kind == .null_only) return null;
                return .{ .key = key, .inner = pool.getNullableInner(current) };
            },
            // `string | undefined` written out is the same type as `string?`
            // and narrows the same way. Only the `t_nullable` spelling was
            // recognized, so every author who wrote the union form got no
            // narrowing at all - including from `if (v === undefined) return;`,
            // the most common guard in the corpus.
            .t_union => {
                // On the heap, not a sixteen-slot scratch buffer. `addUnion`
                // dropped its own cap because a schema enum is routinely wider,
                // so bailing out here left exactly those unions unnarrowable:
                // `if (m === undefined) return;` over a seventeen-member enum
                // installed nothing and the value stayed nullable afterwards.
                const members = pool.getUnionMembers(current);
                var kept: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer kept.deinit(self.allocator);
                var saw_absent = false;
                for (members) |member| {
                    const tag = pool.getTag(member) orelse continue;
                    if (kind.removes(tag)) {
                        saw_absent = true;
                        continue;
                    }
                    kept.append(self.allocator, member) catch return null;
                }
                if (!saw_absent or kept.items.len == 0) return null;
                return .{ .key = key, .inner = pool.addUnion(self.allocator, kept.items) };
            },
            // exhaustive: only `T?` and a union carrying `undefined` or `null`
            // describe a value that may be absent. Every other tag is a type that
            // is always present, so an absence guard over it narrows nothing and
            // installing one would claim a removal that never happened.
            else => return null,
        }
    }

    /// Extract a discriminated union narrowing guard from x.prop === <literal>.
    /// Returns the matched union member for the then-branch. The caller handles
    /// else-branch narrowing via the negated flag.
    fn extractDiscriminantGuard(
        self: *const TypeChecker,
        member_node: NodeIndex,
        literal_node: NodeIndex,
        op: @import("zts-engine").parser.ir.BinaryOp,
    ) ?NarrowingGuard {
        const member = self.ir_view.getMember(member_node) orelse return null;
        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;
        if (self.env.pool.getTag(current) != .t_union) return null;

        const prop_name = self.resolveAtomName(member.property) orelse return null;
        const literal_type = self.inferType(literal_node);
        const literal_tag = self.env.pool.getTag(literal_type) orelse return null;
        if (literal_tag != .t_literal_string and literal_tag != .t_literal_number and literal_tag != .t_literal_bool) return null;

        const matched = blk: {
            for (self.env.pool.getUnionMembers(current)) |member_type| {
                const field = self.env.pool.lookupRecordField(member_type, prop_name) orelse continue;
                if (self.env.isAssignableTo(field.type_idx, literal_type) and
                    self.env.isAssignableTo(literal_type, field.type_idx))
                {
                    break :blk member_type;
                }
            }
            break :blk null_type_idx;
        };
        if (matched == null_type_idx) return null;

        if (op == .strict_eq) {
            // x.prop === "literal": then-branch narrows to matched member,
            // else_type is the union with matched excluded (for after early return)
            const excluded = self.env.pool.excludeUnionMember(self.allocator, current, matched);
            return .{
                .key = key,
                .narrowed_type = matched,
                .negated = false,
                .else_type = excluded,
            };
        } else {
            // x.prop !== "literal": narrow to union excluding the matched member
            const excluded = self.env.pool.excludeUnionMember(self.allocator, current, matched);
            if (excluded == null_type_idx) return null;
            return .{
                .key = key,
                .narrowed_type = excluded,
                .negated = false,
                .else_type = matched,
            };
        }
    }

    /// Check if a branch unconditionally returns (simple check for early-return pattern).
    fn branchAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag == .return_stmt) return true;
        if (tag == .block) {
            const block = self.ir_view.getBlock(node) orelse return false;
            if (block.stmts_count == 0) return false;
            // Check the last statement
            const last = self.ir_view.getListIndex(block.stmts_start, @intCast(block.stmts_count - 1));
            return self.branchAlwaysReturns(last);
        }
        return false;
    }

    fn inferBinaryType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const bin = self.ir_view.getBinary(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (bin.op) {
            // Loose equality belongs only to the comptime expression profile.
            // Fail closed if such an IR node reaches normal type analysis.
            .loose_eq, .loose_neq => null_type_idx,
            .strict_eq, .strict_neq, .lt, .lte, .gt, .gte, .in_op => pool.idx_boolean,
            .and_op, .or_op => {
                const lt = self.inferType(bin.left);
                const rt = self.inferType(bin.right);
                if (lt == null_type_idx or rt == null_type_idx) return null_type_idx;
                return pool.addUnion(self.allocator, &.{ lt, rt });
            },
            .sub, .mul, .div, .mod, .pow => pool.idx_number,
            .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => pool.idx_number,
            .add => {
                const lt = pool.widenLiteral(self.inferType(bin.left));
                const rt = pool.widenLiteral(self.inferType(bin.right));
                if (lt == pool.idx_string or rt == pool.idx_string) return pool.idx_string;
                if (lt == pool.idx_number and rt == pool.idx_number) return pool.idx_number;
                return null_type_idx;
            },
            .nullish => {
                const lt = self.inferType(bin.left);
                const rt = self.inferType(bin.right);
                const lt_tag = pool.getTag(lt);
                if (lt_tag == .t_nullable) {
                    const inner = pool.getNullableInner(lt);
                    if (rt == null_type_idx) return null_type_idx;
                    return pool.addUnion(self.allocator, &.{ inner, rt });
                }
                if (lt_tag == .t_undefined) return rt;
                if (lt != null_type_idx) return lt; // non-nullable ?? anything -> left
                return null_type_idx;
            },
        };
    }

    fn inferUnaryType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const un = self.ir_view.getUnary(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (un.op) {
            .not => pool.idx_boolean,
            .neg, .pos, .bit_not => pool.idx_number,
            .typeof_op => pool.idx_string,
            .void_op => pool.idx_undefined,
        };
    }

    fn inferObjectLiteralType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const obj = self.ir_view.getObject(node) orelse return null_type_idx;
        if (obj.properties_count == 0) return null_type_idx;

        var fields_buf: std.ArrayListUnmanaged(type_pool_mod.RecordField) = .empty;
        defer fields_buf.deinit(self.allocator);

        for (0..obj.properties_count) |i| {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
            // A spread element carries its operand where a property carries its
            // key, so reading it as a property named the operand `base` a field
            // and dropped every field `base` actually had. Its fields belong
            // here, in source order: a later key of the same name overrides an
            // earlier one, which is what `addRecord` does with duplicates.
            if (self.ir_view.getTag(prop_idx) == .object_spread) {
                const operand = self.ir_view.getOptValue(prop_idx) orelse continue;
                const spread_type = self.inferType(operand);
                for (self.env.pool.getRecordFields(spread_type)) |field| {
                    fields_buf.append(self.allocator, field) catch {
                        @constCast(self).markAllocationFailure();
                        return null_type_idx;
                    };
                }
                continue;
            }
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            // The key is a node index (identifier, string, or computed); extract atom from it
            const key_tag = self.ir_view.getTag(prop.key) orelse continue;
            const prop_name = if (key_tag == .identifier)
                (if (self.ir_view.getBinding(prop.key)) |b| self.resolveAtomName(b.name_atom) else null)
            else if (key_tag == .lit_string)
                (if (self.ir_view.getStringIdx(prop.key)) |si| self.ir_view.getString(si) else null)
            else
                null;
            const prop_name_str = prop_name orelse continue;
            const val_type = self.inferType(prop.value);
            const n = self.env.pool.addName(self.allocator, prop_name_str);
            fields_buf.append(self.allocator, .{
                .name_start = n.start,
                .name_len = n.len,
                .type_idx = val_type,
                .optional = false,
            }) catch {
                @constCast(self).markAllocationFailure();
                return null_type_idx;
            };
        }

        if (fields_buf.items.len == 0) return null_type_idx;
        return self.env.pool.addRecord(self.allocator, fields_buf.items);
    }

    fn inferArrayLiteralType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const arr = self.ir_view.getArray(node) orelse return null_type_idx;
        if (arr.elements_count == 0) return null_type_idx;

        var element_types: [32]TypeIndex = undefined;
        var count: usize = 0;
        var truncated = false;

        for (0..arr.elements_count) |i| {
            // For arrays larger than the buffer, infer the element type from the
            // first 32 elements rather than discarding the whole type as unknown.
            if (count >= element_types.len) {
                truncated = true;
                break;
            }
            const elem_idx = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
            const elem_type = self.inferType(elem_idx);
            if (elem_type == null_type_idx) return null_type_idx;
            element_types[count] = elem_type;
            count += 1;
        }

        const first = element_types[0];
        var homogeneous = true;
        for (element_types[1..count]) |elem_type| {
            if (elem_type != first) {
                homogeneous = false;
                break;
            }
        }

        if (homogeneous) {
            return self.env.pool.addArray(self.allocator, first);
        }
        // A truncated array must not be described as a fixed-length tuple of the
        // first 32 elements (that would understate the real length). Widen to a
        // homogeneous array over the seen element types instead.
        if (truncated) {
            return self.env.pool.addArray(self.allocator, self.env.pool.addUnion(self.allocator, element_types[0..count]));
        }
        return self.env.pool.addTuple(self.allocator, element_types[0..count]);
    }

    fn functionsCompatible(self: *const TypeChecker, field_type: TypeIndex, first_info: anytype) bool {
        if (self.env.pool.getTag(field_type) != .t_function) return false;
        const info = self.env.pool.getFunctionInfo(field_type);
        if (info.params.len != first_info.params.len) return false;
        for (info.params, first_info.params) |param, first_param| {
            if (param.type_idx != first_param.type_idx) return false;
        }
        return info.ret == first_info.ret;
    }

    fn inferMemberAccessType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const member = self.ir_view.getMember(node) orelse return null_type_idx;
        const raw_obj_type = self.inferType(member.object);
        if (raw_obj_type == null_type_idx) return null_type_idx;

        // Unwrap nominal types for member access (operations work on the base type)
        const obj_type = self.env.pool.unwrapNominal(raw_obj_type);

        const prop_name = self.resolveAtomName(member.property) orelse return null_type_idx;

        const tag = self.env.pool.getTag(obj_type) orelse return null_type_idx;
        if (tag == .t_record) {
            if (self.env.pool.lookupRecordField(obj_type, prop_name)) |field| {
                return field.type_idx;
            }
            @constCast(self).addDiagnostic(.{
                .severity = .err,
                .kind = .missing_field,
                .node = node,
                .message = "property does not exist on type",
                .help = null,
            });
            return null_type_idx;
        }

        if (tag == .t_union) {
            var field_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            var count: usize = 0;
            for (self.env.pool.getUnionMembers(obj_type)) |member_type| {
                const field = self.env.pool.lookupRecordField(member_type, prop_name) orelse return null_type_idx;
                if (count >= field_types.len) return null_type_idx;
                field_types[count] = field.type_idx;
                count += 1;
            }
            if (count == 0) return null_type_idx;
            if (count == 1) return field_types[0];

            const first_tag = self.env.pool.getTag(field_types[0]) orelse return null_type_idx;
            if (first_tag == .t_function) {
                const first_info = self.env.pool.getFunctionInfo(field_types[0]);
                for (field_types[1..count]) |field_type| {
                    if (!self.functionsCompatible(field_type, first_info)) {
                        @constCast(self).addDiagnostic(.{
                            .severity = .err,
                            .kind = .type_mismatch,
                            .node = node,
                            .message = "must narrow union before calling this member",
                            .help = null,
                        });
                        return null_type_idx;
                    }
                }
                return field_types[0];
            }

            return self.env.pool.addUnion(self.allocator, field_types[0..count]);
        }

        // Array (and tuple-typed array literal) receivers. A heterogeneous literal
        // like `[10, 2, 1]` infers as a tuple, so widen it back to a `T[]` result.
        if (tag == .t_array) {
            return self.inferArrayMethodType(obj_type, prop_name);
        }
        if (tag == .t_tuple) {
            return self.inferArrayMethodType(self.tupleToArrayType(obj_type), prop_name);
        }

        return null_type_idx;
    }

    /// Widen a tuple type into a `T[]` whose element is the union of its (widened)
    /// element types. Used so array-method modelling works on array-literal receivers.
    fn tupleToArrayType(self: *const TypeChecker, tuple_type: TypeIndex) TypeIndex {
        const elements = self.env.pool.getTupleElements(tuple_type);
        if (elements.len == 0) return self.env.pool.addArray(self.allocator, self.env.pool.idx_unknown);
        var widened: [32]TypeIndex = undefined;
        var count: usize = 0;
        for (elements) |elem| {
            if (count >= widened.len) break;
            const w = self.env.pool.widenLiteral(elem);
            var seen = false;
            for (widened[0..count]) |existing| {
                if (existing == w) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                widened[count] = w;
                count += 1;
            }
        }
        const element_type = if (count == 1) widened[0] else self.env.pool.addUnion(self.allocator, widened[0..count]);
        return self.env.pool.addArray(self.allocator, element_type);
    }

    /// Model the subset of Array.prototype methods that preserve the element type.
    /// `toSorted(compareFn?)` and `toReversed()` both return a fresh `T[]`. Without
    /// this, member access on an array receiver infers `null_type_idx`, leaving the
    /// call's return type unknown and (for `toSorted`) risking a spurious argument
    /// diagnostic against an unmodelled signature. The comparator parameter is typed
    /// `unknown` and optional so any callback is accepted.
    fn inferArrayMethodType(self: *const TypeChecker, array_type: TypeIndex, prop_name: []const u8) TypeIndex {
        if (std.mem.eql(u8, prop_name, "toSorted")) {
            const params = [_]type_pool_mod.FuncParam{.{
                .name_start = 0,
                .name_len = 0,
                .type_idx = self.env.pool.idx_unknown,
                .optional = true,
            }};
            return self.env.pool.addFunction(self.allocator, &params, array_type);
        }
        if (std.mem.eql(u8, prop_name, "toReversed")) {
            return self.env.pool.addFunction(self.allocator, &.{}, array_type);
        }
        return null_type_idx;
    }

    fn inferFunctionReturnType(self: *const TypeChecker, callee_type: TypeIndex) TypeIndex {
        const tag = self.env.pool.getTag(callee_type) orelse return null_type_idx;
        if (tag == .t_function) {
            return self.env.pool.getFunctionInfo(callee_type).ret;
        }
        if (tag == .t_union) {
            var return_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            var count: usize = 0;
            for (self.env.pool.getUnionMembers(callee_type)) |member_type| {
                if (self.env.pool.getTag(member_type) != .t_function) return null_type_idx;
                if (count >= return_types.len) return null_type_idx;
                return_types[count] = self.env.pool.getFunctionInfo(member_type).ret;
                count += 1;
            }
            if (count == 0) return null_type_idx;
            if (count == 1) return return_types[0];
            return self.env.pool.addUnion(self.allocator, return_types[0..count]);
        }
        return null_type_idx;
    }

    /// The `Response` type when `call` is one of the four constructors on the
    /// `Response` global, otherwise `null_type_idx`.
    ///
    /// `Response` is a global with no binding to hang a type on, so the object
    /// side of `Response.json(...)` infers nothing and the member read after it
    /// infers nothing either. Matching the name is how the checker reaches the
    /// only thing that constructs a response. A shadowed `Response` is a
    /// different value and is left alone, the same way `Array.isArray` is.
    fn inferResponseConstructorType(self: *const TypeChecker, call: Node.CallExpr) TypeIndex {
        const callee = self.ir_view.getMember(call.callee) orelse return null_type_idx;
        if (self.ir_view.getTag(callee.object) != .identifier) return null_type_idx;
        const object_binding = self.ir_view.getBinding(callee.object) orelse return null_type_idx;
        const object_name = self.resolveAtomName(object_binding.name_atom) orelse return null_type_idx;
        if (!std.mem.eql(u8, object_name, abi_types.RESPONSE_TYPE_NAME)) return null_type_idx;
        if (self.binding_types.get(bindingKey(object_binding)) != null) return null_type_idx;
        const method = self.resolveAtomName(callee.property) orelse return null_type_idx;
        if (!abi_types.isResponseConstructor(method)) return null_type_idx;
        return abi_types.responseType(self.env);
    }

    fn inferCallType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const call = self.ir_view.getCall(node) orelse return null_type_idx;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null_type_idx;

        if (callee_tag == .member_access) {
            const constructed = self.inferResponseConstructorType(call);
            if (constructed != null_type_idx) return constructed;
            return self.inferFunctionReturnType(self.inferType(call.callee));
        }
        if (callee_tag != .identifier) return null_type_idx;

        const binding = self.ir_view.getBinding(call.callee) orelse return null_type_idx;
        if (self.boundCallableMetadata(binding)) |metadata| {
            return switch (metadata) {
                .unavailable => null_type_idx,
                .signature => |sig| self.instantiatedReturnType(node, sig, call),
            };
        }
        const name = self.resolveAtomName(binding.name_atom) orelse return null_type_idx;
        // `hole()` types as `never`, the bottom type, so it is assignable to
        // whatever the surrounding context expects and the rest of the program
        // keeps checking. Inferring `unknown` instead would make every hole a
        // second diagnostic on top of the one that says the hole is there.
        if (std.mem.eql(u8, name, "hole")) return self.env.pool.idx_never;
        if (std.mem.eql(u8, name, "serviceCall")) {
            const service_call_type = self.inferServiceCallType(call);
            if (service_call_type != null_type_idx) return service_call_type;
        }
        if (std.mem.eql(u8, name, "validateJson") or
            std.mem.eql(u8, name, "validateObject") or
            std.mem.eql(u8, name, "coerceJson") or
            std.mem.eql(u8, name, "decodeJson") or
            std.mem.eql(u8, name, "decodeForm") or
            std.mem.eql(u8, name, "decodeQuery"))
        {
            if (call.args_count > 0) {
                const schema_node = self.ir_view.getListIndex(call.args_start, 0);
                if (self.getLiteralString(schema_node)) |schema_name| {
                    if (self.schemaTypeByName(schema_name)) |schema_type| {
                        return self.typedResultType(schema_type);
                    }
                }
            }
        }
        // Check if this is a nominal type constructor: UserId("str")
        if (self.env.getTypeAlias(name)) |alias_type| {
            if (self.env.pool.isNominal(alias_type)) {
                return alias_type;
            }
        }
        const sig = self.env.getFnSigByName(name) orelse return null_type_idx;
        return self.instantiatedReturnType(node, sig, call);
    }

    /// The return type of one call to `sig`, with this call's type arguments
    /// substituted. A signature that declares no type parameters, and a call
    /// whose parameters could not all be bound, return the declared type
    /// unchanged - the refusal is reported by `checkCallArgs`, and inferring
    /// `unknown` here would turn one diagnostic into a cascade.
    fn instantiatedReturnType(
        self: *const TypeChecker,
        node: NodeIndex,
        sig: type_env_mod.FunctionSig,
        call: Node.CallExpr,
    ) TypeIndex {
        if (sig.type_param_count == 0) return sig.return_type;
        return self.substitute(self.instantiateSignature(node, sig, call), sig.return_type);
    }

    fn inferMatchType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const me = self.ir_view.getMatchExpr(node) orelse return null_type_idx;
        if (me.arms_count == 0) return null_type_idx;

        var result: TypeIndex = null_type_idx;
        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
            const arm_type = self.inferType(arm.body);
            if (result == null_type_idx) {
                result = arm_type;
            } else if (arm_type != null_type_idx and arm_type != result) {
                // Different arm types - create union
                result = self.env.pool.addUnion(self.allocator, &.{ result, arm_type });
            }
        }
        return result;
    }

    // -------------------------------------------------------------------
    // Match expression narrowing
    // -------------------------------------------------------------------

    fn bindVarDeclaration(self: *TypeChecker, binding: ir.BindingRef) TypeIndex {
        const name = self.resolveAtomName(binding.name_atom) orelse {
            self.pushActiveDeclared(binding.name_atom, null_type_idx);
            return null_type_idx;
        };

        const gop = self.var_name_ordinals.getOrPut(self.allocator, binding.name_atom) catch {
            self.markAllocationFailure();
            return null_type_idx;
        };
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const ordinal = gop.value_ptr.*;
        gop.value_ptr.* += 1;

        const declared = self.env.getVarTypeByNameOrdinal(name, ordinal) orelse null_type_idx;
        if (declared != null_type_idx) {
            self.env.bindVarType(binding.scope_id, binding.name_atom, declared) catch self.markAllocationFailure();
            self.bound_var_annotations += 1;
        }
        self.pushActiveDeclared(binding.name_atom, declared);
        return declared;
    }

    fn pushActiveDeclared(self: *TypeChecker, name_atom: u16, type_idx: TypeIndex) void {
        self.active_declared_types.append(self.allocator, .{
            .name_atom = name_atom,
            .type_idx = type_idx,
        }) catch self.markAllocationFailure();
    }

    fn bindCallableMetadata(self: *TypeChecker, binding: ir.BindingRef, metadata: CallableMetadata) void {
        const key = bindingKey(binding);
        self.binding_callables.put(self.allocator, key, metadata) catch {
            self.markAllocationFailure();
            return;
        };

        var i = self.active_declared_types.items.len;
        while (i > 0) {
            i -= 1;
            if (self.active_declared_types.items[i].name_atom == binding.name_atom) {
                self.active_declared_types.items[i].callable = metadata;
                return;
            }
        }
    }

    fn boundCallableMetadata(self: *const TypeChecker, binding: ir.BindingRef) ?CallableMetadata {
        if (binding.kind == .upvalue) {
            var i = self.active_declared_types.items.len;
            while (i > 0) {
                i -= 1;
                const active = self.active_declared_types.items[i];
                if (active.name_atom == binding.name_atom) return active.callable;
            }
            return null;
        }

        const key = bindingKey(binding);
        return self.binding_callables.get(key);
    }

    fn callableSignatureForBinding(self: *const TypeChecker, binding: ir.BindingRef) ?type_env_mod.FunctionSig {
        if (self.boundCallableMetadata(binding)) |metadata| {
            return switch (metadata) {
                .unavailable => null,
                .signature => |sig| sig,
            };
        }

        const name = self.resolveAtomName(binding.name_atom) orelse return null;
        return self.env.getFnSigByName(name);
    }

    fn callableMetadataForExpression(self: *const TypeChecker, node: NodeIndex, inferred: TypeIndex) CallableMetadata {
        const tag = self.ir_view.getTag(node) orelse return .unavailable;
        return switch (tag) {
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk .unavailable;
                const sig = self.callableSignatureForBinding(binding) orelse break :blk .unavailable;
                break :blk .{ .signature = sig };
            },
            .function_expr, .arrow_function => blk: {
                const loc = self.ir_view.getLoc(node) orelse break :blk .unavailable;
                const sig = self.env.getFnSigByLoc(loc.line) orelse break :blk .unavailable;
                break :blk .{ .signature = sig };
            },
            else => self.callableMetadataFromType(inferred),
        };
    }

    fn callableMetadataFromType(self: *const TypeChecker, type_idx: TypeIndex) CallableMetadata {
        if (self.env.pool.getTag(type_idx) != .t_function) return .unavailable;
        const info = self.env.pool.getFunctionInfo(type_idx);
        if (info.params.len > 16) return .unavailable;

        var sig: type_env_mod.FunctionSig = .{};
        sig.param_count = @intCast(info.params.len);
        sig.return_type = info.ret;
        var required_param_count: u8 = 0;
        for (info.params, 0..) |param, i| {
            sig.param_types[i] = param.type_idx;
            if (!param.optional) required_param_count += 1;
        }
        sig.required_param_count = required_param_count;
        return .{ .signature = sig };
    }

    fn declaredTypeForBinding(self: *const TypeChecker, binding: ir.BindingRef) TypeIndex {
        if (self.env.getVarTypeByBinding(binding.scope_id, binding.name_atom)) |declared| {
            return declared;
        }

        if (binding.kind == .upvalue) {
            var i = self.active_declared_types.items.len;
            while (i > 0) {
                i -= 1;
                const active = self.active_declared_types.items[i];
                if (active.name_atom == binding.name_atom) return active.type_idx;
            }
            return null_type_idx;
        }

        if (binding.kind == .undeclared_global) {
            const name = self.resolveAtomName(binding.name_atom) orelse return null_type_idx;
            return self.env.getVarTypeByName(name) orelse null_type_idx;
        }
        return null_type_idx;
    }

    fn walkMatchWithNarrowing(self: *TypeChecker, me: ir.Node.MatchExpr) void {
        // Check if discriminant is an identifier with a union type
        const disc_tag = self.ir_view.getTag(me.discriminant) orelse return;
        var disc_type: TypeIndex = null_type_idx;
        const disc_key: ?u64 = if (disc_tag == .identifier) blk: {
            const binding = self.ir_view.getBinding(me.discriminant) orelse break :blk null;
            // The same fallback chain every other guard extractor uses. Reading
            // `binding_types` alone sees `const` and `let` only, so a `match`
            // over a function parameter - the shape the corpus is written in -
            // found no union and narrowed no arm.
            disc_type = self.currentBindingType(binding) orelse null_type_idx;
            break :blk bindingKey(binding);
        } else null;

        const pool = self.env.pool;
        const is_union = if (pool.getTag(disc_type)) |tag| tag == .t_union else false;

        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;

            if (is_union and disc_key != null and arm.pattern != ir.null_node) {
                const narrowed_type = self.findUnionMemberForPattern(disc_type, arm.pattern);
                if (narrowed_type != null_type_idx) {
                    const saved = self.narrowed.get(disc_key.?);
                    self.narrowed.put(self.allocator, disc_key.?, narrowed_type) catch self.markAllocationFailure();
                    self.bindPatternBindings(arm.pattern, narrowed_type);
                    self.walkExpr(arm.body);
                    if (saved) |s| {
                        self.narrowed.put(self.allocator, disc_key.?, s) catch self.markAllocationFailure();
                    } else {
                        _ = self.narrowed.remove(disc_key.?);
                    }
                    continue;
                }
            }
            // Not a narrowable union, so the arm sees the scrutinee's own type.
            // A binding still needs its field type: without one it infers
            // nothing, and a call that misuses it is checked against nothing.
            self.bindPatternBindings(arm.pattern, disc_type);
            self.walkExpr(arm.body);
        }
    }

    /// Give every field a record pattern binds the type that field has in the
    /// arm's narrowed scrutinee (spec 5.5). Without this the bound name infers
    /// nothing, and every use of it is checked against nothing - which is the
    /// fail-open shape, not a missing feature: `take(text)` with a `number`
    /// parameter and a `string` field would pass.
    fn bindPatternBindings(self: *TypeChecker, pattern: ir.NodeIndex, scrutinee: TypeIndex) void {
        if (pattern == ir.null_node or scrutinee == null_type_idx) return;
        if (self.ir_view.getTag(pattern) != .match_pattern) return;
        const record = self.ir_view.getMatchPattern(pattern) orelse return;
        const pool = self.env.pool;
        if (pool.getTag(scrutinee) != .t_record) return;

        for (0..record.props_count) |i| {
            const prop_idx = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            if (prop.value == ir.null_node) continue;
            if (self.ir_view.getTag(prop.value) != .identifier) continue;
            const binding = self.ir_view.getBinding(prop.value) orelse continue;

            const key_str_idx = self.ir_view.getStringIdx(prop.key) orelse continue;
            const key_str = self.ir_view.getString(key_str_idx) orelse continue;

            for (pool.getRecordFields(scrutinee)) |field| {
                if (!std.mem.eql(u8, pool.getName(field.name_start, field.name_len), key_str)) continue;
                self.binding_types.put(self.allocator, bindingKey(binding), field.type_idx) catch self.markAllocationFailure();
                break;
            }
        }
    }

    fn findUnionMemberForPattern(self: *const TypeChecker, union_type: TypeIndex, pattern: ir.NodeIndex) TypeIndex {
        const analysis = match_analysis_mod.MatchAnalysis.init(self.allocator, self.ir_view, self.env.pool);
        return analysis.narrowTypeForPattern(union_type, pattern);
    }

    /// Register a function's declared parameter types under their binding keys
    /// (into the dedicated `param_types` map; see its doc comment for why this
    /// stays out of general identifier inference). Entries are keyed by
    /// (scope_id, slot), which is unique per function scope, so no
    /// save/restore is needed.
    fn registerParamTypes(self: *TypeChecker, func: ir.Node.FunctionExpr, sig: type_env_mod.FunctionSig) void {
        for (0..func.params_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const binding = self.ir_view.paramBinding(param_idx) orelse continue;
            const param_type = if (i < sig.param_count) sig.param_types[i] else null_type_idx;
            self.pushActiveDeclared(binding.name_atom, param_type);
            self.bindCallableMetadata(binding, self.callableMetadataFromType(param_type));
            if (param_type == null_type_idx) continue;
            const key = bindingKey(binding);
            self.param_types.put(self.allocator, key, param_type) catch self.markAllocationFailure();
            self.env.bindVarType(binding.scope_id, binding.name_atom, param_type) catch self.markAllocationFailure();
        }
    }

    /// Check every declared parameter default against the parameter's declared
    /// type. Omission selects the default, so a default the type does not admit
    /// is a value the body would see under a type that denies it.
    fn checkParamDefaults(self: *TypeChecker, func: ir.Node.FunctionExpr, sig: type_env_mod.FunctionSig) void {
        if (!func.flags.has_default_params) return;
        for (0..func.params_count) |i| {
            if (i >= sig.param_count) return;
            const declared = sig.param_types[i];
            if (declared == null_type_idx) continue;
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const elem = self.ir_view.getPatternElem(param_idx) orelse continue;
            if (elem.default_value == null_node) continue;
            const inferred = self.inferType(elem.default_value);
            if (inferred == null_type_idx) continue;
            if (!self.env.isAssignableTo(inferred, declared)) {
                self.addTypeMismatch(elem.default_value, declared, inferred);
            }
        }
    }

    /// Declared type of an identifier that is a function parameter, or
    /// null_type_idx. Fallback for sites where the declared type is
    /// load-bearing and general inference cannot see it.
    fn paramDeclaredType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        if (tag != .identifier) return null_type_idx;
        const binding = self.ir_view.getBinding(node) orelse return null_type_idx;
        const key = bindingKey(binding);
        return self.param_types.get(key) orelse null_type_idx;
    }

    fn isMatchExhaustive(self: *const TypeChecker, me: ir.Node.MatchExpr) bool {
        // A catch-all arm makes the match exhaustive by construction, regardless
        // of whether the discriminant type resolves.
        if (match_analysis_mod.hasDefaultArm(self.ir_view, me)) return true;
        // General inference does not resolve a plain parameter reference; fall
        // back to the declared parameter type so a full-variant
        // `match (param)` without a default is recognized as exhaustive.
        var disc_type = self.inferType(me.discriminant);
        if (disc_type == null_type_idx) disc_type = self.paramDeclaredType(me.discriminant);
        if (disc_type == null_type_idx) return false;
        const analysis = match_analysis_mod.MatchAnalysis.init(self.allocator, self.ir_view, self.env.pool);
        return analysis.isMatchExhaustive(disc_type, me);
    }

    // -------------------------------------------------------------------
    // Generic instantiation
    //
    // One pass, argument-driven, no return-type propagation (D1 section 4).
    // A call to a generic signature binds every type parameter here, and the
    // bindings are then substituted into the parameter types before the
    // arguments are checked and into the return type before it is inferred.
    // A parameter no argument position determines is an error, not a silent
    // widening to `unknown`.
    // -------------------------------------------------------------------

    const MAX_TYPE_PARAMS = type_env_mod.MAX_TYPE_PARAMS;

    const TypeBindings = struct {
        names: [MAX_TYPE_PARAMS][]const u8 = @splat(""),
        types: [MAX_TYPE_PARAMS]TypeIndex = @splat(null_type_idx),
        count: u8 = 0,

        fn indexOf(self: *const TypeBindings, name: []const u8) ?usize {
            for (0..self.count) |i| {
                if (std.mem.eql(u8, self.names[i], name)) return i;
            }
            return null;
        }
    };

    const Instantiation = union(enum) {
        /// The signature is monomorphic; nothing to substitute.
        none,
        ok: TypeBindings,
        arity: struct { expected: u8, got: u8 },
        ambiguous: []const u8,
        violated: struct { name: []const u8, arg: TypeIndex, constraint: TypeIndex },
    };

    /// Explicit type arguments written at this call, if any. Keyed by the byte
    /// offset of the call's `(`, which is what the stripper recorded one past
    /// the closing `>`.
    fn explicitTypeArgs(self: *const TypeChecker, node: NodeIndex) ?type_env_mod.CallTypeArgs {
        const loc = self.ir_view.getLoc(node) orelse return null;
        return self.env.getCallTypeArgs(loc.offset);
    }

    /// Bind every type parameter of `sig` for this call. Pure: it reports what
    /// it found and leaves the diagnostics to the caller, so the same answer
    /// serves both the argument check and the return-type inference.
    fn instantiateSignature(
        self: *const TypeChecker,
        node: NodeIndex,
        sig: type_env_mod.FunctionSig,
        call: Node.CallExpr,
    ) Instantiation {
        const type_params = sig.typeParams();
        if (type_params.len == 0) return .none;

        var bindings: TypeBindings = .{};
        for (type_params) |param| {
            bindings.names[bindings.count] = param.name;
            bindings.count += 1;
        }

        if (self.explicitTypeArgs(node)) |explicit| {
            // Explicit arguments skip inference entirely (D1 section 4).
            if (explicit.count != type_params.len) {
                return .{ .arity = .{ .expected = @intCast(type_params.len), .got = explicit.count } };
            }
            for (0..bindings.count) |i| bindings.types[i] = explicit.args[i];
        } else {
            var i: u8 = 0;
            while (i < sig.param_count and i < call.args_count) : (i += 1) {
                const arg_idx = self.ir_view.getListIndex(call.args_start, i);
                const arg_type = self.argumentTypeForInference(arg_idx);
                if (arg_type == null_type_idx) continue;
                self.unify(type_params, sig.param_types[i], arg_type, &bindings, 0);
            }
            for (0..bindings.count) |bi| {
                if (bindings.types[bi] == null_type_idx) return .{ .ambiguous = bindings.names[bi] };
            }
        }

        for (type_params, 0..) |param, pi| {
            if (param.constraint == null_type_idx) continue;
            const arg = bindings.types[pi];
            if (arg == null_type_idx) continue;
            if (!self.env.isAssignableTo(arg, param.constraint)) {
                return .{ .violated = .{ .name = param.name, .arg = arg, .constraint = param.constraint } };
            }
        }

        return .{ .ok = bindings };
    }

    /// The type of one call argument, for the purpose of binding type
    /// parameters.
    ///
    /// `inferType` answers `null_type_idx` for a function expression, because
    /// the rest of the checker reaches a function through its recorded
    /// signature rather than through a type. That is fine everywhere a callee
    /// is named and wrong here: a callback passed as an argument is the only
    /// evidence a signature like `run(key: string, fn: () => T): T` has for
    /// what `T` is, and skipping it leaves `T` unbound and reports the call as
    /// ambiguous. This builds the function type that argument position needs.
    fn argumentTypeForInference(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const inferred = self.inferType(node);
        if (inferred != null_type_idx) return inferred;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        if (tag != .arrow_function and tag != .function_expr) return null_type_idx;
        return self.functionExprType(node);
    }

    /// A function type for a function expression written at a call site: its
    /// declared signature when one was recorded, otherwise an empty parameter
    /// list and the type its body returns.
    ///
    /// The parameter list is left empty when nothing declared it. `unify` walks
    /// a function pattern only as far as both sides carry parameters and then
    /// unifies the return types, so an empty list costs nothing here and
    /// guessing parameter types from a body would be a second inference with no
    /// caller asking for it.
    fn functionExprType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const func = self.ir_view.getFunction(node) orelse return null_type_idx;
        const declared: ?type_env_mod.FunctionSig = if (self.ir_view.getLoc(node)) |loc|
            self.env.getFnSigByLoc(loc.line)
        else
            null;
        if (declared) |sig| {
            if (sig.return_type != null_type_idx) {
                return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, sig.return_type);
            }
        }
        const returned = self.bodyReturnType(func.body, 0);
        if (returned == null_type_idx) return null_type_idx;
        return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, returned);
    }

    /// The type a function body returns: the join of every `return` value the
    /// body reaches, or `null_type_idx` when no `return` carries a value.
    ///
    /// Nested function bodies are not entered - their `return` answers their
    /// own contract, not this one. A body whose returns disagree joins to a
    /// union, which is the same answer the checker gives a match expression
    /// whose arms disagree.
    fn bodyReturnType(self: *const TypeChecker, node: NodeIndex, depth: u8) TypeIndex {
        if (depth > 8 or node == null_node) return null_type_idx;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        switch (tag) {
            .return_stmt => {
                const value = self.ir_view.getOptValue(node) orelse return null_type_idx;
                return self.inferType(value);
            },
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return null_type_idx;
                var result: TypeIndex = null_type_idx;
                for (0..block.stmts_count) |i| {
                    const stmt = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    result = self.joinReturnType(result, self.bodyReturnType(stmt, depth + 1));
                }
                return result;
            },
            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return null_type_idx;
                const then_type = self.bodyReturnType(if_s.then_branch, depth + 1);
                const else_type = if (if_s.else_branch != null_node)
                    self.bodyReturnType(if_s.else_branch, depth + 1)
                else
                    null_type_idx;
                return self.joinReturnType(then_type, else_type);
            },
            // exhaustive: the listed statement shapes are the ones that can
            // carry a `return` for this function. Every other tag either holds
            // no statement (an expression, a declaration) or opens a nested
            // function, whose returns answer its own contract. Answering
            // nothing here is not a swallowed verdict: the caller infers no
            // type for the argument and the type parameter stays unbound, which
            // `instantiateSignature` reports as ambiguous.
            else => return null_type_idx,
        }
    }

    fn joinReturnType(self: *const TypeChecker, left: TypeIndex, right: TypeIndex) TypeIndex {
        if (left == null_type_idx) return right;
        if (right == null_type_idx or right == left) return left;
        return self.env.pool.addUnion(self.allocator, &.{ left, right });
    }

    /// The declared type parameter `pattern` names, or null when `pattern` is
    /// not a type-parameter reference. A parameter annotation reaches the pool
    /// two ways - a bare `T` resolves to the `t_generic_param` node in scope,
    /// while a `T` nested in `T[]` stays a `t_ref` the type-expression parser
    /// built - so both tags are matched by name, which is also how
    /// `TypePool.instantiate` substitutes.
    fn typeParamNameOf(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        pattern: TypeIndex,
    ) ?[]const u8 {
        const tag = self.env.pool.getTag(pattern) orelse return null;
        if (tag != .t_generic_param and tag != .t_ref) return null;
        const name = self.env.pool.getRefName(pattern);
        if (name.len == 0) return null;
        for (type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return param.name;
        }
        return null;
    }

    fn constraintFor(
        type_params: []const type_env_mod.GenericParam,
        name: []const u8,
    ) TypeIndex {
        for (type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return param.constraint;
        }
        return null_type_idx;
    }

    /// Walk a parameter type and the argument type it was given side by side,
    /// binding each type parameter the walk reaches.
    fn unify(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        pattern: TypeIndex,
        actual: TypeIndex,
        bindings: *TypeBindings,
        depth: u8,
    ) void {
        if (depth > 8) return;
        if (pattern == null_type_idx or actual == null_type_idx) return;
        const pool = self.env.pool;

        if (self.typeParamNameOf(type_params, pattern)) |name| {
            self.bindTypeParam(type_params, name, actual, bindings);
            return;
        }

        const pattern_tag = pool.getTag(pattern) orelse return;
        const actual_tag = pool.getTag(actual) orelse return;

        switch (pattern_tag) {
            .t_record => {
                if (actual_tag != .t_record) return;
                // Fields present in the pattern only: a field the argument
                // carries and the parameter does not says nothing about any
                // type parameter.
                const pattern_fields = pool.getRecordFields(pattern);
                var i: usize = 0;
                while (i < pattern_fields.len) : (i += 1) {
                    // Re-read each iteration: a nested unify can add to the
                    // pool's shared fields list and move the slice.
                    const live = pool.getRecordFields(pattern);
                    if (i >= live.len) break;
                    const field = live[i];
                    const field_name = pool.getName(field.name_start, field.name_len);
                    const actual_field = pool.lookupRecordField(actual, field_name) orelse continue;
                    self.unify(type_params, field.type_idx, actual_field.type_idx, bindings, depth + 1);
                }
            },
            .t_array => {
                const elem = pool.getArrayElement(pattern);
                if (actual_tag == .t_array) {
                    self.unify(type_params, elem, pool.getArrayElement(actual), bindings, depth + 1);
                } else if (actual_tag == .t_tuple) {
                    // `["a", "b"]` types as a tuple of literals, so `T[]` sees
                    // each element and the joins in `bindTypeParam` produce
                    // one element type for T.
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const live = pool.getTupleElements(actual);
                        if (i >= live.len) break;
                        self.unify(type_params, elem, live[i], bindings, depth + 1);
                    }
                }
            },
            .t_tuple => {
                if (actual_tag == .t_tuple) {
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const p_live = pool.getTupleElements(pattern);
                        const a_live = pool.getTupleElements(actual);
                        if (i >= p_live.len or i >= a_live.len) break;
                        self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                    }
                } else if (actual_tag == .t_array) {
                    const actual_elem = pool.getArrayElement(actual);
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const p_live = pool.getTupleElements(pattern);
                        if (i >= p_live.len) break;
                        self.unify(type_params, p_live[i], actual_elem, bindings, depth + 1);
                    }
                }
            },
            .t_function => {
                if (actual_tag != .t_function) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_info = pool.getFunctionInfo(pattern);
                    const a_info = pool.getFunctionInfo(actual);
                    if (i >= p_info.params.len or i >= a_info.params.len) break;
                    self.unify(type_params, p_info.params[i].type_idx, a_info.params[i].type_idx, bindings, depth + 1);
                }
                self.unify(
                    type_params,
                    pool.getFunctionInfo(pattern).ret,
                    pool.getFunctionInfo(actual).ret,
                    bindings,
                    depth + 1,
                );
            },
            .t_nullable => {
                const inner = pool.getNullableInner(pattern);
                const actual_inner = if (actual_tag == .t_nullable) pool.getNullableInner(actual) else actual;
                self.unify(type_params, inner, actual_inner, bindings, depth + 1);
            },
            .t_union => {
                // D1 section 4: a union pattern with exactly one type-parameter
                // member binds it to the whole argument. `x: T | undefined`
                // given `string | undefined` binds T to `string | undefined`,
                // which is what the declaration asked about.
                var generic_member: ?[]const u8 = null;
                var generic_count: usize = 0;
                const members = pool.getUnionMembers(pattern);
                for (members) |member| {
                    if (self.typeParamNameOf(type_params, member)) |name| {
                        generic_member = name;
                        generic_count += 1;
                    }
                }
                if (generic_count == 1) {
                    self.bindTypeParam(type_params, generic_member.?, actual, bindings);
                    return;
                }
                if (actual_tag != .t_union) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getUnionMembers(pattern);
                    const a_live = pool.getUnionMembers(actual);
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            .t_intersection => {
                if (actual_tag != .t_intersection) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getIntersectionMembers(pattern);
                    const a_live = pool.getIntersectionMembers(actual);
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            .t_generic_app => {
                if (actual_tag != .t_generic_app) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getGenericAppInfo(pattern).args;
                    const a_live = pool.getGenericAppInfo(actual).args;
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            // exhaustive: every remaining tag is a leaf the walk cannot
            // decompose, so it contributes no binding. Assignability checks it
            // after substitution.
            else => {},
        }
    }

    /// Bind, or join with what a previous argument position already bound.
    fn bindTypeParam(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        name: []const u8,
        actual: TypeIndex,
        bindings: *TypeBindings,
    ) void {
        const slot = bindings.indexOf(name) orelse return;
        const contribution = self.widenForBinding(constraintFor(type_params, name), actual);
        const existing = bindings.types[slot];
        bindings.types[slot] = if (existing == null_type_idx)
            contribution
        else
            self.joinTypes(existing, contribution);
    }

    /// A literal argument binds its base type, so `first(["a"])` returns
    /// `string` rather than `"a"`. The exception is a constraint the base type
    /// does not satisfy - `T extends "a" | "b"` is asking for the literal, and
    /// widening it would make every call violate its own bound.
    fn widenForBinding(self: *const TypeChecker, constraint: TypeIndex, actual: TypeIndex) TypeIndex {
        const widened = self.env.pool.widenLiteral(actual);
        if (widened == actual) return actual;
        if (constraint != null_type_idx and !self.env.isAssignableTo(widened, constraint)) {
            return actual;
        }
        return widened;
    }

    /// Substitute the bindings into a type. Returns the type unchanged when the
    /// call is not generic.
    fn substitute(self: *const TypeChecker, inst: Instantiation, idx: TypeIndex) TypeIndex {
        const bindings = switch (inst) {
            .ok => |b| b,
            // exhaustive: `.none` is a monomorphic signature and the three
            // refusals were already reported. Each has no bindings to apply,
            // so the type is returned as declared.
            else => return idx,
        };
        if (bindings.count == 0 or idx == null_type_idx) return idx;
        return self.env.pool.instantiate(
            self.env.allocator,
            idx,
            bindings.names[0..bindings.count],
            bindings.types[0..bindings.count],
            0,
        );
    }

    /// Report whatever `instantiateSignature` refused, and return the bindings
    /// when it accepted. A refusal returns `.none`, so the argument check that
    /// follows compares against the uninstantiated parameter types rather than
    /// stacking a second diagnostic on the first.
    fn reportInstantiation(self: *TypeChecker, node: NodeIndex, inst: Instantiation) Instantiation {
        switch (inst) {
            .none, .ok => return inst,
            .arity => |a| self.addGenericDiagnostic(
                .type_argument_count_mismatch,
                node,
                "wrong number of type arguments: expected {d}, got {d}",
                .{ a.expected, a.got },
                "wrong number of type arguments",
                "Give one type argument for each declared type parameter.",
            ),
            .ambiguous => |name| self.addGenericDiagnostic(
                .ambiguous_type_argument,
                node,
                "no argument determines type parameter '{s}'",
                .{name},
                "a type parameter is not determined by any argument",
                "Name the type argument at the call site.",
            ),
            .violated => |v| {
                var arg_buf: [128]u8 = undefined;
                var constraint_buf: [128]u8 = undefined;
                self.addGenericDiagnostic(
                    .type_constraint_violation,
                    node,
                    "type argument {s} for '{s}' does not satisfy constraint {s}",
                    .{
                        self.env.pool.formatType(v.arg, &arg_buf),
                        v.name,
                        self.env.pool.formatType(v.constraint, &constraint_buf),
                    },
                    "a type argument does not satisfy its constraint",
                    null,
                );
            },
        }
        return .none;
    }

    /// Message ownership matches `addArgCountMismatch`: the formatted text is
    /// owned when it was allocated, and the static fallback never is.
    fn addGenericDiagnostic(
        self: *TypeChecker,
        kind: DiagnosticKind,
        node: NodeIndex,
        comptime fmt: []const u8,
        args: anytype,
        fallback: []const u8,
        help: ?[]const u8,
    ) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch fallback;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = kind,
            .node = node,
            .message = msg,
            .help = help,
            .allocated = msg.ptr != fallback.ptr,
        });
    }

    // -------------------------------------------------------------------
    // Call argument checking
    // -------------------------------------------------------------------

    /// The first member of `idx` that JSON cannot carry, or null when nothing
    /// in it is definitely unencodable.
    ///
    /// Spec 6.4 states the rule the other way round - admit only scalars,
    /// arrays, tuples, fixed records, and string-keyed `Dict` - and this
    /// refuses what is definitely wrong instead. The difference is `unknown`,
    /// which the strict reading rejects and which is what a `Result` payload
    /// and a parsed document both type as today. Rejecting it would refuse
    /// `Response.json(parsed.value)` in every handler that has one, so the
    /// checker takes the direction that cannot reject a true program: it
    /// reports where it knows, and stays quiet where it does not. Phase 7's
    /// cutover can tighten this once those positions carry real types.
    ///
    /// A function is the case worth catching. `valueToJsonString` throws on
    /// one, `http.zig` calls it with `try`, and the subset has no `try/catch` -
    /// so the failure that exists today has no way to be handled, which is the
    /// concrete argument for deciding it at compile time.
    fn firstUnencodable(self: *const TypeChecker, idx: TypeIndex, depth: u8) ?TypeIndex {
        if (idx == null_type_idx or depth >= 16) return null;
        const pool = self.env.pool;
        const tag = pool.getTag(idx) orelse return null;
        return switch (tag) {
            .t_function => idx,
            // A Bytes is an octet buffer, not a JSON value. Spec 6.3 keeps the
            // two apart, and `encodeBase64` is the conversion an author writes
            // when they mean to send one.
            .t_bytes => idx,
            .t_array => self.firstUnencodable(pool.getArrayElement(idx), depth + 1),
            .t_nullable => self.firstUnencodable(pool.getNullableInner(idx), depth + 1),
            .t_dict => self.firstUnencodable(pool.getDictValue(idx), depth + 1),
            .t_record => blk: {
                for (pool.getRecordFields(idx)) |field| {
                    if (self.firstUnencodable(field.type_idx, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            .t_tuple => blk: {
                for (pool.getTupleElements(idx)) |element| {
                    if (self.firstUnencodable(element, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            .t_union => blk: {
                for (pool.getUnionMembers(idx)) |member| {
                    if (self.firstUnencodable(member, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            // exhaustive: every remaining tag is a JSON scalar, a literal, a
            // name the pool did not resolve, or `unknown`. The scalars and
            // literals encode; the other two are types this walk has no
            // information about, and reporting one would refuse a program on
            // the absence of knowledge rather than on knowledge. Refusing what
            // is definitely wrong is the direction this rule takes, so an
            // unmodelled tag arriving here is admitted and reported by
            // whatever does know it.
            else => null,
        };
    }

    /// `Response.json(payload)`: refuse a payload whose type JSON cannot carry.
    ///
    /// Spec 7.2 wants `responseJson<T>` to return `Result<Response, JsonError>`
    /// so the failure is handled rather than thrown. Making the shipped global
    /// fallible rewrites the return statement of every handler in the
    /// repository, which is what phase 7's direct cutover is for. This is the
    /// half that costs no migration and closes the same hole wherever `T`
    /// decides it; the residual - the size limit, which no payload type
    /// discharges - stays a run-time fault.
    fn checkResponseJsonPayload(self: *TypeChecker, call: Node.CallExpr) void {
        const callee = self.ir_view.getMember(call.callee) orelse return;
        if (self.ir_view.getTag(callee.object) != .identifier) return;
        const object_binding = self.ir_view.getBinding(callee.object) orelse return;
        const object_name = self.resolveAtomName(object_binding.name_atom) orelse return;
        if (!std.mem.eql(u8, object_name, abi_types.RESPONSE_TYPE_NAME)) return;
        // A shadowed `Response` is a different value, the same way
        // `inferResponseConstructorType` leaves one alone.
        if (self.binding_types.get(bindingKey(object_binding)) != null) return;
        const method = self.resolveAtomName(callee.property) orelse return;
        if (!std.mem.eql(u8, method, "json")) return;
        if (call.args_count == 0) return;

        const arg_idx = self.ir_view.getListIndex(call.args_start, 0);
        self.reportIfUnencodable(arg_idx, "Response.json");
    }

    /// Report ZTS213 when the value at `arg_idx` has a type JSON cannot carry.
    /// Shared by `Response.json` and by every module export that marks an
    /// argument `json_encodable_args` - one rule at both sites, which is what
    /// makes it a rule rather than a special case.
    fn reportIfUnencodable(self: *TypeChecker, arg_idx: NodeIndex, site: []const u8) void {
        const arg_type = self.inferType(arg_idx);
        const bad = self.firstUnencodable(arg_type, 0) orelse return;

        var buf: [1024]u8 = undefined;
        const bad_str = self.env.pool.formatType(bad, &buf);
        const msg = std.fmt.allocPrint(
            self.allocator,
            "{s} cannot encode this payload: {s} is not a JSON value",
            .{ site, bad_str },
        ) catch "this payload is not JSON-encodable";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unencodable_json_payload,
            .node = arg_idx,
            .message = msg,
            .help = "JSON carries scalars, arrays, tuples, records, and string-keyed Dict values. Encode a Bytes with encodeBase64, and call a function rather than sending it.",
            .allocated = !std.mem.eql(u8, msg, "this payload is not JSON-encodable"),
        });
    }

    /// The module export a call's callee names, resolved through the import
    /// that introduced it rather than by the local spelling.
    ///
    /// A bare-name lookup was wrong in both directions. `import { send as
    /// publish }` never matched, so the export's checks were skipped under an
    /// alias; and a handler's own `function send(...)` matched, so a local
    /// function was checked against a module export's declaration. The import
    /// record carries `imported_atom` - the name in the source module - and
    /// the specifier, which together identify the export exactly.
    fn resolveImportedExport(
        self: *const TypeChecker,
        callee_binding: ir.BindingRef,
    ) ?@TypeOf(@import("zts-engine").builtin_modules.findExport("", "").?) {
        const builtin_modules = @import("zts-engine").builtin_modules;
        const node_count = self.ir_view.nodeCount();
        var idx: NodeIndex = 0;
        while (idx < node_count) : (idx += 1) {
            if (self.ir_view.getTag(idx) != .import_decl) continue;
            const decl = self.ir_view.getImportDecl(idx) orelse continue;
            const specifier = self.ir_view.getString(decl.module_idx) orelse continue;
            var i: u8 = 0;
            while (i < decl.specifiers_count) : (i += 1) {
                const spec_idx = self.ir_view.getListIndex(decl.specifiers_start, i);
                const spec = self.ir_view.getImportSpec(spec_idx) orelse continue;
                if (spec.kind != .named) continue;
                if (spec.local_binding.slot != callee_binding.slot) continue;
                if (spec.local_binding.kind != callee_binding.kind) continue;
                const imported = self.resolveAtomName(spec.imported_atom) orelse continue;
                if (builtin_modules.findExport(specifier, imported)) |entry| return entry;
            }
        }
        return null;
    }

    /// The `json_encodable_args` positions of the module export `call` names,
    /// checked with the same rule. A queue payload and a response body are
    /// serialized by the same encoder, so they answer to the same question.
    fn checkModuleEncodableArgs(self: *TypeChecker, call: Node.CallExpr) void {
        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const entry = self.resolveImportedExport(binding) orelse return;
        for (entry.func.json_encodable_args) |position| {
            if (position >= call.args_count) continue;
            const arg_idx = self.ir_view.getListIndex(call.args_start, position);
            var site_buf: [128]u8 = undefined;
            const site = std.fmt.bufPrint(&site_buf, "{s}.{s}", .{ entry.binding.specifier, entry.func.name }) catch entry.func.name;
            self.reportIfUnencodable(arg_idx, site);
        }
    }

    fn checkCallArgs(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag == .identifier) self.checkModuleEncodableArgs(call);
        if (callee_tag == .member_access) {
            self.checkResponseJsonPayload(call);
            const callee_type = self.inferType(call.callee);
            const tag = self.env.pool.getTag(callee_type) orelse return;
            if (tag == .t_function) {
                const info = self.env.pool.getFunctionInfo(callee_type);
                // Optional (trailing) params may be omitted: the arg count must fall
                // between the required-param count and the total param count.
                var required: usize = 0;
                for (info.params) |param| {
                    if (!param.optional) required += 1;
                }
                if (call.args_count < required or call.args_count > info.params.len) {
                    self.addArgCountMismatch(node, info.params.len, @intCast(call.args_count));
                    return;
                }
                for (info.params, 0..) |param, i| {
                    if (i >= call.args_count) break;
                    const arg_idx = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    const arg_type = self.inferType(arg_idx);
                    if (arg_type != null_type_idx and param.type_idx != null_type_idx and !self.env.isAssignableTo(arg_type, param.type_idx)) {
                        self.addArgTypeMismatch(arg_idx, param.type_idx, arg_type);
                    }
                }
            } else if (tag == .t_union) {
                const members = self.env.pool.getUnionMembers(callee_type);
                if (members.len == 0) return;

                var shared_param_count: ?usize = null;
                var param_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
                var param_count: usize = 0;

                for (members) |member_type| {
                    if (self.env.pool.getTag(member_type) != .t_function) return;
                    const info = self.env.pool.getFunctionInfo(member_type);
                    if (shared_param_count == null) {
                        shared_param_count = info.params.len;
                        param_count = info.params.len;
                        if (param_count > param_types.len) return;
                        for (info.params, 0..) |param, i| {
                            param_types[i] = param.type_idx;
                        }
                    } else if (shared_param_count.? != info.params.len) {
                        return;
                    } else {
                        for (info.params, 0..) |param, i| {
                            if (param_types[i] != param.type_idx) return;
                        }
                    }
                }

                if (call.args_count != param_count) {
                    self.addArgCountMismatch(node, param_count, @intCast(call.args_count));
                    return;
                }

                for (0..param_count) |i| {
                    const arg_idx = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    const arg_type = self.inferType(arg_idx);
                    if (arg_type != null_type_idx and param_types[i] != null_type_idx and !self.env.isAssignableTo(arg_type, param_types[i])) {
                        self.addArgTypeMismatch(arg_idx, param_types[i], arg_type);
                    }
                }
            }
            return;
        }
        if (callee_tag != .identifier) return;

        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const bound_metadata = self.boundCallableMetadata(binding);
        const unbound_name = if (bound_metadata == null)
            self.resolveAtomName(binding.name_atom)
        else
            null;

        if (unbound_name) |name| if (std.mem.eql(u8, name, "serviceCall")) {
            const service_context = self.service_type_context orelse return;
            if (call.args_count >= 2) {
                const service_node = self.ir_view.getListIndex(call.args_start, 0);
                const route_node = self.ir_view.getListIndex(call.args_start, 1);
                if (self.getLiteralString(service_node)) |service_name| {
                    if (self.getLiteralString(route_node)) |route_pattern| {
                        if (parseServiceRoute(route_pattern)) |parsed| {
                            if (service_context.lookupRoute(service_name, parsed.method, parsed.path)) |route| {
                                self.validateServiceCallAgainstRoute(node, call, route);
                            }
                        }
                    }
                }
            }
        };

        const sig = if (bound_metadata) |metadata|
            switch (metadata) {
                .unavailable => return,
                .signature => |signature| signature,
            }
        else
            self.env.getFnSigByName(unbound_name orelse return) orelse return;

        // Check argument count
        const required_param_count = sig.required_param_count orelse sig.param_count;
        if (call.args_count < required_param_count) {
            self.addArgCountMismatch(node, required_param_count, @intCast(call.args_count));
            return;
        }

        // Bind the type parameters before the arguments are compared, so every
        // instantiation is checked against its substituted parameter types
        // rather than against a type variable that accepts anything.
        const attempted = self.instantiateSignature(node, sig, call);
        const failed = switch (attempted) {
            .none, .ok => false,
            .arity, .ambiguous, .violated => true,
        };
        const inst = self.reportInstantiation(node, attempted);

        // A call whose type parameters could not be bound is already reported.
        // Comparing its arguments against parameter types that still contain an
        // unsubstituted `T` says nothing further about the program - under D1
        // amendment A1 a type variable is assignable to nothing, so every
        // argument of a refused call would be reported a second time for the
        // same defect. This is the cascade `instantiatedReturnType` avoids on
        // the return side.
        if (failed) return;

        // Check argument types
        var i: u8 = 0;
        while (i < sig.param_count and i < call.args_count) : (i += 1) {
            const arg_idx = self.ir_view.getListIndex(call.args_start, i);
            const arg_type = self.inferType(arg_idx);
            const param_type = self.substitute(inst, sig.param_types[i]);
            if (arg_type != null_type_idx and param_type != null_type_idx) {
                if (!self.env.isAssignableTo(arg_type, param_type)) {
                    self.addArgTypeMismatch(arg_idx, param_type, arg_type);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Diagnostic helpers
    // -------------------------------------------------------------------

    fn addDiagnostic(self: *TypeChecker, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch {
            if (diag.allocated) self.allocator.free(diag.message);
            self.markAllocationFailure();
        };
    }

    /// Report ZTS212 when a declared annotation names an alias whose cycle no
    /// data constructor guards (spec 5.7). The alias is decided once in
    /// `TypeEnv`; this is the site that gives the verdict a source location,
    /// since the declaration itself is blanked by the stripper and reaches the
    /// parser as whitespace.
    fn reportIfNonContractive(self: *TypeChecker, declared: TypeIndex, node: NodeIndex) void {
        if (declared == null_type_idx or node == null_node) return;
        if (!self.env.isNonContractiveType(declared)) return;
        const name = if (self.env.pool.getTag(declared) == .t_ref)
            self.env.pool.getRefName(declared)
        else
            self.env.nameOfNonContractive(declared) orelse "";
        if (name.len == 0) return;

        const msg = std.fmt.allocPrint(
            self.allocator,
            "recursive type alias '{s}' has a cycle no data constructor guards",
            .{name},
        ) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .non_contractive_alias,
                .node = node,
                .message = "recursive type alias has a cycle no data constructor guards",
                .help = null,
            });
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .non_contractive_alias,
            .node = node,
            .message = msg,
            .help = "route the recursion through a record, a tuple, or an array, the way `type JsonValue = ... | readonly JsonValue[]` does; a union or intersection edge does not guard it",
            .allocated = true,
        });
    }

    fn addTypeMismatch(self: *TypeChecker, node: NodeIndex, expected: TypeIndex, got: TypeIndex) void {
        var buf: [256]u8 = undefined;
        const expected_str = self.env.pool.formatType(expected, buf[0..128]);
        const got_str = self.env.pool.formatType(got, buf[128..256]);

        const msg = std.fmt.allocPrint(self.allocator, "type '{s}' is not assignable to type '{s}'", .{ got_str, expected_str }) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .type_mismatch,
                .node = node,
                .message = "type mismatch",
                .help = null,
            });
            return;
        };

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .type_mismatch,
            .node = node,
            .message = msg,
            .help = null,
            .allocated = true,
        });
    }

    /// Emit an arg-count mismatch (ZTS202) whose message names the expected and
    /// actual counts, so a caller (human or agent) can fix it without guessing.
    /// The detail rides in `.message` because `deinit` only frees `.message`
    /// when `allocated`; `.help` is never freed, so an owned string there leaks.
    fn addArgCountMismatch(self: *TypeChecker, node: NodeIndex, expected: usize, got: usize) void {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "wrong number of arguments: expected {d}, got {d}",
            .{ expected, got },
        ) catch "wrong number of arguments";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .arg_count_mismatch,
            .node = node,
            .message = msg,
            .help = null,
            .allocated = !std.mem.eql(u8, msg, "wrong number of arguments"),
        });
    }

    /// Emit an arg-type mismatch (ZTS203) whose message names the expected
    /// parameter type and the actual argument type. Same ownership rule as
    /// `addArgCountMismatch`: the detail goes in `.message`, not `.help`.
    fn addArgTypeMismatch(self: *TypeChecker, node: NodeIndex, expected: TypeIndex, got: TypeIndex) void {
        // A kilobyte a side, not 128 bytes. `formatType` answers "?" when its
        // buffer is too small, so a record with more than a couple of fields
        // printed as `expected ?, got ?` - a diagnostic that names neither
        // type, on exactly the mismatches that are hardest to read from the
        // source. Found when `FetchOptions` became a five-field record.
        var buf: [2048]u8 = undefined;
        const expected_str = self.env.pool.formatType(expected, buf[0..1024]);
        const got_str = self.env.pool.formatType(got, buf[1024..2048]);
        const msg = std.fmt.allocPrint(
            self.allocator,
            "argument type does not match parameter type: expected {s}, got {s}",
            .{ expected_str, got_str },
        ) catch "argument type does not match parameter type";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .arg_type_mismatch,
            .node = node,
            .message = msg,
            .help = null,
            .allocated = !std.mem.eql(u8, msg, "argument type does not match parameter type"),
        });
    }

    fn resolveAtomName(self: *const TypeChecker, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            const atom: object.Atom = @enumFromInt(atom_idx);
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @enumFromInt(atom_idx);
        return atom.toPredefinedName();
    }

    fn markAllocationFailure(self: *TypeChecker) void {
        self.allocation_failed = true;
    }
};

/// Binding identity for this checker's flow maps.
///
/// `bool_checker.packBindingKey` folds only (scope, slot), and a captured
/// upvalue shares both with a parameter of the capturing function: the upvalue
/// indexes the closure's upvalue array, the parameter indexes its own argument
/// array, and both start at zero in the same function scope. A narrowing
/// installed for the captured binding therefore landed on the inner function's
/// own parameter, so `if (v === undefined) return 0;` over a captured `v` made
/// `return n` read `string` and reported a return-type mismatch on correct
/// code. Folding the kind in separates them.
fn bindingKey(binding: ir.BindingRef) u64 {
    return (@as(u64, binding.scope_id) << 32) |
        (@as(u64, @intFromEnum(binding.kind)) << 16) |
        @as(u64, binding.slot);
}

const writeJsonString = json_utils.writeJsonString;

test "TypeChecker fails closed when binding analysis cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "let count = 1;");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = TypeChecker.init(failing.allocator(), view, null, &env, null);
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

test "TypeChecker fails closed when diagnostic storage cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = TypeChecker.init(failing.allocator(), view, null, &env, null);
    defer checker.deinit();
    checker.addDiagnostic(.{
        .severity = .err,
        .kind = .type_mismatch,
        .node = root,
        .message = "forced diagnostic",
        .help = null,
    });
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

test "TypeChecker ensureHealthy rejects a TypePool poisoned after check" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var checker = TypeChecker.init(allocator, view, null, &env, null);
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));

    const record = pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = pool.idx_string,
        .optional = false,
    }});
    try pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = pool.makeReadonly(failing.allocator(), record);

    try std.testing.expectError(error.OutOfMemory, checker.ensureHealthy());
}

test "TypeChecker ensureHealthy propagates TypePool capacity exhaustion" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var checker = TypeChecker.init(allocator, view, null, &env, null);
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));
    try pool.fields.resize(allocator, @as(usize, std.math.maxInt(u16)) + 1);
    _ = pool.addRecord(allocator, &.{});

    try std.testing.expectError(error.TypePoolCapacityExceeded, checker.ensureHealthy());
}

fn checkTypedSource(source: []const u8, expect_errors: u32, expect_warnings: ?u32) !void {
    try checkTypedSourceWithServiceContext(source, null, expect_errors, expect_warnings);
}

/// `checkTypedSource` plus the text of the diagnostic it expects. A count alone
/// is satisfied by any error at all, including one from a different rule, so a
/// test that means to pin a particular refusal names it.
fn checkTypedSourceSaying(source: []const u8, expect_errors: u32, needle: []const u8) !void {
    const allocator = std.testing.allocator;

    var strip_result = try @import("zts-engine").stripper.strip(allocator, source, .{});
    defer strip_result.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, strip_result.code);
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateFromTypeMap(&strip_result.type_map);

    var checker = TypeChecker.init(allocator, ir_view, null, &env, null);
    defer checker.deinit();

    const errors = try checker.check(root);
    try std.testing.expectEqual(expect_errors, errors);

    for (checker.getDiagnostics()) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) return;
    }
    for (checker.getDiagnostics()) |diag| {
        std.debug.print("diagnostic: {s}\n", .{diag.message});
    }
    return error.TestExpectedDiagnosticText;
}

/// Type the first ternary in `source` and render the result into `buf`. The
/// rendering is returned rather than the `TypeIndex` because the pool dies with
/// this function, so an index would dangle.
fn formatFirstTernaryType(source: []const u8, buf: []u8) ![]const u8 {
    const allocator = std.testing.allocator;

    var strip_result = try @import("zts-engine").stripper.strip(allocator, source, .{});
    defer strip_result.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, strip_result.code);
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateFromTypeMap(&strip_result.type_map);

    var checker = TypeChecker.init(allocator, ir_view, null, &env, null);
    defer checker.deinit();
    _ = try checker.check(root);

    var node: NodeIndex = 0;
    while (node < ir_view.nodeCount()) : (node += 1) {
        const tag = ir_view.getTag(node) orelse continue;
        if (tag != .ternary) continue;
        return pool.formatType(checker.inferType(node), buf);
    }
    return error.NoTernaryInSource;
}

test "ternary join: identical branch types collapse to that type" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const a: string = req.url; const b: string = req.method; const v = req.method === \"GET\" ? a : b; return Response.text(v); }",
        &buf,
    );
    // Step 2: both branches are `string`, so the join is `string` and no union
    // is formed.
    try std.testing.expectEqualStrings("string", rendered);
}

test "ternary join: distinct literal branches form a literal union" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const x = req.method === \"GET\" ? 1 : 2; return Response.json({ x }); }",
        &buf,
    );
    // Step 5, not step 2: `1` and `2` are distinct literal types and neither is
    // assignable to the other, so the join is their union rather than `number`.
    // Widening to `number` would discard information the checker holds.
    try std.testing.expectEqualStrings("1 | 2", rendered);
}

test "ternary join: a literal widens into the receiving branch type" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const s: string = req.url; const v = req.method === \"GET\" ? \"a\" : s; return Response.text(v); }",
        &buf,
    );
    // Step 4: the string literal is assignable to string but not the reverse,
    // so the receiving type wins.
    try std.testing.expectEqualStrings("string", rendered);
}

test "ternary join: disjoint branch types form a union" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const u = req.method === \"GET\" ? 1 : \"a\"; return Response.json({ u }); }",
        &buf,
    );
    // Step 5: nothing relates number and string, so the join is their union.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "|") != null);
}

test "ternary join: never on one side is removed" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var node_list = ir.NodeList.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const view = ir.IrView.fromNodeList(&node_list, &constants);

    var checker = TypeChecker.init(allocator, view, null, &env, null);
    defer checker.deinit();

    // Step 1, both directions, plus the both-never case.
    try std.testing.expectEqual(pool.idx_number, checker.joinTypes(pool.idx_never, pool.idx_number));
    try std.testing.expectEqual(pool.idx_number, checker.joinTypes(pool.idx_number, pool.idx_never));
    try std.testing.expectEqual(pool.idx_never, checker.joinTypes(pool.idx_never, pool.idx_never));
}

fn recordWithStringField(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8) TypeIndex {
    const n = pool.addName(allocator, name);
    return pool.addRecord(allocator, &.{
        .{ .name_start = n.start, .name_len = n.len, .type_idx = pool.idx_string, .optional = false },
    });
}

test "narrowing: a bare boolean discriminant read, and its negation" {
    // The Result idiom is written `if (!r.ok) return ...` at least as often as
    // it is written `r.ok === false`, and only the second form narrowed.
    //
    // The union members are written inline rather than as two named aliases.
    // That is not a style choice: a union of named refs does not resolve to
    // records here, so no field lookup finds a discriminant and no guard
    // installs - a version of this test written with aliases passes whether
    // the guard is right, wrong, or absent. This shape selects the wrong
    // member if the guard asks for the `false` arm, and both accesses below
    // then report a missing property.
    try checkTypedSource(
        \\function pick(r: { ok: true; value: string } | { ok: false; error: string }): string {
        \\  if (!r.ok) {
        \\    return r.error;
        \\  }
        \\  return r.value;
        \\}
    , 0, null);
    try checkTypedSource(
        \\function pick(r: { ok: true; value: string } | { ok: false; error: string }): string {
        \\  if (r.ok) {
        \\    return r.value;
        \\  }
        \\  return r.error;
        \\}
    , 0, null);
}

test "an object spread contributes the spread record's fields" {
    // `{ ...base, port: 8080 }` typed as `{ base: unknown; port: 8080 }`: a
    // spread node stores its operand where a property stores its key, so the
    // operand's NAME became a field and the operand's fields were dropped. Every
    // spread object therefore failed to satisfy the record type it was written
    // to produce, which is the whole use of the form.
    try checkTypedSource(
        \\type Config = { host: string, port: number };
        \\function defaults(): Config {
        \\  return { host: "localhost", port: 80 };
        \\}
        \\function configured(): Config {
        \\  const base: Config = defaults();
        \\  return { ...base, port: 8080 };
        \\}
    , 0, null);
}

test "an object spread does not invent fields the spread record lacks" {
    // The floor. Merging the spread's fields must not turn the check off: a
    // field the target type requires and neither side provides is still a
    // mismatch.
    try checkTypedSourceSaying(
        \\type Config = { host: string, port: number };
        \\function partial(): { port: number } {
        \\  return { port: 80 };
        \\}
        \\function configured(): Config {
        \\  const base: { port: number } = partial();
        \\  return { ...base, port: 8080 };
        \\}
    , 1, "return type does not match declared return type");
}

test "an annotated let keeps its declared type, so it can be reassigned" {
    // `let total: number = 0` bound the binding to the literal type `0`, from
    // the satisfies-like rule below that keeps a literal under a base-primitive
    // annotation. That rule is right for `const`, whose value cannot change,
    // and wrong for `let`, whose only reason to exist is that it changes: every
    // reassignment of an annotated `let` was refused as "type '7' is not
    // assignable to type '0'". `let` had no legal spelling with a literal
    // initializer.
    try checkTypedSource(
        \\function counter(): number {
        \\  let total: number = 0;
        \\  total = 7;
        \\  return total;
        \\}
    , 0, null);
}

test "an annotated let still refuses a value its declared type does not admit" {
    // The floor. Widening the binding to its annotation must not stop the
    // assignment check, only stop it comparing against the initializer.
    try checkTypedSourceSaying(
        \\function counter(): number {
        \\  let total: number = 0;
        \\  total = "seven";
        \\  return total;
        \\}
    , 1, "not assignable");
}

test "an annotated const still keeps the narrower literal type" {
    // The other side of the same rule, pinned so the fix above cannot be
    // widened into `const`. A `const` under a base-primitive annotation keeps
    // its literal type, which is what makes a match over it exhaustive without
    // a default; widening it to `string` would make the same match
    // non-exhaustive and warn.
    try checkTypedSource(
        \\function label(): number {
        \\  const k: string = "a";
        \\  return match (k) {
        \\    when "a": 1,
        \\  };
        \\}
    , 0, 0);
}

test "narrowing: typeof reaches the authoritative system" {
    try checkTypedSource(
        \\function label(v: string | number): string {
        \\  if (typeof v === "string") {
        \\    return v;
        \\  }
        \\  return "n";
        \\}
    , 0, null);
}

test "narrowing: Array.isArray" {
    try checkTypedSource(
        \\function first(v: string | string[]): string {
        \\  if (Array.isArray(v)) {
        \\    return v[0];
        \\  }
        \\  return v;
        \\}
    , 0, null);
}

test "narrowing: the else branch narrows too" {
    try checkTypedSource(
        \\function orDefault(v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  } else {
        \\    return v;
        \\  }
        \\}
    , 0, null);
}

test "narrowing: an assignment kills the narrowing it invalidates" {
    // Kill rule 1. Nothing killed a narrowing before, so the guard installed by
    // the early return survived the reassignment and `v` still read as
    // `string`.
    //
    // The control comes first, and it is what makes the second assertion mean
    // something: with no narrowing at all, both programs report one error and
    // the pair below would pass while checking nothing.
    try checkTypedSource(
        \\function kept(v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  return v;
        \\}
    , 0, null);
    try checkTypedSource(
        \\function reassigned(v: string | undefined, w: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  v = w;
        \\  return v;
        \\}
    , 1, null);
}

test "narrowing: a loop body that reassigns kills the narrowing at entry" {
    // Kill rule 4. The read happens before the assignment in source order, so
    // only the entry half of the rule can catch it: the back edge re-enters
    // with whatever the last iteration left.
    //
    // Control first: a loop that does not assign keeps the narrowing, so the
    // second assertion is about the assignment rather than about loops.
    try checkTypedSource(
        \\function readOnly(xs: string[], v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  for (const x of xs) {
        \\    const y: string = v;
        \\  }
        \\  return "ok";
        \\}
    , 0, null);
    try checkTypedSource(
        \\function looped(xs: string[], v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  for (const x of xs) {
        \\    const y: string = v;
        \\    v = undefined;
        \\  }
        \\  return "ok";
        \\}
    , 1, null);
}

test "the join asks for structural identity, not the same pool index" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var node_list = ir.NodeList.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const view = ir.IrView.fromNodeList(&node_list, &constants);

    var checker = TypeChecker.init(allocator, view, null, &env, null);
    defer checker.deinit();

    // Step 2. Two branches that each build `{ id: string }` hold different
    // indices, so the old rule fell through to step 3 and reached the same
    // answer by mutual assignability. It is step 2 that answers now, which is
    // what keeps the answer right when one side's field is optional.
    const left = recordWithStringField(&pool, allocator, "id");
    const right = recordWithStringField(&pool, allocator, "id");
    try std.testing.expect(left != right);
    try std.testing.expectEqual(left, checker.joinTypes(left, right));

    // Step 5: two types with nothing in common become the normalized union.
    const joined = checker.joinTypes(pool.idx_string, pool.idx_number);
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(joined).len);

    // Step 4: the receiving type wins when only one direction is assignable.
    const literal = pool.addLiteralString(allocator, "GET");
    try std.testing.expectEqual(pool.idx_string, checker.joinTypes(literal, pool.idx_string));
    try std.testing.expectEqual(pool.idx_string, checker.joinTypes(pool.idx_string, literal));
}

test "union normalization drops never, dedups by key, and subsumes" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // Step 2: `never` contributes no value and leaves.
    const with_never = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_never, pool.idx_number });
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(with_never).len);
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_never }));
    try std.testing.expectEqual(pool.idx_never, pool.addUnion(allocator, &.{ pool.idx_never, pool.idx_never }));

    // Step 3: structurally identical members at different indices are one
    // member. Index equality kept both.
    const a = recordWithStringField(&pool, allocator, "id");
    const b = recordWithStringField(&pool, allocator, "id");
    try std.testing.expectEqual(a, pool.addUnion(allocator, &.{ a, b }));

    // Step 5: `"GET" | string` is `string`, and order does not change that.
    const literal = pool.addLiteralString(allocator, "GET");
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ literal, pool.idx_string }));
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ pool.idx_string, literal }));

    // Step 6: survivors keep the order they were written in, which is what a
    // reader sees. Identity is order-free because the key sorts.
    const written = pool.addUnion(allocator, &.{ pool.idx_number, pool.idx_string });
    const members = pool.getUnionMembers(written);
    try std.testing.expectEqual(pool.idx_number, members[0]);
    try std.testing.expectEqual(pool.idx_string, members[1]);

    // Two literals of the same base do not subsume each other.
    const post = pool.addLiteralString(allocator, "POST");
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ literal, post })).len);
}

test "normalization does not drop a branded or obligation-carrying member" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // A `distinct type` is assignable to its base, but the union of the two is
    // not the base: the brand is what a nominal type is for.
    const user_id = pool.addNominalAlias(allocator, pool.idx_string, "UserId");
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ user_id, pool.idx_string })).len);

    // An intersection is a value shape plus obligations, and it is assignable
    // to its own members. `Effects<string, "env"> | string` resolves to that
    // shape, and dropping the marker branch would leave a type reading as
    // though the author declared no capability ceiling at all.
    const marker_name = pool.addName(allocator, "__zttp_effect__");
    const marker = pool.addRecord(allocator, &.{
        .{ .name_start = marker_name.start, .name_len = marker_name.len, .type_idx = pool.idx_string, .optional = false },
    });
    const carried = pool.addIntersection(allocator, &.{ pool.idx_string, marker });
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ carried, pool.idx_string })).len);
}

fn checkTypedSourceWithServiceContext(
    source: []const u8,
    service_type_context: ?*const ServiceTypeContext,
    expect_errors: u32,
    expect_warnings: ?u32,
) !void {
    const allocator = std.testing.allocator;

    var strip_result = try @import("zts-engine").stripper.strip(allocator, source, .{});
    defer strip_result.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, strip_result.code);
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateFromTypeMap(&strip_result.type_map);

    var checker = TypeChecker.init(allocator, ir_view, null, &env, service_type_context);
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

const RawTestResponse = struct {
    status: u16,
    content_type: ?[]const u8 = "application/json",
    schema_json: ?[]const u8 = null,
    dynamic: bool = false,
};

fn makeTestServiceContext(
    allocator: std.mem.Allocator,
    required_path_params: []const []const u8,
    responses: []const RawTestResponse,
) !ServiceTypeContext {
    const routes = try allocator.alloc(service_types_mod.RouteInfo, 1);
    errdefer allocator.free(routes);

    const path_params = try allocator.alloc([]const u8, required_path_params.len);
    errdefer allocator.free(path_params);
    for (required_path_params, 0..) |name, i| {
        path_params[i] = try allocator.dupe(u8, name);
    }

    const query_params = try allocator.alloc([]const u8, 0);
    const header_params = try allocator.alloc([]const u8, 0);

    const route_responses = try allocator.alloc(service_types_mod.ResponseVariant, responses.len);
    errdefer allocator.free(route_responses);
    for (responses, 0..) |response, i| {
        route_responses[i] = .{
            .status = response.status,
            .content_type = if (response.content_type) |content_type|
                try allocator.dupe(u8, content_type)
            else
                null,
            .schema_json = if (response.schema_json) |schema_json|
                try allocator.dupe(u8, schema_json)
            else
                null,
            .dynamic = response.dynamic,
        };
    }

    routes[0] = .{
        .service_name = try allocator.dupe(u8, "users"),
        .handler_path = try allocator.dupe(u8, "users.ts"),
        .method = try allocator.dupe(u8, "GET"),
        .path = try allocator.dupe(u8, "/api/users/:id"),
        .required_path_params = path_params,
        .required_query_params = query_params,
        .required_header_params = header_params,
        .request_dynamic = false,
        .response_dynamic = false,
        .requires_body = false,
        .responses = route_responses,
    };

    return .{ .routes = routes };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TypeChecker init and deinit" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Create a minimal IR using NodeList
    var node_list = ir.NodeList.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();

    // Add a program node with an empty block
    _ = node_list.add(.{
        .tag = .program,
        .loc = .{ .line = 1, .column = 1, .offset = 0 },
        .data = .{ .binary = .{ .op = .add, .left = null_node, .right = null_node } },
    }) catch {};

    const view = ir.IrView.fromNodeList(&node_list, &constants);

    var checker = TypeChecker.init(allocator, view, null, &env, null);
    defer checker.deinit();

    try std.testing.expectEqual(@as(usize, 0), checker.diagnostics.items.len);
}

test "TypeChecker infers serviceCall json payload with system context" {
    var service_context = try makeTestServiceContext(
        std.testing.allocator,
        &.{"id"},
        &.{
            .{ .status = 200, .schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}" },
        },
    );
    defer service_context.deinit(std.testing.allocator);

    try checkTypedSourceWithServiceContext(
        \\const user = serviceCall("users", "GET /api/users/:id", {
        \\  params: { id: "123" }
        \\});
        \\const status: number = user.status;
        \\const payload = user.json();
        \\const id: string = payload.id;
    , &service_context, 0, 0);
}

test "TypeChecker rejects serviceCall missing required path param" {
    var service_context = try makeTestServiceContext(
        std.testing.allocator,
        &.{"id"},
        &.{
            .{ .status = 200, .schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}" },
        },
    );
    defer service_context.deinit(std.testing.allocator);

    try checkTypedSourceWithServiceContext(
        \\const user = serviceCall("users", "GET /api/users/:id", {});
        \\const payload = user.json();
    , &service_context, 1, 0);
}

test "TypeChecker requires narrowing before multi-status serviceCall json" {
    var service_context = try makeTestServiceContext(
        std.testing.allocator,
        &.{"id"},
        &.{
            .{ .status = 200, .schema_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}" },
            .{ .status = 404, .schema_json = "{\"type\":\"object\",\"properties\":{\"error\":{\"type\":\"string\"}},\"required\":[\"error\"]}" },
        },
    );
    defer service_context.deinit(std.testing.allocator);

    try checkTypedSourceWithServiceContext(
        \\const user = serviceCall("users", "GET /api/users/:id", {
        \\  params: { id: "123" }
        \\});
        \\const payload = user.json();
    , &service_context, 2, 0);
}

test "TypeChecker proves literal union match exhaustiveness" {
    try checkTypedSource(
        \\const value: "a" | "b" = "a";
        \\const out = match (value) {
        \\  when "a": 1,
        \\  when "b": 2,
        \\};
    , 0, 0);
}

test "TypeChecker proves discriminated union match exhaustiveness" {
    try checkTypedSource(
        \\const ok = { kind: "ok", value: "x" };
        \\const err = { kind: "err", error: "bad" };
        \\const result = true ? ok : err;
        \\const out = match (result) {
        \\  when { kind: "ok" }: result.value,
        \\  when { kind: "err" }: result.error,
        \\};
    , 0, 0);
}

test "TypeChecker warns on non-exhaustive match over union" {
    try checkTypedSource(
        \\const value: "a" | "b" = "a";
        \\const out = match (value) {
        \\  when "a": 1,
        \\};
    , 0, 1);
}

test "TypeChecker: param-discriminant match with default arm is exhaustive (no warning)" {
    // Regression: inferType does not resolve a plain parameter's declared type,
    // so the discriminant was unknown and a `default` arm was not credited,
    // producing a spurious non-exhaustive warning. A catch-all arm is now
    // honored regardless of discriminant type.
    try checkTypedSource(
        \\type C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\    when { kind: "ping" }: "pong",
        \\    default: "u",
        \\  };
        \\}
    , 0, 0);
}

test "TypeChecker: typed return satisfies a marker-carrying declared return type" {
    // `Effects<string, "env">` instantiates to `string & { __zttp_effect__ }`.
    // The phantom marker is a verifier obligation, never a value shape, so a
    // returned `string` must pass the return-type check. Without
    // stripProofMarkers the intersection comparison spuriously failed for any
    // return expression whose type inference resolves (annotated locals).
    try checkTypedSource(
        \\function digest(): Effects<string, "env"> {
        \\  const s: string = "x";
        \\  return s;
        \\}
    , 0, 0);
}

test "TypeChecker: marker stripping still rejects a genuinely wrong return" {
    try checkTypedSource(
        \\function digest(): Effects<string, "env"> {
        \\  const n: number = 1;
        \\  return n;
        \\}
    , 1, 0);
}

test "TypeChecker: full-variant param-discriminant match without a default is exhaustive" {
    // Option B: declared parameter types are registered into binding_types on
    // function entry (registerParamTypes), so the discriminant of a
    // `match (param)` resolves to the declared union and variant-coverage
    // analysis runs. Full coverage without a default arm is exhaustive - no
    // warning. (The canonical profile still separately requires a default arm
    // on every match; this only fixes the type-checker layer's false warn.)
    try checkTypedSource(
        \\type C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\    when { kind: "ping" }: "pong",
        \\  };
        \\}
    , 0, 0);
}

test "TypeChecker: partial param-discriminant match without a default still warns" {
    // The same parameter-type resolution must not silence REAL gaps: one of
    // two variants covered, no default - warn.
    try checkTypedSource(
        \\type C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\  };
        \\}
    , 0, 1);
}

test "TypeChecker: annotation preserves narrow inferred type" {
    // const p: number = 3000 should keep type 3000, not widen to number
    try checkTypedSource(
        \\const p: number = 3000;
    , 0, 0);
}

test "TypeChecker: annotation rejects incompatible type" {
    // const bad: number = "oops" should error
    try checkTypedSource(
        \\const bad: number = "oops";
    , 1, 0);
}

test "TypeChecker: exported handler local const rejects incompatible initializer" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  const n: number = "not a number";
        \\  return Response.json({});
        \\}
    , 1, 0);
}

test "TypeChecker: exported default handler local annotation is checked" {
    try checkTypedSource(
        \\export default function handler(req: Request): Response {
        \\  const n: number = "x";
        \\  return Response.json({});
        \\}
    , 1, 0);
}

test "TypeChecker: exported arrow handler local annotation is checked" {
    try checkTypedSource(
        \\export const handler = () => {
        \\  const n: number = "x";
        \\  return Response.json({});
        \\};
    , 1, 0);
}

test "TypeChecker: exported handler local let annotation is checked" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  let n: number = "x";
        \\  return Response.json({});
        \\}
    , 1, 0);
}

test "TypeChecker: nested arrow in exported handler checks local annotation" {
    try checkTypedSource(
        \\export const handler = () => {
        \\  const nested = () => {
        \\    const n: number = "x";
        \\    return n;
        \\  };
        \\  return Response.json({ value: nested() });
        \\};
    , 1, 0);
}

test "TypeChecker: shadowed exported local uses its own scoped annotation" {
    try checkTypedSource(
        \\export const zz: string = "top level";
        \\export function handler(req: Request): Response {
        \\  const zz: number = "not a number";
        \\  return Response.json({ value: zz });
        \\}
    , 1, 0);
}

test "TypeChecker: exported handler argument annotation reaches nested upvalue" {
    try checkTypedSource(
        \\export function handler(req: number): Response {
        \\  const nested = () => {
        \\    const text: string = req;
        \\    return text;
        \\  };
        \\  return Response.json({ value: nested() });
        \\}
    , 1, 0);
}

test "TypeChecker: exported top-level annotation remains checked" {
    try checkTypedSource(
        \\export const top: number = "x";
    , 1, 0);
}

test "TypeChecker: correct local annotation in exported handler passes" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  return Response.json({ value: n });
        \\}
    , 0, 0);
}

test "TypeChecker: colliding locals use their initializer signatures" {
    try checkTypedSource(
        \\function one(value: string): string { return value; }
        \\function none(): string { return "ok"; }
        \\function handler() {
        \\  const request = one;
        \\  const run = none;
        \\  const scope = one;
        \\  const fetch = none;
        \\  request("request");
        \\  run();
        \\  scope("scope");
        \\  fetch();
        \\}
    , 0, 0);
}

test "TypeChecker: non-callable colliding locals do not inherit module signatures" {
    try checkTypedSource(
        \\function handler(send) {
        \\  const request = 42;
        \\  const run = "not callable";
        \\  send();
        \\  request();
        \\  run();
        \\}
    , 0, 0);
}

test "TypeChecker: module signature aliases preserve required parameter count" {
    try checkTypedSource(
        \\import { fetchWithRetry } from "zttp:fetch";
        \\function handler() {
        \\  const request = fetchWithRetry;
        \\  request("https://example.com");
        \\}
    , 0, 0);
}

test "TypeChecker: user function aliases carry the function signature" {
    try checkTypedSource(
        \\function format(value: string, count: number): string { return value; }
        \\function handler() {
        \\  const alias = format;
        \\  alias("ok", 1);
        \\  alias("missing count");
        \\  const nested = (local) => {
        \\    alias("nested missing count");
        \\  };
        \\  nested(42);
        \\}
    , 2, 0);
}

test "TypeChecker: genuine module calls retain module argument checking" {
    try checkTypedSource(
        \\import { request } from "zttp:queue";
        \\request("worker", {});
        \\request("worker");
    , 1, 0);
}

test "TypeChecker: logical and preserves matching operand type" {
    try checkTypedSource(
        \\const x: string = "x";
        \\const y: string = "y";
        \\const s: string = x && y;
    , 0, 0);
}

test "TypeChecker: logical and rejects boolean annotation for string operands" {
    try checkTypedSource(
        \\const x: string = "x";
        \\const y: string = "y";
        \\const b: boolean = x && y;
    , 1, 0);
}

test "TypeChecker: logical operators infer operand union" {
    try checkTypedSource(
        \\function combine(x: string, y: number) {
        \\  const and_result: string | number = x && y;
        \\  const or_result: string | number = x || y;
        \\}
    , 0, 0);
}

test "TypeChecker: logical and flattens operand union for exact annotation" {
    try checkTypedSource(
        \\const value: string | number = "x";
        \\const flag: boolean = true;
        \\const result: string | number | boolean = value && flag;
    , 0, 0);
}

test "TypeChecker: nullish coalescing includes fallback in nullable result" {
    try checkTypedSource(
        \\function maybe(): string | undefined { return undefined; }
        \\const s: string = maybe() ?? 42;
        \\const v: string | number = maybe() ?? 42;
    , 1, 0);
}

test "TypeChecker: non-nullable nullish coalescing keeps left type" {
    try checkTypedSource(
        \\function defaultValue(value: string) {
        \\  const result: string = value ?? 42;
        \\}
    , 0, 0);
}

test "TypeChecker: undefined nullish coalescing returns fallback type" {
    try checkTypedSource(
        \\function defaultValue(fallback: number) {
        \\  const result: number = undefined ?? fallback;
        \\}
    , 0, 0);
}

test "TypeChecker: rejects assignment to readonly property" {
    try checkTypedSource(
        \\type Config = { readonly port: number; host: string };
        \\const cfg: Config = { port: 3000, host: "localhost" };
        \\cfg.port = 8080;
    , 1, 0);
}

test "TypeChecker: allows assignment to non-readonly property" {
    try checkTypedSource(
        \\type Config = { readonly port: number; host: string };
        \\const cfg: Config = { port: 3000, host: "localhost" };
        \\cfg.host = "other";
    , 0, 0);
}

test "TypeChecker: distinct type rejects cross-nominal assignment" {
    // SessionId should not be assignable to UserId
    try checkTypedSource(
        \\distinct type UserId = string;
        \\distinct type SessionId = string;
        \\const sid: SessionId = SessionId("sess_456");
        \\const uid: UserId = sid;
    , 1, 0);
}

test "TypeChecker: distinct type constructor returns nominal type" {
    // UserId("str") should produce a UserId, accepted where UserId is expected
    try checkTypedSource(
        \\distinct type UserId = string;
        \\const uid: UserId = UserId("usr_123");
    , 0, 0);
}

test "TypeChecker: distinct type rejects raw base type" {
    // raw string should not be assignable to UserId
    try checkTypedSource(
        \\distinct type UserId = string;
        \\const uid: UserId = "raw_string";
    , 1, 0);
}

test "TypeChecker: template literal type accepts matching string" {
    try checkTypedSource(
        \\type ApiRoute = `/api/${string}`;
        \\const good: ApiRoute = "/api/users";
    , 0, 0);
}

test "TypeChecker: template literal type rejects non-matching string" {
    try checkTypedSource(
        \\type ApiRoute = `/api/${string}`;
        \\const bad: ApiRoute = "/other";
    , 1, 0);
}

test "TypeChecker: toSorted with a comparator type-checks clean" {
    // Regression for ENG-9: a comparator argument must not raise ZTS204/ZTS003.
    // toSorted(compareFn?) is modelled as an optional callback returning T[].
    try checkTypedSource(
        \\const nums = [10, 2, 1, 33, 4];
        \\const sorted = nums.toSorted((a, b) => a - b);
    , 0, 0);
}

test "TypeChecker: jwtVerify algorithm parameter is optional" {
    try checkTypedSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret");
    , 0, 0);
}

test "TypeChecker: jwtVerify algorithm parameter is type-checked when present" {
    try checkTypedSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret", 123);
    , 1, 0);
}

test "TypeChecker tracks object literal fields beyond 32 properties" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll("const obj = {");
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("p{d}: \"{d}\"", .{ i, i });
    }
    try aw.writer.writeAll("};\nconst last: string = obj.p32;\n");

    try checkTypedSource(aw.writer.buffered(), 0, 0);
}

test "TypeChecker tracks schema object fields beyond 32 properties" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("big", '{"type":"object","properties":{
    );
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("\"p{d}\":{{\"type\":\"string\"}}", .{i});
    }
    try aw.writer.writeAll(
        \\}}');
        \\const result = validateJson("big", "{}");
        \\const last: string = result.value.p32;
        \\
    );

    try checkTypedSource(aw.writer.buffered(), 0, 0);
}

test "TypeChecker tracks schema enum members beyond 32 values" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("choice", '{"enum":[
    );
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("\"v{d}\"", .{i});
    }
    try aw.writer.writeAll(
        \\]}');
        \\
    );

    var strip_result = try @import("zts-engine").stripper.strip(allocator, aw.writer.buffered(), .{});
    defer strip_result.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, strip_result.code);
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateFromTypeMap(&strip_result.type_map);

    var checker = TypeChecker.init(allocator, ir_view, null, &env, null);
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));
    try std.testing.expectEqual(@as(usize, 1), checker.compiled_schemas.items.len);
    const schema_type = checker.compiled_schemas.items[0].type_idx;
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(schema_type).?);
    const members = pool.getUnionMembers(schema_type);
    try std.testing.expectEqual(@as(usize, 33), members.len);
    try std.testing.expectEqualStrings("v32", pool.getLiteralStringValue(members[32]).?);
}

test "TypeChecker: toSorted with no comparator type-checks clean" {
    // The single comparator parameter is optional, so a zero-arg call is valid.
    try checkTypedSource(
        \\const nums = [3, 1, 2];
        \\const sorted = nums.toSorted();
    , 0, 0);
}

test "TypeChecker: toReversed type-checks clean" {
    try checkTypedSource(
        \\const nums = [3, 1, 2];
        \\const rev = nums.toReversed();
    , 0, 0);
}

// ---------------------------------------------------------------------------
// Generic instantiation (D1 section 4)
// ---------------------------------------------------------------------------

/// Type the call to `callee` in `source` and render the result into `buf`.
/// The rendering is returned rather than the `TypeIndex` because the pool dies
/// with this function, so an index would dangle.
fn formatCallType(source: []const u8, callee: []const u8, buf: []u8) ![]const u8 {
    const allocator = std.testing.allocator;

    var strip_result = try @import("zts-engine").stripper.strip(allocator, source, .{});
    defer strip_result.deinit();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, strip_result.code);
    defer parser.deinit();

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    env.populateFromTypeMap(&strip_result.type_map);

    var checker = TypeChecker.init(allocator, ir_view, null, &env, null);
    defer checker.deinit();
    _ = try checker.check(root);

    var node: NodeIndex = 0;
    while (node < ir_view.nodeCount()) : (node += 1) {
        if (ir_view.getTag(node) != .call) continue;
        const call = ir_view.getCall(node) orelse continue;
        if (ir_view.getTag(call.callee) != .identifier) continue;
        const binding = ir_view.getBinding(call.callee) orelse continue;
        const name = checker.resolveAtomName(binding.name_atom) orelse continue;
        if (!std.mem.eql(u8, name, callee)) continue;
        return pool.formatType(checker.inferType(node), buf);
    }
    return error.NoSuchCallInSource;
}

const generic_first_decl =
    \\function first<T>(xs: T[]): T | undefined {
    \\    for (const x of xs) { return x; }
    \\    return undefined;
    \\}
    \\
;

test "a literal argument binds the type parameter to its base type" {
    var buf: [128]u8 = undefined;
    // `["a"]` types as `"a"[]`, so binding T to the element verbatim would make
    // the call return `"a" | undefined` and every other string a mismatch.
    const rendered = try formatCallType(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first(["a"]);
            \\    return Response.json({ head });
            \\}
        ,
        "first",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "string") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"a\"") == null);
}

test "an inferred type argument is checked against the annotation it flows into" {
    // The positive control for the test above: with no inference this call
    // typed as an unresolved `T` and every annotation accepted it.
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head: number | undefined = first(["a"]);
            \\    return Response.json({ head });
            \\}
        ,
        1,
        null,
    );
}

test "an inferred type argument that matches its annotation raises nothing" {
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head: string | undefined = first(["a"]);
            \\    return Response.json({ head });
            \\}
        ,
        0,
        null,
    );
}

test "an explicit type argument overrides inference" {
    var buf: [128]u8 = undefined;
    const rendered = try formatCallType(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<number>([]);
            \\    return Response.json({ head });
            \\}
        ,
        "first",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "number") != null);
}

test "a type parameter no argument determines is refused, not widened" {
    try checkTypedSource(
        \\function make<T>(n: number): T | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v = make(1);
        \\    return Response.json({ v });
        \\}
    ,
        1,
        null,
    );
}

test "naming the type argument answers the ambiguity" {
    try checkTypedSource(
        \\function make<T>(n: number): T | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v = make<string>(1);
        \\    return Response.json({ v });
        \\}
    ,
        0,
        null,
    );
}

test "a type argument outside its constraint is refused" {
    try checkTypedSource(
        \\function idOf<T extends { id: string }>(v: T): string {
        \\    return v.id;
        \\}
        \\function handler(req: Request): Response {
        \\    const s = idOf({ name: "no id" });
        \\    return Response.json({ s });
        \\}
    ,
        1,
        null,
    );
}

test "a type argument inside its constraint is accepted" {
    try checkTypedSource(
        \\function idOf<T extends { id: string }>(v: T): string {
        \\    return v.id;
        \\}
        \\function handler(req: Request): Response {
        \\    const s = idOf({ id: "u1" });
        \\    return Response.json({ s });
        \\}
    ,
        0,
        null,
    );
}

test "explicit type arguments of the wrong count are refused" {
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<string, number>(["a"]);
            \\    return Response.json({ head });
            \\}
        ,
        1,
        null,
    );
}

test "every instantiation re-checks its value arguments" {
    // `first<string>` fixes the parameter at `string[]`, so a number array is
    // a mismatch that the uninstantiated `T[]` accepted.
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<string>([1]);
            \\    return Response.json({ head });
            \\}
        ,
        1,
        null,
    );
}

test "a constraint that accepts literals keeps the literal it was given" {
    // Widening `"get"` to `string` would put the argument outside the bound the
    // call satisfies, so the literal survives and the call is clean.
    try checkTypedSource(
        \\function pick<T extends "get" | "put">(m: T): T {
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    const m = pick("get");
        \\    return Response.json({ m });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Narrowing regressions
// ---------------------------------------------------------------------------

test "a write to a readonly field is caught through a narrowing" {
    // The check read `binding_types`, which holds the declaration, so once
    // narrowings moved to their own overlay the guarded shape - the usual way
    // a readonly record is reached - stopped resolving to a record and the
    // write passed in silence.
    try checkTypedSource(
        \\function load(): { readonly id: string } | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: { readonly id: string } | undefined = load();
        \\    if (v !== undefined) {
        \\        v.id = "b";
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        null,
    );
}

test "a narrowing from a nested early return does not escape its conditional" {
    // Kill rule 5 drops narrowings whose binding lives in the closing block's
    // scope, and the binding here is a parameter of the enclosing function, so
    // the forward narrowing survived the outer `if` and described the path
    // where `flag` was false.
    try checkTypedSource(
        \\function f(flag: boolean, v: string | undefined): string {
        \\    if (flag) {
        \\        if (v === undefined) {
        \\            return "x";
        \\        }
        \\    }
        \\    return v;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f(true, "a") });
        \\}
    ,
        1,
        null,
    );
}

test "an unguarded early return still narrows the rest of its own block" {
    // The positive control for the test above: the same guard without the
    // enclosing conditional must still narrow, or the fix would have bought
    // soundness by turning narrowing off.
    try checkTypedSource(
        \\function f(v: string | undefined): string {
        \\    if (v === undefined) {
        \\        return "x";
        \\    }
        \\    return v;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f("a") });
        \\}
    ,
        0,
        null,
    );
}

test "a boolean field that is not a discriminant installs no guard" {
    // The guard took the first member whose field is literal `true` and
    // excluded only that member. A sibling whose field is plain `boolean` can
    // also be true at runtime, so the then-branch was narrowed to the wrong
    // member and a correct field read reported as missing.
    try checkTypedSource(
        \\function f(c: { on: true, a: string } | { on: boolean, b: string }): string {
        \\    if (c.on) {
        \\        return c.b;
        \\    }
        \\    return "d";
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f({ on: false, b: "x" }) });
        \\}
    ,
        0,
        null,
    );
}

test "a real boolean discriminant still selects its member" {
    // The positive control: reading the other arm's field inside the guard is
    // still an error, so the fix did not disable the guard.
    try checkTypedSource(
        \\function f(r: { ok: true, value: string } | { ok: false, error: string }): string {
        \\    if (r.ok) {
        \\        return r.error;
        \\    }
        \\    return r.error;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f({ ok: false, error: "x" }) });
        \\}
    ,
        1,
        null,
    );
}

test "a captured binding and a parameter in the same slot narrow separately" {
    // Both pack to (scope, slot) and both are slot 0 of the inner function -
    // an upvalue indexes the closure's upvalue array, a parameter its own
    // argument array - so the narrowing installed for the captured `v` landed
    // on `n` and `return n` was read as `string`.
    try checkTypedSource(
        \\function load(): string | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | undefined = load();
        \\    const f = (n: number): number => {
        \\        if (v === undefined) {
        \\            return 0;
        \\        }
        \\        return n;
        \\    };
        \\    return Response.json({ x: f(1) });
        \\}
    ,
        0,
        null,
    );
}

test "an absence guard narrows a union wider than the old scratch buffer" {
    // The partition ran in a sixteen-slot stack buffer and bailed out past it,
    // so exactly the wide enums `addUnion` was changed to represent could not
    // be narrowed: after the early return the value stayed nullable and the
    // return reported a mismatch on correct code.
    try checkTypedSource(
        \\function pick(m: "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | "m17" | undefined): "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | "m17" {
        \\    if (m === undefined) {
        \\        return "m1";
        \\    }
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ m: pick("m1") });
        \\}
    ,
        0,
        null,
    );
}

test "the same guard over a sixteen-member union is the control" {
    try checkTypedSource(
        \\function pick(m: "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | undefined): "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" {
        \\    if (m === undefined) {
        \\        return "m1";
        \\    }
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ m: pick("m1") });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// `null` narrowing (spec 5.3 / phase 3 task 2)
// ---------------------------------------------------------------------------

test "a null guard narrows the value it names" {
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null = req.url;
        \\    if (value !== null) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the guard the same read is refused" {
    // The positive control for the test above: with no narrowing at all, both
    // programs would report the same count and neither would prove anything.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null = req.url;
        \\    return Response.json({ n: take(value) });
        \\}
    ,
        1,
        "expected string, got string | null",
    );
}

test "an undefined guard does not remove null" {
    // Spec 5.3 keeps the two apart. `v !== undefined` over
    // `string | null | undefined` leaves `string | null`, so the call still
    // reports - the diagnostic is what proves the `null` member survived.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null | undefined = req.url;
        \\    if (value !== undefined) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        1,
        "expected string, got string | null",
    );
}

test "a null guard over an optional type narrows nothing" {
    // `t_nullable` is `T | undefined` and carries no `null` member, so a
    // `null` test over it removes nothing and must not strip the optionality
    // the author declared.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | undefined = req.url;
        \\    if (value !== null) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        1,
        "expected string, got string | undefined",
    );
}

// ---------------------------------------------------------------------------
// `match` field bindings (spec 5.5 / phase 3 task 5)
// ---------------------------------------------------------------------------

const command_union =
    \\type Command =
    \\  | { kind: "echo"; text: string }
    \\  | { kind: "ping" };
;

test "a shorthand binding carries the field type" {
    try checkTypedSource(
        command_union ++
            \\function take(s: string): number {
            \\    return s.length;
            \\}
            \\function run(command: Command): number {
            \\    return match (command) {
            \\        when { kind: "echo", text }: take(text)
            \\        when { kind: "ping" }: 0
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ n: run({ kind: "ping" }) });
            \\}
        ,
        0,
        null,
    );
}

test "a binding used against the wrong type is refused" {
    // The positive control: with no type on the binding, every use of it is
    // checked against nothing and this program passes too.
    try checkTypedSourceSaying(
        command_union ++
            \\function take(n: number): number {
            \\    return n;
            \\}
            \\function run(command: Command): number {
            \\    return match (command) {
            \\        when { kind: "echo", text }: take(text)
            \\        when { kind: "ping" }: 0
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ n: run({ kind: "ping" }) });
            \\}
        ,
        1,
        "expected number, got string",
    );
}

test "a rename binds the field under the new name" {
    try checkTypedSource(
        command_union ++
            \\function run(command: Command): string {
            \\    return match (command) {
            \\        when { kind: "echo", text: message }: message
            \\        when { kind: "ping" }: "pong"
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ s: run({ kind: "ping" }) });
            \\}
        ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Type-test patterns (spec 5.5 / phase 3 task 6)
// ---------------------------------------------------------------------------

test "a type test narrows its arm" {
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function label(value: string | number): number {
        \\    return match (value) {
        \\        when string: take(value)
        \\        when number: 0
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: label(1) });
        \\}
    ,
        0,
        null,
    );
}

test "a type test does not narrow the arm it does not name" {
    // The positive control for the test above: if `when number:` narrowed to
    // `string` too, or narrowed nothing, this program would pass.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function label(value: string | number): number {
        \\    return match (value) {
        \\        when string: 0
        \\        when number: take(value)
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: label(1) });
        \\}
    ,
        1,
        "expected string, got number",
    );
}

test "the null literal and the four type tests exhaust JsonValue without a default" {
    try checkTypedSource(
        \\type JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function depth(value: JsonValue): number {
        \\    return match (value) {
        \\        when null: 1
        \\        when boolean: 1
        \\        when number: 1
        \\        when string: 1
        \\        when array: 2
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ d: depth([1, "a"]) });
        \\}
    ,
        0,
        null,
    );
}

test "the six arms cover JsonValue with its Dict arm" {
    // Spec 16.3 in full: the null literal pattern plus the five type tests
    // cover the six value kinds exactly, so the match is exhaustive without a
    // `default` - which a closed union is required to do without.
    try checkTypedSource(
        \\type JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[]
        \\  | Dict<string, JsonValue>;
        \\function kindOf(value: JsonValue): string {
        \\    return match (value) {
        \\        when null: "null"
        \\        when boolean: "boolean"
        \\        when number: "number"
        \\        when string: "string"
        \\        when array: "array"
        \\        when Dict: "dict"
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ k: kindOf(1) });
        \\}
    ,
        0,
        null,
    );
}

test "isDict narrows to the Dict member and leaves the rest to the else branch" {
    try checkTypedSource(
        \\function take(d: Dict<string, number>): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Dict<string, number> = "x";
        \\    if (isDict(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the isDict guard the same call is refused" {
    // The positive control: with no narrowing, both programs report the same
    // count and the test above proves nothing.
    try checkTypedSourceSaying(
        \\function take(d: Dict<string, number>): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Dict<string, number> = "x";
        \\    return Response.json({ n: take(v) });
        \\}
    ,
        1,
        "expected Dict<string, number>",
    );
}

test "a Bytes arm narrows in the arm it guards and not in the others" {
    // The binding's type inside the arm is `Bytes`, so a Bytes-taking helper
    // accepts it there; in a sibling arm the same name is still the union, and
    // the same call is refused. One program, both halves.
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function sizeOf(value: string | Bytes): number {
        \\    return match (value) {
        \\        when Bytes: take(value)
        \\        when string: 0
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: sizeOf("x") });
        \\}
    ,
        0,
        null,
    );

    try checkTypedSourceSaying(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function sizeOf(value: string | Bytes): number {
        \\    return match (value) {
        \\        when Bytes: 0
        \\        when string: take(value)
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: sizeOf("x") });
        \\}
    ,
        1,
        "expected Bytes",
    );
}

test "the request readers are typed, and their parameter is a Request" {
    // They are globals, so their signatures live in the same name-keyed map
    // the module exports use. Without that a call to one would infer nothing,
    // which is the state `Request` itself was in before this phase.
    try checkTypedSource(
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: bytesLength(requestBody(req)) });
        \\}
    ,
        0,
        null,
    );

    // The return type is `Bytes`, which the encodability rule then refuses to
    // send - two rules meeting on one value, which is the check that the
    // reader's declared type is real rather than absent.
    try checkTypedSourceSaying(
        \\function handler(req: Request): Response {
        \\    return Response.json({ raw: requestBody(req) });
        \\}
    ,
        1,
        "Bytes is not a JSON value",
    );

    // The parameter is a `Request` and nothing else.
    try checkTypedSourceSaying(
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: bytesLength(requestBody("nope")) });
        \\}
    ,
        1,
        "expected Request",
    );
}

test "the encodability rule generalizes to a module payload" {
    // The same rule at a second site, which is the check that it is a rule
    // rather than a special case for `Response.json`. A queue payload and a
    // response body are serialized by the same encoder, so they answer the
    // same question - and the diagnostic names which site asked it.
    //
    // `request` rather than `send`: two modules export a `send`, and
    // `populateModuleTypes` keys its signature map by bare name, so
    // `zttp:websocket.send` overwrites `zttp:queue.send` and a call to either
    // is checked against the other's parameters. That collision is real and
    // predates this rule; naming it here keeps the test measuring the rule.
    try checkTypedSourceSaying(
        \\import { request } from "zttp:queue";
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    const r = request("worker", { raw: encodeUtf8("hi") });
        \\    return Response.json({ ok: r.ok });
        \\}
    ,
        1,
        "zttp:queue.request cannot encode this payload",
    );

    // The other half: an encodable payload passes, so the rule is usable
    // rather than merely strict.
    try checkTypedSource(
        \\import { request } from "zttp:queue";
        \\function handler(req: Request): Response {
        \\    const r = request("worker", { id: "a", n: 1, flags: [true, false] });
        \\    return Response.json({ ok: r.ok });
        \\}
    ,
        0,
        null,
    );
}

test "the encodability rule follows the import, not the local spelling" {
    // A bare-name lookup was wrong in both directions: an alias never matched,
    // so the check was skipped under `import { request as publish }`; and a
    // handler's own function of the same name did match, so a local was
    // checked against a module export's declaration.
    try checkTypedSourceSaying(
        \\import { request as publish } from "zttp:queue";
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    const r = publish("jobs", { raw: encodeUtf8("x") });
        \\    return Response.json({ ok: r.ok });
        \\}
    ,
        1,
        "zttp:queue.request cannot encode this payload",
    );

    // A local function that happens to share the name is not the export.
    try checkTypedSource(
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function request(target: string, payload: unknown): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: request("jobs", { raw: encodeUtf8("x") }) });
        \\}
    ,
        0,
        null,
    );
}

test "a message id is not an actor name" {
    // `ack(id)` and `send(target, payload)` both took a bare string, so the
    // one confusion the queue ABI invites - settling a message with the actor
    // name you just sent to - was unsayable in the types. `MessageId` is a
    // brand over string, so a literal is refused.
    try checkTypedSourceSaying(
        \\import { ack } from "zttp:queue";
        \\function handler(req: Request): Response {
        \\    const done = ack("worker");
        \\    return Response.json({ ok: done.ok });
        \\}
    ,
        1,
        "expected MessageId",
    );

    // The id a caller actually has comes out of a `Result` whose value types
    // as nothing, so the checker admits it for want of information rather
    // than for want of a brand. Recorded, because it is the half that does
    // not hold yet and it needs phase 7's parameterized `Result`.
    try checkTypedSource(
        \\import { receive, ack } from "zttp:queue";
        \\function handler(req: Request): Response {
        \\    const r = receive("main");
        \\    if (!r.ok) return Response.json({ ok: false });
        \\    const done = ack(r.value.id);
        \\    return Response.json({ ok: done.ok });
        \\}
    ,
        0,
        null,
    );
}

test "Response.json refuses a payload JSON cannot carry" {
    // The failure exists today and has nowhere to go: `http.zig` calls
    // `valueToJsonString` with `try`, so a function-valued field throws, and
    // the subset has no `try/catch`. Deciding it from the type is what turns a
    // run-time throw into a diagnostic.
    try checkTypedSourceSaying(
        \\function helper(n: number): number {
        \\    return n;
        \\}
        \\function handler(req: Request): Response {
        \\    const f: (n: number) => number = helper;
        \\    return Response.json({ f });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // A whole request, whose `text` and `json` fields are functions. Sending
    // one would throw at the first of them.
    try checkTypedSourceSaying(
        \\function handler(req: Request): Response {
        \\    return Response.json({ r: req });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // A Bytes is an octet buffer, not a JSON value.
    try checkTypedSourceSaying(
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ raw: encodeUtf8("hi") });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // And nested, because a payload is usually a record of records.
    try checkTypedSourceSaying(
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ outer: { inner: [encodeUtf8("hi")] } });
        \\}
    ,
        1,
        "is not a JSON value",
    );
}

test "a bare function name in an object literal is not caught, and that is inference" {
    // Measured, not assumed: `{ f: helper }` where `helper` is a plain
    // declaration infers a record whose field has no type, so the rule has
    // nothing to refuse. The limit is in what an object literal infers for a
    // bare callable identifier, not in the encodability walk - the same
    // program with the function bound to a declared function type reports.
    //
    // Recorded rather than worked around: making the walk guess from a name
    // would be the rule claiming knowledge the type system did not give it.
    try checkTypedSource(
        \\function helper(n: number): number {
        \\    return n;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ f: helper });
        \\}
    ,
        0,
        null,
    );
}

test "Response.json still admits every payload JSON can carry" {
    // The other half. Without it the test above passes for a checker that
    // refuses everything, and the rule would be unusable rather than wrong.
    try checkTypedSource(
        \\import { encodeBase64, encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    const nested = { id: "a", counts: [1, 2, 3], flag: true, missing: null };
        \\    return Response.json({ nested, encoded: encodeBase64(encodeUtf8("hi")), n: 1 });
        \\}
    ,
        0,
        null,
    );

    // `unknown` is admitted deliberately: it is what a `Result` payload types
    // as, and refusing it would reject `Response.json(parsed.value)` in every
    // handler that has one. The checker reports where it knows and stays quiet
    // where it does not.
    try checkTypedSource(
        \\import { parseJson } from "zttp:json";
        \\function handler(req: Request): Response {
        \\    const parsed = parseJson("{}");
        \\    if (!parsed.ok) return Response.json({ error: parsed.error });
        \\    return Response.json({ data: parsed.value });
        \\}
    ,
        0,
        null,
    );
}

test "a request field reads its declared type end to end" {
    // `Request` was a name resolving to nothing, so every read off a request
    // answered nothing and a typo was as silent as a correct field. These are
    // the two halves: a declared field types, and passing an absent-capable
    // one where a `string` is wanted now reports.
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.method), u: take(req.url) });
        \\}
    ,
        0,
        null,
    );

    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.body) });
        \\}
    ,
        1,
        "expected string, got string | undefined",
    );

    // And the narrowing an author writes discharges it.
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.body ?? "") });
        \\}
    ,
        0,
        null,
    );
}

test "isBytes narrows to the Bytes member and leaves the rest to the else branch" {
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Bytes = "x";
        \\    if (isBytes(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the isBytes guard the same call is refused" {
    // The positive control: with no narrowing, both programs report the same
    // count and the test above proves nothing.
    try checkTypedSourceSaying(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Bytes = "x";
        \\    return Response.json({ n: take(v) });
        \\}
    ,
        1,
        "expected Bytes",
    );
}

test "isBytes refines unknown, which is where the guard is written" {
    // A `Result`-returning export types its payload `unknown`, so this is the
    // site the guard exists for. Without the refinement the narrowed value is
    // still `unknown` and every use of it is refused.
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: unknown = 1;
        \\    if (isBytes(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "the recursive fold over JsonValue type-checks" {
    // Spec 16.3 minus its Dict arm: the array arm recurses through the same
    // alias, which is what the contractive rule exists to admit.
    try checkTypedSource(
        \\type JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function deeper(maximum: number, child: JsonValue): number {
        \\    const childDepth = depth(child);
        \\    return childDepth > maximum ? childDepth : maximum;
        \\}
        \\function depth(value: JsonValue): number {
        \\    return match (value) {
        \\        when null: 1
        \\        when boolean: 1
        \\        when number: 1
        \\        when string: 1
        \\        when array: value.reduce(deeper, 0) + 1
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ d: depth([1, "a"]) });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Contractive recursive aliases (spec 5.7 / phase 3 task 4)
// ---------------------------------------------------------------------------

test "a recursive alias guarded by an array is accepted" {
    try checkTypedSource(
        \\type JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function handler(req: Request): Response {
        \\    const value: JsonValue = [1, "a", [true, null]];
        \\    return Response.json({ value });
        \\}
    ,
        0,
        null,
    );
}

test "a recursive alias guarded by a record is accepted" {
    try checkTypedSource(
        \\type Tree = { value: number; children: readonly Tree[] };
        \\function handler(req: Request): Response {
        \\    const t: Tree = { value: 1, children: [] };
        \\    return Response.json({ v: t.value });
        \\}
    ,
        0,
        null,
    );
}

test "a direct cycle is refused" {
    try checkTypedSourceSaying(
        \\type Loop = Loop;
        \\function handler(req: Request): Response {
        \\    const v: Loop = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        "recursive type alias 'Loop' has a cycle no data constructor guards",
    );
}

test "a union edge does not guard a cycle" {
    // The union member is where the recursion sits, and a union is not a data
    // constructor. `type U = number | U` describes no finite value.
    try checkTypedSourceSaying(
        \\type U = number | U;
        \\function handler(req: Request): Response {
        \\    const v: U = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "has a cycle no data constructor guards",
    );
}

test "a Bytes member does not disturb a recursive alias either way" {
    // `Bytes` is a leaf: it takes no type parameter and holds no member type,
    // so it can neither guard a cycle nor close one, and the guard set does not
    // mention it. Measured rather than argued - adding `.t_bytes` to the guard
    // set in `type_env.reachesUnguarded` changes neither of these two programs,
    // because in the first the cycle runs through the union and in the second
    // it runs through the record.
    //
    // A record guards, so the alias is contractive and the Bytes field rides
    // along.
    try checkTypedSource(
        \\type Chunk = { data: Bytes; next: Chunk | null };
        \\function handler(req: Request): Response {
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );

    // A union does not, so the same member cannot rescue it. ZTS212 fires
    // where a declared annotation names the alias, which is why the binding is
    // here and not just the alias.
    try checkTypedSourceSaying(
        \\type B = Bytes | B;
        \\function handler(req: Request): Response {
        \\    const v: B = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "has a cycle no data constructor guards",
    );
}

test "a cycle through two names is refused" {
    try checkTypedSourceSaying(
        \\type A = B;
        \\type B = A;
        \\function handler(req: Request): Response {
        \\    const v: A = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        "has a cycle no data constructor guards",
    );
}

test "negative recursion through a function parameter is refused" {
    try checkTypedSourceSaying(
        \\type Neg = (value: Neg) => number;
        \\function handler(req: Request): Response {
        \\    const v: Neg = (value) => 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "recursive type alias 'Neg' has a cycle no data constructor guards",
    );
}

// ---------------------------------------------------------------------------
// Type predicates (D1 / plan task 6)
// ---------------------------------------------------------------------------

test "an admitted type predicate narrows at its call site" {
    // The narrowed type is `string`, so assigning it to `number` is the error.
    // Before the predicate was read, the binding stayed `string | number` and
    // the same program reported the same count for the wrong reason - hence the
    // companion test below, which pins that the un-narrowed type is different.
    try checkTypedSource(
        \\function isString(v: string | number): v is string {
        \\    return typeof v === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );
}

test "a predicate whose body calls a function installs no guard" {
    // Two errors: the predicate itself (ZTS211), and the assignment that the
    // missing narrowing leaves unproven. The second is what makes this test
    // non-vacuous - it shows the guard really was withheld, not merely
    // reported.
    try checkTypedSource(
        \\function helper(v: string | number): boolean {
        \\    return typeof v === "string";
        \\}
        \\function isString(v: string | number): v is string {
        \\    return helper(v);
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        null,
    );
}

test "a predicate that returns a bare literal proves nothing" {
    try checkTypedSource(
        \\function isString(v: string | number): v is string {
        \\    return true;
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        null,
    );
}

test "a predicate that tests a different parameter is refused" {
    try checkTypedSource(
        \\function isString(v: string | number, other: string | number): v is string {
        \\    return typeof other === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw, "x")) {
        \\        return Response.json({ ok: true });
        \\    }
        \\    return Response.json({ ok: false });
        \\}
    ,
        1,
        null,
    );
}

test "admitted tests combine with && and !" {
    try checkTypedSource(
        \\function isText(v: string | number | undefined): v is string {
        \\    return v !== undefined && typeof v === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number | undefined = 1;
        \\    if (isText(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );
}

test "a test over an unknown parameter is admitted on its form, not its effect" {
    // `typeof x === "object"` narrows nothing when the declared type is
    // `unknown`, because `unknown` is not a union - and it is still exactly the
    // test a predicate is allowed to be made of. Checking admission by asking
    // whether a narrowing came out rejected this shape, which is the one the
    // corpus writes.
    try checkTypedSource(
        \\function isObject(x: unknown): x is object {
        \\    return typeof x === "object";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: unknown = 1;
        \\    if (isObject(raw)) {
        \\        return Response.json({ ok: true });
        \\    }
        \\    return Response.json({ ok: false });
        \\}
    ,
        0,
        null,
    );
}

test "a test outside the closed list is refused" {
    // `"status" in val` is not in the closed narrowing list, so the compiler
    // cannot verify the claim the annotation makes. This is the shape the
    // corpus trips ZTS211 on.
    try checkTypedSource(
        \\function isResponse(val: unknown): val is Response {
        \\    return typeof val === "object" && "status" in val;
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: unknown = 1;
        \\    if (isResponse(raw)) {
        \\        return Response.json({ ok: true });
        \\    }
        \\    return Response.json({ ok: false });
        \\}
    ,
        1,
        null,
    );
}
