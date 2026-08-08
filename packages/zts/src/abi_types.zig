//! Types for the globals the runtime hands a handler, as opposed to the
//! virtual-module exports `module_types.zig` describes.
//!
//! `Response` had no type at all. A handler declaring `: Response` produced an
//! unresolved `t_ref`, `Response.json(...)` inferred nothing, and the return
//! check compares nothing when either side is absent - so every handler in the
//! repository passed its return check by never running it. That was invisible
//! while an unresolved name answered assignable; under D1 amendment A1 it is
//! the difference between a proof and a skipped question.
//!
//! This is today's shipped surface, not spec section 7.2. The spec renames the
//! constructors (`responseJson<T>` returning `Result<Response, JsonError>`) and
//! types the request side over `Bytes`, `Dict`, and `JsonValue`, none of which
//! the engine has yet. Describing what ships now is what lets the return check
//! run now; phase 5 replaces the operations, not this file's reason to exist.

const std = @import("std");
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");

const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const TypeEnv = type_env_mod.TypeEnv;

/// The name a handler writes to annotate its return type.
pub const RESPONSE_TYPE_NAME = "Response";

/// The four constructors on the `Response` global. Each returns a `Response`,
/// and there is no other way for a handler to make one.
pub const RESPONSE_CONSTRUCTORS = [_][]const u8{ "json", "text", "html", "redirect" };

fn addField(
    pool: *TypePool,
    allocator: std.mem.Allocator,
    name: []const u8,
    type_idx: TypeIndex,
) type_pool_mod.RecordField {
    const n = pool.addName(allocator, name);
    return .{
        .name_start = n.start,
        .name_len = n.len,
        .type_idx = type_idx,
        .optional = false,
    };
}

/// Register the handler-facing global types in `env`.
///
/// The fields are the ones `http.zig` sets on a constructed response, read off
/// the constructor rather than guessed.
///
/// `Response` is branded nominal, which buys less here than the word suggests
/// and is still worth having. D1 amendment A5 keeps a nominal record reachable
/// structurally from a plain record, because a capability interface has to be
/// satisfiable by an object literal - so an object carrying all four fields
/// with the right types is assignable to `Response`. What the brand does buy is
/// the other direction and the sibling direction: `Response` is not
/// interchangeable with another branded record of the same shape, and a
/// response is not silently a `{ status: number }` an author declared.
pub fn populateHandlerAbiTypes(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    if (env.getTypeAlias(RESPONSE_TYPE_NAME) != null) return;

    const shape = pool.addRecord(allocator, &.{
        addField(pool, allocator, "body", pool.idx_string),
        addField(pool, allocator, "status", pool.idx_number),
        addField(pool, allocator, "statusText", pool.idx_string),
        addField(pool, allocator, "ok", pool.idx_boolean),
    });
    if (shape == null_type_idx) return;

    const response = pool.addNominalAlias(allocator, shape, RESPONSE_TYPE_NAME);
    if (response == null_type_idx) return;
    env.putTypeAlias(RESPONSE_TYPE_NAME, response);
}

/// The registered `Response` type, or `null_type_idx` when nothing registered
/// it. A caller that gets `null_type_idx` infers nothing, which is what the
/// checker did for every response before this file existed.
pub fn responseType(env: *const TypeEnv) TypeIndex {
    return env.getTypeAlias(RESPONSE_TYPE_NAME) orelse null_type_idx;
}

/// True when `name` is one of the `Response` constructors.
pub fn isResponseConstructor(name: []const u8) bool {
    for (RESPONSE_CONSTRUCTORS) |constructor| {
        if (std.mem.eql(u8, name, constructor)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "populateHandlerAbiTypes registers a nominal Response" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);

    const response = responseType(&env);
    try std.testing.expect(response != null_type_idx);
    try std.testing.expect(pool.isNominal(response));
}

test "an object missing a response field is not a Response" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);
    const response = responseType(&env);

    // What a handler that forgot to construct one actually returns.
    const bare = pool.addRecord(allocator, &.{
        addField(&pool, allocator, "status", pool.idx_number),
    });
    try std.testing.expect(!env.isAssignableTo(bare, response));
    try std.testing.expect(env.isAssignableTo(response, response));

    // The brand is not interchangeable with another brand of the same shape.
    const other = pool.addNominalAlias(allocator, response, "NotAResponse");
    try std.testing.expect(!env.isAssignableTo(other, response));
}

test "a handler's Response annotation resolves to the registered type" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);
    const response = responseType(&env);

    // What a `: Response` annotation lowers to before anything resolves it.
    const annotation = pool.addRef(allocator, RESPONSE_TYPE_NAME);
    try std.testing.expect(env.isAssignableTo(response, annotation));
}

test "isResponseConstructor names only the four constructors" {
    try std.testing.expect(isResponseConstructor("json"));
    try std.testing.expect(isResponseConstructor("redirect"));
    try std.testing.expect(!isResponseConstructor("clone"));
}
