//! Non-streaming Chat Completions adapter for the DeepSeek API.
//!
//! DeepSeek serves an OpenAI-compatible `/chat/completions` endpoint, not the
//! Responses API, so this is a sibling of `local/client.zig` rather than of
//! `openai/client.zig`: the same request body, a different endpoint policy and
//! a different decoder.
//!
//! Two things differ from the local adapter. The endpoint is remote, so the
//! transport requires HTTPS and a bearer credential. And DeepSeek returns
//! tool-call ids of its own, so ids are taken from the response instead of
//! being synthesized from a request digest, and the `<|tool_call_start|>`
//! envelope the local LFM model emits has no counterpart here.

const std = @import("std");
const zts = @import("zts");
const TextBuffer = @import("../../text_buffer.zig").TextBuffer;
const loop = @import("../../loop.zig");
const turn = @import("../../turn.zig");
const transcript_mod = @import("../../transcript.zig");
const registry_mod = @import("../../registry/registry.zig");
const propose_change_set = @import("../anthropic/propose_change_set.zig");
const http_errors = @import("../http_errors.zig");
const model_request = @import("../model_request.zig");
const context_budget = @import("../../context_budget.zig");
const model_registry = @import("../models.zig");
const capture_sink = @import("../capture_sink.zig");
const chat_completions = @import("../chat_completions.zig");

pub const default_base_url = "https://api.deepseek.com";
pub const default_model = model_registry.defaultForProvider(.deepseek).id;
pub const default_max_tokens = model_registry.defaultForProvider(.deepseek).request_policy.max_output_tokens;

/// `DEEPSEEK_BASE_URL` selects a different HTTPS root, for a gateway or a
/// regional endpoint. A blank value is treated as unset.
pub fn effectiveBaseUrl(raw: ?[]const u8) []const u8 {
    const value = raw orelse return default_base_url;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) default_base_url else trimmed;
}

const chat_completions_path = "/chat/completions";
const max_response_body_bytes: usize = 16 * 1024 * 1024;
const max_tool_args_bytes: usize = 256 * 1024;
const max_tool_calls: usize = 16;
const max_tool_name_bytes: usize = 128;
const max_value_depth: usize = 16;
const max_response_json_depth: usize = 64;

const TransportResponse = union(enum) {
    ok: []const u8,
    http_error: struct {
        status_code: u16,
        body: []const u8,
    },
};

/// How long a single completion may take before the request is called stalled.
///
/// A non-streaming DeepSeek response sends its head at once and then nothing at
/// all until generation finishes, so the silence sits between the head and the
/// first body byte and lasts as long as the model takes. The shared 2-minute
/// idle budget expires inside a healthy request of that shape.
///
/// This is the socket's read timeout and nothing else. An expired `SO_RCVTIMEO`
/// surfaces as POSIX EAGAIN inside a blocking read, which Zig 0.16 treats as a
/// programmer bug and panics on instead of returning an error, so the socket
/// value must be one no healthy request can reach - not the turn's remaining
/// budget, which is smaller than this ceiling by definition. Detecting a stall
/// is the polls' job, and bounding the turn is the turn deadline's.
const generation_ceiling_ms: i32 = 15 * 60 * 1000;

/// The value handed to `SO_RCVTIMEO`. Named so a test can assert what it is not:
/// derived from the turn budget, which is what made the panic above reachable on
/// every call.
const socket_read_timeout_ms: i32 = generation_ceiling_ms;

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
    /// How long one request may sit silent before it is called stalled, apart
    /// from `request_timeout_ms`, which is whatever the turn has left.
    ///
    /// The two are different questions and one number answered both: a turn
    /// whose budget is gone and a single request that hung read identically,
    /// because the poll below was bounded by the remaining budget alone. Set
    /// this below that budget and the two separate - a poll that expires with
    /// budget still on the clock reports `DeepSeekGenerationStalled`, which the
    /// caller may reissue, while an expiry that reaches the budget stays
    /// `RequestTimedOut` and ends the turn as before. Null keeps one number
    /// answering both, which is right for interactive use.
    stall_timeout_ms: ?u64 = null,
};

