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

/// One field that a coverage check leaves out of the field-by-field copy.
/// The reason states why the copy does not carry the field.
const Exclusion = struct {
    name: []const u8,
    reason: []const u8,
};

fn isExcluded(comptime excluded: []const Exclusion, comptime name: []const u8) bool {
    for (excluded) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// Return the first problem in the field mapping from `Source` to `Target`, or null.
/// Every source field is excluded or has a target field of the same type.
/// Every target field is excluded or has a source field of the same type.
/// Each exclusion names a field that exists on its own side and has a reason.
fn coverageProblem(
    comptime Source: type,
    comptime Target: type,
    comptime source_excluded: []const Exclusion,
    comptime target_excluded: []const Exclusion,
) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const names = @typeName(Source) ++ " -> " ++ @typeName(Target);
    for (source_excluded) |entry| {
        if (!@hasField(Source, entry.name)) return names ++ ": source exclusion names no field: " ++ entry.name;
        if (entry.reason.len == 0) return names ++ ": source exclusion has no reason: " ++ entry.name;
    }
    for (target_excluded) |entry| {
        if (!@hasField(Target, entry.name)) return names ++ ": target exclusion names no field: " ++ entry.name;
        if (entry.reason.len == 0) return names ++ ": target exclusion has no reason: " ++ entry.name;
    }
    for (@typeInfo(Source).@"struct".field_names) |field| {
        if (isExcluded(source_excluded, field)) continue;
        if (!@hasField(Target, field) or isExcluded(target_excluded, field))
            return names ++ ": unclassified source field: " ++ field;
        if (@FieldType(Target, field) != @FieldType(Source, field))
            return names ++ ": field type differs: " ++ field;
    }
    for (@typeInfo(Target).@"struct".field_names) |field| {
        if (isExcluded(target_excluded, field)) continue;
        if (!@hasField(Source, field) or isExcluded(source_excluded, field))
            return names ++ ": unclassified target field: " ++ field;
    }
    return null;
}

fn requireCoverage(
    comptime Source: type,
    comptime Target: type,
    comptime source_excluded: []const Exclusion,
    comptime target_excluded: []const Exclusion,
) void {
    if (coverageProblem(Source, Target, source_excluded, target_excluded)) |problem| @compileError(problem);
}

const label_exclusions = [_]Exclusion{
    .{ .name = "_reserved", .reason = "reserved bits never become analyzer labels" },
};

/// Copy the nine named labels. The reserved bits stay zero in the result.
fn adaptLabels(comptime labels: sdk.LabelSet) internal.LabelSet {
    comptime requireCoverage(sdk.LabelSet, internal.LabelSet, &label_exclusions, &label_exclusions);
    var out: internal.LabelSet = .{};
    inline for (@typeInfo(sdk.LabelSet).@"struct".field_names) |field| {
        if (comptime isExcluded(&label_exclusions, field)) continue;
        @field(out, field) = @field(labels, field);
    }
    return out;
}

const module_source_exclusions = [_]Exclusion{
    .{ .name = "exports", .reason = "the element type differs; adaptFunctionBindings converts it" },
};
const module_target_exclusions = [_]Exclusion{
    .{ .name = "exports", .reason = "the element type differs; adaptFunctionBindings converts it" },
};

const function_source_exclusions = [_]Exclusion{
    .{ .name = "module_func", .reason = "wrapToNativeFn turns it into the internal func field" },
    .{ .name = "return_labels", .reason = "the LabelSet types differ; adaptLabels converts it" },
    .{ .name = "declassifies", .reason = "the LabelSet types differ; adaptLabels converts it" },
};
const function_target_exclusions = [_]Exclusion{
    .{ .name = "func", .reason = "set from the wrapped SDK module_func" },
    .{ .name = "module_func", .reason = "stays null; the adapter wraps the SDK function into func" },
    .{ .name = "return_labels", .reason = "the LabelSet types differ; adaptLabels converts it" },
    .{ .name = "declassifies", .reason = "the LabelSet types differ; adaptLabels converts it" },
};

