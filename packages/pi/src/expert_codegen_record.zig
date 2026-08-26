//! expert_codegen_record - baseline recorder and offline recorder smoke test.
//!
//! Corpus recording spends real model time and stays gated behind
//! `ZTTP_CODEGEN_RECORD=1`. `ZTTP_CODEGEN_PROVIDER` selects the provider;
//! `ZTTP_CODEGEN_REQUIRE_GREEN=1` refuses to stage a case that did not apply an
//! edit or whose declared runtime intent did not pass.
//! `ZTTP_CODEGEN_QUALIFY=1` is a separate report-only full-corpus mode. It
//! never activates cassettes or changes a model default.
//! cloud credentials are required only for an explicitly selected cloud
//! provider. Transport, capture, disk, and replay are tested offline.
//! Live cassettes remain the only source for model-behavior measurements.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const anthropic = @import("providers/anthropic/client.zig");
const anthropic_tools = @import("providers/anthropic/tools_schema.zig");
const local = @import("providers/local/client.zig");
const openai = @import("providers/openai/client.zig");
const deepseek = @import("providers/deepseek/client.zig");
const cassette_client = @import("providers/cassette_client.zig");
const cassette_record = @import("providers/cassette_record.zig");
const capture_sink = @import("providers/capture_sink.zig");
const model_request = @import("providers/model_request.zig");
const tool_catalog = @import("providers/tool_catalog.zig");
const registry_mod = @import("registry/registry.zig");
const flow_artifact = @import("simulator/artifact.zig");
const flow_promotion = @import("simulator/promotion.zig");
const flow_recorder = @import("simulator/recorder.zig");
const simulator_model_client = @import("simulator/model_client.zig");
const transcript_mod = @import("transcript.zig");
const loop = @import("loop.zig");
const app = @import("app.zig");
const agent = @import("agent.zig");
const codegen = @import("expert_codegen_eval.zig");
const codegen_types = @import("expert_codegen_types.zig");
const evidence_identity = @import("expert_evidence_identity.zig");
const failure_analysis = @import("expert_failure_analysis.zig");
const qualification = @import("expert_qualification.zig");
const security_probes = @import("expert_security_probes.zig");
const expert_persona = @import("expert_persona.zig");
const models = @import("providers/models.zig");
const tool_common = @import("tools/common.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const cwdPathAlloc = @import("test_support/cwd.zig").cwdPathAlloc;

const testing = std.testing;

const CodegenResponseCapture = struct {
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    scenario: []const u8,

    fn record(
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void {
        const self: *CodegenResponseCapture = @ptrCast(@alignCast(context));
        const scenario_dir = try std.fs.path.join(self.allocator, &.{ self.out_dir, self.scenario });
        defer self.allocator.free(scenario_dir);
        var io_backend = std.Io.Threaded.init(self.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), scenario_dir);

        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/step_{d}.jsonl",
            .{ scenario_dir, call_index },
        );
        defer self.allocator.free(path);
        try cassette_record.writeCassette(self.allocator, path, raw_response, .{
            .provider = switch (snapshot.config.provider) {
                .local => .local,
                .anthropic => .anthropic,
                .openai => .openai,
                .deepseek => .deepseek,
            },
            .scenario = self.scenario,
            .stream = snapshot.config.stream,
            .model = snapshot.config.model,
            .request_sha256 = if (snapshot.wire_request_sha256) |digest| digest.slice() else null,
        });
    }
};

/// Replays a recorded multi-roundtrip session: each model request is served the
/// next committed cassette step (step_0, step_1, ...), parsed through the same
/// assembler the live client uses. The transcript is ignored - the recorded
/// responses are authoritative - so the loop re-executes the recorded tool calls
/// and re-vetoes the recorded edit deterministically and offline.
const CassetteSequenceClient = struct {
    steps: []const []const u8,
    index: usize = 0,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        tr: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *CassetteSequenceClient = @ptrCast(@alignCast(ctx));
        _ = tr;
        _ = extra_user_text;
        if (self.index >= self.steps.len) return error.CassetteSequenceExhausted;
        const cassette = try cassette_client.loadCassetteFromBytes(arena, self.steps[self.index], null);
        self.index += 1;
        return try cassette_client.replay(arena, cassette);
    }

    pub fn asClient(self: *CassetteSequenceClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

/// Where one case's provider responses were read from.
pub const StepSource = enum { flow_artifact, flat_cassette, missing };

pub const ResolvedSteps = struct {
    steps: [][]u8,
    source: StepSource,
    flow_case: ?flow_artifact.FlowCase = null,

    pub fn deinit(self: *ResolvedSteps, allocator: std.mem.Allocator) void {
        if (self.flow_case) |*flow_case| flow_case.deinit();
        for (self.steps) |step| allocator.free(step);
        allocator.free(self.steps);
        self.* = undefined;
    }

    pub fn responseCount(self: *const ResolvedSteps) usize {
        if (self.flow_case) |flow_case| return flow_case.manifest.model_responses.len;
        return self.steps.len;
    }

    pub fn model(self: *const ResolvedSteps) ?[]const u8 {
        if (self.flow_case) |flow_case| return flow_case.manifest.model;
        if (self.steps.len == 0) return null;
        return cassetteModel(self.steps[0]);
    }
};

/// True when `name` has a recorded flow artifact, which is the descriptor's
/// presence and nothing more. Whether that artifact loads is a separate
/// question, and one this must not answer: a case with a descriptor and a
/// broken generation is a corrupt corpus, and falling back to its old flat
/// cassette would replay stale bytes under a fresh recording's name.
fn hasFlowArtifact(allocator: std.mem.Allocator, case_root_abs: []const u8) bool {
    const descriptor = std.fmt.allocPrint(allocator, "{s}/case.json", .{case_root_abs}) catch return false;
    defer allocator.free(descriptor);
    const bytes = zts.file_io.readFile(allocator, descriptor, 64 * 1024) catch return false;
    allocator.free(bytes);
    return true;
}

/// One case's provider responses, preferring the recorded flow artifact over
/// the flat cassette.
///
/// The recorder writes flow artifacts and has since `71c7bbf4`; the flat
/// cassettes are what every case recorded before it still carries. They are not
/// convertible - re-recording a case to change its storage format redraws the
/// sample, which is the re-rolling `docs/convergence.md` forbids - so both are
/// read here and neither is ever written twice. A case has one or the other,
/// the flat set only shrinks, and the split closes as cases are re-recorded for
/// their own reasons.
///
/// Reading the artifact through `artifact.loadCase` rather than by globbing
/// `responses/` is the point: it resolves the descriptor's active generation
/// and checks every fixture against its recorded digest, so a corpus edited by
/// hand fails here instead of replaying as a recording.
fn resolveCaseSteps(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    provider: agent.Provider,
    name: []const u8,
) !ResolvedSteps {
    const flow_case_root = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}",
        .{ repo_root, flowRoot(provider), name },
    );
    defer allocator.free(flow_case_root);

    if (hasFlowArtifact(allocator, flow_case_root)) {
        const state = flow_artifact.loadCase(allocator, flow_case_root);
        switch (state) {
            .available => |flow_case| {
                var owned_flow_case = flow_case;
                errdefer owned_flow_case.deinit();
                return .{
                    .steps = try allocator.alloc([]u8, 0),
                    .source = .flow_artifact,
                    .flow_case = owned_flow_case,
                };
            },
            .failure => |diagnostic| {
                std.debug.print(
                    "[codegen-replay] {s}: flow artifact failed to load ({s} in {s}, {s})\n",
                    .{
                        name,
                        @tagName(diagnostic.kind),
                        @tagName(diagnostic.component),
                        diagnostic.fixturePath(),
                    },
                );
                if (diagnostic.kind == .unsupported_schema_version) {
                    return error.StaleFlowArtifact;
                }
                return error.UnloadableFlowArtifact;
            },
        }
    }

    if (provider != .anthropic) {
        return .{ .steps = try allocator.alloc([]u8, 0), .source = .missing };
    }

    const cassette_case_root = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}",
        .{ repo_root, cassette_root, name },
    );
    defer allocator.free(cassette_case_root);
    return .{ .steps = try readCaseSteps(allocator, cassette_case_root), .source = .flat_cassette };
}

/// Empirical replay tests cannot reinterpret a pre-change-set recording as
/// current evidence. Skip those tests until an explicitly authorized fresh
/// recording exists. Publication scripts still fail because a skipped replay
/// emits no complete evidence marker.
///
/// A skip is silent, so it is not the signal on its own: the test named
/// "every headline empirical case resolves to a current recording" is what
/// fails and names the re-record command. Do not loosen it to accept a stale
/// cohort, or this skip becomes a corpus that quietly covers nothing.
fn resolveCurrentCaseStepsForTest(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    provider: agent.Provider,
    name: []const u8,
) !ResolvedSteps {
    return resolveCaseSteps(allocator, repo_root, provider, name) catch |err| switch (err) {
        error.StaleFlowArtifact => error.SkipZigTest,
        else => err,
    };
}

