//! The canonical egress endpoint: `scheme://host:port`, and the resolved
//! address scopes a connection may land in.
//!
//! A host name is not a destination. `https://api.example.com` and
//! `http://api.example.com:8080` share a host and reach two different servers,
//! so a policy that names hosts cannot say which one it meant, and a check that
//! compares hosts cannot tell them apart. Every layer that decides where a
//! handler may connect - the policy file, the contract, the serialized runtime
//! policy, and the socket - names an endpoint instead, produced by this rule.
//!
//! This is deliberately a second implementation of the rule the acceptance
//! kernel carries in `packages/proof-checker/src/residual.zig`. The kernel is a
//! leaf: it imports `std` and its own siblings and nothing else, so it cannot
//! call into this package, and this package sits below it. A test in
//! `packages/runtime`, which imports both, runs the two over one corpus and
//! fails when they disagree. Two implementations pinned to each other is the
//! arrangement the layering allows; one implementation quietly diverging from
//! the other is what it prevents.

const std = @import("std");

/// A normalized `scheme://host:port`.
pub const max_endpoint_bytes: usize = 512;

pub const NormalizeError = error{
    Empty,
    TooLong,
    /// Not a form this rule can canonicalize: a missing scheme, a scheme
    /// outside the set, userinfo, an empty host, a port outside range.
    Malformed,
};

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

/// Canonicalize a URL or endpoint into `scheme://host:port`, lowercased.
///
/// `out` receives the result and the returned slice points into it. The rule:
/// the scheme must be `http` or `https`; a missing port becomes the scheme's
/// default; path, query, and fragment are dropped, because the guard authorizes
/// a destination and not a request; one trailing dot on the host is the same
/// name in DNS and is removed; userinfo is refused outright, because
/// `evil.example@allowed.example` reads as the allowed host to a careless
/// parser and connects to neither.
pub fn normalize(value: []const u8, out: []u8) NormalizeError![]const u8 {
    if (value.len == 0) return error.Empty;
    if (value.len > max_endpoint_bytes) return error.TooLong;

    const separator = std.mem.indexOf(u8, value, "://") orelse return error.Malformed;
    const scheme = blk: {
        if (asciiEqlIgnoreCase(value[0..separator], "http")) break :blk Scheme.http;
        if (asciiEqlIgnoreCase(value[0..separator], "https")) break :blk Scheme.https;
        return error.Malformed;
    };

    var rest = value[separator + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |cut| rest = rest[0..cut];
    if (rest.len == 0) return error.Malformed;
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

/// Where a resolved address sits. An endpoint says which name and port a
/// handler may reach; this says which addresses that name is allowed to
/// resolve to, so a name that resolves to a loopback or private address is a
/// different decision from the same name resolving to a public one.
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

    /// The name this scope carries in a policy file.
    pub fn fromText(text: []const u8) ?AddressScope {
        inline for (@typeInfo(AddressScope).@"enum".fields) |field| {
            const scope: AddressScope = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, scope.name())) return scope;
        }
        return null;
    }

    pub fn name(self: AddressScope) []const u8 {
        return @tagName(self);
    }

    pub fn bit(self: AddressScope) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(self) - 1);
    }
};

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

/// A resolved address, as bytes. Named this way rather than as
/// `std.net.Address` because this tier is built for every target the engine is,
/// including ones with no networking in their standard library; the caller that
/// holds a socket address converts.
pub const ResolvedAddress = union(enum) {
    v4: [4]u8,
    v6: [16]u8,
};

/// Classify a resolved address. Called after resolution and before the socket,
/// so a name that answers with a private or loopback address is refused there
/// rather than at the name.
pub fn scopeOf(address: ResolvedAddress) AddressScope {
    return switch (address) {
        .v4 => |octets| scopeOfIpv4(octets),
        .v6 => |bytes| scopeOfIpv6(bytes),
    };
}

fn scopeOfIpv4(octets: [4]u8) AddressScope {
    if (octets[0] == 127) return .loopback;
    if (octets[0] == 0) return .unspecified;
    if (octets[0] == 10) return .private;
    if (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) return .private;
    if (octets[0] == 192 and octets[1] == 168) return .private;
    // Carrier-grade NAT and the benchmarking range are not the public internet
    // either, and a handler that reaches them reaches infrastructure.
    if (octets[0] == 100 and octets[1] >= 64 and octets[1] <= 127) return .private;
    if (octets[0] == 198 and (octets[1] == 18 or octets[1] == 19)) return .private;
    if (octets[0] == 169 and octets[1] == 254) return .link_local;
    if (octets[0] >= 224 and octets[0] <= 239) return .multicast;
    return .public;
}

