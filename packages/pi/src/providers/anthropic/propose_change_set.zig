//! Provider-neutral bridge from `propose_change_set` tool calls to the turn
//! machine's first-class ordered change-set reply.

const std = @import("std");
const turn = @import("../../turn.zig");
const tool_catalog = @import("../tool_catalog.zig");

pub const tool_name = tool_catalog.propose_change_set.name;
pub const tool_description = tool_catalog.propose_change_set.description;
pub const input_schema_literal = tool_catalog.propose_change_set.input_schema;

pub const max_changes: usize = 32;

pub const RemapError = error{
    InvalidChangeSetArgs,
    OutputTruncated,
};

const host_authoritative_keys = tool_catalog.propose_change_set.host_authoritative_keys;

fn remapFailure(stop_reason: ?[]const u8) RemapError {
    if (stop_reason) |reason| {
        if (std.mem.eql(u8, reason, "max_tokens")) return error.OutputTruncated;
    }
    return error.InvalidChangeSetArgs;
}

pub fn maybeRemap(
    arena: std.mem.Allocator,
    reply: turn.AssistantReply,
    stop_reason: ?[]const u8,
) !turn.AssistantReply {
    switch (reply.response) {
        .tool_calls => |calls| {
            if (calls.len != 1) return reply;
            if (!std.mem.eql(u8, calls[0].name, tool_name)) return reply;

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, calls[0].args_json, .{
                .duplicate_field_behavior = .@"error",
            }) catch return remapFailure(stop_reason);
            if (parsed != .object or parsed.object.count() != 1) return remapFailure(stop_reason);
            const changes_value = parsed.object.get("changes") orelse return remapFailure(stop_reason);
            if (changes_value != .array) return remapFailure(stop_reason);
            if (changes_value.array.items.len == 0 or changes_value.array.items.len > max_changes) {
                return remapFailure(stop_reason);
            }

            const additional = try arena.alloc(turn.Change, changes_value.array.items.len - 1);
            var first: turn.Change = undefined;
            for (changes_value.array.items, 0..) |value, index| {
                if (value != .object or value.object.count() != 2) return remapFailure(stop_reason);
                const file_value = value.object.get("file") orelse return remapFailure(stop_reason);
                const content_value = value.object.get("content") orelse return remapFailure(stop_reason);
                if (file_value != .string or content_value != .string or file_value.string.len == 0) {
                    return remapFailure(stop_reason);
                }
                for (host_authoritative_keys) |key| {
                    if (value.object.get(key) != null) return remapFailure(stop_reason);
                }
                const change: turn.Change = .{ .file = file_value.string, .content = content_value.string };
                if (index == 0) {
                    first = change;
                } else {
                    additional[index - 1] = change;
                }
            }

            return .{
                .preamble = reply.preamble,
                .response = .{ .change_set = .{
                    .file = first.file,
                    .content = first.content,
                    .additional = additional,
                    .reasoning_content = calls[0].reasoning_content,
                } },
            };
        },
        else => return reply,
    }
}

const testing = std.testing;

test "single proposal becomes an ordered change set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_changes",
        .name = tool_name,
        .args_json =
        \\{"changes":[{"file":"src/a.ts","content":"a"},{"file":"src/b.tsx","content":"b"}]}
        ,
        .reasoning_content = "opaque continuation",
    }};
    const out = try maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null);
    switch (out.response) {
        .change_set => |set| {
            try testing.expectEqual(@as(usize, 2), set.len());
            try testing.expectEqualStrings("src/a.ts", set.at(0).file);
            try testing.expectEqualStrings("src/b.tsx", set.at(1).file);
            try testing.expectEqualStrings("opaque continuation", set.reasoning_content.?);
        },
        else => return error.TestFailed,
    }
}

test "proposal shape fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const invalid = [_][]const u8{
        "{}",
        "{\"changes\":[]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"extra\":true}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\",\"baseline_sha256\":\"forged\"}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"file\":\"b.ts\",\"content\":\"x\"}]}",
        "{\"changes\":[{\"file\":\"\",\"content\":\"x\"}]}",
        "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}],\"extra\":true}",
    };
    for (invalid) |args_json| {
        const calls = [_]turn.ToolCall{.{ .id = "toolu_bad", .name = tool_name, .args_json = args_json }};
        try testing.expectError(
            error.InvalidChangeSetArgs,
            maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null),
        );
    }
}

test "truncated proposal reports the recoverable error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_bad",
        .name = tool_name,
        .args_json = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"",
    }};
    try testing.expectError(
        error.OutputTruncated,
        maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, "max_tokens"),
    );
}

test "mixed proposal batch remains a normal tool batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_changes", .name = tool_name, .args_json = "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}]}" },
        .{ .id = "toolu_meta", .name = "zts_expert_meta", .args_json = "{}" },
    };
    const out = try maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null);
    try testing.expect(out.response == .tool_calls);
}
