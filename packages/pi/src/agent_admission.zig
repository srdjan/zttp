//! Request admission for an `AgentSession`: the provider-neutral request
//! controller, token budgets, threshold compaction, and overflow recovery.

const std = @import("std");
const loop = @import("loop.zig");
const turn = @import("turn.zig");
const transcript_mod = @import("transcript.zig");
const model_request = @import("providers/model_request.zig");
const compaction = @import("compaction.zig");
const context_budget = @import("context_budget.zig");
const chat_completions = @import("providers/chat_completions.zig");
const models_registry = @import("providers/models.zig");
const session_events = @import("session/events.zig");
const agent = @import("agent.zig");
const agent_compaction = @import("agent_compaction.zig");

const Transcript = transcript_mod.Transcript;
const Provider = models_registry.Provider;
const AgentSession = agent.AgentSession;
const CompactionPhase = agent.CompactionPhase;
const CompactResult = agent_compaction.CompactResult;
const compactTranscriptDetailed = agent_compaction.compactTranscriptDetailed;
const ReductionOutcome = agent_compaction.ReductionOutcome;

/// Provider-neutral production request controller. Injected clients, notably
/// deterministic simulator replay, use this boundary so request admission,
/// threshold compaction, and PromptTooLong recovery cannot drift from live
/// providers.
pub const RequestController = struct {
    allocator: std.mem.Allocator,
    session: *AgentSession,
    raw_client: loop.ModelClient,
    summarizer: ?compaction.Summarizer,

    pub fn asModelClient(self: *RequestController) loop.ModelClient {
        return .{
            .context = self,
            .request_fn = request,
            .set_deadline_fn = setDeadline,
        };
    }

    fn setDeadline(context: *anyopaque, deadline_ms: ?i64) void {
        const self: *RequestController = @ptrCast(@alignCast(context));
        self.session.request_deadline_ms = deadline_ms;
    }

    fn request(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *RequestController = @ptrCast(@alignCast(context));
        return requestNormalWith(
            self.allocator,
            arena,
            self.session,
            self.raw_client,
            self.summarizer,
            @constCast(transcript),
            extra_user_text,
        );
    }
};

/// A request is admitted on both sizes it can be measured at: the anchored
/// stable-usage estimate and the fresh conservative estimate. Either can be the
/// one the provider agrees with, so the larger governs the hard limit.
fn exceedsHardLimit(selected_tokens: u64, budget: context_budget.RequestBudget) bool {
    return @max(selected_tokens, budget.tokens.total) > budget.limits.hard_input_tokens;
}

/// The compaction threshold sits at or below the hard limit, so a selected
/// estimate over the hard limit is already over the admitted limit.
fn needsReduction(
    selected_tokens: u64,
    budget: context_budget.RequestBudget,
    admitted_limit: u64,
) bool {
    return selected_tokens > admitted_limit or
        budget.tokens.total > budget.limits.hard_input_tokens;
}

