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

    pub fn atLeast(self: SemanticState, other: SemanticState) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    pub fn name(self: SemanticState) []const u8 {
        return switch (self) {
            .parsed => "parsed",
            .integrity_verified => "integrity_verified",
            .proof_checked => "proof_checked",
            .policy_accepted => "policy_accepted",
        };
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
        return switch (self) {
            .absent => "absent",
            .unchecked => "unchecked",
            .signature_verified => "signature_verified",
            .trusted_origin => "trusted_origin",
        };
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
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }

    pub fn atLeastAsStrongAs(self: AssuranceGrade, floor: AssuranceGrade) bool {
        return @intFromEnum(self) <= @intFromEnum(floor);
    }

    /// Wire encoding is one-based so that zero can mean "no grade stated".
    pub fn fromWire(value: u8) ?AssuranceGrade {
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
        return @as(u8, @intFromEnum(self)) + 1;
    }

    pub fn name(self: AssuranceGrade) []const u8 {
        return switch (self) {
            .proved => "proved",
            .translation_validated => "translation_validated",
            .solver_assumed => "solver_assumed",
            .tested => "tested",
            .trusted => "trusted",
        };
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

    pub fn name(self: Stage) []const u8 {
        return switch (self) {
            .decode => "decode",
            .limits => "limits",
            .proof_system_identity => "proof_system_identity",
            .artifact_binding => "artifact_binding",
            .obligation_reconstruction => "obligation_reconstruction",
            .evidence_check => "evidence_check",
            .translation_check => "translation_check",
            .solver => "solver",
            .policy => "policy",
        };
    }
};

/// Stable rejection codes. The numeric value is the contract; the spelling is
/// the diagnostic. Never renumber a member, and never reuse a retired one.
///
/// Every member here is a code some path in this package constructs. A code the
/// kernel advertises and never produces reads, to anyone auditing the rejection
/// surface, as a check that exists; three such were removed rather than left in
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
    rule_family_mismatch = 1503,
    rule_premise_unmet = 1504,
    proof_node_cycle = 1505,
    proof_node_unknown = 1506,
    fabricated_property = 1507,
    trusted_edge_undeclared = 1508,
    evidence_edge_invalid = 1509,
    proof_node_parent_mismatch = 1510,

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
    semantics_epoch_not_selected = 1806,

    pub fn text(self: ReasonCode) []const u8 {
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
    const count = @typeInfo(proof_system.Property).@"enum".fields.len;

    grades: [count]?AssuranceGrade = [_]?AssuranceGrade{null} ** count,
    accepted_bits: u16 = 0,

    fn slot(property: proof_system.Property) usize {
        return @intFromEnum(property) - 1;
    }

    pub fn gradeFor(self: PropertyVerdicts, property: proof_system.Property) ?AssuranceGrade {
        return self.grades[slot(property)];
    }

    pub fn accepted(self: PropertyVerdicts, property: proof_system.Property) bool {
        return self.accepted_bits & (@as(u16, 1) << @intCast(slot(property))) != 0;
    }

    pub fn recordGrade(self: *PropertyVerdicts, property: proof_system.Property, grade: AssuranceGrade) void {
        self.grades[slot(property)] = grade;
    }

    pub fn accept(self: *PropertyVerdicts, property: proof_system.Property) void {
        self.accepted_bits |= @as(u16, 1) << @intCast(slot(property));
    }
};

/// The full result of one acceptance run. Every field states work the consumer
/// actually did.
pub const Assessment = struct {
    semantic: SemanticState,
    provenance: ProvenanceState,
    /// The weakest edge used to reach `semantic`. Absent below `proof_checked`,
    /// because nothing was graded yet.
    grade: ?AssuranceGrade,
    /// The artifact declared an ephemeral identity or an unpinned runtime
    /// policy. Such an artifact can be checked, and can never be accepted for
    /// production.
    development_only: bool,
    rejection: ?Rejection,
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

    pub fn accepted(self: Assessment) bool {
        return self.rejection == null and self.semantic == .policy_accepted;
    }

    pub fn reject(
        state: SemanticState,
        provenance: ProvenanceState,
        rejection: Rejection,
        work_spent: u64,
    ) Assessment {
        return .{
            .semantic = state,
            .provenance = provenance,
            .grade = null,
            .development_only = false,
            .rejection = rejection,
            .work_spent = work_spent,
        };
    }
};

test "semantic states are ordered and never skipped backwards" {
    try std.testing.expect(SemanticState.policy_accepted.atLeast(.proof_checked));
    try std.testing.expect(SemanticState.proof_checked.atLeast(.integrity_verified));
    try std.testing.expect(!SemanticState.integrity_verified.atLeast(.proof_checked));
}

test "weakest edge dominates" {
    try std.testing.expectEqual(AssuranceGrade.trusted, AssuranceGrade.weakest(.proved, .trusted));
    try std.testing.expectEqual(AssuranceGrade.tested, AssuranceGrade.weakest(.tested, .proved));
    try std.testing.expectEqual(AssuranceGrade.proved, AssuranceGrade.weakest(.proved, .proved));
    try std.testing.expect(AssuranceGrade.proved.atLeastAsStrongAs(.tested));
    try std.testing.expect(!AssuranceGrade.tested.atLeastAsStrongAs(.proved));
}

test "a rejection is never an acceptance" {
    const a = Assessment.reject(.parsed, .absent, .{
        .stage = .decode,
        .code = .bad_magic,
        .recertifiable = true,
    }, 0);
    try std.testing.expect(!a.accepted());
    try std.testing.expectEqual(@as(?AssuranceGrade, null), a.grade);
}

test "reason codes are unique and stable" {
    @setEvalBranchQuota(20000);
    const fields = @typeInfo(ReasonCode).@"enum".fields;
    inline for (fields, 0..) |a, i| {
        inline for (fields, 0..) |b, j| {
            if (i != j) try std.testing.expect(a.value != b.value);
        }
        try std.testing.expect(a.value >= 1000);
    }
}

test "assurance grade wire encoding is one-based and closed" {
    try std.testing.expectEqual(@as(?AssuranceGrade, null), AssuranceGrade.fromWire(0));
    try std.testing.expectEqual(@as(?AssuranceGrade, null), AssuranceGrade.fromWire(6));
    inline for (@typeInfo(AssuranceGrade).@"enum".fields) |f| {
        const g: AssuranceGrade = @enumFromInt(f.value);
        try std.testing.expectEqual(@as(?AssuranceGrade, g), AssuranceGrade.fromWire(g.toWire()));
    }
}

test "every stage and state names itself" {
    inline for (@typeInfo(Stage).@"enum".fields) |f| {
        const s: Stage = @enumFromInt(f.value);
        try std.testing.expect(s.name().len > 0);
    }
    inline for (@typeInfo(SemanticState).@"enum".fields) |f| {
        const s: SemanticState = @enumFromInt(f.value);
        try std.testing.expect(s.name().len > 0);
    }
    inline for (@typeInfo(ProvenanceState).@"enum".fields) |f| {
        const s: ProvenanceState = @enumFromInt(f.value);
        try std.testing.expect(s.name().len > 0);
    }
    inline for (@typeInfo(AssuranceGrade).@"enum".fields) |f| {
        const g: AssuranceGrade = @enumFromInt(f.value);
        try std.testing.expect(g.name().len > 0);
    }
}
