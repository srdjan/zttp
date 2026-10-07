//! The certificate wire format and its bounded decoder.
//!
//! The format is fixed-width and closed. Every record has one size, every
//! alphabet is an enum with a `fromWire` that returns null outside it, sections
//! appear once in ascending tag order, and reserved bytes must be zero. There
//! is no extension point: a producer with something new to say bumps
//! `schema_version` and edits this file.
//!
//! The decoder is zero-copy and allocation-free. It validates structure and
//! every enum-bearing field in one bounded pass, then hands back cursors into
//! the caller's buffer.

const std = @import("std");
const limits_mod = @import("limits.zig");
const ps = @import("proof_system.zig");
const graph_mod = @import("executable_graph.zig");
const invariant = @import("invariant.zig");
const residual = @import("residual.zig");
const verdict = @import("verdict.zig");

const Limits = limits_mod.Limits;
const Budget = limits_mod.Budget;
const ReasonCode = verdict.ReasonCode;

/// "ZTPCC1\0\0" - Zttp Proof Certificate, container 1.
pub const magic: u64 = 0x5A54_5043_4331_0000;

pub const header_size = 18;
pub const section_header_size = 6;

pub const DecodeError = error{
    CertificateTooLarge,
    Truncated,
    BadMagic,
    UnsupportedSchemaVersion,
    UnknownSectionTag,
    DuplicateSection,
    MissingRequiredSection,
    TrailingData,
    SectionTooLarge,
    SectionLengthMismatch,
    CountExceedsLimit,
    UnknownEnumMember,
    SectionNotCanonicallyOrdered,
    ReservedFieldNonZero,
    WorkBudgetExhausted,
};

/// Map a decode failure onto the stable public reason code.
pub fn reasonFor(err: DecodeError) ReasonCode {
    @setRuntimeSafety(true);
    return switch (err) {
        error.CertificateTooLarge => .certificate_too_large,
        error.Truncated => .truncated_input,
        error.BadMagic => .bad_magic,
        error.UnsupportedSchemaVersion => .unsupported_schema_version,
        error.UnknownSectionTag => .unknown_section_tag,
        error.DuplicateSection => .duplicate_section,
        error.MissingRequiredSection => .missing_required_section,
        error.TrailingData => .trailing_data,
        error.SectionTooLarge => .section_too_large,
        error.SectionLengthMismatch => .section_length_mismatch,
        error.CountExceedsLimit => .count_exceeds_limit,
        error.UnknownEnumMember => .unknown_enum_member,
        error.SectionNotCanonicallyOrdered => .section_not_canonically_ordered,
        error.ReservedFieldNonZero => .reserved_field_nonzero,
        error.WorkBudgetExhausted => .work_budget_exhausted,
    };
}

pub const SectionTag = enum(u16) {
    identity = 1,
    graph = 2,
    obligations = 3,
    proof_ir = 4,
    evidence = 5,
    translation = 6,
    rewrites = 7,
    trusted = 8,
    solver = 9,
    /// Residual guard obligations. Present only under a proof system that
    /// carries them.
    residual = 10,
    /// Protected-ledger operation witnesses for a configured invariant.
    invariant = 11,

    pub fn fromWire(value: u16) ?SectionTag {
        @setRuntimeSafety(true);
        return std.enums.fromInt(SectionTag, value);
    }

    pub fn required(self: SectionTag) bool {
        @setRuntimeSafety(true);
        return switch (self) {
            .identity, .graph, .obligations, .proof_ir, .evidence => true,
            .translation, .rewrites, .trusted, .solver, .residual, .invariant => false,
        };
    }
};

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

pub const identity_size = 193;

pub const Identity = struct {
    /// Root over the canonical executable graph.
    executable_root: [32]u8,
    /// Root over the canonical proof IR, which is itself a graph member.
    ir_root: [32]u8,
    /// Digest of the serialized handler contract.
    contract_digest: [32]u8,
    /// Digest of the canonical residual guard plan. All zero when the handler
    /// has no guarded operations, which is a statement and not an omission.
    residual_plan_digest: [32]u8 = [_]u8{0} ** 32,
    /// Digest of the exact serialized runtime capability policy this artifact
    /// was built against. The checker recomputes it from the bytes it is given,
    /// so this is what ties a guard plan to one policy rather than to any.
    runtime_policy_digest: [32]u8 = [_]u8{0} ** 32,
    /// Digest of the canonical structured invariant specification. All zero
    /// when this artifact declares no application invariant.
    invariant_spec_digest: [32]u8 = [_]u8{0} ** 32,
    /// The artifact was built with an ephemeral identity or an unpinned runtime
    /// policy. It can be checked; it can never satisfy production acceptance.
    development: bool,
};

pub const graph_record_size = 38;

pub const obligation_record_size = 8;

pub const SubjectKind = enum(u8) {
    /// The handler as a whole.
    handler = 1,
    /// One function in the proof IR, named by its node id.
    function = 2,

    pub fn fromWire(value: u8) ?SubjectKind {
        @setRuntimeSafety(true);
        return std.enums.fromInt(SubjectKind, value);
    }
};

pub const Obligation = struct {
    property: ps.Property,
    subject_kind: SubjectKind,
    subject_id: u32,

    /// Canonical obligation order: property, then subject kind, then subject id.
    pub fn order(a: Obligation, b: Obligation) std.math.Order {
        @setRuntimeSafety(true);
        const pa = @intFromEnum(a.property);
        const pb = @intFromEnum(b.property);
        if (pa != pb) return std.math.order(pa, pb);
        const ka = @intFromEnum(a.subject_kind);
        const kb = @intFromEnum(b.subject_kind);
        if (ka != kb) return std.math.order(ka, kb);
        return std.math.order(a.subject_id, b.subject_id);
    }
};

pub const ir_record_size = 56;

pub const IrNode = struct {
    id: u32,
    tag: ps.NodeTag,
    /// The compiler-selected handler entry. Exactly one function carries this
    /// marker, and the marker participates in the proof-IR root.
    is_handler: bool = false,
    /// Parent node id. The root function is its own parent.
    parent: u32,
    first_child: u32,
    child_count: u32,
    /// Stable identity of this IR member, independent of source lines.
    digest: [32]u8,
    /// Tag-specific operand. Only `capability_call` uses it, where it names the
    /// row of the consumer's guard catalog this call matches. Every other tag
    /// must leave it zero, so the field cannot become a place to carry meaning
    /// the decoder does not check.
    aux: u32 = 0,
};

pub const evidence_record_size = 16;

/// The kind of theorem-chain edge one evidence entry supplies.
pub const EdgeKind = enum(u8) {
    /// A small-kernel rule the consumer re-runs itself.
    proved = 1,
    /// A translation witness the consumer re-checks against the final bytecode.
    translation_validated = 2,
    /// A query the consumer reconstructs and hands to an isolated solver.
    solver = 3,
    /// A finite corpus exercised it. Disclosed, not checked here.
    tested = 4,
    /// Declared trusted. Disclosed, not checked here.
    trusted = 5,
    /// The producer states that this obligation is not discharged. A handler
    /// that writes is not read-only, and saying so is an answer. It is not an
    /// omission, and it is not a weak form of yes: an obligation carrying only
    /// this edge is answered and not established, and a policy that requires
    /// the property rejects.
    not_established = 6,

    pub fn fromWire(value: u8) ?EdgeKind {
        @setRuntimeSafety(true);
        return std.enums.fromInt(EdgeKind, value);
    }

    /// The grade an edge of this kind contributes when it holds. An edge that
    /// establishes nothing contributes no grade.
    pub fn grade(self: EdgeKind) ?verdict.AssuranceGrade {
        @setRuntimeSafety(true);
        return switch (self) {
            .proved => .proved,
            .translation_validated => .translation_validated,
            .solver => .solver_assumed,
            .tested => .tested,
            .trusted => .trusted,
            .not_established => null,
        };
    }

    /// Whether the consumer re-runs work for this edge, or only records it.
    pub fn checked(self: EdgeKind) bool {
        @setRuntimeSafety(true);
        return switch (self) {
            .proved, .translation_validated, .solver => true,
            .tested, .trusted, .not_established => false,
        };
    }
};

pub const Evidence = struct {
    obligation_index: u32,
    edge: EdgeKind,
    /// The kernel rule this entry cites. Absent for edges the consumer does not
    /// re-run.
    rule: ?ps.Rule,
    /// The proof-IR node the entry is about.
    node_id: u32,
    /// Rule-specific operand: a second node id, a code offset, or zero.
    aux: u32,
};

pub const witness_record_size = 28;

pub const WitnessKind = enum(u8) {
    /// This IR member occupies [code_start, code_start + code_len) in the final
    /// bytecode.
    emission = 1,
    /// This IR member emitted a jump at `code_start` that resolves to
    /// `target_offset`, which must be where `target_ir` was emitted.
    jump = 2,

    pub fn fromWire(value: u8) ?WitnessKind {
        @setRuntimeSafety(true);
        return std.enums.fromInt(WitnessKind, value);
    }
};

