//! Compile-Time Exhaustive Test Generation
//!
//! Enumerates every execution path through a handler function and generates
//! a declarative test case (JSONL) for each one. Paths are finite because
//! zttp's JS subset has no back-edges (while/do-while banned) and no
//! exceptions (try/catch banned). The IR tree IS the control flow graph.
//!
//! Each test specifies: the request that triggers the path, virtual module
//! stubs with concrete return values derived from branch conditions, and
//! the expected response status from the return statement.
//!
//! Output format matches the existing declarative test runner (test_runner.zig)
//! so generated tests are immediately runnable via --test.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const atom_table = @import("zts-engine").atom_table;
const builtin_modules = @import("zts-engine").builtin_modules;
const module_facts_mod = @import("module_facts.zig");
const route_resolution = @import("route_resolution.zig");
const effect_inference = @import("effect_inference.zig");
const mb = @import("zts-engine").module_binding;
const bool_checker_mod = @import("bool_checker.zig");
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");
const status_check = @import("status_check.zig");
const handler_contract = @import("zts-contracts").handler_contract;
const contract_types = @import("zts-contracts").contract_types;

const Node = ir.Node;
pub const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
pub const null_node = ir.null_node;
const packBindingKey = bool_checker_mod.packBindingKey;

// ---------------------------------------------------------------------------
// Path constraints
// ---------------------------------------------------------------------------

pub const Constraint = union(enum) {
    req_method: []const u8,
    /// The request method must differ from this value: the false side of a
    /// `req.method` comparison.
    req_method_not: []const u8,
    req_url: []const u8,
    /// The request URL must differ from this value.
    req_url_not: []const u8,
    stub_truthy: StubInfo,
    stub_falsy: StubInfo,
    result_ok: StubInfo,
    result_not_ok: StubInfo,
    /// A status test on an `ok`-record call that is not the complement of
    /// `ok`. It is not a failure path and no coverage counts it: it only
    /// fixes the status that the call's stub carries on this path.
    status_is: StatusIs,

    /// Whether this constraint represents an I/O failure condition.
    pub fn isFailure(self: Constraint) bool {
        return switch (self) {
            .stub_falsy, .result_not_ok => true,
            else => false,
        };
    }
};

pub const StubInfo = struct {
    module: []const u8,
    func: []const u8,
    returns: mb.ReturnKind,
    call_site: NodeIndex = null_node,
};

/// The call's `status` comparison must take the value `expect` on this path.
pub const StatusIs = struct {
    stub: StubInfo,
    comparison: status_check.Comparison,
    expect: bool,
};

// ---------------------------------------------------------------------------
// Generated test
// ---------------------------------------------------------------------------

pub const IoStub = struct {
    seq: u32,
    module: []const u8,
    func: []const u8,
    result_json: []const u8,
    call_site: NodeIndex = null_node,
    /// True when the call is the left operand of `??` and its export returns an
    /// optional. The fallback is the explicit failure path for the absent
    /// value, so fault coverage counts the site as covered.
    absent_handled: bool = false,
    /// Canonical arg signature (pipe-delimited), owned when non-null.
    /// See `handler_contract.PathIoCall.arg_signature` for the format.
    arg_signature: ?[]const u8 = null,
};

pub const GeneratedTest = struct {
    name: []const u8,
    method: []const u8,
    url: []const u8,
    has_auth_header: bool,
    expected_status: u16,
    io_stubs: std.ArrayList(IoStub),
    constraints: []const Constraint = &.{},
    /// True when this path begins at a function dispatched by `routerMatch`.
    route_root: bool = false,
    root_function: NodeIndex = null_node,
};

fn stubInfoEql(a: StubInfo, b: StubInfo) bool {
    return std.mem.eql(u8, a.module, b.module) and
        std.mem.eql(u8, a.func, b.func) and
        a.returns == b.returns and
        a.call_site == b.call_site;
}

fn constraintEql(a: Constraint, b: Constraint) bool {
    return switch (a) {
        .req_method => |x| b == .req_method and std.mem.eql(u8, x, b.req_method),
        .req_method_not => |x| b == .req_method_not and std.mem.eql(u8, x, b.req_method_not),
        .req_url => |x| b == .req_url and std.mem.eql(u8, x, b.req_url),
        .req_url_not => |x| b == .req_url_not and std.mem.eql(u8, x, b.req_url_not),
        .stub_truthy => |x| b == .stub_truthy and stubInfoEql(x, b.stub_truthy),
        .stub_falsy => |x| b == .stub_falsy and stubInfoEql(x, b.stub_falsy),
        .result_ok => |x| b == .result_ok and stubInfoEql(x, b.result_ok),
        .result_not_ok => |x| b == .result_not_ok and stubInfoEql(x, b.result_not_ok),
        .status_is => |x| b == .status_is and stubInfoEql(x.stub, b.status_is.stub) and
            x.expect == b.status_is.expect and
            x.comparison.op == b.status_is.comparison.op and
            x.comparison.literal_left == b.status_is.comparison.literal_left and
            x.comparison.literal == b.status_is.comparison.literal,
    };
}

/// The contract condition for a constraint, or null for one the contract does
/// not record: a status test that is not a failure path, and a negative request
/// constraint. `PathCondition.Kind` has no negative request kind, and the
/// contract bytes do not gain one.
fn dupePathCondition(
    allocator: std.mem.Allocator,
    constraint: Constraint,
) !?handler_contract.PathCondition {
    return switch (constraint) {
        .status_is, .req_method_not, .req_url_not => null,
        .req_method => |value| .{
            .kind = .req_method,
            .value = try allocator.dupe(u8, value),
        },
        .req_url => |value| .{
            .kind = .req_url,
            .value = try allocator.dupe(u8, value),
        },
        .stub_truthy, .result_ok => |info| try dupeIoCondition(allocator, .io_ok, info),
        .stub_falsy, .result_not_ok => |info| try dupeIoCondition(allocator, .io_fail, info),
    };
}

fn dupeIoCondition(
    allocator: std.mem.Allocator,
    kind: handler_contract.PathCondition.Kind,
    info: StubInfo,
) !handler_contract.PathCondition {
    const module = try allocator.dupe(u8, info.module);
    errdefer allocator.free(module);
    const func = try allocator.dupe(u8, info.func);
    return .{ .kind = kind, .module = module, .func = func };
}

fn dupePathIoCall(
    allocator: std.mem.Allocator,
    stub: IoStub,
) !handler_contract.PathIoCall {
    const module = try allocator.dupe(u8, stub.module);
    errdefer allocator.free(module);
    const func = try allocator.dupe(u8, stub.func);
    errdefer allocator.free(func);
    const arg_signature = if (stub.arg_signature) |signature|
        try allocator.dupe(u8, signature)
    else
        null;
    return .{
        .module = module,
        .func = func,
        .arg_signature = arg_signature,
    };
}

/// The version of the path analysis, hashed into `policyHash`.
///
/// The path generator and the fault-coverage checker that reads its paths
/// decide `fault_covered` and the other path properties. The acceptance kernel
/// takes those on the producer's word, and rule metadata does not move when the
/// analysis learns to prove less or more. Any change to what fault coverage can
/// prove (which calls count as failable, which forks the generator emits, what
/// blocks `fault_covered`, how a site is keyed) MUST bump this number. The bump
/// moves `policy_hash`, so a contract stamped by an older analysis no longer
/// matches the policy and is rebuilt instead of trusted. It lives here, beside
/// the walk that the fault-coverage checker consumes, as `flow_analyzer_version`
/// lives with the flow checker.
///
/// 1 is the implicit version before this constant existed: no path version was
/// hashed. 2 is the analysis after every failable call counts as a site, a call
/// the walk cannot see or a non-exhaustive walk blocks `fault_covered`, and
/// `fetch` is an upstream call forked by `res.ok`. 3 (R4) enumerates the
/// short-circuit cases of an `&&` condition, counts failable calls in imported
/// files and blocks on any import it cannot scan, forks on a `res.status`
/// comparison that is the complement of `ok`, and counts the severities that
/// F5 declared.
pub const path_analyzer_version: u32 = 3;

/// Methods tried in order for a path whose constraints name no method.
const request_method_candidates = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };

/// URLs tried in order for a path whose constraints name no URL.
const request_url_candidates = [_][]const u8{
    "/",
    "/__zttp_alternate__",
    "/__zttp_alternate_2__",
    "/__zttp_alternate_3__",
};

// ---------------------------------------------------------------------------
// PathGenerator
// ---------------------------------------------------------------------------

