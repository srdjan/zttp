//! Client-side keyword filter over the schema-v2 rule discovery envelope.
//!
//! The compiler protocol remains the only rule authority. This convenience
//! tool requests the complete `describe_rule` result, filters its `rules`
//! array without changing rule objects or envelope identity, and returns that
//! complete version-2 envelope.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_search";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "search rules",
    .effect = .analyze,
    .context_policy = .exact,
    .description = "Search schema-v2 diagnostic rules by keyword substring across name, description, and help.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Case-sensitive keyword substring to search for.\"}},\"required\":[\"query\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "query");
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 1) {
        return registry_mod.ToolResult.err(allocator, name ++ " requires one keyword argument\n");
    }

    const projection = try client.invokeForTool(allocator, .{
        .operation = .describe_rule,
        .input_json = "{}",
    });
    if (!projection.ok) return .{ .ok = false, .llm_text = projection.llm_text };
    defer allocator.free(projection.llm_text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, projection.llm_text, .{}) catch
        return error.MalformedProtocolResponse;
    defer parsed.deinit();
    const payload = parsed.value.object.getPtr("payload") orelse return error.MalformedProtocolResponse;
    if (payload.* != .object) return error.MalformedProtocolResponse;
    const rules = payload.object.getPtr("rules") orelse return error.MalformedProtocolResponse;
    if (rules.* != .array) return error.MalformedProtocolResponse;

    var kept: usize = 0;
    for (rules.array.items) |rule| {
        if (!ruleMatches(rule, args[0])) continue;
        rules.array.items[kept] = rule;
        kept += 1;
    }
    rules.array.shrinkRetainingCapacity(kept);

    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.write(parsed.value);
    try out.writer().writeByte('\n');
    return .{ .ok = true, .llm_text = try out.toOwnedSlice() };
}

fn ruleMatches(value: std.json.Value, query: []const u8) bool {
    if (value != .object) return false;
    const fields = [_][]const u8{ "name", "description", "help" };
    for (fields) |field| {
        const candidate = value.object.get(field) orelse continue;
        if (candidate == .string and std.mem.indexOf(u8, candidate.string, query) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "missing keyword returns not-ok body" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "requires one keyword") != null);
}

test "search preserves the version-2 envelope and filters rules" {
    var result = try execute(testing.allocator, &.{"result"});
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), root.get("schema_version").?.integer);
    try testing.expectEqualStrings("describe_rule", root.get("operation").?.string);
    try testing.expectEqual(@as(usize, 64), root.get("policy_hash").?.string.len);
    const rules = root.get("payload").?.object.get("rules").?.array;
    try testing.expect(rules.items.len >= 1);
    for (rules.items) |rule| try testing.expect(ruleMatches(rule, "result"));
}

test "search with no matches preserves an empty version-2 rules payload" {
    var result = try execute(testing.allocator, &.{"zzzz-definitely-no-such-rule-zzzz"});
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("describe_rule", parsed.value.object.get("operation").?.string);
    try testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("payload").?.object.get("rules").?.array.items.len,
    );
}
