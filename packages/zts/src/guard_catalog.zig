//! The supported guard surface: which virtual-module export arguments the
//! consumer can carry as residual obligations, and what each one authorizes.
//!
//! The compiler needs this to answer two questions it cannot answer from the
//! rule registry: whether a computed capability argument is one the consumer
//! guards at all, and which policy section the author has to write. The
//! acceptance kernel owns the authoritative table in
//! `packages/proof-checker/src/residual.zig`, and it is a leaf that this
//! package sits below, so the rows are mirrored here and a test in
//! `packages/runtime`, which sees both, fails when the two disagree.
//!
//! A row here does not mean the family is enabled. Enabling is R19's question -
//! whether a measured rejection exists that becomes a guarded operation - and
//! it is answered in the classifier, not in this table.

const std = @import("std");

/// What kind of resource a guard authorizes. Mirrors the kernel's `GuardKind`,
/// wire values included, because the proof IR carries the catalog row index and
/// the consumer resolves the kind from its own copy.
pub const Kind = enum(u8) {
    env_key = 1,
    egress_endpoint = 2,
    cache_namespace = 3,
    sql_read = 4,
    sql_write = 5,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    /// The policy file section whose list decides this kind at run time.
    pub fn section(self: Kind) []const u8 {
        return switch (self) {
            .env_key => "env.allow",
            .egress_endpoint => "egress.allow_endpoints",
            .cache_namespace => "cache.allow_namespaces",
            .sql_read, .sql_write => "sql.allow_queries",
        };
    }
};

pub const Entry = struct {
    module: []const u8,
    export_name: []const u8,
    arg_index: u8,
    kind: Kind,
};

/// Mirrors `pcc.residual.catalog`, row for row and in the same order: the index
/// is what the proof IR carries.
pub const entries = [_]Entry{
    .{ .module = "zttp:env", .export_name = "env", .arg_index = 0, .kind = .env_key },

    .{ .module = "zttp:fetch", .export_name = "fetch", .arg_index = 0, .kind = .egress_endpoint },
    .{ .module = "zttp:fetch", .export_name = "fetchWithRetry", .arg_index = 0, .kind = .egress_endpoint },

    .{ .module = "zttp:cache", .export_name = "cacheGet", .arg_index = 0, .kind = .cache_namespace },
    .{ .module = "zttp:cache", .export_name = "cacheSet", .arg_index = 0, .kind = .cache_namespace },
    .{ .module = "zttp:cache", .export_name = "cacheDelete", .arg_index = 0, .kind = .cache_namespace },
    .{ .module = "zttp:cache", .export_name = "cacheIncr", .arg_index = 0, .kind = .cache_namespace },
    .{ .module = "zttp:cache", .export_name = "cacheStats", .arg_index = 0, .kind = .cache_namespace },

    .{ .module = "zttp:sql", .export_name = "sqlOne", .arg_index = 0, .kind = .sql_read },
    .{ .module = "zttp:sql", .export_name = "sqlMany", .arg_index = 0, .kind = .sql_read },
    .{ .module = "zttp:sql", .export_name = "sqlExec", .arg_index = 0, .kind = .sql_write },
};

pub fn lookup(module: []const u8, export_name: []const u8, arg_index: u8) ?Entry {
    const index = lookupIndex(module, export_name, arg_index) orelse return null;
    return entries[index];
}

pub fn lookupIndex(module: []const u8, export_name: []const u8, arg_index: u8) ?u32 {
    for (entries, 0..) |entry, index| {
        if (entry.arg_index != arg_index) continue;
        if (!std.mem.eql(u8, entry.module, module)) continue;
        if (!std.mem.eql(u8, entry.export_name, export_name)) continue;
        return @intCast(index);
    }
    return null;
}

/// Whether any argument of this export is guarded, for a caller that has a
/// module and an export and no argument position yet.
pub fn guardsAnyArgument(module: []const u8, export_name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.module, module) and
            std.mem.eql(u8, entry.export_name, export_name)) return true;
    }
    return false;
}

const testing = std.testing;

test "a row is found by module, export, and argument position together" {
    const found = lookup("zttp:cache", "cacheIncr", 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Kind.cache_namespace, found.kind);
    try testing.expectEqualStrings("cache.allow_namespaces", found.kind.section());

    // A different argument position is a different question, and this table
    // answers only for the one it names.
    try testing.expect(lookup("zttp:cache", "cacheIncr", 1) == null);
    // Registering a statement is not executing a named query.
    try testing.expect(lookup("zttp:sql", "sql", 0) == null);
    try testing.expect(lookup("zttp:service", "serviceCall", 0) == null);
    try testing.expect(guardsAnyArgument("zttp:fetch", "fetchWithRetry"));
    try testing.expect(!guardsAnyArgument("zttp:fetch", "fetchSync"));
}

test "each kind names the policy section its author has to write" {
    try testing.expectEqualStrings("env.allow", Kind.env_key.section());
    try testing.expectEqualStrings("egress.allow_endpoints", Kind.egress_endpoint.section());
    try testing.expectEqualStrings("cache.allow_namespaces", Kind.cache_namespace.section());
    try testing.expectEqualStrings("sql.allow_queries", Kind.sql_read.section());
    try testing.expectEqualStrings("sql.allow_queries", Kind.sql_write.section());
}