pub fn adaptModuleBinding(comptime binding: sdk.ModuleBinding) internal.ModuleBinding {
    const builtin_prefix = std.mem.startsWith(u8, binding.specifier, "zttp:");
    const extension_prefix = std.mem.startsWith(u8, binding.specifier, "zttp-ext:");
    if (!builtin_prefix and !extension_prefix) {
        @compileError("adapted module specifier must start with 'zttp:' or 'zttp-ext:': " ++ binding.specifier);
    }
    comptime requireCoverage(sdk.ModuleBinding, internal.ModuleBinding, &module_source_exclusions, &module_target_exclusions);

    const exports = comptime adaptFunctionBindings(binding.specifier, binding.required_capabilities, binding.exports);
    var out: internal.ModuleBinding = undefined;
    out.exports = &exports;
    inline for (@typeInfo(sdk.ModuleBinding).@"struct".field_names) |field| {
        if (comptime isExcluded(&module_source_exclusions, field)) continue;
        @field(out, field) = @field(binding, field);
    }
    return out;
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
    comptime requireCoverage(sdk.FunctionBinding, internal.FunctionBinding, &function_source_exclusions, &function_target_exclusions);
    var out: internal.FunctionBinding = undefined;
    out.func = wrapToNativeFn(binding.module_func, specifier, binding.required_capabilities orelse required_capabilities);
    out.module_func = null;
    out.return_labels = adaptLabels(binding.return_labels);
    out.declassifies = adaptLabels(binding.declassifies);
    inline for (@typeInfo(sdk.FunctionBinding).@"struct".field_names) |field| {
        if (comptime isExcluded(&function_source_exclusions, field)) continue;
        @field(out, field) = @field(binding, field);
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

test "adapted export enforces its declared capabilities at call time" {
    const Observed = struct {
        var empty_clock: bool = true;
        var declared_clock: bool = false;
        var inherited_clock: bool = false;
        var inherited_random: bool = true;
    };
    Observed.empty_clock = true;
    Observed.declared_clock = false;
    Observed.inherited_clock = false;
    Observed.inherited_random = true;

    const binding = sdk.ModuleBinding{
        .specifier = "zttp-ext:export-capability-test",
        .name = "export-capability-test",
        .required_capabilities = &.{ .clock, .random },
        .exports = &.{
            .{
                .name = "empty",
                .module_func = struct {
                    fn f(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        Observed.empty_clock = sdk.hasCapability(handle, .clock);
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
                .required_capabilities = &.{},
            },
            .{
                .name = "declared",
                .module_func = struct {
                    fn f(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        Observed.declared_clock = sdk.hasCapability(handle, .clock);
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
                .required_capabilities = &.{.clock},
            },
            .{
                .name = "inherited",
                .module_func = struct {
                    fn f(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
                        Observed.inherited_clock = sdk.hasCapability(handle, .clock);
                        Observed.inherited_random = sdk.hasCapability(handle, .random);
                        return sdk.JSValue.undefined_val;
                    }
                }.f,
                .arg_count = 0,
            },
        },
    };
    const adapted = comptime adaptModuleBinding(binding);

    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    _ = try adapted.exports[0].func.?(ctx, value.JSValue.undefined_val, &.{});
    _ = try adapted.exports[1].func.?(ctx, value.JSValue.undefined_val, &.{});
    _ = try adapted.exports[2].func.?(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expectEqual(false, Observed.empty_clock);
    try std.testing.expectEqual(true, Observed.declared_clock);
    try std.testing.expectEqual(true, Observed.inherited_clock);
    try std.testing.expectEqual(true, Observed.inherited_random);
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

test "adapter coverage refuses unclassified fields, type changes, and bad exclusions" {
    const Source = struct { name: []const u8, wrapped: u8, added: bool };
    const Target = struct { name: []const u8, built: u8 };
    const Retyped = struct { name: u32, built: u8 };
    const Same = struct { name: []const u8 };
    const src_excl = [_]Exclusion{.{ .name = "wrapped", .reason = "test" }};
    const tgt_excl = [_]Exclusion{.{ .name = "built", .reason = "test" }};
    const added_excl = [_]Exclusion{.{ .name = "added", .reason = "test" }};
    const absent = [_]Exclusion{.{ .name = "absent", .reason = "test" }};
    const no_reason = [_]Exclusion{.{ .name = "wrapped", .reason = "" }};
    const both = src_excl ++ added_excl;

    try std.testing.expect(comptime coverageProblem(Source, Target, &both, &tgt_excl) == null);
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Source, Target, &src_excl, &tgt_excl).?, "unclassified source field: added"));
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Same, Source, &.{}, &.{}).?, "unclassified target field: wrapped"));
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Source, Retyped, &both, &tgt_excl).?, "field type differs: name"));
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Source, Target, &(both ++ absent), &tgt_excl).?, "source exclusion names no field: absent"));
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Source, Target, &both, &(tgt_excl ++ absent)).?, "target exclusion names no field: absent"));
    try std.testing.expect(comptime std.mem.endsWith(u8, coverageProblem(Source, Target, &(added_excl ++ no_reason), &tgt_excl).?, "source exclusion has no reason: wrapped"));
}
