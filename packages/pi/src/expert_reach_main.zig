//! Command runner for the bounded, reference-backed provable-set reach measure.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const agent = @import("agent.zig");
const app = @import("app.zig");
const corpus = @import("expert_reach_corpus.zig");
const reach = @import("expert_reach.zig");
const report = @import("expert_reach_report.zig");
const loop = @import("loop.zig");
const model_request = @import("providers/model_request.zig");
const models = @import("providers/models.zig");
const capture_sink = @import("providers/capture_sink.zig");
const cassette_record = @import("providers/cassette_record.zig");
const flow_artifact = @import("simulator/artifact.zig");
const transcript_mod = @import("transcript.zig");
const turn = @import("turn.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const common = @import("tools/common.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;

pub const Mode = enum { references, smoke, live };

pub const Command = struct {
    mode: Mode,
    output: []const u8,
    limit: usize = report.full_task_count,
    confirm_live: bool = false,
};

const task_timeout_ms: u64 = 600_000;
const max_roundtrips: u32 = 18;
const max_tool_calls: u32 = 16;
const max_verification_attempts: u32 = 5;
const expected_provider: models.Provider = .deepseek;
const expected_model = "deepseek-v4-flash";

pub fn parseCommand(args: []const []const u8) !Command {
    var mode: ?Mode = null;
    var output: ?[]const u8 = null;
    var limit: usize = report.full_task_count;
    var limit_seen = false;
    var confirm_live = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--references")) {
            if (mode != null) return error.ConflictingModes;
            mode = .references;
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            if (mode != null) return error.ConflictingModes;
            mode = .smoke;
        } else if (std.mem.eql(u8, arg, "--live")) {
            if (mode != null) return error.ConflictingModes;
            mode = .live;
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (output != null) return error.DuplicateOutput;
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingOutput;
            output = args[index];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            if (limit_seen) return error.DuplicateLimit;
            limit_seen = true;
            index += 1;
            if (index >= args.len) return error.InvalidLimit;
            limit = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidLimit;
            if (limit != 1 and limit != report.full_task_count) return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--confirm-live")) {
            if (confirm_live) return error.DuplicateLiveConfirmation;
            confirm_live = true;
        } else {
            return error.UnknownArgument;
        }
    }
    const selected_mode = mode orelse return error.MissingMode;
    if (selected_mode == .live and !confirm_live) return error.LiveConfirmationRequired;
    if (selected_mode != .live and confirm_live) return error.LiveConfirmationWithoutLive;
    return .{
        .mode = selected_mode,
        .output = output orelse return error.MissingOutput,
        .limit = limit,
        .confirm_live = confirm_live,
    };
}

const SourceSnapshot = struct {
    revision: []const u8,
    known: bool,
    clean: bool,
    status_hash: []const u8,

    fn asReport(self: SourceSnapshot) report.SourceIdentity {
        return .{ .revision = self.revision, .known = self.known, .clean = self.clean };
    }
};

fn isLowerHex(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn readSourceSnapshot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !SourceSnapshot {
    var head = common.runCommand(allocator, repo_root, &.{ "git", "rev-parse", "HEAD" }) catch
        return unknownSource(allocator);
    defer head.deinit(allocator);
    const commit = std.mem.trim(u8, head.stdout, " \t\r\n");
    if (!head.ok or commit.len != 40 or !isLowerHex(commit)) return unknownSource(allocator);

    var status = common.runCommand(
        allocator,
        repo_root,
        &.{ "git", "status", "--porcelain=v1", "--untracked-files=normal" },
    ) catch return unknownSource(allocator);
    defer status.deinit(allocator);
    if (!status.ok) return unknownSource(allocator);
    return .{
        .revision = try allocator.dupe(u8, commit),
        .known = true,
        .clean = std.mem.trim(u8, status.stdout, " \t\r\n").len == 0,
        .status_hash = try reach.digest(allocator, "reach-source-status-v1", status.stdout),
    };
}

fn unknownSource(allocator: std.mem.Allocator) !SourceSnapshot {
    return .{
        .revision = "unknown",
        .known = false,
        .clean = false,
        .status_hash = try reach.digest(allocator, "reach-source-status-v1", "unknown"),
    };
}

fn sameSource(left: SourceSnapshot, right: SourceSnapshot) bool {
    return left.known == right.known and left.clean == right.clean and
        std.mem.eql(u8, left.revision, right.revision) and
        std.mem.eql(u8, left.status_hash, right.status_hash);
}

fn createOutput(allocator: std.mem.Allocator, output_abs: []const u8) !void {
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    const parent = std.fs.path.dirname(output_abs) orelse return error.InvalidOutputPath;
    var parent_dir = try std.Io.Dir.openDirAbsolute(backend.io(), parent, .{});
    defer parent_dir.close(backend.io());
    parent_dir.createDir(backend.io(), std.fs.path.basename(output_abs), .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.OutputAlreadyExists,
        else => return err,
    };
}

fn writeArtifact(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    relative: []const u8,
    bytes: []const u8,
) !void {
    try reach.writeFiles(allocator, output_root, &.{.{ .path = relative, .bytes = bytes }});
}

fn writeJson(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    relative: []const u8,
    value: anytype,
) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try writeArtifact(allocator, output_root, relative, bytes);
}

fn retainTaskDefinitions(allocator: std.mem.Allocator, output_root: []const u8) !void {
    for (corpus.tasks) |task| {
        const path = try std.fmt.allocPrint(allocator, "tasks/{s}.json", .{task.id});
        defer allocator.free(path);
        try writeJson(allocator, output_root, path, task);
    }
}

fn suiteHash(
    allocator: std.mem.Allocator,
    selected: []const report.ExpectedCase,
) ![]const u8 {
    const StableCase = struct {
        id: []const u8,
        family: []const u8,
        mode: report.InputMode,
        input_hash: []const u8,
        reference_hash: []const u8,
        intent_hash: []const u8,
    };
    const stable = try allocator.alloc(StableCase, selected.len);
    for (selected, 0..) |case, index| stable[index] = .{
        .id = case.id,
        .family = case.family,
        .mode = case.mode,
        .input_hash = case.input_hash,
        .reference_hash = case.reference_hash,
        .intent_hash = case.intent_hash,
    };
    return reach.digest(allocator, "reach-suite-v1", stable);
}

fn compilerIdentity(allocator: std.mem.Allocator) !report.CompilerIdentity {
    const policy_hash = zts.policyHash();
    const grammar_hash = zts.grammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostic_hash = zts.diagnosticCatalogHash();
    return .{
        .version = zts_cli.expert_meta.compiler_version,
        .policy_hash = try allocator.dupe(u8, &policy_hash),
        .grammar_hash = try allocator.dupe(u8, &grammar_hash),
        .semantics_hash = try allocator.dupe(u8, &semantics_hash),
        .diagnostic_hash = try allocator.dupe(u8, &diagnostic_hash),
    };
}

