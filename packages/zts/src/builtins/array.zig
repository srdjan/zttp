const std = @import("std");
const h = @import("helpers.zig");
const err_builtin = @import("error.zig");

const value = h.value;
const object = h.object;
const context = h.context;
const string = h.string;
const http = h.http;

const getObject = h.getObject;
const getCallFn = h.getCallFn;
const invokeCallback = h.invokeCallback;
const createArrayWithPrototype = h.createArrayWithPrototype;
const getCallbackArg = h.getCallbackArg;
const valueToStringSimple = h.valueToStringSimple;

fn throwTypeError(ctx: *context.Context, message: []const u8) value.JSValue {
    const message_val = ctx.createString(message) catch {
        ctx.throwException(value.JSValue.exception_val);
        return value.JSValue.exception_val;
    };
    const args = [_]value.JSValue{message_val};
    const err_obj = err_builtin.typeErrorConstructor(ctx, value.JSValue.undefined_val, &args);
    if (err_obj.isUndefined()) {
        ctx.throwException(value.JSValue.exception_val);
    } else {
        ctx.throwException(err_obj);
    }
    return value.JSValue.exception_val;
}

fn predicateBool(ctx: *context.Context, result: value.JSValue) ?bool {
    return result.toConditionBool() orelse {
        _ = throwTypeError(ctx, "predicate callback must return boolean");
        return null;
    };
}

// ============================================================================
// Array methods
// ============================================================================

/// Get array length from object
fn getArrayLength(obj: *object.JSObject, pool: ?*const object.HiddenClassPool) i32 {
    if (obj.class_id == .array) {
        return @intCast(obj.getArrayLength());
    }
    if (pool) |p| {
        if (obj.getOwnProperty(p, .length)) |len_val| {
            if (len_val.isInt()) return len_val.getInt();
        }
    }
    return 0;
}

/// Array.isArray(value) - Check if value is an array
pub fn arrayIsArray(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    _ = ctx;
    _ = this;
    if (args.len == 0) return value.JSValue.false_val;

    if (getObject(args[0])) |obj| {
        return if (obj.class_id == .array) value.JSValue.true_val else value.JSValue.false_val;
    }
    return value.JSValue.false_val;
}

/// Array.prototype.push(...items) - Append elements, return new length
pub fn arrayPush(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    if (obj.class_id != .array) return value.JSValue.undefined_val;

    // The receiver can be module state, so each store goes through the escape
    // check: a request-scoped value must not outlive the request arena.
    for (args) |arg| {
        ctx.setIndexChecked(obj, obj.getArrayLength(), arg) catch return value.JSValue.undefined_val;
    }
    return value.JSValue.fromInt(@intCast(obj.getArrayLength()));
}

/// Array.prototype.indexOf(searchElement, fromIndex?) - Find first index of element
/// Optimized: scans inline_slots and overflow_slots directly as contiguous u64
/// arrays, avoiding per-element getIndex overhead (class_id check, length check,
/// inline/overflow branch, undefined check).
pub fn arrayIndexOf(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    _ = ctx;
    const obj = getObject(this) orelse return value.JSValue.fromInt(-1);
    if (obj.class_id != .array) return value.JSValue.fromInt(-1);

    const len = obj.getArrayLength();
    if (args.len == 0 or len == 0) return value.JSValue.fromInt(-1);

    const search_elem = args[0];
    var from_idx: i32 = 0;
    if (args.len > 1 and args[1].isInt()) {
        from_idx = args[1].getInt();
        if (from_idx < 0) from_idx = @max(0, @as(i32, @intCast(len)) + from_idx);
    }

    const start: u32 = @intCast(@max(from_idx, 0));
    if (start >= len) return value.JSValue.fromInt(-1);

    // NaN never equals anything via strict equality
    if (search_elem.isFloat64() and std.math.isNan(search_elem.getFloat64())) {
        return value.JSValue.fromInt(-1);
    }

    // Numbers (cross int<->float and -0/+0), strings, and Bytes need strictEquals
    if (search_elem.isNumber() or search_elem.isAnyString() or search_elem.isBytes()) {
        return arrayIndexOfSlow(obj, search_elem, start, len);
    }

    // Fast path: raw u64 comparison for bools, null, undefined, object identity
    return arrayIndexOfRaw(obj, search_elem.raw, start, len);
}

