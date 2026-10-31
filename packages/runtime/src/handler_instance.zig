//! The pooled handler instance: one JS engine runtime, its installed
//! builtins, the loaded handler, and the per-invocation state that a single
//! request mutates.
//!
//! Pure Zig on top of zts, no C dependencies. `runtime_pool.zig` owns
//! instances of this type and decides when to reuse, recycle, or evict one.
//! The tests that drive it live in zruntime_tests.zig, which is the test root for
//! this file.

const std = @import("std");
const execution_spec = @import("execution_spec.zig");
const builtin = @import("builtin");
const compat = @import("zts").compat;

// Import zts module
const zq = @import("zts");
const trace_request_recorder = @import("trace_request_recorder.zig");
const fault_explain = @import("fault_explain.zig");
const incident_log = @import("incident_log.zig");
const runtime_builtins = @import("runtime_builtins.zig");
const console = @import("runtime_console.zig");
const http = @import("runtime_http.zig");
const natives = @import("runtime_natives.zig");
const buildQueryObject = natives.buildQueryObject;
const getStringDataCtx = zq.builtins.helpers.getStringDataCtx;

// Context-only HTTP callbacks need no host adapter.
const headersGetNative = http.headersGetNative;
const headersHasNative = http.headersHasNative;
const headersSetNative = http.headersSetNative;
const headersAppendNative = http.headersAppendNative;
const headersDeleteNative = http.headersDeleteNative;
const headersConstructorNative = http.headersConstructorNative;
const requestConstructorNative = http.requestConstructorNative;
const responseConstructorNative = http.responseConstructorNative;
const responseJsonStaticNative = http.responseJsonStaticNative;
const responseTextStaticNative = http.responseTextStaticNative;
const responseHtmlStaticNative = http.responseHtmlStaticNative;
const responseRawJsonStaticNative = http.responseRawJsonStaticNative;
const responseRedirectStaticNative = http.responseRedirectStaticNative;

// Bytecode caching for faster cold starts
const bytecode_cache = zq.bytecode_cache;

// HTTP protocol types (shared with server layer)
const http_types = @import("http_types.zig");
const OutboundIo = @import("outbound_io.zig").OutboundIo;

/// Replay wrappers are outermost. Apply the retired credential check outside
/// those wrappers, so recorded results cannot bypass refusal.
fn fetchCredentialOuter(
    comptime binding: zq.module_binding.ModuleBinding,
    comptime exp: zq.module_binding.FunctionBinding,
    comptime inner: zq.NativeFn,
) zq.NativeFn {
    if (comptime std.mem.eql(u8, binding.specifier, "zttp:fetch") and
        std.mem.eql(u8, exp.name, "fetch"))
    {
        return credentialOptionGuard(inner);
    }
    return inner;
}
pub const HttpRequestView = http_types.HttpRequestView;
const HttpResponse = http_types.HttpResponse;

fn fetchSyncNative(ctx_ptr: *anyopaque, _: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const rt = HandlerInstance.fromContext(ctx) orelse return error.RuntimeUnavailable;
    return http.fetchSync(rt.httpView(), args);
}

fn httpRequestNative(ctx_ptr: *anyopaque, _: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const rt = HandlerInstance.fromContext(ctx) orelse return error.RuntimeUnavailable;
    return http.httpRequest(rt.httpView(), args);
}

fn fetchModuleCallback(runtime_ptr: *anyopaque, _: *zq.Context, args: []const zq.JSValue) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    return http.dispatchFetchModule(rt.httpView(), args);
}

fn fetchModuleRefusal(runtime_ptr: *anyopaque, _: *zq.Context, code: []const u8, details: []const u8) anyerror!zq.JSValue {
    const rt: *HandlerInstance = @ptrCast(@alignCast(runtime_ptr));
    return http.createFetchErrorResponse(rt.httpView(), code, details);
}

fn credentialOptionGuard(comptime inner: zq.NativeFn) zq.NativeFn {
    return struct {
        fn guarded(ctx_ptr: *anyopaque, this_value: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
            const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
            const rt = HandlerInstance.fromContext(ctx) orelse return error.RuntimeUnavailable;
            if (try http.refuseCredentialOption(rt.httpView(), args)) |refusal| return refusal;
            return inner(ctx_ptr, this_value, args);
        }
    }.guarded;
}

fn bodyTextNative(ctx_ptr: *anyopaque, this: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    if (HandlerInstance.fromContext(ctx)) |rt| return runtime_builtins.bodyText(ctx, &rt.http_state, rt.allocator, this);
    return runtime_builtins.bodyText(ctx, null, ctx.allocator, this);
}

fn bodyJsonNative(ctx_ptr: *anyopaque, this: zq.JSValue, _: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    if (HandlerInstance.fromContext(ctx)) |rt| return runtime_builtins.bodyJson(ctx, &rt.http_state, rt.allocator, this);
    return runtime_builtins.bodyJson(ctx, null, ctx.allocator, this);
}

const runtime_config_mod = @import("runtime_config.zig");
const RuntimePolicyGeneration = @import("runtime_policy_generation.zig").RuntimePolicyGeneration;
const cost_meter = zq.CostMeter;

/// Public because `HandlerInstance.init` takes one, and the benchmark harness
/// in `packages/runtime/bench/` reaches this file as a module rather than by
/// relative path. Re-exporting here keeps the config type and the type that
/// consumes it in one module, so no consumer analyzes `runtime_config.zig`
/// a second time and ends up with an incompatible `RuntimeConfig`.
pub const RuntimeConfig = runtime_config_mod.RuntimeConfig;

/// Public for the benchmark harness, which drives the pool request path through
/// this module so it shares one `RuntimeConfig` type with the pool.
pub const HandlerPool = @import("runtime_pool.zig").HandlerPool;

const openTraceFile = runtime_config_mod.openTraceFile;
const applyRuntimeConfig = runtime_config_mod.applyRuntimeConfig;
const applyEmbeddedCapabilityPolicy = runtime_config_mod.applyEmbeddedCapabilityPolicy;

// ============================================================================
// File reading for module graph (POSIX, no async I/O dependency)
// ============================================================================

const readFilePosixForGraph = zq.file_io.readFileForModuleGraph;

