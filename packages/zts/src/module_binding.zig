//! Virtual Module Binding Specification
//!
//! A single comptime struct that captures every fact about a virtual module
//! needed by all consumers: resolver, type checker, verifier, bool checker,
//! contract builder, state manager, and trace/replay system.
//!
//! Built-in modules declare `pub const binding: ModuleBinding` alongside
//! their existing `exports` array. Third-party modules depend on zttp-sdk
//! and write functions using ModuleFn (opaque handle) instead of NativeFn.
//!
//! Third-party modules use the SDK's opaque ModuleHandle and helpers.
//! SDK helpers call the runtime ABI bridge. This internal facade also
//! exposes Context access for trusted engine and runtime bootstrap code.
//!
//! This facade keeps in-repository callers independent of the file split.
//! The specification vocabulary, capability enforcement, and runtime ABI bridge live in
//! `module_binding/types.zig`, `module_binding/capabilities.zig`, and
//! `module_binding/bridge.zig`. Their facade exports remain here.

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const context = @import("context.zig");
const resolver = @import("modules/internal/resolver.zig");
const gc = @import("gc.zig");
const module_slots = @import("zts-base").module_slots;
const compat = @import("zts-base").compat;
const handler_policy = @import("handler_policy.zig");
const security_events = @import("security_events.zig");

pub const capabilities = @import("module_binding/capabilities.zig");
pub const bridge = @import("module_binding/bridge.zig");
pub const types = @import("module_binding/types.zig");

// --- capabilities ---------------------------------------------------------
pub const ModuleHandle = capabilities.ModuleHandle;
pub const ModuleFn = capabilities.ModuleFn;
pub const ActiveModuleToken = capabilities.ActiveModuleToken;
pub const ModuleCapability = capabilities.ModuleCapability;
pub const ModuleCapabilityError = capabilities.ModuleCapabilityError;
pub const ActiveCapabilityError = capabilities.ActiveCapabilityError;
pub const capability_count = capabilities.capability_count;
pub const capabilityHash = capabilities.capabilityHash;
pub const wrapModuleFn = capabilities.wrapModuleFn;
pub const wrapNativeFnWithCapabilities = capabilities.wrapNativeFnWithCapabilities;
pub const wrapModuleFnWithCapabilities = capabilities.wrapModuleFnWithCapabilities;
pub const handleToContext = capabilities.handleToContext;
pub const contextToHandle = capabilities.contextToHandle;
pub const activeModuleOwnsStateSlot = capabilities.activeModuleOwnsStateSlot;
pub const hasCapability = capabilities.hasCapability;
pub const requireCapability = capabilities.requireCapability;
pub const pushActiveModuleContext = capabilities.pushActiveModuleContext;
pub const popActiveModuleContext = capabilities.popActiveModuleContext;
pub const nowMsForActiveModule = capabilities.nowMsForActiveModule;
pub const nowNsForActiveModule = capabilities.nowNsForActiveModule;
pub const fillRandomForActiveModule = capabilities.fillRandomForActiveModule;
pub const writeStderrForActiveModule = capabilities.writeStderrForActiveModule;
pub const allowSdkSqlitePath = capabilities.allowSdkSqlitePath;
pub const readEnvForActiveModule = capabilities.readEnvForActiveModule;
pub const readEnvChecked = capabilities.readEnvChecked;
pub const sqliteCapabilityChecked = capabilities.sqliteCapabilityChecked;
pub const openSqliteDbChecked = capabilities.openSqliteDbChecked;
pub const hmacSha256ForActiveModule = capabilities.hmacSha256ForActiveModule;
pub const sha256ForActiveModule = capabilities.sha256ForActiveModule;
pub const allowsCacheNamespaceForActiveModule = capabilities.allowsCacheNamespaceForActiveModule;
pub const allowsCacheNamespaceChecked = capabilities.allowsCacheNamespaceChecked;
pub const allowsEnvForActiveModule = capabilities.allowsEnvForActiveModule;
pub const allowsEnvChecked = capabilities.allowsEnvChecked;
pub const allowsSqlQueryForActiveModule = capabilities.allowsSqlQueryForActiveModule;
pub const allowsSqlQueryChecked = capabilities.allowsSqlQueryChecked;
pub const allowsSqlWriteForActiveModule = capabilities.allowsSqlWriteForActiveModule;
pub const allowsSqlWriteChecked = capabilities.allowsSqlWriteChecked;

