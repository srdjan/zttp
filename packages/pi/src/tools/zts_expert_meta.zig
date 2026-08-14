//! Both this tool and `zts meta --json` go through
//! `expert_meta.writeJson`, so expert and CLI output stay byte-identical.

const std = @import("std");
const expert_meta = @import("zts_cli").expert_meta;
const registry_mod = @import("../registry/registry.zig");

const name = "zts_expert_meta";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "policy meta",
    .effect = .analyze,
    .context_policy = .exact,
    .description = "Show compiler version, policy version, policy hash, and rule counts. Takes no arguments.",
    .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    .decode_json = registry_mod.helpers.decodeNoArgs,
    .execute = execute,
};

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 0) return registry_mod.ToolResult.err(allocator, name ++ ": v1 takes no arguments\n");

    const info = expert_meta.compute();
    const llm_text = try registry_mod.helpers.renderAlloc(allocator, expert_meta.writeJson, .{&info});
    return .{ .ok = true, .llm_text = llm_text };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "execute returns v1 meta envelope" {
    var result = try execute(testing.allocator, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"compiler_version\":\"0.18.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"policy_version\":\"2026.04.2\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"mode\":\"embedded\"") != null);
}

test "execute rejects unexpected arguments" {
    var result = try execute(testing.allocator, &.{"unexpected"});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "takes no arguments") != null);
}

test "registry invokes the tool end-to-end" {
    var reg: registry_mod.Registry = .{};
    defer reg.deinit(testing.allocator);

    try reg.register(testing.allocator, tool);

    var result = try reg.invoke(testing.allocator, name, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"rule_count\":") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"categories\":{\"verifier\":") != null);
}
