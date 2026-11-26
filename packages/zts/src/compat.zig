const std = @import("std");
const builtin = @import("builtin");

pub const ClockError = error{ClockGettimeFailed};

fn clockGetTime(clock_id: std.posix.CLOCK) ClockError!std.posix.timespec {
    var ts: std.posix.timespec = undefined;
    const rc = std.c.clock_gettime(
        @as(std.c.clockid_t, @fromBackingInt(@intCast(@backingInt(clock_id)))),
        &ts,
    );
    if (rc != 0) return error.ClockGettimeFailed;
    return ts;
}

pub fn realtimeNowNs() ClockError!u64 {
    const ts = try clockGetTime(.REALTIME);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

pub fn realtimeNowMs() ClockError!i64 {
    const ts = try clockGetTime(.REALTIME);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn monotonicNowNs() ClockError!u64 {
    const ts = try clockGetTime(.MONOTONIC);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

pub const Instant = struct {
    ns: u64,

    pub fn now() ClockError!Instant {
        return .{ .ns = try monotonicNowNs() };
    }

    pub fn since(self: Instant, start: Instant) u64 {
        return self.ns -| start.ns;
    }
};

pub const Timer = struct {
    start_ns: u64,

    pub fn start() ClockError!Timer {
        return .{ .start_ns = try monotonicNowNs() };
    }

    pub fn read(self: *const Timer) u64 {
        const now = monotonicNowNs() catch return 0;
        return now -| self.start_ns;
    }
};

fn futexWait(ptr: *const u32, expect: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_4arg(ptr, .{ .cmd = .WAIT, .private = true }, expect, null);
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            _ = std.c.__ulock_wait(.{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true }, ptr, expect, 0);
        },
        else => std.Thread.yield() catch {},
    }
}

fn futexWake(ptr: *const u32, max_waiters: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_3arg(
                ptr,
                .{ .cmd = .WAKE, .private = true },
                @min(max_waiters, std.math.maxInt(i32)),
            );
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            const flags: std.c.UL = .{
                .op = .COMPARE_AND_WAIT,
                .NO_ERRNO = true,
                .WAKE_ALL = max_waiters > 1,
            };
            while (true) {
                const status = std.c.__ulock_wake(flags, ptr, 0);
                if (status >= 0) return;
                const err: std.c.E = @fromBackingInt(@intCast(-status));
                if (err != .INTR and err != .CANCELED) return;
            }
        },
        else => {},
    }
}

/// Pure-Zig relocatable futex mutex (0 unlocked, 1 locked, 2 locked + waiters).
pub const Mutex = struct {
    state: u32 = 0,

    pub fn lock(self: *Mutex) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        if (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) == null) return;
        while (true) {
            if (@atomicLoad(u32, &self.state, .monotonic) == 2 or
                @cmpxchgWeak(u32, &self.state, 1, 2, .monotonic, .monotonic) != null)
            {
                futexWait(&self.state, 2);
            }
            if (@atomicRmw(u32, &self.state, .Xchg, 2, .acquire) == 0) return;
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        if (@atomicRmw(u32, &self.state, .Sub, 1, .release) != 1) {
            @atomicStore(u32, &self.state, 0, .release);
            futexWake(&self.state, 1);
        }
    }
};

/// Pure-Zig relocatable futex read/write lock:
/// bit 0 = active writer, bit 1 = waiters present, bits 2..31 = reader count.
pub const RwLock = struct {
    state: u32 = 0,

    const writer_bit: u32 = 1;
    const waiter_bit: u32 = 2;
    const reader_inc: u32 = 4;

    pub fn lock(self: *RwLock) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        while (true) {
            const s = @atomicLoad(u32, &self.state, .monotonic);
            if ((s & ~waiter_bit) == 0) {
                if (@cmpxchgWeak(u32, &self.state, s, s | writer_bit, .acquire, .monotonic) == null) return;
                continue;
            }
            const want = s | waiter_bit;
            if (s != want and @cmpxchgWeak(u32, &self.state, s, want, .monotonic, .monotonic) != null) continue;
            futexWait(&self.state, want);
        }
    }

    pub fn unlock(self: *RwLock) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        const prev = @atomicRmw(u32, &self.state, .Xchg, 0, .release);
        if ((prev & waiter_bit) != 0) {
            futexWake(&self.state, std.math.maxInt(u32));
        }
    }

    pub fn lockShared(self: *RwLock) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        while (true) {
            const s = @atomicLoad(u32, &self.state, .monotonic);
            if ((s & writer_bit) == 0) {
                if (@cmpxchgWeak(u32, &self.state, s, s + reader_inc, .acquire, .monotonic) == null) return;
                continue;
            }
            const want = s | waiter_bit;
            if (s != want and @cmpxchgWeak(u32, &self.state, s, want, .monotonic, .monotonic) != null) continue;
            futexWait(&self.state, want);
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        if (comptime builtin.single_threaded or builtin.os.tag == .freestanding) return;
        const prev = @atomicRmw(u32, &self.state, .Sub, reader_inc, .release);
        if ((prev >> 2) == 1 and (prev & waiter_bit) != 0) {
            _ = @cmpxchgStrong(u32, &self.state, waiter_bit, 0, .monotonic, .monotonic);
            futexWake(&self.state, std.math.maxInt(u32));
        }
    }
};