pub const HandlerInstance = struct {
    allocator: std.mem.Allocator,
    ctx: *zq.Context,
    gc_state: *zq.GC,
    heap: *zq.Heap,
    interpreter: zq.Interpreter,
    last_opt_stats: zq.OptStats,
    strings: *zq.StringTable,
    owned_strings: ?zq.StringTable,
    handler_atom: ?zq.Atom,
    cached_handler_obj: ?*zq.JSObject,
    cached_dispatch: ?*const zq.PatternDispatchTable,
    config: RuntimeConfig,
    /// Policy tuple retained for this runtime's full lifetime.
    policy_generation: ?*RuntimePolicyGeneration = null,
    /// The pool reload-generation this runtime was compiled for. The pool's
    /// live-reload / egress-policy swap bumps the pool counter; ensureRuntime
    /// rebuilds this runtime when it falls behind. Defaults to 0 so existing
    /// initializers need not set it.
    pool_generation: u64 = 0,
    outbound_io_backend: ?OutboundIo,
    owns_resources: bool,
    active_request_id: std.atomic.Value(u64),
    last_request_body_len: usize,
    /// Source location of the most recent handler type fault, resolved from the
    /// bytecode line table (feature A). Set at the fault catch; the pool copies
    /// it out on the error path, because the server builds the 500 body after
    /// this runtime is already released.
    last_fault_location: ?zq.bytecode.LineEntry = null,
    http_state: http.HttpState,
    // Trace recording support
    trace_file: ?std.c.fd_t,
    trace_mutex: ?*zq.trace.TraceMutex,
    trace_recorder: ?*zq.TraceRecorder,
    active_request: ?HttpRequestView,
    // Hybrid allocation support
    arena_state: ?*zq.arena.Arena,
    hybrid_state: ?*zq.arena.HybridAllocator,
    const Self = @This();

    /// Recover the runtime that owns `ctx`. This is the sanctioned way for a
    /// native callback to reach its host runtime: the engine hands callbacks a
    /// `*Context`, and the host pointer makes the runtime an explicit argument
    /// rather than something read out of thread-local state.
    ///
    /// Returns null for a Context no runtime claimed (an engine-only Context in
    /// a compiler test, for example).
    pub fn fromContext(ctx: *zq.Context) ?*Self {
        const host = ctx.host orelse return null;
        return @ptrCast(@alignCast(host));
    }

    /// Borrow the HTTP dependencies without moving state or the Io backend.
    pub fn httpView(self: *Self) http.View {
        return .{
            .allocator = self.allocator,
            .ctx = self.ctx,
            .state = &self.http_state,
            .config = .{
                .enabled = self.config.outbound_http_enabled,
                .allow_host = self.config.outbound_allow_host,
                .max_response_bytes = self.config.outbound_max_response_bytes,
                .timeout_ms = self.config.outbound_timeout_ms,
                .replay = self.config.replay_file_path != null,
            },
            .backend = if (self.outbound_io_backend) |*backend| backend else null,
        };
    }

    pub fn init(allocator: std.mem.Allocator, config: RuntimeConfig) !*Self {
        if (config.outbound_timeout_ms == 0) return error.ZeroOutboundTimeout;
        const self = try allocator.create(Self);
        var initialized = false;
        errdefer if (!initialized) allocator.destroy(self);

        // Construct the heap first so early failure cleanup, like normal
        // teardown, releases the GC before the heap it may still reference.
        const heap_state = try allocator.create(zq.Heap);
        errdefer if (!initialized) allocator.destroy(heap_state);
        heap_state.* = zq.Heap.init(allocator, .{});
        errdefer if (!initialized) heap_state.deinit();

        // Initialize GC
        const gc_state = try allocator.create(zq.GC);
        errdefer if (!initialized) allocator.destroy(gc_state);
        gc_state.* = try zq.GC.init(allocator, .{
            .nursery_size = config.nursery_size,
        });
        errdefer if (!initialized) gc_state.deinit();

        gc_state.setHeap(heap_state);

        // Initialize context
        const ctx = try zq.Context.init(allocator, gc_state, .{});
        errdefer if (!initialized) ctx.deinit();

        applyRuntimeConfig(ctx, gc_state, heap_state, config);
        applyEmbeddedCapabilityPolicy(ctx, config, null);

        // Install core JS builtins (Array.prototype, Object, Math, JSON, etc.)
        try zq.initBuiltins(ctx);

        // Initialize hybrid allocation if enabled
        var arena_state: ?*zq.arena.Arena = null;
        var hybrid_state: ?*zq.arena.HybridAllocator = null;

        if (config.use_hybrid_allocation) {
            arena_state = try allocator.create(zq.arena.Arena);
            errdefer allocator.destroy(arena_state.?);
            arena_state.?.* = try zq.arena.Arena.init(allocator, .{ .size = config.arena_size });
            errdefer arena_state.?.deinit();

            hybrid_state = try allocator.create(zq.arena.HybridAllocator);
            errdefer allocator.destroy(hybrid_state.?);
            hybrid_state.?.* = .{
                .persistent = allocator,
                .arena = arena_state.?,
            };
            ctx.setHybridAllocator(hybrid_state.?);
            if (config.memory_limit > 0) {
                hybrid_state.?.setMemoryLimit(config.memory_limit);
            }
        }

        const interp = zq.Interpreter.init(ctx);

        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .gc_state = gc_state,
            .heap = heap_state,
            .interpreter = interp,
            .last_opt_stats = .{},
            .strings = undefined,
            .owned_strings = zq.StringTable.init(allocator),
            .handler_atom = null,
            .cached_handler_obj = null,
            .cached_dispatch = null,
            .config = config,
            .policy_generation = null,
            .outbound_io_backend = if (config.outbound_http_enabled)
                OutboundIo.init(allocator)
            else
                null,
            .owns_resources = true,
            .active_request_id = std.atomic.Value(u64).init(0),
            .last_request_body_len = 0,
            .last_fault_location = null,
            .http_state = .{},
            .trace_file = null,
            .trace_mutex = null,
            .trace_recorder = null,
            .active_request = null,
            .arena_state = arena_state,
            .hybrid_state = hybrid_state,
        };
        self.strings = &self.owned_strings.?;
        // All core resources have moved into the wrapper. Later failures use
        // normal teardown, including trace descriptors and the outbound backend.
        initialized = true;
        errdefer self.deinit();

        // The Context carries the host pointer so a native callback can reach
        // this runtime by an explicit cast. `self` is heap-allocated and stable
        // for the runtime's whole life; `deinit` clears the slot.
        self.ctx.host = self;

        // Open trace file if configured
        if (config.trace_file_path) |trace_path| {
            self.trace_file = openTraceFile(allocator, trace_path) catch |err| {
                std.log.err("Failed to open trace file '{s}': {}", .{ trace_path, err });
                return err;
            };
            const mutex = try allocator.create(zq.trace.TraceMutex);
            mutex.* = .{};
            self.trace_mutex = mutex;
        }

        // Install built-in bindings
        try self.installBindings();

        return self;
    }

    /// Initialize a runtime wrapper on top of a pooled zts runtime.
    /// The pooled runtime owns ctx/gc/heap; this wrapper owns only its own state.
    pub fn initFromPool(
        pool_rt: *zq.LockFreePool.Runtime,
        config: RuntimeConfig,
        policy_generation: *RuntimePolicyGeneration,
    ) !*Self {
        if (config.outbound_timeout_ms == 0) return error.ZeroOutboundTimeout;
        const allocator = pool_rt.ctx.allocator;
        const self = try allocator.create(Self);
        const retained_policy = policy_generation.retain();

        const interp = zq.Interpreter.init(pool_rt.ctx);

        self.* = .{
            .allocator = allocator,
            .ctx = pool_rt.ctx,
            .gc_state = pool_rt.gc_state,
            .heap = pool_rt.heap_state,
            .interpreter = interp,
            .last_opt_stats = .{},
            .strings = &pool_rt.strings,
            .owned_strings = null,
            .handler_atom = null,
            .cached_handler_obj = null,
            .cached_dispatch = null,
            .config = config,
            .policy_generation = retained_policy,
            .outbound_io_backend = if (config.outbound_http_enabled)
                OutboundIo.init(allocator)
            else
                null,
            .owns_resources = false,
            .active_request_id = std.atomic.Value(u64).init(0),
            .last_request_body_len = 0,
            .last_fault_location = null,
            .http_state = .{},
            .trace_file = null,
            .trace_mutex = null,
            .trace_recorder = null,
            .active_request = null,
            // Pool runtimes manage their own hybrid allocation
            .arena_state = null,
            .hybrid_state = null,
        };
        // The pooled Context survives a failed wrapper installation. Normal
        // teardown clears its published host without destroying pooled cores.
        errdefer self.deinit();

        applyRuntimeConfig(pool_rt.ctx, pool_rt.gc_state, pool_rt.heap_state, config);
        applyEmbeddedCapabilityPolicy(pool_rt.ctx, config, retained_policy.policy);
        if (config.shared_rate_store) |store| try zq.modules.ratelimit.installShared(pool_rt.ctx, store);
        pool_rt.ctx.policy_generation = retained_policy.id;

        // Pooled Contexts outlive this wrapper and are handed to the next
        // wrapper on recycle, so the slot is re-pointed here on every init and
        // cleared in `deinit`. A stale host pointer would be a use-after-free.
        pool_rt.ctx.host = self;

        // Install core JS builtins if the pooled runtime hasn't already done so.
        if (pool_rt.ctx.builtin_objects.items.len == 0) {
            try zq.initBuiltins(pool_rt.ctx);
        }
        try self.installBindings();

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Drop the host pointer before anything is torn down. On the pooled
        // path the Context survives this wrapper, so leaving it set would hand
        // the next callback a freed pointer.
        if (self.ctx.host == @as(?*anyopaque, @ptrCast(self))) self.ctx.host = null;
        if (self.owns_resources) {
            // Context teardown walks builtin objects and bytecode constants that may
            // still reference interned unique strings from this runtime.
            self.ctx.deinit();
            self.gc_state.deinit();
            self.heap.deinit();
            // Clean up hybrid allocation state after the context has released any
            // arena-backed request allocations it still knows about.
            if (self.arena_state) |a| {
                a.deinit();
                self.allocator.destroy(a);
            }
            if (self.hybrid_state) |h| {
                self.allocator.destroy(h);
            }
            self.allocator.destroy(self.gc_state);
            self.allocator.destroy(self.heap);
            if (self.trace_file) |fd| std.Io.Threaded.closeFd(fd);
            if (self.trace_mutex) |m| self.allocator.destroy(m);
        }
        self.http_state.deinit(self.allocator);
        if (self.outbound_io_backend) |*io_backend| {
            io_backend.deinit();
        }
        if (self.trace_recorder) |rec| {
            rec.deinit();
            self.allocator.destroy(rec);
        }
        if (self.owned_strings) |*owned_strings| {
            owned_strings.deinit();
        }
        if (self.policy_generation) |generation| generation.release();
        self.allocator.destroy(self);
    }

    /// Install native API bindings (console, etc.)
    /// Note: Response is already set up by initBuiltins() with constructor and static methods
    fn installBindings(self: *Self) !void {
        // Use predefined handler atom
        self.handler_atom = zq.Atom.handler;
        self.cached_handler_obj = null;
        self.cached_dispatch = null;

        try self.installHttpConstructors();
        // Install console object
        try self.installConsole();
        try self.installHttpRequest();
        try self.installFetchSync();

        // Register all virtual module native functions eagerly.
        // This ensures import bindings resolve correctly whether the handler
        // was parsed or loaded from bytecode cache.
        try self.installVirtualModules();
        try self.installSqlModuleState();
        try self.installFetchModuleState();

        // Note: Response, h(), renderToString(), Fragment are all set up by initBuiltins()
        // Don't re-register them here as it would overwrite the proper constructor
    }

    fn installHttpConstructors(self: *Self) !void {
        const root_class_idx = self.ctx.root_class_idx;
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;

        const request_proto = try zq.JSObject.create(self.allocator, root_class_idx, null, pool);
        var request_proto_unowned = true;
        errdefer if (request_proto_unowned) request_proto.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, request_proto);
        request_proto_unowned = false;
        try self.addDynamicMethod(request_proto, "text", bodyTextNative, 0);
        try self.addDynamicMethod(request_proto, "json", bodyJsonNative, 0);

        const response_proto = try zq.JSObject.create(self.allocator, root_class_idx, null, pool);
        var response_proto_unowned = true;
        errdefer if (response_proto_unowned) response_proto.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, response_proto);
        response_proto_unowned = false;
        try self.addDynamicMethod(response_proto, "text", bodyTextNative, 0);
        try self.addDynamicMethod(response_proto, "json", bodyJsonNative, 0);

        const headers_proto = try zq.JSObject.create(self.allocator, root_class_idx, null, pool);
        var headers_proto_unowned = true;
        errdefer if (headers_proto_unowned) headers_proto.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, headers_proto);
        headers_proto_unowned = false;
        try self.addDynamicMethod(headers_proto, "get", headersGetNative, 1);
        try self.addDynamicMethod(headers_proto, "set", headersSetNative, 2);
        try self.addDynamicMethod(headers_proto, "append", headersAppendNative, 2);
        try self.addDynamicMethod(headers_proto, "has", headersHasNative, 1);
        try self.addDynamicMethod(headers_proto, "delete", headersDeleteNative, 1);

        const headers_ctor_atom = try self.ctx.atoms.intern("Headers");
        const headers_ctor = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            root_class_idx,
            headersConstructorNative,
            headers_ctor_atom,
            1,
        );
        var headers_ctor_unowned = true;
        errdefer if (headers_ctor_unowned) headers_ctor.destroyBuiltin(self.allocator, pool);
        try self.ctx.setPropertyChecked(headers_ctor, .prototype, headers_proto.toValue());
        try self.ctx.builtin_objects.append(self.allocator, headers_ctor);
        headers_ctor_unowned = false;
        try self.ctx.setGlobal(headers_ctor_atom, headers_ctor.toValue());

        const request_ctor_atom = try self.ctx.atoms.intern("Request");
        const request_ctor = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            root_class_idx,
            requestConstructorNative,
            request_ctor_atom,
            2,
        );
        var request_ctor_unowned = true;
        errdefer if (request_ctor_unowned) request_ctor.destroyBuiltin(self.allocator, pool);
        try self.ctx.setPropertyChecked(request_ctor, .prototype, request_proto.toValue());
        try self.ctx.builtin_objects.append(self.allocator, request_ctor);
        request_ctor_unowned = false;
        try self.ctx.setGlobal(request_ctor_atom, request_ctor.toValue());

        const response_ctor = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            root_class_idx,
            responseConstructorNative,
            .Response,
            2,
        );
        var response_ctor_unowned = true;
        errdefer if (response_ctor_unowned) response_ctor.destroyBuiltin(self.allocator, pool);
        try self.ctx.setPropertyChecked(response_ctor, .prototype, response_proto.toValue());
        try self.addMethod(response_ctor, .json, responseJsonStaticNative, 1);
        try self.addMethod(response_ctor, .text, responseTextStaticNative, 1);
        try self.addMethod(response_ctor, .html, responseHtmlStaticNative, 1);
        try self.addDynamicMethod(response_ctor, "redirect", responseRedirectStaticNative, 1);
        try self.addMethod(response_ctor, .rawJson, responseRawJsonStaticNative, 1);
        try self.ctx.builtin_objects.append(self.allocator, response_ctor);
        response_ctor_unowned = false;
        try self.ctx.setGlobal(.Response, response_ctor.toValue());

        // The spec 7.2 body readers, installed here for the same reason the
        // Response constructors are: the engine's own installer runs for
        // analysis, and this one runs for serving. A reader typed by the
        // checker and missing at run time would be the worst of both.
        try self.installGlobalFunction("requestBody", zq.http.requestBody, 1);
        try self.installGlobalFunction("requestText", zq.http.requestText, 1);
        try self.installGlobalFunction("requestJson", zq.http.requestJson, 1);

        self.http_state.installPrototypes(request_proto, response_proto, headers_proto);
    }

    fn installGlobalFunction(self: *Self, name: []const u8, func: zq.NativeFn, arg_count: u8) !void {
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
        const atom = try self.ctx.atoms.intern(name);
        const fn_obj = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            self.ctx.root_class_idx,
            func,
            atom,
            arg_count,
        );
        var unowned = true;
        errdefer if (unowned) fn_obj.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, fn_obj);
        unowned = false;
        try self.ctx.setGlobal(atom, fn_obj.toValue());
    }

    fn addMethod(self: *Self, obj: *zq.JSObject, atom: zq.Atom, func: zq.NativeFn, arg_count: u8) !void {
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
        const fn_obj = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            self.ctx.root_class_idx,
            func,
            atom,
            arg_count,
        );
        errdefer fn_obj.destroyFull(self.allocator);
        try self.ctx.setPropertyChecked(obj, atom, fn_obj.toValue());
    }

    fn addDynamicMethod(self: *Self, obj: *zq.JSObject, name: []const u8, func: zq.NativeFn, arg_count: u8) !void {
        const atom = try self.ctx.atoms.intern(name);
        try self.addMethod(obj, atom, func, arg_count);
    }

    fn installConsole(self: *Self) !void {
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;

        // Create console object
        const root_class_idx = self.ctx.root_class_idx;
        const console_obj = try zq.JSObject.create(self.allocator, root_class_idx, null, pool);
        var console_obj_unowned = true;
        errdefer if (console_obj_unowned) console_obj.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, console_obj);
        console_obj_unowned = false;

        try self.addMethod(console_obj, .log, console.consoleLog, 0);
        try self.addDynamicMethod(console_obj, "error", console.consoleError, 0);
        try self.addDynamicMethod(console_obj, "warn", console.consoleError, 0);
        try self.addDynamicMethod(console_obj, "info", console.consoleLog, 0);
        try self.addDynamicMethod(console_obj, "debug", console.consoleLog, 0);

        // Register on global
        try self.ctx.setGlobal(.console, console_obj.toValue());
    }

    fn installHttpRequest(self: *Self) !void {
        const root_class_idx = self.ctx.root_class_idx;
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;

        const fn_atom = try self.ctx.atoms.intern("httpRequest");
        const fn_obj = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            root_class_idx,
            httpRequestNative,
            fn_atom,
            1,
        );
        var fn_obj_unowned = true;
        errdefer if (fn_obj_unowned) fn_obj.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, fn_obj);
        fn_obj_unowned = false;
        try self.ctx.setGlobal(fn_atom, fn_obj.toValue());
    }

    fn installFetchSync(self: *Self) !void {
        const root_class_idx = self.ctx.root_class_idx;
        const pool = self.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;

        const fn_atom = try self.ctx.atoms.intern("fetchSync");
        // In replay mode, use a stub that returns recorded fetch responses.
        const fetch_replay_stub = comptime zq.trace.makeReplayStub("http", "fetchSync");
        const func: zq.NativeFn = if (self.config.replay_file_path != null)
            comptime credentialOptionGuard(fetch_replay_stub)
        else
            comptime credentialOptionGuard(fetchSyncNative);
        const fn_obj = try zq.JSObject.createNativeFunction(
            self.allocator,
            pool,
            root_class_idx,
            func,
            fn_atom,
            1,
        );
        var fn_obj_unowned = true;
        errdefer if (fn_obj_unowned) fn_obj.destroyBuiltin(self.allocator, pool);
        try self.ctx.builtin_objects.append(self.allocator, fn_obj);
        fn_obj_unowned = false;
        try self.ctx.setGlobal(fn_atom, fn_obj.toValue());
    }

    /// Validate module imports from parsed IR.
    /// Called after parse() to verify that all import specifiers reference valid modules.
    /// Native functions are registered eagerly by installVirtualModules(), so this only validates.
    /// Returns true if file imports are present (requiring module graph compilation).
    fn resolveModuleImports(_: *Self, p: *const zq.Parser) !bool {
        const imports = p.getImports() catch |err| {
            std.log.err("Failed to extract module imports: {}", .{err});
            return err;
        };
        defer p.freeImports(imports);

        var has_file_imports = false;

        for (imports) |import_info| {
            const result = zq.modules.resolve(import_info.module_specifier);
            switch (result) {
                .virtual => |binding| {
                    // Validate that all imported names exist in the module
                    if (zq.modules.validateImports(binding, import_info.specifier_names)) |missing| {
                        std.log.err("Module '{s}' has no export '{s}'", .{ import_info.module_specifier, missing });
                        return error.ModuleExportNotFound;
                    }
                },
                .file => {
                    has_file_imports = true;
                },
                .unknown => {
                    if (!builtin.is_test) std.log.err("Unknown module: '{s}'; only zttp:* virtual modules and relative file imports are supported", .{import_info.module_specifier});
                    return error.UnknownModule;
                },
            }
        }

        return has_file_imports;
    }

    /// Build a module graph from file imports, compile all dependencies,
    /// and run them in topological order so their exports are available
    /// as globals when the entry file executes.
    fn compileAndRunFileImports(self: *Self, entry_source: []const u8, filename: []const u8, refresh_handler: bool, prepared_eval: bool) !void {
        // Build module graph
        var graph = zq.modules.ModuleGraph.init(self.allocator);
        defer graph.deinit();

        (if (prepared_eval)
            graph.buildPreparedEval(filename, entry_source, readFilePosixForGraph)
        else
            graph.build(filename, entry_source, readFilePosixForGraph)) catch |err| {
            switch (err) {
                error.CircularImport => std.log.err("Circular import detected starting from '{s}'", .{filename}),
                error.ImportFileNotFound => std.log.err("Could not read an imported file from '{s}'", .{filename}),
                error.ImportNestingTooDeep => std.log.err("Import nesting too deep (max 32) from '{s}'", .{filename}),
                else => std.log.err("Module graph error for '{s}': {}", .{ filename, err }),
            }
            return err;
        };

        if (graph.dependencyCount() == 0) {
            // No actual file dependencies found; run entry normally
            // This shouldn't happen since resolveModuleImports said there were file imports,
            // but handle gracefully.
            if (refresh_handler) {
                try self.refreshHandlerCache();
            }
            return;
        }

        // Compile all modules with shared atom table
        var module_compiler = zq.modules.ModuleCompiler.init(
            self.allocator,
            &self.ctx.atoms,
            self.strings,
        );
        var compile_result = module_compiler.compileAll(&graph) catch |err| {
            std.log.err("Multi-module compilation failed: {}", .{err});
            return err;
        };
        defer compile_result.deinit();

        // Run each module in execution order
        for (compile_result.modules) |*compiled_mod| {
            // Materialize shapes
            if (compiled_mod.shapes.len > 0) {
                try self.ctx.materializeShapes(compiled_mod.shapes);
            }

            // Run bytecode - this defines exported globals
            _ = try self.interpreter.run(&compiled_mod.func);
        }

        if (refresh_handler) {
            try self.refreshHandlerCache();
        }
    }

    /// Register all virtual module native functions on the context.
    /// Called during installBindings() for every runtime instance.
    /// In replay mode, registers stubs that return recorded values.
    /// In trace mode, registers wrappers that record I/O.
    fn installVirtualModules(self: *Self) !void {
        if (self.config.replay_file_path != null) {
            // Replay mode: stubs that return recorded values from ReplayState
            inline for (zq.builtinModules) |binding| {
                try zq.modules.registerVirtualModuleReplayWithOuter(binding, self.ctx, self.allocator, fetchCredentialOuter);
            }
        } else if (self.config.trace_file_path != null) {
            // Use traced wrappers that record I/O to TraceRecorder
            inline for (zq.builtinModules) |binding| {
                try zq.modules.registerVirtualModuleTraced(binding, self.ctx, self.allocator);
            }
        } else {
            inline for (zq.builtinModules) |binding| {
                try zq.modules.registerVirtualModule(binding, self.ctx, self.allocator);
            }
        }
    }

    fn installSqlModuleState(self: *Self) !void {
        try zq.modules.sql.installStore(self.ctx, self.config.sqlite_path);
    }

    fn installFetchModuleState(self: *Self) !void {
        try zq.modules.fetch.installState(self.ctx, self, fetchModuleCallback, fetchModuleRefusal);
    }

    fn verifyBytecodeRecursive(func: *const zq.FunctionBytecode) !void {
        const verify_result = zq.BytecodeVerifier.verify(func);
        if (!verify_result.valid) {
            if (!builtin.is_test) {
                std.log.err("Bytecode verification failed at offset {d}: {s}", .{
                    verify_result.offset,
                    verify_result.message,
                });
            }
            return error.BytecodeVerificationFailed;
        }

        for (func.constants) |constant| {
            const nested_func = bytecodeConstant(constant) orelse continue;
            try verifyBytecodeRecursive(nested_func);
        }
    }

    fn bytecodeConstant(constant: zq.JSValue) ?*const zq.FunctionBytecode {
        if (!constant.isExternPtr()) return null;
        const magic = constant.toExternPtr(u32);
        if (magic.* != zq.bytecode.MAGIC) return null;
        return constant.toExternPtr(zq.FunctionBytecode);
    }

    fn captureCompilationStats(self: *Self, parser: *const zq.Parser) void {
        self.last_opt_stats = if (parser.code_gen) |cg| cg.getOptStats() else .{};
    }

    /// Load and compile JavaScript code
    pub fn loadCode(self: *Self, code: []const u8, filename: []const u8) !void {
        _ = try self.loadCodeWithCachingInternal(code, filename, null, true, false);
    }

    /// Load and compile JavaScript code without requiring a `handler` export.
    /// Used by benchmark and script-style tooling that call other globals directly.
    pub fn loadCodeNoHandler(self: *Self, code: []const u8, filename: []const u8) !void {
        _ = try self.loadCodeWithCachingInternal(code, filename, null, false, false);
    }

    /// Load and compile JavaScript code, optionally returning serialized bytecode for caching
    /// If cache_buffer is provided, serializes the bytecode and returns the serialized slice
    pub fn loadCodeWithCaching(self: *Self, code: []const u8, filename: []const u8, cache_buffer: ?[]u8) !?[]const u8 {
        return self.loadCodeWithCachingInternal(code, filename, cache_buffer, true, false);
    }

    pub fn loadPreparedEval(self: *Self, source: execution_spec.PreparedEvalSource, filename: []const u8) !void {
        _ = try self.loadCodeWithCachingInternal(source.code, filename, null, true, true);
    }

    pub fn loadPreparedEvalWithCaching(
        self: *Self,
        source: execution_spec.PreparedEvalSource,
        filename: []const u8,
        cache_buffer: ?[]u8,
    ) !?[]const u8 {
        return self.loadCodeWithCachingInternal(source.code, filename, cache_buffer, true, true);
    }

    fn loadCodeWithCachingInternal(self: *Self, code: []const u8, filename: []const u8, cache_buffer: ?[]u8, refresh_handler: bool, prepared_eval: bool) !?[]const u8 {
        self.last_opt_stats = .{};
        self.interpreter.resetProfilingCounters();
        const source_kind = zq.classifySourcePath(filename);
        if (source_kind == .unsupported) return error.UnsupportedSourceExtension;
        if (prepared_eval and source_kind != .virtual_javascript) return error.UnsupportedSourceExtension;
        // Every source passes admission. A `.ts` file also gets type checking and
        // normalized diagnostic positions. A virtual source (inline code or prepared
        // eval) leaves authored annotations unchecked and generates bytecode right
        // after admission. Prepared eval implies a virtual source.
        const typed_file = source_kind.isTyped();
        var diag_view = zq.SourceView.of(code);
        diag_view.name = filename;
        diag_view.normalize_positions = typed_file;
        var p = try zq.Parser.initTyped(self.allocator, self.allocator, code, self.strings, &self.ctx.atoms);
        defer p.deinit();
        var bytecode_data: []const u8 = undefined;
        switch (try p.parseTypedIr()) {
            .accepted => {},
            .parser_refused => |refusal| {
                logParseErrors(self.allocator, diag_view, p.js_parser.getProjectedErrors());
                return refusal.first_error;
            },
            .terminal_admission_refused => |failure| {
                const err = zq.prepareErrorForAdmissionFailure(failure);
                if (!builtin.is_test) std.log.err("TypeScript strip error in {s}: {}", .{ filename, err });
                return err;
            },
            .recovered_admission_refused => unreachable,
        }
        if (!typed_file) bytecode_data = try p.generateParsed(self.allocator);

        {
            const ir_view = zq.IrView.fromIRStore(&p.js_parser.nodes, &p.js_parser.constants);
            var parsed = if (typed_file)
                zq.pipeline.ParsedModule.fromTypedExisting(ir_view, p.root_node, &self.ctx.atoms, &p.js_parser.type_store)
            else
                zq.pipeline.ParsedModule.fromExisting(ir_view, p.root_node, &self.ctx.atoms);
            parsed.scopes = &p.js_parser.scopes;

            var type_env_storage: zq.pipeline.TypeEnvStorage = .{};
            defer type_env_storage.deinit(self.allocator);
            if (typed_file) {
                try type_env_storage.initWithSource(self.allocator, .{ .direct = .{
                    .store = &p.js_parser.type_store,
                    .ir_view = ir_view,
                    .atoms = &self.ctx.atoms,
                } });
            }

            var resolved = try zq.pipeline.resolve(
                self.allocator,
                parsed,
                // The runtime parse path only surfaces bool diagnostics; strict
                // ZTS6xx is a build-time concern that precompile already ran.
                // Skip it here to keep the runtime loop free of redundant work.
                .{ .type_env = type_env_storage.envPtr(), .strict = false },
            );
            defer resolved.deinit();

            const bool_diags = resolved.boolDiagnostics();
            if (bool_diags.len > 0) {
                var diag_output: std.ArrayList(u8) = .empty;
                defer diag_output.deinit(self.allocator);
                var diag_aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &diag_output);
                resolved.formatBoolDiagnostics(diag_view, &diag_aw.writer) catch {};
                diag_output = diag_aw.toArrayList();
                if (diag_output.items.len > 0) {
                    std.log.err("{s}", .{diag_output.items});
                }
                std.log.err("{d} boolean check error(s), {d} warning(s)", .{
                    resolved.bool_error_count,
                    bool_diags.len - resolved.bool_error_count,
                });
            }
            if (resolved.bool_error_count > 0) {
                return error.SoundModeViolation;
            }

            const type_diags = resolved.typeDiagnostics();
            if (type_diags.len > 0) {
                var tc_output: std.ArrayList(u8) = .empty;
                defer tc_output.deinit(self.allocator);
                var tc_aw: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &tc_output);
                resolved.formatTypeDiagnostics(diag_view, &tc_aw.writer) catch {};
                tc_output = tc_aw.toArrayList();
                if (tc_output.items.len > 0 and !builtin.is_test) {
                    std.log.err("{s}", .{tc_output.items});
                }
            }
            if (resolved.typeErrorCount() > 0) {
                return error.SoundModeViolation;
            }
        }

        if (typed_file) bytecode_data = try p.generateParsed(self.allocator);

        // Resolve module imports and register virtual module native functions
        const has_file_imports = try self.resolveModuleImports(&p);

        // If file imports are present, build module graph and compile dependencies
        if (has_file_imports) {
            try self.compileAndRunFileImports(code, filename, refresh_handler, prepared_eval);
            return null; // Disable caching for multi-module handlers
        }

        // Materialize object literal shapes before execution
        const shapes = p.getShapes();
        if (shapes.len > 0) {
            try self.ctx.materializeShapes(shapes);
        }

        // Create FunctionBytecode struct to wrap the parsed result
        const func = zq.FunctionBytecode{
            .header = .{},
            .name_atom = 0,
            .arg_count = 0,
            .local_count = p.max_local_count,
            .stack_size = 256,
            .flags = .{},
            .code = bytecode_data,
            .constants = p.constants.items,
            .source_map = null,
            .line_table = p.getLineTable(),
        };

        // Bytecode verification: reject malformed bytecode before execution.
        try verifyBytecodeRecursive(&func);

        // Serialize for caching if buffer provided (includes atoms for true cache hit)
        var serialized: ?[]const u8 = null;
        if (cache_buffer) |buffer| {
            var writer = bytecode_cache.SliceWriter{ .buffer = buffer };
            bytecode_cache.serializeBytecodeWithAtomsAndShapes(
                &func,
                &self.ctx.atoms,
                shapes,
                &writer,
                self.allocator,
            ) catch {
                // Serialization failed (buffer too small), continue without caching
            };
            if (writer.pos > 0) {
                serialized = writer.getWritten();
            }
        }

        // Execute the compiled code to define functions
        _ = try self.interpreter.run(&func);
        self.captureCompilationStats(&p);
        if (refresh_handler) {
            try self.refreshHandlerCache();
        }

        return serialized;
    }

    /// Load handler code (alias for loadCode for API compatibility)
    pub fn loadHandler(self: *Self, code: []const u8, filename: []const u8) !void {
        return self.loadCode(code, filename);
    }

    /// Call a global function by name with the provided arguments.
    /// Returns the function result or error.NotCallable if missing or not callable.
    pub fn callGlobalFunction(self: *Self, name: []const u8, args: []const zq.JSValue) !zq.JSValue {
        const atom = zq.lookupPredefinedAtom(name) orelse try self.ctx.atoms.intern(name);
        const func_val = self.ctx.getGlobal(atom) orelse return error.NotCallable;
        if (!func_val.isCallable()) return error.NotCallable;
        const func_obj = func_val.toPtr(zq.JSObject);
        return try self.callFunction(func_obj, args);
    }

    fn refreshHandlerCache(self: *Self) !void {
        const handler_atom = self.handler_atom orelse return error.NoHandler;
        const handler_val = self.ctx.getGlobal(handler_atom) orelse return error.NoHandler;
        if (!handler_val.isCallable()) return error.HandlerNotCallable;

        const handler_obj = handler_val.toPtr(zq.JSObject);
        self.cached_handler_obj = handler_obj;

        if (handler_obj.getBytecodeFunctionData()) |bc_data| {
            self.cached_dispatch = bc_data.bytecode.pattern_dispatch;
        } else {
            self.cached_dispatch = null;
        }
    }

    /// Load from cached serialized bytecode (Phase 1d: true cache hit with atoms and shapes)
    pub fn loadFromCachedBytecode(self: *Self, cached_data: []const u8) !void {
        try self.loadFromCachedBytecodeImpl(cached_data, true);
    }

    /// Load from cached bytecode without refreshing handler cache.
    /// Used for dependency modules that define exports but not the handler function.
    pub fn loadFromCachedBytecodeNoHandler(self: *Self, cached_data: []const u8) !void {
        try self.loadFromCachedBytecodeImpl(cached_data, false);
    }

    fn loadFromCachedBytecodeImpl(self: *Self, cached_data: []const u8, refresh_handler: bool) !void {
        self.last_opt_stats = .{};
        self.interpreter.resetProfilingCounters();
        var reader = bytecode_cache.SliceReader{ .data = cached_data };

        // Deserialize bytecode with atoms and shapes - skips parsing entirely
        var result = try bytecode_cache.deserializeBytecodeWithAtomsAndShapes(
            &reader,
            &self.ctx.atoms,
            self.allocator,
            self.strings,
        );
        var bytecode_transferred = false;
        defer {
            if (bytecode_transferred) {
                // Free shapes after materialization (they're copied into hidden classes)
                for (result.shapes) |shape| {
                    self.allocator.free(shape);
                }
                self.allocator.free(result.shapes);
            } else {
                result.deinit();
            }
        }

        // Verify deserialized bytecode before materialization or execution.
        try verifyBytecodeRecursive(result.func);

        // Materialize object literal shapes before execution
        if (result.shapes.len > 0) {
            // Convert [][]object.Atom to []const []const object.Atom for materializeShapes
            const shapes_const: []const []const zq.Atom = @ptrCast(result.shapes);
            try self.ctx.materializeShapes(shapes_const);
        }

        // The script root is heap-allocated on cache deserialization. Transfer
        // it to the context before execution creates separately tracked nested
        // function objects; context teardown deduplicates both ownership paths.
        try self.ctx.takeBytecodeRoot(result.func);
        bytecode_transferred = true;

        // Execute the deserialized bytecode
        _ = try self.interpreter.run(result.func);
        if (refresh_handler) {
            try self.refreshHandlerCache();
        }
    }

    /// Arm the per-request execution deadline on this runtime's context.
    /// No-op when request_timeout_ms == 0.
    pub fn armRequestDeadline(self: *Self) void {
        self.armRequestDeadlineMs(self.config.request_timeout_ms);
    }

    fn armRequestDeadlineMs(self: *Self, ms: u32) void {
        self.ctx.interrupt_requested.store(false, .monotonic);
        self.ctx.deadline_ns = 0;
        if (ms == 0) return;
        const now = compat.monotonicNowNs() catch return;
        self.ctx.deadline_ns = now + @as(u64, ms) * std.time.ns_per_ms;
    }

    /// Clear the per-request execution deadline and interrupt flag.
    pub fn clearRequestDeadline(self: *Self) void {
        self.ctx.deadline_ns = 0;
        self.ctx.interrupt_requested.store(false, .monotonic);
    }

    /// Execute the handler function with a request
    pub fn executeHandler(self: *Self, request: HttpRequestView) !HttpResponse {
        return self.executeHandlerWithId(request, 0);
    }

    pub fn executeHandlerWithId(self: *Self, request: HttpRequestView, request_id: u64) !HttpResponse {
        return self.executeHandlerInternal(request, request_id, false);
    }

    /// Execute handler and return a response that borrows JS string bodies.
    /// Caller must ensure the runtime is not reset or reused until after send.
    pub fn executeHandlerBorrowed(self: *Self, request: HttpRequestView) !HttpResponse {
        return self.executeHandlerBorrowedWithId(request, 0);
    }

    pub fn executeHandlerBorrowedWithId(self: *Self, request: HttpRequestView, request_id: u64) !HttpResponse {
        return self.executeHandlerInternal(request, request_id, true);
    }

    /// Record a soundness incident: a runtime fault on a path the compiler proved
    /// safe (every guarding chip discharged, yet the handler faulted). Loud log
    /// always (outside tests); JSONL append when --incident-log is configured.
    /// Best-effort — never disturbs the response path.
    fn recordSoundnessIncident(self: *Self, chips: []const []const u8, detail: []const u8) void {
        const method: []const u8 = if (self.active_request) |r| r.method else "";
        // Prefer the parsed route path; fall back to the full request URL when a
        // caller only populated url (e.g. the fast-path / test request builders).
        const path: []const u8 = if (self.active_request) |r|
            (if (r.path.len > 0) r.path else r.url)
        else
            "";
        // A Zig-level type fault ran through the interpreter's trace catch, which
        // resolves the faulting bytecode offset to a source line via the line
        // table (feature A). Append it to the detail when available.
        var detail_buf: [192]u8 = undefined;
        const full_detail: []const u8 = if (self.interpreter.last_error_location) |loc|
            (std.fmt.bufPrint(&detail_buf, "{s} at {d}:{d}", .{ detail, loc.line, loc.column }) catch detail)
        else
            detail;
        if (!builtin.is_test) {
            std.log.err("SOUNDNESS INCIDENT: {s} {s} faulted on a proven path ({s})", .{ method, path, full_detail });
        }
        if (self.config.incident_log_fd) |fd| {
            incident_log.write(self.allocator, fd, method, path, chips, full_detail);
        }
    }

    fn arenaHighWatermark(self: *Self) usize {
        const arena = self.arena_state orelse return 0;
        return arena.getStats().high_watermark;
    }

    fn recordCostBoundedIncident(self: *Self, detail: []const u8) void {
        self.recordSoundnessIncident(&.{"cost_bounded"}, detail);
    }

    fn recordCostFuseIncidents(self: *Self) void {
        const ceilings = self.config.cost_ceilings orelse return;
        const high_water = self.arenaHighWatermark();

        inline for (std.enums.values(cost_meter.ModuleClass)) |class| {
            if (ceilings.classLimit(class)) |ceiling| {
                const observed: u64 = self.ctx.cost_meter.count(class);
                if (observed > ceiling) {
                    var detail_buf: [192]u8 = undefined;
                    const detail = std.fmt.bufPrint(
                        &detail_buf,
                        "cost envelope exceeded: {s} {d} > {d} (arena high-water {d} bytes)",
                        .{ @tagName(class), observed, ceiling, high_water },
                    ) catch "cost envelope exceeded";
                    self.recordCostBoundedIncident(detail);
                    return;
                }
            }
        }

        if (ceilings.total) |ceiling| {
            const observed: u64 = self.ctx.cost_meter.total();
            if (observed > ceiling) {
                var detail_buf: [192]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "cost envelope exceeded: total {d} > {d} (arena high-water {d} bytes)",
                    .{ observed, ceiling, high_water },
                ) catch "cost envelope exceeded";
                self.recordCostBoundedIncident(detail);
                return;
            }
        }

        if (ceilings.total_is_constant) {
            const arena = self.arena_state orelse return;
            const stats = arena.getStats();
            if (stats.overflow_count > 0) {
                var detail_buf: [192]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "cost arena overflow under constant envelope: overflow_count {d} (arena high-water {d} bytes)",
                    .{ stats.overflow_count, stats.high_watermark },
                ) catch "cost arena overflow under constant envelope";
                self.recordCostBoundedIncident(detail);
            }
        }
    }

    fn executeHandlerInternal(self: *Self, request: HttpRequestView, request_id: u64, borrow_body: bool) !HttpResponse {
        self.active_request = request;
        defer self.active_request = null;
        var response = try self.executeHandlerFrame(request, request_id, borrow_body);
        errdefer response.deinit();
        return response;
    }

    fn executeHandlerFrame(self: *Self, request: HttpRequestView, request_id: u64, borrow_body: bool) !HttpResponse {
        self.last_request_body_len = if (request.body) |b| b.len else 0;
        if (self.cached_handler_obj == null) {
            try self.refreshHandlerCache();
        }
        const handler_obj = self.cached_handler_obj orelse return error.NoHandler;

        var tracked = false;
        if (builtin.mode == .debug and request_id != 0) {
            const prev = self.active_request_id.swap(request_id, .acq_rel);
            if (prev != 0) {
                std.log.err(
                    "HandlerInstance reused concurrently (prev={d} new={d} runtime=0x{x})",
                    .{ prev, request_id, @intFromPtr(self) },
                );
                return error.RuntimeInUse;
            }
            tracked = true;
        }
        defer if (tracked) self.active_request_id.store(0, .release);
        var reset_after = self.owns_resources;
        defer if (reset_after) self.resetForNextRequest();
        defer self.recordCostFuseIncidents();

        // === TRACE RECORDING: Set up per-request recorder ===
        const trace_timer = trace_request_recorder.setupRequestRecorder(self, request);
        defer trace_request_recorder.finishRequestRecorder(self, trace_timer);

        // === FAST PATH: Native dispatch for static routes ===
        if (self.cached_dispatch) |dispatch| {
            if (self.tryFastPathDispatch(
                dispatch,
                request.url,
                request.path,
                borrow_body,
            )) |response| {
                // Native fast-path dispatch does not execute JS bytecode or allocate
                // request JS objects, so runtime reset is unnecessary on this path.
                reset_after = false;
                return response;
            }
        }

        // Create Request object from HttpRequest
        const request_obj = try self.createRequestObject(request);

        // The handler receives one argument: the Request.
        const args_buf = [1]zq.JSValue{request_obj};
        const args: []const zq.JSValue = args_buf[0..1];

        // === SLOW PATH: Full bytecode execution ===

        // Set the callback for JSX function component rendering.
        zq.http.setCallFunctionCallback(self.ctx, callFunctionWrapper);
        defer zq.http.clearCallFunctionCallback(self.ctx);

        self.ctx.hole_reached = false;
        const result = self.callFunction(handler_obj, args) catch |err| {
            if (err == error.RequestTimeout) return error.RequestTimeout;
            // An unfilled `hole()` is an unfinished program, not a faulting
            // one. Reporting it as 500 would blame the handler for something
            // its author has not written yet.
            if (self.ctx.hole_reached) return error.HandlerNotImplemented;
            if (!builtin.is_test) std.log.err("Handler execution failed: {}", .{err});
            // Preserve the fault class in the error value so the 500 site can
            // map it to the proof chip that guards it (see fault_explain.zig).
            // TypeError/NotCallable are what optional_safe/result_safe guard.
            switch (err) {
                error.TypeError, error.NotCallable => {
                    const diag = fault_explain.diagnose(self.config.handler_proof, .type_fault);
                    if (diag.verdict == .soundness_incident) {
                        self.recordSoundnessIncident(diag.namedChips(), @errorName(err));
                    }
                    // Hand the resolved source line to the server's 500 site, which
                    // builds the body after this runtime is released (same worker
                    // thread, so the threadlocal is a safe read-and-cleared channel).
                    self.last_fault_location = self.interpreter.last_error_location;
                    return error.HandlerTypeFault;
                },
                else => return error.HandlerError,
            }
        };

        // If the bytecode path set an exception but didn't propagate a Zig error
        // (e.g. a conditional opcode rejected its operand and left the stack in
        // an `undefined` state), surface it as a 500 instead of letting
        // extractResponseInternal return an empty default. This guards against
        // the "silent empty 200" class of bug.
        if (self.ctx.hasException()) {
            const exc = self.ctx.exception;
            self.ctx.clearException();
            var err_response = HttpResponse.init(self.allocator);
            err_response.status = 500;
            const exc_msg: []const u8 = if (exc.isString())
                exc.toPtr(zq.JSString).data()
            else
                "handler aborted without returning a Response";
            // Proof-explain the exception: a pending exception that is not a
            // Response is an engine-raised type fault (throw is not in the subset).
            var fault_buf: [256]u8 = undefined;
            const diag = fault_explain.diagnose(self.config.handler_proof, .type_fault);
            const explained = fault_explain.formatMessage(&fault_buf, diag);
            // Append the source line when the trap resolved one (feature A). A
            // JS-thrown exception often has none, so this is best-effort.
            const body_owned = if (self.interpreter.last_error_location) |loc|
                try self.allocator.print("{s} ({s}) at {d}:{d}", .{ explained, exc_msg, loc.line, loc.column })
            else
                try self.allocator.print("{s} ({s})", .{ explained, exc_msg });
            err_response.setBodyOwned(body_owned);
            try err_response.putHeader("Content-Type", "text/plain; charset=utf-8");
            if (diag.verdict == .soundness_incident) {
                self.recordSoundnessIncident(diag.namedChips(), exc_msg);
            }
            trace_request_recorder.recordResponse(self, &err_response);
            return err_response;
        }

        // Convert result to HttpResponse
        const response = try self.extractResponseInternal(result, borrow_body);
        if (borrow_body and response.requires_runtime) {
            reset_after = false;
        }

        trace_request_recorder.recordResponse(self, &response);
        return response;
    }

    /// Try to dispatch request via native fast path.
    /// Returns response if a static pattern matches, null otherwise.
    fn tryFastPathDispatch(
        self: *Self,
        dispatch: *const zq.PatternDispatchTable,
        url: []const u8,
        path: []const u8,
        borrow_body: bool,
    ) ?HttpResponse {
        const effective_path = if (path.len > 0) path else url;

        // O(1) exact match via hash lookup
        if (self.tryFastExactMatch(dispatch, .url, url, borrow_body)) |response| {
            return response;
        }
        if (!std.mem.eql(u8, effective_path, url)) {
            if (self.tryFastExactMatch(dispatch, .path, effective_path, borrow_body)) |response| {
                return response;
            }
        }

        return null; // Fall back to bytecode execution
    }

    fn tryFastExactMatch(
        self: *Self,
        dispatch: *const zq.PatternDispatchTable,
        route_atom: zq.Atom,
        target: []const u8,
        borrow_body: bool,
    ) ?HttpResponse {
        const target_hash = std.hash.Wyhash.hash(0, target);
        const idx = dispatch.exact_match_map.get(target_hash) orelse return null;
        const pattern = &dispatch.patterns[idx];

        // Verify atom + bytes (handle hash collision)
        if (pattern.pattern_type != .exact) return null;
        if (pattern.url_atom != route_atom) return null;
        if (!std.mem.eql(u8, target, pattern.url_bytes)) return null;
        if (pattern.body_source != .static) return null;

        return self.buildFastResponse(pattern, borrow_body) catch null;
    }

    /// Build a response from a pre-serialized static pattern.
    fn buildFastResponse(
        self: *Self,
        pattern: *const zq.HandlerPattern,
        borrow_body: bool,
    ) !HttpResponse {
        var response = HttpResponse.init(self.allocator);
        response.status = pattern.status;

        const content_type = switch (pattern.content_type_idx) {
            0 => "application/json",
            1 => "text/plain; charset=utf-8",
            else => "text/html; charset=utf-8",
        };

        // OPTIMIZATION: Use pre-built raw response if available (single write, no header construction)
        if (pattern.prebuilt_response) |prebuilt| {
            response.prebuilt_raw = prebuilt;
            // Still set body for logging/debugging purposes
            response.body = pattern.static_body;
            response.body_owned = false;
            // Also populate the structured Content-Type header. The slow path
            // (Connection: close, or attestation active) rebuilds headers from
            // response.headers and ignores prebuilt_raw's baked-in Content-Type,
            // so without this such responses would ship with no Content-Type.
            try response.putHeaderBorrowed("Content-Type", content_type);
            return response;
        }

        // Fallback: construct response normally
        if (borrow_body) {
            response.body = pattern.static_body;
            response.body_owned = false;
        } else {
            const body_copy = try self.allocator.dupe(u8, pattern.static_body);
            response.body = body_copy;
            response.body_owned = true;
        }

        try response.putHeaderBorrowed("Content-Type", content_type);

        return response;
    }

    // Retained for embedding callers; the helper implementation has one owner.
    pub const parseQueryInt = natives.parseQueryInt;
    pub const headerKeyToAtom = natives.headerKeyToAtom;

    /// pub for the request-object tests in zruntime_tests.zig.
    pub fn createRequestObject(self: *Self, request: HttpRequestView) !zq.JSValue {
        // Use pre-shaped request object for faster creation (direct slot access).
        // http_shapes is initialized by default (use_http_shape_cache = true).
        // If not available, fall back to dynamic object creation.
        const shapes = self.ctx.http.shapes orelse return self.createRequestObjectDynamic(request);

        const req_obj = try self.ctx.createObjectWithClass(shapes.request.class_idx, self.http_state.request_prototype);

        // URL
        const url_str = try self.ctx.createString(request.url);
        req_obj.setSlot(shapes.request.url_slot, url_str);

        // Method - use cached string if available
        const method_val: zq.JSValue = if (self.ctx.getCachedMethod(request.method)) |cached|
            zq.JSValue.fromPtr(cached)
        else
            try self.ctx.createString(request.method);
        req_obj.setSlot(shapes.request.method_slot, method_val);

        // Path - URL without query string
        const path_slice = if (request.path.len > 0) request.path else request.url;
        const path_val: zq.JSValue = if (std.mem.eql(u8, path_slice, request.url))
            url_str
        else
            try self.ctx.createString(path_slice);
        req_obj.setSlot(shapes.request.path_slot, path_val);

        // Query - create object from parsed query parameters
        const query_obj = try buildQueryObject(self.ctx, request.query_params);
        req_obj.setSlot(shapes.request.query_slot, query_obj.toValue());

        // Body
        if (request.body) |body| {
            const body_str = try self.ctx.createString(body);
            req_obj.setSlot(shapes.request.body_slot, body_str);
        } else {
            req_obj.setSlot(shapes.request.body_slot, zq.JSValue.undefined_val);
        }

        // Copy request headers into the handler request object.
        const headers_obj = try self.ctx.createObjectWithClass(shapes.request_headers.class_idx, self.http_state.headers_prototype);
        for (request.headers.items) |header| {
            const key_atom = headerKeyToAtom(header.key) orelse
                try self.ctx.atoms.intern(header.key);
            const value_str = try self.ctx.createString(header.value);
            switch (key_atom) {
                .authorization => headers_obj.setSlot(shapes.request_headers.authorization_slot, value_str),
                .@"content-type" => headers_obj.setSlot(shapes.request_headers.content_type_slot, value_str),
                .accept => headers_obj.setSlot(shapes.request_headers.accept_slot, value_str),
                .host => headers_obj.setSlot(shapes.request_headers.host_slot, value_str),
                .@"user-agent" => headers_obj.setSlot(shapes.request_headers.user_agent_slot, value_str),
                .@"accept-encoding" => headers_obj.setSlot(shapes.request_headers.accept_encoding_slot, value_str),
                .connection => headers_obj.setSlot(shapes.request_headers.connection_slot, value_str),
                else => try self.ctx.setPropertyChecked(headers_obj, key_atom, value_str),
            }
        }
        req_obj.setSlot(shapes.request.headers_slot, headers_obj.toValue());

        return req_obj.toValue();
    }

    /// Fallback for creating request objects when http_shapes is not available.
    /// This is slower than the shaped path but handles edge cases.
    fn createRequestObjectDynamic(self: *Self, request: HttpRequestView) !zq.JSValue {
        const req_obj = try self.ctx.createObject(self.http_state.request_prototype);

        const url_str = try self.ctx.createString(request.url);
        try self.ctx.setPropertyChecked(req_obj, zq.Atom.url, url_str);

        const method_val: zq.JSValue = if (self.ctx.getCachedMethod(request.method)) |cached|
            zq.JSValue.fromPtr(cached)
        else
            try self.ctx.createString(request.method);
        try self.ctx.setPropertyChecked(req_obj, zq.Atom.method, method_val);

        const path_slice = if (request.path.len > 0) request.path else request.url;
        const path_val: zq.JSValue = if (std.mem.eql(u8, path_slice, request.url))
            url_str
        else
            try self.ctx.createString(path_slice);
        try self.ctx.setPropertyChecked(req_obj, zq.Atom.path, path_val);

        const query_obj = try buildQueryObject(self.ctx, request.query_params);
        try self.ctx.setPropertyChecked(req_obj, zq.Atom.query, query_obj.toValue());

        if (request.body) |body| {
            const body_str = try self.ctx.createString(body);
            try self.ctx.setPropertyChecked(req_obj, zq.Atom.body, body_str);
        }

        const headers_obj = try self.ctx.createObject(self.http_state.headers_prototype);
        for (request.headers.items) |header| {
            const key_atom = headerKeyToAtom(header.key) orelse
                try self.ctx.atoms.intern(header.key);
            const value_str = try self.ctx.createString(header.value);
            try self.ctx.setPropertyChecked(headers_obj, key_atom, value_str);
        }
        try self.ctx.setPropertyChecked(req_obj, zq.Atom.headers, headers_obj.toValue());

        return req_obj.toValue();
    }

    pub fn createString(self: *Self, str: []const u8) !zq.JSValue {
        return self.ctx.createString(str);
    }

    pub fn callFunction(self: *Self, func_obj: *zq.JSObject, args: []const zq.JSValue) !zq.JSValue {
        if (func_obj.getClosureData()) |closure_data| {
            const prev_closure = self.interpreter.current_closure;
            self.interpreter.current_closure = closure_data;
            defer self.interpreter.current_closure = prev_closure;

            return try self.interpreter.callBytecodeFunction(
                func_obj.toValue(),
                closure_data.bytecode,
                zq.JSValue.undefined_val,
                args,
            );
        }

        if (func_obj.getBytecodeFunctionData()) |bc_data| {
            return try self.interpreter.callBytecodeFunction(
                func_obj.toValue(),
                bc_data.bytecode,
                zq.JSValue.undefined_val,
                args,
            );
        }

        const native_data = func_obj.getNativeFunctionData() orelse return error.NotCallable;
        return native_data.func(self.ctx, zq.JSValue.undefined_val, args);
    }

    /// Wrapper for calling JS functions from http.zig (used for JSX function
    /// components and the array higher-order functions). The Context carries the
    /// callback, so the runtime comes from the Context the engine passes back
    /// rather than from thread-local state - which is what makes a nested
    /// sub-handler dispatch safe.
    fn callFunctionWrapper(ctx: *zq.Context, func_obj: *zq.JSObject, args: []const zq.JSValue) anyerror!zq.JSValue {
        const runtime = Self.fromContext(ctx) orelse return error.NoRuntime;
        return runtime.callFunction(func_obj, args);
    }

    /// Set a response body from any JS string value. A genuine flat JSString can
    /// be borrowed (pinned via its pointer); a slice is flattened (into the
    /// request arena) and copied, since there is no JSString handle to borrow.
    fn setResponseBody(self: *Self, response: *HttpResponse, val: zq.JSValue, borrow_body: bool) !void {
        if (val.isString()) {
            const str = val.toPtr(zq.JSString);
            if (borrow_body) {
                response.setBodyBorrowed(str.data(), @ptrCast(str));
            } else {
                response.setBodyOwned(try self.allocator.dupe(u8, str.data()));
            }
        } else if (getStringDataCtx(val, self.ctx)) |bytes| {
            response.setBodyOwned(try self.allocator.dupe(u8, bytes));
        }
    }

    /// Put a response header whose value is any JS string. Flat strings keep the
    /// borrow fast path; slice values are flattened and copied.
    fn putResponseHeader(self: *Self, response: *HttpResponse, name: []const u8, val: zq.JSValue, borrow_body: bool) !void {
        if (val.isString()) {
            const str = val.toPtr(zq.JSString);
            if (borrow_body) {
                try response.putHeaderBorrowedRuntime(name, str.data());
            } else {
                try response.putHeader(name, str.data());
            }
        } else if (getStringDataCtx(val, self.ctx)) |bytes| {
            try response.putHeader(name, bytes);
        }
    }

    pub fn extractResponseInternal(self: *Self, result: zq.JSValue, borrow_body: bool) !HttpResponse {
        var response = HttpResponse.init(self.allocator);

        if (!result.isObject()) {
            // If result is any string (flat or slice), use it as
            // the body (supported return type). getStringDataCtx is non-null for
            // every string kind and null for primitives, which fall through to 500.
            if (getStringDataCtx(result, self.ctx) != null) {
                try self.setResponseBody(&response, result, borrow_body);
                return response;
            }
            // Non-string, non-object: handler returned a primitive (number, bool, undefined).
            // Return 500 instead of a silent empty 200, proof-explained against
            // exhaustive_returns (the chip that proves every path returns a Response).
            response.status = 500;
            var fault_buf: [256]u8 = undefined;
            const diag = fault_explain.diagnose(self.config.handler_proof, .non_response_return);
            const body_owned = try self.allocator.dupe(u8, fault_explain.formatMessage(&fault_buf, diag));
            response.setBodyOwned(body_owned);
            try response.putHeader("Content-Type", "text/plain; charset=utf-8");
            return response;
        }

        const result_obj = result.toPtr(zq.JSObject);
        const pool = self.ctx.hidden_class_pool orelse return response;

        // Fast path: use direct slot access if response matches pre-shaped class
        if (self.ctx.http.shapes) |shapes| {
            if (result_obj.hidden_class_idx == shapes.response.class_idx) {
                // Status - direct slot access with bounds validation
                const status_val = result_obj.getSlot(shapes.response.status_slot);
                if (status_val.isInt()) {
                    const raw = status_val.getInt();
                    response.status = if (raw < 100 or raw > 599) 500 else @intCast(raw);
                }

                // Body - direct slot access
                const body_val = result_obj.getSlot(shapes.response.body_slot);
                try self.setResponseBody(&response, body_val, borrow_body);

                // Headers - still need property iteration for custom headers
                const headers_val = result_obj.getSlot(shapes.response.headers_slot);
                if (headers_val.isObject()) {
                    const headers_obj = headers_val.toPtr(zq.JSObject);
                    if (headers_obj.hidden_class_idx == shapes.response_headers.class_idx) {
                        try self.putResponseHeader(&response, "Content-Type", headers_obj.getSlot(shapes.response_headers.content_type_slot), borrow_body);
                        try self.putResponseHeader(&response, "Content-Length", headers_obj.getSlot(shapes.response_headers.content_length_slot), borrow_body);
                        try self.putResponseHeader(&response, "Cache-Control", headers_obj.getSlot(shapes.response_headers.cache_control_slot), borrow_body);
                    } else {
                        const keys = try headers_obj.getOwnEnumerableKeys(self.allocator, pool);
                        defer self.allocator.free(keys);
                        for (keys) |key_atom| {
                            const key_name = self.ctx.atoms.getName(key_atom) orelse continue;
                            const header_val = headers_obj.getOwnProperty(pool, key_atom) orelse continue;
                            try self.putResponseHeader(&response, key_name, header_val, borrow_body);
                        }
                    }
                }

                return response;
            }
        }

        // Fallback: property-based extraction for non-standard response objects
        if (result_obj.getOwnProperty(pool, zq.Atom.status)) |status_val| {
            if (status_val.isInt()) {
                const raw = status_val.getInt();
                response.status = if (raw < 100 or raw > 599) 500 else @intCast(raw);
            }
        }

        if (result_obj.getOwnProperty(pool, zq.Atom.body)) |body_val| {
            try self.setResponseBody(&response, body_val, borrow_body);
        }

        if (result_obj.getOwnProperty(pool, zq.Atom.headers)) |headers_val| {
            if (headers_val.isObject()) {
                const headers_obj = headers_val.toPtr(zq.JSObject);
                const keys = try headers_obj.getOwnEnumerableKeys(self.allocator, pool);
                defer self.allocator.free(keys);
                for (keys) |key_atom| {
                    const key_name = self.ctx.atoms.getName(key_atom) orelse continue;
                    const header_val = headers_obj.getOwnProperty(pool, key_atom) orelse continue;
                    try self.putResponseHeader(&response, key_name, header_val, borrow_body);
                }
            }
        }

        return response;
    }

    /// Reset runtime for next request (isolation)
    pub fn resetForNextRequest(self: *Self) void {
        self.ctx.sp = 0;
        self.ctx.call_depth = 0;
        self.ctx.clearException();
        self.ctx.cost_meter.reset();
        self.http_state.reset();

        // Reset ephemeral allocations when hybrid allocation is enabled
        if (self.hybrid_state) |h| {
            h.resetEphemeral();
        } else {
            // Trigger minor GC if nursery is half full
            const used = self.gc_state.nursery.used();
            const base_threshold = self.gc_state.config.nursery_size / 2;
            const body_threshold = self.gc_state.config.nursery_size / 4;
            const threshold = if (self.last_request_body_len >= base_threshold) body_threshold else base_threshold;
            if (used > threshold) {
                self.gc_state.minorGC();
            }
            // Interleave major-GC sweep work between requests to reduce pause spikes.
            self.gc_state.runIncrementalGCStep(self.gc_state.config.sweep_chunk_size);
        }
        self.last_request_body_len = 0;

        // Note: We do NOT clear user globals here. The handler code and all its
        // dependencies (functions, constants, component definitions) are loaded
        // once per runtime and must persist across requests. Request isolation
        // is achieved through the handler pool (each request gets a pooled runtime)
        // and stack/exception clearing above.
    }

    pub fn prepareForPoolRelease(self: *Self) void {
        // Clear zruntime-layer request state that pool.zig's HandlerInstance.reset()
        // does not know about. The engine-level sp/call_depth/exception clear
        // happens inside pool.release() -> HandlerInstance.reset().
        self.http_state.reset();
        self.last_request_body_len = 0;
    }
};

