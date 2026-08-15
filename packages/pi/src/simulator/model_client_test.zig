const std = @import("std");
const testing = std.testing;

const artifact = @import("artifact.zig");
const model_client = @import("model_client.zig");
const compaction = @import("../compaction.zig");
const context_budget = @import("../context_budget.zig");
const local_client = @import("../providers/local/client.zig");
const deepseek_client = @import("../providers/deepseek/client.zig");
const chat_completions = @import("../providers/chat_completions.zig");
const model_request = @import("../providers/model_request.zig");
const models = @import("../providers/models.zig");
const transcript_mod = @import("../transcript.zig");
const turn = @import("../turn.zig");

const openai_cassette = @embedFile("../providers/testdata/openai/chat_completion.jsonl");

fn bindOpenAiCassette(
    allocator: std.mem.Allocator,
    request_sha256: model_request.Sha256Hex,
) ![]u8 {
    const newline = std.mem.indexOfScalar(u8, openai_cassette, '\n') orelse
        return error.MalformedTestCassette;
    if (newline == 0 or openai_cassette[newline - 1] != '}') {
        return error.MalformedTestCassette;
    }
    return std.fmt.allocPrint(
        allocator,
        "{s},\"request_sha256\":\"{s}\"{s}",
        .{
            openai_cassette[0 .. newline - 1],
            request_sha256.slice(),
            openai_cassette[newline - 1 ..],
        },
    );
}

test "canonical request snapshot covers every model-visible input" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "call_1", .name = "workspace_read", .args_json = "{\"path\":\"handler.ts\"}" },
    };
    try transcript.append(testing.allocator, .{ .user_text = "inspect" });
    try transcript.append(testing.allocator, .{ .proof_card = .{ .llm_text = "display only" } });
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read",
        .ok = true,
        .llm_text = "export default 1;",
    } });
    try transcript.append(testing.allocator, .{ .system_note = "compacted context" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snapshot = try model_request.createSnapshot(arena.allocator(), .{
        .config = .{
            .provider = .openai,
            .model = "gpt-test",
            .max_output_tokens = 4096,
            .system_prompt = "persona",
            .tools_json = "[{\"name\":\"workspace_read\"}]",
        },
        .transcript = &transcript,
        .extra_user_text = "retry after veto",
    });

    try testing.expectEqual(@as(usize, 4), snapshot.items.len);
    try testing.expectEqual(model_request.ItemTag.user_text, std.meta.activeTag(snapshot.items[0]));
    try testing.expectEqual(model_request.ItemTag.tool_use, std.meta.activeTag(snapshot.items[1]));
    try testing.expectEqual(model_request.ItemTag.tool_result, std.meta.activeTag(snapshot.items[2]));
    try testing.expectEqual(model_request.ItemTag.system_note, std.meta.activeTag(snapshot.items[3]));
    try testing.expect(snapshot.transient_user_text_sha256 != null);

    const changed_policy = try model_request.createSnapshot(arena.allocator(), .{
        .config = .{
            .provider = .openai,
            .model = "gpt-test",
            .max_output_tokens = 8192,
            .system_prompt = "persona",
            .tools_json = "[{\"name\":\"workspace_read\"}]",
        },
        .transcript = &transcript,
        .extra_user_text = "retry after veto",
    });
    try testing.expect(!snapshot.request_context_sha256.eql(changed_policy.request_context_sha256));

    try transcript.append(testing.allocator, .{ .model_text = "done" });
    const changed_transcript = try model_request.createSnapshot(arena.allocator(), .{
        .config = .{
            .provider = .openai,
            .model = "gpt-test",
            .max_output_tokens = 4096,
            .system_prompt = "persona",
            .tools_json = "[{\"name\":\"workspace_read\"}]",
        },
        .transcript = &transcript,
        .extra_user_text = "retry after veto",
    });
    try testing.expect(!snapshot.transcript_sha256.eql(changed_transcript.transcript_sha256));
}

test "canonical request snapshot hides host apply_edit baseline while raw history keeps it" {
    const raw_apply_edit_args =
        "{\"file\":\"handler.ts\",\"content\":\"new\",\"before\":\"old\",\"baseline_state\":\"present\",\"baseline_sha256\":\"0123456789abcdef\",\"reason\":\"repair\"}";
    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_edit", .name = "apply_edit", .args_json = raw_apply_edit_args },
        .{ .id = "toolu_other", .name = "inspect", .args_json = "{\"path\":\"handler.ts\"}" },
    };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });

    var snapshot = try model_request.createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .deepseek,
            .model = "deepseek-chat",
            .max_output_tokens = 1024,
            .system_prompt = "system",
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);

    switch (transcript.at(0).*) {
        .assistant_tool_use => |raw_calls| {
            try testing.expectEqualStrings(raw_apply_edit_args, raw_calls[0].args_json);
        },
        else => return error.TestExpectedRawToolUse,
    }
    switch (snapshot.items[0]) {
        .tool_use => |call| try testing.expectEqualStrings(
            "{\"file\":\"handler.ts\",\"content\":\"new\",\"reason\":\"repair\"}",
            call.args_json,
        ),
        else => return error.TestExpectedProjectedToolUse,
    }
    switch (snapshot.items[1]) {
        .tool_use => |call| try testing.expectEqualStrings("{\"path\":\"handler.ts\"}", call.args_json),
        else => return error.TestExpectedUnchangedToolUse,
    }

    const wire_body = try chat_completions.buildRequestBodyFromSnapshot(testing.allocator, &snapshot);
    defer testing.allocator.free(wire_body);
    try testing.expect(std.mem.indexOf(u8, wire_body, "baseline_state") == null);
    try testing.expect(std.mem.indexOf(u8, wire_body, "baseline_sha256") == null);
    try testing.expect(std.mem.indexOf(u8, wire_body, "\\\"before\\\"") == null);
}

