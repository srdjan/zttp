//! Ownership-safe transcript for user text, assistant narration, structured
//! tool-use, tool results, and visible verification output.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const turn = @import("turn.zig");
const ui_payload = @import("ui_payload.zig");

/// Return an allocator-owned display-only copy of `body`, capped at `max`
/// bytes. The transcript and persisted provider projection stay untouched;
/// this exists only to keep live terminal rendering manageable.
///
/// If `max` is smaller than the truncation suffix itself, the function falls
/// back to a short fixed marker so it never crashes on tiny `max` values.
fn capToolResultBodyForDisplay(
    allocator: std.mem.Allocator,
    body: []const u8,
    max: usize,
) ![]u8 {
    if (body.len <= max) return try allocator.dupe(u8, body);

    const suffix_prefix = "\n...[truncated ";
    const suffix_tail = " bytes]";

    // Render the digit count against an upper bound on dropped bytes so the
    // suffix width is known before sizing the keep slice. body.len fits in
    // usize, which prints in at most 20 decimal digits.
    var num_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&num_buf, "{d}", .{body.len}) catch unreachable;
    const suffix_len = suffix_prefix.len + digits.len + suffix_tail.len;

    if (max < suffix_len) return try allocator.dupe(u8, "...[truncated]");

    const keep = max - suffix_len;
    const dropped = body.len - keep;
    const real_digits = std.fmt.bufPrint(&num_buf, "{d}", .{dropped}) catch unreachable;
    const real_suffix_len = suffix_prefix.len + real_digits.len + suffix_tail.len;
    const total = keep + real_suffix_len;

    const out = try allocator.alloc(u8, total);
    @memcpy(out[0..keep], body[0..keep]);
    @memcpy(out[keep .. keep + suffix_prefix.len], suffix_prefix);
    @memcpy(
        out[keep + suffix_prefix.len .. keep + suffix_prefix.len + real_digits.len],
        real_digits,
    );
    @memcpy(out[keep + suffix_prefix.len + real_digits.len ..], suffix_tail);
    return out;
}

pub const OwnedToolCall = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
    reasoning_content: ?[]const u8 = null,

    pub fn deinit(self: *OwnedToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.args_json);
        if (self.reasoning_content) |body| allocator.free(body);
        self.* = .{ .id = &.{}, .name = &.{}, .args_json = &.{}, .reasoning_content = null };
    }
};

pub const OwnedToolResult = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    ok: bool,
    llm_text: []const u8,
    ui_payload: ?ui_payload.UiPayload = null,

    pub fn deinit(self: *OwnedToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_use_id);
        allocator.free(self.tool_name);
        allocator.free(self.llm_text);
        if (self.ui_payload) |*payload| payload.deinit(allocator);
        self.* = .{
            .tool_use_id = &.{},
            .tool_name = &.{},
            .ok = false,
            .llm_text = &.{},
            .ui_payload = null,
        };
    }
};

pub const OwnedDisplayMessage = struct {
    llm_text: []const u8,
    ui_payload: ?ui_payload.UiPayload = null,

    pub fn deinit(self: *OwnedDisplayMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.llm_text);
        if (self.ui_payload) |*payload| payload.deinit(allocator);
        self.* = .{ .llm_text = &.{}, .ui_payload = null };
    }
};

pub const OwnedEntry = union(enum) {
    user_text: []const u8,
    model_text: []const u8,
    assistant_tool_use: []OwnedToolCall,
    proof_card: OwnedDisplayMessage,
    diagnostic_box: OwnedDisplayMessage,
    verified_patch: OwnedDisplayMessage,
    tool_result: OwnedToolResult,
    system_note: []const u8,

    pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .user_text => |body| allocator.free(body),
            .model_text => |body| allocator.free(body),
            .proof_card => |*message| message.deinit(allocator),
            .diagnostic_box => |*message| message.deinit(allocator),
            .verified_patch => |*message| message.deinit(allocator),
            .system_note => |body| allocator.free(body),
            .assistant_tool_use => |calls| {
                for (calls) |*call| call.deinit(allocator);
                allocator.free(calls);
            },
            .tool_result => |*result| result.deinit(allocator),
        }
        self.* = .{ .user_text = &.{} };
    }
};

pub const Tag = std.meta.Tag(OwnedEntry);
pub const EntryId = u64;

