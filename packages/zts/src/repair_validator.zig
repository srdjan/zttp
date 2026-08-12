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
//! them? M4, declared law, for every one of them, and the catalog says why the
//! other four do not. M1 and M2 were built and measured: layout identity prints
//! both sides and compares bytes, parse identity compares trees, and neither
//! discharged a single row. Every rewrite here changes the tree -
//! `flatten_destructure` turns one statement into two, `drop_unused_index_alias`
//! turns two into one - so parse identity refuses them all, and layout identity
//! is strictly weaker than parse identity. Their case is the rewrite that moves
//! a token without moving structure, which is the semicolon spec 5.5 forbids
//! ASI from inserting; the code went out with the measurement rather than being
//! carried against a rewrite that does not exist yet. M3 needs the semantic
//! kernel, which spec section 10 defers. M5 is advisory-only by construction.
//! That leaves M4, whose machinery already runs under z3 in `scripts/verify.sh`
//! and whose published shape - a law plus "the law's own preconditions carried
//! into the row's precondition column" - is the shape these rewrites need.
//!
//! Where a precondition comes from is part of the row. For most it is the
//! checker: the rewrite is sound exactly where the diagnostic that requested it
//! fired. For the two multi-line laws it is not, because the fact that makes
//! them equivalences - no live binding is captured, no dropped name is read -
//! is one the producer established for itself, and a validator that trusted the
//! producer's own check would be checking nothing. Those two re-derive their
//! preconditions here, from the original source, conservatively: a refusal
//! costs a repair, and an acceptance that should have been a refusal grades a
//! program-changing edit as an equivalence.
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
const ir_identity = @import("ir_identity.zig");

pub const RepairIntent = repair_intent.RepairIntent;

/// D3 section 4's validator catalog, strongest to weakest.
pub const Method = enum {
    /// No equivalence is claimed. The rewrite deliberately changes behaviour,
    /// so there is nothing for an equivalence validator to discharge.
    none,
    /// M1 - layout identity. Print both sides with the canonical formatter;
    /// equivalent iff the bytes match. Catalog entry only: it was implemented,
    /// discharged no row, and the implementation went out with that result.
    layout_identity,
    /// M2 - parse identity. IR trees identical modulo positions and trivia.
    /// Catalog entry only, for the same reason as M1.
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
        .status = .implemented,
        .precondition = "the checker proved the binding is never reassigned (ZTS604)",
    },
    .{
        .intent = .canonicalize_for_of_const,
        .method = .declared_law,
        .status = .implemented,
        .precondition = "the checker proved the loop binding is never reassigned",
    },
    .{
        .intent = .replace_compound_assign_with_explicit,
        .method = .declared_law,
        .status = .implemented,
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
        .status = .implemented,
        .precondition = "the arrow is bound once and never used before its declaration",
    },
    .{
        .intent = .replace_export_arrow_with_function,
        .method = .declared_law,
        .status = .implemented,
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
        .intent = .lead_with_spread,
        .method = .kernel_identity,
        .status = .planned,
        .precondition = "no later key collides with a spread key",
    },
    // These two named M2 and could not be discharged by it: one turns a
    // statement into two and the other turns two into one, so the trees differ
    // by construction and parse identity refuses both. M4 is the method that
    // fits, and its precondition column carries the fact the law re-derives.
    // The one row M2 discharges, and the reason M2 exists. Writing the `;` a
    // program relied on insertion for makes the token stream longer and leaves
    // the tree exactly as the parser built it, which is the unique-parse
    // argument spec 5.5 makes - stated here as something that runs rather than
    // as prose. No precondition: parse identity compares whole programs, so
    // there is nothing for a law to re-derive.
    .{
        .intent = .insert_semicolon,
        .method = .parse_identity,
        .status = .implemented,
        .precondition = null,
    },
    .{
        .intent = .flatten_destructure,
        .method = .declared_law,
        .status = .implemented,
        .precondition = "the destructure binds exactly one field through one level, and nothing else in the file binds the name the rewrite introduces",
    },
    .{
        .intent = .drop_unused_index_alias,
        .method = .declared_law,
        .status = .implemented,
        .precondition = "neither the pair binding nor the index alias is read after the loop header",
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
    /// The validator ran and formed no answer. Distinct from both a refusal
    /// and an acceptance, and every caller must treat it as a reason not to
    /// apply: "undecided" is not "equivalent".
    ///
    /// No implemented method produces it today - it was M1's and M2's answer
    /// for a source the printer refused or a tree the comparison did not
    /// model, and both went out with them. It stays because it is the answer
    /// the next whole-program method will need, and because the wire publishes
    /// `undecided_equivalence` as a refusal reason a client already handles.
    undecided: []const u8,
};

/// Discharge one applied repair by its row's method.
///
/// `line` is the 1-based line the diagnostic reported. For a declared law two
/// obligations are checked, and both are needed: the edit must be confined to
/// the region starting at that line (a validator that only checked content
/// would accept a rewrite that also deleted a function three lines down), and
/// that region's new content must be what the law produces from its old
/// content.
///
/// Total: every outcome is a verdict. It allocates nothing and cannot fail,
/// because the one method that runs re-derives the rewrite into a stack buffer
/// and refuses a line too long to hold rather than growing one.
/// `error.OutOfMemory` is the only failure. Everything else is a verdict,
/// including "the tree carries a construct parse identity does not model",
/// which is an answer about the input rather than a fault in the check.
///
/// The allocator came back with M2. `3c1d5f6b` removed it because the only
/// allocating method discharged no row, and this is the change that gives one
/// a consumer: the semicolon insertion ASI removal needs, whose equivalence is
/// exactly the unique-parse argument spec 5.5 makes.
pub fn validateApplication(
    allocator: std.mem.Allocator,
    intent: RepairIntent,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) error{OutOfMemory}!Discharge {
    const row = find(intent) orelse return .no_validator;
    if (row.status != .implemented) return .no_validator;
    return dischargeByMethod(allocator, row.method, intent, original, repaired, line);
}

/// The method table. A row with no implemented method never reaches here
/// through `validateApplication`: it returns first.
pub fn dischargeByMethod(
    allocator: std.mem.Allocator,
    method: Method,
    intent: RepairIntent,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) error{OutOfMemory}!Discharge {
    return switch (method) {
        .declared_law => dischargeDeclaredLaw(intent, original, repaired, line),
        .parse_identity => dischargeParseIdentity(allocator, original, repaired),
        // M1 was built, ran, and discharged no row, so it went out with the
        // measurement. M3 has no kernel to elaborate into and M5 never
        // auto-applies. `.none` claims no equivalence at all.
        .layout_identity,
        .kernel_identity,
        .contract_equivalence,
        .none,
        => .no_validator,
    };
}

