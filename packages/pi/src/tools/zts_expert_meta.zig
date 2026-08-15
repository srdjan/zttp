//! Version-2 compiler and policy discovery through the in-process protocol.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_meta";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "policy meta",
    .effect = .analyze,
    .context_policy = .exact,
    .description = "Discover the active schema-v2 compiler profile, identities, operations, registries, grammar, examples, and decisions. Takes no arguments.",
    .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    .decode_json = registry_mod.helpers.decodeNoArgs,
    .execute = execute,
};

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len != 0) return registry_mod.ToolResult.err(allocator, name ++ ": takes no arguments\n");
    const projection = try client.invokeForTool(allocator, .{ .operation = .meta, .input_json = "{}" });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

const testing = std.testing;

test "discovery registry returns the full version-2 meta envelope" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);

    var result = try reg.invokeJson(testing.allocator, name, "{}");
    defer result.deinit(testing.allocator);
    try expectEnvelope(result, "meta");
    const payload = try payloadObject(result.llm_text);
    defer payload.parsed.deinit();
    try testing.expect(payload.object.get("operations") != null);
    try testing.expect(payload.object.get("grammar") != null);
}

fn expectEnvelope(result: registry_mod.ToolResult, operation: []const u8) !void {
    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings(operation, envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-advanced-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
}

const ParsedPayload = struct {
    parsed: std.json.Parsed(std.json.Value),
    object: std.json.ObjectMap,
};

fn payloadObject(bytes: []const u8) !ParsedPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    errdefer parsed.deinit();
    return .{ .object = parsed.value.object.get("payload").?.object, .parsed = parsed };
}
