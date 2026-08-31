//! Closed identities the acceptance kernel understands.
//!
//! Every alphabet here is exhaustive on purpose. A producer that names
//! something outside one of these enums is refused at the decoder rather than
//! carried into checking under a permissive default, so widening any of them is
//! a deliberate edit to this file and to the checker that consumes it.

const std = @import("std");

/// The certificate wire schema. Bumped for any layout change; the kernel checks
/// equality, never a range, so an older or newer certificate is refused with a
/// rebuild diagnostic instead of being reinterpreted.
pub const schema_version: u16 = 2;

/// The proof system a certificate claims to be written in. `zttp_pcc_v1` is the
/// initial small-kernel system: closed rules over the canonical proof IR, plus
/// translation witnesses down to the final optimized bytecode.
pub const ProofSystem = enum(u16) {
    zttp_pcc_v1 = 1,

    pub fn fromWire(value: u16) ?ProofSystem {
        return switch (value) {
            1 => .zttp_pcc_v1,
            else => null,
        };
    }
};

/// The semantics registry generation the producer compiled against. The
/// consumer pins the epochs it accepts; a certificate from a different epoch
/// describes a different meaning for the same opcodes and is not reinterpreted.
pub const semantics_epoch: u32 = 1;

/// Static safety properties a consumer can require of a handler.
///
/// This is the obligation alphabet. It is smaller than the compiler's property
/// list on purpose: a property only belongs here once the consumer can state
/// what obligation it induces and what evidence discharges it.
pub const Property = enum(u16) {
    /// Every path through the subject returns a Response.
    response_total = 1,
    /// Every Result-producing call has `.ok` checked before `.value`.
    results_checked = 2,
    /// No value carrying a secret or credential label reaches the response.
    no_secret_leakage = 3,
    /// No request-scoped state survives into the next request.
    state_isolated = 4,
    /// The handler answers the same way on every run for the same request.
    deterministic = 5,
    /// The handler performs no writing effect.
    read_only = 6,
    /// Re-running the handler after a partial failure is safe.
    retry_safe = 7,
    /// The inferred capability set sits inside the declared ceiling.
    capability_bounded = 8,

    pub fn fromWire(value: u16) ?Property {
        return switch (value) {
            1 => .response_total,
            2 => .results_checked,
            3 => .no_secret_leakage,
            4 => .state_isolated,
            5 => .deterministic,
            6 => .read_only,
            7 => .retry_safe,
            8 => .capability_bounded,
            else => null,
        };
    }

    /// Which proof-IR member an obligation for this property is about.
    ///
    /// Only `response_total` names a specific member: the entry function, which
    /// the consumer resolves from the IR itself rather than reading the
    /// producer's word for which node that is. Everything else is stated once
    /// about the handler.
    pub fn subjectIsEntryFunction(self: Property) bool {
        return switch (self) {
            .response_total => true,
            .results_checked,
            .no_secret_leakage,
            .state_isolated,
            .deterministic,
            .read_only,
            .retry_safe,
            .capability_bounded,
            => false,
        };
    }

    /// Whether the acceptance kernel re-derives this property itself, or takes
    /// the producer's disclosure for it.
    ///
    /// This is the ratchet. Every `false` here is a property a consumer accepts
    /// on somebody else's word, and moving one to `true` is the unit of work
    /// that shrinks the disclosed trusted boundary. `scripts/check-proof-ratchet.sh`
    /// pins the count in both directions: it fails when the count drops, and it
    /// fails when the published residual list stops matching this switch.
    pub fn consumerChecked(self: Property) bool {
        return switch (self) {
            // Totality is folded over the proof IR by the consumer and related
            // to the final bytecode by the translation witnesses.
            .response_total => true,
            // Disclosed. Each needs an analysis the kernel does not model: the
            // result-binding dataflow, the label propagation, and the effect
            // inference respectively. Promoting one means adding its rule to
            // the kernel and its members to the proof IR, not relabelling it.
            .results_checked,
            .no_secret_leakage,
            .state_isolated,
            .deterministic,
            .read_only,
            .retry_safe,
            .capability_bounded,
            => false,
        };
    }

    /// How many properties the consumer re-derives. The ratchet floor.
    pub fn consumerCheckedCount() usize {
        var count: usize = 0;
        inline for (@typeInfo(Property).@"enum".fields) |field| {
            const property: Property = @enumFromInt(field.value);
            if (property.consumerChecked()) count += 1;
        }
        return count;
    }

    pub fn name(self: Property) []const u8 {
        return switch (self) {
            .response_total => "response_total",
            .results_checked => "results_checked",
            .no_secret_leakage => "no_secret_leakage",
            .state_isolated => "state_isolated",
            .deterministic => "deterministic",
            .read_only => "read_only",
            .retry_safe => "retry_safe",
            .capability_bounded => "capability_bounded",
        };
    }
};

