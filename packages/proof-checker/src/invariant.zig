//! Consumer-owned identities for application invariant enforcement.
//!
//! The plain-language sentence is authoring input. The canonical bytes decoded
//! here are the authority used for acceptance. The decoder is zero-copy and
//! allocation-free.

const std = @import("std");

pub const magic = "ZTINV1\x00\x00";
pub const schema_version: u16 = 1;
pub const header_size: usize = 16;
pub const currency_record_size: usize = 4;
pub const max_spec_bytes: usize = 4096;
pub const max_ledger_id_bytes: usize = 64;
pub const max_currencies: u16 = 64;
pub const max_scale: u8 = 18;

pub const DecodeError = error{
    SpecTooLarge,
    Truncated,
    BadMagic,
    UnsupportedSchemaVersion,
    UnknownInvariantKind,
    EmptyLedgerId,
    InvalidLedgerId,
    EmptyCurrencySet,
    TooManyCurrencies,
    InvalidCurrency,
    InvalidScale,
    CurrenciesNotOrdered,
    TrailingData,
};

pub const Kind = enum(u16) {
    balance_conservation_v1 = 1,

    pub fn fromWire(value: u16) ?Kind {
        return switch (value) {
            1 => .balance_conservation_v1,
            else => null,
        };
    }
};

pub const Currency = struct {
    code: [3]u8,
    scale: u8,
};

pub const Spec = struct {
    kind: Kind,
    ledger_id: []const u8,
    currency_bytes: []const u8,
    currency_count: u16,

    pub fn currency(self: Spec, index: u16) DecodeError!Currency {
        if (index >= self.currency_count) return error.Truncated;
        const start = @as(usize, index) * currency_record_size;
        const record = self.currency_bytes[start..][0..currency_record_size];
        return .{ .code = record[0..3].*, .scale = record[3] };
    }
};

fn validLedgerByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
}

fn validCurrencyCode(code: [3]u8) bool {
    for (code) |byte| {
        if (byte < 'A' or byte > 'Z') return false;
    }
    return true;
}

/// Decode canonical `balance_conservation_v1` bytes.
///
/// Wire layout: magic[8], schema u16, kind u16, ledger length u16, currency
/// count u16, ledger bytes, then sorted records of ISO-style code[3] + scale.
pub fn decode(bytes: []const u8) DecodeError!Spec {
    if (bytes.len > max_spec_bytes) return error.SpecTooLarge;
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, bytes[8..10], .little) != schema_version) {
        return error.UnsupportedSchemaVersion;
    }
    const kind = Kind.fromWire(std.mem.readInt(u16, bytes[10..12], .little)) orelse
        return error.UnknownInvariantKind;
    const ledger_len = std.mem.readInt(u16, bytes[12..14], .little);
    const currency_count = std.mem.readInt(u16, bytes[14..16], .little);
    if (ledger_len == 0) return error.EmptyLedgerId;
    if (ledger_len > max_ledger_id_bytes) return error.InvalidLedgerId;
    if (currency_count == 0) return error.EmptyCurrencySet;
    if (currency_count > max_currencies) return error.TooManyCurrencies;

    const expected = header_size + @as(usize, ledger_len) +
        @as(usize, currency_count) * currency_record_size;
    if (bytes.len < expected) return error.Truncated;
    if (bytes.len > expected) return error.TrailingData;

    const ledger_id = bytes[header_size..][0..ledger_len];
    for (ledger_id) |byte| {
        if (!validLedgerByte(byte)) return error.InvalidLedgerId;
    }

    const currency_bytes = bytes[header_size + ledger_len ..];
    var previous: ?[3]u8 = null;
    var index: u16 = 0;
    while (index < currency_count) : (index += 1) {
        const start = @as(usize, index) * currency_record_size;
        const code: [3]u8 = currency_bytes[start..][0..3].*;
        if (!validCurrencyCode(code)) return error.InvalidCurrency;
        if (currency_bytes[start + 3] > max_scale) return error.InvalidScale;
        if (previous) |prior| {
            if (std.mem.order(u8, &prior, &code) != .lt) return error.CurrenciesNotOrdered;
        }
        previous = code;
    }

    return .{
        .kind = kind,
        .ledger_id = ledger_id,
        .currency_bytes = currency_bytes,
        .currency_count = currency_count,
    };
}

