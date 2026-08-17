//! Strict, provider-neutral capture boundary for one model exchange.
//!
//! The request snapshot and raw response borrow from the caller and are valid
//! only for the synchronous `record` call. A sink must copy any data it keeps.
//! The sink owns call ordering and advances its cursor only after the injected
//! recorder succeeds.

const model_request = @import("model_request.zig");
const propose_change_set = @import("anthropic/propose_change_set.zig");

pub const ResponseFieldPresence = struct {
    choices: bool = false,
    first_choice: bool = false,
    finish_reason: bool = false,
    message: bool = false,
    content: bool = false,
    reasoning: bool = false,
    tool_calls: bool = false,
    usage: bool = false,
    completion_tokens: bool = false,
};

pub const FinishReason = enum {
    stop,
    length,
    tool_calls,
    content_filter,
    function_call,
};

pub const ParserWarning = enum {
    transport_failed,
    response_too_large,
    json_parse_failed,
    root_not_object,
    choices_missing,
    choices_not_array,
    choices_empty,
    first_choice_not_object,
    finish_reason_invalid,
    finish_reason_unknown,
    finish_reason_null,
    message_missing,
    message_not_object,
    content_invalid,
    content_null,
    content_empty,
    tool_calls_invalid,
    tool_calls_empty,
    usage_missing,
    usage_invalid,
    completion_tokens_missing,
    completion_tokens_invalid,
    assistant_output_missing,
    sanitizer_rejected_response,
    capture_rejected_response,
    decoder_rejected_response,
};

/// Metadata-only observation of one provider response. The record intentionally
/// excludes prompts, response content, reasoning, tool arguments, arbitrary
/// provider strings, and user source.
pub const ResponseDiagnostics = struct {
    latency_ms: ?u64,
    /// Numeric HTTP status for a provider rejection. Null for successful
    /// responses and failures that occurred before an HTTP response arrived.
    http_status: ?u16 = null,
    finish_reason: ?FinishReason,
    completion_tokens: ?u64,
    field_presence: ResponseFieldPresence,
    parser_warnings: []const ParserWarning,
    failure: ?anyerror,
    /// Which `propose_change_set` refusal fired, when that is what failed.
    ///
    /// A tag, never content - it names a branch in `maybeRemap`, not anything
    /// the model wrote, so the metadata-only guarantee above still holds. It
    /// exists because `InvalidChangeSetArgs` alone cannot be acted on: ten
    /// refusals shared it, and the body that would tell them apart is gone by
    /// the time this record is written.
    change_set_rejection: ?propose_change_set.RejectionShape = null,
};

/// The only request metadata visible to a diagnostic observer. Keep this
/// narrower than ModelRequestSnapshot so observers cannot access prompts,
/// transcript items, tool arguments, or user source.
pub const ResponseDiagnosticContext = struct {
    provider: model_request.Provider,
    model: []const u8,
};

/// One response body the decoder refused, held for diagnosis.
///
/// This is the single deliberate exception to the metadata-only rule above, and
/// it exists because that rule made a class of failure unexplainable: a refusal
/// whose cause is in the bytes cannot be diagnosed from a tag naming the branch
/// that fired. The exception is bounded on every side - it carries only a
/// response the decoder already rejected, only the sanitized bytes that would
/// have entered a cassette had they decoded, and a sink is free to write
/// nothing. It never carries a prompt, a transcript, or user source.
pub const RejectedResponse = struct {
    /// The decoder error that refused this body.
    failure: anyerror,
    /// Which `propose_change_set` refusal fired, when that is what failed.
    change_set_rejection: ?propose_change_set.RejectionShape,
    /// Sanitized response bytes, borrowed for this call only.
    body: []const u8,
};

pub const CaptureSink = struct {
    context: *anyopaque,
    record_fn: *const fn (
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void,
    /// Optional best-effort observer. A diagnostics failure must never replace
    /// the transport, capture, or parser result for the model call.
    diagnostics_fn: ?*const fn (
        context: *anyopaque,
        attempt_index: usize,
        diagnostic_context: ResponseDiagnosticContext,
        diagnostics: ResponseDiagnostics,
    ) anyerror!void = null,
    /// Optional best-effort quarantine for a body the decoder refused. Like the
    /// observer above, a failure here must never replace the transport, capture,
    /// or parser result for the model call.
    quarantine_fn: ?*const fn (
        context: *anyopaque,
        attempt_index: usize,
        diagnostic_context: ResponseDiagnosticContext,
        rejection: RejectedResponse,
    ) anyerror!void = null,
    /// Strict capture cursor. It advances only after record_fn succeeds.
    next_call_index: usize = 0,
    /// Diagnostic sequence. It includes failures that happen before capture.
    next_diagnostic_attempt_index: usize = 0,

    pub fn record(
        self: *CaptureSink,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) !void {
        try self.record_fn(self.context, self.next_call_index, snapshot, raw_response);
        self.next_call_index += 1;
    }

    /// Hand a refused body to the sink under the attempt index the next
    /// diagnostics row will carry, so the two can be read together. Call it
    /// before `recordDiagnostics` for the same failure: this reads the cursor
    /// and that one advances it.
    pub fn quarantineRejectedResponse(
        self: *CaptureSink,
        diagnostic_context: ResponseDiagnosticContext,
        rejection: RejectedResponse,
    ) void {
        const quarantine = self.quarantine_fn orelse return;
        quarantine(
            self.context,
            self.next_diagnostic_attempt_index,
            diagnostic_context,
            rejection,
        ) catch {};
    }

    pub fn recordDiagnostics(
        self: *CaptureSink,
        diagnostic_context: ResponseDiagnosticContext,
        diagnostics: ResponseDiagnostics,
    ) void {
        const diagnose = self.diagnostics_fn orelse return;
        const attempt_index = self.next_diagnostic_attempt_index;
        self.next_diagnostic_attempt_index +%= 1;
        diagnose(self.context, attempt_index, diagnostic_context, diagnostics) catch {};
    }
};
