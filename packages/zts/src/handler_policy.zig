//! Capability policy parsing, validation, and runtime views.
//!
//! Policies are opt-in and restrict precompiled handlers to an explicit set of
//! env vars, outbound hosts, cache namespaces, and SQL query names.

const std = @import("std");
/// The contract's data types, not `handler_contract.zig`. Everything this file
/// names - HandlerContract, SqlQueryInfo, emptySqlInfo, emptyApiInfo - is
/// defined here and only re-exported by `handler_contract.zig`, which adds the
/// JSON reader and writer on top. Taking the alias route meant `context.zig`,
/// which imports this file, dragged both serializers along. See
/// docs/plans/2026-08-07-021-zts-three-module-split-plan.md.
const contract_mod = @import("zts-contracts").contract_types;

const HandlerContract = contract_mod.HandlerContract;
const ascii = std.ascii;

/// Re-export so runtime-side serializers (self_extract) can name the per-query
/// allowlist element type without reaching into the contract types directly.
pub const SqlQueryInfo = contract_mod.SqlQueryInfo;

pub const AllowList = struct {
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *AllowList, allocator: std.mem.Allocator) void {
        for (self.values.items) |item| {
            allocator.free(item);
        }
        self.values.deinit(allocator);
    }

    fn appendUnique(self: *AllowList, allocator: std.mem.Allocator, item: []const u8) !void {
        if (self.contains(item, false)) return;
        try self.values.append(allocator, try allocator.dupe(u8, item));
    }

    fn contains(self: *const AllowList, candidate: []const u8, case_insensitive: bool) bool {
        for (self.values.items) |item| {
            const matches = if (case_insensitive)
                ascii.eqlIgnoreCase(item, candidate)
            else
                std.mem.eql(u8, item, candidate);
            if (matches) return true;
        }
        return false;
    }
};

pub const HandlerPolicy = struct {
    env: ?AllowList = null,
    egress: ?AllowList = null,
    cache: ?AllowList = null,
    sql: ?AllowList = null,

    pub fn deinit(self: *HandlerPolicy, allocator: std.mem.Allocator) void {
        if (self.env) |*section| section.deinit(allocator);
        if (self.egress) |*section| section.deinit(allocator);
        if (self.cache) |*section| section.deinit(allocator);
        if (self.sql) |*section| section.deinit(allocator);
    }
};

/// R18 resource limits.
///
/// Mirrored from `packages/proof-checker/src/residual.zig`, which this package
/// cannot import: the acceptance kernel is a leaf and `packages/zts` sits below
/// it. A test in `packages/runtime`, which sees both, pins the two sets equal,
/// so a change on either side fails there rather than at a deployed guard.
pub const max_policy_entries: usize = 256;
/// An environment key, cache namespace, or SQL query name.
pub const max_identifier_bytes: usize = 255;
/// A normalized `scheme://host:port`. Egress entries are bare host names until
/// the endpoint move, and the larger cap already covers those.
pub const max_endpoint_bytes: usize = 512;
/// Probes one category lookup may cost at `max_policy_entries`. Nine, measured
/// over the search rather than read off log2 of the cap.
pub const max_lookup_comparisons: usize = 9;

pub const RuntimeAllowList = struct {
    enabled: bool = false,
    values: []const []const u8 = &.{},

    pub fn allows(self: RuntimeAllowList, candidate: []const u8) bool {
        if (!self.enabled) return true;
        for (self.values) |item| {
            if (std.mem.eql(u8, item, candidate)) return true;
        }
        return false;
    }

    pub fn allowsCaseInsensitive(self: RuntimeAllowList, candidate: []const u8) bool {
        if (!self.enabled) return true;
        for (self.values) |item| {
            if (ascii.eqlIgnoreCase(item, candidate)) return true;
        }
        return false;
    }
};

