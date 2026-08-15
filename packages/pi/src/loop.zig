//! Expert loop driver. Pumps transcript state, Anthropic replies, compiler
//! veto results, and structured tool batches through `turn.TurnMachine`.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const turn = @import("turn.zig");
const veto = @import("veto.zig");
const transcript_mod = @import("transcript.zig");
const registry_mod = @import("registry/registry.zig");
const ui_payload_mod = @import("ui_payload.zig");
const proof_enrichment = @import("proof_enrichment.zig");
const zts = @import("zts");
const file_io = zts.file_io;
const apply_edit = @import("providers/anthropic/apply_edit.zig");
const tools_common = @import("tools/common.zig");
const json_writer = @import("providers/json_writer.zig");
const session_events = @import("session/events.zig");
const expert_workflow = @import("expert_workflow.zig");
const auto_repair = @import("auto_repair.zig");
const pi_goal_candidate = @import("tools/pi_goal_candidate.zig");
const zts_repair_writer = @import("tools/zts_repair_writer.zig");
const compaction = @import("compaction.zig");

const PostApplyReport = struct {
    ok: bool,
    summary: ?[]u8 = null,
};

const RepairLinks = struct {
    repair_plan_ids: [][]u8 = &.{},

    fn deinit(self: *RepairLinks, allocator: std.mem.Allocator) void {
        for (self.repair_plan_ids) |item| allocator.free(item);
        allocator.free(self.repair_plan_ids);
        self.* = .{};
    }
};

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
pub const ApprovalPreview = struct {
    file: []const u8,
    before: ?[]const u8 = null,
    after: []const u8 = "",
    properties: ?ui_payload_mod.PropertiesSnapshot = null,
    /// Canonical-normalization rewrites applied during salvage. Non-empty when
    /// the veto auto-fixed canonical violations before approval. Borrows from
    /// the veto report; does not outlive the run_veto arm's arena.
    rewrite_trace: []const []u8 = &.{},
};

pub const ApprovalFn = union(enum) {
    bare: *const fn (preview: ApprovalPreview) anyerror!bool,
    contextual: struct {
        context: *anyopaque,
        func: *const fn (context: *anyopaque, preview: ApprovalPreview) anyerror!bool,
    },

    pub fn fromFn(func: *const fn (preview: ApprovalPreview) anyerror!bool) ApprovalFn {
        return .{ .bare = func };
    }

    pub fn call(self: ApprovalFn, preview: ApprovalPreview) anyerror!bool {
        return switch (self) {
            .bare => |func| func(preview),
            .contextual => |wrapped| wrapped.func(wrapped.context, preview),
        };
    }
};

pub const ApprovalPolicy = enum { ask, auto_approve, auto_reject };

pub fn autoApprove(preview: ApprovalPreview) anyerror!bool {
    _ = preview;
    return true;
}

pub fn autoReject(preview: ApprovalPreview) anyerror!bool {
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
        error.OutputTruncated => "The edit was too large for one response and was cut off at the model's output limit. Split the change into smaller edits (edit one function or section at a time), or switch to a model with a larger output budget via `/model <id>`.",
        error.InvalidEditArgs => "The model sent an `apply_edit` call this host cannot accept: it must carry `file` and `content` only, and never a baseline the host owns. Retry the ask.",
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
    applied_edit: bool = false,
    /// Proof guarantees discharged / tracked on the applied edit, counted at the
    /// veto (see PropertiesSnapshot.guaranteeCounts). Both 0 when no edit applied.
    proven_guarantees: u32 = 0,
    tracked_guarantees: u32 = 0,
    /// Host-classified workflow for this turn. The hint is advisory; compiler
    /// veto remains the authority on whether edits can land.
    workflow_kind: expert_workflow.TaskKind = .unknown,
    workflow_confidence: expert_workflow.Confidence = .low,
    workflow_hint_injected: bool = false,
    /// True when the first model draft passed the edit-simulate veto. This is
    /// a quality signal for "expert first draft" effectiveness, not an apply
    /// authorization.
    first_draft_veto_pass: bool = false,
    veto_retry_count: u32 = 0,
    tool_call_count: u32 = 0,
    /// True when this turn applied a compiler-authored repair candidate with no
    /// model round-trip (the model's draft failed veto, the deterministic lane
    /// produced a fix that passed the full veto, and it landed through the
    /// approval gate). The headline "model-free apply" signal.
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
    /// Host-only write edge for exact bound protocol repairs. It is injected
    /// here, never registered as a model or RPC tool.
    repair_writer: zts_repair_writer.RepairWriter = zts_repair_writer.protocol_writer,
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

/// Opening words of the tool result the loop writes when the veto rejects a
/// draft. Unlike the two above this is a `function_call_output` body, not a user
/// message, which is what makes it usable to tell "past the apply step because
/// the edit landed" from "past it because the compiler bounced it".
pub const veto_reject_preamble = "The compiler rejected this edit.";

/// Upper bound on repairs the in-process auto-repair lane chains onto one
/// failed draft before producing a candidate. Matches pi_goal_candidate's
/// max_repairs cap; a draft needing more distinct fixes than this falls back to
/// an enriched model retry.
const max_auto_repairs: usize = 8;

const PreparedEdit = struct {
    edit: turn.Edit,
    resolved_path: []const u8,
    before: ?[]const u8,
    baseline_sha256: [32]u8,

    fn deinit(self: *PreparedEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved_path);
        if (self.before) |before| allocator.free(before);
        self.* = undefined;
    }
};

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

/// Serialize a model edit draft into `apply_edit` tool-input JSON so the draft
/// can be recorded in the transcript as an assistant tool call. Recording the
/// draft on the wire - paired with the compiler veto verdict as a tool_result -
/// is what makes the retry loop information-complete: the diagnostics the model
/// must fix reference bytes it can actually see, and the context survives a
/// mid-repair tool call instead of evaporating with a transient prompt.
fn buildApplyEditArgs(
    allocator: std.mem.Allocator,
    edit: turn.Edit,
    prepared: ?*const PreparedEdit,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"file\":");
    try json_writer.writeString(w, edit.file);
    try w.writeAll(",\"content\":");
    try json_writer.writeString(w, edit.content);
    if (prepared) |host| {
        const digest_hex = std.fmt.bytesToHex(host.baseline_sha256, .lower);
        try w.writeAll(",\"baseline_state\":\"");
        try w.writeAll(if (host.before == null) "absent" else "present");
        try w.writeAll("\",\"baseline_sha256\":\"");
        try w.writeAll(&digest_hex);
        try w.writeByte('"');
    }
    try w.writeByte('}');
    return try buf.toOwnedSlice();
}

/// Append the `tool_result` that closes a draft's synthetic `apply_edit` tool
/// call. Every path out of `.run_veto` must call this so the transcript never
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
        .tool_name = "apply_edit",
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

/// SQL escalation hint appended to a failed-draft tool_result once the SQL veto
/// has failed twice in a turn, so the model gets diagnostic guidance without
/// burning a blind attempt.
const sql_escalation_hint =
    "\n\nYou have failed the SQL check twice. Common causes: " ++
    "(a) the query references a table or column not in the schema, " ++
    "(b) you used a non-supported SQL statement (only SELECT/INSERT/UPDATE/DELETE with named parameters). " ++
    "Use the zts_expert_describe_rule tool to look up ZTS3xx SQL rules, " ++
    "or ask the user to verify the schema path in zttp.json.";