pub const Witness = struct {
    ir_node: u32,
    code_start: u32,
    code_len: u32,
    target_ir: u32,
    target_offset: u32,
    /// The function whose code buffer these offsets are measured in, as a
    /// proof-IR node id. Every function generates into its own buffer, so an
    /// offset only means something inside one; comparing a jump in one function
    /// against an emission in another would be comparing two number lines.
    scope_ir_node: u32,
    kind: WitnessKind,

    /// Canonical witness order. Emissions precede jumps within a scope so the
    /// checker can validate the interval structure in one bounded pass.
    pub fn order(a: Witness, b: Witness) std.math.Order {
        @setRuntimeSafety(true);
        if (a.scope_ir_node != b.scope_ir_node) return std.math.order(a.scope_ir_node, b.scope_ir_node);
        const a_kind = @intFromEnum(a.kind);
        const b_kind = @intFromEnum(b.kind);
        if (a_kind != b_kind) return std.math.order(a_kind, b_kind);
        if (a.code_start != b.code_start) return std.math.order(a.code_start, b.code_start);
        if (a.code_len != b.code_len) return std.math.order(b.code_len, a.code_len);
        if (a.ir_node != b.ir_node) return std.math.order(a.ir_node, b.ir_node);
        if (a.target_ir != b.target_ir) return std.math.order(a.target_ir, b.target_ir);
        return std.math.order(a.target_offset, b.target_offset);
    }
};

pub const rewrite_record_size = 24;

pub const Rewrite = struct {
    rule: ps.Rule,
    before_offset: u32,
    before_len: u32,
    after_offset: u32,
    after_len: u32,
    /// Bytes every later offset shifted by. Negative for compaction.
    delta: i32,
};

pub const trusted_record_size = 8;

pub const TrustedFamily = enum(u8) {
    /// A proof-IR node whose totality is declared rather than derived.
    node = 1,
    /// A bytecode-level edge the kernel does not model, such as the decode of
    /// the bytes the translation witnesses point at.
    opcode = 2,

    pub fn fromWire(value: u8) ?TrustedFamily {
        @setRuntimeSafety(true);
        return std.enums.fromInt(TrustedFamily, value);
    }
};

pub const TrustedEdge = struct {
    family: TrustedFamily,
    member_id: u16,
    reason: ps.TrustReason,
    grade: verdict.AssuranceGrade,
};

pub const residual_record_size = 16;

/// One guarded operation.
///
/// Every field except `operation_id` restates something the consumer's own
/// catalog already decides. That redundancy is the point: a producer that
/// disagrees with the catalog about the kind, the rule, the sink, the section,
/// or the guard implementation is refused, and a producer that agrees has told
/// the consumer nothing it did not already know.
pub const ResidualObligation = struct {
    kind: residual.GuardKind,
    normalization: residual.Normalization,
    sink: residual.SinkId,
    section: residual.PolicySection,
    /// Identity of the guard implementation at that sink.
    impl_id: u32,
    /// The proof-IR node of the guarded call. This is the only field the
    /// catalog cannot supply, and it is what makes two guarded calls in one
    /// category two obligations.
    operation_id: u32,

    /// Canonical order: by the operation this is about. Kind follows from the
    /// catalog, so ordering by kind first would order by a derived value.
    pub fn order(a: ResidualObligation, b: ResidualObligation) std.math.Order {
        @setRuntimeSafety(true);
        return std.math.order(a.operation_id, b.operation_id);
    }
};

pub const invariant_record_size = 28;

/// One protected-ledger call related to proof IR and final bytecode.
pub const InvariantWitness = struct {
    ir_node: u32,
    scope_ir_node: u32,
    function_ordinal: u32,
    code_offset: u32,
    translation_index: u32,
    operation: invariant.Operation,
    sink: invariant.SinkId,
    impl_id: u32,

    /// Canonical order follows the independently observed final-code location.
    pub fn order(a: InvariantWitness, b: InvariantWitness) std.math.Order {
        @setRuntimeSafety(true);
        if (a.function_ordinal != b.function_ordinal) return std.math.order(a.function_ordinal, b.function_ordinal);
        if (a.code_offset != b.code_offset) return std.math.order(a.code_offset, b.code_offset);
        if (a.ir_node != b.ir_node) return std.math.order(a.ir_node, b.ir_node);
        return std.math.order(@intFromEnum(a.operation), @intFromEnum(b.operation));
    }
};

pub const solver_record_size = 8;

pub const SolverQueryKind = enum(u16) {
    /// The lowering of one opcode agrees with its denotation. One kind, because
    /// one is what a producer can construct today; a second would advertise a
    /// query shape nothing emits.
    opcode_equivalence = 1,

    pub fn fromWire(value: u16) ?SolverQueryKind {
        @setRuntimeSafety(true);
        return std.enums.fromInt(SolverQueryKind, value);
    }
};

pub const SolverQuery = struct {
    obligation_index: u32,
    query_kind: SolverQueryKind,
};

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

/// A fixed-width record table living inside the caller's buffer.
pub fn Table(comptime Record: type, comptime record_size: usize) type {
    @setRuntimeSafety(true);
    return struct {
        const Self = @This();

        bytes: []const u8 = &.{},
        count: u32 = 0,

        pub fn len(self: Self) u32 {
            @setRuntimeSafety(true);
            return self.count;
        }

        pub fn get(self: Self, index: u32) DecodeError!Record {
            @setRuntimeSafety(true);
            if (index >= self.count) return error.Truncated;
            const start = @as(usize, index) * record_size;
            return decodeRecord(Record, self.bytes[start..][0..record_size]);
        }
    };
}

pub const GraphTable = Table(graph_mod.Member, graph_record_size);
pub const ObligationTable = Table(Obligation, obligation_record_size);
pub const IrTable = Table(IrNode, ir_record_size);
pub const EvidenceTable = Table(Evidence, evidence_record_size);
pub const WitnessTable = Table(Witness, witness_record_size);
pub const RewriteTable = Table(Rewrite, rewrite_record_size);
pub const TrustedTable = Table(TrustedEdge, trusted_record_size);
pub const SolverTable = Table(SolverQuery, solver_record_size);
pub const ResidualTable = Table(ResidualObligation, residual_record_size);
pub const InvariantTable = Table(InvariantWitness, invariant_record_size);

