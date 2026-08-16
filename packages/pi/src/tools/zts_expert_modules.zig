//! Version-2 resolved-module discovery through the in-process protocol.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_modules";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "resolved modules",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description = "Resolve one handler's complete module graph and return built-ins, extensions, rejections, and the bound graph hash through schema v2.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Entry handler file to resolve.\"}},\"required\":[\"file\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(allocator: std.mem.Allocator, args_json: []const u8) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "file");
}

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len != 1) return registry_mod.ToolResult.err(allocator, name ++ ": requires one file\n");
    const input_json = try stringInput(allocator, args[0]);
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{ .operation = .modules, .input_json = input_json });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

fn stringInput(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("file");
    try json.write(file);
    try json.endObject();
    return out.toOwnedSlice();
}

const testing = std.testing;

test "modules registry requires a file" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    try testing.expectError(error.InvalidToolArgsJson, reg.invokeJson(testing.allocator, name, "{}"));
}

test "modules registry returns its full version-2 envelope" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    var result = try reg.invokeJson(testing.allocator, name, "{\"file\":\"packages/tools/tests/fixtures/expert/clean_handler.ts\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("modules", envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-model-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    const payload = envelope.get("payload").?.object;
    try testing.expect(payload.get("graph") != null);
    try testing.expect(payload.get("builtins") != null);
}

test "modules registry preserves out-of-root refusal envelope" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);
    try reg.register(testing.allocator, tool);
    var result = try reg.invokeJson(testing.allocator, name, "{\"file\":\"../outside.ts\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "path_outside_project_root",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}
