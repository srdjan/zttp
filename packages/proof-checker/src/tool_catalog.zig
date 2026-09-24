//! The canonical tool catalog, `ZTCAT1`.
//!
//! A tool-profile handler ships its catalog as canonical bytes, and the
//! executable graph commits to them as member `tool_catalog`. The kernel decodes
//! the bytes itself, recomputes their domain-separated digest, and compares it
//! with the member. The decoder is zero-copy and allocation-free: every slice it
//! returns points into the bytes the caller holds.
//!
//! The kernel does not check that a schema is inside the supported subset. That
//! needs an allocating parser; the runtime compiles every schema from the
//! accepted bytes and refuses to start when one does not compile.
//!
//! Layout (integers little-endian, strings u32-length-prefixed UTF-8):
//!
//! ```text
//! magic            8 bytes  "ZTCAT1\0\0"
//! schema           u16      2
//! entry_count      u16      1..64
//! entry, entry_count times, strictly increasing by name bytes:
//!   name             string  1..64
//!   method           string  1..16, uppercase ASCII A-Z
//!   path             string  1..512, starts with "/"
//!   description      string  1..4096
//!   input_name       string  1..64
//!   input_schema     string  1..65536
//!   output_name      string  1..64
//!   output_schema    string  1..65536
//!   max_input_bytes  u32     1..1048576
//!   scope_tenant     string  0, or 1..64: the input field bound to the tenant
//!   scope_subject    string  0, or 1..64: the input field bound to the subject
//!   export_count     u16     0..256
//!   export, export_count times, strictly increasing by (module, name):
//!     module           string  1..64
//!     name             string  1..64
//!   credential_count u16     0..64
//!   credential, credential_count times, strictly increasing by bytes:
//!     name             string  1..64: a credential the tool may use
//! trailing bytes: refused
//! ```
//!
//! No two entries share a (method, path) route. A scope field of length 0 is
//! absent; it is the only string in the layout that may be empty. The kernel
//! checks a scope field's length and encoding only: that it names a required
//! string property of the input schema is a build rule, and the runtime finds
//! the field in the compiled schema it validates with.
//!
//! Schema 2 (M4 T5) added the two scope fields. Schema 3 (M4 T6) added the
//! credential names: the tool's credential grant, which the runtime checks
//! before it injects a credential. The kernel checks their lengths, encoding,
//! and order; that each names a reference the project defines is a build
//! rule. Schemas 1 and 2 are refused: no artifact carrying them exists
//! outside tests.

const std = @import("std");

pub const magic = "ZTCAT1\x00\x00";
pub const schema_version: u16 = 3;
pub const header_size: usize = magic.len + 2 + 2;

pub const digest_domain = "zttp-tool-catalog-v1";

pub const min_entries: u16 = 1;
pub const max_entries: u16 = 64;
pub const max_name_bytes: u32 = 64;
pub const max_method_bytes: u32 = 16;
pub const max_path_bytes: u32 = 512;
pub const max_description_bytes: u32 = 4096;
pub const max_schema_name_bytes: u32 = 64;
pub const max_schema_bytes: u32 = 65536;
pub const min_max_input_bytes: u32 = 1;
pub const max_max_input_bytes: u32 = 1048576;
pub const max_scope_field_bytes: u32 = 64;
pub const max_exports: u16 = 256;
pub const max_export_field_bytes: u32 = 64;
pub const max_credentials: u16 = 64;
pub const max_credential_name_bytes: u32 = 64;

/// Every refusal the decoder can report. Closed, and each member names one
/// distinct defect so a diagnostic can say which rule the bytes broke.
pub const DecodeError = error{
    Truncated,
    BadMagic,
    UnsupportedSchema,
    EntryCountOutOfRange,
    NameLength,
    MethodInvalid,
    PathInvalid,
    DescriptionLength,
    SchemaNameLength,
    SchemaLength,
    MaxInputBytesOutOfRange,
    /// A scope field longer than `max_scope_field_bytes`.
    ScopeFieldLength,
    ExportCountOutOfRange,
    ExportFieldLength,
    /// Names must be strictly increasing by byte order, which also refuses a
    /// duplicate name.
    NamesNotOrdered,
    /// Two entries name the same method and path.
    RouteDuplicate,
    /// Exports must be strictly increasing by (module, name), which also
    /// refuses a duplicate export.
    ExportsNotOrdered,
    CredentialCountOutOfRange,
    CredentialNameLength,
    /// Credential names must be strictly increasing by byte order, which also
    /// refuses a duplicate.
    CredentialsNotOrdered,
    InvalidUtf8,
    TrailingData,
};