pub const PathGenerator = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,

    /// Binding tracking: local slot -> module function metadata.
    module_fn_bindings: std.AutoHashMapUnmanaged(u16, FnMeta),
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the generator. Null means build a private one.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Variable init tracking: packed(scope, slot) -> NodeIndex of init expression.
    var_inits: std.AutoHashMapUnmanaged(u32, NodeIndex),
    /// Request parameter binding key.
    req_binding_key: ?u32,
    /// Slot bound to req.method.
    method_binding_key: ?u32,
    /// Slot bound to req.url or req.path.
    url_binding_key: ?u32,

    /// Accumulated constraints for current path.
    constraints: std.ArrayList(Constraint),
    /// Accumulated I/O call sequence for current path.
    io_seq: std.ArrayList(IoCall),
    /// Active for...of loop bounds for the current path.
    loop_stack: std.ArrayList(LoopFrame),
    /// Owned provenance descriptions from popped loop frames. I/O and path
    /// cost snapshots borrow these strings until PathGenerator.deinit.
    retired_loop_descs: std.ArrayList([]const u8),
    /// Per-emitted-path I/O multiplicity snapshots.
    path_costs: std.ArrayList(PathCost),
    /// Completed test cases.
    tests: std.ArrayList(GeneratedTest),
    /// Prefix of `tests` produced by the exported handler root.
    handler_tests_end: usize,
    path_count: u32,
    /// First path-cost snapshot produced by a route root. Null when the source
    /// has no resolved route roots.
    route_costs_start: ?usize,
    walking_route_root: bool,
    walking_root_function: NodeIndex,
    /// Set when a construct was walked as a representative skeleton rather than
    /// enumerated. A loop body is walked once, so the paths through iteration
    /// counts other than one - including zero - are never emitted. Spec gap 11:
    /// a summary must not be presented as exhaustive coverage.
    summarized: bool,
    /// Set when the handler is recursive or reaches a recursive function. The
    /// generator does not follow calls into user functions at all, so the
    /// recursion is neither enumerated nor costed, and no constant bound over
    /// it is earned. Spec 5.6: no runtime stack cap may be presented as a
    /// termination proof.
    reaches_recursion: bool,
    /// Set when a `routerMatch` route table or dispatched handler cannot be
    /// resolved to a closed set of functions. Paths and cost facts are then
    /// incomplete, so consumers must not treat the emitted set as exhaustive.
    unresolved_route_dispatch: bool,
    /// Number of calls through a handler value returned by `routerMatch`.
    route_dispatch_count: u32,
    /// Set when the handler does not return one routed response directly.
    route_composition_unmodeled: bool,
    /// Calls to exports with a failure severity that no emitted path holds as
    /// an I/O stub and that no `??` answers. Fault coverage can neither count
    /// nor cover these, so it must not claim the handler is covered. Computed
    /// at the end of `generate`.
    unseen_failable_calls: std.ArrayList(UnseenCall),
    /// What the caller learned about the files the handler imports, one entry
    /// per import record. Borrowed; must outlive the generator. Null means the
    /// caller gave no answer at all (no filesystem, or it did not look), so no
    /// non-builtin import record has an entry and each counts as unseen.
    imported_scan: ?[]const ImportScanEntry = null,

    pub const MAX_PATHS = 1024;

    /// Why an import record of the handler has no clean answer.
    pub const BlockReason = enum {
        /// The caller gave no entry for this record.
        not_scanned,
        /// A specifier that is neither `./` nor `../`, such as a bare package.
        not_relative,
        /// A file on the chain could not be resolved, read, stripped, or parsed.
        unreadable,
        /// The import chain went past the depth limit.
        too_deep,
        /// A partner module. Partner exports have no failure model.
        partner,

        pub fn text(self: BlockReason) []const u8 {
            return switch (self) {
                .not_scanned => "not scanned",
                .not_relative => "not a relative path",
                .unreadable => "unreadable",
                .too_deep => "import chain too deep",
                .partner => "partner module",
            };
        }
    };

    /// The answer for one import record of the handler.
    pub const ImportScan = union(enum) {
        /// Every file reachable from the import was scanned and holds no
        /// failable call or value use.
        clean,
        /// A file reachable from the import holds a failable call or value use.
        /// `file` names that file, as the handler reaches it.
        failable: struct {
            file: []const u8,
            module: []const u8,
            func: []const u8,
        },
        /// The scan could not reach a verdict. `file` names where it stopped.
        blocked: struct {
            file: []const u8,
            reason: BlockReason,
        },
    };

    /// The scan answer for the import record bound to local slot `slot`.
    pub const ImportScanEntry = struct {
        slot: u16,
        scan: ImportScan,
    };

    /// Where a failable call sits when it is not in the handler file.
    pub const ImportedCause = struct {
        /// The sibling file, or the import specifier when no file was reached.
        file: []const u8,
        /// Null when `file` holds the call (`UnseenCall.module` and `func`
        /// name it). Set when the scan could not reach a verdict.
        blocked: ?BlockReason,
    };

    /// A call to a failable export that the walk never recorded on a path.
    pub const UnseenCall = struct {
        /// The call node in the handler file. For an imported file, the
        /// `import_decl` node in the handler that binds the record.
        node: NodeIndex,
        module: []const u8,
        func: []const u8,
        /// Null for a call in the handler file.
        imported: ?ImportedCause = null,

        /// The text that names this call in a report. Static for a call in
        /// the handler file; allocated for an imported file. The caller frees
        /// the result when `owned` is true.
        pub fn describe(self: UnseenCall, allocator: std.mem.Allocator) error{OutOfMemory}!struct { text: []const u8, owned: bool } {
            const cause = self.imported orelse return .{ .text = self.func, .owned = false };
            const text = if (cause.blocked) |reason|
                try std.fmt.allocPrint(allocator, "{s} ({s})", .{ cause.file, reason.text() })
            else
                try std.fmt.allocPrint(allocator, "{s} in {s}", .{ self.func, cause.file });
            return .{ .text = text, .owned = true };
        }
    };

    const FnMeta = struct {
        module: []const u8,
        func: []const u8,
        returns: mb.ReturnKind,
        severity: mb.FailureSeverity,
        /// The export is failable, does not return a `Result`, and its parsed
        /// return type is a record with a top-level `ok: boolean` field (the
        /// `fetch` response), so `x.ok` on a binding initialized from a call forks
        /// success and failure. A `Result` export forks through `returns` alone.
        ok_record: bool = false,
    };

    const IoCall = struct {
        module: []const u8,
        func: []const u8,
        returns: mb.ReturnKind,
        ok_record: bool = false,
        binding_key: ?u32,
        mult: Mult,
        /// IR node of the originating call expression. Used at emission
        /// time to compute an argument signature for the behavior-path
        /// canonicalizer. null when the call was tracked through a wrapper
        /// (e.g. nullish-coalesce) and the original node is unavailable.
        call_node: ?NodeIndex,
        /// The call is the left operand of `??` and returns an optional, so
        /// the fallback answers its absent value.
        absent_handled: bool = false,
    };

    const LoopFrame = struct {
        bound: LoopBound,
    };

    /// The trip-count bound resolved for one `for...of` iterable.
    pub const LoopBound = union(enum) {
        /// Trip count statically known.
        constant: u32,
        /// Trip count = |source|. desc is owned by PathGenerator.
        symbolic: contract_types.BoundProvenance,
        /// Iterable not identifiable at all. desc is owned by PathGenerator.
        unknown: contract_types.BoundProvenance,
    };

    const SourceMult = struct {
        coefficient: u32,
        source: contract_types.BoundProvenance,
    };

    const Mult = union(enum) {
        once,
        constant_x: u32,
        per_source: SourceMult,
        unbounded: contract_types.BoundProvenance,
    };

    const PathCostEntry = struct {
        module: []const u8,
        mult: Mult,
    };

    const PathCost = struct {
        entries: std.ArrayList(PathCostEntry) = .empty,

        fn deinit(self: *PathCost, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }
    };

    const ModuleCost = struct {
        module: []const u8,
        bound: contract_types.Bound,
    };

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*atom_table.AtomTable) PathGenerator {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .module_fn_bindings = .empty,
            .var_inits = .empty,
            .req_binding_key = null,
            .method_binding_key = null,
            .url_binding_key = null,
            .constraints = .empty,
            .io_seq = .empty,
            .loop_stack = .empty,
            .retired_loop_descs = .empty,
            .path_costs = .empty,
            .tests = .empty,
            .handler_tests_end = 0,
            .path_count = 0,
            .route_costs_start = null,
            .walking_route_root = false,
            .walking_root_function = null_node,
            .summarized = false,
            .reaches_recursion = false,
            .unresolved_route_dispatch = false,
            .route_dispatch_count = 0,
            .route_composition_unmodeled = false,
            .unseen_failable_calls = .empty,
        };
    }

    pub fn deinit(self: *PathGenerator) void {
        if (self.owned_facts) |*owned| owned.deinit();
        self.module_fn_bindings.deinit(self.allocator);
        self.var_inits.deinit(self.allocator);
        self.constraints.deinit(self.allocator);
        self.io_seq.deinit(self.allocator);
        for (self.loop_stack.items) |*frame| {
            self.freeLoopBound(frame.bound);
        }
        self.loop_stack.deinit(self.allocator);
        for (self.retired_loop_descs.items) |desc| {
            self.allocator.free(desc);
        }
        self.retired_loop_descs.deinit(self.allocator);
        for (self.path_costs.items) |*cost| {
            cost.deinit(self.allocator);
        }
        self.path_costs.deinit(self.allocator);
        for (self.tests.items) |*t| {
            self.allocator.free(t.name);
            for (t.io_stubs.items) |*stub| {
                if (stub.arg_signature) |sig| self.allocator.free(sig);
            }
            t.io_stubs.deinit(self.allocator);
            if (t.constraints.len > 0) self.allocator.free(t.constraints);
        }
        self.tests.deinit(self.allocator);
        self.unseen_failable_calls.deinit(self.allocator);
    }

    /// Generate test cases for the given handler function.
    pub fn generate(self: *PathGenerator, handler_func: NodeIndex) !void {
        try self.scanImports();
        const facts = try self.resolveFacts();
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var route_roots = try resolver.routeRoots(self.allocator);
        defer route_roots.deinit(self.allocator);
        self.unresolved_route_dispatch = route_roots.unresolved;
        try self.scanRouteDispatches(&resolver);

        try self.generateRoot(handler_func, false);
        self.handler_tests_end = self.tests.items.len;
        if (self.route_dispatch_count > 1 or
            (self.route_dispatch_count > 0 and self.summarized))
        {
            self.route_composition_unmodeled = true;
        }
        if (route_roots.functions.items.len > 0 and self.route_dispatch_count > 0) {
            self.route_costs_start = self.path_costs.items.len;
        }
        for (route_roots.functions.items) |route_function| {
            if (route_function == handler_func) continue;
            try self.generateRoot(route_function, true);
        }
        try self.scanUnseenFailableCalls();
    }

    /// Find every call to a failable export that no emitted path holds as an
    /// I/O stub. The walk records a call only when it is the initializer of a
    /// `const`, or a bare statement, on a path that reaches a `return`. A call
    /// in a nested function, a helper, an expression, an argument, a `match`
    /// scrutinee, or a branch that does not return is never recorded, so
    /// fault coverage would neither count nor cover it. This scan reads the
    /// whole IR, so it does not depend on what the walk saw, and it names each
    /// call the walk missed. A call that is the left operand of `??` on an
    /// optional-returning export is answered by its fallback and is not listed.
    fn scanUnseenFailableCalls(self: *PathGenerator) error{ OutOfMemory, InvalidIR }!void {
        self.unseen_failable_calls.clearRetainingCapacity();

        var seen: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        defer seen.deinit(self.allocator);
        for (self.tests.items) |test_case| {
            for (test_case.io_stubs.items) |stub| {
                if (stub.call_site == null_node) continue;
                try seen.put(self.allocator, stub.call_site, {});
            }
        }

        try scanFileFailableCalls(
            self.allocator,
            self.ir_view,
            &self.module_fn_bindings,
            &seen,
            &self.unseen_failable_calls,
        );
        try self.scanImportRecords();
    }

    /// The scan core for one parsed file. It lists every call to a failable
    /// builtin export, and every value use of one, that is not in `walked`.
    /// `walked` holds the call nodes a path recorded as I/O stubs. The
    /// handler file passes it. An imported file has no walk, so it passes
    /// null and every failable call counts. A call that is the left operand of
    /// `??` on an optional-returning export is answered by its fallback and is
    /// not listed.
    fn scanFileFailableCalls(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        bindings: *const std.AutoHashMapUnmanaged(u16, FnMeta),
        walked: ?*const std.AutoHashMapUnmanaged(NodeIndex, void),
        out: *std.ArrayList(UnseenCall),
    ) error{ OutOfMemory, InvalidIR }!void {
        var absent_answered: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        defer absent_answered.deinit(allocator);
        for (0..ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (ir_view.getTag(idx) != .binary_op) continue;
            const bin = ir_view.getBinary(idx) orelse return error.InvalidIR;
            if (bin.op == .nullish) try absent_answered.put(allocator, bin.left, {});
        }

        var callees: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        defer callees.deinit(allocator);

        for (0..ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = ir_view.getTag(idx) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const call = ir_view.getCall(idx) orelse return error.InvalidIR;
            try callees.put(allocator, call.callee, {});
            const meta = calleeMeta(ir_view, bindings, call.callee) orelse continue;
            if (meta.severity == .none) continue;
            if (walked) |w| if (w.contains(idx)) continue;
            if (isOptionalReturn(meta.returns) and absent_answered.contains(idx)) continue;
            try out.append(allocator, .{
                .node = idx,
                .module = meta.module,
                .func = meta.func,
            });
        }

        // A failable import used as a value, not called: `const f = jwtVerify`,
        // or `parallel([jwtVerify])`. The call it makes later has a callee the
        // walk cannot resolve to the module, so no path records it. Imports are
        // globals, so a local or a parameter never matches.
        for (0..ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (ir_view.getTag(idx) != .identifier) continue;
            if (callees.contains(idx)) continue;
            const binding = ir_view.getBinding(idx) orelse continue;
            if (binding.kind != .global) continue;
            const meta = bindings.get(binding.slot) orelse continue;
            if (meta.severity == .none) continue;
            try out.append(allocator, .{
                .node = idx,
                .module = meta.module,
                .func = meta.func,
            });
        }
    }

    /// Every failable call, and every failable value use, in a file other than
    /// the handler's. `imports` is that file's own import index. The nodes
    /// belong to `ir_view`, so the caller reads each location before it
    /// releases the parse. There is no walk for such a file, so every
    /// failable call counts.
    pub fn scanImportedFile(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        imports: []const module_facts_mod.ImportRecord,
        out: *std.ArrayList(UnseenCall),
    ) error{ OutOfMemory, InvalidIR }!void {
        var bindings: std.AutoHashMapUnmanaged(u16, FnMeta) = .empty;
        defer bindings.deinit(allocator);
        try fillFnBindings(allocator, imports, &bindings);
        try scanFileFailableCalls(allocator, ir_view, &bindings, null, out);
    }

    /// Count the handler's own imports of files it does not own. A record that
    /// resolves to a builtin module is read by `scanFileFailableCalls`. Every
    /// other record needs a clean answer from the caller (`imported_scan`).
    /// A record with no entry, a blocked entry, an entry with a failable call,
    /// and every partner record each add one unseen call, located at the
    /// import. A partner export has no failure model, so no entry can clear it.
    fn scanImportRecords(self: *PathGenerator) error{OutOfMemory}!void {
        const facts = try self.resolveFacts();

        var decl_of: std.AutoHashMapUnmanaged(u16, NodeIndex) = .empty;
        defer decl_of.deinit(self.allocator);
        var decl_scanned = false;

        for (facts.imports.items) |rec| {
            if (rec.resolution == .builtin) continue;

            var call: UnseenCall = .{
                .node = null_node,
                .module = "",
                .func = "",
                .imported = .{ .file = rec.module_specifier, .blocked = .not_scanned },
            };
            if (rec.resolution == .partner) {
                call.imported = .{ .file = rec.module_specifier, .blocked = .partner };
            } else if (self.importScanFor(rec.slot)) |entry| {
                switch (entry.scan) {
                    .clean => continue,
                    .failable => |f| {
                        call.module = f.module;
                        call.func = f.func;
                        call.imported = .{ .file = f.file, .blocked = null };
                    },
                    .blocked => |b| call.imported = .{ .file = b.file, .blocked = b.reason },
                }
            }

            if (!decl_scanned) {
                try self.indexImportDecls(&decl_of);
                decl_scanned = true;
            }
            if (decl_of.get(rec.slot)) |node| call.node = node;
            try self.unseen_failable_calls.append(self.allocator, call);
        }
    }

    fn importScanFor(self: *const PathGenerator, slot: u16) ?ImportScanEntry {
        const entries = self.imported_scan orelse return null;
        for (entries) |entry| {
            if (entry.slot == slot) return entry;
        }
        return null;
    }

    /// Map each imported local slot to the `import_decl` node that binds it.
    fn indexImportDecls(
        self: *const PathGenerator,
        out: *std.AutoHashMapUnmanaged(u16, NodeIndex),
    ) error{OutOfMemory}!void {
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .import_decl) continue;
            const decl = self.ir_view.getImportDecl(idx) orelse continue;
            var j: u8 = 0;
            while (j < decl.specifiers_count) : (j += 1) {
                const spec_idx = self.ir_view.getListIndex(decl.specifiers_start, j);
                const spec = self.ir_view.getImportSpec(spec_idx) orelse continue;
                try out.put(self.allocator, spec.local_binding.slot, idx);
            }
        }
    }

    /// The import index the generator reads. Callers that scan the imported
    /// files build their answer from these records, so the records and the
    /// answer agree on every slot.
    pub fn importFacts(self: *PathGenerator) error{OutOfMemory}!*const module_facts_mod.ModuleFacts {
        return self.resolveFacts();
    }

    /// Give the generator the answer for the handler's non-builtin import
    /// records. Call it before `generate`. Borrowed; `entries` must outlive the
    /// generator. Null says the caller has no answer.
    pub fn setImportedScan(self: *PathGenerator, entries: ?[]const ImportScanEntry) void {
        self.imported_scan = entries;
    }

    fn isOptionalReturn(returns: mb.ReturnKind) bool {
        return switch (returns) {
            .optional_string, .optional_object, .optional_number => true,
            .boolean,
            .number,
            .string,
            .object,
            .undefined,
            .unknown,
            .result,
            .dict,
            .bytes,
            => false,
        };
    }

    /// The failable calls the walk never recorded. See `scanUnseenFailableCalls`.
    pub fn unseenFailableCalls(self: *const PathGenerator) []const UnseenCall {
        return self.unseen_failable_calls.items;
    }

    /// Whether fault coverage may claim the handler is covered. The coverage
    /// report counts only the calls the walk recorded, so it proves nothing
    /// about a call the walk missed or about a path set that is a summary. This
    /// is false when a failable call is on no path, when the path set is not
    /// exhaustive (a summarized loop, recursion, truncation), and when a
    /// `routerMatch` dispatch is unresolved. Callers combine it with
    /// `FaultCoverageReport.isClean`, which still needs one failable site: a
    /// handler with no site at all proves nothing either.
    pub fn faultAnalysisComplete(self: *const PathGenerator) bool {
        return self.routeDispatchesResolved() and
            self.pathsExhaustive() and
            self.unseen_failable_calls.items.len == 0;
    }

    fn generateRoot(self: *PathGenerator, function: NodeIndex, route_root: bool) !void {
        self.req_binding_key = null;
        self.method_binding_key = null;
        self.url_binding_key = null;
        self.var_inits.clearRetainingCapacity();
        self.constraints.clearRetainingCapacity();
        self.io_seq.clearRetainingCapacity();
        self.walking_route_root = route_root;
        self.walking_root_function = function;

        try self.findHandlerBindings(function);
        try self.detectRecursionReach(function);
        const func = self.ir_view.getFunction(function) orelse return;
        try self.walkPaths(func.body);
    }

    fn scanRouteDispatches(
        self: *PathGenerator,
        resolver: *const route_resolution.Resolver,
    ) !void {
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const call = self.ir_view.getCall(idx) orelse return error.InvalidIR;
            var targets = try resolver.resolveDispatch(self.allocator, call.callee) orelse continue;
            defer targets.deinit(self.allocator);
            self.route_dispatch_count += 1;
            if (targets.unresolved) self.unresolved_route_dispatch = true;
            if (!self.isDirectReturnValue(idx)) self.route_composition_unmodeled = true;
        }
    }

    fn isDirectReturnValue(self: *const PathGenerator, call_node: NodeIndex) bool {
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .return_stmt) continue;
            const value = self.ir_view.getOptValue(idx) orelse continue;
            if (value == call_node) return true;
        }
        return false;
    }

    /// Record whether the handler reaches recursion, so the cost and coverage
    /// claims below can refuse to over-claim over a call graph this generator
    /// never walks into.
    fn detectRecursionReach(self: *PathGenerator, handler_func: NodeIndex) !void {
        // The analyzer collects functions by walking down from its argument, so
        // it needs the program root: handed `handler_func` it would never see
        // the sibling declarations the handler calls.
        const root = self.findProgramRoot() orelse {
            self.reaches_recursion = true;
            return;
        };

        var analyzer = effect_inference.Analyzer.init(self.allocator, self.ir_view, self.atoms);
        defer analyzer.deinit();
        // Fail closed: an analysis that could not run is not evidence that the
        // handler is recursion-free.
        analyzer.analyze(root) catch {
            self.reaches_recursion = true;
            return;
        };
        // `reachesRecursion` keys on the body: callers hold the
        // `.function_expr` while the analyzer records the `.function_decl`, and
        // the body is the node both agree on.
        const handler_fn = self.ir_view.getFunction(handler_func) orelse {
            self.reaches_recursion = true;
            return;
        };
        // Same reason as above: a walk that could not allocate found no cycle
        // because it never looked.
        const root_reaches_recursion = analyzer.reachesRecursion(handler_fn.body) catch true;
        self.reaches_recursion = self.reaches_recursion or root_reaches_recursion;
    }

    fn findProgramRoot(self: *const PathGenerator) ?NodeIndex {
        var idx: NodeIndex = 0;
        while (idx < self.ir_view.nodeCount()) : (idx += 1) {
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag == .program) return idx;
        }
        return null;
    }

    pub fn getTests(self: *const PathGenerator) []const GeneratedTest {
        return self.tests.items;
    }

    /// Handler-root paths that can be emitted as runnable requests.
    /// Route-root paths stay available through `getTests` for property checks.
    pub fn getHandlerTests(self: *const PathGenerator) []const GeneratedTest {
        return self.tests.items[0..self.handler_tests_end];
    }

    /// Whether the emitted paths are the complete set. False when enumeration
    /// hit `MAX_PATHS`, and false when any construct was summarized rather than
    /// enumerated (spec gap 11). Every consumer that reports path coverage MUST
    /// read this rather than recomputing the `MAX_PATHS` comparison, or half of
    /// them keep over-claiming.
    pub fn pathsExhaustive(self: *const PathGenerator) bool {
        return self.coverage() == .exhaustive;
    }

    /// Whether every `routerMatch` dispatch has a closed function target set
    /// and returns its route result directly. Fault coverage uses this narrower
    /// predicate so unknown or discarded route failures cannot prove clean.
    pub fn routeDispatchesResolved(self: *const PathGenerator) bool {
        return !self.unresolved_route_dispatch and !self.route_composition_unmodeled;
    }

    /// Why the enumerated paths are or are not the complete set. Reported
    /// verbatim, because a single "not exhaustive" bool made every cause read
    /// as whichever one the display happened to name.
    pub const Coverage = enum {
        exhaustive,
        /// Hit `MAX_PATHS`; the paths beyond it were never built.
        truncated,
        /// A loop body was walked once as a representative iteration.
        summarized_loop,
        /// The handler reaches recursion, which the walk does not follow.
        recursion,
        /// A dynamic or unstable `routerMatch` dispatch can reach a route body
        /// that the generator did not enumerate.
        unresolved_dispatch,
        /// More than one dispatch, or a dispatch under summarized handler
        /// control flow, cannot be composed from one route-root cost summary.
        unmodeled_dispatch_composition,

        pub fn note(self: Coverage) []const u8 {
            return switch (self) {
                .exhaustive => "exhaustive",
                .truncated => "limit reached",
                .summarized_loop => "summarized: a loop body is walked once, not enumerated",
                .recursion => "summarized: the handler reaches recursion, which is not followed",
                .unresolved_dispatch => "unresolved: routerMatch dispatch can reach an unknown route function",
                .unmodeled_dispatch_composition => "summarized: routerMatch dispatch composition is not modeled",
            };
        }
    };

    pub fn coverage(self: *const PathGenerator) Coverage {
        if (self.tests.items.len >= MAX_PATHS) return .truncated;
        if (self.unresolved_route_dispatch) return .unresolved_dispatch;
        if (self.route_composition_unmodeled) return .unmodeled_dispatch_composition;
        if (self.reaches_recursion) return .recursion;
        if (self.summarized) return .summarized_loop;
        return .exhaustive;
    }

    /// Fold every enumerated path's io_seq multiplicities into a per-module
    /// worst-path CostEnvelope. Caller owns the result.
    pub fn buildCostEnvelope(self: *const PathGenerator, allocator: std.mem.Allocator) !contract_types.CostEnvelope {
        // Truncation and unsupported route dispatch composition make the
        // emitted cost incomplete, so the total below is forced to unbounded.
        // Ordinary loop summarization loses path coverage but not the cost
        // bound: `loopMultiplier` still carries the collection length
        // symbolically.
        const truncated = self.tests.items.len >= MAX_PATHS;
        var handler_cost = contract_types.CostEnvelope{};
        defer handler_cost.deinit(allocator);
        var route_cost = contract_types.CostEnvelope{};
        defer route_cost.deinit(allocator);

        for (self.path_costs.items, 0..) |path_cost, path_index| {
            var path_entries: std.ArrayList(ModuleCost) = .empty;
            defer path_entries.deinit(allocator);

            var path_total = contract_types.Bound{ .constant = 0 };
            for (path_cost.entries.items) |entry| {
                const call_bound = boundFromMult(entry.mult);
                path_total = contract_types.Bound.addBorrowed(path_total, call_bound);

                if (findModuleCost(path_entries.items, entry.module)) |idx| {
                    path_entries.items[idx].bound =
                        contract_types.Bound.addBorrowed(path_entries.items[idx].bound, call_bound);
                } else {
                    try path_entries.append(allocator, .{
                        .module = entry.module,
                        .bound = call_bound,
                    });
                }
            }

            const group = if (self.route_costs_start) |start|
                (if (path_index >= start) &route_cost else &handler_cost)
            else
                &handler_cost;
            try updateWorstPathCost(allocator, group, path_entries.items, path_total);
        }

        var envelope = if (self.route_costs_start != null)
            try composeSequentialCosts(allocator, &handler_cost, &route_cost)
        else
            try handler_cost.dupeOwned(allocator);
        errdefer envelope.deinit(allocator);
        envelope.exhaustive = self.pathsExhaustive();

        if (truncated or self.unresolved_route_dispatch or self.route_composition_unmodeled) {
            const unbounded_desc = try allocator.dupe(
                u8,
                if (truncated)
                    "path enumeration truncated at 1024"
                else if (self.route_composition_unmodeled)
                    "routerMatch dispatch composition is not modeled"
                else
                    "unresolved routerMatch dispatch",
            );
            envelope.total.deinitOwned(allocator);
            envelope.total = .{ .unbounded = .{
                .line = 0,
                .column = 0,
                .desc = unbounded_desc,
            } };
        } else if (self.reaches_recursion) {
            // The recursion's depth is not proven to decrease, and the
            // generator never walks into the call, so every module call the
            // cycle performs is missing from the count above. A constant bound
            // over that is not a bound. Spec 5.6.
            const recursion_desc = try allocator.dupe(u8, "recursion with no proven decreasing argument");
            envelope.total.deinitOwned(allocator);
            envelope.total = .{ .unbounded = .{
                .line = 0,
                .column = 0,
                .desc = recursion_desc,
            } };
        }

        std.mem.sort(contract_types.CostEntry, envelope.entries.items, {}, costEntryLessThan);
        return envelope;
    }

    fn updateWorstPathCost(
        allocator: std.mem.Allocator,
        group: *contract_types.CostEnvelope,
        path_entries: []const ModuleCost,
        path_total: contract_types.Bound,
    ) !void {
        for (path_entries) |module_cost| {
            if (findCostEntry(group.entries.items, module_cost.module)) |idx| {
                const candidate = contract_types.Bound.maxBorrowed(group.entries.items[idx].bound, module_cost.bound);
                const owned = try candidate.dupeOwned(allocator);
                group.entries.items[idx].bound.deinitOwned(allocator);
                group.entries.items[idx].bound = owned;
            } else {
                const module = try allocator.dupe(u8, module_cost.module);
                errdefer allocator.free(module);
                var bound = try module_cost.bound.dupeOwned(allocator);
                errdefer bound.deinitOwned(allocator);
                try group.entries.append(allocator, .{ .module = module, .bound = bound });
            }
        }

        const total_candidate = contract_types.Bound.maxBorrowed(group.total, path_total);
        const owned_total = try total_candidate.dupeOwned(allocator);
        group.total.deinitOwned(allocator);
        group.total = owned_total;
    }

    fn composeSequentialCosts(
        allocator: std.mem.Allocator,
        handler_cost: *const contract_types.CostEnvelope,
        route_cost: *const contract_types.CostEnvelope,
    ) !contract_types.CostEnvelope {
        var result = contract_types.CostEnvelope{
            .total = try contract_types.Bound.addBorrowed(handler_cost.total, route_cost.total).dupeOwned(allocator),
        };
        errdefer result.deinit(allocator);

        for (handler_cost.entries.items) |handler_entry| {
            const route_bound = if (route_cost.find(handler_entry.module)) |bound|
                bound.*
            else
                contract_types.Bound{ .constant = 0 };
            const module = try allocator.dupe(u8, handler_entry.module);
            errdefer allocator.free(module);
            var bound = try contract_types.Bound.addBorrowed(handler_entry.bound, route_bound).dupeOwned(allocator);
            errdefer bound.deinitOwned(allocator);
            try result.entries.append(allocator, .{ .module = module, .bound = bound });
        }
        for (route_cost.entries.items) |route_entry| {
            if (handler_cost.find(route_entry.module) != null) continue;
            const module = try allocator.dupe(u8, route_entry.module);
            errdefer allocator.free(module);
            var bound = try route_entry.bound.dupeOwned(allocator);
            errdefer bound.deinitOwned(allocator);
            try result.entries.append(allocator, .{ .module = module, .bound = bound });
        }
        return result;
    }

    fn findModuleCost(items: []const ModuleCost, module: []const u8) ?usize {
        for (items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.module, module)) return idx;
        }
        return null;
    }

    fn findCostEntry(items: []const contract_types.CostEntry, module: []const u8) ?usize {
        for (items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.module, module)) return idx;
        }
        return null;
    }

    fn costEntryLessThan(_: void, a: contract_types.CostEntry, b: contract_types.CostEntry) bool {
        return std.mem.lessThan(u8, a.module, b.module);
    }

    fn boundFromMult(mult: Mult) contract_types.Bound {
        return switch (mult) {
            .once => .{ .constant = 1 },
            .constant_x => |count| .{ .constant = count },
            .per_source => |source| .{ .linear = .{
                .coefficient = source.coefficient,
                .base = 0,
                .source = source.source,
            } },
            .unbounded => |source| .{ .unbounded = source },
        };
    }

    /// Write all generated tests as JSONL to writer.
    pub fn writeJsonl(self: *const PathGenerator, writer: anytype) !void {
        for (self.getHandlerTests()) |test_case| {
            // Test header
            try writer.writeAll("{\"type\":\"test\",\"name\":");
            try handler_contract.writeJsonString(writer, test_case.name);
            try writer.writeAll("}\n");

            try writer.writeAll("{\"type\":\"request\",\"method\":\"");
            try writer.writeAll(test_case.method);
            try writer.writeAll("\",\"url\":");
            try handler_contract.writeJsonString(writer, test_case.url);
            if (test_case.has_auth_header) {
                try writer.writeAll(",\"headers\":{\"authorization\":\"Bearer test-token\"},\"body\":null}\n");
            } else {
                try writer.writeAll(",\"headers\":{},\"body\":null}\n");
            }

            // I/O stubs
            for (test_case.io_stubs.items) |stub| {
                try writer.print("{{\"type\":\"io\",\"seq\":{d},\"module\":\"{s}\",\"fn\":\"{s}\",\"result\":{s}}}\n", .{
                    stub.seq,
                    stub.module,
                    stub.func,
                    stub.result_json,
                });
            }

            // Expected response
            try writer.print("{{\"type\":\"expect\",\"status\":{d}}}\n", .{test_case.expected_status});
        }
    }

    /// Convert generated tests into BehaviorPath structs for the contract.
    /// Caller owns the returned list and its contents.
    pub fn toBehaviorPaths(self: *const PathGenerator, allocator: std.mem.Allocator) !std.ArrayList(handler_contract.BehaviorPath) {
        var paths: std.ArrayList(handler_contract.BehaviorPath) = .empty;
        errdefer {
            for (paths.items) |*p| p.deinit(allocator);
            paths.deinit(allocator);
        }

        for (self.getHandlerTests()) |test_case| {
            var conditions: std.ArrayList(handler_contract.PathCondition) = .empty;
            errdefer {
                for (conditions.items) |*c| @constCast(c).deinit(allocator);
                conditions.deinit(allocator);
            }

            var is_failure = false;
            for (test_case.constraints) |constraint| {
                if (constraint.isFailure()) is_failure = true;

                var cond = (try dupePathCondition(allocator, constraint)) orelse continue;
                errdefer cond.deinit(allocator);
                try conditions.append(allocator, cond);
            }

            var io_sequence: std.ArrayList(handler_contract.PathIoCall) = .empty;
            errdefer {
                for (io_sequence.items) |*io| @constCast(io).deinit(allocator);
                io_sequence.deinit(allocator);
            }

            for (test_case.io_stubs.items) |stub| {
                var io_call = try dupePathIoCall(allocator, stub);
                errdefer io_call.deinit(allocator);
                try io_sequence.append(allocator, io_call);
            }

            const route_method = try allocator.dupe(u8, test_case.method);
            errdefer allocator.free(route_method);
            const route_pattern = try allocator.dupe(u8, test_case.url);
            errdefer allocator.free(route_pattern);
            try paths.append(allocator, .{
                .route_method = route_method,
                .route_pattern = route_pattern,
                .conditions = conditions,
                .io_sequence = io_sequence,
                .response_status = test_case.expected_status,
                .io_depth = @intCast(test_case.io_stubs.items.len),
                .is_failure_path = is_failure,
            });
        }

        return paths;
    }

    // -------------------------------------------------------------------
    // Phase 1: Scan imports and handler bindings
    // -------------------------------------------------------------------

    /// Resolve the index to read: injected, or private on first use.
    fn resolveFacts(self: *PathGenerator) error{OutOfMemory}!*const module_facts_mod.ModuleFacts {
        if (self.facts) |f| return f;
        if (self.owned_facts == null) {
            self.owned_facts = module_facts_mod.ModuleFacts.build(
                self.allocator,
                self.ir_view,
                self.atoms,
                null,
            ) catch return error.OutOfMemory;
        }
        return &self.owned_facts.?;
    }

    /// Map local binding slots to builtin module function metadata.
    ///
    /// `.builtin` only, which is the exact translation of the legacy
    /// `fromSpecifier(module) orelse continue`: that lookup searches
    /// `builtin_modules.all` and never a manifest registry, so a
    /// partner-registered module was skipped before and stays skipped.
    fn scanImports(self: *PathGenerator) error{OutOfMemory}!void {
        const facts = try self.resolveFacts();
        try fillFnBindings(self.allocator, facts.imports.items, &self.module_fn_bindings);
    }

    fn fillFnBindings(
        allocator: std.mem.Allocator,
        imports: []const module_facts_mod.ImportRecord,
        bindings: *std.AutoHashMapUnmanaged(u16, FnMeta),
    ) error{OutOfMemory}!void {
        for (imports) |rec| {
            if (rec.resolution != .builtin) continue;
            const entry = builtin_modules.findExport(rec.module_specifier, rec.imported_name) orelse continue;
            try bindings.put(allocator, rec.slot, .{
                // The binding's short name, not its specifier: that is what the
                // legacy scan stored and what downstream comparisons expect.
                .module = entry.binding.name,
                .func = entry.func.name,
                .returns = entry.func.returns,
                .severity = entry.func.failure_severity,
                .ok_record = try isOkRecordExport(allocator, entry.func),
            });
        }
    }

    fn findHandlerBindings(self: *PathGenerator, handler_func: NodeIndex) error{OutOfMemory}!void {
        const func = self.ir_view.getFunction(handler_func) orelse return;
        if (func.params_count == 0) return;

        // First parameter is the request. The parser wraps a parameter in a
        // `.pattern_element`, so read its binding through `paramBinding`, which
        // accepts both shapes.
        const param_idx = self.ir_view.getListIndex(func.params_start, 0);
        if (self.ir_view.paramBinding(param_idx)) |binding| {
            self.req_binding_key = packBindingKey(binding.scope_id, binding.slot);
        }

        // Scan body for `const method = req.method` and `const url = req.url` patterns
        const body = self.ir_view.getBlock(func.body) orelse return;
        var i: u16 = 0;
        while (i < body.stmts_count) : (i += 1) {
            const stmt_idx = self.ir_view.getListIndex(body.stmts_start, i);
            const stmt_tag = self.ir_view.getTag(stmt_idx) orelse continue;
            if (stmt_tag != .var_decl) continue;

            const vd = self.ir_view.getVarDecl(stmt_idx) orelse continue;
            if (vd.init == null_node) continue;

            const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
            try self.var_inits.put(self.allocator, key, vd.init);

            // Check if init is req.method or req.url/req.path
            if (self.isReqMemberAccess(vd.init, "method")) {
                self.method_binding_key = key;
            } else if (self.isReqMemberAccess(vd.init, "url") or self.isReqMemberAccess(vd.init, "path")) {
                self.url_binding_key = key;
            }
        }
    }

    // -------------------------------------------------------------------
    // Phase 2: Path enumeration via recursive IR walk
    // -------------------------------------------------------------------

    fn walkPaths(self: *PathGenerator, node: NodeIndex) error{OutOfMemory}!void {
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .return_stmt => {
                // Leaf: complete path found. Emit test case.
                const status = self.extractReturnStatus(node);
                try self.emitTestCase(status);
            },

            .block, .program => {
                const block = self.ir_view.getBlock(node) orelse return;
                try self.walkBlock(block);
            },

            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;

                const saved_constraints = self.constraints.items.len;
                const saved_io = self.io_seq.items.len;

                // Push all extractable constraints for then-branch
                try self.extractAllConstraints(if_s.condition);
                try self.walkPaths(if_s.then_branch);
                self.constraints.shrinkRetainingCapacity(saved_constraints);
                self.io_seq.shrinkRetainingCapacity(saved_io);

                // Else-branch: walked once for each way the condition is false
                if (if_s.else_branch != null_node) {
                    var cases = try self.falseCases(if_s.condition);
                    defer cases.deinit(self.allocator);
                    for (0..cases.count()) |k| {
                        if (k > 0 and self.path_count >= MAX_PATHS) break;
                        try self.constraints.appendSlice(self.allocator, cases.slice(k));
                        try self.walkPaths(if_s.else_branch);
                        self.constraints.shrinkRetainingCapacity(saved_constraints);
                        self.io_seq.shrinkRetainingCapacity(saved_io);
                    }
                }
                // If no else and then-branch doesn't always return, fall-through
                // is handled by the caller walking the next statement in the block.
            },

            .match_expr => {
                const match_data = self.ir_view.getMatchExpr(node) orelse return;
                var i: u8 = 0;
                while (i < match_data.arms_count) : (i += 1) {
                    const arm_idx = self.ir_view.getListIndex(match_data.arms_start, i);
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    const saved = self.constraints.items.len;
                    const saved_io = self.io_seq.items.len;
                    try self.walkPaths(arm.body);
                    self.constraints.shrinkRetainingCapacity(saved);
                    self.io_seq.shrinkRetainingCapacity(saved_io);
                }
            },

            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                if (vd.init != null_node) {
                    const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
                    try self.var_inits.put(self.allocator, key, vd.init);
                    try self.trackModuleCall(vd.init, key);
                }
            },

            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    try self.trackModuleCall(expr, null);
                }
            },

            .for_of_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                // The body is walked once below, as a representative iteration.
                // Paths through zero iterations, or through differing branch
                // choices across iterations, are never emitted, so from here on
                // this handler's enumeration is a summary.
                self.summarized = true;
                const bound = self.resolveLoopBound(fi.iterable, node);
                self.retired_loop_descs.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                    self.freeLoopBound(bound);
                    return err;
                };
                self.loop_stack.append(self.allocator, .{ .bound = bound }) catch |err| {
                    self.freeLoopBound(bound);
                    return err;
                };
                defer {
                    const frame = self.loop_stack.pop().?;
                    self.retireLoopBound(frame.bound);
                }
                // Walk body path (non-empty collection case)
                try self.walkPaths(fi.body);
            },

            .switch_stmt => {
                const sw = self.ir_view.getSwitchStmt(node) orelse return;
                for (0..sw.cases_count) |i| {
                    const case_idx = self.ir_view.getListIndex(sw.cases_start, @intCast(i));
                    const cc = self.ir_view.getCaseClause(case_idx) orelse continue;
                    const saved = self.constraints.items.len;
                    const saved_io = self.io_seq.items.len;
                    const case_block = Node.BlockData{ .stmts_start = cc.body_start, .stmts_count = cc.body_count, .scope_id = 0 };
                    try self.walkBlock(case_block);
                    self.constraints.shrinkRetainingCapacity(saved);
                    self.io_seq.shrinkRetainingCapacity(saved_io);
                }
            },

            .function_decl, .function_expr, .arrow_function => {
                // Don't recurse into nested function definitions
            },

            .export_default => {
                if (self.ir_view.getOptValue(node)) |val| {
                    try self.walkPaths(val);
                }
            },

            else => {},
        }
    }

    fn walkBlock(self: *PathGenerator, block: Node.BlockData) !void {
        try self.walkBlockFrom(block, 0);
    }

    fn walkBlockFrom(self: *PathGenerator, block: Node.BlockData, first: u16) !void {
        var i: u16 = first;
        while (i < block.stmts_count) : (i += 1) {
            const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
            const stmt_tag = self.ir_view.getTag(stmt_idx) orelse continue;

            if (stmt_tag == .if_stmt) {
                const if_s = self.ir_view.getIfStmt(stmt_idx) orelse continue;
                const then_always = self.stmtAlwaysReturns(if_s.then_branch);

                if (then_always and if_s.else_branch != null_node) {
                    // Both branches return: fork and stop
                    try self.walkPaths(stmt_idx);
                    return;
                } else if (then_always and if_s.else_branch == null_node) {
                    // Then-branch returns, no else: fork then-path, continue for fall-through
                    const saved = self.constraints.items.len;
                    const saved_io = self.io_seq.items.len;
                    try self.extractAllConstraints(if_s.condition);
                    try self.walkPaths(if_s.then_branch);
                    self.constraints.shrinkRetainingCapacity(saved);
                    self.io_seq.shrinkRetainingCapacity(saved_io);

                    // Fall-through: one way the condition is false continues in
                    // this loop, several walk the rest of the block each.
                    var cases = try self.falseCases(if_s.condition);
                    defer cases.deinit(self.allocator);
                    if (cases.count() == 1) {
                        try self.constraints.appendSlice(self.allocator, cases.slice(0));
                        continue;
                    }
                    for (0..cases.count()) |k| {
                        if (k > 0 and self.path_count >= MAX_PATHS) break;
                        try self.constraints.appendSlice(self.allocator, cases.slice(k));
                        try self.walkBlockFrom(block, i + 1);
                        self.constraints.shrinkRetainingCapacity(saved);
                        self.io_seq.shrinkRetainingCapacity(saved_io);
                    }
                    return;
                } else {
                    // Neither always returns: just recurse normally
                    try self.walkPaths(stmt_idx);
                    continue;
                }
            }

            try self.walkPaths(stmt_idx);

            // If this statement always returns, remaining statements are unreachable
            if (stmt_tag == .return_stmt) return;
        }
    }

    // -------------------------------------------------------------------
    // Phase 3: Constraint extraction from conditions
    // -------------------------------------------------------------------

    /// Push all extractable constraints from a condition into the constraint
    /// list: the constraints that hold on the path where the condition is true.
    fn extractAllConstraints(self: *PathGenerator, cond: NodeIndex) error{OutOfMemory}!void {
        const tag = self.ir_view.getTag(cond) orelse return;

        // AND chains: extract from both sides
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(cond) orelse return;
            if (bin.op == .and_op) {
                try self.extractAllConstraints(bin.left);
                try self.extractAllConstraints(bin.right);
                return;
            }
        }

        // Extract single constraint from this node
        if (self.extractConditionConstraint(cond)) |c| try self.constraints.append(self.allocator, c);
    }

    /// The ways a condition can be false, each as the constraints that hold on
    /// the path reaching it. `a && b` is false when `a` is false, or when `a`
    /// is true and `b` is false, so the negation of every conjunct on one path
    /// is not the complement of the then-path.
    const FalseCases = struct {
        constraints: std.ArrayList(Constraint) = .empty,
        spans: std.ArrayList(Span) = .empty,

        const Span = struct { start: usize, len: usize };

        fn deinit(self: *FalseCases, allocator: std.mem.Allocator) void {
            self.constraints.deinit(allocator);
            self.spans.deinit(allocator);
        }

        fn count(self: *const FalseCases) usize {
            return self.spans.items.len;
        }

        fn slice(self: *const FalseCases, k: usize) []const Constraint {
            const span = self.spans.items[k];
            return self.constraints.items[span.start..][0..span.len];
        }

        /// Append `parts` joined as one case, unless an equal case exists.
        fn add(
            self: *FalseCases,
            allocator: std.mem.Allocator,
            parts: []const []const Constraint,
        ) error{OutOfMemory}!void {
            const start = self.constraints.items.len;
            for (parts) |part| try self.constraints.appendSlice(allocator, part);
            const added = self.constraints.items[start..];
            for (0..self.count()) |k| {
                const existing = self.slice(k);
                if (existing.len != added.len) continue;
                for (existing, added) |a, b| {
                    if (!constraintEql(a, b)) break;
                } else {
                    self.constraints.shrinkRetainingCapacity(start);
                    return;
                }
            }
            try self.spans.append(allocator, .{ .start = start, .len = added.len });
        }
    };

    /// Cases for the conjuncts `c1 && ... && cn`. For each `ci` false with
    /// `c1..c(i-1)` true, one case holds the negation of `ci`. A conjunct with
    /// no constraint, or none expressible when false, still gets its case,
    /// holding only the earlier conjuncts. Short-circuit evaluation never reads
    /// the conjuncts after `ci`, so a failable call that one of them tests can
    /// still have failed: each such conjunct adds a case with its failure.
    /// The result always holds at least one case.
    fn falseCases(self: *PathGenerator, cond: NodeIndex) error{OutOfMemory}!FalseCases {
        var conjuncts: std.ArrayList(NodeIndex) = .empty;
        defer conjuncts.deinit(self.allocator);
        try self.collectConjuncts(cond, &conjuncts);

        var cases: FalseCases = .{};
        errdefer cases.deinit(self.allocator);
        // The constraints of the conjuncts before `ci`, each true.
        var held: std.ArrayList(Constraint) = .empty;
        defer held.deinit(self.allocator);

        for (conjuncts.items, 0..) |conjunct, i| {
            const positive = self.extractConditionConstraint(conjunct);
            const negated: ?Constraint = if (positive) |c| self.negateConstraint(c) else null;
            const last: []const Constraint = if (negated) |*n| n[0..1] else &.{};
            try cases.add(self.allocator, &.{ held.items, last });
            for (conjuncts.items[i + 1 ..]) |later| {
                const failure = self.failurePolarity(self.extractConditionConstraint(later)) orelse continue;
                try cases.add(self.allocator, &.{ held.items, last, (&failure)[0..1] });
            }
            if (positive) |c| try held.append(self.allocator, c);
        }
        return cases;
    }

    /// The failing side of a conjunct's constraint, when it has one.
    fn failurePolarity(self: *const PathGenerator, positive: ?Constraint) ?Constraint {
        const c = positive orelse return null;
        if (c.isFailure()) return c;
        const negated = self.negateConstraint(c) orelse return null;
        return if (negated.isFailure()) negated else null;
    }

    /// Flatten an `&&` chain into its conjuncts, left to right.
    fn collectConjuncts(
        self: *const PathGenerator,
        cond: NodeIndex,
        out: *std.ArrayList(NodeIndex),
    ) error{OutOfMemory}!void {
        if (self.ir_view.getTag(cond)) |tag| {
            if (tag == .binary_op) {
                if (self.ir_view.getBinary(cond)) |bin| {
                    if (bin.op == .and_op) {
                        try self.collectConjuncts(bin.left, out);
                        try self.collectConjuncts(bin.right, out);
                        return;
                    }
                }
            }
        }
        try out.append(self.allocator, cond);
    }

    fn extractConditionConstraint(self: *PathGenerator, cond: NodeIndex) ?Constraint {
        const tag = self.ir_view.getTag(cond) orelse return null;

        switch (tag) {
            .binary_op => {
                const bin = self.ir_view.getBinary(cond) orelse return null;

                if (self.extractStatusComparison(bin)) |c| return c;

                if (bin.op == .strict_eq or bin.op == .strict_neq) {
                    // Check pattern: identifier === "literal"
                    if (self.extractLiteralComparison(bin.left, bin.right)) |c| {
                        return if (bin.op == .strict_eq) c else self.negateConstraint(c);
                    }
                    // Reverse: "literal" === identifier
                    if (self.extractLiteralComparison(bin.right, bin.left)) |c| {
                        return if (bin.op == .strict_eq) c else self.negateConstraint(c);
                    }
                    if (self.extractOptionalAbsentComparison(bin.left, bin.right)) |c| {
                        return if (bin.op == .strict_eq) c else self.negateConstraint(c);
                    }
                    if (self.extractOptionalAbsentComparison(bin.right, bin.left)) |c| {
                        return if (bin.op == .strict_eq) c else self.negateConstraint(c);
                    }
                }

                // && chains handled by extractAllConstraints
                if (bin.op == .and_op) return null;
            },

            .unary_op => {
                // !expr -> negate
                const unary = self.ir_view.getUnary(cond) orelse return null;
                if (unary.op == .not) {
                    if (self.extractConditionConstraint(unary.operand)) |c| {
                        return self.negateConstraint(c);
                    }
                }
            },

            .identifier => {
                // Only a boolean-returning module value is a legal direct
                // condition in the boolean-only profile.
                return self.extractBooleanConstraint(cond);
            },

            .member_access => {
                // if (result.ok) pattern
                return self.extractResultOkConstraint(cond);
            },

            .call => {
                return self.extractBooleanCallConstraint(cond);
            },

            else => {},
        }

        return null;
    }

    fn extractLiteralComparison(self: *PathGenerator, id_node: NodeIndex, lit_node: NodeIndex) ?Constraint {
        const lit_tag = self.ir_view.getTag(lit_node) orelse return null;
        if (lit_tag != .lit_string) return null;

        const str_idx = self.ir_view.getStringIdx(lit_node) orelse return null;
        const value = self.ir_view.getString(str_idx) orelse return null;

        // A direct `req.method === "POST"` or `req.url === "/x"`.
        if (self.isReqMemberAccess(id_node, "method")) return .{ .req_method = value };
        if (self.isReqMemberAccess(id_node, "url") or self.isReqMemberAccess(id_node, "path")) return .{ .req_url = value };

        const id_tag = self.ir_view.getTag(id_node) orelse return null;
        if (id_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(id_node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);

        // Direct req.method / req.url comparisons
        if (self.req_binding_key) |req_key| {
            if (key == req_key) return null; // comparing request itself, not a property
        }

        if (self.method_binding_key) |mk| {
            if (key == mk) return .{ .req_method = value };
        }

        if (self.url_binding_key) |uk| {
            if (key == uk) return .{ .req_url = value };
        }

        // Check if this binding was initialized from req.method or req.url
        if (self.var_inits.get(key)) |init_node| {
            if (self.isReqMemberAccess(init_node, "method")) return .{ .req_method = value };
            if (self.isReqMemberAccess(init_node, "url") or self.isReqMemberAccess(init_node, "path")) return .{ .req_url = value };
        }

        return null;
    }

    fn extractBooleanConstraint(self: *PathGenerator, id_node: NodeIndex) ?Constraint {
        const binding = self.ir_view.getBinding(id_node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);

        // Check if this binding was initialized from a module call
        const init_node = self.var_inits.get(key) orelse return null;
        const init_tag = self.ir_view.getTag(init_node) orelse return null;

        if (init_tag == .call) {
            const call = self.ir_view.getCall(init_node) orelse return null;
            if (self.getCalleeMeta(call.callee)) |meta| {
                if (meta.returns != .boolean) return null;
                return .{ .stub_truthy = .{ .module = meta.module, .func = meta.func, .returns = meta.returns, .call_site = init_node } };
            }
        }

        return null;
    }

    fn extractBooleanCallConstraint(self: *PathGenerator, call_node: NodeIndex) ?Constraint {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (self.getCalleeMeta(call.callee)) |meta| {
            if (meta.returns != .boolean) return null;
            return .{ .stub_truthy = .{ .module = meta.module, .func = meta.func, .returns = meta.returns, .call_site = call_node } };
        }
        return null;
    }

    fn extractOptionalAbsentComparison(
        self: *PathGenerator,
        value_node: NodeIndex,
        undefined_node: NodeIndex,
    ) ?Constraint {
        if (self.ir_view.getTag(value_node) != .identifier or
            self.ir_view.getTag(undefined_node) != .lit_undefined)
        {
            return null;
        }
        const binding = self.ir_view.getBinding(value_node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const init_node = self.var_inits.get(key) orelse return null;
        if (self.ir_view.getTag(init_node) != .call) return null;
        const call = self.ir_view.getCall(init_node) orelse return null;
        const meta = self.getCalleeMeta(call.callee) orelse return null;
        switch (meta.returns) {
            .optional_string, .optional_object, .optional_number => {},
            .boolean,
            .number,
            .string,
            .object,
            .undefined,
            .unknown,
            .result,
            .dict,
            .bytes,
            => return null,
        }
        return .{ .stub_falsy = .{ .module = meta.module, .func = meta.func, .returns = meta.returns, .call_site = init_node } };
    }

    /// `x.status OP n` or `n OP x.status`, where `x` is bound to a call of an
    /// `ok`-record export and `n` is a numeric literal. When the comparison is
    /// the complement of `ok` it forks like `x.ok`: the side that holds on the
    /// failure status gets `result_not_ok`, the other `result_ok`. Any other
    /// comparison that splits the statuses gets a `status_is` constraint.
    /// The returned constraint holds where the comparison is true.
    fn extractStatusComparison(self: *PathGenerator, bin: Node.BinaryExpr) ?Constraint {
        var call_site: NodeIndex = undefined;
        var comparison: status_check.Comparison = undefined;
        if (self.statusMemberCall(bin.left)) |site| {
            const shape = status_check.shape(self.ir_view, bin, true) orelse return null;
            call_site = site;
            comparison = shape.comparison;
        } else if (self.statusMemberCall(bin.right)) |site| {
            const shape = status_check.shape(self.ir_view, bin, false) orelse return null;
            call_site = site;
            comparison = shape.comparison;
        } else return null;

        const call = self.ir_view.getCall(call_site) orelse return null;
        const meta = self.getCalleeMeta(call.callee) orelse return null;
        const info: StubInfo = .{
            .module = meta.module,
            .func = meta.func,
            .returns = meta.returns,
            .call_site = call_site,
        };
        return switch (status_check.classify(comparison)) {
            .constant => null,
            .plain => .{ .status_is = .{ .stub = info, .comparison = comparison, .expect = true } },
            .fork => |failure_side| if (failure_side) .{ .result_not_ok = info } else .{ .result_ok = info },
        };
    }

    /// The call site when `node` is `x.status` and `x` is an identifier bound
    /// to a call of an `ok`-record export.
    fn statusMemberCall(self: *PathGenerator, node: NodeIndex) ?NodeIndex {
        if (self.ir_view.getTag(node) != .member_access) return null;
        const member = self.ir_view.getMember(node) orelse return null;
        const prop_name = self.resolveAtomName(member.property) orelse return null;
        if (!std.mem.eql(u8, prop_name, "status")) return null;
        if (self.ir_view.getTag(member.object) != .identifier) return null;
        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const init_node = self.var_inits.get(packBindingKey(binding.scope_id, binding.slot)) orelse return null;
        if (self.ir_view.getTag(init_node) != .call) return null;
        const call = self.ir_view.getCall(init_node) orelse return null;
        const meta = self.getCalleeMeta(call.callee) orelse return null;
        if (!meta.ok_record) return null;
        return init_node;
    }

    fn extractResultOkConstraint(self: *PathGenerator, member_node: NodeIndex) ?Constraint {
        const member = self.ir_view.getMember(member_node) orelse return null;
        const prop_name = self.resolveAtomName(member.property) orelse return null;
        if (!std.mem.eql(u8, prop_name, "ok")) return null;

        // Object should be an identifier bound to a result-producing call
        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const init_node = self.var_inits.get(key) orelse return null;
        const init_tag = self.ir_view.getTag(init_node) orelse return null;

        if (init_tag == .call) {
            const call = self.ir_view.getCall(init_node) orelse return null;
            if (self.getCalleeMeta(call.callee)) |meta| {
                if (meta.returns == .result or meta.ok_record) {
                    return .{ .result_ok = .{ .module = meta.module, .func = meta.func, .returns = meta.returns, .call_site = init_node } };
                }
            }
        }

        return null;
    }

    fn negateConstraint(_: *const PathGenerator, c: Constraint) ?Constraint {
        return switch (c) {
            .req_method => |m| .{ .req_method_not = m },
            .req_method_not => |m| .{ .req_method = m },
            .req_url => |u| .{ .req_url_not = u },
            .req_url_not => |u| .{ .req_url = u },
            .stub_truthy => |info| .{ .stub_falsy = info },
            .stub_falsy => |info| .{ .stub_truthy = info },
            .result_ok => |info| .{ .result_not_ok = info },
            .result_not_ok => |info| .{ .result_ok = info },
            .status_is => |s| .{ .status_is = .{ .stub = s.stub, .comparison = s.comparison, .expect = !s.expect } },
        };
    }

    // -------------------------------------------------------------------
    // I/O call tracking
    // -------------------------------------------------------------------

    fn trackModuleCall(self: *PathGenerator, node: NodeIndex, binding_key: ?u32) error{OutOfMemory}!void {
        return self.trackModuleCallUnder(node, binding_key, false);
    }

    /// `under_nullish` is true when `node` is the left operand of `??`. The
    /// fallback then answers an absent value from an optional-returning export.
    fn trackModuleCallUnder(
        self: *PathGenerator,
        node: NodeIndex,
        binding_key: ?u32,
        under_nullish: bool,
    ) error{OutOfMemory}!void {
        const tag = self.ir_view.getTag(node) orelse return;

        if (tag == .call) {
            const call = self.ir_view.getCall(node) orelse return;
            if (self.getCalleeMeta(call.callee)) |meta| {
                try self.io_seq.append(self.allocator, .{
                    .module = meta.module,
                    .func = meta.func,
                    .returns = meta.returns,
                    .ok_record = meta.ok_record,
                    .binding_key = binding_key,
                    .mult = self.currentMultiplicity(),
                    .call_node = node,
                    .absent_handled = under_nullish and isOptionalReturn(meta.returns),
                });
            }
            return;
        }

        // Look through nullish coalescing: env("X") ?? "default"
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(node) orelse return;
            if (bin.op == .nullish) {
                try self.trackModuleCallUnder(bin.left, binding_key, true);
                return;
            }
        }
    }

    fn currentMultiplicity(self: *const PathGenerator) Mult {
        if (self.loop_stack.items.len == 0) return .once;

        var constant_product: u32 = 1;
        var symbolic_count: u32 = 0;
        var symbolic_source: contract_types.BoundProvenance = .{};
        var innermost_dynamic: contract_types.BoundProvenance = .{};
        var saw_unknown = false;

        for (self.loop_stack.items) |frame| {
            switch (frame.bound) {
                .constant => |count| {
                    constant_product = saturatingMulU32(constant_product, count);
                },
                .symbolic => |source| {
                    symbolic_count += 1;
                    symbolic_source = source;
                    innermost_dynamic = source;
                },
                .unknown => |source| {
                    saw_unknown = true;
                    innermost_dynamic = source;
                },
            }
        }

        if (saw_unknown or symbolic_count > 1) {
            return .{ .unbounded = innermost_dynamic };
        }
        if (symbolic_count == 1) {
            return .{ .per_source = .{
                .coefficient = constant_product,
                .source = symbolic_source,
            } };
        }
        return .{ .constant_x = constant_product };
    }

    fn saturatingMulU32(a: u32, b: u32) u32 {
        const product, const overflow = @mulWithOverflow(a, b);
        return if (overflow != 0) std.math.maxInt(u32) else product;
    }

    /// Build a canonical argument signature for the call at `call_node`.
    /// Pipe-delimited, one token per argument position:
    ///   "lit:<raw>"   - string literal
    ///   "int:<raw>"   - integer literal
    ///   "bool:true"   - boolean literal
    ///   "bool:false"
    ///   "?"           - dynamic or unknown
    /// Returns an owned slice. Caller frees.
    fn computeArgSignature(self: *const PathGenerator, allocator: std.mem.Allocator, call_node: NodeIndex) !?[]const u8 {
        const tag = self.ir_view.getTag(call_node) orelse return null;
        if (tag != .call and tag != .method_call) return null;
        const call = self.ir_view.getCall(call_node) orelse return null;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        var j: u8 = 0;
        while (j < call.args_count) : (j += 1) {
            if (j > 0) try buf.append(allocator, '|');
            const arg_idx = self.ir_view.getListIndex(call.args_start, j);
            const arg_tag = self.ir_view.getTag(arg_idx) orelse {
                try buf.append(allocator, '?');
                continue;
            };
            switch (arg_tag) {
                .lit_string => {
                    const str_idx = self.ir_view.getStringIdx(arg_idx) orelse {
                        try buf.append(allocator, '?');
                        continue;
                    };
                    const raw = self.ir_view.getString(str_idx) orelse {
                        try buf.append(allocator, '?');
                        continue;
                    };
                    try buf.appendSlice(allocator, "lit:");
                    try buf.appendSlice(allocator, raw);
                },
                .lit_int => {
                    const v = self.ir_view.getIntValue(arg_idx) orelse {
                        try buf.append(allocator, '?');
                        continue;
                    };
                    try buf.print(allocator, "int:{d}", .{v});
                },
                .lit_bool => {
                    const b = self.ir_view.getBoolValue(arg_idx) orelse {
                        try buf.append(allocator, '?');
                        continue;
                    };
                    try buf.appendSlice(allocator, if (b) "bool:true" else "bool:false");
                },
                else => try buf.append(allocator, '?'),
            }
        }

        return try buf.toOwnedSlice(allocator);
    }

    // -------------------------------------------------------------------
    // Response status extraction
    // -------------------------------------------------------------------

    fn extractReturnStatus(self: *PathGenerator, node: NodeIndex) u16 {
        const ret_val = self.ir_view.getOptValue(node) orelse return 200;
        const ret_tag = self.ir_view.getTag(ret_val) orelse return 200;

        if (ret_tag == .call or ret_tag == .method_call) {
            const call = self.ir_view.getCall(ret_val) orelse return 200;

            if (!self.isResponseHelper(call.callee)) return 200;

            if (call.args_count >= 2) {
                const opts = self.ir_view.getListIndex(call.args_start, 1);
                if (self.extractStatusFromOptions(opts)) |status| return status;
            }
        }

        return 200;
    }

    fn extractStatusFromOptions(self: *const PathGenerator, opts_node: NodeIndex) ?u16 {
        const tag = self.ir_view.getTag(opts_node) orelse return null;
        if (tag != .object_literal) return null;

        const obj = self.ir_view.getObject(opts_node) orelse return null;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
            if (prop_tag != .object_property) continue;

            const prop = self.ir_view.getProperty(prop_idx) orelse continue;

            const key_name = self.getPropertyKeyName(prop.key) orelse continue;
            if (!std.mem.eql(u8, key_name, "status")) continue;

            const val_tag = self.ir_view.getTag(prop.value) orelse continue;
            if (val_tag == .lit_int) {
                const val = self.ir_view.getIntValue(prop.value) orelse continue;
                if (val >= 100 and val <= 599) return @intCast(val);
            }
        }
        return null;
    }

    // -------------------------------------------------------------------
    // Test case emission
    // -------------------------------------------------------------------

    const SolvedRequest = struct {
        method: []const u8,
        url: []const u8,
    };

    /// The method and URL that satisfy the request constraints of this path. A
    /// positive constraint names the value (the last one wins). With none, the
    /// first candidate that differs from every negative constraint is used, so
    /// the path after `if (req.method !== "POST") return 405` sends `POST` and
    /// the 405 path sends a method other than `POST`.
    fn solveRequest(self: *const PathGenerator) SolvedRequest {
        var method: ?[]const u8 = null;
        var url: ?[]const u8 = null;
        for (self.constraints.items) |c| {
            switch (c) {
                .req_method => |m| method = m,
                .req_url => |u| url = u,
                .req_method_not,
                .req_url_not,
                .stub_truthy,
                .stub_falsy,
                .result_ok,
                .result_not_ok,
                .status_is,
                => {},
            }
        }
        return .{
            .method = method orelse self.firstUnexcluded(&request_method_candidates, .method),
            .url = url orelse self.firstUnexcluded(&request_url_candidates, .url),
        };
    }

    const RequestPart = enum { method, url };

    /// The first candidate that no negative constraint of that part excludes.
    /// The candidate lists are longer than any path's negative constraints in
    /// practice; the last candidate is the fallback.
    fn firstUnexcluded(
        self: *const PathGenerator,
        candidates: []const []const u8,
        part: RequestPart,
    ) []const u8 {
        for (candidates) |candidate| {
            var excluded = false;
            for (self.constraints.items) |c| {
                const not = switch (c) {
                    .req_method_not => |m| if (part == .method) m else continue,
                    .req_url_not => |u| if (part == .url) u else continue,
                    else => continue,
                };
                if (std.mem.eql(u8, not, candidate)) excluded = true;
            }
            if (!excluded) return candidate;
        }
        return candidates[candidates.len - 1];
    }

    fn emitTestCase(self: *PathGenerator, status: u16) !void {
        if (self.path_count >= MAX_PATHS) return;
        self.path_count += 1;
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        const prefix = std.fmt.bufPrint(name_buf[0..], "path {d}", .{self.path_count}) catch "path";
        name_len = prefix.len;

        var negated_buf: [64]u8 = undefined;
        for (self.constraints.items) |c| {
            const desc: []const u8 = switch (c) {
                .req_method => |m| m,
                .req_method_not, .req_url_not => |v| std.fmt.bufPrint(&negated_buf, "!{s}", .{v}) catch "",
                .req_url => |u| u,
                .stub_truthy => |s| s.func,
                .stub_falsy => "!falsy",
                .result_ok => "result.ok",
                .result_not_ok => "!result.ok",
                .status_is => "status",
            };
            if (desc.len > 0 and name_len + 2 + desc.len < name_buf.len) {
                name_buf[name_len] = ' ';
                name_len += 1;
                @memcpy(name_buf[name_len .. name_len + desc.len], desc);
                name_len += desc.len;
            }
        }

        const name = try self.allocator.dupe(u8, name_buf[0..name_len]);
        errdefer self.allocator.free(name);

        // Derive request properties from constraints
        var has_auth = false;

        // Build I/O stubs from constraints + tracked calls
        var io_stubs: std.ArrayList(IoStub) = .empty;
        errdefer {
            for (io_stubs.items) |stub| {
                if (stub.arg_signature) |sig| self.allocator.free(sig);
            }
            io_stubs.deinit(self.allocator);
        }
        var seq: u32 = 0;

        // First pass: gather stub requirements from constraints. An override is
        // keyed by the call site, not the function name: a path that checks
        // two calls to one function must stub each call by its own constraint.
        var stub_overrides = std.AutoHashMapUnmanaged(NodeIndex, []const u8).empty;
        defer stub_overrides.deinit(self.allocator);

        for (self.constraints.items) |c| {
            switch (c) {
                .req_method, .req_method_not, .req_url, .req_url_not => {},
                .stub_truthy => |info| {
                    try stub_overrides.put(self.allocator, info.call_site, stubValueForType(info.returns, true));
                    if (std.mem.eql(u8, info.func, "parseBearer")) has_auth = true;
                },
                .stub_falsy => |info| {
                    try stub_overrides.put(self.allocator, info.call_site, stubValueForType(info.returns, false));
                },
                .result_ok => |info| {
                    try stub_overrides.put(self.allocator, info.call_site, resultOrOkRecordStub(info.returns, true));
                },
                .result_not_ok => |info| {
                    try stub_overrides.put(self.allocator, info.call_site, resultOrOkRecordStub(info.returns, false));
                },
                .status_is => {},
            }
        }
        try self.applyStatusTests(&stub_overrides);
        const request = self.solveRequest();
        const method = request.method;
        const url = request.url;

        // Second pass: emit I/O stubs for tracked calls on this path
        for (self.io_seq.items) |io_call| {
            const result_json = stub_overrides.get(io_call.call_node orelse null_node) orelse
                if (io_call.ok_record) okRecordStub(true) else stubValueForType(io_call.returns, true);

            {
                const arg_sig: ?[]const u8 = if (io_call.call_node) |cn|
                    self.computeArgSignature(self.allocator, cn) catch null
                else
                    null;
                errdefer if (arg_sig) |sig| self.allocator.free(sig);

                try io_stubs.append(self.allocator, .{
                    .seq = seq,
                    .module = io_call.module,
                    .func = io_call.func,
                    .result_json = result_json,
                    .call_site = io_call.call_node orelse null_node,
                    .absent_handled = io_call.absent_handled,
                    .arg_signature = arg_sig,
                });
            }
            seq += 1;
        }

        // Snapshot current constraints for fault coverage analysis
        const constraints_snapshot = try self.allocator.dupe(Constraint, self.constraints.items);
        errdefer if (constraints_snapshot.len > 0) self.allocator.free(constraints_snapshot);
        try self.snapshotPathCost();

        try self.tests.append(self.allocator, .{
            .name = name,
            .method = method,
            .url = url,
            .has_auth_header = has_auth,
            .expected_status = status,
            .io_stubs = io_stubs,
            .constraints = constraints_snapshot,
            .route_root = self.walking_route_root,
            .root_function = self.walking_root_function,
        });
    }

    /// Give every call that a `status_is` constraint names the stub whose
    /// status satisfies all of its status tests and agrees with its `ok`
    /// fork, when the path has one. A path that no status satisfies keeps the
    /// stub it had: it cannot occur, and any stub is as good as another.
    fn applyStatusTests(
        self: *PathGenerator,
        stub_overrides: *std.AutoHashMapUnmanaged(NodeIndex, []const u8),
    ) error{OutOfMemory}!void {
        var requirements: std.ArrayList(status_check.Requirement) = .empty;
        defer requirements.deinit(self.allocator);
        for (self.constraints.items, 0..) |c, i| {
            const first = switch (c) {
                .status_is => |s| s,
                else => continue,
            };
            // Handle each call once, at its first status test.
            const site = first.stub.call_site;
            var seen_before = false;
            for (self.constraints.items[0..i]) |earlier| {
                if (earlier == .status_is and earlier.status_is.stub.call_site == site) seen_before = true;
            }
            if (seen_before) continue;

            requirements.clearRetainingCapacity();
            var ok_state: ?bool = null;
            for (self.constraints.items) |other| {
                switch (other) {
                    .status_is => |s| if (s.stub.call_site == site) {
                        try requirements.append(self.allocator, .{ .comparison = s.comparison, .expect = s.expect });
                    },
                    .result_ok => |info| if (info.call_site == site) {
                        ok_state = true;
                    },
                    .result_not_ok => |info| if (info.call_site == site) {
                        ok_state = false;
                    },
                    else => {},
                }
            }
            const status = status_check.chooseStatus(ok_state, requirements.items) orelse continue;
            try stub_overrides.put(self.allocator, site, statusStub(status));
        }
    }

    fn snapshotPathCost(self: *PathGenerator) !void {
        var path_cost = PathCost{};
        errdefer path_cost.deinit(self.allocator);

        try path_cost.entries.ensureTotalCapacity(self.allocator, self.io_seq.items.len);
        for (self.io_seq.items) |io_call| {
            path_cost.entries.appendAssumeCapacity(.{
                .module = io_call.module,
                .mult = io_call.mult,
            });
        }
        try self.path_costs.append(self.allocator, path_cost);
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    fn stmtAlwaysReturns(self: *const PathGenerator, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        return switch (tag) {
            .return_stmt => true,
            .block, .program => blk: {
                const block = self.ir_view.getBlock(node) orelse break :blk false;
                var i: u16 = 0;
                while (i < block.stmts_count) : (i += 1) {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, i);
                    if (self.stmtAlwaysReturns(stmt_idx)) break :blk true;
                }
                break :blk false;
            },
            .if_stmt => blk: {
                const if_s = self.ir_view.getIfStmt(node) orelse break :blk false;
                if (if_s.else_branch == null_node) break :blk false;
                break :blk self.stmtAlwaysReturns(if_s.then_branch) and self.stmtAlwaysReturns(if_s.else_branch);
            },
            else => false,
        };
    }

    fn isResponseHelper(self: *const PathGenerator, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access) return false;
        const member = self.ir_view.getMember(callee) orelse return false;

        const obj_tag = self.ir_view.getTag(member.object) orelse return false;
        if (obj_tag != .identifier) return false;
        const binding = self.ir_view.getBinding(member.object) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const obj_name = self.resolveAtomName(binding.name_atom) orelse return false;
        if (!std.mem.eql(u8, obj_name, "Response")) return false;

        const method_name = self.resolveAtomName(member.property) orelse return false;
        return std.mem.eql(u8, method_name, "json") or
            std.mem.eql(u8, method_name, "text") or
            std.mem.eql(u8, method_name, "html") or
            std.mem.eql(u8, method_name, "redirect");
    }

    fn isReqMemberAccess(self: *const PathGenerator, node: NodeIndex, prop: []const u8) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag != .member_access) return false;
        const member = self.ir_view.getMember(node) orelse return false;

        const obj_tag = self.ir_view.getTag(member.object) orelse return false;
        if (obj_tag != .identifier) return false;
        const binding = self.ir_view.getBinding(member.object) orelse return false;
        const key = packBindingKey(binding.scope_id, binding.slot);
        if (self.req_binding_key == null or key != self.req_binding_key.?) return false;

        const prop_name = self.resolveAtomName(member.property) orelse return false;
        return std.mem.eql(u8, prop_name, prop);
    }

    fn getCalleeMeta(self: *const PathGenerator, callee: NodeIndex) ?FnMeta {
        return calleeMeta(self.ir_view, &self.module_fn_bindings, callee);
    }

    fn calleeMeta(
        ir_view: IrView,
        bindings: *const std.AutoHashMapUnmanaged(u16, FnMeta),
        callee: NodeIndex,
    ) ?FnMeta {
        const tag = ir_view.getTag(callee) orelse return null;
        if (tag != .identifier) return null;
        const binding = ir_view.getBinding(callee) orelse return null;
        return bindings.get(binding.slot);
    }

    fn getPropertyKeyName(self: *const PathGenerator, key_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(key_idx) orelse return null;
        if (tag == .identifier) {
            const binding = self.ir_view.getBinding(key_idx) orelse return null;
            return self.resolveAtomName(binding.name_atom);
        } else if (tag == .lit_string) {
            const str_idx = self.ir_view.getStringIdx(key_idx) orelse return null;
            return self.ir_view.getString(str_idx);
        }
        return null;
    }

    fn resolveAtomName(self: *const PathGenerator, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            const atom: object.Atom = @enumFromInt(atom_idx);
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @enumFromInt(atom_idx);
        return atom.toPredefinedName();
    }

    fn retireLoopBound(self: *PathGenerator, bound: LoopBound) void {
        switch (bound) {
            .constant => {},
            .symbolic => |p| if (p.desc.len > 0) self.retired_loop_descs.appendAssumeCapacity(p.desc),
            .unknown => |p| if (p.desc.len > 0) self.retired_loop_descs.appendAssumeCapacity(p.desc),
        }
    }

    fn freeLoopBound(self: *PathGenerator, bound: LoopBound) void {
        switch (bound) {
            .constant => {},
            .symbolic => |p| if (p.desc.len > 0) self.allocator.free(p.desc),
            .unknown => |p| if (p.desc.len > 0) self.allocator.free(p.desc),
        }
    }

    fn allocLoopDesc(self: *PathGenerator, comptime fmt: []const u8, args: anytype, fallback: []const u8) []const u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args) catch
            self.allocator.dupe(u8, fallback) catch "";
    }

    // P2 SEAM
    /// P2 extends this body to discharge known-size iterables. Keep callers
    /// above this seam so later phases can edit this function in isolation.
    fn resolveLoopBound(self: *PathGenerator, iterable: NodeIndex, loop_node: NodeIndex) LoopBound {
        if (self.constantLoopBound(iterable)) |count| return .{ .constant = count };

        const loc: ir.SourceLocation = self.ir_view.getLoc(loop_node) orelse .{ .line = 0, .column = 0, .offset = 0 };
        const tag = self.ir_view.getTag(iterable) orelse {
            return .{ .unknown = .{
                .line = loc.line,
                .column = loc.column,
                .desc = self.allocLoopDesc("{s}", .{"for...of (unrecognized iterable)"}, "for...of (unrecognized iterable)"),
            } };
        };

        switch (tag) {
            // An identifier or member access names a real collection value we
            // iterate: the trip count is |that collection|, so the bound is
            // symbolic. We attach the collection's source name when it is
            // recoverable (see `iterableName`); a function-local whose name the
            // IR does not retain still yields a symbolic (named-less) bound.
            .identifier, .member_access => {
                if (self.iterableName(iterable)) |name| {
                    return .{ .symbolic = .{
                        .line = loc.line,
                        .column = loc.column,
                        .desc = self.allocLoopDesc("for...of over `{s}`", .{name}, "for...of loop"),
                    } };
                }
                return .{ .symbolic = .{
                    .line = loc.line,
                    .column = loc.column,
                    .desc = self.allocLoopDesc("{s}", .{"for...of loop"}, "for...of loop"),
                } };
            },
            else => return .{ .unknown = .{
                .line = loc.line,
                .column = loc.column,
                .desc = self.allocLoopDesc("{s}", .{"for...of (unrecognized iterable)"}, "for...of (unrecognized iterable)"),
            } },
        }
    }

    fn constantLoopBound(self: *PathGenerator, iterable: NodeIndex) ?u32 {
        const tag = self.ir_view.getTag(iterable) orelse return null;
        switch (tag) {
            .array_literal => return self.arrayLiteralCount(iterable),
            .call, .method_call => {
                if (self.rangeCallCount(iterable)) |count| return count;
                if (self.sliceCallCeiling(iterable)) |count| return count;
                if (self.objectKeysLiteralCount(iterable)) |count| return count;
            },
            .identifier => if (self.sqlLimitForIdentifier(iterable)) |count| return count,
            .member_access => if (self.schemaMaxItemsForMember(iterable)) |count| return count,
            else => {},
        }
        return null;
    }

    fn arrayLiteralCount(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const arr = self.ir_view.getArray(node) orelse return null;
        if (arr.has_spread) return null;
        return arr.elements_count;
    }

    fn rangeCallCount(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const call = self.ir_view.getCall(node) orelse return null;
        if (!self.isUndeclaredGlobalName(call.callee, "range")) return null;

        if (call.args_count == 1) {
            const end_node = self.ir_view.getListIndex(call.args_start, 0);
            const end = self.intLiteralValue(end_node) orelse return null;
            return nonNegativeI64ToU32(end);
        }
        if (call.args_count == 2) {
            const start_node = self.ir_view.getListIndex(call.args_start, 0);
            const end_node = self.ir_view.getListIndex(call.args_start, 1);
            const start = self.intLiteralValue(start_node) orelse return null;
            const end = self.intLiteralValue(end_node) orelse return null;
            return nonNegativeI64ToU32(end - start);
        }
        return null;
    }

    fn sliceCallCeiling(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const call = self.ir_view.getCall(node) orelse return null;
        const member = self.memberCalleeNamed(call.callee, "slice") orelse return null;
        _ = member;
        if (call.args_count < 2) return null;

        const start_node = self.ir_view.getListIndex(call.args_start, 0);
        const end_node = self.ir_view.getListIndex(call.args_start, 1);
        const start = self.intLiteralValue(start_node) orelse return null;
        const end = self.intLiteralValue(end_node) orelse return null;
        if (start != 0 or end < 0) return null;
        return nonNegativeI64ToU32(end);
    }

    fn objectKeysLiteralCount(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const call = self.ir_view.getCall(node) orelse return null;
        const member = self.memberCalleeNamed(call.callee, "keys") orelse return null;
        if (!self.isUndeclaredGlobalName(member.object, "Object")) return null;
        if (call.args_count != 1) return null;

        const obj_node = self.ir_view.getListIndex(call.args_start, 0);
        return self.objectLiteralPropertyCount(obj_node);
    }

    fn sqlLimitForIdentifier(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const binding = self.ir_view.getBinding(node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const init_node = self.var_inits.get(key) orelse return null;
        const tag = self.ir_view.getTag(init_node) orelse return null;
        if (tag != .call) return null;
        const call = self.ir_view.getCall(init_node) orelse return null;
        const meta = self.getCalleeMeta(call.callee) orelse return null;
        if (!std.mem.eql(u8, meta.module, "sql")) return null;
        if (!std.mem.eql(u8, meta.func, "sql") and !std.mem.eql(u8, meta.func, "sqlMany")) return null;
        if (call.args_count == 0) return null;

        const statement_node = self.ir_view.getListIndex(call.args_start, 0);
        const statement = self.stringLiteralValue(statement_node) orelse return null;
        return trailingLimitValue(statement);
    }

    const ValidatedField = struct {
        binding_key: u32,
        field: []const u8,
    };

    fn schemaMaxItemsForMember(self: *PathGenerator, node: NodeIndex) ?u32 {
        const access = self.validatedFieldAccess(node) orelse return null;
        const init_node = self.var_inits.get(access.binding_key) orelse return null;
        const tag = self.ir_view.getTag(init_node) orelse return null;
        if (tag != .call) return null;
        const call = self.ir_view.getCall(init_node) orelse return null;
        const meta = self.getCalleeMeta(call.callee) orelse return null;
        const validates = std.mem.eql(u8, meta.module, "validate") and
            (std.mem.eql(u8, meta.func, "validateJson") or
                std.mem.eql(u8, meta.func, "validateObject") or
                std.mem.eql(u8, meta.func, "coerceJson"));
        // zttp:tool (M4 T7) names its schema in argument 0 as well.
        const tool_input = std.mem.eql(u8, meta.module, "tool") and std.mem.eql(u8, meta.func, "toolInput");
        if (!validates and !tool_input) return null;
        if (call.args_count == 0) return null;

        const schema_name_node = self.ir_view.getListIndex(call.args_start, 0);
        const schema_name = self.stringLiteralValue(schema_name_node) orelse return null;
        const schema_json = self.schemaJsonLiteral(schema_name) orelse return null;
        return self.schemaFieldMaxItems(schema_json, access.field);
    }

    fn validatedFieldAccess(self: *const PathGenerator, node: NodeIndex) ?ValidatedField {
        const outer = self.ir_view.getMember(node) orelse return null;
        const field = self.resolveAtomName(outer.property) orelse return null;

        var root = outer.object;
        if (self.ir_view.getTag(root) == .member_access) {
            const inner = self.ir_view.getMember(root) orelse return null;
            const inner_prop = self.resolveAtomName(inner.property) orelse return null;
            if (!std.mem.eql(u8, inner_prop, "value")) return null;
            root = inner.object;
        }

        const root_tag = self.ir_view.getTag(root) orelse return null;
        if (root_tag != .identifier) return null;
        const binding = self.ir_view.getBinding(root) orelse return null;
        return .{
            .binding_key = packBindingKey(binding.scope_id, binding.slot),
            .field = field,
        };
    }

    fn schemaJsonLiteral(self: *const PathGenerator, schema_name: []const u8) ?[]const u8 {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call) continue;

            const call = self.ir_view.getCall(idx) orelse continue;
            const meta = self.getCalleeMeta(call.callee) orelse continue;
            if (!std.mem.eql(u8, meta.module, "validate")) continue;
            if (!std.mem.eql(u8, meta.func, "schemaCompile")) continue;
            if (call.args_count < 2) continue;

            const name_node = self.ir_view.getListIndex(call.args_start, 0);
            const found_name = self.stringLiteralValue(name_node) orelse continue;
            if (!std.mem.eql(u8, found_name, schema_name)) continue;

            const schema_node = self.ir_view.getListIndex(call.args_start, 1);
            return self.stringLiteralValue(schema_node);
        }
        return null;
    }

    fn schemaFieldMaxItems(self: *PathGenerator, schema_json: []const u8, field: []const u8) ?u32 {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_json, .{}) catch return null;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return null,
        };
        const properties_val = root.get("properties") orelse return null;
        const properties = switch (properties_val) {
            .object => |obj| obj,
            else => return null,
        };
        const field_val = properties.get(field) orelse return null;
        const field_obj = switch (field_val) {
            .object => |obj| obj,
            else => return null,
        };
        const field_type = field_obj.get("type") orelse return null;
        switch (field_type) {
            .string => |s| if (!std.mem.eql(u8, s, "array")) return null,
            else => return null,
        }
        const max_items = field_obj.get("maxItems") orelse return null;
        return jsonValueToU32(max_items);
    }

    fn objectLiteralPropertyCount(self: *const PathGenerator, node: NodeIndex) ?u32 {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .object_literal) return null;
        const obj = self.ir_view.getObject(node) orelse return null;
        var count: u32 = 0;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            const prop_tag = self.ir_view.getTag(prop_idx) orelse return null;
            switch (prop_tag) {
                .object_property, .object_method, .object_getter, .object_setter => count += 1,
                else => return null,
            }
        }
        return count;
    }

    fn memberCalleeNamed(self: *const PathGenerator, callee: NodeIndex, name: []const u8) ?Node.MemberExpr {
        const tag = self.ir_view.getTag(callee) orelse return null;
        if (tag != .member_access) return null;
        const member = self.ir_view.getMember(callee) orelse return null;
        const prop_name = self.resolveAtomName(member.property) orelse return null;
        if (!std.mem.eql(u8, prop_name, name)) return null;
        return member;
    }

    fn isUndeclaredGlobalName(self: *const PathGenerator, node: NodeIndex, name: []const u8) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const actual = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, actual, name);
    }

    fn intLiteralValue(self: *const PathGenerator, node: NodeIndex) ?i64 {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .lit_int) return null;
        return self.ir_view.getIntValue(node) orelse return null;
    }

    fn stringLiteralValue(self: *const PathGenerator, node: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .lit_string) return null;
        const str_idx = self.ir_view.getStringIdx(node) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    fn nonNegativeI64ToU32(value: i64) u32 {
        if (value <= 0) return 0;
        if (value > std.math.maxInt(u32)) return std.math.maxInt(u32);
        return @intCast(value);
    }

    fn trailingLimitValue(statement: []const u8) ?u32 {
        var end = statement.len;
        while (end > 0 and std.ascii.isWhitespace(statement[end - 1])) : (end -= 1) {}

        const digits_end = end;
        var digits_start = digits_end;
        while (digits_start > 0 and isAsciiDigit(statement[digits_start - 1])) : (digits_start -= 1) {}
        if (digits_start == digits_end) return null;

        var limit_end = digits_start;
        while (limit_end > 0 and std.ascii.isWhitespace(statement[limit_end - 1])) : (limit_end -= 1) {}
        if (limit_end < "LIMIT".len) return null;
        const limit_start = limit_end - "LIMIT".len;
        if (!std.ascii.eqlIgnoreCase(statement[limit_start..limit_end], "LIMIT")) return null;
        if (limit_start > 0 and !std.ascii.isWhitespace(statement[limit_start - 1])) return null;

        return std.fmt.parseInt(u32, statement[digits_start..digits_end], 10) catch null;
    }

    fn isAsciiDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn jsonValueToU32(v: std.json.Value) ?u32 {
        const max: f64 = @floatFromInt(std.math.maxInt(u32));
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            .float => |f| if (std.math.isFinite(f) and f >= 0 and f <= max) @intFromFloat(@trunc(f)) else null,
            else => null,
        };
    }

    /// Best-effort source name for a `for...of` iterable, for provenance only.
    /// Returns a BORROWED slice (atom/string table) or null when the name is
    /// not recoverable. `BindingRef.slot` is a real atom index only for
    /// global/builtin bindings; for a function-local it is a scope slot, so
    /// resolving it as an atom would yield a wrong (colliding) predefined name.
    /// For a local we instead recover the name from a request-field
    /// initializer, e.g. `const ids = req.ids`. P2 may extend this.
    fn iterableName(self: *const PathGenerator, iterable: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(iterable) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(iterable) orelse return null;
                if (binding.kind == .global or binding.kind == .undeclared_global) {
                    return self.resolveAtomName(binding.name_atom);
                }
                const key = packBindingKey(binding.scope_id, binding.slot);
                const init_node = self.var_inits.get(key) orelse return null;
                return self.memberPropertyName(init_node);
            },
            .member_access => return self.memberPropertyName(iterable),
            else => return null,
        }
    }

    fn memberPropertyName(self: *const PathGenerator, node: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .member_access) return null;
        const member = self.ir_view.getMember(node) orelse return null;
        return self.resolveAtomName(member.property);
    }
};

