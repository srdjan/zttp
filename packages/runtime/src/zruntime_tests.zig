//! Test root for the runtime package's handler instance.
//!
//! The instance itself is `handler_instance.HandlerInstance`. This file holds
//! the end-to-end tests that drive it - durable runs, workflow dispatch,
//! fetch, WebSocket, JSX - together with the loopback HTTP server they need.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("zts").compat;
const ascii = std.ascii;

/// The egress policy entry for a URL, since policy names endpoints and a test
/// server's port is only known once it is listening. Writing `127.0.0.1` in a
/// fixture would name a destination the handler never reaches.
fn egressEndpoint(url: []const u8, out: []u8) []const u8 {
    return @import("zts").endpoint.normalize(url, out) catch unreachable;
}

// Import zts module
const zq = @import("zts");
const durable_store_mod = @import("durable_store.zig");
const durable_fetch = @import("durable_fetch.zig");
const durable_executor = @import("durable_executor.zig");
const workflow_queue = @import("workflow_queue.zig");
const actor_queue = @import("actor_queue.zig");
const queue_callbacks = @import("queue_runtime_callbacks.zig");
const fault_explain = @import("fault_explain.zig");
const incident_log = @import("incident_log.zig");
const workflow = @import("runtime_workflow.zig");
const http = @import("runtime_http.zig");
const natives = @import("runtime_natives.zig");

// Force-reference so this root collects the attestation receipt's tests. A
// container-level import that nothing else in the graph analyzes does not pull
// its tests in, and a test that is never collected reports the same green as
// one that passes.
comptime {
    _ = @import("attest/build_receipt.zig");
}

// Helpers in runtime_http.zig that the tests below call unqualified.
const buildFetchUrl = http.buildFetchUrl;
const buildServiceUrl = http.buildServiceUrl;
const parseFetchArgs = http.parseFetchArgs;

// Bytecode caching for faster cold starts
const bytecode_cache = zq.bytecode_cache;

// HTTP protocol types (shared with server layer)
const http_types = @import("http_types.zig");
const HttpRequestView = http_types.HttpRequestView;
const HttpRequestOwned = http_types.HttpRequestOwned;

const runtime_config_mod = @import("runtime_config.zig");
const cost_meter = zq.CostMeter;

const RuntimeConfig = runtime_config_mod.RuntimeConfig;
const RuntimePolicyGeneration = @import("runtime_policy_generation.zig").RuntimePolicyGeneration;

/// In-process registry of co-located sub-handlers, used by zttp:workflow to
/// dispatch from an orchestrator handler without HTTP.
const SystemRuntime = @import("in_process_dispatch.zig").SystemRuntime;

test {
    // Force collection of in_process_dispatch.zig tests under test-zruntime.
    _ = @import("in_process_dispatch.zig");
    _ = @import("actor_queue.zig");
    _ = @import("queue_runtime_callbacks.zig");
}

const openOplogFile = runtime_config_mod.openOplogFile;
const tryLockOplogFd = runtime_config_mod.tryLockOplogFd;
const applyEmbeddedCapabilityPolicy = runtime_config_mod.applyEmbeddedCapabilityPolicy;

// ============================================================================
// File reading for module graph (POSIX, no async I/O dependency)
// ============================================================================

const handler_instance = @import("handler_instance.zig");
const HandlerInstance = handler_instance.HandlerInstance;
const OutboundIo = @import("outbound_io.zig").OutboundIo;
const AotOverrideFn = handler_instance.AotOverrideFn;
const setAotOverrideForTest = handler_instance.setAotOverrideForTest;

// ===========================================================================
// WebSocket runtime callbacks (W1-d.4-b)
// ===========================================================================

// ============================================================================
// Percentile Tracker for Latency Metrics
// ============================================================================

/// Mutex-protected ring buffer that records nanosecond-resolution latency samples.
/// Used only for diagnostic metrics in debug builds, so we prefer correctness
/// under contention over lock-free writes.

// ============================================================================
// Handler Pool (Lock-Free)
// ============================================================================

/// Lock-free pool of pre-initialized JavaScript runtimes, backed by zts.LockFreePool.
/// Uses per-runtime wrappers to install builtins and load handler code once.

// ============================================================================
// Tests
// ============================================================================

const TestErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

const TestCapturedHeader = struct {
    name: []u8,
    value: []u8,
};

const TestCapturedRequest = struct {
    method: []u8,
    path: []u8,
    headers: std.ArrayListUnmanaged(TestCapturedHeader) = .empty,
    body: []u8,
    raw: []u8,

    fn deinit(self: *TestCapturedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        for (self.headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        self.headers.deinit(allocator);
        allocator.free(self.body);
        allocator.free(self.raw);
    }

    fn getHeader(self: *const TestCapturedRequest, name: []const u8) ?[]const u8 {
        var i = self.headers.items.len;
        while (i > 0) {
            i -= 1;
            const item = self.headers.items[i];
            if (ascii.eqlIgnoreCase(item.name, name)) {
                return item.value;
            }
        }
        return null;
    }
};

const TestHttpServer = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    mode: Mode,
    thread: ?std.Thread = null,
    closed: bool = false,
    thread_error: std.atomic.Value(TestErrorInt) = std.atomic.Value(TestErrorInt).init(0),
    // Only consulted when mode == .sequenced_status: one status code per
    // accepted connection, in order.
    status_sequence: []const u16 = &.{},

    const Mode = enum {
        echo_request_json,
        large_plain_text,
        silent_hold,
        sequenced_status,
    };

    fn init(allocator: std.mem.Allocator, mode: Mode) !TestHttpServer {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        const io = io_backend.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try address.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io_backend = io_backend,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .mode = mode,
        };
    }

    fn start(self: *TestHttpServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn url(self: *const TestHttpServer, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    fn join(self: *TestHttpServer) !void {
        if (self.closed) return;
        self.closed = true;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const io = self.io_backend.io();
        self.listener.deinit(io);
        self.io_backend.deinit();
        const err_int = self.thread_error.swap(0, .acq_rel);
        if (err_int != 0) {
            return @errorFromInt(err_int);
        }
    }

    fn run(self: *TestHttpServer) void {
        self.runInner() catch |err| {
            self.thread_error.store(@intFromError(err), .release);
        };
    }

    fn runInner(self: *TestHttpServer) !void {
        const io = self.io_backend.io();

        if (self.mode == .sequenced_status) {
            for (self.status_sequence) |status| {
                var stream = while (true) {
                    break self.listener.accept(io) catch |err| switch (err) {
                        error.ConnectionAborted => continue,
                        error.SocketNotListening => return,
                        else => return err,
                    };
                };
                defer stream.close(io);
                try self.respondWithStatus(&stream, io, status);
            }
            return;
        }

        var stream = while (true) {
            break self.listener.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                error.SocketNotListening => return,
                else => return err,
            };
        };
        defer stream.close(io);

        switch (self.mode) {
            .echo_request_json => try self.respondWithEcho(&stream, io),
            .large_plain_text => try self.respondWithLargeBody(&stream, io),
            .silent_hold => try self.holdSilently(&stream, io),
            .sequenced_status => unreachable,
        }
    }

    /// Accepts the request but never writes a byte back; returns once the
    /// client gives up and closes its end.
    fn holdSilently(self: *TestHttpServer, stream: *std.Io.net.Stream, io: std.Io) !void {
        _ = self;
        while (true) {
            var chunk: [1024]u8 = undefined;
            var vecs: [1][]u8 = .{chunk[0..]};
            const n = io.vtable.netRead(io.userdata, stream.socket.handle, &vecs) catch break;
            if (n == 0) break;
        }
    }

    fn respondWithEcho(self: *TestHttpServer, stream: *std.Io.net.Stream, io: std.Io) !void {
        var captured = try captureRequest(self.allocator, stream, io);
        defer captured.deinit(self.allocator);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var json: std.json.Stringify = .{ .writer = &aw.writer };
        try json.beginObject();
        try json.objectField("method");
        try json.write(captured.method);
        try json.objectField("path");
        try json.write(captured.path);
        try json.objectField("contentType");
        try json.write(captured.getHeader("content-type") orelse "");
        try json.objectField("xTest");
        try json.write(captured.getHeader("x-test") orelse "");
        try json.objectField("contentLength");
        try json.write(captured.getHeader("content-length") orelse "");
        try json.objectField("transferEncoding");
        try json.write(captured.getHeader("transfer-encoding") orelse "");
        try json.objectField("body");
        try json.write(captured.body);
        try json.objectField("raw");
        try json.write(captured.raw);
        try json.endObject();
        const body = try aw.toOwnedSlice();
        defer self.allocator.free(body);

        try writeTestResponse(stream, io, 201, "Created", &.{
            "Content-Type: application/json",
            "x-reply: ok",
        }, body);
    }

    fn respondWithLargeBody(self: *TestHttpServer, stream: *std.Io.net.Stream, io: std.Io) !void {
        _ = self;
        try writeTestResponse(
            stream,
            io,
            200,
            "OK",
            &.{"Content-Type: text/plain"},
            "0123456789abcdef0123456789abcdef",
        );
    }

    fn respondWithStatus(self: *TestHttpServer, stream: *std.Io.net.Stream, io: std.Io, status: u16) !void {
        var captured = try captureRequest(self.allocator, stream, io);
        defer captured.deinit(self.allocator);
        const reason: []const u8 = if (status >= 500) "Internal Server Error" else "OK";
        try writeTestResponse(stream, io, status, reason, &.{"Content-Type: text/plain"}, "");
    }
};

fn captureRequest(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, io: std.Io) !TestCapturedRequest {
    const raw = try readRawRequestBytes(allocator, stream, io);
    errdefer allocator.free(raw);
    const header_sep = findTestHeaderEnd(raw) orelse return error.InvalidTestRequest;
    const header_end = header_sep + 4;
    const request_head = raw[0..header_sep];
    const line_end = std.mem.indexOf(u8, request_head, "\r\n") orelse return error.InvalidTestRequest;
    const request_line = request_head[0..line_end];
    const first_space = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidTestRequest;
    const rest = request_line[first_space + 1 ..];
    const second_space_rel = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidTestRequest;

    const method = try allocator.dupe(u8, request_line[0..first_space]);
    errdefer allocator.free(method);
    const path = try allocator.dupe(u8, rest[0..second_space_rel]);
    errdefer allocator.free(path);

    var headers: std.ArrayListUnmanaged(TestCapturedHeader) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }
    var line_start = line_end + 2;
    while (line_start < request_head.len) {
        const next_line_end = std.mem.indexOfPos(u8, request_head, line_start, "\r\n") orelse request_head.len;
        if (next_line_end == line_start) break;
        const line = request_head[line_start..next_line_end];

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);
        try headers.append(allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
        line_start = next_line_end + 2;
    }

    const body = try allocator.dupe(u8, raw[header_end..]);
    errdefer allocator.free(body);

    return .{
        .method = method,
        .path = path,
        .headers = headers,
        .body = body,
        .raw = raw,
    };
}

fn readRawRequestBytes(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, io: std.Io) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    while (true) {
        var chunk: [1024]u8 = undefined;
        var vecs: [1][]u8 = .{chunk[0..]};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, &vecs) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break;
        try raw.appendSlice(allocator, chunk[0..n]);
        if (requestMessageLength(raw.items)) |message_len| {
            if (message_len < raw.items.len) {
                try raw.resize(allocator, message_len);
            }
            break;
        }
    }

    return try raw.toOwnedSlice(allocator);
}

fn findTestHeaderEnd(raw: []const u8) ?usize {
    return std.mem.indexOf(u8, raw, "\r\n\r\n") orelse null;
}

fn requestMessageLength(raw: []const u8) ?usize {
    const header_sep = findTestHeaderEnd(raw) orelse return null;
    const header_end = header_sep + 4;
    const header_block = raw[0..header_sep];

    var content_length: ?usize = null;
    var chunked = false;
    var line_start: usize = 0;
    while (line_start < header_block.len) {
        const line_end = std.mem.indexOfPos(u8, header_block, line_start, "\r\n") orelse header_block.len;
        const line = header_block[line_start..line_end];
        line_start = line_end + 2;
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return null;
        } else if (ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = ascii.indexOfIgnoreCase(value, "chunked") != null;
        }
    }

    if (chunked) {
        const body_len = chunkedBodyLength(raw[header_end..]) orelse return null;
        return header_end + body_len;
    }
    if (content_length) |len| {
        if (raw.len < header_end + len) return null;
        return header_end + len;
    }
    return header_end;
}

fn chunkedBodyLength(body: []const u8) ?usize {
    var idx: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, body, idx, "\r\n") orelse return null;
        const size_line = body[idx..line_end];
        const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_text = std.mem.trim(u8, size_line[0..semi], " \t");
        const chunk_len = std.fmt.parseInt(usize, size_text, 16) catch return null;
        idx = line_end + 2;

        if (chunk_len == 0) {
            while (true) {
                const trailer_end = std.mem.indexOfPos(u8, body, idx, "\r\n") orelse return null;
                if (trailer_end == idx) return trailer_end + 2;
                idx = trailer_end + 2;
            }
        }

        if (body.len < idx + chunk_len + 2) return null;
        idx += chunk_len;
        if (!std.mem.eql(u8, body[idx .. idx + 2], "\r\n")) return null;
        idx += 2;
    }
}

fn writeTestResponse(
    stream: *std.Io.net.Stream,
    io: std.Io,
    status: u16,
    reason: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !void {
    var out_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const out = &writer.interface;

    try out.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason });
    try out.print("Content-Length: {d}\r\n", .{body.len});
    for (headers) |header| {
        try out.writeAll(header);
        try out.writeAll("\r\n");
    }
    try out.writeAll("Connection: close\r\n\r\n");
    if (body.len > 0) {
        try out.writeAll(body);
    }
    try writer.interface.flush();
}

fn durableTestDirPath(allocator: std.mem.Allocator, tmp_dir: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
}

fn makeTestRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    idempotency_key: ?[]const u8,
) !HttpRequestOwned {
    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, method),
        .url = try allocator.dupe(u8, url),
        .headers = .empty,
        .body = null,
    };
    errdefer request.deinit(allocator);

    if (idempotency_key) |key| {
        try request.headers.append(allocator, .{
            .key = try allocator.dupe(u8, "idempotency-key"),
            .value = try allocator.dupe(u8, key),
        });
    }

    return request;
}

test "durable run+step cycle frees nested non-closure function bytecode exactly once" {
    // Regression for a double-free in Context.deinit's bytecode_functions
    // teardown: run()'s and step()'s zero-upvalue arrow callbacks compile to
    // non-closure make_function objects (no captured locals), so their
    // FunctionBytecode is simultaneously (a) a constant of their lexically
    // enclosing function - freed recursively via destroyConstant - and (b)
    // independently tracked in ctx.bytecode_functions - freed again via
    // destroyFullTracked. Masked everywhere else in this file because those
    // tests wrap HandlerInstance in an arena, where a double-free is a silent no-op.
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);
    defer allocator.free(durable_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  return run("nested-bytecode-owner", () => {
        \\    const v = step("s", () => 1);
        \\    return Response.json({ v: v });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<nested-bytecode-owner>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
}

test "zttp:queue sends receives and acks JSON payloads" {
    const allocator = std.testing.allocator;

    var queue = actor_queue.ActorQueue.init(allocator, 8, 30_000);
    defer queue.deinit();

    const rt = try HandlerInstance.init(allocator, .{
        .queue_system = @ptrCast(&queue),
        .queue_actor_name = "main",
    });
    defer rt.deinit();

    const direct_payload = try rt.ctx.createString("direct");
    _ = try queue_callbacks.queueSendInternal(rt, rt.ctx, "direct", direct_payload, false);
    try std.testing.expect(!rt.ctx.hasException());
    const direct_msg = (try queue.receive("direct")).?;
    try std.testing.expect(queue.ack(direct_msg.id));

    const handler_code =
        \\import { send, receive, ack } from "zttp:queue";
        \\function handler(req) {
        \\  const sent = send("worker", { kind: "work", n: 3 });
        \\  if (!sent.ok) return Response.json({ error: sent.error }, { status: 500 });
        \\  const inbox = receive("worker");
        \\  if (!inbox.ok) return Response.json({ error: inbox.error }, { status: 500 });
        \\  const msg = inbox.value;
        \\  const acknowledged = ack(msg.id);
        \\  return Response.json({
        \\    id: sent.value,
        \\    source: msg.source,
        \\    target: msg.target,
        \\    attempt: msg.attempt,
        \\    kind: msg.payload.kind,
        \\    n: msg.payload.n,
        \\    acked: acknowledged.ok
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<queue>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    // The default reply-to identity is namespaced per HandlerInstance instance
    // ("main#<address>") so concurrent pooled runtimes never share a
    // mailbox; only the prefix is deterministic across test runs.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"source\":\"main#") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"target\":\"worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"kind\":\"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"n\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"acked\":true") != null);
    try std.testing.expectEqual(@as(?*actor_queue.MessageEnvelope, null), try queue.receive("worker"));
}

fn seedIncompleteDurableRandomStep(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    key: []const u8,
    step_name: []const u8,
    result_json: []const u8,
) !void {
    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const path = try durable_executor.buildDurableOplogPath(rt, key);
    defer allocator.free(path);

    const fd = try openOplogFile(allocator, path);
    defer std.Io.Threaded.closeFd(fd);

    var state = zq.trace.DurableState.init(allocator, &.{}, fd);
    defer state.deinit();

    const header_names = [_][]const u8{"idempotency-key"};
    const header_values = [_][]const u8{key};
    const result = zq.trace.jsonToJSValue(rt.ctx, result_json);

    try state.persistRunKey(key);
    try state.persistRequest("GET", "/", &header_names, &header_values, null);
    try state.persistStepStart(step_name);
    try state.persistIO("builtin", "Math.random", rt.ctx, &.{}, result);
    try state.persistStepResult(step_name, rt.ctx, result);
}

// Pull tests from sibling files that are not otherwise reachable from this
// module's import graph. Zig's test runner only analyzes files transitively
// reached from the test root, so handler_loader.zig (used by replay_runner,
// test_runner, and durable_recovery) needs an explicit hook here.
test {
    _ = @import("handler_loader.zig");
    _ = @import("replay_runner.zig");
    _ = @import("durable_fetch.zig");
    _ = @import("retry_backoff.zig");
    _ = @import("handler_corpus.zig");
    _ = @import("durable_dead_runs.zig");
    _ = @import("durable_dead_runs_cli.zig");
    _ = @import("fault_explain.zig");
    _ = @import("incident_log.zig");
}

test "HandlerInstance creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    try std.testing.expect(rt.ctx.sp == 0);
}

test "fromContext recovers the owning runtime, and a native callback sees it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    try std.testing.expectEqual(@as(?*HandlerInstance, rt), HandlerInstance.fromContext(rt.ctx));

    // A native function receives the type-erased Context, which is exactly the
    // position every module callback is in. It must be able to recover the
    // runtime without reading thread-local state.
    const probe = struct {
        var seen: ?*HandlerInstance = null;
        fn call(ctx_ptr: *anyopaque, _: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
            const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
            seen = HandlerInstance.fromContext(ctx);
            return zq.JSValue.undefined_val;
        }
    };
    probe.seen = null;
    _ = try probe.call(rt.ctx, zq.JSValue.undefined_val, &.{});
    try std.testing.expectEqual(@as(?*HandlerInstance, rt), probe.seen);
}

test "a pooled wrapper re-points the host slot and clears it on deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pool = try zq.LockFreePool.init(allocator, .{ .max_size = 1 });
    defer pool.deinit();
    const base_rt = try pool.acquire();
    const policy_generation = try RuntimePolicyGeneration.create(allocator, 1, .{}, false);
    defer policy_generation.release();

    // The pooled Context outlives each wrapper, so the slot must follow the
    // current wrapper and must be empty in between.
    const first = try HandlerInstance.initFromPool(base_rt, .{}, policy_generation);
    try std.testing.expectEqual(@as(?*HandlerInstance, first), HandlerInstance.fromContext(base_rt.ctx));
    first.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), base_rt.ctx.host);

    const second = try HandlerInstance.initFromPool(base_rt, .{}, policy_generation);
    defer second.deinit();
    try std.testing.expectEqual(@as(?*HandlerInstance, second), HandlerInstance.fromContext(base_rt.ctx));
}

test "fromContext returns null for a Context no runtime claimed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const gc_state = try allocator.create(zq.GC);
    gc_state.* = try zq.GC.init(allocator, .{});
    defer gc_state.deinit();

    const ctx = try zq.Context.init(allocator, gc_state, .{});
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?*HandlerInstance, null), HandlerInstance.fromContext(ctx));
}

test "virtual module import alias resolves to callable binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\import { env as getEnv } from "zttp:env";
        \\function handler(req) {
        \\  return Response.text(typeof getEnv);
        \\}
    ;
    try rt.loadHandler(handler_code, "<import-alias>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("function", response.body);
}

