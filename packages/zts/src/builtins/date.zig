const std = @import("std");
const h = @import("helpers.zig");
const value = h.value;
const context = h.context;
const compat = h.compat;
const trace_mod = h.trace_mod;

const allocFloat = h.allocFloat;

/// Date.now() - Returns milliseconds since Unix epoch
/// When trace recording is active, the result is recorded as an I/O call
/// so replay can reproduce the exact timestamp.
/// When replay is active, the recorded timestamp is returned instead.
pub fn dateNow(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    _ = this;
    _ = args;

    // Replay mode: return recorded timestamp
    if (ctx.getModuleState(trace_mod.ReplayState, trace_mod.REPLAY_STATE_SLOT)) |state| {
        const entry = state.nextIO("builtin", "Date.now") orelse return value.JSValue.undefined_val;
        return trace_mod.jsonToJSValue(ctx, entry.result_json);
    }

    const ms = compat.realtimeNowMs() catch {
        return value.JSValue.undefined_val;
    };
    // Return as float since timestamps exceed i32 range
    const result = allocFloat(ctx, @floatFromInt(ms));

    // Record to trace if active (Date.now is a non-determinism source)
    if (ctx.getModuleState(trace_mod.TraceRecorder, trace_mod.TRACE_STATE_SLOT)) |recorder| {
        recorder.recordIO("builtin", "Date.now", ctx, &.{}, result);
    }

    return result;
}

/// Initialization states for `perf_time_origin`: the first caller wins the
/// compare-and-swap and publishes the origin; later callers wait for it.
const origin_uninit: u8 = 0;
const origin_writing: u8 = 1;
const origin_ready: u8 = 2;

var perf_time_origin: compat.Instant = undefined;
var perf_origin_state = std.atomic.Value(u8).init(origin_uninit);

/// performance.now() - Returns milliseconds since time origin (monotonic)
pub fn performanceNow(ctx: *context.Context, this: value.JSValue, args: []const value.JSValue) value.JSValue {
    _ = this;
    _ = args;
    const now = compat.Instant.now() catch return value.JSValue.undefined_val;
    if (perf_origin_state.cmpxchgStrong(origin_uninit, origin_writing, .acquire, .acquire) == null) {
        perf_time_origin = now;
        perf_origin_state.store(origin_ready, .release);
        return allocFloat(ctx, 0);
    }
    while (perf_origin_state.load(.acquire) != origin_ready) std.atomic.spinLoopHint();
    const elapsed_ns = now.since(perf_time_origin);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    return allocFloat(ctx, elapsed_ms);
}
