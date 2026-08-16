//! Handler Test Runner
//!
//! Runs declarative handler tests defined as JSONL test cases.
//! Leverages the deterministic replay infrastructure: because virtual modules
//! are the ONLY I/O boundary, handlers are pure functions of
//! (Request, VirtualModuleResponses).
//!
//! Test file format (JSONL):
//!   {"type":"test","name":"descriptive name"}
//!   {"type":"request","method":"GET","url":"/path","headers":{},"body":null}
//!   {"type":"io","seq":0,"module":"env","fn":"env","args":["KEY"],"result":"value"}
//!   {"type":"expect","status":200,"body":"{\"ok\":true}","bodyContains":null}
//!
//! Usage:
//!   zig build run -- handler.ts --test tests.jsonl

const std = @import("std");
const builtin = @import("builtin");
const zq = @import("zts");
const RuntimeConfig = @import("runtime_config.zig").RuntimeConfig;
const HandlerInstance = @import("handler_instance.zig").HandlerInstance;
const HttpRequestView = @import("http_types.zig").HttpRequestView;
const HttpHeader = @import("http_types.zig").HttpHeader;
const HttpResponse = @import("http_types.zig").HttpResponse;
const ExecutionSpec = @import("execution_spec.zig").ExecutionSpec;
const actor_queue = @import("actor_queue.zig");
const durable_executor = @import("durable_executor.zig");
const DurableStore = @import("durable_store.zig").DurableStore;
const handler_loader = @import("handler_loader.zig");
const in_process_dispatch = @import("in_process_dispatch.zig");
const runtime_natives = @import("runtime_natives.zig");
const workflow_queue = @import("workflow_queue.zig");

const trace = zq.trace;
const parseHeadersFromJson = @import("trace_helpers.zig").parseHeadersFromJson;

const TestAssertions = struct {
    status: ?u16 = null,
    body: ?[]const u8 = null,
    body_contains: ?[]const u8 = null,
    headers_json: ?[]const u8 = null,
};

const TestCase = struct {
    name: []const u8,
    request: ?trace.RequestTrace = null,
    io_calls: []const trace.IoEntry = &.{},
    assertions: TestAssertions = .{},
};

const RuntimeScenario = struct {
    durable: bool,
    workflow_queue: bool,
};

const ExpectedRun = struct {
    run_key: []const u8,
    complete: bool,
};

const ExpectedEventKind = enum {
    step_start,
    step_result,
    wait_signal,
    resume_signal,
};

const ExpectedEvent = struct {
    run_key: []const u8,
    kind: ExpectedEventKind,
    name: []const u8,
    result_contains: ?[]const u8 = null,
    payload_contains: ?[]const u8 = null,
};

const ExpectedQueue = struct {
    run_key: []const u8,
    step: []const u8,
    status: u16,
    body_contains: ?[]const u8 = null,
};

const RuntimeAssertions = struct {
    runs: []const ExpectedRun = &.{},
    events: []const ExpectedEvent = &.{},
    queues: []const ExpectedQueue = &.{},
    signal_artifact_count: ?usize = null,
};

const TestSuite = struct {
    tests: []TestCase,
    scenario: ?RuntimeScenario = null,
    runtime_assertions: RuntimeAssertions = .{},

    fn deinit(self: *TestSuite, allocator: std.mem.Allocator) void {
        for (self.tests) |test_case| allocator.free(test_case.io_calls);
        allocator.free(self.tests);
        allocator.free(self.runtime_assertions.runs);
        allocator.free(self.runtime_assertions.events);
        allocator.free(self.runtime_assertions.queues);
        self.* = undefined;
    }
};

const ScenarioBackend = struct {
    allocator: std.mem.Allocator,
    durable_dir: ?[]u8 = null,
    system_runtime: ?in_process_dispatch.SystemRuntime = null,

    fn init(
        allocator: std.mem.Allocator,
        scenario: RuntimeScenario,
        config: *RuntimeConfig,
    ) !ScenarioBackend {
        if (scenario.workflow_queue and !scenario.durable) {
            return error.WorkflowQueueRequiresDurable;
        }
        if (scenario.workflow_queue and config.system_config_path == null) {
            return error.WorkflowQueueRequiresSystem;
        }

        var backend = ScenarioBackend{ .allocator = allocator };
        errdefer backend.deinit();

        if (scenario.durable) {
            backend.durable_dir = try createPrivateScenarioDir(allocator);
            config.durable_oplog_dir = backend.durable_dir.?;
        } else {
            config.durable_oplog_dir = null;
        }
        config.workflow_queue_enabled = scenario.workflow_queue;

        if (config.system_config_path) |system_path| {
            backend.system_runtime = try in_process_dispatch.SystemRuntime.buildFromSystemConfig(
                allocator,
                system_path,
                config.*,
                1,
            );
        }
        // The registry pointer is installed by run() only after this value has
        // moved into its final optional storage. Pointing at the local
        // `backend` here leaves RuntimeConfig holding a dangling address.
        config.system_registry = null;
        return backend;
    }

    fn deinit(self: *ScenarioBackend) void {
        if (self.system_runtime) |*system_runtime| system_runtime.deinit();
        if (self.durable_dir) |path| {
            deleteScenarioDir(self.allocator, path);
            self.allocator.free(path);
        }
        self.* = undefined;
    }
};

fn createPrivateScenarioDir(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random_bytes: [8]u8 = undefined;
        try io.randomSecure(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(
            allocator,
            "/tmp/zttp-test-scenario-{d}-{s}",
            .{ std.c.getpid(), &random_hex },
        );
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        switch (std.posix.errno(std.posix.system.mkdir(path_z, 0o700))) {
            .SUCCESS => return path,
            .EXIST => allocator.free(path),
            else => {
                allocator.free(path);
                return error.MakeScenarioDirectoryFailed;
            },
        }
    }
    return error.MakeScenarioDirectoryFailed;
}

fn deleteScenarioDir(allocator: std.mem.Allocator, path: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const parent = std.fs.path.dirname(path) orelse return;
    const name = std.fs.path.basename(path);
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer dir.close(io);
    dir.deleteTree(io, name) catch {};
}

