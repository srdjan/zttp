//! Consumer-owned identities for application invariant enforcement.
//!
//! The plain-language sentence is authoring input. The canonical bytes decoded
//! here are the authority used for acceptance. The decoder is zero-copy and
//! allocation-free.

const std = @import("std");

pub const magic = "ZTINV1\x00\x00";

/// The original wire schema: one kind named in the header and nothing after
/// the currency records. Deployed artifacts and existing ledger stores are
/// bound to the digest of bytes carrying this value, so neither its layout nor
/// its digest domain may move.
pub const schema_version: u16 = 1;

/// The versioned payload set: the same ledger and currency region, followed by
/// a sorted, length-delimited record per declared kind. The header field that
/// schema 1 spends on its single kind carries the declared count here.
pub const schema_version_v2: u16 = 2;

pub const header_size: usize = 16;
pub const currency_record_size: usize = 4;
/// Wire ordinal u16 plus payload length u16, ahead of each payload.
pub const kind_record_header_size: usize = 4;
pub const max_spec_bytes: usize = 4096;
pub const max_ledger_id_bytes: usize = 64;
pub const max_currencies: u16 = 64;
pub const max_scale: u8 = 18;
/// A wire ordinal is a bit position below 32, so no canonical set holds more.
pub const max_kinds: u16 = 32;

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
    TooManyKinds,
    DuplicateKind,
    KindsNotOrdered,
    RequiredKindMissing,
    UnexpectedKindPayload,
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
// shifted by either the ordinal or the declaration index of any kind. Ordinal
// zero decodes to no kind, so the lowest member takes bit zero and `kindBit`
// below can subtract one without underflowing.
comptime {
    for (@typeInfo(Kind).@"enum".fields) |field| {
        const row = kind_table.get(@enumFromInt(field.value));
        if (row.wire_ordinal == 0) {
            @compileError("invariant kind '" ++ field.name ++ "' has wire ordinal zero, which decodes to no kind");
        }
        if (row.wire_ordinal >= 32) {
            @compileError("invariant kind '" ++ field.name ++ "' has a wire ordinal at or above 32");
        }
    }
}

// Exactly one kind is required. Two places lean on that and would stay quietly
// true rather than becoming false if the required set widened: `Spec.kind`,
// which a schema 2 decode fills with the conservation literal, and `decodeV1`,
// which admits the one kind schema 1's header has room for. Neither is wrong
// today, and neither would announce itself. This fires instead.
comptime {
    var required_kinds: usize = 0;
    for (@typeInfo(Kind).@"enum".fields) |field| {
        if (kind_table.get(@as(Kind, @enumFromInt(field.value))).required) required_kinds += 1;
    }
    if (required_kinds != 1) {
        @compileError("the invariant catalog must name exactly one required kind; Spec.kind and decodeV1 both read it as the only one");
    }
}

/// The bit a kind occupies in a per-kind mask.
fn kindBit(kind: Kind) u32 {
    return @as(u32, 1) << @intCast(kindInfo(kind).wire_ordinal - 1);
}

pub const Currency = struct {
    code: [3]u8,
    scale: u8,
};

