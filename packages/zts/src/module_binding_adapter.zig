const std = @import("std");
const sdk = @import("zttp-sdk");
const internal = @import("module_binding.zig");
const object = @import("object.zig");
const value = @import("value.zig");
const context = @import("context.zig");
const gc = @import("gc.zig");

pub const ModuleBinding = internal.ModuleBinding;

comptime {
    if (@sizeOf(sdk.JSValue) != @sizeOf(value.JSValue))
        @compileError("zttp-sdk.JSValue must match runtime JSValue size");
    if (@bitSizeOf(sdk.JSValue) != @bitSizeOf(value.JSValue))
        @compileError("zttp-sdk.JSValue must match runtime JSValue bit size");
}

pub fn adaptModuleBinding(comptime binding: sdk.ModuleBinding) internal.ModuleBinding {
    const builtin_prefix = std.mem.startsWith(u8, binding.specifier, "zttp:");
    const extension_prefix = std.mem.startsWith(u8, binding.specifier, "zttp-ext:");
    if (!builtin_prefix and !extension_prefix) {
        @compileError("adapted module specifier must start with 'zttp:' or 'zttp-ext:': " ++ binding.specifier);
    }

    const exports = comptime adaptFunctionBindings(binding.specifier, binding.required_capabilities, binding.exports);
    return .{
        .specifier = binding.specifier,
        .name = binding.name,
        .exports = &exports,
        .summary = binding.summary,
        .required_capabilities = binding.required_capabilities,
        .stateful = binding.stateful,
        .state_init = binding.state_init,
        .state_deinit = binding.state_deinit,
        .contract_section = binding.contract_section,
        .sandboxable = binding.sandboxable,
    };
}

fn adaptFunctionBindings(
    comptime specifier: []const u8,
    comptime required_capabilities: []const sdk.ModuleCapability,
    comptime exports: []const sdk.FunctionBinding,
) [exports.len]internal.FunctionBinding {
    var out: [exports.len]internal.FunctionBinding = undefined;
    for (exports, 0..) |binding, i| {
        out[i] = adaptFunctionBinding(specifier, required_capabilities, binding);
    }
    return out;
}

fn adaptFunctionBinding(
    comptime specifier: []const u8,
    comptime required_capabilities: []const sdk.ModuleCapability,
    comptime binding: sdk.FunctionBinding,
) internal.FunctionBinding {
    return .{
        .name = binding.name,
        .func = wrapToNativeFn(binding.module_func, specifier, required_capabilities),
        .arg_count = binding.arg_count,
        .required_arg_count = binding.required_arg_count,
        .effect = binding.effect,
        .required_capabilities = binding.required_capabilities,
        .returns = binding.returns,
        .param_types = binding.param_types,
        // Carried, not dropped: a peer-package module that names its
        // parameters must reach discovery with them, or the type kinds answer
        // alone and the model is back to guessing which string is which.
        .param_names = binding.param_names,
        // Carried across the boundary rather than dropped: a peer-package
        // module that declares a precise signature must reach the checker
        // with it, or the coarse enum answers in its place and the loss is
        // invisible.
        .signature = binding.signature,
        .json_encodable_args = binding.json_encodable_args,
        .traceable = binding.traceable,
        .replay_pure = binding.replay_pure,
        .contract_extractions = binding.contract_extractions,
        .contract_flags = binding.contract_flags,
        // Reserved SDK bits never become analyzer labels. Keep the explicit
        // field boundary even though the current packed layouts agree.
        .derives_from_args = binding.derives_from_args,
        .return_labels = .{
            .secret = binding.return_labels.secret,
            .credential = binding.return_labels.credential,
            .user_input = binding.return_labels.user_input,
            .config = binding.return_labels.config,
            .internal = binding.return_labels.internal,
            .external = binding.return_labels.external,
            .validated = binding.return_labels.validated,
            .nondeterministic = binding.return_labels.nondeterministic,
            .unknown = binding.return_labels.unknown,
        },
        .declassify_bound_arg = binding.declassify_bound_arg,
        .declassifies = .{
            .secret = binding.declassifies.secret,
            .credential = binding.declassifies.credential,
            .user_input = binding.declassifies.user_input,
            .config = binding.declassifies.config,
            .internal = binding.declassifies.internal,
            .external = binding.declassifies.external,
            .validated = binding.declassifies.validated,
            .nondeterministic = binding.declassifies.nondeterministic,
            .unknown = binding.declassifies.unknown,
        },
        .failure_severity = binding.failure_severity,
        .laws = binding.laws,
    };
}

/// Cross-boundary casts shared by the runtime-callback installState shims
/// (packages/zts/src/modules/net/{fetch,service,websocket}.zig). Both
/// JSValue types are bit-identical packed structs by comptime assertion
/// above; the opaque handle types wrap the same context pointer.
pub inline fn contextFromHandle(handle: *sdk.ModuleHandle) *context.Context {
    return internal.handleToContext(@ptrCast(handle));
}

pub inline fn sdkValue(v: value.JSValue) sdk.JSValue {
    return @bitCast(v);
}

