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

    pub fn fromWire(value: u16) ?SectionTag {
        return switch (value) {
            1 => .identity,
            2 => .graph,
            3 => .obligations,
            4 => .proof_ir,
            5 => .evidence,
            6 => .translation,
            7 => .rewrites,
            8 => .trusted,
            9 => .solver,
            else => null,
        };
    }

    pub fn required(self: SectionTag) bool {
        return switch (self) {
            .identity, .graph, .obligations, .proof_ir, .evidence => true,
            .translation, .rewrites, .trusted, .solver => false,
        };
    }
};

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

pub const identity_size = 97;

pub const Identity = struct {
    /// Root over the canonical executable graph.
    executable_root: [32]u8,
    /// Root over the canonical proof IR, which is itself a graph member.
    ir_root: [32]u8,
    /// Digest of the serialized handler contract.
    contract_digest: [32]u8,
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
        return switch (value) {
            1 => .handler,
            2 => .function,
            else => null,
        };
    }
};

pub const Obligation = struct {
    property: ps.Property,
    subject_kind: SubjectKind,
    subject_id: u32,

    /// Canonical obligation order: property, then subject kind, then subject id.
    pub fn order(a: Obligation, b: Obligation) std.math.Order {
        const pa = @intFromEnum(a.property);
        const pb = @intFromEnum(b.property);
        if (pa != pb) return std.math.order(pa, pb);
        const ka = @intFromEnum(a.subject_kind);
        const kb = @intFromEnum(b.subject_kind);
        if (ka != kb) return std.math.order(ka, kb);
        return std.math.order(a.subject_id, b.subject_id);
    }
};

pub const ir_record_size = 52;

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
        return switch (value) {
            1 => .proved,
            2 => .translation_validated,
            3 => .solver,
            4 => .tested,
            5 => .trusted,
            6 => .not_established,
            else => null,
        };
    }

    /// The grade an edge of this kind contributes when it holds. An edge that
    /// establishes nothing contributes no grade.
    pub fn grade(self: EdgeKind) ?verdict.AssuranceGrade {
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
        return switch (value) {
            1 => .emission,
            2 => .jump,
            else => null,
        };
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
        return switch (value) {
            1 => .node,
            2 => .opcode,
            else => null,
        };
    }
};

pub const TrustedEdge = struct {
    family: TrustedFamily,
    member_id: u16,
    reason: ps.TrustReason,
    grade: verdict.AssuranceGrade,
};

pub const solver_record_size = 8;

