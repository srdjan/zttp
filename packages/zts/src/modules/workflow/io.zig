//! zttp:io - Structured Concurrent I/O
//!
//! Provides concurrent effect execution without async/await or Promises.
//! Handler code remains synchronous and linear; concurrency is purely in
//! the I/O layer.
//!
//! Exports:
//!   parallel(thunks: Array<() => T>) -> Array<T>
//!     Execute an array of zero-arg functions concurrently.
//!     All I/O effects (fetchSync calls) within the thunks are overlapped.
//!     Results are returned in declaration order regardless of completion order.
//!
//!   race(thunks: Array<() => T>) -> T
//!     Execute an array of zero-arg functions concurrently.
//!     All I/O effects run and are waited on; returns the first successful
//!     result in declaration order, NOT by latency: every thunk's threads are
//!     joined before results are scanned, so "first" means first in the
//!     caller's array, not first-to-finish on the wall clock. A genuinely
//!     lowest-latency winner would need per-thunk completion signaling
//!     instead of join-all-then-scan, and is deferred - see the
//!     workflow/fault-tolerance gaps plan (Scope Boundaries).

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const object = @import("../../object.zig");
const resolver = @import("../internal/resolver.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");
const parallel_collection = @import("../../parallel_collection.zig");

/// Maximum number of concurrent operations in a single parallel/race call.
/// This bounds actual concurrent OS threads/fetches, unlike
/// `zttp:workflow`'s `MAX_PARALLEL_CALLS` (runtime_workflow.zig), which
/// bounds a sequential dispatch loop's array size - the two are not required
/// to match.
pub const MAX_PARALLEL: u32 = 8;

pub const MODULE_STATE_SLOT = @intFromEnum(@import("../../module_slots.zig").Slot.io);

pub const binding = mb.ModuleBinding{
    .specifier = "zttp:io",
    .name = "io",
    .required_capabilities = &.{.runtime_callback},
    .stateful = true,
    .exports = &.{
        // parallel always returns a JS array (never undefined) -> .object.
        // race can return undefined on a no-winner / response-build-failure path
        // (see raceNative), so it is .optional_object: callers must narrow before
        // use, never .object. io.json must mirror both (ZVM009).
        // `.required_arg_count = 0`: calling either with no arguments is valid
        // (parallel() yields an empty array, race() yields undefined), so the
        // declared parameter must not make the argument mandatory.
        .{ .name = "parallel", .func = parallelNative, .arg_count = 1, .required_arg_count = 0, .effect = .write, .returns = .object, .param_types = &.{.object}, .return_labels = .{ .external = true } },
        .{ .name = "race", .func = raceNative, .arg_count = 1, .required_arg_count = 0, .effect = .write, .returns = .optional_object, .param_types = &.{.object}, .return_labels = .{ .external = true } },
    },
};

pub const exports = binding.toModuleExports();

// ============================================================================
// Runtime callback interface
// ============================================================================

/// Opaque callbacks provided by the runtime layer (src/zruntime.zig).
/// Stored in Context.module_state[MODULE_STATE_SLOT].
/// The runtime sets these during initialization when outbound HTTP is enabled.
pub const IoCallbacks = struct {
    /// Call a zero-arg JS function via the interpreter and return its result.
    call_thunk_fn: *const fn (*anyopaque, value.JSValue) anyerror!value.JSValue,

    /// Execute HTTP fetches concurrently. Takes descriptors, fills results.
    execute_fetches_fn: *const fn (*anyopaque, []const FetchDescriptor, []FetchResult) void,

    /// Build a JS Response object from a FetchResult.
    build_response_fn: *const fn (*anyopaque, *const FetchResult) anyerror!value.JSValue,

    /// Opaque pointer to the runtime (passed as first arg to above fns).
    runtime_ptr: *anyopaque,

    pub fn deinitOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *IoCallbacks = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

pub const FetchDescriptor = parallel_collection.FetchDescriptor;

/// Result of an HTTP fetch executed by a worker thread.
pub const FetchResult = struct {
    status: u16 = 0,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    response_headers: std.ArrayList(ResponseHeader) = .empty,
    ok: bool = false,
    error_code: ?[]const u8 = null,
    error_details: ?[]const u8 = null,

    pub const ResponseHeader = struct {
        name: []const u8,
        value_str: []const u8,
    };

    pub fn deinit(self: *FetchResult, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        if (self.content_type) |ct| allocator.free(ct);
        if (self.reason) |r| allocator.free(r);
        for (self.response_headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value_str);
        }
        self.response_headers.deinit(allocator);
        if (self.error_code) |ec| allocator.free(ec);
        if (self.error_details) |ed| allocator.free(ed);
    }
};

