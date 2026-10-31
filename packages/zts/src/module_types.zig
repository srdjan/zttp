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
//! pre-rebase:docs/archive/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");
const mb = @import("zts-base").module_descriptors;
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
        .object, .result_list, .result_fn => object_ref,
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

/// `FetchOptions` (spec 7.2), registered before the export loop so a declared
/// signature naming it resolves, and put in the alias table so a handler can
/// annotate with it.
///
/// It is not section 7.2's shape verbatim, and the two differences are
/// measured rather than chosen.
///
/// `timeoutMs` is absent. Section 7.2 names it and `runtime_http.zig` reads no
/// such field, so declaring it would type a value that does nothing - a type
/// that lies about the runtime is worse than one that omits a feature.
///
/// `query` and `maxResponseBytes` are present and the spec omits them. Both
/// ship and both are read; `query` in particular is what keeps an egress host
/// a compile-time literal while its values vary per request, which is the
/// property `examples/fetch/weather-app.ts` exists to prove. Refusing them
/// would delete a working contract guarantee to match a shorter list.
///
/// `body` is `string | Bytes`, which is section 7.2's own type and was a lie
/// until this commit: the runtime answered `InvalidBody` for a Bytes. It
/// accepts one now and sends its octets unchanged.
///
/// `headers` is the opaque `object` where section 7.2 writes `Dict<string,
/// string>`. `runtime_http.zig` reads the header map by walking an object's
/// properties and has no Dict path, so the spec's type would refuse the
/// object-literal form every handler uses and admit a Dict the runtime would
/// ignore - wrong in both directions at once. Aligning the two ends is a
/// runtime change and belongs with the phase 7 pass that also closes
/// `timeoutMs`.
fn registerFetchOptions(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    if (env.getTypeAlias("FetchOptions") != null) return;

    const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    var method_literals: [methods.len]TypeIndex = undefined;
    for (methods, 0..) |name, i| {
        method_literals[i] = pool.addLiteralString(allocator, name);
    }
    const method_union = pool.addUnion(allocator, &method_literals);
    const body_type = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_bytes });

    const options = pool.addRecord(allocator, &.{
        optionalField(pool, allocator, "method", method_union),
        optionalField(pool, allocator, "headers", object_refFor(pool, allocator)),
        optionalField(pool, allocator, "body", body_type),
        optionalField(pool, allocator, "query", object_refFor(pool, allocator)),
        optionalField(pool, allocator, "maxResponseBytes", pool.idx_number),
    });
    if (options == null_type_idx) return;
    env.putTypeAlias("FetchOptions", options);
}

fn object_refFor(pool: *TypePool, allocator: std.mem.Allocator) TypeIndex {
    return pool.addRef(allocator, "object");
}

