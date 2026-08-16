//! Streaming HTTPS wire layer for the OpenAI Responses API.
//!
//! Mirrors the shape of `providers/anthropic/client.zig`: post a request,
//! parse the streamed SSE body, fold the events into a `turn.AssistantReply`
//! identical to the Anthropic one. The loop sees one provider-shaped
//! result regardless of which backend produced it.
//!
//! The earlier non-streaming Chat Completions implementation lived here. The
//! Responses API streaming endpoint keeps the OpenAI path aligned with
//! Anthropic's "watch tool calls assemble in real time" experience.

const std = @import("std");
const TextBuffer = @import("../../text_buffer.zig").TextBuffer;
const builtin = @import("builtin");
const loop = @import("../../loop.zig");
const turn = @import("../../turn.zig");
const transcript_mod = @import("../../transcript.zig");
const registry_mod = @import("../../registry/registry.zig");
const sse_parser = @import("sse_parser.zig");
const response_assembler = @import("response_assembler.zig");
const http_errors = @import("../http_errors.zig");
const propose_change_set = @import("../anthropic/propose_change_set.zig");
const tool_catalog = @import("../tool_catalog.zig");
const model_request = @import("../model_request.zig");
const context_budget = @import("../../context_budget.zig");
const capture_sink = @import("../capture_sink.zig");
const json_writer = @import("../json_writer.zig");
const model_registry = @import("../models.zig");

pub const default_base_url = "https://api.openai.com/v1/responses";
pub const default_model = model_registry.defaultForProvider(.openai).id;
pub const default_max_tokens = model_registry.defaultForProvider(.openai).request_policy.max_output_tokens;
const max_response_body_bytes: usize = 16 * 1024 * 1024;

pub const Config = struct {
    api_key: []const u8,
    system_prompt: []const u8,
    model: []const u8 = default_model,
    max_tokens: u32 = default_max_tokens,
    tools_json: ?[]const u8 = null,
    reserve_tokens: u64 = context_budget.default_reserve_tokens,
    base_url: []const u8 = default_base_url,
    purpose: model_request.Purpose = .normal,
    cache_policy: model_request.CachePolicy = .enabled,
    request_timeout_ms: ?u64 = null,
};

pub const ClientError = error{
    HttpNotOk,
    UnexpectedResponseShape,
};

pub const Client = struct {
    config: Config,
    /// Borrowed for this client's lifetime. null preserves ordinary live use.
    capture: ?*capture_sink.CaptureSink = null,

    pub fn init(config: Config) Client {
        return .{ .config = config };
    }

    pub fn initWithCapture(config: Config, capture: *capture_sink.CaptureSink) Client {
        return .{ .config = config, .capture = capture };
    }

    pub fn asModelClient(self: *Client) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *Client = @ptrCast(@alignCast(ctx));
        return self.sendTurn(arena, transcript, extra_user_text);
    }

    pub fn sendTurn(
        self: *Client,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !loop.ModelCallResult {
        return self.sendTurnWithPost(arena, transcript, extra_user_text, post);
    }

    fn sendTurnWithPost(
        self: *Client,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
        post_fn: anytype,
    ) !loop.ModelCallResult {
        var snapshot = try createRequestSnapshot(arena, self.config, transcript, extra_user_text);
        defer snapshot.deinit(arena);

        var body = try buildRequestBodyFromSnapshot(arena, &snapshot);
        try snapshot.completePreparation(body);
        if (try snapshot.clampOutputToRemainingContext()) {
            body = try buildRequestBodyFromSnapshot(arena, &snapshot);
            try snapshot.completePreparation(body);
        }
        try snapshot.requireHardAdmission();
        snapshot.wire_request_sha256 = model_request.Sha256Hex.fromRawBytes(body);
        const response_body = try post_fn(arena, self.config, body);
        if (self.capture) |sink| try sink.record(&snapshot, response_body);

        return assembleTurn(arena, response_body);
    }
};

