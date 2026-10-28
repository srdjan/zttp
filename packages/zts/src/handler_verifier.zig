//! Compile-Time Handler Verifier
//!
//! Statically proves handler functions cannot fail in production by verifying:
//! 1. Every code path returns a Response (exhaustive return analysis)
//! 2. Result values are checked before access (result safety)
//! 3. No unreachable code after unconditional returns
//! 4. No unused variable declarations
//! 5. Match expressions are provably exhaustive or have default arms
//! 6. Optional values from virtual modules are checked before use
//!
//! This is possible because zttp's JS subset bans most non-trivial control flow:
//! no while/do-while (no back-edges), no try/catch (no exceptional paths).
//! break/continue are allowed within for-of only (forward jumps, no new back-edges).
//! The IR tree IS the control flow graph.
//! Verification is a recursive tree walk, not a fixpoint dataflow analysis.

const std = @import("std");
const SourceView = @import("zts-base").source_diagnostics.SourceView;
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const diagnostic_projection = @import("diagnostic_projection.zig");
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const type_checker_mod = @import("type_checker.zig");
const route_resolution = @import("route_resolution.zig");
const repair_intent_mod = @import("repair_intent.zig");

pub const RepairIntent = repair_intent_mod.RepairIntent;

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const TypeEnv = type_env_mod.TypeEnv;
const TypeChecker = type_checker_mod.TypeChecker;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;

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
    // Return analysis (Check 1)
    missing_return_path,

    // Result checking (Check 2)
    unchecked_result_value,

    // Unreachable code (Check 3)
    unreachable_after_return,

    // Dead variables (Check 4)
    unused_variable,
    unused_import,

    // Match expression (Check 5)

    // Optional checking (Check 6)
    unchecked_optional_use,
    unchecked_optional_access,

    // State isolation (Check 7)
    module_scope_mutation,

    // WebSocket event exports (Check 8)
    // Author-declared spec discharge (Check 9) does NOT appear here. ZTS500,
    // ZTS501 and ZTS502 are emitted through
    // `contract_types.SpecDiagnostic.Kind` by `spec_discharge.zig`; this enum
    // carried three variants naming the same three codes that no code path
    // ever constructed. Because the coverage gate keys on the code and the
    // codes are live, nothing could report the variants as dead. Their
    // registry rows now hang on the enum that emits them.
};