pub fn runTurnWith(
    allocator: std.mem.Allocator,
    client: ModelClient,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    user_text: []const u8,
    options: RunOptions,
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
    // Compiler-authored repair guidance for the most recent failed draft, built
    // by the in-process repair lane on a veto failure and folded into that
    // draft's failed tool_result so the model gets the exact fix - persisted in
    // the transcript, not a transient prompt. Arena-owned; null when the lane
    // produced no actionable plans.
    var auto_repair_block: ?[]const u8 = null;
    // Project SQL schema for the veto, discovered lazily on the first edit
    // attempt and reused for every retry in the turn (the discovery walks the
    // filesystem for zttp.json; once per turn is enough). Arena-owned.
    var sql_schema_resolved = false;
    var sql_schema_path: ?[]u8 = null;
    // How many times a SQL veto has failed in this turn. When it reaches 2, an
    // extra escalation hint is folded into the failed draft's tool_result so the
    // model gets diagnostic guidance without burning another attempt blind.
    var sql_veto_fail_count: u32 = 0;
    // Set when this turn applies a compiler-verified edit; carries the proof
    // guarantee counts of the applied bytes back to the session layer for metrics.
    var applied_edit = false;
    var applied_proven: u32 = 0;
    var applied_tracked: u32 = 0;
    var first_draft_veto_pass = false;
    var veto_retry_count: u32 = 0;
    // Set when this turn lands a compiler-authored repair candidate model-free
    // (Phase B). Carried into the TurnResult so the session layer can report
    // "% of edits that became model-free".
    var compiler_authored_apply = false;

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
                veto_retry_count += 1;
                model_roundtrips += 1;
                // The failed draft and its full diagnostic - plus any compiler-
                // authored repair block and SQL escalation - are already in the
                // transcript as an `apply_edit` tool_use paired with a failed
                // tool_result (see the `.run_veto` arm). The model can therefore
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
            .run_veto => |edit| {
                // Record the model's draft as an `apply_edit` tool call so the
                // retry loop is information-complete: the draft's bytes and the
                // compiler's verdict live in the transcript (as a tool_use/
                // tool_result pair) instead of a transient prompt, so the model
                // can see exactly what it wrote and what was flagged - and that
                // context survives a mid-repair tool call. The id keys off the
                // transcript index so it is unique across the whole session
                // (required for `--resume` replay). Every exit from this arm must
                // append a matching tool_result to close the tool call.
                const edit_call_id = try std.fmt.allocPrint(ta, "apply_edit-{d}", .{transcript.len()});
                const prepared = prepareEdit(ta, options.workspace_root, edit) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const args_json = try buildApplyEditArgs(ta, edit, null);
                    const calls = [_]turn.ToolCall{.{ .id = edit_call_id, .name = "apply_edit", .args_json = args_json }};
                    try transcript.append(allocator, .{ .assistant_tool_use = &calls });
                    const msg = if (err == error.PathOutsideWorkspace)
                        try std.fmt.allocPrint(
                            ta,
                            "edit rejected: the file path `{s}` resolves outside the workspace " ++
                                "root. Use a path relative to the workspace (for example " ++
                                "`src/handler.ts`), not an absolute path or one that escapes the " ++
                                "project directory.",
                            .{edit.file},
                        )
                    else
                        try std.fmt.allocPrint(
                            ta,
                            "edit rejected: the host could not establish an authoritative baseline " ++
                                "for `{s}` ({s}); no edit was applied.",
                            .{ edit.file, @errorName(err) },
                        );
                    try transcript.append(allocator, .{ .diagnostic_box = .{ .llm_text = msg } });
                    try appendEditToolResult(allocator, transcript, edit_call_id, false, msg);
                    next_event = .{ .edit_verified = .{ .ok = false, .llm_text = msg } };
                    continue;
                };
                {
                    const args_json = try buildApplyEditArgs(ta, edit, &prepared);
                    const calls = [_]turn.ToolCall{.{ .id = edit_call_id, .name = "apply_edit", .args_json = args_json }};
                    try transcript.append(allocator, .{ .assistant_tool_use = &calls });
                }
                if (!sql_schema_resolved) {
                    sql_schema_resolved = true;
                    sql_schema_path = veto.discoverSqlSchemaPath(ta);
                }
                const veto_result = try veto.runVetoWithSchema(ta, .{
                    .file = prepared.edit.file,
                    .content = prepared.edit.content,
                    .before = prepared.before,
                }, sql_schema_path);
                // The outcome handed to the state machine. The model-free
                // repair path (Phase B) overrides it to a pass after it lands a
                // candidate, so the failed draft still drives the turn to done.
                var edit_event: turn.EditOutcome = veto_result.outcome;
                if (!veto_result.outcome.ok and veto_result.sql_failure) {
                    sql_veto_fail_count += 1;
                }
                // Close the draft's `apply_edit` tool call with the compiler's
                // verdict on the DRAFT itself (not `edit_event`, which Phase B may
                // flip to a pass). Appended here - before the success paths'
                // verified_patch/proof_card - so the tool_use is closed on every
                // exit and verified_patch stays adjacent to the proof card. On
                // failure the body carries the diagnostic plus any SQL escalation;
                // the compiler-authored repair block (built by the lane below) is
                // persisted afterwards as a follow-up system_note. Either way the
                // whole retry context lives in the transcript, not a transient
                // prompt, so it survives a mid-repair tool call.
                if (veto_result.outcome.ok) {
                    try appendEditToolResult(allocator, transcript, edit_call_id, true, "verified: all compiler checks passed");
                } else {
                    const sql_hint: []const u8 = if (veto_result.sql_failure and sql_veto_fail_count >= 2)
                        sql_escalation_hint
                    else
                        "";
                    const body = try std.fmt.allocPrint(
                        ta,
                        veto_reject_preamble ++ " Fix every flagged violation below:\n\n{s}{s}",
                        .{ veto_result.outcome.llm_text, sql_hint },
                    );
                    try appendEditToolResult(allocator, transcript, edit_call_id, false, body);
                }
                if (veto_result.outcome.ok and !options.replay_mode) {
                    if (machine.attempt == 1) first_draft_veto_pass = true;
                    const st = try applyVerifiedEdit(allocator, ta, registry, transcript, options, prepared, veto_result.report, null);
                    if (st.denied) {
                        return finishTurn(&machine, turn_usage, .approval_denied, model_roundtrips, applied_edit, applied_proven, applied_tracked, workflow_hint, workflow_hint_injected, first_draft_veto_pass, veto_retry_count, tool_calls_used, compiler_authored_apply);
                    }
                    applied_edit = st.applied;
                    applied_proven = st.proven;
                    applied_tracked = st.tracked;
                }
                // Failed draft: run the deterministic repair lane in-process on
                // the un-written draft. If it produces a candidate that ALSO
                // passes the full veto against the ORIGINAL pre-edit handler (the
                // authority - the lane only verifies repairs against the draft),
                // apply it model-free through the same approval gate and receipt
                // (Phase B). Otherwise feed the exact repair templates + smallest
                // witness into the next retry (Phase A). Skipped for SQL failures
                // (own escalation), zero-new-violation failures, and replay.
                if (!veto_result.outcome.ok and !options.replay_mode and
                    auto_repair.shouldRunLane(veto_result.sql_failure, veto_result.report.new))
                {
                    if (pi_goal_candidate.candidateFromSource(ta, prepared.edit.content, prepared.edit.file, &.{}, max_auto_repairs)) |cand_val| {
                        var cand = cand_val;
                        defer cand.deinit(ta);
                        var phase_b_applied = false;
                        if (cand.verified()) {
                            if (cand.proposed_content) |proposed| {
                                const synth: PreparedEdit = .{
                                    .edit = .{ .file = prepared.edit.file, .content = proposed },
                                    .resolved_path = prepared.resolved_path,
                                    .before = prepared.before,
                                    .baseline_sha256 = prepared.baseline_sha256,
                                };
                                const reveto = try veto.runVetoWithSchema(ta, .{
                                    .file = synth.edit.file,
                                    .content = synth.edit.content,
                                    .before = synth.before,
                                }, sql_schema_path);
                                if (reveto.outcome.ok) {
                                    const st = try applyVerifiedEdit(allocator, ta, registry, transcript, options, synth, reveto.report, cand.plan_ids);
                                    if (st.denied) {
                                        return finishTurn(&machine, turn_usage, .approval_denied, model_roundtrips, applied_edit, applied_proven, applied_tracked, workflow_hint, workflow_hint_injected, first_draft_veto_pass, veto_retry_count, tool_calls_used, compiler_authored_apply);
                                    }
                                    applied_edit = st.applied;
                                    applied_proven = st.proven;
                                    applied_tracked = st.tracked;
                                    compiler_authored_apply = true;
                                    // Carry the re-veto's proof HUD so the model-
                                    // free apply renders the same proof card as an
                                    // ordinary verified apply (ui_payload is on
                                    // `ta`, matching the model-green path above).
                                    edit_event = .{
                                        .ok = true,
                                        .llm_text = try ta.dupe(u8, "compiler-authored repair applied"),
                                        .ui_payload = reveto.outcome.ui_payload,
                                    };
                                    phase_b_applied = true;
                                }
                            }
                        }
                        if (!phase_b_applied) {
                            const block_opt = auto_repair.buildRetryBlock(ta, cand.plans_json) catch |err| switch (err) {
                                error.OutOfMemory => return err,
                                else => null,
                            };
                            if (block_opt) |block| auto_repair_block = block;
                        }
                    } else |err| switch (err) {
                        // Best-effort lane: a schema-less project or an
                        // unparseable plan just means no model-free repair this
                        // turn (fall back to the normal model retry). OOM is a
                        // real fault and must not be hidden behind the fallback.
                        error.OutOfMemory => return err,
                        else => {},
                    }
                }
                // Persist the compiler-authored repair block (Phase A) as a
                // follow-up note so the exact fix survives in the transcript for
                // the retry, instead of riding in a transient prompt that a
                // mid-repair tool call would erase. Phase B (model-free apply)
                // never sets it, and it is appended after the draft's failed
                // tool_result so both live in the same user turn on the wire.
                if (auto_repair_block) |block| {
                    auto_repair_block = null;
                    const note = try std.fmt.allocPrint(
                        ta,
                        compiler_repair_prefix ++ ". Apply these changes verbatim, then fix any remaining flagged violations:\n\n{s}",
                        .{block},
                    );
                    try transcript.append(allocator, .{ .system_note = note });
                }
                next_event = .{ .edit_verified = edit_event };
            },
            .invoke_tool_batch => |calls| {
                try transcript.append(allocator, .{ .assistant_tool_use = calls });

                const mixed_apply_edit = containsApplyEdit(calls) and calls.len > 1;
                const over_budget = calls.len > options.max_tool_batch_size or
                    tool_calls_used + calls.len > options.max_tool_calls_per_turn;

                if (mixed_apply_edit or over_budget) {
                    if (over_budget) hit_tool_budget = true;
                    for (calls) |call| {
                        const message = if (mixed_apply_edit)
                            "apply_edit was grouped with other tool calls. It must be issued alone in a single response so the compiler veto can run cleanly. Re-issue just the apply_edit call without any other tools."
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
                for (calls) |call| {
                    var result = try invokeToolRecovering(ta, registry, call);
                    defer result.deinit(ta);
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
                    applied_edit,
                    applied_proven,
                    applied_tracked,
                    workflow_hint,
                    workflow_hint_injected,
                    first_draft_veto_pass,
                    veto_retry_count,
                    tool_calls_used,
                    compiler_authored_apply,
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
                    applied_edit,
                    applied_proven,
                    applied_tracked,
                    workflow_hint,
                    workflow_hint_injected,
                    first_draft_veto_pass,
                    veto_retry_count,
                    tool_calls_used,
                    compiler_authored_apply,
                );
            },
            .end_turn => return finishTurn(
                &machine,
                turn_usage,
                if (hit_tool_budget) .budget_tool_calls else .approved,
                model_roundtrips,
                applied_edit,
                applied_proven,
                applied_tracked,
                workflow_hint,
                workflow_hint_injected,
                first_draft_veto_pass,
                veto_retry_count,
                tool_calls_used,
                compiler_authored_apply,
            ),
            .none => return finishTurn(
                &machine,
                turn_usage,
                if (hit_tool_budget) .budget_tool_calls else .approved,
                model_roundtrips,
                applied_edit,
                applied_proven,
                applied_tracked,
                workflow_hint,
                workflow_hint_injected,
                first_draft_veto_pass,
                veto_retry_count,
                tool_calls_used,
                compiler_authored_apply,
            ),
        }
    }
}