test "canonical request snapshot carries malformed apply_edit history verbatim" {
    // `loop` appends a raw tool batch before rejecting a mixed or truncated
    // one, so model-authored args that never parsed are already in the
    // transcript. Refusing them here would fail every later request in the
    // session, including compaction, over one off-spec call.
    const truncated_args = "{\"file\":\"handler.ts\",\"content\":";
    const calls = [_]turn.ToolCall{.{
        .id = "toolu_edit",
        .name = "apply_edit",
        .args_json = truncated_args,
    }};
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });

    var snapshot = try model_request.createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .deepseek,
            .model = "deepseek-chat",
            .max_output_tokens = 1024,
            .system_prompt = "system",
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);

    switch (snapshot.items[0]) {
        .tool_use => |call| try testing.expectEqualStrings(truncated_args, call.args_json),
        else => return error.TestExpectedRawToolUse,
    }
}

test "canonical request snapshot records the active projection cut" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "old request" });
    try transcript.append(testing.allocator, .{ .model_text = "retained response" });
    try transcript.replaceProjection(testing.allocator, "validated summary", 2);

    var snapshot = try model_request.createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .deepseek,
            .model = deepseek_client.default_model,
            .max_output_tokens = deepseek_client.default_max_tokens,
            .stream = false,
            .system_prompt = "persona",
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(?transcript_mod.EntryId, 2), snapshot.projection_first_kept_entry_id);
    try testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try testing.expectEqual(model_request.ItemTag.compaction_summary, std.meta.activeTag(snapshot.items[0]));
    try testing.expectEqual(model_request.ItemTag.model_text, std.meta.activeTag(snapshot.items[1]));
}

test "every provider preparation binds the exact serialized wire body" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "inspect handler.ts" });

    const providers = [_]models.Provider{ .local, .anthropic, .openai, .deepseek };
    for (providers) |provider| {
        const model = models.defaultForProvider(provider);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var snapshot = try model_request.createSnapshot(arena.allocator(), .{
            .config = .{
                .provider = provider,
                .model = model.id,
                .max_output_tokens = model.request_policy.max_output_tokens,
                .system_prompt = "persona",
                .tools_json = "[]",
            },
            .transcript = &transcript,
        });
        const body = try model_client.prepareSnapshot(arena.allocator(), &snapshot);
        const expected = model_request.Sha256Hex.fromRawBytes(body);
        try testing.expect(snapshot.wire_request_sha256.?.eql(expected));
    }
}

