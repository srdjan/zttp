const std = @import("std");
const testing = std.testing;
const zts = @import("zts");

const app = @import("app.zig");
const context_budget = @import("context_budget.zig");
const chat_completions = @import("providers/chat_completions.zig");
const deepseek_client = @import("providers/deepseek/client.zig");
const expert_persona = @import("expert_persona.zig");
const model_request = @import("providers/model_request.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const transcript_mod = @import("transcript.zig");
const turn = @import("turn.zig");

test "current repository full preset fixed prefix meets U2 budget and stays stable" {
    const pre_u2_baseline_tokens: u64 = 31_477;
    const fixed_prefix_target_tokens: u64 = 20_000;
    const maximum_retained_percent: u64 = 65;
    const allocator = testing.allocator;
    const repository_agents = try zts.file_io.readFile(allocator, "AGENTS.md", 64 * 1024);
    defer allocator.free(repository_agents);
    const prompt = try expert_persona.buildSystemPromptWithContext(allocator, repository_agents);
    defer allocator.free(prompt);
    const repeated_prompt = try expert_persona.buildSystemPromptWithContext(allocator, repository_agents);
    defer allocator.free(repeated_prompt);
    try testing.expectEqualStrings(prompt, repeated_prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, repository_agents) != null);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    var tools = TextBuffer.init(allocator);
    defer tools.deinit();
    try deepseek_client.writeToolsArray(tools.writer(), &registry);
    const tools_json = try tools.toOwnedSlice();
    defer allocator.free(tools_json);
    var repeated_tools = TextBuffer.init(allocator);
    defer repeated_tools.deinit();
    try deepseek_client.writeToolsArray(repeated_tools.writer(), &registry);
    const repeated_tools_json = try repeated_tools.toOwnedSlice();
    defer allocator.free(repeated_tools_json);
    try testing.expectEqualStrings(tools_json, repeated_tools_json);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    var snapshot = try model_request.createSnapshot(allocator, .{
        .config = .{
            .provider = .deepseek,
            .model = deepseek_client.default_model,
            .max_output_tokens = deepseek_client.default_max_tokens,
            .stream = false,
            .system_prompt = prompt,
            .tools_json = tools_json,
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(allocator);
    const body = try chat_completions.buildRequestBodyFromSnapshot(allocator, &snapshot);
    defer allocator.free(body);
    try snapshot.completePreparation(body);
    const budget = snapshot.budget orelse return error.TestExpectedEqual;

    try testing.expectEqual(@as(u64, prompt.len), budget.bytes.system);
    try testing.expectEqual(@as(u64, tools_json.len), budget.bytes.tools);
    try testing.expectEqual(@as(u64, 0), budget.bytes.history);
    try testing.expectEqual(@as(u64, 0), budget.bytes.transient);
    try testing.expect(budget.bytes.framing > 0);
    try testing.expectEqual(@as(u64, body.len), budget.bytes.wire);
    try testing.expect(budget.tokens.total <= fixed_prefix_target_tokens);
    try testing.expect(
        budget.tokens.total * 100 <= pre_u2_baseline_tokens * maximum_retained_percent,
    );
}

test "request preparation accounts all visible components and exact wire bytes" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "call_1", .name = "workspace_read_file", .args_json = "{\"path\":\"handler.ts\"}" },
        .{ .id = "call_2", .name = "zts_expert_modules", .args_json = "{}" },
    };
    try transcript.append(testing.allocator, .{ .user_text = "inspect the project" });
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "export default 1;",
    } });
    try transcript.append(testing.allocator, .{ .system_note = "checkpoint context" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var snapshot = try model_request.createSnapshot(allocator, .{
        .config = .{
            .provider = .local,
            .model = "mlx-community/Qwen3-8B-4bit",
            .max_output_tokens = 8_192,
            .stream = false,
            .system_prompt = "expert persona\nproject instructions",
            .tools_json = "[{\"type\":\"function\",\"function\":{\"name\":\"workspace_read_file\"}}]",
        },
        .transcript = &transcript,
        .extra_user_text = "retry after veto",
    });
    defer snapshot.deinit(allocator);

    const body = try chat_completions.buildRequestBodyFromSnapshot(allocator, &snapshot);
    try snapshot.completePreparation(body);
    const budget = snapshot.budget orelse return error.TestExpectedEqual;

    try testing.expectEqual(@as(u64, snapshot.config.system_prompt.len), budget.bytes.system);
    try testing.expectEqual(@as(u64, snapshot.config.tools_json.?.len), budget.bytes.tools);
    try testing.expect(budget.bytes.history > 0);
    try testing.expectEqual(@as(u64, snapshot.extra_user_text.?.len), budget.bytes.transient);
    try testing.expectEqual(@as(u64, body.len), budget.bytes.wire);
    try testing.expectEqual(
        budget.bytes.wire -| budget.bytes.system -| budget.bytes.tools -|
            budget.bytes.history -| budget.bytes.transient,
        budget.bytes.framing,
    );
    try testing.expectEqual(
        budget.tokens.system + budget.tokens.tools + budget.tokens.history +
            budget.tokens.transient + budget.tokens.framing,
        budget.tokens.total,
    );
    try testing.expectEqual(@as(u64, 16_384), budget.tokens.reserve);
    try testing.expectEqual(@as(u64, 40_000), budget.limits.soft_input_tokens);
    try testing.expectEqual(@as(u64, 24_576), budget.limits.hard_input_tokens);
}

test "empty request and boundary classification stay explicit" {
    const components: context_budget.ComponentBytes = .{
        .system = 9,
        .tools = 0,
        .history = 0,
        .transient = 0,
    };
    const qwen = context_budget.ModelLimits{
        .context_window_tokens = 40_960,
        .reserve_tokens = 16_384,
    };
    const empty = try context_budget.estimate(components, 9, qwen);
    try testing.expectEqual(@as(u64, 0), empty.bytes.history);
    try testing.expectEqual(@as(u64, 0), empty.bytes.transient);
    try testing.expectEqual(@as(u64, 9), empty.bytes.wire);
    try testing.expectEqual(@as(u64, 24_576), empty.limits.hard_input_tokens);

    try testing.expectEqual(
        context_budget.BudgetRelation.within,
        context_budget.relation(40_000, 40_000),
    );
    try testing.expectEqual(
        context_budget.BudgetRelation.exceeded,
        context_budget.relation(40_001, 40_000),
    );
    try testing.expectEqual(
        context_budget.BudgetRelation.within,
        context_budget.relation(24_576, empty.limits.hard_input_tokens),
    );
    try testing.expectEqual(
        context_budget.BudgetRelation.exceeded,
        context_budget.relation(24_577, empty.limits.hard_input_tokens),
    );
}

test "provider usage normalization and exact usage selection are provider neutral" {
    const anthropic_usage: turn.Usage = .{
        .input_tokens = 3,
        .cache_read_input_tokens = 31_471,
        .cache_creation_input_tokens = 488,
    };
    try testing.expectEqual(
        @as(u64, 31_962),
        try context_budget.normalizeLogicalInput(.anthropic, anthropic_usage),
    );
    try testing.expectEqual(
        @as(u64, 3),
        try context_budget.normalizeLogicalInput(.deepseek, anthropic_usage),
    );

    const epoch: context_budget.UsageEpoch = .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .checkpoint_generation = 7,
    };
    const exact: context_budget.ExactInputUsage = .{
        .epoch = epoch,
        .logical_input_tokens = 33_123,
    };
    const anchored = try context_budget.selectInputEstimate(.{
        .epoch = epoch,
        .fallback_estimated_tokens = 35_000,
        .trailing_estimated_tokens = 900,
        .exact_usage = exact,
    });
    try testing.expectEqual(context_budget.EstimateSource.actual_plus_trailing, anchored.source);
    try testing.expectEqual(@as(u64, 34_023), anchored.tokens);

    var switched = epoch;
    switched.model = "deepseek-v4-pro";
    const after_model_switch = try context_budget.selectInputEstimate(.{
        .epoch = switched,
        .fallback_estimated_tokens = 35_000,
        .trailing_estimated_tokens = 900,
        .exact_usage = exact,
    });
    try testing.expectEqual(context_budget.EstimateSource.full_estimate, after_model_switch.source);
    try testing.expectEqual(@as(u64, 35_000), after_model_switch.tokens);

    var checkpointed = epoch;
    checkpointed.checkpoint_generation += 1;
    const after_checkpoint = try context_budget.selectInputEstimate(.{
        .epoch = checkpointed,
        .fallback_estimated_tokens = 35_000,
        .trailing_estimated_tokens = 900,
        .exact_usage = exact,
    });
    try testing.expectEqual(context_budget.EstimateSource.full_estimate, after_checkpoint.source);
}

test "pinned estimator fixtures reject undercounts and excessive overestimates" {
    const deepseek_primary = [_]struct { actual: u64, estimated: u64 }{
        .{ .actual = 28_747, .estimated = 30_100 },
        .{ .actual = 33_123, .estimated = 35_000 },
        .{ .actual = 42_053, .estimated = 45_500 },
        .{ .actual = 51_573, .estimated = 56_000 },
    };
    for (deepseek_primary) |fixture| {
        try context_budget.validateCalibration(fixture.estimated, fixture.actual);
    }

    const local_calibration = [_]struct { actual: u64, estimated: u64 }{
        .{ .actual = 28_463, .estimated = 31_000 },
        .{ .actual = 29_590, .estimated = 32_000 },
        .{ .actual = 36_393, .estimated = 39_000 },
    };
    for (local_calibration) |fixture| {
        try context_budget.validateCalibration(fixture.estimated, fixture.actual);
    }

    try testing.expectError(
        error.EstimatorUndercount,
        context_budget.validateCalibration(28_746, 28_747),
    );
    try testing.expectError(
        error.EstimatorOverestimate,
        context_budget.validateCalibration(40_000, 28_747),
    );
}
