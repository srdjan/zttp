//! The acceptance kernel.
//!
//! Everything here is work the consumer does for itself. It reads the
//! certificate as data, recomputes what the certificate claims, and compares.
//! It never reads a producer verdict, never touches the filesystem, the clock,
//! the network, or a signer, and never allocates.

const std = @import("std");

const cert_mod = @import("certificate.zig");
const graph = @import("executable_graph.zig");
const limits_mod = @import("limits.zig");
const policy_mod = @import("policy.zig");
const ps = @import("proof_system.zig");
const verdict = @import("verdict.zig");

const Assessment = verdict.Assessment;
const Budget = limits_mod.Budget;
const Policy = policy_mod.Policy;
const Rejection = verdict.Rejection;
const SemanticState = verdict.SemanticState;

pub const Inputs = struct {
    /// The certificate bytes, exactly as they were embedded or fetched.
    certificate: []const u8,
    /// The executable-graph inventory the consumer recomputed from the artifact
    /// it holds. Not the producer's list: the point of the comparison is that
    /// these two were derived independently.
    observed_graph: []const graph.Member,
    /// What a separate provenance check established, if one ran. Provenance is
    /// carried through so a caller can report it, and it never raises or lowers
    /// a semantic state.
    provenance: verdict.ProvenanceState = .absent,
};

fn rejectAt(
    state: SemanticState,
    provenance: verdict.ProvenanceState,
    budget: Budget,
    limits: limits_mod.Limits,
    rejection: Rejection,
) Assessment {
    return Assessment.reject(state, provenance, rejection, budget.spent(limits));
}

/// Run semantic acceptance over one certificate and one recomputed inventory.
pub fn check(inputs: Inputs, policy: Policy) Assessment {
    var budget = Budget.init(policy.limits);
    const limits = policy.limits;

    policy.validate() catch |err| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .policy,
            .code = switch (err) {
                error.EmptyRequirementSet => .policy_requires_nothing,
                error.EmptyProofSystemSet, error.DuplicateRequirement => .proof_system_not_selected,
                error.EmptyEpochSet => .semantics_epoch_not_selected,
            },
            .recertifiable = false,
        });
    };

    const certificate = cert_mod.decode(inputs.certificate, limits, &budget) catch |err| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = if (err == error.WorkBudgetExhausted) .limits else .decode,
            .code = cert_mod.reasonFor(err),
            .recertifiable = true,
        });
    };

    if (!policy.acceptsProofSystem(certificate.proof_system)) {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .proof_system_identity,
            .code = .unsupported_proof_system,
            .actual = .{ .scalar = @intFromEnum(certificate.proof_system) },
            .recertifiable = true,
        });
    }
    if (!policy.acceptsEpoch(certificate.semantics_epoch)) {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .proof_system_identity,
            .code = .unsupported_semantics_epoch,
            .actual = .{ .scalar = certificate.semantics_epoch },
            .recertifiable = true,
        });
    }

    if (bindExecutableGraph(certificate, inputs.observed_graph, &budget)) |rejection| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, rejection);
    }

    // Everything above establishes that the certificate describes exactly the
    // artifact in hand. Nothing above establishes what the artifact does.
    return .{
        .semantic = .integrity_verified,
        .provenance = inputs.provenance,
        .grade = null,
        .development_only = certificate.identity.development,
        .rejection = null,
        .work_spent = budget.spent(limits),
    };
}

fn bindingRejection(code: verdict.ReasonCode, subject: verdict.Subject) Rejection {
    return .{
        .stage = .artifact_binding,
        .code = code,
        .subject = subject,
        .recertifiable = true,
    };
}

fn memberSubject(member: graph.Member) verdict.Subject {
    return .{ .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal } };
}

