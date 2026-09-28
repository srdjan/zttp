//! Agent admission for local fixture and recorded-trace execution.
//! Source catalogs have the same authority as dev catalogs. Replay does not
//! contact a provider or load credentials, and the recorder stays in memory.

const std = @import("std");
const zts = @import("zts");
const contract_runtime = @import("contract_runtime.zig");
const turn_recorder = @import("turn_recorder.zig");
const TurnState = @import("turn_state.zig").TurnState;
const HttpRequestView = @import("http_types.zig").HttpRequestView;
const HandlerInstance = @import("handler_instance.zig").HandlerInstance;
const tool_auth = @import("tool_auth.zig");
const self_extract = @import("self_extract.zig");

pub const ReplayTurn = struct {
    allocator: std.mem.Allocator,
    catalog: contract_runtime.AcceptedCatalog,
    recorder: turn_recorder.Recorder,
    turn: TurnState,
    prompt_arena: *std.heap.ArenaAllocator,
    prompt: []const u8,

    pub fn prepare(
        allocator: std.mem.Allocator,
        rt: *HandlerInstance,
        source: []const u8,
        filename: []const u8,
        request: *HttpRequestView,
    ) !?*ReplayTurn {
        var contract = try zts.pipeline.extractContract(allocator, source, filename, .{
            .strict = false,
            .version = zts.version.string,
            .read_file = zts.file_io.readFileForModuleGraph,
        });
        defer contract.deinit(allocator);
        var catalog = (try contract_runtime.lowerProducerToolCatalog(allocator, contract.tools.items)) orelse return null;
        errdefer catalog.deinit();
        const agent = catalog.matchAgent(request.method, request.path) orelse {
            catalog.deinit();
            return null;
        };
        const body: []const u8 = request.*.body orelse "";
        if (body.len > agent.max_input_bytes) return error.AgentInputTooLarge;
        const prompt_arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(prompt_arena);
        prompt_arena.* = .init(allocator);
        errdefer prompt_arena.deinit();
        if (try contract_runtime.validateAgentInput(prompt_arena.allocator(), agent, body) != .ok) return error.InvalidAgentInput;
        const prompt = try contract_runtime.admittedAgentPrompt(prompt_arena.allocator(), body);
        const self = try allocator.create(ReplayTurn);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.catalog = catalog;
        self.prompt = prompt;
        self.prompt_arena = prompt_arena;
        self.recorder = turn_recorder.Recorder.initMemory(allocator, std.math.maxInt(u64));
        errdefer self.recorder.deinit();
        var id: turn_recorder.TurnId = undefined;
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try io_backend.io().randomSecure(&id);
        const now = try zts.monotonicNowNs();
        self.turn = try TurnState.init(allocator, id, agent.limits, now +| @as(u64, agent.limits.turn_deadline_ms) * std.time.ns_per_ms, &self.recorder);
        errdefer self.turn.deinit();
        const catalog_digest = std.fmt.bytesToHex(@import("zttp_proof_checker").tool_catalog.digest(catalog.bytes), .lower);
        const policy_bytes = try self_extract.serializePolicy(allocator, &rt.ctx.capability_policy);
        defer allocator.free(policy_bytes);
        var policy_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(policy_bytes, &policy_digest, .{});
        const policy_hex = std.fmt.bytesToHex(policy_digest, .lower);
        try self.recorder.admit(.{
            .turn_id = id,
            .sequence = 0,
            .kind = .admit,
            .monotonic_ns = now,
            .agent_name = agent.name,
            .catalog_digest = &catalog_digest,
            .runtime_policy_hash = &policy_hex,
            .wall_time_unix_ns = @as(i128, zts.trace.unixMillis()) * std.time.ns_per_ms,
        });
        request.turn = &self.turn;
        request.agent_prompt = prompt;
        request.tool_grant = tool_auth.agentGrantFor(agent);
        request.strip_authorization = true;
        rt.config.contract_has_catalog = true;
        rt.config.contract_has_agent = true;
        return self;
    }

    pub fn finish(self: *ReplayTurn, status: u16, timed_out: bool) !void {
        try self.recorder.terminal(.{
            .turn_id = self.turn.id,
            .sequence = self.turn.nextSequence(),
            .kind = .terminal,
            .monotonic_ns = try zts.monotonicNowNs(),
            .terminal_tag = self.turn.terminalTag(status, timed_out),
        });
    }

    pub fn deinit(self: *ReplayTurn) void {
        self.turn.deinit();
        self.recorder.deinit();
        self.catalog.deinit();
        self.prompt_arena.deinit();
        self.allocator.destroy(self.prompt_arena);
        self.allocator.destroy(self);
    }
};