test "built-in module import runs under capability wrapper context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\import { uuid, nanoid } from "zttp:id";
        \\function handler(req) {
        \\  const a = uuid();
        \\  const b = nanoid(4);
        \\  return Response.json({
        \\    uuidLen: a.length,
        \\    nanoLen: b.length
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<builtin-capability-wrapper>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("{\"uuidLen\":36,\"nanoLen\":4}", response.body);
}

test "the capability ceiling holds for one call and is cleared after it and after a failing call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\import { uuid } from "zttp:id";
        \\function handler(req) {
        \\  return Response.text(String(uuid().length));
        \\}
    ;
    try rt.loadHandler(handler_code, "<capability-ceiling>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    // A ceiling that admits every category and excludes nothing: the call
    // runs, and the ceiling does not outlive it.
    var view = request.asView();
    view.capability_ceiling = .{ .categories = std.math.maxInt(u32), .excluded_modules = &.{} };
    var response = try rt.executeHandler(view);
    defer response.deinit();
    try std.testing.expectEqualStrings("36", response.body);
    try std.testing.expect(rt.ctx.active_capability_ceiling == null);

    // A ceiling that excludes the module: the call is refused inside the
    // handler, the request fails, and the ceiling is cleared on that path too.
    const excluded = [_][]const u8{"zttp:id"};
    view.capability_ceiling = .{ .categories = std.math.maxInt(u32), .excluded_modules = &excluded };
    if (rt.executeHandler(view)) |unexpected| {
        var owned = unexpected;
        defer owned.deinit();
        std.debug.print("expected a refused call, got status {d}: {s}\n", .{ owned.status, owned.body });
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.HandlerError, err);
    }
    try std.testing.expect(rt.ctx.active_capability_ceiling == null);

    // With no ceiling the same runtime serves the call again.
    view.capability_ceiling = null;
    var again = try rt.executeHandler(view);
    defer again.deinit();
    try std.testing.expectEqualStrings("36", again.body);
}

test "durable run reuses completed response for duplicate key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    return Response.json({
        \\      key: key,
        \\      value: Math.random()
        \\    });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-duplicate>");

    var first_request = try makeTestRequest(allocator, "GET", "/", "order:123");
    defer first_request.deinit(allocator);
    var first_response = try rt.executeHandler(first_request.asView());
    defer first_response.deinit();
    const first_body = try allocator.dupe(u8, first_response.body);

    var second_request = try makeTestRequest(allocator, "GET", "/", "order:123");
    defer second_request.deinit(allocator);
    var second_response = try rt.executeHandler(second_request.asView());
    defer second_response.deinit();

    try std.testing.expectEqualStrings(first_body, second_response.body);

    const path = try durable_executor.buildDurableOplogPath(rt, "order:123");
    defer allocator.free(path);

    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"fn\":\"Math.random\""));

    var parsed = try zq.trace.parseDurableOplog(allocator, source);
    defer parsed.deinit();

    try std.testing.expect(parsed.complete);
    try std.testing.expectEqualStrings("order:123", parsed.run_key.?);
    try std.testing.expect(parsed.response != null);
}

test "durable run resumes from completed step state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    try seedIncompleteDurableRandomStep(
        allocator,
        durable_dir,
        "resume:123",
        "seed",
        "0.25",
    );

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    const seed = step("seed", () => Math.random());
        \\    const stamp = step("stamp", () => Date.now());
        \\    return Response.json({ seed: seed, stamp: stamp });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-resume>");

    var request = try makeTestRequest(allocator, "GET", "/", "resume:123");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed_json.deinit();
    const obj = parsed_json.value.object;

    try std.testing.expectEqual(@as(f64, 0.25), obj.get("seed").?.float);
    try std.testing.expect(obj.get("stamp") != null);

    const path = try durable_executor.buildDurableOplogPath(rt, "resume:123");
    defer allocator.free(path);

    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"fn\":\"Math.random\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"fn\":\"Date.now\""));

    var parsed = try zq.trace.parseDurableOplog(allocator, source);
    defer parsed.deinit();

    try std.testing.expect(parsed.complete);
    try std.testing.expectEqualStrings("resume:123", parsed.run_key.?);
}

test "proof-gated durable retry allows proven workflow replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    try seedIncompleteDurableRandomStep(
        allocator,
        durable_dir,
        "retry:proven",
        "seed",
        "0.75",
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .durable_workflow_properties = .{ .enforced = true, .retry_safe = true },
    });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  return run("retry:proven", () => {
        \\    const seed = step("seed", () => Math.random());
        \\    return Response.json({ seed: seed });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-retry-proven>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"seed\":0.75") != null);
}

test "runtime type fault is preserved as HandlerTypeFault for proof-explained 500" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // `o.missing` is undefined at runtime; calling it raises NotCallable in the
    // interpreter. The bytecode compiles on this path (no analyzer veto), so the
    // fault reaches executeHandlerInternal's catch, which must preserve the fault
    // class as error.HandlerTypeFault (not the opaque error.HandlerError) so the
    // 500 site can name the proof chip that guards it. See fault_explain.zig.
    const handler_code = "function handler(req) { const o = { a: 1 }; const f = o.missing; return f(); }";
    try rt.loadHandler(handler_code, "<type-fault>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    try std.testing.expectError(error.HandlerTypeFault, rt.executeHandler(request.asView()));
}

test "non-Response return 500 is proof-explained against exhaustive_returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // Returns a primitive, not a Response -> extractResponseInternal's Path B
    // builds a 500. handler_proof defaults to unproven, so the body names the
    // exhaustive_returns chip as the predicted cause.
    try rt.loadHandler("function handler(req) { return 42; }", "<non-response>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "exhaustive_returns") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "not proven") != null);
}

test "soundness incident on a proven path is written to the incident log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/incidents.jsonl", .{tmp.sub_path});

    const fd = try incident_log.open(allocator, log_path);
    defer std.Io.Threaded.closeFd(fd);

    // handler_proof claims both guarding chips proven, so a runtime type fault is
    // a soundness incident that must be recorded to the log.
    const rt = try HandlerInstance.init(allocator, .{
        .handler_proof = .{ .optional_safe = true, .result_safe = true },
        .incident_log_fd = fd,
    });
    defer rt.deinit();

    try rt.loadHandler("function handler(req) { const o = { a: 1 }; const f = o.missing; return f(); }", "<incident>");
    var request = try makeTestRequest(allocator, "GET", "/boom", null);
    defer request.deinit(allocator);
    try std.testing.expectError(error.HandlerTypeFault, rt.executeHandler(request.asView()));

    const contents = try zq.file_io.readFile(allocator, log_path, 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, contents, "soundness_incident") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "/boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "optional_safe") != null);
    // The single-line handler faults on line 1; the source map (feature A) must
    // surface that line into the incident detail.
    try std.testing.expect(std.mem.indexOf(u8, contents, "NotCallable at 1:") != null);
}

test "exceeding a constant cost ceiling records a soundness incident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cost-incidents.jsonl", .{tmp.sub_path});

    const fd = try incident_log.open(allocator, log_path);
    defer std.Io.Threaded.closeFd(fd);

    const rt = try HandlerInstance.init(allocator, .{
        .incident_log_fd = fd,
        .cost_ceilings = .{
            .total = 1,
            .total_is_constant = true,
        },
    });
    defer rt.deinit();

    try rt.loadHandler(
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  env("ONE");
        \\  env("TWO");
        \\  return Response.text("ok");
        \\}
    , "<cost-exceeded>");

    var request = try makeTestRequest(allocator, "GET", "/cost", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);

    const contents = try zq.file_io.readFile(allocator, log_path, 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, contents, "soundness_incident") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "cost_bounded") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "cost envelope exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "total 2 > 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "arena high-water") != null);
}

test "requests within the ceiling record no incident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cost-clean.jsonl", .{tmp.sub_path});

    const fd = try incident_log.open(allocator, log_path);
    defer std.Io.Threaded.closeFd(fd);

    const rt = try HandlerInstance.init(allocator, .{
        .incident_log_fd = fd,
        .cost_ceilings = .{
            .total = 2,
            .total_is_constant = true,
        },
    });
    defer rt.deinit();

    try rt.loadHandler(
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  env("ONE");
        \\  return Response.text("ok");
        \\}
    , "<cost-clean>");

    var request = try makeTestRequest(allocator, "GET", "/cost", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);

    const contents = try zq.file_io.readFile(allocator, log_path, 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, contents, "soundness_incident") == null);
}

test "cost meter resets between pooled requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cost-reset.jsonl", .{tmp.sub_path});

    const fd = try incident_log.open(allocator, log_path);
    defer std.Io.Threaded.closeFd(fd);

    const rt = try HandlerInstance.init(allocator, .{
        .incident_log_fd = fd,
        .cost_ceilings = .{
            .total = 1,
            .total_is_constant = true,
        },
    });
    defer rt.deinit();

    try rt.loadHandler(
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  env("ONE");
        \\  return Response.text("ok");
        \\}
    , "<cost-reset>");

    var first = try makeTestRequest(allocator, "GET", "/first", null);
    defer first.deinit(allocator);
    var first_response = try rt.executeHandler(first.asView());
    defer first_response.deinit();
    try std.testing.expectEqual(@as(u32, 0), rt.ctx.cost_meter.total());

    var second = try makeTestRequest(allocator, "GET", "/second", null);
    defer second.deinit(allocator);
    var second_response = try rt.executeHandler(second.asView());
    defer second_response.deinit();
    try std.testing.expectEqual(@as(u32, 0), rt.ctx.cost_meter.total());

    const contents = try zq.file_io.readFile(allocator, log_path, 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, contents, "soundness_incident") == null);
}

test "proof-gated durable retry blocks unproven workflow replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    try seedIncompleteDurableRandomStep(
        allocator,
        durable_dir,
        "retry:unproven",
        "seed",
        "0.5",
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .durable_workflow_properties = .{ .enforced = true },
    });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  return run("retry:unproven", () => {
        \\    const seed = step("seed", () => Math.random());
        \\    return Response.json({ seed: seed });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-retry-unproven>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 599), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "DurableRetryUnproven") != null);
}

test "idempotency ledger allows unproven durable retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    try seedIncompleteDurableRandomStep(
        allocator,
        durable_dir,
        "retry:ledger",
        "seed",
        "0.25",
    );
    var store = durable_store_mod.DurableStore.initFs(allocator, durable_dir);
    try store.writeIdempotencyLedger("retry:ledger", "retry:ledger", .started);

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .durable_workflow_properties = .{ .enforced = true },
    });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    const seed = step("seed", () => Math.random());
        \\    return Response.json({ seed: seed });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-retry-ledger>");

    var request = try makeTestRequest(allocator, "GET", "/", "retry:ledger");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"seed\":0.25") != null);
    try std.testing.expect(try store.hasIdempotencyLedger("retry:ledger", "retry:ledger"));
}

test "idempotency ledger allows unproven duplicate durable response reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .durable_workflow_properties = .{ .enforced = true },
    });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => Response.json({ value: Math.random() }));
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-idem-ledger>");

    var first_request = try makeTestRequest(allocator, "GET", "/", "idem:duplicate");
    defer first_request.deinit(allocator);
    var first_response = try rt.executeHandler(first_request.asView());
    defer first_response.deinit();
    const first_body = try allocator.dupe(u8, first_response.body);

    var second_request = try makeTestRequest(allocator, "GET", "/", "idem:duplicate");
    defer second_request.deinit(allocator);
    var second_response = try rt.executeHandler(second_request.asView());
    defer second_response.deinit();

    try std.testing.expectEqual(@as(u16, 200), second_response.status);
    try std.testing.expectEqualStrings(first_body, second_response.body);

    const path = try durable_executor.buildDurableOplogPath(rt, "idem:duplicate");
    defer allocator.free(path);
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"fn\":\"Math.random\""));
}

fn seedIncompleteWorkflowCallStep(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    key: []const u8,
    step_name: []const u8,
    result_json: []const u8,
) !void {
    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const path = try durable_executor.buildDurableOplogPath(rt, key);
    defer allocator.free(path);

    const fd = try openOplogFile(allocator, path);
    defer std.Io.Threaded.closeFd(fd);

    var state = zq.trace.DurableState.init(allocator, &.{}, fd);
    defer state.deinit();

    const header_names = [_][]const u8{"idempotency-key"};
    const header_values = [_][]const u8{key};
    const result = zq.trace.jsonToJSValue(rt.ctx, result_json);

    try state.persistRunKey(key);
    try state.persistRequest("GET", "/", &header_names, &header_values, null);
    try state.persistStepStart(step_name);
    try state.persistStepResult(step_name, rt.ctx, result);
}

test "workflow.call inside durable run replays a completed step from cache (no re-dispatch)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    // Seed a COMPLETED workflow.call#0 step whose stored Response body marks it
    // as the cached (oplog) value. The run itself stays incomplete so the
    // orchestrator re-executes on the next request.
    try seedIncompleteWorkflowCallStep(
        allocator,
        durable_dir,
        "wf:1",
        "workflow.call#0",
        "{\"status\":200,\"headers\":{\"content-type\":\"application/json\"},\"body\":\"{\\\"cached\\\":true}\"}",
    );

    // The live sub-handler would return cached:false if (wrongly) re-dispatched.
    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler(
        "greet",
        "function handler(req) { return Response.json({ cached: false }); }",
        "<greet>",
        .{},
        1,
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .system_registry = @ptrCast(&sys),
    });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    const res = call("greet", { method: "GET", path: "/greet" });
        \\    return Response.json({ subStatus: res.status, sub: res.json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<wf-durable>");

    var request = try makeTestRequest(allocator, "GET", "/", "wf:1");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    // The cached step result wins: greet is NOT re-dispatched, so the body
    // carries the oplog's cached:true and a real reconstructed 200 Response.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"cached\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"subStatus\":200") != null);
}

test "workflow.call inside durable run records its dispatch as a durable step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler(
        "greet",
        "function handler(req) { return Response.json({ from: 'greet' }); }",
        "<greet>",
        .{},
        1,
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .system_registry = @ptrCast(&sys),
    });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    const res = call("greet", { method: "GET", path: "/greet" });
        \\    return Response.json({ subStatus: res.status, sub: res.json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<wf-durable-live>");

    var request = try makeTestRequest(allocator, "GET", "/", "wf:live");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    // First run dispatches greet live and composes its response.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"from\":\"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"subStatus\":200") != null);

    // The call was recorded as its own durable step in the oplog.
    const path = try durable_executor.buildDurableOplogPath(rt, "wf:live");
    defer allocator.free(path);
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    // The call appears twice: once in step_start, once in step_result.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "\"name\":\"workflow.call#0\""));
    try std.testing.expect(std.mem.indexOf(u8, source, "\"type\":\"step_result\"") != null);

    var parsed = try zq.trace.parseDurableOplog(allocator, source);
    defer parsed.deinit();
    try std.testing.expect(parsed.complete);
}

test "workflow.call queue mode persists child result before durable step result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler(
        "greet",
        "function handler(req) { return Response.json({ from: 'greet', method: req.method, body: req.body, trace: req.headers.get('x-trace') }); }",
        "<greet>",
        .{},
        1,
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .system_registry = @ptrCast(&sys),
        .workflow_queue_enabled = true,
    });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("wf:queue", () => {
        \\    const res = call("greet", { method: "POST", path: "/greet", body: "hello", headers: { "x-trace": "queued" } });
        \\    return Response.json({ subStatus: res.status, sub: res.json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<wf-queue>");

    var request = try makeTestRequest(allocator, "GET", "/", "wf:queue");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"from\":\"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"method\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"body\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"trace\":\"queued\"") != null);

    const item_id = try workflow_queue.itemId(allocator, "wf:queue", "workflow.call#0");
    const result_json = (try workflow_queue.readResult(allocator, durable_dir, item_id)) orelse return error.MissingWorkflowQueueResult;
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "greet") != null);

    const path = try durable_executor.buildDurableOplogPath(rt, "wf:queue");
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "\"name\":\"workflow.call#0\""));
    try std.testing.expect(std.mem.indexOf(u8, source, "\"type\":\"step_result\"") != null);
}

test "workflow-queue dead letter suspends the parent, and replay resolves it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler(
        "greet",
        "function handler(req) { return Response.json({ from: 'greet' }); }",
        "<greet>",
        .{},
        1,
    );

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .system_registry = @ptrCast(&sys),
        .workflow_queue_enabled = true,
    });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { call } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("wf:dead-retry", () => {
        \\    const res = call("greet", { method: "GET", path: "/greet" });
        \\    return Response.json({ subStatus: res.status, sub: res.json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<wf-dead-retry>");

    const item_id = try workflow_queue.itemId(allocator, "wf:dead-retry", "workflow.call#0");

    const view: HttpRequestView = .{
        .method = "GET",
        .path = "/greet",
        .url = "/greet",
        .query_params = &.{},
        .headers = .empty,
        .body = null,
    };
    try workflow_queue.enqueueRequest(allocator, durable_dir, item_id, "greet", view);

    // Drive the queue item to dead-letter by exhausting its attempt cap
    // through repeated lease-expiry reclaims without ever completing it -
    // simulating the child handler crashing every time before it finishes.
    const lease_ms = workflow_queue.defaultLeaseMs();
    var now_ms: i64 = 0;
    var attempt: u32 = 0;
    while (attempt <= workflow_queue.defaultMaxAttempts()) : (attempt += 1) {
        var claim = try workflow_queue.tryClaim(allocator, durable_dir, item_id, now_ms, lease_ms);
        defer claim.deinit(allocator);
        if (claim == .dead) break;
        now_ms += lease_ms + 1;
    }

    const dead_ids = try workflow_queue.listDeadIds(allocator, durable_dir);
    try std.testing.expectEqual(@as(usize, 1), dead_ids.len);

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    // First attempt: the child is dead-lettered, so the parent must suspend
    // (202, pending) rather than caching a terminal error response that a
    // later replay could never undo - the finding #2 fix.
    var suspended = try rt.executeHandler(request.asView());
    defer suspended.deinit();
    try std.testing.expectEqual(@as(u16, 202), suspended.status);
    try std.testing.expect(std.mem.indexOf(u8, suspended.body, "\"pending\":true") != null);

    try workflow_queue.replayDead(allocator, durable_dir, item_id);

    // Retrying the same parent request now actually dispatches the child
    // and completes the run - the recovery guarantee `workflow-queue
    // replay` is supposed to provide.
    var recovered = try rt.executeHandler(request.asView());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u16, 200), recovered.status);
    try std.testing.expect(std.mem.indexOf(u8, recovered.body, "\"from\":\"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.body, "\"subStatus\":200") != null);
}

test "workflow.saga is rejected under workflow queue mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .workflow_queue_enabled = true,
    });
    defer rt.deinit();

    const result = try workflow.workflowSagaCallback(@ptrCast(rt), rt.ctx, zq.JSValue.undefined_val);
    try std.testing.expect(result.isException());
    try std.testing.expect(rt.ctx.hasException());
    rt.ctx.clearException();
}

// Saga (P3): an empty SystemRuntime is enough to enable the workflow module;
// each saga step's run/compensate thunk returns a Response.json directly so the
// success/failure status is controlled without sub-handlers.
fn runSagaHandler(allocator: std.mem.Allocator, durable_dir: []const u8, key: []const u8, handler_code: []const u8) !struct { status: u16, body: []u8, oplog: []u8 } {
    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .system_registry = @ptrCast(&sys),
    });
    defer rt.deinit();
    try rt.loadHandler(handler_code, "<saga>");

    var request = try makeTestRequest(allocator, "GET", "/", key);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    const status = response.status;
    const body = try allocator.dupe(u8, response.body);

    const path = try durable_executor.buildDurableOplogPath(rt, key);
    defer allocator.free(path);
    const oplog = try zq.file_io.readFile(allocator, path, 1024 * 1024);

    return .{ .status = status, .body = body, .oplog = oplog };
}

test "workflow.saga runs every step and returns ok:true when none fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("saga:ok", () => saga([
        \\    { name: "a", run: () => Response.json({ step: "a" }) },
        \\    { name: "b", run: () => Response.json({ step: "b" }) },
        \\  ]));
        \\}
    ;
    const out = try runSagaHandler(allocator, durable_dir, "saga:ok", handler_code);

    try std.testing.expectEqual(@as(u16, 200), out.status);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.oplog, "\"name\":\"do:a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.oplog, "\"name\":\"do:b\"") != null);
    // No compensation ran.
    try std.testing.expect(std.mem.indexOf(u8, out.oplog, "undo:") == null);
}

test "workflow.saga compensates completed steps in reverse order on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("saga:fail", () => saga([
        \\    { name: "reserve", run: () => Response.json({ ok: true }), compensate: () => Response.json({ undone: "reserve" }) },
        \\    { name: "charge", run: () => Response.json({ ok: true }), compensate: () => Response.json({ undone: "charge" }) },
        \\    { name: "ship", run: () => Response.json({ err: true }, { status: 500 }) },
        \\  ]));
        \\}
    ;
    const out = try runSagaHandler(allocator, durable_dir, "saga:fail", handler_code);

    // The failed step's status propagates; the rollback summary marks it failed.
    try std.testing.expectEqual(@as(u16, 500), out.status);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"failed\":\"ship\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"compensated\":true") != null);

    // Both completed steps compensated, in REVERSE declaration order.
    const undo_charge = std.mem.indexOf(u8, out.oplog, "undo:charge") orelse return error.MissingUndoCharge;
    const undo_reserve = std.mem.indexOf(u8, out.oplog, "undo:reserve") orelse return error.MissingUndoReserve;
    try std.testing.expect(undo_charge < undo_reserve);
    // The failed step itself was not compensated (it never completed).
    try std.testing.expect(std.mem.indexOf(u8, out.oplog, "undo:ship") == null);
}

test "workflow.saga returns terminal 500 when a compensation itself fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("saga:compfail", () => saga([
        \\    { name: "reserve", run: () => Response.json({ ok: true }), compensate: () => Response.json({ e: 1 }, { status: 500 }) },
        \\    { name: "charge", run: () => Response.json({ bad: true }, { status: 402 }) },
        \\  ]));
        \\}
    ;
    const out = try runSagaHandler(allocator, durable_dir, "saga:compfail", handler_code);

    // charge (402) fails -> compensate reserve -> reserve's compensate returns
    // 500 -> terminal "manual intervention" with the offending step named.
    try std.testing.expectEqual(@as(u16, 500), out.status);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"compensationFailed\":\"reserve\"") != null);
}

fn seedIncompleteSagaSteps(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    key: []const u8,
    names: []const []const u8,
    results: []const []const u8,
) !void {
    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const path = try durable_executor.buildDurableOplogPath(rt, key);
    defer allocator.free(path);
    const fd = try openOplogFile(allocator, path);
    defer std.Io.Threaded.closeFd(fd);

    var state = zq.trace.DurableState.init(allocator, &.{}, fd);
    defer state.deinit();

    const header_names = [_][]const u8{"idempotency-key"};
    const header_values = [_][]const u8{key};
    try state.persistRunKey(key);
    try state.persistRequest("GET", "/", &header_names, &header_values, null);
    for (names, results) |n, r| {
        const result = zq.trace.jsonToJSValue(rt.ctx, r);
        try state.persistStepStart(n);
        try state.persistStepResult(n, rt.ctx, result);
    }
}

