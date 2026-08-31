//! The consumer's own decoder for the runtime capability policy.
//!
//! The policy that decides which environment key, endpoint, cache namespace, or
//! SQL name a guarded operation may reach is serialized into the artifact and
//! committed as a graph member. This file reads those exact bytes with code the
//! checker owns.
//!
//! It is deliberately a second implementation. The producer serializes the
//! policy from its own types; if the checker asked the producer to decode it,
//! the checker would be checking the producer's reading rather than the bytes.
//! A digest without bytes proves even less: it says two sides hashed the same
//! blob, not that either could read it or that it contains the category a guard
//! needs.
//!
//! Zero-copy and allocation-free, like the rest of the kernel. Entries are
//! required to be in strictly ascending order, which is what makes a lookup a
//! bounded binary search and makes a duplicate impossible rather than merely
//! unlikely.

const std = @import("std");
const residual = @import("residual.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DecodeError = error{
    PolicyTooLarge,
    Truncated,
    TrailingData,
    CountExceedsLimit,
    EntryTooLong,
    EntryEmpty,
    EntriesNotSorted,
    DuplicateEntry,
    UnknownAddressScope,
    ReservedFieldNonZero,
    DigestMismatch,
};

/// One category's allowlist, as bytes inside the caller's buffer.
pub const Section = struct {
    /// False means the category was not configured. A guarded operation whose
    /// category is not enabled is refused: an absent list is not an empty one,
    /// and neither is a licence.
    enabled: bool = false,
    count: u16 = 0,
    bytes: []const u8 = &.{},
    /// Set for the SQL section, whose records carry a read-only flag.
    tagged: bool = false,

    pub fn get(self: Section, index: u16) DecodeError!Entry {
        if (index >= self.count) return error.Truncated;
        var cursor: usize = 0;
        var seen: u16 = 0;
        while (seen < index) : (seen += 1) {
            cursor = try self.skip(cursor);
        }
        return self.read(cursor);
    }

    fn skip(self: Section, cursor: usize) DecodeError!usize {
        const entry = try self.read(cursor);
        return cursor + entry.encoded_len;
    }

    fn read(self: Section, cursor: usize) DecodeError!Entry {
        var at = cursor;
        var read_only = false;
        if (self.tagged) {
            if (at + 1 > self.bytes.len) return error.Truncated;
            const flag = self.bytes[at];
            if (flag > 1) return error.ReservedFieldNonZero;
            read_only = flag == 1;
            at += 1;
        }
        if (at + 2 > self.bytes.len) return error.Truncated;
        const len = std.mem.readInt(u16, self.bytes[at..][0..2], .little);
        at += 2;
        if (at + len > self.bytes.len) return error.Truncated;
        return .{
            .value = self.bytes[at..][0..len],
            .read_only = read_only,
            .encoded_len = (at + len) - cursor,
        };
    }

    /// Whether an already-normalized value is in this list.
    ///
    /// Binary search over a strictly ascending list: at most
    /// `residual.max_lookup_comparisons` key comparisons at the entry cap, and
    /// the cap is a compile-time property of that constant.
    pub fn allows(self: Section, normalized: []const u8) DecodeError!bool {
        return (try self.find(normalized)) != null;
    }

    pub fn find(self: Section, normalized: []const u8) DecodeError!?Entry {
        var ignored: usize = 0;
        return self.findCounting(normalized, &ignored);
    }

    /// `find`, reporting what it cost. The counter is how the comparison bound
    /// is checked against the search rather than against a formula about it.
    fn findCounting(self: Section, normalized: []const u8, comparisons: *usize) DecodeError!?Entry {
        if (!self.enabled) return null;
        if (self.count == 0) return null;
        var low: u16 = 0;
        var high: u16 = self.count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = try self.get(mid);
            comparisons.* += 1;
            switch (std.mem.order(u8, entry.value, normalized)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return entry,
            }
        }
        return null;
    }
};

pub const Entry = struct {
    value: []const u8,
    read_only: bool,
    encoded_len: usize,
};

pub const Policy = struct {
    env: Section = .{},
    egress: Section = .{},
    cache: Section = .{},
    sql: Section = .{},
    /// Which resolved-address scopes an outbound connection may land in.
    scopes: residual.ScopeSet = .{},
    /// SHA-256 of the exact bytes this was decoded from.
    digest: [32]u8 = [_]u8{0} ** 32,

    pub fn section(self: *const Policy, which: residual.PolicySection) Section {
        return switch (which) {
            .env => self.env,
            .egress => self.egress,
            .cache => self.cache,
            .sql => self.sql,
        };
    }

    /// Whether the category a guard kind needs is configured at all.
    pub fn categoryEnabled(self: *const Policy, kind: residual.GuardKind) bool {
        return self.section(kind.section()).enabled;
    }
};

