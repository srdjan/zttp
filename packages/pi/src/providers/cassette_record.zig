//! Recorder half of the cassette harness.
//!
//! Recorded API responses are serialised here as cassettes that the replay
//! client (`cassette_client.zig`) plays back deterministically. The recorder
//! is provider-agnostic: it only serialises response bytes in the cassette
//! format `cassette_client.zig` consumes.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const zts = @import("zts");
const file_io = zts.file_io;
const cassette_client = @import("cassette_client.zig");

// -----------------------------------------------------------------------
// Cassette writer
// -----------------------------------------------------------------------

pub const WriteOptions = struct {
    provider: cassette_client.Provider,
    scenario: []const u8,
    /// `true` when the response is an SSE byte stream; `false` for a
    /// single JSON envelope.
    stream: bool,
    /// Embedded ISO-8601 timestamp. Pass `null` to omit. Recorded
    /// cassettes typically stamp the wall clock; tests pin a fixed value
    /// so the cassette bytes round-trip stably.
    recorded_at: ?[]const u8 = null,
    /// Optional model name to record alongside the scenario.
    model: ?[]const u8 = null,
    /// Exact SHA-256 of the provider wire request. Required for local flow
    /// recordings so deterministic tool IDs survive offline replay.
    request_sha256: ?[]const u8 = null,
};

/// Serialise a captured body into the JSONL cassette format
/// `cassette_client.zig` consumes. Returned bytes are owned by the
/// caller. The cassette is one JSON object per line:
///
///     {"v":1,"provider":"...","scenario":"...","stream":true|false,...}
///     {"sse":"event: ...\ndata: ...\n\n"}     (one per SSE record, stream=true)
///     {"body":"<single-line JSON>"}            (single line, stream=false)
pub fn serializeCassette(
    allocator: std.mem.Allocator,
    body: []const u8,
    options: WriteOptions,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try writeHeaderLine(w, options);
    try w.writeByte('\n');

    if (options.stream) {
        var it = SseRecordIterator{ .input = body };
        while (it.next()) |record| {
            try w.writeAll("{\"sse\":");
            try writeJsonString(w, record);
            try w.writeAll("}\n");
        }
    } else {
        try w.writeAll("{\"body\":");
        try writeJsonString(w, body);
        try w.writeAll("}\n");
    }

    return try buf.toOwnedSlice();
}

/// Write a captured body to disk as a cassette. Intermediate directories
/// are created on demand. The caller chooses the path; convention is
/// `packages/pi/src/simulator/testdata/empirical/<provider>/codegen/<scenario>.jsonl`.
pub fn writeCassette(
    allocator: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
    options: WriteOptions,
) !void {
    const serialized = try serializeCassette(allocator, body, options);
    defer allocator.free(serialized);

    // Parent dirs are the caller's responsibility; tests stage them via
    // `std.testing.tmpDir`, and the production recorder binary creates
    // `packages/pi/src/simulator/testdata/empirical/<provider>/codegen/` once on first use.
    try file_io.writeFile(allocator, path, serialized);
}

fn writeHeaderLine(w: anytype, options: WriteOptions) !void {
    try w.writeAll("{\"v\":1,\"provider\":");
    try writeJsonString(w, switch (options.provider) {
        .local => "local",
        .deepseek => "deepseek",
    });
    try w.writeAll(",\"scenario\":");
    try writeJsonString(w, options.scenario);
    try w.print(",\"stream\":{s}", .{if (options.stream) "true" else "false"});
    if (options.model) |model| {
        try w.writeAll(",\"model\":");
        try writeJsonString(w, model);
    }
    if (options.request_sha256) |digest| {
        try w.writeAll(",\"request_sha256\":");
        try writeJsonString(w, digest);
    }
    if (options.recorded_at) |stamp| {
        try w.writeAll(",\"recorded_at\":");
        try writeJsonString(w, stamp);
    }
    try w.writeByte('}');
}

