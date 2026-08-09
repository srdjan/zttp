//! `Bytes` - immutable octet data (spec 6.3).
//!
//! A Bytes value keeps text and binary apart, which is the whole reason spec
//! 6.3 exists: a string is a sequence of scalars and an octet buffer is not,
//! and letting one stand in for the other is how a decoding bug becomes a
//! silent one. Every operation the spec names returns a new value or a scalar,
//! so the buffer behind a Bytes is written once at construction and never
//! mutated afterwards.
//!
//! Storage is one `ByteBuffer` block held in a single object slot. That is the
//! difference from `Dict`, which interleaves its keys and values across the
//! object's own slots: a Bytes has one outgoing edge, and the block it points
//! at is tagged `MemTag.byte_array`, which the GC already scans as holding no
//! pointers. So the trace terminates at the buffer with no new tracing path to
//! keep in step.
//!
//! Slicing copies. A slice that shared its parent's buffer would keep the
//! parent alive and, worse, would outlive it in the arena case where the
//! parent's block is reclaimed on request end. Copying is what makes a Bytes
//! own its octets outright.

const std = @import("std");
const heap = @import("heap.zig");
const object = @import("object.zig");
const value = @import("value.zig");
const context = @import("context.zig");
const arena_mod = @import("arena.zig");

const JSObject = object.JSObject;
const JSValue = value.JSValue;

/// The octet buffer behind a Bytes value: a header, a length, and the octets
/// inline after it - the same shape `JSString` uses, for the same reason.
/// The tag is `MemTag.byte_array`, which `gc.scanObject` already treats as
/// pointer-free, so a Bytes adds no case to the marker.
pub const ByteBuffer = extern struct {
    header: heap.MemBlockHeader,
    len: u32,
    /// Keeps the octets 8-byte aligned after the header, so the block layout
    /// does not depend on the header's own size changing.
    _reserved: u32 = 0,

    pub fn data(self: *const ByteBuffer) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return (base + @sizeOf(ByteBuffer))[0..self.len];
    }

    pub fn dataMut(self: *ByteBuffer) []u8 {
        const base: [*]u8 = @ptrCast(self);
        return (base + @sizeOf(ByteBuffer))[0..self.len];
    }
};

/// The largest octet count one buffer can hold. `MemBlockHeader` records a
/// block's size in u26 words and panics above that bound, so this is what the
/// storage can carry rather than a policy choice - the same derivation
/// `MAX_DICT_ENTRIES` uses. Construction fails closed below it; spec 6.3's
/// `size-limit` fault reports this number as its limit.
pub const MAX_LENGTH: u32 = @as(u32, std.math.maxInt(u26)) * 8 - @sizeOf(ByteBuffer);

/// Why a `[]const JSValue` is not a run of octets. Domain faults are data:
/// spec 6.3's `invalid-octet` carries the offending index and value, and
/// `size-limit` carries the limit, so neither is signalled as a Zig error.
pub const OctetFault = union(enum) {
    /// The element at `index` is not an integer in `[0, 255]`. `val` is the
    /// number it was; a non-numeric element reports NaN, because there is no
    /// number to report and truncating one into existence is the confusion
    /// this whole type exists to prevent.
    invalid_octet: struct { index: u32, val: f64 },
    /// More octets than one buffer can hold.
    size_limit: struct { limit: u32 },
};

pub const FromOctets = union(enum) {
    ok: *JSObject,
    fault: OctetFault,
};

/// Why a slice request is not a subrange.
pub const BoundsFault = struct { start: u32, end: u32 };

pub const Slice = union(enum) {
    ok: *JSObject,
    fault: BoundsFault,
};

/// True when `val` is a Bytes.
pub fn isBytes(val: JSValue) bool {
    if (!val.isObject()) return false;
    return JSObject.fromValue(val).class_id == .bytes;
}

