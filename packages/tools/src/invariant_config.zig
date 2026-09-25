//! Deterministic authoring boundary for the confirmed invariant specification.
const std = @import("std");
const zts = @import("zts");
const invariant = @import("zttp_proof_checker").invariant;

const Currency = struct { code: []const u8, scale: u8 };

/// One declared account rule. Exactly one of the two fields is present: the
/// closed union is expressed as two optional field names rather than as a tag
/// plus a value, so a document naming neither or both is refused rather than
/// defaulted to whichever the reader looks at first.
const AccountEntry = struct {
    exact: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
};

/// One declared kind in a schema 2 document. A kind that carries a payload
/// declares its own fields here as the catalog grows.
const KindEntry = struct {
    kind: []const u8,
    accounts: ?[]AccountEntry = null,
};

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
        invariant.schema_version_v1 => encodeV1(allocator, doc),
        invariant.schema_version_v2 => encodeV2(allocator, doc),
        else => error.UnsupportedInvariantVersion,
    };
}

/// One declared kind, resolved to the catalog member and its encoded payload.
const ResolvedKind = struct {
    kind: invariant.Kind,
    /// Owned by the caller's allocator. Empty for a kind that carries none.
    payload: []u8,
};

/// The payload a declared kind carries in schema 2 bytes. The switch is
/// exhaustive, so a catalog member added without a case fails to compile rather
/// than encoding an empty payload the decoder would reject far from the cause.
fn encodeKindPayload(
    allocator: std.mem.Allocator,
    kind: invariant.Kind,
    entry: KindEntry,
) ![]u8 {
    return switch (kind) {
        .balance_conservation_v1 => blk: {
            if (entry.accounts != null) return error.UnexpectedKindPayload;
            break :blk try allocator.alloc(u8, 0);
        },
        .declared_accounts_v1 => encodeAccountPayload(
            allocator,
            entry.accounts orelse return error.MissingAccountMatchers,
        ),
    };
}

/// Canonicalize and encode the declared account set.
///
/// Sorting happens here, so an author may list the rules in any order and the
/// canonical bytes do not depend on it. Sorting first is also what lets the
/// decoder below report a repeated rule as a duplicate rather than as whatever
/// ordering violation the author's typing order happened to produce.
fn encodeAccountPayload(allocator: std.mem.Allocator, entries: []AccountEntry) ![]u8 {
    if (entries.len == 0) return error.EmptyAccountMatcherSet;
    if (entries.len > invariant.max_account_matchers) return error.TooManyAccountMatchers;

    const matchers = try allocator.alloc(invariant.AccountMatcher, entries.len);
    defer allocator.free(matchers);
    for (entries, 0..) |entry, index| {
        const exact = entry.exact;
        const prefix = entry.prefix;
        if (exact != null and prefix != null) return error.InvalidInvariantDocument;
        if (exact) |value| {
            matchers[index] = .{ .tag = .exact, .value = value };
        } else if (prefix) |value| {
            matchers[index] = .{ .tag = .prefix, .value = value };
        } else return error.InvalidInvariantDocument;
        if (matchers[index].value.len == 0) return error.EmptyAccountMatcher;
        if (matchers[index].value.len > invariant.max_account_bytes) return error.AccountMatcherTooLong;
    }
    std.mem.sort(invariant.AccountMatcher, matchers, {}, struct {
        fn less(_: void, a: invariant.AccountMatcher, b: invariant.AccountMatcher) bool {
            return invariant.AccountMatcher.order(a, b) == .lt;
        }
    }.less);

    var size: usize = 2;
    for (matchers) |matcher| {
        size += invariant.account_matcher_header_size + matcher.value.len;
    }
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    std.mem.writeInt(u16, bytes[0..2], @intCast(matchers.len), .little);
    var cursor: usize = 2;
    for (matchers) |matcher| {
        bytes[cursor] = @intFromEnum(matcher.tag);
        std.mem.writeInt(u16, bytes[cursor + 1 ..][0..2], @intCast(matcher.value.len), .little);
        @memcpy(bytes[cursor + invariant.account_matcher_header_size ..][0..matcher.value.len], matcher.value);
        cursor += invariant.account_matcher_header_size + matcher.value.len;
    }
    // The decoder is the authority here too: an empty matcher, a duplicate, a
    // value that is not valid UTF-8, and a non-canonical order are all refused
    // by it rather than by a second opinion written above.
    _ = try invariant.decodeAccountMatchers(bytes);
    return bytes;
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
    writeCommon(bytes, doc, invariant.schema_version_v1, @intFromEnum(kind));
    _ = try invariant.decode(bytes);
    return bytes;
}