fn requestConfigForSession(session: *const agent.AgentSession) !model_request.Config {
    return switch (session.backend) {
        .deepseek => |client| .{
            .provider = .deepseek,
            .model = client.config.model,
            .max_output_tokens = client.config.max_tokens,
            .stream = false,
            .system_prompt = client.config.system_prompt,
            .tools_json = client.config.tools_json,
            .reserve_tokens = client.config.reserve_tokens,
            .purpose = client.config.purpose,
            .cache_policy = client.config.cache_policy,
        },
        else => error.UnexpectedReachProvider,
    };
}

fn modelIdentity(
    allocator: std.mem.Allocator,
    config: model_request.Config,
) !report.ModelIdentity {
    const persona_hash = try reach.digest(allocator, "reach-model-persona-v1", config.system_prompt);
    const tool_catalog_hash = try reach.digest(
        allocator,
        "reach-model-tools-v1",
        config.tools_json orelse return error.EmptyReachToolCatalog,
    );
    const context_hash = try reach.digest(allocator, "reach-model-context-v1", .{
        .provider = config.provider,
        .model = config.model,
        .max_output_tokens = config.max_output_tokens,
        .reserve_tokens = config.reserve_tokens,
        .stream = config.stream,
        .purpose = config.purpose,
        .cache_policy = config.cache_policy,
        .persona_hash = persona_hash,
        .tool_catalog_hash = tool_catalog_hash,
    });
    return .{
        .provider = config.provider.publicName(),
        .model = try allocator.dupe(u8, config.model),
        .request_policy = .{
            .max_output_tokens = config.max_output_tokens,
            .reserve_tokens = config.reserve_tokens,
            .stream = config.stream,
            .purpose = @tagName(config.purpose),
            .cache_policy = @tagName(config.cache_policy),
        },
        .context_hash = context_hash,
        .persona_hash = persona_hash,
        .tool_catalog_hash = tool_catalog_hash,
    };
}

fn modelIdentityEql(left: report.ModelIdentity, right: report.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.model, right.model) and
        left.request_policy.max_output_tokens == right.request_policy.max_output_tokens and
        left.request_policy.reserve_tokens == right.request_policy.reserve_tokens and
        left.request_policy.stream == right.request_policy.stream and
        std.mem.eql(u8, left.request_policy.purpose, right.request_policy.purpose) and
        std.mem.eql(u8, left.request_policy.cache_policy, right.request_policy.cache_policy) and
        std.mem.eql(u8, left.context_hash, right.context_hash) and
        std.mem.eql(u8, left.persona_hash, right.persona_hash) and
        std.mem.eql(u8, left.tool_catalog_hash, right.tool_catalog_hash);
}

fn initLiveSession(
    allocator: std.mem.Allocator,
    registry: *const @import("registry/registry.zig").Registry,
) !agent.AgentSession {
    var session = try agent.initFromEnvWithSessionConfig(allocator, registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = expected_provider,
        .model = expected_model,
    });
    errdefer session.deinit(allocator);
    if (session.activeProvider() != expected_provider or
        !std.mem.eql(u8, session.currentModel() orelse "", expected_model))
    {
        return error.UnexpectedReachProvider;
    }
    return session;
}

