//! Loopback-only HTTP server for the deterministic OpenAI wire stand-in.

const std = @import("std");
const playbook = @import("playbook.zig");
const request = @import("request.zig");

const max_request_bytes: usize = 16 * 1024 * 1024;
const ErrorInt = u16;

pub const Server = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    max_requests: ?usize,
    thread: ?std.Thread = null,
    closed: bool = false,
    thread_error: std.atomic.Value(ErrorInt) = std.atomic.Value(ErrorInt).init(0),
    /// Set before waking the accept loop so it returns instead of serving the
    /// wake-up connection. Read by the loop, written by `deinit`.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        max_requests: ?usize,
    ) !Server {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        errdefer io_backend.deinit();
        const io = io_backend.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        const listener = try address.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io_backend = io_backend,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .max_requests = max_requests,
        };
    }

    pub fn start(self: *Server) !void {
        if (self.thread != null) return error.ServerAlreadyStarted;
        self.thread = try std.Thread.spawn(.{}, runThread, .{self});
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    pub fn serve(self: *Server) !void {
        try self.serveInner();
    }

    /// Wake the accept loop, join the thread, and surface whatever it failed
    /// with. Safe whether or not the loop finished on its own.
    ///
    /// This replaces a `join` that only worked when the caller had predicted
    /// the exact number of requests a run would make. A prediction that came in
    /// high left the loop blocked in `accept` while the caller blocked in
    /// `join`, so drift between a playbook and the loop hung the suite instead
    /// of failing it.
    pub fn stop(self: *Server) !void {
        if (self.closed) return;
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            self.wakeAcceptLoop();
            thread.join();
            self.thread = null;
        }
        const err_int = self.thread_error.swap(0, .acq_rel);
        self.closeResources();
        if (err_int != 0) return @errorFromInt(err_int);
    }

    /// Shut down from any state, including with the accept loop still blocked.
    ///
    /// The thread is woken by connecting to our own port rather than by closing
    /// the listener under it: `listener.deinit` invalidates the value the
    /// blocked `accept` is reading, so closing first and joining second raced
    /// the thread and turned an early return - a failed assertion running
    /// `defer server.deinit()` before `join()` - into a hang or a panic.
    pub fn deinit(self: *Server) void {
        if (self.closed) return;
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            self.wakeAcceptLoop();
            thread.join();
            self.thread = null;
        }
        const io = self.io_backend.io();
        self.listener.deinit(io);
        self.io_backend.deinit();
        self.closed = true;
        const err_int = self.thread_error.swap(0, .acq_rel);
        if (err_int != 0) {
            std.log.err("zttp-standin server thread failed: {s}", .{@errorName(@errorFromInt(err_int))});
        }
    }

    fn closeResources(self: *Server) void {
        if (self.closed) return;
        const io = self.io_backend.io();
        self.listener.deinit(io);
        self.io_backend.deinit();
        self.closed = true;
    }

    fn runThread(self: *Server) void {
        self.serveInner() catch |err| {
            self.thread_error.store(@intFromError(err), .release);
        };
    }

    /// Best-effort connect to our own listener so a blocked `accept` returns.
    /// Any failure is ignored: the thread is being torn down either way, and a
    /// wake-up that does not arrive is reported by the join that follows.
    fn wakeAcceptLoop(self: *Server) void {
        const io = self.io_backend.io();
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }

    fn serveInner(self: *Server) !void {
        const io = self.io_backend.io();
        var served: usize = 0;
        while (self.max_requests == null or served < self.max_requests.?) {
            if (self.stopping.load(.acquire)) return;
            var stream = while (true) {
                break self.listener.accept(io) catch |err| switch (err) {
                    error.ConnectionAborted => continue,
                    error.SocketNotListening => return,
                    else => return err,
                };
            };
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                return;
            }
            {
                defer stream.close(io);
                // One bad connection must not end the server. A port probe
                // closes without sending and yields UnexpectedEof; a header
                // line without a colon yields InvalidRequest. Propagating
                // either killed the accept loop, so the dev server exited
                // mid-session and an offline turn lost its author. Note the
                // asymmetry this removes: parseHttpRequest's InvalidRequest
                // was already answered with a 400.
                serveConnection(self.allocator, &stream, io) catch |err| {
                    std.log.warn("zttp-standin dropped a connection: {s}", .{@errorName(err)});
                };
            }
            // Counted even when the connection failed, so a client that always
            // errors cannot spin here forever and a bounded run always
            // terminates. A test that loses a request fails at its assertions
            // rather than hanging in join().
            served += 1;
        }
    }
};

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

