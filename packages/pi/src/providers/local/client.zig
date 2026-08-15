//! Non-streaming Chat Completions adapter for a developer-managed MLX server.
//!
//! The endpoint is loopback-only. The adapter never starts the server and never
//! falls back to another provider.

const std = @import("std");
const zts = @import("zts");
const TextBuffer = @import("../../text_buffer.zig").TextBuffer;
const loop = @import("../../loop.zig");
const turn = @import("../../turn.zig");
const transcript_mod = @import("../../transcript.zig");
const registry_mod = @import("../../registry/registry.zig");
const apply_edit = @import("../anthropic/apply_edit.zig");
const http_errors = @import("../http_errors.zig");
const model_request = @import("../model_request.zig");
const model_registry = @import("../models.zig");
const capture_sink = @import("../capture_sink.zig");
const json_writer = @import("../json_writer.zig");
const chat_completions = @import("../chat_completions.zig");

pub const default_base_url = "http://127.0.0.1:8080";
pub const default_model = model_registry.defaultForProvider(.local).id;
pub const default_max_tokens = model_registry.defaultForProvider(.local).request_policy.max_output_tokens;

pub fn effectiveBaseUrl(raw: ?[]const u8) []const u8 {
    const value = raw orelse return default_base_url;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) default_base_url else trimmed;
}

const chat_completions_path = "/v1/chat/completions";
const max_response_body_bytes: usize = 16 * 1024 * 1024;
const max_tool_envelope_bytes: usize = 1024 * 1024;
const max_tool_args_bytes: usize = 256 * 1024;
const max_tool_calls: usize = 16;
const max_tool_name_bytes: usize = 128;
const max_value_depth: usize = 16;
const max_response_json_depth: usize = 64;
const response_head_timeout_ms: i32 = 15 * 60 * 1000;
const tool_call_start = "<|tool_call_start|>";
const tool_call_end = "<|tool_call_end|>";

pub const Config = struct {
    system_prompt: []const u8,
    model: []const u8 = default_model,
    max_tokens: u32 = default_max_tokens,
    tools_json: ?[]const u8 = null,
    base_url: []const u8 = default_base_url,
    purpose: model_request.Purpose = .normal,
    cache_policy: model_request.CachePolicy = .enabled,
};

pub const ClientError = error{
    EmptyResponse,
    InvalidMlxBaseUrl,
    InvalidResponseJson,
    LocalHealthNotOk,
    LocalModelUnavailable,
    LocalServerUnavailable,
    MalformedToolCall,
    MalformedToolEnvelope,
    OutputTruncated,
    ResponseTooLarge,
    TooManyToolCalls,
    UnexpectedResponseShape,
};

pub const Client = struct {
    config: Config,
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
        try validateBaseUrl(self.config.base_url);
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = .{
                .provider = .local,
                .model = self.config.model,
                .max_output_tokens = self.config.max_tokens,
                .stream = false,
                .system_prompt = self.config.system_prompt,
                .tools_json = self.config.tools_json,
                .purpose = self.config.purpose,
                .cache_policy = self.config.cache_policy,
            },
            .transcript = transcript,
            .extra_user_text = extra_user_text,
        });
        defer snapshot.deinit(arena);
        var body = try chat_completions.buildRequestBodyFromSnapshot(arena, &snapshot);
        try snapshot.completePreparation(body);
        if (try snapshot.clampOutputToRemainingContext()) {
            body = try chat_completions.buildRequestBodyFromSnapshot(arena, &snapshot);
            try snapshot.completePreparation(body);
        }
        try snapshot.requireHardAdmission();
        const request_digest = sha256(body);
        snapshot.wire_request_sha256 = .{ .bytes = std.fmt.bytesToHex(request_digest, .lower) };
        const diagnostics_enabled = if (self.capture) |sink| sink.diagnostics_fn != null else false;
        const started_ns = if (diagnostics_enabled) monotonicNowNs() else null;
        const raw_response = post_fn(arena, self.config, body) catch |err| {
            if (diagnostics_enabled) {
                var inspection: ResponseInspection = .{};
                inspection.addWarning(.transport_failed);
                self.recordResponseDiagnostics(
                    &inspection,
                    elapsedMs(started_ns),
                    err,
                );
            }
            return err;
        };
        const latency_ms = elapsedMs(started_ns);
        var inspection: ResponseInspection = .{};
        const response = parseSanitizedResponseWithInspection(
            arena,
            raw_response,
            if (diagnostics_enabled) &inspection else null,
        ) catch |err| {
            if (diagnostics_enabled) {
                inspection.addWarning(.sanitizer_rejected_response);
                self.recordResponseDiagnostics(
                    &inspection,
                    latency_ms,
                    err,
                );
            }
            return err;
        };
        if (self.capture) |sink| {
            sink.record(&snapshot, response.bytes) catch |err| {
                if (diagnostics_enabled) {
                    inspection.addWarning(.capture_rejected_response);
                    self.recordResponseDiagnostics(
                        &inspection,
                        latency_ms,
                        err,
                    );
                }
                return err;
            };
        }
        const result = decodeResponseValue(
            arena,
            request_digest,
            response.bytes,
            response.value,
        ) catch |err| {
            if (diagnostics_enabled) {
                inspection.addWarning(.decoder_rejected_response);
                self.recordResponseDiagnostics(
                    &inspection,
                    latency_ms,
                    err,
                );
            }
            return err;
        };
        if (diagnostics_enabled) {
            self.recordResponseDiagnostics(
                &inspection,
                latency_ms,
                null,
            );
        }
        return result;
    }

    fn recordResponseDiagnostics(
        self: *Client,
        inspection: *const ResponseInspection,
        latency_ms: ?u64,
        failure: ?anyerror,
    ) void {
        const sink = self.capture orelse return;
        sink.recordDiagnostics(.{
            .provider = .local,
            .model = self.config.model,
        }, .{
            .latency_ms = latency_ms,
            .finish_reason = inspection.finish_reason,
            .completion_tokens = inspection.completion_tokens,
            .field_presence = inspection.field_presence,
            .parser_warnings = inspection.warningSlice(),
            .failure = failure,
        });
    }
};

pub fn validateBaseUrl(url: []const u8) ClientError!void {
    const uri = std.Uri.parse(url) catch return ClientError.InvalidMlxBaseUrl;
    if (!std.mem.eql(u8, uri.scheme, "http")) return ClientError.InvalidMlxBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return ClientError.InvalidMlxBaseUrl;
    }
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ClientError.InvalidMlxBaseUrl;
    const is_ipv6_loopback = std.mem.eql(u8, host.bytes, "::1") or
        std.mem.eql(u8, host.bytes, "[::1]");
    if (!std.ascii.eqlIgnoreCase(host.bytes, "localhost") and
        !std.mem.eql(u8, host.bytes, "127.0.0.1") and
        !is_ipv6_loopback)
    {
        return ClientError.InvalidMlxBaseUrl;
    }
    var path_buf: [1024]u8 = undefined;
    const path = uri.path.toRaw(&path_buf) catch return ClientError.InvalidMlxBaseUrl;
    if (path.len > 0 and !std.mem.eql(u8, path, "/")) return ClientError.InvalidMlxBaseUrl;
}

fn endpointUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    try validateBaseUrl(base_url);
    return std.fmt.allocPrint(arena, "{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        chat_completions_path,
    });
}

/// Verify that the developer-managed server is healthy and exposes the exact
/// configured model before any session or workspace state is created.
pub fn checkReadiness(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    model: []const u8,
) !void {
    var context: u8 = 0;
    return checkReadinessWithGet(allocator, base_url, model, &context, getReadinessFn);
}