pub const ClientError = error{
    DeepSeekGenerationStalled,
    DeepSeekServerUnavailable,
    EmptyResponse,
    InvalidDeepSeekBaseUrl,
    InvalidResponseJson,
    MalformedToolCall,
    OutputTruncated,
    ResponseTooLarge,
    TooManyToolCalls,
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
        try validateBaseUrl(self.config.base_url);
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = .{
                .provider = .deepseek,
                .model = self.config.model,
                .max_output_tokens = self.config.max_tokens,
                .stream = false,
                .system_prompt = self.config.system_prompt,
                .tools_json = self.config.tools_json,
                .reserve_tokens = self.config.reserve_tokens,
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
        snapshot.wire_request_sha256 = model_request.Sha256Hex.fromRawBytes(body);
        const diagnostics_enabled = if (self.capture) |sink| sink.diagnostics_fn != null else false;
        const started_ns = if (diagnostics_enabled) monotonicNowNs() else null;

        const transport_response = post_fn(arena, self.config, body) catch |err| {
            if (diagnostics_enabled) {
                var inspection: ResponseInspection = .{};
                inspection.addWarning(.transport_failed);
                self.recordResponseDiagnostics(&inspection, elapsedMs(started_ns), null, err, null);
            }
            return err;
        };
        const raw_response = switch (transport_response) {
            .ok => |response_body| response_body,
            .http_error => |http_failure| {
                const err = http_errors.classify(http_failure.status_code, http_failure.body);
                if (diagnostics_enabled) {
                    var inspection: ResponseInspection = .{};
                    inspection.addWarning(.transport_failed);
                    self.recordResponseDiagnostics(
                        &inspection,
                        elapsedMs(started_ns),
                        http_failure.status_code,
                        err,
                        null,
                    );
                }
                return err;
            },
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
                self.recordResponseDiagnostics(&inspection, latency_ms, null, err, null);
            }
            return err;
        };
        if (self.capture) |sink| {
            sink.record(&snapshot, response.bytes) catch |err| {
                if (diagnostics_enabled) {
                    inspection.addWarning(.capture_rejected_response);
                    self.recordResponseDiagnostics(&inspection, latency_ms, null, err, null);
                }
                return err;
            };
        }
        var change_set_rejection: ?propose_change_set.RejectionShape = null;
        const result = decodeResponseValue(arena, response.value, &change_set_rejection) catch |err| {
            if (diagnostics_enabled) {
                inspection.addWarning(.decoder_rejected_response);
                self.recordResponseDiagnostics(&inspection, latency_ms, null, err, change_set_rejection);
            }
            return err;
        };
        if (diagnostics_enabled) {
            self.recordResponseDiagnostics(&inspection, latency_ms, null, null, null);
        }
        return result;
    }

    fn recordResponseDiagnostics(
        self: *Client,
        inspection: *const ResponseInspection,
        latency_ms: ?u64,
        http_status: ?u16,
        failure: ?anyerror,
        change_set_rejection: ?propose_change_set.RejectionShape,
    ) void {
        const sink = self.capture orelse return;
        sink.recordDiagnostics(.{
            .provider = .deepseek,
            .model = self.config.model,
        }, .{
            .latency_ms = latency_ms,
            .http_status = http_status,
            .finish_reason = inspection.finish_reason,
            .completion_tokens = inspection.completion_tokens,
            .field_presence = inspection.field_presence,
            .parser_warnings = inspection.warningSlice(),
            .failure = failure,
            .change_set_rejection = change_set_rejection,
        });
    }
};

/// The endpoint must be a remote HTTPS root carrying no credential of its own.
/// Plain HTTP is refused rather than upgraded: an API key belongs on a
/// TLS socket, and a silent upgrade would hide a misconfiguration.
pub fn validateBaseUrl(url: []const u8) ClientError!void {
    const uri = std.Uri.parse(url) catch return ClientError.InvalidDeepSeekBaseUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return ClientError.InvalidDeepSeekBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return ClientError.InvalidDeepSeekBaseUrl;
    }
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ClientError.InvalidDeepSeekBaseUrl;
    if (host.bytes.len == 0) return ClientError.InvalidDeepSeekBaseUrl;
    var path_buf: [1024]u8 = undefined;
    const path = uri.path.toRaw(&path_buf) catch return ClientError.InvalidDeepSeekBaseUrl;
    // A root or a single prefix segment (`/v1`) is allowed; the endpoint path
    // is appended, so anything deeper is a caller mistake.
    if (path.len > 0 and !std.mem.eql(u8, path, "/")) {
        const trimmed = std.mem.trimEnd(u8, path, "/");
        if (std.mem.count(u8, trimmed, "/") != 1) return ClientError.InvalidDeepSeekBaseUrl;
    }
}

fn endpointUrl(arena: std.mem.Allocator, base_url: []const u8) ![]u8 {
    try validateBaseUrl(base_url);
    return std.fmt.allocPrint(arena, "{s}{s}", .{
        std.mem.trimEnd(u8, base_url, "/"),
        chat_completions_path,
    });
}