pub const RuntimeSqlAllowList = struct {
    enabled: bool = false,
    /// Operation-agnostic name allowlist: a name here is allowed for BOTH read
    /// and write. Only the name-only JSON policy-checker skeleton (policy.zig),
    /// which has no per-query operation data, populates this. Every production
    /// policy path (engine adapter, dev/serve, deploy, precompile) leaves it
    /// empty and uses `queries` so the read/write split is actually enforced.
    values: []const []const u8 = &.{},
    /// Per-query allowlist carrying each query's operation, so a query proven
    /// read-only cannot satisfy a db.write check (and vice-versa). This is what
    /// the production paths populate, matching the contract's per-query
    /// db.read/db.write capabilities in all run modes.
    queries: []const contract_mod.SqlQueryInfo = &.{},

    pub fn allowsRead(self: RuntimeSqlAllowList, candidate: []const u8) bool {
        if (!self.enabled) return true;
        for (self.values) |value| {
            if (std.mem.eql(u8, value, candidate)) return true;
        }
        for (self.queries) |query| {
            if (std.mem.eql(u8, query.name, candidate) and sqlQueryIsReadOnly(query)) return true;
        }
        return false;
    }

    pub fn allowsWrite(self: RuntimeSqlAllowList, candidate: []const u8) bool {
        if (!self.enabled) return true;
        for (self.values) |value| {
            if (std.mem.eql(u8, value, candidate)) return true;
        }
        for (self.queries) |query| {
            if (std.mem.eql(u8, query.name, candidate) and !sqlQueryIsReadOnly(query)) return true;
        }
        return false;
    }
};

pub const RuntimePolicy = struct {
    env: RuntimeAllowList = .{},
    egress: RuntimeAllowList = .{},
    cache: RuntimeAllowList = .{},
    sql: RuntimeSqlAllowList = .{},

    pub fn allowsEnv(self: RuntimePolicy, key: []const u8) bool {
        return self.env.allows(key);
    }

    pub fn allowsEgressHost(self: RuntimePolicy, host: []const u8) bool {
        return self.egress.allowsCaseInsensitive(host);
    }

    pub fn allowsCacheNamespace(self: RuntimePolicy, ns: []const u8) bool {
        return self.cache.allows(ns);
    }

    pub fn allowsSqlQuery(self: RuntimePolicy, name: []const u8) bool {
        return self.sql.allowsRead(name);
    }

    pub fn allowsSqlWrite(self: RuntimePolicy, name: []const u8) bool {
        return self.sql.allowsWrite(name);
    }
};

/// True when the query is a read-only SELECT. Prefers the explicit `operation`
/// (set by normalizedSqlQuery for serialized/dev policies), falling back to the
/// first token of the statement for contract-borrowed queries whose operation
/// is still "".
pub fn sqlQueryIsReadOnly(query: contract_mod.SqlQueryInfo) bool {
    if (query.operation.len > 0) {
        return std.ascii.eqlIgnoreCase(query.operation, "select");
    }
    const first = firstSqlToken(query.statement) orelse return false;
    return std.ascii.eqlIgnoreCase(first, "select");
}

/// Build a statement-free query view whose read/write nature is encoded in
/// `operation` alone, for policies that are serialized into a deployed binary,
/// duplicated for a dev/serve generation, or emitted as generated-code
/// constants. `name` is borrowed from the caller; `statement`/`tables` stay
/// empty, so the result MUST NOT be released via SqlQueryInfo.deinit (free only
/// the caller-owned `name`).
pub fn normalizedSqlQuery(name: []const u8, read_only: bool) contract_mod.SqlQueryInfo {
    return .{ .name = name, .operation = if (read_only) "select" else "write", .statement = "" };
}

fn firstSqlToken(statement: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < statement.len and std.ascii.isWhitespace(statement[start])) : (start += 1) {}
    if (start == statement.len) return null;

    var end = start;
    while (end < statement.len and (std.ascii.isAlphabetic(statement[end]) or statement[end] == '_')) : (end += 1) {}
    if (end == start) return null;
    return statement[start..end];
}