/// Recompute the root over the certificate's inventory, compare that inventory
/// member by member against the one the consumer derived from the artifact, and
/// confirm the root the certificate committed to.
///
/// Returns null when the binding holds.
fn bindExecutableGraph(
    certificate: cert_mod.Certificate,
    observed: []const graph.Member,
    budget: *Budget,
) ?Rejection {
    if (std.mem.allEqual(u8, &certificate.identity.executable_root, 0)) {
        return bindingRejection(.zero_commitment, .none);
    }

    var hasher = graph.RootHasher.init(certificate.graph.len()) catch {
        return bindingRejection(.zero_commitment, .none);
    };

    var index: u32 = 0;
    var observed_index: usize = 0;
    while (index < certificate.graph.len()) : (index += 1) {
        budget.spend(2) catch return .{
            .stage = .limits,
            .code = .work_budget_exhausted,
            .recertifiable = true,
        };

        const claimed = certificate.graph.get(index) catch {
            return bindingRejection(.graph_member_missing, .{ .section = @intFromEnum(cert_mod.SectionTag.graph) });
        };

        hasher.push(claimed) catch |err| return bindingRejection(switch (err) {
            error.DuplicateMember => .graph_member_duplicate,
            else => .graph_member_out_of_order,
        }, memberSubject(claimed));

        // Advance past anything the consumer observed that the certificate does
        // not mention: extra executable bytes are the dangerous direction.
        while (observed_index < observed.len and
            graph.Member.order(observed[observed_index], claimed) == .lt)
        {
            return bindingRejection(.graph_member_extra, memberSubject(observed[observed_index]));
        }

        if (observed_index >= observed.len) {
            return bindingRejection(.graph_member_missing, memberSubject(claimed));
        }
        const seen = observed[observed_index];
        switch (graph.Member.order(seen, claimed)) {
            .gt => return bindingRejection(.graph_member_missing, memberSubject(claimed)),
            .lt => unreachable, // handled above
            .eq => {
                if (!std.mem.eql(u8, &seen.digest, &claimed.digest)) {
                    return .{
                        .stage = .artifact_binding,
                        .code = .graph_member_digest_mismatch,
                        .subject = memberSubject(claimed),
                        .expected = .{ .digest = claimed.digest },
                        .actual = .{ .digest = seen.digest },
                        .recertifiable = true,
                    };
                }
                observed_index += 1;
            },
        }
    }

    if (observed_index < observed.len) {
        return bindingRejection(.graph_member_extra, memberSubject(observed[observed_index]));
    }

    hasher.checkRequiredKinds() catch {
        return bindingRejection(.graph_member_missing, .none);
    };

    const recomputed = hasher.finish() catch {
        return bindingRejection(.zero_commitment, .none);
    };
    if (!std.mem.eql(u8, &recomputed, &certificate.identity.executable_root)) {
        return .{
            .stage = .artifact_binding,
            .code = .executable_root_mismatch,
            .expected = .{ .digest = certificate.identity.executable_root },
            .actual = .{ .digest = recomputed },
            .recertifiable = true,
        };
    }

    // The proof IR is itself a graph member, so the IR root the certificate
    // states must be the digest the inventory committed to.
    var ir_index: u32 = 0;
    while (ir_index < certificate.graph.len()) : (ir_index += 1) {
        const member = certificate.graph.get(ir_index) catch break;
        if (member.kind != .proof_ir) continue;
        if (!std.mem.eql(u8, &member.digest, &certificate.identity.ir_root)) {
            return .{
                .stage = .artifact_binding,
                .code = .proof_ir_digest_mismatch,
                .subject = memberSubject(member),
                .expected = .{ .digest = member.digest },
                .actual = .{ .digest = certificate.identity.ir_root },
                .recertifiable = true,
            };
        }
        break;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const test_support = struct {
    pub fn digest(seed: u8) [32]u8 {
        var out: [32]u8 = undefined;
        @memset(&out, seed);
        return out;
    }

    pub const Fixture = struct {
        members: [8]graph.Member,
        ir: [2]cert_mod.IrNode,
        obligations: [1]cert_mod.Obligation,
        evidence: [1]cert_mod.Evidence,
        buffer: [4096]u8 = undefined,
        len: usize = 0,

        pub fn bytes(self: *const Fixture) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn graphMembers(self: *const Fixture) []const graph.Member {
            return &self.members;
        }
    };

    /// A well-formed minimal certificate plus the inventory a consumer would
    /// recompute from the matching artifact.
    pub fn build() !Fixture {
        var fixture = Fixture{
            .members = .{
                .{ .kind = .main_bytecode, .ordinal = 0, .digest = digest(1) },
                .{ .kind = .contract_bytes, .ordinal = 0, .digest = digest(2) },
                .{ .kind = .runtime_policy_bytes, .ordinal = 0, .digest = digest(3) },
                .{ .kind = .source_profile_core, .ordinal = 0, .digest = digest(4) },
                .{ .kind = .core_grammar, .ordinal = 0, .digest = digest(5) },
                .{ .kind = .semantics, .ordinal = 0, .digest = digest(6) },
                .{ .kind = .capability_matrix, .ordinal = 0, .digest = digest(7) },
                .{ .kind = .proof_ir, .ordinal = 0, .digest = digest(8) },
            },
            .ir = .{
                .{ .id = 0, .tag = .function, .parent = 0, .first_child = 1, .child_count = 1, .digest = digest(20) },
                .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = digest(21) },
            },
            .obligations = .{
                .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
            },
            .evidence = .{
                .{ .obligation_index = 0, .edge = .proved, .rule = .return_total, .node_id = 1, .aux = 0 },
            },
        };
        std.mem.sort(graph.Member, &fixture.members, {}, struct {
            fn lt(_: void, a: graph.Member, b: graph.Member) bool {
                return graph.Member.order(a, b) == .lt;
            }
        }.lt);

        const parts = cert_mod.Parts{
            .identity = .{
                .executable_root = try graph.computeRoot(&fixture.members),
                .ir_root = digest(8),
                .contract_digest = digest(2),
                .development = false,
            },
            .graph = &fixture.members,
            .obligations = &fixture.obligations,
            .ir = &fixture.ir,
            .evidence = &fixture.evidence,
        };
        const encoded = try cert_mod.encode(parts, &fixture.buffer);
        fixture.len = encoded.len;
        return fixture;
    }
};

test "a matching certificate and inventory reach integrity verification" {
    const fixture = try test_support.build();
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    }, policy_mod.production);

    try testing.expectEqual(@as(?Rejection, null), result.rejection);
    try testing.expectEqual(SemanticState.integrity_verified, result.semantic);
    try testing.expect(!result.accepted());
    try testing.expectEqual(@as(?verdict.AssuranceGrade, null), result.grade);
    try testing.expect(result.work_spent > 0);
}

