//! What the consumer established, and where it stopped.
//!
//! The states are separate because conflating them is the failure this package
//! exists to prevent: a matching hash is not a checked proof, a checked proof is
//! not an accepted policy, an accepted policy is not a runnable deployment, and
//! a valid signature is none of those.

const std = @import("std");
const proof_system = @import("proof_system.zig");

/// How far semantic acceptance got. Ordered: each state implies the ones before
/// it, and the kernel never reports a state it did not reach.
pub const SemanticState = enum(u8) {
    /// The certificate decoded within limits. Nothing about the artifact is
    /// established yet.
    parsed = 1,
    /// Every executable-graph member the consumer recomputed matches the
    /// certificate, and the root over them matches too.
    integrity_verified = 2,
    /// The reconstructed obligations equal the supplied ones and every
    /// obligation carries evidence the consumer checked or explicitly graded.
    proof_checked = 3,
    /// The checked result meets the consumer's requirements, epochs, and
    /// minimum grades.
    policy_accepted = 4,

    pub fn name(self: SemanticState) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
    }
};

/// Provenance is orthogonal to the semantic chain. It never raises a semantic
/// state and never lowers one.
pub const ProvenanceState = enum(u8) {
    /// The artifact carries no signature. `--no-attest` lands here, and it is
    /// not a rejection.
    absent = 1,
    /// A signature is present and the consumer did not check it.
    unchecked = 2,
    /// The signature validates against the key it carries.
    signature_verified = 3,
    /// The signature validates and its key is one the consumer pinned.
    trusted_origin = 4,

    pub fn name(self: ProvenanceState) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
    }
};

/// The strength of one edge in the theorem chain. Lower is stronger. The
/// certificate's overall grade is the weakest edge it actually used.
///
/// `solver_assumed` sits between `translation_validated` and `tested` because a
/// discharged solver query covers every input under the solver's soundness,
/// while a test covers the inputs someone wrote down.
pub const AssuranceGrade = enum(u8) {
    proved = 0,
    translation_validated = 1,
    solver_assumed = 2,
    tested = 3,
    trusted = 4,

    /// The weaker of two grades. This is the only way a grade is combined.
    pub fn weakest(a: AssuranceGrade, b: AssuranceGrade) AssuranceGrade {
        @setRuntimeSafety(true);
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }

    pub fn atLeastAsStrongAs(self: AssuranceGrade, floor: AssuranceGrade) bool {
        @setRuntimeSafety(true);
        return @backingInt(self) <= @backingInt(floor);
    }

    /// Wire encoding is one-based so that zero can mean "no grade stated".
    pub fn fromWire(value: u8) ?AssuranceGrade {
        @setRuntimeSafety(true);
        return switch (value) {
            1 => .proved,
            2 => .translation_validated,
            3 => .solver_assumed,
            4 => .tested,
            5 => .trusted,
            else => null,
        };
    }

    pub fn toWire(self: AssuranceGrade) u8 {
        @setRuntimeSafety(true);
        return @as(u8, @backingInt(self)) + 1;
    }

    pub fn name(self: AssuranceGrade) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
    }
};

/// Where a rejection happened. Named so a diagnostic can say which consumer
/// stage refused, not only that something refused.
pub const Stage = enum(u8) {
    decode = 1,
    limits = 2,
    proof_system_identity = 3,
    artifact_binding = 4,
    obligation_reconstruction = 5,
    evidence_check = 6,
    translation_check = 7,
    solver = 8,
    policy = 9,
    /// Residual guard reconstruction and coverage.
    guard_coverage = 10,
    // Stage ordinals 11 through 13 are retired.

    pub fn name(self: Stage) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
    }
};