/// Slow path: compare using strictEquals (for strings and boxed floats)
fn arrayIndexOfSlow(obj: *const object.JSObject, search_elem: value.JSValue, start: u32, len: u32) value.JSValue {
    var i: u32 = start;
    while (i < len) : (i += 1) {
        if (obj.getIndexUnchecked(i).strictEquals(search_elem)) {
            return value.JSValue.fromInt(@intCast(i));
        }
    }
    return value.JSValue.fromInt(-1);
}

/// Fast path: scan inline and overflow slots as contiguous u64 arrays
fn arrayIndexOfRaw(obj: *const object.JSObject, search_raw: u64, start: u32, len: u32) value.JSValue {
    const INLINE_CAP: u32 = object.JSObject.INLINE_SLOT_COUNT - 1; // 7 elements inline (slot 0 = length)

    // Scan inline slots (elements 0..min(len, 7))
    const inline_count: u32 = @min(len, INLINE_CAP);
    if (start < inline_count) {
        const slots_ptr: [*]const u64 = @ptrCast(&obj.inline_slots);
        var slot: u32 = start + 1; // slot = element_index + 1
        const slot_end: u32 = inline_count + 1;
        while (slot < slot_end) : (slot += 1) {
            if (slots_ptr[slot] == search_raw) {
                return value.JSValue.fromInt(@intCast(slot - 1));
            }
        }
    }

    // Scan overflow slots (elements 7..len), clamped to allocated overflow_capacity
    // so sparse arrays (length > backing) never read past the overflow buffer.
    if (len > INLINE_CAP) {
        if (obj.overflow_slots) |overflow| {
            const begin: u32 = if (start > INLINE_CAP) start - INLINE_CAP else 0;
            const count: u32 = @min(len - INLINE_CAP, @as(u32, obj.overflow_capacity));
            const overflow_ptr: [*]const u64 = @ptrCast(overflow);
            var i: u32 = begin;
            while (i < count) : (i += 1) {
                if (overflow_ptr[i] == search_raw) {
                    return value.JSValue.fromInt(@intCast(i + INLINE_CAP));
                }
            }
        }
    }

    return value.JSValue.fromInt(-1);
}

/// Array.prototype.includes(searchElement, fromIndex?) - Check if array contains element
/// Uses SameValueZero: NaN matches NaN (unlike indexOf which uses strict equality).
pub fn arrayIncludes(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    // SameValueZero treats NaN as equal to NaN (unlike ===)
    if (args.len > 0) {
        const search = args[0];
        if (search.isFloat64() and std.math.isNan(search.getFloat64())) {
            const obj = getObject(this) orelse return value.JSValue.false_val;
            if (obj.class_id != .array) return value.JSValue.false_val;
            const len = obj.getArrayLength();
            var i: u32 = 0;
            if (args.len > 1 and args[1].isInt()) {
                const from = args[1].getInt();
                if (from < 0) {
                    i = @intCast(@max(0, @as(i64, len) + @as(i64, from)));
                } else {
                    i = @intCast(@max(from, 0));
                }
            }
            while (i < len) : (i += 1) {
                const val = obj.getIndexUnchecked(i);
                if (val.isFloat64() and std.math.isNan(val.getFloat64())) {
                    return value.JSValue.true_val;
                }
            }
            return value.JSValue.false_val;
        }
    }

    // Non-NaN: SameValueZero is identical to strict equality
    const result = arrayIndexOf(ctx, this, args);
    if (result.isInt() and result.getInt() >= 0) {
        return value.JSValue.true_val;
    }
    return value.JSValue.false_val;
}