test "simulator client rejects a semantic mismatch without consuming the response" {
    var expected_transcript: transcript_mod.Transcript = .{};
    defer expected_transcript.deinit(testing.allocator);
    try expected_transcript.append(testing.allocator, .{ .user_text = "expected" });

    var actual_transcript: transcript_mod.Transcript = .{};
    defer actual_transcript.deinit(testing.allocator);
    try actual_transcript.append(testing.allocator, .{ .user_text = "different" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "persona",
        .tools_json = null,
    };
    var expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
        .extra_user_text = null,
    });
    _ = try model_client.prepareSnapshot(arena.allocator(), &expected);
    const checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
    const bound_cassette = try bindOpenAiCassette(arena.allocator(), expected.wire_request_sha256.?);
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = artifact.Sha256Hex.fromBytes(bound_cassette),
    }};
    const fixtures = [_]artifact.LoadedFixture{.{
        .role = .response,
        .path = "responses/0.jsonl",
        .bytes = bound_cassette,
    }};
    var client = model_client.Client.init(.{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .checkpoints = &checkpoints,
        .responses = &responses,
        .fixtures = &fixtures,
    }, request_config);

    const model = client.asModelClient();
    client.request_config.system_prompt = "changed persona";
    try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &expected_transcript, null));
    try testing.expectEqual(@as(usize, 0), client.consumedCount());
    switch (client.lastMismatch().?) {
        .model_context_mismatch => {},
        else => return error.TestFailed,
    }

    client.request_config.system_prompt = request_config.system_prompt;
    try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &actual_transcript, null));
    try testing.expectEqual(@as(usize, 0), client.consumedCount());
    switch (client.lastMismatch().?) {
        .transcript_or_transient_prompt_mismatch => |detail| {
            try testing.expectEqual(@as(?u32, 0), detail.turn_index);
            try testing.expectEqual(@as(?u32, 0), detail.call_index);
        },
        else => return error.TestFailed,
    }

    try testing.expectError(
        error.ReplayMismatch,
        model.request(arena.allocator(), &expected_transcript, "unexpected retry"),
    );
    try testing.expectEqual(@as(usize, 0), client.consumedCount());
    switch (client.lastMismatch().?) {
        .transcript_or_transient_prompt_mismatch => {},
        else => return error.TestFailed,
    }

    const result = try model.request(arena.allocator(), &expected_transcript, null);
    switch (result.reply.response) {
        .final_text => |text| try testing.expectEqualStrings("hello world", text),
        else => return error.TestFailed,
    }
    try testing.expectEqual(@as(usize, 1), client.consumedCount());
}

test "simulator summarizer consumes a purpose-specific request checkpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "normal persona",
    };
    const summary_request: compaction.SummaryRequest = .{
        .system_prompt = "summary contract",
        .user_prompt = "summarize this span",
        .max_output_tokens = @as(u32, 512),
    };
    var summary_transcript: transcript_mod.Transcript = .{};
    defer summary_transcript.deinit(allocator);
    try summary_transcript.append(allocator, .{ .user_text = summary_request.user_prompt });
    var summary_config = request_config;
    summary_config.system_prompt = summary_request.system_prompt;
    summary_config.tools_json = null;
    summary_config.max_output_tokens = summary_request.max_output_tokens;
    summary_config.purpose = .summarization;
    summary_config.cache_policy = .disabled;
    var snapshot = try model_request.createSnapshot(allocator, .{
        .config = summary_config,
        .transcript = &summary_transcript,
    });
    _ = try model_client.prepareSnapshot(allocator, &snapshot);
    const checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&snapshot)};
    const bound_cassette = try bindOpenAiCassette(allocator, snapshot.wire_request_sha256.?);
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = artifact.Sha256Hex.fromBytes(bound_cassette),
    }};
    const fixtures = [_]artifact.LoadedFixture{.{
        .role = .response,
        .path = "responses/0.jsonl",
        .bytes = bound_cassette,
    }};
    var client = model_client.Client.init(.{
        .provider = .openai,
        .model = request_config.model,
        .evidence_class = .empirical_model,
        .checkpoints = &checkpoints,
        .responses = &responses,
        .fixtures = &fixtures,
    }, request_config);
    const normal_anchor: context_budget.InputAnchor = .{
        .usage = .{
            .epoch = .{
                .provider = .openai,
                .model = request_config.model,
                .checkpoint_generation = 0,
            },
            .logical_input_tokens = 42,
        },
        .budget = snapshot.budget.?,
    };
    client.input_anchor = normal_anchor;

    const result = try client.asSummarizer().summarize(allocator, summary_request);
    switch (result.response) {
        .final_text => |text| try testing.expectEqualStrings("hello world", text),
        else => return error.TestFailed,
    }
    try testing.expectEqual(@as(usize, 1), client.consumedCount());
    try testing.expectEqual(
        normal_anchor.usage.logical_input_tokens,
        client.input_anchor.?.usage.logical_input_tokens,
    );
    try testing.expect(normal_anchor.usage.epoch.eql(client.input_anchor.?.usage.epoch));
    try testing.expectEqual(normal_anchor.budget.bytes.wire, client.input_anchor.?.budget.bytes.wire);
}