test "workflow.saga replays cached do: steps and re-derives compensation on recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    // Seed a crash mid-saga: reserve completed ok (200), charge completed as a
    // FAILURE (500). The run stays incomplete so the orchestrator re-executes.
    try seedIncompleteSagaSteps(
        allocator,
        durable_dir,
        "saga:replay",
        &.{ "do:reserve", "do:charge" },
        &.{ "{\"status\":200}", "{\"status\":500}" },
    );

    // On replay the live run thunks would BOTH return 200 (success). If the
    // cached do:charge (500) is honored, the saga still fails and compensates
    // reserve. If the steps were wrongly re-run, charge would be 200 -> ok:true.
    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { saga } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("saga:replay", () => saga([
        \\    { name: "reserve", run: () => Response.json({ live: true }), compensate: () => Response.json({ undone: true }) },
        \\    { name: "charge", run: () => Response.json({ live: true }) },
        \\  ]));
        \\}
    ;
    const out = try runSagaHandler(allocator, durable_dir, "saga:replay", handler_code);

    // The cached failure wins -> compensation path, proving do:charge was NOT re-run.
    try std.testing.expectEqual(@as(u16, 500), out.status);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.body, "\"failed\":\"charge\"") != null);
    // reserve was compensated on recovery.
    try std.testing.expect(std.mem.indexOf(u8, out.oplog, "undo:reserve") != null);
}

test "workflow.fanout returns sub-handler responses in declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler("a", "function handler(req) { return Response.json({ who: 'a' }); }", "<a>", .{}, 1);
    try sys.addHandler("b", "function handler(req) { return Response.json({ who: 'b' }); }", "<b>", .{}, 1);
    try sys.addHandler("c", "function handler(req) { return Response.json({ who: 'c' }); }", "<c>", .{}, 1);

    const rt = try HandlerInstance.init(allocator, .{ .system_registry = @ptrCast(&sys) });
    defer rt.deinit();

    const handler_code =
        \\import { fanout } from "zttp:workflow";
        \\function handler(req) {
        \\  const rs = fanout([{ name: "a" }, { name: "b" }, { name: "c" }]);
        \\  return Response.json({ n: rs.length, a: rs[0].json(), b: rs[1].json(), c: rs[2].json() });
        \\}
    ;
    try rt.loadHandler(handler_code, "<parallel>");
    var request = try makeTestRequest(allocator, "GET", "/", "x");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"n\":3") != null);
    // Results are in declaration order a, b, c regardless of execution order.
    const ia = std.mem.indexOf(u8, response.body, "\"who\":\"a\"") orelse return error.MissingA;
    const ib = std.mem.indexOf(u8, response.body, "\"who\":\"b\"") orelse return error.MissingB;
    const ic = std.mem.indexOf(u8, response.body, "\"who\":\"c\"") orelse return error.MissingC;
    try std.testing.expect(ia < ib and ib < ic);
}

test "workflow.fanout records the whole fan-out as one durable step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler("a", "function handler(req) { return Response.json({ who: 'a' }); }", "<a>", .{}, 1);
    try sys.addHandler("b", "function handler(req) { return Response.json({ who: 'b' }); }", "<b>", .{}, 1);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir, .system_registry = @ptrCast(&sys) });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { fanout } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("par:1", () => {
        \\    const rs = fanout([{ name: "a" }, { name: "b" }]);
        \\    return Response.json({ n: rs.length, a: rs[0].json(), b: rs[1].json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<parallel-durable>");
    var request = try makeTestRequest(allocator, "GET", "/", "par:1");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"who\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"n\":2") != null);

    const path = try durable_executor.buildDurableOplogPath(rt, "par:1");
    defer allocator.free(path);
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    // One fan-out step (step_start + step_result name it), and NO per-call steps.
    // The durable name stays workflow.parallel#0 for replay compatibility.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "\"name\":\"workflow.parallel#0\""));
    try std.testing.expect(std.mem.indexOf(u8, source, "workflow.call#") == null);
}

test "workflow.fanout replays its aggregate from cache without re-dispatching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    // Seed a completed fan-out step whose stored aggregate marks both entries
    // as the cached value. Reuses the single-step seed helper - the step result
    // is just an array of {status,headers,body}.
    try seedIncompleteWorkflowCallStep(
        allocator,
        durable_dir,
        "par:replay",
        "workflow.parallel#0",
        "[{\"status\":200,\"headers\":{},\"body\":\"{\\\"v\\\":\\\"cached-a\\\"}\"},{\"status\":200,\"headers\":{},\"body\":\"{\\\"v\\\":\\\"cached-b\\\"}\"}]",
    );

    // Live sub-handlers would return "live-*" if (wrongly) re-dispatched.
    var sys = SystemRuntime.init(allocator);
    defer sys.deinit();
    try sys.addHandler("a", "function handler(req) { return Response.json({ v: 'live-a' }); }", "<a>", .{}, 1);
    try sys.addHandler("b", "function handler(req) { return Response.json({ v: 'live-b' }); }", "<b>", .{}, 1);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir, .system_registry = @ptrCast(&sys) });
    defer rt.deinit();

    const handler_code =
        \\import { run } from "zttp:durable";
        \\import { fanout } from "zttp:workflow";
        \\function handler(req) {
        \\  return run("par:replay", () => {
        \\    const rs = fanout([{ name: "a" }, { name: "b" }]);
        \\    return Response.json({ a: rs[0].json(), b: rs[1].json() });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<parallel-replay>");
    var request = try makeTestRequest(allocator, "GET", "/", "par:replay");
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    // The cached aggregate wins -> neither sub-handler was re-dispatched.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "cached-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "cached-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "live-") == null);
}

test "durable sleepUntil returns pending response without duplicating wait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, sleepUntil } from "zttp:durable";
        \\function handler(req) {
        \\  return run("timer:123", () => {
        \\    sleepUntil(4102444800000);
        \\    return Response.json({ ok: true });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-sleep>");

    var first_request = try makeTestRequest(allocator, "GET", "/", null);
    defer first_request.deinit(allocator);
    var first_response = try rt.executeHandler(first_request.asView());
    defer first_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), first_response.status);
    try std.testing.expect(std.mem.indexOf(u8, first_response.body, "\"type\":\"timer\"") != null);

    var second_request = try makeTestRequest(allocator, "GET", "/", null);
    defer second_request.deinit(allocator);
    var second_response = try rt.executeHandler(second_request.asView());
    defer second_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), second_response.status);
    try std.testing.expect(std.mem.indexOf(u8, second_response.body, "\"pending\":true") != null);

    const path = try durable_executor.buildDurableOplogPath(rt, "timer:123");
    defer allocator.free(path);

    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"type\":\"wait_timer\""));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "\"type\":\"resume_timer\""));
}

test "durable waitSignal resumes from queued signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, waitSignal, signal } from "zttp:durable";
        \\function handler(req) {
        \\  if (req.url === "/signal") {
        \\    return Response.json({ delivered: signal("job:123", "approved", { ok: true }) });
        \\  }
        \\  return run("job:123", () => {
        \\    const payload = waitSignal("approved");
        \\    return Response.json(payload);
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-signal>");

    var wait_request = try makeTestRequest(allocator, "GET", "/wait", null);
    defer wait_request.deinit(allocator);
    var pending_response = try rt.executeHandler(wait_request.asView());
    defer pending_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), pending_response.status);
    try std.testing.expect(std.mem.indexOf(u8, pending_response.body, "\"type\":\"signal\"") != null);

    var signal_request = try makeTestRequest(allocator, "GET", "/signal", null);
    defer signal_request.deinit(allocator);
    var signal_response = try rt.executeHandler(signal_request.asView());
    defer signal_response.deinit();

    var parsed_signal = try std.json.parseFromSlice(std.json.Value, allocator, signal_response.body, .{});
    defer parsed_signal.deinit();
    try std.testing.expect(parsed_signal.value.object.get("delivered").?.bool);

    var resume_request = try makeTestRequest(allocator, "GET", "/wait", null);
    defer resume_request.deinit(allocator);
    var resumed_response = try rt.executeHandler(resume_request.asView());
    defer resumed_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), resumed_response.status);

    var parsed_payload = try std.json.parseFromSlice(std.json.Value, allocator, resumed_response.body, .{});
    defer parsed_payload.deinit();
    try std.testing.expect(parsed_payload.value.object.get("ok").?.bool);

    const path = try durable_executor.buildDurableOplogPath(rt, "job:123");
    defer allocator.free(path);

    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"type\":\"wait_signal\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"type\":\"resume_signal\""));
}

test "durable stepWithTimeout times out a durable sleep boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, stepWithTimeout, sleep } from "zttp:durable";
        \\function handler(req) {
        \\  return run("timeout:sleep", () => {
        \\    const result = stepWithTimeout("slow", 5, () => {
        \\      sleep(1000);
        \\      return "late";
        \\    });
        \\    return Response.json({ ok: result.ok, error: result.error });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-step-timeout-sleep>");

    var first_request = try makeTestRequest(allocator, "GET", "/", null);
    defer first_request.deinit(allocator);
    var first_response = try rt.executeHandler(first_request.asView());
    defer first_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), first_response.status);
    try std.testing.expect(std.mem.indexOf(u8, first_response.body, "\"type\":\"timer\"") != null);

    std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};

    var second_request = try makeTestRequest(allocator, "GET", "/", null);
    defer second_request.deinit(allocator);
    var second_response = try rt.executeHandler(second_request.asView());
    defer second_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), second_response.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, second_response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("timeout", obj.get("error").?.string);
}

test "durable stepWithTimeout times out waitSignal before consuming a later signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, stepWithTimeout, waitSignal, signal } from "zttp:durable";
        \\function handler(req) {
        \\  if (req.url === "/signal") {
        \\    return Response.json({ delivered: signal("timeout:signal", "approved", { ok: true }) });
        \\  }
        \\  return run("timeout:signal", () => {
        \\    const result = stepWithTimeout("approval", 5, () => waitSignal("approved"));
        \\    return Response.json({ ok: result.ok, error: result.error });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-step-timeout-signal>");

    var wait_request = try makeTestRequest(allocator, "GET", "/wait", null);
    defer wait_request.deinit(allocator);
    var pending_response = try rt.executeHandler(wait_request.asView());
    defer pending_response.deinit();
    try std.testing.expectEqual(@as(u16, 202), pending_response.status);
    try std.testing.expect(std.mem.indexOf(u8, pending_response.body, "\"type\":\"signal\"") != null);

    std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};

    var signal_request = try makeTestRequest(allocator, "GET", "/signal", null);
    defer signal_request.deinit(allocator);
    var signal_response = try rt.executeHandler(signal_request.asView());
    defer signal_response.deinit();
    var parsed_signal = try std.json.parseFromSlice(std.json.Value, allocator, signal_response.body, .{});
    defer parsed_signal.deinit();
    try std.testing.expect(parsed_signal.value.object.get("delivered").?.bool);

    var resume_request = try makeTestRequest(allocator, "GET", "/wait", null);
    defer resume_request.deinit(allocator);
    var resumed_response = try rt.executeHandler(resume_request.asView());
    defer resumed_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), resumed_response.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, resumed_response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("timeout", obj.get("error").?.string);

    const path = try durable_executor.buildDurableOplogPath(rt, "timeout:signal");
    defer allocator.free(path);
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"timeout_ms\"") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "\"type\":\"resume_signal\""));
}

test "durable fetch retries 5xx responses and succeeds within the retry budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var server = try TestHttpServer.init(allocator, .sequenced_status);
    server.status_sequence = &.{ 500, 500, 200 };
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .outbound_http_enabled = true,
    });
    defer rt.deinit();
    var endpoint_buf: [512]u8 = undefined;
    const allowed = [_][]const u8{egressEndpoint(url, &endpoint_buf)};
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &allowed },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback),
    };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const res = fetch("{s}", {{ durable: {{ key: "retry-success", retries: 5, backoff: "none" }} }});
        \\  return Response.json({{ status: res.status }});
        \\}}
    , .{url});
    try rt.loadHandler(handler_code, "<durable-fetch-retry-success>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("status").?.integer);
}

test "durable fetch stops retrying once the retry budget is exhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    var server = try TestHttpServer.init(allocator, .sequenced_status);
    server.status_sequence = &.{500};
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .outbound_http_enabled = true,
    });
    defer rt.deinit();
    var endpoint_buf: [512]u8 = undefined;
    const allowed = [_][]const u8{egressEndpoint(url, &endpoint_buf)};
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &allowed },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback),
    };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const res = fetch("{s}", {{ durable: {{ key: "retry-exhausted", retries: 0, backoff: "none" }} }});
        \\  return Response.json({{ status: res.status }});
        \\}}
    , .{url});
    try rt.loadHandler(handler_code, "<durable-fetch-retry-exhausted>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    // retries: 0 means exactly one attempt - the server's single-item
    // sequence is consumed exactly once, proving the loop did not retry
    // past a `retries: 0` budget.
    try std.testing.expectEqual(@as(u16, 200), response.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 500), parsed.value.object.get("status").?.integer);
}

test "durable fetch retry loop stops once the step deadline passes instead of exhausting its retry budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    // Point at a closed local port instead of a real server: each connect
    // attempt is refused near-instantly (no listener, no background thread
    // to coordinate or tear down), and a refused connection is classified
    // exactly like a 5xx response (synthetic 599) by fetchSyncResult, so
    // the retry loop treats it identically.
    const rt = try HandlerInstance.init(allocator, .{
        .durable_oplog_dir = durable_dir,
        .outbound_http_enabled = true,
    });
    defer rt.deinit();
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"http://127.0.0.1:18711"} },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback),
    };

    const handler_code =
        \\import { run, stepWithTimeout } from "zttp:durable";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  return run("fetch:deadline", () => {
        \\    const result = stepWithTimeout("call", 50, () => {
        \\      return fetch("http://127.0.0.1:18711/", { durable: { key: "deadline-fetch", retries: 8, backoff: "exponential" } });
        \\    });
        \\    return Response.json({ ok: result.ok, error: result.error });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-fetch-deadline>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    var timer = try zq.compat.Timer.start();
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    const elapsed_ms = timer.read() / std.time.ns_per_ms;

    try std.testing.expectEqual(@as(u16, 200), response.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("timeout", obj.get("error").?.string);

    // With retries: 8 and exponential backoff, an unbounded retry loop
    // could spend several seconds (backoff caps grow to 6400ms per
    // attempt); stopping at the step deadline keeps this well under a
    // second even with two real network round-trips and one backoff sleep.
    try std.testing.expect(elapsed_ms < 2000);
}

test "durable signal returns false after completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, signal } from "zttp:durable";
        \\function handler(req) {
        \\  if (req.url === "/signal") {
        \\    return Response.json({ delivered: signal("done:123", "approved", { ok: true }) });
        \\  }
        \\  return run("done:123", () => Response.json({ ok: true }));
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-signal-false>");

    var run_request = try makeTestRequest(allocator, "GET", "/run", null);
    defer run_request.deinit(allocator);
    var run_response = try rt.executeHandler(run_request.asView());
    defer run_response.deinit();
    try std.testing.expectEqual(@as(u16, 200), run_response.status);

    var signal_request = try makeTestRequest(allocator, "GET", "/signal", null);
    defer signal_request.deinit(allocator);
    var signal_response = try rt.executeHandler(signal_request.asView());
    defer signal_response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, signal_response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("delivered").?.bool);
}

test "durable step outside run fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { step } from "zttp:durable";
        \\function handler(req) {
        \\  step("seed", () => 1);
        \\  return Response.json({ ok: true });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-step-outside-run>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    const request_val = try rt.createRequestObject(request.asView());
    try std.testing.expectError(error.NativeFunctionError, rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}));
    rt.resetForNextRequest();
}

test "httpRequest native binding reports disabled bridge by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const out = httpRequest(JSON.stringify({ url: "http://example.com" }));
        \\  return Response.json(JSON.parse(out));
        \\}
    ;
    try rt.loadHandler(handler_code, "<http-bridge-disabled>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    const ok_v = obj.get("ok") orelse return error.BadGolden;
    try std.testing.expect(ok_v == .bool and !ok_v.bool);
    const err_v = obj.get("error") orelse return error.BadGolden;
    try std.testing.expect(err_v == .string);
    try std.testing.expectEqualStrings("OutboundHttpDisabled", err_v.string);
}

test "httpRequest native binding enforces allowlisted host before dialing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "localhost",
    });
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const out = httpRequest(JSON.stringify({ url: "http://example.com" }));
        \\  return Response.json(JSON.parse(out));
        \\}
    ;
    try rt.loadHandler(handler_code, "<http-bridge-allowlist>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    const ok_v = obj.get("ok") orelse return error.BadGolden;
    try std.testing.expect(ok_v == .bool and !ok_v.bool);
    const err_v = obj.get("error") orelse return error.BadGolden;
    try std.testing.expect(err_v == .string);
    try std.testing.expectEqualStrings("HostNotAllowed", err_v.string);
}

test "request helpers expose body parsing and case-insensitive headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const body = req.body ?? "";
        \\  const data = req.json();
        \\  return Response.json({
        \\    contentType: req.headers.get("content-type"),
        \\    auth: req.headers.get("AUTHORIZATION"),
        \\    missing: req.headers.get("x-missing"),
        \\    body: body,
        \\    name: data.name,
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<request-helpers>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "{\"name\":\"zttp\"}"),
    };
    defer request.deinit(allocator);

    try request.headers.append(allocator, .{
        .key = try allocator.dupe(u8, "Content-Type"),
        .value = try allocator.dupe(u8, "application/json"),
    });
    try request.headers.append(allocator, .{
        .key = try allocator.dupe(u8, "Authorization"),
        .value = try allocator.dupe(u8, "Bearer test-token"),
    });
    try request.headers.append(allocator, .{
        .key = try allocator.dupe(u8, "authorization"),
        .value = try allocator.dupe(u8, "Bearer override"),
    });

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("application/json", obj.get("contentType").?.string);
    try std.testing.expectEqualStrings("Bearer override", obj.get("auth").?.string);
    try std.testing.expect(obj.get("missing") == null); // undefined values are omitted from JSON
    try std.testing.expectEqualStrings("{\"name\":\"zttp\"}", obj.get("body").?.string);
    try std.testing.expectEqualStrings("zttp", obj.get("name").?.string);
}

test "request helpers define empty and invalid body semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  return Response.json({
        \\    body: req.body ?? "",
        \\    jsonIsUndefined: req.json() === undefined,
        \\    missingIsUndefined: req.headers.get("x-missing") === undefined,
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<request-body-semantics>");

    var empty_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer empty_request.deinit(allocator);

    var empty_response = try rt.executeHandler(empty_request.asView());
    defer empty_response.deinit();

    var empty_parsed = try std.json.parseFromSlice(std.json.Value, allocator, empty_response.body, .{});
    defer empty_parsed.deinit();
    const empty_obj = empty_parsed.value.object;
    try std.testing.expectEqualStrings("", empty_obj.get("body").?.string);
    try std.testing.expectEqual(true, empty_obj.get("jsonIsUndefined").?.bool);
    try std.testing.expectEqual(true, empty_obj.get("missingIsUndefined").?.bool);

    var invalid_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "{invalid json"),
    };
    defer invalid_request.deinit(allocator);

    var invalid_response = try rt.executeHandler(invalid_request.asView());
    defer invalid_response.deinit();

    var invalid_parsed = try std.json.parseFromSlice(std.json.Value, allocator, invalid_response.body, .{});
    defer invalid_parsed.deinit();
    const invalid_obj = invalid_parsed.value.object;
    try std.testing.expectEqualStrings("{invalid json", invalid_obj.get("body").?.string);
    try std.testing.expectEqual(true, invalid_obj.get("jsonIsUndefined").?.bool);
    try std.testing.expectEqual(true, invalid_obj.get("missingIsUndefined").?.bool);
}