// ============================================================================
// Parallel collection state (set by parallel/race, read by fetchSync)
// ============================================================================

pub const ParallelCollector = parallel_collection.ParallelCollector;

// ============================================================================
// parallel()
// ============================================================================

fn parallelNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);

    if (args.len == 0) {
        return (try ctx.createArray()).toValue();
    }

    // Validate: first arg must be an array
    if (!args[0].isObject()) {
        return util.throwError(ctx, "TypeError", "parallel() expects an array of functions");
    }
    const arr = args[0].toPtr(object.JSObject);
    if (arr.class_id != .array) {
        return util.throwError(ctx, "TypeError", "parallel() expects an array of functions");
    }

    const count = arr.getArrayLength();
    if (count == 0) {
        return (try ctx.createArray()).toValue();
    }
    if (count > MAX_PARALLEL) {
        return util.throwError(ctx, "RangeError", "parallel() supports at most 8 concurrent operations");
    }

    // Get runtime callbacks from module state after handling no-op cases.
    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "parallel() requires outbound HTTP to be enabled");
    };

    // Phase 1: Execute each thunk to collect fetch descriptors.
    // fetchSync calls during thunk execution are intercepted and recorded
    // instead of blocking on HTTP I/O.
    var descriptor_buf: [MAX_PARALLEL]FetchDescriptor = undefined;
    for (0..MAX_PARALLEL) |i| {
        descriptor_buf[i] = .{
            .url = &.{},
            .method = .GET,
            .body = null,
            .headers = .empty,
            .max_response_bytes = 1024 * 1024,
        };
    }

    var collector = ParallelCollector{
        .descriptors = &descriptor_buf,
        .count = 0,
        .allocator = ctx.allocator,
        .capacity = @intCast(count),
    };

    // Install the collector on this Context. The scope restores its parent on
    // every exit and supports nested parallel/race calls without sharing state
    // with another Context on the same worker thread.
    const collector_scope = ctx.parallel_collection.enter(&collector);
    var collection_done = false;
    defer {
        collector_scope.restore();
        if (!collection_done) freeDescriptors(&descriptor_buf, collector.count, ctx.allocator);
    }

    // Execute each thunk (fetchSync records URL instead of blocking),
    // tracking which descriptor belongs to which position. The contract is
    // positional ("results are returned in declaration order"), so thunk i
    // must produce result i: a thunk with no fetch yields undefined at its
    // position, and a thrown thunk aborts the whole call - the language
    // subset has no try/catch, so swallowing the error here would silently
    // shift every later result one position left.
    var desc_for_thunk: [MAX_PARALLEL]?u32 = @splat(null);
    for (0..count) |i| {
        const before = collector.count;
        const thunk = arr.getIndex(@intCast(i)) orelse value.JSValue.undefined_val;
        if (!thunk.isObject()) {
            return util.throwError(ctx, "TypeError", "parallel() expects an array of functions");
        }
        _ = try callbacks.call_thunk_fn(callbacks.runtime_ptr, thunk);
        if (collector.count > before) {
            // A thunk's value is its last fetch (earlier ones are effects).
            desc_for_thunk[i] = collector.count - 1;
        }
    }
    collection_done = true;

    const desc_count = collector.count;

    // Phase 2: Execute all collected HTTP fetches concurrently
    var results: [MAX_PARALLEL]FetchResult = undefined;
    for (0..MAX_PARALLEL) |i| {
        results[i] = .{};
    }

    // Free every executed fetch result and descriptor on any exit path. Phase 3's
    // `try` (createArray / arrayPush) can OOM after collection_done disarmed the
    // defer's descriptor free, which would otherwise leak all bodies + descriptors.
    var cleaned = false;
    errdefer if (!cleaned) {
        for (0..desc_count) |i| {
            results[i].deinit(ctx.allocator);
            descriptor_buf[i].deinit(ctx.allocator);
        }
    };

    if (desc_count > 0) {
        callbacks.execute_fetches_fn(
            callbacks.runtime_ptr,
            descriptor_buf[0..desc_count],
            results[0..desc_count],
        );
    }

    // Phase 3: Build one result per thunk position
    const result_arr = try ctx.createArray();
    for (0..count) |i| {
        const resp_val = if (desc_for_thunk[i]) |desc_idx|
            callbacks.build_response_fn(callbacks.runtime_ptr, &results[desc_idx]) catch value.JSValue.undefined_val
        else
            value.JSValue.undefined_val;
        try result_arr.arrayPush(ctx.allocator, resp_val);
    }

    for (0..desc_count) |i| {
        results[i].deinit(ctx.allocator);
        descriptor_buf[i].deinit(ctx.allocator);
    }
    cleaned = true;

    return result_arr.toValue();
}

