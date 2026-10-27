//! Test root for the runtime package's handler instance.
//!
//! The instance itself is `handler_instance.HandlerInstance`. This file holds
//! the end-to-end tests that drive fetch and JSX. The file also
//! contains the loopback HTTP server that these tests use.

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
const fault_explain = @import("fault_explain.zig");
const incident_log = @import("incident_log.zig");
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
const parseFetchArgs = http.parseFetchArgs;

// Bytecode caching for faster cold starts
const bytecode_cache = zq.bytecode_cache;

// HTTP protocol types (shared with server layer)
const http_types = @import("http_types.zig");
const HttpRequestView = http_types.HttpRequestView;
const HttpRequestOwned = http_types.HttpRequestOwned;

const runtime_config_mod = @import("runtime_config.zig");
const contract_runtime = @import("contract_runtime.zig");
const cost_meter = zq.CostMeter;

const RuntimeConfig = runtime_config_mod.RuntimeConfig;
const RuntimePolicyGeneration = @import("runtime_policy_generation.zig").RuntimePolicyGeneration;

const applyEmbeddedCapabilityPolicy = runtime_config_mod.applyEmbeddedCapabilityPolicy;

// ============================================================================
// File reading for module graph (POSIX, no async I/O dependency)
// ============================================================================

const handler_instance = @import("handler_instance.zig");
const HandlerInstance = handler_instance.HandlerInstance;
const OutboundIo = @import("outbound_io.zig").OutboundIo;
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
    // Requests answered in .sequenced_status mode.
    served: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Set by `finish` so a server that is still waiting to accept stops.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    raw_response: []const u8 = "",

    const Mode = enum {
        echo_request_json,
        large_plain_text,
        silent_hold,
        sequenced_status,
        raw_response,
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
        return allocator.print("http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    /// Stops a .sequenced_status server that may still wait to accept, then
    /// joins it. A wake-up connection unblocks the pending accept.
    fn finish(self: *TestHttpServer) !void {
        self.stopping.store(true, .release);
        if (!self.closed) {
            const io = self.io_backend.io();
            const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
            if (address.connect(io, .{ .mode = .stream })) |wake| {
                var stream = wake;
                stream.close(io);
            } else |_| {}
        }
        try self.join();
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
                if (self.stopping.load(.acquire)) return;
                try self.respondWithStatus(&stream, io, status);
                _ = self.served.fetchAdd(1, .acq_rel);
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
            .raw_response => {
                var captured = try captureRequest(self.allocator, &stream, io);
                defer captured.deinit(self.allocator);
                var buffer: [4096]u8 = undefined;
                var writer = stream.writer(io, &buffer);
                try writer.interface.writeAll(self.raw_response);
                try writer.interface.flush();
            },
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
            const result = stream.readWithControl(io, &vecs, &.{}) catch break;
            const n = result.data_len;
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
        const result = stream.readWithControl(io, &vecs, &.{}) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        const n = result.data_len;
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
            chunked = ascii.findIgnoreCase(value, "chunked") != null;
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

test {
    _ = @import("handler_loader.zig");
    _ = @import("replay_runner.zig");
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

test "standalone initialization unwinds builtin and trace allocation failures" {
    const ProbeAllocator = struct {
        backing: std.mem.Allocator,
        fd: ?std.c.fd_t = null,
        remaining: usize,
        failed: bool = false,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Context.init creates the global object before initBuiltins
            // creates prototypes/native functions. Alternatively, target the
            // first allocations after openTraceFile has published its fd.
            const selected = if (self.fd) |fd|
                std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0)) != -1
            else
                len == @sizeOf(zq.JSObject);
            if (selected) {
                if (self.remaining == 0) {
                    self.failed = true;
                    return null;
                }
                self.remaining -= 1;
            }
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }
        fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }
        fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }
        fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };
    // Skip the Context's global object, then fail the first and second builtin
    // objects. This exercises pre-handoff cleanup without an exhaustive
    // constructor sweep on every test-root invocation.
    for ([_]usize{ 1, 2 }) |objects_before_failure| {
        var probe: ProbeAllocator = .{ .backing = std.testing.allocator, .remaining = objects_before_failure };
        try std.testing.expectError(error.OutOfMemory, HandlerInstance.init(probe.allocator(), .{}));
        try std.testing.expect(probe.failed);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.testing.allocator.print(".zig-cache/tmp/{s}/trace.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    for (0..2) |after_open| {
        const fd = try runtime_config_mod.openTraceFile(std.testing.allocator, path);
        std.Io.Threaded.closeFd(fd);
        var probe: ProbeAllocator = .{ .backing = std.testing.allocator, .fd = fd, .remaining = after_open };
        try std.testing.expectError(error.OutOfMemory, HandlerInstance.init(probe.allocator(), .{
            .trace_file_path = path,
            .outbound_http_enabled = true,
        }));
        try std.testing.expect(probe.failed);
        try std.testing.expectEqual(@as(c_int, -1), std.posix.system.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0)));
    }
}

