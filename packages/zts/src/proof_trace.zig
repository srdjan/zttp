//! Proof Trace - per-property reasoning for the proof card.
//!
//! Every handler property the analyzer proves (deterministic, read_only,
//! no_secret_leakage, ...) carries a verdict today but no *reasoning*. This
//! module turns data the analyzer already computed - enumerated paths,
//! fault-coverage counts, flow-checker diagnostics with their counterexample
//! witnesses, and the deterministic-demotion provenance - into a small,
//! legible per-property explanation: how a proof was discharged, or the
//! concrete counterexample that broke it.
//!
//! Pure and freestanding-safe: no filesystem, no clock, no libc. The wasm
//! analyzer build emits the exact same `proofTrace` JSON as `zts check`.

const std = @import("std");
const handler_contract = @import("zts-contracts").handler_contract;
const flow_checker = @import("flow_checker.zig");
const counterexample = @import("counterexample.zig");
const flow_evidence = @import("flow_evidence.zig");
const handler_function_mod = @import("handler_function.zig");
const ir = @import("zts-engine").parser.ir;
const json_utils = @import("zts-base").json_utils;
const spec_discharge = @import("spec_discharge.zig");

const HandlerProperties = handler_contract.HandlerProperties;
const HandlerContract = handler_contract.HandlerContract;

/// The family of reasoning that discharged (or failed to discharge) a property.
pub const ProofKind = enum {
    /// Backed by exhaustive symbolic path enumeration.
    path_enumeration,
    /// Backed by data-flow provenance: a source-to-sink taint trace.
    flow_trace,
    /// Backed by a single-pass structural scan of the IR.
    structural,

    pub fn asString(self: ProofKind) []const u8 {
        return switch (self) {
            .path_enumeration => "path-enumeration",
            .flow_trace => "flow-trace",
            .structural => "structural",
        };
    }
};

pub const CounterexampleKind = enum { offending_node, flow_chain };

/// A concrete demonstration of a failed proof. `offending_node` locates a
/// single source construct; `flow_chain` walks a tainted value from its
/// source call to the sink, plus the request that drives that path.
pub const ProofCounterexample = struct {
    kind: CounterexampleKind,
    /// offending_node: the source location of the breaking construct.
    line: u32 = 0,
    column: u32 = 0,
    snippet: []const u8 = "",
    /// flow_chain: ordered human-readable steps the tainted value travels.
    flow: []const []const u8 = &.{},
    request_method: []const u8 = "",
    request_url: []const u8 = "",
    request_has_auth: bool = false,
    /// The remediation, in one line.
    fix: []const u8 = "",
};

/// The green-proof mirror of `ProofCounterexample`: a representative attack
/// the prover considered and the source -> guard -> sink chain that defeats
/// it. Present only when a flow property `holds`. Turns a passing checkmark
/// into legible evidence ("tried X; the validator caught it"). Derived from a
/// `flow_checker.DefendedPath`, never fabricated.
pub const ResistedCounterexample = struct {
    /// The falsifying input the prover would reject (a canned, property-
    /// appropriate literal from `counterexample.attackInput`).
    attack_input: []const u8,
    /// Ordered human-readable steps: where the input enters, the guard that
    /// clears it (if any), and the sink it safely reaches.
    chain: []const []const u8,
    /// One-line statement of why the attack cannot succeed.
    conclusion: []const u8,
};

/// One property's full reasoning. `summary` is always present and legible;
/// `counterexample` is present only when `holds` is false and a concrete one
/// is derivable. `resisted` is the inverse: present only when a flow property
/// holds and a defended path was captured. Facts are only meaningful for
/// `path_enumeration` traces.
pub const ProofTrace = struct {
    /// snake_case `HandlerProperties` field name.
    property: []const u8,
    holds: bool,
    kind: ProofKind,
    summary: []const u8,
    paths_enumerated: u32 = 0,
    paths_exhaustive: bool = false,
    failable_sites: u32 = 0,
    covered_sites: u32 = 0,
    /// Covered upstream sites whose failure path returns 2xx. Only the
    /// `fault_covered` trace sets it, and the wire format omits it at zero.
    upstream_fallback_sites: u32 = 0,
    counterexample: ?ProofCounterexample = null,
    resisted: ?ResistedCounterexample = null,
};

