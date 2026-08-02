//! Pure decoding for OpenAI Responses API requests sent to the stand-in.

const std = @import("std");

pub const ParsedRequest = struct {
    ask: []const u8,
    step_index: usize,
    source: []const u8,
};

pub const ParseError = error{
    InvalidRequest,
    MissingAsk,
};

pub fn parse(arena: std.mem.Allocator, body: []const u8) !ParsedRequest {
    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return ParseError.InvalidRequest,
    };
    if (root_value != .object) return ParseError.InvalidRequest;
    const input_value = root_value.object.get("input") orelse return ParseError.InvalidRequest;
    if (input_value != .array) return ParseError.InvalidRequest;

    var ask: ?[]const u8 = null;
    var step_index: usize = 0;
    var source: []const u8 = "";

    for (input_value.array.items) |item_value| {
        if (item_value != .object) return ParseError.InvalidRequest;
        const item = item_value.object;

        if (item.get("type")) |type_value| {
            if (type_value != .string) return ParseError.InvalidRequest;
            if (std.mem.eql(u8, type_value.string, "function_call_output")) {
                step_index += 1;
                if (item.get("output")) |output_value| {
                    if (output_value != .string) return ParseError.InvalidRequest;
                    if (try readSource(arena, output_value.string)) |content| source = content;
                }
            }
        }

        if (ask == null and isUserMessage(item)) {
            const text = try readInputText(item);
            if (!std.mem.startsWith(u8, text, "[expert workflow]")) ask = text;
        }
    }

    return .{
        .ask = ask orelse return ParseError.MissingAsk,
        .step_index = step_index,
        .source = source,
    };
}

fn isUserMessage(item: std.json.ObjectMap) bool {
    const role = item.get("role") orelse return false;
    return role == .string and std.mem.eql(u8, role.string, "user");
}

fn readInputText(item: std.json.ObjectMap) ![]const u8 {
    const content_value = item.get("content") orelse return ParseError.InvalidRequest;
    if (content_value != .array) return ParseError.InvalidRequest;
    for (content_value.array.items) |part_value| {
        if (part_value != .object) return ParseError.InvalidRequest;
        const part = part_value.object;
        const type_value = part.get("type") orelse continue;
        if (type_value != .string) return ParseError.InvalidRequest;
        if (!std.mem.eql(u8, type_value.string, "input_text")) continue;
        const text_value = part.get("text") orelse return ParseError.InvalidRequest;
        if (text_value != .string) return ParseError.InvalidRequest;
        return text_value.string;
    }
    return ParseError.InvalidRequest;
}

fn readSource(arena: std.mem.Allocator, output: []const u8) !?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (value != .object) return null;
    const content = value.object.get("content") orelse return null;
    if (content != .string) return null;
    return content.string;
}

const testing = std.testing;

test "stand-in request parsing recovers the ask, source, and stateless step index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"role":"user","content":[{"type":"input_text","text":"[expert workflow] kind=route_add"}]},
        \\  {"type":"function_call","call_id":"call-0","name":"workspace_read_file","arguments":"{\"path\":\"handler.ts\"}"},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"[]"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Add a GET /health route to handler.ts", parsed.ask);
    try testing.expectEqual(@as(usize, 2), parsed.step_index);
    try testing.expectEqualStrings("function handler() {}", parsed.source);
}
