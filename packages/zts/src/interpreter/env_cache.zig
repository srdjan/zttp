//! Tiny thread-safe helpers for first-call-cached env var reads. Each helper
//! uses atomic cache cells so concurrent worker threads share cached reads
//! without data races.

const std = @import("std");

pub const BoolCache = struct {
    /// 0 = unset, 1 = false, 2 = true
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
};

pub fn UintCache(comptime T: type) type {
    return struct {
        /// 0 = unset, 1 = initialized
        state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
        value: std.atomic.Value(T) = std.atomic.Value(T).init(0),
    };
}

/// True if the env var is present (any value, including empty). Cached after
/// the first read.
pub inline fn cachedBoolPresent(name: [*:0]const u8, cache: *BoolCache) bool {
    const cur = cache.state.load(.acquire);
    if (cur != 0) return cur == 2;
    const present = std.c.getenv(name) != null;
    cache.state.store(if (present) 2 else 1, .release);
    return present;
}

/// Parse env var as an unsigned integer of type `T` with a fallback default.
/// Cached after the first read. A parse failure also yields `default`.
pub inline fn cachedUint(comptime T: type, name: [*:0]const u8, cache: *UintCache(T), default: T) T {
    if (cache.state.load(.acquire) != 0) return cache.value.load(.acquire);
    const result: T = blk: {
        const raw_ptr = std.c.getenv(name) orelse break :blk default;
        const raw = std.mem.sliceTo(raw_ptr, 0);
        break :blk std.fmt.parseUnsigned(T, raw, 10) catch default;
    };
    cache.value.store(result, .release);
    cache.state.store(1, .release);
    return result;
}

/// Like `cachedUint` but also treats a parsed `0` as "use default", for
/// flags where 0 is meaningless.
pub inline fn cachedUintNonzero(comptime T: type, name: [*:0]const u8, cache: *UintCache(T), default: T) T {
    if (cache.state.load(.acquire) != 0) return cache.value.load(.acquire);
    const result: T = blk: {
        const raw_ptr = std.c.getenv(name) orelse break :blk default;
        const raw = std.mem.sliceTo(raw_ptr, 0);
        const parsed = std.fmt.parseUnsigned(T, raw, 10) catch break :blk default;
        break :blk if (parsed == 0) default else parsed;
    };
    cache.value.store(result, .release);
    cache.state.store(1, .release);
    return result;
}
