//! expert_codegen_record - baseline recorder and offline recorder smoke test.
//!
//! Corpus recording spends real model time and stays gated behind
//! `ZTTP_CODEGEN_RECORD=1`. `ZTTP_CODEGEN_PROVIDER` selects the provider;
//! cloud credentials are required only for an explicitly selected cloud
//! provider. Transport, capture, disk, and replay are tested offline.
//! Live cassettes remain the only source for model-behavior measurements.

const std = @import("std");
const zts = @import("zts");
const anthropic = @import("providers/anthropic/client.zig");
const anthropic_tools = @import("providers/anthropic/tools_schema.zig");
const local = @import("providers/local/client.zig");
const openai = @import("providers/openai/client.zig");
const deepseek = @import("providers/deepseek/client.zig");
const cassette_client = @import("providers/cassette_client.zig");
const cassette_record = @import("providers/cassette_record.zig");
const capture_sink = @import("providers/capture_sink.zig");
const model_request = @import("providers/model_request.zig");
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
const expert_persona = @import("expert_persona.zig");
const models = @import("providers/models.zig");
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

/// Delete a case's cassette directory (`<out_dir_abs>/<name>`) via its absolute
/// parent, so it works regardless of the current working directory. Best-effort.
fn removeCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);
    parent.deleteTree(io, name) catch {};
}

/// Suffix for a case's stashed cassette while a live recording runs.
const stash_suffix = ".recording-backup";

/// Move a case's committed cassette aside before recording over it.
///
/// The recorder used to delete the directory outright, and its failure path
/// deleted the partial too - so a run that failed left nothing where a working
/// cassette had been. That is survivable only because cassettes are committed,
/// and it has cost the whole corpus once: a full run with every turn failing
/// clears all eleven cases. Stashing makes a failed recording a no-op instead.
///
/// Returns true when a stash was taken, so the caller knows whether there is
/// anything to restore.
fn stashCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) bool {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return false;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return false;
    defer allocator.free(stashed);

    // A stash left behind by an interrupted run would block the rename.
    parent.deleteTree(io, stashed) catch {};
    parent.rename(name, parent, stashed, io) catch return false;
    return true;
}

/// Put the stashed cassette back, discarding whatever the failed run wrote.
fn restoreCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return;
    defer allocator.free(stashed);

    parent.deleteTree(io, name) catch {};
    parent.rename(stashed, parent, name, io) catch {};
}

/// Drop the stash after a recording that succeeded.
fn dropStashedCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return;
    defer allocator.free(stashed);
    parent.deleteTree(io, stashed) catch {};
}

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

fn recordingCommand(
    allocator: std.mem.Allocator,
    provider: agent.Provider,
    named_case: bool,
) ![]u8 {
    return if (named_case)
        std.fmt.allocPrint(
            allocator,
            "ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER={s} ZTTP_CODEGEN_ONLY=<name> " ++
                "zig build test-expert-app -Dtest-filter=\"record codegen baseline corpus\"",
            .{provider.publicName()},
        )
    else
        std.fmt.allocPrint(
            allocator,
            "ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_PROVIDER={s} " ++
                "zig build test-expert-app -Dtest-filter=\"record codegen baseline corpus\"",
            .{provider.publicName()},
        );
}

