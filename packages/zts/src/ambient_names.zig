//! The ambient names: what a handler may write without importing it.
//!
//! Spec section 6 requires `meta.payload.ambient_names` to publish "the closed
//! table of ambient type and value names", registry-generated. The value half
//! already had one closed list, `known_globals.names`, and this file re-exports
//! it rather than copying it: a second copy of that list is a soundness change,
//! for the reasons its own header gives.
//!
//! The type half had no list at all. An ambient type name resolves at one of
//! four sites, and a name that resolves at none of them reaches the checker as
//! an unresolved reference:
//!
//! - `type_pool.TypeExprParser.resolveIdentType`, for the primitives,
//! - `type_pool.TypeExprParser.parseGenericApp`, for `Dict<K, V>`, which is a
//!   value kind of its own rather than an alias a handler could shadow,
//! - `type_env.TypeEnv.registerBuiltins`, for the capsule aliases,
//! - `abi_types.populateHandlerAbiTypes`, for the handler ABI's two nominal
//!   aliases.
//!
//! What the gates below prove, and what they do not. Every published row is
//! resolved through the same environment the pipeline builds, so a row naming a
//! type the checker would refuse fails the build - that is the direction that
//! costs a reader something, because an agent that reads this table writes the
//! names in it. The reverse direction is only provable where the source set is
//! enumerable: the two alias tables are hash maps and are compared key for key,
//! so a builtin alias added without publishing it fails. The primitive branch is
//! a chain of string comparisons with no enumeration, so a primitive added there
//! and not added here would not fail. Two exclusions are deliberate and pinned
//! by tests rather than left to drift.

const std = @import("std");

const known_globals = @import("zts-base").known_globals;
const type_pool_mod = @import("type_pool.zig");
const type_env_mod = @import("type_env.zig");
const abi_types = @import("abi_types.zig");

const TypePool = type_pool_mod.TypePool;
const TypeEnv = type_env_mod.TypeEnv;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;

/// Which of the four sites gives a published name its meaning. A client reads
/// this to know whether the name is shadowable: a `builtin_alias` or an
/// `abi_alias` is an entry in a table a later declaration overwrites, and a
/// `primitive` or a `value_kind` is resolved before any table is consulted.
pub const TypeOrigin = enum {
    primitive,
    value_kind,
    builtin_alias,
    abi_alias,

    pub fn id(self: TypeOrigin) []const u8 {
        return @tagName(self);
    }
};

pub const AmbientType = struct {
    name: []const u8,
    origin: TypeOrigin,
    /// Type arguments the name requires. `Dict` is written `Dict<K, V>` and
    /// nothing else, so publishing the name alone would teach half a spelling.
    arity: u8 = 0,
};

/// The ambient type names, one row per name the checker resolves without an
/// import. Ordered by origin, then alphabetically inside it.
pub const types = [_]AmbientType{
    .{ .name = "boolean", .origin = .primitive },
    .{ .name = "Bytes", .origin = .primitive },
    .{ .name = "never", .origin = .primitive },
    .{ .name = "null", .origin = .primitive },
    .{ .name = "number", .origin = .primitive },
    .{ .name = "string", .origin = .primitive },
    .{ .name = "undefined", .origin = .primitive },
    .{ .name = "unknown", .origin = .primitive },
    .{ .name = "void", .origin = .primitive },

    .{ .name = "Dict", .origin = .value_kind, .arity = 2 },

    .{ .name = "Effects", .origin = .builtin_alias, .arity = 2 },
    .{ .name = "Proof", .origin = .builtin_alias, .arity = 2 },

    .{ .name = "Request", .origin = .abi_alias },
    .{ .name = "Response", .origin = .abi_alias },
};

/// The ambient value names. Borrowed from `known_globals`, which is the list
/// the checker and effect inference already share, so this publishes their
/// answer rather than a third opinion about it.
pub const values: []const []const u8 = &known_globals.names;

pub fn findType(name: []const u8) ?*const AmbientType {
    for (&types) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Gates
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The environment the pipeline builds before it checks a handler:
/// `TypeEnv.init` registers the capsule aliases and
/// `populateHandlerAbiTypes` registers the ABI ones. Resolving a published
/// name against anything less would prove it ambient in an environment no
/// handler is checked in.
const Fixture = struct {
    pool: TypePool,
    env: TypeEnv,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const self = try allocator.create(Fixture);
        self.pool = TypePool.init(allocator);
        self.env = TypeEnv.init(allocator, &self.pool);
        abi_types.populateHandlerAbiTypes(&self.env, &self.pool, allocator);
        return self;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.env.deinit();
        self.pool.deinit(allocator);
        allocator.destroy(self);
    }

    /// The type expression that exercises a row: a bare name at arity 0, and
    /// the name applied to `string` arguments otherwise.
    fn expressionFor(entry: AmbientType, buf: []u8) []const u8 {
        if (entry.arity == 0) return entry.name;
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll(entry.name) catch unreachable;
        w.writeByte('<') catch unreachable;
        for (0..entry.arity) |i| {
            if (i > 0) w.writeAll(", ") catch unreachable;
            w.writeAll("string") catch unreachable;
        }
        w.writeByte('>') catch unreachable;
        return w.buffered();
    }

    /// True when `source` names a type this environment can resolve. Asked
    /// through `resolveType`, which is the entry the checker itself uses, so
    /// the answer is the checker's and not a re-derivation of it. An
    /// unresolved name comes back as a `t_ref`, and an application whose base
    /// resolves to no alias comes back as an uninstantiated `t_generic_app` -
    /// the two shapes a missing ambient name produces.
    fn resolves(self: *Fixture, source: []const u8) bool {
        const idx = self.env.resolveType(source);
        if (idx == null_type_idx) return false;
        const tag = self.pool.getTag(idx) orelse return false;
        return switch (tag) {
            .t_ref, .t_generic_app => false,
            else => true,
        };
    }
};