pub fn run(allocator: std.mem.Allocator, spec: ExecutionSpec) !void {
    const test_path = spec.runtime_config.test_file_path orelse return error.NoTestFile;

    const test_source = readFile(allocator, test_path) catch |err| {
        std.log.err("Failed to read test file '{s}': {}", .{ test_path, err });
        return err;
    };
    defer allocator.free(test_source);

    var suite = parseTestFile(allocator, test_source) catch |err| {
        if (err == error.InvalidTestFixture) {
            std.log.err(
                "Invalid test fixture '{s}'. Expected JSONL test rows or a strict runtime scenario.",
                .{test_path},
            );
        }
        return err;
    };
    defer suite.deinit(allocator);
    const tests = suite.tests;

    if (tests.len == 0) {
        std.log.info("No tests found in '{s}'\n", .{test_path});
        return;
    }

    const loaded = handler_loader.load(allocator, spec.handler) catch |err| {
        switch (err) {
            error.UnsupportedHandlerSource => std.log.err("Handler tests require a file_path or inline_code handler source", .{}),
            else => std.log.err("Handler tests failed to load handler: {}", .{err}),
        }
        return err;
    };
    const handler_code = loaded.code;
    const handler_filename = loaded.filename;
    defer allocator.free(handler_code);

    // Set replay_file_path sentinel so HandlerInstance installs replay stubs
    // instead of real virtual module functions.
    var test_config = spec.runtime_config;
    test_config.trace_file_path = null;
    test_config.replay_file_path = "test";
    // Disable arena escape enforcement: each test creates an isolated runtime
    // that is destroyed after the test, so arena objects can't outlive their scope.
    test_config.enforce_arena_escape = false;

    var scenario_backend: ?ScenarioBackend = null;
    defer if (scenario_backend) |*backend| backend.deinit();
    if (suite.scenario) |scenario| {
        scenario_backend = try ScenarioBackend.init(allocator, scenario, &test_config);
        if (scenario_backend.?.system_runtime != null) {
            test_config.system_registry = @ptrCast(&scenario_backend.?.system_runtime.?);
        }
    }

    std.debug.print("\nTesting {s} ({d} tests)\n\n", .{ handler_filename, tests.len });

    var passed: u32 = 0;
    var failed: u32 = 0;

    for (tests) |test_case| {
        const result = runOneTest(
            allocator,
            test_config,
            handler_code,
            handler_filename,
            &test_case,
            .{ .strict_replay = suite.scenario != null },
        );
        if (result.pass) {
            passed += 1;
            std.debug.print("  PASS  {s}\n", .{result.name});
        } else {
            failed += 1;
            std.debug.print("  FAIL  {s}\n", .{result.name});
            if (result.err) |err| {
                std.debug.print("        error: {}\n", .{err});
            }
            for (result.failures.items) |msg| {
                std.debug.print("        {s}\n", .{msg});
            }
            result.deinitFailures(allocator);
        }
    }

    if (suite.scenario != null) {
        const result = runScenarioAssertions(
            allocator,
            scenario_backend.?.durable_dir,
            &suite.runtime_assertions,
        );
        if (result.pass) {
            passed += 1;
            std.debug.print("  PASS  {s}\n", .{result.name});
        } else {
            failed += 1;
            std.debug.print("  FAIL  {s}\n", .{result.name});
            if (result.err) |err| std.debug.print("        error: {}\n", .{err});
            for (result.failures.items) |msg| std.debug.print("        {s}\n", .{msg});
            result.deinitFailures(allocator);
        }
    }

    std.debug.print("\nResults: {d} passed, {d} failed, {d} total\n", .{
        passed, failed, passed + failed,
    });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

const TestResult = struct {
    pass: bool,
    name: []const u8,
    failures: std.ArrayList([]const u8),
    err: ?anyerror = null,

    fn deinitFailures(self: TestResult, allocator: std.mem.Allocator) void {
        for (self.failures.items) |msg| allocator.free(msg);
        var f = self.failures;
        f.deinit(allocator);
    }
};

const RunOneOptions = struct {
    strict_replay: bool = false,
};

fn runOneTest(
    allocator: std.mem.Allocator,
    config: RuntimeConfig,
    handler_code: []const u8,
    handler_filename: []const u8,
    test_case: *const TestCase,
    options: RunOneOptions,
) TestResult {
    var failures: std.ArrayList([]const u8) = .empty;

    const request = test_case.request orelse {
        const msg = std.fmt.allocPrint(allocator, "no request defined", .{}) catch
            return .{ .pass = false, .name = test_case.name, .failures = failures, .err = error.OutOfMemory };
        failures.append(allocator, msg) catch {};
        return .{ .pass = false, .name = test_case.name, .failures = failures, .err = null };
    };

    // Each test case gets its own zttp:queue ActorQueue, matching the
    // fresh HandlerInstance and ReplayState below: sharing one queue across test
    // cases in the same file would leak mailbox/lease/dead-letter state
    // (e.g. a message left un-received by one test would be visible to
    // the next, unlike every other virtual module which replays isolated
    // per test case).
    var test_config = config;
    var test_queue: ?actor_queue.ActorQueue = null;
    defer if (test_queue) |*queue| queue.deinit();
    if (test_config.queue_actor_enabled and test_config.queue_system == null) {
        test_queue = actor_queue.ActorQueue.init(allocator, test_config.queue_capacity, test_config.queue_lease_ms);
        test_config.queue_system = @ptrCast(&test_queue.?);
    }

    const rt = HandlerInstance.init(allocator, test_config) catch |err| {
        return .{ .pass = false, .name = test_case.name, .failures = failures, .err = err };
    };
    defer rt.deinit();

    var replay_state = trace.ReplayState{
        .io_calls = test_case.io_calls,
        .cursor = 0,
        .divergences = 0,
    };
    rt.ctx.setModuleState(
        trace.REPLAY_STATE_SLOT,
        @ptrCast(&replay_state),
        &trace.ReplayState.deinitOpaque,
    );
    defer rt.ctx.module_state[trace.REPLAY_STATE_SLOT] = null;

    rt.loadCode(handler_code, handler_filename) catch |err| {
        return .{ .pass = false, .name = test_case.name, .failures = failures, .err = err };
    };

    var headers_list: std.ArrayListUnmanaged(HttpHeader) = .empty;
    defer headers_list.deinit(allocator);
    parseHeadersFromJson(allocator, request.headers_json, &headers_list) catch {};

    // Split req.path and parse req.query exactly as the live server does, via
    // the shared helper every recorded-request consumer uses. Without it,
    // zruntime falls back to the full url for req.path (keeping the "?query"
    // suffix) and a handler reading req.query.* would see an empty object under
    // `serve --test`.
    const target = runtime_natives.parseRequestTarget(allocator, request.url);
    defer target.deinit(allocator);

    // Unescape the request body (shared with the replay runner) so a JSONL body
    // like "{\"title\":\"x\"}" reaches the handler as real JSON rather than the
    // backslash-escaped literal.
    const ub = trace.unescapeBody(allocator, request.body);
    defer if (ub.owned) |owned| allocator.free(owned);

    var response = rt.executeHandler(.{
        .method = request.method,
        .url = request.url,
        .path = target.path,
        .query_params = target.params,
        .headers = headers_list,
        .body = ub.slice,
    }) catch |err| {
        // A hole is an unfinished path, not a failing one, and the servers
        // answer it with 501. A test asserting that status must see the same
        // thing here, or `zttp test` would contradict `zttp dev` about what a
        // half-written handler does.
        if (err == error.HandlerNotImplemented) {
            var not_implemented: HttpResponse = .{
                .status = 501,
                .headers = .empty,
                .body = "Not Implemented: this path reached a hole() the handler has not filled yet",
                .body_owned = false,
                .body_owner = null,
                .requires_runtime = false,
                .allocator = allocator,
            };
            defer not_implemented.deinit();
            checkAssertions(allocator, &not_implemented, &test_case.assertions, &failures);
            if (options.strict_replay) checkReplayState(allocator, &replay_state, &failures);
            return .{
                .pass = failures.items.len == 0,
                .name = test_case.name,
                .failures = failures,
                .err = null,
            };
        }
        return .{ .pass = false, .name = test_case.name, .failures = failures, .err = err };
    };
    defer response.deinit();

    checkAssertions(allocator, &response, &test_case.assertions, &failures);

    if (options.strict_replay) checkReplayState(allocator, &replay_state, &failures);

    // NOTE (RS1/RS2): serve --test deliberately does NOT fail on
    // replay_state.divergences. The counter conflates real drift (a reordered
    // effectful call) with benign noise - hand-written fixtures whose arg JSON
    // is non-canonical (argsDrifted byte-compares), and pure modules that run
    // for real under --test without consuming their recorded entry. Failing on
    // it here false-positives on legitimate example fixtures. Making the signal
    // usable requires precise divergence accounting (distinguish name-mismatch
    // from arg-formatting); until then the strict consumed-all/divergence gate
    // lives only in the replay verifier (replay_runner), which uses
    // recorder-produced capsules.

    return .{
        .pass = failures.items.len == 0,
        .name = test_case.name,
        .failures = failures,
        .err = null,
    };
}

fn checkReplayState(
    allocator: std.mem.Allocator,
    replay_state: *const trace.ReplayState,
    failures: *std.ArrayList([]const u8),
) void {
    if (replay_state.divergences != 0) {
        const message = std.fmt.allocPrint(
            allocator,
            "runtime scenario replay diverged {d} time(s)",
            .{replay_state.divergences},
        ) catch return;
        failures.append(allocator, message) catch allocator.free(message);
    }
    const unconsumed = replay_state.unconsumedCount();
    if (unconsumed != 0) {
        const message = std.fmt.allocPrint(
            allocator,
            "runtime scenario left {d} I/O expectation(s) unconsumed",
            .{unconsumed},
        ) catch return;
        failures.append(allocator, message) catch allocator.free(message);
    }
}

const DurableEnvelopeCounts = struct {
    run: usize = 0,
    request: usize = 0,
    response: usize = 0,
    complete: usize = 0,
};

fn requiredJsonString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidScenarioDurableLog;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidScenarioDurableLog,
    };
}

