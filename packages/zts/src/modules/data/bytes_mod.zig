//! zttp:bytes - the pure operations over `Bytes` (spec 6.3).
//!
//! Zero capabilities and no state: every export reads its arguments and
//! returns a new value or a scalar. A Bytes is immutable, so nothing here can
//! change a value a caller still holds.
//!
//! The module lives on this side of the package boundary rather than in
//! `packages/modules/src/` for the reason `zttp:collections` records: minting a
//! Bytes needs `Context.createBytes`, and the SDK cannot mint a class.
//!
//! Five exports are fallible, and they are the five spec 6.3 marks:
//! construction from arbitrary numbers, a slice with caller-supplied bounds,
//! a concatenation that can outgrow one buffer, and the two decoders. An
//! infallible operation that returned a `Result` would cost every call site a
//! guard for a branch that cannot be taken, so `bytesLength`, `byteAt`,
//! `encodeUtf8`, and `encodeBase64` hand back their answer directly - and an
//! out-of-range single index is `undefined` rather than an error, which is the
//! spec's own distinction.

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const object = @import("../../object.zig");
const bytes = @import("../../bytes.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");
const helpers = @import("../../builtins/helpers.zig");

const JSValue = value.JSValue;
const JSObject = object.JSObject;

// Every export is `replay_pure`, audited rather than inferred: each reads only
// its arguments, with no host or non-deterministic state, so running one live
// during replay is hermetic. Without the opt-in the handler-test runner would
// install a stub returning `undefined` for all nine, and there is no I/O here
// to have recorded instead.
//
// Every export but `bytesLength` carries `derives_from_args`. The line is the
// one `FunctionBinding.derives_from_args` documents: a result that is data
// *from* the argument keeps the argument's labels, and a result that is a fact
// *about* it does not. A length is a count, like `dictHas`'s presence boolean.
// `byteAt` is on the other side of that line and the plan had it wrong: one
// octet of a secret is eight bits of the secret, and a loop over the indices
// reconstructs the whole of it, so it derives.
pub const binding = mb.ModuleBinding{
    .specifier = "zttp:bytes",
    .name = "bytes",
    .required_capabilities = &.{},
    .exports = &.{
        .{ .name = "bytesFromOctets", .func = bytesFromOctetsNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.object}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "bytesLength", .func = bytesLengthNative, .arg_count = 1, .effect = .none, .returns = .number, .param_types = &.{.bytes}, .laws = &.{.pure}, .replay_pure = true },
        .{ .name = "byteAt", .func = byteAtNative, .arg_count = 2, .effect = .none, .returns = .optional_number, .param_types = &.{ .bytes, .number }, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "sliceBytes", .func = sliceBytesNative, .arg_count = 3, .effect = .none, .returns = .result, .param_types = &.{ .bytes, .number, .number }, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "concatBytes", .func = concatBytesNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.object}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "encodeUtf8", .func = encodeUtf8Native, .arg_count = 1, .effect = .none, .returns = .bytes, .param_types = &.{.string}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "decodeUtf8", .func = decodeUtf8Native, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.bytes}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "decodeBase64", .func = decodeBase64Native, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.string}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "encodeBase64", .func = encodeBase64Native, .arg_count = 1, .effect = .none, .returns = .string, .param_types = &.{.bytes}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
    },
};

pub const exports = binding.toModuleExports();

// ---------------------------------------------------------------------------
// The error taxonomy of spec 6.3
// ---------------------------------------------------------------------------

/// Closed: every failure of every export is one of these four, so a caller
/// matching on `kind` covers a finite set.
pub const ErrorKind = enum {
    invalid_octet,
    invalid_encoding,
    invalid_bounds,
    size_limit,

    fn wire(self: ErrorKind) []const u8 {
        return switch (self) {
            .invalid_octet => "invalid-octet",
            .invalid_encoding => "invalid-encoding",
            .invalid_bounds => "invalid-bounds",
            .size_limit => "size-limit",
        };
    }
};

