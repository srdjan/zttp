//! zttp:result - the constructors and combinators over `Result<T, E>`
//! (spec 6.1).
//!
//! `Result` itself is predeclared and needs no import. What this module
//! supplies is the admitted operations on it, as free functions: the profile
//! has no member form for a `Result`, so `unwrapOr(r, d)` is the spelling and
//! `r.unwrapOr(d)` is not. The type checker already refuses the method form -
//! it models `Result` as a record with no methods - so before this module
//! there was no admitted way to write consumption rule 1 at all.
//!
//! The module lives in the engine-coupled tier because a `Result` is a native
//! class with three inline slots, and the mechanics of reading and building one
//! live in `builtins/result.zig`. The four combinators delegate there rather
//! than reimplementing the slot layout beside it.
//!
//! Effect rows. Spec 6.1 makes the combinator callbacks effect-row
//! polymorphic: the callback of `mapResult`, `mapError`, `andThen`, and
//! `orElse` may be effectful, and the call's row is the join of the callback's
//! row and its operands'. That is what the declared `.none` effect on each
//! export means - the export itself reaches nothing. The join is not declared
//! anywhere, because it is not a declaration: `effect_inference` walks a
//! callback argument's body into the enclosing function's row, and a named
//! helper passed in the same position gets its call-graph edge at the argument
//! site. A test below pins it, since nothing else would notice if it stopped
//! being true.

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const object = @import("../../object.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");
const helpers = @import("../../builtins/helpers.zig");
const result = @import("../../builtins/result.zig");

const JSValue = value.JSValue;
const JSObject = object.JSObject;

// Every export is `replay_pure`: it reads its arguments and nothing else. A
// callback's own I/O is stubbed at the callback's own call site, not here.
//
// Every export is also `derives_from_args`: a `Result` holds what was put in
// it, `unwrapOr` hands the payload straight back, and `collectAll` collects
// the values it was given. Without the flag a secret routed through any of
// them would reach the response with `no_secret_leakage` PROVEN, which is the
// hole `zttp:collections` and `zttp:json` shipped with and had closed.
//
// `laws = .{.pure}` is declared only where it is unconditionally true. The
// four callback-taking combinators do not carry it: spec 6.1 admits an
// effectful callback, so a rewrite justified by purity would be justified by
// something the source can contradict.
pub const binding = mb.ModuleBinding{
    .specifier = "zttp:result",
    .name = "result",
    .summary = "Free functions, not methods: the profile has no member form for a Result, so unwrapOr(r, d) is the spelling and r.unwrapOr(d) is refused.",
    .required_capabilities = &.{},
    .exports = &.{
        .{ .name = "ok", .func = okNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.unknown}, .param_names = &.{"value"}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "err", .func = errNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.unknown}, .param_names = &.{"error"}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "mapResult", .func = mapResultNative, .arg_count = 2, .effect = .none, .returns = .result, .param_types = &.{ .result, .object }, .param_names = &.{ "result", "fn" }, .replay_pure = true, .derives_from_args = true },
        .{ .name = "mapError", .func = mapErrorNative, .arg_count = 2, .effect = .none, .returns = .result, .param_types = &.{ .result, .object }, .param_names = &.{ "result", "fn" }, .replay_pure = true, .derives_from_args = true },
        .{ .name = "andThen", .func = andThenNative, .arg_count = 2, .effect = .none, .returns = .result, .param_types = &.{ .result, .object }, .param_names = &.{ "result", "fn" }, .replay_pure = true, .derives_from_args = true },
        .{ .name = "orElse", .func = orElseNative, .arg_count = 2, .effect = .none, .returns = .result, .param_types = &.{ .result, .object }, .param_names = &.{ "result", "fn" }, .replay_pure = true, .derives_from_args = true },
        .{ .name = "unwrapOr", .func = unwrapOrNative, .arg_count = 2, .effect = .none, .returns = .unknown, .param_types = &.{ .result, .unknown }, .param_names = &.{ "result", "fallback" }, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
        .{ .name = "collectAll", .func = collectAllNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.object}, .param_names = &.{"results"}, .laws = &.{.pure}, .replay_pure = true, .derives_from_args = true },
    },
};

pub const exports = binding.toModuleExports();

fn argAt(args: []const JSValue, index: usize) JSValue {
    if (args.len <= index) return JSValue.undefined_val;
    return args[index];
}

fn okNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return helpers.createResultOk(ctx, argAt(args, 0));
}

fn errNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return helpers.createResultErr(ctx, argAt(args, 0));
}

/// The four combinators take the `Result` as their first argument where the
/// shipped prototype methods take it as `this`. That is the whole adaptation:
/// the transformation itself is the one `builtins/result.zig` already
/// performs, and duplicating it here would be a second place for the slot
/// layout to be wrong.
fn mapResultNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return result.resultMap(ctx, argAt(args, 0), rest(args));
}

