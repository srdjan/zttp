//! Lock-free pool of per-request JS runtimes plus the lifecycle/audit
//! machinery that decides when to reuse, recycle, or evict a runtime.
//! `HandlerInstance` itself lives in handler_instance.zig and is reached via back-import.

const std = @import("std");
const builtin = @import("builtin");
const zq = @import("zts");
const compat = zq.compat;

const contract_runtime = @import("contract_runtime.zig");
const durable_store_mod = @import("durable_store.zig");
const durable_fetch = @import("durable_fetch.zig");
const http_types = @import("http_types.zig");
const embedded_handler = @import("embedded_handler");

const runtime_config_mod = @import("runtime_config.zig");
const RuntimeConfig = runtime_config_mod.RuntimeConfig;
const openTraceFile = runtime_config_mod.openTraceFile;
const PercentileTracker = @import("runtime_percentile.zig").PercentileTracker;

const bytecode_cache = zq.bytecode_cache;
const HttpRequestView = http_types.HttpRequestView;
const HttpResponse = http_types.HttpResponse;
const HttpRequestOwned = http_types.HttpRequestOwned;

const handler_instance = @import("handler_instance.zig");
const HandlerInstance = handler_instance.HandlerInstance;
const panic_recovery = @import("panic_recovery.zig");

