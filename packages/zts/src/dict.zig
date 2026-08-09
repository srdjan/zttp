//! `Dict<K, V>` - immutable keyed data with deterministic iteration (spec 6.2).
//!
//! A Dict holds its entries in insertion order and answers key equality with
//! SameValueZero on numbers and scalar-sequence equality on strings. Every
//! operation that changes a Dict returns a new one; nothing here mutates a
//! Dict a caller can still see, which is what lets a Dict be shared across a
//! request without a copy at the boundary.
//!
//! Storage lives in the object's own slots (see `JSObject.Slots.DICT_COUNT`),
//! so the GC traces a Dict's keys and values through the same walk it already
//! runs over every object. Lookup is a linear scan of that order. That is the
//! honest first implementation: an index would need a side allocation the GC
//! does not trace today, and no measurement yet says the scan is the cost.

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const context = @import("context.zig");

const JSObject = object.JSObject;
const JSValue = value.JSValue;

pub const MAX_ENTRIES = JSObject.MAX_DICT_ENTRIES;

/// True when `val` is a Dict.
pub fn isDict(val: JSValue) bool {
    if (!val.isObject()) return false;
    return JSObject.fromValue(val).class_id == .dict;
}

/// The Dict behind `val`, or null when it is not one.
pub fn asDict(val: JSValue) ?*JSObject {
    if (!isDict(val)) return null;
    return JSObject.fromValue(val);
}

/// Key equality, SameValueZero (spec 6.2). It differs from `===` in exactly
/// one place: `NaN` equals `NaN`, so a key that was stored can be found again.
/// Negative zero equals positive zero, which `===` already gives.
pub fn sameValueZero(a: JSValue, b: JSValue) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.toNumber() orelse return false;
        const y = b.toNumber() orelse return false;
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        return x == y;
    }
    return a.strictEquals(b);
}

/// The position of `key`, or null when the Dict does not hold it.
pub fn indexOf(dict: *const JSObject, key: JSValue) ?u32 {
    const total = dict.getDictCount();
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        if (sameValueZero(dict.getDictKey(i), key)) return i;
    }
    return null;
}

pub fn count(dict: *const JSObject) u32 {
    return dict.getDictCount();
}

pub fn get(dict: *const JSObject, key: JSValue) JSValue {
    const idx = indexOf(dict, key) orelse return JSValue.undefined_val;
    return dict.getDictValue(idx);
}

pub fn has(dict: *const JSObject, key: JSValue) bool {
    return indexOf(dict, key) != null;
}

pub fn keyAt(dict: *const JSObject, index: u32) JSValue {
    return dict.getDictKey(index);
}

pub fn valueAt(dict: *const JSObject, index: u32) JSValue {
    return dict.getDictValue(index);
}

/// A Dict with no entries.
pub fn empty(ctx: *context.Context) !*JSObject {
    const dict = try JSObject.createDict(ctx.allocator, ctx.root_class_idx);
    dict.prototype = null;
    return dict;
}

/// `dict` with `key` bound to `val`, as a new Dict. An existing key keeps its
/// position - spec 6.2: updating a present key does not move it - and a new
/// key is appended, so iteration order is insertion order of the current value.
pub fn set(ctx: *context.Context, dict: *const JSObject, key: JSValue, val: JSValue) !*JSObject {
    const existing = indexOf(dict, key);
    const old_count = dict.getDictCount();
    const new_count = if (existing == null) old_count + 1 else old_count;
    if (new_count > MAX_ENTRIES) return error.OutOfMemory;

    const out = try JSObject.createDict(ctx.allocator, ctx.root_class_idx);
    var i: u32 = 0;
    while (i < old_count) : (i += 1) {
        const entry_key = dict.getDictKey(i);
        const entry_val = if (existing != null and existing.? == i) val else dict.getDictValue(i);
        try out.setDictEntry(ctx.allocator, i, entry_key, entry_val);
    }
    if (existing == null) {
        try out.setDictEntry(ctx.allocator, old_count, key, val);
    }
    out.setDictCount(new_count);
    return out;
}