/// Which refused Result use a ZTS303 diagnostic reports. The label changes the
/// message and the repair plan. It never changes which programs are refused.
pub const ResultShape = enum {
    unchecked_value,
    unchecked_error,
    error_on_ok_path,
    unrecognized_guard,
    closure_read,
    flat_guard,
    unknown_member,
    computed_key,
    method_call,
    alias_or_reassignment,
    function_alias,
    call_argument,
    returned,
    collection_member,
    spread,
    match_subject,
    unbound_call,
    ambiguous_upvalue,
    depth_limit,
    other_use,

    pub fn asString(self: ResultShape) []const u8 {
        return @tagName(self);
    }

    pub fn message(self: ResultShape) []const u8 {
        return switch (self) {
            .unchecked_value => "result.value accessed without checking result.ok first",
            .unchecked_error => "result.error read where result.ok is not known to be false",
            .error_on_ok_path => "result.error read on a path where result.ok is true",
            .unrecognized_guard => "result.value read after a check that the proof does not recognize",
            .closure_read => "a closure reads a Result without its own ok check",
            .flat_guard => "a Result is read inside an assert, throw, switch, or try statement without a check before it",
            .unknown_member => "a Result member other than ok, value, error, errors, or unwrap is read",
            .computed_key => "a Result is read with a computed key that is not a string literal",
            .method_call => "a method is called on a Result binding",
            .alias_or_reassignment => "a Result is copied or reassigned",
            .function_alias => "a Result function is named without a call",
            .call_argument => "a Result is passed as a call argument",
            .returned => "a Result is returned from a function",
            .collection_member => "a Result is stored in an object or an array",
            .spread => "a Result is spread",
            .match_subject => "match is used on a Result",
            .unbound_call => "a Result call is used without a const binding",
            .ambiguous_upvalue => "a captured name matches two Result bindings",
            .depth_limit => "an expression is too deep to check for Result use",
            .other_use => "a Result is used in a way that the proof does not model",
        };
    }

    pub fn help(self: ResultShape) []const u8 {
        return switch (self) {
            .unchecked_value => "check result.ok before accessing result.value:\n           if (result.ok) { ... result.value ... }",
            .unchecked_error => "read result.error after if (!result.ok), or write result.error ?? fallback",
            .error_on_ok_path => "result.error is undefined when ok is true: read it after if (result.ok) return ..., or write result.error ?? fallback",
            .unrecognized_guard => "use exactly if (result.ok) or if (!result.ok) on the const bound to the Result call: === true, isOk(), isErr(), and match are not checks",
            .closure_read => "a check outside a closure does not reach it: check result.ok inside the closure before the read",
            .flat_guard => "a check inside such a statement covers nothing: check result.ok in an if statement before the statement",
            .unknown_member => "read only result.ok, result.value, result.error, or result.errors",
            .computed_key => "use result.ok, result.value, or result.error as a plain member read",
            .method_call => "a Result has no methods: use if (result.ok) or if (!result.ok), then read result.value or result.error",
            .alias_or_reassignment => "keep each Result in the one const bound to its call: check result.ok, then copy result.value",
            .function_alias => "call the Result function directly: const result = fn(...)",
            .call_argument => "check result.ok, then pass result.value: pass the Result itself only to a zttp:result function that takes a Result",
            .returned => "check result.ok, then return result.value or a Response",
            .collection_member => "check result.ok, then store result.value",
            .spread => "check result.ok, then spread result.value",
            .match_subject => "use if (!result.ok) { return ...; } and then read result.value",
            .unbound_call => "bind the call to a const, then check its ok: const r = call(...); if (!r.ok) { return ...; }",
            .ambiguous_upvalue => "give each Result binding in the file a unique name",
            .depth_limit => "split the expression into const bindings",
            .other_use => "use a Result only through result.ok, result.value, result.error, and result.errors",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    /// For unchecked_result_value: the virtual module that produced the result.
    /// Borrowed from the module binding registry - always valid.
    source_module: ?[]const u8 = null,
    /// For unchecked_result_value: the function that produced the result.
    /// Borrowed from the module binding registry - always valid.
    source_func: ?[]const u8 = null,
    /// True when the diagnostic came from a route function checked as a
    /// request root rather than from the exported handler.
    route_root: bool = false,
    /// Typed repair primitive the agent uses to pick an apply step directly.
    /// `null` when no single canonical
    /// repair applies (e.g. unused_variable — needs a free-form delete).
    repair_intent: ?RepairIntent = null,
    /// For unchecked_result_value from the Result walk: the refused shape.
    result_shape: ?ResultShape = null,
};

/// Return status for a statement or block - used by exhaustive return analysis.
const ReturnStatus = enum {
    always, // every path through this node returns
    never, // no path through this node returns
    sometimes, // some paths return, some don't
};

/// Pure path-return analysis for an arbitrary function body. Returns true
/// when every path through `body` reaches a `return`. Unlike the verifier's
/// `stmtReturns`, this emits no diagnostics and needs no `HandlerVerifier`
/// instance, so capsule discharge can call it per-helper to settle the
/// `total` proof property. Expression-bodied arrows count as total: the
/// expression is itself the return value.
pub fn functionAlwaysReturns(ir_view: IrView, body: NodeIndex) bool {
    const tag = ir_view.getTag(body) orelse return false;
    // Exhaustive over `NodeTag` on purpose. This answer is written straight
    // into `CapsuleFacts.total` by `function_specs.discharge`, which feeds
    // `spec_discharge` and the `response_total` property, and the switch used
    // to end in `else => true`: a statement tag added to the IR and not added
    // to the false arm became silently "always returns", granting a proof
    // instead of costing one. There is no catch-all now, so a new tag is a
    // compile error and someone has to classify it. If a catch-all is ever
    // reintroduced it returns `false` - the unknown case must cost a refusal.
    return switch (tag) {
        // Bodies the walk understands.
        .block, .program => pureBlockReturns(ir_view, body) == .always,
        .return_stmt => true,
        .if_stmt => pureStmtReturns(ir_view, body) == .always,

        // An expression-bodied arrow: the expression IS the return value, so
        // every path returns. Only shapes that can stand alone as a complete
        // expression body belong here.
        .lit_int,
        .lit_float,
        .lit_string,
        .lit_bool,
        .lit_null,
        .lit_undefined,
        .identifier,
        .binary_op,
        .unary_op,
        .ternary,
        .call,
        .method_call,
        .member_access,
        .computed_access,
        .optional_chain,
        .assignment,
        .array_literal,
        .object_literal,
        .function_expr,
        .arrow_function,
        .await_expr,
        .yield_expr,
        .sequence_expr,
        .comma_expr,
        .match_expr,
        => true,

        // Every remaining tag: a statement other than the three handled above,
        // a declaration, a pattern, a module form, or a sub-node that is never
        // a function body on its own (an object member, a spread, a match arm
        // or pattern, a list marker). None of them return on every path, and
        // for the sub-nodes `false` is the fail-closed answer to a shape that
        // should not have reached here at all.
        .object_property,
        .object_method,
        .object_getter,
        .object_setter,
        .object_spread,
        .spread,
        .match_arm,
        .match_pattern,
        .match_type_test,
        .expr_stmt,
        .var_decl,
        .for_stmt,
        .for_of_stmt,
        .for_in_stmt,
        .while_stmt,
        .do_while_stmt,
        .switch_stmt,
        .case_clause,
        .assert_stmt,
        .throw_stmt,
        .break_stmt,
        .continue_stmt,
        .try_stmt,
        .labeled_stmt,
        .function_decl,
        .array_pattern,
        .pattern_element,
        .pattern_rest,
        .pattern_default,
        .import_decl,
        .import_specifier,
        .import_default,
        .import_namespace,
        .export_decl,
        .export_specifier,
        .export_default,
        .export_all,
        .param_list,
        .arg_list,
        .stmt_list,
        => false,
    };
}

fn pureStmtReturns(ir_view: IrView, node: NodeIndex) ReturnStatus {
    const tag = ir_view.getTag(node) orelse return .never;
    return switch (tag) {
        .return_stmt => .always,
        .block, .program => pureBlockReturns(ir_view, node),
        .if_stmt => pureIfReturns(ir_view, node),
        // exhaustive: an unlisted statement does not establish a return.
        // `.never` can only cost the total-return proof.
        else => .never,
    };
}

fn pureBlockReturns(ir_view: IrView, node: NodeIndex) ReturnStatus {
    const block = ir_view.getBlock(node) orelse return .never;
    if (block.stmts_count == 0) return .never;
    var last_status: ReturnStatus = .never;
    var i: u16 = 0;
    while (i < block.stmts_count) : (i += 1) {
        const stmt_idx = ir_view.getListIndex(block.stmts_start, i);
        const status = pureStmtReturns(ir_view, stmt_idx);
        if (status == .always) return .always;
        last_status = status;
    }
    return last_status;
}

fn pureIfReturns(ir_view: IrView, node: NodeIndex) ReturnStatus {
    const if_stmt = ir_view.getIfStmt(node) orelse return .never;
    const then_status = pureStmtReturns(ir_view, if_stmt.then_branch);
    if (if_stmt.else_branch == null_node) {
        return if (then_status == .always) .sometimes else .never;
    }
    const else_status = pureStmtReturns(ir_view, if_stmt.else_branch);
    if (then_status == .always and else_status == .always) return .always;
    if (then_status == .never and else_status == .never) return .never;
    return .sometimes;
}

/// Tracks a local binding for result checking and dead variable detection.
const BindingState = struct {
    scope_id: ir.ScopeId, // scope that owns this binding
    slot: u16,
    ref_count: u16,
    decl_node: NodeIndex,
    name_idx: u16, // string constant index for the name (0 = unknown)
    /// For result bindings: the virtual module specifier (e.g. "zttp:auth").
    /// Borrowed from module binding registry string - always valid.
    source_module: ?[]const u8 = null,
    /// For result bindings: the function name (e.g. "jwtVerify").
    /// Borrowed from module binding registry string - always valid.
    source_func: ?[]const u8 = null,
    /// The declared name. A closure reads the binding through an upvalue
    /// reference, which names it by this atom and not by scope and slot.
    name_atom: u16 = 0,

    fn key(self: BindingState) u32 {
        return bindingKey(self.scope_id, self.slot);
    }
};

/// One name bound by an import specifier, and whether anything names it back.
///
/// `used` rather than a count: the question is only "did anything reference
/// this", and a count would invite reporting "used once" as if that meant
/// something.
const ImportBindingState = struct {
    scope_id: ir.ScopeId,
    slot: u16,
    /// The specifier node, so the diagnostic points at the binding the author
    /// wrote rather than at the whole import statement.
    decl_node: NodeIndex,
    name_atom: u16,
    used: bool,
};

// ---------------------------------------------------------------------------
// Known tracked functions from virtual modules
// ---------------------------------------------------------------------------

const OptionalKind = enum { optional_string, optional_object };

/// What a virtual module function produces that requires caller-side checking.
const FunctionProduces = enum {
    result, // Result object - must check .ok before .value
    optional_string, // string | undefined - must narrow before use
    optional_object, // object | undefined - must narrow before use

    fn toOptionalKind(self: FunctionProduces) ?OptionalKind {
        return switch (self) {
            .optional_string => .optional_string,
            .optional_object => .optional_object,
            .result => null,
        };
    }
};

const builtin_modules = @import("zts-engine").builtin_modules;
const module_facts_mod = @import("module_facts.zig");
const mb = @import("zts-engine").module_binding;

/// Look up whether a function produces a value requiring caller-side checking.
/// Reads from the module binding registry instead of a hardcoded table.
fn lookupTrackedFunction(module_specifier: []const u8, name: []const u8) ?FunctionProduces {
    const entry = builtin_modules.findExport(module_specifier, name) orelse return null;
    return switch (entry.func.returns) {
        .result => .result,
        .optional_string => .optional_string,
        .optional_object => .optional_object,
        // Keep this list exhaustive so a new return kind cannot silently skip
        // caller-side checking. optional_number is listed explicitly to keep
        // the current verifier behavior unchanged; supporting it needs a new
        // OptionalKind and its own diagnostics.
        .boolean,
        .number,
        .string,
        .object,
        .undefined,
        .unknown,
        .optional_number,
        .result_list,
        .result_fn,
        .dict,
        .bytes,
        => null,
    };
}

const bindingKey = @import("binding_key.zig").packBindingKey;
const findHandlerFunction = @import("handler_function.zig").findHandlerFunction;

/// One change to a checked flag, kept so the enclosing block can restore the
/// value the flag had before the change.
const CheckedChange = struct {
    const Flag = enum { optional_narrowed };
    flag: Flag,
    key: u32,
    old: bool,
};

const OptionalFnSlot = struct {
    slot: u16,
    kind: OptionalKind,
};

const OptionalBindingState = struct {
    scope_id: ir.ScopeId,
    slot: u16,
    kind: OptionalKind,
    narrowed: bool,
    decl_node: NodeIndex,

    fn key(self: OptionalBindingState) u32 {
        return bindingKey(self.scope_id, self.slot);
    }
};

/// The names of the ambient globals that return a Result. `abi_types.zig`
/// registers each of them; `proof_ir.zig` holds the same list for the lowering.
const result_globals = [_][]const u8{ "requestJson", "requestText" };

/// What a Result call names: the export that produces it, or null for an
/// ambient global. Strings are borrowed from the module binding registry.
const ResultCallee = struct {
    func: ?*const mb.FunctionBinding,
    module_name: ?[]const u8,
    func_name: []const u8,
};

/// How one identifier relates to the Result bindings of the program.
const ResultReference = union(enum) {
    /// Not a Result binding.
    none,
    /// The index of the binding in `result_bindings`.
    ordinal: u32,
    /// An upvalue whose name matches several Result bindings.
    ambiguous,
};

/// Where a Result use sits. Only these positions are safe for an unbound
/// Result or a Result binding. Every other position is a use the verifier
/// does not model, and it is refused.
/// The positions after `result_arg` only name the refusal. They never make a
/// use safe.
const ResultPosition = enum {
    other,
    discard,
    nullish_left,
    optional_object,
    result_arg,
    alias,
    argument,
    returned,
    collection_member,
    spread,
    matched,
    callee,
};

/// One check that holds for a Result binding over a region of the walk. An
/// `ok` cover permits a read of `.value`; an `err` cover permits a read of
/// `.error`.
const ResultCover = struct {
    ordinal: u32,
    polarity: ResultPolarity,
};

const ResultPolarity = enum { ok, err };

const NarrowingBranch = enum { then, then_returns_early };

const NarrowingInfo = struct {
    slot: u16,
    scope_id: ir.ScopeId,
    branch: NarrowingBranch,
};

// ---------------------------------------------------------------------------
// HandlerVerifier
// ---------------------------------------------------------------------------

pub const HandlerVerifier = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    type_env: ?*const TypeEnv,
    type_checker: ?*TypeChecker,
    diagnostics: std.ArrayList(Diagnostic),

    // Result checking state. A Result binding is a `var_decl` whose initializer
    // is a direct call that returns a Result; its index is its ordinal. The
    // covers are the checks in force at the current point of the walk.
    result_bindings: std.ArrayList(BindingState),
    result_covers: std.ArrayList(ResultCover),
    /// Covers below this index belong to an enclosing function and do not
    /// reach the function being walked.
    result_cover_base: usize = 0,
    /// Set while a statement that has no guard structure is walked. A guard
    /// inside it covers nothing, as in the proof lowering.
    result_flat: bool = false,
    /// Set while the condition of an `if` that is not a guard is walked.
    result_in_condition: bool = false,
    /// Bindings whose `ok` was read in a condition that is not a guard.
    result_unrecognized: std.ArrayList(u32),
    /// Request roots other than the handler. A refusal inside one carries
    /// `route_root`.
    result_route_roots: []const NodeIndex = &.{},
    result_in_route_root: bool = false,
    result_handler: NodeIndex = null_node,
    /// How many functions enclose the point of the walk.
    result_function_depth: u32 = 0,

    // Optional checking state (Check 6)
    optional_bindings: std.ArrayList(OptionalBindingState),
    optional_function_slots: std.ArrayList(OptionalFnSlot),
    /// Changes to `narrowed`, in order, so a block can undo what
    /// it changed when it ends. See `journalMark` and `journalRestore`.
    checked_journal: std.ArrayList(CheckedChange),
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the verifier. Null means build a private one.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,

    // Dead variable tracking
    all_bindings: std.ArrayList(BindingState),

    // Dead import tracking (Check 5). Kept apart from `all_bindings` because
    // the two report different codes and are counted over different scopes:
    // a variable is dead if the handler body never names it, an import is
    // dead if NO function in the module does.
    import_bindings: std.ArrayList(ImportBindingState),

    // State isolation (Check 7)
    handler_scope_id: ?ir.ScopeId = null,
    has_module_mutation: bool = false,
    /// Local bindings initialised from a module-scope or builtin binding. A
    /// member write through one of them writes shared state.
    shared_aliases: std.ArrayList(u32) = .empty,
    /// A route call exists, but its complete target set is not known. The
    /// caller uses this separately from `has_module_mutation`: unknown code
    /// makes state isolation unproven without claiming an observed mutation.
    unresolved_route_dispatch: bool = false,
    /// Sticky failure for every tracked binding and diagnostic. These are
    /// proof inputs, so a partial verifier result must never escape.
    allocation_failed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        type_env: ?*const TypeEnv,
        type_checker: ?*TypeChecker,
    ) HandlerVerifier {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .type_env = type_env,
            .type_checker = type_checker,
            .diagnostics = .empty,
            .result_bindings = .empty,
            .result_covers = .empty,
            .result_unrecognized = .empty,
            .optional_bindings = .empty,
            .optional_function_slots = .empty,
            .checked_journal = .empty,
            .all_bindings = .empty,
            .import_bindings = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *HandlerVerifier) void {
        self.diagnostics.deinit(self.allocator);
        self.result_bindings.deinit(self.allocator);
        if (self.owned_facts) |*owned| owned.deinit();
        self.result_covers.deinit(self.allocator);
        self.result_unrecognized.deinit(self.allocator);
        self.optional_bindings.deinit(self.allocator);
        self.optional_function_slots.deinit(self.allocator);
        self.checked_journal.deinit(self.allocator);
        self.all_bindings.deinit(self.allocator);
        self.import_bindings.deinit(self.allocator);
        self.shared_aliases.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /// Run all verification checks on a handler function node.
    /// Returns the number of error-severity diagnostics.
    pub fn verify(self: *HandlerVerifier, handler_func: NodeIndex) !u32 {
        if (self.type_checker) |tc| try tc.ensureHealthy();
        // Phase 1: Scan imports for result-producing function bindings
        self.scanImports();

        const facts = self.resolveFacts() orelse return error.OutOfMemory;
        const route_resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var route_roots = try route_resolver.routeRoots(self.allocator);
        defer route_roots.deinit(self.allocator);

        // Phase 2: Exhaustive return analysis on the handler body
        const handler = self.ir_view.getFunction(handler_func) orelse {
            if (self.allocation_failed) return error.OutOfMemory;
            return 0;
        };
        if (route_roots.unresolved) self.addUnresolvedRouteDiagnostics(handler_func);
        self.verifyRequestRoot(handler_func, handler);
        for (route_roots.functions.items) |route_function| {
            if (route_function == handler_func) continue;
            const function = self.ir_view.getFunction(route_function) orelse {
                self.addUnresolvedRouteDiagnostics(route_function);
                continue;
            };
            const diagnostic_start = self.diagnostics.items.len;
            self.verifyRequestRoot(route_function, function);
            for (self.diagnostics.items[diagnostic_start..]) |*diag| {
                diag.route_root = true;
            }
        }
        try self.checkUnresolvedRouteDispatches(&route_resolver);

        // Phase 4: Result uses, over every function of the program and not
        // only the request roots. A Result in a sibling helper is as unchecked
        // as one in the handler.
        self.result_route_roots = route_roots.functions.items;
        defer self.result_route_roots = &.{};
        self.checkResultUses(handler_func);

        // Phase 5: Report unused variables (scope-aware tracking)
        self.reportUnusedVariables();

        // Phase 6: Report unused imports (module-scoped, see markUsedImports)
        self.collectImportBindings();
        self.markUsedImports();
        self.reportUnusedImports();
        if (self.type_checker) |tc| try tc.ensureHealthy();
        if (self.allocation_failed) return error.OutOfMemory;

        // Count errors
        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        return error_count;
    }

    /// Apply the handler-scoped checks to one request entry point. A route
    /// function receives the same untrusted request and owns the same proof
    /// obligations as the exported handler that dispatches to it.
    fn verifyRequestRoot(self: *HandlerVerifier, function_node: NodeIndex, function: Node.FunctionExpr) void {
        self.handler_scope_id = function.scope_id;
        if (self.stmtReturns(function.body) != .always) {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .missing_return_path,
                .node = function_node,
                .message = "not all code paths return a Response",
                .help = "ensure every branch (if/else, switch/default) ends with a return statement",
                .repair_intent = .add_trailing_return,
            });
        }
        self.walkForResultsAndRefs(function.body);
    }

    fn checkUnresolvedRouteDispatches(
        self: *HandlerVerifier,
        resolver: *const route_resolution.Resolver,
    ) !void {
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const call = self.ir_view.getCall(idx) orelse continue;
            var targets = (try resolver.resolveDispatch(self.allocator, call.callee)) orelse continue;
            defer targets.deinit(self.allocator);
            if (targets.unresolved) self.addUnresolvedRouteDiagnostics(idx);
        }
    }

    /// One unresolved dispatch costs both verifier properties. These existing
    /// diagnostic kinds are the inputs that decide response_total and
    /// results_safe, so the unknown target cannot silently prove either one.
    fn addUnresolvedRouteDiagnostics(self: *HandlerVerifier, node: NodeIndex) void {
        self.unresolved_route_dispatch = true;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .missing_return_path,
            .node = node,
            .message = "route dispatch target cannot be resolved, so response totality is unproven",
            .help = "use a stable literal routerMatch table whose entries are function declarations",
        });
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unchecked_result_value,
            .node = node,
            .message = "route dispatch target cannot be resolved, so result safety is unproven",
            .help = "use a stable literal routerMatch table whose entries are function declarations",
        });
    }

    /// Get all diagnostics.
    pub fn getDiagnostics(self: *const HandlerVerifier) []const Diagnostic {
        return self.diagnostics.items;
    }

    /// Format diagnostics to a writer. Requires source text for context lines.
    pub fn formatDiagnostics(self: *const HandlerVerifier, source: SourceView, writer: anytype) !void {
        try diagnostic_projection.writeAll(.verifier, source, self.diagnostics.items, self.ir_view, writer);
    }

    /// Returns true if there are any error-severity diagnostics.
    pub fn hasErrors(self: *const HandlerVerifier) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Check 1: Exhaustive Return Analysis
    // -----------------------------------------------------------------------

    /// Determine whether a statement node always, never, or sometimes returns.
    fn stmtReturns(self: *HandlerVerifier, node: NodeIndex) ReturnStatus {
        const tag = self.ir_view.getTag(node) orelse return .never;
        return switch (tag) {
            .return_stmt => .always,

            .block, .program => self.blockReturns(node),

            .if_stmt => self.ifReturns(node),

            .for_of_stmt => self.forOfReturns(node),

            .var_decl,
            .expr_stmt,
            .import_decl,
            .export_decl,
            .function_decl,
            .break_stmt,
            .continue_stmt,
            => .never,

            // exhaustive: an unlisted statement does not establish a return.
            // `.never` can only cost the total-return proof.
            else => .never,
        };
    }

    /// Analyze return status of a block. Also detects unreachable code.
    fn blockReturns(self: *HandlerVerifier, node: NodeIndex) ReturnStatus {
        const block = self.ir_view.getBlock(node) orelse return .never;
        if (block.stmts_count == 0) return .never;

        var last_status: ReturnStatus = .never;
        var i: u16 = 0;
        while (i < block.stmts_count) : (i += 1) {
            const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
            const status = self.stmtReturns(stmt_idx);

            if (status == .always) {
                // Check for unreachable statements after this one
                if (i + 1 < block.stmts_count) {
                    const next_stmt = self.ir_view.getListIndex(block.stmts_start, i + 1);
                    // Skip function declarations - they're hoisted logically
                    const next_tag = self.ir_view.getTag(next_stmt);
                    if (next_tag != null and next_tag.? != .function_decl) {
                        self.addDiagnostic(.{
                            .severity = .warning,
                            .kind = .unreachable_after_return,
                            .node = next_stmt,
                            .message = "unreachable code after return statement",
                            .help = "remove the unreachable code, or restructure the control flow",
                        });
                    }
                }
                return .always;
            }
            last_status = status;
        }

        return last_status;
    }

    /// Analyze return status of an if statement.
    fn ifReturns(self: *HandlerVerifier, node: NodeIndex) ReturnStatus {
        const if_stmt = self.ir_view.getIfStmt(node) orelse return .never;

        const then_status = self.stmtReturns(if_stmt.then_branch);

        // No else clause: can never guarantee return
        if (if_stmt.else_branch == null_node) {
            if (then_status == .always) {
                // The then branch always returns, but there's no else.
                // This is only a problem if this if-stmt is in a terminal position.
                // We report it as "sometimes" and let the parent block handle it.
                return .sometimes;
            }
            return .never;
        }

        // Has else clause: combine both branches
        const else_status = self.stmtReturns(if_stmt.else_branch);

        if (then_status == .always and else_status == .always) return .always;
        if (then_status == .never and else_status == .never) return .never;
        return .sometimes;
    }

    /// Analyze return status of a switch statement.
    /// for-of body returns .never because the iterable could be empty.
    fn forOfReturns(_: *HandlerVerifier, _: NodeIndex) ReturnStatus {
        return .never;
    }

    // -----------------------------------------------------------------------
    // Check 2: Result Checking
    // -----------------------------------------------------------------------

    /// Scan top-level import declarations to identify which local bindings
    /// Resolve the index to read: injected, or private on first use.
    fn resolveFacts(self: *HandlerVerifier) ?*const module_facts_mod.ModuleFacts {
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

    /// Map local binding slots to tracked virtual module functions
    /// (result-producing or optional-producing).
    ///
    /// The legacy scan pre-screened each module for having ANY tracked export
    /// before looking at its specifiers. That screen is dropped here because it
    /// is a pure short-circuit: `lookupTrackedFunction` goes through
    /// `findExport`, so a module with no tracked export returns null for every
    /// name anyway, and a module outside `builtin_modules.all` returns null too.
    /// The differential test below is what establishes that rather than
    /// assuming it.
    fn scanImports(self: *HandlerVerifier) void {
        const facts = self.resolveFacts() orelse return;
        for (facts.imports.items) |rec| {
            if (rec.resolution != .builtin) continue;
            const produces = lookupTrackedFunction(rec.module_specifier, rec.imported_name) orelse continue;
            switch (produces) {
                // A Result source is classified from the import index at the
                // call (`resultCallee`), not from a slot list kept here.
                .result => {},
                .optional_string, .optional_object => self.optional_function_slots.append(self.allocator, .{
                    .slot = rec.slot,
                    .kind = produces.toOptionalKind().?,
                }) catch self.markAllocationFailure(),
            }
        }
    }

    // -----------------------------------------------------------------------
    // Check 5: Dead Imports
    // -----------------------------------------------------------------------

    /// Collect every name an import specifier binds.
    ///
    /// Scans the node array rather than walking from a root, because the
    /// verifier is handed a handler function and never the program node.
    fn collectImportBindings(self: *HandlerVerifier) void {
        const count = self.ir_view.nodeCount();
        var idx: NodeIndex = 0;
        while (idx < count) : (idx += 1) {
            if (self.ir_view.getTag(idx) != .import_specifier) continue;
            const spec = self.ir_view.getImportSpec(idx) orelse continue;
            self.import_bindings.append(self.allocator, .{
                .scope_id = spec.local_binding.scope_id,
                .slot = spec.local_binding.slot,
                .decl_node = idx,
                .name_atom = spec.local_binding.name_atom,
                .used = false,
            }) catch self.markAllocationFailure();
        }
    }

    /// Mark an import used if any identifier anywhere in the module names it.
    ///
    /// Deliberately the whole node array and not the handler body. The rest of
    /// this verifier is handler-scoped, which is right for a dead *variable* -
    /// a local the handler never names is dead whatever the rest of the module
    /// does. An import is module-scoped: `import { sha256 }` referenced only
    /// inside a helper the handler calls is used, and counting it over the
    /// handler body alone would report every helper's imports as dead.
    ///
    /// Scanning all nodes also counts references from unreachable code, which
    /// over-approximates "used". That is the safe direction: it suppresses a
    /// warning, and never invents one.
    fn markUsedImports(self: *HandlerVerifier) void {
        if (self.import_bindings.items.len == 0) return;
        const count = self.ir_view.nodeCount();
        var idx: NodeIndex = 0;
        while (idx < count) : (idx += 1) {
            if (self.ir_view.getTag(idx) != .identifier) continue;
            const binding = self.ir_view.getBinding(idx) orelse continue;
            const target = bindingKey(binding.scope_id, binding.slot);
            for (self.import_bindings.items) |*imported| {
                if (bindingKey(imported.scope_id, imported.slot) == target) {
                    imported.used = true;
                    break;
                }
            }
        }
    }

    fn reportUnusedImports(self: *HandlerVerifier) void {
        for (self.import_bindings.items) |imported| {
            if (imported.used) continue;

            // Same suppression convention as an unused variable.
            if (self.resolveAtomName(imported.name_atom)) |name| {
                if (name.len > 0 and name[0] == '_') continue;
            }

            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .unused_import,
                .node = imported.decl_node,
                .message = "imported binding is never used",
                .help = "remove the unused import, or prefix with '_' to suppress this warning",
            });
        }
    }

    /// Walk the handler body to track result bindings and reference counts.
    fn walkForResultsAndRefs(self: *HandlerVerifier, node: NodeIndex) void {
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .block, .program => {
                const block = self.ir_view.getBlock(node) orelse return;
                // A guard in this block holds for the rest of this block and no
                // further: restore every checked flag the block changed when it ends.
                const mark = self.journalMark();
                defer self.journalRestore(mark);
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
                    self.walkForResultsAndRefs(stmt_idx);
                }
            },
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;

                // Track this binding for dead variable detection (scope-aware).
                self.all_bindings.append(self.allocator, .{
                    .scope_id = decl.binding.scope_id,
                    .slot = decl.binding.slot,
                    .ref_count = 0,
                    .decl_node = node,
                    .name_idx = 0,
                    .name_atom = decl.binding.name_atom,
                }) catch self.markAllocationFailure();

                if (decl.init != null_node) {
                    self.walkExprForRefs(decl.init);
                    self.recordSharedAlias(decl);

                    // Check 6: track optional-producing calls
                    // Skip if RHS is `optionalCall() ?? default` (nullish coalesce resolves)
                    if (!self.isNullishCoalesceWithOptionalCall(decl.init)) {
                        if (self.isOptionalProducingCall(decl.init)) |kind| {
                            self.optional_bindings.append(self.allocator, .{
                                .scope_id = decl.binding.scope_id,
                                .slot = decl.binding.slot,
                                .kind = kind,
                                .narrowed = false,
                                .decl_node = node,
                            }) catch self.markAllocationFailure();
                        }
                    }
                }
            },
            .if_stmt => {
                const if_stmt = self.ir_view.getIfStmt(node) orelse return;

                // Always walk the condition for ref-counting (identifiers in
                // conditions must be counted regardless of which extraction path
                // matches). The extraction helpers are read-only so order is safe.
                self.walkExprForRefs(if_stmt.condition);

                if (self.extractOptionalNarrowingCheck(if_stmt.condition)) |info| {
                    // Check 6: optional narrowing via if (val) or if (val !== undefined)
                    switch (info.branch) {
                        .then => {
                            // if (val) - narrowed in then-branch only
                            self.setOptionalNarrowed(info.slot, info.scope_id, true);
                            self.walkScoped(if_stmt.then_branch);
                            self.setOptionalNarrowed(info.slot, info.scope_id, false);
                            if (if_stmt.else_branch != null_node) {
                                self.walkScoped(if_stmt.else_branch);
                            }
                        },
                        .then_returns_early => {
                            // if (!val) { return ...; } - code after is narrowed
                            self.walkScoped(if_stmt.then_branch);

                            const then_returns = self.stmtReturnsQuick(if_stmt.then_branch);
                            if (then_returns == .always) {
                                // Then branch always returns, so subsequent code is narrowed
                                self.setOptionalNarrowed(info.slot, info.scope_id, true);
                            }

                            if (if_stmt.else_branch != null_node) {
                                self.setOptionalNarrowed(info.slot, info.scope_id, true);
                                self.walkScoped(if_stmt.else_branch);
                                // Don't restore if then_returns - leave narrowed for subsequent code
                                if (then_returns != .always) {
                                    self.setOptionalNarrowed(info.slot, info.scope_id, false);
                                }
                            }
                        },
                    }
                } else {
                    self.walkScoped(if_stmt.then_branch);
                    if (if_stmt.else_branch != null_node) {
                        self.walkScoped(if_stmt.else_branch);
                    }
                }
            },
            .for_of_stmt => {
                const for_iter = self.ir_view.getForIter(node) orelse return;
                self.walkExprForRefs(for_iter.iterable);
                self.killFlagsAssignedIn(for_iter.body);
                self.walkScoped(for_iter.body);
            },
            .return_stmt => {
                const opt_val = self.ir_view.getOptValue(node);
                if (opt_val) |val| {
                    self.walkExprForRefs(val);
                }
            },
            .expr_stmt => {
                const opt_val = self.ir_view.getOptValue(node);
                if (opt_val) |val| {
                    self.walkExprForRefs(val);
                }
            },
            .assert_stmt => {
                const stmt = self.ir_view.getAssertStmt(node) orelse return;
                self.walkExprForRefs(stmt.condition);
                self.walkExprForRefs(stmt.error_expr);
            },
            .function_decl => {
                const func = self.ir_view.getFunctionOfDecl(node) orelse return;
                self.walkNestedFunctionBody(func.body);
            },
            // exhaustive: every statement kind not named above descends through
            // the shared expression-child map, so a node kind that holds code
            // is walked by default. Each child gets its own journal span, so a
            // guard in one child never clears the code after the statement.
            else => {
                var it = self.ir_view.expressionChildren(node);
                while (it.next()) |child| self.walkScopedChild(child);
            },
        }
    }

    /// True for a node kind that `walkForResultsAndRefs` handles.
    fn isStatementTag(tag: NodeTag) bool {
        return switch (tag) {
            .expr_stmt,
            .var_decl,
            .if_stmt,
            .for_stmt,
            .for_of_stmt,
            .for_in_stmt,
            .while_stmt,
            .do_while_stmt,
            .switch_stmt,
            .case_clause,
            .return_stmt,
            .assert_stmt,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .block,
            .labeled_stmt,
            .function_decl,
            .import_decl,
            .export_decl,
            .program,
            .stmt_list,
            => true,
            // exhaustive: every other tag is an expression, a pattern, or a leaf. Those
            // belong to the expression walk, which descends through the same child map.
            else => false,
        };
    }

    /// Walk a child found by the shared child map: a statement goes to the
    /// statement walk and anything else to the expression walk.
    fn walkChild(self: *HandlerVerifier, child: NodeIndex) void {
        const tag = self.ir_view.getTag(child) orelse return;
        if (isStatementTag(tag)) {
            self.walkForResultsAndRefs(child);
        } else {
            self.walkExprForRefs(child);
        }
    }

    /// `walkChild` in its own journal span.
    fn walkScopedChild(self: *HandlerVerifier, child: NodeIndex) void {
        const mark = self.journalMark();
        defer self.journalRestore(mark);
        self.walkChild(child);
    }

    /// Walk the body of a nested function (declaration, expression, or arrow).
    /// A closure can run at any later time, so no narrowing made outside it
    /// holds inside it: every flag is cleared for the walk and restored exactly
    /// after. A narrowing made inside the body is undone with the walk. A kill
    /// made inside the body survives, because the closure may have run:
    /// `killCheckedFlag` rewrites the journal entries, so the restore leaves the
    /// flag false.
    fn walkNestedFunctionBody(self: *HandlerVerifier, body: NodeIndex) void {
        if (body == null_node) return;
        const mark = self.journalMark();
        defer self.journalRestore(mark);
        for (self.optional_bindings.items) |ob| {
            self.setCheckedFlag(.optional_narrowed, ob.key(), false);
        }
        self.walkChild(body);
    }

    /// Walk an expression for reference counting and result access checking.
    fn walkExprForRefs(self: *HandlerVerifier, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .identifier => {
                const binding = self.bindingOf(node) orelse return;
                self.incrementRefCount(binding);
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return;
                self.walkExprForRefs(member.object);

                // optional_chain (val?.prop) safely handles undefined - skip optional check
                if (tag == .member_access) {
                    self.checkOptionalObjectAccess(member, node);
                }
            },
            .binary_op => {
                const binary = self.ir_view.getBinary(node) orelse return;
                self.walkExprForRefs(binary.left);
                self.walkExprForRefs(binary.right);

                // Check 6: optional used in non-nullish, non-comparison binary ops
                if (binary.op != .nullish and
                    binary.op != .strict_eq and binary.op != .strict_neq)
                {
                    self.checkOptionalUse(binary.left);
                    self.checkOptionalUse(binary.right);
                }
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node) orelse return;
                self.walkExprForRefs(unary.operand);
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return;
                self.walkExprForRefs(call.callee);
                var i: u8 = 0;
                while (i < call.args_count) : (i += 1) {
                    const arg_idx = self.ir_view.getListIndex(call.args_start, i);
                    self.walkExprForRefs(arg_idx);
                    // Check 6: optional passed as argument
                    self.checkOptionalUse(arg_idx);
                }
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return;
                self.walkExprForRefs(ternary.condition);
                self.walkExprForRefs(ternary.then_branch);
                self.walkExprForRefs(ternary.else_branch);
            },
            .match_expr => {
                const match_e = self.ir_view.getMatchExpr(node) orelse return;
                self.walkExprForRefs(match_e.discriminant);
                var mi: u8 = 0;
                while (mi < match_e.arms_count) : (mi += 1) {
                    const arm_idx = self.ir_view.getListIndex(match_e.arms_start, mi);
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    self.walkExprForRefs(arm.body);
                }
            },
            .assignment => {
                const assign = self.ir_view.getAssignment(node) orelse return;
                self.walkExprForRefs(assign.target);
                self.walkExprForRefs(assign.value);

                // Check 6: reassignment to non-optional clears tracking
                self.handleOptionalReassignment(assign);

                // Check 7: detect mutation of module-scope bindings
                self.checkModuleScopeMutation(assign.target, node);
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    const elem = self.ir_view.getListIndex(arr.elements_start, i);
                    self.walkExprForRefs(elem);
                }
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    // A spread element carries its operand where a property
                    // carries its key, so reading it as a property walked the
                    // empty value slot and counted no reference: `{ ...base }`
                    // left `base` looking unread.
                    if (self.ir_view.getTag(prop_idx) == .object_spread) {
                        if (self.ir_view.getOptValue(prop_idx)) |operand| {
                            self.walkExprForRefs(operand);
                        }
                        continue;
                    }
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    self.walkExprForRefs(prop.value);
                    // Check 6: optional used as property value
                    self.checkOptionalUse(prop.value);
                }
            },
            .spread => {
                // The parser stores the operand in the value word (`getOptValue`),
                // not in the unary operand word, so `getUnary` read an empty slot
                // and `[...result.value]` reached no check.
                const operand = self.ir_view.getOptValue(node) orelse return;
                self.walkExprForRefs(operand);
            },
            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                self.walkNestedFunctionBody(func.body);
            },
            .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.walkExprForRefs(member.object);
                if (member.computed != null_node) {
                    self.walkExprForRefs(member.computed);
                }
                // Bracket access must satisfy the same soundness proof as dot
                // access: `m["x"]` on an un-narrowed optional is an
                // unchecked-optional access. Without this, bracket notation
                // launders it past the verdict. The Result forms are checked
                // by `checkResultUses`.
                self.checkOptionalObjectAccess(member, node);
            },
            // exhaustive: this walk looks for unguarded Result and optional reads.
            // Every expression kind not named above descends through the shared
            // expression-child map, so a node kind that holds code is walked by
            // default. A leaf has no children and reads nothing.
            else => {
                var it = self.ir_view.expressionChildren(node);
                while (it.next()) |child| self.walkChild(child);
            },
        }
    }

    // -----------------------------------------------------------------------
    // Check 2: Result uses
    //
    // A Result binding is a `var_decl` whose initializer is a direct call that
    // returns a Result: a builtin export with `returns == .result`, or one of
    // the ambient globals `requestJson` and `requestText`. Every use of one is
    // classified, and a use that is not modelled is refused. This is the same
    // classification that `proof_ir.zig` lowers into events and that the
    // consumer re-derives, so `result_safe` in the contract and the
    // certificate agree.
    //
    //   - `b.ok` is a read of a boolean and is never refused.
    //   - `.value`, `.unwrap` and the literal keys `"value"` and `"unwrap"`
    //     need an ok check. `.error`, `.errors` and their literal keys need an
    //     err check, unless the read is the left operand of `??` or the object
    //     of `?.`.
    //   - The only checks are `if (b.ok)` and `if (!b.ok)`. The then arm and
    //     the else arm take opposite polarity. When the then arm always
    //     returns, the rest of the enclosing block takes the else polarity.
    //   - An argument at a position that the export declares `.result` is
    //     read by that export after it tests `ok`. An array literal of Results
    //     at a `.result_list` position is the same. Any other use is refused:
    //     alias, other argument, return, object or array member, spread, a
    //     computed key that is not a literal, a method call on the binding,
    //     a member read on a Result call that nobody binds, and a Result call
    //     in any position except a discarded statement.
    //   - A closure starts with no checks. An upvalue names its binding by
    //     atom, so it resolves only when exactly one Result binding has that
    //     name.
    //   - A statement without guard structure (`switch`, `try`) is read flat:
    //     a check inside it covers nothing.
    // -----------------------------------------------------------------------

    /// The deepest expression the Result walk reads before it refuses.
    const max_result_depth: u16 = 1024;

    const ResultMemberKind = enum { ok, value, failure, other };

    const ResultGuard = struct {
        ordinal: u32,
        then_polarity: ResultPolarity,
        else_polarity: ResultPolarity,
    };

    const BuiltinExport = struct {
        func: *const mb.FunctionBinding,
        module_name: []const u8,
    };

    /// Check every use of a Result in the program. The walk covers each
    /// function, not only the request roots.
    fn checkResultUses(self: *HandlerVerifier, handler_func: NodeIndex) void {
        self.collectResultBindings();
        self.result_handler = handler_func;
        self.result_covers.clearRetainingCapacity();
        self.result_cover_base = 0;
        self.result_flat = false;
        self.result_in_condition = false;
        self.result_unrecognized.clearRetainingCapacity();
        self.result_function_depth = 0;
        self.walkResultNode(self.programRoot() orelse handler_func);
    }

    /// The program node. The parser adds it last.
    fn programRoot(self: *const HandlerVerifier) ?NodeIndex {
        var index = self.ir_view.nodeCount();
        while (index > 0) {
            index -= 1;
            const node: NodeIndex = @intCast(index);
            if (self.ir_view.getTag(node) == .program) return node;
        }
        return null;
    }

    /// Number the Result bindings of the program, in node order.
    fn collectResultBindings(self: *HandlerVerifier) void {
        for (0..self.ir_view.nodeCount()) |position| {
            const node: NodeIndex = @intCast(position);
            if (self.ir_view.getTag(node) != .var_decl) continue;
            const decl = self.ir_view.getVarDecl(node) orelse continue;
            if (decl.init == null_node) continue;
            const callee = self.resultCallee(decl.init) orelse continue;
            self.result_bindings.append(self.allocator, .{
                .scope_id = decl.binding.scope_id,
                .slot = decl.binding.slot,
                .ref_count = 0,
                .decl_node = node,
                .name_idx = 0,
                .source_module = callee.module_name,
                .source_func = callee.func_name,
                .name_atom = decl.binding.name_atom,
            }) catch self.markAllocationFailure();
        }
    }

    /// The builtin export that an identifier names through an import.
    fn builtinExportOf(self: *HandlerVerifier, identifier: NodeIndex) ?BuiltinExport {
        const facts = self.resolveFacts() orelse return null;
        if (self.ir_view.getTag(identifier) != .identifier) return null;
        const binding = self.ir_view.getBinding(identifier) orelse return null;
        const record = facts.importForReference(binding, .module_reference, .builtin, .first) orelse return null;
        const found = builtin_modules.findExport(record.module_specifier, record.imported_name) orelse return null;
        return .{ .func = found.func, .module_name = found.binding.specifier };
    }

    /// The name of the ambient Result global that an identifier names. A local,
    /// argument, or upvalue that shadows the name is not the global.
    fn resultGlobalName(self: *const HandlerVerifier, identifier: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(identifier) != .identifier) return null;
        const binding = self.ir_view.getBinding(identifier) orelse return null;
        if (binding.kind != .undeclared_global) return null;
        const name = self.resolveAtomName(binding.name_atom) orelse return null;
        for (result_globals) |global| {
            if (std.mem.eql(u8, name, global)) return global;
        }
        return null;
    }

    /// What a direct call that returns a Result names, or null for any other
    /// expression.
    fn resultCallee(self: *HandlerVerifier, node: NodeIndex) ?ResultCallee {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .call and tag != .method_call) return null;
        const call = self.ir_view.getCall(node) orelse return null;
        if (self.resultGlobalName(call.callee)) |name| {
            return .{ .func = null, .module_name = null, .func_name = name };
        }
        const exported = self.builtinExportOf(call.callee) orelse return null;
        if (exported.func.returns != .result) return null;
        return .{ .func = exported.func, .module_name = exported.module_name, .func_name = exported.func.name };
    }

    /// Which Result binding an identifier names. An upvalue names its binding
    /// by atom, so it resolves only when exactly one Result binding has that
    /// name. A binding that is not a Result and shares the name adds no
    /// refusal.
    fn resultReference(self: *const HandlerVerifier, identifier: NodeIndex) ResultReference {
        if (self.ir_view.getTag(identifier) != .identifier) return .none;
        const binding = self.ir_view.getBinding(identifier) orelse return .none;
        var found: ?u32 = null;
        for (self.result_bindings.items, 0..) |declared, ordinal| {
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

    /// Whether the walk holds a check of this polarity for the binding.
    fn resultCovered(self: *const HandlerVerifier, ordinal: u32, polarity: ResultPolarity) bool {
        for (self.result_covers.items[self.result_cover_base..]) |cover| {
            if (cover.ordinal == ordinal and cover.polarity == polarity) return true;
        }
        return false;
    }

    fn pushResultCover(self: *HandlerVerifier, ordinal: u32, polarity: ResultPolarity) void {
        // A failed append is sticky: `allocation_failed` voids the verdict.
        self.result_covers.append(self.allocator, .{ .ordinal = ordinal, .polarity = polarity }) catch self.markAllocationFailure();
    }

    /// The shape of a refused use of a Result binding in this position.
    fn shapeForPosition(position: ResultPosition) ResultShape {
        return switch (position) {
            .alias => .alias_or_reassignment,
            .argument => .call_argument,
            .returned => .returned,
            .collection_member => .collection_member,
            .spread => .spread,
            .matched => .match_subject,
            .other, .discard, .nullish_left, .optional_object, .result_arg, .callee => .other_use,
        };
    }

    /// The shape of an unchecked read of `.value` or `.error` on a binding.
    fn shapeForRead(self: *const HandlerVerifier, member_object: NodeIndex, ordinal: u32, failure: bool) ResultShape {
        if (self.result_flat) return .flat_guard;
        if (self.ir_view.getBinding(member_object)) |binding| {
            if (binding.kind == .upvalue) return .closure_read;
        }
        if (failure) {
            return if (self.resultCovered(ordinal, .ok)) .error_on_ok_path else .unchecked_error;
        }
        for (self.result_unrecognized.items) |unrecognized| {
            if (unrecognized == ordinal) return .unrecognized_guard;
        }
        return .unchecked_value;
    }

    fn noteUnrecognizedOk(self: *HandlerVerifier, ordinal: u32) void {
        if (!self.result_in_condition) return;
        // A failed append is sticky: `allocation_failed` voids the verdict.
        self.result_unrecognized.append(self.allocator, ordinal) catch self.markAllocationFailure();
    }

    fn refuseResult(self: *HandlerVerifier, node: NodeIndex, ordinal: ?u32, shape: ResultShape) void {
        var source_module: ?[]const u8 = null;
        var source_func: ?[]const u8 = null;
        if (ordinal) |index| {
            source_module = self.result_bindings.items[index].source_module;
            source_func = self.result_bindings.items[index].source_func;
        }
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unchecked_result_value,
            .node = node,
            .message = shape.message(),
            .help = shape.help(),
            .source_module = source_module,
            .source_func = source_func,
            .route_root = self.result_in_route_root,
            .repair_intent = .insert_guard_before_line,
            .result_shape = shape,
        });
    }

    /// The guard that an `if` condition forms: exactly `b.ok` or `!b.ok` on a
    /// Result binding. Every other condition is not a guard.
    fn resultGuard(self: *const HandlerVerifier, condition: NodeIndex) ?ResultGuard {
        const tag = self.ir_view.getTag(condition) orelse return null;
        var negated = false;
        var subject = condition;
        if (tag == .unary_op) {
            const unary = self.ir_view.getUnary(condition) orelse return null;
            if (unary.op != .not) return null;
            negated = true;
            subject = unary.operand;
        }
        if (self.ir_view.getTag(subject) != .member_access) return null;
        const member = self.ir_view.getMember(subject) orelse return null;
        if (member.computed != null_node or member.property != @backingInt(object.Atom.ok)) return null;
        if (self.ir_view.getTag(member.object) != .identifier) return null;
        return switch (self.resultReference(member.object)) {
            .ordinal => |ordinal| .{
                .ordinal = ordinal,
                .then_polarity = if (negated) .err else .ok,
                .else_polarity = if (negated) .ok else .err,
            },
            .none, .ambiguous => null,
        };
    }

    fn resultMemberKind(self: *const HandlerVerifier, member: Node.MemberExpr) ResultMemberKind {
        if (member.computed != null_node) {
            if (self.ir_view.getTag(member.computed) != .lit_string) return .other;
            const string_index = self.ir_view.getStringIdx(member.computed) orelse return .other;
            const name = self.ir_view.getString(string_index) orelse return .other;
            if (std.mem.eql(u8, name, "ok")) return .ok;
            if (std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "unwrap")) return .value;
            if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "errors")) return .failure;
            return .other;
        }
        if (member.property == @backingInt(object.Atom.ok)) return .ok;
        if (member.property == @backingInt(object.Atom.value) or member.property == @backingInt(object.Atom.unwrap)) return .value;
        if (member.property == @backingInt(object.Atom.@"error") or member.property == @backingInt(object.Atom.errors)) return .failure;
        return .other;
    }

    /// Walk a child of a statement or expression: a statement to the statement
    /// walk, anything else to the expression walk.
    fn walkResultChild(self: *HandlerVerifier, child: NodeIndex, depth: u16) void {
        self.walkResultChildAt(child, .other, depth);
    }

    fn walkResultChildAt(self: *HandlerVerifier, child: NodeIndex, position: ResultPosition, depth: u16) void {
        if (child == null_node) return;
        const tag = self.ir_view.getTag(child) orelse return;
        if (isStatementTag(tag)) {
            self.walkResultNode(child);
        } else {
            self.walkResultExpr(child, position, depth);
        }
    }

    /// Walk a node in its own span of covers: a check made inside does not
    /// reach the code after it.
    fn walkResultScoped(self: *HandlerVerifier, node: NodeIndex) void {
        const mark = self.result_covers.items.len;
        defer self.result_covers.shrinkRetainingCapacity(mark);
        self.walkResultChild(node, 0);
    }

    fn walkResultNode(self: *HandlerVerifier, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                // A check holds for the rest of its block and no further.
                const mark = self.result_covers.items.len;
                defer self.result_covers.shrinkRetainingCapacity(mark);
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    self.walkResultNode(self.ir_view.getListIndex(block.stmts_start, i));
                }
            },
            .export_decl => {
                const decl = self.ir_view.getExportDecl(node) orelse return;
                self.walkResultNode(decl.declaration);
            },
            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                self.walkResultNode(decl.init);
            },
            .function_expr, .arrow_function => self.walkResultFunction(node, false),
            .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                if (decl.init == null_node) return;
                // A declaration inside a flat statement binds nothing the
                // walk can follow, so its initializer is an ordinary use.
                if (!self.result_flat) {
                    if (self.resultCallee(decl.init)) |callee| {
                        const call = self.ir_view.getCall(decl.init) orelse return;
                        self.walkResultArguments(call, callee.func, 0);
                        return;
                    }
                }
                self.walkResultExpr(decl.init, .alias, 0);
            },
            .expr_stmt => {
                const operand = self.ir_view.getOptValue(node) orelse return;
                self.walkResultExpr(operand, if (self.result_flat) .other else .discard, 0);
            },
            .if_stmt => self.walkResultIf(node),
            .for_of_stmt, .for_in_stmt => {
                const loop = self.ir_view.getForIter(node) orelse return;
                self.walkResultExpr(loop.iterable, .other, 0);
                self.walkResultScoped(loop.body);
            },
            .for_stmt, .while_stmt, .do_while_stmt => {
                const loop = self.ir_view.getLoop(node) orelse return;
                self.walkResultChild(loop.init, 0);
                self.walkResultChild(loop.condition, 0);
                self.walkResultChild(loop.update, 0);
                self.walkResultScoped(loop.body);
            },
            .return_stmt => {
                const value = self.ir_view.getOptValue(node) orelse return;
                self.walkResultExpr(value, .returned, 0);
            },
            // exhaustive: every other statement has no guard structure. A
            // check inside it covers nothing, so it is read flat, and the
            // shared child map reaches every node that holds code.
            else => {
                const saved_flat = self.result_flat;
                self.result_flat = true;
                defer self.result_flat = saved_flat;
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| self.walkResultChild(child, 0);
            },
        }
    }

    fn walkResultIf(self: *HandlerVerifier, node: NodeIndex) void {
        const stmt = self.ir_view.getIfStmt(node) orelse return;
        if (!self.result_flat) {
            if (self.resultGuard(stmt.condition)) |guard| {
                {
                    const mark = self.result_covers.items.len;
                    defer self.result_covers.shrinkRetainingCapacity(mark);
                    self.pushResultCover(guard.ordinal, guard.then_polarity);
                    self.walkResultChild(stmt.then_branch, 0);
                }
                if (stmt.else_branch != null_node) {
                    const mark = self.result_covers.items.len;
                    defer self.result_covers.shrinkRetainingCapacity(mark);
                    self.pushResultCover(guard.ordinal, guard.else_polarity);
                    self.walkResultChild(stmt.else_branch, 0);
                }
                // A then arm that always returns leaves the else polarity
                // true for the rest of the enclosing block.
                if (self.stmtReturnsQuick(stmt.then_branch) == .always) {
                    self.pushResultCover(guard.ordinal, guard.else_polarity);
                }
                return;
            }
        }
        const saved_in_condition = self.result_in_condition;
        self.result_in_condition = true;
        self.walkResultExpr(stmt.condition, .other, 0);
        self.result_in_condition = saved_in_condition;
        self.walkResultScoped(stmt.then_branch);
        if (stmt.else_branch != null_node) self.walkResultScoped(stmt.else_branch);
    }

    /// Walk the body of a function. A function can run at any later time, so
    /// no check made outside it holds inside it. When `returns_consumed` is
    /// set, the function is a callback at a `.result_fn` position: an
    /// expression body is a position where an unbound Result is consumed by
    /// the export that took the callback.
    fn walkResultFunction(self: *HandlerVerifier, node: NodeIndex, returns_consumed: bool) void {
        const func = self.ir_view.getFunction(node) orelse return;
        const saved_base = self.result_cover_base;
        const saved_flat = self.result_flat;
        const saved_route = self.result_in_route_root;
        const outer_length = self.result_covers.items.len;
        self.result_cover_base = outer_length;
        self.result_flat = false;
        if (self.result_function_depth == 0) self.result_in_route_root = self.isRouteRootFunction(node);
        self.result_function_depth += 1;
        // The parser wraps the expression body of an arrow in a `return`.
        const body_is_expression = self.ir_view.getTag(func.body) == .return_stmt;
        if (returns_consumed and body_is_expression) {
            self.walkResultExpr(self.ir_view.getOptValue(func.body) orelse null_node, .result_arg, 0);
        } else {
            self.walkResultChild(func.body, 0);
        }
        self.result_function_depth -= 1;
        self.result_in_route_root = saved_route;
        self.result_flat = saved_flat;
        self.result_cover_base = saved_base;
        self.result_covers.shrinkRetainingCapacity(outer_length);
    }

    /// A request root other than the handler: a route function that
    /// `routerMatch` dispatches to.
    fn isRouteRootFunction(self: *const HandlerVerifier, node: NodeIndex) bool {
        if (node == self.result_handler) return false;
        for (self.result_route_roots) |root| {
            if (root == node) return true;
        }
        return false;
    }

    fn walkResultExpr(self: *HandlerVerifier, node: NodeIndex, position: ResultPosition, depth: u16) void {
        if (node == null_node) return;
        if (depth >= max_result_depth) {
            // An expression this deep is not read, so it is not proven.
            self.refuseResult(node, null, .depth_limit);
            return;
        }
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .function_expr, .arrow_function, .function_decl => self.walkResultNode(node),
            .identifier => switch (self.resultReference(node)) {
                .ordinal => |ordinal| {
                    if (position != .result_arg) self.refuseResult(node, ordinal, shapeForPosition(position));
                },
                .ambiguous => self.refuseResult(node, null, .ambiguous_upvalue),
                .none => {
                    // A Result export named outside the callee position is an
                    // alias, and a call through the alias is not classified.
                    if (self.resultGlobalName(node) != null) self.refuseResult(node, null, .function_alias);
                    if (self.builtinExportOf(node)) |exported| {
                        if (exported.func.returns == .result) self.refuseResult(node, null, .function_alias);
                    }
                },
            },
            .member_access, .optional_chain, .computed_access => self.walkResultMember(node, tag, position, depth),
            .binary_op => {
                const binary = self.ir_view.getBinary(node) orelse return;
                const left: ResultPosition = if (binary.op == .nullish) .nullish_left else .other;
                self.walkResultExpr(binary.left, left, depth + 1);
                self.walkResultExpr(binary.right, .other, depth + 1);
            },
            .call, .method_call => self.walkResultCall(node, position, depth),
            // exhaustive: every other expression passes no Result safely, so
            // each child is a use in an unmodelled position.
            else => {
                const child_position: ResultPosition = switch (tag) {
                    .array_literal, .object_literal, .object_property => .collection_member,
                    .spread, .object_spread => .spread,
                    .assignment => .alias,
                    // exhaustive: the position only names the refusal. Every
                    // child is a refused use whatever the label is.
                    else => .other,
                };
                var first = true;
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| {
                    // The first child of a `match` is its subject.
                    const at: ResultPosition = if (tag == .match_expr and first) .matched else child_position;
                    first = false;
                    self.walkResultChildAt(child, at, depth + 1);
                }
            },
        }
    }

    fn walkResultMember(self: *HandlerVerifier, node: NodeIndex, tag: NodeTag, position: ResultPosition, depth: u16) void {
        const member = self.ir_view.getMember(node) orelse return;
        const reference: ResultReference = if (self.ir_view.getTag(member.object) == .identifier)
            self.resultReference(member.object)
        else
            .none;
        switch (reference) {
            .none => {
                const object_position: ResultPosition = if (tag == .optional_chain) .optional_object else .other;
                self.walkResultExpr(member.object, object_position, depth + 1);
            },
            .ambiguous => self.refuseResult(node, null, .ambiguous_upvalue),
            .ordinal => |ordinal| switch (self.resultMemberKind(member)) {
                .ok => self.noteUnrecognizedOk(ordinal),
                .value => if (!self.resultCovered(ordinal, .ok)) {
                    self.refuseResult(node, ordinal, self.shapeForRead(member.object, ordinal, false));
                },
                .failure => {
                    // On an ok Result `.error` is undefined, so a read that
                    // supplies a fallback or chains optionally gets no payload.
                    if (position != .nullish_left and position != .optional_object and
                        !self.resultCovered(ordinal, .err))
                    {
                        self.refuseResult(node, ordinal, self.shapeForRead(member.object, ordinal, true));
                    }
                },
                .other => {
                    self.noteUnrecognizedOk(ordinal);
                    const shape: ResultShape = if (position == .callee)
                        .method_call
                    else if (member.computed != null_node and self.ir_view.getTag(member.computed) != .lit_string)
                        .computed_key
                    else
                        .unknown_member;
                    self.refuseResult(node, ordinal, shape);
                },
            },
        }
        self.walkResultExpr(member.computed, .other, depth + 1);
    }

    fn walkResultCall(self: *HandlerVerifier, node: NodeIndex, position: ResultPosition, depth: u16) void {
        const call = self.ir_view.getCall(node) orelse return;
        const exported = self.builtinExportOf(call.callee);
        if (self.resultGlobalName(call.callee) != null) {
            if (position != .discard and position != .result_arg) self.refuseResult(node, null, .unbound_call);
        } else if (exported) |found| {
            // A Result nobody binds can only be discarded or passed to a
            // consumer that tests it. Anywhere else it flows on unchecked.
            if (found.func.returns == .result and position != .discard and position != .result_arg) {
                self.refuseResult(node, null, .unbound_call);
            }
        } else {
            self.walkResultExpr(call.callee, .callee, depth + 1);
        }
        self.walkResultArguments(call, if (exported) |found| found.func else null, depth);
    }

    /// An argument at a position the export declares as a Result is read by
    /// that export, and each such export tests `ok` before it reads. An array
    /// literal at a `.result_list` position holds Results that the export
    /// reads the same way.
    fn walkResultArguments(self: *HandlerVerifier, call: Node.CallExpr, func: ?*const mb.FunctionBinding, depth: u16) void {
        for (0..call.args_count) |position| {
            const argument = self.ir_view.getListIndex(call.args_start, @intCast(position));
            if (func) |exported| {
                if (position < exported.param_types.len) {
                    switch (exported.param_types[position]) {
                        .result => {
                            self.walkResultExpr(argument, .result_arg, depth + 1);
                            continue;
                        },
                        .result_list => {
                            self.walkResultList(argument, depth + 1);
                            continue;
                        },
                        .result_fn => {
                            switch (self.ir_view.getTag(argument) orelse .lit_null) {
                                .arrow_function, .function_expr => self.walkResultFunction(argument, true),
                                else => self.walkResultExpr(argument, .argument, depth + 1),
                            }
                            continue;
                        },
                        // exhaustive: every other parameter kind passes no Result
                        // safely, so its argument is an ordinary use, walked below.
                        else => {},
                    }
                }
            }
            self.walkResultExpr(argument, .argument, depth + 1);
        }
    }

    fn walkResultList(self: *HandlerVerifier, argument: NodeIndex, depth: u16) void {
        if (self.ir_view.getTag(argument) != .array_literal) return self.walkResultExpr(argument, .argument, depth);
        const array = self.ir_view.getArray(argument) orelse return;
        var i: u16 = 0;
        while (i < array.elements_count) : (i += 1) {
            self.walkResultExpr(self.ir_view.getListIndex(array.elements_start, i), .result_arg, depth + 1);
        }
    }

    /// The binding an identifier node reads, as the declaring scope names it.
    /// A closure reads a captured binding through an upvalue reference whose
    /// scope and slot index the closure's own upvalue table, so the tracked
    /// state, which is keyed by the declaring scope and slot, would never
    /// match it. An upvalue reference is resolved by name to the one variable
    /// declaration that has that name. When two declarations share the name,
    /// the reference stays unresolved and reads no tracked state: this is the
    /// same blind spot that closures had before the walk entered them.
    fn bindingOf(self: *const HandlerVerifier, identifier_node: NodeIndex) ?ir.BindingRef {
        const ref = self.ir_view.getBinding(identifier_node) orelse return null;
        if (ref.kind != .upvalue) return ref;
        var found: ?BindingState = null;
        for (self.all_bindings.items) |declared| {
            if (declared.name_atom != ref.name_atom) continue;
            if (found != null) return ref;
            found = declared;
        }
        const declared = found orelse return ref;
        return .{
            .scope_id = declared.scope_id,
            .slot = declared.slot,
            .name_atom = declared.name_atom,
            .kind = .local,
        };
    }

    /// Pointer to the flag that `flag` and `key` name, or null when the binding
    /// is not tracked. Valid until the next append to the binding lists.
    fn checkedFlagPtr(self: *HandlerVerifier, flag: CheckedChange.Flag, key: u32) ?*bool {
        switch (flag) {
            .optional_narrowed => {
                for (self.optional_bindings.items) |*ob| {
                    if (ob.key() == key) return &ob.narrowed;
                }
            },
        }
        return null;
    }

    /// Set a checked flag and journal the old value when the flag changes.
    fn setCheckedFlag(self: *HandlerVerifier, flag: CheckedChange.Flag, key: u32, value: bool) void {
        const ptr = self.checkedFlagPtr(flag, key) orelse return;
        if (ptr.* == value) return;
        // A failed append is sticky: `allocation_failed` voids the whole verdict.
        self.checked_journal.append(self.allocator, .{ .flag = flag, .key = key, .old = ptr.* }) catch self.markAllocationFailure();
        ptr.* = value;
    }

    /// Clear a checked flag because the binding now holds a new, unchecked
    /// value. The kill is not undone when a block ends: the value that a block
    /// assigned is still there after the block. The kill also rewrites every
    /// journal entry of the flag to `false`, so no restore can bring back a
    /// check made before the assignment.
    fn killCheckedFlag(self: *HandlerVerifier, flag: CheckedChange.Flag, key: u32) void {
        const ptr = self.checkedFlagPtr(flag, key) orelse return;
        ptr.* = false;
        for (self.checked_journal.items) |*change| {
            if (change.flag == flag and change.key == key) change.old = false;
        }
    }

    /// Loop rule: the walk reads a loop body once, but the body runs at least
    /// twice when the loop repeats, and the second run starts with the value
    /// that the first run assigned. Before the body is walked, clear what the
    /// assignment path would clear for every binding that the subtree assigns:
    /// the narrowing of an optional that is assigned an optional-producing
    /// call. A narrowing made before the loop then does not hold at the top of
    /// the body, and a narrowing made inside the body after the assignment
    /// still holds for the code after it.
    /// This over-approximates (an assignment in a nested closure or in a branch
    /// counts) and so can only add refusals, never remove one. The kill outlasts
    /// the loop, as any kill does.
    fn killFlagsAssignedIn(self: *HandlerVerifier, root: NodeIndex) void {
        if (root == null_node) return;
        if ((self.ir_view.getTag(root) orelse return) == .assignment) {
            if (self.ir_view.getAssignment(root)) |assign| {
                if ((self.ir_view.getTag(assign.target) orelse .lit_null) == .identifier) {
                    if (self.bindingOf(assign.target)) |binding| {
                        const key = bindingKey(binding.scope_id, binding.slot);
                        if (self.findOptionalBinding(binding.slot, binding.scope_id) != null and
                            self.isOptionalProducingCall(assign.value) != null)
                        {
                            self.killCheckedFlag(.optional_narrowed, key);
                        }
                    }
                }
            }
        }
        var it = self.ir_view.expressionChildren(root);
        while (it.next()) |child| self.killFlagsAssignedIn(child);
    }

    /// Start of a block's journal span. Pair with `journalRestore`.
    fn journalMark(self: *const HandlerVerifier) usize {
        return self.checked_journal.items.len;
    }

    /// Undo every checked-flag change made since `mark`, newest first. A guard
    /// holds for the rest of the block that contains it. Restoring at the end
    /// of that block, and not at the end of the `if` statement, is what lets
    /// `if (!result.ok) { return ...; }` clear the code after it in the same
    /// block and nowhere else. This is the model of `beginNarrowScope` and
    /// `endNarrowScope` in `type_checker.zig`.
    fn journalRestore(self: *HandlerVerifier, mark: usize) void {
        var i = self.checked_journal.items.len;
        while (i > mark) {
            i -= 1;
            const change = self.checked_journal.items[i];
            if (self.checkedFlagPtr(change.flag, change.key)) |ptr| ptr.* = change.old;
        }
        self.checked_journal.shrinkRetainingCapacity(mark);
    }

    /// Walk a branch body in its own journal span.
    fn walkScoped(self: *HandlerVerifier, node: NodeIndex) void {
        const mark = self.journalMark();
        defer self.journalRestore(mark);
        self.walkForResultsAndRefs(node);
    }

    /// Increment reference count for a binding (scope-aware).
    fn incrementRefCount(self: *HandlerVerifier, binding_ref: ir.BindingRef) void {
        const target_key = bindingKey(binding_ref.scope_id, binding_ref.slot);
        for (self.all_bindings.items) |*binding| {
            if (binding.key() == target_key) {
                binding.ref_count +|= 1;
                return;
            }
        }
    }

    /// Resolve an atom index to its string name.
    /// Uses predefined atom names or the atom table for dynamic atoms.
    fn resolveAtomName(self: *const HandlerVerifier, atom_idx: u16) ?[]const u8 {
        const atom: object.Atom = @fromBackingInt(@intCast(atom_idx));
        if (atom.isPredefined()) {
            return atom.toPredefinedName();
        }
        if (self.atoms) |at| {
            return at.getName(atom);
        }
        return null;
    }

    /// Quick return status check (without emitting diagnostics).
    /// Intentionally separate from stmtReturns: that function is the full Check 1 analysis
    /// pass that emits diagnostics (unreachable code, missing default, etc.). This one is a
    /// lightweight predicate used by Check 2 and Check 6 to decide if a then-branch always
    /// returns (enabling post-dominator narrowing). Merging them would require threading a
    /// "suppress diagnostics" flag through the entire Check 1 call tree.
    fn stmtReturnsQuick(self: *HandlerVerifier, node: NodeIndex) ReturnStatus {
        const tag = self.ir_view.getTag(node) orelse return .never;
        return switch (tag) {
            .return_stmt => .always,
            .block, .program => blk: {
                const block = self.ir_view.getBlock(node) orelse break :blk .never;
                if (block.stmts_count == 0) break :blk .never;
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
                    if (self.stmtReturnsQuick(stmt_idx) == .always) break :blk .always;
                }
                break :blk .never;
            },
            .if_stmt => blk: {
                const if_stmt = self.ir_view.getIfStmt(node) orelse break :blk .never;
                const then_s = self.stmtReturnsQuick(if_stmt.then_branch);
                if (if_stmt.else_branch == null_node) break :blk if (then_s == .always) .sometimes else .never;
                const else_s = self.stmtReturnsQuick(if_stmt.else_branch);
                break :blk if (then_s == .always and else_s == .always) .always else .sometimes;
            },
            // exhaustive: an unlisted statement does not establish a return.
            // `.never` can only prevent post-dominator narrowing.
            else => .never,
        };
    }

    // -----------------------------------------------------------------------
    // Check 4: Dead Variables
    // -----------------------------------------------------------------------

    fn reportUnusedVariables(self: *HandlerVerifier) void {
        // The walk does not enter nested function bodies, so a binding read only
        // by a closure counted no reference. Every upvalue reference in the
        // program names its binding by atom; a binding whose name some closure
        // captures is not reported. Two bindings that share a name can hide a
        // warning this way, and never raise one.
        var captured = std.StaticBitSet(1 << 16).empty;
        for (0..self.ir_view.nodeCount()) |i| {
            const idx: NodeIndex = @intCast(i);
            if ((self.ir_view.getTag(idx) orelse continue) != .identifier) continue;
            const ref = self.ir_view.getBinding(idx) orelse continue;
            if (ref.kind == .upvalue) captured.set(ref.name_atom);
        }

        for (self.all_bindings.items) |binding| {
            if (binding.ref_count > 0) continue;
            if (binding.name_atom != 0 and captured.isSet(binding.name_atom)) continue;

            // Skip special bindings (slot 0 is typically the module scope)
            if (binding.slot == 0) continue;

            // Skip _-prefixed names (convention for intentionally unused)
            // For global bindings, slot is the atom index
            if (binding.scope_id == 0) {
                if (self.resolveAtomName(binding.slot)) |name| {
                    if (name.len > 0 and name[0] == '_') continue;
                }
            }
            // For named string index
            if (binding.name_idx != 0) {
                if (self.ir_view.getString(binding.name_idx)) |name| {
                    if (name.len > 0 and name[0] == '_') continue;
                }
            }

            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .unused_variable,
                .node = binding.decl_node,
                .message = "declared variable is never used",
                .help = "remove the unused variable, or prefix with '_' to suppress this warning",
            });
        }
    }

    // -----------------------------------------------------------------------
    // Check 6: Optional Value Checking
    // -----------------------------------------------------------------------

    /// Check if a call expression calls an optional-producing function.
    fn isOptionalProducingCall(self: *HandlerVerifier, node: NodeIndex) ?OptionalKind {
        const call_tag = self.ir_view.getTag(node) orelse return null;
        if (call_tag != .call and call_tag != .method_call) return null;

        const call = self.ir_view.getCall(node) orelse return null;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;

        if (callee_tag == .identifier) {
            const binding = self.ir_view.getBinding(call.callee) orelse return null;
            for (self.optional_function_slots.items) |opt_fn| {
                if (opt_fn.slot == binding.slot) return opt_fn.kind;
            }
        }

        return null;
    }

    /// Check if the init is `optionalCall() ?? default` (nullish coalesce resolves optionality).
    fn isNullishCoalesceWithOptionalCall(self: *HandlerVerifier, node: NodeIndex) bool {
        const t = self.ir_view.getTag(node) orelse return false;
        if (t != .binary_op) return false;

        const binary = self.ir_view.getBinary(node) orelse return false;
        if (binary.op != .nullish) return false;

        // LHS must be an optional-producing call
        return self.isOptionalProducingCall(binary.left) != null;
    }

    /// Extract optional narrowing info from an explicit undefined comparison.
    fn extractOptionalNarrowingCheck(self: *HandlerVerifier, cond_node: NodeIndex) ?NarrowingInfo {
        const cond_tag = self.ir_view.getTag(cond_node) orelse return null;

        // if (val !== undefined) or if (val === undefined)
        if (cond_tag == .binary_op) {
            const binary = self.ir_view.getBinary(cond_node) orelse return null;
            if (binary.op == .strict_neq) {
                if (self.extractUndefinedComparisonSlot(binary)) |info| {
                    return .{ .slot = info.slot, .scope_id = info.scope_id, .branch = .then };
                }
            }
            if (binary.op == .strict_eq) {
                if (self.extractUndefinedComparisonSlot(binary)) |info| {
                    return .{ .slot = info.slot, .scope_id = info.scope_id, .branch = .then_returns_early };
                }
            }
        }

        return null;
    }

    /// Extract slot from `val !== undefined` or `undefined !== val`.
    fn extractUndefinedComparisonSlot(self: *HandlerVerifier, binary: Node.BinaryExpr) ?struct { slot: u16, scope_id: ir.ScopeId } {
        // Check left=identifier, right=undefined
        const left_tag = self.ir_view.getTag(binary.left) orelse return null;
        const right_tag = self.ir_view.getTag(binary.right) orelse return null;

        if (left_tag == .identifier and right_tag == .lit_undefined) {
            const binding = self.bindingOf(binary.left) orelse return null;
            if (self.findOptionalBinding(binding.slot, binding.scope_id) != null) {
                return .{ .slot = binding.slot, .scope_id = binding.scope_id };
            }
        }

        // Check left=undefined, right=identifier
        if (left_tag == .lit_undefined and right_tag == .identifier) {
            const binding = self.bindingOf(binary.right) orelse return null;
            if (self.findOptionalBinding(binding.slot, binding.scope_id) != null) {
                return .{ .slot = binding.slot, .scope_id = binding.scope_id };
            }
        }

        return null;
    }

    /// Find an optional binding by slot and scope.
    fn findOptionalBinding(self: *HandlerVerifier, slot: u16, scope_id: ir.ScopeId) ?*OptionalBindingState {
        const target_key = bindingKey(scope_id, slot);
        for (self.optional_bindings.items) |*ob| {
            if (ob.key() == target_key) return ob;
        }
        return null;
    }

    /// Resolve an identifier node to its un-narrowed optional binding, if any.
    fn getUnnarrowedOptional(self: *HandlerVerifier, identifier_node: NodeIndex) ?*OptionalBindingState {
        const binding = self.bindingOf(identifier_node) orelse return null;
        const ob = self.findOptionalBinding(binding.slot, binding.scope_id) orelse return null;
        if (ob.narrowed) return null;
        return ob;
    }

    /// Set the narrowed state for an optional binding.
    fn setOptionalNarrowed(self: *HandlerVerifier, slot: u16, scope_id: ir.ScopeId, narrowed: bool) void {
        self.setCheckedFlag(.optional_narrowed, bindingKey(scope_id, slot), narrowed);
    }

    /// Check if a node is an un-narrowed optional identifier, and emit diagnostic.
    fn checkOptionalUse(self: *HandlerVerifier, node: NodeIndex) void {
        const t = self.ir_view.getTag(node) orelse return;
        if (t != .identifier) return;
        if (self.getUnnarrowedOptional(node) == null) return;

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unchecked_optional_use,
            .node = node,
            .message = "optional value used without checking for undefined",
            .help = "check before use: if (val !== undefined) { ... }\n           or provide a default: val ?? \"fallback\"",
            .repair_intent = .insert_guard_before_line,
        });
    }

    /// Check if a member_access is on an un-narrowed optional binding.
    ///
    /// Every `OptionalKind`, not just `optional_object`. Both members of that
    /// enum are commented "must narrow before use", and reading a property off
    /// either is the same runtime fault - `undefined.anything` throws whatever
    /// the absent value would have been. Restricting this to objects meant a
    /// property read off an un-narrowed optional string was reported by
    /// nothing, and `optionals_safe` then answered PROVEN over it.
    fn checkOptionalObjectAccess(self: *HandlerVerifier, member: Node.MemberExpr, node: NodeIndex) void {
        const obj_tag = self.ir_view.getTag(member.object) orelse return;
        if (obj_tag != .identifier) return;

        const ob = self.getUnnarrowedOptional(member.object) orelse return;

        // Optional chaining is a repair only where the narrowed value has the
        // property. On `string | undefined` it is the opposite of a repair:
        // `parsed?.ok` deletes the member_access this check reads, so ZTS309
        // stops firing and `optionals_safe` answers PROVEN again while
        // `.ok` is still undefined on a string and the handler still answers
        // 401 to every request. Widening the check to every OptionalKind
        // without splitting the help taught that repair.
        const help = switch (ob.kind) {
            .optional_object => "check before access: if (val) { ... val.prop ... }\n           or use optional chaining: val?.prop",
            .optional_string => "this value is a string when it is present, so it has no such property; " ++
                "check before use: if (val !== undefined) { ... val ... }",
        };

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unchecked_optional_access,
            .node = node,
            .message = "property access on optional value without checking for undefined",
            .help = help,
            .repair_intent = .insert_guard_before_line,
        });
    }

    /// Handle reassignment to a tracked binding. A non-optional value narrows an
    /// optional, for the rest of the enclosing block. An optional-producing
    /// call makes the binding optional again. That kill outlasts the block. An
    /// assignment to a Result binding is refused by `checkResultUses`.
    fn handleOptionalReassignment(self: *HandlerVerifier, assign: Node.AssignExpr) void {
        const target_tag = self.ir_view.getTag(assign.target) orelse return;
        if (target_tag != .identifier) return;

        const binding = self.bindingOf(assign.target) orelse return;
        const key = bindingKey(binding.scope_id, binding.slot);

        if (self.findOptionalBinding(binding.slot, binding.scope_id) == null) return;

        // Another optional-producing call: the binding is optional again
        if (self.isOptionalProducingCall(assign.value) != null) {
            self.killCheckedFlag(.optional_narrowed, key);
            return;
        }

        // Reassignment to non-optional resolves optionality
        self.setCheckedFlag(.optional_narrowed, key, true);
    }

    // -----------------------------------------------------------------------
    // Check 7: State isolation
    // -----------------------------------------------------------------------

    fn checkModuleScopeMutation(self: *HandlerVerifier, target: NodeIndex, assign_node: NodeIndex) void {
        const handler_scope = self.handler_scope_id orelse return;
        const target_tag = self.ir_view.getTag(target) orelse return;
        // A member or index write changes the object its base names, so the base
        // decides whether the object is shared between requests.
        const base = switch (target_tag) {
            .identifier => target,
            .member_access, .computed_access => self.memberBase(target) orelse return,
            // exhaustive: any other target form names no binding to test, and the
            // check returned for it before member writes were added. A write through
            // a call result such as `getStore().x = 1` stays unchecked here.
            else => return,
        };

        const binding = self.bindingOf(base) orelse return;
        // Module-scope bindings have a scope_id lower than the handler's. A builtin
        // such as Math is an undeclared global: a write to the name itself is not
        // state, a write through it changes an object every request shares.
        const shared = if (base == target)
            binding.scope_id < handler_scope and binding.kind != .undeclared_global
        else
            binding.scope_id < handler_scope or binding.kind == .undeclared_global or self.isSharedAlias(binding);
        if (shared) {
            self.has_module_mutation = true;
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .module_scope_mutation,
                .node = assign_node,
                .message = "handler mutates module-scope variable (breaks cross-request isolation)",
                .help = "use const instead of let for module-scope declarations, or move state to zttp:cache",
            });
        }
    }

    /// The identifier at the root of a chain of member and index accesses.
    fn memberBase(self: *const HandlerVerifier, node: NodeIndex) ?NodeIndex {
        var current = node;
        while (true) {
            const tag = self.ir_view.getTag(current) orelse return null;
            switch (tag) {
                .identifier => return current,
                .member_access, .optional_chain, .computed_access => {
                    const member = self.ir_view.getMember(current) orelse return null;
                    current = member.object;
                },
                // exhaustive: a call result, literal, or other expression at the root
                // names no binding, so no shared-state verdict is possible from it.
                else => return null,
            }
        }
    }

    fn isSharedAlias(self: *const HandlerVerifier, binding: ir.BindingRef) bool {
        const key = bindingKey(binding.scope_id, binding.slot);
        for (self.shared_aliases.items) |alias| {
            if (alias == key) return true;
        }
        return false;
    }

    /// `const m = Math;` and `const s = moduleObject;` make `m` and `s` names for
    /// shared objects. An alias of an alias is recorded too, in source order.
    fn recordSharedAlias(self: *HandlerVerifier, decl: Node.VarDecl) void {
        const handler_scope = self.handler_scope_id orelse return;
        if ((self.ir_view.getTag(decl.init) orelse return) != .identifier) return;
        const source = self.bindingOf(decl.init) orelse return;
        if (source.scope_id >= handler_scope and source.kind != .undeclared_global and !self.isSharedAlias(source)) return;
        self.shared_aliases.append(self.allocator, bindingKey(decl.binding.scope_id, decl.binding.slot)) catch self.markAllocationFailure();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    fn addDiagnostic(self: *HandlerVerifier, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch self.markAllocationFailure();
    }

    fn markAllocationFailure(self: *HandlerVerifier) void {
        self.allocation_failed = true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ReturnStatus enum" {
    try std.testing.expectEqual(ReturnStatus.always, ReturnStatus.always);
    try std.testing.expectEqual(ReturnStatus.never, ReturnStatus.never);
    try std.testing.expectEqual(ReturnStatus.sometimes, ReturnStatus.sometimes);
}

test "Severity labels" {
    try std.testing.expectEqualStrings("error", Severity.err.label());
    try std.testing.expectEqualStrings("warning", Severity.warning.label());
}

test "DiagnosticKind enum values" {
    // Ensure all variants are distinct
    const kinds = [_]DiagnosticKind{
        .missing_return_path,
        .unchecked_result_value,
        .unreachable_after_return,
        .unused_variable,
        .unused_import,
        .unchecked_optional_use,
        .unchecked_optional_access,
    };
    for (kinds, 0..) |k, i| {
        for (kinds, 0..) |k2, j| {
            if (i != j) {
                try std.testing.expect(k != k2);
            }
        }
    }
}

test "lookupTrackedFunction" {
    // Result-producing
    try std.testing.expectEqual(FunctionProduces.result, lookupTrackedFunction("zttp:auth", "jwtVerify").?);
    try std.testing.expectEqual(FunctionProduces.result, lookupTrackedFunction("zttp:validate", "validateJson").?);
    try std.testing.expectEqual(FunctionProduces.result, lookupTrackedFunction("zttp:validate", "validateObject").?);
    try std.testing.expectEqual(FunctionProduces.result, lookupTrackedFunction("zttp:validate", "coerceJson").?);
    // Optional-producing
    try std.testing.expectEqual(FunctionProduces.optional_string, lookupTrackedFunction("zttp:env", "env").?);
    try std.testing.expectEqual(FunctionProduces.optional_string, lookupTrackedFunction("zttp:cache", "cacheGet").?);
    try std.testing.expectEqual(FunctionProduces.optional_string, lookupTrackedFunction("zttp:auth", "parseBearer").?);
    try std.testing.expectEqual(FunctionProduces.optional_object, lookupTrackedFunction("zttp:router", "routerMatch").?);
    // Untracked
    try std.testing.expect(lookupTrackedFunction("zttp:crypto", "sha256") == null);
    try std.testing.expect(lookupTrackedFunction("zttp:cache", "cacheSet") == null);
}

test "verifier init and deinit" {
    // Create a minimal IR with just a program node
    var store = ir.IRStore.init(std.testing.allocator);
    defer store.deinit();

    var constants = ir.ConstantPool.init(std.testing.allocator);
    defer constants.deinit();

    const view = IrView.fromIRStore(&store, &constants);

    var verifier = HandlerVerifier.init(std.testing.allocator, view, null, null, null);
    defer verifier.deinit();

    try std.testing.expectEqual(@as(usize, 0), verifier.getDiagnostics().len);
    try std.testing.expect(!verifier.hasErrors());
}

test "diagnostic formatting" {
    var store = ir.IRStore.init(std.testing.allocator);
    defer store.deinit();

    var constants = ir.ConstantPool.init(std.testing.allocator);
    defer constants.deinit();

    // Add a node with a source location
    _ = try store.addNode(.return_stmt, .{ .line = 5, .column = 3, .offset = 42 }, .{ .a = null_node, .b = 0 });

    const view = IrView.fromIRStore(&store, &constants);

    var verifier = HandlerVerifier.init(std.testing.allocator, view, null, null, null);
    defer verifier.deinit();

    verifier.addDiagnostic(.{
        .severity = .err,
        .kind = .missing_return_path,
        .node = 0,
        .message = "not all code paths return a Response",
        .help = "add return statements",
    });

    try std.testing.expectEqual(@as(usize, 1), verifier.getDiagnostics().len);
    try std.testing.expect(verifier.hasErrors());

    // Test formatting doesn't crash
    const source = "line 1\nline 2\nline 3\nline 4\nline 5 has code\n";
    var output_buf: std.ArrayList(u8) = .empty;
    defer output_buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &output_buf);
    try verifier.formatDiagnostics(SourceView.of(source), &aw.writer);
    output_buf = aw.toArrayList();
    try std.testing.expect(output_buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output_buf.items, "verify error[ZTS302]") != null);
}