fn checkReadinessWithGet(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    model: []const u8,
    get_context: *anyopaque,
    get_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, bool) anyerror!ReadinessResponse,
) !void {
    try validateBaseUrl(base_url);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const root = std.mem.trimEnd(u8, base_url, "/");
    const health_url = try std.fmt.allocPrint(ta, "{s}/health", .{root});
    const models_url = try std.fmt.allocPrint(ta, "{s}/v1/models", .{root});

    const health = try get_fn(get_context, ta, health_url, false);
    if (health.status != .ok) return ClientError.LocalHealthNotOk;
    const models = try get_fn(get_context, ta, models_url, true);
    if (models.status != .ok) return ClientError.LocalModelUnavailable;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ta, models.body, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_response_body_bytes,
    }) catch return ClientError.InvalidResponseJson;
    if (parsed != .object) return ClientError.InvalidResponseJson;
    const data = parsed.object.get("data") orelse return ClientError.InvalidResponseJson;
    if (data != .array) return ClientError.InvalidResponseJson;
    for (data.array.items) |entry| {
        if (entry != .object) return ClientError.InvalidResponseJson;
        const id = entry.object.get("id") orelse return ClientError.InvalidResponseJson;
        if (id != .string) return ClientError.InvalidResponseJson;
        if (std.mem.eql(u8, id.string, model)) return;
    }
    return ClientError.LocalModelUnavailable;
}

const ReadinessResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

fn getReadiness(arena: std.mem.Allocator, url: []const u8, read_body: bool) !ReadinessResponse {
    const uri = std.Uri.parse(url) catch return ClientError.InvalidMlxBaseUrl;
    var io_backend = std.Io.Threaded.init(arena, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return ClientError.InvalidMlxBaseUrl;
    if (protocol != .plain) return ClientError.InvalidMlxBaseUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ClientError.InvalidMlxBaseUrl;
    const connection = http_errors.connect(&client, host, uri.port, protocol) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ClientError.LocalServerUnavailable,
    };
    var request = client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        .headers = .{ .accept_encoding = .omit },
    }) catch return ClientError.LocalServerUnavailable;
    defer request.deinit();
    request.sendBodiless() catch return ClientError.LocalServerUnavailable;
    try waitForResponseHead(connection.stream_reader.stream.socket.handle);
    var response = request.receiveHead(&.{}) catch return ClientError.LocalServerUnavailable;
    if (!read_body) return .{ .status = response.head.status, .body = "" };
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    const body = http_errors.readBody(reader, arena, max_response_body_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ClientError.LocalServerUnavailable,
    };
    return .{ .status = response.head.status, .body = body };
}

fn getReadinessFn(
    _: *anyopaque,
    arena: std.mem.Allocator,
    url: []const u8,
    read_body: bool,
) !ReadinessResponse {
    return getReadiness(arena, url, read_body);
}

/// The wire body, with the loopback-only endpoint policy checked first so a
/// misconfigured base URL fails before any bytes are built. The body itself is
/// the shared Chat Completions shape, identical to the one DeepSeek receives.
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) ![]u8 {
    try validateBaseUrl(config.base_url);
    return chat_completions.buildRequestBody(arena, .{
        .provider = .local,
        .model = config.model,
        .max_tokens = config.max_tokens,
        .system_prompt = config.system_prompt,
        .tools_json = config.tools_json,
    }, transcript, extra_user_text);
}

pub fn writeToolsArray(writer: anytype, registry: *const registry_mod.Registry) !void {
    return chat_completions.writeToolsArray(writer, registry);
}

pub fn decodeResponse(
    arena: std.mem.Allocator,
    request_body: []const u8,
    response_body: []const u8,
) !loop.ModelCallResult {
    const response = try parseSanitizedResponse(arena, response_body);
    return decodeResponseValue(arena, sha256(request_body), response.bytes, response.value);
}

pub fn decodeResponseFromRequestDigest(
    arena: std.mem.Allocator,
    request_sha256: []const u8,
    response_body: []const u8,
) !loop.ModelCallResult {
    var digest: [32]u8 = undefined;
    if (request_sha256.len != 64) return ClientError.InvalidResponseJson;
    _ = std.fmt.hexToBytes(&digest, request_sha256) catch return ClientError.InvalidResponseJson;
    const response = try parseSanitizedResponse(arena, response_body);
    return decodeResponseValue(arena, digest, response.bytes, response.value);
}

pub fn sanitizeResponse(arena: std.mem.Allocator, response_body: []const u8) ![]u8 {
    return (try parseSanitizedResponse(arena, response_body)).bytes;
}

const SanitizedResponse = struct {
    value: std.json.Value,
    bytes: []u8,
};

const max_parser_warnings = std.meta.fields(capture_sink.ParserWarning).len;

const ResponseInspection = struct {
    finish_reason: ?capture_sink.FinishReason = null,
    completion_tokens: ?u64 = null,
    field_presence: capture_sink.ResponseFieldPresence = .{},
    warnings: [max_parser_warnings]capture_sink.ParserWarning = undefined,
    warning_count: usize = 0,

    fn addWarning(self: *ResponseInspection, warning: capture_sink.ParserWarning) void {
        for (self.warnings[0..self.warning_count]) |existing| {
            if (existing == warning) return;
        }
        if (self.warning_count == self.warnings.len) return;
        self.warnings[self.warning_count] = warning;
        self.warning_count += 1;
    }

    fn warningSlice(self: *const ResponseInspection) []const capture_sink.ParserWarning {
        return self.warnings[0..self.warning_count];
    }
};

fn inspectResponseValue(inspection: *ResponseInspection, root: std.json.Value) void {
    if (root != .object) {
        inspection.addWarning(.root_not_object);
        return;
    }

    inspectUsage(inspection, root.object.get("usage"));

    const choices = root.object.get("choices") orelse {
        inspection.addWarning(.choices_missing);
        return;
    };
    inspection.field_presence.choices = true;
    if (choices != .array) {
        inspection.addWarning(.choices_not_array);
        return;
    }
    if (choices.array.items.len == 0) {
        inspection.addWarning(.choices_empty);
        return;
    }

    inspection.field_presence.first_choice = true;
    const choice = choices.array.items[0];
    if (choice != .object) {
        inspection.addWarning(.first_choice_not_object);
        return;
    }
    if (choice.object.get("finish_reason")) |finish_reason| {
        inspection.field_presence.finish_reason = true;
        switch (finish_reason) {
            .string => |value| {
                if (std.meta.stringToEnum(capture_sink.FinishReason, value)) |known| {
                    inspection.finish_reason = known;
                } else {
                    inspection.addWarning(.finish_reason_unknown);
                }
            },
            .null => inspection.addWarning(.finish_reason_null),
            else => inspection.addWarning(.finish_reason_invalid),
        }
    }

    const message = choice.object.get("message") orelse {
        inspection.addWarning(.message_missing);
        inspection.addWarning(.assistant_output_missing);
        return;
    };
    inspection.field_presence.message = true;
    if (message != .object) {
        inspection.addWarning(.message_not_object);
        inspection.addWarning(.assistant_output_missing);
        return;
    }

    var has_output = false;
    if (message.object.get("content")) |content| {
        inspection.field_presence.content = true;
        switch (content) {
            .string => |value| {
                if (value.len == 0) {
                    inspection.addWarning(.content_empty);
                } else {
                    has_output = true;
                }
            },
            .null => inspection.addWarning(.content_null),
            else => inspection.addWarning(.content_invalid),
        }
    }
    inspection.field_presence.reasoning = message.object.get("reasoning") != null;
    if (message.object.get("tool_calls")) |tool_calls| {
        inspection.field_presence.tool_calls = true;
        if (tool_calls != .array) {
            inspection.addWarning(.tool_calls_invalid);
        } else if (tool_calls.array.items.len == 0) {
            inspection.addWarning(.tool_calls_empty);
        } else {
            has_output = true;
        }
    }
    if (!has_output) inspection.addWarning(.assistant_output_missing);
}

