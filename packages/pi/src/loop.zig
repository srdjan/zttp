//! Expert loop driver. Pumps transcript state, Anthropic replies, compiler
//! veto results, and structured tool batches through `turn.TurnMachine`.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const turn = @import("turn.zig");
const transcript_mod = @import("transcript.zig");
const registry_mod = @import("registry/registry.zig");
const ui_payload_mod = @import("ui_payload.zig");
const zts = @import("zts");
const file_io = zts.file_io;
const propose_change_set = @import("providers/anthropic/propose_change_set.zig");
const tools_common = @import("tools/common.zig");
const json_writer = @import("providers/json_writer.zig");
const session_events = @import("session/events.zig");
const expert_workflow = @import("expert_workflow.zig");
const codegen_types = @import("expert_codegen_types.zig");
const auto_repair = @import("auto_repair.zig");
const pi_goal_candidate = @import("tools/pi_goal_candidate.zig");
const compaction = @import("compaction.zig");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const aggregate_proof = @import("aggregate_proof.zig");
const change_transaction = @import("change_transaction.zig");
const change_set_receipt = @import("change_set_receipt.zig");
const contract_gate = @import("contract_gate.zig");
const gate_record = @import("gate_record.zig");

pub const ModelCallResult = struct {
    reply: turn.AssistantReply,
    usage: turn.Usage = .{},
    /// The provider's stop reason for this roundtrip ("end_turn", "tool_use",
    /// "max_tokens", ...). Threaded through so the loop can distinguish an
    /// output-truncated reply from a normal one. Null for clients that do not
    /// report it (cassette/stub).
    stop_reason: ?[]const u8 = null,
};

pub const ModelClient = struct {
    context: *anyopaque,
    request_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!ModelCallResult,
    set_deadline_fn: ?*const fn (ctx: *anyopaque, deadline_ms: ?i64) void = null,

    pub fn request(
        self: ModelClient,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !ModelCallResult {
        return self.request_fn(self.context, arena, transcript, extra_user_text);
    }

    pub fn setDeadline(self: ModelClient, deadline_ms: ?i64) void {
        const set_deadline = self.set_deadline_fn orelse return;
        set_deadline(self.context, deadline_ms);
    }
};

/// What the user sees before approving a verified edit. Carries enough to make
/// an informed decision: the target file, the pre- and post-edit bytes (so a
/// surface can show a diff or change size), and the proven properties the edit
/// established. Built only on the interactive `.ask` path; auto policies ignore
/// it. `after` is the exact bytes that will be written if approved.
pub const ChangePreview = struct {
    file: []const u8,
    before: ?[]const u8 = null,
    after: []const u8 = "",
    rewrite_trace: []const []u8 = &.{},
};

pub const ChangeSetApprovalPreview = struct {
    proof_id: []const u8,
    changes: []const ChangePreview,
    system_proven: bool,
};

pub const ApprovalFn = union(enum) {
    bare: *const fn (preview: ChangeSetApprovalPreview) anyerror!bool,
    contextual: struct {
        context: *anyopaque,
        func: *const fn (context: *anyopaque, preview: ChangeSetApprovalPreview) anyerror!bool,
    },

    pub fn fromFn(func: *const fn (preview: ChangeSetApprovalPreview) anyerror!bool) ApprovalFn {
        return .{ .bare = func };
    }

    pub fn call(self: ApprovalFn, preview: ChangeSetApprovalPreview) anyerror!bool {
        return switch (self) {
            .bare => |func| func(preview),
            .contextual => |wrapped| wrapped.func(wrapped.context, preview),
        };
    }
};

pub const ApprovalPolicy = enum { ask, auto_approve, auto_reject };

pub const ReceiptDurability = enum {
    /// The workspace transaction receipt is the durable authority. Used by
    /// no-session and direct harness callers.
    workspace,
    /// A session journal must persist the receipt before the workspace journal
    /// can acknowledge it. The agent layer performs that acknowledgement.
    session_journal,
};

pub fn autoApprove(preview: ChangeSetApprovalPreview) anyerror!bool {
    _ = preview;
    return true;
}

pub fn autoReject(preview: ChangeSetApprovalPreview) anyerror!bool {
    _ = preview;
    return false;
}

/// Appended to the bare "agent budget exhausted before a final answer" line so a
/// turn that runs out of model round-trips ends with a concrete next step rather
/// than a dead end.
pub const budget_exhausted_next_step =
    "Next: re-run the request, narrow it to one change at a time, or run " ++
    "`zttp check <handler>` to see the remaining diagnostics directly.";

/// Appended to the veto-exhaustion diagnostic box so a turn that burns every
/// verification attempt ends with a recoverable next step rather than a silent
/// dead end. Mirrors `budget_exhausted_next_step`.
pub const veto_exhausted_next_step =
    "Next: narrow the ask to one change, fix it directly " ++
    "(`zttp check <handler>` shows the full diagnostic), or rephrase the goal. " ++
    "The attempts are saved in your session ledger (/ledger).";

/// One-line, actionable remediation for a model-backend error, or null for
/// errors that are not provider failures (local I/O, parse, etc.). The wire
/// layer maps HTTP status and in-stream errors to these typed errors; the
/// interactive and `--print` catch sites render this hint so the user sees what
/// to do instead of a bare CamelCase error name.
pub fn providerErrorRemediation(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.AuthFailed => "Authentication failed. Check `zttp auth status`, then configure the explicitly selected cloud provider.",
        error.InsufficientCredit => "The provider rejected the request for insufficient credit. Check your account credit balance.",
        error.RateLimited => "Rate limited by the provider. Wait a moment and try again.",
        error.ModelNotFound => "The configured model was not found. Switch with `/model <id>` or check the model name.",
        error.ProviderOverloaded => "The provider is overloaded. Try again shortly.",
        error.ProviderServerError => "The provider returned a server error. Try again shortly.",
        error.ApiError => "The provider returned an error mid-response (details logged above).",
        error.PromptTooLong => "The conversation is too large for the model's context window. Run `/compact` to shrink it, then retry.",
        error.RequestTooLarge,
        error.CompactedRequestStillTooLarge,
        => "The protected request content is too large for this model. Narrow the request, page large reads, or switch to a model with a larger context window.",
        error.CompactionUnavailable,
        error.CompactionMadeNoProgress,
        error.NoValidCompactionCut,
        error.InvalidCompactionToolPair,
        => "The request crossed the context target but could not be compacted safely. Close pending tool work, run `/compact`, or narrow the request.",
        error.OutputTruncated => "The change set was too large for one response and was cut off at the model's output limit. Split the change into smaller change sets (change one function or section at a time), or switch to a model with a larger output budget via `/model <id>`.",
        error.InvalidChangeSetArgs => "The model sent a `propose_change_set` call this host cannot accept: it must carry one nonempty `changes` array of `{file, content}` objects and no host-owned baseline fields. Retry the ask.",
        error.RequestTimedOut => "The request timed out with no response. Check your network and try again.",
        error.LocalServerUnavailable,
        error.LocalHealthNotOk,
        error.LocalModelUnavailable,
        => "The local MLX model is not ready. Start `mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080`, then retry.",
        error.InvalidMlxBaseUrl => "ZTTP_MLX_BASE_URL must be a credential-free HTTP loopback root such as http://127.0.0.1:8080.",
        error.InvalidResponseJson,
        error.MalformedToolCall,
        error.MalformedToolEnvelope,
        error.UnexpectedResponseShape,
        error.EmptyResponse,
        => "The local MLX response was malformed or incomplete. Check the tested MLX-LM version and model, then retry.",
        error.ResponseTooLarge,
        error.TooManyToolCalls,
        => "The local MLX response exceeded zttp's bounded response limits. Narrow the request and retry.",
        // SSE/stream decode failures from `providers/openai/sse_parser.zig`. A
        // mangled or partial stream (often a proxy) otherwise prints a bare
        // CamelCase name; collapse them all into one actionable line.
        error.MalformedSse,
        error.MissingType,
        error.UnknownEventType,
        error.UnexpectedJsonShape,
        => "The provider response could not be parsed (possibly a proxy or partial stream). Try again.",
        else => null,
    };
}

/// Write a failed turn's error name to stderr, followed by one-line remediation
/// when it is a known provider error. Shared by the interactive REPL and
/// `--print` so both surface the same actionable message instead of a bare
/// error name (or, for `--print`, a Zig error-return trace).
pub fn writeTurnErrorToStderr(err: anyerror) void {
    var buf: [512]u8 = undefined;
    const text = if (providerErrorRemediation(err)) |hint|
        std.fmt.bufPrint(&buf, "error: {s}\n{s}\n", .{ @errorName(err), hint }) catch "error\n"
    else
        std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
    _ = std.c.write(std.c.STDERR_FILENO, text.ptr, text.len);
}

pub fn resolveApprovalFn(policy: ApprovalPolicy, ask_fn: ?ApprovalFn) ApprovalFn {
    return switch (policy) {
        .auto_approve => ApprovalFn.fromFn(autoApprove),
        .auto_reject => ApprovalFn.fromFn(autoReject),
        .ask => ask_fn orelse ApprovalFn.fromFn(autoReject),
    };
}

pub const TurnResult = struct {
    final_state: turn.TurnState,
    attempt: u8,
    usage: turn.Usage = .{},
    end_reason: session_events.TurnEndReason = .approved,
    /// Model round-trips consumed by this turn. Surfaced so the session layer
    /// can accumulate "round-trips to first green proof" without re-parsing the
    /// events log.
    roundtrips: u8 = 0,
    /// True when this turn applied a compiler-verified edit. A plain-text turn
    /// (e.g. a clarifying question) ends `.approved` without applying one, so
    /// metrics key "handler advanced" on this, not on `end_reason`.
    applied_change_set: bool = false,
    /// Proof guarantees discharged / tracked on the applied edit, counted at the
    /// veto (see PropertiesSnapshot.guaranteeCounts). Both 0 when no edit applied.
    proven_guarantees: u32 = 0,
    tracked_guarantees: u32 = 0,
    /// Host-classified workflow for this turn. The hint is advisory; compiler
    /// veto remains the authority on whether edits can land.
    workflow_kind: expert_workflow.TaskKind = .unknown,
    workflow_confidence: expert_workflow.Confidence = .low,
    workflow_hint_injected: bool = false,
    /// Closed cause behind the two published first-attempt metrics.
    draft_quality: codegen_types.DraftQuality = .not_green,
    veto_retry_count: u32 = 0,
    tool_call_count: u32 = 0,
    /// Tool calls whose arguments satisfied the declared schema. The gate is an
    /// instrument: this count never changes which tools ran.
    tool_calls_gate_passed: u32 = 0,
    /// The first failing gate check in this turn, in call order. Null when
    /// every call passed and when the turn made no call.
    first_gate_failure: ?contract_gate.FailureReason = null,
    /// True when this turn applied a compiler-authored repair candidate with no
    /// model round-trip (the model's draft failed veto, the deterministic lane
    /// produced a fix that passed the full veto, and it landed through the
    /// approval gate). The headline "model-free apply" signal.
    compiler_authored_apply: bool = false,

    pub fn rawFirstDraftVetoPass(self: TurnResult) bool {
        return self.draft_quality.rawFirstDraftVetoPass();
    }

    pub fn firstAttemptGreen(self: TurnResult) bool {
        return self.draft_quality.firstAttemptGreen();
    }
};

