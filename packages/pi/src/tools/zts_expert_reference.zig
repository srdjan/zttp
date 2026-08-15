//! Read-only retrieval for the embedded expert guide and canonical examples.
//! Rule, feature, module, and policy references keep their existing dedicated
//! tools; this tool owns only the embedded sources that otherwise have no
//! model-accessible retrieval surface after U2 removes them from the prompt.

const std = @import("std");
const embedded = @import("zts_expert_skill");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const json_writer = @import("../providers/json_writer.zig");

const name = "zts_expert_reference";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "expert reference",
    .effect = .analyze,
    .context_policy = .replayable_preview,
    .description = "Retrieve one bounded page of a canonical embedded zts expert reference. Continue with next_offset until it is null.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"topic\":{\"type\":\"string\",\"enum\":[\"agent-guide\",\"virtual-modules\",\"testing-replay\",\"jsx-patterns\",\"examples\"]},\"offset\":{\"type\":\"integer\",\"minimum\":0},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":6144}},\"required\":[\"topic\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, args_json, .{}) catch return error.InvalidToolArgsJson;
    if (parsed != .object) return error.InvalidToolArgsJson;
    const topic = parsed.object.get("topic") orelse return error.InvalidToolArgsJson;
    if (topic != .string) return error.InvalidToolArgsJson;
    const offset = if (parsed.object.get("offset")) |value| blk: {
        if (value != .integer or value.integer < 0) return error.InvalidToolArgsJson;
        break :blk @as(usize, @intCast(value.integer));
    } else 0;
    const max_bytes = if (parsed.object.get("max_bytes")) |value| blk: {
        if (value != .integer or value.integer <= 0 or value.integer > common.max_text_page_bytes) return error.InvalidToolArgsJson;
        break :blk @as(usize, @intCast(value.integer));
    } else common.max_text_page_bytes;
    const out = try allocator.alloc([]const u8, 3);
    out[0] = topic.string;
    out[1] = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    out[2] = try std.fmt.allocPrint(allocator, "{d}", .{max_bytes});
    return out;
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) {
        return registry_mod.ToolResult.err(allocator, name ++ ": expected a topic\n");
    }

    const topic = args[0];
    const offset = if (args.len >= 2) std.fmt.parseInt(usize, args[1], 10) catch 0 else 0;
    const max_bytes = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch common.max_text_page_bytes
    else
        common.max_text_page_bytes;
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| allocator.free(source);
    const source: []const u8 = if (std.mem.eql(u8, topic, "agent-guide"))
        embedded.skill_md
    else if (std.mem.eql(u8, topic, "virtual-modules"))
        embedded.virtual_modules_md
    else if (std.mem.eql(u8, topic, "testing-replay"))
        embedded.testing_replay_md
    else if (std.mem.eql(u8, topic, "jsx-patterns"))
        embedded.jsx_patterns_md
    else if (std.mem.eql(u8, topic, "examples")) blk: {
        owned_source = try examples(allocator);
        break :blk owned_source.?;
    } else return registry_mod.ToolResult.err(
        allocator,
        name ++ ": unknown topic; use agent-guide, virtual-modules, testing-replay, jsx-patterns, or examples\n",
    );

    return renderPage(allocator, topic, source, offset, @min(max_bytes, common.max_text_page_bytes));
}

fn examples(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "# basic handler\n{s}\n\n# routing with virtual modules\n{s}\n\n# cache, service, and routing\n{s}\n\n# durable workflow DSL\n{s}\n",
        .{
            embedded.basic_handler,
            embedded.routing_router,
            embedded.system_users,
            embedded.workflow_dsl_orchestrator,
        },
    );
}

/// Render the largest page whose complete envelope stays inside
/// `max_projected_tool_result_bytes`, measured rather than assumed.
fn renderPage(
    allocator: std.mem.Allocator,
    topic: []const u8,
    source: []const u8,
    offset: usize,
    max_bytes: usize,
) !registry_mod.ToolResult {
    var budget = max_bytes;
    while (true) {
        const result = renderPageWithin(allocator, topic, source, offset, budget) catch |err| switch (err) {
            error.ToolContextProjectionTooLarge => {
                const page = try common.textPage(source, offset, budget);
                if (page.content.len <= 1) return err;
                budget = page.content.len / 2;
                continue;
            },
            else => return err,
        };
        return result;
    }
}

fn renderPageWithin(
    allocator: std.mem.Allocator,
    topic: []const u8,
    source: []const u8,
    offset: usize,
    max_bytes: usize,
) !registry_mod.ToolResult {
    const page = common.textPage(source, offset, max_bytes) catch |err| switch (err) {
        error.InvalidUtf8Text => return registry_mod.ToolResult.err(allocator, name ++ ": reference content is not valid UTF-8\n"),
        error.InvalidTextOffset => return registry_mod.ToolResult.err(allocator, name ++ ": offset is not a valid content boundary\n"),
    };
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    defer out.deinit();
    const w = out.writer();
    try w.writeAll("{\"ok\":true,\"topic\":");
    try json_writer.writeString(w, topic);
    try w.print(
        ",\"offset\":{d},\"page_end\":{d},\"total_bytes\":{d},\"omitted_before_bytes\":{d},\"omitted_after_bytes\":{d},\"complete\":{s},\"next_offset\":",
        .{ offset, page.end, page.total_bytes, offset, page.total_bytes - page.end, if (page.complete()) "true" else "false" },
    );
    if (page.nextOffset()) |next| {
        try w.print("{d}", .{next});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"content\":");
    try json_writer.writeString(w, page.content);
    try w.writeAll("}\n");

    const llm_text = try out.toOwnedSlice();
    errdefer allocator.free(llm_text);
    if (llm_text.len > common.max_projected_tool_result_bytes) return error.ToolContextProjectionTooLarge;
    return .{ .ok = true, .llm_text = llm_text };
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

test "reference pages reconstruct exact bytes" {
    const source = "one blåbær two three";
    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(testing.allocator);
    var offset: usize = 0;
    while (offset < source.len) {
        var result = try renderPage(testing.allocator, "test", source, offset, 6);
        defer result.deinit(testing.allocator);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.llm_text, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try rebuilt.appendSlice(testing.allocator, obj.get("content").?.string);
        const next = obj.get("next_offset").?;
        if (next == .null) break;
        offset = @intCast(next.integer);
    }
    try testing.expectEqualStrings(source, rebuilt.items);
}
