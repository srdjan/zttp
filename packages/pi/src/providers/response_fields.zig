//! Identical response-field and tool-argument validation for both Chat Completions providers.

const std = @import("std");
const turn = @import("../turn.zig");

pub const max_tool_args_bytes: usize = 256 * 1024;
pub const max_tool_name_bytes: usize = 128;
pub const max_value_depth: usize = 16;

pub fn optionalString(value: ?std.json.Value) !?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .null => null,
        .string => |text| text,
        else => error.UnexpectedResponseShape,
    };
}

pub fn requiredString(value: ?std.json.Value) ![]const u8 {
    return (try optionalString(value)) orelse error.MalformedToolCall;
}

pub fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

pub fn decodeUsage(value: ?std.json.Value) !turn.Usage {
    const present = value orelse return .{};
    if (present == .null) return .{};
    if (present != .object) return error.UnexpectedResponseShape;
    return .{
        .input_tokens = try optionalTokenCount(present.object.get("prompt_tokens")),
        .output_tokens = try optionalTokenCount(present.object.get("completion_tokens")),
    };
}

fn optionalTokenCount(value: ?std.json.Value) !u64 {
    const present = value orelse return 0;
    if (present != .integer or present.integer < 0) return error.UnexpectedResponseShape;
    return @intCast(present.integer);
}

pub fn validateJsonArguments(arena: std.mem.Allocator, args: []const u8) !void {
    if (args.len > max_tool_args_bytes) return error.MalformedToolCall;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_tool_args_bytes,
    }) catch return error.MalformedToolCall;
    if (value != .object) return error.MalformedToolCall;
    try validateJsonDepth(value, 0);
}

fn validateJsonDepth(value: std.json.Value, depth: usize) !void {
    if (depth > max_value_depth) return error.MalformedToolCall;
    switch (value) {
        .array => |items| for (items.items) |item| try validateJsonDepth(item, depth + 1),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateJsonDepth(entry.value_ptr.*, depth + 1);
        },
        else => {},
    }
}

pub fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_tool_name_bytes or !isIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| if (!isIdentifierContinue(byte)) return false;
    return true;
}

pub fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

pub fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-';
}