pub const HandlerPool = struct {
    allocator: std.mem.Allocator,
    config: RuntimeConfig,
    handler_code: []const u8,
    handler_filename: []const u8,
    max_size: usize,
    acquire_timeout_ms: u32,
    in_use: std.atomic.Value(usize),
    request_seq: std.atomic.Value(u64),
    total_wait_ns: std.atomic.Value(u64),
    max_wait_ns: std.atomic.Value(u64),
    total_exec_ns: std.atomic.Value(u64),
    max_exec_ns: std.atomic.Value(u64),
    exhausted_count: std.atomic.Value(u64),
    /// Release-time arena audit failures. Exposed via getMetrics().
    arena_audit_failures: std.atomic.Value(u64),
    /// Release-time persistent-string-in-arena violations. Exposed via getMetrics().
    persistent_escape_failures: std.atomic.Value(u64),
    /// Runtimes recycled (destroyed, not returned to pool) by policy.
    recycles: std.atomic.Value(u64),
    /// Handler panics isolated via setjmp recovery. Each quarantines the slot.
    panics: std.atomic.Value(u64),
    /// Requests that exceeded the per-request timeout deadline.
    timeouts: std.atomic.Value(u64),
    /// Contract-derived lifecycle policy. Set by the server after contract parse.
    pooling_policy: contract_runtime.PoolingPolicy = .reuse_bounded_by_count,
    pooling_thresholds: contract_runtime.PoolingThresholds = .{},
    wait_percentiles: PercentileTracker,
    exec_percentiles: PercentileTracker,
    pool: zq.LockFreePool,
    cache: zq.BytecodeCache,
    cache_mutex: compat.Mutex,
    /// Latches to true after a cache deserialize failure so subsequent
    /// requests skip both reads and writes and always recompile from
    /// source. Protects the runtime from looping on a serialize/deserialize
    /// mismatch that is, by definition, only visible on cache hits.
    cache_disabled: std.atomic.Value(bool),
    runtime_init_mutex: compat.Mutex,
    /// Bumped by reloadHandler / setDevCapabilityPolicy so idle runtimes rebuild
    /// lazily on their next acquire (under runtime_init_mutex) instead of being
    /// torn down from the reload thread while a worker may be executing on them.
    reload_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Pre-compiled bytecode embedded at build time (from -Dhandler option)
    embedded_bytecode: ?[]const u8,
    /// HandlerInstance-provided dependency bytecodes (from self-extracting binary)
    runtime_dep_bytecodes: ?[]const []const u8,
    /// Shared trace file handle (owned by pool, shared across runtimes)
    trace_file: ?std.c.fd_t,
    /// Mutex protecting concurrent trace file writes
    trace_mutex: ?*zq.trace.TraceMutex,
    /// E2E panic-injection path for testing real panic recovery and slot
    /// quarantine. Set from RuntimeConfig or the ZTTP_DEBUG_PANIC_PATH env
    /// var at init; null in production.
    debug_panic_path: ?[]const u8 = null,

    const Self = @This();
    const collect_pool_metrics = builtin.mode == .Debug;

    pub const ResponseHandle = struct {
        response: HttpResponse,
        runtime: *HandlerInstance,
        base_rt: *zq.LockFreePool.Runtime,
        pool: *HandlerPool,
        released: bool = false,

        /// Releasing the runtime resets it, so any `response.body` borrowed from
        /// runtime-managed memory (requires_runtime) is only valid until this
        /// call. The caller must finish sending the body before deinit. That
        /// contract is not expressible in the type system, so harden it in
        /// safety builds by poisoning the borrowed body after release: a
        /// use-after-release then reads obviously-wrong empty bytes instead of
        /// reset runtime memory. Idempotent on repeated deinit, matching
        /// WorkerRuntimeLease.
        pub fn deinit(self: *ResponseHandle) void {
            if (self.released) return;
            self.released = true;
            self.response.deinit();
            self.pool.releaseForRequest(self.base_rt);
            if (std.debug.runtime_safety) {
                self.response.body = &.{};
                self.response.body_owner = null;
            }
        }
    };

    pub const WorkerRuntimeLease = struct {
        runtime: *HandlerInstance,
        base_rt: *zq.LockFreePool.Runtime,
        pool: *HandlerPool,
        active: bool = true,

        pub fn deinit(self: *WorkerRuntimeLease) void {
            if (!self.active) return;
            self.active = false;
            self.pool.releaseForRequest(self.base_rt);
        }

        /// Drop a runtime whose WebSocket callback exceeded the request
        /// deadline. Timed-out contexts may retain interrupted VM state and
        /// must never return to the reusable pool.
        pub fn recycleAfterTimeout(self: *WorkerRuntimeLease) void {
            if (!self.active) return;
            _ = self.pool.timeouts.fetchAdd(1, .monotonic);
            std.log.warn(
                "WebSocket callback timed out, invalidating runtime (configured maximum {d}ms)",
                .{self.pool.config.request_timeout_ms},
            );
            self.pool.recycleLeasedRuntime(self);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        config: RuntimeConfig,
        handler_code: []const u8,
        handler_filename: []const u8,
        max_size: usize,
        acquire_timeout_ms: u32,
    ) !Self {
        return initWithEmbedded(allocator, config, handler_code, handler_filename, max_size, acquire_timeout_ms, null);
    }

    /// Initialize with optional embedded bytecode (set before prewarm)
    pub fn initWithEmbedded(
        allocator: std.mem.Allocator,
        config: RuntimeConfig,
        handler_code: []const u8,
        handler_filename: []const u8,
        max_size: usize,
        acquire_timeout_ms: u32,
        embedded_bytecode: ?[]const u8,
    ) !Self {
        return initWithEmbeddedAndDeps(allocator, config, handler_code, handler_filename, max_size, acquire_timeout_ms, embedded_bytecode, null);
    }

    /// Initialize with optional embedded bytecode and runtime-provided dependency bytecodes
    pub fn initWithEmbeddedAndDeps(
        allocator: std.mem.Allocator,
        config: RuntimeConfig,
        handler_code: []const u8,
        handler_filename: []const u8,
        max_size: usize,
        acquire_timeout_ms: u32,
        embedded_bytecode: ?[]const u8,
        runtime_dep_bytecodes: ?[]const []const u8,
    ) !Self {
        const pool = try zq.LockFreePool.init(allocator, .{
            .max_size = max_size,
            .gc_config = .{ .nursery_size = config.nursery_size },
            .arena_config = .{ .size = config.arena_size },
            .use_hybrid_allocation = config.use_hybrid_allocation,
        });

        var self = Self{
            .allocator = allocator,
            .config = config,
            .handler_code = handler_code,
            .handler_filename = handler_filename,
            .max_size = max_size,
            .acquire_timeout_ms = acquire_timeout_ms,
            .in_use = std.atomic.Value(usize).init(0),
            .request_seq = std.atomic.Value(u64).init(0),
            .total_wait_ns = std.atomic.Value(u64).init(0),
            .max_wait_ns = std.atomic.Value(u64).init(0),
            .total_exec_ns = std.atomic.Value(u64).init(0),
            .max_exec_ns = std.atomic.Value(u64).init(0),
            .exhausted_count = std.atomic.Value(u64).init(0),
            .arena_audit_failures = std.atomic.Value(u64).init(0),
            .persistent_escape_failures = std.atomic.Value(u64).init(0),
            .recycles = std.atomic.Value(u64).init(0),
            .panics = std.atomic.Value(u64).init(0),
            .timeouts = std.atomic.Value(u64).init(0),
            .wait_percentiles = .{},
            .exec_percentiles = .{},
            .pool = pool,
            .cache = zq.BytecodeCache.init(allocator),
            .cache_mutex = .{},
            .cache_disabled = std.atomic.Value(bool).init(false),
            .runtime_init_mutex = .{},
            .embedded_bytecode = embedded_bytecode,
            .runtime_dep_bytecodes = runtime_dep_bytecodes,
            .trace_file = null,
            .trace_mutex = null,
            .debug_panic_path = config.debug_panic_path orelse if (std.c.getenv("ZTTP_DEBUG_PANIC_PATH")) |raw| std.mem.span(raw) else null,
        };
        errdefer self.deinit();

        // Open shared trace file if configured
        if (config.trace_file_path) |trace_path| {
            self.trace_file = openTraceFile(allocator, trace_path) catch |err| {
                std.log.err("Failed to open trace file '{s}': {}", .{ trace_path, err });
                return err;
            };
            const mutex = try allocator.create(zq.trace.TraceMutex);
            mutex.* = .{};
            self.trace_mutex = mutex;
        }

        try self.prewarm();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.pool.deinit();
        self.cache.deinit();
        if (self.trace_file) |fd| std.Io.Threaded.closeFd(fd);
        if (self.trace_mutex) |m| self.allocator.destroy(m);
    }

    /// Hot-swap handler code without restarting the server.
    ///
    /// Updates the handler source, clears the bytecode cache, and invalidates
    /// all idle runtimes so they recompile on next acquire. In-flight requests
    /// continue with the old handler and get the new code on their next cycle.
    ///
    /// `new_code` must be heap-allocated and owned by the caller. The pool
    /// takes a reference but does not free it - the caller manages the
    /// lifetime of both old and new code (keep the previous generation alive
    /// until the next reload cycle to avoid use-after-free on in-flight
    /// runtimes).
    pub fn reloadHandler(self: *Self, new_code: []const u8, new_filename: []const u8) usize {
        return self.reloadHandlerWithPolicy(new_code, new_filename, null);
    }

    /// Hot-swap handler code and, when supplied, the dev capability policy in
    /// one generation update. This prevents newly-created runtimes from seeing
    /// new code with the old dev policy or the reverse.
    pub fn reloadHandlerWithPolicy(
        self: *Self,
        new_code: []const u8,
        new_filename: []const u8,
        dev_policy: ?zq.RuntimePolicy,
    ) usize {
        self.runtime_init_mutex.lock();
        self.cache_mutex.lock();

        self.handler_code = new_code;
        self.handler_filename = new_filename;
        self.cache.clear();
        self.embedded_bytecode = null;
        if (dev_policy) |policy| {
            self.config.dev_capability_policy = policy;
        }

        self.cache_mutex.unlock();
        self.runtime_init_mutex.unlock();

        // Bump the reload generation rather than tearing idle runtimes down from
        // this (watcher) thread: a worker may have just CAS-acquired a slot and
        // be executing on its user_data, so freeing it here is a use-after-free /
        // double-free. ensureRuntime rebuilds any runtime whose generation lags,
        // under runtime_init_mutex, on its next acquire. In-flight requests
        // finish on the old generation. We count currently-idle runtimes purely
        // for the caller's log line.
        _ = self.reload_generation.fetchAdd(1, .acq_rel);
        var invalidated: usize = 0;
        for (self.pool.slots) |*slot| {
            if (slot.load(.acquire) != null) invalidated += 1;
        }

        return invalidated;
    }

    /// Dev/serve live path only: pin a contract-derived capability policy onto
    /// the pool config and invalidate idle runtimes so they re-create enforcing
    /// it. Recreated runtimes read `self.config` in `ensureRuntime`. In-flight
    /// (checked-out) runtimes finish under the previous policy, so the caller
    /// must keep the previous policy's backing storage alive one generation.
    /// Mirrors `reloadHandler`'s locking.
    pub fn setDevCapabilityPolicy(self: *Self, policy: zq.RuntimePolicy) void {
        self.runtime_init_mutex.lock();
        self.config.dev_capability_policy = policy;
        self.runtime_init_mutex.unlock();

        // Same rationale as reloadHandler: bump the generation so idle runtimes
        // rebuild lazily (reading the new config) under runtime_init_mutex on
        // their next acquire, instead of being freed from this thread underneath
        // an in-flight request.
        _ = self.reload_generation.fetchAdd(1, .acq_rel);
    }

    fn nextRequestId(self: *Self) u64 {
        return if (collect_pool_metrics) self.request_seq.fetchAdd(1, .acq_rel) + 1 else 0;
    }

    /// Acquire and pin a runtime to the current worker thread.
    /// Caller must release it with lease.deinit().
    pub fn acquireWorkerRuntime(self: *Self) !WorkerRuntimeLease {
        const base_rt = try self.acquireForRequest();
        errdefer self.releaseForRequest(base_rt);
        const rt = try self.ensureRuntime(base_rt);
        return .{
            .runtime = rt,
            .base_rt = base_rt,
            .pool = self,
        };
    }

    /// Execute handler with a request (acquire, run, release)
    pub fn executeHandler(self: *Self, request: HttpRequestView) !HttpResponse {
        const request_id = self.nextRequestId();
        const base_rt = try self.acquireForRequest();
        var exec_timer: ?compat.Timer = null;
        if (collect_pool_metrics) {
            exec_timer = compat.Timer.start() catch null;
        }
        defer if (collect_pool_metrics) {
            if (exec_timer) |*t| self.recordExec(t.read());
        };

        var slot_disposed = false;
        defer if (!slot_disposed) self.releaseForRequest(base_rt);
        var attempt: u8 = 0;
        var last_err: ?anyerror = null;
        while (attempt < 2) : (attempt += 1) {
            const rt = try self.ensureRuntime(base_rt);
            const result = self.callHandlerGuarded(rt, request, request_id, false) catch |err| {
                if (err == error.HandlerPanicked) {
                    slot_disposed = true;
                    self.quarantineSlot(base_rt);
                    return err;
                }
                if (err == error.RequestTimeout) {
                    _ = self.timeouts.fetchAdd(1, .monotonic);
                    std.log.warn("Handler timed out after {d}ms, invalidating runtime", .{self.config.request_timeout_ms});
                    slot_disposed = true;
                    self.recycleSlot(base_rt);
                    return err;
                }
                if (isHandlerInvalid(err)) {
                    std.log.warn("Handler invalid, rebuilding runtime (err={})", .{err});
                    self.invalidateRuntime(base_rt);
                    last_err = err;
                    continue;
                }
                return err;
            };
            if (!rt.owns_resources) {
                result.assertDetachedFromRuntime();
            }
            return result;
        }
        return last_err orelse error.HandlerNotCallable;
    }

    /// Execute handler and return a response handle that borrows JS strings.
    /// Caller must call handle.deinit() after sending the response.
    pub fn executeHandlerBorrowed(self: *Self, request: HttpRequestView) !ResponseHandle {
        return self.executeHandlerBorrowedCapturingFault(request, null);
    }

    /// Same as `executeHandlerBorrowed`, but on a type-fault error it copies the
    /// runtime's resolved fault location into `fault_out` before the runtime is
    /// released. The server's 500 site builds its body after release, so the
    /// value has to leave the runtime here or not at all.
    pub fn executeHandlerBorrowedCapturingFault(
        self: *Self,
        request: HttpRequestView,
        fault_out: ?*?zq.bytecode.LineEntry,
    ) !ResponseHandle {
        const request_id = self.nextRequestId();
        const base_rt = try self.acquireForRequest();
        var slot_disposed = false;
        errdefer if (!slot_disposed) self.releaseForRequest(base_rt);
        var exec_timer: ?compat.Timer = null;
        if (collect_pool_metrics) {
            exec_timer = compat.Timer.start() catch null;
        }
        defer if (collect_pool_metrics) {
            if (exec_timer) |*t| self.recordExec(t.read());
        };

        var attempt: u8 = 0;
        var last_err: ?anyerror = null;
        while (attempt < 2) : (attempt += 1) {
            const rt = try self.ensureRuntime(base_rt);
            const response = self.callHandlerGuarded(rt, request, request_id, true) catch |err| {
                if (fault_out) |out| out.* = rt.last_fault_location;
                if (err == error.HandlerPanicked) {
                    slot_disposed = true;
                    self.quarantineSlot(base_rt);
                    return err;
                }
                if (err == error.RequestTimeout) {
                    _ = self.timeouts.fetchAdd(1, .monotonic);
                    std.log.warn("Handler timed out after {d}ms, invalidating runtime", .{self.config.request_timeout_ms});
                    slot_disposed = true;
                    self.recycleSlot(base_rt);
                    return err;
                }
                if (isHandlerInvalid(err)) {
                    std.log.warn("Handler invalid, rebuilding runtime (err={})", .{err});
                    self.invalidateRuntime(base_rt);
                    last_err = err;
                    continue;
                }
                return err;
            };
            return .{
                .response = response,
                .runtime = rt,
                .base_rt = base_rt,
                .pool = self,
            };
        }
        return last_err orelse error.HandlerNotCallable;
    }

    pub fn getInUse(self: *const Self) usize {
        return self.in_use.load(.acquire);
    }

    /// Context for parallel prewarm workers
    const PrewarmCtx = struct {
        pool: *HandlerPool,
        success: std.atomic.Value(bool),
    };

    fn prewarm(self: *Self) !void {
        const prewarm_count = @min(@as(usize, 2), self.max_size);

        // Single runtime or test mode - sequential prewarm
        // (test allocators aren't thread-safe)
        if (prewarm_count <= 1 or builtin.is_test) {
            for (0..prewarm_count) |_| {
                const base_rt = try self.pool.acquire();
                errdefer self.pool.release(base_rt);
                _ = try self.ensureRuntime(base_rt);
                self.pool.release(base_rt);
            }
            return;
        }

        // Parallel prewarm for multiple runtimes (production only)
        var contexts: [2]PrewarmCtx = undefined;
        var threads: [2]?std.Thread = [_]?std.Thread{null} ** 2;

        // Spawn workers
        for (0..prewarm_count) |i| {
            contexts[i] = .{
                .pool = self,
                .success = std.atomic.Value(bool).init(false),
            };
            threads[i] = std.Thread.spawn(.{}, prewarmWorker, .{&contexts[i]}) catch null;
        }

        // Join all workers
        var success_count: usize = 0;
        for (0..prewarm_count) |i| {
            if (threads[i]) |t| {
                t.join();
                if (contexts[i].success.load(.acquire)) success_count += 1;
            }
        }

        // Require at least one successful prewarm
        if (success_count == 0) return error.PrewarmFailed;
    }

    fn prewarmWorker(ctx: *PrewarmCtx) void {
        const base_rt = ctx.pool.pool.acquire() catch return;
        defer ctx.pool.pool.release(base_rt);
        _ = ctx.pool.ensureRuntime(base_rt) catch return;
        ctx.success.store(true, .release);
    }

    fn acquireForRequest(self: *Self) !*zq.LockFreePool.Runtime {
        var wait_timer: ?compat.Timer = null;
        const timeout_ns: u64 = @as(u64, self.acquire_timeout_ms) * std.time.ns_per_ms;

        // Adaptive backoff parameters:
        // Phase 1: Spin without sleep (10 iterations)
        // Phase 2: Sleep starting at 10us, cap at 1ms (faster than 50us-5ms)
        // The configured acquire_timeout_ms is the sole wait bound: a nonzero
        // timeout fails only once elapsed time reaches it, a zero timeout fails
        // fast below. There is deliberately no separate retry-count circuit
        // breaker - it previously cut waits short of the configured timeout
        // under contention.
        const spin_iterations: u32 = 10;
        const initial_backoff_ns: u64 = 10 * std.time.ns_per_us;
        const max_backoff_ns: u64 = 1 * std.time.ns_per_ms;

        var retry_count: u32 = 0;
        var backoff_ns: u64 = initial_backoff_ns;

        while (true) {
            if (self.max_size != 0) {
                // Use CAS loop to atomically check-and-increment only if under limit.
                // This prevents the race where multiple threads temporarily exceed max_size.
                var current = self.in_use.load(.acquire);
                var acquired = false;
                while (current < self.max_size) {
                    if (self.in_use.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
                        // CAS failed - another thread modified in_use, retry with actual value
                        current = actual;
                        continue;
                    }
                    // CAS succeeded - we atomically incremented and are under limit
                    acquired = true;
                    break;
                }
                if (acquired) break;

                // At capacity - proceed to retry/backoff logic. Saturate so a
                // long but legitimate wait cannot overflow the counter; past the
                // spin phase its only roles are the phase gate and the jitter seed.
                retry_count +|= 1;

                // Check timeout first
                if (self.acquire_timeout_ms == 0) {
                    _ = self.exhausted_count.fetchAdd(1, .monotonic);
                    if (collect_pool_metrics) {
                        if (wait_timer) |*t| self.recordWait(t.read());
                    }
                    return error.PoolExhausted;
                }

                if (wait_timer == null) {
                    wait_timer = compat.Timer.start() catch null;
                    // Without a monotonic clock we cannot enforce
                    // acquire_timeout_ms. Fail closed rather than spin forever:
                    // the elapsed-time check below is now the only loop bound
                    // (the retry-count circuit breaker was removed), so a null
                    // timer would otherwise never terminate the wait.
                    if (wait_timer == null) {
                        _ = self.exhausted_count.fetchAdd(1, .monotonic);
                        return error.PoolExhausted;
                    }
                }
                if (wait_timer) |*t| {
                    const elapsed = t.read();
                    if (elapsed >= timeout_ns) {
                        _ = self.exhausted_count.fetchAdd(1, .monotonic);
                        if (collect_pool_metrics) {
                            self.recordWait(elapsed);
                        }
                        return error.PoolExhausted;
                    }
                }

                // Phase 1: Spin without sleep for brief contention
                if (retry_count <= spin_iterations) {
                    std.atomic.spinLoopHint();
                    continue;
                }

                // Phase 2: Sleep with jitter to prevent thundering herd
                // Use thread-unique seed: stack address differs per thread
                const jitter_range = backoff_ns / 4;
                const jitter = if (jitter_range > 0) blk: {
                    const thread_seed = @intFromPtr(&retry_count);
                    const combined = @as(u128, retry_count) * 7919 + @as(u128, thread_seed);
                    break :blk @as(u64, @truncate(combined % (jitter_range * 2)));
                } else 0;
                const sleep_ns = backoff_ns -| jitter_range + jitter;
                const ts = std.c.timespec{
                    .sec = @intCast(sleep_ns / std.time.ns_per_s),
                    .nsec = @intCast(sleep_ns % std.time.ns_per_s),
                };
                _ = std.c.nanosleep(&ts, null);
                backoff_ns = @min(backoff_ns * 2, max_backoff_ns);
                continue;
            } else {
                // No limit - monotonic is fine for metrics-only counter
                _ = self.in_use.fetchAdd(1, .monotonic);
                break;
            }
        }

        const rt = self.pool.acquire() catch |err| {
            _ = self.in_use.fetchSub(1, .monotonic);
            if (collect_pool_metrics) {
                if (wait_timer) |*t| {
                    self.recordWait(t.read());
                } else {
                    self.recordWait(0);
                }
            }
            return err;
        };
        if (collect_pool_metrics) {
            if (wait_timer) |*t| {
                self.recordWait(t.read());
            } else {
                self.recordWait(0);
            }
        }

        // TTL-based pooling is the only consumer of first_use_ns, so skip
        // the clock read for every other policy.
        if (self.pooling_policy == .reuse_bounded_by_ttl and rt.first_use_ns == null) {
            rt.first_use_ns = compat.realtimeNowNs() catch 0;
        }

        return rt;
    }

    pub fn setPoolingPolicy(self: *Self, policy: contract_runtime.PoolingPolicy) void {
        self.pooling_policy = policy;
    }

    pub fn setDurableWorkflowProperties(self: *Self, properties: runtime_config_mod.DurableWorkflowProperties) void {
        self.runtime_init_mutex.lock();
        self.config.durable_workflow_properties = properties;
        self.runtime_init_mutex.unlock();

        _ = self.reload_generation.fetchAdd(1, .acq_rel);
    }

    fn emitRuntimeEvent(kind: zq.security_events.SecurityEventKind, detail: []const u8) void {
        zq.security_events.emitGlobal(
            zq.security_events.SecurityEvent.init(kind, "runtime", detail),
        );
    }

    fn releaseForRequest(self: *Self, rt: *zq.LockFreePool.Runtime) void {
        if (rt.user_data) |ptr| {
            const runtime: *HandlerInstance = @ptrCast(@alignCast(ptr));
            runtime.prepareForPoolRelease();
        }

        // Sandbox audit runs only under runtime safety; a failed audit
        // forces recycle regardless of policy. The `comptime` guard lets
        // ReleaseFast drop both checks entirely.
        var audit_poisoned = false;
        if (comptime std.debug.runtime_safety) {
            rt.assertPersistentStringsOutsideArena() catch {
                _ = self.persistent_escape_failures.fetchAdd(1, .monotonic);
                std.log.err("sandbox: persistent string escaped into request arena", .{});
                emitRuntimeEvent(.persistent_string_escape, "persistent string escaped into request arena");
                audit_poisoned = true;
            };

            _ = rt.auditAndResetArena() catch {
                _ = self.arena_audit_failures.fetchAdd(1, .monotonic);
                std.log.err("sandbox: request arena audit failed", .{});
                emitRuntimeEvent(.arena_audit_failure, "post-reset arena state was non-zero");
                audit_poisoned = true;
            };
        }

        // request_count still reflects completed-BEFORE-this-one, so add
        // one when comparing against the policy threshold.
        const request_count_after: u64 = rt.request_count + 1;
        const policy_recycle = switch (self.pooling_policy) {
            .reuse_unbounded => rt.ctx.atoms.count() >= self.pooling_thresholds.max_dynamic_atoms,
            .ephemeral => true,
            .reuse_bounded_by_count => request_count_after >= self.pooling_thresholds.max_requests,
            .reuse_bounded_by_ttl => blk: {
                const first = rt.first_use_ns orelse break :blk false;
                const now = compat.realtimeNowNs() catch break :blk false;
                break :blk now -| first >= self.pooling_thresholds.ttl_ns;
            },
        };

        if (audit_poisoned or policy_recycle) {
            _ = self.recycles.fetchAdd(1, .monotonic);
            self.pool.dropRuntime(rt);
            _ = self.in_use.fetchSub(1, .monotonic);
            return;
        }

        self.pool.release(rt);
        _ = self.in_use.fetchSub(1, .monotonic);
    }

    pub fn getMetrics(self: *Self) struct {
        requests: u64,
        exhausted: u64,
        avg_wait_ns: u64,
        max_wait_ns: u64,
        avg_exec_ns: u64,
        max_exec_ns: u64,
        wait_p50_ns: u64,
        wait_p95_ns: u64,
        wait_p99_ns: u64,
        exec_p50_ns: u64,
        exec_p95_ns: u64,
        exec_p99_ns: u64,
        arena_audit_failures: u64,
        persistent_escape_failures: u64,
        recycles: u64,
        panics: u64,
        timeouts: u64,
        pooling_policy: contract_runtime.PoolingPolicy,
    } {
        const requests = self.request_seq.load(.acquire);
        const wait_total = self.total_wait_ns.load(.acquire);
        const exec_total = self.total_exec_ns.load(.acquire);
        return .{
            .requests = requests,
            .exhausted = self.exhausted_count.load(.acquire),
            .avg_wait_ns = if (requests > 0) wait_total / requests else 0,
            .max_wait_ns = self.max_wait_ns.load(.acquire),
            .avg_exec_ns = if (requests > 0) exec_total / requests else 0,
            .max_exec_ns = self.max_exec_ns.load(.acquire),
            .wait_p50_ns = self.wait_percentiles.getPercentile(50.0),
            .wait_p95_ns = self.wait_percentiles.getPercentile(95.0),
            .wait_p99_ns = self.wait_percentiles.getPercentile(99.0),
            .exec_p50_ns = self.exec_percentiles.getPercentile(50.0),
            .exec_p95_ns = self.exec_percentiles.getPercentile(95.0),
            .exec_p99_ns = self.exec_percentiles.getPercentile(99.0),
            .arena_audit_failures = self.arena_audit_failures.load(.acquire),
            .persistent_escape_failures = self.persistent_escape_failures.load(.acquire),
            .recycles = self.recycles.load(.acquire),
            .panics = self.panics.load(.acquire),
            .timeouts = self.timeouts.load(.acquire),
            .pooling_policy = self.pooling_policy,
        };
    }

    fn recordWait(self: *Self, ns: u64) void {
        _ = self.total_wait_ns.fetchAdd(ns, .acq_rel);
        updateMax(&self.max_wait_ns, ns);
        self.wait_percentiles.record(ns);
    }

    fn recordExec(self: *Self, ns: u64) void {
        _ = self.total_exec_ns.fetchAdd(ns, .acq_rel);
        updateMax(&self.max_exec_ns, ns);
        self.exec_percentiles.record(ns);
    }

    fn isHandlerInvalid(err: anyerror) bool {
        return err == error.HandlerNotCallable or err == error.NoHandler or err == error.NotCallable;
    }

    fn invalidateRuntime(self: *Self, base_rt: *zq.LockFreePool.Runtime) void {
        if (base_rt.user_data != null) {
            runtimeUserDeinit(base_rt, self.allocator);
        }
    }

    /// Panic path only: destroy the whole base slot without running release-time
    /// audits or prepareForPoolRelease - the runtime heap may be mid-mutation.
    /// LockFreePool.dropRuntime destroys the slot's GC/arena; the next acquire
    /// builds a fresh runtime via ensureRuntime.
    fn quarantineSlot(self: *Self, base_rt: *zq.LockFreePool.Runtime) void {
        _ = self.panics.fetchAdd(1, .monotonic);
        self.recycleSlot(base_rt);
    }

    fn recycleSlot(self: *Self, base_rt: *zq.LockFreePool.Runtime) void {
        _ = self.recycles.fetchAdd(1, .monotonic);
        self.pool.dropRuntime(base_rt);
        _ = self.in_use.fetchSub(1, .monotonic);
    }

    fn recycleLeasedRuntime(self: *Self, lease: *WorkerRuntimeLease) void {
        if (!lease.active) return;
        self.recycleSlot(lease.base_rt);
        lease.active = false;
    }

    fn quarantineLeasedRuntime(self: *Self, lease: *WorkerRuntimeLease) void {
        if (!lease.active) return;
        _ = self.panics.fetchAdd(1, .monotonic);
        self.recycleLeasedRuntime(lease);
    }

    /// Run one handler invocation under panic recovery and the per-request
    /// deadline. MUST remain noinline and minimal: after the second setjmp return,
    /// only `frame` (address-taken) remains valid; `rt` must not be touched on
    /// the panic path.
    noinline fn callHandlerGuarded(
        self: *Self,
        rt: *HandlerInstance,
        request: HttpRequestView,
        request_id: u64,
        comptime borrowed: bool,
    ) !HttpResponse {
        var frame: panic_recovery.Frame = undefined;
        if (panic_recovery.setjmpFn(&frame.jb) != 0) {
            // Handler panicked. Defers in the skipped zruntime frames did NOT run.
            std.log.err("handler panicked (isolated): {s}", .{frame.message()});
            return error.HandlerPanicked;
        }
        panic_recovery.arm(&frame);
        defer panic_recovery.disarm();

        if (self.debug_panic_path) |pp| {
            const effective_path = if (request.path.len > 0) request.path else request.url;
            if (std.mem.eql(u8, effective_path, pp)) {
                @panic("zttp_debug_panic_path");
            }
        }

        rt.armRequestDeadline();
        const result = if (borrowed)
            rt.executeHandlerBorrowedWithId(request, request_id)
        else
            rt.executeHandlerWithId(request, request_id);
        const response = result catch |err| {
            rt.clearRequestDeadline();
            return err;
        };
        rt.clearRequestDeadline();
        return response;
    }

    fn updateMax(target: *std.atomic.Value(u64), value: u64) void {
        var current = target.load(.acquire);
        while (value > current) {
            if (target.cmpxchgStrong(current, value, .acq_rel, .acquire) == null) return;
            current = target.load(.acquire);
        }
    }

    fn ensureRuntime(self: *Self, base_rt: *zq.LockFreePool.Runtime) !*HandlerInstance {
        const cur_gen = self.reload_generation.load(.acquire);
        if (base_rt.user_data) |ptr| {
            const rt: *HandlerInstance = @ptrCast(@alignCast(ptr));
            // Fresh runtime: fast path. A stale one (a reload/egress swap bumped
            // the generation while it was idle) falls through to rebuild below.
            if (rt.pool_generation == cur_gen) return rt;
        }

        self.runtime_init_mutex.lock();
        defer self.runtime_init_mutex.unlock();

        // Re-read under the lock; only the owning (acquiring) worker reaches here
        // for this base_rt, so the stale teardown cannot race an in-flight request.
        const gen = self.reload_generation.load(.acquire);
        if (base_rt.user_data) |ptr| {
            const rt: *HandlerInstance = @ptrCast(@alignCast(ptr));
            if (rt.pool_generation == gen) return rt;
            // Stale: tear down the old generation's runtime before rebuilding so
            // it picks up the new handler code / egress policy.
            runtimeUserDeinit(base_rt, self.allocator);
        }

        const rt = try HandlerInstance.initFromPool(base_rt, self.config);
        rt.pool_generation = gen;
        errdefer rt.deinit();

        // Inject shared trace file/mutex from pool
        if (self.trace_file != null and self.trace_mutex != null) {
            rt.trace_file = self.trace_file;
            rt.trace_mutex = self.trace_mutex;
        }

        try self.loadHandlerCached(rt);
        base_rt.assertPersistentStringsOutsideArena() catch |err| switch (err) {
            error.PersistentStringEscapedIntoArena => {
                std.log.err("sandbox: persistent string escaped into request arena during handler load", .{});
                return error.PersistentStringEscapedIntoArena;
            },
        };

        base_rt.user_data = rt;
        base_rt.user_deinit = runtimeUserDeinit;
        return rt;
    }

    fn loadHandlerCached(self: *Self, rt: *HandlerInstance) !void {
        // Temporarily disable hybrid mode during handler loading.
        // Handler function objects must use persistent allocation so they survive
        // arena resets between requests. Without this, closures or function objects
        // could reference arena-allocated memory that gets invalidated.
        const saved_hybrid = rt.ctx.hybrid;
        const saved_hybrid_mode = rt.gc_state.hybrid_mode;
        rt.ctx.hybrid = null;
        rt.gc_state.hybrid_mode = false;
        defer {
            rt.ctx.hybrid = saved_hybrid;
            rt.gc_state.hybrid_mode = saved_hybrid_mode;
        }

        // Fast path: use embedded bytecode if available (precompiled at build time)
        if (self.embedded_bytecode) |entry_bytecode| {
            // Load dependency modules first
            if (self.runtime_dep_bytecodes) |deps| {
                // HandlerInstance-provided deps (self-extracting binary)
                for (deps) |dep_data| {
                    try rt.loadFromCachedBytecodeNoHandler(dep_data);
                }
            } else if (embedded_handler.dep_count > 0) {
                // Compile-time embedded deps
                for (embedded_handler.dep_bytecodes[0..embedded_handler.dep_count]) |dep_data| {
                    try rt.loadFromCachedBytecodeNoHandler(dep_data);
                }
            }
            // Unlike the dev-cache path below, there is no handler source to
            // recompile from here: for both build-time-embedded and
            // self-extracting-binary bytecode, self.handler_code is a "" placeholder
            // (see server.zig's ServerConfig.handler switch), not real source. A
            // corrupted/version-skewed payload can only be failed cleanly, not
            // recovered from. Log for operator visibility and let the error
            // propagate; callers up the stack (executeHandler/executeHandlerBorrowed)
            // already turn this into a clean per-request 500 instead of a crash.
            rt.loadFromCachedBytecode(entry_bytecode) catch |err| {
                if (!builtin.is_test) {
                    std.log.err(
                        "embedded bytecode deserialize failed for {s}: {}; no source available to recompile, failing handler load",
                        .{ self.handler_filename, err },
                    );
                }
                return err;
            };
            return;
        }

        // Fallback: runtime compilation (for development without -Dhandler)
        const key = zq.sourceCacheKey(self.handler_code, self.handler_filename);

        // Acquire lock for parsing (double-checked locking pattern).
        // The old lockless fast path was unsafe: getRaw() releases its internal
        // lock before returning the slice, so a concurrent cache.clear() could
        // free the backing memory while we were reading from it (UAF).
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        // Double-check: another thread may have populated cache while we waited
        var slow_path_recovered = false;
        if (!self.cache_disabled.load(.monotonic)) {
            if (self.cache.getRaw(key)) |cached_data| {
                rt.loadFromCachedBytecode(cached_data) catch |err| {
                    std.log.warn(
                        "bytecode cache deserialize failed for {s}: {}; recompiling from source",
                        .{ self.handler_filename, err },
                    );
                    self.cache_disabled.store(true, .monotonic);
                    self.cache.clear();
                    slow_path_recovered = true;
                };
                if (!slow_path_recovered) return;
            }
        }

        // Cache MISS confirmed: parse and compile (only one thread does this)
        var buffer: [65536]u8 = undefined;
        const serialized = try rt.loadCodeWithCaching(self.handler_code, self.handler_filename, &buffer);

        // Store in cache for future hits, but only while caching is healthy.
        // Once cache_disabled latches, every request recompiles in-process.
        if (!self.cache_disabled.load(.monotonic)) {
            if (serialized) |data| {
                if (!self.cache.contains(key)) {
                    self.cache.putRaw(key, data) catch |err| {
                        std.log.warn("Bytecode cache insert failed: {}", .{err});
                    };
                }
            }
        }
    }

    fn runtimeUserDeinit(base_rt: *zq.LockFreePool.Runtime, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (base_rt.user_data) |ptr| {
            const rt: *HandlerInstance = @ptrCast(@alignCast(ptr));
            rt.deinit();
            base_rt.user_data = null;
            base_rt.user_deinit = null;
        }
    }
};

const testing = std.testing;

test "WorkerRuntimeLease deinit is a no-op after quarantine" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<runtime-pool-test>",
        1,
        0,
    );
    defer pool.deinit();

    var lease = try pool.acquireWorkerRuntime();
    try testing.expectEqual(@as(usize, 1), pool.getInUse());

    pool.quarantineLeasedRuntime(&lease);
    try testing.expectEqual(@as(usize, 0), pool.getInUse());
    try testing.expect(!lease.active);

    lease.deinit();
    try testing.expectEqual(@as(usize, 0), pool.getInUse());

    var replacement = try pool.acquireWorkerRuntime();
    defer replacement.deinit();
    try testing.expectEqual(@as(usize, 1), pool.getInUse());

    const metrics = pool.getMetrics();
    try testing.expectEqual(@as(u64, 1), metrics.panics);
    try testing.expect(metrics.recycles >= 1);
}