fn requiredNonemptyJsonString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = try requiredJsonString(object, field);
    if (value.len == 0) return error.InvalidScenarioDurableLog;
    return value;
}

fn requireJsonInteger(object: std.json.ObjectMap, field: []const u8) !void {
    const value = object.get(field) orelse return error.InvalidScenarioDurableLog;
    if (value != .integer) return error.InvalidScenarioDurableLog;
}

fn requireJsonObject(object: std.json.ObjectMap, field: []const u8) !void {
    const value = object.get(field) orelse return error.InvalidScenarioDurableLog;
    if (value != .object) return error.InvalidScenarioDurableLog;
}

fn requireOnlyJsonFields(
    object: std.json.ObjectMap,
    comptime allowed: []const []const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        inline for (allowed) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field)) known = true;
        }
        if (!known) return error.InvalidScenarioDurableLog;
    }
}

fn validateStrictDurableLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    expected_run_key: []const u8,
    counts: *DurableEnvelopeCounts,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidScenarioDurableLog;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidScenarioDurableLog,
    };
    const row_type = try requiredNonemptyJsonString(object, "type");
    const entry = trace.parseTraceLine(line) catch return error.InvalidScenarioDurableLog;

    if (std.mem.eql(u8, row_type, "durable_run")) {
        try requireOnlyJsonFields(object, &.{ "type", "key" });
        if (entry != .durable_run) return error.InvalidScenarioDurableLog;
        const key = try requiredNonemptyJsonString(object, "key");
        if (!std.mem.eql(u8, key, expected_run_key)) return error.InvalidScenarioDurableLog;
        counts.run += 1;
    } else if (std.mem.eql(u8, row_type, "request")) {
        try requireOnlyJsonFields(object, &.{ "type", "method", "url", "headers", "body" });
        if (entry != .request) return error.InvalidScenarioDurableLog;
        _ = try requiredNonemptyJsonString(object, "method");
        _ = try requiredNonemptyJsonString(object, "url");
        try requireJsonObject(object, "headers");
        const body = object.get("body") orelse return error.InvalidScenarioDurableLog;
        if (body != .null and body != .string) return error.InvalidScenarioDurableLog;
        counts.request += 1;
    } else if (std.mem.eql(u8, row_type, "io")) {
        try requireOnlyJsonFields(object, &.{ "type", "seq", "module", "fn", "args", "result" });
        if (entry != .io) return error.InvalidScenarioDurableLog;
        try requireJsonInteger(object, "seq");
        _ = try requiredNonemptyJsonString(object, "module");
        _ = try requiredNonemptyJsonString(object, "fn");
        const args = object.get("args") orelse return error.InvalidScenarioDurableLog;
        if (args != .array or object.get("result") == null) return error.InvalidScenarioDurableLog;
    } else if (std.mem.eql(u8, row_type, "step_start")) {
        try requireOnlyJsonFields(object, &.{ "type", "name" });
        if (entry != .step_start) return error.InvalidScenarioDurableLog;
        _ = try requiredNonemptyJsonString(object, "name");
    } else if (std.mem.eql(u8, row_type, "step_result")) {
        try requireOnlyJsonFields(object, &.{ "type", "name", "result" });
        if (entry != .step_result) return error.InvalidScenarioDurableLog;
        _ = try requiredNonemptyJsonString(object, "name");
        if (object.get("result") == null) return error.InvalidScenarioDurableLog;
    } else if (std.mem.eql(u8, row_type, "wait_timer")) {
        try requireOnlyJsonFields(object, &.{ "type", "until_ms", "timeout_ms" });
        if (entry != .wait_timer) return error.InvalidScenarioDurableLog;
        try requireJsonInteger(object, "until_ms");
    } else if (std.mem.eql(u8, row_type, "resume_timer")) {
        try requireOnlyJsonFields(object, &.{ "type", "fired_at_ms" });
        if (entry != .resume_timer) return error.InvalidScenarioDurableLog;
        try requireJsonInteger(object, "fired_at_ms");
    } else if (std.mem.eql(u8, row_type, "wait_signal")) {
        try requireOnlyJsonFields(object, &.{ "type", "name", "timeout_ms" });
        if (entry != .wait_signal) return error.InvalidScenarioDurableLog;
        _ = try requiredNonemptyJsonString(object, "name");
    } else if (std.mem.eql(u8, row_type, "resume_signal")) {
        try requireOnlyJsonFields(object, &.{ "type", "name", "payload" });
        if (entry != .resume_signal) return error.InvalidScenarioDurableLog;
        _ = try requiredNonemptyJsonString(object, "name");
        if (object.get("payload") == null) return error.InvalidScenarioDurableLog;
    } else if (std.mem.eql(u8, row_type, "response")) {
        try requireOnlyJsonFields(object, &.{ "type", "status", "headers", "body" });
        if (entry != .response) return error.InvalidScenarioDurableLog;
        try requireJsonInteger(object, "status");
        try requireJsonObject(object, "headers");
        _ = try requiredJsonString(object, "body");
        counts.response += 1;
    } else if (std.mem.eql(u8, row_type, "complete")) {
        try requireOnlyJsonFields(object, &.{"type"});
        if (entry != .complete) return error.InvalidScenarioDurableLog;
        counts.complete += 1;
    } else {
        return error.InvalidScenarioDurableLog;
    }
}

fn scanStrictDurableOplog(
    allocator: std.mem.Allocator,
    source: []const u8,
    expected_run_key: []const u8,
) !DurableEnvelopeCounts {
    if (source.len == 0 or source[source.len - 1] != '\n') {
        return error.InvalidScenarioDurableLog;
    }
    var counts: DurableEnvelopeCounts = .{};
    var nonempty_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        nonempty_lines += 1;
        try validateStrictDurableLine(allocator, line, expected_run_key, &counts);
    }
    if (nonempty_lines == 0) return error.InvalidScenarioDurableLog;
    return counts;
}

fn expectedEventCount(assertions: *const RuntimeAssertions, run_key: []const u8) usize {
    var count: usize = 0;
    for (assertions.events) |event| {
        if (std.mem.eql(u8, event.run_key, run_key)) count += 1;
    }
    return count;
}

fn expectedEventAt(
    assertions: *const RuntimeAssertions,
    run_key: []const u8,
    wanted_index: usize,
) ?ExpectedEvent {
    var index: usize = 0;
    for (assertions.events) |event| {
        if (!std.mem.eql(u8, event.run_key, run_key)) continue;
        if (index == wanted_index) return event;
        index += 1;
    }
    return null;
}

fn appendScenarioFailure(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList([]const u8),
    comptime format: []const u8,
    args: anytype,
) void {
    const message = std.fmt.allocPrint(allocator, format, args) catch return;
    failures.append(allocator, message) catch allocator.free(message);
}

fn compareExpectedEvent(
    allocator: std.mem.Allocator,
    failures: *std.ArrayList([]const u8),
    run_key: []const u8,
    index: usize,
    expected: ExpectedEvent,
    actual: trace.DurableEvent,
) void {
    const actual_kind: ExpectedEventKind = switch (actual) {
        .step_start => .step_start,
        .step_result => .step_result,
        .wait_signal => .wait_signal,
        .resume_signal => .resume_signal,
        else => unreachable,
    };
    if (actual_kind != expected.kind) {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}' event {d}: expected {s}, found {s}",
            .{ run_key, index, @tagName(expected.kind), @tagName(actual_kind) },
        );
        return;
    }

    const actual_name = switch (actual) {
        .step_start => |event| event.name,
        .step_result => |event| event.name,
        .wait_signal => |event| event.name,
        .resume_signal => |event| event.name,
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual_name, expected.name)) {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}' event {d}: expected name '{s}', found '{s}'",
            .{ run_key, index, expected.name, actual_name },
        );
    }

    if (expected.result_contains) |fixture_needle| {
        const needle = trace.unescapeJson(allocator, fixture_needle) catch fixture_needle;
        defer if (needle.ptr != fixture_needle.ptr) allocator.free(needle);
        switch (actual) {
            .step_result => |event| if (std.mem.indexOf(u8, event.result_json, needle) == null) {
                appendScenarioFailure(
                    allocator,
                    failures,
                    "run '{s}' event {d}: result does not contain '{s}'",
                    .{ run_key, index, needle },
                );
            },
            else => unreachable,
        }
    }
    if (expected.payload_contains) |fixture_needle| {
        const needle = trace.unescapeJson(allocator, fixture_needle) catch fixture_needle;
        defer if (needle.ptr != fixture_needle.ptr) allocator.free(needle);
        switch (actual) {
            .resume_signal => |event| if (std.mem.indexOf(u8, event.payload_json, needle) == null) {
                appendScenarioFailure(
                    allocator,
                    failures,
                    "run '{s}' event {d}: payload does not contain '{s}'",
                    .{ run_key, index, needle },
                );
            },
            else => unreachable,
        }
    }
}

