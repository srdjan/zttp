//! Virtual Module Type Declarations
//!
//! Defines full function signatures for all virtual module exports.
//! Used by the type checker to validate argument types and infer return types
//! for calls to zttp:* module functions. Return types use T | undefined for
//! optional values (no null in user-facing API).
//!
//! Replaces the hardcoded module_return_types table in bool_checker when
//! the type checker is active.
//!
//! This file sat under `modules/internal/` and was re-exported by
//! `modules/root.zig`, which made the engine's module system import the type
//! pool and the type environment. Nothing in the engine calls it: its only
//! callers are the type checker, the handler verifier, and the analysis
//! pipeline. It is analysis code that happened to be filed with the module
//! implementations. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");
const mb = @import("zts-engine").module_binding;
const builtin_modules = @import("zts-engine").builtin_modules;

const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const TypeEnv = type_env_mod.TypeEnv;
const FuncParam = type_pool_mod.FuncParam;

/// Map a ReturnKind from the binding spec to a TypeIndex in the type pool.
fn mapReturnKind(
    kind: mb.ReturnKind,
    pool: *TypePool,
    result_type: TypeIndex,
    optional_string: TypeIndex,
    object_ref: TypeIndex,
    optional_object: TypeIndex,
) TypeIndex {
    return switch (kind) {
        .boolean => pool.idx_boolean,
        .number => pool.idx_number,
        .string => pool.idx_string,
        .object => object_ref,
        .undefined => pool.idx_undefined,
        .unknown => pool.idx_unknown,
        .optional_string => optional_string,
        .optional_object => optional_object,
        .result => result_type,
    };
}

fn addParam(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8, type_idx: TypeIndex) FuncParam {
    const n = pool.addName(allocator, name);
    return .{
        .name_start = n.start,
        .name_len = n.len,
        .type_idx = type_idx,
        .optional = false,
    };
}

fn addField(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8, type_idx: TypeIndex) type_pool_mod.RecordField {
    const n = pool.addName(allocator, name);
    return .{
        .name_start = n.start,
        .name_len = n.len,
        .type_idx = type_idx,
        .optional = false,
    };
}

fn addFetchResponseType(pool: *TypePool, allocator: std.mem.Allocator, optional_string: TypeIndex) TypeIndex {
    const name_param = addParam(pool, allocator, "name", pool.idx_string);
    const headers_get = pool.addFunctionWithReturn(allocator, &.{name_param}, optional_string);
    const headers_has = pool.addFunctionWithReturn(allocator, &.{name_param}, pool.idx_boolean);
    const headers = pool.addRecord(allocator, &.{
        addField(pool, allocator, "get", headers_get),
        addField(pool, allocator, "has", headers_has),
    });

    const no_params: []const FuncParam = &.{};
    const json_fn = pool.addFunctionWithReturn(allocator, no_params, pool.idx_unknown);
    const text_fn = pool.addFunctionWithReturn(allocator, no_params, pool.idx_string);

    return pool.addRecord(allocator, &.{
        addField(pool, allocator, "ok", pool.idx_boolean),
        addField(pool, allocator, "status", pool.idx_number),
        addField(pool, allocator, "statusText", pool.idx_string),
        addField(pool, allocator, "body", pool.idx_string),
        addField(pool, allocator, "headers", headers),
        addField(pool, allocator, "json", json_fn),
        addField(pool, allocator, "text", text_fn),
    });
}

/// The type-parameter name the callback-shaped exports are given. It appears in
/// no source text: a handler writes `run(key, () => ...)` and never names the
/// parameter, so the name only has to be stable for `unify`, which matches a
/// pattern node against the signature's declared parameters by name.
const RETURN_PARAM_NAME = "T";

/// Rewrite `sig` into the one-parameter generic signature that `returns_from_param`
/// describes, so the checker infers the return type per call site rather than
/// reading the fixed `unknown` the binding declares for every other consumer.
///
/// `call_result` re-declares the named argument as `() => T` and returns `T`;
/// `identity` declares it `T` and returns `T`. The parameter list the callback
/// is declared with is empty on purpose - `unify` walks a function pattern only
/// as far as both sides have parameters, then unifies the return types, so an
/// empty list binds `T` from any arity of callback the author writes.
fn applyReturnFromParam(
    func: mb.FunctionBinding,
    sig: *type_env_mod.FunctionSig,
    env: *TypeEnv,
    pool: *TypePool,
    allocator: std.mem.Allocator,
) void {
    const from = func.returns_from_param orelse return;
    if (from.param_index >= sig.param_count) return;

    const t = pool.addGenericParam(allocator, RETURN_PARAM_NAME);
    if (t == null_type_idx) return;

    sig.param_types[from.param_index] = switch (from.kind) {
        .call_result => pool.addFunctionWithReturn(allocator, &.{}, t),
        .identity => t,
    };
    sig.return_type = t;
    sig.type_params[0] = .{
        .name = env.internName(RETURN_PARAM_NAME),
        .idx = t,
        .constraint = null_type_idx,
    };
    sig.type_param_count = 1;
}

