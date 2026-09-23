//! The consumer declaration: an authored JSON file that assigns a flow label to
//! a named member of a value an outside source returns (M4 T4), and, from
//! version 2, the capability ceiling the handler must stay inside (M4 T5b).
//!
//! Version 1 has one section, `classifications`. Each entry names a source, a
//! dot-separated path inside the value that source returns, the label that
//! member carries, whether the analysis must see it, and a reason:
//!
//! ```json
//! { "version": 1,
//!   "classifications": [
//!     { "source": "fetch:api.example.com", "path": "customer.tax_id",
//!       "label": "secret", "required": true, "reason": "Tax identifier." } ] }
//! ```
//!
//! Version 2 makes `classifications` optional and adds an optional `ceiling`.
//! The ceiling names one capability profile from `capability_profiles.zig` and
//! a list of modules to exclude beyond the ones the profile already excludes.
//! A version 2 document carries at least one of the two sections, and a
//! `classifications` list that is present is not empty:
//!
//! ```json
//! { "version": 2,
//!   "ceiling": { "profile": "boundary", "exclude": ["zttp:fetch"] } }
//! ```
//!
//! Version 1 documents stay valid and mean "no ceiling". A `ceiling` key in a
//! version 1 document is an unknown field.
//!
//! The loader is closed. Every field is mandatory and has no default, and a
//! document that breaks a rule is refused with exactly one member of `Refusal`
//! rather than with a Zig error, so a caller can name the rule. Allocation
//! failure is the only Zig error `parse` returns.
//!
//! The canonical form is the accepted `Declaration`: its classifications are
//! sorted by (source kind, source name bytes, path bytes), no two entries share
//! a source and a path, and the ceiling's exclude list is sorted by bytes. Two
//! documents that list the same entries in a different order therefore load to
//! the same value. `encodeCanonical` writes that value as `ZTDCL1` bytes, the
//! layout the acceptance kernel decodes in
//! `packages/proof-checker/src/declaration.zig`.
//!
//! This file is in the `zts-base` tier and imports `std` and
//! `capability_profiles.zig`, a file of the same tier. See
//! docs/plans/2026-09-23-m4-t4-declared-labels-design.md, sections 3 and 9, and
//! docs/plans/2026-09-23-m4-t5-scope-and-grants-design.md, sections 8 and 13.

const std = @import("std");
const capability_profiles = @import("capability_profiles.zig");

/// The largest document `parse` reads. Checked before parsing.
pub const max_document_bytes: usize = 65536;
/// The most classifications one document may carry.
pub const max_classifications: usize = 256;
/// The most segments one path may have.
pub const max_path_segments: usize = 16;
/// The most bytes one path segment may have.
pub const max_segment_bytes: usize = 64;
/// The most bytes a `fetch:` host may have.
pub const max_host_bytes: usize = 253;
/// The most bytes one host label may have.
pub const max_host_label_bytes: usize = 63;
/// The most bytes a `service:` name may have.
pub const max_service_name_bytes: usize = 64;
/// The most modules one ceiling may exclude.
pub const max_exclude: usize = 64;
/// The fewest bytes an excluded module specifier may have: `zttp:` and one
/// more byte.
pub const min_exclude_bytes: usize = 6;
/// The most bytes an excluded module specifier may have.
pub const max_exclude_bytes: usize = 64;
/// The most bytes a `reason` may have. `ZTDCL1` carries the same bound, so
/// the loader refuses a longer one as `reason_too_long`.
pub const max_reason_bytes: usize = 1024;

/// The labels a declaration may assign. Owner decision Q1: `secret` and
/// `credential` only. The other flow labels are refused as `label_unsupported`.
pub const Label = enum { secret, credential };

/// Which kind of outside source a classification names.
pub const SourceKind = enum { fetch, service };

pub const Classification = struct {
    source_kind: SourceKind,
    /// The host of a `fetch:` source or the name of a `service:` source,
    /// without the prefix.
    source_name: []const u8,
    /// The path as the author wrote it, for example `customer.tax_id`.
    path_text: []const u8,
    /// The segments of `path_text`. Each one is a slice of `path_text`.
    path: []const []const u8,
    label: Label,
    required: bool,
    reason: []const u8,
};

/// The capability ceiling a version 2 declaration selects.
pub const Ceiling = struct {
    /// A row of `capability_profiles.profiles`. Never owned.
    profile: *const capability_profiles.Profile,
    /// `zttp:` module specifiers excluded beyond the profile's own list,
    /// sorted by bytes and unique. Owned by the declaration's arena. May be
    /// empty.
    exclude: []const []const u8,
};