fn assertDurableRun(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    assertions: *const RuntimeAssertions,
    expected_run: ExpectedRun,
    failures: *std.ArrayList([]const u8),
) !void {
    const path = try durable_executor.buildDurableOplogPathForDir(
        allocator,
        durable_dir,
        expected_run.run_key,
    );
    defer allocator.free(path);
    const source = readFile(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            appendScenarioFailure(
                allocator,
                failures,
                "run '{s}': durable oplog is missing",
                .{expected_run.run_key},
            );
            return;
        },
        else => return err,
    };
    defer allocator.free(source);

    const counts = scanStrictDurableOplog(allocator, source, expected_run.run_key) catch |err| {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': invalid durable oplog ({s})",
            .{ expected_run.run_key, @errorName(err) },
        );
        return;
    };
    if (counts.run != 1 or counts.request != 1) {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': expected one run and request envelope, found {d} and {d}",
            .{ expected_run.run_key, counts.run, counts.request },
        );
    }
    const expected_terminal_count: usize = if (expected_run.complete) 1 else 0;
    if (counts.response != expected_terminal_count or counts.complete != expected_terminal_count) {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': expected response/complete counts {d}/{d}, found {d}/{d}",
            .{
                expected_run.run_key,
                expected_terminal_count,
                expected_terminal_count,
                counts.response,
                counts.complete,
            },
        );
    }

    var durable_log = trace.parseDurableOplog(allocator, source) catch |err| {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': durable oplog could not be decoded ({s})",
            .{ expected_run.run_key, @errorName(err) },
        );
        return;
    };
    defer durable_log.deinit();
    if (durable_log.run_key == null or
        !std.mem.eql(u8, durable_log.run_key.?, expected_run.run_key) or
        durable_log.request == null or durable_log.complete != expected_run.complete)
    {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': typed durable envelope disagrees with the expectation",
            .{expected_run.run_key},
        );
    }

    var actual_index: usize = 0;
    for (durable_log.events) |event| switch (event) {
        // I/O rows have their own exact scenario evidence: runOneTest requires
        // every declared replay row to be consumed once without divergence.
        .io => {},
        .wait_timer, .resume_timer => {
            appendScenarioFailure(
                allocator,
                failures,
                "run '{s}': found an undeclared timer event",
                .{expected_run.run_key},
            );
        },
        .step_start, .step_result, .wait_signal, .resume_signal => {
            const expected = expectedEventAt(assertions, expected_run.run_key, actual_index) orelse {
                appendScenarioFailure(
                    allocator,
                    failures,
                    "run '{s}': found extra durable event {d}",
                    .{ expected_run.run_key, actual_index },
                );
                actual_index += 1;
                continue;
            };
            compareExpectedEvent(
                allocator,
                failures,
                expected_run.run_key,
                actual_index,
                expected,
                event,
            );
            actual_index += 1;
        },
    };
    const wanted_count = expectedEventCount(assertions, expected_run.run_key);
    if (actual_index != wanted_count) {
        appendScenarioFailure(
            allocator,
            failures,
            "run '{s}': expected {d} durable events, found {d}",
            .{ expected_run.run_key, wanted_count, actual_index },
        );
    }
}

fn assertQueueResult(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    expected: ExpectedQueue,
    failures: *std.ArrayList([]const u8),
) !void {
    const id = try workflow_queue.itemId(allocator, expected.run_key, expected.step);
    defer allocator.free(id);

    if (try workflow_queue.readDead(allocator, durable_dir, id)) |dead| {
        defer allocator.free(dead);
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': item is dead-lettered",
            .{ expected.run_key, expected.step },
        );
        return;
    }
    const result = (try workflow_queue.readResult(allocator, durable_dir, id)) orelse {
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': completed result is missing",
            .{ expected.run_key, expected.step },
        );
        return;
    };
    defer allocator.free(result);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch {
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': completed result is invalid JSON",
            .{ expected.run_key, expected.step },
        );
        return;
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => {
            appendScenarioFailure(
                allocator,
                failures,
                "queue '{s}/{s}': completed result is not an object",
                .{ expected.run_key, expected.step },
            );
            return;
        },
    };
    const status_value = object.get("status") orelse {
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': completed result has no status",
            .{ expected.run_key, expected.step },
        );
        return;
    };
    const status = switch (status_value) {
        .integer => |value| std.math.cast(u16, value),
        else => null,
    } orelse {
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': completed result has an invalid status",
            .{ expected.run_key, expected.step },
        );
        return;
    };
    if (status != expected.status) {
        appendScenarioFailure(
            allocator,
            failures,
            "queue '{s}/{s}': expected status {d}, found {d}",
            .{ expected.run_key, expected.step, expected.status, status },
        );
    }
    if (expected.body_contains) |fixture_needle| {
        const needle = trace.unescapeJson(allocator, fixture_needle) catch fixture_needle;
        defer if (needle.ptr != fixture_needle.ptr) allocator.free(needle);
        const body_value = object.get("body") orelse {
            appendScenarioFailure(
                allocator,
                failures,
                "queue '{s}/{s}': completed result has no body",
                .{ expected.run_key, expected.step },
            );
            return;
        };
        const body = switch (body_value) {
            .string => |value| value,
            else => {
                appendScenarioFailure(
                    allocator,
                    failures,
                    "queue '{s}/{s}': completed result body is not a string",
                    .{ expected.run_key, expected.step },
                );
                return;
            },
        };
        if (std.mem.indexOf(u8, body, needle) == null) {
            appendScenarioFailure(
                allocator,
                failures,
                "queue '{s}/{s}': body does not contain '{s}'",
                .{ expected.run_key, expected.step, needle },
            );
        }
    }
}

fn assertSignalArtifacts(
    allocator: std.mem.Allocator,
    durable_dir: []const u8,
    expected_count: usize,
    failures: *std.ArrayList([]const u8),
) !void {
    var store = DurableStore.initFs(allocator, durable_dir);
    const artifacts = try store.listSignalArtifacts(allocator);
    defer {
        for (artifacts) |*artifact| artifact.deinit();
        allocator.free(artifacts);
    }
    if (artifacts.len != expected_count) {
        appendScenarioFailure(
            allocator,
            failures,
            "expected {d} signal artifacts, found {d}",
            .{ expected_count, artifacts.len },
        );
    }
}

fn runScenarioAssertions(
    allocator: std.mem.Allocator,
    durable_dir: ?[]const u8,
    assertions: *const RuntimeAssertions,
) TestResult {
    var failures: std.ArrayList([]const u8) = .empty;
    const dir = durable_dir orelse return .{
        .pass = false,
        .name = "runtime evidence",
        .failures = failures,
        .err = error.DurableDisabled,
    };

    for (assertions.runs) |expected_run| {
        assertDurableRun(allocator, dir, assertions, expected_run, &failures) catch |err| {
            return .{
                .pass = false,
                .name = "runtime evidence",
                .failures = failures,
                .err = err,
            };
        };
    }
    for (assertions.queues) |expected_queue| {
        assertQueueResult(allocator, dir, expected_queue, &failures) catch |err| {
            return .{
                .pass = false,
                .name = "runtime evidence",
                .failures = failures,
                .err = err,
            };
        };
    }
    if (assertions.signal_artifact_count) |expected_count| {
        assertSignalArtifacts(allocator, dir, expected_count, &failures) catch |err| {
            return .{
                .pass = false,
                .name = "runtime evidence",
                .failures = failures,
                .err = err,
            };
        };
    }
    return .{
        .pass = failures.items.len == 0,
        .name = "runtime evidence",
        .failures = failures,
        .err = null,
    };
}