fn u16At(bytes: []const u8, offset: usize) u16 {
    @setRuntimeSafety(true);
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn u32At(bytes: []const u8, offset: usize) u32 {
    @setRuntimeSafety(true);
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn i32At(bytes: []const u8, offset: usize) i32 {
    @setRuntimeSafety(true);
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn requireZero(bytes: []const u8) DecodeError!void {
    @setRuntimeSafety(true);
    for (bytes) |byte| {
        if (byte != 0) return error.ReservedFieldNonZero;
    }
}

fn decodeRecord(comptime Record: type, bytes: []const u8) DecodeError!Record {
    @setRuntimeSafety(true);
    return switch (Record) {
        graph_mod.Member => blk: {
            const kind = graph_mod.MemberKind.fromWire(u16At(bytes, 0)) orelse return error.UnknownEnumMember;
            var digest: [32]u8 = undefined;
            @memcpy(&digest, bytes[6..38]);
            break :blk graph_mod.Member{ .kind = kind, .ordinal = u32At(bytes, 2), .digest = digest };
        },
        Obligation => blk: {
            const property = ps.Property.fromWire(u16At(bytes, 0)) orelse return error.UnknownEnumMember;
            const subject_kind = SubjectKind.fromWire(bytes[2]) orelse return error.UnknownEnumMember;
            try requireZero(bytes[3..4]);
            break :blk Obligation{
                .property = property,
                .subject_kind = subject_kind,
                .subject_id = u32At(bytes, 4),
            };
        },
        IrNode => blk: {
            const tag = ps.NodeTag.fromWire(u16At(bytes, 4)) orelse return error.UnknownEnumMember;
            const flags = bytes[6];
            if (flags & ~@as(u8, 0x01) != 0) return error.ReservedFieldNonZero;
            try requireZero(bytes[7..8]);
            var digest: [32]u8 = undefined;
            @memcpy(&digest, bytes[20..52]);
            const aux = u32At(bytes, 52);
            if (!tag.usesAux() and aux != 0) return error.ReservedFieldNonZero;
            break :blk IrNode{
                .id = u32At(bytes, 0),
                .tag = tag,
                .is_handler = flags & 0x01 != 0,
                .parent = u32At(bytes, 8),
                .first_child = u32At(bytes, 12),
                .child_count = u32At(bytes, 16),
                .digest = digest,
                .aux = aux,
            };
        },
        Evidence => blk: {
            const edge = EdgeKind.fromWire(bytes[4]) orelse return error.UnknownEnumMember;
            try requireZero(bytes[5..6]);
            const rule_raw = u16At(bytes, 6);
            const rule: ?ps.Rule = if (rule_raw == 0)
                null
            else
                ps.Rule.fromWire(rule_raw) orelse return error.UnknownEnumMember;
            break :blk Evidence{
                .obligation_index = u32At(bytes, 0),
                .edge = edge,
                .rule = rule,
                .node_id = u32At(bytes, 8),
                .aux = u32At(bytes, 12),
            };
        },
        Witness => blk: {
            const kind = WitnessKind.fromWire(bytes[24]) orelse return error.UnknownEnumMember;
            try requireZero(bytes[25..28]);
            break :blk Witness{
                .ir_node = u32At(bytes, 0),
                .code_start = u32At(bytes, 4),
                .code_len = u32At(bytes, 8),
                .target_ir = u32At(bytes, 12),
                .target_offset = u32At(bytes, 16),
                .scope_ir_node = u32At(bytes, 20),
                .kind = kind,
            };
        },
        Rewrite => blk: {
            const rule = ps.Rule.fromWire(u16At(bytes, 0)) orelse return error.UnknownEnumMember;
            try requireZero(bytes[2..4]);
            break :blk Rewrite{
                .rule = rule,
                .before_offset = u32At(bytes, 4),
                .before_len = u32At(bytes, 8),
                .after_offset = u32At(bytes, 12),
                .after_len = u32At(bytes, 16),
                .delta = i32At(bytes, 20),
            };
        },
        TrustedEdge => blk: {
            const family = TrustedFamily.fromWire(bytes[0]) orelse return error.UnknownEnumMember;
            const grade = verdict.AssuranceGrade.fromWire(bytes[1]) orelse return error.UnknownEnumMember;
            const reason = ps.TrustReason.fromWire(u16At(bytes, 4)) orelse return error.UnknownEnumMember;
            try requireZero(bytes[6..8]);
            break :blk TrustedEdge{
                .family = family,
                .member_id = u16At(bytes, 2),
                .reason = reason,
                .grade = grade,
            };
        },
        ResidualObligation => blk: {
            const kind = residual.GuardKind.fromWire(bytes[0]) orelse return error.UnknownEnumMember;
            const normalization = residual.Normalization.fromWire(bytes[1]) orelse return error.UnknownEnumMember;
            const sink = residual.SinkId.fromWire(bytes[2]) orelse return error.UnknownEnumMember;
            const section = residual.PolicySection.fromWire(bytes[3]) orelse return error.UnknownEnumMember;
            try requireZero(bytes[12..16]);
            break :blk ResidualObligation{
                .kind = kind,
                .normalization = normalization,
                .sink = sink,
                .section = section,
                .impl_id = u32At(bytes, 4),
                .operation_id = u32At(bytes, 8),
            };
        },
        InvariantWitness => blk: {
            const operation = invariant.Operation.fromWire(bytes[20]) orelse return error.UnknownEnumMember;
            const sink = invariant.SinkId.fromWire(bytes[21]) orelse return error.UnknownEnumMember;
            try requireZero(bytes[22..24]);
            break :blk InvariantWitness{
                .ir_node = u32At(bytes, 0),
                .scope_ir_node = u32At(bytes, 4),
                .function_ordinal = u32At(bytes, 8),
                .code_offset = u32At(bytes, 12),
                .translation_index = u32At(bytes, 16),
                .operation = operation,
                .sink = sink,
                .impl_id = u32At(bytes, 24),
            };
        },
        SolverQuery => blk: {
            const kind = SolverQueryKind.fromWire(u16At(bytes, 4)) orelse return error.UnknownEnumMember;
            try requireZero(bytes[6..8]);
            break :blk SolverQuery{
                .obligation_index = u32At(bytes, 0),
                .query_kind = kind,
            };
        },
        else => @compileError("no decoder for " ++ @typeName(Record)),
    };
}

// ---------------------------------------------------------------------------
// Decoded certificate
// ---------------------------------------------------------------------------

pub const Certificate = struct {
    schema_version: u16,
    proof_system: ps.ProofSystem,
    semantics_epoch: u32,
    identity: Identity,
    graph: GraphTable,
    obligations: ObligationTable,
    ir: IrTable,
    evidence: EvidenceTable,
    translation: WitnessTable = .{},
    rewrites: RewriteTable = .{},
    trusted: TrustedTable = .{},
    solver: SolverTable = .{},
    residual: ResidualTable = .{},
    invariants: InvariantTable = .{},
};

const Slot = struct {
    part_field: []const u8,
    cert_field: []const u8,
    limit_field: []const u8,
    record_size: usize,
};

fn slot(comptime tag: SectionTag) Slot {
    @setRuntimeSafety(true);
    return switch (tag) {
        .identity => .{ .part_field = "identity", .cert_field = "identity", .limit_field = "", .record_size = identity_size },
        .graph => .{ .part_field = "graph", .cert_field = "graph", .limit_field = "max_graph_members", .record_size = graph_record_size },
        .obligations => .{ .part_field = "obligations", .cert_field = "obligations", .limit_field = "max_obligations", .record_size = obligation_record_size },
        .proof_ir => .{ .part_field = "ir", .cert_field = "ir", .limit_field = "max_ir_nodes", .record_size = ir_record_size },
        .evidence => .{ .part_field = "evidence", .cert_field = "evidence", .limit_field = "max_evidence", .record_size = evidence_record_size },
        .translation => .{ .part_field = "translation", .cert_field = "translation", .limit_field = "max_witnesses", .record_size = witness_record_size },
        .rewrites => .{ .part_field = "rewrites", .cert_field = "rewrites", .limit_field = "max_rewrites", .record_size = rewrite_record_size },
        .trusted => .{ .part_field = "trusted", .cert_field = "trusted", .limit_field = "max_trusted_edges", .record_size = trusted_record_size },
        .solver => .{ .part_field = "solver", .cert_field = "solver", .limit_field = "max_solver_queries", .record_size = solver_record_size },
        .residual => .{ .part_field = "residual", .cert_field = "residual", .limit_field = "max_residual_obligations", .record_size = residual_record_size },
        .invariant => .{ .part_field = "invariants", .cert_field = "invariants", .limit_field = "max_invariant_operations", .record_size = invariant_record_size },
    };
}

fn countLimitFor(tag: SectionTag, limits: Limits) u32 {
    @setRuntimeSafety(true);
    return switch (tag) {
        .identity => 1,
        inline else => |case| @field(limits, slot(case).limit_field),
    };
}

fn recordSizeFor(tag: SectionTag) usize {
    @setRuntimeSafety(true);
    return switch (tag) {
        inline else => |case| slot(case).record_size,
    };
}

/// Bounded decode. Validates the container, the section table, every record's
/// fixed shape, and every enum-bearing field, then returns cursors into `bytes`.
pub fn decode(bytes: []const u8, limits: Limits, budget: *Budget) DecodeError!Certificate {
    @setRuntimeSafety(true);
    return decodeAccepting(bytes, &[_]u16{ps.schema_version}, limits, budget);
}

/// Bounded decode against an explicit set of accepted schema versions.
///
/// The set comes from the consumer's policy, so which schemas a build reads is
/// a policy decision rather than a constant compiled into the decoder. Equality
/// against the set, never a range.
pub fn decodeAccepting(
    bytes: []const u8,
    accepted_schemas: []const u16,
    limits: Limits,
    budget: *Budget,
) DecodeError!Certificate {
    @setRuntimeSafety(true);
    if (bytes.len > limits.max_certificate_bytes) return error.CertificateTooLarge;
    if (bytes.len < header_size) return error.Truncated;
    try budget.spend(bytes.len / 64 + 1);

    if (std.mem.readInt(u64, bytes[0..8], .little) != magic) return error.BadMagic;
    const schema = u16At(bytes, 8);
    accepted: {
        for (accepted_schemas) |candidate| {
            if (candidate == schema) break :accepted;
        }
        return error.UnsupportedSchemaVersion;
    }
    const proof_system = ps.ProofSystem.fromWire(u16At(bytes, 10)) orelse return error.UnknownEnumMember;
    const epoch = u32At(bytes, 12);
    const section_count = u16At(bytes, 16);
    if (section_count > limits.max_sections) return error.CountExceedsLimit;

    var cert = Certificate{
        .schema_version = schema,
        .proof_system = proof_system,
        .semantics_epoch = epoch,
        .identity = undefined,
        .graph = .{},
        .obligations = .{},
        .ir = .{},
        .evidence = .{},
    };

    var seen = std.EnumSet(SectionTag).initEmpty();
    var previous_tag: u16 = 0;
    var cursor: usize = header_size;

    var index: u16 = 0;
    while (index < section_count) : (index += 1) {
        try budget.spend(4);
        if (cursor + section_header_size > bytes.len) return error.Truncated;
        const raw_tag = u16At(bytes, cursor);
        const length = u32At(bytes, cursor + 2);
        cursor += section_header_size;

        const tag = SectionTag.fromWire(raw_tag) orelse return error.UnknownSectionTag;
        if (seen.contains(tag)) return error.DuplicateSection;
        if (index > 0 and raw_tag <= previous_tag) return error.SectionNotCanonicallyOrdered;
        previous_tag = raw_tag;
        seen.insert(tag);

        if (length > limits.max_section_bytes) return error.SectionTooLarge;
        if (cursor + length > bytes.len) return error.Truncated;
        const payload = bytes[cursor..][0..length];
        cursor += length;

        try decodeSection(&cert, tag, payload, limits, budget);
    }

    if (cursor != bytes.len) return error.TrailingData;

    inline for (@typeInfo(SectionTag).@"enum".fields) |field| {
        const tag: SectionTag = @enumFromInt(field.value);
        if (tag.required() and !seen.contains(tag)) return error.MissingRequiredSection;
    }

    return cert;
}

fn decodeSection(
    cert: *Certificate,
    tag: SectionTag,
    payload: []const u8,
    limits: Limits,
    budget: *Budget,
) DecodeError!void {
    @setRuntimeSafety(true);
    switch (tag) {
        .identity => {
            if (payload.len != identity_size) return error.SectionLengthMismatch;
            var identity = Identity{
                .executable_root = undefined,
                .ir_root = undefined,
                .contract_digest = undefined,
                .development = false,
            };
            @memcpy(&identity.executable_root, payload[0..32]);
            @memcpy(&identity.ir_root, payload[32..64]);
            @memcpy(&identity.contract_digest, payload[64..96]);
            @memcpy(&identity.residual_plan_digest, payload[96..128]);
            @memcpy(&identity.runtime_policy_digest, payload[128..160]);
            @memcpy(&identity.invariant_spec_digest, payload[160..192]);
            const flags = payload[192];
            if (flags & ~@as(u8, 0x01) != 0) return error.ReservedFieldNonZero;
            identity.development = (flags & 0x01) != 0;
            cert.identity = identity;
        },
        inline else => |case| {
            if (payload.len < 4) return error.SectionLengthMismatch;
            const count = u32At(payload, 0);
            if (count > countLimitFor(case, limits)) return error.CountExceedsLimit;
            const expected = 4 + @as(usize, count) * recordSizeFor(case);
            if (payload.len != expected) return error.SectionLengthMismatch;
            @field(cert, slot(case).cert_field) = .{ .bytes = payload[4..], .count = count };
            try budget.spend(@as(u64, count) + 1);

            // Validate every enum-bearing field before a caller walks the table.
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try budget.spend(1);
                _ = try @field(cert, slot(case).cert_field).get(i);
            }
        },
    }
}

/// Domain separator for the residual guard plan.
pub const residual_plan_domain = "zttp-residual-plan-v1";

fn foldResidual(hasher: *std.crypto.hash.sha2.Sha256, obligation: ResidualObligation) void {
    @setRuntimeSafety(true);
    hasher.update(&[_]u8{
        @intFromEnum(obligation.kind),
        @intFromEnum(obligation.normalization),
        @intFromEnum(obligation.sink),
        @intFromEnum(obligation.section),
    });
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, obligation.impl_id, .little);
    hasher.update(&scratch);
    std.mem.writeInt(u32, &scratch, obligation.operation_id, .little);
    hasher.update(&scratch);
}

/// Fold a residual plan into one digest.
///
/// An empty plan folds to all zero rather than to the digest of an empty list,
/// so "this handler guards nothing" is one value a reader can recognize instead
/// of a hash they would have to know to compare against.
pub fn residualPlanDigest(obligations: []const ResidualObligation) [32]u8 {
    @setRuntimeSafety(true);
    if (obligations.len == 0) return [_]u8{0} ** 32;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(residual_plan_domain);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, @intCast(obligations.len), .little);
    hasher.update(&count_le);
    for (obligations) |obligation| foldResidual(&hasher, obligation);
    return hasher.finalResult();
}

