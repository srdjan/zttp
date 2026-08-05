//! Typed JSON wire helpers for compatibility-sensitive decoders.
//!
//! `std.json` remains the only JSON parser. These wrappers retain the exact
//! source bytes for strings and embedded JSON values so projection code can
//! preserve legacy domain and serialization behavior.

const std = @import("std");

pub const String = struct {
    bytes: []const u8,

    pub fn jsonParse(
        _: std.mem.Allocator,
        source: anytype,
        _: std.json.ParseOptions,
    ) !String {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        const start = source.cursor + 1;
        try source.skipValue();
        return .{ .bytes = source.input[start .. source.cursor - 1] };
    }
};

pub const RawValue = struct {
    bytes: []const u8,

    pub fn jsonParse(
        _: std.mem.Allocator,
        source: anytype,
        _: std.json.ParseOptions,
    ) !RawValue {
        _ = try source.peekNextTokenType();
        const start = source.cursor;
        try source.skipValue();
        return .{ .bytes = source.input[start..source.cursor] };
    }
};

pub fn RawArrayHashMap(comptime T: type) type {
    return struct {
        pub const Entry = struct {
            key: String,
            value: T,
        };

        entries: []const Entry = &.{},

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            if (try source.next() != .object_begin) return error.UnexpectedToken;

            var entries: std.ArrayList(Entry) = .empty;
            var entry_indexes: std.StringHashMapUnmanaged(usize) = .empty;
            defer entry_indexes.deinit(allocator);
            while (true) {
                if (try source.peekNextTokenType() == .object_end) {
                    _ = try source.next();
                    return .{ .entries = try entries.toOwnedSlice(allocator) };
                }

                const key = try String.jsonParse(allocator, source, options);
                const value = try parseValue(T, allocator, source, options);
                const indexed = try entry_indexes.getOrPut(allocator, key.bytes);
                if (indexed.found_existing) {
                    const entry = &entries.items[indexed.value_ptr.*];
                    switch (options.duplicate_field_behavior) {
                        .use_first => {},
                        .@"error" => return error.DuplicateField,
                        .use_last => entry.value = value,
                    }
                } else {
                    indexed.value_ptr.* = entries.items.len;
                    try entries.append(allocator, .{ .key = key, .value = value });
                }
            }
        }
    };
}

fn parseValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !T {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "jsonParse")) {
                return std.json.innerParse(T, allocator, source, options);
            }
            var value: T = .{};
            try parseStructInto(T, allocator, source, options, &value, false);
            return value;
        },
        .optional => |optional| {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return null;
            }
            return try parseValue(optional.child, allocator, source, options);
        },
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child == u8) {
                return std.json.innerParse(T, allocator, source, options);
            }
            if (try source.next() != .array_begin) return error.UnexpectedToken;
            var values: std.ArrayList(pointer.child) = .empty;
            while (try source.peekNextTokenType() != .array_end) {
                try values.append(allocator, try parseValue(pointer.child, allocator, source, options));
            }
            _ = try source.next();
            return try values.toOwnedSlice(allocator);
        },
        else => return std.json.innerParse(T, allocator, source, options),
    }
}

fn parseStructInto(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
    value: *T,
    merge_existing: bool,
) !void {
    if (try source.next() != .object_begin) return error.UnexpectedToken;
    const fields = std.meta.fields(T);
    var seen = [_]bool{false} ** fields.len;
    while (try source.peekNextTokenType() != .object_end) {
        const key = try String.jsonParse(allocator, source, options);
        if (!try parseKnownField(T, allocator, source, options, key.bytes, value, &seen, merge_existing)) {
            try source.skipValue();
        }
    }
    _ = try source.next();
}