fn freeDescriptors(buf: []FetchDescriptor, n: u32, allocator: std.mem.Allocator) void {
    for (0..n) |i| {
        buf[i].deinit(allocator);
    }
}

// ============================================================================
// race()
// ============================================================================

fn raceNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);

    if (args.len == 0) {
        return value.JSValue.undefined_val;
    }

    if (!args[0].isObject()) {
        return util.throwError(ctx, "TypeError", "race() expects an array of functions");
    }
    const arr = args[0].toPtr(object.JSObject);
    if (arr.class_id != .array) {
        return util.throwError(ctx, "TypeError", "race() expects an array of functions");
    }

    const count = arr.getArrayLength();
    if (count == 0) {
        return value.JSValue.undefined_val;
    }
    if (count > MAX_PARALLEL) {
        return util.throwError(ctx, "RangeError", "race() supports at most 8 concurrent operations");
    }

    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "race() requires outbound HTTP to be enabled");
    };

    // Phase 1: Collect fetch descriptors (same as parallel)
    var descriptor_buf: [MAX_PARALLEL]FetchDescriptor = undefined;
    for (0..MAX_PARALLEL) |i| {
        descriptor_buf[i] = .{
            .url = &.{},
            .method = .GET,
            .body = null,
            .headers = .empty,
            .max_response_bytes = 1024 * 1024,
        };
    }

    var collector = ParallelCollector{
        .descriptors = &descriptor_buf,
        .count = 0,
        .allocator = ctx.allocator,
        .capacity = @intCast(count),
    };

    const collector_scope = ctx.parallel_collection.enter(&collector);
    var collection_done = false;
    defer {
        collector_scope.restore();
        if (!collection_done) freeDescriptors(&descriptor_buf, collector.count, ctx.allocator);
    }

    var desc_for_thunk: [MAX_PARALLEL]?u32 = @splat(null);
    for (0..count) |i| {
        const before = collector.count;
        const thunk = arr.getIndex(@intCast(i)) orelse value.JSValue.undefined_val;
        if (!thunk.isObject()) {
            return util.throwError(ctx, "TypeError", "race() expects an array of functions");
        }
        _ = try callbacks.call_thunk_fn(callbacks.runtime_ptr, thunk);
        if (collector.count > before) {
            // Match parallel(): earlier fetches are effects; the last is the value.
            desc_for_thunk[i] = collector.count - 1;
        }
    }
    collection_done = true;

    const desc_count = collector.count;
    if (desc_count == 0) {
        return value.JSValue.undefined_val;
    }

    // Phase 2: Execute all fetches concurrently (same as parallel)
    var results: [MAX_PARALLEL]FetchResult = undefined;
    for (0..MAX_PARALLEL) |i| {
        results[i] = .{};
    }

    callbacks.execute_fetches_fn(
        callbacks.runtime_ptr,
        descriptor_buf[0..desc_count],
        results[0..desc_count],
    );

    // Phase 3: Pick the first successful thunk in declaration order.
    // All threads have already joined in execute_fetches_fn, so "first"
    // means first in the caller's array, not first by wall-clock time.
    var first_thunk_idx: ?usize = null;
    var winner_thunk_idx: ?usize = null;
    for (0..count) |i| {
        const desc_idx = desc_for_thunk[i] orelse continue;
        if (first_thunk_idx == null) first_thunk_idx = i;
        if (results[desc_idx].ok) {
            winner_thunk_idx = i;
            break;
        }
    }

    // If no thunk succeeded, return the first thunk's final error response.
    const thunk_idx = winner_thunk_idx orelse first_thunk_idx orelse unreachable;
    const idx = desc_for_thunk[thunk_idx] orelse unreachable;
    const resp_val = callbacks.build_response_fn(callbacks.runtime_ptr, &results[idx]) catch value.JSValue.undefined_val;

    // Clean up all results and descriptors
    for (0..desc_count) |i| {
        results[i].deinit(ctx.allocator);
        descriptor_buf[i].deinit(ctx.allocator);
    }

    return resp_val;
}