/// The same fold over a decoded table.
pub fn residualPlanDigestFromTable(table: ResidualTable) DecodeError![32]u8 {
    @setRuntimeSafety(true);
    if (table.len() == 0) return [_]u8{0} ** 32;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(residual_plan_domain);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, table.len(), .little);
    hasher.update(&count_le);
    var index: u32 = 0;
    while (index < table.len()) : (index += 1) {
        foldResidual(&hasher, try table.get(index));
    }
    return hasher.finalResult();
}

/// Domain separator for the proof-IR root.
pub const ir_root_domain = "zttp-proof-ir-root-v2";

fn foldIrNode(hasher: *std.crypto.hash.sha2.Sha256, node: IrNode) void {
    @setRuntimeSafety(true);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, node.id, .little);
    hasher.update(&scratch);
    var tag_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &tag_le, @intFromEnum(node.tag), .little);
    hasher.update(&tag_le);
    hasher.update(&[_]u8{@intFromBool(node.is_handler)});
    std.mem.writeInt(u32, &scratch, node.parent, .little);
    hasher.update(&scratch);
    std.mem.writeInt(u32, &scratch, node.first_child, .little);
    hasher.update(&scratch);
    std.mem.writeInt(u32, &scratch, node.child_count, .little);
    hasher.update(&scratch);
    hasher.update(&node.digest);
    std.mem.writeInt(u32, &scratch, node.aux, .little);
    hasher.update(&scratch);
}

/// Fold a proof-IR node list into one root.
///
/// This is the only definition of that fold. The producer calls it too, through
/// the same package, so a certificate's `ir_root` and the value the consumer
/// recomputes cannot come from two formulas that drifted apart.
pub fn irRootFromNodes(nodes: []const IrNode) [32]u8 {
    @setRuntimeSafety(true);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(ir_root_domain);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, @intCast(nodes.len), .little);
    hasher.update(&count_le);
    for (nodes) |node| foldIrNode(&hasher, node);
    return hasher.finalResult();
}

/// The same fold over a decoded table.
pub fn irRootFromTable(table: IrTable) DecodeError![32]u8 {
    @setRuntimeSafety(true);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(ir_root_domain);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, table.len(), .little);
    hasher.update(&count_le);
    var index: u32 = 0;
    while (index < table.len()) : (index += 1) {
        foldIrNode(&hasher, try table.get(index));
    }
    return hasher.finalResult();
}

/// Domain separator for the complete certificate commitment.
pub const commitment_domain = "zttp-proof-certificate-commitment-v1";

/// Commit every canonical certificate byte without creating a hash cycle.
///
/// The executable root contains this commitment as a graph member, while the
/// identity section contains that executable root. Both self-references are
/// replaced with zeroes for this fold. No authority-bearing certificate field
/// is excluded: evidence, translation witnesses, rewrites, trusted edges, and
/// solver queries all move the commitment.
pub fn commitmentDigest(bytes: []const u8, certificate: Certificate) DecodeError![32]u8 {
    @setRuntimeSafety(true);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(commitment_domain);

    const identity_root_offset = header_size + section_header_size;
    const zero_digest = [_]u8{0} ** 32;
    hasher.update(bytes[0..identity_root_offset]);
    hasher.update(&zero_digest);
    var cursor = identity_root_offset + zero_digest.len;

    const graph_offset = @intFromPtr(certificate.graph.bytes.ptr) - @intFromPtr(bytes.ptr);
    var index: u32 = 0;
    while (index < certificate.graph.len()) : (index += 1) {
        const member = try certificate.graph.get(index);
        if (member.kind != .proof_certificate) continue;

        const digest_offset = graph_offset + @as(usize, index) * graph_record_size + 6;
        hasher.update(bytes[cursor..digest_offset]);
        hasher.update(&zero_digest);
        cursor = digest_offset + zero_digest.len;
    }
    hasher.update(bytes[cursor..]);
    return hasher.finalResult();
}

// ---------------------------------------------------------------------------
// Canonical encoder
// ---------------------------------------------------------------------------

/// The producer-side view of a certificate: owned slices the encoder folds into
/// canonical bytes. The encoder lives beside the decoder so the two cannot
/// drift; it is not part of the acceptance kernel and takes no authority.
pub const Parts = struct {
    /// The schema this certificate is written in. Producers and consumers use
    /// one strict version and rebuild across version boundaries.
    schema_version: u16 = ps.schema_version,
    proof_system: ps.ProofSystem = .zttp_pcc_v3,
    semantics_epoch: u32 = ps.semantics_epoch,
    identity: Identity,
    graph: []const graph_mod.Member,
    obligations: []const Obligation,
    ir: []const IrNode,
    evidence: []const Evidence,
    translation: []const Witness = &.{},
    rewrites: []const Rewrite = &.{},
    trusted: []const TrustedEdge = &.{},
    solver: []const SolverQuery = &.{},
    residual: []const ResidualObligation = &.{},
    invariants: []const InvariantWitness = &.{},
};

pub const EncodeError = error{BufferTooSmall};

/// Bytes `encode` needs for `parts`.
pub fn encodedSize(parts: Parts) usize {
    @setRuntimeSafety(true);
    var total: usize = header_size;
    inline for (@typeInfo(SectionTag).@"enum".fields) |field| {
        const tag: SectionTag = @enumFromInt(field.value);
        if (tag == .identity) {
            total += section_header_size + identity_size;
        } else {
            const count = @field(parts, slot(tag).part_field).len;
            if (tag.required() or count > 0) total += section_header_size + 4 + count * slot(tag).record_size;
        }
    }
    return total;
}

