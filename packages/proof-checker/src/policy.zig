//! The consumer's acceptance policy.
//!
//! This is the half of the theorem the producer does not own. It states which
//! proof systems and semantics epochs the consumer will read at all, which
//! properties it requires, and how strong the weakest edge under each may be.
//! A policy that requires nothing accepts everything, so an empty requirement
//! set is refused rather than treated as permissive.

const std = @import("std");
const ps = @import("proof_system.zig");
const limits_mod = @import("limits.zig");
const verdict = @import("verdict.zig");

const AssuranceGrade = verdict.AssuranceGrade;

pub const Requirement = struct {
    property: ps.Property,
    /// The weakest edge the consumer will accept for this property. `.proved`
    /// admits only kernel-checked evidence; `.trusted` admits a disclosure.
    min_grade: AssuranceGrade,
};

pub const Error = error{
    EmptyRequirementSet,
    EmptyProofSystemSet,
    EmptyEpochSet,
    DuplicateRequirement,
};

pub const Policy = struct {
    /// Proof systems this consumer reads. A certificate outside the set is
    /// refused without being interpreted.
    proof_systems: []const ps.ProofSystem,
    /// Semantics epochs this consumer pins. A different epoch gives the same
    /// opcodes a different meaning.
    semantics_epochs: []const u32,
    /// What the consumer requires. Never empty.
    required: []const Requirement,
    /// Whether a development artifact (ephemeral identity, unpinned runtime
    /// policy) may reach acceptance. Production says no.
    allow_development: bool = false,
    /// Whether a reconstructed solver query may discharge an obligation. This
    /// is an interim theorem-chain edge and is off by default.
    allow_solver_edges: bool = false,
    limits: limits_mod.Limits = .{},

    /// A policy is only meaningful once it asks for something. Callers run this
    /// before checking, and the checker runs it again so a hand-built policy
    /// cannot skip it.
    pub fn validate(self: Policy) Error!void {
        if (self.required.len == 0) return error.EmptyRequirementSet;
        if (self.proof_systems.len == 0) return error.EmptyProofSystemSet;
        if (self.semantics_epochs.len == 0) return error.EmptyEpochSet;
        for (self.required, 0..) |a, i| {
            for (self.required[i + 1 ..]) |b| {
                if (a.property == b.property) return error.DuplicateRequirement;
            }
        }
    }

    pub fn acceptsProofSystem(self: Policy, system: ps.ProofSystem) bool {
        for (self.proof_systems) |candidate| {
            if (candidate == system) return true;
        }
        return false;
    }

    pub fn acceptsEpoch(self: Policy, epoch: u32) bool {
        for (self.semantics_epochs) |candidate| {
            if (candidate == epoch) return true;
        }
        return false;
    }

    pub fn requirementFor(self: Policy, property: ps.Property) ?Requirement {
        for (self.required) |requirement| {
            if (requirement.property == property) return requirement;
        }
        return null;
    }

    /// Whether the policy asks about this property at all. Obligation
    /// reconstruction walks exactly this set, so a property the consumer does
    /// not require induces no obligation and cannot be smuggled in by the
    /// producer's supplied list.
    pub fn requires(self: Policy, property: ps.Property) bool {
        return self.requirementFor(property) != null;
    }
};

const default_proof_systems = [_]ps.ProofSystem{.zttp_pcc_v1};
const default_epochs = [_]u32{ps.semantics_epoch};

const production_requirements = [_]Requirement{
    // The kernel proves totality over the proof IR and re-checks the
    // translation down to the final bytecode, so the honest floor is the
    // translation edge, not the source-level proof alone.
    .{ .property = .response_total, .min_grade = .translation_validated },
    // These three are disclosed rather than kernel-checked today. The floor
    // says so out loud instead of implying a proof that does not exist.
    .{ .property = .results_checked, .min_grade = .tested },
    .{ .property = .no_secret_leakage, .min_grade = .tested },
    .{ .property = .capability_bounded, .min_grade = .tested },
};

/// The strict production policy: pinned system and epoch, no development
/// artifacts, no solver edges.
pub const production = Policy{
    .proof_systems = &default_proof_systems,
    .semantics_epochs = &default_epochs,
    .required = &production_requirements,
    .allow_development = false,
    .allow_solver_edges = false,
};

const development_requirements = [_]Requirement{
    .{ .property = .response_total, .min_grade = .trusted },
};

/// A permissive local policy. It can reach acceptance for a development
/// artifact, and callers must not present that result as production acceptance.
pub const development = Policy{
    .proof_systems = &default_proof_systems,
    .semantics_epochs = &default_epochs,
    .required = &development_requirements,
    .allow_development = true,
    .allow_solver_edges = false,
};

const testing = std.testing;

test "an empty policy is refused rather than treated as permissive" {
    const empty = Policy{
        .proof_systems = &default_proof_systems,
        .semantics_epochs = &default_epochs,
        .required = &.{},
    };
    try testing.expectError(error.EmptyRequirementSet, empty.validate());

    const no_system = Policy{
        .proof_systems = &.{},
        .semantics_epochs = &default_epochs,
        .required = &production_requirements,
    };
    try testing.expectError(error.EmptyProofSystemSet, no_system.validate());

    const no_epoch = Policy{
        .proof_systems = &default_proof_systems,
        .semantics_epochs = &.{},
        .required = &production_requirements,
    };
    try testing.expectError(error.EmptyEpochSet, no_epoch.validate());
}

test "a duplicated requirement is refused" {
    const dup = [_]Requirement{
        .{ .property = .response_total, .min_grade = .proved },
        .{ .property = .response_total, .min_grade = .trusted },
    };
    const policy = Policy{
        .proof_systems = &default_proof_systems,
        .semantics_epochs = &default_epochs,
        .required = &dup,
    };
    try testing.expectError(error.DuplicateRequirement, policy.validate());
}

test "the shipped presets validate" {
    try production.validate();
    try development.validate();
}

test "production refuses development artifacts and solver edges" {
    try testing.expect(!production.allow_development);
    try testing.expect(!production.allow_solver_edges);
    try testing.expect(development.allow_development);
}

test "policy pins its proof system and epoch" {
    try testing.expect(production.acceptsProofSystem(.zttp_pcc_v1));
    try testing.expect(production.acceptsEpoch(ps.semantics_epoch));
    try testing.expect(!production.acceptsEpoch(ps.semantics_epoch + 1));
}

test "requirement lookup drives what the consumer asks about" {
    try testing.expect(production.requires(.response_total));
    try testing.expect(!production.requires(.retry_safe));
    const requirement = production.requirementFor(.response_total).?;
    try testing.expectEqual(AssuranceGrade.translation_validated, requirement.min_grade);
}