test "Headers Request and Response factories share the HTTP model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const headers = Headers({
        \\    "Content-Type": "application/json",
        \\    "X-Test": "one"
        \\  });
        \\  headers.append("X-Test", "two");
        \\  headers.set("X-Mode", "fast");
        \\  const beforeDelete = headers.has("x-mode");
        \\  headers.delete("x-mode");
        \\  const request = Request("/items?id=41&name=zttp", {
        \\    method: "POST",
        \\    headers: headers,
        \\    body: "{\"ok\":true}"
        \\  });
        \\  const data = request.json();
        \\  const response = Response("done", {
        \\    status: 201,
        \\    headers: { "X-Reply": "ok" }
        \\  });
        \\  return Response.json({
        \\    combinedHeader: headers.get("x-test"),
        \\    beforeDelete: beforeDelete,
        \\    afterDelete: headers.has("x-mode"),
        \\    requestMethod: request.method,
        \\    requestPath: request.path,
        \\    requestId: request.query.id,
        \\    requestName: request.query.name,
        \\    requestType: request.headers.get("content-type"),
        \\    requestOk: data.ok,
        \\    responseStatus: response.status,
        \\    responseOk: response.ok,
        \\    responseReply: response.headers.get("x-reply"),
        \\    responseType: response.headers.get("content-type"),
        \\    responseText: response.text()
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<http-factories>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("one, two", obj.get("combinedHeader").?.string);
    try std.testing.expectEqual(true, obj.get("beforeDelete").?.bool);
    try std.testing.expectEqual(false, obj.get("afterDelete").?.bool);
    try std.testing.expectEqualStrings("POST", obj.get("requestMethod").?.string);
    try std.testing.expectEqualStrings("/items", obj.get("requestPath").?.string);
    try std.testing.expectEqual(@as(i64, 41), obj.get("requestId").?.integer);
    try std.testing.expectEqualStrings("zttp", obj.get("requestName").?.string);
    try std.testing.expectEqualStrings("application/json", obj.get("requestType").?.string);
    try std.testing.expectEqual(true, obj.get("requestOk").?.bool);
    try std.testing.expectEqual(@as(i64, 201), obj.get("responseStatus").?.integer);
    try std.testing.expectEqual(true, obj.get("responseOk").?.bool);
    try std.testing.expectEqualStrings("ok", obj.get("responseReply").?.string);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", obj.get("responseType").?.string);
    try std.testing.expectEqualStrings("done", obj.get("responseText").?.string);
}

test "Response factories expose canonical status text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    try rt.loadHandler(
        \\function handler(req) {
        \\  const cached = Response("created", { status: 201 });
        \\  const badGateway = Response.json({ error: true }, { status: 502 });
        \\  const networkTimeout = Response.rawJson("{}", { status: 599 });
        \\  const accepted = Response.text("pending", { status: 202 });
        \\  const requestTimeout = Response.html("", { status: 408 });
        \\  const unknown = Response("teapot", { status: 418 });
        \\  return Response.json({
        \\    cached: cached.statusText,
        \\    badGateway: badGateway.statusText,
        \\    networkTimeout: networkTimeout.statusText,
        \\    accepted: accepted.statusText,
        \\    requestTimeout: requestTimeout.statusText,
        \\    unknown: unknown.statusText
        \\  });
        \\}
    , "<response-status-text>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("Created", obj.get("cached").?.string);
    try std.testing.expectEqualStrings("Bad Gateway", obj.get("badGateway").?.string);
    try std.testing.expectEqualStrings("Network Connect Timeout Error", obj.get("networkTimeout").?.string);
    try std.testing.expectEqualStrings("Accepted", obj.get("accepted").?.string);
    try std.testing.expectEqualStrings("Request Timeout", obj.get("requestTimeout").?.string);
    try std.testing.expectEqualStrings("Unknown", obj.get("unknown").?.string);
}

test "body readers are single-use for inbound and constructed HTTP objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    try rt.loadHandler(
        \\function handler(req) {
        \\  req.text();
        \\  return Response.text(req.text());
        \\}
    , "<request-body-reuse>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "ping"),
    };
    defer request.deinit(allocator);

    const request_val = try rt.createRequestObject(request.asView());
    try std.testing.expectError(error.NativeFunctionError, rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}));
    rt.resetForNextRequest();

    try rt.loadHandler(
        \\function handler(req) {
        \\  const built = Response("pong");
        \\  built.text();
        \\  return Response.text(built.text());
        \\}
    , "<response-body-reuse>");

    const request_val_two = try rt.createRequestObject(request.asView());
    try std.testing.expectError(error.NativeFunctionError, rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val_two}));
    rt.resetForNextRequest();
}

test "fetchSync returns response helpers and direct response objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const inspect_handler =
        \\function handler(req) {
        \\  const resp = fetchSync("http://example.com");
        \\  const data = resp.json();
        \\  return Response.json({
        \\    status: resp.status,
        \\    ok: resp.ok,
        \\    contentType: resp.headers.get("Content-Type"),
        \\    error: data.error,
        \\    details: data.details,
        \\  });
        \\}
    ;
    try rt.loadHandler(inspect_handler, "<fetchsync-inspect>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), obj.get("status").?.integer);
    try std.testing.expect(obj.get("ok").?.bool == false);
    try std.testing.expectEqualStrings("application/json", obj.get("contentType").?.string);
    try std.testing.expectEqualStrings("OutboundHttpDisabled", obj.get("error").?.string);

    try rt.loadHandler("function handler(req) { return fetchSync('http://example.com'); }", "<fetchsync-direct>");
    var direct_response = try rt.executeHandler(request.asView());
    defer direct_response.deinit();

    try std.testing.expectEqual(@as(u16, 599), direct_response.status);
    try std.testing.expect(std.mem.indexOf(u8, direct_response.body, "\"error\":\"OutboundHttpDisabled\"") != null);
}

test "fetchSync returns structured errors for invalid init and allowlist failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "localhost",
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const badHeadersResp = fetchSync("http://localhost", {
        \\    headers: { "X-Test": 42 }
        \\  });
        \\  const badHeaders = badHeadersResp.json();
        \\  return Response.json({
        \\    badHeadersStatus: badHeadersResp.status,
        \\    badHeadersOk: badHeadersResp.ok,
        \\    badHeadersStatusText: badHeadersResp.statusText,
        \\    badHeadersError: badHeaders.error,
        \\    badMethodError: fetchSync({ url: "http://localhost", method: "BOGUS" }).json().error,
        \\    badBodyError: fetchSync("http://localhost", { body: 42 }).json().error,
        \\    badCamelMaxError: fetchSync("http://localhost", { maxResponseBytes: "large" }).json().error,
        \\    badSnakeMaxError: fetchSync("http://localhost", { max_response_bytes: "large" }).json().error,
        \\    missingUrlError: fetchSync({ method: "GET" }).json().error,
        \\    hostBlockedError: fetchSync("http://example.com").json().error,
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<fetchsync-invalid>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), obj.get("badHeadersStatus").?.integer);
    try std.testing.expectEqual(false, obj.get("badHeadersOk").?.bool);
    try std.testing.expectEqualStrings("InvalidHeaders", obj.get("badHeadersStatusText").?.string);
    try std.testing.expectEqualStrings("InvalidHeaders", obj.get("badHeadersError").?.string);
    try std.testing.expectEqualStrings("InvalidMethod", obj.get("badMethodError").?.string);
    try std.testing.expectEqualStrings("InvalidBody", obj.get("badBodyError").?.string);
    try std.testing.expectEqualStrings("InvalidMaxResponseBytes", obj.get("badCamelMaxError").?.string);
    try std.testing.expectEqualStrings("InvalidMaxResponseBytes", obj.get("badSnakeMaxError").?.string);
    try std.testing.expectEqualStrings("InvalidUrl", obj.get("missingUrlError").?.string);
    try std.testing.expectEqualStrings("HostNotAllowed", obj.get("hostBlockedError").?.string);
}

test "a Bytes body is accepted where a number is InvalidBody" {
    // The replay path stubs `fetch` before the init is parsed, so a handler
    // test cannot reach this. `fetchSync` against a host with nothing
    // listening does: the init is parsed first, and only then does the
    // connection fail - so `InvalidBody` and everything else are
    // distinguishable at the error string.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "localhost",
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code =
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req) {
        \\  return Response.json({
        \\    bytesBodyError: fetchSync("http://localhost:9", { body: encodeUtf8("hi") }).json().error,
        \\    numberBodyError: fetchSync("http://localhost:9", { body: 42 }).json().error,
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<fetchsync-bytes-body>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // The number is still refused, which is the control: without it a run in
    // which neither body reached the parser would satisfy the assertion below.
    try std.testing.expectEqualStrings("InvalidBody", obj.get("numberBodyError").?.string);

    // The Bytes is not. It gets past the init and fails on the connection,
    // which is a different error entirely.
    const bytes_error = obj.get("bytesBodyError").?.string;
    try std.testing.expect(!std.mem.eql(u8, "InvalidBody", bytes_error));
}

test "fetchSync respects embedded capability policy host allowlist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
    });
    defer rt.deinit();
    rt.ctx.capability_policy = .{
        .egress = .{
            .enabled = true,
            .values = &[_][]const u8{"http://localhost:80"},
        },
    };

    const handler_code =
        \\function handler(req) {
        \\  return Response.json({
        \\    blocked: fetchSync("http://example.com").json().error,
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<fetchsync-policy>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("HostNotAllowed", obj.get("blocked").?.string);
}

// Regression guard: the concurrent fetch path (zttp:io parallel) shares
// parseFetchArgs with the sync path, so the egress allowlist is enforced at
// collection time. A disallowed host is rejected before a descriptor is
// registered, so it never opens a socket; its position in the results array
// stays (undefined) because parallel() is positional.
test "parallel fetch enforces egress allowlist - disallowed host never registers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{ .outbound_http_enabled = true });
    defer rt.deinit();
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"http://localhost:80"} },
    };

    // Both thunks target a disallowed host: no descriptor registers, so
    // both positions are undefined and example.com is never connected.
    const handler_code =
        \\import { parallel } from "zttp:io";
        \\function a() { return fetchSync("http://example.com/one"); }
        \\function b() { return fetchSync("http://example.com/two"); }
        \\function handler(req) {
        \\  const results = parallel([a, b]);
        \\  const blocked = results[0] === undefined && results[1] === undefined;
        \\  return Response.json({ count: results.length, blocked: blocked });
        \\}
    ;
    try rt.loadHandler(handler_code, "<parallel-egress-blocked>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("count").?.integer);
    try std.testing.expect(parsed.value.object.get("blocked").?.bool);
}

// Discrimination: an allowlisted host passes through the parallel path
// (registers, executes, returns 200) while a disallowed sibling yields
// undefined at its own position.
test "parallel fetch allows allowlisted host and drops disallowed one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .echo_request_json);
    defer server.join() catch {};
    try server.start();

    const allowed_url = try server.url(allocator, "/ok");
    defer allocator.free(allowed_url);

    const rt = try HandlerInstance.init(allocator, .{ .outbound_http_enabled = true });
    defer rt.deinit();
    var endpoint_buf: [512]u8 = undefined;
    const allowed = [_][]const u8{egressEndpoint(allowed_url, &endpoint_buf)};
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &allowed },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback),
    };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ parallel }} from "zttp:io";
        \\function allowed() {{ return fetchSync("{s}"); }}
        \\function blocked() {{ return fetchSync("http://example.com/x"); }}
        \\function handler(req) {{
        \\  const results = parallel([allowed, blocked]);
        \\  return Response.json({{
        \\    count: results.length,
        \\    status: results[0] === undefined ? 0 : results[0].status,
        \\    blockedUndefined: results[1] === undefined
        \\  }});
        \\}}
    , .{allowed_url});
    try rt.loadHandler(handler_code, "<parallel-egress-mixed>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    // The allowlisted host actually executed and returned the echo server's
    // 201 at its own position; the disallowed host's position is undefined.
    try std.testing.expectEqual(@as(i64, 201), obj.get("status").?.integer);
    try std.testing.expect(obj.get("blockedUndefined").?.bool);
}

// The endpoint check authorizes the name. These two cover what the name
// answers with: the scope of the resolved address, checked before the socket.
// `TestHttpServer` accepts exactly one connection and then exits, so a second
// fetch that still gets served is proof the first one never connected - a
// denial that returned the right string while opening the socket anyway would
// consume that single accept and fail here.
test "a resolved scope outside policy denies before the socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .echo_request_json);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/ok");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{ .outbound_http_enabled = true });
    defer rt.deinit();
    var endpoint_buf: [512]u8 = undefined;
    const allowed = [_][]const u8{egressEndpoint(url, &endpoint_buf)};
    // The endpoint is allowed. Only the scope is not: 127.0.0.1 is loopback.
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &allowed },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.public),
    };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\function handler(req) {{
        \\  const res = fetchSync("{s}");
        \\  return Response.json({{ status: res.status, error: res.error }});
        \\}}
    , .{url});
    try rt.loadHandler(handler_code, "<egress-scope-denied>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    {
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 599), obj.get("status").?.integer);
        try std.testing.expectEqualStrings("AddressScopeNotAllowed", obj.get("error").?.string);
    }

    // Grant the scope the address actually has. The server still has its one
    // accept, so this reaches it and echoes 201.
    rt.ctx.capability_policy.egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback);
    {
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 201), parsed.value.object.get("status").?.integer);
    }
}

test "a denial names the guard, not the request's own bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zq.security_events.initGlobal(std.testing.allocator, 32);
    defer zq.security_events.deinitGlobal();

    var server = try TestHttpServer.init(allocator, .echo_request_json);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/secret-looking-path");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{ .outbound_http_enabled = true });
    defer rt.deinit();
    var endpoint_buf: [512]u8 = undefined;
    const allowed = [_][]const u8{egressEndpoint(url, &endpoint_buf)};
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = &allowed },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.public),
    };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\function handler(req) {{
        \\  return Response.json({{ error: fetchSync("{s}").error }});
        \\}}
    , .{url});
    try rt.loadHandler(handler_code, "<denial-telemetry>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    {
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
    }

    const stream = zq.security_events.getGlobal() orelse return error.TestUnexpectedResult;
    var drained: [32]zq.security_events.SecurityEvent = undefined;
    const count = stream.drain(&drained);
    // Floor: no event means the assertions below hold over nothing.
    try std.testing.expect(count >= 1);

    var saw_denial = false;
    for (drained[0..count]) |event| {
        if (event.kind != .policy_denied) continue;
        saw_denial = true;
        try std.testing.expectEqualStrings("http.outbound", event.actionSlice());
        try std.testing.expectEqualStrings("address_scope", event.resourceKindSlice());
        // The sink that refused, not the destination the request asked for.
        try std.testing.expectEqualStrings("egress_connect", event.resourceIdSlice());
        try std.testing.expectEqualStrings("address_scope_not_allowed", event.detailSlice());
        // Nothing the request chose reaches the stream: not the host, not the
        // port, not the path.
        for ([_][]const u8{ "127.0.0.1", "secret-looking-path" }) |chosen| {
            try std.testing.expect(std.mem.indexOf(u8, event.resourceIdSlice(), chosen) == null);
            try std.testing.expect(std.mem.indexOf(u8, event.detailSlice(), chosen) == null);
            try std.testing.expect(std.mem.indexOf(u8, event.moduleSlice(), chosen) == null);
        }
    }
    try std.testing.expect(saw_denial);

    // Drain the server's single accept so `join` returns.
    rt.ctx.capability_policy.egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback);
    var drain = try rt.executeHandler(request.asView());
    drain.deinit();
}

test "a policy that names no scope permits no connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .echo_request_json);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/ok");
    defer allocator.free(url);

    // No capability policy at all: the endpoint list admits everything and the
    // scope set names nothing, which is the whole decision.
    const rt = try HandlerInstance.init(allocator, .{ .outbound_http_enabled = true });
    defer rt.deinit();

    const handler_code = try std.fmt.allocPrint(allocator,
        \\function handler(req) {{
        \\  const res = fetchSync("{s}");
        \\  return Response.json({{ error: res.error }});
        \\}}
    , .{url});
    try rt.loadHandler(handler_code, "<egress-scope-unnamed>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("AddressScopeNotAllowed", parsed.value.object.get("error").?.string);

    // Drain the server's single accept so `join` returns.
    rt.ctx.capability_policy.egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback);
    var drain = try rt.executeHandler(request.asView());
    drain.deinit();
}

// Change 2: the dev/serve contract-derived allowlist arrives via
// RuntimeConfig.dev_capability_policy and is applied by applyEmbeddedCapabilityPolicy
// on top of the (empty) embedded stub. Enforced identically on the sync path.
test "dev_capability_policy config enforces egress on sync fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .dev_capability_policy = .{ .egress = .{ .enabled = true, .values = &[_][]const u8{"http://localhost:80"} } },
    });
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  return Response.json({ blocked: fetchSync("http://example.com").json().error });
        \\}
    ;
    try rt.loadHandler(handler_code, "<dev-egress-sync>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("HostNotAllowed", parsed.value.object.get("blocked").?.string);
}

test "dev_capability_policy config applies env cache and sql sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .dev_capability_policy = .{
            .env = .{ .enabled = true, .values = &[_][]const u8{"API_KEY"} },
            .cache = .{ .enabled = true, .values = &[_][]const u8{"sessions"} },
            .sql = .{ .enabled = true, .values = &[_][]const u8{"listTodos"}, .queries = &.{} },
        },
    });
    defer rt.deinit();

    try std.testing.expect(rt.ctx.capability_policy.allowsEnv("API_KEY"));
    try std.testing.expect(!rt.ctx.capability_policy.allowsEnv("OTHER"));
    try std.testing.expect(rt.ctx.capability_policy.allowsCacheNamespace("sessions"));
    try std.testing.expect(!rt.ctx.capability_policy.allowsCacheNamespace("other"));
    try std.testing.expect(rt.ctx.capability_policy.allowsSqlQuery("listTodos"));
    try std.testing.expect(!rt.ctx.capability_policy.allowsSqlQuery("dropTodos"));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
const probeSetenv = setenv;
const probeUnsetenv = unsetenv;

// The three sinks below already check before their effects. These probe that
// the check is what stops the effect - a guard that returned the right answer
// and let the operation run would pass an assertion on its return value.
test "a denied env key never reaches the handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = probeSetenv("ZTTP_PROBE_ALLOWED", "visible", 1);
    _ = probeSetenv("ZTTP_PROBE_DENIED", "secret", 1);
    defer {
        _ = probeUnsetenv("ZTTP_PROBE_ALLOWED");
        _ = probeUnsetenv("ZTTP_PROBE_DENIED");
    }

    const rt = try HandlerInstance.init(allocator, .{
        .dev_capability_policy = .{
            .env = .{ .enabled = true, .values = &[_][]const u8{"ZTTP_PROBE_ALLOWED"} },
        },
    });
    defer rt.deinit();

    const handler_code =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ allowed: env("ZTTP_PROBE_ALLOWED") });
        \\}
    ;
    try rt.loadHandler(handler_code, "<env-allowed>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    {
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("visible", parsed.value.object.get("allowed").?.string);
    }

    // The denied key throws at the guard, so its value has no path into the
    // response at all.
    const denied_code =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ denied: env("ZTTP_PROBE_DENIED") });
        \\}
    ;
    try rt.loadHandler(denied_code, "<env-denied>");
    const request_val = try rt.createRequestObject(request.asView());
    try std.testing.expectError(
        error.NativeFunctionError,
        rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}),
    );
    rt.resetForNextRequest();
}

test "a denied cache namespace never creates the store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cache_slot = @intFromEnum(zq.module_slots.Slot.cache);
    const policy = zq.RuntimePolicy{
        .cache = .{ .enabled = true, .values = &[_][]const u8{"allowed"} },
    };

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    // An allowed namespace reaches the store, so the slot holds one.
    {
        const rt = try HandlerInstance.init(allocator, .{ .dev_capability_policy = policy });
        defer rt.deinit();
        try rt.loadHandler(
            \\import { cacheSet } from "zttp:cache";
            \\function handler(req) {
            \\  cacheSet("allowed", "k", "v");
            \\  return Response.json({ wrote: true });
            \\}
        , "<cache-allowed>");
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        try std.testing.expect(rt.ctx.module_state[cache_slot] != null);
    }

    // A denied one does not, for any of the five operations. The guard runs
    // before getOrCreateStore, so there is no store to have read, mutated, or
    // counted - a stronger statement than "the deny helper returned false".
    const denied_calls = [_][]const u8{
        "cacheGet(\"blocked\", \"k\")",
        "cacheSet(\"blocked\", \"k\", \"v\")",
        "cacheDelete(\"blocked\", \"k\")",
        "cacheIncr(\"blocked\", \"k\", 1)",
        "cacheStats(\"blocked\")",
    };
    for (denied_calls) |call| {
        const rt = try HandlerInstance.init(allocator, .{ .dev_capability_policy = policy });
        defer rt.deinit();
        const code = try std.fmt.allocPrint(allocator,
            \\import {{ cacheGet, cacheSet, cacheDelete, cacheIncr, cacheStats }} from "zttp:cache";
            \\function handler(req) {{
            \\  return Response.json({{ out: {s} }});
            \\}}
        , .{call});
        try rt.loadHandler(code, "<cache-denied>");
        const request_val = try rt.createRequestObject(request.asView());
        try std.testing.expectError(
            error.NativeFunctionError,
            rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}),
        );
        rt.resetForNextRequest();
        try std.testing.expect(rt.ctx.module_state[cache_slot] == null);
    }
}

test "a denied sql write never reaches the database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/probe.db", .{dir});

    // Writes are allowed by name. `insertDenied` is not one of them, and the
    // row count in the file afterwards is what says whether the guard stopped
    // the statement or merely reported on it.
    const policy = zq.RuntimePolicy{
        .sql = .{
            .enabled = true,
            .queries = &.{
                zq.handler_policy.normalizedSqlQuery("makeTable", false),
                zq.handler_policy.normalizedSqlQuery("insertAllowed", false),
            },
        },
    };

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    {
        const rt = try HandlerInstance.init(allocator, .{
            .sqlite_path = db_path,
            .dev_capability_policy = policy,
        });
        defer rt.deinit();
        try rt.loadHandler(
            \\import { sql, sqlExec } from "zttp:sql";
            \\function handler(req) {
            \\  sql("makeTable", "CREATE TABLE t (n INTEGER)");
            \\  sql("insertAllowed", "INSERT INTO t VALUES (1)");
            \\  sqlExec("makeTable");
            \\  sqlExec("insertAllowed");
            \\  return Response.json({ wrote: true });
            \\}
        , "<sql-write-allowed>");
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), countRows(allocator, db_path));

    {
        const rt = try HandlerInstance.init(allocator, .{
            .sqlite_path = db_path,
            .dev_capability_policy = policy,
        });
        defer rt.deinit();
        try rt.loadHandler(
            \\import { sql, sqlExec } from "zttp:sql";
            \\function handler(req) {
            \\  sql("insertDenied", "INSERT INTO t VALUES (2)");
            \\  sqlExec("insertDenied");
            \\  return Response.json({ wrote: true });
            \\}
        , "<sql-write-denied>");
        const request_val = try rt.createRequestObject(request.asView());
        try std.testing.expectError(
            error.NativeFunctionError,
            rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}),
        );
        rt.resetForNextRequest();
    }
    try std.testing.expectEqual(@as(usize, 1), countRows(allocator, db_path));

    // The same name is not a read either: the split is by operation, so an
    // allowed write name does not satisfy a read.
    {
        const rt = try HandlerInstance.init(allocator, .{
            .sqlite_path = db_path,
            .dev_capability_policy = policy,
        });
        defer rt.deinit();
        try std.testing.expect(rt.ctx.capability_policy.allowsSqlWrite("insertAllowed"));
        try std.testing.expect(!rt.ctx.capability_policy.allowsSqlQuery("insertAllowed"));
    }
}