const TurnProgress = struct {
    applied_change_set: bool = false,
    applied_proven: u32 = 0,
    applied_tracked: u32 = 0,
    draft_quality: codegen_types.DraftQuality = .not_green,
    veto_retry_count: u32 = 0,
    compiler_authored_apply: bool = false,
};

pub const RunOptions = struct {
    max_attempts: u8 = 3,
    workspace_root: []const u8 = ".",
    approval_fn: ?ApprovalFn = null,
    max_model_roundtrips_per_turn: u8 = 18,
    max_tool_calls_per_turn: usize = 16,
    max_tool_batch_size: usize = 8,
    replay_mode: bool = false,
    receipt_durability: ReceiptDurability = .workspace,
    /// Per-turn wall-time limit in milliseconds. When elapsed at the start of
    /// a model roundtrip, the turn is cut short the same way a roundtrip-budget
    /// exhaustion is: the model sees a "budget exhausted" prompt and the turn
    /// returns in .awaiting_user state. 0 disables the limit.
    ///
    /// 5 minutes: the recorded convergence for a complex, multi-tool,
    /// spec-bearing handler ran 80-96s, so a 60s cap killed the flagship turn
    /// shape one roundtrip from green. The roundtrip and tool-call budgets are
    /// the primary bounds; this is only a runaway backstop. The codegen eval
    /// harness inherits this same default so measurement and production share
    /// one options struct.
    turn_timeout_ms: u64 = 300_000,
    /// Best-effort instrument. Null disables recording entirely.
    gate_sink: ?*gate_record.GateSink = null,
    /// Host-assigned task class for the niche key. The loop copies it verbatim
    /// and never derives it.
    task_class: []const u8 = "unclassified",
    /// Resident model identity for the niche record. Empty when unknown.
    model_id: []const u8 = "",
    /// Session identity for the niche record. Empty when the caller runs
    /// without a session (`--no-session`, tests, the eval harness).
    session_id: []const u8 = "",
    /// Turn ordinal within the session, for the gate record. Zero when the
    /// caller does not track it.
    turn_index: u32 = 0,
};

/// Verification attempts granted to interactive and `--print` turns. Higher
/// than the conservative library default (3): a non-trivial edit often needs
/// several retry rounds because the first diagnostic surfaces only one of
/// multiple issues, and three attempts ends the turn "failed" with nothing
/// applied. Sourced here so the REPL `/settings` display cannot drift from it.
pub const interactive_max_attempts: u8 = 5;

/// The mid-turn messages this loop authors, exported so a reader of the wire can
/// recognize them.
///
/// Both reach the provider as user-role items - `extra_user_text` is a user
/// message and a `system_note` is serialized as one - so anything reconstructing
/// turn state from the request body sees them as ordinary user text. Something
/// that treats a user message as the start of a new ask will silently restart
/// mid-turn on every retry, which is exactly what the deterministic stand-in did
/// until these were named.
pub const veto_retry_prefix = "Your previous edit failed compiler verification";
pub const compiler_repair_prefix = "Compiler-authored repair for your last edit";

const max_auto_repairs: usize = 8;

/// Opening words of the tool result the loop writes when the veto rejects a
/// draft. Unlike the two above this is a `function_call_output` body, not a user
/// message, which is what makes it usable to tell "past the apply step because
/// the edit landed" from "past it because the compiler bounced it".
pub const veto_reject_preamble = "The compiler rejected this edit.";

fn callModel(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    client: ModelClient,
    transcript: *transcript_mod.Transcript,
    extra_prompt: ?[]const u8,
) !ModelCallResult {
    const result = try client.request(arena, transcript, extra_prompt);
    if (result.reply.preamble) |text| {
        if (text.len > 0) try transcript.append(allocator, .{ .model_text = text });
    }
    return result;
}

