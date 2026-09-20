//! Rebuild an owned raw `Transcript` plus its latest provider projection from
//! a framed v4 event journal.
//!
//! Pure, wire-free helper used by resume flows to restore a previous session
//! into memory. Tool-use frames that share one logical entry ID are coalesced
//! back into the original multi-call assistant entry.
//!
//! Errors:
//!   - `error.SchemaVersionUnsupported` - the journal is not direct-cutover v4.
//!   - `error.CorruptEventsLog` - frame or JSON corruption, invalid stable IDs,
//!     a malformed checkpoint, or an unknown event kind.
//!   - Underlying file-IO errors propagate (`error.FileNotFound`, etc.).
//!
//! Empty file returns a fresh empty `Transcript`.

const std = @import("std");
const zts = @import("zts");

const transcript = @import("../transcript.zig");
const events = @import("events.zig");
const ui_payload = @import("../ui_payload.zig");

pub const Diagnostic = struct {
    line_number: usize = 0,
    message: []const u8 = "",
};

/// Streams the framed event journal at `events_path` and returns an owned
/// `Transcript`. Caller frees via `transcript.deinit(allocator)`.
pub fn reconstructTranscript(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    diag: ?*Diagnostic,
) !transcript.Transcript {
    var tr: transcript.Transcript = .{};
    errdefer tr.deinit(allocator);

    var reader = try events.Reader.open(allocator, events_path);
    defer reader.deinit();

    var record_number: usize = 0;
    while (true) {
        const record_json = reader.next() catch |err| switch (err) {
            error.SchemaVersionUnsupported => return error.SchemaVersionUnsupported,
            error.CorruptEventsLog,
            error.IncompleteEventFrame,
            error.EventTooLarge,
            => {
                if (diag) |d| d.* = .{
                    .line_number = record_number + 1,
                    .message = "invalid or malformed v4 event frame",
                };
                return error.CorruptEventsLog;
            },
            else => |other| return other,
        } orelse break;
        defer allocator.free(record_json);
        record_number += 1;
        appendFromLine(allocator, &tr, record_json) catch |err| switch (err) {
            error.SchemaVersionUnsupported => return error.SchemaVersionUnsupported,
            error.CorruptEventsLog, error.InvalidProjectionCut => {
                if (diag) |d| d.* = .{
                    .line_number = record_number,
                    .message = "invalid or malformed v4 event frame",
                };
                return error.CorruptEventsLog;
            },
            else => |e| return e,
        };
    }

    return tr;
}

fn appendFromLine(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    line: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return error.CorruptEventsLog;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.CorruptEventsLog;
    const obj = parsed.value.object;

    const version_val = obj.get("v") orelse return error.CorruptEventsLog;
    if (version_val != .integer) return error.CorruptEventsLog;
    const version_i = version_val.integer;
    if (version_i < 0) return error.CorruptEventsLog;
    const version: u32 = std.math.cast(u32, version_i) orelse return error.SchemaVersionUnsupported;
    if (version != events.schema_version) return error.SchemaVersionUnsupported;

    const kind_val = obj.get("k") orelse return error.CorruptEventsLog;
    if (kind_val != .string) return error.CorruptEventsLog;

    const payload = obj.get("d") orelse return error.CorruptEventsLog;

    const kind = kind_val.string;
    const entry_id = try parseOptionalEntryId(obj);
    const part_index = try parseOptionalPartIndex(obj);
    const transcript_kind = isTranscriptKind(kind);
    if (transcript_kind and entry_id == null) return error.CorruptEventsLog;
    if (!transcript_kind and (entry_id != null or part_index != null)) return error.CorruptEventsLog;

    if (transcript_kind) {
        const id = entry_id orelse return error.CorruptEventsLog;
        if (std.mem.eql(u8, kind, "tool_use") and id == tr.nextEntryId() - 1) {
            try appendToolUsePart(allocator, tr, payload, part_index orelse return error.CorruptEventsLog);
            return;
        }
        if (id != tr.nextEntryId()) return error.CorruptEventsLog;
        if (std.mem.eql(u8, kind, "tool_use")) {
            if (part_index != 0) return error.CorruptEventsLog;
        } else if (part_index != null) return error.CorruptEventsLog;
    }

    if (std.mem.eql(u8, kind, "user_text")) {
        try appendText(allocator, tr, payload, .user_text);
    } else if (std.mem.eql(u8, kind, "model_text")) {
        try appendText(allocator, tr, payload, .model_text);
    } else if (std.mem.eql(u8, kind, "proof_card")) {
        try appendDisplayMessage(allocator, tr, payload, .proof_card);
    } else if (std.mem.eql(u8, kind, "diagnostic_box")) {
        try appendDisplayMessage(allocator, tr, payload, .diagnostic_box);
    } else if (std.mem.eql(u8, kind, "verified_change_set")) {
        try appendDisplayMessage(allocator, tr, payload, .verified_change_set);
    } else if (std.mem.eql(u8, kind, "tool_use")) {
        try appendToolUse(allocator, tr, payload);
    } else if (std.mem.eql(u8, kind, "tool_use_batch")) {
        try appendToolUseBatch(allocator, tr, payload);
    } else if (std.mem.eql(u8, kind, "tool_result")) {
        try appendToolResult(allocator, tr, payload);
    } else if (std.mem.eql(u8, kind, "system_note")) {
        try appendText(allocator, tr, payload, .system_note);
    } else if (std.mem.eql(u8, kind, "autoloop_outcome")) {
        // Session-level summary; not rebuilt into the transcript.
        return;
    } else if (std.mem.eql(u8, kind, "turn_end")) {
        // Session-level turn marker; not rebuilt into the transcript.
        return;
    } else if (std.mem.eql(u8, kind, "session_summary")) {
        // Session-level metrics row; not rebuilt into the transcript.
        return;
    } else if (std.mem.eql(u8, kind, "compaction_checkpoint")) {
        try applyCheckpoint(allocator, tr, payload);
    } else {
        return error.CorruptEventsLog;
    }
}

