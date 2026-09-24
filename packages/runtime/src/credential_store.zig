//! Credential values for outbound requests (M4 T6).
//!
//! The server reads the value of every credential reference once at startup,
//! from the environment variable the reference names. The handler's env allow
//! list does not apply: no JS value ever holds a credential, and `zttp:env`
//! cannot read one unless the handler's own policy names the same variable. A
//! reference whose variable is unset or empty stops the server from starting
//! (AE17, "missing secret binding"), in every mode.
//!
//! The store keeps its own copy of each reference beside the value, so the
//! runtime authorizes a request against the reference the value was loaded
//! for, whatever the source of the references was (zttp.json or an accepted
//! contract).
//!
//! The store zeroes every value on release and never logs or formats one. The
//! runtime reads a value only through `authorize`, in the one function that
//! adds it to an authorized request. See
//! docs/plans/2026-09-24-m4-t6-credential-injection-design.md, sections 3, 5,
//! and 7.

const std = @import("std");
const zq = @import("zts");

pub const CredentialRef = zq.handler_contract.CredentialRef;
pub const credential_ref = zq.handler_contract.credential_ref;

pub const Entry = struct {
    /// Owned copy of the reference.
    ref: CredentialRef,
    value: []u8,
};

/// Every loaded value, in the references' order. Owns each reference and value.
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn deinit(self: *Store) void {
        releaseEntries(self.allocator, self.entries);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// The entry of the credential named `name`, or null. Borrowed for the
    /// store's lifetime.
    pub fn find(self: *const Store, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.ref.name, name)) return entry;
        }
        return null;
    }

    /// The value of the credential named `name`, or null. Borrowed for the
    /// store's lifetime.
    pub fn value(self: *const Store, name: []const u8) ?[]const u8 {
        const entry = self.find(name) orelse return null;
        return entry.value;
    }
};

pub const LoadResult = union(enum) {
    ok: Store,
    /// The first reference whose variable is unset or empty. Borrows from the
    /// references passed to `load`.
    missing: *const CredentialRef,
};

/// Where `load` reads a variable. The server passes `processEnv`; tests pass
/// an in-memory table.
pub const EnvSource = struct {
    context: ?*const anyopaque = null,
    get: *const fn (context: ?*const anyopaque, name_z: [:0]const u8) ?[]const u8,
};

pub fn processEnv() EnvSource {
    return .{ .get = getProcessEnv };
}

fn getProcessEnv(_: ?*const anyopaque, name_z: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name_z) orelse return null;
    return std.mem.span(raw);
}

/// Read the value of every reference. Refuses on the first reference whose
/// variable is unset or empty and loads nothing.
pub fn load(allocator: std.mem.Allocator, refs: []const CredentialRef, env: EnvSource) std.mem.Allocator.Error!LoadResult {
    const entries = try allocator.alloc(Entry, refs.len);
    var filled: usize = 0;
    errdefer {
        releaseEntries(allocator, entries[0..filled]);
        allocator.free(entries);
    }

    for (refs) |*ref| {
        const name_z = try allocator.dupeZ(u8, ref.env);
        defer allocator.free(name_z);
        const raw = env.get(env.context, name_z) orelse "";
        if (raw.len == 0) {
            releaseEntries(allocator, entries[0..filled]);
            allocator.free(entries);
            return .{ .missing = ref };
        }
        var owned_ref = try ref.dupe(allocator);
        errdefer owned_ref.deinit(allocator);
        entries[filled] = .{ .ref = owned_ref, .value = try allocator.dupe(u8, raw) };
        filled += 1;
    }
    return .{ .ok = .{ .allocator = allocator, .entries = entries } };
}

fn releaseEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| {
        std.crypto.secureZero(u8, entry.value);
        allocator.free(entry.value);
        entry.ref.deinit(allocator);
    }
}

// ---------------------------------------------------------------------------
// Authorization of the exact request (design note, section 5)
// ---------------------------------------------------------------------------

/// Why the runtime refused to add a credential. Closed: the 599 detail of a
/// `CredentialRefused` fetch error is exactly one of these names, and never
/// holds the value.
pub const Refusal = enum {
    /// No tool request is active, or the active tool's grant does not hold
    /// the name.
    not_granted,
    /// The store holds no credential with the name.
    not_configured,
    /// The final URL's canonical endpoint is not the reference's endpoint.
    endpoint_mismatch,
    /// The method is not in the reference's `methods`.
    method_not_allowed,
    /// The final path matches none of the reference's `paths` at a segment
    /// boundary, or holds a `.` or `..` segment, an empty interior segment, or
    /// an encoded `/` or `\`.
    path_not_allowed,
    /// The handler set the reference's header itself.
    header_collision,
    /// The scheme is `http` and the host is not a loopback IP literal.
    plaintext,
    /// The credential was passed to a sender that does not inject one:
    /// `fetchWithRetry`, a durable fetch, the `zttp:io` parallel path, or
    /// `httpRequest`.
    path_unsupported,
};

