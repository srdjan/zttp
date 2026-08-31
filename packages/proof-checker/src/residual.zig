//! Residual guard obligations: the closed alphabet for operations the compiler
//! could not resolve statically.
//!
//! A residual obligation says one thing: this exact operation reaches an
//! authoritative sink that evaluates the actual resource against a named policy
//! section before the effect. It does not say the operation is safe, it does not
//! discharge a Property, and it does not predict that a future runtime value
//! will pass. A guarded operation is a permission to check at run time, not a
//! theorem.
//!
//! Everything here is closed. A producer that names a guard kind, a
//! normalization rule, a sink, or a policy section outside these sets is refused
//! at the decoder, and the catalog at the bottom is the consumer's own answer to
//! "which export argument is guardable" - it is never read from the producer.

const std = @import("std");

/// What kind of resource a guard authorizes. Five, matching the five sinks that
/// observe an actual value immediately before an effect.
pub const GuardKind = enum(u8) {
    env_key = 1,
    egress_endpoint = 2,
    cache_namespace = 3,
    sql_read = 4,
    sql_write = 5,

    pub fn fromWire(value: u8) ?GuardKind {
        return switch (value) {
            1 => .env_key,
            2 => .egress_endpoint,
            3 => .cache_namespace,
            4 => .sql_read,
            5 => .sql_write,
            else => null,
        };
    }

    pub fn name(self: GuardKind) []const u8 {
        return @tagName(self);
    }

    pub fn normalization(self: GuardKind) Normalization {
        return switch (self) {
            .env_key, .cache_namespace, .sql_read, .sql_write => .identifier_exact_v1,
            .egress_endpoint => .endpoint_v1,
        };
    }

    pub fn section(self: GuardKind) PolicySection {
        return switch (self) {
            .env_key => .env,
            .egress_endpoint => .egress,
            .cache_namespace => .cache,
            .sql_read, .sql_write => .sql,
        };
    }

    pub fn sink(self: GuardKind) SinkId {
        return switch (self) {
            .env_key => .env_read,
            .egress_endpoint => .egress_connect,
            .cache_namespace => .cache_operation,
            .sql_read, .sql_write => .sql_execute,
        };
    }
};

/// How a resource is canonicalized before it is compared with a policy entry.
///
/// Versioned, because producer, checker, policy, and runtime must agree byte for
/// byte and the only way to change that agreement is to change the rule's name.
pub const Normalization = enum(u8) {
    /// The bytes as written, at most `max_identifier_bytes`. No case folding and
    /// no trimming: an environment key, a cache namespace, and a SQL query name
    /// are identifiers, and two that differ in a byte are two names.
    identifier_exact_v1 = 1,
    /// `scheme://host:port`. Scheme and host lowercased, one trailing dot
    /// stripped from the host, the port always explicit, no userinfo, no path,
    /// at most `max_endpoint_bytes`.
    endpoint_v1 = 2,

    pub fn fromWire(value: u8) ?Normalization {
        return switch (value) {
            1 => .identifier_exact_v1,
            2 => .endpoint_v1,
            else => null,
        };
    }

    pub fn name(self: Normalization) []const u8 {
        return @tagName(self);
    }
};

/// The authoritative operation boundary that performs the check.
///
/// A sink is named so a certificate cannot point an obligation at a caller-side
/// helper. The consumer's catalog decides which sink a kind belongs to; the
/// producer only restates it, and a restatement that disagrees rejects.
pub const SinkId = enum(u8) {
    /// `module_binding/capabilities.readEnvForActiveModule`, before `getenv`.
    env_read = 1,
    /// The runtime HTTP path, before name resolution and before connecting.
    egress_connect = 2,
    /// `modules/data/cache.denyIfNamespaceBlocked`, before every store access.
    cache_operation = 3,
    /// `modules/data/sql.executeQuery`, before the store, the open, the
    /// prepare, and every step.
    sql_execute = 4,

    pub fn fromWire(value: u8) ?SinkId {
        return switch (value) {
            1 => .env_read,
            2 => .egress_connect,
            3 => .cache_operation,
            4 => .sql_execute,
            else => null,
        };
    }

    pub fn name(self: SinkId) []const u8 {
        return @tagName(self);
    }
};

