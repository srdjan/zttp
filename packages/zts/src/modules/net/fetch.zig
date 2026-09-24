const std = @import("std");
const compat = @import("zts-base").compat;
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const adapter = @import("../../module_binding_adapter.zig");
const module_binding = @import("../../module_binding.zig");
const sdk = @import("zttp-sdk");
const modules = @import("zttp-modules");
const fetch_module = modules.net.fetch;

pub const binding = adapter.adaptModuleBinding(fetch_module.binding);
pub const exports = binding.toModuleExports();

pub const MODULE_STATE_SLOT: usize = fetch_module.MODULE_STATE_SLOT;

pub const FetchCallFn = *const fn (
    runtime_ptr: *anyopaque,
    ctx: *context.Context,
    args: []const value.JSValue,
) anyerror!value.JSValue;

/// Builds the runtime's 599 fetch error with `code` and `details`.
pub const FetchRefuseFn = *const fn (
    runtime_ptr: *anyopaque,
    ctx: *context.Context,
    code: []const u8,
    details: []const u8,
) anyerror!value.JSValue;

const InstalledState = struct {
    runtime_ptr: *anyopaque,
    call_fn: FetchCallFn,
    refuse_fn: FetchRefuseFn,
    allocator: std.mem.Allocator,
    base: fetch_module.FetchState,

    fn sdkCall(
        installed_ptr: *anyopaque,
        handle: *sdk.ModuleHandle,
        args: []const sdk.JSValue,
    ) anyerror!sdk.JSValue {
        const self: *InstalledState = @ptrCast(@alignCast(installed_ptr));
        const result = try self.call_fn(self.runtime_ptr, adapter.contextFromHandle(handle), adapter.internalArgs(args));
        return adapter.sdkValue(result);
    }

    fn sdkRefuse(
        installed_ptr: *anyopaque,
        handle: *sdk.ModuleHandle,
        code: []const u8,
        details: []const u8,
    ) anyerror!sdk.JSValue {
        const self: *InstalledState = @ptrCast(@alignCast(installed_ptr));
        const result = try self.refuse_fn(self.runtime_ptr, adapter.contextFromHandle(handle), code, details);
        return adapter.sdkValue(result);
    }

    fn sdkDeadlinePassed(_: *anyopaque, handle: *sdk.ModuleHandle) bool {
        const ctx = adapter.contextFromHandle(handle);
        const deadline = ctx.deadline_ns;
        if (deadline == 0) return false;
        const now = compat.monotonicNowNs() catch return false;
        if (now < deadline) return false;
        ctx.interrupt_requested.store(true, .monotonic);
        return true;
    }
};

/// Install the fetch callbacks into the runtime context. Called during
/// runtime bootstrap, outside any module invocation. The module reads its
/// state through the SDK's `getModuleState`, which unwraps an
/// `SdkStateEnvelope`, so the state must be installed in one: a bare pointer
/// would have the module read the first word of `base` as the envelope's
/// user pointer, and so read `InstalledState` as if it were `FetchState`.
pub fn installState(
    ctx: *context.Context,
    runtime_ptr: *anyopaque,
    call_fn: FetchCallFn,
    refuse_fn: FetchRefuseFn,
) !void {
    if (module_binding.sdk_bridge.getSdkModuleStatePtr(ctx, MODULE_STATE_SLOT)) |existing| {
        const base: *fetch_module.FetchState = @ptrCast(@alignCast(existing));
        const installed: *InstalledState = @fieldParentPtr("base", base);
        installed.runtime_ptr = runtime_ptr;
        installed.call_fn = call_fn;
        installed.refuse_fn = refuse_fn;
        return;
    }

    const installed = try ctx.allocator.create(InstalledState);
    errdefer ctx.allocator.destroy(installed);
    installed.* = .{
        .runtime_ptr = runtime_ptr,
        .call_fn = call_fn,
        .refuse_fn = refuse_fn,
        .allocator = ctx.allocator,
        .base = .{
            .runtime_ptr = @ptrCast(installed),
            .call_fn = InstalledState.sdkCall,
            .deadline_passed_fn = InstalledState.sdkDeadlinePassed,
            .refuse_fn = InstalledState.sdkRefuse,
        },
    };
    try module_binding.sdk_bridge.installSdkModuleState(ctx, MODULE_STATE_SLOT, @ptrCast(&installed.base), sdkDeinit);
}

fn sdkDeinit(ptr: *anyopaque) callconv(.c) void {
    const base: *fetch_module.FetchState = @ptrCast(@alignCast(ptr));
    const installed: *InstalledState = @fieldParentPtr("base", base);
    installed.allocator.destroy(installed);
}
