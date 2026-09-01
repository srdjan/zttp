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
const endpoint = @import("zts-base").endpoint;
const guard_catalog = @import("zts-base").guard_catalog;

const HandlerContract = contract_mod.HandlerContract;

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
        if (self.contains(item)) return;
        try self.values.append(allocator, try allocator.dupe(u8, item));
    }

    /// Exact, for every category. Egress used to compare case-insensitively
    /// because it held host names; it holds normalized endpoints now, and the
    /// folding happens in `zts.endpoint` before a value reaches this list.
    fn contains(self: *const AllowList, candidate: []const u8) bool {
        for (self.values.items) |item| {
            if (std.mem.eql(u8, item, candidate)) return true;
        }
        return false;
    }
};

pub const HandlerPolicy = struct {
    env: ?AllowList = null,
    /// Normalized `scheme://host:port` entries, from `egress.allow_endpoints`.
    egress: ?AllowList = null,
    /// Which resolved-address scopes a connection may land in, from
    /// `egress.allow_address_scopes`. Empty permits none: an endpoint says
    /// which name and port may be reached, and this says which addresses that
    /// name is allowed to answer with, so a policy that names endpoints and no
    /// scopes has not yet said a connection may happen.
    egress_scopes: endpoint.ScopeSet = .{},
    cache: ?AllowList = null,
    sql: ?AllowList = null,

    /// Which sections this policy file declares.
    ///
    /// A section that is absent and a section that is present with an empty list
    /// are two different answers: the first says the author has not decided, the
    /// second says the author decided nothing is allowed. The compiler needs the
    /// first to refuse a computed resource that would have nothing to be checked
    /// against.
    pub fn declaredSections(self: *const HandlerPolicy) guard_catalog.SectionSet {
        var sections = guard_catalog.SectionSet{};
        if (self.env != null) sections = sections.with(.env);
        if (self.egress != null) sections = sections.with(.egress);
        if (self.cache != null) sections = sections.with(.cache);
        if (self.sql != null) sections = sections.with(.sql);
        return sections;
    }

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
/// The serialized runtime capability policy accepted by either decoder.
pub const max_policy_bytes: usize = 256 * 1024;
/// An environment key, cache namespace, or SQL query name.
pub const max_identifier_bytes: usize = 255;
/// A normalized `scheme://host:port`.
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
    /// Normalized `scheme://host:port` entries. Compared byte for byte,
    /// because both sides normalized first: case folding and the default port
    /// happened in `zts.endpoint`, not in the comparison.
    egress: RuntimeAllowList = .{},
    /// Which resolved-address scopes a connection may land in. Supplied by the
    /// configured policy; empty names none.
    egress_scopes: endpoint.ScopeSet = .{},
    cache: RuntimeAllowList = .{},
    sql: RuntimeSqlAllowList = .{},
    /// Present only on a consumer-accepted guarded runtime generation. The
    /// generation owns this index and outlives every RuntimePolicy copy that
    /// points at it. Static-only generations leave it null and retain the
    /// literal allowlist path.
    installed_index: ?*const RuntimePolicyIndex = null,

    pub fn allowsEnv(self: RuntimePolicy, key: []const u8) bool {
        if (!self.env.enabled) return true;
        if (self.installed_index) |index| return index.allows(.env, key);
        return self.env.allows(key);
    }

    /// Whether an already-normalized endpoint is allowed.
    ///
    /// The caller normalizes: a value that reaches here unnormalized is a value
    /// no entry matches, which denies. That is the safe direction, and it is
    /// why this takes the canonical form rather than a URL.
    pub fn allowsEgressEndpoint(self: RuntimePolicy, normalized: []const u8) bool {
        if (!self.egress.enabled) return true;
        if (self.installed_index) |index| return index.allows(.egress, normalized);
        return self.egress.allows(normalized);
    }

    /// Whether a resolved address may be connected to.
    pub fn allowsAddressScope(self: RuntimePolicy, scope: endpoint.AddressScope) bool {
        return self.egress_scopes.contains(scope);
    }

    pub fn allowsCacheNamespace(self: RuntimePolicy, ns: []const u8) bool {
        if (!self.cache.enabled) return true;
        if (self.installed_index) |index| return index.allows(.cache, ns);
        return self.cache.allows(ns);
    }

    pub fn allowsSqlQuery(self: RuntimePolicy, name: []const u8) bool {
        if (!self.sql.enabled) return true;
        if (self.installed_index) |index| return index.allows(.sql_read, name);
        return self.sql.allowsRead(name);
    }

    pub fn allowsSqlWrite(self: RuntimePolicy, name: []const u8) bool {
        if (!self.sql.enabled) return true;
        if (self.installed_index) |index| return index.allows(.sql_write, name);
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
            contract.egress.endpoints.items,
            if (configured) |policy| policy.egress else null,
        ),
        // Scopes are the policy file's to grant. A contract proves which
        // endpoint a handler names; it cannot prove what that name will resolve
        // to at run time, so there is nothing here to derive them from.
        .egress_scopes = if (configured) |policy| policy.egress_scopes else .{},
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

/// Whether a contract has a capability resource that must be decided by a
/// residual runtime guard. Such generations install the bounded lookup index;
/// fully static generations keep the literal lookup path and no index.
pub fn contractRequiresRuntimePolicyIndex(contract: *const HandlerContract) bool {
    return contract.env.dynamic or
        contract.egress.dynamic or
        contract.cache.dynamic or
        contract.sql.dynamic;
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
/// Egress entries are normalized endpoints, so their comparison is exact just
/// like every other section. Case folding and default-port expansion happen
/// before either the policy or a request reaches this index.
pub const RuntimePolicyIndex = struct {
    env: []const []const u8,
    egress: []const []const u8,
    cache: []const []const u8,
    sql_read: []const []const u8,
    sql_write: []const []const u8,

    pub const Section = enum { env, egress, cache, sql_read, sql_write };

    pub fn deinit(self: *RuntimePolicyIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.env);
        allocator.free(self.egress);
        allocator.free(self.cache);
        allocator.free(self.sql_read);
        allocator.free(self.sql_write);
        self.* = undefined;
    }

    pub fn entries(self: *const RuntimePolicyIndex, section: Section) []const []const u8 {
        return switch (section) {
            .env => self.env,
            .egress => self.egress,
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
    try validateRuntimePolicy(policy);
    const env = try sortedSection(allocator, policy.env.values, max_identifier_bytes);
    errdefer allocator.free(env);
    const egress = try sortedSection(allocator, policy.egress.values, max_endpoint_bytes);
    errdefer allocator.free(egress);
    const cache = try sortedSection(allocator, policy.cache.values, max_identifier_bytes);
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

    const sql_read = try sortedSection(allocator, read_names.items, max_identifier_bytes);
    errdefer allocator.free(sql_read);
    const sql_write = try sortedSection(allocator, write_names.items, max_identifier_bytes);

    return .{
        .env = env,
        .egress = egress,
        .cache = cache,
        .sql_read = sql_read,
        .sql_write = sql_write,
    };
}

/// Validate the limits and uniqueness a runtime generation relies on before
/// allocating owned backing. Static-only generations call this too, without
/// constructing an index, so malformed borrowed input never becomes an
/// oversized long-lived allocation.
pub fn validateRuntimePolicy(policy: RuntimePolicy) IndexError!void {
    try validateRuntimeValues(policy.env.values, max_identifier_bytes);
    try validateRuntimeValues(policy.egress.values, max_endpoint_bytes);
    try validateRuntimeValues(policy.cache.values, max_identifier_bytes);

    const sql_count = std.math.add(
        usize,
        policy.sql.values.len,
        policy.sql.queries.len,
    ) catch return error.TooManyEntries;
    if (sql_count > max_policy_entries) return error.TooManyEntries;
    try validateRuntimeValues(policy.sql.values, max_identifier_bytes);
    for (policy.sql.queries, 0..) |query, index| {
        try validateRuntimeValue(query.name, max_identifier_bytes);
        for (policy.sql.values) |value| {
            if (std.mem.eql(u8, value, query.name)) return error.DuplicateEntry;
        }
        for (policy.sql.queries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, query.name)) return error.DuplicateEntry;
        }
    }
}

fn validateRuntimeValues(values: []const []const u8, max_entry_bytes: usize) IndexError!void {
    if (values.len > max_policy_entries) return error.TooManyEntries;
    for (values, 0..) |value, index| {
        try validateRuntimeValue(value, max_entry_bytes);
        for (values[0..index]) |previous| {
            if (std.mem.eql(u8, previous, value)) return error.DuplicateEntry;
        }
    }
}

fn validateRuntimeValue(value: []const u8, max_entry_bytes: usize) IndexError!void {
    if (value.len == 0) return error.EntryEmpty;
    if (value.len > max_entry_bytes) return error.EntryTooLong;
}

fn sortedSection(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    max_entry_bytes: usize,
) IndexError![]const []const u8 {
    if (values.len > max_policy_entries) return error.TooManyEntries;
    for (values) |value| {
        if (value.len == 0) return error.EntryEmpty;
        if (value.len > max_entry_bytes) return error.EntryTooLong;
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

/// One line telling a developer what a refused policy file got wrong, for the
/// errors where the error name alone does not say. Lives here, beside the
/// reader that produces them, so every command reports the same thing.
pub fn policyErrorHelp(err: anyerror) []const u8 {
    return switch (err) {
        error.EgressAllowHostsRetired =>
        \\egress.allow_hosts was replaced by egress.allow_endpoints, which names
        \\destinations as scheme://host:port, and egress.allow_address_scopes,
        \\which names the resolved addresses those may answer with. A host list
        \\could not say which scheme or port it meant.
        ,
        error.InvalidEgressEndpoint =>
        \\an egress.allow_endpoints entry is not a destination this runtime can
        \\canonicalize. Write scheme://host[:port] with http or https, and no
        \\userinfo: a bare host names no destination.
        ,
        error.UnknownAddressScope =>
        \\an egress.allow_address_scopes entry names no known scope. The set is
        \\public, private, loopback, link_local, multicast, unspecified.
        ,
        else => "",
    };
}

pub const scopes_field = "allow_address_scopes";
pub const endpoints_field = "allow_endpoints";
/// The key this file used to read. Named here so the parser can say what
/// replaced it rather than reporting an unknown key.
pub const retired_hosts_field = "allow_hosts";

/// The sections a policy file declares, read straight from its bytes.
///
/// A file that does not parse declares nothing here. That is not this
/// function's message to deliver: the policy diagnostics path parses the same
/// bytes and reports the parse failure with a code and a location, and a
/// compile that cannot read its policy fails there rather than silently
/// classifying against an imagined one.
pub fn declaredSectionsFromJson(
    allocator: std.mem.Allocator,
    source: []const u8,
) guard_catalog.SectionSet {
    var policy = parsePolicyJson(allocator, source) catch return .{};
    defer policy.deinit(allocator);
    return policy.declaredSections();
}

pub fn parsePolicyJson(allocator: std.mem.Allocator, source: []const u8) !HandlerPolicy {
    if (source.len > max_policy_bytes) return error.PolicyTooLarge;
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

    var policy = HandlerPolicy{
        .env = try parseSection(allocator, root, "env", "allow"),
        .cache = try parseSection(allocator, root, "cache", "allow_namespaces"),
        .sql = try parseSection(allocator, root, "sql", "allow_queries"),
    };
    errdefer policy.deinit(allocator);
    const egress = try parseEgressSection(allocator, root);
    policy.egress = egress.allow;
    policy.egress_scopes = egress.scopes;
    return policy;
}

const EgressSection = struct {
    allow: ?AllowList = null,
    scopes: endpoint.ScopeSet = .{},
};

/// `egress` carries two fields, and both are load-bearing.
///
/// `allow_endpoints` replaced `allow_hosts` outright: a host list cannot say
/// which scheme or port it meant, and the same host under another scheme or
/// port is another server. Entries are normalized here, so the file may write
/// `https://api.example.com` and the runtime compares
/// `https://api.example.com:443`; a form the rule cannot canonicalize is a
/// policy error rather than an entry nothing will ever match.
fn parseEgressSection(allocator: std.mem.Allocator, root: std.json.ObjectMap) !EgressSection {
    const raw_section = root.get("egress") orelse return .{};
    if (raw_section != .object) return error.InvalidPolicy;
    const section_obj = raw_section.object;

    var iter = section_obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, retired_hosts_field)) return error.EgressAllowHostsRetired;
        if (!std.mem.eql(u8, key, endpoints_field) and !std.mem.eql(u8, key, scopes_field)) {
            return error.InvalidPolicy;
        }
    }

    const raw_allow = section_obj.get(endpoints_field) orelse return error.InvalidPolicy;
    if (raw_allow != .array) return error.InvalidPolicy;
    if (raw_allow.array.items.len > max_policy_entries) return error.TooManyEntries;

    var allow = AllowList{};
    errdefer allow.deinit(allocator);
    for (raw_allow.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidPolicy;
        var buf: [endpoint.max_endpoint_bytes]u8 = undefined;
        const normalized = endpoint.normalize(item.string, &buf) catch return error.InvalidEgressEndpoint;
        if (allow.contains(normalized)) return error.DuplicateEntry;
        try allow.appendUnique(allocator, normalized);
    }

    var scopes = endpoint.ScopeSet{};
    if (section_obj.get(scopes_field)) |raw_scopes| {
        if (raw_scopes != .array) return error.InvalidPolicy;
        for (raw_scopes.array.items) |item| {
            if (item != .string) return error.InvalidPolicy;
            const scope = endpoint.AddressScope.fromText(item.string) orelse
                return error.UnknownAddressScope;
            if (scopes.contains(scope)) return error.DuplicateEntry;
            scopes = scopes.with(scope);
        }
    }

    return .{ .allow = allow, .scopes = scopes };
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
            if (!section.contains(item)) {
                try report.violations.append(allocator, .{
                    .category = .env,
                    .kind = .literal_not_allowed,
                    .value = item,
                });
            }
        }
    }

    if (policy.egress) |section| {
        // Both sides hold normalized endpoints - the contract from the
        // compiler, the section from the policy reader - so this compares
        // exactly, like every other category. The case-insensitive match this
        // used to do belonged to host names.
        for (contract.egress.endpoints.items) |item| {
            if (!section.contains(item)) {
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
            if (!section.contains(item)) {
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
            if (!section.contains(query.name)) {
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
    if (raw_allow.array.items.len > max_policy_entries) return error.TooManyEntries;

    var section = AllowList{};
    errdefer section.deinit(allocator);

    for (raw_allow.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidPolicy;
        if (item.string.len > max_identifier_bytes) return error.EntryTooLong;
        if (section.contains(item.string)) return error.DuplicateEntry;
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
        \\  "egress": {
        \\    "allow_endpoints": ["https://api.example.com"],
        \\    "allow_address_scopes": ["public"]
        \\  },
        \\  "cache": { "allow_namespaces": ["sessions"] }
        \\}
    ;

    var policy = try parsePolicyJson(allocator, source);
    defer policy.deinit(allocator);

    try std.testing.expect(policy.env != null);
    try std.testing.expect(policy.egress != null);
    try std.testing.expect(policy.cache != null);
    try std.testing.expectEqual(@as(usize, 2), policy.env.?.values.items.len);
    // The file may write the endpoint any way the rule accepts; what is stored
    // is the canonical form the runtime will compare.
    try std.testing.expectEqualStrings("https://api.example.com:443", policy.egress.?.values.items[0]);
    try std.testing.expectEqualStrings("sessions", policy.cache.?.values.items[0]);
    try std.testing.expect(policy.egress_scopes.contains(.public));
    try std.testing.expect(!policy.egress_scopes.contains(.loopback));
}

test "the retired egress key names its replacement" {
    const allocator = std.testing.allocator;
    const source =
        \\{ "egress": { "allow_hosts": ["api.example.com"] } }
    ;
    // Not "unknown key": a host list read as an endpoint list would permit
    // nothing it names, and the reader should say which key took its place.
    try std.testing.expectError(
        error.EgressAllowHostsRetired,
        parsePolicyJson(allocator, source),
    );

    // The developer is told the replacement, not only that something failed.
    const help = policyErrorHelp(error.EgressAllowHostsRetired);
    try std.testing.expect(std.mem.indexOf(u8, help, endpoints_field) != null);
    try std.testing.expect(std.mem.indexOf(u8, help, scopes_field) != null);
    try std.testing.expect(policyErrorHelp(error.InvalidEgressEndpoint).len > 0);
    try std.testing.expect(policyErrorHelp(error.UnknownAddressScope).len > 0);
    // An error with nothing extra to say says nothing rather than something
    // generic, which is how the caller decides whether to print a second line.
    try std.testing.expectEqualStrings("", policyErrorHelp(error.InvalidPolicy));
}

test "an egress section the rule cannot read is a policy error" {
    const allocator = std.testing.allocator;

    // A bare host names no destination.
    try std.testing.expectError(error.InvalidEgressEndpoint, parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["api.example.com"] } }
    ));
    // A scheme outside the set, and userinfo, which reads as the allowed host.
    try std.testing.expectError(error.InvalidEgressEndpoint, parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["ftp://api.example.com"] } }
    ));
    try std.testing.expectError(error.InvalidEgressEndpoint, parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["https://allowed.example@evil.example"] } }
    ));
    // A scope name outside the alphabet is not "some scope we do not model".
    try std.testing.expectError(error.UnknownAddressScope, parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["https://a.example"], "allow_address_scopes": ["everywhere"] } }
    ));
    // An endpoints list is required; a section with only scopes says where a
    // connection may land without saying which one may be made.
    try std.testing.expectError(error.InvalidPolicy, parsePolicyJson(allocator,
        \\{ "egress": { "allow_address_scopes": ["public"] } }
    ));
}

