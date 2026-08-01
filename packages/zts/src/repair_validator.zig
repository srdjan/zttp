//! The equivalence-validator registry for typed repairs (D3 section 4).
//!
//! Spec 4.8 permits advertising an exact repair only when a registered
//! equivalence validator exists. Before this file the answer was a hardcoded
//! `repair_available: false` and a comment; this makes the classification data,
//! so a client can read it out of `meta.validators` and a reviewer can argue
//! with a row instead of with prose.
//!
//! Two things are being said per intent, and they are different questions.
//!
//! First, is the rewrite an equivalence at all? A canonicalization is: `let`
//! and `const` denote the same program when the binding is never reassigned.
//! A repair is not: `add_trailing_return` exists precisely to change what the
//! program does on a path that previously fell off the end. Repairs are
//! classified `.none` and ship advisory-only, which D3 blesses directly - "a
//! row with no method is legal and ships advisory-only". That is a correct
//! classification, not a gap waiting to be closed.
//!
//! Second, for the rewrites that are equivalences, which method discharges
//! them? M2 (parse identity) discharges none: every one changes the IR tree.
//! M1 needs the canonical formatter and M3 needs the semantic kernel, neither
//! of which exists. M5 is advisory-only by construction. That leaves M4,
//! declared law, whose machinery already runs under z3 in `scripts/verify.sh` -
//! and whose published shape, a law plus "the law's own preconditions carried
//! into the row's precondition column", is the shape these rewrites need. The
//! precondition source here is the checker: the rewrite is sound exactly where
//! the diagnostic that requested it fired.
//!
//! `status` is what keeps the advertisement honest. A row may name M4 and still
//! be `.planned`, meaning the method is right but nothing runs it yet. Only an
//! `.implemented` row may flip `repair_available`, so naming a validator can
//! never be mistaken for having one.

const std = @import("std");
const repair_intent = @import("repair_intent.zig");

pub const RepairIntent = repair_intent.RepairIntent;

/// D3 section 4's validator catalog, strongest to weakest.
pub const Method = enum {
    /// No equivalence is claimed. The rewrite deliberately changes behaviour,
    /// so there is nothing for an equivalence validator to discharge.
    none,
    /// M1 - layout identity. Print both sides with the canonical formatter;
    /// equivalent iff the bytes match.
    layout_identity,
    /// M2 - parse identity. IR trees identical modulo positions and trivia.
    parse_identity,
    /// M3 - kernel-IR identity. Both sides elaborate to the same semantic
    /// kernel term after normalization.
    kernel_identity,
    /// M4 - declared law, with the law's preconditions carried on the row.
    declared_law,
    /// M5 - contract behavioral equivalence. Advisory-only by construction: it
    /// compares extracted contracts, so it is blind to pure computation the
    /// contract does not model, and per spec 4.2.1 never auto-applies.
    contract_equivalence,

    pub fn id(self: Method) []const u8 {
        return switch (self) {
            .none => "none",
            .layout_identity => "M1",
            .parse_identity => "M2",
            .kernel_identity => "M3",
            .declared_law => "M4",
            .contract_equivalence => "M5",
        };
    }
};

/// Whether the named method actually runs for this row today.
pub const Status = enum {
    /// The method is named and something discharges it. Only these may
    /// advertise a repair.
    implemented,
    /// The method is the right one but nothing runs it yet.
    planned,
    /// No equivalence is claimed, so there is nothing to implement.
    not_applicable,
};

pub const Row = struct {
    intent: RepairIntent,
    method: Method,
    status: Status,
    /// The condition under which the rewrite is an equivalence, or null when
    /// none is claimed. For the checker-discharged rows this names the fact the
    /// diagnostic established, which is why the repair is sound at that site
    /// and nowhere else.
    precondition: ?[]const u8,

    /// True when this row may advertise `repair_available` on the wire.
    pub fn gradable(self: Row) bool {
        return self.method != .none and self.status == .implemented;
    }
};