test "recording remediation preserves the replay provider" {
    const claude = try recordingCommand(testing.allocator, .anthropic, false);
    defer testing.allocator.free(claude);
    try testing.expect(std.mem.indexOf(u8, claude, "ZTTP_CODEGEN_PROVIDER=claude") != null);

    const local_named = try recordingCommand(testing.allocator, .local, true);
    defer testing.allocator.free(local_named);
    try testing.expect(std.mem.indexOf(u8, local_named, "ZTTP_CODEGEN_PROVIDER=local") != null);
    try testing.expect(std.mem.indexOf(u8, local_named, "ZTTP_CODEGEN_ONLY=<name>") != null);
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
    if (provider != .local or !std.mem.eql(u8, model, local.default_model)) return null;
    if (envValue("ZTTP_CODEGEN_MODEL_REVISION")) |revision| return try allocator.dupe(u8, revision);
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

const RecordCase = struct {
    name: []const u8,
    prompt: []const u8,
    seed_files: []const codegen.SeedFile = &.{},
    /// The recorded first-draft outcome, locked in after recording. The offline
    /// ratchet asserts replay reproduces exactly this, so a case the agent
    /// currently fails is a valid, pinned corpus entry (it feeds the gap
    /// histogram) - not a broken test.
    expect_first_draft_pass: bool = true,
    /// Behaviour the produced handler must exhibit for the case to count as
    /// having done the task. Null leaves the case veto-checked but not
    /// intent-checked, which the summary reports separately rather than
    /// counting as a pass.
    intent: ?codegen.IntentCheck = null,
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

pub const Mode = enum { whole_file, holes };

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

test "first draft expectations are provider qualified" {
    try testing.expectEqual(
        @as(?bool, false),
        firstDraftExpectation(.local, false, true),
    );
    try testing.expectEqual(
        @as(?bool, null),
        firstDraftExpectation(.local, null, true),
    );
    try testing.expectEqual(
        @as(?bool, true),
        firstDraftExpectation(.anthropic, null, true),
    );
}

fn firstDraftExpectation(
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

/// Identity of the frozen prompt corpus.
///
/// A published pass rate means nothing without saying which corpus produced it,
/// and a hand-maintained version number rots the moment someone edits a prompt.
/// This hashes the corpus itself - names, prompts, seed files, and the pinned
/// outcomes - so editing any case changes the version by construction. Same
/// mechanism as `zts.policyHash`, for the same reason.
pub fn corpusVersion() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (&record_corpus) |*rc| {
        hasher.update(rc.name);
        hasher.update("\x00");
        hasher.update(rc.prompt);
        hasher.update("\x00");
        for (rc.seed_files) |sf| {
            hasher.update(sf.path);
            hasher.update("\x00");
            hasher.update(sf.bytes);
            hasher.update("\x00");
        }
        // The pinned outcome is part of the corpus identity: flipping a case
        // from accepted-failure to expected-pass changes what the rate means.
        hasher.update(&[_]u8{@intFromBool(rc.expect_first_draft_pass)});
        hasher.update("\x00");
        // So is the turn mode. The same prompt against a holed skeleton and
        // against an empty workspace are two different measurements, and a
        // corpus version that could not tell them apart would let the split
        // change under a stable hash.
        hasher.update(&[_]u8{@intFromEnum(rc.mode)});
        hasher.update("\x00");
        // So is the intent spec: loosening what a case must do changes what a
        // published intent-pass rate is a rate of.
        if (rc.intent) |intent| {
            hasher.update(intent.tests_jsonl);
            hasher.update("\x00");
            hasher.update(intent.handler_path);
            hasher.update("\x00");
            if (intent.zttp_json) |cfg| hasher.update(cfg);
            hasher.update("\x00");
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return out;
}

test "corpus version changes when a case changes" {
    const before = corpusVersion();
    // Same input twice is stable - the hash is a function of the corpus, not
    // of call order or allocation.
    try testing.expectEqualSlices(u8, &before, &corpusVersion());
    // A version that is all zeroes or empty would silently pass the equality
    // above, so assert it looks like a real digest.
    try testing.expectEqual(@as(usize, 64), before.len);
    var nonzero = false;
    for (before) |c| {
        if (c != '0') nonzero = true;
    }
    try testing.expect(nonzero);
}

// The corpus spans common tasks the agent handles cleanly and harder ones that
// probe known gap areas (user-input egress, websocket events, durable
// workflows). Each elicits realistic multi-roundtrip behaviour (explore then
// edit) and records as step_0/step_1/...
//
// Thirteen of the nineteen carry an intent spec. The five durable and workflow
// cases do not: executing them needs the durable store and queue the runtime
// stands up, and `zttp test` has no offline story for either - `saga()` fails
// with NativeFunctionError before any assertion runs, and an io stub does not
// intercept it. Those cases stay veto-checked and report `.not_checked`, which
// the summary counts apart from passes, so the published figure reads 13 of 19
// covered instead of pretending to 20. Closing that gap means giving the test
// runner a durable backend, which is its own piece of work.
//
// `parallel-secret` is the sixth without a spec, for a different reason given
// at the case.
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
/// The motivating measurement: a case's *first* model call carries ~29,000
/// prompt tokens before the task is even stated, and the whole 18-roundtrip
/// transcript adds only ~5,000 more. Thirty-seven tools contribute roughly
/// 21 KB of that preamble and the recorded traces call eight of them.
///
/// Two things this deliberately does not do. It never drops `apply_edit`,
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
        if (registry.findByName(name) == null) {
            std.debug.print("[codegen-tools] no registered tool named '{s}'\n", .{name});
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

const record_corpus = [_]RecordCase{
    .{
        .name = "health",
        .prompt = "Create a handler in handler.ts that responds to GET /health with " ++
            "Response.json({ ok: true }). Keep it minimal and deterministic.",
        .expect_first_draft_pass = true,
        // Asserts the task the prompt names, not the shape of one recording: a
        // different-but-correct handler must still pass, or the check measures
        // the cassette instead of the model.
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"GET /health reports ok"}
            \\{"type":"request","method":"GET","url":"/health","headers":{},"body":""}
            \\{"type":"expect","status":200,"bodyContains":"\"ok\":true"}
            \\
            ,
        },
    },
    .{
        .name = "validate-body",
        .prompt = "Create a handler in handler.ts that decodes the JSON request body with " ++
            "zttp:validate against a schema named \"item\" requiring a string field \"name\", " ++
            "returns the validated data on success, and returns a 400 with the errors on failure.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a body missing name is rejected"}
            \\{"type":"request","method":"POST","url":"/","headers":{"content-type":"application/json"},"body":"{}"}
            \\{"type":"expect","status":400}
            \\
            ,
        },
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
        .expect_first_draft_pass = true,
    },
    .{
        .name = "jwt-auth",
        .prompt = "Create a handler in handler.ts that requires a bearer JWT using zttp:auth " ++
            "with the secret from env JWT_SECRET, returns 401 when the token is missing or invalid, " ++
            "and otherwise returns the verified claims as JSON. Never use a fallback secret.",
        // The env stub is what makes this check test its own name. Without it
        // JWT_SECRET is unset in the workspace, so a handler that validates its
        // configuration before it looks at the request answers 500 "server
        // misconfigured" and the check reports a bearer-token failure that never
        // happened. It passed for years only because the recorded handler
        // happened to read the header first; the 2026-08-03 re-record produced
        // one that checks the secret first, and the check failed on a handler
        // that does return 401 for a missing token.
        //
        // Same correction as `websocket-echo` below, in the other direction:
        // that one passed for a reason its name did not describe, this one
        // failed for one. Neither was measuring what it claimed.
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with no bearer token is unauthorized"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["JWT_SECRET"],"result":"test-signing-secret"}
            \\{"type":"expect","status":401}
            \\
            ,
        },
        // This case has now caught the same laundering class twice, which is
        // most of its value.
        //
        // First as JSON.stringify/JSON.parse round-tripping, closed by
        // propagating labels through member and JSON calls. Then, on the
        // 2026-08-03 recording, through `validateJson`: the model routed the
        // claims through the validator and wrote in its own commentary that
        // this cleared the credential label. It was right, and the veto passed.
        // See docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md.
        //
        // With that closed, this re-record is the first time the case reaches a
        // safe handler without a hand correction. The model tried the validator
        // route, was refused (the ZTS400 in the recorded gap field), and settled
        // on returning a confirmation envelope rather than the claims - the same
        // shape the previous cassette had to be hand-edited into. Sixteen
        // round-trips, zero veto retries: it converged in simulation.
        //
        // Pin flips false to true because that is what was recorded. It is not
        // a rate improvement to read as the model getting better; the fence
        // moved under it.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "weather-egress",
        .prompt = "Create a handler in handler.ts that reads a `city` query parameter and " ++
            "fetches the current weather for that city from https://api.open-meteo.com/v1/forecast " ++
            "using zttp:fetch, returning the JSON response.",
        // The success path needs egress, which the offline replay has no way to
        // serve. The missing-parameter path is the part of the task that can be
        // demonstrated without a network, so that is what this asserts.
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with no city is rejected"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":400}
            \\
            ,
        },
        // Was ZTS602 (never converged); closed by the literal-URL + init-query
        // egress teaching.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "durable-order",
        .prompt = "Create a durable handler in handler.ts using zttp:durable that runs a " ++
            "two-step order workflow: a `reserve` step then a `charge` step, via run() and step().",
        // Was ZTS042/narrowing death-spiral (never converged); closed by the
        // "use untyped values directly, never narrow with as/guards" teaching.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-queued-call",
        .prompt = "Create a durable workflow handler in handler.ts using zttp:durable and " ++
            "zttp:workflow. It should read the Idempotency-Key header, enter run(key), " ++
            "and dispatch a greet child handler with workflow.call at durable depth 0.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-nested-dispatch-avoidance",
        .prompt = "Create a durable order workflow in handler.ts. Reserve inventory with a " ++
            "durable step, then dispatch a notify child handler with workflow.call after the " ++
            "step completes. Keep the child dispatch outside the step callback.",
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
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-saga-compensation",
        .prompt = "Create a handler in handler.ts using zttp:workflow saga() for reserve, " ++
            "charge, and ship steps. Include compensate functions for every non-last static " ++
            "saga step so the saga compensation proof can pass.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-wait-signal",
        .prompt = "Create a durable approval workflow in handler.ts using waitSignal and " ++
            "signal. The /wait path should park a run using the Idempotency-Key header, and " ++
            "the /signal path should resume the same key with an approved payload.",
        .expect_first_draft_pass = true,
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
        .intent = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"sqlite\": \"schema.sql\"\n}\n",
            .tests_jsonl =
            \\{"type":"test","name":"queried rows reach the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"sql","fn":"sqlMany","args":["list_users"],"result":[{"id":1,"name":"ada"}]}
            \\{"type":"expect","status":200,"bodyContains":"ada"}
            \\
            ,
        },
        // Recorded with the best model (Sonnet): writes correct SQL, self-checks
        // cleanly, and first-draft-passes. Previously it failed because the
        // property analysis reported read_only as PROVEN for a SELECT and the
        // agent declared it (then ZTS501 rejected it); the classifier now gates
        // declarable read_only on write-effect imports, so the agent is no
        // longer told to declare a property the import forbids.
        .expect_first_draft_pass = true,
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
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the timestamp stays out of the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":200,"body":"{\"ok\":true}"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
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
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the stored counter reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"cache","fn":"cacheGet","args":["counters","hits"],"result":"41"}
            \\{"type":"expect","status":200,"bodyContains":"41"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
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
        // preceded the one `apply_edit`, which is where the shape was found.
        //
        // No intent spec: the response is a bare app name read from an env var,
        // and asserting it would test the env stub rather than the containment
        // this case is about. What matters here is the veto verdict.
        .name = "parallel-secret",
        .prompt = "Create a handler in handler.ts that reads the APP_NAME and API_SECRET " ++
            "environment variables concurrently using parallel() from zttp:io. Return 503 " ++
            "when API_SECRET is not set. Otherwise return Response.json with only the app " ++
            "name - the secret must never appear in the response.",
        .expect_first_draft_pass = true,
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
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the upstream payload reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://api.example.com/v1/status"],"result":{"status":200,"body":"{\"state\":\"green\"}"}}
            \\{"type":"expect","status":200,"bodyContains":"green"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
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
                \\export function apiToken(): string | undefined {
                \\  return env("API_TOKEN");
                \\}
                \\
                \\export function displayName(): string {
                \\  return env("APP_NAME") ?? "unnamed";
                \\}
                \\
                ,
            },
        },
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the configured name crosses the file boundary and the token does not"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["API_TOKEN"],"result":"tok-secret-value"}
            \\{"type":"io","seq":1,"module":"env","fn":"env","args":["APP_NAME"],"result":"orders-api"}
            \\{"type":"expect","status":200,"body":"{\"name\":\"orders-api\"}"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
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
    // Each seed carries the narrow `Spec<...>` its finished form needs, and the
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
            "zts_expert_holes to read the frame and zts_expert_fill_hole to fill it.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\function handler(req: Request): Response & Spec<"deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"GET /health reports ok"}
            \\{"type":"request","method":"GET","url":"/health","headers":{},"body":""}
            \\{"type":"expect","status":200,"bodyContains":"\"ok\":true"}
            \\
            ,
        },
        .mode = .holes,
        .expect_first_draft_pass = true,
    },
    .{
        .name = "cache-counter-holes",
        .prompt = "handler.ts reads the \"hits\" counter from the \"counters\" namespace and " ++
            "has a hole() on each branch. Fill them so the handler returns the counter as " ++
            "JSON under a \"hits\" key, treating a missing counter as \"0\". Use " ++
            "zts_expert_holes for the frame and zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\import { cacheGet } from "zttp:cache";
                \\
                \\function handler(req: Request): Response & Spec<"retry_safe" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
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
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the stored counter reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"cache","fn":"cacheGet","args":["counters","hits"],"result":"41"}
            \\{"type":"expect","status":200,"bodyContains":"41"}
            \\
            ,
        },
        .mode = .holes,
        .expect_first_draft_pass = true,
    },
    .{
        .name = "egress-options-holes",
        .prompt = "handler.ts already calls the upstream with an init object and has a hole() " ++
            "on each branch. Fill them so it returns the upstream JSON on success and a 502 " ++
            "when the call fails. Use zts_expert_holes for the frame and " ++
            "zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "handler.ts",
                .bytes =
                \\import { fetch } from "zttp:fetch";
                \\
                \\function handler(req: Request): Response & Spec<"state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
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
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the upstream payload reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://api.example.com/v1/status"],"result":{"status":200,"body":"{\"state\":\"green\"}"}}
            \\{"type":"expect","status":200,"bodyContains":"green"}
            \\
            ,
        },
        .mode = .holes,
        .expect_first_draft_pass = true,
    },
    .{
        .name = "sibling-helper-holes",
        .prompt = "handler.ts imports displayName() and apiToken() from ./lib/settings.ts and " ++
            "has a hole() on each branch. Fill them so the handler returns 503 when " ++
            "apiToken() is undefined and otherwise Response.json({ name: displayName() }). " ++
            "The token must never appear in the response. Use zts_expert_holes for the " ++
            "frame and zts_expert_fill_hole to fill each one.",
        .seed_files = &.{
            .{
                .path = "lib/settings.ts",
                .bytes =
                \\import { env } from "zttp:env";
                \\
                \\export function apiToken(): string | undefined {
                \\  return env("API_TOKEN");
                \\}
                \\
                \\export function displayName(): string {
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
                \\function handler(req: Request): Response & Spec<"deterministic" | "read_only" | "retry_safe" | "idempotent" | "state_isolated" | "result_safe" | "optional_safe" | "no_secret_leakage" | "no_credential_leakage" | "input_validated" | "pii_contained" | "injection_safe" | "canonical" | "cost_bounded"> {
                \\  if (apiToken() === undefined) {
                \\    return Response.json({ error: "unconfigured" }, { status: 503 });
                \\  }
                \\  return hole();
                \\}
                \\
                ,
            },
        },
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the configured name crosses the file boundary and the token does not"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["API_TOKEN"],"result":"tok-secret-value"}
            \\{"type":"io","seq":1,"module":"env","fn":"env","args":["APP_NAME"],"result":"orders-api"}
            \\{"type":"expect","status":200,"body":"{\"name\":\"orders-api\"}"}
            \\
            ,
        },
        .mode = .holes,
        .expect_first_draft_pass = true,
    },
};

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
        }
    }
};

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