/// M2, parse identity: the two sources build the same tree, so the edit moved
/// tokens and not structure.
fn dischargeParseIdentity(
    allocator: std.mem.Allocator,
    original: []const u8,
    repaired: []const u8,
) error{OutOfMemory}!Discharge {
    return switch (try ir_identity.compare(allocator, original, repaired, .{})) {
        .identical => .equivalent,
        .differs => |why| .{ .not_law_shape = why },
        // A repaired source that does not parse is not the same program as one
        // that does, and saying so is the whole answer. An original that does
        // not parse leaves nothing to compare against.
        .unparsable => |side| switch (side) {
            .original => .{ .undecided = "the original does not parse, so there is no tree to compare against" },
            .repaired => .{ .not_law_shape = "the repaired source does not parse" },
        },
        .unmodeled => .{ .undecided = "the tree carries a construct parse identity does not model" },
    };
}

/// M4, declared law: re-derive the rewrite from the original and require the
/// edit to be exactly it.
///
/// Two skeletons, because the rewrites come in two shapes. A line-local law
/// replaces one line with one line. A region law replaces a run of lines with
/// a different-length run, which is what flattening a destructure (one line
/// becomes two) and collapsing an index alias (two become one) do.
fn dischargeDeclaredLaw(
    intent: RepairIntent,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) Discharge {
    if (lawFor(intent)) |law| return dischargeLineLocal(law, original, repaired, line);
    if (regionLawFor(intent)) |law| return dischargeRegionLocal(law, original, repaired, line);
    return .no_validator;
}

/// A law, as a function from the line it applies to onto the line it produces.
///
/// `null` means the original line is not the shape this law describes, which is
/// a refusal rather than an error: the diagnostic said one thing and the line
/// says another, and splicing on a partial match is the failure a validator is
/// here to prevent.
const LawFn = *const fn (before: []const u8, buf: []u8) ?[]const u8;

/// A law over a run of lines rather than one line.
///
/// `source` is the whole original file, which these laws need: their
/// preconditions are facts about the rest of the program - whether a name the
/// rewrite introduces is already bound, whether a name it drops is read later -
/// and neither is visible in the region alone.
const RegionLawFn = *const fn (
    source: []const u8,
    region: Region,
    before: []const u8,
    buf: []u8,
) ?[]const u8;

fn regionLawFor(intent: RepairIntent) ?RegionLawFn {
    return switch (intent) {
        .flatten_destructure => lawFlattenDestructure,
        .drop_unused_index_alias => lawDropUnusedIndexAlias,
        else => null,
    };
}

fn lawFor(intent: RepairIntent) ?LawFn {
    return switch (intent) {
        .drop_redundant_bool_compare => lawDropBoolCompare,
        .replace_let_with_const => lawLetToConst,
        .canonicalize_for_of_const => lawForOfLetToConst,
        .replace_compound_assign_with_explicit => lawCompoundAssign,
        .replace_arrow_with_function,
        .replace_export_arrow_with_function,
        => lawArrowToFunction,
        // Every other row is `.planned` or `.none`, so the caller's status
        // guard already returned.
        else => null,
    };
}

/// The shared skeleton for every line-local law: the edit must be confined to
/// the diagnostic's line, and that line's new content must be exactly what the
/// law produces from its old content.
///
/// Both halves are needed. A validator that only checked content would accept
/// a rewrite that also deleted a function three lines down; one that only
/// checked confinement would accept any edit to the right line.
fn dischargeLineLocal(
    law: LawFn,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) Discharge {
    const changed = singleChangedLine(original, repaired) orelse
        return .{ .not_law_shape = "the edit touches more than one line, or none" };
    if (changed != line) {
        return .{ .not_law_shape = "the changed line is not the line the diagnostic reported" };
    }

    const before = sourceLine(original, line) orelse
        return .{ .not_law_shape = "the reported line is past the end of the original" };
    const after = sourceLine(repaired, line) orelse
        return .{ .not_law_shape = "the reported line is past the end of the repaired source" };

    var buf: [4096]u8 = undefined;
    const expected = law(before, &buf) orelse
        return .{ .not_law_shape = "the original line is not the shape this law rewrites, or is too long to re-derive" };

    if (!std.mem.eql(u8, expected, after)) {
        return .{ .not_law_shape = "the new line is not the law's rewrite of the old one" };
    }
    return .equivalent;
}

/// The run of lines an edit changed, as 1-based line numbers and counts.
const Region = struct {
    /// First changed line, 1-based.
    first_line: u32,
    /// How many lines the region covers in the original.
    original_lines: u32,
    /// How many it covers in the repaired source.
    repaired_lines: u32,
};

/// The region skeleton: the same two obligations as `dischargeLineLocal`, for
/// a rewrite whose output is a different number of lines than its input.
fn dischargeRegionLocal(
    law: RegionLawFn,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) Discharge {
    const region = changedRegion(original, repaired) orelse
        return .{ .not_law_shape = "the edit changes nothing" };
    if (region.first_line != line) {
        return .{ .not_law_shape = "the changed region does not start at the line the diagnostic reported" };
    }

    const before = lineSpan(original, region.first_line, region.original_lines) orelse
        return .{ .not_law_shape = "the reported region runs past the end of the original" };
    const after = lineSpan(repaired, region.first_line, region.repaired_lines) orelse
        return .{ .not_law_shape = "the reported region runs past the end of the repaired source" };

    var buf: [8192]u8 = undefined;
    const expected = law(original, region, before, &buf) orelse
        return .{ .not_law_shape = "the original region is not the shape this law rewrites, or its precondition does not hold" };

    if (!std.mem.eql(u8, expected, after)) {
        return .{ .not_law_shape = "the new region is not the law's rewrite of the old one" };
    }
    return .equivalent;
}