/// Stable rejection codes. The numeric value is the contract; the spelling is
/// the diagnostic. Never renumber a member, and never reuse a retired one.
///
/// Every member here is a code some path in this package constructs. A code the
/// kernel advertises and never produces reads, to anyone auditing the rejection
/// surface, as a check that exists; four such were removed rather than left in
/// as placeholders, and their numbers are retired.
pub const ReasonCode = enum(u16) {
    // decode
    certificate_too_large = 1001,
    truncated_input = 1002,
    bad_magic = 1003,
    unsupported_schema_version = 1004,
    unknown_section_tag = 1005,
    duplicate_section = 1006,
    missing_required_section = 1007,
    trailing_data = 1008,
    section_too_large = 1009,
    section_length_mismatch = 1010,
    count_exceeds_limit = 1011,
    unknown_enum_member = 1012,
    section_not_canonically_ordered = 1014,
    reserved_field_nonzero = 1013,

    // limits
    work_budget_exhausted = 1101,
    proof_depth_exceeded = 1102,

    // proof-system identity
    unsupported_proof_system = 1201,
    unsupported_semantics_epoch = 1202,

    // artifact binding
    executable_root_mismatch = 1301,
    graph_member_missing = 1302,
    graph_member_extra = 1303,
    graph_member_digest_mismatch = 1304,
    graph_member_out_of_order = 1305,
    graph_member_duplicate = 1306,
    zero_commitment = 1307,
    proof_ir_digest_mismatch = 1308,
    proof_certificate_digest_mismatch = 1309,

    // obligation reconstruction
    obligation_missing = 1401,
    obligation_extra = 1402,
    obligation_duplicate = 1403,
    obligation_out_of_order = 1404,
    obligation_subject_unknown = 1405,

    // evidence
    obligation_without_evidence = 1501,
    rule_premise_unmet = 1504,
    proof_node_cycle = 1505,
    proof_node_unknown = 1506,
    fabricated_property = 1507,
    trusted_edge_undeclared = 1508,
    evidence_edge_invalid = 1509,
    proof_node_parent_mismatch = 1510,
    result_read_unguarded = 1511,
    result_escape_present = 1512,
    result_binding_redefined = 1513,
    result_guard_malformed = 1514,
    result_binding_limit = 1515,

    // translation
    witness_missing = 1601,
    witness_range_overlaps = 1602,
    witness_range_out_of_bounds = 1603,
    jump_target_mismatch = 1604,
    rewrite_unknown = 1605,
    rewrite_span_mismatch = 1606,

    // solver
    solver_edge_not_permitted = 1701,
    solver_inconclusive = 1703,
    solver_query_too_large = 1704,
    solver_query_mismatch = 1705,

    // policy
    required_property_not_established = 1801,
    grade_below_floor = 1802,
    development_artifact_refused = 1803,
    proof_system_not_selected = 1804,
    policy_requires_nothing = 1805,

    // residual guards
    guard_member_missing = 1901,
    guard_member_extra = 1902,
    guard_member_duplicate = 1903,
    guard_member_out_of_order = 1904,
    guard_kind_mismatch = 1905,
    guard_normalization_mismatch = 1906,
    guard_sink_mismatch = 1907,
    guard_section_mismatch = 1908,
    guard_impl_identity_mismatch = 1909,
    guard_operation_unknown = 1910,
    guard_category_not_configured = 1911,
    residual_plan_digest_mismatch = 1912,
    runtime_policy_missing = 1914,
    runtime_policy_undecodable = 1915,
    guard_family_disabled = 1916,
    semantics_epoch_not_selected = 1806,

    // Reason ordinals 2001 through 2017, 2101 through 2103, and 2201 through
    // 2203 are retired.

    pub fn text(self: ReasonCode) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
    }
};

/// What a rejection is about.
pub const Subject = union(enum) {
    none,
    section: u16,
    graph_member: GraphMemberRef,
    obligation: ObligationRef,
    ir_node: u32,
    code_offset: u32,
    property: proof_system.Property,
    rule: proof_system.Rule,

    pub const GraphMemberRef = struct { kind: u16, ordinal: u32 };
    pub const ObligationRef = struct { property: proof_system.Property, subject_id: u32 };
};

/// An identity a rejection can name on both sides. A digest and a scalar are
/// the only two shapes the kernel compares.
pub const Identity = union(enum) {
    digest: [32]u8,
    scalar: u64,
};