/// Small-kernel rules. Each one is a check the consumer performs itself over
/// data it holds; none of them reads a producer verdict.
///
/// The set is closed and every member is constructible from real source. A rule
/// the compiler cannot produce and no certificate can cite would advertise a
/// check that never runs, which is the shape of gate this repository has been
/// burned by before. `match` is deliberately absent: it is an expression in this
/// subset, so it can never be the construct that returns, and modelling it would
/// have added three node kinds and a rule that nothing could reach.
pub const Rule = enum(u16) {
    /// A `return` node discharges totality for itself.
    return_total = 1,
    /// A branch node is total when both arms are present and both are total.
    branch_both_arms_total = 2,
    /// A statement sequence is total when one of its statements is total.
    /// Everything after that statement is unreachable.
    sequence_member_total = 3,
    /// A loop body never establishes totality: the iterable can be empty.
    loop_never_total = 4,
    /// Each IR member occupies one contiguous range of final bytecode, and no
    /// two sibling ranges overlap.
    emission_contiguous = 5,
    /// Every jump a branch emitted resolves to the emitted start of the IR
    /// member it names as its target.
    jump_target_resolved = 6,
    /// A recorded peephole fusion replaced a known instruction pair with a
    /// known fused instruction.
    rewrite_peephole_fusion = 7,
    /// A recorded compaction shifted later offsets by one consistent delta.
    rewrite_compaction = 8,

    pub fn fromWire(value: u16) ?Rule {
        return switch (value) {
            1 => .return_total,
            2 => .branch_both_arms_total,
            3 => .sequence_member_total,
            4 => .loop_never_total,
            5 => .emission_contiguous,
            6 => .jump_target_resolved,
            7 => .rewrite_peephole_fusion,
            8 => .rewrite_compaction,
            else => null,
        };
    }

    /// Which stage the rule belongs to. A translation rule cited as proof of a
    /// source-level obligation, or the reverse, is a category error the checker
    /// refuses rather than silently accepts.
    pub fn family(self: Rule) RuleFamily {
        return switch (self) {
            .return_total,
            .branch_both_arms_total,
            .sequence_member_total,
            .loop_never_total,
            => .totality,
            .emission_contiguous,
            .jump_target_resolved,
            .rewrite_peephole_fusion,
            .rewrite_compaction,
            => .translation,
        };
    }
};

pub const RuleFamily = enum { totality, translation };

/// Proof-IR node tags the kernel can walk.
///
/// Six, which is what this subset's totality actually depends on: a function,
/// a statement sequence, a branch, a loop, a return, and a leaf for everything
/// else. `match` is an expression here and can never be the construct that
/// returns; a call is one too. Both collapse to `plain`, because a tag nothing
/// can produce is a tag no rule can be checked against.
pub const NodeTag = enum(u16) {
    function = 1,
    sequence = 2,
    branch = 3,
    loop_node = 4,
    return_node = 5,
    /// A statement or expression with no bearing on totality. Present so a
    /// sequence's shape is complete.
    plain = 6,

    pub fn fromWire(value: u16) ?NodeTag {
        return switch (value) {
            1 => .function,
            2 => .sequence,
            3 => .branch,
            4 => .loop_node,
            5 => .return_node,
            6 => .plain,
            else => null,
        };
    }
};

/// Why a semantic family is declared trusted rather than checked. The reason is
/// part of the theorem chain the certificate discloses, so it is a closed
/// alphabet and not free text.
pub const TrustReason = enum(u16) {
    /// The kernel has no rule for this family yet.
    not_modeled = 1,
    /// A rule exists but needs a solver the consumer did not run.
    solver_absent = 2,
    /// Only a finite corpus exercises it.
    corpus_only = 3,
    /// Assumed from outside the artifact (host OS, hardware, cryptography).
    external_axiom = 4,
    /// Deliberately deferred to follow-up work.
    deferred_family = 5,

    pub fn fromWire(value: u16) ?TrustReason {
        return switch (value) {
            1 => .not_modeled,
            2 => .solver_absent,
            3 => .corpus_only,
            4 => .external_axiom,
            5 => .deferred_family,
            else => null,
        };
    }
};

test "wire decoders refuse values outside the alphabet" {
    try std.testing.expectEqual(@as(?ProofSystem, null), ProofSystem.fromWire(0));
    try std.testing.expectEqual(@as(?ProofSystem, null), ProofSystem.fromWire(2));
    try std.testing.expectEqual(@as(?Property, null), Property.fromWire(0));
    try std.testing.expectEqual(@as(?Property, null), Property.fromWire(9));
    try std.testing.expectEqual(@as(?Rule, null), Rule.fromWire(9));
    try std.testing.expectEqual(@as(?NodeTag, null), NodeTag.fromWire(7));
    try std.testing.expectEqual(@as(?TrustReason, null), TrustReason.fromWire(6));
}

test "every alphabet member round trips through its wire decoder" {
    inline for (.{ ProofSystem, Property, Rule, NodeTag, TrustReason }) |T| {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            const member: T = @enumFromInt(field.value);
            try std.testing.expectEqual(@as(?T, member), T.fromWire(field.value));
        }
    }
}

test "the ratchet floor is met and the two halves partition the alphabet" {
    var checked: usize = 0;
    var disclosed: usize = 0;
    inline for (@typeInfo(Property).@"enum".fields) |field| {
        const p: Property = @enumFromInt(field.value);
        if (p.consumerChecked()) checked += 1 else disclosed += 1;
    }
    try std.testing.expectEqual(checked + disclosed, @typeInfo(Property).@"enum".fields.len);
    try std.testing.expectEqual(checked, Property.consumerCheckedCount());
    // A kernel that re-derives nothing is a kernel that checks nothing. The
    // floor is what stops the ratchet from being turned the wrong way by a
    // change that only meant to simplify.
    try std.testing.expect(checked >= 1);
    try std.testing.expect(Property.response_total.consumerChecked());
}

test "every property states its subject and names itself" {
    var entry_function_subjects: usize = 0;
    inline for (@typeInfo(Property).@"enum".fields) |field| {
        const p: Property = @enumFromInt(field.value);
        if (p.subjectIsEntryFunction()) entry_function_subjects += 1;
        try std.testing.expect(p.name().len > 0);
    }
    // Exactly one property is about a named IR member. If that stops being
    // true, obligation reconstruction has to change with it.
    try std.testing.expectEqual(@as(usize, 1), entry_function_subjects);
}

test "rule family is stated for every rule" {
    inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const r: Rule = @enumFromInt(field.value);
        _ = r.family();
    }
}
