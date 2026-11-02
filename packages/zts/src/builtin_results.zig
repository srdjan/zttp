//! The result types of builtin calls and builtin property reads.
//!
//! The type checker gives a builtin no function type, so a call of one has no
//! type unless a row here supplies it. A row gives a result type only when the
//! arguments have the types that the runtime reads and their count is in the
//! runtime's range (T1 of the builtin result types plan). Otherwise the result
//! stays untyped, as it was before this table. The table adds no argument
//! diagnostic (T4): `Math.floor("x")` is not refused, its result has no type.
//!
//! Each row follows the runtime in `builtins/` (and `http.zig` and
//! `runtime/src/runtime_http.zig` for the HTTP rows), not TypeScript. A
//! parameter is `any` when the result type is the same for every argument the
//! runtime can receive: `String(x)` is a string for any `x`. A parameter is
//! `number` when a non-number changes the result: `Math.floor("x")` is
//! `undefined`, so `Math.floor(s)` with `s: string` has no row result.
//!
//! The census at the end of this file fails when an installed builtin has
//! neither a row nor an allowlist row that says why it stays untyped.

const std = @import("std");
const engine = @import("zts-engine");
const flow_rules = @import("flow_rules.zig");
const known_globals = @import("zts-base").known_globals;

/// What the runtime reads from one argument position.
pub const Param = enum {
    /// Any value, including one with no type. The result type does not depend
    /// on the argument.
    any,
    /// A value of type `number`. A non-number gives `undefined` at runtime.
    number,
    /// A value of type `string`. A non-string gives `undefined` at runtime.
    string,
    /// A value of a function type. A value that is not callable gives
    /// `undefined` at runtime.
    function,
    /// A record, a Dict, an array, or a tuple: a value that the runtime reads
    /// as an object. Any other value gives `undefined` at runtime.
    object,
};

/// The type of a row's result. The first group has one type for every
/// accepted call. The second group takes its type from the receiver or the
/// arguments, in `builtinShapedResult` of `type_checker.zig`.
pub const Result = enum {
    number,
    boolean,
    string,
    string_array,
    /// `string | undefined`.
    optional_string,
    undefined_value,
    /// `unknown`.
    unknown_value,
    /// The Result record with an `unknown` value and a `string` error.
    json_result,
    /// `T[]` for the element type `T` of the receiver.
    receiver_array,
    /// `T | undefined` for the element type `T` of the receiver.
    receiver_element_or_undefined,
    /// The array of the union of the receiver's element type and what each
    /// argument adds.
    concat_array,
    /// The array of the callback's return type.
    map_array,
    /// The join of the initial value type (or the element type) and the
    /// callback's return type.
    reduce_value,
    /// `string` for an argument of bounded JSON depth, `string | undefined`
    /// for a recursive type, and no result for a type with an `unknown` part.
    json_text,
    /// The array of the union of the arguments' types.
    array_of,
    /// `string[]` for a string, the same array for an array.
    array_from,
};

pub const Kind = enum {
    /// A call of the member.
    call,
    /// A read of the member as a value.
    property,
};

pub const Row = struct {
    /// A scope string of `flow_rules.zig`: `global`, a namespace name,
    /// `String.prototype`, `Array.prototype`, or `Headers.prototype`.
    scope: []const u8,
    name: []const u8,
    kind: Kind = .call,
    /// The fewest arguments for which the row gives a result.
    min_args: u8 = 0,
    /// The parameters by position. A call with more arguments than `params`
    /// has a result only when `rest` is set.
    params: []const Param = &.{},
    /// The parameter of every argument after `params`.
    rest: ?Param = null,
    result: Result,

    pub fn paramAt(self: Row, index: usize) ?Param {
        if (index < self.params.len) return self.params[index];
        return self.rest;
    }

    /// Whether `count` arguments are in the range that the runtime reads.
    pub fn acceptsCount(self: Row, count: usize) bool {
        if (count < self.min_args) return false;
        if (count <= self.params.len) return true;
        return self.rest != null;
    }
};

const any_one: []const Param = &.{.any};
const any_two: []const Param = &.{ .any, .any };
const number_one: []const Param = &.{.number};
const number_two: []const Param = &.{ .number, .number };

fn calls(
    comptime scope: []const u8,
    comptime min_args: u8,
    comptime params: []const Param,
    comptime result: Result,
    comptime names: []const []const u8,
) [names.len]Row {
    var built: [names.len]Row = undefined;
    for (names, 0..) |name, i| {
        built[i] = .{ .scope = scope, .name = name, .min_args = min_args, .params = params, .result = result };
    }
    return built;
}