/// Convert a HandlerContract's proven sections into a RuntimePolicy.
///
/// A static section restricts the runtime to exactly the literals the compiler
/// saw. A dynamic section - some access is computed - takes its entries from
/// `configured`, the capability policy file, and from nowhere else. With no
/// configured section it is enabled and empty, which denies everything.
///
/// It used to be left disabled, and a disabled list admits every value. The
/// only thing standing between that and an allow-all deployment was that
/// strict checking rejects a computed capability argument (ZTS602) before a
/// dynamic contract can be built. That is a compiler decision guarding a
/// runtime default, and the guarded-call work removes it, so the default moves
/// first: no section this function returns is ever disabled.
///
/// The returned policy borrows string data from the contract and from
/// `configured`. Both must outlive the policy. For precompilation this is fine
/// because the data gets embedded as compile-time constants in the generated
/// .zig file.
pub fn contractToRuntimePolicy(
    contract: *const HandlerContract,
    configured: ?*const HandlerPolicy,
) RuntimePolicy {
    return .{
        .env = projectSection(
            contract.env.dynamic,
            contract.env.literal.items,
            if (configured) |policy| policy.env else null,
        ),
        .egress = projectSection(
            contract.egress.dynamic,
            contract.egress.hosts.items,
            if (configured) |policy| policy.egress else null,
        ),
        .cache = projectSection(
            contract.cache.dynamic,
            contract.cache.namespaces.items,
            if (configured) |policy| policy.cache else null,
        ),
        .sql = projectSqlSection(
            contract.sql.dynamic,
            contract.sql.queries.items,
            if (configured) |policy| policy.sql else null,
        ),
    };
}

fn projectSection(
    dynamic: bool,
    literals: []const []const u8,
    configured: ?AllowList,
) RuntimeAllowList {
    if (!dynamic) return .{ .enabled = true, .values = literals };
    const section = configured orelse return .{ .enabled = true, .values = &.{} };
    return .{ .enabled = true, .values = section.values.items };
}

/// The SQL projection loses the read/write split when it comes from the policy
/// file, because a configured `allow_queries` entry is a name with no
/// operation. A name the file lists is therefore allowed for both, which is
/// what the file says today. The residual guard schema splits named reads from
/// named writes, so the SQL families stay rejected until the file can express
/// the difference.
fn projectSqlSection(
    dynamic: bool,
    queries: []const contract_mod.SqlQueryInfo,
    configured: ?AllowList,
) RuntimeSqlAllowList {
    if (!dynamic) return .{ .enabled = true, .queries = queries };
    const section = configured orelse return .{ .enabled = true };
    return .{ .enabled = true, .values = section.values.items };
}

// ---------------------------------------------------------------------------
// Installed lookup index
// ---------------------------------------------------------------------------

pub const IndexError = error{
    /// More entries than R18 admits in one category.
    TooManyEntries,
    /// An identifier longer than R18 admits.
    EntryTooLong,
    /// An empty identifier names no resource.
    EntryEmpty,
    /// Two entries normalize to the same key, so the list says one thing twice
    /// and the sorted index cannot say which one a lookup found.
    DuplicateEntry,
    OutOfMemory,
};

/// One immutable sorted index over an installed generation's policy.
///
/// Built once when the generation is installed, never after. Lookups are a
/// bounded binary search - `max_lookup_comparisons` probes at the entry cap -
/// rather than the linear scan `RuntimeAllowList` does, and the limits R18
/// names are checked here, before activation, rather than at the sink.
///
/// Entries are borrowed. The policy, and whatever the policy borrows from,
/// must outlive the index. Only the pointer arrays are owned.
///
/// Egress is absent on purpose: an egress entry is compared case-insensitively
/// today, and a byte-sorted list cannot answer a case-insensitive question.
/// It joins when egress entries become normalized endpoints, which are already
/// case-folded, and the comparison becomes exact.
pub const RuntimePolicyIndex = struct {
    env: []const []const u8,
    cache: []const []const u8,
    sql_read: []const []const u8,
    sql_write: []const []const u8,

    pub const Section = enum { env, cache, sql_read, sql_write };

    pub fn deinit(self: *RuntimePolicyIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.env);
        allocator.free(self.cache);
        allocator.free(self.sql_read);
        allocator.free(self.sql_write);
        self.* = undefined;
    }

    pub fn entries(self: *const RuntimePolicyIndex, section: Section) []const []const u8 {
        return switch (section) {
            .env => self.env,
            .cache => self.cache,
            .sql_read => self.sql_read,
            .sql_write => self.sql_write,
        };
    }

    pub fn allows(self: *const RuntimePolicyIndex, section: Section, candidate: []const u8) bool {
        var ignored: usize = 0;
        return searchCounting(self.entries(section), candidate, &ignored);
    }

    /// `allows`, reporting what it cost. The comparison bound is checked
    /// against the search, not against a formula about the entry cap.
    pub fn allowsCounting(
        self: *const RuntimePolicyIndex,
        section: Section,
        candidate: []const u8,
        comparisons: *usize,
    ) bool {
        return searchCounting(self.entries(section), candidate, comparisons);
    }
};

