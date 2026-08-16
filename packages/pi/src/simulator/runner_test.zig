const std = @import("std");
const testing = std.testing;

const artifact = @import("artifact.zig");
const model_client = @import("model_client.zig");
const model_request = @import("../providers/model_request.zig");
const registry_mod = @import("../registry/registry.zig");
const runner = @import("runner.zig");
const transcript_mod = @import("../transcript.zig");

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

fn zeroDigest() artifact.Sha256Hex {
    return .{ .bytes = [_]u8{'0'} ** 64 };
}

test "flow runner continues a real multi-Turn transcript and preserves exact workspace bytes" {
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "persona",
    };

    var expected_transcript: transcript_mod.Transcript = .{};
    defer expected_transcript.deinit(testing.allocator);
    try expected_transcript.append(testing.allocator, .{ .user_text = "hello" });
    var snapshot_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer snapshot_arena.deinit();
    var first_snapshot = try model_request.createSnapshot(snapshot_arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
    });
    _ = try model_client.prepareSnapshot(snapshot_arena.allocator(), &first_snapshot);
    try expected_transcript.append(testing.allocator, .{ .model_text = "hello world" });
    try expected_transcript.append(testing.allocator, .{ .user_text = "again" });
    var second_snapshot = try model_request.createSnapshot(snapshot_arena.allocator(), .{
        .config = request_config,
        .transcript = &expected_transcript,
    });
    _ = try model_client.prepareSnapshot(snapshot_arena.allocator(), &second_snapshot);
    const first_cassette = try bindOpenAiCassette(
        snapshot_arena.allocator(),
        first_snapshot.wire_request_sha256.?,
    );
    const second_cassette = try bindOpenAiCassette(
        snapshot_arena.allocator(),
        second_snapshot.wire_request_sha256.?,
    );

    const workspace_bytes = "keep these exact bytes\n";
    const checkpoints = [_]artifact.ModelCheckpoint{
        .{
            .index = 0,
            .turn_index = 0,
            .call_index = 0,
            .transcript_prefix_count = @intCast(first_snapshot.items.len),
            .transcript_sha256 = .{ .bytes = first_snapshot.transcript_sha256.bytes },
            .request_context_sha256 = .{ .bytes = first_snapshot.request_context_sha256.bytes },
            .transient_user_text_sha256 = null,
            .wire_request_sha256 = .{ .bytes = first_snapshot.wire_request_sha256.?.bytes },
            .request_budget = first_snapshot.budget,
            .projection_first_kept_entry_id = first_snapshot.projection_first_kept_entry_id,
        },
        .{
            .index = 1,
            .turn_index = 1,
            .call_index = 0,
            .transcript_prefix_count = @intCast(second_snapshot.items.len),
            .transcript_sha256 = .{ .bytes = second_snapshot.transcript_sha256.bytes },
            .request_context_sha256 = .{ .bytes = second_snapshot.request_context_sha256.bytes },
            .transient_user_text_sha256 = null,
            .wire_request_sha256 = .{ .bytes = second_snapshot.wire_request_sha256.?.bytes },
            .request_budget = second_snapshot.budget,
            .projection_first_kept_entry_id = second_snapshot.projection_first_kept_entry_id,
        },
    };
    const responses = [_]artifact.ResponseFixture{
        .{
            .index = 0,
            .turn_index = 0,
            .call_index = 0,
            .path = "responses/0.jsonl",
            .sha256 = artifact.Sha256Hex.fromBytes(first_cassette),
        },
        .{
            .index = 1,
            .turn_index = 1,
            .call_index = 0,
            .path = "responses/1.jsonl",
            .sha256 = artifact.Sha256Hex.fromBytes(second_cassette),
        },
    };
    const workspace = [_]artifact.WorkspaceFixture{.{
        .path = "handler.ts",
        .sha256 = artifact.Sha256Hex.fromBytes(workspace_bytes),
    }};
    const events = [_]artifact.EventExpectation{
        .{
            .index = 0,
            .turn_index = 0,
            .kind = .user_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello"),
        },
        .{
            .index = 1,
            .turn_index = 0,
            .kind = .model_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
        },
        .{
            .index = 2,
            .turn_index = 0,
            .kind = .turn_end,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("approved"),
        },
        .{
            .index = 3,
            .turn_index = 1,
            .kind = .user_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("again"),
        },
        .{
            .index = 4,
            .turn_index = 1,
            .kind = .model_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
        },
        .{
            .index = 5,
            .turn_index = 1,
            .kind = .turn_end,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("approved"),
        },
    };
    const transcript_items = [_]artifact.TranscriptItem{
        .{
            .index = 0,
            .turn_index = 0,
            .kind = .user_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello"),
        },
        .{
            .index = 1,
            .turn_index = 0,
            .kind = .model_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
        },
        .{
            .index = 2,
            .turn_index = 1,
            .kind = .user_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("again"),
        },
        .{
            .index = 3,
            .turn_index = 1,
            .kind = .model_text,
            .payload_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
        },
    };
    const fixtures = [_]artifact.LoadedFixture{
        .{ .role = .response, .path = "responses/0.jsonl", .bytes = first_cassette },
        .{ .role = .response, .path = "responses/1.jsonl", .bytes = second_cassette },
        .{ .role = .initial_workspace, .path = "initial/handler.ts", .bytes = workspace_bytes },
        .{ .role = .turn_workspace, .path = "turns/0/handler.ts", .bytes = workspace_bytes },
        .{ .role = .expected_workspace, .path = "expected/handler.ts", .bytes = workspace_bytes },
    };

    var flow_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer flow_arena.deinit();
    const flow_case = artifact.FlowCase{
        .arena = flow_arena,
        .descriptor = .{
            .schema_version = artifact.schema_version,
            .case_name = "text-only",
            .evidence_class = .deterministic_harness,
            .executable = true,
            .active_generation = zeroDigest(),
        },
        .manifest = .{
            .schema_version = artifact.schema_version,
            .flow_version = zeroDigest(),
            .case_name = "text-only",
            .evidence_class = .deterministic_harness,
            .executable = true,
            .provider = .openai,
            .model = "gpt-4o-mini",
            .turns = &.{
                .{
                    .index = 0,
                    .user_input = "hello",
                    .outcome = .approved,
                    .final_response_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
                },
                .{
                    .index = 1,
                    .user_input = "again",
                    .outcome = .approved,
                    .final_response_sha256 = artifact.Sha256Hex.fromBytes("hello world"),
                },
            },
            .model_responses = &responses,
            .approvals = &.{},
            .events = &events,
            .allowed_workspace_changes = &.{},
            .initial_workspace = &workspace,
            .turn_workspaces = &.{.{ .turn_index = 0, .files = &workspace }},
            .expected_workspace = &workspace,
            .trace = .{ .path = "trace.json", .sha256 = zeroDigest() },
        },
        .trace = .{
            .schema_version = artifact.schema_version,
            .model_calls = &checkpoints,
            .approvals = &.{},
            .transcript_items = &transcript_items,
            .apply_receipts = &.{},
        },
        .fixtures = &fixtures,
        .flow_version = zeroDigest(),
    };

    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    var tampered_fixtures = fixtures;
    tampered_fixtures[3].bytes = "wrong intermediate bytes\n";
    var tampered_flow = flow_case;
    tampered_flow.fixtures = &tampered_fixtures;
    var tampered_runner = runner.Runner.init(testing.allocator, &tampered_flow, &registry, request_config);
    try testing.expectError(error.ReplayMismatch, tampered_runner.run());
    switch (tampered_runner.lastMismatch().?) {
        .workspace_mismatch => |detail| try testing.expectEqual(artifact.Component.turn_workspace, detail.component),
        else => return error.TestFailed,
    }

    var flow_runner = runner.Runner.init(testing.allocator, &flow_case, &registry, request_config);
    const result = try flow_runner.run();

    try testing.expectEqual(@as(usize, 2), result.turns);
    try testing.expectEqual(@as(usize, 2), result.model_calls);
    try testing.expectEqual(@as(usize, 2), result.expected_model_calls);
    try testing.expectEqual(@as(usize, 0), result.approvals);
    try testing.expectEqual(artifact.EvidenceClass.deterministic_harness, result.evidence_class);
    try testing.expect(result.complete_consumption);

    var non_executable = flow_case;
    non_executable.descriptor.executable = false;
    non_executable.manifest.executable = false;
    var refused_runner = runner.Runner.init(testing.allocator, &non_executable, &registry, request_config);
    try testing.expectError(error.ReplayMismatch, refused_runner.run());
    switch (refused_runner.lastMismatch().?) {
        .non_executable_case => {},
        else => return error.TestFailed,
    }
}