pub const Declaration = struct {
    /// Owns every string and slice below. The input bytes are not borrowed.
    arena: *std.heap.ArenaAllocator,
    /// Sorted by (source_kind, source_name bytes, path_text bytes). Empty only
    /// for a version 2 document that carries a ceiling and no classifications.
    classifications: []const Classification,
    /// Null for a version 1 document and for a version 2 document without a
    /// `ceiling` section.
    ceiling: ?Ceiling = null,

    pub fn deinit(self: *Declaration) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

/// Why a document is refused. One member per rule; the set is closed.
pub const Refusal = enum {
    /// The bytes are not one JSON value.
    invalid_json,
    /// An object, at any depth, has the same key twice.
    duplicate_key,
    /// An object, at any depth, has a key the schema does not name.
    unknown_field,
    /// A mandatory key is absent.
    missing_field,
    /// A value has the wrong JSON type, including `null`.
    wrong_type,
    /// `version` is a number other than the integer 1 or 2.
    unsupported_version,
    /// `classifications` is an empty array.
    classifications_empty,
    /// `classifications` has more than `max_classifications` entries.
    too_many_classifications,
    /// `source` is not `fetch:<host>` or `service:<name>`.
    source_invalid,
    /// `path` is not 1 to 16 dot-separated identifier segments.
    path_invalid,
    /// `label` is not `secret` or `credential`.
    label_unsupported,
    /// `reason` is empty or holds only whitespace.
    reason_empty,
    /// Two entries have the same source and the same path.
    duplicate_entry,
    /// The input is larger than `max_document_bytes`.
    document_too_large,
    /// `ceiling.profile` names no row of `capability_profiles.profiles`.
    ceiling_profile_unknown,
    /// `ceiling.exclude` has more than `max_exclude` entries, or an entry that
    /// is not a `zttp:` specifier of 6 to 64 bytes of `[a-z0-9_:-]`.
    ceiling_exclude_invalid,
    /// `ceiling.exclude` names the same module twice.
    ceiling_exclude_duplicate,
    /// A version 2 document has neither `classifications` nor `ceiling`.
    declaration_empty,
    /// `reason` is longer than `max_reason_bytes`, the bound `ZTDCL1` carries.
    /// Refused here so that every accepted document encodes.
    reason_too_long,
};

pub const ParseResult = union(enum) {
    ok: Declaration,
    refused: struct {
        reason: Refusal,
        /// The zero-based classification index when the refusal is about one
        /// entry. For `duplicate_entry` it is the later of the two entries.
        entry: ?u32,
    },
};

const entry_fields = [_][]const u8{ "source", "path", "label", "required", "reason" };
/// Every top-level key any version names. A key outside this set is refused
/// before the version is read; `ceiling` in a version 1 document is refused
/// after it.
const top_fields = [_][]const u8{ "version", "classifications", "ceiling" };
const ceiling_fields = [_][]const u8{ "profile", "exclude" };

/// Parse and validate a declaration document. The result owns copies of every
/// string it keeps; `bytes` may be freed or overwritten after this returns.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!ParseResult {
    if (bytes.len > max_document_bytes) return refuse(.document_too_large, null);

    // The JSON tree lives in a scratch arena that is always released; only the
    // accepted classifications are copied into the result arena.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return refuse(.duplicate_key, null),
        else => return refuse(.invalid_json, null),
    };

    if (root != .object) return refuse(.wrong_type, null);
    const top = root.object;
    if (hasUnknownKey(top, &top_fields)) return refuse(.unknown_field, null);
    const version_value = top.get("version") orelse return refuse(.missing_field, null);
    const version: u8 = switch (version_value) {
        .integer => |v| switch (v) {
            1 => 1,
            2 => 2,
            else => return refuse(.unsupported_version, null),
        },
        .float, .number_string => return refuse(.unsupported_version, null),
        else => return refuse(.wrong_type, null),
    };
    const list_value = top.get("classifications");
    const ceiling_value = top.get("ceiling");
    if (version == 1) {
        if (ceiling_value != null) return refuse(.unknown_field, null);
        if (list_value == null) return refuse(.missing_field, null);
    } else if (list_value == null and ceiling_value == null) {
        return refuse(.declaration_empty, null);
    }

    const items: []const std.json.Value = if (list_value) |value| blk: {
        if (value != .array) return refuse(.wrong_type, null);
        const list = value.array.items;
        if (list.len == 0) return refuse(.classifications_empty, null);
        if (list.len > max_classifications) return refuse(.too_many_classifications, null);
        break :blk list;
    } else &.{};

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var declaration = Declaration{ .arena = arena, .classifications = &.{} };
    var accepted = false;
    defer if (!accepted) declaration.deinit();
    const owned = arena.allocator();

    const out = try owned.alloc(Classification, items.len);
    for (items, 0..) |item, index| {
        const at: u32 = @intCast(index);
        const checked = checkEntry(item);
        const fields = switch (checked) {
            .refused => |reason| return refuse(reason, at),
            .ok => |f| f,
        };
        for (out[0..index]) |previous| {
            if (previous.source_kind == fields.source_kind and
                std.mem.eql(u8, previous.source_name, fields.source_name) and
                std.mem.eql(u8, previous.path_text, fields.path_text))
            {
                return refuse(.duplicate_entry, at);
            }
        }
        out[index] = try copyEntry(owned, fields);
    }

    std.mem.sort(Classification, out, {}, lessThan);
    declaration.classifications = out;

    if (ceiling_value) |value| {
        switch (try checkCeiling(owned, value)) {
            .refused => |reason| return refuse(reason, null),
            .ok => |ceiling| declaration.ceiling = ceiling,
        }
    }
    accepted = true;
    return .{ .ok = declaration };
}

const CeilingCheck = union(enum) { ok: Ceiling, refused: Refusal };

/// Validate a `ceiling` object and copy its exclude list, sorted, into `owned`.
fn checkCeiling(owned: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!CeilingCheck {
    if (value != .object) return .{ .refused = .wrong_type };
    const object = value.object;
    if (hasUnknownKey(object, &ceiling_fields)) return .{ .refused = .unknown_field };
    const profile_value = object.get("profile") orelse return .{ .refused = .missing_field };
    const exclude_value = object.get("exclude") orelse return .{ .refused = .missing_field };
    if (profile_value != .string or exclude_value != .array) return .{ .refused = .wrong_type };
    const items = exclude_value.array.items;
    for (items) |item| {
        if (item != .string) return .{ .refused = .wrong_type };
    }
    const profile = capability_profiles.findProfile(profile_value.string) orelse
        return .{ .refused = .ceiling_profile_unknown };
    if (items.len > max_exclude) return .{ .refused = .ceiling_exclude_invalid };
    for (items, 0..) |item, index| {
        if (!isValidExclude(item.string)) return .{ .refused = .ceiling_exclude_invalid };
        for (items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.string, item.string)) {
                return .{ .refused = .ceiling_exclude_duplicate };
            }
        }
    }

    const exclude = try owned.alloc([]const u8, items.len);
    for (items, 0..) |item, index| exclude[index] = try owned.dupe(u8, item.string);
    std.mem.sort([]const u8, exclude, {}, bytesLessThan);
    return .{ .ok = .{ .profile = profile, .exclude = exclude } };
}