test "a policy that requires nothing is refused before anything is read" {
    const fixture = try test_support.build();
    const empty = Policy{
        .proof_systems = &[_]ps.ProofSystem{.zttp_pcc_v1},
        .semantics_epochs = &[_]u32{ps.semantics_epoch},
        .required = &.{},
    };
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    }, empty);
    try testing.expectEqual(verdict.ReasonCode.policy_requires_nothing, result.rejection.?.code);
    try testing.expect(!result.rejection.?.recertifiable);
}

test "mutating any observed member class rejects at artifact binding" {
    const fixture = try test_support.build();
    for (0..fixture.members.len) |index| {
        var observed = fixture.members;
        observed[index].digest[0] +%= 1;
        const result = check(.{
            .certificate = fixture.bytes(),
            .observed_graph = &observed,
        }, policy_mod.production);
        try testing.expectEqual(verdict.Stage.artifact_binding, result.rejection.?.stage);
        try testing.expectEqual(
            verdict.ReasonCode.graph_member_digest_mismatch,
            result.rejection.?.code,
        );
        try testing.expect(result.rejection.?.recertifiable);
    }
}

test "an artifact carrying a member the certificate omits rejects" {
    const fixture = try test_support.build();
    var observed: [9]graph.Member = undefined;
    @memcpy(observed[0..8], &fixture.members);
    observed[8] = .{ .kind = .dep_bytecode, .ordinal = 0, .digest = test_support.digest(99) };
    std.mem.sort(graph.Member, &observed, {}, struct {
        fn lt(_: void, a: graph.Member, b: graph.Member) bool {
            return graph.Member.order(a, b) == .lt;
        }
    }.lt);

    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = &observed,
    }, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.graph_member_extra, result.rejection.?.code);
}

test "an artifact missing a member the certificate names rejects" {
    const fixture = try test_support.build();
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.members[0 .. fixture.members.len - 1],
    }, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.graph_member_missing, result.rejection.?.code);
}

test "an unsupported proof system rejects before binding" {
    const fixture = try test_support.build();
    const other = Policy{
        .proof_systems = &.{},
        .semantics_epochs = &[_]u32{ps.semantics_epoch},
        .required = policy_mod.production.required,
    };
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    }, other);
    // An empty proof-system set is a malformed policy, caught first.
    try testing.expectEqual(verdict.Stage.policy, result.rejection.?.stage);
}

test "an unsupported semantics epoch rejects" {
    const fixture = try test_support.build();
    const epochs = [_]u32{ps.semantics_epoch + 7};
    const other = Policy{
        .proof_systems = policy_mod.production.proof_systems,
        .semantics_epochs = &epochs,
        .required = policy_mod.production.required,
    };
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    }, other);
    try testing.expectEqual(verdict.ReasonCode.unsupported_semantics_epoch, result.rejection.?.code);
    try testing.expectEqual(verdict.Stage.proof_system_identity, result.rejection.?.stage);
}

test "a starved work budget rejects at the limits stage" {
    const fixture = try test_support.build();
    var starved = policy_mod.production;
    starved.limits.max_work = 2;
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    }, starved);
    try testing.expectEqual(verdict.Stage.limits, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.work_budget_exhausted, result.rejection.?.code);
}

test "checking is deterministic" {
    const fixture = try test_support.build();
    const inputs = Inputs{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
    };
    const first = check(inputs, policy_mod.production);
    const second = check(inputs, policy_mod.production);
    try testing.expectEqual(first.semantic, second.semantic);
    try testing.expectEqual(first.work_spent, second.work_spent);
    try testing.expectEqual(first.development_only, second.development_only);
}

test "provenance is carried through and never raises the semantic state" {
    const fixture = try test_support.build();
    const result = check(.{
        .certificate = fixture.bytes(),
        .observed_graph = fixture.graphMembers(),
        .provenance = .trusted_origin,
    }, policy_mod.production);
    try testing.expectEqual(verdict.ProvenanceState.trusted_origin, result.provenance);
    try testing.expectEqual(SemanticState.integrity_verified, result.semantic);
    try testing.expect(!result.accepted());
}