// Record the real expert agent against the corpus and report the live baseline.
// Gated: ZTTP_CODEGEN_RECORD=1. Cloud providers additionally require their
// named key. Each case runs in its own tmp
// workspace with cwd switched to it, so the agent's tools and the edit veto
// resolve the same files; cassettes are written to an absolute repo path so the
// chdir does not misplace them. ZTTP_CODEGEN_LIMIT caps the case count for a
// cheap small-scale validation before the full run.
test "record codegen baseline corpus (live, gated)" {
    if (!recordingRequested()) return error.SkipZigTest;
    const corpus_provider = try recordingProvider();
    if (!recordingAuthAvailable(corpus_provider)) return error.SkipZigTest;
    // A live recording driver, not a memory-correctness test: use an arena over
    // the page allocator so the strict test allocator's leak check does not flag
    // the live HTTP/TLS stack (which the deterministic tests never exercise).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    try applyToolAllowlist(&registry);
    // The published number describes the model a user actually gets, so the
    // corpus records against the product default rather than a hand-picked
    // tier - see `headline_model`. ZTTP_CODEGEN_MODEL overrides it (e.g. Haiku)
    // for cheap harness testing, or to record a second row against another
    // tier. Env strings live for the process, so the borrowed slice is safe.
    const corpus_model = envValue("ZTTP_CODEGEN_MODEL") orelse
        models.defaultForProvider(corpus_provider).id;
    var session = try agent.initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = corpus_provider,
        .model = corpus_model,
    });
    defer session.deinit(allocator);
    if (session.activeProvider() != corpus_provider) return error.UnsupportedRecordingProvider;
    // ZTTP_CODEGEN_ONLY=<name> records just one case, leaving the others'
    // committed cassettes untouched.
    const only_case = envValue("ZTTP_CODEGEN_ONLY");

    const record_turn_timeout_ms: u64 = if (envValue("ZTTP_CODEGEN_TURN_TIMEOUT_MS")) |raw|
        std.fmt.parseInt(u64, raw, 10) catch default_record_turn_timeout_ms
    else
        default_record_turn_timeout_ms;
    std.debug.print(
        "[codegen-record] per-turn ceiling: {d}ms\n",
        .{record_turn_timeout_ms},
    );

    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);
    const out_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, flowRoot(corpus_provider) });
    defer allocator.free(out_dir);
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, out_dir);

    const request_config = try requestConfigForSession(&session);
    const model_revision = try cachedModelRevision(allocator, corpus_provider, corpus_model);
    defer if (model_revision) |revision| allocator.free(revision);
    const runtime_identity = try declaredRuntime(corpus_provider);
    if (runtime_identity) |identity| {
        std.debug.print(
            "[codegen-record] declared local runtime: {s} {s}\n",
            .{ identity.name, identity.version },
        );
    }
    // A fresh directory per invocation keeps failed attempts from different
    // corpus runs distinguishable without making diagnostics authoritative.
    const diagnostics_run_id: ?[]const u8 = if (corpus_provider == .local)
        try std.fmt.allocPrint(
            allocator,
            "{d}-{d}",
            .{ zts.realtimeNowMs() catch 0, std.c.getpid() },
        )
    else
        null;
    defer if (diagnostics_run_id) |run_id| allocator.free(run_id);

    var limit: usize = record_corpus.len;
    if (envValue("ZTTP_CODEGEN_LIMIT")) |lim| {
        limit = std.fmt.parseInt(usize, lim, 10) catch limit;
    }
    const selected_case_count = selectedRecordCaseCount(limit, only_case);
    std.debug.print(
        "[codegen-record] corpus start: provider={s} model={s} cases={d}\n",
        .{ corpus_provider.publicName(), corpus_model, selected_case_count },
    );

    var first_draft_passes: usize = 0;
    var greens: usize = 0;
    var total: usize = 0;
    for (record_corpus, 0..) |rc, i| {
        if (!recordCaseSelected(i, limit, only_case, rc.name)) continue;
        total += 1;
        std.debug.print(
            "[codegen-record] [{d}/{d}] {s}: case start\n",
            .{ total, selected_case_count, rc.name },
        );
        var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer case_arena.deinit();
        const ca = case_arena.allocator();

        var tmp = try IsolatedTmp.init(ca, "codegen-record");
        defer tmp.cleanup(ca);
        for (rc.seed_files) |sf| try tmp.writeFile(ca, sf.path, sf.bytes);

        const case_dir = try std.fs.path.join(ca, &.{ out_dir, rc.name });
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, case_dir);
        const case_root_abs = try std.Io.Dir.realPathFileAbsoluteAlloc(io, case_dir, ca);
        const response_diagnostics_path: ?[]const u8 = if (diagnostics_run_id) |run_id|
            try std.fmt.allocPrint(
                ca,
                "{s}/.zig-cache/codegen-record-diagnostics/{s}/{s}.jsonl",
                .{ repo_root, run_id, rc.name },
            )
        else
            null;

        const workspace_allowlist = try workspaceCaptureAllowlist(ca, rc.seed_files);
        var live_progress: LiveRecordingProgress = .{
            .case_index = total,
            .case_count = selected_case_count,
            .case_name = rc.name,
        };
        var recorder = try flow_recorder.Recorder.init(ca, .{
            .case_name = rc.name,
            .evidence_class = .empirical_model,
            .provider = switch (corpus_provider) {
                .local => .local,
                .anthropic => .anthropic,
                .openai => .openai,
                .deepseek => .deepseek,
            },
            .model = corpus_model,
            .model_revision = model_revision,
            .runtime_name = if (runtime_identity) |identity| identity.name else null,
            .runtime_version = if (runtime_identity) |identity| identity.version else null,
            .diagnostics_path = response_diagnostics_path,
            .progress = live_progress.observer(),
            .workspace_allowlist = workspace_allowlist,
        });
        defer recorder.deinit();
        try recorder.captureInitialWorkspace(tmp.abs_path);

        const saved_cwd = try cwdPathAlloc(ca);
        try std.Io.Threaded.chdir(tmp.abs_path);
        defer std.Io.Threaded.chdir(saved_cwd) catch {};

        var sink = recorder.captureSink();
        try setSessionCapture(&session, &sink);

        var tr: transcript_mod.Transcript = .{};
        defer tr.deinit(ca);
        try recorder.beginTurn(rc.prompt, tr.len(), .approve);
        const result = loop.runTurnWith(ca, session.modelClient(), &registry, &tr, rc.prompt, .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = recorder.approvalFn(),
            .replay_mode = false,
            // Three minutes per cassette. This was 0, which disables the bound
            // entirely: a local model that stops producing tokens mid-turn
            // hangs the whole corpus run rather than failing that one case, and
            // `durable-order` has ended in `EmptyResponse` after doing exactly
            // that. A capped case fails, gets named in the run's output, and
            // the remaining cases still record.
            .turn_timeout_ms = record_turn_timeout_ms,
        }) catch |err| {
            try setSessionCapture(&session, null);
            // Collection is memory-only until validation and replay both pass,
            // so a live failure cannot disturb the active case pointer.
            std.debug.print("[codegen-record] {s}: turn failed: {s}\n", .{ rc.name, @errorName(err) });
            if (response_diagnostics_path) |path| {
                std.debug.print("[codegen-record] metadata-only response diagnostics: {s}\n", .{path});
            }
            return err;
        };
        try setSessionCapture(&session, null);
        // A turn the wall clock cut short cannot be replayed. The live loop
        // stopped asking for model calls because the elapsed time crossed
        // `turn_timeout_ms`; a replay of the same turn finishes in
        // milliseconds, never crosses it, and asks for one more call than the
        // recording holds. Promotion would surface that as `response_underflow`
        // at the last call, which reads like a divergence and is not one.
        // Refuse here, where the reason is still known and can be acted on.
        if (result.end_reason == .budget_timeout) {
            std.debug.print(
                "[codegen-record] {s}: turn hit the {d}s wall-clock ceiling, so its recording " ++
                    "would not replay; raise ZTTP_CODEGEN_TURN_TIMEOUT_MS for this corpus. " ++
                    "Active case unchanged.\n",
                .{ rc.name, record_turn_timeout_ms / 1000 },
            );
            return error.RecordedTurnHitTimeBudget;
        }
        try recorder.finishTurn(result, &tr);
        try recorder.captureExpectedWorkspace(tmp.abs_path);
        std.debug.print(
            "[codegen-record] [{d}/{d}] {s}: live turn captured " ++
                "(calls={d} roundtrips={d} retries={d} tools={d}); checking result\n",
            .{
                total,
                selected_case_count,
                rc.name,
                sink.next_call_index,
                result.roundtrips,
                result.veto_retry_count,
                result.tool_call_count,
            },
        );
        if (corpus_provider == headline_provider) {
            if (firstDraftExpectation(corpus_provider, null, rc.expect_first_draft_pass)) |expected| {
                if (result.first_draft_veto_pass != expected) {
                    std.debug.print(
                        "[codegen-record] {s}: pinned first_draft_pass={} but fresh flow observed {}; active case unchanged\n",
                        .{ rc.name, expected, result.first_draft_veto_pass },
                    );
                    return error.PinnedExpectationMismatch;
                }
            }
        }

        const zttp_bin: ?[]u8 = if (rc.intent != null)
            codegen.locateZttpBinary(ca, repo_root) orelse {
                std.debug.print(
                    "[codegen-record] {s}: declared intent cannot run because zig-out/bin/zttp is unavailable; active case unchanged\n",
                    .{rc.name},
                );
                return error.IntentCheckUnavailable;
            }
        else
            null;
        requireRecordedIntent(
            ca,
            rc.intent,
            tmp.abs_path,
            zttp_bin,
            codegen.runIntentCheck,
        ) catch |err| {
            const handler_path: ?[]u8 = std.fs.path.join(
                ca,
                &.{ tmp.abs_path, "handler.ts" },
            ) catch null;
            if (handler_path) |path| {
                if (zts.file_io.readFile(ca, path, 1024 * 1024)) |handler| {
                    std.debug.print("[codegen-record] {s}: produced handler:\n{s}\n", .{ rc.name, handler });
                } else |_| {}
            }
            std.debug.print(
                "[codegen-record] {s}: declared intent did not pass ({s}); failure will be measured and promoted\n",
                .{ rc.name, @errorName(err) },
            );
            if (err == error.IntentCheckUnavailable) return err;
        };

        std.debug.print(
            "[codegen-record] [{d}/{d}] {s}: validating replay and promoting\n",
            .{ total, selected_case_count, rc.name },
        );
        const active_version = try flow_promotion.validateAndPromote(
            ca,
            &recorder,
            case_root_abs,
            &registry,
            request_config,
        );
        if (result.first_draft_veto_pass) first_draft_passes += 1;
        if (result.applied_edit) greens += 1;
        const fail_code = codegen.firstZtsCode(&tr) orelse "-";
        std.debug.print(
            "[codegen-record] [{d}/{d}] {s}: promoted provider={s} model={s} flow={s} first_draft_pass={} applied={} compiler_authored={} roundtrips={d} retries={d} tools={d} calls={d} fail={s}\n",
            .{
                total,
                selected_case_count,
                rc.name,
                corpus_provider.publicName(),
                corpus_model,
                active_version.slice()[0..12],
                result.first_draft_veto_pass,
                result.applied_edit,
                result.compiler_authored_apply,
                result.roundtrips,
                result.veto_retry_count,
                result.tool_call_count,
                sink.next_call_index,
                fail_code,
            },
        );
    }
    std.debug.print(
        "[codegen-record] BASELINE first-draft pass: {d}/{d}; reached-green: {d}/{d}\n",
        .{ first_draft_passes, total, greens, total },
    );
    if (only_case != null and total != 1) return error.NamedCodegenCaseNotFound;
    if (only_case == null and limit >= record_corpus.len and total != record_corpus.len) {
        return error.CodegenCorpusCountMismatch;
    }
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
// require it still passes on the first draft. Runs in normal CI (no network, no
// key): it reproduces the recorded baseline deterministically and fails if a
// compiler/policy change would make a previously-clean recorded edit regress.
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