fn parseKnownField(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
    key: []const u8,
    value: *T,
    seen: *[std.meta.fields(T).len]bool,
    merge_existing: bool,
) !bool {
    inline for (std.meta.fields(T), 0..) |field, field_index| {
        if (std.mem.eql(u8, key, field.name)) {
            if (seen[field_index]) switch (options.duplicate_field_behavior) {
                .use_first => {
                    try source.skipValue();
                    return true;
                },
                .@"error" => return error.DuplicateField,
                .use_last => {},
            };

            const Field = field.type;
            if ((seen[field_index] or merge_existing) and comptime hasMergeParser(Field)) {
                try Field.jsonParseInto(allocator, source, options, &@field(value, field.name));
            } else if ((seen[field_index] or merge_existing) and comptime isRepeatedSlice(Field)) {
                const next = try parseValue(Field, allocator, source, options);
                @field(value, field.name) = try appendRepeatedSlice(Field, allocator, @field(value, field.name), next);
            } else if ((seen[field_index] or merge_existing) and comptime isRawStruct(Field)) {
                try parseStructInto(Field, allocator, source, options, &@field(value, field.name), true);
            } else {
                @field(value, field.name) = try parseValue(Field, allocator, source, options);
            }
            seen[field_index] = true;
            return true;
        }
    }
    return false;
}

fn hasMergeParser(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "jsonParseInto"),
        else => false,
    };
}

fn isRawStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => !@hasDecl(T, "jsonParse"),
        else => false,
    };
}

fn isRepeatedSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.child != u8,
        else => false,
    };
}

fn appendRepeatedSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    previous: T,
    next: T,
) !T {
    const Child = @typeInfo(T).pointer.child;
    const joined = try allocator.alloc(Child, previous.len + next.len);
    @memcpy(joined[0..previous.len], previous);
    @memcpy(joined[previous.len..], next);
    return joined;
}

/// An unsigned JSON integer that preserves the legacy decoder's overflow
/// behavior: decimal digits are consumed, but an out-of-range value projects
/// as null so the owning field can apply its documented default.
pub fn Unsigned(comptime T: type) type {
    return struct {
        value: ?T,

        pub fn jsonParse(
            _: std.mem.Allocator,
            source: anytype,
            _: std.json.ParseOptions,
        ) !@This() {
            if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
            const start = source.cursor;
            try source.skipValue();
            const raw = source.input[start..source.cursor];
            for (raw) |byte| {
                if (byte < '0' or byte > '9') return error.UnexpectedToken;
            }
            return .{ .value = std.fmt.parseInt(T, raw, 10) catch null };
        }
    };
}

/// An optional wire field whose explicit JSON value must be non-null.
/// `value == null` means the object omitted the field entirely.
pub fn OptionalNonNull(comptime T: type) type {
    return struct {
        value: ?T = null,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            if (try source.peekNextTokenType() == .null) return error.UnexpectedToken;
            return .{ .value = try parseValue(T, allocator, source, options) };
        }
    };
}

/// A required array field that appends values when the same key occurs more
/// than once in one object. Explicit null is invalid.
pub fn AppendedNonNull(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slice = []const T;

        value: ?Slice = null,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            if (try source.peekNextTokenType() == .null) return error.UnexpectedToken;
            return .{ .value = try parseValue(Slice, allocator, source, options) };
        }

        pub fn jsonParseInto(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
            result: *Self,
        ) !void {
            if (try source.peekNextTokenType() == .null) return error.UnexpectedToken;
            const next = try parseValue(Slice, allocator, source, options);
            result.value = if (result.value) |previous|
                try appendRepeatedSlice(Slice, allocator, previous, next)
            else
                next;
        }
    };
}

/// An optional object that preserves fields accumulated across repeated
/// occurrences. Explicit null is a no-op, matching legacy section parsers.
pub fn MergedOptional(comptime T: type) type {
    return struct {
        const Self = @This();

        value: ?T = null,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return .{};
            }
            return .{ .value = try parseValue(T, allocator, source, options) };
        }

        pub fn jsonParseInto(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
            result: *Self,
        ) !void {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return;
            }
            if (result.value) |*value| {
                try parseStructInto(T, allocator, source, options, value, true);
            } else {
                result.value = try parseValue(T, allocator, source, options);
            }
        }
    };
}