const Cursor = struct {
    buf: []u8,
    at: usize = 0,

    fn need(self: *Cursor, n: usize) EncodeError![]u8 {
        @setRuntimeSafety(true);
        if (self.at + n > self.buf.len) return error.BufferTooSmall;
        const slice = self.buf[self.at..][0..n];
        self.at += n;
        return slice;
    }

    fn u8At(self: *Cursor, value: u8) EncodeError!void {
        @setRuntimeSafety(true);
        (try self.need(1))[0] = value;
    }

    fn u16At(self: *Cursor, value: u16) EncodeError!void {
        @setRuntimeSafety(true);
        std.mem.writeInt(u16, (try self.need(2))[0..2], value, .little);
    }

    fn u32At(self: *Cursor, value: u32) EncodeError!void {
        @setRuntimeSafety(true);
        std.mem.writeInt(u32, (try self.need(4))[0..4], value, .little);
    }

    fn i32At(self: *Cursor, value: i32) EncodeError!void {
        @setRuntimeSafety(true);
        std.mem.writeInt(i32, (try self.need(4))[0..4], value, .little);
    }

    fn u64At(self: *Cursor, value: u64) EncodeError!void {
        @setRuntimeSafety(true);
        std.mem.writeInt(u64, (try self.need(8))[0..8], value, .little);
    }

    fn zeros(self: *Cursor, n: usize) EncodeError!void {
        @setRuntimeSafety(true);
        @memset(try self.need(n), 0);
    }

    fn raw(self: *Cursor, bytes: []const u8) EncodeError!void {
        @setRuntimeSafety(true);
        @memcpy(try self.need(bytes.len), bytes);
    }
};

fn sectionCount(parts: Parts) u16 {
    @setRuntimeSafety(true);
    var count: u16 = 0;
    inline for (@typeInfo(SectionTag).@"enum".fields) |field| {
        const tag: SectionTag = @enumFromInt(field.value);
        if (tag == .identity) {
            count += 1;
        } else if (tag.required() or @field(parts, slot(tag).part_field).len > 0) {
            count += 1;
        }
    }
    return count;
}

/// Encode `parts` into `out` in canonical form. Sections are written in
/// ascending tag order; empty optional sections are omitted rather than written
/// with a zero count, so one set of parts has exactly one encoding.
pub fn encode(parts: Parts, out: []u8) EncodeError![]u8 {
    @setRuntimeSafety(true);
    var cursor = Cursor{ .buf = out };
    try cursor.u64At(magic);
    try cursor.u16At(parts.schema_version);
    try cursor.u16At(@intFromEnum(parts.proof_system));
    try cursor.u32At(parts.semantics_epoch);
    try cursor.u16At(sectionCount(parts));

    inline for (@typeInfo(SectionTag).@"enum".fields) |field| {
        try encodeSection(@enumFromInt(field.value), parts, &cursor);
    }
    return out[0..cursor.at];
}

fn encodeSection(comptime tag: SectionTag, parts: Parts, cursor: *Cursor) EncodeError!void {
    @setRuntimeSafety(true);
    if (tag != .identity) {
        if (!tag.required() and @field(parts, slot(tag).part_field).len == 0) return;
    }
    switch (tag) {
        .identity => {
            try cursor.u16At(@intFromEnum(tag));
            try cursor.u32At(@intCast(slot(tag).record_size));
            try cursor.raw(&parts.identity.executable_root);
            try cursor.raw(&parts.identity.ir_root);
            try cursor.raw(&parts.identity.contract_digest);
            try cursor.raw(&parts.identity.residual_plan_digest);
            try cursor.raw(&parts.identity.runtime_policy_digest);
            try cursor.raw(&parts.identity.invariant_spec_digest);
            try cursor.u8At(if (parts.identity.development) 0x01 else 0x00);
        },
        .graph => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |member| {
                try cursor.u16At(@intFromEnum(member.kind));
                try cursor.u32At(member.ordinal);
                try cursor.raw(&member.digest);
            }
        },
        .obligations => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |obligation| {
                try cursor.u16At(@intFromEnum(obligation.property));
                try cursor.u8At(@intFromEnum(obligation.subject_kind));
                try cursor.zeros(1);
                try cursor.u32At(obligation.subject_id);
            }
        },
        .proof_ir => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |node| {
                try cursor.u32At(node.id);
                try cursor.u16At(@intFromEnum(node.tag));
                try cursor.u8At(@intFromBool(node.is_handler));
                try cursor.zeros(1);
                try cursor.u32At(node.parent);
                try cursor.u32At(node.first_child);
                try cursor.u32At(node.child_count);
                try cursor.raw(&node.digest);
                try cursor.u32At(node.aux);
            }
        },
        .evidence => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |entry| {
                try cursor.u32At(entry.obligation_index);
                try cursor.u8At(@intFromEnum(entry.edge));
                try cursor.zeros(1);
                try cursor.u16At(if (entry.rule) |rule| @intFromEnum(rule) else 0);
                try cursor.u32At(entry.node_id);
                try cursor.u32At(entry.aux);
            }
        },
        .translation => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |witness| {
                try cursor.u32At(witness.ir_node);
                try cursor.u32At(witness.code_start);
                try cursor.u32At(witness.code_len);
                try cursor.u32At(witness.target_ir);
                try cursor.u32At(witness.target_offset);
                try cursor.u32At(witness.scope_ir_node);
                try cursor.u8At(@intFromEnum(witness.kind));
                try cursor.zeros(3);
            }
        },
        .rewrites => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |rewrite| {
                try cursor.u16At(@intFromEnum(rewrite.rule));
                try cursor.zeros(2);
                try cursor.u32At(rewrite.before_offset);
                try cursor.u32At(rewrite.before_len);
                try cursor.u32At(rewrite.after_offset);
                try cursor.u32At(rewrite.after_len);
                try cursor.i32At(rewrite.delta);
            }
        },
        .trusted => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |edge| {
                try cursor.u8At(@intFromEnum(edge.family));
                try cursor.u8At(edge.grade.toWire());
                try cursor.u16At(edge.member_id);
                try cursor.u16At(@intFromEnum(edge.reason));
                try cursor.zeros(2);
            }
        },
        .solver => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |query| {
                try cursor.u32At(query.obligation_index);
                try cursor.u16At(@intFromEnum(query.query_kind));
                try cursor.zeros(2);
            }
        },
        .residual => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |obligation| {
                try cursor.u8At(@intFromEnum(obligation.kind));
                try cursor.u8At(@intFromEnum(obligation.normalization));
                try cursor.u8At(@intFromEnum(obligation.sink));
                try cursor.u8At(@intFromEnum(obligation.section));
                try cursor.u32At(obligation.impl_id);
                try cursor.u32At(obligation.operation_id);
                try cursor.zeros(4);
            }
        },
        .invariant => {
            const records = @field(parts, slot(tag).part_field);
            try writeTable(cursor, tag, records.len, slot(tag).record_size);
            for (records) |witness| {
                try cursor.u32At(witness.ir_node);
                try cursor.u32At(witness.scope_ir_node);
                try cursor.u32At(witness.function_ordinal);
                try cursor.u32At(witness.code_offset);
                try cursor.u32At(witness.translation_index);
                try cursor.u8At(@intFromEnum(witness.operation));
                try cursor.u8At(@intFromEnum(witness.sink));
                try cursor.zeros(2);
                try cursor.u32At(witness.impl_id);
            }
        },
    }
}

fn writeTable(cursor: *Cursor, tag: SectionTag, count: usize, record_size: usize) EncodeError!void {
    @setRuntimeSafety(true);
    try cursor.u16At(@intFromEnum(tag));
    try cursor.u32At(@intCast(4 + count * record_size));
    try cursor.u32At(@intCast(count));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const fixture = struct {
    pub fn digest(seed: u8) [32]u8 {
        @setRuntimeSafety(true);
        var out: [32]u8 = undefined;
        @memset(&out, seed);
        return out;
    }

    /// The smallest certificate the schema admits: one handler function, one
    /// obligation, one proved edge, and the required graph kinds.
    pub fn minimalParts(
        graph: []const graph_mod.Member,
        ir: []const IrNode,
        obligations: []const Obligation,
        evidence: []const Evidence,
    ) Parts {
        @setRuntimeSafety(true);
        return .{
            .identity = .{
                .executable_root = digest(0),
                .ir_root = digest(0),
                .contract_digest = digest(2),
                .development = false,
            },
            .graph = graph,
            .obligations = obligations,
            .ir = ir,
            .evidence = evidence,
        };
    }
};

fn minimalGraph() [8]graph_mod.Member {
    @setRuntimeSafety(true);
    var members = [_]graph_mod.Member{
        .{ .kind = .main_bytecode, .ordinal = 0, .digest = fixture.digest(1) },
        .{ .kind = .contract_bytes, .ordinal = 0, .digest = fixture.digest(2) },
        .{ .kind = .runtime_policy_bytes, .ordinal = 0, .digest = fixture.digest(3) },
        .{ .kind = .source_profile_core, .ordinal = 0, .digest = fixture.digest(4) },
        .{ .kind = .core_grammar, .ordinal = 0, .digest = fixture.digest(5) },
        .{ .kind = .semantics, .ordinal = 0, .digest = fixture.digest(6) },
        .{ .kind = .capability_matrix, .ordinal = 0, .digest = fixture.digest(7) },
        .{ .kind = .proof_ir, .ordinal = 0, .digest = fixture.digest(8) },
    };
    std.mem.sort(graph_mod.Member, &members, {}, struct {
        fn lt(_: void, a: graph_mod.Member, b: graph_mod.Member) bool {
            @setRuntimeSafety(true);
            return graph_mod.Member.order(a, b) == .lt;
        }
    }.lt);
    return members;
}

fn buildMinimal(buf: []u8) ![]u8 {
    @setRuntimeSafety(true);
    const members = minimalGraph();
    const ir = [_]IrNode{
        .{ .id = 0, .tag = .function, .parent = 0, .first_child = 1, .child_count = 1, .digest = fixture.digest(20) },
        .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = fixture.digest(21) },
    };
    const obligations = [_]Obligation{
        .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
    };
    const evidence = [_]Evidence{
        .{ .obligation_index = 0, .edge = .proved, .rule = .return_total, .node_id = 1, .aux = 0 },
    };
    var parts = fixture.minimalParts(&members, &ir, &obligations, &evidence);
    parts.identity.executable_root = try graph_mod.computeRoot(&members);
    return encode(parts, buf);
}

