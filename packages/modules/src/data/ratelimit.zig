//! zttp:ratelimit - In-memory rate limiting
//!
//! Exports:
//!   rateCheck(key: string, limit: number, windowSec: number) -> Result
//!     Fixed-window per-key counter. Returns
//!     { ok: true, value: { remaining, resetAt } } or
//!     { ok: false, error: { tag: "rate_exceeded", retryAfter } }.
//!
//!   rateReset(key: string) -> boolean
//!     Clears the counter for the given key. Returns true if present.

const std = @import("std");
const sdk = @import("zttp-sdk");
const state_limits = @import("../internal/state_limits.zig");

const MODULE_STATE_SLOT: usize = 8; // module_slots.Slot.ratelimit

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:ratelimit",
    .name = "ratelimit",
    .required_capabilities = &.{.clock},
    .stateful = true,
    .exports = &.{
        .{
            .name = "rateCheck",
            // rateCheckImpl reads sdk.nowMs for the window.
            .required_capabilities = &.{.clock},
            .module_func = rateCheckImpl,
            .arg_count = 3,
            .returns = .result,
            .param_types = &.{ .string, .number, .number },
            .param_names = &.{ "key", "limit", "windowSec" },
            .effect = .write,
            .failure_severity = .critical,
            .contract_extractions = &.{.{ .arg_position = 0, .category = .rate_limit_key }},
            .return_labels = .{ .internal = true },
        },
        .{
            .name = "rateReset",
            // store.reset removes a map entry. No window, no clock.
            .required_capabilities = &.{},
            .module_func = rateResetImpl,
            .arg_count = 1,
            .returns = .boolean,
            .param_types = &.{.string},
            .param_names = &.{"key"},
            .effect = .write,
        },
    },
};

const EVICT_INTERVAL: u32 = 256;

const RateEntry = struct {
    count: u32,
    window_start: i64,
    window_sec: i64,
};