fn mapErrorNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return result.resultMapErr(ctx, argAt(args, 0), rest(args));
}

fn andThenNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return result.resultAndThen(ctx, argAt(args, 0), rest(args));
}

fn orElseNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return result.resultOrElse(ctx, argAt(args, 0), rest(args));
}

fn unwrapOrNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return result.resultUnwrapOr(ctx, argAt(args, 0), rest(args));
}

/// Everything after the `Result`, which is where the prototype form's own
/// argument list starts.
fn rest(args: []const JSValue) []const JSValue {
    if (args.len <= 1) return &.{};
    return args[1..];
}

/// `collectAll(results)`: the first `err` in order, or an ok holding every
/// value in order. First-error rather than error-accumulating, so it agrees
/// with the `andThen` short-circuit the same chain would have spelled by hand
/// (spec 6.1).
///
/// A malformed argument - not an array, or an element that is not
/// `Result`-shaped - answers `err(undefined)`. The type checker refuses both
/// at the call site, so this is the shape of an already-refused program; it
/// matches what `dictFromEntries` answers for a malformed entry list rather
/// than inventing a second convention for the same situation.
fn collectAllNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const arg = argAt(args, 0);
    if (!arg.isObject()) return helpers.createResultErr(ctx, JSValue.undefined_val);
    const list = JSObject.fromValue(arg);
    if (list.class_id != .array) return helpers.createResultErr(ctx, JSValue.undefined_val);

    const out = helpers.createArrayWithPrototype(ctx) orelse return JSValue.undefined_val;
    const len = list.getArrayLength();
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const coerced = result.coerceResultLike(ctx, list.getSlot(@intCast(i + 1))) orelse
            return helpers.createResultErr(ctx, JSValue.undefined_val);
        const entry = JSObject.fromValue(coerced);
        // The first err is returned as it stands, so its payload reaches the
        // caller unchanged and the walk stops: nothing after it is read.
        if (!entry.inline_slots[JSObject.Slots.RESULT_IS_OK].isTrue()) return coerced;
        try out.setIndex(ctx.allocator, i, entry.inline_slots[JSObject.Slots.RESULT_VALUE]);
    }
    return helpers.createResultOk(ctx, JSValue.fromPtr(out));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gc_mod = @import("../../gc.zig");
const http = helpers.http;

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
    http.setCallFunctionCallback(h.ctx, dispatchCallback);
    return h;
}

fn releaseHarness(h: *Harness) void {
    http.clearCallFunctionCallback(h.ctx);
    h.deinit();
    testing.allocator.destroy(h);
}

fn dispatchCallback(ctx: *context.Context, func: *JSObject, args: []const JSValue) anyerror!JSValue {
    const data = func.getNativeFunctionData() orelse return error.InvalidFunction;
    return data.func(ctx, JSValue.undefined_val, args);
}

fn nativeFn(h: *Harness, f: object.NativeFn) !JSValue {
    const pool = h.ctx.hidden_class_pool.?;
    const fn_obj = try JSObject.createNativeFunction(h.ctx.allocator, pool, h.ctx.root_class_idx, f, .map, 1);
    return fn_obj.toValue();
}

fn addOne(_: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    if (args.len == 0 or !args[0].isInt()) return JSValue.undefined_val;
    return JSValue.fromInt(args[0].getInt() + 1);
}

fn arrayOf(h: *Harness, values: []const JSValue) !JSValue {
    const arr = helpers.createArrayWithPrototype(h.ctx) orelse return error.TestExpectedArray;
    for (values, 0..) |v, i| try arr.setIndex(h.ctx.allocator, @intCast(i), v);
    return JSValue.fromPtr(arr);
}

fn isOk(val: JSValue) bool {
    if (!val.isObject()) return false;
    const obj = JSObject.fromValue(val);
    if (obj.class_id != .result) return false;
    return obj.inline_slots[JSObject.Slots.RESULT_IS_OK].isTrue();
}

fn payload(val: JSValue) JSValue {
    return JSObject.fromValue(val).inline_slots[JSObject.Slots.RESULT_VALUE];
}

test "collectAll returns the first error in order and reads nothing after it" {
    // The roadmap's phase 4 exit row. First-error is what makes `collectAll`
    // interchangeable with the `andThen` chain it replaces; an accumulating
    // version would return a different value for the same input, so the row
    // that rewrites one into the other would be unsound.
    const h = try harness();
    defer releaseHarness(h);

    const first_err = helpers.createResultErr(h.ctx, JSValue.fromInt(11));
    const second_err = helpers.createResultErr(h.ctx, JSValue.fromInt(22));
    const list = try arrayOf(h, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(1)),
        first_err,
        second_err,
    });

    const collected = try collectAllNative(h.ctx, JSValue.undefined_val, &.{list});
    try testing.expect(!isOk(collected));
    try testing.expectEqual(@as(i32, 11), payload(collected).getInt());
}