fn properties(
    comptime scope: []const u8,
    comptime names: []const []const u8,
) [names.len]Row {
    var built: [names.len]Row = undefined;
    for (names, 0..) |name, i| {
        built[i] = .{ .scope = scope, .name = name, .kind = .property, .result = .number };
    }
    return built;
}

/// The rows. Runtime facts that differ from TypeScript are written beside the
/// row that they change.
pub const rows =
    // Math. A call with no argument or a non-number argument returns
    // `undefined` (`toNumber(arg) orelse return undefined` in math.zig), so
    // each parameter is `number`. `Math.min` and `Math.max` with no argument
    // return Infinity and -Infinity, so they accept zero arguments.
    calls("Math", 1, number_one, .number, &.{
        "abs", "floor", "ceil", "round", "trunc", "sqrt", "sin", "cos", "tan", "log", "exp",
    }) ++
    calls("Math", 2, number_two, .number, &.{"pow"}) ++
    [_]Row{
        .{ .scope = "Math", .name = "min", .rest = .number, .result = .number },
        .{ .scope = "Math", .name = "max", .rest = .number, .result = .number },
    } ++
    // `Math.random` returns `undefined` only when a replay log is exhausted,
    // which is not a normal call.
    calls("Math", 0, &.{}, .number, &.{"random"}) ++
    // Only `Math.PI` is installed. The other seven `math_constants` are Zig
    // declarations that the runtime does not install: `Math.E` reads
    // `undefined`, so it has no row.
    properties("Math", &.{"PI"}) ++
    // Number. The predicates return false for a value that is not a number, and
    // the parsers return NaN for a value that is not a string, so each result
    // is the same for every argument. NaN is a `number`.
    calls("Number", 0, any_one, .boolean, &.{ "isInteger", "isNaN", "isFinite" }) ++
    calls("Number", 0, any_one, .number, &.{"parseFloat"}) ++
    calls("Number", 0, any_two, .number, &.{"parseInt"}) ++
    // The 8 constants that builtins/root.zig installs on `Number`.
    properties("Number", &.{
        "MAX_VALUE",         "MIN_VALUE",         "NaN",
        "POSITIVE_INFINITY", "NEGATIVE_INFINITY", "MAX_SAFE_INTEGER",
        "MIN_SAFE_INTEGER",  "EPSILON",
    }) ++
    // `Date.now` returns `undefined` only when the operating system clock
    // fails or a replay log is exhausted, which is not a normal call.
    calls("Date", 0, &.{}, .number, &.{"now"}) ++
    // `String.fromCharCode` maps each argument to a character, a non-number to
    // code 0, and returns a string for any arguments.
    [_]Row{.{ .scope = "String", .name = "fromCharCode", .rest = .any, .result = .string }} ++
    // The global functions. `String(x)` and `Number(x)` convert any value.
    // `renderToString` returns "" for no argument and throws, rather than
    // returns, when a component fails.
    calls("global", 0, any_one, .string, &.{ "String", "renderToString" }) ++
    calls("global", 0, any_one, .number, &.{ "Number", "parseFloat" }) ++
    calls("global", 0, any_two, .number, &.{"parseInt"}) ++
    // String.prototype. The receiver is a string, so each method returns its
    // normal result for any argument, except `repeat`: a negative or infinite
    // count, or a result over 1 MB, returns `undefined`.
    calls("String.prototype", 0, any_one, .string, &.{ "charAt", "toLowerCase", "toUpperCase", "trim", "trimStart", "trimEnd" }) ++
    calls("String.prototype", 0, any_one, .number, &.{"charCodeAt"}) ++
    calls("String.prototype", 0, any_two, .number, &.{ "indexOf", "lastIndexOf" }) ++
    calls("String.prototype", 0, any_two, .boolean, &.{ "startsWith", "endsWith", "includes" }) ++
    calls("String.prototype", 0, any_two, .string, &.{ "slice", "substring", "padStart", "padEnd", "replace", "replaceAll" }) ++
    calls("String.prototype", 0, any_one, .optional_string, &.{"repeat"}) ++
    // `split` returns `undefined` when the separator is neither a string nor
    // undefined, so its separator is `string`. With no argument, it returns
    // the string in a one-element array. A limit that is not an integer is
    // ignored.
    [_]Row{
        .{ .scope = "String.prototype", .name = "split", .params = &.{ .string, .any }, .result = .string_array },
        .{ .scope = "String.prototype", .name = "concat", .rest = .any, .result = .string },
    } ++
    // Headers. `get` returns `undefined` for a missing header, and for a name
    // that is not a string. Only the headers of a `Request` have a row: see
    // `inferBuiltinMemberCall` in type_checker.zig.
    calls("Headers.prototype", 0, any_one, .optional_string, &.{"get"}) ++
    calls("Headers.prototype", 0, any_one, .boolean, &.{"has"}) ++
    calls("Headers.prototype", 0, any_two, .undefined_value, &.{ "set", "append", "delete" }) ++
    // `.length` of a string counts UTF-16 code units, and of an array counts
    // elements. Both are numbers.
    properties("String.prototype", &.{"length"}) ++
    properties("Array.prototype", &.{"length"}) ++
    // Array.prototype. The receiver is an array, and a call returns its normal
    // result for any argument. Allocation failure and an arena escape install
    // an exception instead of returning, so they are not a result.
    //
    // `push` and `unshift` return the new length. `pop` and `shift` return
    // `undefined` on an empty array. They read no argument, so a call with an
    // argument stays untyped.
    [_]Row{
        .{ .scope = "Array.prototype", .name = "push", .rest = .any, .result = .number },
        .{ .scope = "Array.prototype", .name = "unshift", .rest = .any, .result = .number },
        .{ .scope = "Array.prototype", .name = "pop", .result = .receiver_element_or_undefined },
        .{ .scope = "Array.prototype", .name = "shift", .result = .receiver_element_or_undefined },
        // `splice` reads a start and a count only when they are integers, else
        // it deletes from 0 to the end. It always returns the deleted elements.
        .{ .scope = "Array.prototype", .name = "splice", .rest = .any, .result = .receiver_array },
        // `slice` converts a non-integer bound, and always returns an array.
        .{ .scope = "Array.prototype", .name = "slice", .params = any_two, .result = .receiver_array },
        // `indexOf` and `includes` return -1 or false for a missing element or
        // a bound that is not an integer.
        .{ .scope = "Array.prototype", .name = "indexOf", .params = any_two, .result = .number },
        .{ .scope = "Array.prototype", .name = "includes", .params = any_two, .result = .boolean },
        // `join` converts a separator that is not a string to a string
        // (`valueToStringSimple`), and an undefined separator is a comma, so
        // the separator is `any`.
        .{ .scope = "Array.prototype", .name = "join", .params = any_one, .result = .string },
        // `concat` flattens an argument that is an array one level and appends
        // any other argument as one element.
        .{ .scope = "Array.prototype", .name = "concat", .rest = .any, .result = .concat_array },
        // `map` returns `undefined` for a callback that is not callable. A
        // second argument is ignored.
        .{ .scope = "Array.prototype", .name = "map", .min_args = 1, .params = &.{ .function, .any }, .result = .map_array },
        // `reduce` returns the initial value for an empty array, and the last
        // callback result otherwise. With no initial value, a one-element
        // array returns its element, a longer array the last callback result,
        // and an empty array throws.
        .{ .scope = "Array.prototype", .name = "reduce", .min_args = 1, .params = &.{ .function, .any }, .result = .reduce_value },
        // `forEach` returns `undefined`, with or without a callback.
        .{ .scope = "Array.prototype", .name = "forEach", .rest = .any, .result = .undefined_value },
    } ++
    // JSON. `parse` returns the parsed value, or `undefined` for text that is
    // not valid JSON, for a value that is not a string, and for JSON `null`.
    // `unknown` covers all of them. `tryParse` returns a Result object for any
    // argument. Its `ok`, `value`, and `error` are the core properties of the
    // Result object (`getResultCoreProperty` in object.zig), the same ones
    // that `requestJson` returns. A failure has a string `error`.
    // `stringify` returns `undefined` for no argument, and for a value nested
    // 512 levels deep or more; see `json_text`.
    [_]Row{
        .{ .scope = "JSON", .name = "parse", .params = any_one, .result = .unknown_value },
        .{ .scope = "JSON", .name = "tryParse", .params = any_one, .result = .json_result },
        .{ .scope = "JSON", .name = "stringify", .min_args = 1, .params = &.{ .any, .any, .any }, .result = .json_text },
    } ++
    // Object. `keys` returns `undefined` for a value that is not an object, so
    // its argument is `object`. `hasOwn` returns false for a value that is not
    // an object and for a key that is not a string.
    [_]Row{
        .{ .scope = "Object", .name = "keys", .min_args = 1, .params = &.{.object}, .result = .string_array },
        .{ .scope = "Object", .name = "hasOwn", .params = any_two, .result = .boolean },
    } ++
    // Array. `isArray` is false for no argument and for a value that is not an
    // array. `of` returns an array of its arguments. `from` returns
    // `undefined` for no argument; a string gives an array of its characters,
    // an array gives a copy, and a second argument maps the elements, so
    // `from` has a result only for one argument.
    [_]Row{
        .{ .scope = "Array", .name = "isArray", .params = any_one, .result = .boolean },
        .{ .scope = "Array", .name = "of", .min_args = 1, .rest = .any, .result = .array_of },
        .{ .scope = "Array", .name = "from", .min_args = 1, .params = any_one, .result = .array_from },
    };