fn wirePropertyName(name: []const u8) []const u8 {
    if (eql(name, "result_safe")) return "results_safe";
    return name;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Family = enum { structural, flow, path };

fn proofKind(family: Family) ProofKind {
    return switch (family) {
        .structural => .structural,
        .flow => .flow_trace,
        .path => .path_enumeration,
    };
}

/// Static metadata for one handler property: how it is proved, the
/// counterexample tag it witnesses (flow properties only), and the
/// passing / failing one-line explanations. `failing` text for properties
/// that carry a concrete counterexample (deterministic, the flow set,
/// fault_covered) is a fallback only - `buildTrace` overrides it at runtime.
const PropertyInfo = struct {
    name: []const u8,
    family: Family,
    flow_tag: ?counterexample.PropertyTag = null,
    passing: []const u8,
    failing: []const u8,
};

const generic_failing = "The compiler could not discharge this property.";

const property_info = [_]PropertyInfo{
    .{
        .name = "pure",
        .family = .structural,
        .passing = "No virtual-module calls: the handler is a pure function of the request.",
        .failing = "The handler calls virtual modules, so it is not a pure function of the request.",
    },
    .{
        .name = "read_only",
        .family = .structural,
        .passing = "Every virtual-module call is read-classified: no state is mutated.",
        .failing = "A write-classified virtual-module call mutates state.",
    },
    .{
        .name = "stateless",
        .family = .structural,
        .passing = "Read-only and no cache reads: the handler never depends on mutable state.",
        .failing = "The handler reads mutable state (a cache or store), so its result is not stateless.",
    },
    .{
        .name = "deterministic",
        .family = .structural,
        .passing = "No Date.now(), Math.random(), or performance.now() on any enumerated path: every run of a request is identical.",
        .failing = generic_failing,
    },
    .{
        .name = "has_egress",
        .family = .structural,
        .passing = "The handler makes outbound fetch calls.",
        .failing = "The handler makes no outbound fetch calls.",
    },
    .{
        .name = "state_isolated",
        .family = .structural,
        .passing = "No module-scope mutation in the handler body: requests cannot leak state into one another.",
        .failing = "A module-scope variable is mutated inside the handler body.",
    },
    .{
        .name = "retry_safe",
        .family = .path,
        .passing = "The handler is read-only, so a retry cannot repeat a write.",
        .failing = "A retry could repeat a write from this handler.",
    },
    .{
        .name = "idempotent",
        .family = .path,
        .passing = "Deterministic and retry-safe: safe under at-least-once delivery.",
        .failing = "Non-deterministic or not retry-safe: unsafe for at-least-once delivery.",
    },
    .{
        .name = "fault_covered",
        .family = .path,
        .passing = "Every failable I/O site has an explicit failure path.",
        .failing = generic_failing,
    },
    .{
        .name = "result_safe",
        .family = .path,
        .passing = "Every Result.ok access is guarded before the value is used.",
        .failing = "A Result.ok value is used without being guarded first.",
    },
    .{
        .name = "optional_safe",
        .family = .path,
        .passing = "Every optional value is narrowed before use.",
        .failing = "An optional value is used without being narrowed first.",
    },
    .{
        .name = "no_secret_leakage",
        .family = .flow,
        .flow_tag = .no_secret_leakage,
        .passing = "No secret-labelled value reaches a response body, header, or egress call.",
        .failing = generic_failing,
    },
    .{
        .name = "no_credential_leakage",
        .family = .flow,
        .flow_tag = .no_credential_leakage,
        .passing = "No credential-labelled value reaches a response body, header, log, or egress call.",
        .failing = generic_failing,
    },
    .{
        .name = "input_validated",
        .family = .flow,
        .flow_tag = .input_validated,
        .passing = "All user input passes a validation step before any egress call.",
        .failing = "User input reaches an egress call without passing a validation step.",
    },
    .{
        .name = "pii_contained",
        .family = .flow,
        .flow_tag = .pii_contained,
        .passing = "User input never flows to an external egress host.",
        .failing = "User input flows to an external egress host.",
    },
    .{
        .name = "injection_safe",
        .family = .flow,
        .flow_tag = .injection_safe,
        .passing = "No unvalidated user input reaches a SQL or HTML sink.",
        .failing = generic_failing,
    },
    .{
        .name = "canonical",
        .family = .structural,
        .passing = "The handler is in Canonical Normal Form: zero ZTS6xx canonical-profile errors. A non-idiomatic spelling is reported at advisory severity and does not deny this property.",
        .failing = "A non-canonical construct remains; run `zts normalize` to rewrite it.",
    },
    .{
        .name = "post_only",
        .family = .structural,
        .passing = "The handler's AOT route table (routerMatch) is non-empty and every route's method is POST.",
        .failing = "The route table is empty, dynamic, or contains a non-POST method.",
    },
    .{
        .name = "cost_bounded",
        .family = .path,
        .passing = "Worst-path module-call count is bounded by the request.",
        .failing = "A loop over an unsized source makes the handler's I/O cost unbounded.",
    },
};

/// Fallback for a property with no `property_info` row. The comptime check
/// below makes a missing row a compile error, so this is only reached if
/// `collect` is ever called with a name outside `HandlerProperties`.
const default_info = PropertyInfo{
    .name = "",
    .family = .structural,
    .passing = "Proven by the compiler.",
    .failing = generic_failing,
};

// Every `HandlerProperties` field must have a `property_info` row or an exclusion, and every row
// must name a field, so adding a property cannot silently fall through to generic text.
const property_info_names = blk: {
    var names: [property_info.len][]const u8 = undefined;
    for (property_info, 0..) |row, index| names[index] = row.name;
    break :blk names;
};

comptime {
    if (handler_contract.HandlerProperties.namesCoverageProblem(
        "proof_trace.property_info",
        &property_info_names,
        &handler_contract.HandlerProperties.exclusions(&.{"max_io_depth"}, "a number, not a pass or fail property"),
    )) |problem| @compileError(problem);
}

/// One field of a `verify` result's `evidence` object.
pub const ResultField = struct {
    name: []const u8,
    /// The JSON type the wire writes for this field.
    json_type: []const u8,
    /// When the field carries a value rather than `null`.
    presence: []const u8,
};

/// The `verify` input fields a property needs, spec 4.8's "required inputs".
///
/// Uniform across the registry, and that is a fact about the compiler rather
/// than a simplification: one analysis run over one file decides every property
/// at once, so no property can ask for an input another does not. `content` is
/// the optional in-memory override for `file`, not a second source.
/// `agent_protocol` pins this list against the `verify` operation's own
/// `input_fields`, so the two spellings of "what verify takes" cannot drift.
pub const verify_inputs = [_][]const u8{ "file", "properties", "content" };

/// Every grade `verify` can answer a registered property with, most assured
/// first. `unknown_property` is deliberately absent: it is the answer to a name
/// that is not in this registry, so no row here can ever be graded with it.
pub const verify_grades = [_][]const u8{ "proven", "not_proven", "not_decided" };

const contract_prerequisite = "the file analyzes far enough to produce a handler contract; without one every property grades not_decided";

fn prerequisitesFor(comptime kind: ProofKind) []const []const u8 {
    return switch (kind) {
        .structural => &.{contract_prerequisite},
        .path_enumeration => &.{
            contract_prerequisite,
            "symbolic path enumeration ran; the trace reports how many paths it covered and whether that set was exhaustive",
        },
        .flow_trace => &.{
            contract_prerequisite,
            "the flow checker ran; a defended source-to-sink path is what lets a holding property carry `resisted`",
        },
    };
}

const common_result_fields = [_]ResultField{
    .{ .name = "kind", .json_type = "string", .presence = "always; the family of reasoning that actually decided this file" },
    .{ .name = "summary", .json_type = "string|null", .presence = "always present, null only when the trace carried no summary" },
};

fn resultSchemaFor(comptime kind: ProofKind) []const ResultField {
    const counterexample_field: ResultField = switch (kind) {
        .flow_trace => .{
            .name = "counterexample",
            .json_type = "object|null",
            .presence = "when the property does not hold and a flow chain was derived: a flow_chain walking the tainted value from source to sink, plus the request that drives it",
        },
        .structural, .path_enumeration => .{
            .name = "counterexample",
            .json_type = "object|null",
            .presence = "when the property does not hold and a single breaking construct was located: an offending_node with its line, column, snippet, and fix",
        },
    };
    const resisted_field: ResultField = switch (kind) {
        .flow_trace => .{
            .name = "resisted",
            .json_type = "object|null",
            .presence = "when the property holds and a defended path was captured: the attack input, the source-guard-sink chain, and why it cannot succeed",
        },
        .structural, .path_enumeration => .{
            .name = "resisted",
            .json_type = "null",
            .presence = "never; only a flow property captures a defended path",
        },
    };
    return &(common_result_fields ++ [_]ResultField{ counterexample_field, resisted_field });
}

/// One row of the verifier discovery registry: a property a client may ask
/// `verify` about, the family of reasoning that decides it, and - spec 4.8's
/// MUST - what a request has to supply, what has to hold first, which grades
/// the answer can carry, and the shape of the evidence beside it.
///
/// The last four are derived from `kind` rather than written per row. A
/// property's inputs, prerequisites, grades, and evidence shape are properties
/// of how it is proved, not of which property it is, so writing them out
/// fifteen times would be fifteen chances to disagree with the code that emits
/// them.
pub const Verifier = struct {
    id: []const u8,
    kind: ProofKind,
    /// The `verify` input fields this property needs.
    inputs: []const []const u8,
    /// What must hold before the grade can be anything but `not_decided`.
    prerequisites: []const []const u8,
    /// Every grade this property can be answered with, most assured first.
    grades: []const []const u8,
    /// The fields of this property's `evidence` object.
    result_schema: []const ResultField,
};

/// Every property the compiler can decide, in `property_info` order.
///
/// Derived rather than written. `property_info` already carries the closed set
/// and a comptime check ties it to `HandlerProperties`, so a property added to
/// the contract reaches this registry - and therefore `meta.verifiers` and the
/// `verify` operation - without an edit here. Hand-maintaining the list would
/// be a second closed set that could disagree with the first.
///
/// Ids are wire names: `result_safe` is `results_safe` everywhere a client can
/// see it, and publishing the internal spelling would name a property `verify`
/// then refuses to answer about.
pub const verifiers = blk: {
    var rows: [property_info.len]Verifier = undefined;
    for (property_info, 0..) |p, i| {
        const kind = proofKind(p.family);
        rows[i] = .{
            .id = wirePropertyName(p.name),
            .kind = kind,
            .inputs = &verify_inputs,
            .prerequisites = prerequisitesFor(kind),
            .grades = &verify_grades,
            .result_schema = resultSchemaFor(kind),
        };
    }
    const frozen = rows;
    break :blk frozen;
};

/// True when `id` is a property a client may ask about. A `verify` request
/// naming anything else is answered, not rejected: an unknown id is a fact
/// about the request that the response reports per property.
pub fn isVerifier(id: []const u8) bool {
    for (verifiers) |v| {
        if (eql(v.id, id)) return true;
    }
    return false;
}

pub fn verifierKind(id: []const u8) ?ProofKind {
    for (verifiers) |v| {
        if (eql(v.id, id)) return v.kind;
    }
    return null;
}

fn infoFor(name: []const u8) PropertyInfo {
    for (property_info) |p| {
        if (eql(p.name, name)) return p;
    }
    return default_info;
}

/// Where a flow diagnostic's tainted value lands, as a chain endpoint label.
fn sinkLabel(kind: flow_checker.DiagnosticKind) []const u8 {
    return switch (kind) {
        .secret_in_response, .credential_in_response => "the response body",
        .secret_in_log, .credential_in_log => "a log line",
        .secret_in_egress_url, .credential_in_egress_url => "an egress URL",
        .secret_in_egress_body, .credential_in_egress_body => "an egress request body",
        .unvalidated_input_in_egress => "an egress call",
    };
}

/// Build the per-property trace set. All strings are allocated from `arena`;
/// the caller owns the arena and frees the whole set at once.
pub fn collect(
    arena: std.mem.Allocator,
    contract: *const HandlerContract,
    flow_diags: []const flow_checker.Diagnostic,
    defended: []const flow_checker.DefendedPath,
    ir_view: ir.IrView,
    paths_enumerated: u32,
    paths_exhaustive: bool,
) ![]ProofTrace {
    var list: std.ArrayListUnmanaged(ProofTrace) = .empty;
    if (contract.properties) |props| {
        inline for (@typeInfo(HandlerProperties).@"struct".field_names) |field| {
            if (@FieldType(HandlerProperties, field) == bool) {
                const name = field;
                const holds = @field(props, name);
                try list.append(arena, try buildTrace(
                    arena,
                    name,
                    holds,
                    contract,
                    flow_diags,
                    defended,
                    ir_view,
                    paths_enumerated,
                    paths_exhaustive,
                ));
            }
        }
    }
    return list.toOwnedSlice(arena);
}

fn buildTrace(
    arena: std.mem.Allocator,
    name: []const u8,
    holds: bool,
    contract: *const HandlerContract,
    flow_diags: []const flow_checker.Diagnostic,
    defended: []const flow_checker.DefendedPath,
    ir_view: ir.IrView,
    paths_enumerated: u32,
    paths_exhaustive: bool,
) !ProofTrace {
    const info = infoFor(name);
    var trace: ProofTrace = .{
        .property = name,
        .holds = holds,
        .kind = proofKind(info.family),
        .summary = if (holds) info.passing else info.failing,
    };

    switch (info.family) {
        .path => {
            trace.paths_enumerated = paths_enumerated;
            trace.paths_exhaustive = paths_exhaustive;
            if (eql(name, "fault_covered")) {
                if (contract.fault_coverage) |fc| {
                    trace.failable_sites = fc.total_failable;
                    trace.covered_sites = fc.covered;
                    trace.upstream_fallback_sites = fc.upstream_fallback_sites;
                    if (holds and fc.total_failable == 0) {
                        trace.summary = try arena.print("The property holds because the handler has no failable I/O site, across {d} enumerated path(s).", .{paths_enumerated});
                    } else if (holds) {
                        trace.summary = try arena.print("All {d} failable I/O site(s) have an explicit failure path, across {d} enumerated path(s).", .{ fc.total_failable, paths_enumerated });
                        if (fc.upstream_fallback_sites > 0) {
                            trace.summary = try arena.print("{s} {d} upstream site(s) answer a failure with a 2xx status; each is covered and may be an intended fallback.", .{ trace.summary, fc.upstream_fallback_sites });
                        }
                    } else if (fc.total_failable == 0 and !fc.analysis_complete) {
                        trace.summary = "No failable I/O site was counted, but the fault analysis is not complete (the enumerated paths are a summary, or a route dispatch did not resolve), so the property is not proven.";
                    } else if (fc.total_failable == 0 and fc.unseen_calls == 0) {
                        trace.summary = "The contract records no failable I/O site, but it does not claim the property.";
                    } else if (fc.covered == fc.total_failable and fc.warnings == 0 and !fc.analysis_complete) {
                        // Every counted site has a failure path, but the fault
                        // analysis is incomplete: the path set is a summary (a
                        // loop walked once, recursion, a limit), or a route
                        // dispatch did not resolve. A site on a path never
                        // emitted is unseen. `analysis_complete` is the
                        // generator's own answer, so this branch also covers
                        // the unresolved dispatch that `paths_exhaustive` misses.
                        trace.summary = try arena.print("All {d} counted failable I/O site(s) have a failure path, but the fault analysis is not complete (the enumerated paths are a summary, or a route dispatch did not resolve), so the property is not proven.", .{fc.total_failable});
                    } else {
                        trace.summary = try arena.print("{d} of {d} failable I/O site(s) have no explicit failure path.", .{ fc.total_failable -| fc.covered, fc.total_failable });
                    }
                    // A failable call on no enumerated path is neither counted
                    // nor covered, so it blocks the property whatever the
                    // counts say. Name the first such call.
                    if (!holds and fc.unseen_calls > 0) {
                        const counted: []const u8 = if (fc.total_failable == 0)
                            ""
                        else if (fc.covered == fc.total_failable)
                            try arena.print("All {d} counted failable I/O site(s) have a failure path. ", .{fc.total_failable})
                        else
                            try arena.print("{s} ", .{trace.summary});
                        if (contract.property_provenance.causeFor("fault_covered")) |cause| {
                            trace.summary = try arena.print("{s}{d} failable call(s) sit on no enumerated path, so no failure path covers them. The first is `{s}`.", .{ counted, fc.unseen_calls, cause.snippet });
                            trace.counterexample = .{
                                .kind = .offending_node,
                                .line = cause.line,
                                .column = cause.column,
                                .snippet = cause.snippet,
                                .fix = "bind the call to a const in the handler body and branch on its failure before the value is used.",
                            };
                        } else {
                            trace.summary = try arena.print("{s}{d} failable call(s) sit on no enumerated path, so no failure path covers them.", .{ counted, fc.unseen_calls });
                        }
                    }
                }
            } else if (!holds and eql(name, "cost_bounded")) {
                if (contract.cost_envelope) |envelope| {
                    if (envelope.total == .unbounded) {
                        const source = envelope.total.unbounded;
                        trace.summary = try arena.print("Cost is unbounded because {s} cannot be assigned a finite module-call bound.", .{source.desc});
                        trace.counterexample = .{
                            .kind = .offending_node,
                            .line = source.line,
                            .column = source.column,
                            .snippet = source.desc,
                            .fix = spec_discharge.suggestionFor("cost_bounded") orelse "",
                        };
                    }
                }
            } else if (holds and paths_enumerated > 0) {
                trace.summary = try arena.print("{s} Checked across {d} enumerated path(s){s}.", .{
                    info.passing,
                    paths_enumerated,
                    if (paths_exhaustive) " (exhaustive)" else "",
                });
            }
        },
        .structural => {
            if (!holds and eql(name, "deterministic")) {
                if (contract.property_provenance.causeFor("deterministic")) |cause| {
                    trace.summary = try arena.print("{s} reads a clock or RNG: two runs of the same request can differ.", .{cause.snippet});
                    trace.counterexample = .{
                        .kind = .offending_node,
                        .line = cause.line,
                        .column = cause.column,
                        .snippet = cause.snippet,
                        .fix = "remove the varying read, or take the value from the request.",
                    };
                }
            }
        },
        .flow => {
            if (info.flow_tag) |tag| {
                if (!holds) {
                    if (findFlowDiag(flow_diags, tag)) |diag| {
                        trace.summary = diag.message;
                        trace.counterexample = try flowCounterexample(arena, diag, tag, ir_view);
                    }
                } else if (findDefended(defended, tag)) |dp| {
                    trace.resisted = try resistedFor(arena, dp, tag);
                }
            }
        },
    }
    if (!contract.effect_analysis_complete and holds and eql(name, "has_egress")) {
        trace.summary = "Effect analysis is incomplete. Conservative egress does not claim an observed outbound call.";
    }
    return trace;
}

fn findFlowDiag(
    flow_diags: []const flow_checker.Diagnostic,
    tag: counterexample.PropertyTag,
) ?flow_checker.Diagnostic {
    var first: ?flow_checker.Diagnostic = null;
    for (flow_diags) |diag| {
        const diag_tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (diag_tag == tag) {
            if (diag.witness != null) return diag;
            if (first == null) first = diag;
        }
    }
    return first;
}

fn findDefended(
    defended: []const flow_checker.DefendedPath,
    tag: counterexample.PropertyTag,
) ?flow_checker.DefendedPath {
    for (defended) |d| {
        if (d.property == tag) return d;
    }
    return null;
}

/// The label family a tag tracks, for the chain's source phrasing.
fn sourcePhrase(tag: counterexample.PropertyTag) []const u8 {
    return switch (tag) {
        .no_secret_leakage => "a secret-labelled value",
        .no_credential_leakage => "a credential-labelled value",
        .input_validated, .pii_contained, .injection_safe => "user input",
    };
}

/// Build the green-proof evidence from a defended path. Soundness: a
/// `.validated` path always carries a named guard (the flow checker only
/// records one when the validator binding is recovered), so the chain never
/// invents a guard; a `.never_reached` path states containment with no guard.
fn resistedFor(
    arena: std.mem.Allocator,
    dp: flow_checker.DefendedPath,
    tag: counterexample.PropertyTag,
) !?ResistedCounterexample {
    const source = sourcePhrase(tag);
    var chain: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (dp.safe_form) {
        .validated => {
            const guard = dp.guard_func orelse return null;
            try chain.append(arena, try arena.print("{s} enters the handler", .{source}));
            try chain.append(arena, try arena.print("validated by {s}() at L{d}", .{ guard, dp.guard_line }));
            try chain.append(arena, try arena.print("reaches {s} at L{d}, already cleared", .{ dp.sink_label, dp.sink_line }));
            return .{
                .attack_input = counterexample.attackInput(tag),
                .chain = try chain.toOwnedSlice(arena),
                .conclusion = "the request data reaches this sink with its required defense; the property holds.",
            };
        },
        .never_reached => {
            try chain.append(arena, try arena.print("{s} is read", .{source}));
            try chain.append(arena, switch (tag) {
                .no_secret_leakage, .no_credential_leakage => "it never reaches a response, log, or egress sink",
                .input_validated, .pii_contained => "it never reaches an external egress sink",
                .injection_safe => "it never reaches an HTML response or governed external egress sink",
            });
            return .{
                .attack_input = counterexample.attackInput(tag),
                .chain = try chain.toOwnedSlice(arena),
                .conclusion = "no sink governed by this property is reachable from the labelled source.",
            };
        },
    }
}

fn flowCounterexample(
    arena: std.mem.Allocator,
    diag: flow_checker.Diagnostic,
    tag: counterexample.PropertyTag,
    ir_view: ir.IrView,
) !?ProofCounterexample {
    const capsule = diag.witness orelse return null;
    const loc = ir_view.getLoc(diag.node);
    const constraints = capsule.path_constraints;
    const io_calls = capsule.io_calls;
    const witness = try counterexample.solve(arena, .{
        .property = tag,
        .origin = .{ .line = if (loc) |l| l.line else 0, .column = if (loc) |l| l.column else 0 },
        .sink = .{ .line = if (loc) |l| l.line else 0, .column = if (loc) |l| l.column else 0 },
        .summary = diag.message,
        .constraints = constraints,
        .io_calls = io_calls,
    });
    if (!try flow_evidence.candidateSatisfies(arena, constraints, witness)) return null;

    // Build the source-to-sink chain from the I/O calls observed on the
    // path, ending at the sink the diagnostic flagged.
    var flow: std.ArrayListUnmanaged([]const u8) = .empty;
    for (io_calls) |call| {
        try flow.append(arena, try arena.print("{s}() call", .{call.func}));
    }
    try flow.append(arena, sinkLabel(diag.kind));

    return .{
        .kind = .flow_chain,
        .line = if (loc) |l| l.line else 0,
        .column = if (loc) |l| l.column else 0,
        .flow = try flow.toOwnedSlice(arena),
        .request_method = witness.request.method,
        .request_url = witness.request.url,
        .request_has_auth = witness.request.has_auth_header,
        .fix = diag.help orelse "validate or drop the untrusted value before it reaches the sink.",
    };
}

// ---------------------------------------------------------------------------
// JSON wire format
// ---------------------------------------------------------------------------

/// Emit the `proofTrace` object: one entry per UI-facing snake_case property
/// key. Additive sibling of `proof.properties`; existing parsers that read the
/// booleans are unaffected.
pub fn writeJson(writer: anytype, traces: []const ProofTrace) !void {
    try writer.writeByte('{');
    for (traces, 0..) |trace, i| {
        if (i > 0) try writer.writeByte(',');
        try json_utils.writeJsonString(writer, wirePropertyName(trace.property));
        try writer.writeAll(":{\"holds\":");
        try writer.writeAll(if (trace.holds) "true" else "false");
        try writer.writeAll(",\"kind\":");
        try json_utils.writeJsonString(writer, trace.kind.asString());
        try writer.writeAll(",\"summary\":");
        try json_utils.writeJsonString(writer, trace.summary);

        if (trace.kind == .path_enumeration) {
            try writer.print(
                ",\"facts\":{{\"pathsEnumerated\":{d},\"pathsExhaustive\":{},\"failableSites\":{d},\"coveredSites\":{d}",
                .{ trace.paths_enumerated, trace.paths_exhaustive, trace.failable_sites, trace.covered_sites },
            );
            if (trace.upstream_fallback_sites > 0) {
                // A fact for the fault-coverage trace only, and only when it is
                // not zero, so a trace without a fallback keeps its wire bytes.
                try writer.print(",\"upstreamFallbackSites\":{d}", .{trace.upstream_fallback_sites});
            }
            try writer.writeAll("}");
        }

        if (trace.counterexample) |cx| {
            try writer.writeAll(",\"counterexample\":");
            try writeCounterexample(writer, cx);
        }
        if (trace.resisted) |r| {
            try writer.writeAll(",\"resisted\":{\"attackInput\":");
            try json_utils.writeJsonString(writer, r.attack_input);
            try writer.writeAll(",\"chain\":[");
            for (r.chain, 0..) |step, j| {
                if (j > 0) try writer.writeByte(',');
                try json_utils.writeJsonString(writer, step);
            }
            try writer.writeAll("],\"conclusion\":");
            try json_utils.writeJsonString(writer, r.conclusion);
            try writer.writeByte('}');
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

fn writeCounterexample(writer: anytype, cx: ProofCounterexample) !void {
    switch (cx.kind) {
        .offending_node => {
            try writer.print(
                "{{\"kind\":\"offending-node\",\"location\":{{\"line\":{d},\"column\":{d}}},\"snippet\":",
                .{ cx.line, cx.column },
            );
            try json_utils.writeJsonString(writer, cx.snippet);
            try writer.writeAll(",\"fix\":");
            try json_utils.writeJsonString(writer, cx.fix);
            try writer.writeByte('}');
        },
        .flow_chain => {
            try writer.print(
                "{{\"kind\":\"flow-chain\",\"sink\":{{\"line\":{d},\"column\":{d}}},\"flow\":[",
                .{ cx.line, cx.column },
            );
            for (cx.flow, 0..) |step, i| {
                if (i > 0) try writer.writeByte(',');
                try json_utils.writeJsonString(writer, step);
            }
            try writer.writeAll("],\"request\":{\"method\":");
            try json_utils.writeJsonString(writer, cx.request_method);
            try writer.writeAll(",\"url\":");
            try json_utils.writeJsonString(writer, cx.request_url);
            try writer.print(",\"hasAuthHeader\":{}}}", .{cx.request_has_auth});
            try writer.writeAll(",\"fix\":");
            try json_utils.writeJsonString(writer, cx.fix);
            try writer.writeByte('}');
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "infoFor classifies every property family" {
    try testing.expectEqual(Family.flow, infoFor("no_secret_leakage").family);
    try testing.expectEqual(Family.flow, infoFor("injection_safe").family);
    try testing.expectEqual(Family.path, infoFor("fault_covered").family);
    try testing.expectEqual(Family.path, infoFor("retry_safe").family);
    try testing.expectEqual(Family.structural, infoFor("deterministic").family);
    try testing.expectEqual(Family.structural, infoFor("read_only").family);
}

test "writeJson emits a path-enumeration trace with facts" {
    const traces = [_]ProofTrace{.{
        .property = "fault_covered",
        .holds = true,
        .kind = .path_enumeration,
        .summary = "ok",
        .paths_enumerated = 5,
        .paths_exhaustive = true,
        .failable_sites = 3,
        .covered_sites = 3,
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"fault_covered\":{") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"path-enumeration\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"pathsEnumerated\":5") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"coveredSites\":3") != null);
}

test "writeJson maps result_safe to results_safe UI key" {
    const traces = [_]ProofTrace{.{
        .property = "result_safe",
        .holds = false,
        .kind = .path_enumeration,
        .summary = "A Result.ok value is used without being guarded first.",
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"results_safe\":{") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"result_safe\":{") == null);
}

test "an incomplete fault analysis is named even when the enumerated paths are exhaustive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var contract = handler_contract.emptyContract(try testing.allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(testing.allocator);
    contract.properties = .{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = true,
        .has_egress = true,
        .fault_covered = false,
    };
    // Every counted site is covered and the path set is exhaustive, yet the
    // generator reported the analysis incomplete (an unresolved route dispatch).
    contract.fault_coverage = .{
        .total_failable = 2,
        .covered = 2,
        .warnings = 0,
        .analysis_complete = false,
    };

    const traces = try collect(arena.allocator(), &contract, &.{}, &.{}, undefined, 4, true);
    var summary: ?[]const u8 = null;
    for (traces) |trace| {
        if (std.mem.eql(u8, trace.property, "fault_covered")) summary = trace.summary;
    }
    const text = summary orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, text, "fault analysis is not complete") != null);
    try testing.expect(std.mem.indexOf(u8, text, "route dispatch did not resolve") != null);
}

test "a handler with no failable site says the property holds because there is none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var contract = handler_contract.emptyContract(try testing.allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(testing.allocator);
    contract.properties = .{
        .pure = true,
        .read_only = true,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
        .fault_covered = true,
    };
    contract.fault_coverage = .{
        .total_failable = 0,
        .covered = 0,
        .warnings = 0,
        .analysis_complete = true,
    };

    const traces = try collect(arena.allocator(), &contract, &.{}, &.{}, undefined, 2, true);
    var summary: ?[]const u8 = null;
    for (traces) |trace| {
        if (std.mem.eql(u8, trace.property, "fault_covered")) summary = trace.summary;
    }
    const text = summary orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, text, "has no failable I/O site") != null);
    try testing.expect(std.mem.indexOf(u8, text, "All 0") == null);
}

