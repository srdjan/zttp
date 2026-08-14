//! Shared OpenAI-shaped Chat Completions request writing.
//!
//! Two providers speak this wire format: the developer-managed MLX server
//! (`local/client.zig`) and DeepSeek (`deepseek/client.zig`). The bytes are
//! identical for both, so the body writer lives here and each client keeps
//! only what differs: its endpoint policy, its authentication, and its
//! response decoding.
//!
//! Nothing here touches the network or validates a URL. A caller validates
//! its own base URL before calling, because the two providers have opposite
//! policies: local requires a loopback plain-HTTP root, DeepSeek requires
//! HTTPS.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const turn = @import("../turn.zig");
const transcript_mod = @import("../transcript.zig");
const registry_mod = @import("../registry/registry.zig");
const tool_catalog = @import("tool_catalog.zig");
const json_writer = @import("json_writer.zig");
const model_request = @import("model_request.zig");

const writeJsonString = json_writer.writeString;

/// The parts of a provider Config that reach the wire body. Each client
/// projects its own Config into this so neither client's Config type has to
/// be visible here.
pub const BodyParams = struct {
    provider: model_request.Provider = .local,
    model: []const u8,
    max_tokens: u32,
    system_prompt: []const u8,
    tools_json: ?[]const u8 = null,
};

/// Serialize one Chat Completions request. Returned bytes are owned by
/// `arena`.
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    params: BodyParams,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) ![]u8 {
    var snapshot = try model_request.createSnapshot(arena, .{
        .config = .{
            .provider = params.provider,
            .model = params.model,
            .max_output_tokens = params.max_tokens,
            .stream = false,
            .system_prompt = params.system_prompt,
            .tools_json = params.tools_json,
        },
        .transcript = transcript,
        .extra_user_text = extra_user_text,
    });
    defer snapshot.deinit(arena);
    return buildRequestBodyFromSnapshot(arena, &snapshot);
}

/// Serialize from the provider-neutral prepared view. Item-group boundaries
/// retain the exact multi-tool assistant messages emitted by the previous
/// Transcript-based writer.
pub fn buildRequestBodyFromSnapshot(
    arena: std.mem.Allocator,
    snapshot: *const model_request.ModelRequestSnapshot,
) ![]u8 {
    if (snapshot.config.provider != .local and snapshot.config.provider != .deepseek) {
        return error.InvalidProvider;
    }
    var buf = TextBuffer.init(arena);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, snapshot.config.model);
    try writer.print(",\"max_tokens\":{d},\"stream\":false,\"messages\":[", .{snapshot.config.max_output_tokens});
    try writeMessage(writer, "system", snapshot.config.system_prompt);

    for (snapshot.item_groups) |group| {
        const group_items = snapshot.items[group.start..][0..group.len];
        if (group_items.len == 0) return error.InvalidSnapshot;
        switch (group_items[0]) {
            .user_text => |body| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeByte(',');
                try writeMessage(writer, "user", body);
            },
            .model_text => |body| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeByte(',');
                try writeMessage(writer, "assistant", body);
            },
            .system_note => |body| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeByte(',');
                try writeMessage(writer, "user", body);
            },
            .tool_use => {
                try writer.writeAll(",{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[");
                for (group_items, 0..) |item, index| {
                    const call = switch (item) {
                        .tool_use => |value| value,
                        else => return error.InvalidSnapshot,
                    };
                    if (index > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try writeJsonString(writer, call.id);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try writeJsonString(writer, call.name);
                    try writer.writeAll(",\"arguments\":");
                    try writeJsonString(writer, call.args_json);
                    try writer.writeAll("}}");
                }
                try writer.writeAll("]}");
            },
            .tool_result => |result| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                try writeJsonString(writer, result.tool_use_id);
                try writer.writeAll(",\"name\":");
                try writeJsonString(writer, result.tool_name);
                try writer.writeAll(",\"content\":");
                try writeJsonString(writer, if (result.llm_text.len == 0) "(no output)" else result.llm_text);
                try writer.writeByte('}');
            },
        }
    }
    if (snapshot.extra_user_text) |body| {
        try writer.writeByte(',');
        try writeMessage(writer, "user", body);
    }
    try writer.writeByte(']');
    if (snapshot.config.tools_json) |tools| {
        try writer.writeAll(",\"tools\":");
        try writer.writeAll(tools);
        try writer.writeAll(",\"tool_choice\":\"auto\"");
    }
    try writer.writeByte('}');
    return buf.toOwnedSlice();
}

fn writeMessage(writer: anytype, role: []const u8, body: []const u8) !void {
    try writer.writeAll("{\"role\":");
    try writeJsonString(writer, role);
    try writer.writeAll(",\"content\":");
    try writeJsonString(writer, body);
    try writer.writeByte('}');
}

/// The `tools` array in OpenAI function-calling shape.
pub fn writeToolsArray(writer: anytype, registry: *const registry_mod.Registry) !void {
    var tools = tool_catalog.iterator(registry);
    try writer.writeByte('[');
    var index: usize = 0;
    while (tools.next()) |tool| {
        if (index > 0) try writer.writeByte(',');
        index += 1;
        try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try writeJsonString(writer, tool.name);
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, tool.description);
        try writer.writeAll(",\"parameters\":");
        try writer.writeAll(tool.input_schema);
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
}

const testing = std.testing;

test "buildRequestBody carries system, user, tool call, and tool result turns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .user_text = "read the handler" });
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
    }};
    try transcript.append(ta, .{ .assistant_tool_use = &calls });
    try transcript.append(ta, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "export default {}",
    } });

    const body = try buildRequestBody(ta, .{
        .model = "test-model",
        .max_tokens = 128,
        .system_prompt = "be exact",
        .tools_json = "[]",
    }, &transcript, "and then stop");

    try testing.expect(std.mem.startsWith(u8, body, "{\"model\":\"test-model\",\"max_tokens\":128,\"stream\":false,"));
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"system\",\"content\":\"be exact\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"read the handler\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[{\"id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"tool\",\"tool_call_id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"role\":\"user\",\"content\":\"and then stop\"}") != null);
    try testing.expect(std.mem.endsWith(u8, body, ",\"tools\":[],\"tool_choice\":\"auto\"}"));
}

test "buildRequestBody omits the tools field when no catalog is supplied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);

    const body = try buildRequestBody(ta, .{
        .model = "m",
        .max_tokens = 8,
        .system_prompt = "s",
    }, &transcript, null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try testing.expect(std.mem.endsWith(u8, body, "]}"));
}

test "an empty tool result still sends a non-empty content field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .tool_result = .{
        .tool_use_id = "call_2",
        .tool_name = "zig_build_step",
        .ok = true,
        .llm_text = "",
    } });

    const body = try buildRequestBody(ta, .{
        .model = "m",
        .max_tokens = 8,
        .system_prompt = "s",
    }, &transcript, null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"(no output)\"") != null);
}
