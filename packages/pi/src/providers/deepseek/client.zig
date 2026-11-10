//! Non-streaming Chat Completions adapter for the DeepSeek API.
//!
//! DeepSeek serves an OpenAI-compatible `/chat/completions` endpoint, so this is
//! a sibling of `local/client.zig`: the same request body, a different endpoint
//! policy and a different decoder.
//!
//! Two things differ from the local adapter. The endpoint is remote, so the
//! transport requires HTTPS and a bearer credential. And DeepSeek returns
//! tool-call ids of its own, so ids are taken from the response instead of
//! being synthesized from a request digest, and the `<|tool_call_start|>`
//! envelope the local LFM model emits has no counterpart here.

const std = @import("std");
const loop = @import("../../loop.zig");
const turn = @import("../../turn.zig");
const transcript_mod = @import("../../transcript.zig");
const registry_mod = @import("../../registry/registry.zig");
const propose_change_set = @import("../propose_change_set.zig");
const http_errors = @import("../http_errors.zig");
const model_request = @import("../model_request.zig");
const context_budget = @import("../../context_budget.zig");
const model_registry = @import("../models.zig");
const capture_sink = @import("../capture_sink.zig");
const chat_completions = @import("../chat_completions.zig");
const response_fields = @import("../response_fields.zig");
const response_sanitize = @import("../response_sanitize.zig");
const max_response_body_bytes = response_sanitize.max_response_body_bytes;
const max_tool_name_bytes = response_fields.max_tool_name_bytes;
const optionalString = response_fields.optionalString;
const requiredString = response_fields.requiredString;
const nonEmpty = response_fields.nonEmpty;
const decodeUsage = response_fields.decodeUsage;
const validateJsonArguments = response_fields.validateJsonArguments;
const validToolName = response_fields.validToolName;

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
const max_tool_calls: usize = 16;

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
    AbnormalFinish,
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
    const host = http_errors.uriHost(uri, &host_buf) catch return ClientError.InvalidDeepSeekBaseUrl;
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
    return arena.print("{s}{s}", .{
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

const SanitizedResponse = response_sanitize.SanitizedResponse;
const ResponseInspection = response_sanitize.ResponseInspection;
const monotonicNowNs = response_sanitize.monotonicNowNs;
const elapsedMs = response_sanitize.elapsedMs;

/// DeepSeek V4 requires reasoning_content from tool-call messages to be passed
/// back verbatim on subsequent requests, so that continuation stays.
const reasoning_rule: response_sanitize.ReasoningRule = .keep_tool_call_continuation;

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
    return response_sanitize.parseSanitizedResponseWithInspection(arena, response_body, inspection, reasoning_rule);
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
        // "content_filter" and "insufficient_system_resource" end the reply on
        // partial text, so only a natural stop or a tool call may decode.
        if (!std.mem.eql(u8, reason, "stop") and !std.mem.eql(u8, reason, "tool_calls")) {
            return ClientError.AbnormalFinish;
        }
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
    // system trust store and stamp `now` here.
    const now = std.Io.Clock.real.now(io);
    client.ca_bundle.rescan(arena, io, now) catch return error.CertificateBundleLoadFailure;
    client.now = now;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return ClientError.InvalidDeepSeekBaseUrl;
    if (protocol != .tls) return ClientError.InvalidDeepSeekBaseUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = http_errors.uriHost(uri, &host_buf) catch return ClientError.InvalidDeepSeekBaseUrl;
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
    const request_started_ns = monotonicNowNs();
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
    const authorization = try arena.print("Bearer {s}", .{config.api_key});
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

    var response = http_errors.receiveHeadWithin(
        &request,
        silence_ceiling_ms,
        remainingMs(request_started_ns, request_timeout_ms),
    ) catch |err| switch (err) {
        error.RequestTimedOut => return error.RequestTimedOut,
        error.RequestStalled => return ClientError.DeepSeekGenerationStalled,
        else => return ClientError.DeepSeekServerUnavailable,
    };
    // The wait covers the silence before the first body byte. It is skipped when
    // decrypted body bytes are already buffered, because the socket can then be
    // silent with the body complete. A partial encrypted record still needs the
    // socket, so the ciphertext reader is not checked here.
    if (connection.reader().bufferedLen() == 0) {
        try waitForReadable(
            connection.stream_reader.stream.socket.handle,
            silence_ceiling_ms,
            remainingMs(request_started_ns, request_timeout_ms),
        );
    }
    const declared_len = http_errors.declaredBodyLength(response.head);
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
        remainingMs(request_started_ns, request_timeout_ms),
        &.{ connection.reader(), &connection.stream_reader.interface },
        declared_len,
    ) catch |err| switch (err) {
        error.StreamTooLong => return ClientError.ResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTimedOut => return error.RequestTimedOut,
        error.RequestStalled => return ClientError.DeepSeekGenerationStalled,
        else => return ClientError.DeepSeekServerUnavailable,
    };
    if (response.head.status != .ok) {
        return .{ .http_error = .{
            .status_code = @backingInt(response.head.status),
            .body = response_body,
        } };
    }
    return .{ .ok = response_body };
}