fn buildAllSections(buf: []u8) ![]u8 {
    @setRuntimeSafety(true);
    const members = minimalGraph();
    const ir = [_]IrNode{
        .{ .id = 0, .tag = .function, .is_handler = true, .parent = 0, .first_child = 1, .child_count = 1, .digest = fixture.digest(20) },
        .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = fixture.digest(21) },
    };
    const obligations = [_]Obligation{.{ .property = .response_total, .subject_kind = .function, .subject_id = 0 }};
    const evidence = [_]Evidence{.{ .obligation_index = 0, .edge = .proved, .rule = .return_total, .node_id = 1, .aux = 0 }};
    const translation = [_]Witness{.{ .ir_node = 1, .code_start = 2, .code_len = 3, .target_ir = 0, .target_offset = 4, .scope_ir_node = 0, .kind = .emission }};
    const rewrites = [_]Rewrite{.{ .rule = .return_total, .before_offset = 2, .before_len = 3, .after_offset = 4, .after_len = 5, .delta = -1 }};
    const trusted = [_]TrustedEdge{.{ .family = .opcode, .member_id = 7, .reason = .not_modeled, .grade = .trusted }};
    const solver = [_]SolverQuery{.{ .obligation_index = 0, .query_kind = .opcode_equivalence }};
    const guards = [_]ResidualObligation{.{ .kind = .env_key, .normalization = .identifier_exact_v1, .sink = .env_read, .section = .env, .impl_id = 9, .operation_id = 1 }};
    const invariants = [_]InvariantWitness{.{ .ir_node = 1, .scope_ir_node = 0, .function_ordinal = 0, .code_offset = 2, .translation_index = 0, .operation = .post, .sink = .ledger_post, .impl_id = 9 }};
    var parts = fixture.minimalParts(&members, &ir, &obligations, &evidence);
    parts.identity.executable_root = try graph_mod.computeRoot(&members);
    parts.translation = &translation;
    parts.rewrites = &rewrites;
    parts.trusted = &trusted;
    parts.solver = &solver;
    parts.residual = &guards;
    parts.invariants = &invariants;
    return encode(parts, buf);
}

test "a minimal certificate round trips through the canonical codec" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);

    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);
    try testing.expectEqual(ps.schema_version, cert.schema_version);
    try testing.expectEqual(ps.ProofSystem.zttp_pcc_v3, cert.proof_system);
    try testing.expectEqual(@as(u32, 8), cert.graph.len());
    try testing.expectEqual(@as(u32, 1), cert.obligations.len());
    try testing.expectEqual(@as(u32, 2), cert.ir.len());
    try testing.expectEqual(@as(u32, 1), cert.evidence.len());
    try testing.expect(!cert.identity.development);

    const obligation = try cert.obligations.get(0);
    try testing.expectEqual(ps.Property.response_total, obligation.property);
    const entry = try cert.evidence.get(0);
    try testing.expectEqual(EdgeKind.proved, entry.edge);
    try testing.expectEqual(@as(?ps.Rule, .return_total), entry.rule);
}

test "the immediate predecessor certificate is refused rather than reinterpreted" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var predecessor: [4096]u8 = undefined;
    @memcpy(predecessor[0..bytes.len], bytes);
    std.mem.writeInt(u16, predecessor[8..10], 2, .little);
    std.mem.writeInt(u16, predecessor[10..12], 1, .little);

    var budget = Budget.init(.{});
    try testing.expectError(
        error.UnsupportedSchemaVersion,
        decode(predecessor[0..bytes.len], .{}, &budget),
    );
}

test "encoding is deterministic and sized exactly" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const first = try buildMinimal(&a);
    const second = try buildMinimal(&b);
    try testing.expectEqualSlices(u8, first, second);

    const members = minimalGraph();
    const ir = [_]IrNode{
        .{ .id = 0, .tag = .function, .parent = 0, .first_child = 1, .child_count = 1, .digest = fixture.digest(20) },
        .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = fixture.digest(21) },
    };
    const obligations = [_]Obligation{
        .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
    };
    const evidence = [_]Evidence{
        .{ .obligation_index = 0, .edge = .proved, .rule = .return_total, .node_id = 1, .aux = 0 },
    };
    const parts = fixture.minimalParts(&members, &ir, &obligations, &evidence);
    try testing.expectEqual(encodedSize(parts), first.len);
}

test "the encoder refuses a buffer that cannot hold the certificate" {
    var small: [16]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, buildMinimal(&small));
}

fn sectionHeaderOffset(bytes: []const u8, records: []const u8) usize {
    @setRuntimeSafety(true);
    // The four-byte table count sits between the section header and records.
    return @intFromPtr(records.ptr) - @intFromPtr(bytes.ptr) - 4 - section_header_size;
}

const TestSection = struct { start: usize, payload: usize, length: usize };

fn testSection(bytes: []const u8, tag: SectionTag) TestSection {
    @setRuntimeSafety(true);
    var at: usize = header_size;
    while (at < bytes.len) {
        const length = u32At(bytes, at + 2);
        if (u16At(bytes, at) == @intFromEnum(tag)) {
            return .{ .start = at, .payload = at + section_header_size, .length = length };
        }
        at += section_header_size + length;
    }
    unreachable;
}

test "all certificate sections have pinned wire bytes and decoded fields" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildAllSections(&buf);
    // This literal pins the wire format. Computing the expected digest from
    // the encoder at test time would check only encoder-decoder agreement.
    const pinned = [_]u8{
        0x60, 0x63, 0xe7, 0x03, 0x86, 0x68, 0x10, 0xab,
        0x6d, 0x57, 0xa8, 0x71, 0x38, 0x19, 0xc2, 0xe7,
        0xc2, 0x66, 0x38, 0xe2, 0xa2, 0xe2, 0x4b, 0xe9,
        0x51, 0xa8, 0xc7, 0x8d, 0xe2, 0xdf, 0xdc, 0xf6,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try testing.expectEqualSlices(u8, &pinned, &digest);

    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);
    try testing.expectEqual(@as(u16, 11), u16At(bytes, 16));
    try testing.expectEqual(@as(u32, 8), cert.graph.len());
    try testing.expectEqual(@as(u32, 1), cert.obligations.len());
    try testing.expectEqual(@as(u32, 2), cert.ir.len());
    try testing.expectEqual(@as(u32, 1), cert.evidence.len());
    try testing.expectEqual(@as(u32, 1), cert.translation.len());
    try testing.expectEqual(@as(u32, 1), cert.rewrites.len());
    try testing.expectEqual(@as(u32, 1), cert.trusted.len());
    try testing.expectEqual(@as(u32, 1), cert.solver.len());
    try testing.expectEqual(@as(u32, 1), cert.residual.len());
    try testing.expectEqual(@as(u32, 1), cert.invariants.len());
    try testing.expectEqualSlices(u8, &fixture.digest(2), &cert.identity.contract_digest);
    try testing.expectEqual(graph_mod.MemberKind.main_bytecode, (try cert.graph.get(0)).kind);
    try testing.expectEqual(ps.Property.response_total, (try cert.obligations.get(0)).property);
    try testing.expectEqual(ps.NodeTag.function, (try cert.ir.get(0)).tag);
    try testing.expect((try cert.ir.get(0)).is_handler);
    try testing.expectEqual(EdgeKind.proved, (try cert.evidence.get(0)).edge);
    try testing.expectEqual(@as(u32, 3), (try cert.translation.get(0)).code_len);
    try testing.expectEqual(@as(u32, 7), (try cert.trusted.get(0)).member_id);
    try testing.expectEqual(@as(i32, -1), (try cert.rewrites.get(0)).delta);
    try testing.expectEqual(SolverQueryKind.opcode_equivalence, (try cert.solver.get(0)).query_kind);
    try testing.expectEqual(residual.GuardKind.env_key, (try cert.residual.get(0)).kind);
    try testing.expectEqual(@as(u32, 2), (try cert.invariants.get(0)).code_offset);
}

