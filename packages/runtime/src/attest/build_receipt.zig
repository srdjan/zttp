//! Shared proof-receipt signer for build-time and dev-time attestation.

const std = @import("std");
const zts = @import("zts");

const envelope = @import("envelope.zig");
const header_strings = @import("header_strings.zig");
const identity = @import("identity.zig");
const proof_ledger = @import("../proof_ledger.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const compiler_version_tag: []const u8 = "zttp-attest-slice1";

/// Produces a compact JWS for build/deploy artifacts. Uses the persistent
/// identity under ~/.zttp/attest and fails if that identity cannot be
/// loaded safely. Caller owns the returned bytes.
pub fn buildJws(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
) ![]u8 {
    const loaded = identity.loadOrCreate(allocator) catch |err| {
        std.log.err(
            "attest: failed to load identity from ~/.zttp/attest/keypair.bin: {s}. Inspect the file, fix the permissions (chmod 600), or delete it to mint a fresh key.",
            .{@errorName(err)},
        );
        return err;
    };
    if (loaded.source == .generated) {
        std.log.info("attest: minted persistent identity (fingerprint {s})", .{loaded.fingerprint_hex[0..16]});
    }
    return try buildJwsWithKey(
        allocator,
        contract_json,
        bytecode,
        contract,
        runtime_policy_sha256,
        loaded.key_pair,
    );
}

/// Produces a compact JWS for local dev receipts. Dev servers may run with a
/// stripped environment, so this falls back to a process-local ephemeral key
/// when the persistent identity cannot be loaded.
pub fn buildDevJws(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
) ![]u8 {
    return try buildJwsWithKey(
        allocator,
        contract_json,
        bytecode,
        contract,
        envelope.unpinned_runtime_policy_sha256,
        loadPersistentOrEphemeralKey(allocator),
    );
}

fn buildJwsWithKey(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
    key_pair: Ed25519.KeyPair,
) ![]u8 {
    var contract_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract_json, &contract_sha, .{});
    const contract_sha_hex = std.fmt.bytesToHex(contract_sha, .lower);

    var bytecode_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytecode, &bytecode_sha, .{});
    const bytecode_sha_hex = std.fmt.bytesToHex(bytecode_sha, .lower);

    const policy_sha_hex = zts.rule_registry.policyHash();
    // All-zero means one thing here: the contract carries no capability
    // statement at all. It is not also "present but unstamped", which is what
    // an earlier comment claimed. Both producers stamp unconditionally
    // (`contract_types.computeCapabilityMatrix` ends with a `capabilityHash`
    // call), and the JSON parser recomputes when the field is absent or zero
    // (`contract_json_parser.zig`), so a present matrix cannot reach here
    // unstamped. An empty capability list is not zero either - it hashes to
    // SHA-256 over no input.
    //
    // That distinction is what keeps this claim readable, and it is pinned by
    // the test at the bottom of this file rather than left as prose. A signed
    // claim whose absent case is indistinguishable from a real value is the
    // same defect this repo has recorded twice under a different name; see
    // docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md.
    const capability_hash_hex = std.fmt.bytesToHex(
        if (contract.capabilities) |caps| caps.hash else [_]u8{0} ** 32,
        .lower,
    );

    // Name every field. HandlerProperties defaults the six flow and isolation
    // fields to true, so relying on the defaults here would put proof chips
    // for properties the contract never asserted into a signed claim.
    const props_or_default = contract.properties orelse zts.handler_contract.HandlerProperties{
        .pure = false,
        .read_only = false,
        .stateless = false,
        .retry_safe = false,
        .deterministic = false,
        .has_egress = false,
        .no_secret_leakage = false,
        .no_credential_leakage = false,
        .input_validated = false,
        .pii_contained = false,
        .injection_safe = false,
        .state_isolated = false,
    };
    const property_summary = try header_strings.formatProofChips(allocator, props_or_default);
    defer if (property_summary.len > 0) allocator.free(property_summary);

    const claims = envelope.Claims{
        .contract_sha256 = &contract_sha_hex,
        .bytecode_sha256 = &bytecode_sha_hex,
        .policy_sha256 = &policy_sha_hex,
        .capability_hash = &capability_hash_hex,
        .runtime_policy_sha256 = runtime_policy_sha256,
        .compiler_version = compiler_version_tag,
        .signed_at_unix = @divTrunc(proof_ledger.defaultNowMs(), std.time.ms_per_s),
        .property_summary = property_summary,
        .routes_count = @intCast(contract.api.routes.items.len),
        .durable_workflow_proof_level = contract.durable.workflow.proof_level.toString(),
        .durable_workflow_retry_safe = contract.durable.workflow.properties.retry_safe,
        .durable_workflow_idempotent = contract.durable.workflow.properties.idempotent,
        .durable_workflow_fault_covered = contract.durable.workflow.properties.fault_covered,
    };

    var env = try envelope.sign(allocator, claims, key_pair);
    return env.intoJws();
}