fn isTranscriptKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "user_text") or
        std.mem.eql(u8, kind, "model_text") or
        std.mem.eql(u8, kind, "proof_card") or
        std.mem.eql(u8, kind, "diagnostic_box") or
        std.mem.eql(u8, kind, "verified_change_set") or
        std.mem.eql(u8, kind, "tool_use") or
        std.mem.eql(u8, kind, "tool_use_batch") or
        std.mem.eql(u8, kind, "tool_result") or
        std.mem.eql(u8, kind, "system_note");
}

fn parseOptionalEntryId(obj: std.json.ObjectMap) !?events.EntryId {
    const value = obj.get("entry_id") orelse return null;
    if (value != .integer or value.integer <= 0) return error.CorruptEventsLog;
    return std.math.cast(events.EntryId, value.integer) orelse error.CorruptEventsLog;
}

fn parseOptionalPartIndex(obj: std.json.ObjectMap) !?u32 {
    const value = obj.get("part_index") orelse return null;
    if (value != .integer or value.integer < 0) return error.CorruptEventsLog;
    return std.math.cast(u32, value.integer) orelse error.CorruptEventsLog;
}

fn applyCheckpoint(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
) !void {
    if (payload != .object) return error.CorruptEventsLog;
    const summary = payload.object.get("summary") orelse return error.CorruptEventsLog;
    const first_kept = payload.object.get("first_kept_entry_id") orelse return error.CorruptEventsLog;
    const reason = payload.object.get("reason") orelse return error.CorruptEventsLog;
    const read_files_value = payload.object.get("read_files") orelse return error.CorruptEventsLog;
    const modified_files_value = payload.object.get("modified_files") orelse return error.CorruptEventsLog;
    if (summary != .string or first_kept != .integer or first_kept.integer <= 0 or reason != .string) {
        return error.CorruptEventsLog;
    }
    _ = std.meta.stringToEnum(events.CompactionReason, reason.string) orelse return error.CorruptEventsLog;
    const cut = std.math.cast(events.EntryId, first_kept.integer) orelse return error.CorruptEventsLog;
    const read_files = try parseStringArray(allocator, read_files_value);
    defer allocator.free(read_files);
    const modified_files = try parseStringArray(allocator, modified_files_value);
    defer allocator.free(modified_files);
    try tr.replaceProjectionWithFiles(allocator, summary.string, cut, read_files, modified_files);
}

fn parseStringArray(allocator: std.mem.Allocator, value: std.json.Value) ![][]const u8 {
    if (value != .array) return error.CorruptEventsLog;
    const strings = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(strings);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.CorruptEventsLog;
        strings[index] = item.string;
    }
    return strings;
}

const TextKind = enum { user_text, model_text, system_note };

fn appendText(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
    kind: TextKind,
) !void {
    if (payload != .string) return error.CorruptEventsLog;
    const body = try allocator.dupe(u8, payload.string);
    errdefer allocator.free(body);

    const entry: transcript.OwnedEntry = switch (kind) {
        .user_text => .{ .user_text = body },
        .model_text => .{ .model_text = body },
        .system_note => .{ .system_note = body },
    };
    try tr.entries.append(allocator, entry);
}

const DisplayKind = enum { proof_card, diagnostic_box, verified_change_set };

fn appendDisplayMessage(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
    kind: DisplayKind,
) !void {
    var message = if (payload == .string) blk: {
        break :blk transcript.OwnedDisplayMessage{
            .llm_text = try allocator.dupe(u8, payload.string),
            .ui_payload = null,
        };
    } else try parseDisplayMessage(allocator, payload);
    errdefer {
        allocator.free(message.llm_text);
        if (message.ui_payload) |*p| p.deinit(allocator);
    }

    try tr.entries.append(allocator, switch (kind) {
        .proof_card => .{ .proof_card = message },
        .diagnostic_box => .{ .diagnostic_box = message },
        .verified_change_set => .{ .verified_change_set = message },
    });
}

