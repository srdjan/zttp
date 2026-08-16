const std = @import("std");
const artifact = @import("artifact.zig");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

const testing = std.testing;

const Mutation = enum {
    none,
    model_gap,
    model_reordered,
    approval_duplicate,
    event_gap,
    transcript_duplicate,
    receipt_reordered,
    response_orphan,
    missing_initial,
    missing_turn_checkpoint,
    local_valid,
    local_missing_version,
    local_empty_version,
    cloud_version,
    empty_revision,
    local_runtime_only,
    local_runtime_name_only,
    local_runtime_version_only,
    cloud_runtime,
    draft_metric_half,
    draft_metric_mixed,
    draft_metric_impossible,
};

const Fixture = struct {
    tree: IsolatedTmp,
    case_root_abs: [:0]u8,
    generation: []u8,
    flow_version: artifact.Sha256Hex,

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.case_root_abs);
        testing.allocator.free(self.generation);
        self.tree.cleanup(testing.allocator);
    }
};

fn renderJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, out.writer());
    return out.toOwnedSlice();
}

fn zeroDigest() artifact.Sha256Hex {
    return .{ .bytes = [_]u8{'0'} ** 64 };
}

test "draft expectations preserve legacy meaning and reject impossible pairs" {
    const legacy = try (artifact.TurnExpectation{
        .index = 0,
        .user_input = "x",
        .outcome = .approved,
        .final_response_sha256 = artifact.Sha256Hex.fromBytes(""),
        .first_draft_veto_pass = true,
    }).draftExpectation();
    try testing.expect(legacy.matches(.raw_veto_pass));
    try testing.expect(legacy.matches(.normalized));
    try testing.expect(!legacy.matches(.compiler_repaired));

    const current = try (artifact.TurnExpectation{
        .index = 0,
        .user_input = "x",
        .outcome = .approved,
        .final_response_sha256 = artifact.Sha256Hex.fromBytes(""),
        .raw_first_draft_veto_pass = false,
        .first_attempt_green = true,
    }).draftExpectation();
    try testing.expect(current.matches(.normalized));
    try testing.expect(current.matches(.compiler_repaired));
    try testing.expect(!current.matches(.not_green));
    try testing.expectError(error.InvalidDraftExpectation, (artifact.TurnExpectation{
        .index = 0,
        .user_input = "x",
        .outcome = .approved,
        .final_response_sha256 = artifact.Sha256Hex.fromBytes(""),
        .raw_first_draft_veto_pass = true,
        .first_attempt_green = false,
    }).draftExpectation());
}

