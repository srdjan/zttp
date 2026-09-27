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
const wire = @import("wire.zig");

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
        @setRuntimeSafety(true);
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
        @setRuntimeSafety(true);
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
        @setRuntimeSafety(true);
        return .{ .bytes = self.bytes, .pos = header_size, .remaining = self.classification_count };
    }
};

const Reader = wire.Reader;

pub const ClassificationIterator = wire.Iterator(Classification, DecodeError, readClassification);
pub const ExcludeIterator = wire.Iterator([]const u8, DecodeError, readExclude);

fn readExclude(reader: *Reader) DecodeError![]const u8 {
    @setRuntimeSafety(true);
    return reader.string(u32, min_exclude_bytes, max_exclude_bytes, error.ExcludeInvalid);
}

/// Read one classification with every field rule applied.
fn readClassification(reader: *Reader) DecodeError!Classification {
    @setRuntimeSafety(true);
    const kind_byte = try reader.int(u8);
    if (kind_byte > 1) return error.SourceKindInvalid;
    const source_name = try reader.string(u32, 1, max_source_name_bytes, error.SourceNameLength);
    const path = try reader.string(u32, 1, max_path_bytes, error.PathInvalid);
    try validPath(path);
    const label_byte = try reader.int(u8);
    if (label_byte > 1) return error.LabelInvalid;
    const required_byte = try reader.int(u8);
    if (required_byte > 1) return error.RequiredInvalid;
    const reason = try reader.string(u32, 1, max_reason_bytes, error.ReasonLength);
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
    @setRuntimeSafety(true);
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
    @setRuntimeSafety(true);
    if (!std.mem.startsWith(u8, entry, exclude_prefix)) return error.ExcludeInvalid;
    for (entry) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '_' or c == ':' or c == '-';
        if (!ok) return error.ExcludeInvalid;
    }
}

/// Decode and validate canonical declaration bytes.
pub fn decode(bytes: []const u8) DecodeError!Declaration {
    @setRuntimeSafety(true);
    var reader = try wire.header(bytes, magic, schema_version);
    const count = try reader.int(u16);
    if (count > max_classifications) return error.ClassificationCountOutOfRange;

    var classes = ClassificationIterator{ .bytes = bytes, .pos = reader.pos, .remaining = count };
    var class_order = wire.Ascending(Classification, Classification.order){};
    while (try classes.next()) |item| {
        if (class_order.step(item) != .lt) return error.ClassificationsNotOrdered;
    }
    reader.pos = classes.pos;

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
        var entries = wire.Ascending([]const u8, wire.bytesOrder){};
        while (try it.next()) |entry| {
            try validExclude(entry);
            if (entries.step(entry) != .lt) return error.ExcludesNotOrdered;
        }
        reader.pos = it.pos;
        ceiling = .{
            .profile = @enumFromInt(profile_byte),
            .exclude_count = exclude_count,
            .exclude_bytes = bytes[0..reader.pos],
            .exclude_pos = exclude_pos,
        };
    }
    if (!reader.atEnd()) return error.TrailingData;
    if (count == 0 and ceiling == null) return error.DeclarationEmpty;

    return .{ .bytes = bytes, .classification_count = count, .ceiling = ceiling };
}

/// Domain-separated SHA-256 over the whole encoding. The digest a graph member
/// carries for these bytes.
pub fn digest(bytes: []const u8) [32]u8 {
    @setRuntimeSafety(true);
    return wire.domainDigest(digest_domain, bytes);
}

// ---------------------------------------------------------------------------
// Test support
// ---------------------------------------------------------------------------

