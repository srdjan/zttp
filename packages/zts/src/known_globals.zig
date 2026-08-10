//! The global names a handler may call without importing them.
//!
//! Shared by `strict_checker` (which must not flag a call to one of these as
//! an unknown callee) and `effect_inference` (which must not mark a row as a
//! lower bound because of one). Two copies of this list would drift, and a
//! drifted copy is a soundness change: a name missing from the inference copy
//! turns every handler that calls it into a lower bound, and a name wrongly
//! present hides a genuinely unresolvable call.

const std = @import("std");

/// Callable globals the runtime provides. Object namespaces (`Math`, `JSON`)
/// appear because they are the callee object of a member call.
pub const names = [_][]const u8{
    "Array",
    "Boolean",
    "Date",
    "Headers",
    "JSON",
    "Math",
    "Number",
    "Object",
    "Request",
    "Response",
    "String",
    "assert",
    "h",
    "hole",
    "isBytes",
    "isDict",
    "parallel",
    "parseFloat",
    "parseInt",
    "race",
    "range",
    "renderToString",
    "requestBody",
    "requestJson",
    "requestText",
    "resource",
};

/// Global member reads whose result differs between runs.
///
/// Same reasoning as `names` above, and the same cost for a drifted copy. This
/// list was duplicated by hand in `flow_checker.isVaryingGlobalRead` (which
/// labels the value) and `effect_inference.isNonDeterministic` (which answers
/// the per-function question labels cannot reach). Both listed `Date.now` and
/// `Math.random` and neither listed `performance.now`, so a handler reading a
/// clock through that name discharged `deterministic` and printed PROVEN.
///
/// A name missing here is a fail-open: the read costs nothing and the property
/// is claimed anyway. Adding a runtime clock or entropy source means adding it
/// here.
pub const VaryingRead = struct {
    object: []const u8,
    property: []const u8,
    /// True when a `durable.step()` callback records this read and replays the
    /// recorded value on recovery.
    ///
    /// The analyzers exempt a varying read inside a durable step, and that
    /// exemption is only sound when the runtime actually records it.
    /// `Date.now` and `Math.random` do, through `durable.replayNext` and
    /// `durable.persistIO` plus `recorder.recordIO`. `performance.now`
    /// (`builtins/date.zig`) does none of the three: it reads a live monotonic
    /// clock every time. Exempting it would certify a workflow as
    /// `deterministic` and `idempotent` that takes a different branch on
    /// replay than the one it was proven to take.
    recorded_in_durable_step: bool,
};

pub const varying_reads = [_]VaryingRead{
    .{ .object = "Date", .property = "now", .recorded_in_durable_step = true },
    .{ .object = "Math", .property = "random", .recorded_in_durable_step = true },
    .{ .object = "performance", .property = "now", .recorded_in_durable_step = false },
};

fn find(object_name: []const u8, property_name: []const u8) ?VaryingRead {
    for (varying_reads) |candidate| {
        if (std.mem.eql(u8, object_name, candidate.object) and
            std.mem.eql(u8, property_name, candidate.property)) return candidate;
    }
    return null;
}

pub fn isVaryingRead(object_name: []const u8, property_name: []const u8) bool {
    return find(object_name, property_name) != null;
}

/// True when this read varies AND a durable step cannot record it, so the
/// varying-read verdict must stand even inside a `durable.step()` callback.
pub fn isUnrecordableVaryingRead(object_name: []const u8, property_name: []const u8) bool {
    const read = find(object_name, property_name) orelse return false;
    return !read.recorded_in_durable_step;
}

pub fn isKnownGlobalFunction(name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "hole is a known global" {
    // `hole()` must be recognised here or effect inference reads it as an
    // unresolvable callee and marks every holed function's row a lower bound -
    // which would defeat the whole point of a hole, that the rest of the
    // program still verifies.
    try std.testing.expect(isKnownGlobalFunction("hole"));
}

test "known globals cover the runtime-provided callables" {
    try std.testing.expect(isKnownGlobalFunction("renderToString"));
    try std.testing.expect(isKnownGlobalFunction("range"));
    try std.testing.expect(!isKnownGlobalFunction("myHelper"));
    try std.testing.expect(!isKnownGlobalFunction(""));
}

const testing = std.testing;

test "every varying read is recognized, and performance.now is among them" {
    // performance.now was absent from both hand-copied lists, so a handler
    // reading that clock discharged `deterministic` and printed PROVEN.
    try testing.expect(isVaryingRead("performance", "now"));
    try testing.expect(isVaryingRead("Date", "now"));
    try testing.expect(isVaryingRead("Math", "random"));

    // `names` is deliberately NOT asserted to contain every varying-read
    // receiver. The two lists answer different questions: `names` suppresses
    // unknown-callee reports for bare identifier calls, and no consumer of it
    // ever inspects a member call's receiver. Adding `performance` there
    // changed nothing for varying reads and did let a bare `performance()`
    // call - which TypeErrors at runtime - pass as a known global.
    try testing.expect(!isKnownGlobalFunction("performance"));

    // Neither half of a pair matches on its own.
    try testing.expect(!isVaryingRead("performance", "mark"));
    try testing.expect(!isVaryingRead("Date", "random"));
    try testing.expect(!isVaryingRead("Math", "now"));
    try testing.expect(!isVaryingRead("Performance", "now"));
}
