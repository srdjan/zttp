//! Expert session wrapper around `loop.runTurn`. Launch identity is resolved
//! before any backend is constructed, then the provider-specific client stays
//! behind one tagged union for the lifetime of the process.
//!
//! The session owns a long-lived `Transcript` that grows across turns
//! plus allocator-owned provider configuration whose bytes must outlive a
//! client request.
//! `runOneTurn` drives one pass through the loop driver, then renders
//! the latest appended transcript entry to an owned `[]u8` the caller
//! frees. Rendering the whole transcript per turn would re-print
//! history on every submission.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const zts = @import("zts");
const loop = @import("loop.zig");
const turn = @import("turn.zig");
const transcript_mod = @import("transcript.zig");
const registry_mod = @import("registry/registry.zig");
const anthropic_client = @import("providers/anthropic/client.zig");
const tools_schema = @import("providers/anthropic/tools_schema.zig");
const openai_client = @import("providers/openai/client.zig");
const local_client = @import("providers/local/client.zig");
const deepseek_client = @import("providers/deepseek/client.zig");
const model_request = @import("providers/model_request.zig");
const compaction = @import("compaction.zig");
const context_budget = @import("context_budget.zig");
const chat_completions = @import("providers/chat_completions.zig");
const models_registry = @import("providers/models.zig");
const provider_selection = @import("providers/selection.zig");
const expert_persona = @import("expert_persona.zig");
const zts_cli = @import("zts_cli");
const expert_meta = zts_cli.expert_meta;
const session_id_mod = @import("session/session_id.zig");
const session_paths = @import("session/paths.zig");
const session_events = @import("session/events.zig");
const persister = @import("session/persister.zig");
const reconstructor = @import("session/reconstructor.zig");
const project_context = @import("context/project_context.zig");
const expert_workflow = @import("expert_workflow.zig");

const Registry = registry_mod.Registry;
const Transcript = transcript_mod.Transcript;

pub const Provider = models_registry.Provider;

pub const BackendDescriptor = struct {
    auth_label: []const u8,
    provider_label: []const u8,
};

pub const SessionConfig = struct {
    /// Internal compiler-only lane. It may persist compiler events but never
    /// constructs or checks a model transport.
    model_free: bool = false,
    no_session: bool = false,
    no_persist_tool_output: bool = false,
    /// Skip AGENTS.md / CLAUDE.md project-context loading. Persona is
    /// unchanged; only the appended read-only project-context section is
    /// suppressed.
    no_context_files: bool = false,
    /// Explicit session id. If both this and `resume_latest` are null/false,
    /// a fresh id is generated on init.
    session_id: ?[]const u8 = null,
    /// Load the newest session for this cwd. Mutually exclusive with
    /// `session_id`.
    resume_latest: bool = false,
    /// Fork from the given session id: copy its transcript into a new session
    /// with `parent_id` pointing to the source. Mutually exclusive with
    /// `resume_latest` and `session_id`.
    fork_session_id: ?[]const u8 = null,
    /// Launch-scoped provider override. Null restores a persisted identity or
    /// selects the product default for a new model-mediated session.
    provider: ?Provider = null,
    /// `--model <id>` launch override (a canonical static registry id, so it
    /// outlives the session). Applied once here so every entry point inherits
    /// it; null leaves the compile-time default in place.
    model: ?[]const u8 = null,
    /// Approval policy to store in meta.json so --resume can restore it.
    /// The tag name string ("ask", "auto_approve", "auto_reject") is stored
    /// rather than the enum so events.zig stays free of loop.zig imports.
    approval_policy_tag: ?[]const u8 = null,
};

const stub_reply_text =
    "expert offline: no live model backend configured; set ANTHROPIC_API_KEY to enable expert mode";

/// Deterministic internal client used by compiler-only and unit-test paths.
const StubClient = struct {
    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        _ = ctx;
        _ = arena;
        _ = transcript;
        _ = extra_user_text;
        return .{ .reply = .{ .response = .{ .final_text = stub_reply_text } } };
    }

    fn asClient(self: *StubClient) loop.ModelClient {
        return .{
            .context = self,
            .request_fn = requestFn,
        };
    }
};

const Backend = union(enum) {
    stub: StubClient,
    local: local_client.Client,
    anthropic: anthropic_client.Client,
    openai: openai_client.Client,
    deepseek: deepseek_client.Client,
};

fn configWithModel(config: anytype, model: *const models_registry.Model) @TypeOf(config) {
    var next = config;
    next.model = model.id;
    next.max_tokens = model.request_policy.max_output_tokens;
    return next;
}

fn modelConfigMatches(
    model_id: []const u8,
    max_tokens: u32,
    model: *const models_registry.Model,
) bool {
    return std.mem.eql(u8, model_id, model.id) and
        max_tokens == model.request_policy.max_output_tokens;
}

/// Running per-session metrics, folded one turn at a time and emitted as a
/// `session_summary` event at session close. Keyed on the `verified_patch`
/// signal (`TurnResult.applied_edit`), not `turn_end`, so a plain-text turn
/// such as a clarifying question is counted as a turn without being mistaken
/// for an applied edit. See STRATEGY.md for the three staked metrics.
pub const SessionMetrics = struct {
    turn_count: u32 = 0,
    total_roundtrips: u32 = 0,
    verified_patch_count: u32 = 0,
    round_trips_to_first_green: u32 = 0,
    proven_properties: u32 = 0,
    tracked_properties: u32 = 0,
    workflow_hint_count: u32 = 0,
    high_confidence_workflow_hint_count: u32 = 0,
    first_draft_veto_pass_count: u32 = 0,
    veto_retry_count: u32 = 0,
    tool_call_count: u32 = 0,
    /// Edits that landed via the compiler-authored repair lane with no model
    /// round-trip. The numerator of "% of edits that became model-free"
    /// (denominator: verified_patch_count).
    compiler_authored_apply_count: u32 = 0,
    last_workflow_kind: expert_workflow.TaskKind = .unknown,
    last_workflow_confidence: expert_workflow.Confidence = .low,
    last_outcome: session_events.TurnEndReason = .approved,

    /// Fold one completed turn's result into the running totals.
    pub fn record(self: *SessionMetrics, result: loop.TurnResult) void {
        self.turn_count += 1;
        self.total_roundtrips +|= result.roundtrips;
        self.last_outcome = result.end_reason;
        self.last_workflow_kind = result.workflow_kind;
        self.last_workflow_confidence = result.workflow_confidence;
        if (result.workflow_hint_injected) {
            self.workflow_hint_count += 1;
            if (result.workflow_confidence == .high) {
                self.high_confidence_workflow_hint_count += 1;
            }
        }
        if (result.first_draft_veto_pass) self.first_draft_veto_pass_count += 1;
        self.veto_retry_count +|= result.veto_retry_count;
        self.tool_call_count +|= result.tool_call_count;
        if (result.compiler_authored_apply) self.compiler_authored_apply_count += 1;
        if (result.applied_edit) {
            if (self.verified_patch_count == 0) {
                // Round-trips accumulated up to and including the first verified
                // edit - "round-trips to first green proof".
                self.round_trips_to_first_green = self.total_roundtrips;
            }
            self.verified_patch_count += 1;
            self.proven_properties = result.proven_guarantees;
            self.tracked_properties = result.tracked_guarantees;
        }
    }

    pub fn summary(self: SessionMetrics) session_events.SessionSummary {
        return .{
            .turn_count = self.turn_count,
            .total_roundtrips = self.total_roundtrips,
            .verified_patch_count = self.verified_patch_count,
            .reached_proof = self.verified_patch_count > 0,
            .round_trips_to_first_green = self.round_trips_to_first_green,
            .proven_properties = self.proven_properties,
            .tracked_properties = self.tracked_properties,
            .workflow_hint_count = self.workflow_hint_count,
            .high_confidence_workflow_hint_count = self.high_confidence_workflow_hint_count,
            .first_draft_veto_pass_count = self.first_draft_veto_pass_count,
            .veto_retry_count = self.veto_retry_count,
            .tool_call_count = self.tool_call_count,
            .compiler_authored_apply_count = self.compiler_authored_apply_count,
            .last_workflow_kind = expert_workflow.taskKindName(self.last_workflow_kind),
            .last_workflow_confidence = expert_workflow.confidenceName(self.last_workflow_confidence),
            .final_outcome = self.last_outcome,
        };
    }
};

/// Where to send OpenAI-shaped requests when the target is not OpenAI.
///
pub const OpenAiEndpoint = struct {
    base_url: []const u8,
};

/// Read an endpoint override out of the environment, or null when
/// `ZTS_OPENAI_BASE_URL` is unset - which is the hosted path, unchanged.
///
/// The slices borrow from the process environment, which outlives any session,
/// and `initOpenAI` copies them anyway so one ownership rule covers both the
/// env source and a caller-supplied literal.
pub fn openAiEndpointFromEnv() !?OpenAiEndpoint {
    if (envVar("ZTS_OPENAI_MODEL") != null) return error.UnsupportedOpenAIModelOverride;
    const base_url = envVar("ZTS_OPENAI_BASE_URL") orelse return null;
    return .{ .base_url = base_url };
}

/// Where the resolved session will send handler source.
///
/// A `zttp expert` turn puts source on the wire whenever the model reads a
/// file, so a user is owed the destination before the first turn rather than
/// after. The banner reads this from the constructed backend instead of
/// re-deriving identity from credentials or other environment state.
pub const Destination = union(enum) {
    /// Internal stub backend used by compiler-only and test paths.
    offline,
    local: []const u8,
    anthropic,
    openai_hosted,
    /// `ZTS_OPENAI_BASE_URL` is set. Carries the value as given.
    openai_custom: []const u8,
    /// DeepSeek, at its default root or at a `DEEPSEEK_BASE_URL` override.
    /// Carries the value as given. The endpoint policy requires HTTPS, so this
    /// is always a remote host.
    deepseek: []const u8,

    /// True when the destination is on this machine, so source never reaches a
    /// third party. Host-form check only: it reports what the user configured,
    /// not what DNS would resolve to.
    pub fn isLocal(self: Destination) bool {
        return switch (self) {
            .offline, .local => true,
            .anthropic, .openai_hosted, .deepseek => false,
            .openai_custom => |url| containsAny(url, &.{ "//127.0.0.1", "//localhost", "//[::1]", "//0.0.0.0" }),
        };
    }
};

