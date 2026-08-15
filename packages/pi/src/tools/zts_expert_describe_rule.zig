//! Version-2 rule discovery through the in-process protocol.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_describe_rule";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "describe rule",
    .effect = .analyze,
    .context_policy = .exact,
    .description = "Discover a rule by name or code, or list all rules when called without a rule, through the schema-v2 compiler protocol.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"rule\":{\"type\":\"string\",\"description\":\"Optional rule code or name.\"}},\"required\":[]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(allocator: std.mem.Allocator, args_json: []const u8) ![]const []const u8 {
    return registry_mod.helpers.decodeOptionalSingleStringField(allocator, args_json, "rule");
}

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len > 1) return registry_mod.ToolResult.err(allocator, name ++ ": accepts at most one rule\n");
    const input_json = if (args.len == 1)
        try stringInput(allocator, "rule", args[0])
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{ .operation = .describe_rule, .input_json = input_json });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

fn stringInput(allocator: std.mem.Allocator, field: []const u8, value: []const u8) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField(field);
    try json.write(value);
    try json.endObject();
    return out.toOwnedSlice();
}

const testing = std.testing;

test "describe-rule registry returns its full version-2 envelope" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    var result = try reg.invokeJson(testing.allocator, name, "{\"rule\":\"ZTS303\"}");
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("describe_rule", envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-model-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    const rules = envelope.get("payload").?.object.get("rules").?.array;
    try testing.expectEqual(@as(usize, 1), rules.items.len);
    try testing.expectEqualStrings("ZTS303", rules.items[0].object.get("code").?.string);
}

test "describe-rule registry preserves the protocol's empty unknown-rule result" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    var result = try reg.invokeJson(testing.allocator, name, "{\"rule\":\"not-a-real-rule\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("describe_rule", parsed.value.object.get("operation").?.string);
    try testing.expect(parsed.value.object.get("success").?.bool);
    try testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("payload").?.object.get("rules").?.array.items.len,
    );
}