test "failed pooled initialization clears its host and releases wrapper state" {
    const Probe = struct {
        fn run(fail_from_end: ?usize) !usize {
            var pool = try zq.LockFreePool.init(std.testing.allocator, .{ .max_size = 1 });
            defer pool.deinit();
            const base = try pool.acquire();
            defer pool.release(base);
            const original_allocator = base.ctx.allocator;
            var failing = std.testing.FailingAllocator.init(original_allocator, .{});
            base.ctx.allocator = failing.allocator();
            defer base.ctx.allocator = original_allocator;
            const generation = try RuntimePolicyGeneration.create(std.testing.allocator, 1, .{}, false);
            defer generation.release();
            const before = failing.alloc_index;
            if (fail_from_end) |offset| failing.fail_index = before + offset;
            if (HandlerInstance.initFromPool(base, .{ .outbound_http_enabled = true }, generation)) |rt| {
                defer rt.deinit();
                try std.testing.expect(fail_from_end == null);
                return failing.alloc_index - before;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(@as(?*anyopaque, null), base.ctx.host);
                try std.testing.expectEqual(@as(usize, 1), generation.refs.load(.monotonic));
                return failing.alloc_index - before;
            }
        }
    };
    const allocations = try Probe.run(null);
    try std.testing.expect(allocations >= 8);
    // The last binding allocations happen after host publication. Deriving
    // their positions from a successful construction avoids brittle indices.
    for (allocations - 8..allocations) |offset| _ = try Probe.run(offset);
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

/// Runs the handler source against a fresh runtime. The tests below use it
/// with callbacks that fail, and expect the handler call to fail with them.
fn runFailingCallbackHandler(handler_code: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadHandler(handler_code, "<callback-fault>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    response.deinit();
}

test "an error inside a map callback fails the call" {
    // `boom` calls an undefined member, so the callback fails. The call must
    // fail too, not hand the handler an array of undefined.
    try std.testing.expectError(error.HandlerError, runFailingCallbackHandler(
        "function boom(n) { const o = { a: n }; const f = o.missing; return f(); }" ++
            "function handler(req) { const r = [1, 2].map((x) => boom(0)); return Response.json(r); }",
    ));
}

test "a request timeout inside a map callback remains RequestTimeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    const timeout = struct {
        fn call(_: *anyopaque, _: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
            return error.RequestTimeout;
        }
    };
    const timeout_atom = try rt.ctx.atoms.intern("requestTimeout");
    try rt.ctx.registerGlobalFunction(timeout_atom, timeout.call, 0);
    try rt.loadHandler(
        "function handler(req) { const r = [1].map((x) => requestTimeout()); return Response.json(r); }",
        "<callback-timeout>",
    );

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    try std.testing.expectError(error.RequestTimeout, rt.executeHandler(request.asView()));
}

test "an error inside a filter callback fails the call" {
    try std.testing.expectError(error.HandlerError, runFailingCallbackHandler(
        "function boom(n) { const o = { a: n }; const f = o.missing; return f(); }" ++
            "function handler(req) { const r = [1, 2].filter((x) => boom(0)); return Response.json(r); }",
    ));
}

test "an error inside a reduce callback fails the call" {
    try std.testing.expectError(error.HandlerError, runFailingCallbackHandler(
        "function boom(n) { const o = { a: n }; const f = o.missing; return f(); }" ++
            "function handler(req) { const r = [1, 2].reduce((a, x) => boom(0), 0); return Response.json(r); }",
    ));
}