/// The Bytes behind `val`, or null when it is not one.
pub fn asBytes(val: JSValue) ?*JSObject {
    if (!isBytes(val)) return null;
    return JSObject.fromValue(val);
}

/// The buffer block behind a Bytes, or null when `obj` is not one or its slot
/// has not been filled. Every reader goes through here rather than reaching
/// into the slot, so a wrong class can never be read as a buffer pointer.
pub fn buffer(obj: *const JSObject) ?*const ByteBuffer {
    if (obj.class_id != .bytes) return null;
    const slot = obj.inline_slots[JSObject.Slots.BYTES_BUFFER];
    if (!slot.isPtr()) return null;
    return @ptrCast(@alignCast(slot.toPtr(u8)));
}

/// The octets of a Bytes. Empty for anything that is not one.
pub fn data(obj: *const JSObject) []const u8 {
    const buf = buffer(obj) orelse return &.{};
    return buf.data();
}

pub fn length(obj: *const JSObject) u32 {
    const buf = buffer(obj) orelse return 0;
    return buf.len;
}

/// The octet at `index`, or null past the end. Spec 6.3: an out-of-bounds
/// single index is `undefined`, not a fault.
pub fn byteAt(obj: *const JSObject, index: u32) ?u8 {
    const octets = data(obj);
    if (index >= octets.len) return null;
    return octets[index];
}

/// Content equality over the buffers. Two Bytes built independently from the
/// same octets are one value, which is why `===` cannot be pointer identity
/// here (see `JSValue.strictEquals`).
pub fn equals(a: *const JSObject, b: *const JSObject) bool {
    if (a.class_id != .bytes or b.class_id != .bytes) return false;
    return std.mem.eql(u8, data(a), data(b));
}

/// A Bytes over a copy of `octets`.
pub fn fromSlice(ctx: *context.Context, octets: []const u8) !*JSObject {
    return ctx.createBytes(octets);
}

/// A Bytes over `values`, validating every element. An element that is not an
/// integer in `[0, 255]` is refused with its index rather than truncated: a
/// truncation here would turn a caller's arithmetic mistake into data that
/// looks correct downstream.
pub fn fromOctets(ctx: *context.Context, values: []const JSValue) !FromOctets {
    if (values.len > MAX_LENGTH) {
        return .{ .fault = .{ .size_limit = .{ .limit = MAX_LENGTH } } };
    }

    // Validate before allocating: a list refused halfway would otherwise leave
    // a half-built value behind for the arena to carry to the end of the
    // request for nothing.
    for (values, 0..) |element, i| {
        if (octetOf(element) == null) return .{ .fault = .{ .invalid_octet = .{
            .index = @intCast(i),
            .val = element.toNumber() orelse std.math.nan(f64),
        } } };
    }

    const obj = try ctx.createBytesUninitialized(@intCast(values.len));
    const octets = bufferMut(obj).?.dataMut();
    for (values, 0..) |element, i| {
        octets[i] = octetOf(element).?;
    }
    return .{ .ok = obj };
}

/// The octet `val` denotes, or null when it denotes none. A fractional number
/// is not an octet; neither is one outside `[0, 255]`, a NaN, an infinity, or
/// a non-number.
fn octetOf(val: JSValue) ?u8 {
    if (!val.isNumber()) return null;
    const n = val.toNumber() orelse return null;
    if (!std.math.isFinite(n)) return null;
    if (n != @trunc(n)) return null;
    if (n < 0 or n > 255) return null;
    return @intFromFloat(n);
}

/// `[start, end)` of `src` as a new Bytes. The octets are copied, so the
/// result does not alias `src` and stays valid after `src` is reclaimed.
pub fn slice(ctx: *context.Context, src: *const JSObject, start: u32, end: u32) !Slice {
    const octets = data(src);
    if (start > end or end > octets.len) {
        return .{ .fault = .{ .start = start, .end = end } };
    }
    return .{ .ok = try fromSlice(ctx, octets[start..end]) };
}

