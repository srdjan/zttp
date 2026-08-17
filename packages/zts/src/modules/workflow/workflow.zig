//! zttp:workflow - in-process multi-handler orchestration
//!
//! Exports:
//!   call(name: string, init?: { method?, path?, body?, headers? }) -> Response
//!     Dispatch a request to a co-located sub-handler by name, in-process,
//!     with full per-call isolation (a separate pooled runtime, its own
//!     GC/arena, setjmp panic isolation). Returns the sub-handler's Response,
//!     copied into orchestrator-owned memory.
//!
//! The actual dispatch/copy-out behavior lives in the runtime layer
//! (src/zruntime.zig `workflowCallCallback` over the `SystemRuntime`
//! registry). This module validates JS arguments, then delegates to the
//! runtime-owned callback. `self_managed_io` keeps the generic
//! trace/replay/durable wrappers from auto-recording live Response objects:
//! the runtime callbacks snapshot workflow dispatches as plain
//! `{status,headers,body}` data and rebuild Responses during replay.

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");

pub const MODULE_STATE_SLOT = @intFromEnum(@import("zts-base").module_slots.Slot.workflow);

/// Runtime-owned callbacks installed by src/zruntime.zig when a system
/// registry (a `--system` handler bundle) is present.
pub const WorkflowCallbacks = struct {
    call_fn: *const fn (*anyopaque, *context.Context, []const u8, value.JSValue) anyerror!value.JSValue,
    saga_fn: *const fn (*anyopaque, *context.Context, value.JSValue) anyerror!value.JSValue,
    fanout_fn: *const fn (*anyopaque, *context.Context, value.JSValue) anyerror!value.JSValue,
    follow_fn: *const fn (*anyopaque, *context.Context, value.JSValue, []const u8, value.JSValue) anyerror!value.JSValue,
    runtime_ptr: *anyopaque,

    pub fn deinitOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WorkflowCallbacks = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

pub const binding = mb.ModuleBinding{
    .specifier = "zttp:workflow",
    .name = "workflow",
    .summary = "call dispatches to a co-located handler named in the project's system.json. saga runs an ordered array of { name, run, compensate } steps and returns the outcome, including which steps compensated when a later one fails - a handler that discards that result reports success on a saga that rolled back.",
    .required_capabilities = &.{.runtime_callback},
    .stateful = true,
    .self_managed_io = true,
    .exports = &.{
        // The return type is `Response`, spelled structurally because module
        // types populate before the ABI aliases and the name would not resolve
        // - the same reason `zttp:fetch` spells it out. It is not an
        // approximation: this value comes from `createFetchResponse`, the very
        // function fetch's does, carrying the Response prototype.
        //
        // Declaring `.object` cost two things measured on
        // workflow-queued-call. `return call(...)` tripped ZTS204 against a
        // handler's declared Response, forcing a wrap that the runtime does not
        // need. And `.object` resolves to an unresolved `t_ref`, which member
        // access falls through silently, so a draft reading `.value` off the
        // result compiled clean with results_safe PROVEN and returned 502 for
        // every request.
        .{ .name = "call", .func = callNative, .arg_count = 2, .effect = .write, .returns = .object, .signature = .{
            .params = &.{ "string", "unknown" },
            .returns = "{ ok: boolean; status: number; statusText: string; body: string; headers: { get: (name: string) => string | undefined; has: (name: string) => boolean }; json: () => unknown; text: () => string }",
        }, .param_types = &.{ .string, .unknown }, .param_names = &.{ "name", "init" }, .return_labels = .{ .external = true }, .contract_extractions = &.{.{ .category = .workflow_call }} },
        .{ .name = "saga", .func = sagaNative, .arg_count = 1, .effect = .write, .returns = .object, .param_types = &.{.unknown}, .param_names = &.{"steps"}, .return_labels = .{ .external = true } },
        // Named `fanout`, not `parallel`: module exports share one flat global
        // name namespace (resolver registers each via ctx.setGlobal by name), so
        // `parallel` would collide with and clobber zttp:io's `parallel`.
        .{ .name = "fanout", .func = fanoutNative, .arg_count = 1, .effect = .write, .returns = .object, .param_types = &.{.unknown}, .param_names = &.{"calls"}, .return_labels = .{ .external = true } },
        // follow(resource, rel, init?) - HATEOAS: resolve affordance `rel` on a
        // structured resource() to a bundle route and dispatch in-process. The
        // trailing `init` (body/headers) is optional, so required_arg_count = 2.
        .{ .name = "follow", .func = followNative, .arg_count = 3, .required_arg_count = 2, .effect = .write, .returns = .object, .param_types = &.{ .unknown, .string, .unknown }, .param_names = &.{ "resource", "rel", "init" }, .return_labels = .{ .external = true } },
    },
};

pub const exports = binding.toModuleExports();

fn callNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);
    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "call() requires a --system handler bundle");
    };

    if (args.len < 1) {
        return util.throwError(ctx, "TypeError", "call() expects a handler name");
    }

    const name = util.extractString(args[0]) orelse {
        return util.throwError(ctx, "TypeError", "call() handler name must be a string");
    };

    const init_val = if (args.len >= 2) args[1] else value.JSValue.undefined_val;
    return callbacks.call_fn(callbacks.runtime_ptr, ctx, name, init_val);
}

fn sagaNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);
    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "saga() requires a --system handler bundle");
    };

    if (args.len < 1 or !args[0].isObject()) {
        return util.throwError(ctx, "TypeError", "saga() expects an array of { name, run, compensate? } steps");
    }

    return callbacks.saga_fn(callbacks.runtime_ptr, ctx, args[0]);
}

fn fanoutNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);
    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "fanout() requires a --system handler bundle");
    };

    if (args.len < 1 or !args[0].isObject()) {
        return util.throwError(ctx, "TypeError", "fanout() expects an array of { name, method?, path?, body?, headers? } calls");
    }

    return callbacks.fanout_fn(callbacks.runtime_ptr, ctx, args[0]);
}

fn followNative(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
    const ctx = util.castContext(ctx_ptr);
    const callbacks = try getCallbacks(ctx) orelse {
        return util.throwError(ctx, "Error", "follow() requires a --system handler bundle");
    };

    if (args.len < 2) {
        return util.throwError(ctx, "TypeError", "follow() expects (resource, rel, init?)");
    }
    if (!args[0].isObject()) {
        return util.throwError(ctx, "TypeError", "follow() first argument must be a resource()");
    }
    const rel = util.extractString(args[1]) orelse {
        return util.throwError(ctx, "TypeError", "follow() rel must be a string");
    };

    const init_val = if (args.len >= 3) args[2] else value.JSValue.undefined_val;
    return callbacks.follow_fn(callbacks.runtime_ptr, ctx, args[0], rel, init_val);
}

fn getCallbacks(ctx: *context.Context) error{CapabilityViolation}!?*WorkflowCallbacks {
    return mb.getRuntimeCallbackStateChecked(ctx, WorkflowCallbacks, MODULE_STATE_SLOT);
}