fn buildCase(mutation: Mutation) !Fixture {
    var tree = try IsolatedTmp.init(testing.allocator, "flow-artifact");
    errdefer tree.cleanup(testing.allocator);

    const initial = "export function handler() { return Response.text(\"old\"); }\n";
    const expected = "export function handler() { return Response.text(\"new\"); }\n";
    const response_0 = "provider response zero\n";
    const response_1 = "provider response one\n";
    const response_2 = "orphan response\n";

    var model_calls = [_]artifact.ModelCheckpoint{
        .{
            .index = 0,
            .turn_index = 0,
            .call_index = 0,
            .transcript_prefix_count = 1,
            .transcript_sha256 = artifact.Sha256Hex.fromBytes("transcript-0"),
            .request_context_sha256 = artifact.Sha256Hex.fromBytes("context"),
            .transient_user_text_sha256 = null,
        },
        .{
            .index = 1,
            .turn_index = 1,
            .call_index = 0,
            .transcript_prefix_count = 2,
            .transcript_sha256 = artifact.Sha256Hex.fromBytes("transcript-1"),
            .request_context_sha256 = artifact.Sha256Hex.fromBytes("context"),
            .transient_user_text_sha256 = null,
        },
    };
    var approval_checkpoints = [_]artifact.ApprovalCheckpoint{
        .{ .index = 0, .turn_index = 0, .checkpoint_index = 0, .preview_sha256 = artifact.Sha256Hex.fromBytes("preview-0") },
        .{ .index = 1, .turn_index = 1, .checkpoint_index = 0, .preview_sha256 = artifact.Sha256Hex.fromBytes("preview-1") },
    };
    var transcript_items = [_]artifact.TranscriptItem{
        .{ .index = 0, .turn_index = 0, .kind = .user_text, .payload_sha256 = artifact.Sha256Hex.fromBytes("turn-0") },
        .{ .index = 1, .turn_index = 1, .kind = .user_text, .payload_sha256 = artifact.Sha256Hex.fromBytes("turn-1") },
    };
    var receipts = [_]artifact.ApplyReceipt{
        .{ .index = 0, .turn_index = 0, .payload_sha256 = artifact.Sha256Hex.fromBytes("receipt-0") },
        .{ .index = 1, .turn_index = 1, .payload_sha256 = artifact.Sha256Hex.fromBytes("receipt-1") },
    };
    switch (mutation) {
        .model_gap => model_calls[1].index = 2,
        .model_reordered => {
            model_calls[0].turn_index = 1;
            model_calls[1].turn_index = 0;
        },
        .approval_duplicate => approval_checkpoints[1].index = 0,
        .transcript_duplicate => transcript_items[1].index = 0,
        .receipt_reordered => {
            receipts[0].turn_index = 1;
            receipts[1].turn_index = 0;
        },
        else => {},
    }
    const trace = artifact.InteractionTrace{
        .schema_version = artifact.schema_version,
        .model_calls = &model_calls,
        .approvals = &approval_checkpoints,
        .transcript_items = &transcript_items,
        .apply_receipts = &receipts,
    };
    const trace_bytes = try renderJson(testing.allocator, trace);
    defer testing.allocator.free(trace_bytes);

    var responses = [_]artifact.ResponseFixture{
        .{ .index = 0, .turn_index = 0, .call_index = 0, .path = "responses/0.jsonl", .sha256 = artifact.Sha256Hex.fromBytes(response_0) },
        .{ .index = 1, .turn_index = 1, .call_index = 0, .path = "responses/1.jsonl", .sha256 = artifact.Sha256Hex.fromBytes(response_1) },
        .{ .index = 2, .turn_index = 1, .call_index = 1, .path = "responses/2.jsonl", .sha256 = artifact.Sha256Hex.fromBytes(response_2) },
    };
    var approvals = [_]artifact.ApprovalExpectation{
        .{ .index = 0, .turn_index = 0, .checkpoint_index = 0, .decision = .approve },
        .{ .index = 1, .turn_index = 1, .checkpoint_index = 0, .decision = .approve },
    };
    var events = [_]artifact.EventExpectation{
        .{ .index = 0, .turn_index = 0, .kind = .turn_end, .payload_sha256 = artifact.Sha256Hex.fromBytes("approved") },
        .{ .index = 1, .turn_index = 1, .kind = .turn_end, .payload_sha256 = artifact.Sha256Hex.fromBytes("approved") },
    };
    if (mutation == .event_gap) events[1].index = 2;
    if (mutation == .approval_duplicate) approvals[1].index = 0;

    var turns = [_]artifact.TurnExpectation{
        .{ .index = 0, .user_input = "first", .outcome = .approved, .final_response_sha256 = artifact.Sha256Hex.fromBytes("done-0") },
        .{ .index = 1, .user_input = "second", .outcome = .approved, .final_response_sha256 = artifact.Sha256Hex.fromBytes("done-1") },
    };
    switch (mutation) {
        .draft_metric_half => turns[0].raw_first_draft_veto_pass = true,
        .draft_metric_mixed => {
            turns[0].first_draft_veto_pass = true;
            turns[0].raw_first_draft_veto_pass = true;
            turns[0].first_attempt_green = true;
        },
        .draft_metric_impossible => {
            turns[0].raw_first_draft_veto_pass = true;
            turns[0].first_attempt_green = false;
        },
        else => {},
    }

    var manifest = artifact.FlowManifest{
        .schema_version = artifact.schema_version,
        .flow_version = zeroDigest(),
        .case_name = "multi-turn",
        .evidence_class = .deterministic_harness,
        .executable = true,
        .provider = switch (mutation) {
            .local_valid,
            .local_missing_version,
            .local_empty_version,
            .local_runtime_only,
            .local_runtime_name_only,
            .local_runtime_version_only,
            => .local,
            else => .anthropic,
        },
        .model = "fixture-model",
        .model_revision = switch (mutation) {
            .local_valid => "model-revision-fixture",
            .empty_revision => "",
            else => null,
        },
        .mlx_lm_version = switch (mutation) {
            .local_valid => "mlx-lm-fixture",
            .local_empty_version => "",
            .cloud_version => "mlx-lm-on-cloud",
            else => null,
        },
        // A stack that reports no fingerprint names itself through the declared
        // pair instead. `local_runtime_only` carries no `mlx_lm_version` and
        // must still load: it is the rapid-mlx shape.
        .runtime_name = switch (mutation) {
            .local_runtime_only, .local_runtime_name_only => "rapid-mlx",
            .cloud_runtime => "rapid-mlx-on-cloud",
            else => null,
        },
        .runtime_version = switch (mutation) {
            .local_runtime_only, .local_runtime_version_only => "0.12.11",
            .cloud_runtime => "0.12.11",
            else => null,
        },
        .turns = &turns,
        .model_responses = if (mutation == .response_orphan) &responses else responses[0..2],
        .approvals = &approvals,
        .events = &events,
        .allowed_workspace_changes = &.{.{ .path = "handler.ts", .kind = .changed }},
        .initial_workspace = &.{.{ .path = "handler.ts", .sha256 = artifact.Sha256Hex.fromBytes(initial) }},
        .turn_workspaces = if (mutation == .missing_turn_checkpoint) &.{} else &.{.{
            .turn_index = 0,
            .files = &.{.{ .path = "handler.ts", .sha256 = artifact.Sha256Hex.fromBytes(initial) }},
        }},
        .expected_workspace = &.{.{ .path = "handler.ts", .sha256 = artifact.Sha256Hex.fromBytes(expected) }},
        .trace = .{ .path = "trace.json", .sha256 = artifact.Sha256Hex.fromBytes(trace_bytes) },
    };

    var fixtures = std.ArrayList(artifact.LoadedFixture).empty;
    defer fixtures.deinit(testing.allocator);
    try fixtures.append(testing.allocator, .{ .role = .trace, .path = "trace.json", .bytes = trace_bytes });
    try fixtures.append(testing.allocator, .{ .role = .response, .path = "responses/0.jsonl", .bytes = response_0 });
    try fixtures.append(testing.allocator, .{ .role = .response, .path = "responses/1.jsonl", .bytes = response_1 });
    if (mutation == .response_orphan) {
        try fixtures.append(testing.allocator, .{ .role = .response, .path = "responses/2.jsonl", .bytes = response_2 });
    }
    if (mutation != .missing_initial) {
        try fixtures.append(testing.allocator, .{ .role = .initial_workspace, .path = "initial/handler.ts", .bytes = initial });
    }
    try fixtures.append(testing.allocator, .{ .role = .turn_workspace, .path = "turns/0/handler.ts", .bytes = initial });
    try fixtures.append(testing.allocator, .{ .role = .expected_workspace, .path = "expected/handler.ts", .bytes = expected });
    manifest.flow_version = try artifact.computeFlowVersion(testing.allocator, &manifest, fixtures.items);

    const generation = try std.fmt.allocPrint(testing.allocator, "generations/{s}", .{manifest.flow_version.slice()});
    defer testing.allocator.free(generation);
    try tree.mkdir(testing.allocator, generation);
    try writeGeneratedFile(&tree, generation, "manifest.json", try renderJson(testing.allocator, manifest));
    try writeGeneratedFile(&tree, generation, "trace.json", try testing.allocator.dupe(u8, trace_bytes));
    try writeGeneratedFile(&tree, generation, "responses/0.jsonl", try testing.allocator.dupe(u8, response_0));
    try writeGeneratedFile(&tree, generation, "responses/1.jsonl", try testing.allocator.dupe(u8, response_1));
    if (mutation == .response_orphan) {
        try writeGeneratedFile(&tree, generation, "responses/2.jsonl", try testing.allocator.dupe(u8, response_2));
    }
    if (mutation != .missing_initial) {
        try writeGeneratedFile(&tree, generation, "initial/handler.ts", try testing.allocator.dupe(u8, initial));
    }
    try writeGeneratedFile(&tree, generation, "turns/0/handler.ts", try testing.allocator.dupe(u8, initial));
    try writeGeneratedFile(&tree, generation, "expected/handler.ts", try testing.allocator.dupe(u8, expected));

    const descriptor = artifact.CaseDescriptor{
        .schema_version = artifact.schema_version,
        .case_name = manifest.case_name,
        .evidence_class = manifest.evidence_class,
        .executable = manifest.executable,
        .active_generation = manifest.flow_version,
    };
    const descriptor_bytes = try renderJson(testing.allocator, descriptor);
    defer testing.allocator.free(descriptor_bytes);
    try tree.writeFile(testing.allocator, "case.json", descriptor_bytes);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return .{
        .tree = tree,
        .case_root_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(
            io_backend.io(),
            tree.abs_path,
            testing.allocator,
        ),
        .generation = try testing.allocator.dupe(u8, generation),
        .flow_version = manifest.flow_version,
    };
}