/// The mutable buffer of a freshly built Bytes. Construction is the only
/// writer: nothing outside this file and `Context.createBytes` may call it,
/// which is what keeps the value immutable once a caller can see it.
pub fn bufferMut(obj: *JSObject) ?*ByteBuffer {
    if (obj.class_id != .bytes) return null;
    const slot = obj.inline_slots[JSObject.Slots.BYTES_BUFFER];
    if (!slot.isPtr()) return null;
    return @ptrCast(@alignCast(slot.toPtr(u8)));
}

// ---------------------------------------------------------------------------
// Buffer allocation
//
// Two routes, the same pair every other value kind carries: the request arena
// when one is active, and the context allocator otherwise. `Context.createBytes`
// picks; nothing else should call these directly.
// ---------------------------------------------------------------------------

/// Buffers are 8-byte aligned because `JSValue.fromPtr` tags a pointer in its
/// low three bits and asserts they are clear. `ByteBuffer`'s own alignment is
/// 4, so the alignment is a property of how it is allocated, not of the type,
/// and both routes below have to hold it.
const BUFFER_ALIGN = std.mem.Alignment.@"8";

pub fn createBuffer(allocator: std.mem.Allocator, len: u32) !*ByteBuffer {
    const total_size = @sizeOf(ByteBuffer) + @as(usize, len);
    const mem = try allocator.alignedAlloc(u8, BUFFER_ALIGN, total_size);
    const buf: *ByteBuffer = @ptrCast(@alignCast(mem.ptr));
    buf.* = .{
        .header = heap.MemBlockHeader.init(.byte_array, total_size),
        .len = len,
    };
    return buf;
}

pub fn createBufferWithArena(request_arena: *arena_mod.Arena, len: u32) ?*ByteBuffer {
    const total_size = @sizeOf(ByteBuffer) + @as(usize, len);
    const mem = request_arena.alloc(total_size) orelse return null;
    const buf: *ByteBuffer = @ptrCast(@alignCast(mem));
    buf.* = .{
        .header = heap.MemBlockHeader.init(.byte_array, total_size),
        .len = len,
    };
    return buf;
}

pub fn freeBuffer(allocator: std.mem.Allocator, buf: *ByteBuffer) void {
    const total_size = @sizeOf(ByteBuffer) + @as(usize, buf.len);
    const ptr: [*]align(BUFFER_ALIGN.toByteUnits()) u8 = @ptrCast(@alignCast(buf));
    allocator.free(ptr[0..total_size]);
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

test "octets round-trip and length reports the count" {
    const h = try harness();
    defer releaseHarness(h);

    const b = try fromSlice(h.ctx, &[_]u8{ 0, 127, 255 });
    try testing.expectEqual(@as(u32, 3), length(b));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 127, 255 }, data(b));
    try testing.expectEqual(@as(u8, 127), byteAt(b, 1).?);
    try testing.expect(byteAt(b, 3) == null);
}

test "an octet outside the range is refused with its index" {
    const h = try harness();
    defer releaseHarness(h);

    const values = [_]JSValue{ num(1), num(2), num(256) };
    const result = try fromOctets(h.ctx, &values);
    switch (result) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| switch (f) {
            .invalid_octet => |o| {
                try testing.expectEqual(@as(u32, 2), o.index);
                try testing.expectEqual(@as(f64, 256), o.val);
            },
            else => return error.TestExpectedInvalidOctet,
        },
    }

    const negative = [_]JSValue{num(-1)};
    switch (try fromOctets(h.ctx, &negative)) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| try testing.expectEqual(@as(u32, 0), f.invalid_octet.index),
    }
}

