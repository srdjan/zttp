//! Host installation of the protected accounting store.
const context = @import("../../context.zig");
const mb = @import("../../module_binding.zig");
const adapter = @import("../../module_binding_adapter.zig");
const ledger = @import("zttp-modules").data.ledger;

pub const binding = adapter.adaptModuleBinding(ledger.binding);
pub const exports = binding.toModuleExports();
pub const MODULE_STATE_SLOT = ledger.MODULE_STATE_SLOT;
pub const Config = ledger.Config;
pub const Currency = ledger.Currency;
pub const AccountMatcher = ledger.AccountMatcher;
pub const AccountMatcherTag = ledger.AccountMatcherTag;

/// The linked adapter's own statement of what it enforces, re-exported so the
/// runtime can convert it for the executable graph without reaching past this
/// bridge. It is the native module's value, not a copy maintained here.
pub const AdapterManifest = ledger.AdapterManifest;
pub const ManifestPredicate = ledger.ManifestPredicate;
pub const adapter_manifest = ledger.adapter_manifest;

pub fn installStore(ctx: *context.Context, path: []const u8, config: Config) !void {
    try mb.installProtectedLedgerPath(ctx, path);
    if (mb.sdk_bridge.getSdkModuleStatePtr(ctx, MODULE_STATE_SLOT) != null)
        return error.LedgerAlreadyInstalled;
    const store = try ctx.allocator.create(ledger.LedgerStore);
    store.* = ledger.LedgerStore.init(ctx.allocator, config) catch |err| {
        ctx.allocator.destroy(store);
        return err;
    };
    // The SDK envelope owns the store after installation, including on a
    // subsequent validation failure when the host destroys this Context.
    mb.sdk_bridge.installSdkModuleState(ctx, MODULE_STATE_SLOT, @ptrCast(store), ledger.LedgerStore.sdkDeinit) catch |err| {
        ledger.LedgerStore.sdkDeinit(@ptrCast(store));
        return err;
    };
    const token = mb.pushActiveModuleContext(ctx, binding.specifier, binding.required_capabilities);
    defer mb.popActiveModuleContext(token);
    try store.validate(@ptrCast(mb.contextToHandle(ctx)));
}
