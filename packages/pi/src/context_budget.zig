//! Pure, provider-neutral request-size accounting.
//!
//! This module measures and characterizes requests. Admission, projection,
//! and compaction remain separate policy layers so observing a request cannot
//! change the bytes sent by a provider client.

const std = @import("std");
const models = @import("providers/models.zig");
const turn = @import("turn.zig");

pub const estimator_version = "estimated_logical_input_v1";
pub const soft_input_target_tokens: u64 = 40_000;
pub const default_reserve_tokens: u64 = 16_384;

/// The fresh-request fallback treats each four wire bytes as one token.
/// Component estimates round independently so their sum cannot be less than
/// the estimate of the complete wire body.
const primary_bytes_per_token: u64 = 4;
const trailing_uncertainty_tokens: u64 = 4_096;
const tool_heavy_trailing_uncertainty_tokens: u64 = 8_192;
const tool_heavy_history_bytes: u64 = 4_096;

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

pub const ExactInputUsage = struct {
    epoch: UsageEpoch,
    logical_input_tokens: u64,
};

pub const EstimateSource = enum {
    actual_plus_trailing,
    full_estimate,
};

pub const SelectedEstimate = struct {
    tokens: u64,
    source: EstimateSource,
};

pub const SelectEstimateInput = struct {
    epoch: UsageEpoch,
    fallback_estimated_tokens: u64,
    trailing_estimated_tokens: u64,
    exact_usage: ?ExactInputUsage,
};

/// Reuse exact provider usage only inside the same model and checkpoint epoch.
/// A model switch or a new projection checkpoint falls back to a full fresh
/// estimate rather than presenting stale usage as exact.
pub fn selectInputEstimate(input: SelectEstimateInput) BudgetError!SelectedEstimate {
    if (input.exact_usage) |exact| {
        if (input.epoch.eql(exact.epoch)) {
            return .{
                .tokens = try checkedAdd(
                    exact.logical_input_tokens,
                    input.trailing_estimated_tokens,
                    error.TokenCountOverflow,
                ),
                .source = .actual_plus_trailing,
            };
        }
    }
    return .{ .tokens = input.fallback_estimated_tokens, .source = .full_estimate };
}

/// Estimate growth after an exact provider count. A component decrease means
/// the request is no longer an append-only extension and invalidates the
/// anchor. DeepSeek's pinned corpus shows that cached logical-input growth can
/// be substantially denser than wire-byte growth. Any non-empty suffix gets a
/// 4,096-token uncertainty floor; once visible history exceeds 4 KiB, the
/// pinned tool-heavy requests require an 8,192-token floor. A new exact count
/// replaces the anchor after every response.
pub fn estimateTrailing(previous: RequestBudget, current: RequestBudget) ?u64 {
    if (current.bytes.system < previous.bytes.system or
        current.bytes.tools < previous.bytes.tools or
        current.bytes.history < previous.bytes.history or
        current.bytes.transient < previous.bytes.transient or
        current.bytes.wire < previous.bytes.wire)
    {
        return null;
    }

    const delta = (current.bytes.system - previous.bytes.system) +|
        (current.bytes.tools - previous.bytes.tools) +|
        (current.bytes.history - previous.bytes.history) +|
        (current.bytes.transient - previous.bytes.transient) +|
        (current.bytes.wire - previous.bytes.wire);
    if (delta == 0) return 0;
    const uncertainty = if (current.bytes.history >= tool_heavy_history_bytes)
        tool_heavy_trailing_uncertainty_tokens
    else
        trailing_uncertainty_tokens;
    return @max(estimateBytes(delta), uncertainty);
}

fn estimateBytes(bytes: u64) u64 {
    return ceilingDivision(bytes, primary_bytes_per_token);
}

fn ceilingDivision(value: u64, divisor: u64) u64 {
    return value / divisor + @intFromBool(value % divisor != 0);
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
