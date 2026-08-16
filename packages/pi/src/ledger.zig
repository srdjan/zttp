const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const zts = @import("zts");
const transcript_mod = @import("transcript.zig");
const ui_payload = @import("ui_payload.zig");
const turn = @import("turn.zig");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const aggregate_proof = @import("aggregate_proof.zig");
const change_transaction = @import("change_transaction.zig");
const session_events = @import("session/events.zig");
const session_paths = @import("session/paths.zig");
const reconstructor = @import("session/reconstructor.zig");
const json_writer = @import("providers/json_writer.zig");
const tools_common = @import("tools/common.zig");

pub const export_schema_version: u32 = 2;

pub const ExportMeta = struct {
    workspace_hash: []u8,
    session_id: []u8,
    parent_session_id: ?[]u8,
    exported_at_unix_ms: i64,

    pub fn deinit(self: *ExportMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_hash);
        allocator.free(self.session_id);
        if (self.parent_session_id) |parent| allocator.free(parent);
        self.* = .{
            .workspace_hash = &.{},
            .session_id = &.{},
            .parent_session_id = null,
            .exported_at_unix_ms = 0,
        };
    }
};

pub const LedgerChangeSet = struct {
    session_id: []u8,
    summary: []u8,
    payload: ui_payload.VerifiedChangeSetPayload,

    pub fn deinit(self: *LedgerChangeSet, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.summary);
        self.payload.deinit(allocator);
        self.* = .{
            .session_id = &.{},
            .summary = &.{},
            .payload = undefined,
        };
    }
};

pub const ExportBundle = struct {
    meta: ExportMeta,
    change_sets: []LedgerChangeSet,

    pub fn deinit(self: *ExportBundle, allocator: std.mem.Allocator) void {
        self.meta.deinit(allocator);
        for (self.change_sets) |*change_set_receipt| change_set_receipt.deinit(allocator);
        allocator.free(self.change_sets);
        self.* = .{
            .meta = undefined,
            .change_sets = &.{},
        };
    }
};

pub const ReplayKind = enum {
    success,
    policy_drift,
    violation_drift,
    prove_drift,
    system_drift,
    apply_failure,
};

pub const ReplayResult = struct {
    kind: ReplayKind,
    change_set_index: usize,
    file: []u8,
    detail: []u8,

    pub fn deinit(self: *ReplayResult, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.detail);
        self.* = .{
            .kind = .success,
            .change_set_index = 0,
            .file = &.{},
            .detail = &.{},
        };
    }
};

pub fn exportSessionLedger(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    out_path: []const u8,
) !void {
    var bundle = try collectSessionLedger(allocator, session_id);
    defer bundle.deinit(allocator);

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try writeMetaLine(w, bundle.meta);
    try w.writeByte('\n');
    for (bundle.change_sets) |change_set_receipt| {
        try writeChangeSetLine(w, change_set_receipt);
        try w.writeByte('\n');
    }

    try zts.file_io.writeFile(allocator, out_path, buf.written());
}

