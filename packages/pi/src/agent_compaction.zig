//! Manual and automatic compaction of an `AgentSession` transcript, with the
//! result types.

const std = @import("std");
const turn = @import("turn.zig");
const transcript_mod = @import("transcript.zig");
const compaction = @import("compaction.zig");
const session_events = @import("session/events.zig");
const agent = @import("agent.zig");
const agent_admission = @import("agent_admission.zig");

const Transcript = transcript_mod.Transcript;
const AgentSession = agent.AgentSession;
const admitSummaryRequest = agent_admission.admitSummaryRequest;
const normalRequestBudget = agent_admission.normalRequestBudget;
const notifyCompaction = agent_admission.notifyCompaction;
const requestBudgetForConfig = agent_admission.requestBudgetForConfig;
const requestBudgetForProjection = agent_admission.requestBudgetForProjection;

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
/// same controller's structured result directly to command surfaces.
pub fn compact(
    allocator: std.mem.Allocator,
    session: *AgentSession,
) ![]u8 {
    const result = try compactManual(allocator, session, null);
    return renderCompactResult(allocator, result);
}

pub fn compactManual(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    focus: ?[]const u8,
) !CompactResult {
    notifyCompaction(session, .start, .manual, null);
    const result = compactDetailed(
        allocator,
        session,
        session.summarizer(),
        session.compaction_settings,
        .manual,
        focus,
        false,
    ) catch |err| {
        const failed: CompactResult = .{ .failed = err };
        notifyCompaction(session, .end, .manual, &failed);
        return err;
    };
    notifyCompaction(session, .end, .manual, &result);
    return result;
}

pub fn renderCompactResult(
    allocator: std.mem.Allocator,
    result: CompactResult,
) ![]u8 {
    return switch (result) {
        .compacted => |details| allocator.print("Compacted context at entry {d}: {d} -> {d} estimated tokens.\n", .{ details.first_kept_entry_id, details.tokens_before, details.estimated_tokens_after }),
        .no_change => allocator.dupe(u8, "Nothing to compact.\n"),
        .not_compactable => |reason| allocator.print("Context is not compactable: {s}.\n", .{@tagName(reason)}),
        .unavailable => allocator.dupe(u8, "Compaction requires an active model backend.\n"),
        .failed => |failure| allocator.print("Compaction failed: {s}.\n", .{@errorName(failure)}),
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
    return compactTranscriptDetailed(
        allocator,
        session,
        &session.transcript,
        maybe_summarizer,
        settings,
        reason,
        focus,
        will_retry,
        null,
    );
}

pub fn compactTranscriptDetailed(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    tr: *transcript_mod.Transcript,
    maybe_summarizer: ?compaction.Summarizer,
    settings: compaction.Settings,
    reason: session_events.CompactionReason,
    focus: ?[]const u8,
    will_retry: bool,
    pending_extra_user_text: ?[]const u8,
) !CompactResult {
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
    const current_budget = try normalRequestBudget(
        allocator,
        session,
        tr,
        pending_extra_user_text,
    );
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
        const validated_summary = switch (response.response) {
            .final_text => |text| text,
            .tool_calls => return .{ .failed = error.SummaryReturnedToolCall },
            .change_set => return .{ .failed = error.SummaryReturnedEdit },
        };
        compaction.validateRegularSummary(validated_summary) catch |err| return .{ .failed = err };
        regular_summary = validated_summary;
    }

    var prefix_summary: ?[]const u8 = null;
    if (ready.prefix_start) |prefix_start| {
        const prefix_end = ready.prefix_end orelse return .{ .failed = error.InvalidCompactionSpan };
        const conversation = try compaction.serializeSpan(
            temporary,
            tr,
            prefix_start,
            prefix_end,
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
        const validated_summary = switch (response.response) {
            .final_text => |text| text,
            .tool_calls => return .{ .failed = error.SummaryReturnedToolCall },
            .change_set => return .{ .failed = error.SummaryReturnedEdit },
        };
        compaction.validatePrefixSummary(validated_summary) catch |err| return .{ .failed = err };
        prefix_summary = validated_summary;
    }

    const summary = try compaction.assembleSummary(
        allocator,
        regular_summary,
        prefix_summary,
        file_ops,
    );
    var summary_owned = true;
    defer if (summary_owned) allocator.free(summary);
    const after_budget = try requestBudgetForConfig(
        allocator,
        try session.requestConfig(),
        tr,
        .{
            .summary = summary,
            .first_kept_entry_id = ready.first_kept_entry_id,
        },
        pending_extra_user_text,
        false,
    );
    if (after_budget.tokens.total > capacity.admitted_input_tokens) {
        return .{ .failed = error.CompactedRequestStillTooLarge };
    }

    const persistent_transcript = tr == &session.transcript;
    if (persistent_transcript and session.events_path != null) {
        while (session.last_persisted_len < tr.len()) : (session.last_persisted_len += 1) {
            session.appendPersistedEntry(
                allocator,
                tr.entryIdAt(session.last_persisted_len),
                tr.at(session.last_persisted_len),
            ) catch |err| return .{ .failed = err };
        }
        session.appendPersistedEvent(allocator, .{ .compaction_checkpoint = .{
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
    session.checkpoint_generation +|= 1;
    session.compaction_bridge_anchor = session.last_normal_anchor;
    session.last_normal_anchor = null;
    const details: CompactedDetails = .{
        .reason = reason,
        .first_kept_entry_id = ready.first_kept_entry_id,
        .tokens_before = current_budget.tokens.total,
        .estimated_tokens_after = after_budget.tokens.total,
        .summary_usage = summary_usage,
    };
    session.compaction_sequence +|= 1;
    session.last_compaction = details;
    return .{ .compacted = details };
}

fn callSummarizer(
    session: *AgentSession,
    summarizer: compaction.Summarizer,
    arena: std.mem.Allocator,
    request: compaction.SummaryRequest,
) !compaction.SummaryResponse {
    try session.prepareProviderCall();
    session.summary_attempt_count +|= 1;
    const response = try summarizer.summarize(arena, request);
    session.summary_token_totals.add(response.usage);
    session.token_totals.add(response.usage);
    return response;
}

pub const ReductionOutcome = enum {
    compacted,
    protected_passthrough,
};