const HttpResponse = struct {
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []u8,

    fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

fn serveConnection(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_bytes = try readRequest(arena.allocator(), stream, io);
    const parsed = parseHttpRequest(request_bytes) catch |err| switch (err) {
        error.InvalidRequest => {
            var response = try plainResponse(allocator, 400, "Bad Request", "invalid HTTP request\n");
            defer response.deinit(allocator);
            return writeResponse(stream, io, response);
        },
    };
    var response = try dispatch(allocator, parsed);
    defer response.deinit(allocator);
    try writeResponse(stream, io, response);
}

fn readRequest(arena: std.mem.Allocator, stream: *std.Io.net.Stream, io: std.Io) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(arena);
    var expected_len: ?usize = null;

    while (bytes.items.len <= max_request_bytes) {
        if (expected_len) |len| {
            if (bytes.items.len >= len) return try bytes.toOwnedSlice(arena);
        }

        var chunk: [4096]u8 = undefined;
        var vecs: [1][]u8 = .{chunk[0..]};
        const count = try io.vtable.netRead(io.userdata, stream.socket.handle, &vecs);
        if (count == 0) return error.UnexpectedEof;
        try bytes.appendSlice(arena, chunk[0..count]);
        if (bytes.items.len > max_request_bytes) return error.RequestTooLarge;

        if (expected_len == null) {
            if (std.mem.indexOf(u8, bytes.items, "\r\n\r\n")) |head_end| {
                const content_length = try parseContentLength(bytes.items[0..head_end]);
                if (content_length > max_request_bytes - (head_end + 4)) return error.RequestTooLarge;
                expected_len = head_end + 4 + content_length;
            }
        }
    }
    return error.RequestTooLarge;
}

fn parseContentLength(head: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next() orelse return error.InvalidRequest;
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        if (content_length != null) return error.InvalidRequest;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRequest;
    }
    return content_length orelse 0;
}

fn parseHttpRequest(bytes: []const u8) !HttpRequest {
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.InvalidRequest;
    const first_line_end = std.mem.indexOf(u8, bytes[0..head_end], "\r\n") orelse return error.InvalidRequest;
    const first_line = bytes[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    _ = parts.next() orelse return error.InvalidRequest;
    if (parts.next() != null) return error.InvalidRequest;
    return .{ .method = method, .path = path, .body = bytes[head_end + 4 ..] };
}

fn dispatch(allocator: std.mem.Allocator, incoming: HttpRequest) !HttpResponse {
    if (std.mem.eql(u8, incoming.method, "GET") and std.mem.eql(u8, incoming.path, "/_health")) {
        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"protocol\":\"{s}\",\"version\":\"{s}\"}}\n",
            .{ playbook.protocol, playbook.version },
        );
        errdefer allocator.free(body);
        return .{ .status = 200, .reason = "OK", .content_type = "application/json", .body = body };
    }

    if (std.mem.eql(u8, incoming.method, "POST") and std.mem.eql(u8, incoming.path, "/v1/responses")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = request.parse(arena.allocator(), incoming.body) catch |err| switch (err) {
            error.InvalidRequest, error.MissingAsk => return plainResponse(
                allocator,
                400,
                "Bad Request",
                "invalid Responses API request\n",
            ),
            else => return err,
        };
        const body = playbook.renderResponse(allocator, parsed) catch |err| switch (err) {
            error.InvalidRouteSpec => return plainResponse(
                allocator,
                400,
                "Bad Request",
                "invalid add-route intent\n",
            ),
            else => return err,
        };
        errdefer allocator.free(body);
        return .{ .status = 200, .reason = "OK", .content_type = "text/event-stream", .body = body };
    }

    return plainResponse(allocator, 404, "Not Found", "not found\n");
}

fn plainResponse(
    allocator: std.mem.Allocator,
    status: u16,
    reason: []const u8,
    text: []const u8,
) !HttpResponse {
    const body = try allocator.dupe(u8, text);
    errdefer allocator.free(body);
    return .{ .status = status, .reason = reason, .content_type = "text/plain", .body = body };
}

fn writeResponse(stream: *std.Io.net.Stream, io: std.Io, response: HttpResponse) !void {
    var out_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const out = &writer.interface;
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ response.status, response.reason });
    try out.print("Content-Length: {d}\r\n", .{response.body.len});
    try out.print("Content-Type: {s}\r\n", .{response.content_type});
    try out.writeAll("Cache-Control: no-store\r\nConnection: close\r\n\r\n");
    try out.writeAll(response.body);
    try out.flush();
}

const testing = std.testing;

test "stand-in health response carries protocol and stand-in version" {
    var response = try dispatch(testing.allocator, .{ .method = "GET", .path = "/_health", .body = "" });
    defer response.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, playbook.protocol) != null);
    try testing.expect(std.mem.indexOf(u8, response.body, playbook.version) != null);
}
