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

/// Per-kind metadata for the closed invariant catalog.
///
/// The row is the one place a kind's wire identity, its confirmed sentence, and
/// its policy flags are stated. A consumer that needs one of those facts reads
/// it here instead of restating it locally.
pub const KindInfo = struct {
    /// The value this kind carries in the spec header's kind field.
    wire_ordinal: u16,
    /// The plain-language sentence a developer confirms when declaring the
    /// invariant. Authoring input, not acceptance authority.
    description: []const u8,
    /// The version of the predicate this kind names. A change of meaning that
    /// keeps the wire ordinal must raise this.
    predicate_version: u16,
    /// True when a consumer must see the kind discharged before acceptance.
    required: bool,
    /// True when the kind constrains operations that write.
    applies_to_writes: bool,
};

/// The catalog, keyed by `Kind`. `EnumArray.init` takes one field per member
/// and supplies no default, so a member added without a row fails to compile
/// here. A runtime check over a partly filled table would report a pass.
pub const kind_table = std.EnumArray(Kind, KindInfo).init(.{
    .balance_conservation_v1 = .{
        .wire_ordinal = 1,
        .description = "the sum of signed balances is zero within each ledger and currency after every committed posting group",
        .predicate_version = 1,
        .required = true,
        .applies_to_writes = true,
    },
});

pub fn kindInfo(kind: Kind) KindInfo {
    return kind_table.get(kind);
}

// A wire ordinal names a bit position in a per-kind mask. Distinct ordinals
// below 32 also bound the catalog at 32 members, so a 32-bit mask can be
// shifted by either the ordinal or the declaration index of any kind.
comptime {
    for (@typeInfo(Kind).@"enum".fields) |field| {
        const row = kind_table.get(@enumFromInt(field.value));
        if (row.wire_ordinal >= 32) {
            @compileError("invariant kind '" ++ field.name ++ "' has a wire ordinal at or above 32");
        }
    }
}

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

test "every invariant kind carries a metadata row that agrees with its wire ordinal" {
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const kind: Kind = @enumFromInt(field.value);
        const row = kindInfo(kind);
        try std.testing.expect(row.description.len > 0);
        try std.testing.expectEqual(@as(u16, field.value), row.wire_ordinal);
        try std.testing.expectEqual(@as(?Kind, kind), Kind.fromWire(row.wire_ordinal));
        try std.testing.expect(row.predicate_version >= 1);
    }
}

test "invariant kind wire ordinals are unique" {
    // A set bit per ordinal, shifted the way a per-kind mask is built. With one
    // kind the pairwise form would compare nothing, so the assertion runs once
    // per member and the floor below fails if the table is ever read as empty.
    var seen: u32 = 0;
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const row = kindInfo(@as(Kind, @enumFromInt(field.value)));
        const bit = @as(u32, 1) << @intCast(row.wire_ordinal);
        try std.testing.expectEqual(@as(u32, 0), seen & bit);
        seen |= bit;
    }
    try std.testing.expect(seen != 0);
}

test "balance conservation v1 is required, applies to writes, and states the confirmed sentence" {
    const row = kindInfo(.balance_conservation_v1);
    try std.testing.expectEqualStrings(
        "the sum of signed balances is zero within each ledger and currency after every committed posting group",
        row.description,
    );
    try std.testing.expectEqual(@as(u16, 1), row.wire_ordinal);
    try std.testing.expectEqual(@as(u16, 1), row.predicate_version);
    try std.testing.expect(row.required);
    try std.testing.expect(row.applies_to_writes);
}

test "the v1 specification digest of the canonical fixture is pinned" {
    // A literal, not a recomputation. A later wire schema must be shown not to
    // move this value, and a check that recomputes both sides would agree with
    // itself whatever the codec does.
    const bytes = magic.* ++ [_]u8{
        1, 0, // schema
        1, 0, // kind
        6, 0, // ledger id length
        2, 0, // currency count
    } ++ "ledger" ++ "EUR" ++ [_]u8{2} ++ "USD" ++ [_]u8{2};
    try std.testing.expectEqualStrings(
        "6a13f44159ddc5639abbcb92065b2ef846c9ff569b7fceee73b4d6393f83be74",
        &std.fmt.bytesToHex(digest(bytes), .lower),
    );
}

test "the native adapter digest is pinned" {
    // Unlike `digest`, this hash carries no domain prefix. The literal pins that
    // too, so adding one later is a visible change rather than a silent one.
    try std.testing.expectEqualStrings(
        "38190d83549a2f159b8c917b0a614856915358920ea73e831231a889db512c67",
        &std.fmt.bytesToHex(adapterDigest(), .lower),
    );
}