/// Five of seventy-four, measured 2026-08-14 over the complete 19-case DeepSeek
/// corpus. It is not the Anthropic set: DeepSeek trips ZTS305 and ZTS501, which
/// Claude's recordings never reached, and never reaches ZTS407 or ZTS502, which
/// Claude's do. Two fence sets of the same size describing different rules is
/// the reason a headline may not borrow another provider's baseline.
const deepseek_coverage_baseline = [_][]const u8{
    "ZTS305",
    "ZTS400",
    "ZTS401",
    "ZTS500",
    "ZTS501",
};

/// Return the coverage floor measured for one exact provider/model identity.
/// A new headline identity must publish its own complete corpus before the
/// default can move; borrowing another provider's fence set is never valid.
fn coverageBaseline(provider: agent.Provider, model: []const u8) ?[]const []const u8 {
    return switch (provider) {
        .anthropic => if (std.mem.eql(u8, model, models.defaultForProvider(.anthropic).id))
            &anthropic_coverage_baseline
        else
            null,
        .deepseek => if (std.mem.eql(u8, model, models.defaultForProvider(.deepseek).id))
            &deepseek_coverage_baseline
        else
            null,
        .local, .openai => null,
    };
}

test "coverage baselines are provider and model qualified" {
    try testing.expectEqual(
        @as(?[]const []const u8, &anthropic_coverage_baseline),
        coverageBaseline(.anthropic, models.defaultForProvider(.anthropic).id),
    );
    try testing.expectEqual(
        @as(?[]const []const u8, &deepseek_coverage_baseline),
        coverageBaseline(.deepseek, models.defaultForProvider(.deepseek).id),
    );
    try testing.expect(coverageBaseline(.local, local.default_model) == null);
    try testing.expect(coverageBaseline(.anthropic, "claude-other") == null);
    try testing.expect(coverageBaseline(.deepseek, "deepseek-v4-pro") == null);
    // The two sets are measurements of different models, not copies.
    try testing.expect(anthropic_coverage_baseline.len == deepseek_coverage_baseline.len);
    var identical = true;
    for (anthropic_coverage_baseline, deepseek_coverage_baseline) |claude_code, deepseek_code| {
        if (!std.mem.eql(u8, claude_code, deepseek_code)) identical = false;
    }
    try testing.expect(!identical);
}