fn appendToolUse(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
) !void {
    if (payload != .object) return error.CorruptEventsLog;
    const obj = payload.object;

    const id_val = obj.get("id") orelse return error.CorruptEventsLog;
    const name_val = obj.get("name") orelse return error.CorruptEventsLog;
    const args_val = obj.get("args_json") orelse return error.CorruptEventsLog;
    if (id_val != .string or name_val != .string or args_val != .string) {
        return error.CorruptEventsLog;
    }

    const calls = try allocator.alloc(transcript.OwnedToolCall, 1);
    errdefer allocator.free(calls);

    const id_copy = try allocator.dupe(u8, id_val.string);
    errdefer allocator.free(id_copy);
    const name_copy = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name_copy);
    const args_copy = try allocator.dupe(u8, args_val.string);
    errdefer allocator.free(args_copy);
    const reasoning_copy = if (obj.get("reasoning_content")) |value| blk: {
        if (value != .string) return error.CorruptEventsLog;
        break :blk try allocator.dupe(u8, value.string);
    } else null;
    errdefer if (reasoning_copy) |body| allocator.free(body);

    calls[0] = .{
        .id = id_copy,
        .name = name_copy,
        .args_json = args_copy,
        .reasoning_content = reasoning_copy,
    };
    try tr.entries.append(allocator, .{ .assistant_tool_use = calls });
}

fn appendToolUseBatch(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
) !void {
    if (payload != .array or payload.array.items.len == 0) return error.CorruptEventsLog;
    const calls = try allocator.alloc(transcript.OwnedToolCall, payload.array.items.len);
    errdefer allocator.free(calls);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |*call| call.deinit(allocator);
    }
    for (payload.array.items, 0..) |item, index| {
        if (item != .object) return error.CorruptEventsLog;
        const id_val = item.object.get("id") orelse return error.CorruptEventsLog;
        const name_val = item.object.get("name") orelse return error.CorruptEventsLog;
        const args_val = item.object.get("args_json") orelse return error.CorruptEventsLog;
        if (id_val != .string or name_val != .string or args_val != .string) {
            return error.CorruptEventsLog;
        }
        const id_copy = try allocator.dupe(u8, id_val.string);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, name_val.string);
        errdefer allocator.free(name_copy);
        const args_copy = try allocator.dupe(u8, args_val.string);
        errdefer allocator.free(args_copy);
        const reasoning_copy = if (item.object.get("reasoning_content")) |value| blk: {
            if (value != .string) return error.CorruptEventsLog;
            break :blk try allocator.dupe(u8, value.string);
        } else null;
        errdefer if (reasoning_copy) |body| allocator.free(body);
        calls[index] = .{
            .id = id_copy,
            .name = name_copy,
            .args_json = args_copy,
            .reasoning_content = reasoning_copy,
        };
        initialized += 1;
    }
    try tr.entries.append(allocator, .{ .assistant_tool_use = calls });
}

fn appendToolUsePart(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
    part_index: u32,
) !void {
    if (tr.entries.items.len == 0) return error.CorruptEventsLog;
    const last = &tr.entries.items[tr.entries.items.len - 1];
    if (last.* != .assistant_tool_use) return error.CorruptEventsLog;
    if (part_index != last.assistant_tool_use.len) return error.CorruptEventsLog;
    if (payload != .object) return error.CorruptEventsLog;
    const id_val = payload.object.get("id") orelse return error.CorruptEventsLog;
    const name_val = payload.object.get("name") orelse return error.CorruptEventsLog;
    const args_val = payload.object.get("args_json") orelse return error.CorruptEventsLog;
    if (id_val != .string or name_val != .string or args_val != .string) return error.CorruptEventsLog;

    const id_copy = try allocator.dupe(u8, id_val.string);
    errdefer allocator.free(id_copy);
    const name_copy = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name_copy);
    const args_copy = try allocator.dupe(u8, args_val.string);
    errdefer allocator.free(args_copy);
    const reasoning_copy = if (payload.object.get("reasoning_content")) |value| blk: {
        if (value != .string) return error.CorruptEventsLog;
        break :blk try allocator.dupe(u8, value.string);
    } else null;
    errdefer if (reasoning_copy) |body| allocator.free(body);

    const old_len = last.assistant_tool_use.len;
    const calls = try allocator.realloc(last.assistant_tool_use, old_len + 1);
    last.assistant_tool_use = calls;
    calls[old_len] = .{
        .id = id_copy,
        .name = name_copy,
        .args_json = args_copy,
        .reasoning_content = reasoning_copy,
    };
}

fn appendToolResult(
    allocator: std.mem.Allocator,
    tr: *transcript.Transcript,
    payload: std.json.Value,
) !void {
    if (payload != .object) return error.CorruptEventsLog;
    const obj = payload.object;

    const tu_id_val = obj.get("tool_use_id") orelse return error.CorruptEventsLog;
    const tool_name_val = obj.get("tool_name") orelse return error.CorruptEventsLog;
    const ok_val = obj.get("ok") orelse return error.CorruptEventsLog;
    const llm_text_val = obj.get("llm_text") orelse obj.get("body") orelse return error.CorruptEventsLog;
    if (tu_id_val != .string or tool_name_val != .string or ok_val != .bool or llm_text_val != .string) {
        return error.CorruptEventsLog;
    }

    const tu_id_copy = try allocator.dupe(u8, tu_id_val.string);
    errdefer allocator.free(tu_id_copy);
    const tool_name_copy = try allocator.dupe(u8, tool_name_val.string);
    errdefer allocator.free(tool_name_copy);
    const llm_text_copy = try allocator.dupe(u8, llm_text_val.string);
    errdefer allocator.free(llm_text_copy);
    var payload_copy = if (obj.get("ui_payload")) |payload_val|
        try ui_payload.parse(allocator, payload_val)
    else
        null;
    errdefer if (payload_copy) |*copied_payload| copied_payload.deinit(allocator);

    try tr.entries.append(allocator, .{ .tool_result = .{
        .tool_use_id = tu_id_copy,
        .tool_name = tool_name_copy,
        .ok = ok_val.bool,
        .llm_text = llm_text_copy,
        .ui_payload = payload_copy,
    } });
}