fn writeGeneratedFile(tree: *const IsolatedTmp, generation: []const u8, path: []const u8, bytes: []u8) !void {
    defer testing.allocator.free(bytes);
    const relative = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ generation, path });
    defer testing.allocator.free(relative);
    try tree.writeFile(testing.allocator, relative, bytes);
}

fn expectLoadFailure(case_root: []const u8, expected: artifact.FailureKind) !void {
    var state = artifact.loadCase(testing.allocator, case_root);
    defer state.deinit();
    switch (state) {
        .available => return error.ExpectedInvalidFlowCase,
        .failure => |failure| try testing.expectEqual(expected, failure.kind),
    }
}

test "flow artifact loader accepts a valid multi-Turn case" {
    var fixture = try buildCase(.none);
    defer fixture.deinit();
    var state = artifact.loadCase(testing.allocator, fixture.case_root_abs);
    defer state.deinit();
    switch (state) {
        .available => |flow_case| {
            try testing.expectEqual(@as(usize, 2), flow_case.manifest.turns.len);
            try testing.expectEqual(@as(usize, 2), flow_case.trace.model_calls.len);
        },
        .failure => return error.ExpectedAvailableFlowCase,
    }
}

test "local provenance round-trips and binds the flow version" {
    var fixture = try buildCase(.local_valid);
    defer fixture.deinit();
    var state = artifact.loadCase(testing.allocator, fixture.case_root_abs);
    defer state.deinit();
    switch (state) {
        .failure => return error.ExpectedAvailableFlowCase,
        .available => |flow_case| {
            try testing.expectEqual(artifact.Provider.local, flow_case.manifest.provider);
            try testing.expectEqualStrings(
                "model-revision-fixture",
                flow_case.manifest.model_revision orelse return error.TestUnexpectedResult,
            );
            try testing.expectEqualStrings(
                "mlx-lm-fixture",
                flow_case.manifest.mlx_lm_version orelse return error.TestUnexpectedResult,
            );

            var changed_revision = flow_case.manifest;
            changed_revision.model_revision = "different-revision";
            const revision_version = try artifact.computeFlowVersion(
                testing.allocator,
                &changed_revision,
                flow_case.fixtures,
            );
            try testing.expect(!revision_version.eql(flow_case.flow_version));

            var changed_mlx = flow_case.manifest;
            changed_mlx.mlx_lm_version = "different-mlx-lm";
            const mlx_version = try artifact.computeFlowVersion(
                testing.allocator,
                &changed_mlx,
                flow_case.fixtures,
            );
            try testing.expect(!mlx_version.eql(flow_case.flow_version));
        },
    }
}