pub inline fn internalValue(v: sdk.JSValue) value.JSValue {
    return @bitCast(v);
}

pub inline fn internalArgs(args: []const sdk.JSValue) []const value.JSValue {
    return @ptrCast(args);
}

/// Produce a NativeFn directly from a sdk.ModuleFn, avoiding double-wrapping.
/// Both JSValue types are bit-identical packed structs, so args are aliased
/// via @ptrCast with zero per-element copy.
fn wrapToNativeFn(
    comptime module_fn: sdk.ModuleFn,
    comptime specifier: []const u8,
    comptime required_capabilities: []const internal.ModuleCapability,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
            const prev = internal.pushActiveModuleContext(ctx, specifier, required_capabilities);
            defer internal.popActiveModuleContext(prev);

            const sdk_args: []const sdk.JSValue = @ptrCast(args);
            const result = try module_fn(
                @ptrCast(ctx_ptr),
                @bitCast(this),
                sdk_args,
            );
            return @bitCast(result);
        }
    }.call;
}

test "adaptModuleBinding preserves required capabilities" {
    const binding = sdk.ModuleBinding{
        .specifier = "zttp-ext:test",
        .name = "test",
        .required_capabilities = &.{ .clock, .runtime_callback },
        .exports = &.{
            .{
                .name = "noop",
                .module_func = struct {
                    fn f(_: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
            },
        },
    };

    const adapted = comptime adaptModuleBinding(binding);
    try std.testing.expectEqual(@as(usize, 2), adapted.required_capabilities.len);
    try std.testing.expectEqual(internal.ModuleCapability.clock, adapted.required_capabilities[0]);
    try std.testing.expectEqual(internal.ModuleCapability.runtime_callback, adapted.required_capabilities[1]);
}

test "adapted SDK module invocation reads authorization from its Context" {
    const Observed = struct {
        var clock: bool = false;
        var random: bool = false;
    };
    Observed.clock = false;
    Observed.random = false;

    const binding = sdk.ModuleBinding{
        .specifier = "zttp-ext:authorization-test",
        .name = "authorization-test",
        .required_capabilities = &.{.clock},
        .exports = &.{.{
            .name = "observe",
            .module_func = struct {
                fn f(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                    Observed.clock = sdk.hasCapability(handle, .clock);
                    Observed.random = sdk.hasCapability(handle, .random);
                    return sdk.JSValue.undefined_val;
                }
            }.f,
            .arg_count = 0,
        }},
    };
    const adapted = comptime adaptModuleBinding(binding);

    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    _ = try adapted.exports[0].func.?(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expect(Observed.clock);
    try std.testing.expect(!Observed.random);
    try std.testing.expect(ctx.active_module_scope == null);
}

test "binding metadata has one SDK type identity" {
    inline for (.{
        .{ sdk.EffectClass, internal.EffectClass },
        .{ sdk.ReturnKind, internal.ReturnKind },
        .{ sdk.binding.DeclaredSignature, internal.DeclaredSignature },
        .{ sdk.FailureSeverity, internal.FailureSeverity },
        .{ sdk.ModuleCapability, internal.ModuleCapability },
        .{ sdk.DataLabel, internal.DataLabel },
        .{ sdk.ContractCategory, internal.ContractCategory },
        .{ sdk.ContractTransform, internal.ContractTransform },
        .{ sdk.ContractExtraction, internal.ContractExtraction },
        .{ sdk.ContractFlags, internal.ContractFlags },
        .{ sdk.LawKind, internal.LawKind },
        .{ sdk.AbsorbingPattern, internal.AbsorbingPattern },
        .{ sdk.Law, internal.Law },
    }) |pair| try std.testing.expect(pair[0] == pair[1]);
    try std.testing.expect(sdk.LabelSet != internal.LabelSet);
    try std.testing.expect(sdk.ModuleHandle != internal.ModuleHandle);
    try std.testing.expect(sdk.JSValue != value.JSValue);
}

test "adapted bindings preserve capability inheritance and reject reserved label bits" {
    const binding = sdk.ModuleBinding{
        .specifier = "zttp-ext:metadata-test",
        .name = "metadata-test",
        .required_capabilities = &.{.clock},
        .exports = &.{
            .{
                .name = "inherit",
                .module_func = struct {
                    fn f(_: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
                // Reserved SDK bits must never become analyzer facts.
                .return_labels = .{ .unknown = true, ._reserved = 1 },
                .declassifies = .{ .secret = true, .credential = true, ._reserved = 1 },
            },
            .{
                .name = "none",
                .module_func = struct {
                    fn f(_: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
                .required_capabilities = &.{},
            },
        },
    };
    const adapted = comptime adaptModuleBinding(binding);
    try std.testing.expect(adapted.exports[0].required_capabilities == null);
    try std.testing.expectEqual(@as(usize, 0), adapted.exports[1].required_capabilities.?.len);
    try std.testing.expectEqual(internal.LabelSet{ .unknown = true }, adapted.exports[0].return_labels);
    try std.testing.expectEqual(internal.LabelSet{ .secret = true, .credential = true }, adapted.exports[0].declassifies);
}