/// The one contiguous run of lines that differs, or null when nothing does.
///
/// Computed as the lines between the common prefix and the common suffix, so
/// an edit that adds or removes lines is located as precisely as one that
/// replaces them. An edit that touches two separate places collapses into one
/// region spanning both, and the law then refuses it for not being its shape.
/// Both scans walk the sources rather than materializing a line table: this
/// runs on the request path, and one array per side big enough for any handler
/// is a quarter megabyte of stack for a comparison that needs none.
fn changedRegion(original: []const u8, repaired: []const u8) ?Region {
    const a_count = countLines(original);
    const b_count = countLines(repaired);

    var prefix: u32 = 0;
    var a_it = std.mem.splitScalar(u8, original, '\n');
    var b_it = std.mem.splitScalar(u8, repaired, '\n');
    while (prefix < a_count and prefix < b_count) : (prefix += 1) {
        if (!std.mem.eql(u8, a_it.next().?, b_it.next().?)) break;
    }
    if (prefix == a_count and prefix == b_count) return null;

    var suffix: u32 = 0;
    var a_end: usize = original.len;
    var b_end: usize = repaired.len;
    while (suffix < a_count - prefix and suffix < b_count - prefix) : (suffix += 1) {
        const a_start = if (std.mem.lastIndexOfScalar(u8, original[0..a_end], '\n')) |i| i + 1 else 0;
        const b_start = if (std.mem.lastIndexOfScalar(u8, repaired[0..b_end], '\n')) |i| i + 1 else 0;
        if (!std.mem.eql(u8, original[a_start..a_end], repaired[b_start..b_end])) break;
        a_end = if (a_start == 0) 0 else a_start - 1;
        b_end = if (b_start == 0) 0 else b_start - 1;
    }

    return .{
        .first_line = prefix + 1,
        .original_lines = a_count - prefix - suffix,
        .repaired_lines = b_count - prefix - suffix,
    };
}

/// Lines are newline-separated, so a source with no newline is one line and a
/// source ending in one has a final empty line. `lineSpan` counts the same way.
fn countLines(source: []const u8) u32 {
    var n: u32 = 1;
    for (source) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The bytes of `count` lines starting at 1-based `first`, without the newline
/// that ends the last of them. A zero count is the empty slice at that point,
/// which is what a pure insertion or deletion needs.
fn lineSpan(source: []const u8, first: u32, count: u32) ?[]const u8 {
    if (first == 0) return null;
    var start: usize = 0;
    var n: u32 = 1;
    while (n < first) : (n += 1) {
        start = (std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return null) + 1;
    }
    if (count == 0) return source[start..start];
    var end = start;
    var seen: u32 = 0;
    while (seen < count) : (seen += 1) {
        const nl = std.mem.indexOfScalarPos(u8, source, end, '\n');
        if (seen + 1 == count) {
            end = nl orelse source.len;
            break;
        }
        end = (nl orelse return null) + 1;
    }
    return source[start..end];
}

// ---------------------------------------------------------------------------
// The laws
//
// Each is an independent re-derivation, not a call into the rewriter that
// produced the edit. That is the whole point: a validator sharing the
// producer's scanner re-derives the same wrong answer and agrees with itself,
// so a producer that starts mis-locating a construct passes its own check.
// ---------------------------------------------------------------------------

/// `x === true` / `x !== false` -> `x`, and the two mirrors -> `!x`, for a
/// statically-boolean `x`.
fn lawDropBoolCompare(before: []const u8, buf: []u8) ?[]const u8 {
    const rewrite = lawRewrite(before) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{
        before[0..rewrite.span_start],
        if (rewrite.positive) "" else "!",
        rewrite.value,
        before[rewrite.span_end..],
    }) catch null;
}

/// `let x = e;` -> `const x = e;` for a binding the checker proved is never
/// reassigned. Indentation is preserved verbatim, and only the keyword moves.
///
/// Refuses a `for (let ...)` line even though the producer handles both from
/// one function: the two are separate intents, and accepting either here would
/// let a misclassified diagnostic discharge against the wrong law.
fn lawLetToConst(before: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOf(u8, before, "for (let ") != null) return null;
    const indent_len = leadingBlankLen(before);
    const rest = before[indent_len..];
    if (!std.mem.startsWith(u8, rest, "let ")) return null;
    return std.fmt.bufPrint(buf, "{s}const {s}", .{
        before[0..indent_len],
        rest["let ".len..],
    }) catch null;
}

/// `for (let x of xs)` -> `for (const x of xs)`.
fn lawForOfLetToConst(before: []const u8, buf: []u8) ?[]const u8 {
    const needle = "for (let ";
    const at = std.mem.indexOf(u8, before, needle) orelse return null;
    return std.fmt.bufPrint(buf, "{s}for (const {s}", .{
        before[0..at],
        before[at + needle.len ..],
    }) catch null;
}

/// `x += e;` -> `x = x + e;`, parenthesizing a compound right-hand side.
///
/// The parenthesization is the load-bearing part and the reason this law is
/// worth re-deriving rather than trusting. `total -= fee + tax` must become
/// `total = total - (fee + tax)`; without the parens it reassociates to
/// `(total - fee) + tax` and silently computes something else. A validator that
/// accepted the unparenthesized form would grade a value-changing edit as an
/// equivalence.
fn lawCompoundAssign(before: []const u8, buf: []u8) ?[]const u8 {
    const indent_len = leadingBlankLen(before);

    var i: usize = indent_len;
    while (i < before.len) : (i += 1) {
        if (before[i] != '=') continue;
        if (i == indent_len) continue;
        // `==` and `===` are comparisons, not compound assignments.
        if (i + 1 < before.len and before[i + 1] == '=') continue;
        const op = before[i - 1];
        if (!isArithmeticOpChar(op)) continue;

        const lhs = trimBlank(before[indent_len .. i - 1]);
        if (!isSimpleLvalue(lhs)) return null;

        const rhs = trimBlank(before[i + 1 ..]);
        if (rhs.len == 0) return null;

        const has_semi = rhs[rhs.len - 1] == ';';
        const expr = if (has_semi) trimBlank(rhs[0 .. rhs.len - 1]) else rhs;
        const trailer: []const u8 = if (has_semi) ";" else "";
        if (expr.len == 0) return null;
        // An interior `;` or a comment defeats the textual split, so the law
        // does not describe this line.
        if (std.mem.indexOfScalar(u8, expr, ';') != null) return null;
        if (std.mem.indexOf(u8, expr, "//") != null or std.mem.indexOf(u8, expr, "/*") != null) return null;

        if (isAtomicRhs(expr)) {
            return std.fmt.bufPrint(buf, "{s}{s} = {s} {c} {s}{s}", .{
                before[0..indent_len], lhs, lhs, op, expr, trailer,
            }) catch null;
        }
        if (!delimitersBalanced(expr)) return null;
        return std.fmt.bufPrint(buf, "{s}{s} = {s} {c} ({s}){s}", .{
            before[0..indent_len], lhs, lhs, op, expr, trailer,
        }) catch null;
    }
    return null;
}