fn finishTurn(
    machine: *const turn.TurnMachine,
    usage: turn.Usage,
    reason: session_events.TurnEndReason,
    model_roundtrips: u8,
    applied_edit: bool,
    applied_proven: u32,
    applied_tracked: u32,
    workflow_hint: expert_workflow.WorkflowHint,
    workflow_hint_injected: bool,
    first_draft_veto_pass: bool,
    veto_retry_count: u32,
    tool_calls_used: usize,
    compiler_authored_apply: bool,
) TurnResult {
    return .{
        .final_state = machine.state,
        .attempt = machine.attempt,
        .usage = usage,
        .end_reason = reason,
        .roundtrips = model_roundtrips,
        .applied_edit = applied_edit,
        .proven_guarantees = applied_proven,
        .tracked_guarantees = applied_tracked,
        .workflow_kind = workflow_hint.kind,
        .workflow_confidence = workflow_hint.confidence,
        .workflow_hint_injected = workflow_hint_injected,
        .first_draft_veto_pass = first_draft_veto_pass,
        .veto_retry_count = veto_retry_count,
        .tool_call_count = @intCast(@min(tool_calls_used, std.math.maxInt(u32))),
        .compiler_authored_apply = compiler_authored_apply,
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

fn containsApplyEdit(calls: []const turn.ToolCall) bool {
    for (calls) |call| {
        if (std.mem.eql(u8, call.name, apply_edit.tool_name)) return true;
    }
    return false;
}

fn prepareEdit(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    edit: turn.Edit,
) !PreparedEdit {
    const target_path = try tools_common.resolveInsideWorkspace(allocator, workspace_root, edit.file);
    errdefer allocator.free(target_path);

    const before: ?[]const u8 = file_io.readFile(allocator, target_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    errdefer if (before) |bytes| allocator.free(bytes);

    return .{
        .edit = edit,
        .resolved_path = target_path,
        .before = before,
        .baseline_sha256 = baselineDigest(before),
    };
}

fn baselineDigest(before: ?[]const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (before) |bytes| {
        hasher.update("present\x00");
        hasher.update(bytes);
    } else {
        hasher.update("absent\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn verifyBaselineUnchanged(allocator: std.mem.Allocator, prepared: PreparedEdit) !void {
    const current: ?[]u8 = file_io.readFile(allocator, prepared.resolved_path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        error.FileTooBig => return error.WorkspaceChangedBeforeApply,
        else => return err,
    };
    defer if (current) |bytes| allocator.free(bytes);
    const current_digest = baselineDigest(current);
    if (!std.mem.eql(u8, &current_digest, &prepared.baseline_sha256)) {
        return error.WorkspaceChangedBeforeApply;
    }
}

fn applyPreparedEdit(
    allocator: std.mem.Allocator,
    prepared: PreparedEdit,
    content: []const u8,
) !void {
    const parent = std.fs.path.dirname(prepared.resolved_path);
    if (parent) |dir_path| {
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io_backend.io(), dir_path);
    }
    try file_io.writeFile(allocator, prepared.resolved_path, content);
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

/// Apply an already-veto-passed edit: surface the approval preview, write the
/// (normalized) bytes, run the post-apply regression checks, and append the
/// verified-patch receipt. Shared by the model-green path and the model-free
/// compiler-repair path (Phase B) so both go through the exact same approval
/// gate and equivalence receipt. `repair_plan_ids_override` is non-null only
/// for the compiler-repair path, where the plan ids come from the in-process
/// candidate rather than a transcript tool_result.
fn applyVerifiedEdit(
    allocator: std.mem.Allocator,
    ta: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    options: RunOptions,
    prepared: PreparedEdit,
    report: veto.VetoReport,
    repair_plan_ids_override: ?[]const []const u8,
) !ApplyState {
    // The bytes that will actually be written (post-normalization). Bound here
    // so the approval preview shows exactly what lands.
    const applied_content = report.normalized_content orelse prepared.edit.content;
    const protocol_repair: ?ui_payload_mod.ProtocolRepairPayload = if (repair_plan_ids_override == null)
        try findRecentProtocolRepair(
            ta,
            transcript,
            options.workspace_root,
            prepared.edit.file,
            prepared.edit.content,
        )
    else
        null;
    if (protocol_repair != null and !std.mem.eql(u8, applied_content, prepared.edit.content)) {
        return error.ProtocolRepairNormalizationMismatch;
    }

    // Log canonical normalization to stderr in auto-approve mode so the user
    // knows what changed even when there is no prompt.
    const is_auto_approve: bool = if (options.approval_fn) |fn_| switch (fn_) {
        .bare => |f| f == &autoApprove,
        else => false,
    } else false;
    if (is_auto_approve and report.rewrite_trace.len > 0) {
        var buf: [512]u8 = undefined;
        var fw = std.Io.Writer.fixed(&buf);
        fw.writeAll("note: canonical normalization applied ") catch {};
        fw.print("{d}", .{report.rewrite_trace.len}) catch {};
        fw.writeAll(" rewrite(s): ") catch {};
        for (report.rewrite_trace, 0..) |rname, ri| {
            if (ri > 0) fw.writeAll(", ") catch {};
            fw.writeAll(rname) catch {};
        }
        fw.writeByte('\n') catch {};
        const out = fw.buffered();
        _ = std.c.write(std.c.STDERR_FILENO, out.ptr, out.len);
    }

    if (options.approval_fn) |approve| {
        const preview: ApprovalPreview = .{
            .file = prepared.edit.file,
            .before = prepared.before,
            .after = applied_content,
            .properties = report.after_properties,
            .rewrite_trace = report.rewrite_trace,
        };
        if (!try approve.call(preview)) {
            // The synthetic apply_edit call was already closed with the
            // compiler verdict before the approval boundary. Record the human
            // decision as internal continuation context instead of inventing a
            // second, unmatched tool result that would invalidate provider
            // history and make later compaction impossible.
            try transcript.append(allocator, .{
                .system_note = "edit verified but not applied by user approval policy",
            });
            return .{ .denied = true };
        }
    }

    // Normalize-on-apply: `applied_content` is the veto's Canonical Normal Form
    // reduction, fed to BOTH the disk write and the verified-patch entry so the
    // file on disk, the equivalence receipt (after=applied), and the transcript
    // attest the same bytes.
    //
    // A workspace changed under the approval prompt ends the turn the same way a
    // denial does. Raising out of here instead would leave the transcript's
    // "verified: all compiler checks passed" tool result as the last word on an
    // edit that was never written, and a resumed session would reason from a
    // file it believes it changed.
    verifyBaselineUnchanged(ta, prepared) catch |err| switch (err) {
        error.WorkspaceChangedBeforeApply => {
            try transcript.append(allocator, .{
                .system_note = "edit verified but not applied: the file changed on disk after the baseline was taken",
            });
            return .{ .denied = true };
        },
        else => return err,
    };
    var protocol_identity: ?zts_repair_writer.Applied = null;
    if (protocol_repair) |repair| {
        var io_backend = std.Io.Threaded.init(ta, .{ .environ = .empty });
        defer io_backend.deinit();
        var outcome = try options.repair_writer.apply(ta, io_backend.io(), .{
            .workspace_root = options.workspace_root,
            .file = prepared.edit.file,
            .repairs_json = repair.repairs_json,
            .expected = .{
                .profile_id = repair.profile_id,
                .policy_hash = repair.policy_hash,
                .module_graph_hash = repair.module_graph_hash,
            },
            .proposed_content = applied_content,
        });
        defer outcome.deinit(ta);
        switch (outcome) {
            .applied => |identity| protocol_identity = identity,
            .refused => |refusal| {
                const note = try std.fmt.allocPrint(
                    ta,
                    "bound compiler repair refused before write: {s}: {s}",
                    .{ refusal.code, refusal.message },
                );
                try transcript.append(allocator, .{ .system_note = note });
                return error.ProtocolRepairRefused;
            },
        }
    } else {
        try applyPreparedEdit(ta, prepared, applied_content);
    }
    const post_apply = try postApplyCheck(allocator, ta, registry, transcript, prepared, applied_content);
    defer if (post_apply.summary) |s| allocator.free(s);
    try appendVerifiedPatchEntry(
        allocator,
        transcript,
        options.workspace_root,
        prepared,
        applied_content,
        report,
        post_apply,
        repair_plan_ids_override,
        protocol_identity,
    );
    var st: ApplyState = .{ .applied = true };
    if (report.after_properties) |snap| {
        const counts = snap.guaranteeCounts();
        st.proven = counts.proven;
        st.tracked = counts.tracked;
    }
    return st;
}

/// One post-apply tool check. The tool name + args + diagnostic prefix +
/// summary text all vary per check; the surrounding "lookup, invoke,
/// transcribe on failure, update report" ceremony is identical. Bundling
/// here so the two checks in `postApplyCheck` stay one-call-site each
/// instead of two ~25-line nested blocks.
const PostCheckSpec = struct {
    tool_name: []const u8,
    args_json: []const u8,
    note_prefix: []const u8,
    summary: []const u8,
    /// `true` for the review-patch check, which is meant to override an
    /// earlier `verify_paths regressed` summary because the review's
    /// finding is more specific. `false` for verify_paths, which only
    /// sets the summary if nothing has set it yet.
    overwrite_summary: bool,
};

fn runPostApplyTool(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    report: *PostApplyReport,
    spec: PostCheckSpec,
) !void {
    if (registry.findByName(spec.tool_name) == null) return;

    // Note: invokeJson errors are propagated up to postApplyCheck which
    // catches them and returns the report-so-far, preserving the
    // original `catch return report` short-circuit semantics.
    var result = try registry.invokeJson(arena, spec.tool_name, spec.args_json);
    defer result.deinit(arena);
    if (result.ok) return;

    const note = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spec.note_prefix, result.llm_text });
    defer allocator.free(note);
    try transcript.append(allocator, .{ .diagnostic_box = .{
        .llm_text = note,
        .ui_payload = if (result.ui_payload) |payload|
            try payload.clone(allocator)
        else
            null,
    } });

    report.ok = false;
    if (spec.overwrite_summary) {
        // Null the field BEFORE the free, then re-assign. If `dupe` later
        // OOMs the field is null rather than dangling; otherwise the
        // caller's `runPostApplyTool(...) catch return report` would
        // swallow the error and the outer call site's
        // `defer if (post_apply.summary) |s| allocator.free(s);` would
        // free the already-freed pointer. Guards against the regression
        // verified in the prior code review (CONFIRMED at loop.zig:393).
        if (report.summary) |s| {
            report.summary = null;
            allocator.free(s);
        }
        report.summary = try allocator.dupe(u8, spec.summary);
    } else if (report.summary == null) {
        report.summary = try allocator.dupe(u8, spec.summary);
    }
}

fn postApplyCheck(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    registry: *const registry_mod.Registry,
    transcript: *transcript_mod.Transcript,
    prepared: PreparedEdit,
    applied_content: []const u8,
) !PostApplyReport {
    var report: PostApplyReport = .{ .ok = true, .summary = null };
    errdefer if (report.summary) |s| allocator.free(s);

    // Build the args JSON with the escaping writer rather than raw {s}
    // interpolation: edit.file is model-controlled, so a quote/backslash/control
    // char would otherwise produce malformed JSON and silently disable this
    // post-apply regression gate.
    const verify_paths_args = blk: {
        var buf = TextBuffer.init(arena);
        const w = buf.writer();
        try w.writeAll("{\"file\":");
        try json_writer.writeString(w, prepared.edit.file);
        try w.writeByte('}');
        break :blk buf.written();
    };
    runPostApplyTool(allocator, arena, registry, transcript, &report, .{
        .tool_name = "zts_expert_verify_paths",
        .args_json = verify_paths_args,
        .note_prefix = "post-apply regression: verify_paths found violations\n",
        .summary = "verify_paths regressed",
        .overwrite_summary = false,
    }) catch return report;

    if (prepared.before) |before| {
        const review_args = blk: {
            var buf = TextBuffer.init(arena);
            const w = buf.writer();
            // review_patch requires "file" and "content" (the applied bytes) and
            // takes "before" so diff_only can mark genuinely new violations.
            // Omitting content silently disabled this gate ("missing content").
            try w.writeAll("{\"file\":");
            try json_writer.writeString(w, prepared.edit.file);
            try w.writeAll(",\"content\":");
            try json_writer.writeString(w, applied_content);
            try w.writeAll(",\"before\":");
            try json_writer.writeString(w, before);
            try w.writeAll(",\"diff_only\":true}");
            break :blk buf.written();
        };
        runPostApplyTool(allocator, arena, registry, transcript, &report, .{
            .tool_name = "zts_expert_review_patch",
            .args_json = review_args,
            .note_prefix = "post-apply diff review: new violations found\n",
            .summary = "review_patch flagged new violations",
            .overwrite_summary = true,
        }) catch return report;
    }

    return report;
}

fn appendVerifiedPatchEntry(
    allocator: std.mem.Allocator,
    transcript: *transcript_mod.Transcript,
    workspace_root: []const u8,
    prepared: PreparedEdit,
    applied_content: []const u8,
    report: veto.VetoReport,
    post_apply: PostApplyReport,
    repair_plan_ids_override: ?[]const []const u8,
    protocol_identity: ?zts_repair_writer.Applied,
) !void {
    const workspace_root_abs = try std.fs.path.resolve(allocator, &.{workspace_root});
    defer allocator.free(workspace_root_abs);
    // Repair-plan provenance: the model-free compiler-repair path passes its
    // candidate's plan ids directly (there is no pi_apply_repair_plan
    // tool_result in the transcript to scan). The model path passes null and we
    // recover the links from the transcript, keying on the model's *proposed*
    // content (what the candidate tool emitted), not the post-normalize bytes,
    // a candidate the model echoed verbatim should still link even if normalize
    // then canonicalized it on the way to disk.
    var owned_links: ?RepairLinks = null;
    defer if (owned_links) |*l| l.deinit(allocator);
    const repair_plan_ids: []const []const u8 = if (repair_plan_ids_override) |ids| ids else blk: {
        owned_links = try collectRecentRepairLinks(
            allocator,
            transcript,
            workspace_root_abs,
            prepared.edit.file,
            prepared.edit.content,
        );
        break :blk (owned_links orelse return error.MissingRepairLinks).repair_plan_ids;
    };

    // `after` (the equivalence-receipt after-image), the disk write, and the
    // transcript all attest `applied_content`, the canonicalized bytes.
    const payload: ui_payload_mod.UiPayload = .{ .verified_patch = try proof_enrichment.buildVerifiedPatchPayload(
        allocator,
        .{
            .workspace_root = workspace_root_abs,
            .file = prepared.edit.file,
            .before = prepared.before,
            .after = applied_content,
            .policy_hash = report.policy_hash,
            .source_digest = if (protocol_identity) |identity| &identity.source_digest else null,
            .module_graph_hash = if (protocol_identity) |identity| &identity.module_graph_hash else null,
            .applied_at_unix_ms = tools_common.nowUnixMs(),
            .post_apply_ok = post_apply.ok,
            .post_apply_summary = post_apply.summary,
            .transcript = transcript,
            .repair_plan_ids = repair_plan_ids,
            .emit_perf_receipt = true,
            .is_canonical = report.is_canonical,
            .rewrite_trace = report.rewrite_trace,
        },
    ) };
    errdefer {
        var owned = payload;
        owned.deinit(allocator);
    }

    const patch = payload.verified_patch;
    const summary_line = try std.fmt.allocPrint(
        allocator,
        "verified: {s} ({s}, {d} total, {d} new, {d} preexisting)",
        .{
            patch.file,
            if (patch.prove) |prove| prove.classification else "unclassified",
            patch.stats.total,
            patch.stats.new,
            patch.stats.preexisting orelse 0,
        },
    );
    errdefer allocator.free(summary_line);

    try transcript.entries.append(allocator, .{ .verified_patch = .{
        .llm_text = summary_line,
        .ui_payload = payload,
    } });
}

fn collectRecentRepairLinks(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    workspace_root_abs: []const u8,
    file: []const u8,
    content: []const u8,
) !RepairLinks {
    const file_abs = try std.fs.path.resolve(allocator, &.{ workspace_root_abs, file });
    defer allocator.free(file_abs);
    var i = transcript.len();
    while (i > 0) {
        i -= 1;
        switch (transcript.at(i).*) {
            .tool_result => |result| {
                if (std.mem.eql(u8, result.tool_name, "pi_apply_repair_plan")) {
                    if (try repairLinksFromCandidate(allocator, result.ui_payload, workspace_root_abs, file_abs, content)) |links| return links;
                }
            },
            else => {},
        }
    }
    return .{};
}

/// Match only the exact v2 preview tool result for this path and the model's
/// proposed bytes. A near match is not a protocol repair: semantic apply_edit
/// remains available, but a selected bound repair can never be reconstructed
/// from text or a broad diagnostic.
fn findRecentProtocolRepair(
    allocator: std.mem.Allocator,
    transcript: *const transcript_mod.Transcript,
    workspace_root: []const u8,
    file: []const u8,
    content: []const u8,
) !?ui_payload_mod.ProtocolRepairPayload {
    const workspace_root_abs = try std.fs.path.resolve(allocator, &.{workspace_root});
    defer allocator.free(workspace_root_abs);
    const file_abs = try std.fs.path.resolve(allocator, &.{ workspace_root_abs, file });
    defer allocator.free(file_abs);

    var i = transcript.len();
    while (i > 0) {
        i -= 1;
        switch (transcript.at(i).*) {
            .user_text => break,
            .tool_result => |result| {
                if (!std.mem.eql(u8, result.tool_name, "pi_apply_repair_plan")) continue;
                const payload = result.ui_payload orelse continue;
                switch (payload) {
                    .protocol_repair => |repair| {
                        const candidate_abs = try std.fs.path.resolve(
                            allocator,
                            &.{ workspace_root_abs, repair.path },
                        );
                        defer allocator.free(candidate_abs);
                        if (!std.mem.eql(u8, candidate_abs, file_abs)) continue;
                        if (!std.mem.eql(u8, repair.proposed_content, content)) continue;
                        return repair;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return null;
}

fn repairLinksFromCandidate(
    allocator: std.mem.Allocator,
    payload: ?ui_payload_mod.UiPayload,
    workspace_root_abs: []const u8,
    file_abs: []const u8,
    content: []const u8,
) !?RepairLinks {
    const value = payload orelse return null;
    return switch (value) {
        .repair_candidate => |candidate| blk: {
            const candidate_abs = try std.fs.path.resolve(allocator, &.{ workspace_root_abs, candidate.path });
            defer allocator.free(candidate_abs);
            if (!std.mem.eql(u8, candidate_abs, file_abs)) break :blk null;
            if (!std.mem.eql(u8, candidate.proposed_content, content)) break :blk null;
            const repair_plan_ids = try allocator.alloc([]u8, 1);
            errdefer allocator.free(repair_plan_ids);
            repair_plan_ids[0] = try allocator.dupe(u8, candidate.plan_id);
            break :blk .{ .repair_plan_ids = repair_plan_ids };
        },
        else => null,
    };
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
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

const bad_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { var x = 1; return Response.json({x}); }";
const clean_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ok: true}); }";
const protocol_before_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { let ok = true; return Response.json({ok}); }";
const protocol_after_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> { const ok = true; return Response.json({ok}); }";

fn protocolPreviewExecute(
    allocator: std.mem.Allocator,
    _: []const []const u8,
) anyerror!registry_mod.ToolResult {
    var payload: ui_payload_mod.UiPayload = .{ .protocol_repair = try ui_payload_mod.ProtocolRepairPayload.init(
        allocator,
        "handler.ts",
        protocol_after_handler,
        "[{\"intent\":\"replace_let_with_const\",\"bound\":{\"source_digest\":\"source\",\"profile_id\":\"zts-advanced-1\",\"policy_hash\":\"policy\",\"module_graph_hash\":\"graph\"}}]",
        "source",
        "zts-advanced-1",
        "policy",
        "graph",
        "0 new, 0 preexisting",
        .{ .total = 0, .new = 0, .preexisting = 0 },
    ) };
    errdefer payload.deinit(allocator);
    return .{
        .ok = true,
        .llm_text = try allocator.dupe(u8, "{\"schema_version\":2,\"operation\":\"simulate_edit\",\"success\":true}"),
        .ui_payload = payload,
    };
}

const protocol_preview_tool: registry_mod.ToolDef = .{
    .name = "pi_apply_repair_plan",
    .label = "test protocol repair preview",
    .effect = .read_workspace,
    .context_policy = .exact,
    .description = "Test-only protocol repair preview",
    .input_schema = "{\"type\":\"object\"}",
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = protocolPreviewExecute,
};

const ApprovalRace = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_before: []const u8,
    concurrent_content: []const u8,
    saw_authoritative_before: bool = false,

    fn approve(context: *anyopaque, preview: ApprovalPreview) anyerror!bool {
        const self: *ApprovalRace = @ptrCast(@alignCast(context));
        self.saw_authoritative_before = preview.before != null and
            std.mem.eql(u8, preview.before.?, self.expected_before);
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

    fn approve(context: *anyopaque, preview: ApprovalPreview) anyerror!bool {
        const self: *ApprovalCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.saw_after = std.mem.eql(u8, preview.after, self.expected_after);
        return self.approve_result;
    }

    fn callback(self: *ApprovalCapture) ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = approve } };
    }
};

const RecordingRepairWriter = struct {
    calls: u32 = 0,
    refuse: bool = false,

    fn apply(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        request: zts_repair_writer.ApplyRequest,
    ) anyerror!zts_repair_writer.Outcome {
        const self: *RecordingRepairWriter = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.refuse) {
            const code = try allocator.dupe(u8, "test_refusal");
            errdefer allocator.free(code);
            return .{ .refused = .{
                .code = code,
                .message = try allocator.dupe(u8, "writer refused"),
            } };
        }

        const absolute = try tools_common.resolveInsideWorkspace(allocator, request.workspace_root, request.file);
        defer allocator.free(absolute);
        try file_io.writeFile(allocator, absolute, request.proposed_content);
        var source_digest: [64]u8 = undefined;
        @memset(&source_digest, 'a');
        var module_graph_hash: [64]u8 = undefined;
        @memset(&module_graph_hash, 'b');
        return .{ .applied = .{
            .source_digest = source_digest,
            .module_graph_hash = module_graph_hash,
        } };
    }

    fn capability(self: *RecordingRepairWriter) zts_repair_writer.RepairWriter {
        return .{ .context = self, .apply_fn = apply };
    }
};

// Accesses result.value without checking result.ok: a HandlerVerifier error
// (ZTS303 unchecked_result_value) that the repair lane can author a fix for.
const unchecked_result_handler =
    "import { validateJson } from \"zttp:validate\";\n" ++
    "function handler(req: Request): Proof<Response, \"deterministic\"> {\n" ++
    "  const result = validateJson(\"item\", req.body ?? \"\");\n" ++
    "  const data = result.value;\n" ++
    "  return Response.json({ data });\n" ++
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
        .{ .response = .{ .edit = .{ .file = "src/handler.ts", .content = unchecked_result_handler } } },
        .{ .response = .{ .edit = .{ .file = "src/handler.ts", .content = clean_handler } } },
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
    try testing.expect(result.applied_edit);
    try testing.expect(result.compiler_authored_apply);
    try testing.expectEqual(@as(u32, 0), result.veto_retry_count);
    try testing.expect(!client.saw_repair_block);
    try testing.expectEqual(@as(usize, 1), client.index); // second reply never requested

    // The compiler-authored guard is what actually landed on disk.
    const written = try file_io.readFile(testing.allocator, written_path, 1 << 20);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "if (!result.ok)") != null);
}

