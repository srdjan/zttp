//! Both this tool and `zts features --json` go through
//! `json_diagnostics.writeFeaturesJson`, so expert and CLI output stay
//! byte-identical.

const std = @import("std");
const json_diagnostics = @import("zts_cli").json_diagnostics;
const registry_mod = @import("../registry/registry.zig");

const name = "zts_expert_features";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "language features",
    .effect = .analyze,
    .description = "List allowed and blocked JS/TS features with suggested alternatives. Takes no arguments.",
    .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    .decode_json = registry_mod.helpers.decodeNoArgs,
    .execute = execute,
};

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 0) return registry_mod.ToolResult.err(allocator, name ++ ": takes no arguments\n");

    const llm_text = try registry_mod.helpers.renderAlloc(allocator, json_diagnostics.writeFeaturesJson, .{});
    return .{ .ok = true, .llm_text = llm_text };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "features emits JSON array with at least one allowed and one blocked entry" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    try testing.expectEqual(@as(u8, '['), result.llm_text[0]);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"status\":\"allowed\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"status\":\"blocked\"") != null);
}

test "features rejects unexpected arguments" {
    var result = try execute(testing.allocator, &.{"unexpected"});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "takes no arguments") != null);
}