fn searchCounting(values: []const []const u8, candidate: []const u8, comparisons: *usize) bool {
    var low: usize = 0;
    var high: usize = values.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        comparisons.* += 1;
        switch (std.mem.order(u8, values[mid], candidate)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

/// Build the generation's index. Rejects before activation rather than at the
/// sink: an oversized, empty, or duplicated entry is a policy that cannot be
/// enforced as written, and installing it would enforce something else.
pub fn buildIndex(allocator: std.mem.Allocator, policy: RuntimePolicy) IndexError!RuntimePolicyIndex {
    const env = try sortedSection(allocator, policy.env.values);
    errdefer allocator.free(env);
    const cache = try sortedSection(allocator, policy.cache.values);
    errdefer allocator.free(cache);

    var read_names: std.ArrayList([]const u8) = .empty;
    defer read_names.deinit(allocator);
    var write_names: std.ArrayList([]const u8) = .empty;
    defer write_names.deinit(allocator);
    for (policy.sql.values) |name| {
        try read_names.append(allocator, name);
        try write_names.append(allocator, name);
    }
    for (policy.sql.queries) |query| {
        if (sqlQueryIsReadOnly(query))
            try read_names.append(allocator, query.name)
        else
            try write_names.append(allocator, query.name);
    }

    const sql_read = try sortedSection(allocator, read_names.items);
    errdefer allocator.free(sql_read);
    const sql_write = try sortedSection(allocator, write_names.items);

    return .{
        .env = env,
        .cache = cache,
        .sql_read = sql_read,
        .sql_write = sql_write,
    };
}

fn sortedSection(allocator: std.mem.Allocator, values: []const []const u8) IndexError![]const []const u8 {
    if (values.len > max_policy_entries) return error.TooManyEntries;
    for (values) |value| {
        if (value.len == 0) return error.EntryEmpty;
        if (value.len > max_identifier_bytes) return error.EntryTooLong;
    }

    const out = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(out);
    @memcpy(out, values);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var index: usize = 1;
    while (index < out.len) : (index += 1) {
        if (std.mem.eql(u8, out[index - 1], out[index])) return error.DuplicateEntry;
    }
    return out;
}

pub const PolicyCategory = enum {
    env,
    egress,
    cache,
    sql,
};

/// Only one shape survives. `dynamic_not_allowed` was removed with POL002,
/// POL004, POL006 and POL008: the strict checker reports any non-literal
/// argument to a capability export as ZTS602 at error severity, and both the
/// check path and the build path return on strict errors before the contract
/// is built, so `contract.<category>.dynamic` is never true by the time this
/// runs. The language refuses all dynamic capability access unconditionally,
/// which is strictly broader than any allow-list could express.
pub const ViolationKind = enum {
    literal_not_allowed,
};

pub const PolicyViolation = struct {
    category: PolicyCategory,
    kind: ViolationKind,
    value: ?[]const u8 = null,
    introduced_by_patch: bool = false,
};

pub const ValidationReport = struct {
    violations: std.ArrayListUnmanaged(PolicyViolation) = .empty,

    pub fn deinit(self: *ValidationReport, allocator: std.mem.Allocator) void {
        self.violations.deinit(allocator);
    }

    pub fn hasViolations(self: *const ValidationReport) bool {
        return self.violations.items.len > 0;
    }
};

pub fn parsePolicyJson(allocator: std.mem.Allocator, source: []const u8) !HandlerPolicy {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPolicy;

    const root = parsed.value.object;
    var iter = root.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "env") and
            !std.mem.eql(u8, key, "egress") and
            !std.mem.eql(u8, key, "cache") and
            !std.mem.eql(u8, key, "sql"))
        {
            return error.InvalidPolicy;
        }
    }

    return .{
        .env = try parseSection(allocator, root, "env", "allow"),
        .egress = try parseSection(allocator, root, "egress", "allow_hosts"),
        .cache = try parseSection(allocator, root, "cache", "allow_namespaces"),
        .sql = try parseSection(allocator, root, "sql", "allow_queries"),
    };
}