/// Serialize a model change-set draft into `propose_change_set` tool-input JSON so the draft
/// can be recorded in the transcript as an assistant tool call. Recording the
/// draft on the wire - paired with the compiler veto verdict as a tool_result -
/// is what makes the retry loop information-complete: the diagnostics the model
/// must fix reference bytes it can actually see, and the context survives a
/// mid-repair tool call instead of evaporating with a transient prompt.
fn buildProposeChangeSetArgs(
    allocator: std.mem.Allocator,
    edit: turn.ChangeSet,
    prepared: ?*const change_set.PreparedChangeSet,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"changes\":[");
    var index: usize = 0;
    while (index < edit.len()) : (index += 1) {
        if (index > 0) try w.writeByte(',');
        const change = edit.at(index);
        try w.writeAll("{\"file\":");
        try json_writer.writeString(w, change.file);
        try w.writeAll(",\"content\":");
        try json_writer.writeString(w, change.content);
        if (prepared) |host| {
            const prepared_change = &host.changes[index];
            const digest_hex = std.fmt.bytesToHex(prepared_change.baseline_sha256, .lower);
            try w.writeAll(",\"baseline_state\":\"");
            try w.writeAll(if (prepared_change.baseline == .absent) "absent" else "present");
            try w.writeAll("\",\"baseline_sha256\":\"");
            try w.writeAll(&digest_hex);
            try w.writeByte('"');
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return try buf.toOwnedSlice();
}

fn appendChangeSetToolUse(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    call_id: []const u8,
    proposal: turn.ChangeSet,
    prepared: ?*const change_set.PreparedChangeSet,
) !void {
    const args_json = try buildProposeChangeSetArgs(arena, proposal, prepared);
    const calls = [_]turn.ToolCall{.{
        .id = call_id,
        .name = "propose_change_set",
        .args_json = args_json,
        .reasoning_content = proposal.reasoning_content,
    }};
    try transcript.append(allocator, .{ .assistant_tool_use = &calls });
}

/// Append the `tool_result` that closes a draft's synthetic `propose_change_set` tool
/// call. Every path out of `.run_change_set_veto` must call this so the transcript never
/// carries a dangling tool_use (which the Messages API rejects on the next
/// request, and which would break `--resume`). The body/id are duplicated into
/// `allocator` by the transcript, so arena-owned inputs are safe.
fn appendEditToolResult(
    allocator: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    tool_use_id: []const u8,
    ok: bool,
    llm_text: []const u8,
) !void {
    try transcript.append(allocator, .{ .tool_result = .{
        .tool_use_id = tool_use_id,
        .tool_name = "propose_change_set",
        .ok = ok,
        .llm_text = llm_text,
        .ui_payload = null,
    } });
}

const ProjectedToolResult = struct {
    ok: bool,
    llm_text: []const u8,
};

/// Enforce the tool's declared provider-context contract without slicing its
/// output. Replayable previews and process digests must already be bounded,
/// valid envelopes when they reach the loop. A buggy tool fails closed with a
/// small result instead of injecting malformed JSON into later requests.
fn projectToolResult(
    arena: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    tool_name: []const u8,
    ok: bool,
    body: []const u8,
) !ProjectedToolResult {
    const tool = registry.findByName(tool_name) orelse return .{ .ok = ok, .llm_text = body };
    return switch (tool.context_policy) {
        .exact => .{ .ok = ok, .llm_text = body },
        .replayable_preview, .structured_digest => if (body.len <= tools_common.max_projected_tool_result_bytes)
            .{ .ok = ok, .llm_text = body }
        else
            .{
                .ok = false,
                .llm_text = try std.fmt.allocPrint(
                    arena,
                    "{{\"ok\":false,\"error\":\"{s} violated its bounded context policy\",\"result_bytes\":{d},\"maximum_bytes\":{d}}}\n",
                    .{ tool_name, body.len, tools_common.max_projected_tool_result_bytes },
                ),
            },
    };
}

/// Gate state accumulated across one turn. It is owned by `runTurnWith` and
/// borrowed by the turn body, so the record it feeds is still valid when the
/// sink runs, whichever of the body's exits was taken.
const GateState = struct {
    passed: u32 = 0,
    first_failure: ?contract_gate.FailureReason = null,
    calls: std.ArrayListUnmanaged(gate_record.CallOutcome) = .empty,
    tool_set_hash: gate_record.ToolSetHash = std.mem.zeroes(gate_record.ToolSetHash),
    started_ns: u64 = 0,
};

/// Publish the turn's gate counts and, when a sink is attached, one record.
///
/// `adapter_id` is null in M0 because no adapter exists yet. The LoRA
/// inference milestone fills it.
fn emitGateRecord(result: *TurnResult, options: RunOptions, gate: *const GateState) void {
    result.tool_calls_gate_passed = gate.passed;
    result.first_gate_failure = gate.first_failure;
    const sink = options.gate_sink orelse return;
    const now_ns = zts.monotonicNowNs() catch gate.started_ns;
    sink.record(.{
        .session_id = options.session_id,
        .turn_index = options.turn_index,
        .unix_ms = zts.realtimeNowMs() catch 0,
        .task_class = options.task_class,
        .tool_set_hash = gate.tool_set_hash,
        .model_id = options.model_id,
        .adapter_id = null,
        // Every graded call, not only the executed ones: a refused batch and a
        // remapped change set are still calls the model emitted.
        .tool_calls_total = @intCast(@min(gate.calls.items.len, std.math.maxInt(u32))),
        .tool_calls_gate_passed = gate.passed,
        .first_failure = gate.first_failure,
        .calls = gate.calls.items,
        .prompt_tokens = result.usage.input_tokens,
        .generated_tokens = result.usage.output_tokens,
        .wall_ns = now_ns -| gate.started_ns,
    });
}

pub fn runTurnWith(
    allocator: std.mem.Allocator,
    client: ModelClient,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    user_text: []const u8,
    options: RunOptions,
) !TurnResult {
    var gate: GateState = .{
        .tool_set_hash = gate_record.toolSetHash(allocator, registry.list()) catch
            std.mem.zeroes(gate_record.ToolSetHash),
        .started_ns = zts.monotonicNowNs() catch 0,
    };
    defer gate.calls.deinit(allocator);
    var result = try runTurnBody(allocator, client, registry, transcript, user_text, options, &gate);
    emitGateRecord(&result, options, &gate);
    return result;
}

fn runTurnBody(
    allocator: std.mem.Allocator,
    client: ModelClient,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    user_text: []const u8,
    options: RunOptions,
    gate: *GateState,
) !TurnResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    try transcript.append(allocator, .{ .user_text = user_text });
    const workflow_hint = expert_workflow.classify(user_text);
    var workflow_hint_injected = false;
    if (try expert_workflow.renderSystemNote(ta, workflow_hint)) |note| {
        try transcript.append(allocator, .{ .system_note = note });
        workflow_hint_injected = true;
    }

    var machine: turn.TurnMachine = .{ .max_attempts = options.max_attempts };
    var next_event: turn.TurnEvent = .{ .user_submitted = user_text };
    var model_roundtrips: u8 = 0;
    var tool_calls_used: usize = 0;
    var turn_usage: turn.Usage = .{};
    // Set when we stop the turn for running out of model round-trips. The
    // `.prompt_user` arm reads it to append a concrete next step to the bare
    // "budget exhausted" line so the user is not left at a dead end.
    var hit_roundtrip_budget = false;
    // Set when the per-turn tool-call budget is exceeded; causes end_turn/none
    // to log budget_tool_calls instead of approved.
    var hit_tool_budget = false;
    // Set when the per-turn wall-time budget is exhausted. The `.prompt_user`
    // arm reads it to show a timeout-specific message instead of the generic
    // round-trip exhaustion text.
    var hit_timeout_budget = false;
    const turn_start_ms: i64 = nowMonotonicMs();
    const turn_deadline_ms: ?i64 = if (options.turn_timeout_ms == 0)
        null
    else
        std.math.add(
            i64,
            turn_start_ms,
            std.math.cast(i64, options.turn_timeout_ms) orelse std.math.maxInt(i64),
        ) catch std.math.maxInt(i64);
    client.setDeadline(turn_deadline_ms);
    defer client.setDeadline(null);
    // Mutable outcome facts accumulated across the state-machine exits.
    var progress: TurnProgress = .{};

    while (true) {
        const action = machine.transition(next_event);
        switch (action) {
            .request_model => {
                if (model_roundtrips >= options.max_model_roundtrips_per_turn) {
                    hit_roundtrip_budget = true;
                    next_event = .budget_exhausted;
                    continue;
                }
                if (options.turn_timeout_ms > 0 and
                    nowMonotonicMs() - turn_start_ms >= @as(i64, @intCast(options.turn_timeout_ms)))
                {
                    hit_timeout_budget = true;
                    next_event = .budget_exhausted;
                    continue;
                }
                model_roundtrips += 1;
                const result = try callModel(allocator, ta, client, transcript, null);
                turn_usage.add(result.usage);
                next_event = .{ .model_replied = result.reply };
            },
            .retry_draft => |payload| {
                if (model_roundtrips >= options.max_model_roundtrips_per_turn) {
                    hit_roundtrip_budget = true;
                    next_event = .budget_exhausted;
                    continue;
                }
                if (options.turn_timeout_ms > 0 and
                    nowMonotonicMs() - turn_start_ms >= @as(i64, @intCast(options.turn_timeout_ms)))
                {
                    hit_timeout_budget = true;
                    next_event = .budget_exhausted;
                    continue;
                }
                progress.veto_retry_count += 1;
                model_roundtrips += 1;
                // The failed draft and its full diagnostic - plus any compiler-
                // authored repair block and SQL escalation - are already in the
                // transcript as an `propose_change_set` tool_use paired with a failed
                // tool_result (see the `.run_change_set_veto` arm). The model can therefore
                // see exactly what it wrote and precisely which lines the
                // compiler flagged, and that context survives even if the model
                // runs a tool before re-drafting. Only a short framing nudge
                // rides in the transient prompt; losing it is harmless because
                // the substantive repair context is persisted, not re-sent.
                const prompt = try std.fmt.allocPrint(
                    ta,
                    veto_retry_prefix ++ " (attempt {d}/{d}). " ++
                        "Emit a new, complete edit that fixes every flagged violation " ++
                        "without re-introducing one you already fixed in an earlier attempt.",
                    .{ payload.attempt, payload.max_attempts },
                );
                const result = try callModel(allocator, ta, client, transcript, prompt);
                turn_usage.add(result.usage);
                next_event = .{ .model_replied = result.reply };
            },
            .run_change_set_veto => |proposal| {
                // propose_change_set never reaches the tool-batch arm: the
                // provider layer remaps it and the raw arguments are gone by
                // here, so the verdict rides on the proposal instead. Without
                // this the instrument would omit the tool the expert exists to
                // call, and every change-set turn would encode the way a turn
                // that made no call encodes.
                const gate_call_index = gate.calls.items.len;
                {
                    const verdict = proposal.gate_verdict;
                    const gate_pass = verdict == .pass;
                    if (gate_pass) {
                        gate.passed += 1;
                    } else if (gate.first_failure == null) {
                        gate.first_failure = switch (verdict) {
                            .pass => null,
                            .fail => |f| f.reason,
                        };
                    }
                    try gate.calls.append(allocator, .{
                        .tool_name = propose_change_set.tool_name,
                        .gate_pass = gate_pass,
                        .failure = switch (verdict) {
                            .pass => null,
                            .fail => |f| f.reason,
                        },
                        .execution_ok = null,
                    });
                }
                const call_id = try std.fmt.allocPrint(ta, "propose_change_set-{d}", .{transcript.len()});
                var workspace_lock = change_transaction.WorkspaceLock.acquire(ta, options.workspace_root) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = try std.fmt.allocPrint(
                        ta,
                        "change set rejected before proof: workspace transaction lock failed ({s}); no source was written.",
                        .{@errorName(err)},
                    );
                    try appendChangeSetToolUse(allocator, ta, transcript, call_id, proposal, null);
                    try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = message } });
                    try appendEditToolResult(allocator, transcript, call_id, false, message);
                    next_event = .{ .change_set_verified = .{ .ok = false, .llm_text = message } };
                    continue;
                };
                defer workspace_lock.deinit();
                _ = change_transaction.recoverAllLocked(ta, &workspace_lock, options.workspace_root) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = try std.fmt.allocPrint(
                        ta,
                        "change set rejected before proof: workspace recovery failed ({s}); resolve the recorded transaction conflict before retrying.",
                        .{@errorName(err)},
                    );
                    try appendChangeSetToolUse(allocator, ta, transcript, call_id, proposal, null);
                    try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = message } });
                    try appendEditToolResult(allocator, transcript, call_id, false, message);
                    next_event = .{ .change_set_verified = .{ .ok = false, .llm_text = message } };
                    continue;
                };

                var prepared = change_set.prepare(ta, options.workspace_root, proposal) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = try std.fmt.allocPrint(
                        ta,
                        "change set rejected: the host could not establish authoritative source baselines ({s}); no source was written.",
                        .{@errorName(err)},
                    );
                    try appendChangeSetToolUse(allocator, ta, transcript, call_id, proposal, null);
                    try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = message } });
                    try appendEditToolResult(allocator, transcript, call_id, false, message);
                    next_event = .{ .change_set_verified = .{ .ok = false, .llm_text = message } };
                    continue;
                };
                defer prepared.deinit(ta);
                try appendChangeSetToolUse(allocator, ta, transcript, call_id, proposal, &prepared);

                var snapshot = workspace_snapshot.Snapshot.capture(ta, &prepared) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = try std.fmt.allocPrint(
                        ta,
                        "change set rejected: proof input capture failed closed ({s}); no source was written.",
                        .{@errorName(err)},
                    );
                    try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = message } });
                    try appendEditToolResult(allocator, transcript, call_id, false, message);
                    next_event = .{ .change_set_verified = .{ .ok = false, .llm_text = message } };
                    continue;
                };
                defer snapshot.deinit(ta);
                var proof_result = try aggregate_proof.prove(ta, &prepared, &snapshot);
                // All proof allocations live in the turn arena. Do not call
                // `deinit` here: the state machine consumes rejection text on
                // the next loop iteration, and an arena can reclaim or poison
                // a just-freed tail allocation before that transition.
                switch (proof_result) {
                    .rejected => |rejection| {
                        gate.calls.items[gate_call_index].execution_ok = false;
                        const body = try std.fmt.allocPrint(
                            ta,
                            veto_reject_preamble ++ " Fix every flagged violation below:\n\n{s}: {s}",
                            .{ rejection.code, rejection.message },
                        );
                        if (!options.replay_mode and prepared.changes.len == 1) repair: {
                            var candidate = pi_goal_candidate.candidateFromSource(
                                ta,
                                proposal.content,
                                proposal.file,
                                &.{},
                                max_auto_repairs,
                            ) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => break :repair,
                            };
                            defer candidate.deinit(ta);
                            const repaired_source = candidate.proposed_content orelse break :repair;
                            if (!candidate.verified() or std.mem.eql(u8, repaired_source, proposal.content))
                                break :repair;

                            var repaired_prepared = change_set.prepare(ta, options.workspace_root, .{
                                .file = proposal.file,
                                .content = repaired_source,
                            }) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => break :repair,
                            };
                            defer repaired_prepared.deinit(ta);
                            var repaired_snapshot = workspace_snapshot.Snapshot.capture(ta, &repaired_prepared) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => break :repair,
                            };
                            defer repaired_snapshot.deinit(ta);
                            var repaired_result = try aggregate_proof.prove(ta, &repaired_prepared, &repaired_snapshot);
                            switch (repaired_result) {
                                .rejected => break :repair,
                                .accepted => |*repaired_proof| {
                                    try appendEditToolResult(allocator, transcript, call_id, false, body);
                                    const repair_note = try std.fmt.allocPrint(
                                        ta,
                                        compiler_repair_prefix ++ ": applied {d} compiler-validated repair{s} through a fresh aggregate proof.",
                                        .{ candidate.plan_ids.len, if (candidate.plan_ids.len == 1) "" else "s" },
                                    );
                                    try transcript.append(allocator, .{ .system_note = repair_note });
                                    const state = try applyVerifiedChangeSet(
                                        allocator,
                                        ta,
                                        transcript,
                                        options,
                                        &workspace_lock,
                                        &repaired_prepared,
                                        &repaired_snapshot,
                                        repaired_proof,
                                    );
                                    if (state.denied) {
                                        return finishTurn(&machine, turn_usage, .approval_denied, model_roundtrips, workflow_hint, workflow_hint_injected, tool_calls_used, progress);
                                    }
                                    progress.applied_change_set = state.applied;
                                    progress.applied_proven = state.proven;
                                    progress.applied_tracked = state.tracked;
                                    progress.compiler_authored_apply = true;
                                    if (machine.attempt == 1) progress.draft_quality = .compiler_repaired;
                                    next_event = .{ .change_set_verified = .{
                                        .ok = true,
                                        .llm_text = "compiler-authored repair passed aggregate proof",
                                    } };
                                    continue;
                                },
                            }

                            if (auto_repair.buildRetryBlock(ta, candidate.plans_json) catch null) |block| {
                                const note = try std.fmt.allocPrint(
                                    ta,
                                    compiler_repair_prefix ++ ". Apply these changes verbatim, then fix any remaining flagged violations:\n\n{s}",
                                    .{block},
                                );
                                try transcript.append(allocator, .{ .system_note = note });
                            }
                        }
                        try appendEditToolResult(allocator, transcript, call_id, false, body);
                        next_event = .{ .change_set_verified = .{
                            .ok = false,
                            .llm_text = rejection.message,
                        } };
                    },
                    .accepted => |*proof| {
                        gate.calls.items[gate_call_index].execution_ok = true;
                        try appendEditToolResult(
                            allocator,
                            transcript,
                            call_id,
                            true,
                            "verified: aggregate compiler and read-set proof passed",
                        );
                        if (machine.attempt == 1) {
                            var rewrite_count: usize = 0;
                            for (prepared.changes) |change| rewrite_count += change.rewrite_trace.len;
                            progress.draft_quality = if (rewrite_count == 0) .raw_veto_pass else .normalized;
                        }
                        if (!options.replay_mode) {
                            const state = try applyVerifiedChangeSet(
                                allocator,
                                ta,
                                transcript,
                                options,
                                &workspace_lock,
                                &prepared,
                                &snapshot,
                                proof,
                            );
                            if (state.denied) {
                                return finishTurn(&machine, turn_usage, .approval_denied, model_roundtrips, workflow_hint, workflow_hint_injected, tool_calls_used, progress);
                            }
                            progress.applied_change_set = state.applied;
                            progress.applied_proven = state.proven;
                            progress.applied_tracked = state.tracked;
                        }
                        next_event = .{ .change_set_verified = .{
                            .ok = true,
                            .llm_text = try std.fmt.allocPrint(
                                ta,
                                "aggregate proof passed for {d} source file{s}",
                                .{ prepared.changes.len, if (prepared.changes.len == 1) "" else "s" },
                            ),
                        } };
                    },
                }
            },
            .invoke_tool_batch => |calls| {
                try transcript.append(allocator, .{ .assistant_tool_use = calls });

                // Grade before the refusal branch below, so a batch the host
                // refuses is still counted: a schema verdict is a property of
                // what the model emitted, not of what the host did with it.
                for (calls) |call| {
                    var gate_arena = std.heap.ArenaAllocator.init(ta);
                    const declared: ?*const registry_mod.ToolDef = blk: {
                        const found = registry.findByName(call.name) orelse break :blk null;
                        // A trusted-only or RPC-only tool was never shown to the
                        // model, so a call naming it is undeclared, not merely
                        // mis-typed. `findByName` alone cannot tell them apart.
                        break :blk if (found.allowedOn(.model)) found else null;
                    };
                    // An allocation failure inside the gate degrades to a pass.
                    // An instrument must never abort the turn it measures.
                    const verdict = contract_gate.check(
                        gate_arena.allocator(),
                        declared,
                        call.args_json,
                    ) catch contract_gate.Verdict{ .pass = {} };
                    gate_arena.deinit();

                    const gate_pass = verdict == .pass;
                    const failure: ?contract_gate.FailureReason = switch (verdict) {
                        .pass => null,
                        .fail => |f| f.reason,
                    };
                    if (gate_pass) {
                        gate.passed += 1;
                    } else if (gate.first_failure == null) {
                        gate.first_failure = failure;
                    }
                    try gate.calls.append(allocator, .{
                        .tool_name = call.name,
                        .gate_pass = gate_pass,
                        .failure = failure,
                        .execution_ok = null,
                    });
                }

                const mixed_propose_change_set = containsProposeChangeSet(calls) and calls.len > 1;
                const over_budget = calls.len > options.max_tool_batch_size or
                    tool_calls_used + calls.len > options.max_tool_calls_per_turn;

                if (mixed_propose_change_set or over_budget) {
                    if (over_budget) hit_tool_budget = true;
                    for (calls) |call| {
                        const message = if (mixed_propose_change_set)
                            "propose_change_set was grouped with other tool calls. It must be issued alone in a single response so the compiler veto can run cleanly. Re-issue just the propose_change_set call without any other tools."
                        else
                            "tool-call budget exceeded for this turn";
                        try transcript.append(allocator, .{ .tool_result = .{
                            .tool_use_id = call.id,
                            .tool_name = call.name,
                            .ok = false,
                            .llm_text = message,
                            .ui_payload = null,
                        } });
                    }
                    next_event = .tool_batch_completed;
                    continue;
                }

                tool_calls_used += calls.len;
                for (calls, 0..) |call, index| {
                    var result = try invokeToolRecovering(ta, registry, call);
                    defer result.deinit(ta);
                    // Separate from the gate verdict and never merged with it:
                    // a schema-satisfying call can still fail when it runs. A
                    // graded call that never ran keeps a null outcome.
                    gate.calls.items[gate.calls.items.len - calls.len + index].execution_ok = result.ok;
                    const projected = try projectToolResult(
                        ta,
                        registry,
                        call.name,
                        result.ok,
                        result.llm_text,
                    );
                    try transcript.append(allocator, .{ .tool_result = .{
                        .tool_use_id = call.id,
                        .tool_name = call.name,
                        .ok = projected.ok,
                        .llm_text = projected.llm_text,
                        .ui_payload = result.ui_payload,
                    } });
                }
                next_event = .tool_batch_completed;
            },
            .render => |msg| {
                // A diagnostic_box in the render arm always means veto exhaustion
                // (the turn machine emits it only after the final failed attempt).
                // Append a concrete next step so the user is not left at a dead end,
                // mirroring the budget-exhausted path. ui_payload is preserved so the
                // structured diagnostic surface is unchanged.
                const entry: turn.Message = switch (msg) {
                    .diagnostic_box => |box| .{ .diagnostic_box = .{
                        .llm_text = try std.fmt.allocPrint(ta, "{s}\n\n{s}", .{ box.llm_text, veto_exhausted_next_step }),
                        .ui_payload = box.ui_payload,
                    } },
                    else => msg,
                };
                try transcript.append(allocator, entry);
                const end_reason: session_events.TurnEndReason = switch (msg) {
                    .diagnostic_box => .veto_exhausted,
                    else => .approved,
                };
                return finishTurn(
                    &machine,
                    turn_usage,
                    end_reason,
                    model_roundtrips,
                    workflow_hint,
                    workflow_hint_injected,
                    tool_calls_used,
                    progress,
                );
            },
            .prompt_user => |question| {
                const text = if (hit_timeout_budget)
                    try std.fmt.allocPrint(
                        ta,
                        "{s}\nTurn time limit reached ({d}s). Run /compact or narrow the task and retry.",
                        .{ question, options.turn_timeout_ms / 1000 },
                    )
                else if (hit_roundtrip_budget)
                    try std.fmt.allocPrint(ta, "{s}\n{s}", .{ question, budget_exhausted_next_step })
                else
                    question;
                try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = text } });
                const budget_reason: session_events.TurnEndReason = if (hit_timeout_budget) .budget_timeout else .budget_roundtrips;
                return finishTurn(
                    &machine,
                    turn_usage,
                    budget_reason,
                    model_roundtrips,
                    workflow_hint,
                    workflow_hint_injected,
                    tool_calls_used,
                    progress,
                );
            },
            .end_turn => return finishTurn(
                &machine,
                turn_usage,
                if (hit_tool_budget) .budget_tool_calls else .approved,
                model_roundtrips,
                workflow_hint,
                workflow_hint_injected,
                tool_calls_used,
                progress,
            ),
            .none => return finishTurn(
                &machine,
                turn_usage,
                if (hit_tool_budget) .budget_tool_calls else .approved,
                model_roundtrips,
                workflow_hint,
                workflow_hint_injected,
                tool_calls_used,
                progress,
            ),
        }
    }
}