/// Array.prototype.join(separator?) - Join elements into string
/// Optimized: for arrays of integers/simple values, writes directly into a stack
/// buffer avoiding per-element JSString heap allocations.
pub fn arrayJoin(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    if (obj.class_id != .array) return value.JSValue.undefined_val;

    const ra = ctx.requestAllocator();
    const len = obj.getArrayLength();
    var separator: []const u8 = ",";
    var sep_str_owned: ?*string.JSString = null;
    defer if (sep_str_owned) |s| string.freeString(ra, s);
    if (args.len > 0 and !args[0].isUndefined()) {
        const sep_str = valueToStringSimple(ra, args[0]) catch return value.JSValue.undefined_val;
        separator = sep_str.data();
        if (!args[0].isString()) sep_str_owned = sep_str;
    }

    // Fast path: build result in a stack buffer (no per-element heap allocation)
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    var fast_ok = true;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (i > 0) {
            if (pos + separator.len > buf.len) {
                fast_ok = false;
                break;
            }
            @memcpy(buf[pos..][0..separator.len], separator);
            pos += separator.len;
        }

        const val = obj.getIndexUnchecked(i);
        if (val.isUndefined() or val.isNull()) continue;

        if (val.isInt()) {
            const written = writeIntToBuf(buf[pos..], val.getInt());
            if (written == 0) {
                fast_ok = false;
                break;
            }
            pos += written;
        } else if (val.isString()) {
            const data = val.toPtr(string.JSString).data();
            if (pos + data.len > buf.len) {
                fast_ok = false;
                break;
            }
            @memcpy(buf[pos..][0..data.len], data);
            pos += data.len;
        } else if (val.isStringSlice()) {
            const data = val.toPtr(string.SliceString).data();
            if (pos + data.len > buf.len) {
                fast_ok = false;
                break;
            }
            @memcpy(buf[pos..][0..data.len], data);
            pos += data.len;
        } else if (val.isTrue()) {
            if (pos + 4 > buf.len) {
                fast_ok = false;
                break;
            }
            @memcpy(buf[pos..][0..4], "true");
            pos += 4;
        } else if (val.isFalse()) {
            if (pos + 5 > buf.len) {
                fast_ok = false;
                break;
            }
            @memcpy(buf[pos..][0..5], "false");
            pos += 5;
        } else {
            fast_ok = false;
            break;
        }
    }

    if (fast_ok) {
        const result = createStringForJoin(ctx, buf[0..pos]) orelse return value.JSValue.undefined_val;
        return value.JSValue.fromPtr(result);
    }

    // Slow path: build the text in a scratch buffer, then copy it into the
    // result string. The buffer is freed here, not at request reset.
    const scratch = ctx.scratchAllocator();
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(scratch);

    i = 0;
    while (i < len) : (i += 1) {
        if (i > 0) {
            buffer.appendSlice(scratch, separator) catch return value.JSValue.undefined_val;
        }
        const val = obj.getIndexUnchecked(i);
        if (val.isUndefined() or val.isNull()) {
            continue;
        }
        const elem_str = valueToStringSimple(ra, val) catch return value.JSValue.undefined_val;
        defer if (!val.isString()) string.freeString(ra, elem_str);
        buffer.appendSlice(scratch, elem_str.data()) catch return value.JSValue.undefined_val;
    }

    const result = createStringForJoin(ctx, buffer.items) orelse return value.JSValue.undefined_val;
    return value.JSValue.fromPtr(result);
}

/// Write an i32 as decimal digits into a buffer. Returns bytes written, or 0 if buffer too small.
fn writeIntToBuf(buf: []u8, val: i32) usize {
    if (val == 0) {
        if (buf.len == 0) return 0;
        buf[0] = '0';
        return 1;
    }

    var n: u64 = if (val < 0) @intCast(-@as(i64, val)) else @intCast(val);
    var digits: [11]u8 = undefined;
    var dlen: usize = 0;
    while (n > 0) {
        digits[dlen] = @intCast('0' + @as(u8, @truncate(n % 10)));
        n /= 10;
        dlen += 1;
    }

    var out_pos: usize = 0;
    if (val < 0) {
        if (buf.len == 0) return 0;
        buf[0] = '-';
        out_pos = 1;
    }
    if (out_pos + dlen > buf.len) return 0;

    var j: usize = 0;
    while (j < dlen) : (j += 1) {
        buf[out_pos + j] = digits[dlen - 1 - j];
    }
    return out_pos + dlen;
}

/// Create a string using arena when available, general allocator otherwise.
fn createStringForJoin(ctx: *context.Context, data: []const u8) ?*string.JSString {
    if (ctx.hybrid) |hybrid| {
        return string.createStringWithArena(hybrid.arena, data);
    }
    return ctx.createStringPtr(data) catch null;
}