fn countRows(allocator: std.mem.Allocator, path: []const u8) usize {
    var db = zq.sqlite.Db.openReadOnly(allocator, path) catch return 0;
    defer db.close();
    var stmt = db.prepare("SELECT n FROM t") catch return 0;
    defer stmt.finalize();
    var rows: usize = 0;
    while (stmt.step() == zq.sqlite.c.SQLITE_ROW) rows += 1;
    return rows;
}

// ...and on the parallel path, via the same config-supplied allowlist.
test "dev_capability_policy config enforces egress on parallel fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .dev_capability_policy = .{ .egress = .{ .enabled = true, .values = &[_][]const u8{"http://localhost:80"} } },
    });
    defer rt.deinit();

    const handler_code =
        \\import { parallel } from "zttp:io";
        \\function a() { return fetchSync("http://example.com/one"); }
        \\function b() { return fetchSync("http://example.com/two"); }
        \\function handler(req) {
        \\  const results = parallel([a, b]);
        \\  const blocked = results[0] === undefined && results[1] === undefined;
        \\  return Response.json({ count: results.length, blocked: blocked });
        \\}
    ;
    try rt.loadHandler(handler_code, "<dev-egress-parallel>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("count").?.integer);
    try std.testing.expect(parsed.value.object.get("blocked").?.bool);
}

test "fetchSync sends request data and exposes response helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .echo_request_json);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/inspect?mode=1");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "127.0.0.1",
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code = try std.fmt.allocPrint(
        allocator,
        \\function handler(req) {{
        \\  const init = {{
        \\    method: "POST",
        \\    headers: {{
        \\      "Content-Type": "text/plain",
        \\      "X-Test": "alpha"
        \\    }},
        \\    body: "ping"
        \\  }};
        \\  const resp = fetchSync("{s}", init);
        \\  const rawBody = resp.text();
        \\  const data = JSON.parse(rawBody);
        \\  return Response.json({{
        \\    status: resp.status,
        \\    ok: resp.ok,
        \\    contentType: resp.headers.get("content-type"),
        \\    reply: resp.headers.get("X-Reply"),
        \\    rawBody: rawBody,
        \\    method: data.method,
        \\    path: data.path,
        \\    requestType: data.contentType,
        \\    requestHeader: data.xTest,
        \\    requestBody: data.body,
        \\    requestLength: data.contentLength,
        \\    transferEncoding: data.transferEncoding,
        \\    requestRaw: data.raw
        \\  }});
        \\}}
    ,
        .{url},
    );
    defer allocator.free(handler_code);
    try rt.loadHandler(handler_code, "<fetchsync-success>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try server.join();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 201), obj.get("status").?.integer);
    try std.testing.expectEqual(true, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("application/json", obj.get("contentType").?.string);
    try std.testing.expectEqualStrings("ok", obj.get("reply").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("rawBody").?.string, "\"method\":\"POST\"") != null);
    try std.testing.expectEqualStrings("POST", obj.get("method").?.string);
    try std.testing.expectEqualStrings("/inspect?mode=1", obj.get("path").?.string);
    try std.testing.expectEqualStrings("text/plain", obj.get("requestType").?.string);
    try std.testing.expectEqualStrings("alpha", obj.get("requestHeader").?.string);
    try std.testing.expectEqualStrings("ping", obj.get("requestBody").?.string);
    try std.testing.expectEqualStrings("4", obj.get("requestLength").?.string);
    try std.testing.expectEqualStrings("", obj.get("transferEncoding").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("requestRaw").?.string, "POST /inspect?mode=1 HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("requestRaw").?.string, "content-length: 4\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("requestRaw").?.string, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("requestRaw").?.string, "X-Test: alpha\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("requestRaw").?.string, "\r\n\r\nping") != null);
}

test "zttp fetch replay consumes traced inner and outer rows and preserves headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();

    const io_calls = [_]zq.trace.IoEntry{
        .{
            .seq = 0,
            .module = "http",
            .func = "fetchSync",
            .args_json = "[\"http://example.com/weather\"]",
            .result_json = "{\"status\":200,\"statusText\":\"Origin Supplied\",\"ok\":true,\"headers\":{\"content-type\":\"application/json\",\"x-request-id\":\"trace-123\"},\"body\":\"{\\\"temperature\\\":21}\"}",
        },
        .{
            .seq = 1,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[\"http://example.com/weather\"]",
            .result_json = "{\"status\":200,\"statusText\":\"Origin Supplied\",\"ok\":true,\"headers\":{\"content-type\":\"application/json\",\"x-request-id\":\"trace-123\"},\"body\":\"{\\\"temperature\\\":21}\"}",
        },
        .{
            .seq = 2,
            .module = "env",
            .func = "env",
            .args_json = "[\"NEXT\"]",
            .result_json = "\"after-fetch\"",
        },
    };
    var replay_state = zq.trace.ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        zq.trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &zq.trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    const handler_code =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const response = fetch("http://example.com/weather");
        \\  const body = response.json();
        \\  return Response.json({
        \\    statusText: response.statusText,
        \\    requestId: response.headers.get("x-request-id"),
        \\    contentType: response.headers.get("content-type"),
        \\    temperature: body.temperature,
        \\    next: env("NEXT")
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<fetch-replay-trace>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("Origin Supplied", obj.get("statusText").?.string);
    try std.testing.expectEqualStrings("trace-123", obj.get("requestId").?.string);
    try std.testing.expectEqualStrings("application/json", obj.get("contentType").?.string);
    try std.testing.expectEqual(@as(i64, 21), obj.get("temperature").?.integer);
    try std.testing.expectEqualStrings("after-fetch", obj.get("next").?.string);
    try std.testing.expectEqual(@as(u32, 3), replay_state.cursor);
    try std.testing.expectEqual(@as(u32, 0), replay_state.divergences);
}

test "zttp fetch replay preserves missing content-type header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();

    const io_calls = [_]zq.trace.IoEntry{
        .{
            .seq = 0,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[\"http://example.com/plain\"]",
            .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{},\"body\":\"plain\"}",
        },
    };
    var replay_state = zq.trace.ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        zq.trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &zq.trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    const handler_code =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const response = fetch("http://example.com/plain");
        \\  return Response.json({
        \\    hasContentType: response.headers.has("content-type"),
        \\    contentType: response.headers.get("content-type") ?? "missing"
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<fetch-replay-missing-content-type>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(false, obj.get("hasContentType").?.bool);
    try std.testing.expectEqualStrings("missing", obj.get("contentType").?.string);
    try std.testing.expectEqual(@as(u32, 1), replay_state.cursor);
    try std.testing.expectEqual(@as(u32, 0), replay_state.divergences);
}

// Mirrors examples/fetch/weather-forecasts.ts (the demo handler). Embedded as
// plain JS so the replay tests below exercise the real fetch -> json() -> shape
// pipeline without the type-import surface; behavior is identical.
const weather_handler_src =
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  if (req.method !== "GET") {
    \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
    \\  }
    \\  if (req.path !== "/" && req.path !== "/weather") {
    \\    return Response.json({ error: "not_found" }, { status: 404 });
    \\  }
    \\  const upstream = fetch("https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current=temperature_2m,relative_humidity_2m,wind_speed_10m,is_day&timezone=auto", {
    \\    headers: { "Accept": "application/json" },
    \\    maxResponseBytes: 65536,
    \\  });
    \\  if (!upstream.ok) {
    \\    return Response.json({ error: "weather_unavailable", upstreamStatus: upstream.status }, { status: 502 });
    \\  }
    \\  const forecast = upstream.json();
    \\  return Response.json({
    \\    app: "Weather Forecasts",
    \\    source: "open-meteo",
    \\    upstreamRequestId: upstream.headers.get("x-request-id") ?? "none",
    \\    coordinates: { latitude: forecast.latitude, longitude: forecast.longitude },
    \\    timezone: forecast.timezone,
    \\    current: {
    \\      temperature: forecast.current.temperature_2m,
    \\      humidity: forecast.current.relative_humidity_2m,
    \\      isDay: forecast.current.is_day,
    \\    },
    \\  });
    \\}
;

test "weather handler parses Open-Meteo forecast and surfaces request id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();

    // The upstream body is a JSON string nested inside result_json, hence the
    // doubled escaping. Named so result_json reads as wrapper ++ body ++ close.
    const forecast_body = "{\\\"latitude\\\":52.52,\\\"longitude\\\":13.41,\\\"timezone\\\":\\\"Europe/Berlin\\\",\\\"current\\\":{\\\"temperature_2m\\\":21.5,\\\"relative_humidity_2m\\\":56,\\\"is_day\\\":1}}";
    const io_calls = [_]zq.trace.IoEntry{
        .{
            .seq = 0,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[\"https://api.open-meteo.com/v1/forecast\"]",
            .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{\"content-type\":\"application/json\",\"x-request-id\":\"meteo-123\"},\"body\":\"" ++ forecast_body ++ "\"}",
        },
    };
    var replay_state = zq.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
    rt.ctx.setModuleState(zq.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zq.trace.ReplayState.deinitOpaque);
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    try rt.loadHandler(weather_handler_src, "<weather-replay-ok>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/weather"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("open-meteo", obj.get("source").?.string);
    try std.testing.expectEqualStrings("Europe/Berlin", obj.get("timezone").?.string);
    try std.testing.expectEqualStrings("meteo-123", obj.get("upstreamRequestId").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 52.52), obj.get("coordinates").?.object.get("latitude").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 21.5), obj.get("current").?.object.get("temperature").?.float, 0.001);
    try std.testing.expectEqual(@as(i64, 56), obj.get("current").?.object.get("humidity").?.integer);
    try std.testing.expectEqual(@as(u32, 1), replay_state.cursor);
    try std.testing.expectEqual(@as(u32, 0), replay_state.divergences);
}

test "weather handler returns 502 when upstream is not ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();

    const io_calls = [_]zq.trace.IoEntry{
        .{
            .seq = 0,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[\"https://api.open-meteo.com/v1/forecast\"]",
            .result_json = "{\"status\":503,\"statusText\":\"Service Unavailable\",\"ok\":false,\"headers\":{\"content-type\":\"application/json\"},\"body\":\"{}\"}",
        },
    };
    var replay_state = zq.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
    rt.ctx.setModuleState(zq.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zq.trace.ReplayState.deinitOpaque);
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    try rt.loadHandler(weather_handler_src, "<weather-replay-502>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/weather"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 502), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "weather_unavailable") != null);
    try std.testing.expectEqual(@as(u32, 1), replay_state.cursor);
    try std.testing.expectEqual(@as(u32, 0), replay_state.divergences);
}

test "weather handler returns 404 for an unknown path without any egress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();

    // No recorded I/O: the not-found path must short-circuit before fetch.
    const io_calls = [_]zq.trace.IoEntry{};
    var replay_state = zq.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
    rt.ctx.setModuleState(zq.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zq.trace.ReplayState.deinitOpaque);
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    try rt.loadHandler(weather_handler_src, "<weather-replay-404>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/unknown"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 404), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "not_found") != null);
    // cursor stays at 0: fetch was never reached, so no egress happened.
    try std.testing.expectEqual(@as(u32, 0), replay_state.cursor);
    try std.testing.expectEqual(@as(u32, 0), replay_state.divergences);
}

test "buildServiceUrl renders service params and query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const params = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(params, try rt.ctx.atoms.intern("id"), try rt.ctx.createString("42"));

    const query = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("mode"), try rt.ctx.createString("a b"));

    const init = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(init, try rt.ctx.atoms.intern("params"), params.toValue());
    try rt.ctx.setPropertyChecked(init, try rt.ctx.atoms.intern("query"), query.toValue());

    const url = try buildServiceUrl(rt, rt.ctx, "http://users.internal", "/inspect/:id", init);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("http://users.internal/inspect/42?mode=a%20b", url);
}

test "buildFetchUrl appends a dynamic query to a literal base and percent-encodes values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    const pool = rt.ctx.hidden_class_pool.?;

    // The shape the weather app builds: user-supplied coordinates plus static
    // request params, all riding in the dynamic `query` object.
    const query = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("latitude"), try rt.ctx.createString("40.71"));
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("longitude"), try rt.ctx.createString("-74.01"));
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("current"), try rt.ctx.createString("temperature_2m,wind_speed_10m"));
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("timezone"), try rt.ctx.createString("auto"));

    const init = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(init, try rt.ctx.atoms.intern("query"), query.toValue());

    const url = switch (try buildFetchUrl(rt, pool, "https://api.open-meteo.com/v1/forecast", init)) {
        .ok => |u| u,
        .err => return error.UnexpectedFetchUrlError,
    };
    defer allocator.free(url);

    // Insertion order is preserved; `-` and `.` are unreserved, the comma is encoded.
    try std.testing.expectEqualStrings(
        "https://api.open-meteo.com/v1/forecast?latitude=40.71&longitude=-74.01&current=temperature_2m%2Cwind_speed_10m&timezone=auto",
        url,
    );
}

test "buildFetchUrl returns a copy of the literal base when there is no query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    const pool = rt.ctx.hidden_class_pool.?;

    // An init object with only non-query fields leaves the URL untouched.
    const init = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(init, try rt.ctx.atoms.intern("method"), try rt.ctx.createString("GET"));

    const url = switch (try buildFetchUrl(rt, pool, "https://api.open-meteo.com/v1/forecast", init)) {
        .ok => |u| u,
        .err => return error.UnexpectedFetchUrlError,
    };
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.open-meteo.com/v1/forecast", url);
}

test "buildFetchUrl uses & when the literal base already has a query string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    const pool = rt.ctx.hidden_class_pool.?;

    const query = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(query, try rt.ctx.atoms.intern("latitude"), try rt.ctx.createString("1.5"));

    const init = try rt.ctx.createObject(null);
    try rt.ctx.setPropertyChecked(init, try rt.ctx.atoms.intern("query"), query.toValue());

    const url = switch (try buildFetchUrl(rt, pool, "https://api.example.com/v1?format=json", init)) {
        .ok => |u| u,
        .err => return error.UnexpectedFetchUrlError,
    };
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.example.com/v1?format=json&latitude=1.5", url);
}

test "fetchSync enforces response byte limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .large_plain_text);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/too-large");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "127.0.0.1",
        .outbound_max_response_bytes = 64,
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code = try std.fmt.allocPrint(
        allocator,
        \\function handler(req) {{
        \\  const resp = fetchSync("{s}", {{ max_response_bytes: 8 }});
        \\  const data = resp.json();
        \\  return Response.json({{
        \\    status: resp.status,
        \\    ok: resp.ok,
        \\    error: data.error,
        \\    details: data.details
        \\  }});
        \\}}
    ,
        .{url},
    );
    defer allocator.free(handler_code);
    try rt.loadHandler(handler_code, "<fetchsync-too-large>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try server.join();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), obj.get("status").?.integer);
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("ResponseTooLarge", obj.get("error").?.string);
    try std.testing.expectEqualStrings("response exceeded max_response_bytes", obj.get("details").?.string);
}

test "a runtime refuses a zero outbound timeout instead of running unbounded" {
    try std.testing.expectError(
        error.ZeroOutboundTimeout,
        HandlerInstance.init(std.testing.allocator, .{ .outbound_timeout_ms = 0 }),
    );
}

test "fetchSync times out instead of hanging when upstream accepts and goes silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try TestHttpServer.init(allocator, .silent_hold);
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/never-answers");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "127.0.0.1",
        .outbound_timeout_ms = 200,
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code = try std.fmt.allocPrint(
        allocator,
        \\function handler(req) {{
        \\  const resp = fetchSync("{s}");
        \\  const data = resp.json();
        \\  return Response.json({{
        \\    status: resp.status,
        \\    ok: resp.ok,
        \\    error: data.error
        \\  }});
        \\}}
    ,
        .{url},
    );
    defer allocator.free(handler_code);
    try rt.loadHandler(handler_code, "<fetchsync-timeout>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    const clock_io = server.io_backend.io();
    const started = std.Io.Clock.awake.now(clock_io);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    const elapsed_ms = started.untilNow(clock_io, .awake).toMilliseconds();
    try server.join();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), obj.get("status").?.integer);
    try std.testing.expectEqual(false, obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("TimedOut", obj.get("error").?.string);
    // 200ms deadline; anything near a second means the watchdog never fired.
    try std.testing.expect(elapsed_ms < 2000);
}

/// Runs one `fetchSync` of `target_url` on its own thread, under a ceiling. A
/// fetch that outlives the ceiling is exactly the unbounded wait these tests
/// exist to catch, and its thread cannot be stopped, so the process exits
/// instead of hanging the step.
const CeilingFetch = struct {
    rt: *HandlerInstance,
    allocator: std.mem.Allocator,
    body: ?anyerror![]u8 = null,
    done: std.Io.Event = .unset,
    io: std.Io,

    const ceiling_ms: i64 = 5_000;

    fn run(self: *CeilingFetch) void {
        const request = HttpRequestOwned{
            .method = "GET",
            .url = "/",
            .headers = .empty,
            .body = null,
        };
        if (self.rt.executeHandler(request.asView())) |response| {
            var owned = response;
            defer owned.deinit();
            self.body = self.allocator.dupe(u8, owned.body);
        } else |err| {
            self.body = err;
        }
        self.done.set(self.io);
    }

    /// Returns the handler's JSON body and the elapsed milliseconds.
    fn fetch(allocator: std.mem.Allocator, target_url: []const u8, timeout_ms: u32) !struct { body: []u8, elapsed_ms: i64 } {
        const rt = try HandlerInstance.init(allocator, .{
            .outbound_http_enabled = true,
            .outbound_allow_host = "127.0.0.1",
            .outbound_timeout_ms = timeout_ms,
            .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
        });
        defer rt.deinit();
        const handler_code = try std.fmt.allocPrint(
            allocator,
            \\function handler(req) {{
            \\  const resp = fetchSync("{s}");
            \\  const data = resp.json();
            \\  return Response.json({{ status: resp.status, error: data.error, details: data.details }});
            \\}}
        ,
            .{target_url},
        );
        defer allocator.free(handler_code);
        try rt.loadHandler(handler_code, "<fetch-ceiling>");

        var clock_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer clock_backend.deinit();
        const io = clock_backend.io();

        var job: CeilingFetch = .{ .rt = rt, .allocator = allocator, .io = io };
        const started = std.Io.Clock.awake.now(io);
        const thread = try std.Thread.spawn(.{}, run, .{&job});
        const ceiling = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(ceiling_ms), .clock = .awake });
        while (!job.done.isSet()) {
            job.done.waitTimeout(io, .{ .deadline = ceiling }) catch {};
            if (!job.done.isSet() and ceiling.durationFromNow(io).raw.nanoseconds <= 0) {
                std.debug.print("fetch of {s} outlived its {d} ms ceiling: the outbound deadline did not fire\n", .{ target_url, ceiling_ms });
                std.process.exit(1);
            }
        }
        thread.join();
        const elapsed_ms = started.untilNow(io, .awake).toMilliseconds();
        return .{ .body = try job.body.?, .elapsed_ms = elapsed_ms };
    }
};

fn expectFetchTimedOut(allocator: std.mem.Allocator, body: []const u8, details: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), obj.get("status").?.integer);
    try std.testing.expectEqualStrings("TimedOut", obj.get("error").?.string);
    try std.testing.expectEqualStrings(details, obj.get("details").?.string);
}

test "a TLS handshake the peer never answers ends at the outbound deadline" {
    // The kernel completes the TCP handshake from the listen backlog, and
    // nothing ever reads the ClientHello: the stall sits inside std's TLS
    // setup, before the caller has a stream of its own.
    const allocator = std.testing.allocator;
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    const io = backend.io();
    const loopback = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const target_url = try std.fmt.allocPrint(allocator, "https://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
    defer allocator.free(target_url);
    const result = try CeilingFetch.fetch(allocator, target_url, 200);
    defer allocator.free(result.body);
    try expectFetchTimedOut(allocator, result.body, "TlsInitializationFailed");
    try std.testing.expect(result.elapsed_ms < 2000);
}

/// A non-blocking connect to `port` that is still pending after 100 ms, or
/// null when it completed. Completed descriptors are kept in `held` so the
/// listen queue stays full.
fn pendingConnect(port: u16, held: *std.ArrayList(std.posix.fd_t), allocator: std.mem.Allocator) !?std.posix.fd_t {
    const posix = std.posix;
    const rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(rc);
    const flags: usize = @intCast(posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0)));
    _ = posix.system.fcntl(fd, posix.F.SETFL, flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK")));
    var addr: posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    switch (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)))) {
        .SUCCESS => {},
        .INPROGRESS => {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            if (posix.system.poll(&fds, fds.len, 100) == 0) return fd;
        },
        else => {},
    }
    try held.append(allocator, fd);
    return null;
}

test "a connect the peer never answers ends at the outbound deadline" {
    // A listener that never accepts, with a backlog of one, stops answering
    // SYNs once its queue is full. Fill it until a raw connect stays pending;
    // the fetch's own connect is then the one that has no answer.
    const allocator = std.testing.allocator;
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    const io = backend.io();
    const loopback = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true, .kernel_backlog = 1 });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var held: std.ArrayList(std.posix.fd_t) = .empty;
    defer {
        for (held.items) |fd| _ = std.posix.system.close(fd);
        held.deinit(allocator);
    }
    const probe_fd = for (0..16) |_| {
        if (try pendingConnect(port, &held, allocator)) |fd| break fd;
    } else {
        // Linux can answer an overflowing queue with SYN cookies. This case
        // is then unobserved here, and the skip count says so.
        std.debug.print("listen queue never filled on this host; the unanswered-connect case did not run\n", .{});
        return error.SkipZigTest;
    };
    try held.append(allocator, probe_fd);

    const target_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
    defer allocator.free(target_url);
    const result = try CeilingFetch.fetch(allocator, target_url, 200);
    defer allocator.free(result.body);
    try expectFetchTimedOut(allocator, result.body, "Timeout");
    try std.testing.expect(result.elapsed_ms < 2000);
}