pub fn buildRequestBody(
    arena: std.mem.Allocator,
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) ![]u8 {
    try validateBaseUrl(config.base_url);
    return chat_completions.buildRequestBody(arena, .{
        .provider = .deepseek,
        .model = config.model,
        .max_tokens = config.max_tokens,
        .system_prompt = config.system_prompt,
        .tools_json = config.tools_json,
    }, transcript, extra_user_text);
}

pub fn writeToolsArray(writer: anytype, registry: *const registry_mod.Registry) !void {
    return chat_completions.writeToolsArray(writer, registry);
}

// -----------------------------------------------------------------------
// Response decoding
// -----------------------------------------------------------------------

pub fn decodeResponse(
    arena: std.mem.Allocator,
    response_body: []const u8,
) !loop.ModelCallResult {
    return decodeResponseObserved(arena, response_body, null);
}

/// `decodeResponse`, reporting which change-set refusal fired through
/// `observed`.
///
/// This is the decode a recording actually runs. `sendTurn` captures before it
/// decodes, and the capture pre-decodes the body through here to prove the
/// cassette will replay, so a refused proposal fails at capture and `sendTurn`'s
/// own decode is never reached. Instrumenting only that later branch left the
/// path that fires blind, which is how two occurrences in one run reported a
/// null shape.
pub fn decodeResponseObserved(
    arena: std.mem.Allocator,
    response_body: []const u8,
    observed: ?*?propose_change_set.RejectionShape,
) !loop.ModelCallResult {
    const response = try parseSanitizedResponse(arena, response_body);
    return decodeResponseValue(arena, response.value, observed);
}

/// The response with unneeded reasoning fields removed, plus the parsed value.
/// DeepSeek V4 requires reasoning_content from tool-call messages to be passed
/// back verbatim on subsequent requests. That one opaque continuation is kept;
/// final-answer reasoning and gateway-specific reasoning fields are scrubbed.
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
    inspection.field_presence.reasoning = message.object.get("reasoning_content") != null or
        message.object.get("reasoning") != null;
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

fn inspectUsage(inspection: *ResponseInspection, maybe_usage: ?std.json.Value) void {
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
    removeUnneededReasoning(&root);
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

/// Keep only the official DeepSeek continuation attached to a non-empty tool
/// call batch. Generic gateway reasoning and final-answer reasoning remain
/// private and never enter transcripts or cassettes.
fn removeUnneededReasoning(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            const has_tool_calls = if (object.get("tool_calls")) |calls|
                calls == .array and calls.array.items.len > 0
            else
                false;
            if (!has_tool_calls) _ = object.orderedRemove("reasoning_content");
            _ = object.orderedRemove("reasoning");
            for (object.values()) |*child| removeUnneededReasoning(child);
        },
        .array => |*array| for (array.items) |*child| removeUnneededReasoning(child),
        else => {},
    }
}

fn decodeResponseValue(
    arena: std.mem.Allocator,
    root: std.json.Value,
    change_set_rejection: ?*?propose_change_set.RejectionShape,
) !loop.ModelCallResult {
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
    const reasoning_content = try optionalString(message.object.get("reasoning_content"));
    const usage = try decodeUsage(root.object.get("usage"));

    if (message.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value != .array) return ClientError.UnexpectedResponseShape;
        if (tool_calls_value.array.items.len > max_tool_calls) return ClientError.TooManyToolCalls;
        if (tool_calls_value.array.items.len > 0) {
            const calls = try arena.alloc(turn.ToolCall, tool_calls_value.array.items.len);
            for (tool_calls_value.array.items, 0..) |item, index| {
                if (item != .object) return ClientError.MalformedToolCall;
                const id = try requiredString(item.object.get("id"));
                if (id.len == 0 or id.len > max_tool_name_bytes) return ClientError.MalformedToolCall;
                const function = item.object.get("function") orelse return ClientError.MalformedToolCall;
                if (function != .object) return ClientError.MalformedToolCall;
                const name = try requiredString(function.object.get("name"));
                if (!validToolName(name)) return ClientError.MalformedToolCall;
                const args = try requiredString(function.object.get("arguments"));
                try validateJsonArguments(arena, args);
                calls[index] = .{
                    .id = id,
                    .name = name,
                    .args_json = args,
                    .reasoning_content = if (index == 0) reasoning_content else null,
                };
            }
            const reply: turn.AssistantReply = .{
                .preamble = nonEmpty(content),
                .response = .{ .tool_calls = calls },
            };
            return .{
                .reply = try propose_change_set.maybeRemapObserved(
                    arena,
                    reply,
                    finish_reason,
                    change_set_rejection,
                ),
                .usage = usage,
                .stop_reason = finish_reason,
            };
        }
    }

    const text = content orelse return ClientError.EmptyResponse;
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