fn finishTurn(
    machine: *const turn.TurnMachine,
    usage: turn.Usage,
    reason: session_events.TurnEndReason,
    model_roundtrips: u8,
    workflow_hint: expert_workflow.WorkflowHint,
    workflow_hint_injected: bool,
    tool_calls_used: usize,
    progress: TurnProgress,
) TurnResult {
    return .{
        .final_state = machine.state,
        .attempt = machine.attempt,
        .usage = usage,
        .end_reason = reason,
        .roundtrips = model_roundtrips,
        .applied_change_set = progress.applied_change_set,
        .proven_guarantees = progress.applied_proven,
        .tracked_guarantees = progress.applied_tracked,
        .workflow_kind = workflow_hint.kind,
        .workflow_confidence = workflow_hint.confidence,
        .workflow_hint_injected = workflow_hint_injected,
        .draft_quality = progress.draft_quality,
        .veto_retry_count = progress.veto_retry_count,
        .tool_call_count = @intCast(@min(tool_calls_used, std.math.maxInt(u32))),
        .compiler_authored_apply = progress.compiler_authored_apply,
    };
}

/// Monotonic time in milliseconds. Delegates to zts.monotonicNowNs
/// which reads CLOCK_MONOTONIC directly and is safe for interval checks.
fn nowMonotonicMs() i64 {
    return @intCast((zts.monotonicNowNs() catch 0) / 1_000_000);
}