test "incomplete effect analysis does not claim observed or absent calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var contract = handler_contract.emptyContract(try testing.allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(testing.allocator);
    contract.effect_analysis_complete = false;
    contract.properties = .{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = false,
        .has_egress = true,
    };

    const traces = try collect(arena.allocator(), &contract, &.{}, &.{}, undefined, 0, false);
    var egress_summary: ?[]const u8 = null;
    for (traces) |trace| {
        if (std.mem.eql(u8, trace.property, "has_egress")) egress_summary = trace.summary;
    }
    const summary = egress_summary orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, summary, "incomplete") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "observed outbound call") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "makes outbound") == null);
    try testing.expect(std.mem.indexOf(u8, summary, "no outbound") == null);
}

test "unbounded cost trace carries loop counterexample and lever" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var contract = handler_contract.emptyContract(try testing.allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(testing.allocator);
    contract.properties = .{
        .pure = true,
        .read_only = true,
        .stateless = true,
        .retry_safe = true,
        .deterministic = true,
        .has_egress = false,
        .cost_bounded = false,
    };
    contract.cost_envelope = .{
        .total = .{ .unbounded = .{
            .line = 17,
            .column = 5,
            .desc = try testing.allocator.dupe(u8, "for...of over `ids`"),
        } },
    };

    const traces = try collect(
        arena.allocator(),
        &contract,
        &.{},
        &.{},
        undefined,
        3,
        true,
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"cost_bounded\":{") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"offending-node\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"line\":17") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "for...of over `ids`") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "LIMIT") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "maxItems") != null);
}