/// `const f = (a: T): R => e;` -> `function f(a: T): R { return e; }`, and the
/// `export` form. A brace body is moved across as-is rather than wrapped.
///
/// The produced line carries no indentation, because the construct is
/// top-level by the rule that emits it and the producer trims. Re-deriving the
/// same way keeps the validator honest about what it is comparing against.
fn lawArrowToFunction(before: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = trimBlank(before);
    const is_export = std.mem.startsWith(u8, trimmed, "export const ");
    if (!is_export and !std.mem.startsWith(u8, trimmed, "const ")) return null;
    const rest = trimmed[(if (is_export) "export const ".len else "const ".len)..];

    const eq = assignmentEquals(rest) orelse return null;
    const name = trimBlank(rest[0..eq]);
    if (name.len == 0) return null;
    for (name) |c| {
        if (c == ':' or c == ' ' or c == '\t') return null;
    }

    const arrow_source = trimBlank(rest[eq + 1 ..]);
    const arrow = outermostArrow(arrow_source) orelse return null;
    const signature = trimBlank(arrow_source[0..arrow]);
    // A generic arrow is refused: the producer refuses it too, and a law that
    // accepted one here could discharge an edit nothing generated.
    if (std.mem.startsWith(u8, signature, "<")) return null;

    var body = trimBlank(arrow_source[arrow + 2 ..]);
    if (body.len > 0 and body[body.len - 1] == ';') body = trimBlank(body[0 .. body.len - 1]);
    if (body.len == 0) return null;

    const export_prefix: []const u8 = if (is_export) "export " else "";
    const parens_needed = !std.mem.startsWith(u8, signature, "(");

    if (body[0] == '{') {
        return if (parens_needed)
            std.fmt.bufPrint(buf, "{s}function {s}({s}) {s}", .{ export_prefix, name, signature, body }) catch null
        else
            std.fmt.bufPrint(buf, "{s}function {s}{s} {s}", .{ export_prefix, name, signature, body }) catch null;
    }
    return if (parens_needed)
        std.fmt.bufPrint(buf, "{s}function {s}({s}) {{ return {s}; }}", .{ export_prefix, name, signature, body }) catch null
    else
        std.fmt.bufPrint(buf, "{s}function {s}{s} {{ return {s}; }}", .{ export_prefix, name, signature, body }) catch null;
}

/// ZTS618. `const {outer: {inner}} = rhs;` becomes
/// `const {outer} = rhs;` followed by `const {inner} = outer;`.
///
/// The rewrite introduces a binding the program did not have, which is the
/// only way it can stop being an equivalence: if `outer` already names
/// something the rest of the file uses, the new declaration shadows it. That
/// precondition is re-derived here rather than taken from the producer, and it
/// is deliberately conservative - any binding of the name anywhere outside the
/// rewritten line refuses, whether or not it is in scope, and the scan works in
/// logical lines so a declaration head or parameter list broken across physical
/// lines cannot hide one.
fn lawFlattenDestructure(
    source: []const u8,
    region: Region,
    before: []const u8,
    buf: []u8,
) ?[]const u8 {
    if (region.original_lines != 1 or region.repaired_lines != 2) return null;

    const indent_len = leadingBlankLen(before);
    const rest = before[indent_len..];
    if (!std.mem.startsWith(u8, rest, "const ")) return null;

    const open = std.mem.indexOfScalar(u8, before, '{') orelse return null;
    const close = matchingBrace(before, open) orelse return null;
    const eq = topLevelEquals(before, close + 1) orelse return null;

    const rhs = trimBlank(before[eq + 1 ..]);
    if (rhs.len == 0) return null;
    // An expression that does not finish on this line would be truncated by a
    // two-line replacement, so the law does not describe it.
    if (!delimitersBalanced(rhs)) return null;

    const pattern = trimBlank(before[open + 1 .. close]);
    const colon = topLevelColon(pattern) orelse return null;
    const outer = trimBlank(pattern[0..colon]);
    if (!isSimpleIdentifier(outer)) return null;

    const nested = trimBlank(pattern[colon + 1 ..]);
    if (nested.len < 2 or nested[0] != '{' or nested[nested.len - 1] != '}') return null;
    const inner = trimBlank(nested[1 .. nested.len - 1]);
    if (!isFlatIdentifierList(inner)) return null;

    // The precondition. `outer` becomes a binding here, so nothing else may
    // bind it.
    if (bindsOutsideRegion(source, region, outer)) return null;

    const indent = before[0..indent_len];
    return std.fmt.bufPrint(buf, "{s}const {{{s}}} = {s}\n{s}const {{{s}}} = {s};", .{
        indent, outer, rhs, indent, inner, outer,
    }) catch null;
}