pub fn find(kind: Kind, scope: []const u8, name: []const u8) ?Row {
    for (rows) |row| {
        if (row.kind == kind and std.mem.eql(u8, row.scope, scope) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Census (T2)
// ---------------------------------------------------------------------------

/// A member that stays untyped, and why.
pub const Skip = struct {
    scope: []const u8,
    name: []const u8,
    reason: []const u8,
};

const u1b = "typed in U1b";
const values_unbounded = "the declared field types do not bound the values: a record can hold a field that its type does not name (the discriminant-test gap in docs/roadmap.md), so the union of the field types would be a false proof";
const typed_elsewhere_array = "typed elsewhere: inferArrayMethodType gives the method a function type";
const typed_elsewhere_response = "typed elsewhere: inferResponseConstructorType gives the Response type";
const typed_elsewhere_signature = "typed elsewhere: a function signature registered by name in abi_types.zig";
const result_unmodeled = "out of scope: a Result method is not modeled, and a typed Result record has no method members (ZTS201)";
const refused_in_handler = "a handler cannot reach it: ZTS629 unpublished ambient global";

fn skipsOf(
    comptime scope: []const u8,
    comptime reason: []const u8,
    comptime names: []const []const u8,
) [names.len]Skip {
    var out: [names.len]Skip = undefined;
    for (names, 0..) |name, i| {
        out[i] = .{ .scope = scope, .name = name, .reason = reason };
    }
    return out;
}

pub const skips =
    // Array.prototype: the seven methods that the checker already types.
    skipsOf("Array.prototype", typed_elsewhere_array, &.{ "filter", "every", "some", "find", "findIndex", "toSorted", "toReversed" }) ++
    skipsOf("Object", values_unbounded, &.{ "values", "entries" }) ++
    skipsOf("Response", typed_elsewhere_response, &.{ "json", "text", "html", "redirect", "rawJson" }) ++
    skipsOf("Result.prototype", result_unmodeled, &.{
        "isOk", "isErr", "unwrap", "unwrapOr", "unwrapErr", "map", "mapErr", "andThen", "match",
    }) ++
    skipsOf("Request.prototype", "typed elsewhere: the Request type declares text and json as functions (abi_types.zig)", &.{ "text", "json" }) ++
    skipsOf("global", typed_elsewhere_signature, &.{ "isDict", "isBytes", "requestBody", "requestText", "requestJson", "hole" }) ++
    skipsOf("global", "out of scope: range returns a lazy iterator, not an array. It has no prototype, and only for...of and .length read it", &.{"range"}) ++
    skipsOf("range", "out of scope: the iterator that range returns is untyped, so its length is too", &.{"length"}) ++
    skipsOf("global", "out of scope: h returns a vnode, a runtime object with no type", &.{"h"}) ++
    skipsOf("global", "out of scope: Boolean is a known name that the runtime does not install, so a call fails with NotCallable", &.{"Boolean"}) ++
    skipsOf("global", "out of scope: a call of the constructor returns a runtime object with no type", &.{ "Headers", "Request" }) ++
    skipsOf("global", "out of scope: assert is a statement, not a callable value", &.{"assert"}) ++
    skipsOf("global", refused_in_handler, &.{
        "Error",           "Fragment",    "RangeError", "ReferenceError", "Result",      "SyntaxError", "TypeError",
        "_processRequest", "httpRequest", "isFinite",   "isNaN",          "performance", "fetchSync",
    }) ++
    skipsOf("console", refused_in_handler, &.{"log"});

/// A registry member that the census requires a row or a skip for.
const Member = struct { scope: []const u8, name: []const u8 };

pub const CensusError = error{
    /// A member has neither a row nor a skip.
    MemberWithoutRow,
    /// A skip names a member that has a row.
    SkipForTypedMember,
    /// A skip names no member of any registry.
    SkipNamesNoMember,
    /// A row names no member of any registry.
    RowNamesNoMember,
    /// A skip states no reason.
    SkipWithoutReason,
};

pub const Counts = struct {
    members: usize,
    rows: usize,
    skips: usize,
    u1b_skips: usize,
};

fn findMember(members: []const Member, scope: []const u8, name: []const u8) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m.scope, scope) and std.mem.eql(u8, m.name, name)) return true;
    }
    return false;
}