pub fn validateContract(
    allocator: std.mem.Allocator,
    contract: *const HandlerContract,
    policy: *const HandlerPolicy,
) !ValidationReport {
    var report = ValidationReport{};
    errdefer report.deinit(allocator);

    if (policy.env) |section| {
        for (contract.env.literal.items) |item| {
            if (!section.contains(item, false)) {
                try report.violations.append(allocator, .{
                    .category = .env,
                    .kind = .literal_not_allowed,
                    .value = item,
                });
            }
        }
    }

    if (policy.egress) |section| {
        for (contract.egress.hosts.items) |item| {
            if (!section.contains(item, true)) {
                try report.violations.append(allocator, .{
                    .category = .egress,
                    .kind = .literal_not_allowed,
                    .value = item,
                });
            }
        }
    }

    if (policy.cache) |section| {
        for (contract.cache.namespaces.items) |item| {
            if (!section.contains(item, false)) {
                try report.violations.append(allocator, .{
                    .category = .cache,
                    .kind = .literal_not_allowed,
                    .value = item,
                });
            }
        }
    }

    if (policy.sql) |section| {
        for (contract.sql.queries.items) |query| {
            if (!section.contains(query.name, false)) {
                try report.violations.append(allocator, .{
                    .category = .sql,
                    .kind = .literal_not_allowed,
                    .value = query.name,
                });
            }
        }
    }

    return report;
}

pub fn formatViolations(report: *const ValidationReport, writer: anytype) !void {
    for (report.violations.items) |violation| {
        switch (violation.kind) {
            .literal_not_allowed => {
                try writer.print(
                    "policy violation: {s} '{s}' is not allowed\n",
                    .{ categoryLiteralLabel(violation.category), violation.value.? },
                );
            },
        }
    }
}

fn parseSection(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    section_name: []const u8,
    field_name: []const u8,
) !?AllowList {
    const raw_section = root.get(section_name) orelse return null;
    if (raw_section != .object) return error.InvalidPolicy;

    const section_obj = raw_section.object;
    var iter = section_obj.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, field_name)) return error.InvalidPolicy;
    }

    const raw_allow = section_obj.get(field_name) orelse return error.InvalidPolicy;
    if (raw_allow != .array) return error.InvalidPolicy;

    var section = AllowList{};
    errdefer section.deinit(allocator);

    for (raw_allow.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidPolicy;
        try section.appendUnique(allocator, item.string);
    }

    return section;
}

pub fn categoryLiteralLabel(category: PolicyCategory) []const u8 {
    return switch (category) {
        .env => "env var",
        .egress => "outbound host",
        .cache => "cache namespace",
        .sql => "sql query",
    };
}

pub fn categoryDynamicLabel(category: PolicyCategory) []const u8 {
    return switch (category) {
        .env => "env",
        .egress => "outbound host",
        .cache => "cache namespace",
        .sql => "sql query",
    };
}