const ScriptedClient = struct {
    task: *const corpus.Task,

    fn requestFn(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        _ = transcript;
        _ = extra_user_text;
        const self: *ScriptedClient = @ptrCast(@alignCast(context));
        _ = allocator;
        const handler = for (self.task.reference_files) |file| {
            if (std.mem.eql(u8, file.path, self.task.intent.handler_path)) break file;
        } else return error.MissingReferenceHandler;
        return .{ .reply = .{ .response = .{ .change_set = .{
            .file = handler.path,
            .content = handler.bytes,
        } } } };
    }

    fn asModelClient(self: *ScriptedClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const CountingClient = struct {
    inner: loop.ModelClient,
    requests: u32 = 0,

    fn requestFn(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *CountingClient = @ptrCast(@alignCast(context));
        self.requests +|= 1;
        return self.inner.request(allocator, transcript, extra_user_text);
    }

    fn setDeadlineFn(context: *anyopaque, deadline_ms: ?i64) void {
        const self: *CountingClient = @ptrCast(@alignCast(context));
        self.inner.setDeadline(deadline_ms);
    }

    fn asModelClient(self: *CountingClient) loop.ModelClient {
        return .{
            .context = self,
            .request_fn = requestFn,
            .set_deadline_fn = setDeadlineFn,
        };
    }
};

const LiveCapture = struct {
    allocator: std.mem.Allocator,
    case_dir: []const u8,
    task_id: []const u8,
    exchange_hashes: std.ArrayList([]const u8) = .empty,
    provider_attempts: usize = 0,
    diagnostic_write_failed: bool = false,
    diagnostic_error_name: ?[]const u8 = null,

    fn deinit(self: *LiveCapture) void {
        self.exchange_hashes.deinit(self.allocator);
    }

    fn record(
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void {
        const self: *LiveCapture = @ptrCast(@alignCast(context));
        const path = try std.fmt.allocPrint(self.allocator, "{s}/provider/step_{d}.jsonl", .{ self.case_dir, call_index });
        defer self.allocator.free(path);
        try cassette_record.writeCassette(self.allocator, path, raw_response, .{
            .provider = .deepseek,
            .scenario = self.task_id,
            .stream = snapshot.config.stream,
            .model = snapshot.config.model,
            .request_sha256 = if (snapshot.wire_request_sha256) |digest| digest.slice() else null,
        });
        try self.exchange_hashes.append(
            self.allocator,
            try reach.digest(self.allocator, "reach-provider-exchange-v1", .{
                .call_index = call_index,
                .request_context_sha256 = snapshot.request_context_sha256.slice(),
                .wire_request_sha256 = if (snapshot.wire_request_sha256) |digest| digest.slice() else null,
                .raw_response = raw_response,
            }),
        );
    }

    fn diagnostics(
        context: *anyopaque,
        attempt_index: usize,
        diagnostic_context: capture_sink.ResponseDiagnosticContext,
        observation: capture_sink.ResponseDiagnostics,
    ) anyerror!void {
        const self: *LiveCapture = @ptrCast(@alignCast(context));
        self.provider_attempts = @max(self.provider_attempts, attempt_index + 1);
        self.writeDiagnostics(attempt_index, diagnostic_context, observation) catch |err| {
            self.diagnostic_write_failed = true;
            self.diagnostic_error_name = @errorName(err);
            return err;
        };
    }

    fn writeDiagnostics(
        self: *LiveCapture,
        attempt_index: usize,
        diagnostic_context: capture_sink.ResponseDiagnosticContext,
        observation: capture_sink.ResponseDiagnostics,
    ) !void {
        const warnings = try self.allocator.alloc([]const u8, observation.parser_warnings.len);
        defer self.allocator.free(warnings);
        for (observation.parser_warnings, 0..) |warning, index| warnings[index] = @tagName(warning);
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{
            .attempt_index = attempt_index,
            .provider = @tagName(diagnostic_context.provider),
            .model = diagnostic_context.model,
            .latency_ms = observation.latency_ms,
            .http_status = observation.http_status,
            .finish_reason = if (observation.finish_reason) |reason| @tagName(reason) else null,
            .completion_tokens = observation.completion_tokens,
            .field_presence = observation.field_presence,
            .parser_warnings = warnings,
            .failure = if (observation.failure) |failure| @errorName(failure) else null,
            .change_set_rejection = if (observation.change_set_rejection) |shape| @tagName(shape) else null,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/provider/attempt_{d}.json",
            .{ self.case_dir, attempt_index },
        );
        defer self.allocator.free(path);
        try zts.file_io.writeFile(self.allocator, path, bytes);
    }

    fn sink(self: *LiveCapture) capture_sink.CaptureSink {
        return .{
            .context = self,
            .record_fn = record,
            .diagnostics_fn = diagnostics,
        };
    }
};

fn setSessionCapture(session: *agent.AgentSession, sink: ?*capture_sink.CaptureSink) !void {
    switch (session.backend) {
        .deepseek => |*client| client.capture = sink,
        else => return error.UnexpectedReachProvider,
    }
}

fn renderTranscript(allocator: std.mem.Allocator, transcript: *const transcript_mod.Transcript) ![]u8 {
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    for (transcript.entries.items) |*entry| try transcript_mod.renderPlain(buffer.writer(), entry);
    return buffer.toOwnedSlice();
}

fn countTranscriptTools(transcript: *const transcript_mod.Transcript) u32 {
    var count: u32 = 0;
    for (transcript.entries.items) |entry| switch (entry) {
        .assistant_tool_use => |calls| count +|= @intCast(calls.len),
        else => {},
    };
    return count;
}

fn countVerificationAttempts(transcript: *const transcript_mod.Transcript) u32 {
    var count: u32 = 0;
    for (transcript.entries.items) |entry| switch (entry) {
        .assistant_tool_use => |calls| for (calls) |call| {
            if (std.mem.eql(u8, call.name, "propose_change_set")) count +|= 1;
        },
        else => {},
    };
    return count;
}

fn elapsedMs(started_ns: u64) u64 {
    const finished_ns = zts.monotonicNowNs() catch started_ns;
    if (finished_ns <= started_ns) return 0;
    return (finished_ns - started_ns) / std.time.ns_per_ms;
}

fn classifyTurnError(err: anyerror) report.Outcome {
    return switch (err) {
        error.EmptyResponse => .empty_response,
        error.RequestTimedOut, error.DeepSeekGenerationStalled => .timeout,
        error.InvalidResponseJson,
        error.MalformedToolCall,
        error.MalformedToolEnvelope,
        error.UnexpectedResponseShape,
        error.InvalidChangeSetArgs,
        error.OutputTruncated,
        error.MalformedSse,
        error.MissingType,
        error.UnknownEventType,
        error.UnexpectedJsonShape,
        error.TooManyToolCalls,
        => .decode_error,
        error.AuthFailed,
        error.InsufficientCredit,
        error.RateLimited,
        error.ModelNotFound,
        error.ProviderOverloaded,
        error.ProviderServerError,
        error.ApiError,
        error.DeepSeekServerUnavailable,
        error.RequestTooLarge,
        error.ResponseTooLarge,
        => .provider_error,
        else => .internal_error,
    };
}

const WorkspaceRecord = struct {
    path: []const u8,
    present: bool,
    hash: ?[]const u8,
};

fn alreadyNamed(files: []const WorkspaceRecord, path: []const u8) bool {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return true;
    return false;
}

fn retainWorkspace(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    case_relative: []const u8,
    workspace_abs: []const u8,
    task: corpus.Task,
) ![]const WorkspaceRecord {
    var records: std.ArrayList(WorkspaceRecord) = .empty;
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    const io = backend.io();
    var root = try std.Io.Dir.openDirAbsolute(io, workspace_abs, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory or flow_artifact.isAgentScratch(entry.path)) continue;
        if (!isSourcePath(entry.path)) continue;
        if (entry.kind != .file or !flow_artifact.isSafeRelativePath(entry.path)) {
            return error.UnsafeReachWorkspacePath;
        }
        if (paths.items.len >= flow_artifact.Limits.files) return error.ReachWorkspaceFileLimitExceeded;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);
    var total_bytes: usize = 0;
    for (paths.items) |path| try retainWorkspaceFile(
        allocator,
        output_root,
        case_relative,
        workspace_abs,
        path,
        &records,
        &total_bytes,
    );
    for (task.seed_files) |file| {
        if (alreadyNamed(records.items, file.path)) continue;
        try records.append(allocator, .{ .path = file.path, .present = false, .hash = null });
    }
    for (task.reference_files) |file| {
        if (alreadyNamed(records.items, file.path)) continue;
        try records.append(allocator, .{ .path = file.path, .present = false, .hash = null });
    }
    std.mem.sort(WorkspaceRecord, records.items, {}, lessThanWorkspaceRecord);
    const owned = try records.toOwnedSlice(allocator);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/workspace.json", .{case_relative});
    defer allocator.free(manifest_path);
    try writeJson(allocator, output_root, manifest_path, owned);
    return owned;
}

fn retainWorkspaceFile(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    case_relative: []const u8,
    workspace_abs: []const u8,
    relative: []const u8,
    records: *std.ArrayList(WorkspaceRecord),
    total_bytes: *usize,
) !void {
    const source = try common.resolveInsideWorkspace(allocator, workspace_abs, relative);
    defer allocator.free(source);
    const bytes = zts.file_io.readFile(allocator, source, flow_artifact.Limits.workspace_file_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try records.append(allocator, .{ .path = relative, .present = false, .hash = null });
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    total_bytes.* = std.math.add(usize, total_bytes.*, bytes.len) catch
        return error.ReachWorkspaceByteLimitExceeded;
    if (total_bytes.* > flow_artifact.Limits.case_bytes) return error.ReachWorkspaceByteLimitExceeded;
    const destination = try std.fmt.allocPrint(allocator, "{s}/workspace/{s}", .{ case_relative, relative });
    defer allocator.free(destination);
    try writeArtifact(allocator, output_root, destination, bytes);
    try records.append(allocator, .{
        .path = relative,
        .present = true,
        .hash = try reach.digest(allocator, "reach-workspace-file-v1", bytes),
    });
}

fn isSourcePath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    inline for (&.{ ".ts", ".tsx", ".js", ".jsx", ".json" }) |expected| {
        if (std.mem.eql(u8, extension, expected)) return true;
    }
    return false;
}

fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessThanWorkspaceRecord(_: void, left: WorkspaceRecord, right: WorkspaceRecord) bool {
    return lessThanPath({}, left.path, right.path);
}

fn candidateHash(
    allocator: std.mem.Allocator,
    workspace: []const WorkspaceRecord,
    task: corpus.Task,
) !?[]const u8 {
    var handler_present = false;
    var present: std.ArrayList(WorkspaceRecord) = .empty;
    defer present.deinit(allocator);
    for (workspace) |actual| {
        if (!actual.present) continue;
        try present.append(allocator, actual);
        if (std.mem.eql(u8, actual.path, task.intent.handler_path)) handler_present = true;
    }
    if (!handler_present) return null;
    return try reach.digest(allocator, "reach-candidate-source-v1", present.items);
}

fn fixedSeedsUnchanged(
    allocator: std.mem.Allocator,
    workspace_abs: []const u8,
    task: corpus.Task,
) !bool {
    for (task.seed_files) |seed| {
        if (std.mem.eql(u8, seed.path, task.intent.handler_path)) continue;
        const path = try common.resolveInsideWorkspace(allocator, workspace_abs, seed.path);
        defer allocator.free(path);
        const actual = zts.file_io.readFile(allocator, path, flow_artifact.Limits.workspace_file_bytes) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, seed.bytes)) return false;
    }
    return true;
}

