//! Reduce a handler file to its unique Canonical Normal Form.
//!
//! Read-only: returns the canonical source, the `fullyCanonical` fixed-point
//! flag, any residual diagnostics, and the rewrite trace. The agent applies the
//! canonical source through its normal `propose_change_set` path; this tool never writes
//! the file. Distinct from `zts_expert_canonicalize`, which previews single
//! per-node refactor intents - this returns the fixed point.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_normalize";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "normalize",
    .effect = .read_workspace,
    .context_policy = .exact,
    .description = "Reduce a handler file to its unique Canonical Normal Form and return the canonical source, fullyCanonical, residualDiagnostics, and the rewrite trace. Read-only: never writes the file. Use it to canonicalize a draft before applying, so the compiler veto never rejects it on a ZTS6xx canonical-form violation.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Handler file to normalize.\"}},\"required\":[\"file\"]}",
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
    const object = parsed.value.object;
    if (object.get("write") != null) return error.InvalidToolArgsJson;
    const file_value = object.get("file") orelse return error.InvalidToolArgsJson;
    if (file_value != .string) return error.InvalidToolArgsJson;

    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.append(allocator, try allocator.dupe(u8, file_value.string));
    return try args.toOwnedSlice(allocator);
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 1) {
        return registry_mod.ToolResult.err(allocator, "zts_expert_normalize requires a single file argument\n");
    }

    const input_json = try normalizeInput(allocator, args[0]);
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{
        .operation = .normalize,
        .input_json = input_json,
    });
    return .{
        .ok = projection.ok,
        .llm_text = projection.llm_text,
    };
}

fn normalizeInput(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("file");
    try json.write(file);
    try json.objectField("write");
    try json.write(false);
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

test "normalize request projection is explicitly read-only" {
    const input_json = try normalizeInput(testing.allocator, "handler.ts");
    defer testing.allocator.free(input_json);
    try testing.expectEqualStrings("{\"file\":\"handler.ts\",\"write\":false}", input_json);
}

test "normalize registry returns a non-writing version-2 fixed point" {
    const source =
        \\function handler(req: Request): Response {
        \\  let msg = "hi";
        \\  return Response.json({ msg: msg });
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
    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"file\":{f}}}", .{std.json.fmt(file, .{})});
    defer testing.allocator.free(args_json);
    var result = try registry.invokeJson(testing.allocator, name, args_json);
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("normalize", envelope.get("operation").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    const payload = envelope.get("payload").?.object;
    try testing.expect(payload.get("fullyCanonical") == null);
    try testing.expect(payload.get("canonicalSource") == null);
    try testing.expect(payload.get("rewriteTrace") == null);
    try testing.expect(payload.get("converged").?.bool);
    try testing.expect(payload.get("fully_canonical").?.bool);
    const trace = payload.get("rewrite_trace").?.array;
    try testing.expectEqual(@as(usize, 1), trace.items.len);
    try testing.expectEqualStrings("replace_let_with_const", trace.items[0].object.get("intent").?.string);
    const canonical_source = payload.get("canonical_source").?.string;
    try testing.expect(std.mem.indexOf(u8, canonical_source, "const msg") != null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "handler.ts", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(source, on_disk);
}

test "normalize registry cannot request writes" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    try testing.expectError(
        error.InvalidToolArgsJson,
        registry.invokeJson(testing.allocator, name, "{\"file\":\"handler.ts\",\"write\":true}"),
    );
}

test "normalize registry preserves out-of-root refusal envelope" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    var result = try registry.invokeJson(testing.allocator, name, "{\"file\":\"../outside.ts\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("normalize", parsed.value.object.get("operation").?.string);
    try testing.expectEqualStrings("path_outside_project_root", parsed.value.object.get("error").?.object.get("code").?.string);
}
