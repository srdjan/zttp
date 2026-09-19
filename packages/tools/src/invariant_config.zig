//! Deterministic authoring boundary for the confirmed invariant specification.
const std = @import("std");
const zts = @import("zts");
const invariant = @import("zttp_proof_checker").invariant;

const Currency = struct { code: []const u8, scale: u8 };

/// One declared kind in a schema 2 document. A kind that carries a payload
/// declares its own fields here as the catalog grows.
const KindEntry = struct { kind: []const u8 };

const Document = struct {
    version: u16,
    /// Schema 1 names its one kind here; schema 2 lists them under `kinds`.
    /// Both are optional in the type and required by the schema that owns them,
    /// so a document that omits one or carries both is refused rather than
    /// quietly defaulted.
    kind: ?[]const u8 = null,
    kinds: ?[]KindEntry = null,
    ledger: []const u8,
    currencies: []Currency,
    /// Human annotation only. The confirmed structured fields define the claim.
    statement: ?[]const u8 = null,
};

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const source = try zts.file_io.readFile(allocator, path, 1024 * 1024);
    defer allocator.free(source);
    return parse(allocator, source);
}

/// The JSON is deliberately a closed template, not a predicate language.
///
/// Both wire schemas are authored here. Schema 1 documents must still encode
/// byte for byte as they always have: deployed artifacts and existing ledger
/// stores are bound to the digest of those exact bytes.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Document, allocator, source, .{});
    defer parsed.deinit();
    const doc = parsed.value;
    return switch (doc.version) {
        invariant.schema_version => encodeV1(allocator, doc),
        invariant.schema_version_v2 => encodeV2(allocator, doc),
        else => error.UnsupportedInvariantVersion,
    };
}

/// The payload a declared kind carries in schema 2 bytes. The switch is
/// exhaustive, so a catalog member added without a case fails to compile rather
/// than encoding an empty payload the decoder would reject far from the cause.
fn kindPayload(kind: invariant.Kind) []const u8 {
    return switch (kind) {
        .balance_conservation_v1 => "",
    };
}

/// The ledger and currency fields both schemas share. Sorting happens here, so
/// the author may list currencies in any order and the canonical bytes do not
/// depend on that order.
fn validateCommon(doc: Document) !void {
    if (doc.ledger.len == 0 or doc.ledger.len > invariant.max_ledger_id_bytes) return error.InvalidLedgerId;
    if (doc.currencies.len == 0 or doc.currencies.len > invariant.max_currencies) return error.InvalidCurrencies;
    for (doc.currencies) |currency| {
        if (currency.code.len != 3) return error.InvalidCurrency;
    }
    std.mem.sort(Currency, doc.currencies, {}, struct {
        fn less(_: void, a: Currency, b: Currency) bool {
            return std.mem.lessThan(u8, a.code, b.code);
        }
    }.less);
}

fn commonSize(doc: Document) usize {
    return invariant.header_size + doc.ledger.len +
        doc.currencies.len * invariant.currency_record_size;
}

/// Write the header and the shared region. `tagged` is the header field the two
/// schemas spend differently: schema 1 puts its single kind there, schema 2 the
/// number of kind records that follow.
fn writeCommon(bytes: []u8, doc: Document, schema: u16, tagged: u16) void {
    @memcpy(bytes[0..8], invariant.magic);
    std.mem.writeInt(u16, bytes[8..10], schema, .little);
    std.mem.writeInt(u16, bytes[10..12], tagged, .little);
    std.mem.writeInt(u16, bytes[12..14], @intCast(doc.ledger.len), .little);
    std.mem.writeInt(u16, bytes[14..16], @intCast(doc.currencies.len), .little);
    @memcpy(bytes[invariant.header_size..][0..doc.ledger.len], doc.ledger);
    for (doc.currencies, 0..) |currency, i| {
        const start = invariant.header_size + doc.ledger.len + i * invariant.currency_record_size;
        @memcpy(bytes[start..][0..3], currency.code);
        bytes[start + 3] = currency.scale;
    }
}