test "an error inside a component fails the render" {
    try std.testing.expectError(error.HandlerError, runFailingCallbackHandler(
        "function boom(n) { const o = { a: n }; const f = o.missing; return f(); }" ++
            "function Comp(props) { return boom(0); }" ++
            "function handler(req) { return Response.html(renderToString(h(Comp, {}))); }",
    ));
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
    const log_path = try allocator.print(".zig-cache/tmp/{s}/incidents.jsonl", .{tmp.sub_path});

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
    const log_path = try allocator.print(".zig-cache/tmp/{s}/cost-incidents.jsonl", .{tmp.sub_path});

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
    const log_path = try allocator.print(".zig-cache/tmp/{s}/cost-clean.jsonl", .{tmp.sub_path});

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
    const log_path = try allocator.print(".zig-cache/tmp/{s}/cost-reset.jsonl", .{tmp.sub_path});

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

test "HTTP body consumption resets for request reuse and pool release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rt = try HandlerInstance.init(allocator, .{ .use_hybrid_allocation = false });
    defer rt.deinit();
    try rt.loadHandler("function handler(req) { return req.text(); }", "<body-reset>");
    const request = try rt.createRequestObject(.{ .method = "POST", .url = "/", .headers = .empty, .body = "ping" });
    // Keep the same object alive across resets so allocating a fresh object
    // cannot conceal stale body-consumption tracking.
    try rt.ctx.setGlobal(try rt.ctx.atoms.intern("held"), request);

    const resetters = [_]*const fn (*HandlerInstance) void{
        HandlerInstance.resetForNextRequest,
        HandlerInstance.prepareForPoolRelease,
    };
    for (resetters) |reset| {
        const first = try rt.callGlobalFunction("handler", &.{request});
        try std.testing.expectEqualStrings("ping", first.toPtr(zq.JSString).data());
        reset(rt);
        const reused = try rt.callGlobalFunction("handler", &.{request});
        try std.testing.expectEqualStrings("ping", reused.toPtr(zq.JSString).data());
        reset(rt);
    }
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

    const handler_code = try allocator.print(
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

    const handler_code = try allocator.print(
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

    const handler_code = try allocator.print(
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

    const cache_slot = @backingInt(zq.module_slots.Slot.cache);
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
        const code = try allocator.print(
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

test "jwtSign, jwtVerify, and verifyWebhookSignature refuse an empty secret" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // The signature in `forged` and in `webhookEmptyKey` is the HMAC-SHA256
    // under an empty key, computed offline with openssl. An empty key makes
    // every signature forgeable, so each export must refuse it.
    const handler_code =
        \\import { jwtSign, jwtVerify, verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  const signed = jwtSign("{\"sub\":\"u\"}", "");
        \\  const forged = jwtVerify("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1In0.0BKgpXNgRqIrxGLFAtUHTOgMMdipTvNKsHd5bkn-JOc", "");
        \\  const hook = verifyWebhookSignature("hello", "", "4352b26e33fe0d769a8922a6ba29004109f01688e26acc9e6cb347e5a5afc4da");
        \\  return Response.json({ signed: typeof signed, verifyOk: forged.ok, hook: hook });
        \\}
    ;
    try rt.loadHandler(handler_code, "<empty-secret>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"signed\":\"undefined\",\"verifyOk\":false,\"hook\":false}", response.body);
}

test "jwtSign, jwtVerify, and verifyWebhookSignature accept a non-empty secret" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // Signatures under the key "k" were computed offline with openssl.
    const handler_code =
        \\import { jwtSign, jwtVerify, verifyWebhookSignature } from "zttp:auth";
        \\function handler(req) {
        \\  const signed = jwtSign("{\"sub\":\"u\"}", "k");
        \\  const verified = jwtVerify("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1In0.TI4AolyVR9MO-UaZ2NrpNzy6a0x8_ezFO_lLVawUY7Q", "k");
        \\  const hook = verifyWebhookSignature("hello", "k", "406e4b43f87095aa86ca6299d25e875921fefa180f02043bb29bec5681c0c2d0");
        \\  return Response.json({ signed: signed, verifyOk: verified.ok, hook: hook });
        \\}
    ;
    try rt.loadHandler(handler_code, "<non-empty-secret>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"signed\":\"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1In0.TI4AolyVR9MO-UaZ2NrpNzy6a0x8_ezFO_lLVawUY7Q\",\"verifyOk\":true,\"hook\":true}", response.body);
}

test "rateCheck answers bad arguments with an error Result, not undefined" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    // A limit below 1 and a window below 1 second are refused. The census
    // forks a Result on `.ok`, so a plain `undefined` here was a failure no
    // path represented (R4 F6).
    const handler_code =
        \\import { rateCheck } from "zttp:ratelimit";
        \\function handler(req) {
        \\  const limit = rateCheck("k", 0, 60);
        \\  const window = rateCheck("k", 5, 0);
        \\  return Response.json({ limitOk: limit.ok, limitTag: limit.error.tag, windowOk: window.ok, windowTag: window.error.tag });
        \\}
    ;
    try rt.loadHandler(handler_code, "<ratecheck-invalid>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"limitOk\":false,\"limitTag\":\"invalid_arguments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"windowOk\":false,\"windowTag\":\"invalid_arguments\"") != null);
}

test "a denied sql write never reaches the database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try allocator.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db_path = try allocator.print("{s}/probe.db", .{dir});

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

    const handler_code = try allocator.print(
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
    , .{url});
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

const retired_ledger_handler =
    \\import { balance } from "zttp:ledger";
    \\function handler(req) {
    \\  return Response.json(balance("main", "USD", "asset:cash"));
    \\}
;

const retired_tool_handler =
    \\import { callTool, toolInput } from "zttp:tool";
    \\function handler(req) {
    \\  return Response.json([toolInput("Input", req), callTool("call-1", "lookup", "{}")]);
    \\}
;

test "replay cannot replace retired ledger absence with recorded success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{ .replay_file_path = "test" });
    defer rt.deinit();
    const io_calls = [_]zq.trace.IoEntry{.{
        .seq = 0,
        .module = "ledger",
        .func = "balance",
        .args_json = "[\"main\",\"USD\",\"asset:cash\"]",
        .result_json = "{\"ok\":true,\"value\":\"999\"}",
    }};
    var replay_state = zq.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
    rt.ctx.setModuleState(zq.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zq.trace.ReplayState.deinitOpaque);
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    try std.testing.expectError(
        error.UnknownModule,
        rt.loadHandler(retired_ledger_handler, "<retired-ledger>"),
    );
    try std.testing.expectEqual(@as(u32, 0), replay_state.cursor);
}

