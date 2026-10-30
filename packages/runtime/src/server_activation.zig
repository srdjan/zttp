//! Artifact activation and live-swap refusal for `Server`.
//!
//! These functions were methods and helpers in `server.zig`. Each former method
//! takes the `Server` as its first parameter and runs in the original order.
//! The engine boundary is the same as `server.zig`: no direct `zts` import.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine_adapter.zig");
const retired_authority = @import("project_config").retired_authority;
const contract_runtime = @import("contract_runtime.zig");
const RuntimeContract = contract_runtime.RuntimeContract;
const artifact_graph = @import("artifact_graph.zig");
const pcc = @import("zttp_proof_checker");
const proof_activation = @import("proof_activation.zig");
const attest_envelope = @import("attest/envelope.zig");
const Server = @import("server.zig").Server;

/// Why a swap may not proceed.
///
/// A live swap has no certificate or consumer acceptance run. Static resources
/// remain safe because the compiler enumerates an exact contract allowlist. A
/// computed resource may swap only when this same analysis parsed and checked a
/// configured policy snapshot, which is installed atomically with the candidate
/// generation. Without that checked pair, either guarded side is a refusal.
///
/// Kept at the server transition boundary so the decision is tested without a
/// pool, a server, and a file watcher.
pub const SwapRefusal = enum {
    none,
    candidate_uses_retired_authority,
    installed_generation_is_guarded,
    candidate_computes_a_capability_resource,
};

pub fn swapRefusal(
    installed_generation_is_guarded: bool,
    candidate: ?*const engine.HandlerContract,
    candidate_policy_checked: bool,
) SwapRefusal {
    if (candidate) |contract| {
        if (retired_authority.first(retired_authority.contractFacts(contract)) != null) {
            return .candidate_uses_retired_authority;
        }
    }
    if (installed_generation_is_guarded and !candidate_policy_checked) {
        return .installed_generation_is_guarded;
    }
    const contract = candidate orelse return .none;
    // The plain-swap and missing-contract branches arrive here with no
    // candidate contract. They are covered by the first check: a swap with
    // nothing to inspect may proceed only when the running generation has no
    // guard to preserve.
    if (!candidate_policy_checked and (contract.env.dynamic or
        contract.egress.dynamic or
        contract.cache.dynamic or
        contract.sql.dynamic))
    {
        return .candidate_computes_a_capability_resource;
    }
    return .none;
}

pub fn requireSourceSwap(guarded: bool, candidate: ?*const engine.HandlerContract, policy_checked: bool) !void {
    return switch (swapRefusal(guarded, candidate, policy_checked)) {
        .none => {},
        .candidate_uses_retired_authority => error.UnsupportedRuntimeAuthority,
        .installed_generation_is_guarded => error.GuardedGenerationSwapRefused,
        .candidate_computes_a_capability_resource => error.UncheckedDynamicCapability,
    };
}

/// Cross-check the signed attestation claims against the hashes the server
/// actually loaded. `attest_envelope.verify` proves only that the JWS was
/// signed; it never compares claim hashes to the running artifact. Returns
/// false when the policy or bytecode hash in the claims disagrees with the
/// live contract. A live hash of all-zero means the contract carried no
/// sandbox block (e.g. live reload), so we skip that field rather than
/// reject it - mirroring the skip-on-zero semantics in
/// `contract_runtime.verifyPolicyHash` / `verifyArtifactHash`.
pub fn attestationClaimsMatchContract(
    claims: attest_envelope.Claims,
    contract: *const RuntimeContract,
) bool {
    if (!hexHashMatchesOrUnpinned(claims.policy_sha256, contract.policy_hash)) return false;
    if (!hexHashMatchesOrUnpinned(claims.bytecode_sha256, contract.artifact_sha256)) return false;
    if (!std.mem.eql(u8, claims.core_profile_id, contract.source_identity.core_profile.id())) return false;
    if (!hexHashMatches(claims.core_grammar_sha256, contract.source_identity.core_grammar_hash)) return false;
    if (!hexHashMatches(claims.semantics_sha256, contract.source_identity.semantics_hash)) return false;
    return true;
}

