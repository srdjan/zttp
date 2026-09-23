//! The canonical consumer declaration, `ZTDCL1`.
//!
//! A handler built with a consumer declaration ships the declaration's
//! canonical bytes: its classifications and its capability ceiling. The
//! executable graph commits to them as member `declaration`. The kernel decodes
//! the bytes itself, recomputes their domain-separated digest, and compares it
//! with the member. The decoder is zero-copy and allocation-free: every slice it
//! returns points into the bytes the caller holds.
//!
//! The producer is `encodeCanonical` in `packages/zts/src/declaration.zig`,
//! which writes the value its loader accepted. This decoder does not trust it:
//! every bound and every order rule below is checked here again.
//!
//! Layout (integers little-endian, strings u32-length-prefixed):
//!
//! ```text
//! magic                 8 bytes  "ZTDCL1\0\0"
//! schema                u16      1
//! classification_count  u16      0..256
//! classification, count times, strictly increasing by (kind, name, path):
//!   source_kind  u8      0 fetch, 1 service
//!   source_name  string  1..253
//!   path         string  1..1040 (1..16 segments of up to 64 bytes and dots)
//!   label        u8      0 secret, 1 credential
//!   required     u8      0 or 1
//!   reason       string  1..1024
//! ceiling_present       u8       0 or 1
//! ceiling, when present:
//!   profile        u8      0 boundary, 1 adapter, 2 ledger
//!   exclude_count  u16     0..64
//!   exclude, count times, strictly increasing: string 6..64, starts "zttp:"
//! trailing bytes: refused
//! ```
//!
//! A declaration with no classifications and no ceiling is refused. A path
//! segment is `[A-Za-z_][A-Za-z0-9_]*` and an exclude entry is `[a-z0-9_:-]`,
//! the loader's own grammar. A source name and a reason must be valid UTF-8;
//! the kernel does not re-check the host or service grammar of a source name.
//! See docs/plans/2026-09-23-m4-t5-scope-and-grants-design.md section 13.

const std = @import("std");

pub const magic = "ZTDCL1\x00\x00";
pub const schema_version: u16 = 1;
pub const header_size: usize = magic.len + 2 + 2;

pub const digest_domain = "zttp-declaration-v1";

pub const max_classifications: u16 = 256;
pub const max_source_name_bytes: u32 = 253;
pub const max_path_bytes: u32 = 1040;
pub const max_path_segments: usize = 16;
pub const max_segment_bytes: usize = 64;
pub const max_reason_bytes: u32 = 1024;
pub const max_exclude: u16 = 64;
pub const min_exclude_bytes: u32 = 6;
pub const max_exclude_bytes: u32 = 64;
pub const exclude_prefix = "zttp:";

/// Every refusal the decoder can report. Closed, and each member names one
/// distinct defect so a diagnostic can say which rule the bytes broke.
pub const DecodeError = error{
    Truncated,
    BadMagic,
    UnsupportedSchema,
    ClassificationCountOutOfRange,
    /// A `source_kind` byte other than 0 or 1.
    SourceKindInvalid,
    SourceNameLength,
    /// A path whose length, segment count, segment length, or segment
    /// characters break the rule above.
    PathInvalid,
    /// A `label` byte other than 0 or 1.
    LabelInvalid,
    /// A `required` byte other than 0 or 1.
    RequiredInvalid,
    ReasonLength,
    /// Classifications must be strictly increasing by (kind, name, path),
    /// which also refuses two entries with the same source and path.
    ClassificationsNotOrdered,
    /// A `ceiling_present` byte other than 0 or 1.
    CeilingFlagInvalid,
    /// A `profile` byte other than 0, 1, or 2.
    ProfileInvalid,
    ExcludeCountOutOfRange,
    /// An exclude entry whose length, prefix, or characters break the rule
    /// above.
    ExcludeInvalid,
    /// Exclude entries must be strictly increasing by bytes, which also
    /// refuses a repeated entry.
    ExcludesNotOrdered,
    /// No classifications and no ceiling.
    DeclarationEmpty,
    InvalidUtf8,
    TrailingData,
};

pub const SourceKind = enum(u8) { fetch = 0, service = 1 };
pub const Label = enum(u8) { secret = 0, credential = 1 };