/// Sorted JSON array of a code set, for a line git can diff.
///
/// No escaping: registry codes are comptime literals and scanned codes match
/// `ZTS` plus digits, so every key is alphanumeric by construction.
fn jsonCodeArray(a: std.mem.Allocator, set: *const codegen.CodeSet) ![]u8 {
    const codes = try a.dupe([]const u8, set.keys());
    std.mem.sort([]const u8, codes, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);

    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '[');
    for (codes, 0..) |code, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.append(a, '"');
        try buf.appendSlice(a, code);
        try buf.append(a, '"');
    }
    try buf.append(a, ']');
    return try buf.toOwnedSlice(a);
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
fn jsonUntripped(a: std.mem.Allocator, tripped: *const codegen.CodeSet) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '[');
    var first = true;
    for (zts.PolicyCatalog.rules()) |rule| {
        if (tripped.contains(rule.code)) continue;
        if (!first) try buf.append(a, ',');
        first = false;
        try buf.append(a, '"');
        try buf.appendSlice(a, rule.code);
        try buf.append(a, '"');
    }
    try buf.append(a, ']');
    return try buf.toOwnedSlice(a);
}

test "codegen baseline replays at the committed first-draft pass rate" {
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
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(a);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(a);
    // The model every cassette agrees on. Null until the first one is read; a
    // disagreement means the corpus is half re-recorded against another tier,
    // which would publish one row averaging two models.
    var corpus_model: ?[]const u8 = null;
    var models_read: usize = 0;
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
        var resolved = try resolveCaseSteps(ca, repo_root, replay_provider, rc.name);
        defer resolved.deinit(ca);
        const response_count = resolved.responseCount();
        if (response_count == 0) {
            try missing.append(a, rc.name);
            continue;
        }
        if (resolved.source == .flow_artifact) flow_backed += 1;

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
        var tr: transcript_mod.Transcript = .{};
        // A cassette that no longer covers its turn is collected, not thrown.
        // Returning at the first stale case means a compiler change that
        // invalidates several is discovered one paid recording at a time; the
        // whole re-record list is worth more than the early exit.
        const result = loop.runTurnWith(ca, client.asModelClient(), &registry, &tr, rc.prompt, .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        }) catch |err| {
            try stale.append(a, rc.name);
            std.debug.print(
                "[codegen-replay] {s}: {s} - its {d}-step cassette no longer covers the turn\n",
                .{ rc.name, @errorName(err), response_count },
            );
            continue;
        };
        client.finish() catch |err| {
            try stale.append(a, rc.name);
            std.debug.print(
                "[codegen-replay] {s}: {s} - its {d}-step flow has unconsumed checkpoints\n",
                .{ rc.name, @errorName(err), response_count },
            );
            continue;
        };
        try codegen.collectCodes(a, &tr, &tripped, &off_registry);

        // Ratchet each provider against its own recorded observation. Claude's
        // historical flat cassettes predate provider-qualified turn metadata,
        // so their immutable corpus pin remains the compatibility source.
        const recorded_expectation = if (resolved.flow_case) |flow_case|
            flow_case.manifest.turns[0].first_draft_veto_pass
        else
            null;
        const expected_first_draft = firstDraftExpectation(
            replay_provider,
            recorded_expectation,
            rc.expect_first_draft_pass,
        );
        const case_model = resolved.model() orelse headline_model;
        const on_headline = replay_provider == headline_provider and
            std.mem.eql(u8, case_model, headline_model);
        if (expected_first_draft) |expected| {
            if (result.first_draft_veto_pass != expected) {
                std.debug.print(
                    "[codegen-replay] {s}: expected first_draft_pass={} got {} (code {s}){s}\n",
                    .{
                        rc.name,
                        expected,
                        result.first_draft_veto_pass,
                        codegen.firstZtsCode(&tr) orelse "-",
                        if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                    },
                );
                if (on_headline) return error.CassetteRatchetMismatch;
            }
        } else {
            std.debug.print(
                "[codegen-replay] {s}: provider {s} has no recorded first-draft expectation{s}\n",
                .{
                    rc.name,
                    replay_provider.publicName(),
                    if (on_headline) "" else " - off-headline provider or model, measured not ratcheted",
                },
            );
            if (on_headline) return error.MissingProviderFirstDraftExpectation;
        }
        var case_intent: codegen.IntentOutcome = .not_checked;

        // Intent: does the produced handler do what the prompt asked for? Run
        // after the turn, against whatever it actually wrote. A case with no
        // spec, or a run with no built binary, stays `.not_checked` - never a
        // pass, so an unmeasured corpus reads as unmeasured.
        if (rc.intent) |intent| {
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
        if (!result.first_draft_veto_pass) {
            std.debug.print("[codegen-gap] {s}: {s} (green={})\n", .{
                rc.name,
                codegen.firstZtsCode(&tr) orelse "?",
                result.applied_edit,
            });
        }
        try results.append(a, .{
            .name = rc.name,
            .routed = true,
            .first_draft_pass = result.first_draft_veto_pass,
            .applied = result.applied_edit,
            .passed_criterion = result.first_draft_veto_pass,
            .roundtrips = result.roundtrips,
            .tool_calls = result.tool_call_count,
            .proven_guarantees = result.proven_guarantees,
            .intent = case_intent,
        });
        passes += 1;
    }

    if (stale.items.len > 0) {
        std.debug.print("[codegen-replay] {d} cassette(s) need re-recording:\n", .{stale.items.len});
        for (stale.items) |name| std.debug.print("  - {s}\n", .{name});
        const command = try recordingCommand(a, replay_provider, true);
        std.debug.print("  {s}\n", .{command});
        return error.StaleCodegenCassette;
    }

    if (missing.items.len > 0) {
        std.debug.print("[codegen-replay] missing committed cassette(s) for {d} case(s):\n", .{missing.items.len});
        for (missing.items) |name| std.debug.print("  - {s}\n", .{name});
        const command = try recordingCommand(a, replay_provider, false);
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

    // The publishable record of this run, on one line so
    // scripts/update-convergence.sh can lift it without parsing the rest of the
    // test output. Emitted every run, including when intent checks were
    // skipped - a row that says `intentChecked: 0` is honest; a missing row
    // would just look like the eval was not run.
    const summary = codegen.summarize(results.items);
    const version = corpusVersion();
    std.debug.print(
        "[codegen-convergence] {{\"corpusVersion\":\"{s}\",\"corpusCases\":{d}," ++
            "\"provider\":\"{s}\",\"model\":\"{s}\",\"policyHash\":\"{s}\",\"firstDraftPassPercent\":{d}," ++
            "\"firstDraftPasses\":{d},\"medianRoundtrips\":{d},\"intentPassPercent\":{d}," ++
            "\"intentPasses\":{d},\"intentChecked\":{d}}}\n",
        .{
            version[0..],
            summary.total,
            replay_provider.publicName(),
            published_model,
            zts.policyHash()[0..],
            summary.firstDraftPassPercent(),
            summary.first_draft_passes,
            summary.median_roundtrips,
            summary.intentPassPercent(),
            summary.intent_passes,
            summary.intent_checked,
        },
    );

    // What the corpus covers, published apart from the headline and under its
    // own marker.
    //
    // The headline says how often a first draft lands. It cannot say whether the
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

        const tripped_sorted = try jsonCodeArray(a, &tripped);
        const off_sorted = try jsonCodeArray(a, &off_registry);
        // The complement is carried on the line rather than left to be derived,
        // so a reader of docs/coverage.json needs no copy of the registry to see
        // what the corpus does not reach. It is also the half worth reading.
        const untripped_sorted = try jsonUntripped(a, &tripped);
        std.debug.print(
            "[proof-coverage] {{\"corpusVersion\":\"{s}\",\"rulesTotal\":{d},\"rulesTripped\":{d}," ++
                "\"tripped\":{s},\"untripped\":{s},\"offRegistry\":{s}}}\n",
            .{
                version[0..],
                zts.PolicyCatalog.rules().len,
                tripped.count(),
                tripped_sorted,
                untripped_sorted,
                off_sorted,
            },
        );

        const on_headline = replay_provider == headline_provider and
            std.mem.eql(u8, published_model, headline_model);
        if (coverageBaseline(replay_provider, published_model)) |baseline| {
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
        if (on_headline) {
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
        // Intent is a measurement, not a release threshold. A failure says the
        // recorded handler missed the task even if the compiler accepted its
        // shape. Publish that result without selecting a more flattering run.
        if (intent_passes != intent_checked) {
            std.debug.print(
                "[codegen-intent] failures are measured; no score threshold is applied\n",
                .{},
            );
        }
    }
}

test "every corpus case resolves to exactly one recording source" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);

    var flow_backed: usize = 0;
    for (record_corpus) |rc| {
        var resolved = try resolveCaseSteps(allocator, repo_root, headline_provider, rc.name);
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

    // The flat-cassette path is anthropic-only by construction, so it has to be
    // exercised against that provider or not at all. Checking it here keeps a
    // resolver that silently stopped reading flat cassettes from passing on the
    // strength of a headline that no longer uses them.
    var flat_backed: usize = 0;
    for (record_corpus) |rc| {
        var resolved = try resolveCaseSteps(allocator, repo_root, .anthropic, rc.name);
        defer resolved.deinit(allocator);
        if (resolved.source == .flat_cassette and resolved.responseCount() > 0) flat_backed += 1;
    }
    try std.testing.expect(flat_backed > 0);
}