const TurnObservation = struct {
    result: ?loop.TurnResult,
    error_name: ?[]const u8,
    error_outcome: ?report.Outcome,
    requests: u32,
};

fn runTurnInWorkspace(
    allocator: std.mem.Allocator,
    registry: *const @import("registry/registry.zig").Registry,
    transcript: *transcript_mod.Transcript,
    client: loop.ModelClient,
    task: corpus.Task,
    workspace_abs: []const u8,
) !TurnObservation {
    const saved_cwd = try common.realCwd(allocator);
    defer allocator.free(saved_cwd);
    var counted: CountingClient = .{ .inner = client };
    try std.Io.Threaded.chdir(workspace_abs);
    const attempted = loop.runTurnWith(
        allocator,
        counted.asModelClient(),
        registry,
        transcript,
        task.prompt,
        .{
            .workspace_root = workspace_abs,
            .max_attempts = @intCast(max_verification_attempts),
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .max_model_roundtrips_per_turn = @intCast(max_roundtrips),
            .max_tool_calls_per_turn = max_tool_calls,
            .replay_mode = false,
            .turn_timeout_ms = task_timeout_ms,
        },
    );
    try std.Io.Threaded.chdir(saved_cwd);
    if (attempted) |result| {
        return .{ .result = result, .error_name = null, .error_outcome = null, .requests = counted.requests };
    } else |err| {
        return .{
            .result = null,
            .error_name = try allocator.dupe(u8, @errorName(err)),
            .error_outcome = classifyTurnError(err),
            .requests = counted.requests,
        };
    }
}

fn endReasonWithinBudget(result: loop.TurnResult) bool {
    return switch (result.end_reason) {
        .budget_roundtrips, .budget_tool_calls, .budget_timeout => false,
        else => true,
    };
}

const CaseProgress = struct {
    wall_clock_ms: u64,
    roundtrips: u32,
    tool_calls: u32,
    verification_attempts: u32,
    within_budget: bool,
};

fn observeCaseProgress(
    started_ns: u64,
    observation: TurnObservation,
    transcript: *const transcript_mod.Transcript,
) CaseProgress {
    const wall_clock_ms = elapsedMs(started_ns);
    const result = observation.result;
    const roundtrips: u32 = if (result) |value| value.roundtrips else observation.requests;
    const tool_calls: u32 = if (result) |value| value.tool_call_count else countTranscriptTools(transcript);
    const transcript_verifications = countVerificationAttempts(transcript);
    const verification_attempts: u32 = if (result) |value|
        if (value.applied_change_set or value.end_reason == .veto_exhausted)
            @max(transcript_verifications, value.attempt)
        else
            transcript_verifications
    else
        transcript_verifications;
    return .{
        .wall_clock_ms = wall_clock_ms,
        .roundtrips = roundtrips,
        .tool_calls = tool_calls,
        .verification_attempts = verification_attempts,
        .within_budget = wall_clock_ms <= task_timeout_ms and
            roundtrips <= max_roundtrips and tool_calls <= max_tool_calls and
            verification_attempts <= max_verification_attempts and
            (if (result) |value| endReasonWithinBudget(value) else observation.error_outcome != .timeout),
    };
}

fn harnessFailureResult(
    task: corpus.Task,
    progress: CaseProgress,
    err: anyerror,
) report.CaseResult {
    return .{
        .task_id = task.id,
        .outcome = .harness_error,
        .within_budget = progress.within_budget,
        .error_name = @errorName(err),
        .wall_clock_ms = progress.wall_clock_ms,
        .roundtrips = progress.roundtrips,
        .tool_calls = progress.tool_calls,
        .verification_attempts = progress.verification_attempts,
    };
}

fn runCase(
    allocator: std.mem.Allocator,
    registry: *const @import("registry/registry.zig").Registry,
    task: corpus.Task,
    output_root: []const u8,
    zttp_bin: []const u8,
    client: loop.ModelClient,
    live_session: ?*agent.AgentSession,
) !report.CaseResult {
    const started_ns = zts.monotonicNowNs() catch 0;
    var workspace = try IsolatedTmp.init(allocator, "reach-model");
    defer workspace.cleanup(allocator);
    try reach.writeFiles(allocator, workspace.abs_path, task.seed_files);

    const case_relative = try std.fmt.allocPrint(allocator, "cases/{s}", .{task.id});
    const case_abs = try std.fs.path.resolve(allocator, &.{ output_root, case_relative });
    var backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer backend.deinit();
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), backend.io(), case_abs);
    const provider_dir = try std.fs.path.resolve(allocator, &.{ case_abs, "provider" });
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), backend.io(), provider_dir);

    var capture: LiveCapture = .{ .allocator = allocator, .case_dir = case_abs, .task_id = task.id };
    defer capture.deinit();
    var sink = capture.sink();
    if (live_session) |session| try setSessionCapture(session, &sink);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    const observed = runTurnInWorkspace(
        allocator,
        registry,
        &transcript,
        client,
        task,
        workspace.abs_path,
    );
    if (live_session) |session| try setSessionCapture(session, null);
    const turn_observation = try observed;

    return finishCase(
        allocator,
        task,
        output_root,
        zttp_bin,
        workspace.abs_path,
        case_relative,
        &transcript,
        turn_observation,
        &capture,
        started_ns,
    ) catch |err| {
        const progress = observeCaseProgress(started_ns, turn_observation, &transcript);
        const failure = harnessFailureResult(task, progress, err);
        retainPostTurnFailure(
            allocator,
            task,
            output_root,
            workspace.abs_path,
            case_relative,
            &transcript,
            turn_observation,
            failure,
            &capture,
        );
        return failure;
    };
}