test "local replay rejects a wire framing mismatch before releasing a response" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "inspect handler.ts" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request_config: model_request.Config = .{
        .provider = .local,
        .model = local_client.default_model,
        .max_output_tokens = local_client.default_max_tokens,
        .system_prompt = "persona",
        .tools_json = "[]",
        .stream = false,
    };
    var expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &transcript,
    });
    const body = try local_client.buildRequestBody(arena.allocator(), .{
        .system_prompt = request_config.system_prompt,
        .model = request_config.model,
        .max_tokens = request_config.max_output_tokens,
        .tools_json = request_config.tools_json,
    }, &transcript, null);
    expected.wire_request_sha256 = model_request.Sha256Hex.fromRawBytes(body);

    var checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
    const response =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"ok\"}}]}";
    const cassette = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"v\":1,\"provider\":\"local\",\"stream\":false,\"request_sha256\":\"{s}\"}}\n{{\"body\":{f}}}\n",
        .{ expected.wire_request_sha256.?.slice(), std.json.fmt(response, .{}) },
    );
    defer testing.allocator.free(cassette);
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = artifact.Sha256Hex.fromBytes(cassette),
    }};
    const fixtures = [_]artifact.LoadedFixture{.{
        .role = .response,
        .path = "responses/0.jsonl",
        .bytes = cassette,
    }};

    checkpoints[0].wire_request_sha256 = .{ .bytes = [_]u8{'0'} ** 64 };
    var client = model_client.Client.init(.{
        .provider = .local,
        .model = local_client.default_model,
        .checkpoints = &checkpoints,
        .responses = &responses,
        .fixtures = &fixtures,
    }, request_config);
    const model = client.asModelClient();
    try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &transcript, null));
    try testing.expectEqual(@as(usize, 0), client.consumedCount());
    try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .transcript_or_transient_prompt_mismatch);
}