// ---------------------------------------------------------------------------
// Stub value synthesis
// ---------------------------------------------------------------------------

/// Whether `x.ok` and `x.status` fork the result of a call to this export: it is
/// failable, does not return a `Result`, and declares an `ok`-record response
/// (`fetch`). The flow checker's witness search asks the same question, so the
/// generated tests and the counterexamples fork the same calls.
pub fn isOkRecordExport(allocator: std.mem.Allocator, func: *const mb.FunctionBinding) error{OutOfMemory}!bool {
    return func.failure_severity != .none and func.returns != .result and
        try declaresOkRecord(allocator, func);
}

/// Whether the export is forked by `x.ok` on its result because it declares an
/// `ok: boolean` response record. The rule reads the parsed return type, not the
/// signature text: `returnsOkRecord` resolves it through the type environment.
/// The caller applies it only to exports with a failure severity, so
/// `zttp:workflow` `call`, which declares the same record with severity `.none`,
/// adds no fork.
fn declaresOkRecord(allocator: std.mem.Allocator, func: *const mb.FunctionBinding) error{OutOfMemory}!bool {
    const sig = func.signature orelse return false;
    return returnsOkRecord(allocator, sig.returns);
}

/// True when `return_text` parses to a record that has a top-level, required
/// field `ok` of type `boolean`. A nested `ok`, an optional `ok`, a union that
/// holds such a record, and a function type all give false.
pub fn returnsOkRecord(allocator: std.mem.Allocator, return_text: []const u8) error{OutOfMemory}!bool {
    var pool = type_pool_mod.TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = type_env_mod.TypeEnv.init(allocator, &pool);
    defer env.deinit();

    const parsed = env.resolveType(return_text);
    try env.ensureHealthy();
    if (parsed == type_pool_mod.null_type_idx) return false;
    const resolved = env.resolveRef(parsed);
    if (pool.getTag(resolved) != .t_record) return false;
    for (pool.getRecordFields(resolved)) |field| {
        if (field.optional) continue;
        if (!std.mem.eql(u8, pool.getName(field.name_start, field.name_len), "ok")) continue;
        if (field.type_idx == pool.idx_boolean) return true;
    }
    return false;
}