pub fn collectSessionLedger(
    allocator: std.mem.Allocator,
    session_id: []const u8,
) !ExportBundle {
    const root = try session_paths.sessionRoot(allocator);
    defer allocator.free(root);
    const hash = try session_paths.cwdHashFull(allocator);

    const entries = try session_paths.listSessions(allocator, root, hash[0..]);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    try by_id.ensureUnusedCapacity(allocator, @intCast(entries.len));
    for (entries, 0..) |entry, i| {
        by_id.putAssumeCapacity(entry.session_id, i);
    }

    const target_index = by_id.get(session_id) orelse return error.SessionNotFound;
    var chain = std.ArrayList(usize).empty;
    defer chain.deinit(allocator);

    var cursor_index: ?usize = target_index;
    while (cursor_index) |index| {
        try chain.append(allocator, index);
        cursor_index = if (entries[index].parent_id) |parent_id|
            by_id.get(parent_id)
        else
            null;
    }
    std.mem.reverse(usize, chain.items);

    var change_sets: std.ArrayList(LedgerChangeSet) = .empty;
    defer change_sets.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit(allocator);
    }

    for (chain.items) |index| {
        const events_path = try std.fs.path.join(allocator, &.{ entries[index].dir_path, "events.jsonl" });
        defer allocator.free(events_path);
        var transcript = reconstructor.reconstructTranscript(allocator, events_path, null) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer transcript.deinit(allocator);

        for (transcript.entries.items) |*entry| {
            switch (entry.*) {
                .verified_change_set => |message| {
                    const receipt_payload = if (message.ui_payload) |payload|
                        switch (payload) {
                            .verified_change_set => |value| value,
                            else => continue,
                        }
                    else
                        continue;

                    const fingerprint = receipt_payload.transaction_id;
                    if (seen.contains(fingerprint)) continue;
                    try seen.put(allocator, try allocator.dupe(u8, fingerprint), {});

                    try change_sets.append(allocator, .{
                        .session_id = try allocator.dupe(u8, entries[index].session_id),
                        .summary = try allocator.dupe(u8, message.llm_text),
                        .payload = try receipt_payload.clone(allocator),
                    });
                },
                else => {},
            }
        }
    }

    return .{
        .meta = .{
            .workspace_hash = try allocator.dupe(u8, hash[0..]),
            .session_id = try allocator.dupe(u8, entries[target_index].session_id),
            .parent_session_id = if (entries[target_index].parent_id) |parent|
                try allocator.dupe(u8, parent)
            else
                null,
            .exported_at_unix_ms = nowUnixMs(),
        },
        .change_sets = try change_sets.toOwnedSlice(allocator),
    };
}

pub fn readLedgerFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
) !ExportBundle {
    const raw = try zts.file_io.readFile(allocator, input_path, 64 * 1024 * 1024);
    defer allocator.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const meta_line = lines.next() orelse return error.InvalidLedgerFile;
    if (meta_line.len == 0) return error.InvalidLedgerFile;

    var bundle = ExportBundle{
        .meta = try parseMetaLine(allocator, meta_line),
        .change_sets = try allocator.alloc(LedgerChangeSet, 0),
    };
    errdefer bundle.deinit(allocator);

    var change_sets = std.ArrayList(LedgerChangeSet).empty;
    defer change_sets.deinit(allocator);

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try change_sets.append(allocator, try parseChangeSetLine(allocator, line));
    }

    bundle.change_sets = try change_sets.toOwnedSlice(allocator);
    return bundle;
}

pub fn replayBundleInWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    bundle: *const ExportBundle,
) !ReplayResult {
    var workspace_lock = try change_transaction.WorkspaceLock.acquire(allocator, workspace_root);
    defer workspace_lock.deinit();
    _ = try change_transaction.recoverAllLocked(allocator, &workspace_lock, workspace_root);

    for (bundle.change_sets, 0..) |change_set_receipt, index| {
        const receipt = change_set_receipt.payload;
        const primary_file = receipt.changes[0].file;
        const additional = try allocator.alloc(turn.Change, receipt.changes.len - 1);
        defer allocator.free(additional);
        for (receipt.changes[1..], additional) |change, *out| out.* = .{
            .file = change.file,
            .content = change.after,
        };
        var prepared = change_set.prepare(allocator, workspace_root, .{
            .file = primary_file,
            .content = receipt.changes[0].after,
            .additional = additional,
        }) catch |err| {
            return replayFailure(allocator, .apply_failure, index, primary_file, @errorName(err));
        };
        defer prepared.deinit(allocator);
        if (!receiptMatchesBaselines(&prepared, receipt)) {
            return replayFailure(
                allocator,
                .apply_failure,
                index,
                primary_file,
                "current source baselines do not match the receipt",
            );
        }

        var snapshot = workspace_snapshot.Snapshot.capture(allocator, &prepared) catch |err| {
            return replayFailure(allocator, .prove_drift, index, primary_file, @errorName(err));
        };
        defer snapshot.deinit(allocator);
        var result = try aggregate_proof.prove(allocator, &prepared, &snapshot);
        defer result.deinit(allocator);
        const proof = switch (result) {
            .rejected => |rejection| return replayFailure(allocator, .prove_drift, index, primary_file, rejection.message),
            .accepted => |*accepted| accepted,
        };

        if (!std.mem.eql(u8, &proof.policy_hash, receipt.policy_hash)) {
            return replayFailure(allocator, .policy_drift, index, primary_file, "compiler policy identity changed");
        }
        if (!receiptMatchesProof(receipt, proof)) {
            return replayFailure(allocator, .prove_drift, index, primary_file, "aggregate proof identity or read set changed");
        }

        var receipt_json = TextBuffer.init(allocator);
        defer receipt_json.deinit();
        try ui_payload.writeJson(receipt_json.writer(), .{ .verified_change_set = receipt });
        var committed = change_transaction.commitLocked(
            allocator,
            &workspace_lock,
            &prepared,
            &snapshot,
            proof,
            .{ .receipt_json = receipt_json.written() },
        ) catch |err| {
            return replayFailure(allocator, .apply_failure, index, primary_file, @errorName(err));
        };
        defer committed.deinit(allocator);
        try change_transaction.markReceiptedLocked(
            allocator,
            &workspace_lock,
            workspace_root,
            &proof.proof_id,
        );
    }

    return .{
        .kind = .success,
        .change_set_index = bundle.change_sets.len,
        .file = try allocator.dupe(u8, ""),
        .detail = try std.fmt.allocPrint(allocator, "replayed {d} change set(s)", .{bundle.change_sets.len}),
    };
}

