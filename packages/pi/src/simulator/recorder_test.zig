const std = @import("std");
const testing = std.testing;
const zts = @import("zts");

const artifact = @import("artifact.zig");
const observation = @import("observation.zig");
const promotion = @import("promotion.zig");
const recorder_mod = @import("recorder.zig");
const runner_mod = @import("runner.zig");
const capture_sink = @import("../providers/capture_sink.zig");
const cassette_client = @import("../providers/cassette_client.zig");
const cassette_record = @import("../providers/cassette_record.zig");
const context_budget = @import("../context_budget.zig");
const model_client = @import("model_client.zig");
const local_client = @import("../providers/local/client.zig");
const model_request = @import("../providers/model_request.zig");
const loop = @import("../loop.zig");
const registry_mod = @import("../registry/registry.zig");
const transcript_mod = @import("../transcript.zig");
const app = @import("../app.zig");
const expert_persona = @import("../expert_persona.zig");
const openai_client = @import("../providers/openai/client.zig");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwdPathAlloc = @import("../test_support/cwd.zig").cwdPathAlloc;

const openai_text_response =
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"hello world\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}\n\n" ++
    "data: [DONE]\n\n";

const deterministic_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> {\n" ++
    "    return Response.json({ ok: true });\n" ++
    "}\n";

fn renderOpenAiProposeChangeSetResponse(allocator: std.mem.Allocator) ![]u8 {
    var arguments = TextBuffer.init(allocator);
    defer arguments.deinit();
    try std.json.Stringify.value(.{
        .changes = &.{.{
            .file = "handler.ts",
            .content = deterministic_handler,
        }},
    }, .{}, arguments.writer());

    var response = TextBuffer.init(allocator);
    errdefer response.deinit();
    const writer = response.writer();
    try writer.writeAll("event: response.created\n" ++
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_edit\",\"status\":\"in_progress\"}}\n\n" ++
        "event: response.output_item.added\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"fc_edit\",\"type\":\"function_call\",\"call_id\":\"call_edit\",\"name\":\"propose_change_set\",\"arguments\":\"\"}}\n\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":");
    try std.json.Stringify.value(arguments.written(), .{}, writer);
    try writer.writeAll("}\n\n" ++
        "event: response.output_item.done\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"fc_edit\",\"type\":\"function_call\",\"call_id\":\"call_edit\",\"name\":\"propose_change_set\",\"arguments\":");
    try std.json.Stringify.value(arguments.written(), .{}, writer);
    try writer.writeAll("}}\n\n" ++
        "event: response.completed\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_edit\",\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3,\"total_tokens\":10}}}\n\n" ++
        "data: [DONE]\n\n");
    return response.toOwnedSlice();
}

fn deterministicEditSteps(allocator: std.mem.Allocator) ![]const []const u8 {
    const propose_change_set_response = try renderOpenAiProposeChangeSetResponse(allocator);
    const steps = try allocator.alloc([]const u8, 1);
    steps[0] = try cassette_record.serializeCassette(allocator, propose_change_set_response, .{
        .provider = .openai,
        .scenario = "recorder-edit-flow",
        .stream = true,
        .model = openai_client.default_model,
    });
    return steps;
}

const ProgressProbe = struct {
    events: std.ArrayList(recorder_mod.ProgressEvent) = .empty,

    fn observer(self: *ProgressProbe) recorder_mod.ProgressObserver {
        return .{ .context = self, .on_event = onEvent };
    }

    fn onEvent(context: *anyopaque, event: recorder_mod.ProgressEvent) void {
        const self: *ProgressProbe = @ptrCast(@alignCast(context));
        self.events.append(testing.allocator, event) catch @panic("progress probe allocation failed");
    }

    fn deinit(self: *ProgressProbe) void {
        self.events.deinit(testing.allocator);
    }
};

test "simulator recorder appends metadata-only response diagnostics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cwdPathAlloc(testing.allocator);
    defer testing.allocator.free(cwd);
    const diagnostics_path = try std.fs.path.resolve(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "local-response-diagnostics.jsonl",
    });
    defer testing.allocator.free(diagnostics_path);
    var probe: ProgressProbe = .{};
    defer probe.deinit();

    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "diagnostic-case",
        .evidence_class = .deterministic_harness,
        .provider = .local,
        .model = "diagnostic-model",
        .diagnostics_path = diagnostics_path,
        .progress = probe.observer(),
        .workspace_allowlist = &.{},
    });
    defer recorder.deinit();

    var sink = recorder.captureSink();
    sink.recordDiagnostics(.{
        .provider = .local,
        .model = "diagnostic-model",
    }, .{
        .latency_ms = 1234,
        .finish_reason = .stop,
        .completion_tokens = 0,
        .field_presence = .{
            .choices = true,
            .first_choice = true,
            .finish_reason = true,
            .message = true,
            .content = true,
            .reasoning = true,
            .usage = true,
            .completion_tokens = true,
        },
        .parser_warnings = &.{ .content_null, .assistant_output_missing },
        .failure = error.EmptyResponse,
    });
    sink.recordDiagnostics(.{
        .provider = .local,
        .model = "diagnostic-model",
    }, .{
        .latency_ms = 9,
        .http_status = 429,
        .finish_reason = null,
        .completion_tokens = null,
        .field_presence = .{},
        .parser_warnings = &.{.transport_failed},
        .failure = error.LocalServerUnavailable,
    });

    const bytes = try zts.file_io.readFile(testing.allocator, diagnostics_path, 64 * 1024);
    defer testing.allocator.free(bytes);
    const first_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.TestUnexpectedResult;
    const second_start = first_end + 1;
    const second_end_rel = std.mem.indexOfScalar(u8, bytes[second_start..], '\n') orelse
        return error.TestUnexpectedResult;
    const second_end = second_start + second_end_rel;
    try testing.expectEqual(bytes.len, second_end + 1);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        bytes[0..first_end],
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("v").?.integer);
    try testing.expectEqualStrings("diagnostic-case", root.get("case_name").?.string);
    try testing.expectEqualStrings("local", root.get("provider").?.string);
    try testing.expectEqualStrings("diagnostic-model", root.get("model").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("attempt_index").?.integer);
    try testing.expectEqual(@as(i64, 1234), root.get("latency_ms").?.integer);
    try testing.expectEqualStrings("stop", root.get("finish_reason").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("completion_tokens").?.integer);
    try testing.expect(root.get("field_presence").?.object.get("reasoning").?.bool);
    try testing.expectEqualStrings("content_null", root.get("parser_warnings").?.array.items[0].string);
    try testing.expectEqualStrings("EmptyResponse", root.get("error_name").?.string);
    try testing.expect(std.mem.indexOf(u8, bytes[second_start..second_end], "\"attempt_index\":1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes[second_start..second_end], "\"http_status\":429") != null);
    try testing.expect(std.mem.indexOf(u8, bytes[second_start..second_end], "\"transport_failed\"") != null);
    try testing.expectEqual(@as(usize, 2), probe.events.items.len);
    switch (probe.events.items[0]) {
        .model_call_failed => |failed| {
            try testing.expectEqual(@as(usize, 0), failed.attempt_index);
            try testing.expectEqual(@as(?u16, null), failed.http_status);
            try testing.expectEqual(error.EmptyResponse, failed.failure);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (probe.events.items[1]) {
        .model_call_failed => |failed| {
            try testing.expectEqual(@as(usize, 1), failed.attempt_index);
            try testing.expectEqual(@as(?u16, 429), failed.http_status);
            try testing.expectEqual(error.LocalServerUnavailable, failed.failure);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "local client failure records diagnostics through the flow recorder" {
    const response_body =
        "{\"system_fingerprint\":\"0.31.3-fixture\"," ++
        "\"choices\":[{\"finish_reason\":\"stop\",\"message\":{" ++
        "\"reasoning\":\"private chain\",\"content\":null}}]," ++
        "\"usage\":{\"completion_tokens\":0}}";
    var server = try cassette_record.LocalHttpServer.init(
        testing.allocator,
        response_body,
        "application/json",
    );
    try server.start();
    errdefer server.join() catch {};
    const base_url = try server.url(testing.allocator, "");
    defer testing.allocator.free(base_url);

    var tree = try IsolatedTmp.init(testing.allocator, "local-response-diagnostics");
    defer tree.cleanup(testing.allocator);
    try tree.mkdir(testing.allocator, "workspace");
    const workspace_abs = try tree.childPath(testing.allocator, "workspace");
    defer testing.allocator.free(workspace_abs);
    const diagnostics_path = try tree.childPath(testing.allocator, "diagnostics.jsonl");
    defer testing.allocator.free(diagnostics_path);

    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "local-empty-response",
        .evidence_class = .deterministic_harness,
        .provider = .local,
        .model = "diagnostic-model",
        .diagnostics_path = diagnostics_path,
        .workspace_allowlist = &.{},
    });
    defer recorder.deinit();
    try recorder.captureInitialWorkspace(workspace_abs);
    try recorder.beginTurn("private user source", 0, .approve);
    var sink = recorder.captureSink();
    var client = local_client.Client.initWithCapture(.{
        .system_prompt = "private system prompt",
        .model = "diagnostic-model",
        .base_url = base_url,
    }, &sink);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "private user source" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        local_client.ClientError.EmptyResponse,
        client.sendTurn(arena.allocator(), &transcript, null),
    );
    try server.join();

    const bytes = try zts.file_io.readFile(testing.allocator, diagnostics_path, 64 * 1024);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "private user source") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "private system prompt") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "private chain") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"latency_ms\":") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"finish_reason\":\"stop\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"completion_tokens\":0") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"content\":true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"reasoning\":true") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"assistant_output_missing\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"error_name\":\"EmptyResponse\"") != null);
}