test "parse policy json with all sections" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "env": { "allow": ["JWT_SECRET", "API_KEY"] },
        \\  "egress": { "allow_hosts": ["api.example.com"] },
        \\  "cache": { "allow_namespaces": ["sessions"] }
        \\}
    ;

    var policy = try parsePolicyJson(allocator, source);
    defer policy.deinit(allocator);

    try std.testing.expect(policy.env != null);
    try std.testing.expect(policy.egress != null);
    try std.testing.expect(policy.cache != null);
    try std.testing.expectEqual(@as(usize, 2), policy.env.?.values.items.len);
    try std.testing.expectEqualStrings("api.example.com", policy.egress.?.values.items[0]);
    try std.testing.expectEqualStrings("sessions", policy.cache.?.values.items[0]);
}

test "parse policy json rejects unknown sections" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "modules": { "allow": ["zttp:env"] }
        \\}
    ;

    try std.testing.expectError(error.InvalidPolicy, parsePolicyJson(allocator, source));
}

test "validate contract rejects disallowed literals" {
    const allocator = std.testing.allocator;

    const path = try allocator.dupe(u8, "handler.ts");
    var env_literals: std.ArrayList([]const u8) = .empty;
    try env_literals.append(allocator, try allocator.dupe(u8, "JWT_SECRET"));
    var hosts: std.ArrayList([]const u8) = .empty;
    try hosts.append(allocator, try allocator.dupe(u8, "api.example.com"));
    var namespaces: std.ArrayList([]const u8) = .empty;
    try namespaces.append(allocator, try allocator.dupe(u8, "sessions"));

    var contract = HandlerContract{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = env_literals, .dynamic = true },
        .egress = .{ .hosts = hosts, .dynamic = false },
        .cache = .{ .namespaces = namespaces, .dynamic = false },
        .sql = contract_mod.emptySqlInfo(),
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
        },
        .scope = .{
            .used = false,
            .names = .empty,
            .dynamic = false,
            .max_depth = 0,
        },
        .api = contract_mod.emptyApiInfo(),
        .verification = null,
        .aot = null,
    };
    defer contract.deinit(allocator);

    var policy = HandlerPolicy{
        .env = .{},
        .egress = .{},
        .cache = .{},
    };
    defer policy.deinit(allocator);
    try policy.env.?.appendUnique(allocator, "PUBLIC_KEY");
    try policy.egress.?.appendUnique(allocator, "api.example.com");
    try policy.cache.?.appendUnique(allocator, "metrics");

    var report = try validateContract(allocator, &contract, &policy);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), report.violations.items.len);
    try std.testing.expectEqual(PolicyCategory.env, report.violations.items[0].category);
    try std.testing.expectEqual(ViolationKind.literal_not_allowed, report.violations.items[0].kind);
    try std.testing.expectEqual(PolicyCategory.cache, report.violations.items[1].category);
    try std.testing.expectEqual(ViolationKind.literal_not_allowed, report.violations.items[1].kind);
}

test "runtime policy host matching is case insensitive" {
    const policy = RuntimePolicy{
        .egress = .{
            .enabled = true,
            .values = &[_][]const u8{"API.EXAMPLE.COM"},
        },
    };

    try std.testing.expect(policy.allowsEgressHost("api.example.com"));
    try std.testing.expect(!policy.allowsEgressHost("other.example.com"));
}

