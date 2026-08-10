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
    // Last variant of each paired enum must share an ordinal. Covers
    // length alignment too: if SDK adds a tail variant the internal side
    // lacks, the ordinal check catches it before any adaptor runs.
    assertOrdinal(sdk.EffectClass.none, internal.EffectClass.none, "EffectClass");
    assertOrdinal(sdk.ReturnKind.result, internal.ReturnKind.result, "ReturnKind");
    assertOrdinal(sdk.FailureSeverity.none, internal.FailureSeverity.none, "FailureSeverity");
    assertOrdinal(sdk.ContractCategory.extension_specific, internal.ContractCategory.extension_specific, "ContractCategory");
    assertOrdinal(sdk.LawKind.absorbing, internal.LawKind.absorbing, "LawKind");
}

fn assertOrdinal(comptime sdk_variant: anytype, comptime internal_variant: anytype, comptime name: []const u8) void {
    if (@intFromEnum(sdk_variant) != @intFromEnum(internal_variant))
        @compileError("sdk." ++ name ++ " ordinals diverge from internal");
}

pub fn adaptModuleBinding(comptime binding: sdk.ModuleBinding) internal.ModuleBinding {
    const builtin_prefix = std.mem.startsWith(u8, binding.specifier, "zttp:");
    const extension_prefix = std.mem.startsWith(u8, binding.specifier, "zttp-ext:");
    if (!builtin_prefix and !extension_prefix) {
        @compileError("adapted module specifier must start with 'zttp:' or 'zttp-ext:': " ++ binding.specifier);
    }

    const exports = comptime adaptFunctionBindings(binding.specifier, binding.required_capabilities, binding.exports);
    const required_capabilities = comptime adaptModuleCapabilities(binding.required_capabilities);
    return .{
        .specifier = binding.specifier,
        .name = binding.name,
        .exports = &exports,
        .required_capabilities = &required_capabilities,
        .stateful = binding.stateful,
        .state_init = binding.state_init,
        .state_deinit = binding.state_deinit,
        .contract_section = binding.contract_section,
        .sandboxable = binding.sandboxable,
        .comptime_only = binding.comptime_only,
        .self_managed_io = binding.self_managed_io,
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

fn adaptModuleCapabilities(comptime capabilities: []const sdk.ModuleCapability) [capabilities.len]internal.ModuleCapability {
    var out: [capabilities.len]internal.ModuleCapability = undefined;
    for (capabilities, 0..) |capability, i| {
        out[i] = @enumFromInt(@intFromEnum(capability));
    }
    return out;
}

/// Carry an export's own capability set across the SDK boundary, preserving
/// the null/empty distinction: null inherits the module set, empty declares
/// that this export reaches nothing.
fn adaptExportCapabilities(
    comptime caps: ?[]const sdk.ModuleCapability,
) ?[]const internal.ModuleCapability {
    const declared = caps orelse return null;
    const adapted = adaptModuleCapabilities(declared);
    const frozen = adapted;
    return &frozen;
}

fn adaptFunctionBinding(
    comptime specifier: []const u8,
    comptime required_capabilities: []const sdk.ModuleCapability,
    comptime binding: sdk.FunctionBinding,
) internal.FunctionBinding {
    const param_types = comptime adaptReturnKinds(binding.param_types);
    const contract_extractions = comptime adaptContractExtractions(binding.contract_extractions);
    const laws = comptime adaptLaws(binding.laws);
    const internal_required_capabilities = comptime adaptModuleCapabilities(required_capabilities);
    return .{
        .name = binding.name,
        .func = wrapToNativeFn(binding.module_func, specifier, &internal_required_capabilities),
        .arg_count = binding.arg_count,
        .required_arg_count = binding.required_arg_count,
        .effect = @enumFromInt(@intFromEnum(binding.effect)),
        .required_capabilities = comptime adaptExportCapabilities(binding.required_capabilities),
        .returns = @enumFromInt(@intFromEnum(binding.returns)),
        .param_types = &param_types,
        // Carried across the boundary rather than dropped: a peer-package
        // module that declares a precise signature must reach the checker
        // with it, or the coarse enum answers in its place and the loss is
        // invisible.
        .signature = if (binding.signature) |sig| .{ .params = sig.params, .returns = sig.returns } else null,
        .json_encodable_args = binding.json_encodable_args,
        .traceable = binding.traceable,
        .replay_pure = binding.replay_pure,
        .contract_extractions = &contract_extractions,
        .contract_flags = .{
            .sets_scope_used = binding.contract_flags.sets_scope_used,
            .sets_durable_used = binding.contract_flags.sets_durable_used,
            .sets_durable_timers = binding.contract_flags.sets_durable_timers,
            .sets_bearer_auth = binding.contract_flags.sets_bearer_auth,
            .sets_jwt_auth = binding.contract_flags.sets_jwt_auth,
        },
        // Field by field, not a bitcast: the internal set carries `unknown`,
        // which the analysis assigns and an extension author cannot declare,
        // so the two types no longer share a width.
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
        },
        .failure_severity = @enumFromInt(@intFromEnum(binding.failure_severity)),
        .laws = &laws,
    };
}

fn adaptLaws(comptime laws: []const sdk.Law) [laws.len]internal.Law {
    var out: [laws.len]internal.Law = undefined;
    for (laws, 0..) |law, i| {
        out[i] = switch (law) {
            .pure => .pure,
            .idempotent_call => .idempotent_call,
            .inverse_of => |target| .{ .inverse_of = target },
            .absorbing => |pattern| .{ .absorbing = .{
                .arg_position = pattern.arg_position,
                .argument_shape = @enumFromInt(@intFromEnum(pattern.argument_shape)),
                .residue = @enumFromInt(@intFromEnum(pattern.residue)),
            } },
        };
    }
    return out;
}

fn adaptReturnKinds(comptime kinds: []const sdk.ReturnKind) [kinds.len]internal.ReturnKind {
    var out: [kinds.len]internal.ReturnKind = undefined;
    for (kinds, 0..) |kind, i| {
        out[i] = @enumFromInt(@intFromEnum(kind));
    }
    return out;
}

fn adaptContractExtractions(comptime extractions: []const sdk.ContractExtraction) [extractions.len]internal.ContractExtraction {
    var out: [extractions.len]internal.ContractExtraction = undefined;
    for (extractions, 0..) |extraction, i| {
        out[i] = .{
            .arg_position = extraction.arg_position,
            .category = @enumFromInt(@intFromEnum(extraction.category)),
            .transform = if (extraction.transform) |transform|
                @enumFromInt(@intFromEnum(transform))
            else
                null,
            .flag_only = extraction.flag_only,
            .extension_category = extraction.extension_category,
        };
    }
    return out;
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
