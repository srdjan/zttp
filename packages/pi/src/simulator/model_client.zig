//! Fail-closed model client for one validated flow-cassette script.
//!
//! The client borrows its script and request config. It creates the same
//! canonical request snapshot as the production providers, validates the next
//! semantic checkpoint, and only then parses and replays the raw cassette.

const std = @import("std");
const artifact = @import("artifact.zig");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");
const cassette_client = @import("../providers/cassette_client.zig");
const chat_completions = @import("../providers/chat_completions.zig");
const anthropic_client = @import("../providers/anthropic/client.zig");
const openai_client = @import("../providers/openai/client.zig");
const model_request = @import("../providers/model_request.zig");
const context_budget = @import("../context_budget.zig");
const compaction = @import("../compaction.zig");

pub const Script = struct {
    provider: artifact.Provider,
    model: []const u8,
    evidence_class: artifact.EvidenceClass = .deterministic_harness,
    checkpoints: []const artifact.ModelCheckpoint,
    responses: []const artifact.ResponseFixture,
    fixtures: []const artifact.LoadedFixture,

    pub fn fromFlowCase(flow_case: *const artifact.FlowCase) Script {
        return .{
            .provider = flow_case.manifest.provider,
            .model = flow_case.manifest.model,
            .evidence_class = flow_case.manifest.evidence_class,
            .checkpoints = flow_case.trace.model_calls,
            .responses = flow_case.manifest.model_responses,
            .fixtures = flow_case.fixtures,
        };
    }
};