const test_catalog_prefix =
    \\import { fetch } from "zttp:fetch";
    \\import { routerMatch } from "zttp:router";
    \\import { toolCatalog } from "zttp:tool";
    \\import { schemaCompile } from "zttp:validate";
    \\schemaCompile("In", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}");
    \\schemaCompile("Out", "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}");
    \\function lookup(req) { return Response.json({}); }
;

const test_catalog_suffix =
    \\const routes = { "POST /tools/lookup": lookup, "POST /agent": assistant };
    \\toolCatalog({
    \\  lookup: { route: "POST /tools/lookup", description: "Look up one value.", input: "In", output: "Out", maxInputBytes: 4096 },
    \\  assistant: {
    \\    route: "POST /agent",
    \\    description: "Answer one question.",
    \\    maxInputBytes: 8192,
    \\    agent: {
    \\      tools: ["lookup"],
    \\      provider: { endpoint: "https://api.example.com", credential: "provider" },
    \\      limits: { rounds: 1, toolCalls: 1, toolCallsPerRound: 1, argumentBytes: 4096, resultBytes: 16384, turnDeadlineMs: 20000, providerRequestBytes: 32768 }
    \\    }
    \\  }
    \\});
    \\function handler(req) {
    \\  const found = routerMatch(routes, req);
    \\  if (found !== undefined) return found.handler(req);
    \\  return Response.json({}, { status: 404 });
    \\}
;

const completed_retry_handler = test_catalog_prefix ++
    \\function assistant(req) {
    \\  const first = fetch("https://api.example.com/v1", { credential: "provider" });
    \\  const second = fetch("https://api.example.com/v1", { credential: "provider" });
    \\  return Response.json({ first: first.status, second: second.status, error: second["error"], details: second["details"] });
    \\}
++ test_catalog_suffix;

const caught_unknown_handler = test_catalog_prefix ++
    \\function assistant(req) {
    \\  const result = fetch("https://api.example.com/v1", { credential: "provider" });
    \\  return Response.json({ fetchStatus: result.status, caught: result["error"], details: result["details"] });
    \\}
++ test_catalog_suffix;

fn testRequest(body: []const u8) HttpRequestView {
    return .{
        .method = "POST",
        .url = "/agent",
        .path = "/agent",
        .query_params = &.{},
        .headers = .empty,
        .body = body,
    };
}

test "replayOne keeps completed provider replay in memory and refuses the excess round" {
    const replay_runner = @import("replay_runner.zig");
    const io_calls = [_]zts.trace.IoEntry{.{
        .seq = 0,
        .module = "fetch",
        .func = "fetch",
        .args_json = "[\"https://api.example.com/v1\",{\"credential\":\"provider\"}]",
        .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{},\"body\":\"done\"}",
        .provider_phase = .completed,
        .provider_status = 200,
    }};
    const group = zts.trace.RequestTraceGroup{
        .request = .{
            .method = "POST",
            .url = "/agent",
            .headers_json = "{}",
            .body = "{\"version\":1,\"prompt\":\"private prompt\"}",
        },
        .io_calls = &io_calls,
        .response = null,
        .meta = null,
    };
    var result = try replay_runner.replayOne(
        std.testing.allocator,
        .{ .replay_file_path = "memory", .enforce_arena_escape = false },
        completed_retry_handler,
        "agent-replay.ts",
        &group,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.match);
    try std.testing.expectEqual(@as(u16, 200), result.actual_status);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.actual_body_owned, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 200), object.get("first").?.integer);
    try std.testing.expectEqual(@as(i64, 599), object.get("second").?.integer);
    try std.testing.expectEqualStrings("AgentTurnRefused", object.get("error").?.string);
    try std.testing.expectEqualStrings("budget_exhausted", object.get("details").?.string);
    try std.testing.expectEqual(@as(u32, 1), result.io_total);
    try std.testing.expectEqual(@as(u32, 0), result.io_divergences);
}

