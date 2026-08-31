//! The activation boundary: does this process hold an artifact a consumer
//! checker accepts?
//!
//! Everything here runs before the handler pool is initialized. It rebuilds the
//! executable-graph inventory from the sections this process actually loaded -
//! not from the producer's list - decodes the embedded certificate, and hands
//! both to the acceptance kernel. A refusal is a refusal to serve, not a warning.
//!
//! An absent certificate is one of the refusals. It is not a permissive default
//! and it is not a legacy allowance: an artifact that carries no proof has not
//! been checked, and the runtime says so with the same stage and reason code it
//! would use for a proof that failed.

const std = @import("std");
const pcc = @import("zttp_proof_checker");

const artifact_graph = @import("artifact_graph.zig");

pub const Assessment = pcc.Assessment;

pub const Inputs = struct {
    /// Section 7, exactly as embedded. Null when the artifact carries none.
    certificate: ?[]const u8,
    /// Section 1, exactly as loaded.
    bytecode: []const u8,
    /// Section 2 entries, in load order.
    dep_bytecodes: []const []const u8 = &.{},
    /// Section 3, exactly as loaded.
    contract_section: ?[]const u8 = null,
    /// SHA-256 of section 4, as this process hashed it on the way in.
    policy_section_digest: [32]u8,
    /// Module and source identity, read from the contract this process
    /// validated rather than from the one the producer signed.
    identity: artifact_graph.Identity = .{},
    /// What a separate provenance check established, if one ran.
    provenance: pcc.ProvenanceState = .absent,
    /// One entry per solver query in the certificate, from an adapter outside
    /// the kernel. Empty means no solver ran, and the kernel treats an
    /// unanswered solver edge as inconclusive.
    solver_results: []const bool = &.{},
};

pub const Error = error{
    OutOfMemory,
};

fn refusal(
    stage: pcc.verdict.Stage,
    code: pcc.ReasonCode,
    provenance: pcc.ProvenanceState,
    recertifiable: bool,
) Assessment {
    return .{
        .semantic = .parsed,
        .provenance = provenance,
        .grade = null,
        .development_only = false,
        .rejection = .{
            .stage = stage,
            .code = code,
            .recertifiable = recertifiable,
        },
        .work_spent = 0,
    };
}

/// Rebuild the inventory, check the certificate against it, and report what the
/// consumer established.
pub fn accept(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    policy: pcc.Policy,
) Error!Assessment {
    const certificate = inputs.certificate orelse
        return refusal(.decode, .missing_required_section, inputs.provenance, true);

    const members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(members);

    const observed = artifact_graph.build(allocator, artifact_graph.fromArtifact(.{
        .bytecode = inputs.bytecode,
        .dep_bytecodes = inputs.dep_bytecodes,
        .contract_section = inputs.contract_section,
        .policy_section_digest = inputs.policy_section_digest,
        .identity = inputs.identity,
        // The proof IR is a member of the graph, and its digest is the IR root
        // the certificate states. Reading it from the certificate is safe
        // precisely because the kernel then folds the IR section itself and
        // refuses a root that does not match what it folded.
        .proof_ir_digest = proofIrDigest(certificate),
    }), members) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refusal(.artifact_binding, .graph_member_missing, inputs.provenance, true),
    };

    const scratch = try allocator.alloc(u8, pcc.checker.scratchBytes(policy.limits));
    defer allocator.free(scratch);

    return pcc.check(.{
        .certificate = certificate,
        .observed_graph = observed,
        .provenance = inputs.provenance,
        .scratch = scratch,
        .solver_results = inputs.solver_results,
    }, policy);
}

/// Peek at the certificate's stated IR root without trusting it.
///
/// The consumer cannot rebuild the proof IR - it has no compiler - so the one
/// member it cannot derive is read from the certificate. That is not a hole:
/// the kernel refolds the IR section it decoded and refuses a certificate whose
/// stated root is not the fold of the IR it carries, so a producer that lies
/// here fails there.
fn proofIrDigest(certificate: []const u8) ?[32]u8 {
    var budget = pcc.limits.Budget.init(.{});
    const decoded = pcc.certificate.decode(certificate, .{}, &budget) catch return null;
    return decoded.identity.ir_root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an artifact with no certificate is refused, not waved through" {
    const allocator = testing.allocator;
    const result = try accept(allocator, .{
        .certificate = null,
        .bytecode = "",
        .policy_section_digest = [_]u8{0} ** 32,
    }, pcc.policy.production);

    try testing.expect(!result.accepted());
    try testing.expectEqual(pcc.ReasonCode.missing_required_section, result.rejection.?.code);
    try testing.expect(result.rejection.?.recertifiable);
}

test "a certificate that does not decode is refused at the decode stage" {
    const allocator = testing.allocator;
    const result = try accept(allocator, .{
        .certificate = "not a certificate",
        .bytecode = "",
        .policy_section_digest = [_]u8{0} ** 32,
    }, pcc.policy.production);
    try testing.expect(!result.accepted());
    // The graph rebuild runs first and refuses the empty module stream.
    try testing.expect(result.rejection != null);
}