/// One decoded specification, presented the same way whichever schema the
/// bytes carried. A consumer reads `kind_count`, `kindAt` and `payloadFor`
/// without asking which wire schema produced them.
pub const Spec = struct {
    /// The wire schema these bytes carried.
    schema: u16,
    /// The required kind. Schema 1 names it in the header; schema 2 must list
    /// it among the declared kinds, and the decoder refuses bytes that omit it.
    kind: Kind,
    ledger_id: []const u8,
    currency_bytes: []const u8,
    currency_count: u16,
    /// How many kinds the document declares. Always one under schema 1.
    kind_count: u16,
    /// The tagged payload records, borrowed from the caller's bytes. Empty
    /// under schema 1, where the single kind carries no payload region.
    kind_bytes: []const u8,

    pub fn currency(self: Spec, index: u16) DecodeError!Currency {
        if (index >= self.currency_count) return error.Truncated;
        const start = @as(usize, index) * currency_record_size;
        const record = self.currency_bytes[start..][0..currency_record_size];
        return .{ .code = record[0..3].*, .scale = record[3] };
    }

    /// The kind declared at `index`, in canonical wire-ordinal order.
    pub fn kindAt(self: Spec, index: u16) DecodeError!Kind {
        return (try self.recordAt(index)).kind;
    }

    /// The payload the document carries for `kind`, or null when it declares no
    /// such kind. A declared kind that carries no payload returns an empty
    /// slice, which is why the absent case is null rather than a zero length.
    ///
    /// A walk that cannot proceed is an error rather than a null: "the bytes
    /// could not be read" and "the document does not declare this kind" lead a
    /// caller to opposite conclusions, and collapsing them into null is how a
    /// missing obligation reads as a discharged one.
    pub fn payloadFor(self: Spec, kind: Kind) DecodeError!?[]const u8 {
        var index: u16 = 0;
        while (index < self.kind_count) : (index += 1) {
            const record = try self.recordAt(index);
            if (record.kind == kind) return record.payload;
        }
        return null;
    }

    pub fn declares(self: Spec, kind: Kind) DecodeError!bool {
        return (try self.payloadFor(kind)) != null;
    }

    const Record = struct { kind: Kind, payload: []const u8 };

    /// Walk the length-delimited records. `decode` has already bounded every
    /// length, so the checks here cannot fire on bytes it returned; they keep
    /// the walk total for a `Spec` built any other way.
    fn recordAt(self: Spec, index: u16) DecodeError!Record {
        if (index >= self.kind_count) return error.Truncated;
        if (self.schema != schema_version_v2) {
            return .{ .kind = self.kind, .payload = self.kind_bytes[0..0] };
        }
        var cursor: usize = 0;
        var position: u16 = 0;
        while (position <= index) : (position += 1) {
            if (cursor + kind_record_header_size > self.kind_bytes.len) return error.Truncated;
            const ordinal = std.mem.readInt(u16, self.kind_bytes[cursor..][0..2], .little);
            const length = std.mem.readInt(u16, self.kind_bytes[cursor + 2 ..][0..2], .little);
            const body = cursor + kind_record_header_size;
            if (body + length > self.kind_bytes.len) return error.Truncated;
            if (position == index) {
                const kind = Kind.fromWire(ordinal) orelse return error.UnknownInvariantKind;
                return .{ .kind = kind, .payload = self.kind_bytes[body..][0..length] };
            }
            cursor = body + length;
        }
        return error.Truncated;
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

/// The payload shape each kind carries under schema 2. The switch is
/// exhaustive, so a kind added to the catalog without a rule here fails to
/// compile rather than accepting whatever bytes the record happens to hold.
fn validateKindPayload(kind: Kind, payload: []const u8) DecodeError!void {
    switch (kind) {
        .balance_conservation_v1 => if (payload.len != 0) return error.UnexpectedKindPayload,
    }
}

/// The header counts, bounded but not yet matched against the byte length.
const Counts = struct {
    ledger_len: u16,
    currency_count: u16,
    /// One past the last currency record.
    common_end: usize,
};

fn decodeCounts(bytes: []const u8) DecodeError!Counts {
    const ledger_len = std.mem.readInt(u16, bytes[12..14], .little);
    const currency_count = std.mem.readInt(u16, bytes[14..16], .little);
    if (ledger_len == 0) return error.EmptyLedgerId;
    if (ledger_len > max_ledger_id_bytes) return error.InvalidLedgerId;
    if (currency_count == 0) return error.EmptyCurrencySet;
    if (currency_count > max_currencies) return error.TooManyCurrencies;
    return .{
        .ledger_len = ledger_len,
        .currency_count = currency_count,
        .common_end = header_size + @as(usize, ledger_len) +
            @as(usize, currency_count) * currency_record_size,
    };
}

const Common = struct {
    ledger_id: []const u8,
    currency_bytes: []const u8,
};

/// The ledger identifier and the sorted currency records, shared byte for byte
/// by both schemas. The caller has already placed `counts.common_end` inside
/// `bytes`.
fn decodeCommon(bytes: []const u8, counts: Counts) DecodeError!Common {
    const ledger_id = bytes[header_size..][0..counts.ledger_len];
    for (ledger_id) |byte| {
        if (!validLedgerByte(byte)) return error.InvalidLedgerId;
    }

    const currency_bytes = bytes[header_size + counts.ledger_len .. counts.common_end];
    var previous: ?[3]u8 = null;
    var index: u16 = 0;
    while (index < counts.currency_count) : (index += 1) {
        const start = @as(usize, index) * currency_record_size;
        const code: [3]u8 = currency_bytes[start..][0..3].*;
        if (!validCurrencyCode(code)) return error.InvalidCurrency;
        if (currency_bytes[start + 3] > max_scale) return error.InvalidScale;
        if (previous) |prior| {
            if (std.mem.order(u8, &prior, &code) != .lt) return error.CurrenciesNotOrdered;
        }
        previous = code;
    }
    return .{ .ledger_id = ledger_id, .currency_bytes = currency_bytes };
}

/// Decode canonical invariant specification bytes.
///
/// Schema 1: magic[8], schema u16, kind u16, ledger length u16, currency count
/// u16, ledger bytes, then sorted records of ISO-style code[3] + scale. These
/// bytes and the digest taken over them are fixed by deployed artifacts.
///
/// Schema 2: the same header with the kind field spent on the declared kind
/// count, the same ledger and currency region, then that many records of wire
/// ordinal u16 + payload length u16 + payload, ascending by ordinal.
pub fn decode(bytes: []const u8) DecodeError!Spec {
    if (bytes.len > max_spec_bytes) return error.SpecTooLarge;
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadMagic;
    return switch (std.mem.readInt(u16, bytes[8..10], .little)) {
        schema_version => decodeV1(bytes),
        schema_version_v2 => decodeV2(bytes),
        else => error.UnsupportedSchemaVersion,
    };
}

fn decodeV1(bytes: []const u8) DecodeError!Spec {
    const kind = Kind.fromWire(std.mem.readInt(u16, bytes[10..12], .little)) orelse
        return error.UnknownInvariantKind;
    // The required kind is mandatory under both schemas, and schema 1's header
    // has room for exactly one, so the one it names must be that kind. Without
    // this the rule rests on `fromWire` knowing a single ordinal: the day the
    // catalog grows, schema 1 bytes naming the new kind would decode to a
    // specification with no conservation, and the consumer would accept them.
    // No test reaches this while the catalog holds one kind, which is why it is
    // written here rather than left to the encoder that a consumer never runs.
    if (!kindInfo(kind).required) return error.RequiredKindMissing;
    const counts = try decodeCounts(bytes);
    if (bytes.len < counts.common_end) return error.Truncated;
    if (bytes.len > counts.common_end) return error.TrailingData;
    const common = try decodeCommon(bytes, counts);
    return .{
        .schema = schema_version,
        .kind = kind,
        .ledger_id = common.ledger_id,
        .currency_bytes = common.currency_bytes,
        .currency_count = counts.currency_count,
        .kind_count = 1,
        .kind_bytes = bytes[counts.common_end..],
    };
}

fn decodeV2(bytes: []const u8) DecodeError!Spec {
    const kind_count = std.mem.readInt(u16, bytes[10..12], .little);
    if (kind_count > max_kinds) return error.TooManyKinds;
    const counts = try decodeCounts(bytes);
    if (bytes.len < counts.common_end) return error.Truncated;
    const common = try decodeCommon(bytes, counts);
    const kind_bytes = bytes[counts.common_end..];

    // First pass: record framing and canonical order, read from the raw
    // ordinals. Order is a property of the bytes, so a descending pair is
    // refused as non-canonical even when neither ordinal names a catalog kind.
    var cursor: usize = 0;
    var previous: ?u16 = null;
    var index: u16 = 0;
    while (index < kind_count) : (index += 1) {
        if (cursor + kind_record_header_size > kind_bytes.len) return error.Truncated;
        const ordinal = std.mem.readInt(u16, kind_bytes[cursor..][0..2], .little);
        const length = std.mem.readInt(u16, kind_bytes[cursor + 2 ..][0..2], .little);
        if (previous) |prior| {
            if (ordinal == prior) return error.DuplicateKind;
            if (ordinal < prior) return error.KindsNotOrdered;
        }
        previous = ordinal;
        const body = cursor + kind_record_header_size;
        if (body + length > kind_bytes.len) return error.Truncated;
        cursor = body + length;
    }
    if (cursor != kind_bytes.len) return error.TrailingData;

    const spec = Spec{
        .schema = schema_version_v2,
        .kind = .balance_conservation_v1,
        .ledger_id = common.ledger_id,
        .currency_bytes = common.currency_bytes,
        .currency_count = counts.currency_count,
        .kind_count = kind_count,
        .kind_bytes = kind_bytes,
    };

    // Second pass: catalog membership and payload shape, then the kinds a
    // consumer must see declared before it accepts anything.
    var declared: u32 = 0;
    index = 0;
    while (index < kind_count) : (index += 1) {
        const record = try spec.recordAt(index);
        try validateKindPayload(record.kind, record.payload);
        declared |= kindBit(record.kind);
    }
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        const member: Kind = @enumFromInt(field.value);
        if (kindInfo(member).required and declared & kindBit(member) == 0) {
            return error.RequiredKindMissing;
        }
    }
    return spec;
}

pub const digest_domain = "zttp-invariant-spec-v1";

/// Schema 2 hashes under its own domain, so the same ledger declared under the
/// two schemas cannot collide, and an older consumer's digest cannot name a
/// document it would not have decoded.
pub const digest_domain_v2 = "zttp-invariant-spec-v2";

/// The domain these bytes hash under, selected from the schema they carry.
/// Bytes too short to carry a schema, and any schema this build does not own,
/// fall back to the schema 1 domain, which leaves every digest ever computed
/// over schema 1 bytes exactly where it was.
pub fn digestDomain(bytes: []const u8) []const u8 {
    if (bytes.len < 10) return digest_domain;
    return switch (std.mem.readInt(u16, bytes[8..10], .little)) {
        schema_version_v2 => digest_domain_v2,
        else => digest_domain,
    };
}

pub fn digest(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(digestDomain(bytes));
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

// ---------------------------------------------------------------------------
// Schema 2 fixtures. Each refusal below spells its own bytes out so the
// mutation under test is visible beside the error it must produce.
// ---------------------------------------------------------------------------

/// The ledger and currency region shared by both schemas, under a schema 2
/// header. The declared kind count sits where schema 1 keeps its single kind.
const v2_header_and_common = magic.* ++ [_]u8{
    2, 0, // schema
    1, 0, // declared kind count
    6, 0, // ledger id length
    1, 0, // currency count
} ++ "ledger" ++ "USD" ++ [_]u8{2};

/// A schema 2 document: that region followed by one length-delimited record
/// per declared kind.
const v2_fixture = v2_header_and_common ++ [_]u8{
    1, 0, // balance_conservation_v1
    0, 0, // payload length
};

/// The schema 1 document the pinned digest above is taken over.
const v1_fixture = magic.* ++ [_]u8{
    1, 0, // schema
    1, 0, // kind
    6, 0, // ledger id length
    2, 0, // currency count
} ++ "ledger" ++ "EUR" ++ [_]u8{2} ++ "USD" ++ [_]u8{2};

test "a schema 2 specification decodes the same ledger and currency region as schema 1" {
    const spec = try decode(v2_fixture);
    try std.testing.expectEqual(@as(u16, 2), spec.schema);
    try std.testing.expectEqual(Kind.balance_conservation_v1, spec.kind);
    try std.testing.expectEqualStrings("ledger", spec.ledger_id);
    try std.testing.expectEqual(@as(u16, 1), spec.currency_count);
    try std.testing.expectEqualSlices(u8, "USD", &(try spec.currency(0)).code);
    try std.testing.expectEqual(@as(u8, 2), (try spec.currency(0)).scale);
}

test "a schema 2 specification presents its declared kinds and their payloads" {
    const spec = try decode(v2_fixture);
    try std.testing.expectEqual(@as(u16, 1), spec.kind_count);
    try std.testing.expectEqual(Kind.balance_conservation_v1, try spec.kindAt(0));
    try std.testing.expectError(error.Truncated, spec.kindAt(1));
    try std.testing.expect(try spec.declares(.balance_conservation_v1));
    const payload = (try spec.payloadFor(.balance_conservation_v1)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), payload.len);
}

test "a schema 1 specification presents the same kind view as schema 2" {
    // A consumer that reads the kind set must not branch on the schema. The
    // schema 1 document names one kind, so it reports one, at index zero, with
    // no payload, exactly as the schema 2 document above does.
    const spec = try decode(v1_fixture);
    try std.testing.expectEqual(@as(u16, 1), spec.schema);
    try std.testing.expectEqual(@as(u16, 1), spec.kind_count);
    try std.testing.expectEqual(Kind.balance_conservation_v1, try spec.kindAt(0));
    try std.testing.expectError(error.Truncated, spec.kindAt(1));
    try std.testing.expect(try spec.declares(.balance_conservation_v1));
    const payload = (try spec.payloadFor(.balance_conservation_v1)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), payload.len);
}

