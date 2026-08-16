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

/// The name a handler writes to annotate its parameter.
pub const REQUEST_TYPE_NAME = "Request";

/// Compiler-owned names that may cross an exported function boundary without
/// a user-declared alias. Keep this registry beside the ABI implementations so
/// a new ABI type cannot require a second handwritten exemption in the strict
/// checker.
pub const boundary_type_names = [_][]const u8{
    REQUEST_TYPE_NAME,
    RESPONSE_TYPE_NAME,
    "Bytes",
    "Dict",
    "JsonValue",
    "Result",
};

/// Whether an annotation starts with one of the fixed application ABI types.
/// Generic arguments and postfix arrays do not change the owning type name.
pub fn isBoundaryTypeAnnotation(annotation: []const u8) bool {
    var text = std.mem.trim(u8, annotation, " \t\r\n");
    if (std.mem.startsWith(u8, text, "readonly")) {
        const after = text["readonly".len..];
        if (after.len > 0 and std.ascii.isWhitespace(after[0])) {
            text = std.mem.trim(u8, after, " \t\r\n");
        }
    }
    for (boundary_type_names) |name| {
        if (!std.mem.startsWith(u8, text, name)) continue;
        const rest = std.mem.trim(u8, text[name.len..], " \t\r\n");
        if (rest.len == 0) return true;
        return switch (rest[0]) {
            '<', '[' => true,
            else => false,
        };
    }
    return false;
}

/// The constructors on the `Response` global. Each returns a `Response`, and
/// there is no other way for a handler to make one.
///
/// `rawJson` was missing from this list while `object.Atom.rawJson` existed,
/// `contract_builder.zig` handled it, and `handler_analyzer.zig` matched it in
/// four places - so the checker did not know a constructor the contract
/// builder did, and a handler returning one inferred nothing where the other
/// four inferred `Response`. That is the fail-open direction: the return check
/// compares nothing when either side is absent.
///
/// `text` is the total constructor spec 7.2 names `responseText`: a handler
/// always has an infallible way to build the error arm of a fallible one. That
/// is why the encodability rule below applies to `json` and not to it.
pub const RESPONSE_CONSTRUCTORS = [_][]const u8{ "json", "text", "html", "redirect", "rawJson" };

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

    populateRequestType(env, pool, allocator);
    populateRequestReaders(env, pool, allocator);
}

/// `Request` was a `known_globals` name resolving to a bare `t_ref`, so every
/// property read off a request answered nothing: `req.method` had no type,
/// `req.url` had no type, and a typo in a field name was as silent as a
/// correct one. This is the first typing of the request side, not a re-typing
/// - spec 7.2's request contract had nothing here to replace.
///
/// The fields are the ones the runtime sets, read off
/// `handler_instance.createRequestObject` rather than guessed: `url`,
/// `method`, `path`, `query`, `body`, and `headers`, plus the two prototype
/// methods `text()` and `json()`. `body` is `string | undefined`, which is
/// what the runtime writes when a request carries none.
///
/// `headers`, `query`, and `params` are the opaque `object`, which spec 7.2
/// admits beside a precise type and which is the honest answer for all three:
/// a header map is keyed by whatever the client sent, the query map by
/// whatever the URL carried, and `params` by whatever pattern a router
/// matched. Nothing enters as `unknown`, which is the line the spec draws -
/// `object` says "a record whose keys I do not know", and `unknown` would say
/// "I do not know what this is at all".
///
/// `params` is not set by the runtime. A router handler assigns it
/// (`req.params = found.params`) and then reads it, which is the shipped
/// idiom; declaring it is what keeps both halves of that idiom typed.
fn populateRequestType(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    if (env.getTypeAlias(REQUEST_TYPE_NAME) != null) return;

    const object_ref = pool.addRef(allocator, "object");
    const optional_string = pool.addNullable(allocator, pool.idx_string);
    const no_params: []const type_pool_mod.FuncParam = &.{};
    const text_fn = pool.addFunctionWithReturn(allocator, no_params, pool.idx_string);
    const json_fn = pool.addFunctionWithReturn(allocator, no_params, pool.idx_unknown);

    const shape = pool.addRecord(allocator, &.{
        addField(pool, allocator, "url", pool.idx_string),
        addField(pool, allocator, "method", pool.idx_string),
        addField(pool, allocator, "path", pool.idx_string),
        addField(pool, allocator, "query", object_ref),
        addField(pool, allocator, "body", optional_string),
        addField(pool, allocator, "headers", object_ref),
        addField(pool, allocator, "params", object_ref),
        addField(pool, allocator, "text", text_fn),
        addField(pool, allocator, "json", json_fn),
    });
    if (shape == null_type_idx) return;

    const request = pool.addNominalAlias(allocator, shape, REQUEST_TYPE_NAME);
    if (request == null_type_idx) return;
    env.putTypeAlias(REQUEST_TYPE_NAME, request);
}

