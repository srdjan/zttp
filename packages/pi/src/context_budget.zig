//! Pure, provider-neutral request-size accounting.
//!
//! This module measures and characterizes requests. Admission, projection,
//! and compaction remain separate policy layers so observing a request cannot
//! change the bytes sent by a provider client.

const std = @import("std");
const models = @import("providers/models.zig");
const turn = @import("turn.zig");

pub const estimator_version = "estimated_logical_input_v2";
pub const soft_input_target_tokens: u64 = 40_000;
pub const default_reserve_tokens: u64 = 16_384;

/// Fresh requests use the measured conservative density of thirteen tokens per
/// thirty-six bytes. Component estimates round independently, so their sum
/// cannot be less than the estimate of the complete wire body.
const request_bytes_per_token: u64 = 3;
const request_headroom_bytes_per_token: u64 = 36;
/// DeepSeek's cache boundaries can change whole-prompt token density between
/// adjacent requests. Project the last stable density with this measured margin
/// instead of treating the appended byte suffix as independently tokenizable.
/// The same margin bounds the projection against the fresh estimate, because a
/// large appended payload can change the request composition enough that stale
/// whole-request density overshoots.
const anchor_margin_numerator: u64 = 119;
const anchor_margin_denominator: u64 = 100;

pub const BudgetError = error{
    RequestSizeOverflow,
    TokenCountOverflow,
    EstimatorUndercount,
    EstimatorOverestimate,
};

pub const ComponentBytes = struct {
    system: u64,
    tools: u64,
    history: u64,
    transient: u64,
};

pub const RequestBytes = struct {
    system: u64,
    tools: u64,
    history: u64,
    transient: u64,
    framing: u64,
    total: u64,
    wire: u64,
};

pub const RequestTokens = struct {
    system: u64,
    tools: u64,
    history: u64,
    transient: u64,
    framing: u64,
    total: u64,
    reserve: u64,
};

pub const ModelLimits = struct {
    context_window_tokens: u64,
    reserve_tokens: u64 = default_reserve_tokens,
};

pub const InputLimits = struct {
    soft_input_tokens: u64,
    hard_input_tokens: u64,
};

pub const RequestBudget = struct {
    estimator: []const u8 = estimator_version,
    bytes: RequestBytes,
    tokens: RequestTokens,
    limits: InputLimits,
};

pub const BudgetRelation = enum {
    within,
    exceeded,
};

pub fn relation(tokens: u64, limit: u64) BudgetRelation {
    return if (tokens <= limit) .within else .exceeded;
}

/// Account for one exact provider wire body. Content components are raw
/// logical bytes. Framing is everything the provider serializer adds around
/// those bytes, including JSON escaping and role or tool envelopes.
pub fn estimate(
    components: ComponentBytes,
    wire_bytes: u64,
    model_limits: ModelLimits,
) BudgetError!RequestBudget {
    const logical_bytes = try sum4(
        components.system,
        components.tools,
        components.history,
        components.transient,
        error.RequestSizeOverflow,
    );
    const framing_bytes = wire_bytes -| logical_bytes;
    const total_bytes = try checkedAdd(logical_bytes, framing_bytes, error.RequestSizeOverflow);

    const system_tokens = estimateBytes(components.system);
    const tool_tokens = estimateBytes(components.tools);
    const history_tokens = estimateBytes(components.history);
    const transient_tokens = estimateBytes(components.transient);
    const framing_tokens = estimateBytes(framing_bytes);
    const total_tokens = try sum5(
        system_tokens,
        tool_tokens,
        history_tokens,
        transient_tokens,
        framing_tokens,
        error.TokenCountOverflow,
    );

    return .{
        .bytes = .{
            .system = components.system,
            .tools = components.tools,
            .history = components.history,
            .transient = components.transient,
            .framing = framing_bytes,
            .total = total_bytes,
            .wire = wire_bytes,
        },
        .tokens = .{
            .system = system_tokens,
            .tools = tool_tokens,
            .history = history_tokens,
            .transient = transient_tokens,
            .framing = framing_tokens,
            .total = total_tokens,
            .reserve = model_limits.reserve_tokens,
        },
        .limits = .{
            .soft_input_tokens = soft_input_target_tokens,
            .hard_input_tokens = model_limits.context_window_tokens -| model_limits.reserve_tokens,
        },
    };
}

pub fn limitsForModel(provider: models.Provider, model_id: []const u8) ModelLimits {
    if (models.findById(model_id)) |model| {
        if (model.provider == provider) {
            return .{ .context_window_tokens = model.capabilities.context_window_tokens };
        }
    }
    return .{
        .context_window_tokens = models.defaultForProvider(provider).capabilities.context_window_tokens,
    };
}