const readBodyWithin = http_errors.readBodyWithin;
const remainingMs = http_errors.remainingMs;
const effectiveRequestTimeoutMs = http_errors.effectiveRequestTimeoutMs;

/// The shared wait, with its outcomes named for this provider. A stall is one
/// request that went quiet while the turn could still afford another, which the
/// caller may reissue.
fn waitForReadable(fd: std.posix.fd_t, silence_ceiling_ms: i32, request_timeout_ms: i32) !void {
    http_errors.waitForReadable(fd, silence_ceiling_ms, request_timeout_ms) catch |err| return switch (err) {
        error.RequestTimedOut => error.RequestTimedOut,
        error.RequestStalled => ClientError.DeepSeekGenerationStalled,
        error.PollFailed => ClientError.DeepSeekServerUnavailable,
    };
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
    // and at a nearly spent one.
    const recording_budget: i32 = 600_000;
    const stall: u64 = 300_000;
    try testing.expect(effectiveStallCeilingMs(stall, recording_budget) < socket_read_timeout_ms);
    try testing.expect(effectiveStallCeilingMs(stall, 1_000) < socket_read_timeout_ms);
    try testing.expect(effectiveStallCeilingMs(null, recording_budget) < socket_read_timeout_ms);

    // And the request budget itself is always at or below the ceiling - so
    // setting the socket from it could only ever make the socket expire first
    // or tie.
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
        error.RequestStalled,
        readBodyWithin(&stalled_reader, allocator, 1 << 20, pipe_fds[0], 20, 1_000, &.{}, null),
    );

    // With the ceiling at the budget the same silence is exhaustion, not a
    // stall - the distinction the ceiling exists to draw.
    var spent_reader = std.Io.Reader.fixed(stalled_payload);
    try testing.expectError(
        error.RequestTimedOut,
        readBodyWithin(&spent_reader, allocator, 1 << 20, pipe_fds[0], 20, 20, &.{}, null),
    );

    // The floor under both: a body that arrives is read whole, across chunks,
    // and a poll between them does not truncate it.
    _ = std.posix.system.write(pipe_fds[1], "ready", 5);
    const whole_payload = try allocator.alloc(u8, 4096 * 2 + 7);
    defer allocator.free(whole_payload);
    for (whole_payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var whole_reader = std.Io.Reader.fixed(whole_payload);
    const body = try readBodyWithin(&whole_reader, allocator, 1 << 20, pipe_fds[0], 20, 1_000, &.{}, null);
    defer allocator.free(body);
    try testing.expectEqualSlices(u8, whole_payload, body);

    // And the size limit still refuses a body over the cap.
    var large_reader = std.Io.Reader.fixed(whole_payload);
    try testing.expectError(
        error.StreamTooLong,
        readBodyWithin(&large_reader, allocator, 4096, pipe_fds[0], 20, 1_000, &.{}, null),
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

test "the wait on a silent socket names a stall and a spent budget for DeepSeek" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    try testing.expectError(ClientError.DeepSeekGenerationStalled, waitForReadable(fds[0], 20, 1_000));
    try testing.expectError(error.RequestTimedOut, waitForReadable(fds[0], 20, 20));
}

fn shutdownPeerAfterTwoSeconds(fd: std.posix.fd_t) void {
    std.Io.sleep(testing.io, .fromMilliseconds(2000), .awake) catch {};
    _ = std.posix.system.shutdown(fd, 1);
}

test "a body that trickles in below one chunk and then goes silent stalls on the silence ceiling" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    _ = std.posix.system.write(fds[1], "0123456789", 10);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(testing.io, &buf);

    // The watchdog closes the peer after 2 s so a defective read returns
    // instead of hanging the suite.
    const watchdog = try std.Thread.spawn(.{}, shutdownPeerAfterTwoSeconds, .{fds[1]});
    const started = monotonicNowNs().?;
    const result = readBodyWithin(&stream_reader.interface, testing.allocator, 1 << 20, fds[0], 20, 1_000, &.{}, null);
    const elapsed = elapsedMs(started).?;
    watchdog.join();
    defer if (result) |body| testing.allocator.free(body) else |_| {};
    try testing.expectError(error.RequestStalled, result);
    try testing.expect(elapsed < 500);
}