/// The fields each kind carries, and no others. `index`, `start`, `end`, and
/// `val` are `f64` rather than integers because they report what the caller
/// passed: a start of `-1` or `1.5` is reported as written rather than
/// coerced into a shape that hides the mistake.
pub const Failure = struct {
    kind: ErrorKind,
    index: f64 = 0,
    val: f64 = 0,
    encoding: []const u8 = "",
    offset: usize = 0,
    start: f64 = 0,
    end: f64 = 0,
    limit: u32 = 0,
};

/// Build `{ kind, ... }` and wrap it as the error arm of a `Result`.
fn failure(ctx: *context.Context, f: Failure) JSValue {
    const pool = ctx.hidden_class_pool orelse return helpers.createResultErr(ctx, JSValue.undefined_val);
    const obj = ctx.createObject(null) catch return helpers.createResultErr(ctx, JSValue.undefined_val);

    setText(ctx, pool, obj, "kind", f.kind.wire()) catch
        return helpers.createResultErr(ctx, JSValue.undefined_val);

    switch (f.kind) {
        .invalid_octet => {
            setNumber(ctx, pool, obj, "index", f.index) catch {};
            setNumber(ctx, pool, obj, "value", f.val) catch {};
        },
        .invalid_encoding => {
            setText(ctx, pool, obj, "encoding", f.encoding) catch {};
            setNumber(ctx, pool, obj, "offset", @floatFromInt(f.offset)) catch {};
        },
        .invalid_bounds => {
            setNumber(ctx, pool, obj, "start", f.start) catch {};
            setNumber(ctx, pool, obj, "end", f.end) catch {};
        },
        .size_limit => {
            setNumber(ctx, pool, obj, "limit", @floatFromInt(f.limit)) catch {};
        },
    }
    return helpers.createResultErr(ctx, JSValue.fromPtr(obj));
}

fn setText(ctx: *context.Context, pool: *object.HiddenClassPool, obj: *JSObject, name: []const u8, text: []const u8) !void {
    const atom = try ctx.atoms.intern(name);
    const str = try ctx.createString(text);
    try obj.setProperty(ctx.allocator, pool, atom, str);
}

fn setNumber(ctx: *context.Context, pool: *object.HiddenClassPool, obj: *JSObject, name: []const u8, n: f64) !void {
    const atom = try ctx.atoms.intern(name);
    try obj.setProperty(ctx.allocator, pool, atom, helpers.allocFloat(ctx, n));
}

// ---------------------------------------------------------------------------
// Argument readers
// ---------------------------------------------------------------------------

fn bytesArg(args: []const JSValue, index: usize) ?*JSObject {
    if (args.len <= index) return null;
    return bytes.asBytes(args[index]);
}

/// The array behind an argument, or null when it is not one. Both list-taking
/// exports go through here, so a non-array argument is refused the same way in
/// both rather than read as a zero-length list.
fn arrayArg(args: []const JSValue, index: usize) ?*JSObject {
    if (args.len <= index) return null;
    if (!args[index].isObject()) return null;
    const obj = JSObject.fromValue(args[index]);
    if (obj.class_id != .array) return null;
    return obj;
}

fn numberArg(args: []const JSValue, index: usize) ?f64 {
    if (args.len <= index) return null;
    if (!args[index].isNumber()) return null;
    return args[index].toNumber();
}

/// `n` as an index into a buffer, or null when it names no position: a
/// fraction, a negative, a non-finite, or a value past `u32`.
fn asIndex(n: f64) ?u32 {
    if (!std.math.isFinite(n)) return null;
    if (n != @trunc(n)) return null;
    if (n < 0 or n > std.math.maxInt(u32)) return null;
    return @intFromFloat(n);
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

/// `bytesFromOctets(values)`: every element is validated before anything is
/// allocated, and an element that is not an integer in `[0, 255]` is refused
/// with its index and its value rather than truncated.
fn bytesFromOctetsNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const list = arrayArg(args, 0) orelse
        return failure(ctx, .{ .kind = .invalid_octet, .index = 0, .val = std.math.nan(f64) });

    const len = list.getArrayLength();
    if (len > bytes.MAX_LENGTH) {
        return failure(ctx, .{ .kind = .size_limit, .limit = bytes.MAX_LENGTH });
    }

    const elements = try ctx.allocator.alloc(JSValue, len);
    defer ctx.allocator.free(elements);
    for (elements, 0..) |*slot, i| slot.* = list.getSlot(@intCast(i + 1));

    return switch (try bytes.fromOctets(ctx, elements)) {
        .ok => |obj| helpers.createResultOk(ctx, JSValue.fromPtr(obj)),
        .fault => |f| switch (f) {
            .invalid_octet => |o| failure(ctx, .{
                .kind = .invalid_octet,
                .index = @floatFromInt(o.index),
                .val = o.val,
            }),
            .size_limit => |s| failure(ctx, .{ .kind = .size_limit, .limit = s.limit }),
        },
    };
}