/// Anthropic reports uncached, cache-read, and cache-created input as disjoint
/// fields. Other providers already report their complete logical input in
/// `input_tokens`, so their cache diagnostics must not be added a second time.
pub fn normalizeLogicalInput(provider: models.Provider, usage: turn.Usage) BudgetError!u64 {
    if (provider != .anthropic) return usage.input_tokens;
    const input_and_read = try checkedAdd(
        usage.input_tokens,
        usage.cache_read_input_tokens,
        error.TokenCountOverflow,
    );
    return checkedAdd(
        input_and_read,
        usage.cache_creation_input_tokens,
        error.TokenCountOverflow,
    );
}

/// Calibration is fail-closed: an estimate may not undercount. Its permitted
/// headroom is the larger of 25 percent of actual input or 4,096 tokens.
pub fn validateCalibration(estimated_tokens: u64, actual_tokens: u64) BudgetError!void {
    if (estimated_tokens < actual_tokens) return error.EstimatorUndercount;
    const percentage_allowance = actual_tokens / 4 + @intFromBool(actual_tokens % 4 != 0);
    const allowance = @max(percentage_allowance, 4_096);
    if (estimated_tokens - actual_tokens > allowance) return error.EstimatorOverestimate;
}

pub const UsageEpoch = struct {
    provider: models.Provider,
    model: []const u8,
    checkpoint_generation: u64,

    pub fn eql(self: UsageEpoch, other: UsageEpoch) bool {
        return self.provider == other.provider and
            self.checkpoint_generation == other.checkpoint_generation and
            std.mem.eql(u8, self.model, other.model);
    }
};

pub const StableInputUsage = struct {
    epoch: UsageEpoch,
    logical_input_tokens: u64,
};

pub const EstimateSource = enum {
    anchored_density,
    compaction_bridge_density,
    full_estimate,
};

pub const SelectedEstimate = struct {
    tokens: u64,
    source: EstimateSource,
};

pub const InputAnchor = struct {
    usage: StableInputUsage,
    budget: RequestBudget,
};

pub const InputObservationSource = enum {
    provider_reported,
    prior_density_projection,
};

pub const InputObservation = struct {
    reported_tokens: u64,
    logical_input_tokens: u64,
    source: InputObservationSource,
};

pub const ObserveInput = struct {
    epoch: UsageEpoch,
    current_budget: RequestBudget,
    anchor: ?InputAnchor,
    compaction_bridge: ?InputAnchor = null,
    reported_tokens: u64,
};

/// Stabilize provider input accounting inside one append-oriented request
/// epoch. DeepSeek can report sharp rises or drops when its cache accounting
/// rolls over even though the persistent request grows smoothly. Accept a raw
/// total only when it is calibrated against the estimate selected before the
/// response. Otherwise project the prior stable density. The raw total remains
/// present in the observation for cost reporting and empirical diagnostics.
pub fn observeLogicalInput(input: ObserveInput) BudgetError!InputObservation {
    const reported: InputObservation = .{
        .reported_tokens = input.reported_tokens,
        .logical_input_tokens = input.reported_tokens,
        .source = .provider_reported,
    };
    if (input.reported_tokens == 0) return reported;
    if (input.anchor) |anchor| {
        if (input.epoch.eql(anchor.usage.epoch)) {
            const selected = try selectInputEstimate(.{
                .epoch = input.epoch,
                .current_budget = input.current_budget,
                .anchor = input.anchor,
            });
            validateCalibration(selected.tokens, input.reported_tokens) catch {
                const projected = try projectInputFromAnchor(
                    anchor.budget,
                    input.current_budget,
                    anchor.usage.logical_input_tokens,
                ) orelse return reported;
                return .{
                    .reported_tokens = input.reported_tokens,
                    .logical_input_tokens = projected,
                    .source = .prior_density_projection,
                };
            };
            return reported;
        }
    }
    const bridge = input.compaction_bridge orelse return reported;
    const projected = try projectAcrossCompaction(
        bridge,
        input.epoch,
        input.current_budget,
    ) orelse return reported;
    const selected = try withAnchorMargin(projected);
    validateCalibration(selected, input.reported_tokens) catch return .{
        .reported_tokens = input.reported_tokens,
        .logical_input_tokens = projected,
        .source = .prior_density_projection,
    };
    return reported;
}

pub const SelectEstimateInput = struct {
    epoch: UsageEpoch,
    current_budget: RequestBudget,
    anchor: ?InputAnchor,
    compaction_bridge: ?InputAnchor = null,
};

