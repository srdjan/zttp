const std = @import("std");
const testing = std.testing;

const artifact = @import("artifact.zig");
const model_client = @import("model_client.zig");
const model_request = @import("../providers/model_request.zig");
const transcript_mod = @import("../transcript.zig");
const turn = @import("../turn.zig");

const openai_cassette = @embedFile("../providers/testdata/openai/chat_completion.jsonl");

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
    const expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
        .extra_user_text = null,
    });
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
    const expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
    });
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
    const expected = try model_request.createSnapshot(arena.allocator(), .{
        .config = request_config,
        .transcript = &transcript,
    });
    const checkpoints = [_]artifact.ModelCheckpoint{checkpointFromSnapshot(&expected)};
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
            .bytes =
            \\{"v":1,"provider":"openai","stream":true}
            \\{"sse":"not an SSE event"}
            ,
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