pub const RateStore = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(RateEntry),
    max_entries: usize,
    total_key_bytes: usize,
    max_key_bytes: usize,
    check_count: u32 = 0,

    fn init(allocator: std.mem.Allocator) RateStore {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(RateEntry).init(allocator),
            .max_entries = state_limits.max_entries,
            .total_key_bytes = 0,
            .max_key_bytes = state_limits.max_bytes,
        };
    }

    fn deinitSelf(self: *RateStore) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    fn sdkDeinit(ptr: *anyopaque) callconv(.c) void {
        const store: *RateStore = @ptrCast(@alignCast(ptr));
        const allocator = store.allocator;
        store.deinitSelf();
        allocator.destroy(store);
    }

    fn evictExpired(self: *RateStore, now: i64) void {
        // Drain ALL expired keys this sweep. The old fixed 64-key cap let
        // expired entries accumulate faster than they were reclaimed under a
        // high-cardinality key space (e.g. per-IP limiting under an IP flood),
        // growing the map without bound. Collecting into a heap list (this runs
        // only every EVICT_INTERVAL checks) avoids mutating the map mid-iterate.
        var expired = std.ArrayList([]const u8).empty;
        defer expired.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (now >= entry.value_ptr.window_start +| entry.value_ptr.window_sec) {
                // Best-effort on OOM: remove whatever was collected so far.
                expired.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }

        for (expired.items) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.total_key_bytes -= removed.key.len;
                self.allocator.free(removed.key);
            }
        }
    }

    const CheckResult = struct { allowed: bool, remaining: u32, reset_at_ms: i64 };

    fn check(self: *RateStore, key: []const u8, limit: u32, window_sec: i64, now: i64) !CheckResult {
        self.check_count +%= 1;
        if (self.check_count % EVICT_INTERVAL == 0) {
            self.evictExpired(now);
        }

        if (self.entries.getPtr(key)) |entry| {
            // Saturating arithmetic: window_sec is lossyCast-saturated at the
            // caller and can be near maxInt(i64), so a plain +/* would overflow.
            const window_end = entry.window_start +| entry.window_sec;

            if (now >= window_end) {
                entry.count = 1;
                entry.window_start = now;
                entry.window_sec = window_sec;
                return .{
                    .allowed = true,
                    .remaining = if (limit > 1) limit - 1 else 0,
                    .reset_at_ms = (now +| window_sec) *| 1000,
                };
            }

            if (entry.count >= limit) {
                return .{
                    .allowed = false,
                    .remaining = 0,
                    .reset_at_ms = window_end *| 1000,
                };
            }

            entry.count += 1;
            return .{
                .allowed = true,
                .remaining = limit - entry.count,
                .reset_at_ms = window_end *| 1000,
            };
        }

        if (key.len > self.max_key_bytes) return error.RateStoreCapacityExceeded;

        if (self.entries.count() >= self.max_entries or
            self.total_key_bytes > self.max_key_bytes - key.len)
        {
            // A full store gets an immediate expiry sweep instead of waiting
            // for the periodic sweep. If every retained window is still live,
            // fail closed for a new key and keep the established key set.
            self.evictExpired(now);
            if (self.entries.count() >= self.max_entries or
                self.total_key_bytes > self.max_key_bytes - key.len)
            {
                return error.RateStoreCapacityExceeded;
            }
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.entries.put(owned_key, .{
            .count = 1,
            .window_start = now,
            .window_sec = window_sec,
        });
        self.total_key_bytes += owned_key.len;
        return .{
            .allowed = true,
            .remaining = if (limit > 1) limit - 1 else 0,
            .reset_at_ms = (now +| window_sec) *| 1000,
        };
    }

    fn reset(self: *RateStore, key: []const u8) bool {
        if (self.entries.fetchRemove(key)) |kv| {
            self.total_key_bytes -= kv.key.len;
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }
};

fn getOrCreateStore(handle: *sdk.ModuleHandle) !*RateStore {
    if (sdk.getModuleState(handle, RateStore, MODULE_STATE_SLOT)) |store| return store;
    const allocator = sdk.getAllocator(handle);
    const store = try allocator.create(RateStore);
    errdefer allocator.destroy(store);
    store.* = RateStore.init(allocator);
    try sdk.setModuleState(handle, MODULE_STATE_SLOT, @ptrCast(store), RateStore.sdkDeinit);
    return store;
}

fn rateCheckImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    if (args.len < 3) return sdk.JSValue.undefined_val;
    const key = sdk.extractString(args[0]) orelse return sdk.JSValue.undefined_val;
    const limit_i = sdk.extractInt(args[1]) orelse return sdk.JSValue.undefined_val;
    if (limit_i < 1) return sdk.JSValue.undefined_val;
    const limit: u32 = @intCast(limit_i);
    const window_f = sdk.extractFloat(args[2]) orelse return sdk.JSValue.undefined_val;
    // NaN < 1 is false, so guard non-finite explicitly before the cast; an
    // out-of-range @intFromFloat would otherwise be illegal behavior. lossyCast
    // saturates the in-range conversion.
    if (!std.math.isFinite(window_f) or window_f < 1) return sdk.JSValue.undefined_val;
    const window_sec: i64 = std.math.lossyCast(i64, window_f);

    const now_ms = sdk.nowMs(handle) catch return sdk.JSValue.undefined_val;
    const now_s = @divTrunc(now_ms, 1000);

    const store = getOrCreateStore(handle) catch return sdk.JSValue.undefined_val;
    const result = store.check(key, limit, window_sec, now_s) catch |err| return switch (err) {
        error.RateStoreCapacityExceeded => rateStoreCapacityResult(handle),
        error.OutOfMemory => sdk.JSValue.undefined_val,
    };

    if (result.allowed) {
        const val_obj = try sdk.createObject(handle);
        try sdk.objectSet(handle, val_obj, "remaining", sdk.JSValue.fromInt(@intCast(result.remaining)));
        try sdk.objectSet(handle, val_obj, "resetAt", sdk.numberFromF64(@floatFromInt(result.reset_at_ms)));
        return sdk.resultOk(handle, val_obj);
    }

    const err_obj = try sdk.createObject(handle);
    const tag_str = try sdk.createString(handle, "rate_exceeded");
    try sdk.objectSet(handle, err_obj, "tag", tag_str);

    const retry_after_ms = result.reset_at_ms - now_ms;
    const retry_sec = @divTrunc(@max(@as(i64, 0), retry_after_ms), 1000);
    try sdk.objectSet(handle, err_obj, "retryAfter", sdk.numberFromF64(@floatFromInt(retry_sec)));
    return sdk.resultErrValue(handle, err_obj);
}