/// Read step_0.jsonl, step_1.jsonl, ... from an absolute case directory until a
/// step is missing. Returns an empty slice when the case has no cassette yet.
fn readCaseSteps(allocator: std.mem.Allocator, dir_abs: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (true) : (i += 1) {
        const path = try std.fmt.allocPrint(allocator, "{s}/step_{d}.jsonl", .{ dir_abs, i });
        defer allocator.free(path);
        // An absent step ends the sequence (and an absent step_0 means no
        // cassette); any other read error must surface, not masquerade as "missing".
        const bytes = zts.file_io.readFile(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        try list.append(allocator, bytes);
    }
    return list.toOwnedSlice(allocator);
}

/// Where committed cassettes live, relative to the repo root (the cwd when the
/// recorder runs via `zig build`).
pub const cassette_root = "packages/pi/src/providers/testdata/codegen";
pub const claude_empirical_flow_root = "packages/pi/src/simulator/testdata/empirical/codegen";
pub const local_empirical_flow_root = "packages/pi/src/simulator/testdata/empirical/local/codegen";
pub const openai_empirical_flow_root = "packages/pi/src/simulator/testdata/empirical/openai/codegen";
pub const deepseek_empirical_flow_root = "packages/pi/src/simulator/testdata/empirical/deepseek/codegen";

// Runtime and evaluation defaults share one authority. The local cutover is a
// one-line change only after its structural E2E and full corpus both complete.
pub const headline_provider: agent.Provider = models.default_provider;
pub const empirical_flow_root = flowRoot(headline_provider);

fn flowRoot(provider: agent.Provider) []const u8 {
    return switch (provider) {
        .local => local_empirical_flow_root,
        .anthropic => claude_empirical_flow_root,
        .openai => openai_empirical_flow_root,
        .deepseek => deepseek_empirical_flow_root,
    };
}

fn recordingProvider() !agent.Provider {
    const value = envValue("ZTTP_CODEGEN_PROVIDER") orelse return .local;
    return agent.Provider.parsePublic(value) orelse error.UnsupportedRecordingProvider;
}

fn recordingAuthAvailable(provider: agent.Provider) bool {
    return switch (provider) {
        .local => true,
        .anthropic => envValue("ANTHROPIC_API_KEY") != null,
        .openai => envValue("OPENAI_API_KEY") != null,
        .deepseek => envValue("DEEPSEEK_API_KEY") != null,
    };
}

/// A DeepSeek turn is slower than a local one, and the heavier cases exceed the
/// 3-minute default. A turn cut off there can never replay, so the recorder
/// refuses to promote it - which reads as a recording failure rather than as a
/// ceiling that was set too low. The corpus was recorded at 600000, so the
/// remediation names that value rather than leaving the operator to rediscover
/// it from a refused promotion.
const deepseek_record_turn_timeout_ms: u64 = 600_000;

fn recordingCommand(
    allocator: std.mem.Allocator,
    provider: agent.Provider,
) ![]u8 {
    const timeout: []const u8 = if (provider == .deepseek)
        std.fmt.comptimePrint(
            "ZTTP_CODEGEN_TURN_TIMEOUT_MS={d} ",
            .{deepseek_record_turn_timeout_ms},
        )
    else
        "";
    return std.fmt.allocPrint(
        allocator,
        "ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER={s} {s}" ++
            "zig build test-expert-app -Dtest-filter=\"record codegen baseline corpus\"",
        .{ provider.publicName(), timeout },
    );
}

test "recording remediation preserves the replay provider and requires the full corpus" {
    const claude = try recordingCommand(testing.allocator, .anthropic);
    defer testing.allocator.free(claude);
    try testing.expect(std.mem.indexOf(u8, claude, "ZTTP_CODEGEN_PROVIDER=claude") != null);

    const local_full = try recordingCommand(testing.allocator, .local);
    defer testing.allocator.free(local_full);
    try testing.expect(std.mem.indexOf(u8, local_full, "ZTTP_CODEGEN_PROVIDER=local") != null);
    try testing.expect(std.mem.indexOf(u8, local_full, "ZTTP_CODEGEN_ONLY") == null);

    // The DeepSeek ceiling is named because the default truncates the heavier
    // cases into refused promotions. The local default is the stall guard, so
    // the remediation must not raise it there.
    const deepseek_command = try recordingCommand(testing.allocator, .deepseek);
    defer testing.allocator.free(deepseek_command);
    try testing.expect(std.mem.indexOf(u8, deepseek_command, "ZTTP_CODEGEN_PROVIDER=deepseek") != null);
    try testing.expect(std.mem.indexOf(u8, deepseek_command, "ZTTP_CODEGEN_TURN_TIMEOUT_MS=600000") != null);
    try testing.expect(std.mem.indexOf(u8, local_full, "ZTTP_CODEGEN_TURN_TIMEOUT_MS") == null);
}

/// The declared local server stack, as `name@version`.
///
/// MLX-LM names itself in every response `system_fingerprint`, so a recording
/// against it needs nothing here. rapid-mlx sends no fingerprint and serves no
/// version endpoint, so the identity exists only in the operator's shell and
/// `ZTTP_CODEGEN_LOCAL_RUNTIME=rapid-mlx@0.12.11` is how it reaches the
/// manifest. Refused rather than guessed when malformed: a wrong stack name is
/// worse than an absent one, because the artifact gate accepts it.
const RuntimeIdentity = struct { name: []const u8, version: []const u8 };

fn declaredRuntime(provider: agent.Provider) !?RuntimeIdentity {
    return declaredRuntimeFrom(provider, envValue("ZTTP_CODEGEN_LOCAL_RUNTIME"));
}

test "a declared runtime identity splits on the first at-sign" {
    const identity = (try declaredRuntimeFrom(.local, "rapid-mlx@0.12.11")).?;
    try testing.expectEqualStrings("rapid-mlx", identity.name);
    try testing.expectEqualStrings("0.12.11", identity.version);
    try testing.expectError(error.MalformedRuntimeIdentity, declaredRuntimeFrom(.local, "rapid-mlx"));
    try testing.expectError(error.MalformedRuntimeIdentity, declaredRuntimeFrom(.local, "@0.12.11"));
    try testing.expectError(error.MalformedRuntimeIdentity, declaredRuntimeFrom(.local, "rapid-mlx@"));
    try testing.expectError(
        error.RuntimeIdentityRequiresLocalProvider,
        declaredRuntimeFrom(.anthropic, "rapid-mlx@0.12.11"),
    );
    try testing.expect(try declaredRuntimeFrom(.local, null) == null);
}

/// The body of `declaredRuntime`, with the environment read lifted out so the
/// parse is testable without a process-wide variable.
fn declaredRuntimeFrom(provider: agent.Provider, raw_opt: ?[]const u8) !?RuntimeIdentity {
    const raw = raw_opt orelse return null;
    if (provider != .local) return error.RuntimeIdentityRequiresLocalProvider;
    const split = std.mem.indexOfScalar(u8, raw, '@') orelse return error.MalformedRuntimeIdentity;
    const name = std.mem.trim(u8, raw[0..split], " \t");
    const version = std.mem.trim(u8, raw[split + 1 ..], " \t");
    if (name.len == 0 or version.len == 0) return error.MalformedRuntimeIdentity;
    if (name.len > 128 or version.len > 128) return error.MalformedRuntimeIdentity;
    return .{ .name = name, .version = version };
}

fn cachedModelRevision(allocator: std.mem.Allocator, provider: agent.Provider, model: []const u8) !?[]u8 {
    if (envValue("ZTTP_CODEGEN_MODEL_REVISION")) |revision| return try allocator.dupe(u8, revision);
    if (provider != .local or !std.mem.eql(u8, model, local.default_model)) return null;
    const cache_root = if (envValue("HF_HOME")) |root|
        try allocator.dupe(u8, root)
    else if (envValue("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".cache", "huggingface" })
    else
        return null;
    defer allocator.free(cache_root);
    const ref_path = try std.fs.path.join(allocator, &.{
        cache_root,
        "hub",
        "models--LiquidAI--LFM2.5-2.6B-MLX-8bit",
        "refs",
        "main",
    });
    defer allocator.free(ref_path);
    const bytes = zts.file_io.readFile(allocator, ref_path, 256) catch return null;
    defer allocator.free(bytes);
    const revision = std.mem.trim(u8, bytes, " \t\r\n");
    if (revision.len == 0) return null;
    for (revision) |byte| if (!std.ascii.isHex(byte)) return null;
    return try allocator.dupe(u8, revision);
}

fn requestConfigForSession(session: *const agent.AgentSession) !model_request.Config {
    return switch (session.backend) {
        .local => |client| .{
            .provider = .local,
            .model = client.config.model,
            .max_output_tokens = client.config.max_tokens,
            .stream = false,
            .system_prompt = client.config.system_prompt,
            .tools_json = client.config.tools_json,
        },
        .anthropic => |client| .{
            .provider = .anthropic,
            .model = client.config.model,
            .max_output_tokens = client.config.max_tokens,
            .system_prompt = client.config.system_prompt,
            .tools_json = client.config.tools_json,
        },
        .openai => |client| .{
            .provider = .openai,
            .model = client.config.model,
            .max_output_tokens = client.config.max_tokens,
            .system_prompt = client.config.system_prompt,
            .tools_json = client.config.tools_json,
        },
        .deepseek => |client| .{
            .provider = .deepseek,
            .model = client.config.model,
            .max_output_tokens = client.config.max_tokens,
            .stream = false,
            .system_prompt = client.config.system_prompt,
            .tools_json = client.config.tools_json,
        },
        .stub => error.UnsupportedRecordingProvider,
    };
}

const ReplayRequestContext = struct {
    system_prompt: []u8,
    tools_json: []u8,
    config: model_request.Config,

    fn init(
        allocator: std.mem.Allocator,
        registry: *const registry_mod.Registry,
        provider: agent.Provider,
        model_id: []const u8,
    ) !ReplayRequestContext {
        const selected_model = try models.resolveForProvider(provider, model_id);
        const system_prompt = try expert_persona.buildSystemPrompt(allocator);
        errdefer allocator.free(system_prompt);

        var tools = TextBuffer.init(allocator);
        defer tools.deinit();
        switch (provider) {
            .local => try local.writeToolsArray(tools.writer(), registry),
            .anthropic => try anthropic_tools.writeToolsArray(tools.writer(), registry),
            .openai => try openai.writeToolsArray(tools.writer(), registry),
            .deepseek => try deepseek.writeToolsArray(tools.writer(), registry),
        }
        const tools_json = try tools.toOwnedSlice();
        errdefer allocator.free(tools_json);

        return .{
            .system_prompt = system_prompt,
            .tools_json = tools_json,
            .config = .{
                .provider = switch (provider) {
                    .local => .local,
                    .anthropic => .anthropic,
                    .openai => .openai,
                    .deepseek => .deepseek,
                },
                .model = selected_model.id,
                .max_output_tokens = selected_model.request_policy.max_output_tokens,
                // The two Chat Completions adapters are non-streaming; the two
                // SSE adapters stream.
                .stream = provider != .local and provider != .deepseek,
                .system_prompt = system_prompt,
                .tools_json = tools_json,
            },
        };
    }

    fn deinit(self: *ReplayRequestContext, allocator: std.mem.Allocator) void {
        allocator.free(self.tools_json);
        allocator.free(self.system_prompt);
        self.* = undefined;
    }
};

const CorpusReplayClient = union(enum) {
    flow: simulator_model_client.Client,
    flat: CassetteSequenceClient,

    fn init(
        resolved: *const ResolvedSteps,
        request_config: ?model_request.Config,
    ) !CorpusReplayClient {
        if (resolved.flow_case) |*flow_case| {
            return .{ .flow = simulator_model_client.Client.init(
                simulator_model_client.Script.fromFlowCase(flow_case),
                request_config orelse return error.MissingFlowRequestConfig,
            ) };
        }
        return .{ .flat = .{ .steps = resolved.steps } };
    }

    fn asModelClient(self: *CorpusReplayClient) loop.ModelClient {
        return switch (self.*) {
            .flow => |*client| client.asModelClient(),
            .flat => |*client| client.asClient(),
        };
    }

    fn asSummarizer(self: *CorpusReplayClient) ?@import("compaction.zig").Summarizer {
        return switch (self.*) {
            .flow => |*client| client.asSummarizer(),
            .flat => null,
        };
    }

    fn finish(self: *CorpusReplayClient) !void {
        return switch (self.*) {
            .flow => |*client| client.finish(),
            .flat => {},
        };
    }

    fn lastFlowMismatch(self: *const CorpusReplayClient) ?flow_artifact.ReplayMismatch {
        return switch (self.*) {
            .flow => |*client| client.lastMismatch(),
            .flat => null,
        };
    }
};

const CorpusReplayOutcome = struct {
    result: loop.TurnResult,
    transcript: transcript_mod.Transcript,

    fn deinit(self: *CorpusReplayOutcome, allocator: std.mem.Allocator) void {
        self.transcript.deinit(allocator);
        self.* = undefined;
    }
};

/// Replays one corpus turn through the same provider-neutral admission and
/// compaction controller as a live session. Flow artifacts record standalone
/// summarizer calls as part of the model script, so bypassing this controller
/// makes every compacted recording diverge at its first summary checkpoint.
/// Legacy flat Anthropic cassettes predate that controller and retain their
/// direct model-client path until they are deliberately re-recorded.
fn replayCorpusTurn(
    allocator: std.mem.Allocator,
    resolved: *const ResolvedSteps,
    client: *CorpusReplayClient,
    request_config: ?model_request.Config,
    provider: agent.Provider,
    registry: *const registry_mod.Registry,
    prompt: []const u8,
) !CorpusReplayOutcome {
    var transcript: transcript_mod.Transcript = .{};
    errdefer transcript.deinit(allocator);

    if (resolved.flow_case) |*flow_case| {
        const config = request_config orelse return error.MissingFlowRequestConfig;
        const selected_model = try models.resolveForProvider(provider, flow_case.manifest.model);
        var session = agent.AgentSession.initControlled(allocator, selected_model, config);
        defer session.deinit(allocator);
        var controller: agent.RequestController = .{
            .allocator = allocator,
            .session = &session,
            .raw_client = client.asModelClient(),
            .summarizer = client.asSummarizer(),
        };
        const result = try loop.runTurnWith(
            allocator,
            controller.asModelClient(),
            registry,
            &session.transcript,
            prompt,
            .{
                .workspace_root = ".",
                .max_attempts = loop.interactive_max_attempts,
                .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
                .replay_mode = false,
                .turn_timeout_ms = 0,
            },
        );
        transcript = session.transcript;
        session.transcript = .{};
        return .{ .result = result, .transcript = transcript };
    }

    const result = try loop.runTurnWith(
        allocator,
        client.asModelClient(),
        registry,
        &transcript,
        prompt,
        .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    return .{ .result = result, .transcript = transcript };
}

fn setSessionCapture(session: *agent.AgentSession, sink: ?*capture_sink.CaptureSink) !void {
    switch (session.backend) {
        .local => |*client| client.capture = sink,
        .anthropic => |*client| client.capture = sink,
        .openai => |*client| client.capture = sink,
        .deepseek => |*client| client.capture = sink,
        .stub => return error.UnsupportedRecordingProvider,
    }
}

/// Borrowed env-var read (no allocation), mirroring agent.zig's `envVar`:
/// std.process env helpers are not the 0.16 path; std.c.getenv is.
fn envValue(name_z: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name_z) orelse return null;
    const v = std.mem.sliceTo(raw, 0);
    return if (v.len == 0) null else v;
}

fn recordingRequested() bool {
    const flag = envValue("ZTTP_CODEGEN_RECORD") orelse return false;
    return std.mem.eql(u8, flag, "1");
}

const LiveCorpusMode = enum { record, qualify };

fn qualificationRequested() bool {
    const flag = envValue("ZTTP_CODEGEN_QUALIFY") orelse return false;
    return std.mem.eql(u8, flag, "1");
}

fn liveCorpusModeFrom(record: bool, qualify: bool) !?LiveCorpusMode {
    if (record and qualify) return error.ConflictingLiveCorpusModes;
    if (record) return .record;
    if (qualify) return .qualify;
    return null;
}

fn requestedLiveCorpusMode() !?LiveCorpusMode {
    return liveCorpusModeFrom(recordingRequested(), qualificationRequested());
}

test "recording and qualification modes are distinct" {
    try testing.expectEqual(LiveCorpusMode.record, (try liveCorpusModeFrom(true, false)).?);
    try testing.expectEqual(LiveCorpusMode.qualify, (try liveCorpusModeFrom(false, true)).?);
    try testing.expect((try liveCorpusModeFrom(false, false)) == null);
    try testing.expectError(error.ConflictingLiveCorpusModes, liveCorpusModeFrom(true, true));
}

fn greenRecordingRequired() bool {
    const flag = envValue("ZTTP_CODEGEN_REQUIRE_GREEN") orelse return false;
    return std.mem.eql(u8, flag, "1");
}

/// `required` stays a parameter rather than an `if` at the call site: the only
/// call site is inside the live-gated recorder test, so guarding there leaves
/// "a non-required run refuses nothing" with no offline assertion at all. That
/// branch is the one that keeps the measured-failure corpus behind
/// docs/convergence.md and docs/coverage.md populated.
fn requireGreenRecording(required: bool, applied_change_set: bool, intent_passed: bool) !void {
    if (!required) return;
    if (!applied_change_set) return error.RecordedEditNotApplied;
    if (!intent_passed) return error.RecordedIntentCheckFailed;
}

test "required-green recording refuses unapplied and failed-intent turns" {
    // A non-required run accepts a turn that applied no edit and failed its
    // intent check. Without this line the not-required branch is untested.
    try requireGreenRecording(false, false, false);
    try requireGreenRecording(true, true, true);
    try testing.expectError(
        error.RecordedEditNotApplied,
        requireGreenRecording(true, false, true),
    );
    try testing.expectError(
        error.RecordedIntentCheckFailed,
        requireGreenRecording(true, true, false),
    );
}

// Smoke test: prove the production Anthropic record tee writes a cassette that
// replays to the same reply. The wire response is loopback-local so harness
// changes never need provider credit merely to reach capture and replay.
test "record-tee captures a faithful anthropic cassette offline" {
    // Both provider parsers intentionally use leaky arena JSON parsing because
    // one model turn owns the entire result. Match that production lifetime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const response_body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"OK\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    var server = try cassette_record.LocalHttpServer.init(allocator, response_body, "text/event-stream");
    try server.start();
    errdefer server.join() catch {};
    const endpoint = try server.url(allocator, "/v1/messages");
    defer allocator.free(endpoint);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const record_root = try std.fs.path.resolve(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(record_root);

    var capture = CodegenResponseCapture{
        .allocator = allocator,
        .out_dir = record_root,
        .scenario = "_smoke",
    };
    var sink = capture_sink.CaptureSink{
        .context = &capture,
        .record_fn = CodegenResponseCapture.record,
    };
    var client = anthropic.Client.initWithCapture(.{
        .api_key = "unused-loopback-key",
        .system_prompt = "You are a terse assistant. Reply with exactly one word.",
        .model = "deterministic-recorder-smoke",
        .base_url = endpoint,
    }, &sink);

    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(allocator);
    try tr.append(allocator, .{ .user_text = "Say OK." });

    const live = try client.sendTurn(allocator, &tr, null);
    try server.join();

    // Replay the just-written cassette and confirm it round-trips to a reply.
    const path = try std.fmt.allocPrint(allocator, "{s}/_smoke/step_0.jsonl", .{record_root});
    defer allocator.free(path);
    const cassette = try cassette_client.loadCassetteFromPath(allocator, path);
    const replayed = try cassette_client.replay(allocator, cassette);

    const live_kind = std.meta.activeTag(live.reply.response);
    const replay_kind = std.meta.activeTag(replayed.reply.response);
    try testing.expectEqual(live_kind, replay_kind);
    switch (replayed.reply.response) {
        .final_text => |text| try testing.expectEqualStrings("OK", text),
        else => return error.ExpectedFinalText,
    }
    std.debug.print("[codegen-smoke] live and replay agree: {s}\n", .{@tagName(replay_kind)});
}

const IntentPolicy = union(enum) {
    runtime: codegen.IntentCheck,
    compiler_veto_only: []const u8,
};

fn runtimeIntent(policy: IntentPolicy) ?codegen.IntentCheck {
    return switch (policy) {
        .runtime => |intent| intent,
        .compiler_veto_only => null,
    };
}

const RecordCase = struct {
    name: []const u8,
    prompt: []const u8,
    seed_files: []const codegen.SeedFile = &.{},
    /// The recorded first-attempt-green outcome, locked in after recording. The
    /// offline ratchet asserts replay reproduces exactly this, so a case the agent
    /// currently fails is a valid, pinned corpus entry (it feeds the gap
    /// histogram) - not a broken test.
    expect_first_attempt_green: bool = true,
    /// Whether the committed handler for this case is expected to pass its
    /// declared runtime intent, locked in after recording exactly like
    /// `expect_first_attempt_green` above.
    ///
    /// The durable-intent test used to require a pass from every case. That
    /// made a corpus unpublishable the moment it honestly recorded an intent
    /// failure - and docs/convergence.md pins
    /// `workflow-nested-dispatch-avoidance` as an accepted failure by name, so
    /// the corpus the protocol describes could not pass its own test.
    ///
    /// The artifact cannot answer this on its own: a case can apply an edit and
    /// still miss its intent, and run 4 recorded exactly that shape, so the
    /// presence of `expected/handler.ts` does not discriminate.
    ///
    /// A mismatch either way is a real signal. Pinned true and now failing
    /// means the runtime broke a handler that worked. Pinned false and now
    /// passing means the gap closed and the pin owes an update.
    expect_committed_intent_pass: bool = true,
    /// Runtime evidence or an explicit reason this case cannot execute. The
    /// union prevents a missing spec from being represented as an executable
    /// case and prevents a runtime spec from carrying an unsupported reason.
    intent: IntentPolicy,
    /// How the turn starts. `whole_file` hands the agent an empty workspace and
    /// asks for a handler; `holes` seeds a skeleton whose response expressions
    /// are `hole()` and asks for them to be filled one at a time.
    ///
    /// Roadmap item 3 predicts round-trips to first green fall for hole mode
    /// against whole-file mode on the same model, and nothing could measure it:
    /// the corpus held no hole-mode session, and a cassette replay cannot
    /// produce a turn nobody recorded. The two modes are reported apart so the
    /// comparison is a published number rather than an argument.
    mode: Mode = .whole_file,
};

pub const Mode = codegen_types.InputMode;

fn workspaceCaptureAllowlist(
    allocator: std.mem.Allocator,
    seed_files: []const codegen.SeedFile,
) ![]const []const u8 {
    var count: usize = 1;
    for (seed_files) |seed| {
        if (!std.mem.eql(u8, seed.path, "handler.ts")) count += 1;
    }
    const paths = try allocator.alloc([]const u8, count);
    paths[0] = "handler.ts";
    var index: usize = 1;
    for (seed_files) |seed| {
        if (std.mem.eql(u8, seed.path, "handler.ts")) continue;
        paths[index] = seed.path;
        index += 1;
    }
    return paths;
}

const IntentCheckFn = *const fn (
    std.mem.Allocator,
    codegen.IntentCheck,
    []const u8,
    []const u8,
) codegen.IntentOutcome;

fn requireRecordedIntent(
    allocator: std.mem.Allocator,
    intent: ?codegen.IntentCheck,
    workspace_abs: []const u8,
    zttp_bin: ?[]const u8,
    run_intent_check: IntentCheckFn,
) !void {
    const declared = intent orelse return;
    const bin = zttp_bin orelse return error.IntentCheckUnavailable;
    if (run_intent_check(allocator, declared, workspace_abs, bin) != .passed) {
        return error.RecordedIntentCheckFailed;
    }
}

test "workspace capture allowlist includes handler and seed paths once" {
    const paths = try workspaceCaptureAllowlist(testing.allocator, &.{
        .{ .path = "handler.ts", .bytes = "seed handler" },
        .{ .path = "lib/settings.ts", .bytes = "seed settings" },
    });
    defer testing.allocator.free(paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("handler.ts", paths[0]);
    try testing.expectEqualStrings("lib/settings.ts", paths[1]);
}

test "empirical recording requires declared intent to pass" {
    const intent: codegen.IntentCheck = .{ .tests_jsonl = "fixture" };
    const Probe = struct {
        fn passed(_: std.mem.Allocator, _: codegen.IntentCheck, _: []const u8, _: []const u8) codegen.IntentOutcome {
            return .passed;
        }

        fn failed(_: std.mem.Allocator, _: codegen.IntentCheck, _: []const u8, _: []const u8) codegen.IntentOutcome {
            return .failed;
        }

        fn notChecked(_: std.mem.Allocator, _: codegen.IntentCheck, _: []const u8, _: []const u8) codegen.IntentOutcome {
            return .not_checked;
        }
    };

    try requireRecordedIntent(testing.allocator, null, "/workspace", null, Probe.failed);
    try testing.expectError(
        error.IntentCheckUnavailable,
        requireRecordedIntent(testing.allocator, intent, "/workspace", null, Probe.passed),
    );
    try testing.expectError(
        error.RecordedIntentCheckFailed,
        requireRecordedIntent(testing.allocator, intent, "/workspace", "/zttp", Probe.failed),
    );
    try testing.expectError(
        error.RecordedIntentCheckFailed,
        requireRecordedIntent(testing.allocator, intent, "/workspace", "/zttp", Probe.notChecked),
    );
    try requireRecordedIntent(testing.allocator, intent, "/workspace", "/zttp", Probe.passed);
}

test "first attempt expectations are provider qualified" {
    try testing.expectEqual(
        @as(?bool, false),
        firstAttemptExpectation(.local, false, true),
    );
    try testing.expectEqual(
        @as(?bool, null),
        firstAttemptExpectation(.local, null, true),
    );
    try testing.expectEqual(
        @as(?bool, true),
        firstAttemptExpectation(.anthropic, null, true),
    );
}

fn firstAttemptExpectation(
    provider: agent.Provider,
    recorded: ?bool,
    claude_expectation: bool,
) ?bool {
    if (recorded) |expectation| return expectation;
    return if (provider == .anthropic) claude_expectation else null;
}

/// The headline model for the published convergence number.
///
/// Derived from the product default rather than written down twice, so the
/// number always describes the model a user actually gets. `ZTTP_CODEGEN_MODEL`
/// overrides it for a cheap harness run (e.g. Haiku) or to record a second row
/// against a different tier.
pub const headline_model = models.defaultForProvider(headline_provider).id;

/// Model-visible identity of the frozen headline input. Expected and observed
/// outcomes are unrepresentable here: the constructor reads only case names,
/// prompts, seed paths/bytes, and turn modes.
pub fn headlineInputIdentity() evidence_identity.HeadlineInputIdentity {
    const seed_count = comptime blk: {
        var total: usize = 0;
        for (record_corpus) |rc| total += rc.seed_files.len;
        break :blk total;
    };
    var seeds: [seed_count]codegen_types.SeedFile = undefined;
    var cases: [record_corpus.len]evidence_identity.HeadlineCase = undefined;
    var seed_index: usize = 0;
    for (record_corpus, 0..) |rc, case_index| {
        const first_seed = seed_index;
        for (rc.seed_files) |seed| {
            seeds[seed_index] = seed;
            seed_index += 1;
        }
        cases[case_index] = .{
            .name = rc.name,
            .prompt = rc.prompt,
            .seed_files = seeds[first_seed..seed_index],
            .mode = rc.mode,
        };
    }
    return evidence_identity.headlineInput(&cases);
}

pub fn intentSuiteIdentity() evidence_identity.IntentSuiteIdentity {
    var scenarios: [record_corpus.len]evidence_identity.IntentScenario = undefined;
    for (record_corpus, 0..) |rc, index| {
        scenarios[index] = switch (rc.intent) {
            .runtime => |intent| .{ .runtime = .{
                .name = rc.name,
                .spec = intent.tests_jsonl,
                .runner = "zttp-test-runtime-scenario-v1",
                .handler_path = intent.handler_path,
                .config = intent.zttp_json,
                .runtime_files = intent.runtime_files,
            } },
            .compiler_veto_only => |reason| .{ .compiler_veto_only = .{
                .name = rc.name,
                .reason = reason,
            } },
        };
    }
    return evidence_identity.intentSuite(&scenarios);
}

pub fn securityProbeIdentity() evidence_identity.SecurityProbeCorpusIdentity {
    return security_probes.identity();
}

pub fn thresholdIdentity() evidence_identity.ThresholdIdentity {
    var outcomes: [record_corpus.len]evidence_identity.ExpectedOutcome = undefined;
    for (record_corpus, 0..) |rc, index| {
        outcomes[index] = .{
            .scenario = rc.name,
            .metric = .first_attempt_green,
            .verdict = if (rc.expect_first_attempt_green) .pass else .fail,
        };
    }
    return evidence_identity.thresholds(&outcomes, &.{
        .{ .name = "raw-first-draft-passes", .comparison = .at_least, .value = 14 },
        .{ .name = "final-green", .comparison = .exactly, .value = 19 },
        .{ .name = "runtime-intent-passes", .comparison = .exactly, .value = 18 },
        .{ .name = "median-roundtrips", .comparison = .at_most, .value = 4 },
        .{ .name = "empty-responses", .comparison = .exactly, .value = 0 },
        .{ .name = "timeout-failures", .comparison = .exactly, .value = 0 },
        .{ .name = "decode-failures", .comparison = .exactly, .value = 0 },
        .{ .name = "provider-failures", .comparison = .exactly, .value = 0 },
        .{ .name = "internal-failures", .comparison = .exactly, .value = 0 },
        .{ .name = "qualification-runs", .comparison = .exactly, .value = qualification.required_runs },
    });
}

pub fn evaluationManifestIdentity() evidence_identity.ManifestIdentity {
    return evidence_identity.manifest(.{
        .headline_input = headlineInputIdentity(),
        .intent_suite = intentSuiteIdentity(),
        .security_probes = securityProbeIdentity(),
        .thresholds = thresholdIdentity(),
    });
}

/// Compatibility accessor for the existing JSON field. It is now the frozen
/// model-visible input identity, not an aggregate containing expectations.
pub fn corpusVersion() [64]u8 {
    return headlineInputIdentity().bytes;
}

test "evaluation identities are deterministic and the corpus accessor is input only" {
    const headline = headlineInputIdentity();
    const intents = intentSuiteIdentity();
    const probes = securityProbeIdentity();
    const expected = thresholdIdentity();
    const aggregate = evaluationManifestIdentity();

    try testing.expect(headline.eql(headlineInputIdentity()));
    try testing.expect(intents.eql(intentSuiteIdentity()));
    try testing.expect(probes.eql(securityProbeIdentity()));
    try testing.expect(expected.eql(thresholdIdentity()));
    try testing.expect(aggregate.eql(evaluationManifestIdentity()));
    try testing.expectEqualSlices(u8, &headline.bytes, &corpusVersion());
}

test "intent cohort is explicit and non-vacuous" {
    var executable: usize = 0;
    var compiler_veto_only: usize = 0;
    for (record_corpus) |rc| switch (rc.intent) {
        .runtime => {
            executable += 1;
        },
        .compiler_veto_only => |reason| {
            try testing.expectEqualStrings("parallel-secret", rc.name);
            try testing.expect(reason.len > 0);
            compiler_veto_only += 1;
        },
    };
    try testing.expectEqual(@as(usize, 18), executable);
    try testing.expectEqual(@as(usize, 1), compiler_veto_only);
    try testing.expect(security_probes.corpus.len > 0);
}

// The corpus spans common tasks the agent handles cleanly and harder ones that
// probe known gap areas (user-input egress, websocket events, durable
// workflows). Each elicits realistic multi-roundtrip behaviour (explore then
// edit) and records as step_0/step_1/...
//
// Eighteen of the nineteen cases carry executable runtime intent. The five
// durable and workflow cases use the scenario header to own a private durable
// store, optional queue/system backend, and exact event evidence. Auxiliary
// system handlers are written only after the model turn, so they cannot affect
// the authored prompt cohort. `parallel-secret` is intentionally compiler-only
// for the reason given at that case.
//
// The last five cases were added because eleven could not separate nine
// consecutive builds - every row read 90%, which was the corpus reporting its
// own resolution rather than the compiler holding still. Each targets one fence
// docs/convergence.md names as invisible to the original eleven: none of them
// logged a timestamp, none returned a value read from a store, none wrote the
// shapes the flow-checker fail-opens hid behind. A fence no case stands on
// cannot move a number.
/// Restrict the model-facing tool catalog to a comma-separated allowlist in
/// `ZTTP_CODEGEN_TOOLS`, for measuring whether a smaller preamble changes
/// convergence. Unset leaves every registered tool in place, which is the
/// shape every committed recording was made under.
///
/// The original motivating measurement found 37 tools and roughly 21 KB of
/// provider schemas while recorded traces called eight. The frozen production
/// catalog now exposes 21 tools and 11.2-11.8 KB depending on provider shape;
/// this filter remains an experiment only and cannot publish evidence.
///
/// Two things this deliberately does not do. It never drops `propose_change_set`,
/// which `tool_catalog` emits ahead of the registry and is the only way an
/// edit reaches the veto. And it fails on a name that matches nothing rather
/// than silently keeping fewer tools than asked for - a typo'd allowlist that
/// quietly shrank the catalog further would read as a stronger result than it
/// is.
fn applyToolAllowlist(registry: *registry_mod.Registry) !void {
    const raw = envValue("ZTTP_CODEGEN_TOOLS") orelse return;
    var kept: usize = 0;
    const before = registry.entries.items.len;

    var wanted = std.mem.splitScalar(u8, raw, ',');
    while (wanted.next()) |name_raw| {
        const name = std.mem.trim(u8, name_raw, " \t");
        if (name.len == 0) continue;
        const definition = registry.findByName(name);
        if (definition == null or !definition.?.allowedOn(.model)) {
            std.debug.print("[codegen-tools] no model-visible tool named '{s}'\n", .{name});
            return error.UnknownToolInAllowlist;
        }
    }

    var index: usize = 0;
    while (index < registry.entries.items.len) {
        const entry_name = registry.entries.items[index].name;
        var allowed = false;
        var scan = std.mem.splitScalar(u8, raw, ',');
        while (scan.next()) |candidate| {
            if (std.mem.eql(u8, std.mem.trim(u8, candidate, " \t"), entry_name)) {
                allowed = true;
                break;
            }
        }
        if (allowed) {
            index += 1;
            kept += 1;
        } else {
            _ = registry.entries.orderedRemove(index);
        }
    }

    std.debug.print(
        "[codegen-tools] catalog restricted: {d} of {d} tools kept\n",
        .{ kept, before },
    );
}

/// Wall-clock ceiling on one recorded turn. A local model server is the
/// recording backend now, and a stalled generation there is silence rather
/// than an error, so an uncapped turn takes the whole corpus run with it.
/// `ZTTP_CODEGEN_TURN_TIMEOUT_MS` overrides it; zero restores the old
/// unbounded behavior for a case that legitimately needs longer.
const default_record_turn_timeout_ms: u64 = 180_000;

const queued_call_runtime_files = [_]codegen.SeedFile{
    .{
        .path = "intent-system.json",
        .bytes =
        \\{"version":1,"handlers":[
        \\  {"name":"greet","path":"intent-greet.ts","baseUrl":"https://greet.internal"}
        \\]}
        ,
    },
    .{
        .path = "intent-greet.ts",
        .bytes =
        \\function handler(req) {
        \\  return Response.json({ from: "greet-child", path: req.path });
        \\}
        ,
    },
};

const nested_dispatch_runtime_files = [_]codegen.SeedFile{
    .{
        .path = "intent-system.json",
        .bytes =
        \\{"version":1,"handlers":[
        \\  {"name":"notify","path":"intent-notify.ts","baseUrl":"https://notify.internal"}
        \\]}
        ,
    },
    .{
        .path = "intent-notify.ts",
        .bytes =
        \\function handler(req) {
        \\  return Response.json({ notified: "notify-child", path: req.path });
        \\}
        ,
    },
};

const saga_runtime_files = [_]codegen.SeedFile{
    .{
        .path = "intent-system.json",
        .bytes =
        \\{"version":1,"handlers":[
        \\  {"name":"inventory","path":"intent-inventory.ts","baseUrl":"https://inventory.internal"},
        \\  {"name":"billing","path":"intent-billing.ts","baseUrl":"https://billing.internal"},
        \\  {"name":"shipping","path":"intent-shipping.ts","baseUrl":"https://shipping.internal"}
        \\]}
        ,
    },
    .{
        .path = "intent-inventory.ts",
        .bytes =
        \\function handler(req) {
        \\  if (req.path === "/release") return Response.json({ marker: "release-compensation" });
        \\  return Response.json({ marker: "reserve-complete" });
        \\}
        ,
    },
    .{
        .path = "intent-billing.ts",
        .bytes =
        \\function handler(req) {
        \\  if (req.path === "/refund") return Response.json({ marker: "refund-compensation" });
        \\  return Response.json({ marker: "charge-complete" });
        \\}
        ,
    },
    .{
        .path = "intent-shipping.ts",
        .bytes =
        \\function handler(req) {
        \\  return Response.json({ marker: "ship-failure" }, { status: 503 });
        \\}
        ,
    },
};

const record_corpus = [_]RecordCase{
    .{
        .name = "health",
        .prompt = "Create a handler in handler.ts that responds to GET /health with " ++
            "Response.json({ ok: true }). Keep it minimal and deterministic.",
        .expect_first_attempt_green = true,
        // Asserts the task the prompt names, not the shape of one recording: a
        // different-but-correct handler must still pass, or the check measures
        // the cassette instead of the model.
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"GET /health reports ok"}
            \\{"type":"request","method":"GET","url":"/health","headers":{},"body":""}
            \\{"type":"expect","status":200,"bodyContains":"\"ok\":true"}
            \\
            ,
        } },
    },
    .{
        .name = "validate-body",
        .prompt = "Create a handler in handler.ts that decodes the JSON request body with " ++
            "zttp:validate against a schema named \"item\" requiring a string field \"name\", " ++
            "returns the validated data on success, and returns a 400 with the errors on failure.",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"a body missing name is rejected"}
            \\{"type":"request","method":"POST","url":"/","headers":{"content-type":"application/json"},"body":"{}"}
            \\{"type":"expect","status":400}
            \\
            ,
        } },
        // The corpus's one accepted failure, and the reason the published
        // first-draft rate reads 10/11 rather than 11/11.
        //
        // The first draft writes `result.value as Item`, and the subset has no
        // `as`: the stripper rejects it as ZTS042, which is what the
        // [codegen-gap] histogram prints. The case still reaches green - the
        // model drops the assertion on retry - so it is a first-draft failure,
        // not a broken case.
        //
        // The teaching gap this ranks is therefore `as`, not the shape of
        // `validateJson().errors`. The draft does also declare
        // `errors: string[]` where the value is statically `unknown`, but the
        // veto reports the assertion first and the model never reaches the
        // type mismatch. An earlier version of this comment named ZTS200 and
        // that second gap; it described a draft this cassette no longer holds.
        .expect_first_attempt_green = true,
    },
    .{
        .name = "jwt-auth",
        .prompt = "Create a handler in handler.ts that requires a bearer JWT using zttp:auth " ++
            "with the secret from env JWT_SECRET, returns 401 when the token is missing or invalid, " ++
            "and otherwise returns Response.json({ authenticated: true }). Never return the " ++
            "verified claims or secret, and never use a fallback secret.",
        // An invalid bearer token makes the secret lookup mandatory regardless
        // of whether the handler checks configuration before or after parsing
        // the header. The old missing-token request still declared an exact env
        // I/O event; a correct header-first handler returned 401 without reading
        // env, leaving the mock unconsumed and failing intent for call order
        // rather than behavior.
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with an invalid bearer token is unauthorized"}
            \\{"type":"request","method":"GET","url":"/","headers":{"authorization":"Bearer invalid-token"},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["JWT_SECRET"],"result":"test-signing-secret"}
            \\{"type":"expect","status":401}
            \\
            ,
        } },
        // This case caught label laundering through JSON round-tripping and
        // then through validateJson. Both are closed; a verified claims value
        // remains credential-labelled and cannot enter a response. The corpus
        // must therefore ask for the valid public confirmation envelope it is
        // meant to measure. Asking for raw claims and accepting a confirmation
        // instead would count a dropped requirement as convergence, which the
        // phase-7 gate explicitly forbids.
        .expect_first_attempt_green = true,
    },
    .{
        .name = "weather-egress",
        .prompt = "Create a handler in handler.ts that reads a `city` query parameter and " ++
            "fetches the current weather for that city from https://api.open-meteo.com/v1/forecast " ++
            "using zttp:fetch, returning the JSON response.",
        // The success path needs egress, which the offline replay has no way to
        // serve. The missing-parameter path is the part of the task that can be
        // demonstrated without a network, so that is what this asserts.
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with no city is rejected"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":400}
            \\
            ,
        } },
        // Was ZTS602 (never converged); closed by the literal-URL + init-query
        // egress teaching.
        .expect_first_attempt_green = true,
    },
    .{
        .name = "durable-order",
        // The prompt states the observable contract the intent test asserts.
        // It used to name only the two steps, while the test demanded a 201, a
        // `reserved`/`charged` body, and step results carrying `reservationId`
        // and `chargeId` - none of which a reader of the prompt could derive.
        // A case whose test asks for more than its prompt says measures
        // guessing, not convergence.
        // Second pass. Stating the 201 and the body fields fixed those, and the
        // case still failed four runs running on the one thing left ambiguous:
        // the test asserts the step's recorded RESULT contains "reservationId",
        // which needs the step to return an object carrying that key. "a
        // reserve step returning a reservationId" reads as returning the id
        // value, and that is what the model wrote twice - binding it to a
        // variable of that name, which the recorded result never sees.
        //
        // Verified before recording: a handler whose steps return
        // { reservationId } and { chargeId } passes this spec 3/3.
        .prompt = "Create a durable handler in handler.ts using zttp:durable that runs a " ++
            "two-step order workflow via run() and step(): a `reserve` step returning " ++
            "{ reservationId }, then a `charge` step returning { chargeId }. Respond 201 " ++
            "with a body carrying reserved and charged as true.",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"runtime","durable":true,"workflowQueue":false}
            \\{"type":"test","name":"the order runs reserve then charge"}
            \\{"type":"request","method":"POST","url":"/","headers":{"idempotency-key":"order-1"},"body":null}
            \\{"type":"expect","status":201,"bodyContains":"\"charged\":true"}
            \\{"type":"test","name":"the completed order replays without duplicate steps"}
            \\{"type":"request","method":"POST","url":"/","headers":{"idempotency-key":"order-1"},"body":null}
            \\{"type":"expect","status":201,"bodyContains":"\"reserved\":true"}
            \\{"type":"expect-run","runKey":"order-1","complete":true}
            \\{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"reserve"}
            \\{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"reserve","resultContains":"reservationId"}
            \\{"type":"expect-event","runKey":"order-1","kind":"step_start","name":"charge"}
            \\{"type":"expect-event","runKey":"order-1","kind":"step_result","name":"charge","resultContains":"chargeId"}
            \\{"type":"expect-signals","count":0}
            \\
            ,
        } },
        // Was ZTS042/narrowing death-spiral (never converged); closed by the
        // "use untyped values directly, never narrow with as/guards" teaching.
        .expect_first_attempt_green = true,
    },
    .{
        .name = "workflow-queued-call",
        // "dispatch a greet child handler" read as an instruction to write one,
        // and the model created `greet.ts` - which the recorder refuses, because
        // the capture allowlist is handler.ts plus the case's seed_files and
        // this case seeds nothing at draft time. The whole case then aborts with
        // an internal UndeclaredWorkspacePath rather than recording an outcome.
        //
        // The child is already registered and resolved from the system registry
        // at run time, so say so. Same omission as saga's: the case provides
        // something the prompt never mentions.
        .prompt = "Create a durable workflow handler in handler.ts using zttp:durable and " ++
            "zttp:workflow. It should read the Idempotency-Key header, enter run(key), " ++
            "and dispatch the already-registered `greet` child handler with workflow.call " ++
            "at durable depth 0, answering with the child's response body. The child " ++
            "handler already exists in the system registry - write only handler.ts.",
        .intent = .{ .runtime = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"system\": \"intent-system.json\"\n}\n",
            .runtime_files = &queued_call_runtime_files,
            .tests_jsonl =
            \\{"type":"runtime","durable":true,"workflowQueue":true}
            \\{"type":"test","name":"the queued greet child is dispatched"}
            \\{"type":"request","method":"GET","url":"/","headers":{"idempotency-key":"queued-1"},"body":null}
            \\{"type":"expect","status":200,"bodyContains":"greet-child"}
            \\{"type":"expect-run","runKey":"queued-1","complete":true}
            \\{"type":"expect-event","runKey":"queued-1","kind":"step_start","name":"workflow.call#0"}
            \\{"type":"expect-event","runKey":"queued-1","kind":"step_result","name":"workflow.call#0","resultContains":"greet-child"}
            \\{"type":"expect-queue","runKey":"queued-1","step":"workflow.call#0","status":200,"bodyContains":"greet-child"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },
    .{
        .name = "workflow-nested-dispatch-avoidance",
        // Same omission, same internal abort: the model wrote `notify.ts` and
        // the recorder refused the capture, so run 5 recorded no outcome for
        // this case at all.
        .prompt = "Create a durable order workflow in handler.ts. Reserve inventory with a " ++
            "durable step that returns the reservation response, then dispatch the " ++
            "already-registered `notify` child handler with workflow.call after the step " ++
            "completes. Keep the child dispatch outside the step callback. Respond 201 with " ++
            "a body carrying notified as the child call's status code. The child handler " ++
            "already exists in the system registry - write only handler.ts.",
        .intent = .{ .runtime = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"system\": \"intent-system.json\"\n}\n",
            .runtime_files = &nested_dispatch_runtime_files,
            .tests_jsonl =
            \\{"type":"runtime","durable":true,"workflowQueue":true}
            \\{"type":"test","name":"notify dispatch occurs outside the durable step"}
            \\{"type":"request","method":"POST","url":"/","headers":{"idempotency-key":"nested-1"},"body":"{\"sku\":\"one\"}"}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://inventory.internal/reserve"],"result":{"status":200,"body":"{\"reserved\":true}"}}
            \\{"type":"expect","status":201,"bodyContains":"\"notified\":200"}
            \\{"type":"expect-run","runKey":"nested-1","complete":true}
            \\{"type":"expect-event","runKey":"nested-1","kind":"step_start","name":"reserve"}
            \\{"type":"expect-event","runKey":"nested-1","kind":"step_result","name":"reserve","resultContains":"reserved"}
            \\{"type":"expect-event","runKey":"nested-1","kind":"step_start","name":"workflow.call#0"}
            \\{"type":"expect-event","runKey":"nested-1","kind":"step_result","name":"workflow.call#0","resultContains":"notify-child"}
            \\{"type":"expect-queue","runKey":"nested-1","step":"workflow.call#0","status":200,"bodyContains":"notify-child"}
            \\
            ,
        } },
        // Flipped to false on the 2026-08-03 re-record, and back to true on
        // 2026-08-04 when the compiler defect that caused the failure was
        // fixed. Both flips are worth keeping, because they say different
        // things.
        //
        // The re-record was the model drawing a different first draft between
        // two recordings of the same prompt: a much larger program that trips
        // ZTS204. Re-recording until the old outcome came back would have been
        // selecting the sample that flatters the rate, so the worse outcome was
        // pinned.
        //
        // Reading what it tripped on is what found the defect. The cassette's
        // next turn says it plainly - "ZTS204 on line 88, the Response.json(...)
        // call inside run()" - and that return is inside the `run` callback, a
        // nested arrow with no signature of its own. The checker left the
        // enclosing handler's declared return type in place for it, so a
        // correct inner return was measured against the outer contract. The
        // draft was right and the compiler was wrong, and the round-trip the
        // model spent working around it is the cost of that.
        .expect_first_attempt_green = true,
        // Measured, not chosen: the recording that produced the committed
        // corpus applied no edit for this case, so there is no handler to run
        // and the intent cannot pass. docs/convergence.md already pins this case
        // as the precedent accepted failure. Flip this back when a recording
        // measures it passing, and say what closed the gap.
        .expect_committed_intent_pass = false,
    },
    .{
        .name = "workflow-saga-compensation",
        // The case named no service, and its support files are `runtime_files`,
        // which `writeRuntimeFiles` materializes inside `runIntentCheck` - after
        // the model has drafted. So `intent-system.json` and the three seeded
        // handlers do not exist in the workspace while it writes, and the test
        // asserts step results carrying markers only those handlers produce.
        // The case was unpassable except by guessing three names it was never
        // given, which run 1 happened to do and later runs did not.
        //
        // Naming them matches both siblings, which keep their support files
        // runtime-only and name the service in the prompt: queued-call says
        // "a greet child handler", nested-dispatch says "inventory" and
        // "notify". Seeding at draft time instead would have made this the one
        // workflow case that discovers its registry rather than being told it.
        //
        // Verified before recording: a handler dispatching these services on
        // these paths, requiring no request body, and answering with the saga
        // outcome passes this spec 2/2 - and `do:`/`undo:` step names are
        // derived from each entry's `name`, so the prompt does not state them.
        .prompt = "Create a handler in handler.ts using zttp:workflow saga() for reserve, " ++
            "charge, and ship steps, taking the run key from the idempotency-key header " ++
            "and reading no request body. Each step dispatches to a co-located handler " ++
            "with call(): reserve to \"inventory\" at /reserve, charge to \"billing\" at " ++
            "/charge, ship to \"shipping\" at /ship. Include compensate functions for every " ++
            "non-last static saga step so the saga compensation proof can pass - reserve " ++
            "compensates to \"inventory\" at /release and charge to \"billing\" at /refund. " ++
            "Answer with the saga outcome in the response body.",
        .intent = .{ .runtime = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"system\": \"intent-system.json\"\n}\n",
            .runtime_files = &saga_runtime_files,
            .tests_jsonl =
            \\{"type":"runtime","durable":true,"workflowQueue":false}
            \\{"type":"test","name":"shipping failure compensates charge then reserve"}
            \\{"type":"request","method":"POST","url":"/","headers":{"idempotency-key":"saga-1"},"body":null}
            \\{"type":"expect","bodyContains":"outcome"}
            \\{"type":"expect-run","runKey":"saga-1","complete":true}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_start","name":"do:reserve"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_result","name":"do:reserve","resultContains":"reserve-complete"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_start","name":"do:charge"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_result","name":"do:charge","resultContains":"charge-complete"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_start","name":"do:ship"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_result","name":"do:ship","resultContains":"ship-failure"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_start","name":"undo:charge"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_result","name":"undo:charge","resultContains":"refund-compensation"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_start","name":"undo:reserve"}
            \\{"type":"expect-event","runKey":"saga-1","kind":"step_result","name":"undo:reserve","resultContains":"release-compensation"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
        // Back to true on the 2026-08-26 re-record, having been false since
        // 2026-08-25. The pin records what one recording measured, so it moves
        // when a recording measures something else, in the same commit as the
        // cassettes.
        //
        // The 2026-08-25 draft compensated correctly - it answered 503 with
        // {"ok":false,"failed":"ship","compensated":true} - but omitted the
        // literal key "outcome", which is the spec's first assertion and a word
        // the prompt never says it wants. The test stopped there, so that
        // recording measured nothing about the step and compensation events
        // after it. This draft satisfies the assertion and the run reaches
        // them, so the case is intent-qualified.
        //
        // The underlying mismatch is not fixed: the spec still asserts a key
        // shape the prompt does not state, so which side of the pin this case
        // lands on is a property of the draft rather than of the handler being
        // right. Closing it needs the spec and the prompt to agree on the
        // answer's shape, which changes the request identity and so belongs to
        // a deliberate re-record, not to this one.
        .expect_committed_intent_pass = true,
    },
    .{
        .name = "workflow-wait-signal",
        // Same defect as durable-order. The test drives POST on both paths and
        // expects 202 on park, 200 on resume, and an "approval" signal name;
        // the prompt named no method, no status, and no signal name. The last
        // recording restricted /wait to GET, which the prompt never forbade,
        // and every request in the test then missed the route.
        .prompt = "Create a durable approval workflow in handler.ts using waitSignal and " ++
            "signal, both paths served on POST. POST /wait parks a run under the " ++
            "Idempotency-Key header waiting on a signal named `approval`, answering 202 " ++
            "until it resumes and 200 with approved true once it has. POST /signal " ++
            "delivers an approval payload carrying approved true to the same key and " ++
            "answers 200 with delivered true.",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"runtime","durable":true,"workflowQueue":false}
            \\{"type":"test","name":"the approval run parks"}
            \\{"type":"request","method":"POST","url":"/wait","headers":{"Idempotency-Key":"approval-1"},"body":null}
            \\{"type":"expect","status":202,"bodyContains":"signal"}
            \\{"type":"test","name":"the approval signal is delivered"}
            \\{"type":"request","method":"POST","url":"/signal","headers":{"Idempotency-Key":"approval-1"},"body":null}
            \\{"type":"expect","status":200,"bodyContains":"\"delivered\":true"}
            \\{"type":"test","name":"the parked run resumes with approval"}
            \\{"type":"request","method":"POST","url":"/wait","headers":{"Idempotency-Key":"approval-1"},"body":null}
            \\{"type":"expect","status":200,"bodyContains":"\"approved\":true"}
            \\{"type":"expect-run","runKey":"approval-1","complete":true}
            \\{"type":"expect-event","runKey":"approval-1","kind":"wait_signal","name":"approval"}
            \\{"type":"expect-event","runKey":"approval-1","kind":"resume_signal","name":"approval","payloadContains":"\"approved\":true"}
            \\{"type":"expect-signals","count":0}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },
    .{
        .name = "sql-users",
        .prompt = "Create a handler in handler.ts that returns all users (id and name) from " ++
            "the sqlite database using zttp:sql. The users table has columns id (integer) " ++
            "and name (text).",
        // Seeds the project SQL schema the veto discovers via zttp.json's
        // `sqlite` key (resolved relative to the workspace).
        .seed_files = &.{
            .{ .path = "zttp.json", .bytes = "{\n  \"sqlite\": \"schema.sql\"\n}\n" },
            .{ .path = "schema.sql", .bytes = "CREATE TABLE users (\n  id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL\n);\n" },
        },
        // Supplies its own config: the seeded `sqlite` key is what the veto and
        // the runtime resolve the schema through, and synthesizing a
        // handler-only zttp.json over the top would drop it. The row comes from
        // an io stub rather than a seeded database - the task is to query and
        // shape the response, and stubbing the store is what the spec format is
        // for. Asserting on the stubbed value also proves the rows reach the
        // body, which asserting on the literal "users" would not.
        .intent = .{ .runtime = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"sqlite\": \"schema.sql\"\n}\n",
            .tests_jsonl =
            \\{"type":"test","name":"queried rows reach the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"sql","fn":"sqlMany","args":["list_users"],"result":[{"id":1,"name":"ada"}]}
            \\{"type":"expect","status":200,"bodyContains":"ada"}
            \\
            ,
        } },
        // Recorded with the best model (Sonnet): writes correct SQL, self-checks
        // cleanly, and first-draft-passes. Previously it failed because the
        // property analysis reported read_only as PROVEN for a SELECT and the
        // agent declared it (then ZTS501 rejected it); the classifier now gates
        // declarable read_only on write-effect imports, so the agent is no
        // longer told to declare a property the import forbids.
        .expect_first_attempt_green = true,
    },
    .{
        // Fence: the `deterministic` loosening. The property moved from "was a
        // varying value read" to "does one reach the response", so a handler
        // that logs a clock read and returns a constant keeps it. No case in the
        // original eleven read a clock at all, so that change was invisible
        // here. Verified against the analyzer before recording: this shape
        // proves `deterministic`.
        //
        // The intent spec asserts the body exactly rather than by substring. The
        // whole point is that the timestamp stays out of it, and `bodyContains`
        // would pass a handler that put the clock read in the response too -
        // which is the failure this case exists to catch.
        .name = "log-timestamp",
        .prompt = "Create a handler in handler.ts that logs when it served the request, " ++
            "including the current time from Date.now(), using logInfo from zttp:log. " ++
            "The response body must be exactly Response.json({ ok: true }) - the " ++
            "timestamp belongs in the log and must never appear in the response.",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the timestamp stays out of the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":200,"body":"{\"ok\":true}"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },
    .{
        // Fence: a read from mutable module state is its own varying source,
        // which no capability set can express. Before that rule the handler
        // below proved `deterministic` while returning whatever the last write
        // left in the store. The corpus had nothing that read a store into a
        // response, so the tightening moved nothing.
        //
        // The prompt does not mention determinism or Spec. Noticing that a store
        // read costs the default profile and narrowing the Spec accordingly is
        // the model behaviour being measured; saying it in the prompt would
        // measure instruction-following instead.
        .name = "cache-counter",
        .prompt = "Create a handler in handler.ts that reads the \"hits\" counter from the " ++
            "\"counters\" namespace with cacheGet from zttp:cache and returns it as JSON " ++
            "under a \"hits\" key. Treat a missing counter as \"0\".",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the stored counter reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"cache","fn":"cacheGet","args":["counters","hits"],"result":"41"}
            \\{"type":"expect","status":200,"bodyContains":"41"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },
    .{
        // Fence: labels crossing a module boundary through a caller's callback.
        // `parallel([() => env("SECRET_KEY")])` used to prove clean, because a
        // module export answers with its declared return labels and those cannot
        // describe what a caller's callback produced. See
        // docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md.
        //
        // The result array `parallel` returns carries the union of every
        // callback's labels and indexing does not narrow back, so returning
        // `values[0]` is refused for what `values[1]` read. That much was
        // measured before recording and holds: direct `env` reads with the
        // secret in a local are clean, two non-secret callbacks are clean, so
        // the union is specifically the result array. See
        // docs/solutions/logic-errors/a-label-union-that-never-narrows-refuses-a-clean-program.md.
        //
        // The case was authored pinned to false on the reasoning that no draft
        // could therefore pass. That reasoning was wrong and the recording is
        // what showed it. The model reduced the secret to a boolean *inside* the
        // callback - `checkApiSecret()` returns `{present: bool}`, never the raw
        // value - so nothing carrying the secret label ever crosses the module
        // boundary and there is no union to narrow. It passed first draft.
        //
        // So what this case measures is not the imprecision but the way around
        // it: whether the model contains a secret at the boundary rather than
        // carrying it across and filtering after. Three `edit_simulate` calls
        // preceded the one `propose_change_set`, which is where the shape was found.
        //
        // No intent spec: the response is a bare app name read from an env var,
        // and asserting it would test the env stub rather than the containment
        // this case is about. What matters here is the veto verdict.
        .name = "parallel-secret",
        .prompt = "Create a handler in handler.ts that reads the APP_NAME and API_SECRET " ++
            "environment variables concurrently using parallel() from zttp:io. Return 503 " ++
            "when API_SECRET is not set. Otherwise return Response.json with only the app " ++
            "name - the secret must never appear in the response.",
        .intent = .{
            .compiler_veto_only = "a runtime APP_NAME assertion would only retest the env stub, while the compiler veto proves the secret-containment boundary",
        },
        .expect_first_attempt_green = true,
    },
    .{
        // Fence: the shapes of egress options object the flow checker could not
        // read field by field. `weather-egress` passes its query through the
        // init object, but nothing in the corpus set a method and headers there.
        //
        // It also carries the intent spec `weather-egress` says cannot exist.
        // That comment predates the fetch io stub: runtime_http.zig serves
        // `{"module":"fetch","fn":"fetch"}` from the replay state, so the
        // success path is assertable offline. Checked before recording - a stub
        // with the wrong body fails the assertion, so it is load-bearing.
        .name = "egress-options",
        .prompt = "Create a handler in handler.ts that calls " ++
            "https://api.example.com/v1/status with fetch from zttp:fetch, passing an init " ++
            "object that sets the method to GET and an \"accept: application/json\" header. " ++
            "Return the upstream JSON on success and a 502 when the upstream call fails.",
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the upstream payload reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://api.example.com/v1/status"],"result":{"status":200,"body":"{\"state\":\"green\"}"}}
            \\{"type":"expect","status":200,"bodyContains":"green"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },
    .{
        // Fence: walking a helper imported from a sibling file. Every other case
        // is a single file, so the cross-file label walk had nothing here to
        // stand on. The seeded helper returns a secret from one export and a
        // plain string from the other, so the walk has to distinguish them
        // rather than tainting the module.
        //
        // Verified before recording: returning `apiToken()` trips ZTS400 through
        // the import, and returning only `displayName()` is clean. The intent
        // spec pins the body exactly, so a handler that also returns the token
        // fails the check even in a build where the label walk does not.
        .name = "sibling-helper",
        .prompt = "The file lib/settings.ts already exists and exports displayName() and " ++
            "apiToken(). Create a handler in handler.ts that imports both from " ++
            "\"./lib/settings.ts\", returns 503 when apiToken() is undefined, and otherwise " ++
            "returns Response.json({ name: displayName() }). The token must never appear " ++
            "in the response.",
        .seed_files = &.{
            .{
                .path = "lib/settings.ts",
                .bytes =
                \\import { env } from "zttp:env";
                \\
                \\export structural ApiToken = string | undefined;
                \\export structural DisplayName = string;
                \\
                \\export function apiToken(): ApiToken {
                \\  return env("API_TOKEN");
                \\}
                \\
                \\export function displayName(): DisplayName {
                \\  return env("APP_NAME") ?? "unnamed";
                \\}
                \\
                ,
            },
        },
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the configured name crosses the file boundary and the token does not"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["API_TOKEN"],"result":"tok-secret-value"}
            \\{"type":"io","seq":1,"module":"env","fn":"env","args":["APP_NAME"],"result":"orders-api"}
            \\{"type":"expect","status":200,"body":"{\"name\":\"orders-api\"}"}
            \\
            ,
        } },
        .expect_first_attempt_green = true,
    },

    // ---------------------------------------------------------------------
    // Hole-mode arm. Roadmap item 3's measurement: round-trips to first green
    // for a holed skeleton against the same task written from scratch.
    //
    // Each of these four pairs with the whole-file case of the same task name
    // above, so the comparison holds the task fixed and varies only how the
    // turn starts. The seeded skeleton carries the imports and the branch
    // structure and leaves every response expression a `hole()`; the agent
    // fills them with `zts_expert_fill_hole`, which can only replace the bytes
    // of one hole call, so "one hole per turn" is the shape of the edit rather
    // than an instruction.
    //
    // The confound is worth naming rather than hiding: the hole arm is handed
    // the frame for free, so some of any round-trip saving is work it was not
    // asked to do. That is the mechanism item 3 describes - the compiler
    // constructs the frame and the emittable set per step narrows to one typed
    // expression - not a flaw in the comparison, but it does mean the number
    // measures the mechanism end to end rather than the model's aim alone.
    //
    // Every skeleton was checked before recording: each parses, enumerates both
    // paths, and reports its holes with an `expectedType` and an `inScope`
    // list. `hole()` is typed `never`, so a holed program still proves.
    //
    // Each seed carries the narrow `Proof<T, P>` its finished form needs, and the
    // first recording of this arm is why. Without it the seeds check with a
    // ZTS500 already outstanding, and that quietly broke the comparison in the
    // hole arm's favour.
    //
    // The veto is differential - it asks whether an edit introduces a NEW
    // violation against the file it started from. A seed that already fails a
    // check hands that check a baseline it cannot see past, so filling a hole
    // adds nothing and the veto passes on a program that does not check clean.
    // `zts_expert_fill_hole` replaces the bytes of one `hole()` call and can
    // never touch a signature, so the agent could not have cleared it either.
    // All three non-trivial cases recorded a first-draft pass and then failed
    // their intent check, which is what surfaced it.
    //
    // That is the weak-baseline family again, one level along from
    // docs/solutions/logic-errors/empty-baseline-made-a-file-destroying-edit-prove-clean.md:
    // there an empty baseline stood for an unreadable file, here a baseline
    // carrying the violation stands for a program that does not hold it. A
    // differential check is only as strong as the state it differs against, and
    // seeding that state is the corpus author's job.
    //
    // So the seeds are clean apart from their holes, and the only work the arm
    // measures is producing the right expression - which is the thing the
    // comparison is about.
    //
    // One hole per case, for a second reason the first recordings surfaced.
    // `zts_expert_fill_hole` proposes an edit and re-reads the file from disk
    // on every call, so two fills in one turn do not compose: the second one
    // runs against the original bytes, not against the result of the first. The
    // model said so itself mid-session - "the fill_hole tool is working off the
    // on-disk file (which still has hole 1 unfilled)" - and ended the turn with
    // a hole still in the program. Written up separately; it is a defect in the
    // loop, not in the corpus.
    //
    // Measuring a workflow the loop does not support would report that defect
    // as a round-trip cost and confuse the two. The persona's rule is one hole
    // per turn and the eval gives each case one turn, so one hole per case is
    // what the arm can honestly measure. The multi-hole case belongs in the
    // comparison once fills compose.
    .{
        .name = "health-holes",
        .prompt = "handler.ts has a hole() where its response belongs. Fill it so the " ++
            "handler responds to GET /health with Response.json({ ok: true }). Use " ++
            "zts_expert_query operation holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"GET /health reports ok"}
            \\{"type":"request","method":"GET","url":"/health","headers":{},"body":""}
            \\{"type":"expect","status":200,"bodyContains":"\"ok\":true"}
            \\
            ,
        } },
        .mode = .holes,
        .expect_first_attempt_green = true,
    },
    .{
        .name = "cache-counter-holes",
        .prompt = "handler.ts reads the \"hits\" counter from the \"counters\" namespace and " ++
            "has a hole() on each branch. Fill them so the handler returns the counter as " ++
            "JSON under a \"hits\" key, treating a missing counter as \"0\". Use " ++
            "zts_expert_query operation holes for the frame and zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\import { cacheGet } from "zttp:cache";
                \\
                \\function handler(req: Request): Proof<Response, "retry_safe" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  const hits = cacheGet("counters", "hits");
                \\  if (hits === undefined) {
                \\    return Response.json({ hits: "0" });
                \\  }
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the stored counter reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"cache","fn":"cacheGet","args":["counters","hits"],"result":"41"}
            \\{"type":"expect","status":200,"bodyContains":"41"}
            \\
            ,
        } },
        .mode = .holes,
        .expect_first_attempt_green = true,
    },
    .{
        .name = "egress-options-holes",
        .prompt = "handler.ts already calls the upstream with an init object and has a hole() " ++
            "on each branch. Fill them so it returns the upstream JSON on success and a 502 " ++
            "when the call fails. Use zts_expert_query operation holes for the frame and " ++
            "zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\import { fetch } from "zttp:fetch";
                \\
                \\function handler(req: Request): Proof<Response, "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  const res = fetch("https://api.example.com/v1/status", { method: "GET", headers: { accept: "application/json" } });
                \\  if (!res.ok) {
                \\    return Response.json({ error: "upstream" }, { status: 502 });
                \\  }
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the upstream payload reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://api.example.com/v1/status"],"result":{"status":200,"body":"{\"state\":\"green\"}"}}
            \\{"type":"expect","status":200,"bodyContains":"green"}
            \\
            ,
        } },
        .mode = .holes,
        .expect_first_attempt_green = true,
    },
    .{
        .name = "sibling-helper-holes",
        .prompt = "handler.ts imports displayName() and apiToken() from ./lib/settings.ts and " ++
            "has a hole() on each branch. Fill them so the handler returns 503 when " ++
            "apiToken() is undefined and otherwise Response.json({ name: displayName() }). " ++
            "The token must never appear in the response. Use zts_expert_query operation holes for the " ++
            "frame and zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "lib/settings.ts",
                .bytes =
                \\import { env } from "zttp:env";
                \\
                \\export structural ApiToken = string | undefined;
                \\export structural DisplayName = string;
                \\
                \\export function apiToken(): ApiToken {
                \\  return env("API_TOKEN");
                \\}
                \\
                \\export function displayName(): DisplayName {
                \\  return env("APP_NAME") ?? "unnamed";
                \\}
                \\
                ,
            },
            .{
                .path = "handler.ts",
                .bytes =
                \\import { apiToken, displayName } from "./lib/settings.ts";
                \\
                \\function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  if (apiToken() === undefined) {
                \\    return Response.json({ error: "unconfigured" }, { status: 503 });
                \\  }
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{ .runtime = .{
            .tests_jsonl =
            \\{"type":"test","name":"the configured name crosses the file boundary and the token does not"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["API_TOKEN"],"result":"tok-secret-value"}
            \\{"type":"io","seq":1,"module":"env","fn":"env","args":["APP_NAME"],"result":"orders-api"}
            \\{"type":"expect","status":200,"body":"{\"name\":\"orders-api\"}"}
            \\
            ,
        } },
        .mode = .holes,
        .expect_first_attempt_green = true,
    },
};

