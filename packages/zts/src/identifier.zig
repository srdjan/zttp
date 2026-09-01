//! The canonical guard identifier: an environment key, a cache namespace, or a
//! SQL query name, as written.
//!
//! These three are identifiers rather than addresses, so the rule is exact: no
//! case folding, no trimming, no substitution. Two identifiers that differ in a
//! byte are two identifiers, and a rule that quietly made one of them match a
//! policy entry would be the failure this layer exists to prevent. What the rule
//! does refuse is a form no policy entry can hold: an empty name, one longer
//! than the cap, and one carrying a control byte.
//!
//! This is deliberately a second implementation of the rule the acceptance
//! kernel carries in `packages/proof-checker/src/residual.zig`, for the reason
//! `endpoint.zig` gives about its own: the kernel is a leaf and this package
//! sits below it, so neither can call the other, and a test in
//! `packages/runtime` runs both over one corpus and fails when they disagree.

const std = @import("std");

/// An environment key, cache namespace, or SQL query name.
pub const max_identifier_bytes: usize = 255;

pub const NormalizeError = error{
    Empty,
    TooLong,
    /// Carries a byte an identifier cannot carry: a control byte or DEL.
    Malformed,
};

/// Canonicalize an identifier. `out` receives the result and the returned slice
/// points into it.
pub fn normalize(value: []const u8, out: []u8) NormalizeError![]const u8 {
    if (value.len == 0) return error.Empty;
    if (value.len > max_identifier_bytes) return error.TooLong;
    if (value.len > out.len) return error.TooLong;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7F) return error.Malformed;
    }
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}

const testing = std.testing;

test "an identifier is exact" {
    var out: [max_identifier_bytes]u8 = undefined;
    try testing.expectEqualStrings("API_KEY", try normalize("API_KEY", &out));
    // Case is not folded and surrounding space is not trimmed: both would make
    // one identifier match another's policy entry.
    try testing.expectEqualStrings("api_key", try normalize("api_key", &out));
    try testing.expectEqualStrings(" API_KEY ", try normalize(" API_KEY ", &out));
}

test "an identifier no policy entry can hold is refused" {
    var out: [max_identifier_bytes]u8 = undefined;
    try testing.expectError(error.Empty, normalize("", &out));

    const longest = [_]u8{'a'} ** max_identifier_bytes;
    try testing.expectEqualStrings(&longest, try normalize(&longest, &out));
    const one_too_long = [_]u8{'a'} ** (max_identifier_bytes + 1);
    try testing.expectError(error.TooLong, normalize(&one_too_long, &out));

    try testing.expectError(error.Malformed, normalize("API\nKEY", &out));
    try testing.expectError(error.Malformed, normalize("API\x00KEY", &out));
    try testing.expectError(error.Malformed, normalize("API\x7FKEY", &out));
}

test "a buffer too small for the identifier refuses rather than truncates" {
    var out: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", try normalize("abcd", &out));
    try testing.expectError(error.TooLong, normalize("abcde", &out));
}