test "writeJson emits an offending-node counterexample" {
    const traces = [_]ProofTrace{.{
        .property = "deterministic",
        .holds = false,
        .kind = .structural,
        .summary = "Date.now() reads a clock",
        .counterexample = .{
            .kind = .offending_node,
            .line = 14,
            .column = 9,
            .snippet = "Date.now()",
            .fix = "remove the varying read",
        },
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"offending-node\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"line\":14") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"snippet\":\"Date.now()\"") != null);
}

test "writeJson emits a resisted counterexample for a passing flow property" {
    const steps = [_][]const u8{
        "user input enters the handler",
        "validated by schemaCompile() at L7",
        "reaches an egress request body at L12, already cleared",
    };
    const traces = [_]ProofTrace{.{
        .property = "injection_safe",
        .holds = true,
        .kind = .flow_trace,
        .summary = "No unvalidated user input reaches a SQL or HTML sink.",
        .resisted = .{
            .attack_input = "1; DROP TABLE users--",
            .chain = &steps,
            .conclusion = "the validator clears the taint before the sink; the attack input cannot reach it unescaped.",
        },
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"resisted\":{") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"attackInput\":\"1; DROP TABLE users--\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"validated by schemaCompile() at L7\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"conclusion\":") != null);
    // holds==true, so no failing counterexample is present.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"counterexample\"") == null);
}

