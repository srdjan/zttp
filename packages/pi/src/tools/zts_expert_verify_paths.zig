//! Single-file schema-v2 check through the in-process agent protocol.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const ui_payload = @import("../ui_payload.zig");
const client = @import("zts_agent_client.zig");

const name = "zts_expert_verify_paths";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "check handler",
    .effect = .read_workspace,
    .context_policy = .exact,
    .description = "Run one file-bound schema-v2 check and return its complete diagnostics, proof payload, and identity envelope.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\",\"description\":\"Handler file to check.\"}},\"required\":[\"file\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(allocator: std.mem.Allocator, args_json: []const u8) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "file");
}

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len != 1) return registry_mod.ToolResult.err(allocator, name ++ ": requires one file\n");
    const input_json = try fileInput(allocator, args[0]);
    defer allocator.free(input_json);

    const projection = try client.invokeForTool(allocator, .{ .operation = .check, .input_json = input_json });
    errdefer allocator.free(projection.llm_text);
    return .{
        .ok = projection.ok,
        .llm_text = projection.llm_text,
        .ui_payload = buildDiagnosticsPayload(allocator, projection.llm_text) catch null,
    };
}

fn fileInput(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("file");
    try json.write(file);
    try json.endObject();
    return out.toOwnedSlice();
}

fn buildDiagnosticsPayload(allocator: std.mem.Allocator, llm_text: []const u8) !ui_payload.UiPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, llm_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiagnosticsEnvelope;
    const envelope = parsed.value.object;
    const payload = envelope.get("payload") orelse return error.InvalidDiagnosticsEnvelope;
    const diagnostics = envelope.get("diagnostics") orelse return error.InvalidDiagnosticsEnvelope;
    if (payload != .object or diagnostics != .array) return error.InvalidDiagnosticsEnvelope;
    const file = payload.object.get("file") orelse return error.InvalidDiagnosticsEnvelope;
    if (file != .string) return error.InvalidDiagnosticsEnvelope;

    const items = try allocator.alloc(ui_payload.DiagnosticItem, diagnostics.array.items.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            items[initialized].deinit(allocator);
        }
        allocator.free(items);
    }
    while (initialized < diagnostics.array.items.len) : (initialized += 1) {
        const diagnostic = diagnostics.array.items[initialized];
        if (diagnostic != .object) return error.InvalidDiagnosticsEnvelope;
        const object = diagnostic.object;
        items[initialized] = try ui_payload.DiagnosticItem.init(
            allocator,
            getString(object, "code") orelse return error.InvalidDiagnosticsEnvelope,
            getString(object, "severity") orelse return error.InvalidDiagnosticsEnvelope,
            getString(object, "file") orelse return error.InvalidDiagnosticsEnvelope,
            @intCast(getInteger(object, "line") orelse return error.InvalidDiagnosticsEnvelope),
            @intCast(getInteger(object, "column") orelse return error.InvalidDiagnosticsEnvelope),
            getString(object, "message") orelse return error.InvalidDiagnosticsEnvelope,
            null,
        );
    }

    return .{ .diagnostics = .{
        .summary = try std.fmt.allocPrint(
            allocator,
            "checked {s}: {d} diagnostic(s)",
            .{ file.string, items.len },
        ),
        .items = items,
    } };
}

fn getString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

const testing = std.testing;

test "verify-paths registry requires one file" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    try testing.expectError(error.InvalidToolArgsJson, registry.invokeJson(testing.allocator, name, "{}"));
    try testing.expectError(
        error.InvalidToolArgsJson,
        registry.invokeJson(testing.allocator, name, "{\"paths\":[\"handler.ts\"]}"),
    );
}

test "verify-paths registry performs one file-bound version-2 check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "function handler(req: Request): Response { var x = 1; return Response.json({ x: x }); }",
    });
    const file = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, "handler.ts", testing.allocator);
    defer testing.allocator.free(file);

    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    const args_json = try fileInput(testing.allocator, file);
    defer testing.allocator.free(args_json);
    var result = try registry.invokeJson(testing.allocator, name, args_json);
    defer result.deinit(testing.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try testing.expect(!result.ok);
    try testing.expectEqual(@as(i64, 2), envelope.get("schema_version").?.integer);
    try testing.expectEqualStrings("check", envelope.get("operation").?.string);
    try testing.expectEqualStrings("zts-advanced-1", envelope.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), envelope.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), envelope.get("module_graph_hash").?.string.len);
    try testing.expectEqualStrings(
        envelope.get("payload").?.object.get("source_digest").?.string,
        envelope.get("diagnostics").?.array.items[0].object.get("source_digest").?.string,
    );
    try testing.expect(result.ui_payload != null);
    switch (result.ui_payload.?) {
        .diagnostics => |diagnostics| {
            try testing.expect(diagnostics.items.len > 0);
            try testing.expectEqualStrings(
                envelope.get("diagnostics").?.array.items[0].object.get("code").?.string,
                diagnostics.items[0].code,
            );
        },
        else => return error.TestExpectedDiagnostics,
    }

    const meta = try client.invokeForTool(testing.allocator, .{ .operation = .meta, .input_json = "{}" });
    defer testing.allocator.free(meta.llm_text);
    var parsed_meta = try std.json.parseFromSlice(std.json.Value, testing.allocator, meta.llm_text, .{});
    defer parsed_meta.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        envelope.get("module_graph_hash").?.string,
        parsed_meta.value.object.get("module_graph_hash").?.string,
    ));
}

test "verify-paths registry preserves out-of-root refusal" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);
    var result = try registry.invokeJson(testing.allocator, name, "{\"file\":\"../outside.ts\"}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(result.ui_payload == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("check", parsed.value.object.get("operation").?.string);
    try testing.expectEqualStrings(
        "path_outside_project_root",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}