fn inspectUsage(
    inspection: *ResponseInspection,
    maybe_usage: ?std.json.Value,
) void {
    const usage = maybe_usage orelse {
        inspection.addWarning(.usage_missing);
        inspection.addWarning(.completion_tokens_missing);
        return;
    };
    inspection.field_presence.usage = true;
    if (usage == .null) {
        inspection.addWarning(.completion_tokens_missing);
        return;
    }
    if (usage != .object) {
        inspection.addWarning(.usage_invalid);
        inspection.addWarning(.completion_tokens_missing);
        return;
    }
    const completion_tokens = usage.object.get("completion_tokens") orelse {
        inspection.addWarning(.completion_tokens_missing);
        return;
    };
    inspection.field_presence.completion_tokens = true;
    if (completion_tokens != .integer or completion_tokens.integer < 0) {
        inspection.addWarning(.completion_tokens_invalid);
        return;
    }
    inspection.completion_tokens = @intCast(completion_tokens.integer);
}

fn monotonicNowNs() ?u64 {
    return zts.monotonicNowNs() catch null;
}

fn elapsedMs(started_ns: ?u64) ?u64 {
    const start = started_ns orelse return null;
    const end = monotonicNowNs() orelse return null;
    return (end -| start) / std.time.ns_per_ms;
}

fn parseSanitizedResponse(
    arena: std.mem.Allocator,
    response_body: []const u8,
) !SanitizedResponse {
    return parseSanitizedResponseWithInspection(arena, response_body, null);
}

fn parseSanitizedResponseWithInspection(
    arena: std.mem.Allocator,
    response_body: []const u8,
    inspection: ?*ResponseInspection,
) !SanitizedResponse {
    if (response_body.len > max_response_body_bytes) {
        if (inspection) |value| value.addWarning(.response_too_large);
        return ClientError.ResponseTooLarge;
    }
    validateResponseDepth(arena, response_body) catch |err| {
        if (inspection) |value| value.addWarning(.json_parse_failed);
        return err;
    };
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, response_body, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_response_body_bytes,
    }) catch {
        if (inspection) |value| value.addWarning(.json_parse_failed);
        return ClientError.InvalidResponseJson;
    };
    if (inspection) |value| inspectResponseValue(value, root);
    removeReasoning(&root);
    var out = TextBuffer.init(arena);
    defer out.deinit();
    std.json.Stringify.value(root, .{}, out.writer()) catch return ClientError.InvalidResponseJson;
    return .{ .value = root, .bytes = try out.toOwnedSlice() };
}

fn validateResponseDepth(arena: std.mem.Allocator, response_body: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(arena, response_body);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return ClientError.InvalidResponseJson;
        if (scanner.stackHeight() > max_response_json_depth) return ClientError.InvalidResponseJson;
        if (token == .end_of_document) return;
    }
}

fn removeReasoning(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            _ = object.orderedRemove("reasoning");
            for (object.values()) |*child| removeReasoning(child);
        },
        .array => |*array| for (array.items) |*child| removeReasoning(child),
        else => {},
    }
}

fn decodeResponseValue(
    arena: std.mem.Allocator,
    request_digest: [32]u8,
    response_body: []const u8,
    root: std.json.Value,
) !loop.ModelCallResult {
    if (response_body.len > max_response_body_bytes) return ClientError.ResponseTooLarge;
    if (root != .object) return ClientError.UnexpectedResponseShape;
    const choices_value = root.object.get("choices") orelse return ClientError.UnexpectedResponseShape;
    if (choices_value != .array or choices_value.array.items.len == 0) return ClientError.EmptyResponse;
    const choice = choices_value.array.items[0];
    if (choice != .object) return ClientError.UnexpectedResponseShape;

    const finish_reason = try optionalString(choice.object.get("finish_reason"));
    if (finish_reason) |reason| {
        if (std.mem.eql(u8, reason, "length")) return ClientError.OutputTruncated;
    }
    const message = choice.object.get("message") orelse return ClientError.UnexpectedResponseShape;
    if (message != .object) return ClientError.UnexpectedResponseShape;
    const content = try optionalString(message.object.get("content"));
    const response_digest = sha256(response_body);

    const usage = try decodeUsage(root.object.get("usage"));
    if (message.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value != .array) return ClientError.UnexpectedResponseShape;
        if (tool_calls_value.array.items.len > max_tool_calls) return ClientError.TooManyToolCalls;
        if (tool_calls_value.array.items.len > 0) {
            const calls = try arena.alloc(turn.ToolCall, tool_calls_value.array.items.len);
            for (tool_calls_value.array.items, 0..) |item, index| {
                if (item != .object) return ClientError.MalformedToolCall;
                const function = item.object.get("function") orelse return ClientError.MalformedToolCall;
                if (function != .object) return ClientError.MalformedToolCall;
                const name = try requiredString(function.object.get("name"));
                if (!validToolName(name)) return ClientError.MalformedToolCall;
                const args = try requiredString(function.object.get("arguments"));
                try validateJsonArguments(arena, args);
                calls[index] = .{
                    .id = try stableCallId(arena, request_digest, response_digest, index),
                    .name = name,
                    .args_json = args,
                };
            }
            const has_raw_envelope = if (content) |text| containsToolMarker(text) else false;
            const reply: turn.AssistantReply = .{
                .preamble = if (!has_raw_envelope) nonEmpty(content) else null,
                .response = .{ .tool_calls = calls },
            };
            return .{
                .reply = try apply_edit.maybeRemap(arena, reply, finish_reason),
                .usage = usage,
                .stop_reason = finish_reason,
            };
        }
    }

    const text = content orelse return ClientError.EmptyResponse;
    if (containsToolMarker(text)) {
        const calls = try parseToolEnvelopes(arena, request_digest, response_digest, text);
        const reply: turn.AssistantReply = .{ .response = .{ .tool_calls = calls } };
        return .{
            .reply = try apply_edit.maybeRemap(arena, reply, finish_reason),
            .usage = usage,
            .stop_reason = finish_reason,
        };
    }
    if (text.len == 0) return ClientError.EmptyResponse;
    return .{
        .reply = .{ .response = .{ .final_text = text } },
        .usage = usage,
        .stop_reason = finish_reason,
    };
}

fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .null => null,
        .string => |text| text,
        else => ClientError.UnexpectedResponseShape,
    };
}

fn requiredString(value: ?std.json.Value) ![]const u8 {
    return (try optionalString(value)) orelse ClientError.MalformedToolCall;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn decodeUsage(value: ?std.json.Value) !turn.Usage {
    const present = value orelse return .{};
    if (present == .null) return .{};
    if (present != .object) return ClientError.UnexpectedResponseShape;
    return .{
        .input_tokens = try optionalTokenCount(present.object.get("prompt_tokens")),
        .output_tokens = try optionalTokenCount(present.object.get("completion_tokens")),
    };
}

fn optionalTokenCount(value: ?std.json.Value) !u64 {
    const present = value orelse return 0;
    if (present != .integer or present.integer < 0) return ClientError.UnexpectedResponseShape;
    return @intCast(present.integer);
}

fn validateJsonArguments(arena: std.mem.Allocator, args: []const u8) !void {
    if (args.len > max_tool_args_bytes) return ClientError.MalformedToolCall;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_tool_args_bytes,
    }) catch return ClientError.MalformedToolCall;
    if (value != .object) return ClientError.MalformedToolCall;
    try validateJsonDepth(value, 0);
}

