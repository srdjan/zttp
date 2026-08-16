const std = @import("std");
const zts = @import("zts");

const session_events = @import("session/events.zig");
const session_id_mod = @import("session/session_id.zig");
const session_paths = @import("session/paths.zig");
const protocol_identity = @import("session/protocol_identity.zig");
const tool_registry = @import("tool_registry.zig");
const models_registry = @import("providers/models.zig");
const ui_payload = @import("ui_payload.zig");
const turn = @import("turn.zig");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const aggregate_proof = @import("aggregate_proof.zig");
const change_transaction = @import("change_transaction.zig");
const change_set_receipt = @import("change_set_receipt.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

const marker_relpath = ".zttp/proof-passport-session";
const dir_marker_relpath = ".zttp/proof-passport-session-dir";

pub const Step = enum {
    baseline,
    witness,
    repaired,
    deployed,
};

pub const SessionInfo = struct {
    session_id: []u8,
    session_dir: []u8,
    events_path: []u8,
    meta_path: []u8,
    expert_command: []u8,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.session_dir);
        allocator.free(self.events_path);
        allocator.free(self.meta_path);
        allocator.free(self.expert_command);
        self.* = undefined;
    }
};

pub const AppendOptions = struct {
    workspace_root: []const u8,
    handler_path: []const u8,
    step: Step,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    deploy_artifact: ?[]const u8 = null,
};

pub fn ensureSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) !SessionInfo {
    const session_id = try readOrCreateSessionId(allocator, workspace_root);
    errdefer allocator.free(session_id);

    const session_dir = try readOrCreateSessionDir(allocator, workspace_root, session_id);
    errdefer allocator.free(session_dir);

    const realpath = try workspaceRealpath(allocator, workspace_root);
    defer allocator.free(realpath);
    try session_paths.writeWorkspacePointer(allocator, session_dir, realpath);

    const events_path = try std.fs.path.join(allocator, &.{ session_dir, "events.jsonl" });
    errdefer allocator.free(events_path);
    const meta_path = try std.fs.path.join(allocator, &.{ session_dir, "meta.json" });
    errdefer allocator.free(meta_path);

    if (!zts.file_io.fileExists(allocator, meta_path)) {
        const policy_hash = zts.policyHash();
        var registry = try tool_registry.buildRegistry(allocator);
        defer registry.deinit(allocator);
        const protocol_hash = try protocol_identity.current(allocator, &registry);
        const model = models_registry.defaultForProvider(models_registry.default_provider);
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = session_id,
            .workspace_realpath = realpath,
            .created_at_unix_ms = nowUnixMs(),
            .policy_hash = policy_hash[0..],
            .protocol_hash = protocol_hash[0..],
            .provider = model.provider.publicName(),
            .model = model.id,
        });
    }

    const expert_command = try buildExpertCommand(allocator, realpath, session_id);
    errdefer allocator.free(expert_command);

    return .{
        .session_id = session_id,
        .session_dir = session_dir,
        .events_path = events_path,
        .meta_path = meta_path,
        .expert_command = expert_command,
    };
}

pub fn appendStep(
    allocator: std.mem.Allocator,
    options: AppendOptions,
) !SessionInfo {
    var info = try ensureSession(allocator, options.workspace_root);
    errdefer info.deinit(allocator);

    switch (options.step) {
        .baseline => try appendBaseline(allocator, info.events_path),
        .witness => try appendWitness(allocator, info.events_path, options.handler_path),
        .repaired => try appendVerifiedChangeSet(allocator, info.events_path, options),
        .deployed => try appendDeployed(allocator, info.events_path, options.deploy_artifact),
    }
    return info;
}

pub fn resetToBaseline(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) !SessionInfo {
    var info = try ensureSession(allocator, workspace_root);
    errdefer info.deinit(allocator);
    try zts.file_io.writeFile(allocator, info.events_path, "");
    try appendBaseline(allocator, info.events_path);
    return info;
}

fn appendBaseline(
    allocator: std.mem.Allocator,
    events_path: []const u8,
) !void {
    try session_events.appendEntryEvent(allocator, events_path, try session_events.nextEntryId(allocator, events_path), null, .{
        .system_note = "Proof Passport baseline: Studio loaded a green demo workspace with declared specs for injection_safe and no_secret_leakage.",
    });
}

fn appendWitness(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    handler_path: []const u8,
) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "Proof Passport witness: unsafe SECRET_KEY flow in {s}. GET /status moves env(\"SECRET_KEY\") into Response.json; no_secret_leakage is broken until the status payload is repaired.",
        .{handler_path},
    );
    defer allocator.free(body);

    const payload_text = try allocator.dupe(u8, body);
    errdefer allocator.free(payload_text);
    var payload: ui_payload.UiPayload = .{ .plain_text = payload_text };
    defer payload.deinit(allocator);

    try session_events.appendEntryEvent(allocator, events_path, try session_events.nextEntryId(allocator, events_path), null, .{ .diagnostic_box = .{
        .llm_text = body,
        .ui_payload = payload,
    } });
}