// --- bridge ---------------------------------------------------------------
pub const sdk_bridge = bridge.sdk_bridge;
pub const createString = bridge.createString;
pub const extractString = bridge.extractString;
pub const extractInt = bridge.extractInt;
pub const extractFloat = bridge.extractFloat;
pub const resultOk = bridge.resultOk;
pub const resultErr = bridge.resultErr;
pub const resultErrValue = bridge.resultErrValue;
pub const resultErrs = bridge.resultErrs;
pub const throwError = bridge.throwError;
pub const getAllocator = bridge.getAllocator;

// The SDK bridge is part of the binary ABI. Referencing the module alone does
// not force analysis of its contents, so the export family needs this anchor
// to be emitted.
comptime {
    _ = bridge.sdk_bridge;
}

// --- types ----------------------------------------------------------------
pub const EffectClass = types.EffectClass;
pub const ReturnKind = types.ReturnKind;
pub const DeclaredSignature = types.DeclaredSignature;
pub const FailureSeverity = types.FailureSeverity;
pub const DataLabel = types.DataLabel;
pub const LabelSet = types.LabelSet;
pub const ContractCategory = types.ContractCategory;
pub const ContractTransform = types.ContractTransform;
pub const ContractExtraction = types.ContractExtraction;
pub const ContractFlags = types.ContractFlags;
pub const LawKind = types.LawKind;
pub const Law = types.Law;
pub const AbsorbingPattern = types.AbsorbingPattern;
pub const FunctionBinding = types.FunctionBinding;
pub const ModuleBinding = types.ModuleBinding;
pub const validateBindings = types.validateBindings;
pub const findDuplicateLawKind = types.findDuplicateLawKind;
const findDuplicateRequiredCapability = types.findDuplicateRequiredCapability;
pub const findFunctionInRegistry = types.findFunctionInRegistry;
pub const hasInverseLawPointingTo = types.hasInverseLawPointingTo;

/// Whether a result that reads this capability can differ between two runs of
/// the same request: a clock, a random source, the network, and stored data.
/// The switch has no `else`, so a new capability must be classified here.
pub fn capabilityVaries(cap: ModuleCapability) bool {
    return switch (cap) {
        .clock, .random, .network, .sqlite, .filesystem => true,
        .env, .crypto, .stderr, .runtime_callback, .policy_check => false,
    };
}