fn trickleSixtyBytes(fd: std.posix.fd_t) void {
    var sent: usize = 0;
    while (sent < 60) : (sent += 1) {
        std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
        _ = std.posix.system.write(fd, "x", 1);
    }
    _ = std.posix.system.shutdown(fd, 1);
}

test "a body that keeps trickling past the request budget times out" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(testing.io, &buf);

    // One byte every 20 ms never lets one silence poll expire, so only the
    // request budget can end the read. The peer closes after about 1.2 s.
    const trickler = try std.Thread.spawn(.{}, trickleSixtyBytes, .{fds[1]});
    const started = monotonicNowNs().?;
    const result = readBodyWithin(&stream_reader.interface, testing.allocator, 1 << 20, fds[0], 100, 300, &.{}, null);
    const elapsed = elapsedMs(started).?;
    trickler.join();
    defer if (result) |body| testing.allocator.free(body) else |_| {};
    try testing.expectError(error.RequestTimedOut, result);
    try testing.expect(elapsed < 800);
}

test "bytes that a lower reader already holds are read without polling the silent socket" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    _ = std.posix.system.write(fds[1], "0123456789", 10);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var lower_buf: [4096]u8 = undefined;
    var lower = stream.reader(testing.io, &lower_buf);
    // The lower reader takes the bytes off the socket, so the socket is silent now.
    try lower.interface.fill(10);
    var upper_buf: [4096]u8 = undefined;
    var upper = std.Io.Reader.limited(&lower.interface, .limited(10), &upper_buf);

    // A false stall would surface as DeepSeekGenerationStalled. The 9-byte
    // limit makes the first pass end in the size refusal instead.
    const lowers = [_]*const std.Io.Reader{&lower.interface};
    try testing.expectError(
        error.StreamTooLong,
        readBodyWithin(&upper.interface, testing.allocator, 9, fds[0], 20, 1_000, &lowers, null),
    );
}

test "a body that the peer closes before its declared length is a truncated body" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    _ = std.posix.system.write(fds[1], "01234", 5);
    _ = std.posix.system.shutdown(fds[1], 1);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(testing.io, &buf);
    const result = readBodyWithin(&stream_reader.interface, testing.allocator, 1 << 20, fds[0], 20, 1_000, &.{}, 10);
    defer if (result) |body| testing.allocator.free(body) else |_| {};
    try testing.expectError(error.BodyTruncated, result);
}

test "a body that reaches its declared length ends without polling the silent socket" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    var reader = std.Io.Reader.fixed("0123456789");
    const body = try readBodyWithin(&reader, testing.allocator, 1 << 20, fds[0], 20, 1_000, &.{}, 10);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("0123456789", body);
}

test "a response head that stops part way names a stall and a spent budget" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    _ = std.posix.system.write(fds[1], "HTTP/1.1 200 OK\r\nContent-Le", 27);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(testing.io, &buf);
    const reader = &stream_reader.interface;
    try testing.expectError(error.RequestStalled, http_errors.fillHeadWithin(reader, 4096, fds[0], 20, 1_000, null));
    try testing.expectError(error.RequestTimedOut, http_errors.fillHeadWithin(reader, 4096, fds[0], 20, 20, null));

    // The floor under both: the rest of the head arrives, and the fill ends
    // with the whole head in the reader.
    _ = std.posix.system.write(fds[1], "ngth: 0\r\n\r\n", 11);
    try http_errors.fillHeadWithin(reader, 4096, fds[0], 20, 1_000, null);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", reader.buffered());
}