pub fn destinationForSession(session: *const AgentSession) Destination {
    return switch (session.backend) {
        .stub => .offline,
        .local => |client| .{ .local = client.config.base_url },
        .anthropic => .anthropic,
        .openai => |client| if (std.mem.eql(u8, client.config.base_url, openai_client.default_base_url))
            .openai_hosted
        else
            .{ .openai_custom = client.config.base_url },
        .deepseek => |client| .{ .deepseek = client.config.base_url },
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

pub const AgentSession = struct {
    transcript: Transcript = .{},
    backend: Backend = .{ .stub = .{} },
    /// Allocator-owned copy of the system prompt bytes backing the
    /// Anthropic client's Config. Null for the stub path.
    system_prompt_owned: ?[]u8 = null,
    tools_json_owned: ?[]u8 = null,
    /// Set only when `initOpenAI` was given an endpoint override; the client's
    /// Config borrows these, so the session outlives the caller's buffers the
    /// same way it does for the prompt.
    base_url_owned: ?[]u8 = null,
    /// Resolved launch identity. This is authoritative for UI and persistence,
    /// including test sessions that inject a model client separately.
    resolved_provider: ?Provider = null,
    resolved_model: ?*const models_registry.Model = null,
    identity_override_disclosed: bool = false,

    session_id: ?[]u8 = null,
    session_dir: ?[]u8 = null,
    events_path: ?[]u8 = null,
    meta_path: ?[]u8 = null,
    persist_opts: persister.AppendOptions = .{},
    /// /resume sets this; the first `runOneTurn` after resume passes
    /// `replay_mode = true` to the loop and then clears the flag.
    replay_next_turn: bool = false,
    /// Cursor into `transcript.entries`. Entries from this index forward
    /// are the ones that need to be persisted next.
    last_persisted_len: usize = 0,
    /// Running total of tokens consumed by all turns in this session.
    token_totals: turn.Usage = .{},
    /// Summarization usage is also included in `token_totals` for cost
    /// accounting, but remains separately observable from normal generation.
    summary_token_totals: turn.Usage = .{},
    summary_attempt_count: u64 = 0,
    /// Per-session expert metrics, folded each turn and emitted as a
    /// `session_summary` event by `writeSessionSummary` at session close.
    metrics: SessionMetrics = .{},
    /// Approval policy read from the resumed session's meta.json. Non-null only
    /// after a --resume when the source session had an approval_policy stored.
    /// app.zig applies it as the session default when no flag override is present.
    stored_approval_policy: ?loop.ApprovalPolicy = null,

    pub fn initStub() AgentSession {
        return .{};
    }

    /// Constructs a session whose backend is a real Anthropic client.
    /// Dupes the system prompt so the caller's buffer can be freed
    /// independently. Dupes the API key for the same reason.
    pub fn initAnthropic(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        system_prompt: []const u8,
        tools_json: ?[]const u8,
    ) !AgentSession {
        const prompt_owned = try allocator.dupe(u8, system_prompt);
        errdefer allocator.free(prompt_owned);
        const key_owned = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_owned);
        const tools_owned = if (tools_json) |json|
            try allocator.dupe(u8, json)
        else
            null;
        errdefer if (tools_owned) |json| allocator.free(json);
        const model = models_registry.defaultForProvider(.anthropic);
        return .{
            .backend = .{ .anthropic = anthropic_client.Client.init(.{
                .api_key = key_owned,
                .system_prompt = prompt_owned,
                .tools_json = tools_owned,
                .model = model.id,
                .max_tokens = model.request_policy.max_output_tokens,
            }) },
            .system_prompt_owned = prompt_owned,
            .tools_json_owned = tools_owned,
            .resolved_provider = .anthropic,
            .resolved_model = model,
        };
    }

    pub fn initLocal(
        allocator: std.mem.Allocator,
        system_prompt: []const u8,
        tools_json: ?[]const u8,
        base_url: []const u8,
    ) !AgentSession {
        const prompt_owned = try allocator.dupe(u8, system_prompt);
        errdefer allocator.free(prompt_owned);
        const tools_owned = if (tools_json) |json| try allocator.dupe(u8, json) else null;
        errdefer if (tools_owned) |json| allocator.free(json);
        const base_owned = try allocator.dupe(u8, base_url);
        errdefer allocator.free(base_owned);
        const model = models_registry.defaultForProvider(.local);
        return .{
            .backend = .{ .local = local_client.Client.init(.{
                .system_prompt = prompt_owned,
                .tools_json = tools_owned,
                .base_url = base_owned,
                .model = model.id,
                .max_tokens = model.request_policy.max_output_tokens,
            }) },
            .system_prompt_owned = prompt_owned,
            .tools_json_owned = tools_owned,
            .base_url_owned = base_owned,
            .resolved_provider = .local,
            .resolved_model = model,
        };
    }

    /// Constructs a session whose backend is a real OpenAI Responses-API
    /// streaming client. Same ownership contract as `initAnthropic`:
    /// api_key, system prompt, and tools_json are all duped so the caller's
    /// buffers can be freed independently. `tools_json` is the
    /// Responses-API tools array produced by `openai_client.writeToolsArray`.
    /// An endpoint override changes only the Responses API destination. The
    /// active provider's registry-selected model remains authoritative.
    pub fn initOpenAI(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        system_prompt: []const u8,
        tools_json: ?[]const u8,
        override: ?OpenAiEndpoint,
    ) !AgentSession {
        const prompt_owned = try allocator.dupe(u8, system_prompt);
        errdefer allocator.free(prompt_owned);
        const key_owned = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_owned);
        const tools_owned = if (tools_json) |json|
            try allocator.dupe(u8, json)
        else
            null;
        errdefer if (tools_owned) |json| allocator.free(json);

        const model = models_registry.defaultForProvider(.openai);
        var config = openai_client.Config{
            .api_key = key_owned,
            .system_prompt = prompt_owned,
            .tools_json = tools_owned,
            .model = model.id,
            .max_tokens = model.request_policy.max_output_tokens,
        };

        var base_url_owned: ?[]u8 = null;
        errdefer if (base_url_owned) |s| allocator.free(s);
        if (override) |ep| {
            base_url_owned = try allocator.dupe(u8, ep.base_url);
            config.base_url = base_url_owned.?;
        }

        return .{
            .backend = .{ .openai = openai_client.Client.init(config) },
            .system_prompt_owned = prompt_owned,
            .tools_json_owned = tools_owned,
            .base_url_owned = base_url_owned,
            .resolved_provider = .openai,
            .resolved_model = model,
        };
    }

    /// Constructs a session whose backend is a real DeepSeek Chat Completions
    /// client. Same ownership contract as `initAnthropic`, plus the base URL:
    /// an override is duped so the client's Config never borrows a caller
    /// buffer that could be freed first. `tools_json` is the OpenAI
    /// function-calling array produced by `deepseek_client.writeToolsArray`.
    pub fn initDeepSeek(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        system_prompt: []const u8,
        tools_json: ?[]const u8,
        base_url: []const u8,
    ) !AgentSession {
        const prompt_owned = try allocator.dupe(u8, system_prompt);
        errdefer allocator.free(prompt_owned);
        const key_owned = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_owned);
        const tools_owned = if (tools_json) |json|
            try allocator.dupe(u8, json)
        else
            null;
        errdefer if (tools_owned) |json| allocator.free(json);
        const base_owned = try allocator.dupe(u8, base_url);
        errdefer allocator.free(base_owned);

        const model = models_registry.defaultForProvider(.deepseek);
        return .{
            .backend = .{ .deepseek = deepseek_client.Client.init(.{
                .api_key = key_owned,
                .system_prompt = prompt_owned,
                .tools_json = tools_owned,
                .base_url = base_owned,
                .model = model.id,
                .max_tokens = model.request_policy.max_output_tokens,
            }) },
            .system_prompt_owned = prompt_owned,
            .tools_json_owned = tools_owned,
            .base_url_owned = base_owned,
            .resolved_provider = .deepseek,
            .resolved_model = model,
        };
    }

    pub fn deinit(self: *AgentSession, allocator: std.mem.Allocator) void {
        self.transcript.deinit(allocator);
        if (self.system_prompt_owned) |s| allocator.free(s);
        if (self.tools_json_owned) |json| allocator.free(json);
        if (self.base_url_owned) |s| allocator.free(s);
        if (self.session_id) |s| allocator.free(s);
        if (self.session_dir) |s| allocator.free(s);
        if (self.events_path) |s| allocator.free(s);
        if (self.meta_path) |s| allocator.free(s);
        switch (self.backend) {
            .stub => {},
            .local => {},
            .anthropic => |*c| allocator.free(c.config.api_key),
            .openai => |*c| allocator.free(c.config.api_key),
            .deepseek => |*c| allocator.free(c.config.api_key),
        }
    }

    pub fn modelClient(self: *AgentSession) loop.ModelClient {
        return switch (self.backend) {
            .stub => (&self.backend.stub).asClient(),
            .local => (&self.backend.local).asModelClient(),
            .anthropic => (&self.backend.anthropic).asModelClient(),
            .openai => (&self.backend.openai).asModelClient(),
            .deepseek => (&self.backend.deepseek).asModelClient(),
        };
    }

    pub fn summarizer(self: *AgentSession) ?compaction.Summarizer {
        if (self.backend == .stub) return null;
        return .{ .context = self, .summarize_fn = summarizeRequest };
    }

    fn summarizeRequest(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: compaction.SummaryRequest,
    ) anyerror!compaction.SummaryResponse {
        const self: *AgentSession = @ptrCast(@alignCast(context));
        var summary_transcript: transcript_mod.Transcript = .{};
        defer summary_transcript.deinit(arena);
        try summary_transcript.append(arena, .{ .user_text = request.user_prompt });

        const result = switch (self.backend) {
            .stub => return error.CompactionUnavailable,
            .local => |client| blk: {
                var summary_client = client;
                summary_client.config.system_prompt = request.system_prompt;
                summary_client.config.tools_json = null;
                summary_client.config.max_tokens = request.max_output_tokens;
                summary_client.config.purpose = .summarization;
                summary_client.config.cache_policy = .disabled;
                break :blk try summary_client.sendTurn(arena, &summary_transcript, null);
            },
            .anthropic => |client| blk: {
                var summary_client = client;
                summary_client.config.system_prompt = request.system_prompt;
                summary_client.config.tools_json = null;
                summary_client.config.max_tokens = request.max_output_tokens;
                summary_client.config.purpose = .summarization;
                summary_client.config.cache_policy = .disabled;
                break :blk try summary_client.sendTurn(arena, &summary_transcript, null);
            },
            .openai => |client| blk: {
                var summary_client = client;
                summary_client.config.system_prompt = request.system_prompt;
                summary_client.config.tools_json = null;
                summary_client.config.max_tokens = request.max_output_tokens;
                summary_client.config.purpose = .summarization;
                summary_client.config.cache_policy = .disabled;
                break :blk try summary_client.sendTurn(arena, &summary_transcript, null);
            },
            .deepseek => |client| blk: {
                var summary_client = client;
                summary_client.config.system_prompt = request.system_prompt;
                summary_client.config.tools_json = null;
                summary_client.config.max_tokens = request.max_output_tokens;
                summary_client.config.purpose = .summarization;
                summary_client.config.cache_policy = .disabled;
                break :blk try summary_client.sendTurn(arena, &summary_transcript, null);
            },
        };
        return .{ .response = result.reply.response, .usage = result.usage };
    }

    /// Returns the model id currently in use, or null for the stub backend.
    pub fn currentModel(self: *const AgentSession) ?[]const u8 {
        return if (self.resolved_model) |model| model.id else null;
    }

    pub fn activeProvider(self: *const AgentSession) ?Provider {
        return self.resolved_provider;
    }

    /// Single source of truth for the backend's display labels.
    pub fn backendDescriptor(self: *const AgentSession) BackendDescriptor {
        const provider_label = if (self.activeProvider()) |provider| provider.publicName() else "stub";
        const auth_label: []const u8 = switch (self.backend) {
            .stub => "stub",
            .local => "none",
            .anthropic, .openai, .deepseek => "api-key",
        };
        return .{ .auth_label = auth_label, .provider_label = provider_label };
    }

    /// Select an exact registry model for the active provider. Validation
    /// computes the complete next state before either config field changes.
    pub fn setModel(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        model_id: []const u8,
    ) !void {
        return self.setModelWithRestamp(allocator, model_id, restampSessionIdentity);
    }

    fn setModelWithRestamp(
        self: *AgentSession,
        allocator: std.mem.Allocator,
        model_id: []const u8,
        restamp_fn: anytype,
    ) !void {
        const provider = self.activeProvider() orelse return error.NoActiveProvider;
        const model = try models_registry.resolveForProvider(provider, model_id);
        const backend_matches = switch (self.backend) {
            .local => |client| modelConfigMatches(client.config.model, client.config.max_tokens, model),
            .anthropic => |client| modelConfigMatches(client.config.model, client.config.max_tokens, model),
            .openai => |client| modelConfigMatches(client.config.model, client.config.max_tokens, model),
            .deepseek => |client| modelConfigMatches(client.config.model, client.config.max_tokens, model),
            .stub => false,
        };
        if (backend_matches) {
            self.resolved_model = model;
            return;
        }
        // Persist the complete next identity before changing the live client.
        // A filesystem failure therefore leaves both the session and backend
        // on the previous model.
        try restamp_fn(allocator, self, provider, model.id);
        switch (self.backend) {
            .local => |*client| client.config = configWithModel(client.config, model),
            .anthropic => |*client| client.config = configWithModel(client.config, model),
            .openai => |*client| client.config = configWithModel(client.config, model),
            .deepseek => |*client| client.config = configWithModel(client.config, model),
            .stub => {},
        }
        self.resolved_model = model;
    }

    /// Append the per-session metrics row at session close. Best-effort and a
    /// no-op when the session is not persisted (no events path) or produced no
    /// turns, so calling it from a session-end path is always safe.
    pub fn writeSessionSummary(self: *AgentSession, allocator: std.mem.Allocator) void {
        if (self.metrics.turn_count == 0) return;
        const path = self.events_path orelse return;
        session_events.appendEvent(allocator, path, .{
            .session_summary = self.metrics.summary(),
        }) catch {};
    }
};

/// Resolve session identity, construct only that provider's backend, and,
/// unless `config.no_session` is true, materialize the on-disk session
/// directory and event persistence.
///
/// When `config.resume_latest` is set, the newest existing session for
/// this cwd is loaded and the transcript is replaced with a reconstruction
/// of its events log; the first subsequent turn runs in replay mode.
pub fn initFromEnvWithSessionConfig(
    allocator: std.mem.Allocator,
    registry: ?*const Registry,
    config: SessionConfig,
) !AgentSession {
    return initFromEnvWithPreparedResume(allocator, registry, config, null);
}