test "provider trace phase produces exact unknown records without prompt data" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "memory",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();
    const io_calls = [_]zts.trace.IoEntry{.{
        .seq = 0,
        .module = "fetch",
        .func = "fetch",
        .args_json = "[]",
        .result_json = "{\"status\":599,\"statusText\":\"Unknown\",\"ok\":false,\"headers\":{},\"body\":\"\",\"error\":\"OutcomeUnknown\",\"details\":\"head_failed\"}",
        .provider_phase = .request_started,
    }};
    var replay_state = zts.trace.ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        zts.trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &zts.trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[zts.trace.REPLAY_STATE_SLOT] = null;
    try rt.loadCode(caught_unknown_handler, "agent-unknown-replay.ts");

    const prompt = "prompt-must-not-enter-recorder";
    var request = testRequest("{\"version\":1,\"prompt\":\"prompt-must-not-enter-recorder\"}");
    const replay_turn = (try ReplayTurn.prepare(
        allocator,
        rt,
        caught_unknown_handler,
        "agent-unknown-replay.ts",
        &request,
    )) orelse return error.TestExpectedAgentTurn;
    defer replay_turn.deinit();
    try std.testing.expect(replay_turn.recorder.filePath() == null);

    var response = try rt.executeHandler(request);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try replay_turn.finish(response.status, false);

    const records = try replay_turn.recorder.memoryBytes();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, records, "\"kind\":\"pre\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, records, "\"kind\":\"post\""));
    try std.testing.expect(std.mem.find(u8, records, "\"class\":\"outcome_unknown\"") != null);
    try std.testing.expect(std.mem.find(u8, records, "\"terminalTag\":\"outcome_unknown\"") != null);
    try std.testing.expect(std.mem.find(u8, records, prompt) == null);
    try std.testing.expectEqual(@as(u32, 1), replay_state.cursor);
}

test "agent InternalError classification follows the recorded transport phase" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        phase: ?zts.trace.ProviderPhase,
        status: ?u16 = null,
        class: turn_recorder.OutcomeClass,
    }{
        .{ .phase = .not_started, .class = .not_started },
        .{ .phase = .request_started, .class = .outcome_unknown },
        .{ .phase = .head_received, .status = 200, .class = .outcome_unknown },
        .{ .phase = null, .class = .outcome_unknown },
    };
    for (cases) |case| {
        const rt = try HandlerInstance.init(allocator, .{ .replay_file_path = "memory", .enforce_arena_escape = false });
        defer rt.deinit();
        const io_calls = [_]zts.trace.IoEntry{.{
            .seq = 0,
            .module = "fetch",
            .func = "fetch",
            .args_json = "[]",
            .result_json = "{\"status\":599,\"body\":\"\",\"error\":\"InternalError\",\"details\":\"OutOfMemory\"}",
            .provider_phase = case.phase,
            .provider_status = case.status,
        }};
        var replay_state = zts.trace.ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };
        rt.ctx.setModuleState(zts.trace.REPLAY_STATE_SLOT, @ptrCast(&replay_state), &zts.trace.ReplayState.deinitOpaque);
        defer rt.ctx.module_state[zts.trace.REPLAY_STATE_SLOT] = null;
        try rt.loadCode(caught_unknown_handler, "agent-internal-error.ts");
        var request = testRequest("{\"version\":1,\"prompt\":\"hello\"}");
        const active = (try ReplayTurn.prepare(allocator, rt, caught_unknown_handler, "agent-internal-error.ts", &request)) orelse return error.TestExpectedAgentTurn;
        defer active.deinit();
        var response = try rt.executeHandler(request);
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expect(std.mem.find(u8, response.body, "InternalError") != null);
        try std.testing.expectEqual(@as(u32, 1), replay_state.cursor);
        try std.testing.expectEqual(case.class, active.turn.providerOutcome());
        try std.testing.expectEqual(@as(?turn_recorder.TerminalTag, if (case.class == .outcome_unknown) .outcome_unknown else null), active.turn.latch);
        try active.finish(response.status, false);
        var lines = std.mem.splitScalar(u8, try active.recorder.memoryBytes(), '\n');
        var posts: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            const object = parsed.value.object;
            if (!std.mem.eql(u8, object.get("kind").?.string, "post")) continue;
            posts += 1;
            try std.testing.expectEqualStrings(@tagName(case.class), object.get("class").?.string);
            try std.testing.expectEqual(case.status != null, object.get("headReceived").?.bool);
        }
        try std.testing.expectEqual(@as(usize, 1), posts);
    }
}

