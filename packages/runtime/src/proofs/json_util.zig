const std = @import("std");

pub fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

// getI64 reads an integer field, tolerating floats emitted by JSON serializers
// that upcast large numbers. Floats are truncated toward zero. Returns null if
// the key is absent or the value is not numeric.
pub fn getI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        // Guard before @intFromFloat: a non-finite or out-of-i64 float (read
        // from a possibly-corrupt on-disk ledger) would otherwise be illegal
        // behavior. The i64 bounds use exact powers of two representable as f64.
        .float => |f| if (!std.math.isFinite(f) or f >= 9223372036854775808.0 or f < -9223372036854775808.0)
            null
        else
            @intFromFloat(f),
        else => null,
    };
}