pub const Export = struct {
    module: []const u8,
    name: []const u8,

    pub fn order(a: Export, b: Export) std.math.Order {
        const by_module = std.mem.order(u8, a.module, b.module);
        if (by_module != .eq) return by_module;
        return std.mem.order(u8, a.name, b.name);
    }
};

pub const Entry = struct {
    name: []const u8,
    method: []const u8,
    path: []const u8,
    description: []const u8,
    input_name: []const u8,
    input_schema: []const u8,
    output_name: []const u8,
    output_schema: []const u8,
    max_input_bytes: u32,
    /// The input field bound to the verified tenant, or null.
    scope_tenant: ?[]const u8,
    /// The input field bound to the verified subject, or null.
    scope_subject: ?[]const u8,
    exports: ExportIterator,
    /// The credential names the tool may use (schema 3).
    credentials: NameIterator,
};

/// A decoded catalog. Only `decode` builds one, so the bytes it holds have
/// passed every rule above.
pub const Catalog = struct {
    bytes: []const u8,
    entry_count: u16,

    pub fn entries(self: Catalog) EntryIterator {
        return .{ .bytes = self.bytes, .pos = header_size, .remaining = self.entry_count };
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

    /// A length-prefixed string where length 0 means absent.
    fn optionalString(self: *Reader, max: u32, length_error: DecodeError) DecodeError!?[]const u8 {
        const out = try self.string(0, max, length_error);
        return if (out.len == 0) null else out;
    }
};

pub const ExportIterator = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u16,

    pub fn next(self: *ExportIterator) DecodeError!?Export {
        if (self.remaining == 0) return null;
        var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
        const module = try reader.string(1, max_export_field_bytes, error.ExportFieldLength);
        const name = try reader.string(1, max_export_field_bytes, error.ExportFieldLength);
        self.pos = reader.pos;
        self.remaining -= 1;
        return .{ .module = module, .name = name };
    }
};

/// Length-prefixed names, one after another.
pub const NameIterator = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u16,

    pub fn next(self: *NameIterator) DecodeError!?[]const u8 {
        if (self.remaining == 0) return null;
        var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
        const name = try reader.string(1, max_credential_name_bytes, error.CredentialNameLength);
        self.pos = reader.pos;
        self.remaining -= 1;
        return name;
    }
};

pub const EntryIterator = struct {
    bytes: []const u8,
    pos: usize,
    remaining: u16,

    pub fn next(self: *EntryIterator) DecodeError!?Entry {
        if (self.remaining == 0) return null;
        var reader = Reader{ .bytes = self.bytes, .pos = self.pos };
        const entry = try readEntry(&reader);
        self.pos = reader.pos;
        self.remaining -= 1;
        return entry;
    }
};

/// Read one entry's fields with length bounds only, and step over its exports.
fn readEntry(reader: *Reader) DecodeError!Entry {
    const name = try reader.string(1, max_name_bytes, error.NameLength);
    const method = try reader.string(1, max_method_bytes, error.MethodInvalid);
    const path = try reader.string(1, max_path_bytes, error.PathInvalid);
    const description = try reader.string(1, max_description_bytes, error.DescriptionLength);
    const input_name = try reader.string(1, max_schema_name_bytes, error.SchemaNameLength);
    const input_schema = try reader.string(1, max_schema_bytes, error.SchemaLength);
    const output_name = try reader.string(1, max_schema_name_bytes, error.SchemaNameLength);
    const output_schema = try reader.string(1, max_schema_bytes, error.SchemaLength);
    const max_input_bytes = try reader.int(u32);
    if (max_input_bytes < min_max_input_bytes or max_input_bytes > max_max_input_bytes) {
        return error.MaxInputBytesOutOfRange;
    }
    const scope_tenant = try reader.optionalString(max_scope_field_bytes, error.ScopeFieldLength);
    const scope_subject = try reader.optionalString(max_scope_field_bytes, error.ScopeFieldLength);
    const export_count = try reader.int(u16);
    if (export_count > max_exports) return error.ExportCountOutOfRange;

    var exports = ExportIterator{ .bytes = reader.bytes, .pos = reader.pos, .remaining = export_count };
    var walk = exports;
    while (try walk.next()) |_| {}
    reader.pos = walk.pos;
    exports.bytes = reader.bytes[0..reader.pos];

    const credential_count = try reader.int(u16);
    if (credential_count > max_credentials) return error.CredentialCountOutOfRange;
    var credentials = NameIterator{ .bytes = reader.bytes, .pos = reader.pos, .remaining = credential_count };
    var credential_walk = credentials;
    while (try credential_walk.next()) |_| {}
    reader.pos = credential_walk.pos;
    credentials.bytes = reader.bytes[0..reader.pos];

    return .{
        .name = name,
        .method = method,
        .path = path,
        .description = description,
        .input_name = input_name,
        .input_schema = input_schema,
        .output_name = output_name,
        .output_schema = output_schema,
        .max_input_bytes = max_input_bytes,
        .scope_tenant = scope_tenant,
        .scope_subject = scope_subject,
        .exports = exports,
        .credentials = credentials,
    };
}

