//! Read-only derivations over the session transcript.
//!
//! The autoloop derives the current HandlerProperties and latest aggregate
//! proof identity for a file by scanning verified-change-set receipts.
//!
//! Derivation beats materialization here because the transcript is the
//! only source of truth that survives resume via reconstructTranscript.
//! Any cached map on AgentSession would need a rebuild path that tracks
//! the reconstructor; doing the scan on demand removes that duplication
//! entirely. Each call is O(n) where n is transcript length; sessions
//! with thousands of patches can memoize on top if it ever matters.

const std = @import("std");
const transcript_mod = @import("transcript.zig");
const ui_payload = @import("ui_payload.zig");

pub fn changeSetPayload(
    entry: *const transcript_mod.OwnedEntry,
) ?ui_payload.VerifiedChangeSetPayload {
    switch (entry.*) {
        .verified_change_set => |message| {
            const payload = message.ui_payload orelse return null;
            switch (payload) {
                .verified_change_set => |receipt| return receipt,
                else => return null,
            }
        },
        else => return null,
    }
}

pub fn changeSetPayloadIfMatching(
    entry: *const transcript_mod.OwnedEntry,
    file: []const u8,
) ?ui_payload.VerifiedChangeSetPayload {
    const receipt = changeSetPayload(entry) orelse return null;
    for (receipt.changes) |change| {
        if (std.mem.eql(u8, change.file, file)) return receipt;
    }
    return null;
}

/// Return the primary-root properties of the latest receipt touching `file`.
pub fn currentProperties(
    transcript: *const transcript_mod.Transcript,
    file: []const u8,
) ?ui_payload.PropertiesSnapshot {
    var i = transcript.len();
    while (i > 0) {
        i -= 1;
        if (changeSetPayloadIfMatching(transcript.at(i), file)) |receipt| {
            return receipt.primary_properties;
        }
    }
    return null;
}

/// Return the binary aggregate proof id of the latest receipt touching `file`.
pub fn lastChangeSetHash(
    transcript: *const transcript_mod.Transcript,
    file: []const u8,
) ?[32]u8 {
    var i = transcript.len();
    while (i > 0) {
        i -= 1;
        if (changeSetPayloadIfMatching(transcript.at(i), file)) |receipt| {
            if (receipt.transaction_id.len != 64) return null;
            var digest: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&digest, receipt.transaction_id) catch return null;
            return digest;
        }
    }
    return null;
}