fn parseDisplayMessage(
    allocator: std.mem.Allocator,
    payload: std.json.Value,
) !transcript.OwnedDisplayMessage {
    if (payload != .object) return error.CorruptEventsLog;
    const obj = payload.object;
    const llm_text_val = obj.get("llm_text") orelse obj.get("body") orelse return error.CorruptEventsLog;
    if (llm_text_val != .string) return error.CorruptEventsLog;
    const llm_text = try allocator.dupe(u8, llm_text_val.string);
    errdefer allocator.free(llm_text);
    return .{
        .llm_text = llm_text,
        .ui_payload = if (obj.get("ui_payload")) |payload_val|
            try ui_payload.parse(allocator, payload_val)
        else
            null,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "reconstructor");
}

const JournalEventTag = std.meta.Tag(events.EventRecord);

fn populateAllKindsJournal(allocator: std.mem.Allocator, path: []const u8) !void {
    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "user" });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .model_text = "model" });
    try events.appendEntryEvent(allocator, path, 3, 0, .{ .tool_use = .{
        .id = "toolu_legacy_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"one.ts\"}",
        .reasoning_content = "first reasoning",
    } });
    try events.appendEntryEvent(allocator, path, 3, 1, .{ .tool_use = .{
        .id = "toolu_legacy_2",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"two.ts\"}",
    } });
    const batch = [_]events.ToolUse{
        .{ .id = "toolu_batch", .name = "zts_expert_meta", .args_json = "{}" },
    };
    try events.appendEntryEvent(allocator, path, 4, null, .{ .tool_use_batch = &batch });
    try events.appendEntryEvent(allocator, path, 5, null, .{ .tool_result = .{
        .tool_use_id = "toolu_batch",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "result",
        .ui_payload = .{ .plain_text = @constCast("result display") },
    } });
    try events.appendEntryEvent(allocator, path, 6, null, .{ .proof_card = .{
        .llm_text = "proof",
        .ui_payload = .{ .plain_text = @constCast("proof display") },
    } });
    try events.appendEntryEvent(allocator, path, 7, null, .{ .diagnostic_box = .{
        .llm_text = "diagnostic",
    } });
    try events.appendEntryEvent(allocator, path, 8, null, .{ .verified_change_set = .{
        .llm_text = "verified",
    } });
    try events.appendEntryEvent(allocator, path, 9, null, .{ .system_note = "system" });
    try events.appendEvent(allocator, path, .{ .autoloop_outcome = .{
        .verdict = .achieved,
        .goals_met = &.{"retry_safe"},
        .iterations = 1,
    } });
    try events.appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    try events.appendEvent(allocator, path, .{ .session_summary = .{
        .turn_count = 1,
        .total_roundtrips = 2,
        .final_outcome = .approved,
    } });
    try events.appendEvent(allocator, path, .{ .compaction_checkpoint = .{
        .summary = "summary",
        .first_kept_entry_id = 9,
        .reason = .manual,
        .read_files = &.{"read.ts"},
        .modified_files = &.{"modified.ts"},
    } });
}

fn writeRawSchema4Frame(
    allocator: std.mem.Allocator,
    path: []const u8,
    payload: []const u8,
) !void {
    const frame = try rawSchema4Frame(allocator, payload);
    defer allocator.free(frame);
    try zts.file_io.writeFile(allocator, path, frame);
}

fn appendRawSchema4Frame(
    allocator: std.mem.Allocator,
    path: []const u8,
    payload: []const u8,
) !void {
    const frame = try rawSchema4Frame(allocator, payload);
    defer allocator.free(frame);
    const fd = try zts.file_io.openAppend(allocator, path);
    defer std.Io.Threaded.closeFd(fd);
    var written: usize = 0;
    while (written < frame.len) {
        const result = std.c.write(fd, frame[written..].ptr, frame.len - written);
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        if (result <= 0) return error.TestWriteFailed;
        written += @intCast(result);
    }
}

fn rawSchema4Frame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const frame_magic = "ZTE4";
    const footer_magic = "4ETZ";
    const header_len = frame_magic.len + @sizeOf(u64) + 32;
    const footer_len = @sizeOf(u64) + footer_magic.len;
    const frame = try allocator.alloc(u8, header_len + payload.len + footer_len + 1);
    errdefer allocator.free(frame);
    @memcpy(frame[0..frame_magic.len], frame_magic);
    std.mem.writeInt(u64, frame[frame_magic.len .. frame_magic.len + @sizeOf(u64)], @intCast(payload.len), .big);
    std.crypto.hash.sha2.Sha256.hash(payload, frame[frame_magic.len + @sizeOf(u64) .. header_len], .{});
    @memcpy(frame[header_len .. header_len + payload.len], payload);
    const footer_start = header_len + payload.len;
    std.mem.writeInt(u64, frame[footer_start..][0..@sizeOf(u64)], @intCast(payload.len), .big);
    @memcpy(frame[footer_start + @sizeOf(u64) .. footer_start + footer_len], footer_magic);
    frame[frame.len - 1] = '\n';
    return frame;
}