// -----------------------------------------------------------------------
// Transport
// -----------------------------------------------------------------------

fn post(arena: std.mem.Allocator, config: Config, body: []const u8) !TransportResponse {
    const endpoint = try endpointUrl(arena, config.base_url);
    const uri = std.Uri.parse(endpoint) catch return ClientError.InvalidDeepSeekBaseUrl;
    var io_backend = std.Io.Threaded.init(arena, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var client = std.http.Client{ .allocator = arena, .io = io };
    defer client.deinit();

    // `http_errors.connect` pre-connects, which runs the TLS handshake before
    // `request()` would populate `now` and `ca_bundle` on its own. Scan the
    // system trust store and stamp `now` here, as the Anthropic client does.
    const now = std.Io.Clock.real.now(io);
    client.ca_bundle.rescan(arena, io, now) catch return error.CertificateBundleLoadFailure;
    client.now = now;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return ClientError.InvalidDeepSeekBaseUrl;
    if (protocol != .tls) return ClientError.InvalidDeepSeekBaseUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return ClientError.InvalidDeepSeekBaseUrl;
    const connection = http_errors.connectWithin(
        &client,
        host,
        uri.port,
        protocol,
        config.request_timeout_ms,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimedOut => return error.RequestTimedOut,
        else => return ClientError.DeepSeekServerUnavailable,
    };
    const request_timeout_ms = effectiveRequestTimeoutMs(config.request_timeout_ms, generation_ceiling_ms);
    const silence_ceiling_ms = effectiveStallCeilingMs(config.stall_timeout_ms, request_timeout_ms);
    // The socket gets the generation ceiling, never the turn's remaining budget.
    //
    // `SO_RCVTIMEO` expiring inside a blocking read is POSIX EAGAIN, which Zig
    // 0.16 treats as a programmer bug and panics on, killing the process rather
    // than failing the call - and a corpus recording loses all nineteen cases
    // with it. A budget-sized socket timeout is under-sized by construction: the
    // budget is whatever the turn has left, always at or below the ceiling, so
    // every call was one mid-body stall away from that panic. It happened on
    // `durable-order` call 3, about 600s into a 600s budget.
    //
    // The polls below stay short. They are what detects a stall and turns it
    // into a typed error; the socket timeout exists only so a read cannot hang
    // forever, and the turn deadline is what bounds the turn.
    http_errors.setReadTimeoutMs(
        connection.stream_reader.stream.socket.handle,
        @intCast(socket_read_timeout_ms),
    );
    const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{config.api_key});
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "authorization", .value = authorization },
    };
    var request = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &headers,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ClientError.DeepSeekServerUnavailable,
    };
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var request_body = request.sendBodyUnflushed(&.{}) catch return ClientError.DeepSeekServerUnavailable;
    request_body.writer.writeAll(body) catch return ClientError.DeepSeekServerUnavailable;
    request_body.end() catch return ClientError.DeepSeekServerUnavailable;
    request.connection.?.flush() catch return ClientError.DeepSeekServerUnavailable;

    try waitForReadable(
        connection.stream_reader.stream.socket.handle,
        silence_ceiling_ms,
        request_timeout_ms,
    );
    var response = request.receiveHead(&.{}) catch return ClientError.DeepSeekServerUnavailable;
    // The head arrives before generation starts, so the long silence is here,
    // between the head and the first body byte. Poll for it rather than letting
    // a blocking read sit on the socket past its timeout.
    try waitForReadable(
        connection.stream_reader.stream.socket.handle,
        silence_ceiling_ms,
        request_timeout_ms,
    );
    var transfer_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    const response_body = readBodyWithin(
        reader,
        arena,
        max_response_body_bytes,
        connection.stream_reader.stream.socket.handle,
        silence_ceiling_ms,
        request_timeout_ms,
    ) catch |err| switch (err) {
        error.StreamTooLong => return ClientError.ResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimedOut => return error.RequestTimedOut,
        error.DeepSeekGenerationStalled => return ClientError.DeepSeekGenerationStalled,
        else => return ClientError.DeepSeekServerUnavailable,
    };
    if (response.head.status != .ok) {
        return .{ .http_error = .{
            .status_code = @intFromEnum(response.head.status),
            .body = response_body,
        } };
    }
    return .{ .ok = response_body };
}