test "HandlerVerifier fails closed when a diagnostic cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "function handler(req) {}");
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(view, root) orelse return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var verifier = HandlerVerifier.init(failing.allocator(), view, null, null, null);
    defer verifier.deinit();
    try std.testing.expectError(error.OutOfMemory, verifier.verify(handler_fn));
}

/// Drive the verifier over typed source and assert its error count.
///
/// This used to assert a match-exhaustiveness warning count as well. That
/// warning's producer is gone: the type checker and the strict checker both
/// refuse a non-exhaustive match, and the check pipeline returns on their
/// errors before the verifier stage runs, so the diagnostic could never reach
/// anyone. Calling the verifier directly, as this helper does, was the only
/// place it was ever observed - which is how a rule stayed advertised and
/// tested while being unreachable in the product.
fn verifyTypedHandlerSource(source: []const u8, expect_errors: u32) !void {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse {
        try std.testing.expect(false);
        return;
    };

    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = type_env_mod.TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    @import("abi_types.zig").populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var type_checker = type_checker_mod.TypeChecker.init(allocator, ir_view, &atoms, &env);
    defer type_checker.deinit();
    type_checker.scopes = &parser.scopes;
    _ = try type_checker.check(root);

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, &env, &type_checker);
    defer verifier.deinit();

    const errors = try verifier.verify(handler_fn);
    try std.testing.expectEqual(expect_errors, errors);
}