fn checkAssertions(
    allocator: std.mem.Allocator,
    response: *const HttpResponse,
    assertions: *const TestAssertions,
    failures: *std.ArrayList([]const u8),
) void {
    if (assertions.status) |expected_status| {
        if (response.status != expected_status) {
            const msg = std.fmt.allocPrint(allocator, "expected status: {d}, actual status: {d}", .{
                expected_status, response.status,
            }) catch return;
            failures.append(allocator, msg) catch {};
        }
    }

    if (assertions.body) |expected_body| {
        const unescaped = trace.unescapeJson(allocator, expected_body) catch expected_body;
        defer if (unescaped.ptr != expected_body.ptr) allocator.free(unescaped);

        if (!std.mem.eql(u8, response.body, unescaped)) {
            const msg = std.fmt.allocPrint(allocator, "body mismatch:\n        expected: {s}\n        actual:   {s}", .{
                truncate(unescaped, 200), truncate(response.body, 200),
            }) catch return;
            failures.append(allocator, msg) catch {};
        }
    }

    if (assertions.body_contains) |needle| {
        const unescaped = trace.unescapeJson(allocator, needle) catch needle;
        defer if (unescaped.ptr != needle.ptr) allocator.free(unescaped);

        if (std.mem.indexOf(u8, response.body, unescaped) == null) {
            const msg = std.fmt.allocPrint(allocator, "body does not contain: {s}\n        actual body: {s}", .{
                truncate(unescaped, 100), truncate(response.body, 200),
            }) catch return;
            failures.append(allocator, msg) catch {};
        }
    }

    // Subset match: each expected header must appear in the response
    if (assertions.headers_json) |expected_headers_json| {
        var expected_headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
        defer expected_headers.deinit(allocator);
        parseHeadersFromJson(allocator, expected_headers_json, &expected_headers) catch return;

        for (expected_headers.items) |expected| {
            var found = false;
            for (response.headers.items) |actual| {
                if (std.ascii.eqlIgnoreCase(actual.key, expected.key) and
                    std.mem.eql(u8, actual.value, expected.value))
                {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const msg = std.fmt.allocPrint(allocator, "missing header: {s}: {s}", .{
                    expected.key, expected.value,
                }) catch return;
                failures.append(allocator, msg) catch {};
            }
        }
    }
}

fn truncate(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

const RuntimeRowWire = struct {
    type: []const u8,
    durable: bool,
    workflowQueue: bool,
};

const TestRowWire = struct {
    type: []const u8,
    name: []const u8,
};

const RequestRowWire = struct {
    type: []const u8,
    method: []const u8,
    url: []const u8,
    headers: std.json.Value,
    body: ?[]const u8,
};

const IoRowWire = struct {
    type: []const u8,
    seq: u32,
    module: []const u8,
    @"fn": []const u8,
    args: std.json.Value,
    result: std.json.Value,
};

const ExpectRowWire = struct {
    type: []const u8,
    status: ?u16 = null,
    body: ?[]const u8 = null,
    bodyContains: ?[]const u8 = null,
    headers: ?std.json.Value = null,
};

const ExpectedRunRowWire = struct {
    type: []const u8,
    runKey: []const u8,
    complete: bool,
};

const ExpectedEventRowWire = struct {
    type: []const u8,
    runKey: []const u8,
    kind: ExpectedEventKind,
    name: []const u8,
    resultContains: ?[]const u8 = null,
    payloadContains: ?[]const u8 = null,
};

const ExpectedQueueRowWire = struct {
    type: []const u8,
    runKey: []const u8,
    step: []const u8,
    status: u16,
    bodyContains: ?[]const u8 = null,
};

const ExpectedSignalsRowWire = struct {
    type: []const u8,
    count: usize,
};

fn parseStrictRow(
    comptime T: type,
    allocator: std.mem.Allocator,
    line: []const u8,
    expected_type: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(T, allocator, line, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTestFixture;
    defer parsed.deinit();
    if (!std.mem.eql(u8, @field(parsed.value, "type"), expected_type)) {
        return error.InvalidTestFixture;
    }
}

fn appendParsedTest(
    allocator: std.mem.Allocator,
    tests: *std.ArrayList(TestCase),
    current_name: []const u8,
    current_request: ?trace.RequestTrace,
    current_io: *std.ArrayList(trace.IoEntry),
    current_assertions: TestAssertions,
) !void {
    const io_calls = try current_io.toOwnedSlice(allocator);
    errdefer allocator.free(io_calls);
    try tests.append(allocator, .{
        .name = current_name,
        .request = current_request,
        .io_calls = io_calls,
        .assertions = current_assertions,
    });
}

fn parseTestFile(allocator: std.mem.Allocator, source: []const u8) !TestSuite {
    var tests: std.ArrayList(TestCase) = .empty;
    errdefer {
        for (tests.items) |test_case| allocator.free(test_case.io_calls);
        tests.deinit(allocator);
    }

    var expected_runs: std.ArrayList(ExpectedRun) = .empty;
    errdefer expected_runs.deinit(allocator);
    var expected_events: std.ArrayList(ExpectedEvent) = .empty;
    errdefer expected_events.deinit(allocator);
    var expected_queues: std.ArrayList(ExpectedQueue) = .empty;
    errdefer expected_queues.deinit(allocator);

    var current_name: ?[]const u8 = null;
    var current_request: ?trace.RequestTrace = null;
    var current_io: std.ArrayList(trace.IoEntry) = .empty;
    defer current_io.deinit(allocator);
    var current_assertions: TestAssertions = .{};
    var current_request_seen = false;
    var current_expect_seen = false;
    var scenario: ?RuntimeScenario = null;
    var signal_artifact_count: ?usize = null;
    var saw_nonempty_row = false;
    var assertions_started = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const type_str = trace.findJsonStringValue(trimmed, "\"type\"") orelse {
            if (!builtin.is_test) {
                std.log.err("Invalid test fixture line {d}: missing string field \"type\"", .{line_no});
            }
            return error.InvalidTestFixture;
        };

        if (std.mem.eql(u8, type_str, "runtime")) {
            if (saw_nonempty_row or scenario != null) return error.InvalidTestFixture;
            var parsed = std.json.parseFromSlice(RuntimeRowWire, allocator, trimmed, .{
                .ignore_unknown_fields = false,
                .duplicate_field_behavior = .@"error",
            }) catch return error.InvalidTestFixture;
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.type, "runtime")) {
                return error.InvalidTestFixture;
            }
            scenario = .{
                .durable = parsed.value.durable,
                .workflow_queue = parsed.value.workflowQueue,
            };
        } else if (std.mem.eql(u8, type_str, "test")) {
            if (assertions_started) return error.InvalidTestFixture;
            if (scenario != null) try parseStrictRow(TestRowWire, allocator, trimmed, "test");
            if (current_name != null) {
                if (scenario != null and (!current_request_seen or !current_expect_seen)) {
                    return error.InvalidTestFixture;
                }
                try appendParsedTest(
                    allocator,
                    &tests,
                    current_name.?,
                    current_request,
                    &current_io,
                    current_assertions,
                );
                current_request = null;
                current_assertions = .{};
                current_request_seen = false;
                current_expect_seen = false;
            }
            current_name = trace.findJsonStringValue(trimmed, "\"name\"") orelse "unnamed";
            if (scenario != null and current_name.?.len == 0) return error.InvalidTestFixture;
        } else if (std.mem.eql(u8, type_str, "request")) {
            if (assertions_started or (scenario != null and current_name == null)) {
                return error.InvalidTestFixture;
            }
            if (scenario != null) {
                if (current_request_seen) return error.InvalidTestFixture;
                try parseStrictRow(RequestRowWire, allocator, trimmed, "request");
                var parsed = try std.json.parseFromSlice(RequestRowWire, allocator, trimmed, .{
                    .ignore_unknown_fields = false,
                    .duplicate_field_behavior = .@"error",
                });
                defer parsed.deinit();
                if (parsed.value.headers != .object or
                    parsed.value.method.len == 0 or parsed.value.url.len == 0)
                {
                    return error.InvalidTestFixture;
                }
            }
            current_request = .{
                .method = trace.findJsonStringValue(trimmed, "\"method\"") orelse "GET",
                .url = trace.findJsonStringValue(trimmed, "\"url\"") orelse "/",
                .headers_json = trace.findJsonObjectValue(trimmed, "\"headers\"") orelse "{}",
                .body = trace.findJsonStringValue(trimmed, "\"body\""),
            };
            current_request_seen = true;
        } else if (std.mem.eql(u8, type_str, "io")) {
            if (assertions_started or (scenario != null and current_name == null)) {
                return error.InvalidTestFixture;
            }
            if (scenario != null) {
                try parseStrictRow(IoRowWire, allocator, trimmed, "io");
                var parsed = try std.json.parseFromSlice(IoRowWire, allocator, trimmed, .{
                    .ignore_unknown_fields = false,
                    .duplicate_field_behavior = .@"error",
                });
                defer parsed.deinit();
                if (parsed.value.args != .array or parsed.value.module.len == 0 or
                    parsed.value.@"fn".len == 0)
                {
                    return error.InvalidTestFixture;
                }
            }
            // findJsonIntValue returns ?i64 and accepts negatives; seq is u32.
            // An unguarded @intCast panics (safe builds) or wraps (ReleaseFast)
            // on a hostile fixture. Mirror the status field's guarded cast.
            const seq_i = trace.findJsonIntValue(trimmed, "\"seq\"") orelse 0;
            const seq = std.math.cast(u32, seq_i) orelse return error.InvalidTestFixture;
            try current_io.append(allocator, .{
                .seq = seq,
                .module = trace.findJsonStringValue(trimmed, "\"module\"") orelse "",
                .func = trace.findJsonStringValue(trimmed, "\"fn\"") orelse "",
                .args_json = trace.findJsonArrayValue(trimmed, "\"args\"") orelse "[]",
                .result_json = trace.findJsonAnyValue(trimmed, "\"result\"") orelse "null",
            });
        } else if (std.mem.eql(u8, type_str, "expect")) {
            if (assertions_started or (scenario != null and current_name == null)) {
                return error.InvalidTestFixture;
            }
            if (scenario != null) {
                if (current_expect_seen) return error.InvalidTestFixture;
                try parseStrictRow(ExpectRowWire, allocator, trimmed, "expect");
                var parsed = try std.json.parseFromSlice(ExpectRowWire, allocator, trimmed, .{
                    .ignore_unknown_fields = false,
                    .duplicate_field_behavior = .@"error",
                });
                defer parsed.deinit();
                if (parsed.value.status == null and parsed.value.body == null and
                    parsed.value.bodyContains == null and parsed.value.headers == null)
                {
                    return error.InvalidTestFixture;
                }
                if (parsed.value.headers) |headers| {
                    if (headers != .object) return error.InvalidTestFixture;
                }
            }
            const status_val = trace.findJsonIntValue(trimmed, "\"status\"");
            current_assertions.status = if (status_val) |s| @intCast(@max(0, @min(999, s))) else null;
            current_assertions.body = trace.findJsonStringValue(trimmed, "\"body\"");
            current_assertions.body_contains = trace.findJsonStringValue(trimmed, "\"bodyContains\"");
            current_assertions.headers_json = trace.findJsonObjectValue(trimmed, "\"headers\"");
            current_expect_seen = true;
        } else if (std.mem.eql(u8, type_str, "expect-run")) {
            if (scenario == null or current_name == null or !current_expect_seen) {
                return error.InvalidTestFixture;
            }
            assertions_started = true;
            try parseStrictRow(ExpectedRunRowWire, allocator, trimmed, "expect-run");
            var parsed = try std.json.parseFromSlice(ExpectedRunRowWire, allocator, trimmed, .{
                .ignore_unknown_fields = false,
                .duplicate_field_behavior = .@"error",
            });
            defer parsed.deinit();
            const run_key = trace.findJsonStringValue(trimmed, "\"runKey\"") orelse
                return error.InvalidTestFixture;
            if (run_key.len == 0) return error.InvalidTestFixture;
            for (expected_runs.items) |expected| {
                if (std.mem.eql(u8, expected.run_key, run_key)) return error.InvalidTestFixture;
            }
            try expected_runs.append(allocator, .{
                .run_key = run_key,
                .complete = parsed.value.complete,
            });
        } else if (std.mem.eql(u8, type_str, "expect-event")) {
            if (scenario == null or current_name == null or !current_expect_seen) {
                return error.InvalidTestFixture;
            }
            assertions_started = true;
            var parsed = std.json.parseFromSlice(ExpectedEventRowWire, allocator, trimmed, .{
                .ignore_unknown_fields = false,
                .duplicate_field_behavior = .@"error",
            }) catch return error.InvalidTestFixture;
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.type, "expect-event") or
                parsed.value.runKey.len == 0 or parsed.value.name.len == 0)
            {
                return error.InvalidTestFixture;
            }
            switch (parsed.value.kind) {
                .step_start, .wait_signal => {
                    if (parsed.value.resultContains != null or parsed.value.payloadContains != null) {
                        return error.InvalidTestFixture;
                    }
                },
                .step_result => if (parsed.value.payloadContains != null) {
                    return error.InvalidTestFixture;
                },
                .resume_signal => if (parsed.value.resultContains != null) {
                    return error.InvalidTestFixture;
                },
            }
            try expected_events.append(allocator, .{
                .run_key = trace.findJsonStringValue(trimmed, "\"runKey\"") orelse
                    return error.InvalidTestFixture,
                .kind = parsed.value.kind,
                .name = trace.findJsonStringValue(trimmed, "\"name\"") orelse
                    return error.InvalidTestFixture,
                .result_contains = trace.findJsonStringValue(trimmed, "\"resultContains\""),
                .payload_contains = trace.findJsonStringValue(trimmed, "\"payloadContains\""),
            });
        } else if (std.mem.eql(u8, type_str, "expect-queue")) {
            if (scenario == null or current_name == null or !current_expect_seen) {
                return error.InvalidTestFixture;
            }
            assertions_started = true;
            try parseStrictRow(ExpectedQueueRowWire, allocator, trimmed, "expect-queue");
            const run_key = trace.findJsonStringValue(trimmed, "\"runKey\"") orelse
                return error.InvalidTestFixture;
            const step = trace.findJsonStringValue(trimmed, "\"step\"") orelse
                return error.InvalidTestFixture;
            if (run_key.len == 0 or step.len == 0) return error.InvalidTestFixture;
            for (expected_queues.items) |expected| {
                if (std.mem.eql(u8, expected.run_key, run_key) and
                    std.mem.eql(u8, expected.step, step)) return error.InvalidTestFixture;
            }
            const status_value = trace.findJsonIntValue(trimmed, "\"status\"") orelse
                return error.InvalidTestFixture;
            const status = std.math.cast(u16, status_value) orelse return error.InvalidTestFixture;
            try expected_queues.append(allocator, .{
                .run_key = run_key,
                .step = step,
                .status = status,
                .body_contains = trace.findJsonStringValue(trimmed, "\"bodyContains\""),
            });
        } else if (std.mem.eql(u8, type_str, "expect-signals")) {
            if (scenario == null or current_name == null or !current_expect_seen or
                signal_artifact_count != null)
            {
                return error.InvalidTestFixture;
            }
            assertions_started = true;
            try parseStrictRow(ExpectedSignalsRowWire, allocator, trimmed, "expect-signals");
            const count_value = trace.findJsonIntValue(trimmed, "\"count\"") orelse
                return error.InvalidTestFixture;
            signal_artifact_count = std.math.cast(usize, count_value) orelse
                return error.InvalidTestFixture;
        } else {
            if (!builtin.is_test) {
                std.log.err("Invalid test fixture line {d}: unknown type \"{s}\"", .{ line_no, type_str });
            }
            return error.InvalidTestFixture;
        }
        saw_nonempty_row = true;
    }

    if (current_name != null) {
        if (scenario != null and (!current_request_seen or !current_expect_seen)) {
            return error.InvalidTestFixture;
        }
        try appendParsedTest(
            allocator,
            &tests,
            current_name.?,
            current_request,
            &current_io,
            current_assertions,
        );
    }

    if (scenario) |runtime_scenario| {
        if (!runtime_scenario.durable or tests.items.len == 0 or
            expected_runs.items.len == 0 or expected_events.items.len == 0)
        {
            return error.InvalidTestFixture;
        }
        if (runtime_scenario.workflow_queue != (expected_queues.items.len != 0)) {
            return error.InvalidTestFixture;
        }
        for (expected_events.items) |event| {
            var declared = false;
            for (expected_runs.items) |expected| {
                if (std.mem.eql(u8, expected.run_key, event.run_key)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) return error.InvalidTestFixture;
        }
        for (expected_queues.items) |queue| {
            var declared = false;
            for (expected_runs.items) |expected| {
                if (std.mem.eql(u8, expected.run_key, queue.run_key)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) return error.InvalidTestFixture;
        }
        for (expected_runs.items) |expected| {
            var event_count: usize = 0;
            for (expected_events.items) |event| {
                if (std.mem.eql(u8, expected.run_key, event.run_key)) event_count += 1;
            }
            if (event_count == 0) return error.InvalidTestFixture;
        }
    } else if (expected_runs.items.len != 0 or expected_events.items.len != 0 or
        expected_queues.items.len != 0 or signal_artifact_count != null)
    {
        return error.InvalidTestFixture;
    }

    return .{
        .tests = try tests.toOwnedSlice(allocator),
        .scenario = scenario,
        .runtime_assertions = .{
            .runs = try expected_runs.toOwnedSlice(allocator),
            .events = try expected_events.toOwnedSlice(allocator),
            .queues = try expected_queues.toOwnedSlice(allocator),
            .signal_artifact_count = signal_artifact_count,
        },
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return zq.file_io.readFile(allocator, path, 100 * 1024 * 1024);
}

// ============================================================================
// Tests
// ============================================================================

test "parseTestFile: empty input" {
    var suite = try parseTestFile(std.testing.allocator, "");
    defer suite.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), suite.tests.len);
}

