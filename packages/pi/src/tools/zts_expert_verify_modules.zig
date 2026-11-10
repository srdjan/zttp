//! Both this tool and `zts verify-modules --json` go through
//! `module_audit.writeJsonEnvelope`, so expert and CLI output stay byte-identical.
//!
//! `ToolResult.ok` mirrors the v1 envelope's `ok` field so callers can branch
//! on the tool result without parsing the body.

const std = @import("std");
const zts = @import("zts");
const module_audit = @import("zts_cli").module_audit;
const registry_mod = @import("../registry/registry.zig");
const ui_payload = @import("../ui_payload.zig");

const name = "zts_expert_verify_modules";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "verify module(s)",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description = "Audit built-in virtual module files for capability and effect discipline.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"builtins\":{\"type\":\"boolean\"},\"strict\":{\"type\":\"boolean\"}},\"required\":[]}",
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    var strict = false;
    var builtins = false;
    var paths = args;

    if (args.len == 1 and args[0].len > 0 and args[0][0] == '{') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
            return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules: invalid JSON input\n");
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules: expected JSON object\n");
        }
        const obj = parsed.value.object;
        strict = if (obj.get("strict")) |value| value == .bool and value.bool else false;
        builtins = if (obj.get("builtins")) |value| value == .bool and value.bool else false;

        if (builtins) {
            var result = try module_audit.verifyBuiltins(allocator, .{ .strict = strict });
            defer result.deinit(allocator);

            var buf = registry_mod.helpers.TextBuffer.init(allocator);
            defer buf.deinit();

            const hash = zts.policyHash();
            try module_audit.writeJsonEnvelope(buf.writer(), &result, hash);

            const llm_text = try buf.toOwnedSlice();
            errdefer allocator.free(llm_text);
            return .{
                .ok = !result.hasErrors(),
                .llm_text = llm_text,
                .ui_payload = try buildDiagnosticsPayloadFromEnvelope(allocator, llm_text),
            };
        }

        const paths_val = obj.get("paths") orelse
            return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules requires at least one path or builtins=true\n");
        if (paths_val != .array or paths_val.array.items.len == 0) {
            return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules requires at least one path or builtins=true\n");
        }
        const parsed_paths = try allocator.alloc([]const u8, paths_val.array.items.len);
        for (paths_val.array.items, 0..) |item, i| {
            if (item != .string) {
                return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules: paths must be strings\n");
            }
            parsed_paths[i] = item.string;
        }
        paths = parsed_paths;
    }

    if (paths.len == 0) {
        return registry_mod.ToolResult.err(allocator, "zts_expert_verify_modules requires at least one path\n");
    }

    var result = try module_audit.verifyPaths(allocator, paths, .{ .strict = strict });
    defer result.deinit(allocator);

    var buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer buf.deinit();

    const hash = zts.policyHash();
    try module_audit.writeJsonEnvelope(buf.writer(), &result, hash);

    const llm_text = try buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    return .{
        .ok = !result.hasErrors(),
        .llm_text = llm_text,
        .ui_payload = try buildDiagnosticsPayloadFromEnvelope(allocator, llm_text),
    };
}

fn buildDiagnosticsPayloadFromEnvelope(
    allocator: std.mem.Allocator,
    llm_text: []const u8,
) !ui_payload.UiPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, llm_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiagnosticsEnvelope;
    const obj = parsed.value.object;
    const checked_files = obj.get("checked_files") orelse return error.InvalidDiagnosticsEnvelope;
    const violations = obj.get("violations") orelse return error.InvalidDiagnosticsEnvelope;
    if (checked_files != .array or violations != .array) return error.InvalidDiagnosticsEnvelope;

    const items = try allocator.alloc(ui_payload.DiagnosticItem, violations.array.items.len);
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            items[i].deinit(allocator);
        }
        allocator.free(items);
    }
    while (i < violations.array.items.len) : (i += 1) {
        const diag = violations.array.items[i];
        if (diag != .object) return error.InvalidDiagnosticsEnvelope;
        const diag_obj = diag.object;
        items[i] = try ui_payload.DiagnosticItem.init(
            allocator,
            getString(diag_obj, "code") orelse return error.InvalidDiagnosticsEnvelope,
            getString(diag_obj, "severity") orelse return error.InvalidDiagnosticsEnvelope,
            getString(diag_obj, "file") orelse return error.InvalidDiagnosticsEnvelope,
            try requireU32(diag_obj, "line"),
            try requireU32(diag_obj, "column"),
            getString(diag_obj, "message") orelse return error.InvalidDiagnosticsEnvelope,
            null,
        );
    }

    return .{ .diagnostics = .{
        .summary = try allocator.print("{d} checked file(s), {d} diagnostic(s)", .{ checked_files.array.items.len, items.len }),
        .items = items,
    } };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// A number that the field cannot hold marks a damaged envelope.