fn validateJsonDepth(value: std.json.Value, depth: usize) !void {
    if (depth > max_value_depth) return ClientError.MalformedToolCall;
    switch (value) {
        .array => |items| for (items.items) |item| try validateJsonDepth(item, depth + 1),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateJsonDepth(entry.value_ptr.*, depth + 1);
        },
        else => {},
    }
}

fn containsToolMarker(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "<|tool_call") != null or
        std.mem.indexOf(u8, text, "tool_call_end|>") != null;
}

fn parseToolEnvelopes(
    arena: std.mem.Allocator,
    request_digest: [32]u8,
    response_digest: [32]u8,
    content: []const u8,
) ![]const turn.ToolCall {
    if (content.len > max_tool_envelope_bytes) return ClientError.MalformedToolEnvelope;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    var calls: std.ArrayListUnmanaged(turn.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            if (call.id.len > 0) arena.free(call.id);
            arena.free(call.args_json);
        }
        calls.deinit(arena);
    }
    var cursor: usize = 0;
    while (cursor < trimmed.len) {
        cursor = skipWhitespace(trimmed, cursor);
        if (!std.mem.startsWith(u8, trimmed[cursor..], tool_call_start)) {
            return ClientError.MalformedToolEnvelope;
        }
        const payload_start = cursor + tool_call_start.len;
        const payload_end = std.mem.indexOfPos(u8, trimmed, payload_start, tool_call_end) orelse
            return ClientError.MalformedToolEnvelope;
        var parser: EnvelopeParser = .{
            .allocator = arena,
            .input = std.mem.trim(u8, trimmed[payload_start..payload_end], " \t\r\n"),
        };
        try parser.parseCalls(&calls);
        if (calls.items.len > max_tool_calls) return ClientError.TooManyToolCalls;
        cursor = skipWhitespace(trimmed, payload_end + tool_call_end.len);
    }
    if (calls.items.len == 0) return ClientError.MalformedToolEnvelope;
    for (calls.items, 0..) |*call, index| {
        call.id = try stableCallId(arena, request_digest, response_digest, index);
    }
    return calls.toOwnedSlice(arena);
}

const EnvelopeParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn parseCalls(self: *EnvelopeParser, calls: *std.ArrayListUnmanaged(turn.ToolCall)) !void {
        try self.expectByte('[');
        self.skipSpace();
        if (self.takeByte(']')) return ClientError.MalformedToolEnvelope;
        while (true) {
            if (calls.items.len >= max_tool_calls) return ClientError.TooManyToolCalls;
            try calls.ensureUnusedCapacity(self.allocator, 1);
            calls.appendAssumeCapacity(try self.parseCall());
            self.skipSpace();
            if (self.takeByte(']')) break;
            try self.expectByte(',');
        }
        self.skipSpace();
        if (self.pos != self.input.len) return ClientError.MalformedToolEnvelope;
    }

    fn parseCall(self: *EnvelopeParser) !turn.ToolCall {
        const name = try self.parseIdentifier();
        if (!validToolName(name)) return ClientError.MalformedToolEnvelope;
        try self.expectByte('(');
        var args = TextBuffer.init(self.allocator);
        defer args.deinit();
        const writer = args.writer();
        try writer.writeByte('{');
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer keys.deinit(self.allocator);
        self.skipSpace();
        var count: usize = 0;
        if (!self.takeByte(')')) {
            while (true) {
                const key = try self.parseIdentifier();
                if (keys.contains(key)) return ClientError.MalformedToolEnvelope;
                try keys.put(self.allocator, key, {});
                try self.expectByte('=');
                if (count > 0) try writer.writeByte(',');
                count += 1;
                try writeJsonString(writer, key);
                try writer.writeByte(':');
                try self.parseValue(writer, 0);
                self.skipSpace();
                if (self.takeByte(')')) break;
                try self.expectByte(',');
            }
        }
        try writer.writeByte('}');
        const args_json = try args.toOwnedSlice();
        errdefer self.allocator.free(args_json);
        if (args_json.len > max_tool_args_bytes) return ClientError.MalformedToolEnvelope;
        return .{ .id = "", .name = name, .args_json = args_json };
    }

    fn parseValue(self: *EnvelopeParser, writer: anytype, depth: usize) anyerror!void {
        if (depth > max_value_depth) return ClientError.MalformedToolEnvelope;
        self.skipSpace();
        const byte = self.peek() orelse return ClientError.MalformedToolEnvelope;
        switch (byte) {
            '\'', '"' => try writeJsonString(writer, try self.parseString()),
            '[' => try self.parseList(writer, depth + 1),
            '{' => try self.parseObject(writer, depth + 1),
            '-', '0'...'9' => try writer.writeAll(try self.parseNumber()),
            else => {
                const word = try self.parseIdentifier();
                if (std.mem.eql(u8, word, "true") or
                    std.mem.eql(u8, word, "false") or
                    std.mem.eql(u8, word, "null"))
                {
                    try writer.writeAll(word);
                } else return ClientError.MalformedToolEnvelope;
            },
        }
    }

    fn parseList(self: *EnvelopeParser, writer: anytype, depth: usize) anyerror!void {
        try self.expectByte('[');
        try writer.writeByte('[');
        self.skipSpace();
        var index: usize = 0;
        if (!self.takeByte(']')) {
            while (true) {
                if (index > 0) try writer.writeByte(',');
                index += 1;
                try self.parseValue(writer, depth);
                self.skipSpace();
                if (self.takeByte(']')) break;
                try self.expectByte(',');
            }
        }
        try writer.writeByte(']');
    }

    fn parseObject(self: *EnvelopeParser, writer: anytype, depth: usize) anyerror!void {
        try self.expectByte('{');
        try writer.writeByte('{');
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer keys.deinit(self.allocator);
        self.skipSpace();
        var index: usize = 0;
        if (!self.takeByte('}')) {
            while (true) {
                self.skipSpace();
                const key = switch (self.peek() orelse return ClientError.MalformedToolEnvelope) {
                    '\'', '"' => try self.parseString(),
                    else => try self.parseIdentifier(),
                };
                if (keys.contains(key)) return ClientError.MalformedToolEnvelope;
                try keys.put(self.allocator, key, {});
                try self.expectByte(':');
                if (index > 0) try writer.writeByte(',');
                index += 1;
                try writeJsonString(writer, key);
                try writer.writeByte(':');
                try self.parseValue(writer, depth);
                self.skipSpace();
                if (self.takeByte('}')) break;
                try self.expectByte(',');
            }
        }
        try writer.writeByte('}');
    }

    fn parseString(self: *EnvelopeParser) ![]const u8 {
        self.skipSpace();
        const quote = self.peek() orelse return ClientError.MalformedToolEnvelope;
        if (quote != '\'' and quote != '"') return ClientError.MalformedToolEnvelope;
        self.pos += 1;
        var decoded = TextBuffer.init(self.allocator);
        defer decoded.deinit();
        const writer = decoded.writer();
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            self.pos += 1;
            if (byte == quote) {
                const out = try decoded.toOwnedSlice();
                if (!std.unicode.utf8ValidateSlice(out)) return ClientError.MalformedToolEnvelope;
                return out;
            }
            if (byte < 0x20) return ClientError.MalformedToolEnvelope;
            if (byte != '\\') {
                try writer.writeByte(byte);
                continue;
            }
            const escaped = self.peek() orelse return ClientError.MalformedToolEnvelope;
            self.pos += 1;
            switch (escaped) {
                '"', '\'', '\\', '/' => try writer.writeByte(escaped),
                'b' => try writer.writeByte(0x08),
                'f' => try writer.writeByte(0x0c),
                'n' => try writer.writeByte('\n'),
                'r' => try writer.writeByte('\r'),
                't' => try writer.writeByte('\t'),
                'u' => try self.parseUnicodeEscape(writer),
                else => return ClientError.MalformedToolEnvelope,
            }
        }
        return ClientError.MalformedToolEnvelope;
    }

    fn parseUnicodeEscape(self: *EnvelopeParser, writer: anytype) !void {
        var codepoint: u21 = try self.parseHex16();
        if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
            if (self.pos + 2 > self.input.len or
                self.input[self.pos] != '\\' or self.input[self.pos + 1] != 'u')
            {
                return ClientError.MalformedToolEnvelope;
            }
            self.pos += 2;
            const low = try self.parseHex16();
            if (low < 0xdc00 or low > 0xdfff) return ClientError.MalformedToolEnvelope;
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
        } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
            return ClientError.MalformedToolEnvelope;
        }
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch return ClientError.MalformedToolEnvelope;
        try writer.writeAll(bytes[0..len]);
    }

    fn parseHex16(self: *EnvelopeParser) !u16 {
        if (self.pos + 4 > self.input.len) return ClientError.MalformedToolEnvelope;
        const value = std.fmt.parseInt(u16, self.input[self.pos .. self.pos + 4], 16) catch
            return ClientError.MalformedToolEnvelope;
        self.pos += 4;
        return value;
    }

    fn parseNumber(self: *EnvelopeParser) ![]const u8 {
        self.skipSpace();
        const start = self.pos;
        _ = self.takeByte('-');
        if (self.takeByte('0')) {
            if (self.peek()) |next| if (next >= '0' and next <= '9') return ClientError.MalformedToolEnvelope;
        } else {
            try self.takeDigits(true);
        }
        if (self.takeByte('.')) try self.takeDigits(true);
        if (self.peek()) |next| {
            if (next == 'e' or next == 'E') {
                self.pos += 1;
                if (self.peek()) |sign| {
                    if (sign == '+' or sign == '-') self.pos += 1;
                }
                try self.takeDigits(true);
            }
        }
        return self.input[start..self.pos];
    }

    fn takeDigits(self: *EnvelopeParser, require_one: bool) !void {
        const start = self.pos;
        while (self.peek()) |byte| {
            if (byte < '0' or byte > '9') break;
            self.pos += 1;
        }
        if (require_one and self.pos == start) return ClientError.MalformedToolEnvelope;
    }

    fn parseIdentifier(self: *EnvelopeParser) ![]const u8 {
        self.skipSpace();
        const start = self.pos;
        const first = self.peek() orelse return ClientError.MalformedToolEnvelope;
        if (!isIdentifierStart(first)) return ClientError.MalformedToolEnvelope;
        self.pos += 1;
        while (self.peek()) |byte| {
            if (!isIdentifierContinue(byte)) break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn expectByte(self: *EnvelopeParser, expected: u8) !void {
        self.skipSpace();
        if (!self.takeByte(expected)) return ClientError.MalformedToolEnvelope;
    }

    fn takeByte(self: *EnvelopeParser, expected: u8) bool {
        if (self.pos >= self.input.len or self.input[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn skipSpace(self: *EnvelopeParser) void {
        self.pos = skipWhitespace(self.input, self.pos);
    }

    fn peek(self: *const EnvelopeParser) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }
};

fn skipWhitespace(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and switch (input[pos]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    }) pos += 1;
    return pos;
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_tool_name_bytes or !isIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| if (!isIdentifierContinue(byte)) return false;
    return true;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-';
}

fn stableCallId(
    arena: std.mem.Allocator,
    request_digest: [32]u8,
    response_digest: [32]u8,
    ordinal: usize,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zttp-local-tool-call-v1");
    hasher.update(&request_digest);
    hasher.update(&response_digest);
    var ordinal_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &ordinal_bytes, @intCast(ordinal), .big);
    hasher.update(&ordinal_bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(arena, "call_local_{s}", .{hex[0..32]});
}

fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn post(arena: std.mem.Allocator, config: Config, body: []const u8) ![]const u8 {
    const endpoint = try endpointUrl(arena, config.base_url);
    const uri = std.Uri.parse(endpoint) catch return ClientError.InvalidMlxBaseUrl;
    var io_backend = std.Io.Threaded.init(arena, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return ClientError.InvalidMlxBaseUrl;
    if (protocol != .plain) return ClientError.InvalidMlxBaseUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ClientError.InvalidMlxBaseUrl;
    const connection = http_errors.connect(&client, host, uri.port, protocol) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimedOut => return error.RequestTimedOut,
        else => return ClientError.LocalServerUnavailable,
    };
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    };
    var request = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &headers,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ClientError.LocalServerUnavailable,
    };
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var request_body = request.sendBodyUnflushed(&.{}) catch return ClientError.LocalServerUnavailable;
    request_body.writer.writeAll(body) catch return ClientError.LocalServerUnavailable;
    request_body.end() catch return ClientError.LocalServerUnavailable;
    request.connection.?.flush() catch return ClientError.LocalServerUnavailable;

    try waitForResponseHead(connection.stream_reader.stream.socket.handle);
    var response = request.receiveHead(&.{}) catch return ClientError.LocalServerUnavailable;
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    const response_body = http_errors.readBody(reader, arena, max_response_body_bytes) catch |err| switch (err) {
        error.StreamTooLong => return ClientError.ResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimedOut => return error.RequestTimedOut,
        else => return ClientError.LocalServerUnavailable,
    };
    if (response.head.status != .ok) {
        return http_errors.classify(@intFromEnum(response.head.status), response_body);
    }
    return response_body;
}