/// Render parse errors for a person: the ZTS code, `file:line:column`, the
/// source line, and an underline, translated into the file the author wrote.
/// Caller owns the result.
fn renderParseErrors(
    allocator: std.mem.Allocator,
    view: zq.SourceView,
    errors: []const zq.ParseError,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try zq.DiagnosticProjection.writeParseErrors(view, errors, &aw.writer);
    return aw.toOwnedSlice();
}

/// Log the rendered parse errors. A rendering failure falls back to the
/// position and message, so a parse failure is never logged as nothing.
fn logParseErrors(allocator: std.mem.Allocator, view: zq.SourceView, errors: []const zq.ParseError) void {
    if (renderParseErrors(allocator, view, errors)) |text| {
        defer allocator.free(text);
        if (!builtin.is_test) std.log.err("parse error\n{s}", .{text});
    } else |_| {
        for (errors) |parse_error| {
            if (!builtin.is_test) std.log.err("Parse error at {s}:{d}:{d}: {s}", .{
                view.name orelse "<source>",
                parse_error.location.line,
                parse_error.location.column,
                parse_error.message,
            });
        }
    }
}

test "a load parse failure renders its code, file, source line, and underline" {
    const allocator = std.testing.allocator;
    const source = "const a = 1;\nconst b = while;\n";
    var frontend: zq.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "bad.ts");
    defer frontend.deinit();
    switch (frontend.parse_outcome) {
        .parser_refused => {},
        else => return error.TestExpectedParseFailure,
    }

    const text = try renderParseErrors(allocator, frontend.sourceView(), frontend.parserErrors());
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "error[ZTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  --> bad.ts:2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2 | const b = while;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "^") != null);
}