fn bytesLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A `zttp:` module specifier of `min_exclude_bytes` to `max_exclude_bytes`
/// bytes, every byte in `[a-z0-9_:-]`. The module need not exist in this build:
/// excluding a module the build does not carry is harmless.
fn isValidExclude(text: []const u8) bool {
    if (text.len < min_exclude_bytes or text.len > max_exclude_bytes) return false;
    if (!std.mem.startsWith(u8, text, "zttp:")) return false;
    for (text) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '_' or c == ':' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Canonical encoding: ZTDCL1

/// The `ZTDCL1` magic, schema, and digest domain. The acceptance kernel's
/// decoder in `packages/proof-checker/src/declaration.zig` holds the same
/// values; the round-trip test in `packages/tools/src/declaration_encoding_test.zig`
/// fails when the two disagree.
pub const canonical_magic = "ZTDCL1\x00\x00";
pub const canonical_schema: u16 = 1;
pub const digest_domain = "zttp-declaration-v1";

pub const EncodeError = std.mem.Allocator.Error || error{
    /// The declaration has no classifications and no ceiling. `parse` refuses
    /// such a document as `declaration_empty`, so only a hand-built value
    /// reaches this.
    DeclarationEmpty,
    /// A reason is longer than `max_reason_bytes`. `parse` refuses such a
    /// document as `reason_too_long`, so only a hand-built value reaches this.
    ReasonTooLong,
};

/// Write `decl` as `ZTDCL1` bytes: integers little-endian, strings with a u32
/// length prefix, every field written. The layout is in
/// docs/plans/2026-09-23-m4-t5-scope-and-grants-design.md section 13. The
/// classifications are written in the order `parse` sorted them and the
/// exclude list in the order `parse` sorted it. The profile is written as its
/// index in `capability_profiles.profiles`. Caller frees the result.
pub fn encodeCanonical(allocator: std.mem.Allocator, decl: *const Declaration) EncodeError![]u8 {
    if (decl.classifications.len == 0 and decl.ceiling == null) return error.DeclarationEmpty;
    for (decl.classifications) |c| {
        if (c.reason.len > max_reason_bytes) return error.ReasonTooLong;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, canonical_magic);
    try appendInt(&out, allocator, u16, canonical_schema);
    try appendInt(&out, allocator, u16, @intCast(decl.classifications.len));
    for (decl.classifications) |c| {
        try out.append(allocator, @intFromEnum(c.source_kind));
        try appendString(&out, allocator, c.source_name);
        try appendString(&out, allocator, c.path_text);
        try out.append(allocator, @intFromEnum(c.label));
        try out.append(allocator, @intFromBool(c.required));
        try appendString(&out, allocator, c.reason);
    }
    if (decl.ceiling) |ceiling| {
        try out.append(allocator, 1);
        try out.append(allocator, capability_profiles.indexOf(ceiling.profile));
        try appendInt(&out, allocator, u16, @intCast(ceiling.exclude.len));
        for (ceiling.exclude) |module| try appendString(&out, allocator, module);
    } else {
        try out.append(allocator, 0);
    }
    return out.toOwnedSlice(allocator);
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) std.mem.Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    try appendInt(out, allocator, u32, @intCast(text.len));
    try out.appendSlice(allocator, text);
}

/// Domain-separated SHA-256 over `ZTDCL1` bytes: the digest a graph member
/// carries for them.
pub fn digest(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(digest_domain);
    hasher.update(bytes);
    return hasher.finalResult();
}

fn refuse(reason: Refusal, entry: ?u32) ParseResult {
    return .{ .refused = .{ .reason = reason, .entry = entry } };
}

fn hasUnknownKey(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var keys = object.iterator();
    outer: while (keys.next()) |kv| {
        for (allowed) |name| {
            if (std.mem.eql(u8, kv.key_ptr.*, name)) continue :outer;
        }
        return true;
    }
    return false;
}

/// One entry after validation, still borrowing the scratch tree.
const EntryFields = struct {
    source_kind: SourceKind,
    source_name: []const u8,
    path_text: []const u8,
    label: Label,
    required: bool,
    reason: []const u8,
};

const EntryCheck = union(enum) { ok: EntryFields, refused: Refusal };

fn checkEntry(item: std.json.Value) EntryCheck {
    if (item != .object) return .{ .refused = .wrong_type };
    const object = item.object;
    if (hasUnknownKey(object, &entry_fields)) return .{ .refused = .unknown_field };
    for (entry_fields) |name| {
        if (object.get(name) == null) return .{ .refused = .missing_field };
    }
    const source = object.get("source").?;
    const path = object.get("path").?;
    const label = object.get("label").?;
    const required = object.get("required").?;
    const reason = object.get("reason").?;
    if (source != .string or path != .string or label != .string or
        required != .bool or reason != .string)
    {
        return .{ .refused = .wrong_type };
    }

    const parsed_source = parseSource(source.string) orelse return .{ .refused = .source_invalid };
    if (!isValidPath(path.string)) return .{ .refused = .path_invalid };
    const parsed_label = parseLabel(label.string) orelse return .{ .refused = .label_unsupported };
    if (std.mem.trim(u8, reason.string, &std.ascii.whitespace).len == 0) {
        return .{ .refused = .reason_empty };
    }
    if (reason.string.len > max_reason_bytes) return .{ .refused = .reason_too_long };
    return .{ .ok = .{
        .source_kind = parsed_source.kind,
        .source_name = parsed_source.name,
        .path_text = path.string,
        .label = parsed_label,
        .required = required.bool,
        .reason = reason.string,
    } };
}

fn copyEntry(owned: std.mem.Allocator, fields: EntryFields) std.mem.Allocator.Error!Classification {
    const path_text = try owned.dupe(u8, fields.path_text);
    const segment_count = std.mem.countScalar(u8, path_text, '.') + 1;
    const segments = try owned.alloc([]const u8, segment_count);
    var it = std.mem.splitScalar(u8, path_text, '.');
    var i: usize = 0;
    while (it.next()) |segment| : (i += 1) segments[i] = segment;
    return .{
        .source_kind = fields.source_kind,
        .source_name = try owned.dupe(u8, fields.source_name),
        .path_text = path_text,
        .path = segments,
        .label = fields.label,
        .required = fields.required,
        .reason = try owned.dupe(u8, fields.reason),
    };
}

fn lessThan(_: void, a: Classification, b: Classification) bool {
    if (a.source_kind != b.source_kind) {
        return @intFromEnum(a.source_kind) < @intFromEnum(b.source_kind);
    }
    switch (std.mem.order(u8, a.source_name, b.source_name)) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.order(u8, a.path_text, b.path_text) == .lt,
    }
}

fn parseLabel(text: []const u8) ?Label {
    if (std.mem.eql(u8, text, "secret")) return .secret;
    if (std.mem.eql(u8, text, "credential")) return .credential;
    return null;
}

const Source = struct { kind: SourceKind, name: []const u8 };