/// Reuse stable provider usage only inside the same model and checkpoint epoch.
/// A model switch or a new projection checkpoint falls back to a full fresh
/// estimate rather than presenting stale usage as exact.
pub fn selectInputEstimate(input: SelectEstimateInput) BudgetError!SelectedEstimate {
    const fallback: SelectedEstimate = .{
        .tokens = input.current_budget.tokens.total,
        .source = .full_estimate,
    };
    const anchor = input.anchor orelse {
        const bridge = input.compaction_bridge orelse return fallback;
        const projected = try projectAcrossCompaction(
            bridge,
            input.epoch,
            input.current_budget,
        ) orelse return fallback;
        return .{
            .tokens = try withAnchorMargin(projected),
            .source = .compaction_bridge_density,
        };
    };
    if (!input.epoch.eql(anchor.usage.epoch)) return fallback;
    const projected = try projectInputFromAnchor(
        anchor.budget,
        input.current_budget,
        anchor.usage.logical_input_tokens,
    ) orelse return fallback;
    if (input.current_budget.bytes.wire == anchor.budget.bytes.wire) {
        return .{ .tokens = projected, .source = .anchored_density };
    }

    // A whole-request density is valuable for small append-only changes, but
    // a large new tool payload can change the request's composition abruptly.
    // Bound stale-density overshoot near the fresh content estimate. The margin
    // is monotone, so bounding before it is the same as bounding after it.
    return .{
        .tokens = try withAnchorMargin(@min(projected, fallback.tokens)),
        .source = .anchored_density,
    };
}

/// A compaction bridge is deliberately separate from the active usage anchor.
/// It may inform exactly the first request after a projection checkpoint. The
/// new request need not be smaller than the preceding request: model output
/// appended after that request may outweigh the bytes compaction removed. The
/// explicit checkpoint transition, stable provider/model, and stable fixed
/// prefix establish the bridge. The next successful normal request replaces it
/// with an ordinary same-epoch anchor.
fn projectAcrossCompaction(
    bridge: InputAnchor,
    current_epoch: UsageEpoch,
    current: RequestBudget,
) BudgetError!?u64 {
    if (bridge.usage.epoch.provider != current_epoch.provider or
        !std.mem.eql(u8, bridge.usage.epoch.model, current_epoch.model) or
        bridge.usage.epoch.checkpoint_generation == current_epoch.checkpoint_generation)
    {
        return null;
    }
    const previous = bridge.budget;
    if (current.bytes.system != previous.bytes.system or
        current.bytes.tools != previous.bytes.tools or
        previous.bytes.wire == 0)
    {
        return null;
    }
    return @as(?u64, try ratioCeil(
        bridge.usage.logical_input_tokens,
        current.bytes.wire,
        previous.bytes.wire,
    ));
}

/// Project the last stable whole-request density onto the current wire size.
/// Replacing the stable prefix or shrinking the persistent request invalidates
/// the anchor. Transient retry text may come and go while history and the full
/// wire body continue to grow, so it is not part of continuation identity.
fn projectInputFromAnchor(
    previous: RequestBudget,
    current: RequestBudget,
    previous_input_tokens: u64,
) BudgetError!?u64 {
    if (!isPersistentContinuation(previous, current)) return null;
    if (current.bytes.wire == previous.bytes.wire) return previous_input_tokens;
    if (previous.bytes.wire == 0) return null;
    return try ratioCeil(
        previous_input_tokens,
        current.bytes.wire,
        previous.bytes.wire,
    );
}

fn isPersistentContinuation(previous: RequestBudget, current: RequestBudget) bool {
    return current.bytes.system == previous.bytes.system and
        current.bytes.tools == previous.bytes.tools and
        current.bytes.history >= previous.bytes.history and
        current.bytes.wire >= previous.bytes.wire;
}

/// The one density. The compaction planner sizes the suffix it keeps with the
/// same function that admits the request built from it, so a plan that fits
/// cannot be refused by the accountant that measures it.
pub fn estimateBytes(bytes: u64) u64 {
    return ceilingDivision(bytes, request_bytes_per_token) +|
        ceilingDivision(bytes, request_headroom_bytes_per_token);
}

fn ceilingDivision(value: u64, divisor: u64) u64 {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn withAnchorMargin(value: u64) BudgetError!u64 {
    return ratioCeil(value, anchor_margin_numerator, anchor_margin_denominator);
}

fn ratioCeil(value: u64, numerator: u64, denominator: u64) BudgetError!u64 {
    const product = @as(u128, value) * @as(u128, numerator);
    const wide_denominator: u128 = denominator;
    const result = product / wide_denominator + @intFromBool(product % wide_denominator != 0);
    return std.math.cast(u64, result) orelse error.TokenCountOverflow;
}

fn checkedAdd(a: u64, b: u64, comptime overflow_error: BudgetError) BudgetError!u64 {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return overflow_error;
    return sum;
}

fn sum4(a: u64, b: u64, c: u64, d: u64, comptime overflow_error: BudgetError) BudgetError!u64 {
    return checkedAdd(
        try checkedAdd(a, b, overflow_error),
        try checkedAdd(c, d, overflow_error),
        overflow_error,
    );
}

fn sum5(
    a: u64,
    b: u64,
    c: u64,
    d: u64,
    e: u64,
    comptime overflow_error: BudgetError,
) BudgetError!u64 {
    return checkedAdd(try sum4(a, b, c, d, overflow_error), e, overflow_error);
}