fn bytesLengthNative(_: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const b = bytesArg(args, 0) orelse return JSValue.fromInt(0);
    return JSValue.fromInt(@intCast(bytes.length(b)));
}

/// `byteAt(value, index)`: out of range is `undefined`, not a fault (spec 6.3).
/// A fractional or negative index names no position either, so it answers the
/// same way.
fn byteAtNative(_: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const b = bytesArg(args, 0) orelse return JSValue.undefined_val;
    const raw = numberArg(args, 1) orelse return JSValue.undefined_val;
    const index = asIndex(raw) orelse return JSValue.undefined_val;
    const octet = bytes.byteAt(b, index) orelse return JSValue.undefined_val;
    return JSValue.fromInt(octet);
}

/// `sliceBytes(value, start, end)`: `[start, end)`, copied. Bounds are checked
/// against the buffer and reported as the caller wrote them.
fn sliceBytesNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const raw_start = numberArg(args, 1) orelse std.math.nan(f64);
    const raw_end = numberArg(args, 2) orelse std.math.nan(f64);
    const bounds = Failure{ .kind = .invalid_bounds, .start = raw_start, .end = raw_end };

    const b = bytesArg(args, 0) orelse return failure(ctx, bounds);
    const start = asIndex(raw_start) orelse return failure(ctx, bounds);
    const end = asIndex(raw_end) orelse return failure(ctx, bounds);

    return switch (try bytes.slice(ctx, b, start, end)) {
        .ok => |obj| helpers.createResultOk(ctx, JSValue.fromPtr(obj)),
        .fault => failure(ctx, bounds),
    };
}

/// `concatBytes(values)`: the joined buffer, or `size-limit` when the total
/// exceeds what one buffer holds.
///
/// An element that is not a Bytes cannot arrive through a checked handler -
/// the declared parameter is a list of Bytes - so reaching it means the static
/// type was bypassed. It is refused rather than skipped, and `invalid-octet`
/// with the element's index is the member of this closed taxonomy that points
/// at the offending position; the reported value is NaN, because the element
/// was not a number and inventing one would be the confusion `Bytes` exists to
/// prevent.
fn concatBytesNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const list = arrayArg(args, 0) orelse
        return failure(ctx, .{ .kind = .invalid_octet, .index = 0, .val = std.math.nan(f64) });

    const count = list.getArrayLength();
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const part = bytes.asBytes(list.getSlot(@intCast(i + 1))) orelse return failure(ctx, .{
            .kind = .invalid_octet,
            .index = @floatFromInt(i),
            .val = std.math.nan(f64),
        });
        total += bytes.length(part);
        if (total > bytes.MAX_LENGTH) {
            return failure(ctx, .{ .kind = .size_limit, .limit = bytes.MAX_LENGTH });
        }
    }

    const out = try ctx.createBytesUninitialized(@intCast(total));
    const buf = bytes.bufferMut(out).?.dataMut();
    var written: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const part = bytes.asBytes(list.getSlot(@intCast(i + 1))).?;
        const octets = bytes.data(part);
        @memcpy(buf[written..][0..octets.len], octets);
        written += octets.len;
    }
    return helpers.createResultOk(ctx, JSValue.fromPtr(out));
}