test "acquireForRequest waits out contention up to the timeout, not a retry cap" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<runtime-pool-test>",
        1, // single slot: the second acquire must wait for a release
        10_000, // 10s acquire timeout: far longer than the release delay below
    );
    defer pool.deinit();

    // Occupy the only slot.
    const rt1 = try pool.acquireForRequest();
    try testing.expectEqual(@as(usize, 1), pool.getInUse());

    // Release rt1 after ~250ms - well past the old ~100-retry circuit-breaker
    // window (~80ms of 1ms backoffs) yet far below the 10s timeout. The
    // planned-at code returned error.PoolExhausted at the retry cap before this
    // release; the fix keeps waiting until the slot frees.
    const Releaser = struct {
        pool: *HandlerPool,
        rt: *zq.LockFreePool.Runtime,
        fn run(ctx: *@This()) void {
            const ts = std.c.timespec{ .sec = 0, .nsec = @intCast(250 * std.time.ns_per_ms) };
            _ = std.c.nanosleep(&ts, null);
            ctx.pool.releaseForRequest(ctx.rt);
        }
    };
    var ctx = Releaser{ .pool = &pool, .rt = rt1 };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&ctx});
    defer releaser.join();

    // Must succeed (the contended wait outlasts the retry cap) rather than
    // returning error.PoolExhausted.
    const rt2 = try pool.acquireForRequest();
    defer pool.releaseForRequest(rt2);
    try testing.expectEqual(@as(usize, 1), pool.getInUse());
}