test "jwt intent is independent of secret lookup order" {
    const jwt = for (record_corpus) |candidate| {
        if (std.mem.eql(u8, candidate.name, "jwt-auth")) break candidate;
    } else return error.TestExpectedEqual;
    const intent = runtimeIntent(jwt.intent) orelse return error.TestExpectedEqual;

    try testing.expect(std.mem.indexOf(
        u8,
        intent.tests_jsonl,
        "\"authorization\":\"Bearer invalid-token\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        intent.tests_jsonl,
        "\"module\":\"env\",\"fn\":\"env\",\"args\":[\"JWT_SECRET\"]",
    ) != null);
}

test "durable runtime intents match their pinned committed outcome" {
    const names = [_][]const u8{
        "durable-order",
        "workflow-queued-call",
        "workflow-nested-dispatch-avoidance",
        "workflow-saga-compensation",
        "workflow-wait-signal",
    };
    const repo_root = try cwdPathAlloc(testing.allocator);
    defer testing.allocator.free(repo_root);
    const zttp_bin = codegen.locateZttpBinary(testing.allocator, repo_root) orelse
        return error.SkipZigTest;
    defer testing.allocator.free(zttp_bin);

    var passed: usize = 0;
    var checked: usize = 0;
    for (names) |name| {
        const rc = for (record_corpus) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) break candidate;
        } else return error.MissingRuntimeIntentCase;
        const intent = runtimeIntent(rc.intent) orelse return error.MissingRuntimeIntent;

        var resolved = try resolveCurrentCaseStepsForTest(
            testing.allocator,
            repo_root,
            headline_provider,
            name,
        );
        defer resolved.deinit(testing.allocator);
        const flow_case = if (resolved.flow_case) |*flow_case|
            flow_case
        else
            return error.MissingRuntimeIntentArtifact;
        // A case that applied no edit has no expected workspace, which is the
        // correct record of that outcome rather than a broken artifact. It
        // cannot pass an intent check, so it is an observed failure and is
        // compared against the pin like any other.
        const handler: ?[]const u8 = for (flow_case.fixtures) |fixture| {
            if (fixture.role == .expected_workspace and
                std.mem.eql(u8, fixture.path, "expected/handler.ts"))
            {
                break fixture.bytes;
            }
        } else null;
        if (handler == null) {
            if (rc.expect_committed_intent_pass) {
                std.debug.print(
                    "[codegen-intent] {s}: pinned to pass but the recording applied no edit," ++
                        " so the corpus holds no handler to run\n",
                    .{name},
                );
                return error.RuntimeIntentPinMismatch;
            }
            checked += 1;
            continue;
        }

        var tmp = try IsolatedTmp.init(testing.allocator, "durable-intent");
        defer tmp.cleanup(testing.allocator);
        for (rc.seed_files) |seed| try tmp.writeFile(testing.allocator, seed.path, seed.bytes);
        try tmp.writeFile(testing.allocator, intent.handler_path, handler.?);

        const outcome = codegen.runIntentCheck(
            testing.allocator,
            intent,
            tmp.abs_path,
            zttp_bin,
        );
        const observed_pass = outcome == .passed;
        if (observed_pass != rc.expect_committed_intent_pass) {
            if (!observed_pass) {
                var diagnostic = try tool_common.runCommand(
                    testing.allocator,
                    tmp.abs_path,
                    &.{ zttp_bin, "test", "intent.test.jsonl" },
                );
                defer diagnostic.deinit(testing.allocator);
                std.debug.print("[codegen-intent] committed handler failed: {s}\n", .{name});
                std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ diagnostic.stdout, diagnostic.stderr });
            }
            std.debug.print(
                "[codegen-intent] {s}: pinned expect_committed_intent_pass={} but observed {}." ++
                    " If the recording measured this outcome, move the pin in the same commit" ++
                    " as the cassettes and say what changed.\n",
                .{ name, rc.expect_committed_intent_pass, observed_pass },
            );
            return error.RuntimeIntentPinMismatch;
        }
        checked += 1;
        if (observed_pass) passed += 1;
    }
    // Every named case reached its assertion. Without this the loop would
    // satisfy the test by checking nothing if a case stopped resolving.
    try testing.expectEqual(names.len, checked);
    // And at least one committed handler genuinely runs. A corpus where every
    // durable case is pinned as a failure would otherwise pass this test while
    // proving the runtime executes nothing.
    try testing.expect(passed > 0);
}