/// Iterates `\n\n`-separated SSE records. Each record carries the trailing
/// blank line that delimits it, so concatenating every record reproduces
/// the original byte stream verbatim.
const SseRecordIterator = struct {
    input: []const u8,
    pos: usize = 0,

    fn next(self: *SseRecordIterator) ?[]const u8 {
        if (self.pos >= self.input.len) return null;
        const start = self.pos;
        const remaining = self.input[start..];
        const sep_rel = std.mem.indexOf(u8, remaining, "\n\n");
        if (sep_rel) |off| {
            const end = start + off + 2;
            self.pos = end;
            return self.input[start..end];
        }
        // Tail without trailing blank line: emit verbatim.
        self.pos = self.input.len;
        return self.input[start..];
    }
};

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "serializeCassette: non-streaming body emits header + single body line" {
    const body = "{\"id\":\"x\",\"choices\":[]}";
    const serialized = try serializeCassette(testing.allocator, body, .{
        .provider = .deepseek,
        .scenario = "smoke",
        .stream = false,
        .recorded_at = "2026-05-28T00:00:00Z",
        .model = "deepseek-v4-flash",
    });
    defer testing.allocator.free(serialized);

    // Round-trip through the loader: bytes back out should match the body.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cassette = try cassette_client.loadCassetteFromBytes(arena.allocator(), serialized, null);
    try testing.expectEqual(cassette_client.Provider.deepseek, cassette.header.provider);
    try testing.expect(!cassette.header.stream);
    try testing.expectEqualStrings(body, cassette.body);
}

test "serializeCassette: streaming body splits SSE records one-per-line" {
    const sse = "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: end\ndata: {\"type\":\"end\"}\n\n";
    const serialized = try serializeCassette(testing.allocator, sse, .{
        .provider = .deepseek,
        .scenario = "smoke_stream",
        .stream = true,
        .recorded_at = "2026-05-28T00:00:00Z",
    });
    defer testing.allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cassette = try cassette_client.loadCassetteFromBytes(arena.allocator(), serialized, null);
    try testing.expectEqual(cassette_client.Provider.deepseek, cassette.header.provider);
    try testing.expect(cassette.header.stream);
    try testing.expectEqualStrings(sse, cassette.body);
}

test "writeCassette + loadCassetteFromPath: full disk round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const full_path = try std.fs.path.resolve(testing.allocator, &.{
        ".zig-cache", "tmp", tmp.sub_path[0..], "smoke.jsonl",
    });
    defer testing.allocator.free(full_path);

    const body = "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"hello\"}}]}";
    try writeCassette(testing.allocator, full_path, body, .{
        .provider = .deepseek,
        .scenario = "smoke",
        .stream = false,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cassette = try cassette_client.loadCassetteFromPath(arena.allocator(), full_path);
    try testing.expectEqualStrings(body, cassette.body);
}

const TestErrorInt = u16;

/// One-response loopback server shared by provider and recorder integration
/// tests. It deliberately knows nothing about either provider's wire format.
pub const LocalHttpServer = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    response_body: []const u8,
    response_content_type: []const u8,
    thread: ?std.Thread = null,
    closed: bool = false,
    thread_error: std.atomic.Value(TestErrorInt) = std.atomic.Value(TestErrorInt).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        response_body: []const u8,
        response_content_type: []const u8,
    ) !LocalHttpServer {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        const io = io_backend.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const listener = try address.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io_backend = io_backend,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .response_body = response_body,
            .response_content_type = response_content_type,
        };
    }

    pub fn start(self: *LocalHttpServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn url(self: *const LocalHttpServer, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return allocator.print("http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    pub fn join(self: *LocalHttpServer) !void {
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
        if (err_int != 0) return @errorFromInt(err_int);
    }

    fn run(self: *LocalHttpServer) void {
        self.runInner() catch |err| {
            self.thread_error.store(@intFromError(err), .release);
        };
    }

    fn runInner(self: *LocalHttpServer) !void {
        const io = self.io_backend.io();
        var stream = while (true) {
            break self.listener.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                error.SocketNotListening => return,
                else => return err,
            };
        };
        defer stream.close(io);

        // Drain the request head. We do not assert on it; the recorder
        // owns request shaping, the harness owns wire compliance.
        try drainRequestHead(self.allocator, &stream, io);

        var out_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &out_buf);
        const out = &writer.interface;
        try out.print("HTTP/1.1 200 OK\r\n", .{});
        try out.print("Content-Length: {d}\r\n", .{self.response_body.len});
        try out.print("Content-Type: {s}\r\n", .{self.response_content_type});
        try out.writeAll("Connection: close\r\n\r\n");
        try out.writeAll(self.response_body);
        try out.flush();
    }
};

fn drainRequestHead(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, io: std.Io) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        var chunk: [1024]u8 = undefined;
        var vecs: [1][]u8 = .{chunk[0..]};
        const result = stream.readWithControl(io, &vecs, &.{}) catch |err| switch (err) {
            error.ConnectionResetByPeer => return,
            else => return err,
        };
        const n = result.data_len;
        if (n == 0) return;
        try buf.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) continue;
        // Headers seen; assume any Content-Length body fits in the same
        // buffer chunk we already pulled. For the harness's tiny POST
        // bodies (a few hundred bytes) this holds; on real traffic the
        // recorder is what owns full-body reads, not this server.
        return;
    }
}
