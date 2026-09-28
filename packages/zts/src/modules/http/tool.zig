const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const adapter = @import("../../module_binding_adapter.zig");
const module_binding = @import("../../module_binding.zig");
const sdk = @import("zttp-sdk");
const modules = @import("zttp-modules");
const tool_module = modules.http.tool;

pub const binding = adapter.adaptModuleBinding(tool_module.binding);
pub const exports = binding.toModuleExports();
pub const MODULE_STATE_SLOT: usize = tool_module.MODULE_STATE_SLOT;

pub const CallToolFn = *const fn (
    runtime_ptr: *anyopaque,
    ctx: *context.Context,
    args: []const value.JSValue,
) anyerror!value.JSValue;

const InstalledState = struct {
    runtime_ptr: *anyopaque,
    call_fn: CallToolFn,
    allocator: std.mem.Allocator,
    base: tool_module.ToolState,

    fn sdkCall(
        installed_ptr: *anyopaque,
        handle: *sdk.ModuleHandle,
        args: []const sdk.JSValue,
    ) anyerror!sdk.JSValue {
        const self: *InstalledState = @ptrCast(@alignCast(installed_ptr));
        const result = try self.call_fn(self.runtime_ptr, adapter.contextFromHandle(handle), adapter.internalArgs(args));
        return adapter.sdkValue(result);
    }
};

pub fn installState(ctx: *context.Context, runtime_ptr: *anyopaque, call_fn: CallToolFn) !void {
    if (module_binding.sdk_bridge.getSdkModuleStatePtr(ctx, MODULE_STATE_SLOT)) |existing| {
        const base: *tool_module.ToolState = @ptrCast(@alignCast(existing));
        const installed: *InstalledState = @fieldParentPtr("base", base);
        installed.runtime_ptr = runtime_ptr;
        installed.call_fn = call_fn;
        return;
    }

    const installed = try ctx.allocator.create(InstalledState);
    errdefer ctx.allocator.destroy(installed);
    installed.* = .{
        .runtime_ptr = runtime_ptr,
        .call_fn = call_fn,
        .allocator = ctx.allocator,
        .base = .{
            .runtime_ptr = @ptrCast(installed),
            .call_fn = InstalledState.sdkCall,
        },
    };
    try module_binding.sdk_bridge.installSdkModuleState(ctx, MODULE_STATE_SLOT, @ptrCast(&installed.base), sdkDeinit);
}

fn sdkDeinit(ptr: *anyopaque) callconv(.c) void {
    const base: *tool_module.ToolState = @ptrCast(@alignCast(ptr));
    const installed: *InstalledState = @fieldParentPtr("base", base);
    installed.allocator.destroy(installed);
}