test "parseTestFile: invalid non-empty row fails" {
    try std.testing.expectError(error.InvalidTestFixture, parseTestFile(std.testing.allocator, "not json"));
    try std.testing.expectError(error.InvalidTestFixture, parseTestFile(std.testing.allocator, "{\"type\":\"bogus\"}"));
}

test "parseTestFile: single test with status assertion" {
    const source =
        \\{"type":"test","name":"health check"}
        \\{"type":"request","method":"GET","url":"/health","headers":{},"body":null}
        \\{"type":"expect","status":200}
    ;
    var suite = try parseTestFile(std.testing.allocator, source);
    defer suite.deinit(std.testing.allocator);
    const tests = suite.tests;

    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqualStrings("health check", tests[0].name);
    try std.testing.expectEqualStrings("GET", tests[0].request.?.method);
    try std.testing.expectEqualStrings("/health", tests[0].request.?.url);
    try std.testing.expectEqual(@as(u16, 200), tests[0].assertions.status.?);
}

test "parseTestFile: multiple tests" {
    const source =
        \\{"type":"test","name":"first"}
        \\{"type":"request","method":"GET","url":"/a","headers":{},"body":null}
        \\{"type":"expect","status":200}
        \\{"type":"test","name":"second"}
        \\{"type":"request","method":"POST","url":"/b","headers":{},"body":null}
        \\{"type":"expect","status":404}
    ;
    var suite = try parseTestFile(std.testing.allocator, source);
    defer suite.deinit(std.testing.allocator);
    const tests = suite.tests;

    try std.testing.expectEqual(@as(usize, 2), tests.len);
    try std.testing.expectEqualStrings("first", tests[0].name);
    try std.testing.expectEqualStrings("second", tests[1].name);
    try std.testing.expectEqual(@as(u16, 404), tests[1].assertions.status.?);
}

