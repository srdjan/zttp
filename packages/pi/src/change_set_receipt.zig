//! Builds the one transcript/session receipt for an aggregate source change set.

const std = @import("std");
const zts = @import("zts");
const ui_payload = @import("ui_payload.zig");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const aggregate_proof = @import("aggregate_proof.zig");
const proof_enrichment = @import("proof_enrichment.zig");

pub fn build(
    allocator: std.mem.Allocator,
    prepared: *const change_set.PreparedChangeSet,
    snapshot: *const workspace_snapshot.Snapshot,
    proof: *const aggregate_proof.AggregateProof,
    applied_at_unix_ms: i64,
) !ui_payload.VerifiedChangeSetPayload {
    const changes = try allocator.alloc(ui_payload.VerifiedChange, prepared.changes.len);
    for (changes) |*change| change.* = undefined;
    var changes_initialized: usize = 0;
    errdefer {
        while (changes_initialized > 0) {
            changes_initialized -= 1;
            changes[changes_initialized].deinit(allocator);
        }
        allocator.free(changes);
    }
    while (changes_initialized < prepared.changes.len) : (changes_initialized += 1) {
        changes[changes_initialized] = try buildChange(allocator, &prepared.changes[changes_initialized]);
    }

    const proof_inputs = try allocator.alloc(ui_payload.VerifiedProofInput, snapshot.entries.len);
    for (proof_inputs) |*input| input.* = undefined;
    var inputs_initialized: usize = 0;
    errdefer {
        while (inputs_initialized > 0) {
            inputs_initialized -= 1;
            proof_inputs[inputs_initialized].deinit(allocator);
        }
        allocator.free(proof_inputs);
    }
    while (inputs_initialized < snapshot.entries.len) : (inputs_initialized += 1) {
        const input = snapshot.entries[inputs_initialized];
        proof_inputs[inputs_initialized] = try buildProofInput(allocator, input);
    }

    const proof_roots = try cloneStrings(allocator, proof.proof_roots);
    errdefer freeStrings(allocator, proof_roots);
    const proof_schema = try allocator.dupe(u8, aggregate_proof.proof_schema_version);
    errdefer allocator.free(proof_schema);
    const transaction_id = try allocator.dupe(u8, &proof.proof_id);
    errdefer allocator.free(transaction_id);
    const compiler_version = try allocator.dupe(u8, zts.version.string);
    errdefer allocator.free(compiler_version);
    const profile_id = try allocator.dupe(u8, zts.GrammarCatalog.profile_id);
    errdefer allocator.free(profile_id);
    const policy_hash = try allocator.dupe(u8, &proof.policy_hash);
    errdefer allocator.free(policy_hash);
    const grammar_hash = try allocator.dupe(u8, &zts.grammarHash());
    errdefer allocator.free(grammar_hash);
    const semantics_hash = try allocator.dupe(u8, &zts.semanticsHash());
    errdefer allocator.free(semantics_hash);
    const diagnostics_hash = try allocator.dupe(u8, &zts.diagnosticCatalogHash());
    errdefer allocator.free(diagnostics_hash);
    const read_set_digest = try allocator.dupe(u8, &proof.read_set_digest);
    errdefer allocator.free(read_set_digest);

    return .{
        .proof_schema_version = proof_schema,
        .transaction_id = transaction_id,
        .compiler_version = compiler_version,
        .profile_id = profile_id,
        .policy_hash = policy_hash,
        .grammar_hash = grammar_hash,
        .semantics_hash = semantics_hash,
        .diagnostic_catalog_hash = diagnostics_hash,
        .read_set_digest = read_set_digest,
        .applied_at_unix_ms = applied_at_unix_ms,
        .system_proven = proof.system_proven,
        .proof_roots = proof_roots,
        .changes = changes,
        .proof_inputs = proof_inputs,
    };
}

fn buildProofInput(
    allocator: std.mem.Allocator,
    input: workspace_snapshot.ReadEntry,
) !ui_payload.VerifiedProofInput {
    const path = try allocator.dupe(u8, input.relative_path);
    errdefer allocator.free(path);
    const state = try allocator.dupe(u8, if (input.state == .absent) "absent" else "present");
    errdefer allocator.free(state);
    const digest = try hexOwned(allocator, input.sha256);
    errdefer allocator.free(digest);
    return .{ .path = path, .state = state, .sha256 = digest };
}

fn buildChange(
    allocator: std.mem.Allocator,
    change: *const change_set.PreparedChange,
) !ui_payload.VerifiedChange {
    const diff = try proof_enrichment.buildUnifiedDiff(allocator, change.baseline.bytes(), change.candidate);
    defer allocator.free(diff.hunks);
    errdefer allocator.free(diff.text);
    const file = try allocator.dupe(u8, change.authored_path);
    errdefer allocator.free(file);
    const state = try allocator.dupe(u8, if (change.baseline == .absent) "absent" else "present");
    errdefer allocator.free(state);
    const baseline_hash = try hexOwned(allocator, change.baseline_sha256);
    errdefer allocator.free(baseline_hash);
    var candidate_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(change.candidate, &candidate_digest, .{});
    const candidate_hash = try hexOwned(allocator, candidate_digest);
    errdefer allocator.free(candidate_hash);
    const before = if (change.baseline.bytes()) |bytes| try allocator.dupe(u8, bytes) else null;
    errdefer if (before) |bytes| allocator.free(bytes);
    const after = try allocator.dupe(u8, change.candidate);
    errdefer allocator.free(after);
    const rewrite_trace = try cloneStrings(allocator, change.rewrite_trace);
    errdefer freeStrings(allocator, rewrite_trace);
    return .{
        .file = file,
        .baseline_state = state,
        .baseline_sha256 = baseline_hash,
        .candidate_sha256 = candidate_hash,
        .before = before,
        .after = after,
        .unified_diff = diff.text,
        .rewrite_trace = rewrite_trace,
    };
}

fn hexOwned(allocator: std.mem.Allocator, digest: [32]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn cloneStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (strings, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn freeStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

const testing = std.testing;

test "change set receipt binds ordered changes and the full proof read set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/context.ts", .data = "context" });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{ .file = "src/a.ts", .content = "new" });
    defer prepared.deinit(testing.allocator);
    var snapshot = try workspace_snapshot.Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    const roots = try testing.allocator.alloc([]u8, 1);
    roots[0] = try testing.allocator.dupe(u8, "src/a.ts");
    var proof: aggregate_proof.AggregateProof = .{
        .proof_id = @splat('a'),
        .policy_hash = zts.policyHash(),
        .read_set_digest = @splat('b'),
        .proof_roots = roots,
        .diagnostics = try testing.allocator.alloc(aggregate_proof.Diagnostic, 0),
        .system_proven = false,
    };
    defer proof.deinit(testing.allocator);

    var receipt = try build(testing.allocator, &prepared, &snapshot, &proof, 42);
    defer receipt.deinit(testing.allocator);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", receipt.transaction_id);
    try testing.expectEqual(@as(usize, 1), receipt.changes.len);
    try testing.expectEqualStrings("old", receipt.changes[0].before.?);
    try testing.expectEqualStrings("new", receipt.changes[0].after);
    try testing.expect(receipt.proof_inputs.len >= 2);
    try testing.expectEqualStrings("src/a.ts", receipt.proof_roots[0]);
}