/// Read the response body a chunk at a time, polling the socket whenever more
/// is expected.
///
/// `http_errors.readBody` reads to end of stream in one call, so the only bound
/// on a mid-body stall was `SO_RCVTIMEO` - which is the 15-minute generation
/// ceiling, never the turn's remaining budget. The two polls above cover the
/// wait before the head and the wait before the first body byte and nothing
/// after, so a connection that went silent once bytes had started arriving sat
/// there for the full ceiling with no output and no error, long past the
/// deadline `setProviderRequestTimeout` was asked to enforce.
///
/// A short read is end of stream, so the loop only polls after a chunk that
/// filled the buffer: the wait is taken where more data is genuinely expected,
/// and the last chunk returns without one.
fn readBodyWithin(
    reader: *std.Io.Reader,
    arena: std.mem.Allocator,
    limit_bytes: usize,
    fd: std.posix.fd_t,
    silence_ceiling_ms: i32,
    request_timeout_ms: i32,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(arena);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const read = reader.readSliceShort(&chunk) catch |err| {
            if (http_errors.isTimeout(err)) return error.RequestTimedOut;
            return err;
        };
        if (body.items.len + read > limit_bytes) return error.StreamTooLong;
        try body.appendSlice(arena, chunk[0..read]);
        if (read < chunk.len) break;
        try waitForReadable(fd, silence_ceiling_ms, request_timeout_ms);
    }
    return body.toOwnedSlice(arena);
}

/// Block until the socket has bytes to read, bounded by the silence ceiling.
/// Used before the head and again before the body: a blocking read that
/// outlives `SO_RCVTIMEO` panics instead of erroring, so the wait is done here
/// where a timeout is a typed error.
///
/// Which error it is depends on what was still on the clock. A ceiling shorter
/// than the request budget expiring means this one request went quiet while the
/// turn could still afford another, which is a stall the caller may reissue.
/// A ceiling that reaches the budget expiring means the budget itself is gone,
/// and reissuing would only fail again with nothing left to spend.
fn waitForReadable(fd: std.posix.fd_t, silence_ceiling_ms: i32, request_timeout_ms: i32) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, silence_ceiling_ms) catch
        return ClientError.DeepSeekServerUnavailable;
    if (ready != 0) return;
    if (silence_ceiling_ms < request_timeout_ms) return ClientError.DeepSeekGenerationStalled;
    return error.RequestTimedOut;
}

fn effectiveRequestTimeoutMs(request_timeout_ms: ?u64, ceiling_ms: i32) i32 {
    const ceiling: u64 = @intCast(ceiling_ms);
    return @intCast(@max(@as(u64, 1), @min(request_timeout_ms orelse ceiling, ceiling)));
}

/// The silence ceiling never exceeds the budget it sits inside. A configured
/// value at or above the budget collapses to the budget, which is the same
/// single-number behaviour as configuring nothing.
fn effectiveStallCeilingMs(stall_timeout_ms: ?u64, request_timeout_ms: i32) i32 {
    const configured = stall_timeout_ms orelse return request_timeout_ms;
    const budget: u64 = @intCast(request_timeout_ms);
    return @intCast(@max(@as(u64, 1), @min(configured, budget)));
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "base URL policy admits an HTTPS root and refuses everything else" {
    try validateBaseUrl("https://api.deepseek.com");
    try validateBaseUrl("https://api.deepseek.com/");
    try validateBaseUrl("https://api.deepseek.com/v1");
    try validateBaseUrl("https://gateway.example.com:8443/deepseek");

    const rejected = [_][]const u8{
        "http://api.deepseek.com",
        "http://127.0.0.1:8080",
        "https://user:secret@api.deepseek.com",
        "https://api.deepseek.com/v1?key=leak",
        "https://api.deepseek.com/v1#fragment",
        "https://api.deepseek.com/a/b",
        "api.deepseek.com",
        "",
    };
    for (rejected) |url| {
        try testing.expectError(ClientError.InvalidDeepSeekBaseUrl, validateBaseUrl(url));
    }
}

test "effectiveBaseUrl treats unset and blank alike" {
    try testing.expectEqualStrings(default_base_url, effectiveBaseUrl(null));
    try testing.expectEqualStrings(default_base_url, effectiveBaseUrl("   \t"));
    try testing.expectEqualStrings("https://gateway.example.com", effectiveBaseUrl(" https://gateway.example.com "));
}

test "the request body is the shared Chat Completions framing" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "inspect handler.ts" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequestBody(arena.allocator(), .{
        .api_key = "unused-in-body",
        .system_prompt = "zts expert",
        .tools_json = "[]",
    }, &transcript, null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings(default_model, root.get("model").?.string);
    try testing.expect(!root.get("stream").?.bool);
    try testing.expectEqual(@as(i64, default_max_tokens), root.get("max_tokens").?.integer);
    try testing.expectEqual(@as(usize, 0), root.get("tools").?.array.items.len);
    try testing.expect(root.get("tool_choice") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"api_key\"") == null);
    const messages = root.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
}