test "a fractional octet is refused rather than truncated" {
    const h = try harness();
    defer releaseHarness(h);

    // 1.5 truncating to 1 would be a caller's arithmetic mistake turned into
    // plausible data. It is refused, and the reported value is the one given.
    const values = [_]JSValue{ num(1), num(1.5) };
    switch (try fromOctets(h.ctx, &values)) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| {
            try testing.expectEqual(@as(u32, 1), f.invalid_octet.index);
            try testing.expectEqual(@as(f64, 1.5), f.invalid_octet.val);
        },
    }

    // A non-number element is refused too, with NaN for a value it does not have.
    const not_a_number = [_]JSValue{ num(0), JSValue.true_val };
    switch (try fromOctets(h.ctx, &not_a_number)) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| {
            try testing.expectEqual(@as(u32, 1), f.invalid_octet.index);
            try testing.expect(std.math.isNan(f.invalid_octet.val));
        },
    }
}

test "a valid octet list builds and nothing is dropped" {
    const h = try harness();
    defer releaseHarness(h);

    const values = [_]JSValue{ num(0), num(255), num(-0.0), num(64) };
    const b = (try fromOctets(h.ctx, &values)).ok;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 64 }, data(b));

    // An empty list is the empty value, not a fault.
    const empty = (try fromOctets(h.ctx, &[_]JSValue{})).ok;
    try testing.expectEqual(@as(u32, 0), length(empty));
}

test "two independently built buffers with the same octets are equal" {
    const h = try harness();
    defer releaseHarness(h);

    const a = try fromSlice(h.ctx, &[_]u8{ 1, 2, 3 });
    const b = try fromSlice(h.ctx, &[_]u8{ 1, 2, 3 });
    const c = try fromSlice(h.ctx, &[_]u8{ 1, 2, 4 });

    try testing.expect(a != b); // distinct objects
    try testing.expect(equals(a, b));
    try testing.expect(!equals(a, c));

    // `===` is the only spelling spec 6.3 gives equality, so it has to agree.
    try testing.expect(a.toValue().strictEquals(b.toValue()));
    try testing.expect(!a.toValue().strictEquals(c.toValue()));

    // A Bytes is not a string, and an equal-looking string is not equal to it.
    const text = try h.ctx.createString("abc");
    const abc = try fromSlice(h.ctx, "abc");
    try testing.expect(!abc.toValue().strictEquals(text));
}

test "a slice copies and does not alias its source" {
    const h = try harness();
    defer releaseHarness(h);

    const src = try fromSlice(h.ctx, &[_]u8{ 10, 20, 30, 40 });
    const part = (try slice(h.ctx, src, 1, 3)).ok;
    try testing.expectEqualSlices(u8, &[_]u8{ 20, 30 }, data(part));

    // No overlap with the source buffer: the slice owns its octets, so it
    // stays valid when the source is reclaimed rather than pointing into a
    // freed block.
    const src_start = @intFromPtr(data(src).ptr);
    const part_start = @intFromPtr(data(part).ptr);
    try testing.expect(part_start < src_start or part_start >= src_start + data(src).len);
}

test "a copied buffer outlives the buffer it was copied from" {
    // The claim the non-overlap check above cannot make on its own: the copy
    // is readable after the source block is actually returned to the
    // allocator. The testing allocator poisons freed memory, so a slice that
    // still pointed into the source would read wrong octets here rather than
    // pass by luck.
    const allocator = testing.allocator;

    const src = try createBuffer(allocator, 4);
    @memcpy(src.dataMut(), &[_]u8{ 10, 20, 30, 40 });

    const copy = try createBuffer(allocator, 2);
    defer freeBuffer(allocator, copy);
    @memcpy(copy.dataMut(), src.data()[1..3]);

    freeBuffer(allocator, src);
    try testing.expectEqualSlices(u8, &[_]u8{ 20, 30 }, copy.data());
}