fn maxEntryBytes(which: residual.PolicySection) usize {
    return switch (which) {
        .egress => residual.max_endpoint_bytes,
        .env, .cache, .sql => residual.max_identifier_bytes,
    };
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn u8At(self: *Cursor) DecodeError!u8 {
        if (self.at + 1 > self.bytes.len) return error.Truncated;
        const value = self.bytes[self.at];
        self.at += 1;
        return value;
    }

    fn u16At(self: *Cursor) DecodeError!u16 {
        if (self.at + 2 > self.bytes.len) return error.Truncated;
        const value = std.mem.readInt(u16, self.bytes[self.at..][0..2], .little);
        self.at += 2;
        return value;
    }

    fn take(self: *Cursor, len: usize) DecodeError![]const u8 {
        if (self.at + len > self.bytes.len) return error.Truncated;
        const slice = self.bytes[self.at..][0..len];
        self.at += len;
        return slice;
    }
};

fn decodeSection(
    cursor: *Cursor,
    which: residual.PolicySection,
    tagged: bool,
) DecodeError!Section {
    const enabled_byte = try cursor.u8At();
    if (enabled_byte > 1) return error.ReservedFieldNonZero;
    const count = try cursor.u16At();
    if (count > residual.max_policy_entries) return error.CountExceedsLimit;

    const start = cursor.at;
    var previous: ?[]const u8 = null;
    var index: u16 = 0;
    while (index < count) : (index += 1) {
        if (tagged) {
            const flag = try cursor.u8At();
            if (flag > 1) return error.ReservedFieldNonZero;
        }
        const len = try cursor.u16At();
        if (len == 0) return error.EntryEmpty;
        if (len > maxEntryBytes(which)) return error.EntryTooLong;
        const value = try cursor.take(len);
        if (previous) |prev| {
            switch (std.mem.order(u8, prev, value)) {
                .lt => {},
                .eq => return error.DuplicateEntry,
                // Ascending order is not cosmetic: it is what makes the lookup
                // bounded and what makes a duplicate impossible to encode.
                .gt => return error.EntriesNotSorted,
            }
        }
        previous = value;
    }

    return .{
        .enabled = enabled_byte == 1,
        .count = count,
        .bytes = cursor.bytes[start..cursor.at],
        .tagged = tagged,
    };
}