/// `dict` without `key`, as a new Dict. Removing a key the Dict does not hold
/// returns an equal Dict rather than an error: `dictRemove` is total.
pub fn remove(ctx: *context.Context, dict: *const JSObject, key: JSValue) !*JSObject {
    const old_count = dict.getDictCount();
    const out = try JSObject.createDict(ctx.allocator, ctx.root_class_idx);
    var written: u32 = 0;
    var i: u32 = 0;
    while (i < old_count) : (i += 1) {
        const entry_key = dict.getDictKey(i);
        if (sameValueZero(entry_key, key)) continue;
        try out.setDictEntry(ctx.allocator, written, entry_key, dict.getDictValue(i));
        written += 1;
    }
    out.setDictCount(written);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gc_mod = @import("gc.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    gc: gc_mod.GC,
    ctx: *context.Context,

    fn deinit(self: *Harness) void {
        self.ctx.deinit();
        self.gc.deinit();
        self.arena.deinit();
    }
};

fn harness() !*Harness {
    const h = try testing.allocator.create(Harness);
    h.arena = std.heap.ArenaAllocator.init(testing.allocator);
    const allocator = h.arena.allocator();
    h.gc = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    h.ctx = try context.Context.init(allocator, &h.gc, .{});
    return h;
}

fn releaseHarness(h: *Harness) void {
    h.deinit();
    testing.allocator.destroy(h);
}

fn num(n: f64) JSValue {
    return JSValue.fromFloat(n);
}

test "a Dict iterates in insertion order" {
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    d = try set(h.ctx, d, num(3), num(30));
    d = try set(h.ctx, d, num(1), num(10));
    d = try set(h.ctx, d, num(2), num(20));

    try testing.expectEqual(@as(u32, 3), count(d));
    try testing.expectEqual(@as(f64, 3), keyAt(d, 0).toNumber().?);
    try testing.expectEqual(@as(f64, 1), keyAt(d, 1).toNumber().?);
    try testing.expectEqual(@as(f64, 2), keyAt(d, 2).toNumber().?);
}

test "updating a present key does not move it" {
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    d = try set(h.ctx, d, num(1), num(10));
    d = try set(h.ctx, d, num(2), num(20));
    d = try set(h.ctx, d, num(1), num(99));

    try testing.expectEqual(@as(u32, 2), count(d));
    try testing.expectEqual(@as(f64, 1), keyAt(d, 0).toNumber().?);
    try testing.expectEqual(@as(f64, 99), valueAt(d, 0).toNumber().?);
    try testing.expectEqual(@as(f64, 2), keyAt(d, 1).toNumber().?);
}

test "set returns a new Dict and leaves the old one alone" {
    const h = try harness();
    defer releaseHarness(h);

    const base = try empty(h.ctx);
    const one = try set(h.ctx, base, num(1), num(10));
    const two = try set(h.ctx, one, num(2), num(20));

    try testing.expectEqual(@as(u32, 0), count(base));
    try testing.expectEqual(@as(u32, 1), count(one));
    try testing.expectEqual(@as(u32, 2), count(two));
}

test "NaN finds its own key and negative zero is positive zero" {
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    d = try set(h.ctx, d, num(std.math.nan(f64)), num(1));
    d = try set(h.ctx, d, num(-0.0), num(2));

    // SameValueZero, not `===`: a NaN key is findable, which is the whole
    // reason the Dict does not just call strictEquals.
    try testing.expectEqual(@as(f64, 1), get(d, num(std.math.nan(f64))).toNumber().?);
    try testing.expect(has(d, num(std.math.nan(f64))));

    // -0 and +0 are one key, so the second write updated the first rather than
    // appending: two writes, two entries, and +0 reads what -0 stored.
    try testing.expectEqual(@as(u32, 2), count(d));
    try testing.expectEqual(@as(f64, 2), get(d, num(0.0)).toNumber().?);

    d = try set(h.ctx, d, num(0.0), num(3));
    try testing.expectEqual(@as(u32, 2), count(d));
    try testing.expectEqual(@as(f64, 3), get(d, num(-0.0)).toNumber().?);
}

test "remove drops one key and keeps the order of the rest" {
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    d = try set(h.ctx, d, num(1), num(10));
    d = try set(h.ctx, d, num(2), num(20));
    d = try set(h.ctx, d, num(3), num(30));

    const without = try remove(h.ctx, d, num(2));
    try testing.expectEqual(@as(u32, 2), count(without));
    try testing.expectEqual(@as(f64, 1), keyAt(without, 0).toNumber().?);
    try testing.expectEqual(@as(f64, 3), keyAt(without, 1).toNumber().?);

    // Removing an absent key is total, and the original is untouched.
    const same = try remove(h.ctx, without, num(99));
    try testing.expectEqual(@as(u32, 2), count(same));
    try testing.expectEqual(@as(u32, 3), count(d));
}

test "a missing key reads undefined rather than failing" {
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    d = try set(h.ctx, d, num(1), num(10));

    try testing.expect(get(d, num(2)).isUndefined());
    try testing.expect(!has(d, num(2)));
}

test "entries past the inline slots are stored and read back" {
    // Eight inline slots hold the count and three entries; everything after
    // that lives in the overflow backing, which is the path a wrong slot index
    // would corrupt silently.
    const h = try harness();
    defer releaseHarness(h);

    var d = try empty(h.ctx);
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        d = try set(h.ctx, d, num(@floatFromInt(i)), num(@floatFromInt(i * 2)));
    }

    try testing.expectEqual(@as(u32, 40), count(d));
    i = 0;
    while (i < 40) : (i += 1) {
        try testing.expectEqual(@as(f64, @floatFromInt(i)), keyAt(d, i).toNumber().?);
        try testing.expectEqual(@as(f64, @floatFromInt(i * 2)), get(d, num(@floatFromInt(i))).toNumber().?);
    }
}