/// The request the runtime is about to send, after the query was appended.
pub const Outbound = struct {
    /// The final URL.
    url: []const u8,
    method: std.http.Method,
    /// The handler's own headers.
    headers: []const std.http.Header,
};

pub const Decision = union(enum) {
    granted: *const Entry,
    refused: Refusal,
};

/// Check the exact request against the reference, in the order section 5 of
/// the design note fixes. `granted` is whether the active tool's grant holds
/// `name`; the caller answers it, because the grant belongs to the request and
/// not to the store. Only a `.granted` decision gives access to the value.
pub fn authorize(store: ?*const Store, granted: bool, name: []const u8, request: Outbound) Decision {
    if (!granted) return .{ .refused = .not_granted };
    const entry = (store orelse return .{ .refused = .not_configured }).find(name) orelse
        return .{ .refused = .not_configured };
    const ref = &entry.ref;

    var endpoint_buf: [zq.endpoint.max_endpoint_bytes]u8 = undefined;
    const canonical = canonicalEndpoint(request.url, &endpoint_buf) orelse return .{ .refused = .endpoint_mismatch };
    if (!std.mem.eql(u8, canonical, ref.endpoint)) return .{ .refused = .endpoint_mismatch };

    const method = std.meta.stringToEnum(credential_ref.Method, @tagName(request.method)) orelse
        return .{ .refused = .method_not_allowed };
    if (!ref.methods.contains(method)) return .{ .refused = .method_not_allowed };

    if (!pathAllowed(sentPath(request.url), ref.paths)) return .{ .refused = .path_not_allowed };

    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, ref.header)) return .{ .refused = .header_collision };
    }

    if (!std.mem.startsWith(u8, canonical, "https://") and !credential_ref.loopbackLiteral(hostOf(canonical))) {
        return .{ .refused = .plaintext };
    }
    return .{ .granted = entry };
}

/// The header value for a granted entry: the scheme, one space, and the value,
/// or the value alone. The caller owns the result and must zero it before it
/// frees it (`releaseHeaderValue`).
pub fn headerValue(allocator: std.mem.Allocator, entry: *const Entry) std.mem.Allocator.Error![]u8 {
    const scheme = entry.ref.scheme orelse return allocator.dupe(u8, entry.value);
    const out = try allocator.alloc(u8, scheme.len + 1 + entry.value.len);
    @memcpy(out[0..scheme.len], scheme);
    out[scheme.len] = ' ';
    @memcpy(out[scheme.len + 1 ..], entry.value);
    return out;
}

pub fn releaseHeaderValue(allocator: std.mem.Allocator, header_value: []u8) void {
    std.crypto.secureZero(u8, header_value);
    allocator.free(header_value);
}

/// The canonical `scheme://host:port` of a full URL. Only the origin is passed
/// to the normalizer, so a long path or query does not exceed its bound.
fn canonicalEndpoint(url: []const u8, out: []u8) ?[]const u8 {
    const separator = std.mem.indexOf(u8, url, "://") orelse return null;
    const origin_end = if (std.mem.indexOfAny(u8, url[separator + 3 ..], "/?#")) |cut| separator + 3 + cut else url.len;
    return zq.endpoint.normalize(url[0..origin_end], out) catch null;
}

/// The host of a canonical `scheme://host:port`.
fn hostOf(canonical: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, canonical, "://") orelse return "") + 3;
    const colon = std.mem.lastIndexOfScalar(u8, canonical, ':') orelse return "";
    if (colon <= start) return "";
    return canonical[start..colon];
}

/// The path of a URL in the percent-encoded form the client sends: from the
/// end of the authority to the query or fragment. An empty path is sent as
/// `/`.
fn sentPath(url: []const u8) []const u8 {
    const separator = std.mem.indexOf(u8, url, "://") orelse return "";
    const after = url[separator + 3 ..];
    const path_start = std.mem.indexOfAny(u8, after, "/?#") orelse return "/";
    const rest = after[path_start..];
    if (rest[0] != '/') return "/";
    const path_end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    return rest[0..path_end];
}

/// True when `path` is safe to compare and one of `prefixes` matches it at a
/// segment boundary: `/v1/forecast` matches `/v1/forecast` and
/// `/v1/forecast/today`, and not `/v1/forecastx`.
fn pathAllowed(path: []const u8, prefixes: []const []const u8) bool {
    if (!pathSafe(path)) return false;
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        if (path.len == prefix.len) return true;
        if (std.mem.eql(u8, prefix, "/") or path[prefix.len] == '/') return true;
    }
    return false;
}