/// A writer for building declarations in tests, over a fixed buffer. It writes
/// what it is told, valid or not, so a test can build each refusal directly.
pub const test_support = struct {
    pub const Writer = wire.Writer;

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
        @setRuntimeSafety(true);
        w.int(u8, item.source_kind);
        w.string(item.source_name);
        w.string(item.path);
        w.int(u8, item.label);
        w.int(u8, item.required);
        w.string(item.reason);
    }

    pub fn writeDeclaration(w: *Writer, items: []const SampleClassification, ceiling: ?SampleCeiling) void {
        @setRuntimeSafety(true);
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
        @setRuntimeSafety(true);
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

test "classification order compares source kind before source name" {
    const classifications = [_]test_support.SampleClassification{
        .{ .source_kind = 0, .source_name = "z.example", .path = "a" },
        .{ .source_kind = 1, .source_name = "a-service", .path = "a" },
    };
    var buf: [512]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeDeclaration(&w, &classifications, null);

    const declaration = try decode(w.bytes());
    try testing.expectEqual(@as(u16, 2), declaration.classification_count);
    var it = declaration.classifications();
    const fetch = (try it.next()).?;
    try testing.expectEqual(SourceKind.fetch, fetch.source_kind);
    try testing.expectEqualStrings("z.example", fetch.source_name);
    const service = (try it.next()).?;
    try testing.expectEqual(SourceKind.service, service.source_kind);
    try testing.expectEqualStrings("a-service", service.source_name);
    try testing.expectEqual(@as(?Classification, null), try it.next());
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

const DecodeSite = enum {
    short_header,
    integer_body,
    string_body,
    magic,
    schema,
    classification_count,
    source_kind,
    source_name_length,
    path_length,
    path_segment_count,
    path_segment_empty,
    path_segment_length,
    path_first_character,
    path_character,
    label,
    required,
    reason_length,
    source_name_utf8,
    reason_utf8,
    classification_order,
    ceiling_flag,
    profile,
    exclude_count,
    exclude_length,
    exclude_prefix,
    exclude_character,
    exclude_order,
    trailing_data,
    empty_declaration,
};

const Case = struct {
    site: DecodeSite,
    expected: DecodeError,
    classifications: []const test_support.SampleClassification = &.{},
    ceiling: ?test_support.SampleCeiling = test_support.SampleCeiling{},
    /// When set, the case is written by hand instead of from the fields above.
    custom: ?*const fn (w: *test_support.Writer) void = null,
};

fn truncatedInteger(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
}

fn truncatedString(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, 0);
    w.int(u32, 1);
}

fn sampleWithTrailingByte(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    test_support.writeDeclaration(w, &test_support.sample_classifications, test_support.sample_ceiling);
    w.raw(&.{0});
}

fn sampleTruncated(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    test_support.writeDeclaration(w, &test_support.sample_classifications, test_support.sample_ceiling);
    w.len -= 1;
}

fn shortMagic(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw("ZTDCL");
}

fn badMagic(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw("ZTDCL2\x00\x00");
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 0);
}

fn unsupportedSchema(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, 2);
    w.int(u16, 0);
    w.int(u8, 0);
}

fn tooManyClassifications(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_classifications + 1);
}

/// A classification whose fields before `field` are valid and whose string
/// field `field` claims `len` bytes without carrying them. The length bound
/// fires before the body is required. Fields: 0 source_name, 1 path, 2 reason.
fn claimLength(w: *test_support.Writer, field: usize, len: u32) void {
    @setRuntimeSafety(true);
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
    @setRuntimeSafety(true);
    claimLength(w, 0, max_source_name_bytes + 1);
}

fn pathTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    claimLength(w, 1, max_path_bytes + 1);
}

fn reasonTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    claimLength(w, 2, max_reason_bytes + 1);
}

fn tooManyExcludes(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
    w.int(u8, 1);
    w.int(u8, 0);
    w.int(u16, max_exclude + 1);
}