test "a fetch backend refuses a connect that has no deadline" {
    const allocator = std.testing.allocator;
    var backend = OutboundIo.init(allocator);
    defer backend.deinit();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 9);
    try std.testing.expectError(error.OptionUnsupported, address.connect(backend.io(), .{ .mode = .stream }));
}

fn writeCachedTeardownFixture(allocator: std.mem.Allocator, buffer: []u8) ![]const u8 {
    const source =
        \\function cachedOuter() {
        \\  const cachedInner = () => 1;
        \\  return cachedInner;
        \\}
    ;

    const source_rt = try HandlerInstance.init(allocator, .{});
    defer source_rt.deinit();
    return (try source_rt.loadCodeWithCachingNoHandler(
        source,
        "<cached-teardown-source>",
        buffer,
    )) orelse return error.TestExpectedCacheEntry;
}

test "cached bytecode teardown does not allocate after ownership transfer" {
    const allocator = std.testing.allocator;
    var cache_buffer: [64 * 1024]u8 = undefined;
    const cached = try writeCachedTeardownFixture(allocator, &cache_buffer);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const cached_rt = try HandlerInstance.init(failing.allocator(), .{});
    errdefer cached_rt.deinit();
    try cached_rt.loadFromCachedBytecodeNoHandler(cached);

    // Any allocation from this point fails. Cached bytecode teardown must use
    // ownership metadata reserved during load rather than allocating a seen-set.
    failing.fail_index = failing.alloc_index;
    cached_rt.deinit();
}

test "cached and source bytecode keep independent teardown ownership" {
    const allocator = std.testing.allocator;
    var cache_buffer: [64 * 1024]u8 = undefined;
    const cached = try writeCachedTeardownFixture(allocator, &cache_buffer);

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadFromCachedBytecodeNoHandler(cached);
    try rt.loadFromCachedBytecodeNoHandler(cached);
    try rt.loadCodeNoHandler(
        "function sourceOuter() { const sourceInner = () => 2; return sourceInner; }",
        "<source-teardown-owner>",
    );
}

test "HandlerInstance rejects malformed cached bytecode before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const code = [_]u8{
        @intFromEnum(zq.Opcode.ret),
    };
    const func = zq.FunctionBytecode{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = 0,
        .stack_size = 256,
        .flags = .{},
        .code = &code,
        .constants = &.{},
        .source_map = null,
        .line_table = null,
    };

    const no_shapes: []const []const zq.Atom = &.{};
    var buffer: [1024]u8 = undefined;
    var writer = bytecode_cache.SliceWriter{ .buffer = &buffer };
    try bytecode_cache.serializeBytecodeWithAtomsAndShapes(
        &func,
        &rt.ctx.atoms,
        no_shapes,
        &writer,
        allocator,
    );

    try std.testing.expectError(
        error.BytecodeVerificationFailed,
        rt.loadFromCachedBytecodeNoHandler(writer.getWritten()),
    );
}

test "request deadline arms and clears" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try HandlerInstance.init(allocator, .{ .request_timeout_ms = 50 });
    defer rt.deinit();

    rt.armRequestDeadline();
    try std.testing.expect(rt.ctx.deadline_ns != 0);
    rt.clearRequestDeadline();
    try std.testing.expectEqual(@as(u64, 0), rt.ctx.deadline_ns);
}

test "HandlerInstance rejects malformed nested cached bytecode before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const child_code = [_]u8{
        @intFromEnum(zq.Opcode.ret),
    };
    var child = zq.FunctionBytecode{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = 0,
        .stack_size = 256,
        .flags = .{},
        .code = &child_code,
        .constants = &.{},
        .source_map = null,
        .line_table = null,
    };
    const constants = [_]zq.JSValue{
        zq.JSValue.fromExternPtr(&child),
    };
    const parent_code = [_]u8{
        @intFromEnum(zq.Opcode.ret_undefined),
    };
    const parent = zq.FunctionBytecode{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = 0,
        .stack_size = 256,
        .flags = .{},
        .code = &parent_code,
        .constants = &constants,
        .source_map = null,
        .line_table = null,
    };

    const no_shapes: []const []const zq.Atom = &.{};
    var buffer: [2048]u8 = undefined;
    var writer = bytecode_cache.SliceWriter{ .buffer = &buffer };
    try bytecode_cache.serializeBytecodeWithAtomsAndShapes(
        &parent,
        &rt.ctx.atoms,
        no_shapes,
        &writer,
        allocator,
    );

    try std.testing.expectError(
        error.BytecodeVerificationFailed,
        rt.loadFromCachedBytecodeNoHandler(writer.getWritten()),
    );
}

test "AOT override fallback and success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const handler_code = "function handler(req) { return Response.json({ok:false}); }";
    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadHandler(handler_code, "<handler>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    const aot_ok: AotOverrideFn = struct {
        fn call(ctx: *zq.Context, args: []const zq.JSValue) anyerror!zq.JSValue {
            _ = args;
            return zq.http.createResponse(ctx, "{\"ok\":true}", 200, "application/json");
        }
    }.call;

    const aot_bail: AotOverrideFn = struct {
        fn call(_: *zq.Context, _: []const zq.JSValue) anyerror!zq.JSValue {
            return error.AotBail;
        }
    }.call;

    setAotOverrideForTest(aot_bail);
    defer setAotOverrideForTest(null);

    var fallback_response = try rt.executeHandler(request.asView());
    defer fallback_response.deinit();
    try std.testing.expectEqualStrings("{\"ok\":false}", fallback_response.body);

    setAotOverrideForTest(aot_ok);
    var aot_response = try rt.executeHandler(request.asView());
    defer aot_response.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", aot_response.body);
}

test "string prototype methods are callable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const proto = rt.ctx.string_prototype orelse return error.NoRootClass;
    const pool = rt.ctx.hidden_class_pool orelse return error.NoRootClass;
    const split_val = proto.getProperty(pool, zq.Atom.split) orelse return error.NoHandler;
    try std.testing.expect(split_val.isCallable());

    try rt.loadHandler("function handler(req){ return Response.text(typeof ''.split); }", "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("function", response.body);
}

test "request body split works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // First test: simple method call
    const simple_test = "function handler(req){ return Response.text('hello'); }";
    try rt.loadHandler(simple_test, "<test1>");

    var req1 = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };

    var resp1 = try rt.executeHandler(req1.asView());
    try std.testing.expectEqualStrings("hello", resp1.body);
    resp1.deinit();
    req1.deinit(allocator);

    // Reset and test property access
    const rt2 = try HandlerInstance.init(allocator, .{});
    defer rt2.deinit();

    const prop_test = "function handler(req){ return Response.text(req.method); }";
    try rt2.loadHandler(prop_test, "<test2>");

    var req2 = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "test"),
    };

    var resp2 = try rt2.executeHandler(req2.asView());
    try std.testing.expectEqualStrings("POST", resp2.body);
    resp2.deinit();
    req2.deinit(allocator);

    // Test typeof without var assignment
    const rt3 = try HandlerInstance.init(allocator, .{});
    defer rt3.deinit();

    const typeof_split = "function handler(req){ return Response.text(typeof 'a&b'.split('&')); }";
    try rt3.loadHandler(typeof_split, "<test3>");

    var req3 = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };

    var resp3 = try rt3.executeHandler(req3.asView());
    try std.testing.expectEqualStrings("object", resp3.body);
    resp3.deinit();
    req3.deinit(allocator);

    // Test simple var assignment
    const rt4 = try HandlerInstance.init(allocator, .{});
    defer rt4.deinit();

    const handler_code =
        "function handler(req){ let x = 'test'; return Response.text(x); }";
    try rt4.loadHandler(handler_code, "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt4.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("test", response.body);
}

test "for loop locals preserve numeric values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        "function handler(req){ for (let i of range(1)) { return Response.text(typeof i); } return Response.text('none'); }";
    try rt.loadHandler(handler_code, "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("number", response.body);
}

test "Number converts numeric cache-shaped strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req) {
        \\  const hits = Number("41");
        \\  return Response.json({ hits: hits });
        \\}
    ;
    try rt.loadHandler(handler_code, "<number-constructor>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"hits\":41}", response.body);
}

test "object property access works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req){
        \\  const obj = { name: 'Alice', age: 30 };
        \\  const name = obj.name;
        \\  const age = obj.age;
        \\  return Response.text([name, '-', String(age)].join(''));
        \\}
    ;
    try rt.loadHandler(handler_code, "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("Alice-30", response.body);
}

test "ENG-2: zero-arg user-named method on object literal is callable" {
    // Regression: a zero-arg method call on an object literal with a
    // user-defined property name (`({greet:()=>7}).greet()`) used to fall
    // through to NotCallable -> HTTP 500 because the get_field+call_method ->
    // get_field_call peephole fusion mis-resolved the dynamically-interned
    // atom. The fusion is now disabled (bytecode_opt.zig). Covers the literal
    // receiver, a multi-property literal, and a variable receiver.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req){
        \\  const a = ({greet:()=>7}).greet();
        \\  const b = ({x:1,wave:()=>9}).wave();
        \\  const o = { hi: () => 4 };
        \\  const c = o.hi();
        \\  return Response.text([String(a), '-', String(b), '-', String(c)].join(''));
        \\}
    ;
    try rt.loadHandler(handler_code, "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("7-9-4", response.body);
}

test "array indexing works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req){
        \\  const arr = [1, 2, 3];
        \\  const a = arr[0];
        \\  const b = arr[1];
        \\  const c = arr[2];
        \\  return Response.text([String(a), '-', String(b), '-', String(c)].join(''));
        \\}
    ;
    try rt.loadHandler(handler_code, "<test>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("1-2-3", response.body);
}

test "JSX rendering works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req){
        \\  const elem = <div>Hello</div>;
        \\  return Response.html(renderToString(elem));
        \\}
    ;
    // Load through the TSX frontend so element syntax is lowered before parsing.
    try rt.loadHandler(handler_code, "test.tsx");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("<div>Hello</div>", response.body);
}

test "handler loading refuses JavaScript file extensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rt = try HandlerInstance.init(arena.allocator(), .{});
    defer rt.deinit();
    const source = "function handler(req) { return Response.text('ok'); }";

    try std.testing.expectError(error.UnsupportedSourceExtension, rt.loadHandler(source, "handler.js"));
    try std.testing.expectError(error.UnsupportedSourceExtension, rt.loadHandler(source, "handler.jsx"));
}

test "loadCodeNoHandler supports benchmark-style scripts" {
    const allocator = std.heap.c_allocator;

    const script =
        \\function run(iterations) {
        \\  return iterations + 1;
        \\}
    ;

    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadCodeNoHandler(script, "<bench>");

    const args = [_]zq.JSValue{zq.JSValue.fromInt(10)};
    const result = try rt.callGlobalFunction("run", &args);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i32, 11), result.getInt());
}

test "loadCodeNoHandler supports imported benchmark-style scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dep_source =
        \\export function addOne(value) {
        \\  return value + 1;
        \\}
    ;
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "dep.ts",
        .data = dep_source,
    });

    const main_source =
        \\import { addOne } from "./dep.ts";
        \\function run(iterations) {
        \\  return addOne(iterations) + 1;
        \\}
    ;
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "main.ts",
        .data = main_source,
    });

    const entry_path = try std.fs.path.resolve(allocator, &.{ ".zig-cache", "tmp", tmp_dir.sub_path[0..], "main.ts" });

    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadCodeNoHandler(main_source, entry_path);

    const args = [_]zq.JSValue{zq.JSValue.fromInt(10)};
    const result = try rt.callGlobalFunction("run", &args);
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i32, 12), result.getInt());
}

test "durable run refuses the oplog while a recovery claim holds it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    try seedIncompleteDurableRandomStep(allocator, durable_dir, "order:busy", "charge", "0.5");

    const rt = try HandlerInstance.init(allocator, .{ .durable_oplog_dir = durable_dir });
    defer rt.deinit();

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  const key = req.headers.get("idempotency-key") ?? "missing";
        \\  return run(key, () => {
        \\    const seed = step("charge", () => Math.random());
        \\    return Response.json({ seed: seed });
        \\  });
        \\}
    ;
    try rt.loadHandler(handler_code, "<durable-busy>");

    const path = try durable_executor.buildDurableOplogPath(rt, "order:busy");
    defer allocator.free(path);

    // Hold the recovery-style advisory lock, as durable_recovery.OplogClaim
    // does for the duration of a re-execution.
    const path_z = try allocator.dupeZ(u8, path);
    const lock_fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(lock_fd >= 0);
    defer _ = std.c.close(lock_fd);
    try tryLockOplogFd(lock_fd);

    var request = try makeTestRequest(allocator, "GET", "/", "order:busy");
    defer request.deinit(allocator);

    const request_val = try rt.createRequestObject(request.asView());
    try std.testing.expectError(error.NativeFunctionError, rt.callGlobalFunction("handler", &[_]zq.JSValue{request_val}));
    rt.resetForNextRequest();

    // The refused run must not have touched the locked oplog.
    const source = try zq.file_io.readFile(allocator, path, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "\"fn\":\"Math.random\""));
    try std.testing.expect(!std.mem.containsAtLeast(u8, source, 1, "\"type\":\"complete\""));
}

fn ledgerInvariantBytes(buffer: []u8, scale: u8) ![]u8 {
    const invariant = @import("zttp_proof_checker").invariant;
    const size = invariant.header_size + "main".len + invariant.currency_record_size;
    if (buffer.len < size) return error.BufferTooSmall;
    @memcpy(buffer[0..8], invariant.magic);
    std.mem.writeInt(u16, buffer[8..10], invariant.schema_version_v1, .little);
    std.mem.writeInt(u16, buffer[10..12], @intFromEnum(invariant.Kind.balance_conservation_v1), .little);
    std.mem.writeInt(u16, buffer[12..14], "main".len, .little);
    std.mem.writeInt(u16, buffer[14..16], 1, .little);
    @memcpy(buffer[invariant.header_size..][0..4], "main");
    @memcpy(buffer[invariant.header_size + 4 ..][0..3], "USD");
    buffer[invariant.header_size + 7] = scale;
    const encoded = buffer[0..size];
    _ = try invariant.decode(encoded);
    return encoded;
}

fn ledgerTwoCurrencyInvariantBytes(buffer: []u8, usd_scale: u8) ![]u8 {
    const invariant = @import("zttp_proof_checker").invariant;
    const size = invariant.header_size + "main".len + 2 * invariant.currency_record_size;
    if (buffer.len < size) return error.BufferTooSmall;
    @memcpy(buffer[0..8], invariant.magic);
    std.mem.writeInt(u16, buffer[8..10], invariant.schema_version_v1, .little);
    std.mem.writeInt(u16, buffer[10..12], @intFromEnum(invariant.Kind.balance_conservation_v1), .little);
    std.mem.writeInt(u16, buffer[12..14], "main".len, .little);
    std.mem.writeInt(u16, buffer[14..16], 2, .little);
    @memcpy(buffer[invariant.header_size..][0..4], "main");
    @memcpy(buffer[invariant.header_size + 4 ..][0..3], "EUR");
    buffer[invariant.header_size + 7] = 2;
    @memcpy(buffer[invariant.header_size + 8 ..][0..3], "USD");
    buffer[invariant.header_size + 11] = usd_scale;
    const encoded = buffer[0..size];
    _ = try invariant.decode(encoded);
    return encoded;
}

/// One declared account rule, in the order the canonical payload requires:
/// exact rules before prefix rules, and byte order within each.
const LedgerMatcher = struct { exact: bool, value: []const u8 };

/// A schema 2 section declaring balance conservation and a set of account
/// rules over the one ledger `main` and the one currency USD.
fn ledgerDeclaredAccountsBytes(buffer: []u8, matchers: []const LedgerMatcher) ![]u8 {
    const invariant = @import("zttp_proof_checker").invariant;
    var payload_len: usize = 2;
    for (matchers) |matcher| {
        payload_len += invariant.account_matcher_header_size + matcher.value.len;
    }
    const size = invariant.header_size + "main".len + invariant.currency_record_size +
        2 * invariant.kind_record_header_size + payload_len;
    if (buffer.len < size) return error.BufferTooSmall;

    @memcpy(buffer[0..8], invariant.magic);
    std.mem.writeInt(u16, buffer[8..10], invariant.schema_version_v2, .little);
    std.mem.writeInt(u16, buffer[10..12], 2, .little);
    std.mem.writeInt(u16, buffer[12..14], "main".len, .little);
    std.mem.writeInt(u16, buffer[14..16], 1, .little);
    @memcpy(buffer[invariant.header_size..][0..4], "main");
    @memcpy(buffer[invariant.header_size + 4 ..][0..3], "USD");
    buffer[invariant.header_size + 7] = 2;

    var cursor: usize = invariant.header_size + 4 + invariant.currency_record_size;
    std.mem.writeInt(u16, buffer[cursor..][0..2], 1, .little);
    std.mem.writeInt(u16, buffer[cursor + 2 ..][0..2], 0, .little);
    cursor += invariant.kind_record_header_size;
    std.mem.writeInt(u16, buffer[cursor..][0..2], 2, .little);
    std.mem.writeInt(u16, buffer[cursor + 2 ..][0..2], @intCast(payload_len), .little);
    cursor += invariant.kind_record_header_size;
    std.mem.writeInt(u16, buffer[cursor..][0..2], @intCast(matchers.len), .little);
    cursor += 2;
    for (matchers) |matcher| {
        buffer[cursor] = if (matcher.exact) 1 else 2;
        std.mem.writeInt(u16, buffer[cursor + 1 ..][0..2], @intCast(matcher.value.len), .little);
        @memcpy(buffer[cursor + invariant.account_matcher_header_size ..][0..matcher.value.len], matcher.value);
        cursor += invariant.account_matcher_header_size + matcher.value.len;
    }

    const encoded = buffer[0..size];
    _ = try invariant.decode(encoded);
    return encoded;
}

fn ledgerScalar(allocator: std.mem.Allocator, path: []const u8, sql: [:0]const u8) !i64 {
    var db = try zq.sqlite.Db.openReadOnly(allocator, path);
    defer db.close();
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (stmt.step() != zq.sqlite.c.SQLITE_ROW) return error.NoRow;
    return zq.sqlite.c.sqlite3_column_int64(stmt.handle, 0);
}

fn ledgerStoredDigest(allocator: std.mem.Allocator, path: []const u8, out: *[64]u8) ![]const u8 {
    var db = try zq.sqlite.Db.openReadOnly(allocator, path);
    defer db.close();
    var stmt = try db.prepare("SELECT invariant_digest FROM ledger_meta WHERE singleton = 1");
    defer stmt.finalize();
    if (stmt.step() != zq.sqlite.c.SQLITE_ROW) return error.NoRow;
    const text = zq.sqlite.c.sqlite3_column_text(stmt.handle, 0);
    const len: usize = @intCast(zq.sqlite.c.sqlite3_column_bytes(stmt.handle, 0));
    if (len != out.len) return error.UnexpectedDigest;
    @memcpy(out[0..len], @as([*]const u8, @ptrCast(text))[0..len]);
    return out[0..len];
}

