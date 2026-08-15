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

const CapturedDeepSeekInput = struct {
    system_bytes: u64 = 7_142,
    tools_bytes: u64 = 20_252,
    wire_bytes: u64,
    history_bytes: u64,
    transient_bytes: u64 = 0,
    actual_tokens: u64,
    checkpoint_generation: u64 = 0,
};

fn expectCapturedDeepSeekFlowCalibrates(captured: []const CapturedDeepSeekInput) !void {
    try testing.expect(captured.len > 0);
    const limits = context_budget.limitsForModel(.deepseek, "deepseek-v4-flash");
    var anchor: ?context_budget.InputAnchor = null;
    var compaction_bridge: ?context_budget.InputAnchor = null;
    var previous_generation: ?u64 = null;

    for (captured, 0..) |fixture, fixture_index| {
        if (previous_generation != fixture.checkpoint_generation) {
            compaction_bridge = anchor;
            anchor = null;
        }
        const epoch: context_budget.UsageEpoch = .{
            .provider = .deepseek,
            .model = "deepseek-v4-flash",
            .checkpoint_generation = fixture.checkpoint_generation,
        };
        const budget = try context_budget.estimate(.{
            .system = fixture.system_bytes,
            .tools = fixture.tools_bytes,
            .history = fixture.history_bytes,
            .transient = fixture.transient_bytes,
        }, fixture.wire_bytes, limits);
        const selected = try context_budget.selectInputEstimate(.{
            .epoch = epoch,
            .current_budget = budget,
            .anchor = anchor,
            .compaction_bridge = compaction_bridge,
        });
        const observed = try context_budget.observeLogicalInput(.{
            .epoch = epoch,
            .current_budget = budget,
            .anchor = anchor,
            .compaction_bridge = compaction_bridge,
            .reported_tokens = fixture.actual_tokens,
        });
        context_budget.validateCalibration(selected.tokens, observed.logical_input_tokens) catch |err| {
            std.debug.print(
                "fixture {d}: wire={d} estimated={d} reported={d} logical={d} estimate_source={s} observation_source={s}: {s}\n",
                .{
                    fixture_index,
                    fixture.wire_bytes,
                    selected.tokens,
                    fixture.actual_tokens,
                    observed.logical_input_tokens,
                    @tagName(selected.source),
                    @tagName(observed.source),
                    @errorName(err),
                },
            );
            return err;
        };
        anchor = .{
            .usage = .{ .epoch = epoch, .logical_input_tokens = observed.logical_input_tokens },
            .budget = budget,
        };
        compaction_bridge = null;
        previous_generation = fixture.checkpoint_generation;
    }
}