fn validUtf8(bytes: []const u8) DecodeError!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
}

fn validateEntry(entry: Entry) DecodeError!void {
    for (entry.method) |byte| {
        if (byte < 'A' or byte > 'Z') return error.MethodInvalid;
    }
    if (entry.path[0] != '/') return error.PathInvalid;

    try validUtf8(entry.name);
    try validUtf8(entry.path);
    try validUtf8(entry.description);
    try validUtf8(entry.input_name);
    try validUtf8(entry.input_schema);
    try validUtf8(entry.output_name);
    try validUtf8(entry.output_schema);
    if (entry.scope_tenant) |field| try validUtf8(field);
    if (entry.scope_subject) |field| try validUtf8(field);

    var exports = entry.exports;
    var previous: ?Export = null;
    while (try exports.next()) |item| {
        try validUtf8(item.module);
        try validUtf8(item.name);
        if (previous) |prev| {
            if (Export.order(prev, item) != .lt) return error.ExportsNotOrdered;
        }
        previous = item;
    }

    var credentials = entry.credentials;
    var previous_credential: ?[]const u8 = null;
    while (try credentials.next()) |name| {
        try validUtf8(name);
        if (previous_credential) |prev| {
            if (std.mem.order(u8, prev, name) != .lt) return error.CredentialsNotOrdered;
        }
        previous_credential = name;
    }
}