pub const Projection = struct {
    summary: []const u8,
    first_kept_entry_id: EntryId,
    read_files: []const []const u8,
    modified_files: []const []const u8,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.read_files) |file| allocator.free(file);
        for (self.modified_files) |file| allocator.free(file);
        if (self.read_files.len > 0) allocator.free(self.read_files);
        if (self.modified_files.len > 0) allocator.free(self.modified_files);
        self.* = undefined;
    }
};

pub const Transcript = struct {
    entries: std.ArrayListUnmanaged(OwnedEntry) = .empty,
    /// Latest provider-visible projection checkpoint. Raw entries are never
    /// removed by compaction; proof, ledger, and replay consumers continue to
    /// scan the append-only `entries` list.
    projection: ?Projection = null,
    /// Optional observer fired after each successful append, with the entry
    /// just stored. `--print --mode json` uses it to stream NDJSON events live,
    /// so a turn that later crashes or is killed still leaves its transcript on
    /// stdout instead of losing everything to the post-turn replay.
    observer: ?Observer = null,

    pub const Observer = struct {
        context: *anyopaque,
        /// Best-effort: must not fail the turn, so it returns void and swallows
        /// its own write errors.
        on_append: *const fn (context: *anyopaque, entry: *const OwnedEntry) void,
    };

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        if (self.projection) |*projection| projection.deinit(allocator);
        self.* = .{};
    }

    pub fn append(
        self: *Transcript,
        allocator: std.mem.Allocator,
        message: turn.Message,
    ) !void {
        try self.entries.append(allocator, try ownMessage(allocator, message));
        if (self.observer) |obs| {
            obs.on_append(obs.context, &self.entries.items[self.entries.items.len - 1]);
        }
    }

    pub fn len(self: *const Transcript) usize {
        return self.entries.items.len;
    }

    pub fn at(self: *const Transcript, index: usize) *const OwnedEntry {
        return &self.entries.items[index];
    }

    pub fn entryIdAt(self: *const Transcript, index: usize) EntryId {
        std.debug.assert(index < self.entries.items.len);
        return @intCast(index + 1);
    }

    pub fn nextEntryId(self: *const Transcript) EntryId {
        return @intCast(self.entries.items.len + 1);
    }

    pub fn activeStartIndex(self: *const Transcript) !usize {
        const projection = self.projection orelse return 0;
        if (projection.first_kept_entry_id == 0 or
            projection.first_kept_entry_id > self.nextEntryId())
        {
            return error.InvalidProjectionCut;
        }
        return @intCast(projection.first_kept_entry_id - 1);
    }

    pub fn replaceProjection(
        self: *Transcript,
        allocator: std.mem.Allocator,
        summary: []const u8,
        first_kept_entry_id: EntryId,
    ) !void {
        return self.replaceProjectionWithFiles(
            allocator,
            summary,
            first_kept_entry_id,
            &.{},
            &.{},
        );
    }

    pub fn replaceProjectionWithFiles(
        self: *Transcript,
        allocator: std.mem.Allocator,
        summary: []const u8,
        first_kept_entry_id: EntryId,
        read_files: []const []const u8,
        modified_files: []const []const u8,
    ) !void {
        if (first_kept_entry_id == 0 or first_kept_entry_id > self.nextEntryId()) {
            return error.InvalidProjectionCut;
        }
        const summary_copy = try allocator.dupe(u8, summary);
        errdefer allocator.free(summary_copy);
        const read_copies = try dupeStrings(allocator, read_files);
        errdefer freeStrings(allocator, read_copies);
        const modified_copies = try dupeStrings(allocator, modified_files);
        errdefer freeStrings(allocator, modified_copies);
        if (self.projection) |*projection| projection.deinit(allocator);
        self.projection = .{
            .summary = summary_copy,
            .first_kept_entry_id = first_kept_entry_id,
            .read_files = read_copies,
            .modified_files = modified_copies,
        };
    }

    pub fn installProjectionOwned(
        self: *Transcript,
        allocator: std.mem.Allocator,
        summary: []u8,
        first_kept_entry_id: EntryId,
    ) void {
        std.debug.assert(first_kept_entry_id > 0 and first_kept_entry_id <= self.nextEntryId());
        if (self.projection) |*projection| projection.deinit(allocator);
        self.projection = .{
            .summary = summary,
            .first_kept_entry_id = first_kept_entry_id,
            .read_files = &.{},
            .modified_files = &.{},
        };
    }

    pub fn installProjectionOwnedWithFiles(
        self: *Transcript,
        allocator: std.mem.Allocator,
        summary: []u8,
        first_kept_entry_id: EntryId,
        read_files: [][]u8,
        modified_files: [][]u8,
    ) void {
        std.debug.assert(first_kept_entry_id > 0 and first_kept_entry_id <= self.nextEntryId());
        if (self.projection) |*projection| projection.deinit(allocator);
        self.projection = .{
            .summary = summary,
            .first_kept_entry_id = first_kept_entry_id,
            .read_files = read_files,
            .modified_files = modified_files,
        };
    }
};

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
    const copies = try allocator.alloc([]u8, strings.len);
    errdefer allocator.free(copies);
    var initialized: usize = 0;
    errdefer for (copies[0..initialized]) |copy| allocator.free(copy);
    for (strings, 0..) |string, index| {
        copies[index] = try allocator.dupe(u8, string);
        initialized += 1;
    }
    return copies;
}

