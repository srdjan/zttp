//! Top-level entrypoint for `zttp expert` (developer CLI).

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const registry_mod = @import("registry/registry.zig");
const repl = @import("repl.zig");
const loop = @import("loop.zig");
const print_mode = @import("print_mode.zig");
const rpc_mode = @import("rpc_mode.zig");
const ledger = @import("ledger.zig");
const autoloop = @import("autoloop.zig");
const transcript_mod = @import("transcript.zig");
const agent = @import("agent.zig");
const session_state = @import("session_state.zig");
const property_goals = @import("property_goals.zig");
const models_registry = @import("providers/models.zig");
const local_client = @import("providers/local/client.zig");
const tools_common = @import("tools/common.zig");

const meta_tool = @import("tools/zts_expert_meta.zig");
const verify_paths_tool = @import("tools/zts_expert_verify_paths.zig");
const canonicalize_tool = @import("tools/zts_expert_canonicalize.zig");
const normalize_tool = @import("tools/zts_expert_normalize.zig");
const describe_rule_tool = @import("tools/zts_expert_describe_rule.zig");
const search_tool = @import("tools/zts_expert_search.zig");
const edit_simulate_tool = @import("tools/zts_expert_edit_simulate.zig");
const review_patch_tool = @import("tools/zts_expert_review_patch.zig");
const prove_patch_tool = @import("tools/zts_expert_prove_patch.zig");
const system_proof_tool = @import("tools/zts_expert_system_proof.zig");
const features_tool = @import("tools/zts_expert_features.zig");
const modules_tool = @import("tools/zts_expert_modules.zig");
const verify_modules_tool = @import("tools/zts_expert_verify_modules.zig");
const workspace_list_files_tool = @import("tools/workspace_list_files.zig");
const workspace_read_file_tool = @import("tools/workspace_read_file.zig");
const workspace_search_text_tool = @import("tools/workspace_search_text.zig");
const zts_check_tool = @import("tools/zts_check.zig");
const zig_build_step_tool = @import("tools/zig_build_step.zig");
const zig_test_step_tool = @import("tools/zig_test_step.zig");
const gen_tests_tool = @import("tools/gen_tests.zig");
const pi_goal_check_tool = @import("tools/pi_goal_check.zig");
const pi_goal_candidate_tool = @import("tools/pi_goal_candidate.zig");
const pi_repair_plan_tool = @import("tools/pi_repair_plan.zig");
const pi_apply_repair_plan_tool = @import("tools/pi_apply_repair_plan.zig");
const ast_rewrite_tool = @import("tools/zts_expert_ast_rewrite.zig");
const pi_specs_status_tool = @import("tools/pi_specs_status.zig");
const pi_witnesses_tool = @import("tools/pi_witnesses.zig");
const pi_remember_fact_tool = @import("tools/pi_remember_fact.zig");
const pi_recall_facts_tool = @import("tools/pi_recall_facts.zig");
const pi_extension_catalog_tool = @import("tools/pi_extension_catalog.zig");
const effects_tool = @import("tools/zts_expert_effects.zig");
const holes_tool = @import("tools/zts_expert_holes.zig");
const fill_hole_tool = @import("tools/zts_expert_fill_hole.zig");
const narrow_tool = @import("tools/zts_expert_narrow.zig");
const ratchet_tool = @import("tools/zts_expert_ratchet.zig");
const reference_tool = @import("tools/zts_expert_reference.zig");

/// Re-exported so the runtime-side witness replay implementation can
/// share the canonical `Verdict` type and function pointer signature.
/// The host binary registers its replay function via
/// `pi_app.witness_replay.setReplayFn` at startup.
pub const witness_replay = @import("witness_replay.zig");
/// Re-exported so the runtime stack can register the engine-backed perf
/// probe via `pi_app.perf_probe.setProbeFn` at startup (Slice H wiring).
pub const perf_probe = @import("perf_probe.zig");

/// Proof-carrying changes: the runtime host registers the signed
/// equivalence-receipt probe via `pi_app.equivalence_probe.setProbeFn` at
/// startup, mirroring the perf-probe seam.
pub const equivalence_probe = @import("equivalence_probe.zig");

/// Proof Flight Recorder: the runtime host registers the capsule-replay probe
/// via `pi_app.capsule_probe.setProbeFn` at startup, mirroring the perf-probe
/// seam. The expert loop uses it to flag edits that regress a recorded capsule.
pub const capsule_probe = @import("capsule_probe.zig");
pub const demo_passport = @import("demo_passport.zig");

pub fn checkLocalReadiness(allocator: std.mem.Allocator) !void {
    const raw = if (std.c.getenv("ZTTP_MLX_BASE_URL")) |value| std.mem.sliceTo(value, 0) else null;
    const base_url = local_client.effectiveBaseUrl(raw);
    return local_client.checkReadiness(allocator, base_url, local_client.default_model);
}

/// Fail before scaffolding when the current product default cannot launch.
/// The one provider authority keeps this check aligned with session selection.
pub fn checkDefaultProviderReadiness(allocator: std.mem.Allocator) !void {
    switch (models_registry.default_provider) {
        .local => return checkLocalReadiness(allocator),
        .anthropic => if (!envHasNonBlank("ANTHROPIC_API_KEY")) return error.MissingAnthropicCredential,
        .openai => if (!envHasNonBlank("OPENAI_API_KEY")) return error.MissingOpenAICredential,
        .deepseek => if (!envHasNonBlank("DEEPSEEK_API_KEY")) return error.MissingDeepSeekCredential,
    }
}