pub const Client = struct {
    script: Script,
    request_config: model_request.Config,
    cursor: usize = 0,
    last_mismatch: ?artifact.ReplayMismatch = null,
    input_anchor: ?context_budget.InputAnchor = null,

    pub fn init(script: Script, request_config: model_request.Config) Client {
        return .{ .script = script, .request_config = request_config };
    }

    pub fn asModelClient(self: *Client) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }

    pub fn asSummarizer(self: *Client) compaction.Summarizer {
        return .{ .context = self, .summarize_fn = summarizeFn };
    }

    pub fn consumedCount(self: *const Client) usize {
        return self.cursor;
    }

    pub fn lastMismatch(self: *const Client) ?artifact.ReplayMismatch {
        return self.last_mismatch;
    }

    pub fn finish(self: *Client) !void {
        if (self.cursor < self.script.checkpoints.len) {
            return self.fail(.{ .unconsumed_checkpoint = self.detail(.trace) });
        }
        if (self.cursor < self.script.responses.len) {
            return self.fail(.{ .response_overflow = self.detail(.response) });
        }
    }

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.request(arena, transcript, extra_user_text);
    }

    fn request(
        self: *Client,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !loop.ModelCallResult {
        return self.requestWithConfig(arena, self.request_config, transcript, extra_user_text);
    }

    fn requestWithConfig(
        self: *Client,
        arena: std.mem.Allocator,
        request_config: model_request.Config,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !loop.ModelCallResult {
        self.last_mismatch = null;
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = request_config,
            .transcript = transcript,
            .extra_user_text = extra_user_text,
        });
        defer snapshot.deinit(arena);
        _ = try prepareSnapshot(arena, &snapshot);

        const checkpoint = try self.validateSnapshot(&snapshot);
        const response = try self.responseFor(checkpoint);
        const raw = try self.responseBytes(response);
        const cassette = cassette_client.loadCassetteFromBytes(arena, raw, null) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SidecarNotFound, error.SidecarUnreadable => return self.failResponseFixture(.unreadable),
            else => return self.failResponseFixture(.malformed),
        };
        if (cassette.header.provider != self.script.provider) {
            return self.fail(.{ .response_order_mismatch = self.detail(.response) });
        }
        if (checkpoint.wire_request_sha256) |expected| {
            const actual = cassette.header.request_sha256 orelse
                return self.fail(.{ .response_order_mismatch = self.detail(.response) });
            if (!std.mem.eql(u8, expected.slice(), actual)) {
                return self.fail(.{ .response_order_mismatch = self.detail(.response) });
            }
        } else if (cassette.header.request_sha256 != null) {
            return self.fail(.{ .response_order_mismatch = self.detail(.response) });
        }

        const result = cassette_client.replay(arena, cassette) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.failResponseFixture(.malformed),
        };
        const reported_input = try context_budget.normalizeLogicalInput(self.script.provider, result.usage);
        if (checkpoint.normalized_input_tokens) |expected_input| {
            if (reported_input != expected_input) {
                return self.fail(.{ .normalized_input_mismatch = self.detailFor(.trace, checkpoint) });
            }
        }
        // Production tracks stable normal-request usage only. Summarization is
        // separately accounted and a compaction projection starts a new usage
        // epoch, so replay must not let either contaminate the normal anchor.
        if (self.script.evidence_class == .empirical_model and
            reported_input > 0 and
            request_config.purpose == .normal)
        {
            const budget = snapshot.budget orelse return error.IncompleteRequestPreparation;
            const epoch: context_budget.UsageEpoch = .{
                .provider = self.script.provider,
                .model = self.script.model,
                .checkpoint_generation = snapshot.projection_first_kept_entry_id orelse 0,
            };
            const selected = try context_budget.selectInputEstimate(.{
                .epoch = epoch,
                .current_budget = budget,
                .anchor = self.input_anchor,
            });
            const observed = try context_budget.observeLogicalInput(.{
                .epoch = epoch,
                .current_budget = budget,
                .anchor = self.input_anchor,
                .reported_tokens = reported_input,
            });
            context_budget.validateCalibration(selected.tokens, observed.logical_input_tokens) catch |err| {
                std.debug.print(
                    "[request-budget] {s} call {d}: estimated={d} ({s})" ++
                        " reported={d} logical={d} ({s})" ++
                        " bytes(system={d}, tools={d}, history={d}, transient={d}, framing={d}, wire={d}): {s}\n",
                    .{
                        self.script.model,
                        self.cursor,
                        selected.tokens,
                        @tagName(selected.source),
                        observed.reported_tokens,
                        observed.logical_input_tokens,
                        @tagName(observed.source),
                        budget.bytes.system,
                        budget.bytes.tools,
                        budget.bytes.history,
                        budget.bytes.transient,
                        budget.bytes.framing,
                        budget.bytes.wire,
                        @errorName(err),
                    },
                );
                return err;
            };
            self.input_anchor = .{
                .usage = .{ .epoch = epoch, .logical_input_tokens = observed.logical_input_tokens },
                .budget = budget,
            };
        }
        self.cursor += 1;
        return result;
    }

    fn summarizeFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        summary_request: compaction.SummaryRequest,
    ) anyerror!compaction.SummaryResponse {
        const self: *Client = @ptrCast(@alignCast(context));
        var transcript: transcript_mod.Transcript = .{};
        defer transcript.deinit(arena);
        try transcript.append(arena, .{ .user_text = summary_request.user_prompt });
        var config = self.request_config;
        config.system_prompt = summary_request.system_prompt;
        config.tools_json = null;
        config.max_output_tokens = summary_request.max_output_tokens;
        config.purpose = .summarization;
        config.cache_policy = .disabled;
        const result = try self.requestWithConfig(arena, config, &transcript, null);
        return .{ .response = result.reply.response, .usage = result.usage };
    }

    fn validateSnapshot(
        self: *Client,
        snapshot: *const model_request.ModelRequestSnapshot,
    ) !*const artifact.ModelCheckpoint {
        if (self.cursor >= self.script.checkpoints.len) {
            // The replay wants a model call the recording does not hold. The
            // recorded sequence ended here and the live run did not, so the
            // divergence is already behind us - what identifies it is this
            // request's context digest against the digests the script holds.
            // Printed because `response_underflow` carries no index once the
            // cursor is past the end, so the detail is empty by construction.
            std.debug.print(
                "[replay-underflow] wanted call {d}, script holds {d}\n" ++
                    "  request_context {s}\n" ++
                    "  transcript      {s}\n",
                .{
                    self.cursor,
                    self.script.checkpoints.len,
                    snapshot.request_context_sha256.slice(),
                    snapshot.transcript_sha256.slice(),
                },
            );
            for (self.script.checkpoints, 0..) |cp, i| {
                std.debug.print(
                    "  script[{d}] turn={d} call={d} request_context {s}\n",
                    .{ i, cp.turn_index, cp.call_index, cp.request_context_sha256.slice() },
                );
            }
            return self.fail(.{ .response_underflow = self.detail(.trace) });
        }
        const checkpoint = &self.script.checkpoints[self.cursor];
        if (checkpoint.index != self.cursor) {
            return self.fail(.{ .response_order_mismatch = self.detailFor(.trace, checkpoint) });
        }
        if (snapshot.config.provider != self.script.provider or
            !std.mem.eql(u8, snapshot.config.model, self.script.model))
        {
            return self.fail(.{ .provider_request_mismatch = self.detailFor(.trace, checkpoint) });
        }
        if (!std.mem.eql(
            u8,
            snapshot.request_context_sha256.slice(),
            checkpoint.request_context_sha256.slice(),
        )) {
            return self.fail(.{ .model_context_mismatch = self.detailFor(.trace, checkpoint) });
        }
        const item_count: u32 = std.math.cast(u32, snapshot.items.len) orelse
            return self.fail(.{ .transcript_or_transient_prompt_mismatch = self.detailFor(.trace, checkpoint) });
        const item_count_differs = item_count != checkpoint.transcript_prefix_count;
        const transcript_differs = !std.mem.eql(
            u8,
            snapshot.transcript_sha256.slice(),
            checkpoint.transcript_sha256.slice(),
        );
        const transient_differs = !optionalDigestEql(
            snapshot.transient_user_text_sha256,
            checkpoint.transient_user_text_sha256,
        );
        const wire_differs = !optionalDigestEql(
            snapshot.wire_request_sha256,
            checkpoint.wire_request_sha256,
        );
        const projection_differs = snapshot.projection_first_kept_entry_id !=
            checkpoint.projection_first_kept_entry_id;
        if (item_count_differs or transcript_differs or transient_differs or wire_differs or projection_differs) {
            // One mismatch kind covers five distinct inputs, and which one moved
            // is the whole diagnosis: a differing item count is a transcript the
            // replay grew differently, while a differing wire digest with an
            // equal transcript is a request the client framed differently.
            std.debug.print(
                "[replay-detail] call {d}: items {d} vs {d}{s}{s}{s}\n",
                .{
                    self.cursor,
                    item_count,
                    checkpoint.transcript_prefix_count,
                    if (transcript_differs) ", transcript digest differs" else "",
                    if (transient_differs) ", transient prompt digest differs" else "",
                    if (wire_differs) ", wire request digest differs" else "",
                },
            );
            // With equal item counts the divergence is content, and the newest
            // items are the ones this call added. The recording stores digests
            // rather than text, so the replay side is the only text available;
            // printing it bounded is what turns "some tool differs" into a name.
            if (transcript_differs and !item_count_differs) {
                const tail_start = snapshot.items.len -| 2;
                for (snapshot.items[tail_start..], tail_start..) |item, index| {
                    switch (item) {
                        .tool_result => |result| std.debug.print(
                            "[replay-detail]   item {d} tool_result {s} ok={} text[0..240]={s}\n",
                            .{ index, result.tool_name, result.ok, boundedPrefix(result.llm_text) },
                        ),
                        .tool_use => |use| std.debug.print(
                            "[replay-detail]   item {d} tool_use {s} args={s}\n",
                            .{ index, use.name, boundedPrefix(use.args_json) },
                        ),
                        else => std.debug.print(
                            "[replay-detail]   item {d} {s}\n",
                            .{ index, @tagName(std.meta.activeTag(item)) },
                        ),
                    }
                }
            }
            if (projection_differs) {
                std.debug.print(
                    "[replay-detail]   projection cut {any} vs {any}\n",
                    .{
                        snapshot.projection_first_kept_entry_id,
                        checkpoint.projection_first_kept_entry_id,
                    },
                );
            }
            return self.fail(.{ .transcript_or_transient_prompt_mismatch = self.detailFor(.trace, checkpoint) });
        }
        if (checkpoint.request_budget) |expected_budget| {
            const actual_budget = snapshot.budget orelse
                return self.fail(.{ .request_budget_mismatch = self.detailFor(.trace, checkpoint) });
            if (!requestBudgetEql(actual_budget, expected_budget)) {
                return self.fail(.{ .request_budget_mismatch = self.detailFor(.trace, checkpoint) });
            }
        }
        return checkpoint;
    }

    fn responseFor(
        self: *Client,
        checkpoint: *const artifact.ModelCheckpoint,
    ) !*const artifact.ResponseFixture {
        if (self.cursor >= self.script.responses.len) {
            return self.fail(.{ .response_underflow = self.detailFor(.response, checkpoint) });
        }
        const response = &self.script.responses[self.cursor];
        if (response.index != checkpoint.index or response.turn_index != checkpoint.turn_index or
            response.call_index != checkpoint.call_index)
        {
            return self.fail(.{ .response_order_mismatch = self.detailFor(.response, checkpoint) });
        }
        return response;
    }

    fn responseBytes(self: *Client, response: *const artifact.ResponseFixture) ![]const u8 {
        for (self.script.fixtures) |fixture| {
            if (fixture.role != .response or !std.mem.eql(u8, fixture.path, response.path)) continue;
            const actual = artifact.Sha256Hex.fromBytes(fixture.bytes);
            if (!actual.eql(response.sha256)) {
                return self.failResponseFixture(.digest_mismatch);
            }
            return fixture.bytes;
        }
        return self.failResponseFixture(.missing);
    }

    fn failResponseFixture(
        self: *Client,
        kind: artifact.ResponseFixtureFailure,
    ) error{ReplayMismatch} {
        const mismatch_detail = self.detail(.response);
        return self.fail(.{ .response_fixture_mismatch = .{
            .component = mismatch_detail.component,
            .turn_index = mismatch_detail.turn_index,
            .call_index = mismatch_detail.call_index,
            .kind = kind,
        } });
    }

    fn detail(self: *const Client, component: artifact.Component) artifact.MismatchDetail {
        if (self.cursor >= self.script.checkpoints.len) return .{ .component = component };
        return self.detailFor(component, &self.script.checkpoints[self.cursor]);
    }

    fn detailFor(
        self: *const Client,
        component: artifact.Component,
        checkpoint: *const artifact.ModelCheckpoint,
    ) artifact.MismatchDetail {
        _ = self;
        return .{
            .component = component,
            .turn_index = checkpoint.turn_index,
            .call_index = checkpoint.call_index,
        };
    }

    fn fail(self: *Client, mismatch: artifact.ReplayMismatch) error{ReplayMismatch} {
        self.last_mismatch = mismatch;
        return error.ReplayMismatch;
    }
};