test "each required certificate section is required by the decoder" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    inline for (.{ .identity, .graph, .obligations, .proof_ir, .evidence }) |tag| {
        const section = testSection(bytes, tag);
        const end = section.payload + section.length;
        var removed: [4096]u8 = undefined;
        @memcpy(removed[0..section.start], bytes[0..section.start]);
        @memcpy(removed[section.start..][0 .. bytes.len - end], bytes[end..]);
        std.mem.writeInt(u16, removed[16..18], 4, .little);
        var budget = Budget.init(.{});
        try testing.expectError(error.MissingRequiredSection, decode(removed[0 .. bytes.len - (end - section.start)], .{}, &budget));
    }
}

const CertificateDecodeSite = enum {
    identity_flags,
    obligation_reserved,
    ir_flags,
    ir_reserved,
    ir_aux,
    evidence_reserved,
    evidence_rule,
    witness_reserved,
    rewrite_reserved,
    trusted_reserved,
    solver_reserved,
    residual_reserved,
    invariant_reserved,
};

test "certificate record reserved sites and closed wire fields refuse nonzero bytes" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildAllSections(&buf);
    const Site = struct { site: CertificateDecodeSite, tag: SectionTag, offset: usize, value: u8, expected: DecodeError };
    const sites = [_]Site{
        .{ .site = .identity_flags, .tag = .identity, .offset = 192, .value = 0x02, .expected = error.ReservedFieldNonZero }, // C08
        .{ .site = .obligation_reserved, .tag = .obligations, .offset = 3, .value = 1, .expected = error.ReservedFieldNonZero },
        .{ .site = .ir_flags, .tag = .proof_ir, .offset = 6, .value = 0x02, .expected = error.ReservedFieldNonZero }, // C22
        .{ .site = .ir_reserved, .tag = .proof_ir, .offset = 7, .value = 1, .expected = error.ReservedFieldNonZero },
        .{ .site = .ir_aux, .tag = .proof_ir, .offset = 52, .value = 1, .expected = error.ReservedFieldNonZero }, // C13
        .{ .site = .evidence_reserved, .tag = .evidence, .offset = 5, .value = 1, .expected = error.ReservedFieldNonZero }, // C14
        .{ .site = .evidence_rule, .tag = .evidence, .offset = 6, .value = 0xff, .expected = error.UnknownEnumMember }, // C16
        .{ .site = .witness_reserved, .tag = .translation, .offset = 25, .value = 1, .expected = error.ReservedFieldNonZero }, // C15
        .{ .site = .rewrite_reserved, .tag = .rewrites, .offset = 2, .value = 1, .expected = error.ReservedFieldNonZero }, // C24
        .{ .site = .trusted_reserved, .tag = .trusted, .offset = 6, .value = 1, .expected = error.ReservedFieldNonZero }, // C23
        .{ .site = .solver_reserved, .tag = .solver, .offset = 6, .value = 1, .expected = error.ReservedFieldNonZero }, // C19
        .{ .site = .residual_reserved, .tag = .residual, .offset = 12, .value = 1, .expected = error.ReservedFieldNonZero }, // C17
        .{ .site = .invariant_reserved, .tag = .invariant, .offset = 22, .value = 1, .expected = error.ReservedFieldNonZero }, // C18
    };
    inline for (sites) |site| {
        var changed: [4096]u8 = undefined;
        @memcpy(changed[0..bytes.len], bytes);
        const section = testSection(bytes, site.tag);
        const record = section.payload + @as(usize, if (site.tag == .identity) 0 else 4);
        changed[record + site.offset] = site.value;
        var budget = Budget.init(.{});
        try testing.expectError(site.expected, decode(changed[0..bytes.len], .{}, &budget));
    }
    inline for (@typeInfo(CertificateDecodeSite).@"enum".fields) |field| {
        const site: CertificateDecodeSite = @enumFromInt(field.value);
        var driven = false;
        for (sites) |probe| {
            if (probe.site == site) driven = true;
        }
        try testing.expect(driven);
    }
}

test "table sections refuse slack bytes" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    const section = testSection(bytes, .graph);
    const end = section.payload + section.length;
    var changed: [4097]u8 = undefined;
    @memcpy(changed[0..end], bytes[0..end]);
    changed[end] = 0x5a;
    @memcpy(changed[end + 1 ..][0 .. bytes.len - end], bytes[end..]);
    std.mem.writeInt(u32, changed[section.start + 2 ..][0..4], @intCast(section.length + 1), .little);
    var budget = Budget.init(.{});
    try testing.expectError(error.SectionLengthMismatch, decode(changed[0 .. bytes.len + 1], .{}, &budget));
}

test "certificate section and record limits include the limit" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildAllSections(&buf);
    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{ .max_sections = 11, .max_graph_members = 8, .max_solver_queries = 1 }, &budget);
    try testing.expectEqual(@as(u32, 1), cert.solver.len());

    budget = Budget.init(.{});
    try testing.expectError(error.CountExceedsLimit, decode(bytes, .{ .max_solver_queries = 0 }, &budget));
    budget = Budget.init(.{});
    try testing.expectError(error.CountExceedsLimit, decode(bytes, .{ .max_sections = 10 }, &budget));
}

test "certificate section count past the limit is refused before reading sections" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildAllSections(&buf);
    var changed: [4096]u8 = undefined;
    @memcpy(changed[0..bytes.len], bytes);
    std.mem.writeInt(u16, changed[16..18], 12, .little);
    var budget = Budget.init(.{});
    try testing.expectError(error.CountExceedsLimit, decode(changed[0..bytes.len], .{ .max_sections = 11 }, &budget));
}

test "certificate decode charges table framing and every record" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildAllSections(&buf);
    var budget = Budget.init(.{ .max_work = 104 });
    const cert = try decode(bytes, .{}, &budget);
    try testing.expectEqual(@as(u64, 0), budget.remaining);
    try testing.expectError(error.Truncated, cert.invariants.get(cert.invariants.len()));

    budget = Budget.init(.{ .max_work = 103 });
    try testing.expectError(error.WorkBudgetExhausted, decode(bytes, .{}, &budget));
}