test "a declared runtime is provenance on its own and binds the flow version" {
    var fixture = try buildCase(.local_runtime_only);
    defer fixture.deinit();
    var state = artifact.loadCase(testing.allocator, fixture.case_root_abs);
    defer state.deinit();
    switch (state) {
        .failure => return error.ExpectedAvailableFlowCase,
        .available => |flow_case| {
            // The rapid-mlx shape: no fingerprint on the wire, so no
            // `mlx_lm_version`, and the pair carries the identity instead.
            try testing.expect(flow_case.manifest.mlx_lm_version == null);
            try testing.expectEqualStrings(
                "rapid-mlx",
                flow_case.manifest.runtime_name orelse return error.TestUnexpectedResult,
            );
            try testing.expectEqualStrings(
                "0.12.11",
                flow_case.manifest.runtime_version orelse return error.TestUnexpectedResult,
            );

            // Provenance that does not reach the flow version is provenance a
            // re-record can change without the version noticing.
            var changed_name = flow_case.manifest;
            changed_name.runtime_name = "mlx-lm";
            const name_version = try artifact.computeFlowVersion(
                testing.allocator,
                &changed_name,
                flow_case.fixtures,
            );
            try testing.expect(!name_version.eql(flow_case.flow_version));

            var changed_version = flow_case.manifest;
            changed_version.runtime_version = "0.12.12";
            const version_version = try artifact.computeFlowVersion(
                testing.allocator,
                &changed_version,
                flow_case.fixtures,
            );
            try testing.expect(!version_version.eql(flow_case.flow_version));
        },
    }
}

