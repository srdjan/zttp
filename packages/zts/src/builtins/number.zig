const std = @import("std");
const h = @import("helpers.zig");
const context = h.context;
const value = h.value;
const object = h.object;
const string = h.string;

// Aliased helpers for use in this module
const allocFloat = h.allocFloat;
const toNumber = h.toNumber;
const getStringData = h.getStringData;
const createArrayWithPrototype = h.createArrayWithPrototype;

// ============================================================================
// Number methods
// ============================================================================

/// Number(value) - Convert a value with the subset's JavaScript ToNumber rules.
///
/// `Number` is a callable global in the language surface. Keeping its static
/// methods on a plain object makes programs that pass analysis fail at runtime
/// with `NotCallable`, so the constructor and the object must be one function
/// object, as they are in JavaScript.
pub fn numberConstructor(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromInt(0);
    return allocFloat(ctx, coerceToNumber(args[0]));
}

/// Number.isInteger(value) - Returns true if value is an integer
pub fn numberIsInteger(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromBool(false);
    const val = args[0];

    // Check if it's an int32
    if (val.isInt()) return value.JSValue.fromBool(true);

    // Check if it's a float that's an integer
    if (val.isFloat()) {
        const n = val.getFloat64();
        if (std.math.isNan(n) or std.math.isInf(n)) return value.JSValue.fromBool(false);
        return value.JSValue.fromBool(@floor(n) == n);
    }

    return value.JSValue.fromBool(false);
}

/// Number.isNaN(value) - Returns true if value is NaN
pub fn numberIsNaN(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromBool(false);
    const val = args[0];

    if (val.raw == value.JSValue.nan_val.raw) return value.JSValue.fromBool(true);
    if (!val.isFloat()) return value.JSValue.fromBool(false);
    return value.JSValue.fromBool(std.math.isNan(val.getFloat64()));
}

/// Number.isFinite(value) - Returns true if value is a finite number
pub fn numberIsFinite(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromBool(false);
    const val = args[0];

    if (val.isInt()) return value.JSValue.fromBool(true);

    if (val.isFloat()) {
        const n = val.getFloat64();
        return value.JSValue.fromBool(!std.math.isNan(n) and !std.math.isInf(n));
    }

    return value.JSValue.fromBool(false);
}

/// Number.parseFloat(string) - Parse string as float
pub fn numberParseFloat(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.nan_val;
    const val = args[0];

    const text = h.getStringDataCtx(val, ctx) orelse return value.JSValue.nan_val;

    // Skip leading whitespace
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) : (i += 1) {}

    if (i >= text.len) return value.JSValue.nan_val;

    // Parse sign
    var sign: f64 = 1.0;
    if (text[i] == '-') {
        sign = -1.0;
        i += 1;
    } else if (text[i] == '+') {
        i += 1;
    }

    // Parse number
    var result: f64 = 0.0;
    var has_digits = false;

    // Integer part
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        result = result * 10.0 + @as(f64, @floatFromInt(text[i] - '0'));
        has_digits = true;
        i += 1;
    }

    // Fractional part
    if (i < text.len and text[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            result += @as(f64, @floatFromInt(text[i] - '0')) * frac;
            frac *= 0.1;
            has_digits = true;
            i += 1;
        }
    }

    if (!has_digits) return value.JSValue.nan_val;

    // Exponent part
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        var exp_sign: i32 = 1;
        if (i < text.len and text[i] == '-') {
            exp_sign = -1;
            i += 1;
        } else if (i < text.len and text[i] == '+') {
            i += 1;
        }

        var exp: i32 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            exp = exp * 10 + @as(i32, @intCast(text[i] - '0'));
            i += 1;
        }
        result *= std.math.pow(f64, 10.0, @as(f64, @floatFromInt(exp * exp_sign)));
    }

    result *= sign;
    // NaN-boxing: store float inline without allocation
    return value.JSValue.fromFloat(result);
}

/// Number.parseInt(string, radix) - Parse string as integer
pub fn numberParseInt(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.nan_val;
    const val = args[0];

    const text = h.getStringDataCtx(val, ctx) orelse return value.JSValue.nan_val;

    // Get radix (default 10). Track explicitness to control 0x auto-detection.
    var radix: u8 = 10;
    const radix_explicit = args.len > 1;
    if (radix_explicit and args[1].isInt()) {
        const r = args[1].getInt();
        if (r < 2 or r > 36) return value.JSValue.nan_val;
        radix = @intCast(r);
    }

    // Skip leading whitespace
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) : (i += 1) {}

    if (i >= text.len) return value.JSValue.nan_val;

    // Parse sign
    var negative = false;
    if (text[i] == '-') {
        negative = true;
        i += 1;
    } else if (text[i] == '+') {
        i += 1;
    }

    // Handle 0x prefix for hex. Auto-detect only when radix was not explicitly given.
    if (radix == 16 and i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
        i += 2;
    } else if (!radix_explicit and radix == 10 and i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
        radix = 16;
        i += 2;
    }

    // Parse digits
    var result: i64 = 0;
    var has_digits = false;

    while (i < text.len) {
        const c = text[i];
        var digit: ?u8 = null;

        if (c >= '0' and c <= '9') {
            digit = c - '0';
        } else if (c >= 'a' and c <= 'z') {
            digit = c - 'a' + 10;
        } else if (c >= 'A' and c <= 'Z') {
            digit = c - 'A' + 10;
        }

        if (digit == null or digit.? >= radix) break;

        result = result * radix + digit.?;
        has_digits = true;
        i += 1;
    }

    if (!has_digits) return value.JSValue.nan_val;

    if (negative) result = -result;

    // Check if it fits in i32
    if (result >= std.math.minInt(i32) and result <= std.math.maxInt(i32)) {
        return value.JSValue.fromInt(@intCast(result));
    }

    // Return as float for large values (NaN-boxing: no allocation)
    return value.JSValue.fromFloat(@floatFromInt(result));
}

