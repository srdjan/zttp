//! Read-only retrieval for the embedded expert guide and canonical examples.
//! Rule, feature, module, and policy references keep their existing dedicated
//! tools; this tool owns only the embedded sources that otherwise have no
//! model-accessible retrieval surface after U2 removes them from the prompt.

const std = @import("std");
const embedded = @import("zts_expert_skill");
const registry_mod = @import("../registry/registry.zig");

const name = "zts_expert_reference";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "expert reference",
    .effect = .analyze,
    .description = "Retrieve one canonical embedded zts expert reference: agent-guide, virtual-modules, testing-replay, jsx-patterns, or examples.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"topic\":{\"type\":\"string\",\"enum\":[\"agent-guide\",\"virtual-modules\",\"testing-replay\",\"jsx-patterns\",\"examples\"]}},\"required\":[\"topic\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "topic");
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 1) {
        return registry_mod.ToolResult.err(allocator, name ++ ": expected one topic\n");
    }

    const topic = args[0];
    const source = if (std.mem.eql(u8, topic, "agent-guide"))
        embedded.skill_md
    else if (std.mem.eql(u8, topic, "virtual-modules"))
        embedded.virtual_modules_md
    else if (std.mem.eql(u8, topic, "testing-replay"))
        embedded.testing_replay_md
    else if (std.mem.eql(u8, topic, "jsx-patterns"))
        embedded.jsx_patterns_md
    else if (std.mem.eql(u8, topic, "examples"))
        return examples(allocator)
    else
        return registry_mod.ToolResult.err(
            allocator,
            name ++ ": unknown topic; use agent-guide, virtual-modules, testing-replay, jsx-patterns, or examples\n",
        );

    return .{ .ok = true, .llm_text = try allocator.dupe(u8, source) };
}

fn examples(allocator: std.mem.Allocator) !registry_mod.ToolResult {
    const text = try std.fmt.allocPrint(
        allocator,
        "# basic handler\n{s}\n\n# routing with virtual modules\n{s}\n\n# cache, service, and routing\n{s}\n\n# durable workflow DSL\n{s}\n",
        .{
            embedded.basic_handler,
            embedded.routing_router,
            embedded.system_users,
            embedded.workflow_dsl_orchestrator,
        },
    );
    return .{ .ok = true, .llm_text = text };
}

const testing = std.testing;

test "retrieves each embedded reference topic" {
    const topics = [_][]const u8{
        "agent-guide",
        "virtual-modules",
        "testing-replay",
        "jsx-patterns",
        "examples",
    };
    for (topics) |topic| {
        var result = try execute(testing.allocator, &.{topic});
        defer result.deinit(testing.allocator);
        try testing.expect(result.ok);
        try testing.expect(result.llm_text.len > 100);
    }
}

test "rejects an unknown reference topic" {
    var result = try execute(testing.allocator, &.{"unknown"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "unknown topic") != null);
}