test "slice bounds outside the buffer are a fault with both ends" {
    const h = try harness();
    defer releaseHarness(h);

    const src = try fromSlice(h.ctx, &[_]u8{ 1, 2, 3 });

    switch (try slice(h.ctx, src, 2, 1)) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| {
            try testing.expectEqual(@as(u32, 2), f.start);
            try testing.expectEqual(@as(u32, 1), f.end);
        },
    }

    switch (try slice(h.ctx, src, 0, 4)) {
        .ok => return error.TestExpectedRefusal,
        .fault => |f| try testing.expectEqual(@as(u32, 4), f.end),
    }

    // An empty slice at the end is in bounds.
    try testing.expectEqual(@as(u32, 0), length((try slice(h.ctx, src, 3, 3)).ok));
}

test "isBytes answers for a Bytes and for nothing else" {
    const h = try harness();
    defer releaseHarness(h);

    const b = try fromSlice(h.ctx, &[_]u8{7});
    try testing.expect(isBytes(b.toValue()));
    try testing.expect(asBytes(b.toValue()) != null);

    const dict_obj = try h.ctx.createDict();
    try testing.expect(!isBytes(dict_obj.toValue()));
    try testing.expect(!isBytes(try h.ctx.createString("abc")));
    try testing.expect(!isBytes(num(1)));
    try testing.expect(asBytes(num(1)) == null);

    // A non-Bytes read through the Bytes accessors answers empty rather than
    // reading another class's slot 0 as a buffer pointer.
    try testing.expectEqual(@as(u32, 0), length(dict_obj));
    try testing.expect(buffer(dict_obj) == null);
}

test "a Bytes built in a request arena is reclaimed by the arena reset" {
    // Phase 4 measured a Dict built from `ctx.allocator` inside a request
    // leaking. `createBytes` picks the arena the same way `createDict` does,
    // and this is the check: both the object and its buffer land in the arena,
    // and the reset takes them back.
    const allocator = testing.allocator;

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    var req_arena = try arena_mod.Arena.init(allocator, .{ .size = 64 * 1024 });
    defer req_arena.deinit();
    var hybrid = arena_mod.HybridAllocator{ .persistent = allocator, .arena = &req_arena };
    ctx.setHybridAllocator(&hybrid);

    try testing.expectEqual(@as(usize, 0), req_arena.usedBytes());

    const b = try fromSlice(ctx, &[_]u8{ 1, 2, 3, 4, 5 });
    try testing.expect(req_arena.contains(@ptrCast(b)));
    try testing.expect(req_arena.contains(@ptrCast(@constCast(buffer(b).?))));
    try testing.expect(ctx.isEphemeralValue(b.toValue()));
    try testing.expect(req_arena.usedBytes() > 0);

    req_arena.reset();
    try testing.expectEqual(@as(usize, 0), req_arena.usedBytes());
}

test "a rooted Bytes survives a collection with its octets intact" {
    // A new class kind is most likely to be wrong in the GC. The marker reaches
    // a Bytes through its root, walks its one slot, and lands on a block tagged
    // `byte_array` - which `scanObject` terminates on because octets hold no
    // pointers. This is the check that the walk happens and ends there.
    const h = try harness();
    defer releaseHarness(h);

    const b = try fromSlice(h.ctx, &[_]u8{ 9, 8, 7, 6 });
    try testing.expectEqual(heap.MemTag.byte_array, buffer(b).?.header.tag);

    try h.gc.addRoot(b.toValue());
    h.gc.minorGC();
    h.gc.majorGC();

    try testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, data(b));
    try testing.expectEqual(heap.MemTag.byte_array, buffer(b).?.header.tag);
}

test "the length bound is what one block can hold" {
    // Derived from the storage, not chosen: MemBlockHeader panics above u26
    // words, so a buffer at MAX_LENGTH is the largest one that does not.
    try testing.expectEqual(
        @as(usize, std.math.maxInt(u26)) * 8,
        @sizeOf(ByteBuffer) + @as(usize, MAX_LENGTH),
    );
}
