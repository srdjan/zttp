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
//!
//! `validateApplication` is the thing that runs, and it lives here rather than
//! beside the rewrite on purpose. A validator that reuses the producer's own
//! scanner cannot catch the producer drifting: it would re-derive the same wrong
//! answer and agree with itself. This one re-locates the comparison and
//! recomputes the law's rewrite from the original line independently, and the
//! apply path is accepted only when the two agree byte for byte.
//!
//! It is deliberately solver-free. `semantics_check.runSmt` degrades to
//! "skipped" when z3 is absent, so a wire flag that depended on a solver run
//! would answer differently on a machine without z3 - and `repair_available` is
//! a published protocol field, not a local diagnostic.

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
        .status = .implemented,
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

/// The answer `validateApplication` gives about one applied edit.
pub const Discharge = union(enum) {
    /// The edit is exactly the declared law's rewrite, so the two programs
    /// denote the same thing under the row's precondition.
    equivalent,
    /// The edit is something other than the law's rewrite. The payload names
    /// which check refused, so a caller can report why rather than "no".
    not_law_shape: []const u8,
    /// This intent has no implemented validator. Distinct from a refusal: the
    /// edit was never examined.
    no_validator,
};

/// Discharge one applied repair against its row's declared law.
///
/// `line` is the 1-based line the diagnostic reported. Two obligations, and
/// both are needed: the edit must be confined to that line (a validator that
/// only checked the line's content would accept a rewrite that also deleted a
/// function three lines down), and the line's new content must be what the law
/// produces from its old content.
pub fn validateApplication(
    intent: RepairIntent,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) Discharge {
    const row = find(intent) orelse return .no_validator;
    if (row.status != .implemented) return .no_validator;

    return switch (intent) {
        .drop_redundant_bool_compare => dischargeBoolCompare(original, repaired, line),
        // Every other row is `.planned`, so the guard above already returned.
        else => .no_validator,
    };
}

fn dischargeBoolCompare(original: []const u8, repaired: []const u8, line: u32) Discharge {
    const changed = singleChangedLine(original, repaired) orelse
        return .{ .not_law_shape = "the edit touches more than one line, or none" };
    if (changed != line) {
        return .{ .not_law_shape = "the changed line is not the line the diagnostic reported" };
    }

    const before = sourceLine(original, line) orelse
        return .{ .not_law_shape = "the reported line is past the end of the original" };
    const after = sourceLine(repaired, line) orelse
        return .{ .not_law_shape = "the reported line is past the end of the repaired source" };

    const rewrite = lawRewrite(before) orelse
        return .{ .not_law_shape = "the original line carries no rewritable boolean comparison" };

    // `!x` needs two writes into the scratch buffer and the value operand is
    // bounded by the line, so a line long enough to overflow this cannot hold a
    // comparison this scan would accept.
    var buf: [1024]u8 = undefined;
    const expected = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{
        before[0..rewrite.span_start],
        if (rewrite.positive) "" else "!",
        rewrite.value,
        before[rewrite.span_end..],
    }) catch return .{ .not_law_shape = "the line is too long to re-derive" };

    if (!std.mem.eql(u8, expected, after)) {
        return .{ .not_law_shape = "the new line is not the law's rewrite of the old one" };
    }
    return .equivalent;
}

const LawRewrite = struct {
    /// Half-open byte range of the whole comparison on the line.
    span_start: usize,
    span_end: usize,
    /// The non-literal operand.
    value: []const u8,
    /// True for the `x` form (`x === true`, `x !== false`), false for `!x`.
    positive: bool,
};

/// Locate the one rewritable boolean comparison on `line` and state what the
/// law turns it into. Refuses on two candidates: with two there is no way to
/// tell which the diagnostic meant, and accepting either would let an edit to
/// the wrong one pass as the law's rewrite.
fn lawRewrite(line: []const u8) ?LawRewrite {
    var found: ?LawRewrite = null;
    var i: usize = 0;
    while (i + 3 <= line.len) : (i += 1) {
        const op = line[i .. i + 3];
        const is_eq = std.mem.eql(u8, op, "===");
        if (!is_eq and !std.mem.eql(u8, op, "!==")) continue;

        const left_end = trimSpacesBack(line, i);
        const left_start = operandStartBack(line, left_end) orelse continue;
        const left = line[left_start..left_end];

        const right_start = skipSpaces(line, i + 3);
        const right = operandForward(line, right_start) orelse continue;

        const left_lit = isBoolLiteral(left);
        const right_lit = isBoolLiteral(right);
        // The checker's invariant: exactly one side is the literal.
        if (left_lit == right_lit) continue;

        const value = if (left_lit) right else left;
        if (!isSimpleLvalue(value)) continue;

        const literal_is_true = if (left_lit)
            std.mem.eql(u8, left, "true")
        else
            std.mem.eql(u8, right, "true");

        if (found != null) return null;
        found = .{
            .span_start = left_start,
            .span_end = right_start + right.len,
            .value = value,
            .positive = if (is_eq) literal_is_true else !literal_is_true,
        };
    }
    return found;
}