/// MLX does not send response headers until generation completes. The shared
/// socket has a two-minute idle read timeout, so entering `receiveHead` before
/// a long generation finishes can surface POSIX EAGAIN inside Zig's blocking
/// reader. Poll first without consuming bytes, then let the HTTP parser read a
/// ready header. This also provides a typed upper bound for a hung server.
fn waitForResponseHead(fd: std.posix.fd_t) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, response_head_timeout_ms) catch
        return ClientError.LocalServerUnavailable;
    if (ready == 0) return error.RequestTimedOut;
}

const writeJsonString = json_writer.writeString;

const testing = std.testing;

const DiagnosticsProbe = struct {
    diagnostics_calls: usize = 0,
    capture_calls: usize = 0,
    saw_expected_diagnostics: bool = false,

    fn capture(
        context: *anyopaque,
        call_index: usize,
        _: *const model_request.ModelRequestSnapshot,
        sanitized_response: []const u8,
    ) !void {
        const self: *DiagnosticsProbe = @ptrCast(@alignCast(context));
        self.capture_calls += 1;
        try testing.expectEqual(@as(usize, 0), call_index);
        try testing.expect(std.mem.indexOf(u8, sanitized_response, "private chain") == null);
    }

    fn diagnose(
        context: *anyopaque,
        attempt_index: usize,
        diagnostic_context: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) !void {
        const self: *DiagnosticsProbe = @ptrCast(@alignCast(context));
        self.diagnostics_calls += 1;
        try testing.expectEqual(@as(usize, 0), attempt_index);
        try testing.expectEqual(model_request.Provider.local, diagnostic_context.provider);
        try testing.expectEqualStrings("diagnostic-model", diagnostic_context.model);
        try testing.expect(diagnostics.latency_ms != null);
        try testing.expectEqual(capture_sink.FinishReason.stop, diagnostics.finish_reason.?);
        try testing.expectEqual(@as(?u64, 0), diagnostics.completion_tokens);
        try testing.expect(diagnostics.field_presence.choices);
        try testing.expect(diagnostics.field_presence.first_choice);
        try testing.expect(diagnostics.field_presence.finish_reason);
        try testing.expect(diagnostics.field_presence.message);
        try testing.expect(diagnostics.field_presence.content);
        try testing.expect(diagnostics.field_presence.reasoning);
        try testing.expect(!diagnostics.field_presence.tool_calls);
        try testing.expect(diagnostics.field_presence.usage);
        try testing.expect(diagnostics.field_presence.completion_tokens);
        try testing.expectEqualStrings("EmptyResponse", @errorName(diagnostics.failure.?));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .content_null));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .assistant_output_missing));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .decoder_rejected_response));
        self.saw_expected_diagnostics = true;
        return error.InjectedDiagnosticsFailure;
    }
};