fn assembleTurn(arena: std.mem.Allocator, response_body: []const u8) !loop.ModelCallResult {
    const event_list = try sse_parser.parseAll(arena, response_body);
    const outcome = try response_assembler.assemble(arena, event_list);
    const reply = try propose_change_set.maybeRemap(arena, outcome.reply, outcome.stop_reason);
    return .{ .reply = reply, .usage = outcome.usage, .stop_reason = outcome.stop_reason };
}

// -----------------------------------------------------------------------
// Request body
//
// The Responses API uses a flatter, "input + tools" shape compared to the
// Chat Completions one we used before. The system prompt is hoisted into a
// top-level `instructions` field; everything else (user, assistant, tool
// calls, tool results) becomes an entry in the `input` array.
// -----------------------------------------------------------------------

pub fn buildRequestBody(
    arena: std.mem.Allocator,
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) ![]u8 {
    var snapshot = try createRequestSnapshot(arena, config, transcript, extra_user_text);
    defer snapshot.deinit(arena);
    return buildRequestBodyFromSnapshot(arena, &snapshot);
}

fn createRequestSnapshot(
    arena: std.mem.Allocator,
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) !model_request.ModelRequestSnapshot {
    return model_request.createSnapshot(arena, .{
        .config = .{
            .provider = .openai,
            .model = config.model,
            .max_output_tokens = config.max_tokens,
            .system_prompt = config.system_prompt,
            .tools_json = config.tools_json,
            .reserve_tokens = config.reserve_tokens,
            .purpose = config.purpose,
            .cache_policy = config.cache_policy,
        },
        .transcript = transcript,
        .extra_user_text = extra_user_text,
    });
}

pub fn buildRequestBodyFromSnapshot(
    arena: std.mem.Allocator,
    snapshot: *const model_request.ModelRequestSnapshot,
) ![]u8 {
    if (snapshot.config.provider != .openai) return error.InvalidProvider;
    var buf = TextBuffer.init(arena);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeByte('{');
    try w.writeAll("\"model\":");
    try writeJsonString(w, snapshot.config.model);
    try w.print(",\"max_output_tokens\":{d}", .{snapshot.config.max_output_tokens});
    try w.writeAll(",\"stream\":");
    try w.writeAll(if (snapshot.config.stream) "true" else "false");
    try w.writeAll(",\"instructions\":");
    try writeJsonString(w, snapshot.config.system_prompt);

    try w.writeAll(",\"input\":[");
    var first_entry = true;
    for (snapshot.items) |item| {
        try writeSnapshotItem(w, item, &first_entry);
    }
    if (snapshot.extra_user_text) |body| {
        if (!first_entry) try w.writeByte(',');
        first_entry = false;
        try writeUserMessage(w, body);
    }
    try w.writeByte(']');

    if (snapshot.config.tools_json) |tools| {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools);
    }

    try w.writeByte('}');
    return try buf.toOwnedSlice();
}

fn writeUserMessage(w: anytype, body: []const u8) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
    try writeJsonString(w, body);
    try w.writeAll("}]}");
}

fn writeAssistantText(w: anytype, body: []const u8) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try writeJsonString(w, body);
    try w.writeAll("}]}");
}

fn writeSnapshotItem(
    w: anytype,
    item: model_request.Item,
    first_entry: *bool,
) !void {
    switch (item) {
        .user_text, .system_note => |body| {
            // System notes are surfaced as additional user-role context
            // blocks; the top-level `instructions` field carries the
            // persona prompt exclusively.
            if (!first_entry.*) try w.writeByte(',');
            first_entry.* = false;
            try writeUserMessage(w, body);
        },
        .compaction_summary => |body| {
            if (!first_entry.*) try w.writeByte(',');
            first_entry.* = false;
            try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonString(w, model_request.compaction_summary_marker);
            try w.writeAll("},{\"type\":\"input_text\",\"text\":");
            try writeJsonString(w, body);
            try w.writeAll("}]}");
        },
        .model_text => |body| {
            if (!first_entry.*) try w.writeByte(',');
            first_entry.* = false;
            try writeAssistantText(w, body);
        },
        .tool_use => |call| {
            // The Responses API expects each function call to be its own
            // top-level input item (no wrapping assistant message).
            if (!first_entry.*) try w.writeByte(',');
            first_entry.* = false;
            try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
            try writeJsonString(w, call.id);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, call.name);
            try w.writeAll(",\"arguments\":");
            try writeJsonString(w, call.args_json);
            try w.writeByte('}');
        },
        .tool_result => |result| {
            if (!first_entry.*) try w.writeByte(',');
            first_entry.* = false;
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try writeJsonString(w, result.tool_use_id);
            try w.writeAll(",\"output\":");
            try writeJsonString(w, result.llm_text);
            try w.writeByte('}');
        },
    }
}