// A client that records, on each roundtrip after the first, whether the failed
// draft (recorded as an `apply_edit` tool_use) and the compiler diagnostic
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
                        if (std.mem.eql(u8, call.name, "apply_edit") and
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
            1 => .{ .reply = .{ .response = .{ .edit = .{ .file = "handler.ts", .content = bad_handler } } } },
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
        .system_note => |body| try testing.expect(std.mem.indexOf(u8, body, "submit exactly one `apply_edit` call so the host veto checks the draft") != null),
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
        .response = .{ .edit = .{
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
        .proof_card => |body| try testing.expect(std.mem.indexOf(u8, body.llm_text, "\"total\":0") != null),
        else => return error.TestFailed,
    }
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(clean_handler, written);
}

test "broken edit path: veto fails with diagnostic box" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
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
            try testing.expect(std.mem.indexOf(u8, body.llm_text, "\"ZTS001\"") != null);
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

test "retry: one bad draft then one good draft lands a proof card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    const replies = [_]turn.AssistantReply{
        .{ .response = .{ .edit = .{ .file = "handler.ts", .content = bad_handler } } },
        .{ .response = .{ .edit = .{ .file = "handler.ts", .content = clean_handler } } },
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
    try testing.expect(!result.first_draft_veto_pass);
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
        .response = .{ .edit = .{
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
        .tool_result => |result| apply_results += @intFromBool(std.mem.eql(u8, result.tool_name, "apply_edit")),
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), apply_results);
    switch (try compaction.prepare(testing.allocator, &tr, 1)) {
        .not_compactable => |reason| try testing.expect(reason != .invalid_tool_pair),
        .no_change, .ready => {},
    }
    try testing.expect(!file_io.fileExists(testing.allocator, written_path));
}

