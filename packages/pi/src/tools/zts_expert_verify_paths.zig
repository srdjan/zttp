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
    .model_exposure = .visible,
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
            try requireU32(object, "line"),
            try requireU32(object, "column"),
            getString(object, "message") orelse return error.InvalidDiagnosticsEnvelope,
            null,
        );
    }

    return .{ .diagnostics = .{
        .summary = try allocator.print("checked {s}: {d} diagnostic(s)", .{ file.string, items.len }),
        .items = items,
    } };
}

fn getString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// A number that the field cannot hold marks a damaged envelope.
fn requireU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return error.InvalidDiagnosticsEnvelope;
    if (value != .integer) return error.InvalidDiagnosticsEnvelope;
    return std.math.cast(u32, value.integer) orelse error.InvalidDiagnosticsEnvelope;
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
    try testing.expectEqualStrings("zts-model-1", envelope.get("profile_id").?.string);
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

/// One diagnostic, with every field that the payload reads. The line breaks
/// between JSON tokens only.
const one_diagnostic_envelope =
    \\{"payload":{"file":"handler.ts"},"diagnostics":[{"code":"ZTS001","severity":"error",
    \\"file":"handler.ts","line":3,"column":7,"message":"unsupported feature"}]}
;

fn buildPayloadThenFree(allocator: std.mem.Allocator, envelope: []const u8) !void {
    var payload = try buildDiagnosticsPayload(allocator, envelope);
    payload.deinit(allocator);
}

test "diagnostics payload carries each diagnostic of the envelope" {
    var payload = try buildDiagnosticsPayload(testing.allocator, one_diagnostic_envelope);
    defer payload.deinit(testing.allocator);
    try testing.expectEqualStrings("checked handler.ts: 1 diagnostic(s)", payload.diagnostics.summary);
    try testing.expectEqual(@as(usize, 1), payload.diagnostics.items.len);
    try testing.expectEqualStrings("ZTS001", payload.diagnostics.items[0].code);
    try testing.expectEqual(@as(u32, 3), payload.diagnostics.items[0].line);
    try testing.expectEqual(@as(u32, 7), payload.diagnostics.items[0].column);
}

test "diagnostics payload frees every allocation when any one allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, buildPayloadThenFree, .{one_diagnostic_envelope});
}

test "diagnostics payload refuses a damaged diagnostic" {
    // Each row changes one token of `one_diagnostic_envelope`. 4294967296 is
    // the first value that a u32 cannot hold.
    const Case = struct { valid: []const u8, damaged: []const u8 };
    const cases = [_]Case{
        .{ .valid = "\"message\":\"unsupported feature\"}]", .damaged = "\"message\":\"unsupported feature\"},5]" },
        .{ .valid = "\"message\":\"unsupported feature\"", .damaged = "\"message\":5" },
        .{ .valid = "\"line\":3,", .damaged = "\"line\":4294967296," },
        .{ .valid = "\"line\":3,", .damaged = "\"line\":-1," },
        .{ .valid = "\"column\":7,", .damaged = "\"column\":4294967296," },
        .{ .valid = "\"column\":7,", .damaged = "\"column\":-1," },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, one_diagnostic_envelope, case.valid));
        const envelope = try std.mem.replaceOwned(u8, testing.allocator, one_diagnostic_envelope, case.valid, case.damaged);
        defer testing.allocator.free(envelope);
        try testing.expectError(error.InvalidDiagnosticsEnvelope, buildDiagnosticsPayload(testing.allocator, envelope));
    }
}