/// Which allowlist in the configured capability policy answers this guard.
pub const PolicySection = enum(u8) {
    env = 1,
    egress = 2,
    cache = 3,
    sql = 4,

    pub fn fromWire(value: u8) ?PolicySection {
        return switch (value) {
            1 => .env,
            2 => .egress,
            3 => .cache,
            4 => .sql,
            else => null,
        };
    }

    pub fn name(self: PolicySection) []const u8 {
        return @tagName(self);
    }
};

/// The scope an outbound connection's resolved address falls in.
///
/// An allowlisted hostname that resolves to a loopback or private address is
/// the rebinding attack, so the scope is policy in its own right and is checked
/// after resolution and before connecting.
pub const AddressScope = enum(u8) {
    public = 1,
    private = 2,
    loopback = 3,
    link_local = 4,
    multicast = 5,
    unspecified = 6,

    pub fn fromWire(value: u8) ?AddressScope {
        return switch (value) {
            1 => .public,
            2 => .private,
            3 => .loopback,
            4 => .link_local,
            5 => .multicast,
            6 => .unspecified,
            else => null,
        };
    }

    pub fn name(self: AddressScope) []const u8 {
        return @tagName(self);
    }

    pub fn bit(self: AddressScope) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(self) - 1);
    }
};

/// The set of scopes a policy admits, as one byte.
pub const ScopeSet = struct {
    bits: u8 = 0,

    pub fn contains(self: ScopeSet, scope: AddressScope) bool {
        return self.bits & scope.bit() != 0;
    }

    pub fn with(self: ScopeSet, scope: AddressScope) ScopeSet {
        return .{ .bits = self.bits | scope.bit() };
    }

    pub fn isEmpty(self: ScopeSet) bool {
        return self.bits == 0;
    }

    /// Reject a byte that names a scope outside the alphabet, so an unknown bit
    /// cannot be read as "some scope we do not model, allow it".
    pub fn fromWire(bits: u8) ?ScopeSet {
        var known: u8 = 0;
        inline for (@typeInfo(AddressScope).@"enum".fields) |field| {
            const scope: AddressScope = @enumFromInt(field.value);
            known |= scope.bit();
        }
        if (bits & ~known != 0) return null;
        return .{ .bits = bits };
    }
};

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/// An environment key, cache namespace, or SQL query name.
pub const max_identifier_bytes: usize = 255;
/// A normalized `scheme://host:port`.
pub const max_endpoint_bytes: usize = 512;
/// Entries in one policy category.
pub const max_policy_entries: u16 = 256;
/// The serialized runtime policy the checker will read at all.
pub const max_policy_bytes: usize = 256 * 1024;
/// Key comparisons a category lookup may cost at `max_policy_entries`.
///
/// Nine, measured rather than taken from log2. A three-way binary search over
/// 256 sorted entries probes nine times in the worst case, because the last
/// probe lands on a range of one. Eight is the cost at 255 entries; reading
/// log2 of the cap and writing it down here described a search over a smaller
/// list than the cap admits.
pub const max_lookup_comparisons: usize = 9;

comptime {
    // The cost of the search, not the width of the cap. Halving the range
    // until it is empty counts the probes a lookup pays when the answer sits
    // at the last one or is not there at all.
    var range: usize = max_policy_entries;
    var comparisons: usize = 0;
    while (range > 0) : (comparisons += 1) range /= 2;
    if (comparisons != max_lookup_comparisons) {
        @compileError("the comparison cap does not describe the search over max_policy_entries");
    }
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

pub const NormalizeError = error{
    Empty,
    TooLong,
    /// Not a form this rule can canonicalize: a missing scheme, a scheme
    /// outside the set, userinfo, an empty host, a port outside range.
    Malformed,
};

/// Canonicalize a resource for its rule. `out` receives the result; the
/// returned slice points into it.
///
/// One function, called by the producer, the checker, the policy loader, and
/// the runtime sink. Four implementations of "the same" rule is how a guard
/// ends up checking a string the effect never sees.
pub fn normalize(rule: Normalization, value: []const u8, out: []u8) NormalizeError![]const u8 {
    return switch (rule) {
        .identifier_exact_v1 => normalizeIdentifier(value, out),
        .endpoint_v1 => normalizeEndpoint(value, out),
    };
}

fn normalizeIdentifier(value: []const u8, out: []u8) NormalizeError![]const u8 {
    if (value.len == 0) return error.Empty;
    if (value.len > max_identifier_bytes) return error.TooLong;
    if (value.len > out.len) return error.TooLong;
    // Control bytes are refused rather than stripped: an identifier that needs
    // stripping is a different identifier, and silently making it match a
    // policy entry is the failure this whole layer exists to prevent.
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7F) return error.Malformed;
    }
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}