/// Whether the result of an export can differ between runs of the same
/// request. The export varies when its capabilities (its own list, or the
/// module's when it declares none) include a varying capability, when it reads
/// from a stateful module, or when it declares `unknown` or `nondeterministic`
/// for its return labels. The two flow analyses and the effect rows read this
/// one rule, so a new export cannot slip past one of them.
pub fn exportVaries(binding: *const ModuleBinding, func: *const FunctionBinding) bool {
    if (binding.stateful and func.effect == .read) return true;
    if (func.return_labels.unknown or func.return_labels.nondeterministic) return true;
    const caps = func.required_capabilities orelse binding.required_capabilities;
    for (caps) |cap| {
        if (capabilityVaries(cap)) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "wrapModuleFn generates valid NativeFn" {
    const module_fn: ModuleFn = struct {
        fn f(_: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    }.f;

    const native_fn = comptime wrapModuleFn(module_fn);
    // Verify the wrapper compiles and has the right type
    const ptr_info = @typeInfo(@TypeOf(native_fn));
    try std.testing.expect(ptr_info == .pointer);
}

test "FunctionBinding with module_func wraps correctly" {
    const fb = FunctionBinding{
        .name = "sandboxedFn",
        .module_func = struct {
            fn f(_: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
                return value.JSValue.true_val;
            }
        }.f,
        .arg_count = 1,
    };

    const native_fn = comptime fb.getNativeFn();
    const expected = comptime wrapModuleFn(fb.module_func.?);
    try std.testing.expect(native_fn == expected);
}

test "LabelSet merge combines labels" {
    const a = LabelSet{ .secret = true };
    const b = LabelSet{ .credential = true };
    const merged = LabelSet.merge(a, b);
    try std.testing.expect(merged.secret);
    try std.testing.expect(merged.credential);
    try std.testing.expect(!merged.user_input);
}

test "value aggregation requires every user input contributor to be validated" {
    const raw = LabelSet{ .user_input = true, .secret = true };
    const checked = LabelSet{ .user_input = true, .validated = true, .credential = true };
    const escaped = LabelSet{ .validated = true };
    for ([_]LabelSet{ checked, escaped }) |safe| {
        for ([_]LabelSet{ LabelSet.mergeValues(raw, safe), LabelSet.mergeValues(safe, raw) }) |mixed| {
            try std.testing.expect(mixed.user_input);
            try std.testing.expect(mixed.secret);
            try std.testing.expectEqual(safe.credential, mixed.credential);
            try std.testing.expect(!mixed.validated);
            // A later validated sibling cannot restore a lost guarantee.
            try std.testing.expect(!LabelSet.mergeValues(mixed, checked).validated);
        }
        try std.testing.expect(LabelSet.mergeValues(LabelSet.empty, safe).validated);
        try std.testing.expect(LabelSet.mergeValues(safe, LabelSet.empty).validated);
        try std.testing.expect(LabelSet.mergeValues(safe, safe).validated);
    }
    try std.testing.expect(!LabelSet.mergeValues(LabelSet.empty, LabelSet.empty).validated);
}

test "LabelSet has checks specific label" {
    const labels = LabelSet{ .secret = true, .user_input = true };
    try std.testing.expect(labels.has(.secret));
    try std.testing.expect(labels.has(.user_input));
    try std.testing.expect(!labels.has(.credential));
    try std.testing.expect(!labels.has(.config));
}

test "LabelSet hasAny checks mask intersection" {
    const labels = LabelSet{ .config = true, .internal = true };
    const sensitive = LabelSet{ .secret = true, .credential = true };
    const config_mask = LabelSet{ .config = true };
    try std.testing.expect(!labels.hasAny(sensitive));
    try std.testing.expect(labels.hasAny(config_mask));
}

test "LabelSet isEmpty" {
    try std.testing.expect(LabelSet.empty.isEmpty());
    try std.testing.expect(!(LabelSet{ .secret = true }).isEmpty());
}

test "LabelSet fromLabel" {
    const label = LabelSet.fromLabel(.credential);
    try std.testing.expect(label.credential);
    try std.testing.expect(!label.secret);
}

test "FunctionBinding return_labels defaults to empty" {
    const fb = FunctionBinding{
        .name = "test",
        .func = struct {
            fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
                return value.JSValue.undefined_val;
            }
        }.f,
        .arg_count = 0,
    };
    try std.testing.expect(fb.return_labels.isEmpty());
}

test "FunctionBinding failure_severity defaults to none" {
    const fb = FunctionBinding{
        .name = "test",
        .func = struct {
            fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
                return value.JSValue.undefined_val;
            }
        }.f,
        .arg_count = 0,
    };
    try std.testing.expectEqual(FailureSeverity.none, fb.failure_severity);
}

test "ModuleBinding required_capabilities defaults to empty" {
    const binding = ModuleBinding{
        .specifier = "zttp:test",
        .name = "test",
        .exports = &.{},
    };

    try std.testing.expectEqual(@as(usize, 0), binding.required_capabilities.len);
}

test "findDuplicateRequiredCapability returns duplicate capability" {
    const duplicate = comptime findDuplicateRequiredCapability(&.{ .clock, .crypto, .clock });
    try std.testing.expectEqual(ModuleCapability.clock, duplicate.?);
}

test "findDuplicateRequiredCapability ignores unique capabilities" {
    const duplicate = comptime findDuplicateRequiredCapability(&.{ .clock, .crypto, .policy_check });
    try std.testing.expect(duplicate == null);
}

test "requireCapability respects active module scope" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();
    const handle = contextToHandle(ctx);

    const token = pushActiveModuleContext(ctx, "zttp-ext:test", &.{ .clock, .stderr });
    defer popActiveModuleContext(token);

    try requireCapability(handle, .clock);
    try std.testing.expect(hasCapability(handle, .stderr));
    try std.testing.expectError(ModuleCapabilityError.MissingModuleCapability, requireCapability(handle, .random));
}