fn parseSource(text: []const u8) ?Source {
    const fetch_prefix = "fetch:";
    const service_prefix = "service:";
    if (std.mem.startsWith(u8, text, fetch_prefix)) {
        const host = text[fetch_prefix.len..];
        return if (isValidHost(host)) .{ .kind = .fetch, .name = host } else null;
    }
    if (std.mem.startsWith(u8, text, service_prefix)) {
        const name = text[service_prefix.len..];
        return if (isValidServiceName(name)) .{ .kind = .service, .name = name } else null;
    }
    return null;
}

/// A lowercase DNS host name: 1 to 253 bytes of dot-separated labels, each 1 to
/// 63 bytes of `[a-z0-9-]` that neither starts nor ends with a hyphen. No port,
/// no trailing dot, no empty label.
fn isValidHost(host: []const u8) bool {
    if (host.len == 0 or host.len > max_host_bytes) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > max_host_label_bytes) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
            if (!ok) return false;
        }
    }
    return true;
}

/// A service name as the system linker can resolve it.
///
/// The linker validates no charset: `findHandlerByName` compares the name to a
/// bundle's `handlers[].name` byte for byte (system_linker.zig:287), and
/// `mountMatchName` requires the name to be the leading segment of a request
/// path, `/<name>` or `/<name>/...`, compared against the raw path bytes
/// (system_linker.zig:329, mirrored by the runtime's
/// `in_process_dispatch.pathMountsName`). A name the linker can resolve by
/// either route is therefore one path segment that needs no percent-encoding:
/// 1 to 64 bytes of RFC 3986 unreserved characters `[A-Za-z0-9._~-]`, and not
/// the dot segments `.` or `..`, which a path normalizer removes. The 64-byte
/// cap is this file's bound; the linker has none.
fn isValidServiceName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_service_name_bytes) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        if (!ok) return false;
    }
    return true;
}

/// 1 to 16 dot-separated segments, each `[A-Za-z_][A-Za-z0-9_]*` and at most
/// 64 bytes. Wildcards, brackets and empty segments fail the character rule.
fn isValidPath(path: []const u8) bool {
    if (path.len == 0) return false;
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        count += 1;
        if (count > max_path_segments) return false;
        if (segment.len == 0 or segment.len > max_segment_bytes) return false;
        if (!(std.ascii.isAlphabetic(segment[0]) or segment[0] == '_')) return false;
        for (segment[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        }
    }
    return true;
}

/// How an observed member path relates to a declared one.
pub const Relation = enum {
    /// The two paths differ at some segment both have.
    unrelated,
    /// Same segments, same length.
    exact,
    /// The observed path reads below the declared member, for example
    /// `customer.tax_id.last4` against `customer.tax_id`.
    observed_extends_declared,
    /// The observed path is an ancestor of the declared member, so the value
    /// read contains it, for example `customer` against `customer.tax_id`. An
    /// empty observed path is the whole source value and is a prefix of any
    /// declared path.
    observed_is_prefix,
};