/// ZTS619. A for-of over `xs.entries()` whose body opens by destructuring the
/// pair into `[index, value]` becomes a for-of over `xs` binding `value`.
///
/// Two names disappear: the pair and the index. The rewrite is an equivalence
/// only where neither is read afterwards, and both halves are re-derived here.
/// The checker establishes the index is unread inside the loop, and nothing
/// establishes the pair is - the producer checks that for itself, which is
/// exactly the check a validator must not borrow.
fn lawDropUnusedIndexAlias(
    source: []const u8,
    region: Region,
    before: []const u8,
    buf: []u8,
) ?[]const u8 {
    if (region.original_lines != 2 or region.repaired_lines != 1) return null;

    const split = std.mem.indexOfScalar(u8, before, '\n') orelse return null;
    const for_line = before[0..split];
    const destructure_line = before[split + 1 ..];

    const indent_len = leadingBlankLen(for_line);
    const indent = for_line[0..indent_len];
    var rest = for_line[indent_len..];

    const prefix = "for (const ";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    rest = rest[prefix.len..];
    const binding_end = identEnd(rest) orelse return null;
    const binding = rest[0..binding_end];
    rest = trimLeadingBlank(rest[binding_end..]);
    if (!std.mem.startsWith(u8, rest, "of ")) return null;
    rest = trimLeadingBlank(rest["of ".len..]);

    const entries = std.mem.lastIndexOf(u8, rest, ".entries()") orelse return null;
    const iterable = trimBlank(rest[0..entries]);
    if (iterable.len == 0) return null;
    var tail = trimLeadingBlank(rest[entries + ".entries()".len ..]);
    if (tail.len == 0 or tail[0] != ')') return null;
    tail = trimLeadingBlank(tail[1..]);
    if (tail.len == 0 or tail[0] != '{') return null;
    if (trimBlank(tail[1..]).len != 0) return null;

    // `const [index, value] = binding;`
    var d = trimLeadingBlank(destructure_line);
    if (!std.mem.startsWith(u8, d, "const [")) return null;
    d = d["const [".len..];
    const bracket = std.mem.indexOfScalar(u8, d, ']') orelse return null;
    const elements = d[0..bracket];
    const comma = std.mem.indexOfScalar(u8, elements, ',') orelse return null;
    if (std.mem.indexOfScalarPos(u8, elements, comma + 1, ',') != null) return null;
    const index_name = trimBlank(elements[0..comma]);
    const value_name = trimBlank(elements[comma + 1 ..]);
    if (!isSimpleIdentifier(index_name) or !isSimpleIdentifier(value_name)) return null;

    var after_bracket = trimLeadingBlank(d[bracket + 1 ..]);
    if (after_bracket.len == 0 or after_bracket[0] != '=') return null;
    after_bracket = std.mem.trim(u8, after_bracket[1..], " \t\r;");
    if (!std.mem.eql(u8, after_bracket, binding)) return null;

    // The preconditions. Both dropped names must be dead from here on.
    if (readAfterRegion(source, region, binding)) return null;
    if (readAfterRegion(source, region, index_name)) return null;

    return std.fmt.bufPrint(buf, "{s}for (const {s} of {s}) {{", .{
        indent, value_name, iterable,
    }) catch null;
}

/// True when any binding outside the changed region binds `ident`.
///
/// The unit is the logical line, not the physical one: a declaration head or a
/// parameter list broken across lines is examined as the one declaration it is.
/// A physical-line scan sees `const {`, then `  user,`, then `} = cfg;` and
/// finds no line that declares `user`, and the same for a parameter on its own
/// line - so it answers "nothing binds this" for two forms that do, and the
/// caller then grades a capture as an equivalence.
///
/// Over-approximates otherwise. It covers the binding forms the language has -
/// `const`/`let` declarations including destructuring heads, arrow and function
/// parameters, a for-of binding, and an import specifier - and it does not ask
/// whether the binding is in scope at the rewrite site. A refusal costs a
/// repair; a miss is unsound.
pub fn bindsOutsideLines(
    source: []const u8,
    first_line: u32,
    line_count: u32,
    ident: []const u8,
) bool {
    var i: usize = 0;
    var line_no: u32 = 1;
    while (i < source.len) {
        const start_line = line_no;
        const end = logicalLineEnd(source, i, &line_no);
        const inside = start_line >= first_line and start_line < first_line + line_count;
        if (!inside and lineBinds(source[i..end], ident)) return true;
        if (end >= source.len) break;
        line_no += 1;
        i = end + 1;
    }
    return false;
}

fn bindsOutsideRegion(source: []const u8, region: Region, ident: []const u8) bool {
    return bindsOutsideLines(source, region.first_line, region.original_lines, ident);
}

/// Index of the newline that ends the logical line starting at `start`, or the
/// length of the source. `line_no` is advanced past every newline swallowed.
///
/// A line continues into the next while a `(` or `[` it opened is still open,
/// and - only for a declaration head - while a `{` is. The brace case is
/// restricted that way because an unrestricted one would swallow a function
/// body whole: `function f() {` opens a brace that closes pages later, and the
/// whole body would then read as one declaration naming everything in it.
fn logicalLineEnd(source: []const u8, start: usize, line_no: *u32) usize {
    const first_line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const head = trimLeadingBlank(source[start..first_line_end]);
    const decl_head = std.mem.startsWith(u8, head, "const ") or
        std.mem.startsWith(u8, head, "let ") or
        std.mem.startsWith(u8, head, "var ") or
        std.mem.startsWith(u8, head, "import ") or
        std.mem.startsWith(u8, head, "export const ") or
        std.mem.startsWith(u8, head, "export let ");

    var round: i32 = 0;
    var curly: i32 = 0;
    var i = start;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            // Bounded to the line: a literal that does not close on its own
            // line is malformed, and following it further would swallow lines
            // whose bindings this scan exists to find.
            '"', '\'', '`' => {
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                if (skipStringLiteral(source[0..line_end], i)) |close| i = close;
            },
            '(', '[' => round += 1,
            ')', ']' => {
                if (round > 0) round -= 1;
            },
            '{' => curly += 1,
            '}' => {
                if (curly > 0) curly -= 1;
            },
            '\n' => {
                if (round == 0 and (curly == 0 or !decl_head)) return i;
                line_no.* += 1;
            },
            else => {},
        }
    }
    return source.len;
}

/// True when `ident` appears as a token on any line after the changed region.
fn readAfterRegion(source: []const u8, region: Region, ident: []const u8) bool {
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 0;
    while (it.next()) |line| {
        n += 1;
        if (n < region.first_line + region.original_lines) continue;
        if (tokenAppears(line, ident)) return true;
    }
    return false;
}

/// True when the logical line declares `ident`. Written against a span that may
/// carry newlines: every scan below is by index, not by line.
fn lineBinds(line: []const u8, ident: []const u8) bool {
    var t = trimLeadingBlank(line);
    if (std.mem.startsWith(u8, t, "export ")) t = trimLeadingBlank(t["export ".len..]);

    // `const x = ...`, `let {a, b} = ...`: everything left of the binding `=`.
    inline for (.{ "const ", "let " }) |kw| {
        if (std.mem.startsWith(u8, t, kw)) {
            const eq = topLevelEquals(t, kw.len) orelse t.len;
            if (tokenAppears(t[kw.len..eq], ident)) return true;
        }
    }
    // An arrow's parameters sit left of the `=>`, whichever declaration the
    // line opens with.
    if (std.mem.indexOf(u8, t, "=>")) |arrow| {
        if (tokenAppears(t[0..arrow], ident)) return true;
    }
    // A function's name and parameter list.
    if (std.mem.indexOf(u8, t, "function ")) |at| {
        if (tokenAppears(t[at..], ident)) return true;
    }
    // A for-of binding.
    if (std.mem.indexOf(u8, t, "for (")) |at| {
        const head = t[at..];
        const of = std.mem.indexOf(u8, head, " of ") orelse head.len;
        if (tokenAppears(head[0..of], ident)) return true;
    }
    // An import clause binds every name it lists.
    if (std.mem.startsWith(u8, t, "import ")) {
        if (tokenAppears(t, ident)) return true;
    }
    return false;
}