const LiveRecordingProgress = struct {
    case_index: usize,
    case_count: usize,
    case_name: []const u8,

    fn observer(self: *LiveRecordingProgress) flow_recorder.ProgressObserver {
        return .{ .context = self, .on_event = onEvent };
    }

    fn onEvent(context: *anyopaque, event: flow_recorder.ProgressEvent) void {
        const self: *LiveRecordingProgress = @ptrCast(@alignCast(context));
        var bytes: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        writeEvent(&writer, self.*, event) catch {
            std.debug.print(
                "[codegen-record] [{d}/{d}] {s}: model call captured\n",
                .{ self.case_index, self.case_count, self.case_name },
            );
            return;
        };
        std.debug.print("{s}", .{writer.buffered()});
    }

    fn writeEvent(
        writer: *std.Io.Writer,
        progress: LiveRecordingProgress,
        event: flow_recorder.ProgressEvent,
    ) !void {
        switch (event) {
            .model_call_completed => |completed| try writer.print(
                "[codegen-record] [{d}/{d}] {s}: call {d} captured " ++
                    "(turn={d} turn-call={d} purpose={s} " ++
                    "input-reported={d} input-logical={d} ({s}) " ++
                    "input-estimated={d} ({s}) output={d} " ++
                    "output-limit={d} wire={d}B)\n",
                .{
                    progress.case_index,
                    progress.case_count,
                    progress.case_name,
                    completed.global_call_index + 1,
                    completed.turn_index + 1,
                    completed.turn_call_index + 1,
                    @tagName(completed.purpose),
                    completed.reported_input_tokens,
                    completed.logical_input_tokens,
                    @tagName(completed.input_observation_source),
                    completed.estimated_input_tokens,
                    @tagName(completed.estimate_source),
                    completed.output_tokens,
                    completed.output_limit_tokens,
                    completed.wire_bytes,
                },
            ),
            .model_call_failed => |failed| try writer.print(
                "[codegen-record] [{d}/{d}] {s}: call attempt {d} failed " ++
                    "(provider={s} latency={?d}ms http-status={?d} error={s})\n",
                .{
                    progress.case_index,
                    progress.case_count,
                    progress.case_name,
                    failed.attempt_index + 1,
                    @tagName(failed.provider),
                    failed.latency_ms,
                    failed.http_status,
                    @errorName(failed.failure),
                },
            ),
        }
    }
};

const recorder_transport_attempts: u8 = 3;

/// How long one recorded request may sit silent before it is called stalled.
///
/// Measured, not chosen: across 3,037 successful attempts in seven run
/// directories the median took 5.6s, the 99th percentile 85s, and the slowest
/// 191s. Nothing healthy has ever come close to five minutes, so a request
/// still silent at that point is not a slow answer. The one occurrence this
/// exists for spent the whole 600s turn budget on its first call, and the same
/// case recorded in about a minute when it was re-run alone.
///
/// The value only has to sit above every real generation and below the turn
/// budget. It does not have to be tight: an occurrence costs five minutes
/// either way, and the alternative was losing the whole run.
const recorder_silence_ceiling_ms: u64 = 5 * 60 * 1000;

/// Live recording is a long, expensive sequence of otherwise independent
/// model requests. A connection that closes before a response is decoded has
/// produced no replayable model event and no tool effect, so the exact pending
/// request can be retried safely. The same holds for a request that goes silent
/// past the ceiling above, which is why it is a distinct error rather than the
/// timeout the turn reports when its budget is spent: no response was decoded,
/// so a reissue is not a re-roll of an answer the model already gave.
///
/// Keep this policy at the recorder boundary: ordinary interactive sessions
/// continue to surface transport failures.
const RecorderModelClient = struct {
    inner: loop.ModelClient,
    progress: LiveRecordingProgress,

    fn retriable(err: anyerror) bool {
        return err == error.DeepSeekServerUnavailable or
            err == error.DeepSeekGenerationStalled;
    }

    fn request(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *@This() = @ptrCast(@alignCast(context));
        var attempt: u8 = 1;
        while (true) {
            const result = self.inner.request(arena, transcript, extra_user_text) catch |err| {
                if (!retriable(err) or attempt >= recorder_transport_attempts) {
                    return err;
                }
                attempt += 1;
                std.debug.print(
                    "[codegen-record] [{d}/{d}] {s}: {s}; " ++
                        "retrying the same model request ({d}/{d})\n",
                    .{
                        self.progress.case_index,
                        self.progress.case_count,
                        self.progress.case_name,
                        @errorName(err),
                        attempt,
                        recorder_transport_attempts,
                    },
                );
                continue;
            };
            return result;
        }
    }

    fn setDeadline(context: *anyopaque, deadline_ms: ?i64) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.inner.setDeadline(deadline_ms);
    }

    fn asModelClient(self: *@This()) loop.ModelClient {
        return .{
            .context = self,
            .request_fn = request,
            .set_deadline_fn = setDeadline,
        };
    }
};

test "live recorder retries a transient DeepSeek transport failure" {
    const FakeClient = struct {
        calls: usize = 0,
        failures_left: usize,
        deadline: ?i64 = null,

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: *const transcript_mod.Transcript,
            _: ?[]const u8,
        ) anyerror!loop.ModelCallResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.failures_left > 0) {
                self.failures_left -= 1;
                return error.DeepSeekServerUnavailable;
            }
            return .{ .reply = .{ .response = .{ .final_text = "recorded" } } };
        }

        fn setDeadline(context: *anyopaque, deadline_ms: ?i64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.deadline = deadline_ms;
        }

        fn asModelClient(self: *@This()) loop.ModelClient {
            return .{
                .context = self,
                .request_fn = request,
                .set_deadline_fn = setDeadline,
            };
        }
    };

    var fake: FakeClient = .{ .failures_left = 2 };
    var retrying: RecorderModelClient = .{
        .inner = fake.asModelClient(),
        .progress = .{ .case_index = 1, .case_count = 1, .case_name = "probe" },
    };
    const client = retrying.asModelClient();
    client.setDeadline(1234);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    const result = try client.request(testing.allocator, &transcript, null);

    try testing.expectEqualStrings("recorded", result.reply.response.final_text);
    try testing.expectEqual(@as(usize, 3), fake.calls);
    try testing.expectEqual(@as(?i64, 1234), fake.deadline);
}

test "live recorder does not retry a non-transport failure" {
    const FakeClient = struct {
        calls: usize = 0,

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: *const transcript_mod.Transcript,
            _: ?[]const u8,
        ) anyerror!loop.ModelCallResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.InvalidChangeSetArgs;
        }
    };

    var fake: FakeClient = .{};
    var retrying: RecorderModelClient = .{
        .inner = .{ .context = &fake, .request_fn = FakeClient.request },
        .progress = .{ .case_index = 1, .case_count = 1, .case_name = "probe" },
    };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidChangeSetArgs,
        retrying.asModelClient().request(testing.allocator, &transcript, null),
    );
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

const StallingClient = struct {
    calls: usize = 0,
    stalls_left: usize,
    failure: anyerror = error.DeepSeekGenerationStalled,

    fn request(
        context: *anyopaque,
        _: std.mem.Allocator,
        _: *const transcript_mod.Transcript,
        _: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.stalls_left > 0) {
            self.stalls_left -= 1;
            return self.failure;
        }
        return .{ .reply = .{ .response = .{ .final_text = "recorded" } } };
    }
};

test "live recorder reissues a request that went silent" {
    // A stalled request decoded nothing, so reissuing it is not a re-roll of an
    // answer the model already gave. One occurrence cost a full run: jwt-auth
    // spent its entire 600s turn on its first call and then recorded in about a
    // minute when it was re-run alone.
    var fake: StallingClient = .{ .stalls_left = 2 };
    var retrying: RecorderModelClient = .{
        .inner = .{ .context = &fake, .request_fn = StallingClient.request },
        .progress = .{ .case_index = 1, .case_count = 1, .case_name = "probe" },
    };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    const result = try retrying.asModelClient().request(testing.allocator, &transcript, null);
    try testing.expectEqualStrings("recorded", result.reply.response.final_text);
    try testing.expectEqual(@as(usize, 3), fake.calls);
}

test "live recorder does not reissue a request whose turn budget is spent" {
    // The distinction the silence ceiling exists to draw. RequestTimedOut means
    // the turn has nothing left to spend, so every reissue would return the same
    // error without reaching the provider - three calls to reach one failure the
    // first call already knew.
    var fake: StallingClient = .{ .stalls_left = 2, .failure = error.RequestTimedOut };
    var retrying: RecorderModelClient = .{
        .inner = .{ .context = &fake, .request_fn = StallingClient.request },
        .progress = .{ .case_index = 1, .case_count = 1, .case_name = "probe" },
    };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);

    try testing.expectError(
        error.RequestTimedOut,
        retrying.asModelClient().request(testing.allocator, &transcript, null),
    );
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "live codegen recorder progress renders metadata only" {
    var text = TextBuffer.init(testing.allocator);
    defer text.deinit();
    try LiveRecordingProgress.writeEvent(text.writer(), .{
        .case_index = 3,
        .case_count = 19,
        .case_name = "validate-body",
    }, .{ .model_call_completed = .{
        .global_call_index = 3,
        .turn_index = 0,
        .turn_call_index = 3,
        .purpose = .normal,
        .estimated_input_tokens = 27_308,
        .estimate_source = .anchored_density,
        .reported_input_tokens = 19_861,
        .logical_input_tokens = 20_394,
        .input_observation_source = .prior_density_projection,
        .output_tokens = 417,
        .output_limit_tokens = 32_768,
        .wire_bytes = 77_789,
    } });
    try testing.expectEqualStrings(
        "[codegen-record] [3/19] validate-body: call 4 captured " ++
            "(turn=1 turn-call=4 purpose=normal input-reported=19861 " ++
            "input-logical=20394 (prior_density_projection) input-estimated=27308 " ++
            "(anchored_density) output=417 output-limit=32768 wire=77789B)\n",
        text.written(),
    );
}

test "live codegen recorder progress renders provider failure metadata only" {
    var text = TextBuffer.init(testing.allocator);
    defer text.deinit();
    try LiveRecordingProgress.writeEvent(text.writer(), .{
        .case_index = 1,
        .case_count = 19,
        .case_name = "health",
    }, .{ .model_call_failed = .{
        .attempt_index = 8,
        .provider = .deepseek,
        .latency_ms = 843,
        .http_status = 429,
        .failure = error.RateLimited,
    } });
    try testing.expectEqualStrings(
        "[codegen-record] [1/19] health: call attempt 9 failed " ++
            "(provider=deepseek latency=843ms http-status=429 error=RateLimited)\n",
        text.written(),
    );
}

/// The single selection rule. The progress denominator and the recording loop
/// both read it, so the printed `[n/total]` cannot drift from what runs.
fn recordCaseSelected(index: usize, limit: usize, only_case: ?[]const u8, name: []const u8) bool {
    if (index >= limit) return false;
    if (only_case) |only| return std.mem.eql(u8, only, name);
    return true;
}

fn selectedRecordCaseCount(limit: usize, only_case: ?[]const u8) usize {
    var count: usize = 0;
    for (record_corpus, 0..) |rc, index| {
        if (recordCaseSelected(index, limit, only_case, rc.name)) count += 1;
    }
    return count;
}

fn recordingShapeCanActivate(
    only_case: ?[]const u8,
    has_limit: bool,
    has_tool_filter: bool,
    selected_count: usize,
    model: []const u8,
    default_model: []const u8,
) bool {
    return only_case == null and !has_limit and !has_tool_filter and
        selected_count == record_corpus.len and std.mem.eql(u8, model, default_model);
}

const RecordingRunSummary = struct {
    selected: usize,
    staged: usize,
    applied: usize,
    intents_passed: usize,
    /// Cases that never produced an artifact: a refused proposal, a timeout, a
    /// decode failure. Distinct from a case that staged and recorded a model
    /// failure - see `recordingRunCanActivate`.
    recording_failures: usize,
};

/// Whether a run may replace the active corpus.
///
/// The question is whether the corpus is COMPLETE, not whether the model did
/// well. Those were one condition and it made the corpus unrecordable: a run
/// activated only when all nineteen cases applied an edit and passed intent,
/// so a corpus could be recorded only in the runs where the model happened to
/// be perfect. Five consecutive full runs failed this, each on a different two
/// or three cases, while the published metric this corpus feeds is a
/// first-draft PASS RATE - a number whose whole purpose is to be less than
/// 100%. The historical rows show it: 2026-08-14 published 89% first-draft and
/// 84% intent, and 2026-08-03 published 25%.
///
/// The recorder already treats a model failure as data. With
/// `ZTTP_CODEGEN_REQUIRE_GREEN` unset it prints "failure will be measured and
/// staged in quarantine", validates the replay, and stages the artifact - and
/// `requireGreenRecording`'s own comment says that branch is what "keeps the
/// measured-failure corpus behind docs/convergence.md and docs/coverage.md
/// populated". Refusing to activate that run discarded the measurement the
/// recorder had just taken.
///
/// So completeness is `staged == selected`, and that is exactly the integrity
/// property: a case that fails to record is never staged, which is why run 3
/// reported staged=17 against selected=19. A case that staged has a validated
/// replay whether or not the model succeeded in it.
///
/// `ZTTP_CODEGEN_REQUIRE_GREEN=1` remains the opt-in strict mode: it refuses
/// to stage a non-green case at all, so `staged == selected` then carries the
/// old meaning without a second condition asserting it.
fn recordingRunCanActivate(canonical_shape: bool, summary: RecordingRunSummary) bool {
    return canonical_shape and summary.selected == record_corpus.len and
        summary.staged == summary.selected and summary.recording_failures == 0;
}

test "a complete recording activates whether or not the model succeeded in it" {
    const canonical = recordingShapeCanActivate(null, false, false, 19, "default", "default");
    try testing.expect(canonical);

    // The green run activates, as before.
    try testing.expect(recordingRunCanActivate(canonical, .{
        .selected = 19,
        .staged = 19,
        .applied = 19,
        .intents_passed = 19,
        .recording_failures = 0,
    }));

    // And so does the run that measured failures. This is the change: all
    // nineteen cases produced a validated artifact, three of them recording a
    // model that did not apply an edit or missed its intent. That corpus is
    // complete, and the rate it publishes is what those three make true. Five
    // consecutive runs were discarded for exactly this shape.
    try testing.expect(recordingRunCanActivate(canonical, .{
        .selected = 19,
        .staged = 19,
        .applied = 17,
        .intents_passed = 18,
        .recording_failures = 0,
    }));

    // What still refuses: a case that produced no artifact. The corpus would
    // be missing a case, and the replay would cover eighteen while claiming
    // nineteen. Both the count and the flag are checked, because they come
    // from different places and either alone has been wrong.
    try testing.expect(!recordingRunCanActivate(canonical, .{
        .selected = 19,
        .staged = 17,
        .applied = 17,
        .intents_passed = 17,
        .recording_failures = 2,
    }));
    try testing.expect(!recordingRunCanActivate(canonical, .{
        .selected = 19,
        .staged = 19,
        .applied = 19,
        .intents_passed = 19,
        .recording_failures = 1,
    }));

    // Shape guards are unchanged: a filtered, truncated, single-case or
    // non-default-model run never activates whatever its outcome.
    try testing.expect(!recordingShapeCanActivate("health", false, false, 1, "default", "default"));
    try testing.expect(!recordingShapeCanActivate(null, true, false, 19, "default", "default"));
    try testing.expect(!recordingShapeCanActivate(null, false, true, 19, "default", "default"));
    try testing.expect(!recordingShapeCanActivate(null, false, false, 18, "default", "default"));
    try testing.expect(!recordingShapeCanActivate(null, false, false, 19, "candidate", "default"));
    try testing.expect(!recordingRunCanActivate(false, .{
        .selected = 19,
        .staged = 19,
        .applied = 19,
        .intents_passed = 19,
        .recording_failures = 0,
    }));
}

const RecordingFailureKind = enum {
    empty_response,
    timeout,
    decode,
    provider,
    intent,
    validation,
    internal,
};

const RecordingFailure = struct {
    case_name: []const u8,
    kind: RecordingFailureKind,
    error_name: []const u8,
};

fn classifyRecordingFailure(err: anyerror) RecordingFailureKind {
    return switch (err) {
        error.EmptyResponse => .empty_response,
        error.RequestTimedOut,
        error.RecordedTurnHitTimeBudget,
        // Reported only after every reissue also went silent, so by the time it
        // reaches here it has cost the turn its budget like any other timeout.
        error.DeepSeekGenerationStalled,
        => .timeout,
        error.InvalidResponseJson,
        error.MalformedToolCall,
        error.MalformedToolEnvelope,
        error.UnexpectedResponseShape,
        error.MalformedSse,
        error.MissingType,
        error.UnknownEventType,
        error.UnexpectedJsonShape,
        => .decode,
        error.IntentCheckUnavailable,
        error.RecordedIntentCheckFailed,
        => .intent,
        error.InvalidRecordedFlow,
        error.NonDeterministicFlowVersion,
        error.PinnedExpectationMismatch,
        error.RecordedEditNotApplied,
        => .validation,
        error.AuthFailed,
        error.InsufficientCredit,
        error.RateLimited,
        error.ModelNotFound,
        error.ProviderOverloaded,
        error.ProviderServerError,
        error.ApiError,
        error.HttpNotOk,
        error.DeepSeekServerUnavailable,
        error.LocalServerUnavailable,
        error.LocalHealthNotOk,
        error.LocalModelUnavailable,
        => .provider,
        else => if (loop.providerErrorRemediation(err) != null) .provider else .internal,
    };
}