test "active module helpers enforce declared capabilities" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const token = pushActiveModuleContext(ctx, "zttp:test", &.{ .clock, .random, .stderr, .crypto });
    defer popActiveModuleContext(token);

    const now_ms = try nowMsForActiveModule(ctx);
    try std.testing.expect(now_ms >= 0);

    var random_bytes: [8]u8 = undefined;
    try fillRandomForActiveModule(ctx, &random_bytes);

    try writeStderrForActiveModule(ctx, "");

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    try sha256ForActiveModule(ctx, &digest, "data");

    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    try hmacSha256ForActiveModule(ctx, &mac, "data", "key");
}

test "active module helpers reject missing capabilities" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const token = pushActiveModuleContext(ctx, "zttp:test", &.{.clock});
    defer popActiveModuleContext(token);

    var bytes: [8]u8 = undefined;
    try std.testing.expectError(ModuleCapabilityError.MissingModuleCapability, fillRandomForActiveModule(ctx, &bytes));
}

test "FunctionBinding laws defaults to empty" {
    const fb = FunctionBinding{
        .name = "test",
        .func = struct {
            fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
                return value.JSValue.undefined_val;
            }
        }.f,
        .arg_count = 0,
    };
    try std.testing.expectEqual(@as(usize, 0), fb.laws.len);
}

test "findDuplicateLawKind detects repeats" {
    const laws_dup = [_]Law{ .pure, .pure };
    try std.testing.expectEqual(LawKind.pure, findDuplicateLawKind(&laws_dup).?);

    const laws_ok = [_]Law{ .pure, .idempotent_call };
    try std.testing.expect(findDuplicateLawKind(&laws_ok) == null);

    const laws_mixed = [_]Law{
        .{ .inverse_of = "decode" },
        .{ .inverse_of = "other" },
    };
    try std.testing.expectEqual(LawKind.inverse_of, findDuplicateLawKind(&laws_mixed).?);
}

test "findDuplicateLawKind returns null for empty list" {
    const laws = [_]Law{};
    try std.testing.expect(findDuplicateLawKind(&laws) == null);
}

test "hasInverseLawPointingTo matches by target name" {
    const laws = [_]Law{
        .pure,
        .{ .inverse_of = "base64Decode" },
    };
    try std.testing.expect(hasInverseLawPointingTo(&laws, "base64Decode"));
    try std.testing.expect(!hasInverseLawPointingTo(&laws, "base64Encode"));
    try std.testing.expect(!hasInverseLawPointingTo(&laws, ""));
}

test "findFunctionInRegistry locates binding across modules" {
    const dummy = struct {
        fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.undefined_val;
        }
    }.f;

    const bindings = [_]ModuleBinding{
        .{
            .specifier = "zttp:a",
            .name = "a",
            .exports = &.{.{ .name = "alpha", .func = dummy, .arg_count = 0 }},
        },
        .{
            .specifier = "zttp:b",
            .name = "b",
            .exports = &.{.{ .name = "beta", .func = dummy, .arg_count = 0 }},
        },
    };

    try std.testing.expect(findFunctionInRegistry(&bindings, "alpha") != null);
    try std.testing.expect(findFunctionInRegistry(&bindings, "beta") != null);
    try std.testing.expect(findFunctionInRegistry(&bindings, "gamma") == null);
}