fn excludeTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
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
    .{ .site = .string_body, .expected = error.Truncated, .custom = sampleTruncated },
    .{ .site = .short_header, .expected = error.Truncated, .custom = shortMagic },
    .{ .site = .integer_body, .expected = error.Truncated, .custom = truncatedInteger },
    .{ .site = .string_body, .expected = error.Truncated, .custom = truncatedString },
    .{ .site = .magic, .expected = error.BadMagic, .custom = badMagic },
    .{ .site = .schema, .expected = error.UnsupportedSchema, .custom = unsupportedSchema },
    .{ .site = .classification_count, .expected = error.ClassificationCountOutOfRange, .custom = tooManyClassifications },
    .{ .site = .source_kind, .expected = error.SourceKindInvalid, .classifications = &.{.{ .path = "a", .source_kind = 2 }} },
    .{ .site = .source_name_length, .expected = error.SourceNameLength, .classifications = &.{.{ .path = "a", .source_name = "" }} },
    .{ .site = .source_name_length, .expected = error.SourceNameLength, .custom = sourceNameTooLong },
    .{ .site = .path_length, .expected = error.PathInvalid, .classifications = &.{.{ .path = "" }} },
    .{ .site = .path_length, .expected = error.PathInvalid, .custom = pathTooLong },
    .{ .site = .path_segment_empty, .expected = error.PathInvalid, .classifications = &.{.{ .path = "a..b" }} },
    .{ .site = .path_segment_empty, .expected = error.PathInvalid, .classifications = &.{.{ .path = "a." }} },
    .{ .site = .path_first_character, .expected = error.PathInvalid, .classifications = &.{.{ .path = "1a" }} },
    .{ .site = .path_character, .expected = error.PathInvalid, .classifications = &.{.{ .path = "a.b-c" }} },
    .{ .site = .path_segment_length, .expected = error.PathInvalid, .classifications = &.{.{ .path = segment_65 }} },
    .{ .site = .path_segment_count, .expected = error.PathInvalid, .classifications = &.{.{ .path = path_17 }} },
    .{ .site = .label, .expected = error.LabelInvalid, .classifications = &.{.{ .path = "a", .label = 2 }} },
    .{ .site = .required, .expected = error.RequiredInvalid, .classifications = &.{.{ .path = "a", .required = 2 }} },
    .{ .site = .reason_length, .expected = error.ReasonLength, .classifications = &.{.{ .path = "a", .reason = "" }} },
    .{ .site = .reason_length, .expected = error.ReasonLength, .custom = reasonTooLong },
    .{ .site = .reason_utf8, .expected = error.InvalidUtf8, .classifications = &.{.{ .path = "a", .reason = "\xff" }} },
    .{ .site = .source_name_utf8, .expected = error.InvalidUtf8, .classifications = &.{.{ .path = "a", .source_name = "a\xc3" }} },
    // Out of order by kind, by name, and by path; then a repeat.
    .{ .site = .classification_order, .expected = error.ClassificationsNotOrdered, .classifications = &.{ s[1], s[0] } },
    .{ .site = .classification_order, .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "a", .source_name = "b.example" }, .{ .path = "a", .source_name = "a.example" } } },
    .{ .site = .classification_order, .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "b" }, .{ .path = "a" } } },
    .{ .site = .classification_order, .expected = error.ClassificationsNotOrdered, .classifications = &.{ .{ .path = "a" }, .{ .path = "a", .label = 1 } } },
    .{ .site = .ceiling_flag, .expected = error.CeilingFlagInvalid, .custom = ceilingFlagTwo },
    .{ .site = .profile, .expected = error.ProfileInvalid, .ceiling = .{ .profile = 3 } },
    .{ .site = .exclude_count, .expected = error.ExcludeCountOutOfRange, .custom = tooManyExcludes },
    .{ .site = .exclude_length, .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp"} } },
    .{ .site = .exclude_prefix, .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp-e:x"} } },
    .{ .site = .exclude_character, .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp:A"} } },
    .{ .site = .exclude_character, .expected = error.ExcludeInvalid, .ceiling = .{ .exclude = &.{"zttp:a/b"} } },
    .{ .site = .exclude_length, .expected = error.ExcludeInvalid, .custom = excludeTooLong },
    .{ .site = .exclude_order, .expected = error.ExcludesNotOrdered, .ceiling = .{ .exclude = &.{ "zttp:sql", "zttp:fetch" } } },
    .{ .site = .exclude_order, .expected = error.ExcludesNotOrdered, .ceiling = .{ .exclude = &.{ "zttp:fetch", "zttp:fetch" } } },
    .{ .site = .empty_declaration, .expected = error.DeclarationEmpty, .ceiling = null },
    .{ .site = .trailing_data, .expected = error.TrailingData, .custom = sampleWithTrailingByte },
};

fn ceilingFlagTwo(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
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

test "every declaration decode site and error is driven by a refusal case" {
    const sites = @typeInfo(DecodeSite).@"enum".fields;
    inline for (sites) |site_field| {
        const site: DecodeSite = @enumFromInt(site_field.value);
        var driven = false;
        for (cases) |case| {
            if (case.site == site) driven = true;
        }
        if (!driven) {
            std.debug.print("DecodeSite.{s} has no refusal case\n", .{site_field.name});
            return error.TestUnexpectedResult;
        }
    }

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