test "acquireForRequest with timeout 0 fails fast and records exhaustion" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<runtime-pool-test>",
        1, // single slot
        0, // timeout 0: must fail immediately when at capacity, no waiting
    );
    defer pool.deinit();

    const rt1 = try pool.acquireForRequest();
    defer pool.releaseForRequest(rt1);
    try testing.expectEqual(@as(usize, 1), pool.getInUse());

    try testing.expectError(error.PoolExhausted, pool.acquireForRequest());
    try testing.expectEqual(@as(u64, 1), pool.getMetrics().exhausted);
}

test "reuse_unbounded runtime recycles once its dynamic atom count reaches the threshold" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<runtime-pool-test>",
        1,
        0,
    );
    defer pool.deinit();
    pool.pooling_policy = .reuse_unbounded;

    const rt1 = try pool.acquireForRequest();
    const baseline = rt1.ctx.atoms.count();
    // Force a low ceiling so the test only has to intern a handful of atoms
    // (not the full 65,534 hard cap) to cross it.
    pool.pooling_thresholds.max_dynamic_atoms = @intCast(baseline + 3);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "dyn_atom_{d}", .{i});
        defer allocator.free(name);
        _ = try rt1.ctx.atoms.intern(name);
    }
    try testing.expect(rt1.ctx.atoms.count() >= pool.pooling_thresholds.max_dynamic_atoms);

    pool.releaseForRequest(rt1);
    try testing.expectEqual(@as(u64, 1), pool.getMetrics().recycles);
}