test "AbsorbingPattern fields set correctly" {
    const pat = AbsorbingPattern{
        .arg_position = 1,
        .argument_shape = .empty_string_literal,
        .residue = .result_err,
    };
    try std.testing.expectEqual(@as(u8, 1), pat.arg_position);
    try std.testing.expectEqual(AbsorbingPattern.ArgumentShape.empty_string_literal, pat.argument_shape);
    try std.testing.expectEqual(AbsorbingPattern.Residue.result_err, pat.residue);
}

test "Law union carries inverse_of payload" {
    const law: Law = .{ .inverse_of = "decode" };
    switch (law) {
        .inverse_of => |target| try std.testing.expectEqualStrings("decode", target),
        else => try std.testing.expect(false),
    }
}

test "validateBindings accepts paired inverse_of laws" {
    const dummy = struct {
        fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.undefined_val;
        }
    }.f;

    comptime {
        const bindings = [_]ModuleBinding{.{
            .specifier = "zttp:codec",
            .name = "codec",
            .exports = &.{
                .{
                    .name = "encode",
                    .func = dummy,
                    .arg_count = 1,
                    .param_types = &.{.string},
                    .param_names = &.{"input"},
                    .effect = .none,
                    .laws = &.{ .pure, .{ .inverse_of = "decode" } },
                },
                .{
                    .name = "decode",
                    .func = dummy,
                    .arg_count = 1,
                    .param_types = &.{.string},
                    .param_names = &.{"input"},
                    .effect = .none,
                    .laws = &.{ .pure, .{ .inverse_of = "encode" } },
                },
            },
        }};
        validateBindings(&bindings);
    }
}

test "validateBindings accepts idempotent_call on write-effect function" {
    const dummy = struct {
        fn f(_: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.undefined_val;
        }
    }.f;

    comptime {
        const bindings = [_]ModuleBinding{.{
            .specifier = "zttp:kv",
            .name = "kv",
            .exports = &.{
                .{
                    .name = "kvSet",
                    .func = dummy,
                    .arg_count = 2,
                    .param_types = &.{ .string, .string },
                    .param_names = &.{ "key", "value" },
                    .effect = .write,
                    .laws = &.{.idempotent_call},
                },
            },
        }};
        validateBindings(&bindings);
    }
}

// Sandbox invariant: when a NativeFn produced by wrapModuleFnWithCapabilities
// is invoked through its function pointer (the same path used by both the
// interpreter's doCall .none branch and the JIT slow-path jitCall), the
// wrapper's Context-owned active-module-scope push must fire before the inner
// user_fn observes the capability set. The interpreter's hot-builtin bypass
// in interpreter/call.zig only fires for pure-function BuiltinIds (Math.*,
// JSON.*, string slice/indexOf, parseInt/parseFloat), none of which consult
// capabilities. If a future change broke that chain - by inlining a
// capability-requiring builtin into the bypass switch, or by routing past
// the wrapped pointer - this test would fail because the inner function would
// observe an empty active context.

// Policy gating: the four `allows*ForActiveModule` helpers are the only
// path SDK consumers reach to ask the runtime policy whether a given
// name/host is admitted. The Context-owned active scope must declare
// `.policy_check` (rule: a module that consults policy must say so in
// its binding), and the underlying `ctx.capability_policy` decides
// allow vs deny per category. These tests pin both halves so a future
// refactor that drops either gate fails closed.
test "allowsEnvForActiveModule denies when policy enabled and name not in allowlist" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    ctx.capability_policy = .{
        .env = .{ .enabled = true, .values = &[_][]const u8{"ALLOWED"} },
    };

    const token = pushActiveModuleContext(ctx, "zttp:env-test", &.{.policy_check});
    defer popActiveModuleContext(token);

    try std.testing.expect(try allowsEnvForActiveModule(ctx, "ALLOWED"));
    try std.testing.expect(!try allowsEnvForActiveModule(ctx, "DENIED"));
}