fn envHasNonBlank(name: [:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    return std.mem.trim(u8, std.mem.sliceTo(raw, 0), " \t\r\n").len > 0;
}

const Registry = registry_mod.Registry;
const ToolDef = registry_mod.ToolDef;

/// The tool catalog, grouped by what a bundle lets the agent do rather than by
/// which file each tool lives in. The `minimal` preset is the workspace bundle,
/// so "read-only workspace access" is a named set instead of three names
/// repeated in a second function that could fall out of step with the first.
///
/// A bundle is not an authorization boundary. That is `ToolDef.effect`, which
/// every tool still declares for itself and which `ToolDef.allowedOn` reads.
pub const Bundle = enum {
    /// Read the workspace: list, read, search.
    workspace,
    /// Compiler analysis over handler sources and the rule registry.
    analysis,
    /// Run a process: the compiler, the build, the tests.
    build,
    /// Propose and dry-run source repairs. Nothing here writes a file.
    repair,
    /// Agent-owned memory: facts, witnesses, extension catalog.
    memory,
    /// Produce new project artifacts.
    authoring,
};

const workspace_bundle = [_]ToolDef{
    workspace_read_file_tool.tool,
    workspace_list_files_tool.tool,
    workspace_search_text_tool.tool,
};

const analysis_bundle = [_]ToolDef{
    meta_tool.tool,
    verify_paths_tool.tool,
    canonicalize_tool.tool,
    normalize_tool.tool,
    describe_rule_tool.tool,
    search_tool.tool,
    edit_simulate_tool.tool,
    review_patch_tool.tool,
    prove_patch_tool.tool,
    system_proof_tool.tool,
    features_tool.tool,
    modules_tool.tool,
    verify_modules_tool.tool,
    effects_tool.tool,
    holes_tool.tool,
    fill_hole_tool.tool,
    narrow_tool.tool,
    ratchet_tool.tool,
    reference_tool.tool,
};

const build_bundle = [_]ToolDef{
    zts_check_tool.tool,
    zig_build_step_tool.tool,
    zig_test_step_tool.tool,
    pi_specs_status_tool.tool,
};

const repair_bundle = [_]ToolDef{
    pi_goal_check_tool.tool,
    pi_goal_candidate_tool.tool,
    pi_repair_plan_tool.tool,
    pi_apply_repair_plan_tool.tool,
    ast_rewrite_tool.tool,
};

const memory_bundle = [_]ToolDef{
    pi_witnesses_tool.tool,
    pi_remember_fact_tool.tool,
    pi_recall_facts_tool.tool,
    pi_extension_catalog_tool.tool,
};

const authoring_bundle = [_]ToolDef{
    gen_tests_tool.tool,
};

pub fn bundleTools(bundle: Bundle) []const ToolDef {
    return switch (bundle) {
        .workspace => &workspace_bundle,
        .analysis => &analysis_bundle,
        .build => &build_bundle,
        .repair => &repair_bundle,
        .memory => &memory_bundle,
        .authoring => &authoring_bundle,
    };
}

fn registerBundle(reg: *Registry, allocator: std.mem.Allocator, bundle: Bundle) !void {
    for (bundleTools(bundle)) |tool| try reg.register(allocator, tool);
}

pub fn buildMinimalRegistry(allocator: std.mem.Allocator) !Registry {
    var reg: Registry = .{};
    errdefer reg.deinit(allocator);
    try registerBundle(&reg, allocator, .workspace);
    return reg;
}

pub fn buildRegistry(allocator: std.mem.Allocator) !Registry {
    var reg: Registry = .{};
    errdefer reg.deinit(allocator);
    inline for (comptime std.enums.values(Bundle)) |bundle| {
        try registerBundle(&reg, allocator, bundle);
    }
    return reg;
}

/// Long flags whose next token is a value. `zts_main.zig` consults this
/// list so it can skip the value while scanning for stray positional args.
pub const value_taking_flags = [_][]const u8{ "--session-id", "--print", "--mode", "--tools", "--fork", "--goal", "--max-iters", "--handler", "--provider", "--model" };

var captured_argv: ?[]const []const u8 = null;

pub fn setInvocationArgv(argv: []const []const u8) void {
    captured_argv = argv;
}

pub fn run(allocator: std.mem.Allocator) !void {
    const argv = captured_argv orelse &[_][]const u8{};
    const flags = parseExpertFlags(argv) catch |err| exitWithMessage(flagErrorMessage(err), 2);

    perf_probe.setEnabled(flags.perf_receipt);
    equivalence_probe.setEnabled(flags.equivalence_receipt);

    var registry = switch (flags.tools_preset) {
        .full => try buildRegistry(allocator),
        .minimal => try buildMinimalRegistry(allocator),
    };
    defer registry.deinit(allocator);

    if (flags.goals != null) {
        runAutoloop(allocator, &registry, flags) catch |err| return handleModeError(err);
        return;
    }

    if (flags.rpc_mode) {
        rpc_mode.run(allocator, &registry, flags, flags.policy orelse .auto_reject) catch |err| return handleModeError(err);
        return;
    }

    if (flags.print != null) {
        print_mode.run(allocator, &registry, flags, flags.policy orelse .auto_reject) catch |err| return handleModeError(err);
        return;
    }

    repl.run(allocator, &registry, flags, flags.policy) catch |err| return handleModeError(err);
}

pub fn runLedgerCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    try ledger.runWithArgs(allocator, argv);
}

fn runAutoloop(
    allocator: std.mem.Allocator,
    registry: *const Registry,
    flags: ExpertFlags,
) !void {
    const goals_csv = flags.goals orelse return;
    const handler = flags.handler orelse return;

    const goals = try splitCsv(allocator, goals_csv);
    defer {
        for (goals) |g| allocator.free(g);
        allocator.free(goals);
    }
    if (goals.len == 0) exitWithMessage("error: --goal list is empty\n", 2);
    for (goals) |goal| {
        if (!property_goals.isGoalDriveable(goal)) {
            var stderr: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &stderr,
                "error: unsupported autoloop goal '{s}' in --goal; try one of: {s}\n",
                .{ goal, property_goals.supported_goal_list },
            ) catch "error: unsupported autoloop goal in --goal\n";
            exitWithMessage(line, 2);
        }
    }

    const workspace_root = try tools_common.workspaceRoot(allocator);
    defer allocator.free(workspace_root);

    // Bootstrap a session unless `--no-session` is passed: lets the
    // autoloop's verified_patch and autoloop_outcome events persist to
    // events.jsonl, so a follow-up `zttp expert --resume` can open
    // the resulting witnesses tab on the same patches. Without
    // session bootstrap the run is in-memory only (the original
    // behaviour, kept for `--no-session`).
    var session = try agent.initFromEnvWithSessionConfig(allocator, registry, .{
        .model_free = true,
        .no_session = flags.no_session,
        .no_persist_tool_output = flags.no_persist_tool_output,
        .no_context_files = true, // autoloop doesn't need project context
        .session_id = flags.session_id,
        .resume_latest = flags.resume_latest,
        .provider = flags.provider,
        .model = flags.model,
    });
    defer session.deinit(allocator);

    var budget: autoloop.Budget = .{};
    if (flags.max_iters) |n| budget.max_iterations = n;

    const goal_slices = try allocator.alloc([]const u8, goals.len);
    defer allocator.free(goal_slices);
    for (goals, 0..) |g, i| goal_slices[i] = g;

    const outcome = autoloop.drive(allocator, registry, &session.transcript, .{
        .workspace_root = workspace_root,
        .file = handler,
        .goals = goal_slices,
        .budget = budget,
        .events_path = session.events_path,
    }) catch |err| {
        var stderr: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&stderr, "autoloop error: {s}\n", .{@errorName(err)}) catch "autoloop error\n";
        exitWithMessage(line, 1);
    };

    try printAutoloopOutcome(allocator, outcome, &session.transcript, handler, goal_slices);
    if (session.session_id) |sid| {
        var stdout_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&stdout_buf, "session: {s} (resume with `zttp expert --resume`)\n", .{sid}) catch "session persisted\n";
        _ = std.c.write(std.c.STDOUT_FILENO, line.ptr, line.len);
    }
    if (outcome.verdict != .achieved) std.process.exit(1);
}