test "every Chat Completions provider rebuilds its wire digest on replay" {
    // The recorder stores a wire digest for each non-streaming provider. If
    // replay rebuilds that body for only some of them, the checkpoint carries
    // a digest the snapshot lacks and every call fails as a
    // transcript_or_transient_prompt_mismatch, which is what a DeepSeek
    // recording hit before this path covered more than `.local`.
    const cases = [_]struct {
        provider: artifact.Provider,
        model: []const u8,
        max_output_tokens: u32,
        header_name: []const u8,
    }{
        .{
            .provider = .local,
            .model = local_client.default_model,
            .max_output_tokens = local_client.default_max_tokens,
            .header_name = "local",
        },
        .{
            .provider = .deepseek,
            .model = deepseek_client.default_model,
            .max_output_tokens = deepseek_client.default_max_tokens,
            .header_name = "deepseek",
        },
    };

    for (cases) |case| {
        var transcript: transcript_mod.Transcript = .{};
        defer transcript.deinit(testing.allocator);
        try transcript.append(testing.allocator, .{ .user_text = "inspect handler.ts" });

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const request_config: model_request.Config = .{
            .provider = case.provider,
            .model = case.model,
            .max_output_tokens = case.max_output_tokens,
            .system_prompt = "persona",
            .tools_json = "[]",
            .stream = false,
        };
        var expected = try model_request.createSnapshot(arena.allocator(), .{
            .config = request_config,
            .transcript = &transcript,
        });
        const body = try chat_completions.buildRequestBody(arena.allocator(), .{
            .system_prompt = request_config.system_prompt,
            .model = request_config.model,
            .max_tokens = request_config.max_output_tokens,
            .tools_json = request_config.tools_json,
        }, &transcript, null);
        expected.wire_request_sha256 = model_request.Sha256Hex.fromRawBytes(body);

        var checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
        const response =
            "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"ok\"}}]}";
        const cassette = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"v\":1,\"provider\":\"{s}\",\"stream\":false,\"request_sha256\":\"{s}\"}}\n{{\"body\":{f}}}\n",
            .{
                case.header_name,
                expected.wire_request_sha256.?.slice(),
                std.json.fmt(response, .{}),
            },
        );
        defer testing.allocator.free(cassette);
        const responses = [_]artifact.ResponseFixture{.{
            .index = 0,
            .turn_index = 0,
            .call_index = 0,
            .path = "responses/0.jsonl",
            .sha256 = artifact.Sha256Hex.fromBytes(cassette),
        }};
        const fixtures = [_]artifact.LoadedFixture{.{
            .role = .response,
            .path = "responses/0.jsonl",
            .bytes = cassette,
        }};

        var client = model_client.Client.init(.{
            .provider = case.provider,
            .model = case.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        const model = client.asModelClient();
        const result = try model.request(arena.allocator(), &transcript, null);
        try testing.expectEqualStrings("ok", result.reply.response.final_text);
        try testing.expectEqual(@as(usize, 1), client.consumedCount());
        try testing.expect(client.lastMismatch() == null);
    }
}

test "simulator checkpoints bind request budgets normalized usage and projection identity" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "old request" });
    try transcript.append(testing.allocator, .{ .model_text = "retained response" });
    try transcript.replaceProjection(testing.allocator, "validated summary", 2);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request_config: model_request.Config = .{
        .provider = .deepseek,
        .model = deepseek_client.default_model,
        .max_output_tokens = deepseek_client.default_max_tokens,
        .stream = false,
        .system_prompt = "persona",
        .tools_json = "[]",
    };
    var expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &transcript,
    });
    _ = try model_client.prepareSnapshot(arena.allocator(), &expected);

    var checkpoint = checkpointFromSnapshot(&expected);
    checkpoint.normalized_input_tokens = 9;
    const response =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"ok\"}}]," ++
        "\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":1}}";
    const cassette = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"v\":1,\"provider\":\"deepseek\",\"stream\":false," ++
            "\"request_sha256\":\"{s}\"}}\n{{\"body\":{f}}}\n",
        .{ expected.wire_request_sha256.?.slice(), std.json.fmt(response, .{}) },
    );
    defer testing.allocator.free(cassette);
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = artifact.Sha256Hex.fromBytes(cassette),
    }};
    const fixtures = [_]artifact.LoadedFixture{.{
        .role = .response,
        .path = "responses/0.jsonl",
        .bytes = cassette,
    }};

    {
        const checkpoints = [_]artifact.ModelCheckpoint{checkpoint};
        var client = model_client.Client.init(.{
            .provider = .deepseek,
            .model = request_config.model,
            .evidence_class = .empirical_model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        client.input_anchor = .{
            .usage = .{
                .epoch = .{
                    .provider = .deepseek,
                    .model = request_config.model,
                    .checkpoint_generation = transcript.projection.?.first_kept_entry_id,
                },
                .logical_input_tokens = 10_000,
            },
            .budget = checkpoint.request_budget.?,
        };
        const result = try client.asModelClient().request(arena.allocator(), &transcript, null);
        try testing.expectEqualStrings("ok", result.reply.response.final_text);
        try testing.expectEqual(
            transcript.projection.?.first_kept_entry_id,
            client.input_anchor.?.usage.epoch.checkpoint_generation,
        );
        try testing.expectEqual(@as(u64, 10_000), client.input_anchor.?.usage.logical_input_tokens);
    }

    {
        var changed = checkpoint;
        changed.projection_first_kept_entry_id = 1;
        const checkpoints = [_]artifact.ModelCheckpoint{changed};
        var client = model_client.Client.init(.{
            .provider = .deepseek,
            .model = request_config.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        try testing.expectError(
            error.ReplayMismatch,
            client.asModelClient().request(arena.allocator(), &transcript, null),
        );
        try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .transcript_or_transient_prompt_mismatch);
    }

    {
        var changed = checkpoint;
        changed.request_budget.?.tokens.total += 1;
        const checkpoints = [_]artifact.ModelCheckpoint{changed};
        var client = model_client.Client.init(.{
            .provider = .deepseek,
            .model = request_config.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        try testing.expectError(
            error.ReplayMismatch,
            client.asModelClient().request(arena.allocator(), &transcript, null),
        );
        try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .request_budget_mismatch);
    }

    {
        var changed = checkpoint;
        changed.normalized_input_tokens = 10;
        const checkpoints = [_]artifact.ModelCheckpoint{changed};
        var client = model_client.Client.init(.{
            .provider = .deepseek,
            .model = request_config.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        try testing.expectError(
            error.ReplayMismatch,
            client.asModelClient().request(arena.allocator(), &transcript, null),
        );
        try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .normalized_input_mismatch);
    }
}

test "adversarial request mutations fail before releasing a response" {
    var expected_transcript: transcript_mod.Transcript = .{};
    defer expected_transcript.deinit(testing.allocator);
    try appendRequestProbeTranscript(
        &expected_transcript,
        "repair the handler",
        "export function handler() {}",
        "Veto ZTS500: declared proof missing",
        false,
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "persona",
        .tools_json = "[{\"name\":\"workspace_read\"}]",
    };
    var expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
    });
    _ = try model_client.prepareSnapshot(arena.allocator(), &expected);
    const checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
    const responses = [_]artifact.ResponseFixture{.{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .path = "responses/0.jsonl",
        .sha256 = artifact.Sha256Hex.fromBytes(openai_cassette),
    }};
    const fixtures = [_]artifact.LoadedFixture{.{
        .role = .response,
        .path = "responses/0.jsonl",
        .bytes = openai_cassette,
    }};

    const transcript_mutations = [_]struct {
        prompt: []const u8,
        tool_result: []const u8,
        diagnostic: []const u8,
        reorder: bool,
    }{
        .{ .prompt = "different prompt", .tool_result = "export function handler() {}", .diagnostic = "Veto ZTS500: declared proof missing", .reorder = false },
        .{ .prompt = "repair the handler", .tool_result = "tampered tool result", .diagnostic = "Veto ZTS500: declared proof missing", .reorder = false },
        .{ .prompt = "repair the handler", .tool_result = "export function handler() {}", .diagnostic = "different Veto diagnostic", .reorder = false },
        .{ .prompt = "repair the handler", .tool_result = "export function handler() {}", .diagnostic = "Veto ZTS500: declared proof missing", .reorder = true },
    };
    for (transcript_mutations) |mutation| {
        var actual: transcript_mod.Transcript = .{};
        defer actual.deinit(testing.allocator);
        try appendRequestProbeTranscript(
            &actual,
            mutation.prompt,
            mutation.tool_result,
            mutation.diagnostic,
            mutation.reorder,
        );
        var client = model_client.Client.init(.{
            .provider = .openai,
            .model = request_config.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);
        const model = client.asModelClient();
        try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &actual, null));
        try testing.expectEqual(@as(usize, 0), client.consumedCount());
        try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .transcript_or_transient_prompt_mismatch);
    }

    for ([_]model_request.Config{
        blk: {
            var changed = request_config;
            changed.system_prompt = "different persona";
            break :blk changed;
        },
        blk: {
            var changed = request_config;
            changed.tools_json = "[{\"name\":\"workspace_write\"}]";
            break :blk changed;
        },
    }) |changed_config| {
        var client = model_client.Client.init(.{
            .provider = .openai,
            .model = request_config.model,
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, changed_config);
        const model = client.asModelClient();
        try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &expected_transcript, null));
        try testing.expectEqual(@as(usize, 0), client.consumedCount());
        try testing.expect(std.meta.activeTag(client.lastMismatch().?) == .model_context_mismatch);
    }
}