test "allowsEnvForActiveModule allows everything when policy section is disabled" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();
    // ctx.capability_policy is default: env.enabled = false → permissive

    const token = pushActiveModuleContext(ctx, "zttp:env-test", &.{.policy_check});
    defer popActiveModuleContext(token);

    try std.testing.expect(try allowsEnvForActiveModule(ctx, "ANYTHING"));
}

test "allowsEnvForActiveModule fails closed when active module lacks policy_check" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Active module declares clock but not policy_check.
    const token = pushActiveModuleContext(ctx, "zttp:env-test", &.{.clock});
    defer popActiveModuleContext(token);

    try std.testing.expectError(
        ModuleCapabilityError.MissingModuleCapability,
        allowsEnvForActiveModule(ctx, "DENIED"),
    );
}

const sdk = @import("zttp-sdk");

const SdkStateProbe = struct {
    handle: *sdk.ModuleHandle,
    slot: usize,
    cleanup_count: usize = 0,
    callback_tag: ?CallbackTag = null,
    read_returned_null_during_cleanup: bool = false,

    const CallbackTag = enum { first, second };

    fn cleanupFirst(ptr: *anyopaque) callconv(.c) void {
        recordCleanup(ptr, .first);
    }

    fn cleanupSecond(ptr: *anyopaque) callconv(.c) void {
        recordCleanup(ptr, .second);
    }

    fn recordCleanup(ptr: *anyopaque, tag: CallbackTag) void {
        const probe: *SdkStateProbe = @ptrCast(@alignCast(ptr));
        probe.cleanup_count += 1;
        probe.callback_tag = tag;
        probe.read_returned_null_during_cleanup = sdk.getModuleState(
            probe.handle,
            SdkStateProbe,
            probe.slot,
        ) == null;
    }
};

test "SDK module state slots are active-module scoped" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    var ctx_live = true;
    defer if (ctx_live) ctx.deinit();
    const handle = contextToHandle(ctx);
    const sdk_handle: *sdk.ModuleHandle = @ptrCast(ctx);
    const sql_slot = @backingInt(module_slots.Slot.sql);
    const cache_slot = @backingInt(module_slots.Slot.cache);
    var installed: SdkStateProbe = .{ .handle = sdk_handle, .slot = sql_slot };
    var rejected: SdkStateProbe = .{ .handle = sdk_handle, .slot = sql_slot };

    try std.testing.expect(!activeModuleOwnsStateSlot(handle, sql_slot));
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.setModuleState(sdk_handle, sql_slot, &rejected, SdkStateProbe.cleanupSecond),
    );
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == null);

    _ = pushActiveModuleContext(ctx, "zttp:cache", &.{});
    try std.testing.expect(!activeModuleOwnsStateSlot(handle, sql_slot));
    try std.testing.expect(activeModuleOwnsStateSlot(handle, cache_slot));
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.setModuleState(sdk_handle, sql_slot, &rejected, SdkStateProbe.cleanupSecond),
    );

    _ = pushActiveModuleContext(ctx, "zttp:sql", &.{});
    try std.testing.expect(activeModuleOwnsStateSlot(handle, sql_slot));
    try std.testing.expect(!activeModuleOwnsStateSlot(handle, cache_slot));
    try std.testing.expect(!activeModuleOwnsStateSlot(handle, 15));
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == null);
    try sdk.setModuleState(sdk_handle, sql_slot, &installed, SdkStateProbe.cleanupFirst);
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == &installed);

    _ = pushActiveModuleContext(ctx, "zttp:cache", &.{});
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == null);
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.setModuleState(sdk_handle, sql_slot, &rejected, SdkStateProbe.cleanupSecond),
    );

    // Discard restore tokens because teardown must clear the final SQL scope.
    _ = pushActiveModuleContext(ctx, "zttp:sql", &.{});
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == &installed);

    inline for (.{ context.MAX_MODULE_STATE_SLOTS, std.math.maxInt(usize) }) |invalid_slot| {
        try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, invalid_slot) == null);
        try std.testing.expectError(
            error.OutOfMemory,
            sdk.setModuleState(sdk_handle, invalid_slot, &rejected, SdkStateProbe.cleanupSecond),
        );
    }

    ctx.deinit();
    ctx_live = false;
    try std.testing.expectEqual(@as(usize, 1), installed.cleanup_count);
    try std.testing.expectEqual(SdkStateProbe.CallbackTag.first, installed.callback_tag.?);
    try std.testing.expect(installed.read_returned_null_during_cleanup);
    try std.testing.expectEqual(@as(usize, 0), rejected.cleanup_count);
    try std.testing.expect(rejected.callback_tag == null);
}