// -----------------------------------------------------------------------
// Tools schema
//
// The Responses API expects each tool to be `{type, name, description,
// parameters}` flat (no nested `function` wrapper that Chat Completions
// used). The signature is unchanged so call sites in agent.zig keep
// working without modification.
// -----------------------------------------------------------------------

pub fn writeToolsArray(writer: anytype, registry: *const registry_mod.Registry) !void {
    var tools = tool_catalog.iterator(registry);
    try writer.writeByte('[');
    var index: usize = 0;
    while (tools.next()) |tool| {
        if (index > 0) try writer.writeByte(',');
        index += 1;
        try writer.writeAll("{\"type\":\"function\",\"name\":");
        try writeJsonString(writer, tool.name);
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, tool.description);
        try writer.writeAll(",\"parameters\":");
        try writer.writeAll(tool.input_schema);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

// -----------------------------------------------------------------------
// HTTPS POST (mirrors the anthropic client's pattern)
// -----------------------------------------------------------------------

fn post(arena: std.mem.Allocator, config: Config, body: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(config.base_url);

    var io_backend = std.Io.Threaded.init(arena, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();

    const now = std.Io.Clock.real.now(io);
    client.ca_bundle.rescan(arena, io, now) catch return error.CertificateBundleLoadFailure;
    client.now = now;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedProtocol;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);
    const connection = try http_errors.connectWithin(
        &client,
        host,
        uri.port,
        protocol,
        config.request_timeout_ms,
    );

    const auth_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{config.api_key});
    const extra_headers = [_]std.http.Header{
        .{ .name = "authorization", .value = auth_header },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
    };

    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        // Ask for an identity (uncompressed) body; std.http.Client otherwise
        // advertises gzip/deflate itself. We also decode transparently below so
        // a proxy that compresses anyway is still handled.
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &extra_headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var req_body = try req.sendBodyUnflushed(&.{});
    try req_body.writer.writeAll(body);
    try req_body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    const status = response.head.status;

    // Decode Content-Encoding/Transfer-Encoding transparently: a raw gzip/chunked
    // body fed to the SSE parser splits on stray newline bytes and surfaces as a
    // bogus parse error. readerDecompressing handles gzip/deflate/zstd; identity
    // passes straight through.
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    const response_body = try http_errors.readBody(reader, arena, max_response_body_bytes);

    if (status != .ok) {
        // The error body is a small JSON payload carrying the real reason (bad
        // key, exceeded quota, rate limit). Classify first: when the typed error
        // carries one-line remediation the catch site prints that actionable
        // message, so dumping the raw body here (ahead of the catch site) would
        // only bury it. Keep the raw `err` line solely for the unclassified
        // `HttpNotOk` fallthrough, where the body is the user's only signal.
        const err = http_errors.classify(@intFromEnum(status), response_body);
        if (!builtin.is_test and loop.providerErrorRemediation(err) == null) {
            std.log.err("openai API: HTTP {d} {s}: {s}", .{
                @intFromEnum(status),
                status.phrase() orelse "",
                response_body,
            });
        }
        return err;
    }

    return response_body;
}

const writeJsonString = json_writer.writeString;

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