test "approved bound repair uses host writer once and receipts returned identity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);
    try file_io.writeFile(testing.allocator, written_path, protocol_before_handler);

    const replies = [_]turn.AssistantReply{
        .{ .response = .{ .tool_calls = &[_]turn.ToolCall{.{
            .id = "toolu_protocol_repair",
            .name = "pi_apply_repair_plan",
            .args_json = "{\"path\":\"handler.ts\",\"repairs\":[]}",
        }} } },
        .{ .response = .{ .edit = .{ .file = "handler.ts", .content = protocol_after_handler } } },
    };
    var sequence: SequenceClient = .{ .replies = &replies };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, protocol_preview_tool);
    var approval: ApprovalCapture = .{ .approve_result = true, .expected_after = protocol_after_handler };
    var writer: RecordingRepairWriter = .{};

    const result = try runTurnWith(
        testing.allocator,
        sequence.asClient(),
        &registry,
        &transcript,
        "apply the bound repair",
        .{
            .workspace_root = workspace_root,
            .approval_fn = approval.callback(),
            .repair_writer = writer.capability(),
        },
    );
    try testing.expect(result.applied_edit);
    try testing.expectEqual(@as(u32, 1), approval.calls);
    try testing.expect(approval.saw_after);
    try testing.expectEqual(@as(u32, 1), writer.calls);
    const on_disk = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(protocol_after_handler, on_disk);

    var found_receipt = false;
    for (transcript.entries.items) |entry| switch (entry) {
        .verified_patch => |message| switch (message.ui_payload.?) {
            .verified_patch => |patch| {
                found_receipt = true;
                try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", patch.source_digest.?);
                try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", patch.module_graph_hash.?);
                try testing.expectEqual(@as(usize, 0), patch.repair_plan_ids.len);
            },
            else => return error.TestExpectedVerifiedPatch,
        },
        else => {},
    };
    try testing.expect(found_receipt);
}