/// Array.prototype.slice(start?, end?) - Return shallow copy of portion
pub fn arraySlice(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const len: i32 = @max(0, getArrayLength(obj, ctx.hidden_class_pool));
    const len_i64: i64 = len;

    var start_i64: i64 = 0;
    var end_i64: i64 = len_i64;

    if (args.len > 0 and !args[0].isUndefined()) {
        if (args[0].isInt()) {
            start_i64 = args[0].getInt();
        } else if (args[0].toNumber()) |n| {
            if (std.math.isFinite(n)) {
                start_i64 = std.math.lossyCast(i64, @trunc(n));
            } else if (n > 0) {
                start_i64 = len_i64;
            } // NaN / -Infinity -> start stays 0
        }
        if (start_i64 < 0) start_i64 = @max(@as(i64, 0), len_i64 + start_i64);
        start_i64 = @min(start_i64, len_i64);
    }
    if (args.len > 1 and !args[1].isUndefined()) {
        if (args[1].isInt()) {
            end_i64 = args[1].getInt();
        } else if (args[1].toNumber()) |n| {
            if (std.math.isFinite(n)) {
                end_i64 = std.math.lossyCast(i64, @trunc(n));
            } else if (n > 0) {
                end_i64 = len_i64; // +Infinity -> end = len
            } else {
                end_i64 = 0; // -Infinity / NaN -> 0
            }
        }
        if (end_i64 < 0) end_i64 = @max(@as(i64, 0), len_i64 + end_i64);
        end_i64 = @min(end_i64, len_i64);
    }

    const start: i32 = @intCast(start_i64);
    const end: i32 = @intCast(end_i64);

    if (end <= start) {
        const result = ctx.createArray() catch return value.JSValue.undefined_val;
        result.prototype = ctx.array_prototype;
        result.setArrayLength(0);
        return result.toValue();
    }

    const slice_len: u32 = @intCast(end - start);
    const result = ctx.createArray() catch return value.JSValue.undefined_val;
    result.prototype = ctx.array_prototype;
    var dst: u32 = 0;
    var src: i32 = start;
    while (src < end) : ({
        src += 1;
        dst += 1;
    }) {
        const elem = obj.getIndex(@intCast(src)) orelse value.JSValue.undefined_val;
        ctx.setIndexChecked(result, dst, elem) catch return value.JSValue.undefined_val;
    }
    result.setArrayLength(slice_len);
    return result.toValue();
}

/// Array.prototype.concat(...items) - Merge arrays
/// Append every element of `src` (an array object) onto `dst`.
fn appendArrayElements(ctx: *context.Context, dst: *object.JSObject, src: *object.JSObject) !void {
    const len = getArrayLength(src, ctx.hidden_class_pool);
    const ulen: u32 = if (len > 0) @intCast(len) else 0;
    var i: u32 = 0;
    while (i < ulen) : (i += 1) {
        const elem = src.getIndex(i) orelse value.JSValue.undefined_val;
        try dst.arrayPush(ctx.allocator, elem);
    }
}

/// Array.prototype.map(callback, thisArg?) - Map to new array
pub fn arrayMap(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.undefined_val;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.undefined_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return (createArrayWithPrototype(ctx) orelse return error.OutOfMemory).toValue();

    const result = createArrayWithPrototype(ctx) orelse return error.OutOfMemory;
    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const mapped = try invokeCallback(ctx, call_fn, callback, &call_args);
        try result.arrayPush(ctx.allocator, mapped);
    }
    return result.toValue();
}

/// Array.prototype.filter(callback, thisArg?) - Filter to new array
pub fn arrayFilter(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.undefined_val;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.undefined_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return (createArrayWithPrototype(ctx) orelse return error.OutOfMemory).toValue();

    const result = createArrayWithPrototype(ctx) orelse return error.OutOfMemory;
    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const keep = try invokeCallback(ctx, call_fn, callback, &call_args);
        const keep_bool = predicateBool(ctx, keep) orelse return value.JSValue.exception_val;
        if (keep_bool) {
            try result.arrayPush(ctx.allocator, elem);
        }
    }
    return result.toValue();
}

/// Array.prototype.reduce(callback, initialValue?) - Reduce to single value
pub fn arrayReduce(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.undefined_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    const len_u32: u32 = if (len > 0) @intCast(len) else 0;

    var accumulator: value.JSValue = value.JSValue.undefined_val;
    var start_idx: u32 = 0;

    if (args.len > 1) {
        accumulator = args[1];
    } else if (len_u32 > 0) {
        accumulator = obj.getIndex(0) orelse value.JSValue.undefined_val;
        start_idx = 1;
    } else {
        return throwTypeError(ctx, "Reduce of empty array with no initial value");
    }

    if (start_idx >= len_u32) return accumulator;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.undefined_val;

    var i: u32 = start_idx;
    while (i < len_u32) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ accumulator, elem, value.JSValue.fromInt(@intCast(i)), this };
        accumulator = try invokeCallback(ctx, call_fn, callback, &call_args);
    }
    return accumulator;
}