fn hasParserWarning(
    warnings: []const capture_sink.ParserWarning,
    expected: capture_sink.ParserWarning,
) bool {
    return std.mem.findScalar(capture_sink.ParserWarning, warnings, expected) != null;
}

fn emptyResponsePost(_: std.mem.Allocator, _: Config, _: []const u8) ![]const u8 {
    return "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{" ++
        "\"reasoning\":\"private chain\",\"content\":null}}]," ++
        "\"usage\":{\"completion_tokens\":0}}";
}

test "local client records safe diagnostics without replacing decode failure" {
    var probe: DiagnosticsProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = DiagnosticsProbe.capture,
        .diagnostics_fn = DiagnosticsProbe.diagnose,
    };
    var client = Client.initWithCapture(.{
        .system_prompt = "diagnostic-system",
        .model = "diagnostic-model",
    }, &sink);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "private user source" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.EmptyResponse, client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        null,
        emptyResponsePost,
    ));

    try testing.expectEqual(@as(usize, 1), probe.capture_calls);
    try testing.expectEqual(@as(usize, 1), probe.diagnostics_calls);
    try testing.expect(probe.saw_expected_diagnostics);
    try testing.expectEqual(@as(usize, 1), sink.next_call_index);
    try testing.expectEqual(@as(usize, 1), sink.next_diagnostic_attempt_index);
}

const InvalidJsonDiagnosticsProbe = struct {
    diagnostics_calls: usize = 0,

    fn capture(
        _: *anyopaque,
        _: usize,
        _: *const model_request.ModelRequestSnapshot,
        _: []const u8,
    ) !void {
        return error.UnexpectedCapture;
    }

    fn diagnose(
        context: *anyopaque,
        attempt_index: usize,
        _: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) !void {
        const self: *InvalidJsonDiagnosticsProbe = @ptrCast(@alignCast(context));
        self.diagnostics_calls += 1;
        try testing.expectEqual(@as(usize, 0), attempt_index);
        try testing.expect(diagnostics.latency_ms != null);
        try testing.expect(diagnostics.finish_reason == null);
        try testing.expect(diagnostics.completion_tokens == null);
        try testing.expect(!diagnostics.field_presence.choices);
        try testing.expectEqualStrings("InvalidResponseJson", @errorName(diagnostics.failure.?));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .json_parse_failed));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .sanitizer_rejected_response));
        return error.InjectedDiagnosticsFailure;
    }
};

fn invalidJsonPost(_: std.mem.Allocator, _: Config, _: []const u8) ![]const u8 {
    return "{";
}

test "local client records parser warnings when response JSON is invalid" {
    var probe: InvalidJsonDiagnosticsProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = InvalidJsonDiagnosticsProbe.capture,
        .diagnostics_fn = InvalidJsonDiagnosticsProbe.diagnose,
    };
    var client = Client.initWithCapture(.{ .system_prompt = "diagnostic-system" }, &sink);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.InvalidResponseJson, client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        null,
        invalidJsonPost,
    ));
    try testing.expectEqual(@as(usize, 1), probe.diagnostics_calls);
    try testing.expectEqual(@as(usize, 0), sink.next_call_index);
    try testing.expectEqual(@as(usize, 1), sink.next_diagnostic_attempt_index);
}

const AttemptDiagnosticsProbe = struct {
    capture_calls: usize = 0,
    diagnostics_calls: usize = 0,

    fn capture(
        context: *anyopaque,
        call_index: usize,
        _: *const model_request.ModelRequestSnapshot,
        _: []const u8,
    ) !void {
        const self: *AttemptDiagnosticsProbe = @ptrCast(@alignCast(context));
        self.capture_calls += 1;
        try testing.expectEqual(@as(usize, 0), call_index);
    }

    fn diagnose(
        context: *anyopaque,
        attempt_index: usize,
        _: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) !void {
        const self: *AttemptDiagnosticsProbe = @ptrCast(@alignCast(context));
        try testing.expectEqual(self.diagnostics_calls, attempt_index);
        self.diagnostics_calls += 1;
        if (attempt_index < 2) {
            try testing.expectEqualStrings("LocalServerUnavailable", @errorName(diagnostics.failure.?));
            try testing.expect(hasParserWarning(diagnostics.parser_warnings, .transport_failed));
        } else {
            try testing.expectEqualStrings("EmptyResponse", @errorName(diagnostics.failure.?));
            try testing.expect(hasParserWarning(diagnostics.parser_warnings, .decoder_rejected_response));
        }
        return error.InjectedDiagnosticsFailure;
    }
};

fn transportFailurePost(_: std.mem.Allocator, _: Config, _: []const u8) ![]const u8 {
    return ClientError.LocalServerUnavailable;
}

test "local diagnostics order failed attempts independently of capture cursor" {
    var probe: AttemptDiagnosticsProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = AttemptDiagnosticsProbe.capture,
        .diagnostics_fn = AttemptDiagnosticsProbe.diagnose,
    };
    var client = Client.initWithCapture(.{ .system_prompt = "diagnostic-system" }, &sink);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (0..2) |_| {
        try testing.expectError(ClientError.LocalServerUnavailable, client.sendTurnWithPost(
            arena.allocator(),
            &transcript,
            null,
            transportFailurePost,
        ));
    }
    try testing.expectError(ClientError.EmptyResponse, client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        null,
        emptyResponsePost,
    ));

    try testing.expectEqual(@as(usize, 1), probe.capture_calls);
    try testing.expectEqual(@as(usize, 3), probe.diagnostics_calls);
    try testing.expectEqual(@as(usize, 1), sink.next_call_index);
    try testing.expectEqual(@as(usize, 3), sink.next_diagnostic_attempt_index);
}

const CaptureFailureDiagnosticsProbe = struct {
    diagnostics_calls: usize = 0,

    fn capture(
        _: *anyopaque,
        _: usize,
        _: *const model_request.ModelRequestSnapshot,
        _: []const u8,
    ) !void {
        return error.InjectedCaptureFailure;
    }

    fn diagnose(
        context: *anyopaque,
        attempt_index: usize,
        _: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) !void {
        const self: *CaptureFailureDiagnosticsProbe = @ptrCast(@alignCast(context));
        self.diagnostics_calls += 1;
        try testing.expectEqual(@as(usize, 0), attempt_index);
        try testing.expectEqualStrings("InjectedCaptureFailure", @errorName(diagnostics.failure.?));
        try testing.expect(hasParserWarning(diagnostics.parser_warnings, .capture_rejected_response));
        return error.InjectedDiagnosticsFailure;
    }
};

fn validResponsePost(_: std.mem.Allocator, _: Config, _: []const u8) ![]const u8 {
    return "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{" ++
        "\"content\":\"ok\"}}],\"usage\":{\"completion_tokens\":1}}";
}

test "local diagnostics cannot replace a strict capture failure" {
    var probe: CaptureFailureDiagnosticsProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = CaptureFailureDiagnosticsProbe.capture,
        .diagnostics_fn = CaptureFailureDiagnosticsProbe.diagnose,
    };
    var client = Client.initWithCapture(.{ .system_prompt = "diagnostic-system" }, &sink);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InjectedCaptureFailure, client.sendTurnWithPost(
        arena.allocator(),
        &transcript,
        null,
        validResponsePost,
    ));
    try testing.expectEqual(@as(usize, 1), probe.diagnostics_calls);
    try testing.expectEqual(@as(usize, 0), sink.next_call_index);
    try testing.expectEqual(@as(usize, 1), sink.next_diagnostic_attempt_index);
}