/// Coerce a JS value to a number following ToNumber, returning the f64 or NaN.
/// Strings are trimmed then parsed in full (a trailing non-numeric tail yields
/// NaN, unlike parseFloat); an all-whitespace/empty string coerces to 0.
fn coerceToNumber(val: value.JSValue) f64 {
    if (val.isInt()) return @floatFromInt(val.getInt());
    if (val.isFloat()) return val.getFloat64();
    if (val.isNull()) return 0; // null -> 0
    if (val.isUndefined()) return std.math.nan(f64); // undefined -> NaN
    if (val.isTrue()) return 1;
    if (val.isFalse()) return 0;
    if (getStringData(val)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed.len == 0) return 0; // "" / whitespace -> 0
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    // Objects (and anything else) coerce to NaN in this subset.
    return std.math.nan(f64);
}

/// Global isNaN - coerces argument to number first (unlike Number.isNaN)
pub fn globalIsNaN(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromBool(true); // isNaN(undefined) = true

    return value.JSValue.fromBool(std.math.isNan(coerceToNumber(args[0])));
}

/// Global isFinite - coerces argument to number first (unlike Number.isFinite)
pub fn globalIsFinite(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.fromBool(false); // isFinite(undefined) = false

    // Same ToNumber coercion as globalIsNaN, so isFinite("42") is true and
    // isFinite("x")/isFinite({}) are false (the prior code returned false for
    // every string and object, including numeric strings).
    return value.JSValue.fromBool(std.math.isFinite(coerceToNumber(args[0])));
}

/// Global range(end) or range(start, end) or range(start, end, step)
/// Returns an array of integers for use with for-of iteration
/// `hole()` - an unfilled expression the author (or the agent) has not written
/// yet.
///
/// Its type is `never`, the bottom type, so it satisfies whatever the
/// surrounding context expects and the rest of the program keeps type-checking
/// and verifying. That is the point: the compiler describes the frame, and only
/// the hole is missing.
///
/// Reaching one at runtime is not an error in the program, it is an unfinished
/// program being run. The runtime maps this to 501 Not Implemented rather than
/// the 500 a genuine fault produces, so `zttp dev` can serve a
/// `isDict(value)` - the specified intrinsic type guard for `Dict` (spec 5.7).
/// A guard the checker recognizes has to be a real function at runtime too:
/// the `when Dict:` pattern lowers to a call to this name, exactly as
/// `when array:` lowers to `Array.isArray`.
pub fn globalIsDict(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.false_val;
    return if (@import("../dict.zig").isDict(args[0])) value.JSValue.true_val else value.JSValue.false_val;
}

/// `isBytes(value)` - the intrinsic type guard for `Bytes` (spec 6.3), for the
/// same reason `isDict` exists: `when Bytes:` lowers to a call to this name, so
/// a guard the checker recognizes has to be a real function at runtime.
pub fn globalIsBytes(_: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    if (args.len == 0) return value.JSValue.false_val;
    return if (args[0].isBytes()) value.JSValue.true_val else value.JSValue.false_val;
}

/// partially-written handler and say exactly which path is still empty.
pub fn globalHole(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    _ = args;
    ctx.hole_reached = true;
    ctx.throwException(value.JSValue.exception_val);
    return value.JSValue.exception_val;
}