test "reconstructTranscript applies all event kinds with stable identities" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "all-kinds.events");
    defer allocator.free(path);
    try populateAllKindsJournal(allocator, path);

    var seen = std.EnumSet(JournalEventTag).initEmpty();
    var frame_count: usize = 0;
    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    while (try reader.next()) |payload| {
        defer allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const kind_value = parsed.value.object.get("k") orelse return error.TestExpectedEventKind;
        const tag = std.meta.stringToEnum(JournalEventTag, kind_value.string) orelse
            return error.TestExpectedKnownEventKind;
        seen.insert(tag);
        frame_count += 1;
    }
    try testing.expectEqual(@as(usize, 14), frame_count);
    for (std.enums.values(JournalEventTag)) |tag| try testing.expect(seen.contains(tag));

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    const expected_tags = [_]transcript.Tag{
        .user_text,
        .model_text,
        .assistant_tool_use,
        .assistant_tool_use,
        .tool_result,
        .proof_card,
        .diagnostic_box,
        .verified_change_set,
        .system_note,
    };
    try testing.expectEqual(expected_tags.len, tr.len());
    for (expected_tags, 0..) |expected, index| {
        try testing.expectEqual(expected, std.meta.activeTag(tr.at(index).*));
        try testing.expectEqual(@as(events.EntryId, @intCast(index + 1)), tr.entryIdAt(index));
    }
    try testing.expectEqualStrings("user", tr.at(0).user_text);
    try testing.expectEqualStrings("model", tr.at(1).model_text);
    try testing.expectEqual(@as(usize, 2), tr.at(2).assistant_tool_use.len);
    try testing.expectEqualStrings("toolu_legacy_1", tr.at(2).assistant_tool_use[0].id);
    try testing.expectEqualStrings("workspace_read_file", tr.at(2).assistant_tool_use[0].name);
    try testing.expectEqualStrings("{\"path\":\"one.ts\"}", tr.at(2).assistant_tool_use[0].args_json);
    try testing.expectEqualStrings("first reasoning", tr.at(2).assistant_tool_use[0].reasoning_content.?);
    try testing.expectEqualStrings("toolu_legacy_2", tr.at(2).assistant_tool_use[1].id);
    try testing.expectEqual(@as(usize, 1), tr.at(3).assistant_tool_use.len);
    try testing.expectEqualStrings("toolu_batch", tr.at(3).assistant_tool_use[0].id);
    try testing.expectEqualStrings("zts_expert_meta", tr.at(3).assistant_tool_use[0].name);
    try testing.expectEqualStrings("{}", tr.at(3).assistant_tool_use[0].args_json);
    try testing.expectEqualStrings("toolu_batch", tr.at(4).tool_result.tool_use_id);
    try testing.expectEqualStrings("zts_expert_meta", tr.at(4).tool_result.tool_name);
    try testing.expect(tr.at(4).tool_result.ok);
    try testing.expectEqualStrings("result", tr.at(4).tool_result.llm_text);
    switch (tr.at(4).tool_result.ui_payload.?) {
        .plain_text => |text| try testing.expectEqualStrings("result display", text),
        else => return error.TestExpectedPlainTextPayload,
    }
    switch (tr.at(5).proof_card.ui_payload.?) {
        .plain_text => |text| try testing.expectEqualStrings("proof display", text),
        else => return error.TestExpectedPlainTextPayload,
    }
    try testing.expectEqualStrings("proof", tr.at(5).proof_card.llm_text);
    try testing.expectEqualStrings("diagnostic", tr.at(6).diagnostic_box.llm_text);
    try testing.expectEqualStrings("verified", tr.at(7).verified_change_set.llm_text);
    try testing.expectEqualStrings("system", tr.at(8).system_note);
    try testing.expectEqualStrings("summary", tr.projection.?.summary);
    try testing.expectEqual(@as(events.EntryId, 9), tr.projection.?.first_kept_entry_id);
    try testing.expectEqualStrings("read.ts", tr.projection.?.read_files[0]);
    try testing.expectEqualStrings("modified.ts", tr.projection.?.modified_files[0]);
}

test "reconstructTranscript preserves legacy display and body payloads" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const display_path = try tmp.childPath(allocator, "display-string.events");
    defer allocator.free(display_path);
    try writeRawSchema4Frame(
        allocator,
        display_path,
        "{\"v\":4,\"entry_id\":1,\"k\":\"proof_card\",\"d\":\"legacy proof\"}",
    );
    var display = try reconstructTranscript(allocator, display_path, null);
    defer display.deinit(allocator);
    try testing.expectEqualStrings("legacy proof", display.at(0).proof_card.llm_text);
    try testing.expect(display.at(0).proof_card.ui_payload == null);

    const result_path = try tmp.childPath(allocator, "result-body.events");
    defer allocator.free(result_path);
    try writeRawSchema4Frame(
        allocator,
        result_path,
        "{\"v\":4,\"entry_id\":1,\"k\":\"tool_result\",\"d\":{\"tool_use_id\":\"toolu_1\",\"tool_name\":\"tool\",\"ok\":true,\"body\":\"legacy result\",\"ui_payload\":{\"kind\":\"plain_text\",\"text\":\"display\"}}}",
    );
    var result = try reconstructTranscript(allocator, result_path, null);
    defer result.deinit(allocator);
    try testing.expectEqualStrings("legacy result", result.at(0).tool_result.llm_text);
    switch (result.at(0).tool_result.ui_payload.?) {
        .plain_text => |text| try testing.expectEqualStrings("display", text),
        else => return error.TestExpectedPlainTextPayload,
    }

    const object_path = try tmp.childPath(allocator, "display-body.events");
    defer allocator.free(object_path);
    try writeRawSchema4Frame(
        allocator,
        object_path,
        "{\"v\":4,\"entry_id\":1,\"k\":\"verified_change_set\",\"d\":{\"body\":\"legacy verified\",\"ui_payload\":{\"kind\":\"plain_text\",\"text\":\"verified display\"}}}",
    );
    var object = try reconstructTranscript(allocator, object_path, null);
    defer object.deinit(allocator);
    try testing.expectEqualStrings("legacy verified", object.at(0).verified_change_set.llm_text);
    switch (object.at(0).verified_change_set.ui_payload.?) {
        .plain_text => |text| try testing.expectEqualStrings("verified display", text),
        else => return error.TestExpectedPlainTextPayload,
    }
}