fn replayFailure(
    allocator: std.mem.Allocator,
    kind: ReplayKind,
    index: usize,
    file: []const u8,
    detail: []const u8,
) !ReplayResult {
    return .{
        .kind = kind,
        .change_set_index = index,
        .file = try allocator.dupe(u8, file),
        .detail = try allocator.dupe(u8, detail),
    };
}

fn receiptMatchesBaselines(
    prepared: *const change_set.PreparedChangeSet,
    receipt: ui_payload.VerifiedChangeSetPayload,
) bool {
    if (prepared.changes.len != receipt.changes.len) return false;
    for (prepared.changes, receipt.changes) |actual, expected| {
        if (!std.mem.eql(u8, actual.authored_path, expected.file)) return false;
        const expected_state = if (actual.baseline == .absent) "absent" else "present";
        if (!std.mem.eql(u8, expected_state, expected.baseline_state)) return false;
        const digest = std.fmt.bytesToHex(actual.baseline_sha256, .lower);
        if (!std.mem.eql(u8, &digest, expected.baseline_sha256)) return false;
        if (!optionalStringEqual(actual.baseline.bytes(), expected.before)) return false;
        var candidate_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(actual.candidate, &candidate_digest, .{});
        const candidate_hex = std.fmt.bytesToHex(candidate_digest, .lower);
        if (!std.mem.eql(u8, &candidate_hex, expected.candidate_sha256)) return false;
    }
    return true;
}

fn receiptMatchesProof(
    receipt: ui_payload.VerifiedChangeSetPayload,
    proof: *const aggregate_proof.AggregateProof,
) bool {
    const grammar_hash = zts.grammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostics_hash = zts.diagnosticCatalogHash();
    if (!std.mem.eql(u8, receipt.proof_schema_version, aggregate_proof.proof_schema_version) or
        receipt.proof_roots.len != proof.proof_roots.len)
    {
        return false;
    }
    for (receipt.proof_roots, proof.proof_roots) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return std.mem.eql(u8, receipt.transaction_id, &proof.proof_id) and
        std.mem.eql(u8, receipt.read_set_digest, &proof.read_set_digest) and
        std.mem.eql(u8, receipt.compiler_version, zts.version.string) and
        std.mem.eql(u8, receipt.profile_id, zts.GrammarCatalog.profile_id) and
        std.mem.eql(u8, receipt.grammar_hash, &grammar_hash) and
        std.mem.eql(u8, receipt.semantics_hash, &semantics_hash) and
        std.mem.eql(u8, receipt.diagnostic_catalog_hash, &diagnostics_hash) and
        receipt.system_proven == proof.system_proven;
}