// ============================================================================
// Helpers
// ============================================================================

fn getCallbacks(ctx: *context.Context) error{CapabilityViolation}!?*IoCallbacks {
    return mb.getRuntimeCallbackStateChecked(ctx, IoCallbacks, MODULE_STATE_SLOT);
}

// ============================================================================
// Tests
// ============================================================================

test "parallel collection state belongs to Context" {
    try std.testing.expect(@hasField(context.Context, "parallel_collection"));
}

test "parallel collectors stay isolated across alternating Contexts" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    var setup_a_complete = false;
    const gc_a = try allocator.create(gc_mod.GC);
    errdefer if (!setup_a_complete) allocator.destroy(gc_a);
    gc_a.* = try gc_mod.GC.init(allocator, .{});
    errdefer if (!setup_a_complete) gc_a.deinit();
    const heap_a = try allocator.create(heap_mod.Heap);
    errdefer if (!setup_a_complete) allocator.destroy(heap_a);
    heap_a.* = heap_mod.Heap.init(allocator, .{});
    errdefer if (!setup_a_complete) heap_a.deinit();
    gc_a.setHeap(heap_a);
    const ctx_a = try context.Context.init(allocator, gc_a, .{});
    errdefer if (!setup_a_complete) ctx_a.deinit();
    defer {
        ctx_a.deinit();
        heap_a.deinit();
        gc_a.deinit();
        allocator.destroy(heap_a);
        allocator.destroy(gc_a);
    }
    setup_a_complete = true;

    var setup_b_complete = false;
    const gc_b = try allocator.create(gc_mod.GC);
    errdefer if (!setup_b_complete) allocator.destroy(gc_b);
    gc_b.* = try gc_mod.GC.init(allocator, .{});
    errdefer if (!setup_b_complete) gc_b.deinit();
    const heap_b = try allocator.create(heap_mod.Heap);
    errdefer if (!setup_b_complete) allocator.destroy(heap_b);
    heap_b.* = heap_mod.Heap.init(allocator, .{});
    errdefer if (!setup_b_complete) heap_b.deinit();
    gc_b.setHeap(heap_b);
    const ctx_b = try context.Context.init(allocator, gc_b, .{});
    errdefer if (!setup_b_complete) ctx_b.deinit();
    defer {
        ctx_b.deinit();
        heap_b.deinit();
        gc_b.deinit();
        allocator.destroy(heap_b);
        allocator.destroy(gc_b);
    }
    setup_b_complete = true;

    var descriptors_a: [1]FetchDescriptor = undefined;
    var descriptors_b: [1]FetchDescriptor = undefined;
    var collector_a = ParallelCollector{
        .descriptors = &descriptors_a,
        .count = 0,
        .allocator = allocator,
        .capacity = 1,
    };
    var collector_b = ParallelCollector{
        .descriptors = &descriptors_b,
        .count = 0,
        .allocator = allocator,
        .capacity = 1,
    };

    const scope_a = ctx_a.parallel_collection.enter(&collector_a);
    try std.testing.expect(ctx_a.parallel_collection.active == &collector_a);
    try std.testing.expect(ctx_b.parallel_collection.active == null);

    const scope_b = ctx_b.parallel_collection.enter(&collector_b);
    try std.testing.expect(ctx_a.parallel_collection.active == &collector_a);
    try std.testing.expect(ctx_b.parallel_collection.active == &collector_b);

    scope_b.restore();
    try std.testing.expect(ctx_a.parallel_collection.active == &collector_a);
    try std.testing.expect(ctx_b.parallel_collection.active == null);

    scope_a.restore();
    try std.testing.expect(ctx_a.parallel_collection.active == null);
}

test "parallel: empty array returns empty array" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }

    const result = try parallelNative(ctx, value.JSValue.undefined_val, &.{});
    defer result.toPtr(object.JSObject).destroy(allocator);

    try std.testing.expect(result.isObject());
    try std.testing.expectEqual(object.ClassId.array, result.toPtr(object.JSObject).class_id);
    try std.testing.expectEqual(@as(u32, 0), result.toPtr(object.JSObject).getArrayLength());
}

test "MAX_PARALLEL is within MODULE_STATE_SLOTS" {
    try std.testing.expect(MODULE_STATE_SLOT < 8); // MAX_MODULE_STATE_SLOTS
}