/// Compare two paths segment by segment from the root. Trailing segments are
/// never compared alone: `tax_id` is unrelated to `customer.tax_id`.
pub fn relation(declared: []const []const u8, observed: []const []const u8) Relation {
    const common = @min(declared.len, observed.len);
    for (declared[0..common], observed[0..common]) |d, o| {
        if (!std.mem.eql(u8, d, o)) return .unrelated;
    }
    if (declared.len == observed.len) return .exact;
    return if (observed.len > declared.len) .observed_extends_declared else .observed_is_prefix;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectRefused(bytes: []const u8, reason: Refusal, entry: ?u32) !void {
    var result = try parse(testing.allocator, bytes);
    switch (result) {
        .ok => |*d| {
            d.deinit();
            std.debug.print("expected refusal {s}, document was accepted\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
        .refused => |r| {
            try testing.expectEqual(reason, r.reason);
            try testing.expectEqual(entry, r.entry);
        },
    }
}

const two_entries =
    \\{ "version": 1,
    \\  "classifications": [
    \\    { "source": "service:billing", "path": "card.token",
    \\      "label": "credential", "required": false, "reason": "Payment token." },
    \\    { "source": "fetch:api.example.com", "path": "customer.tax_id",
    \\      "label": "secret", "required": true, "reason": "Tax identifier." }
    \\  ] }
;

test "declaration accepts two entries, sorts them, and owns its strings" {
    const buffer = try testing.allocator.dupe(u8, two_entries);
    defer testing.allocator.free(buffer);
    var result = try parse(testing.allocator, buffer);
    try testing.expect(result == .ok);
    var decl = &result.ok;
    defer decl.deinit();

    // The input is gone: every byte kept must be a copy.
    @memset(buffer, 'X');

    try testing.expectEqual(@as(usize, 2), decl.classifications.len);
    const first = decl.classifications[0];
    try testing.expectEqual(SourceKind.fetch, first.source_kind);
    try testing.expectEqualStrings("api.example.com", first.source_name);
    try testing.expectEqualStrings("customer.tax_id", first.path_text);
    try testing.expectEqual(@as(usize, 2), first.path.len);
    try testing.expectEqualStrings("customer", first.path[0]);
    try testing.expectEqualStrings("tax_id", first.path[1]);
    try testing.expectEqual(Label.secret, first.label);
    try testing.expect(first.required);
    try testing.expectEqualStrings("Tax identifier.", first.reason);

    const second = decl.classifications[1];
    try testing.expectEqual(SourceKind.service, second.source_kind);
    try testing.expectEqualStrings("billing", second.source_name);
    try testing.expectEqualStrings("card.token", second.path_text);
    try testing.expectEqual(@as(usize, 2), second.path.len);
    try testing.expectEqualStrings("card", second.path[0]);
    try testing.expectEqualStrings("token", second.path[1]);
    try testing.expectEqual(Label.credential, second.label);
    try testing.expect(!second.required);
    try testing.expectEqualStrings("Payment token.", second.reason);
}

test "declaration sorts by source name then path within one source kind" {
    var result = try parse(testing.allocator,
        \\{"version":1,"classifications":[
        \\{"source":"fetch:b.example","path":"a","label":"secret","required":true,"reason":"r"},
        \\{"source":"fetch:a.example","path":"z","label":"secret","required":true,"reason":"r"},
        \\{"source":"fetch:a.example","path":"b","label":"secret","required":true,"reason":"r"}]}
    );
    try testing.expect(result == .ok);
    defer result.ok.deinit();
    const c = result.ok.classifications;
    try testing.expectEqualStrings("a.example", c[0].source_name);
    try testing.expectEqualStrings("b", c[0].path_text);
    try testing.expectEqualStrings("a.example", c[1].source_name);
    try testing.expectEqualStrings("z", c[1].path_text);
    try testing.expectEqualStrings("b.example", c[2].source_name);
}

const RefusalCase = struct {
    name: []const u8,
    bytes: []const u8,
    reason: Refusal,
    entry: ?u32,
    /// Build the document at run time instead of using `bytes`, for inputs
    /// too large to write as a literal. The caller frees the result.
    build: ?*const fn (std.mem.Allocator) std.mem.Allocator.Error![]u8 = null,
};

/// A document one byte over `max_document_bytes`.
fn buildOversize(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    const big = try allocator.alloc(u8, max_document_bytes + 1);
    @memset(big, ' ');
    return big;
}

/// A document with `count` distinct, valid entries.
fn buildEntries(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "{\"version\":1,\"classifications\":[");
    for (0..count) |i| {
        if (i != 0) try list.append(allocator, ',');
        try list.print(allocator,
            \\{{"source":"fetch:a.example","path":"p{d}","label":"secret","required":true,"reason":"r"}}
        , .{i});
    }
    try list.appendSlice(allocator, "]}");
    return list.toOwnedSlice(allocator);
}

fn buildOverCount(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return buildEntries(allocator, max_classifications + 1);
}

/// A document with one entry built from the five given field texts.
fn oneEntry(comptime fields: []const u8) []const u8 {
    return "{\"version\":1,\"classifications\":[{" ++ fields ++ "}]}";
}

const good_fields =
    \\"source":"fetch:api.example.com","path":"a.b","label":"secret","required":true,"reason":"r"
;

/// Two entries: a valid first entry, then one built from `fields`.
fn afterGood(comptime fields: []const u8) []const u8 {
    return "{\"version\":1,\"classifications\":[{" ++ good_fields ++ "},{" ++ fields ++ "}]}";
}

/// A version 2 document whose only section is `"ceiling":` followed by `value`.
fn v2Ceiling(comptime value: []const u8) []const u8 {
    return "{\"version\":2,\"ceiling\":" ++ value ++ "}";
}

/// A version 2 ceiling whose exclude list has `count` distinct, valid entries.
fn buildExcludes(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "{\"version\":2,\"ceiling\":{\"profile\":\"adapter\",\"exclude\":[");
    for (0..count) |i| {
        if (i != 0) try list.append(allocator, ',');
        try list.print(allocator, "\"zttp:m{d}\"", .{i});
    }
    try list.appendSlice(allocator, "]}}");
    return list.toOwnedSlice(allocator);
}

fn buildOverExclude(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return buildExcludes(allocator, max_exclude + 1);
}

const refusal_cases = [_]RefusalCase{
    .{ .name = "not json", .bytes = "{\"version\":1,", .reason = .invalid_json, .entry = null },
    .{ .name = "trailing garbage", .bytes = oneEntry(good_fields) ++ " x", .reason = .invalid_json, .entry = null },
    .{ .name = "duplicate top key", .bytes = "{\"version\":1,\"version\":1,\"classifications\":[]}", .reason = .duplicate_key, .entry = null },
    .{ .name = "duplicate entry key", .bytes = oneEntry(good_fields ++ ",\"label\":\"secret\""), .reason = .duplicate_key, .entry = null },
    .{ .name = "unknown top key", .bytes = "{\"version\":1,\"classifications\":[{" ++ good_fields ++ "}],\"extra\":0}", .reason = .unknown_field, .entry = null },
    .{ .name = "unknown entry key", .bytes = afterGood(good_fields ++ ",\"note\":\"x\""), .reason = .unknown_field, .entry = 1 },
    .{ .name = "missing version", .bytes = "{\"classifications\":[{" ++ good_fields ++ "}]}", .reason = .missing_field, .entry = null },
    .{ .name = "missing classifications", .bytes = "{\"version\":1}", .reason = .missing_field, .entry = null },
    .{ .name = "missing reason", .bytes = afterGood(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":true
    ), .reason = .missing_field, .entry = 1 },
    .{ .name = "missing required", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"secret","reason":"r"
    ), .reason = .missing_field, .entry = 0 },
    .{ .name = "top level array", .bytes = "[]", .reason = .wrong_type, .entry = null },
    .{ .name = "version string", .bytes = "{\"version\":\"1\",\"classifications\":[]}", .reason = .wrong_type, .entry = null },
    .{ .name = "classifications object", .bytes = "{\"version\":1,\"classifications\":{}}", .reason = .wrong_type, .entry = null },
    .{ .name = "entry not object", .bytes = "{\"version\":1,\"classifications\":[{" ++ good_fields ++ "},1]}", .reason = .wrong_type, .entry = 1 },
    .{ .name = "required string", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":"yes","reason":"r"
    ), .reason = .wrong_type, .entry = 0 },
    .{ .name = "reason null", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":null
    ), .reason = .wrong_type, .entry = 0 },
    .{ .name = "version 3", .bytes = "{\"version\":3,\"classifications\":[{" ++ good_fields ++ "}]}", .reason = .unsupported_version, .entry = null },
    .{ .name = "version 1.0", .bytes = "{\"version\":1.0,\"classifications\":[{" ++ good_fields ++ "}]}", .reason = .unsupported_version, .entry = null },
    .{ .name = "empty list", .bytes = "{\"version\":1,\"classifications\":[]}", .reason = .classifications_empty, .entry = null },
    .{ .name = "no prefix", .bytes = oneEntry(
        \\"source":"api.example.com","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "uppercase host", .bytes = afterGood(
        \\"source":"fetch:API.example.com","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 1 },
    .{ .name = "host with port", .bytes = oneEntry(
        \\"source":"fetch:a.example:443","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "host empty label", .bytes = oneEntry(
        \\"source":"fetch:a..example","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "host trailing dot", .bytes = oneEntry(
        \\"source":"fetch:a.example.","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "host leading hyphen", .bytes = oneEntry(
        \\"source":"fetch:-a.example","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "host label over 63", .bytes = oneEntry(
        \\"source":"fetch:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "empty host", .bytes = oneEntry(
        \\"source":"fetch:","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "service with slash", .bytes = oneEntry(
        \\"source":"service:pay/eu","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "service dot segment", .bytes = oneEntry(
        \\"source":"service:..","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "empty service", .bytes = oneEntry(
        \\"source":"service:","path":"a","label":"secret","required":true,"reason":"r"
    ), .reason = .source_invalid, .entry = 0 },
    .{ .name = "path wildcard", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"customer.*","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "path index", .bytes = afterGood(
        \\"source":"fetch:a.example","path":"items[0].id","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 1 },
    .{ .name = "path empty segment", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a..b","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "path empty", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "path leading digit", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a.1b","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "path 17 segments", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "path segment over 64", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","label":"secret","required":true,"reason":"r"
    ), .reason = .path_invalid, .entry = 0 },
    .{ .name = "label user_input", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"user_input","required":true,"reason":"r"
    ), .reason = .label_unsupported, .entry = 0 },
    .{ .name = "label pii", .bytes = afterGood(
        \\"source":"fetch:a.example","path":"a","label":"pii","required":true,"reason":"r"
    ), .reason = .label_unsupported, .entry = 1 },
    .{ .name = "label wrong case", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"Secret","required":true,"reason":"r"
    ), .reason = .label_unsupported, .entry = 0 },
    .{ .name = "reason empty", .bytes = oneEntry(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":""
    ), .reason = .reason_empty, .entry = 0 },
    .{ .name = "reason whitespace", .bytes = afterGood(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":" \t\n"
    ), .reason = .reason_empty, .entry = 1 },
    .{ .name = "reason 1025 bytes", .bytes = afterGood(
        \\"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":"
    ++ "r" ** 1025 ++ "\""), .reason = .reason_too_long, .entry = 1 },
    .{ .name = "same source and path", .bytes = afterGood(
        \\"source":"fetch:api.example.com","path":"a.b","label":"credential","required":false,"reason":"again"
    ), .reason = .duplicate_entry, .entry = 1 },
    // Version 2 and the ceiling.
    .{ .name = "v1 with a ceiling", .bytes = "{\"version\":1,\"classifications\":[{" ++ good_fields ++ "}],\"ceiling\":{\"profile\":\"boundary\",\"exclude\":[]}}", .reason = .unknown_field, .entry = null },
    .{ .name = "v1 with only a ceiling", .bytes = "{\"version\":1,\"ceiling\":{\"profile\":\"boundary\",\"exclude\":[]}}", .reason = .unknown_field, .entry = null },
    .{ .name = "v2 with neither section", .bytes = "{\"version\":2}", .reason = .declaration_empty, .entry = null },
    .{ .name = "v2 with an empty list", .bytes = "{\"version\":2,\"classifications\":[]}", .reason = .classifications_empty, .entry = null },
    .{ .name = "v2 empty list beside a ceiling", .bytes = "{\"version\":2,\"classifications\":[],\"ceiling\":{\"profile\":\"boundary\",\"exclude\":[]}}", .reason = .classifications_empty, .entry = null },
    .{ .name = "v2 classifications null", .bytes = "{\"version\":2,\"classifications\":null}", .reason = .wrong_type, .entry = null },
    .{ .name = "ceiling not object", .bytes = v2Ceiling("\"boundary\""), .reason = .wrong_type, .entry = null },
    .{ .name = "ceiling null", .bytes = v2Ceiling("null"), .reason = .wrong_type, .entry = null },
    .{ .name = "ceiling unknown key", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[],\"note\":1}"), .reason = .unknown_field, .entry = null },
    .{ .name = "ceiling duplicate key", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"profile\":\"adapter\",\"exclude\":[]}"), .reason = .duplicate_key, .entry = null },
    .{ .name = "ceiling missing exclude", .bytes = v2Ceiling("{\"profile\":\"boundary\"}"), .reason = .missing_field, .entry = null },
    .{ .name = "ceiling missing profile", .bytes = v2Ceiling("{\"exclude\":[]}"), .reason = .missing_field, .entry = null },
    .{ .name = "profile number", .bytes = v2Ceiling("{\"profile\":0,\"exclude\":[]}"), .reason = .wrong_type, .entry = null },
    .{ .name = "exclude string", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":\"zttp:fetch\"}"), .reason = .wrong_type, .entry = null },
    .{ .name = "exclude entry number", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[1]}"), .reason = .wrong_type, .entry = null },
    .{ .name = "profile unknown", .bytes = v2Ceiling("{\"profile\":\"store\",\"exclude\":[]}"), .reason = .ceiling_profile_unknown, .entry = null },
    .{ .name = "profile wrong case", .bytes = v2Ceiling("{\"profile\":\"Boundary\",\"exclude\":[]}"), .reason = .ceiling_profile_unknown, .entry = null },
    .{ .name = "exclude no prefix", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"fetch\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude extension prefix", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp-ext:foo\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude prefix only", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude uppercase", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:Fetch\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude with slash", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:a/b\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude 65 bytes", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:" ++ "a" ** 60 ++ "\"]}"), .reason = .ceiling_exclude_invalid, .entry = null },
    .{ .name = "exclude 65 entries", .bytes = "", .reason = .ceiling_exclude_invalid, .entry = null, .build = buildOverExclude },
    .{ .name = "exclude repeats", .bytes = v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:fetch\",\"zttp:sql\",\"zttp:fetch\"]}"), .reason = .ceiling_exclude_duplicate, .entry = null },
    .{ .name = "one byte over the cap", .bytes = "", .reason = .document_too_large, .entry = null, .build = buildOversize },
    .{ .name = "257 entries", .bytes = "", .reason = .too_many_classifications, .entry = null, .build = buildOverCount },
};