test "parseTestFile: test with io stubs" {
    const source =
        \\{"type":"test","name":"with io"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"io","seq":0,"module":"env","fn":"env","args":["KEY"],"result":"val"}
        \\{"type":"io","seq":1,"module":"crypto","fn":"sha256","args":["x"],"result":"abc"}
        \\{"type":"expect","status":200}
    ;
    var suite = try parseTestFile(std.testing.allocator, source);
    defer suite.deinit(std.testing.allocator);
    const tests = suite.tests;

    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqual(@as(usize, 2), tests[0].io_calls.len);
    try std.testing.expectEqualStrings("env", tests[0].io_calls[0].module);
    try std.testing.expectEqualStrings("crypto", tests[0].io_calls[1].module);
}

test "parseTestFile: bodyContains assertion" {
    const source =
        \\{"type":"test","name":"contains"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":200,"bodyContains":"hello"}
    ;
    var suite = try parseTestFile(std.testing.allocator, source);
    defer suite.deinit(std.testing.allocator);
    const tests = suite.tests;

    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqualStrings("hello", tests[0].assertions.body_contains.?);
}

test "parseTestFile: strict runtime scenario owns durable evidence" {
    const source =
        \\{"type":"runtime","durable":true,"workflowQueue":false}
        \\{"type":"test","name":"durable order"}
        \\{"type":"request","method":"POST","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":201,"bodyContains":"charged"}
        \\{"type":"expect-run","runKey":"order-1","complete":true}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"reserve"}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"reserve","resultContains":"reserved"}
        \\{"type":"expect-signals","count":0}
    ;
    var suite = try parseTestFile(std.testing.allocator, source);
    defer suite.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), suite.tests.len);
    try std.testing.expect(suite.scenario.?.durable);
    try std.testing.expect(!suite.scenario.?.workflow_queue);
    try std.testing.expectEqual(@as(usize, 1), suite.runtime_assertions.runs.len);
    try std.testing.expectEqual(@as(usize, 2), suite.runtime_assertions.events.len);
    try std.testing.expectEqual(@as(?usize, 0), suite.runtime_assertions.signal_artifact_count);
}

test "parseTestFile: runtime scenarios fail closed" {
    const invalid_fixtures = [_][]const u8{
        // Runtime configuration must be the first row and appear once.
        "{\"type\":\"test\",\"name\":\"late\"}\n" ++
            "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n",
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n" ++
            "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n",
        // A scenario that exercises nothing cannot report success.
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n",
        // Requests and response assertions are exactly one per scenario test.
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n" ++
            "{\"type\":\"test\",\"name\":\"duplicate request\"}\n" ++
            "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
            "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n",
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n" ++
            "{\"type\":\"test\",\"name\":\"missing expect\"}\n" ++
            "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n",
        // A queue scenario must declare queue evidence, and non-queue
        // scenarios must not smuggle a queue assertion into the fixture.
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":true}\n" ++
            "{\"type\":\"test\",\"name\":\"queue\"}\n" ++
            "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
            "{\"type\":\"expect\",\"status\":200}\n" ++
            "{\"type\":\"expect-run\",\"runKey\":\"q\",\"complete\":true}\n" ++
            "{\"type\":\"expect-event\",\"runKey\":\"q\",\"kind\":\"step_start\",\"name\":\"workflow.call#0\"}\n",
        // Assertion rows must resolve to exactly one declared run.
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false}\n" ++
            "{\"type\":\"test\",\"name\":\"unknown run\"}\n" ++
            "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
            "{\"type\":\"expect\",\"status\":200}\n" ++
            "{\"type\":\"expect-run\",\"runKey\":\"known\",\"complete\":true}\n" ++
            "{\"type\":\"expect-event\",\"runKey\":\"unknown\",\"kind\":\"step_start\",\"name\":\"s\"}\n",
        // Strict rows reject extra and duplicate fields.
        "{\"type\":\"runtime\",\"durable\":true,\"workflowQueue\":false,\"extra\":1}\n",
        "{\"type\":\"runtime\",\"durable\":true,\"durable\":true,\"workflowQueue\":false}\n",
    };

    for (invalid_fixtures) |fixture| {
        try std.testing.expectError(
            error.InvalidTestFixture,
            parseTestFile(std.testing.allocator, fixture),
        );
    }
}