/// An optional array that appends values across repeated occurrences.
/// Explicit null is a no-op, matching legacy collection parsers.
pub fn AppendedOptional(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slice = []const T;

        value: ?Slice = null,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return .{};
            }
            return .{ .value = try parseValue(Slice, allocator, source, options) };
        }

        pub fn jsonParseInto(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
            result: *Self,
        ) !void {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return;
            }
            const next = try parseValue(Slice, allocator, source, options);
            result.value = if (result.value) |previous|
                try appendRepeatedSlice(Slice, allocator, previous, next)
            else
                next;
        }
    };
}

/// An optional object whose repeated occurrences are combined by a caller
/// supplied pure reducer. Explicit null is a no-op.
pub fn FoldedOptional(
    comptime T: type,
    comptime combine: fn (*T, T) void,
) type {
    return struct {
        const Self = @This();

        value: ?T = null,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return .{};
            }
            return .{ .value = try parseValue(T, allocator, source, options) };
        }

        pub fn jsonParseInto(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
            result: *Self,
        ) !void {
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return;
            }
            const next = try parseValue(T, allocator, source, options);
            if (result.value) |*previous| {
                combine(previous, next);
            } else {
                result.value = next;
            }
        }
    };
}

pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: []const u8,
) error{ InvalidJson, OutOfMemory }!std.json.Parsed(T) {
    var scanner = std.json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();

    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const options: std.json.ParseOptions = .{
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = true,
        .max_value_len = source.len,
        .allocate = .alloc_if_needed,
    };
    const value = parseValue(T, arena.allocator(), &scanner, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return .{ .arena = arena, .value = value };
}

test "typed wire retains raw strings and trailing compatibility" {
    const Fixture = struct {
        name: String = .{ .bytes = "" },
    };
    var parsed = try parse(Fixture, std.testing.allocator, "{\"name\":\"a\\n\\u0062\"} trailing");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\\n\\u0062", parsed.value.name.bytes);
}

test "typed wire unsigned values distinguish overflow from malformed numbers" {
    const Fixture = struct {
        value: Unsigned(u16) = .{ .value = null },
    };
    var overflow = try parse(Fixture, std.testing.allocator, "{\"value\":999999}");
    defer overflow.deinit();
    try std.testing.expectEqual(@as(?u16, null), overflow.value.value.value);
    try std.testing.expectError(error.InvalidJson, parse(Fixture, std.testing.allocator, "{\"value\":1.5}"));
}

test "typed wire map retains raw keys and replaces exact duplicates" {
    const Fixture = struct {
        values: RawArrayHashMap(bool) = .{},
    };
    var parsed = try parse(
        Fixture,
        std.testing.allocator,
        "{\"values\":{\"a\":true,\"\\u0061\":false,\"a\":false}}",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.values.entries.len);
    try std.testing.expectEqualStrings("a", parsed.value.values.entries[0].key.bytes);
    try std.testing.expect(!parsed.value.values.entries[0].value);
    try std.testing.expectEqualStrings("\\u0061", parsed.value.values.entries[1].key.bytes);
}

test "typed wire rejects explicit null for optional non-null fields" {
    const Fixture = struct {
        proof: OptionalNonNull(String) = .{},
    };
    var absent = try parse(Fixture, std.testing.allocator, "{}");
    defer absent.deinit();
    try std.testing.expectEqual(@as(?String, null), absent.value.proof.value);
    try std.testing.expectError(error.InvalidJson, parse(Fixture, std.testing.allocator, "{\"proof\":null}"));
}

test "typed wire merges optional objects and appends optional arrays" {
    const Section = struct {
        first: bool = false,
        second: bool = false,
    };
    const Fixture = struct {
        section: MergedOptional(Section) = .{},
        values: AppendedOptional(String) = .{},
    };
    var parsed = try parse(
        Fixture,
        std.testing.allocator,
        "{\"section\":{\"first\":true},\"section\":null,\"section\":{\"second\":true}," ++
            "\"values\":[\"a\"],\"values\":null,\"values\":[\"b\"]}",
    );
    defer parsed.deinit();

    const section = parsed.value.section.value orelse unreachable;
    try std.testing.expect(section.first);
    try std.testing.expect(section.second);
    const values = parsed.value.values.value orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("a", values[0].bytes);
    try std.testing.expectEqualStrings("b", values[1].bytes);
}