fn invokeToolRecovering(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    call: turn.ToolCall,
) !registry_mod.ToolResult {
    return registry.invokeJsonOn(allocator, .model, call.name, call.args_json) catch |err| switch (err) {
        registry_mod.RegistryError.ToolNotFound => registry_mod.ToolResult.errFmt(
            allocator,
            "unknown tool: {s}",
            .{call.name},
        ),
        error.InvalidToolArgsJson => registry_mod.ToolResult.errFmt(
            allocator,
            "{s}: invalid structured tool arguments",
            .{call.name},
        ),
        registry_mod.RegistryError.ToolNotAllowed => registry_mod.ToolResult.errFmt(
            allocator,
            "tool is not available to the model: {s}",
            .{call.name},
        ),
        else => registry_mod.ToolResult.errFmt(
            allocator,
            "{s}: {s}",
            .{ call.name, @errorName(err) },
        ),
    };
}

fn containsProposeChangeSet(calls: []const turn.ToolCall) bool {
    for (calls) |call| {
        if (std.mem.eql(u8, call.name, propose_change_set.tool_name)) return true;
    }
    return false;
}

const ApplyState = struct {
    applied: bool = false,
    proven: u32 = 0,
    tracked: u32 = 0,
    /// True when a verified edit was not written: the approval policy rejected
    /// it, or the file changed on disk after the baseline was taken. The caller
    /// ends the turn with .approval_denied; nothing was written either way.
    denied: bool = false,
};

fn applyVerifiedChangeSet(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    options: RunOptions,
    workspace_lock: *const change_transaction.WorkspaceLock,
    prepared: *const change_set.PreparedChangeSet,
    snapshot: *const workspace_snapshot.Snapshot,
    proof: *const aggregate_proof.AggregateProof,
) !ApplyState {
    if (options.approval_fn) |approve| {
        const previews = try arena.alloc(ChangePreview, prepared.changes.len);
        for (prepared.changes, 0..) |change, index| previews[index] = .{
            .file = change.authored_path,
            .before = change.baseline.bytes(),
            .after = change.candidate,
            .rewrite_trace = change.rewrite_trace,
        };
        if (!try approve.call(.{
            .proof_id = &proof.proof_id,
            .changes = previews,
            .system_proven = proof.system_proven,
        })) {
            try transcript.append(allocator, .{
                .system_note = "change set proved but was not applied by the user approval policy",
            });
            return .{ .denied = true };
        }
    }

    var receipt_payload: ui_payload_mod.UiPayload = .{ .verified_change_set = try change_set_receipt.build(
        allocator,
        prepared,
        snapshot,
        proof,
        tools_common.nowUnixMs(),
    ) };
    var receipt_owned = true;
    defer if (receipt_owned) receipt_payload.deinit(allocator);
    var receipt_json = TextBuffer.init(arena);
    defer receipt_json.deinit();
    try ui_payload_mod.writeJson(receipt_json.writer(), receipt_payload);

    var committed = change_transaction.commitLocked(
        arena,
        workspace_lock,
        prepared,
        snapshot,
        proof,
        .{ .receipt_json = receipt_json.written() },
    ) catch |err| switch (err) {
        error.ProofReadSetChanged => {
            try transcript.append(allocator, .{
                .system_note = "change set proved but was not applied: a proof input changed before commit",
            });
            return .{ .denied = true };
        },
        else => return err,
    };
    defer committed.deinit(arena);

    const summary = try std.fmt.allocPrint(
        allocator,
        "verified change set: {d} source file{s} ({s})",
        .{
            prepared.changes.len,
            if (prepared.changes.len == 1) "" else "s",
            proof.proof_id,
        },
    );
    errdefer allocator.free(summary);
    try transcript.entries.append(allocator, .{ .verified_change_set = .{
        .llm_text = summary,
        .ui_payload = receipt_payload,
    } });
    receipt_owned = false;
    if (options.receipt_durability == .workspace) {
        try change_transaction.markReceiptedLocked(
            arena,
            workspace_lock,
            prepared.workspace_root,
            &proof.proof_id,
        );
    }
    return .{ .applied = true };
}
const testing = std.testing;
const Tag = transcript_mod.Tag;

const CannedClient = struct {
    reply: turn.AssistantReply,
    saw_workflow_note: bool = false,
    request_count: usize = 0,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!ModelCallResult {
        const self: *CannedClient = @ptrCast(@alignCast(ctx));
        _ = arena;
        _ = extra_user_text;
        self.request_count += 1;
        for (transcript.entries.items) |entry| {
            switch (entry) {
                .system_note => |body| {
                    if (std.mem.indexOf(u8, body, expert_workflow.workflow_note_prefix) != null) {
                        self.saw_workflow_note = true;
                    }
                },
                else => {},
            }
        }
        return .{ .reply = self.reply };
    }

    pub fn asClient(self: *CannedClient) ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

const SequenceClient = struct {
    replies: []const turn.AssistantReply,
    index: usize = 0,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!ModelCallResult {
        const self: *SequenceClient = @ptrCast(@alignCast(ctx));
        _ = arena;
        _ = transcript;
        _ = extra_user_text;
        if (self.index >= self.replies.len) return error.TestSequenceExhausted;
        const reply = self.replies[self.index];
        self.index += 1;
        return .{ .reply = reply };
    }

    pub fn asClient(self: *SequenceClient) ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

fn stubExecute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    _ = args;
    return .{ .ok = true, .llm_text = try allocator.dupe(u8, "{\"stub\":\"ok\"}\n") };
}

fn stubDecodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    return registry_mod.helpers.decodeNoArgs(allocator, args_json);
}

const stub_tool: registry_mod.ToolDef = .{
    .name = "stub",
    .label = "stub",
    .effect = .analyze,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description = "Test stub",
    .input_schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    .decode_json = stubDecodeJson,
    .execute = stubExecute,
};

// `std.testing.tmpDir` creates `.zig-cache/tmp/<sub_path>/`, but `tmp.sub_path`
// is only the 16-char random component. Resolving it directly against CWD
// (the repo root) would create stray `<repo>/<sub_path>/` folders that
// `tmp.cleanup()` never deletes. Compose the full relative path so writes
// land inside the real tmp dir.
fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    try tmp.dir.createDirPath(testing.io, "src");
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

const bad_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { var x = 1; return Response.json({ x: x }); }";
const clean_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ok: true}); }";

const ApprovalRace = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_before: []const u8,
    concurrent_content: []const u8,
    saw_authoritative_before: bool = false,

    fn approve(context: *anyopaque, preview: ChangeSetApprovalPreview) anyerror!bool {
        const self: *ApprovalRace = @ptrCast(@alignCast(context));
        self.saw_authoritative_before = preview.changes.len == 1 and
            preview.changes[0].before != null and
            std.mem.eql(u8, preview.changes[0].before.?, self.expected_before);
        try file_io.writeFile(self.allocator, self.path, self.concurrent_content);
        return true;
    }

    fn callback(self: *ApprovalRace) ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = approve } };
    }
};

const ApprovalCapture = struct {
    approve_result: bool,
    calls: u32 = 0,
    saw_after: bool = false,
    expected_after: []const u8,
    expected_change_count: usize = 1,
    saw_expected_change_count: bool = false,

    fn approve(context: *anyopaque, preview: ChangeSetApprovalPreview) anyerror!bool {
        const self: *ApprovalCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.saw_expected_change_count = preview.changes.len == self.expected_change_count;
        self.saw_after = preview.changes.len == 1 and
            std.mem.eql(u8, preview.changes[0].after, self.expected_after);
        return self.approve_result;
    }

    fn callback(self: *ApprovalCapture) ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = approve } };
    }
};

// Accesses result.value without checking result.ok: a HandlerVerifier error
// (ZTS303 unchecked_result_value) that the repair lane can author a fix for.
const unchecked_result_handler =
    "import { validateJson } from \"zttp:validate\";\n" ++
    "function handler(req: Request): Proof<Response, \"deterministic\"> {\n" ++
    "  const result = validateJson(\"item\", req.body ?? \"\");\n" ++
    "  const data = result.value;\n" ++
    "  return Response.json({ data: data });\n" ++
    "}\n";

// A scripted client that flags whether any retry prompt carried the
// compiler-authored repair block, so the auto-repair wiring can be asserted
// end-to-end without reaching into the loop's internal prompt construction.
const RetryCaptureClient = struct {
    replies: []const turn.AssistantReply,
    index: usize = 0,
    saw_repair_block: bool = false,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!ModelCallResult {
        const self: *RetryCaptureClient = @ptrCast(@alignCast(ctx));
        _ = arena;
        _ = transcript;
        if (extra_user_text) |t| {
            if (std.mem.indexOf(u8, t, "COMPILER-AUTHORED FIX") != null) self.saw_repair_block = true;
        }
        if (self.index >= self.replies.len) return error.TestSequenceExhausted;
        const reply = self.replies[self.index];
        self.index += 1;
        return .{ .reply = reply };
    }

    pub fn asClient(self: *RetryCaptureClient) ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

test "veto failure triggers model-free compiler-authored apply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/src/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var client: RetryCaptureClient = .{ .replies = &.{
        .{ .response = .{ .change_set = .{ .file = "src/handler.ts", .content = unchecked_result_handler } } },
        .{ .response = .{ .change_set = .{ .file = "src/handler.ts", .content = clean_handler } } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(testing.allocator, client.asClient(), &registry, &tr, "fix the handler", .{
        .workspace_root = workspace_root,
        .max_attempts = 2,
        .approval_fn = ApprovalFn.fromFn(autoApprove),
        .turn_timeout_ms = 0,
    });

    // The first draft (unchecked result) failed veto; the deterministic lane
    // authored a fix that passed the binding re-veto and landed model-free -
    // no retry, no second model call.
    try testing.expect(result.applied_change_set);
    try testing.expectEqual(@as(usize, 1), client.index); // second reply never requested
    try testing.expect(result.compiler_authored_apply);
    try testing.expectEqual(@as(u32, 0), result.veto_retry_count);
    try testing.expect(!client.saw_repair_block);

    // The compiler-authored guard is what actually landed on disk.
    const written = try file_io.readFile(testing.allocator, written_path, 1 << 20);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "if (!result.ok)") != null);
}