const CapturingClient = struct {
    config: model_request.Config,
    capture: *capture_sink.CaptureSink,

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *CapturingClient = @ptrCast(@alignCast(context));
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = self.config,
            .transcript = transcript,
            .extra_user_text = extra_user_text,
        });
        defer snapshot.deinit(arena);
        _ = try model_client.prepareSnapshot(arena, &snapshot);
        try self.capture.record(&snapshot, openai_text_response);
        const bytes = try cassette_record.serializeCassette(arena, openai_text_response, .{
            .provider = .openai,
            .scenario = "recorded-two-turn",
            .stream = true,
            .model = self.config.model,
        });
        const cassette = try cassette_client.loadCassetteFromBytes(arena, bytes, null);
        return cassette_client.replay(arena, cassette);
    }

    fn asModelClient(self: *CapturingClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const LegacyCapturingClient = struct {
    config: model_request.Config,
    capture: *capture_sink.CaptureSink,
    steps: []const []const u8,
    cursor: usize = 0,

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *LegacyCapturingClient = @ptrCast(@alignCast(context));
        if (self.cursor >= self.steps.len) return error.CassetteSequenceExhausted;
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = self.config,
            .transcript = transcript,
            .extra_user_text = extra_user_text,
        });
        defer snapshot.deinit(arena);
        _ = try model_client.prepareSnapshot(arena, &snapshot);
        const cassette = try cassette_client.loadCassetteFromBytes(arena, self.steps[self.cursor], null);
        try self.capture.record(&snapshot, cassette.body);
        const result = try cassette_client.replay(arena, cassette);
        self.cursor += 1;
        return result;
    }

    fn asModelClient(self: *LegacyCapturingClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

test "simulator recorder validates and owns workspace capture allowlist" {
    try testing.expectError(error.UnsafePath, recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "unsafe-workspace-path",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{"../handler.ts"},
    }));
    try testing.expectError(error.DuplicateWorkspacePath, recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "duplicate-workspace-path",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{ "handler.ts", "handler.ts" },
    }));

    var mutable_path = "handler.ts".*;
    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "owned-workspace-path",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{mutable_path[0..]},
    });
    defer recorder.deinit();
    mutable_path = "ignored.ts".*;
    try testing.expectEqualStrings("handler.ts", recorder.options.workspace_allowlist[0]);
}