fn initFromEnvWithPreparedResume(
    allocator: std.mem.Allocator,
    registry: ?*const Registry,
    config: SessionConfig,
    prepared_resume: ?*const PreparedResume,
) !AgentSession {
    std.debug.assert(!(config.resume_latest and config.session_id != null));
    std.debug.assert(!(config.fork_session_id != null and config.resume_latest));
    std.debug.assert(!(config.fork_session_id != null and config.session_id != null));

    // Resolve the source session and read its identity before credential
    // validation, transport readiness, or any session-directory write.
    var resumed = false;
    var resolved_resume_id: ?[]u8 = null;
    defer if (resolved_resume_id) |id| allocator.free(id);
    if (config.resume_latest) {
        if (prepared_resume) |prepared| {
            resumed = true;
            resolved_resume_id = try allocator.dupe(u8, prepared.session_id);
        } else {
            const root = try session_paths.sessionRoot(allocator);
            defer allocator.free(root);
            const hash = try session_paths.cwdHashFull(allocator);
            const entries = try session_paths.listSessions(allocator, root, hash[0..]);
            defer {
                for (entries) |*entry| entry.deinit(allocator);
                allocator.free(entries);
            }
            if (entries.len > 0) {
                resumed = true;
                resolved_resume_id = try allocator.dupe(u8, entries[0].session_id);
            }
        }
    }

    var owned_stored_meta: ?session_events.Meta = null;
    defer if (owned_stored_meta) |*meta| session_events.freeMeta(allocator, meta);
    var stored_meta: ?*const session_events.Meta = null;
    if (resolved_resume_id) |source_id| {
        if (prepared_resume) |prepared| {
            stored_meta = &prepared.meta;
        } else {
            owned_stored_meta = try readSessionMeta(allocator, source_id);
            if (owned_stored_meta) |*meta| stored_meta = meta;
        }
    } else if (config.session_id) |source_id| {
        owned_stored_meta = readSessionMeta(allocator, source_id) catch |err| switch (err) {
            error.FileNotFound => if (try sessionEventsExist(allocator, source_id))
                return error.MissingSessionMetadata
            else
                null,
            else => return err,
        };
        if (owned_stored_meta != null) {
            if (owned_stored_meta) |*meta| stored_meta = meta;
            resumed = true;
            resolved_resume_id = try allocator.dupe(u8, source_id);
        }
    } else if (config.fork_session_id) |source_id| {
        owned_stored_meta = try readSessionMeta(allocator, source_id);
        if (owned_stored_meta) |*meta| stored_meta = meta;
    }

    const resolution: ?provider_selection.Resolution = if (config.model_free)
        null
    else
        try provider_selection.resolve(.{
            .launch_provider = config.provider,
            .launch_model = config.model,
            .stored = if (stored_meta) |meta| .{
                .provider = meta.provider,
                .model = meta.model,
            } else null,
        });

    // Load project context (AGENTS.md / CLAUDE.md) from cwd upward unless
    // the caller disabled it. Instruction failures propagate: launching with
    // an incomplete project contract would be less safe than refusing.
    const project_ctx: ?[]u8 = if (config.no_context_files)
        null
    else
        try project_context.loadFromCwd(allocator);
    defer if (project_ctx) |p| allocator.free(p);

    var session = blk: {
        if (config.model_free) break :blk AgentSession.initStub();
        // A null registry is the test-only seam for sessions that exercise
        // persistence and context loading without issuing model requests.
        const active_registry = registry orelse break :blk AgentSession.initStub();
        const resolved = resolution orelse return error.NoActiveProvider;
        switch (resolved.provider) {
            .local => {
                const base_url = local_client.effectiveBaseUrl(envVar("ZTTP_MLX_BASE_URL"));
                try local_client.checkReadiness(allocator, base_url, resolved.model.id);
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildLocalToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initLocal(allocator, system_prompt, tools_json, base_url);
            },
            .anthropic => {
                const api_key = envVar("ANTHROPIC_API_KEY") orelse return error.MissingAnthropicCredential;
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initAnthropic(allocator, api_key, system_prompt, tools_json);
            },
            .openai => {
                const api_key = envVar("OPENAI_API_KEY") orelse return error.MissingOpenAICredential;
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildOpenAIToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initOpenAI(
                    allocator,
                    api_key,
                    system_prompt,
                    tools_json,
                    try openAiEndpointFromEnv(),
                );
            },
            .deepseek => {
                const api_key = envVar("DEEPSEEK_API_KEY") orelse return error.MissingDeepSeekCredential;
                const base_url = deepseek_client.effectiveBaseUrl(envVar("DEEPSEEK_BASE_URL"));
                try deepseek_client.validateBaseUrl(base_url);
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildDeepSeekToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initDeepSeek(
                    allocator,
                    api_key,
                    system_prompt,
                    tools_json,
                    base_url,
                );
            },
        }
    };
    errdefer session.deinit(allocator);

    if (resolution) |resolved| {
        session.resolved_provider = resolved.provider;
        session.resolved_model = resolved.model;
        session.identity_override_disclosed = resolved.provider_overridden or resolved.model_overridden;
    }

    // Apply a --model launch override once, here, so every caller
    // (interactive REPL, autoloop, --print, --rpc) inherits it without each
    // having to remember a separate apply step. Also covers no_session sessions.
    if (resolution) |resolved| {
        switch (session.backend) {
            .stub => {},
            else => try session.setModel(allocator, resolved.model.id),
        }
    }

    if (config.no_session) return session;

    session.persist_opts = .{ .no_persist_tool_output = config.no_persist_tool_output };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const realpath = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(realpath);

    const sid: []u8 = pick: {
        if (config.session_id) |id| break :pick try allocator.dupe(u8, id);
        if (resolved_resume_id) |id| break :pick try allocator.dupe(u8, id);
        break :pick try session_id_mod.generate(allocator);
    };
    session.session_id = sid;

    const dir = try session_paths.sessionDir(allocator, sid);
    session.session_dir = dir;
    try session_paths.writeWorkspacePointer(allocator, dir, realpath);

    session.events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    session.meta_path = try std.fs.path.join(allocator, &.{ dir, "meta.json" });
    const events_path = session.events_path orelse return error.MissingSessionPath;
    const meta_path = session.meta_path orelse return error.MissingSessionPath;
    // A successfully created session is resumable even before its first turn.
    // Forking an empty transcript likewise needs a real, empty event log.
    if (!resumed) try zts.file_io.writeFile(allocator, events_path, "");

    const current_hash_bytes = expert_meta.compute().policy_hash;
    const current_hash = current_hash_bytes[0..];
    const persisted_provider = if (resolution) |resolved|
        resolved.provider.publicName()
    else if (stored_meta) |meta|
        meta.provider
    else
        null;
    const persisted_model = if (resolution) |resolved|
        resolved.model.id
    else if (stored_meta) |meta|
        meta.model
    else
        null;

    if (resumed) {
        var tr = try reconstructor.reconstructTranscript(allocator, events_path, null);
        session.transcript.deinit(allocator);
        session.transcript = tr;
        session.last_persisted_len = tr.len();
        session.replay_next_turn = true;

        // Detect policy drift: if the resumed session's meta.json stamps a
        // different hash than the current binary, prepend a system_note to
        // the transcript so both the model and the user see the mismatch.
        const resume_meta = stored_meta orelse return error.MissingSessionMetadata;
        try injectDriftNote(allocator, &session, current_hash, resume_meta);
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = resume_meta.session_id,
            .workspace_realpath = resume_meta.workspace_realpath,
            .created_at_unix_ms = resume_meta.created_at_unix_ms,
            .parent_id = resume_meta.parent_id,
            .policy_hash = current_hash,
            .approval_policy = resume_meta.approval_policy,
            .provider = persisted_provider,
            .model = persisted_model,
        });
    } else if (config.fork_session_id) |fork_id| {
        const src_dir = try session_paths.sessionDir(allocator, fork_id);
        defer allocator.free(src_dir);
        const src_events = try std.fs.path.join(allocator, &.{ src_dir, "events.jsonl" });
        defer allocator.free(src_events);
        const tr = try reconstructor.reconstructTranscript(allocator, src_events, null);
        session.transcript.deinit(allocator);
        session.transcript = tr;
        try session_events.copyJournal(allocator, src_events, events_path);
        session.last_persisted_len = session.transcript.len();
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = sid,
            .workspace_realpath = realpath,
            .created_at_unix_ms = nowUnixMs(),
            .parent_id = fork_id,
            .policy_hash = current_hash,
            .approval_policy = config.approval_policy_tag,
            .provider = persisted_provider,
            .model = persisted_model,
        });
    } else {
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = sid,
            .workspace_realpath = realpath,
            .created_at_unix_ms = nowUnixMs(),
            .policy_hash = current_hash,
            .approval_policy = config.approval_policy_tag,
            .provider = persisted_provider,
            .model = persisted_model,
        });
    }

    return session;
}

fn readSessionMeta(allocator: std.mem.Allocator, session_id: []const u8) !session_events.Meta {
    const source_dir = try session_paths.sessionDir(allocator, session_id);
    defer allocator.free(source_dir);
    const source_meta_path = try std.fs.path.join(allocator, &.{ source_dir, "meta.json" });
    defer allocator.free(source_meta_path);
    return try session_events.readMeta(allocator, source_meta_path);
}

fn sessionEventsExist(allocator: std.mem.Allocator, session_id: []const u8) !bool {
    const source_dir = try session_paths.sessionDir(allocator, session_id);
    defer allocator.free(source_dir);
    const events_path = try std.fs.path.join(allocator, &.{ source_dir, "events.jsonl" });
    defer allocator.free(events_path);
    return zts.file_io.fileExists(allocator, events_path);
}

/// Compare the resumed session's stored policy_hash against the current
/// binary's hash. On mismatch (or on a pre-Phase-2 session with no stamped
/// hash), append a `system_note` to the transcript so the model is aware the
/// reasoning in prior turns was produced under a different rule set.
pub const POLICY_DRIFT_PREFIX = "[policy drift]";

/// Token budget reserved for everything in a request that is NOT the transcript:
/// the system prompt (persona + project context + witnesses) and the tools
/// schema. Added to the transcript estimate so compaction triggers before the
/// assembled request actually overflows the model's context window.
const non_transcript_token_allowance: usize = 20_000;

/// Rough estimate of how many tokens the current transcript would contribute to
/// the next request, plus a fixed allowance for the system prompt and tools.
/// Uses a discarding writer to count rendered bytes without allocating, then the
/// standard ~4-bytes-per-token approximation. Good enough to decide when to
/// compact; it is never treated as exact.
pub fn estimateContextTokens(session: *const AgentSession) usize {
    var scratch: [256]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&scratch);
    if (session.transcript.projection) |projection| {
        discarding.writer.writeAll(projection.summary) catch {};
    }
    const active_start = session.transcript.activeStartIndex() catch 0;
    for (session.transcript.entries.items[active_start..]) |*entry| {
        transcript_mod.renderPlain(&discarding.writer, entry) catch break;
    }
    const bytes: usize = @intCast(discarding.fullCount());
    return bytes / 4 + non_transcript_token_allowance;
}

/// Fraction of the active model's context window at which a session is
/// auto-compacted so a long conversation cannot dead-end on a 400 "prompt is too
/// long".
const compaction_threshold_pct: usize = 70;

/// The active model's context window in tokens, or a conservative default.
fn contextWindowTokens(session: *const AgentSession) usize {
    const provider = session.activeProvider() orelse return 200_000;
    if (session.currentModel()) |id| {
        if (models_registry.resolveForProvider(provider, id)) |model| {
            return model.capabilities.context_window_tokens;
        } else |_| {}
    }
    return models_registry.defaultForProvider(provider).capabilities.context_window_tokens;
}

/// Compact the session in place when the estimated context size reaches the
/// threshold for the active model's window; returns true if it compacted (the
/// caller can then surface a one-line notice). Lives here next to the estimate
/// and `compact` so every multi-turn surface gets the same proactive guard, not
/// just the interactive REPL. Compaction is local (summarizes the transcript
/// into one note), so this is cheap and never makes a model call.
pub fn maybeAutoCompact(allocator: std.mem.Allocator, session: *AgentSession) !bool {
    const window = contextWindowTokens(session);
    if (estimateContextTokens(session) * 100 < window * compaction_threshold_pct) return false;
    const msg = try compact(allocator, session);
    allocator.free(msg);
    return true;
}

/// The policy-drift `system_note` carried by a resumed transcript, if any. The
/// returned slice borrows from the transcript. Lets an interactive surface echo
/// the warning to the user instead of leaving it visible only to the model.
pub fn policyDriftNote(session: *const AgentSession) ?[]const u8 {
    for (session.transcript.entries.items) |entry| {
        switch (entry) {
            .system_note => |note| {
                if (std.mem.indexOf(u8, note, POLICY_DRIFT_PREFIX) != null) return note;
            },
            else => {},
        }
    }
    return null;
}

fn injectDriftNote(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    current_hash: []const u8,
    meta: *const session_events.Meta,
) !void {
    // Restore the stored approval policy (if any) so --resume inherits it.
    // The policy tag string is parsed back to the enum; unknown tags are
    // silently ignored so old sessions without the field do not break.
    if (meta.approval_policy) |tag| {
        if (std.mem.eql(u8, tag, "auto_approve")) {
            session.stored_approval_policy = .auto_approve;
        } else if (std.mem.eql(u8, tag, "auto_reject")) {
            session.stored_approval_policy = .auto_reject;
        } else if (std.mem.eql(u8, tag, "ask")) {
            session.stored_approval_policy = .ask;
        }
    }

    // Pre-Phase-2 sessions (no saved hash) and matching hashes both skip the
    // note; only the drift case appends + persists a system_note. All three
    // cases leave the transcript unchanged. The caller forward-stamps the
    // complete metadata once after this function returns.
    if (meta.policy_hash) |saved| {
        if (std.mem.eql(u8, saved, current_hash)) return;

        const note = try std.fmt.allocPrint(
            allocator,
            "{s} Resumed session was created under policy_hash {s} but the current binary is {s}. Prior rule citations in this transcript may be stale against today's compiler policy.\n",
            .{ POLICY_DRIFT_PREFIX, saved, current_hash },
        );
        errdefer allocator.free(note);
        try session.transcript.entries.append(allocator, .{ .system_note = note });

        if (session.events_path) |path| {
            try persister.appendEntry(
                allocator,
                path,
                session.transcript.entryIdAt(session.transcript.entries.items.len - 1),
                &session.transcript.entries.items[session.transcript.entries.items.len - 1],
                session.persist_opts,
            );
            session.last_persisted_len = session.transcript.len();
        }
    }
}

fn restampSessionIdentity(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    provider: Provider,
    model: []const u8,
) !void {
    const meta_path = session.meta_path orelse return;
    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);
    try session_events.writeMeta(allocator, meta_path, .{
        .session_id = meta.session_id,
        .workspace_realpath = meta.workspace_realpath,
        .created_at_unix_ms = meta.created_at_unix_ms,
        .parent_id = meta.parent_id,
        .policy_hash = meta.policy_hash,
        .approval_policy = meta.approval_policy,
        .provider = provider.publicName(),
        .model = model,
    });
}