fn rateStoreCapacityResult(handle: *sdk.ModuleHandle) !sdk.JSValue {
    const err_obj = try sdk.createObject(handle);
    const tag_str = try sdk.createString(handle, "rate_store_capacity");
    try sdk.objectSet(handle, err_obj, "tag", tag_str);
    return sdk.resultErrValue(handle, err_obj);
}

fn rateResetImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const key = (sdk.decodeArgs(&.{.string}, args) orelse return sdk.JSValue.false_val)[0];
    const store = getOrCreateStore(handle) catch return sdk.JSValue.false_val;
    return if (store.reset(key)) sdk.JSValue.true_val else sdk.JSValue.false_val;
}

test "RateStore: basic check" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();

    const r1 = try store.check("test-key", 3, 60, 1000);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 2), r1.remaining);

    const r2 = try store.check("test-key", 3, 60, 1001);
    try std.testing.expect(r2.allowed);
    try std.testing.expectEqual(@as(u32, 1), r2.remaining);

    const r3 = try store.check("test-key", 3, 60, 1002);
    try std.testing.expect(r3.allowed);
    try std.testing.expectEqual(@as(u32, 0), r3.remaining);

    const r4 = try store.check("test-key", 3, 60, 1003);
    try std.testing.expect(!r4.allowed);
}

test "RateStore: huge window_sec does not overflow reset_at_ms" {
    // window_sec is lossyCast-saturated at the caller and can approach
    // maxInt(i64); reset_at_ms = (now + window_sec) * 1000 must saturate, not
    // overflow-panic.
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();

    const r = try store.check("k", 5, std.math.maxInt(i64), 1000);
    try std.testing.expect(r.allowed);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), r.reset_at_ms);
}

test "RateStore: reset" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();

    _ = try store.check("test-key", 3, 60, 1000);
    try std.testing.expect(store.reset("test-key"));
    try std.testing.expect(!store.reset("nonexistent"));
}

test "RateStore: independent keys" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();

    const r1 = try store.check("key-a", 1, 60, 1000);
    try std.testing.expect(r1.allowed);

    const r2 = try store.check("key-b", 1, 60, 1000);
    try std.testing.expect(r2.allowed);

    const r3 = try store.check("key-a", 1, 60, 1001);
    try std.testing.expect(!r3.allowed);

    const r4 = try store.check("key-b", 1, 60, 1001);
    try std.testing.expect(!r4.allowed);
}

test "RateStore: capacity rejects a new live key" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();
    store.max_entries = 2;

    _ = try store.check("a", 1, 60, 1000);
    _ = try store.check("b", 1, 60, 1000);
    try std.testing.expectError(
        error.RateStoreCapacityExceeded,
        store.check("c", 1, 60, 1000),
    );
    try std.testing.expectEqual(@as(u32, 2), store.entries.count());
    try std.testing.expect(store.entries.contains("a"));
    try std.testing.expect(store.entries.contains("b"));
}

test "RateStore: capacity sweep admits a key after expiry" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();
    store.max_entries = 1;

    _ = try store.check("expired", 1, 1, 1000);
    try std.testing.expectEqual(@as(usize, "expired".len), store.total_key_bytes);
    _ = try store.check("replacement", 1, 60, 1001);

    try std.testing.expectEqual(@as(u32, 1), store.entries.count());
    try std.testing.expectEqual(@as(usize, "replacement".len), store.total_key_bytes);
    try std.testing.expect(!store.entries.contains("expired"));
    try std.testing.expect(store.entries.contains("replacement"));
}

test "RateStore: key byte capacity rejects a new live key" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();
    store.max_key_bytes = 3;

    _ = try store.check("ab", 1, 60, 1000);
    try std.testing.expectError(
        error.RateStoreCapacityExceeded,
        store.check("cd", 1, 60, 1000),
    );
    try std.testing.expectEqual(@as(usize, 2), store.total_key_bytes);
    try std.testing.expect(store.entries.contains("ab"));
    try std.testing.expect(!store.entries.contains("cd"));
}

test "RateStore: reset releases owned key bytes" {
    var store = RateStore.init(std.testing.allocator);
    defer store.deinitSelf();

    _ = try store.check("reset-me", 1, 60, 1000);
    try std.testing.expectEqual(@as(usize, "reset-me".len), store.total_key_bytes);
    try std.testing.expect(store.reset("reset-me"));
    try std.testing.expectEqual(@as(usize, 0), store.total_key_bytes);
}