fn requireU32(obj: std.json.ObjectMap, key: []const u8) !u32 {
    const value = obj.get(key) orelse return error.InvalidDiagnosticsEnvelope;
    if (value != .integer) return error.InvalidDiagnosticsEnvelope;
    return std.math.cast(u32, value.integer) orelse error.InvalidDiagnosticsEnvelope;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "missing args returns not-ok body" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "requires at least one path") != null);
}

test "nonexistent module path produces a v1 envelope" {
    var result = try execute(testing.allocator, &.{"/tmp/zts-pi-not-a-module.zig"});
    defer result.deinit(testing.allocator);

    // The audit reports "unknown virtual module file" or similar, but the
    // envelope shape must match regardless of the specific diagnostic.
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"policy_version\":\"2026.04.2\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"checked_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"violations\":") != null);
    try testing.expect(result.ui_payload != null);
}

/// One violation, with every field that the payload reads. The line breaks
/// between JSON tokens only.
const one_violation_envelope =
    \\{"checked_files":["packages/modules/src/env.zig"],"violations":[{"code":"ZTS900",
    \\"severity":"error","file":"packages/modules/src/env.zig","line":3,"column":7,
    \\"message":"missing capability"}]}
;

fn buildPayloadThenFree(allocator: std.mem.Allocator, envelope: []const u8) !void {
    var payload = try buildDiagnosticsPayloadFromEnvelope(allocator, envelope);
    payload.deinit(allocator);
}

test "diagnostics payload carries each violation of the envelope" {
    var payload = try buildDiagnosticsPayloadFromEnvelope(testing.allocator, one_violation_envelope);
    defer payload.deinit(testing.allocator);
    try testing.expectEqualStrings("1 checked file(s), 1 diagnostic(s)", payload.diagnostics.summary);
    try testing.expectEqual(@as(usize, 1), payload.diagnostics.items.len);
    try testing.expectEqualStrings("ZTS900", payload.diagnostics.items[0].code);
    try testing.expectEqual(@as(u32, 3), payload.diagnostics.items[0].line);
    try testing.expectEqual(@as(u32, 7), payload.diagnostics.items[0].column);
}

test "diagnostics payload frees every allocation when any one allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, buildPayloadThenFree, .{one_violation_envelope});
}

test "diagnostics payload refuses a damaged violation" {
    // Each row changes one token of `one_violation_envelope`. 4294967296 is
    // the first value that a u32 cannot hold.
    const Case = struct { valid: []const u8, damaged: []const u8 };
    const cases = [_]Case{
        .{ .valid = "\"message\":\"missing capability\"}]", .damaged = "\"message\":\"missing capability\"},5]" },
        .{ .valid = "\"message\":\"missing capability\"", .damaged = "\"message\":5" },
        .{ .valid = "\"line\":3,", .damaged = "\"line\":4294967296," },
        .{ .valid = "\"line\":3,", .damaged = "\"line\":-1," },
        .{ .valid = "\"column\":7,", .damaged = "\"column\":4294967296," },
        .{ .valid = "\"column\":7,", .damaged = "\"column\":-1," },
    };
    for (cases) |case| {
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, one_violation_envelope, case.valid));
        const envelope = try std.mem.replaceOwned(u8, testing.allocator, one_violation_envelope, case.valid, case.damaged);
        defer testing.allocator.free(envelope);
        try testing.expectError(error.InvalidDiagnosticsEnvelope, buildDiagnosticsPayloadFromEnvelope(testing.allocator, envelope));
    }
}