/// `encodeUtf8(text)`: total. A JS string in this engine already holds UTF-8,
/// so the encoding is a copy - and the copy is the point, since the result must
/// own its octets rather than alias the string.
fn encodeUtf8Native(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const text = if (args.len > 0) helpers.getStringDataCtx(args[0], ctx) else null;
    const out = try bytes.fromSlice(ctx, text orelse "");
    return JSValue.fromPtr(out);
}

/// `decodeUtf8(value)`: validated, and an invalid sequence is reported at the
/// offset where it starts. `invalid-encoding`, never `invalid-octet` - every
/// octet is a valid octet; it is the sequence that is not a valid encoding.
fn decodeUtf8Native(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const b = bytesArg(args, 0) orelse return failure(ctx, .{
        .kind = .invalid_encoding,
        .encoding = "utf-8",
        .offset = 0,
    });

    const octets = bytes.data(b);
    if (firstInvalidUtf8(octets)) |offset| {
        return failure(ctx, .{ .kind = .invalid_encoding, .encoding = "utf-8", .offset = offset });
    }
    const text = try ctx.createString(octets);
    return helpers.createResultOk(ctx, text);
}

/// The offset of the first byte that does not start a well-formed UTF-8
/// sequence, or null when the whole slice is valid. An offset is what makes
/// the diagnostic actionable, which is why this does not just call
/// `std.unicode.utf8ValidateSlice`.
fn firstInvalidUtf8(octets: []const u8) ?usize {
    var i: usize = 0;
    while (i < octets.len) {
        const width = std.unicode.utf8ByteSequenceLength(octets[i]) catch return i;
        if (i + width > octets.len) return i;
        _ = std.unicode.utf8Decode(octets[i..][0..width]) catch return i;
        i += width;
    }
    return null;
}

/// `decodeBase64(text)`: the standard alphabet with padding, the same one
/// `zttp:crypto`'s string pair uses, so the two agree on what base64 is.
fn decodeBase64Native(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const text = if (args.len > 0) helpers.getStringDataCtx(args[0], ctx) else null;
    const input = text orelse return failure(ctx, .{
        .kind = .invalid_encoding,
        .encoding = "base64",
        .offset = 0,
    });

    if (firstInvalidBase64(input)) |offset| {
        return failure(ctx, .{ .kind = .invalid_encoding, .encoding = "base64", .offset = offset });
    }

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(input) catch
        return failure(ctx, .{ .kind = .invalid_encoding, .encoding = "base64", .offset = input.len });
    if (decoded_len > bytes.MAX_LENGTH) {
        return failure(ctx, .{ .kind = .size_limit, .limit = bytes.MAX_LENGTH });
    }

    const out = try ctx.createBytesUninitialized(@intCast(decoded_len));
    decoder.decode(bytes.bufferMut(out).?.dataMut(), input) catch
        return failure(ctx, .{ .kind = .invalid_encoding, .encoding = "base64", .offset = input.len });
    return helpers.createResultOk(ctx, JSValue.fromPtr(out));
}

/// The offset of the first character outside the standard alphabet, or null.
/// A length or padding fault has no single offending character, so it is
/// reported at the end of the input by the caller rather than guessed at here.
fn firstInvalidBase64(input: []const u8) ?usize {
    for (input, 0..) |c, i| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '+', '/' => {},
            // Padding is only well-formed at the end, and `calcSizeForSlice`
            // is what decides how much of it is allowed.
            '=' => {},
            else => return i,
        }
    }
    return null;
}

fn encodeBase64Native(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const b = bytesArg(args, 0) orelse return try ctx.createString("");

    const octets = bytes.data(b);
    const encoder = std.base64.standard.Encoder;
    const buf = try ctx.allocator.alloc(u8, encoder.calcSize(octets.len));
    defer ctx.allocator.free(buf);
    return try ctx.createString(encoder.encode(buf, octets));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gc_mod = @import("../../gc.zig");

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

/// Call an export the way the interpreter does: through its `NativeFn`, with
/// the opaque context pointer. Reading the exports this way rather than the
/// Zig helpers behind them is what makes these tests cover the binding.
fn call(h: *Harness, comptime name: []const u8, args: []const JSValue) !JSValue {
    inline for (binding.exports) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) {
            return f.func.?(@ptrCast(h.ctx), JSValue.undefined_val, args);
        }
    }
    return error.TestUnknownExport;
}

