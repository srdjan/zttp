const std = @import("std");
const zts = @import("zts");
const panic_recovery = @import("panic_recovery.zig");

pub const panic = std.debug.FullPanic(panic_recovery.handlePanic);

const mb = zts.module_binding;
const JSValue = zts.JSValue;

const ProbeError = error{
    MissingProbeState,
    OuterCapabilityMissing,
    InnerCapabilityLeaked,
    InnerScopeMissingAfterPanic,
    InnerScopeSurvivedQuarantine,
    PanicDidNotFire,
    WrongPanic,
};

const RecoveryState = struct {
    frame: panic_recovery.Frame = undefined,
    outer_handle: *mb.ModuleHandle,
    inner_context: *zts.Context,
    inner_scope_cleared_on_deinit: bool = false,
};

fn observeQuarantineCleanup(ptr: *anyopaque, _: std.mem.Allocator) void {
    const probe: *RecoveryState = @ptrCast(@alignCast(ptr));
    probe.inner_scope_cleared_on_deinit = probe.inner_context.active_module_scope == null;
}

fn innerModule(_: *mb.ModuleHandle, _: JSValue, _: []const JSValue) anyerror!JSValue {
    @panic("module_scope_panic_probe");
}

const inner_wrapped = mb.wrapModuleFnWithCapabilities(
    innerModule,
    "zttp:panic-inner",
    &.{.random},
);

noinline fn outerModule(handle: *mb.ModuleHandle, _: JSValue, _: []const JSValue) anyerror!JSValue {
    if (!mb.hasCapability(handle, .clock)) return ProbeError.OuterCapabilityMissing;
    if (mb.hasCapability(handle, .random)) return ProbeError.InnerCapabilityLeaked;

    const outer_context = mb.handleToContext(handle);
    const probe: *RecoveryState = @ptrCast(@alignCast(outer_context.host orelse return ProbeError.MissingProbeState));

    if (panic_recovery.setjmpFn(&probe.frame.jb) != 0) {
        if (!std.mem.eql(u8, probe.frame.message(), "module_scope_panic_probe")) {
            return ProbeError.WrongPanic;
        }
        if (!mb.hasCapability(probe.outer_handle, .clock)) {
            return ProbeError.OuterCapabilityMissing;
        }
        if (mb.hasCapability(probe.outer_handle, .random)) {
            return ProbeError.InnerCapabilityLeaked;
        }
        return JSValue.true_val;
    }

    panic_recovery.arm(&probe.frame);
    defer panic_recovery.disarm();
    _ = try inner_wrapped(probe.inner_context, JSValue.undefined_val, &.{});
    return ProbeError.PanicDidNotFire;
}

const outer_wrapped = mb.wrapModuleFnWithCapabilities(
    outerModule,
    "zttp:panic-outer",
    &.{.clock},
);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var outer_gc = try zts.GC.init(allocator, .{});
    defer outer_gc.deinit();
    const outer_context = try zts.Context.init(allocator, &outer_gc, .{});
    defer outer_context.deinit();

    var inner_gc = try zts.GC.init(allocator, .{});
    defer inner_gc.deinit();
    const inner_context = try zts.Context.init(allocator, &inner_gc, .{});
    var inner_context_owned = true;
    errdefer if (inner_context_owned) inner_context.deinit();

    var probe = RecoveryState{
        .outer_handle = mb.contextToHandle(outer_context),
        .inner_context = inner_context,
    };
    outer_context.host = &probe;
    inner_context.setModuleState(0, &probe, observeQuarantineCleanup);

    const result = try outer_wrapped(outer_context, JSValue.undefined_val, &.{});
    if (!result.isTrue()) return error.UnexpectedProbeResult;
    if (mb.hasCapability(probe.outer_handle, .clock)) return error.OuterScopeNotCleared;

    const failed_scope = inner_context.active_module_scope orelse return ProbeError.InnerScopeMissingAfterPanic;
    if (!std.mem.eql(u8, failed_scope.specifier, "zttp:panic-inner") or
        failed_scope.required_capabilities.len != 1 or
        failed_scope.required_capabilities[0] != .random)
    {
        return ProbeError.InnerScopeMissingAfterPanic;
    }

    // HandlerPool drops a runtime after a recovered panic instead of reusing
    // it. The skipped wrapper defer may leave the failed Context's inner scope
    // set, so deinit must revoke it before any module-state destructor runs.
    inner_context.deinit();
    inner_context_owned = false;
    if (!probe.inner_scope_cleared_on_deinit) return ProbeError.InnerScopeSurvivedQuarantine;
}