test "approval validator rejects digest mismatch without advancing its cursor" {
    var rewrite = "replace_let_with_const".*;
    const rewrite_trace = [_][]u8{rewrite[0..]};
    const changes = [_]@import("../loop.zig").ChangePreview{.{
        .file = "handler.ts",
        .before = "old\n",
        .after = "new\n",
        .rewrite_trace = &rewrite_trace,
    }};
    const expected_preview = @import("../loop.zig").ChangeSetApprovalPreview{
        .proof_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .changes = &changes,
        .system_proven = false,
    };
    const expected_digest = try runner.approvalPreviewDigest(testing.allocator, expected_preview);
    const manifest = [_]artifact.ApprovalExpectation{.{
        .index = 0,
        .turn_index = 0,
        .checkpoint_index = 0,
        .decision = .approve,
    }};
    const trace = [_]artifact.ApprovalCheckpoint{.{
        .index = 0,
        .turn_index = 0,
        .checkpoint_index = 0,
        .preview_sha256 = expected_digest,
    }};
    var validator = runner.ApprovalValidator.init(testing.allocator, &manifest, &trace);
    validator.beginTurn(0);

    const callback = validator.asApprovalFn();
    var changed_changes = changes;
    changed_changes[0].after = "tampered\n";
    var changed = expected_preview;
    changed.changes = &changed_changes;
    try testing.expectError(error.ReplayMismatch, callback.call(changed));
    try testing.expectEqual(@as(usize, 0), validator.consumedCount());
    switch (validator.lastMismatch().?) {
        .approval_mismatch => {},
        else => return error.TestFailed,
    }

    try testing.expect(try callback.call(expected_preview));
    try testing.expectEqual(@as(usize, 1), validator.consumedCount());
    try validator.finish();
}

test "approval validator fails strict exhaustion when a checkpoint is unconsumed" {
    const manifest = [_]artifact.ApprovalExpectation{.{
        .index = 0,
        .turn_index = 0,
        .checkpoint_index = 0,
        .decision = .reject,
    }};
    const trace = [_]artifact.ApprovalCheckpoint{.{
        .index = 0,
        .turn_index = 0,
        .checkpoint_index = 0,
        .preview_sha256 = zeroDigest(),
    }};
    var validator = runner.ApprovalValidator.init(testing.allocator, &manifest, &trace);

    try testing.expectError(error.ReplayMismatch, validator.finish());
    try testing.expectEqual(@as(usize, 0), validator.consumedCount());
    switch (validator.lastMismatch().?) {
        .unconsumed_checkpoint => {},
        else => return error.TestFailed,
    }
}