pub fn replayLedgerOntoRef(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    onto_ref: []const u8,
) !ReplayResult {
    var bundle = try readLedgerFile(allocator, input_path);
    defer bundle.deinit(allocator);

    const root = try tools_common.workspaceRoot(allocator);
    defer allocator.free(root);

    const worktree_dir = try std.fmt.allocPrint(allocator, "/tmp/zts-ledger-replay-{d}", .{nowUnixMs()});
    defer allocator.free(worktree_dir);

    const add_argv = [_][]const u8{ "git", "worktree", "add", "--detach", worktree_dir, onto_ref };
    var add_result = try tools_common.runCommand(allocator, root, &add_argv);
    defer add_result.deinit(allocator);
    if (!add_result.ok) return error.WorktreeAddFailed;
    defer {
        const remove_argv = [_][]const u8{ "git", "worktree", "remove", "--force", worktree_dir };
        const maybe_remove = tools_common.runCommand(allocator, root, &remove_argv) catch null;
        if (maybe_remove) |result| {
            var owned = result;
            defer owned.deinit(allocator);
        }
    }

    return replayBundleInWorkspace(allocator, worktree_dir, &bundle);
}

pub fn runWithArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !void {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "help")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, argv[0], "export")) {
        var session_id: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--session")) {
                i += 1;
                if (i >= argv.len) return error.MissingArgument;
                session_id = argv[i];
                continue;
            }
            if (std.mem.eql(u8, argv[i], "--out")) {
                i += 1;
                if (i >= argv.len) return error.MissingArgument;
                out_path = argv[i];
                continue;
            }
            return error.InvalidArgument;
        }
        try exportSessionLedger(allocator, session_id orelse return error.MissingArgument, out_path orelse return error.MissingArgument);
        return;
    }

    if (std.mem.eql(u8, argv[0], "replay")) {
        var input_path: ?[]const u8 = null;
        var onto_ref: ?[]const u8 = null;
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--input")) {
                i += 1;
                if (i >= argv.len) return error.MissingArgument;
                input_path = argv[i];
                continue;
            }
            if (std.mem.eql(u8, argv[i], "--onto")) {
                i += 1;
                if (i >= argv.len) return error.MissingArgument;
                onto_ref = argv[i];
                continue;
            }
            return error.InvalidArgument;
        }
        var result = try replayLedgerOntoRef(allocator, input_path orelse return error.MissingArgument, onto_ref orelse return error.MissingArgument);
        defer result.deinit(allocator);
        printReplayResult(result);
        if (result.kind != .success) std.process.exit(1);
        return;
    }

    if (std.mem.eql(u8, argv[0], "stats")) {
        try runStats(allocator);
        return;
    }

    return error.UnknownCommand;
}

/// The three per-session signals `ledger stats` aggregates, read back from a
/// session's persisted `session_summary` row.
const SummaryStat = struct {
    reached_proof: bool,
    round_trips_to_first_green: u32,
    proven: u32,
    tracked: u32,
};

fn summaryU32(obj: std.json.ObjectMap, key: []const u8) u32 {
    if (obj.get(key)) |v| {
        if (v == .integer and v.integer >= 0) return @intCast(v.integer);
    }
    return 0;
}

/// Read the last `session_summary` row from a session's events.jsonl. Returns
/// null for a session that never wrote one (empty or in-progress). Best-effort:
/// an unreadable file or a malformed line is skipped, never fatal.
fn readLastSessionSummary(allocator: std.mem.Allocator, events_path: []const u8) !?SummaryStat {
    var reader = session_events.Reader.open(allocator, events_path) catch return null;
    defer reader.deinit();

    var found: ?SummaryStat = null;
    while (reader.next() catch return found) |record_json| {
        defer allocator.free(record_json);
        // Cheap pre-filter before the JSON parse.
        if (std.mem.indexOf(u8, record_json, "\"session_summary\"") == null) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, record_json, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root_obj = parsed.value.object;
        const k = root_obj.get("k") orelse continue;
        if (k != .string or !std.mem.eql(u8, k.string, "session_summary")) continue;
        const d = root_obj.get("d") orelse continue;
        if (d != .object) continue;
        const dobj = d.object;
        found = .{
            .reached_proof = if (dobj.get("reached_proof")) |v| (v == .bool and v.bool) else false,
            .round_trips_to_first_green = summaryU32(dobj, "round_trips_to_first_green"),
            .proven = summaryU32(dobj, "proven_properties"),
            .tracked = summaryU32(dobj, "tracked_properties"),
        };
    }
    return found;
}