test "simulator recorder rejects undeclared credential file before workspace reads" {
    var tree = try IsolatedTmp.init(testing.allocator, "flow-recorder-allowlist");
    defer tree.cleanup(testing.allocator);
    try tree.mkdir(testing.allocator, "workspace");
    try tree.writeFile(testing.allocator, "workspace/handler.ts", "allowed\n");
    try tree.writeFile(
        testing.allocator,
        "workspace/service-account-credentials.json",
        "{\"token\":\"must-not-be-captured\"}\n",
    );
    const workspace_path = try tree.childPath(testing.allocator, "workspace");
    defer testing.allocator.free(workspace_path);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const workspace_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(
        io_backend.io(),
        workspace_path,
        testing.allocator,
    );
    defer testing.allocator.free(workspace_abs);

    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "undeclared-credential",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{"handler.ts"},
    });
    defer recorder.deinit();
    try testing.expectError(error.UndeclaredWorkspacePath, recorder.captureInitialWorkspace(workspace_abs));
    try testing.expectEqual(@as(usize, 0), recorder.initial_workspace.items.len);
    try testing.expectEqual(@as(usize, 0), recorder.fixtures.items.len);
}

test "simulator recorder skips agent scratch but still refuses undeclared source" {
    // `pi_goal_check` persists witnesses under `.zttp/witnesses/<hash>/`. That
    // is agent-owned state, not case source, and its directory name carries a
    // per-run hash, so capturing it would make a case differ from itself on the
    // next recording. Skipping it must not weaken the refusal for a real file
    // the case never declared.
    var tree = try IsolatedTmp.init(testing.allocator, "flow-recorder-scratch");
    defer tree.cleanup(testing.allocator);
    try tree.mkdir(testing.allocator, "workspace");
    try tree.writeFile(testing.allocator, "workspace/handler.ts", "allowed\n");
    try tree.mkdir(testing.allocator, "workspace/.zttp");
    try tree.mkdir(testing.allocator, "workspace/.zttp/witnesses");
    try tree.mkdir(testing.allocator, "workspace/.zttp/witnesses/f0812d0e79287bb9");
    try tree.writeFile(
        testing.allocator,
        "workspace/.zttp/witnesses/f0812d0e79287bb9/handler.path",
        "witness state\n",
    );
    const workspace_path = try tree.childPath(testing.allocator, "workspace");
    defer testing.allocator.free(workspace_path);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const workspace_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(
        io_backend.io(),
        workspace_path,
        testing.allocator,
    );
    defer testing.allocator.free(workspace_abs);

    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "agent-scratch",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{"handler.ts"},
    });
    defer recorder.deinit();
    try recorder.captureInitialWorkspace(workspace_abs);
    try testing.expectEqual(@as(usize, 1), recorder.initial_workspace.items.len);
    try testing.expectEqualStrings("handler.ts", recorder.initial_workspace.items[0].path);
    for (recorder.fixtures.items) |fixture| {
        try testing.expect(std.mem.indexOf(u8, fixture.path, ".zttp") == null);
    }

    // A sibling source file the case did not declare is still refused, so the
    // skip covers scratch only.
    try tree.writeFile(testing.allocator, "workspace/helper.ts", "undeclared\n");
    var strict = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "agent-scratch-strict",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = "gpt-4o-mini",
        .workspace_allowlist = &.{"handler.ts"},
    });
    defer strict.deinit();
    try testing.expectError(
        error.UndeclaredWorkspacePath,
        strict.captureInitialWorkspace(workspace_abs),
    );
}