test "writeJson emits a flow-chain counterexample" {
    const steps = [_][]const u8{ "env() call", "the response body" };
    const traces = [_]ProofTrace{.{
        .property = "no_secret_leakage",
        .holds = false,
        .kind = .flow_trace,
        .summary = "SECRET flows into the response",
        .counterexample = .{
            .kind = .flow_chain,
            .line = 7,
            .column = 12,
            .flow = &steps,
            .request_method = "POST",
            .request_url = "/leak",
            .request_has_auth = false,
            .fix = "do not return env values",
        },
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &traces);
    buf = aw.toArrayList();

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"flow-chain\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"flow\":[\"env() call\",\"the response body\"]") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"method\":\"POST\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"hasAuthHeader\":false") != null);
}

test "the verifier registry covers every contract property" {
    // The registry is derived from `property_info`, which a comptime check
    // already ties to `HandlerProperties`. This asserts the derivation did not
    // lose a row, and that the ids published are the wire spellings - a client
    // that asks about `result_safe` is asking about a name the wire never uses.
    try std.testing.expectEqual(property_info.len, verifiers.len);
    try std.testing.expect(isVerifier("results_safe"));
    try std.testing.expect(!isVerifier("result_safe"));
    try std.testing.expect(!isVerifier("not_a_property"));

    try std.testing.expectEqual(ProofKind.flow_trace, verifierKind("no_secret_leakage").?);
    try std.testing.expectEqual(ProofKind.path_enumeration, verifierKind("fault_covered").?);
    try std.testing.expectEqual(ProofKind.structural, verifierKind("pure").?);
}