test "flow-backed replay validates the current request checkpoint" {
    const allocator = std.testing.allocator;
    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);
    var resolved = try resolveCaseSteps(allocator, repo_root, headline_provider, "durable-order");
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

test "a broken flow artifact is refused rather than falling back" {
    const allocator = std.testing.allocator;
    var tmp = try IsolatedTmp.init(allocator, "codegen-resolve");
    defer tmp.cleanup(allocator);

    const name = "half-recorded";
    // A descriptor and nothing else: what an interrupted recording leaves.
    const descriptor = try std.fmt.allocPrint(allocator, "{s}/{s}/case.json", .{ empirical_flow_root, name });
    defer allocator.free(descriptor);
    try tmp.writeFile(allocator, descriptor, "{\"schema_version\":1}");

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

test "a failed recording restores the previous cassette" {
    // The recorder deletes the case directory before recording over it, and its
    // failure path deletes the partial too. Without a stash a failed run leaves
    // the case with nothing where a working cassette had been - which has
    // wiped the corpus once, recoverable only because cassettes are committed.
    const allocator = testing.allocator;

    var tmp = try IsolatedTmp.init(allocator, "codegen-stash");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"original\"}\n");

    // Stash, then clear, as the recorder does before a live turn.
    try testing.expect(stashCaseDir(allocator, tmp.abs_path, "case"));
    removeCaseDir(allocator, tmp.abs_path, "case");

    const cleared = try tmp.childPath(allocator, "case/step_0.jsonl");
    defer allocator.free(cleared);
    try testing.expect(!zts.file_io.fileExists(allocator, cleared));

    // The turn fails: restore.
    restoreCaseDir(allocator, tmp.abs_path, "case");

    const restored = try zts.file_io.readFile(allocator, cleared, 4096);
    defer allocator.free(restored);
    try testing.expectEqualStrings("{\"sse\":\"original\"}\n", restored);

    // The stash itself is gone, so a later run does not trip over it.
    const leftover = try tmp.childPath(allocator, "case" ++ stash_suffix ++ "/step_0.jsonl");
    defer allocator.free(leftover);
    try testing.expect(!zts.file_io.fileExists(allocator, leftover));
}

test "a successful recording drops the stash" {
    const allocator = testing.allocator;

    var tmp = try IsolatedTmp.init(allocator, "codegen-stash-ok");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"old\"}\n");

    try testing.expect(stashCaseDir(allocator, tmp.abs_path, "case"));
    removeCaseDir(allocator, tmp.abs_path, "case");
    // The turn succeeds and writes a new cassette.
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"new\"}\n");
    dropStashedCaseDir(allocator, tmp.abs_path, "case");

    const current = try tmp.childPath(allocator, "case/step_0.jsonl");
    defer allocator.free(current);
    const bytes = try zts.file_io.readFile(allocator, current, 4096);
    defer allocator.free(bytes);
    try testing.expectEqualStrings("{\"sse\":\"new\"}\n", bytes);

    const leftover = try tmp.childPath(allocator, "case" ++ stash_suffix ++ "/step_0.jsonl");
    defer allocator.free(leftover);
    try testing.expect(!zts.file_io.fileExists(allocator, leftover));
}