/// Count the `unused_variable` warnings `source` produces. Untyped: the rule
/// reads reference counts off the IR and needs no type environment.
fn countUnusedVariableWarnings(source: []const u8) !u32 {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler_fn);

    var count: u32 = 0;
    for (verifier.getDiagnostics()) |diag| {
        if (diag.kind == .unused_variable) count += 1;
    }
    return count;
}

const RouteVerifierCounts = struct {
    missing_return: u32 = 0,
    unchecked_result: u32 = 0,
    unchecked_optional: u32 = 0,
    module_mutation: u32 = 0,
    unresolved_dispatch: bool = false,
    has_module_mutation: bool = false,
};

fn routeVerifierCounts(source: []const u8) !RouteVerifierCounts {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler = findHandlerFunction(view, root) orelse return error.HandlerNotFound;

    var verifier = HandlerVerifier.init(allocator, view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler);

    var counts: RouteVerifierCounts = .{};
    for (verifier.getDiagnostics()) |diagnostic| {
        switch (diagnostic.kind) {
            .missing_return_path => counts.missing_return += 1,
            .unchecked_result_value => counts.unchecked_result += 1,
            .unchecked_optional_use, .unchecked_optional_access => counts.unchecked_optional += 1,
            .module_scope_mutation => counts.module_mutation += 1,
            // exhaustive: this test helper counts only the four properties its
            // callers assert; all other diagnostics are outside that result.
            else => {},
        }
    }
    counts.unresolved_dispatch = verifier.unresolved_route_dispatch;
    counts.has_module_mutation = verifier.has_module_mutation;
    return counts;
}