fn envVar(name_z: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name_z) orelse return null;
    const value = std.mem.sliceTo(raw, 0);
    // Treat a set-but-blank variable as absent. An empty or whitespace-only
    // API key is never a legitimate credential, so callers (the `expert`
    // fail-fast and `initFromEnvWithSessionConfig`) should both fall through
    // to the missing-backend path rather than build a client that 401s on
    // first request. Trimming is also how a .env loader's accidental
    // padding (e.g. `KEY = "..."`) would otherwise sneak through.
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn nowUnixMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(@enumFromInt(@intFromEnum(std.posix.CLOCK.REALTIME)), &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn buildToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try tools_schema.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

fn buildOpenAIToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try openai_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

fn buildLocalToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try local_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

fn buildDeepSeekToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try deepseek_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

/// Runs one turn through the loop driver and returns an owned slice holding
/// the rendered plain-text form of the message the turn appended. Caller
/// frees with `allocator.free`.
///
/// Invariant: every turn appends at least the user_text entry, so the
/// transcript length is guaranteed to grow by at least one.
pub fn runOneTurn(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    registry: *const Registry,
    user_text: []const u8,
    approval_fn: ?loop.ApprovalFn,
) ![]u8 {
    return runOneTurnWithClient(
        allocator,
        session,
        registry,
        session.modelClient(),
        user_text,
        approval_fn,
    );
}

pub fn runOneTurnWithClient(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    registry: *const Registry,
    client: loop.ModelClient,
    user_text: []const u8,
    approval_fn: ?loop.ApprovalFn,
) ![]u8 {
    const replay = session.replay_next_turn;
    session.replay_next_turn = false;

    const turn_result = loop.runTurnWith(
        allocator,
        client,
        registry,
        &session.transcript,
        user_text,
        .{
            .approval_fn = approval_fn,
            .replay_mode = replay,
            .max_attempts = loop.interactive_max_attempts,
        },
    ) catch |err| {
        if (session.events_path) |path| {
            const entries = session.transcript.entries.items;
            while (session.last_persisted_len < entries.len) : (session.last_persisted_len += 1) {
                persister.appendEntry(
                    allocator,
                    path,
                    session.transcript.entryIdAt(session.last_persisted_len),
                    &entries[session.last_persisted_len],
                    session.persist_opts,
                ) catch {};
            }
            session_events.appendEvent(allocator, path, .{ .turn_end = .{
                .reason = .error_exit,
            } }) catch {};
        }
        return err;
    };
    session.token_totals.add(turn_result.usage);
    session.metrics.record(turn_result);
    const tr = &session.transcript;
    std.debug.assert(tr.len() >= 1);

    if (session.events_path) |path| {
        const entries = tr.entries.items;
        while (session.last_persisted_len < entries.len) : (session.last_persisted_len += 1) {
            try persister.appendEntry(
                allocator,
                path,
                tr.entryIdAt(session.last_persisted_len),
                &entries[session.last_persisted_len],
                session.persist_opts,
            );
        }
        session_events.appendEvent(allocator, path, .{ .turn_end = .{
            .reason = turn_result.end_reason,
        } }) catch {}; // best-effort: a log write failure must not crash the turn
    }

    return transcript_mod.renderRichEntryToOwned(allocator, tr.at(tr.len() - 1));
}

pub const CompactedDetails = struct {
    reason: session_events.CompactionReason,
    first_kept_entry_id: transcript_mod.EntryId,
    tokens_before: u64,
    estimated_tokens_after: u64,
    summary_usage: turn.Usage,
};

pub const CompactResult = union(enum) {
    compacted: CompactedDetails,
    no_change,
    not_compactable: compaction.NotCompactableReason,
    unavailable,
    failed: anyerror,
};

/// Compatibility text wrapper for the current TTY command. U8 exposes the
/// same controller's structured result directly to RPC and command surfaces.
pub fn compact(
    allocator: std.mem.Allocator,
    session: *AgentSession,
) ![]u8 {
    const result = try compactDetailed(
        allocator,
        session,
        session.summarizer(),
        .{},
        .manual,
        null,
        false,
    );
    return switch (result) {
        .compacted => |details| std.fmt.allocPrint(
            allocator,
            "Compacted context at entry {d}: {d} -> {d} estimated tokens.\n",
            .{ details.first_kept_entry_id, details.tokens_before, details.estimated_tokens_after },
        ),
        .no_change => allocator.dupe(u8, "Nothing to compact.\n"),
        .not_compactable => |reason| std.fmt.allocPrint(
            allocator,
            "Context is not compactable: {s}.\n",
            .{@tagName(reason)},
        ),
        .unavailable => allocator.dupe(u8, "Compaction requires an active model backend.\n"),
        .failed => |failure| return failure,
    };
}

pub fn compactDetailed(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    maybe_summarizer: ?compaction.Summarizer,
    settings: compaction.Settings,
    reason: session_events.CompactionReason,
    focus: ?[]const u8,
    will_retry: bool,
) !CompactResult {
    const tr = &session.transcript;
    if (tr.len() == 0) return .no_change;
    const summarizer = maybe_summarizer orelse return .unavailable;
    const model = session.resolved_model orelse return .unavailable;

    var empty_transcript: transcript_mod.Transcript = .{};
    defer empty_transcript.deinit(allocator);
    const fixed_budget = try requestBudgetForProjection(allocator, session, &empty_transcript, null);
    const fixed_tokens = fixed_budget.tokens.system +| fixed_budget.tokens.tools;
    const capacity = compaction.deriveCapacity(
        settings,
        model,
        fixed_tokens,
        fixed_budget.tokens.framing,
    ) catch |err| return .{ .failed = err };
    const current_budget = try requestBudgetForProjection(allocator, session, tr, null);
    const preparation = try compaction.prepare(
        allocator,
        tr,
        capacity.effective_keep_recent_tokens,
    );
    const ready = switch (preparation) {
        .no_change => return .no_change,
        .not_compactable => |not_compactable| return .{ .not_compactable = not_compactable },
        .ready => |value| value,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();

    var file_ops = try compaction.extractFileOps(
        allocator,
        tr,
        ready.summarize_start,
        ready.first_kept_index,
    );
    var file_ops_owned = true;
    defer if (file_ops_owned) file_ops.deinit(allocator);

    var summary_usage: turn.Usage = .{};
    var regular_summary: ?[]const u8 = null;
    if (ready.summarize_start < ready.summarize_end or tr.projection != null) {
        const conversation = try compaction.serializeSpan(
            temporary,
            tr,
            ready.summarize_start,
            ready.summarize_end,
        );
        const prompt = try compaction.buildRegularPrompt(
            temporary,
            if (tr.projection) |projection| projection.summary else null,
            conversation,
            focus,
        );
        const request: compaction.SummaryRequest = .{
            .system_prompt = compaction.regular_system_prompt,
            .user_prompt = prompt,
            .max_output_tokens = @intCast(capacity.summary_allowance_tokens),
        };
        admitSummaryRequest(temporary, session, request) catch |err| return .{ .failed = err };
        const response = callSummarizer(
            session,
            summarizer,
            temporary,
            request,
        ) catch |err| return .{ .failed = err };
        summary_usage.add(response.usage);
        regular_summary = switch (response.response) {
            .final_text => |text| text,
            .tool_calls => return .{ .failed = error.SummaryReturnedToolCall },
            .edit => return .{ .failed = error.SummaryReturnedEdit },
        };
        compaction.validateRegularSummary(regular_summary.?) catch |err| return .{ .failed = err };
    }

    var prefix_summary: ?[]const u8 = null;
    if (ready.prefix_start) |prefix_start| {
        const conversation = try compaction.serializeSpan(
            temporary,
            tr,
            prefix_start,
            ready.prefix_end.?,
        );
        const prompt = try compaction.buildPrefixPrompt(temporary, conversation, focus);
        const request: compaction.SummaryRequest = .{
            .system_prompt = compaction.prefix_system_prompt,
            .user_prompt = prompt,
            .max_output_tokens = @intCast(capacity.summary_allowance_tokens),
        };
        admitSummaryRequest(temporary, session, request) catch |err| return .{ .failed = err };
        const response = callSummarizer(
            session,
            summarizer,
            temporary,
            request,
        ) catch |err| return .{ .failed = err };
        summary_usage.add(response.usage);
        prefix_summary = switch (response.response) {
            .final_text => |text| text,
            .tool_calls => return .{ .failed = error.SummaryReturnedToolCall },
            .edit => return .{ .failed = error.SummaryReturnedEdit },
        };
        compaction.validatePrefixSummary(prefix_summary.?) catch |err| return .{ .failed = err };
    }

    const summary = try compaction.assembleSummary(
        allocator,
        regular_summary,
        prefix_summary,
        file_ops,
    );
    var summary_owned = true;
    defer if (summary_owned) allocator.free(summary);
    const after_budget = try requestBudgetForProjection(allocator, session, tr, .{
        .summary = summary,
        .first_kept_entry_id = ready.first_kept_entry_id,
    });
    if (after_budget.tokens.total > capacity.admitted_input_tokens) {
        return .{ .failed = error.CompactedRequestStillTooLarge };
    }

    if (session.events_path) |path| {
        while (session.last_persisted_len < tr.len()) : (session.last_persisted_len += 1) {
            persister.appendEntry(
                allocator,
                path,
                tr.entryIdAt(session.last_persisted_len),
                tr.at(session.last_persisted_len),
                session.persist_opts,
            ) catch |err| return .{ .failed = err };
        }
        session_events.appendEvent(allocator, path, .{ .compaction_checkpoint = .{
            .summary = summary,
            .first_kept_entry_id = ready.first_kept_entry_id,
            .reason = reason,
            .tokens_before = current_budget.tokens.total,
            .estimated_tokens_after = after_budget.tokens.total,
            .summary_input_tokens = summary_usage.input_tokens,
            .summary_output_tokens = summary_usage.output_tokens,
            .will_retry = will_retry,
            .read_files = file_ops.read_files,
            .modified_files = file_ops.modified_files,
        } }) catch |err| return .{ .failed = err };
    }

    tr.installProjectionOwnedWithFiles(
        allocator,
        summary,
        ready.first_kept_entry_id,
        file_ops.read_files,
        file_ops.modified_files,
    );
    summary_owned = false;
    file_ops_owned = false;
    return .{ .compacted = .{
        .reason = reason,
        .first_kept_entry_id = ready.first_kept_entry_id,
        .tokens_before = current_budget.tokens.total,
        .estimated_tokens_after = after_budget.tokens.total,
        .summary_usage = summary_usage,
    } };
}

fn callSummarizer(
    session: *AgentSession,
    summarizer: compaction.Summarizer,
    arena: std.mem.Allocator,
    request: compaction.SummaryRequest,
) !compaction.SummaryResponse {
    session.summary_attempt_count +|= 1;
    const response = try summarizer.summarize(arena, request);
    session.summary_token_totals.add(response.usage);
    session.token_totals.add(response.usage);
    return response;
}

fn normalRequestConfig(session: *const AgentSession) !model_request.Config {
    return switch (session.backend) {
        .stub => error.CompactionUnavailable,
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
    };
}

fn requestBudgetForProjection(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    transcript: *const transcript_mod.Transcript,
    projection_override: ?model_request.ProjectionOverride,
) !context_budget.RequestBudget {
    return requestBudgetForConfig(
        allocator,
        try normalRequestConfig(session),
        transcript,
        projection_override,
        false,
    );
}

fn admitSummaryRequest(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    request: compaction.SummaryRequest,
) !void {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    try transcript.append(allocator, .{ .user_text = request.user_prompt });
    var config = try normalRequestConfig(session);
    config.system_prompt = request.system_prompt;
    config.tools_json = null;
    config.max_output_tokens = request.max_output_tokens;
    config.purpose = .summarization;
    config.cache_policy = .disabled;
    _ = try requestBudgetForConfig(allocator, config, &transcript, null, true);
}

fn requestBudgetForConfig(
    allocator: std.mem.Allocator,
    config: model_request.Config,
    transcript: *const transcript_mod.Transcript,
    projection_override: ?model_request.ProjectionOverride,
    require_hard_admission: bool,
) !context_budget.RequestBudget {
    var snapshot = try model_request.createSnapshot(allocator, .{
        .config = config,
        .transcript = transcript,
        .projection_override = projection_override,
        .use_projection_override = projection_override != null,
    });
    defer snapshot.deinit(allocator);
    const body = switch (snapshot.config.provider) {
        .anthropic => try anthropic_client.buildRequestBodyFromSnapshot(allocator, &snapshot),
        .openai => try openai_client.buildRequestBodyFromSnapshot(allocator, &snapshot),
        .local, .deepseek => try chat_completions.buildRequestBodyFromSnapshot(allocator, &snapshot),
    };
    defer allocator.free(body);
    try snapshot.completePreparation(body);
    if (require_hard_admission) try snapshot.requireHardAdmission();
    return snapshot.budget orelse error.RequestNotPrepared;
}

/// Branch the current session: create a new session directory, copy the
/// current transcript's persisted events to it, write a meta.json with
/// `parent_id` pointing at the current session, then update the session's
/// on-disk handles to the new location. The in-memory transcript is unchanged.
/// Returns an owned summary message; caller frees.
pub fn fork(
    allocator: std.mem.Allocator,
    session: *AgentSession,
) ![]u8 {
    const old_sid = session.session_id orelse {
        return allocator.dupe(u8, "Session is ephemeral (--no-session); nothing to fork.\n");
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const realpath = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(realpath);

    const new_sid = try session_id_mod.generate(allocator);
    errdefer allocator.free(new_sid);
    const new_dir = try session_paths.sessionDir(allocator, new_sid);
    errdefer allocator.free(new_dir);
    try session_paths.writeWorkspacePointer(allocator, new_dir, realpath);

    const new_events_path = try std.fs.path.join(allocator, &.{ new_dir, "events.jsonl" });
    errdefer allocator.free(new_events_path);
    const new_meta_path = try std.fs.path.join(allocator, &.{ new_dir, "meta.json" });
    errdefer allocator.free(new_meta_path);

    const old_events_path = session.events_path orelse return error.MissingSessionPath;
    while (session.last_persisted_len < session.transcript.len()) : (session.last_persisted_len += 1) {
        try persister.appendEntry(
            allocator,
            old_events_path,
            session.transcript.entryIdAt(session.last_persisted_len),
            session.transcript.at(session.last_persisted_len),
            session.persist_opts,
        );
    }
    try session_events.copyJournal(allocator, old_events_path, new_events_path);

    try session_events.writeMeta(allocator, new_meta_path, .{
        .session_id = new_sid,
        .workspace_realpath = realpath,
        .created_at_unix_ms = nowUnixMs(),
        .parent_id = old_sid,
        .provider = if (session.activeProvider()) |provider| provider.publicName() else null,
        .model = session.currentModel(),
    });

    if (session.session_id) |s| allocator.free(s);
    if (session.session_dir) |s| allocator.free(s);
    if (session.events_path) |s| allocator.free(s);
    if (session.meta_path) |s| allocator.free(s);

    session.session_id = new_sid;
    session.session_dir = new_dir;
    session.events_path = new_events_path;
    session.meta_path = new_meta_path;
    session.last_persisted_len = session.transcript.len();

    return std.fmt.allocPrint(
        allocator,
        "Forked to new session: {s}\nParent: {s}\n",
        .{ new_sid, old_sid },
    );
}

/// Tear down `session` and rebuild it in place from the same environment.
/// Used by `/resume` and `/new`.
const PreparedResume = struct {
    session_id: []u8,
    meta: session_events.Meta,

    fn deinit(self: *PreparedResume, allocator: std.mem.Allocator) void {
        session_events.freeMeta(allocator, &self.meta);
        allocator.free(self.session_id);
        self.* = undefined;
    }
};

fn prepareLatestResume(allocator: std.mem.Allocator) !?PreparedResume {
    const root = try session_paths.sessionRoot(allocator);
    defer allocator.free(root);
    const hash = try session_paths.cwdHashFull(allocator);
    const entries = try session_paths.listSessions(allocator, root, hash[0..]);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    if (entries.len == 0) return null;

    const session_id = try allocator.dupe(u8, entries[0].session_id);
    errdefer allocator.free(session_id);
    return .{
        .session_id = session_id,
        .meta = try readSessionMeta(allocator, session_id),
    };
}

pub fn rebuildSession(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    registry: *const Registry,
    config: SessionConfig,
) !void {
    var prepared_resume = if (config.resume_latest)
        try prepareLatestResume(allocator)
    else
        null;
    defer if (prepared_resume) |*prepared| prepared.deinit(allocator);
    if (prepared_resume) |*prepared| {
        const target = try provider_selection.resolve(.{
            .launch_provider = config.provider,
            .launch_model = config.model,
            .stored = .{
                .provider = prepared.meta.provider,
                .model = prepared.meta.model,
            },
        });
        if (target.provider != session.activeProvider()) {
            return error.CrossProviderResume;
        }
    }
    var next = try initFromEnvWithPreparedResume(
        allocator,
        registry,
        config,
        if (prepared_resume) |*prepared| prepared else null,
    );
    errdefer next.deinit(allocator);
    if (config.resume_latest and next.activeProvider() != session.activeProvider()) {
        return error.CrossProviderResume;
    }

    // Commit the swap only after the target session and provider constraint are
    // fully validated. A failed resume leaves the current session untouched.
    session.writeSessionSummary(allocator);
    session.deinit(allocator);
    session.* = next;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const EnvOverride = @import("test_support/env.zig").EnvOverride;
const cwdPathAlloc = @import("test_support/cwd.zig").cwdPathAlloc;
const ui_payload = @import("ui_payload.zig");

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "agent");
}

/// All proof-guarantee booleans set to `value`. Used to exercise the metrics
/// fold without depending on a live analyzer run.
fn snapshotAll(value: bool) ui_payload.PropertiesSnapshot {
    return .{
        .pure = value,
        .read_only = value,
        .stateless = value,
        .retry_safe = value,
        .deterministic = value,
        .has_egress = value,
        .no_secret_leakage = value,
        .no_credential_leakage = value,
        .input_validated = value,
        .pii_contained = value,
        .idempotent = value,
        .injection_safe = value,
        .state_isolated = value,
        .fault_covered = value,
        .result_safe = value,
        .optional_safe = value,
        .cost_bounded = value,
        .post_only = value,
        .canonical = value,
    };
}

test "guaranteeCounts excludes has_egress and counts discharged guarantees" {
    const all_true = snapshotAll(true).guaranteeCounts();
    try testing.expectEqual(@as(u32, 18), all_true.tracked);
    try testing.expectEqual(@as(u32, 18), all_true.proven);

    const all_false = snapshotAll(false).guaranteeCounts();
    try testing.expectEqual(@as(u32, 18), all_false.tracked);
    try testing.expectEqual(@as(u32, 0), all_false.proven);
}

test "SessionMetrics folds a clarifying text turn then an applied edit" {
    var m: SessionMetrics = .{};
    // Turn 1: a clarifying question - plain text, ends approved, applies no edit.
    m.record(.{ .final_state = .done, .attempt = 0, .roundtrips = 1 });
    // Turn 2: the answer drives an applied, compiler-verified edit. The veto
    // counts the proof guarantees (snapshotAll(true) -> 18/18, see guaranteeCounts).
    m.record(.{
        .final_state = .done,
        .attempt = 1,
        .roundtrips = 3,
        .applied_edit = true,
        .proven_guarantees = 16,
        .tracked_guarantees = 16,
        .workflow_kind = .route_add,
        .workflow_confidence = .high,
        .workflow_hint_injected = true,
        .first_draft_veto_pass = true,
        .tool_call_count = 2,
    });

    const s = m.summary();
    try testing.expectEqual(@as(u32, 2), s.turn_count);
    try testing.expectEqual(@as(u32, 4), s.total_roundtrips);
    try testing.expectEqual(@as(u32, 1), s.verified_patch_count);
    try testing.expect(s.reached_proof);
    // Both turns' round-trips count toward reaching the first green proof.
    try testing.expectEqual(@as(u32, 4), s.round_trips_to_first_green);
    try testing.expectEqual(@as(u32, 16), s.tracked_properties);
    try testing.expectEqual(@as(u32, 16), s.proven_properties);
    try testing.expectEqual(@as(u32, 1), s.workflow_hint_count);
    try testing.expectEqual(@as(u32, 1), s.high_confidence_workflow_hint_count);
    try testing.expectEqual(@as(u32, 1), s.first_draft_veto_pass_count);
    try testing.expectEqual(@as(u32, 2), s.tool_call_count);
    try testing.expectEqualStrings("route_add", s.last_workflow_kind);
    try testing.expectEqualStrings("high", s.last_workflow_confidence);
    try testing.expectEqual(@as(f32, 1.0), s.provenPathRatio());
}

test "SessionMetrics with no applied edit reports no proof reached" {
    var m: SessionMetrics = .{};
    m.record(.{ .final_state = .done, .attempt = 0, .roundtrips = 2, .end_reason = .veto_exhausted });
    const s = m.summary();
    try testing.expectEqual(@as(u32, 1), s.turn_count);
    try testing.expectEqual(@as(u32, 0), s.verified_patch_count);
    try testing.expect(!s.reached_proof);
    try testing.expectEqual(@as(u32, 0), s.round_trips_to_first_green);
    try testing.expectEqual(session_events.TurnEndReason.veto_exhausted, s.final_outcome);
}

fn writeTestFile(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    sub_path: []const u8,
    data: []const u8,
) !void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var root = try std.Io.Dir.openDirAbsolute(io, root_abs, .{});
    defer root.close(io);
    if (std.fs.path.dirname(sub_path)) |parent| {
        try std.Io.Dir.createDirPath(root, io, parent);
    }
    try root.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test "runOneTurn: fresh stub session grows transcript by 2 and renders model reply" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    const rendered = try runOneTurn(testing.allocator, &session, &registry, "add a GET route", null);
    defer testing.allocator.free(rendered);

    try testing.expectEqual(@as(usize, 3), session.transcript.len());
    switch (session.transcript.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("add a GET route", body),
        else => return error.TestFailed,
    }
    switch (session.transcript.at(1).*) {
        .system_note => |body| try testing.expect(std.mem.indexOf(u8, body, "kind=route_add") != null),
        else => return error.TestFailed,
    }
    switch (session.transcript.at(2).*) {
        .model_text => |body| try testing.expectEqualStrings(stub_reply_text, body),
        else => return error.TestFailed,
    }
    try testing.expect(std.mem.startsWith(u8, rendered, "model: "));
    try testing.expect(std.mem.indexOf(u8, rendered, stub_reply_text) != null);
    try testing.expect(rendered[rendered.len - 1] == '\n');
}

test "runOneTurn: two turns back-to-back accumulate in the transcript" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    const first = try runOneTurn(testing.allocator, &session, &registry, "first intent", null);
    defer testing.allocator.free(first);
    const second = try runOneTurn(testing.allocator, &session, &registry, "second intent", null);
    defer testing.allocator.free(second);

    try testing.expectEqual(@as(usize, 4), session.transcript.len());
    switch (session.transcript.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("first intent", body),
        else => return error.TestFailed,
    }
    switch (session.transcript.at(2).*) {
        .user_text => |body| try testing.expectEqualStrings("second intent", body),
        else => return error.TestFailed,
    }
    // The second render is the second turn's model reply only, not a
    // cumulative dump of the whole transcript.
    try testing.expect(std.mem.indexOf(u8, second, "first intent") == null);
    try testing.expect(std.mem.indexOf(u8, second, stub_reply_text) != null);
}