/// What the consumer established about guarded operations.
pub const GuardVerdicts = struct {
    /// Guarded call sites the consumer reconstructed from the proof IR.
    required: u32 = 0,
    /// Of those, how many the certificate covered with a matching obligation
    /// whose policy category is configured.
    covered: u32 = 0,
    /// Which guard kinds appear, as one bit per kind.
    kinds: u8 = 0,

    /// Every reconstructed guard has a matching covered obligation. Vacuously
    /// true for a handler with none, which is the honest answer: it has nothing
    /// to guard.
    pub fn ready(self: GuardVerdicts) bool {
        @setRuntimeSafety(true);
        return self.required == self.covered;
    }
};

pub const Rejection = struct {
    stage: Stage,
    code: ReasonCode,
    subject: Subject = .none,
    expected: ?Identity = null,
    actual: ?Identity = null,
    /// Whether rebuilding and recertifying the same source can resolve this.
    /// A version cutover can; a fabricated property cannot.
    recertifiable: bool,
};

pub const PropertyVerdicts = struct {
    const count = @typeInfo(proof_system.Property).@"enum".field_names.len;
    pub const Entry = union(enum) {
        none,
        graded: AssuranceGrade,
        accepted: AssuranceGrade,
    };
    entries: [count]Entry = @as([count]Entry, @splat(.none)),

    fn slot(property: proof_system.Property) usize {
        @setRuntimeSafety(true);
        return @backingInt(property) - 1;
    }

    pub fn gradeFor(self: PropertyVerdicts, property: proof_system.Property) ?AssuranceGrade {
        @setRuntimeSafety(true);
        return switch (self.entries[slot(property)]) {
            .none => null,
            .graded, .accepted => |grade| grade,
        };
    }

    pub fn accepted(self: PropertyVerdicts, property: proof_system.Property) bool {
        @setRuntimeSafety(true);
        return self.entries[slot(property)] == .accepted;
    }

    pub fn recordGrade(self: *PropertyVerdicts, property: proof_system.Property, grade: AssuranceGrade) void {
        @setRuntimeSafety(true);
        self.entries[slot(property)] = switch (self.entries[slot(property)]) {
            .accepted => .{ .accepted = grade },
            .none, .graded => .{ .graded = grade },
        };
    }

    pub fn accept(self: *PropertyVerdicts, property: proof_system.Property, grade: AssuranceGrade) void {
        @setRuntimeSafety(true);
        self.entries[slot(property)] = .{ .accepted = grade };
    }
};

/// A refusal can stop at one of these three established stages.
pub const Reached = union(enum) {
    parsed,
    integrity_verified,
    proof_checked: ?AssuranceGrade,

    pub fn semantic(self: Reached) SemanticState {
        @setRuntimeSafety(true);
        return switch (self) {
            .parsed => .parsed,
            .integrity_verified => .integrity_verified,
            .proof_checked => .proof_checked,
        };
    }
};

pub const Outcome = union(enum) {
    accepted: struct { grade: AssuranceGrade, development_only: bool },
    rejected: struct { reached: Reached, rejection: Rejection, development_only: ?bool },
};