test "a declared account set refuses an undeclared posting and leaves the store untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const ledger_path = try std.fmt.allocPrint(allocator, "{s}/declared.sqlite", .{dir});
    var invariant_buffer: [128]u8 = undefined;
    const invariant_bytes = try ledgerDeclaredAccountsBytes(&invariant_buffer, &.{
        .{ .exact = true, .value = "clearing:main" },
        .{ .exact = false, .value = "asset:" },
    });
    const config = RuntimeConfig{
        .ledger_path = ledger_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    };

    {
        const rt = try HandlerInstance.init(allocator, config);
        defer rt.deinit();
        try rt.loadHandler(
            \\import { post, balance } from "zttp:ledger";
            \\function handler(req) {
            \\  const declared = post({ ledger: "main", currency: "USD", idempotencyKey: "declared", entries: [
            \\    { account: "asset:cash", amount: "-5" },
            \\    { account: "clearing:main", amount: "5" }
            \\  ] });
            \\  const prefixItself = post({ ledger: "main", currency: "USD", idempotencyKey: "prefix-itself", entries: [
            \\    { account: "asset:", amount: "-1" },
            \\    { account: "clearing:main", amount: "1" }
            \\  ] });
            \\  const nearMiss = post({ ledger: "main", currency: "USD", idempotencyKey: "near-miss", entries: [
            \\    { account: "assets:cash", amount: "-1" },
            \\    { account: "clearing:main", amount: "1" }
            \\  ] });
            \\  const wrongCase = post({ ledger: "main", currency: "USD", idempotencyKey: "wrong-case", entries: [
            \\    { account: "Clearing:main", amount: "-1" },
            \\    { account: "asset:cash", amount: "1" }
            \\  ] });
            \\  const zeroAmount = post({ ledger: "main", currency: "USD", idempotencyKey: "zero-amount", entries: [
            \\    { account: "asset:cash", amount: "-1" },
            \\    { account: "clearing:main", amount: "1" },
            \\    { account: "suspense:held", amount: "0" }
            \\  ] });
            \\  const cancelling = post({ ledger: "main", currency: "USD", idempotencyKey: "cancelling", entries: [
            \\    { account: "suspense:held", amount: "7" },
            \\    { account: "suspense:held", amount: "-7" }
            \\  ] });
            \\  const cash = balance("main", "USD", "asset:cash");
            \\  const clearing = balance("main", "USD", "clearing:main");
            \\  const suspense = balance("main", "USD", "suspense:held");
            \\  return Response.json({ declaredOk: declared.ok, prefixItselfOk: prefixItself.ok,
            \\    nearMissTag: nearMiss.error.tag, wrongCaseTag: wrongCase.error.tag,
            \\    zeroAmountTag: zeroAmount.error.tag, cancellingTag: cancelling.error.tag,
            \\    cash: cash.value, clearing: clearing.value, suspense: suspense.value });
            \\}
        , "<ledger-declared>");

        var request = try makeTestRequest(allocator, "GET", "/", null);
        defer request.deinit(allocator);
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        const body = parsed.value.object;
        try std.testing.expect(body.get("declaredOk").?.bool);
        // The prefix accepts its own bytes.
        try std.testing.expect(body.get("prefixItselfOk").?.bool);
        try std.testing.expectEqualStrings("undeclared_account", body.get("nearMissTag").?.string);
        try std.testing.expectEqualStrings("undeclared_account", body.get("wrongCaseTag").?.string);
        // A zero-amount entry is still an entry, and so is a pair that cancels
        // on one account: neither changes a balance, and both are refused.
        try std.testing.expectEqualStrings("undeclared_account", body.get("zeroAmountTag").?.string);
        try std.testing.expectEqualStrings("undeclared_account", body.get("cancellingTag").?.string);
        // The second group debits the prefix's own bytes, not `asset:cash`.
        try std.testing.expectEqualStrings("-5", body.get("cash").?.string);
        try std.testing.expectEqualStrings("6", body.get("clearing").?.string);
        try std.testing.expectEqualStrings("0", body.get("suspense").?.string);
    }

    // The refused groups left nothing behind: not an entry, not a balance row
    // for the undeclared account, and not an idempotency record that a later
    // retry would replay instead of re-deciding.
    try std.testing.expectEqual(@as(i64, 2), try ledgerScalar(allocator, ledger_path, "SELECT count(*) FROM ledger_postings"));
    try std.testing.expectEqual(@as(i64, 4), try ledgerScalar(allocator, ledger_path, "SELECT count(*) FROM ledger_entries"));
    try std.testing.expectEqual(@as(i64, 3), try ledgerScalar(allocator, ledger_path, "SELECT count(*) FROM ledger_balances"));
    try std.testing.expectEqual(
        @as(i64, 0),
        try ledgerScalar(allocator, ledger_path, "SELECT count(*) FROM ledger_balances WHERE account = 'suspense:held'"),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        try ledgerScalar(allocator, ledger_path, "SELECT count(*) FROM ledger_postings WHERE idempotency_key IN ('near-miss', 'wrong-case', 'zero-amount', 'cancelling')"),
    );

    // The same specification reopens the store it wrote.
    {
        const rt = try HandlerInstance.init(allocator, config);
        defer rt.deinit();
        try rt.loadHandler(
            \\import { balance } from "zttp:ledger";
            \\function handler(req) {
            \\  const cash = balance("main", "USD", "asset:cash");
            \\  return Response.json({ cash: cash.value });
            \\}
        , "<ledger-declared-reopen>");

        var request = try makeTestRequest(allocator, "GET", "/", null);
        defer request.deinit(allocator);
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("-5", parsed.value.object.get("cash").?.string);
    }

    // A narrower specification is a different document with a different
    // digest, so the store refuses it - and the stored digest is read back
    // afterwards, because a startup that rewrote metadata to make a mismatch
    // pass would produce exactly the same refusal on this one attempt and none
    // on the next.
    var stored_before: [64]u8 = undefined;
    const before = try ledgerStoredDigest(allocator, ledger_path, &stored_before);
    var narrow_buffer: [128]u8 = undefined;
    const narrowed = try ledgerDeclaredAccountsBytes(&narrow_buffer, &.{
        .{ .exact = true, .value = "clearing:main" },
    });
    try std.testing.expectError(error.LedgerConfigMismatch, HandlerInstance.init(allocator, .{
        .ledger_path = ledger_path,
        .invariant_section = narrowed,
        .invariant_coverage_accepted = true,
    }));
    var stored_after: [64]u8 = undefined;
    const after = try ledgerStoredDigest(allocator, ledger_path, &stored_after);
    try std.testing.expectEqualStrings(before, after);

    // And a store that already holds an account the same specification does
    // not declare is refused before it is served. The rename keeps every sum
    // intact, so nothing else in the baseline has anything to object to.
    var db = try zq.sqlite.Db.openReadWriteCreate(allocator, ledger_path);
    try db.exec(allocator, "UPDATE ledger_entries SET account = 'suspense:held' WHERE account = 'asset:cash'");
    try db.exec(allocator, "UPDATE ledger_balances SET account = 'suspense:held' WHERE account = 'asset:cash'");
    db.close();
    try std.testing.expectError(error.UndeclaredStoredAccount, HandlerInstance.init(allocator, config));
}

test "a store with no declared account set admits every account" {
    // The floor under the test above: without it, an account check that
    // refused everything would satisfy every refusal it asserts.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const ledger_path = try std.fmt.allocPrint(allocator, "{s}/undeclared.sqlite", .{dir});
    var invariant_buffer: [64]u8 = undefined;
    const invariant_bytes = try ledgerInvariantBytes(&invariant_buffer, 2);
    const config = RuntimeConfig{
        .ledger_path = ledger_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    };
    const rt = try HandlerInstance.init(allocator, config);
    defer rt.deinit();
    try rt.loadHandler(
        \\import { post } from "zttp:ledger";
        \\function handler(req) {
        \\  const result = post({ ledger: "main", currency: "USD", idempotencyKey: "any", entries: [
        \\    { account: "suspense:held", amount: "3" }, { account: "whatever", amount: "-3" }
        \\  ] });
        \\  return Response.text(result.ok ? "ok" : result.error.tag);
        \\}
    , "<ledger-undeclared>");
    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
}

test "protected ledger posts atomically and validates its baseline on reopen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const ledger_path = try std.fmt.allocPrint(allocator, "{s}/ledger.sqlite", .{dir});
    var invariant_buffer: [64]u8 = undefined;
    const invariant_bytes = try ledgerTwoCurrencyInvariantBytes(&invariant_buffer, 2);
    const config = RuntimeConfig{
        .ledger_path = ledger_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    };

    {
        const rt = try HandlerInstance.init(allocator, config);
        defer rt.deinit();
        try rt.loadHandler(
            \\import { post, balance } from "zttp:ledger";
            \\function handler(req) {
            \\  const first = post({ ledger: "main", currency: "USD", idempotencyKey: "initial", entries: [
            \\    { account: "source", amount: "9223372036854775807" },
            \\    { account: "sink", amount: "-9223372036854775807" }
            \\  ] });
            \\  const replay = post({ ledger: "main", currency: "USD", idempotencyKey: "initial", entries: [
            \\    { account: "source", amount: "9223372036854775807" },
            \\    { account: "sink", amount: "-9223372036854775807" }
            \\  ] });
            \\  const conflict = post({ ledger: "main", currency: "USD", idempotencyKey: "initial", entries: [
            \\    { account: "source", amount: "1" }, { account: "sink", amount: "-1" }
            \\  ] });
            \\  const unbalanced = post({ ledger: "main", currency: "USD", idempotencyKey: "unbalanced", entries: [
            \\    { account: "source", amount: "1" }
            \\  ] });
            \\  const invalid = post({ ledger: "main", currency: "USD", idempotencyKey: "invalid", entries: [
            \\    { account: "source", amount: "+1" }, { account: "sink", amount: "-1" }
            \\  ] });
            \\  const overflow = post({ ledger: "main", currency: "USD", idempotencyKey: "overflow", entries: [
            \\    { account: "source", amount: "1" }, { account: "sink", amount: "-1" }
            \\  ] });
            \\  const eur = post({ ledger: "main", currency: "EUR", idempotencyKey: "eur", entries: [
            \\    { account: "source", amount: "10" }, { account: "sink", amount: "-10" }
            \\  ] });
            \\  const cancelForward = post({ ledger: "main", currency: "USD", idempotencyKey: "cancel-forward", entries: [
            \\    { account: "source", amount: "1" }, { account: "source", amount: "-1" }
            \\  ] });
            \\  const cancelReverse = post({ ledger: "main", currency: "USD", idempotencyKey: "cancel-reverse", entries: [
            \\    { account: "source", amount: "-1" }, { account: "source", amount: "1" }
            \\  ] });
            \\  const source = balance("main", "USD", "source");
            \\  const sink = balance("main", "USD", "sink");
            \\  const eurSource = balance("main", "EUR", "source");
            \\  return Response.json({ firstOk: first.ok, firstReplayed: first.value.replayed,
            \\    replayOk: replay.ok, replayReplayed: replay.value.replayed,
            \\    conflictTag: conflict.error.tag, unbalancedTag: unbalanced.error.tag,
            \\    invalidTag: invalid.error.tag, overflowTag: overflow.error.tag,
            \\    eurOk: eur.ok, cancelForwardOk: cancelForward.ok, cancelReverseOk: cancelReverse.ok,
            \\    source: source.value, sink: sink.value, eurSource: eurSource.value });
            \\}
        , "<ledger-atomic>");

        var request = try makeTestRequest(allocator, "GET", "/", null);
        defer request.deinit(allocator);
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        const body = parsed.value.object;
        try std.testing.expect(body.get("firstOk").?.bool);
        try std.testing.expect(!body.get("firstReplayed").?.bool);
        try std.testing.expect(body.get("replayOk").?.bool);
        try std.testing.expect(body.get("replayReplayed").?.bool);
        try std.testing.expectEqualStrings("idempotency_conflict", body.get("conflictTag").?.string);
        try std.testing.expectEqualStrings("unbalanced", body.get("unbalancedTag").?.string);
        try std.testing.expectEqualStrings("invalid_input", body.get("invalidTag").?.string);
        try std.testing.expectEqualStrings("balance_overflow", body.get("overflowTag").?.string);
        try std.testing.expect(body.get("eurOk").?.bool);
        try std.testing.expect(body.get("cancelForwardOk").?.bool);
        try std.testing.expect(body.get("cancelReverseOk").?.bool);
        try std.testing.expectEqualStrings("9223372036854775807", body.get("source").?.string);
        try std.testing.expectEqualStrings("-9223372036854775807", body.get("sink").?.string);
        try std.testing.expectEqualStrings("10", body.get("eurSource").?.string);
    }

    // A new runtime validates the existing baseline before it can serve and
    // reads the same committed balances.
    {
        const rt = try HandlerInstance.init(allocator, config);
        defer rt.deinit();
        try rt.loadHandler(
            \\import { balance } from "zttp:ledger";
            \\function handler(req) {
            \\  const source = balance("main", "USD", "source");
            \\  return Response.json({ source: source.value });
            \\}
        , "<ledger-reopen>");
        var request = try makeTestRequest(allocator, "GET", "/", null);
        defer request.deinit(allocator);
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("9223372036854775807", parsed.value.object.get("source").?.string);
    }

    // A changed scale changes the invariant digest and cannot reopen the store.
    var changed_buffer: [64]u8 = undefined;
    const changed_invariant = try ledgerTwoCurrencyInvariantBytes(&changed_buffer, 3);
    try std.testing.expectError(error.LedgerConfigMismatch, HandlerInstance.init(allocator, .{
        .ledger_path = ledger_path,
        .invariant_section = changed_invariant,
        .invariant_coverage_accepted = true,
    }));

    // Tampering with a materialized balance is detected before the next
    // runtime becomes usable.
    var db = try zq.sqlite.Db.openReadWriteCreate(allocator, ledger_path);
    try db.exec(allocator, "UPDATE ledger_balances SET balance = balance - 1 WHERE account = 'source'");
    db.close();
    try std.testing.expectError(error.InvariantViolated, HandlerInstance.init(allocator, config));
}

test "protected ledger busy write is retryable after the competing transaction ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const ledger_path = try std.fmt.allocPrint(allocator, "{s}/ledger.sqlite", .{dir});
    var invariant_buffer: [64]u8 = undefined;
    const invariant_bytes = try ledgerInvariantBytes(&invariant_buffer, 2);
    const config = RuntimeConfig{
        .ledger_path = ledger_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    };
    const rt = try HandlerInstance.init(allocator, config);
    defer rt.deinit();
    try rt.loadHandler(
        \\import { post } from "zttp:ledger";
        \\function handler(req) {
        \\  const result = post({ ledger: "main", currency: "USD", idempotencyKey: "retry", entries: [
        \\    { account: "a", amount: "7" }, { account: "b", amount: "-7" }
        \\  ] });
        \\  return Response.text(result.ok ? "ok" : result.error.tag);
        \\}
    , "<ledger-busy>");

    var competing = try zq.sqlite.Db.openReadWriteCreate(allocator, ledger_path);
    defer competing.close();
    try competing.exec(allocator, "BEGIN IMMEDIATE");

    var request = try makeTestRequest(allocator, "POST", "/", null);
    defer request.deinit(allocator);
    var blocked = try rt.executeHandler(request.asView());
    defer blocked.deinit();
    try std.testing.expectEqualStrings("storage_busy", blocked.body);

    try competing.exec(allocator, "ROLLBACK");
    var retried = try rt.executeHandler(request.asView());
    defer retried.deinit();
    try std.testing.expectEqualStrings("ok", retried.body);

    // Reopening validates that the failed attempt left no partial rows and the
    // retry committed one balanced group.
    const reopened = try HandlerInstance.init(allocator, config);
    reopened.deinit();
}

test "protected ledger refuses schema objects outside the trusted adapter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    var invariant_buffer: [64]u8 = undefined;
    const invariant_bytes = try ledgerInvariantBytes(&invariant_buffer, 2);
    const cases = [_]struct { name: []const u8, ddl: []const u8 }{
        .{ .name = "trigger", .ddl = "CREATE TRIGGER alter_post AFTER INSERT ON ledger_postings BEGIN UPDATE ledger_balances SET balance = balance + 1; END" },
        .{ .name = "view", .ddl = "CREATE VIEW leaked_balances AS SELECT * FROM ledger_balances" },
        .{ .name = "index", .ddl = "CREATE INDEX alternate_balance_path ON ledger_balances(account)" },
    };

    const view_only_path = try std.fmt.allocPrint(allocator, "{s}/view-only.sqlite", .{dir});
    var view_only_db = try zq.sqlite.Db.openReadWriteCreate(allocator, view_only_path);
    try view_only_db.exec(allocator, "CREATE VIEW unexpected AS SELECT 1 AS value");
    view_only_db.close();
    try std.testing.expectError(error.InvalidLedgerSchema, HandlerInstance.init(allocator, .{
        .ledger_path = view_only_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    }));

    for (cases) |case| {
        const ledger_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sqlite", .{ dir, case.name });
        const config = RuntimeConfig{
            .ledger_path = ledger_path,
            .invariant_section = invariant_bytes,
            .invariant_coverage_accepted = true,
        };
        {
            const rt = try HandlerInstance.init(allocator, config);
            rt.deinit();
        }
        var db = try zq.sqlite.Db.openReadWriteCreate(allocator, ledger_path);
        try db.exec(allocator, case.ddl);
        db.close();
        try std.testing.expectError(error.InvalidLedgerSchema, HandlerInstance.init(allocator, config));
    }
}

test "protected ledger rejects a changed posting hash with balanced rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const path = try std.fs.path.join(allocator, &.{ dir, "ledger.sqlite" });
    var buffer: [64]u8 = undefined;
    const spec = try ledgerInvariantBytes(&buffer, 2);
    const config: RuntimeConfig = .{ .ledger_path = path, .invariant_section = spec, .invariant_coverage_accepted = true };
    {
        const rt = try HandlerInstance.init(allocator, config);
        defer rt.deinit();
        try rt.loadHandler(
            \\import { post } from "zttp:ledger";
            \\function handler(req) {
            \\  const result = post({ ledger: "main", currency: "USD", idempotencyKey: "hash", entries: [
            \\    { account: "cash", amount: "1" }, { account: "clearing", amount: "-1" }
            \\  ] });
            \\  return Response.text(result.ok ? "posted" : "failed");
            \\}
        , "<ledger-hash>");
        var request = try makeTestRequest(allocator, "GET", "/", null);
        defer request.deinit(allocator);
        var response = try rt.executeHandler(request.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("posted", response.body);
    }
    var db = try zq.sqlite.Db.openReadWriteCreate(allocator, path);
    // Change exactly one hex digit. Entries and materialized balances stay intact.
    try db.exec(allocator, "UPDATE ledger_postings SET content_hash = (CASE substr(content_hash, 1, 1) WHEN '0' THEN '1' ELSE '0' END) || substr(content_hash, 2)");
    db.close();
    try std.testing.expectError(error.CorruptLedger, HandlerInstance.init(allocator, config));
    try std.testing.expectError(error.CorruptLedger, @import("runtime_pool.zig").HandlerPool.init(
        allocator,
        config,
        "function handler(req) { return Response.text('unused'); }",
        "<unused>",
        1,
        0,
    ));
}

test "a balance-only generation activates on a fresh store and serves a balance read" {
    // The read-only topology the write-applicability report exists for. It has
    // no posting group anywhere, so nothing a write-gating kind constrains ever
    // runs; the store is still opened, its baseline still validated, and the
    // read still served.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const ledger_path = try std.fs.path.join(allocator, &.{ dir, "ledger.sqlite" });
    var invariant_buffer: [64]u8 = undefined;
    const invariant_bytes = try ledgerInvariantBytes(&invariant_buffer, 2);
    const config = RuntimeConfig{
        .ledger_path = ledger_path,
        .invariant_section = invariant_bytes,
        .invariant_coverage_accepted = true,
    };

    const rt = try HandlerInstance.init(allocator, config);
    defer rt.deinit();
    try rt.loadHandler(
        \\import { balance } from "zttp:ledger";
        \\function handler(req) {
        \\  const cash = balance("main", "USD", "cash");
        \\  return Response.json({ ok: cash.ok, cash: cash.value });
        \\}
    , "<balance-only>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("0", parsed.value.object.get("cash").?.string);
}

test "an invariant pool refuses reload and keeps serving its accepted generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try durableTestDirPath(allocator, &tmp);
    const path = try std.fs.path.join(allocator, &.{ dir, "ledger.sqlite" });
    var buffer: [64]u8 = undefined;
    const spec = try ledgerInvariantBytes(&buffer, 2);
    const config: RuntimeConfig = .{
        .ledger_path = path,
        .invariant_section = spec,
        .invariant_coverage_accepted = true,
    };
    var conflicting = config;
    conflicting.trace_file_path = path;
    try std.testing.expectError(error.ProtectedLedgerPath, @import("runtime_pool.zig").HandlerPool.init(
        allocator,
        conflicting,
        "function handler(req) { return Response.text('unused'); }",
        "<unused>",
        0,
        0,
    ));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
    try std.testing.expectError(error.InvariantPoolRequiresCapacity, @import("runtime_pool.zig").HandlerPool.init(
        allocator,
        config,
        "function handler(req) { return Response.text('unused'); }",
        "<unused>",
        0,
        0,
    ));
    var pool = try @import("runtime_pool.zig").HandlerPool.init(allocator, config, "function handler(req) { return Response.text('accepted'); }", "<accepted>", 1, 0);
    defer pool.deinit();
    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var before = try pool.executeHandler(request.asView());
    defer before.deinit();
    try std.testing.expectEqualStrings("accepted", before.body);
    try std.testing.expectError(error.InvariantGenerationSwapRefused, pool.reloadHandler(
        "function handler(req) { return Response.text('unchecked'); }",
        "<unchecked>",
    ));
    var after = try pool.executeHandler(request.asView());
    defer after.deinit();
    try std.testing.expectEqualStrings("accepted", after.body);
}

// ============================================================================
// Credential injection (M4 T6 U3)
// ============================================================================
//
// docs/plans/2026-09-24-m4-t6-credential-injection-design.md, sections 5 to 8.
// Each handler asks the upstream for `/__stop` last, and the upstream records
// every request before that one, so a refusal that still sent a request shows
// up as a recorded request rather than as a hang.

const credential_store = @import("credential_store.zig");

/// The value every credential test loads. No response, trace, or event may
/// hold it (design note, section 7).
const credential_marker = "zttp-u3-marker-5c1e9a";
const credential_env = "ZTTP_U3_TEST_KEY";

fn credentialMarkerEnv(_: ?*const anyopaque, name_z: [:0]const u8) ?[]const u8 {
    if (std.mem.eql(u8, name_z, credential_env)) return credential_marker;
    return null;
}

/// A store with one reference, `weather`: `endpoint`, the `authorization`
/// header with scheme `Bearer`, GET and POST, and the path prefix `/v1`.
/// Loaded from a hand-built reference, so a test can name an endpoint the
/// loader would refuse.
fn credentialTestStore(allocator: std.mem.Allocator, endpoint: []const u8) !credential_store.Store {
    var paths = [_][]const u8{"/v1"};
    var methods = std.EnumSet(credential_store.credential_ref.Method).initEmpty();
    methods.insert(.GET);
    methods.insert(.POST);
    const refs = [_]credential_store.CredentialRef{.{
        .name = "weather",
        .env = credential_env,
        .endpoint = endpoint,
        .header = "authorization",
        .scheme = "Bearer",
        .methods = methods,
        .paths = &paths,
    }};
    return (try credential_store.load(allocator, &refs, .{ .get = credentialMarkerEnv })).ok;
}

