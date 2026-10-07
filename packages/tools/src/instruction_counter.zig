//! Retired-instruction counter for the current process, with a named source.
//!
//! A budget gate needs a cost number that does not depend on machine load.
//! Retired user-space instructions are close to that: the same work gives
//! nearly the same count on each run. Wall time is not.
//!
//! The reader tries the best source the host offers and says which one
//! produced the number, so a caller can gate on an instruction source and only
//! report on the CPU-time fallback:
//!
//! - macOS: `proc_pid_rusage` with `RUSAGE_INFO_V4`, field `ri_instructions`.
//! - Linux: `perf_event_open` with `PERF_COUNT_HW_INSTRUCTIONS`, user space
//!   only. It fails under a strict `perf_event_paranoid` setting and in a
//!   virtual machine with no performance counters.
//! - Everywhere else, and when the Linux open fails: CPU time (user plus
//!   system) in nanoseconds from `getrusage`.
//!
//! Values from different sources are not comparable. `delta` refuses to
//! subtract across sources.

const std = @import("std");
const builtin = @import("builtin");

pub const Source = enum {
    instructions_darwin,
    instructions_linux_perf,
    cpu_time_ns,

    /// True when `value` counts instructions rather than nanoseconds.
    pub fn countsInstructions(self: Source) bool {
        return switch (self) {
            .instructions_darwin, .instructions_linux_perf => true,
            .cpu_time_ns => false,
        };
    }
};

pub const Reading = struct {
    source: Source,
    value: u64,
};

pub const DeltaError = error{
    /// The two readings come from different sources, so the difference means nothing.
    SourceMismatch,
    /// The later reading is smaller than the earlier one.
    CounterWentBackwards,
};

pub fn delta(before: Reading, after: Reading) DeltaError!u64 {
    if (before.source != after.source) return error.SourceMismatch;
    if (after.value < before.value) return error.CounterWentBackwards;
    return after.value - before.value;
}

// ---------------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------------

/// `struct rusage_info_v4` from the macOS SDK header `sys/resource.h`, copied
/// field by field. A struct one `u64` short does not fail: the kernel fills
/// what fits and `ri_instructions` reads 0. The size assertion below is why
/// that cannot happen unnoticed.
const RusageInfoV4 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
};

/// `RUSAGE_INFO_V4` in `sys/resource.h`.
const rusage_info_v4_flavor: c_int = 4;

/// `sizeof(struct rusage_info_v4)` and `offsetof(.., ri_instructions)`, both
/// measured with the macOS SDK C compiler against `sys/resource.h`.
const rusage_info_v4_size: usize = 296;
const ri_instructions_offset: usize = 248;

comptime {
    if (@sizeOf(RusageInfoV4) != rusage_info_v4_size)
        @compileError("RusageInfoV4 does not match sizeof(struct rusage_info_v4) in sys/resource.h");
    if (@offsetOf(RusageInfoV4, "ri_instructions") != ri_instructions_offset)
        @compileError("RusageInfoV4.ri_instructions does not match its offset in sys/resource.h");
}

const darwin = struct {
    extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV4) c_int;

    fn read() ?u64 {
        var info: RusageInfoV4 = undefined;
        if (proc_pid_rusage(std.c.getpid(), rusage_info_v4_flavor, &info) != 0) return null;
        return info.ri_instructions;
    }
};

// ---------------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------------

const linux_perf = struct {
    const linux = std.os.linux;

    /// Opens a user-space instruction counter on the calling thread. Returns
    /// null when the kernel or the host refuses.
    fn open() ?linux.fd_t {
        var attr: linux.perf_event_attr = .{
            .type = .HARDWARE,
            .config = @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS),
            .flags = .{ .exclude_kernel = true, .exclude_hv = true },
        };
        const rc = linux.perf_event_open(&attr, 0, -1, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return @intCast(rc);
    }

    fn read(fd: linux.fd_t) ?u64 {
        var value: u64 = 0;
        const rc = linux.read(fd, @ptrCast(&value), @sizeOf(u64));
        if (linux.errno(rc) != .SUCCESS or rc != @sizeOf(u64)) return null;
        return value;
    }

    fn close(fd: linux.fd_t) void {
        _ = linux.close(fd);
    }
};

// ---------------------------------------------------------------------------
// Fallback
// ---------------------------------------------------------------------------

/// User plus system CPU time of the process, in nanoseconds.
fn cpuTimeNs() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const ns_per_us: u64 = 1000;
    const ns_per_s: u64 = 1_000_000_000;
    const user_s: u64 = @intCast(usage.utime.sec);
    const user_us: u64 = @intCast(usage.utime.usec);
    const sys_s: u64 = @intCast(usage.stime.sec);
    const sys_us: u64 = @intCast(usage.stime.usec);
    return (user_s + sys_s) * ns_per_s + (user_us + sys_us) * ns_per_us;
}

// ---------------------------------------------------------------------------
// Counter
// ---------------------------------------------------------------------------