fn hexHashMatches(claim_hex: []const u8, live: [32]u8) bool {
    if (claim_hex.len != 64) return false;
    const live_hex = std.fmt.bytesToHex(live, .lower);
    return std.mem.eql(u8, &live_hex, claim_hex);
}

/// True when `live` is unpinned (all-zero) or its lowercase-hex form equals
/// `claim_hex`. A claim field that is not 64 hex chars cannot match a
/// pinned 32-byte hash and is rejected.
fn hexHashMatchesOrUnpinned(claim_hex: []const u8, live: [32]u8) bool {
    if (std.mem.allEqual(u8, &live, 0)) return true;
    if (claim_hex.len != 64) return false;
    const live_hex = std.fmt.bytesToHex(live, .lower);
    return std.mem.eql(u8, &live_hex, claim_hex);
}

/// True only when the signed `claim_hex` is pinned (64 non-all-zero hex
/// chars) AND equals sha256(bytecode). This binds the attestation to the
/// bytecode actually loaded into the pool, anchored on the untamperable
/// signed claim rather than the contract's self-reported `artifact_sha256`
/// field (which a tamperer can zero to slip past the all-zero skip in
/// `contract_runtime.validate`). An unpinned claim cannot bind a running
/// artifact, so it returns false: attestation is fail-closed.
pub fn bytecodeMatchesClaim(bytecode: []const u8, claim_hex: []const u8) bool {
    if (claim_hex.len != 64) return false;
    if (std.mem.allEqual(u8, claim_hex, '0')) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytecode, &digest, .{});
    const live_hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&live_hex, claim_hex);
}

/// Validate the signed runtime-policy claim against the exact section-4
/// bytes parsed from a self-extract artifact. Unlike live contract hashes,
/// this claim cannot be unpinned: the deployed artifact always has section
/// 4, so an all-zero claim means it predates policy binding.
fn validateRuntimePolicyClaim(section_sha256: [32]u8, claim_hex: []const u8) !void {
    if (std.mem.eql(u8, claim_hex, attest_envelope.unpinned_runtime_policy_sha256)) {
        return error.RuntimePolicyClaimUnpinned;
    }
    if (claim_hex.len != 64) return error.RuntimePolicyClaimMismatch;
    const section_hex = std.fmt.bytesToHex(section_sha256, .lower);
    if (!std.ascii.eqlIgnoreCase(&section_hex, claim_hex)) {
        return error.RuntimePolicyClaimMismatch;
    }
}

fn validateEmbeddedRuntimePolicyAttestation(self: *Server) !void {
    const jws = self.config.attestation_jws orelse return;
    const section_sha256 = self.config.policy_section_sha256 orelse switch (self.config.handler) {
        .appended_payload => {
            if (!builtin.is_test) {
                std.log.err(
                    "attestation: embedded runtime policy hash is missing; rebuild the artifact before serving",
                    .{},
                );
            }
            return error.RuntimePolicySectionHashMissing;
        },
        else => return,
    };
    var verify_result = attest_envelope.verify(self.allocator, jws) catch |err| {
        if (!builtin.is_test) {
            switch (err) {
                error.UnsupportedAttestationVersion => std.log.err(
                    "attestation: embedded receipt uses an unsupported format; rebuild the artifact before serving",
                    .{},
                ),
                else => std.log.err(
                    "attestation: embedded JWS failed self-verification ({s}); refusing to serve",
                    .{@errorName(err)},
                ),
            }
        }
        return error.InvalidEmbeddedAttestation;
    };
    defer verify_result.deinit();

    validateRuntimePolicyClaim(
        section_sha256,
        verify_result.claims.runtime_policy_sha256,
    ) catch |err| {
        if (!builtin.is_test) {
            switch (err) {
                error.RuntimePolicyClaimUnpinned => std.log.err(
                    "attestation: artifact predates runtime policy binding and must be rebuilt; refusing to serve",
                    .{},
                ),
                error.RuntimePolicyClaimMismatch => std.log.err(
                    "attestation: embedded runtime policy does not match the signed claim; refusing to serve",
                    .{},
                ),
            }
        }
        return err;
    };

    try validateExecutableGraphClaim(
        self,
        section_sha256,
        verify_result.claims.executable_root_sha256,
    );
}

