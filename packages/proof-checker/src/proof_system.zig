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
pub const schema_version: u16 = 5;

/// The proof system a certificate claims to be written in. The only accepted
/// system carries closed rules over the canonical proof IR, translation
/// witnesses down to the final optimized bytecode, and residual guards.
pub const ProofSystem = enum(u16) {
    /// Residual guard obligations cover operations whose resource the compiler
    /// could not resolve. An authoritative runtime sink checks them against a
    /// bound capability policy.
    zttp_pcc_v3 = 3,

    pub fn fromWire(value: u16) ?ProofSystem {
        @setRuntimeSafety(true);
        return std.enums.fromInt(ProofSystem, value);
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
        @setRuntimeSafety(true);
        return std.enums.fromInt(Property, value);
    }

    /// Which proof-IR member an obligation for this property is about.
    ///
    /// Only `response_total` names a specific member: the entry function, which
    /// the consumer resolves from the IR itself rather than reading the
    /// producer's word for which node that is. Everything else is stated once
    /// about the handler.
    pub fn subjectIsEntryFunction(self: Property) bool {
        @setRuntimeSafety(true);
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
        @setRuntimeSafety(true);
        return switch (self) {
            // Totality is folded over the proof IR by the consumer and related
            // to the final bytecode by the translation witnesses.
            .response_total => true,
            // The result-binding dataflow is re-derived over the Result events
            // in the proof IR, for every non-refused claim at any edge kind.
            .results_checked => true,
            // Disclosed. Each needs an analysis the kernel does not model: the
            // label propagation, the state analysis, and the effect inference.
            // Promoting one means adding its rule to the kernel and its
            // members to the proof IR, not relabelling it.
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
        @setRuntimeSafety(true);
        var count: usize = 0;
        inline for (@typeInfo(Property).@"enum".field_names) |field| {
            const property: Property = @fromBackingInt(@intCast(@backingInt(@field(Property, field))));
            if (property.consumerChecked()) count += 1;
        }
        return count;
    }

    pub fn name(self: Property) []const u8 {
        @setRuntimeSafety(true);
        return @tagName(self);
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
    /// Every read of a Result value is dominated by an `.ok` guard of the
    /// right polarity, over a single definition of the binding.
    result_reads_guarded = 9,

    pub fn fromWire(value: u16) ?Rule {
        @setRuntimeSafety(true);
        return std.enums.fromInt(Rule, value);
    }

    /// Which stage the rule belongs to. A translation rule cited as proof of a
    /// source-level obligation, or the reverse, is a category error the checker
    /// refuses rather than silently accepts.
    pub fn family(self: Rule) RuleFamily {
        @setRuntimeSafety(true);
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
            .result_reads_guarded => .results,
        };
    }
};

pub const RuleFamily = enum { totality, translation, results };

/// Proof-IR node tags the kernel can walk.
///
/// Seven tags for totality and residual reconstruction (six totality shapes and
/// one unresolved capability call), then six result-event tags. The result tags
/// carry a binding ordinal in `aux` for the `results_checked` rule.
pub const NodeTag = enum(u16) {
    function = 1,
    sequence = 2,
    branch = 3,
    loop_node = 4,
    return_node = 5,
    /// A statement or expression with no bearing on totality. Present so a
    /// sequence's shape is complete.
    plain = 6,
    /// A call to a capability export whose resource the compiler could not
    /// resolve. It contributes nothing to totality; it exists so the consumer
    /// can count the guarded operations for itself instead of reading the
    /// producer's list of them.
    capability_call = 7,
    // Wire ordinal 8 is retired with protected-ledger invariants.
    /// `const b = <Result export call>`. `aux` is the binding ordinal.
    result_def = 9,
    /// The `if` condition is exactly `b.ok`. `aux` is the binding ordinal.
    result_guard_ok = 10,
    /// The `if` condition is exactly `!b.ok`. `aux` is the binding ordinal.
    result_guard_err = 11,
    /// A read of `.value` or `.unwrap` on binding `aux`.
    result_read_ok = 12,
    /// A read of `.error` or `.errors` on binding `aux`.
    result_read_err = 13,
    /// Any other use of binding `aux`. The kernel refuses it.
    result_escape = 14,

    pub fn fromWire(value: u16) ?NodeTag {
        @setRuntimeSafety(true);
        return std.enums.fromInt(NodeTag, value);
    }

    /// Whether a node of this tag carries a catalog index in its `aux` field.
    /// Every other tag must leave it zero, so the field cannot become a place
    /// to smuggle data past the decoder.
    pub fn usesAux(self: NodeTag) bool {
        @setRuntimeSafety(true);
        return switch (self) {
            .capability_call,
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => true,
            .function, .sequence, .branch, .loop_node, .return_node, .plain => false,
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
        @setRuntimeSafety(true);
        return std.enums.fromInt(TrustReason, value);
    }
};

test "wire decoders refuse values outside the alphabet" {
    try std.testing.expectEqual(@as(u16, 5), schema_version);
    try std.testing.expectEqual(@as(?ProofSystem, null), ProofSystem.fromWire(1));
    try std.testing.expectEqual(@as(?ProofSystem, null), ProofSystem.fromWire(0));
    try std.testing.expectEqual(@as(?ProofSystem, null), ProofSystem.fromWire(2));
    try std.testing.expectEqual(@as(?Property, null), Property.fromWire(0));
    try std.testing.expectEqual(@as(?Property, null), Property.fromWire(9));
    try std.testing.expectEqual(@as(?Rule, .result_reads_guarded), Rule.fromWire(9));
    try std.testing.expectEqual(@as(?Rule, null), Rule.fromWire(10));
    try std.testing.expectEqual(@as(?NodeTag, .capability_call), NodeTag.fromWire(7));
    try std.testing.expectEqual(@as(?NodeTag, null), NodeTag.fromWire(8));
    try std.testing.expectEqual(@as(?NodeTag, .result_def), NodeTag.fromWire(9));
    try std.testing.expectEqual(@as(?NodeTag, .result_escape), NodeTag.fromWire(14));
    try std.testing.expectEqual(@as(?NodeTag, null), NodeTag.fromWire(15));
    try std.testing.expectEqual(@as(?TrustReason, null), TrustReason.fromWire(6));
}

test "every alphabet member round trips through its wire decoder" {
    inline for (.{ ProofSystem, Property, Rule, NodeTag, TrustReason }) |T| {
        inline for (@typeInfo(T).@"enum".field_names) |field| {
            const member: T = @fromBackingInt(@intCast(@backingInt(@field(T, field))));
            try std.testing.expectEqual(@as(?T, member), T.fromWire(@backingInt(@field(T, field))));
        }
    }
}

test "the ratchet floor is met and the two halves partition the alphabet" {
    var checked: usize = 0;
    var disclosed: usize = 0;
    inline for (@typeInfo(Property).@"enum".field_names) |field| {
        const p: Property = @fromBackingInt(@intCast(@backingInt(@field(Property, field))));
        if (p.consumerChecked()) checked += 1 else disclosed += 1;
    }
    try std.testing.expectEqual(checked + disclosed, @typeInfo(Property).@"enum".field_names.len);
    try std.testing.expectEqual(checked, Property.consumerCheckedCount());
    // A kernel that re-derives nothing is a kernel that checks nothing. The
    // floor is what stops the ratchet from being turned the wrong way by a
    // change that only meant to simplify.
    try std.testing.expect(checked >= 1);
    try std.testing.expect(Property.response_total.consumerChecked());
    try std.testing.expect(Property.results_checked.consumerChecked());
    try std.testing.expectEqual(@as(usize, 2), checked);
    inline for (.{
        Property.no_secret_leakage,
        Property.state_isolated,
        Property.deterministic,
        Property.read_only,
        Property.retry_safe,
        Property.capability_bounded,
    }) |property| try std.testing.expect(!property.consumerChecked());
}

test "every property states its subject and names itself" {
    var entry_function_subjects: usize = 0;
    inline for (@typeInfo(Property).@"enum".field_names) |field| {
        const p: Property = @fromBackingInt(@intCast(@backingInt(@field(Property, field))));
        if (p.subjectIsEntryFunction()) entry_function_subjects += 1;
        try std.testing.expectEqualStrings(field, p.name());
    }
    // Exactly one property is about a named IR member. If that stops being
    // true, obligation reconstruction has to change with it.
    try std.testing.expectEqual(@as(usize, 1), entry_function_subjects);
}

test "rule family is stated for every rule" {
    inline for (.{
        Rule.return_total,
        Rule.branch_both_arms_total,
        Rule.sequence_member_total,
        Rule.loop_never_total,
    }) |rule| try std.testing.expectEqual(RuleFamily.totality, rule.family());
    inline for (.{
        Rule.emission_contiguous,
        Rule.jump_target_resolved,
        Rule.rewrite_peephole_fusion,
        Rule.rewrite_compaction,
    }) |rule| try std.testing.expectEqual(RuleFamily.translation, rule.family());
}

test "the result rule is in the results family" {
    try std.testing.expectEqual(RuleFamily.results, Rule.result_reads_guarded.family());
}

test "only the capability call and the six result tags carry an aux ordinal" {
    inline for (.{
        NodeTag.capability_call,
        NodeTag.result_def,
        NodeTag.result_guard_ok,
        NodeTag.result_guard_err,
        NodeTag.result_read_ok,
        NodeTag.result_read_err,
        NodeTag.result_escape,
    }) |tag| try std.testing.expect(tag.usesAux());
    inline for (.{
        NodeTag.function,
        NodeTag.sequence,
        NodeTag.branch,
        NodeTag.loop_node,
        NodeTag.return_node,
        NodeTag.plain,
    }) |tag| try std.testing.expect(!tag.usesAux());
}