pub const SolverQueryKind = enum(u16) {
    /// The lowering of one opcode agrees with its denotation. One kind, because
    /// one is what a producer can construct today; a second would advertise a
    /// query shape nothing emits.
    opcode_equivalence = 1,

    pub fn fromWire(value: u16) ?SolverQueryKind {
        return switch (value) {
            1 => .opcode_equivalence,
            else => null,
        };
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
    return struct {
        const Self = @This();

        bytes: []const u8 = &.{},
        count: u32 = 0,

        pub fn len(self: Self) u32 {
            return self.count;
        }

        pub fn get(self: Self, index: u32) DecodeError!Record {
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

fn u16At(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn u32At(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn i32At(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn requireZero(bytes: []const u8) DecodeError!void {
    for (bytes) |byte| {
        if (byte != 0) return error.ReservedFieldNonZero;
    }
}

fn decodeRecord(comptime Record: type, bytes: []const u8) DecodeError!Record {
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
            break :blk IrNode{
                .id = u32At(bytes, 0),
                .tag = tag,
                .is_handler = flags & 0x01 != 0,
                .parent = u32At(bytes, 8),
                .first_child = u32At(bytes, 12),
                .child_count = u32At(bytes, 16),
                .digest = digest,
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
};

fn countLimitFor(tag: SectionTag, limits: Limits) u32 {
    return switch (tag) {
        .identity => 1,
        .graph => limits.max_graph_members,
        .obligations => limits.max_obligations,
        .proof_ir => limits.max_ir_nodes,
        .evidence => limits.max_evidence,
        .translation => limits.max_witnesses,
        .rewrites => limits.max_rewrites,
        .trusted => limits.max_trusted_edges,
        .solver => limits.max_solver_queries,
    };
}

fn recordSizeFor(tag: SectionTag) usize {
    return switch (tag) {
        .identity => identity_size,
        .graph => graph_record_size,
        .obligations => obligation_record_size,
        .proof_ir => ir_record_size,
        .evidence => evidence_record_size,
        .translation => witness_record_size,
        .rewrites => rewrite_record_size,
        .trusted => trusted_record_size,
        .solver => solver_record_size,
    };
}

/// Bounded decode. Validates the container, the section table, every record's
/// fixed shape, and every enum-bearing field, then returns cursors into `bytes`.
pub fn decode(bytes: []const u8, limits: Limits, budget: *Budget) DecodeError!Certificate {
    if (bytes.len > limits.max_certificate_bytes) return error.CertificateTooLarge;
    if (bytes.len < header_size) return error.Truncated;
    try budget.spend(bytes.len / 64 + 1);

    if (std.mem.readInt(u64, bytes[0..8], .little) != magic) return error.BadMagic;
    const schema = u16At(bytes, 8);
    if (schema != ps.schema_version) return error.UnsupportedSchemaVersion;
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
    if (tag == .identity) {
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
        const flags = payload[96];
        if (flags & ~@as(u8, 0x01) != 0) return error.ReservedFieldNonZero;
        identity.development = (flags & 0x01) != 0;
        cert.identity = identity;
        return;
    }

    if (payload.len < 4) return error.SectionLengthMismatch;
    const count = u32At(payload, 0);
    if (count > countLimitFor(tag, limits)) return error.CountExceedsLimit;
    const record_size = recordSizeFor(tag);
    const expected = 4 + @as(usize, count) * record_size;
    if (payload.len != expected) return error.SectionLengthMismatch;
    const records = payload[4..];
    try budget.spend(@as(u64, count) + 1);

    switch (tag) {
        .identity => unreachable,
        .graph => cert.graph = .{ .bytes = records, .count = count },
        .obligations => cert.obligations = .{ .bytes = records, .count = count },
        .proof_ir => cert.ir = .{ .bytes = records, .count = count },
        .evidence => cert.evidence = .{ .bytes = records, .count = count },
        .translation => cert.translation = .{ .bytes = records, .count = count },
        .rewrites => cert.rewrites = .{ .bytes = records, .count = count },
        .trusted => cert.trusted = .{ .bytes = records, .count = count },
        .solver => cert.solver = .{ .bytes = records, .count = count },
    }

    // Validate every enum-bearing field now, so a caller walking the table
    // later cannot be surprised by a member outside the alphabet.
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try budget.spend(1);
        switch (tag) {
            .identity => unreachable,
            .graph => _ = try cert.graph.get(i),
            .obligations => _ = try cert.obligations.get(i),
            .proof_ir => _ = try cert.ir.get(i),
            .evidence => _ = try cert.evidence.get(i),
            .translation => _ = try cert.translation.get(i),
            .rewrites => _ = try cert.rewrites.get(i),
            .trusted => _ = try cert.trusted.get(i),
            .solver => _ = try cert.solver.get(i),
        }
    }
}

/// Domain separator for the proof-IR root.
pub const ir_root_domain = "zttp-proof-ir-root-v2";

fn foldIrNode(hasher: *std.crypto.hash.sha2.Sha256, node: IrNode) void {
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
}

/// Fold a proof-IR node list into one root.
///
/// This is the only definition of that fold. The producer calls it too, through
/// the same package, so a certificate's `ir_root` and the value the consumer
/// recomputes cannot come from two formulas that drifted apart.
pub fn irRootFromNodes(nodes: []const IrNode) [32]u8 {
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
    proof_system: ps.ProofSystem = .zttp_pcc_v1,
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
};

pub const EncodeError = error{BufferTooSmall};

/// Bytes `encode` needs for `parts`.
pub fn encodedSize(parts: Parts) usize {
    var total: usize = header_size;
    total += section_header_size + identity_size;
    total += section_header_size + 4 + parts.graph.len * graph_record_size;
    total += section_header_size + 4 + parts.obligations.len * obligation_record_size;
    total += section_header_size + 4 + parts.ir.len * ir_record_size;
    total += section_header_size + 4 + parts.evidence.len * evidence_record_size;
    if (parts.translation.len > 0) total += section_header_size + 4 + parts.translation.len * witness_record_size;
    if (parts.rewrites.len > 0) total += section_header_size + 4 + parts.rewrites.len * rewrite_record_size;
    if (parts.trusted.len > 0) total += section_header_size + 4 + parts.trusted.len * trusted_record_size;
    if (parts.solver.len > 0) total += section_header_size + 4 + parts.solver.len * solver_record_size;
    return total;
}

const Cursor = struct {
    buf: []u8,
    at: usize = 0,

    fn need(self: *Cursor, n: usize) EncodeError![]u8 {
        if (self.at + n > self.buf.len) return error.BufferTooSmall;
        const slice = self.buf[self.at..][0..n];
        self.at += n;
        return slice;
    }

    fn u8At(self: *Cursor, value: u8) EncodeError!void {
        (try self.need(1))[0] = value;
    }

    fn u16At(self: *Cursor, value: u16) EncodeError!void {
        std.mem.writeInt(u16, (try self.need(2))[0..2], value, .little);
    }

    fn u32At(self: *Cursor, value: u32) EncodeError!void {
        std.mem.writeInt(u32, (try self.need(4))[0..4], value, .little);
    }

    fn i32At(self: *Cursor, value: i32) EncodeError!void {
        std.mem.writeInt(i32, (try self.need(4))[0..4], value, .little);
    }

    fn u64At(self: *Cursor, value: u64) EncodeError!void {
        std.mem.writeInt(u64, (try self.need(8))[0..8], value, .little);
    }

    fn zeros(self: *Cursor, n: usize) EncodeError!void {
        @memset(try self.need(n), 0);
    }

    fn raw(self: *Cursor, bytes: []const u8) EncodeError!void {
        @memcpy(try self.need(bytes.len), bytes);
    }
};

fn sectionCount(parts: Parts) u16 {
    var count: u16 = 5;
    if (parts.translation.len > 0) count += 1;
    if (parts.rewrites.len > 0) count += 1;
    if (parts.trusted.len > 0) count += 1;
    if (parts.solver.len > 0) count += 1;
    return count;
}

/// Encode `parts` into `out` in canonical form. Sections are written in
/// ascending tag order; empty optional sections are omitted rather than written
/// with a zero count, so one set of parts has exactly one encoding.
pub fn encode(parts: Parts, out: []u8) EncodeError![]u8 {
    var cursor = Cursor{ .buf = out };
    try cursor.u64At(magic);
    try cursor.u16At(ps.schema_version);
    try cursor.u16At(@intFromEnum(parts.proof_system));
    try cursor.u32At(parts.semantics_epoch);
    try cursor.u16At(sectionCount(parts));

    try cursor.u16At(@intFromEnum(SectionTag.identity));
    try cursor.u32At(identity_size);
    try cursor.raw(&parts.identity.executable_root);
    try cursor.raw(&parts.identity.ir_root);
    try cursor.raw(&parts.identity.contract_digest);
    try cursor.u8At(if (parts.identity.development) 0x01 else 0x00);

    try writeTable(&cursor, .graph, parts.graph.len, graph_record_size);
    for (parts.graph) |member| {
        try cursor.u16At(@intFromEnum(member.kind));
        try cursor.u32At(member.ordinal);
        try cursor.raw(&member.digest);
    }

    try writeTable(&cursor, .obligations, parts.obligations.len, obligation_record_size);
    for (parts.obligations) |obligation| {
        try cursor.u16At(@intFromEnum(obligation.property));
        try cursor.u8At(@intFromEnum(obligation.subject_kind));
        try cursor.zeros(1);
        try cursor.u32At(obligation.subject_id);
    }

    try writeTable(&cursor, .proof_ir, parts.ir.len, ir_record_size);
    for (parts.ir) |node| {
        try cursor.u32At(node.id);
        try cursor.u16At(@intFromEnum(node.tag));
        try cursor.u8At(@intFromBool(node.is_handler));
        try cursor.zeros(1);
        try cursor.u32At(node.parent);
        try cursor.u32At(node.first_child);
        try cursor.u32At(node.child_count);
        try cursor.raw(&node.digest);
    }

    try writeTable(&cursor, .evidence, parts.evidence.len, evidence_record_size);
    for (parts.evidence) |entry| {
        try cursor.u32At(entry.obligation_index);
        try cursor.u8At(@intFromEnum(entry.edge));
        try cursor.zeros(1);
        try cursor.u16At(if (entry.rule) |rule| @intFromEnum(rule) else 0);
        try cursor.u32At(entry.node_id);
        try cursor.u32At(entry.aux);
    }

    if (parts.translation.len > 0) {
        try writeTable(&cursor, .translation, parts.translation.len, witness_record_size);
        for (parts.translation) |witness| {
            try cursor.u32At(witness.ir_node);
            try cursor.u32At(witness.code_start);
            try cursor.u32At(witness.code_len);
            try cursor.u32At(witness.target_ir);
            try cursor.u32At(witness.target_offset);
            try cursor.u32At(witness.scope_ir_node);
            try cursor.u8At(@intFromEnum(witness.kind));
            try cursor.zeros(3);
        }
    }

    if (parts.rewrites.len > 0) {
        try writeTable(&cursor, .rewrites, parts.rewrites.len, rewrite_record_size);
        for (parts.rewrites) |rewrite| {
            try cursor.u16At(@intFromEnum(rewrite.rule));
            try cursor.zeros(2);
            try cursor.u32At(rewrite.before_offset);
            try cursor.u32At(rewrite.before_len);
            try cursor.u32At(rewrite.after_offset);
            try cursor.u32At(rewrite.after_len);
            try cursor.i32At(rewrite.delta);
        }
    }

    if (parts.trusted.len > 0) {
        try writeTable(&cursor, .trusted, parts.trusted.len, trusted_record_size);
        for (parts.trusted) |edge| {
            try cursor.u8At(@intFromEnum(edge.family));
            try cursor.u8At(edge.grade.toWire());
            try cursor.u16At(edge.member_id);
            try cursor.u16At(@intFromEnum(edge.reason));
            try cursor.zeros(2);
        }
    }

    if (parts.solver.len > 0) {
        try writeTable(&cursor, .solver, parts.solver.len, solver_record_size);
        for (parts.solver) |query| {
            try cursor.u32At(query.obligation_index);
            try cursor.u16At(@intFromEnum(query.query_kind));
            try cursor.zeros(2);
        }
    }

    return out[0..cursor.at];
}

fn writeTable(cursor: *Cursor, tag: SectionTag, count: usize, record_size: usize) EncodeError!void {
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
            return graph_mod.Member.order(a, b) == .lt;
        }
    }.lt);
    return members;
}

fn buildMinimal(buf: []u8) ![]u8 {
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

test "a minimal certificate round trips through the canonical codec" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);

    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);
    try testing.expectEqual(ps.schema_version, cert.schema_version);
    try testing.expectEqual(ps.ProofSystem.zttp_pcc_v1, cert.proof_system);
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

test "bad magic, wrong schema, and trailing data each reject" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var budget = Budget.init(.{});

    var mutated: [4096]u8 = undefined;
    @memcpy(mutated[0..bytes.len], bytes);
    mutated[0] +%= 1;
    try testing.expectError(error.BadMagic, decode(mutated[0..bytes.len], .{}, &budget));

    @memcpy(mutated[0..bytes.len], bytes);
    mutated[8] +%= 1;
    budget = Budget.init(.{});
    try testing.expectError(error.UnsupportedSchemaVersion, decode(mutated[0..bytes.len], .{}, &budget));

    @memcpy(mutated[0..bytes.len], bytes);
    mutated[bytes.len] = 0xAA;
    budget = Budget.init(.{});
    try testing.expectError(error.TrailingData, decode(mutated[0 .. bytes.len + 1], .{}, &budget));
}

test "an unknown proof system rejects" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var mutated: [4096]u8 = undefined;
    @memcpy(mutated[0..bytes.len], bytes);
    std.mem.writeInt(u16, mutated[10..12], 999, .little);
    var budget = Budget.init(.{});
    try testing.expectError(error.UnknownEnumMember, decode(mutated[0..bytes.len], .{}, &budget));
}

test "an unknown section tag rejects" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var mutated: [4096]u8 = undefined;
    @memcpy(mutated[0..bytes.len], bytes);
    // First section header sits right after the fixed header.
    std.mem.writeInt(u16, mutated[header_size..][0..2], 4242, .little);
    var budget = Budget.init(.{});
    try testing.expectError(error.UnknownSectionTag, decode(mutated[0..bytes.len], .{}, &budget));
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

test "a missing required section rejects" {
    const members = minimalGraph();
    const ir = [_]IrNode{
        .{ .id = 0, .tag = .function, .parent = 0, .first_child = 0, .child_count = 0, .digest = fixture.digest(20) },
    };
    // Hand-build a container that omits the evidence section but claims four.
    var buf: [4096]u8 = undefined;
    var cursor = Cursor{ .buf = &buf };
    try cursor.u64At(magic);
    try cursor.u16At(ps.schema_version);
    try cursor.u16At(@intFromEnum(ps.ProofSystem.zttp_pcc_v1));
    try cursor.u32At(ps.semantics_epoch);
    try cursor.u16At(4);
    try cursor.u16At(@intFromEnum(SectionTag.identity));
    try cursor.u32At(identity_size);
    try cursor.zeros(identity_size);
    try writeTable(&cursor, .graph, members.len, graph_record_size);
    for (members) |member| {
        try cursor.u16At(@intFromEnum(member.kind));
        try cursor.u32At(member.ordinal);
        try cursor.raw(&member.digest);
    }
    try writeTable(&cursor, .obligations, 0, obligation_record_size);
    try writeTable(&cursor, .proof_ir, ir.len, ir_record_size);
    for (ir) |node| {
        try cursor.u32At(node.id);
        try cursor.u16At(@intFromEnum(node.tag));
        try cursor.zeros(2);
        try cursor.u32At(node.parent);
        try cursor.u32At(node.first_child);
        try cursor.u32At(node.child_count);
        try cursor.raw(&node.digest);
    }
    var budget = Budget.init(.{});
    try testing.expectError(error.MissingRequiredSection, decode(buf[0..cursor.at], .{}, &budget));
}

test "reserved bytes must be zero" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    // The obligations section's reserved byte: find it by decoding first.
    var budget = Budget.init(.{});
    const cert = try decode(bytes, .{}, &budget);
    const offset = @intFromPtr(cert.obligations.bytes.ptr) - @intFromPtr(bytes.ptr);
    var mutated: [4096]u8 = undefined;
    @memcpy(mutated[0..bytes.len], bytes);
    mutated[offset + 3] = 0xFF;
    budget = Budget.init(.{});
    try testing.expectError(error.ReservedFieldNonZero, decode(mutated[0..bytes.len], .{}, &budget));
}

