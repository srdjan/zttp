//! Pure decoding for OpenAI Responses API requests sent to the stand-in.

const std = @import("std");

pub const ParsedRequest = struct {
    ask: []const u8,
    step_index: usize,
    /// The target file's bytes, recovered from a read tool's output.
    ///
    /// Null means no read has succeeded yet, which is NOT the same as an empty
    /// file. The loop caps a tool result at 32 KiB, so the output for a large
    /// file is truncated and no longer parses as JSON, and a failed read
    /// returns plain text with no `content` field. Both arrive here as null. A
    /// playbook that authored from "" in those cases would rewrite the file
    /// from nothing, and the veto would not object because an empty `before`
    /// makes an empty baseline.
    source: ?[]const u8 = null,
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
    var source: ?[]const u8 = null;

    // Everything here is scoped to the CURRENT turn, and a plain user message
    // is what starts one. The transcript is cumulative, so counting across the
    // whole array would carry the previous task's tool outputs into this one:
    // a second ask in the same session would start past the end of its own
    // playbook and answer the first ask's question.
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

        if (isUserMessage(item)) {
            const text = try readInputText(item);
            // The workflow note rides along as a second user message on the
            // same turn, so it must not reset the turn it belongs to.
            if (!std.mem.startsWith(u8, text, "[expert workflow]")) {
                ask = text;
                step_index = 0;
                source = null;
            }
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
    try testing.expectEqualStrings("function handler() {}", parsed.source.?);
}

test "stand-in request parsing scopes the turn to the latest ask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A completed add-route turn followed by a fresh ask. Counting across the
    // whole transcript would report step 4 and answer the first question.
    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"content\":\"function handler() {}\"}"},
        \\  {"type":"function_call_output","call_id":"call-1","output":"[]"},
        \\  {"type":"function_call_output","call_id":"call-2","output":"{\"ok\":true}"},
        \\  {"role":"user","content":[{"type":"input_text","text":"Explain what this handler does"}]},
        \\  {"role":"user","content":[{"type":"input_text","text":"[expert workflow] kind=review_explain"}]}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqualStrings("Explain what this handler does", parsed.ask);
    try testing.expectEqual(@as(usize, 0), parsed.step_index);
    try testing.expect(parsed.source == null);
}

test "stand-in request parsing reports an unrecoverable read as null, not empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // What a >32 KiB file looks like after the loop truncates the tool result:
    // no longer valid JSON, so no content can be recovered. Authoring from ""
    // here would overwrite the user's file with a stub.
    const body =
        \\{"model":"standin","input":[
        \\  {"role":"user","content":[{"type":"input_text","text":"Add a GET /health route to handler.ts"}]},
        \\  {"type":"function_call_output","call_id":"call-0","output":"{\"ok\":true,\"content\":\"function han ...[truncated 40000 bytes]"}
        \\]}
    ;

    const parsed = try parse(arena.allocator(), body);
    try testing.expectEqual(@as(usize, 1), parsed.step_index);
    try testing.expect(parsed.source == null);
}
