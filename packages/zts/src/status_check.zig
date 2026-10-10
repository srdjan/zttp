//! The status-comparison rule for `ok`-record calls such as `fetch`.
//!
//! A handler can test `res.status !== 200` instead of `!res.ok`. This file
//! decides, from the comparison alone, whether that test splits the response
//! into the same two sides as `res.ok`, and which status a stub must carry to
//! take each side. It reads no IR: callers recognize the comparison, build a
//! `Comparison`, and ask here. The fault-coverage path generator uses it, and
//! the flow checker's witness search will use the same rule.
//!
//! `ok` is `200 <= status < 300`. `fetch` does not follow redirects, so a 3xx
//! reaches the handler with `ok` false. A comparison therefore stands in for
//! `ok` only when it sends every status outside 2xx to one side and status 200
//! to the other.

const std = @import("std");

/// The lowest and highest status that a response can carry.
pub const min_status: u16 = 100;
pub const max_status: u16 = 599;

/// The status of the success stub, and of the failure stub, in
/// `path_generator.zig`. The failure stub is the probe for the failure side.
pub const success_status: u16 = 200;
pub const failure_status: u16 = 503;

pub const Op = enum { eq, neq, lt, lte, gt, gte };

/// `status OP literal`, or `literal OP status` when `literal_left` is true.
pub const Comparison = struct {
    op: Op,
    literal: f64,
    literal_left: bool,
};

/// A comparison that must take the value `expect`.
pub const Requirement = struct {
    comparison: Comparison,
    expect: bool,
};

/// The value of the comparison at one status, in source operand order.
pub fn holds(c: Comparison, status: u16) bool {
    const s: f64 = @floatFromInt(status);
    const a = if (c.literal_left) c.literal else s;
    const b = if (c.literal_left) s else c.literal;
    return switch (c.op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .lte => a <= b,
        .gt => a > b,
        .gte => a >= b,
    };
}

/// Whether a response with this status has `ok` true.
pub fn isOkStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

pub const Class = union(enum) {
    /// The comparison takes the same value at every status in 100..599, so no
    /// branch differs and no path is worth recording.
    constant,
    /// The comparison splits the statuses, but not along `ok`.
    plain,
    /// The comparison is the complement of `ok`, up to status 200. The payload
    /// is the comparison's value on the failure side (status 503).
    fork: bool,
};

/// Classify a comparison. A fork needs the value at 200 to differ from the
/// value at 503, and the value at every status in 100..199 and 300..599 to
/// equal the value at 503. Statuses 201..299 are not checked: they are `ok`
/// responses that the comparison may send to either side.
pub fn classify(c: Comparison) Class {
    const failure_side = holds(c, failure_status);
    var varies = false;
    var fork = holds(c, success_status) != failure_side;
    var status: u16 = min_status;
    while (status <= max_status) : (status += 1) {
        if (holds(c, status) != failure_side) varies = true;
        if (status >= 200 and status < 300) continue;
        if (holds(c, status) != failure_side) fork = false;
    }
    if (!varies) return .constant;
    return if (fork) .{ .fork = failure_side } else .plain;
}

/// The status that a stub for this call should carry, so that the response is
/// `ok` as `ok_state` says (null: not constrained) and every requirement
/// holds. The canonical statuses come first (200, or 503 for a failed
/// response), so a path with no status test keeps the stub it always had.
/// Returns null when no status satisfies the whole set: the path cannot occur.
pub fn chooseStatus(ok_state: ?bool, requirements: []const Requirement) ?u16 {
    const preferred: u16 = if (ok_state == false) failure_status else success_status;
    if (satisfies(preferred, ok_state, requirements)) return preferred;
    var status: u16 = min_status;
    while (status <= max_status) : (status += 1) {
        if (satisfies(status, ok_state, requirements)) return status;
    }
    return null;
}