test "a cassette recorded before the runtime pair existed keeps its flow version" {
    var fixture = try buildCase(.local_valid);
    defer fixture.deinit();
    var state = artifact.loadCase(testing.allocator, fixture.case_root_abs);
    defer state.deinit();
    switch (state) {
        .failure => return error.ExpectedAvailableFlowCase,
        .available => |flow_case| {
            // The 15 committed local cassettes carry neither field. The hash
            // skips an absent pair, so adding it must not restamp them.
            try testing.expect(flow_case.manifest.runtime_name == null);
            try testing.expect(flow_case.manifest.runtime_version == null);
            const recomputed = try artifact.computeFlowVersion(
                testing.allocator,
                &flow_case.manifest,
                flow_case.fixtures,
            );
            try testing.expect(recomputed.eql(flow_case.flow_version));
        },
    }
}

test "flow artifact loader rejects strict checkpoint mutations" {
    const cases = [_]struct { mutation: Mutation, failure: artifact.FailureKind }{
        .{ .mutation = .model_gap, .failure = .invalid_index },
        .{ .mutation = .model_reordered, .failure = .invalid_index },
        .{ .mutation = .approval_duplicate, .failure = .invalid_index },
        .{ .mutation = .event_gap, .failure = .invalid_index },
        .{ .mutation = .transcript_duplicate, .failure = .invalid_index },
        .{ .mutation = .receipt_reordered, .failure = .invalid_index },
        .{ .mutation = .response_orphan, .failure = .checkpoint_alignment },
        .{ .mutation = .missing_initial, .failure = .missing_fixture },
        .{ .mutation = .missing_turn_checkpoint, .failure = .checkpoint_alignment },
        .{ .mutation = .local_missing_version, .failure = .invalid_inventory },
        .{ .mutation = .local_empty_version, .failure = .invalid_inventory },
        .{ .mutation = .cloud_version, .failure = .invalid_inventory },
        .{ .mutation = .empty_revision, .failure = .invalid_inventory },
        .{ .mutation = .local_runtime_name_only, .failure = .invalid_inventory },
        .{ .mutation = .local_runtime_version_only, .failure = .invalid_inventory },
        .{ .mutation = .cloud_runtime, .failure = .invalid_inventory },
        .{ .mutation = .draft_metric_half, .failure = .invalid_inventory },
        .{ .mutation = .draft_metric_mixed, .failure = .invalid_inventory },
        .{ .mutation = .draft_metric_impossible, .failure = .invalid_inventory },
    };
    for (cases) |case| {
        var fixture = try buildCase(case.mutation);
        defer fixture.deinit();
        try expectLoadFailure(fixture.case_root_abs, case.failure);
    }
}