test "writeJson reports upstream fallback sites inside the facts, and only when present" {
    const with_fallback = [_]ProofTrace{.{
        .property = "fault_covered",
        .holds = true,
        .kind = .path_enumeration,
        .summary = "ok",
        .paths_enumerated = 2,
        .paths_exhaustive = true,
        .failable_sites = 1,
        .covered_sites = 1,
        .upstream_fallback_sites = 1,
    }};
    var without_fallback = with_fallback;
    without_fallback[0].upstream_fallback_sites = 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw.writer, &with_fallback);
    buf = aw.toArrayList();
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"coveredSites\":1,\"upstreamFallbackSites\":1}") != null);

    buf.clearRetainingCapacity();
    var aw2: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    try writeJson(&aw2.writer, &without_fallback);
    buf = aw2.toArrayList();
    try testing.expect(std.mem.indexOf(u8, buf.items, "upstreamFallbackSites") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"coveredSites\":1}") != null);
}

fn checkPublicFlowTrace(source: []const u8, tag: counterexample.PropertyTag, constructive: bool, auth: bool) !void {
    const allocator = testing.allocator;
    const engine = @import("zts-engine");
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try engine.parser.JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler = handler_function_mod.findHandlerFunction(view, root) orelse return error.MissingHandler;
    var checker = flow_checker.FlowChecker.init(allocator, view, &atoms);
    defer checker.deinit();
    checker.scopes = &parser.scopes;
    _ = try checker.check(handler);
    const properties = checker.getProperties();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var contract = handler_contract.emptyContract(try arena.allocator().dupe(u8, "handler.ts"));
    contract.properties = .{ .pure = false, .read_only = false, .stateless = false, .retry_safe = false, .deterministic = properties.deterministic, .has_egress = false, .no_secret_leakage = properties.no_secret_leakage, .no_credential_leakage = properties.no_credential_leakage, .input_validated = properties.input_validated, .injection_safe = properties.injection_safe, .pii_contained = properties.pii_contained };
    const traces = try collect(arena.allocator(), &contract, checker.getDiagnostics(), checker.getDefendedPaths(), view, 0, false);
    for (traces) |trace| {
        if (!std.mem.eql(u8, trace.property, @tagName(tag))) continue;
        try testing.expect(!trace.holds);
        try testing.expect(trace.summary.len > 0);
        try testing.expectEqual(constructive, trace.counterexample != null);
        if (trace.counterexample) |example| try testing.expectEqual(auth, example.request_has_auth);
        return;
    }
    return error.MissingTrace;
}