/// An open reader. `open` never fails: it falls back to CPU time and reports
/// that in `source`. On Linux the counter belongs to the thread that opened it,
/// so read it from that thread. Close it when done.
pub const Counter = struct {
    source: Source,
    /// The perf file descriptor on Linux, otherwise unused.
    fd: i32 = -1,

    pub fn open() Counter {
        switch (builtin.os.tag) {
            .macos => {
                // Probe once: a host that refuses the call falls back.
                if (darwin.read() != null) return .{ .source = .instructions_darwin };
            },
            .linux => {
                if (linux_perf.open()) |fd| {
                    return .{ .source = .instructions_linux_perf, .fd = fd };
                }
            },
            else => {},
        }
        return .{ .source = .cpu_time_ns };
    }

    pub fn close(self: *Counter) void {
        if (builtin.os.tag == .linux and self.source == .instructions_linux_perf) {
            linux_perf.close(self.fd);
            self.fd = -1;
        }
    }

    /// The cumulative count since the process (or, on Linux perf, the counter)
    /// began. A failed read of an instruction source reports 0, which the tests
    /// reject as a zero count; use `delta` between two readings for a cost.
    pub fn read(self: *const Counter) Reading {
        const value: u64 = switch (self.source) {
            .instructions_darwin => if (builtin.os.tag == .macos) (darwin.read() orelse 0) else 0,
            .instructions_linux_perf => if (builtin.os.tag == .linux) (linux_perf.read(self.fd) orelse 0) else 0,
            .cpu_time_ns => cpuTimeNs(),
        };
        return .{ .source = self.source, .value = value };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Work the optimizer cannot remove or fold: each step depends on the last
/// and the result escapes through `doNotOptimizeAway`.
fn spin(iterations: u64) u64 {
    var x: u64 = 0x9E3779B97F4A7C15;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        x ^= x >> 29;
        std.mem.doNotOptimizeAway(x);
    }
    return x;
}

fn cost(counter: *const Counter, iterations: u64) !u64 {
    const before = counter.read();
    std.mem.doNotOptimizeAway(spin(iterations));
    const after = counter.read();
    return delta(before, after);
}

test "counter names its source and never silently falls back on macOS" {
    var counter = Counter.open();
    defer counter.close();
    if (builtin.os.tag == .macos) {
        // A fallback on the developer machine would turn every budget gate
        // into a report-only check without anyone noticing.
        try std.testing.expectEqual(Source.instructions_darwin, counter.source);
    }
    const reading = counter.read();
    try std.testing.expectEqual(counter.source, reading.source);
    try std.testing.expect(reading.value > 0);
}

test "counter cost grows with the work done" {
    var counter = Counter.open();
    defer counter.close();
    const n: u64 = 2_000_000;

    const small = try cost(&counter, n);
    const big = try cost(&counter, 2 * n);
    try std.testing.expect(small > 0);

    if (counter.source.countsInstructions()) {
        // Doubling the iterations doubles the loop; the fixed cost of the two
        // readings is tiny against two million iterations. The window leaves
        // room for interrupt and scheduler noise.
        const ratio = @as(f64, @floatFromInt(big)) / @as(f64, @floatFromInt(small));
        if (ratio < 1.5 or ratio > 2.5) {
            std.debug.print("source {s}: n={d} cost {d}, 2n cost {d}, ratio {d:.3}\n", .{ @tagName(counter.source), n, small, big, ratio });
            return error.TestUnexpectedResult;
        }
    } else {
        // CPU time is coarse (microseconds) and noisy, so assert only that a
        // much larger run costs more than a small one.
        const huge = try cost(&counter, 64 * n);
        try std.testing.expect(huge > small);
    }
}

test "counter ignores work it did not do" {
    var counter = Counter.open();
    defer counter.close();
    if (!counter.source.countsInstructions()) return error.SkipZigTest;
    // Two back-to-back readings bracket almost no work. If the count were
    // wall time, or moved while nothing ran, this window would be large.
    const before = counter.read();
    const after = counter.read();
    const idle = try delta(before, after);
    try std.testing.expect(idle < 100_000);
}

test "delta refuses mismatched sources and backwards counters" {
    const a: Reading = .{ .source = .instructions_darwin, .value = 10 };
    const b: Reading = .{ .source = .cpu_time_ns, .value = 20 };
    try std.testing.expectError(error.SourceMismatch, delta(a, b));
    const later: Reading = .{ .source = .instructions_darwin, .value = 5 };
    try std.testing.expectError(error.CounterWentBackwards, delta(a, later));
    try std.testing.expectEqual(@as(u64, 15), try delta(later, .{ .source = .instructions_darwin, .value = 20 }));
}

test "macOS rusage_info_v4 layout matches the SDK header" {
    try std.testing.expectEqual(@as(usize, 296), @sizeOf(RusageInfoV4));
    try std.testing.expectEqual(@as(usize, 248), @offsetOf(RusageInfoV4, "ri_instructions"));
    try std.testing.expectEqual(@as(usize, 256), @offsetOf(RusageInfoV4, "ri_cycles"));
}