test "local response diagnostics reject unknown finish reason text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var inspection: ResponseInspection = .{};
    _ = try parseSanitizedResponseWithInspection(
        arena.allocator(),
        "{\"choices\":[{\"finish_reason\":\"private-provider-text\",\"message\":{" ++
            "\"content\":\"ok\"}}],\"usage\":{\"completion_tokens\":1}}",
        &inspection,
    );

    try testing.expect(inspection.field_presence.finish_reason);
    try testing.expect(inspection.finish_reason == null);
    try testing.expect(hasParserWarning(inspection.warningSlice(), .finish_reason_unknown));
}

test "local request uses non-streaming Chat Completions framing" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "inspect handler.ts" });
    try transcript.append(testing.allocator, .{ .model_text = "I will inspect it." });
    const calls = [_]turn.ToolCall{.{
        .id = "prior_call",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
    }};
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "prior_call",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "source bytes",
    } });
    try transcript.append(testing.allocator, .{ .system_note = "compiler veto: repair line 3" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{
        .system_prompt = "zts expert",
        .tools_json = "[]",
    }, &transcript, "repair continuation");

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings(default_model, root.get("model").?.string);
    try testing.expect(!root.get("stream").?.bool);
    try testing.expectEqual(@as(i64, default_max_tokens), root.get("max_tokens").?.integer);
    try testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    const messages = root.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 7), messages.len);
    try testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    try testing.expectEqualStrings("user", messages[1].object.get("role").?.string);
    try testing.expectEqualStrings("assistant", messages[2].object.get("role").?.string);
    try testing.expectEqualStrings("assistant", messages[3].object.get("role").?.string);
    try testing.expectEqualStrings("tool", messages[4].object.get("role").?.string);
    try testing.expectEqualStrings("compiler veto: repair line 3", messages[5].object.get("content").?.string);
    try testing.expectEqualStrings("repair continuation", messages[6].object.get("content").?.string);
}

test "local response prefers structured tool calls and discards reasoning" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{" ++
        "\"reasoning\":\"private chain\",\"content\":\"<|tool_call_start|>[wrong()]<|tool_call_end|>\"," ++
        "\"tool_calls\":[{\"id\":\"server-id\",\"type\":\"function\",\"function\":{" ++
        "\"name\":\"workspace_read_file\",\"arguments\":\"{\\\"path\\\":\\\"handler.ts\\\"}\"}}]}}]," ++
        "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7}}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const first = try decodeResponse(arena.allocator(), "request", response);
    const second = try decodeResponse(arena.allocator(), "request", response);
    try testing.expectEqual(@as(u64, 11), first.usage.input_tokens);
    try testing.expectEqual(@as(u64, 7), first.usage.output_tokens);
    try testing.expect(first.reply.preamble == null);
    const first_calls = first.reply.response.tool_calls;
    const second_calls = second.reply.response.tool_calls;
    try testing.expectEqual(@as(usize, 1), first_calls.len);
    try testing.expectEqualStrings("workspace_read_file", first_calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"handler.ts\"}", first_calls[0].args_json);
    try testing.expectEqualStrings(first_calls[0].id, second_calls[0].id);
    try testing.expect(std.mem.startsWith(u8, first_calls[0].id, "call_local_"));
    try testing.expect(std.mem.indexOf(u8, response, "private chain") != null);
}

test "local response decodes plain text and usage without reasoning" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{" ++
        "\"reasoning\":\"private\",\"content\":\"hello\"}}]," ++
        "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), "request", response);
    switch (result.reply.response) {
        .final_text => |text| try testing.expectEqualStrings("hello", text),
        else => return error.TestFailed,
    }
    try testing.expectEqual(@as(u64, 3), result.usage.input_tokens);
    try testing.expectEqual(@as(u64, 2), result.usage.output_tokens);
}

test "local tool call ids change with request and response digests" {
    const response_a =
        "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{" ++
        "\"function\":{\"name\":\"inspect\",\"arguments\":\"{}\"}}]}}]}";
    const response_b =
        "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{" ++
        "\"function\":{\"name\":\"inspect_other\",\"arguments\":\"{}\"}}]}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const first = try decodeResponse(arena.allocator(), "request-a", response_a);
    const changed_request = try decodeResponse(arena.allocator(), "request-b", response_a);
    const changed_response = try decodeResponse(arena.allocator(), "request-a", response_b);
    const first_id = first.reply.response.tool_calls[0].id;
    try testing.expect(!std.mem.eql(u8, first_id, changed_request.reply.response.tool_calls[0].id));
    try testing.expect(!std.mem.eql(u8, first_id, changed_response.reply.response.tool_calls[0].id));
}

test "local response sanitization removes nested reasoning before capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sanitized = try sanitizeResponse(
        arena.allocator(),
        "{\"reasoning\":\"root\",\"choices\":[{\"message\":{\"reasoning\":\"private\",\"content\":\"ok\"}}]}",
    );
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "reasoning") == null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "\"content\":\"ok\"") != null);
}

test "local response normalizes multiple raw calls with nested arguments" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":" ++
        "\"<|tool_call_start|>[alpha(text='a\\\\n\\\"b', count=-2.5e3, ok=true, none=null, " ++
        "items=[1, 'two'], meta={key: 'value', nested: {enabled: false}}), beta()]<|tool_call_end|>\"}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), "request", response);
    const calls = result.reply.response.tool_calls;
    try testing.expectEqual(@as(usize, 2), calls.len);
    try testing.expectEqualStrings("alpha", calls[0].name);
    try testing.expectEqualStrings("beta", calls[1].name);
    try testing.expect(!std.mem.eql(u8, calls[0].id, calls[1].id));
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), calls[0].args_json, .{});
    try testing.expectEqualStrings("a\n\"b", args.object.get("text").?.string);
    try testing.expect(args.object.get("ok").?.bool);
    try testing.expect(args.object.get("none").? == .null);
    try testing.expectEqualStrings(
        "value",
        args.object.get("meta").?.object.get("key").?.string,
    );
}

test "local raw tool syntax leaves unknown valid names to the registry" {
    const response =
        "{\"choices\":[{\"message\":{\"content\":" ++
        "\"<|tool_call_start|>[future_tool(value=1)]<|tool_call_end|>\"}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), "request", response);
    try testing.expectEqualStrings("future_tool", result.reply.response.tool_calls[0].name);
    try testing.expectEqualStrings("{\"value\":1}", result.reply.response.tool_calls[0].args_json);
}

test "local response rejects malformed raw tool envelopes" {
    const malformed = [_][]const u8{
        "prefix <|tool_call_start|>[alpha()]<|tool_call_end|>",
        "<|tool_call_start|>[alpha()]",
        "<|tool_call_start|>[alpha(x=1, x=2)]<|tool_call_end|>",
        "<|tool_call_start|>[alpha(meta={x: 1, x: 2})]<|tool_call_end|>",
        "<|tool_call_start|>[alpha(x=unknown)]<|tool_call_end|>",
    };
    for (malformed) |content| {
        const response = try std.fmt.allocPrint(testing.allocator, "{{\"choices\":[{{\"message\":{{\"content\":{f}}}}}]}}", .{std.json.fmt(content, .{})});
        defer testing.allocator.free(response);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectError(
            ClientError.MalformedToolEnvelope,
            decodeResponse(arena.allocator(), "request", response),
        );
    }
}