/// Read a PropertiesSnapshot field by its string name. Returns false for
/// unknown names, which deliberately aliases "unknown" with "unsatisfied"
/// so a typo in the goal list never silently passes the termination check.
pub fn propertyByName(props: ui_payload.PropertiesSnapshot, name: []const u8) bool {
    inline for (@typeInfo(ui_payload.PropertiesSnapshot).@"struct".fields) |field| {
        if (field.type != bool) continue;
        if (std.mem.eql(u8, field.name, name)) {
            return @field(props, field.name);
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn appendChangeSet(
    allocator: std.mem.Allocator,
    tr: *transcript_mod.Transcript,
    file: []const u8,
    hash: ?[32]u8,
    after: ui_payload.PropertiesSnapshot,
) !void {
    var transaction_buffer: [64]u8 = undefined;
    const transaction_id: []u8 = if (hash) |value| blk: {
        transaction_buffer = std.fmt.bytesToHex(value, .lower);
        break :blk &transaction_buffer;
    } else @constCast("g" ** 64);
    var changes = [_]ui_payload.VerifiedChange{.{
        .file = @constCast(file),
        .baseline_state = @constCast("absent"),
        .baseline_sha256 = @constCast("a" ** 64),
        .candidate_sha256 = @constCast("b" ** 64),
        .before = null,
        .after = @constCast(""),
        .unified_diff = @constCast(""),
    }};
    var roots = [_][]u8{@constCast(file)};
    var inputs = [_]ui_payload.VerifiedProofInput{.{
        .path = @constCast(file),
        .state = @constCast("absent"),
        .sha256 = @constCast("a" ** 64),
    }};
    const source: ui_payload.UiPayload = .{ .verified_change_set = .{
        .proof_schema_version = @constCast("test-proof-v1"),
        .transaction_id = transaction_id,
        .compiler_version = @constCast("test"),
        .profile_id = @constCast("test"),
        .policy_hash = @constCast("c" ** 64),
        .grammar_hash = @constCast("d" ** 64),
        .semantics_hash = @constCast("e" ** 64),
        .diagnostic_catalog_hash = @constCast("f" ** 64),
        .read_set_digest = @constCast("1" ** 64),
        .applied_at_unix_ms = 0,
        .system_proven = false,
        .primary_properties = after,
        .proof_roots = &roots,
        .changes = &changes,
        .proof_inputs = &inputs,
    } };
    var receipt = try source.clone(allocator);
    errdefer receipt.deinit(allocator);
    const llm_text = try allocator.dupe(u8, "verified");
    errdefer allocator.free(llm_text);

    try tr.entries.append(allocator, .{ .verified_change_set = .{
        .llm_text = llm_text,
        .ui_payload = receipt,
    } });
}

fn zeroProps() ui_payload.PropertiesSnapshot {
    return .{
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
        .idempotent = false,
        .max_io_depth = null,
        .injection_safe = false,
        .state_isolated = false,
        .fault_covered = false,
        .result_safe = false,
        .optional_safe = false,
    };
}

test "currentProperties returns the latest patch for the matching file" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    var p1 = zeroProps();
    p1.retry_safe = false;
    try appendChangeSet(testing.allocator, &tr, "handler.ts", null, p1);

    var p2 = zeroProps();
    p2.retry_safe = true;
    try appendChangeSet(testing.allocator, &tr, "handler.ts", null, p2);

    const current = currentProperties(&tr, "handler.ts");
    try testing.expect(current != null);
    try testing.expect(current.?.retry_safe);
}

test "provider projection does not hide raw proof state" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var props = zeroProps();
    props.retry_safe = true;
    try appendChangeSet(testing.allocator, &tr, "handler.ts", null, props);
    try tr.replaceProjection(testing.allocator, "summary", tr.nextEntryId());

    const current = currentProperties(&tr, "handler.ts") orelse return error.TestExpectedProperties;
    try testing.expect(current.retry_safe);
    try testing.expectEqual(@as(usize, 1), tr.len());
}

test "currentProperties returns null when no patch matches the file" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    try appendChangeSet(testing.allocator, &tr, "other.ts", null, zeroProps());

    const current = currentProperties(&tr, "handler.ts");
    try testing.expect(current == null);
}

test "currentProperties is scoped per file" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    var a = zeroProps();
    a.pure = true;
    try appendChangeSet(testing.allocator, &tr, "a.ts", null, a);

    var b = zeroProps();
    b.retry_safe = true;
    try appendChangeSet(testing.allocator, &tr, "b.ts", null, b);

    const ca = currentProperties(&tr, "a.ts").?;
    const cb = currentProperties(&tr, "b.ts").?;
    try testing.expect(ca.pure);
    try testing.expect(!ca.retry_safe);
    try testing.expect(cb.retry_safe);
    try testing.expect(!cb.pure);
}

test "lastChangeSetHash returns the most recent hash for the file" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    var h1: [32]u8 = undefined;
    for (&h1, 0..) |*b, i| b.* = @intCast(i);
    var h2: [32]u8 = undefined;
    for (&h2, 0..) |*b, i| b.* = @intCast(i + 100);

    try appendChangeSet(testing.allocator, &tr, "handler.ts", h1, zeroProps());
    try appendChangeSet(testing.allocator, &tr, "handler.ts", h2, zeroProps());

    const latest = lastChangeSetHash(&tr, "handler.ts");
    try testing.expect(latest != null);
    try testing.expectEqualSlices(u8, &h2, &latest.?);
}

test "lastChangeSetHash returns null for a malformed transaction identity" {
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);

    try appendChangeSet(testing.allocator, &tr, "handler.ts", null, zeroProps());

    try testing.expect(lastChangeSetHash(&tr, "handler.ts") == null);
}