/// The stub for a call forked by `x.ok`. A `Result` export gets the Result
/// shape. An `ok`-record export (`fetch`) gets a response the replay reads:
/// `status` decides `ok` (replay derives it from the status, never from a stub
/// field), and `statusText`, `headers`, and `body` are the other fields
/// `runtime_http.zig` reads from a recorded fetch.
fn resultOrOkRecordStub(returns: mb.ReturnKind, ok: bool) []const u8 {
    if (returns == .result) return stubValueForType(.result, ok);
    return okRecordStub(ok);
}

/// The stubs are shared with the counterexample solver, so a witness and a
/// generated test drive an `ok`-record call with the same response.
const okRecordStub = status_check.okRecordStub;
const statusStub = status_check.statusStub;

fn stubValueForType(returns: mb.ReturnKind, truthy: bool) []const u8 {
    if (!truthy) {
        return switch (returns) {
            .optional_string, .optional_object, .optional_number => "null",
            .result => "{\"ok\":false,\"error\":\"test-error\"}",
            .boolean => "false",
            .number => "0",
            else => "null",
        };
    }
    return switch (returns) {
        .optional_string, .string => "\"test-value\"",
        .optional_object, .object => "{\"id\":\"1\"}",
        .result => "{\"ok\":true,\"value\":{}}",
        .boolean => "true",
        .number, .optional_number => "42",
        .undefined => "null",
        .unknown => "\"test-value\"",
        .dict => "{}",
        // No JSON literal denotes a Bytes; the empty octet list is the
        // closest true spelling. See counterexample.zig for why the
        // `zttp:bytes` exports do not reach this arm.
        .bytes => "[]",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stubValueForType truthy" {
    try std.testing.expectEqualStrings("\"test-value\"", stubValueForType(.optional_string, true));
    try std.testing.expectEqualStrings("{\"ok\":true,\"value\":{}}", stubValueForType(.result, true));
    try std.testing.expectEqualStrings("true", stubValueForType(.boolean, true));
}

test "stubValueForType falsy" {
    try std.testing.expectEqualStrings("null", stubValueForType(.optional_string, false));
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"test-error\"}", stubValueForType(.result, false));
    try std.testing.expectEqualStrings("false", stubValueForType(.boolean, false));
}