test "declaration refuses each rule with its named reason and entry" {
    for (refusal_cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        if (case.build) |build| {
            const bytes = try build(testing.allocator);
            defer testing.allocator.free(bytes);
            try expectRefused(bytes, case.reason, case.entry);
        } else {
            try expectRefused(case.bytes, case.reason, case.entry);
        }
    }
}

test "declaration accepts exactly 256 classifications" {
    const bytes = try buildEntries(testing.allocator, max_classifications);
    defer testing.allocator.free(bytes);
    var result = try parse(testing.allocator, bytes);
    try testing.expect(result == .ok);
    defer result.ok.deinit();
    try testing.expectEqual(max_classifications, result.ok.classifications.len);
}

test "declaration accepts a document exactly at the byte cap" {
    const doc = oneEntry(good_fields);
    const buffer = try testing.allocator.alloc(u8, max_document_bytes);
    defer testing.allocator.free(buffer);
    @memset(buffer, ' ');
    @memcpy(buffer[0..doc.len], doc);
    var result = try parse(testing.allocator, buffer);
    try testing.expect(result == .ok);
    result.ok.deinit();
}

test "declaration refusal census: every member is driven by a case" {
    var seen = [_]bool{false} ** std.meta.tags(Refusal).len;
    for (refusal_cases) |case| seen[@intFromEnum(case.reason)] = true;
    for (std.meta.tags(Refusal)) |tag| {
        if (!seen[@intFromEnum(tag)]) {
            std.debug.print("no case drives refusal {s}\n", .{@tagName(tag)});
            return error.TestUnexpectedResult;
        }
    }
}

