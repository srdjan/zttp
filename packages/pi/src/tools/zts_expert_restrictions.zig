//! Version-2 language-restriction discovery through the in-process protocol.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_restrictions";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "language restrictions",
    .effect = .analyze,
    .context_policy = .exact,
    .description = "Discover language restrictions and their proof rationale from the schema-v2 compiler protocol. Takes no arguments.",
    .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    .decode_json = registry_mod.helpers.decodeNoArgs,
    .execute = execute,
};

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len != 0) return registry_mod.ToolResult.err(allocator, name ++ ": takes no arguments\n");
    const projection = try client.invokeForTool(allocator, .{ .operation = .restrictions, .input_json = "{}" });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

const testing = std.testing;

test "restrictions registry returns its full version-2 envelope" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    var result = try reg.invokeJson(testing.allocator, name, "{}");
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("restrictions", envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-advanced-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    try testing.expect(envelope.get("payload").?.object.get("restrictions") != null);
}