fn qualificationFailureKind(kind: RecordingFailureKind) qualification.FailureKind {
    return switch (kind) {
        .empty_response => .empty_response,
        .timeout => .timeout,
        .decode => .decode,
        .provider => .provider,
        .intent => .intent,
        .validation => .validation,
        .internal => .internal,
    };
}

fn requiredQualificationEnv(name: [:0]const u8) ![]const u8 {
    return envValue(name) orelse error.MissingQualificationProvenance;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn servingArgsContainSecret(args: []const u8) bool {
    inline for (&.{ "api-key", "apikey", "token", "secret", "password", "credential" }) |needle| {
        if (containsAsciiIgnoreCase(args, needle)) return true;
    }
    return false;
}

fn qualificationLocalProvenance(provider: agent.Provider) !?qualification.LocalProvenance {
    const names = .{
        "ZTTP_CODEGEN_MODEL_ARTIFACT_SHA256",
        "ZTTP_CODEGEN_QUANTIZATION",
        "ZTTP_CODEGEN_CHAT_TEMPLATE_SHA256",
        "ZTTP_CODEGEN_SERVING_ARGS",
        "ZTTP_CODEGEN_HARDWARE",
        "ZTTP_CODEGEN_OS",
        "ZTTP_CODEGEN_PEAK_MEMORY_BYTES",
    };
    if (provider != .local) {
        inline for (names) |name| {
            if (envValue(name) != null) return error.LocalProvenanceRequiresLocalProvider;
        }
        return null;
    }

    const artifact_sha256 = try requiredQualificationEnv(names[0]);
    const chat_template_sha256 = try requiredQualificationEnv(names[2]);
    if (artifact_sha256.len != 64 or !isLowerHex(artifact_sha256) or
        chat_template_sha256.len != 64 or !isLowerHex(chat_template_sha256))
    {
        return error.MalformedQualificationDigest;
    }
    const peak_memory = std.fmt.parseInt(
        u64,
        try requiredQualificationEnv(names[6]),
        10,
    ) catch return error.MalformedQualificationPeakMemory;
    if (peak_memory == 0) return error.MalformedQualificationPeakMemory;
    const serving_args = try requiredQualificationEnv(names[3]);
    if (servingArgsContainSecret(serving_args)) return error.SecretInQualificationProvenance;
    const quantization = try requiredQualificationEnv(names[1]);
    const hardware = try requiredQualificationEnv(names[4]);
    const os = try requiredQualificationEnv(names[5]);
    if (quantization.len == 0 or serving_args.len == 0 or
        hardware.len == 0 or os.len == 0 or
        quantization.len > 64 or serving_args.len > 4096 or
        hardware.len > 512 or os.len > 512)
    {
        return error.QualificationProvenanceTooLarge;
    }
    return .{
        .model_artifact_sha256 = artifact_sha256,
        .quantization = quantization,
        .chat_template_sha256 = chat_template_sha256,
        .serving_args = serving_args,
        .sampling_policy = "server-defaults",
        .seed = null,
        .hardware = hardware,
        .os = os,
        .peak_memory_bytes = peak_memory,
    };
}

test "recording failures map exhaustively into qualification failures" {
    try testing.expectEqual(
        qualification.FailureKind.empty_response,
        qualificationFailureKind(.empty_response),
    );
    try testing.expectEqual(
        qualification.FailureKind.internal,
        qualificationFailureKind(.internal),
    );
}

test "qualification serving arguments reject secret-shaped flags" {
    try testing.expect(!servingArgsContainSecret("mlx_lm.server --model candidate --port 8080"));
    try testing.expect(servingArgsContainSecret("mlx_lm.server --api-key do-not-record"));
    try testing.expect(servingArgsContainSecret("serve --TOKEN=value"));
}

fn copyDraftFailure(
    allocator: std.mem.Allocator,
    analysis: *const failure_analysis.Analysis,
) !qualification.DraftFailure {
    const diagnostic_code = if (analysis.diagnosticCode()) |code| try allocator.dupe(u8, code) else null;
    const tool_name = if (analysis.toolName()) |name| try allocator.dupe(u8, name) else null;
    return .{
        .primary = analysis.primary,
        .contributors = try allocator.dupe(qualification.DraftFailureCause, analysis.contributors()),
        .evidence = .{
            .diagnostic_code = diagnostic_code,
            .transcript_entry = analysis.transcript_entry,
            .tool_name = tool_name,
        },
    };
}

const CorpusSwapFault = enum { after_old_rename, after_new_rename };

const CorpusSwapHooks = struct {
    fail_at: ?CorpusSwapFault = null,

    fn reach(self: CorpusSwapHooks, point: CorpusSwapFault) !void {
        if (self.fail_at == point) return error.InjectedCorpusSwapFault;
    }
};

fn pathKind(io: std.Io, path: []const u8) !?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return stat.kind;
}

fn requireDirectory(io: std.Io, path: []const u8) !bool {
    const kind = try pathKind(io, path) orelse return false;
    if (kind != .directory) return error.CorpusSwapPathNotDirectory;
    return true;
}

fn syncParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.CorpusSwapMissingParent;
    var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    if (std.c.fsync(dir.handle) != 0) return error.DirectorySyncFailed;
}

fn deleteTreeAbsolute(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.CorpusSwapMissingParent;
    const base = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.deleteTree(io, base);
    if (std.c.fsync(dir.handle) != 0) return error.DirectorySyncFailed;
}

fn corpusBackupPath(allocator: std.mem.Allocator, active_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.recording-backup", .{active_root});
}

/// Complete or undo the only two interrupted directory-swap states.
fn recoverCorpusSwap(
    allocator: std.mem.Allocator,
    io: std.Io,
    active_root: []const u8,
) !void {
    const backup = try corpusBackupPath(allocator, active_root);
    defer allocator.free(backup);
    if (!try requireDirectory(io, backup)) return;

    if (try requireDirectory(io, active_root)) {
        // New active root exists, so the complete staged corpus won the second
        // rename. Only cleanup was interrupted.
        try deleteTreeAbsolute(io, backup);
        std.debug.print("[codegen-record] completed interrupted corpus swap cleanup\n", .{});
        return;
    }
    // The old root moved but the staged root did not. Restore the old root and
    // leave the staged run quarantined at its unique path.
    try std.Io.Dir.renameAbsolute(backup, active_root, io);
    try syncParent(io, active_root);
    std.debug.print("[codegen-record] restored active corpus after interrupted swap\n", .{});
}

fn commitStagedCorpus(
    allocator: std.mem.Allocator,
    io: std.Io,
    stage_root: []const u8,
    active_root: []const u8,
) !void {
    return commitStagedCorpusWithHooks(allocator, io, stage_root, active_root, .{});
}

fn commitStagedCorpusWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    stage_root: []const u8,
    active_root: []const u8,
    hooks: CorpusSwapHooks,
) !void {
    if (!try requireDirectory(io, stage_root)) return error.MissingStagedCorpus;
    const backup = try corpusBackupPath(allocator, active_root);
    defer allocator.free(backup);
    if (try pathKind(io, backup) != null) return error.CorpusSwapRecoveryRequired;

    const had_active = try requireDirectory(io, active_root);
    if (had_active) {
        try std.Io.Dir.renameAbsolute(active_root, backup, io);
        try syncParent(io, active_root);
        try hooks.reach(.after_old_rename);
    }

    std.Io.Dir.renameAbsolute(stage_root, active_root, io) catch |err| {
        if (had_active) {
            std.Io.Dir.renameAbsolute(backup, active_root, io) catch
                return error.CorpusSwapRecoveryRequired;
            syncParent(io, active_root) catch return error.CorpusSwapRecoveryRequired;
        }
        return err;
    };
    syncParent(io, active_root) catch return error.CorpusActivatedRecoveryRequired;
    syncParent(io, stage_root) catch return error.CorpusActivatedRecoveryRequired;
    hooks.reach(.after_new_rename) catch return error.CorpusActivatedRecoveryRequired;

    if (had_active) {
        deleteTreeAbsolute(io, backup) catch return error.CorpusActivatedRecoveryRequired;
    }
}

test "recording failures preserve empty timeout decode and provider classes" {
    try testing.expectEqual(RecordingFailureKind.empty_response, classifyRecordingFailure(error.EmptyResponse));
    try testing.expectEqual(RecordingFailureKind.timeout, classifyRecordingFailure(error.RequestTimedOut));
    try testing.expectEqual(RecordingFailureKind.decode, classifyRecordingFailure(error.InvalidResponseJson));
    try testing.expectEqual(RecordingFailureKind.provider, classifyRecordingFailure(error.RateLimited));
    try testing.expectEqual(RecordingFailureKind.provider, classifyRecordingFailure(error.DeepSeekServerUnavailable));
    try testing.expectEqual(RecordingFailureKind.internal, classifyRecordingFailure(error.OutOfMemory));
}

test "whole corpus swap recovers both crash boundaries" {
    var tmp = try IsolatedTmp.init(testing.allocator, "codegen-corpus-swap");
    defer tmp.cleanup(testing.allocator);
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const active = try std.fs.path.join(testing.allocator, &.{ tmp.abs_path, "active" });
    defer testing.allocator.free(active);
    const stage = try std.fs.path.join(testing.allocator, &.{ tmp.abs_path, "stage" });
    defer testing.allocator.free(stage);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, active);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, stage);
    const active_file = try std.fs.path.join(testing.allocator, &.{ active, "value" });
    defer testing.allocator.free(active_file);
    const stage_file = try std.fs.path.join(testing.allocator, &.{ stage, "value" });
    defer testing.allocator.free(stage_file);
    try zts.file_io.writeFile(testing.allocator, active_file, "old");
    try zts.file_io.writeFile(testing.allocator, stage_file, "new");

    try testing.expectError(
        error.InjectedCorpusSwapFault,
        commitStagedCorpusWithHooks(
            testing.allocator,
            io,
            stage,
            active,
            .{ .fail_at = .after_old_rename },
        ),
    );
    try recoverCorpusSwap(testing.allocator, io, active);
    const restored = try zts.file_io.readFile(testing.allocator, active_file, 16);
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("old", restored);

    // The first staged root remains quarantined. Use a fresh complete stage for
    // the post-activation crash point.
    const stage_two = try std.fs.path.join(testing.allocator, &.{ tmp.abs_path, "stage-two" });
    defer testing.allocator.free(stage_two);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, stage_two);
    const stage_two_file = try std.fs.path.join(testing.allocator, &.{ stage_two, "value" });
    defer testing.allocator.free(stage_two_file);
    try zts.file_io.writeFile(testing.allocator, stage_two_file, "new");
    try testing.expectError(
        error.CorpusActivatedRecoveryRequired,
        commitStagedCorpusWithHooks(
            testing.allocator,
            io,
            stage_two,
            active,
            .{ .fail_at = .after_new_rename },
        ),
    );
    try recoverCorpusSwap(testing.allocator, io, active);
    const activated = try zts.file_io.readFile(testing.allocator, active_file, 16);
    defer testing.allocator.free(activated);
    try testing.expectEqualStrings("new", activated);

    const stage_three = try std.fs.path.join(testing.allocator, &.{ tmp.abs_path, "stage-three" });
    defer testing.allocator.free(stage_three);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, stage_three);
    const stage_three_file = try std.fs.path.join(testing.allocator, &.{ stage_three, "value" });
    defer testing.allocator.free(stage_three_file);
    try zts.file_io.writeFile(testing.allocator, stage_three_file, "newer");
    try commitStagedCorpus(testing.allocator, io, stage_three, active);
    const committed = try zts.file_io.readFile(testing.allocator, active_file, 16);
    defer testing.allocator.free(committed);
    try testing.expectEqualStrings("newer", committed);
    const backup = try corpusBackupPath(testing.allocator, active);
    defer testing.allocator.free(backup);
    try testing.expect(try pathKind(io, backup) == null);
}

const LiveRecordContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *registry_mod.Registry,
    session: *agent.AgentSession,
    request_config: model_request.Config,
    provider: agent.Provider,
    model: []const u8,
    model_revision: ?[]const u8,
    runtime_identity: ?RuntimeIdentity,
    repo_root: []const u8,
    stage_root: []const u8,
    diagnostics_run_id: []const u8,
    turn_timeout_ms: u64,
    require_green: bool,
    enforce_headline_ratchet: bool,
};

const LiveRecordOutcome = struct {
    artifact_identity: evidence_identity.ContentDigest,
    draft_quality: codegen_types.DraftQuality,
    applied: bool,
    intent: codegen_types.IntentOutcome,
    roundtrips: u8,
    wall_clock_ms: u64,
    draft_failure: ?failure_analysis.Analysis,
    provider_runtime: ?evidence_identity.RuntimeRevision,
};

fn elapsedWallClockMs(started_ms: i64) u64 {
    const finished_ms = zts.realtimeNowMs() catch started_ms;
    if (finished_ms <= started_ms) return 0;
    return @intCast(finished_ms - started_ms);
}

fn recordLiveCase(
    context: *LiveRecordContext,
    rc: RecordCase,
    case_index: usize,
    case_count: usize,
) !LiveRecordOutcome {
    const started_ms = zts.realtimeNowMs() catch 0;
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    const allocator = case_arena.allocator();

    var tmp = try IsolatedTmp.init(allocator, "codegen-record");
    defer tmp.cleanup(allocator);
    for (rc.seed_files) |seed| try tmp.writeFile(allocator, seed.path, seed.bytes);

    const case_dir = try std.fs.path.join(allocator, &.{ context.stage_root, rc.name });
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), context.io, case_dir);
    const case_root_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(context.io, case_dir, allocator);
    const response_diagnostics_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/codegen-record-diagnostics/{s}/{s}.jsonl",
        .{ context.repo_root, context.diagnostics_run_id, rc.name },
    );

    const workspace_allowlist = try workspaceCaptureAllowlist(allocator, rc.seed_files);
    var live_progress: LiveRecordingProgress = .{
        .case_index = case_index,
        .case_count = case_count,
        .case_name = rc.name,
    };
    var recorder = try flow_recorder.Recorder.init(allocator, .{
        .case_name = rc.name,
        .evidence_class = .empirical_model,
        .provider = switch (context.provider) {
            .local => .local,
            .anthropic => .anthropic,
            .openai => .openai,
            .deepseek => .deepseek,
        },
        .model = context.model,
        .model_revision = context.model_revision,
        .runtime_name = if (context.runtime_identity) |identity| identity.name else null,
        .runtime_version = if (context.runtime_identity) |identity| identity.version else null,
        .diagnostics_path = response_diagnostics_path,
        .progress = live_progress.observer(),
        .workspace_allowlist = workspace_allowlist,
    });
    defer recorder.deinit();
    try recorder.captureInitialWorkspace(tmp.abs_path);

    const saved_cwd = try cwdPathAlloc(allocator);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var sink = recorder.captureSink();
    try setSessionCapture(context.session, &sink);
    defer setSessionCapture(context.session, null) catch {};

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    try recorder.beginTurn(rc.prompt, transcript.len(), .approve);
    var recording_client: RecorderModelClient = .{
        .inner = context.session.modelClient(),
        .progress = live_progress,
    };
    const result = loop.runTurnWith(
        allocator,
        recording_client.asModelClient(),
        context.registry,
        &transcript,
        rc.prompt,
        .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = recorder.approvalFn(),
            .replay_mode = false,
            .turn_timeout_ms = context.turn_timeout_ms,
        },
    ) catch |err| {
        std.debug.print("[codegen-record] {s}: turn failed: {s}\n", .{ rc.name, @errorName(err) });
        std.debug.print(
            "[codegen-record] metadata-only response diagnostics: {s}\n",
            .{response_diagnostics_path},
        );
        return err;
    };
    try setSessionCapture(context.session, null);

    if (result.end_reason == .budget_timeout) {
        std.debug.print(
            "[codegen-record] {s}: turn hit the {d}s wall-clock ceiling, so its recording " ++
                "would not replay; raise ZTTP_CODEGEN_TURN_TIMEOUT_MS for this corpus\n",
            .{ rc.name, context.turn_timeout_ms / 1000 },
        );
        return error.RecordedTurnHitTimeBudget;
    }
    try recorder.finishTurn(result, &transcript);
    try recorder.captureExpectedWorkspace(tmp.abs_path);
    std.debug.print(
        "[codegen-record] [{d}/{d}] {s}: live turn captured " ++
            "(calls={d} roundtrips={d} retries={d} tools={d}); checking result\n",
        .{
            case_index,
            case_count,
            rc.name,
            sink.next_call_index,
            result.roundtrips,
            result.veto_retry_count,
            result.tool_call_count,
        },
    );
    if (context.enforce_headline_ratchet) {
        if (firstAttemptExpectation(context.provider, null, rc.expect_first_attempt_green)) |expected| {
            if (result.firstAttemptGreen() != expected) {
                std.debug.print(
                    "[codegen-record] {s}: pinned first_attempt_green={} but fresh flow observed {}\n",
                    .{ rc.name, expected, result.firstAttemptGreen() },
                );
                return error.PinnedExpectationMismatch;
            }
        }
    }

    const zttp_bin: ?[]u8 = if (runtimeIntent(rc.intent) != null)
        codegen.locateZttpBinary(allocator, context.repo_root) orelse {
            std.debug.print(
                "[codegen-record] {s}: declared intent cannot run because zig-out/bin/zttp is unavailable\n",
                .{rc.name},
            );
            return error.IntentCheckUnavailable;
        }
    else
        null;
    var intent_outcome: codegen_types.IntentOutcome = switch (rc.intent) {
        .runtime => .not_checked,
        .compiler_veto_only => .compiler_veto_only,
    };
    requireRecordedIntent(
        allocator,
        runtimeIntent(rc.intent),
        tmp.abs_path,
        zttp_bin,
        codegen.runIntentCheck,
    ) catch |err| {
        intent_outcome = .failed;
        const handler_path: ?[]u8 = std.fs.path.join(
            allocator,
            &.{ tmp.abs_path, "handler.ts" },
        ) catch null;
        if (handler_path) |path| {
            if (zts.file_io.readFile(allocator, path, 1024 * 1024)) |handler| {
                std.debug.print("[codegen-record] {s}: produced handler:\n{s}\n", .{ rc.name, handler });
            } else |_| {}
        }
        const outcome: []const u8 = if (context.require_green)
            "required-green mode will refuse staging"
        else
            "failure will be measured and staged in quarantine";
        std.debug.print(
            "[codegen-record] {s}: declared intent did not pass ({s}); {s}\n",
            .{ rc.name, @errorName(err), outcome },
        );
        if (err == error.IntentCheckUnavailable) return err;
    };
    if (runtimeIntent(rc.intent) != null and intent_outcome == .not_checked) {
        intent_outcome = .passed;
    }

    const intent_passed = intent_outcome == .passed or intent_outcome == .compiler_veto_only;

    requireGreenRecording(
        context.require_green,
        result.applied_change_set,
        intent_passed,
    ) catch |err| {
        std.debug.print(
            "[codegen-record] {s}: required-green check failed " ++
                "(applied={} intent-passed={} error={s})\n",
            .{ rc.name, result.applied_change_set, intent_passed, @errorName(err) },
        );
        return err;
    };

    std.debug.print(
        "[codegen-record] [{d}/{d}] {s}: validating replay and staging\n",
        .{ case_index, case_count, rc.name },
    );
    const staged_version = try flow_promotion.validateAndPromote(
        allocator,
        &recorder,
        case_root_abs,
        context.registry,
        context.request_config,
    );
    const fail_code = codegen.firstZtsCode(&transcript) orelse "-";
    const draft_failure = if (result.rawFirstDraftVetoPass())
        null
    else
        failure_analysis.analyze(
            allocator,
            rc.mode,
            &transcript,
            codegen.firstZtsCode(&transcript),
        );
    const provider_runtime: ?evidence_identity.RuntimeRevision = if (recorder.runtimeIdentity()) |identity|
        .{
            .name = try context.allocator.dupe(u8, identity.name),
            .revision = try context.allocator.dupe(u8, identity.revision),
        }
    else
        null;
    std.debug.print(
        "[codegen-record] [{d}/{d}] {s}: staged provider={s} model={s} flow={s} raw_first_draft_pass={} first_attempt_green={} applied={} compiler_authored={} roundtrips={d} retries={d} tools={d} calls={d} fail={s}\n",
        .{
            case_index,
            case_count,
            rc.name,
            context.provider.publicName(),
            context.model,
            staged_version.slice()[0..12],
            result.rawFirstDraftVetoPass(),
            result.firstAttemptGreen(),
            result.applied_change_set,
            result.compiler_authored_apply,
            result.roundtrips,
            result.veto_retry_count,
            result.tool_call_count,
            sink.next_call_index,
            fail_code,
        },
    );
    return .{
        .artifact_identity = evidence_identity.contentDigest("flow-artifact", staged_version.slice()),
        .draft_quality = result.draft_quality,
        .applied = result.applied_change_set,
        .intent = intent_outcome,
        .roundtrips = result.roundtrips,
        .wall_clock_ms = elapsedWallClockMs(started_ms),
        .draft_failure = draft_failure,
        .provider_runtime = provider_runtime,
    };
}