/// Array.prototype.every(callback, thisArg?) - Test if all elements pass
pub fn arrayEvery(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.true_val;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.true_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return value.JSValue.true_val;

    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const result = try invokeCallback(ctx, call_fn, callback, &call_args);
        const result_bool = predicateBool(ctx, result) orelse return value.JSValue.exception_val;
        if (!result_bool) return value.JSValue.false_val;
    }
    return value.JSValue.true_val;
}

/// Array.prototype.some(callback, thisArg?) - Test if any element passes
pub fn arraySome(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.false_val;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.false_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return value.JSValue.false_val;

    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const result = try invokeCallback(ctx, call_fn, callback, &call_args);
        const result_bool = predicateBool(ctx, result) orelse return value.JSValue.exception_val;
        if (result_bool) return value.JSValue.true_val;
    }
    return value.JSValue.false_val;
}

/// Array.prototype.find(callback, thisArg?) - Find first matching element
pub fn arrayFind(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.undefined_val;
    const call_fn = getCallFn(ctx) orelse return value.JSValue.undefined_val;
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return value.JSValue.undefined_val;

    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const result = try invokeCallback(ctx, call_fn, callback, &call_args);
        const result_bool = predicateBool(ctx, result) orelse return value.JSValue.exception_val;
        if (result_bool) return elem;
    }
    return value.JSValue.undefined_val;
}

/// Array.prototype.findIndex(callback, thisArg?) - Find index of first matching element
pub fn arrayFindIndex(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    const callback = getCallbackArg(args) orelse return value.JSValue.fromInt(-1);
    const call_fn = getCallFn(ctx) orelse return value.JSValue.fromInt(-1);
    const len = getArrayLength(obj, ctx.hidden_class_pool);
    if (len <= 0) return value.JSValue.fromInt(-1);

    var i: u32 = 0;
    while (i < @as(u32, @intCast(len))) : (i += 1) {
        const elem = obj.getIndex(i) orelse value.JSValue.undefined_val;
        const call_args = [_]value.JSValue{ elem, value.JSValue.fromInt(@intCast(i)), this };
        const result = try invokeCallback(ctx, call_fn, callback, &call_args);
        const result_bool = predicateBool(ctx, result) orelse return value.JSValue.exception_val;
        if (result_bool) return value.JSValue.fromInt(@intCast(i));
    }
    return value.JSValue.fromInt(-1);
}