test "contractToRuntimePolicy restricts static sections" {
    const allocator = std.testing.allocator;

    const path = try allocator.dupe(u8, "handler.ts");
    var env_literals: std.ArrayList([]const u8) = .empty;
    try env_literals.append(allocator, try allocator.dupe(u8, "API_KEY"));
    try env_literals.append(allocator, try allocator.dupe(u8, "DB_URL"));
    var hosts: std.ArrayList([]const u8) = .empty;
    try hosts.append(allocator, try allocator.dupe(u8, "api.stripe.com"));
    var namespaces: std.ArrayList([]const u8) = .empty;
    try namespaces.append(allocator, try allocator.dupe(u8, "sessions"));

    var contract = HandlerContract{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = env_literals, .dynamic = false },
        .egress = .{ .hosts = hosts, .dynamic = false },
        .cache = .{ .namespaces = namespaces, .dynamic = false },
        .sql = contract_mod.emptySqlInfo(),
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
        },
        .scope = .{
            .used = false,
            .names = .empty,
            .dynamic = false,
            .max_depth = 0,
        },
        .api = contract_mod.emptyApiInfo(),
        .verification = null,
        .aot = null,
    };
    defer contract.deinit(allocator);

    const policy = contractToRuntimePolicy(&contract, null);

    // All sections should be restricted
    try std.testing.expect(policy.env.enabled);
    try std.testing.expect(policy.egress.enabled);
    try std.testing.expect(policy.cache.enabled);

    // Should allow proven values
    try std.testing.expect(policy.allowsEnv("API_KEY"));
    try std.testing.expect(policy.allowsEnv("DB_URL"));
    try std.testing.expect(!policy.allowsEnv("SECRET"));

    try std.testing.expect(policy.allowsEgressHost("api.stripe.com"));
    try std.testing.expect(!policy.allowsEgressHost("evil.com"));

    try std.testing.expect(policy.allowsCacheNamespace("sessions"));
    try std.testing.expect(!policy.allowsCacheNamespace("other"));
}

test "runtime SQL policy splits read and write queries by statement operation" {
    const queries = [_]contract_mod.SqlQueryInfo{
        .{
            .name = "listTodos",
            .statement = "SELECT id, title FROM todos",
            .operation = "",
            .tables = .empty,
        },
        .{
            .name = "insertTodo",
            .statement = "INSERT INTO todos(title) VALUES (:title)",
            .operation = "",
            .tables = .empty,
        },
    };
    const policy = RuntimePolicy{
        .sql = .{ .enabled = true, .queries = &queries },
    };

    try std.testing.expect(policy.allowsSqlQuery("listTodos"));
    try std.testing.expect(!policy.allowsSqlWrite("listTodos"));
    try std.testing.expect(!policy.allowsSqlQuery("insertTodo"));
    try std.testing.expect(policy.allowsSqlWrite("insertTodo"));
}

test "a dynamic section denies everything unless a policy names it" {
    const allocator = std.testing.allocator;

    const path = try allocator.dupe(u8, "handler.ts");
    var env_literals: std.ArrayList([]const u8) = .empty;
    try env_literals.append(allocator, try allocator.dupe(u8, "API_KEY"));

    var contract = HandlerContract{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = env_literals, .dynamic = true }, // dynamic
        .egress = .{ .hosts = .empty, .dynamic = false }, // static, empty
        .cache = .{ .namespaces = .empty, .dynamic = true }, // dynamic
        .sql = contract_mod.emptySqlInfo(),
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
        },
        .scope = .{
            .used = false,
            .names = .empty,
            .dynamic = false,
            .max_depth = 0,
        },
        .api = contract_mod.emptyApiInfo(),
        .verification = null,
        .aot = null,
    };
    defer contract.deinit(allocator);

    // No configured policy: a computed environment key or cache namespace
    // reaches an enabled, empty allowlist. This is the security probe. Before
    // it, both sections came back disabled, and a disabled section admits every
    // value a handler asks for.
    const denied = contractToRuntimePolicy(&contract, null);
    try std.testing.expect(denied.env.enabled);
    try std.testing.expect(!denied.allowsEnv("ANYTHING"));
    try std.testing.expect(!denied.allowsEnv("API_KEY"));
    try std.testing.expect(denied.cache.enabled);
    try std.testing.expect(!denied.allowsCacheNamespace("anything"));

    // Static but empty: restricted to nothing, as before.
    try std.testing.expect(denied.egress.enabled);
    try std.testing.expect(!denied.allowsEgressHost("any.host"));

    // A configured section, and only a configured section, supplies the
    // entries a dynamic category may reach.
    var configured = HandlerPolicy{};
    defer configured.deinit(allocator);
    var env_allowed = AllowList{};
    try env_allowed.appendUnique(allocator, "RUNTIME_KEY");
    configured.env = env_allowed;

    const allowed = contractToRuntimePolicy(&contract, &configured);
    try std.testing.expect(allowed.allowsEnv("RUNTIME_KEY"));
    // The contract's own literal is not authority for a dynamic category: the
    // compiler did not see every key this handler reads.
    try std.testing.expect(!allowed.allowsEnv("API_KEY"));
    // A category the policy leaves out is still deny-all, not inherited.
    try std.testing.expect(!allowed.allowsCacheNamespace("anything"));
}

