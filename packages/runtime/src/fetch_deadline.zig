//! Wall-clock deadline for one outbound HTTP exchange.
//!
//! Extracted from `runtime_http.zig` so the developer CLI can bound its own
//! outbound calls without importing the JS runtime's fetch natives. That file
//! keeps an alias, so its three call sites are unchanged and there is still
//! exactly one definition.

const std = @import("std");

/// Wall-clock deadline for one outbound exchange, enforced by a watchdog
/// thread that full-shutdowns the socket once the deadline passes. The std
/// paths cannot bound this themselves: ConnectTcpOptions.timeout is declared
/// but never read by std.http.Client, and SO_RCVTIMEO is unusable because the
/// Threaded backend treats a socket EAGAIN as a programmer bug (panics in
/// Debug). After shutdown, blocked reads surface EndOfStream and blocked
/// writes SocketUnconnected, which the call sites map to a clean fetch error.
/// `disarm` must run before the connection is released so the watchdog can
/// never shut down a recycled fd.
///
/// It bounds the exchange, not the connect: the TLS handshake has already
/// happened by the time a caller has a stream to arm this on.
pub const FetchDeadline = struct {
    stream: std.Io.net.Stream,
    timeout_ms: u32,
    io: std.Io,
    event: std.Io.Event = .unset,
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn arm(self: *FetchDeadline) void {
        if (self.timeout_ms == 0) return;
        self.thread = std.Thread.spawn(.{}, watch, .{self}) catch null;
    }

    fn watch(self: *FetchDeadline) void {
        const duration: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(self.timeout_ms)),
            .clock = .awake,
        };
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, duration);
        while (true) {
            if (self.event.waitTimeout(self.io, .{ .deadline = deadline })) |_| {
                return;
            } else |err| switch (err) {
                error.Canceled => return,
                // waitTimeout reports spurious wakeups as Timeout; trust
                // only the clock.
                error.Timeout => if (deadline.durationFromNow(self.io).raw.nanoseconds <= 0) break,
            }
        }
        if (self.event.isSet()) return;
        self.fired.store(true, .seq_cst);
        self.stream.shutdown(self.io, .both) catch {};
    }

    pub fn disarm(self: *FetchDeadline) void {
        const thread = self.thread orelse return;
        self.event.set(self.io);
        thread.join();
        self.thread = null;
    }

    pub fn expired(self: *const FetchDeadline) bool {
        return self.fired.load(.seq_cst);
    }

    pub fn failCode(self: *const FetchDeadline, fallback: []const u8) []const u8 {
        return if (self.expired()) "TimedOut" else fallback;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "an armed deadline shuts down a stalled read and reports that it fired" {
    // A listening peer that never replies is the stall this exists for: the
    // connect succeeds through the backlog, and the read then blocks with
    // nothing to bound it but this watchdog.
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const loopback = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const peer = try std.Io.net.IpAddress.parseIp4("127.0.0.1", listener.socket.address.getPort());
    var stream = try peer.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var deadline: FetchDeadline = .{ .stream = stream, .timeout_ms = 50, .io = io };
    deadline.arm();
    defer deadline.disarm();
    try std.testing.expect(!deadline.expired());

    var buf: [64]u8 = undefined;
    var reader = stream.reader(io, &buf);
    // Without the watchdog this never returns.
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());

    try std.testing.expect(deadline.expired());
    try std.testing.expectEqualStrings("TimedOut", deadline.failCode("ResponseReadFailed"));
}

test "a zero timeout arms nothing and disarm stays safe" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var deadline: FetchDeadline = .{ .stream = undefined, .timeout_ms = 0, .io = io };
    deadline.arm();
    deadline.disarm();
    try std.testing.expect(!deadline.expired());
    try std.testing.expectEqualStrings("ResponseReadFailed", deadline.failCode("ResponseReadFailed"));
}
