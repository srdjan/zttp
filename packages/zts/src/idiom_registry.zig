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
const repair_intent = @import("repair_intent.zig");

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
    /// The `RepairIntent` tag name of the canonicalize rewrite that implements
    /// the row, or null when the row is advisory-only. A consumer reading a
    /// `normalize --json` rewrite trace maps an applied intent back to its
    /// idiom through this field; `findByRewriteRule` does the lookup.
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
        .id = "idiom.matched-field-read",
        .operation = "matched field read",
        .idiomatic = "a binding pattern field",
        .superseded = "a match arm that reads the field off the scrutinee",
        .precondition = "none",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.binding-field-name",
        .operation = "binding field name",
        .idiomatic = "shorthand { value }",
        .superseded = "{ value: value }",
        .precondition = "none",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.element-iteration",
        .operation = "element iteration",
        .idiomatic = "for (const item of items)",
        // The second spelling is beyond spec 4.2.1's table, which lists only the
        // range-index form. The repo has rewritten the entries-alias form since
        // before this program (ZTS619), and it supersedes the same idiomatic
        // spelling for the same operation, so it belongs on this row. Spec edit
        // owed: add it to the table's non-idiomatic column.
        .superseded = "for...of over range(items.length) whose body only indexes items, for...of over items.entries() whose index alias is never read",
        .precondition = "none",
        .rewrite_rule = "drop_unused_index_alias",
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

/// Find the row a rewrite implements, given the `RepairIntent` tag name a
/// `normalize --json` trace records. Returns null for an intent that repairs a
/// restriction rather than realizing an idiom, which is most of them.
pub fn findByRewriteRule(intent_name: []const u8) ?*const IdiomEntry {
    for (&entries) |*entry| {
        const rule = entry.rewrite_rule orelse continue;
        if (std.mem.eql(u8, rule, intent_name)) return entry;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Table hash
// ---------------------------------------------------------------------------

/// Deterministic SHA-256 over the idiom table, field-wise with `\0` separators
/// and a `\x01` record terminator - the pre-image shape the policy hash uses
/// (D3 §3). Published as `idiom_table_hash`, so a client can tell whether the
/// preference set it cached still matches this compiler's. Cached on first call
/// because SHA-256 exceeds the comptime branch budget.
var cached_hash: ?[64]u8 = null;

pub fn tableHash() [64]u8 {
    if (cached_hash) |h| return h;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (&entries) |*entry| {
        hasher.update(entry.id);
        hasher.update("\x00");
        hasher.update(entry.operation);
        hasher.update("\x00");
        hasher.update(entry.idiomatic);
        hasher.update("\x00");
        hasher.update(entry.superseded);
        hasher.update("\x00");
        hasher.update(entry.precondition);
        hasher.update("\x00");
        // A row losing its rewrite is a policy-visible change, so the sentinel
        // must not collide with a real intent name.
        hasher.update(entry.rewrite_rule orelse "-");
        hasher.update("\x01");
    }

    cached_hash = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return cached_hash.?;
}

test "tableHash is stable and covers the rewrite column" {
    const h = tableHash();
    try std.testing.expectEqual(@as(usize, 64), h.len);
    try std.testing.expectEqualSlices(u8, &h, &tableHash());
    for (h) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(hex);
    }
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

test "every wired rewrite_rule names a real RepairIntent" {
    // The back-reference is a bare string, so nothing but this test stops it
    // drifting when an intent is renamed or removed.
    for (entries) |entry| {
        const rule = entry.rewrite_rule orelse continue;
        _ = std.meta.stringToEnum(repair_intent.RepairIntent, rule) orelse {
            std.debug.print("\nidiom {s} names unknown repair intent '{s}'\n", .{ entry.id, rule });
            return error.UnknownRepairIntent;
        };
    }
}

test "findByRewriteRule maps an applied intent back to its idiom" {
    const entry = findByRewriteRule("drop_unused_index_alias") orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("idiom.element-iteration", entry.id);
    // An intent that repairs a restriction rather than realizing an idiom has
    // no row, and must not be forced into one.
    try std.testing.expect(findByRewriteRule("replace_let_with_const") == null);
}

test "findById resolves a seeded row and rejects an unknown one" {
    const entry = findById("idiom.element-iteration") orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("element iteration", entry.operation);
    try std.testing.expect(findById("idiom.nonexistent") == null);
}
