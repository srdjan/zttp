//! Preview compiler-authored canonical refactors for a handler file.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_canonicalize";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "canonicalize preview",
    .effect = .read_workspace,
    .context_policy = .exact,
    .description = "Preview local canonical ZigTS refactor intents. Set simulate=true to apply previews in memory through edit_simulate.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Handler file to analyze.\"},\"simulate\":{\"type\":\"boolean\",\"description\":\"Apply previews in memory and run edit_simulate.\"}},\"required\":[\"file\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArgsJson;
    const obj = parsed.value.object;
    const file_value = obj.get("file") orelse return error.InvalidToolArgsJson;
    if (file_value != .string) return error.InvalidToolArgsJson;
    const simulate = if (obj.get("simulate")) |value| blk: {
        if (value != .bool) return error.InvalidToolArgsJson;
        break :blk value.bool;
    } else false;

    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.append(allocator, try allocator.dupe(u8, file_value.string));
    if (simulate) try args.append(allocator, "--simulate");
    return try args.toOwnedSlice(allocator);
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0 or args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--simulate"))) {
        return registry_mod.ToolResult.err(allocator, "zts_expert_canonicalize requires a file and optional --simulate\n");
    }

    const input_json = try canonicalizeInput(allocator, args[0], args.len == 2);
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{
        .operation = .canonicalize,
        .input_json = input_json,
    });
    return .{
        .ok = projection.ok,
        .llm_text = projection.llm_text,
    };
}

fn canonicalizeInput(allocator: std.mem.Allocator, file: []const u8, simulate: bool) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("file");
    try json.write(file);
    if (simulate) {
        try json.objectField("simulate");
        try json.write(true);
    }
    try json.endObject();
    return out.toOwnedSlice();
}

const testing = std.testing;

test "tool decodes file arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try decodeJson(arena.allocator(), "{\"file\":\"handler.ts\"}");
    try testing.expectEqual(@as(usize, 1), args.len);
    try testing.expectEqualStrings("handler.ts", args[0]);
}

test "tool decodes simulate arg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try decodeJson(arena.allocator(), "{\"file\":\"handler.ts\",\"simulate\":true}");
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("handler.ts", args[0]);
    try testing.expectEqualStrings("--simulate", args[1]);
}

test "canonicalize registry returns bound version-2 candidates and optional simulation" {
    const source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = source });
    const file = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, "handler.ts", testing.allocator);
    defer testing.allocator.free(file);

    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);

    const plain_args = try std.fmt.allocPrint(testing.allocator, "{{\"file\":{f}}}", .{std.json.fmt(file, .{})});
    defer testing.allocator.free(plain_args);
    var plain = try registry.invokeJson(testing.allocator, name, plain_args);
    defer plain.deinit(testing.allocator);
    try testing.expect(plain.ok);

    var plain_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, plain.llm_text, .{});
    defer plain_parsed.deinit();
    const envelope = plain_parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("canonicalize", envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-advanced-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    const payload = envelope.get("payload").?.object;
    try testing.expect(payload.get("source_digest").?.string.len == 64);
    try testing.expect(payload.get("simulation").? == .null);
    try testing.expect(payload.get("refactors") == null);
    const candidate = payload.get("candidates").?.array.items[0].object;
    try testing.expect(candidate.get("kind") == null);
    const bound = candidate.get("bound").?.object;
    try testing.expectEqualStrings(payload.get("source_digest").?.string, bound.get("source_digest").?.string);
    try testing.expectEqualStrings(envelope.get("profile_id").?.string, bound.get("profile_id").?.string);
    try testing.expectEqualStrings(envelope.get("policy_hash").?.string, bound.get("policy_hash").?.string);
    try testing.expectEqualStrings(envelope.get("module_graph_hash").?.string, bound.get("module_graph_hash").?.string);

    const simulated_args = try std.fmt.allocPrint(testing.allocator, "{{\"file\":{f},\"simulate\":true}}", .{std.json.fmt(file, .{})});
    defer testing.allocator.free(simulated_args);
    var simulated = try registry.invokeJson(testing.allocator, name, simulated_args);
    defer simulated.deinit(testing.allocator);
    var simulated_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, simulated.llm_text, .{});
    defer simulated_parsed.deinit();
    const simulation = simulated_parsed.value.object.get("payload").?.object.get("simulation").?.object;
    try testing.expect(simulation.get("ok").? == .bool);
    try testing.expect(simulation.get("new_count").? == .integer);
    try testing.expect(simulation.get("preexisting_count").? == .integer);
}

test "canonicalize registry preserves out-of-root refusal envelope" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    var result = try registry.invokeJson(testing.allocator, name, "{\"file\":\"../outside.ts\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("canonicalize", parsed.value.object.get("operation").?.string);
    try testing.expectEqualStrings("path_outside_project_root", parsed.value.object.get("error").?.object.get("code").?.string);
}