test "reuse_unbounded runtime under the atom threshold is not recycled" {
    const allocator = std.heap.c_allocator;
    var pool = try HandlerPool.init(
        allocator,
        .{},
        "function handler(req) { return Response.text('ok'); }",
        "<runtime-pool-test>",
        1,
        0,
    );
    defer pool.deinit();
    pool.pooling_policy = .reuse_unbounded;

    const rt1 = try pool.acquireForRequest();
    const baseline = rt1.ctx.atoms.count();
    pool.pooling_thresholds.max_dynamic_atoms = @intCast(baseline + 100);

    const name = try allocator.dupe(u8, "dyn_atom_under_threshold");
    defer allocator.free(name);
    _ = try rt1.ctx.atoms.intern(name);
    try testing.expect(rt1.ctx.atoms.count() < pool.pooling_thresholds.max_dynamic_atoms);

    pool.releaseForRequest(rt1);
    try testing.expectEqual(@as(u64, 0), pool.getMetrics().recycles);
}

test "loadHandlerCached embedded path fails cleanly on corrupted bytecode instead of crashing" {
    const allocator = std.heap.c_allocator;

    // Build a minimal but valid handler FunctionBytecode with one int constant
    // holding a rare marker value, so its ConstantTag byte can be located in
    // the serialized blob and flipped to an out-of-range value.
    var source_atoms = zq.AtomTable.init(allocator);
    defer source_atoms.deinit();

    const marker: i32 = 0x11223344;
    var constants = [_]zq.JSValue{zq.JSValue.fromInt(marker)};
    var code_buf = [_]u8{@intFromEnum(zq.Opcode.ret)};

    const func = try allocator.create(zq.FunctionBytecode);
    defer allocator.destroy(func);
    func.* = .{
        .header = .{},
        .name_atom = 0,
        .arg_count = 0,
        .local_count = 0,
        .stack_size = 1,
        .flags = .{},
        .upvalue_count = 0,
        .upvalue_info = &.{},
        .code = &code_buf,
        .constants = &constants,
        .source_map = null,
        .line_table = null,
    };

    var buffer: [4096]u8 = undefined;
    var writer = zq.bytecode_cache.SliceWriter{ .buffer = &buffer };
    try zq.bytecode_cache.serializeBytecodeWithAtomsAndShapes(func, &source_atoms, &.{}, &writer, allocator);

    const blob = try allocator.dupe(u8, writer.getWritten());
    defer allocator.free(blob);

    const marker_bytes = std.mem.asBytes(&marker);
    const marker_pos = std.mem.indexOf(u8, blob, marker_bytes) orelse return error.MarkerNotFoundInSerializedBlob;
    try testing.expect(marker_pos > 0);
    blob[marker_pos - 1] = 0xFF; // corrupt the preceding ConstantTag byte (was .int = 0)

    // Pre-fix, deserializing this corrupted payload panics inside the raw
    // @enumFromInt in bytecode_cache.zig, taking down the whole process.
    // Post-fix, constructing the pool (which prewarms through
    // loadHandlerCached's embedded fast path) must fail cleanly instead.
    const result = HandlerPool.initWithEmbedded(
        allocator,
        .{},
        "",
        "<embedded>",
        1,
        0,
        blob,
    );
    try testing.expectError(error.InvalidTag, result);
}