test "reader recovery and reconstruction preserve additive journal fields" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "additive-fields.events");
    defer allocator.free(path);
    const entry_payload =
        "{\"v\":4,\"entry_id\":1,\"future_envelope\":{\"revision\":5},\"k\":\"tool_result\",\"d\":{\"tool_use_id\":\"toolu_1\",\"tool_name\":\"tool\",\"ok\":true,\"body\":\"result\",\"future_payload\":[1,2],\"ui_payload\":{\"kind\":\"plain_text\",\"text\":\"display\",\"future_ui\":true}}}";
    const checkpoint_payload =
        "{\"v\":4,\"future_envelope\":\"kept\",\"k\":\"compaction_checkpoint\",\"d\":{\"summary\":\"summary\",\"first_kept_entry_id\":1,\"reason\":\"manual\",\"read_files\":[\"read.ts\"],\"modified_files\":[\"modified.ts\"],\"future_payload\":{\"tokens\":3}}}";
    try writeRawSchema4Frame(allocator, path, entry_payload);
    try appendRawSchema4Frame(allocator, path, checkpoint_payload);

    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    const first = (try reader.next()) orelse return error.TestExpectedEventFrame;
    defer allocator.free(first);
    const second = (try reader.next()) orelse return error.TestExpectedEventFrame;
    defer allocator.free(second);
    try testing.expect((try reader.next()) == null);
    try testing.expectEqualStrings(entry_payload, first);
    try testing.expectEqualStrings(checkpoint_payload, second);

    try events.recoverIncompleteTail(allocator, path);
    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), tr.len());
    try testing.expectEqualStrings("toolu_1", tr.at(0).tool_result.tool_use_id);
    try testing.expectEqualStrings("result", tr.at(0).tool_result.llm_text);
    switch (tr.at(0).tool_result.ui_payload.?) {
        .plain_text => |text| try testing.expectEqualStrings("display", text),
        else => return error.TestExpectedPlainTextPayload,
    }
    try testing.expectEqualStrings("summary", tr.projection.?.summary);
    try testing.expectEqual(@as(events.EntryId, 1), tr.projection.?.first_kept_entry_id);
    try testing.expectEqualStrings("read.ts", tr.projection.?.read_files[0]);
    try testing.expectEqualStrings("modified.ts", tr.projection.?.modified_files[0]);
}

test "checkpoint recovery accepts omitted projection fields but reconstruction rejects them" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "checkpoint-omitted-fields.events");
    defer allocator.free(path);
    try writeRawSchema4Frame(
        allocator,
        path,
        "{\"v\":4,\"k\":\"compaction_checkpoint\",\"d\":{\"first_kept_entry_id\":1}}",
    );

    try events.recoverIncompleteTail(allocator, path);
    try testing.expectError(error.CorruptEventsLog, reconstructTranscript(allocator, path, null));
}

test "checkpoint recovery rejects absent or malformed cut identity" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const absent_path = try tmp.childPath(allocator, "checkpoint-absent-cut.events");
    defer allocator.free(absent_path);
    try writeRawSchema4Frame(
        allocator,
        absent_path,
        "{\"v\":4,\"k\":\"compaction_checkpoint\",\"d\":{}}",
    );
    try testing.expectError(
        error.CorruptEventsLog,
        events.recoverIncompleteTail(allocator, absent_path),
    );

    const malformed_path = try tmp.childPath(allocator, "checkpoint-malformed-cut.events");
    defer allocator.free(malformed_path);
    try writeRawSchema4Frame(
        allocator,
        malformed_path,
        "{\"v\":4,\"k\":\"compaction_checkpoint\",\"d\":{\"first_kept_entry_id\":\"1\"}}",
    );
    try testing.expectError(
        error.CorruptEventsLog,
        events.recoverIncompleteTail(allocator, malformed_path),
    );
}

test "reader exposes a framed skipped identity while recovery and reconstruction reject it" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "raw-skipped-entry.events");
    defer allocator.free(path);
    const payload = "{\"v\":4,\"entry_id\":2,\"k\":\"user_text\",\"d\":\"skipped\"}";
    try writeRawSchema4Frame(allocator, path, payload);

    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    const framed = (try reader.next()) orelse return error.TestExpectedEventFrame;
    defer allocator.free(framed);
    try testing.expectEqualStrings(payload, framed);
    try testing.expect((try reader.next()) == null);

    try testing.expectError(
        error.CorruptEventsLog,
        events.recoverIncompleteTail(allocator, path),
    );
    try testing.expectError(error.CorruptEventsLog, reconstructTranscript(allocator, path, null));
}