test "runOneTurn folds the turn into session metrics" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);

    const rendered = try runOneTurn(testing.allocator, &session, &registry, "add a GET route", null);
    defer testing.allocator.free(rendered);

    // A stub reply is plain text - it counts as a turn, but applies no edit, so
    // it must not register as a verified patch or a reached proof.
    try testing.expectEqual(@as(u32, 1), session.metrics.turn_count);
    try testing.expectEqual(@as(u32, 0), session.metrics.verified_patch_count);
    try testing.expectEqual(@as(u32, 1), session.metrics.workflow_hint_count);
    try testing.expectEqual(@as(u32, 1), session.metrics.high_confidence_workflow_hint_count);
    try testing.expectEqualStrings("route_add", session.metrics.summary().last_workflow_kind);
    try testing.expect(!session.metrics.summary().reached_proof);
}

test "StubClient ignores user_text and always returns the stub reply" {
    var stub: StubClient = .{};
    const client = stub.asClient();
    var transcript: Transcript = .{};
    defer transcript.deinit(testing.allocator);
    const result = try client.request(testing.allocator, &transcript, "whatever the user typed");
    switch (result.reply.response) {
        .final_text => |t| try testing.expectEqualStrings(stub_reply_text, t),
        else => return error.TestFailed,
    }
}

test "initAnthropic dupes api_key and system_prompt, deinit releases both" {
    var session = try AgentSession.initAnthropic(
        testing.allocator,
        "test-fixture-key",
        "you are a zts expert",
        "[{\"name\":\"zts_expert_meta\",\"description\":\"d\",\"input_schema\":{}}]",
    );
    defer session.deinit(testing.allocator);

    try testing.expect(session.backend == .anthropic);
    try testing.expectEqualStrings("test-fixture-key", session.backend.anthropic.config.api_key);
    try testing.expectEqualStrings("you are a zts expert", session.backend.anthropic.config.system_prompt);
    try testing.expectEqualStrings("claude-sonnet-4-6", session.backend.anthropic.config.model);
    try testing.expectEqual(@as(u32, 64_000), session.backend.anthropic.config.max_tokens);
    try testing.expect(session.backend.anthropic.config.tools_json != null);
    try testing.expect(session.system_prompt_owned != null);
}

test "initOpenAI dupes api_key and system_prompt and routes through openai backend" {
    var session = try AgentSession.initOpenAI(
        testing.allocator,
        "openai-fixture-key",
        "you are a zts expert",
        "[{\"type\":\"function\",\"function\":{\"name\":\"x\"}}]",
        null,
    );
    defer session.deinit(testing.allocator);

    try testing.expect(session.backend == .openai);
    try testing.expectEqualStrings("openai-fixture-key", session.backend.openai.config.api_key);
    try testing.expectEqualStrings("you are a zts expert", session.backend.openai.config.system_prompt);
    try testing.expectEqualStrings("gpt-4o-mini", session.backend.openai.config.model);
    try testing.expectEqual(@as(u32, 8_192), session.backend.openai.config.max_tokens);
    try testing.expectEqualStrings("openai", session.backendDescriptor().provider_label);
}

test "initDeepSeek dupes its owned bytes and routes through the deepseek backend" {
    var session = try AgentSession.initDeepSeek(
        testing.allocator,
        "deepseek-fixture-key",
        "you are a zts expert",
        "[{\"type\":\"function\",\"function\":{\"name\":\"x\"}}]",
        deepseek_client.default_base_url,
    );
    defer session.deinit(testing.allocator);

    try testing.expect(session.backend == .deepseek);
    try testing.expectEqualStrings("deepseek-fixture-key", session.backend.deepseek.config.api_key);
    try testing.expectEqualStrings("you are a zts expert", session.backend.deepseek.config.system_prompt);
    try testing.expectEqualStrings("deepseek-v4-flash", session.backend.deepseek.config.model);
    try testing.expectEqual(@as(u32, 8_192), session.backend.deepseek.config.max_tokens);
    try testing.expectEqualStrings("deepseek", session.backendDescriptor().provider_label);
    try testing.expectEqualStrings("api-key", session.backendDescriptor().auth_label);
    try testing.expect(session.base_url_owned != null);
}

test "a deepseek session declares a remote destination at whatever root it uses" {
    var hosted = try AgentSession.initDeepSeek(
        testing.allocator,
        "k",
        "p",
        null,
        deepseek_client.default_base_url,
    );
    defer hosted.deinit(testing.allocator);
    const hosted_destination = destinationForSession(&hosted);
    try testing.expectEqualStrings(deepseek_client.default_base_url, hosted_destination.deepseek);
    try testing.expect(!hosted_destination.isLocal());

    var gateway = try AgentSession.initDeepSeek(
        testing.allocator,
        "k",
        "p",
        null,
        "https://gateway.example.com/v1",
    );
    defer gateway.deinit(testing.allocator);
    const gateway_destination = destinationForSession(&gateway);
    try testing.expectEqualStrings("https://gateway.example.com/v1", gateway_destination.deepseek);
    try testing.expect(!gateway_destination.isLocal());
}

test "setModel moves a deepseek session between registered deepseek models only" {
    var session = try AgentSession.initDeepSeek(testing.allocator, "k", "p", null, deepseek_client.default_base_url);
    defer session.deinit(testing.allocator);

    try session.setModel(testing.allocator, "deepseek-v4-pro");
    try testing.expectEqualStrings("deepseek-v4-pro", session.backend.deepseek.config.model);
    try testing.expectEqualStrings("deepseek-v4-pro", session.currentModel().?);

    try testing.expectError(
        error.ProviderMismatch,
        session.setModel(testing.allocator, "gpt-4o-mini"),
    );
    try testing.expectEqualStrings("deepseek-v4-pro", session.backend.deepseek.config.model);
}

test "an endpoint override redirects the client without touching the hosted default" {
    // A custom Responses-compatible endpoint changes transport location only.
    // Model selection remains provider-scoped through the static registry.
    var local = try AgentSession.initOpenAI(
        testing.allocator,
        "unused-by-a-local-server",
        "p",
        null,
        .{ .base_url = "http://127.0.0.1:11434/v1/responses" },
    );
    defer local.deinit(testing.allocator);

    try testing.expectEqualStrings("http://127.0.0.1:11434/v1/responses", local.backend.openai.config.base_url);
    try testing.expectEqualStrings("gpt-4o-mini", local.backend.openai.config.model);
    try testing.expectEqual(@as(u32, 8_192), local.backend.openai.config.max_tokens);

    var hosted = try AgentSession.initOpenAI(testing.allocator, "k", "p", null, null);
    defer hosted.deinit(testing.allocator);
    try testing.expectEqualStrings("gpt-4o-mini", hosted.backend.openai.config.model);
    try testing.expectEqual(@as(u32, 8_192), hosted.backend.openai.config.max_tokens);
}

test "an endpoint that moves only the host keeps the registry model" {
    // A proxy in front of OpenAI: the wire shape and the model are unchanged,
    // only where the request goes. Forcing a model id here would silently
    // replace one the caller never asked to change.
    var session = try AgentSession.initOpenAI(
        testing.allocator,
        "k",
        "p",
        null,
        .{ .base_url = "http://proxy.internal/v1/responses" },
    );
    defer session.deinit(testing.allocator);

    try testing.expectEqualStrings("http://proxy.internal/v1/responses", session.backend.openai.config.base_url);
    try testing.expectEqualStrings("gpt-4o-mini", session.backend.openai.config.model);
    try testing.expectEqual(@as(u32, 8_192), session.backend.openai.config.max_tokens);
}