test "a count over the limit rejects before the records are walked" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var budget = Budget.init(.{});
    try testing.expectError(
        error.CountExceedsLimit,
        decode(bytes, .{ .max_graph_members = 2 }, &budget),
    );
}

test "an oversized certificate rejects before decoding" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var budget = Budget.init(.{});
    try testing.expectError(
        error.CertificateTooLarge,
        decode(bytes, .{ .max_certificate_bytes = 8 }, &budget),
    );
}

test "a starved work budget rejects rather than running to completion" {
    var buf: [4096]u8 = undefined;
    const bytes = try buildMinimal(&buf);
    var budget = Budget.init(.{ .max_work = 2 });
    try testing.expectError(error.WorkBudgetExhausted, decode(bytes, .{}, &budget));
}

test "every decode error maps to a distinct stable reason code" {
    const errors = [_]DecodeError{
        error.CertificateTooLarge,
        error.Truncated,
        error.BadMagic,
        error.UnsupportedSchemaVersion,
        error.UnknownSectionTag,
        error.DuplicateSection,
        error.MissingRequiredSection,
        error.TrailingData,
        error.SectionTooLarge,
        error.SectionLengthMismatch,
        error.CountExceedsLimit,
        error.UnknownEnumMember,
        error.SectionNotCanonicallyOrdered,
        error.ReservedFieldNonZero,
        error.WorkBudgetExhausted,
    };
    for (errors, 0..) |a, i| {
        for (errors, 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(reasonFor(a) != reasonFor(b));
        }
    }
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
