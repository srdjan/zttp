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

    // A DeepSeek reply that both says something and calls a tool is one message
    // carrying `content`, `reasoning_content`, and `tool_calls`. The transcript
    // splits it: `callModel` appends the preamble as its own `model_text` item
    // before the tool calls land. Written out as two assistant messages, the
    // preamble half has no `reasoning_content`, and DeepSeek in thinking mode
    // answers 400 "The `reasoning_content` in the thinking mode must be passed
    // back to the API." - measured against a captured recorder request on
    // 2026-08-25, on a corpus that recorded cleanly on 2026-08-17. So the two
    // halves are rejoined here, into the shape the provider itself returned.
    //
    // A `model_text` the provider is not about to follow with tool calls stays
    // its own message. Final-answer reasoning is scrubbed on the way in and
    // never reaches the transcript, so there is nothing to pass back for it;
    // that shape is only reachable when a later turn re-sends a completed
    // answer, which this corpus never does.
    var pending_preamble: ?[]const u8 = null;
    var group_index: usize = 0;
    while (group_index < snapshot.item_groups.len) : (group_index += 1) {
        const group = snapshot.item_groups[group_index];
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
                if (snapshot.config.provider == .deepseek and
                    nextGroupIsToolUse(snapshot, group_index))
                {
                    pending_preamble = body;
                    continue;
                }
                try writer.writeByte(',');
                try writeMessage(writer, "assistant", body);
            },
            .system_note => |body| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeByte(',');
                try writeMessage(writer, "user", body);
            },
            .compaction_summary => |body| {
                if (group_items.len != 1) return error.InvalidSnapshot;
                try writer.writeByte(',');
                try writeMessage(writer, "user", model_request.compaction_summary_marker);
                try writer.writeByte(',');
                try writeMessage(writer, "user", body);
            },
            .tool_use => {
                try writer.writeAll(",{\"role\":\"assistant\",\"content\":");
                if (snapshot.config.provider == .deepseek) {
                    if (pending_preamble) |text| {
                        try writeJsonString(writer, text);
                    } else {
                        try writer.writeAll("\"\"");
                    }
                    pending_preamble = null;
                    if (group_items[0].tool_use.reasoning_content) |reasoning| {
                        try writer.writeAll(",\"reasoning_content\":");
                        try writeJsonString(writer, reasoning);
                    }
                } else {
                    try writer.writeAll("null");
                }
                try writer.writeAll(",\"tool_calls\":[");
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
        if (snapshot.config.provider != .deepseek) {
            try writer.writeAll(",\"tool_choice\":\"auto\"");
        }
    }
    if (snapshot.config.provider == .deepseek and
        snapshot.config.purpose == .summarization)
    {
        try writer.writeAll(",\"thinking\":{\"type\":\"disabled\"}");
    }
    try writer.writeByte('}');
    return buf.toOwnedSlice();
}

/// Whether the group after `index` is an assistant tool-call group, which is
/// what makes a preceding `model_text` a preamble rather than an answer.
fn nextGroupIsToolUse(
    snapshot: *const model_request.ModelRequestSnapshot,
    index: usize,
) bool {
    if (index + 1 >= snapshot.item_groups.len) return false;
    const next = snapshot.item_groups[index + 1];
    if (next.len == 0) return false;
    return snapshot.items[next.start] == .tool_use;
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

test "DeepSeek tool turns preserve opaque reasoning and omit tool_choice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    const calls = [_]turn.ToolCall{.{
        .id = "call_reasoning",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
        .reasoning_content = "opaque continuation",
    }};
    try transcript.append(ta, .{ .assistant_tool_use = &calls });
    try transcript.append(ta, .{ .tool_result = .{
        .tool_use_id = "call_reasoning",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "ok",
    } });

    const body = try buildRequestBody(ta, .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .max_tokens = 128,
        .system_prompt = "be exact",
        .tools_json = "[]",
    }, &transcript, null);

    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"\",\"reasoning_content\":\"opaque continuation\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
}

test "a DeepSeek preamble rejoins the tool-call message it introduced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .user_text = "read the handler" });
    try transcript.append(ta, .{ .model_text = "I will read it first." });
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
        .reasoning_content = "opaque continuation",
    }};
    try transcript.append(ta, .{ .assistant_tool_use = &calls });
    try transcript.append(ta, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "export default {}",
    } });

    const body = try buildRequestBody(ta, .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .max_tokens = 128,
        .system_prompt = "be exact",
        .tools_json = "[]",
    }, &transcript, null);

    // The exact shape the provider returned: one assistant message carrying the
    // preamble, the continuation, and the calls. Asserted as the value expected,
    // not as the absence of the old one - a body that stopped emitting the
    // preamble at all would satisfy an absence check.
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"role\":\"assistant\",\"content\":\"I will read it first.\"," ++
            "\"reasoning_content\":\"opaque continuation\",\"tool_calls\":[{\"id\":\"call_1\"",
    ) != null);
    // And exactly one assistant message, so the split half is gone rather than
    // duplicated.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, body, "\"role\":\"assistant\""),
    );
}

test "a local preamble stays its own message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .model_text = "I will read it first." });
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
    }};
    try transcript.append(ta, .{ .assistant_tool_use = &calls });

    const body = try buildRequestBody(ta, .{
        .provider = .local,
        .model = "local-model",
        .max_tokens = 128,
        .system_prompt = "be exact",
        .tools_json = "[]",
    }, &transcript, null);

    // The rejoin is DeepSeek's requirement, and folding here would change the
    // local corpus's wire bytes for nothing.
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"role\":\"assistant\",\"content\":\"I will read it first.\"}",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":null,\"tool_calls\":") != null);
}

test "a DeepSeek answer with no tool call after it stays its own message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .user_text = "is it pure?" });
    try transcript.append(ta, .{ .model_text = "Yes, it is pure." });

    const body = try buildRequestBody(ta, .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .max_tokens = 128,
        .system_prompt = "be exact",
        .tools_json = "[]",
    }, &transcript, null);

    // Nothing to rejoin it to, and no reasoning to pass back: final-answer
    // reasoning is scrubbed before the transcript ever sees it.
    try testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"role\":\"assistant\",\"content\":\"Yes, it is pure.\"}",
    ) != null);
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

test "local and DeepSeek summarization bodies are standalone and tool-free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(ta);
    try transcript.append(ta, .{ .user_text = "summary payload" });

    inline for (.{ model_request.Provider.local, model_request.Provider.deepseek }) |provider| {
        var snapshot = try model_request.createSnapshot(ta, .{
            .config = .{
                .provider = provider,
                .model = if (provider == .local) "local-model" else "deepseek-model",
                .max_output_tokens = 4096,
                .stream = false,
                .system_prompt = "summary system",
                .purpose = .summarization,
                .cache_policy = .disabled,
            },
            .transcript = &transcript,
        });
        defer snapshot.deinit(ta);
        const body = try buildRequestBodyFromSnapshot(ta, &snapshot);
        try testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
        try testing.expect(std.mem.indexOf(u8, body, "summary payload") != null);
        if (provider == .deepseek) {
            try testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"disabled\"}") != null);
        } else {
            try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
        }
        try testing.expectEqual(model_request.Purpose.summarization, snapshot.config.purpose);
    }
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
