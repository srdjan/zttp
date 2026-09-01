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

    // The pooled Context outlives each wrapper, so the slot must follow the
    // current wrapper and must be empty in between.
    const first = try HandlerInstance.initFromPool(base_rt, .{});
    try std.testing.expectEqual(@as(?*HandlerInstance, first), HandlerInstance.fromContext(base_rt.ctx));
    first.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), base_rt.ctx.host);

    const second = try HandlerInstance.initFromPool(base_rt, .{});
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
            .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{\"content-type\":\"application/json\",\"x-request-id\":\"trace-123\"},\"body\":\"{\\\"temperature\\\":21}\"}",
        },
        .{
            .seq = 1,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[\"http://example.com/weather\"]",
            .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{\"content-type\":\"application/json\",\"x-request-id\":\"trace-123\"},\"body\":\"{\\\"temperature\\\":21}\"}",
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