test "replay cannot replace retired tool refusals with recorded success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{ .replay_file_path = "test" });
    defer rt.deinit();
    const io_calls = [_]zq.trace.IoEntry{
        .{ .seq = 0, .module = "tool", .func = "toolInput", .args_json = "[]", .result_json = "{\"ok\":true,\"value\":{}}" },
        .{ .seq = 1, .module = "tool", .func = "callTool", .args_json = "[]", .result_json = "{\"ok\":true,\"value\":\"recorded\"}" },
    };
    var replay_state = zq.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
    rt.ctx.setModuleState(zq.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zq.trace.ReplayState.deinitOpaque);
    defer rt.ctx.module_state[zq.trace.REPLAY_STATE_SLOT] = null;

    try std.testing.expectError(
        error.UnknownModule,
        rt.loadHandler(retired_tool_handler, "<retired-tool>"),
    );
    try std.testing.expectEqual(@as(u32, 0), replay_state.cursor);
}

test "a handler exercising every stateful module fills only owned slots" {
    const allocator = std.testing.allocator;
    const Slot = zq.module_slots.Slot;
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadHandler(
        \\import { cacheSet } from "zttp:cache";
        \\import { rateCheck } from "zttp:ratelimit";
        \\import { schemaCompile } from "zttp:validate";
        \\function handler(req) {
        \\  cacheSet("ns", "k", "v");
        \\  rateCheck("k", 5, 60);
        \\  schemaCompile("item", "{\"type\":\"object\"}");
        \\  return Response.text("ok");
        \\}
    , "<stateful-modules>");
    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);

    // Floor: each active module that keeps state has filled its slot, so the
    // ownership check below runs against live state rather than an empty array.
    for ([_]Slot{ .sql, .fetch, .cache, .ratelimit, .validate }) |slot| {
        try std.testing.expect(rt.ctx.module_state[@backingInt(slot)] != null);
    }
    // Retired ordinals (ledger, tool, durable, and the rest) have no owner, so
    // no runtime path may write state there.
    for (rt.ctx.module_state, 0..) |entry, slot| {
        if (entry != null) try std.testing.expect(zq.module_slots.ownerSpecifier(slot) != null);
    }
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
    \\  if (upstream.ok !== true) {
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

    const url = switch (try buildFetchUrl(rt.httpView(), pool, "https://api.open-meteo.com/v1/forecast", init)) {
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

    const url = switch (try buildFetchUrl(rt.httpView(), pool, "https://api.open-meteo.com/v1/forecast", init)) {
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

    const url = switch (try buildFetchUrl(rt.httpView(), pool, "https://api.example.com/v1?format=json", init)) {
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

    const handler_code = try allocator.print(
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
    , .{url});
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

    const handler_code = try allocator.print(
        \\function handler(req) {{
        \\  const resp = fetchSync("{s}");
        \\  const data = resp.json();
        \\  return Response.json({{
        \\    status: resp.status,
        \\    ok: resp.ok,
        \\    error: data.error
        \\  }});
        \\}}
    , .{url});
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

const RetryProbe = struct {
    status: i64,
    err: []const u8,
    served: u32,
};

/// Runs `fetchWithRetry(url, init, { maxRetries: 2, baseDelayMs: 0 })` in a
/// handler against a listener that answers 503 to every request it accepts.
fn probeFetchWithRetry(allocator: std.mem.Allocator, init_js: []const u8) !RetryProbe {
    var server = try TestHttpServer.init(allocator, .sequenced_status);
    server.status_sequence = &.{ 503, 503, 503 };
    defer server.join() catch {};
    try server.start();

    const url = try server.url(allocator, "/retry");
    defer allocator.free(url);

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "127.0.0.1",
        .outbound_timeout_ms = 1000,
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();

    const handler_code = try allocator.print(
        \\import {{ fetchWithRetry }} from "zttp:fetch";
        \\function handler(req) {{
        \\  const resp = fetchWithRetry("{s}", {s}, {{ maxRetries: 2, baseDelayMs: 0 }});
        \\  return Response.json({{
        \\    status: resp.status,
        \\    error: resp.error ?? "none"
        \\  }});
        \\}}
    , .{ url, init_js });
    defer allocator.free(handler_code);
    try rt.loadHandler(handler_code, "<fetchwithretry-credential>");

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try server.finish();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    return .{
        .status = obj.get("status").?.integer,
        .err = try allocator.dupe(u8, obj.get("error").?.string),
        .served = server.served.load(.acquire),
    };
}

test "fetchWithRetry refuses an authorization header before any request is sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probe = try probeFetchWithRetry(arena.allocator(), "{ headers: { authorization: \"Bearer t\" } }");
    try std.testing.expectEqual(@as(i64, 599), probe.status);
    try std.testing.expectEqualStrings("CredentialRefused", probe.err);
    try std.testing.expectEqual(@as(u32, 0), probe.served);
}

test "fetchWithRetry refuses a mixed-case Authorization header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probe = try probeFetchWithRetry(arena.allocator(), "{ method: \"POST\", headers: { \"Content-Type\": \"text/plain\", \"Authorization\": \"Bearer t\" }, body: \"x\" }");
    try std.testing.expectEqual(@as(i64, 599), probe.status);
    try std.testing.expectEqualStrings("CredentialRefused", probe.err);
    try std.testing.expectEqual(@as(u32, 0), probe.served);
}

test "fetchWithRetry refuses a cookie header and a proxy-authorization header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cookie = try probeFetchWithRetry(arena.allocator(), "{ headers: { \"COOKIE\": \"sid=1\" } }");
    try std.testing.expectEqualStrings("CredentialRefused", cookie.err);
    try std.testing.expectEqual(@as(u32, 0), cookie.served);
    const proxy = try probeFetchWithRetry(arena.allocator(), "{ headers: { \"Proxy-Authorization\": \"Basic x\" } }");
    try std.testing.expectEqualStrings("CredentialRefused", proxy.err);
    try std.testing.expectEqual(@as(u32, 0), proxy.served);
}

test "fetchWithRetry without a credential header is still retried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const probe = try probeFetchWithRetry(arena.allocator(), "{ method: \"POST\", headers: { \"X-Test\": \"alpha\" }, body: \"x\" }");
    try std.testing.expectEqual(@as(i64, 503), probe.status);
    try std.testing.expectEqualStrings("none", probe.err);
    try std.testing.expectEqual(@as(u32, 3), probe.served);
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
        const handler_code = try allocator.print(
            \\function handler(req) {{
            \\  const resp = fetchSync("{s}");
            \\  const data = resp.json();
            \\  return Response.json({{ status: resp.status, error: data.error, details: data.details }});
            \\}}
        , .{target_url});
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

    const target_url = try allocator.print("https://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
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

    const target_url = try allocator.print("http://127.0.0.1:{d}/", .{port});
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
        @backingInt(zq.Opcode.ret),
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

    const before = try compat.monotonicNowNs();
    rt.armRequestDeadline();
    const after = try compat.monotonicNowNs();
    try std.testing.expect(rt.ctx.deadline_ns >= before + 50 * std.time.ns_per_ms);
    try std.testing.expect(rt.ctx.deadline_ns <= after + 50 * std.time.ns_per_ms);
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
        @backingInt(zq.Opcode.ret),
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
        @backingInt(zq.Opcode.ret_undefined),
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
    // atom. The fusion is now deleted (bytecode_opt.zig). Covers the literal
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

test "HTML rendering works through ordinary TypeScript calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();

    const handler_code =
        \\function handler(req){
        \\  const elem = h("div", null, "Hello");
        \\  return Response.html(renderToString(elem));
        \\}
    ;
    try rt.loadHandler(handler_code, "test.ts");

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

test "handler loading refuses retired source extensions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rt = try HandlerInstance.init(arena.allocator(), .{});
    defer rt.deinit();
    const source = "function handler(req) { return Response.text('ok'); }";

    try std.testing.expectError(error.UnsupportedSourceExtension, rt.loadHandler(source, "handler.js"));
    try std.testing.expectError(error.UnsupportedSourceExtension, rt.loadHandler(source, "handler.jsx"));
    try std.testing.expectError(error.UnsupportedSourceExtension, rt.loadHandler(source, "handler.tsx"));
}

test "constant folding matches runtime arithmetic and preserves short circuit effects" {
    const cases = [_]struct { expression: []const u8, dynamic: []const u8, expected: f64 }{
        .{ .expression = "7 / 2", .dynamic = "const a = 7; const b = 2; return a / b;", .expected = 3.5 },
        .{ .expression = "-5 % 3", .dynamic = "const a = -5; const b = 3; return a % b;", .expected = -2 },
        .{ .expression = "5 % -3", .dynamic = "const a = 5; const b = -3; return a % b;", .expected = 2 },
        .{ .expression = "(-2147483647 - 1) % -1", .dynamic = "const a = -2147483647 - 1; const b = -1; return a % b;", .expected = 0 },
        .{ .expression = "-(-2147483647 - 1)", .dynamic = "const a = -2147483647 - 1; return -a;", .expected = 2147483648 },
        .{ .expression = "2147483647 + 1", .dynamic = "const a = 2147483647; return a + 1;", .expected = 2147483648 },
        .{ .expression = "1.5 + 2.5", .dynamic = "const a = 1.5; const b = 2.5; return a + b;", .expected = 4 },
        .{ .expression = "(1.5 + 2.5) * 2", .dynamic = "const a = 1.5; const b = 2.5; return (a + b) * 2;", .expected = 8 },
        .{ .expression = "-0.0 / 2", .dynamic = "const a = -0.0; return a / 2;", .expected = -0.0 },
        .{ .expression = "1 / 0", .dynamic = "const a = 1; const b = 0; return a / b;", .expected = std.math.inf(f64) },
        .{ .expression = "1 % 0", .dynamic = "const a = 1; const b = 0; return a % b;", .expected = std.math.nan(f64) },
        .{ .expression = "1 << 33", .dynamic = "const a = 1; const b = 33; return a << b;", .expected = 2 },
        .{ .expression = "~5", .dynamic = "const a = 5; return ~a;", .expected = -6 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const source = try allocator.print("function folded() {{ return {s}; }} function baseline() {{ {s} }}", .{ case.expression, case.dynamic });
        const rt = try HandlerInstance.init(allocator, .{});
        defer rt.deinit();
        try rt.loadCodeNoHandler(source, "<bench>");
        const folded = try rt.callGlobalFunction("folded", &.{});
        const baseline = try rt.callGlobalFunction("baseline", &.{});
        const actual = folded.toNumber() orelse return error.TestUnexpectedResult;
        const reference = baseline.toNumber() orelse return error.TestUnexpectedResult;
        if (std.math.isNan(case.expected)) {
            try std.testing.expect(std.math.isNan(actual));
            try std.testing.expect(std.math.isNan(reference));
        } else {
            try std.testing.expectEqual(@as(u64, @bitCast(case.expected)), @as(u64, @bitCast(actual)));
            try std.testing.expectEqual(@as(u64, @bitCast(reference)), @as(u64, @bitCast(actual)));
        }
        try std.testing.expectEqual(baseline.isInt(), folded.isInt());
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rt = try HandlerInstance.init(arena.allocator(), .{});
    defer rt.deinit();
    try rt.loadCodeNoHandler(
        \\function run() {
        \\  let count = 0;
        \\  function touch() { count = count + 1; return true; }
        \\  const a = false && touch();
        \\  const b = true || touch();
        \\  const c = true && touch();
        \\  const d = false || touch();
        \\  const truth = !(5 < 2) && !!true;
        \\  return truth ? count : -1;
        \\}
    , "<bench>");
    const result = try rt.callGlobalFunction("run", &.{});
    try std.testing.expect(result.isInt());
    try std.testing.expectEqual(@as(i32, 2), result.getInt());
}

test "runtime strings survive the borrowed parser source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try allocator.dupe(u8,
        \\function handler(req) { return Response.json(["plain", "escaped\nvalue", "plain"]); }
    );
    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadHandler(source, "strings.ts");
    @memset(source, 'x');
    var response = try rt.executeHandler(.{ .method = "GET", .url = "/", .headers = .empty, .body = null });
    defer response.deinit();
    try std.testing.expectEqualStrings("[\"plain\",\"escaped\\nvalue\",\"plain\"]", response.body);
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

test "outbound adapters preserve exchange results and failure stages" {
    const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x33\x30\x34\x32\x36\x31\x35\x33\xb7\xb0\x4c\x4c\x4a\x4e\x49\x4d\x33\x40\xe3\x03\x00\x0e\xb5\x59\x77\x20\x00\x00\x00";
    const Case = struct { response: []const u8 = "", expected_error: []const u8 = "", silent: bool = false, fail_send: bool = false };
    const cases = [_]Case{
        .{ .response = "HTTP/1.1 201 Origin Supplied\r\nContent-Length: 4\r\nContent-Type: text/plain\r\nX-Reply: seen\r\nConnection: close\r\n\r\nbody" },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 32\r\nConnection: close\r\n\r\nshort", .expected_error = "ResponseReadFailed" },
        .{ .response = "invalid response\r\n\r\n", .expected_error = "ResponseHeadFailed" },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 39\r\nConnection: close\r\n\r\n" ++ gzip_body, .expected_error = "ResponseTooLarge" },
        .{ .silent = true, .expected_error = "TimedOut" },
        .{ .silent = true, .fail_send = true, .expected_error = "RequestSendFailed" },
    };
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .net_write) return .{ .net_write = error.ConnectionResetByPeer };
            const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
            return threaded.io().operate(operation);
        }
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var previous_details: ?[]const u8 = null;
        for ([_]bool{ false, true }) |json_adapter| {
            var server = try TestHttpServer.init(std.testing.allocator, if (case.silent) .silent_hold else .raw_response);
            server.raw_response = case.response;
            defer server.join() catch {};
            try server.start();
            const url = try server.url(allocator, "/exchange");
            const rt = try HandlerInstance.init(allocator, .{
                .outbound_http_enabled = true,
                .outbound_allow_host = "127.0.0.1",
                .outbound_timeout_ms = 250,
                .outbound_max_response_bytes = 16,
                .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
            });
            defer rt.deinit();
            if (case.fail_send) rt.outbound_io_backend.?.vtable.operate = FailWrite.operate;
            const source = if (json_adapter)
                try allocator.print(
                    \\function handler(req) {{
                    \\  const result = JSON.parse(httpRequest(JSON.stringify({{ url: "{s}", method: "POST", body: req.body, headers: {{ "X-Test": "borrowed" }} }})));
                    \\  return Response.json({{ status: result.status ?? 599, error: result.error ?? "", details: result.details ?? "", body: result.body ?? "", reason: result.reason ?? "", reply: "" }});
                    \\}}
                , .{url})
            else
                try allocator.print(
                    \\function handler(req) {{
                    \\  const result = fetchSync("{s}", {{ method: "POST", body: req.body, headers: {{ "X-Test": "borrowed" }} }});
                    \\  const failure = result.status === 599 ? JSON.parse(result.body) : {{ error: "", details: "" }};
                    \\  return Response.json({{ status: result.status, error: failure.error, details: failure.details, body: result.body, reason: result.statusText, reply: result.headers.get("x-reply") ?? "" }});
                    \\}}
                , .{url});
            try rt.loadHandler(source, "<outbound-adapter-parity>");
            var request = try makeTestRequest(allocator, "GET", "/", null);
            defer request.deinit(allocator);
            if (case.fail_send) {
                const body = try allocator.alloc(u8, 64 * 1024);
                @memset(body, 'x');
                request.body = body;
            }
            var response = try rt.executeHandler(request.asView());
            defer response.deinit();
            try server.join();
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
            defer parsed.deinit();
            const result = parsed.value.object;
            try std.testing.expectEqualStrings(case.expected_error, result.get("error").?.string);
            try std.testing.expectEqual(@as(i64, if (case.expected_error.len == 0) 201 else 599), result.get("status").?.integer);
            if (case.expected_error.len == 0) {
                try std.testing.expectEqualStrings("body", result.get("body").?.string);
                try std.testing.expectEqualStrings("Origin Supplied", result.get("reason").?.string);
                if (!json_adapter) try std.testing.expectEqualStrings("seen", result.get("reply").?.string);
            } else if (previous_details) |expected| {
                try std.testing.expectEqualStrings(expected, result.get("details").?.string);
            } else {
                previous_details = try allocator.dupe(u8, result.get("details").?.string);
            }
        }
    }
}

test "a POST with no body is sent with an empty body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sync_upstream = try TestHttpServer.init(std.testing.allocator, .echo_request_json);
    defer sync_upstream.join() catch {};
    var bridge_upstream = try TestHttpServer.init(std.testing.allocator, .echo_request_json);
    defer bridge_upstream.join() catch {};
    try sync_upstream.start();
    try bridge_upstream.start();
    const sync_url = try sync_upstream.url(allocator, "/sync");
    const bridge_url = try bridge_upstream.url(allocator, "/bridge");

    const rt = try HandlerInstance.init(allocator, .{
        .outbound_http_enabled = true,
        .outbound_allow_host = "127.0.0.1",
        .dev_capability_policy = .{ .egress_scopes = (zq.endpoint.ScopeSet{}).with(.loopback) },
    });
    defer rt.deinit();
    const source = try allocator.print(
        \\function handler(req) {{
        \\  const sync = JSON.parse(fetchSync("{s}", {{ method: "POST" }}).body);
        \\  const bridge = JSON.parse(JSON.parse(httpRequest(JSON.stringify({{ url: "{s}", method: "PUT" }}))).body);
        \\  return Response.json({{ sync: sync.contentLength, bridge: bridge.contentLength }});
        \\}}
    , .{ sync_url, bridge_url });
    try rt.loadHandler(source, "<empty-post-control>");

    var request = try makeTestRequest(allocator, "GET", "/", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try sync_upstream.join();
    try bridge_upstream.join();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0", parsed.value.object.get("sync").?.string);
    try std.testing.expectEqualStrings("0", parsed.value.object.get("bridge").?.string);
}

test "sseEvents returns events and a tagged framing failure through the JS API" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rt = try HandlerInstance.init(allocator, .{});
    defer rt.deinit();
    try rt.loadHandler(
        \\import { sseEvents } from "zttp:sse";
        \\function handler(req) {
        \\  const bounds = { maxBodyBytes: 128, maxBlockBytes: 128, maxEvents: 4 };
        \\  const events = sseEvents("id: shared\ndata: one\n\ndata: two\n\n", bounds);
        \\  const incomplete = sseEvents("data: unfinished", bounds);
        \\  return Response.json({
        \\    eventsOk: events.ok,
        \\    eventCount: events.ok ? events.value.length : -1,
        \\    firstEvent: events.ok ? events.value[0].event : "",
        \\    firstData: events.ok ? events.value[0].data : "",
        \\    firstId: events.ok ? events.value[0].id : "",
        \\    secondData: events.ok ? events.value[1].data : "",
        \\    secondId: events.ok ? events.value[1].id : "",
        \\    incompleteOk: incomplete.ok,
        \\    errorTag: incomplete.ok ? "" : incomplete.error.tag,
        \\    errorOffset: incomplete.ok ? -1 : incomplete.error.offset
        \\  });
        \\}
    , "<sse-js-result>");

    var request = try makeTestRequest(allocator, "GET", "/sse", null);
    defer request.deinit(allocator);
    var response = try rt.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const output = parsed.value.object;
    try std.testing.expect(output.get("eventsOk").?.bool);
    try std.testing.expectEqual(@as(i64, 2), output.get("eventCount").?.integer);
    try std.testing.expectEqualStrings("message", output.get("firstEvent").?.string);
    try std.testing.expectEqualStrings("one", output.get("firstData").?.string);
    try std.testing.expectEqualStrings("shared", output.get("firstId").?.string);
    try std.testing.expectEqualStrings("two", output.get("secondData").?.string);
    try std.testing.expectEqualStrings("shared", output.get("secondId").?.string);
    try std.testing.expect(!output.get("incompleteOk").?.bool);
    try std.testing.expectEqualStrings("unterminated_event", output.get("errorTag").?.string);
    try std.testing.expectEqual(@as(i64, 0), output.get("errorOffset").?.integer);
}

