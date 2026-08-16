//! Canonical observations shared by flow recording and replay.

const std = @import("std");
const artifact = @import("artifact.zig");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;

pub fn approvalPreviewDigest(
    allocator: std.mem.Allocator,
    preview: loop.ChangeSetApprovalPreview,
) !artifact.Sha256Hex {
    var canonical = TextBuffer.init(allocator);
    defer canonical.deinit();
    const writer = canonical.writer();
    try writeFrame(writer, preview.proof_id);
    try writer.print("{d}\n", .{preview.changes.len});
    for (preview.changes) |change| {
        try writeFrame(writer, change.file);
        if (change.before) |before| {
            try writeFrame(writer, "before-present");
            try writeFrame(writer, before);
        } else try writeFrame(writer, "before-absent");
        try writeFrame(writer, change.after);
        for (change.rewrite_trace) |rewrite| try writeFrame(writer, rewrite);
    }
    try writeFrame(writer, if (preview.system_proven) "system-proven" else "system-absent");
    return artifact.Sha256Hex.fromBytes(canonical.written());
}

pub fn eventForEntry(
    allocator: std.mem.Allocator,
    index: u32,
    turn_index: u32,
    entry: *const transcript_mod.OwnedEntry,
) !artifact.EventExpectation {
    const kind: artifact.EventKind = switch (entry.*) {
        .user_text => .user_text,
        .model_text => .model_text,
        .assistant_tool_use => .tool_use,
        .tool_result => .tool_result,
        .proof_card => .proof_card,
        .diagnostic_box => .diagnostic_box,
        .verified_change_set => .verified_change_set,
        .system_note => .system_note,
    };
    const payload_sha256 = switch (entry.*) {
        .user_text, .model_text, .system_note => |text| artifact.Sha256Hex.fromBytes(text),
        .proof_card, .diagnostic_box, .verified_change_set => |message| artifact.Sha256Hex.fromBytes(message.llm_text),
        .assistant_tool_use => |calls| blk: {
            var canonical = TextBuffer.init(allocator);
            defer canonical.deinit();
            try std.json.Stringify.value(calls, .{}, canonical.writer());
            break :blk artifact.Sha256Hex.fromBytes(canonical.written());
        },
        .tool_result => |result| blk: {
            var canonical = TextBuffer.init(allocator);
            defer canonical.deinit();
            try std.json.Stringify.value(.{
                .tool_use_id = result.tool_use_id,
                .tool_name = result.tool_name,
                .ok = result.ok,
                .llm_text = result.llm_text,
            }, .{}, canonical.writer());
            break :blk artifact.Sha256Hex.fromBytes(canonical.written());
        },
    };
    return .{
        .index = index,
        .turn_index = turn_index,
        .kind = kind,
        .payload_sha256 = payload_sha256,
    };
}

/// Hashes every stable field in the structured verified-change-set receipt. The
/// wall-clock application time is deliberately excluded so a recording can be
/// replayed later while every semantic and proof-bearing field remains bound.
pub fn applyReceiptDigest(
    allocator: std.mem.Allocator,
    entry: *const transcript_mod.OwnedEntry,
) !artifact.Sha256Hex {
    return switch (entry.*) {
        .verified_change_set => |message| switch (message.ui_payload orelse return error.InvalidApplyReceipt) {
            .verified_change_set => |payload| digestReceiptPayload(allocator, "zttp-change-set-receipt-v1", payload),
            else => return error.InvalidApplyReceipt,
        },
        else => return error.InvalidApplyReceipt,
    };
}

fn digestReceiptPayload(
    allocator: std.mem.Allocator,
    domain: []const u8,
    payload: anytype,
) !artifact.Sha256Hex {
    var canonical = TextBuffer.init(allocator);
    defer canonical.deinit();
    const writer = canonical.writer();
    try writeFrame(writer, domain);
    try writer.writeByte('{');
    var wrote_field = false;
    inline for (@typeInfo(@TypeOf(payload)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "applied_at_unix_ms")) continue;
        if (wrote_field) try writer.writeByte(',');
        wrote_field = true;
        try std.json.Stringify.value(field.name, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(@field(payload, field.name), .{}, writer);
    }
    try writer.writeByte('}');
    return artifact.Sha256Hex.fromBytes(canonical.written());
}

pub fn transcriptKind(entry: *const transcript_mod.OwnedEntry) artifact.TranscriptItemKind {
    return switch (entry.*) {
        .user_text => .user_text,
        .model_text => .model_text,
        .assistant_tool_use => .assistant_tool_use,
        .tool_result => .tool_result,
        .proof_card => .proof_card,
        .diagnostic_box => .diagnostic_box,
        .verified_change_set => .verified_change_set,
        .system_note => .system_note,
    };
}

pub fn lastModelText(transcript: *const transcript_mod.Transcript, start: usize) ?[]const u8 {
    var index = transcript.len();
    while (index > start) {
        index -= 1;
        switch (transcript.entries.items[index]) {
            .model_text => |text| return text,
            else => {},
        }
    }
    return null;
}

pub fn outcomeFromResult(result: loop.TurnResult) artifact.TurnOutcome {
    return switch (result.end_reason) {
        .approved => .approved,
        .approval_denied => .approval_denied,
        .veto_exhausted => .veto_exhausted,
        .budget_roundtrips => .budget_roundtrips,
        .budget_tool_calls => .budget_tool_calls,
        .budget_timeout => .budget_timeout,
        .error_exit => .error_exit,
    };
}

fn writeFrame(writer: anytype, bytes: []const u8) !void {
    try writer.print("{d}:", .{bytes.len});
    try writer.writeAll(bytes);
}