/// Stands in for the reader of the std TLS client, which exists only after a
/// handshake that no test peer can answer. It takes whole records off `input`
/// with the reads that the TLS client makes, and passes each payload on as it
/// arrived.
const RecordReader = struct {
    input: *std.Io.Reader,
    interface: std.Io.Reader,

    fn init(input: *std.Io.Reader, buffer: []u8) RecordReader {
        return .{ .input = input, .interface = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return readRecord(r);
    }

    fn readVec(r: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
        return readRecord(r);
    }

    fn readRecord(r: *std.Io.Reader) std.Io.Reader.Error!usize {
        const self: *RecordReader = @alignCast(@fieldParentPtr("interface", r));
        const header = try self.input.peek(5);
        const record_len = 5 + @as(usize, std.mem.readInt(u16, header[3..5], .big));
        if (record_len > self.input.bufferedLen()) {
            try self.input.fillMore();
            if (record_len > self.input.bufferedLen()) return 0;
        }
        const payload = (try self.input.take(record_len))[5..];
        @memcpy(r.buffer[r.end..][0..payload.len], payload);
        r.end += payload.len;
        return 0;
    }
};

test "a TLS record that stops part way stalls the head on the silence ceiling" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    // The record header declares 38 bytes, and 27 of them arrive.
    _ = std.posix.system.write(fds[1], "\x17\x03\x03\x00\x26HTTP/1.1 200 OK\r\nContent-Le", 32);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var input_buf: [4096]u8 = undefined;
    var input = stream.reader(testing.io, &input_buf);
    var records_buf: [4096]u8 = undefined;
    var records: RecordReader = .init(&input.interface, &records_buf);

    // The watchdog closes the peer after 2 s so a defective read returns
    // instead of hanging the suite.
    const watchdog = try std.Thread.spawn(.{}, shutdownPeerAfterTwoSeconds, .{fds[1]});
    const started = monotonicNowNs().?;
    const result = http_errors.fillHeadWithin(&records.interface, 4096, fds[0], 20, 1_000, &input.interface);
    const elapsed = elapsedMs(started).?;
    watchdog.join();
    try testing.expectError(error.RequestStalled, result);
    try testing.expect(elapsed < 500);
}

test "a whole TLS record that the socket reader holds completes the head without a wait" {
    if (@TypeOf(std.posix.system.socketpair) == void) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);
    _ = std.posix.system.write(fds[1], "\x17\x03\x03\x00\x26HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 43);

    var stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = undefined } };
    var input_buf: [4096]u8 = undefined;
    var input = stream.reader(testing.io, &input_buf);
    // The socket reader takes the record off the socket, so the socket is silent now.
    try input.interface.fill(43);
    var records_buf: [4096]u8 = undefined;
    var records: RecordReader = .init(&input.interface, &records_buf);

    try http_errors.fillHeadWithin(&records.interface, 4096, fds[0], 20, 1_000, &input.interface);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", records.interface.buffered());
}

const SilentPeer = struct {
    listener: std.Io.net.Server,
    io: std.Io,

    /// Accepts one connection and never answers it. Closes it after 2 s so a
    /// defective connect returns instead of hanging the suite.
    fn run(self: *SilentPeer) void {
        const io = self.io;
        var stream = self.listener.accept(io) catch return;
        defer stream.close(io);
        std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
    }
};

test "a TLS handshake that the peer never answers ends at the connect budget" {
    const allocator = testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var peer: SilentPeer = .{ .listener = try address.listen(io, .{ .reuse_address = true }), .io = io };
    defer peer.listener.deinit(io);
    const port = peer.listener.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, SilentPeer.run, .{&peer});
    defer thread.join();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    client.now = std.Io.Clock.real.now(io);
    const started = monotonicNowNs().?;
    const result = http_errors.connectWithin(&client, .{ .bytes = "127.0.0.1" }, port, .tls, 200);
    const elapsed = elapsedMs(started).?;
    try testing.expectError(error.RequestTimedOut, result);
    try testing.expect(elapsed < 1000);
}

test "a completion that the provider cut off for another reason is an error, not a short answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(ClientError.AbnormalFinish, decodeResponse(
        arena.allocator(),
        "{\"choices\":[{\"finish_reason\":\"content_filter\",\"message\":{\"content\":\"half a han\"}}]}",
    ));
    try testing.expectError(ClientError.AbnormalFinish, decodeResponse(
        arena.allocator(),
        "{\"choices\":[{\"finish_reason\":\"insufficient_system_resource\",\"message\":{\"content\":\"half a han\"}}]}",
    ));
}