/// Refuse a path an upstream could resolve to a place its bytes do not name:
/// a `.` or `..` segment (also percent-encoded), an encoded `/` or `\`, a raw
/// `\`, and an empty segment anywhere but the end.
fn pathSafe(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var i: usize = 0;
    while (i + 2 < path.len) : (i += 1) {
        if (path[i] != '%') continue;
        const a = std.ascii.toLower(path[i + 1]);
        const b = std.ascii.toLower(path[i + 2]);
        if ((a == '2' and b == 'f') or (a == '5' and b == 'c')) return false;
    }
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) {
            if (segments.peek() == null) continue;
            return false;
        }
        if (dotSegment(segment)) return false;
    }
    return true;
}

/// `.` or `..`, with each dot written plain or as `%2e`.
fn dotSegment(segment: []const u8) bool {
    var dots: usize = 0;
    var i: usize = 0;
    while (i < segment.len) {
        if (segment[i] == '.') {
            i += 1;
        } else if (i + 2 < segment.len and segment[i] == '%' and segment[i + 1] == '2' and std.ascii.toLower(segment[i + 2]) == 'e') {
            i += 3;
        } else return false;
        dots += 1;
    }
    return dots == 1 or dots == 2;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestEnv = struct {
    pairs: []const [2][]const u8,

    fn source(self: *const TestEnv) EnvSource {
        return .{ .context = self, .get = get };
    }

    fn get(context: ?*const anyopaque, name_z: [:0]const u8) ?[]const u8 {
        const self: *const TestEnv = @ptrCast(@alignCast(context.?));
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair[0], name_z)) return pair[1];
        }
        return null;
    }
};

fn testRefs(allocator: std.mem.Allocator) ![]zq.handler_contract.CredentialRef {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"weather": {"env": "WEATHER_KEY", "endpoint": "https://api.weather.example", "header": "authorization",
        \\   "scheme": "Bearer", "methods": ["GET"], "paths": ["/v1"]},
        \\ "billing": {"env": "BILLING_KEY", "endpoint": "https://billing.example", "header": "x-api-key",
        \\   "methods": ["POST"], "paths": ["/charges"]}}
    , .{});
    defer parsed.deinit();
    return (try zq.handler_contract.credential_ref.parseConfig(allocator, parsed.value)).ok;
}

test "the store loads every referenced value and finds it by name" {
    const refs = try testRefs(testing.allocator);
    defer zq.handler_contract.credential_ref.freeAll(testing.allocator, refs);
    const env = TestEnv{ .pairs = &.{ .{ "WEATHER_KEY", "w-secret" }, .{ "BILLING_KEY", "b-secret" } } };

    var store = (try load(testing.allocator, refs, env.source())).ok;
    defer store.deinit();
    try testing.expectEqualStrings("w-secret", store.value("weather").?);
    try testing.expectEqualStrings("b-secret", store.value("billing").?);
    try testing.expectEqual(@as(?[]const u8, null), store.value("WEATHER_KEY"));
    try testing.expectEqual(@as(?[]const u8, null), store.value("other"));
}

test "an unset or empty variable refuses the whole load and names the reference" {
    const refs = try testRefs(testing.allocator);
    defer zq.handler_contract.credential_ref.freeAll(testing.allocator, refs);

    // `billing` sorts first, so an unset WEATHER_KEY fails after one value
    // loaded: the partial entry must be released, which the testing allocator
    // checks.
    const cases = [_]TestEnv{
        .{ .pairs = &.{.{ "BILLING_KEY", "b-secret" }} },
        .{ .pairs = &.{ .{ "BILLING_KEY", "b-secret" }, .{ "WEATHER_KEY", "" } } },
    };
    for (cases) |env| {
        const result = try load(testing.allocator, refs, env.source());
        try testing.expectEqualStrings("weather", result.missing.name);
        try testing.expectEqualStrings("WEATHER_KEY", result.missing.env);
    }

    const none = TestEnv{ .pairs = &.{} };
    const first = try load(testing.allocator, refs, none.source());
    try testing.expectEqualStrings("billing", first.missing.name);
}

test "no references load an empty store" {
    const none = TestEnv{ .pairs = &.{} };
    var store = (try load(testing.allocator, &.{}, none.source())).ok;
    defer store.deinit();
    try testing.expectEqual(@as(usize, 0), store.entries.len);
}

test "the process environment source reads a real variable" {
    try testing.expectEqual(@as(?[]const u8, null), getProcessEnv(null, "ZTTP_CREDENTIAL_STORE_UNSET_TEST"));
    try testing.expect(getProcessEnv(null, "PATH") != null);
}

fn testStore(allocator: std.mem.Allocator) !Store {
    const refs = try testRefs(allocator);
    defer credential_ref.freeAll(allocator, refs);
    const env = TestEnv{ .pairs = &.{ .{ "WEATHER_KEY", "w-secret" }, .{ "BILLING_KEY", "b-secret" } } };
    return (try load(allocator, refs, env.source())).ok;
}