fn tokenAppears(text: []const u8, ident: []const u8) bool {
    if (ident.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) {
        if (!isIdentStart(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < text.len and isIdentContinue(text[i])) i += 1;
        if (std.mem.eql(u8, text[start..i], ident)) return true;
    }
    return false;
}

fn identEnd(s: []const u8) ?usize {
    if (s.len == 0 or !isIdentStart(s[0])) return null;
    var i: usize = 1;
    while (i < s.len and isIdentContinue(s[i])) i += 1;
    return i;
}

fn isSimpleIdentifier(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentContinue(c)) return false;
    }
    return true;
}

/// `a, b, c` - the only inner pattern the flatten law rewrites, because a
/// nested or renamed field would need a second level of rewriting.
fn isFlatIdentifierList(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (!isSimpleIdentifier(trimBlank(part))) return false;
    }
    return true;
}

fn trimLeadingBlank(s: []const u8) []const u8 {
    return s[leadingBlankLen(s)..];
}

/// Index of the `}` closing the `{` at `open`, within one line, ignoring
/// brackets inside string literals.
fn matchingBrace(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '{') return null;
    var depth: i32 = 0;
    var i = open;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '"', '\'', '`' => i = skipStringLiteral(line, i) orelse return null,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Index of the first `=` at nesting depth zero at or after `from`, skipping
/// `==`, `=>`, and the comparison operators.
fn topLevelEquals(line: []const u8, from: usize) ?usize {
    var depth: i32 = 0;
    var i = from;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '"', '\'', '`' => i = skipStringLiteral(line, i) orelse return null,
            '{', '[', '(' => depth += 1,
            '}', ']', ')' => depth -= 1,
            '=' => {
                if (depth != 0) continue;
                if (i + 1 < line.len and (line[i + 1] == '=' or line[i + 1] == '>')) continue;
                if (i > from and (line[i - 1] == '=' or line[i - 1] == '!' or line[i - 1] == '<' or line[i - 1] == '>')) continue;
                return i;
            },
            else => {},
        }
    }
    return null;
}

/// Index of the first `:` at nesting depth zero, which is the field separator
/// of a one-level destructuring pattern.
fn topLevelColon(pattern: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '"', '\'', '`' => i = skipStringLiteral(pattern, i) orelse return null,
            '{', '[', '(' => depth += 1,
            '}', ']', ')' => depth -= 1,
            ':' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

/// Index of the closing quote of the literal opening at `start`, or null when
/// it does not close on this line.
fn skipStringLiteral(text: []const u8, start: usize) ?usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i;
    }
    return null;
}

fn leadingBlankLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i;
}

fn trimBlank(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn isArithmeticOpChar(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '%';
}

/// A single atom needs no parentheses: `n += 1` is `n = n + 1`, not
/// `n = n + (1)`, and the producer emits the former.
fn isAtomicRhs(expr: []const u8) bool {
    if (expr.len == 0) return false;
    for (expr) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.')) return false;
    }
    return true;
}

/// True when the expression opens and closes every delimiter it uses, and every
/// string literal in it finishes.
///
/// Braces count for the same reason parentheses do. A two-line replacement
/// splices a declaration in after this line, so an object literal or a template
/// that continues onto the next line would be cut in half by the splice, and a
/// balance check blind to `{` would call that shape finished.
fn delimitersBalanced(expr: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        switch (expr[i]) {
            '"', '\'', '`' => i = skipStringLiteral(expr, i) orelse return false,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth < 0) return false;
            },
            else => {},
        }
    }
    return depth == 0;
}

/// Index of the `=` that binds the declaration, skipping `=>` and `==`.
fn assignmentEquals(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '=') continue;
        if (i + 1 < s.len and (s[i + 1] == '=' or s[i + 1] == '>')) continue;
        if (i > 0 and (s[i - 1] == '=' or s[i - 1] == '!' or s[i - 1] == '<' or s[i - 1] == '>')) continue;
        return i;
    }
    return null;
}

/// Index of the `=` in the first `=>` at nesting depth zero. A parameter typed
/// as a function (`(fn: (x: number) => string) => body`) carries an inner `=>`
/// that is not the arrow being rewritten.
fn outermostArrow(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '<' => depth += 1,
            ')', ']', '>' => {
                // A `>` that closes an arrow is not a closer; check for the
                // arrow first so `=>` at depth zero is not read as a bracket.
                if (s[i] == '>' and i > 0 and s[i - 1] == '=') continue;
                depth -= 1;
            },
            '=' => if (s[i + 1] == '>' and depth == 0) return i,
            else => {},
        }
    }
    return null;
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
    // The property that keeps the wire honest, and it still has live examples
    // now that the M4 rows are discharged: `replace_ternary_with_if` names M3,
    // which is the right method for it, and the semantic kernel M3 needs does
    // not exist. Naming it does not make the rewrite advertisable.
    const row = find(.replace_ternary_with_if).?;
    try std.testing.expectEqual(Method.kernel_identity, row.method);
    try std.testing.expectEqual(Status.planned, row.status);
    try std.testing.expect(row.precondition != null);
    try std.testing.expect(!row.gradable());
}

test "every gradable row has a law, and every law has a gradable row" {
    // The registry shipped with nothing gradable and this test counted that.
    // A count alone stops being useful once there is more than one row, so it
    // now asserts the two directions that actually matter: a row cannot claim
    // `implemented` without a law behind it, and a law cannot exist for a row
    // that still says `planned`. Either drift is a lie in a published field.
    //
    // "A law" means either skeleton: a line-local one, or the region-local one
    // the two multi-line rewrites use. A row served by neither and still
    // claiming M4 is the drift being caught.
    var gradable_count: usize = 0;
    for (rows) |row| {
        const has_law = lawFor(row.intent) != null or regionLawFor(row.intent) != null;
        if (row.gradable()) {
            gradable_count += 1;
            // What `implemented` has to mean: `dischargeByMethod` reaches
            // something for this row's method. M4 is the only one that does,
            // and it needs a law of its own. Every other method answers
            // `.no_validator` there, so a row naming one and claiming
            // `implemented` advertises a repair the apply path then refuses
            // with `ungraded_intent`.
            const dischargeable = switch (row.method) {
                .declared_law => has_law,
                // M2 needs no law: it compares whole trees, so there is
                // nothing per-row to re-derive. `dischargeByMethod` reaches
                // `ir_identity.compare` for it.
                .parse_identity => true,
                .layout_identity,
                .kernel_identity,
                .contract_equivalence,
                .none,
                => false,
            };
            if (!dischargeable) {
                std.debug.print("row {s} is implemented with nothing to discharge it\n", .{@tagName(row.intent)});
                return error.TestFailed;
            }
        } else if (has_law) {
            std.debug.print("row {s} has a law and does not advertise it\n", .{@tagName(row.intent)});
            return error.TestFailed;
        }
    }
    // Eight under M4 plus the one under M2, which is the semicolon insertion
    // ASI removal needs and the only row parse identity discharges.
    try std.testing.expectEqual(@as(usize, 9), gradable_count);
}