// A client that records, on each roundtrip after the first, whether the failed
// draft (recorded as an `propose_change_set` tool_use) and the compiler diagnostic
// (recorded as a failed tool_result) are visible in the transcript it is handed.
// This is the #1 invariant: because those live in the transcript - not a
// transient prompt - a tool call interleaved into the repair cannot erase the
// context the model must fix against.
const DraftVisibilityClient = struct {
    calls: usize = 0,
    saw_on_retry: bool = false,
    saw_after_interleave: bool = false,

    fn draftAndDiagVisible(transcript: *const transcript_mod.Transcript) bool {
        var saw_draft = false;
        var saw_digest_without_baseline_copy = false;
        var saw_diag = false;
        for (transcript.entries.items) |*entry| {
            switch (entry.*) {
                .assistant_tool_use => |calls| {
                    for (calls) |call| {
                        if (std.mem.eql(u8, call.name, "propose_change_set") and
                            std.mem.indexOf(u8, call.args_json, "var x = 1") != null)
                        {
                            saw_draft = true;
                            saw_digest_without_baseline_copy =
                                std.mem.indexOf(u8, call.args_json, "baseline_sha256") != null and
                                std.mem.indexOf(u8, call.args_json, "\"before\"") == null and
                                std.mem.indexOf(u8, call.args_json, clean_handler) == null;
                        }
                    }
                },
                .tool_result => |result| {
                    if (!result.ok and std.mem.indexOf(u8, result.llm_text, "compiler rejected") != null)
                        saw_diag = true;
                },
                else => {},
            }
        }
        return saw_draft and saw_digest_without_baseline_copy and saw_diag;
    }

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!ModelCallResult {
        const self: *DraftVisibilityClient = @ptrCast(@alignCast(ctx));
        _ = arena;
        _ = extra_user_text;
        self.calls += 1;
        const stub_calls = [_]turn.ToolCall{.{ .id = "toolu_probe", .name = "stub", .args_json = "{}" }};
        return switch (self.calls) {
            // First draft: fails the veto (unsupported `var`).
            1 => .{ .reply = .{ .response = .{ .change_set = .{ .file = "handler.ts", .content = bad_handler } } } },
            // Retry: the failed draft and its diagnostic must already be in the
            // transcript. Respond with a TOOL CALL rather than a new edit - the
            // mid-repair interleave that used to wipe the transient retry prompt.
            2 => blk: {
                self.saw_on_retry = DraftVisibilityClient.draftAndDiagVisible(transcript);
                break :blk .{ .reply = .{ .response = .{ .tool_calls = &stub_calls } } };
            },
            // After the interleave: the draft + diagnostic must STILL be visible.
            3 => blk: {
                self.saw_after_interleave = DraftVisibilityClient.draftAndDiagVisible(transcript);
                break :blk .{ .reply = .{ .response = .{ .final_text = "giving up" } } };
            },
            else => .{ .reply = .{ .response = .{ .final_text = "done" } } },
        };
    }

    pub fn asClient(self: *DraftVisibilityClient) ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

test "retry loop is information-complete: failed draft + diagnostic survive a mid-repair tool call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const handler_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(handler_path);
    try file_io.writeFile(testing.allocator, handler_path, clean_handler);

    var client: DraftVisibilityClient = .{};
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, stub_tool);

    // replay_mode skips the deterministic repair lane so the failed draft cleanly
    // drives a model retry (the case that exercises the interleave), while veto
    // and the transcript appends run exactly as in production.
    const result = try runTurnWith(
        testing.allocator,
        client.asClient(),
        &registry,
        &tr,
        "write the handler",
        .{ .workspace_root = workspace_root, .replay_mode = true },
    );
    try testing.expectEqual(turn.TurnState.done, result.final_state);

    // The model saw its failed draft and the compiler diagnostic on the retry...
    try testing.expect(client.saw_on_retry);
    // ...and they were NOT erased by the interleaved tool call.
    try testing.expect(client.saw_after_interleave);
}

test "bounded context policy rejects oversized output without slicing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    const tool: registry_mod.ToolDef = .{
        .name = "bounded",
        .label = "bounded",
        .effect = .analyze,
        .context_policy = .replayable_preview,
        .model_exposure = .visible,
        .description = "test",
        .input_schema = "{}",
        .decode_json = registry_mod.helpers.decodeNoArgs,
        .execute = stubExecute,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);

    const big = try ta.alloc(u8, tools_common.max_projected_tool_result_bytes + 1);
    @memset(big, 'a');
    const rejected = try projectToolResult(ta, &registry, "bounded", true, big);
    try testing.expect(!rejected.ok);
    try testing.expect(std.mem.indexOf(u8, rejected.llm_text, "violated") != null);
    try testing.expect(std.mem.indexOf(u8, rejected.llm_text, "aaaa") == null);

    const small = "ok";
    const passthrough = try projectToolResult(ta, &registry, "bounded", true, small);
    try testing.expect(passthrough.ok);
    try testing.expectEqual(small.ptr, passthrough.llm_text.ptr);

    const boundary = try ta.alloc(u8, tools_common.max_projected_tool_result_bytes);
    @memset(boundary, 'b');
    const accepted = try projectToolResult(ta, &registry, "bounded", true, boundary);
    try testing.expect(accepted.ok);
    try testing.expectEqual(boundary.ptr, accepted.llm_text.ptr);

    var exact_tool = tool;
    exact_tool.name = "exact";
    exact_tool.context_policy = .exact;
    try registry.register(testing.allocator, exact_tool);
    const historical_boundary = try ta.alloc(u8, tools_common.max_hole_tool_result_bytes + 1);
    @memset(historical_boundary, 'c');
    const preserved = try projectToolResult(ta, &registry, "exact", true, historical_boundary);
    try testing.expect(preserved.ok);
    try testing.expectEqual(historical_boundary.len, preserved.llm_text.len);
    try testing.expectEqual(historical_boundary.ptr, preserved.llm_text.ptr);
}

test "bounded tool batch growth is explicit and finite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const tool: registry_mod.ToolDef = .{
        .name = "paged",
        .label = "paged",
        .effect = .read_workspace,
        .context_policy = .replayable_preview,
        .model_exposure = .visible,
        .description = "test",
        .input_schema = "{}",
        .decode_json = registry_mod.helpers.decodeNoArgs,
        .execute = stubExecute,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);

    const page = try ta.alloc(u8, tools_common.max_projected_tool_result_bytes);
    @memset(page, 'p');
    var total: usize = 0;
    for (0..4) |_| {
        const projected = try projectToolResult(ta, &registry, "paged", true, page);
        try testing.expect(projected.ok);
        total += projected.llm_text.len;
    }
    try testing.expectEqual(tools_common.max_projected_tool_result_bytes * 4, total);
}

test "text reply path injects workflow note before model text" {
    var canned: CannedClient = .{ .reply = .{
        .response = .{ .final_text = "here is the plan" },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(testing.allocator, canned.asClient(), &registry, &tr, "add a GET route", .{});
    try testing.expectEqual(turn.TurnState.done, result.final_state);
    try testing.expectEqual(expert_workflow.TaskKind.route_add, result.workflow_kind);
    try testing.expect(result.workflow_hint_injected);
    try testing.expect(canned.saw_workflow_note);
    try testing.expectEqual(@as(usize, 1), canned.request_count);
    switch (tr.at(0).*) {
        .user_text => |body| try testing.expectEqualStrings("add a GET route", body),
        else => return error.TestFailed,
    }
    switch (tr.at(1).*) {
        .system_note => |body| try testing.expect(std.mem.indexOf(u8, body, "submit exactly one `propose_change_set` call so the host veto checks the draft") != null),
        else => return error.TestFailed,
    }
    switch (tr.at(2).*) {
        .model_text => |body| try testing.expectEqualStrings("here is the plan", body),
        else => return error.TestFailed,
    }
}

test "clean edit path: veto passes and writes file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/src/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "src/handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add an ok response",
        .{ .workspace_root = workspace_root },
    );

    try testing.expectEqual(turn.TurnState.done, result.final_state);
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => |body| try testing.expect(std.mem.indexOf(u8, body.llm_text, "aggregate proof passed") != null),
        else => return error.TestFailed,
    }
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(clean_handler, written);
}

test "coordinated two-file change proves once approves once and commits one receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zttp.json", .data = "{\"entry\":\"src/handler.ts\"}" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(\"old\"); }\n",
    });
    const handler =
        "import { newValue } from \"./helper\";\n" ++
        "export function handler(req: Request): Proof<Response, \"state_isolated\"> { return Response.text(newValue()); }\n";
    const helper = "export function newValue(): string { return \"new\"; }\n";
    const tail = [_]turn.Change{.{ .file = "src/helper.ts", .content = helper }};
    var canned: CannedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "src/handler.ts",
        .content = handler,
        .additional = &tail,
    } } } };
    var approval: ApprovalCapture = .{
        .approve_result = true,
        .expected_after = handler,
        .expected_change_count = 2,
    };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add a helper and use it",
        .{ .workspace_root = workspace_root, .approval_fn = approval.callback() },
    );
    try testing.expect(result.applied_change_set);
    try testing.expectEqual(@as(u32, 1), approval.calls);
    try testing.expect(approval.saw_expected_change_count);
    var receipt_count: usize = 0;
    for (tr.entries.items) |entry| switch (entry) {
        .verified_change_set => |message| {
            receipt_count += 1;
            switch (message.ui_payload.?) {
                .verified_change_set => |receipt| try testing.expectEqual(@as(usize, 2), receipt.changes.len),
                else => return error.TestFailed,
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), receipt_count);
    const handler_path = try std.fs.path.resolve(testing.allocator, &.{ workspace_root, "src/handler.ts" });
    defer testing.allocator.free(handler_path);
    const helper_path = try std.fs.path.resolve(testing.allocator, &.{ workspace_root, "src/helper.ts" });
    defer testing.allocator.free(helper_path);
    const handler_bytes = try file_io.readFile(testing.allocator, handler_path, 1024 * 1024);
    defer testing.allocator.free(handler_bytes);
    const helper_bytes = try file_io.readFile(testing.allocator, helper_path, 1024 * 1024);
    defer testing.allocator.free(helper_bytes);
    try testing.expect(std.mem.indexOf(u8, handler_bytes, "newValue") != null);
    try testing.expect(std.mem.indexOf(u8, helper_bytes, "return \"new\"") != null);
}