test "scanImports tracks virtual module functions with binding names" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\const value = env("NAME");
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();

    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var generator = PathGenerator.init(allocator, ir_view, &atoms);
    defer generator.deinit();
    try generator.scanImports();

    // Find the slot through the index rather than re-walking import_decl here:
    // this test was the last duplicate of that traversal in the file.
    var facts = try module_facts_mod.ModuleFacts.build(allocator, ir_view, &atoms, null);
    defer facts.deinit();
    var tracked_slot: ?u16 = null;
    for (facts.imports.items) |rec| {
        if (std.mem.eql(u8, rec.module_specifier, "zttp:env")) {
            tracked_slot = rec.slot;
            break;
        }
    }

    const meta = generator.module_fn_bindings.get(tracked_slot orelse return error.ExpectedTrackedSlot) orelse return error.ExpectedTrackedMeta;
    try std.testing.expectEqualStrings("env", meta.module);
    try std.testing.expectEqualStrings("env", meta.func);
    try std.testing.expectEqual(mb.ReturnKind.optional_string, meta.returns);
}

const parser_mod = @import("zts-engine").parser;
const handler_verifier = @import("handler_verifier.zig");
const module_manifest_mod = @import("zts-engine").module_manifest;
const manifest_registry_mod = @import("manifest_registry.zig");