fn appendVerifiedChangeSet(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    options: AppendOptions,
) !void {
    const before = options.before orelse return error.MissingBeforeSource;
    const after = options.after orelse return error.MissingAfterSource;
    const relative_path = try std.fs.path.relative(
        allocator,
        options.workspace_root,
        null,
        options.workspace_root,
        options.handler_path,
    );
    defer allocator.free(relative_path);
    var lock = try change_transaction.WorkspaceLock.acquire(allocator, options.workspace_root);
    defer lock.deinit();
    _ = try change_transaction.recoverAllLocked(allocator, &lock, options.workspace_root);
    var prepared = try change_set.prepare(allocator, options.workspace_root, turn.ChangeSet{
        .file = relative_path,
        .content = after,
    });
    defer prepared.deinit(allocator);
    if (prepared.changes[0].baseline.bytes() == null or
        !std.mem.eql(u8, prepared.changes[0].baseline.bytes().?, before))
    {
        return error.DemoRepairBaselineChanged;
    }
    var snapshot = try workspace_snapshot.Snapshot.capture(allocator, &prepared);
    defer snapshot.deinit(allocator);
    var result = try aggregate_proof.prove(allocator, &prepared, &snapshot);
    defer result.deinit(allocator);
    const proof = switch (result) {
        .rejected => return error.DemoRepairRejected,
        .accepted => |*accepted| accepted,
    };
    var payload: ui_payload.UiPayload = .{ .verified_change_set = try change_set_receipt.buildWithProvenance(
        allocator,
        &prepared,
        &snapshot,
        proof,
        nowUnixMs(),
        .{ .goal_context = &.{ "no_secret_leakage", "injection_safe" } },
    ) };
    defer payload.deinit(allocator);
    var receipt_json = TextBuffer.init(allocator);
    defer receipt_json.deinit();
    try ui_payload.writeJson(receipt_json.writer(), payload);
    var committed = try change_transaction.commitLocked(
        allocator,
        &lock,
        &prepared,
        &snapshot,
        proof,
        .{ .receipt_json = receipt_json.written() },
    );
    defer committed.deinit(allocator);

    try session_events.appendEntryEvent(allocator, events_path, try session_events.nextEntryId(allocator, events_path), null, .{ .verified_change_set = .{
        .llm_text = "Verified change set: repaired src/handler.tsx and restored no_secret_leakage.",
        .ui_payload = payload,
    } });
    try change_transaction.markReceiptedLocked(allocator, &lock, options.workspace_root, &proof.proof_id);
}

fn appendDeployed(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    deploy_artifact: ?[]const u8,
) !void {
    const artifact = deploy_artifact orelse ".zttp/deploy/<service>";
    const body = try std.fmt.allocPrint(
        allocator,
        "Proof Passport deploy receipt: ledger .zttp/proofs.jsonl and local artifact {s} are present.",
        .{artifact},
    );
    defer allocator.free(body);
    try session_events.appendEntryEvent(allocator, events_path, try session_events.nextEntryId(allocator, events_path), null, .{ .system_note = body });
}

fn readOrCreateSessionId(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]u8 {
    const marker_path = try std.fs.path.join(allocator, &.{ workspace_root, marker_relpath });
    defer allocator.free(marker_path);

    if (zts.file_io.readFile(allocator, marker_path, 4096)) |raw| {
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    } else |_| {}

    const id = try session_id_mod.generate(allocator);
    errdefer allocator.free(id);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{id});
    defer allocator.free(line);
    try zts.file_io.writeFile(allocator, marker_path, line);
    return id;
}

fn readOrCreateSessionDir(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]u8 {
    const marker_path = try std.fs.path.join(allocator, &.{ workspace_root, dir_marker_relpath });
    defer allocator.free(marker_path);

    if (zts.file_io.readFile(allocator, marker_path, 4096)) |raw| {
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    } else |_| {}

    const session_dir = try session_paths.sessionDirForWorkspace(allocator, workspace_root, session_id);
    errdefer allocator.free(session_dir);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{session_dir});
    defer allocator.free(line);
    try zts.file_io.writeFile(allocator, marker_path, line);
    return session_dir;
}

fn workspaceRealpath(allocator: std.mem.Allocator, workspace_root: []const u8) ![:0]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io_backend.io(), workspace_root, allocator);
}

fn buildExpertCommand(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]u8 {
    const quoted_root = try shellQuote(allocator, workspace_root);
    defer allocator.free(quoted_root);
    const quoted_id = try shellQuote(allocator, session_id);
    defer allocator.free(quoted_id);
    return try std.fmt.allocPrint(allocator, "cd {s} && zttp expert --session-id {s}", .{ quoted_root, quoted_id });
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn nowUnixMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(@enumFromInt(@intFromEnum(std.posix.CLOCK.REALTIME)), &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const testing = std.testing;

test "demo passport expert command shell-quotes workspace and session" {
    const allocator = testing.allocator;
    const command = try buildExpertCommand(allocator, "/tmp/proof demo", "abc'123");
    defer allocator.free(command);
    try testing.expectEqualStrings("cd '/tmp/proof demo' && zttp expert --session-id 'abc'\\''123'", command);
}