test "FetchDescriptor init and deinit" {
    const allocator = std.testing.allocator;
    var desc = FetchDescriptor{
        .url = try allocator.dupe(u8, "https://example.com"),
        .method = .GET,
        .body = null,
        .headers = .empty,
        .max_response_bytes = 1024,
    };
    desc.deinit(allocator);
}

test "FetchResult init and deinit" {
    const allocator = std.testing.allocator;
    var result = FetchResult{
        .status = 200,
        .body = try allocator.dupe(u8, "hello"),
        .content_type = try allocator.dupe(u8, "text/plain"),
        .reason = try allocator.dupe(u8, "OK"),
        .ok = true,
    };
    result.deinit(allocator);
}

test "getCallbacks returns installed runtime callback state under capability context" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }

    const callbacks = try allocator.create(IoCallbacks);
    callbacks.* = .{
        .call_thunk_fn = struct {
            fn call(_: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
                return value.JSValue.undefined_val;
            }
        }.call,
        .execute_fetches_fn = struct {
            fn exec(_: *anyopaque, _: []const FetchDescriptor, _: []FetchResult) void {}
        }.exec,
        .build_response_fn = struct {
            fn build(_: *anyopaque, _: *const FetchResult) anyerror!value.JSValue {
                return value.JSValue.undefined_val;
            }
        }.build,
        .runtime_ptr = @ptrFromInt(0x1),
    };
    ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);

    try std.testing.expect(try getCallbacks(ctx) != null);
}

test "parallel: results stay aligned to thunk positions" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }

    // Thunk 0 and thunk 2 each record one fetch; thunk 1 records none.
    // The old per-descriptor result array came back [resp, resp] and shifted
    // thunk 2's response into position 1.
    const Stubs = struct {
        var calls: u32 = 0;
        fn callThunk(ctx_ptr: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
            const i = calls;
            calls += 1;
            if (i != 1) {
                const current_ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
                const col = current_ctx.parallel_collection.active.?;
                col.descriptors[col.count] = .{
                    .url = try col.allocator.dupe(u8, "https://x"),
                    .method = .GET,
                    .body = null,
                    .headers = .empty,
                    .max_response_bytes = 1024,
                };
                col.count += 1;
            }
            return value.JSValue.undefined_val;
        }
        fn exec(_: *anyopaque, _: []const FetchDescriptor, results: []FetchResult) void {
            for (results) |*r| r.ok = true;
        }
        fn build(_: *anyopaque, _: *const FetchResult) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    };
    Stubs.calls = 0;

    const callbacks = try allocator.create(IoCallbacks);
    callbacks.* = .{
        .call_thunk_fn = Stubs.callThunk,
        .execute_fetches_fn = Stubs.exec,
        .build_response_fn = Stubs.build,
        .runtime_ptr = ctx,
    };
    ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);

    const arr = try ctx.createArray();
    defer arr.destroy(allocator);
    var thunks: [3]*object.JSObject = undefined;
    for (0..3) |i| {
        thunks[i] = try ctx.createObject(ctx.object_prototype);
        try arr.arrayPush(ctx.allocator, thunks[i].toValue());
    }
    defer for (thunks) |t| t.destroy(allocator);

    const result = try parallelNative(ctx, value.JSValue.undefined_val, &.{arr.toValue()});
    const result_obj = result.toPtr(object.JSObject);
    defer result_obj.destroy(allocator);

    try std.testing.expectEqual(@as(u32, 3), result_obj.getArrayLength());
    try std.testing.expect(result_obj.getIndex(0).?.isBool());
    const middle = result_obj.getIndex(1);
    try std.testing.expect(middle == null or middle.?.isUndefined());
    try std.testing.expect(result_obj.getIndex(2).?.isBool());
}