const PathGeneratorFixture = struct {
    parser: parser_mod.JsParser,
    atoms: atom_table.AtomTable,
    generator: PathGenerator,
    /// The scan answer given to the generator, owned here.
    scan_entries: []PathGenerator.ImportScanEntry = &.{},

    fn deinit(self: *PathGeneratorFixture) void {
        std.testing.allocator.free(self.scan_entries);
        self.generator.deinit();
        self.parser.deinit();
        self.atoms.deinit();
    }
};

const FailNextAllocation = struct {
    child: std.mem.Allocator,
    armed: bool = true,
    allocations_before_failure: usize = 0,

    fn init(child: std.mem.Allocator) FailNextAllocation {
        return .{ .child = child };
    }

    fn allocator(self: *FailNextAllocation) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context_ptr: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FailNextAllocation = @ptrCast(@alignCast(context_ptr));
        if (self.armed) {
            if (self.allocations_before_failure > 0) {
                self.allocations_before_failure -= 1;
                return self.child.rawAlloc(len, alignment, return_address);
            }
            self.armed = false;
            return null;
        }
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context_ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *FailNextAllocation = @ptrCast(@alignCast(context_ptr));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context_ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *FailNextAllocation = @ptrCast(@alignCast(context_ptr));
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context_ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *FailNextAllocation = @ptrCast(@alignCast(context_ptr));
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn expectGenerationFailsOnFirstAllocation(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;
    var failing = FailNextAllocation.init(allocator);
    var generator = PathGenerator.init(failing.allocator(), ir_view, &atoms);
    defer generator.deinit();

    try std.testing.expectError(error.OutOfMemory, generator.generate(handler_fn));
}

test "generate fails closed when import binding allocation fails" {
    try expectGenerationFailsOnFirstAllocation(
        \\import { env } from "zttp:env";
        \\export function handler(req) {
        \\  const value = env("NAME");
        \\  return Response.json(value);
        \\}
    );
}

test "generate fails closed when handler binding allocation fails" {
    try expectGenerationFailsOnFirstAllocation(
        \\export function handler(req) {
        \\  const method = req.method;
        \\  if (method === "POST") return Response.json(true);
        \\  return Response.json(false);
        \\}
    );
}

fn expectWalkFailsOnNextAllocation(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;
    const function = ir_view.getFunction(handler_fn) orelse return error.HandlerNotFound;

    var failing = FailNextAllocation.init(allocator);
    failing.armed = false;
    var generator = PathGenerator.init(failing.allocator(), ir_view, &atoms);
    defer generator.deinit();
    try generator.scanImports();
    try generator.findHandlerBindings(handler_fn);
    failing.armed = true;

    try std.testing.expectError(error.OutOfMemory, generator.walkPaths(function.body));
}

test "walkPaths fails closed when local binding allocation fails" {
    try expectWalkFailsOnNextAllocation(
        \\export function handler(req) {
        \\  if (req.method === "GET") {
        \\    const local = req.url;
        \\    return Response.json(local);
        \\  }
        \\  return Response.json(false);
        \\}
    );
}

test "walkPaths fails closed when I/O sequence allocation fails" {
    try expectWalkFailsOnNextAllocation(
        \\import { env } from "zttp:env";
        \\export function handler(req) {
        \\  env("NAME");
        \\  return Response.json(true);
        \\}
    );
}

test "emitTestCase keeps argument signature allocation failure conservative" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\export function handler(req) {
        \\  env("NAME");
        \\  return Response.json(true);
        \\}
    ;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    var failing = FailNextAllocation.init(allocator);
    failing.armed = false;
    var generator = PathGenerator.init(failing.allocator(), ir_view, &atoms);
    defer generator.deinit();
    try generator.scanImports();
    try generator.findHandlerBindings(handler_fn);
    for (0..ir_view.nodeCount()) |idx| {
        try generator.trackModuleCall(@intCast(idx), null);
    }
    try std.testing.expectEqual(@as(usize, 1), generator.io_seq.items.len);

    // The first allocation duplicates the test name; fail the signature copy
    // immediately after it so the production fallback is exercised.
    failing.allocations_before_failure = 1;
    failing.armed = true;
    try generator.emitTestCase(200);

    try std.testing.expect(!failing.armed);
    try std.testing.expectEqual(@as(usize, 1), generator.tests.items.len);
    try std.testing.expectEqual(@as(usize, 1), generator.tests.items[0].io_stubs.items.len);
    try std.testing.expect(generator.tests.items[0].io_stubs.items[0].arg_signature == null);
}

fn generateWithAllocator(
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: *atom_table.AtomTable,
    handler_fn: NodeIndex,
) !void {
    var generator = PathGenerator.init(allocator, ir_view, atoms);
    defer generator.deinit();
    try generator.generate(handler_fn);
}

test "generate cleans every fatal allocation failure" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  for (const id of ids) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json(true);
        \\}
    ;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    try std.testing.checkAllAllocationFailures(
        allocator,
        generateWithAllocator,
        .{ ir_view, &atoms, handler_fn },
    );
}

fn costEnvelopeWithAllocator(
    allocator: std.mem.Allocator,
    generator: *const PathGenerator,
) !void {
    var envelope = try generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);
}

test "cost envelope cleans every allocation failure" {
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  for (const id of ids) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json(true);
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        costEnvelopeWithAllocator,
        .{&fixture.generator},
    );
}

fn behaviorPathsWithAllocator(
    allocator: std.mem.Allocator,
    generator: *const PathGenerator,
) !void {
    var paths = try generator.toBehaviorPaths(allocator);
    defer {
        for (paths.items) |*path| path.deinit(allocator);
        paths.deinit(allocator);
    }
}

test "behavior path conversion cleans every allocation failure" {
    const source =
        \\import { env } from "zttp:env";
        \\export function handler(req) {
        \\  const value = env("NAME");
        \\  if (value !== undefined) return Response.json(true);
        \\  return Response.json(false);
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        behaviorPathsWithAllocator,
        .{&fixture.generator},
    );
}

test "route roots stay internal to analysis outputs" {
    const allocator = std.testing.allocator;
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  return Response.text("created", { status: 201 });
        \\}
        \\const routes = { "POST /probe": route };
        \\export function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var found_route_root = false;
    for (fixture.generator.getTests()) |generated| {
        if (generated.route_root and generated.expected_status == 201) {
            found_route_root = true;
            break;
        }
    }
    try std.testing.expect(found_route_root);

    var jsonl: std.ArrayList(u8) = .empty;
    defer jsonl.deinit(allocator);
    var allocating_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &jsonl);
    try fixture.generator.writeJsonl(&allocating_writer.writer);
    jsonl = allocating_writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, jsonl.items, "\"status\":201") == null);

    var paths = try fixture.generator.toBehaviorPaths(allocator);
    defer {
        for (paths.items) |*path| path.deinit(allocator);
        paths.deinit(allocator);
    }
    for (paths.items) |path| {
        try std.testing.expect(path.response_status != 201);
    }
}

fn generateFixture(allocator: std.mem.Allocator, source: []const u8) !PathGeneratorFixture {
    return generateFixtureScanned(allocator, source, null);
}

/// One answer for the import records that name `specifier`.
const SpecifierScan = struct {
    specifier: []const u8,
    scan: PathGenerator.ImportScan,
};

/// Like `generateFixture`, and gives the generator an import scan before it
/// generates. `scans` null gives no input at all; a slice gives an entry for
/// each non-builtin record whose specifier it names, and none for the rest.
fn generateFixtureScanned(
    allocator: std.mem.Allocator,
    source: []const u8,
    scans: ?[]const SpecifierScan,
) !PathGeneratorFixture {
    var parser = try parser_mod.JsParser.init(allocator, source);
    errdefer parser.deinit();

    var atoms = atom_table.AtomTable.init(allocator);
    errdefer atoms.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    var generator = PathGenerator.init(allocator, ir_view, &atoms);
    errdefer generator.deinit();
    var entries: std.ArrayList(PathGenerator.ImportScanEntry) = .empty;
    errdefer entries.deinit(allocator);
    if (scans) |given| {
        const facts = try generator.importFacts();
        for (facts.imports.items) |rec| {
            for (given) |candidate| {
                if (!std.mem.eql(u8, candidate.specifier, rec.module_specifier)) continue;
                try entries.append(allocator, .{ .slot = rec.slot, .scan = candidate.scan });
            }
        }
        generator.setImportedScan(entries.items);
    }
    try generator.generate(handler_fn);

    return .{
        .parser = parser,
        .atoms = atoms,
        .generator = generator,
        .scan_entries = try entries.toOwnedSlice(allocator),
    };
}

test "recursive handler gets no constant cost bound" {
    const allocator = std.testing.allocator;
    // Measured before this test existed: `zts check` on this shape reported
    // `cost_bounded PROVEN`, `Max I/O depth: 0`, and `1 (exhaustive)`. All
    // three are false. `depth` calls `sqlOne` once per level and the level
    // count comes from the request, so the module-call count is unbounded, and
    // the generator never followed the call at all. Spec 5.6: no runtime stack
    // cap may be presented as a termination proof.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function depth(n) {
        \\  if (n === 0) {
        \\    return 0;
        \\  }
        \\  sqlOne("row");
        \\  return depth(n - 1) + 1;
        \\}
        \\export function handler(req) {
        \\  const d = depth(req.n);
        \\  return Response.json({ d: d });
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.total.class() == .unbounded);
    try std.testing.expect(!envelope.exhaustive);
}

test "handler calling a recursive helper gets no constant cost bound" {
    const allocator = std.testing.allocator;
    // The recursion is one hop away, and `EffectRow.recursive` does not
    // propagate to callers by design, so this needs call-graph reachability
    // rather than the handler's own row.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function inner(n) {
        \\  if (n === 0) {
        \\    return 0;
        \\  }
        \\  sqlOne("row");
        \\  return inner(n - 1);
        \\}
        \\function outer(n) {
        \\  return inner(n);
        \\}
        \\export function handler(req) {
        \\  const d = outer(req.n);
        \\  return Response.json({ d: d });
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.total.class() == .unbounded);
}

test "non-recursive helper keeps its constant cost bound" {
    const allocator = std.testing.allocator;
    // The downgrade must be keyed on recursion, not on calling a helper at all.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function load(id) {
        \\  return id;
        \\}
        \\export function handler(req) {
        \\  sqlOne("row");
        \\  const a = load("x");
        \\  return Response.json({ a: a });
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.total.class() != .unbounded);
    try std.testing.expect(envelope.exhaustive);
}

test "envelope is not exhaustive when a loop body is summarized" {
    const allocator = std.testing.allocator;
    // The generator walks a for...of body once, as a representative iteration,
    // and never enumerates the zero-iteration case. Both branches of the `if`
    // below therefore appear on the enumerated paths, but the interleavings
    // across iterations do not. That is a summary, not an enumeration, so the
    // envelope must not claim exhaustive coverage (spec gap 11).
    const source =
        \\export function handler(req) {
        \\  const items = req.items;
        \\  for (const item of items) {
        \\    if (item.ok) {
        \\      return Response.json({ ok: true });
        \\    }
        \\  }
        \\  return Response.json({ ok: false });
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(!envelope.exhaustive);
    try std.testing.expect(!fixture.generator.pathsExhaustive());
}

test "envelope stays exhaustive for a loop-free handler" {
    const allocator = std.testing.allocator;
    const source =
        \\export function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.json({ ok: true });
        \\  }
        \\  return Response.json({ ok: false });
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(envelope.exhaustive);
    try std.testing.expect(fixture.generator.pathsExhaustive());
}

test "a summarized loop does not make the cost total unbounded" {
    const allocator = std.testing.allocator;
    // Losing exhaustive path coverage is not losing the cost bound: the loop
    // still carries a symbolic linear bound in the collection's length. Only
    // MAX_PATHS truncation forces the total to unbounded.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  for (const id of ids) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expect(!envelope.exhaustive);
    try std.testing.expect(envelope.total.class() != .unbounded);
}

test "for...of over request-derived array yields linear io multiplicity" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  sqlOne("setup");
        \\  for (const id of ids) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    // Spec gap 11: the loop body is summarized, not enumerated, so the envelope
    // cannot claim exhaustive path coverage. The cost bound below is unaffected.
    try std.testing.expect(!envelope.exhaustive);
    const total = envelope.total.linear;
    try std.testing.expectEqual(@as(u32, 1), total.coefficient);
    try std.testing.expectEqual(@as(u32, 1), total.base);
    try std.testing.expectEqual(@as(u32, 5), total.source.line);
    try std.testing.expectEqualStrings("for...of over `ids`", total.source.desc);
}

test "io call outside loops stays constant" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  sqlOne("setup");
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 1), envelope.total.constant);
}