fn encodeV2(allocator: std.mem.Allocator, doc: Document) ![]u8 {
    if (doc.kind != null) return error.InvalidInvariantDocument;
    const entries = doc.kinds orelse return error.MissingInvariantKind;
    if (entries.len > invariant.max_kinds) return error.TooManyInvariantKinds;
    try validateCommon(doc);

    const kinds = try allocator.alloc(ResolvedKind, entries.len);
    var resolved: usize = 0;
    defer {
        for (kinds[0..resolved]) |row| allocator.free(row.payload);
        allocator.free(kinds);
    }
    for (entries, 0..) |entry, index| {
        const kind = std.meta.stringToEnum(invariant.Kind, entry.kind) orelse
            return error.UnsupportedInvariantKind;
        kinds[index] = .{ .kind = kind, .payload = try encodeKindPayload(allocator, kind, entry) };
        resolved += 1;
    }
    std.mem.sort(ResolvedKind, kinds, {}, struct {
        fn less(_: void, a: ResolvedKind, b: ResolvedKind) bool {
            return invariant.kindInfo(a.kind).wire_ordinal < invariant.kindInfo(b.kind).wire_ordinal;
        }
    }.less);

    var record_bytes: usize = 0;
    for (kinds) |row| {
        record_bytes += invariant.kind_record_header_size + row.payload.len;
    }

    const bytes = try allocator.alloc(u8, commonSize(doc) + record_bytes);
    errdefer allocator.free(bytes);
    writeCommon(bytes, doc, invariant.schema_version_v2, @intCast(entries.len));
    var cursor = commonSize(doc);
    for (kinds) |row| {
        std.mem.writeInt(u16, bytes[cursor..][0..2], invariant.kindInfo(row.kind).wire_ordinal, .little);
        std.mem.writeInt(u16, bytes[cursor + 2 ..][0..2], @intCast(row.payload.len), .little);
        @memcpy(bytes[cursor + invariant.kind_record_header_size ..][0..row.payload.len], row.payload);
        cursor += invariant.kind_record_header_size + row.payload.len;
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
    try std.testing.expectEqual(invariant.Schema.v2, std.meta.activeTag(decoded.kinds));
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

test "the schema 2 template canonicalizes a declared account set and refuses a weakened one" {
    const a = std.testing.allocator;
    const spec = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"prefix":"asset:"},{"exact":"clearing:main"}]}]}
    );
    defer a.free(spec);
    const decoded = try invariant.decode(spec);
    try std.testing.expectEqual(@as(u16, 2), decoded.kind_count);
    try std.testing.expect(try decoded.declares(.declared_accounts_v1));
    const payload = (try decoded.payloadFor(.declared_accounts_v1)) orelse
        return error.TestUnexpectedResult;
    const matchers = try invariant.decodeAccountMatchers(payload);
    // Listed prefix-first, encoded exact-first: the canonical order is the
    // matcher tag then the byte value, never the order the author typed.
    try std.testing.expectEqual(@as(u16, 2), matchers.count);
    try std.testing.expectEqual(invariant.AccountMatcherTag.exact, (try matchers.at(0)).tag);
    try std.testing.expectEqualStrings("clearing:main", (try matchers.at(0)).value);
    try std.testing.expectEqualStrings("asset:", (try matchers.at(1)).value);
    try std.testing.expect(try matchers.matches("asset:cash"));
    try std.testing.expect(!(try matchers.matches("assets:cash")));

    // The same set typed in the other order must produce the same bytes.
    const reordered = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"exact":"clearing:main"},{"prefix":"asset:"}]}]}
    );
    defer a.free(reordered);
    try std.testing.expectEqualSlices(u8, spec, reordered);

    // And so must the same kinds listed in the other order.
    const kinds_reordered = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"declared_accounts_v1","accounts":[{"prefix":"asset:"},{"exact":"clearing:main"}]},{"kind":"balance_conservation_v1"}]}
    );
    defer a.free(kinds_reordered);
    try std.testing.expectEqualSlices(u8, spec, kinds_reordered);
}

test "a declared account set must be present, non-empty, well formed, and free of repeats" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingAccountMatchers, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1"}]}
    ));
    try std.testing.expectError(error.EmptyAccountMatcherSet, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[]}]}
    ));
    try std.testing.expectError(error.EmptyAccountMatcher, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"prefix":""}]}]}
    ));
    try std.testing.expectError(error.InvalidInvariantDocument, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{}]}]}
    ));
    try std.testing.expectError(error.InvalidInvariantDocument, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"exact":"a","prefix":"a"}]}]}
    ));
    try std.testing.expectError(error.DuplicateAccountMatcher, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"exact":"a"},{"exact":"a"}]}]}
    ));
    // An exact and a prefix carrying the same bytes are two different rules.
    const both = try parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"exact":"a"},{"prefix":"a"}]}]}
    );
    defer a.free(both);
    try std.testing.expectError(error.InvalidAccountMatcher, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1"},{"kind":"declared_accounts_v1","accounts":[{"exact":"a\u0000b"}]}]}
    ));
}

test "balance conservation carries no payload and the closed schema carries no second kind" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedKindPayload, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"balance_conservation_v1","accounts":[{"exact":"a"}]}]}
    ));
    // Schema 1's header has room for one kind and its decoder admits only the
    // required one, so the optional kind is refused by name there.
    try std.testing.expectError(error.UnsupportedInvariantKind, parse(a,
        \\{"version":1,"kind":"declared_accounts_v1","ledger":"main","currencies":[{"code":"USD","scale":2}]}
    ));
    // A document naming only the optional kind is refused by the decoder.
    try std.testing.expectError(error.RequiredKindMissing, parse(a,
        \\{"version":2,"ledger":"main","currencies":[{"code":"USD","scale":2}],"kinds":[{"kind":"declared_accounts_v1","accounts":[{"exact":"a"}]}]}
    ));
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
