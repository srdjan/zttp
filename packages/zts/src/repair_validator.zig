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
//! discharged a single row. Every rewrite here changes the tree, so parse
//! identity refuses them all, and layout identity is strictly weaker than parse
//! identity. Their case is the rewrite that moves
//! a token without moving structure, which is the semicolon spec 5.5 forbids
//! ASI from inserting; the code went out with the measurement rather than being
//! carried against a rewrite that does not exist yet. M3 needs the semantic
//! kernel, which spec section 10 defers. M5 is advisory-only by construction.
//! That leaves M4, whose machinery already runs under z3 in `scripts/verify.sh`
//! and whose published shape - a law plus "the law's own preconditions carried
//! into the row's precondition column" - is the shape these rewrites need.
//!
//! Where a precondition comes from is part of the row. It is the checker: the
//! rewrite is sound exactly where the diagnostic that requested it fired.
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
    // `.planned`, not `.implemented`, so nothing advertises this repair or
    // auto-applies it. M2 as wired parses BOTH sides under the ASI grammar the
    // compiler no longer ships, so it certified two mutually inconsistent
    // programs as equivalent to the same original: with `return` on its own
    // line, writing the `;` one way yields `return;` and the other yields
    // `return r;`, and tree identity under the permissive grammar cannot tell
    // them apart. The row returns to `.implemented` when the repaired side is
    // compared under the shipping grammar.
    .{
        .intent = .insert_semicolon,
        .method = .parse_identity,
        .status = .planned,
        .precondition = null,
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
    .{
        .intent = .declare_boundary_type,
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
fn dischargeDeclaredLaw(
    intent: RepairIntent,
    original: []const u8,
    repaired: []const u8,
    line: u32,
) Discharge {
    if (lawFor(intent)) |law| return dischargeLineLocal(law, original, repaired, line);
    return .no_validator;
}

/// A law, as a function from the line it applies to onto the line it produces.
///
/// `null` means the original line is not the shape this law describes, which is
/// a refusal rather than an error: the diagnostic said one thing and the line
/// says another, and splicing on a partial match is the failure a validator is
/// here to prevent.
const LawFn = *const fn (before: []const u8, buf: []u8) ?[]const u8;

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

test "declaring an exported boundary type is not advertised as an automatic repair" {
    const row = find(.declare_boundary_type) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Method.none, row.method);
    try std.testing.expectEqual(Status.not_applicable, row.status);
    try std.testing.expect(!row.gradable());
    try std.testing.expect(!gradable(.declare_boundary_type));
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
    // A row without a line-local law that still claims M4 is the drift being
    // caught.
    var gradable_count: usize = 0;
    for (rows) |row| {
        const has_law = lawFor(row.intent) != null;
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
    // Six, all under M4. The one M2 row is `.planned` while its pipeline is
    // withdrawn, so it is not gradable and advertises nothing.
    try std.testing.expectEqual(@as(usize, 6), gradable_count);
}

test "the withdrawn semicolon row advertises nothing" {
    // While the row is `.planned`, `validateApplication` must answer
    // `no_validator` for it - the apply path then refuses the intent rather
    // than applying an edit nothing checked.
    try std.testing.expect(!gradable(.insert_semicolon));
    try std.testing.expectEqual(
        Discharge.no_validator,
        try validateApplication(
            std.testing.allocator,
            .insert_semicolon,
            "const a = 1\n",
            "const a = 1;\n",
            1,
        ),
    );
}

test "parse identity discharges a written semicolon" {
    // The unique-parse argument spec 5.5 makes, as something that runs: writing
    // the `;` a program relied on insertion for lengthens the token stream and
    // leaves the tree the parser built exactly as it was.
    try std.testing.expectEqual(
        Discharge.equivalent,
        try dischargeParseIdentity(
            std.testing.allocator,
            "const a = 1\nconst b = 2\n",
            "const a = 1;\nconst b = 2;\n",
        ),
    );
}

test "parse identity refuses an edit that moves structure, not just tokens" {
    // The floor. A method that accepted everything would discharge the row and
    // grade an arbitrary edit as an equivalence, which is the one answer a
    // validator must never give.
    const changed_value = try dischargeParseIdentity(
        std.testing.allocator,
        "const a = 1\n",
        "const a = 2;\n",
    );
    try std.testing.expect(changed_value == .not_law_shape);

    const added_statement = try dischargeParseIdentity(
        std.testing.allocator,
        "const a = 1\n",
        "const a = 1;\nconst b = 2;\n",
    );
    try std.testing.expect(added_statement == .not_law_shape);

    // A repaired source that does not parse is not the same program as one
    // that does.
    const broken = try dischargeParseIdentity(
        std.testing.allocator,
        "const a = 1\n",
        "const a = ;\n",
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