test "the installed index answers inside the measured comparison bound" {
    const allocator = std.testing.allocator;

    var names: [max_policy_entries][8]u8 = undefined;
    var values: [max_policy_entries][]const u8 = undefined;
    var index: usize = 0;
    while (index < max_policy_entries) : (index += 1) {
        // Reverse insertion order, so a lookup that happened to work on the
        // caller's order rather than on the sort would answer wrongly.
        values[index] = try std.fmt.bufPrint(
            &names[index],
            "k{d:0>5}",
            .{max_policy_entries - 1 - index},
        );
    }

    var built = try buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &values } });
    defer built.deinit(allocator);

    var worst: usize = 0;
    index = 0;
    while (index < max_policy_entries) : (index += 1) {
        var comparisons: usize = 0;
        try std.testing.expect(built.allowsCounting(.env, values[index], &comparisons));
        worst = @max(worst, comparisons);
    }
    for ([_][]const u8{ "a00000", "k00000x", "z00000" }) |absent| {
        var comparisons: usize = 0;
        try std.testing.expect(!built.allowsCounting(.env, absent, &comparisons));
        worst = @max(worst, comparisons);
    }
    try std.testing.expectEqual(max_lookup_comparisons, worst);
}

test "the index refuses a policy it could not enforce as written" {
    const allocator = std.testing.allocator;

    const empty = [_][]const u8{""};
    try std.testing.expectError(
        error.EntryEmpty,
        buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &empty } }),
    );

    var long_buf: [max_identifier_bytes + 1]u8 = @splat('k');
    const long = [_][]const u8{&long_buf};
    try std.testing.expectError(
        error.EntryTooLong,
        buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &long } }),
    );

    // The first byte over the cap rejects; the cap itself passes.
    const at_cap = [_][]const u8{long_buf[0..max_identifier_bytes]};
    var ok = try buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &at_cap } });
    ok.deinit(allocator);

    const duplicated = [_][]const u8{ "API_KEY", "API_KEY" };
    try std.testing.expectError(
        error.DuplicateEntry,
        buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &duplicated } }),
    );

    var over: [max_policy_entries + 1][8]u8 = undefined;
    var over_values: [max_policy_entries + 1][]const u8 = undefined;
    var index: usize = 0;
    while (index < over_values.len) : (index += 1) {
        over_values[index] = try std.fmt.bufPrint(&over[index], "k{d:0>5}", .{index});
    }
    try std.testing.expectError(
        error.TooManyEntries,
        buildIndex(allocator, .{ .env = .{ .enabled = true, .values = &over_values } }),
    );
    var at_entry_cap = try buildIndex(allocator, .{
        .env = .{ .enabled = true, .values = over_values[0..max_policy_entries] },
    });
    at_entry_cap.deinit(allocator);
}

test "the index keeps a named read out of the write section" {
    const allocator = std.testing.allocator;
    const queries = [_]contract_mod.SqlQueryInfo{
        .{ .name = "listTodos", .statement = "SELECT id FROM todos", .operation = "", .tables = .empty },
        .{ .name = "insertTodo", .statement = "INSERT INTO todos(title) VALUES (:title)", .operation = "", .tables = .empty },
    };
    var built = try buildIndex(allocator, .{ .sql = .{ .enabled = true, .queries = &queries } });
    defer built.deinit(allocator);

    try std.testing.expect(built.allows(.sql_read, "listTodos"));
    try std.testing.expect(!built.allows(.sql_write, "listTodos"));
    try std.testing.expect(built.allows(.sql_write, "insertTodo"));
    try std.testing.expect(!built.allows(.sql_read, "insertTodo"));
}