// Record or qualify the real expert agent against the corpus.
// Gated: ZTTP_CODEGEN_RECORD=1 or ZTTP_CODEGEN_QUALIFY=1. Cloud providers additionally require their
// named key. Each case runs in its own tmp
// workspace with cwd switched to it, so the agent's tools and the edit veto
// resolve the same files; cassettes are written to an absolute repo path so the
// chdir does not misplace them. Filtered, limited, non-default-model, and
// failed runs stay under `.zig-cache/codegen-record-staging`; only a complete
// unfiltered run swaps the provider corpus root.
test "record codegen baseline corpus (live, gated)" {
    const live_mode = (try requestedLiveCorpusMode()) orelse return error.SkipZigTest;
    if (live_mode == .qualify and
        (envValue("ZTTP_CODEGEN_PROVIDER") == null or envValue("ZTTP_CODEGEN_MODEL") == null))
    {
        return error.QualificationRequiresExplicitCandidate;
    }
    const corpus_provider = try recordingProvider();
    if (!recordingAuthAvailable(corpus_provider)) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const corpus_model = envValue("ZTTP_CODEGEN_MODEL") orelse
        models.defaultForProvider(corpus_provider).id;
    const only_case: ?[]const u8 = if (envValue("ZTTP_CODEGEN_ONLY")) |value|
        if (value.len == 0) null else value
    else
        null;
    if (live_mode == .qualify and greenRecordingRequired()) {
        return error.QualificationMustMeasureFailures;
    }
    const require_green = live_mode == .record and greenRecordingRequired();
    const record_turn_timeout_ms: u64 = if (envValue("ZTTP_CODEGEN_TURN_TIMEOUT_MS")) |raw|
        std.fmt.parseInt(u64, raw, 10) catch default_record_turn_timeout_ms
    else
        default_record_turn_timeout_ms;
    var limit: usize = record_corpus.len;
    if (envValue("ZTTP_CODEGEN_LIMIT")) |raw| {
        limit = std.fmt.parseInt(usize, raw, 10) catch limit;
    }
    const selected_case_count = selectedRecordCaseCount(limit, only_case);
    if (selected_case_count == 0) {
        if (only_case != null) return error.NamedCodegenCaseNotFound;
        return error.CodegenCorpusCountMismatch;
    }

    const has_limit = if (envValue("ZTTP_CODEGEN_LIMIT")) |value| value.len != 0 else false;
    const has_tool_filter = if (envValue("ZTTP_CODEGEN_TOOLS")) |value| value.len != 0 else false;
    if (live_mode == .qualify and
        (only_case != null or has_limit or has_tool_filter or selected_case_count != record_corpus.len))
    {
        return error.FilteredQualificationRefused;
    }
    const local_provenance = if (live_mode == .qualify)
        try qualificationLocalProvenance(corpus_provider)
    else
        null;

    const repo_root = try cwdPathAlloc(allocator);
    const source_before = readSourceIdentity(allocator, repo_root);
    if (live_mode == .qualify and (!source_before.known or source_before.revision.dirty)) {
        return error.QualificationRequiresCleanKnownSource;
    }
    const out_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, flowRoot(corpus_provider) });
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    // Recovery precedes provider/session initialization. A prior crash cannot
    // leave the active corpus absent while a new model call starts.
    try recoverCorpusSwap(allocator, io, out_dir);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    try applyToolAllowlist(&registry);
    var session = try agent.initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = corpus_provider,
        .model = corpus_model,
    });
    defer session.deinit(allocator);
    if (session.activeProvider() != corpus_provider) return error.UnsupportedRecordingProvider;
    // A recording turn holds one wall-clock budget for the whole case, so a
    // single hung request could spend all of it and end the run. Give a silent
    // request its own ceiling so it fails while the turn can still reissue it.
    session.setProviderStallTimeout(recorder_silence_ceiling_ms);

    const request_config = try requestConfigForSession(&session);
    const model_revision = try cachedModelRevision(allocator, corpus_provider, corpus_model);
    if (live_mode == .qualify and corpus_provider == .local) {
        const revision = model_revision orelse return error.LocalQualificationRequiresModelRevision;
        if (revision.len != 40 or !isLowerHex(revision)) {
            return error.MalformedQualificationModelRevision;
        }
    }
    const runtime_identity = try declaredRuntime(corpus_provider);
    if (runtime_identity) |identity| {
        std.debug.print(
            "[codegen-record] declared local runtime: {s} {s}\n",
            .{ identity.name, identity.version },
        );
    }
    const diagnostics_run_id = try std.fmt.allocPrint(
        allocator,
        "{d}-{d}",
        .{ zts.realtimeNowMs() catch 0, std.c.getpid() },
    );
    const stage_root = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/codegen-record-staging/{s}-{s}",
        .{ repo_root, corpus_provider.publicName(), diagnostics_run_id },
    );
    if (try pathKind(io, stage_root) != null) return error.CorpusStagingPathExists;
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, stage_root);

    const canonical_full_run = recordingShapeCanActivate(
        only_case,
        has_limit,
        has_tool_filter,
        selected_case_count,
        corpus_model,
        models.defaultForProvider(corpus_provider).id,
    );
    std.debug.print(
        "[codegen-record] corpus start: provider={s} model={s} cases={d} " ++
            "mode={s} timeout={d}ms require-green={} canonical-full-run={} stage={s}\n",
        .{
            corpus_provider.publicName(),
            corpus_model,
            selected_case_count,
            @tagName(live_mode),
            record_turn_timeout_ms,
            require_green,
            canonical_full_run,
            stage_root,
        },
    );

    var context: LiveRecordContext = .{
        .allocator = allocator,
        .io = io,
        .registry = &registry,
        .session = &session,
        .request_config = request_config,
        .provider = corpus_provider,
        .model = corpus_model,
        .model_revision = model_revision,
        .runtime_identity = runtime_identity,
        .repo_root = repo_root,
        .stage_root = stage_root,
        .diagnostics_run_id = diagnostics_run_id,
        .turn_timeout_ms = record_turn_timeout_ms,
        .require_green = require_green,
        .enforce_headline_ratchet = live_mode == .record and
            corpus_provider == headline_provider and
            std.mem.eql(u8, corpus_model, headline_model),
    };
    var raw_first_draft_passes: usize = 0;
    var first_attempt_greens: usize = 0;
    var greens: usize = 0;
    var intent_passes: usize = 0;
    var total: usize = 0;
    var staged: usize = 0;
    var qualification_cases: std.ArrayList(qualification.CaseResult) = .empty;
    defer qualification_cases.deinit(allocator);
    var observed_runtime: RuntimeConsensus = .{};
    var failures: std.ArrayList(RecordingFailure) = .empty;
    defer failures.deinit(allocator);
    // Cases that produced no artifact at all. Counted apart from the failures
    // list, which also holds model outcomes measured after a case staged.
    var recording_failures: usize = 0;
    for (record_corpus, 0..) |rc, i| {
        if (!recordCaseSelected(i, limit, only_case, rc.name)) continue;
        total += 1;
        std.debug.print(
            "[codegen-record] [{d}/{d}] {s}: case start\n",
            .{ total, selected_case_count, rc.name },
        );
        const case_started_ms = zts.realtimeNowMs() catch 0;
        const outcome = recordLiveCase(&context, rc, total, selected_case_count) catch |err| {
            const kind = classifyRecordingFailure(err);
            recording_failures += 1;
            try failures.append(allocator, .{
                .case_name = rc.name,
                .kind = kind,
                .error_name = @errorName(err),
            });
            std.debug.print(
                "[codegen-record] [{d}/{d}] {s}: quarantined failure kind={s} error={s}\n",
                .{ total, selected_case_count, rc.name, @tagName(kind), @errorName(err) },
            );
            const case_failures = try allocator.alloc(qualification.FailureKind, 1);
            case_failures[0] = qualificationFailureKind(kind);
            const error_names = try allocator.alloc([]const u8, 1);
            error_names[0] = @errorName(err);
            try qualification_cases.append(allocator, .{
                .name = rc.name,
                .artifact_identity = null,
                .draft_quality = .not_green,
                .applied = false,
                .intent = switch (rc.intent) {
                    .runtime => .not_checked,
                    .compiler_veto_only => .compiler_veto_only,
                },
                .roundtrips = 0,
                .wall_clock_ms = elapsedWallClockMs(case_started_ms),
                .failures = case_failures,
                .error_names = error_names,
            });
            continue;
        };
        try observed_runtime.observe(allocator, outcome.provider_runtime);
        staged += 1;
        if (outcome.draft_quality.rawFirstDraftVetoPass()) raw_first_draft_passes += 1;
        if (outcome.draft_quality.firstAttemptGreen()) first_attempt_greens += 1;
        if (outcome.applied) greens += 1;
        const intent_satisfied = outcome.intent == .passed or outcome.intent == .compiler_veto_only;
        if (intent_satisfied) intent_passes += 1;
        var case_failure_count: usize = 0;
        if (!outcome.applied) case_failure_count += 1;
        if (!intent_satisfied) case_failure_count += 1;
        const case_failures = try allocator.alloc(qualification.FailureKind, case_failure_count);
        const error_names = try allocator.alloc([]const u8, case_failure_count);
        var case_failure_index: usize = 0;
        if (!outcome.applied) {
            try failures.append(allocator, .{
                .case_name = rc.name,
                .kind = .validation,
                .error_name = @errorName(error.RecordedEditNotApplied),
            });
            case_failures[case_failure_index] = .validation;
            error_names[case_failure_index] = @errorName(error.RecordedEditNotApplied);
            case_failure_index += 1;
        }
        if (!intent_satisfied) {
            try failures.append(allocator, .{
                .case_name = rc.name,
                .kind = .intent,
                .error_name = @errorName(error.RecordedIntentCheckFailed),
            });
            case_failures[case_failure_index] = .intent;
            error_names[case_failure_index] = @errorName(error.RecordedIntentCheckFailed);
        }
        const draft_failure = if (outcome.draft_failure) |*analysis|
            try copyDraftFailure(allocator, analysis)
        else
            null;
        try qualification_cases.append(allocator, .{
            .name = rc.name,
            .artifact_identity = try allocator.dupe(u8, outcome.artifact_identity.slice()),
            .draft_quality = outcome.draft_quality,
            .applied = outcome.applied,
            .intent = outcome.intent,
            .roundtrips = outcome.roundtrips,
            .wall_clock_ms = outcome.wall_clock_ms,
            .failures = case_failures,
            .error_names = error_names,
            .draft_failure = draft_failure,
        });
    }
    std.debug.print(
        "[codegen-record] RUN raw first-draft pass: {d}/{d}; first-attempt green: {d}/{d}; " ++
            "reached-green: {d}/{d}; intent-qualified: {d}/{d}; staged={d}; failures={d}\n",
        .{
            raw_first_draft_passes,
            total,
            first_attempt_greens,
            total,
            greens,
            total,
            intent_passes,
            total,
            staged,
            failures.items.len,
        },
    );
    for (failures.items) |failure| {
        std.debug.print(
            "[codegen-record] failure case={s} kind={s} error={s}\n",
            .{ failure.case_name, @tagName(failure.kind), failure.error_name },
        );
    }
    if (total != selected_case_count) return error.CodegenCorpusCountMismatch;
    if (qualification_cases.items.len != selected_case_count) return error.CodegenCorpusCountMismatch;
    if (live_mode == .qualify) {
        try emitQualificationRun(
            allocator,
            &registry,
            corpus_provider,
            corpus_model,
            model_revision,
            &observed_runtime,
            request_config,
            source_before,
            repo_root,
            diagnostics_run_id,
            record_turn_timeout_ms,
            local_provenance,
            qualification_cases.items,
        );
        std.debug.print(
            "[codegen-record] qualification artifacts remain quarantined at {s}; active corpora and model defaults are unchanged\n",
            .{stage_root},
        );
        return;
    }
    const can_activate = recordingRunCanActivate(canonical_full_run, .{
        .selected = total,
        .staged = staged,
        .applied = greens,
        .intents_passed = intent_passes,
        .recording_failures = recording_failures,
    });
    if (recording_failures != 0 or staged != selected_case_count) {
        std.debug.print(
            "[codegen-record] incomplete run quarantined at {s} " ++
                "({d} case(s) produced no artifact, {d} of {d} staged)\n",
            .{ stage_root, recording_failures, staged, selected_case_count },
        );
        return error.CodegenRecordingRunFailed;
    }
    // Measured model failures do not block activation - they are the
    // measurement - but they are the headline of the run and are said plainly.
    if (greens != selected_case_count or intent_passes != selected_case_count) {
        std.debug.print(
            "[codegen-record] activating a corpus that measures {d} unapplied and " ++
                "{d} intent-failing case(s) of {d}; the published rate reports them\n",
            .{
                selected_case_count - greens,
                selected_case_count - intent_passes,
                selected_case_count,
            },
        );
    }
    if (!can_activate) {
        std.debug.print(
            "[codegen-record] partial, filtered, or non-default-model run quarantined at {s}\n",
            .{stage_root},
        );
        return error.PartialRecordingQuarantined;
    }
    try commitStagedCorpus(allocator, io, stage_root, out_dir);
    std.debug.print(
        "[codegen-record] activated complete {d}-case corpus at {s}\n",
        .{ staged, out_dir },
    );
}

