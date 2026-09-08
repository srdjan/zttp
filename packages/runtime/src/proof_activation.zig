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
        // exhaustive: any other build error means the graph could not be
        // reconstructed, so a caller comparing two rebuilds has nothing to
        // compare. Null is the absence of a root, not a matching one, and the
        // comparison this feeds refuses on it - no failure reads as agreement.
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
        .residual_plan_digest = if (commitments) |value| value.residual_plan else null,
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
        // exhaustive: any other build error is answered by the refusal on this
        // line. The arm is not silent - it IS the rejection, so no ignored case
        // reaches the kernel.
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
    residual_plan: ?[32]u8,
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
        .residual_plan = if (decoded.residual.len() > 0)
            pcc.certificate.residualPlanDigestFromTable(decoded.residual) catch return null
        else
            null,
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

test "the kernel's endpoint rule and the base-tier one agree" {
    // Two implementations of one rule, in packages that cannot import each
    // other. This file imports both. A corpus of the forms the rule is meant to
    // settle - scheme, case, trailing dot, explicit and implicit ports, paths,
    // userinfo, brackets - run through each, and every answer must match,
    // including which inputs are refused.
    const corpus = [_][]const u8{
        "https://api.example.com",
        "https://api.example.com/",
        "https://api.example.com/v1/orders?page=2#top",
        "HTTPS://API.Example.COM.",
        "https://api.example.com:443",
        "https://api.example.com:8443",
        "http://api.example.com",
        "http://api.example.com:80",
        "http://localhost:3000",
        "https://[::1]",
        "http://[::1]:8080",
        "https://[::1",
        "https://allowed.example@evil.example",
        "api.example.com",
        "ftp://api.example.com",
        "file:///etc/passwd",
        "https://",
        "https:///path",
        "https://api.example.com:0",
        "https://api.example.com:70000",
        "https://api.example.com:80x",
        "https://api.example.com..",
        "https://api example.com",
        "",
    };

    for (corpus) |value| {
        var producer_buf: [zts.endpoint.max_endpoint_bytes]u8 = undefined;
        var kernel_buf: [pcc.residual.max_endpoint_bytes]u8 = undefined;
        const producer = zts.endpoint.normalize(value, &producer_buf);
        const kernel = pcc.residual.normalize(.endpoint_v1, value, &kernel_buf);

        if (producer) |produced| {
            const checked = kernel catch |err| {
                std.debug.print(
                    "base tier normalized '{s}' to '{s}'; the kernel refused it with {s}\n",
                    .{ value, produced, @errorName(err) },
                );
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(produced, checked);
        } else |producer_error| {
            if (kernel) |checked| {
                std.debug.print(
                    "base tier refused '{s}' with {s}; the kernel normalized it to '{s}'\n",
                    .{ value, @errorName(producer_error), checked },
                );
                return error.TestUnexpectedResult;
            } else |kernel_error| {
                try testing.expectEqual(producer_error, kernel_error);
            }
        }
    }
}

test "the compiler's guard catalog and the kernel's are the same table" {
    // The proof IR carries a catalog row index and nothing else about the row,
    // so the producer's table and the consumer's must agree on order as well as
    // content: a row inserted on one side renumbers every obligation after it.
    // The compiler cannot import the kernel, so this file compares them.
    try testing.expectEqual(pcc.residual.catalog.len, zts.guard_catalog.entries.len);
    for (pcc.residual.catalog, zts.guard_catalog.entries) |kernel, producer| {
        try testing.expectEqualStrings(kernel.module, producer.module);
        try testing.expectEqualStrings(kernel.export_name, producer.export_name);
        try testing.expectEqual(kernel.arg_index, producer.arg_index);
        try testing.expectEqualStrings(kernel.kind.name(), producer.kind.name());
        try testing.expectEqual(@intFromEnum(kernel.kind), @intFromEnum(producer.kind));
        try testing.expectEqualStrings(
            kernel.kind.section().name(),
            sectionKeyRoot(producer.kind.section()),
        );
        // The sink a denial names has to be the sink the kernel binds the
        // obligation to, or an operator reading one and a verifier reading the
        // other are talking about different code.
        try testing.expectEqualStrings(kernel.kind.sink().name(), producer.kind.sink());
    }
}

/// The producer names a policy file key (`cache.allow_namespaces`); the kernel
/// names the section (`cache`). Compare the part they both claim.
fn sectionKeyRoot(key: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, key, '.') orelse return key;
    return key[0..dot];
}

test "the kernel's identifier rule and the base-tier one agree" {
    // Same arrangement as the endpoint rule above: two implementations in
    // packages that cannot import each other, one corpus, and every answer must
    // match including which inputs are refused. The forms that matter here are
    // the ones a rule is tempted to be helpful about - case, surrounding space,
    // control bytes - plus both sides of the length cap.
    try testing.expectEqual(
        pcc.residual.max_identifier_bytes,
        zts.identifier.max_identifier_bytes,
    );

    const longest = [_]u8{'a'} ** zts.identifier.max_identifier_bytes;
    const one_too_long = [_]u8{'a'} ** (zts.identifier.max_identifier_bytes + 1);
    const corpus = [_][]const u8{
        "API_KEY",
        "api_key",
        " API_KEY ",
        "sessions",
        "listTodos",
        "a",
        "name with spaces",
        "naïve",
        "API\nKEY",
        "API\tKEY",
        "API\x00KEY",
        "API\x7FKEY",
        &longest,
        &one_too_long,
        "",
    };

    for (corpus) |value| {
        var producer_buf: [zts.identifier.max_identifier_bytes]u8 = undefined;
        var kernel_buf: [pcc.residual.max_identifier_bytes]u8 = undefined;
        const producer = zts.identifier.normalize(value, &producer_buf);
        const kernel = pcc.residual.normalize(.identifier_exact_v1, value, &kernel_buf);

        if (producer) |produced| {
            const checked = kernel catch |err| {
                std.debug.print(
                    "base tier normalized an identifier the kernel refused with {s}\n",
                    .{@errorName(err)},
                );
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(produced, checked);
        } else |producer_error| {
            if (kernel) |_| {
                std.debug.print(
                    "base tier refused an identifier with {s}; the kernel normalized it\n",
                    .{@errorName(producer_error)},
                );
                return error.TestUnexpectedResult;
            } else |kernel_error| {
                try testing.expectEqual(producer_error, kernel_error);
            }
        }
    }
}

test "the producer and the consumer name address scopes with the same bits" {
    inline for (@typeInfo(zts.endpoint.AddressScope).@"enum".fields) |field| {
        const producer: zts.endpoint.AddressScope = @enumFromInt(field.value);
        const consumer = pcc.residual.AddressScope.fromWire(field.value) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqualStrings(producer.name(), consumer.name());
        try testing.expectEqual(producer.bit(), consumer.bit());
    }
    // Neither side admits a bit the other does not model.
    try testing.expect(zts.endpoint.ScopeSet.fromWire(0b1000_0000) == null);
    try testing.expect(pcc.residual.ScopeSet.fromWire(0b1000_0000) == null);
}