test "routerMatch cost composes handler and route calls" {
    const allocator = std.testing.allocator;
    const source =
        \\import { cacheGet } from "zttp:cache";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const route_value = cacheGet("probe", "route");
        \\  return Response.json({ value: route_value });
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const handler_value = cacheGet("probe", "handler");
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ value: handler_value }, { status: 404 });
        \\  return found.handler(req);
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    const cache_bound = envelope.find("cache") orelse return error.ExpectedCacheBound;
    try std.testing.expectEqual(contract_types.BoundClass.constant, cache_bound.class());
    try std.testing.expectEqual(@as(u32, 2), cache_bound.constant);
    try std.testing.expect(envelope.total.constant >= 2);
}

test "repeated routerMatch dispatch makes cost unbounded" {
    const allocator = std.testing.allocator;
    const source =
        \\import { cacheGet } from "zttp:cache";
        \\import { routerMatch } from "zttp:router";
        \\function route(req) {
        \\  const value = cacheGet("probe", "route");
        \\  return Response.json({ value: value });
        \\}
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const first = routerMatch(routes, req);
        \\  const second = routerMatch(routes, req);
        \\  if (first === undefined) return Response.text("not found", { status: 404 });
        \\  if (second === undefined) return Response.text("not found", { status: 404 });
        \\  const ignored = first.handler(req);
        \\  return second.handler(req);
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.unbounded, envelope.total.class());
    try std.testing.expect(!fixture.generator.pathsExhaustive());
}

test "nested dynamic for...of degrades to unbounded" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  const names = req.names;
        \\  for (const id of ids) {
        \\    for (const name of names) {
        \\      sqlOne("row");
        \\    }
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.unbounded, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 6), envelope.total.unbounded.line);
    try std.testing.expectEqualStrings("for...of over `names`", envelope.total.unbounded.desc);
}

test "loop-aware envelope leaves generated test stubs unchanged" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  for (const id of ids) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqual(@as(usize, 1), tests[0].io_stubs.items.len);

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);
    try std.testing.expectEqual(contract_types.BoundClass.linear, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 1), envelope.total.linear.coefficient);
}

test "for...of over array literal discharges to constant" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  for (const id of [1, 2, 3]) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 3), envelope.total.constant);
}

test "range(n) literal discharges loop bound" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  for (const id of range(4)) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 4), envelope.total.constant);
}

test "slice(0, k) discharges loop bound" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const ids = req.ids;
        \\  for (const id of ids.slice(0, 2)) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 2), envelope.total.constant);
}

test "Object.keys of object literal discharges loop bound" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  for (const key of Object.keys({ a: 1, b: 2, c: 3 })) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 3), envelope.total.constant);
}

test "sql LIMIT n discharges loop over query rows" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sqlMany, sqlOne } from "zttp:sql";
        \\export function handler(req) {
        \\  const rows = sqlMany("SELECT id FROM todos ORDER BY id LIMIT 3");
        \\  for (const row of rows) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
    try std.testing.expectEqual(@as(u32, 4), envelope.total.constant);
}

test "validated field with maxItems discharges to constant ceiling" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\import { sqlOne } from "zttp:sql";
        \\schemaCompile("payload", "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"maxItems\":2}}}");
        \\export function handler(req) {
        \\  const parsed = validateJson("payload", req.body);
        \\  if (!parsed.ok) return Response.json({}, { status: 400 });
        \\  for (const item of parsed.value.items) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    const sql_bound = envelope.find("sql") orelse return error.ExpectedSqlBound;
    try std.testing.expectEqual(contract_types.BoundClass.constant, sql_bound.class());
    try std.testing.expectEqual(@as(u32, 2), sql_bound.constant);
    try std.testing.expectEqual(contract_types.BoundClass.constant, envelope.total.class());
}

test "validated field without maxItems stays linear" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\import { sqlOne } from "zttp:sql";
        \\schemaCompile("payload", "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\"}}}");
        \\export function handler(req) {
        \\  const parsed = validateJson("payload", req.body);
        \\  if (!parsed.ok) return Response.json({}, { status: 400 });
        \\  for (const item of parsed.value.items) {
        \\    sqlOne("row");
        \\  }
        \\  return Response.json({});
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var envelope = try fixture.generator.buildCostEnvelope(allocator);
    defer envelope.deinit(allocator);

    const sql_bound = envelope.find("sql") orelse return error.ExpectedSqlBound;
    try std.testing.expectEqual(contract_types.BoundClass.linear, sql_bound.class());
    try std.testing.expectEqual(@as(u32, 1), sql_bound.linear.coefficient);
    try std.testing.expectEqualStrings("for...of over `items`", sql_bound.linear.source.desc);
}

const import_corpus = @import("tests/import_corpus.zig");

test "the import scan maps builtin slots to function metadata in both atom modes" {
    // Replaces the differential that proved this scan matches the pre-C1
    // implementation. Both atom modes, per C1 finding 2.
    const allocator = std.testing.allocator;

    for ([_]bool{ true, false }) |use_atoms| {
        var parser = try @import("zts-engine").parser.JsParser.init(allocator,
            \\import { env } from "zttp:env";
            \\import { sha256 } from "zttp:crypto";
            \\import { thing } from "zttp-ext:unknown";
        );
        defer parser.deinit();
        var atoms = atom_table.AtomTable.init(allocator);
        defer atoms.deinit();
        if (use_atoms) parser.setAtomTable(&atoms);
        _ = try parser.parse();
        const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

        var gen = PathGenerator.init(allocator, ir_view, if (use_atoms) &atoms else null);
        defer gen.deinit();
        try gen.scanImports();

        // Two builtins tracked, the unresolved module skipped. sha256 is the
        // case that has no generic_bindings entry, so it is only reachable
        // through the unfiltered imports collection.
        std.testing.expectEqual(@as(u32, 2), gen.module_fn_bindings.count()) catch |err| {
            std.debug.print("\natoms={}: expected 2 bindings, found {d}\n", .{ use_atoms, gen.module_fn_bindings.count() });
            return err;
        };
    }
}

test "this generator skips imports from unresolved modules" {
    // The filter difference: builtins only, unlike strict_checker and
    // effect_inference which record every import.
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator,
        \\import { env } from "zttp:env";
        \\import { thing } from "zttp-ext:unknown";
    );
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var gen = PathGenerator.init(allocator, ir_view, &atoms);
    defer gen.deinit();
    try gen.scanImports();

    try std.testing.expectEqual(@as(u32, 1), gen.module_fn_bindings.count());
    var it = gen.module_fn_bindings.iterator();
    try std.testing.expectEqualStrings("env", it.next().?.value_ptr.func);
}

test "a path that checks two calls to one function stubs each call by its own constraint" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  if (!a.ok) return Response.text("a failed", { status: 401 });
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!b.ok) return Response.text("b failed", { status: 403 });
        \\  return Response.text("ok");
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);

    var checked_first_fail: usize = 0;
    var checked_second_fail: usize = 0;
    var checked_both_ok: usize = 0;
    for (tests) |test_case| {
        try std.testing.expect(test_case.io_stubs.items.len >= 1);
        const first_ok = std.mem.indexOf(u8, test_case.io_stubs.items[0].result_json, "\"ok\":true") != null;
        switch (test_case.expected_status) {
            401 => {
                // The first call fails. The second call is never reached.
                try std.testing.expect(!first_ok);
                checked_first_fail += 1;
            },
            403 => {
                // The first call succeeds and only the second call fails.
                try std.testing.expectEqual(@as(usize, 2), test_case.io_stubs.items.len);
                try std.testing.expect(first_ok);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[1].result_json, "\"ok\":false") != null);
                checked_second_fail += 1;
            },
            200 => {
                try std.testing.expectEqual(@as(usize, 2), test_case.io_stubs.items.len);
                try std.testing.expect(first_ok);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[1].result_json, "\"ok\":true") != null);
                checked_both_ok += 1;
            },
            else => return error.UnexpectedStatus,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), checked_first_fail);
    try std.testing.expectEqual(@as(usize, 1), checked_second_fail);
    try std.testing.expectEqual(@as(usize, 1), checked_both_ok);
}

test "the scan names a failable call the walk never recorded" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  return Response.text(jwtVerify("t", "secret").error);
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const unseen = fixture.generator.unseenFailableCalls();
    try std.testing.expectEqual(@as(usize, 1), unseen.len);
    try std.testing.expectEqualStrings("jwtVerify", unseen[0].func);
    try std.testing.expectEqualStrings("auth", unseen[0].module);
    try std.testing.expect(!fixture.generator.faultAnalysisComplete());
}

test "the scan lists nothing for a recorded call or a call answered by ??" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const a = jwtVerify("t", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text(env("NAME") ?? "anon");
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
    try std.testing.expect(fixture.generator.faultAnalysisComplete());
}

test "a call to an export with no failure severity is never listed" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req) {
        \\  return Response.text(sha256("x"));
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
}

const sibling_import_handler =
    \\import { jwtVerify } from "zttp:auth";
    \\import { helper } from "./dep.ts";
    \\function handler(req) {
    \\  const a = jwtVerify("t", "secret");
    \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
    \\  return Response.text(helper());
    \\}
;

test "no import scan counts a relative import as one unseen call at its import line" {
    const allocator = std.testing.allocator;
    var fixture = try generateFixture(allocator, sibling_import_handler);
    defer fixture.deinit();

    const unseen = fixture.generator.unseenFailableCalls();
    try std.testing.expectEqual(@as(usize, 1), unseen.len);
    const cause = unseen[0].imported orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("./dep.ts", cause.file);
    try std.testing.expectEqual(PathGenerator.BlockReason.not_scanned, cause.blocked orelse return error.TestExpectedEqual);
    // The location is the handler's import, not a node of another file.
    try std.testing.expect(unseen[0].node != null_node);
    try std.testing.expectEqual(@as(u32, 2), fixture.generator.ir_view.getLoc(unseen[0].node).?.line);
    try std.testing.expect(!fixture.generator.faultAnalysisComplete());
}

test "an import scan that omits one record leaves that record unseen" {
    const allocator = std.testing.allocator;
    const source =
        \\import { a } from "./a.ts";
        \\import { b } from "./b.ts";
        \\function handler(req) {
        \\  return Response.text(a() + b());
        \\}
    ;
    var fixture = try generateFixtureScanned(allocator, source, &.{
        .{ .specifier = "./a.ts", .scan = .clean },
    });
    defer fixture.deinit();

    const unseen = fixture.generator.unseenFailableCalls();
    try std.testing.expectEqual(@as(usize, 1), unseen.len);
    try std.testing.expectEqualStrings("./b.ts", unseen[0].imported.?.file);
    try std.testing.expectEqual(PathGenerator.BlockReason.not_scanned, unseen[0].imported.?.blocked.?);
    try std.testing.expect(!fixture.generator.faultAnalysisComplete());
}

test "a clean answer for every relative import leaves the analysis complete" {
    const allocator = std.testing.allocator;
    var fixture = try generateFixtureScanned(allocator, sibling_import_handler, &.{
        .{ .specifier = "./dep.ts", .scan = .clean },
    });
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
    try std.testing.expect(fixture.generator.faultAnalysisComplete());
}

test "a handler with only builtin imports needs no import scan" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const a = jwtVerify("t", "secret");
        \\  if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
    try std.testing.expect(fixture.generator.faultAnalysisComplete());
}

test "a failable answer and every blocked answer each count and name their cause" {
    const allocator = std.testing.allocator;
    const reasons = [_]PathGenerator.BlockReason{ .not_relative, .unreadable, .too_deep, .partner };
    for (reasons) |reason| {
        var fixture = try generateFixtureScanned(allocator, sibling_import_handler, &.{
            .{ .specifier = "./dep.ts", .scan = .{ .blocked = .{ .file = "./deep.ts", .reason = reason } } },
        });
        defer fixture.deinit();

        const unseen = fixture.generator.unseenFailableCalls();
        try std.testing.expectEqual(@as(usize, 1), unseen.len);
        try std.testing.expectEqual(reason, unseen[0].imported.?.blocked.?);
        try std.testing.expectEqualStrings("./deep.ts", unseen[0].imported.?.file);
        try std.testing.expect(!fixture.generator.faultAnalysisComplete());
        const described = try unseen[0].describe(allocator);
        defer if (described.owned) allocator.free(described.text);
        const expected = try std.fmt.allocPrint(allocator, "./deep.ts ({s})", .{reason.text()});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, described.text);
    }

    var failable = try generateFixtureScanned(allocator, sibling_import_handler, &.{
        .{ .specifier = "./dep.ts", .scan = .{ .failable = .{ .file = "./dep.ts", .module = "fetch", .func = "fetch" } } },
    });
    defer failable.deinit();
    const unseen = failable.generator.unseenFailableCalls();
    try std.testing.expectEqual(@as(usize, 1), unseen.len);
    try std.testing.expect(unseen[0].imported.?.blocked == null);
    const described = try unseen[0].describe(allocator);
    defer if (described.owned) allocator.free(described.text);
    try std.testing.expectEqualStrings("fetch in ./dep.ts", described.text);
    try std.testing.expect(!failable.generator.faultAnalysisComplete());
}

test "a partner import is unseen even when an answer calls it clean" {
    const allocator = std.testing.allocator;
    var manifest = try module_manifest_mod.parse(allocator,
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:stripe",
        \\  "backend": "native-zig",
        \\  "requiredCapabilities": ["network"],
        \\  "exports": [
        \\    { "name": "chargeCard", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    );
    errdefer manifest.deinit(allocator);
    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    try registry.register(manifest);

    const source =
        \\import { chargeCard } from "zttp-ext:stripe";
        \\function handler(req) {
        \\  const r = chargeCard("x");
        \\  return Response.text("ok");
        \\}
    ;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    var facts = try module_facts_mod.ModuleFacts.build(allocator, ir_view, &atoms, &registry);
    defer facts.deinit();
    try std.testing.expectEqual(module_facts_mod.ImportRecord.Resolution.partner, facts.imports.items[0].resolution);

    var generator = PathGenerator.init(allocator, ir_view, &atoms);
    defer generator.deinit();
    generator.facts = &facts;
    const clean = [_]PathGenerator.ImportScanEntry{.{ .slot = facts.imports.items[0].slot, .scan = .clean }};
    generator.setImportedScan(&clean);
    try generator.generate(handler_fn);

    const unseen = generator.unseenFailableCalls();
    try std.testing.expectEqual(@as(usize, 1), unseen.len);
    try std.testing.expectEqual(PathGenerator.BlockReason.partner, unseen[0].imported.?.blocked.?);
    try std.testing.expectEqualStrings("zttp-ext:stripe", unseen[0].imported.?.file);
    try std.testing.expect(!generator.faultAnalysisComplete());
}

/// Parse `source` as an imported file and list what the scan core finds in it.
fn scanImportedSource(allocator: std.mem.Allocator, source: []const u8) !usize {
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var facts = try module_facts_mod.ModuleFacts.build(allocator, ir_view, &atoms, null);
    defer facts.deinit();
    var sites: std.ArrayList(PathGenerator.UnseenCall) = .empty;
    defer sites.deinit(allocator);
    try PathGenerator.scanImportedFile(allocator, ir_view, facts.imports.items, &sites);
    return sites.items.len;
}

test "the file scan lists a failable call, a failable value use, and nothing else" {
    const allocator = std.testing.allocator;
    // An unchecked call in a helper: no walk exists, so it counts.
    try std.testing.expectEqual(@as(usize, 1), try scanImportedSource(allocator,
        \\import { fetch } from "zttp:fetch";
        \\export function enrich() {
        \\  const res = fetch("https://api.example.com/b");
        \\  return res.body;
        \\}
    ));
    // A call that a branch checks still counts: only the handler's own walk
    // can record a stub.
    try std.testing.expectEqual(@as(usize, 1), try scanImportedSource(allocator,
        \\import { jwtVerify } from "zttp:auth";
        \\export function check(t) {
        \\  const a = jwtVerify(t, "secret");
        \\  if (!a.ok) return "no";
        \\  return "yes";
        \\}
    ));
    // The failable export used as a value.
    try std.testing.expectEqual(@as(usize, 1), try scanImportedSource(allocator,
        \\import { fetch } from "zttp:fetch";
        \\export const f = fetch;
    ));
    // `??` on an optional-returning export answers the absent value.
    try std.testing.expectEqual(@as(usize, 0), try scanImportedSource(allocator,
        \\import { env } from "zttp:env";
        \\export function token() { return env("API_TOKEN") ?? "none"; }
    ));
    // The same call without `??` counts.
    try std.testing.expectEqual(@as(usize, 1), try scanImportedSource(allocator,
        \\import { env } from "zttp:env";
        \\export function token() { return env("API_TOKEN"); }
    ));
    // Pure code and a severity-less export give nothing.
    try std.testing.expectEqual(@as(usize, 0), try scanImportedSource(allocator,
        \\import { sha256 } from "zttp:crypto";
        \\export function digest(s) { return sha256(s); }
    ));
}

test "a summarized path set is not a complete fault analysis" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  for (const i of range(2)) {
        \\    const a = jwtVerify("t", "secret");
        \\    if (!a.ok) return Response.text("unauthorized", { status: 401 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
    try std.testing.expect(!fixture.generator.pathsExhaustive());
    try std.testing.expect(!fixture.generator.faultAnalysisComplete());
}

test "returnsOkRecord reads the parsed return type, not the text" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, expected: bool }{
        .{ .text = "{ ok: boolean; status: number }", .expected = true },
        .{ .text = "{ status: number; ok: boolean; body: string }", .expected = true },
        .{ .text = "{ ok: boolean; headers: { get: (name: string) => string | undefined } }", .expected = true },
        // A nested `ok` is not the record's own.
        .{ .text = "{ meta: { ok: boolean }; status: number }", .expected = false },
        // Optional, or another type, or a function type.
        .{ .text = "{ ok?: boolean; status: number }", .expected = false },
        .{ .text = "{ ok: string; status: number }", .expected = false },
        .{ .text = "{ check: (ok: boolean) => boolean }", .expected = false },
        // A text scan would match this: the text holds `ok: boolean` and the
        // type is a union, not a record.
        .{ .text = "{ ok: boolean } | undefined", .expected = false },
        .{ .text = "string", .expected = false },
        .{ .text = "", .expected = false },
    };
    for (cases) |case| {
        const actual = try returnsOkRecord(allocator, case.text);
        if (actual != case.expected) {
            std.debug.print("returnsOkRecord(\"{s}\"): expected {}, got {}\n", .{ case.text, case.expected, actual });
            return error.WrongOkRecordVerdict;
        }
    }
}

test "fetch, fetchWithRetry, serviceCall, and workflow call fork on ok" {
    const allocator = std.testing.allocator;
    const fetch_source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/data");
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;
    const retry_source =
        \\import { fetchWithRetry } from "zttp:fetch";
        \\function handler(req) {
        \\  const res = fetchWithRetry("https://api.example.com/data");
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;
    const workflow_source =
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  const res = call("worker", {});
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;

    const service_source =
        \\import { serviceCall } from "zttp:service";
        \\function handler(req) {
        \\  const res = serviceCall("users", "GET /api/users", {});
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;

    var fetch_fixture = try generateFixture(allocator, fetch_source);
    defer fetch_fixture.deinit();
    var retry_fixture = try generateFixture(allocator, retry_source);
    defer retry_fixture.deinit();
    var workflow_fixture = try generateFixture(allocator, workflow_source);
    defer workflow_fixture.deinit();
    var service_fixture = try generateFixture(allocator, service_source);
    defer service_fixture.deinit();

    // Each export declares the `ok` record with a severity: two paths, and each
    // carries one I/O constraint on its call.
    for ([_]*PathGeneratorFixture{ &fetch_fixture, &retry_fixture, &workflow_fixture, &service_fixture }) |fixture| {
        const tests = fixture.generator.getTests();
        try std.testing.expectEqual(@as(usize, 2), tests.len);
        for (tests) |test_case| try std.testing.expectEqual(@as(usize, 1), test_case.constraints.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.generator.unseenFailableCalls().len);
    }
}

test "an ok record with no severity, or a Result return, is not forked on ok" {
    const allocator = std.testing.allocator;
    const base = mb.FunctionBinding{
        .name = "probe",
        .arg_count = 0,
        .effect = .write,
        .returns = .object,
        .signature = .{ .params = &.{}, .returns = "{ ok: boolean; status: number }" },
        .failure_severity = .upstream,
    };
    try std.testing.expect(try isOkRecordExport(allocator, &base));

    var no_severity = base;
    no_severity.failure_severity = .none;
    try std.testing.expect(!(try isOkRecordExport(allocator, &no_severity)));

    var result_return = base;
    result_return.returns = .result;
    try std.testing.expect(!(try isOkRecordExport(allocator, &result_return)));
}

test "a failing fetch path stubs a response the replay reads as a 503" {
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const a = fetch("https://api.example.com/a");
        \\  if (!a.ok) return Response.text("a failed", { status: 502 });
        \\  const b = fetch("https://api.example.com/b");
        \\  if (!b.ok) return Response.text("b failed", { status: 504 });
        \\  return Response.text("ok");
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const ok_stub = "\"status\":200";
    const failed_stub = "\"status\":503";
    var seen_502: bool = false;
    var seen_504: bool = false;
    var seen_200: bool = false;
    for (fixture.generator.getTests()) |test_case| {
        switch (test_case.expected_status) {
            502 => {
                // The first fetch fails and the second is never reached.
                try std.testing.expectEqual(@as(usize, 1), test_case.io_stubs.items.len);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[0].result_json, failed_stub) != null);
                seen_502 = true;
            },
            504 => {
                // Only the second fetch fails. Each call has its own stub.
                try std.testing.expectEqual(@as(usize, 2), test_case.io_stubs.items.len);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[0].result_json, ok_stub) != null);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[1].result_json, failed_stub) != null);
                seen_504 = true;
            },
            200 => {
                try std.testing.expectEqual(@as(usize, 2), test_case.io_stubs.items.len);
                for (test_case.io_stubs.items) |stub| {
                    try std.testing.expect(std.mem.indexOf(u8, stub.result_json, ok_stub) != null);
                }
                seen_200 = true;
            },
            else => return error.UnexpectedStatus,
        }
    }
    try std.testing.expect(seen_502 and seen_504 and seen_200);

    // The stub carries the fields the replay reads, and no Result shape.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    try fixture.generator.writeJsonl(&aw.writer);
    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"statusText\":\"Service Unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"headers\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"error\":\"test-error\"") == null);
}