/// The ceiling profiles, in wire order. The names are those of
/// `packages/zts/src/capability_profiles.zig`; the round-trip test in
/// `packages/tools/src/declaration_encoding_test.zig` fails when the two
/// disagree.
pub const Profile = enum(u8) { boundary = 0, adapter = 1, ledger = 2 };

pub const Classification = struct {
    source_kind: SourceKind,
    source_name: []const u8,
    /// The dot-separated path as written.
    path: []const u8,
    label: Label,
    required: bool,
    reason: []const u8,

    fn order(a: Classification, b: Classification) std.math.Order {
        if (a.source_kind != b.source_kind) {
            return std.math.order(@intFromEnum(a.source_kind), @intFromEnum(b.source_kind));
        }
        const by_name = std.mem.order(u8, a.source_name, b.source_name);
        if (by_name != .eq) return by_name;
        return std.mem.order(u8, a.path, b.path);
    }
};

pub const Ceiling = struct {
    profile: Profile,
    exclude_count: u16,
    exclude_bytes: []const u8,
    exclude_pos: usize,

    pub fn excludes(self: Ceiling) ExcludeIterator {
        return .{ .bytes = self.exclude_bytes, .pos = self.exclude_pos, .remaining = self.exclude_count };
    }
};

/// A decoded declaration. Only `decode` builds one, so the bytes it holds have
/// passed every rule above.
pub const Declaration = struct {
    bytes: []const u8,
    classification_count: u16,
    ceiling: ?Ceiling,

    pub fn classifications(self: Declaration) ClassificationIterator {
        return .{ .bytes = self.bytes, .pos = header_size, .remaining = self.classification_count };
    }
};

/// Bounds-checked reads over a byte slice. It reports truncation and nothing
/// else: content rules are checked by `decode`.
const Reader = struct {
    bytes: []const u8,
    pos: usize,

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        const size = @sizeOf(T);
        if (self.bytes.len - self.pos < size) return error.Truncated;
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..size], .little);
        self.pos += size;
        return value;
    }

    /// A length-prefixed string. The length bound is checked before the body
    /// is required, so an out-of-range length names itself rather than
    /// surfacing as truncation.
    fn string(self: *Reader, min: u32, max: u32, length_error: DecodeError) DecodeError![]const u8 {
        const len = try self.int(u32);
        if (len < min or len > max) return length_error;
        if (self.bytes.len - self.pos < len) return error.Truncated;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }
};

pub const ClassificationIterator = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u16,

    pub fn next(self: *ClassificationIterator) DecodeError!?Classification {
        if (self.remaining == 0) return null;
        var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
        const item = try readClassification(&reader);
        self.pos = reader.pos;
        self.remaining -= 1;
        return item;
    }
};

pub const ExcludeIterator = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u16,

    pub fn next(self: *ExcludeIterator) DecodeError!?[]const u8 {
        if (self.remaining == 0) return null;
        var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
        const item = try reader.string(min_exclude_bytes, max_exclude_bytes, error.ExcludeInvalid);
        self.pos = reader.pos;
        self.remaining -= 1;
        return item;
    }
};

/// Read one classification with every field rule applied.
fn readClassification(reader: *Reader) DecodeError!Classification {
    const kind_byte = try reader.int(u8);
    if (kind_byte > 1) return error.SourceKindInvalid;
    const source_name = try reader.string(1, max_source_name_bytes, error.SourceNameLength);
    const path = try reader.string(1, max_path_bytes, error.PathInvalid);
    try validPath(path);
    const label_byte = try reader.int(u8);
    if (label_byte > 1) return error.LabelInvalid;
    const required_byte = try reader.int(u8);
    if (required_byte > 1) return error.RequiredInvalid;
    const reason = try reader.string(1, max_reason_bytes, error.ReasonLength);
    if (!std.unicode.utf8ValidateSlice(source_name)) return error.InvalidUtf8;
    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
    return .{
        .source_kind = @enumFromInt(kind_byte),
        .source_name = source_name,
        .path = path,
        .label = @enumFromInt(label_byte),
        .required = required_byte == 1,
        .reason = reason,
    };
}

/// 1 to 16 dot-separated segments, each `[A-Za-z_][A-Za-z0-9_]*` and at most
/// 64 bytes.
fn validPath(path: []const u8) DecodeError!void {
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        count += 1;
        if (count > max_path_segments) return error.PathInvalid;
        if (segment.len == 0 or segment.len > max_segment_bytes) return error.PathInvalid;
        if (!(std.ascii.isAlphabetic(segment[0]) or segment[0] == '_')) return error.PathInvalid;
        for (segment[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return error.PathInvalid;
        }
    }
}

