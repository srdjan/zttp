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

    pub fn family(self: Kind) Family {
        return switch (self) {
            .env_key => .env,
            .egress_endpoint => .egress,
            .cache_namespace => .cache,
            .sql_read, .sql_write => .sql,
        };
    }

    pub fn sectionId(self: Kind) Section {
        return switch (self) {
            .env_key => .env,
            .egress_endpoint => .egress,
            .cache_namespace => .cache,
            .sql_read, .sql_write => .sql,
        };
    }

    /// What the author computed, in the words the diagnostic uses.
    pub fn resourceNoun(self: Kind) []const u8 {
        return switch (self) {
            .env_key => "environment key",
            .egress_endpoint => "egress endpoint",
            .cache_namespace => "cache namespace",
            .sql_read => "SQL query name",
            .sql_write => "SQL query name",
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

/// The families a guarded operation may belong to. One per policy section the
/// runtime enforces.
pub const Family = enum(u3) {
    env = 0,
    egress = 1,
    cache = 2,
    sql = 3,

    pub fn bit(self: Family) u8 {
        return @as(u8, 1) << @intFromEnum(self);
    }
};

pub const FamilySet = struct {
    bits: u8 = 0,

    pub fn with(self: FamilySet, family: Family) FamilySet {
        return .{ .bits = self.bits | family.bit() };
    }

    pub fn contains(self: FamilySet, family: Family) bool {
        return self.bits & family.bit() != 0;
    }
};

/// Which families have a measured rejection behind them, per R19: a checked-in
/// operation that this compiler rejects today and that becomes a guarded one
/// when a policy names it.
///
/// `env`, `egress`, and `cache` each have a seed in
/// `packages/pi/src/standin/defect_seeds.zig`. `sql` does not, and evidence is
/// not its only obstacle: a policy file spells a SQL allowance as a bare name
/// in `allow_queries`, with no operation, so a configured SQL policy would
/// admit one name for both a read and a write and lose the split the sink
/// enforces. SQL stays rejected until the file can say which.
pub const measured_families = (FamilySet{})
    .with(.env)
    .with(.egress)
    .with(.cache);

/// Whether a guarded operation may compile.
///
/// Off, deliberately. The classification is real and runs today - it is what
/// decides which diagnostic an author gets - but a guarded operation is still a
/// build error, because a guarded handler produces an artifact only the
/// successor certificate can carry. Admit one while the producer still emits
/// the predecessor and `zttp build` fails at
/// `GuardedOperationsNotRepresentable` instead of giving the author anything to
/// read. The U7 cutover turns this on in the same commit that makes the
/// successor certificate the strict default, and nowhere else.
pub const classification_enabled = false;

/// The families the classifier admits. Which operations are guarded is a
/// question about evidence, and it does not change with the switch above; what
/// changes is whether a guarded one is fatal.
pub const enabled_families: FamilySet = measured_families;

pub const Section = enum { env, egress, cache, sql };

pub const SectionSet = struct {
    bits: u8 = 0,

    pub fn with(self: SectionSet, section: Section) SectionSet {
        return .{ .bits = self.bits | (@as(u8, 1) << @intFromEnum(section)) };
    }

    pub fn contains(self: SectionSet, section: Section) bool {
        return self.bits & (@as(u8, 1) << @intFromEnum(section)) != 0;
    }
};

/// Why a computed capability argument is refused. Each names a different next
/// action, so they are distinct values rather than one "not allowed".
pub const Rejection = enum {
    /// No catalog row: nothing at the sink decides this resource, so no policy
    /// edit makes it checkable. A service call, a registered SQL statement, the
    /// raw `fetchSync`.
    unguarded_surface,
    /// The consumer could carry it, but the family has no measured rejection
    /// behind it yet, or its policy section cannot express what the sink
    /// enforces.
    family_not_enabled,
    /// Supported and enabled, and the author has written no policy section for
    /// it. Admitting it would produce an artifact whose obligations nothing
    /// covers.
    missing_policy_section,
};

pub const Disposition = union(enum) {
    /// The consumer carries this as a residual obligation and the runtime
    /// decides the actual value.
    guarded: Entry,
    rejected: Rejection,
};

pub const ClassifyContext = struct {
    enabled: FamilySet = enabled_families,
    /// The sections the configured capability policy declares. A section the
    /// author did not write cannot cover an obligation.
    sections: SectionSet = .{},
};

/// Classify one computed capability argument. Exhaustive: every argument that
/// is not compiler-visible leaves here as guarded or as a named rejection, and
/// there is no fall-through that admits an unknown export.
pub fn classifyComputed(
    module: []const u8,
    export_name: []const u8,
    arg_index: u8,
    ctx: ClassifyContext,
) Disposition {
    const entry = lookup(module, export_name, arg_index) orelse
        return .{ .rejected = .unguarded_surface };
    const family = entry.kind.family();
    if (!ctx.enabled.contains(family)) return .{ .rejected = .family_not_enabled };
    if (!ctx.sections.contains(entry.kind.sectionId())) {
        return .{ .rejected = .missing_policy_section };
    }
    return .{ .guarded = entry };
}

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

test "classification is exhaustive over the surface" {
    const all_sections = (SectionSet{}).with(.env).with(.egress).with(.cache).with(.sql);

    // Enabled, carried, and covered by a section the author wrote.
    const guarded = classifyComputed("zttp:env", "env", 0, .{
        .enabled = measured_families,
        .sections = all_sections,
    });
    try testing.expectEqual(Kind.env_key, guarded.guarded.kind);

    // Carried and enabled, but the author wrote no section for it. This is the
    // case that must not become a development allow-all artifact.
    const uncovered = classifyComputed("zttp:cache", "cacheSet", 0, .{
        .enabled = measured_families,
        .sections = (SectionSet{}).with(.env),
    });
    try testing.expectEqual(Rejection.missing_policy_section, uncovered.rejected);

    // Carried, with a section, and not enabled: SQL, whose policy section
    // cannot say read from write.
    const not_enabled = classifyComputed("zttp:sql", "sqlExec", 0, .{
        .enabled = measured_families,
        .sections = all_sections,
    });
    try testing.expectEqual(Rejection.family_not_enabled, not_enabled.rejected);

    // Not carried at all: no policy edit makes these checkable.
    for ([_][2][]const u8{
        .{ "zttp:service", "serviceCall" },
        .{ "zttp:sql", "sql" },
        .{ "zttp:fetch", "fetchSync" },
        .{ "zttp:unknown", "whatever" },
    }) |pair| {
        const refused = classifyComputed(pair[0], pair[1], 0, .{
            .enabled = measured_families,
            .sections = all_sections,
        });
        try testing.expectEqual(Rejection.unguarded_surface, refused.rejected);
    }

    // An argument position the catalog does not name is not the guarded one.
    const other_position = classifyComputed("zttp:env", "env", 1, .{
        .enabled = measured_families,
        .sections = all_sections,
    });
    try testing.expectEqual(Rejection.unguarded_surface, other_position.rejected);
}

test "the shipped context classifies the enabled families as guarded" {
    // Classification does not wait for the cutover. Only fatality does, and
    // that decision lives at the diagnostic site, not here.
    const all_sections = (SectionSet{}).with(.env).with(.egress).with(.cache).with(.sql);
    for (entries) |entry| {
        const disposition = classifyComputed(entry.module, entry.export_name, entry.arg_index, .{
            .sections = all_sections,
        });
        switch (entry.kind.family()) {
            .sql => try testing.expectEqual(Rejection.family_not_enabled, disposition.rejected),
            else => try testing.expectEqual(entry.kind, disposition.guarded.kind),
        }
    }
}

test "the measured families are the ones with a seed behind them" {
    try testing.expect(measured_families.contains(.env));
    try testing.expect(measured_families.contains(.egress));
    try testing.expect(measured_families.contains(.cache));
    try testing.expect(!measured_families.contains(.sql));
}

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
