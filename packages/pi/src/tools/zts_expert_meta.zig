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
    .model_exposure = .visible,
    .description = "Discover the active schema-v2 compiler profile and operation index. Use view full for registries, grammar, examples, and decisions; new sessions already contain the bounded bootstrap view.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"view\":{\"type\":\"string\",\"enum\":[\"bootstrap\",\"full\"],\"description\":\"Optional metadata projection; defaults to full.\"}},\"required\":[]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(allocator: std.mem.Allocator, args_json: []const u8) ![]const []const u8 {
    return registry_mod.helpers.decodeOptionalSingleStringField(allocator, args_json, "view");
}

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len > 1) return registry_mod.ToolResult.err(allocator, name ++ ": accepts at most one view\n");
    const input_json = if (args.len == 1)
        try viewInput(allocator, args[0])
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{ .operation = .meta, .input_json = input_json });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

fn viewInput(allocator: std.mem.Allocator, view: []const u8) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("view");
    try json.write(view);
    try json.endObject();
    return out.toOwnedSlice();
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

test "discovery registry returns a bounded bootstrap projection" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);

    var result = try reg.invokeJson(testing.allocator, name, "{\"view\":\"bootstrap\"}");
    defer result.deinit(testing.allocator);
    try expectEnvelope(result, "meta");
    try testing.expect(result.llm_text.len <= 8 * 1024);
    const payload = try payloadObject(result.llm_text);
    defer payload.parsed.deinit();
    try testing.expectEqualStrings("bootstrap", payload.object.get("view").?.string);
    try testing.expect(payload.object.get("grammar") == null);
    try testing.expect(payload.object.get("full_meta_request") != null);
}

fn expectEnvelope(result: registry_mod.ToolResult, operation: []const u8) !void {
    try testing.expect(result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings(operation, envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-model-1", envelope.get("profile_id").?.string);
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