/// Populate the TypeEnv with full type signatures for all virtual module exports.
/// Reads from the builtin_modules registry instead of hardcoded tables.
pub fn populateModuleTypes(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    // Build shared types
    const ok_n = pool.addName(allocator, "ok");
    const val_n = pool.addName(allocator, "value");
    const err_n = pool.addName(allocator, "error");
    const errs_n = pool.addName(allocator, "errors");
    const result_type = pool.addRecord(allocator, &.{
        .{ .name_start = ok_n.start, .name_len = ok_n.len, .type_idx = pool.idx_boolean, .optional = false },
        .{ .name_start = val_n.start, .name_len = val_n.len, .type_idx = pool.idx_unknown, .optional = true },
        .{ .name_start = err_n.start, .name_len = err_n.len, .type_idx = pool.idx_string, .optional = true },
        .{ .name_start = errs_n.start, .name_len = errs_n.len, .type_idx = pool.idx_unknown, .optional = true },
    });
    const optional_string = pool.addNullable(allocator, pool.idx_string);
    const object_ref = pool.addRef(allocator, "object");
    const optional_object = pool.addNullable(allocator, object_ref);
    const fetch_response = addFetchResponseType(pool, allocator, optional_string);

    // Register all function signatures from the module registry
    for (builtin_modules.all) |binding| {
        for (binding.exports) |func| {
            const is_fetch = std.mem.eql(u8, binding.specifier, "zttp:fetch") and
                std.mem.eql(u8, func.name, "fetch");
            const return_type_idx = if (is_fetch) fetch_response else mapReturnKind(
                func.returns,
                pool,
                result_type,
                optional_string,
                object_ref,
                optional_object,
            );

            var sig = type_env_mod.FunctionSig{};
            sig.return_type = return_type_idx;
            const param_len = if (is_fetch) @min(func.param_types.len, 1) else func.param_types.len;
            const param_count: u8 = @intCast(@min(param_len, 16));
            sig.param_count = param_count;
            if (func.required_arg_count) |required_arg_count| {
                sig.required_param_count = @intCast(@min(required_arg_count, param_count));
            }
            for (func.param_types[0..param_count], 0..) |pt, i| {
                sig.param_types[i] = mapReturnKind(
                    pt,
                    pool,
                    result_type,
                    optional_string,
                    object_ref,
                    optional_object,
                );
            }

            applyReturnFromParam(func, &sig, env, pool, allocator);

            const owned = env.internName(func.name);
            env.fn_sigs_by_name.put(allocator, owned, sig) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "populateModuleTypes registers signatures" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    // sha256 should be registered: (string) => string
    const sha256_sig = env.getFnSigByName("sha256");
    try std.testing.expect(sha256_sig != null);
    try std.testing.expectEqual(@as(u8, 1), sha256_sig.?.param_count);
    try std.testing.expectEqual(pool.idx_string, sha256_sig.?.param_types[0]);
    try std.testing.expectEqual(pool.idx_string, sha256_sig.?.return_type);

    // env should be registered: (string) => string | null
    const env_sig = env.getFnSigByName("env");
    try std.testing.expect(env_sig != null);
    try std.testing.expectEqual(@as(u8, 1), env_sig.?.param_count);
    // Return type should be nullable
    const ret_tag = pool.getTag(env_sig.?.return_type);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_nullable, ret_tag.?);
}

test "populateModuleTypes keeps jwtVerify algorithm optional" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const sig = env.getFnSigByName("jwtVerify") orelse return error.MissingJwtVerify;
    try std.testing.expectEqual(@as(u8, 3), sig.param_count);
    try std.testing.expectEqual(@as(u8, 2), sig.required_param_count orelse sig.param_count);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[0]);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[1]);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[2]);
}

test "populateModuleTypes declares validateObject payload as object" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const sig = env.getFnSigByName("validateObject") orelse return error.MissingValidateObject;
    try std.testing.expectEqual(@as(u8, 2), sig.param_count);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[0]);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(sig.param_types[1]).?);
    try std.testing.expectEqualStrings("object", pool.getRefName(sig.param_types[1]));
}

test "populateModuleTypes keeps fetchWithRetry options optional" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const sig = env.getFnSigByName("fetchWithRetry") orelse return error.MissingFetchWithRetry;
    try std.testing.expectEqual(@as(u8, 3), sig.param_count);
    try std.testing.expectEqual(@as(u8, 1), sig.required_param_count orelse sig.param_count);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[0]);
}