fn rowFor(table: []const Row, scope: []const u8, name: []const u8) bool {
    for (table) |row| {
        if (std.mem.eql(u8, row.scope, scope) and std.mem.eql(u8, row.name, name)) return true;
    }
    return false;
}

fn skipFor(table: []const Skip, scope: []const u8, name: []const u8) bool {
    for (table) |skip| {
        if (std.mem.eql(u8, skip.scope, scope) and std.mem.eql(u8, skip.name, name)) return true;
    }
    return false;
}

fn addMember(list: *std.ArrayList(Member), allocator: std.mem.Allocator, scope: []const u8, name: []const u8) !void {
    if (findMember(list.items, scope, name)) return;
    try list.append(allocator, .{ .scope = scope, .name = name });
}

/// Every own property of `holder`, callable or not, as a member of `scope`.
fn addInstalled(
    list: *std.ArrayList(Member),
    allocator: std.mem.Allocator,
    ctx: *engine.context.Context,
    scope: []const u8,
    holder: *engine.object.JSObject,
) !void {
    const pool = ctx.hidden_class_pool orelse return error.PropertyWithoutPool;
    var it = holder.propertyIterator(pool);
    while (it.next()) |entry| {
        // The atoms 0xFFFE and 0xFFFF are hidden-class sentinels of a native
        // function, not properties (atom_table.zig).
        if (@as(u32, @backingInt(entry.atom)) >= 0xFFFE) continue;
        const name = entry.atom.toPredefinedName() orelse ctx.atoms.getName(entry.atom) orelse return error.UnnamedProperty;
        try addMember(list, allocator, scope, name);
    }
}