fn freeStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn ownMessage(allocator: std.mem.Allocator, message: turn.Message) !OwnedEntry {
    return switch (message) {
        .user_text => |body| .{ .user_text = try allocator.dupe(u8, body) },
        .model_text => |body| .{ .model_text = try allocator.dupe(u8, body) },
        .proof_card => |body| .{ .proof_card = try ownDisplayMessage(allocator, body) },
        .diagnostic_box => |body| .{ .diagnostic_box = try ownDisplayMessage(allocator, body) },
        .assistant_tool_use => |calls| blk: {
            const owned = try allocator.alloc(OwnedToolCall, calls.len);
            errdefer allocator.free(owned);
            for (calls, 0..) |call, i| {
                owned[i] = .{
                    .id = try allocator.dupe(u8, call.id),
                    .name = try allocator.dupe(u8, call.name),
                    .args_json = try allocator.dupe(u8, call.args_json),
                    .reasoning_content = if (call.reasoning_content) |body|
                        try allocator.dupe(u8, body)
                    else
                        null,
                };
            }
            break :blk .{ .assistant_tool_use = owned };
        },
        .tool_result => |result| .{ .tool_result = .{
            .tool_use_id = try allocator.dupe(u8, result.tool_use_id),
            .tool_name = try allocator.dupe(u8, result.tool_name),
            .ok = result.ok,
            .llm_text = try allocator.dupe(u8, result.llm_text),
            .ui_payload = if (result.ui_payload) |payload|
                try payload.clone(allocator)
            else
                null,
        } },
        .system_note => |body| .{ .system_note = try allocator.dupe(u8, body) },
    };
}

fn ownDisplayMessage(
    allocator: std.mem.Allocator,
    message: turn.DisplayMessage,
) !OwnedDisplayMessage {
    return .{
        .llm_text = try allocator.dupe(u8, message.llm_text),
        .ui_payload = if (message.ui_payload) |payload|
            try payload.clone(allocator)
        else
            null,
    };
}

pub fn renderPlain(writer: anytype, entry: *const OwnedEntry) !void {
    switch (entry.*) {
        .user_text => |body| try writeTaggedLine(writer, "user", body),
        .model_text => |body| try writeTaggedLine(writer, "model", body),
        .proof_card => |message| try writeTaggedLine(writer, "proof", message.llm_text),
        .diagnostic_box => |message| try writeTaggedLine(writer, "error", message.llm_text),
        .verified_patch => |message| try writeTaggedLine(writer, "patch", message.llm_text),
        .system_note => |body| try writeTaggedLine(writer, "note", body),
        .assistant_tool_use => |calls| {
            try writer.writeAll("assistant: tool_use ");
            for (calls, 0..) |call, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(call.name);
            }
            try writer.writeAll("\n");
        },
        .tool_result => |result| {
            try writer.writeAll("tool ");
            try writer.writeAll(result.tool_name);
            try writer.writeAll(": ");
            try writer.writeAll(result.llm_text);
            if (result.llm_text.len == 0 or result.llm_text[result.llm_text.len - 1] != '\n') {
                try writer.writeAll("\n");
            }
        },
    }
}

fn writeTaggedLine(writer: anytype, label: []const u8, body: []const u8) !void {
    try writer.writeAll(label);
    try writer.writeAll(": ");
    try writer.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') {
        try writer.writeAll("\n");
    }
}

fn renderAll(writer: anytype, transcript: *const Transcript) !void {
    for (transcript.entries.items) |*entry| {
        try renderPlain(writer, entry);
    }
}