test "public flow traces retain refusal without inventing absent witness evidence" {
    try checkPublicFlowTrace("import { env } from 'zttp:env'; function handler(req) { const items = [env('API_TOKEN'), 'public']; return Response.text(items[1]); }", .no_secret_leakage, false, false);
    try checkPublicFlowTrace("import { env } from 'zttp:env'; function handler(req) { return Response.text(env('API_TOKEN')); }", .no_secret_leakage, true, false);
    try checkPublicFlowTrace("function handler(req) { return Response.text(req.headers.authorization); }", .no_credential_leakage, true, true);
}

test "public flow traces select supported evidence after an unsupported sink" {
    try checkPublicFlowTrace("import { env } from 'zttp:env'; function handler(req) { const items = [env('API_TOKEN'), 'public']; console.log(items[1]); return Response.text(env('API_TOKEN')); }", .no_secret_leakage, true, false);
}

test "contradictory supplied capsules never become public counterexamples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const constraints = [_]counterexample.WitnessConstraint{ .{ .req_method = "GET" }, .{ .req_method = "POST" } };
    const diagnostic: flow_checker.Diagnostic = .{ .kind = .secret_in_response, .severity = .err, .node = 0, .message = "secret flow", .help = null, .witness = .{ .path_constraints = &constraints, .io_calls = &.{} } };
    const engine = @import("zts-engine");
    var parser = try engine.parser.JsParser.init(testing.allocator, "function handler(req) { return 'public'; }");
    defer parser.deinit();
    _ = try parser.parse();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try testing.expect((try flowCounterexample(arena.allocator(), diagnostic, .no_secret_leakage, view)) == null);
}

test "contained request evidence names only the property governed sinks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]counterexample.PropertyTag{ .input_validated, .pii_contained, .injection_safe }) |tag| {
        const resisted = (try resistedFor(arena.allocator(), .{ .property = tag, .safe_form = .never_reached }, tag)).?;
        try testing.expect(std.mem.indexOf(u8, resisted.chain[1], "external egress") != null);
        try testing.expect(std.mem.indexOf(u8, resisted.chain[1], "never reaches a response, log") == null);
    }
    try testing.expect((try resistedFor(arena.allocator(), .{ .property = .injection_safe, .safe_form = .validated }, .injection_safe)) == null);
}