test "parallel: a thrown thunk propagates instead of being swallowed" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }

    const Stubs = struct {
        var calls: u32 = 0;
        fn callThunk(ctx_ptr: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
            const i = calls;
            calls += 1;
            if (i == 0) {
                // First thunk records a fetch whose descriptor must be freed
                // on the abort path (the leak check enforces it).
                const current_ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
                const col = current_ctx.parallel_collection.active.?;
                col.descriptors[col.count] = .{
                    .url = try col.allocator.dupe(u8, "https://x"),
                    .method = .GET,
                    .body = null,
                    .headers = .empty,
                    .max_response_bytes = 1024,
                };
                col.count += 1;
                return value.JSValue.undefined_val;
            }
            return error.ThunkFailed;
        }
        fn exec(_: *anyopaque, _: []const FetchDescriptor, _: []FetchResult) void {}
        fn build(_: *anyopaque, _: *const FetchResult) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    };
    Stubs.calls = 0;

    const callbacks = try allocator.create(IoCallbacks);
    callbacks.* = .{
        .call_thunk_fn = Stubs.callThunk,
        .execute_fetches_fn = Stubs.exec,
        .build_response_fn = Stubs.build,
        .runtime_ptr = ctx,
    };
    ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);

    const arr = try ctx.createArray();
    defer arr.destroy(allocator);
    var thunks: [2]*object.JSObject = undefined;
    for (0..2) |i| {
        thunks[i] = try ctx.createObject(ctx.object_prototype);
        try arr.arrayPush(ctx.allocator, thunks[i].toValue());
    }
    defer for (thunks) |t| t.destroy(allocator);

    var outer_descriptors: [1]FetchDescriptor = undefined;
    var outer_collector = ParallelCollector{
        .descriptors = &outer_descriptors,
        .count = 0,
        .allocator = allocator,
        .capacity = 1,
    };
    const outer_scope = ctx.parallel_collection.enter(&outer_collector);
    defer outer_scope.restore();

    try std.testing.expectError(
        error.ThunkFailed,
        parallelNative(ctx, value.JSValue.undefined_val, &.{arr.toValue()}),
    );
    try std.testing.expect(ctx.parallel_collection.active == &outer_collector);
}

test "nested structured I/O operations restore parent collectors" {
    const Harness = struct {
        const Operation = enum {
            parallel,
            race,
        };

        ctx: *context.Context,
        inner_operation: Operation,
        inner_thunks: value.JSValue,
        depth: u8 = 0,
        inner_calls: u8 = 0,
        parent_restored: bool = false,

        fn invoke(operation: Operation, ctx: *context.Context, thunks: value.JSValue) !value.JSValue {
            return switch (operation) {
                .parallel => parallelNative(ctx, value.JSValue.undefined_val, &.{thunks}),
                .race => raceNative(ctx, value.JSValue.undefined_val, &.{thunks}),
            };
        }

        fn destroyResult(operation: Operation, result: value.JSValue, allocator: std.mem.Allocator) void {
            if (operation == .parallel) result.toPtr(object.JSObject).destroy(allocator);
        }

        fn appendFetch(collector: *ParallelCollector) !void {
            collector.descriptors[collector.count] = .{
                .url = try collector.allocator.dupe(u8, "https://nested.example"),
                .method = .GET,
                .body = null,
                .headers = .empty,
                .max_response_bytes = 1024,
            };
            collector.count += 1;
        }

        fn callThunk(runtime_ptr: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
            const self: *@This() = @ptrCast(@alignCast(runtime_ptr));
            const active = self.ctx.parallel_collection.active orelse return error.MissingCollector;

            if (self.depth == 0) {
                self.depth = 1;
                defer self.depth = 0;

                const inner_result = try invoke(self.inner_operation, self.ctx, self.inner_thunks);
                defer destroyResult(self.inner_operation, inner_result, self.ctx.allocator);

                try std.testing.expect(self.ctx.parallel_collection.active == active);
                self.parent_restored = true;
                try appendFetch(active);
            } else {
                self.inner_calls += 1;
                try appendFetch(active);
            }

            return value.JSValue.undefined_val;
        }

        fn execute(_: *anyopaque, _: []const FetchDescriptor, results: []FetchResult) void {
            for (results) |*result| result.ok = true;
        }

        fn build(_: *anyopaque, _: *const FetchResult) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }

        fn run(outer_operation: Operation, inner_operation: Operation) !void {
            const allocator = std.testing.allocator;
            const gc_mod = @import("../../gc.zig");
            const heap_mod = @import("../../heap.zig");

            var setup_complete = false;
            const gc_state = try allocator.create(gc_mod.GC);
            errdefer if (!setup_complete) allocator.destroy(gc_state);
            gc_state.* = try gc_mod.GC.init(allocator, .{});
            errdefer if (!setup_complete) gc_state.deinit();
            const heap_state = try allocator.create(heap_mod.Heap);
            errdefer if (!setup_complete) allocator.destroy(heap_state);
            heap_state.* = heap_mod.Heap.init(allocator, .{});
            errdefer if (!setup_complete) heap_state.deinit();
            gc_state.setHeap(heap_state);
            const ctx = try context.Context.init(allocator, gc_state, .{});
            errdefer if (!setup_complete) ctx.deinit();
            defer {
                ctx.deinit();
                heap_state.deinit();
                gc_state.deinit();
                allocator.destroy(heap_state);
                allocator.destroy(gc_state);
            }
            setup_complete = true;

            const inner_array = try ctx.createArray();
            defer inner_array.destroy(allocator);
            const inner_thunk = try ctx.createObject(ctx.object_prototype);
            defer inner_thunk.destroy(allocator);
            try inner_array.arrayPush(allocator, inner_thunk.toValue());

            const outer_array = try ctx.createArray();
            defer outer_array.destroy(allocator);
            const outer_thunk = try ctx.createObject(ctx.object_prototype);
            defer outer_thunk.destroy(allocator);
            try outer_array.arrayPush(allocator, outer_thunk.toValue());

            var state = @This(){
                .ctx = ctx,
                .inner_operation = inner_operation,
                .inner_thunks = inner_array.toValue(),
            };
            const callbacks = try allocator.create(IoCallbacks);
            callbacks.* = .{
                .call_thunk_fn = callThunk,
                .execute_fetches_fn = execute,
                .build_response_fn = build,
                .runtime_ptr = &state,
            };
            ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

            const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
            defer mb.popActiveModuleContext(token);

            const result = try invoke(outer_operation, ctx, outer_array.toValue());
            defer destroyResult(outer_operation, result, allocator);

            try std.testing.expect(state.parent_restored);
            try std.testing.expectEqual(@as(u8, 1), state.inner_calls);
            try std.testing.expect(ctx.parallel_collection.active == null);
        }
    };

    const cases = [_]struct {
        outer: Harness.Operation,
        inner: Harness.Operation,
    }{
        .{ .outer = .parallel, .inner = .parallel },
        .{ .outer = .parallel, .inner = .race },
        .{ .outer = .race, .inner = .parallel },
    };

    for (cases) |case| try Harness.run(case.outer, case.inner);
}