fn encodeV1(allocator: std.mem.Allocator, doc: Document) ![]u8 {
    if (doc.kinds != null) return error.InvalidInvariantDocument;
    const name = doc.kind orelse return error.MissingInvariantKind;
    const kind = std.meta.stringToEnum(invariant.Kind, name) orelse
        return error.UnsupportedInvariantKind;
    // Schema 1 has room for one kind and only ever carried this one. A kind the
    // catalog adds later is authored under schema 2, not retrofitted here.
    if (kind != .balance_conservation_v1) return error.UnsupportedInvariantKind;
    try validateCommon(doc);
    const bytes = try allocator.alloc(u8, commonSize(doc));
    errdefer allocator.free(bytes);
    writeCommon(bytes, doc, invariant.schema_version, @intFromEnum(kind));
    _ = try invariant.decode(bytes);
    return bytes;
}

fn encodeV2(allocator: std.mem.Allocator, doc: Document) ![]u8 {
    if (doc.kind != null) return error.InvalidInvariantDocument;
    const entries = doc.kinds orelse return error.MissingInvariantKind;
    if (entries.len > invariant.max_kinds) return error.TooManyInvariantKinds;
    try validateCommon(doc);

    const kinds = try allocator.alloc(invariant.Kind, entries.len);
    defer allocator.free(kinds);
    for (entries, 0..) |entry, index| {
        kinds[index] = std.meta.stringToEnum(invariant.Kind, entry.kind) orelse
            return error.UnsupportedInvariantKind;
    }
    std.mem.sort(invariant.Kind, kinds, {}, struct {
        fn less(_: void, a: invariant.Kind, b: invariant.Kind) bool {
            return invariant.kindInfo(a).wire_ordinal < invariant.kindInfo(b).wire_ordinal;
        }
    }.less);

    var record_bytes: usize = 0;
    for (kinds) |kind| {
        record_bytes += invariant.kind_record_header_size + kindPayload(kind).len;
    }

    const bytes = try allocator.alloc(u8, commonSize(doc) + record_bytes);
    errdefer allocator.free(bytes);
    writeCommon(bytes, doc, invariant.schema_version_v2, @intCast(entries.len));
    var cursor = commonSize(doc);
    for (kinds) |kind| {
        const payload = kindPayload(kind);
        std.mem.writeInt(u16, bytes[cursor..][0..2], invariant.kindInfo(kind).wire_ordinal, .little);
        std.mem.writeInt(u16, bytes[cursor + 2 ..][0..2], @intCast(payload.len), .little);
        @memcpy(bytes[cursor + invariant.kind_record_header_size ..][0..payload.len], payload);
        cursor += invariant.kind_record_header_size + payload.len;
    }
    // The decoder is the authority: a repeated kind, a kind the catalog does
    // not name, and a set without balance conservation are all refused here.
    _ = try invariant.decode(bytes);
    return bytes;
}

test "confirmed invariant JSON canonicalizes currencies and rejects weakened templates" {
    const a = std.testing.allocator;
    const spec = try parse(a,
        \\{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2},{"code":"EUR","scale":2}]}
    );
    defer a.free(spec);
    const decoded = try invariant.decode(spec);
    try std.testing.expectEqualStrings("main", decoded.ledger_id);
    try std.testing.expectEqualStrings("EUR", &(try decoded.currency(0)).code);
    try std.testing.expectError(error.UnsupportedInvariantKind, parse(a,
        \\{"version":1,"kind":"approximately_balanced","ledger":"main","currencies":[{"code":"USD","scale":2}]}
    ));
    try std.testing.expectError(error.CurrenciesNotOrdered, parse(a,
        \\{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2},{"code":"USD","scale":2}]}
    ));
}