test "strict durable scenario scan rejects malformed evidence" {
    const valid =
        "{\"type\":\"durable_run\",\"key\":\"run-1\"}\n" ++
        "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
        "{\"type\":\"step_start\",\"name\":\"s\"}\n" ++
        "{\"type\":\"step_result\",\"name\":\"s\",\"result\":{\"ok\":true}}\n" ++
        "{\"type\":\"response\",\"status\":200,\"headers\":{},\"body\":\"ok\"}\n" ++
        "{\"type\":\"complete\"}\n";
    const counts = try scanStrictDurableOplog(std.testing.allocator, valid, "run-1");
    try std.testing.expectEqual(@as(usize, 1), counts.run);
    try std.testing.expectEqual(@as(usize, 1), counts.request);
    try std.testing.expectEqual(@as(usize, 1), counts.response);
    try std.testing.expectEqual(@as(usize, 1), counts.complete);

    try std.testing.expectError(
        error.InvalidScenarioDurableLog,
        scanStrictDurableOplog(std.testing.allocator, valid[0 .. valid.len - 1], "run-1"),
    );
    try std.testing.expectError(
        error.InvalidScenarioDurableLog,
        scanStrictDurableOplog(
            std.testing.allocator,
            "{\"type\":\"step_result\",\"name\":\"s\"}\n",
            "run-1",
        ),
    );
    try std.testing.expectError(
        error.InvalidScenarioDurableLog,
        scanStrictDurableOplog(
            std.testing.allocator,
            "{\"type\":\"invented\",\"name\":\"s\"}\n",
            "run-1",
        ),
    );
    try std.testing.expectError(
        error.InvalidScenarioDurableLog,
        scanStrictDurableOplog(
            std.testing.allocator,
            "{\"type\":\"durable_run\",\"key\":\"run-1\",\"extra\":true}\n",
            "run-1",
        ),
    );
    try std.testing.expectError(
        error.InvalidScenarioDurableLog,
        scanStrictDurableOplog(
            std.testing.allocator,
            "{\"type\":\"durable_run\",\"key\":\"run-1\",\"key\":\"run-1\"}\n",
            "run-1",
        ),
    );
}

test "checkAssertions: status match passes" {
    const assertions = TestAssertions{ .status = 200 };
    var response = HttpResponse.init(std.testing.allocator);
    response.status = 200;
    var failures: std.ArrayList([]const u8) = .empty;
    checkAssertions(std.testing.allocator, &response, &assertions, &failures);
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
}

test "checkAssertions: status mismatch fails" {
    const assertions = TestAssertions{ .status = 404 };
    var response = HttpResponse.init(std.testing.allocator);
    response.status = 200;
    var failures: std.ArrayList([]const u8) = .empty;
    checkAssertions(std.testing.allocator, &response, &assertions, &failures);
    defer {
        for (failures.items) |msg| std.testing.allocator.free(msg);
        failures.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
    try std.testing.expect(std.mem.indexOf(u8, failures.items[0], "expected status: 404") != null);
}

test "checkAssertions: bodyContains match passes" {
    const assertions = TestAssertions{ .body_contains = "world" };
    var response = HttpResponse.init(std.testing.allocator);
    response.body = "{\"greeting\":\"hello world\"}";
    var failures: std.ArrayList([]const u8) = .empty;
    checkAssertions(std.testing.allocator, &response, &assertions, &failures);
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
}

test "checkAssertions: bodyContains mismatch fails" {
    const assertions = TestAssertions{ .body_contains = "missing" };
    var response = HttpResponse.init(std.testing.allocator);
    response.body = "{\"greeting\":\"hello\"}";
    var failures: std.ArrayList([]const u8) = .empty;
    checkAssertions(std.testing.allocator, &response, &assertions, &failures);
    defer {
        for (failures.items) |msg| std.testing.allocator.free(msg);
        failures.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
    try std.testing.expect(std.mem.indexOf(u8, failures.items[0], "body does not contain") != null);
}

test "run: actor queue flag installs queue runtime for declarative tests" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(io, .{
        .sub_path = "queue.test.jsonl",
        .data =
        \\{"type":"test","name":"queue"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":200,"bodyContains":"queued"}
        ,
    });

    const handler_code =
        \\import { send, receive, ack } from "zttp:queue";
        \\function handler(req) {
        \\  const sent = send("worker", { ok: true });
        \\  if (!sent.ok) return Response.text(sent.error, { status: 500 });
        \\  const empty = receive("empty");
        \\  if (!empty.ok) return Response.text(empty.error, { status: 500 });
        \\  if (empty.value !== null) return Response.text("expected empty mailbox", { status: 500 });
        \\  const inbox = receive("worker");
        \\  if (!inbox.ok) return Response.text(inbox.error, { status: 500 });
        \\  const done = ack(inbox.value.id);
        \\  return Response.text(done.ok && inbox.value.payload.ok ? "queued" : "bad");
        \\}
    ;

    try run(testing.allocator, .{
        .handler = .{ .inline_code = handler_code },
        .runtime_config = .{
            .test_file_path = "queue.test.jsonl",
            .queue_actor_enabled = true,
            .queue_capacity = 2,
        },
    });
}

test "run: runtime scenario proves durable steps end to end" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(io, .{
        .sub_path = "durable.test.jsonl",
        .data =
        \\{"type":"runtime","durable":true,"workflowQueue":false}
        \\{"type":"test","name":"durable backend"}
        \\{"type":"request","method":"POST","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":201,"bodyContains":"charged"}
        \\{"type":"expect-run","runKey":"order-1","complete":true}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"reserve"}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"reserve","resultContains":"reserved"}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"charge"}
        \\{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"charge","resultContains":"charged"}
        ,
    });

    const handler_code =
        \\import { run, step } from "zttp:durable";
        \\function handler(req) {
        \\  return run("order-1", () => {
        \\    const reserved = step("reserve", () => ({ reserved: true }));
        \\    const charged = step("charge", () => ({ charged: reserved.reserved }));
        \\    return Response.json(charged, { status: 201 });
        \\  });
        \\}
    ;

    try run(testing.allocator, .{
        .handler = .{ .inline_code = handler_code },
        .runtime_config = .{ .test_file_path = "durable.test.jsonl" },
    });
}

test "runOneTest: request url with query string yields path without query (CLI-1 scaffold)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Handler matches req.path === "/" (mirrors the default `zttp init` basic scaffold).
    const handler_code =
        \\function handler(req) {
        \\  if (req.method === "GET" && req.path === "/") {
        \\    return Response.text("Hello,");
        \\  }
        \\  return Response.text("Not Found", { status: 404 });
        \\}
    ;

    // Mirror run(): replay sentinel installs stub modules, arena escape off.
    const config = RuntimeConfig{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    };

    // The scaffold fixture sends GET /?probe=1; before the fix req.path became
    // "/?probe=1" and the handler returned 404.
    const test_case = TestCase{
        .name = "scaffold probe",
        .request = .{
            .method = "GET",
            .url = "/?probe=1",
            .headers_json = "{}",
            .body = null,
        },
        .assertions = .{ .status = 200 },
    };

    const result = runOneTest(allocator, config, handler_code, "<scaffold>", &test_case, .{});
    defer result.deinitFailures(allocator);

    try std.testing.expect(result.err == null);
    try std.testing.expect(result.pass);
}

test "runOneTest: req.query is populated from the url query string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Echo a query param back. Mirrors the weather app, which reads
    // req.query.latitude/longitude. Without query_params plumbed into the test
    // request, req.query would be empty and this would 400.
    const handler_code =
        \\function handler(req) {
        \\  const lat = req.query.latitude;
        \\  if (lat === undefined) {
        \\    return Response.text("missing", { status: 400 });
        \\  }
        \\  return Response.text(["lat=", lat].join(""));
        \\}
    ;

    const config = RuntimeConfig{
        .replay_file_path = "test",
        .enforce_arena_escape = false,
    };

    const test_case = TestCase{
        .name = "query echo",
        .request = .{
            .method = "GET",
            .url = "/forecast?latitude=48.85&longitude=2.35",
            .headers_json = "{}",
            .body = null,
        },
        .assertions = .{ .status = 200, .body_contains = "lat=48.85" },
    };

    const result = runOneTest(allocator, config, handler_code, "<query>", &test_case, .{});
    defer result.deinitFailures(allocator);

    try std.testing.expect(result.err == null);
    try std.testing.expect(result.pass);
}