/// Decode and validate canonical catalog bytes.
pub fn decode(bytes: []const u8) DecodeError!Catalog {
    if (bytes.len < magic.len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    var reader = Reader{ .bytes = bytes, .pos = magic.len };
    if (try reader.int(u16) != schema_version) return error.UnsupportedSchema;
    const entry_count = try reader.int(u16);
    if (entry_count < min_entries or entry_count > max_entries) return error.EntryCountOutOfRange;

    var previous_name: ?[]const u8 = null;
    var index: u16 = 0;
    while (index < entry_count) : (index += 1) {
        const entry = try readEntry(&reader);
        try validateEntry(entry);
        if (previous_name) |prev| {
            if (std.mem.order(u8, prev, entry.name) != .lt) return error.NamesNotOrdered;
        }
        previous_name = entry.name;
    }
    if (reader.pos != bytes.len) return error.TrailingData;

    const catalog = Catalog{ .bytes = bytes, .entry_count = entry_count };

    // Routes: at most 64 entries, so a pairwise scan bounds the work without a
    // table. Every read below is over bytes the loop above already accepted.
    var outer = catalog.entries();
    var outer_index: u16 = 0;
    while (try outer.next()) |a| : (outer_index += 1) {
        var inner = catalog.entries();
        var inner_index: u16 = 0;
        while (inner_index <= outer_index) : (inner_index += 1) _ = try inner.next();
        while (try inner.next()) |b| {
            if (std.mem.eql(u8, a.method, b.method) and std.mem.eql(u8, a.path, b.path)) {
                return error.RouteDuplicate;
            }
        }
    }
    return catalog;
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

/// A writer for building catalogs in tests, over a fixed buffer. It writes what
/// it is told, valid or not, so a test can build each refusal directly.
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

    pub const SampleExport = struct { module: []const u8, name: []const u8 };

    pub const SampleEntry = struct {
        name: []const u8,
        method: []const u8 = "POST",
        path: []const u8,
        description: []const u8 = "Echo the input text.",
        input_name: []const u8 = "EchoInput",
        input_schema: []const u8 = "{\"type\":\"object\"}",
        output_name: []const u8 = "EchoOutput",
        output_schema: []const u8 = "{\"type\":\"object\"}",
        max_input_bytes: u32 = 4096,
        scope_tenant: ?[]const u8 = null,
        scope_subject: ?[]const u8 = null,
        exports: []const SampleExport = &.{},
        credentials: []const []const u8 = &.{},
    };

    pub fn writeEntry(w: *Writer, entry: SampleEntry) void {
        w.string(entry.name);
        w.string(entry.method);
        w.string(entry.path);
        w.string(entry.description);
        w.string(entry.input_name);
        w.string(entry.input_schema);
        w.string(entry.output_name);
        w.string(entry.output_schema);
        w.int(u32, entry.max_input_bytes);
        w.string(entry.scope_tenant orelse "");
        w.string(entry.scope_subject orelse "");
        w.int(u16, @intCast(entry.exports.len));
        for (entry.exports) |item| {
            w.string(item.module);
            w.string(item.name);
        }
        w.int(u16, @intCast(entry.credentials.len));
        for (entry.credentials) |name| w.string(name);
    }

    pub fn writeCatalog(w: *Writer, entries: []const SampleEntry) void {
        w.raw(magic);
        w.int(u16, schema_version);
        w.int(u16, @intCast(entries.len));
        for (entries) |entry| writeEntry(w, entry);
    }

    pub const sample_entries = [_]SampleEntry{
        .{
            .name = "echo",
            .path = "/tools/echo",
            .exports = &.{
                .{ .module = "zttp:json", .name = "parse" },
                .{ .module = "zttp:result", .name = "ok" },
            },
        },
        .{
            .name = "lookup",
            .method = "GET",
            .path = "/tools/lookup",
            .description = "Look up one record.",
            .input_name = "LookupInput",
            .input_schema = "{\"type\":\"string\"}",
            .output_name = "LookupOutput",
            .output_schema = "{\"type\":\"number\"}",
            .max_input_bytes = 1048576,
            .scope_tenant = "tenant_id",
            .credentials = &.{ "billing", "weather" },
        },
    };

    /// The two-entry sample catalog, written into `buf`.
    pub fn sample(buf: []u8) []const u8 {
        var w = Writer{ .buf = buf };
        writeCatalog(&w, &sample_entries);
        return w.bytes();
    }
};

const testing = std.testing;

test "a valid two-entry catalog decodes and iterates every field" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const catalog = try decode(bytes);
    try testing.expectEqual(@as(u16, 2), catalog.entry_count);

    var it = catalog.entries();
    const echo = (try it.next()).?;
    try testing.expectEqualStrings("echo", echo.name);
    try testing.expectEqualStrings("POST", echo.method);
    try testing.expectEqualStrings("/tools/echo", echo.path);
    try testing.expectEqualStrings("Echo the input text.", echo.description);
    try testing.expectEqualStrings("EchoInput", echo.input_name);
    try testing.expectEqualStrings("{\"type\":\"object\"}", echo.input_schema);
    try testing.expectEqualStrings("EchoOutput", echo.output_name);
    try testing.expectEqualStrings("{\"type\":\"object\"}", echo.output_schema);
    try testing.expectEqual(@as(u32, 4096), echo.max_input_bytes);
    try testing.expectEqual(@as(?[]const u8, null), echo.scope_tenant);
    try testing.expectEqual(@as(?[]const u8, null), echo.scope_subject);
    var exports = echo.exports;
    const first = (try exports.next()).?;
    try testing.expectEqualStrings("zttp:json", first.module);
    try testing.expectEqualStrings("parse", first.name);
    const second = (try exports.next()).?;
    try testing.expectEqualStrings("zttp:result", second.module);
    try testing.expectEqualStrings("ok", second.name);
    try testing.expectEqual(@as(?Export, null), try exports.next());

    const lookup = (try it.next()).?;
    try testing.expectEqualStrings("lookup", lookup.name);
    try testing.expectEqualStrings("GET", lookup.method);
    try testing.expectEqualStrings("/tools/lookup", lookup.path);
    try testing.expectEqualStrings("Look up one record.", lookup.description);
    try testing.expectEqualStrings("LookupInput", lookup.input_name);
    try testing.expectEqualStrings("{\"type\":\"string\"}", lookup.input_schema);
    try testing.expectEqualStrings("LookupOutput", lookup.output_name);
    try testing.expectEqualStrings("{\"type\":\"number\"}", lookup.output_schema);
    try testing.expectEqual(@as(u32, 1048576), lookup.max_input_bytes);
    try testing.expectEqualStrings("tenant_id", lookup.scope_tenant orelse return error.TestMissingScope);
    try testing.expectEqual(@as(?[]const u8, null), lookup.scope_subject);
    var no_exports = lookup.exports;
    try testing.expectEqual(@as(?Export, null), try no_exports.next());
    var lookup_credentials = lookup.credentials;
    try testing.expectEqualStrings("billing", (try lookup_credentials.next()).?);
    try testing.expectEqualStrings("weather", (try lookup_credentials.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try lookup_credentials.next());
    var echo_credentials = echo.credentials;
    try testing.expectEqual(@as(?[]const u8, null), try echo_credentials.next());

    try testing.expectEqual(@as(?Entry, null), try it.next());

    // Zero-copy: every slice points into the input.
    const base = @intFromPtr(bytes.ptr);
    try testing.expect(@intFromPtr(echo.name.ptr) >= base);
    try testing.expect(@intFromPtr(lookup.output_schema.ptr) + lookup.output_schema.len <= base + bytes.len);
}

test "the catalog digest is stable and domain-separated" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const a = digest(bytes);
    const b = digest(bytes);
    try testing.expectEqualSlices(u8, &a, &b);

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
    entries: []const test_support.SampleEntry = &.{},
    /// When set, the case is written by hand instead of from `entries`.
    custom: ?*const fn (w: *test_support.Writer) void = null,
};