/// The registered `Request` type, or `null_type_idx` when nothing registered it.
pub fn requestType(env: *const TypeEnv) TypeIndex {
    return env.getTypeAlias(REQUEST_TYPE_NAME) orelse null_type_idx;
}

/// The three body readers of spec 7.2, typed. They are globals, so their
/// signatures go in the same `fn_sigs_by_name` map the module exports use -
/// `callableSignatureForBinding` falls back to it by name, which is what gives
/// an unimported global a type at all.
///
/// Two of the three are typed less precisely than section 7.2 spells them, and
/// the gap is in the type system rather than in these declarations. The spec
/// writes `Result<string, BodyError>` and `Result<JsonValue, JsonError |
/// BodyError>`; the checker's `Result` is one fixed record shared by every
/// fallible export, with `value: unknown` and no type parameters, so both
/// collapse to it. The runtime error records carry the spec's taxonomy exactly
/// and are pinned by test there. The precise spelling waits on the
/// parameterized `Result` that phase 7's cutover brings, alongside
/// `responseJson`, which is deferred there for the same kind of reason.
///
/// `requestBody` needs none of that: `Bytes` exists and the operation is
/// total, so its declaration is the spec's.
fn populateRequestReaders(env: *TypeEnv, pool: *TypePool, allocator: std.mem.Allocator) void {
    const request = requestType(env);
    if (request == null_type_idx) return;

    // The same four-field record every fallible module export returns, built
    // the same way `module_types.populateModuleTypes` builds it. A reader with
    // a shape of its own would make `result.ok` and `result.value` mean
    // something different depending on which call produced them.
    const ok_n = pool.addName(allocator, "ok");
    const val_n = pool.addName(allocator, "value");
    const err_n = pool.addName(allocator, "error");
    const errs_n = pool.addName(allocator, "errors");
    const result_record = pool.addRecord(allocator, &.{
        .{ .name_start = ok_n.start, .name_len = ok_n.len, .type_idx = pool.idx_boolean, .optional = false },
        .{ .name_start = val_n.start, .name_len = val_n.len, .type_idx = pool.idx_unknown, .optional = true },
        .{ .name_start = err_n.start, .name_len = err_n.len, .type_idx = pool.idx_unknown, .optional = true },
        .{ .name_start = errs_n.start, .name_len = errs_n.len, .type_idx = pool.idx_unknown, .optional = true },
    });
    if (result_record == null_type_idx) return;

    registerReader(env, "requestBody", request, pool.idx_bytes);
    registerReader(env, "requestText", request, result_record);
    registerReader(env, "requestJson", request, result_record);
}

fn registerReader(env: *TypeEnv, name: []const u8, request: TypeIndex, returns: TypeIndex) void {
    var sig = type_env_mod.FunctionSig{};
    sig.param_count = 1;
    sig.param_types[0] = request;
    sig.return_type = returns;
    env.fn_sigs_by_name.put(env.allocator, env.internName(name), sig) catch {};
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

test "the exported-boundary ABI registry owns every fixed exemption" {
    for ([_][]const u8{
        "Request",
        "Response",
        "Bytes",
        "Dict<string, number>",
        "JsonValue",
        "Result<string, string>",
        "readonly Bytes[]",
    }) |annotation| {
        try std.testing.expect(isBoundaryTypeAnnotation(annotation));
    }
    try std.testing.expect(!isBoundaryTypeAnnotation("ResponseBody"));
    try std.testing.expect(!isBoundaryTypeAnnotation("Request | string"));
    try std.testing.expect(!isBoundaryTypeAnnotation("string"));
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

test "populateHandlerAbiTypes registers a nominal Request with the runtime's fields" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);

    const request = requestType(&env);
    try std.testing.expect(request != null_type_idx);
    try std.testing.expect(pool.isNominal(request));

    // Every field the runtime sets, and the two prototype methods. A missing
    // one reads as nothing at the call site, which is what the whole type
    // exists to stop.
    const expected = [_][]const u8{ "url", "method", "path", "query", "body", "headers", "params", "text", "json" };
    const fields = pool.getRecordFields(request);
    try std.testing.expectEqual(expected.len, fields.len);
    for (expected, fields) |name, field| {
        try std.testing.expectEqualStrings(name, pool.getName(field.name_start, field.name_len));
    }
}