test "simulator client maps malformed and unreadable response fixtures without advancing" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "expected" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "persona",
    };
    var expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &transcript,
    });
    _ = try model_client.prepareSnapshot(arena.allocator(), &expected);
    const checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
    const malformed_sse = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"v\":1,\"provider\":\"openai\",\"stream\":true," ++
            "\"request_sha256\":\"{s}\"}}\n{{\"sse\":\"not an SSE event\"}}",
        .{expected.wire_request_sha256.?.slice()},
    );
    const cases = [_]struct {
        bytes: []const u8,
        failure: artifact.ResponseFixtureFailure,
    }{
        .{ .bytes = "not-json\n", .failure = .malformed },
        .{
            .bytes = "{\"v\":1,\"provider\":\"openai\",\"stream\":true,\"sse_path\":\"missing.sse.txt\"}\n",
            .failure = .unreadable,
        },
        .{
            .bytes = malformed_sse,
            .failure = .malformed,
        },
    };

    for (cases) |case| {
        const responses = [_]artifact.ResponseFixture{.{
            .index = 0,
            .turn_index = 0,
            .call_index = 0,
            .path = "responses/0.jsonl",
            .sha256 = artifact.Sha256Hex.fromBytes(case.bytes),
        }};
        const fixtures = [_]artifact.LoadedFixture{.{
            .role = .response,
            .path = "responses/0.jsonl",
            .bytes = case.bytes,
        }};
        var client = model_client.Client.init(.{
            .provider = .openai,
            .model = "gpt-4o-mini",
            .checkpoints = &checkpoints,
            .responses = &responses,
            .fixtures = &fixtures,
        }, request_config);

        const model = client.asModelClient();
        for (0..2) |_| {
            try testing.expectError(error.ReplayMismatch, model.request(arena.allocator(), &transcript, null));
            try testing.expectEqual(@as(usize, 0), client.consumedCount());
            switch (client.lastMismatch().?) {
                .response_fixture_mismatch => |mismatch| {
                    try testing.expectEqual(case.failure, mismatch.kind);
                    try testing.expectEqual(@as(?u32, 0), mismatch.turn_index);
                    try testing.expectEqual(@as(?u32, 0), mismatch.call_index);
                },
                else => return error.TestFailed,
            }
        }
    }
}