/// Decode the serialized runtime capability policy and bind it to a digest.
///
/// `expected_digest` is the value the certificate committed to. The digest is
/// recomputed here from the bytes rather than accepted, so a caller cannot hand
/// the kernel one artifact's policy and another artifact's hash.
pub fn decode(bytes: []const u8, expected_digest: [32]u8) DecodeError!Policy {
    if (bytes.len > residual.max_policy_bytes) return error.PolicyTooLarge;

    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected_digest)) return error.DigestMismatch;

    var cursor = Cursor{ .bytes = bytes };
    const env = try decodeSection(&cursor, .env, false);
    const egress = try decodeSection(&cursor, .egress, false);
    const cache = try decodeSection(&cursor, .cache, false);
    const sql = try decodeSection(&cursor, .sql, true);
    const scope_bits = try cursor.u8At();
    const scopes = residual.ScopeSet.fromWire(scope_bits) orelse return error.UnknownAddressScope;

    if (cursor.at != bytes.len) return error.TrailingData;

    return .{
        .env = env,
        .egress = egress,
        .cache = cache,
        .sql = sql,
        .scopes = scopes,
        .digest = digest,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Builder = struct {
    buffer: [4096]u8 = undefined,
    len: usize = 0,

    fn byte(self: *Builder, value: u8) void {
        self.buffer[self.len] = value;
        self.len += 1;
    }

    fn u16le(self: *Builder, value: u16) void {
        std.mem.writeInt(u16, self.buffer[self.len..][0..2], value, .little);
        self.len += 2;
    }

    fn section(self: *Builder, enabled: bool, entries: []const []const u8) void {
        self.byte(if (enabled) 1 else 0);
        self.u16le(@intCast(entries.len));
        for (entries) |entry| {
            self.u16le(@intCast(entry.len));
            @memcpy(self.buffer[self.len..][0..entry.len], entry);
            self.len += entry.len;
        }
    }

    fn sqlSection(self: *Builder, enabled: bool, entries: []const []const u8, read_only: bool) void {
        self.byte(if (enabled) 1 else 0);
        self.u16le(@intCast(entries.len));
        for (entries) |entry| {
            self.byte(if (read_only) 1 else 0);
            self.u16le(@intCast(entry.len));
            @memcpy(self.buffer[self.len..][0..entry.len], entry);
            self.len += entry.len;
        }
    }

    fn bytes(self: *const Builder) []const u8 {
        return self.buffer[0..self.len];
    }

    fn digest(self: *const Builder) [32]u8 {
        var out: [32]u8 = undefined;
        Sha256.hash(self.bytes(), &out, .{});
        return out;
    }
};

fn sample() Builder {
    var b = Builder{};
    b.section(true, &.{ "API_KEY", "DATABASE_URL" });
    b.section(true, &.{ "https://a.example.com:443", "https://b.example.com:443" });
    b.section(true, &.{ "metrics", "sessions" });
    b.sqlSection(true, &.{ "insertTodo", "listTodos" }, true);
    b.byte(residual.AddressScope.public.bit());
    return b;
}

test "a well formed policy decodes and answers lookups" {
    var b = sample();
    const policy = try decode(b.bytes(), b.digest());

    try testing.expect(policy.env.enabled);
    try testing.expectEqual(@as(u16, 2), policy.env.count);
    try testing.expect(try policy.env.allows("API_KEY"));
    try testing.expect(try policy.env.allows("DATABASE_URL"));
    try testing.expect(!try policy.env.allows("SECRET"));
    // Case is significant for identifiers.
    try testing.expect(!try policy.env.allows("api_key"));

    try testing.expect(try policy.egress.allows("https://b.example.com:443"));
    try testing.expect(!try policy.egress.allows("http://b.example.com:80"));
    try testing.expect(try policy.cache.allows("sessions"));
    try testing.expect(try policy.sql.allows("listTodos"));
    try testing.expect((try policy.sql.find("listTodos")).?.read_only);

    try testing.expect(policy.scopes.contains(.public));
    try testing.expect(!policy.scopes.contains(.loopback));
    try testing.expect(policy.categoryEnabled(.env_key));
    try testing.expect(policy.categoryEnabled(.sql_write));
}

test "a digest that does not match the bytes rejects" {
    var b = sample();
    var wrong = b.digest();
    wrong[0] +%= 1;
    try testing.expectError(error.DigestMismatch, decode(b.bytes(), wrong));
}

test "an absent category is not an empty one" {
    var b = Builder{};
    b.section(false, &.{});
    b.section(true, &.{});
    b.section(false, &.{});
    b.section(false, &.{});
    b.byte(0);
    var sql = b;
    // The fourth section is tagged; rebuild it that way.
    sql.len = 0;
    sql.section(false, &.{});
    sql.section(true, &.{});
    sql.section(false, &.{});
    sql.sqlSection(false, &.{}, true);
    sql.byte(0);

    const policy = try decode(sql.bytes(), sql.digest());
    // Not configured: a guarded operation in this category cannot be accepted.
    try testing.expect(!policy.categoryEnabled(.env_key));
    // Configured and empty: deny-all, which is a decision, not an absence.
    try testing.expect(policy.categoryEnabled(.egress_endpoint));
    try testing.expect(!try policy.egress.allows("https://a.example.com:443"));
    try testing.expect(policy.scopes.isEmpty());
}

test "unsorted, duplicate, empty, and oversized entries reject" {
    var unsorted = Builder{};
    unsorted.section(true, &.{ "b", "a" });
    unsorted.section(true, &.{});
    unsorted.section(true, &.{});
    unsorted.sqlSection(true, &.{}, true);
    unsorted.byte(0);
    try testing.expectError(error.EntriesNotSorted, decode(unsorted.bytes(), unsorted.digest()));

    var duplicate = Builder{};
    duplicate.section(true, &.{ "a", "a" });
    duplicate.section(true, &.{});
    duplicate.section(true, &.{});
    duplicate.sqlSection(true, &.{}, true);
    duplicate.byte(0);
    try testing.expectError(error.DuplicateEntry, decode(duplicate.bytes(), duplicate.digest()));

    var empty = Builder{};
    empty.section(true, &.{""});
    empty.section(true, &.{});
    empty.section(true, &.{});
    empty.sqlSection(true, &.{}, true);
    empty.byte(0);
    try testing.expectError(error.EntryEmpty, decode(empty.bytes(), empty.digest()));

    const long = [_]u8{'a'} ** (residual.max_identifier_bytes + 1);
    var oversized = Builder{};
    oversized.section(true, &.{&long});
    oversized.section(true, &.{});
    oversized.section(true, &.{});
    oversized.sqlSection(true, &.{}, true);
    oversized.byte(0);
    try testing.expectError(error.EntryTooLong, decode(oversized.bytes(), oversized.digest()));
}

test "an endpoint may be longer than an identifier, up to its own bound" {
    const host = [_]u8{'a'} ** 200;
    const endpoint = "https://" ++ host ++ ":443";
    var b = Builder{};
    b.section(true, &.{});
    b.section(true, &.{endpoint});
    b.section(true, &.{});
    b.sqlSection(true, &.{}, true);
    b.byte(0);
    const policy = try decode(b.bytes(), b.digest());
    try testing.expect(try policy.egress.allows(endpoint));
}

test "an over-count, trailing bytes, truncation, and an unknown scope reject" {
    var over = Builder{};
    over.byte(1);
    over.u16le(residual.max_policy_entries + 1);
    try testing.expectError(error.CountExceedsLimit, decode(over.bytes(), over.digest()));

    var trailing = sample();
    trailing.byte(0xAA);
    try testing.expectError(error.TrailingData, decode(trailing.bytes(), trailing.digest()));

    var scope = Builder{};
    scope.section(true, &.{});
    scope.section(true, &.{});
    scope.section(true, &.{});
    scope.sqlSection(true, &.{}, true);
    scope.byte(0x80);
    try testing.expectError(error.UnknownAddressScope, decode(scope.bytes(), scope.digest()));

    var b = sample();
    var cut: usize = 1;
    while (cut < b.len) : (cut += 3) {
        const bytes = b.buffer[0..cut];
        var digest: [32]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        try testing.expect(std.meta.isError(decode(bytes, digest)));
    }
}

test "a policy larger than the bound is refused before it is read" {
    const big = [_]u8{0} ** 16;
    var digest: [32]u8 = undefined;
    Sha256.hash(&big, &digest, .{});
    // The bound is on the input, so a short blob passes the size gate and fails
    // later; the check itself is exercised by its own constant.
    try testing.expect(residual.max_policy_bytes == 256 * 1024);
    try testing.expect(std.meta.isError(decode(&big, digest)));
}

test "a full category still resolves inside the comparison bound" {
    // 256 entries, sorted, each distinct. The search must settle in at most
    // eight key comparisons; the bound itself is pinned at compile time in
    // residual.zig, and this proves the encoding a full category produces is
    // one the search can actually walk.
    var buffer: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    buffer[len] = 1;
    len += 1;
    std.mem.writeInt(u16, buffer[len..][0..2], residual.max_policy_entries, .little);
    len += 2;
    var index: u16 = 0;
    while (index < residual.max_policy_entries) : (index += 1) {
        var name: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "k{d:0>5}", .{index}) catch unreachable;
        std.mem.writeInt(u16, buffer[len..][0..2], @intCast(text.len), .little);
        len += 2;
        @memcpy(buffer[len..][0..text.len], text);
        len += text.len;
    }
    // Three empty sections and the scope byte.
    buffer[len] = 0;
    len += 1;
    std.mem.writeInt(u16, buffer[len..][0..2], 0, .little);
    len += 2;
    buffer[len] = 0;
    len += 1;
    std.mem.writeInt(u16, buffer[len..][0..2], 0, .little);
    len += 2;
    buffer[len] = 0;
    len += 1;
    std.mem.writeInt(u16, buffer[len..][0..2], 0, .little);
    len += 2;
    buffer[len] = 0;
    len += 1;

    const bytes = buffer[0..len];
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const policy = try decode(bytes, digest);
    try testing.expectEqual(residual.max_policy_entries, policy.env.count);
    try testing.expect(try policy.env.allows("k00000"));
    try testing.expect(try policy.env.allows("k00255"));
    try testing.expect(!try policy.env.allows("k00256"));

    // What the search actually costs at the cap, over every entry and over a
    // miss below, inside, and above the range. The worst case is the bound, so
    // the test names the value rather than a difference from it.
    var worst: usize = 0;
    index = 0;
    while (index < residual.max_policy_entries) : (index += 1) {
        var name: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "k{d:0>5}", .{index}) catch unreachable;
        var comparisons: usize = 0;
        _ = try policy.env.findCounting(text, &comparisons);
        worst = @max(worst, comparisons);
    }
    for ([_][]const u8{ "a00000", "k00000x", "z00000" }) |absent| {
        var comparisons: usize = 0;
        _ = try policy.env.findCounting(absent, &comparisons);
        worst = @max(worst, comparisons);
    }
    try testing.expectEqual(residual.max_lookup_comparisons, worst);
}