fn makeArray(h: *Harness, items: []const JSValue) !JSValue {
    const arr = helpers.createArrayWithPrototype(h.ctx) orelse return error.TestAllocFailed;
    for (items, 0..) |item, i| try arr.setIndex(h.ctx.allocator, @intCast(i), item);
    return JSValue.fromPtr(arr);
}

fn okValue(h: *Harness, result: JSValue) !JSValue {
    const obj = helpers.getObject(result) orelse return error.TestExpectedResult;
    if (!obj.inline_slots[JSObject.Slots.RESULT_IS_OK].isTrue()) return error.TestExpectedOk;
    _ = h;
    return obj.inline_slots[JSObject.Slots.RESULT_VALUE];
}

fn errValue(h: *Harness, result: JSValue) !*JSObject {
    const obj = helpers.getObject(result) orelse return error.TestExpectedResult;
    if (obj.inline_slots[JSObject.Slots.RESULT_IS_OK].isTrue()) return error.TestExpectedErr;
    _ = h;
    return helpers.getObject(obj.inline_slots[JSObject.Slots.RESULT_VALUE]) orelse
        return error.TestExpectedErrorRecord;
}

fn field(h: *Harness, obj: *JSObject, name: []const u8) !JSValue {
    const pool = h.ctx.hidden_class_pool orelse return error.TestNoPool;
    const atom = try h.ctx.atoms.intern(name);
    return obj.getProperty(pool, atom) orelse JSValue.undefined_val;
}

fn errKind(h: *Harness, result: JSValue) ![]const u8 {
    const obj = try errValue(h, result);
    return helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx) orelse
        return error.TestExpectedString;
}

test "the module declares the nine exports of spec 6.3 and no capabilities" {
    // The floor: every assertion below is about a binding, so an empty export
    // list would satisfy each of them over nothing.
    try testing.expectEqual(@as(usize, 9), binding.exports.len);
    try testing.expectEqual(@as(usize, 0), binding.required_capabilities.len);

    const expected = [_][]const u8{
        "bytesFromOctets", "bytesLength",  "byteAt",
        "sliceBytes",      "concatBytes",  "encodeUtf8",
        "decodeUtf8",      "decodeBase64", "encodeBase64",
    };
    for (expected, binding.exports) |name, f| {
        try testing.expectEqualStrings(name, f.name);
        try testing.expect(f.replay_pure);
        try testing.expectEqual(mb.EffectClass.none, f.effect);
    }

    // Exactly five exports are fallible, and they are the five the spec marks.
    // A sixth would cost its call sites a guard for an untakeable branch; a
    // missing one would be a failure with nowhere to go.
    var fallible: usize = 0;
    for (binding.exports) |f| {
        if (f.returns == .result) fallible += 1;
    }
    try testing.expectEqual(@as(usize, 5), fallible);
    for ([_][]const u8{ "bytesFromOctets", "sliceBytes", "concatBytes", "decodeUtf8", "decodeBase64" }) |name| {
        for (binding.exports) |f| {
            if (std.mem.eql(u8, f.name, name)) try testing.expectEqual(mb.ReturnKind.result, f.returns);
        }
    }
}

test "UTF-8 round-trips including an astral scalar" {
    const h = try harness();
    defer releaseHarness(h);

    const text = "hello \u{00e9} \u{4e16} \u{1F600}";
    const encoded = try call(h, "encodeUtf8", &.{try h.ctx.createString(text)});
    try testing.expect(bytes.isBytes(encoded));
    try testing.expectEqualSlices(u8, text, bytes.data(bytes.asBytes(encoded).?));

    const decoded = try call(h, "decodeUtf8", &.{encoded});
    const out = try okValue(h, decoded);
    try testing.expectEqualStrings(text, helpers.getStringDataCtx(out, h.ctx).?);
}