/// Complete the simulator's provider-neutral request preparation exactly once.
/// Recorder tests use this same seam so capture and replay cannot drift on
/// output clamping, hard admission, or Chat Completions wire hashing.
pub fn prepareSnapshot(
    arena: std.mem.Allocator,
    snapshot: *model_request.ModelRequestSnapshot,
) ![]const u8 {
    var body = switch (snapshot.config.provider) {
        .local, .deepseek => try chat_completions.buildRequestBodyFromSnapshot(arena, snapshot),
        .anthropic => try anthropic_client.buildRequestBodyFromSnapshot(arena, snapshot),
        .openai => try openai_client.buildRequestBodyFromSnapshot(arena, snapshot),
    };
    try snapshot.completePreparation(body);
    if (try snapshot.clampOutputToRemainingContext()) {
        body = switch (snapshot.config.provider) {
            .local, .deepseek => try chat_completions.buildRequestBodyFromSnapshot(arena, snapshot),
            .anthropic => try anthropic_client.buildRequestBodyFromSnapshot(arena, snapshot),
            .openai => try openai_client.buildRequestBodyFromSnapshot(arena, snapshot),
        };
        try snapshot.completePreparation(body);
    }
    try snapshot.requireHardAdmission();
    snapshot.wire_request_sha256 = model_request.Sha256Hex.fromRawBytes(body);
    return body;
}

/// A short, single-line window onto a tool payload. Diagnostics must not
/// paste a whole tool result into the build log.
fn boundedPrefix(text: []const u8) []const u8 {
    const limit = @min(text.len, 240);
    return text[0..limit];
}

fn optionalDigestEql(
    actual: ?model_request.Sha256Hex,
    expected: ?artifact.Sha256Hex,
) bool {
    if (actual == null or expected == null) return actual == null and expected == null;
    const actual_digest = actual orelse return false;
    const expected_digest = expected orelse return false;
    return std.mem.eql(u8, actual_digest.slice(), expected_digest.slice());
}

fn requestBudgetEql(
    actual: context_budget.RequestBudget,
    expected: context_budget.RequestBudget,
) bool {
    return std.mem.eql(u8, actual.estimator, expected.estimator) and
        std.meta.eql(actual.bytes, expected.bytes) and
        std.meta.eql(actual.tokens, expected.tokens) and
        std.meta.eql(actual.limits, expected.limits);
}