// ---------------------------------------------------------------------------
// HandlerPool behavior tests. Moved here from the old zruntime.zig god-file, which held them
// only for historical reasons and had to back-import this file to compile them.
// ---------------------------------------------------------------------------

test "HandlerPool basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const handler_code = "function handler(req) { return Response.text('ok'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 2, 0);
    defer {
        pool.deinit();
    }

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try pool.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("ok", response.body);
}
// Uses testing.allocator directly so leaks fail rather than being absorbed
// by an arena.
test "HandlerPool teardown leaves no leaks under testing.allocator" {
    const allocator = std.testing.allocator;
    const handler_code = "function handler(req) { return Response.text('ok'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 2, 0);
    defer pool.deinit();

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try pool.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("ok", response.body);
}
test "HandlerPool cached pattern dispatch transfers ownership without leaks" {
    const allocator = std.testing.allocator;
    const handler_code =
        \\function handler(request) {
        \\  const url = request.url;
        \\  if (url === "/api/a") return Response.text("alpha");
        \\  return Response.text("fallback");
        \\}
    ;
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 2, 0);
    defer pool.deinit();

    // Keep the source-compiled runtime checked out so the request must create
    // a second runtime and hydrate it from the shared bytecode cache.
    const warmed_runtime = try pool.pool.acquire();
    defer pool.pool.release(warmed_runtime);

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/api/a"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try pool.executeHandler(request.asView());
    defer response.deinit();

    try std.testing.expectEqualStrings("alpha", response.body);
    try std.testing.expect(pool.cache.hits.load(.monotonic) > 0);
    try std.testing.expect(!pool.cache_disabled.load(.monotonic));
}
test "HandlerPool bytecode cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const handler_code = "function handler(req) { return Response.text('cached'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 4, 0);
    defer {
        pool.deinit();
    }

    // First request triggers cache population during prewarm
    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var response = try pool.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("cached", response.body);

    // Cache should have entries (hits from prewarm, misses from first parse)
    const hits = pool.cache.hits.load(.monotonic);
    const misses = pool.cache.misses.load(.monotonic);
    try std.testing.expect(hits + misses >= 1);
}
test "HandlerPool handler remains callable across resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const handler_code = "function handler(req) { return Response.text('ok'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 2, 0);
    defer pool.deinit();

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    const iterations: usize = 200;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var response = try pool.executeHandler(request.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("ok", response.body);
    }
}
test "HandlerPool exhaustion and recovery" {
    const allocator = std.heap.c_allocator;

    const handler_code = "function handler(req) { return Response.text('ok'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 2, 0);
    defer pool.deinit();
    pool.acquire_timeout_ms = 0;

    var request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer request.deinit(allocator);

    var lease1 = try pool.acquireWorkerRuntime();
    var lease1_active = true;
    defer if (lease1_active) lease1.deinit();
    var lease2 = try pool.acquireWorkerRuntime();
    defer lease2.deinit();

    try std.testing.expectError(error.PoolExhausted, pool.acquireWorkerRuntime());
    const metrics = pool.getMetrics();
    try std.testing.expect(metrics.exhausted >= 1);

    lease1.deinit();
    lease1_active = false;

    var response = try pool.executeHandler(request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
}
test "HandlerPool owned response survives pooled reuse" {
    const allocator = std.heap.c_allocator;

    const handler_code =
        \\function handler(req) {
        \\  return Response.text(req.body ?? "");
        \\}
    ;
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 1, 0);
    defer pool.deinit();

    var first_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "first"),
    };
    defer first_request.deinit(allocator);

    var second_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "second"),
    };
    defer second_request.deinit(allocator);

    var first_response = try pool.executeHandler(first_request.asView());
    defer first_response.deinit();

    var second_response = try pool.executeHandler(second_request.asView());
    defer second_response.deinit();

    try std.testing.expectEqualStrings("first", first_response.body);
    try std.testing.expectEqualStrings("second", second_response.body);
}
test "HandlerPool borrowed response pins runtime until release" {
    const allocator = std.heap.c_allocator;

    const handler_code =
        \\function handler(req) {
        \\  return Response.text(req.body ?? "");
        \\}
    ;
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 1, 0);
    defer pool.deinit();
    pool.acquire_timeout_ms = 0;

    var first_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "first"),
    };
    defer first_request.deinit(allocator);

    var second_request = HttpRequestOwned{
        .method = try allocator.dupe(u8, "POST"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = try allocator.dupe(u8, "second"),
    };
    defer second_request.deinit(allocator);

    var handle = try pool.executeHandlerBorrowed(first_request.asView());
    try std.testing.expectEqualStrings("first", handle.response.body);
    try std.testing.expectError(error.PoolExhausted, pool.executeHandler(second_request.asView()));

    handle.deinit();

    var response = try pool.executeHandler(second_request.asView());
    defer response.deinit();
    try std.testing.expectEqualStrings("second", response.body);
}
test "HandlerPool pooled teardown survives repeated pool lifecycles" {
    const allocator = std.heap.c_allocator;
    const handler_code =
        \\function handler(req) {
        \\  return Response.text(req.body ?? "ok");
        \\}
    ;

    const Cycle = struct {
        fn run(test_allocator: std.mem.Allocator, handler_source: []const u8, cycle: usize) !void {
            var pool = try HandlerPool.init(test_allocator, .{}, handler_source, "<handler>", 2, 0);
            defer pool.deinit();
            pool.acquire_timeout_ms = 0;

            var first_request = HttpRequestOwned{
                .method = try test_allocator.dupe(u8, "POST"),
                .url = try test_allocator.dupe(u8, "/"),
                .headers = .empty,
                .body = try std.fmt.allocPrint(test_allocator, "first-{d}", .{cycle}),
            };
            defer first_request.deinit(test_allocator);

            var second_request = HttpRequestOwned{
                .method = try test_allocator.dupe(u8, "POST"),
                .url = try test_allocator.dupe(u8, "/"),
                .headers = .empty,
                .body = try std.fmt.allocPrint(test_allocator, "second-{d}", .{cycle}),
            };
            defer second_request.deinit(test_allocator);

            var lease1 = try pool.acquireWorkerRuntime();
            var lease1_active = true;
            defer if (lease1_active) lease1.deinit();
            var lease2 = try pool.acquireWorkerRuntime();
            var lease2_active = true;
            defer if (lease2_active) lease2.deinit();

            const hits = pool.cache.hits.load(.acquire);
            const misses = pool.cache.misses.load(.acquire);
            try std.testing.expect(hits >= 1);
            try std.testing.expect(misses >= 1);

            try std.testing.expectError(error.PoolExhausted, pool.acquireWorkerRuntime());

            lease2.deinit();
            lease2_active = false;

            var first_response = try pool.executeHandler(first_request.asView());
            defer first_response.deinit();

            var second_response = try pool.executeHandler(second_request.asView());
            defer second_response.deinit();

            try std.testing.expectEqualStrings(first_request.body.?, first_response.body);
            try std.testing.expectEqualStrings(second_request.body.?, second_response.body);

            var handle = try pool.executeHandlerBorrowed(first_request.asView());
            try std.testing.expectEqualStrings(first_request.body.?, handle.response.body);
            try std.testing.expectError(error.PoolExhausted, pool.executeHandler(second_request.asView()));

            handle.deinit();
            lease1.deinit();
            lease1_active = false;

            var recovered = try pool.executeHandler(second_request.asView());
            defer recovered.deinit();
            try std.testing.expectEqualStrings(second_request.body.?, recovered.body);

            const metrics = pool.getMetrics();
            try std.testing.expect(metrics.exhausted >= 2);
        }
    };

    var cycle: usize = 0;
    while (cycle < 32) : (cycle += 1) {
        try Cycle.run(allocator, handler_code, cycle);
    }
}
test "HandlerPool does not leak request data across pooled requests" {
    const allocator = std.heap.c_allocator;

    // The handler reflects every request-scoped input back into the response.
    // If body, a header, or the url survived a runtime recycle, a request with
    // none of them set would echo a prior request's values.
    const handler_code =
        \\function handler(req) {
        \\  return Response.json({
        \\    body: req.body ?? "NONE",
        \\    secret: req.headers.get("x-secret") ?? "NONE",
        \\    url: req.url,
        \\  });
        \\}
    ;

    // Pool size 1 forces every request onto the same recycled runtime.
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 1, 0);
    defer pool.deinit();

    const Probe = struct {
        fn tainted(a: std.mem.Allocator, marker: []const u8) !HttpRequestOwned {
            var req = HttpRequestOwned{
                .method = try a.dupe(u8, "POST"),
                .url = try std.fmt.allocPrint(a, "/path-{s}", .{marker}),
                .headers = .empty,
                .body = try std.fmt.allocPrint(a, "BODY-{s}", .{marker}),
            };
            try req.headers.append(a, .{
                .key = try a.dupe(u8, "X-Secret"),
                .value = try std.fmt.allocPrint(a, "SECRET-{s}", .{marker}),
            });
            return req;
        }
        fn clean(a: std.mem.Allocator) !HttpRequestOwned {
            return HttpRequestOwned{
                .method = try a.dupe(u8, "GET"),
                .url = try a.dupe(u8, "/clean"),
                .headers = .empty,
                .body = null,
            };
        }
    };

    // Alternate tainted and clean requests so the recycle is exercised in both
    // directions across several cycles on the one shared runtime.
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        var marker_buf: [16]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "{d}", .{cycle});

        var tainted_req = try Probe.tainted(allocator, marker);
        defer tainted_req.deinit(allocator);
        var tainted_resp = try pool.executeHandler(tainted_req.asView());
        defer tainted_resp.deinit();
        // The tainted request must see exactly its own data.
        try std.testing.expect(std.mem.indexOf(u8, tainted_resp.body, "BODY-") != null);
        try std.testing.expect(std.mem.indexOf(u8, tainted_resp.body, "SECRET-") != null);

        var clean_req = try Probe.clean(allocator);
        defer clean_req.deinit(allocator);
        var clean_resp = try pool.executeHandler(clean_req.asView());
        defer clean_resp.deinit();
        // The clean request, on the same recycled runtime, must carry none of
        // the prior request's body, header, or url.
        try std.testing.expect(std.mem.indexOf(u8, clean_resp.body, "BODY-") == null);
        try std.testing.expect(std.mem.indexOf(u8, clean_resp.body, "SECRET-") == null);
        try std.testing.expect(std.mem.indexOf(u8, clean_resp.body, "path-") == null);
    }
}
test "reloadHandler swaps handler code and new requests use new handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const old_code = "function handler(req) { return Response.text('v1'); }";
    var pool = try HandlerPool.init(allocator, .{}, old_code, "<handler>", 2, 0);
    defer pool.deinit();

    // Execute with old handler
    var req = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer req.deinit(allocator);

    {
        var response = try pool.executeHandler(req.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("v1", response.body);
    }

    // Reload with new handler
    const new_code = "function handler(req) { return Response.text('v2'); }";
    const invalidated = pool.reloadHandler(new_code, "<handler>");
    try std.testing.expect(invalidated > 0);

    // Execute with new handler - should return v2
    {
        var response = try pool.executeHandler(req.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("v2", response.body);
    }
}
test "reloadHandler clears bytecode cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const old_code = "function handler(req) { return Response.text('cached-v1'); }";
    var pool = try HandlerPool.init(allocator, .{}, old_code, "<handler>", 2, 0);
    defer pool.deinit();

    // Execute to populate cache
    var req = HttpRequestOwned{
        .method = try allocator.dupe(u8, "GET"),
        .url = try allocator.dupe(u8, "/"),
        .headers = .empty,
        .body = null,
    };
    defer req.deinit(allocator);

    {
        var response = try pool.executeHandler(req.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("cached-v1", response.body);
    }

    // Cache should have entries
    try std.testing.expect(pool.cache.count() > 0);

    // Reload clears cache
    _ = pool.reloadHandler(
        "function handler(req) { return Response.text('cached-v2'); }",
        "<handler>",
    );
    try std.testing.expectEqual(@as(usize, 0), pool.cache.count());

    // New request uses new handler
    {
        var response = try pool.executeHandler(req.asView());
        defer response.deinit();
        try std.testing.expectEqualStrings("cached-v2", response.body);
    }
}
// Probe HandlerPool.init under FailingAllocator at every allocation site.
// The pool init walks LockFreePool slot allocation, GC arenas per slot,
// handler-source parse/compile during prewarm, bytecode cache state, and
// (when configured) trace mutex creation — a long errdefer chain.
//
// First run of this harness found a real leak: when prewarm's
// installHttpConstructors failed inside addDynamicMethod, the just-created
// prototype objects were not yet registered in ctx.builtin_objects, and native
// function objects created by addMethod had no errdefer owner before property
// installation. The allocator walk keeps those ownership edges transactional.
test "HandlerPool init under FailingAllocator never leaks" {
    const handler_code = "function handler(req) { return Response.text('ok'); }";

    const Probe = struct {
        fn run(handler: []const u8, fail_at: usize) !bool {
            var leak_detector: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
            const child = leak_detector.allocator();
            var failing = std.testing.FailingAllocator.init(child, .{ .fail_index = fail_at });

            const result = HandlerPool.init(failing.allocator(), .{}, handler, "<handler>", 1, 0);
            if (result) |pool| {
                var pool_mut = pool;
                pool_mut.deinit();
                const leak_check = leak_detector.deinit();
                if (leak_check == .leak) std.debug.print("HandlerPool.init leaked on success after fail_at={d}\n", .{fail_at});
                try std.testing.expectEqual(std.heap.Check.ok, leak_check);
                return true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                const leak_check = leak_detector.deinit();
                if (leak_check == .leak) std.debug.print("HandlerPool.init leaked on fail_at={d}\n", .{fail_at});
                try std.testing.expectEqual(std.heap.Check.ok, leak_check);
                return false;
            }
        }
    };

    const regression_fail_points = [_]usize{
        0,
        1,
        // Prototype/console/native module ownership failures found while
        // unskipping this test for v0.2.0.
        1489,
        1535,
        // Parser scope initialization previously panicked instead of
        // returning OutOfMemory on this part of prewarm.
        2048,
    };
    for (regression_fail_points) |fail_at| {
        _ = try Probe.run(handler_code, fail_at);
    }

    {
        var leak_detector: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
        const child = leak_detector.allocator();
        var probe = std.testing.FailingAllocator.init(child, .{ .fail_index = std.math.maxInt(usize) });

        var pool = try HandlerPool.init(probe.allocator(), .{}, handler_code, "<handler>", 1, 0);
        pool.deinit();
        const leak_check = leak_detector.deinit();
        if (leak_check == .leak) std.debug.print("HandlerPool.init leaked on success probe\n", .{});
        try std.testing.expectEqual(std.heap.Check.ok, leak_check);
    }

    if (std.c.getenv("ZTS_RUN_OOM_SWEEP") != null) {
        var fail_at: usize = 0;
        const max_steps: usize = 8192;
        while (fail_at < max_steps) : (fail_at += 1) {
            if (try Probe.run(handler_code, fail_at)) break;
        } else {
            std.debug.print("HandlerPool.init did not succeed within {d} injected allocation failures\n", .{max_steps});
            return error.TestExpectedSuccess;
        }
    }
}
test "HandlerPool concurrent stress" {
    // Expensive opt-in stress test. Stable on Zig 0.16.0 (5/5 runs).
    // Run explicitly with: ZTS_RUN_STRESS_TESTS=1 zig build test-zruntime
    if (std.c.getenv("ZTS_RUN_STRESS_TESTS") == null) return error.SkipZigTest;

    const allocator = std.heap.c_allocator;

    // Allow disabling JIT for this test via env var during debugging.
    const handler_code = "function handler(req) { return Response.text('ok'); }";
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 8, 0);
    defer pool.deinit();

    const thread_count: usize = 8;
    const iterations: usize = 200;

    var errors = std.atomic.Value(u32).init(0);

    const ThreadCtx = struct {
        pool: *HandlerPool,
        allocator: std.mem.Allocator,
        errors: *std.atomic.Value(u32),
    };

    const Worker = struct {
        fn run(ctx: *ThreadCtx) void {
            const method = ctx.allocator.dupe(u8, "GET") catch {
                _ = ctx.errors.fetchAdd(1, .acq_rel);
                return;
            };
            const url = ctx.allocator.dupe(u8, "/") catch {
                ctx.allocator.free(method);
                _ = ctx.errors.fetchAdd(1, .acq_rel);
                return;
            };
            var request = HttpRequestOwned{
                .method = method,
                .url = url,
                .headers = .empty,
                .body = null,
            };
            defer request.deinit(ctx.allocator);

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                var response = ctx.pool.executeHandler(request.asView()) catch {
                    _ = ctx.errors.fetchAdd(1, .acq_rel);
                    continue;
                };
                response.deinit();
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadCtx = undefined;
    for (0..thread_count) |i| {
        contexts[i] = .{
            .pool = &pool,
            .allocator = allocator,
            .errors = &errors,
        };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, 0), errors.load(.acquire));
}
test "HandlerPool high contention stress" {
    const allocator = std.heap.c_allocator;

    // Allow disabling JIT for this test via env var during debugging.
    const handler_code = "function handler(req) { return Response.text('ok'); }";
    // Use larger pool (8 slots) with reasonable timeout for contention
    var pool = try HandlerPool.init(allocator, .{}, handler_code, "<handler>", 8, 0);
    defer pool.deinit();

    const thread_count: usize = 16;
    const iterations: usize = 25;

    var errors = std.atomic.Value(u32).init(0);
    var completed = std.atomic.Value(u32).init(0);

    const ThreadCtx = struct {
        pool: *HandlerPool,
        allocator: std.mem.Allocator,
        errors: *std.atomic.Value(u32),
        completed: *std.atomic.Value(u32),
    };

    const Worker = struct {
        fn run(ctx: *ThreadCtx) void {
            const method = ctx.allocator.dupe(u8, "GET") catch {
                _ = ctx.errors.fetchAdd(1, .acq_rel);
                return;
            };
            const url = ctx.allocator.dupe(u8, "/") catch {
                ctx.allocator.free(method);
                _ = ctx.errors.fetchAdd(1, .acq_rel);
                return;
            };
            var request = HttpRequestOwned{
                .method = method,
                .url = url,
                .headers = .empty,
                .body = null,
            };
            defer request.deinit(ctx.allocator);

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                var response = ctx.pool.executeHandler(request.asView()) catch {
                    _ = ctx.errors.fetchAdd(1, .acq_rel);
                    continue;
                };
                response.deinit();
                _ = ctx.completed.fetchAdd(1, .acq_rel);
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    var contexts: [thread_count]ThreadCtx = undefined;
    for (0..thread_count) |i| {
        contexts[i] = .{
            .pool = &pool,
            .allocator = allocator,
            .errors = &errors,
            .completed = &completed,
        };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    // Verify results - primary goal is no crashes under contention
    const error_count = errors.load(.acquire);
    const completed_count = completed.load(.acquire);
    const total = error_count + completed_count;

    // All requests should be accounted for (either completed or errored)
    try std.testing.expectEqual(thread_count * iterations, total);
    // At least some requests should succeed (proves pool works under contention)
    try std.testing.expect(completed_count > 0);
}