fn medianU32(items: []u32) f64 {
    if (items.len == 0) return 0;
    std.mem.sort(u32, items, {}, std.sort.asc(u32));
    const mid = items.len / 2;
    if (items.len % 2 == 1) return @floatFromInt(items[mid]);
    return (@as(f64, @floatFromInt(items[mid - 1])) + @as(f64, @floatFromInt(items[mid]))) / 2.0;
}

fn medianF32(items: []f32) f64 {
    if (items.len == 0) return 0;
    std.mem.sort(f32, items, {}, std.sort.asc(f32));
    const mid = items.len / 2;
    if (items.len % 2 == 1) return items[mid];
    return (@as(f64, items[mid - 1]) + @as(f64, items[mid])) / 2.0;
}

/// Aggregate every session's `session_summary` for the current workspace into
/// the three STRATEGY.md metrics (expert success rate, median round-trips to
/// first green, median proven-path ratio) and print them. These were staked as
/// cross-session medians/rates but had no measurement home until now.
fn runStats(allocator: std.mem.Allocator) !void {
    const root = try session_paths.sessionRoot(allocator);
    defer allocator.free(root);
    const hash = try session_paths.cwdHashFull(allocator);
    const entries = try session_paths.listSessions(allocator, root, hash[0..]);
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    var green: std.ArrayListUnmanaged(u32) = .empty;
    defer green.deinit(allocator);
    var ratios: std.ArrayListUnmanaged(f32) = .empty;
    defer ratios.deinit(allocator);
    var total: usize = 0;
    var proof_reached: usize = 0;

    for (entries) |e| {
        const events_path = try std.fs.path.join(allocator, &.{ e.dir_path, "events.jsonl" });
        defer allocator.free(events_path);
        const stat = (try readLastSessionSummary(allocator, events_path)) orelse continue;
        total += 1;
        if (stat.reached_proof) {
            proof_reached += 1;
            try green.append(allocator, stat.round_trips_to_first_green);
            const ratio: f32 = if (stat.tracked == 0)
                0
            else
                @as(f32, @floatFromInt(stat.proven)) / @as(f32, @floatFromInt(stat.tracked));
            try ratios.append(allocator, ratio);
        }
    }

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    if (total == 0) {
        try w.writeAll("ledger stats: no sessions with a summary yet for this workspace.\n");
    } else {
        const success_pct = proof_reached * 100 / total;
        try w.print("ledger stats for this workspace ({d} session{s} with a summary)\n", .{ total, if (total == 1) "" else "s" });
        try w.print("  expert success rate:         {d}%  ({d}/{d} reached a verified proof)\n", .{ success_pct, proof_reached, total });
        if (proof_reached == 0) {
            try w.writeAll("  round-trips to first green:  n/a  (no proof sessions yet)\n");
            try w.writeAll("  proven-path ratio:           n/a  (no proof sessions yet)\n");
        } else {
            try w.print("  round-trips to first green:  median {d:.1}  (over {d} proof session{s})\n", .{ medianU32(green.items), proof_reached, if (proof_reached == 1) "" else "s" });
            try w.print("  proven-path ratio:           median {d:.3}  (over {d} proof session{s})\n", .{ medianF32(ratios.items), proof_reached, if (proof_reached == 1) "" else "s" });
        }
    }
    const bytes = buf.written();
    _ = std.c.write(std.c.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn writeMetaLine(writer: *std.Io.Writer, meta: ExportMeta) !void {
    try writer.writeAll("{\"kind\":\"meta\",\"schema_version\":");
    try writer.print("{d}", .{export_schema_version});
    try writer.writeAll(",\"workspace_hash\":");
    try json_writer.writeString(writer, meta.workspace_hash);
    try writer.writeAll(",\"session_id\":");
    try json_writer.writeString(writer, meta.session_id);
    try writer.writeAll(",\"parent_session_id\":");
    if (meta.parent_session_id) |parent| {
        try json_writer.writeString(writer, parent);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"exported_at_unix_ms\":");
    try writer.print("{d}", .{meta.exported_at_unix_ms});
    try writer.writeByte('}');
}

fn writeChangeSetLine(writer: *std.Io.Writer, receipt: LedgerChangeSet) !void {
    try writer.writeAll("{\"kind\":\"verified_change_set\",\"session_id\":");
    try json_writer.writeString(writer, receipt.session_id);
    try writer.writeAll(",\"summary\":");
    try json_writer.writeString(writer, receipt.summary);
    try writer.writeAll(",\"payload\":");
    try ui_payload.writeJson(writer, .{ .verified_change_set = receipt.payload });
    try writer.writeByte('}');
}

fn parseMetaLine(allocator: std.mem.Allocator, line: []const u8) !ExportMeta {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidLedgerFile;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidLedgerFile;
    const obj = parsed.value.object;
    if (!valueIsString(obj.get("kind"), "meta")) return error.InvalidLedgerFile;
    const version = obj.get("schema_version") orelse return error.InvalidLedgerFile;
    if (version != .integer or version.integer != export_schema_version) return error.InvalidLedgerFile;

    return .{
        .workspace_hash = try allocator.dupe(u8, getString(obj, "workspace_hash") orelse return error.InvalidLedgerFile),
        .session_id = try allocator.dupe(u8, getString(obj, "session_id") orelse return error.InvalidLedgerFile),
        .parent_session_id = if (try getOptionalString(obj, "parent_session_id")) |parent|
            try allocator.dupe(u8, parent)
        else
            null,
        .exported_at_unix_ms = getInteger(obj, "exported_at_unix_ms") orelse return error.InvalidLedgerFile,
    };
}

fn parseChangeSetLine(allocator: std.mem.Allocator, line: []const u8) !LedgerChangeSet {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidLedgerFile;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidLedgerFile;
    const obj = parsed.value.object;
    if (!valueIsString(obj.get("kind"), "verified_change_set")) return error.InvalidLedgerFile;

    const payload_val = obj.get("payload") orelse return error.InvalidLedgerFile;
    var payload_union = try ui_payload.parse(allocator, payload_val);
    errdefer payload_union.deinit(allocator);

    return switch (payload_union) {
        .verified_change_set => |payload| .{
            .session_id = try allocator.dupe(u8, getString(obj, "session_id") orelse return error.InvalidLedgerFile),
            .summary = try allocator.dupe(u8, getString(obj, "summary") orelse return error.InvalidLedgerFile),
            .payload = payload,
        },
        else => error.InvalidLedgerFile,
    };
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn valueIsString(value: ?std.json.Value, expected: []const u8) bool {
    const actual = value orelse return false;
    return actual == .string and std.mem.eql(u8, actual.string, expected);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidLedgerFile,
    };
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn nowUnixMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(@enumFromInt(@intFromEnum(std.posix.CLOCK.REALTIME)), &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn printReplayResult(result: ReplayResult) void {
    const line = std.fmt.allocPrint(std.heap.smp_allocator, "{s}: change set {d} {s} - {s}\n", .{
        @tagName(result.kind),
        result.change_set_index,
        result.file,
        result.detail,
    }) catch return;
    defer std.heap.smp_allocator.free(line);
    _ = std.c.write(std.c.STDERR_FILENO, line.ptr, line.len);
}

fn printHelp() void {
    const help =
        \\zttp ledger - export, replay, or aggregate verified change-set ledgers
        \\
        \\Usage:
        \\  zttp ledger export --session <id> --out <path>
        \\  zttp ledger replay --input <path> --onto <git-ref>
        \\  zttp ledger stats
        \\
        \\`stats` aggregates every session's summary for the current workspace
        \\into the staked metrics: expert success rate, median round-trips to
        \\first green proof, and median proven-path ratio.
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

const testing = std.testing;
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const EnvOverride = @import("test_support/env.zig").EnvOverride;

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "ledger");
}

test "collectSessionLedger exports empty ledger when events file is missing" {
    var tmp = try initTmp(testing.allocator);
    defer tmp.cleanup(testing.allocator);

    var env_override = try EnvOverride.set(testing.allocator, "ZTTP_SESSIONS_DIR", tmp.abs_path);
    defer env_override.restore(testing.allocator);

    const hash = try session_paths.cwdHashFull(testing.allocator);
    const session_dir = try std.fs.path.join(testing.allocator, &.{ tmp.abs_path, hash[0..], "sess-fresh" });
    defer testing.allocator.free(session_dir);

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), session_dir);

    const meta_path = try std.fs.path.join(testing.allocator, &.{ session_dir, "meta.json" });
    defer testing.allocator.free(meta_path);
    try session_events.writeMeta(testing.allocator, meta_path, .{
        .session_id = "sess-fresh",
        .workspace_realpath = tmp.abs_path,
        .created_at_unix_ms = 1,
        .parent_id = null,
        .policy_hash = "a" ** 64,
        .protocol_hash = "b" ** 64,
    });

    var bundle = try collectSessionLedger(testing.allocator, "sess-fresh");
    defer bundle.deinit(testing.allocator);

    try testing.expectEqualStrings("sess-fresh", bundle.meta.session_id);
    try testing.expectEqual(@as(usize, 0), bundle.change_sets.len);
}

fn testLedgerReceipt(
    allocator: std.mem.Allocator,
    before: ?[]const u8,
    after: []const u8,
    policy_hash: []const u8,
) !LedgerChangeSet {
    const before_digest = blk: {
        const digest = change_set.digestBaseline(before);
        break :blk std.fmt.bytesToHex(digest, .lower);
    };
    const after_digest = blk: {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(after, &digest, .{});
        break :blk std.fmt.bytesToHex(digest, .lower);
    };
    const baseline_state: []u8 = @constCast(if (before == null) "absent" else "present");
    var changes = [_]ui_payload.VerifiedChange{.{
        .file = @constCast("handler.ts"),
        .baseline_state = baseline_state,
        .baseline_sha256 = @constCast(&before_digest),
        .candidate_sha256 = @constCast(&after_digest),
        .before = if (before) |bytes| @constCast(bytes) else null,
        .after = @constCast(after),
        .unified_diff = @constCast(""),
    }};
    var roots = [_][]u8{@constCast("handler.ts")};
    var inputs = [_]ui_payload.VerifiedProofInput{.{
        .path = @constCast("handler.ts"),
        .state = baseline_state,
        .sha256 = @constCast(&before_digest),
    }};
    const grammar_hash = zts.grammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostics_hash = zts.diagnosticCatalogHash();
    const source = ui_payload.VerifiedChangeSetPayload{
        .proof_schema_version = @constCast(aggregate_proof.proof_schema_version),
        .transaction_id = @constCast("a" ** 64),
        .compiler_version = @constCast(zts.version.string),
        .profile_id = @constCast(zts.GrammarCatalog.profile_id),
        .policy_hash = @constCast(policy_hash),
        .grammar_hash = @constCast(&grammar_hash),
        .semantics_hash = @constCast(&semantics_hash),
        .diagnostic_catalog_hash = @constCast(&diagnostics_hash),
        .read_set_digest = @constCast("b" ** 64),
        .applied_at_unix_ms = 42,
        .system_proven = false,
        .proof_roots = &roots,
        .changes = &changes,
        .proof_inputs = &inputs,
    };
    var payload = try source.clone(allocator);
    errdefer payload.deinit(allocator);
    const session_id = try allocator.dupe(u8, "sess-1");
    errdefer allocator.free(session_id);
    const summary = try allocator.dupe(u8, "verified change set: handler.ts");
    errdefer allocator.free(summary);
    return .{
        .session_id = session_id,
        .summary = summary,
        .payload = payload,
    };
}

test "readLedgerFile round-trips exported verified change-set payload" {
    var tmp = try initTmp(testing.allocator);
    defer tmp.cleanup(testing.allocator);

    const path = try tmp.childPath(testing.allocator, "ledger.ndjson");
    defer testing.allocator.free(path);

    const receipt = try testLedgerReceipt(testing.allocator, null, "after", "a" ** 64);
    defer {
        var owned = receipt;
        owned.deinit(testing.allocator);
    }

    const meta = ExportMeta{
        .workspace_hash = try testing.allocator.dupe(u8, "h" ** 64),
        .session_id = try testing.allocator.dupe(u8, "sess-1"),
        .parent_session_id = null,
        .exported_at_unix_ms = 99,
    };
    defer {
        var owned = meta;
        owned.deinit(testing.allocator);
    }

    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try writeMetaLine(buf.writer(), meta);
    try buf.writer().writeByte('\n');
    try writeChangeSetLine(buf.writer(), receipt);
    try buf.writer().writeByte('\n');
    try zts.file_io.writeFile(testing.allocator, path, buf.written());

    var bundle = try readLedgerFile(testing.allocator, path);
    defer bundle.deinit(testing.allocator);

    try testing.expectEqualStrings("sess-1", bundle.meta.session_id);
    try testing.expectEqual(@as(usize, 1), bundle.change_sets.len);
    try testing.expectEqualStrings("handler.ts", bundle.change_sets[0].payload.changes[0].file);
    try testing.expectEqualStrings("a" ** 64, bundle.change_sets[0].payload.transaction_id);
}

test "replayBundleInWorkspace detects policy drift" {
    var tmp = try initTmp(testing.allocator);
    defer tmp.cleanup(testing.allocator);

    const file_path = try tmp.childPath(testing.allocator, "handler.ts");
    defer testing.allocator.free(file_path);
    try zts.file_io.writeFile(testing.allocator, file_path, "function handler(req: Request): Response { return Response.json({ ok: true }); }");

    const change_sets = try testing.allocator.alloc(LedgerChangeSet, 1);
    change_sets[0] = try testLedgerReceipt(
        testing.allocator,
        "function handler(req: Request): Response { return Response.json({ ok: true }); }",
        "function handler(req: Request): Response { return Response.json({ ok: false }); }",
        "b" ** 64,
    );
    var bundle = ExportBundle{
        .meta = .{
            .workspace_hash = try testing.allocator.dupe(u8, "h" ** 64),
            .session_id = try testing.allocator.dupe(u8, "sess-1"),
            .parent_session_id = null,
            .exported_at_unix_ms = 1,
        },
        .change_sets = change_sets,
    };
    defer bundle.deinit(testing.allocator);

    var result = try replayBundleInWorkspace(testing.allocator, tmp.abs_path, &bundle);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(ReplayKind.policy_drift, result.kind);
    try testing.expectEqualStrings("handler.ts", result.file);
}

test "medianU32 handles odd, even, and empty inputs" {
    var odd = [_]u32{ 3, 1, 2 };
    try testing.expectEqual(@as(f64, 2), medianU32(&odd));
    var even = [_]u32{ 4, 1, 3, 2 };
    try testing.expectEqual(@as(f64, 2.5), medianU32(&even));
    var empty = [_]u32{};
    try testing.expectEqual(@as(f64, 0), medianU32(&empty));
}

test "readLastSessionSummary returns the final summary row's staked signals" {
    var tmp = try initTmp(testing.allocator);
    defer tmp.cleanup(testing.allocator);
    const events_path = try tmp.childPath(testing.allocator, "events.jsonl");
    defer testing.allocator.free(events_path);

    // An early summary that did not reach proof...
    try session_events.appendEvent(testing.allocator, events_path, .{ .session_summary = .{
        .reached_proof = false,
    } });
    // ...superseded by a later one that did (e.g. after --resume). The last row
    // wins, so the aggregate reflects the session's final state.
    try session_events.appendEvent(testing.allocator, events_path, .{ .session_summary = .{
        .reached_proof = true,
        .round_trips_to_first_green = 5,
        .proven_properties = 12,
        .tracked_properties = 16,
    } });

    const stat = (try readLastSessionSummary(testing.allocator, events_path)).?;
    try testing.expect(stat.reached_proof);
    try testing.expectEqual(@as(u32, 5), stat.round_trips_to_first_green);
    try testing.expectEqual(@as(u32, 12), stat.proven);
    try testing.expectEqual(@as(u32, 16), stat.tracked);
}

test "readLastSessionSummary returns null when a session wrote no summary" {
    var tmp = try initTmp(testing.allocator);
    defer tmp.cleanup(testing.allocator);
    const events_path = try tmp.childPath(testing.allocator, "events.jsonl");
    defer testing.allocator.free(events_path);
    try session_events.appendEntryEvent(testing.allocator, events_path, 1, null, .{ .user_text = "hello" });
    try testing.expect((try readLastSessionSummary(testing.allocator, events_path)) == null);
}