/// Run consumer acceptance over the embedded certificate, and promote the
/// contract only if it passes.
///
/// A production artifact - one serving from an appended payload - must
/// carry a certificate this consumer accepts. Anything else refuses to
/// serve. Dev, live reload, and `-Dhandler` builds carry no artifact and no
/// certificate; they run with no promotion at all, which means no proof
/// response cache, no unbounded runtime reuse, and no result-safety shortcut.
fn acceptEmbeddedCertificate(self: *Server) !void {
    const validated = if (self.contract) |*contract| contract else null;
    const is_production_artifact = switch (self.config.handler) {
        .appended_payload => true,
        else => false,
    };

    if (!is_production_artifact) {
        if (self.config.certificate != null and !builtin.is_test) {
            std.log.info("Proof certificate present but this is not a deployed artifact; running unpromoted", .{});
        }
        return;
    }

    const contract = validated orelse {
        if (!builtin.is_test) {
            std.log.err(
                "activation: deployed artifact carries no contract, so nothing can be checked; refusing to serve",
                .{},
            );
        }
        return error.ProofContractMissing;
    };

    const bytecode = self.embedded_bytecode orelse return error.ProofBytecodeMissing;
    const policy_digest = self.config.policy_section_sha256 orelse {
        if (!builtin.is_test) {
            std.log.err(
                "activation: deployed artifact carries no runtime policy section; refusing to serve",
                .{},
            );
        }
        return error.RuntimePolicySectionHashMissing;
    };

    const assessment = try proof_activation.accept(self.allocator, .{
        .certificate = self.config.certificate,
        .bytecode = bytecode,
        .dep_bytecodes = self.runtime_dep_bytecodes orelse &.{},
        .contract_section = self.config.contract_json,
        .policy_section_digest = policy_digest,
        .policy_section = self.config.policy_section,
        .identity = observedArtifactIdentity(self),
        .provenance = if (self.config.attestation_jws != null)
            .signature_verified
        else
            .absent,
    }, pcc.policy.production);

    self.proof_checked = contract_runtime.promote(contract, assessment, policy_digest);
    if (self.proof_checked == null) {
        if (!builtin.is_test) {
            if (assessment.rejection()) |rejection| {
                std.log.err(
                    "activation: proof acceptance failed at {s} ({s}); refusing to serve. Rebuild {s}resolve this.",
                    .{
                        rejection.stage.name(),
                        rejection.code.text(),
                        if (rejection.recertifiable) "can " else "cannot ",
                    },
                );
            } else {
                std.log.err("activation: proof acceptance did not complete; refusing to serve", .{});
            }
        }
        return error.ProofAcceptanceFailed;
    }

    if (!builtin.is_test) {
        std.log.info(
            "Proof accepted: weakest edge {s}, {d} disclosed edge(s){s}",
            .{
                self.proof_checked.?.grade.name(),
                assessment.disclosed_edges,
                if (self.proof_checked.?.development_only) " (development artifact)" else "",
            },
        );
    }
}