test "declaration accepts the service grammar the linker can resolve" {
    var result = try parse(testing.allocator, oneEntry(
        \\"source":"service:payments-eu_v2.~x","path":"_a.B9","label":"credential","required":false,"reason":"r"
    ));
    try testing.expect(result == .ok);
    defer result.ok.deinit();
    try testing.expectEqualStrings("payments-eu_v2.~x", result.ok.classifications[0].source_name);
}

test "relation compares whole paths from the root" {
    const declared = [_][]const u8{ "customer", "tax_id" };
    try testing.expectEqual(Relation.unrelated, relation(&declared, &.{"tax_id"}));
    try testing.expectEqual(Relation.observed_is_prefix, relation(&declared, &.{"customer"}));
    try testing.expectEqual(Relation.observed_extends_declared, relation(&declared, &.{ "customer", "tax_id", "last4" }));
    try testing.expectEqual(Relation.exact, relation(&declared, &.{ "customer", "tax_id" }));
    try testing.expectEqual(Relation.unrelated, relation(&declared, &.{ "vendor", "tax_id" }));
    try testing.expectEqual(Relation.unrelated, relation(&declared, &.{ "customer", "name" }));
    try testing.expectEqual(Relation.observed_is_prefix, relation(&declared, &.{}));
}

fn parseAndRelease(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var result = try parse(allocator, bytes);
    switch (result) {
        .ok => |*d| d.deinit(),
        .refused => return error.TestUnexpectedResult,
    }
}

test "declaration parse reports every allocation failure and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndRelease, .{@as([]const u8, two_entries)});
}

test "declaration version 2 accepts a ceiling alone, sorts its exclude list, and owns it" {
    const buffer = try testing.allocator.dupe(u8,
        \\{"version":2,"ceiling":{"profile":"adapter","exclude":["zttp:sql","zttp:fetch"]}}
    );
    defer testing.allocator.free(buffer);
    var result = try parse(testing.allocator, buffer);
    try testing.expect(result == .ok);
    var decl = &result.ok;
    defer decl.deinit();
    @memset(buffer, 'X');

    try testing.expectEqual(@as(usize, 0), decl.classifications.len);
    const ceiling = decl.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqualStrings("adapter", ceiling.profile.name);
    try testing.expectEqual(capability_profiles.findProfile("adapter").?, ceiling.profile);
    try testing.expectEqual(@as(usize, 2), ceiling.exclude.len);
    try testing.expectEqualStrings("zttp:fetch", ceiling.exclude[0]);
    try testing.expectEqualStrings("zttp:sql", ceiling.exclude[1]);
}

test "declaration version 2 accepts classifications alone, a ceiling with an empty exclude list, and both" {
    {
        var result = try parse(testing.allocator, "{\"version\":2,\"classifications\":[{" ++ good_fields ++ "}]}");
        try testing.expect(result == .ok);
        defer result.ok.deinit();
        try testing.expectEqual(@as(usize, 1), result.ok.classifications.len);
        try testing.expect(result.ok.ceiling == null);
    }
    {
        var result = try parse(testing.allocator, v2Ceiling("{\"profile\":\"ledger\",\"exclude\":[]}"));
        try testing.expect(result == .ok);
        defer result.ok.deinit();
        const ceiling = result.ok.ceiling orelse return error.TestMissingCeiling;
        try testing.expectEqualStrings("ledger", ceiling.profile.name);
        try testing.expectEqual(@as(usize, 0), ceiling.exclude.len);
    }
    {
        // An exclude entry the profile already excludes is accepted.
        var result = try parse(testing.allocator,
            \\{"version":2,"classifications":[{"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":"r"}],
            \\ "ceiling":{"profile":"boundary","exclude":["zttp:cache"]}}
        );
        try testing.expect(result == .ok);
        defer result.ok.deinit();
        try testing.expectEqual(@as(usize, 1), result.ok.classifications.len);
        const ceiling = result.ok.ceiling orelse return error.TestMissingCeiling;
        try testing.expectEqualStrings("zttp:cache", ceiling.exclude[0]);
    }
}

test "declaration accepts a reason of exactly max_reason_bytes and it encodes" {
    var decl = try parseOk("{\"version\":1,\"classifications\":[{\"source\":\"fetch:a.example\",\"path\":\"a\",\"label\":\"secret\",\"required\":true,\"reason\":\"" ++ "r" ** max_reason_bytes ++ "\"}]}");
    defer decl.deinit();
    try testing.expectEqual(max_reason_bytes, decl.classifications[0].reason.len);
    const bytes = try encodeCanonical(testing.allocator, &decl);
    testing.allocator.free(bytes);
}

test "declaration version 1 carries no ceiling" {
    var result = try parse(testing.allocator, two_entries);
    try testing.expect(result == .ok);
    defer result.ok.deinit();
    try testing.expect(result.ok.ceiling == null);
}

test "declaration accepts exactly 64 exclude entries and a 64-byte specifier" {
    const bytes = try buildExcludes(testing.allocator, max_exclude);
    defer testing.allocator.free(bytes);
    var result = try parse(testing.allocator, bytes);
    try testing.expect(result == .ok);
    defer result.ok.deinit();
    const ceiling = result.ok.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqual(max_exclude, ceiling.exclude.len);

    var long = try parse(testing.allocator, v2Ceiling("{\"profile\":\"boundary\",\"exclude\":[\"zttp:" ++ "a" ** 59 ++ "\",\"zttp:a\"]}"));
    try testing.expect(long == .ok);
    defer long.ok.deinit();
    const long_ceiling = long.ok.ceiling orelse return error.TestMissingCeiling;
    try testing.expectEqual(max_exclude_bytes, long_ceiling.exclude[1].len);
}