test "SDK module state is isolated by Context lifetime" {
    const allocator = std.testing.allocator;
    var gc_a = try gc.GC.init(allocator, .{});
    defer gc_a.deinit();
    const ctx_a = try context.Context.init(allocator, &gc_a, .{});
    var ctx_a_live = true;
    defer if (ctx_a_live) ctx_a.deinit();

    var gc_b = try gc.GC.init(allocator, .{});
    defer gc_b.deinit();
    const ctx_b = try context.Context.init(allocator, &gc_b, .{});
    var ctx_b_live = true;
    defer if (ctx_b_live) ctx_b.deinit();

    const handle_a: *sdk.ModuleHandle = @ptrCast(ctx_a);
    const handle_b: *sdk.ModuleHandle = @ptrCast(ctx_b);
    const sql_slot = @backingInt(module_slots.Slot.sql);
    var probe_a: SdkStateProbe = .{ .handle = handle_a, .slot = sql_slot };
    var probe_b: SdkStateProbe = .{ .handle = handle_b, .slot = sql_slot };

    // Leave both SQL scopes active so each teardown must revoke its authority.
    _ = pushActiveModuleContext(ctx_a, "zttp:sql", &.{});
    _ = pushActiveModuleContext(ctx_b, "zttp:sql", &.{});
    try sdk.setModuleState(handle_a, sql_slot, &probe_a, SdkStateProbe.cleanupFirst);
    try sdk.setModuleState(handle_b, sql_slot, &probe_b, SdkStateProbe.cleanupSecond);
    try std.testing.expect(sdk.getModuleState(handle_a, SdkStateProbe, sql_slot) == &probe_a);
    try std.testing.expect(sdk.getModuleState(handle_b, SdkStateProbe, sql_slot) == &probe_b);

    ctx_a.deinit();
    ctx_a_live = false;
    try std.testing.expectEqual(@as(usize, 1), probe_a.cleanup_count);
    try std.testing.expectEqual(SdkStateProbe.CallbackTag.first, probe_a.callback_tag.?);
    try std.testing.expect(probe_a.read_returned_null_during_cleanup);
    try std.testing.expectEqual(@as(usize, 0), probe_b.cleanup_count);
    try std.testing.expect(sdk.getModuleState(handle_b, SdkStateProbe, sql_slot) == &probe_b);

    ctx_b.deinit();
    ctx_b_live = false;
    try std.testing.expectEqual(@as(usize, 1), probe_b.cleanup_count);
    try std.testing.expectEqual(SdkStateProbe.CallbackTag.second, probe_b.callback_tag.?);
    try std.testing.expect(probe_b.read_returned_null_during_cleanup);
}

