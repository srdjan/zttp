//! Runtime configuration knobs plus the small helpers that translate
//! `RuntimeConfig` into GC/heap/capability-policy mutations.

const std = @import("std");
const builtin = @import("builtin");
const zq = @import("zts");
const embedded_handler = @import("embedded_handler");
const fault_explain = @import("fault_explain.zig");

const cost_meter = zq.CostMeter;

/// True when `mode` keeps the internal debug panic hook. ReleaseFast and
/// ReleaseSmall builds compile the hook out.
pub fn debugHooksEnabledIn(mode: std.lang.Optimize) bool {
    return switch (mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
}

pub const debug_hooks_enabled = debugHooksEnabledIn(builtin.mode);

pub const CostCeilings = struct {
    per_class: [cost_meter.class_count]?u64 = @splat(null),
    total: ?u64 = null,
    /// True only when the contract's total bound was `.constant`; linear
    /// bounds can still evaluate to a finite worst case at the body limit.
    total_is_constant: bool = false,

    pub inline fn classLimit(self: *const CostCeilings, class: cost_meter.ModuleClass) ?u64 {
        return self.per_class[@backingInt(class)];
    }
};

pub const RuntimeConfig = struct {
    memory_limit: usize = 0,
    nursery_size: usize = 64 * 1024,
    use_hybrid_allocation: bool = true,
    arena_size: usize = 1024 * 1024,
    enforce_arena_escape: bool = true,
    outbound_http_enabled: bool = false,
    outbound_allow_host: ?[]const u8 = null,
    outbound_max_response_bytes: usize = 1024 * 1024,
    outbound_timeout_ms: u32 = 10_000,
    sqlite_path: ?[]const u8 = null,
    trace_file_path: ?[]const u8 = null,
    /// Opt-in JSONL sink for runtime soundness incidents (`--incident-log`).
    /// `incident_log_path` is the CLI-supplied path; the server opens it once at
    /// startup and shares the resulting O_APPEND fd through `incident_log_fd`, so
    /// every pooled runtime writes to the same fd (atomic for small lines).
    incident_log_path: ?[]const u8 = null,
    incident_log_fd: ?std.c.fd_t = null,
    replay_file_path: ?[]const u8 = null,
    test_file_path: ?[]const u8 = null,
    /// Proof facts the server derives from the contract, read at the runtime's
    /// own 500 sites (Path A / Path B) to proof-explain a fault. Defaults to all
    /// false so a no-contract runtime reports faults as predicted, never as a
    /// (false) soundness incident.
    handler_proof: fault_explain.Proof = .{},
    /// Contract cost envelope evaluated once at startup for the configured
    /// request body limit.
    cost_ceilings: ?CostCeilings = null,
    /// Dev/serve path only: the checked contract plus configured policy,
    /// projected for installation instead of the embedded stub. Null when the
    /// policy in `embedded_handler` stays the source. This is an
    /// input view only. HandlerPool deep-copies it into a refcounted policy
    /// generation that owns the backing for all in-flight runtimes.
    dev_capability_policy: ?zq.RuntimePolicy = null,
    /// Internal activation bit. Only an accepted artifact with residual guards
    /// sets this before pool construction. Static-only generations keep their
    /// installed index absent and use the existing literal allowlist path.
    runtime_policy_index_required: bool = false,
    /// Per-request handler execution deadline in ms. 0 = disabled.
    /// Checked cooperatively at interpreter loop back-edges and call entries.
    request_timeout_ms: u32 = 0,
    /// Test-only path that triggers a real panic at the guarded handler
    /// boundary for panic-isolation E2E coverage. Null in normal operation.
    debug_panic_path: ?[]const u8 = null,
};

pub fn openTraceFile(allocator: std.mem.Allocator, path: []const u8) !std.c.fd_t {
    return zq.file_io.openAppend(allocator, path);
}

pub fn applyRuntimeConfig(ctx: *zq.Context, gc_state: *zq.GC, heap_state: *zq.Heap, config: RuntimeConfig) void {
    ctx.enforce_arena_escape = config.enforce_arena_escape;

    // FaaS workloads see less benefit from the stock 10k threshold; the
    // higher value trades memory for fewer mid-request pauses.
    gc_state.setMajorGCThreshold(50_000);

    if (config.memory_limit > 0) {
        gc_state.setMemoryLimit(config.memory_limit);
        heap_state.setMemoryLimit(config.memory_limit);
        if (ctx.hybrid) |h| {
            h.setMemoryLimit(config.memory_limit);
        }
    }
}

pub fn applyEmbeddedCapabilityPolicy(
    ctx: *zq.Context,
    config: RuntimeConfig,
    installed: ?zq.RuntimePolicy,
) void {
    if (installed) |policy| {
        ctx.capability_policy = policy;
        return;
    }
    ctx.capability_policy = embedded_handler.capability_policy;
    // Dev/serve override: the embedded policy is the empty stub here, so the
    // full contract-derived policy is the enforcement source in interpreted
    // mode. A null dev_capability_policy keeps the embedded list.
    if (config.dev_capability_policy) |policy| {
        ctx.capability_policy = policy;
    }
}