test "authorize grants the exact request a reference describes" {
    var store = try testStore(testing.allocator);
    defer store.deinit();

    const urls = [_][]const u8{
        "https://api.weather.example/v1",
        "https://api.weather.example:443/v1/forecast?lat=1&lon=2",
        "HTTPS://API.WEATHER.EXAMPLE/v1/forecast/",
        "https://api.weather.example/v1#frag",
    };
    for (urls) |url| {
        const decision = authorize(&store, true, "weather", .{ .url = url, .method = .GET, .headers = &.{.{ .name = "x-trace", .value = "1" }} });
        try testing.expectEqualStrings("weather", decision.granted.ref.name);
    }

    const granted = authorize(&store, true, "weather", .{ .url = urls[0], .method = .GET, .headers = &.{} }).granted;
    const header_value = try headerValue(testing.allocator, granted);
    defer releaseHeaderValue(testing.allocator, header_value);
    try testing.expectEqualStrings("Bearer w-secret", header_value);

    const billing = authorize(&store, true, "billing", .{ .url = "https://billing.example/charges", .method = .POST, .headers = &.{} }).granted;
    const bare = try headerValue(testing.allocator, billing);
    defer releaseHeaderValue(testing.allocator, bare);
    try testing.expectEqualStrings("b-secret", bare);
}

test "authorize refuses each rule with its named reason, and every reason is observed" {
    var store = try testStore(testing.allocator);
    defer store.deinit();

    // A reference the loader would refuse (plain http to a name), built by
    // hand so the last check is reachable.
    var plain_paths = [_][]const u8{"/"};
    const plain_entry = [_]Entry{.{
        .ref = .{
            .name = "plain",
            .env = "PLAIN",
            .endpoint = "http://localhost:8080",
            .header = "x-key",
            .methods = std.EnumSet(credential_ref.Method).initOne(.GET),
            .paths = &plain_paths,
        },
        .value = @constCast("p"),
    }};
    const plain_store = Store{ .allocator = testing.allocator, .entries = @constCast(&plain_entry) };

    const Case = struct {
        store: ?*const Store,
        granted: bool = true,
        name: []const u8 = "weather",
        url: []const u8 = "https://api.weather.example/v1",
        method: std.http.Method = .GET,
        headers: []const std.http.Header = &.{},
        expect: Refusal,
    };
    const cases = [_]Case{
        .{ .store = &store, .granted = false, .expect = .not_granted },
        .{ .store = null, .expect = .not_configured },
        .{ .store = &store, .name = "other", .expect = .not_configured },
        .{ .store = &store, .url = "https://api.weather.example:8443/v1", .expect = .endpoint_mismatch },
        .{ .store = &store, .url = "http://api.weather.example/v1", .expect = .endpoint_mismatch },
        .{ .store = &store, .url = "https://evil.example/v1", .expect = .endpoint_mismatch },
        .{ .store = &store, .url = "https://user@api.weather.example/v1", .expect = .endpoint_mismatch },
        .{ .store = &store, .method = .POST, .expect = .method_not_allowed },
        .{ .store = &store, .method = .TRACE, .expect = .method_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1x", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1/../admin", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1/%2e%2E/admin", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1/./x", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1%2fadmin", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1/a%5Cb", .expect = .path_not_allowed },
        .{ .store = &store, .url = "https://api.weather.example/v1//x", .expect = .path_not_allowed },
        .{ .store = &store, .headers = &.{.{ .name = "Authorization", .value = "Bearer mine" }}, .expect = .header_collision },
        .{ .store = &plain_store, .name = "plain", .url = "http://localhost:8080/", .expect = .plaintext },
    };

    var observed = std.EnumSet(Refusal).initEmpty();
    for (cases, 0..) |case, i| {
        const decision = authorize(case.store, case.granted, case.name, .{ .url = case.url, .method = case.method, .headers = case.headers });
        switch (decision) {
            .granted => {
                std.debug.print("case {d} ({s}) was granted, expected {s}\n", .{ i, case.url, @tagName(case.expect) });
                return error.TestUnexpectedResult;
            },
            .refused => |reason| {
                if (reason != case.expect) std.debug.print("case {d} ({s}): {s}, expected {s}\n", .{ i, case.url, @tagName(reason), @tagName(case.expect) });
                try testing.expectEqual(case.expect, reason);
                observed.insert(reason);
            },
        }
    }
    // `path_unsupported` belongs to the senders that never call `authorize`;
    // the runtime tests observe it. Every other member is observed here.
    var expected = std.EnumSet(Refusal).initFull();
    expected.remove(.path_unsupported);
    try testing.expect(observed.eql(expected));
}