fn renderRich(writer: *std.Io.Writer, entry: *const OwnedEntry) !void {
    // Proof-bearing entries carry a structured ui_payload whose llm_text is raw
    // analyzer JSON; render those legibly for humans. Everything else (and any
    // entry without a payload) falls through to the plain-text label form.
    const payload: ?ui_payload.UiPayload = switch (entry.*) {
        .proof_card, .diagnostic_box, .verified_patch => |message| message.ui_payload,
        .tool_result => |result| result.ui_payload,
        else => null,
    };
    if (payload) |p| {
        if (try ui_payload.writeLegible(writer, p)) return;
    }
    try renderPlain(writer, entry);
}

pub fn renderRichEntryToOwned(
    allocator: std.mem.Allocator,
    entry: *const OwnedEntry,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try renderRich(buf.writer(), entry);
    return try buf.toOwnedSlice();
}

/// Byte cap applied to a `tool_result` body when it is rendered live to the
/// interactive terminal. A single tool result (a full file dump, a long
/// diagnostic blob) can be hundreds of KB; printing it verbatim floods the
/// scrollback and buries the model's prose. The persisted/JSON paths keep the
/// full body (the persister has its own, much larger disk cap); only the live
/// TTY view is trimmed, with a `...[truncated N bytes]` marker.
pub const tty_tool_result_cap: usize = 4 * 1024;

/// Like `renderRichEntryToOwned`, but caps an oversized `.tool_result` body to
/// `tty_tool_result_cap` before rendering so the live terminal stream is not
/// flooded. All other entry kinds render identically. Used only by the
/// interactive REPL's live render path; persistence and `--print --mode json`
/// keep the uncapped renderer.
pub fn renderRichEntryToOwnedTty(
    allocator: std.mem.Allocator,
    entry: *const OwnedEntry,
) ![]u8 {
    switch (entry.*) {
        .tool_result => |result| {
            if (result.llm_text.len > tty_tool_result_cap) {
                const capped = try capToolResultBodyForDisplay(allocator, result.llm_text, tty_tool_result_cap);
                defer allocator.free(capped);
                // Shallow copy with the capped body; the ui_payload is borrowed
                // (not freed here) and never longer than the cap anyway.
                const trimmed: OwnedEntry = .{ .tool_result = .{
                    .tool_use_id = result.tool_use_id,
                    .tool_name = result.tool_name,
                    .ok = result.ok,
                    .llm_text = capped,
                    .ui_payload = result.ui_payload,
                } };
                return try renderRichEntryToOwned(allocator, &trimmed);
            }
        },
        else => {},
    }
    return try renderRichEntryToOwned(allocator, entry);
}

const testing = std.testing;
const veto = @import("veto.zig");

fn renderToString(
    allocator: std.mem.Allocator,
    transcript: *const Transcript,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try renderAll(buf.writer(), transcript);
    return try buf.toOwnedSlice();
}

test "append dupes textual message bodies" {
    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);

    {
        var scratch = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
        try tr.append(testing.allocator, .{ .user_text = scratch[0..] });
        scratch[0] = 'X';
    }

    switch (tr.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("hello", body),
        else => return error.TestFailed,
    }
}

test "assistant_tool_use and tool_result variants are preserved" {
    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_1", .name = "zts_expert_meta", .args_json = "{}" },
        .{ .id = "toolu_2", .name = "zts_expert_features", .args_json = "{}" },
    };
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "{\"ok\":true}\n",
    } });

    switch (tr.at(0).*) {
        .assistant_tool_use => |owned_calls| {
            try testing.expectEqual(@as(usize, 2), owned_calls.len);
            try testing.expectEqualStrings("zts_expert_meta", owned_calls[0].name);
        },
        else => return error.TestFailed,
    }
    switch (tr.at(1).*) {
        .tool_result => |result| {
            try testing.expect(result.ok);
            try testing.expectEqualStrings("toolu_1", result.tool_use_id);
        },
        else => return error.TestFailed,
    }
}

test "every entry variant renders a stable plain-text label" {
    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_1", .name = "zts_expert_meta", .args_json = "{}" },
    };
    try tr.append(testing.allocator, .{ .user_text = "add a route" });
    try tr.append(testing.allocator, .{ .model_text = "I'll inspect first." });
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "{\"ok\":true}",
    } });
    try tr.append(testing.allocator, .{ .proof_card = .{ .llm_text = "contract ok" } });
    try tr.append(testing.allocator, .{ .diagnostic_box = .{ .llm_text = "ZTS001 unsupported var" } });

    const out = try renderToString(testing.allocator, &tr);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "user: add a route\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model: I'll inspect first.\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "assistant: tool_use zts_expert_meta\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tool zts_expert_meta: {\"ok\":true}\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "proof: contract ok\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "error: ZTS001 unsupported var\n") != null);
}

