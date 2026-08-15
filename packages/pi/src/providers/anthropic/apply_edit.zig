//! Synthetic `apply_edit` bridge between provider tool vocabularies and the
//! turn machine's first-class `.edit` reply shape.
//!
//! Its provider-neutral definition lives in `providers/tool_catalog.zig`; this
//! module only validates and remaps a call before it reaches the registry.

const std = @import("std");
const turn = @import("../../turn.zig");
const tool_catalog = @import("../tool_catalog.zig");

pub const tool_name = tool_catalog.apply_edit.name;
pub const tool_description = tool_catalog.apply_edit.description;
pub const input_schema_literal = tool_catalog.apply_edit.input_schema;

pub const RemapError = error{
    InvalidEditArgs,
    /// The model hit its output-token limit mid-`apply_edit`, so the tool
    /// input JSON is incomplete. Distinct from InvalidEditArgs (a genuinely
    /// malformed args object) because it is recoverable with actionable
    /// guidance - split the change - rather than an opaque fatal crash.
    OutputTruncated,
};

const host_authoritative_keys = tool_catalog.apply_edit.host_authoritative_keys;

/// A parse/shape failure on an `apply_edit` payload is truncation (recoverable)
/// when the response stopped on the output-token limit, and a malformed-args bug
/// otherwise.
fn remapFailure(stop_reason: ?[]const u8) RemapError {
    if (stop_reason) |sr| {
        if (std.mem.eql(u8, sr, "max_tokens")) return RemapError.OutputTruncated;
    }
    return RemapError.InvalidEditArgs;
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

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, calls[0].args_json, .{}) catch {
                return remapFailure(stop_reason);
            };
            if (parsed != .object) return remapFailure(stop_reason);
            const obj = parsed.object;

            const file_v = obj.get("file") orelse return remapFailure(stop_reason);
            const content_v = obj.get("content") orelse return remapFailure(stop_reason);
            if (file_v != .string or content_v != .string) return remapFailure(stop_reason);
            // The baseline is host-authoritative: a model-supplied one is a
            // forged pre-image and must be refused. Every other extra property
            // is ignored, because failing the whole call over one stray field a
            // provider habitually emits kills the turn for no safety gain.
            for (host_authoritative_keys) |key| {
                if (obj.get(key) != null) return remapFailure(stop_reason);
            }

            return .{
                .preamble = reply.preamble,
                .response = .{ .edit = .{
                    .file = file_v.string,
                    .content = content_v.string,
                    .reasoning_content = calls[0].reasoning_content,
                } },
            };
        },
        else => return reply,
    }
}

const testing = std.testing;
const sse_parser = @import("sse_parser.zig");
const response_assembler = @import("response_assembler.zig");

test "maybeRemap: non-matching tool batch passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_meta", .name = "zts_expert_meta", .args_json = "{}" },
    };
    const reply: turn.AssistantReply = .{
        .response = .{ .tool_calls = &calls },
    };

    const out = try maybeRemap(arena.allocator(), reply, null);
    switch (out.response) {
        .tool_calls => |out_calls| try testing.expectEqualStrings("zts_expert_meta", out_calls[0].name),
        else => return error.TestFailed,
    }
}

test "maybeRemap: single apply_edit tool call produces .edit reply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const calls = [_]turn.ToolCall{
        .{
            .id = "toolu_edit",
            .name = tool_name,
            .args_json = "{\"file\":\"handler.ts\",\"content\":\"function handler(req) { return Response.json({ok:true}); }\"}",
            .reasoning_content = "opaque continuation",
        },
    };
    const reply: turn.AssistantReply = .{
        .response = .{ .tool_calls = &calls },
    };

    const out = try maybeRemap(arena.allocator(), reply, null);
    switch (out.response) {
        .edit => |edit| {
            try testing.expectEqualStrings("handler.ts", edit.file);
            try testing.expect(std.mem.indexOf(u8, edit.content, "Response.json") != null);
            try testing.expectEqualStrings("opaque continuation", edit.reasoning_content.?);
        },
        else => return error.TestFailed,
    }
}