pub fn requestNormalWith(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    session: *AgentSession,
    raw_client: loop.ModelClient,
    maybe_summarizer: ?compaction.Summarizer,
    transcript: *transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) !loop.ModelCallResult {
    resetOverflowRecoveryForCurrentTurn(session, transcript);

    var budget = try normalRequestBudget(allocator, session, transcript, extra_user_text);
    var selected_tokens = try selectedNormalInputTokens(session, budget);
    const hard_limit = budget.limits.hard_input_tokens;
    const admitted_limit = @min(session.compaction_settings.max_input_tokens, hard_limit);

    if (session.compaction_enabled and needsReduction(selected_tokens, budget, admitted_limit)) {
        const reduction = try reducePendingRequest(
            allocator,
            session,
            transcript,
            maybe_summarizer,
            .threshold,
            extra_user_text,
            false,
            selected_tokens,
            hard_limit,
        );
        if (reduction == .compacted) {
            budget = try normalRequestBudget(allocator, session, transcript, extra_user_text);
            selected_tokens = try selectedNormalInputTokens(session, budget);
            if (needsReduction(selected_tokens, budget, admitted_limit)) {
                return error.CompactedRequestStillTooLarge;
            }
        }
    }

    if (exceedsHardLimit(selected_tokens, budget)) {
        return error.RequestTooLarge;
    }

    try session.prepareProviderCall();
    session.normal_request_attempt_count +|= 1;
    const first = raw_client.request(arena, transcript, extra_user_text) catch |err| {
        // A client admits on its own conservative byte-derived budget, which the
        // calibration gate permits to sit above the stable-usage estimate this
        // controller admitted on. Both of its refusals are the same overflow and
        // both are recoverable by compacting; treating only PromptTooLong as one
        // left the stale anchor in place and failed every later turn identically.
        const overflowed = err == error.PromptTooLong or err == error.RequestTooLarge;
        if (!overflowed or !session.compaction_enabled or session.overflow_recovery_used) {
            return err;
        }
        session.overflow_recovery_used = true;
        const reduction = reducePendingRequest(
            allocator,
            session,
            transcript,
            maybe_summarizer,
            .overflow,
            extra_user_text,
            true,
            selected_tokens,
            hard_limit,
        ) catch |reduction_err| return reduction_err;
        if (reduction != .compacted) return err;

        budget = try normalRequestBudget(allocator, session, transcript, extra_user_text);
        selected_tokens = try selectedNormalInputTokens(session, budget);
        if (exceedsHardLimit(selected_tokens, budget)) {
            return error.RequestTooLarge;
        }

        try session.prepareProviderCall();
        session.normal_request_attempt_count +|= 1;
        const retried = try raw_client.request(arena, transcript, extra_user_text);
        try rememberNormalInput(session, budget, retried.usage);
        return retried;
    };
    try rememberNormalInput(session, budget, first.usage);
    return first;
}

fn reducePendingRequest(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    transcript: *transcript_mod.Transcript,
    maybe_summarizer: ?compaction.Summarizer,
    reason: session_events.CompactionReason,
    extra_user_text: ?[]const u8,
    will_retry: bool,
    selected_tokens: u64,
    hard_limit: u64,
) !ReductionOutcome {
    notifyCompaction(session, .start, reason, null);
    const result = compactTranscriptDetailed(
        allocator,
        session,
        transcript,
        maybe_summarizer,
        session.compaction_settings,
        reason,
        null,
        will_retry,
        extra_user_text,
    ) catch |err| {
        const failed: CompactResult = .{ .failed = err };
        notifyCompaction(session, .end, reason, &failed);
        return err;
    };
    notifyCompaction(session, .end, reason, &result);
    return switch (result) {
        .compacted => .compacted,
        .not_compactable => |why| switch (why) {
            .oversized_current_user, .unresolved_tool_pair => if (selected_tokens <= hard_limit)
                .protected_passthrough
            else
                error.RequestTooLarge,
            .no_valid_cut => error.NoValidCompactionCut,
            .invalid_tool_pair => error.InvalidCompactionToolPair,
        },
        .no_change => if (reason == .threshold and selected_tokens <= hard_limit)
            .protected_passthrough
        else
            error.CompactionMadeNoProgress,
        .unavailable => error.CompactionUnavailable,
        .failed => |failure| failure,
    };
}

pub fn notifyCompaction(
    session: *AgentSession,
    phase: CompactionPhase,
    reason: session_events.CompactionReason,
    result: ?*const CompactResult,
) void {
    const observer = session.compaction_observer orelse return;
    observer.on_event(observer.context, phase, reason, result);
}

fn selectedNormalInputTokens(
    session: *const AgentSession,
    current: context_budget.RequestBudget,
) !u64 {
    const provider = session.resolved_provider orelse return current.tokens.total;
    const model = session.resolved_model orelse return current.tokens.total;
    const epoch: context_budget.UsageEpoch = .{
        .provider = provider,
        .model = model.id,
        .checkpoint_generation = session.checkpoint_generation,
    };
    return (try context_budget.selectInputEstimate(.{
        .epoch = epoch,
        .current_budget = current,
        .anchor = session.last_normal_anchor,
        .compaction_bridge = session.compaction_bridge_anchor,
    })).tokens;
}