test "fresh estimate stays calibrated after current validate body compaction" {
    // Captured from the 2026-08-16 direct-cutover corpus. The first request
    // after checkpoint 13 has no same-epoch usage anchor. A single density for
    // fixed schemas and conversation history overestimated it by 4,446 tokens.
    const captured = [_]CapturedDeepSeekInput{
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 24_733, .history_bytes = 232, .actual_tokens = 6_154 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 28_085, .history_bytes = 2_969, .actual_tokens = 7_260 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 60_634, .history_bytes = 32_223, .actual_tokens = 14_531 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 114_978, .history_bytes = 80_016, .actual_tokens = 28_181 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 129_350, .history_bytes = 93_480, .actual_tokens = 32_163 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 55_249, .history_bytes = 28_844, .actual_tokens = 15_509, .checkpoint_generation = 13 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 61_864, .history_bytes = 34_731, .actual_tokens = 17_378, .checkpoint_generation = 13 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 64_297, .history_bytes = 36_786, .actual_tokens = 20_382, .checkpoint_generation = 13 },
        .{ .system_bytes = 3_871, .tools_bytes = 20_390, .wire_bytes = 66_274, .history_bytes = 38_390, .actual_tokens = 23_342, .checkpoint_generation = 13 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

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
    const stable: context_budget.StableInputUsage = .{
        .epoch = epoch,
        .logical_input_tokens = 33_123,
    };
    const anchor_budget = try context_budget.estimate(.{
        .system = 100,
        .tools = 200,
        .history = 300,
        .transient = 0,
    }, 700, .{ .context_window_tokens = 100_000 });
    const anchored = try context_budget.selectInputEstimate(.{
        .epoch = epoch,
        .current_budget = anchor_budget,
        .anchor = .{ .usage = stable, .budget = anchor_budget },
    });
    try testing.expectEqual(context_budget.EstimateSource.anchored_density, anchored.source);
    try testing.expectEqual(@as(u64, 33_123), anchored.tokens);

    var switched = epoch;
    switched.model = "deepseek-v4-pro";
    const after_model_switch = try context_budget.selectInputEstimate(.{
        .epoch = switched,
        .current_budget = anchor_budget,
        .anchor = .{ .usage = stable, .budget = anchor_budget },
    });
    try testing.expectEqual(context_budget.EstimateSource.full_estimate, after_model_switch.source);
    try testing.expectEqual(anchor_budget.tokens.total, after_model_switch.tokens);

    var checkpointed = epoch;
    checkpointed.checkpoint_generation += 1;
    const after_checkpoint = try context_budget.selectInputEstimate(.{
        .epoch = checkpointed,
        .current_budget = anchor_budget,
        .anchor = .{ .usage = stable, .budget = anchor_budget },
    });
    try testing.expectEqual(context_budget.EstimateSource.full_estimate, after_checkpoint.source);
    try testing.expectEqual(anchor_budget.tokens.total, after_checkpoint.tokens);

    const compacted_budget = try context_budget.estimate(.{
        .system = 100,
        .tools = 200,
        .history = 100,
        .transient = 0,
    }, 450, .{ .context_window_tokens = 100_000 });
    const bridged = try context_budget.selectInputEstimate(.{
        .epoch = checkpointed,
        .current_budget = compacted_budget,
        .anchor = null,
        .compaction_bridge = .{ .usage = stable, .budget = anchor_budget },
    });
    try testing.expectEqual(context_budget.EstimateSource.compaction_bridge_density, bridged.source);
    try testing.expectEqual(@as(u64, 25_340), bridged.tokens);

    const switched_bridge = try context_budget.selectInputEstimate(.{
        .epoch = switched,
        .current_budget = compacted_budget,
        .anchor = null,
        .compaction_bridge = .{ .usage = stable, .budget = anchor_budget },
    });
    try testing.expectEqual(context_budget.EstimateSource.full_estimate, switched_bridge.source);
}

test "logical input observation preserves raw cache discontinuity evidence" {
    const epoch: context_budget.UsageEpoch = .{
        .provider = .deepseek,
        .model = "deepseek-v4-flash",
        .checkpoint_generation = 3,
    };
    const limits: context_budget.ModelLimits = .{ .context_window_tokens = 1_000_000 };
    const previous = try context_budget.estimate(.{
        .system = 100,
        .tools = 100,
        .history = 700,
        .transient = 0,
    }, 1_000, limits);
    const current = try context_budget.estimate(.{
        .system = 100,
        .tools = 100,
        .history = 800,
        .transient = 0,
    }, 1_100, limits);
    const anchor: context_budget.InputAnchor = .{
        .usage = .{ .epoch = epoch, .logical_input_tokens = 300 },
        .budget = previous,
    };

    const calibrated = try context_budget.observeLogicalInput(.{
        .epoch = epoch,
        .current_budget = current,
        .anchor = anchor,
        .reported_tokens = 390,
    });
    try testing.expectEqual(context_budget.InputObservationSource.provider_reported, calibrated.source);
    try testing.expectEqual(@as(u64, 390), calibrated.logical_input_tokens);

    const cache_jump = try context_budget.observeLogicalInput(.{
        .epoch = epoch,
        .current_budget = current,
        .anchor = anchor,
        .reported_tokens = 465,
    });
    try testing.expectEqual(@as(u64, 465), cache_jump.reported_tokens);
    try testing.expectEqual(context_budget.InputObservationSource.prior_density_projection, cache_jump.source);
    try testing.expectEqual(@as(u64, 330), cache_jump.logical_input_tokens);
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

test "anchored estimate stays calibrated across captured DeepSeek health flow" {
    // Captured from the rejected 2026-08-15 health recapture. Call 4 is the
    // regression: its input grew by 745 tokens, while the old tool-heavy floor
    // added 8,192 and exceeded the calibration ceiling.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 28_217, .history_bytes = 503, .actual_tokens = 7_001 },
        .{ .wire_bytes = 29_193, .history_bytes = 1_130, .actual_tokens = 7_300 },
        .{ .wire_bytes = 51_739, .history_bytes = 21_524, .actual_tokens = 12_750 },
        .{ .wire_bytes = 75_753, .history_bytes = 42_599, .actual_tokens = 19_116 },
        .{ .wire_bytes = 77_789, .history_bytes = 44_049, .actual_tokens = 19_861 },
        .{ .wire_bytes = 79_515, .history_bytes = 45_441, .actual_tokens = 20_394 },
        .{ .wire_bytes = 82_305, .history_bytes = 47_750, .actual_tokens = 22_117 },
        .{ .wire_bytes = 89_881, .history_bytes = 54_674, .actual_tokens = 25_115 },
        .{ .wire_bytes = 90_561, .history_bytes = 55_045, .actual_tokens = 25_379 },
        .{ .wire_bytes = 91_903, .history_bytes = 56_100, .actual_tokens = 26_617 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

test "anchored estimate stays calibrated across captured DeepSeek validate body flow" {
    // Captured by the same full-corpus run as the jwt-auth regression. This
    // longer successful case bounds the estimator's upper side after replacing
    // the suffix floor with whole-request density headroom.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 27_919, .history_bytes = 232, .actual_tokens = 6_916 },
        .{ .wire_bytes = 46_880, .history_bytes = 16_258, .actual_tokens = 11_480 },
        .{ .wire_bytes = 59_709, .history_bytes = 27_883, .actual_tokens = 14_975 },
        .{ .wire_bytes = 67_457, .history_bytes = 35_040, .actual_tokens = 17_179 },
        .{ .wire_bytes = 74_598, .history_bytes = 41_721, .actual_tokens = 19_034 },
        .{ .wire_bytes = 83_172, .history_bytes = 49_459, .actual_tokens = 21_510 },
        .{ .wire_bytes = 93_775, .history_bytes = 58_873, .actual_tokens = 25_134 },
        .{ .wire_bytes = 95_362, .history_bytes = 60_159, .actual_tokens = 27_103 },
        .{ .wire_bytes = 97_641, .history_bytes = 62_100, .actual_tokens = 27_746 },
        .{ .wire_bytes = 98_373, .history_bytes = 62_493, .actual_tokens = 28_564 },
        .{ .wire_bytes = 100_175, .history_bytes = 63_974, .actual_tokens = 29_045 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

test "anchored estimate stays calibrated across captured DeepSeek jwt auth compaction flow" {
    // Captured from the rejected 2026-08-15 jwt-auth recapture. Call 4 is the
    // first regression: DeepSeek's cache boundary changes the whole-prompt
    // density enough that adding wire_delta / 3 to call 3 undercounts by 2,298
    // tokens. Calls 8-12 are the normal requests after a compaction checkpoint;
    // production clears the stable-usage anchor at that boundary.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 28_211, .history_bytes = 497, .actual_tokens = 6_981, .checkpoint_generation = 0 },
        .{ .wire_bytes = 46_091, .history_bytes = 15_524, .actual_tokens = 11_283, .checkpoint_generation = 0 },
        .{ .wire_bytes = 52_562, .history_bytes = 21_137, .actual_tokens = 13_237, .checkpoint_generation = 0 },
        .{ .wire_bytes = 77_057, .history_bytes = 43_528, .actual_tokens = 19_206, .checkpoint_generation = 0 },
        .{ .wire_bytes = 94_764, .history_bytes = 59_790, .actual_tokens = 27_407, .checkpoint_generation = 0 },
        .{ .wire_bytes = 118_199, .history_bytes = 81_273, .actual_tokens = 34_762, .checkpoint_generation = 0 },
        .{ .wire_bytes = 119_672, .history_bytes = 82_151, .actual_tokens = 37_374, .checkpoint_generation = 0 },
        .{ .wire_bytes = 105_331, .history_bytes = 70_232, .actual_tokens = 35_995, .checkpoint_generation = 1 },
        .{ .wire_bytes = 106_843, .history_bytes = 71_155, .actual_tokens = 42_900, .checkpoint_generation = 1 },
        .{ .wire_bytes = 108_408, .history_bytes = 72_125, .actual_tokens = 46_394, .checkpoint_generation = 1 },
        .{ .wire_bytes = 109_042, .history_bytes = 72_454, .actual_tokens = 46_542, .checkpoint_generation = 1 },
        .{ .wire_bytes = 109_389, .history_bytes = 72_623, .actual_tokens = 46_667, .checkpoint_generation = 1 },
    };
    const limits = context_budget.limitsForModel(.deepseek, "deepseek-v4-flash");
    const summary_budget = try context_budget.estimate(.{
        .system = 160,
        .tools = 0,
        .history = 3_578,
        .transient = 0,
    }, 4_273, limits);
    try context_budget.validateCalibration(summary_budget.tokens.total, 1_221);
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

test "captured DeepSeek jwt auth cache discontinuities stay calibrated" {
    // Preserved from the rejected 2026-08-15 jwt-auth recording. DeepSeek's
    // reported prompt total drops inside each append-oriented projection even
    // though every persistent request component and the wire body grow.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 28_212, .history_bytes = 497, .actual_tokens = 6_981, .checkpoint_generation = 0 },
        .{ .wire_bytes = 46_092, .history_bytes = 15_524, .actual_tokens = 11_356, .checkpoint_generation = 0 },
        .{ .wire_bytes = 68_350, .history_bytes = 35_823, .actual_tokens = 17_025, .checkpoint_generation = 0 },
        .{ .wire_bytes = 92_160, .history_bytes = 57_452, .actual_tokens = 24_053, .checkpoint_generation = 0 },
        .{ .wire_bytes = 106_081, .history_bytes = 70_466, .actual_tokens = 27_961, .checkpoint_generation = 0 },
        .{ .wire_bytes = 115_258, .history_bytes = 78_915, .actual_tokens = 32_560, .checkpoint_generation = 0 },
        .{ .wire_bytes = 117_932, .history_bytes = 81_114, .actual_tokens = 33_485, .checkpoint_generation = 0 },
        .{ .wire_bytes = 103_727, .history_bytes = 69_329, .actual_tokens = 32_038, .checkpoint_generation = 1 },
        .{ .wire_bytes = 104_872, .history_bytes = 70_012, .actual_tokens = 33_940, .checkpoint_generation = 1 },
        .{ .wire_bytes = 107_468, .history_bytes = 72_200, .actual_tokens = 35_506, .checkpoint_generation = 1 },
        .{ .wire_bytes = 111_208, .history_bytes = 75_328, .actual_tokens = 38_554, .checkpoint_generation = 1 },
        .{ .wire_bytes = 114_929, .history_bytes = 78_376, .transient_bytes = 191, .actual_tokens = 28_432, .checkpoint_generation = 1 },
        .{ .wire_bytes = 98_285, .history_bytes = 63_489, .actual_tokens = 35_423, .checkpoint_generation = 2 },
        .{ .wire_bytes = 102_385, .history_bytes = 66_872, .transient_bytes = 191, .actual_tokens = 25_395, .checkpoint_generation = 2 },
        .{ .wire_bytes = 103_647, .history_bytes = 67_878, .actual_tokens = 27_974, .checkpoint_generation = 2 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

test "captured DeepSeek wait signal density jump stays calibrated" {
    // Preserved from the rejected 2026-08-15 workflow-wait-signal recording.
    // The provider total jumps by 6,935 tokens while the wire grows by only
    // 1,049 bytes, so a prior-density projection cannot replace the full
    // conservative estimate.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 28_545, .history_bytes = 828, .actual_tokens = 7_088 },
        .{ .wire_bytes = 46_425, .history_bytes = 15_855, .actual_tokens = 11_439 },
        .{ .wire_bytes = 64_592, .history_bytes = 32_195, .actual_tokens = 15_763 },
        .{ .wire_bytes = 76_640, .history_bytes = 43_270, .actual_tokens = 18_912 },
        .{ .wire_bytes = 89_011, .history_bytes = 54_690, .actual_tokens = 22_252 },
        .{ .wire_bytes = 98_207, .history_bytes = 63_034, .actual_tokens = 24_753 },
        .{ .wire_bytes = 105_090, .history_bytes = 69_392, .actual_tokens = 26_611 },
        .{ .wire_bytes = 106_139, .history_bytes = 69_975, .actual_tokens = 33_546 },
        .{ .wire_bytes = 106_790, .history_bytes = 70_423, .actual_tokens = 33_855 },
        .{ .wire_bytes = 111_021, .history_bytes = 73_955, .transient_bytes = 191, .actual_tokens = 27_432 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}

test "captured DeepSeek sibling helper cache jumps stay calibrated" {
    // Preserved from the 2026-08-15 sibling-helper-holes recording that exposed
    // three upward cache-accounting discontinuities. The raw totals remain in
    // the fixture while the budgeting observation stabilizes only the values
    // that violate the pre-response calibration envelope.
    const captured = [_]CapturedDeepSeekInput{
        .{ .wire_bytes = 28_422, .history_bytes = 707, .actual_tokens = 7_040 },
        .{ .wire_bytes = 30_129, .history_bytes = 1_963, .actual_tokens = 7_494 },
        .{ .wire_bytes = 32_778, .history_bytes = 4_188, .actual_tokens = 8_549 },
        .{ .wire_bytes = 34_057, .history_bytes = 5_069, .actual_tokens = 9_692 },
        .{ .wire_bytes = 36_316, .history_bytes = 6_740, .actual_tokens = 12_569 },
        .{ .wire_bytes = 37_785, .history_bytes = 7_691, .actual_tokens = 14_029 },
        .{ .wire_bytes = 46_505, .history_bytes = 15_464, .actual_tokens = 18_100 },
        .{ .wire_bytes = 75_184, .history_bytes = 41_719, .actual_tokens = 26_114 },
        .{ .wire_bytes = 77_336, .history_bytes = 43_474, .actual_tokens = 29_315 },
        .{ .wire_bytes = 80_798, .history_bytes = 46_286, .actual_tokens = 30_994 },
        .{ .wire_bytes = 82_843, .history_bytes = 47_836, .actual_tokens = 34_079 },
    };
    try expectCapturedDeepSeekFlowCalibrates(&captured);
}