test "modelClient returns an anthropic client vtable when backend is anthropic" {
    var session = try AgentSession.initAnthropic(testing.allocator, "k", "p", null);
    defer session.deinit(testing.allocator);

    const mc = session.modelClient();
    try testing.expect(mc.context == @as(*anyopaque, @ptrCast(&session.backend.anthropic)));
}

test "registry defaults match provider client model defaults" {
    const anthropic_defaults = anthropic_client.Config{ .api_key = "", .system_prompt = "" };
    const openai_defaults = openai_client.Config{ .api_key = "", .system_prompt = "" };
    try testing.expectEqualStrings(
        anthropic_defaults.model,
        models_registry.defaultForProvider(.anthropic).id,
    );
    try testing.expectEqualStrings(
        openai_defaults.model,
        models_registry.defaultForProvider(.openai).id,
    );
}

test "contextWindowTokens uses provider registry metadata" {
    var openai = try AgentSession.initOpenAI(testing.allocator, "k", "p", null, null);
    defer openai.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 128_000), contextWindowTokens(&openai));

    var anthropic = try AgentSession.initAnthropic(testing.allocator, "k", "p", null);
    defer anthropic.deinit(testing.allocator);
    // The Anthropic default is registered, so its real window is used.
    try testing.expectEqual(@as(usize, 200_000), contextWindowTokens(&anthropic));
}

test "setModel validates provider and commits model with request policy atomically" {
    var session = try AgentSession.initAnthropic(testing.allocator, "k", "p", null);
    defer session.deinit(testing.allocator);

    try session.setModel(testing.allocator, "claude-sonnet-4-6");
    try testing.expectEqual(@as(u32, 64_000), session.backend.anthropic.config.max_tokens);
    try testing.expectEqualStrings("claude-sonnet-4-6", session.backend.anthropic.config.model);

    try testing.expectError(error.UnknownModel, session.setModel(testing.allocator, "some-unknown-model"));
    try testing.expectEqual(@as(u32, 64_000), session.backend.anthropic.config.max_tokens);
    try testing.expectEqualStrings("claude-sonnet-4-6", session.backend.anthropic.config.model);

    try testing.expectError(error.ProviderMismatch, session.setModel(testing.allocator, "gpt-4o-mini"));
    try testing.expectEqual(@as(u32, 64_000), session.backend.anthropic.config.max_tokens);
    try testing.expectEqualStrings("claude-sonnet-4-6", session.backend.anthropic.config.model);
}

test "setModel persistence failure leaves the live model unchanged" {
    const FailRestamp = struct {
        fn run(
            _: std.mem.Allocator,
            _: *const AgentSession,
            _: Provider,
            _: []const u8,
        ) !void {
            return error.WriteFailure;
        }
    };

    var session = try AgentSession.initAnthropic(testing.allocator, "k", "p", null);
    defer session.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "claude-sonnet-4-6",
        session.currentModel() orelse return error.TestUnexpectedResult,
    );

    try testing.expectError(
        error.WriteFailure,
        session.setModelWithRestamp(testing.allocator, "claude-opus-4-8", FailRestamp.run),
    );
    try testing.expectEqualStrings(
        "claude-sonnet-4-6",
        session.currentModel() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings("claude-sonnet-4-6", session.backend.anthropic.config.model);
    try testing.expectEqual(@as(u32, 64_000), session.backend.anthropic.config.max_tokens);
}

test "OpenAI and stub model selection respect backend provider state" {
    var openai = try AgentSession.initOpenAI(testing.allocator, "k", "p", null, null);
    defer openai.deinit(testing.allocator);
    try testing.expectEqual(
        Provider.openai,
        openai.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try openai.setModel(testing.allocator, "gpt-4o-mini");
    try testing.expectEqual(@as(u32, 8_192), openai.backend.openai.config.max_tokens);

    var stub = AgentSession.initStub();
    defer stub.deinit(testing.allocator);
    try testing.expect(stub.activeProvider() == null);
    try testing.expectError(error.NoActiveProvider, stub.setModel(testing.allocator, "gpt-4o-mini"));
    try testing.expect(stub.currentModel() == null);
}

test "explicit Claude selects only the Anthropic credential" {
    const allocator = testing.allocator;
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-key");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-key");
    defer openai.restore(allocator);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = .anthropic,
        .model = "claude-haiku-4-5-20251001",
    });
    defer session.deinit(allocator);
    try testing.expectEqual(
        Provider.anthropic,
        session.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "claude-haiku-4-5-20251001",
        session.currentModel() orelse return error.TestUnexpectedResult,
    );

    try testing.expectError(
        error.ProviderMismatch,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_session = true,
            .no_context_files = true,
            .provider = .anthropic,
            .model = "gpt-4o-mini",
        }),
    );
}

test "explicit OpenAI selects only the OpenAI credential" {
    const allocator = testing.allocator;
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-decoy");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-key");
    defer openai.restore(allocator);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = .openai,
        .model = "gpt-4o-mini",
    });
    defer session.deinit(allocator);
    try testing.expectEqual(
        Provider.openai,
        session.activeProvider() orelse return error.TestUnexpectedResult,
    );

    try testing.expectError(
        error.ProviderMismatch,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_session = true,
            .no_context_files = true,
            .provider = .openai,
            .model = "claude-sonnet-4-6",
        }),
    );
}

test "explicit DeepSeek selects only the DeepSeek credential" {
    const allocator = testing.allocator;
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-decoy");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-decoy");
    defer openai.restore(allocator);
    var deepseek = try EnvOverride.set(allocator, "DEEPSEEK_API_KEY", "deepseek-key");
    defer deepseek.restore(allocator);
    var base_url = try EnvOverride.unset(allocator, "DEEPSEEK_BASE_URL");
    defer base_url.restore(allocator);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = .deepseek,
        .model = "deepseek-v4-pro",
    });
    defer session.deinit(allocator);
    try testing.expectEqual(
        Provider.deepseek,
        session.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings("deepseek-key", session.backend.deepseek.config.api_key);
    try testing.expectEqualStrings(deepseek_client.default_base_url, session.backend.deepseek.config.base_url);
    try testing.expectEqualStrings("deepseek-v4-pro", session.currentModel().?);

    try testing.expectError(
        error.ProviderMismatch,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_session = true,
            .no_context_files = true,
            .provider = .deepseek,
            .model = "claude-sonnet-4-6",
        }),
    );
}

test "a DeepSeek session refuses to launch without a key or over plain HTTP" {
    const allocator = testing.allocator;
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    {
        var deepseek = try EnvOverride.unset(allocator, "DEEPSEEK_API_KEY");
        defer deepseek.restore(allocator);
        try testing.expectError(
            error.MissingDeepSeekCredential,
            initFromEnvWithSessionConfig(allocator, &registry, .{
                .no_session = true,
                .no_context_files = true,
                .provider = .deepseek,
            }),
        );
    }

    var deepseek = try EnvOverride.set(allocator, "DEEPSEEK_API_KEY", "deepseek-key");
    defer deepseek.restore(allocator);
    var base_url = try EnvOverride.set(allocator, "DEEPSEEK_BASE_URL", "http://127.0.0.1:8080");
    defer base_url.restore(allocator);
    try testing.expectError(
        error.InvalidDeepSeekBaseUrl,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_session = true,
            .no_context_files = true,
            .provider = .deepseek,
        }),
    );
}

test "explicit cloud provider never borrows the other provider credential" {
    const allocator = testing.allocator;
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    {
        var anthropic = try EnvOverride.unset(allocator, "ANTHROPIC_API_KEY");
        defer anthropic.restore(allocator);
        var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-only");
        defer openai.restore(allocator);
        try testing.expectError(error.MissingAnthropicCredential, initFromEnvWithSessionConfig(
            allocator,
            &registry,
            .{ .no_session = true, .no_context_files = true, .provider = .anthropic },
        ));
    }
    {
        var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-only");
        defer anthropic.restore(allocator);
        var openai = try EnvOverride.unset(allocator, "OPENAI_API_KEY");
        defer openai.restore(allocator);
        try testing.expectError(error.MissingOpenAICredential, initFromEnvWithSessionConfig(
            allocator,
            &registry,
            .{ .no_session = true, .no_context_files = true, .provider = .openai },
        ));
    }
}

test "bare persisted session follows the global default regardless of cloud keys" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-decoy");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-decoy");
    defer openai.restore(allocator);

    var session = try initFromEnvWithSessionConfig(allocator, null, .{ .no_context_files = true });
    defer session.deinit(allocator);
    // Named rather than derived from `default_provider`: deriving both sides
    // would pass whatever the constant said, including a value nobody meant to
    // ship. Anthropic and OpenAI keys are set here and no DeepSeek key is,
    // which is the point - credentials never steer the default.
    try testing.expectEqual(
        Provider.deepseek,
        session.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqual(models_registry.default_provider, session.activeProvider().?);
    try testing.expectEqualStrings(
        "deepseek-v4-flash",
        session.currentModel() orelse return error.TestUnexpectedResult,
    );

    var meta = try session_events.readMeta(
        allocator,
        session.meta_path orelse return error.TestUnexpectedResult,
    );
    defer session_events.freeMeta(allocator, &meta);
    try testing.expectEqualStrings("deepseek", meta.provider orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        "deepseek-v4-flash",
        meta.model orelse return error.TestUnexpectedResult,
    );
}

test "resume fork override and model mutation preserve provider identity" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);

    const source_id = blk: {
        var source = try initFromEnvWithSessionConfig(allocator, null, .{
            .no_context_files = true,
            .provider = .anthropic,
            .model = "claude-opus-4-8",
        });
        defer source.deinit(allocator);
        try zts.file_io.writeFile(
            allocator,
            source.events_path orelse return error.TestUnexpectedResult,
            "",
        );
        break :blk try allocator.dupe(
            u8,
            source.session_id orelse return error.TestUnexpectedResult,
        );
    };
    defer allocator.free(source_id);

    var resumed = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .resume_latest = true,
    });
    try testing.expectEqual(
        Provider.anthropic,
        resumed.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "claude-opus-4-8",
        resumed.currentModel() orelse return error.TestUnexpectedResult,
    );
    try resumed.setModel(allocator, "claude-sonnet-5");
    var mutated = try session_events.readMeta(
        allocator,
        resumed.meta_path orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings("claude", mutated.provider orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        "claude-sonnet-5",
        mutated.model orelse return error.TestUnexpectedResult,
    );
    session_events.freeMeta(allocator, &mutated);
    resumed.deinit(allocator);

    var forked = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .fork_session_id = source_id,
    });
    defer forked.deinit(allocator);
    try testing.expectEqual(
        Provider.anthropic,
        forked.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "claude-sonnet-5",
        forked.currentModel() orelse return error.TestUnexpectedResult,
    );
    var fork_meta = try session_events.readMeta(
        allocator,
        forked.meta_path orelse return error.TestUnexpectedResult,
    );
    defer session_events.freeMeta(allocator, &fork_meta);
    try testing.expectEqualStrings(source_id, fork_meta.parent_id orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("claude", fork_meta.provider orelse return error.TestUnexpectedResult);

    var overridden = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .resume_latest = true,
        .provider = .local,
    });
    defer overridden.deinit(allocator);
    try testing.expect(overridden.identity_override_disclosed);
    try testing.expectEqual(
        Provider.local,
        overridden.activeProvider() orelse return error.TestUnexpectedResult,
    );
    var override_meta = try session_events.readMeta(
        allocator,
        overridden.meta_path orelse return error.TestUnexpectedResult,
    );
    defer session_events.freeMeta(allocator, &override_meta);
    try testing.expectEqualStrings("local", override_meta.provider orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        local_client.default_model,
        override_meta.model orelse return error.TestUnexpectedResult,
    );
}

test "named session resume preserves transcript bytes and stored identity" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);

    const source_id, const expected_events = blk: {
        var source = try initFromEnvWithSessionConfig(allocator, null, .{
            .no_context_files = true,
            .provider = .anthropic,
            .model = "claude-opus-4-8",
        });
        defer source.deinit(allocator);
        const source_events_path = source.events_path orelse return error.TestUnexpectedResult;
        try session_events.appendEntryEvent(allocator, source_events_path, 1, null, .{ .user_text = "preserve me" });
        const bytes = try zts.file_io.readFile(allocator, source_events_path, 1024 * 1024);
        errdefer allocator.free(bytes);
        break :blk .{
            try allocator.dupe(
                u8,
                source.session_id orelse return error.TestUnexpectedResult,
            ),
            bytes,
        };
    };
    defer allocator.free(source_id);
    defer allocator.free(expected_events);

    var resumed = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .session_id = source_id,
    });
    defer resumed.deinit(allocator);

    const actual_events = try zts.file_io.readFile(
        allocator,
        resumed.events_path orelse return error.TestUnexpectedResult,
        1024 * 1024,
    );
    defer allocator.free(actual_events);
    try testing.expectEqualStrings(expected_events, actual_events);
    try testing.expect(resumed.replay_next_turn);
    try testing.expectEqual(@as(usize, 1), resumed.transcript.len());
    try testing.expectEqual(
        Provider.anthropic,
        resumed.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "claude-opus-4-8",
        resumed.currentModel() orelse return error.TestUnexpectedResult,
    );
}

test "named session with events and missing metadata fails without truncation" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);

    const session_id = "missing-meta";
    const session_dir = try session_paths.sessionDir(allocator, session_id);
    defer allocator.free(session_dir);
    const workspace = try cwdPathAlloc(allocator);
    defer allocator.free(workspace);
    try session_paths.writeWorkspacePointer(allocator, session_dir, workspace);

    const events_path = try std.fs.path.join(allocator, &.{ session_dir, "events.jsonl" });
    defer allocator.free(events_path);
    const expected_events = "{\"type\":\"user_text\",\"text\":\"preserve me\"}\n";
    try zts.file_io.writeFile(allocator, events_path, expected_events);

    try testing.expectError(
        error.MissingSessionMetadata,
        initFromEnvWithSessionConfig(allocator, null, .{
            .no_context_files = true,
            .session_id = session_id,
        }),
    );

    const actual_events = try zts.file_io.readFile(allocator, events_path, 1024 * 1024);
    defer allocator.free(actual_events);
    try testing.expectEqualStrings(expected_events, actual_events);
}