fn finishCase(
    allocator: std.mem.Allocator,
    task: corpus.Task,
    output_root: []const u8,
    zttp_bin: []const u8,
    workspace_abs: []const u8,
    case_relative: []const u8,
    transcript: *const transcript_mod.Transcript,
    turn_observation: TurnObservation,
    capture: *LiveCapture,
    started_ns: u64,
) !report.CaseResult {
    const transcript_bytes = try renderTranscript(allocator, transcript);
    const transcript_path = try std.fmt.allocPrint(allocator, "{s}/transcript.txt", .{case_relative});
    try writeArtifact(allocator, output_root, transcript_path, transcript_bytes);
    const workspace_record = try retainWorkspace(
        allocator,
        output_root,
        case_relative,
        workspace_abs,
        task,
    );
    const fixed_seeds_unchanged = try fixedSeedsUnchanged(allocator, workspace_abs, task);
    const evaluation = reach.evaluate(allocator, task, workspace_abs, zttp_bin) catch |err| {
        const error_path = try std.fmt.allocPrint(allocator, "{s}/evaluation-error.json", .{case_relative});
        writeJson(allocator, output_root, error_path, .{ .error_name = @errorName(err) }) catch |write_err| {
            std.debug.print("[reach] {s}: could not retain evaluation error: {s}\n", .{
                task.id, @errorName(write_err),
            });
        };
        return err;
    };
    const compiler_path = try std.fmt.allocPrint(allocator, "{s}/compiler.json", .{case_relative});
    try writeArtifact(allocator, output_root, compiler_path, evaluation.compiler_output);
    const stdout_path = try std.fmt.allocPrint(allocator, "{s}/intent.stdout", .{case_relative});
    try writeArtifact(allocator, output_root, stdout_path, evaluation.intent_stdout);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}/intent.stderr", .{case_relative});
    try writeArtifact(allocator, output_root, stderr_path, evaluation.intent_stderr);
    const progress = observeCaseProgress(started_ns, turn_observation, transcript);
    const result = turn_observation.result;
    const applied = if (result) |value| value.applied_change_set else false;
    const candidate_source_hash = if (applied)
        try candidateHash(allocator, workspace_record, task)
    else
        null;
    var outcome: report.Outcome = if (turn_observation.error_outcome) |failure|
        failure
    else if (!progress.within_budget)
        .budget_exhausted
    else if (result.?.end_reason == .veto_exhausted)
        .proof_failed
    else if (!applied)
        .no_edit
    else if (!fixed_seeds_unchanged)
        .proof_failed
    else if (!evaluation.compiler_ok or !evaluation.properties_ok)
        .proof_failed
    else if (!evaluation.intent_passed)
        .intent_failed
    else
        .reached;
    if ((applied and candidate_source_hash == null) or capture.diagnostic_write_failed) {
        outcome = .harness_error;
    }
    const harness_error_name: ?[]const u8 = if (capture.diagnostic_write_failed)
        capture.diagnostic_error_name
    else if (applied and candidate_source_hash == null)
        "MissingCandidateSource"
    else
        null;

    const compiler_evidence_hash = try reach.digest(
        allocator,
        "reach-compiler-evidence-v1",
        evaluation.compiler_output,
    );
    const intent_evidence_hash = try reach.digest(allocator, "reach-intent-evidence-v1", .{
        .stdout = evaluation.intent_stdout,
        .stderr = evaluation.intent_stderr,
    });
    const artifact_hash = try reach.digest(allocator, "reach-case-artifact-v1", .{
        .task_id = task.id,
        .transcript = transcript_bytes,
        .workspace = workspace_record,
        .provider_exchange_hashes = capture.exchange_hashes.items,
        .compiler_evidence_hash = compiler_evidence_hash,
        .intent_evidence_hash = intent_evidence_hash,
    });
    const success_evidence = outcome == .reached or outcome == .intent_failed;
    const case_result: report.CaseResult = .{
        .task_id = task.id,
        .outcome = outcome,
        .compiler_ok = if (!applied or turn_observation.error_outcome != null) false else evaluation.compiler_ok,
        .properties_ok = if (!applied or turn_observation.error_outcome != null or !fixed_seeds_unchanged) false else evaluation.properties_ok,
        .intent_passed = if (!applied or turn_observation.error_outcome != null or !fixed_seeds_unchanged) false else evaluation.intent_passed,
        .within_budget = progress.within_budget,
        .candidate_source_hash = if (outcome == .no_edit or turn_observation.error_outcome != null) null else candidate_source_hash,
        .artifact_hash = if (success_evidence) artifact_hash else null,
        .compiler_evidence_hash = if (success_evidence or outcome == .proof_failed) compiler_evidence_hash else null,
        .intent_evidence_hash = if (success_evidence) intent_evidence_hash else null,
        .error_name = turn_observation.error_name orelse harness_error_name,
        .wall_clock_ms = progress.wall_clock_ms,
        .roundtrips = progress.roundtrips,
        .tool_calls = progress.tool_calls,
        .verification_attempts = progress.verification_attempts,
    };
    const result_path = try std.fmt.allocPrint(allocator, "{s}/result.json", .{case_relative});
    try writeJson(allocator, output_root, result_path, .{
        .result = case_result,
        .usage = if (result) |value| value.usage else null,
        .end_reason = if (result) |value| @tagName(value.end_reason) else null,
        .fixed_seeds_unchanged = fixed_seeds_unchanged,
        .provider_exchange_count = capture.exchange_hashes.items.len,
        .provider_attempt_count = capture.provider_attempts,
    });
    return case_result;
}