const Scheme = enum {
    http,
    https,

    fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }

    fn text(self: Scheme) []const u8 {
        return @tagName(self);
    }
};

fn normalizeEndpoint(value: []const u8, out: []u8) NormalizeError![]const u8 {
    if (value.len == 0) return error.Empty;
    if (value.len > max_endpoint_bytes) return error.TooLong;

    const separator = std.mem.indexOf(u8, value, "://") orelse return error.Malformed;
    const scheme = blk: {
        if (asciiEqlIgnoreCase(value[0..separator], "http")) break :blk Scheme.http;
        if (asciiEqlIgnoreCase(value[0..separator], "https")) break :blk Scheme.https;
        return error.Malformed;
    };

    var rest = value[separator + 3 ..];
    // Everything from the first path, query, or fragment byte is not part of
    // the endpoint. The guard authorizes a destination, not a request.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |cut| rest = rest[0..cut];
    if (rest.len == 0) return error.Malformed;
    // Userinfo is refused rather than dropped: `evil.example@allowed.example`
    // reads as the allowed host to a careless parser and connects to neither.
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return error.Malformed;

    var host = rest;
    var port: ?u16 = null;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.Malformed;
        host = rest[0 .. close + 1];
        const tail = rest[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return error.Malformed;
            port = try parsePort(tail[1..]);
        }
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        host = rest[0..colon];
        port = try parsePort(rest[colon + 1 ..]);
    }

    if (host.len == 0) return error.Malformed;
    // One trailing dot is the same name in DNS; more than one is not a name.
    if (host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0 or host[host.len - 1] == '.') return error.Malformed;
    for (host) |byte| {
        if (byte <= 0x20 or byte >= 0x7F) return error.Malformed;
    }

    const effective_port = port orelse scheme.defaultPort();
    var buffer: [max_endpoint_bytes]u8 = undefined;
    const written = std.fmt.bufPrint(&buffer, "{s}://{s}:{d}", .{
        scheme.text(),
        host,
        effective_port,
    }) catch return error.TooLong;
    if (written.len > out.len) return error.TooLong;
    for (written, 0..) |byte, index| out[index] = std.ascii.toLower(byte);
    return out[0..written.len];
}

fn parsePort(text: []const u8) NormalizeError!u16 {
    if (text.len == 0 or text.len > 5) return error.Malformed;
    var port: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.Malformed;
        port = port * 10 + (byte - '0');
        if (port > std.math.maxInt(u16)) return error.Malformed;
    }
    if (port == 0) return error.Malformed;
    return @intCast(port);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// The consumer's catalog
// ---------------------------------------------------------------------------

/// Which export argument the consumer is willing to treat as guardable.
///
/// This is the consumer's list, not the producer's. A certificate that claims a
/// guard for something absent here is refused, so widening the guardable
/// surface is an edit to this table and to the sink that backs it.
pub const CatalogEntry = struct {
    module: []const u8,
    export_name: []const u8,
    arg_index: u8,
    kind: GuardKind,
    /// Bumped when the sink's guard changes shape. A certificate carrying a
    /// stale identity is refused rather than assumed compatible.
    impl_id: u32,
};

/// Guard implementation identities. One per sink, bumped when its guard moves
/// or changes what it compares.
pub const guard_impl = struct {
    pub const env_read_v1: u32 = 1;
    pub const egress_connect_v1: u32 = 1;
    pub const cache_operation_v1: u32 = 1;
    pub const sql_execute_v1: u32 = 1;
};