/// Array.prototype.toSorted(compareFunc?) - Return new sorted array (non-mutating)
/// With a compare function, orders by the sign of its numeric return value (per JS
/// spec: <0 keeps a before b, >0 puts b before a, 0/NaN treats them as equal).
/// Without one, falls back to default lexicographic string comparison.
pub fn arrayToSorted(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const obj = getObject(this) orelse return value.JSValue.undefined_val;
    if (obj.class_id != .array) return value.JSValue.undefined_val;

    const compare_fn: ?*object.JSObject = getCallbackArg(args);

    const len = obj.getArrayLength();
    if (len == 0) {
        const result = try ctx.createArray();
        result.prototype = ctx.array_prototype;
        return result.toValue();
    }

    // Copy elements to temporary buffer
    const ra = ctx.requestAllocator();
    const temp = try ra.alloc(value.JSValue, len);
    defer ra.free(temp);

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        temp[i] = obj.getIndex(i) orelse value.JSValue.undefined_val;
    }

    if (compare_fn) |callback| {
        // Custom comparator: order by the sign of the callback's numeric result.
        const call_fn = getCallFn(ctx) orelse return value.JSValue.undefined_val;
        const CompareCtx = struct {
            ctx: *context.Context,
            call_fn: http.CallFunctionFn,
            callback: *object.JSObject,
            // std.mem.sort cannot propagate: keep the first callback error here and return it after the sort.
            first_error: *?anyerror,
            pub fn lessThan(self: @This(), a: value.JSValue, b: value.JSValue) bool {
                if (self.first_error.* != null) return false;
                // undefined values sort to the end without invoking the comparator (per spec).
                if (a.isUndefined()) return false;
                if (b.isUndefined()) return true;
                const call_args = [_]value.JSValue{ a, b };
                const result = invokeCallback(self.ctx, self.call_fn, self.callback, &call_args) catch |err| {
                    self.first_error.* = err;
                    return false;
                };
                const n = result.toNumber() orelse return false;
                return n < 0;
            }
        };
        var first_error: ?anyerror = null;
        std.mem.sort(value.JSValue, temp, CompareCtx{ .ctx = ctx, .call_fn = call_fn, .callback = callback, .first_error = &first_error }, CompareCtx.lessThan);
        if (first_error) |err| return err;
    } else {
        // Default: lexicographic string comparison (per JS spec).
        const CompareCtx = struct {
            allocator: std.mem.Allocator,
            first_error: *?anyerror,

            pub fn lessThan(self: @This(), a: value.JSValue, b: value.JSValue) bool {
                if (self.first_error.* != null) return false;
                // undefined values go to the end
                if (a.isUndefined() and b.isUndefined()) return false;
                if (a.isUndefined()) return false;
                if (b.isUndefined()) return true;

                // Convert to strings and compare lexicographically (JS default)
                const str_a = valueToStringSimple(self.allocator, a) catch |err| {
                    self.first_error.* = err;
                    return false;
                };
                defer if (!a.isString()) string.freeString(self.allocator, str_a);
                const str_b = valueToStringSimple(self.allocator, b) catch |err| {
                    self.first_error.* = err;
                    return false;
                };
                defer if (!b.isString()) string.freeString(self.allocator, str_b);

                const slice_a = str_a.data();
                const slice_b = str_b.data();

                // Lexicographic comparison
                const min_len = @min(slice_a.len, slice_b.len);
                for (slice_a[0..min_len], slice_b[0..min_len]) |ca, cb| {
                    if (ca < cb) return true;
                    if (ca > cb) return false;
                }
                return slice_a.len < slice_b.len;
            }
        };
        var first_error: ?anyerror = null;
        std.mem.sort(value.JSValue, temp, CompareCtx{ .allocator = ra, .first_error = &first_error }, CompareCtx.lessThan);
        if (first_error) |err| return err;
    }

    // Create result array with sorted elements
    const result = try ctx.createArray();
    result.prototype = ctx.array_prototype;

    for (temp, 0..) |val, idx| {
        try ctx.setIndexChecked(result, @intCast(idx), val);
    }
    result.setArrayLength(len);
    return result.toValue();
}

test "arrayToSorted sorts non-string elements without an allocator mismatch" {
    // Regression: the sort comparator coerces non-string elements to strings via
    // `valueToStringSimple` (a `createString` allocation) but freed them with
    // `allocator.destroy`, which releases only `@sizeOf(JSString)` instead of the
    // `@sizeOf(JSString) + len` block -- a size-mismatched free.
    // A self-managed DebugAllocator catches that mismatch at the point of the bad
    // free. It is deliberately not deinit'd: GC-managed JSObjects are not freed
    // individually in tests, and the resulting leak report is irrelevant here.
    var dbg: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = dbg.allocator();
    const gc_mod = @import("../gc.zig");
    const heap_mod = @import("../heap.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var heap_state = heap_mod.Heap.init(allocator, .{});
    defer heap_state.deinit();
    gc_state.setHeap(&heap_state);

    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const arr = try ctx.createArray();
    arr.prototype = ctx.array_prototype;
    try ctx.setIndexChecked(arr, 0, value.JSValue.fromInt(3));
    try ctx.setIndexChecked(arr, 1, value.JSValue.fromInt(1));
    try ctx.setIndexChecked(arr, 2, value.JSValue.fromInt(2));
    arr.setArrayLength(3);

    const sorted = try arrayToSorted(ctx, arr.toValue(), &.{});
    const sorted_obj = getObject(sorted) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), sorted_obj.getArrayLength());
    try std.testing.expectEqual(@as(i32, 1), (sorted_obj.getIndex(0) orelse value.JSValue.undefined_val).getInt());
    try std.testing.expectEqual(@as(i32, 2), (sorted_obj.getIndex(1) orelse value.JSValue.undefined_val).getInt());
    try std.testing.expectEqual(@as(i32, 3), (sorted_obj.getIndex(2) orelse value.JSValue.undefined_val).getInt());
}

const OneShotFailAllocator = struct {
    child: std.mem.Allocator,
    remaining_successes: usize,
    failed: bool = false,

    fn asAllocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!self.failed and self.remaining_successes == 0) {
            self.failed = true;
            return null;
        }
        if (!self.failed) self.remaining_successes -= 1;
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.child.rawFree(memory, alignment, return_address);
    }
};