const RaceTestState = struct {
    ctx: *context.Context,
    fetches_per_thunk: []const u8,
    result_ok: []const bool,
    thunk_index: usize = 0,

    fn callThunk(runtime_ptr: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
        const self: *RaceTestState = @ptrCast(@alignCast(runtime_ptr));
        const fetch_count = self.fetches_per_thunk[self.thunk_index];
        self.thunk_index += 1;

        const col = self.ctx.parallel_collection.active.?;
        for (0..fetch_count) |_| {
            col.descriptors[col.count] = .{
                .url = try col.allocator.dupe(u8, "https://x"),
                .method = .GET,
                .body = null,
                .headers = .empty,
                .max_response_bytes = 1024,
            };
            col.count += 1;
        }
        return value.JSValue.undefined_val;
    }

    fn exec(runtime_ptr: *anyopaque, _: []const FetchDescriptor, results: []FetchResult) void {
        const self: *RaceTestState = @ptrCast(@alignCast(runtime_ptr));
        for (results, 0..) |*result, i| {
            result.ok = self.result_ok[i];
            result.status = @intCast(200 + i);
        }
    }

    fn build(_: *anyopaque, result: *const FetchResult) anyerror!value.JSValue {
        return value.JSValue.fromInt(result.status);
    }
};

fn runRaceTest(fetches_per_thunk: []const u8, result_ok: []const bool) !value.JSValue {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }

    var state = RaceTestState{
        .ctx = ctx,
        .fetches_per_thunk = fetches_per_thunk,
        .result_ok = result_ok,
    };
    const callbacks = try allocator.create(IoCallbacks);
    callbacks.* = .{
        .call_thunk_fn = RaceTestState.callThunk,
        .execute_fetches_fn = RaceTestState.exec,
        .build_response_fn = RaceTestState.build,
        .runtime_ptr = &state,
    };
    ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);

    const arr = try ctx.createArray();
    defer arr.destroy(allocator);
    var thunks: [MAX_PARALLEL]*object.JSObject = undefined;
    for (0..fetches_per_thunk.len) |i| {
        thunks[i] = try ctx.createObject(ctx.object_prototype);
        try arr.arrayPush(ctx.allocator, thunks[i].toValue());
    }
    defer for (thunks[0..fetches_per_thunk.len]) |thunk| thunk.destroy(allocator);

    var outer_descriptors: [1]FetchDescriptor = undefined;
    var outer_collector = ParallelCollector{
        .descriptors = &outer_descriptors,
        .count = 0,
        .allocator = allocator,
        .capacity = 1,
    };
    const outer_scope = ctx.parallel_collection.enter(&outer_collector);
    defer outer_scope.restore();

    const result = try raceNative(ctx, value.JSValue.undefined_val, &.{arr.toValue()});
    try std.testing.expect(ctx.parallel_collection.active == &outer_collector);
    return result;
}