/// A tool grant that allows every export and the credentials it names.
const TestCredentialGrant = struct {
    names: []const []const u8,

    fn allowsExport(_: *const anyopaque, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn allowsCredential(context: *const anyopaque, name: []const u8) bool {
        const self: *const TestCredentialGrant = @ptrCast(@alignCast(context));
        for (self.names) |granted| {
            if (std.mem.eql(u8, granted, name)) return true;
        }
        return false;
    }

    fn grant(self: *const TestCredentialGrant) http_types.ToolGrant {
        return .{ .context = @ptrCast(self), .allows = allowsExport, .allows_credential = allowsCredential };
    }
};

/// An upstream that records every request until one asks for `/__stop`.
const CredentialUpstream = struct {
    io_backend: std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    reply: Reply,
    /// The `Location` of a `.redirect` reply.
    location: []const u8 = "",
    thread: ?std.Thread = null,
    /// Owned by `std.testing.allocator`, which is thread-safe; the test's
    /// arena is not, and the handler allocates from it while this runs.
    captured: std.ArrayListUnmanaged(TestCapturedRequest) = .empty,
    thread_error: std.atomic.Value(TestErrorInt) = std.atomic.Value(TestErrorInt).init(0),

    const Reply = enum { ok, echo_body, echo_head, redirect, close_without_answer, large_body };

    fn init(reply: Reply) !CredentialUpstream {
        var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try address.listen(io_backend.io(), .{ .reuse_address = true });
        return .{ .io_backend = io_backend, .listener = listener, .port = listener.socket.address.getPort(), .reply = reply };
    }

    fn start(self: *CredentialUpstream) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn url(self: *const CredentialUpstream, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    /// Join after the handler asked for `/__stop`, then release everything.
    fn deinit(self: *CredentialUpstream) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.listener.deinit(self.io_backend.io());
        self.io_backend.deinit();
        for (self.captured.items) |*captured| captured.deinit(std.testing.allocator);
        self.captured.deinit(std.testing.allocator);
    }

    /// The requests the runtime sent before `/__stop`. Joins first.
    fn requests(self: *CredentialUpstream) ![]const TestCapturedRequest {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const err_int = self.thread_error.swap(0, .acq_rel);
        if (err_int != 0) return @errorFromInt(err_int);
        return self.captured.items;
    }

    fn run(self: *CredentialUpstream) void {
        self.runInner() catch |err| self.thread_error.store(@intFromError(err), .release);
    }

    fn runInner(self: *CredentialUpstream) !void {
        const io = self.io_backend.io();
        const allocator = std.testing.allocator;
        while (true) {
            var stream = self.listener.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            defer stream.close(io);
            var captured = try captureRequest(allocator, &stream, io);
            if (std.mem.eql(u8, captured.path, "/__stop")) {
                captured.deinit(allocator);
                try writeTestResponse(&stream, io, 200, "OK", &.{}, "stopped");
                return;
            }
            self.captured.append(allocator, captured) catch |err| {
                captured.deinit(allocator);
                return err;
            };
            const authorization = captured.getHeader("authorization") orelse "";
            switch (self.reply) {
                .ok => try writeTestResponse(&stream, io, 200, "OK", &.{"Content-Type: text/plain"}, "forecast"),
                .echo_body => try writeTestResponse(&stream, io, 200, "OK", &.{"Content-Type: text/plain"}, authorization),
                .echo_head => {
                    var line_buf: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&line_buf, "x-echo: {s}", .{authorization});
                    try writeTestResponse(&stream, io, 200, "OK", &.{line}, "ok");
                },
                .redirect => {
                    var line_buf: [256]u8 = undefined;
                    const line = try std.fmt.bufPrint(&line_buf, "Location: {s}", .{self.location});
                    try writeTestResponse(&stream, io, 302, "Found", &.{line}, "");
                },
                .close_without_answer => {},
                .large_body => try writeTestResponse(&stream, io, 200, "OK", &.{"Content-Type: text/plain"}, "0123456789abcdef0123456789abcdef"),
            }
        }
    }
};

/// Run `handler_code` once under `grant`, with egress allowed to `endpoints`
/// and to loopback, and return the response body. Every body is searched for
/// the marker here, so no test can forget to.
fn runCredentialHandler(
    allocator: std.mem.Allocator,
    config: RuntimeConfig,
    endpoints: []const []const u8,
    grant: ?http_types.ToolGrant,
    handler_code: []const u8,
) ![]u8 {
    var run_config = config;
    run_config.outbound_http_enabled = true;
    const rt = try HandlerInstance.init(allocator, run_config);
    defer rt.deinit();
    rt.ctx.capability_policy = .{
        .egress = .{ .enabled = true, .values = endpoints },
        .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback),
    };
    try rt.loadHandler(handler_code, "<credential>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var view = request.asView();
    view.tool_grant = grant;
    var response = try rt.executeHandler(view);
    defer response.deinit();
    try std.testing.expect(std.mem.indexOf(u8, response.body, credential_marker) == null);
    return allocator.dupe(u8, response.body);
}

fn expectFetchError(body: []const u8, code: []const u8, details: []const u8) !void {
    return expectRefusalBody(body, 599, code, details);
}

/// `httpRequest` answers with its own JSON, which carries no status.
fn expectRefusalBody(body: []const u8, expected_status: ?i64, code: []const u8, details: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (expected_status) |expected| {
        const status = obj.get("status") orelse return error.TestExpectedFetchError;
        try std.testing.expectEqual(expected, status.integer);
    } else try std.testing.expect(obj.get("status") == null);
    const err = obj.get("error") orelse return error.TestExpectedFetchError;
    const detail = obj.get("details") orelse return error.TestExpectedFetchError;
    try std.testing.expectEqualStrings(code, err.string);
    try std.testing.expectEqualStrings(details, detail.string);
}

test "an authorized tool request reaches the upstream with the credential in its header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var upstream = try CredentialUpstream.init(.ok);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoint = egressEndpoint(base, &endpoint_buf);
    var store = try credentialTestStore(std.testing.allocator, endpoint);
    defer store.deinit();
    const grant = TestCredentialGrant{ .names = &.{"weather"} };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const got = fetch("{s}/v1/forecast", {{ credential: "weather", query: {{ lat: 1, lon: 2 }} }});
        \\  const posted = fetch("{s}/v1", {{ credential: "weather", method: "POST", body: "x" }});
        \\  fetch("{s}/__stop");
        \\  return Response.json({{ got: got.status, body: got.body, posted: posted.status }});
        \\}}
    , .{ base, base, base });
    const body = try runCredentialHandler(allocator, .{ .credential_store = &store }, &.{endpoint}, grant.grant(), handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("got").?.integer);
    try std.testing.expectEqualStrings("forecast", parsed.value.object.get("body").?.string);
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("posted").?.integer);

    const requests = try upstream.requests();
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    const expected_header = "Bearer " ++ credential_marker;
    try std.testing.expectEqualStrings("GET", requests[0].method);
    try std.testing.expectEqualStrings("/v1/forecast?lat=1&lon=2", requests[0].path);
    try std.testing.expectEqualStrings(expected_header, requests[0].getHeader("authorization").?);
    try std.testing.expectEqualStrings("POST", requests[1].method);
    try std.testing.expectEqualStrings(expected_header, requests[1].getHeader("authorization").?);
}

test "every credential refusal sends nothing, names its reason, and every reason is observed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const durable_dir = try durableTestDirPath(allocator, &tmp_dir);

    const Case = struct {
        label: []const u8,
        /// The fetch under test. `@BASE@` is the upstream's base URL, `@OTHER@`
        /// the other upstream's.
        call: []const u8,
        grant: []const []const u8 = &.{"weather"},
        no_grant: bool = false,
        no_store: bool = false,
        /// The store's endpoint names `localhost` instead of the address.
        plain_store: bool = false,
        durable: bool = false,
        /// The sender answers with `httpRequest`'s JSON, which has no status.
        no_status: bool = false,
        reason: credential_store.Refusal,
    };
    const cases = [_]Case{
        .{ .label = "no tool request", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\" })", .no_grant = true, .reason = .not_granted },
        .{ .label = "another tool's credential", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\" })", .grant = &.{"billing"}, .reason = .not_granted },
        .{ .label = "no store", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\" })", .no_store = true, .reason = .not_configured },
        .{ .label = "granted, never configured", .call = "fetch(\"@BASE@/v1\", { credential: \"billing\" })", .grant = &.{ "billing", "weather" }, .reason = .not_configured },
        .{ .label = "another endpoint", .call = "fetch(\"@OTHER@/v1\", { credential: \"weather\" })", .reason = .endpoint_mismatch },
        .{ .label = "a method outside the reference", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\", method: \"PUT\", body: \"x\" })", .reason = .method_not_allowed },
        .{ .label = "a path outside the prefixes", .call = "fetch(\"@BASE@/v2/admin\", { credential: \"weather\" })", .reason = .path_not_allowed },
        .{ .label = "a prefix that is not a segment", .call = "fetch(\"@BASE@/v1x\", { credential: \"weather\" })", .reason = .path_not_allowed },
        .{ .label = "a dot segment", .call = "fetch(\"@BASE@/v1/%2e%2e/admin\", { credential: \"weather\" })", .reason = .path_not_allowed },
        .{ .label = "the handler's own header", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\", headers: { Authorization: \"Bearer mine\" } })", .reason = .header_collision },
        .{ .label = "plain http to a name", .call = "fetch(\"@NAMED@/v1\", { credential: \"weather\" })", .plain_store = true, .reason = .plaintext },
        .{ .label = "fetchWithRetry", .call = "fetchWithRetry(\"@BASE@/v1\", { credential: \"weather\" }, { maxRetries: 3 })", .reason = .path_unsupported },
        .{ .label = "durable fetch", .call = "fetch(\"@BASE@/v1\", { credential: \"weather\", durable: { key: \"k\", retries: 3 } })", .durable = true, .reason = .path_unsupported },
        .{ .label = "parallel", .call = "parallelFetch(\"@BASE@/v1\")", .reason = .path_unsupported },
        .{ .label = "httpRequest", .call = "JSON.parse(httpRequest(JSON.stringify({ url: \"@BASE@/v1\", credential: \"weather\" })))", .no_status = true, .reason = .path_unsupported },
    };

    var observed = std.EnumSet(credential_store.Refusal).initEmpty();
    var failures: usize = 0;
    for (cases) |case| {
        var upstream = try CredentialUpstream.init(.ok);
        defer upstream.deinit();
        try upstream.start();
        var other = try CredentialUpstream.init(.ok);
        defer other.deinit();
        try other.start();

        const base = try upstream.url(allocator, "");
        const other_base = try other.url(allocator, "");
        const named_base = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{upstream.port});
        var endpoint_buf: [512]u8 = undefined;
        var other_buf: [512]u8 = undefined;
        var named_buf: [512]u8 = undefined;
        const endpoints = [_][]const u8{
            egressEndpoint(base, &endpoint_buf),
            egressEndpoint(other_base, &other_buf),
            egressEndpoint(named_base, &named_buf),
        };

        var store = try credentialTestStore(std.testing.allocator, if (case.plain_store) endpoints[2] else endpoints[0]);
        defer store.deinit();
        const grant = TestCredentialGrant{ .names = case.grant };

        const template =
            \\import { fetch, fetchWithRetry } from "zttp:fetch";
            \\import { parallel } from "zttp:io";
            \\function parallelFetch(url) {
            \\  const box = [];
            \\  function one() { box.push(fetchSync(url, { credential: "weather" })); }
            \\  parallel([one]);
            \\  return box[0];
            \\}
            \\function handler(req) {
            \\  const res = @CALL@;
            \\  fetch("@BASE@/__stop");
            \\  fetch("@OTHER@/__stop");
            \\  return Response.json({ status: res.status, error: res.error, details: res.details });
            \\}
        ;
        const with_call = try std.mem.replaceOwned(u8, allocator, template, "@CALL@", case.call);
        const with_base = try std.mem.replaceOwned(u8, allocator, with_call, "@BASE@", base);
        const with_other = try std.mem.replaceOwned(u8, allocator, with_base, "@OTHER@", other_base);
        const handler_code = try std.mem.replaceOwned(u8, allocator, with_other, "@NAMED@", named_base);

        var config: RuntimeConfig = .{ .credential_store = if (case.no_store) null else &store };
        if (case.durable) config.durable_oplog_dir = durable_dir;
        const body = try runCredentialHandler(
            allocator,
            config,
            &endpoints,
            if (case.no_grant) null else grant.grant(),
            handler_code,
        );

        // Every case runs, so a broken check reports each case it lets through
        // instead of the first one.
        var refused = true;
        expectRefusalBody(body, if (case.no_status) null else 599, "CredentialRefused", @tagName(case.reason)) catch {
            std.debug.print("case '{s}' was not refused as {s}: {s}\n", .{ case.label, @tagName(case.reason), body });
            refused = false;
        };
        const sent = (try upstream.requests()).len + (try other.requests()).len;
        if (sent != 0) std.debug.print("case '{s}' sent {d} request(s)\n", .{ case.label, sent });
        if (refused and sent == 0) observed.insert(case.reason) else failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(observed.eql(std.EnumSet(credential_store.Refusal).initFull()));
}

test "a credentialed redirect returns to the tool and the second listener receives nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var target = try CredentialUpstream.init(.ok);
    defer target.deinit();
    try target.start();
    var upstream = try CredentialUpstream.init(.redirect);
    defer upstream.deinit();
    const target_base = try target.url(allocator, "");
    upstream.location = try std.fmt.allocPrint(allocator, "{s}/v1/stolen", .{target_base});
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    var target_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{ egressEndpoint(base, &endpoint_buf), egressEndpoint(target_base, &target_buf) };
    var store = try credentialTestStore(std.testing.allocator, endpoints[0]);
    defer store.deinit();
    const grant = TestCredentialGrant{ .names = &.{"weather"} };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\function handler(req) {{
        \\  const res = fetchSync("{s}/v1", {{ credential: "weather" }});
        \\  fetchSync("{s}/__stop");
        \\  fetchSync("{s}/__stop");
        \\  return Response.json({{ status: res.status, location: res.headers.get("location") }});
        \\}}
    , .{ base, base, target_base });
    const body = try runCredentialHandler(allocator, .{ .credential_store = &store }, &endpoints, grant.grant(), handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 302), parsed.value.object.get("status").?.integer);
    try std.testing.expectEqualStrings(upstream.location, parsed.value.object.get("location").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try upstream.requests()).len);
    try std.testing.expectEqual(@as(usize, 0), (try target.requests()).len);
}

test "a credentialed request with no answer is OutcomeUnknown and is sent once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var upstream = try CredentialUpstream.init(.close_without_answer);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};
    var store = try credentialTestStore(std.testing.allocator, endpoints[0]);
    defer store.deinit();
    const grant = TestCredentialGrant{ .names = &.{"weather"} };

    // The second call names no credential: its code does not change.
    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const res = fetch("{s}/v1", {{ credential: "weather", method: "POST", body: "charge" }});
        \\  const plain = fetch("{s}/v1", {{ method: "POST", body: "charge" }});
        \\  fetch("{s}/__stop");
        \\  return Response.json({{ status: res.status, error: res.error, plain: plain.error }});
        \\}}
    , .{ base, base, base });
    const body = try runCredentialHandler(allocator, .{ .credential_store = &store }, &endpoints, grant.grant(), handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 599), parsed.value.object.get("status").?.integer);
    try std.testing.expectEqualStrings("OutcomeUnknown", parsed.value.object.get("error").?.string);
    try std.testing.expectEqualStrings("ResponseHeadFailed", parsed.value.object.get("plain").?.string);
    const requests = try upstream.requests();
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expect(requests[0].getHeader("authorization") != null);
    try std.testing.expect(requests[1].getHeader("authorization") == null);
}

test "an upstream that echoes the credential is refused before the tool reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Case = struct { reply: CredentialUpstream.Reply, where: []const u8 };
    for ([_]Case{ .{ .reply = .echo_body, .where = "response_body" }, .{ .reply = .echo_head, .where = "response_head" } }) |case| {
        var upstream = try CredentialUpstream.init(case.reply);
        defer upstream.deinit();
        try upstream.start();

        const base = try upstream.url(allocator, "");
        var endpoint_buf: [512]u8 = undefined;
        const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};
        var store = try credentialTestStore(std.testing.allocator, endpoints[0]);
        defer store.deinit();
        const grant = TestCredentialGrant{ .names = &.{"weather"} };

        const handler_code = try std.fmt.allocPrint(allocator,
            \\function handler(req) {{
            \\  const res = fetchSync("{s}/v1", {{ credential: "weather" }});
            \\  fetchSync("{s}/__stop");
            \\  return Response.json({{ status: res.status, error: res.error, details: res.details, body: res.body }});
            \\}}
        , .{ base, base });
        const body = try runCredentialHandler(allocator, .{ .credential_store = &store }, &endpoints, grant.grant(), handler_code);
        try expectFetchError(body, "CredentialReflected", case.where);
        try std.testing.expectEqual(@as(usize, 1), (try upstream.requests()).len);
    }
}

test "a credentialed response over the size bound is refused (B8.3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var upstream = try CredentialUpstream.init(.large_body);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};
    var store = try credentialTestStore(std.testing.allocator, endpoints[0]);
    defer store.deinit();
    const grant = TestCredentialGrant{ .names = &.{"weather"} };

    const handler_code = try std.fmt.allocPrint(allocator,
        \\function handler(req) {{
        \\  const res = fetchSync("{s}/v1", {{ credential: "weather" }});
        \\  fetchSync("{s}/__stop");
        \\  return Response.json({{ status: res.status, error: res.error, details: res.details }});
        \\}}
    , .{ base, base });
    const body = try runCredentialHandler(allocator, .{ .credential_store = &store, .outbound_max_response_bytes = 16 }, &endpoints, grant.grant(), handler_code);
    try expectFetchError(body, "ResponseTooLarge", "response exceeded max_response_bytes");
    try std.testing.expectEqual(@as(usize, 1), (try upstream.requests()).len);
}

test "the credential value reaches neither the trace nor the security event stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try zq.security_events.initGlobal(std.testing.allocator, 64);
    defer zq.security_events.deinitGlobal();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const trace_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/credential.trace", .{tmp_dir.sub_path});

    var upstream = try CredentialUpstream.init(.ok);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};
    var store = try credentialTestStore(std.testing.allocator, endpoints[0]);
    defer store.deinit();
    const grant = TestCredentialGrant{ .names = &.{"weather"} };

    // One granted call, one refused call, and one denied by egress, so the
    // trace holds a success and a refusal and the stream holds a denial.
    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const ok = fetch("{s}/v1", {{ credential: "weather" }});
        \\  const refused = fetch("{s}/v2", {{ credential: "weather" }});
        \\  const denied = fetch("http://denied.example/v1", {{ credential: "weather" }});
        \\  fetch("{s}/__stop");
        \\  return Response.json({{ ok: ok.status, refused: refused.details, denied: denied.error }});
        \\}}
    , .{ base, base, base });
    const body = try runCredentialHandler(allocator, .{ .credential_store = &store, .trace_file_path = trace_path }, &endpoints, grant.grant(), handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("ok").?.integer);
    try std.testing.expectEqualStrings("path_not_allowed", parsed.value.object.get("refused").?.string);
    try std.testing.expectEqualStrings("HostNotAllowed", parsed.value.object.get("denied").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try upstream.requests()).len);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, allocator, .limited(1 << 20));
    // Floor: the trace recorded the calls, so the search below covers them.
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"weather\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "forecast") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, credential_marker) == null);

    const stream = zq.security_events.getGlobal() orelse return error.TestUnexpectedResult;
    var drained: [64]zq.security_events.SecurityEvent = undefined;
    const count = stream.drain(&drained);
    // Floor: the egress denial emitted at least one event.
    try std.testing.expect(count >= 1);
    for (drained[0..count]) |event| {
        for ([_][]const u8{ event.moduleSlice(), event.detailSlice(), event.actionSlice(), event.resourceKindSlice(), event.resourceIdSlice() }) |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, credential_marker) == null);
        }
    }
}

// `fetchWithRetry` reads its callbacks through the SDK's `getModuleState`,
// which unwraps an envelope. The state was once installed as a bare pointer,
// so the module read the wrong struct and called a heap address as a
// function the first time it reached a callback no other export used.
test "fetchWithRetry without a credential reaches the upstream once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var upstream = try CredentialUpstream.init(.ok);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ fetch, fetchWithRetry }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const res = fetchWithRetry("{s}/v1", {{}}, {{ maxRetries: 2 }});
        \\  fetch("{s}/__stop");
        \\  return Response.json({{ status: res.status, body: res.body }});
        \\}}
    , .{ base, base });
    const body = try runCredentialHandler(allocator, .{}, &endpoints, null, handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("status").?.integer);
    try std.testing.expectEqualStrings("forecast", parsed.value.object.get("body").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try upstream.requests()).len);
}

// std's `sendBodiless` asserts that the method carries no body, so a POST,
// PUT, or PATCH the handler sent without one once panicked the worker. Each
// sender now sends an empty body instead.
test "a POST with no body is sent with an empty body on every sender" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var upstream = try CredentialUpstream.init(.ok);
    defer upstream.deinit();
    try upstream.start();

    const base = try upstream.url(allocator, "");
    var endpoint_buf: [512]u8 = undefined;
    const endpoints = [_][]const u8{egressEndpoint(base, &endpoint_buf)};

    const handler_code = try std.fmt.allocPrint(allocator,
        \\import {{ parallel }} from "zttp:io";
        \\function viaParallel() {{ return fetchSync("{s}/parallel", {{ method: "PATCH" }}); }}
        \\function handler(req) {{
        \\  const sync = fetchSync("{s}/sync", {{ method: "POST" }});
        \\  const bridged = JSON.parse(httpRequest(JSON.stringify({{ url: "{s}/bridge", method: "PUT" }})));
        \\  const par = parallel([viaParallel]);
        \\  fetchSync("{s}/__stop");
        \\  return Response.json({{ sync: sync.status, bridged: bridged.status, par: par[0].status }});
        \\}}
    , .{ base, base, base, base });
    const body = try runCredentialHandler(allocator, .{}, &endpoints, null, handler_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("sync").?.integer);
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("bridged").?.integer);
    try std.testing.expectEqual(@as(i64, 200), parsed.value.object.get("par").?.integer);
    const requests = try upstream.requests();
    try std.testing.expectEqual(@as(usize, 3), requests.len);
    for (requests) |request| {
        try std.testing.expectEqualStrings("0", request.getHeader("content-length").?);
    }
}