/// Rebuild the executable graph from the sections this process actually
/// loaded and compare it against the signed root.
///
/// The bytecode hash the contract carries covers the entry module. This
/// covers the dependency modules, every nested function, every constant
/// pool, the module and native-module identities, the contract, the runtime
/// policy, and the source profile - all of which run, and none of which the
/// older claim reached.
fn validateExecutableGraphClaim(
    self: *Server,
    policy_section_sha256: [32]u8,
    claimed_root_hex: []const u8,
) !void {
    if (std.mem.eql(u8, claimed_root_hex, attest_envelope.unpinned_executable_root)) {
        if (!builtin.is_test) {
            std.log.err(
                "attestation: artifact predates executable-graph binding and must be rebuilt; refusing to serve",
                .{},
            );
        }
        return error.ExecutableGraphClaimUnpinned;
    }

    const bytecode = self.embedded_bytecode orelse return error.ExecutableGraphMissingBytecode;

    const observed = proof_activation.observedRoot(self.allocator, .{
        .certificate = self.config.certificate,
        .bytecode = bytecode,
        .dep_bytecodes = self.runtime_dep_bytecodes orelse &.{},
        .contract_section = self.config.contract_json,
        .policy_section_digest = policy_section_sha256,
        .identity = observedArtifactIdentity(self),
    }) catch |err| {
        if (!builtin.is_test) {
            std.log.err(
                "attestation: could not rebuild the executable graph ({s}); refusing to serve",
                .{@errorName(err)},
            );
        }
        return error.ExecutableGraphUnreadable;
    } orelse {
        if (!builtin.is_test) {
            std.log.err(
                "attestation: could not rebuild the executable graph; refusing to serve",
                .{},
            );
        }
        return error.ExecutableGraphUnreadable;
    };

    const observed_hex = std.fmt.bytesToHex(observed, .lower);
    if (!std.mem.eql(u8, &observed_hex, claimed_root_hex)) {
        if (!builtin.is_test) {
            std.log.err(
                "attestation: the loaded executable graph does not match the signed root; refusing to serve",
                .{},
            );
        }
        return error.ExecutableGraphMismatch;
    }
}

/// The identity half of the graph, read from the contract this process
/// validated rather than from the one the producer signed.
fn observedArtifactIdentity(self: *Server) artifact_graph.Identity {
    const validated = self.contract orelse return .{};
    return artifact_graph.identityFromRuntimeContract(validated.view());
}

pub fn activate(self: *Server) !void {
    // Parse embedded contract (if present), then promote to Validated before
    // prewarming the handler pool. This rejects artifact hash drift before
    // appended bytecode is loaded into any runtime.
    if (self.config.contract_json) |json| {
        const raw = contract_runtime.parseContractJson(self.allocator, json) catch |err| {
            if (!builtin.is_test) {
                std.log.err("sandbox: embedded handler artifact contract is malformed; binary will not serve: {}", .{err});
            }
            return err;
        };
        self.contract = contract_runtime.validate(raw, .{
            .bytecode = self.embedded_bytecode,
        }) catch |err| {
            switch (err) {
                error.CapabilityMatrixMismatch => std.log.err(
                    "sandbox: capability matrix drift - rebuild the handler contract against this runtime",
                    .{},
                ),
                error.PolicyHashMismatch => std.log.err(
                    "sandbox: policy hash drift - rebuild the handler contract against this runtime",
                    .{},
                ),
                error.ArtifactHashMismatch => std.log.err(
                    "sandbox: embedded bytecode does not match contract artifact hash",
                    .{},
                ),
                error.SourceIdentityMissing => std.log.err(
                    "sandbox: source identity is missing - rebuild the handler contract",
                    .{},
                ),
                error.CoreGrammarHashMismatch,
                error.SemanticsHashMismatch,
                => std.log.err(
                    "sandbox: source profile drift - rebuild the handler contract against this runtime",
                    .{},
                ),
            }
            return err;
        };
    }

    // Self-extract artifacts carry the enforcement policy as section 4.
    // Bind those exact bytes before any runtime is prewarmed. Dev/live
    // reload leaves policy_section_sha256 null and is intentionally exempt.
    try validateEmbeddedRuntimePolicyAttestation(self);

    // Semantic acceptance. Everything above is integrity: the same bytes,
    // the same identities, a signature that validates. None of it says the
    // handler does anything in particular. This does, and it runs before
    // the pool exists, so a refusal is a refusal to serve rather than a
    // handler that is already warm when somebody reads the log line.
    try acceptEmbeddedCertificate(self);
}