fn validExclude(entry: []const u8) DecodeError!void {
    if (!std.mem.startsWith(u8, entry, exclude_prefix)) return error.ExcludeInvalid;
    for (entry) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '_' or c == ':' or c == '-';
        if (!ok) return error.ExcludeInvalid;
    }
}

/// Decode and validate canonical declaration bytes.
pub fn decode(bytes: []const u8) DecodeError!Declaration {
    if (bytes.len < magic.len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    var reader = Reader{ .bytes = bytes, .pos = magic.len };
    if (try reader.int(u16) != schema_version) return error.UnsupportedSchema;
    const count = try reader.int(u16);
    if (count > max_classifications) return error.ClassificationCountOutOfRange;

    var previous: ?Classification = null;
    var index: u16 = 0;
    while (index < count) : (index += 1) {
        const item = try readClassification(&reader);
        if (previous) |prev| {
            if (Classification.order(prev, item) != .lt) return error.ClassificationsNotOrdered;
        }
        previous = item;
    }

    const flag = try reader.int(u8);
    if (flag > 1) return error.CeilingFlagInvalid;
    var ceiling: ?Ceiling = null;
    if (flag == 1) {
        const profile_byte = try reader.int(u8);
        if (profile_byte > @intFromEnum(Profile.ledger)) return error.ProfileInvalid;
        const exclude_count = try reader.int(u16);
        if (exclude_count > max_exclude) return error.ExcludeCountOutOfRange;
        const exclude_pos = reader.pos;
        var it = ExcludeIterator{ .bytes = bytes, .pos = exclude_pos, .remaining = exclude_count };
        var previous_entry: ?[]const u8 = null;
        while (try it.next()) |entry| {
            try validExclude(entry);
            if (previous_entry) |prev| {
                if (std.mem.order(u8, prev, entry) != .lt) return error.ExcludesNotOrdered;
            }
            previous_entry = entry;
        }
        reader.pos = it.pos;
        ceiling = .{
            .profile = @enumFromInt(profile_byte),
            .exclude_count = exclude_count,
            .exclude_bytes = bytes[0..reader.pos],
            .exclude_pos = exclude_pos,
        };
    }
    if (reader.pos != bytes.len) return error.TrailingData;
    if (count == 0 and ceiling == null) return error.DeclarationEmpty;

    return .{ .bytes = bytes, .classification_count = count, .ceiling = ceiling };
}

/// Domain-separated SHA-256 over the whole encoding. The digest a graph member
/// carries for these bytes.
pub fn digest(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(digest_domain);
    hasher.update(bytes);
    return hasher.finalResult();
}

// ---------------------------------------------------------------------------
// Test support
// ---------------------------------------------------------------------------

/// A writer for building declarations in tests, over a fixed buffer. It writes
/// what it is told, valid or not, so a test can build each refusal directly.
pub const test_support = struct {
    pub const Writer = struct {
        buf: []u8,
        len: usize = 0,

        pub fn raw(self: *Writer, data: []const u8) void {
            @memcpy(self.buf[self.len..][0..data.len], data);
            self.len += data.len;
        }

        pub fn int(self: *Writer, comptime T: type, value: T) void {
            std.mem.writeInt(T, self.buf[self.len..][0..@sizeOf(T)], value, .little);
            self.len += @sizeOf(T);
        }

        pub fn string(self: *Writer, data: []const u8) void {
            self.int(u32, @intCast(data.len));
            self.raw(data);
        }

        pub fn bytes(self: *const Writer) []const u8 {
            return self.buf[0..self.len];
        }
    };

    /// Raw bytes rather than enums, so a test can write an out-of-range code.
    pub const SampleClassification = struct {
        source_kind: u8 = 0,
        source_name: []const u8 = "api.example.com",
        path: []const u8,
        label: u8 = 0,
        required: u8 = 1,
        reason: []const u8 = "Tax identifier.",
    };

    pub const SampleCeiling = struct {
        profile: u8 = 0,
        exclude: []const []const u8 = &.{},
    };

    pub fn writeClassification(w: *Writer, item: SampleClassification) void {
        w.int(u8, item.source_kind);
        w.string(item.source_name);
        w.string(item.path);
        w.int(u8, item.label);
        w.int(u8, item.required);
        w.string(item.reason);
    }

    pub fn writeDeclaration(w: *Writer, items: []const SampleClassification, ceiling: ?SampleCeiling) void {
        w.raw(magic);
        w.int(u16, schema_version);
        w.int(u16, @intCast(items.len));
        for (items) |item| writeClassification(w, item);
        if (ceiling) |c| {
            w.int(u8, 1);
            w.int(u8, c.profile);
            w.int(u16, @intCast(c.exclude.len));
            for (c.exclude) |entry| w.string(entry);
        } else {
            w.int(u8, 0);
        }
    }

    pub const sample_classifications = [_]SampleClassification{
        .{ .path = "customer.tax_id" },
        .{ .source_kind = 1, .source_name = "billing", .path = "card.token", .label = 1, .required = 0, .reason = "Payment token." },
    };

    pub const sample_ceiling = SampleCeiling{ .profile = 1, .exclude = &.{ "zttp:fetch", "zttp:sql" } };

    /// The two-classification sample with an `adapter` ceiling, written into
    /// `buf`.
    pub fn sample(buf: []u8) []const u8 {
        var w = Writer{ .buf = buf };
        writeDeclaration(&w, &sample_classifications, sample_ceiling);
        return w.bytes();
    }
};

const testing = std.testing;

test "a valid declaration decodes and iterates every field" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const decl = try decode(bytes);
    try testing.expectEqual(@as(u16, 2), decl.classification_count);

    var it = decl.classifications();
    const first = (try it.next()).?;
    try testing.expectEqual(SourceKind.fetch, first.source_kind);
    try testing.expectEqualStrings("api.example.com", first.source_name);
    try testing.expectEqualStrings("customer.tax_id", first.path);
    try testing.expectEqual(Label.secret, first.label);
    try testing.expect(first.required);
    try testing.expectEqualStrings("Tax identifier.", first.reason);
    const second = (try it.next()).?;
    try testing.expectEqual(SourceKind.service, second.source_kind);
    try testing.expectEqualStrings("billing", second.source_name);
    try testing.expectEqualStrings("card.token", second.path);
    try testing.expectEqual(Label.credential, second.label);
    try testing.expect(!second.required);
    try testing.expectEqualStrings("Payment token.", second.reason);
    try testing.expectEqual(@as(?Classification, null), try it.next());

    const ceiling = decl.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqual(Profile.adapter, ceiling.profile);
    var excludes = ceiling.excludes();
    try testing.expectEqualStrings("zttp:fetch", (try excludes.next()).?);
    try testing.expectEqualStrings("zttp:sql", (try excludes.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try excludes.next());

    // Zero-copy: every slice points into the input.
    const base = @intFromPtr(bytes.ptr);
    try testing.expect(@intFromPtr(first.source_name.ptr) >= base);
    try testing.expect(@intFromPtr(second.reason.ptr) + second.reason.len <= base + bytes.len);
}

test "a declaration with only classifications or only a ceiling decodes" {
    var buf: [1024]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeDeclaration(&w, &test_support.sample_classifications, null);
    const only_classes = try decode(w.bytes());
    try testing.expectEqual(@as(?Ceiling, null), only_classes.ceiling);

    var w2 = test_support.Writer{ .buf = &buf };
    test_support.writeDeclaration(&w2, &.{}, .{ .profile = 2 });
    const only_ceiling = try decode(w2.bytes());
    try testing.expectEqual(@as(u16, 0), only_ceiling.classification_count);
    const ceiling = only_ceiling.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqual(Profile.ledger, ceiling.profile);
    var excludes = ceiling.excludes();
    try testing.expectEqual(@as(?[]const u8, null), try excludes.next());
}

test "the declaration digest is stable and domain-separated" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const a = digest(bytes);
    try testing.expectEqualSlices(u8, &a, &digest(bytes));

    var plain: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &plain, .{});
    try testing.expect(!std.mem.eql(u8, &a, &plain));

    var tampered_buf: [1024]u8 = undefined;
    @memcpy(tampered_buf[0..bytes.len], bytes);
    tampered_buf[bytes.len - 1] ^= 1;
    try testing.expect(!std.mem.eql(u8, &a, &digest(tampered_buf[0..bytes.len])));
}

