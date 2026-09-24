//! Credential values for outbound requests (M4 T6).
//!
//! The server reads the value of every credential reference once at startup,
//! from the environment variable the reference names. The handler's env allow
//! list does not apply: no JS value ever holds a credential, and `zttp:env`
//! cannot read one unless the handler's own policy names the same variable. A
//! reference whose variable is unset or empty stops the server from starting
//! (AE17, "missing secret binding"), in every mode.
//!
//! The store zeroes every value on release and never logs or formats one. The
//! runtime reads a value only through `value`, in the one function that adds
//! it to an authorized request. See
//! docs/plans/2026-09-24-m4-t6-credential-injection-design.md, sections 3 and 7.

const std = @import("std");
const zq = @import("zts");

pub const CredentialRef = zq.handler_contract.CredentialRef;
pub const credential_ref = zq.handler_contract.credential_ref;

pub const Entry = struct {
    name: []u8,
    value: []u8,
};

/// Every loaded value, in the references' order. Owns each name and value.
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn deinit(self: *Store) void {
        releaseEntries(self.allocator, self.entries);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// The value of the credential named `name`, or null. Borrowed for the
    /// store's lifetime.
    pub fn value(self: *const Store, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
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
        const name = try allocator.dupe(u8, ref.name);
        errdefer allocator.free(name);
        entries[filled] = .{ .name = name, .value = try allocator.dupe(u8, raw) };
        filled += 1;
    }
    return .{ .ok = .{ .allocator = allocator, .entries = entries } };
}

fn releaseEntries(allocator: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| {
        std.crypto.secureZero(u8, entry.value);
        allocator.free(entry.value);
        allocator.free(entry.name);
    }
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