test "parse identity discharges a written semicolon" {
    // The unique-parse argument spec 5.5 makes, as something that runs: writing
    // the `;` a program relied on insertion for lengthens the token stream and
    // leaves the tree the parser built exactly as it was.
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(
            std.testing.allocator,
            .insert_semicolon,
            "const a = 1\nconst b = 2\n",
            "const a = 1;\nconst b = 2;\n",
            1,
        ),
    );
}

test "parse identity refuses an edit that moves structure, not just tokens" {
    // The floor. A method that accepted everything would discharge the row and
    // grade an arbitrary edit as an equivalence, which is the one answer a
    // validator must never give.
    const changed_value = try validateApplication(
        std.testing.allocator,
        .insert_semicolon,
        "const a = 1\n",
        "const a = 2;\n",
        1,
    );
    try std.testing.expect(changed_value == .not_law_shape);

    const added_statement = try validateApplication(
        std.testing.allocator,
        .insert_semicolon,
        "const a = 1\n",
        "const a = 1;\nconst b = 2;\n",
        1,
    );
    try std.testing.expect(added_statement == .not_law_shape);

    // A repaired source that does not parse is not the same program as one
    // that does.
    const broken = try validateApplication(
        std.testing.allocator,
        .insert_semicolon,
        "const a = 1\n",
        "const a = ;\n",
        1,
    );
    try std.testing.expect(broken == .not_law_shape);
}

test "let becomes const, and the for-of form is a different law" {
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .replace_let_with_const, "  let n = 1;\n", "  const n = 1;\n", 1),
    );
    // Indentation is preserved verbatim, so a reflowed line is not the law.
    const reflowed = try validateApplication(std.testing.allocator, .replace_let_with_const, "  let n = 1;\n", "const n = 1;\n", 1);
    try std.testing.expect(reflowed == .not_law_shape);

    // The producer handles both from one function; the two intents are
    // separate here so a misclassified diagnostic cannot discharge against the
    // wrong law.
    const wrong_law = try validateApplication(
        std.testing.allocator,
        .replace_let_with_const,
        "  for (let x of xs) {\n",
        "  for (const x of xs) {\n",
        1,
    );
    try std.testing.expect(wrong_law == .not_law_shape);
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .canonicalize_for_of_const, "  for (let x of xs) {\n", "  for (const x of xs) {\n", 1),
    );
}

test "a compound assignment must parenthesize a compound right-hand side" {
    // The load-bearing case. `total -= fee + tax` is `total = total - (fee +
    // tax)`; without the parens it reassociates to `(total - fee) + tax` and
    // computes something else, so accepting the unparenthesized form would
    // grade a value-changing edit as an equivalence.
    const unparenthesized = try validateApplication(
        std.testing.allocator,
        .replace_compound_assign_with_explicit,
        "  total -= fee + tax;\n",
        "  total = total - fee + tax;\n",
        1,
    );
    try std.testing.expect(unparenthesized == .not_law_shape);

    try std.testing.expectEqual(
        Discharge.equivalent,
        validateApplication(
            std.testing.allocator,
            .replace_compound_assign_with_explicit,
            "  total -= fee + tax;\n",
            "  total = total - (fee + tax);\n",
            1,
        ),
    );

    // A single atom needs no parens, and the law says so rather than
    // accepting either spelling.
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .replace_compound_assign_with_explicit, "  n += 1;\n", "  n = n + 1;\n", 1),
    );
    const over_parenthesized = try validateApplication(
        std.testing.allocator,
        .replace_compound_assign_with_explicit,
        "  n += 1;\n",
        "  n = n + (1);\n",
        1,
    );
    try std.testing.expect(over_parenthesized == .not_law_shape);
}

test "an arrow becomes a function, expression body wrapped in a return" {
    try std.testing.expectEqual(
        Discharge.equivalent,
        validateApplication(
            std.testing.allocator,
            .replace_arrow_with_function,
            "const parse = (x: number): number => x;\n",
            "function parse(x: number): number { return x; }\n",
            1,
        ),
    );
    try std.testing.expectEqual(
        Discharge.equivalent,
        validateApplication(
            std.testing.allocator,
            .replace_export_arrow_with_function,
            "export const load = (id: string): Response => Response.text(id);\n",
            "export function load(id: string): Response { return Response.text(id); }\n",
            1,
        ),
    );

    // Dropping `export` changes what the module exports. A rewrite that did it
    // would still type-check inside the file and is not this law.
    const dropped_export = try validateApplication(
        std.testing.allocator,
        .replace_export_arrow_with_function,
        "export const load = (id: string): Response => Response.text(id);\n",
        "function load(id: string): Response { return Response.text(id); }\n",
        1,
    );
    try std.testing.expect(dropped_export == .not_law_shape);
}

test "outermostArrow skips an arrow inside a parameter type" {
    // `(fn: (x: number) => string) => body` carries an inner `=>` that is not
    // the arrow being rewritten. Splitting on the first one would make the
    // signature `(fn: (x: number)` and the body `string) => body`.
    const s = "(fn: (x: number) => string) => body";
    const at = outermostArrow(s).?;
    try std.testing.expectEqualStrings("(fn: (x: number) => string)", trimBlank(s[0..at]));
    try std.testing.expectEqualStrings("body", trimBlank(s[at + 2 ..]));
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
        try validateApplication(std.testing.allocator, .drop_redundant_bool_compare, original, repaired, 2),
    );
}

test "the negated form discharges" {
    const original = "const blocked = flag === false;";
    const repaired = "const blocked = !flag;";
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .drop_redundant_bool_compare, original, repaired, 1),
    );
}