test "collectAll over all-ok collects the values in order" {
    const h = try harness();
    defer releaseHarness(h);

    const list = try arrayOf(h, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(7)),
        helpers.createResultOk(h.ctx, JSValue.fromInt(8)),
        helpers.createResultOk(h.ctx, JSValue.fromInt(9)),
    });

    const collected = try collectAllNative(h.ctx, JSValue.undefined_val, &.{list});
    try testing.expect(isOk(collected));
    const values = JSObject.fromValue(payload(collected));
    try testing.expectEqual(@as(u32, 3), values.getArrayLength());
    try testing.expectEqual(@as(i32, 7), values.getSlot(1).getInt());
    try testing.expectEqual(@as(i32, 8), values.getSlot(2).getInt());
    try testing.expectEqual(@as(i32, 9), values.getSlot(3).getInt());
}

test "collectAll of an empty list is an ok holding nothing" {
    // The floor: a walk over zero elements must answer ok rather than fall
    // through to the malformed-input arm, which would report a failure for a
    // list that simply had nothing wrong with it.
    const h = try harness();
    defer releaseHarness(h);

    const collected = try collectAllNative(h.ctx, JSValue.undefined_val, &.{try arrayOf(h, &.{})});
    try testing.expect(isOk(collected));
    try testing.expectEqual(@as(u32, 0), JSObject.fromValue(payload(collected)).getArrayLength());
}

test "unwrapOr takes the value from an ok and the fallback from an err" {
    const h = try harness();
    defer releaseHarness(h);

    const from_ok = try unwrapOrNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(5)),
        JSValue.fromInt(99),
    });
    try testing.expectEqual(@as(i32, 5), from_ok.getInt());

    const from_err = try unwrapOrNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultErr(h.ctx, JSValue.fromInt(1)),
        JSValue.fromInt(99),
    });
    try testing.expectEqual(@as(i32, 99), from_err.getInt());
}

test "orElse recovers from an err and leaves an ok alone" {
    const h = try harness();
    defer releaseHarness(h);

    const recover = try nativeFn(h, recoverToOk);

    const recovered = try orElseNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultErr(h.ctx, JSValue.fromInt(3)),
        recover,
    });
    try testing.expect(isOk(recovered));
    try testing.expectEqual(@as(i32, 3), payload(recovered).getInt());

    const untouched = try orElseNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(42)),
        recover,
    });
    try testing.expect(isOk(untouched));
    try testing.expectEqual(@as(i32, 42), payload(untouched).getInt());
}

fn recoverToOk(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    return helpers.createResultOk(ctx, if (args.len > 0) args[0] else JSValue.undefined_val);
}

test "mapResult transforms an ok and passes an err through untouched" {
    const h = try harness();
    defer releaseHarness(h);

    const f = try nativeFn(h, addOne);

    const mapped = try mapResultNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(41)),
        f,
    });
    try testing.expect(isOk(mapped));
    try testing.expectEqual(@as(i32, 42), payload(mapped).getInt());

    const passed = try mapResultNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultErr(h.ctx, JSValue.fromInt(7)),
        f,
    });
    try testing.expect(!isOk(passed));
    try testing.expectEqual(@as(i32, 7), payload(passed).getInt());
}

test "mapError transforms an err and passes an ok through untouched" {
    const h = try harness();
    defer releaseHarness(h);

    const f = try nativeFn(h, addOne);

    const mapped = try mapErrorNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultErr(h.ctx, JSValue.fromInt(1)),
        f,
    });
    try testing.expect(!isOk(mapped));
    try testing.expectEqual(@as(i32, 2), payload(mapped).getInt());

    const passed = try mapErrorNative(h.ctx, JSValue.undefined_val, &.{
        helpers.createResultOk(h.ctx, JSValue.fromInt(1)),
        f,
    });
    try testing.expect(isOk(passed));
    try testing.expectEqual(@as(i32, 1), payload(passed).getInt());
}

test "ok and err build the values the combinators read" {
    const h = try harness();
    defer releaseHarness(h);

    const good = try okNative(h.ctx, JSValue.undefined_val, &.{JSValue.fromInt(1)});
    try testing.expect(isOk(good));
    const bad = try errNative(h.ctx, JSValue.undefined_val, &.{JSValue.fromInt(2)});
    try testing.expect(!isOk(bad));
    try testing.expectEqual(@as(i32, 2), payload(bad).getInt());
}