fn retainPostTurnFailure(
    allocator: std.mem.Allocator,
    task: corpus.Task,
    output_root: []const u8,
    workspace_abs: []const u8,
    case_relative: []const u8,
    transcript: *const transcript_mod.Transcript,
    observation: TurnObservation,
    failure: report.CaseResult,
    capture: *const LiveCapture,
) void {
    if (renderTranscript(allocator, transcript)) |transcript_bytes| {
        if (std.fmt.allocPrint(allocator, "{s}/transcript.txt", .{case_relative})) |transcript_path| {
            writeArtifact(allocator, output_root, transcript_path, transcript_bytes) catch |err| {
                std.debug.print("[reach] {s}: could not retain failure transcript: {s}\n", .{ task.id, @errorName(err) });
            };
        } else |err| {
            std.debug.print("[reach] {s}: could not name failure transcript: {s}\n", .{ task.id, @errorName(err) });
        }
    } else |err| {
        std.debug.print("[reach] {s}: could not render failure transcript: {s}\n", .{ task.id, @errorName(err) });
    }
    _ = retainWorkspace(allocator, output_root, case_relative, workspace_abs, task) catch |err| {
        std.debug.print("[reach] {s}: could not retain failure workspace: {s}\n", .{ task.id, @errorName(err) });
    };
    if (std.fmt.allocPrint(allocator, "{s}/result.json", .{case_relative})) |result_path| {
        writeJson(allocator, output_root, result_path, .{
            .result = failure,
            .usage = if (observation.result) |value| value.usage else null,
            .end_reason = if (observation.result) |value| @tagName(value.end_reason) else null,
            .provider_exchange_count = capture.exchange_hashes.items.len,
            .provider_attempt_count = capture.provider_attempts,
        }) catch |err| {
            std.debug.print("[reach] {s}: could not retain failure result: {s}\n", .{ task.id, @errorName(err) });
        };
    } else |err| {
        std.debug.print("[reach] {s}: could not name failure result: {s}\n", .{ task.id, @errorName(err) });
    }
}

fn writeCheckpoint(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    run: report.Run,
    expected: []const report.ExpectedCase,
) !void {
    const summary = try report.summarize(run, expected);
    try writeJson(allocator, output_root, "report.json", run);
    try writeJson(allocator, output_root, "summary.json", summary);
}

fn retainCaseResult(allocator: std.mem.Allocator, result: report.CaseResult) !report.CaseResult {
    var retained = result;
    retained.task_id = try allocator.dupe(u8, result.task_id);
    inline for (.{ "candidate_source_hash", "artifact_hash", "compiler_evidence_hash", "intent_evidence_hash", "error_name" }) |field| {
        if (@field(result, field)) |value| @field(retained, field) = try allocator.dupe(u8, value);
    }
    return retained;
}

fn runId(allocator: std.mem.Allocator, mode: Mode) ![]const u8 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(@enumFromInt(@intFromEnum(std.posix.CLOCK.REALTIME)), &ts);
    return std.fmt.allocPrint(
        allocator,
        "reach-{s}-{d}-{d}",
        .{ @tagName(mode), @as(u64, @intCast(ts.sec)), std.c.getpid() },
    );
}

fn execute(allocator: std.mem.Allocator, command: Command) !void {
    const repo_root = try common.realCwd(allocator);
    const requested_output = if (std.fs.path.isAbsolute(command.output))
        try std.fs.path.resolve(allocator, &.{command.output})
    else
        try std.fs.path.resolve(allocator, &.{ repo_root, command.output });
    var output_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer output_backend.deinit();
    const parent = std.fs.path.dirname(requested_output) orelse return error.InvalidOutputPath;
    const real_parent = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), output_backend.io(), parent, allocator);
    const output_abs = try std.fs.path.resolve(allocator, &.{ real_parent, std.fs.path.basename(requested_output) });
    if (common.isPathInsideRoot(repo_root, output_abs)) return error.OutputMustBeOutsideRepository;
    const zttp_bin = @import("expert_codegen_eval.zig").locateZttpBinary(allocator, repo_root) orelse
        return error.ZttpBinaryNotFound;
    const source_before = try readSourceSnapshot(allocator, repo_root);
    if (command.mode == .live and (!source_before.known or !source_before.clean)) {
        return error.LiveRunRequiresCleanKnownSource;
    }
    try createOutput(allocator, output_abs);
    try writeJson(allocator, output_abs, "source-before.json", source_before);
    try retainTaskDefinitions(allocator, output_abs);

    std.debug.print("[reach] admitting {d} references before {s}\n", .{ corpus.tasks.len, @tagName(command.mode) });
    const admitted = try reach.admitReferences(allocator, zttp_bin, output_abs);
    try writeJson(allocator, output_abs, "suite.json", .{ .tasks = corpus.tasks, .admitted = admitted });
    if (command.mode == .references) {
        const source_after = try readSourceSnapshot(allocator, repo_root);
        try writeJson(allocator, output_abs, "source-after.json", source_after);
        if (!sameSource(source_before, source_after)) return error.SourceChangedDuringReachRun;
        std.debug.print("[reach] references admitted: {d}/{d}; output={s}\n", .{ admitted.len, corpus.tasks.len, output_abs });
        return;
    }

    const selected = admitted[0..command.limit];
    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    var model_identity: ?report.ModelIdentity = null;
    if (command.mode == .live) {
        if (models.default_provider != expected_provider or
            !std.mem.eql(u8, models.defaultForProvider(expected_provider).id, expected_model))
        {
            return error.ReachDefaultModelChanged;
        }
        var preflight_session = try initLiveSession(allocator, &registry);
        defer preflight_session.deinit(allocator);
        model_identity = try modelIdentity(
            allocator,
            try requestConfigForSession(&preflight_session),
        );
    }

    const rows = try allocator.alloc(report.CaseResult, selected.len);
    for (rows, selected) |*row, expected| row.* = .{
        .task_id = expected.id,
        .outcome = .not_attempted,
    };
    var run: report.Run = .{
        .schema_version = report.schema_version,
        .run_id = try runId(allocator, command.mode),
        .origin = if (command.mode == .live) .fresh_model else .deterministic_harness,
        .scope = if (command.limit == report.full_task_count) .full else .pilot,
        .complete = false,
        .source = source_before.asReport(),
        .identity = .{
            .suite_hash = try suiteHash(allocator, selected),
            .compiler = try compilerIdentity(allocator),
            .model = model_identity,
        },
        .limits = .{
            .task_timeout_ms = task_timeout_ms,
            .max_model_roundtrips = max_roundtrips,
            .max_tool_calls = max_tool_calls,
            .max_verification_attempts = max_verification_attempts,
        },
        .selected = selected,
        .cases = rows,
    };
    try writeCheckpoint(allocator, output_abs, run, selected);

    var infrastructure_failed = false;
    for (corpus.tasks[0..command.limit], 0..) |task, index| {
        std.debug.print("[reach] [{d}/{d}] {s}: start\n", .{ index + 1, command.limit, task.id });
        var case_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer case_arena.deinit();
        const case_allocator = case_arena.allocator();
        var live_session: ?agent.AgentSession = null;
        defer if (live_session) |*session| session.deinit(case_allocator);
        if (command.mode == .live) {
            live_session = try initLiveSession(case_allocator, &registry);
            if (live_session) |*session| {
                const case_identity = try modelIdentity(
                    case_allocator,
                    try requestConfigForSession(session),
                );
                if (!modelIdentityEql(model_identity.?, case_identity)) {
                    return error.ReachModelIdentityChanged;
                }
            }
        }
        var scripted: ScriptedClient = .{ .task = &corpus.tasks[index] };
        const client = if (live_session) |*session| session.modelClient() else scripted.asModelClient();
        const case_result: report.CaseResult = runCase(
            case_allocator,
            &registry,
            task,
            output_abs,
            zttp_bin,
            client,
            if (live_session) |*session| session else null,
        ) catch |err| row: {
            infrastructure_failed = true;
            std.debug.print("[reach] [{d}/{d}] {s}: harness error {s}\n", .{
                index + 1, command.limit, task.id, @errorName(err),
            });
            break :row .{
                .task_id = task.id,
                .outcome = .harness_error,
                .error_name = @errorName(err),
            };
        };
        rows[index] = try retainCaseResult(allocator, case_result);
        if (rows[index].outcome == .harness_error) infrastructure_failed = true;
        try writeCheckpoint(allocator, output_abs, run, selected);
        std.debug.print("[reach] [{d}/{d}] {s}: {s}\n", .{
            index + 1, command.limit, task.id, @tagName(rows[index].outcome),
        });
    }

    const source_after = try readSourceSnapshot(allocator, repo_root);
    try writeJson(allocator, output_abs, "source-after.json", source_after);
    if (!sameSource(source_before, source_after)) {
        try writeCheckpoint(allocator, output_abs, run, selected);
        return error.SourceChangedDuringReachRun;
    }
    run.complete = true;
    try writeCheckpoint(allocator, output_abs, run, selected);
    const summary = try report.summarize(run, selected);
    std.debug.print("[reach] complete origin={s} scope={s} reached={d}/{d} output={s}\n", .{
        @tagName(run.origin), @tagName(run.scope), summary.reached, summary.selected, output_abs,
    });
    if (summary.headline) |headline| {
        std.debug.print("[reach] fresh full-suite reach: {d}/{d}\n", .{ headline.reached, headline.selected });
    }
    if (infrastructure_failed) return error.ReachInfrastructureFailure;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next();
    var values: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try values.append(allocator, try allocator.dupe(u8, arg));
    const command = parseCommand(values.items) catch |err| {
        std.debug.print(
            "usage: zttp-reach (--references|--smoke|--live --confirm-live) --output <new-path> [--limit 1|8]\nerror: {s}\n",
            .{@errorName(err)},
        );
        return err;
    };
    try execute(allocator, command);
}

