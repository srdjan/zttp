//! Stable identity for counterexample witnesses across edits.
//!
//! A witness is identified by `(property, origin_node_id?, sink_node_id?)`
//! at its ideal. When node IDs are unavailable the key falls back to
//! line/column. The autoloop orchestrator compares before/after witness
//! sets by these keys to decide `witnesses_defeated` vs `witnesses_new`
//! for each VerifiedPatch event.
//!
//! The actual hash computation lives on `counterexample.CounterexampleWitness.stableKey`
//! so that compiler-internal code can write a key without taking a `pi`
//! dependency. This module is the `pi`-side wrapper that allocates and
//! returns an owned hex-string slice - what the ledger payload stores.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const zts = @import("zts");
const counterexample = zts.counterexample;

/// Allocate the stable-key hex string for a witness. Caller owns the
/// returned slice.
pub fn forWitness(
    allocator: std.mem.Allocator,
    witness: counterexample.CounterexampleWitness,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try witness.stableKey(buf.writer());
    return buf.toOwnedSlice();
}

test "forWitness produces a 64-char hex digest" {
    const allocator = std.testing.allocator;
    var witness = try zts.solveCounterexample(allocator, .{
        .property = .no_secret_leakage,
        .origin = .{ .line = 3, .column = 1 },
        .sink = .{ .line = 5, .column = 12 },
        .origin_node_id = 7,
        .sink_node_id = 19,
        .summary = "t",
        .constraints = &.{},
        .io_calls = &.{},
    });
    defer witness.deinit(allocator);

    const key = try forWitness(allocator, witness);
    defer allocator.free(key);

    try std.testing.expectEqual(@as(usize, 64), key.len);
}