pub const catalog = [_]CatalogEntry{
    .{ .module = "zttp:env", .export_name = "env", .arg_index = 0, .kind = .env_key, .impl_id = guard_impl.env_read_v1 },

    .{ .module = "zttp:fetch", .export_name = "fetch", .arg_index = 0, .kind = .egress_endpoint, .impl_id = guard_impl.egress_connect_v1 },
    .{ .module = "zttp:fetch", .export_name = "fetchWithRetry", .arg_index = 0, .kind = .egress_endpoint, .impl_id = guard_impl.egress_connect_v1 },

    .{ .module = "zttp:cache", .export_name = "cacheGet", .arg_index = 0, .kind = .cache_namespace, .impl_id = guard_impl.cache_operation_v1 },
    .{ .module = "zttp:cache", .export_name = "cacheSet", .arg_index = 0, .kind = .cache_namespace, .impl_id = guard_impl.cache_operation_v1 },
    .{ .module = "zttp:cache", .export_name = "cacheDelete", .arg_index = 0, .kind = .cache_namespace, .impl_id = guard_impl.cache_operation_v1 },
    .{ .module = "zttp:cache", .export_name = "cacheIncr", .arg_index = 0, .kind = .cache_namespace, .impl_id = guard_impl.cache_operation_v1 },
    .{ .module = "zttp:cache", .export_name = "cacheStats", .arg_index = 0, .kind = .cache_namespace, .impl_id = guard_impl.cache_operation_v1 },

    // `sql` itself registers a statement. Registering a computed statement is a
    // different question from executing a named one, and it stays rejected.
    .{ .module = "zttp:sql", .export_name = "sqlOne", .arg_index = 0, .kind = .sql_read, .impl_id = guard_impl.sql_execute_v1 },
    .{ .module = "zttp:sql", .export_name = "sqlMany", .arg_index = 0, .kind = .sql_read, .impl_id = guard_impl.sql_execute_v1 },
    .{ .module = "zttp:sql", .export_name = "sqlExec", .arg_index = 0, .kind = .sql_write, .impl_id = guard_impl.sql_execute_v1 },
};

/// The catalog entry for one export argument, if the consumer guards it.
pub fn lookup(module: []const u8, export_name: []const u8, arg_index: u8) ?CatalogEntry {
    const index = lookupIndex(module, export_name, arg_index) orelse return null;
    return catalog[index];
}

/// The catalog row's index. This is what the proof IR carries, so the consumer
/// resolves the row from its own table rather than from anything the producer
/// wrote down about it.
pub fn lookupIndex(module: []const u8, export_name: []const u8, arg_index: u8) ?u32 {
    for (catalog, 0..) |entry, index| {
        if (entry.arg_index != arg_index) continue;
        if (!std.mem.eql(u8, entry.module, module)) continue;
        if (!std.mem.eql(u8, entry.export_name, export_name)) continue;
        return @intCast(index);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every alphabet member round trips and names itself" {
    inline for (.{ GuardKind, Normalization, SinkId, PolicySection, AddressScope }) |T| {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            const member: T = @enumFromInt(field.value);
            try testing.expectEqual(@as(?T, member), T.fromWire(field.value));
            try testing.expect(member.name().len > 0);
        }
        try testing.expectEqual(@as(?T, null), T.fromWire(0));
        try testing.expectEqual(@as(?T, null), T.fromWire(200));
    }
}

test "a guard kind decides its own rule, section, and sink" {
    // The producer restates these; it never chooses them. This is where the
    // consumer's answer lives.
    try testing.expectEqual(Normalization.endpoint_v1, GuardKind.egress_endpoint.normalization());
    try testing.expectEqual(Normalization.identifier_exact_v1, GuardKind.env_key.normalization());
    try testing.expectEqual(PolicySection.sql, GuardKind.sql_write.section());
    try testing.expectEqual(SinkId.sql_execute, GuardKind.sql_read.sink());
    inline for (@typeInfo(GuardKind).@"enum".fields) |field| {
        const kind: GuardKind = @enumFromInt(field.value);
        _ = kind.normalization();
        _ = kind.section();
        _ = kind.sink();
    }
}