const Case = struct {
    expected: DecodeError,
    classifications: []const test_support.SampleClassification = &.{},
    ceiling: ?test_support.SampleCeiling = test_support.SampleCeiling{},
    /// When set, the case is written by hand instead of from the fields above.
    custom: ?*const fn (w: *test_support.Writer) void = null,
};

fn sampleWithTrailingByte(w: *test_support.Writer) void {
    test_support.writeDeclaration(w, &test_support.sample_classifications, test_support.sample_ceiling);
    w.raw(&.{0});
}

fn sampleTruncated(w: *test_support.Writer) void {
    test_support.writeDeclaration(w, &test_support.sample_classifications, test_support.sample_ceiling);
    w.len -= 1;
}

fn shortMagic(w: *test_support.Writer) void {
    w.raw("ZTDCL");
}

fn badMagic(w: *test_support.Writer) void {
    w.raw("ZTDCL2\x00\x00");
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 0);
}

fn unsupportedSchema(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, 2);
    w.int(u16, 0);
    w.int(u8, 0);
}

fn tooManyClassifications(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_classifications + 1);
}

/// A classification whose fields before `field` are valid and whose string
/// field `field` claims `len` bytes without carrying them. The length bound
/// fires before the body is required. Fields: 0 source_name, 1 path, 2 reason.
fn claimLength(w: *test_support.Writer, field: usize, len: u32) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, 0);
    if (field == 0) return w.int(u32, len);
    w.string("a.example");
    if (field == 1) return w.int(u32, len);
    w.string("a");
    w.int(u8, 0);
    w.int(u8, 1);
    w.int(u32, len);
}