test "every published ambient type name resolves in the environment a handler is checked in" {
    const allocator = testing.allocator;
    const fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    var buf: [64]u8 = undefined;
    for (&types) |entry| {
        const source = Fixture.expressionFor(entry, &buf);
        if (!fixture.resolves(source)) {
            std.debug.print("ambient type row does not resolve: {s}\n", .{source});
            return error.AmbientTypeUnresolved;
        }
    }
}

test "a name absent from the table does not resolve, so the gate above measures something" {
    const allocator = testing.allocator;
    const fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    // The floor. Without it, a `resolves` that answered true for everything
    // would pass the test above with every row, including a row naming a type
    // the checker refuses.
    try testing.expect(!fixture.resolves("Widget"));
    try testing.expect(!fixture.resolves("Result<string, string>"));
}

test "the builtin alias rows are exactly the aliases TypeEnv registers" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Both directions, over an enumerable source: a capsule alias added to
    // `registerBuiltins` and not published here fails, and a row published
    // here that no longer registers fails too.
    var registered: usize = 0;
    var it = env.generic_aliases.iterator();
    while (it.next()) |kv| {
        registered += 1;
        const entry = findType(kv.key_ptr.*) orelse {
            std.debug.print("builtin alias is not published: {s}\n", .{kv.key_ptr.*});
            return error.AmbientTypeUnpublished;
        };
        try testing.expectEqual(TypeOrigin.builtin_alias, entry.origin);
    }

    var published: usize = 0;
    for (&types) |entry| {
        if (entry.origin == .builtin_alias) published += 1;
    }
    try testing.expectEqual(published, registered);
}

test "the ABI alias rows are exactly the aliases the handler ABI registers" {
    const allocator = testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    // Measured against the difference the call makes, not against the table
    // afterwards: an alias registered by `TypeEnv.init` is not an ABI one.
    var before = std.StringHashMapUnmanaged(void).empty;
    defer before.deinit(allocator);
    var pre = env.type_aliases.iterator();
    while (pre.next()) |kv| try before.put(allocator, kv.key_ptr.*, {});

    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);

    var added: usize = 0;
    var it = env.type_aliases.iterator();
    while (it.next()) |kv| {
        if (before.contains(kv.key_ptr.*)) continue;
        added += 1;
        const entry = findType(kv.key_ptr.*) orelse {
            std.debug.print("ABI alias is not published: {s}\n", .{kv.key_ptr.*});
            return error.AmbientTypeUnpublished;
        };
        try testing.expectEqual(TypeOrigin.abi_alias, entry.origin);
    }

    var published: usize = 0;
    for (&types) |entry| {
        if (entry.origin == .abi_alias) published += 1;
    }
    try testing.expectEqual(published, added);
    try testing.expect(added > 0);
}

test "the two deliberate exclusions are decisions, not drift" {
    const allocator = testing.allocator;
    const fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    // `bool` resolves - `resolveIdentType` accepts it beside `boolean` - and is
    // deliberately unpublished. Spec 6 does not name it, and the two spellings
    // of one type would teach an agent a choice the canonical form does not
    // admit. Unpublished-but-accepted is the safe direction: nothing an agent
    // writes from this table is refused. The reverse would refuse code the
    // table taught.
    try testing.expect(fixture.resolves("bool"));
    try testing.expect(findType("bool") == null);

    // `Array<T>`, `ReadonlyArray<T>` and `Readonly<T>` resolve in
    // `parseGenericApp` as TS-familiar sugar. `T[]` is the canonical spelling
    // of the first two, and the third is a modifier rather than a type name.
    try testing.expect(fixture.resolves("Array<string>"));
    try testing.expect(findType("Array") == null);
    try testing.expect(findType("ReadonlyArray") == null);
    try testing.expect(findType("Readonly") == null);
}

test "spec 6 names two ambient types this compiler does not admit" {
    const allocator = testing.allocator;
    const fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    // Measured, not assumed. Spec section 6 lists `Result` and `HtmlNode` among
    // the ambient type names. Neither resolves: `Result` is declared by the
    // handler or imported from the module that exports it, and `HtmlNode`
    // appears nowhere in the compiler at all - JSX is typed through `h` and
    // `renderToString` without a published node type.
    //
    // Publishing either would put a name in the table that the checker then
    // refuses, which is the one direction this registry must never take. This
    // test fails when either becomes ambient, which is when each must be
    // published.
    try testing.expect(!fixture.resolves("Result<string, string>"));
    try testing.expect(!fixture.resolves("HtmlNode"));
    try testing.expect(findType("Result") == null);
    try testing.expect(findType("HtmlNode") == null);
}

test "the value names are the known-globals list itself, not a copy of it" {
    try testing.expectEqual(known_globals.names.len, values.len);
    for (values, 0..) |name, i| {
        try testing.expectEqualStrings(known_globals.names[i], name);
        try testing.expect(known_globals.isKnownGlobalFunction(name));
    }
}