const propose_change_set_sse =
    \\event: response.created
    \\data: {"type":"response.created","response":{"id":"resp_edit","status":"in_progress"}}
    \\
    \\event: response.output_item.added
    \\data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_edit","type":"function_call","call_id":"call_edit","name":"propose_change_set","arguments":""}}
    \\
    \\event: response.function_call_arguments.delta
    \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"changes\":[{\"file\":\"handler.ts\",\"content\":\"function handler() {}\"}]}"}
    \\
    \\event: response.output_item.done
    \\data: {"type":"response.output_item.done","output_index":0,"item":{"id":"fc_edit","type":"function_call","call_id":"call_edit","name":"propose_change_set","arguments":"{\"changes\":[{\"file\":\"handler.ts\",\"content\":\"function handler() {}\"}]}"}}
    \\
    \\event: response.completed
    \\data: {"type":"response.completed","response":{"id":"resp_edit","status":"completed","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}}
    \\
    \\data: [DONE]
;

test "OpenAI response pipeline remaps propose_change_set into a change set reply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try assembleTurn(arena.allocator(), propose_change_set_sse);
    switch (result.reply.response) {
        .change_set => |edit| {
            try testing.expectEqualStrings("handler.ts", edit.file);
            try testing.expectEqualStrings("function handler() {}", edit.content);
        },
        else => return error.TestFailed,
    }
}

const CaptureProbe = struct {
    calls: usize = 0,
    fail: bool = false,

    fn record(
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) !void {
        const self: *CaptureProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        try testing.expectEqual(@as(usize, 0), call_index);
        try testing.expectEqual(model_request.Provider.openai, snapshot.config.provider);
        try testing.expectEqualStrings("capture-model", snapshot.config.model);
        try testing.expectEqualStrings("capture-system", snapshot.config.system_prompt);
        try testing.expectEqualStrings("retry-context", snapshot.extra_user_text.?);
        try testing.expectEqual(@as(usize, 1), snapshot.items.len);
        try testing.expect(snapshot.wire_request_sha256 != null);
        try testing.expectEqualStrings("capture-user", snapshot.items[0].user_text);
        try testing.expectEqualStrings(propose_change_set_sse, raw_response);
        if (self.fail) return error.InjectedCaptureFailure;
    }
};

fn captureTestPost(_: std.mem.Allocator, _: Config, _: []const u8) ![]const u8 {
    return propose_change_set_sse;
}

test "OpenAI client records the canonical request and raw response before parsing" {
    var probe: CaptureProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = CaptureProbe.record,
    };
    var client = Client.initWithCapture(.{
        .api_key = "not-captured",
        .system_prompt = "capture-system",
        .model = "capture-model",
    }, &sink);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "capture-user" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        "retry-context",
        captureTestPost,
    );

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 1), sink.next_call_index);
}

test "OpenAI client propagates capture failure without advancing the cursor" {
    var probe: CaptureProbe = .{ .fail = true };
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = CaptureProbe.record,
    };
    var client = Client.initWithCapture(.{
        .api_key = "not-captured",
        .system_prompt = "capture-system",
        .model = "capture-model",
    }, &sink);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "capture-user" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InjectedCaptureFailure, client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        "retry-context",
        captureTestPost,
    ));

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 0), sink.next_call_index);
}

test "buildRequestBody: first turn carries instructions + one user input item and no tools" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "add a GET route" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body = try buildRequestBody(arena.allocator(), .{
        .api_key = "test-fixture-key",
        .system_prompt = "you are a zts expert",
    }, &transcript, null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings(default_model, root.get("model").?.string);
    try testing.expect(root.get("tools") == null);
    try testing.expect(root.get("stream").?.bool);
    try testing.expectEqualStrings("you are a zts expert", root.get("instructions").?.string);

    const input = root.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 1), input.len);
    try testing.expectEqualStrings("user", input[0].object.get("role").?.string);
    const content = input[0].object.get("content").?.array.items;
    try testing.expectEqualStrings("input_text", content[0].object.get("type").?.string);
    try testing.expectEqualStrings("add a GET route", content[0].object.get("text").?.string);
}

test "summarization request is standalone and tool-free" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "summary payload" });
    var snapshot = try model_request.createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .openai,
            .model = "gpt-4o-mini",
            .max_output_tokens = 4096,
            .system_prompt = "summary system",
            .purpose = .summarization,
            .cache_policy = .disabled,
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);
    const body = try buildRequestBodyFromSnapshot(testing.allocator, &snapshot);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "summary payload") != null);
    try testing.expectEqual(model_request.CachePolicy.disabled, snapshot.config.cache_policy);
}