fn loadPersistentOrEphemeralKey(allocator: std.mem.Allocator) Ed25519.KeyPair {
    const loaded = identity.loadOrCreate(allocator) catch |err| {
        std.log.warn("attest: persistent identity unavailable ({s}); using ephemeral dev key", .{@errorName(err)});
        return ephemeralKeyPair();
    };
    if (loaded.source == .generated) {
        std.log.info("attest: minted persistent identity (fingerprint {s})", .{loaded.fingerprint_hex[0..16]});
    }
    return loaded.key_pair;
}

fn ephemeralKeyPair() Ed25519.KeyPair {
    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    // A signing key must come from a CSPRNG. The old fallback seeded a
    // non-cryptographic xoshiro PRNG from time^pid - a low-entropy, partially
    // predictable space an attacker could search to forge attestations. This
    // Zig version exposes no portable OS-CSPRNG fallback (no std.posix.getrandom;
    // arc4random_buf is absent on non-glibc Linux), so fail closed rather than
    // mint a weak key - mirroring zttp:id, which panics rather than seed its
    // CSPRNG from anything but /dev/urandom.
    fillCsprng(&seed) catch @panic("attest: /dev/urandom unavailable; refusing to mint a signing key from a weak seed");
    return envelope.keyPairFromSeed(seed) catch unreachable;
}

fn fillCsprng(buf: *[Ed25519.KeyPair.seed_length]u8) !void {
    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.UrandomOpenFailed;
    defer _ = std.c.close(fd);
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = std.c.read(fd, buf[filled..].ptr, buf.len - filled);
        if (n <= 0) return error.UrandomReadFailed;
        filled += @intCast(n);
    }
}

// The receipt uses an all-zero `capabilityHash` to mean "this contract makes no
// capability statement". That reading is only sound while a contract which DOES
// make one can never hash to zero, so pin both halves here rather than trusting
// the comment at the call site.
test "an all-zero capabilityHash means absent, and a present matrix never produces one" {
    // An empty capability list is a statement, not the absence of one: it
    // hashes over no input, which is SHA-256's empty digest, not zeros.
    const empty_list_hash = zts.module_binding.capabilityHash(&.{});
    try std.testing.expect(!std.mem.allEqual(u8, &empty_list_hash, 0));

    // A matrix built the normal way is always stamped, including when no
    // specifier maps to a capability.
    const no_caps = zts.handler_contract.computeCapabilityMatrix(&.{});
    try std.testing.expect(!std.mem.allEqual(u8, &no_caps.hash, 0));
    try std.testing.expectEqual(@as(u8, 0), no_caps.len);

    const with_caps = zts.handler_contract.computeCapabilityMatrix(&.{"zttp:crypto"});
    try std.testing.expect(with_caps.len > 0);
    try std.testing.expect(!std.mem.allEqual(u8, &with_caps.hash, 0));
    try std.testing.expect(!std.mem.eql(u8, &no_caps.hash, &with_caps.hash));

    // No assertion here on `bytesToHex` of a zero array: that is a property of
    // std.fmt, not of this file, and it stayed green regardless of what the
    // receipt did. What this test can honestly pin is the invariant the
    // receipt's encoding depends on - that a present matrix never hashes to
    // zero - which the assertions above cover. Pinning the emitted claim
    // itself needs a signing key and a built contract, so it belongs with the
    // envelope round-trip tests rather than here.
}
