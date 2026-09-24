//! The schema keywords `zttp:validate` compiles (M4 T7 U2).
//!
//! `schemaCompile` refuses a schema that holds any other keyword, and it does
//! so at runtime, by returning `false`. A later `validateJson` with that name
//! then fails on every input, which no analysis saw. The builder reads this
//! list to refuse that call at build time instead (ZTS514).
//!
//! `packages/modules/src/security/validate.zig` owns the real list, and the
//! builder cannot import it: `zts-compiler` sits above the SDK modules. A test
//! in `builtin_modules.zig`, which sees both, pins this copy to that one.
//!
//! This file imports `std` only, so it lives in `zts-base`.

const std = @import("std");

/// Every key a schema object may hold under `zttp:validate`, in the order
/// `validate.zig` lists them.
pub const supported = [_][]const u8{
    "type",
    "minLength",
    "maxLength",
    "maxItems",
    "minimum",
    "maximum",
    "required",
    "properties",
    "items",
    "enum",
    "format",
    "$schema",
    "title",
    "description",
};

fn isSupported(key: []const u8) bool {
    for (supported) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// The first key `zttp:validate` would refuse in `schema`, searching the
/// object, each value under `properties`, and `items`, as the compiler walks
/// them. Null when every key is supported. A schema that is not a JSON object
/// is answered with "(not an object)".
pub fn firstUnsupported(schema: std.json.Value) ?[]const u8 {
    if (schema != .object) return "(not an object)";
    var it = schema.object.iterator();
    while (it.next()) |entry| {
        if (!isSupported(entry.key_ptr.*)) return entry.key_ptr.*;
    }
    if (schema.object.get("properties")) |props| {
        if (props == .object) {
            var prop_it = props.object.iterator();
            while (prop_it.next()) |entry| {
                if (firstUnsupported(entry.value_ptr.*)) |key| return key;
            }
        }
    }
    if (schema.object.get("items")) |items| {
        if (firstUnsupported(items)) |key| return key;
    }
    return null;
}

test "firstUnsupported names the first keyword zttp:validate refuses" {
    const cases = [_]struct { text: []const u8, expected: ?[]const u8 }{
        .{ .text = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"maxLength\":4}}}", .expected = null },
        .{ .text = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}", .expected = "additionalProperties" },
        .{ .text = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"pattern\":\"x\"}}}", .expected = "pattern" },
        .{ .text = "{\"type\":\"array\",\"items\":{\"type\":\"object\",\"minItems\":1}}", .expected = "minItems" },
        .{ .text = "[1]", .expected = "(not an object)" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.text, .{});
        defer parsed.deinit();
        try std.testing.expectEqualDeep(case.expected, firstUnsupported(parsed.value));
    }
}