test "an egress section with no address scope permits no connection" {
    const allocator = std.testing.allocator;
    var policy = try parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["https://api.example.com"] } }
    );
    defer policy.deinit(allocator);

    // The endpoint is named, so the destination is allowed - and no resolved
    // address may be connected to, because the section granted no scope.
    try std.testing.expect(policy.egress.?.values.items.len == 1);
    try std.testing.expect(policy.egress_scopes.isEmpty());
    inline for (@typeInfo(endpoint.AddressScope).@"enum".fields) |field| {
        const scope: endpoint.AddressScope = @enumFromInt(field.value);
        try std.testing.expect(!policy.egress_scopes.contains(scope));
    }
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

test "policy readers reject oversized and duplicate authority" {
    const allocator = std.testing.allocator;

    const oversized = try allocator.alloc(u8, max_policy_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.PolicyTooLarge, parsePolicyJson(allocator, oversized));

    try std.testing.expectError(error.DuplicateEntry, parsePolicyJson(allocator,
        \\{ "env": { "allow": ["API_KEY", "API_KEY"] } }
    ));
    try std.testing.expectError(error.DuplicateEntry, parsePolicyJson(allocator,
        \\{ "egress": { "allow_endpoints": ["https://API.example", "https://api.example:443"] } }
    ));
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
        .egress = .{ .endpoints = hosts, .dynamic = false },
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

test "the egress comparison is exact, because both sides normalized first" {
    // Case folding and the default port happen in `zts.endpoint`, before either
    // side of this comparison. An entry that reaches the list unnormalized is
    // an entry nothing matches, which denies - the safe direction.
    const policy = RuntimePolicy{
        .egress = .{
            .enabled = true,
            .values = &[_][]const u8{"https://api.example.com:443"},
        },
    };

    try std.testing.expect(policy.allowsEgressEndpoint("https://api.example.com:443"));
    try std.testing.expect(!policy.allowsEgressEndpoint("https://other.example.com:443"));
    // The same host, another scheme or port, is another server.
    try std.testing.expect(!policy.allowsEgressEndpoint("http://api.example.com:80"));
    try std.testing.expect(!policy.allowsEgressEndpoint("https://api.example.com:8443"));
    // A caller that skipped normalization gets no match rather than a lenient one.
    try std.testing.expect(!policy.allowsEgressEndpoint("https://API.EXAMPLE.COM:443"));
    try std.testing.expect(!policy.allowsEgressEndpoint("api.example.com"));

    // Scopes are a separate grant, and an empty set names none.
    try std.testing.expect(!policy.allowsAddressScope(.public));
    try std.testing.expect(!policy.allowsAddressScope(.loopback));
    const scoped = RuntimePolicy{ .egress_scopes = (endpoint.ScopeSet{}).with(.public) };
    try std.testing.expect(scoped.allowsAddressScope(.public));
    try std.testing.expect(!scoped.allowsAddressScope(.loopback));
}

test "contractToRuntimePolicy restricts static sections" {
    const allocator = std.testing.allocator;

    const path = try allocator.dupe(u8, "handler.ts");
    var env_literals: std.ArrayList([]const u8) = .empty;
    try env_literals.append(allocator, try allocator.dupe(u8, "API_KEY"));
    try env_literals.append(allocator, try allocator.dupe(u8, "DB_URL"));
    var hosts: std.ArrayList([]const u8) = .empty;
    try hosts.append(allocator, try allocator.dupe(u8, "https://api.stripe.com:443"));
    var namespaces: std.ArrayList([]const u8) = .empty;
    try namespaces.append(allocator, try allocator.dupe(u8, "sessions"));

    var contract = HandlerContract{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = env_literals, .dynamic = false },
        .egress = .{ .endpoints = hosts, .dynamic = false },
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
    try std.testing.expect(!contractRequiresRuntimePolicyIndex(&contract));

    // All sections should be restricted
    try std.testing.expect(policy.env.enabled);
    try std.testing.expect(policy.egress.enabled);
    try std.testing.expect(policy.cache.enabled);

    // Should allow proven values
    try std.testing.expect(policy.allowsEnv("API_KEY"));
    try std.testing.expect(policy.allowsEnv("DB_URL"));
    try std.testing.expect(!policy.allowsEnv("SECRET"));

    try std.testing.expect(policy.allowsEgressEndpoint("https://api.stripe.com:443"));
    try std.testing.expect(!policy.allowsEgressEndpoint("https://evil.com:443"));

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
        .egress = .{ .endpoints = .empty, .dynamic = false }, // static, empty
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
    try std.testing.expect(contractRequiresRuntimePolicyIndex(&contract));
    try std.testing.expect(denied.env.enabled);
    try std.testing.expect(!denied.allowsEnv("ANYTHING"));
    try std.testing.expect(!denied.allowsEnv("API_KEY"));
    try std.testing.expect(denied.cache.enabled);
    try std.testing.expect(!denied.allowsCacheNamespace("anything"));

    // Static but empty: restricted to nothing, as before.
    try std.testing.expect(denied.egress.enabled);
    try std.testing.expect(!denied.allowsEgressEndpoint("https://any.host:443"));

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

test "authoritative policy membership selects the installed index" {
    const allocator = std.testing.allocator;
    const queries = [_]contract_mod.SqlQueryInfo{
        normalizedSqlQuery("read-indexed", true),
        normalizedSqlQuery("write-indexed", false),
    };
    var index = try buildIndex(allocator, .{
        .env = .{ .enabled = true, .values = &.{"ENV_INDEXED"} },
        .egress = .{ .enabled = true, .values = &.{"https://indexed.example:443"} },
        .cache = .{ .enabled = true, .values = &.{"cache-indexed"} },
        .sql = .{ .enabled = true, .queries = &queries },
    });
    defer index.deinit(allocator);

    var installed = RuntimePolicy{
        .env = .{ .enabled = true, .values = &.{"ENV_LINEAR"} },
        .egress = .{ .enabled = true, .values = &.{"https://linear.example:443"} },
        .cache = .{ .enabled = true, .values = &.{"cache-linear"} },
        .sql = .{ .enabled = true, .values = &.{"sql-linear"} },
        .installed_index = &index,
    };

    try std.testing.expect(installed.allowsEnv("ENV_INDEXED"));
    try std.testing.expect(!installed.allowsEnv("ENV_LINEAR"));
    try std.testing.expect(installed.allowsEgressEndpoint("https://indexed.example:443"));
    try std.testing.expect(!installed.allowsEgressEndpoint("https://linear.example:443"));
    try std.testing.expect(installed.allowsCacheNamespace("cache-indexed"));
    try std.testing.expect(!installed.allowsCacheNamespace("cache-linear"));
    try std.testing.expect(installed.allowsSqlQuery("read-indexed"));
    try std.testing.expect(!installed.allowsSqlWrite("read-indexed"));
    try std.testing.expect(installed.allowsSqlWrite("write-indexed"));
    try std.testing.expect(!installed.allowsSqlQuery("write-indexed"));
    try std.testing.expect(!installed.allowsSqlQuery("sql-linear"));

    // Disabled remains permissive even when a generation carries an index.
    installed.env.enabled = false;
    try std.testing.expect(installed.allowsEnv("not-indexed"));
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

    var endpoint_limit: [max_endpoint_bytes + 1]u8 = @splat('e');
    const endpoint_at_limit = [_][]const u8{endpoint_limit[0..max_endpoint_bytes]};
    var endpoint_ok = try buildIndex(allocator, .{
        .egress = .{ .enabled = true, .values = &endpoint_at_limit },
    });
    endpoint_ok.deinit(allocator);
    const endpoint_over_limit = [_][]const u8{&endpoint_limit};
    try std.testing.expectError(error.EntryTooLong, buildIndex(allocator, .{
        .egress = .{ .enabled = true, .values = &endpoint_over_limit },
    }));
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