test "model-free legacy resume bypasses provider identity and preserves metadata" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);

    const meta_path = blk: {
        var source = try initFromEnvWithSessionConfig(allocator, null, .{ .no_context_files = true });
        defer source.deinit(allocator);
        try session_events.appendEntryEvent(
            allocator,
            source.events_path orelse return error.TestUnexpectedResult,
            1,
            null,
            .{ .user_text = "compiler witness" },
        );
        const source_meta_path = source.meta_path orelse return error.TestUnexpectedResult;
        var meta = try session_events.readMeta(allocator, source_meta_path);
        defer session_events.freeMeta(allocator, &meta);
        try session_events.writeMeta(allocator, source_meta_path, .{
            .session_id = meta.session_id,
            .workspace_realpath = meta.workspace_realpath,
            .created_at_unix_ms = meta.created_at_unix_ms,
            .policy_hash = meta.policy_hash,
            .provider = null,
            .model = null,
        });
        break :blk try allocator.dupe(u8, source_meta_path);
    };
    defer allocator.free(meta_path);

    var resumed = try initFromEnvWithSessionConfig(allocator, null, .{
        .model_free = true,
        .no_context_files = true,
        .resume_latest = true,
    });
    defer resumed.deinit(allocator);
    try testing.expect(resumed.backend == .stub);
    try testing.expectEqual(@as(usize, 1), resumed.transcript.len());

    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);
    try testing.expect(meta.provider == null);
    try testing.expect(meta.model == null);
}

test "obsolete OpenAI model environment override is rejected" {
    const allocator = testing.allocator;
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-key");
    defer openai.restore(allocator);
    var endpoint = try EnvOverride.set(allocator, "ZTS_OPENAI_BASE_URL", "http://127.0.0.1:11434/v1/responses");
    defer endpoint.restore(allocator);
    var model = try EnvOverride.set(allocator, "ZTS_OPENAI_MODEL", "qwen2.5-coder:7b");
    defer model.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    try testing.expectError(error.UnsupportedOpenAIModelOverride, initFromEnvWithSessionConfig(
        allocator,
        &registry,
        .{ .no_session = true, .no_context_files = true, .provider = .openai },
    ));
}

test "legacy resume migrates once and cross-provider rebuild is atomic" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);

    const meta_path = blk: {
        var legacy = try initFromEnvWithSessionConfig(allocator, null, .{ .no_context_files = true });
        defer legacy.deinit(allocator);
        try zts.file_io.writeFile(
            allocator,
            legacy.events_path orelse return error.TestUnexpectedResult,
            "",
        );
        const legacy_meta_path = legacy.meta_path orelse return error.TestUnexpectedResult;
        var meta = try session_events.readMeta(allocator, legacy_meta_path);
        defer session_events.freeMeta(allocator, &meta);
        try session_events.writeMeta(allocator, legacy_meta_path, .{
            .session_id = meta.session_id,
            .workspace_realpath = meta.workspace_realpath,
            .created_at_unix_ms = meta.created_at_unix_ms,
            .policy_hash = meta.policy_hash,
            .provider = null,
            .model = null,
        });
        break :blk try allocator.dupe(u8, legacy_meta_path);
    };
    defer allocator.free(meta_path);

    try testing.expectError(
        error.LegacySessionIdentity,
        initFromEnvWithSessionConfig(allocator, null, .{
            .no_context_files = true,
            .resume_latest = true,
        }),
    );

    var migrated = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .resume_latest = true,
        .provider = .anthropic,
    });
    defer migrated.deinit(allocator);
    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);
    try testing.expectEqualStrings("claude", meta.provider orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(
        "claude-sonnet-4-6",
        meta.model orelse return error.TestUnexpectedResult,
    );

    var current = AgentSession.initStub();
    current.resolved_provider = .local;
    current.resolved_model = models_registry.defaultForProvider(.local);
    defer current.deinit(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);
    const before_model = current.currentModel() orelse return error.TestUnexpectedResult;
    try testing.expectError(error.CrossProviderResume, rebuildSession(
        allocator,
        &current,
        &registry,
        .{ .resume_latest = true, .no_context_files = true },
    ));
    try testing.expectEqual(
        Provider.local,
        current.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        before_model,
        current.currentModel() orelse return error.TestUnexpectedResult,
    );
}

test "rejected startup model creates no session state and frees owned buffers" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions-not-created");
    defer allocator.free(sessions_dir);

    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "anthropic-key");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "openai-key");
    defer openai.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    try testing.expectError(
        error.ProviderMismatch,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_context_files = true,
            .model = "gpt-4o-mini",
        }),
    );

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, sessions_dir, .{}),
    );
}

test "unready explicit local provider has no filesystem or cloud fallback side effects" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions-not-created");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var base = try EnvOverride.set(allocator, "ZTTP_MLX_BASE_URL", "http://127.0.0.1:1");
    defer base.restore(allocator);
    var anthropic = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "must-not-be-used");
    defer anthropic.restore(allocator);
    var openai = try EnvOverride.set(allocator, "OPENAI_API_KEY", "must-not-be-used");
    defer openai.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    try testing.expectError(
        error.LocalServerUnavailable,
        initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_context_files = true,
            .provider = .local,
        }),
    );
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(
        io_backend.io(),
        sessions_dir,
        .{},
    ));

    // The compiler-only lane bypasses the same invalid local transport.
    var model_free = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .model_free = true,
    });
    defer model_free.deinit(allocator);
    try testing.expect(model_free.backend == .stub);
}

test "mid-turn provider failure persists one error exit without fallback" {
    const FailingClient = struct {
        calls: usize = 0,

        fn request(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: *const Transcript,
            _: ?[]const u8,
        ) anyerror!loop.ModelCallResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.LocalServerUnavailable;
        }

        fn modelClient(self: *@This()) loop.ModelClient {
            return .{ .context = self, .request_fn = request };
        }
    };

    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .provider = .local,
    });
    defer session.deinit(allocator);
    var failing: FailingClient = .{};

    try testing.expectError(error.LocalServerUnavailable, runOneTurnWithClient(
        allocator,
        &session,
        &registry,
        failing.modelClient(),
        "inspect the handler",
        null,
    ));
    try testing.expectEqual(@as(usize, 1), failing.calls);
    try testing.expectEqual(
        Provider.local,
        session.activeProvider() orelse return error.TestUnexpectedResult,
    );

    const events = try zts.file_io.readFile(
        allocator,
        session.events_path orelse return error.TestUnexpectedResult,
        1024 * 1024,
    );
    defer allocator.free(events);
    try testing.expect(std.mem.indexOf(u8, events, "\"reason\":\"error_exit\"") != null);
}

test "estimateContextTokens grows with transcript and includes the fixed allowance" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);

    // An empty transcript still reserves the non-transcript allowance.
    const empty = estimateContextTokens(&session);
    try testing.expectEqual(non_transcript_token_allowance, empty);

    try session.transcript.append(testing.allocator, .{ .user_text = "a" ** 4000 });
    const grown = estimateContextTokens(&session);
    // ~4000 bytes of text adds on the order of 1000 tokens over the allowance.
    try testing.expect(grown > empty + 500);
}

test "compact: empty transcript returns early message" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);

    const msg = try compact(testing.allocator, &session);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Nothing to compact.\n", msg);
    try testing.expectEqual(@as(usize, 0), session.transcript.len());
}

const test_compaction_summary =
    "## Goal\nContinue the implementation\n\n" ++
    "## Constraints & Preferences\n- Preserve raw proof history\n\n" ++
    "## Progress\n### Done\n- [x] Older work summarized\n\n" ++
    "### In Progress\n- [ ] Continue recent work\n\n" ++
    "### Blocked\n- None\n\n" ++
    "## Key Decisions\n- Host owns checkpoints\n\n" ++
    "## Next Steps\n1. Continue\n\n" ++
    "## Critical Context\n- Stable entry IDs remain authoritative";

const TestSummarizer = struct {
    calls: usize = 0,
    response: []const u8 = test_compaction_summary,
    failure: ?anyerror = null,
    saw_focus: bool = false,
    saw_previous_summary: bool = false,

    fn summarize(
        context: *anyopaque,
        _: std.mem.Allocator,
        request: compaction.SummaryRequest,
    ) anyerror!compaction.SummaryResponse {
        const self: *TestSummarizer = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.saw_focus = self.saw_focus or std.mem.indexOf(u8, request.user_prompt, "<focus>") != null;
        self.saw_previous_summary = self.saw_previous_summary or
            std.mem.indexOf(u8, request.user_prompt, "<previous-summary>") != null;
        if (self.failure) |failure| return failure;
        return .{
            .response = .{ .final_text = self.response },
            .usage = .{ .input_tokens = 100, .output_tokens = 50 },
        };
    }

    fn asSummarizer(self: *TestSummarizer) compaction.Summarizer {
        return .{ .context = self, .summarize_fn = summarize };
    }
};

fn appendCompactableHistory(allocator: std.mem.Allocator, session: *AgentSession) !void {
    try session.transcript.append(allocator, .{ .user_text = "old request " ** 4000 });
    try session.transcript.append(allocator, .{ .model_text = "old response " ** 4000 });
    try session.transcript.append(allocator, .{ .user_text = "recent request" });
    try session.transcript.append(allocator, .{ .model_text = "recent response" });
}

test "compact preserves raw entries and installs one active projection" {
    var session = try AgentSession.initAnthropic(testing.allocator, "test-key", "test system", null);
    defer session.deinit(testing.allocator);
    try appendCompactableHistory(testing.allocator, &session);
    const before_len = session.transcript.len();
    var summarizer: TestSummarizer = .{};

    const result = try compactDetailed(
        testing.allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        "focus on continuation safety",
        false,
    );
    try testing.expect(result == .compacted);

    try testing.expectEqual(before_len, session.transcript.len());
    const projection = session.transcript.projection orelse return error.TestExpectedProjection;
    try testing.expect(std.mem.indexOf(u8, projection.summary, "## Critical Context") != null);
    try testing.expect(std.mem.indexOf(u8, projection.summary, "<read-files>") != null);
    try testing.expectEqual(@as(transcript_mod.EntryId, 3), projection.first_kept_entry_id);
    try testing.expectEqual(@as(usize, 2), try session.transcript.activeStartIndex());
    try testing.expectEqual(@as(usize, 1), summarizer.calls);
    try testing.expect(summarizer.saw_focus);
    try testing.expectEqual(@as(usize, 0), session.last_persisted_len);
    try testing.expectEqual(@as(u64, 100), session.summary_token_totals.input_tokens);
}

test "compact checkpoint survives immediate session close and resume" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var api_key = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "test-key");
    defer api_key.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    const SourceProjection = struct {
        session_id: []u8,
        transcript_sha256: model_request.Sha256Hex,
        history_bytes: u64,
    };
    const source_projection: SourceProjection = blk: {
        var source = try initFromEnvWithSessionConfig(allocator, &registry, .{
            .no_context_files = true,
            .provider = .anthropic,
            .model = "claude-opus-4-8",
        });
        defer source.deinit(allocator);
        try appendCompactableHistory(allocator, &source);
        var summarizer: TestSummarizer = .{};
        const result = try compactDetailed(
            allocator,
            &source,
            summarizer.asSummarizer(),
            .{},
            .manual,
            null,
            false,
        );
        try testing.expect(result == .compacted);
        var snapshot = try model_request.createSnapshot(allocator, .{
            .config = .{
                .provider = .anthropic,
                .model = "claude-opus-4-8",
                .max_output_tokens = 1024,
                .system_prompt = "test system",
            },
            .transcript = &source.transcript,
        });
        defer snapshot.deinit(allocator);
        break :blk .{
            .session_id = try allocator.dupe(u8, source.session_id orelse return error.TestExpectedSession),
            .transcript_sha256 = snapshot.transcript_sha256,
            .history_bytes = snapshot.component_bytes.history,
        };
    };
    defer allocator.free(source_projection.session_id);

    var resumed = try initFromEnvWithSessionConfig(allocator, null, .{
        .no_context_files = true,
        .session_id = source_projection.session_id,
    });
    defer resumed.deinit(allocator);
    try testing.expectEqual(@as(usize, 4), resumed.transcript.len());
    const projection = resumed.transcript.projection orelse return error.TestExpectedProjection;
    try testing.expect(std.mem.indexOf(u8, projection.summary, "## Goal") != null);
    try testing.expectEqual(@as(transcript_mod.EntryId, 3), projection.first_kept_entry_id);

    var resumed_snapshot = try model_request.createSnapshot(allocator, .{
        .config = .{
            .provider = .anthropic,
            .model = "claude-opus-4-8",
            .max_output_tokens = 1024,
            .system_prompt = "test system",
        },
        .transcript = &resumed.transcript,
    });
    defer resumed_snapshot.deinit(allocator);
    try testing.expect(source_projection.transcript_sha256.eql(resumed_snapshot.transcript_sha256));
    try testing.expectEqual(source_projection.history_bytes, resumed_snapshot.component_bytes.history);
}

