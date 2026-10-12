//! Shared proof-receipt signer for build-time attestation.

const std = @import("std");
const zts = @import("zts");

const envelope = @import("envelope.zig");
const header_strings = @import("header_strings.zig");
const identity = @import("identity.zig");
const proof_ledger = @import("../proof_ledger.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const compiler_version_tag: []const u8 = "zttp-attest-source-identity-v2";
const max_guarded_categories_bytes = "env,egress,cache,sql".len;

fn guardedCategories(
    buffer: *[max_guarded_categories_bytes]u8,
    contract: *const zts.HandlerContract,
) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var wrote_any = false;
    inline for (.{
        .{ "env", contract.env.dynamic },
        .{ "egress", contract.egress.dynamic },
        .{ "cache", contract.cache.dynamic },
        .{ "sql", contract.sql.dynamic },
    }) |category| {
        if (category[1]) {
            if (wrote_any) writer.writeByte(',') catch unreachable;
            writer.writeAll(category[0]) catch unreachable;
            wrote_any = true;
        }
    }
    return writer.buffered();
}

/// Produces a compact JWS for build/deploy artifacts. Uses the persistent
/// identity under ~/.zttp/attest and fails if that identity cannot be
/// loaded safely. Caller owns the returned bytes.
pub fn buildJws(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
    executable_root_sha256: []const u8,
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
        executable_root_sha256,
        loaded.key_pair,
    );
}

fn buildJwsWithKey(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
    executable_root_sha256: []const u8,
    key_pair: Ed25519.KeyPair,
) ![]u8 {
    if (!contract.source_identity.isStamped()) return error.SourceIdentityMissing;

    var contract_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contract_json, &contract_sha, .{});
    const contract_sha_hex = std.fmt.bytesToHex(contract_sha, .lower);

    var bytecode_sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytecode, &bytecode_sha, .{});
    const bytecode_sha_hex = std.fmt.bytesToHex(bytecode_sha, .lower);

    const policy_sha_hex = zts.policyHash();
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
    const core_grammar_hex = std.fmt.bytesToHex(contract.source_identity.core_grammar_hash, .lower);
    const semantics_hex = std.fmt.bytesToHex(contract.source_identity.semantics_hash, .lower);
    // Name every field. HandlerProperties defaults the six flow and isolation
    // fields to true, so relying on the defaults here would put proof chips
    // for properties the contract never asserted into a signed claim.
    const props_or_default = contract.properties orelse zts.HandlerProperties{
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
    var guarded_categories_buffer: [max_guarded_categories_bytes]u8 = undefined;
    const guarded_categories = guardedCategories(&guarded_categories_buffer, contract);

    const claims = envelope.Claims{
        .contract_sha256 = &contract_sha_hex,
        .bytecode_sha256 = &bytecode_sha_hex,
        .policy_sha256 = &policy_sha_hex,
        .capability_hash = &capability_hash_hex,
        .runtime_policy_sha256 = runtime_policy_sha256,
        .executable_root_sha256 = executable_root_sha256,
        .core_profile_id = contract.source_identity.core_profile.id(),
        .core_grammar_sha256 = &core_grammar_hex,
        .semantics_sha256 = &semantics_hex,
        .compiler_version = compiler_version_tag,
        .signed_at_unix = @divTrunc(proof_ledger.defaultNowMs(), std.time.ms_per_s),
        .property_summary = property_summary,
        .guarded_categories = guarded_categories,
        .routes_count = @intCast(contract.api.routes.items.len),
    };

    var env = try envelope.sign(allocator, claims, key_pair);
    return env.intoJws();
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
    const no_caps = zts.computeCapabilityMatrix(&.{});
    try std.testing.expect(!std.mem.allEqual(u8, &no_caps.hash, 0));
    try std.testing.expectEqual(@as(u8, 0), no_caps.len);

    const with_caps = zts.computeCapabilityMatrix(&.{"zttp:crypto"});
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

test "build receipt refuses unstamped contracts and signs core source identity" {
    const allocator = std.testing.allocator;
    var contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    const key_pair = try envelope.keyPairFromSeed([_]u8{0x41} ** Ed25519.KeyPair.seed_length);

    try std.testing.expectError(error.SourceIdentityMissing, buildJwsWithKey(
        allocator,
        "{}",
        "bytecode",
        &contract,
        envelope.unpinned_runtime_policy_sha256,
        "9" ** 64,
        key_pair,
    ));

    contract.source_identity = zts.sourceIdentityForPath(contract.handler.path);
    const jws = try buildJwsWithKey(
        allocator,
        "{}",
        "bytecode",
        &contract,
        envelope.unpinned_runtime_policy_sha256,
        "9" ** 64,
        key_pair,
    );
    defer allocator.free(jws);
    var verified = try envelope.verify(allocator, jws);
    defer verified.deinit();

    const core_grammar_hex = std.fmt.bytesToHex(contract.source_identity.core_grammar_hash, .lower);
    const semantics_hex = std.fmt.bytesToHex(contract.source_identity.semantics_hash, .lower);
    try std.testing.expectEqualStrings(contract.source_identity.core_profile.id(), verified.claims.core_profile_id);
    try std.testing.expectEqualStrings(&core_grammar_hex, verified.claims.core_grammar_sha256);
    try std.testing.expectEqualStrings(&semantics_hex, verified.claims.semantics_sha256);
    try std.testing.expectEqualStrings("", verified.claims.guarded_categories);
    // The receipt carries the executable-graph root it was handed, not a
    // recomputation of its own: the signer commits, the consumer checks.
    try std.testing.expectEqualStrings("9" ** 64, verified.claims.executable_root_sha256);
}

test "build receipt signs dynamic capability categories in stable order" {
    const allocator = std.testing.allocator;
    var contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    contract.source_identity = zts.sourceIdentityForPath(contract.handler.path);
    contract.env.dynamic = true;
    contract.egress.dynamic = true;
    contract.cache.dynamic = true;
    contract.sql.dynamic = true;
    const key_pair = try envelope.keyPairFromSeed([_]u8{0x43} ** Ed25519.KeyPair.seed_length);

    const jws = try buildJwsWithKey(
        allocator,
        "{}",
        "bytecode",
        &contract,
        envelope.unpinned_runtime_policy_sha256,
        "9" ** 64,
        key_pair,
    );
    defer allocator.free(jws);

    var verified = try envelope.verify(allocator, jws);
    defer verified.deinit();
    try std.testing.expectEqualStrings("env,egress,cache,sql", verified.claims.guarded_categories);
}

test "a dev receipt states that it commits to no executable graph" {
    const allocator = std.testing.allocator;
    var contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts"));
    defer contract.deinit(allocator);
    contract.source_identity = zts.sourceIdentityForPath(contract.handler.path);
    const key_pair = try envelope.keyPairFromSeed([_]u8{0x42} ** Ed25519.KeyPair.seed_length);

    const jws = try buildJwsWithKey(
        allocator,
        "{}",
        "bytecode",
        &contract,
        envelope.unpinned_runtime_policy_sha256,
        envelope.unpinned_executable_root,
        key_pair,
    );
    defer allocator.free(jws);

    var verified = try envelope.verify(allocator, jws);
    defer verified.deinit();
    // The sentinel is a statement, not an omission: a verifier can tell "this
    // receipt commits to no graph" from "this receipt's graph is missing".
    try std.testing.expectEqualStrings(
        envelope.unpinned_executable_root,
        verified.claims.executable_root_sha256,
    );
}
