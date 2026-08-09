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
    allocator: std.mem.Allocator,
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
        .optional_number => pool.addNullable(allocator, pool.idx_number),
        .result => result_type,
        // Coarse for the same reason `.result` is: a binding cannot spell the
        // export's type parameters, so the value type is the top type until
        // module signatures can carry them.
        .dict => pool.addDict(allocator, pool.idx_unknown, pool.idx_unknown),
        // Not coarse: `Bytes` has no parameters, so the kind is the type.
        .bytes => pool.idx_bytes,
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

    // Register all function signatures from the module registry
    for (builtin_modules.all) |binding| {
        for (binding.exports) |func| {
            // A declared signature overrides the coarse kind at every
            // position. `zttp:fetch` was a hand-built special case here -
            // a response record assembled in Zig and a parameter list
            // truncated to one, so `init` typed as nothing at all. It is the
            // first customer of the general mechanism rather than a case the
            // mechanism has to keep working around.
            const return_type_idx = if (func.signature) |declared|
                env.resolveType(declared.returns)
            else
                mapReturnKind(
                    func.returns,
                    pool,
                    allocator,
                    result_type,
                    optional_string,
                    object_ref,
                    optional_object,
                );

            var sig = type_env_mod.FunctionSig{};
            sig.return_type = return_type_idx;
            const param_count: u8 = @intCast(@min(func.param_types.len, 16));
            sig.param_count = param_count;
            if (func.required_arg_count) |required_arg_count| {
                sig.required_param_count = @intCast(@min(required_arg_count, param_count));
            }
            for (func.param_types[0..param_count], 0..) |pt, i| {
                sig.param_types[i] = if (func.signature) |declared|
                    env.resolveType(declared.params[i])
                else
                    mapReturnKind(
                        pt,
                        pool,
                        allocator,
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

test "the bytes return kind maps to the Bytes primitive" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const object_ref = pool.addRef(allocator, "object");
    const idx = mapReturnKind(
        .bytes,
        &pool,
        allocator,
        null_type_idx,
        null_type_idx,
        object_ref,
        null_type_idx,
    );

    try std.testing.expectEqual(pool.idx_bytes, idx);
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_bytes, pool.getTag(idx).?);

    // Not the coarse `object` a binding would otherwise have had to declare -
    // which is the difference that makes a Bytes parameter refuse a record.
    try std.testing.expect(idx != object_ref);
}

test "a declared signature builds the precise type, and fetch is its first customer" {
    // `zttp:fetch`.`fetch` was a hand-built special case in this file: a
    // response record assembled in Zig, and a parameter list truncated to one
    // so `init` typed as nothing at all. Both are gone; what replaces them is
    // the text the binding owns.
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const sig = env.getFnSigByName("fetch") orelse return error.MissingFetch;

    // Both parameters, not one. This is the truncation ending.
    try std.testing.expectEqual(@as(u8, 2), sig.param_count);
    try std.testing.expectEqual(pool.idx_string, sig.param_types[0]);
    try std.testing.expect(sig.param_types[1] != null_type_idx);

    // The return type is the record the text spells, with its fields, and not
    // the coarse `object` the binding's `returns` still declares for every
    // other consumer.
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_record, pool.getTag(sig.return_type).?);
    var saw_status = false;
    var saw_headers = false;
    for (pool.getRecordFields(sig.return_type)) |f| {
        const name = pool.getName(f.name_start, f.name_len);
        if (std.mem.eql(u8, name, "status")) {
            saw_status = true;
            try std.testing.expectEqual(pool.idx_number, f.type_idx);
        }
        if (std.mem.eql(u8, name, "headers")) saw_headers = true;
    }
    try std.testing.expect(saw_status);
    try std.testing.expect(saw_headers);

    // The floor: an export with no declared signature still reads the enum, so
    // the override is an override and not a replacement.
    const sha = env.getFnSigByName("sha256") orelse return error.MissingSha256;
    try std.testing.expectEqual(pool.idx_string, sha.return_type);
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