/// One row per `RepairIntent`. `validateCoverage` proves the two cannot drift.
pub const rows = [_]Row{
    // ---- Canonicalizations: equivalences under a checker-discharged fact ----
    .{
        .intent = .replace_let_with_const,
        .method = .declared_law,
        .status = .planned,
        .precondition = "the checker proved the binding is never reassigned (ZTS604)",
    },
    .{
        .intent = .canonicalize_for_of_const,
        .method = .declared_law,
        .status = .planned,
        .precondition = "the checker proved the loop binding is never reassigned",
    },
    .{
        .intent = .replace_compound_assign_with_explicit,
        .method = .declared_law,
        .status = .planned,
        .precondition = "compound assignment desugars to the explicit form by definition",
    },
    .{
        .intent = .drop_redundant_bool_compare,
        .method = .declared_law,
        .status = .planned,
        .precondition = "the compared value is statically boolean, so the comparison is the identity",
    },
    .{
        .intent = .replace_arrow_with_function,
        .method = .declared_law,
        .status = .planned,
        .precondition = "the arrow is bound once and never used before its declaration",
    },
    .{
        .intent = .replace_export_arrow_with_function,
        .method = .declared_law,
        .status = .planned,
        .precondition = "the arrow is bound once and never used before its declaration",
    },
    .{
        .intent = .replace_ternary_with_if,
        .method = .kernel_identity,
        .status = .planned,
        .precondition = "both arms are pure, so the conditional and the statement form share one elaboration",
    },
    .{
        .intent = .name_const_above_template,
        .method = .kernel_identity,
        .status = .planned,
        .precondition = "the extracted expression is pure and evaluated exactly once",
    },
    .{
        .intent = .lift_default_to_body,
        .method = .kernel_identity,
        .status = .planned,
        .precondition = "the default expression is pure",
    },
    .{
        .intent = .lead_with_spread,
        .method = .kernel_identity,
        .status = .planned,
        .precondition = "no later key collides with a spread key",
    },
    .{
        .intent = .flatten_destructure,
        .method = .parse_identity,
        .status = .planned,
        .precondition = "the destructure binds exactly one field",
    },
    .{
        .intent = .drop_unused_index_alias,
        .method = .parse_identity,
        .status = .planned,
        .precondition = "the alias is never read",
    },
    .{
        .intent = .widen_signature_drop_spread,
        .method = .contract_equivalence,
        .status = .planned,
        .precondition = "advisory only: M5 is blind to pure computation the contract does not model",
    },
    .{
        .intent = .canonicalize_capability_key_alias,
        .method = .contract_equivalence,
        .status = .planned,
        .precondition = "advisory only: the rewrite needs file-level scope analysis",
    },

    // ---- Repairs: no equivalence is claimed, and none should be ----
    .{
        .intent = .insert_guard_before_line,
        .method = .none,
        .status = .not_applicable,
        .precondition = null,
    },
    .{
        .intent = .add_trailing_return,
        .method = .none,
        .status = .not_applicable,
        .precondition = null,
    },
    .{
        .intent = .add_capability_declaration,
        .method = .none,
        .status = .not_applicable,
        .precondition = null,
    },
    .{
        .intent = .add_spec_assertion,
        .method = .none,
        .status = .not_applicable,
        .precondition = null,
    },
};

pub fn find(intent: RepairIntent) ?Row {
    for (rows) |row| {
        if (row.intent == intent) return row;
    }
    return null;
}

/// True when a repair carrying this intent may advertise `repair_available`.
/// Unknown intents answer false: an intent with no row has not been classified,
/// and an unclassified rewrite is exactly what must not be advertised.
pub fn gradable(intent: RepairIntent) bool {
    const row = find(intent) orelse return false;
    return row.gradable();
}

/// Every `RepairIntent` has exactly one row. Enforced at comptime so a new
/// intent cannot be added without deciding what, if anything, discharges it -
/// the default would otherwise be silence, and silence here reads as "not
/// gradable" for a rewrite nobody ever considered.
pub fn validateCoverage() void {
    @setEvalBranchQuota(10000);
    for (std.enums.values(RepairIntent)) |intent| {
        var seen: usize = 0;
        for (rows) |row| {
            if (row.intent == intent) seen += 1;
        }
        if (seen == 0) {
            @compileError("RepairIntent." ++ @tagName(intent) ++ " has no repair_validator row; classify it");
        }
        if (seen > 1) {
            @compileError("RepairIntent." ++ @tagName(intent) ++ " has more than one repair_validator row");
        }
    }
}

comptime {
    validateCoverage();
}

test "every intent is classified exactly once" {
    for (std.enums.values(RepairIntent)) |intent| {
        try std.testing.expect(find(intent) != null);
    }
    try std.testing.expectEqual(@as(usize, std.enums.values(RepairIntent).len), rows.len);
}

test "a behaviour-changing repair claims no equivalence" {
    // These exist to change what the program does. Grading them as
    // equivalences would be a category error, not a missing feature.
    const row = find(.add_trailing_return).?;
    try std.testing.expectEqual(Method.none, row.method);
    try std.testing.expect(row.precondition == null);
    try std.testing.expect(!row.gradable());
}

test "naming a method is not the same as having one" {
    // The canonicalizations name M4, which is the right method, and are still
    // ungradable because nothing runs it yet. This is the property that keeps
    // the wire honest.
    const row = find(.replace_let_with_const).?;
    try std.testing.expectEqual(Method.declared_law, row.method);
    try std.testing.expectEqual(Status.planned, row.status);
    try std.testing.expect(row.precondition != null);
    try std.testing.expect(!row.gradable());
}

test "no intent advertises a repair yet" {
    // The registry ships with nothing gradable. When the first method lands,
    // this test changes in the same commit that makes it true - which is the
    // point of asserting it rather than assuming it.
    for (rows) |row| {
        try std.testing.expect(!row.gradable());
    }
}