test "a member or index write through a builtin or module-scope binding breaks state isolation" {
    const Case = struct { source: []const u8, mutations: u32 };
    const cases = [_]Case{
        .{ .source = "function handler(req) { parseInt.x = 1; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "function handler(req) { const m = Math; m.x = 1; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "const store = { a: \"\" };\nfunction handler(req) { store.a = \"x\"; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "const store = { a: \"\" };\nfunction handler(req) { store[\"a\"] = \"x\"; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "const store = { a: { b: 1 } };\nfunction handler(req) { store.a.b = 2; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "const store = { a: \"\" };\nfunction handler(req) { const s = store; s.a = \"x\"; return Response.text(\"ok\"); }", .mutations = 1 },
        .{ .source = "function handler(req) { const o = { a: \"\" }; o.a = \"x\"; return Response.text(\"ok\"); }", .mutations = 0 },
        .{ .source = "function handler(req) { req.x = 1; return Response.text(\"ok\"); }", .mutations = 0 },
        .{ .source = "const store = { a: \"\" };\nfunction handler(req) { const s = { a: store.a }; s.a = \"x\"; return Response.text(\"ok\"); }", .mutations = 0 },
    };
    for (cases) |case| {
        const counts = try routeVerifierCounts(case.source);
        if (counts.module_mutation != case.mutations) std.debug.print("source: {s}\n", .{case.source});
        try std.testing.expectEqual(case.mutations, counts.module_mutation);
        try std.testing.expectEqual(case.mutations > 0, counts.has_module_mutation);
    }
}

test "response total checks routerMatch route functions" {
    const direct = try routeVerifierCounts(
        \\function handler(req) {
        \\  if (req.method === "GET") return Response.text("ok");
        \\}
    );
    const routed = try routeVerifierCounts(
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  if (req.method === "GET") return Response.text("ok");
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );
    const clean = try routeVerifierCounts(
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );

    try std.testing.expectEqual(@as(u32, 1), direct.missing_return);
    try std.testing.expectEqual(direct.missing_return, routed.missing_return);
    try std.testing.expectEqual(@as(u32, 0), clean.missing_return);
    try std.testing.expect(!clean.unresolved_dispatch);
}

test "result safety checks routerMatch route functions" {
    const direct = try routeVerifierCounts(
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  return Response.json({ value: result.value });
        \\}
    );
    const routed = try routeVerifierCounts(
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const result = jwtVerify("token", "key");
        \\  return Response.json({ value: result.value });
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );
    const clean = try routeVerifierCounts(
        \\import { jwtVerify } from "zttp:auth";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (!result.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.json({ value: result.value });
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );

    try std.testing.expectEqual(@as(u32, 1), direct.unchecked_result);
    try std.testing.expectEqual(direct.unchecked_result, routed.unchecked_result);
    try std.testing.expectEqual(@as(u32, 0), clean.unchecked_result);
    try std.testing.expect(!clean.unresolved_dispatch);
}

test "optional safety checks routerMatch route functions" {
    const direct = try routeVerifierCounts(
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const value = env("HOME");
        \\  return Response.json({ length: value.length });
        \\}
    );
    const routed = try routeVerifierCounts(
        \\import { env } from "zttp:env";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const value = env("HOME");
        \\  return Response.json({ length: value.length });
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );
    const clean = try routeVerifierCounts(
        \\import { env } from "zttp:env";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const value = env("HOME");
        \\  if (value === undefined) return Response.text("missing");
        \\  return Response.json({ length: value.length });
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );

    try std.testing.expectEqual(@as(u32, 1), direct.unchecked_optional);
    try std.testing.expectEqual(direct.unchecked_optional, routed.unchecked_optional);
    try std.testing.expectEqual(@as(u32, 0), clean.unchecked_optional);
    try std.testing.expect(!clean.unresolved_dispatch);
}

test "state isolation checks routerMatch route functions" {
    const direct = try routeVerifierCounts(
        \\let counter = 0;
        \\function handler(req) {
        \\  counter = counter + 1;
        \\  return Response.json({ counter: counter });
        \\}
    );
    const routed = try routeVerifierCounts(
        \\import { routerMatch } from "zttp:router";
        \\let counter = 0;
        \\function route(req) {
        \\  counter = counter + 1;
        \\  return Response.json({ counter: counter });
        \\}
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );
    const clean = try routeVerifierCounts(
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("not found", { status: 404 });
        \\}
    );

    try std.testing.expectEqual(@as(u32, 1), direct.module_mutation);
    try std.testing.expectEqual(direct.module_mutation, routed.module_mutation);
    try std.testing.expect(direct.has_module_mutation);
    try std.testing.expect(routed.has_module_mutation);
    try std.testing.expectEqual(@as(u32, 0), clean.module_mutation);
    try std.testing.expect(!clean.has_module_mutation);
    try std.testing.expect(!clean.unresolved_dispatch);
}

test "unresolved routerMatch dispatch costs both verifier properties" {
    const shapes = [_][]const u8{
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\function handler(req) {
        \\  const found = routerMatch(req.routes, req);
        \\  return found.handler(req);
        \\}
        ,
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  const alias = found;
        \\  return alias.handler(req);
        \\}
        ,
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  return found["handler"](req);
        \\}
        ,
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  const dispatch = found.handler;
        \\  return dispatch(req);
        \\}
        ,
    };
    for (shapes) |source| {
        const counts = try routeVerifierCounts(source);
        try std.testing.expect(counts.missing_return > 0);
        try std.testing.expect(counts.unchecked_result > 0);
        try std.testing.expect(counts.unresolved_dispatch);
    }
}