/// The full result of one acceptance run. Every field states work the consumer
/// actually did.
pub const Assessment = struct {
    outcome: Outcome,
    provenance: ProvenanceState,
    /// Work units spent. Reported so a caller can see how close a certificate
    /// came to its budget.
    work_spent: u64,
    /// How many edges the certificate disclosed rather than the consumer
    /// checked. Reported next to the grade because a grade alone hides them:
    /// "translation_validated" describes the check that ran, and this describes
    /// what the whole chain still rests on.
    disclosed_edges: u32 = 0,
    /// Per-property grades and the subset that cleared this policy. Runtime
    /// behavior may consume only the accepted subset.
    properties: PropertyVerdicts = .{},
    /// Residual guard coverage. A third axis beside proof stages and property
    /// verdicts, never folded into either: a covered guard is a promise to
    /// check at run time, and a passing check is not a theorem.
    guards: GuardVerdicts = .{},
    pub fn accepted(self: Assessment) bool {
        @setRuntimeSafety(true);
        return self.outcome == .accepted;
    }

    pub fn semantic(self: Assessment) SemanticState {
        @setRuntimeSafety(true);
        return switch (self.outcome) {
            .accepted => .policy_accepted,
            .rejected => |failure| failure.reached.semantic(),
        };
    }

    pub fn grade(self: Assessment) ?AssuranceGrade {
        @setRuntimeSafety(true);
        return switch (self.outcome) {
            .accepted => |success| success.grade,
            .rejected => |failure| switch (failure.reached) {
                .parsed, .integrity_verified => null,
                .proof_checked => |grade_value| grade_value,
            },
        };
    }

    pub fn rejection(self: Assessment) ?Rejection {
        @setRuntimeSafety(true);
        return switch (self.outcome) {
            .accepted => null,
            .rejected => |failure| failure.rejection,
        };
    }

    /// Null means decoding stopped before the certificate identity was known.
    pub fn developmentOnly(self: Assessment) ?bool {
        @setRuntimeSafety(true);
        return switch (self.outcome) {
            .accepted => |success| success.development_only,
            .rejected => |failure| failure.development_only,
        };
    }

    pub fn reject(
        reached: Reached,
        provenance: ProvenanceState,
        development_only: ?bool,
        refusal: Rejection,
        work_spent: u64,
    ) Assessment {
        @setRuntimeSafety(true);
        return .{
            .outcome = .{ .rejected = .{
                .reached = reached,
                .rejection = refusal,
                .development_only = development_only,
            } },
            .provenance = provenance,
            .work_spent = work_spent,
        };
    }
};

test "weakest edge dominates" {
    try std.testing.expectEqual(AssuranceGrade.trusted, AssuranceGrade.weakest(.proved, .trusted));
    try std.testing.expectEqual(AssuranceGrade.tested, AssuranceGrade.weakest(.tested, .proved));
    try std.testing.expectEqual(AssuranceGrade.proved, AssuranceGrade.weakest(.proved, .proved));
    try std.testing.expect(AssuranceGrade.proved.atLeastAsStrongAs(.tested));
    try std.testing.expect(!AssuranceGrade.tested.atLeastAsStrongAs(.proved));
    inline for (@typeInfo(AssuranceGrade).@"enum".field_names) |field| {
        const grade: AssuranceGrade = @fromBackingInt(@intCast(@backingInt(@field(AssuranceGrade, field))));
        try std.testing.expect(grade.atLeastAsStrongAs(grade));
    }
}

test "a rejection is never an acceptance" {
    const a = Assessment.reject(.parsed, .absent, null, .{
        .stage = .decode,
        .code = .bad_magic,
        .recertifiable = true,
    }, 0);
    try std.testing.expect(!a.accepted());
    try std.testing.expectEqual(@as(?AssuranceGrade, null), a.grade());
}

test "a property keeps its acceptance when its grade is updated" {
    var properties: PropertyVerdicts = .{};
    try std.testing.expectEqual(@as(?AssuranceGrade, null), properties.gradeFor(.response_total));
    try std.testing.expect(!properties.accepted(.response_total));
    properties.recordGrade(.response_total, .tested);
    try std.testing.expectEqual(@as(?AssuranceGrade, .tested), properties.gradeFor(.response_total));
    try std.testing.expect(!properties.accepted(.response_total));
    properties.accept(.response_total, .tested);
    properties.recordGrade(.response_total, .proved);
    try std.testing.expectEqual(@as(?AssuranceGrade, .proved), properties.gradeFor(.response_total));
    try std.testing.expect(properties.accepted(.response_total));
}

test "guard readiness requires exact coverage" {
    try std.testing.expect(!(GuardVerdicts{ .required = 1, .covered = 2 }).ready());
    try std.testing.expect(!(GuardVerdicts{ .required = 2, .covered = 1 }).ready());
}