test "a rewrite that is not the law is refused" {
    // Same line, same diagnostic, and the edit inverts the meaning. The whole
    // point of re-deriving rather than diffing is that this is caught.
    const original = "const ready = flag === true;";
    const repaired = "const ready = !flag;";
    const answer = try validateApplication(std.testing.allocator, .drop_redundant_bool_compare, original, repaired, 1);
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
    const answer = try validateApplication(std.testing.allocator, .drop_redundant_bool_compare, original, repaired, 1);
    try std.testing.expect(answer == .not_law_shape);
}

test "two candidates on one line refuse rather than guess" {
    const original = "const both = a === true && b === true;";
    const repaired = "const both = a && b === true;";
    const answer = try validateApplication(std.testing.allocator, .drop_redundant_bool_compare, original, repaired, 1);
    try std.testing.expect(answer == .not_law_shape);
}

test "a planned intent has no validator" {
    // Distinct from a refusal: the edit is never examined. `lead_with_spread`
    // names M3 and nothing runs it, so an edit carrying it gets no verdict
    // rather than a negative one.
    const answer = try validateApplication(std.testing.allocator, .lead_with_spread, "const a = {...b, c};", "const a = {...b, c};", 1);
    try std.testing.expect(answer == .no_validator);
}

test "no planned row can advertise a repair" {
    // Walked over the table rather than asserted for one row: the property is
    // about the registry, and naming a row here would keep passing after that
    // row changed and a different one went wrong.
    for (rows) |row| {
        if (row.status == .implemented) continue;
        try std.testing.expect(!row.gradable());
        try std.testing.expect(!gradable(row.intent));
        const answer = try validateApplication(std.testing.allocator, row.intent, "const a = 1;\n", "const a = 1;\n", 1);
        try std.testing.expect(answer == .no_validator);
    }
}

test "a nested destructure flattens, and a capture is refused" {
    const original =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name);
        \\}
    ;
    const repaired =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user} = payload;
        \\  const {name} = user;
        \\  return Response.text(name);
        \\}
    ;
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .flatten_destructure, original, repaired, 3),
    );

    // The precondition, re-derived here rather than trusted: the rewrite
    // introduces a binding named `user`, and this file already has one. The
    // two-statement form would shadow it, which is a different program.
    const captures =
        \\const user = "global";
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name);
        \\}
    ;
    const captured =
        \\const user = "global";
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user} = payload;
        \\  const {name} = user;
        \\  return Response.text(name);
        \\}
    ;
    const refused = try validateApplication(std.testing.allocator, .flatten_destructure, captures, captured, 4);
    try std.testing.expect(refused == .not_law_shape);
}

test "an unused index alias collapses, and a live name is refused" {
    const original =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    return Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    const repaired =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const item of items) {
        \\    return Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    try std.testing.expectEqual(
        Discharge.equivalent,
        try validateApplication(std.testing.allocator, .drop_unused_index_alias, original, repaired, 3),
    );

    // The index alias is what the loop drops. A body that reads it is left
    // naming something the rewrite deleted, so the law refuses even though the
    // text of the header rewrite is exactly right.
    const reads_index =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    return Response.text(item + _i);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    const dropped_index =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const item of items) {
        \\    return Response.text(item + _i);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    const refused_index = try validateApplication(std.testing.allocator, .drop_unused_index_alias, reads_index, dropped_index, 3);
    try std.testing.expect(refused_index == .not_law_shape);

    // Same for the pair binding, which nothing but the producer ever checked.
    const reads_pair =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    return Response.text(item + pair[0]);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    const dropped_pair =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const item of items) {
        \\    return Response.text(item + pair[0]);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    const refused_pair = try validateApplication(std.testing.allocator, .drop_unused_index_alias, reads_pair, dropped_pair, 3);
    try std.testing.expect(refused_pair == .not_law_shape);
}

test "a region edit outside the reported line is refused" {
    const original =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name);
        \\}
    ;
    const repaired =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user} = payload;
        \\  const {name} = user;
        \\  return Response.text(name);
        \\}
    ;
    const answer = try validateApplication(std.testing.allocator, .flatten_destructure, original, repaired, 2);
    try std.testing.expect(answer == .not_law_shape);
}

test "a binding wrapped across lines still refuses the flatten" {
    // The capture the line-oriented scan used to miss. `user` is bound by a
    // destructuring head split over three lines, so no single line reads as a
    // declaration of it, and the rewrite's `const {user} = payload;` shadows
    // the outer binding: `name + user` would read the new object rather than
    // the one line 2 bound.
    const original =
        \\const {
        \\  user,
        \\} = config;
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name + user);
        \\}
    ;
    const repaired =
        \\const {
        \\  user,
        \\} = config;
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user} = payload;
        \\  const {name} = user;
        \\  return Response.text(name + user);
        \\}
    ;
    const answer = try validateApplication(std.testing.allocator, .flatten_destructure, original, repaired, 6);
    try std.testing.expect(answer == .not_law_shape);
}

test "a parameter list wrapped across lines still refuses the flatten" {
    // The same capture through the other multi-line form: the parameter sits
    // on its own line, so the line carrying `function` does not name it.
    const original =
        \\function outer(
        \\  user: string,
        \\): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name + user);
        \\}
    ;
    const repaired =
        \\function outer(
        \\  user: string,
        \\): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user} = payload;
        \\  const {name} = user;
        \\  return Response.text(name + user);
        \\}
    ;
    const answer = try validateApplication(std.testing.allocator, .flatten_destructure, original, repaired, 5);
    try std.testing.expect(answer == .not_law_shape);
}

test "an object-literal right-hand side that runs past the line refuses" {
    // `delimitersBalanced` used to count only `()` and `[]`, so an object
    // literal continuing onto the next line read as finished and the law
    // spliced `const {name} = user;` into the middle of it.
    const original =
        \\function handler(req: Request): Response {
        \\  const {user: {name}} = { user: { name: "ada" },
        \\    other: 1 };
        \\  return Response.text(name);
        \\}
    ;
    const repaired =
        \\function handler(req: Request): Response {
        \\  const {user} = { user: { name: "ada" },
        \\  const {name} = user;
        \\    other: 1 };
        \\  return Response.text(name);
        \\}
    ;
    const answer = try validateApplication(std.testing.allocator, .flatten_destructure, original, repaired, 2);
    try std.testing.expect(answer == .not_law_shape);
}