test "simulator recorder promotes and replays a complete two-Turn flow" {
    var tree = try IsolatedTmp.init(testing.allocator, "flow-recorder");
    defer tree.cleanup(testing.allocator);
    try tree.mkdir(testing.allocator, "workspace");
    try tree.mkdir(testing.allocator, "case");
    try tree.writeFile(testing.allocator, "workspace/handler.ts", "keep exact bytes\n");

    const workspace_path = try tree.childPath(testing.allocator, "workspace");
    defer testing.allocator.free(workspace_path);
    const case_path = try tree.childPath(testing.allocator, "case");
    defer testing.allocator.free(case_path);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const workspace_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(
        io_backend.io(),
        workspace_path,
        testing.allocator,
    );
    defer testing.allocator.free(workspace_abs);
    const case_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(
        io_backend.io(),
        case_path,
        testing.allocator,
    );
    defer testing.allocator.free(case_abs);

    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = "gpt-4o-mini",
        .max_output_tokens = 8192,
        .system_prompt = "persona",
    };
    var progress_probe: ProgressProbe = .{};
    defer progress_probe.deinit();
    var recorder = try recorder_mod.Recorder.init(testing.allocator, .{
        .case_name = "recorded-two-turn",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = request_config.model,
        .progress = progress_probe.observer(),
        .workspace_allowlist = &.{"handler.ts"},
    });
    defer recorder.deinit();
    try recorder.captureInitialWorkspace(workspace_abs);
    var sink = recorder.captureSink();
    var client = CapturingClient{ .config = request_config, .capture = &sink };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    for ([_][]const u8{ "hello", "again" }, 0..) |prompt, turn_index| {
        try recorder.beginTurn(prompt, transcript.len(), .approve);
        const result = try loop.runTurnWith(
            testing.allocator,
            client.asModelClient(),
            &registry,
            &transcript,
            prompt,
            .{ .workspace_root = workspace_abs, .turn_timeout_ms = 0 },
        );
        try recorder.finishTurn(result, &transcript);
        if (turn_index == 0) try recorder.captureTurnWorkspace(workspace_abs);
    }
    try recorder.captureExpectedWorkspace(workspace_abs);

    try testing.expectEqual(@as(usize, 2), progress_probe.events.items.len);
    for (progress_probe.events.items, 0..) |event, index| switch (event) {
        .model_call_completed => |completed| {
            try testing.expectEqual(index, completed.global_call_index);
            try testing.expectEqual(@as(u32, @intCast(index)), completed.turn_index);
            try testing.expectEqual(@as(u32, 0), completed.turn_call_index);
            try testing.expectEqual(model_request.Purpose.normal, completed.purpose);
            try testing.expectEqual(request_config.max_output_tokens, completed.output_limit_tokens);
            try testing.expect(completed.estimated_input_tokens >= completed.logical_input_tokens);
            try testing.expectEqual(@as(u64, 1), completed.reported_input_tokens);
            try testing.expectEqual(@as(u64, 1), completed.logical_input_tokens);
            try testing.expectEqual(context_budget.InputObservationSource.provider_reported, completed.input_observation_source);
            try testing.expectEqual(@as(u64, 2), completed.output_tokens);
            try testing.expect(completed.wire_bytes > 0);
        },
        .model_call_failed => return error.TestUnexpectedResult,
    };

    var mismatched_config = request_config;
    mismatched_config.system_prompt = "changed persona";
    try testing.expectError(
        error.ReplayMismatch,
        promotion.validateAndPromote(
            testing.allocator,
            &recorder,
            case_abs,
            &registry,
            mismatched_config,
        ),
    );
    var absent = artifact.loadCase(testing.allocator, case_abs);
    defer absent.deinit();
    switch (absent) {
        .failure => {},
        .available => return error.UnvalidatedFlowWasPromoted,
    }

    const flow_version = try promotion.validateAndPromote(
        testing.allocator,
        &recorder,
        case_abs,
        &registry,
        request_config,
    );

    var loaded = artifact.loadCase(testing.allocator, case_abs);
    defer loaded.deinit();
    switch (loaded) {
        .failure => return error.ExpectedRecordedFlow,
        .available => |*flow_case| {
            try testing.expect(flow_case.flow_version.eql(flow_version));
            try testing.expectEqual(@as(usize, 2), flow_case.manifest.turns.len);
            try testing.expectEqual(
                @as(?bool, false),
                flow_case.manifest.turns[0].raw_first_draft_veto_pass,
            );
            try testing.expectEqual(@as(?bool, false), flow_case.manifest.turns[0].first_attempt_green);
            try testing.expectEqual(@as(?bool, null), flow_case.manifest.turns[0].first_draft_veto_pass);
            try testing.expectEqual(@as(usize, 2), flow_case.trace.model_calls.len);
            for (flow_case.trace.model_calls) |checkpoint| {
                try testing.expect(checkpoint.request_budget != null);
                try testing.expectEqual(@as(?u64, 1), checkpoint.normalized_input_tokens);
                try testing.expect(checkpoint.request_budget.?.bytes.wire > 0);
            }
            var runner = runner_mod.Runner.init(testing.allocator, flow_case, &registry, request_config);
            const replay = try runner.run();
            try testing.expectEqual(@as(usize, 2), replay.turns);
            try testing.expectEqual(@as(usize, 2), replay.model_calls);
        },
    }
}