fn sampleWithTrailingByte(w: *test_support.Writer) void {
    test_support.writeCatalog(w, &test_support.sample_entries);
    w.raw(&.{0});
}

fn sampleTruncated(w: *test_support.Writer) void {
    test_support.writeCatalog(w, &test_support.sample_entries);
    w.len -= 1;
}

fn badMagic(w: *test_support.Writer) void {
    w.raw("ZTCAT2\x00\x00");
    w.int(u16, schema_version);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// Schema 1, the layout before the scope fields, is refused outright.
fn unsupportedSchema(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, 1);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// Schema 2, the layout before the credential names, is refused too.
fn schemaTwo(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, 2);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// An entry with no exports that claims one credential more than the bound.
fn tooManyCredentials(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.string("");
    w.int(u16, 0);
    w.int(u16, max_credentials + 1);
}

const credential_65 = "c" ** (max_credential_name_bytes + 1);

fn zeroEntries(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
}

fn tooManyEntries(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_entries + 1);
}

/// An entry whose fields up to `field` are valid and whose field `field` claims
/// `len` bytes without carrying them. The length bound fires before the body is
/// required.
fn claimLength(w: *test_support.Writer, field: usize, len: u32) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields[0..field]) |value| w.string(value);
    w.int(u32, len);
}

fn descriptionTooLong(w: *test_support.Writer) void {
    claimLength(w, 3, max_description_bytes + 1);
}

fn schemaTooLong(w: *test_support.Writer) void {
    claimLength(w, 5, max_schema_bytes + 1);
}

fn nameTooLong(w: *test_support.Writer) void {
    claimLength(w, 0, max_name_bytes + 1);
}

fn tooManyExports(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.string("");
    w.int(u16, max_exports + 1);
}

/// A scope field that claims one byte more than the bound, without carrying
/// it. The length bound fires before the body is required.
fn scopeTooLong(w: *test_support.Writer) void {
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.int(u32, max_scope_field_bytes + 1);
}

const scope_65 = "s" ** (max_scope_field_bytes + 1);
const scope_64 = "s" ** max_scope_field_bytes;

const e = test_support.sample_entries;