test "bound repair selection does not cross an external user boundary" {
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var preview = try protocolPreviewExecute(testing.allocator, &.{});
    defer preview.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "old_preview",
        .tool_name = "pi_apply_repair_plan",
        .ok = preview.ok,
        .llm_text = preview.llm_text,
        .ui_payload = preview.ui_payload,
    } });
    try transcript.append(testing.allocator, .{ .user_text = "a different request" });
    try testing.expect(try findRecentProtocolRepair(
        testing.allocator,
        &transcript,
        ".",
        "handler.ts",
        protocol_after_handler,
    ) == null);
}

test "bound repair rejection never calls writer and writer refusal never falls back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);
    try file_io.writeFile(testing.allocator, written_path, protocol_before_handler);

    const replies = [_]turn.AssistantReply{
        .{ .response = .{ .tool_calls = &[_]turn.ToolCall{.{
            .id = "toolu_protocol_repair",
            .name = "pi_apply_repair_plan",
            .args_json = "{\"path\":\"handler.ts\",\"repairs\":[]}",
        }} } },
        .{ .response = .{ .edit = .{ .file = "handler.ts", .content = protocol_after_handler } } },
    };
    var denied_sequence: SequenceClient = .{ .replies = &replies };
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, protocol_preview_tool);
    var rejected_writer: RecordingRepairWriter = .{};

    const denied = try runTurnWith(
        testing.allocator,
        denied_sequence.asClient(),
        &registry,
        &transcript,
        "reject the bound repair",
        .{
            .workspace_root = workspace_root,
            .approval_fn = ApprovalFn.fromFn(autoReject),
            .repair_writer = rejected_writer.capability(),
        },
    );
    try testing.expectEqual(session_events.TurnEndReason.approval_denied, denied.end_reason);
    try testing.expectEqual(@as(u32, 0), rejected_writer.calls);
    const after_denial = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(after_denial);
    try testing.expectEqualStrings(protocol_before_handler, after_denial);

    var refusal_transcript: transcript_mod.Transcript = .{};
    defer refusal_transcript.deinit(testing.allocator);
    var refusal_sequence: SequenceClient = .{ .replies = &replies };
    var refusing_writer: RecordingRepairWriter = .{ .refuse = true };
    try testing.expectError(
        error.ProtocolRepairRefused,
        runTurnWith(
            testing.allocator,
            refusal_sequence.asClient(),
            &registry,
            &refusal_transcript,
            "apply a refused bound repair",
            .{
                .workspace_root = workspace_root,
                .approval_fn = ApprovalFn.fromFn(autoApprove),
                .repair_writer = refusing_writer.capability(),
            },
        ),
    );
    try testing.expectEqual(@as(u32, 1), refusing_writer.calls);
    const after_refusal = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(after_refusal);
    try testing.expectEqualStrings(protocol_before_handler, after_refusal);

    const concurrent = "const concurrent = true;\n";
    var race: ApprovalRace = .{
        .allocator = testing.allocator,
        .path = written_path,
        .expected_before = protocol_before_handler,
        .concurrent_content = concurrent,
    };
    var race_transcript: transcript_mod.Transcript = .{};
    defer race_transcript.deinit(testing.allocator);
    var race_sequence: SequenceClient = .{ .replies = &replies };
    var race_writer: RecordingRepairWriter = .{};
    const raced = try runTurnWith(
        testing.allocator,
        race_sequence.asClient(),
        &registry,
        &race_transcript,
        "race the bound repair",
        .{
            .workspace_root = workspace_root,
            .approval_fn = race.callback(),
            .repair_writer = race_writer.capability(),
        },
    );
    try testing.expectEqual(session_events.TurnEndReason.approval_denied, raced.end_reason);
    try testing.expect(race.saw_authoritative_before);
    try testing.expectEqual(@as(u32, 0), race_writer.calls);
    const after_race = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(after_race);
    try testing.expectEqualStrings(concurrent, after_race);
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
    var canned: CannedClient = .{ .reply = .{ .response = .{ .edit = .{
        .file = "handler.ts",
        .content = clean_handler,
    } } } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    // Ending the turn rather than raising: the transcript already closed the
    // synthetic apply_edit call with the compiler verdict, so an error here
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
    try testing.expect(!result.applied_edit);
    try testing.expect(race.saw_authoritative_before);
    switch (tr.at(tr.len() - 1).*) {
        .system_note => |note| try testing.expect(std.mem.indexOf(u8, note, "changed on disk") != null),
        else => return error.TestFailed,
    }
    const after = try file_io.readFile(testing.allocator, written_path, 1024);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(concurrent, after);
}