test "the request body refuses a non-HTTPS endpoint before building bytes" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.InvalidDeepSeekBaseUrl, buildRequestBody(arena.allocator(), .{
        .api_key = "k",
        .system_prompt = "s",
        .base_url = "http://api.deepseek.com",
    }, &transcript, null));
}

test "a text reply decodes with usage and no reasoning" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\"," ++
        "\"reasoning_content\":\"private chain\",\"content\":\"the handler is pure\"}}]," ++
        "\"usage\":{\"prompt_tokens\":21,\"completion_tokens\":6}}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), response);
    try testing.expectEqualStrings("the handler is pure", result.reply.response.final_text);
    try testing.expectEqual(@as(u64, 21), result.usage.input_tokens);
    try testing.expectEqual(@as(u64, 6), result.usage.output_tokens);
    try testing.expectEqualStrings("stop", result.stop_reason.?);
}

test "sanitizeResponse strips reasoning fields before capture" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{" ++
        "\"reasoning_content\":\"private chain\",\"reasoning\":\"also private\"," ++
        "\"content\":\"ok\"}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sanitized = try sanitizeResponse(arena.allocator(), response);
    try testing.expect(std.mem.indexOf(u8, sanitized, "private chain") == null);
    try testing.expect(std.mem.indexOf(u8, sanitized, "also private") == null);
    try testing.expect(std.mem.indexOf(u8, sanitized, "\"content\":\"ok\"") != null);
}

test "sanitizeResponse retains only tool-call reasoning continuation" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{" ++
        "\"reasoning_content\":\"continue exactly\",\"reasoning\":\"discard gateway field\"," ++
        "\"content\":null,\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"workspace_read_file\",\"arguments\":\"{}\"}}]}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sanitized = try sanitizeResponse(arena.allocator(), response);
    try testing.expect(std.mem.indexOf(u8, sanitized, "continue exactly") != null);
    try testing.expect(std.mem.indexOf(u8, sanitized, "discard gateway field") == null);
}

test "tool calls keep the ids DeepSeek assigned" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":null," ++
        "\"reasoning_content\":\"must be replayed\"," ++
        "\"tool_calls\":[{\"id\":\"call_0_abc\",\"type\":\"function\",\"function\":{" ++
        "\"name\":\"workspace_read_file\",\"arguments\":\"{\\\"path\\\":\\\"handler.ts\\\"}\"}}]}}]," ++
        "\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7}}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), response);
    const calls = result.reply.response.tool_calls;
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("call_0_abc", calls[0].id);
    try testing.expectEqualStrings("workspace_read_file", calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"handler.ts\"}", calls[0].args_json);
    try testing.expectEqualStrings("must be replayed", calls[0].reasoning_content.?);
    try testing.expect(result.reply.preamble == null);
    try testing.expectEqualStrings("tool_calls", result.stop_reason.?);
}

test "text alongside a tool call is kept as the preamble" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":\"reading it now\"," ++
        "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{" ++
        "\"name\":\"workspace_read_file\",\"arguments\":\"{}\"}}]}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), response);
    try testing.expectEqualStrings("reading it now", result.reply.preamble.?);
    try testing.expectEqual(@as(usize, 1), result.reply.response.tool_calls.len);
}

test "a propose_change_set tool call is remapped to a change set reply" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":null," ++
        "\"tool_calls\":[{\"id\":\"call_edit\",\"type\":\"function\",\"function\":{" ++
        "\"name\":\"propose_change_set\",\"arguments\":\"{\\\"changes\\\":[{\\\"file\\\":\\\"handler.ts\\\",\\\"content\\\":\\\"ok\\\"}]}\"}}]}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try decodeResponse(arena.allocator(), response);
    try testing.expectEqualStrings("handler.ts", result.reply.response.change_set.file);
    try testing.expectEqualStrings("ok", result.reply.response.change_set.content);
}

test "a truncated completion is an error, not a short answer" {
    const response =
        "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"half a han\"}}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.OutputTruncated, decodeResponse(arena.allocator(), response));
}