test "arrayToSorted default comparator reports allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();
    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const arr = try ctx.createArray();
    try ctx.setIndexChecked(arr, 0, value.JSValue.fromInt(2));
    try ctx.setIndexChecked(arr, 1, value.JSValue.fromInt(1));
    arr.setArrayLength(2);

    var failing = OneShotFailAllocator{ .child = allocator, .remaining_successes = 1 };
    ctx.allocator = failing.asAllocator();
    _ = arrayToSorted(ctx, arr.toValue(), &.{}) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    return error.ExpectedOutOfMemory;
}

test "arrayReduce throws on empty array without initial value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");
    const heap_mod = @import("../heap.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var heap_state = heap_mod.Heap.init(allocator, .{});
    defer heap_state.deinit();
    gc_state.setHeap(&heap_state);

    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const callback = try ctx.createObject(null);
    callback.flags.is_callable = true;

    const arr = try ctx.createArray();
    arr.prototype = ctx.array_prototype;
    arr.setArrayLength(0);

    const with_initial = try arrayReduce(ctx, arr.toValue(), &.{ callback.toValue(), value.JSValue.fromInt(42) });
    try std.testing.expect(!ctx.hasException());
    try std.testing.expectEqual(@as(i32, 42), with_initial.getInt());

    const without_initial = try arrayReduce(ctx, arr.toValue(), &.{callback.toValue()});
    try std.testing.expect(without_initial.isException());
    try std.testing.expect(ctx.hasException());
}

test "arrayFilter rejects a non-boolean predicate result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const stub = struct {
        fn call(_: *context.Context, _: *object.JSObject, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.fromInt(1);
        }
    };
    http.setCallFunctionCallback(ctx, stub.call);
    defer http.clearCallFunctionCallback(ctx);

    const callback = try ctx.createObject(null);
    callback.flags.is_callable = true;
    const arr = try ctx.createArray();
    try ctx.setIndexChecked(arr, 0, value.JSValue.fromInt(1));
    arr.setArrayLength(1);

    const result = try arrayFilter(ctx, arr.toValue(), &.{callback.toValue()});
    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());
}

test "arrayToSorted ascending numeric comparator ENG5" {
    // Regression for ENG-5: a custom comparator `(a,b) => a-b` must drive the
    // ordering. The default string sort puts [10,2,1,33,4] in [1,10,2,33,4]
    // order; the comparator must instead yield ascending [1,2,4,10,33].
    var dbg: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const allocator = dbg.allocator();
    const gc_mod = @import("../gc.zig");
    const heap_mod = @import("../heap.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();

    var heap_state = heap_mod.Heap.init(allocator, .{});
    defer heap_state.deinit();
    gc_state.setHeap(&heap_state);

    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Stub comparator behaving like `(a,b) => a-b`.
    const stub = struct {
        fn call(_: *context.Context, _: *object.JSObject, call_args: []const value.JSValue) anyerror!value.JSValue {
            const a = call_args[0].getInt();
            const b = call_args[1].getInt();
            return value.JSValue.fromInt(a - b);
        }
    };
    http.setCallFunctionCallback(ctx, stub.call);
    defer http.clearCallFunctionCallback(ctx);

    // A callable function object to pass as the comparator argument.
    const cmp = try ctx.createObject(null);
    cmp.flags.is_callable = true;

    const arr = try ctx.createArray();
    arr.prototype = ctx.array_prototype;
    try ctx.setIndexChecked(arr, 0, value.JSValue.fromInt(10));
    try ctx.setIndexChecked(arr, 1, value.JSValue.fromInt(2));
    try ctx.setIndexChecked(arr, 2, value.JSValue.fromInt(1));
    try ctx.setIndexChecked(arr, 3, value.JSValue.fromInt(33));
    try ctx.setIndexChecked(arr, 4, value.JSValue.fromInt(4));
    arr.setArrayLength(5);

    const sorted = try arrayToSorted(ctx, arr.toValue(), &.{cmp.toValue()});
    const sorted_obj = getObject(sorted) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 5), sorted_obj.getArrayLength());
    const expected = [_]i32{ 1, 2, 4, 10, 33 };
    for (expected, 0..) |want, idx| {
        const got = (sorted_obj.getIndex(@intCast(idx)) orelse value.JSValue.undefined_val).getInt();
        try std.testing.expectEqual(want, got);
    }
}