test "edit path outside the workspace is surfaced as a recoverable diagnostic, not a crash" {
    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
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
                if (std.mem.indexOf(u8, box.llm_text, "outside the workspace") != null) {
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

    var canned: CannedClient = .{ .reply = .{ .response = .{ .edit = .{
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
    var saw_verified_patch = false;
    for (tr.entries.items) |*entry| switch (entry.*) {
        .diagnostic_box => |box| {
            if (std.mem.indexOf(u8, box.llm_text, "authoritative baseline") != null) {
                saw_baseline_failure = true;
            }
        },
        .verified_patch => saw_verified_patch = true,
        else => {},
    };
    try testing.expect(saw_baseline_failure);
    try testing.expect(!saw_verified_patch);
}

test "resolveInsideWorkspace converts a relative root to absolute" {
    const abs = try tools_common.resolveInsideWorkspace(testing.allocator, ".", "build.zig");
    defer testing.allocator.free(abs);
    try testing.expect(std.fs.path.isAbsolute(abs));
    try testing.expect(std.mem.endsWith(u8, abs, "build.zig"));
}

test "prepareEdit accepts an in-tree relative path under the default '.' root" {
    // Regression guard: std.fs.path.resolve is lexical, so a relative
    // workspace_root (".") used to leave every relative edit path rejected as
    // "outside the workspace" - which meant the agent could never apply an
    // edit in --print mode. The root must be anchored at the real cwd.
    var prepared = try prepareEdit(testing.allocator, ".", .{
        .file = "src/handler.ts",
        .content = "x",
    });
    defer prepared.deinit(testing.allocator);
    try testing.expect(std.fs.path.isAbsolute(prepared.resolved_path));
    try testing.expect(std.mem.endsWith(u8, prepared.resolved_path, "src/handler.ts"));
}

test "prepareEdit distinguishes absent, empty, and existing host baselines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const existing_path = try std.fmt.allocPrint(testing.allocator, "{s}/existing.ts", .{workspace_root});
    defer testing.allocator.free(existing_path);
    try file_io.writeFile(testing.allocator, existing_path, "host bytes");

    var existing = try prepareEdit(testing.allocator, workspace_root, .{
        .file = "existing.ts",
        .content = "replacement",
    });
    defer existing.deinit(testing.allocator);
    try testing.expectEqualStrings("host bytes", existing.before.?);
    const expected_existing = baselineDigest("host bytes");
    try testing.expectEqualSlices(u8, &expected_existing, &existing.baseline_sha256);

    var absent = try prepareEdit(testing.allocator, workspace_root, .{
        .file = "new.ts",
        .content = "new file",
    });
    defer absent.deinit(testing.allocator);
    try testing.expect(absent.before == null);
    const absent_digest = baselineDigest(null);
    const empty_digest = baselineDigest("");
    try testing.expect(!std.mem.eql(u8, &absent_digest, &empty_digest));
}

test "prepareEdit refuses a target larger than the authoritative baseline limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const large_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.ts", .{workspace_root});
    defer testing.allocator.free(large_path);
    const bytes = try testing.allocator.alloc(u8, 16 * 1024 * 1024 + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try file_io.writeFile(testing.allocator, large_path, bytes);

    try testing.expectError(error.FileTooBig, prepareEdit(testing.allocator, workspace_root, .{
        .file = "large.ts",
        .content = "replacement",
    }));
}

test "recorded apply_edit arguments carry a host digest without baseline bytes" {
    const host_bytes = "private host baseline";
    const prepared: PreparedEdit = .{
        .edit = .{ .file = "handler.ts", .content = clean_handler },
        .resolved_path = "/unused/handler.ts",
        .before = host_bytes,
        .baseline_sha256 = baselineDigest(host_bytes),
    };
    const args = try buildApplyEditArgs(testing.allocator, prepared.edit, &prepared);
    defer testing.allocator.free(args);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args, .{});
    defer parsed.deinit();

    const object = parsed.value.object;
    try testing.expect(object.get("before") == null);
    try testing.expectEqualStrings("present", object.get("baseline_state").?.string);
    try testing.expectEqual(@as(usize, 64), object.get("baseline_sha256").?.string.len);
    try testing.expect(std.mem.indexOf(u8, args, host_bytes) == null);
}

fn postApplyCheckProbe(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len != 1) return error.UnexpectedCheckInvocation;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args[0], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.UnexpectedCheckInvocation;
    const object = parsed.value.object;
    if (object.count() != 1 or object.get("paths") != null) return error.UnexpectedCheckInvocation;
    const file = object.get("file") orelse return error.UnexpectedCheckInvocation;
    if (file != .string or !std.mem.eql(u8, file.string, "handler.ts")) {
        return error.UnexpectedCheckInvocation;
    }
    return .{
        .ok = false,
        .llm_text = try allocator.dupe(
            u8,
            "{\"schema_version\":2,\"operation\":\"check\",\"profile_id\":\"zts-advanced-1\",\"compiler_version\":\"test\",\"policy_version\":\"test\",\"policy_hash\":\"p\",\"module_graph_hash\":\"m\",\"success\":false,\"payload\":{\"file\":\"handler.ts\"},\"diagnostics\":[]}",
        ),
    };
}

test "postApplyCheck rechecks the applied file exactly once with schema-v2 input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const check_tool: registry_mod.ToolDef = .{
        .name = "zts_expert_verify_paths",
        .label = "test check",
        .description = "test-only schema-v2 check probe",
        .effect = .read_workspace,
        .context_policy = .exact,
        .input_schema = "{\"type\":\"object\",\"properties\":{\"file\":{\"type\":\"string\"}},\"required\":[\"file\"]}",
        .decode_json = registry_mod.helpers.decodeJsonPassthrough,
        .execute = postApplyCheckProbe,
    };
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, check_tool);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    const prepared: PreparedEdit = .{
        .edit = .{ .file = "handler.ts", .content = clean_handler },
        .resolved_path = "/unused/handler.ts",
        .before = null,
        .baseline_sha256 = baselineDigest(null),
    };

    const report = try postApplyCheck(
        testing.allocator,
        arena.allocator(),
        &registry,
        &transcript,
        prepared,
        clean_handler,
    );
    defer if (report.summary) |summary| testing.allocator.free(summary);
    try testing.expect(!report.ok);
    try testing.expectEqualStrings("verify_paths regressed", report.summary.?);

    var diagnostic_boxes: usize = 0;
    for (transcript.entries.items) |entry| switch (entry) {
        .diagnostic_box => |box| {
            diagnostic_boxes += 1;
            try testing.expect(std.mem.indexOf(u8, box.llm_text, "\"schema_version\":2") != null);
            try testing.expect(std.mem.indexOf(u8, box.llm_text, "\"operation\":\"check\"") != null);
            try testing.expect(std.mem.indexOf(u8, box.llm_text, "\"checked_files\"") == null);
            try testing.expect(std.mem.indexOf(u8, box.llm_text, "\"violations\"") == null);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), diagnostic_boxes);
}