test "SDK module state allocation failure preserves caller ownership" {
    const backing_allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    const allocator = failing.allocator();
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    var ctx_live = true;
    defer if (ctx_live) ctx.deinit();

    const sdk_handle: *sdk.ModuleHandle = @ptrCast(ctx);
    const sql_slot = @backingInt(module_slots.Slot.sql);
    var probe: SdkStateProbe = .{ .handle = sdk_handle, .slot = sql_slot };
    _ = pushActiveModuleContext(ctx, "zttp:sql", &.{});

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        sdk.setModuleState(sdk_handle, sql_slot, &probe, SdkStateProbe.cleanupFirst),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(sdk.getModuleState(sdk_handle, SdkStateProbe, sql_slot) == null);
    try std.testing.expectEqual(@as(usize, 0), probe.cleanup_count);

    SdkStateProbe.cleanupFirst(&probe);
    try std.testing.expectEqual(@as(usize, 1), probe.cleanup_count);
    try std.testing.expect(probe.read_returned_null_during_cleanup);

    // Keep SQL active until teardown. Context must not own the rejected probe.
    ctx.deinit();
    ctx_live = false;
    try std.testing.expectEqual(@as(usize, 1), probe.cleanup_count);
}

test "SDK sqlite opens require canonical allowlist entry" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const token = pushActiveModuleContext(ctx, "zttp:sql", &.{.sqlite});
    defer popActiveModuleContext(token);

    try std.testing.expectError(
        error.SqlitePathNotAllowed,
        openSqliteDbChecked(ctx, "default-deny-test.sqlite"),
    );
}

test "allowsCacheNamespaceForActiveModule denies namespaces outside the allowlist" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    ctx.capability_policy = .{
        .cache = .{ .enabled = true, .values = &[_][]const u8{"sessions"} },
    };

    const token = pushActiveModuleContext(ctx, "zttp:cache-test", &.{.policy_check});
    defer popActiveModuleContext(token);

    try std.testing.expect(try allowsCacheNamespaceForActiveModule(ctx, "sessions"));
    try std.testing.expect(!try allowsCacheNamespaceForActiveModule(ctx, "secrets"));
}

test "allowsSqlQueryForActiveModule denies queries outside the allowlist" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    ctx.capability_policy = .{
        .sql = .{ .enabled = true, .values = &[_][]const u8{"listTodos"}, .queries = &.{} },
    };

    const token = pushActiveModuleContext(ctx, "zttp:sql-test", &.{.policy_check});
    defer popActiveModuleContext(token);

    try std.testing.expect(try allowsSqlQueryForActiveModule(ctx, "listTodos"));
    try std.testing.expect(!try allowsSqlQueryForActiveModule(ctx, "dropEverything"));
    // Policy JSON allow_queries entries have no operation metadata, so
    // they are explicit read/write overrides. Generated contract query
    // entries are split in handler_policy.zig.
    try std.testing.expect(try allowsSqlWriteForActiveModule(ctx, "listTodos"));
    try std.testing.expect(!try allowsSqlWriteForActiveModule(ctx, "dropEverything"));
}

// Egress is unlike the other four policy categories: there is no
// `allowsEgressHostForActiveModule` wrapper. Outbound `fetch` is a
// runtime-initiated check (see zruntime.zig calling
// `ctx.capability_policy.allowsEgressEndpoint(endpoint)`), not an SDK module
// call routed through the active Context scope, so it does not require
// `.policy_check`. This test pins the raw `RuntimePolicy.allowsEgressEndpoint`
// semantics (an exact match against an already-normalized endpoint). If a
// future change moves outbound checks into an SDK module, the parity (a
// `*ForActiveModule` wrapper, gated by `.policy_check`) must be added at the
// same time.
test "allowsEgressEndpoint compares the destination, not the name" {
    const policy: handler_policy.RuntimePolicy = .{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"https://api.example.com:443"} },
    };
    try std.testing.expect(policy.allowsEgressEndpoint("https://api.example.com:443"));
    // Case folding happened in `zts.endpoint`, before this comparison. A value
    // that arrives unnormalized matches nothing, which denies.
    try std.testing.expect(!policy.allowsEgressEndpoint("HTTPS://API.EXAMPLE.COM:443"));
    // The same host under another scheme or port is another server.
    try std.testing.expect(!policy.allowsEgressEndpoint("http://api.example.com:80"));
    try std.testing.expect(!policy.allowsEgressEndpoint("https://evil.example.com:443"));
}