fn checkpointFromSnapshot(snapshot: *const model_request.ModelRequestSnapshot) artifact.ModelCheckpoint {
    return .{
        .index = 0,
        .turn_index = 0,
        .call_index = 0,
        .transcript_prefix_count = @intCast(snapshot.items.len),
        .transcript_sha256 = .{ .bytes = snapshot.transcript_sha256.bytes },
        .request_context_sha256 = .{ .bytes = snapshot.request_context_sha256.bytes },
        .transient_user_text_sha256 = if (snapshot.transient_user_text_sha256) |digest|
            .{ .bytes = digest.bytes }
        else
            null,
        .wire_request_sha256 = if (snapshot.wire_request_sha256) |digest|
            .{ .bytes = digest.bytes }
        else
            null,
        .request_budget = snapshot.budget,
        .projection_first_kept_entry_id = snapshot.projection_first_kept_entry_id,
    };
}

fn appendRequestProbeTranscript(
    transcript: *transcript_mod.Transcript,
    prompt: []const u8,
    tool_result: []const u8,
    diagnostic: []const u8,
    reorder: bool,
) !void {
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read",
        .args_json = "{\"path\":\"handler.ts\"}",
    }};
    try transcript.append(testing.allocator, .{ .user_text = prompt });
    try transcript.append(testing.allocator, .{ .assistant_tool_use = &calls });
    if (reorder) try transcript.append(testing.allocator, .{ .system_note = diagnostic });
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read",
        .ok = true,
        .llm_text = tool_result,
    } });
    if (!reorder) try transcript.append(testing.allocator, .{ .system_note = diagnostic });
}