test "reason codes are unique and stable" {
    @setEvalBranchQuota(20000);
    const fields = @typeInfo(ReasonCode).@"enum".field_names;
    inline for (fields, 0..) |a, i| {
        inline for (fields, 0..) |b, j| {
            if (i != j) try std.testing.expect(@backingInt(@field(ReasonCode, a)) != @backingInt(@field(ReasonCode, b)));
        }
        try std.testing.expect(@backingInt(@field(ReasonCode, a)) >= 1000);
    }
}

test "retired stage and reason ordinals remain unused" {
    for ([_]u8{ 11, 12, 13 }) |retired_stage| {
        try std.testing.expectEqual(@as(?Stage, null), std.enums.fromInt(Stage, retired_stage));
    }
    for (2001..2018) |retired_reason| {
        try std.testing.expectEqual(
            @as(?ReasonCode, null),
            std.enums.fromInt(ReasonCode, @as(u16, @intCast(retired_reason))),
        );
    }
    for ([_]u16{ 2101, 2102, 2103, 2201, 2202, 2203 }) |retired_reason| {
        try std.testing.expectEqual(
            @as(?ReasonCode, null),
            std.enums.fromInt(ReasonCode, retired_reason),
        );
    }
}

test "assurance grade wire encoding is one-based and closed" {
    try std.testing.expectEqual(@as(?AssuranceGrade, null), AssuranceGrade.fromWire(0));
    try std.testing.expectEqual(@as(?AssuranceGrade, null), AssuranceGrade.fromWire(6));
    inline for (@typeInfo(AssuranceGrade).@"enum".field_names) |f| {
        const g: AssuranceGrade = @fromBackingInt(@intCast(@backingInt(@field(AssuranceGrade, f))));
        try std.testing.expectEqual(@as(?AssuranceGrade, g), AssuranceGrade.fromWire(g.toWire()));
    }
}

test "every stage and state has its exact stable name" {
    const stages = .{
        .{ Stage.decode, "decode" },
        .{ Stage.limits, "limits" },
        .{ Stage.proof_system_identity, "proof_system_identity" },
        .{ Stage.artifact_binding, "artifact_binding" },
        .{ Stage.obligation_reconstruction, "obligation_reconstruction" },
        .{ Stage.evidence_check, "evidence_check" },
        .{ Stage.translation_check, "translation_check" },
        .{ Stage.solver, "solver" },
        .{ Stage.policy, "policy" },
        .{ Stage.guard_coverage, "guard_coverage" },
    };
    try std.testing.expectEqual(@typeInfo(Stage).@"enum".field_names.len, stages.len);
    inline for (stages) |item| try std.testing.expectEqualStrings(item[1], item[0].name());

    const semantic_states = .{
        .{ SemanticState.parsed, "parsed" },
        .{ SemanticState.integrity_verified, "integrity_verified" },
        .{ SemanticState.proof_checked, "proof_checked" },
        .{ SemanticState.policy_accepted, "policy_accepted" },
    };
    try std.testing.expectEqual(@typeInfo(SemanticState).@"enum".field_names.len, semantic_states.len);
    inline for (semantic_states) |item| try std.testing.expectEqualStrings(item[1], item[0].name());

    const provenance_states = .{
        .{ ProvenanceState.absent, "absent" },
        .{ ProvenanceState.unchecked, "unchecked" },
        .{ ProvenanceState.signature_verified, "signature_verified" },
        .{ ProvenanceState.trusted_origin, "trusted_origin" },
    };
    try std.testing.expectEqual(@typeInfo(ProvenanceState).@"enum".field_names.len, provenance_states.len);
    inline for (provenance_states) |item| try std.testing.expectEqualStrings(item[1], item[0].name());

    const assurance_grades = .{
        .{ AssuranceGrade.proved, "proved" },
        .{ AssuranceGrade.translation_validated, "translation_validated" },
        .{ AssuranceGrade.solver_assumed, "solver_assumed" },
        .{ AssuranceGrade.tested, "tested" },
        .{ AssuranceGrade.trusted, "trusted" },
    };
    try std.testing.expectEqual(@typeInfo(AssuranceGrade).@"enum".field_names.len, assurance_grades.len);
    inline for (assurance_grades) |item| try std.testing.expectEqualStrings(item[1], item[0].name());
}