test "display cap returns original body when under the cap" {
    const out = try capToolResultBodyForDisplay(testing.allocator, "hello", 100);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "display cap returns original body when exactly at the cap" {
    const out = try capToolResultBodyForDisplay(testing.allocator, "hello", 5);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "display cap truncates with a byte-count suffix when over the cap" {
    var big: [1000]u8 = undefined;
    @memset(&big, 'a');

    const out = try capToolResultBodyForDisplay(testing.allocator, &big, 100);
    defer testing.allocator.free(out);

    try testing.expect(out.len <= 100);
    try testing.expect(std.mem.indexOf(u8, out, "[truncated") != null);

    // The suffix must encode the exact number of dropped bytes.
    const suffix_prefix = "\n...[truncated ";
    const idx = std.mem.indexOf(u8, out, suffix_prefix) orelse return error.TestFailed;
    const digits_start = idx + suffix_prefix.len;
    const digits_end = std.mem.indexOfScalarPos(u8, out, digits_start, ' ') orelse return error.TestFailed;
    const dropped = try std.fmt.parseInt(usize, out[digits_start..digits_end], 10);
    try testing.expectEqual(big.len - idx, dropped);
}

test "renderRichEntryToOwnedTty caps an oversized tool_result body for the live terminal" {
    const big_len = tty_tool_result_cap * 2;
    const big = try testing.allocator.alloc(u8, big_len);
    defer testing.allocator.free(big);
    @memset(big, 'a');

    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_big",
        .tool_name = "read_file",
        .ok = true,
        .llm_text = big,
        .ui_payload = null,
    } });

    // The live TTY render is capped and carries the truncation marker.
    const tty = try renderRichEntryToOwnedTty(testing.allocator, tr.at(0));
    defer testing.allocator.free(tty);
    try testing.expect(tty.len < big_len);
    try testing.expect(std.mem.indexOf(u8, tty, "[truncated") != null);

    // The uncapped renderer (persistence/json paths) keeps the full body.
    const full = try renderRichEntryToOwned(testing.allocator, tr.at(0));
    defer testing.allocator.free(full);
    try testing.expect(std.mem.indexOf(u8, full, "[truncated") == null);
    try testing.expect(full.len > tty.len);
}

test "renderRichEntryToOwnedTty leaves a small tool_result body untouched" {
    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_small",
        .tool_name = "read_file",
        .ok = true,
        .llm_text = "ok",
        .ui_payload = null,
    } });

    const tty = try renderRichEntryToOwnedTty(testing.allocator, tr.at(0));
    defer testing.allocator.free(tty);
    try testing.expect(std.mem.indexOf(u8, tty, "[truncated") == null);
    try testing.expect(std.mem.indexOf(u8, tty, "ok") != null);
}

test "veto -> turn -> transcript pipeline still lands a proof entry" {
    var result = try veto.runVeto(testing.allocator, .{
        .file = "handler.ts",
        .content = "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ok: true}); }",
        .before = null,
    });
    defer result.deinit(testing.allocator);

    var machine: turn.TurnMachine = .{ .state = .verifying_edit };
    const action = machine.transition(.{ .edit_verified = result.outcome });

    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);

    switch (action) {
        .render => |msg| try tr.append(testing.allocator, msg),
        else => return error.TestFailed,
    }

    switch (tr.at(0).*) {
        .proof_card => |message| try testing.expect(std.mem.indexOf(u8, message.llm_text, "\"total\":0") != null),
        else => return error.TestFailed,
    }
}

test "renderRich renders a proof_card payload legibly, not as raw edit-simulate JSON" {
    var result = try veto.runVeto(testing.allocator, .{
        .file = "handler.ts",
        .content = "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ok: true}); }",
        .before = null,
    });
    defer result.deinit(testing.allocator);

    var machine: turn.TurnMachine = .{ .state = .verifying_edit };
    const action = machine.transition(.{ .edit_verified = result.outcome });

    var tr: Transcript = .{};
    defer tr.deinit(testing.allocator);

    switch (action) {
        .render => |msg| try tr.append(testing.allocator, msg),
        else => return error.TestFailed,
    }

    // The entry's llm_text is the raw edit-simulate JSON envelope; the rich
    // (human) renderer must instead surface the legible proof card.
    const rendered = try renderRichEntryToOwned(testing.allocator, tr.at(0));
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "PROVEN") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Compiler verification") != null);
    // No raw analyzer JSON should leak into the human rendering.
    try testing.expect(std.mem.indexOf(u8, rendered, "\"total\"") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"violations\":[") == null);
}