fn sourceNameTooLong(w: *test_support.Writer) void {
    claimLength(w, 0, max_source_name_bytes + 1);
}

fn pathTooLong(w: *test_support.Writer) void {
    claimLength(w, 1, max_path_bytes + 1);
}

fn reasonTooLong(w: *test_support.Writer) void {
    claimLength(w, 2, max_reason_bytes + 1);
}

fn tooManyExcludes(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 1);
    w.int(u8, 0);
    w.int(u16, max_exclude + 1);
}

fn excludeTooLong(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 1);
    w.int(u8, 0);
    w.int(u16, 1);
    w.int(u32, max_exclude_bytes + 1);
}

const segment_65 = "a" ** (max_segment_bytes + 1);
const path_17 = "a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q";

const s = test_support.sample_classifications;

const cases = [_]Case{
    .{ .expected = error.Truncated, .custom = sampleTruncated },
    .{ .expected = error.Truncated, .custom = shortMagic },
    .{ .expected = error.BadMagic, .custom = badMagic },
    .{ .expected = error.UnsupportedSchema, .custom = unsupportedSchema },
    .{ .expected = error.ClassificationCountOutOfRange, .custom = tooManyClassifications },
    .{ .expected = error.SourceKindInvalid, .classifications = &.{.{ .path = "a", .source_kind = 2 }} },
    .{ .expected = error.SourceNameLength, .classifications = &.{.{ .path = "a", .source_name = "" }} },
    .{ .expected = error.SourceNameLength, .custom = sourceNameTooLong },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = "" }} },
    .{ .expected = error.PathInvalid, .custom = pathTooLong },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = "a..b" }} },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = "a." }} },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = "1a" }} },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = "a.b-c" }} },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = segment_65 }} },
    .{ .expected = error.PathInvalid, .classifications = &.{.{ .path = path_17 }} },
    .{ .expected = error.LabelInvalid, .classifications = &.{.{ .path = "a", .label = 2 }} },
    .{ .expected = error.RequiredInvalid, .classifications = &.{.{ .path = "a", .required = 2 }} },
    .{ .expected = error.ReasonLength, .classifications = &.{.{ .path = "a", .reason = "" }} },
    .{ .expected = error.ReasonLength, .custom = reasonTooLong },
    .{ .expected = error.InvalidUtf8, .classifications = &.{.{ .path = "a", .reason = "\xff" }} },
    .{ .expected = error.InvalidUtf8, .classifications = &.{.{ .path = "a", .source_name = "a\xc3" }} },
    // Out of order by kind, by name, and by path; then a repeat.
    .{ .expected = error.ClassificationsNotOrdered, .classifications = &.{ s[1], s[0] } },
    .{ .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "a", .source_name = "b.example" }, .{ .path = "a", .source_name = "a.example" } } },
    .{ .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "b" }, .{ .path = "a" } } },
    .{ .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "a" }, .{ .path = "a", .label = 1 } } },
    .{ .expected = error.CeilingFlagInvalid, .custom = ceilingFlagTwo },
    .{ .expected = error.ProfileInvalid, .ceiling = .{ .profile = 3 } },
    .{ .expected = error.ExcludeCountOutOfRange, .custom = tooManyExcludes },
    .{ .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp"} } },
    .{ .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp-e:x"} } },
    .{ .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp:A"} } },
    .{ .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp:a/b"} } },
    .{ .expected = error.ExcludeInvalid, .custom = excludeTooLong },
    .{ .expected = error.ExcludesNotOrdered, .ceiling = .{ .exclude = &.{ "zttp:sql", "zttp:fetch" } } },
    .{ .expected = error.ExcludesNotOrdered, .ceiling = .{ .exclude = &.{ "zttp:fetch", "zttp:fetch" } } },
    .{ .expected = error.DeclarationEmpty, .ceiling = null },
    .{ .expected = error.TrailingData, .custom = sampleWithTrailingByte },
};

fn ceilingFlagTwo(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 2);
}

test "every refusal case decodes to its exact error" {
    for (cases, 0..) |case, index| {
        var buf: [2048]u8 = undefined;
        var w = test_support.Writer{ .buf = &buf };
        if (case.custom) |write| {
            write(&w);
        } else {
            test_support.writeDeclaration(&w, case.classifications, case.ceiling);
        }
        const result = decode(w.bytes());
        if (result) |_| {
            std.debug.print("case {d}: expected {s}, decoded\n", .{ index, @errorName(case.expected) });
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != case.expected) {
                std.debug.print("case {d}: expected {s}, got {s}\n", .{ index, @errorName(case.expected), @errorName(err) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "every declaration decode error is driven by a refusal case" {
    const members = @typeInfo(DecodeError).error_set.?;
    inline for (members) |member| {
        var driven = false;
        for (cases) |case| {
            if (std.mem.eql(u8, @errorName(case.expected), member.name)) driven = true;
        }
        if (!driven) {
            std.debug.print("DecodeError.{s} has no refusal case\n", .{member.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "a declaration at every count and length bound decodes" {
    var buf: [65536]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_classifications);
    const long_name = "n" ** max_source_name_bytes;
    const long_reason = "r" ** max_reason_bytes;
    var index: u16 = 0;
    while (index < max_classifications) : (index += 1) {
        const path: [3]u8 = .{ 'p', 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        // The first entry carries the longest reason, the last the longest
        // source name, which also sorts after every other name.
        const last = index == max_classifications - 1;
        test_support.writeClassification(&w, .{
            .source_name = if (last) long_name else "api.example.com",
            .path = &path,
            .reason = if (index == 0) long_reason else "r",
        });
    }
    w.int(u8, 1);
    w.int(u8, 2);
    w.int(u16, max_exclude);
    index = 0;
    while (index < max_exclude) : (index += 1) {
        var entry: [max_exclude_bytes]u8 = undefined;
        @memset(&entry, 'a');
        @memcpy(entry[0..exclude_prefix.len], exclude_prefix);
        entry[entry.len - 2] = 'a' + @as(u8, @intCast(index / 26));
        entry[entry.len - 1] = 'a' + @as(u8, @intCast(index % 26));
        w.string(&entry);
    }
    const decl = try decode(w.bytes());
    try testing.expectEqual(max_classifications, decl.classification_count);
    try testing.expectEqual(max_exclude, (decl.ceiling orelse return error.TestMissingCeiling).exclude_count);

    // The longest path the layout admits: 16 segments of 64 bytes and 15 dots.
    var path_buf: [max_path_bytes]u8 = undefined;
    var p: usize = 0;
    for (0..max_path_segments) |seg| {
        if (seg != 0) {
            path_buf[p] = '.';
            p += 1;
        }
        @memset(path_buf[p..][0..max_segment_bytes], 'x');
        p += max_segment_bytes;
    }
    var w2 = test_support.Writer{ .buf = &buf };
    test_support.writeDeclaration(&w2, &.{.{ .path = path_buf[0..p] }}, null);
    _ = try decode(w2.bytes());
}