test "declaration version 2 parse reports every allocation failure and leaks nothing" {
    const doc =
        \\{"version":2,"classifications":[{"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":"r"}],
        \\ "ceiling":{"profile":"boundary","exclude":["zttp:sql","zttp:fetch"]}}
    ;
    try testing.checkAllAllocationFailures(testing.allocator, parseAndRelease, .{@as([]const u8, doc)});
}

fn parseOk(bytes: []const u8) !Declaration {
    const result = try parse(testing.allocator, bytes);
    return switch (result) {
        .ok => |d| d,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{@tagName(r.reason)});
            return error.TestUnexpectedResult;
        },
    };
}

test "encodeCanonical writes the ZTDCL1 layout field by field" {
    var decl = try parseOk(
        \\{"version":2,"classifications":[{"source":"service:billing","path":"card.token","label":"credential","required":false,"reason":"Tok."}],
        \\ "ceiling":{"profile":"ledger","exclude":["zttp:x"]}}
    );
    defer decl.deinit();
    const bytes = try encodeCanonical(testing.allocator, &decl);
    defer testing.allocator.free(bytes);

    const expected = "ZTDCL1\x00\x00" ++ "\x01\x00" ++ "\x01\x00" ++
        "\x01" ++ "\x07\x00\x00\x00billing" ++ "\x0a\x00\x00\x00card.token" ++
        "\x01" ++ "\x00" ++ "\x04\x00\x00\x00Tok." ++
        "\x01" ++ "\x02" ++ "\x01\x00" ++ "\x06\x00\x00\x00zttp:x";
    try testing.expectEqualSlices(u8, expected, bytes);
}

test "encodeCanonical writes ceiling_present 0 and no ceiling for a version 1 document" {
    var decl = try parseOk(
        \\{"version":1,"classifications":[{"source":"fetch:a.example","path":"a","label":"secret","required":true,"reason":"r"}]}
    );
    defer decl.deinit();
    const bytes = try encodeCanonical(testing.allocator, &decl);
    defer testing.allocator.free(bytes);
    const expected = "ZTDCL1\x00\x00" ++ "\x01\x00" ++ "\x01\x00" ++
        "\x00" ++ "\x09\x00\x00\x00a.example" ++ "\x01\x00\x00\x00a" ++
        "\x00" ++ "\x01" ++ "\x01\x00\x00\x00r" ++ "\x00";
    try testing.expectEqualSlices(u8, expected, bytes);
}

test "encodeCanonical writes each profile as its index: boundary 0, adapter 1, ledger 2" {
    const names = [_][]const u8{ "boundary", "adapter", "ledger" };
    for (names, 0..) |name, index| {
        var buf: [128]u8 = undefined;
        const doc = try std.fmt.bufPrint(&buf, "{{\"version\":2,\"ceiling\":{{\"profile\":\"{s}\",\"exclude\":[]}}}}", .{name});
        var decl = try parseOk(doc);
        defer decl.deinit();
        const bytes = try encodeCanonical(testing.allocator, &decl);
        defer testing.allocator.free(bytes);
        // magic, schema, count 0, ceiling_present 1, profile, exclude_count 0.
        try testing.expectEqual(@as(usize, 8 + 2 + 2 + 1 + 1 + 2), bytes.len);
        try testing.expectEqual(@as(u8, 1), bytes[12]);
        try testing.expectEqual(@as(u8, @intCast(index)), bytes[13]);
    }
}

test "encodeCanonical refuses an empty declaration and a reason over the ZTDCL1 bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty = Declaration{ .arena = &arena, .classifications = &.{} };
    try testing.expectError(error.DeclarationEmpty, encodeCanonical(testing.allocator, &empty));

    var decl = try parseOk("{\"version\":1,\"classifications\":[{\"source\":\"fetch:a.example\",\"path\":\"a\",\"label\":\"secret\",\"required\":true,\"reason\":\"r\"}]}");
    defer decl.deinit();
    const entries = try decl.arena.allocator().dupe(Classification, decl.classifications);
    entries[0].reason = "r" ** (max_reason_bytes + 1);
    decl.classifications = entries;
    try testing.expectError(error.ReasonTooLong, encodeCanonical(testing.allocator, &decl));
}

test "two documents that differ only in order encode to the same bytes and digest" {
    var a = try parseOk(
        \\{"version":2,"ceiling":{"profile":"boundary","exclude":["zttp:sql","zttp:fetch"]},
        \\ "classifications":[
        \\ {"source":"service:billing","path":"card.token","label":"credential","required":false,"reason":"Tok."},
        \\ {"source":"fetch:api.example.com","path":"customer.tax_id","label":"secret","required":true,"reason":"Tax."}]}
    );
    defer a.deinit();
    var b = try parseOk(
        \\{"classifications":[
        \\ {"reason":"Tax.","required":true,"label":"secret","path":"customer.tax_id","source":"fetch:api.example.com"},
        \\ {"source":"service:billing","path":"card.token","label":"credential","required":false,"reason":"Tok."}],
        \\ "ceiling":{"exclude":["zttp:fetch","zttp:sql"],"profile":"boundary"},"version":2}
    );
    defer b.deinit();
    const ea = try encodeCanonical(testing.allocator, &a);
    defer testing.allocator.free(ea);
    const eb = try encodeCanonical(testing.allocator, &b);
    defer testing.allocator.free(eb);
    try testing.expectEqualSlices(u8, ea, eb);
    try testing.expectEqualSlices(u8, &digest(ea), &digest(eb));

    var plain: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ea, &plain, .{});
    try testing.expect(!std.mem.eql(u8, &plain, &digest(ea)));
}

fn encodeAndRelease(allocator: std.mem.Allocator, decl: *const Declaration) !void {
    const bytes = try encodeCanonical(allocator, decl);
    allocator.free(bytes);
}

test "encodeCanonical reports every allocation failure and leaks nothing" {
    var decl = try parseOk(two_entries);
    defer decl.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, encodeAndRelease, .{@as(*const Declaration, &decl)});
}