test "reconstruction skips opaque session payloads that recovery rejects" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "opaque-session-payloads.events");
    defer allocator.free(path);
    try writeRawSchema4Frame(
        allocator,
        path,
        "{\"v\":4,\"k\":\"autoloop_outcome\",\"d\":\"opaque\"}",
    );
    try appendRawSchema4Frame(
        allocator,
        path,
        "{\"v\":4,\"k\":\"turn_end\",\"d\":false}",
    );
    try appendRawSchema4Frame(
        allocator,
        path,
        "{\"v\":4,\"k\":\"session_summary\",\"d\":7}",
    );

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), tr.len());
    try testing.expect(tr.projection == null);
    try testing.expectError(
        error.CorruptEventsLog,
        events.recoverIncompleteTail(allocator, path),
    );
}

test "framed version mismatch preserves reconstruction and recovery errors" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "future-version.events");
    defer allocator.free(path);
    const payload = "{\"v\":5,\"entry_id\":1,\"k\":\"user_text\",\"d\":\"future\"}";
    try writeRawSchema4Frame(allocator, path, payload);

    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    const framed = (try reader.next()) orelse return error.TestExpectedEventFrame;
    defer allocator.free(framed);
    try testing.expectEqualStrings(payload, framed);
    try testing.expect((try reader.next()) == null);
    try testing.expectError(
        error.SchemaVersionUnsupported,
        reconstructTranscript(allocator, path, null),
    );
    try testing.expectError(
        error.CorruptEventsLog,
        events.recoverIncompleteTail(allocator, path),
    );
}

test "writer accepts tool use without part index but reconstruction rejects it" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "tool-use-without-part.events");
    defer allocator.free(path);
    try events.appendEntryEvent(allocator, path, 1, null, .{ .tool_use = .{
        .id = "toolu_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
    } });
    try testing.expectError(error.CorruptEventsLog, reconstructTranscript(allocator, path, null));
}

test "reconstructTranscript preserves parse allocation error compatibility" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "parse-oom.events");
    defer allocator.free(path);
    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "user" });

    // Reader.open allocates the path first and Reader.next allocates the frame
    // payload second. The next allocation enters std.json parsing, whose
    // historical public error is CorruptEventsLog rather than OutOfMemory.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    try testing.expectError(
        error.CorruptEventsLog,
        reconstructTranscript(failing.allocator(), path, null),
    );
}

test "reconstructTranscript cleans every allocation failure" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "allocation-sweep.events");
    defer allocator.free(path);
    try populateAllKindsJournal(allocator, path);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        if (reconstructTranscript(failing.allocator(), path, null)) |value| {
            var tr = value;
            defer tr.deinit(failing.allocator());
            try testing.expectEqual(@as(usize, 9), tr.len());
            try testing.expectEqualStrings("result", tr.at(4).tool_result.llm_text);
            try testing.expectEqualStrings("summary", tr.projection.?.summary);
            break;
        } else |err| {
            try testing.expect(failing.has_induced_failure);
            switch (err) {
                // JSON parse allocation failure has historically been translated
                // to corruption. All later owned projection allocations preserve
                // OutOfMemory. Both paths must clean their partial ownership.
                error.CorruptEventsLog, error.OutOfMemory => {},
                else => return err,
            }
        }
    }
    try testing.expect(fail_index > 0);
}

test "reconstructTranscript returns an empty Transcript for an empty file" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try zts.file_io.writeFile(allocator, path, "");

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), tr.len());
}

test "reconstructTranscript propagates FileNotFound for a missing log" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "does-not-exist.jsonl");
    defer allocator.free(path);

    const result = reconstructTranscript(allocator, path, null);
    try testing.expectError(error.FileNotFound, result);
}

test "reconstructTranscript round-trips user_text, model_text, tool_use, tool_result, proof_card" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "hi" });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .model_text = "hello back" });
    const tool_batch = [_]events.ToolUse{
        .{
            .id = "toolu_1",
            .name = "zts_expert_meta",
            .args_json = "{\"verbose\":true}",
            .reasoning_content = "opaque continuation",
        },
        .{ .id = "toolu_2", .name = "workspace_read_file", .args_json = "{\"path\":\"handler.ts\"}" },
    };
    try events.appendEntryEvent(allocator, path, 3, null, .{ .tool_use_batch = &tool_batch });
    try events.appendEntryEvent(allocator, path, 4, null, .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "{\"ok\":true}",
    } });
    try events.appendEntryEvent(allocator, path, 5, null, .{ .proof_card = .{ .llm_text = "contract ok" } });

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);

    try testing.expectEqual(@as(usize, 5), tr.len());

    switch (tr.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("hi", body),
        else => return error.TestFailed,
    }
    switch (tr.at(1).*) {
        .model_text => |body| try testing.expectEqualStrings("hello back", body),
        else => return error.TestFailed,
    }
    switch (tr.at(2).*) {
        .assistant_tool_use => |calls| {
            try testing.expectEqual(@as(usize, 2), calls.len);
            try testing.expectEqualStrings("toolu_1", calls[0].id);
            try testing.expectEqualStrings("zts_expert_meta", calls[0].name);
            try testing.expectEqualStrings("{\"verbose\":true}", calls[0].args_json);
            try testing.expectEqualStrings("opaque continuation", calls[0].reasoning_content.?);
            try testing.expectEqualStrings("toolu_2", calls[1].id);
            try testing.expectEqualStrings("workspace_read_file", calls[1].name);
        },
        else => return error.TestFailed,
    }
    switch (tr.at(3).*) {
        .tool_result => |r| {
            try testing.expectEqualStrings("toolu_1", r.tool_use_id);
            try testing.expectEqualStrings("zts_expert_meta", r.tool_name);
            try testing.expect(r.ok);
            try testing.expectEqualStrings("{\"ok\":true}", r.llm_text);
        },
        else => return error.TestFailed,
    }
    switch (tr.at(4).*) {
        .proof_card => |body| try testing.expectEqualStrings("contract ok", body.llm_text),
        else => return error.TestFailed,
    }
}