test "reading routerMatch params does not make a stable dispatch unresolved" {
    const counts = try routeVerifierCounts(
        \\import { routerMatch } from "zttp:router";
        \\function route(req) { return Response.text("ok"); }
        \\const routes = { "GET /:id": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) {
        \\    const params = found.params;
        \\    if (params.id === "") return Response.text("bad", { status: 400 });
        \\    return found.handler(req);
        \\  }
        \\  return Response.text("not found", { status: 404 });
        \\}
    );
    try std.testing.expect(!counts.unresolved_dispatch);
    try std.testing.expectEqual(@as(u32, 0), counts.missing_return);
    try std.testing.expectEqual(@as(u32, 0), counts.unchecked_result);
}

const route_table_prelude =
    \\import { routerMatch } from "zttp:router";
    \\import { jwtVerify } from "zttp:auth";
    \\function getHome(req) { return Response.text("home"); }
    \\function bad(req) {
    \\  const result = jwtVerify("token", "key");
    \\  return Response.text(String(result.value));
    \\}
    \\function getBox() { return { n: 1 }; }
    \\
;

const route_table_dispatch =
    \\  const found = routerMatch(routes, req);
    \\  if (found !== undefined) {
    \\    return found.handler(req);
    \\  }
    \\  return Response.text("nf");
    \\}
;

test "a table mutated through an array literal root is unresolved" {
    // `[routes][0]` is the table itself. Before the fix the assignment root was
    // not an identifier, the mutation was skipped, and the table proved stable.
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  [routes][0]["GET /"] = bad;
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(counts.unresolved_dispatch);
    try std.testing.expect(counts.unchecked_result > 0);
}

test "a table iterated through an array literal is unresolved" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  for (const t of [routes]) {
        \\    t["GET /"] = bad;
        \\  }
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(counts.unresolved_dispatch);
    try std.testing.expect(counts.unchecked_result > 0);
}

test "a table stored or iterated through a value position is unresolved" {
    const shapes = [_][]const u8{
        // for...of iterable
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  for (const k of routes) {}
        ,
        // array element in a discarded expression
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  [routes];
        ,
        // a logical operator yields the table, and a declaration stores it
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const t = routes || routes;
        ,
        // a conditional yields the table, and an assignment stores it
        \\const routes = { "GET /": getHome };
        \\let other = 0;
        \\function handler(req) {
        \\  other = req ? routes : routes;
        ,
        // a computed index is a value position
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const k = req.x[routes];
        ,
    };
    inline for (shapes) |head| {
        const counts = try routeVerifierCounts(route_table_prelude ++ head ++ "\n" ++ route_table_dispatch);
        try std.testing.expect(counts.unresolved_dispatch);
    }
}

test "a table that is only tested or dropped stays resolved" {
    const shapes = [_][]const u8{
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  routes;
        ,
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  if (routes === undefined) return Response.text("x");
        ,
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const ok = !routes;
        ,
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const label = typeof routes;
        ,
    };
    inline for (shapes) |head| {
        const counts = try routeVerifierCounts(route_table_prelude ++ head ++ "\n" ++ route_table_dispatch);
        try std.testing.expect(!counts.unresolved_dispatch);
    }
}

test "a directly mutated table stays unresolved" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  routes["GET /"] = bad;
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(counts.unresolved_dispatch);
    try std.testing.expect(counts.unchecked_result > 0);
}