test "broken edit path: veto fails with diagnostic box" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "src/handler.ts",
            .content = bad_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add a bad handler",
        .{ .workspace_root = workspace_root, .max_attempts = 1 },
    );

    try testing.expectEqual(turn.TurnState.done, result.final_state);
    try testing.expectEqual(session_events.TurnEndReason.veto_exhausted, result.end_reason);
    switch (tr.at(tr.len() - 1).*) {
        .diagnostic_box => |body| {
            // The recurring diagnostic is still present...
            try testing.expect(std.mem.indexOf(u8, body.llm_text, "ZTS001") != null);
            // ...and the box now ends with a concrete next step rather than a
            // silent dead end (Set C: veto-exhaustion off-ramp).
            try testing.expect(std.mem.indexOf(u8, body.llm_text, veto_exhausted_next_step) != null);
        },
        else => return error.TestFailed,
    }
}

test "tool batch path: invoke_tool_batch -> tool_result -> final model text" {
    const replies = [_]turn.AssistantReply{
        .{
            .preamble = "I'll inspect first.",
            .response = .{ .tool_calls = &[_]turn.ToolCall{
                .{ .id = "toolu_stub", .name = "stub", .args_json = "{}" },
            } },
        },
        .{
            .response = .{ .final_text = "inspection complete" },
        },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, stub_tool);

    const result = try runTurnWith(testing.allocator, seq.asClient(), &registry, &tr, "run the stub", .{});
    try testing.expectEqual(turn.TurnState.done, result.final_state);
    switch (tr.at(1).*) {
        .model_text => |body| try testing.expectEqualStrings("I'll inspect first.", body),
        else => return error.TestFailed,
    }
    try testing.expectEqual(Tag.assistant_tool_use, @as(Tag, tr.at(2).*));
}

fn gateProbeDecodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    _ = allocator;
    _ = args_json;
    return &.{};
}

/// Requires `path`, but executes successfully whatever it is given. A call that
/// omits `path` therefore fails the gate and succeeds at execution, which is
/// exactly the pair the gate must be able to report separately.
const gate_probe_tool: registry_mod.ToolDef = .{
    .name = "gate_probe",
    .label = "gate probe",
    .effect = .analyze,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description = "Test probe with one required parameter",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    .decode_json = gateProbeDecodeJson,
    .execute = stubExecute,
};

/// Copies the per-call slice on the way in. The loop owns that memory for the
/// length of the turn only, so a collector that outlives the turn must take its
/// own copy. A real sink serializes inside `record` and needs no copy.
const GateCollector = struct {
    records: std.ArrayListUnmanaged(gate_record.TurnRecord) = .empty,
    allocator: std.mem.Allocator,

    fn record(context: *anyopaque, r: gate_record.TurnRecord) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        var copy = r;
        copy.calls = try self.allocator.dupe(gate_record.CallOutcome, r.calls);
        errdefer self.allocator.free(copy.calls);
        try self.records.append(self.allocator, copy);
    }

    fn deinit(self: *@This()) void {
        for (self.records.items) |r| self.allocator.free(r.calls);
        self.records.deinit(self.allocator);
    }
};

test "gate instrument: a schema-violating tool call is recorded but still executes" {
    var collector = GateCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    var sink = gate_record.GateSink{ .context = &collector, .record_fn = GateCollector.record };

    const replies = [_]turn.AssistantReply{
        .{
            .response = .{ .tool_calls = &[_]turn.ToolCall{
                .{ .id = "toolu_ok", .name = "gate_probe", .args_json = "{\"path\":\"src\"}" },
                .{ .id = "toolu_bad", .name = "gate_probe", .args_json = "{}" },
            } },
        },
        .{ .response = .{ .final_text = "done" } },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, gate_probe_tool);

    const result = try runTurnWith(
        testing.allocator,
        seq.asClient(),
        &registry,
        &tr,
        "probe twice",
        .{ .gate_sink = &sink, .task_class = "tool_call", .session_id = "s1" },
    );

    try testing.expectEqual(turn.TurnState.done, result.final_state);
    try testing.expectEqual(@as(u32, 2), result.tool_call_count);
    try testing.expectEqual(@as(u32, 1), result.tool_calls_gate_passed);
    try testing.expectEqual(contract_gate.FailureReason.missing_required, result.first_gate_failure.?);

    try testing.expectEqual(@as(usize, 1), collector.records.items.len);
    const rec = collector.records.items[0];
    try testing.expectEqual(@as(u32, 2), rec.tool_calls_total);
    try testing.expectEqual(@as(u32, 1), rec.tool_calls_gate_passed);
    try testing.expectEqual(contract_gate.FailureReason.missing_required, rec.first_failure.?);
    try testing.expectEqualStrings("tool_call", rec.task_class);
    try testing.expectEqualStrings("s1", rec.session_id);

    // Both calls ran. The gate blocked nothing.
    try testing.expectEqual(@as(usize, 2), rec.calls.len);
    try testing.expect(rec.calls[0].gate_pass);
    try testing.expectEqual(true, rec.calls[0].execution_ok.?);
    try testing.expect(!rec.calls[1].gate_pass);
    try testing.expectEqual(contract_gate.FailureReason.missing_required, rec.calls[1].failure.?);
    // The decisive assertion: gate failed, execution succeeded, and the record
    // reports both without merging them.
    try testing.expectEqual(true, rec.calls[1].execution_ok.?);
}

test "gate instrument: a turn with no tool call records zero of zero" {
    var collector = GateCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    var sink = gate_record.GateSink{ .context = &collector, .record_fn = GateCollector.record };

    const replies = [_]turn.AssistantReply{
        .{ .response = .{ .final_text = "no tool needed" } },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        seq.asClient(),
        &registry,
        &tr,
        "just answer",
        .{ .gate_sink = &sink, .task_class = "tool_call" },
    );

    try testing.expectEqual(@as(usize, 1), collector.records.items.len);
    const rec = collector.records.items[0];
    try testing.expectEqual(@as(u32, 0), rec.tool_calls_total);
    try testing.expectEqual(@as(u32, 0), rec.tool_calls_gate_passed);
    try testing.expect(rec.first_failure == null);
    try testing.expectEqual(@as(usize, 0), rec.calls.len);
}

test "gate instrument: an undeclared tool name is graded as undeclared_tool" {
    var collector = GateCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    var sink = gate_record.GateSink{ .context = &collector, .record_fn = GateCollector.record };

    const replies = [_]turn.AssistantReply{
        .{
            .response = .{ .tool_calls = &[_]turn.ToolCall{
                .{ .id = "toolu_ghost", .name = "not_registered", .args_json = "{}" },
            } },
        },
        .{ .response = .{ .final_text = "done" } },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, stub_tool);

    _ = try runTurnWith(
        testing.allocator,
        seq.asClient(),
        &registry,
        &tr,
        "call a ghost",
        .{ .gate_sink = &sink, .task_class = "tool_call" },
    );

    const rec = collector.records.items[0];
    try testing.expectEqual(contract_gate.FailureReason.undeclared_tool, rec.first_failure.?);
    // The pre-existing recovery path still reported the failure to the model.
    try testing.expectEqual(false, rec.calls[0].execution_ok.?);
}

test "gate instrument: a null sink leaves the turn unchanged" {
    const replies = [_]turn.AssistantReply{
        .{
            .response = .{ .tool_calls = &[_]turn.ToolCall{
                .{ .id = "toolu_stub", .name = "stub", .args_json = "{}" },
            } },
        },
        .{ .response = .{ .final_text = "inspection complete" } },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, stub_tool);

    const result = try runTurnWith(testing.allocator, seq.asClient(), &registry, &tr, "run the stub", .{});
    try testing.expectEqual(turn.TurnState.done, result.final_state);
    // Counting still happens with no sink attached, so the fields are usable
    // by callers that do not want a log.
    try testing.expectEqual(@as(u32, 1), result.tool_calls_gate_passed);
    try testing.expect(result.first_gate_failure == null);
}

test "retry: one bad draft then one good draft lands a proof card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    const replies = [_]turn.AssistantReply{
        .{ .response = .{ .change_set = .{ .file = "handler.ts", .content = bad_handler } } },
        .{ .response = .{ .change_set = .{ .file = "handler.ts", .content = clean_handler } } },
    };
    var seq: SequenceClient = .{ .replies = &replies };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        seq.asClient(),
        &registry,
        &tr,
        "add a GET route",
        .{ .workspace_root = workspace_root },
    );

    try testing.expectEqual(@as(u8, 2), result.attempt);
    try testing.expectEqual(@as(u32, 1), result.veto_retry_count);
    try testing.expect(!result.rawFirstDraftVetoPass());
    try testing.expect(!result.firstAttemptGreen());
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(clean_handler, written);
}

test "approval callback can block an otherwise verified edit from being written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add a GET route",
        .{
            .workspace_root = workspace_root,
            .approval_fn = ApprovalFn.fromFn(autoReject),
        },
    );

    switch (tr.at(tr.len() - 1).*) {
        .system_note => |note| try testing.expect(std.mem.indexOf(u8, note, "not applied") != null),
        else => return error.TestFailed,
    }
    var apply_results: usize = 0;
    for (tr.entries.items) |entry| switch (entry) {
        .tool_result => |result| apply_results += @intFromBool(std.mem.eql(u8, result.tool_name, "propose_change_set")),
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), apply_results);
    switch (try compaction.prepare(testing.allocator, &tr, 1)) {
        .not_compactable => |reason| try testing.expect(reason != .invalid_tool_pair),
        .no_change, .ready => {},
    }
    try testing.expect(!file_io.fileExists(testing.allocator, written_path));
}