fn scopeOfIpv6(bytes: [16]u8) AddressScope {
    const unspecified = [_]u8{0} ** 16;
    if (std.mem.eql(u8, &bytes, &unspecified)) return .unspecified;
    var loopback = [_]u8{0} ** 16;
    loopback[15] = 1;
    if (std.mem.eql(u8, &bytes, &loopback)) return .loopback;
    // An IPv4-mapped address is the IPv4 address it carries, not a public IPv6
    // one: ::ffff:127.0.0.1 reaches loopback.
    const v4_mapped_prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xFF, 0xFF };
    if (std.mem.eql(u8, bytes[0..12], &v4_mapped_prefix)) {
        return scopeOfIpv4(.{ bytes[12], bytes[13], bytes[14], bytes[15] });
    }
    if (bytes[0] == 0xFF) return .multicast;
    if (bytes[0] == 0xFE and (bytes[1] & 0xC0) == 0x80) return .link_local;
    // Unique local addresses, fc00::/7.
    if ((bytes[0] & 0xFE) == 0xFC) return .private;
    return .public;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn normalized(value: []const u8, out: []u8) ![]const u8 {
    return normalize(value, out);
}

test "an endpoint is scheme, host, and effective port" {
    var buf: [max_endpoint_bytes]u8 = undefined;

    try testing.expectEqualStrings("https://api.example.com:443", try normalized("https://api.example.com", &buf));
    try testing.expectEqualStrings("http://api.example.com:80", try normalized("http://api.example.com", &buf));
    try testing.expectEqualStrings("http://api.example.com:8080", try normalized("http://api.example.com:8080", &buf));

    // The path is not part of the destination.
    try testing.expectEqualStrings(
        "https://api.example.com:443",
        try normalized("https://api.example.com/v1/orders?page=2#top", &buf),
    );

    // Case and one trailing dot name the same host.
    try testing.expectEqualStrings("https://api.example.com:443", try normalized("HTTPS://API.Example.COM.", &buf));

    // The explicit default port and the implicit one are the same endpoint.
    try testing.expectEqualStrings("https://api.example.com:443", try normalized("https://api.example.com:443", &buf));
}

test "the same host under a different scheme or port is a different endpoint" {
    var a: [max_endpoint_bytes]u8 = undefined;
    var b: [max_endpoint_bytes]u8 = undefined;

    const https = try normalized("https://api.example.com", &a);
    const http = try normalized("http://api.example.com", &b);
    try testing.expect(!std.mem.eql(u8, https, http));

    const default_port = try normalized("https://api.example.com", &a);
    const other_port = try normalized("https://api.example.com:8443", &b);
    try testing.expect(!std.mem.eql(u8, default_port, other_port));
}

test "a form the rule cannot canonicalize is refused, not guessed at" {
    var buf: [max_endpoint_bytes]u8 = undefined;

    try testing.expectError(error.Empty, normalize("", &buf));
    // No scheme: a bare host names no destination.
    try testing.expectError(error.Malformed, normalize("api.example.com", &buf));
    try testing.expectError(error.Malformed, normalize("ftp://api.example.com", &buf));
    try testing.expectError(error.Malformed, normalize("file:///etc/passwd", &buf));
    // Userinfo reads as the allowed host to a careless parser.
    try testing.expectError(error.Malformed, normalize("https://allowed.example@evil.example", &buf));
    try testing.expectError(error.Malformed, normalize("https://", &buf));
    try testing.expectError(error.Malformed, normalize("https:///path", &buf));
    try testing.expectError(error.Malformed, normalize("https://api.example.com:0", &buf));
    try testing.expectError(error.Malformed, normalize("https://api.example.com:70000", &buf));
    try testing.expectError(error.Malformed, normalize("https://api.example.com:80x", &buf));
    try testing.expectError(error.Malformed, normalize("https://api.example.com..", &buf));
    try testing.expectError(error.Malformed, normalize("https://api example.com", &buf));

    var long: [max_endpoint_bytes + 1]u8 = @splat('a');
    try testing.expectError(error.TooLong, normalize(&long, &buf));
}

test "a bracketed IPv6 host keeps its brackets and takes its port" {
    var buf: [max_endpoint_bytes]u8 = undefined;
    try testing.expectEqualStrings("https://[::1]:443", try normalized("https://[::1]", &buf));
    try testing.expectEqualStrings("http://[::1]:8080", try normalized("http://[::1]:8080", &buf));
    try testing.expectError(error.Malformed, normalize("https://[::1", &buf));
    try testing.expectError(error.Malformed, normalize("https://[::1]x", &buf));
}

