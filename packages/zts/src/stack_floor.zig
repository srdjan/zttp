//! Native stack floor for script recursion.
//!
//! Every script call is also a native call, and the native frame of one Debug
//! `Interpreter.dispatch` is about 85 KB. `Context.call_stack_size` limits
//! script frames, and nothing compared that limit with the stack of the thread.
//! `floor` returns the lowest stack address at which the interpreter may start
//! another script call. Below it the interpreter returns `CallStackOverflow`.

const std = @import("std");
const builtin = @import("builtin");

/// Native stack reserved below the floor. It covers one Debug `dispatch` frame
/// (85,424 bytes) and the deepest bounded native leaf that runs below the last
/// script call: `JSON.stringify` of an array nested 500 deep (the writer limit
/// is 512). With the leaf at every level of unbounded recursion, a headroom of
/// 1 MiB ended on a signal and 1.25 MiB passed, so the leaf needs between 1.0
/// and 1.25 MiB beyond the call that starts it. The 2 MiB value leaves about
/// 0.75 MiB of margin. `renderToString` at its limit passed with a 1 MiB
/// headroom, so it needs less than the JSON leaf.
pub const headroom: usize = 2 * 1024 * 1024;

const Bounds = struct {
    /// Lowest address of the thread stack.
    low: usize,
    size: usize,
};

extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *anyopaque) c_int;
extern "c" fn pthread_attr_getstack(attr: *const anyopaque, addr: *?*anyopaque, size: *usize) c_int;

/// glibc `pthread_attr_t` is 56 bytes on x86_64 and 64 bytes on aarch64, and
/// `std.c.pthread_attr_t` is 56 on both. This buffer holds either.
const LinuxAttr = extern struct { bytes: [128]u8 align(16) };

fn bounds() ?Bounds {
    switch (builtin.os.tag) {
        .macos => {
            const self = std.c.pthread_self();
            const high = @intFromPtr(pthread_get_stackaddr_np(self) orelse return null);
            const size = pthread_get_stacksize_np(self);
            if (size == 0 or size > high) return null;
            return .{ .low = high - size, .size = size };
        },
        .linux => {
            if (!builtin.link_libc) return null;
            var attr: LinuxAttr = undefined;
            if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
            defer _ = std.c.pthread_attr_destroy(@ptrCast(&attr));
            var addr: ?*anyopaque = null;
            var size: usize = 0;
            if (pthread_attr_getstack(&attr, &addr, &size) != 0) return null;
            return .{ .low = @intFromPtr(addr orelse return null), .size = size };
        },
        else => return null,
    }
}

fn compute() usize {
    const found = bounds() orelse return 0;
    // A stack no larger than the headroom would refuse every call. Set no floor
    // and keep the call-frame limit as the only bound.
    if (found.size <= headroom) return 0;
    return found.low + headroom;
}

/// The floor is a property of the thread, so the bounds call runs once for each
/// thread. On Linux, `pthread_getattr_np` reads `/proc/self/maps` for the main
/// thread, which a call on every request would repeat.
threadlocal var thread_floor: ?usize = null;

/// The floor address for the calling thread, or 0 when the platform gives no
/// stack bounds or the stack is no larger than `headroom`. 0 means no floor.
pub fn floor() usize {
    if (thread_floor) |known| return known;
    const computed = compute();
    thread_floor = computed;
    return computed;
}