fn optionalField(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8, type_idx: TypeIndex) type_pool_mod.RecordField {
    const n = pool.addName(allocator, name);
    return .{
        .name_start = n.start,
        .name_len = n.len,
        .type_idx = type_idx,
        .optional = true,
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

/// Populate the TypeEnv with full type signatures for all virtual module exports.
/// Reads from the builtin_modules registry instead of hardcoded tables.
pub fn populateModuleTypes(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    // Build shared types
    const ok_n = pool.addName(allocator, "ok");
    const val_n = pool.addName(allocator, "value");
    const err_n = pool.addName(allocator, "error");
    const errs_n = pool.addName(allocator, "errors");
    const result_type = pool.markResultRecord(allocator, pool.addRecord(allocator, &.{
        .{ .name_start = ok_n.start, .name_len = ok_n.len, .type_idx = pool.idx_boolean, .optional = false },
        .{ .name_start = val_n.start, .name_len = val_n.len, .type_idx = pool.idx_unknown, .optional = true },
        .{ .name_start = err_n.start, .name_len = err_n.len, .type_idx = pool.idx_string, .optional = true },
        .{ .name_start = errs_n.start, .name_len = errs_n.len, .type_idx = pool.idx_unknown, .optional = true },
    }));
    // `parseJson` and `parseJsonBytes` answer the same record with a JSON
    // `value` (Decision 44a): the document is a Dict at run time, so a member
    // or index read on it is refused. The `.result` kind cannot carry that, so
    // the two exports are named.
    const json_result_type = pool.markResultRecord(allocator, pool.addRecord(allocator, &.{
        .{ .name_start = ok_n.start, .name_len = ok_n.len, .type_idx = pool.idx_boolean, .optional = false },
        .{ .name_start = val_n.start, .name_len = val_n.len, .type_idx = pool.idx_json_value, .optional = true },
        .{ .name_start = err_n.start, .name_len = err_n.len, .type_idx = pool.idx_string, .optional = true },
        .{ .name_start = errs_n.start, .name_len = errs_n.len, .type_idx = pool.idx_unknown, .optional = true },
    }));
    const optional_string = pool.addNullable(allocator, pool.idx_string);
    const object_ref = pool.addRef(allocator, "object");
    const optional_object = pool.addNullable(allocator, object_ref);

    registerFetchOptions(env, pool, allocator);

    // Register all function signatures from the module registry
    for (builtin_modules.metadata) |binding| {
        for (binding.exports) |func| {
            // A declared signature overrides the coarse kind at every
            // position. `zttp:fetch` was a hand-built special case here -
            // a response record assembled in Zig and a parameter list
            // truncated to one, so `init` typed as nothing at all. It is the
            // first customer of the general mechanism rather than a case the
            // mechanism has to keep working around.
            const is_parse_json = std.mem.eql(u8, binding.specifier, "zttp:json") and (std.mem.eql(u8, func.name, "parseJson") or std.mem.eql(u8, func.name, "parseJsonBytes"));
            const return_type_idx = if (func.signature) |declared|
                env.resolveType(declared.returns)
            else if (is_parse_json)
                json_result_type
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
            const owned = env.internName(func.name);
            env.fn_sigs_by_name.put(allocator, owned, sig) catch env.markAllocationFailure();
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

test "FetchOptions names what the runtime reads, and only that" {
    // The list is measured against `runtime_http.zig`, not copied from spec
    // The type includes the shipped query and maxResponseBytes options.
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const options = env.getTypeAlias("FetchOptions") orelse return error.MissingFetchOptions;
    const expected = [_][]const u8{ "method", "headers", "body", "query", "maxResponseBytes" };
    const fields = pool.getRecordFields(options);
    try std.testing.expectEqual(expected.len, fields.len);
    for (expected, fields) |name, field| {
        try std.testing.expectEqualStrings(name, pool.getName(field.name_start, field.name_len));
        // Every field is optional: `fetch(url, {})` is a valid call.
        try std.testing.expect(field.optional);
    }

    // `timeoutMs` is absent on purpose. A field the runtime never reads would
    // be a type that lies about what the call does.
    for (fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, "timeoutMs", pool.getName(field.name_start, field.name_len)));
    }

    // The method is the seven literals spec 7.2 lists, so an eighth is a
    // compile-time refusal rather than an `InvalidMethod` at run time.
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(fields[0].type_idx).?);
    try std.testing.expectEqual(@as(usize, 7), pool.getUnionMembers(fields[0].type_idx).len);

    // The body is spec 7.2's own `string | Bytes`, which the runtime now
    // accepts - it answered `InvalidBody` for a Bytes before this commit.
    const body = fields[2].type_idx;
    try std.testing.expect(env.isAssignableTo(pool.idx_string, body));
    try std.testing.expect(env.isAssignableTo(pool.idx_bytes, body));
    try std.testing.expect(!env.isAssignableTo(pool.idx_number, body));
}

test "fetch reads FetchOptions at its second position" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const options = env.getTypeAlias("FetchOptions") orelse return error.MissingFetchOptions;
    const fetch_sig = env.getFnSigByName("fetch") orelse return error.MissingFetch;
    try std.testing.expectEqual(@as(u8, 2), fetch_sig.param_count);
    try std.testing.expectEqual(options, fetch_sig.param_types[1]);

    // `fetchWithRetry` shares it and keeps its third argument.
    const retry_sig = env.getFnSigByName("fetchWithRetry") orelse return error.MissingFetchWithRetry;
    try std.testing.expectEqual(@as(u8, 3), retry_sig.param_count);
    try std.testing.expectEqual(options, retry_sig.param_types[1]);
    try std.testing.expectEqual(@as(u8, 1), retry_sig.required_param_count orelse retry_sig.param_count);
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

test "fetch takes its init object optionally, the way a GET is written" {
    // The binding spells both parameters. `fetch(url)` must still type-check,
    // or a plain GET fails with "expected 2, got 1" - a program the runtime
    // accepts and the checker refuses.
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateModuleTypes(&env, &pool, allocator);

    const sig = env.getFnSigByName("fetch") orelse return error.MissingFetch;
    try std.testing.expectEqual(@as(u8, 2), sig.param_count);
    try std.testing.expectEqual(@as(u8, 1), sig.required_param_count orelse sig.param_count);
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

/// Test double: fails the allocation at `fail_index` and no other, so a single
/// transient OOM is not masked by every later allocation also failing, which
/// is what std.testing.FailingAllocator does.
const FailOnceAllocator = struct {
    parent: std.mem.Allocator,
    fail_index: usize,
    index: usize = 0,
    failed: bool = false,

    fn allocator(self: *FailOnceAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        defer self.index += 1;
        if (self.index == self.fail_index) {
            self.failed = true;
            return null;
        }
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "a module signature the environment could not hold leaves it unhealthy" {
    // Same shape as the request readers: a signature dropped under OOM must
    // poison the environment rather than read as an export with no type.
    var fail_index: usize = 0;
    while (fail_index < 100_000) : (fail_index += 1) {
        var failing: FailOnceAllocator = .{ .parent = std.testing.allocator, .fail_index = fail_index };
        const allocator = failing.allocator();
        var pool = TypePool.init(allocator);
        defer pool.deinit(allocator);
        var env = TypeEnv.init(allocator, &pool);
        defer env.deinit();

        populateModuleTypes(&env, &pool, allocator);

        if (!failing.failed) break;
        const healthy = !std.meta.isError(env.ensureHealthy()) and !std.meta.isError(pool.ensureHealthy());
        if (!healthy) continue;
        for ([_][]const u8{ "sha256", "env" }) |name| {
            try std.testing.expect(env.getFnSigByName(name) != null);
        }
    } else return error.TestUnexpectedResult;
    try std.testing.expect(fail_index > 0);
}