/// The model a committed cassette was recorded against, read from the header
/// line every recording writes (`{"v":1,...,"model":"..."}`).
///
/// The published model column used to be `headline_model`, a compile-time
/// constant, while `ZTTP_CODEGEN_MODEL` was advertised for recording "a second
/// row against another tier". Those two together publish a Haiku measurement
/// under Sonnet's name, which is the one thing the column exists to prevent.
/// Read it from the artefact instead, so the column is measured rather than
/// asserted.
fn cassetteModel(step_0: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, step_0, '\n') orelse step_0.len;
    const header = step_0[0..line_end];
    const needle = "\"model\":\"";
    const start = std.mem.indexOf(u8, header, needle) orelse return null;
    const rest = header[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

test "cassetteModel reads the recorded model from a cassette header" {
    const header =
        \\{"v":1,"provider":"anthropic","scenario":"health","stream":true,"model":"claude-haiku-4-5"}
        \\{"sse":"event: message_start\n"}
    ;
    try testing.expectEqualStrings("claude-haiku-4-5", cassetteModel(header).?);
    // A header without the field, and an empty value, are both "unknown"
    // rather than a silent empty string that would publish as a blank column.
    try testing.expect(cassetteModel("{\"v\":1}\n") == null);
    try testing.expect(cassetteModel("{\"model\":\"\"}\n") == null);
}

// Offline ratchet: replay every committed cassette through the real veto and
// require its recorded first-attempt-green observation to stay stable. Runs in
// normal CI (no network, no key): it reproduces the recorded baseline
// deterministically and fails if a compiler/policy change would regress it.
// Uses an arena over the page allocator (the replay executes the full tool +
// veto stack; this is a fidelity check, not a leak test).
/// Registry rules at least one corpus case trips, as measured on the headline
/// model and committed here.
///
/// The ratchet is one-directional by design: a corpus that grows trips more and
/// nothing here complains, while a corpus that stops standing on a fence fails
/// and names it. Losing coverage is how nine rows came to read 90% while six
/// tightenings landed underneath them, and it is invisible to every other gate
/// on this file - the per-case pin only sees a flipped verdict, never a fence
/// that stopped being felt.
///
/// Five of seventy-two, measured 2026-08-04. That is the finding, not a failure:
/// the corpus was grown to separate builds the headline could not, and it does
/// that on five rules. Four flow rules and one spec-discharge rule, which is a
/// fair description of what these prompts ask for and a poor description of what
/// the compiler proves.
const anthropic_coverage_baseline = [_][]const u8{
    "ZTS400",
    "ZTS401",
    "ZTS407",
    "ZTS500",
    "ZTS502",
};
const anthropic_coverage_legacy_corpus_version = "83c9c0c040e8e6f1f659ddc7d853f9f21bc4c0e1db1837f8cedfb11bad1baf08";

/// Two of seventy-two, measured 2026-08-26 over the 19-case DeepSeek corpus
/// recorded that day, and also the intersection of the three recordings made
/// against this prompt set. Read from the recording rather than carried over:
/// the probe that produced it narrowed this list, ran the replay, and took the
/// tripped set the generator printed. No code appeared that was not already
/// here.
const deepseek_coverage_baseline = [_][]const u8{
    "ZTS400",
    "ZTS500",
};
// Moved again when a full audit of all 19 cases found three more assertions
// stated nowhere the model could read: queued-call's echoed child body,
// nested-dispatch's 201 and `notified` key, and wait-signal's delivered
// payload contents. The identity covers
// the model-visible input, so a prompt edit moves it by construction.
//
// The list above is measured, not carried over. Three recordings now exist
// against the prompt set the identity below names, and `git log
// docs/coverage.json` is the source for each measured set:
//
//   2026-08-17  4  ZTS400 ZTS500 ZTS501 ZTS509
//   2026-08-25  5  ZTS400 ZTS500 ZTS501 ZTS502 ZTS509
//   2026-08-26  2  ZTS400 ZTS500
//
// (The 2026-08-16 measurement of five is not comparable: it was recorded over
// corpus 19dc67a54ec3, a different prompt set.)
//
// ZTS501, ZTS502 and ZTS509 all vary run to run on identical input. On
// 2026-08-26 no draft declared a spec contradicting an imported module, none
// used an unknown spec name, and none tried moving a `workflow.call` inside a
// `durable.step`. Cleaner drafts, and the run measured its best intent rate to
// match. Nothing about the compiler changed.
//
// The sequence 4, 5, 2 is the point, and it is worth stating rather than
// leaving in the numbers: this is not a ratchet that has slipped, it is a
// quantity that is not monotone because it measures the mistakes one model
// happened to make on one draw. Five distinct codes appear across the three
// runs and only these two appear in all of them, so this pin is their
// intersection - a floor under model behaviour, not under compiler coverage,
// and re-pinning it cannot make it the second. What the corpus does not
// exercise is scoped in
// docs/plans/2026-08-26-034-rule-coverage-widening-scope.md; closing it needs
// cases built for the purpose, not a better draw.
const deepseek_coverage_headline_input_id = "0012ad8ca6d5d08ac5023862378fe0c971b3672dadbc079256fb47d810033516";

/// Return the live coverage floor for one exact model-visible input and model.
/// Expected outcomes and thresholds cannot reset this ratchet.
fn coverageBaseline(
    provider: agent.Provider,
    model: []const u8,
    headline_input: evidence_identity.HeadlineInputIdentity,
) ?[]const []const u8 {
    return switch (provider) {
        .deepseek => if (std.mem.eql(u8, model, models.defaultForProvider(.deepseek).id) and
            std.mem.eql(u8, headline_input.slice(), deepseek_coverage_headline_input_id))
            &deepseek_coverage_baseline
        else
            null,
        .local, .anthropic, .openai => null,
    };
}

/// Historical Anthropic evidence predates the separated identities. It remains
/// queryable by its exact legacy hash but is never accepted by the live path.
fn legacyCoverageBaseline(provider: agent.Provider, model: []const u8, legacy_id: []const u8) ?[]const []const u8 {
    if (provider != .anthropic) return null;
    if (!std.mem.eql(u8, model, models.defaultForProvider(.anthropic).id)) return null;
    if (!std.mem.eql(u8, legacy_id, anthropic_coverage_legacy_corpus_version)) return null;
    return &anthropic_coverage_baseline;
}

test "coverage baselines are input provider and model qualified" {
    const headline_input = headlineInputIdentity();
    try testing.expectEqualStrings(deepseek_coverage_headline_input_id, headline_input.slice());
    try testing.expectEqual(
        @as(?[]const []const u8, &anthropic_coverage_baseline),
        legacyCoverageBaseline(.anthropic, models.defaultForProvider(.anthropic).id, anthropic_coverage_legacy_corpus_version),
    );
    try testing.expectEqual(
        @as(?[]const []const u8, &deepseek_coverage_baseline),
        coverageBaseline(.deepseek, models.defaultForProvider(.deepseek).id, headline_input),
    );
    try testing.expect(coverageBaseline(.local, local.default_model, headline_input) == null);
    try testing.expect(legacyCoverageBaseline(.anthropic, "claude-other", anthropic_coverage_legacy_corpus_version) == null);
    try testing.expect(coverageBaseline(.deepseek, "deepseek-v4-pro", headline_input) == null);
    var changed_input = headline_input;
    changed_input.bytes[0] = if (changed_input.bytes[0] == '0') '1' else '0';
    try testing.expect(coverageBaseline(.deepseek, models.defaultForProvider(.deepseek).id, changed_input) == null);
    // The two sets are measurements of different models, not copies.
    //
    // Equal length used to be asserted alongside this and is not the claim: two
    // models can trip the same count and different rules, or different counts
    // entirely, and the second is what happened - the DeepSeek list is now four
    // where the Anthropic one is five. Pairing the slices to compare them also
    // required equal length, so the assertion propped up its own comparison.
    var identical = anthropic_coverage_baseline.len == deepseek_coverage_baseline.len;
    if (identical) {
        for (anthropic_coverage_baseline, 0..) |claude_code, index| {
            if (!std.mem.eql(u8, claude_code, deepseek_coverage_baseline[index])) {
                identical = false;
                break;
            }
        }
    }
    try testing.expect(!identical);
}

/// Sorted code slice for stable JSON evidence.
fn sortedCodes(a: std.mem.Allocator, set: *const codegen.CodeSet) ![][]const u8 {
    const codes = try a.dupe([]const u8, set.keys());
    std.mem.sort([]const u8, codes, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return codes;
}

const OptionalStringConsensus = struct {
    observed: bool = false,
    value: ?[]const u8 = null,

    fn observe(
        self: *OptionalStringConsensus,
        allocator: std.mem.Allocator,
        candidate: ?[]const u8,
    ) !void {
        if (!self.observed) {
            self.observed = true;
            self.value = if (candidate) |bytes| try allocator.dupe(u8, bytes) else null;
            return;
        }
        if ((self.value == null) != (candidate == null)) return error.MixedCorpusIdentity;
        if (self.value) |expected| {
            if (!std.mem.eql(u8, expected, candidate.?)) return error.MixedCorpusIdentity;
        }
    }
};

const RuntimeConsensus = struct {
    observed: bool = false,
    value: ?evidence_identity.RuntimeRevision = null,

    fn observe(
        self: *RuntimeConsensus,
        allocator: std.mem.Allocator,
        candidate: ?evidence_identity.RuntimeRevision,
    ) !void {
        if (!self.observed) {
            self.observed = true;
            self.value = if (candidate) |runtime| .{
                .name = try allocator.dupe(u8, runtime.name),
                .revision = try allocator.dupe(u8, runtime.revision),
            } else null;
            return;
        }
        if ((self.value == null) != (candidate == null)) return error.MixedCorpusIdentity;
        if (self.value) |expected| {
            const actual = candidate.?;
            if (!std.mem.eql(u8, expected.name, actual.name) or
                !std.mem.eql(u8, expected.revision, actual.revision))
            {
                return error.MixedCorpusIdentity;
            }
        }
    }
};

fn manifestRuntime(manifest: *const flow_artifact.FlowManifest) !?evidence_identity.RuntimeRevision {
    if (manifest.mlx_lm_version) |revision| {
        if (manifest.runtime_name != null or manifest.runtime_version != null) {
            return error.AmbiguousProviderRuntime;
        }
        return .{ .name = "mlx-lm", .revision = revision };
    }
    if ((manifest.runtime_name == null) != (manifest.runtime_version == null)) {
        return error.IncompleteProviderRuntime;
    }
    if (manifest.runtime_name) |name| {
        return .{ .name = name, .revision = manifest.runtime_version.? };
    }
    return null;
}

fn artifactIdentity(
    allocator: std.mem.Allocator,
    resolved: *const ResolvedSteps,
) !evidence_identity.ContentDigest {
    if (resolved.flow_case) |flow_case| {
        return evidence_identity.contentDigest("flow-artifact", flow_case.flow_version.slice());
    }
    const parts = try allocator.alloc([]const u8, resolved.steps.len);
    for (resolved.steps, 0..) |step, index| parts[index] = step;
    return evidence_identity.contentDigestParts("flat-cassette-responses", parts);
}

const SourceIdentity = struct {
    revision: evidence_identity.SourceRevision,
    known: bool,
};

fn isLowerHex(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn readSourceIdentity(allocator: std.mem.Allocator, repo_root: []const u8) SourceIdentity {
    var head = tool_common.runCommand(
        allocator,
        repo_root,
        &.{ "git", "rev-parse", "HEAD" },
    ) catch return .{ .revision = .{ .commit = "unknown", .dirty = true }, .known = false };
    defer head.deinit(allocator);
    const commit = std.mem.trim(u8, head.stdout, " \t\r\n");
    if (!head.ok or commit.len != 40 or !isLowerHex(commit)) {
        return .{ .revision = .{ .commit = "unknown", .dirty = true }, .known = false };
    }

    var status = tool_common.runCommand(
        allocator,
        repo_root,
        &.{ "git", "status", "--porcelain", "--untracked-files=normal" },
    ) catch return .{ .revision = .{ .commit = "unknown", .dirty = true }, .known = false };
    defer status.deinit(allocator);
    if (!status.ok) {
        return .{ .revision = .{ .commit = "unknown", .dirty = true }, .known = false };
    }
    return .{
        .revision = .{
            .commit = allocator.dupe(u8, commit) catch
                return .{ .revision = .{ .commit = "unknown", .dirty = true }, .known = false },
            .dirty = std.mem.trim(u8, status.stdout, " \t\r\n").len != 0,
        },
        .known = true,
    };
}

fn replayIsFiltered() bool {
    inline for (&.{ "ZTTP_CODEGEN_ONLY", "ZTTP_CODEGEN_LIMIT", "ZTTP_CODEGEN_TOOLS" }) |name| {
        if (envValue(name)) |value| if (value.len != 0) return true;
    }
    return false;
}

fn evidencePublicationMode() bool {
    const value = envValue("ZTTP_EVIDENCE_PUBLISH") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn publishableEvidence(
    filtered: bool,
    publication_mode: bool,
    source_known: bool,
    expected: usize,
    completed: usize,
    corpus_cases: usize,
) bool {
    return !filtered and publication_mode and source_known and expected == 19 and completed == expected and
        corpus_cases == expected;
}

/// Whether a run's numbers are sound enough to publish - not whether they are
/// good.
///
/// This gated on the value of the very number it publishes: greens == 19, raw
/// first-draft >= 14, median <= 4, intent 18 of 18. Measured against four full
/// runs, every one of those is unreachable: greens ranged 16 to 18, raw 10 to
/// 12, intent 15 to 18, and the median was 5 in all four. The row already on
/// docs/convergence.md fails all of them too - 9 raw, median 5. The thresholds
/// were written on 2026-08-16 and no publication has run since, so they were
/// never tested against a real corpus, and they are aspiration rather than
/// measurement.
///
/// Flooring the headline metric is also the wrong shape. docs/convergence.md
/// publishes a first-draft pass rate and forbids re-recording "until it
/// flatters"; a floor on that rate means the page can only ever carry good
/// news, which makes it a claim rather than a measurement.
///
/// So what remains asserts that the measurement happened and covered the whole
/// corpus. A number that is bad is published and explained. A number that is
/// unsound is refused.
fn expertQualityGate(summary: codegen.CodegenSummary) bool {
    // Every case measured. A short corpus reports a rate over a denominator
    // that is not the corpus.
    if (summary.total != 19) return false;
    // Every intent-declaring case actually ran its check. `intent_checked` is
    // the denominator of the published intent rate, so a check that silently
    // did not run would inflate it. One case is compiler-veto-only by design,
    // which is why this is 18 and not 19.
    if (summary.intent_checked != 18) return false;
    // Zero means no round-trip was counted at all, which is a broken
    // measurement rather than an unusually fast one.
    if (summary.median_roundtrips == 0) return false;
    // The run produced signal, which a denominator on its own cannot say. The
    // thresholds above are not coming back; this is the other claim, and
    // dropping it left nothing between a bad model run and a broken harness.
    //
    // An intent harness that regressed - a missing binary, a changed
    // intent.test.jsonl schema - runs all 18 checks and fails all 18. That
    // leaves intent_checked at 18 and median_roundtrips non-zero, so the gate
    // passed and docs/convergence.md published intentPassPercent: 0 as a
    // measured property of the model.
    //
    // Nineteen handlers the veto accepted, none of which does what its prompt
    // asked, is not a model result: the compiler already agreed they are
    // programs. Nor is zero green out of nineteen, which is the same fault one
    // stage earlier. Both floors sit far below every measured run - greens 16
    // to 18, intent 15 to 18 - so neither can force a re-record until the
    // numbers flatter.
    if (summary.greens == 0) return false;
    if (summary.intent_passes == 0) return false;
    return true;
}

fn neutralCatalogIdentity(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.Registry,
) !evidence_identity.ProviderNeutralCatalogIdentity {
    var definitions: std.ArrayList(tool_catalog.Definition) = .empty;
    defer definitions.deinit(allocator);
    var it = tool_catalog.iterator(registry);
    while (it.next()) |definition| try definitions.append(allocator, definition);
    if (definitions.items.len == 0) return error.EmptyToolCatalog;
    return evidence_identity.providerNeutralCatalog(definitions.items);
}

fn compilerEvidenceIdentities(allocator: std.mem.Allocator) !evidence_identity.CompilerIdentities {
    const schema_hash = zts_cli.agent_protocol.schemaHash();
    const grammar_hash = zts.grammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostic_hash = zts.diagnosticCatalogHash();
    const policy_hash = zts.policyHash();
    const idiom_hash = zts.idiomTableHash();
    const restriction_hash = zts.restrictionMatrixHash();
    const builtin_hash = zts.ModuleMetadata.builtinRegistryHash();
    const module_graph_hash = zts_cli.module_graph_record.contextFreeHash();

    const meta_bytes = try std.fmt.allocPrint(
        allocator,
        "compiler-version\x00{s}\x00policy-version\x00{s}\x00profile-id\x00{s}" ++
            "\x00schema\x00{s}\x00policy\x00{s}\x00grammar\x00{s}\x00idioms\x00{s}" ++
            "\x00restrictions\x00{s}\x00builtins\x00{s}\x00module-graph\x00{s}" ++
            "\x00semantics\x00{s}\x00diagnostics\x00{s}",
        .{
            zts_cli.expert_meta.compiler_version,
            zts_cli.expert_meta.policy_version,
            zts_cli.agent_identity.profile_id,
            schema_hash,
            policy_hash,
            grammar_hash,
            idiom_hash,
            restriction_hash,
            builtin_hash,
            module_graph_hash,
            semantics_hash,
            diagnostic_hash,
        },
    );
    return .{
        .schema = evidence_identity.schema(&schema_hash),
        .meta = evidence_identity.meta(meta_bytes),
        .grammar = evidence_identity.grammar(&grammar_hash),
        .semantics = evidence_identity.semantics(&semantics_hash),
        .diagnostics = evidence_identity.diagnostics(&diagnostic_hash),
        .policy = evidence_identity.policy(&policy_hash),
    };
}

const MarkerRequestPolicy = struct {
    maxOutputTokens: u32,
    reserveTokens: u64,
    stream: bool,
    purpose: []const u8,
    cachePolicy: []const u8,
};

const MarkerRuntime = struct {
    name: []const u8,
    revision: []const u8,
};

fn markerJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = TextBuffer.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, out.writer());
    return try out.toOwnedSlice();
}

fn contentDigestFromHex(value: []const u8) !evidence_identity.ContentDigest {
    if (value.len != 64 or !isLowerHex(value)) return error.InvalidArtifactIdentity;
    var out: evidence_identity.ContentDigest = undefined;
    @memcpy(&out.bytes, value);
    return out;
}

fn emitQualificationRun(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    provider: agent.Provider,
    model: []const u8,
    model_revision: ?[]const u8,
    observed_runtime: *const RuntimeConsensus,
    request_config: model_request.Config,
    source_before: SourceIdentity,
    repo_root: []const u8,
    run_suffix: []const u8,
    turn_timeout_ms: u64,
    local_provenance: ?qualification.LocalProvenance,
    cases: []const qualification.CaseResult,
) !void {
    if (cases.len != record_corpus.len) return error.CodegenCorpusCountMismatch;
    const source_after = readSourceIdentity(allocator, repo_root);
    if (!source_before.known or !source_after.known or
        source_before.revision.dirty != source_after.revision.dirty or
        !std.mem.eql(u8, source_before.revision.commit, source_after.revision.commit))
    {
        return error.SourceChangedDuringQualification;
    }

    const tools_json = request_config.tools_json orelse return error.EmptyToolCatalog;
    const request_policy: evidence_identity.RequestPolicy = .{
        .max_output_tokens = request_config.max_output_tokens,
        .reserve_tokens = request_config.reserve_tokens,
        .stream = request_config.stream,
        .purpose = request_config.purpose,
        .cache_policy = request_config.cache_policy,
    };
    const prompt_persona = evidence_identity.promptPersona(request_config.system_prompt);
    const catalogs: evidence_identity.CatalogIdentities = .{
        .provider_neutral = try neutralCatalogIdentity(allocator, registry),
        .provider_serialized = evidence_identity.providerSerializedCatalog(tools_json),
    };
    const compiler = try compilerEvidenceIdentities(allocator);
    const cohorts: evidence_identity.ManifestComponents = .{
        .headline_input = headlineInputIdentity(),
        .intent_suite = intentSuiteIdentity(),
        .security_probes = securityProbeIdentity(),
        .thresholds = thresholdIdentity(),
    };
    const manifest_identity = evidence_identity.manifest(cohorts);
    const provider_runtime = if (observed_runtime.observed) observed_runtime.value else null;
    const run_id = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{ source_after.revision.commit[0..12], run_suffix },
    );

    const observations = try allocator.alloc(evidence_identity.ObservedResult, cases.len);
    for (cases, 0..) |case, index| {
        observations[index] = .{
            .scenario = case.name,
            .artifact_identity = if (case.artifact_identity) |identity|
                try contentDigestFromHex(identity)
            else
                null,
            .draft_quality = case.draft_quality,
            .intent_outcome = case.intent,
            .applied = case.applied,
            .roundtrips = case.roundtrips,
        };
    }
    const result_run = evidence_identity.resultRun(.{
        .provider = provider,
        .model = model,
        .model_revision = model_revision,
        .provider_runtime = provider_runtime,
        .request_policy = request_policy,
        .prompt_persona = prompt_persona,
        .catalogs = catalogs,
        .compiler = compiler,
        .cohorts = cohorts,
        .source_revision = source_after.revision,
        .run_id = run_id,
        .observations = observations,
    });
    const defaults: loop.RunOptions = .{};
    const summary = qualification.summarize(cases);
    const run: qualification.Run = .{
        .schema_version = qualification.schema_version,
        .run_id = run_id,
        .result_run_hash = result_run.slice(),
        .complete = true,
        .filtered = false,
        .report_only = true,
        .default_change_authorized = false,
        .identity = .{
            .provider = provider.publicName(),
            .model = model,
            .model_revision = model_revision,
            .provider_runtime = if (provider_runtime) |runtime| .{
                .name = runtime.name,
                .revision = runtime.revision,
            } else null,
            .request_policy = .{
                .max_output_tokens = request_policy.max_output_tokens,
                .reserve_tokens = request_policy.reserve_tokens,
                .stream = request_policy.stream,
                .purpose = @tagName(request_policy.purpose),
                .cache_policy = @tagName(request_policy.cache_policy),
            },
            .provider_tool_count = tool_catalog.count(registry),
            .provider_tool_bytes = tools_json.len,
            .headline_input_hash = cohorts.headline_input.slice(),
            .intent_suite_hash = cohorts.intent_suite.slice(),
            .security_probe_hash = cohorts.security_probes.slice(),
            .threshold_hash = cohorts.thresholds.slice(),
            .manifest_hash = manifest_identity.slice(),
            .prompt_persona_hash = prompt_persona.slice(),
            .provider_neutral_catalog_hash = catalogs.provider_neutral.slice(),
            .provider_serialized_catalog_hash = catalogs.provider_serialized.slice(),
            .schema_hash = compiler.schema.slice(),
            .meta_hash = compiler.meta.slice(),
            .grammar_hash = compiler.grammar.slice(),
            .semantics_hash = compiler.semantics.slice(),
            .diagnostic_hash = compiler.diagnostics.slice(),
            .policy_hash = compiler.policy.slice(),
        },
        .source = .{
            .commit = source_after.revision.commit,
            .dirty = source_after.revision.dirty,
            .known = source_after.known,
        },
        .limits = .{
            .turn_timeout_ms = turn_timeout_ms,
            .max_model_roundtrips_per_turn = defaults.max_model_roundtrips_per_turn,
            .max_tool_calls_per_turn = defaults.max_tool_calls_per_turn,
        },
        .local_provenance = local_provenance,
        .cases = cases,
        .summary = summary,
    };
    const status = qualification.assessRun(run);
    std.debug.print(
        "[expert-qualification-status] candidate={s}/{s} passed={} reason={s}\n",
        .{
            provider.publicName(),
            model,
            status == null,
            if (status) |reason| @tagName(reason) else "none",
        },
    );
    const marker = try markerJson(allocator, run);
    std.debug.print("[expert-qualification-run] {s}\n", .{marker});
}

test "corpus evidence consensus and publication floor fail closed" {
    var optional: OptionalStringConsensus = .{};
    try optional.observe(testing.allocator, "r1");
    defer testing.allocator.free(optional.value.?);
    try optional.observe(testing.allocator, "r1");
    try testing.expectError(error.MixedCorpusIdentity, optional.observe(testing.allocator, null));
    try testing.expectError(error.MixedCorpusIdentity, optional.observe(testing.allocator, "r2"));

    var runtime: RuntimeConsensus = .{};
    try runtime.observe(testing.allocator, .{ .name = "mlx-lm", .revision = "1" });
    defer {
        testing.allocator.free(runtime.value.?.name);
        testing.allocator.free(runtime.value.?.revision);
    }
    try runtime.observe(testing.allocator, .{ .name = "mlx-lm", .revision = "1" });
    try testing.expectError(
        error.MixedCorpusIdentity,
        runtime.observe(testing.allocator, .{ .name = "mlx-lm", .revision = "2" }),
    );

    try testing.expect(publishableEvidence(false, true, true, 19, 19, 19));
    try testing.expect(!publishableEvidence(true, true, true, 19, 19, 19));
    try testing.expect(!publishableEvidence(false, false, true, 19, 19, 19));
    try testing.expect(!publishableEvidence(false, true, false, 19, 19, 19));
    try testing.expect(!publishableEvidence(false, true, true, 19, 18, 19));
    try testing.expect(!publishableEvidence(false, true, true, 19, 19, 0));

    const passing_quality: codegen.CodegenSummary = .{
        .total = 19,
        .routed = 19,
        .raw_first_draft_passes = 14,
        .first_attempt_greens = 14,
        .greens = 19,
        .criterion_passes = 14,
        .intent_passes = 18,
        .intent_checked = 18,
        .median_roundtrips = 4,
    };
    try testing.expect(expertQualityGate(passing_quality));

    // A worse run publishes. These are the four measurements the gate used to
    // refuse, at the values four real runs actually produced: greens 16 to 18,
    // raw 10 to 12, intent 15 to 18, median 5 every time. Refusing them meant
    // the page could only ever carry good news, and the row already published
    // on it - 9 raw, median 5 - fails the same thresholds.
    var measured = passing_quality;
    measured.greens = 16;
    measured.raw_first_draft_passes = 10;
    measured.first_attempt_greens = 10;
    measured.intent_passes = 15;
    measured.median_roundtrips = 5;
    try testing.expect(expertQualityGate(measured));

    // An unsound measurement still refuses. A short corpus reports a rate over
    // the wrong denominator.
    var unsound = passing_quality;
    unsound.total = 18;
    try testing.expect(!expertQualityGate(unsound));
    // An intent check that did not run would inflate the published intent rate.
    unsound = passing_quality;
    unsound.intent_checked = 17;
    try testing.expect(!expertQualityGate(unsound));
    // No round-trip counted at all is a broken run, not a fast one.
    unsound = passing_quality;
    unsound.median_roundtrips = 0;
    try testing.expect(!expertQualityGate(unsound));
    // Every intent check ran and every one failed. The denominator is intact,
    // so the gate saw nothing wrong and the page published intentPassPercent: 0
    // as a property of the model. Nineteen veto-accepted handlers, none of
    // which does what its prompt asked, is a harness fault.
    unsound = passing_quality;
    unsound.intent_passes = 0;
    try testing.expect(!expertQualityGate(unsound));
    // The same fault one stage earlier: nothing reached green at all.
    unsound = passing_quality;
    unsound.greens = 0;
    try testing.expect(!expertQualityGate(unsound));
    // And the floors stay below the worst real run, so neither can force a
    // re-record until the numbers flatter.
    var worst_measured = measured;
    worst_measured.greens = 1;
    worst_measured.intent_passes = 1;
    try testing.expect(expertQualityGate(worst_measured));
}

/// Fail when `docs/coverage.json` no longer describes this run.
///
/// The page is generated from the line this replay prints, so a corpus that
/// grew, a rule that was added, or a compiler change that moved what the corpus
/// reaches all leave it stale - and a stale coverage page is worse than none,
/// because it is cited as the current answer. Three fields are enough to catch
/// every one of those: the corpus identity, the denominator, and the count.
///
/// A missing or unparseable file is a failure, never a skip. An absent page
/// reads exactly like a page that agrees.
fn assertCoveragePageCurrent(
    a: std.mem.Allocator,
    repo_root: []const u8,
    version: []const u8,
    tripped_count: usize,
) !void {
    const path = try std.fmt.allocPrint(a, "{s}/docs/coverage.json", .{repo_root});
    const bytes = zts.file_io.readFile(a, path, 64 * 1024) catch |err| {
        std.debug.print(
            "[proof-coverage] cannot read docs/coverage.json ({s}); regenerate with" ++
                " `bash scripts/update-coverage.sh`\n",
            .{@errorName(err)},
        );
        return error.CoveragePageUnreadable;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch |err| {
        std.debug.print(
            "[proof-coverage] docs/coverage.json does not parse ({s}); regenerate with" ++
                " `bash scripts/update-coverage.sh`\n",
            .{@errorName(err)},
        );
        return error.CoveragePageUnreadable;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.CoveragePageUnreadable;

    const published_version = parsed.value.object.get("corpusVersion") orelse return error.CoveragePageUnreadable;
    const published_total = parsed.value.object.get("rulesTotal") orelse return error.CoveragePageUnreadable;
    const published_tripped = parsed.value.object.get("rulesTripped") orelse return error.CoveragePageUnreadable;
    if (published_version != .string or published_total != .integer or published_tripped != .integer) {
        return error.CoveragePageUnreadable;
    }

    const total: i64 = @intCast(zts.PolicyCatalog.rules().len);
    const count: i64 = @intCast(tripped_count);
    if (!std.mem.eql(u8, published_version.string, version) or
        published_total.integer != total or
        published_tripped.integer != count)
    {
        std.debug.print(
            "[proof-coverage] docs/coverage.json is stale: it says corpus {s}, {d} of {d};" ++
                " this run measured {s}, {d} of {d}. Regenerate with" ++
                " `bash scripts/update-coverage.sh`\n",
            .{
                published_version.string[0..@min(12, published_version.string.len)],
                published_tripped.integer,
                published_total.integer,
                version[0..@min(12, version.len)],
                count,
                total,
            },
        );
        return error.CoveragePageStale;
    }
}

/// The registry rules no case tripped, in registry order.
fn untrippedCodes(a: std.mem.Allocator, tripped: *const codegen.CodeSet) ![][]const u8 {
    var codes: std.ArrayList([]const u8) = .empty;
    for (zts.PolicyCatalog.rules()) |rule| {
        if (tripped.contains(rule.code)) continue;
        try codes.append(a, rule.code);
    }
    return try codes.toOwnedSlice(a);
}

test "codegen baseline replays at the committed first-attempt green rate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const repo_root = try cwdPathAlloc(a);
    const replay_provider = if (envValue("ZTTP_CODEGEN_REPLAY_PROVIDER")) |name|
        agent.Provider.parsePublic(name) orelse return error.UnsupportedRecordingProvider
    else
        headline_provider;

    var registry = try app.buildRegistry(a);
    defer registry.deinit(a);

    // Located before the per-case chdir: the binary lives in the repo, and the
    // cases run in tmp workspaces.
    const zttp_bin = codegen.locateZttpBinary(a, repo_root);

    var passes: usize = 0;
    var intent_passes: usize = 0;
    var intent_checked: usize = 0;
    var results: std.ArrayList(codegen.CaseResult) = .empty;
    defer results.deinit(a);
    var observations: std.ArrayList(evidence_identity.ObservedResult) = .empty;
    defer observations.deinit(a);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(a);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(a);
    // The model every cassette agrees on. Null until the first one is read; a
    // disagreement means the corpus is half re-recorded against another tier,
    // which would publish one row averaging two models.
    var corpus_model: ?[]const u8 = null;
    var models_read: usize = 0;
    var model_revision: OptionalStringConsensus = .{};
    var provider_runtime: RuntimeConsensus = .{};
    // How far the migration off flat cassettes has got. Reported rather than
    // asserted: the count moves only when a case is re-recorded for its own
    // reasons, so a target here would be a reason to re-record, which is the
    // one thing the corpus rules forbid.
    var flow_backed: usize = 0;
    // Which fences the corpus actually stands on, accumulated across cases.
    // Published under its own marker: this is a fact about the corpus and the
    // compiler, not a measurement of a model, and the two must never be lifted
    // into the same table.
    var tripped: codegen.CodeSet = .empty;
    defer tripped.deinit(a);
    var off_registry: codegen.CodeSet = .empty;
    defer off_registry.deinit(a);
    for (record_corpus) |rc| {
        var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer case_arena.deinit();
        const ca = case_arena.allocator();
        // Read the responses from the repo (absolute) BEFORE chdir. A real read
        // error propagates; an absent recording yields no steps and is
        // collected so the whole set is reported at once instead of aborting
        // on the first missing case.
        var resolved = try resolveCurrentCaseStepsForTest(ca, repo_root, replay_provider, rc.name);
        defer resolved.deinit(ca);
        const response_count = resolved.responseCount();
        if (response_count == 0) {
            try missing.append(a, rc.name);
            continue;
        }
        if (resolved.source == .flow_artifact) flow_backed += 1;

        const case_artifact_identity = try artifactIdentity(ca, &resolved);
        if (resolved.flow_case) |flow_case| {
            if (flow_case.manifest.provider != replay_provider) return error.MixedProviderCorpus;
            try model_revision.observe(a, flow_case.manifest.model_revision);
            try provider_runtime.observe(a, try manifestRuntime(&flow_case.manifest));
        } else {
            try model_revision.observe(a, null);
            try provider_runtime.observe(a, null);
        }

        if (resolved.model()) |model| {
            models_read += 1;
            if (corpus_model) |seen| {
                if (!std.mem.eql(u8, seen, model)) {
                    std.debug.print(
                        "[codegen-replay] {s} was recorded against {s}, but earlier cassettes say {s};" ++
                            " a mixed-model corpus cannot publish one model column\n",
                        .{ rc.name, model, seen },
                    );
                    return error.MixedModelCorpus;
                }
            } else corpus_model = try a.dupe(u8, model);
        }

        var tmp = try IsolatedTmp.init(ca, "codegen-replay");
        defer tmp.cleanup(ca);
        for (rc.seed_files) |sf| try tmp.writeFile(ca, sf.path, sf.bytes);

        const saved_cwd = try cwdPathAlloc(ca);
        try std.Io.Threaded.chdir(tmp.abs_path);
        defer std.Io.Threaded.chdir(saved_cwd) catch {};

        var replay_context: ?ReplayRequestContext = null;
        defer if (replay_context) |*context| context.deinit(ca);
        if (resolved.flow_case) |*flow_case| {
            replay_context = try ReplayRequestContext.init(
                ca,
                &registry,
                replay_provider,
                flow_case.manifest.model,
            );
        }
        var client = try CorpusReplayClient.init(
            &resolved,
            if (replay_context) |context| context.config else null,
        );
        // A cassette that no longer covers its turn is collected, not thrown.
        // Returning at the first stale case means a compiler change that
        // invalidates several is discovered one paid recording at a time; the
        // whole re-record list is worth more than the early exit.
        var outcome = replayCorpusTurn(
            ca,
            &resolved,
            &client,
            if (replay_context) |context| context.config else null,
            replay_provider,
            &registry,
            rc.prompt,
        ) catch |err| {
            try stale.append(a, rc.name);
            std.debug.print(
                "[codegen-replay] {s}: {s} - its {d}-step cassette no longer covers the turn\n",
                .{ rc.name, @errorName(err), response_count },
            );
            continue;
        };
        defer outcome.deinit(ca);
        const result = outcome.result;
        const tr = &outcome.transcript;
        client.finish() catch |err| {
            try stale.append(a, rc.name);
            std.debug.print(
                "[codegen-replay] {s}: {s} - its {d}-step flow has unconsumed checkpoints\n",
                .{ rc.name, @errorName(err), response_count },
            );
            continue;
        };
        try codegen.collectCodes(a, tr, &tripped, &off_registry);

        // Ratchet each provider against its own recorded observation. Claude's
        // historical flat cassettes predate provider-qualified turn metadata,
        // so their immutable corpus pin remains the compatibility source.
        const recorded_draft: ?flow_artifact.DraftExpectation = if (resolved.flow_case) |flow_case| blk: {
            const expectation = flow_case.manifest.turns[0].draftExpectation() catch unreachable;
            break :blk switch (expectation) {
                .unmeasured => null,
                else => expectation,
            };
        } else null;
        const case_model = resolved.model() orelse headline_model;
        const on_headline = replay_provider == headline_provider and
            std.mem.eql(u8, case_model, headline_model);
        if (recorded_draft) |expected| {
            if (!expected.matches(result.draft_quality)) {
                std.debug.print(
                    "[codegen-replay] {s}: recorded draft metric disagrees with {s} (code {s}){s}\n",
                    .{
                        rc.name,
                        @tagName(result.draft_quality),
                        codegen.firstZtsCode(tr) orelse "-",
                        if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                    },
                );
                if (on_headline) return error.CassetteRatchetMismatch;
            }
        } else if (firstAttemptExpectation(replay_provider, null, rc.expect_first_attempt_green)) |expected| {
            if (result.firstAttemptGreen() != expected) {
                std.debug.print(
                    "[codegen-replay] {s}: expected first_attempt_green={} got {} (code {s}){s}\n",
                    .{
                        rc.name,
                        expected,
                        result.firstAttemptGreen(),
                        codegen.firstZtsCode(tr) orelse "-",
                        if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                    },
                );
                if (on_headline) return error.CassetteRatchetMismatch;
            }
        } else {
            std.debug.print(
                "[codegen-replay] {s}: provider {s} has no recorded first-attempt expectation{s}\n",
                .{
                    rc.name,
                    replay_provider.publicName(),
                    if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                },
            );
            if (on_headline) return error.MissingProviderFirstDraftExpectation;
        }
        var case_intent: codegen.IntentOutcome = switch (rc.intent) {
            .compiler_veto_only => .compiler_veto_only,
            .runtime => .not_checked,
        };

        // Intent: does the produced handler do what the prompt asked for? Run
        // after the turn, against whatever it actually wrote. A case with no
        // executable scenario whose binary is unavailable stays
        // `.not_checked` - never a pass, so an unmeasured corpus reads as
        // unmeasured. The one compiler-veto-only case has its own explicit tag.
        if (runtimeIntent(rc.intent)) |intent| {
            if (zttp_bin) |bin| {
                case_intent = codegen.runIntentCheck(ca, intent, tmp.abs_path, bin);
                if (case_intent == .passed) intent_passes += 1 else {
                    std.debug.print("[codegen-intent] {s}: handler did not do the task\n", .{rc.name});
                }
                intent_checked += 1;
            }
        }

        // Gap histogram: the first rule each non-passing case tripped, ranking
        // which teaching gap to close next.
        if (!result.rawFirstDraftVetoPass()) {
            std.debug.print("[codegen-gap] {s}: {s} (green={})\n", .{
                rc.name,
                codegen.firstZtsCode(tr) orelse "?",
                result.applied_change_set,
            });
        }
        try results.append(a, .{
            .name = rc.name,
            .routed = true,
            .draft_quality = result.draft_quality,
            .applied = result.applied_change_set,
            .passed_criterion = result.rawFirstDraftVetoPass(),
            .roundtrips = result.roundtrips,
            .tool_calls = result.tool_call_count,
            .proven_guarantees = result.proven_guarantees,
            .intent = case_intent,
        });
        try observations.append(a, .{
            .scenario = rc.name,
            .artifact_identity = case_artifact_identity,
            .draft_quality = result.draft_quality,
            .intent_outcome = case_intent,
            .applied = result.applied_change_set,
            .roundtrips = result.roundtrips,
        });
        passes += 1;
    }

    if (stale.items.len > 0) {
        std.debug.print("[codegen-replay] {d} cassette(s) need re-recording:\n", .{stale.items.len});
        for (stale.items) |name| std.debug.print("  - {s}\n", .{name});
        const command = try recordingCommand(a, replay_provider);
        std.debug.print("  {s}\n", .{command});
        return error.StaleCodegenCassette;
    }

    if (missing.items.len > 0) {
        std.debug.print("[codegen-replay] missing committed cassette(s) for {d} case(s):\n", .{missing.items.len});
        for (missing.items) |name| std.debug.print("  - {s}\n", .{name});
        const command = try recordingCommand(a, replay_provider);
        std.debug.print(
            "  record with: {s}\n" ++
                "  (the filter is a build option; `-- --test-filter` is dropped and records the whole corpus)\n",
            .{command},
        );
        return error.MissingCodegenCassette;
    }
    try testing.expectEqual(record_corpus.len, passes);
    std.debug.print(
        "[codegen-replay] {d}/{d} case(s) replayed from a flow artifact, {d} from a flat cassette\n",
        .{ flow_backed, record_corpus.len, record_corpus.len - flow_backed },
    );

    // Floor on the model read, before the column it feeds means anything. A
    // header-format change would leave `corpus_model` null on every case and
    // the column would silently fall back to the constant it used to assert -
    // the same defect this replaced, reintroduced quietly. Require every
    // replayed case to have yielded a model.
    if (corpus_model == null or models_read != record_corpus.len) {
        std.debug.print(
            "[codegen-replay] read a model from {d}/{d} cassettes; the header format changed" ++
                " and the published model column cannot be trusted\n",
            .{ models_read, record_corpus.len },
        );
        return error.CassetteModelUnreadable;
    }
    const published_model = corpus_model.?;

    const summary = codegen.summarize(results.items);
    const headline_input = headlineInputIdentity();
    const version = headline_input.bytes;
    var tripped_sorted: []const []const u8 = &.{};
    var untripped_sorted: []const []const u8 = &.{};
    var off_sorted: []const []const u8 = &.{};

    // What the corpus covers, published apart from the headline and under its
    // own marker.
    //
    // The headline says how often exact model-authored bytes pass. It cannot say whether the
    // corpus stands on the fences that moved, and for nine consecutive rows over
    // one corpus it did not: every row read 90% across six tightenings and one
    // loosening, and the page argued in prose, per row, that no case could feel
    // them. Both sets are closed and comptime-derivable, and `policyHash()` was
    // already imported here, so the join was one import away the whole time.
    //
    // `offRegistry` is the honest half. `all_rules` does not carry the parser,
    // stripper, bool-checker, or type-checker codes, so a count taken over it
    // alone would report a corpus as covering less than it does and would hide
    // that the policy hash cannot see those diagnostics at all.
    {
        // Floor on the denominator before the ratio means anything: a registry
        // that failed to assemble would publish "0 of 0" as a finished
        // measurement.
        if (zts.PolicyCatalog.rules().len < 35) {
            std.debug.print(
                "[proof-coverage] the rule registry carries {d} rules; the denominator is not credible\n",
                .{zts.PolicyCatalog.rules().len},
            );
            return error.RuleRegistryTooSmall;
        }
        // Floor on the collector. Zero tripped rules over a corpus this size is
        // a scan that stopped working, not a finding about the corpus.
        if (tripped.count() == 0) {
            std.debug.print(
                "[proof-coverage] no case tripped any registry rule; the collector reads no diagnostics\n",
                .{},
            );
            return error.CoverageCollectorEmpty;
        }

        tripped_sorted = try sortedCodes(a, &tripped);
        off_sorted = try sortedCodes(a, &off_registry);
        // The complement is carried on the line rather than left to be derived,
        // so a reader of docs/coverage.json needs no copy of the registry to see
        // what the corpus does not reach. It is also the half worth reading.
        untripped_sorted = try untrippedCodes(a, &tripped);

        const on_headline = replay_provider == headline_provider and
            std.mem.eql(u8, published_model, headline_model);
        if (coverageBaseline(replay_provider, published_model, headline_input)) |baseline| {
            // Floor on the selected baseline itself. An emptied list makes the
            // loop below iterate nothing and report a clean ratchet over no
            // claim at all, which is the shape this repo has been bitten by.
            if (baseline.len == 0) {
                std.debug.print(
                    "[proof-coverage] the {s}/{s} baseline names {d} rules; it cannot ratchet anything\n",
                    .{ replay_provider.publicName(), published_model, baseline.len },
                );
                return error.CoverageBaselineEmpty;
            }

            var lost: usize = 0;
            for (baseline) |code| {
                if (tripped.contains(code)) continue;
                lost += 1;
                std.debug.print(
                    "[proof-coverage] {s} was tripped by the baseline corpus and is not tripped now{s}\n",
                    .{ code, if (on_headline) "" else " - off-headline provider or model, measured not ratcheted" },
                );
            }
            if (lost > 0 and on_headline) return error.CoverageRatchetMismatch;
        } else {
            std.debug.print(
                "[proof-coverage] {s}/{s} has no committed coverage baseline{s}\n",
                .{
                    replay_provider.publicName(),
                    published_model,
                    if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                },
            );
            if (on_headline) return error.MissingProviderCoverageBaseline;
        }

        // The published page must be the page this run would write. Checked here
        // rather than in a docs-drift script because the numbers are already in
        // hand and re-deriving them anywhere else would be a second
        // implementation to disagree with.
        //
        // Off-headline runs skip it: the tripped set is a property of the model's
        // drafts, so a smaller tier legitimately writes a different page and must
        // not be able to overwrite the committed one by failing here.
        if (on_headline and !evidencePublicationMode()) {
            try assertCoveragePageCurrent(a, repo_root, version[0..], tripped.count());
        }
    }

    // Roadmap item 3's comparison, reported apart from the headline because it
    // is a different claim: not how often a first draft lands, but whether a
    // constructed frame costs fewer round-trips than an empty workspace.
    //
    // Medians rather than means, for the reason the headline column already
    // gives - one case that never converges must not set the number for the
    // rest. Both arms assert a floor before their median is printed: a mode
    // with no cases would otherwise report 0 and read as "free".
    {
        var whole_rt: std.ArrayList(u8) = .empty;
        defer whole_rt.deinit(a);
        var hole_rt: std.ArrayList(u8) = .empty;
        defer hole_rt.deinit(a);
        for (record_corpus, 0..) |rc, i| {
            if (i >= results.items.len) break;
            const rt = results.items[i].roundtrips;
            switch (rc.mode) {
                .whole_file => try whole_rt.append(a, rt),
                .holes => try hole_rt.append(a, rt),
            }
        }
        if (whole_rt.items.len == 0 or hole_rt.items.len == 0) {
            std.debug.print(
                "[codegen-holes] one arm is empty ({d} whole-file, {d} holes); the comparison" ++
                    " cannot be published from a corpus that holds only one mode\n",
                .{ whole_rt.items.len, hole_rt.items.len },
            );
            return error.HoleComparisonArmEmpty;
        }
        std.mem.sort(u8, whole_rt.items, {}, std.sort.asc(u8));
        std.mem.sort(u8, hole_rt.items, {}, std.sort.asc(u8));
        std.debug.print(
            "[codegen-holes] median round-trips: whole_file={d} (n={d}), holes={d} (n={d})\n",
            .{
                whole_rt.items[whole_rt.items.len / 2],
                whole_rt.items.len,
                hole_rt.items[hole_rt.items.len / 2],
                hole_rt.items.len,
            },
        );
    }

    if (zttp_bin == null) {
        std.debug.print(
            "[codegen-intent] zig-out/bin/zttp is not built; intent checks skipped this run\n",
            .{},
        );
    } else {
        std.debug.print(
            "[codegen-intent] {d}/{d} intent-checked cases did the task\n",
            .{ intent_passes, intent_checked },
        );
        // Intent is both a measurement and an expertise floor. A failure says
        // the recorded handler missed the task even if the compiler accepted
        // its shape, so the marker remains reportable but non-publishable.
        if (intent_passes != intent_checked) {
            std.debug.print(
                "[codegen-intent] failures keep the convergence marker non-publishable\n",
                .{},
            );
        }
    }

    // Emit both evidence records only after every replay, coverage ratchet,
    // docs check, mode floor, and intent check has completed. The publisher
    // also requires the enclosing build to exit successfully, so an early line
    // can never become current evidence.
    if (!model_revision.observed or !provider_runtime.observed or
        observations.items.len != record_corpus.len)
    {
        return error.IncompleteEvidenceIdentity;
    }
    const run_context = try ReplayRequestContext.init(
        a,
        &registry,
        replay_provider,
        published_model,
    );
    defer {
        var owned_context = run_context;
        owned_context.deinit(a);
    }
    const request_policy: evidence_identity.RequestPolicy = .{
        .max_output_tokens = run_context.config.max_output_tokens,
        .reserve_tokens = run_context.config.reserve_tokens,
        .stream = run_context.config.stream,
        .purpose = run_context.config.purpose,
        .cache_policy = run_context.config.cache_policy,
    };
    const marker_request_policy: MarkerRequestPolicy = .{
        .maxOutputTokens = request_policy.max_output_tokens,
        .reserveTokens = request_policy.reserve_tokens,
        .stream = request_policy.stream,
        .purpose = @tagName(request_policy.purpose),
        .cachePolicy = @tagName(request_policy.cache_policy),
    };
    const prompt_persona = evidence_identity.promptPersona(run_context.system_prompt);
    const catalogs: evidence_identity.CatalogIdentities = .{
        .provider_neutral = try neutralCatalogIdentity(a, &registry),
        .provider_serialized = evidence_identity.providerSerializedCatalog(run_context.tools_json),
    };
    const compiler = try compilerEvidenceIdentities(a);
    const cohorts: evidence_identity.ManifestComponents = .{
        .headline_input = headline_input,
        .intent_suite = intentSuiteIdentity(),
        .security_probes = securityProbeIdentity(),
        .thresholds = thresholdIdentity(),
    };
    const manifest_identity = evidence_identity.manifest(cohorts);
    const source = readSourceIdentity(a, repo_root);
    const run_id = try std.fmt.allocPrint(
        a,
        "{s}-{d}-{d}",
        .{
            source.revision.commit[0..@min(source.revision.commit.len, 12)],
            zts.realtimeNowMs() catch 0,
            std.c.getpid(),
        },
    );
    const result_run = evidence_identity.resultRun(.{
        .provider = replay_provider,
        .model = published_model,
        .model_revision = model_revision.value,
        .provider_runtime = provider_runtime.value,
        .request_policy = request_policy,
        .prompt_persona = prompt_persona,
        .catalogs = catalogs,
        .compiler = compiler,
        .cohorts = cohorts,
        .source_revision = source.revision,
        .run_id = run_id,
        .observations = observations.items,
    });
    const runtime_marker: ?MarkerRuntime = if (provider_runtime.value) |runtime| .{
        .name = runtime.name,
        .revision = runtime.revision,
    } else null;
    const complete = true;
    const publication_mode = evidencePublicationMode();
    const structurally_publishable = publishableEvidence(
        replayIsFiltered(),
        publication_mode,
        source.known,
        record_corpus.len,
        results.items.len,
        summary.total,
    );
    const convergence_publishable = structurally_publishable and expertQualityGate(summary);
    if (structurally_publishable and !convergence_publishable) {
        std.debug.print(
            "[codegen-convergence] expertise gate failed: raw={d}/19 final={d}/19 " ++
                "intent={d}/{d} median-roundtrips={d}\n",
            .{
                summary.raw_first_draft_passes,
                summary.greens,
                summary.intent_passes,
                summary.intent_checked,
                summary.median_roundtrips,
            },
        );
    }
    const schema_hash = zts_cli.agent_protocol.schemaHash();
    const grammar_hash = zts.grammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostic_hash = zts.diagnosticCatalogHash();
    const policy_hash = zts.policyHash();

    const convergence_marker = try markerJson(a, .{
        .runId = run_id,
        .complete = complete,
        .publishable = convergence_publishable,
        .publicationMode = publication_mode,
        .expectedCases = record_corpus.len,
        .completedCases = results.items.len,
        .corpusCases = summary.total,
        .provider = replay_provider.publicName(),
        .model = published_model,
        .modelRevision = model_revision.value,
        .providerRuntime = runtime_marker,
        .requestPolicy = marker_request_policy,
        .providerToolCount = tool_catalog.count(&registry),
        .providerToolBytes = run_context.tools_json.len,
        .corpusVersion = version[0..],
        .headlineInputHash = cohorts.headline_input.slice(),
        .intentSuiteHash = cohorts.intent_suite.slice(),
        .securityProbeHash = cohorts.security_probes.slice(),
        .thresholdHash = cohorts.thresholds.slice(),
        .manifestHash = manifest_identity.slice(),
        .resultRunHash = result_run.slice(),
        .promptPersonaHash = prompt_persona.slice(),
        .providerNeutralCatalogHash = catalogs.provider_neutral.slice(),
        .providerSerializedCatalogHash = catalogs.provider_serialized.slice(),
        .schemaHash = schema_hash[0..],
        .metaHash = compiler.meta.slice(),
        .grammarHash = grammar_hash[0..],
        .semanticsHash = semantics_hash[0..],
        .diagnosticHash = diagnostic_hash[0..],
        .policyHash = policy_hash[0..],
        .sourceCommit = source.revision.commit,
        .sourceDirty = source.revision.dirty,
        .rawFirstDraftPassPercent = summary.rawFirstDraftPassPercent(),
        .rawFirstDraftPasses = summary.raw_first_draft_passes,
        .firstAttemptGreenPercent = summary.firstAttemptGreenPercent(),
        .firstAttemptGreens = summary.first_attempt_greens,
        .finalGreenPercent = summary.greens * 100 / summary.total,
        .finalGreens = summary.greens,
        .medianRoundtrips = summary.median_roundtrips,
        .intentPassPercent = summary.intentPassPercent(),
        .intentPasses = summary.intent_passes,
        .intentChecked = summary.intent_checked,
        .emptyResponses = 0,
        .timeoutFailures = 0,
        .decodeFailures = 0,
    });
    std.debug.print("[codegen-convergence] {s}\n", .{convergence_marker});

    const coverage_marker = try markerJson(a, .{
        .runId = run_id,
        .complete = complete,
        .publishable = structurally_publishable,
        .publicationMode = publication_mode,
        .expectedCases = record_corpus.len,
        .completedCases = results.items.len,
        .corpusCases = summary.total,
        .provider = replay_provider.publicName(),
        .model = published_model,
        .modelRevision = model_revision.value,
        .providerRuntime = runtime_marker,
        .requestPolicy = marker_request_policy,
        .providerToolCount = tool_catalog.count(&registry),
        .providerToolBytes = run_context.tools_json.len,
        .corpusVersion = version[0..],
        .headlineInputHash = cohorts.headline_input.slice(),
        .intentSuiteHash = cohorts.intent_suite.slice(),
        .securityProbeHash = cohorts.security_probes.slice(),
        .thresholdHash = cohorts.thresholds.slice(),
        .manifestHash = manifest_identity.slice(),
        .resultRunHash = result_run.slice(),
        .promptPersonaHash = prompt_persona.slice(),
        .providerNeutralCatalogHash = catalogs.provider_neutral.slice(),
        .providerSerializedCatalogHash = catalogs.provider_serialized.slice(),
        .schemaHash = schema_hash[0..],
        .metaHash = compiler.meta.slice(),
        .grammarHash = grammar_hash[0..],
        .semanticsHash = semantics_hash[0..],
        .diagnosticHash = diagnostic_hash[0..],
        .policyHash = policy_hash[0..],
        .sourceCommit = source.revision.commit,
        .sourceDirty = source.revision.dirty,
        .rulesTotal = zts.PolicyCatalog.rules().len,
        .rulesTripped = tripped.count(),
        .tripped = tripped_sorted,
        .untripped = untripped_sorted,
        .offRegistry = off_sorted,
    });
    std.debug.print("[proof-coverage] {s}\n", .{coverage_marker});
}

// Every headline case must resolve to a loadable recording.
//
// This assertion used to read "uniformly current or quarantined as stale" and
// accepted an all-stale cohort because all-stale is uniform. An all-stale
// cohort is not a tidy quarantine, it is the corpus being gone: every replay
// skips, no evidence marker is emitted, and the suite still exits zero. That
// state shipped in `f2252b31`, which bumped the artifact schema to 2 and left
// all 19 recordings at 1, and it survived four commits because the one test
// written to notice it counted the stale cases and then blessed them.
//
// So assert the value expected - current - rather than a shape that the
// excluded values also satisfy. A schema bump that outruns the recordings now
// fails here and prints the command that fixes it. The replay tests still skip
// on stale rather than fail, because twenty identical failures bury the one
// that says what to do; this is the test that says it.
test "every headline empirical case resolves to a current recording" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);

    try std.testing.expect(record_corpus.len > 0);
    var current: usize = 0;
    var stale: usize = 0;
    for (record_corpus) |rc| {
        var resolved = resolveCaseSteps(
            allocator,
            repo_root,
            headline_provider,
            rc.name,
        ) catch |err| switch (err) {
            error.StaleFlowArtifact => {
                std.debug.print(
                    "[codegen-corpus] {s}: recording is stale for the current artifact schema\n",
                    .{rc.name},
                );
                stale += 1;
                continue;
            },
            else => return err,
        };
        defer resolved.deinit(allocator);
        try std.testing.expectEqual(StepSource.flow_artifact, resolved.source);
        try std.testing.expect(resolved.responseCount() > 0);
        current += 1;
    }
    try std.testing.expectEqual(record_corpus.len, current + stale);
    if (stale > 0) {
        const command = try recordingCommand(allocator, headline_provider);
        defer allocator.free(command);
        std.debug.print(
            "[codegen-corpus] {d} of {d} headline recordings are stale;" ++
                " the offline replay covers {d} cases and publishes nothing." ++
                " Re-record with:\n  {s}\n",
            .{ stale, record_corpus.len, current, command },
        );
        return error.StaleHeadlineCorpus;
    }
    try std.testing.expectEqual(record_corpus.len, current);
}