test "a stable table holding the unchecked route reports it and stays resolved" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": bad };
        \\function handler(req) {
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(!counts.unresolved_dispatch);
    try std.testing.expectEqual(@as(u32, 1), counts.unchecked_result);
}

test "a stable table with only reads stays resolved" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const known = routes["GET /"];
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(!counts.unresolved_dispatch);
    // `bad` is a sibling that nothing dispatches to. It reads a Result with no
    // check, and the whole-program walk refuses that read.
    try std.testing.expectEqual(@as(u32, 1), counts.unchecked_result);
}

test "an untracked assignment root unresolves every table in the file" {
    // Documented precision cost: `getBox().n = 5` may alias any table, so the
    // unrelated assignment makes the table look mutated.
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  getBox().n = 5;
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(counts.unresolved_dispatch);
}

test "an assignment to a plain local object leaves the table stable" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const box = { n: 1 };
        \\  box.n = 5;
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(!counts.unresolved_dispatch);
}

test "an alias of the table is unresolved" {
    const counts = try routeVerifierCounts(route_table_prelude ++
        \\const routes = { "GET /": getHome };
        \\function handler(req) {
        \\  const t = routes;
        \\  t["GET /"] = bad;
    ++ "\n" ++ route_table_dispatch);
    try std.testing.expect(counts.unresolved_dispatch);
    try std.testing.expect(counts.unchecked_result > 0);
}

test "a binding read only through an object spread is not reported unused" {
    // Same cause as the type checker's `{ base: unknown }`: the spread's
    // operand sits where a property's key sits, so walking the property's value
    // slot counted no reference and `base` read as never used.
    try std.testing.expectEqual(@as(u32, 0), try countUnusedVariableWarnings(
        \\function handler(req) {
        \\  const base = { host: "localhost", port: 80 };
        \\  return Response.json({ ...base, port: 8080 });
        \\}
    ));
}

test "a binding read only by a closure is not reported unused" {
    // The walk does not enter the arrow, and the arrow reads `y` through an
    // upvalue reference, so `y` counted no reference.
    try std.testing.expectEqual(@as(u32, 0), try countUnusedVariableWarnings(
        \\function handler(req) {
        \\  let saved = () => "clean";
        \\  if (req.method === "GET") {
        \\    const y = "kept";
        \\    saved = () => y;
        \\  }
        \\  return Response.text(saved());
        \\}
    ));
    // A binding nothing reads is still reported beside a captured one.
    try std.testing.expectEqual(@as(u32, 1), try countUnusedVariableWarnings(
        \\function handler(req) {
        \\  const y = "kept";
        \\  const unused = "never read";
        \\  const read = () => y;
        \\  return Response.text(read());
        \\}
    ));
}

test "HandlerVerifier accepts exhaustive literal union match without default" {
    try verifyTypedHandlerSource(
        \\const value: "a" | "b" = "a";
        \\function handler(req) {
        \\  const out = match (value) {
        \\    when "a": 1,
        \\    when "b": 2,
        \\  };
        \\  return Response.json({ out: out });
        \\}
    , 0);
}

// The companion test here asserted that a non-exhaustive union match produced a
// verifier warning. It is gone with the producer: ZTS603 and ZTS205 refuse that
// match first, and both are seed-verified, so the behaviour is still covered -
// by the checkers that actually reach a user.

test "missing_return_path diagnostic carries repair_intent = add_trailing_return" {
    // Handler verifier diagnostics must populate the typed repair primitive
    // so the expert agent can pick an
    // apply step directly. The handler returns only on the truthy branch;
    // the false branch leaves the function with no Response, which trips
    // ZTS302 (missing_return_path). The fix the agent should pick is
    // add_trailing_return — a `return Response.text("", { status: 500 })`
    // tail appended to the body.
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.json({ ok: true });
        \\  }
        \\}
    ;

    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse {
        try std.testing.expect(false);
        return;
    };

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler_fn);

    var saw_missing_return: bool = false;
    for (verifier.getDiagnostics()) |diag| {
        if (diag.kind == .missing_return_path) {
            saw_missing_return = true;
            try std.testing.expectEqual(
                @as(?RepairIntent, .add_trailing_return),
                diag.repair_intent,
            );
        }
    }
    try std.testing.expect(saw_missing_return);
}

/// Run the verifier over a handler that reads a property off an un-narrowed
/// optional produced by `producer`, and report whether ZTS309 fired.
/// The help text of the ZTS309 this producer raises, or null when it raises
/// none. Help rather than a bool: the repair the diagnostic names is the half
/// that decides whether the author's edit fixes the fault or only hides it.
fn optionalAccessHelp(
    allocator: std.mem.Allocator,
    import_line: []const u8,
    producer: []const u8,
    help_buffer: []u8,
) !?[]const u8 {
    const source = try allocator.print(
        \\{s}
        \\function handler(req) {{
        \\  const v = {s};
        \\  return Response.json({{ got: v.anything }});
        \\}}
    , .{ import_line, producer });
    defer allocator.free(source);

    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse return error.TestExpectedHandler;

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler_fn);

    for (verifier.getDiagnostics()) |diag| {
        if (diag.kind != .unchecked_optional_access) continue;
        const help = diag.help orelse return error.TestExpectedHelp;
        if (help.len > help_buffer.len) return error.TestHelpTooLong;
        @memcpy(help_buffer[0..help.len], help);
        return help_buffer[0..help.len];
    }
    return null;
}

test "ZTS309 reports property access on an un-narrowed optional of either kind" {
    // ZTS309 fired only when the binding's kind was `optional_object`, so a
    // property read off an un-narrowed optional STRING was reported by nothing
    // and `optionals_safe` answered PROVEN over it. That is a fail-open, not a
    // missing feature: the rule already says "a property on an optional value",
    // and `OptionalKind`'s own comments say both members must narrow before use.
    //
    // Measured, not hypothetical. A recorded corpus handler read `.ok` and
    // `.value` off `parseBearer(header)`, which returns `string | undefined`.
    // It compiled clean with optionals_safe PROVEN, and at runtime `.ok` is
    // undefined on a string, so `!parsed.ok` was always true and the handler
    // returned 401 for every request.
    //
    // Both kinds are asserted here. Checking only the string case would pass
    // again if someone later restricted the rule to strings instead.
    const allocator = std.testing.allocator;
    var help_buffer: [512]u8 = undefined;

    try std.testing.expect(try optionalAccessHelp(
        allocator,
        "import { env } from \"zttp:env\";",
        "env(\"HOME\")",
        &help_buffer,
    ) != null);
    try std.testing.expect(try optionalAccessHelp(
        allocator,
        "import { sqlOne } from \"zttp:sql\";",
        "sqlOne(\"q\")",
        &help_buffer,
    ) != null);
}

test "ZTS309 offers optional chaining only where it is a repair" {
    // The widened rule kept the help written for optional objects, so a
    // property read off `string | undefined` was answered with
    // `or use optional chaining: val?.prop`. That edit deletes the
    // member_access this check reads: ZTS309 stops firing, `optionals_safe`
    // returns to PROVEN, and `.ok` is still undefined on a string - the exact
    // runtime fault the test above cites as the reason the rule was widened.
    //
    // Asserted on both kinds. Checking only the string case would pass again
    // if the chaining line were dropped from the object case too, where it is
    // a real repair.
    const allocator = std.testing.allocator;
    var help_buffer: [512]u8 = undefined;

    const string_help = try optionalAccessHelp(
        allocator,
        "import { env } from \"zttp:env\";",
        "env(\"HOME\")",
        &help_buffer,
    ) orelse return error.TestExpectedDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, string_help, "?.") == null);
    try std.testing.expect(std.mem.indexOf(u8, string_help, "no such property") != null);

    const object_help = try optionalAccessHelp(
        allocator,
        "import { sqlOne } from \"zttp:sql\";",
        "sqlOne(\"q\")",
        &help_buffer,
    ) orelse return error.TestExpectedDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, object_help, "val?.prop") != null);
}

test "ZTS309 stays silent once the optional is narrowed" {
    // The floor under the test above: a rule that fired on every member access
    // would satisfy it while refusing correct programs. `optionalAccessHelp`
    // builds the un-narrowed shape, so this one is written out in full.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const v = env("HOME");
        \\  if (v === undefined) { return Response.text("none"); }
        \\  return Response.json({ got: v.length });
        \\}
    ;

    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse return error.TestExpectedHandler;

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler_fn);

    for (verifier.getDiagnostics()) |diag| {
        try std.testing.expect(diag.kind != .unchecked_optional_access);
    }
}

const result_import = "import { jwtVerify } from \"zttp:auth\";\n";
const optional_import = "import { cacheGet } from \"zttp:cache\";\n";

test "ZTS303 guard inside a nested block does not clear the code after the block" {
    // The guard sits inside `if (flag)`, so on the path where `flag` is false
    // the Result is unchecked when `result.value` is read.
    const nested = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  const flag = req.method === "GET";
        \\  if (flag) {
        \\    if (!result.ok) {
        \\      return Response.text("no");
        \\    }
        \\  }
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), nested.unchecked_result);

    // The same guard without a single-statement block holds the same way.
    const bare = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (req.method === "GET") if (!result.ok) return Response.text("no");
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), bare.unchecked_result);
}

test "ZTS303 guard at the top level of the handler still clears the code after it" {
    const top = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), top.unchecked_result);

    // A guard and its read in the same inner block still pair up.
    const inner = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (req.method === "GET") {
        \\    if (!result.ok) { return Response.text("no"); }
        \\    return Response.text(String(result.value));
        \\  }
        \\  return Response.text("other");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), inner.unchecked_result);

    const positive = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (result.ok) { return Response.text(String(result.value)); }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), positive.unchecked_result);
}

test "ZTS303 reassigning a Result is refused" {
    // An assignment is a use that no rule models. It is refused twice: once
    // for the assigned binding and once for the Result call that nobody binds.
    const reassigned = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  result = jwtVerify("other", "key");
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), reassigned.unchecked_result);

    // A reassignment inside a branch is refused the same way.
    const in_branch = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  if (req.method === "GET") { result = jwtVerify("other", "key"); }
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), in_branch.unchecked_result);

    // Control: no reassignment, so the guard still holds.
    const kept = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), kept.unchecked_result);
}

test "ZTS303 a Result reassigned in a loop body is refused" {
    // The assignment is refused twice, for the binding and for the unbound call.
    // The read at the top of the body keeps its guard, because no assignment is
    // accepted that could have changed the checked value.
    const for_of = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    const v = result.value;
        \\    result = jwtVerify("other", "key");
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), for_of.unchecked_result);

    // The assignment is still refused when the body checks the new value
    // before it reads `.value`.
    const rechecked = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    result = jwtVerify("other", "key");
        \\    if (!result.ok) { return Response.text("no"); }
        \\    const v = result.value;
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), rechecked.unchecked_result);

    // Control: the body never assigns the Result, so the guard still holds.
    const untouched = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    const v = result.value;
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), untouched.unchecked_result);
}

test "ZTS309 an optional re-assigned in a loop body is un-narrowed at the top of the next iteration" {
    const for_of = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  if (v === undefined) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    const n = v.length;
        \\    v = cacheGet("items", "k2");
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), for_of.unchecked_optional);

    // Control: the body narrows the new value before it reads `.length`.
    const rechecked = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  if (v === undefined) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    v = cacheGet("items", "k2");
        \\    if (v === undefined) { return Response.text("no"); }
        \\    const n = v.length;
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), rechecked.unchecked_optional);

    // Control: the body never assigns the optional, so the narrowing still holds.
    const untouched = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  if (v === undefined) { return Response.text("no"); }
        \\  for (const x of [1, 2]) {
        \\    const n = v.length;
        \\  }
        \\  return Response.text("done");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), untouched.unchecked_optional);
}

test "ZTS309 reassigning an optional-producing call un-narrows the binding" {
    const renarrowed = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  v = "x";
        \\  v = cacheGet("items", "k2");
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), renarrowed.unchecked_optional);

    // Control: a non-optional assignment still narrows for the rest of the block.
    const narrowed = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  v = "x";
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), narrowed.unchecked_optional);

    // A narrowing assignment inside a branch does not narrow the other path.
    const branch = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  if (req.method === "GET") { v = "x"; }
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), branch.unchecked_optional);
}

test "ZTS309 optional guard scope follows the block that holds it" {
    const undefined_guard = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  const v = cacheGet("items", "k");
        \\  if (v === undefined) { return Response.text("none"); }
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), undefined_guard.unchecked_optional);

    const nested = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  const v = cacheGet("items", "k");
        \\  if (req.method === "GET") {
        \\    if (v === undefined) { return Response.text("none"); }
        \\  }
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), nested.unchecked_optional);
}

test "ZTS303 reports an unchecked Result read inside an assert condition" {
    const source = result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  assert result.value !== undefined, Response.text("no");
        \\  return Response.text("ok");
        \\}
    ;
    const counts = try routeVerifierCounts(source);
    try std.testing.expectEqual(@as(u32, 1), counts.unchecked_result);
    // The assert reads `result`, so it is not a dead variable.
    try std.testing.expectEqual(@as(u32, 0), try countUnusedVariableWarnings(source));
}

test "ZTS303 reports an unchecked Result read inside a closure" {
    const arrow = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  const g = () => String(result.value);
        \\  return Response.text(g());
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), arrow.unchecked_result);

    const arrow_block = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  const g = () => { return String(result.value); };
        \\  return Response.text(g());
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), arrow_block.unchecked_result);

    const declared = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  function g() { return String(result.value); }
        \\  return Response.text(g());
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), declared.unchecked_result);
}

test "ZTS303 reports an unchecked Result read through a spread" {
    const counts = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  const items = [...result.value];
        \\  return Response.text(String(items.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), counts.unchecked_result);
}

test "ZTS303 a guard inside a closure does not clear the enclosing read" {
    const declared = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  function g() {
        \\    if (result.ok === false) { return "no"; }
        \\    return "yes";
        \\  }
        \\  const t = g();
        \\  return Response.text([String(result.value), t].join(""));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), declared.unchecked_result);

    const arrow = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  const g = () => {
        \\    if (result.ok === false) { return "no"; }
        \\    return "yes";
        \\  };
        \\  const t = g();
        \\  return Response.text([String(result.value), t].join(""));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), arrow.unchecked_result);
}

test "ZTS309 an assignment inside a closure does not narrow the enclosing read" {
    const counts = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  const g = () => {
        \\    v = "x";
        \\    return 1;
        \\  };
        \\  const len = v.length;
        \\  const n = g();
        \\  v = "y";
        \\  return Response.text(String(len) + String(n) + v);
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), counts.unchecked_optional);
}

test "a reassignment inside a closure is refused for a Result and un-narrows an optional" {
    const result_kill = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  let result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  const g = () => {
        \\    result = jwtVerify("x", "k");
        \\    return 1;
        \\  };
        \\  g();
        \\  return Response.text(String(result.value));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), result_kill.unchecked_result);

    const optional_kill = try routeVerifierCounts(optional_import ++
        \\function handler(req) {
        \\  let v = cacheGet("items", "k");
        \\  if (v === undefined) { return Response.text("none"); }
        \\  const g = () => {
        \\    v = cacheGet("items", "k2");
        \\    return 1;
        \\  };
        \\  g();
        \\  return Response.text(String(v.length));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), optional_kill.unchecked_optional);
}

test "ZTS303 closure walks keep the precision of the checks outside them" {
    // A closure that does not touch the Result adds nothing.
    const untouched = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  const g = () => 1;
        \\  return Response.text(String(result.value) + String(g()));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), untouched.unchecked_result);

    // Documented precision cost: a closure can run at any later time, so a
    // check around its definition does not hold inside it.
    const inside_guard = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (result.ok) {
        \\    const g = () => String(result.value);
        \\    return Response.text(g());
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), inside_guard.unchecked_result);

    // The flags are restored after the closure: the guard still holds after it.
    const restored = try routeVerifierCounts(result_import ++
        \\function handler(req) {
        \\  const result = jwtVerify("token", "key");
        \\  if (!result.ok) { return Response.text("no"); }
        \\  const g = () => 1;
        \\  const n = g();
        \\  return Response.text(String(result.value) + String(n));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), restored.unchecked_result);
}

const import_corpus = @import("tests/import_corpus.zig");

/// Parse `source` and answer `functionAlwaysReturns` for the first node
/// carrying `tag`. Used to reach a body shape by tag rather than by position,
/// so the totality classification can be probed per tag.
fn totalityOfFirstNode(source: []const u8, tag: NodeTag) !bool {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    for (0..view.nodeCount()) |idx| {
        const i: NodeIndex = @intCast(idx);
        if (view.getTag(i) == tag) return functionAlwaysReturns(view, i);
    }
    return error.TagNotFound;
}