test "autoApprove returns true for any preview" {
    try testing.expect(try autoApprove(.{ .file = "any/file.zig", .after = "x" }));
}

test "autoReject returns false for any preview" {
    try testing.expect(!try autoReject(.{ .file = "any/file.zig", .after = "x" }));
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
        .response = .{ .edit = .{
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
        .response = .{ .edit = .{
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
        .response = .{ .edit = .{
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

test "verified edit path appends a verified_patch entry before the proof card" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
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

    // proof_card remains the final entry so the turn state machine contract is
    // unchanged; verified_patch is the entry immediately before it.
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    try testing.expect(tr.len() >= 2);
    switch (tr.at(tr.len() - 2).*) {
        .verified_patch => |message| {
            try testing.expect(message.ui_payload != null);
            switch (message.ui_payload.?) {
                .verified_patch => |payload| {
                    try testing.expectEqualStrings("handler.ts", payload.file);
                    try testing.expectEqual(@as(usize, 64), payload.policy_hash.len);
                    try testing.expect(payload.before == null);
                    try testing.expectEqualStrings(clean_handler, payload.after);
                    try testing.expect(payload.post_apply_ok);
                    try testing.expect(payload.post_apply_summary == null);
                    try testing.expectEqual(@as(u32, 0), payload.stats.new);
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

test "non-canonical-but-legal first draft lands in one attempt; disk == attested bytes and is_canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);
    const written_path = try std.fmt.allocPrint(testing.allocator, "{s}/handler.ts", .{workspace_root});
    defer testing.allocator.free(written_path);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
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

    // The verified_patch entry sits directly before the final proof card.
    switch (tr.at(tr.len() - 1).*) {
        .proof_card => {},
        else => return error.TestFailed,
    }
    const attested = switch (tr.at(tr.len() - 2).*) {
        .verified_patch => |message| blk: {
            switch (message.ui_payload.?) {
                .verified_patch => |payload| {
                    try testing.expect(payload.is_canonical);
                    break :blk payload.after;
                },
                else => return error.TestFailed,
            }
        },
        else => return error.TestFailed,
    };

    // Disk bytes == attested `after` bytes == the model's draft (normalize was
    // a behavior-preserving no-op for this veto-passing edit).
    const written = try file_io.readFile(testing.allocator, written_path, 1024 * 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(attested, written);
    try testing.expectEqualStrings(arrow_handler, written);
}

test "verified patch does not infer links from broad repair plan result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
            .file = "handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    const calls = [_]turn.ToolCall{
        .{ .id = "toolu_repair", .name = "pi_repair_plan", .args_json = "{\"path\":\"handler.ts\"}" },
    };
    try tr.append(testing.allocator, .{ .assistant_tool_use = &calls });
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_repair",
        .tool_name = "pi_repair_plan",
        .ok = false,
        .llm_text =
        \\{"ok":false,"plans":[{"id":"rp_001","closes":["wit_001"]},{"id":"rp_002","closes":["wit_002"]}]}
        ,
        .ui_payload = null,
    } });

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "write the handler",
        .{ .workspace_root = workspace_root },
    );

    switch (tr.at(tr.len() - 2).*) {
        .verified_patch => |message| switch (message.ui_payload.?) {
            .verified_patch => |payload| {
                try testing.expectEqual(@as(usize, 0), payload.repair_plan_ids.len);
                try testing.expectEqual(@as(usize, 0), payload.closed_witness_ids.len);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "verified patch records matching repair candidate plan link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
            .file = "handler.ts",
            .content = clean_handler,
        } },
    } };
    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(testing.allocator);
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);

    var candidate_payload: ui_payload_mod.UiPayload = .{ .repair_candidate = try ui_payload_mod.RepairCandidatePayload.init(
        testing.allocator,
        "handler.ts",
        "rp_candidate",
        "insert_guard_before_line",
        clean_handler,
        true,
        "0 total, 0 new, 0 preexisting",
        .{ .total = 0, .new = 0, .preexisting = 0 },
    ) };
    defer candidate_payload.deinit(testing.allocator);
    try tr.append(testing.allocator, .{ .tool_result = .{
        .tool_use_id = "toolu_apply_repair",
        .tool_name = "pi_apply_repair_plan",
        .ok = true,
        .llm_text = "{\"ok\":true,\"applied\":false}",
        .ui_payload = candidate_payload,
    } });

    _ = try runTurnWith(
        testing.allocator,
        canned.asClient(),
        &registry,
        &tr,
        "write the candidate",
        .{ .workspace_root = workspace_root },
    );

    switch (tr.at(tr.len() - 2).*) {
        .verified_patch => |message| switch (message.ui_payload.?) {
            .verified_patch => |payload| {
                try testing.expectEqual(@as(usize, 1), payload.repair_plan_ids.len);
                try testing.expectEqualStrings("rp_candidate", payload.repair_plan_ids[0]);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "failed veto does not append a verified_patch entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(testing.allocator, &tmp);
    defer testing.allocator.free(workspace_root);

    var canned: CannedClient = .{ .reply = .{
        .response = .{ .edit = .{
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
            .verified_patch => return error.TestFailed,
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