test "simulator recorder captures approved and denied real edit flows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const steps = try deterministicEditSteps(allocator);
    try testing.expectEqual(@as(usize, 1), steps.len);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    const system_prompt = try expert_persona.buildSystemPrompt(allocator);
    var tools_buffer = TextBuffer.init(allocator);
    defer tools_buffer.deinit();
    try openai_client.writeToolsArray(tools_buffer.writer(), &registry);
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = openai_client.default_model,
        .max_output_tokens = 64_000,
        .system_prompt = system_prompt,
        .tools_json = tools_buffer.written(),
    };
    const prompt = "Create a handler in handler.ts that responds to GET /health with " ++
        "Response.json({ ok: true }). Keep it minimal and deterministic.";

    for ([_]artifact.ApprovalDecision{ .approve, .reject }) |decision| {
        var tree = try IsolatedTmp.init(allocator, "flow-edit-record");
        defer tree.cleanup(allocator);
        try tree.mkdir(allocator, "workspace");
        try tree.mkdir(allocator, "case");
        const workspace_path = try tree.childPath(allocator, "workspace");
        const case_path = try tree.childPath(allocator, "case");
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        const workspace_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(io_backend.io(), workspace_path, allocator);
        const case_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(io_backend.io(), case_path, allocator);

        const case_name = if (decision == .approve) "health-approved" else "health-denied";
        var recorder = try recorder_mod.Recorder.init(allocator, .{
            .case_name = case_name,
            .evidence_class = .deterministic_harness,
            .provider = .openai,
            .model = request_config.model,
            .workspace_allowlist = &.{"handler.ts"},
        });
        defer recorder.deinit();
        try recorder.captureInitialWorkspace(workspace_abs);
        var sink = recorder.captureSink();
        var client = LegacyCapturingClient{
            .config = request_config,
            .capture = &sink,
            .steps = steps,
        };
        var transcript: transcript_mod.Transcript = .{};
        defer transcript.deinit(allocator);
        try recorder.beginTurn(prompt, transcript.len(), decision);

        const saved_cwd = try cwdPathAlloc(allocator);
        try std.Io.Threaded.chdir(workspace_abs);
        const result = loop.runTurnWith(
            allocator,
            client.asModelClient(),
            &registry,
            &transcript,
            prompt,
            .{
                .workspace_root = ".",
                .max_attempts = loop.interactive_max_attempts,
                .approval_fn = recorder.approvalFn(),
                .turn_timeout_ms = 0,
            },
        ) catch |err| {
            try std.Io.Threaded.chdir(saved_cwd);
            return err;
        };
        try std.Io.Threaded.chdir(saved_cwd);
        try recorder.finishTurn(result, &transcript);
        if (decision == .approve) {
            const entry = &transcript.entries.items[transcript.entries.items.len - 2];
            const recorded_digest = try observation.applyReceiptDigest(allocator, entry);
            try testing.expect(recorded_digest.eql(recorder.apply_receipts.items[0].payload_sha256));
            switch (entry.*) {
                .verified_patch => |*message| switch (message.ui_payload.?) {
                    .verified_patch => |*patch| {
                        const applied_at_unix_ms = patch.applied_at_unix_ms;
                        patch.applied_at_unix_ms +%= 1;
                        const timestamp_mutation = try observation.applyReceiptDigest(allocator, entry);
                        try testing.expect(recorded_digest.eql(timestamp_mutation));
                        patch.applied_at_unix_ms = applied_at_unix_ms;

                        patch.post_apply_ok = !patch.post_apply_ok;
                        const stable_mutation = try observation.applyReceiptDigest(allocator, entry);
                        try testing.expect(!recorded_digest.eql(stable_mutation));
                        patch.post_apply_ok = !patch.post_apply_ok;
                    },
                    else => return error.TestFailed,
                },
                else => return error.TestFailed,
            }
        }
        try recorder.captureExpectedWorkspace(workspace_abs);
        _ = try recorder.promote(case_abs);

        var loaded = artifact.loadCase(allocator, case_abs);
        defer loaded.deinit();
        switch (loaded) {
            .failure => return error.ExpectedRecordedFlow,
            .available => |*flow_case| {
                try testing.expectEqual(@as(usize, 1), flow_case.manifest.approvals.len);
                try testing.expectEqual(decision, flow_case.manifest.approvals[0].decision);
                if (decision == .approve) {
                    try testing.expectEqual(artifact.TurnOutcome.approved, flow_case.manifest.turns[0].outcome);
                    try testing.expectEqual(@as(usize, 1), flow_case.manifest.expected_workspace.len);
                } else {
                    try testing.expectEqual(artifact.TurnOutcome.approval_denied, flow_case.manifest.turns[0].outcome);
                    try testing.expectEqual(@as(usize, 0), flow_case.manifest.expected_workspace.len);
                }
                if (decision == .approve) {
                    const receipts = @constCast(flow_case.trace.apply_receipts);
                    const original = receipts[0].payload_sha256;
                    receipts[0].payload_sha256 = artifact.Sha256Hex.fromBytes("tampered receipt");
                    var tampered_runner = runner_mod.Runner.init(allocator, flow_case, &registry, request_config);
                    try testing.expectError(error.ReplayMismatch, tampered_runner.run());
                    receipts[0].payload_sha256 = original;
                }
                var runner = runner_mod.Runner.init(allocator, flow_case, &registry, request_config);
                const replay = try runner.run();
                try testing.expectEqual(@as(usize, 1), replay.approvals);
            },
        }
    }
}