const FinalTextClient = struct {
    fn requestFn(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *const transcript_mod.Transcript,
        _: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        return .{ .reply = .{ .response = .{ .final_text = "No edit." } } };
    }

    fn asModelClient(self: *FinalTextClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const SourceClient = struct {
    file: []const u8,
    source: []const u8,
    additional: []const turn.Change = &.{},

    fn requestFn(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: *const transcript_mod.Transcript,
        _: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *SourceClient = @ptrCast(@alignCast(context));
        return .{ .reply = .{ .response = .{ .change_set = .{
            .file = self.file,
            .content = self.source,
            .additional = self.additional,
        } } } };
    }

    fn asModelClient(self: *SourceClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const FailingClient = struct {
    fn requestFn(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: *const transcript_mod.Transcript,
        _: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        return error.DeepSeekServerUnavailable;
    }

    fn asModelClient(self: *FailingClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const BudgetClient = struct {
    request_index: usize = 0,

    fn requestFn(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        _: *const transcript_mod.Transcript,
        _: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *BudgetClient = @ptrCast(@alignCast(context));
        const calls = try allocator.alloc(turn.ToolCall, 1);
        calls[0] = .{
            .id = try std.fmt.allocPrint(allocator, "read-{d}", .{self.request_index}),
            .name = "workspace_read_file",
            .args_json = "{\"path\":\"handler.ts\"}",
        };
        self.request_index += 1;
        return .{ .reply = .{ .response = .{ .tool_calls = calls } } };
    }

    fn asModelClient(self: *BudgetClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

fn referenceHandler(task: corpus.Task) !@TypeOf(task.reference_files[0]) {
    for (task.reference_files) |file| {
        if (std.mem.eql(u8, file.path, task.intent.handler_path)) return file;
    }
    return error.MissingReferenceHandler;
}

fn runScriptedTestCase(
    allocator: std.mem.Allocator,
    task: corpus.Task,
    output_root: []const u8,
    client: loop.ModelClient,
) !report.CaseResult {
    const repo_root = try common.realCwd(allocator);
    const zttp_bin = @import("expert_codegen_eval.zig").locateZttpBinary(allocator, repo_root) orelse
        return error.ZttpBinaryNotFound;
    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    return runCase(allocator, &registry, task, output_root, zttp_bin, client, null);
}

fn expectCaseArtifact(
    allocator: std.mem.Allocator,
    output_root: []const u8,
    task_id: []const u8,
    name: []const u8,
) !void {
    const path = try std.fs.path.resolve(allocator, &.{ output_root, "cases", task_id, name });
    try std.testing.expect(zts.file_io.fileExists(allocator, path));
}

test "reach command parser rejects unsafe and ambiguous invocations" {
    try std.testing.expectError(error.MissingMode, parseCommand(&.{ "--output", "/tmp/reach" }));
    try std.testing.expectError(error.MissingOutput, parseCommand(&.{"--smoke"}));
    try std.testing.expectError(error.ConflictingModes, parseCommand(&.{
        "--smoke", "--live", "--confirm-live", "--output", "/tmp/reach",
    }));
    try std.testing.expectError(error.InvalidLimit, parseCommand(&.{
        "--smoke", "--output", "/tmp/reach", "--limit", "0",
    }));
    try std.testing.expectError(error.InvalidLimit, parseCommand(&.{
        "--smoke", "--output", "/tmp/reach", "--limit", "9",
    }));
    try std.testing.expectError(error.LiveConfirmationRequired, parseCommand(&.{
        "--live", "--output", "/tmp/reach",
    }));
    try std.testing.expectError(error.LiveConfirmationWithoutLive, parseCommand(&.{
        "--smoke", "--confirm-live", "--output", "/tmp/reach",
    }));
    try std.testing.expectError(error.UnknownArgument, parseCommand(&.{
        "--live", "--confirm-live", "--output", "/tmp/reach", "--provider", "deepseek",
    }));
}

test "reach command parser accepts only the fixed scale choices" {
    const pilot = try parseCommand(&.{ "--smoke", "--output", "/tmp/reach", "--limit", "1" });
    try std.testing.expectEqual(Mode.smoke, pilot.mode);
    try std.testing.expectEqual(@as(usize, 1), pilot.limit);
    const full = try parseCommand(&.{ "--live", "--confirm-live", "--output", "/tmp/reach" });
    try std.testing.expectEqual(Mode.live, full.mode);
    try std.testing.expectEqual(@as(usize, report.full_task_count), full.limit);
}

test "empty transcript evidence is retained as an empty buffer" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    const rendered = try renderTranscript(std.testing.allocator, &transcript);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(@as(usize, 0), rendered.len);
}

test "workspace evidence retains and hashes generated source outside declared paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var workspace = try IsolatedTmp.init(allocator, "reach-extra-source-workspace");
    defer workspace.cleanup(allocator);
    var output = try IsolatedTmp.init(allocator, "reach-extra-source-output");
    defer output.cleanup(allocator);
    const task = corpus.tasks[0];
    try reach.writeFiles(allocator, workspace.abs_path, task.reference_files);
    try workspace.writeFile(allocator, "lib/generated.ts", "export const value = 1;\n");
    const first = try retainWorkspace(
        allocator,
        output.abs_path,
        "cases/first",
        workspace.abs_path,
        task,
    );
    const first_hash = (try candidateHash(allocator, first, task)).?;
    try workspace.writeFile(allocator, "lib/generated.ts", "export const value = 2;\n");
    const second = try retainWorkspace(
        allocator,
        output.abs_path,
        "cases/second",
        workspace.abs_path,
        task,
    );
    const second_hash = (try candidateHash(allocator, second, task)).?;
    try std.testing.expect(!std.mem.eql(u8, first_hash, second_hash));
    try expectCaseArtifact(allocator, output.abs_path, "first", "workspace/lib/generated.ts");
    try expectCaseArtifact(allocator, output.abs_path, "second", "workspace/lib/generated.ts");
}

test "scripted no-edit result retains transcript workspace and failure row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-no-edit");
    defer output.cleanup(allocator);
    var client: FinalTextClient = .{};
    const task = corpus.tasks[0];
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.no_edit, result.outcome);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "transcript.txt");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "workspace.json");
}

test "scripted compiler-green wrong handler is retained as intent failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-wrong-intent");
    defer output.cleanup(allocator);
    const task = corpus.tasks[0];
    const handler = try referenceHandler(task);
    const wrong = try std.mem.replaceOwned(u8, allocator, handler.bytes, "kind: kind", "kind: \"wrong\"");
    var client: SourceClient = .{ .file = handler.path, .source = wrong };
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.intent_failed, result.outcome);
    try std.testing.expect(result.compiler_ok);
    try std.testing.expect(result.properties_ok);
    try std.testing.expect(!result.intent_passed);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "intent.stdout");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
}