const ResultRefusals = struct { count: u32 = 0, first_line: u32 = 0 };

/// The ZTS303 diagnostics of `source`, parsed in the mode production uses.
fn resultRefusals(source: []const u8) !ResultRefusals {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler = findHandlerFunction(view, root) orelse return error.HandlerNotFound;

    var verifier = HandlerVerifier.init(allocator, view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler);

    var refusals: ResultRefusals = .{};
    for (verifier.getDiagnostics()) |diagnostic| {
        if (diagnostic.kind != .unchecked_result_value) continue;
        if (refusals.count == 0) refusals.first_line = (view.getLoc(diagnostic.node) orelse return error.NoLocation).line;
        refusals.count += 1;
    }
    return refusals;
}

const validate_prefix =
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
    \\
;
const json_prefix = "import { parseJson } from \"zttp:json\";\n";
const result_prefix = "import { ok, err, unwrapOr, collectAll, andThen, mapResult } from \"zttp:result\";\n";

test "ZTS303 p_helper: a Result passed to a helper that reads it is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function reader(r: unknown): number {
        \\  const v = r.value;
        \\  return 1;
        \\}
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  const n = reader(late);
        \\  return Response.json({ n: n }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 9), refusals.first_line);
}

test "ZTS303 p_alias: an alias of a Result is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  const alias = late;
        \\  const v = alias.value;
        \\  return Response.json({ n: 1 }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_obj: a Result stored in an object literal is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  const box = { r: late };
        \\  const v = box.r.value;
        \\  return Response.json({ n: 1 }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_chain: a member read on an unbound Result call is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const v = validateJson("todo", "{}").value;
        \\  return Response.json({ n: 1 }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 p_sibling: a sibling function that reads a Result unchecked is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function inner(): number {
        \\  const local = validateJson("todo", "{}");
        \\  const v = local.value;
        \\  return 1;
        \\}
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const n = inner();
        \\  return Response.json({ n: n }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_eqvar: a comparison of ok with a variable is not a guard" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  const flag = req.method === "GET";
        \\  if (late.ok === flag) {
        \\    const v = late.value;
        \\  }
        \\  return Response.json({ n: 1 }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 7), refusals.first_line);
}

test "ZTS303 p_err: an unguarded error read is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  const v = late.error;
        \\  return Response.json({ n: 1 }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_errors: an unguarded errors read is refused" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  return Response.json({ e: late.errors }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_spread: spreading a Result is refused" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  const box = { ...r };
        \\  return Response.json({ v: box.value });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 p_computed: a non-literal computed key on a Result is refused" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  const k = "value";
        \\  const v = r[k];
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 p_closure_dup2: a closure over a Result name that two bindings share is refused" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  if (req.method === "GET") {
        \\    const r = parseJson("1");
        \\    if (!r.ok) {
        \\      return Response.json({ bad: true }, { status: 400 });
        \\    }
        \\    return Response.json({ v: r.value });
        \\  }
        \\  const r = parseJson("2");
        \\  const read = (): unknown => {
        \\    return r.value;
        \\  };
        \\  return Response.json({ v: read() });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 12), refusals.first_line);
}

test "ZTS303 an unchecked requestJson read is refused" {
    const refusals = try resultRefusals(
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const v = requestJson(req).value;
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 2), refusals.first_line);
}

test "ZTS303 a bound requestText read without a guard is refused" {
    const refusals = try resultRefusals(
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const body = requestText(req);
        \\  return Response.text(body.value);
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 3), refusals.first_line);
}

test "ZTS303 isOk is a method call on a Result and is not a guard" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  if (r.isOk()) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 2), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 a strict comparison of ok with true is not a guard" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  if (r.ok === true) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 a match on a Result is refused" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  const v = match (r) { when { ok: true, value: x }: x default: 0 };
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 an error read in the then arm of an ok guard has the wrong polarity" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  if (r.ok) {
        \\    return Response.json({ e: r.error });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 a value read in the then arm of an err guard has the wrong polarity" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  if (!r.ok) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 5), refusals.first_line);
}

test "ZTS303 accepts an errors read in the then arm of an err guard" {
    const refusals = try resultRefusals(validate_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  const late = validateJson("todo", "{}");
        \\  if (!late.ok) {
        \\    return Response.json({ e: late.errors }, { status: 400 });
        \\  }
        \\  return Response.json({ v: late.value }, { status: 200 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 accepts an error read after an ok guard that returns" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  if (r.ok) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.json({ e: r.error }, { status: 400 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 accepts an error read that supplies a fallback" {
    const refusals = try resultRefusals(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = parseJson("1");
        \\  const message = r.error ?? "none";
        \\  return Response.text(String(message));
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 accepts a Result at a position the export declares as a Result" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const r = ok(1);
        \\  const n = unwrapOr(r, 0);
        \\  return Response.json({ n: n });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 accepts an array literal of Results passed to collectAll" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const all = collectAll([first, ok(2), err("x")]);
        \\  if (!all.ok) {
        \\    return Response.json({ e: all.error }, { status: 400 });
        \\  }
        \\  return Response.json({ v: all.value });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 refuses a Result binding passed to collectAll without an array literal" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const all = collectAll(first);
        \\  return Response.json({ n: 1 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 refuses a Result nested in the array that collectAll receives" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const all = collectAll([[first]]);
        \\  return Response.json({ n: 1 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 accepts the Result that an expression-bodied callback returns to andThen" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const next = andThen(first, (n) => ok(n + 1));
        \\  if (!next.ok) {
        \\    return Response.json({ e: next.error }, { status: 400 });
        \\  }
        \\  return Response.json({ v: next.value });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "ZTS303 refuses a Result that a callback returns to mapResult" {
    // `mapResult` wraps the callback's return in the payload, so a Result
    // returned there escapes into an untracked value.
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const next = mapResult(first, (n) => ok(n));
        \\  return Response.json({ n: 1 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 refuses a Result returned from a block-bodied callback to andThen" {
    const refusals = try resultRefusals(result_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const first = ok(1);
        \\  const next = andThen(first, (n) => { return ok(n); });
        \\  return Response.json({ n: 1 });
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), refusals.count);
    try std.testing.expectEqual(@as(u32, 4), refusals.first_line);
}

test "ZTS303 accepts a guarded requestText read" {
    const refusals = try resultRefusals(
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const body = requestText(req);
        \\  if (!body.ok) {
        \\    return Response.text("bad", { status: 400 });
        \\  }
        \\  return Response.text(body.value);
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), refusals.count);
}

test "an assert statement is not a total function body" {
    // The discriminating probe for the fail-open this switch used to carry.
    // `functionAlwaysReturns` enumerated the tags that return false and ended
    // in `else => true`, so `.assert_stmt` - a statement that returns on no
    // path - was credited with "every path returns". The answer is written
    // straight into `CapsuleFacts.total`, which feeds `spec_discharge` and the
    // `response_total` property, so the unknown case granted a proof.
    //
    // A tag added to the IR and not classified is now a compile error rather
    // than a silent `true`. This test is the runtime half: it fails if a
    // catch-all returning `true` is ever reintroduced.
    try std.testing.expect(!try totalityOfFirstNode(
        "function handler(req) { assert req; return Response.text(\"ok\"); }",
        .assert_stmt,
    ));
}

test "a for-of statement is not a total function body" {
    // The loop may run zero times, so the body returning is not the function
    // returning. Already classified before the switch was made exhaustive;
    // pinned so the classification cannot drift with the rewrite.
    try std.testing.expect(!try totalityOfFirstNode(
        "function handler(req) { for (const x of [1]) { return x; } return 0; }",
        .for_of_stmt,
    ));
}

test "an expression-bodied arrow is a total function body" {
    // The reason the old catch-all existed, kept as an explicit arm: the
    // expression IS the return value. The control for the two probes above -
    // without it a rewrite that answered `false` everywhere would pass them
    // while breaking every helper capsule's `total` fact.
    try std.testing.expect(try totalityOfFirstNode(
        "const f = (x) => x + 1;",
        .binary_op,
    ));
}

/// Parse `source` and answer `functionAlwaysReturns` for the body of its first
/// arrow function. Reached through the arrow node rather than by finding a
/// `.block` by tag: the parser emits the inner blocks first, so scanning for a
/// tag lands on the wrong one.
fn totalityOfFirstArrowBody(source: []const u8) !bool {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    for (0..view.nodeCount()) |idx| {
        const i: NodeIndex = @intCast(idx);
        if (view.getTag(i) != .arrow_function) continue;
        const fe = view.getFunction(i) orelse return error.TagNotFound;
        return functionAlwaysReturns(view, fe.body);
    }
    return error.TagNotFound;
}

test "a block body that returns on only one path is not total" {
    try std.testing.expect(!try totalityOfFirstArrowBody("const f = (x) => { if (x) { return 1; } };"));
}

test "a block body that returns on every path is total" {
    // The other half of the block arm, so a rewrite cannot satisfy the test
    // above by answering `false` for every block.
    try std.testing.expect(try totalityOfFirstArrowBody(
        "const f = (x) => { if (x) { return 1; } return 2; };",
    ));
}

test "the import scan splits tracked builtins into result and optional slots" {
    // Replaces the differential that proved this scan matches the pre-C1
    // implementation. The no-table divergence keeps its own test below.
    const allocator = std.testing.allocator;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator,
        \\import { jwtVerify } from "zttp:auth";
        \\import { env } from "zttp:env";
        \\import { sha256 } from "zttp:crypto";
        \\import { thing } from "zttp-ext:unknown";
    );
    defer parser.deinit();
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var verifier = HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    verifier.scanImports();

    // env returns an optional string; jwtVerify returns a Result, which the
    // scan leaves to `resultCallee`; sha256 returns a plain string and is
    // tracked by neither; the unresolved module is skipped.
    try std.testing.expectEqual(@as(usize, 1), verifier.optional_function_slots.items.len);
}

test "with no atom table the index resolves imports this verifier used to miss" {
    // An ACCEPTED behavior change, recorded rather than hidden. See C1 finding 5.
    //
    // Three of the six analyzers had three different atom resolvers. Unifying
    // them onto one index necessarily unifies atom resolution, and the resolver
    // the index carries is bool_checker's, because nine sound-mode tests need
    // its string-constant fallback. This verifier's own resolver returned null
    // for a non-predefined atom with no table, so it tracked nothing at all on
    // that path.
    //
    // Direction: strictly more imports seen, never fewer. Scope: no production
    // path, because every production `ParsedModule.fromExisting` site passes a
    // real atom table and precompile passes `&atoms` directly; the null-passing
    // sites are test blocks. All 11 of this file's tests pass either way.
    const allocator = std.testing.allocator;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, "import { env } from \"zttp:env\";\n");
    defer parser.deinit();
    // Deliberately no setAtomTable.
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var verifier = HandlerVerifier.init(allocator, ir_view, null, null, null);
    defer verifier.deinit();
    verifier.scanImports();

    // `env` returns an optional string, so it lands in the optional list. Before
    // C1 this was 0 on the no-table path.
    try std.testing.expectEqual(@as(usize, 1), verifier.optional_function_slots.items.len);
}

/// The shape and the message of the first ZTS303 diagnostic of `source`.
const FirstShape = struct { shape: ResultShape, message: []const u8 };

fn firstResultShape(source: []const u8) !FirstShape {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler = findHandlerFunction(view, root) orelse return error.HandlerNotFound;

    var verifier = HandlerVerifier.init(allocator, view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler);

    for (verifier.getDiagnostics()) |diagnostic| {
        if (diagnostic.kind != .unchecked_result_value) continue;
        return .{ .shape = diagnostic.result_shape orelse return error.NoShape, .message = diagnostic.message };
    }
    return error.NoRefusal;
}

const shape_head = json_prefix ++
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = parseJson("1");
    \\
;

test "ZTS303 shape: an unguarded value read keeps the original message" {
    const first = try firstResultShape(shape_head ++
        \\  const v = r.value;
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(ResultShape.unchecked_value, first.shape);
    try std.testing.expectEqualStrings("result.value accessed without checking result.ok first", first.message);
}

test "ZTS303 shape: an unguarded error read" {
    const first = try firstResultShape(shape_head ++
        \\  const e = r.error;
        \\  return Response.json({ e: e });
        \\}
    );
    try std.testing.expectEqual(ResultShape.unchecked_error, first.shape);
    try std.testing.expectEqualStrings("result.error read where result.ok is not known to be false", first.message);
}

test "ZTS303 shape: an error read on the ok path" {
    const first = try firstResultShape(shape_head ++
        \\  if (r.ok) {
        \\    return Response.json({ e: r.error });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(ResultShape.error_on_ok_path, first.shape);
}

test "ZTS303 shape: a value read after a comparison of ok with true" {
    const first = try firstResultShape(shape_head ++
        \\  if (r.ok === true) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(ResultShape.unrecognized_guard, first.shape);
}

test "ZTS303 shape: a closure reads a Result without its own check" {
    const first = try firstResultShape(shape_head ++
        \\  const read = (): unknown => {
        \\    return r.value;
        \\  };
        \\  return Response.json({ v: read() });
        \\}
    );
    try std.testing.expectEqual(ResultShape.closure_read, first.shape);
}

test "ZTS303 shape: a read inside an assert statement" {
    const first = try firstResultShape(shape_head ++
        \\  assert r.value !== undefined, Response.text("no");
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.flat_guard, first.shape);
}

test "ZTS303 shape: an unknown member" {
    const first = try firstResultShape(shape_head ++
        \\  const x = r.foo;
        \\  return Response.json({ x: x });
        \\}
    );
    try std.testing.expectEqual(ResultShape.unknown_member, first.shape);
}

test "ZTS303 shape: a computed key" {
    const first = try firstResultShape(shape_head ++
        \\  const k = "value";
        \\  const v = r[k];
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(ResultShape.computed_key, first.shape);
}

test "ZTS303 shape: a method call on a Result" {
    const first = try firstResultShape(shape_head ++
        \\  if (r.isOk()) {
        \\    return Response.text("yes");
        \\  }
        \\  return Response.text("no");
        \\}
    );
    try std.testing.expectEqual(ResultShape.method_call, first.shape);
}

test "ZTS303 shape: an alias of a Result" {
    const first = try firstResultShape(shape_head ++
        \\  const a = r;
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.alias_or_reassignment, first.shape);
}

test "ZTS303 shape: a Result function named without a call" {
    const first = try firstResultShape(shape_head ++
        \\  const f = parseJson;
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.function_alias, first.shape);
}

test "ZTS303 shape: a Result passed as an argument" {
    const first = try firstResultShape(shape_head ++
        \\  const s = String(r);
        \\  return Response.text(s);
        \\}
    );
    try std.testing.expectEqual(ResultShape.call_argument, first.shape);
}

test "ZTS303 shape: a Result returned" {
    const first = try firstResultShape(shape_head ++
        \\  if (req.method === "GET") {
        \\    return r;
        \\  }
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.returned, first.shape);
}

test "ZTS303 shape: a Result stored in an object" {
    const first = try firstResultShape(shape_head ++
        \\  const box = { r: r };
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.collection_member, first.shape);
}

test "ZTS303 shape: a Result in an array" {
    const first = try firstResultShape(shape_head ++
        \\  const list = [r];
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.collection_member, first.shape);
}

test "ZTS303 shape: a spread Result" {
    const first = try firstResultShape(shape_head ++
        \\  const box = { ...r };
        \\  return Response.text("ok");
        \\}
    );
    try std.testing.expectEqual(ResultShape.spread, first.shape);
}

test "ZTS303 shape: a match on a Result" {
    const first = try firstResultShape(shape_head ++
        \\  const v = match (r) { when { ok: true, value: x }: x default: 0 };
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(ResultShape.match_subject, first.shape);
}

test "ZTS303 shape: a member read on an unbound Result call" {
    const first = try firstResultShape(shape_head ++
        \\  const v = parseJson("2").value;
        \\  return Response.json({ v: v });
        \\}
    );
    try std.testing.expectEqual(ResultShape.unbound_call, first.shape);
}

test "ZTS303 shape: a captured name that two Result bindings share" {
    const first = try firstResultShape(json_prefix ++
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  if (req.method === "GET") {
        \\    const r = parseJson("1");
        \\    if (!r.ok) {
        \\      return Response.json({ bad: true }, { status: 400 });
        \\    }
        \\    return Response.json({ v: r.value });
        \\  }
        \\  const r = parseJson("2");
        \\  const read = (): unknown => {
        \\    return r.value;
        \\  };
        \\  return Response.json({ v: read() });
        \\}
    );
    try std.testing.expectEqual(ResultShape.ambiguous_upvalue, first.shape);
}

test "ZTS303 shape: any other use of a Result" {
    const first = try firstResultShape(shape_head ++
        \\  const same = r === r;
        \\  return Response.json({ same: same });
        \\}
    );
    try std.testing.expectEqual(ResultShape.other_use, first.shape);
}