const cases = [_]Case{
    .{ .expected = error.Truncated, .custom = sampleTruncated },
    .{ .expected = error.BadMagic, .custom = badMagic },
    .{ .expected = error.UnsupportedSchema, .custom = unsupportedSchema },
    .{ .expected = error.UnsupportedSchema, .custom = schemaTwo },
    .{ .expected = error.EntryCountOutOfRange, .custom = zeroEntries },
    .{ .expected = error.EntryCountOutOfRange, .custom = tooManyEntries },
    .{ .expected = error.NameLength, .entries = &.{.{ .name = "", .path = "/x" }} },
    .{ .expected = error.NameLength, .custom = nameTooLong },
    .{ .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "get", .path = "/x" }} },
    .{ .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "", .path = "/x" }} },
    .{ .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "POSTPOSTPOSTPOSTX", .path = "/x" }} },
    .{ .expected = error.PathInvalid, .entries = &.{.{ .name = "a", .path = "x" }} },
    .{ .expected = error.PathInvalid, .entries = &.{.{ .name = "a", .path = "" }} },
    .{ .expected = error.DescriptionLength, .entries = &.{.{ .name = "a", .path = "/x", .description = "" }} },
    .{ .expected = error.DescriptionLength, .custom = descriptionTooLong },
    .{ .expected = error.SchemaNameLength, .entries = &.{.{ .name = "a", .path = "/x", .input_name = "" }} },
    .{ .expected = error.SchemaNameLength, .entries = &.{.{ .name = "a", .path = "/x", .output_name = "" }} },
    .{ .expected = error.SchemaLength, .entries = &.{.{ .name = "a", .path = "/x", .input_schema = "" }} },
    .{ .expected = error.SchemaLength, .entries = &.{.{ .name = "a", .path = "/x", .output_schema = "" }} },
    .{ .expected = error.SchemaLength, .custom = schemaTooLong },
    .{ .expected = error.MaxInputBytesOutOfRange, .entries = &.{.{ .name = "a", .path = "/x", .max_input_bytes = 0 }} },
    .{ .expected = error.MaxInputBytesOutOfRange, .entries = &.{.{ .name = "a", .path = "/x", .max_input_bytes = max_max_input_bytes + 1 }} },
    .{ .expected = error.ScopeFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .scope_tenant = scope_65 }} },
    .{ .expected = error.ScopeFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .scope_subject = scope_65 }} },
    .{ .expected = error.ScopeFieldLength, .custom = scopeTooLong },
    .{ .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .scope_subject = "\xff" }} },
    .{ .expected = error.ExportCountOutOfRange, .custom = tooManyExports },
    .{ .expected = error.ExportFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "", .name = "f" }} }} },
    .{ .expected = error.ExportFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "m", .name = "" }} }} },
    .{ .expected = error.NamesNotOrdered, .entries = &.{ e[1], e[0] } },
    .{ .expected = error.NamesNotOrdered, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "a", .path = "/y" } } },
    .{ .expected = error.RouteDuplicate, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "b", .path = "/x" } } },
    .{ .expected = error.RouteDuplicate, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "b", .path = "/y" }, .{ .name = "c", .path = "/x" } } },
    .{ .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "m", .name = "g" }, .{ .module = "m", .name = "f" } } }} },
    .{ .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "n", .name = "a" }, .{ .module = "m", .name = "z" } } }} },
    .{ .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "m", .name = "f" }, .{ .module = "m", .name = "f" } } }} },
    .{ .expected = error.CredentialCountOutOfRange, .custom = tooManyCredentials },
    .{ .expected = error.CredentialNameLength, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{""} }} },
    .{ .expected = error.CredentialNameLength, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{credential_65} }} },
    .{ .expected = error.CredentialsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{ "weather", "billing" } }} },
    .{ .expected = error.CredentialsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{ "weather", "weather" } }} },
    .{ .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{"\xfe"} }} },
    .{ .expected = error.InvalidUtf8, .entries = &.{.{ .name = "\xff", .path = "/x" }} },
    .{ .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .input_schema = "{\"\xc3\"}" }} },
    .{ .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "m", .name = "\x80" }} }} },
    .{ .expected = error.TrailingData, .custom = sampleWithTrailingByte },
};

test "every refusal case decodes to its exact error" {
    for (cases, 0..) |case, index| {
        var buf: [2048]u8 = undefined;
        var w = test_support.Writer{ .buf = &buf };
        if (case.custom) |write| {
            write(&w);
        } else {
            test_support.writeCatalog(&w, case.entries);
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

test "every decode error is driven by a refusal case" {
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

test "a scope field at its bound decodes and carries both bindings" {
    var buf: [1024]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &.{.{ .name = "a", .path = "/x", .scope_tenant = scope_64, .scope_subject = "user_id" }});
    const catalog = try decode(w.bytes());
    var it = catalog.entries();
    const entry = (try it.next()).?;
    try testing.expectEqualStrings(scope_64, entry.scope_tenant orelse return error.TestMissingScope);
    try testing.expectEqualStrings("user_id", entry.scope_subject orelse return error.TestMissingScope);
}

test "a catalog at the entry and export bounds decodes" {
    var buf: [65536]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_entries);
    var index: u16 = 0;
    while (index < max_entries) : (index += 1) {
        const name: [2]u8 = .{ 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        const path: [3]u8 = .{ '/', name[0], name[1] };
        test_support.writeEntry(&w, .{ .name = &name, .path = &path });
    }
    const catalog = try decode(w.bytes());
    try testing.expectEqual(max_entries, catalog.entry_count);
}