test "local response reports invalid JSON and output truncation distinctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.InvalidResponseJson, decodeResponse(arena.allocator(), "request", "{"));
    try testing.expectError(ClientError.OutputTruncated, decodeResponse(
        arena.allocator(),
        "request",
        "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}",
    ));
}

test "local response enforces response envelope argument call and depth bounds" {
    const oversized_response = try testing.allocator.alloc(u8, max_response_body_bytes + 1);
    defer testing.allocator.free(oversized_response);
    @memset(oversized_response, 'x');
    try testing.expectError(
        ClientError.ResponseTooLarge,
        sanitizeResponse(testing.allocator, oversized_response),
    );

    var nested_response = TextBuffer.init(testing.allocator);
    defer nested_response.deinit();
    for (0..max_response_json_depth + 1) |_| try nested_response.writer().writeByte('[');
    try nested_response.writer().writeByte('0');
    for (0..max_response_json_depth + 1) |_| try nested_response.writer().writeByte(']');
    try testing.expectError(
        ClientError.InvalidResponseJson,
        sanitizeResponse(testing.allocator, nested_response.written()),
    );

    const oversized_args = try testing.allocator.alloc(u8, max_tool_args_bytes + 1);
    defer testing.allocator.free(oversized_args);
    @memset(oversized_args, 'x');
    try testing.expectError(
        ClientError.MalformedToolCall,
        validateJsonArguments(testing.allocator, oversized_args),
    );

    const oversized_envelope = try testing.allocator.alloc(u8, max_tool_envelope_bytes + 1);
    defer testing.allocator.free(oversized_envelope);
    @memset(oversized_envelope, 'x');
    try testing.expectError(
        ClientError.MalformedToolEnvelope,
        parseToolEnvelopes(testing.allocator, [_]u8{0} ** 32, sha256("response"), oversized_envelope),
    );

    var too_many = TextBuffer.init(testing.allocator);
    defer too_many.deinit();
    try too_many.writer().writeAll(tool_call_start ++ "[");
    for (0..max_tool_calls + 1) |index| {
        if (index > 0) try too_many.writer().writeByte(',');
        try too_many.writer().writeAll("inspect()");
    }
    try too_many.writer().writeAll("]" ++ tool_call_end);
    try testing.expectError(
        ClientError.TooManyToolCalls,
        parseToolEnvelopes(testing.allocator, [_]u8{0} ** 32, sha256("response"), too_many.written()),
    );

    var nested = TextBuffer.init(testing.allocator);
    defer nested.deinit();
    try nested.writer().writeAll(tool_call_start ++ "[inspect(value=");
    for (0..max_value_depth + 2) |_| try nested.writer().writeByte('[');
    try nested.writer().writeByte('0');
    for (0..max_value_depth + 2) |_| try nested.writer().writeByte(']');
    try nested.writer().writeAll(")]" ++ tool_call_end);
    try testing.expectError(
        ClientError.MalformedToolEnvelope,
        parseToolEnvelopes(testing.allocator, [_]u8{0} ** 32, sha256("response"), nested.written()),
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const duplicate_structured_args =
        "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{" ++
        "\"function\":{\"name\":\"inspect\",\"arguments\":\"{\\\"x\\\":1,\\\"x\\\":2}\"}}]}}]}";
    try testing.expectError(
        ClientError.MalformedToolCall,
        decodeResponse(arena.allocator(), "request", duplicate_structured_args),
    );
}

test "local base URL defaulting trims one shared environment value" {
    try testing.expectEqualStrings(default_base_url, effectiveBaseUrl(null));
    try testing.expectEqualStrings(default_base_url, effectiveBaseUrl(" \t\r\n"));
    try testing.expectEqualStrings("http://127.0.0.1:9090", effectiveBaseUrl(" http://127.0.0.1:9090 "));
}

test "local base URL accepts only credential-free HTTP loopback roots" {
    try validateBaseUrl("http://127.0.0.1:8080");
    try validateBaseUrl("http://localhost:9090/");
    try validateBaseUrl("http://[::1]:8080");
    const rejected = [_][]const u8{
        "https://127.0.0.1:8080",
        "http://0.0.0.0:8080",
        "http://192.168.1.2:8080",
        "http://user:pass@127.0.0.1:8080",
        "http://127.0.0.1:8080/prefix",
        "http://127.0.0.1:8080?token=x",
        "http://127.0.0.1:8080#fragment",
    };
    for (rejected) |url| try testing.expectError(ClientError.InvalidMlxBaseUrl, validateBaseUrl(url));
}

const ReadinessProbe = struct {
    health_status: std.http.Status = .ok,
    models_status: std.http.Status = .ok,
    models_body: []const u8 =
        "{\"data\":[{\"id\":\"LiquidAI/LFM2.5-2.6B-MLX-8bit\"}]}",
    calls: usize = 0,

    fn get(
        context: *anyopaque,
        _: std.mem.Allocator,
        url: []const u8,
        read_body: bool,
    ) !ReadinessResponse {
        const self: *ReadinessProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (std.mem.endsWith(u8, url, "/health")) {
            try testing.expect(!read_body);
            return .{ .status = self.health_status, .body = "ok" };
        }
        try testing.expect(std.mem.endsWith(u8, url, "/v1/models"));
        try testing.expect(read_body);
        return .{ .status = self.models_status, .body = self.models_body };
    }
};

test "local readiness requires health and the exact model id" {
    var probe: ReadinessProbe = .{};
    try checkReadinessWithGet(
        testing.allocator,
        default_base_url,
        default_model,
        &probe,
        ReadinessProbe.get,
    );
    try testing.expectEqual(@as(usize, 2), probe.calls);

    probe = .{ .health_status = .service_unavailable };
    try testing.expectError(ClientError.LocalHealthNotOk, checkReadinessWithGet(
        testing.allocator,
        default_base_url,
        default_model,
        &probe,
        ReadinessProbe.get,
    ));
    try testing.expectEqual(@as(usize, 1), probe.calls);

    probe = .{ .models_body = "{\"data\":[{\"id\":\"another-model\"}]}" };
    try testing.expectError(ClientError.LocalModelUnavailable, checkReadinessWithGet(
        testing.allocator,
        default_base_url,
        default_model,
        &probe,
        ReadinessProbe.get,
    ));

    probe = .{ .models_body = "not-json" };
    try testing.expectError(ClientError.InvalidResponseJson, checkReadinessWithGet(
        testing.allocator,
        default_base_url,
        default_model,
        &probe,
        ReadinessProbe.get,
    ));
}

test "local tool serializer uses Chat Completions function wrappers" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, .{
        .name = "inspect",
        .label = "Inspect",
        .description = "Inspect the workspace.",
        .effect = .read_workspace,
        .context_policy = .exact,
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .decode_json = registry_mod.helpers.decodeNoArgs,
        .execute = unusedExecute,
    });
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try writeToolsArray(buf.writer(), &registry);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.written(), .{});
    defer parsed.deinit();
    const tools = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("function", tools[0].object.get("type").?.string);
    try testing.expectEqualStrings("apply_edit", tools[0].object.get("function").?.object.get("name").?.string);
    try testing.expectEqualStrings("inspect", tools[1].object.get("function").?.object.get("name").?.string);
    try testing.expect(tools[1].object.get("function").?.object.get("parameters").? == .object);
}

fn unusedExecute(_: std.mem.Allocator, _: []const []const u8) anyerror!registry_mod.ToolResult {
    return error.TestUnexpectedCall;
}

test "local client exposes the loop-facing request signature" {
    var client = Client.init(.{ .system_prompt = "s" });
    const model_client = client.asModelClient();
    try testing.expect(model_client.context == @as(*anyopaque, @ptrCast(&client)));
    try testing.expect(@intFromPtr(model_client.request_fn) != 0);
}
