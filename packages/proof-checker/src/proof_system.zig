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
pub const schema_version: u16 = 1;

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

    /// Whether the property is stated about each function in the proof IR or
    /// once about the whole handler. The consumer uses this, not the producer's
    /// word, to decide how many obligations a requirement induces.
    pub fn scope(self: Property) Scope {
        return switch (self) {
            .response_total, .results_checked => .per_function,
            .no_secret_leakage,
            .state_isolated,
            .deterministic,
            .read_only,
            .retry_safe,
            .capability_bounded,
            => .handler,
        };
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

pub const Scope = enum { per_function, handler };

/// Small-kernel rules. Each one is a check the consumer performs itself over
/// data it holds; none of them reads a producer verdict.
pub const Rule = enum(u16) {
    /// A `return` node discharges totality for itself.
    return_total = 1,
    /// A branch node is total when both arms are total.
    branch_both_arms_total = 2,
    /// A statement sequence is total when its last statement is total.
    sequence_tail_total = 3,
    /// A `match` node is total when every arm is total and the scrutinee union
    /// is covered member by member, so no default arm is required.
    match_exhaustive_total = 4,
    /// A loop body never establishes totality: the iterable can be empty.
    loop_never_total = 5,
    /// A call is total when the callee's proof capsule states it.
    call_capsule_total = 6,
    /// Each IR member occupies one contiguous range of final bytecode.
    emission_contiguous = 7,
    /// A branch node's emitted jump resolves to the emitted start of the IR
    /// member it names as its target.
    jump_target_resolved = 8,
    /// A recorded peephole fusion replaced a known instruction pair.
    rewrite_peephole_fusion = 9,
    /// A recorded compaction shifted later offsets by one consistent delta.
    rewrite_compaction = 10,

    pub fn fromWire(value: u16) ?Rule {
        return switch (value) {
            1 => .return_total,
            2 => .branch_both_arms_total,
            3 => .sequence_tail_total,
            4 => .match_exhaustive_total,
            5 => .loop_never_total,
            6 => .call_capsule_total,
            7 => .emission_contiguous,
            8 => .jump_target_resolved,
            9 => .rewrite_peephole_fusion,
            10 => .rewrite_compaction,
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
            .sequence_tail_total,
            .match_exhaustive_total,
            .loop_never_total,
            .call_capsule_total,
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

/// Proof-IR node tags the kernel can walk. The producer lowers its own richer
/// IR into this alphabet; anything it cannot lower must be declared a trusted
/// edge rather than smuggled through as an unknown tag.
pub const NodeTag = enum(u16) {
    function = 1,
    sequence = 2,
    branch = 3,
    match_node = 4,
    match_arm = 5,
    loop_node = 6,
    return_node = 7,
    call = 8,
    /// A statement with no bearing on totality (declaration, expression
    /// statement). Present so a sequence's shape is complete.
    plain = 9,

    pub fn fromWire(value: u16) ?NodeTag {
        return switch (value) {
            1 => .function,
            2 => .sequence,
            3 => .branch,
            4 => .match_node,
            5 => .match_arm,
            6 => .loop_node,
            7 => .return_node,
            8 => .call,
            9 => .plain,
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
    try std.testing.expectEqual(@as(?Rule, null), Rule.fromWire(11));
    try std.testing.expectEqual(@as(?NodeTag, null), NodeTag.fromWire(10));
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

test "property scope is stated for every property" {
    inline for (@typeInfo(Property).@"enum".fields) |field| {
        const p: Property = @enumFromInt(field.value);
        _ = p.scope();
        try std.testing.expect(p.name().len > 0);
    }
}

test "rule family is stated for every rule" {
    inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const r: Rule = @enumFromInt(field.value);
        _ = r.family();
    }
}