test "reconstructTranscript rejects a v2 journal after the direct cutover" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try zts.file_io.writeFile(allocator, path, "{\"v\":2,\"k\":\"user_text\",\"d\":\"legacy\"}\n");
    try testing.expectError(error.SchemaVersionUnsupported, reconstructTranscript(allocator, path, null));
}

test "reconstructTranscript skips turn_end records" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "before" });
    try events.appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_roundtrips } });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .model_text = "after" });

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), tr.len());
    switch (tr.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("before", body),
        else => return error.TestFailed,
    }
    switch (tr.at(1).*) {
        .model_text => |body| try testing.expectEqualStrings("after", body),
        else => return error.TestFailed,
    }
}

test "reconstructTranscript restores the latest projection checkpoint" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "old" });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .model_text = "old answer" });
    try events.appendEntryEvent(allocator, path, 3, null, .{ .user_text = "new" });
    try events.appendEvent(allocator, path, .{ .compaction_checkpoint = .{
        .summary = "summary",
        .first_kept_entry_id = 3,
        .reason = .manual,
    } });

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), tr.len());
    try testing.expectEqualStrings("summary", tr.projection.?.summary);
    try testing.expectEqual(@as(events.EntryId, 3), tr.projection.?.first_kept_entry_id);
}

test "reconstructTranscript accepts a checkpoint at the next entry boundary" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "old" });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .model_text = "old answer" });
    try events.appendEvent(allocator, path, .{ .compaction_checkpoint = .{
        .summary = "summary through the completed tail",
        .first_kept_entry_id = 3,
        .reason = .threshold,
    } });
    try events.appendEntryEvent(allocator, path, 3, null, .{ .model_text = "continued" });

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), tr.len());
    try testing.expectEqual(@as(events.EntryId, 3), tr.projection.?.first_kept_entry_id);
    try testing.expectEqual(@as(usize, 2), try tr.activeStartIndex());
    try testing.expectEqualStrings("continued", tr.at(2).model_text);
}

test "journal writer rejects a checkpoint with a missing cut identity" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "only" });
    try testing.expectError(
        error.CorruptEventsLog,
        events.appendEvent(allocator, path, .{ .compaction_checkpoint = .{
            .summary = "invalid",
            .first_kept_entry_id = 99,
            .reason = .manual,
        } }),
    );
}

test "reconstructTranscript streams a journal larger than the former 64 MiB ceiling" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const body = try allocator.alloc(u8, 33 * 1024 * 1024);
    defer allocator.free(body);
    @memset(body, 'a');
    try events.appendEntryEvent(allocator, path, 1, null, .{ .system_note = body });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .system_note = body });

    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), tr.len());
    try testing.expectEqual(body.len, tr.at(0).system_note.len);
    try testing.expectEqual(body.len, tr.at(1).system_note.len);
}

test "reconstructTranscript is read-only and recovery requires the journal lock" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "complete" });
    const fd = try zts.file_io.openAppend(allocator, path);
    defer std.Io.Threaded.closeFd(fd);
    _ = std.c.write(fd, "ZTE3partial".ptr, "ZTE3partial".len);

    try testing.expectError(error.CorruptEventsLog, reconstructTranscript(allocator, path, null));
    try events.recoverIncompleteTail(allocator, path);
    var tr = try reconstructTranscript(allocator, path, null);
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), tr.len());
}

test "reconstructTranscript reports the line number of the first corrupt record" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try events.appendEntryEvent(allocator, path, 1, null, .{ .user_text = "one" });
    try events.appendEntryEvent(allocator, path, 2, null, .{ .user_text = "two" });
    const raw = try zts.file_io.readFile(allocator, path, 1024 * 1024);
    defer allocator.free(raw);
    const corrupt_at = std.mem.indexOf(u8, raw, "two") orelse return error.TestExpectedPayload;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0);
    defer std.Io.Threaded.closeFd(fd);
    const replacement = "x";
    _ = std.c.pwrite(fd, replacement.ptr, replacement.len, @intCast(corrupt_at));

    var diag: Diagnostic = .{};
    const result = reconstructTranscript(allocator, path, &diag);
    try testing.expectError(error.CorruptEventsLog, result);
    try testing.expectEqual(@as(usize, 2), diag.line_number);
}