test "every current corpus case resolves to exactly one recording source" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);

    var flow_backed: usize = 0;
    for (record_corpus) |rc| {
        var resolved = try resolveCurrentCaseStepsForTest(allocator, repo_root, headline_provider, rc.name);
        defer resolved.deinit(allocator);
        // The floor that makes the counts below mean anything: a resolver that
        // found nothing would report a clean split of zero and zero.
        try std.testing.expect(resolved.responseCount() > 0);
        if (resolved.source == .flow_artifact) flow_backed += 1;
    }
    // The headline corpus is recorded in one shape, so every case resolves the
    // same way. This is a floor on the flow path, not a claim that the flat one
    // is gone.
    try std.testing.expectEqual(record_corpus.len, flow_backed);
}

test "anthropic flat cassette fallback resolves at least one recorded case" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);

    // The flat-cassette path is anthropic-only by construction, so it has to be
    // exercised against that provider or not at all. Checking it here keeps a
    // resolver that silently stopped reading flat cassettes from passing on the
    // strength of a headline that no longer uses them.
    var flat_backed: usize = 0;
    for (record_corpus) |rc| {
        var resolved = resolveCaseSteps(allocator, repo_root, .anthropic, rc.name) catch |err| switch (err) {
            // A descriptor always shadows the flat cassette, including when
            // its schema is stale. That case is quarantined, never silently
            // replayed from the older storage lane.
            error.StaleFlowArtifact => continue,
            else => return err,
        };
        defer resolved.deinit(allocator);
        if (resolved.source == .flat_cassette and resolved.responseCount() > 0) flat_backed += 1;
    }
    try std.testing.expect(flat_backed > 0);
}

test "flow-backed replay validates the current request checkpoint" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);
    var resolved = try resolveCurrentCaseStepsForTest(allocator, repo_root, headline_provider, "durable-order");
    defer resolved.deinit(allocator);
    try std.testing.expectEqual(StepSource.flow_artifact, resolved.source);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    const flow_case = if (resolved.flow_case) |*case| case else return error.ExpectedFlowArtifact;
    var request_context = try ReplayRequestContext.init(
        allocator,
        &registry,
        headline_provider,
        flow_case.manifest.model,
    );
    defer request_context.deinit(allocator);
    var client = try CorpusReplayClient.init(&resolved, request_context.config);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.ReplayMismatch,
        client.asModelClient().request(
            arena.allocator(),
            &transcript,
            "this prompt does not match the recorded flow",
        ),
    );
    try std.testing.expect(client.lastFlowMismatch() != null);
}

test "flow-backed corpus replay executes recorded compaction" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);
    // Keep the winning case's steps rather than re-resolving them: the search
    // already read the manifest, trace, and step fixtures off disk.
    var rc: *const RecordCase = undefined;
    var resolved = blk: {
        for (&record_corpus) |*candidate| {
            var candidate_resolved = try resolveCurrentCaseStepsForTest(
                allocator,
                repo_root,
                headline_provider,
                candidate.name,
            );
            const recorded_compaction = if (candidate_resolved.flow_case) |flow_case| compacted: {
                for (flow_case.trace.model_calls) |checkpoint| {
                    if (checkpoint.projection_first_kept_entry_id != null) break :compacted true;
                }
                break :compacted false;
            } else false;
            if (recorded_compaction) {
                rc = candidate;
                break :blk candidate_resolved;
            }
            candidate_resolved.deinit(allocator);
        }
        return error.MissingCompactedCorpusCase;
    };
    defer resolved.deinit(allocator);
    const flow_case = if (resolved.flow_case) |*case| case else return error.ExpectedFlowArtifact;

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    var request_context = try ReplayRequestContext.init(
        allocator,
        &registry,
        headline_provider,
        flow_case.manifest.model,
    );
    defer request_context.deinit(allocator);
    var client = try CorpusReplayClient.init(&resolved, request_context.config);

    var tmp = try IsolatedTmp.init(allocator, "codegen-compacted-replay");
    defer tmp.cleanup(allocator);
    for (rc.seed_files) |seed| try tmp.writeFile(allocator, seed.path, seed.bytes);
    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var outcome = try replayCorpusTurn(
        allocator,
        &resolved,
        &client,
        request_context.config,
        headline_provider,
        &registry,
        rc.prompt,
    );
    defer outcome.deinit(allocator);
    try client.finish();
    try std.testing.expect(outcome.transcript.projection != null);
}

test "a broken flow artifact is refused rather than falling back" {
    const allocator = std.testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "codegen-resolve");
    defer tmp.cleanup(allocator);

    const name = "half-recorded";
    // A descriptor and nothing else: what an interrupted recording leaves.
    const descriptor = try std.fmt.allocPrint(allocator, "{s}/{s}/case.json", .{ empirical_flow_root, name });
    defer allocator.free(descriptor);
    try tmp.writeFile(
        allocator,
        descriptor,
        "{\"schema_version\":2,\"case_name\":\"half-recorded\"," ++
            "\"evidence_class\":\"empirical_model\",\"executable\":true," ++
            "\"active_generation\":\"0000000000000000000000000000000000000000000000000000000000000000\"}",
    );

    // The same case still has its previous flat cassette, which is exactly the
    // situation a fallback would paper over: replaying last week's bytes under
    // this week's recording.
    const step = try std.fmt.allocPrint(allocator, "{s}/{s}/step_0.jsonl", .{ cassette_root, name });
    defer allocator.free(step);
    try tmp.writeFile(allocator, step, "{\"v\":1,\"model\":\"stale\"}\n");

    try std.testing.expectError(
        error.UnloadableFlowArtifact,
        resolveCaseSteps(allocator, tmp.abs_path, headline_provider, name),
    );
}

test "a case with neither recording resolves to no steps" {
    const allocator = std.testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "codegen-resolve-empty");
    defer tmp.cleanup(allocator);

    // Reported as missing by the caller, not thrown here: the whole missing set
    // is worth more than an abort on the first one.
    var resolved = try resolveCaseSteps(allocator, tmp.abs_path, headline_provider, "never-recorded");
    defer resolved.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), resolved.responseCount());
    // A provider with no flat-cassette lane has nowhere else to look, so the
    // absence is named `.missing`. Anthropic falls through to its flat lane and
    // reports that source with zero steps instead.
    try std.testing.expectEqual(StepSource.missing, resolved.source);

    var anthropic_resolved = try resolveCaseSteps(allocator, tmp.abs_path, .anthropic, "never-recorded");
    defer anthropic_resolved.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), anthropic_resolved.responseCount());
    try std.testing.expectEqual(StepSource.flat_cassette, anthropic_resolved.source);
}