fn printAutoloopOutcome(
    allocator: std.mem.Allocator,
    outcome: autoloop.Outcome,
    transcript: *const transcript_mod.Transcript,
    file: []const u8,
    goals: []const []const u8,
) !void {
    const props = session_state.currentProperties(transcript, file);

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.print("autoloop verdict: {s}\n", .{@tagName(outcome.verdict)});
    try w.print("iterations: {d}\n", .{outcome.iterations});
    try w.writeAll("goals:\n");
    for (goals) |goal| {
        // .achieved means pi_goal_check reported ok for every requested goal
        // on this handler, even when no patch was needed and the transcript
        // holds no VerifiedPatch snapshot to derive properties from.
        const met = outcome.verdict == .achieved or
            (if (props) |p| session_state.propertyByName(p, goal) else false);
        try w.print("  {s} {s}\n", .{ if (met) "[x]" else "[ ]", goal });
    }
    if (outcome.final_patch_hash) |hash| {
        const hex = std.fmt.bytesToHex(hash, .lower);
        try w.writeAll("final_patch_hash: ");
        try w.writeAll(&hex);
        try w.writeByte('\n');
    }

    const bytes = buf.written();
    _ = std.c.write(std.c.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn splitCsv(allocator: std.mem.Allocator, csv: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return out.toOwnedSlice(allocator);
}

pub const ToolsPreset = enum { full, minimal };

fn parseToolsPreset(val: []const u8) !ToolsPreset {
    if (std.mem.eql(u8, val, "minimal")) return .minimal;
    if (std.mem.eql(u8, val, "full")) return .full;
    return error.UnsupportedToolsPreset;
}

fn exitWithMessage(msg: []const u8, code: u8) noreturn {
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
    std.process.exit(code);
}

pub fn modeErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ProviderMismatch => "error: --model is not available for the configured provider; model IDs do not switch providers\n",
        error.NoActiveProvider => "error: no active model provider\n",
        error.MissingAnthropicCredential => "error: --provider claude requires ANTHROPIC_API_KEY or `zttp auth claude`\n",
        error.MissingOpenAICredential => "error: --provider openai requires OPENAI_API_KEY or `zttp auth openai`\n",
        error.MissingDeepSeekCredential => "error: --provider deepseek requires DEEPSEEK_API_KEY or `zttp auth deepseek`\n",
        error.InvalidDeepSeekBaseUrl => "error: DEEPSEEK_BASE_URL must be an HTTPS root carrying no credential, such as https://api.deepseek.com\n",
        error.ProjectInstructionsTooLarge => "error: complete AGENTS.md/CLAUDE.md instructions do not fit Pi's 48 KiB system-prompt cap; reduce the applicable project instructions before launching\n",
        error.ProtectedPromptTooLarge => "error: Pi's protected expert prompt exceeds its 16 KiB safety gate; update the Pi build before launching\n",
        error.UnsupportedOpenAIModelOverride => "error: ZTS_OPENAI_MODEL is no longer supported; use --provider openai --model <registered-id>\n",
        error.LegacySessionIdentity => "error: this historical session has no provider identity; resume once with --provider local|claude|openai|deepseek and optional --model\n",
        error.InvalidStoredProvider => "error: the stored session provider is invalid; restart with --provider and optional --model to override it\n",
        error.LocalServerUnavailable,
        error.LocalHealthNotOk,
        error.LocalModelUnavailable,
        error.InvalidResponseJson,
        => "error: local LFM is not ready; start `mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080`\n",
        error.InvalidMlxBaseUrl => "error: ZTTP_MLX_BASE_URL must be a credential-free HTTP loopback root such as http://127.0.0.1:8080\n",
        else => null,
    };
}

fn handleModeError(err: anyerror) !void {
    if (modeErrorMessage(err)) |message| exitWithMessage(message, 2);
    return err;
}

pub fn flagErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MutuallyExclusiveApprovalFlags => "error: --yes and --no-edit are mutually exclusive\n",
        error.MissingSessionId => "error: --session-id requires a value\n",
        error.MutuallyExclusiveResumeFlags => "error: --resume and --session-id are mutually exclusive\n",
        error.MissingPrintPrompt => "error: --print requires a value\n",
        error.MissingModeValue => "error: --mode requires a value (json|rpc)\n",
        error.UnsupportedMode => "error: --mode only accepts 'json' or 'rpc'\n",
        error.JsonModeRequiresPrint => "error: --mode json requires --print <prompt>\n",
        error.RpcModeConflictsWithPrint => "error: --mode rpc cannot be combined with --print\n",
        error.MissingToolsPreset => "error: --tools requires a value (full, minimal)\n",
        error.UnsupportedToolsPreset => "error: --tools only accepts 'full' or 'minimal'\n",
        error.MissingForkSessionId => "error: --fork requires a session id value\n",
        error.MutuallyExclusiveForkFlags => "error: --fork is mutually exclusive with --resume, --continue, and --session-id\n",
        error.MissingGoalValue => "error: --goal requires a comma-separated list of property tags\n",
        error.MissingMaxItersValue => "error: --max-iters requires a positive integer\n",
        error.InvalidMaxIters => "error: --max-iters must be a positive integer\n",
        error.MissingHandlerValue => "error: --handler requires a path value\n",
        error.GoalRequiresHandler => "error: --goal requires --handler <path>\n",
        error.GoalConflictsWithPrintOrRpc => "error: --goal cannot be combined with --print or --mode rpc\n",
        error.MissingModelValue => "error: --model requires a model id value\n",
        error.MissingProviderValue => "error: --provider requires local, claude, or openai\n",
        error.UnsupportedProvider => "error: --provider only accepts local, claude, or openai\n",
        error.UnknownModel => "error: --model has an unknown id; run /model in the expert REPL to list available models\n",
        error.GoalConflictsWithProviderOrModel => "error: --goal is compiler-only and cannot be combined with --provider or --model\n",
        else => "error: unexpected flag parse failure\n",
    };
}

