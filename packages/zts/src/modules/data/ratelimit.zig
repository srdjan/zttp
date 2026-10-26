const context = @import("../../context.zig");
const module_binding = @import("../../module_binding.zig");
const modules = @import("zttp-modules");
const ratelimit_module = modules.data.ratelimit;

pub const RateStore = ratelimit_module.RateStore;

/// Point a runtime's ratelimit slot at a store that a handler pool owns and
/// frees. A slot that already holds a store keeps it. Runtime teardown leaves
/// the shared store alive.
pub fn installShared(ctx: *context.Context, store: *RateStore) !void {
    const slot = ratelimit_module.MODULE_STATE_SLOT;
    if (module_binding.sdk_bridge.getSdkModuleStatePtr(ctx, slot) != null) return;
    try module_binding.sdk_bridge.installSdkModuleState(ctx, slot, @ptrCast(store), RateStore.sharedDeinit);
}