test "normalization is idempotent" {
    var first: [max_endpoint_bytes]u8 = undefined;
    var second: [max_endpoint_bytes]u8 = undefined;
    for ([_][]const u8{
        "https://API.example.com./v1",
        "http://localhost:3000",
        "https://[::1]:8443/x?y=1",
    }) |value| {
        const once = try normalize(value, &first);
        const twice = try normalize(once, &second);
        try testing.expectEqualStrings(once, twice);
    }
}

fn v6(text: []const u8) [16]u8 {
    var bytes: [16]u8 = @splat(0);
    var group: usize = 0;
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |part| {
        if (part.len == 0) {
            // One "::" run, filled by the zeroes already there.
            group = 8 - countTrailingGroups(text);
            index = group * 2;
            continue;
        }
        const value = std.fmt.parseInt(u16, part, 16) catch unreachable;
        std.mem.writeInt(u16, bytes[index..][0..2], value, .big);
        group += 1;
        index += 2;
    }
    return bytes;
}

fn countTrailingGroups(text: []const u8) usize {
    const marker = std.mem.indexOf(u8, text, "::") orelse return 0;
    const tail = text[marker + 2 ..];
    if (tail.len == 0) return 0;
    var count: usize = 1;
    for (tail) |byte| {
        if (byte == ':') count += 1;
    }
    return count;
}

test "an address scope names where a resolved address sits" {
    try testing.expectEqual(AddressScope.loopback, scopeOf(.{ .v4 = .{ 127, 0, 0, 1 } }));
    try testing.expectEqual(AddressScope.unspecified, scopeOf(.{ .v4 = .{ 0, 0, 0, 0 } }));
    try testing.expectEqual(AddressScope.private, scopeOf(.{ .v4 = .{ 10, 1, 2, 3 } }));
    try testing.expectEqual(AddressScope.private, scopeOf(.{ .v4 = .{ 172, 16, 0, 1 } }));
    try testing.expectEqual(AddressScope.public, scopeOf(.{ .v4 = .{ 172, 32, 0, 1 } }));
    try testing.expectEqual(AddressScope.private, scopeOf(.{ .v4 = .{ 192, 168, 1, 1 } }));
    // The cloud metadata endpoint, which is the address this check exists for.
    try testing.expectEqual(AddressScope.link_local, scopeOf(.{ .v4 = .{ 169, 254, 169, 254 } }));
    try testing.expectEqual(AddressScope.private, scopeOf(.{ .v4 = .{ 100, 64, 0, 1 } }));
    try testing.expectEqual(AddressScope.multicast, scopeOf(.{ .v4 = .{ 224, 0, 0, 1 } }));
    try testing.expectEqual(AddressScope.public, scopeOf(.{ .v4 = .{ 93, 184, 216, 34 } }));

    try testing.expectEqual(AddressScope.loopback, scopeOf(.{ .v6 = v6("::1") }));
    try testing.expectEqual(AddressScope.unspecified, scopeOf(.{ .v6 = @splat(0) }));
    // An IPv4-mapped address is the IPv4 address it carries.
    var mapped: [16]u8 = @splat(0);
    mapped[10] = 0xFF;
    mapped[11] = 0xFF;
    mapped[12] = 127;
    mapped[15] = 1;
    try testing.expectEqual(AddressScope.loopback, scopeOf(.{ .v6 = mapped }));
    try testing.expectEqual(AddressScope.private, scopeOf(.{ .v6 = v6("fd00::1") }));
    try testing.expectEqual(AddressScope.link_local, scopeOf(.{ .v6 = v6("fe80::1") }));
    try testing.expectEqual(AddressScope.multicast, scopeOf(.{ .v6 = v6("ff02::1") }));
    try testing.expectEqual(AddressScope.public, scopeOf(.{ .v6 = v6("2606:2800:220:1::1") }));
}

test "an empty scope set permits nothing and an unknown bit is refused" {
    const empty = ScopeSet{};
    try testing.expect(empty.isEmpty());
    inline for (@typeInfo(AddressScope).@"enum".fields) |field| {
        const scope: AddressScope = @enumFromInt(field.value);
        try testing.expect(!empty.contains(scope));
    }

    const public_only = (ScopeSet{}).with(.public);
    try testing.expect(public_only.contains(.public));
    try testing.expect(!public_only.contains(.loopback));

    try testing.expect(ScopeSet.fromWire(0) != null);
    try testing.expect(ScopeSet.fromWire(0b1000_0000) == null);
    try testing.expectEqual(AddressScope.public, AddressScope.fromText("public").?);
    try testing.expect(AddressScope.fromText("everywhere") == null);
}