test "arrayToSorted returns the comparator's error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();
    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const stub = struct {
        fn call(_: *context.Context, _: *object.JSObject, _: []const value.JSValue) anyerror!value.JSValue {
            return error.CallStackOverflow;
        }
    };
    http.setCallFunctionCallback(ctx, stub.call);
    defer http.clearCallFunctionCallback(ctx);

    const cmp = try ctx.createObject(null);
    cmp.flags.is_callable = true;
    const arr = try ctx.createArray();
    arr.prototype = ctx.array_prototype;
    try ctx.setIndexChecked(arr, 0, value.JSValue.fromInt(2));
    try ctx.setIndexChecked(arr, 1, value.JSValue.fromInt(1));
    arr.setArrayLength(2);

    try std.testing.expectError(error.CallStackOverflow, arrayToSorted(ctx, arr.toValue(), &.{cmp.toValue()}));
}

test "arrayIndexOf and arrayIncludes handle sparse arrays, cross-type numbers, and boxed NaN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();
    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Sparse array with overflow slots allocated smaller than length must not OOB-read.
    const sparse = try ctx.createArray();
    try sparse.setIndex(allocator, 8, value.JSValue.true_val);
    sparse.setArrayLength(100);
    const not_found = arrayIndexOf(ctx, sparse.toValue(), &.{value.JSValue.false_val});
    try std.testing.expectEqual(@as(i32, -1), not_found.getInt());
    const found_true = arrayIndexOf(ctx, sparse.toValue(), &.{value.JSValue.true_val});
    try std.testing.expectEqual(@as(i32, 8), found_true.getInt());

    // Numeric equality across int / float64 and -0.0 / +0.0.
    const nums = try ctx.createArray();
    try nums.setIndex(allocator, 0, value.JSValue.fromFloat(3.0));
    try nums.setIndex(allocator, 1, value.JSValue.fromFloat(-0.0));
    try nums.setIndex(allocator, 2, value.JSValue.fromFloat(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, 0), arrayIndexOf(ctx, nums.toValue(), &.{value.JSValue.fromInt(3)}).getInt());
    try std.testing.expectEqual(@as(i32, 1), arrayIndexOf(ctx, nums.toValue(), &.{value.JSValue.fromInt(0)}).getInt());
    try std.testing.expectEqual(@as(i32, -1), arrayIndexOf(ctx, nums.toValue(), &.{value.JSValue.fromFloat(std.math.nan(f64))}).getInt());
    try std.testing.expect(arrayIncludes(ctx, nums.toValue(), &.{value.JSValue.fromFloat(std.math.nan(f64))}).isTrue());
    try std.testing.expect(arrayIncludes(ctx, nums.toValue(), &.{value.JSValue.fromInt(3)}).isTrue());
}

test "arraySlice clamps start and end to array length and HOFs guard negative length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gc_mod = @import("../gc.zig");

    var gc_state = try gc_mod.GC.init(allocator, .{ .nursery_size = 8192 });
    defer gc_state.deinit();
    var ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const arr = try ctx.createArray();
    try arr.setIndex(allocator, 0, value.JSValue.fromInt(10));
    try arr.setIndex(allocator, 1, value.JSValue.fromInt(20));

    const sliced = arraySlice(ctx, arr.toValue(), &.{ value.JSValue.fromInt(0), value.JSValue.fromInt(1_000_000) });
    const sliced_obj = getObject(sliced) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), sliced_obj.getArrayLength());
    try std.testing.expectEqual(@as(i32, 10), sliced_obj.getIndex(0).?.getInt());
    try std.testing.expectEqual(@as(i32, 20), sliced_obj.getIndex(1).?.getInt());

    const stub = struct {
        fn call(_: *context.Context, _: *object.JSObject, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    };
    http.setCallFunctionCallback(ctx, stub.call);
    defer http.clearCallFunctionCallback(ctx);

    const cb = try ctx.createObject(null);
    cb.flags.is_callable = true;
    const neg_like = try ctx.createObject(null);
    try ctx.setPropertyChecked(neg_like, .length, value.JSValue.fromInt(-5));

    try std.testing.expect((try arrayEvery(ctx, neg_like.toValue(), &.{cb.toValue()})).isTrue());
    try std.testing.expect((try arraySome(ctx, neg_like.toValue(), &.{cb.toValue()})).isFalse());
    try std.testing.expect((try arrayFind(ctx, neg_like.toValue(), &.{cb.toValue()})).isUndefined());
    try std.testing.expectEqual(@as(i32, -1), (try arrayFindIndex(ctx, neg_like.toValue(), &.{cb.toValue()})).getInt());
}