test "simulator runner preserves an approved edit into the next real Turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const one_turn_steps = try deterministicEditSteps(allocator);
    try testing.expectEqual(@as(usize, 1), one_turn_steps.len);
    const steps = try allocator.alloc([]const u8, one_turn_steps.len * 2);
    @memcpy(steps[0..one_turn_steps.len], one_turn_steps);
    @memcpy(steps[one_turn_steps.len..], one_turn_steps);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    const system_prompt = try expert_persona.buildSystemPrompt(allocator);
    var tools_buffer = TextBuffer.init(allocator);
    defer tools_buffer.deinit();
    try openai_client.writeToolsArray(tools_buffer.writer(), &registry);
    const request_config: model_request.Config = .{
        .provider = .openai,
        .model = openai_client.default_model,
        .max_output_tokens = 64_000,
        .system_prompt = system_prompt,
        .tools_json = tools_buffer.written(),
    };
    const prompt = "Create a handler in handler.ts that responds to GET /health with " ++
        "Response.json({ ok: true }). Keep it minimal and deterministic.";

    var tree = try IsolatedTmp.init(allocator, "flow-two-edit-record");
    defer tree.cleanup(allocator);
    try tree.mkdir(allocator, "workspace");
    try tree.mkdir(allocator, "case");
    const workspace_path = try tree.childPath(allocator, "workspace");
    const case_path = try tree.childPath(allocator, "case");
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const workspace_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(io_backend.io(), workspace_path, allocator);
    const case_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(io_backend.io(), case_path, allocator);

    var recorder = try recorder_mod.Recorder.init(allocator, .{
        .case_name = "health-two-turn",
        .evidence_class = .deterministic_harness,
        .provider = .openai,
        .model = request_config.model,
        .workspace_allowlist = &.{"handler.ts"},
    });
    defer recorder.deinit();
    try recorder.captureInitialWorkspace(workspace_abs);
    var sink = recorder.captureSink();
    var client = LegacyCapturingClient{
        .config = request_config,
        .capture = &sink,
        .steps = steps,
    };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    const saved_cwd = try cwdPathAlloc(allocator);
    try std.Io.Threaded.chdir(workspace_abs);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};
    for (0..2) |turn_index| {
        try recorder.beginTurn(prompt, transcript.len(), .approve);
        const result = try loop.runTurnWith(
            allocator,
            client.asModelClient(),
            &registry,
            &transcript,
            prompt,
            .{
                .workspace_root = ".",
                .max_attempts = loop.interactive_max_attempts,
                .approval_fn = recorder.approvalFn(),
                .turn_timeout_ms = 0,
            },
        );
        try recorder.finishTurn(result, &transcript);
        if (turn_index == 0) try recorder.captureTurnWorkspace(workspace_abs);
    }
    try std.Io.Threaded.chdir(saved_cwd);
    try recorder.captureExpectedWorkspace(workspace_abs);
    _ = try recorder.promote(case_abs);

    var loaded = artifact.loadCase(allocator, case_abs);
    defer loaded.deinit();
    switch (loaded) {
        .failure => return error.ExpectedRecordedFlow,
        .available => |*flow_case| {
            try testing.expectEqual(@as(usize, 2), flow_case.manifest.turns.len);
            try testing.expectEqual(@as(usize, 2), flow_case.trace.model_calls.len);
            try testing.expectEqual(@as(usize, 2), flow_case.manifest.approvals.len);
            var runner = runner_mod.Runner.init(allocator, flow_case, &registry, request_config);
            const replay = try runner.run();
            try testing.expectEqual(@as(usize, 2), replay.turns);
            try testing.expectEqual(@as(usize, 2), replay.model_calls);
        },
    }
}
