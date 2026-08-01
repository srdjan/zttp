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
    "parallel",
    "parseFloat",
    "parseInt",
    "race",
    "range",
    "renderToString",
    "resource",
};

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