test "buildRequestBody: tool-use and tool-result entries serialize as Responses-API items" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "call_1", .name = "zts_expert_meta", .args_json = "{}" },
    };
    try transcript.append(testing.allocator, .{ .user_text = "inspect" });
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "zts_expert_meta",
        .ok = true,
        .llm_text = "{\"version\":\"x\"}",
    } });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{
        .api_key = "k",
        .system_prompt = "s",
    }, &transcript, null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("input").?.array.items;
    // [user, function_call, function_call_output]
    try testing.expectEqual(@as(usize, 3), items.len);

    try testing.expectEqualStrings("user", items[0].object.get("role").?.string);

    try testing.expectEqualStrings("function_call", items[1].object.get("type").?.string);
    try testing.expectEqualStrings("call_1", items[1].object.get("call_id").?.string);
    try testing.expectEqualStrings("zts_expert_meta", items[1].object.get("name").?.string);
    try testing.expectEqualStrings("{}", items[1].object.get("arguments").?.string);

    try testing.expectEqualStrings("function_call_output", items[2].object.get("type").?.string);
    try testing.expectEqualStrings("call_1", items[2].object.get("call_id").?.string);
    try testing.expectEqualStrings("{\"version\":\"x\"}", items[2].object.get("output").?.string);
}

test "buildRequestBody: multiple tool calls in one assistant turn unroll into separate items" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    const calls = [_]turn.ToolCall{
        .{ .id = "call_a", .name = "tool_a", .args_json = "{}" },
        .{ .id = "call_b", .name = "tool_b", .args_json = "{\"x\":1}" },
    };
    try transcript.append(testing.allocator, .{ .user_text = "u" });
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{
        .api_key = "k",
        .system_prompt = "s",
    }, &transcript, null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("input").?.array.items;
    // [user, function_call_a, function_call_b]
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("call_a", items[1].object.get("call_id").?.string);
    try testing.expectEqualStrings("call_b", items[2].object.get("call_id").?.string);
}

test "writeToolsArray: wraps registry entries in flat Responses-API tool shape" {
    const echo_tool: registry_mod.ToolDef = .{
        .name = "echo",
        .label = "Echo",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .description = "Concatenate args with spaces",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .decode_json = registry_mod.helpers.decodeNoArgs,
        .execute = stubExecute,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, echo_tool);

    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try writeToolsArray(buf.writer(), &registry);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("function", items[0].object.get("type").?.string);
    try testing.expectEqualStrings(propose_change_set.tool_name, items[0].object.get("name").?.string);
    try testing.expectEqualStrings("echo", items[1].object.get("name").?.string);
    try testing.expectEqualStrings("Concatenate args with spaces", items[1].object.get("description").?.string);
    // The schema is inlined as-is.
    try testing.expect(items[1].object.get("parameters").? == .object);
}

test "writeToolsArray: omits registry workspace writers" {
    const writer_tool: registry_mod.ToolDef = .{
        .name = "writer",
        .label = "Writer",
        .description = "Test writer",
        .effect = .write_workspace,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .decode_json = registry_mod.helpers.decodeNoArgs,
        .execute = stubExecute,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, writer_tool);

    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try writeToolsArray(buf.writer(), &registry);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try testing.expectEqualStrings(propose_change_set.tool_name, parsed.value.array.items[0].object.get("name").?.string);
}

fn stubExecute(_: std.mem.Allocator, _: []const []const u8) anyerror!registry_mod.ToolResult {
    return error.NotImplemented;
}

test "Client.asModelClient exposes the loop-facing request signature" {
    var client = Client.init(.{ .api_key = "k", .system_prompt = "s" });
    const mc = client.asModelClient();
    try testing.expect(mc.context == @as(*anyopaque, @ptrCast(&client)));
    try testing.expect(@intFromPtr(mc.request_fn) != 0);
}