test "the specification digest domain follows the wire schema the bytes carry" {
    // Both sides recompute the v1 domain's hash here rather than asking
    // `digest` for it a second time. A `digest` that ignored the schema would
    // agree with the recomputation on the schema 2 bytes, and a `digest` that
    // changed the schema 1 domain would disagree with it on the schema 1 bytes.
    var v1_under_v1_domain: [32]u8 = undefined;
    var v1_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    v1_hasher.update("zttp-invariant-spec-v1");
    v1_hasher.update(v1_fixture);
    v1_hasher.final(&v1_under_v1_domain);
    try std.testing.expectEqualSlices(u8, &v1_under_v1_domain, &digest(v1_fixture));

    var v2_under_v1_domain: [32]u8 = undefined;
    var v2_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    v2_hasher.update("zttp-invariant-spec-v1");
    v2_hasher.update(v2_fixture);
    v2_hasher.final(&v2_under_v1_domain);
    try std.testing.expect(!std.mem.eql(u8, &v2_under_v1_domain, &digest(v2_fixture)));
}

test "a schema 2 specification refuses a repeated kind record" {
    const repeated = magic.* ++ [_]u8{
        2, 0, // schema
        2, 0, // declared kind count
        6, 0, // ledger id length
        1, 0, // currency count
    } ++ "ledger" ++ "USD" ++ [_]u8{2} ++ [_]u8{
        1, 0, 0, 0, // balance_conservation_v1
        1, 0, 0, 0, // the same ordinal again
    };
    try std.testing.expectError(error.DuplicateKind, decode(repeated));
}