test "prepared evaluation omits authored types while raw virtual and file profiles remain distinct" {
    const source = "function handler(req: Request): Response { const value: number = \"ok\"; return Response.text(value); }";
    const raw = try HandlerInstance.init(std.testing.allocator, .{});
    defer raw.deinit();
    try std.testing.expectError(error.UnexpectedToken, raw.loadCode(source, "<eval>"));
    const file = try HandlerInstance.init(std.testing.allocator, .{});
    defer file.deinit();
    try std.testing.expectError(error.SoundModeViolation, file.loadCode(source, "handler.ts"));
    const prepared = try HandlerInstance.init(std.testing.allocator, .{});
    defer prepared.deinit();
    try prepared.loadPreparedEval(.{ .code = source }, "<eval>");
    var request = HttpRequestOwned{
        .method = try std.testing.allocator.dupe(u8, "GET"),
        .url = try std.testing.allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(std.testing.allocator);
    var response = try prepared.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
    try std.testing.expectError(error.UnsupportedSourceExtension, prepared.loadPreparedEval(.{ .code = source }, "handler.ts"));
}

test "prepared evaluation keeps typed entry source through imported compilation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.ts", .data = "export function message(value: number): string { return \"ok\"; }" });
    const source = try allocator.print("import {{ message }} from \"./.zig-cache/tmp/{s}/dep.ts\"; function handler(req: Request): Response {{ return Response.text(message(\"wrong\")); }}", .{tmp.sub_path});
    defer allocator.free(source);
    const runtime = try HandlerInstance.init(allocator, .{});
    defer runtime.deinit();
    try runtime.loadPreparedEval(.{ .code = source }, "<eval>");
    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);
    var response = try runtime.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
}
