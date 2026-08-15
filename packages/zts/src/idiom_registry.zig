//! Machine-readable view of the idiom table (spec 4.2.1).
//!
//! An idiom names one operation, the spelling preferred among the admitted
//! alternatives, the spellings it supersedes, and the precondition under which
//! a mechanical rewrite between them preserves meaning. A non-idiomatic
//! spelling is never an error and never fails a build: it is reported at
//! `advisory` severity, rewritten where the rewrite is provable, and otherwise
//! left alone.
//!
//! The table is complete against spec 4.2.1: 23 rows, in the document's own
//! order, held there by `scripts/check-idiom-table.sh`. Phase 0 seeded the rows
//! that needed no language the engine lacked; the Dict rows arrived with
//! `Dict`; the `Result`, selection, record-update, fold, and search-loop rows
//! arrived in phase 6, once phase 4 had shipped the features they describe.
//!
//! `rewrite_rule` names the canonicalize rewrite that implements the row; it
//! stays null until that rewrite is wired, and a row with no rewrite is
//! advisory-only. Completeness of the table is not completeness of the rewrite
//! lane: all rows are currently advisory-only preferences.
//!
//! Three of the four Dict rows are also reported: `dictionary map` and
//! `dictionary filter` share ZTS627 - one round trip, two destinations,
//! chosen by what the transform does - and `dictionary fold` is ZTS628.
//! `dictionary membership test` ships table-only, like most rows here.

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
        .id = "idiom.two-way-pure-selection",
        .operation = "two-way pure selection",
        .idiomatic = "c ? a : b",
        .superseded = "a two-arm match over a boolean scrutinee whose arms are both pure",
        .precondition = "none",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.record-update",
        .operation = "record update",
        .idiomatic = "an explicit literal",
        .superseded = "a leading spread that overrides every field",
        .precondition = "the spread operand is pure",
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
        .id = "idiom.dictionary-membership-test",
        .operation = "dictionary membership test",
        .idiomatic = "dictHas(d, k)",
        .superseded = "dictGet(d, k) !== undefined",
        .precondition = "V excludes undefined",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.result-default",
        .operation = "Result default",
        .idiomatic = "unwrapOr(r, d)",
        .superseded = "r.ok ? r.value : d, a two-arm match whose arms are the value and a constant",
        .precondition = "d is assignable to T",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.result-sequence",
        .operation = "Result sequence",
        .idiomatic = "collectAll(rs)",
        .superseded = "a reduce over Result values whose body is andThen",
        .precondition = "the fold has no other accumulator",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.dictionary-map",
        .operation = "dictionary map",
        .idiomatic = "dictMapValues(d, f)",
        .superseded = "an entry round trip through dictEntries and dictFromEntries that changes only values",
        .precondition = "the rewrite spans the whole consumption site, including its Result handling",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.dictionary-filter",
        .operation = "dictionary filter",
        .idiomatic = "dictFilter(d, p)",
        .superseded = "an entry round trip that only drops entries",
        .precondition = "the rewrite spans the whole consumption site, including its Result handling",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.dictionary-fold",
        .operation = "dictionary fold",
        .idiomatic = "dictFold(d, f, init)",
        .superseded = "dictEntries(d).reduce(...)",
        .precondition = "the fold has one accumulator",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.pure-single-accumulator-fold",
        .operation = "pure single-accumulator fold",
        .idiomatic = "map, then filter, then some, then every, then find, then findIndex, then reduce: the first that fits",
        .superseded = "let plus for...of with no break, continue, or effect",
        .precondition = "the body is pure and the loop head is already idiomatic under the element-iteration row",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.pure-search-loop",
        .operation = "pure search loop",
        .idiomatic = "find, findIndex, some, or every, by what the loop yields and whether its flag starts false or true",
        .superseded = "let plus for...of whose only early exit is break",
        .precondition = "the body is pure, carries one accumulator, uses no continue, and the loop head is already idiomatic under the element-iteration row",
        .rewrite_rule = null,
    },
    .{
        .id = "idiom.field-read",
        .operation = "field read",
        .idiomatic = "const id = user.id;, or const first = pair[0]; for a tuple",
        .superseded = "any declaration destructuring pattern",
        .precondition = "none",
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
    // The count spec 4.2.1's table carries. A row added to the document and not
    // here fails `scripts/check-idiom-table.sh`; a row added here and not there
    // fails it too. This asserts the number itself so a same-size swap of one
    // row for another still has to face the text comparison.
    try std.testing.expectEqual(@as(usize, 23), entries.len);
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

test "findByRewriteRule rejects intents not owned by an idiom" {
    try std.testing.expect(findByRewriteRule("drop_unused_index_alias") == null);
    try std.testing.expect(findByRewriteRule("replace_let_with_const") == null);
}

test "findById resolves a seeded row and rejects an unknown one" {
    const entry = findById("idiom.element-iteration") orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("element iteration", entry.operation);
    try std.testing.expect(findById("idiom.nonexistent") == null);
}