test "a schema 2 specification refuses kind records out of canonical order" {
    // The ordering check reads the raw ordinal before the catalog lookup, so a
    // descending pair is refused as non-canonical rather than as an unknown
    // kind. Ordinal 2 names no catalog member yet, which is what makes the
    // descending pair expressible while the catalog holds one kind.
    const descending = magic.* ++ [_]u8{
        2, 0, // schema
        2, 0, // declared kind count
        6, 0, // ledger id length
        1, 0, // currency count
    } ++ "ledger" ++ "USD" ++ [_]u8{2} ++ [_]u8{
        2, 0, 0, 0, // ordinal 2 first
        1, 0, 0, 0, // then ordinal 1
    };
    try std.testing.expectError(error.KindsNotOrdered, decode(descending));
}

test "a schema 2 specification refuses a kind the catalog does not name" {
    const unknown = v2_header_and_common ++ [_]u8{
        2, 0, 0, 0, // an ordinal the closed catalog does not name
    };
    try std.testing.expectError(error.UnknownInvariantKind, decode(unknown));
}

test "a schema 2 specification refuses a kind set without balance conservation" {
    const empty = magic.* ++ [_]u8{
        2, 0, // schema
        0, 0, // declared kind count
        6, 0, // ledger id length
        1, 0, // currency count
    } ++ "ledger" ++ "USD" ++ [_]u8{2};
    try std.testing.expectError(error.RequiredKindMissing, decode(empty));
}