test "malformed responses are refused rather than half-decoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    try testing.expectError(ClientError.InvalidResponseJson, decodeResponse(ta, "not json"));
    try testing.expectError(ClientError.EmptyResponse, decodeResponse(ta, "{\"choices\":[]}"));
    try testing.expectError(
        ClientError.UnexpectedResponseShape,
        decodeResponse(ta, "{\"choices\":[{\"message\":\"text\"}]}"),
    );
    try testing.expectError(
        ClientError.EmptyResponse,
        decodeResponse(ta, "{\"choices\":[{\"message\":{\"content\":null}}]}"),
    );
    // A tool call with no id has no handle for the tool result to reference.
    try testing.expectError(ClientError.MalformedToolCall, decodeResponse(
        ta,
        "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"type\":\"function\"," ++
            "\"function\":{\"name\":\"workspace_read_file\",\"arguments\":\"{}\"}}]}}]}",
    ));
    // Arguments must be a JSON object; a bare string is not a tool input.
    try testing.expectError(ClientError.MalformedToolCall, decodeResponse(
        ta,
        "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\"," ++
            "\"function\":{\"name\":\"workspace_read_file\",\"arguments\":\"\\\"nope\\\"\"}}]}}]}",
    ));
}

/// Stands in for the socket: asserts the request the client built, then hands
/// back a canned response body.
fn stubPost(arena: std.mem.Allocator, config: Config, body: []const u8) !TransportResponse {
    _ = arena;
    try testing.expectEqualStrings("test-key", config.api_key);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hello\"") != null);
    return .{ .ok = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"done\"}}]," ++
        "\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}" };
}

test "sendTurn drives the request through the injected transport" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "hello" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var client = Client.init(.{ .api_key = "test-key", .system_prompt = "zts expert" });
    const result = try client.sendTurnWithPost(arena.allocator(), &transcript, null, stubPost);
    try testing.expectEqualStrings("done", result.reply.response.final_text);
    try testing.expectEqual(@as(u64, 3), result.usage.input_tokens);
    try testing.expectEqual(@as(u64, 1), result.usage.output_tokens);
}

const FailureDiagnosticProbe = struct {
    diagnostic_count: usize = 0,
    captured_count: usize = 0,
    http_status: ?u16 = null,
    failure: ?anyerror = null,

    fn record(
        context: *anyopaque,
        _: usize,
        _: *const model_request.ModelRequestSnapshot,
        _: []const u8,
    ) anyerror!void {
        const self: *FailureDiagnosticProbe = @ptrCast(@alignCast(context));
        self.captured_count += 1;
    }

    fn diagnose(
        context: *anyopaque,
        _: usize,
        _: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) anyerror!void {
        const self: *FailureDiagnosticProbe = @ptrCast(@alignCast(context));
        self.diagnostic_count += 1;
        self.http_status = diagnostics.http_status;
        self.failure = diagnostics.failure;
    }
};

fn rateLimitedPost(_: std.mem.Allocator, _: Config, _: []const u8) !TransportResponse {
    return .{ .http_error = .{
        .status_code = 429,
        .body = "{\"error\":{\"message\":\"rate limit reached\"}}",
    } };
}

test "provider rejection records status without capturing response content" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "hello" });

    var probe: FailureDiagnosticProbe = .{};
    var sink: capture_sink.CaptureSink = .{
        .context = &probe,
        .record_fn = FailureDiagnosticProbe.record,
        .diagnostics_fn = FailureDiagnosticProbe.diagnose,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var client = Client.initWithCapture(
        .{ .api_key = "test-key", .system_prompt = "zts expert" },
        &sink,
    );
    try testing.expectError(
        error.RateLimited,
        client.sendTurnWithPost(arena.allocator(), &transcript, null, rateLimitedPost),
    );
    try testing.expectEqual(@as(usize, 0), probe.captured_count);
    try testing.expectEqual(@as(usize, 1), probe.diagnostic_count);
    try testing.expectEqual(@as(?u16, 429), probe.http_status);
    try testing.expectEqual(error.RateLimited, probe.failure.?);
}

test "the socket read timeout is never the first thing to expire" {
    // A read that outlives SO_RCVTIMEO is EAGAIN, which Zig 0.16 panics on, so
    // the socket value must be unreachable by anything healthy and must never be
    // whatever the turn had left. It was the latter, which made the panic
    // reachable on every call, and it fired mid-corpus on durable-order call 3
    // after four cases had already staged.
    try testing.expectEqual(generation_ceiling_ms, socket_read_timeout_ms);

    // Every poll the request makes has to expire first, so a stall surfaces as a
    // typed error rather than as a dead process. Checked at the recording budget
    // and at a nearly spent one, which is the case the old code got wrong.
    const recording_budget: i32 = 600_000;
    const stall: u64 = 300_000;
    try testing.expect(effectiveStallCeilingMs(stall, recording_budget) < socket_read_timeout_ms);
    try testing.expect(effectiveStallCeilingMs(stall, 1_000) < socket_read_timeout_ms);
    try testing.expect(effectiveStallCeilingMs(null, recording_budget) < socket_read_timeout_ms);

    // And the request budget itself, which the socket used to be set from, is
    // always at or below the ceiling - so setting the socket from it could only
    // ever make the socket expire first or tie.
    try testing.expect(effectiveRequestTimeoutMs(600_000, generation_ceiling_ms) < socket_read_timeout_ms);
    try testing.expectEqual(
        socket_read_timeout_ms,
        effectiveRequestTimeoutMs(null, generation_ceiling_ms),
    );
}