pub const digest_domain = "zttp-invariant-spec-v1";

pub fn digest(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(digest_domain);
    hasher.update(bytes);
    return hasher.finalResult();
}

/// The native adapter identity the consumer expects for v1.
pub const adapter_identity = "zttp:ledger/native-adapter-v1";

pub fn adapterDigest() [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(adapter_identity, &out, .{});
    return out;
}

pub const Operation = enum(u8) {
    post = 1,
    balance = 2,

    pub fn fromWire(value: u8) ?Operation {
        return switch (value) {
            1 => .post,
            2 => .balance,
            else => null,
        };
    }
};

pub const SinkId = enum(u8) {
    ledger_post = 1,
    ledger_balance = 2,

    pub fn fromWire(value: u8) ?SinkId {
        return switch (value) {
            1 => .ledger_post,
            2 => .ledger_balance,
            else => null,
        };
    }
};

pub const CatalogEntry = struct {
    operation: Operation,
    sink: SinkId,
    impl_id: u32,
    writes: bool,
};

/// The operation identity comes from the catalog index stored in proof IR.
/// Implementation ids change when the authoritative native boundary changes.
pub const catalog = [_]CatalogEntry{
    .{ .operation = .post, .sink = .ledger_post, .impl_id = 0x4c50_0001, .writes = true },
    .{ .operation = .balance, .sink = .ledger_balance, .impl_id = 0x4c42_0001, .writes = false },
};

/// One native operation independently decoded from final bytecode by the
/// consumer-side loader. The checker relates it to proof IR through the
/// certificate's translation witness.
pub const ObservedOperation = struct {
    function_ordinal: u32,
    code_offset: u32,
    operation: Operation,

    pub fn order(a: ObservedOperation, b: ObservedOperation) std.math.Order {
        if (a.function_ordinal != b.function_ordinal) return std.math.order(a.function_ordinal, b.function_ordinal);
        if (a.code_offset != b.code_offset) return std.math.order(a.code_offset, b.code_offset);
        return std.math.order(@intFromEnum(a.operation), @intFromEnum(b.operation));
    }
};

test "canonical invariant spec decodes without allocation" {
    const bytes = magic.* ++ [_]u8{
        1, 0, // schema
        1, 0, // kind
        6, 0, // ledger id length
        2, 0, // currency count
    } ++ "ledger" ++ "EUR" ++ [_]u8{2} ++ "USD" ++ [_]u8{2};
    const spec = try decode(bytes);
    try std.testing.expectEqual(Kind.balance_conservation_v1, spec.kind);
    try std.testing.expectEqualStrings("ledger", spec.ledger_id);
    try std.testing.expectEqualSlices(u8, "EUR", &(try spec.currency(0)).code);
    try std.testing.expectEqual(@as(u8, 2), (try spec.currency(1)).scale);
}

test "invariant spec refuses duplicate and unsorted currencies" {
    const prefix = magic.* ++ [_]u8{ 1, 0, 1, 0, 1, 0, 2, 0 } ++ "x";
    const duplicate = prefix ++ "USD" ++ [_]u8{2} ++ "USD" ++ [_]u8{2};
    try std.testing.expectError(error.CurrenciesNotOrdered, decode(duplicate));
    const unsorted = prefix ++ "USD" ++ [_]u8{2} ++ "EUR" ++ [_]u8{2};
    try std.testing.expectError(error.CurrenciesNotOrdered, decode(unsorted));
}

test "catalog is nonempty and wire identities round trip" {
    try std.testing.expect(catalog.len > 0);
    inline for (@typeInfo(Operation).@"enum".fields) |field| {
        const operation: Operation = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?Operation, operation), Operation.fromWire(field.value));
    }
    inline for (@typeInfo(SinkId).@"enum".fields) |field| {
        const sink: SinkId = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(?SinkId, sink), SinkId.fromWire(field.value));
    }
}