test "race: a thunk resolves to its final fetch" {
    const result = try runRaceTest(&.{ 2, 0 }, &.{ true, true });
    try std.testing.expectEqual(value.JSValue.fromInt(201), result);
}

test "race: a second thunk can win" {
    const result = try runRaceTest(&.{ 1, 1 }, &.{ false, true });
    try std.testing.expectEqual(value.JSValue.fromInt(201), result);
}

test "race: all failing thunks return the first thunk error" {
    const result = try runRaceTest(&.{ 1, 1 }, &.{ false, false });
    try std.testing.expectEqual(value.JSValue.fromInt(200), result);
}

test "race: single-fetch thunks keep declaration-order semantics" {
    const result = try runRaceTest(&.{ 1, 1, 1 }, &.{ true, true, true });
    try std.testing.expectEqual(value.JSValue.fromInt(200), result);
}

test "race: a thrown thunk propagates and restores the parent collector" {
    const allocator = std.testing.allocator;
    const gc_mod = @import("../../gc.zig");
    const heap_mod = @import("../../heap.zig");

    var setup_complete = false;
    const gc_state = try allocator.create(gc_mod.GC);
    errdefer if (!setup_complete) allocator.destroy(gc_state);
    gc_state.* = try gc_mod.GC.init(allocator, .{});
    errdefer if (!setup_complete) gc_state.deinit();
    const heap_state = try allocator.create(heap_mod.Heap);
    errdefer if (!setup_complete) allocator.destroy(heap_state);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    errdefer if (!setup_complete) heap_state.deinit();
    gc_state.setHeap(heap_state);
    const ctx = try context.Context.init(allocator, gc_state, .{});
    errdefer if (!setup_complete) ctx.deinit();
    defer {
        ctx.deinit();
        heap_state.deinit();
        gc_state.deinit();
        allocator.destroy(heap_state);
        allocator.destroy(gc_state);
    }
    setup_complete = true;

    const Stubs = struct {
        var calls: u32 = 0;

        fn callThunk(ctx_ptr: *anyopaque, _: value.JSValue) anyerror!value.JSValue {
            const i = calls;
            calls += 1;
            if (i == 0) {
                const current_ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
                const collector = current_ctx.parallel_collection.active.?;
                collector.descriptors[collector.count] = .{
                    .url = try collector.allocator.dupe(u8, "https://race.example"),
                    .method = .GET,
                    .body = null,
                    .headers = .empty,
                    .max_response_bytes = 1024,
                };
                collector.count += 1;
                return value.JSValue.undefined_val;
            }
            return error.ThunkFailed;
        }

        fn exec(_: *anyopaque, _: []const FetchDescriptor, _: []FetchResult) void {}

        fn build(_: *anyopaque, _: *const FetchResult) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    };
    Stubs.calls = 0;

    const callbacks = try allocator.create(IoCallbacks);
    callbacks.* = .{
        .call_thunk_fn = Stubs.callThunk,
        .execute_fetches_fn = Stubs.exec,
        .build_response_fn = Stubs.build,
        .runtime_ptr = ctx,
    };
    ctx.setModuleState(MODULE_STATE_SLOT, @ptrCast(callbacks), &IoCallbacks.deinitOpaque);

    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);

    const arr = try ctx.createArray();
    defer arr.destroy(allocator);
    const thunk = try ctx.createObject(ctx.object_prototype);
    defer thunk.destroy(allocator);
    try arr.arrayPush(ctx.allocator, thunk.toValue());
    try arr.arrayPush(ctx.allocator, thunk.toValue());

    var outer_descriptors: [1]FetchDescriptor = undefined;
    var outer_collector = ParallelCollector{
        .descriptors = &outer_descriptors,
        .count = 0,
        .allocator = allocator,
        .capacity = 1,
    };
    const outer_scope = ctx.parallel_collection.enter(&outer_collector);
    defer outer_scope.restore();

    try std.testing.expectError(
        error.ThunkFailed,
        raceNative(ctx, value.JSValue.undefined_val, &.{arr.toValue()}),
    );
    try std.testing.expectEqual(@as(u32, 2), Stubs.calls);
    try std.testing.expect(ctx.parallel_collection.active == &outer_collector);
}