fn satisfies(status: u16, ok_state: ?bool, requirements: []const Requirement) bool {
    if (ok_state) |want| {
        if (isOkStatus(status) != want) return false;
    }
    for (requirements) |r| {
        if (holds(r.comparison, status) != r.expect) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn cmp(op: Op, literal: f64) Comparison {
    return .{ .op = op, .literal = literal, .literal_left = false };
}

test "holds reads the operands in source order" {
    try std.testing.expect(holds(cmp(.lt, 300), 200));
    try std.testing.expect(!holds(cmp(.lt, 300), 400));
    const flipped: Comparison = .{ .op = .lt, .literal = 300, .literal_left = true };
    try std.testing.expect(!holds(flipped, 200));
    try std.testing.expect(holds(flipped, 400));
}

test "classify forks only on the complement of ok" {
    const Row = struct { c: Comparison, class: Class };
    const rows = [_]Row{
        .{ .c = cmp(.neq, 200), .class = .{ .fork = true } },
        .{ .c = cmp(.eq, 200), .class = .{ .fork = false } },
        .{ .c = .{ .op = .neq, .literal = 200, .literal_left = true }, .class = .{ .fork = true } },
        .{ .c = cmp(.neq, 200.0), .class = .{ .fork = true } },
        // 201 is an ok response that `=== 200` sends to the failure side.
        .{ .c = cmp(.eq, 201), .class = .plain },
        .{ .c = cmp(.gte, 300), .class = .plain },
        .{ .c = cmp(.gt, 299), .class = .plain },
        .{ .c = cmp(.lt, 300), .class = .plain },
        .{ .c = cmp(.gte, 400), .class = .plain },
        .{ .c = cmp(.eq, 404), .class = .plain },
        .{ .c = cmp(.neq, 404), .class = .plain },
        .{ .c = cmp(.lt, 300.5), .class = .plain },
        // Same value at every status: nothing to branch on.
        .{ .c = cmp(.gte, 100), .class = .constant },
        .{ .c = cmp(.gt, -1), .class = .constant },
        .{ .c = cmp(.eq, 0), .class = .constant },
        .{ .c = cmp(.neq, 1000), .class = .constant },
        .{ .c = cmp(.eq, std.math.nan(f64)), .class = .constant },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row.class, classify(row.c));
    }
}

test "chooseStatus keeps the canonical stub when nothing forces another" {
    try std.testing.expectEqual(@as(?u16, 200), chooseStatus(null, &.{}));
    try std.testing.expectEqual(@as(?u16, 200), chooseStatus(true, &.{}));
    try std.testing.expectEqual(@as(?u16, 503), chooseStatus(false, &.{}));
}

test "chooseStatus finds a status that takes the branch" {
    const is_404: Requirement = .{ .comparison = cmp(.eq, 404), .expect = true };
    const not_404: Requirement = .{ .comparison = cmp(.eq, 404), .expect = false };
    const ge_300: Requirement = .{ .comparison = cmp(.gte, 300), .expect = true };
    const lt_300: Requirement = .{ .comparison = cmp(.gte, 300), .expect = false };
    try std.testing.expectEqual(@as(?u16, 404), chooseStatus(null, &.{is_404}));
    try std.testing.expectEqual(@as(?u16, 200), chooseStatus(null, &.{not_404}));
    try std.testing.expectEqual(@as(?u16, 503), chooseStatus(false, &.{not_404}));
    try std.testing.expectEqual(@as(?u16, 404), chooseStatus(false, &.{is_404}));
    try std.testing.expectEqual(@as(?u16, 300), chooseStatus(null, &.{ge_300}));
    try std.testing.expectEqual(@as(?u16, 200), chooseStatus(null, &.{lt_300}));
    // An ok response that is not 200 is still reachable.
    const is_201: Requirement = .{ .comparison = cmp(.eq, 201), .expect = true };
    try std.testing.expectEqual(@as(?u16, 201), chooseStatus(true, &.{is_201}));
}

test "chooseStatus is null for a contradiction" {
    const is_404: Requirement = .{ .comparison = cmp(.eq, 404), .expect = true };
    const not_404: Requirement = .{ .comparison = cmp(.eq, 404), .expect = false };
    try std.testing.expectEqual(@as(?u16, null), chooseStatus(null, &.{ is_404, not_404 }));
    try std.testing.expectEqual(@as(?u16, null), chooseStatus(true, &.{is_404}));
}