test "compact checkpoint write failure leaves the active projection unchanged" {
    var session = try AgentSession.initAnthropic(testing.allocator, "test-key", "test system", null);
    defer session.deinit(testing.allocator);
    try appendCompactableHistory(testing.allocator, &session);
    session.events_path = try testing.allocator.dupe(u8, "/nonexistent/zttp-events/checkpoint.jsonl");
    var summarizer: TestSummarizer = .{};

    const result = try compactDetailed(
        testing.allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expectEqual(error.FileOpenFailed, result.failed);
    try testing.expect(session.transcript.projection == null);
    try testing.expectEqual(@as(usize, 4), session.transcript.len());
}

const test_summary_tool_calls = [_]turn.ToolCall{.{
    .id = "summary_tool",
    .name = "workspace_read_file",
    .args_json = "{}",
}};

const ToolCallingSummarizer = struct {
    fn summarize(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: compaction.SummaryRequest,
    ) anyerror!compaction.SummaryResponse {
        return .{ .response = .{ .tool_calls = &test_summary_tool_calls } };
    }
};

test "compact fails closed on malformed tool-calling and provider-error summaries" {
    const allocator = testing.allocator;

    var malformed_session = try AgentSession.initAnthropic(allocator, "test-key", "test system", null);
    defer malformed_session.deinit(allocator);
    try appendCompactableHistory(allocator, &malformed_session);
    var malformed: TestSummarizer = .{ .response = "## Goal\nmissing required sections" };
    const malformed_result = try compactDetailed(
        allocator,
        &malformed_session,
        malformed.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expectEqual(error.MalformedSummary, malformed_result.failed);
    try testing.expect(malformed_session.transcript.projection == null);
    try testing.expectEqual(@as(u64, 100), malformed_session.summary_token_totals.input_tokens);

    var tool_session = try AgentSession.initAnthropic(allocator, "test-key", "test system", null);
    defer tool_session.deinit(allocator);
    try appendCompactableHistory(allocator, &tool_session);
    var tool_context: u8 = 0;
    const tool_result = try compactDetailed(
        allocator,
        &tool_session,
        .{ .context = &tool_context, .summarize_fn = ToolCallingSummarizer.summarize },
        .{},
        .manual,
        null,
        false,
    );
    try testing.expectEqual(error.SummaryReturnedToolCall, tool_result.failed);
    try testing.expect(tool_session.transcript.projection == null);

    var provider_session = try AgentSession.initAnthropic(allocator, "test-key", "test system", null);
    defer provider_session.deinit(allocator);
    try appendCompactableHistory(allocator, &provider_session);
    var provider: TestSummarizer = .{ .failure = error.TestSummaryProviderFailure };
    const provider_result = try compactDetailed(
        allocator,
        &provider_session,
        provider.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expectEqual(error.TestSummaryProviderFailure, provider_result.failed);
    try testing.expect(provider_session.transcript.projection == null);
    try testing.expectEqual(@as(u64, 0), provider_session.summary_token_totals.input_tokens);
}

const SplitSummarizer = struct {
    calls: usize = 0,

    fn summarize(
        context: *anyopaque,
        _: std.mem.Allocator,
        request: compaction.SummaryRequest,
    ) anyerror!compaction.SummaryResponse {
        const self: *SplitSummarizer = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (!std.mem.eql(u8, request.system_prompt, compaction.prefix_system_prompt)) {
            return error.TestExpectedPrefixPrompt;
        }
        if (request.max_output_tokens != 4096) return error.TestExpectedSummaryAllowance;
        return .{
            .response = .{ .final_text = "## Original Request\nInspect and continue\n\n" ++
                "## Early Progress\nRead planning context\n\n" ++
                "## Context for Suffix\nThe retained tool call must run next" },
            .usage = .{ .input_tokens = 80, .output_tokens = 30 },
        };
    }

    fn asSummarizer(self: *SplitSummarizer) compaction.Summarizer {
        return .{ .context = self, .summarize_fn = summarize };
    }
};

test "compact splits one oversized turn before a closed tool pair" {
    const allocator = testing.allocator;
    var session = try AgentSession.initAnthropic(allocator, "test-key", "test system", null);
    defer session.deinit(allocator);
    try session.transcript.append(allocator, .{ .user_text = "inspect and continue" });
    try session.transcript.append(allocator, .{ .model_text = "early work " ** 10_000 });
    const calls = [_]turn.ToolCall{.{
        .id = "call_1",
        .name = "workspace_read_file",
        .args_json = "{\"path\":\"handler.ts\"}",
    }};
    try session.transcript.append(allocator, .{ .assistant_tool_use = &calls });
    try session.transcript.append(allocator, .{ .tool_result = .{
        .tool_use_id = "call_1",
        .tool_name = "workspace_read_file",
        .ok = true,
        .llm_text = "retained result",
    } });
    try session.transcript.append(allocator, .{ .model_text = "retained continuation" });
    var summarizer: SplitSummarizer = .{};
    const result = try compactDetailed(
        allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expect(result == .compacted);
    try testing.expectEqual(@as(usize, 1), summarizer.calls);
    const projection = session.transcript.projection orelse return error.TestExpectedProjection;
    try testing.expectEqual(@as(transcript_mod.EntryId, 3), projection.first_kept_entry_id);
    try testing.expect(std.mem.indexOf(u8, projection.summary, "## Original Request") != null);
    try testing.expectEqual(@as(usize, 0), projection.read_files.len);
    try testing.expect(session.transcript.at(2).* == .assistant_tool_use);
    try testing.expect(session.transcript.at(3).* == .tool_result);
}

test "compact rejects an oversized standalone summary request before the effect" {
    const allocator = testing.allocator;
    var session = try AgentSession.initAnthropic(allocator, "test-key", "test system", null);
    defer session.deinit(allocator);
    const large = try allocator.alloc(u8, 400 * 1024);
    defer allocator.free(large);
    @memset(large, 'x');
    try session.transcript.append(allocator, .{ .user_text = large });
    try session.transcript.append(allocator, .{ .model_text = large });
    try session.transcript.append(allocator, .{ .user_text = "recent" });
    try session.transcript.append(allocator, .{ .model_text = "keep" });
    var summarizer: TestSummarizer = .{};
    const result = try compactDetailed(
        allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expectEqual(error.RequestTooLarge, result.failed);
    try testing.expectEqual(@as(usize, 0), summarizer.calls);
    try testing.expect(session.transcript.projection == null);
}

test "fork: ephemeral session returns error message" {
    var session = AgentSession.initStub();
    defer session.deinit(testing.allocator);

    const msg = try fork(testing.allocator, &session);
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "ephemeral") != null);
}

test "fork copies raw ancestry and projection checkpoints before independent divergence" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions.restore(allocator);
    var api_key = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "test-key");
    defer api_key.restore(allocator);
    var registry: Registry = .{};
    defer registry.deinit(allocator);

    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_context_files = true,
        .provider = .anthropic,
        .model = "claude-opus-4-8",
    });
    defer session.deinit(allocator);
    var summarizer: TestSummarizer = .{};
    try appendCompactableHistory(allocator, &session);
    const first = try compactDetailed(
        allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expect(first == .compacted);
    try session.transcript.append(allocator, .{ .user_text = "next old request " ** 4000 });
    try session.transcript.append(allocator, .{ .model_text = "next old response " ** 4000 });
    try session.transcript.append(allocator, .{ .user_text = "newest request" });
    try session.transcript.append(allocator, .{ .model_text = "newest response" });
    const repeated = try compactDetailed(
        allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expect(repeated == .compacted);
    try testing.expect(summarizer.saw_previous_summary);

    const source_events_path = try allocator.dupe(u8, session.events_path orelse return error.TestExpectedEvents);
    defer allocator.free(source_events_path);
    const source_before = try zts.file_io.readFile(allocator, source_events_path, 1024 * 1024);
    defer allocator.free(source_before);

    const forked = try fork(allocator, &session);
    defer allocator.free(forked);
    const fork_events_path = session.events_path orelse return error.TestExpectedEvents;
    const fork_before = try zts.file_io.readFile(allocator, fork_events_path, 1024 * 1024);
    defer allocator.free(fork_before);
    try testing.expectEqualSlices(u8, source_before, fork_before);
    try testing.expect(session.transcript.projection != null);

    try appendCompactableHistory(allocator, &session);
    const compacted_again = try compactDetailed(
        allocator,
        &session,
        summarizer.asSummarizer(),
        .{},
        .manual,
        null,
        false,
    );
    try testing.expect(compacted_again == .compacted);
    const source_after = try zts.file_io.readFile(allocator, source_events_path, 1024 * 1024);
    defer allocator.free(source_after);
    try testing.expectEqualSlices(u8, source_before, source_after);
    const fork_after = try zts.file_io.readFile(allocator, fork_events_path, 1024 * 1024);
    defer allocator.free(fork_after);
    try testing.expect(fork_after.len > fork_before.len);
}

test "initFromEnvWithSessionConfig appends AGENTS and CLAUDE files as read-only project context" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    try writeTestFile(allocator, tmp.abs_path, "AGENTS.md", "AGENTS_MARKER_XYZ");
    try writeTestFile(allocator, tmp.abs_path, "CLAUDE.md", "CLAUDE_MARKER_ABC");

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var api_override = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "test-fixture-key");
    defer api_override.restore(allocator);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .provider = .anthropic,
    });
    defer session.deinit(allocator);

    try testing.expect(session.backend == .anthropic);
    const actual = session.system_prompt_owned orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, actual, "AGENTS_MARKER_XYZ") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "CLAUDE_MARKER_ABC") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "PROJECT INSTRUCTIONS") != null);
    // Persona identity still intact - project context never overrides it.
    try testing.expect(std.mem.indexOf(u8, actual, "native zts coding agent") != null);
    try testing.expect(std.mem.indexOf(u8, actual, "END OF PERSONA") != null);
}

test "initFromEnvWithSessionConfig: no_context_files suppresses AGENTS and CLAUDE loading" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    try writeTestFile(allocator, tmp.abs_path, "AGENTS.md", "SHOULD_NOT_APPEAR_A");
    try writeTestFile(allocator, tmp.abs_path, "CLAUDE.md", "SHOULD_NOT_APPEAR_B");

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var api_override = try EnvOverride.set(allocator, "ANTHROPIC_API_KEY", "test-fixture-key");
    defer api_override.restore(allocator);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    var session = try initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .provider = .anthropic,
    });
    defer session.deinit(allocator);

    const actual = session.system_prompt_owned orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, actual, "SHOULD_NOT_APPEAR_A") == null);
    try testing.expect(std.mem.indexOf(u8, actual, "SHOULD_NOT_APPEAR_B") == null);
    try testing.expect(std.mem.indexOf(u8, actual, "PROJECT CONTEXT") == null);
}

test "initFromEnvWithSessionConfig stamps current policy_hash into meta.json" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const sessions_dir = try std.fs.path.join(allocator, &.{ tmp.abs_path, "sessions" });
    defer allocator.free(sessions_dir);
    var env_override = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer env_override.restore(allocator);
    var api_override = try EnvOverride.unset(allocator, "ANTHROPIC_API_KEY");
    defer api_override.restore(allocator);

    const ws_dir = try std.fs.path.join(allocator, &.{ tmp.abs_path, "ws" });
    defer allocator.free(ws_dir);
    {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), ws_dir);
    }

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(ws_dir);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var session = try initFromEnvWithSessionConfig(allocator, null, .{});
    defer session.deinit(allocator);

    const meta_path = session.meta_path orelse return error.TestUnexpectedResult;
    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);

    const saved = meta.policy_hash orelse return error.TestExpected;
    const current = expert_meta.compute().policy_hash;
    try testing.expectEqualStrings(current[0..], saved);
}

test "initFromEnvWithSessionConfig: resume with drifted hash injects a system_note" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const sessions_dir = try std.fs.path.join(allocator, &.{ tmp.abs_path, "sessions" });
    defer allocator.free(sessions_dir);
    var env_override = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer env_override.restore(allocator);

    const ws_dir = try std.fs.path.join(allocator, &.{ tmp.abs_path, "ws" });
    defer allocator.free(ws_dir);
    {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), ws_dir);
    }

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(ws_dir);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    // Create a session so meta.json exists, then materialize an empty
    // events.jsonl for reconstruction without depending on a live model
    // backend during this test.
    const captured_meta_path: []u8 = blk: {
        var s = try initFromEnvWithSessionConfig(allocator, null, .{});
        defer s.deinit(allocator);
        try zts.file_io.writeFile(allocator, s.events_path orelse return error.TestUnexpectedResult, "");
        break :blk try allocator.dupe(u8, s.meta_path orelse return error.TestUnexpectedResult);
    };
    defer allocator.free(captured_meta_path);

    // Forge a drifted hash into the stored meta, then resume.
    var original = try session_events.readMeta(allocator, captured_meta_path);
    defer session_events.freeMeta(allocator, &original);
    const drifted_hash = "b" ** 64;
    try session_events.writeMeta(allocator, captured_meta_path, .{
        .session_id = original.session_id,
        .workspace_realpath = original.workspace_realpath,
        .created_at_unix_ms = original.created_at_unix_ms,
        .parent_id = original.parent_id,
        .policy_hash = drifted_hash,
        .provider = original.provider,
        .model = original.model,
    });

    var resumed = try initFromEnvWithSessionConfig(allocator, null, .{ .resume_latest = true });
    defer resumed.deinit(allocator);

    var found_note = false;
    for (resumed.transcript.entries.items) |*entry| {
        switch (entry.*) {
            .system_note => |body| {
                if (std.mem.indexOf(u8, body, POLICY_DRIFT_PREFIX) != null) found_note = true;
            },
            else => {},
        }
    }
    try testing.expect(found_note);

    // After drift handling, meta should carry the current hash so a second
    // resume does not re-warn against the already-acknowledged drift.
    var post = try session_events.readMeta(allocator, captured_meta_path);
    defer session_events.freeMeta(allocator, &post);
    const current = expert_meta.compute().policy_hash;
    const stamped = post.policy_hash orelse return error.TestExpected;
    try testing.expectEqualStrings(current[0..], stamped);
}

test "a loopback endpoint override is reported as local, a remote one is not" {
    const local_urls = [_][]const u8{
        "http://127.0.0.1:11434/v1/responses",
        "http://localhost:8080/v1/responses",
        "http://[::1]:11434/v1/responses",
    };
    for (local_urls) |url| {
        const session = AgentSession{
            .backend = .{ .openai = .{ .config = .{
                .api_key = "test",
                .model = "gpt-4o-mini",
                .system_prompt = "test",
                .base_url = url,
                .max_tokens = 1,
            } } },
        };
        const dest = destinationForSession(&session);
        try testing.expect(dest == .openai_custom);
        try testing.expect(dest.isLocal());
    }

    // A proxy in front of a hosted provider is still off-machine, and the
    // banner must not tell the user their source stays put.
    const session = AgentSession{
        .backend = .{ .openai = .{ .config = .{
            .api_key = "test",
            .model = "gpt-4o-mini",
            .system_prompt = "test",
            .base_url = "https://proxy.example.com/v1/responses",
            .max_tokens = 1,
        } } },
    };
    const dest = destinationForSession(&session);
    try testing.expect(dest == .openai_custom);
    try testing.expect(!dest.isLocal());
}