/// Check `table` and `skip_table` against every registry, in both directions.
/// The registries are `operation_rows`, `runtime_prototype_rows`,
/// `runtime_global_rows`, the two name lists of `known_globals`, the own
/// properties that the engine installs on each namespace and prototype, and
/// `.length` on a string, an array, and a range iterator.
fn census(
    allocator: std.mem.Allocator,
    ctx: *engine.context.Context,
    table: []const Row,
    skip_table: []const Skip,
    report: bool,
) (CensusError || std.mem.Allocator.Error || error{ PropertyWithoutPool, UnnamedProperty })!Counts {
    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(allocator);

    for (flow_rules.operation_rows) |row| try addMember(&members, allocator, row.scope, row.name);
    for (flow_rules.runtime_prototype_rows) |row| try addMember(&members, allocator, row.scope, row.name);
    for (flow_rules.runtime_global_rows) |row| try addMember(&members, allocator, row.scope, row.name);
    // A namespace name is covered by its members. Every other name is a member.
    for (known_globals.names) |name| {
        if (flow_rules.nameIn(&flow_rules.namespace_names, name)) continue;
        try addMember(&members, allocator, "global", name);
    }
    for (known_globals.runtime_only_names) |name| {
        if (flow_rules.nameIn(&flow_rules.namespace_names, name)) continue;
        try addMember(&members, allocator, "global", name);
    }

    for (flow_rules.namespace_names) |name| {
        const value = ctx.getGlobal(try ctx.atoms.intern(name)) orelse continue;
        if (!value.isObject()) continue;
        try addInstalled(&members, allocator, ctx, name, value.toPtr(engine.object.JSObject));
    }
    if (ctx.array_prototype) |holder| try addInstalled(&members, allocator, ctx, "Array.prototype", holder);
    if (ctx.string_prototype) |holder| try addInstalled(&members, allocator, ctx, "String.prototype", holder);

    try addMember(&members, allocator, "String.prototype", "length");
    try addMember(&members, allocator, "Array.prototype", "length");
    try addMember(&members, allocator, "range", "length");

    var skipped: usize = 0;
    var u1b_skipped: usize = 0;
    for (skip_table) |skip| {
        if (skip.reason.len == 0) return error.SkipWithoutReason;
        if (!findMember(members.items, skip.scope, skip.name)) return error.SkipNamesNoMember;
        if (rowFor(table, skip.scope, skip.name)) return error.SkipForTypedMember;
        skipped += 1;
        if (std.mem.eql(u8, skip.reason, u1b)) u1b_skipped += 1;
    }
    for (table) |row| {
        if (!findMember(members.items, row.scope, row.name)) return error.RowNamesNoMember;
    }
    for (members.items) |m| {
        if (rowFor(table, m.scope, m.name)) continue;
        if (skipFor(skip_table, m.scope, m.name)) continue;
        if (report) std.debug.print("builtin result census: {s}.{s} has no row and no skip\n", .{ m.scope, m.name });
        return error.MemberWithoutRow;
    }
    return .{ .members = members.items.len, .rows = table.len, .skips = skipped, .u1b_skips = u1b_skipped };
}