test "scripted model failure retains the provider outcome and actual counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-provider-failure");
    defer output.cleanup(allocator);
    var client: FailingClient = .{};
    const task = corpus.tasks[0];
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.provider_error, result.outcome);
    try std.testing.expectEqual(@as(u32, 1), result.roundtrips);
    try std.testing.expectEqualStrings("DeepSeekServerUnavailable", result.error_name.?);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
}

test "post-turn artifact failure retains the actual work counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-artifact-failure");
    defer output.cleanup(allocator);
    const task = corpus.tasks[0];
    const blocked_path = try std.fmt.allocPrint(allocator, "cases/{s}/transcript.txt", .{task.id});
    try output.mkdir(allocator, blocked_path);
    var client: ScriptedClient = .{ .task = &corpus.tasks[0] };
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.harness_error, result.outcome);
    try std.testing.expectEqual(@as(u32, 1), result.roundtrips);
    try std.testing.expectEqual(@as(u32, 1), result.verification_attempts);
    try std.testing.expect(result.error_name != null);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "workspace/handler.ts");
}

test "output creation refuses an existing run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-existing-output");
    defer output.cleanup(allocator);
    try std.testing.expectError(error.OutputAlreadyExists, createOutput(allocator, output.abs_path));
}

test "scripted repeated tools retain budget exhaustion in the denominator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-budget");
    defer output.cleanup(allocator);
    var client: BudgetClient = .{};
    const task = corpus.tasks[0];
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.budget_exhausted, result.outcome);
    try std.testing.expectEqual(max_roundtrips, result.roundtrips);
    try std.testing.expect(!result.within_budget);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
}

test "veto exhaustion over a hole seed does not report the untouched seed as accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-veto-hole");
    defer output.cleanup(allocator);
    const task = corpus.tasks[1];
    var client: SourceClient = .{
        .file = task.intent.handler_path,
        .source = "function handler(req: Request): Response { return missingName; }\n",
    };
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.proof_failed, result.outcome);
    try std.testing.expect(!result.compiler_ok);
    try std.testing.expect(!result.properties_ok);
    try std.testing.expect(!result.intent_passed);
    try std.testing.expectEqual(max_verification_attempts, result.verification_attempts);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "compiler.json");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
}

test "rewriting a frozen helper cannot score as reached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output = try IsolatedTmp.init(allocator, "reach-fixed-helper");
    defer output.cleanup(allocator);
    const task = corpus.tasks[6];
    const handler = try referenceHandler(task);
    const helper = task.seed_files[0];
    const changed_helper = try std.mem.concat(allocator, u8, &.{ helper.bytes, "\n" });
    const additional = try allocator.alloc(turn.Change, 1);
    additional[0] = .{ .file = helper.path, .content = changed_helper };
    var client: SourceClient = .{
        .file = handler.path,
        .source = handler.bytes,
        .additional = additional,
    };
    const result = try runScriptedTestCase(allocator, task, output.abs_path, client.asModelClient());
    try std.testing.expectEqual(report.Outcome.proof_failed, result.outcome);
    try std.testing.expect(!result.properties_ok);
    try std.testing.expect(!result.intent_passed);
    try expectCaseArtifact(allocator, output.abs_path, task.id, "workspace/lib/label.ts");
    try expectCaseArtifact(allocator, output.abs_path, task.id, "result.json");
}