test "an unknown scope bit is refused rather than read as permissive" {
    const all = ScopeSet{ .bits = 0b0011_1111 };
    try testing.expectEqual(@as(?ScopeSet, all), ScopeSet.fromWire(0b0011_1111));
    try testing.expectEqual(@as(?ScopeSet, null), ScopeSet.fromWire(0b1000_0000));
    try testing.expect(all.contains(.loopback));
    try testing.expect(!(ScopeSet{}).contains(.public));
    try testing.expect((ScopeSet{}).isEmpty());
    try testing.expect(!(ScopeSet{}).with(.public).isEmpty());
}

test "identifier normalization is exact" {
    var out: [max_identifier_bytes]u8 = undefined;
    try testing.expectEqualStrings("API_KEY", try normalize(.identifier_exact_v1, "API_KEY", &out));
    // Case is significant: two identifiers that differ in a byte are two names.
    try testing.expectEqualStrings("api_key", try normalize(.identifier_exact_v1, "api_key", &out));
    try testing.expectError(error.Empty, normalize(.identifier_exact_v1, "", &out));
    try testing.expectError(error.Malformed, normalize(.identifier_exact_v1, "A\tB", &out));
    try testing.expectError(error.Malformed, normalize(.identifier_exact_v1, "A\x00B", &out));

    const long = [_]u8{'a'} ** (max_identifier_bytes);
    _ = try normalize(.identifier_exact_v1, &long, &out);
    const too_long = [_]u8{'a'} ** (max_identifier_bytes + 1);
    var big: [max_endpoint_bytes]u8 = undefined;
    try testing.expectError(error.TooLong, normalize(.identifier_exact_v1, &too_long, &big));
}

test "endpoint normalization folds case, fills the port, and drops the path" {
    var out: [max_endpoint_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "https://api.example.com:443",
        try normalize(.endpoint_v1, "HTTPS://API.Example.COM/v1/things?x=1#f", &out),
    );
    try testing.expectEqualStrings(
        "http://api.example.com:80",
        try normalize(.endpoint_v1, "http://api.example.com", &out),
    );
    // An explicit default port and an implicit one are the same endpoint.
    try testing.expectEqualStrings(
        "https://api.example.com:443",
        try normalize(.endpoint_v1, "https://api.example.com:443/", &out),
    );
    // A non-default port is a different endpoint.
    try testing.expectEqualStrings(
        "https://api.example.com:8443",
        try normalize(.endpoint_v1, "https://api.example.com:8443", &out),
    );
    // One trailing dot is the same DNS name.
    try testing.expectEqualStrings(
        "https://api.example.com:443",
        try normalize(.endpoint_v1, "https://api.example.com./v1", &out),
    );
    try testing.expectEqualStrings(
        "http://[::1]:8080",
        try normalize(.endpoint_v1, "http://[::1]:8080/x", &out),
    );
}

test "endpoint normalization refuses what it cannot canonicalize" {
    var out: [max_endpoint_bytes]u8 = undefined;
    try testing.expectError(error.Empty, normalize(.endpoint_v1, "", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "api.example.com", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "ftp://api.example.com", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "file:///etc/passwd", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "https://", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "https://host:0", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "https://host:70000", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "https://host:x", &out));
    try testing.expectError(error.Malformed, normalize(.endpoint_v1, "https://host..", &out));
    // Userinfo is the substitution that reads as the allowed host and is not.
    try testing.expectError(
        error.Malformed,
        normalize(.endpoint_v1, "https://allowed.example@evil.example/", &out),
    );
}

test "normalization is idempotent" {
    var first: [max_endpoint_bytes]u8 = undefined;
    var second: [max_endpoint_bytes]u8 = undefined;
    const inputs = [_][]const u8{
        "HTTPS://API.Example.COM/v1",
        "http://a.b:80",
        "https://[2001:db8::1]:8443/x",
    };
    for (inputs) |input| {
        const once = try normalize(.endpoint_v1, input, &first);
        const twice = try normalize(.endpoint_v1, once, &second);
        try testing.expectEqualStrings(once, twice);
    }

    var id_first: [max_identifier_bytes]u8 = undefined;
    var id_second: [max_identifier_bytes]u8 = undefined;
    const once = try normalize(.identifier_exact_v1, "ns.one", &id_first);
    const twice = try normalize(.identifier_exact_v1, once, &id_second);
    try testing.expectEqualStrings(once, twice);
}