test "replay recorder failure refuses before consuming provider trace" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "memory",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();
    const io_calls = [_]zts.trace.IoEntry{.{
        .seq = 0,
        .module = "fetch",
        .func = "fetch",
        .args_json = "[]",
        .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{},\"body\":\"done\"}",
        .provider_phase = .completed,
        .provider_status = 200,
    }};
    var replay_state = zts.trace.ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        zts.trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &zts.trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[zts.trace.REPLAY_STATE_SLOT] = null;
    try rt.loadCode(caught_unknown_handler, "agent-recorder-failure-replay.ts");

    var request = testRequest("{\"version\":1,\"prompt\":\"hello\"}");
    const replay_turn = (try ReplayTurn.prepare(
        allocator,
        rt,
        caught_unknown_handler,
        "agent-recorder-failure-replay.ts",
        &request,
    )) orelse return error.TestExpectedAgentTurn;
    defer replay_turn.deinit();
    try replay_turn.recorder.failNextMemoryWrite();

    var response = try rt.executeHandler(request);
    defer response.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), object.get("fetchStatus").?.integer);
    try std.testing.expectEqualStrings("AgentTurnRefused", object.get("caught").?.string);
    try std.testing.expectEqualStrings("recorder_unavailable", object.get("details").?.string);
    try std.testing.expectEqual(@as(u32, 0), replay_state.cursor);
    try std.testing.expect(!replay_turn.recorder.isHealthy());
}

test "closed replay latch refuses before consuming provider trace" {
    const allocator = std.testing.allocator;
    const rt = try HandlerInstance.init(allocator, .{
        .replay_file_path = "memory",
        .enforce_arena_escape = false,
    });
    defer rt.deinit();
    const io_calls = [_]zts.trace.IoEntry{.{
        .seq = 0,
        .module = "fetch",
        .func = "fetch",
        .args_json = "[]",
        .result_json = "{\"status\":200,\"statusText\":\"OK\",\"ok\":true,\"headers\":{},\"body\":\"done\"}",
        .provider_phase = .completed,
        .provider_status = 200,
    }};
    var replay_state = zts.trace.ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        zts.trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &zts.trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[zts.trace.REPLAY_STATE_SLOT] = null;
    try rt.loadCode(caught_unknown_handler, "agent-latched-replay.ts");

    var request = testRequest("{\"version\":1,\"prompt\":\"hello\"}");
    const replay_turn = (try ReplayTurn.prepare(
        allocator,
        rt,
        caught_unknown_handler,
        "agent-latched-replay.ts",
        &request,
    )) orelse return error.TestExpectedAgentTurn;
    defer replay_turn.deinit();
    replay_turn.turn.closeLatch(.tool_failed);

    var response = try rt.executeHandler(request);
    defer response.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 599), object.get("fetchStatus").?.integer);
    try std.testing.expectEqualStrings("AgentTurnRefused", object.get("caught").?.string);
    try std.testing.expectEqualStrings("tool_failed", object.get("details").?.string);
    try std.testing.expectEqual(@as(u32, 0), replay_state.cursor);
    try replay_turn.finish(response.status, false);
    const records = try replay_turn.recorder.memoryBytes();
    try std.testing.expect(std.mem.find(u8, records, "\"terminalTag\":\"tool_failed\"") != null);
}

test "replayOne preserves an ordinary non-agent replay" {
    const replay_runner = @import("replay_runner.zig");
    const group = zts.trace.RequestTraceGroup{
        .request = .{ .method = "GET", .url = "/", .headers_json = "{}", .body = null },
        .io_calls = &.{},
        .response = null,
        .meta = null,
    };
    var result = try replay_runner.replayOne(
        std.testing.allocator,
        .{ .replay_file_path = "memory", .enforce_arena_escape = false },
        "function handler(req) { return Response.text(\"ordinary\"); }",
        "ordinary.ts",
        &group,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.match);
    try std.testing.expectEqualStrings("ordinary", result.actual_body_owned);
    try std.testing.expectEqual(@as(u32, 0), result.io_total);
}