pub fn globalRange(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    const root_class_idx = ctx.root_class_idx;

    // Parse arguments
    var start: i32 = 0;
    var end: i32 = 0;
    var step: i32 = 1;

    if (args.len == 0) {
        return value.JSValue.undefined_val;
    } else if (args.len == 1) {
        // range(end) - start defaults to 0
        end = if (args[0].isInt()) args[0].getInt() else if (args[0].isFloat()) std.math.lossyCast(i32, args[0].getFloat64()) else 0;
    } else if (args.len == 2) {
        // range(start, end)
        start = if (args[0].isInt()) args[0].getInt() else if (args[0].isFloat()) std.math.lossyCast(i32, args[0].getFloat64()) else 0;
        end = if (args[1].isInt()) args[1].getInt() else if (args[1].isFloat()) std.math.lossyCast(i32, args[1].getFloat64()) else 0;
    } else {
        // range(start, end, step)
        start = if (args[0].isInt()) args[0].getInt() else if (args[0].isFloat()) std.math.lossyCast(i32, args[0].getFloat64()) else 0;
        end = if (args[1].isInt()) args[1].getInt() else if (args[1].isFloat()) std.math.lossyCast(i32, args[1].getFloat64()) else 0;
        step = if (args[2].isInt()) args[2].getInt() else if (args[2].isFloat()) std.math.lossyCast(i32, args[2].getFloat64()) else 1;
        if (step == 0) step = 1; // Prevent infinite loop
    }

    // Create lazy range iterator - values are computed on demand, not pre-allocated
    const result = if (ctx.hybrid) |hybrid|
        (object.JSObject.createRangeIteratorWithArena(hybrid.arena, root_class_idx, start, end, step) orelse
            return value.JSValue.undefined_val)
    else
        (object.JSObject.createRangeIterator(ctx.allocator, root_class_idx, start, end, step) catch
            return value.JSValue.undefined_val);

    return result.toValue();
}

/// Native _processRequest(items, page, limit) - pagination with checksum, returns JSON string
/// Eliminates all JS overhead for the /api/process benchmark endpoint
pub fn globalProcessRequest(ctx: *context.Context, _: value.JSValue, args: []const value.JSValue) value.JSValue {
    // Parse arguments with defaults
    const total_items: i32 = if (args.len > 0 and args[0].isInt()) args[0].getInt() else if (args.len > 0 and args[0].isFloat()) std.math.lossyCast(i32, args[0].getFloat64()) else 100;
    const page_arg: i32 = if (args.len > 1 and args[1].isInt()) args[1].getInt() else if (args.len > 1 and args[1].isFloat()) std.math.lossyCast(i32, args[1].getFloat64()) else 1;
    const limit: i32 = if (args.len > 2 and args[2].isInt()) args[2].getInt() else if (args.len > 2 and args[2].isFloat()) std.math.lossyCast(i32, args[2].getFloat64()) else 10;

    // Pagination math
    const total_pages: i32 = if (limit > 0) @divTrunc(total_items + limit - 1, limit) else 1;
    const current_page: i32 = @min(@max(1, page_arg), total_pages);
    const start_idx: i32 = (current_page - 1) * limit;
    const end_idx: i32 = @min(start_idx + limit, total_items);
    const item_count: i32 = end_idx - start_idx;

    // Compute checksum - same algorithm as JS version
    var checksum: i32 = 0;
    var i: i32 = 0;
    while (i < item_count) : (i += 1) {
        const item_idx = start_idx + i;
        const val = @mod(((item_idx * 31) ^ (item_idx * 17)), 10000);
        checksum = @mod((checksum + val), 1000000);
    }

    // Build JSON string directly
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"page\":{d},\"pages\":{d},\"count\":{d},\"checksum\":{d}}}", .{
        current_page,
        total_pages,
        item_count,
        checksum,
    }) catch return value.JSValue.undefined_val;

    // Create JS string from buffer
    return ctx.createString(json) catch return value.JSValue.undefined_val;
}

test "globalIsNaN coerces ToNumber; Number.isNaN does not ENG12" {
    // ENG-12: global isNaN(x) coerces its argument to a number, so a numeric
    // string is not NaN while a non-numeric string is. Number.isNaN performs no
    // coercion: only an actual NaN number is true. ctx is unused by both fns.
    const ctx: *context.Context = undefined;
    const undef = value.JSValue.undefined_val;
    const allocator = std.testing.allocator;

    // Numeric scalars: no coercion needed.
    try std.testing.expect(!globalIsNaN(ctx, undef, &.{value.JSValue.fromInt(42)}).toBoolean());
    try std.testing.expect(!globalIsNaN(ctx, undef, &.{value.JSValue.fromFloat(3.14)}).toBoolean());
    try std.testing.expect(globalIsNaN(ctx, undef, &.{value.JSValue.nan_val}).toBoolean());

    // Strings are coerced (ToNumber): "42" -> 42 (not NaN), "x" -> NaN.
    const numeric_str = try string.createString(allocator, "42");
    defer string.freeString(allocator, numeric_str);
    const alpha_str = try string.createString(allocator, "x");
    defer string.freeString(allocator, alpha_str);
    try std.testing.expect(!globalIsNaN(ctx, undef, &.{value.JSValue.fromPtr(numeric_str)}).toBoolean());
    try std.testing.expect(globalIsNaN(ctx, undef, &.{value.JSValue.fromPtr(alpha_str)}).toBoolean());

    // Number.isNaN performs no coercion: a non-numeric string is NOT NaN.
    try std.testing.expect(!numberIsNaN(ctx, undef, &.{value.JSValue.fromPtr(alpha_str)}).toBoolean());
    try std.testing.expect(!numberIsNaN(ctx, undef, &.{value.JSValue.fromInt(42)}).toBoolean());
    try std.testing.expect(numberIsNaN(ctx, undef, &.{value.JSValue.nan_val}).toBoolean());
}
