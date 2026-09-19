//! The bridge between the adapter this binary linked and the adapter the
//! acceptance kernel expects.
//!
//! The executable graph commits to a protected-ledger adapter. Before this
//! file existed, the producer bound that member from `pcc.invariant`'s own
//! constant and the consumer compared it against the same function, so an
//! artifact whose specification named a kind the linked adapter did not
//! enforce was undetectable: the comparison had one source.
//!
//! Here the member is built from `zts.modules.ledger.adapter_manifest`, which
//! the native module derives at compile time from the dispatch table its two
//! enforcement paths iterate. The kernel's encoder hashes it, because both
//! sides must agree on the encoding for the digests to be comparable at all,
//! but no *value* in the manifest is read from the kernel. The kernel's
//! `expected_adapter_manifest` supplies the other side of the comparison.
//!
//! What a match establishes: the linked adapter names the same identity, keeps
//! the same store schema, publishes the same exports, and dispatches a
//! predicate for every kind the catalog names, at the version it names. Since
//! the serving binary recomputes this from its own linked adapter, a binary
//! older than the artifact fails to reproduce the member and the artifact is
//! refused.
//!
//! What it cannot establish: that any predicate in the table is correct. A row
//! whose function decides the wrong thing produces exactly the digest a right
//! one does. Only the predicate's own tests close that.

const std = @import("std");
const zq = @import("zts");
const pcc = @import("zttp_proof_checker");

const native = zq.modules.ledger;

pub const Error = error{
    /// The linked adapter is not the one the acceptance kernel expects.
    InvariantAdapterMismatch,
};

/// The linked adapter's manifest, in the kernel's type.
///
/// Field for field from the native module. The conversion exists because the
/// two packages own their own types - the native module must not import the
/// kernel, which is a leaf - not because any value is reinterpreted.
pub const linked_manifest: pcc.invariant.AdapterManifest = .{
    .identity = native.adapter_manifest.identity,
    .store_schema_version = native.adapter_manifest.store_schema_version,
    .predicates = &linked_predicates,
    .exports = native.adapter_manifest.exports,
};

const linked_predicates = blk: {
    var rows: [native.adapter_manifest.predicates.len]pcc.invariant.AdapterPredicate = undefined;
    for (native.adapter_manifest.predicates, 0..) |row, index| {
        rows[index] = .{
            .kind_ordinal = row.kind_ordinal,
            .predicate_version = row.predicate_version,
        };
    }
    const frozen = rows;
    break :blk frozen;
};

/// The executable-graph member for the adapter this binary linked.
pub fn linkedDigest() [32]u8 {
    return pcc.invariant.adapterManifestDigest(linked_manifest);
}

/// Refuse a manifest the acceptance kernel would not accept.
///
/// Total over the manifest, allocation-free, and free of any side effect, so a
/// caller can run it before it commits to anything. The runtime calls it with
/// `linked_manifest` ahead of installing the ledger store: a store installed
/// first and refused afterwards would have already opened and validated a
/// database under an adapter the consumer does not accept.
pub fn require(manifest: pcc.invariant.AdapterManifest) Error!void {
    const actual = pcc.invariant.adapterManifestDigest(manifest);
    const expected = pcc.invariant.adapterDigest();
    if (!std.mem.eql(u8, &actual, &expected)) return error.InvariantAdapterMismatch;
}

/// `require` over the adapter this binary actually linked.
pub fn requireLinked() Error!void {
    return require(linked_manifest);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A copy of the linked manifest, so a test can mutate one field of something
/// that is otherwise honest. Mutating a copy of the *real* value is the point:
/// a hand-built manifest that differs everywhere would be refused by a
/// comparison that checks nothing in particular.
fn copyOfLinked(predicates: []const pcc.invariant.AdapterPredicate) pcc.invariant.AdapterManifest {
    return .{
        .identity = linked_manifest.identity,
        .store_schema_version = linked_manifest.store_schema_version,
        .predicates = predicates,
        .exports = linked_manifest.exports,
    };
}

test "the linked adapter manifest digests to what the acceptance kernel expects" {
    // The floor. Without it every refusal below would also pass on a
    // comparison that is unequal for every input, and no real deployment
    // would ever start.
    try testing.expectEqualSlices(u8, &pcc.invariant.adapterDigest(), &linkedDigest());
    try requireLinked();
}

test "the linked manifest restates the native module field for field" {
    // The conversion is the one place a value could be dropped on the way to
    // the kernel's type, and a dropped value would hash consistently on both
    // sides of this process while disagreeing with every other build.
    try testing.expectEqualStrings(native.adapter_manifest.identity, linked_manifest.identity);
    try testing.expectEqual(native.adapter_manifest.store_schema_version, linked_manifest.store_schema_version);
    try testing.expectEqual(native.adapter_manifest.predicates.len, linked_manifest.predicates.len);
    for (native.adapter_manifest.predicates, linked_manifest.predicates) |from, to| {
        try testing.expectEqual(from.kind_ordinal, to.kind_ordinal);
        try testing.expectEqual(from.predicate_version, to.predicate_version);
    }
    try testing.expectEqual(native.adapter_manifest.exports.len, linked_manifest.exports.len);
    for (native.adapter_manifest.exports, linked_manifest.exports) |from, to| {
        try testing.expectEqualStrings(from, to);
    }
    try testing.expect(linked_manifest.predicates.len > 0);
    try testing.expect(linked_manifest.exports.len > 0);
}

test "an adapter manifest missing a predicate row is refused" {
    const short = copyOfLinked(linked_manifest.predicates[0 .. linked_manifest.predicates.len - 1]);
    try testing.expectError(error.InvariantAdapterMismatch, require(short));
}

test "an adapter manifest at a different predicate version is refused" {
    var rows: [linked_manifest.predicates.len]pcc.invariant.AdapterPredicate =
        linked_manifest.predicates[0..linked_manifest.predicates.len].*;
    rows[0].predicate_version += 1;
    try testing.expectError(error.InvariantAdapterMismatch, require(copyOfLinked(&rows)));
}

test "an adapter manifest at a different store schema version is refused" {
    var manifest = linked_manifest;
    manifest.store_schema_version += 1;
    try testing.expectError(error.InvariantAdapterMismatch, require(manifest));
}

test "an adapter manifest with a different export set or identity is refused" {
    var renamed = linked_manifest;
    renamed.identity = "zttp:ledger/native-adapter-v0";
    try testing.expectError(error.InvariantAdapterMismatch, require(renamed));

    var without_exports = linked_manifest;
    without_exports.exports = &.{};
    try testing.expectError(error.InvariantAdapterMismatch, require(without_exports));
}

test "the adapter member is not the bare hash of the identity string" {
    // The shape this task replaced. If the graph member ever returns to it,
    // the producer and the consumer are once again reading one constant.
    var bare: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(linked_manifest.identity, &bare, .{});
    try testing.expect(!std.mem.eql(u8, &bare, &linkedDigest()));
}