test "flow artifact descriptor claims are bound to the active generation" {
    for ([_]artifact.CaseDescriptor{
        .{ .schema_version = artifact.schema_version, .case_name = "multi-turn", .evidence_class = .empirical_model, .executable = true, .active_generation = zeroDigest() },
        .{ .schema_version = artifact.schema_version, .case_name = "multi-turn", .evidence_class = .deterministic_harness, .executable = false, .active_generation = zeroDigest() },
    }) |tampered_base| {
        var fixture = try buildCase(.none);
        defer fixture.deinit();
        var tampered = tampered_base;
        tampered.active_generation = fixture.flow_version;
        const bytes = try renderJson(testing.allocator, tampered);
        defer testing.allocator.free(bytes);
        try fixture.tree.writeFile(testing.allocator, "case.json", bytes);
        try expectLoadFailure(fixture.case_root_abs, .hash_mismatch);
    }
}

test "flow artifact loader rejects strict descriptor and fixture drift" {
    var fixture = try buildCase(.none);
    defer fixture.deinit();
    try fixture.tree.writeFile(testing.allocator, "case.json",
        \\{"schema_version":1,"case_name":"multi-turn","evidence_class":"deterministic_harness","executable":true,"active_generation":"0000000000000000000000000000000000000000000000000000000000000000","extra":true}
    );
    try expectLoadFailure(fixture.case_root_abs, .unknown_json_field);

    var orphan = try buildCase(.none);
    defer orphan.deinit();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/orphan.txt", .{orphan.generation});
    defer testing.allocator.free(path);
    try orphan.tree.writeFile(testing.allocator, path, "orphan\n");
    try expectLoadFailure(orphan.case_root_abs, .unexpected_fixture);
}

test "flow artifact loader rejects a symlink in the case root" {
    var fixture = try buildCase(.none);
    defer fixture.deinit();

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var private_tmp = try std.Io.Dir.openDirAbsolute(io, "/private/tmp", .{});
    defer private_tmp.close(io);
    const link_name = try std.fmt.allocPrint(testing.allocator, "{s}-link", .{fixture.tree.name});
    defer testing.allocator.free(link_name);
    private_tmp.deleteFile(io, link_name) catch {};
    defer private_tmp.deleteFile(io, link_name) catch {};
    try private_tmp.symLink(io, fixture.case_root_abs, link_name, .{ .is_directory = true });
    const link_path = try std.fs.path.join(testing.allocator, &.{ "/private/tmp", link_name });
    defer testing.allocator.free(link_path);

    try expectLoadFailure(link_path, .symlink_component);
}

test "flow artifact paths reject traversal and ambiguous components" {
    try testing.expect(artifact.isSafeRelativePath("responses/0.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("../response.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("responses//0.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("responses/./0.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("/absolute.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("C:/absolute.jsonl"));
    try testing.expect(!artifact.isSafeRelativePath("responses\\0.jsonl"));
}
