//! Machine-readable view of the idiom table (spec 4.2.1).
//!
//! An idiom names one operation, the spelling preferred among the admitted
//! alternatives, the spellings it supersedes, and the precondition under which
//! a mechanical rewrite between them preserves meaning. A non-idiomatic
//! spelling is never an error and never fails a build: it is reported at
//! `advisory` severity, rewritten where the rewrite is provable, and otherwise
//! left alone.
//!
//! Phase 0 seeds only the rows that need no language the engine lacks today.
//! The Dict, Result, match-binding, fold, and search-loop rows arrive with the
//! features they describe (master plan phases 4 and 6). `rewrite_rule` names
//! the canonicalize rewrite that implements the row; it stays null until that
//! rewrite is wired, and a row with no rewrite is advisory-only.

const std = @import("std");

pub const IdiomEntry = struct {
    /// Stable identifier, `idiom.<operation-slug>`. Machine consumers key on
    /// this, so a row is never renamed once published.
    id: []const u8,
    /// The operation the row covers, as spec 4.2.1 names it.
    operation: []const u8,
    /// The preferred spelling.
    idiomatic: []const u8,
    /// The spellings this row supersedes, comma-separated as the spec spells
    /// them.
    superseded: []const u8,
    /// When a mechanical rewrite preserves meaning. "none" means always.
    precondition: []const u8,
    /// The canonicalize rewrite that implements the row, or null when the row
    /// is advisory-only.
    rewrite_rule: ?[]const u8,
};

pub const entries = [_]IdiomEntry{
    .{
        .id = "idiom.absence-default",
        .operation = "absence default",
        .idiomatic = "x ?? d",
        .superseded = "x === undefined ? d : x, x !== undefined ? x : d, match (x) { when undefined: d default: x }",
        .precondition = "operand type excludes null and is neither a generic parameter nor unknown",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.absent-member-read",
        .operation = "absent member read",
        .idiomatic = "x?.f",
        .superseded = "x === undefined ? undefined : x.f",
        .precondition = "operand type excludes null and is neither a generic parameter nor unknown",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.number-in-text",
        .operation = "number in text",
        .idiomatic = "`${n}`",
        .superseded = "`${String(n)}`",
        .precondition = "interpolation of a number",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.scalar-to-text",
        .operation = "scalar to text",
        .idiomatic = "String(n)",
        .superseded = "a template whose entire content is one number interpolation",
        .precondition = "value position outside a template",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.redundant-template",
        .operation = "redundant template",
        .idiomatic = "the interpolated expression itself",
        .superseded = "a template whose entire content is one string interpolation",
        .precondition = "value position outside a template, and the interpolation's static type is exactly string",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.string-concatenation",
        .operation = "string concatenation",
        .idiomatic = "left-associated a + b + c",
        .superseded = "a template with no literal text and two or more interpolations, all string",
        .precondition = "value position outside a template",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.array-concatenation",
        .operation = "array concatenation",
        .idiomatic = "[...a, ...b]",
        .superseded = "a.concat(b)",
        .precondition = "none",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.membership-test",
        .operation = "membership test",
        .idiomatic = "items.includes(v)",
        .superseded = "items.indexOf(v) !== -1, items.indexOf(v) >= 0",
        .precondition = "element type excludes number (NaN distinguishes the two equalities)",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.existence-test",
        .operation = "existence test",
        .idiomatic = "items.some(p)",
        .superseded = "items.find(p) !== undefined",
        .precondition = "element type excludes undefined",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.field-read",
        .operation = "field read",
        .idiomatic = "const id = user.id;, or const first = pair[0]; for a tuple",
        .superseded = "a one-field or one-element destructuring pattern",
        .precondition = "none",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.multi-field-read",
        .operation = "multi-field read",
        .idiomatic = "const { id, name } = user;, or const [first, second] = pair; for a tuple",
        .superseded = "two or more member or fixed-tuple index reads of the same binding in one block",
        .precondition = "the binding's type is a single record type or a fixed tuple, and no narrowing guard separates the reads",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.element-iteration",
        .operation = "element iteration",
        .idiomatic = "for (const item of items)",
        .superseded = "for...of over range(items.length) whose body only indexes items",
        .precondition = "none",
        .rewrite_rule = null,
    },
};

/// Look a row up by its stable id. Canonicalize uses this to attach an idiom
/// id to a rewrite without duplicating the string table.
pub fn findById(id: []const u8) ?*const IdiomEntry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

test "idiom registry has unique stable ids" {
    for (entries, 0..) |entry, i| {
        try std.testing.expect(std.mem.startsWith(u8, entry.id, "idiom."));
        for (entries[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
    try std.testing.expect(entries.len >= 8);
}

test "idiom registry rows are fully populated" {
    for (entries) |entry| {
        try std.testing.expect(entry.operation.len > 0);
        try std.testing.expect(entry.idiomatic.len > 0);
        try std.testing.expect(entry.superseded.len > 0);
        try std.testing.expect(entry.precondition.len > 0);
    }
}

test "findById resolves a seeded row and rejects an unknown one" {
    const entry = findById("idiom.element-iteration") orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("element iteration", entry.operation);
    try std.testing.expect(findById("idiom.nonexistent") == null);
}