test "maybeRemap: apply_edit in a mixed tool batch stays as tool_calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_edit", .name = tool_name, .args_json = "{\"file\":\"h.ts\",\"content\":\"new\"}" },
        .{ .id = "toolu_meta", .name = "zts_expert_meta", .args_json = "{}" },
    };
    const reply: turn.AssistantReply = .{
        .response = .{ .tool_calls = &calls },
    };

    const out = try maybeRemap(arena.allocator(), reply, null);
    try testing.expect(out.response == .tool_calls);
}

test "maybeRemap: rejects a model-supplied before baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_edit",
        .name = tool_name,
        .args_json = "{\"file\":\"handler.ts\",\"content\":\"new\",\"before\":\"forged\"}",
    }};
    try testing.expectError(
        RemapError.InvalidEditArgs,
        maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null),
    );
}

test "maybeRemap: an extra field that is not a baseline is ignored, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_edit",
        .name = tool_name,
        .args_json = "{\"file\":\"handler.ts\",\"content\":\"new\",\"reason\":\"add route\"}",
    }};
    const out = try maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null);
    switch (out.response) {
        .edit => |edit| {
            try testing.expectEqualStrings("handler.ts", edit.file);
            try testing.expectEqualStrings("new", edit.content);
        },
        else => return error.TestFailed,
    }
}

test "maybeRemap: every host-authoritative key stays refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (host_authoritative_keys) |key| {
        const args = "{\"file\":\"handler.ts\",\"content\":\"new\",\"" ++ key ++ "\":\"forged\"}";
        const calls = [_]turn.ToolCall{.{ .id = "toolu_edit", .name = tool_name, .args_json = args }};
        try testing.expectError(
            RemapError.InvalidEditArgs,
            maybeRemap(arena.allocator(), .{ .response = .{ .tool_calls = &calls } }, null),
        );
    }
}

test "maybeRemap: malformed JSON returns InvalidEditArgs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_edit", .name = tool_name, .args_json = "{not valid json" },
    };
    const reply: turn.AssistantReply = .{
        .response = .{ .tool_calls = &calls },
    };
    try testing.expectError(RemapError.InvalidEditArgs, maybeRemap(arena.allocator(), reply, null));
}

test "maybeRemap: apply_edit truncated at the output cap returns OutputTruncated, not InvalidEditArgs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A whole-file content field cut off mid-string when the model hit its
    // output-token limit: structurally the same parse failure as a malformed
    // args object, but recoverable with "split the change" guidance rather than
    // a fatal crash.
    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_edit", .name = tool_name, .args_json = "{\"file\":\"handler.ts\",\"content\":\"function handler(req) { return Resp" },
    };
    const reply: turn.AssistantReply = .{
        .response = .{ .tool_calls = &calls },
    };
    try testing.expectError(RemapError.OutputTruncated, maybeRemap(arena.allocator(), reply, "max_tokens"));

    // The identical truncation shape, but stopped for a normal reason, is a
    // genuine malformed-args bug.
    try testing.expectError(RemapError.InvalidEditArgs, maybeRemap(arena.allocator(), reply, "end_turn"));
}

test "full pipeline: cassette -> parse -> assemble -> remap -> .edit reply" {
    const cassette = @embedFile("cassettes/apply_edit_tool.sse");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    const events = try sse_parser.parseAll(ta, cassette);
    const outcome = try response_assembler.assemble(ta, events);
    const remapped = try maybeRemap(ta, outcome.reply, outcome.stop_reason);

    switch (remapped.response) {
        .edit => |edit| {
            try testing.expectEqualStrings("handler.ts", edit.file);
            try testing.expect(std.mem.indexOf(u8, edit.content, "Response.json") != null);
        },
        else => return error.TestFailed,
    }
    try testing.expectEqualStrings("tool_use", outcome.stop_reason.?);
}