test "an invalid UTF-8 sequence reports invalid-encoding with its offset" {
    const h = try harness();
    defer releaseHarness(h);

    // A well-formed two-byte prefix, then a lone continuation byte at index 3.
    const raw = try bytes.fromSlice(h.ctx, &[_]u8{ 'a', 0xC3, 0xA9, 0x80, 'z' });
    const result = try call(h, "decodeUtf8", &.{JSValue.fromPtr(raw)});

    const obj = try errValue(h, result);
    try testing.expectEqualStrings("invalid-encoding", helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx).?);
    try testing.expectEqualStrings("utf-8", helpers.getStringDataCtx(try field(h, obj, "encoding"), h.ctx).?);
    try testing.expectEqual(@as(f64, 3), (try field(h, obj, "offset")).toNumber().?);

    // And not `invalid-octet`: every byte here is a valid octet, so naming the
    // octet would point the author at the wrong thing.
    try testing.expect(!std.mem.eql(u8, "invalid-octet", try errKind(h, result)));
}

test "a truncated sequence at the end reports the offset it starts at" {
    const h = try harness();
    defer releaseHarness(h);

    // 0xE4 opens a three-byte sequence with only two bytes left.
    const raw = try bytes.fromSlice(h.ctx, &[_]u8{ 'o', 'k', 0xE4, 0xB8 });
    const obj = try errValue(h, try call(h, "decodeUtf8", &.{JSValue.fromPtr(raw)}));
    try testing.expectEqual(@as(f64, 2), (try field(h, obj, "offset")).toNumber().?);
}

test "base64 round-trips and rejects a bad alphabet at its offset" {
    const h = try harness();
    defer releaseHarness(h);

    const raw = try bytes.fromSlice(h.ctx, &[_]u8{ 0, 1, 2, 250, 255 });
    const encoded = try call(h, "encodeBase64", &.{JSValue.fromPtr(raw)});
    const encoded_text = helpers.getStringDataCtx(encoded, h.ctx).?;
    try testing.expectEqualStrings("AAEC+v8=", encoded_text);

    const decoded = try okValue(h, try call(h, "decodeBase64", &.{encoded}));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 250, 255 }, bytes.data(bytes.asBytes(decoded).?));

    // `!` is outside the standard alphabet, at index 2.
    const bad = try call(h, "decodeBase64", &.{try h.ctx.createString("AA!ECg==")});
    const obj = try errValue(h, bad);
    try testing.expectEqualStrings("invalid-encoding", helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx).?);
    try testing.expectEqualStrings("base64", helpers.getStringDataCtx(try field(h, obj, "encoding"), h.ctx).?);
    try testing.expectEqual(@as(f64, 2), (try field(h, obj, "offset")).toNumber().?);

    // A length fault has no offending character, so it is reported at the end
    // rather than pinned on an innocent one.
    const short = try call(h, "decodeBase64", &.{try h.ctx.createString("AAA")});
    try testing.expectEqualStrings("invalid-encoding", try errKind(h, short));
}

test "an octet outside the range is refused with its index and its value" {
    const h = try harness();
    defer releaseHarness(h);

    const list = try makeArray(h, &.{ num(1), num(2), num(300) });
    const obj = try errValue(h, try call(h, "bytesFromOctets", &.{list}));
    try testing.expectEqualStrings("invalid-octet", helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx).?);
    try testing.expectEqual(@as(f64, 2), (try field(h, obj, "index")).toNumber().?);
    try testing.expectEqual(@as(f64, 300), (try field(h, obj, "value")).toNumber().?);

    // A fractional octet is refused rather than truncated to 1.
    const fractional = try makeArray(h, &.{num(1.5)});
    const frac_obj = try errValue(h, try call(h, "bytesFromOctets", &.{fractional}));
    try testing.expectEqual(@as(f64, 1.5), (try field(h, frac_obj, "value")).toNumber().?);

    // And the good list still builds.
    const good = try makeArray(h, &.{ num(0), num(128), num(255) });
    const built = try okValue(h, try call(h, "bytesFromOctets", &.{good}));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 128, 255 }, bytes.data(bytes.asBytes(built).?));
}

