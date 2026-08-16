//! Pure, wire-free persistence helper that maps `transcript.OwnedEntry`
//! values to `session/events.EventRecord` values and appends them to an
//! `events.jsonl` file.
//!
//! Two small, orthogonal helpers:
//!
//!   - `entryToEvent` is a pure mapping from one transcript variant to its
//!     matching event variant. It borrows slices from the input entry and
//!     does no allocation. `appendEntry` handles `.assistant_tool_use`
//!     separately so an entire multi-call assistant entry occupies one
//!     checksummed frame.
//!
//!   - `appendEntry` writes the entry to disk honoring `AppendOptions`:
//!       * `no_persist_tool_output = true` persists a structural redacted
//!         `.tool_result`, so resumed provider history never has a dangling
//!         tool call. All other variants still persist.
//!       * Otherwise tool results are preserved exactly. Provider-context
//!         bounds belong to each tool's typed projection, not the raw journal.
//!
//! This unit does not touch the loop, agent, transcript, or REPL; it is
//! a building block for later wiring.

const std = @import("std");
const transcript = @import("../transcript.zig");
const events = @import("events.zig");

pub const AppendOptions = struct {
    no_persist_tool_output: bool = false,
};

pub const redacted_tool_output = "[tool output not persisted]";

/// Pure mapping from a transcript variant to the corresponding event
/// variant. Borrows slices from `entry`; do not persist the returned
/// record past `entry`'s lifetime unless `events.appendEvent` has already
/// been called with it.
///
/// NOTE: `.assistant_tool_use` is handled separately by `appendEntry` so a
/// partial write can never durably commit only part of a logical call batch.
fn entryToEvent(entry: *const transcript.OwnedEntry) events.EventRecord {
    return switch (entry.*) {
        .user_text => |body| .{ .user_text = body },
        .model_text => |body| .{ .model_text = body },
        .proof_card => |message| .{ .proof_card = .{
            .llm_text = message.llm_text,
            .ui_payload = message.ui_payload,
        } },
        .diagnostic_box => |message| .{ .diagnostic_box = .{
            .llm_text = message.llm_text,
            .ui_payload = message.ui_payload,
        } },
        .verified_change_set => |message| .{ .verified_change_set = .{
            .llm_text = message.llm_text,
            .ui_payload = message.ui_payload,
        } },
        .system_note => |body| .{ .system_note = body },
        .assistant_tool_use => |calls| .{ .tool_use = .{
            .id = calls[0].id,
            .name = calls[0].name,
            .args_json = calls[0].args_json,
            .reasoning_content = calls[0].reasoning_content,
        } },
        .tool_result => |tr| .{ .tool_result = .{
            .tool_use_id = tr.tool_use_id,
            .tool_name = tr.tool_name,
            .ok = tr.ok,
            .llm_text = tr.llm_text,
            .ui_payload = tr.ui_payload,
        } },
    };
}

/// Append one or more `events.jsonl` lines for `entry`, honoring `opts`.
///
/// `.assistant_tool_use` with N calls emits one atomic `tool_use_batch` frame.
/// All other variants emit exactly one frame.
///
/// `.tool_result` uses a structural redacted placeholder when
/// `opts.no_persist_tool_output` is true. Otherwise the raw result is written
/// exactly.
pub fn appendEntry(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    entry_id: events.EntryId,
    entry: *const transcript.OwnedEntry,
    opts: AppendOptions,
) !void {
    var writer = try events.JournalWriter.open(allocator, events_path);
    defer writer.deinit();
    return appendEntryToWriter(allocator, &writer, entry_id, entry, opts);
}

pub fn appendEntryToWriter(
    allocator: std.mem.Allocator,
    writer: *events.JournalWriter,
    entry_id: events.EntryId,
    entry: *const transcript.OwnedEntry,
    opts: AppendOptions,
) !void {
    switch (entry.*) {
        .tool_result => |tr| {
            try writer.appendEntryEvent(allocator, entry_id, null, .{ .tool_result = .{
                .tool_use_id = tr.tool_use_id,
                .tool_name = tr.tool_name,
                .ok = tr.ok,
                .llm_text = if (opts.no_persist_tool_output) redacted_tool_output else tr.llm_text,
                .ui_payload = if (opts.no_persist_tool_output) null else tr.ui_payload,
            } });
        },
        .assistant_tool_use => |calls| {
            if (calls.len == 0) return error.InvalidEventIdentity;
            const batch = try allocator.alloc(events.ToolUse, calls.len);
            defer allocator.free(batch);
            for (calls, 0..) |call, index| {
                batch[index] = .{
                    .id = call.id,
                    .name = call.name,
                    .args_json = call.args_json,
                    .reasoning_content = call.reasoning_content,
                };
            }
            try writer.appendEntryEvent(allocator, entry_id, null, .{ .tool_use_batch = batch });
        },
        else => try writer.appendEntryEvent(allocator, entry_id, null, entryToEvent(entry)),
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "persister");
}

fn readWhole(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    return (try reader.next()) orelse error.MissingEventFrame;
}