/// Validate a `--model <id>` launch value against the same registry the
/// `/model` slash command uses, returning the canonical static id so it
/// outlives the session. An unknown id fails closed with `error.UnknownModel`.
fn resolveModelId(val: []const u8) ![]const u8 {
    const m = models_registry.findById(val) orelse return error.UnknownModel;
    return m.id;
}

fn parseMaxIters(val: []const u8) !u32 {
    const n = std.fmt.parseInt(u32, val, 10) catch return error.InvalidMaxIters;
    if (n == 0) return error.InvalidMaxIters;
    return n;
}

fn setMode(out: *ExpertFlags, val: []const u8) !void {
    if (std.mem.eql(u8, val, "json")) {
        out.json_mode = true;
        return;
    }
    if (std.mem.eql(u8, val, "rpc")) {
        out.rpc_mode = true;
        return;
    }
    return error.UnsupportedMode;
}

/// Flags parsed from `zttp expert` argv. `policy == null` means the user
/// did not pass `--yes` or `--no-edit`; callers pick an appropriate default
/// (`.ask` for interactive, `.auto_reject` for `--print`).
pub const ExpertFlags = struct {
    policy: ?loop.ApprovalPolicy = null,
    no_session: bool = false,
    no_persist_tool_output: bool = false,
    /// Skip the AGENTS.md / CLAUDE.md project-context walk. System prompt
    /// still ships full persona + live snapshots; only the appended
    /// project-context section is suppressed.
    no_context_files: bool = false,
    session_id: ?[]const u8 = null,
    resume_latest: bool = false,
    fork_session_id: ?[]const u8 = null,
    print: ?[]const u8 = null,
    json_mode: bool = false,
    /// Line-delimited JSON-RPC 2.0 over stdio. Long-lived session; mutually
    /// exclusive with --print.
    rpc_mode: bool = false,
    tools_preset: ToolsPreset = .full,
    /// Comma-separated property tags to drive convergence against. When
    /// non-null, `zttp expert` short-circuits the conversational run and
    /// invokes the autoloop orchestrator end-to-end.
    goals: ?[]const u8 = null,
    /// Iteration budget for the autoloop. When null, the orchestrator's
    /// default (8) applies.
    max_iters: ?u32 = null,
    /// Handler path the autoloop operates on. Required whenever `goals` is
    /// set; ignored otherwise.
    handler: ?[]const u8 = null,
    /// Emit a signed perf-as-proof receipt (`kind=perf` row in
    /// `.zttp/proofs.jsonl`) on every applied edit. Default on, matching
    /// the attestation default; `--no-perf-receipt` opts out. No effect when
    /// the runtime probe is not registered (analyzer-only builds, tests).
    perf_receipt: bool = true,
    /// Emit a signed `kind=equivalence` receipt after each applied edit: the
    /// behavioral verdict between the pre- and post-edit handler. Default on,
    /// matching the attestation default; `--no-equivalence-receipt` opts out.
    equivalence_receipt: bool = true,
    /// Launch-scoped provider override. The public Claude name maps to the
    /// existing Anthropic adapter without changing its internal identity.
    provider: ?models_registry.Provider = null,
    /// Launch-time model override (`--model <id>`). Parsing resolves a canonical
    /// registry id; session construction then checks it against the resolved
    /// provider. Null keeps that provider's registry default.
    model: ?[]const u8 = null,
};

fn takeArg(i: *usize, argv: []const []const u8, missing: anyerror) ![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return missing;
    return argv[i.*];
}

