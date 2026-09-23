//! Wall-clock deadline for one outbound HTTP fetch.
//!
//! Kept apart from `runtime_http.zig` so the developer CLI can bound its own
//! outbound calls without importing the JS runtime's fetch natives. There is
//! exactly one definition.

const std = @import("std");

/// Wall-clock deadline for one outbound fetch, enforced by a watchdog thread
/// that full-shutdowns the socket once the deadline passes. SO_RCVTIMEO is
/// unusable because the Threaded backend treats a socket EAGAIN as a
/// programmer bug (panics in Debug). After shutdown, blocked reads surface
/// EndOfStream and blocked writes SocketUnconnected, which the call sites map
/// to a clean fetch error. `disarm` must run before the connection is released
/// so the watchdog can never shut down a recycled fd.
///
/// One deadline covers the connect, the TLS handshake, and the exchange.
/// `begin` fixes its end once, before the connect; `outbound_io.zig` bounds the
/// connect by it and arms the watchdog on the new socket before std starts the
/// TLS handshake. A caller that arms without `begin` gets a deadline that starts
/// at `arm`.
pub const FetchDeadline = struct {
    stream: std.Io.net.Stream = undefined,
    timeout_ms: u32,
    io: std.Io,
    ends_at: ?std.Io.Clock.Timestamp = null,
    event: std.Io.Event = .unset,
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    /// Fixes the end of the fetch. A second call keeps the first end, so the
    /// connect and the exchange can never each take a full budget.
    pub fn begin(self: *FetchDeadline) error{ZeroTimeout}!void {
        if (self.timeout_ms == 0) return error.ZeroTimeout;
        if (self.ends_at != null) return;
        const duration: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(self.timeout_ms)),
            .clock = .awake,
        };
        self.ends_at = std.Io.Clock.Timestamp.fromNow(self.io, duration);
    }

    /// Milliseconds left before the end, rounded up, for `poll`. 0 once the
    /// end has passed. Requires `begin`.
    pub fn remainingMs(self: *const FetchDeadline) i32 {
        const ns = self.ends_at.?.durationFromNow(self.io).raw.nanoseconds;
        if (ns <= 0) return 0;
        const ms = @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }

    /// Refuses rather than skips: an exchange that runs without its watchdog
    /// has no bound at all, so neither a zero timeout nor a failed spawn may
    /// leave the caller believing it is bounded.
    pub fn arm(self: *FetchDeadline) error{ ZeroTimeout, WatchdogUnavailable }!void {
        try self.begin();
        self.thread = std.Thread.spawn(.{}, watch, .{self}) catch return error.WatchdogUnavailable;
    }

    pub fn isArmed(self: *const FetchDeadline) bool {
        return self.thread != null;
    }

    fn watch(self: *FetchDeadline) void {
        const deadline = self.ends_at.?;
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

    /// The fetch error code for a failed connect. A connect that ran out of
    /// budget reports `Timeout`; a handshake the watchdog cut reports its own
    /// error with the deadline fired.
    pub fn connectFailCode(self: *const FetchDeadline, err: anyerror) []const u8 {
        return if (err == error.Timeout) "TimedOut" else self.failCode("ConnectFailed");
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
    try deadline.arm();
    defer deadline.disarm();
    try std.testing.expect(!deadline.expired());

    var buf: [64]u8 = undefined;
    var reader = stream.reader(io, &buf);
    // Without the watchdog this never returns.
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());

    try std.testing.expect(deadline.expired());
    try std.testing.expectEqualStrings("TimedOut", deadline.failCode("ResponseReadFailed"));
}

test "a zero timeout refuses to arm and disarm stays safe" {
    var io_backend = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var deadline: FetchDeadline = .{ .stream = undefined, .timeout_ms = 0, .io = io };
    try std.testing.expectError(error.ZeroTimeout, deadline.arm());
    deadline.disarm();
    try std.testing.expect(!deadline.expired());
    try std.testing.expectEqualStrings("ResponseReadFailed", deadline.failCode("ResponseReadFailed"));
}
