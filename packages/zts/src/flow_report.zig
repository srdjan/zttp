//! Output schema shared by the evaluator, compatibility facade and consumers.
//! This module decides no verdict and constructs no evidence.

const NodeIndex = @import("zts-engine").parser.ir.NodeIndex;
const counterexample = @import("counterexample.zig");
pub const RepairIntent = @import("repair_intent.zig").RepairIntent;

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
    credential_in_egress_body, // {credential} data in fetchSync body or an opaque init
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
    /// Borrowed binding metadata, retained for the checker lifetime.
    guard_func: ?[]const u8 = null,
    guard_line: u32 = 0,
    /// Human label of the sink the validated value safely reached
    /// (static literal); "" for `.never_reached`.
    sink_label: []const u8 = "",
    sink_line: u32 = 0,
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
        .credential_in_egress_body,
        => .no_credential_leakage,
        .unvalidated_input_in_egress => .injection_safe,
    };
}

/// Proven data flow properties for a handler.
pub const FlowProperties = struct {
    /// No {secret} data reaches response bodies or headers, logs, or external
    /// egress. A write to cache or SQL is not a sink. Store readers carry
    /// {unknown}.
    no_secret_leakage: bool = true,
    /// No {credential} data reaches response bodies or headers, logs, or
    /// external egress (URL, headers, or body). The same store exclusion
    /// applies to `no_secret_leakage`.
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