test "the schema 2 template canonicalizes its kind set and refuses weakened ones" {
    const a = std.testing.allocator;
    const spec = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2},{"code":"EUR","scale":2}],"kinds":[{"kind":"balance_conservation_v1"}]}
    );
    defer a.free(spec);
    const decoded = try invariant.decode(spec);
    try std.testing.expectEqual(invariant.schema_version_v2, decoded.schema);
    try std.testing.expectEqualStrings("main", decoded.ledger_id);
    try std.testing.expectEqualStrings("EUR", &(try decoded.currency(0)).code);
    try std.testing.expectEqual(@as(u16, 1), decoded.kind_count);
    try std.testing.expectEqual(invariant.Kind.balance_conservation_v1, try decoded.kindAt(0));

    try std.testing.expectError(error.UnsupportedInvariantKind, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"approximately_balanced"}]}
    ));
    try std.testing.expectError(error.RequiredKindMissing, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[]}
    ));
    try std.testing.expectError(error.DuplicateKind, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"balance_conservation_v1"}]}
    ));
    try std.testing.expectError(error.CurrenciesNotOrdered, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2},{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"}]}
    ));
}

test "each schema names its kinds in its own field and refuses the other's" {
    // Making `kind` optional so schema 2 can omit it must not let a schema 1
    // document omit it too, and a schema 2 document must not smuggle a single
    // kind past the record list the decoder checks.
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingInvariantKind, parse(a,
        \\{"version":1,"ledger":"main","currencies":[{"code":"USD","scale":2}]}
    ));
    try std.testing.expectError(error.InvalidInvariantDocument, parse(a,
        \\{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"}]}
    ));
    try std.testing.expectError(error.MissingInvariantKind, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}]}
    ));
    try std.testing.expectError(error.InvalidInvariantDocument, parse(a,
        \\{"version":2,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"}]}
    ));
    try std.testing.expectError(error.UnsupportedInvariantVersion, parse(a,
        \\{"version":3,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}]}
    ));
}

test "the two schemas produce different bytes and different digests for one ledger" {
    // Same ledger, same currencies, same kind: the documents still differ, and
    // the digest each hashes to must differ too, or a consumer could accept
    // schema 2 bytes against a schema 1 commitment.
    const a = std.testing.allocator;
    const v1 = try parse(a,
        \\{"version":1,"kind":"balance_conservation_v1","ledger":"main","currencies":[{"code":"USD","scale":2}]}
    );
    defer a.free(v1);
    const v2 = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"}]}
    );
    defer a.free(v2);
    try std.testing.expect(!std.mem.eql(u8, v1, v2));
    try std.testing.expect(!std.mem.eql(u8, &invariant.digest(v1), &invariant.digest(v2)));

    // The ledger and currency region is the shared part, byte for byte. Schema
    // 2 differs only in the schema field, the header field it spends on the
    // kind count, and the record list it appends.
    const common_end = invariant.header_size + "main".len + invariant.currency_record_size;
    try std.testing.expectEqualSlices(u8, v1[0..8], v2[0..8]);
    try std.testing.expectEqualSlices(
        u8,
        v1[invariant.header_size..common_end],
        v2[invariant.header_size..common_end],
    );
    try std.testing.expectEqual(common_end, v1.len);
    try std.testing.expectEqual(common_end + invariant.kind_record_header_size, v2.len);
}

test "a schema 1 document still encodes the bytes the pinned digest was taken over" {
    // The literal is the one pinned in packages/proof-checker/src/invariant.zig,
    // computed with shasum before any code compared it to itself. This ledger
    // and currency pair is the fixture it was taken over, so the authoring
    // boundary emitting anything else would move every deployed artifact's
    // invariant digest and lock every existing protected ledger store shut.
    const a = std.testing.allocator;
    const bytes = try parse(a,
        \\{"version":1,"kind":"balance_conservation_v1","ledger":"ledger","currencies":[{"code":"USD","scale":2},{"code":"EUR","scale":2}]}
    );
    defer a.free(bytes);
    try std.testing.expectEqualStrings(
        "6a13f44159ddc5639abbcb92065b2ef846c9ff569b7fceee73b4d6393f83be74",
        &std.fmt.bytesToHex(invariant.digest(bytes), .lower),
    );
}