test "a schema 2 specification refuses a payload length that runs past the end" {
    const overrun = v2_header_and_common ++ [_]u8{
        1, 0, // balance_conservation_v1
        4, 0, // a payload length with no payload behind it
    };
    try std.testing.expectError(error.Truncated, decode(overrun));

    const short_record = v2_header_and_common ++ [_]u8{ 1, 0 };
    try std.testing.expectError(error.Truncated, decode(short_record));
}

test "a schema 2 specification refuses bytes after the last kind record" {
    const trailing = v2_fixture ++ [_]u8{0xff};
    try std.testing.expectError(error.TrailingData, decode(trailing));
}

test "a schema 2 specification refuses a payload on a kind that carries none" {
    const payloaded = v2_header_and_common ++ [_]u8{
        1, 0, // balance_conservation_v1
        1,    0, // one payload byte
        0x2a,
    };
    try std.testing.expectError(error.UnexpectedKindPayload, decode(payloaded));
}

test "a specification past the size bound is refused before it is parsed" {
    var oversize: [max_spec_bytes + 1]u8 = undefined;
    @memset(&oversize, 0);
    @memcpy(oversize[0..8], magic);
    std.mem.writeInt(u16, oversize[8..10], schema_version_v2, .little);
    try std.testing.expectError(error.SpecTooLarge, decode(&oversize));
}

test "the two wire schemas are distinct and schema 1 stays pinned at one" {
    // Deployed artifacts and existing ledger stores are bound to the digest of
    // schema 1 bytes. Moving this constant would change every one of them.
    try std.testing.expectEqual(@as(u16, 1), schema_version);
    try std.testing.expectEqual(@as(u16, 2), schema_version_v2);
    const future = magic.* ++ [_]u8{
        3, 0, // a schema neither decoder owns
        1, 0,
        6, 0,
        1, 0,
    } ++ "ledger" ++ "USD" ++ [_]u8{2};
    try std.testing.expectError(error.UnsupportedSchemaVersion, decode(future));
}