fn probeDecodeError(comptime expected: DecodeError) !void {
    @setRuntimeSafety(true);
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);

    // Every refusal starts from a certificate accepted by the public decoder.
    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);

    var mutated: [4097]u8 = undefined;
    @memcpy(mutated[0..bytes.len], bytes);
    budget = Budget.init(.{});

    switch (expected) {
        error.CertificateTooLarge => try testing.expectError(
            expected,
            decode(bytes, .{ .max_certificate_bytes = 8 }, &budget),
        ),
        error.Truncated => try testing.expectError(
            expected,
            decode(bytes[0..header_size], .{}, &budget),
        ),
        error.BadMagic => {
            mutated[0] +%= 1;
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.UnsupportedSchemaVersion => {
            mutated[8] +%= 1;
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.UnknownSectionTag => {
            std.mem.writeInt(u16, mutated[header_size..][0..2], 4242, .little);
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.DuplicateSection => {
            const obligations_header = sectionHeaderOffset(bytes, cert.obligations.bytes);
            std.mem.writeInt(
                u16,
                mutated[obligations_header..][0..2],
                @intFromEnum(SectionTag.graph),
                .little,
            );
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.MissingRequiredSection => {
            const evidence_header = sectionHeaderOffset(bytes, cert.evidence.bytes);
            std.mem.writeInt(u16, mutated[16..18], 4, .little);
            try testing.expectError(expected, decode(mutated[0..evidence_header], .{}, &budget));
        },
        error.TrailingData => {
            mutated[bytes.len] = 0xAA;
            try testing.expectError(expected, decode(mutated[0 .. bytes.len + 1], .{}, &budget));
        },
        error.SectionTooLarge => {
            std.mem.writeInt(
                u32,
                mutated[header_size + 2 ..][0..4],
                Limits.production.max_section_bytes + 1,
                .little,
            );
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.SectionLengthMismatch => {
            std.mem.writeInt(u32, mutated[header_size + 2 ..][0..4], identity_size - 1, .little);
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.CountExceedsLimit => try testing.expectError(
            expected,
            decode(bytes, .{ .max_graph_members = 2 }, &budget),
        ),
        error.UnknownEnumMember => {
            std.mem.writeInt(u16, mutated[10..12], 999, .little);
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.SectionNotCanonicallyOrdered => {
            const graph_header = sectionHeaderOffset(bytes, cert.graph.bytes);
            const obligations_header = sectionHeaderOffset(bytes, cert.obligations.bytes);
            const obligations_end = @intFromPtr(cert.obligations.bytes.ptr) -
                @intFromPtr(bytes.ptr) + cert.obligations.bytes.len;
            const graph_span = bytes[graph_header..obligations_header];
            const obligations_span = bytes[obligations_header..obligations_end];

            @memcpy(mutated[graph_header..][0..obligations_span.len], obligations_span);
            @memcpy(mutated[graph_header + obligations_span.len ..][0..graph_span.len], graph_span);
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.ReservedFieldNonZero => {
            const obligations_records = @intFromPtr(cert.obligations.bytes.ptr) - @intFromPtr(bytes.ptr);
            mutated[obligations_records + 3] = 0xFF;
            try testing.expectError(expected, decode(mutated[0..bytes.len], .{}, &budget));
        },
        error.WorkBudgetExhausted => {
            budget = Budget.init(.{ .max_work = 2 });
            try testing.expectError(expected, decode(bytes, .{}, &budget));
        },
    }
}

test "every decode error is observed through the public decoder" {
    inline for (@typeInfo(DecodeError).error_set.?) |member| {
        try probeDecodeError(@field(DecodeError, member.name));
    }
}

test "a truncated certificate rejects rather than reading past the end" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var cut: usize = header_size;
    while (cut < bytes.len) : (cut += 7) {
        var budget = Budget.init(.{});
        try testing.expectError(error.Truncated, decode(bytes[0..cut], .{}, &budget));
    }
}

fn isRecordTable(comptime T: type) bool {
    @setRuntimeSafety(true);
    return @typeInfo(T) == .@"struct" and @hasField(T, "count") and @hasField(T, "bytes");
}

/// The structural contract of an accepted certificate, checked without
/// re-encoding. Every record table lies inside the input buffer, an empty table
/// holds no bytes, an index past the count refuses, and every record either
/// decodes or refuses with a typed error: a typed refusal from `get` is a
/// valid outcome, an untyped failure or a panic is not.
fn expectStructurallyValid(input: []const u8, cert: Certificate) !void {
    @setRuntimeSafety(true);
    try testing.expectEqual(ps.schema_version, cert.schema_version);
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    inline for (@typeInfo(Certificate).@"struct".fields) |field| {
        if (comptime isRecordTable(field.type)) {
            const table = @field(cert, field.name);
            if (table.count == 0) {
                try testing.expectEqual(@as(usize, 0), table.bytes.len);
            } else {
                const start = @intFromPtr(table.bytes.ptr);
                try testing.expect(start >= input_start);
                try testing.expect(start + table.bytes.len <= input_end);
            }
            var index: u32 = 0;
            while (index < table.count) : (index += 1) {
                _ = table.get(index) catch continue;
            }
            try testing.expectError(error.Truncated, table.get(table.count));
        }
    }
}

test "a byte-mutation sweep of a valid certificate yields a typed error or a structurally valid value" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    try testing.expect(bytes.len > header_size);

    var work: [4097]u8 = undefined;
    var decoded: usize = 0;
    var rejected: usize = 0;
    var accepted: usize = 0;

    // 1. Flip each bit of each byte. Each mutant gets a fresh budget: a reused
    //    budget would run dry and turn every later mutant into exhaustion.
    var flip_count: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 1) {
        var bit: u3 = 0;
        while (true) : (bit += 1) {
            @memcpy(work[0..bytes.len], bytes);
            work[offset] ^= @as(u8, 1) << bit;
            const mutant = work[0..bytes.len];
            var budget = Budget.init(.{});
            decoded += 1;
            flip_count += 1;
            if (decode(mutant, .{}, &budget)) |cert| {
                accepted += 1;
                try expectStructurallyValid(mutant, cert);
            } else |_| {
                rejected += 1;
            }
            if (bit == 7) break;
        }
    }
    try testing.expectEqual(bytes.len * 8, flip_count);

    // 2. Truncate at every length below the full length. The header fixes the
    //    section count, so a prefix can never be a complete certificate.
    var cut: usize = 0;
    while (cut < bytes.len) : (cut += 1) {
        @memcpy(work[0..cut], bytes[0..cut]);
        var budget = Budget.init(.{});
        decoded += 1;
        if (decode(work[0..cut], .{}, &budget)) |_| {
            return error.TruncatedCertificateWasAccepted;
        } else |_| {
            rejected += 1;
        }
    }

    // 3. Extend by one trailing byte. The section count is fixed, so any extra
    //    byte is trailing data and must be refused.
    const extension = [_]u8{ 0x00, 0xFF };
    for (extension) |extra| {
        @memcpy(work[0..bytes.len], bytes);
        work[bytes.len] = extra;
        var budget = Budget.init(.{});
        decoded += 1;
        if (decode(work[0 .. bytes.len + 1], .{}, &budget)) |_| {
            return error.ExtendedCertificateWasAccepted;
        } else |err| {
            try testing.expectEqual(error.TrailingData, err);
            rejected += 1;
        }
    }

    // The floor: the sweep decoded exactly the mutants the fixture length
    // implies, so an empty or shrunken fixture cannot pass by checking nothing.
    const expected = bytes.len * 8 + bytes.len + extension.len;
    try testing.expectEqual(expected, decoded);
    try testing.expectEqual(decoded, accepted + rejected);
    // The decoder refuses some mutants, and accepts the ones that only move
    // bytes it does not constrain (digests); a sweep that did either alone
    // would prove a degenerate decoder.
    try testing.expect(rejected > 0);
    try testing.expect(accepted > 0);
}

test "every decode error maps to a distinct stable reason code" {
    const errors = @typeInfo(DecodeError).error_set.?;
    inline for (errors, 0..) |a_member, i| {
        inline for (errors, 0..) |b_member, j| {
            if (i == j) continue;
            const a = @field(DecodeError, a_member.name);
            const b = @field(DecodeError, b_member.name);
            try testing.expect(reasonFor(a) != reasonFor(b));
        }
    }
}

test "every decode error maps to its exact reason code" {
    // Distinctness alone passes a swap of two rows. These pairs are the public
    // contract an operator reads, so each one is pinned.
    const pairs = [_]struct { err: DecodeError, code: ReasonCode }{
        .{ .err = error.CertificateTooLarge, .code = .certificate_too_large },
        .{ .err = error.Truncated, .code = .truncated_input },
        .{ .err = error.BadMagic, .code = .bad_magic },
        .{ .err = error.UnsupportedSchemaVersion, .code = .unsupported_schema_version },
        .{ .err = error.UnknownSectionTag, .code = .unknown_section_tag },
        .{ .err = error.DuplicateSection, .code = .duplicate_section },
        .{ .err = error.MissingRequiredSection, .code = .missing_required_section },
        .{ .err = error.TrailingData, .code = .trailing_data },
        .{ .err = error.SectionTooLarge, .code = .section_too_large },
        .{ .err = error.SectionLengthMismatch, .code = .section_length_mismatch },
        .{ .err = error.CountExceedsLimit, .code = .count_exceeds_limit },
        .{ .err = error.UnknownEnumMember, .code = .unknown_enum_member },
        .{ .err = error.SectionNotCanonicallyOrdered, .code = .section_not_canonically_ordered },
        .{ .err = error.ReservedFieldNonZero, .code = .reserved_field_nonzero },
        .{ .err = error.WorkBudgetExhausted, .code = .work_budget_exhausted },
    };
    try testing.expectEqual(@typeInfo(DecodeError).error_set.?.len, pairs.len);
    for (pairs) |pair| try testing.expectEqual(pair.code, reasonFor(pair.err));
}

test "edge kinds grade and check consistently" {
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .proved), EdgeKind.proved.grade());
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .trusted), EdgeKind.trusted.grade());
    try testing.expect(EdgeKind.solver.checked());
    try testing.expect(!EdgeKind.tested.checked());
    // An answer of "not established" is an answer, and it grades nothing.
    try testing.expectEqual(@as(?verdict.AssuranceGrade, null), EdgeKind.not_established.grade());
    try testing.expect(!EdgeKind.not_established.checked());
}

test "the IR root folds the same way from a slice and from a decoded table" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);

    const ir = [_]IrNode{
        .{ .id = 0, .tag = .function, .parent = 0, .first_child = 1, .child_count = 1, .digest = fixture.digest(20) },
        .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = fixture.digest(21) },
    };
    const from_slice = irRootFromNodes(&ir);
    const from_table = try irRootFromTable(cert.ir);
    try testing.expectEqualSlices(u8, &from_slice, &from_table);

    // Changing any field of any node moves the root.
    var mutated = ir;
    mutated[1].tag = .plain;
    try testing.expect(!std.mem.eql(u8, &from_slice, &irRootFromNodes(&mutated)));
    mutated = ir;
    mutated[0].child_count = 0;
    try testing.expect(!std.mem.eql(u8, &from_slice, &irRootFromNodes(&mutated)));
    mutated = ir;
    mutated[0].digest[3] +%= 1;
    try testing.expect(!std.mem.eql(u8, &from_slice, &irRootFromNodes(&mutated)));
}

test "obligation order is total and canonical" {
    const a = Obligation{ .property = .response_total, .subject_kind = .function, .subject_id = 0 };
    const b = Obligation{ .property = .response_total, .subject_kind = .function, .subject_id = 1 };
    const c = Obligation{ .property = .results_checked, .subject_kind = .handler, .subject_id = 0 };
    try testing.expectEqual(std.math.Order.lt, Obligation.order(a, b));
    try testing.expectEqual(std.math.Order.lt, Obligation.order(b, c));
    try testing.expectEqual(std.math.Order.eq, Obligation.order(a, a));
    try testing.expectEqual(std.math.Order.gt, Obligation.order(c, a));
}