test "a Result export keeps its Result stubs beside a fetch" {
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok) return Response.text("unauthorized", { status: 401 });
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) return Response.text("upstream failed", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;

    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    for (fixture.generator.getTests()) |test_case| {
        switch (test_case.expected_status) {
            401 => try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[0].result_json, "\"ok\":false") != null),
            502 => {
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[0].result_json, "\"ok\":true") != null);
                try std.testing.expect(std.mem.indexOf(u8, test_case.io_stubs.items[1].result_json, "\"status\":503") != null);
            },
            200 => {},
            else => return error.UnexpectedStatus,
        }
    }
}

/// Count the generated tests with `status` whose constraints are exactly
/// `kinds`, in order.
fn countPaths(tests: []const GeneratedTest, status: u16, kinds: []const std.meta.Tag(Constraint)) usize {
    var count: usize = 0;
    for (tests) |t| {
        if (t.expected_status != status or t.constraints.len != kinds.len) continue;
        for (t.constraints, kinds) |c, kind| {
            if (std.meta.activeTag(c) != kind) break;
        } else count += 1;
    }
    return count;
}

test "an && fall-through keeps the case where a later conjunct is false" {
    const allocator = std.testing.allocator;
    // `req.headers["x"] === "y"` yields no constraint. The fall-through is
    // reached when the token check passes, and also when it fails and the
    // header test is false: that second path returns 200 on a failed check.
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok && req.headers["x"] === "y") {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 401, &.{.result_not_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_not_ok}));
    for (tests) |t| {
        const failed = std.mem.indexOf(u8, t.io_stubs.items[0].result_json, "\"ok\":false") != null;
        try std.testing.expectEqual(t.constraints[0] == .result_not_ok, failed);
    }
    try std.testing.expect(fixture.generator.pathsExhaustive());
}

test "an && of two checks enumerates each short-circuit case" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!a.ok && !b.ok) return Response.text("both failed", { status: 401 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    // Both fail; a passes; a passes and b fails; a fails and b passes.
    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 4), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 401, &.{ .result_not_ok, .result_not_ok }));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{ .result_ok, .result_not_ok }));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{ .result_not_ok, .result_ok }));
}

test "an opaque conjunct that comes first still lets a later check fail" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (req.headers["x"] === "y" && !auth.ok) {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    // The header test is false, so the token check is never read, and the
    // token can still be bad: that path answers 200.
    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 401, &.{.result_not_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_not_ok}));
}

test "opaque conjuncts that add no constraint do not repeat a path" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.headers["x"] === "y" && req.headers["z"] === "w") {
        \\    return Response.text("both", { status: 400 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, 2), fixture.generator.getTests().len);
}

test "an else branch is reached by every short-circuit case" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok && req.headers["x"] === "y") {
        \\    return Response.text("unauthorized", { status: 401 });
        \\  } else {
        \\    return Response.text("ok");
        \\  }
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 401, &.{.result_not_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_not_ok}));
}

test "short-circuit enumeration that passes MAX_PATHS reports truncation" {
    const allocator = std.testing.allocator;
    // Each guard doubles the paths that follow it. Twelve guards give far
    // more than MAX_PATHS, so the set must say it is not exhaustive.
    const guard =
        \\  if (!a.ok && req.headers["x"] === "y") return Response.text("no", { status: 401 });
        \\
    ;
    const source = try std.mem.concat(allocator, u8, &.{
        "import { jwtVerify } from \"zttp:auth\";\nfunction handler(req) {\n  const a = jwtVerify(\"t\", \"secret\");\n",
        guard ** 12,
        "  return Response.text(\"ok\");\n}\n",
    });
    defer allocator.free(source);
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    try std.testing.expectEqual(@as(usize, PathGenerator.MAX_PATHS), fixture.generator.getTests().len);
    try std.testing.expect(!fixture.generator.pathsExhaustive());
    try std.testing.expectEqual(PathGenerator.Coverage.truncated, fixture.generator.coverage());
}

test "generate cleans every fatal allocation failure through short-circuit cases" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\export function handler(req) {
        \\  const a = jwtVerify("t1", "secret");
        \\  const b = jwtVerify("t2", "secret");
        \\  if (!a.ok && !b.ok && req.headers["x"] === "y") return Response.text("no", { status: 401 });
        \\  if (!a.ok && req.headers["x"] === "y") {
        \\    return Response.text("no", { status: 403 });
        \\  } else {
        \\    return Response.text("ok");
        \\  }
        \\}
    ;
    var parser = try parser_mod.JsParser.init(allocator, source);
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse return error.HandlerNotFound;

    try std.testing.checkAllAllocationFailures(
        allocator,
        generateWithAllocator,
        .{ ir_view, &atoms, handler_fn },
    );
}

// ---------------------------------------------------------------------------
// Status comparisons on an ok-record call (R4 F3)
// ---------------------------------------------------------------------------

const status_prefix =
    \\import { fetch } from "zttp:fetch";
    \\import { jwtVerify } from "zttp:auth";
    \\
;

/// The `status` that a recorded fetch stub carries.
fn stubStatus(result_json: []const u8) !u16 {
    const key = "\"status\":";
    const at = std.mem.indexOf(u8, result_json, key) orelse return error.NoStatus;
    var end = at + key.len;
    while (end < result_json.len and std.ascii.isDigit(result_json[end])) end += 1;
    return std.fmt.parseInt(u16, result_json[at + key.len .. end], 10);
}

fn hasFailureConstraint(t: GeneratedTest) bool {
    for (t.constraints) |c| {
        if (c.isFailure()) return true;
    }
    return false;
}

test "a status !== 200 test forks the fetch like !res.ok" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status !== 200) return Response.json({ error: "upstream" }, { status: 502 });
        \\  return Response.json({ a: res.body });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 502, &.{.result_not_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    for (tests) |t| {
        const failed = t.expected_status == 502;
        try std.testing.expectEqual(if (failed) @as(u16, 503) else @as(u16, 200), try stubStatus(t.io_stubs.items[0].result_json));
    }
}

test "a status === 200 test forks the fetch with the success branch first" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status === 200) return Response.json({ a: res.body });
        \\  return Response.json({ error: "upstream" }, { status: 502 });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 502, &.{.result_not_ok}));
}

test "a literal on the left and a negation fork the same way" {
    const sources = [_][]const u8{
        status_prefix ++
            \\function handler(req) {
            \\  const res = fetch("https://api.example.com/a");
            \\  if (200 !== res.status) return Response.text("up", { status: 502 });
            \\  return Response.text("ok");
            \\}
        ,
        status_prefix ++
            \\function handler(req) {
            \\  const res = fetch("https://api.example.com/a");
            \\  if (!(res.status === 200)) return Response.text("up", { status: 502 });
            \\  return Response.text("ok");
            \\}
        ,
        status_prefix ++
            \\function handler(req) {
            \\  const res = fetch("https://api.example.com/a");
            \\  if (res.status !== 200.0) return Response.text("up", { status: 502 });
            \\  return Response.text("ok");
            \\}
        ,
    };
    for (sources) |source| {
        var fixture = try generateFixture(std.testing.allocator, source);
        defer fixture.deinit();
        const tests = fixture.generator.getTests();
        try std.testing.expectEqual(@as(usize, 2), tests.len);
        try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 502, &.{.result_not_ok}));
        try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    }
}

test "a status test that is not the complement of ok records no fork and takes its branch" {
    const Row = struct { expr: []const u8, cmp: status_check.Comparison };
    const rows = [_]Row{
        .{ .expr = "res.status >= 300", .cmp = .{ .op = .gte, .literal = 300, .literal_left = false } },
        .{ .expr = "res.status > 299", .cmp = .{ .op = .gt, .literal = 299, .literal_left = false } },
        .{ .expr = "res.status < 300", .cmp = .{ .op = .lt, .literal = 300, .literal_left = false } },
        .{ .expr = "res.status >= 400", .cmp = .{ .op = .gte, .literal = 400, .literal_left = false } },
        .{ .expr = "res.status === 404", .cmp = .{ .op = .eq, .literal = 404, .literal_left = false } },
        .{ .expr = "404 === res.status", .cmp = .{ .op = .eq, .literal = 404, .literal_left = true } },
        .{ .expr = "res.status !== 404", .cmp = .{ .op = .neq, .literal = 404, .literal_left = false } },
        .{ .expr = "!(res.status >= 400)", .cmp = .{ .op = .lt, .literal = 400, .literal_left = false } },
        .{ .expr = "500 <= res.status", .cmp = .{ .op = .lte, .literal = 500, .literal_left = true } },
    };
    for (rows) |row| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{
            status_prefix,
            "function handler(req) {\n  const res = fetch(\"https://api.example.com/a\");\n  if (",
            row.expr,
            ") return Response.text(\"taken\", { status: 502 });\n  return Response.text(\"ok\");\n}\n",
        });
        defer std.testing.allocator.free(source);
        var fixture = try generateFixture(std.testing.allocator, source);
        defer fixture.deinit();

        const tests = fixture.generator.getTests();
        try std.testing.expectEqual(@as(usize, 2), tests.len);
        for (tests) |t| {
            // No coverage constraint: the fetch has no failure path here.
            try std.testing.expect(!hasFailureConstraint(t));
            const status = try stubStatus(t.io_stubs.items[0].result_json);
            // The 502 path is the one where the test is true.
            try std.testing.expectEqual(t.expected_status == 502, status_check.holds(row.cmp, status));
            // The stub's status decides `ok`; it must be a real status.
            try std.testing.expect(status >= 100 and status <= 599);
        }
    }
}

test "a status test before an ok test stubs each branch with a status that takes it" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status === 404) return Response.json({ error: "missing" }, { status: 404 });
        \\  if (!res.ok) return Response.json({ error: "upstream" }, { status: 502 });
        \\  return Response.json({ a: res.body });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    var seen: usize = 0;
    for (tests) |t| {
        const status = try stubStatus(t.io_stubs.items[0].result_json);
        switch (t.expected_status) {
            404 => try std.testing.expectEqual(@as(u16, 404), status),
            502 => {
                try std.testing.expect(status != 404);
                try std.testing.expect(!status_check.isOkStatus(status));
                try std.testing.expect(hasFailureConstraint(t));
            },
            200 => {
                try std.testing.expect(status != 404);
                try std.testing.expect(status_check.isOkStatus(status));
            },
            else => return error.UnexpectedStatus,
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "a status test under a forked status test picks a status in the failed range" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status !== 200) {
        \\    if (res.status === 404) return Response.json({ error: "missing" }, { status: 404 });
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    for (tests) |t| {
        const status = try stubStatus(t.io_stubs.items[0].result_json);
        switch (t.expected_status) {
            404 => try std.testing.expectEqual(@as(u16, 404), status),
            502 => try std.testing.expectEqual(@as(u16, 503), status),
            200 => try std.testing.expectEqual(@as(u16, 200), status),
            else => return error.UnexpectedStatus,
        }
    }
}

test "a status read into a const is not a status test" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  const s = res.status;
        \\  if (s !== 200) return Response.text("up", { status: 502 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    for (tests) |t| {
        try std.testing.expectEqual(@as(usize, 0), t.constraints.len);
        try std.testing.expectEqual(@as(u16, 200), try stubStatus(t.io_stubs.items[0].result_json));
    }
}

test "a status test on a call that is not an ok-record export adds no constraint" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  const plain = { status: 1 };
        \\  if (auth.status !== 200) return Response.text("a", { status: 401 });
        \\  if (plain.status !== 200) return Response.text("b", { status: 402 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    for (fixture.generator.getTests()) |t| {
        try std.testing.expectEqual(@as(usize, 0), t.constraints.len);
    }
}

test "a status test is a conjunct that composes with the short-circuit cases" {
    const source = status_prefix ++
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status !== 200 && req.headers["x"] === "y") {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 502, &.{.result_not_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_ok}));
    try std.testing.expectEqual(@as(usize, 1), countPaths(tests, 200, &.{.result_not_ok}));
}

test "a shadowed res keeps the status fork of the outer fetch" {
    const source = status_prefix ++
        \\import { cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (req.method === "POST") {
        \\    const res = cacheGet("ns", "k") ?? "none";
        \\    return Response.json({ cached: res });
        \\  }
        \\  if (res.status !== 200) return Response.json({ error: "upstream" }, { status: 502 });
        \\  return Response.json({ a: res.body });
        \\}
    ;
    var fixture = try generateFixture(std.testing.allocator, source);
    defer fixture.deinit();

    var forked: usize = 0;
    for (fixture.generator.getTests()) |t| {
        if (t.expected_status == 502) {
            try std.testing.expect(hasFailureConstraint(t));
            forked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), forked);
}

test "the canonical stubs for status 200 and 503 are the ok-record stubs" {
    try std.testing.expectEqualStrings(okRecordStub(true), statusStub(200));
    try std.testing.expectEqualStrings(okRecordStub(false), statusStub(503));
    try std.testing.expectEqual(@as(u16, 404), try stubStatus(statusStub(404)));
    try std.testing.expect(std.mem.indexOf(u8, statusStub(404), "\"statusText\":\"Not Found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, statusStub(302), "\"headers\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, statusStub(599), "\"status\":599") != null);
}

test "a direct req.method comparison constrains the request method" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method === "POST") return Response.text("created", { status: 201 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    for (tests) |t| {
        if (t.expected_status == 201) {
            try std.testing.expectEqualStrings("POST", t.method);
        } else {
            try std.testing.expect(!std.mem.eql(u8, t.method, "POST"));
        }
    }
}

test "a method read into a const constrains the request method" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  const m = req.method;
        \\  if (m === "DELETE") return Response.text("gone", { status: 204 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var saw_delete = false;
    for (fixture.generator.getTests()) |t| {
        if (t.expected_status == 204) {
            try std.testing.expectEqualStrings("DELETE", t.method);
            saw_delete = true;
        }
    }
    try std.testing.expect(saw_delete);
}

test "a failed check behind a method conjunct sends that method on its failure path" {
    const allocator = std.testing.allocator;
    // The 401 needs both a failed token check and a POST. Before the request
    // parameter was recognized, the generated test sent a GET and could not
    // reach the 401.
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const auth = jwtVerify("t", "secret");
        \\  if (!auth.ok && req.method === "POST") {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  return Response.json({ data: "private" });
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    var saw_401 = false;
    for (fixture.generator.getTests()) |t| {
        if (t.expected_status != 401) continue;
        try std.testing.expectEqualStrings("POST", t.method);
        saw_401 = true;
    }
    try std.testing.expect(saw_401);
}

test "a !== method guard sends POST on every path after it and another method on the guard path" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  if (req.method !== "POST") return Response.text("no", { status: 405 });
        \\  const r = jwtVerify("t", "s");
        \\  if (!r.ok) return Response.text("no", { status: 401 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    var seen_405 = false;
    var seen_401 = false;
    var seen_200 = false;
    for (tests) |t| {
        switch (t.expected_status) {
            405 => {
                seen_405 = true;
                try std.testing.expect(!std.mem.eql(u8, t.method, "POST"));
            },
            401 => {
                seen_401 = true;
                try std.testing.expectEqualStrings("POST", t.method);
            },
            200 => {
                seen_200 = true;
                try std.testing.expectEqualStrings("POST", t.method);
            },
            else => return error.UnexpectedStatus,
        }
    }
    try std.testing.expect(seen_405 and seen_401 and seen_200);
}

test "a !== GET guard sends a method other than GET on the guard path" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method !== "GET") return Response.text("no", { status: 405 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    for (tests) |t| {
        if (t.expected_status == 405) {
            try std.testing.expect(!std.mem.eql(u8, t.method, "GET"));
        } else {
            try std.testing.expectEqualStrings("GET", t.method);
        }
    }
}

test "the fall-through of two method tests sends a method that is neither" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method === "GET") return Response.text("a", { status: 201 });
        \\  if (req.method === "POST") return Response.text("b", { status: 202 });
        \\  return Response.text("c", { status: 203 });
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    var seen_third = false;
    for (tests) |t| {
        if (t.expected_status != 203) continue;
        seen_third = true;
        try std.testing.expect(!std.mem.eql(u8, t.method, "GET"));
        try std.testing.expect(!std.mem.eql(u8, t.method, "POST"));
    }
    try std.testing.expect(seen_third);
}

test "a !== url guard sends a url other than the compared one" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.url !== "/") return Response.text("no", { status: 404 });
        \\  return Response.text("ok");
        \\}
    ;
    var fixture = try generateFixture(allocator, source);
    defer fixture.deinit();

    const tests = fixture.generator.getTests();
    try std.testing.expectEqual(@as(usize, 2), tests.len);
    for (tests) |t| {
        if (t.expected_status == 404) {
            try std.testing.expect(!std.mem.eql(u8, t.url, "/"));
        } else {
            try std.testing.expectEqualStrings("/", t.url);
        }
    }
}