test "a mid-body stall expires on the silence ceiling, not on the socket" {
    // The gap the two request-side polls left: they cover the wait before the
    // head and the wait before the first body byte, and `readBody` then read to
    // end of stream in one call. The only bound left on a stall after the first
    // byte was SO_RCVTIMEO, which is the 15-minute generation ceiling, so an
    // interactive turn with a 60s deadline sat silent for the whole ceiling.
    const allocator = testing.allocator;

    // A socket pair stands in for the connection: one end is readable while it
    // holds a byte and blocks once drained, which is the shape a stall has.
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var pipe_fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &pipe_fds,
    ))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(pipe_fds[0]);
    defer std.Io.Threaded.closeFd(pipe_fds[1]);

    // A body of exactly one chunk: the loop takes it, sees a full buffer, and
    // polls because more is expected. Nothing arrives.
    const stalled_payload = try allocator.alloc(u8, 4096);
    defer allocator.free(stalled_payload);
    @memset(stalled_payload, 'x');
    var stalled_reader = std.Io.Reader.fixed(stalled_payload);
    try testing.expectError(
        ClientError.DeepSeekGenerationStalled,
        readBodyWithin(&stalled_reader, allocator, 1 << 20, pipe_fds[0], 20, 1_000),
    );

    // With the ceiling at the budget the same silence is exhaustion, not a
    // stall - the distinction the ceiling exists to draw.
    var spent_reader = std.Io.Reader.fixed(stalled_payload);
    try testing.expectError(
        error.RequestTimedOut,
        readBodyWithin(&spent_reader, allocator, 1 << 20, pipe_fds[0], 20, 20),
    );

    // The floor under both: a body that arrives is read whole, across chunks,
    // and a poll between them does not truncate it.
    _ = std.posix.system.write(pipe_fds[1], "ready", 5);
    const whole_payload = try allocator.alloc(u8, 4096 * 2 + 7);
    defer allocator.free(whole_payload);
    for (whole_payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var whole_reader = std.Io.Reader.fixed(whole_payload);
    const body = try readBodyWithin(&whole_reader, allocator, 1 << 20, pipe_fds[0], 20, 1_000);
    defer allocator.free(body);
    try testing.expectEqualSlices(u8, whole_payload, body);

    // And the size limit still refuses a body over the cap.
    var large_reader = std.Io.Reader.fixed(whole_payload);
    try testing.expectError(
        error.StreamTooLong,
        readBodyWithin(&large_reader, allocator, 4096, pipe_fds[0], 20, 1_000),
    );
}

test "a silence ceiling separates a stalled request from a spent budget" {
    // One number answered both questions and the two failures were then
    // indistinguishable: a turn whose 600s budget drained across fifteen calls
    // and a single generation that hung for the whole 600s both reported
    // RequestTimedOut, and only one of them is worth reissuing.
    const budget_ms: i32 = 600_000;
    const stall_ms: u64 = 300_000;

    // Inside the budget, so an expiry still leaves the turn something to spend.
    try testing.expectEqual(@as(i32, 300_000), effectiveStallCeilingMs(stall_ms, budget_ms));

    // Once the turn has less left than the ceiling, the ceiling is the budget,
    // and an expiry is exhaustion rather than a stall.
    try testing.expectEqual(@as(i32, 120_000), effectiveStallCeilingMs(stall_ms, 120_000));

    // Configuring nothing keeps the single-number behaviour interactive use has.
    try testing.expectEqual(@as(i32, 600_000), effectiveStallCeilingMs(null, budget_ms));

    // A ceiling at or above the budget is the same as none, so it can never
    // report a stall the turn cannot actually afford to retry.
    try testing.expectEqual(@as(i32, 600_000), effectiveStallCeilingMs(600_000, budget_ms));
    try testing.expectEqual(@as(i32, 600_000), effectiveStallCeilingMs(900_000, budget_ms));

    // Zero would be an instant, permanent stall on a healthy socket.
    try testing.expectEqual(@as(i32, 1), effectiveStallCeilingMs(0, budget_ms));
}
