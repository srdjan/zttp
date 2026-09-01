//! Owned runtime capability policy generation.
//!
//! RuntimePolicy is normally a borrowed view over a contract, generated
//! constants, or a self-extract payload. A pool generation must outlive all of
//! those callers and every checked-out runtime from an earlier reload. This
//! object owns the backing bytes, optionally owns the one R18 lookup index for
//! a guarded generation, and retires through reference counting.

const std = @import("std");
const zq = @import("zts");

const RuntimePolicy = zq.RuntimePolicy;
const RuntimePolicyIndex = zq.handler_policy.RuntimePolicyIndex;
const SqlQueryInfo = zq.handler_policy.SqlQueryInfo;

pub const RuntimePolicyGeneration = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize),
    id: u64,
    policy: RuntimePolicy,
    index: ?RuntimePolicyIndex = null,
    env_values: []const []const u8 = &.{},
    egress_values: []const []const u8 = &.{},
    cache_values: []const []const u8 = &.{},
    sql_values: []const []const u8 = &.{},
    sql_queries: []const SqlQueryInfo = &.{},

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        id: u64,
        source: RuntimePolicy,
        index_required: bool,
    ) !*Self {
        try zq.handler_policy.validateRuntimePolicy(source);
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .refs = std.atomic.Value(usize).init(1),
            .id = id,
            .policy = .{
                .env = .{ .enabled = source.env.enabled },
                .egress = .{ .enabled = source.egress.enabled },
                .egress_scopes = source.egress_scopes,
                .cache = .{ .enabled = source.cache.enabled },
                .sql = .{ .enabled = source.sql.enabled },
            },
        };
        errdefer self.deinitOwned();

        self.env_values = try dupeStringList(allocator, source.env.values);
        self.policy.env.values = self.env_values;
        self.egress_values = try dupeStringList(allocator, source.egress.values);
        self.policy.egress.values = self.egress_values;
        self.cache_values = try dupeStringList(allocator, source.cache.values);
        self.policy.cache.values = self.cache_values;
        self.sql_values = try dupeStringList(allocator, source.sql.values);
        self.policy.sql.values = self.sql_values;
        self.sql_queries = try dupeQueries(allocator, source.sql.queries);
        self.policy.sql.queries = self.sql_queries;

        if (index_required) {
            self.index = try zq.handler_policy.buildIndex(allocator, self.policy);
            if (self.index) |*index| self.policy.installed_index = index;
        }
        return self;
    }

    pub fn retain(self: *Self) *Self {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Self) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        self.deinitOwned();
        allocator.destroy(self);
    }

    fn deinitOwned(self: *Self) void {
        // The index borrows names from the owned policy. Its pointer arrays
        // retire first so no destructor observes freed entries.
        if (self.index) |*index| {
            self.policy.installed_index = null;
            index.deinit(self.allocator);
            self.index = null;
        }
        freeStringList(self.allocator, self.env_values);
        freeStringList(self.allocator, self.egress_values);
        freeStringList(self.allocator, self.cache_values);
        freeStringList(self.allocator, self.sql_values);
        freeQueries(self.allocator, self.sql_queries);
        self.env_values = &.{};
        self.egress_values = &.{};
        self.cache_values = &.{};
        self.sql_values = &.{};
        self.sql_queries = &.{};
    }
};

fn dupeStringList(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |value| allocator.free(value);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
        filled = index + 1;
    }
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn dupeQueries(
    allocator: std.mem.Allocator,
    queries: []const SqlQueryInfo,
) ![]const SqlQueryInfo {
    if (queries.len == 0) return &.{};
    const out = try allocator.alloc(SqlQueryInfo, queries.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |query| allocator.free(query.name);
    for (queries, 0..) |query, index| {
        const name = try allocator.dupe(u8, query.name);
        out[index] = zq.handler_policy.normalizedSqlQuery(
            name,
            zq.handler_policy.sqlQueryIsReadOnly(query),
        );
        filled = index + 1;
    }
    return out;
}

fn freeQueries(allocator: std.mem.Allocator, queries: []const SqlQueryInfo) void {
    if (queries.len == 0) return;
    for (queries) |query| allocator.free(query.name);
    allocator.free(queries);
}

test "guarded generation owns one index and its policy backing" {
    const allocator = std.testing.allocator;
    const source_name = try allocator.dupe(u8, "OWNED_KEY");
    var source_values = [_][]const u8{source_name};

    const generation = try RuntimePolicyGeneration.create(
        allocator,
        7,
        .{ .env = .{ .enabled = true, .values = &source_values } },
        true,
    );
    allocator.free(source_name);
    source_values[0] = "CHANGED_AFTER_CREATE";
    defer generation.release();

    try std.testing.expectEqual(@as(u64, 7), generation.id);
    try std.testing.expect(generation.index != null);
    try std.testing.expect(generation.policy.allowsEnv("OWNED_KEY"));
    try std.testing.expect(!generation.policy.allowsEnv("CHANGED_AFTER_CREATE"));
}

test "static generation preserves the index-empty state" {
    const generation = try RuntimePolicyGeneration.create(
        std.testing.allocator,
        1,
        .{ .env = .{ .enabled = true, .values = &.{"LITERAL"} } },
        false,
    );
    defer generation.release();

    try std.testing.expect(generation.index == null);
    try std.testing.expect(generation.policy.installed_index == null);
    try std.testing.expect(generation.policy.allowsEnv("LITERAL"));
}

test "a retained old generation outlives the pool owner reference" {
    const generation = try RuntimePolicyGeneration.create(
        std.testing.allocator,
        3,
        .{ .cache = .{ .enabled = true, .values = &.{"old"} } },
        true,
    );
    const runtime_ref = generation.retain();
    generation.release();
    defer runtime_ref.release();

    try std.testing.expect(runtime_ref.policy.allowsCacheNamespace("old"));
    try std.testing.expect(!runtime_ref.policy.allowsCacheNamespace("new"));
}
