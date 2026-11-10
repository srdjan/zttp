//! Shared mapping from a model-provider HTTP error response to a typed error.
//!
//! Provider wire layers call `classify`; the catch sites
//! turn each typed error into one-line remediation via
//! `loop.providerErrorRemediation`. Keeping the status/body interpretation in
//! one place means providers cannot drift in how they report auth,
//! credit, rate-limit, model, overload, and prompt-too-long failures.

const std = @import("std");
const response_sanitize = @import("response_sanitize.zig");

pub fn uriHost(uri: std.Uri, buffer: *[std.Io.net.HostName.max_len]u8) std.Io.net.HostName.FromUriError!std.Io.net.HostName {
    const component = uri.host orelse return error.UriMissingHost;
    const bytes = component.toRaw(buffer) catch return error.NameTooLong;
    // The local provider accepts IPv6 loopback as well as DNS names.
    if (std.Io.net.IpAddress.parseLiteral(bytes)) |_| return .{ .bytes = bytes } else |_| {}
    return std.Io.net.HostName.fromUri(uri, buffer);
}

/// Map an HTTP error status (and, for ambiguous 4xx, the error body) to a typed
/// provider error. The body substrings cover the conventions the providers use:
/// a 400 "credit balance is too low", a 429 "insufficient_quota", and a 400
/// "context_length_exceeded".
pub fn classify(status_code: u16, body: []const u8) anyerror {
    return switch (status_code) {
        401, 403 => error.AuthFailed,
        404 => error.ModelNotFound,
        429 => if (containsAny(body, &.{ "insufficient_quota", "credit balance", "quota" }))
            error.InsufficientCredit
        else
            error.RateLimited,
        529 => error.ProviderOverloaded,
        else => blk: {
            if (status_code >= 500) break :blk error.ProviderServerError;
            if (status_code == 400) {
                if (containsAny(body, &.{"credit balance"})) break :blk error.InsufficientCredit;
                if (containsAny(body, &.{ "prompt is too long", "context_length_exceeded", "maximum context", "too long" }))
                    break :blk error.PromptTooLong;
            }
            break :blk error.HttpNotOk;
        },
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

/// TCP connect + TLS handshake budget. Bounds a captive-portal / unreachable
/// endpoint so a request fails fast instead of hanging on connect.
pub const connect_timeout_ms: u64 = 15_000;

/// Idle-read budget for the streamed response. A reasoning response streams
/// tokens continuously, so this many milliseconds with zero bytes is a genuine
/// stall (overloaded endpoint, dropped-but-not-reset connection), not a slow
/// answer. Bounded via SO_RCVTIMEO so a stalled stream cannot hang forever.
pub const read_idle_timeout_ms: u64 = 120_000;

/// Send budget for the request body. A half-open / stalled peer that accepts
/// the connection but never drains its receive window would otherwise block the
/// body write (writeAll + flush) forever. Bounded via SO_SNDTIMEO.
pub const write_idle_timeout_ms: u64 = 120_000;

/// The same guard with an explicit budget, for a provider whose silence is not
/// a stall. A non-streaming completion sends its response head at once and then
/// nothing at all until generation finishes, so the default idle budget would
/// expire in the middle of a healthy request. That matters more than a slow
/// error: `SO_RCVTIMEO` surfaces as POSIX EAGAIN inside a blocking read, which
/// Zig 0.16 treats as a programmer bug and panics on rather than returning an
/// error, so an under-sized budget aborts the process.
pub fn setReadTimeoutMs(fd: std.posix.fd_t, timeout_ms: u64) void {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// True for the connect/read errors that mean a network stall, so the wire
/// layer can return a clean `error.RequestTimedOut`.
pub fn isTimeout(err: anyerror) bool {
    return err == error.Timeout or err == error.WouldBlock;
}

/// Open a provider connection with the shared connect timeout and idle-read
/// guard, mapping a connect timeout to a clean `error.RequestTimedOut`. Both
/// the local and DeepSeek clients go through this so the timeout policy and
/// the socket-option dance live in exactly one place. `explicit_port` is the
/// URI's port, if any; otherwise the protocol default is used.
pub fn connect(
    client: *std.http.Client,
    host: std.Io.net.HostName,
    explicit_port: ?u16,
    protocol: std.http.Client.Protocol,
) !*std.http.Client.Connection {
    return connectWithin(client, host, explicit_port, protocol, null);
}

pub fn connectWithin(
    client: *std.http.Client,
    host: std.Io.net.HostName,
    explicit_port: ?u16,
    protocol: std.http.Client.Protocol,
    request_timeout_ms: ?u64,
) !*std.http.Client.Connection {
    // A caller with no deadline gets each budget's own default. Folding the
    // absent case into the connect budget would cut the 120 s idle budgets to
    // 15 s, and an under-sized `SO_RCVTIMEO` panics rather than returning (see
    // `setReadTimeoutMs`).
    const remaining: ?u64 = if (request_timeout_ms) |ms| @max(@as(u64, 1), ms) else null;
    const connect_budget_ms = @min(connect_timeout_ms, remaining orelse connect_timeout_ms);
    // `std.http.Client.connectTcpOptions` does not read its `timeout` option, and
    // the TLS handshake runs before a socket timeout can be set. The connect
    // therefore races a sleep, and the race cancels the task that loses.
    const io = client.io;
    var race_buffer: [2]ConnectRace.Union = undefined;
    var race: ConnectRace = .init(io, &race_buffer);
    race.concurrent(.expired, std.Io.sleep, .{
        io,
        std.Io.Duration.fromMilliseconds(connect_budget_ms),
        .awake,
    }) catch |err| {
        abandonConnect(&race, client);
        return err;
    };
    race.concurrent(.connected, std.http.Client.connectTcpOptions, .{ client, .{
        .host = host,
        .port = explicit_port orelse switch (protocol) {
            .plain => 80,
            .tls => 443,
        },
        .protocol = protocol,
    } }) catch |err| {
        abandonConnect(&race, client);
        return err;
    };
    const first = race.await() catch |err| {
        abandonConnect(&race, client);
        return err;
    };
    const connection = switch (first) {
        .expired => {
            abandonConnect(&race, client);
            return error.RequestTimedOut;
        },
        .connected => |result| connected: {
            race.cancelDiscard();
            break :connected try result;
        },
    };
    // Bound a stalled stream so a hung response can't freeze the CLI forever,
    // on both the read side (SO_RCVTIMEO) and the body-write side (SO_SNDTIMEO).
    const sock_handle = connection.stream_reader.stream.socket.handle;
    setReadTimeoutMs(sock_handle, if (remaining) |ms| @min(read_idle_timeout_ms, ms) else read_idle_timeout_ms);
    setWriteTimeoutMs(sock_handle, if (remaining) |ms| @min(write_idle_timeout_ms, ms) else write_idle_timeout_ms);
    return connection;
}

const ConnectRace = std.Io.Select(union(enum) {
    connected: std.http.Client.ConnectTcpError!*std.http.Client.Connection,
    expired: std.Io.Cancelable!void,
});

/// Cancel the tasks that remain in the race. A connection that completed after
/// the budget expired is closed, so the pool holds no used connection.
fn abandonConnect(race: *ConnectRace, client: *std.http.Client) void {
    while (race.cancel()) |late| switch (late) {
        .connected => |result| if (result) |connection| {
            connection.closing = true;
            client.connection_pool.release(connection, client.io);
        } else |_| {},
        .expired => {},
    };
}

pub fn setWriteTimeoutMs(fd: std.posix.fd_t, timeout_ms: u64) void {
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// The body length a response head promises, or null when the head does not
/// promise a length that the body reader's output must match: a chunked
/// transfer ends itself, and a compressed body decodes to a different length.
pub fn declaredBodyLength(head: std.http.Client.Response.Head) ?u64 {
    if (head.transfer_encoding != .none) return null;
    if (head.content_encoding != .identity) return null;
    return head.content_length;
}

/// Read the response body as it arrives, polling the socket before each wait
/// (shared by both provider clients).
///
/// A read to end of stream in one call is bounded only by `SO_RCVTIMEO`, and an
/// expired `SO_RCVTIMEO` panics instead of returning (see `setReadTimeoutMs`).
/// Each pass here takes the bytes that are available and does not wait for a
/// full chunk, so a body that trickles in and goes quiet is bounded too. The
/// socket is polled only when `reader` and every reader in `upstream` hold no
/// bytes: a byte that the HTTP connection reader already took off the socket is
/// not readable there, and polling would report a stall that is not one.
/// `upstream` lists the connection readers beneath the body reader.
///
/// `request_timeout_ms` is the budget that remains when the call starts. Each wait gets
/// that budget minus the time already spent in this function, so a body that keeps
/// trickling still ends with `error.RequestTimedOut` when the budget is gone.
///
/// A connection that closes mid-body ends the reader as if the body were
/// whole, so a stream that ends with fewer than `declared_len` bytes is
/// `error.BodyTruncated`: a transport failure that a caller may reissue, not a
/// decode failure. A body that reaches `declared_len` ends without a further wait.
pub fn readBodyWithin(
    reader: *std.Io.Reader,
    arena: std.mem.Allocator,
    limit_bytes: usize,
    fd: std.posix.fd_t,
    silence_ceiling_ms: i32,
    request_timeout_ms: i32,
    upstream: []const *const std.Io.Reader,
    declared_len: ?u64,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(arena);
    const started_ns = response_sanitize.monotonicNowNs();
    while (true) {
        if (declared_len == body.items.len) break;
        if (!hasBufferedBytes(reader, upstream)) {
            try waitForReadable(fd, silence_ceiling_ms, remainingMs(started_ns, request_timeout_ms));
        }
        reader.fill(1) catch |err| {
            if (err == error.EndOfStream) break;
            if (isTimeout(err)) return error.RequestTimedOut;
            return err;
        };
        const available = reader.buffered();
        if (body.items.len + available.len > limit_bytes) return error.StreamTooLong;
        try body.appendSlice(arena, available);
        reader.tossBuffered();
    }
    if (declared_len) |len| {
        if (body.items.len < len) return error.BodyTruncated;
    }
    return body.toOwnedSlice(arena);
}

fn hasBufferedBytes(reader: *const std.Io.Reader, upstream: []const *const std.Io.Reader) bool {
    if (reader.bufferedLen() > 0) return true;
    for (upstream) |lower| {
        if (lower.bufferedLen() > 0) return true;
    }
    return false;
}

/// Receive the response head with a poll before each socket read (shared by
/// both provider clients).
///
/// `Request.receiveHead` reads the socket until the head is whole. A peer that
/// sends part of a head, or part of a TLS record, and then goes quiet holds
/// that read until `SO_RCVTIMEO` expires, and an expired `SO_RCVTIMEO` panics
/// instead of returning (see `setReadTimeoutMs`). The fill here leaves a whole
/// head in the connection reader, so the parser reads no socket.
///
/// The two budgets and the two timeout errors are those of `waitForReadable`.
pub fn receiveHeadWithin(
    request: *std.http.Client.Request,
    silence_ceiling_ms: i32,
    request_timeout_ms: i32,
) !std.http.Client.Response {
    const connection = request.connection.?;
    try fillHeadWithin(
        connection.reader(),
        request.reader.max_head_len,
        connection.stream_reader.stream.socket.handle,
        silence_ceiling_ms,
        request_timeout_ms,
        if (connection.protocol == .tls) &connection.stream_reader.interface else null,
    );
    return request.receiveHead(&.{});
}

/// Fill `reader`, the connection reader that the HTTP parser reads, until it
/// holds a whole response head. `tls_input` is the socket reader beneath a TLS
/// client, or null when `reader` reads the socket itself.
///
/// The fill stops without an error at a head of `max_head_len` bytes, at the
/// end of the stream, and at a failed read. The HTTP parser meets each of
/// those again without a blocking read, and reports it.
pub fn fillHeadWithin(
    reader: *std.Io.Reader,
    max_head_len: usize,
    fd: std.posix.fd_t,
    silence_ceiling_ms: i32,
    request_timeout_ms: i32,
    tls_input: ?*std.Io.Reader,
) error{ RequestTimedOut, RequestStalled, PollFailed }!void {
    const started_ns = response_sanitize.monotonicNowNs();
    var parser: std.http.HeadParser = .{};
    var head_len: usize = 0;
    while (true) {
        head_len += parser.feed(reader.buffered()[head_len..]);
        if (parser.state == .finished or head_len >= max_head_len) return;
        try waitForInput(fd, tls_input, silence_ceiling_ms, started_ns, request_timeout_ms);
        reader.fillMore() catch return;
    }
}

/// Block until one read from the connection reader cannot block on the socket.
///
/// On a plain connection that is a readable socket. A TLS client reads the
/// socket until `tls_input` holds one whole record, so a readable socket is not
/// enough: a record that arrives in part and then stops holds the client in a
/// blocking read. The record is therefore completed here, with a poll before
/// each socket read. A read that ends or fails stops the wait without an
/// error, because the TLS client meets the same end or failure at once.
///
/// Each poll gets `request_timeout_ms` minus the time spent since `started_ns`.
fn waitForInput(
    fd: std.posix.fd_t,
    tls_input: ?*std.Io.Reader,
    silence_ceiling_ms: i32,
    started_ns: ?u64,
    request_timeout_ms: i32,
) error{ RequestTimedOut, RequestStalled, PollFailed }!void {
    const input = tls_input orelse
        return waitForReadable(fd, silence_ceiling_ms, remainingMs(started_ns, request_timeout_ms));
    while (!holdsTlsRecord(input)) {
        try waitForReadable(fd, silence_ceiling_ms, remainingMs(started_ns, request_timeout_ms));
        input.fillMore() catch return;
    }
}

/// True when the TLS client can take its next record from `input` without a
/// socket read. A record that the buffer cannot hold counts as held: the TLS
/// client refuses it from its header, without a read.
fn holdsTlsRecord(input: *std.Io.Reader) bool {
    const header_len = std.crypto.tls.record_header_len;
    const buffered = input.buffered();
    if (buffered.len < header_len) return false;
    const record_len = header_len + @as(usize, std.mem.readInt(u16, buffered[3..5], .big));
    return buffered.len >= record_len or record_len > input.buffer.len;
}

/// Block until the socket has bytes to read, bounded by the silence ceiling.
/// Used before the head and again before the body: a blocking read that
/// outlives `SO_RCVTIMEO` panics instead of erroring, so the wait is done here
/// where a timeout is a typed error.
///
/// Which error it is depends on what was still on the clock. A ceiling shorter
/// than the request budget expiring is `error.RequestStalled`: this one request
/// went quiet while the turn could still afford another, which the caller may
/// reissue. A ceiling that reaches the budget expiring is
/// `error.RequestTimedOut`: the budget itself is gone, and reissuing would only
/// fail again with nothing left to spend.
///
/// `request_timeout_ms` is the budget that remains at the call. The poll lasts for the
/// shorter of the ceiling and that budget, and a budget of zero or less fails at once.
pub fn waitForReadable(
    fd: std.posix.fd_t,
    silence_ceiling_ms: i32,
    request_timeout_ms: i32,
) error{ RequestTimedOut, RequestStalled, PollFailed }!void {
    if (request_timeout_ms <= 0) return error.RequestTimedOut;
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, @min(silence_ceiling_ms, request_timeout_ms)) catch
        return error.PollFailed;
    if (ready != 0) return;
    if (silence_ceiling_ms < request_timeout_ms) return error.RequestStalled;
    return error.RequestTimedOut;
}

/// The part of `budget_ms` left since `started_ns`, never below zero. An unavailable
/// clock counts as no time spent.
pub fn remainingMs(started_ns: ?u64, budget_ms: i32) i32 {
    const spent: u64 = response_sanitize.elapsedMs(started_ns) orelse 0;
    const spent_ms: i32 = @intCast(@min(spent, @as(u64, std.math.maxInt(i32))));
    return @max(budget_ms -| spent_ms, 0);
}

pub fn effectiveRequestTimeoutMs(request_timeout_ms: ?u64, ceiling_ms: i32) i32 {
    const ceiling: u64 = @intCast(ceiling_ms);
    return @intCast(@max(@as(u64, 1), @min(request_timeout_ms orelse ceiling, ceiling)));
}

const testing = std.testing;

test "URI hosts preserve IPv6 loopback and reject missing and oversized names" {
    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const loopback = try std.Uri.parse("http://[::1]:8080/");
    try testing.expectEqualStrings("[::1]", (try uriHost(loopback, &buffer)).bytes);
    const missing = try std.Uri.parse("file:///tmp/x");
    try testing.expectError(error.UriMissingHost, uriHost(missing, &buffer));
    const name: [300]u8 = @splat('a');
    const overlong: std.Uri = .{ .scheme = "https", .host = .{ .percent_encoded = &name } };
    try testing.expectError(error.NameTooLong, uriHost(overlong, &buffer));
}

test "classify maps common provider statuses to typed errors" {
    try testing.expectEqual(error.AuthFailed, classify(401, ""));
    try testing.expectEqual(error.AuthFailed, classify(403, ""));
    try testing.expectEqual(error.ModelNotFound, classify(404, ""));
    try testing.expectEqual(error.RateLimited, classify(429, "rate_limit_error"));
    try testing.expectEqual(error.InsufficientCredit, classify(429, "insufficient_quota"));
    try testing.expectEqual(error.InsufficientCredit, classify(400, "your credit balance is too low"));
    try testing.expectEqual(error.PromptTooLong, classify(400, "context_length_exceeded"));
    try testing.expectEqual(error.PromptTooLong, classify(400, "prompt is too long for the model"));
    try testing.expectEqual(error.ProviderOverloaded, classify(529, ""));
    try testing.expectEqual(error.ProviderServerError, classify(500, ""));
    try testing.expectEqual(error.ProviderServerError, classify(503, ""));
    try testing.expectEqual(error.HttpNotOk, classify(400, "some other bad request"));
}