test "census: every installed builtin has a result row or a stated reason" {
    const allocator = std.testing.allocator;
    var arena_owner = std.heap.ArenaAllocator.init(allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();
    var gc_state = try engine.gc.GC.init(arena, .{ .nursery_size = 4096 });
    defer gc_state.deinit();
    const ctx = try engine.context.Context.init(arena, &gc_state, .{});
    defer ctx.deinit();
    try engine.builtins.initBuiltins(ctx);

    const counts = try census(allocator, ctx, &rows, &skips, true);
    std.debug.print(
        "builtin result census: {d} members, {d} rows, {d} skips ({d} typed in U1b)\n",
        .{ counts.members, counts.rows, counts.skips, counts.u1b_skips },
    );
    // A floor on the input: a census that enumerated nothing would pass.
    try std.testing.expect(counts.members >= 130);
    // Each member has a row or a skip, never both.
    try std.testing.expectEqual(counts.members, counts.rows + counts.skips);

    // A row removed from the table makes the census fail, for each row that
    // does not share its member with another row.
    for (rows, 0..) |row, removed| {
        const without = try arena.alloc(Row, rows.len - 1);
        @memcpy(without[0..removed], rows[0..removed]);
        @memcpy(without[removed..], rows[removed + 1 ..]);
        if (rowFor(without, row.scope, row.name)) continue;
        try std.testing.expectError(error.MemberWithoutRow, census(allocator, ctx, without, &skips, false));
    }

    // A skip removed from the allowlist makes the census fail.
    for (skips, 0..) |skip, removed| {
        const without = try arena.alloc(Skip, skips.len - 1);
        @memcpy(without[0..removed], skips[0..removed]);
        @memcpy(without[removed..], skips[removed + 1 ..]);
        if (skipFor(without, skip.scope, skip.name)) continue;
        try std.testing.expectError(error.MemberWithoutRow, census(allocator, ctx, &rows, without, false));
    }

    // A skip for a member that has a row fails.
    const both = try arena.alloc(Skip, skips.len + 1);
    @memcpy(both[0..skips.len], &skips);
    both[skips.len] = .{ .scope = "Math", .name = "floor", .reason = "stale" };
    try std.testing.expectError(error.SkipForTypedMember, census(allocator, ctx, &rows, both, false));

    // A skip for a member that no registry holds fails.
    both[skips.len] = .{ .scope = "Math", .name = "E", .reason = "stale" };
    try std.testing.expectError(error.SkipNamesNoMember, census(allocator, ctx, &rows, both, false));

    // A row for a member that no registry holds fails: Math.E is not installed.
    const extra = try arena.alloc(Row, rows.len + 1);
    @memcpy(extra[0..rows.len], &rows);
    extra[rows.len] = .{ .scope = "Math", .name = "E", .kind = .property, .result = .number };
    try std.testing.expectError(error.RowNamesNoMember, census(allocator, ctx, extra, &skips, false));

    // A skip states its reason.
    const silent = try arena.dupe(Skip, &skips);
    silent[0].reason = "";
    try std.testing.expectError(error.SkipWithoutReason, census(allocator, ctx, &rows, silent, false));
}