test "sliceBytes with start after end reports invalid-bounds with both" {
    const h = try harness();
    defer releaseHarness(h);

    const src = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{ 1, 2, 3, 4 }));

    const obj = try errValue(h, try call(h, "sliceBytes", &.{ src, num(3), num(1) }));
    try testing.expectEqualStrings("invalid-bounds", helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx).?);
    try testing.expectEqual(@as(f64, 3), (try field(h, obj, "start")).toNumber().?);
    try testing.expectEqual(@as(f64, 1), (try field(h, obj, "end")).toNumber().?);

    // A negative start is reported as written rather than clamped to zero,
    // which would have made a caller's sign error look like a valid request.
    const negative = try errValue(h, try call(h, "sliceBytes", &.{ src, num(-1), num(2) }));
    try testing.expectEqual(@as(f64, -1), (try field(h, negative, "start")).toNumber().?);

    // Past the end is out of bounds; the empty slice at the end is not.
    try testing.expectEqualStrings("invalid-bounds", try errKind(h, try call(h, "sliceBytes", &.{ src, num(0), num(5) })));
    const empty = try okValue(h, try call(h, "sliceBytes", &.{ src, num(4), num(4) }));
    try testing.expectEqual(@as(u32, 0), bytes.length(bytes.asBytes(empty).?));

    const part = try okValue(h, try call(h, "sliceBytes", &.{ src, num(1), num(3) }));
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 3 }, bytes.data(bytes.asBytes(part).?));
}

test "byteAt past the end is undefined rather than an error" {
    const h = try harness();
    defer releaseHarness(h);

    const src = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{ 7, 8, 9 }));

    try testing.expectEqual(@as(f64, 8), (try call(h, "byteAt", &.{ src, num(1) })).toNumber().?);
    try testing.expect((try call(h, "byteAt", &.{ src, num(3) })).isUndefined());
    try testing.expect((try call(h, "byteAt", &.{ src, num(-1) })).isUndefined());
    try testing.expect((try call(h, "byteAt", &.{ src, num(1.5) })).isUndefined());

    try testing.expectEqual(@as(f64, 3), (try call(h, "bytesLength", &.{src})).toNumber().?);
}

test "concatBytes of an empty list is the empty value" {
    const h = try harness();
    defer releaseHarness(h);

    const empty = try okValue(h, try call(h, "concatBytes", &.{try makeArray(h, &.{})}));
    try testing.expect(bytes.isBytes(empty));
    try testing.expectEqual(@as(u32, 0), bytes.length(bytes.asBytes(empty).?));

    const a = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{ 1, 2 }));
    const b = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{}));
    const c = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{ 3, 4, 5 }));
    const joined = try okValue(h, try call(h, "concatBytes", &.{try makeArray(h, &.{ a, b, c })}));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, bytes.data(bytes.asBytes(joined).?));

    // An element that is not a Bytes is refused rather than skipped, and the
    // index names which one.
    const mixed = try makeArray(h, &.{ a, try h.ctx.createString("no") });
    const obj = try errValue(h, try call(h, "concatBytes", &.{mixed}));
    try testing.expectEqualStrings("invalid-octet", helpers.getStringDataCtx(try field(h, obj, "kind"), h.ctx).?);
    try testing.expectEqual(@as(f64, 1), (try field(h, obj, "index")).toNumber().?);
}

test "an empty Bytes encodes to the empty string and back" {
    const h = try harness();
    defer releaseHarness(h);

    const empty = JSValue.fromPtr(try bytes.fromSlice(h.ctx, &[_]u8{}));
    try testing.expectEqualStrings("", helpers.getStringDataCtx(try call(h, "encodeBase64", &.{empty}), h.ctx).?);
    try testing.expectEqualStrings("", helpers.getStringDataCtx(try okValue(h, try call(h, "decodeUtf8", &.{empty})), h.ctx).?);

    const decoded = try okValue(h, try call(h, "decodeBase64", &.{try h.ctx.createString("")}));
    try testing.expectEqual(@as(u32, 0), bytes.length(bytes.asBytes(decoded).?));
}