test "workspace change during approval fails closed without overwriting concurrent bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    const original = "const original = true;\n";
    const concurrent = "const concurrent = true;\n";
    try file_io.writeFile(testing.allocator, written_path, original);

    var race: ApprovalRace = .{
        .allocator = testing.allocator,
        .path = written_path,
        .expected_before = original,
        .concurrent_content = concurrent,
    };
    var canned: CannedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "handler.ts",
        .content = clean_handler,
    } } } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    // Ending the turn rather than raising: the transcript already closed the
    // synthetic propose_change_set call with the compiler verdict, so an error here
    // would leave "verified" as the last word on an edit that never landed.
    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "replace the handler",
        .{ .workspace_root = workspace_root, .approval_fn = race.callback() },
    );
    try testing.expectEqual(session_events.TurnEndReason.approval_denied, result.end_reason);
    try testing.expect(!result.applied_change_set);
    try testing.expect(race.saw_authoritative_before);
    switch (tr.at(tr.len() - 1).*) {
        .system_note => |note| try testing.expect(std.mem.indexOf(u8, note, "proof input changed") != null),
        else => return error.TestFailed,
    }
    const after = try file_io.readFile(testing.allocator, written_path, 1024);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(concurrent, after);
}

test "edit path outside the workspace is surfaced as a recoverable diagnostic, not a crash" {
    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "../outside-handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    // An out-of-workspace path is the model's mistake, not a fatal agent
    // error: the turn must complete (re-prompting the model) instead of
    // propagating the error and crashing the whole agent.
    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "escape the workspace",
        .{},
    );
    _ = result;

    var saw_path_diag = false;
    for (tr.entries.items) |*entry| {
        switch (entry.*) {
            .diagnostic_box => |box| {
                if (std.mem.indexOf(u8, box.llm_text, "PathOutsideWorkspace") != null and
                    std.mem.indexOf(u8, box.llm_text, "no source was written") != null)
                {
                    saw_path_diag = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_path_diag);
}

test "unreadable edit target fails closed as a recoverable baseline diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "handler.ts");
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{ .response = .{ .change_set = .{
        .file = "handler.ts",
        .content = clean_handler,
    } } } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "replace the unreadable target",
        .{ .workspace_root = workspace_root, .max_attempts = 1 },
    );

    var saw_baseline_failure = false;
    var saw_verified_change_set = false;
    for (tr.entries.items) |*entry| switch (entry.*) {
        .diagnostic_box => |box| {
            if (std.mem.indexOf(u8, box.llm_text, "authoritative source baselines") != null) {
                saw_baseline_failure = true;
            }
        },
        .verified_change_set => saw_verified_change_set = true,
        else => {},
    };
    try testing.expect(saw_baseline_failure);
    try testing.expect(!saw_verified_change_set);
}

test "resolveInsideWorkspace converts a relative root to absolute" {
    const abs = try tools_common.resolveInsideWorkspace(testing.allocator, ".", "build.zig");
    defer testing.allocator.free(abs);
    try testing.expect(std.fs.path.isAbsolute(abs));
    try testing.expect(std.mem.endsWith(u8, abs, "build.zig"));
}

test "recorded propose_change_set arguments carry a host digest without baseline bytes" {
    const host_bytes = "private host baseline";
    var changes = [_]change_set.PreparedChange{.{
        .authored_path = @constCast("handler.ts"),
        .resolved_path = @constCast("/unused/handler.ts"),
        .candidate = @constCast(clean_handler),
        .baseline = .{ .present = @constCast(host_bytes) },
        .baseline_sha256 = change_set.digestBaseline(host_bytes),
    }};
    const prepared: change_set.PreparedChangeSet = .{
        .workspace_root = @constCast("/unused"),
        .project_root = @constCast("/unused"),
        .changes = &changes,
    };
    const proposal: turn.ChangeSet = .{ .file = "handler.ts", .content = clean_handler };
    const args = try buildProposeChangeSetArgs(testing.allocator, proposal, &prepared);
    defer testing.allocator.free(args);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args, .{});
    defer parsed.deinit();

    const object = parsed.value.object.get("changes").?.array.items[0].object;
    try testing.expect(object.get("before") == null);
    try testing.expectEqualStrings("present", object.get("baseline_state").?.string);
    try testing.expectEqual(@as(usize, 64), object.get("baseline_sha256").?.string.len);
    try testing.expect(std.mem.indexOf(u8, args, host_bytes) == null);
}

test "autoApprove returns true for any preview" {
    const changes = [_]ChangePreview{.{ .file = "any/file.ts", .after = "x" }};
    try testing.expect(try autoApprove(.{ .proof_id = "proof", .changes = &changes, .system_proven = false }));
}

test "autoReject returns false for any preview" {
    const changes = [_]ChangePreview{.{ .file = "any/file.ts", .after = "x" }};
    try testing.expect(!try autoReject(.{ .proof_id = "proof", .changes = &changes, .system_proven = false }));
}

test "ApprovalPolicy enum is exported" {
    try testing.expect(@sizeOf(ApprovalPolicy) > 0);
}

test "replay_mode skips filesystem writes for a verified edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/src/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "src/handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add an ok response",
        .{ .workspace_root = workspace_root, .replay_mode = true },
    );

    try testing.expectEqual(turn.TurnState.done, result.final_state);
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    try testing.expect(!file_io.fileExists(testing.allocator, written_path));
}

test "replay_mode skips the approval callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add a GET route",
        .{
            .workspace_root = workspace_root,
            .approval_fn = ApprovalFn.fromFn(autoReject),
            .replay_mode = true,
        },
    );

    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    try testing.expect(!file_io.fileExists(testing.allocator, written_path));
}

test "replay_mode off preserves existing write behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/src/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "src/handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add an ok response",
        .{ .workspace_root = workspace_root, .replay_mode = false },
    );

    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(clean_handler, written);
}

test "verified edit path appends one aggregate receipt before the proof card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "write the handler",
        .{ .workspace_root = workspace_root },
    );
    try testing.expectEqual(turn.TurnState.done, result.final_state);

    // The proof card remains final; the aggregate receipt is immediately before
    // it and binds the exact committed after-image.
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    try testing.expect(tr.len() >= 2);
    switch (tr.at(tr.len() - 2).*) {
        .verified_change_set => |message| {
            try testing.expect(message.ui_payload != null);
            switch (message.ui_payload.?) {
                .verified_change_set => |payload| {
                    try testing.expectEqual(@as(usize, 64), payload.transaction_id.len);
                    try testing.expectEqual(@as(usize, 64), payload.policy_hash.len);
                    try testing.expectEqual(@as(usize, 1), payload.changes.len);
                    try testing.expectEqualStrings("handler.ts", payload.changes[0].file);
                    try testing.expectEqualStrings("absent", payload.changes[0].baseline_state);
                    try testing.expect(payload.changes[0].before == null);
                    try testing.expectEqualStrings(clean_handler, payload.changes[0].after);
                    try testing.expect(payload.proof_inputs.len > 0);
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    }
}

// A legal first-draft a model would naturally emit (an arrow-form handler)
// that passes the veto on the first attempt. The applied bytes are normalized
// on the way to disk; the file content, the attested `after`, and the
// `is_canonical` flag must all agree. Because every canonical-band rule is a
// hard `check` error that would itself fail the veto, an edit that reaches the
// green arm is already canonical, so normalize is a behavior-preserving no-op
// and the attested bytes equal the model's draft byte-for-byte.
const arrow_handler =
    "const handler = (req: Request): Proof<Response, \"deterministic\"> => Response.json({ok: true});";

test "legal first draft lands in one attempt and disk equals the aggregate receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "handler.ts",
            .content = arrow_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const result = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add an ok response",
        .{ .workspace_root = workspace_root },
    );

    // One attempt: the draft passed the veto without any retry_draft round.
    try testing.expectEqual(turn.TurnState.done, result.final_state);
    try testing.expectEqual(@as(u8, 1), result.attempt);

    // The aggregate receipt sits directly before the final proof card.
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    const attested = switch (tr.at(tr.len() - 2).*) {
        .verified_change_set => |message| blk: {
            switch (message.ui_payload.?) {
                .verified_change_set => |payload| {
                    try testing.expectEqual(@as(usize, 1), payload.changes.len);
                    break :blk payload.changes[0].after;
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    };

    // Disk bytes equal the exact after-image covered by the proof and receipt.
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(attested, written);
}

test "failed veto does not append a verified change-set receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "handler.ts",
            .content = bad_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add a bad handler",
        .{ .workspace_root = workspace_root, .max_attempts = 1 },
    );

    for (tr.entries.items) |*entry| {
        switch (entry.*) {
            .verified_change_set => return error.TestFailed,
            else => {},
        }
    }
}

test "providerErrorRemediation: SSE parse errors map to a non-empty actionable hint" {
    // EXP-12: a proxy-mangled stream previously printed a bare CamelCase name.
    const sse_errors = [_]anyerror{
        error.MalformedSse,
        error.MissingType,
        error.UnknownEventType,
        error.UnexpectedJsonShape,
    };
    for (sse_errors) |err| {
        const hint = providerErrorRemediation(err) orelse return error.TestFailed;
        try testing.expect(hint.len > 0);
        try testing.expect(std.mem.indexOf(u8, hint, "could not be parsed") != null);
    }
}

test "budget-exhausted prompt carries a concrete next step" {
    // EXP-9: the bare "budget exhausted" line must end with an actionable step.
    try testing.expect(budget_exhausted_next_step.len > 0);
    try testing.expect(std.mem.indexOf(u8, budget_exhausted_next_step, "zttp check") != null);
}

test "gate instrument: a proposed change set is counted as one tool call" {
    var collector = GateCollector{ .allocator = testing.allocator };
    defer collector.deinit();
    var sink = gate_record.GateSink{ .context = &collector, .record_fn = GateCollector.record };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .change_set = .{
            .file = "src/handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "add an ok response",
        .{ .workspace_root = workspace_root, .gate_sink = &sink, .task_class = "change_set" },
    );

    const rec = collector.records.items[0];
    try testing.expectEqual(@as(u32, 1), rec.tool_calls_total);
    try testing.expectEqual(@as(usize, 1), rec.calls.len);
    try testing.expectEqualStrings("propose_change_set", rec.calls[0].tool_name);
    try testing.expect(rec.calls[0].gate_pass);
    try testing.expectEqual(true, rec.calls[0].execution_ok.?);

    // The decisive negative: a change-set turn must not encode the way a turn
    // that made no tool call encodes.
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try gate_record.writeJsonl(rec, buf.writer());
    try testing.expect(std.mem.indexOf(u8, buf.written(), "\"tool_calls_total\":0") == null);
}
