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
const zts = @import("zts");

const artifact_graph = @import("artifact_graph.zig");

const graph = pcc.executable_graph;

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
    /// Section 4 itself, when this process holds it. The kernel decodes these
    /// bytes with its own decoder and recomputes their digest against the
    /// certificate identity, which is what ties a guard plan to one policy
    /// rather than to any policy. Null supplies no resource authority, and a
    /// guarded artifact is then refused for want of one.
    policy_section: ?[]const u8 = null,
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

/// Rebuild the inventory this process's sections produce, and fold it.
///
/// One definition, used by the attestation check and by acceptance, so the two
/// cannot disagree about which members the artifact has. They disagreed once:
/// acceptance folded the proof-IR member and the attestation check did not, and
/// every artifact carrying a certificate then refused to serve because its own
/// two rebuilds produced different roots.
pub fn observedRoot(allocator: std.mem.Allocator, inputs: Inputs) Error!?[32]u8 {
    const members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(members);
    const observed = artifact_graph.build(allocator, graphInputs(inputs), members) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return graph.computeRoot(observed) catch null;
}

fn graphInputs(inputs: Inputs) artifact_graph.Inputs {
    const commitments = if (inputs.certificate) |certificate|
        certificateCommitments(certificate)
    else
        null;
    return artifact_graph.fromArtifact(.{
        .bytecode = inputs.bytecode,
        .dep_bytecodes = inputs.dep_bytecodes,
        .contract_section = inputs.contract_section,
        .policy_section_digest = inputs.policy_section_digest,
        .identity = inputs.identity,
        // The kernel refolds the IR and the complete certificate. The latter
        // normalizes only the two self-referential digest slots, so every
        // authority-bearing section participates in the executable root.
        .proof_ir_digest = if (commitments) |value| value.ir else null,
        .proof_certificate_digest = if (commitments) |value| value.certificate else null,
    });
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

    const observed = artifact_graph.build(allocator, graphInputs(inputs), members) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refusal(.artifact_binding, .graph_member_missing, inputs.provenance, true),
    };

    // The bytes and the graph member must describe the same policy before the
    // kernel is asked anything about them. The kernel checks these bytes
    // against the certificate's identity; this checks them against the section
    // this process actually loaded.
    if (inputs.policy_section) |bytes| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &inputs.policy_section_digest)) {
            return refusal(.guard_coverage, .runtime_policy_undecodable, inputs.provenance, true);
        }
    }

    const scratch = try allocator.alloc(u8, pcc.checker.scratchBytes(policy.limits));
    defer allocator.free(scratch);

    return pcc.check(.{
        .certificate = certificate,
        .observed_graph = observed,
        .provenance = inputs.provenance,
        .scratch = scratch,
        .solver_results = inputs.solver_results,
        .runtime_policy = if (inputs.policy_section) |bytes| .{ .bytes = bytes } else null,
    }, policy);
}

const CertificateCommitments = struct {
    ir: [32]u8,
    certificate: [32]u8,
};

/// Derive the certificate-owned graph members without trusting either one.
///
/// The consumer cannot rebuild the proof IR because it has no compiler, so its
/// stated root is returned beside a fold over every certificate byte. The
/// checker independently refolds the IR section and compares it with the first
/// value before accepting any evidence.
fn certificateCommitments(certificate: []const u8) ?CertificateCommitments {
    var budget = pcc.limits.Budget.init(.{});
    const decoded = pcc.certificate.decode(certificate, .{}, &budget) catch return null;
    return .{
        .ir = decoded.identity.ir_root,
        .certificate = pcc.certificate.commitmentDigest(certificate, decoded) catch return null,
    };
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

test "the producer and the consumer cap policy resources at the same numbers" {
    // `packages/zts` writes the policy and `packages/proof-checker` reads it,
    // and neither can import the other: the kernel is a leaf and the compiler
    // sits below it, so each carries its own copy of R18's numbers. This file
    // sees both. A number that moves on one side without the other produces a
    // policy the producer writes and the consumer refuses, which is a failure
    // at every deployment rather than here.
    const producer = zts.handler_policy;
    try testing.expectEqual(
        @as(usize, pcc.residual.max_policy_entries),
        producer.max_policy_entries,
    );
    try testing.expectEqual(
        pcc.residual.max_identifier_bytes,
        producer.max_identifier_bytes,
    );
    try testing.expectEqual(
        pcc.residual.max_endpoint_bytes,
        producer.max_endpoint_bytes,
    );
    try testing.expectEqual(
        pcc.residual.max_lookup_comparisons,
        producer.max_lookup_comparisons,
    );
}