test "a request field reads its declared type, and body may be absent" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);
    const request = requestType(&env);

    var method: TypeIndex = null_type_idx;
    var body: TypeIndex = null_type_idx;
    var headers: TypeIndex = null_type_idx;
    for (pool.getRecordFields(request)) |field| {
        const name = pool.getName(field.name_start, field.name_len);
        if (std.mem.eql(u8, name, "method")) method = field.type_idx;
        if (std.mem.eql(u8, name, "body")) body = field.type_idx;
        if (std.mem.eql(u8, name, "headers")) headers = field.type_idx;
    }

    try std.testing.expectEqual(pool.idx_string, method);

    // The runtime writes `undefined` when a request carries no body, so the
    // type says so - which is what made six examples that passed `req.body`
    // straight into a `string` parameter report at last.
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_nullable, pool.getTag(body).?);
    try std.testing.expectEqual(pool.idx_string, pool.getNullableInner(body));
    try std.testing.expect(!env.isAssignableTo(body, pool.idx_string));
    try std.testing.expect(env.isAssignableTo(pool.idx_string, body));

    // Headers are opaque rather than precise, which spec 7.2 admits beside a
    // fixed type. `object`, not `unknown`: the keys are unknown, the kind is
    // not.
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_ref, pool.getTag(headers).?);
    try std.testing.expectEqualStrings("object", pool.getRefName(headers));
    try std.testing.expect(headers != pool.idx_unknown);
}

test "the Request brand refuses what is not one" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    populateHandlerAbiTypes(&env, &pool, allocator);
    const request = requestType(&env);

    // Not a Bytes, in either direction: spec 6.3 keeps binary and structured
    // data apart, and the request side of the ABI is where they would meet.
    try std.testing.expect(!env.isAssignableTo(pool.idx_bytes, request));
    try std.testing.expect(!env.isAssignableTo(request, pool.idx_bytes));

    // Not a Response either, though both are branded records: the brands are
    // what separate them.
    const response = responseType(&env);
    try std.testing.expect(!env.isAssignableTo(response, request));
    try std.testing.expect(!env.isAssignableTo(request, response));

    // A record carrying one of the fields is not a Request.
    const bare = pool.addRecord(allocator, &.{
        addField(&pool, allocator, "method", pool.idx_string),
    });
    try std.testing.expect(!env.isAssignableTo(bare, request));

    // What it *is* assignable to is recorded rather than assumed: `object`
    // means object-like, and a Request is an object. The plan expected a
    // refusal here; measurement says otherwise, and refusing would be wrong -
    // it would make every `object`-typed parameter reject a request for no
    // property the caller could name.
    const object_ref = pool.addRef(allocator, "object");
    try std.testing.expect(env.isAssignableTo(request, object_ref));
}

test "isResponseConstructor names every constructor the runtime installs" {
    // Five, and the fifth is the point: `rawJson` was known to
    // `object.Atom`, to `contract_builder.zig`, and to `handler_analyzer.zig`
    // in four places, and not to the checker - so a handler returning one
    // inferred nothing where the other four inferred `Response`, and the
    // return check compared nothing.
    try std.testing.expectEqual(@as(usize, 5), RESPONSE_CONSTRUCTORS.len);
    for ([_][]const u8{ "json", "text", "html", "redirect", "rawJson" }) |name| {
        try std.testing.expect(isResponseConstructor(name));
    }
    try std.testing.expect(!isResponseConstructor("clone"));
}