/// Scan argv for the expert launch flags. Unknown `--*` tokens are ignored so
/// future slices can add their own without breaking this parser. `--yes` and
/// `--no-edit` together return an error so the caller can report a clear
/// diagnostic. Order-independent; repetition is idempotent.
pub fn parseExpertFlags(argv: []const []const u8) !ExpertFlags {
    var out: ExpertFlags = .{};
    var saw_yes = false;
    var saw_no_edit = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--yes")) saw_yes = true;
        if (std.mem.eql(u8, arg, "--no-edit")) saw_no_edit = true;
        if (std.mem.eql(u8, arg, "--no-session")) out.no_session = true;
        if (std.mem.eql(u8, arg, "--no-persist-tool-output")) out.no_persist_tool_output = true;
        if (std.mem.eql(u8, arg, "--no-context-files")) out.no_context_files = true;
        if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "--continue")) out.resume_latest = true;
        if (std.mem.eql(u8, arg, "--fork")) {
            out.fork_session_id = try takeArg(&i, argv, error.MissingForkSessionId);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fork=")) {
            out.fork_session_id = arg["--fork=".len..];
        }
        if (std.mem.eql(u8, arg, "--tools")) {
            out.tools_preset = try parseToolsPreset(try takeArg(&i, argv, error.MissingToolsPreset));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--tools=")) {
            out.tools_preset = try parseToolsPreset(arg["--tools=".len..]);
        }
        if (std.mem.eql(u8, arg, "--session-id")) {
            out.session_id = try takeArg(&i, argv, error.MissingSessionId);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--session-id=")) {
            out.session_id = arg["--session-id=".len..];
        }
        if (std.mem.eql(u8, arg, "--print")) {
            out.print = try takeArg(&i, argv, error.MissingPrintPrompt);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--print=")) {
            out.print = arg["--print=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--mode")) {
            try setMode(&out, try takeArg(&i, argv, error.MissingModeValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            try setMode(&out, arg["--mode=".len..]);
        }
        if (std.mem.eql(u8, arg, "--goal")) {
            out.goals = try takeArg(&i, argv, error.MissingGoalValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--goal=")) {
            out.goals = arg["--goal=".len..];
        }
        if (std.mem.eql(u8, arg, "--max-iters")) {
            out.max_iters = try parseMaxIters(try takeArg(&i, argv, error.MissingMaxItersValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--max-iters=")) {
            out.max_iters = try parseMaxIters(arg["--max-iters=".len..]);
        }
        if (std.mem.eql(u8, arg, "--handler")) {
            out.handler = try takeArg(&i, argv, error.MissingHandlerValue);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--handler=")) {
            out.handler = arg["--handler=".len..];
        }
        if (std.mem.eql(u8, arg, "--model")) {
            out.model = try resolveModelId(try takeArg(&i, argv, error.MissingModelValue));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            out.model = try resolveModelId(arg["--model=".len..]);
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            const value = try takeArg(&i, argv, error.MissingProviderValue);
            out.provider = models_registry.Provider.parsePublic(value) orelse return error.UnsupportedProvider;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--provider=")) {
            const value = arg["--provider=".len..];
            out.provider = models_registry.Provider.parsePublic(value) orelse return error.UnsupportedProvider;
        }
        if (std.mem.eql(u8, arg, "--no-perf-receipt")) out.perf_receipt = false;
        if (std.mem.eql(u8, arg, "--perf-receipt")) out.perf_receipt = true;
        if (std.mem.eql(u8, arg, "--no-equivalence-receipt")) out.equivalence_receipt = false;
        if (std.mem.eql(u8, arg, "--equivalence-receipt")) out.equivalence_receipt = true;
    }
    if (saw_yes and saw_no_edit) return error.MutuallyExclusiveApprovalFlags;
    if (out.resume_latest and out.session_id != null) return error.MutuallyExclusiveResumeFlags;
    if (out.fork_session_id != null and out.resume_latest) return error.MutuallyExclusiveForkFlags;
    if (out.fork_session_id != null and out.session_id != null) return error.MutuallyExclusiveForkFlags;
    if (out.json_mode and out.print == null) return error.JsonModeRequiresPrint;
    if (out.rpc_mode and out.print != null) return error.RpcModeConflictsWithPrint;
    if (out.goals != null and out.handler == null) return error.GoalRequiresHandler;
    if (out.goals != null and (out.print != null or out.rpc_mode)) return error.GoalConflictsWithPrintOrRpc;
    if (out.goals != null and (out.provider != null or out.model != null)) return error.GoalConflictsWithProviderOrModel;
    if (saw_yes) {
        out.policy = .auto_approve;
    } else if (saw_no_edit) {
        out.policy = .auto_reject;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// When adding new tools to buildRegistry, extend the expected_names list below.
// Do not reintroduce a hardcoded count: the assertion is name-based, not numeric.
test "buildRegistry registers every first-party compiler primitive" {
    var reg = try buildRegistry(testing.allocator);
    defer reg.deinit(testing.allocator);

    const expected_names = [_][]const u8{
        "zts_expert_meta",
        "zts_expert_verify_paths",
        "zts_expert_canonicalize",
        "zts_expert_normalize",
        "zts_expert_describe_rule",
        "zts_expert_search",
        "zts_expert_edit_simulate",
        "zts_expert_review_patch",
        "zts_expert_prove_patch",
        "zts_expert_system_proof",
        "zts_expert_features",
        "zts_expert_modules",
        "zts_expert_verify_modules",
        "workspace_list_files",
        "workspace_read_file",
        "workspace_search_text",
        "zts_check",
        "zig_build_step",
        "zig_test_step",
        "workspace_gen_tests",
        "pi_goal_check",
        "pi_repair_plan",
        "pi_apply_repair_plan",
        "zts_expert_ast_rewrite",
        "pi_specs_status",
        "pi_witnesses",
        "pi_remember_fact",
        "pi_recall_facts",
        "pi_extension_catalog",
        "zts_expert_effects",
        "zts_expert_holes",
        "zts_expert_fill_hole",
        "zts_expert_narrow",
        "zts_expert_ratchet",
    };

    for (expected_names) |expected| {
        if (reg.findByName(expected) == null) {
            std.debug.print("missing tool: {s}\n", .{expected});
            return error.TestFailed;
        }
    }
    try testing.expect(reg.count() >= expected_names.len);
}

test "buildRegistry omits the direct feature-plan writer from model tools" {
    var reg = try buildRegistry(testing.allocator);
    defer reg.deinit(testing.allocator);

    try testing.expect(reg.findByName("pi_apply_feature_plan") == null);
    for (reg.list()) |registered| {
        if (registered.effect == .write_workspace) {
            try testing.expect(!registered.allowedOn(.model));
        }
    }

    const process_tools = [_][]const u8{
        "workspace_search_text",
        "zts_check",
        "pi_specs_status",
    };
    for (process_tools) |process_tool_name| {
        const registered = reg.findByName(process_tool_name) orelse return error.TestFailed;
        try testing.expectEqual(registry_mod.ToolEffect.execute_process, registered.effect);
        try testing.expect(registered.allowedOn(.model));
        try testing.expect(!registered.allowedOn(.rpc));
    }
}

test "every model tool declares an explicit context policy with all policy classes represented" {
    var reg = try buildRegistry(testing.allocator);
    defer reg.deinit(testing.allocator);

    var exact: usize = 0;
    var replayable: usize = 0;
    var digest: usize = 0;
    for (reg.list()) |registered| {
        if (!registered.allowedOn(.model)) continue;
        switch (registered.context_policy) {
            .exact => exact += 1,
            .replayable_preview => replayable += 1,
            .structured_digest => digest += 1,
        }
    }
    try testing.expect(exact > 0);
    try testing.expect(replayable > 0);
    try testing.expect(digest > 0);
}

fn expectOkContains(outcome: *repl.DispatchOutcome, allocator: std.mem.Allocator, needle: []const u8) !void {
    switch (outcome.*) {
        .result => |*r| {
            defer r.deinit(allocator);
            try testing.expect(r.ok);
            try testing.expect(std.mem.indexOf(u8, r.llm_text, needle) != null);
        },
        else => return error.TestFailed,
    }
}

test "parseExpertFlags: empty argv yields defaults" {
    const flags = try parseExpertFlags(&.{});
    try testing.expect(flags.policy == null);
    try testing.expectEqual(false, flags.no_session);
    try testing.expectEqual(false, flags.no_persist_tool_output);
    // Perf receipts are on by default, matching the attestation default.
    try testing.expectEqual(true, flags.perf_receipt);
}

test "parseExpertFlags: --no-perf-receipt opts out" {
    const argv = [_][]const u8{ "zts", "expert", "--no-perf-receipt" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(false, flags.perf_receipt);
}

test "parseExpertFlags: equivalence receipt defaults on, --no- opts out" {
    const default_argv = [_][]const u8{ "zts", "expert" };
    const default_flags = try parseExpertFlags(default_argv[0..]);
    try testing.expectEqual(true, default_flags.equivalence_receipt);

    const off_argv = [_][]const u8{ "zts", "expert", "--no-equivalence-receipt" };
    const off_flags = try parseExpertFlags(off_argv[0..]);
    try testing.expectEqual(false, off_flags.equivalence_receipt);
}

test "parseExpertFlags: --yes yields auto_approve" {
    const argv = [_][]const u8{ "zts", "expert", "--yes" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(loop.ApprovalPolicy.auto_approve, flags.policy.?);
    try testing.expectEqual(false, flags.no_session);
    try testing.expectEqual(false, flags.no_persist_tool_output);
}

test "parseExpertFlags: --no-edit yields auto_reject" {
    const argv = [_][]const u8{ "zts", "expert", "--no-edit" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(loop.ApprovalPolicy.auto_reject, flags.policy.?);
}

test "parseExpertFlags: --no-session alone flips only that field" {
    const argv = [_][]const u8{ "zts", "expert", "--no-session" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.policy == null);
    try testing.expectEqual(true, flags.no_session);
    try testing.expectEqual(false, flags.no_persist_tool_output);
}

test "parseExpertFlags: --no-persist-tool-output alone flips only that field" {
    const argv = [_][]const u8{ "zts", "expert", "--no-persist-tool-output" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.policy == null);
    try testing.expectEqual(false, flags.no_session);
    try testing.expectEqual(true, flags.no_persist_tool_output);
}

test "parseExpertFlags: --yes --no-session --no-persist-tool-output combine" {
    const argv = [_][]const u8{ "zts", "expert", "--yes", "--no-session", "--no-persist-tool-output" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(loop.ApprovalPolicy.auto_approve, flags.policy.?);
    try testing.expectEqual(true, flags.no_session);
    try testing.expectEqual(true, flags.no_persist_tool_output);
}

test "parseExpertFlags: --yes + --no-edit still errors regardless of session flags" {
    const argv = [_][]const u8{ "zts", "expert", "--yes", "--no-session", "--no-edit" };
    try testing.expectError(error.MutuallyExclusiveApprovalFlags, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --no-context-files flips only that field" {
    const argv = [_][]const u8{ "zts", "expert", "--no-context-files" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.no_context_files);
    try testing.expectEqual(false, flags.no_session);
    try testing.expectEqual(false, flags.no_persist_tool_output);
}

test "parseExpertFlags: --no-context-files defaults to false" {
    const argv = [_][]const u8{ "zts", "expert" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(false, flags.no_context_files);
}

test "parseExpertFlags: --mode rpc sets rpc_mode" {
    const argv = [_][]const u8{ "zts", "expert", "--mode", "rpc" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.rpc_mode);
    try testing.expectEqual(false, flags.json_mode);
}

test "parseExpertFlags: --mode=rpc inline form" {
    const argv = [_][]const u8{ "zts", "expert", "--mode=rpc" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.rpc_mode);
}

test "parseExpertFlags: --mode rpc with --print errors" {
    const argv = [_][]const u8{ "zts", "expert", "--mode", "rpc", "--print", "hi" };
    try testing.expectError(error.RpcModeConflictsWithPrint, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --mode bogus still rejected" {
    const argv = [_][]const u8{ "zts", "expert", "--mode", "xml" };
    try testing.expectError(error.UnsupportedMode, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: unknown --frobnicate is ignored, defaults preserved" {
    const argv = [_][]const u8{ "zts", "expert", "--frobnicate" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.policy == null);
    try testing.expectEqual(false, flags.no_session);
    try testing.expectEqual(false, flags.no_persist_tool_output);
}

test "parseExpertFlags: repeated --no-session is idempotent" {
    const argv = [_][]const u8{ "zts", "expert", "--no-session", "--no-session" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.no_session);
    try testing.expect(flags.policy == null);
}

test "parseExpertFlags: --session-id <id> two-argv form captures value" {
    const argv = [_][]const u8{ "zts", "expert", "--session-id", "abc123" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.session_id != null);
    try testing.expectEqualStrings("abc123", flags.session_id.?);
    try testing.expectEqual(false, flags.resume_latest);
}

test "parseExpertFlags: --session-id=<id> one-argv form captures value" {
    const argv = [_][]const u8{ "zts", "expert", "--session-id=xyz" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.session_id != null);
    try testing.expectEqualStrings("xyz", flags.session_id.?);
}

test "parseExpertFlags: --session-id without a value errors" {
    const argv = [_][]const u8{ "zts", "expert", "--session-id" };
    try testing.expectError(error.MissingSessionId, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --resume alone sets the flag" {
    const argv = [_][]const u8{ "zts", "expert", "--resume" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.resume_latest);
    try testing.expect(flags.session_id == null);
}

test "parseExpertFlags: --resume + --session-id is an error" {
    const argv = [_][]const u8{ "zts", "expert", "--resume", "--session-id", "x" };
    try testing.expectError(error.MutuallyExclusiveResumeFlags, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --print \"hello\" captures prompt" {
    const argv = [_][]const u8{ "zts", "expert", "--print", "hello" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.print != null);
    try testing.expectEqualStrings("hello", flags.print.?);
    try testing.expectEqual(false, flags.json_mode);
}

test "parseExpertFlags: --print=hello inline form captures prompt" {
    const argv = [_][]const u8{ "zts", "expert", "--print=hello" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.print != null);
    try testing.expectEqualStrings("hello", flags.print.?);
}

test "parseExpertFlags: --print without a value errors MissingPrintPrompt" {
    const argv = [_][]const u8{ "zts", "expert", "--print" };
    try testing.expectError(error.MissingPrintPrompt, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --mode json without --print errors JsonModeRequiresPrint" {
    const argv = [_][]const u8{ "zts", "expert", "--mode", "json" };
    try testing.expectError(error.JsonModeRequiresPrint, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --mode json with --print sets json_mode" {
    const argv = [_][]const u8{ "zts", "expert", "--print", "x", "--mode", "json" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.json_mode);
    try testing.expect(flags.print != null);
}

test "parseExpertFlags: --mode=json inline form sets json_mode" {
    const argv = [_][]const u8{ "zts", "expert", "--print", "x", "--mode=json" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.json_mode);
}

test "parseExpertFlags: --mode bogus errors UnsupportedMode" {
    const argv = [_][]const u8{ "zts", "expert", "--print", "x", "--mode", "bogus" };
    try testing.expectError(error.UnsupportedMode, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --print + --yes combines policy with print" {
    const argv = [_][]const u8{ "zts", "expert", "--print", "hello", "--yes" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(loop.ApprovalPolicy.auto_approve, flags.policy.?);
    try testing.expect(flags.print != null);
    try testing.expectEqualStrings("hello", flags.print.?);
}

test "parseExpertFlags: --continue sets resume_latest like --resume" {
    const argv = [_][]const u8{ "zts", "expert", "--continue" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(true, flags.resume_latest);
    try testing.expect(flags.fork_session_id == null);
}

test "parseExpertFlags: --fork two-argv form captures id" {
    const argv = [_][]const u8{ "zts", "expert", "--fork", "abc123" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.fork_session_id != null);
    try testing.expectEqualStrings("abc123", flags.fork_session_id.?);
    try testing.expectEqual(false, flags.resume_latest);
}

test "parseExpertFlags: --fork=id inline form captures id" {
    const argv = [_][]const u8{ "zts", "expert", "--fork=xyz" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqualStrings("xyz", flags.fork_session_id.?);
}

test "parseExpertFlags: --fork without value errors MissingForkSessionId" {
    const argv = [_][]const u8{ "zts", "expert", "--fork" };
    try testing.expectError(error.MissingForkSessionId, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --fork + --resume errors MutuallyExclusiveForkFlags" {
    const argv = [_][]const u8{ "zts", "expert", "--fork", "x", "--resume" };
    try testing.expectError(error.MutuallyExclusiveForkFlags, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --fork + --session-id errors MutuallyExclusiveForkFlags" {
    const argv = [_][]const u8{ "zts", "expert", "--fork", "x", "--session-id", "y" };
    try testing.expectError(error.MutuallyExclusiveForkFlags, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --tools minimal sets preset" {
    const argv = [_][]const u8{ "zts", "expert", "--tools", "minimal" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(ToolsPreset.minimal, flags.tools_preset);
}

test "parseExpertFlags: --tools=full sets preset" {
    const argv = [_][]const u8{ "zts", "expert", "--tools=full" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(ToolsPreset.full, flags.tools_preset);
}

test "parseExpertFlags: --tools without value errors MissingToolsPreset" {
    const argv = [_][]const u8{ "zts", "expert", "--tools" };
    try testing.expectError(error.MissingToolsPreset, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --tools bad-value errors UnsupportedToolsPreset" {
    const argv = [_][]const u8{ "zts", "expert", "--tools", "quantum" };
    try testing.expectError(error.UnsupportedToolsPreset, parseExpertFlags(argv[0..]));
}

test "buildRegistry + dispatchLine end-to-end against every tool" {
    var reg = try buildRegistry(testing.allocator);
    defer reg.deinit(testing.allocator);

    var meta_outcome = try repl.dispatchLine(testing.allocator, &reg, "zts_expert_meta");
    try expectOkContains(&meta_outcome, testing.allocator, "\"compiler_version\"");

    var rule_outcome = try repl.dispatchLine(testing.allocator, &reg, "zts_expert_describe_rule ZTS303");
    try expectOkContains(&rule_outcome, testing.allocator, "\"ZTS303\"");

    var search_outcome = try repl.dispatchLine(testing.allocator, &reg, "zts_expert_search result");
    try expectOkContains(&search_outcome, testing.allocator, "\"code\":");
}

test "parseExpertFlags: --goal sets goals csv" {
    const argv = [_][]const u8{ "zts", "expert", "--handler", "handler.ts", "--goal", "no_secret_leakage,injection_safe" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqualStrings("no_secret_leakage,injection_safe", flags.goals.?);
    try testing.expectEqualStrings("handler.ts", flags.handler.?);
}

test "parseExpertFlags: --goal= and --handler= attached forms" {
    const argv = [_][]const u8{ "zts", "expert", "--handler=h.ts", "--goal=no_secret_leakage" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqualStrings("no_secret_leakage", flags.goals.?);
    try testing.expectEqualStrings("h.ts", flags.handler.?);
}

test "parseExpertFlags: --max-iters parses a positive integer" {
    const argv = [_][]const u8{ "zts", "expert", "--handler", "h.ts", "--goal", "no_secret_leakage", "--max-iters", "12" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqual(@as(u32, 12), flags.max_iters.?);
}

test "parseExpertFlags: --max-iters rejects zero" {
    const argv = [_][]const u8{ "zts", "expert", "--max-iters", "0" };
    try testing.expectError(error.InvalidMaxIters, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --max-iters rejects non-numeric" {
    const argv = [_][]const u8{ "zts", "expert", "--max-iters", "abc" };
    try testing.expectError(error.InvalidMaxIters, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --model <id> two-argv form captures the canonical id" {
    const argv = [_][]const u8{ "zts", "expert", "--model", "claude-haiku-4-5-20251001" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.model != null);
    try testing.expectEqualStrings("claude-haiku-4-5-20251001", flags.model.?);
}

test "parseExpertFlags: --model=<id> inline form captures the canonical id" {
    const argv = [_][]const u8{ "zts", "expert", "--model=claude-sonnet-4-6" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.model != null);
    try testing.expectEqualStrings("claude-sonnet-4-6", flags.model.?);
}

test "parseExpertFlags: --model accepts the registered OpenAI default" {
    const argv = [_][]const u8{ "zts", "expert", "--model", "gpt-4o-mini" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expectEqualStrings("gpt-4o-mini", flags.model.?);
}

test "parseExpertFlags: --model defaults to null when absent" {
    const argv = [_][]const u8{ "zts", "expert" };
    const flags = try parseExpertFlags(argv[0..]);
    try testing.expect(flags.model == null);
}

test "parseExpertFlags: public provider names map to internal adapters" {
    const local = try parseExpertFlags(&.{ "--provider", "local" });
    try testing.expectEqual(models_registry.Provider.local, local.provider.?);
    const claude = try parseExpertFlags(&.{"--provider=claude"});
    try testing.expectEqual(models_registry.Provider.anthropic, claude.provider.?);
    const openai = try parseExpertFlags(&.{ "--provider", "openai" });
    try testing.expectEqual(models_registry.Provider.openai, openai.provider.?);
}

test "parseExpertFlags: provider rejects missing and unsupported values" {
    try testing.expectError(error.MissingProviderValue, parseExpertFlags(&.{"--provider"}));
    try testing.expectError(error.UnsupportedProvider, parseExpertFlags(&.{"--provider=anthropic"}));
}

test "parseExpertFlags: compiler-only goal rejects provider and model flags" {
    try testing.expectError(error.GoalConflictsWithProviderOrModel, parseExpertFlags(&.{
        "--goal", "pure", "--handler", "handler.ts", "--provider", "local",
    }));
    try testing.expectError(error.GoalConflictsWithProviderOrModel, parseExpertFlags(&.{
        "--goal", "pure", "--handler", "handler.ts", "--model", "LiquidAI/LFM2.5-2.6B-MLX-8bit",
    }));
}

test "parseExpertFlags: --model without a value errors MissingModelValue" {
    const argv = [_][]const u8{ "zts", "expert", "--model" };
    try testing.expectError(error.MissingModelValue, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --model with an unknown id errors UnknownModel" {
    const argv = [_][]const u8{ "zts", "expert", "--model", "gpt-9-turbo" };
    try testing.expectError(error.UnknownModel, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --model uses exact ids for specialized OpenAI models" {
    const argv = [_][]const u8{ "zts", "expert", "--model", "gpt-4o-mini-search-preview" };
    try testing.expectError(error.UnknownModel, parseExpertFlags(argv[0..]));
}

test "modeErrorMessage explains provider mismatch without provider payloads" {
    const message = modeErrorMessage(error.ProviderMismatch).?;
    try testing.expect(std.mem.indexOf(u8, message, "model IDs do not switch providers") != null);
    try testing.expect(std.mem.indexOf(u8, message, "key") == null);
    try testing.expect(modeErrorMessage(error.OutOfMemory) == null);
}

test "modeErrorMessage gives actionable project instruction size guidance" {
    const message = modeErrorMessage(error.ProjectInstructionsTooLarge).?;
    try testing.expect(std.mem.indexOf(u8, message, "AGENTS.md/CLAUDE.md") != null);
    try testing.expect(std.mem.indexOf(u8, message, "48 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, message, "reduce") != null);
}

test "parseExpertFlags: --goal without --handler is rejected" {
    const argv = [_][]const u8{ "zts", "expert", "--goal", "no_secret_leakage" };
    try testing.expectError(error.GoalRequiresHandler, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --goal conflicts with --print" {
    const argv = [_][]const u8{ "zts", "expert", "--handler", "h.ts", "--goal", "no_secret_leakage", "--print", "hi" };
    try testing.expectError(error.GoalConflictsWithPrintOrRpc, parseExpertFlags(argv[0..]));
}

test "parseExpertFlags: --goal conflicts with --mode rpc" {
    const argv = [_][]const u8{ "zts", "expert", "--handler", "h.ts", "--goal", "no_secret_leakage", "--mode", "rpc" };
    try testing.expectError(error.GoalConflictsWithPrintOrRpc, parseExpertFlags(argv[0..]));
}

test "splitCsv trims whitespace and drops empty entries" {
    const parts = try splitCsv(testing.allocator, " a , b,, c ");
    defer {
        for (parts) |p| testing.allocator.free(p);
        testing.allocator.free(parts);
    }
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("a", parts[0]);
    try testing.expectEqualStrings("b", parts[1]);
    try testing.expectEqualStrings("c", parts[2]);
}

test "every registered tool is documented in the expert persona" {
    // The persona is the model's map of the catalog. A tool absent from it is
    // one the model has to guess at. `workspace_gen_tests` was absent until
    // this gate existed.
    const persona_text = @import("expert_persona.zig").prologue_text_for_test;
    inline for (comptime std.enums.values(Bundle)) |bundle| {
        for (bundleTools(bundle)) |tool| {
            std.testing.expect(std.mem.indexOf(u8, persona_text, tool.name) != null) catch |err| {
                std.debug.print("expert persona does not document `{s}`\n", .{tool.name});
                return err;
            };
        }
    }
}

test "the bundles partition the catalog with no tool in two of them" {
    var seen: usize = 0;
    inline for (comptime std.enums.values(Bundle)) |bundle| {
        seen += bundleTools(bundle).len;
    }
    var reg = try buildRegistry(std.testing.allocator);
    defer reg.deinit(std.testing.allocator);
    // `register` rejects a duplicate name, so an equal count proves each tool
    // appears in exactly one bundle.
    try std.testing.expectEqual(seen, reg.count());
}

test "an analyze tool may not take a workspace path" {
    // `ToolEffect` is documented as the STRONGEST observable effect, so a tool
    // that reads a path the caller names is `read_workspace`, not `analyze`.
    // Seventeen of them claimed `analyze`; today that is only a labelling
    // error, because both are allowed on all three surfaces, but the enum
    // exists so a future surface can deny workspace reads, and those
    // seventeen would have slipped through.
    const path_keys = [_][]const u8{ "\"path\"", "\"paths\"", "\"file\"", "\"before\"", "\"after\"", "\"handler_path\"" };
    inline for (comptime std.enums.values(Bundle)) |bundle| {
        for (bundleTools(bundle)) |tool| {
            if (tool.effect != .analyze) continue;
            for (path_keys) |key| {
                if (std.mem.indexOf(u8, tool.input_schema, key) != null) {
                    std.debug.print(
                        "tool `{s}` declares effect .analyze but takes {s} in its input schema\n",
                        .{ tool.name, key },
                    );
                    return error.EffectUnderstated;
                }
            }
        }
    }
}