fn rememberNormalInput(
    session: *AgentSession,
    budget: context_budget.RequestBudget,
    usage: turn.Usage,
) !void {
    const provider = session.resolved_provider orelse return;
    const model = session.resolved_model orelse return;
    const reported_input = try context_budget.normalizeLogicalInput(provider, usage);
    if (reported_input == 0) {
        session.last_normal_anchor = null;
        session.compaction_bridge_anchor = null;
        return;
    }
    const epoch: context_budget.UsageEpoch = .{
        .provider = provider,
        .model = model.id,
        .checkpoint_generation = session.checkpoint_generation,
    };
    const observed = try context_budget.observeLogicalInput(.{
        .epoch = epoch,
        .current_budget = budget,
        .anchor = session.last_normal_anchor,
        .compaction_bridge = session.compaction_bridge_anchor,
        .reported_tokens = reported_input,
    });
    session.last_normal_anchor = .{
        .usage = .{
            .epoch = epoch,
            .logical_input_tokens = observed.logical_input_tokens,
        },
        .budget = budget,
    };
    session.compaction_bridge_anchor = null;
}

fn resetOverflowRecoveryForCurrentTurn(
    session: *AgentSession,
    transcript: *const transcript_mod.Transcript,
) void {
    const turn_entry_id = currentExternalTurnEntryId(transcript);
    if (turn_entry_id == session.overflow_turn_entry_id) return;
    session.overflow_turn_entry_id = turn_entry_id;
    session.overflow_recovery_used = false;
}

fn currentExternalTurnEntryId(transcript: *const transcript_mod.Transcript) transcript_mod.EntryId {
    var index = transcript.len();
    while (index > 0) {
        index -= 1;
        if (transcript.at(index).* == .user_text) return transcript.entryIdAt(index);
    }
    return 0;
}

pub fn requestBudgetForProjection(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    transcript: *const transcript_mod.Transcript,
    projection_override: ?model_request.ProjectionOverride,
) !context_budget.RequestBudget {
    return requestBudgetForConfig(
        allocator,
        try session.requestConfig(),
        transcript,
        projection_override,
        null,
        false,
    );
}

pub fn normalRequestBudget(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) !context_budget.RequestBudget {
    return requestBudgetForConfig(
        allocator,
        try session.requestConfig(),
        transcript,
        null,
        extra_user_text,
        false,
    );
}

pub fn admitSummaryRequest(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    request: compaction.SummaryRequest,
) !void {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    try transcript.append(allocator, .{ .user_text = request.user_prompt });
    var config = try session.requestConfig();
    config.system_prompt = request.system_prompt;
    config.tools_json = null;
    config.max_output_tokens = request.max_output_tokens;
    config.purpose = .summarization;
    config.cache_policy = .disabled;
    _ = try requestBudgetForConfig(allocator, config, &transcript, null, null, true);
}

pub fn requestBudgetForConfig(
    allocator: std.mem.Allocator,
    config: model_request.Config,
    transcript: *const transcript_mod.Transcript,
    projection_override: ?model_request.ProjectionOverride,
    extra_user_text: ?[]const u8,
    require_hard_admission: bool,
) !context_budget.RequestBudget {
    var snapshot = try model_request.createSnapshot(allocator, .{
        .config = config,
        .transcript = transcript,
        .extra_user_text = extra_user_text,
        .projection_override = projection_override,
        .use_projection_override = projection_override != null,
    });
    defer snapshot.deinit(allocator);
    const body = try chat_completions.buildRequestBodyFromSnapshot(allocator, &snapshot);
    defer allocator.free(body);
    try snapshot.completePreparation(body);
    if (require_hard_admission) try snapshot.requireHardAdmission();
    return snapshot.budget orelse error.RequestNotPrepared;
}

pub fn validateCompactionCapacityForConfig(
    allocator: std.mem.Allocator,
    settings: compaction.Settings,
    model: *const models_registry.Model,
    config: model_request.Config,
) !void {
    var empty_transcript: transcript_mod.Transcript = .{};
    defer empty_transcript.deinit(allocator);
    const fixed_budget = try requestBudgetForConfig(
        allocator,
        config,
        &empty_transcript,
        null,
        null,
        false,
    );
    _ = try compaction.deriveCapacity(
        settings,
        model,
        fixed_budget.tokens.system +| fixed_budget.tokens.tools,
        fixed_budget.tokens.framing,
    );
}