fn readFrames(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList([]u8) {
    var frames: std.ArrayList([]u8) = .empty;
    errdefer {
        for (frames.items) |frame| allocator.free(frame);
        frames.deinit(allocator);
    }
    var reader = try events.Reader.open(allocator, path);
    defer reader.deinit();
    while (try reader.next()) |frame| try frames.append(allocator, frame);
    return frames;
}

fn freeFrames(allocator: std.mem.Allocator, frames: *std.ArrayList([]u8)) void {
    for (frames.items) |frame| allocator.free(frame);
    frames.deinit(allocator);
}

test "appendEntry persists a user_text entry" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const entry: transcript.OwnedEntry = .{ .user_text = "hello user" };
    try appendEntry(allocator, path, 1, &entry, .{});

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("user_text", obj.get("k").?.string);
    try testing.expectEqualStrings("hello user", obj.get("d").?.string);
}

test "appendEntry persists a model_text entry" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const entry: transcript.OwnedEntry = .{ .model_text = "Thinking..." };
    try appendEntry(allocator, path, 1, &entry, .{});

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("model_text", obj.get("k").?.string);
    try testing.expectEqualStrings("Thinking...", obj.get("d").?.string);
}

test "appendEntry on assistant_tool_use writes one atomic tool_use_batch frame" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    var calls = [_]transcript.OwnedToolCall{
        .{
            .id = "toolu_a",
            .name = "zts_expert_meta",
            .args_json = "{}",
            .reasoning_content = "opaque continuation",
        },
        .{ .id = "toolu_b", .name = "workspace_read_file", .args_json = "{\"path\":\"x.ts\"}" },
    };
    const entry: transcript.OwnedEntry = .{ .assistant_tool_use = calls[0..] };
    try appendEntry(allocator, path, 1, &entry, .{});

    var lines = try readFrames(allocator, path);
    defer freeFrames(allocator, &lines);
    try testing.expectEqual(@as(usize, 1), lines.items.len);

    var p1 = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
    defer p1.deinit();
    try testing.expectEqualStrings("tool_use_batch", p1.value.object.get("k").?.string);
    const batch = p1.value.object.get("d").?.array.items;
    try testing.expectEqual(@as(usize, 2), batch.len);
    const d1 = batch[0].object;
    const d2 = batch[1].object;
    try testing.expectEqualStrings("toolu_a", d1.get("id").?.string);
    try testing.expectEqualStrings("zts_expert_meta", d1.get("name").?.string);
    try testing.expectEqualStrings("opaque continuation", d1.get("reasoning_content").?.string);
    try testing.expectEqualStrings("toolu_b", d2.get("id").?.string);
    try testing.expectEqualStrings("workspace_read_file", d2.get("name").?.string);
}

test "appendEntry on tool_result under cap writes body unchanged" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const entry: transcript.OwnedEntry = .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "{\"ok\":true}",
    } };
    try appendEntry(allocator, path, 1, &entry, .{});

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const d = parsed.value.object.get("d").?.object;
    try testing.expectEqualStrings("{\"ok\":true}", d.get("body").?.string);
    try testing.expectEqual(true, d.get("ok").?.bool);
}

test "appendEntry preserves a large projected tool result exactly" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    var big: [1000]u8 = undefined;
    @memset(&big, 'a');

    const entry: transcript.OwnedEntry = .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = &big,
    } };
    try appendEntry(allocator, path, 1, &entry, .{});

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const body = parsed.value.object.get("d").?.object.get("body").?.string;
    try testing.expectEqualSlices(u8, &big, body);

    // Input entry must not have been mutated.
    switch (entry) {
        .tool_result => |tr| try testing.expectEqual(@as(usize, 1000), tr.llm_text.len),
        else => return error.TestFailed,
    }
}

test "appendEntry with no_persist_tool_output writes a structural placeholder" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const entry: transcript.OwnedEntry = .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "secret output",
    } };
    try appendEntry(allocator, path, 1, &entry, .{ .no_persist_tool_output = true });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const body = parsed.value.object.get("d").?.object.get("body").?.string;
    try testing.expectEqualStrings(redacted_tool_output, body);
    try testing.expect(std.mem.indexOf(u8, raw, "secret output") == null);
}

test "appendEntry with no_persist_tool_output still persists user_text" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const entry: transcript.OwnedEntry = .{ .user_text = "still persisted" };
    try appendEntry(allocator, path, 1, &entry, .{ .no_persist_tool_output = true });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("user_text", obj.get("k").?.string);
    try testing.expectEqualStrings("still persisted", obj.get("d").?.string);
}

test "appendEntry on proof_card and diagnostic_box round-trip correctly" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    const proof: transcript.OwnedEntry = .{ .proof_card = .{ .llm_text = "contract ok" } };
    const diag: transcript.OwnedEntry = .{ .diagnostic_box = .{ .llm_text = "ZTS001 veto" } };
    try appendEntry(allocator, path, 1, &proof, .{});
    try appendEntry(allocator, path, 2, &diag, .{});

    var lines = try readFrames(allocator, path);
    defer freeFrames(allocator, &lines);
    try testing.expectEqual(@as(usize, 2), lines.items.len);

    var p1 = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
    defer p1.deinit();
    var p2 = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[1], .{});
    defer p2.deinit();

    try testing.expectEqualStrings("proof_card", p1.value.object.get("k").?.string);
    try testing.expectEqualStrings("contract ok", p1.value.object.get("d").?.object.get("llm_text").?.string);
    try testing.expectEqualStrings("diagnostic_box", p2.value.object.get("k").?.string);
    try testing.expectEqualStrings("ZTS001 veto", p2.value.object.get("d").?.object.get("llm_text").?.string);
}
