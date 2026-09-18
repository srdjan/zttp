//! Deterministic authoring boundary for the confirmed invariant specification.
const std = @import("std");
const zts = @import("zts");
const invariant = @import("zttp_proof_checker").invariant;

const Currency = struct { code: []const u8, scale: u8 };
const Document = struct {
    version: u16,
    kind: []const u8,
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
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Document, allocator, source, .{});
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.version != invariant.schema_version) return error.UnsupportedInvariantVersion;
    if (!std.mem.eql(u8, doc.kind, "balance_conservation_v1")) return error.UnsupportedInvariantKind;
    if (doc.ledger.len == 0 or doc.ledger.len > invariant.max_ledger_id_bytes) return error.InvalidLedgerId;
    if (doc.currencies.len == 0 or doc.currencies.len > invariant.max_currencies) return error.InvalidCurrencies;
    std.mem.sort(Currency, doc.currencies, {}, struct {
        fn less(_: void, a: Currency, b: Currency) bool {
            return std.mem.lessThan(u8, a.code, b.code);
        }
    }.less);
    const bytes = try allocator.alloc(u8, invariant.header_size + doc.ledger.len + doc.currencies.len * invariant.currency_record_size);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..8], invariant.magic);
    std.mem.writeInt(u16, bytes[8..10], doc.version, .little);
    std.mem.writeInt(u16, bytes[10..12], @intFromEnum(invariant.Kind.balance_conservation_v1), .little);
    std.mem.writeInt(u16, bytes[12..14], @intCast(doc.ledger.len), .little);
    std.mem.writeInt(u16, bytes[14..16], @intCast(doc.currencies.len), .little);
    @memcpy(bytes[invariant.header_size..][0..doc.ledger.len], doc.ledger);
    for (doc.currencies, 0..) |currency, i| {
        if (currency.code.len != 3) return error.InvalidCurrency;
        const start = invariant.header_size + doc.ledger.len + i * invariant.currency_record_size;
        @memcpy(bytes[start..][0..3], currency.code);
        bytes[start + 3] = currency.scale;
    }
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