test "distinct destinations do not normalize to one string" {
    var a: [max_endpoint_bytes]u8 = undefined;
    var b: [max_endpoint_bytes]u8 = undefined;
    const pairs = [_][2][]const u8{
        .{ "https://api.example.com", "http://api.example.com" },
        .{ "https://api.example.com", "https://api.example.com:8443" },
        .{ "https://api.example.com", "https://api.example.com.evil.test" },
        .{ "https://a.example.com", "https://b.example.com" },
    };
    for (pairs) |pair| {
        const left = try normalize(.endpoint_v1, pair[0], &a);
        const right = try normalize(.endpoint_v1, pair[1], &b);
        try testing.expect(!std.mem.eql(u8, left, right));
    }
}

test "the catalog names only exports a sink actually observes" {
    // Present.
    const env_entry = lookup("zttp:env", "env", 0).?;
    try testing.expectEqual(GuardKind.env_key, env_entry.kind);
    try testing.expectEqual(SinkId.env_read, env_entry.kind.sink());
    try testing.expectEqual(GuardKind.sql_write, lookup("zttp:sql", "sqlExec", 0).?.kind);
    try testing.expectEqual(GuardKind.sql_read, lookup("zttp:sql", "sqlMany", 0).?.kind);
    try testing.expectEqual(GuardKind.egress_endpoint, lookup("zttp:fetch", "fetchWithRetry", 0).?.kind);

    // Absent on purpose. `sql` registers a statement and `serviceCall` reaches a
    // registry the executable graph does not bind; neither has a sink that
    // observes the final effect, so neither is guardable.
    try testing.expectEqual(@as(?CatalogEntry, null), lookup("zttp:sql", "sql", 0));
    try testing.expectEqual(@as(?CatalogEntry, null), lookup("zttp:service", "serviceCall", 0));
    // A moved argument position is a different operation.
    try testing.expectEqual(@as(?CatalogEntry, null), lookup("zttp:env", "env", 1));
    // An export nobody wrote down cannot fall into a generic bucket.
    try testing.expectEqual(@as(?CatalogEntry, null), lookup("zttp:cache", "cacheFlush", 0));
    try testing.expectEqual(@as(?CatalogEntry, null), lookup("zttp:unknown", "anything", 0));
}

test "a row's index and its entry name the same row" {
    const index = lookupIndex("zttp:sql", "sqlExec", 0).?;
    try testing.expectEqual(GuardKind.sql_write, catalog[index].kind);
    try testing.expectEqual(catalog[index].impl_id, lookup("zttp:sql", "sqlExec", 0).?.impl_id);
    try testing.expectEqual(@as(?u32, null), lookupIndex("zttp:sql", "sql", 0));
}

test "the catalog is non-empty and covers every guard kind" {
    // A catalog that lost its rows would make every lookup null and every
    // reconstruction empty, and an empty required set is satisfied by an empty
    // supplied set.
    try testing.expect(catalog.len >= 8);

    var seen = std.EnumSet(GuardKind).initEmpty();
    for (catalog) |entry| seen.insert(entry.kind);
    inline for (@typeInfo(GuardKind).@"enum".fields) |field| {
        const kind: GuardKind = @enumFromInt(field.value);
        try testing.expect(seen.contains(kind));
    }

    // No two rows describe the same operation.
    for (catalog, 0..) |a, i| {
        for (catalog[i + 1 ..]) |b| {
            const same = std.mem.eql(u8, a.module, b.module) and
                std.mem.eql(u8, a.export_name, b.export_name) and
                a.arg_index == b.arg_index;
            try testing.expect(!same);
        }
    }
}

test "the lookup bound is a compile-time property, not a hope" {
    // Nine, not log2(256). `capability_policy` counts the probes a full
    // category actually costs and compares them against this number.
    try testing.expectEqual(@as(usize, 9), max_lookup_comparisons);
    try testing.expectEqual(@as(u16, 256), max_policy_entries);
}