/// The 1-based index of the only line that differs, or null when zero lines or
/// more than one differ. Sources with different line counts answer null: a
/// span-local rewrite adds and removes no lines.
fn singleChangedLine(original: []const u8, repaired: []const u8) ?u32 {
    var a = std.mem.splitScalar(u8, original, '\n');
    var b = std.mem.splitScalar(u8, repaired, '\n');
    var changed: ?u32 = null;
    var n: u32 = 0;
    while (true) {
        const la = a.next();
        const lb = b.next();
        if (la == null and lb == null) break;
        if (la == null or lb == null) return null;
        n += 1;
        if (!std.mem.eql(u8, la.?, lb.?)) {
            if (changed != null) return null;
            changed = n;
        }
    }
    return changed;
}

fn sourceLine(source: []const u8, line: u32) ?[]const u8 {
    if (line == 0) return null;
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 0;
    while (it.next()) |l| {
        n += 1;
        if (n == line) return l;
    }
    return null;
}

fn isBoolLiteral(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "true") or std.mem.eql(u8, tok, "false");
}

/// An identifier or dotted chain (`a`, `a.b.c`), which is the only operand
/// shape whose span this line-local scan can bound without a parser, and the
/// only one where dropping the comparison cannot change `!` precedence.
fn isSimpleLvalue(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (!isIdentStart(tok[0])) return false;
    for (tok) |c| {
        if (!(isIdentContinue(c) or c == '.')) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn skipSpaces(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn trimSpacesBack(line: []const u8, from: usize) usize {
    var i = from;
    while (i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t')) : (i -= 1) {}
    return i;
}

fn operandForward(line: []const u8, pos: usize) ?[]const u8 {
    if (pos >= line.len or !isIdentStart(line[pos])) return null;
    var end = pos + 1;
    while (end < line.len) {
        if (isIdentContinue(line[end])) {
            end += 1;
            continue;
        }
        if (line[end] == '.' and end + 1 < line.len and isIdentStart(line[end + 1])) {
            end += 1;
            continue;
        }
        break;
    }
    return line[pos..end];
}

/// Start of the operand token ending at `end`. Null when the character before
/// the token is `)` or `]`, which signals a call or index whose real span this
/// scan cannot bound.
fn operandStartBack(line: []const u8, end: usize) ?usize {
    if (end == 0) return null;
    var start = end;
    while (start > 0) {
        const c = line[start - 1];
        if (isIdentContinue(c)) {
            start -= 1;
            continue;
        }
        if (c == '.' and start >= 2 and isIdentContinue(line[start - 2])) {
            start -= 1;
            continue;
        }
        break;
    }
    if (start == end) return null;
    if (!isIdentStart(line[start])) return null;
    if (start > 0 and (line[start - 1] == ')' or line[start - 1] == ']')) return null;
    return start;
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

test "exactly one intent advertises a repair" {
    // The registry shipped with nothing gradable, and this test asserted that.
    // It is written as a count rather than a loop so the second row to land has
    // to come here and say so, instead of quietly joining the first.
    var gradable_count: usize = 0;
    for (rows) |row| {
        if (row.gradable()) gradable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), gradable_count);
    try std.testing.expect(gradable(.drop_redundant_bool_compare));
}

test "the law's own rewrite discharges" {
    const original =
        \\function handler(req) {
        \\  if (ready === true) { return Response.json({ ok: true }); }
        \\  return Response.json({ ok: false });
        \\}
    ;
    const repaired =
        \\function handler(req) {
        \\  if (ready) { return Response.json({ ok: true }); }
        \\  return Response.json({ ok: false });
        \\}
    ;
    try std.testing.expectEqual(
        Discharge.equivalent,
        validateApplication(.drop_redundant_bool_compare, original, repaired, 2),
    );
}

test "the negated form discharges" {
    const original = "const blocked = flag === false;";
    const repaired = "const blocked = !flag;";
    try std.testing.expectEqual(
        Discharge.equivalent,
        validateApplication(.drop_redundant_bool_compare, original, repaired, 1),
    );
}

test "a rewrite that is not the law is refused" {
    // Same line, same diagnostic, and the edit inverts the meaning. The whole
    // point of re-deriving rather than diffing is that this is caught.
    const original = "const ready = flag === true;";
    const repaired = "const ready = !flag;";
    const answer = validateApplication(.drop_redundant_bool_compare, original, repaired, 1);
    try std.testing.expect(answer == .not_law_shape);
}

test "an edit outside the diagnostic's line is refused" {
    const original =
        \\const ready = flag === true;
        \\const other = 1;
    ;
    const repaired =
        \\const ready = flag;
        \\const other = 2;
    ;
    const answer = validateApplication(.drop_redundant_bool_compare, original, repaired, 1);
    try std.testing.expect(answer == .not_law_shape);
}

test "two candidates on one line refuse rather than guess" {
    const original = "const both = a === true && b === true;";
    const repaired = "const both = a && b === true;";
    const answer = validateApplication(.drop_redundant_bool_compare, original, repaired, 1);
    try std.testing.expect(answer == .not_law_shape);
}

test "a planned intent has no validator" {
    // Distinct from a refusal: `replace_let_with_const` names the right method
    // and nothing runs it, so the edit is never examined.
    const answer = validateApplication(.replace_let_with_const, "let a = 1;", "const a = 1;", 1);
    try std.testing.expect(answer == .no_validator);
}
