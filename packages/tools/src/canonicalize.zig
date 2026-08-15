//! Compiler-authored canonical refactor previews.
//!
//! Emits local rewrite intents only. Callers still apply any replacement
//! through edit-simulate / compiler veto; this module never writes source.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");
const edit_simulate = @import("edit_simulate.zig");
const writeJsonString = zts.writeJsonString;
const repairPolicy = zts.RepairPolicy;
pub const RepairIntent = zts.RepairIntent;

/// One rewrite, span-keyed (D3 §5).
///
/// This is the single repair vocabulary. Two used to exist: a line-keyed
/// `Refactor` that refused any replacement containing a newline and any two
/// rewrites touching one line, and a span-keyed `Repair` for the
/// multi-line rules. Two representations meant two apply paths, two sets of
/// guards, and a scheduling rule ("line-keyed takes absolute priority") that
/// existed only to keep them apart.
///
/// A whole-line rewrite is a span rewrite over the line's bytes, so the
/// line-keyed producers lost nothing by moving: `appendRepairUnique` computes
/// the span from the line it was already replacing whole. What the move buys is
/// that a replacement may now contain newlines, and that two rewrites on one
/// line are refused for the reason that is actually true - their spans overlap -
/// rather than because the applier walked lines.
pub const Repair = struct {
    /// The typed intent this rewrite realizes. The span-keyed side has carried
    /// one since it existed; the line-keyed side carried a free string, which is
    /// what made three vocabularies out of one. They are one enum now, and
    /// `legacyKind` is the only place the old spelling survives.
    intent: RepairIntent,
    /// The spec 4.2.1 idiom row this repair realizes, or null when it repairs a
    /// restriction instead. Most repairs are the latter.
    idiom_id: ?[]const u8 = null,
    /// Half-open byte span `[start_offset, end_offset)` into the source this
    /// repair was computed against. A span producer sets both; a line producer
    /// leaves them at zero and `appendRepairUnique` derives them from the line,
    /// which is why they carry a default rather than being required.
    start_offset: usize = 0,
    end_offset: usize = 0,
    /// 1-based position of `start_offset`, kept for reporting and for the v1
    /// `canonicalize --json` shape, which names a line. A line producer sets
    /// them; a span producer leaves them and the appender derives them from the
    /// offset, so neither side has to carry the other's coordinate system.
    line: u32 = 0,
    column: u32 = 0,
    /// Human-readable reason, duped into the repair's allocator. The empty
    /// string is the not-owned sentinel: a span producer has the diagnostic's
    /// own message beside it and does not copy one.
    message: []const u8 = "",
    replacement: []const u8,
    /// Snapshot of `source[start_offset..end_offset]` when the repair was
    /// built, re-validated before splicing. Required, not optional: an absent
    /// snapshot makes the staleness check skip silently, which is the one thing
    /// the field exists to prevent.
    original: []const u8,

    pub fn deinit(self: *Repair, allocator: std.mem.Allocator) void {
        freeRepairOwned(allocator, self);
    }
};

/// The v1 `canonicalize --json` name for an intent.
///
/// Five of these differ from the tag by more than spelling -
/// `canonicalize_arrow_helper` against `replace_arrow_with_function` - which is
/// why the string field read as a separate vocabulary rather than a rendering
/// of this one. D3 §6 freezes v1 command shapes, so the names stay on that
/// surface and nowhere else: the v2 wire publishes the tag, and every internal
/// comparison is now on the enum.
///
/// An intent with no legacy name never reached the line-keyed path, so it has
/// no v1 spelling to preserve; it renders as its tag.
pub fn legacyKind(intent: RepairIntent) []const u8 {
    return switch (intent) {
        .replace_arrow_with_function => "canonicalize_arrow_helper",
        .replace_export_arrow_with_function => "canonicalize_export_function",
        .replace_let_with_const => "canonicalize_let_const",
        .replace_compound_assign_with_explicit => "canonicalize_compound_assign",
        .drop_redundant_bool_compare => "canonicalize_redundant_bool_compare",
        else => @tagName(intent),
    };
}

/// The repairs one analysis pass produced for one file. Both builders fill
/// this: the line-derived rules and the span-derived ones share a list because
/// they share a vocabulary. What is still separate is the normalize loop's
/// policy of driving one group per pass, which is what keeps a critical pair
/// observable to the confluence harness.
pub const Result = struct {
    file: []const u8,
    repairs: std.ArrayListUnmanaged(Repair) = .empty,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.repairs.items) |*r| freeRepairOwned(allocator, r);
        self.repairs.deinit(allocator);
        self.* = .{ .file = "" };
    }
};

pub const SimulationSummary = struct {
    ok: bool,
    total: u32,
    new_count: u32,
    preexisting_count: u32,
};

pub fn collect(allocator: std.mem.Allocator, file: []const u8) !Result {
    const source = try zts.file_io.readFile(allocator, file, 10 * 1024 * 1024);
    defer allocator.free(source);
    return collectFromSource(allocator, source, file);
}

/// Like `collect`, but analyzes pre-read `source` against `virtual_path`
/// instead of reading the file from disk. This is the entry point the
/// fixed-point `normalize` loop drives: each pass rewrites source in memory
/// and re-collects without touching the filesystem.
pub fn collectFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
) !Result {
    var check = try precompile.runCheckOnlyFromSource(allocator, source, virtual_path, null, true, null, false);
    defer check.deinit(allocator);

    var result = Result{ .file = virtual_path };
    errdefer result.deinit(allocator);

    try buildLineRepairs(allocator, source, check.json_diagnostics.items, &result);
    return result;
}

/// Propose the `;` every statement that relies on automatic semicolon
/// insertion is missing.
///
/// WITHDRAWN, and not called. A review of the pipeline found it unsound in
/// every stage, and each fault produced a wrong edit that the wire reported as
/// a success:
///
/// - The line numbers come from a parse of the STRIPPED code and are used
///   against the original source with no `sourcePosition` translation, so a
///   `comptime(...)` fold - which the stripper documents as its one
///   offset-breaking operation - shifts every later repair onto the wrong line.
/// - The replacement is built from `trimEnd(line, " \t\r")`, so a line ending
///   in a `//` comment gets the `;` written inside the comment, and a CRLF file
///   loses its `\r`.
/// - TSX is outside this line-based repair until source positions are composed
///   through the frontend lowering map.
///
/// The corpus needs zero of these repairs, so withdrawing costs nothing a user
/// can feel, while leaving it in place kept `apply_repair` writing edits that
/// changed a program's meaning and publishing them as proven equivalences. It
/// comes back when the line mapping goes through `sourcePosition`, the
/// replacement is built from a span rather than a trimmed line, and M2 compares
/// against the grammar this compiler actually ships.
///
/// Not diagnostic-driven, because there is no diagnostic yet: spec 5.5 mandates
/// no ASI and the parser still accepts it, so this reads the parse's own census
/// of where it inserted. The repair lands before the refusal on purpose - a
/// program the refusal will reject has a mechanical exit the moment the
/// refusal arrives, rather than after it.
fn buildSemicolonRepairs(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    result: *Result,
) !void {
    var prepared = zts.PreparedSource.init(allocator, source, virtual_path, .{
        .enable_comptime = true,
        .comptime_env = .{},
    }) catch return;
    defer prepared.deinit();

    var parser = zts.parser.JsParser.init(allocator, prepared.parserInput()) catch return;
    defer parser.deinit();
    // The source this reads is one the refusing parser rejects - that is why it
    // needs a repair. Finding where the `;` belongs means parsing it the way
    // the old acceptance did.
    parser.allow_asi = true;
    _ = parser.parse() catch return;

    for (parser.asi.recordedLines()) |line_no| {
        const line = sourceLine(source, line_no) orelse continue;
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        // Stripping leaves the source offset-aligned, so the line the parse
        // reported is the line the author wrote. A line that already ends in a
        // `;` is one the census cannot have reported, and re-checking it here
        // costs nothing next to appending a repair that changes no byte.
        if (trimmed.len == 0 or trimmed[trimmed.len - 1] == ';') continue;

        const replacement = try std.fmt.allocPrint(allocator, "{s};", .{trimmed});
        errdefer allocator.free(replacement);
        const original = try allocator.dupe(u8, line);
        errdefer allocator.free(original);
        const message = try allocator.dupe(u8, "statement relies on automatic semicolon insertion, which this profile does not have");
        errdefer allocator.free(message);

        try appendRepairUnique(allocator, source, result, .{
            .intent = .insert_semicolon,
            .line = line_no,
            .column = 1,
            .message = message,
            .replacement = replacement,
            .original = original,
        });
    }
}

/// Translate the diagnostics from one analysis pass into concrete refactors.
/// Shared by `collectFromSource` and the fixed-point `normalizeSource` loop so
/// both read refactors from the same diagnostic set.
fn buildLineRepairs(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
    result: *Result,
) !void {
    for (diagnostics) |diag| {
        const line = sourceLine(source, diag.line) orelse continue;
        if (std.mem.eql(u8, diag.code, "ZTS608") or std.mem.eql(u8, diag.code, "ZTS609")) {
            const replacement = canonicalFunctionReplacement(allocator, line) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendRepairUnique(allocator, source, result, .{
                .intent = if (std.mem.eql(u8, diag.code, "ZTS608"))
                    .replace_arrow_with_function
                else
                    .replace_export_arrow_with_function,
                .line = diag.line,
                .column = diag.column,
                .message = try allocator.dupe(u8, diag.message),
                .replacement = replacement,
                .original = try allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, diag.code, "ZTS604")) {
            const replacement = avoidableLetReplacement(allocator, line) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendRepairUnique(allocator, source, result, .{
                .intent = if (std.mem.indexOf(u8, line, "for (let ") != null)
                    .canonicalize_for_of_const
                else
                    .replace_let_with_const,
                .line = diag.line,
                .column = diag.column,
                .message = try allocator.dupe(u8, diag.message),
                .replacement = replacement,
                .original = try allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, diag.code, "ZTS613")) {
            const replacement = compoundAssignReplacement(allocator, line) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendRepairUnique(allocator, source, result, .{
                .intent = .replace_compound_assign_with_explicit,
                .line = diag.line,
                .column = diag.column,
                .message = try allocator.dupe(u8, diag.message),
                .replacement = replacement,
                .original = try allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, diag.code, "ZTS620")) {
            const positive = redundantBoolComparePositive(diag.suggestion) orelse continue;
            const replacement = redundantBoolCompareReplacement(allocator, line, diag.column, positive) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendRepairUnique(allocator, source, result, .{
                .intent = .drop_redundant_bool_compare,
                .line = diag.line,
                .column = diag.column,
                .message = try allocator.dupe(u8, diag.message),
                .replacement = replacement,
                .original = try allocator.dupe(u8, line),
            });
        } else if (std.mem.eql(u8, diag.code, "ZTS602")) {
            const replacement = capabilityAliasReplacement(allocator, source, diag, diagnostics) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendRepairUnique(allocator, source, result, replacement);
        }
    }
}

/// Append a line-keyed repair, filling its span from the line it names.
///
/// Producers do not set offsets. They already knew which line they were
/// replacing whole and had already duped its text as the snapshot, so the span
/// is derived here from those two facts and checked against the source before
/// the repair is stored: a snapshot that does not match the bytes it claims is
/// refused rather than carried to the applier, where it would fail later and
/// further from the producer that got it wrong.
fn appendRepairUnique(
    allocator: std.mem.Allocator,
    source: []const u8,
    result: *Result,
    repair: Repair,
) !void {
    var owned = repair;
    const span = lineSpan(source, owned.line) orelse {
        freeRepairOwned(allocator, &owned);
        return;
    };
    if (!std.mem.eql(u8, source[span.start..span.end], owned.original)) {
        freeRepairOwned(allocator, &owned);
        return error.StaleRepair;
    }
    owned.start_offset = span.start;
    owned.end_offset = span.end;

    for (result.repairs.items) |*existing| {
        if (existing.start_offset == owned.start_offset and
            existing.end_offset == owned.end_offset and
            std.mem.eql(u8, existing.replacement, owned.replacement))
        {
            if (owned.intent == .canonicalize_capability_key_alias) {
                existing.intent = owned.intent;
                existing.column = owned.column;
                // Move ownership of the duped message: free the old one, take
                // owned's, and clear owned's so freeRepairOwned skips it.
                if (existing.message.len > 0) allocator.free(existing.message);
                existing.message = owned.message;
                owned.message = "";
            }
            freeRepairOwned(allocator, &owned);
            return;
        }
    }
    result.repairs.append(allocator, owned) catch |err| {
        freeRepairOwned(allocator, &owned);
        return err;
    };
}

fn freeRepairOwned(allocator: std.mem.Allocator, repair: *Repair) void {
    // `message` is duped into `allocator` at every build site (ENG-3: it must
    // outlive the CheckResult whose diagnostics it was copied from). The empty
    // string is the freed/moved-out sentinel and is never heap-owned.
    if (repair.message.len > 0) allocator.free(repair.message);
    allocator.free(repair.replacement);
    allocator.free(repair.original);
    repair.* = .{
        .intent = .canonicalize_capability_key_alias,
        .start_offset = 0,
        .end_offset = 0,
        .line = 0,
        .column = 0,
        .message = "",
        .replacement = "",
        .original = "",
    };
}

/// Find the index of the `=>` that is NOT nested inside parens/brackets/angles.
/// Returns the index of `=` in the first outermost `=>`, or null if none found.
fn findOutermostArrow(s: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '<' => depth += 1,
            ')', ']', '>' => if (depth > 0) {
                depth -= 1;
            },
            '=' => if (depth == 0 and i + 1 < s.len and s[i + 1] == '>') return i,
            else => {},
        }
    }
    return null;
}

pub fn canonicalFunctionReplacement(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const is_export = std.mem.startsWith(u8, trimmed, "export const ");
    const prefix_len: usize = if (is_export) "export const ".len else "const ".len;
    if (!is_export and !std.mem.startsWith(u8, trimmed, "const ")) return error.UnsupportedRefactor;

    const rest = trimmed[prefix_len..];
    const eq = assignmentEquals(rest) orelse return error.UnsupportedRefactor;
    const raw_name = std.mem.trim(u8, rest[0..eq], " \t");
    if (raw_name.len == 0) return error.UnsupportedRefactor;
    for (raw_name) |c| {
        if (c == ':' or std.ascii.isWhitespace(c)) return error.UnsupportedRefactor;
    }

    const arrow_source = std.mem.trim(u8, rest[eq + 1 ..], " \t");
    // Find the outermost `=>` — skip any `=>` that appears inside nested
    // parentheses, brackets, or angle brackets (e.g. parameter type annotations
    // like `(fn: (x: number) => string) => body`).
    const arrow = findOutermostArrow(arrow_source) orelse return error.UnsupportedRefactor;
    const signature = std.mem.trim(u8, arrow_source[0..arrow], " \t");
    if (std.mem.startsWith(u8, signature, "<")) return error.UnsupportedRefactor;
    const needs_param_parens = !std.mem.startsWith(u8, signature, "(");
    const function_signature = if (needs_param_parens)
        try std.fmt.allocPrint(allocator, "({s})", .{signature})
    else
        signature;
    defer if (needs_param_parens) allocator.free(function_signature);
    var body = std.mem.trim(u8, arrow_source[arrow + 2 ..], " \t");
    if (std.mem.endsWith(u8, body, ";")) body = std.mem.trim(u8, body[0 .. body.len - 1], " \t");

    const export_prefix: []const u8 = if (is_export) "export " else "";
    if (std.mem.startsWith(u8, body, "{")) {
        return std.fmt.allocPrint(allocator, "{s}function {s}{s} {s}", .{
            export_prefix,
            raw_name,
            function_signature,
            body,
        });
    }

    return std.fmt.allocPrint(allocator, "{s}function {s}{s} {{ return {s}; }}", .{
        export_prefix,
        raw_name,
        function_signature,
        body,
    });
}

pub fn avoidableLetReplacement(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed_left = trimLeft(line, " \t");
    const indent_len = line.len - trimmed_left.len;
    const indent = line[0..indent_len];
    if (std.mem.startsWith(u8, trimmed_left, "let ")) {
        return std.fmt.allocPrint(allocator, "{s}const {s}", .{
            indent,
            trimmed_left["let ".len..],
        });
    }

    const needle = "for (let ";
    const at = std.mem.indexOf(u8, line, needle) orelse return error.UnsupportedRefactor;
    return std.fmt.allocPrint(allocator, "{s}for (const {s}", .{
        line[0..at],
        line[at + needle.len ..],
    });
}

/// ZTS613: rewrite a compound assignment `lhs OP= rhs` into the explicit
/// `lhs = lhs OP rhs` so the read and the write are both visible.
///
/// Conservative by design: only the arithmetic operators (`+= -= *= /= %=`)
/// are handled, and the target must be a *simple lvalue* — an identifier or a
/// dotted-identifier chain (`a`, `a.b.c`). A target containing a call or index
/// (`f().x`, `a[i]`) is refused with `UnsupportedRefactor`, because expanding
/// it would re-evaluate a possibly side-effecting base expression twice and
/// change behavior. Bitwise/shift compound operators are likewise refused to
/// avoid the `<=`/`<<=` and `>=`/`>>=` lexing ambiguity; the agent falls back
/// to a manual edit there.
pub fn compoundAssignReplacement(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed_left = trimLeft(line, " \t");
    const indent = line[0 .. line.len - trimmed_left.len];

    // Find the compound-assignment `=`: the first `=` immediately preceded by
    // an arithmetic operator and not itself part of `==`.
    var i: usize = indent.len;
    while (i < line.len) : (i += 1) {
        if (line[i] != '=') continue;
        if (i == indent.len) continue;
        if (i + 1 < line.len and line[i + 1] == '=') continue; // ==, ===
        const op_char = line[i - 1];
        if (!isArithmeticOpChar(op_char)) continue;

        const lhs = std.mem.trim(u8, line[indent.len .. i - 1], " \t");
        const rhs = trimLeft(line[i + 1 ..], " \t");
        if (!isSimpleLvalue(lhs)) return error.UnsupportedRefactor;
        if (rhs.len == 0) return error.UnsupportedRefactor;

        // Separate the expression from a trailing ';' so we parenthesize only
        // the expression. Refuse anything with an interior ';' or a comment -
        // those defeat the simple textual split and must be edited by hand.
        const rhs_trimmed = trimRight(rhs, " \t");
        const has_semi = rhs_trimmed.len > 0 and rhs_trimmed[rhs_trimmed.len - 1] == ';';
        const expr = if (has_semi) trimRight(rhs_trimmed[0 .. rhs_trimmed.len - 1], " \t") else rhs_trimmed;
        const trailer: []const u8 = if (has_semi) ";" else "";
        if (expr.len == 0) return error.UnsupportedRefactor;
        if (std.mem.indexOfScalar(u8, expr, ';') != null) return error.UnsupportedRefactor;
        if (std.mem.indexOf(u8, expr, "//") != null or std.mem.indexOf(u8, expr, "/*") != null) {
            return error.UnsupportedRefactor;
        }

        // A single atom (identifier, number, dotted chain) needs no parens, so
        // `n += 1` stays `n = n + 1`. Any compound expression MUST be
        // parenthesized: `total -= fee + tax` becomes `total = total - (fee +
        // tax)`, not `total = total - fee + tax` which reassociates to
        // `(total - fee) + tax` and silently changes the result.
        if (isAtomicRhs(expr)) {
            return std.fmt.allocPrint(allocator, "{s}{s} = {s} {c} {s}{s}", .{
                indent, lhs, lhs, op_char, expr, trailer,
            });
        }
        if (!delimitersBalanced(expr)) return error.UnsupportedRefactor;
        return std.fmt.allocPrint(allocator, "{s}{s} = {s} {c} ({s}){s}", .{
            indent, lhs, lhs, op_char, expr, trailer,
        });
    }
    return error.UnsupportedRefactor;
}

fn isArithmeticOpChar(c: u8) bool {
    return c == '+' or c == '-' or c == '*' or c == '/' or c == '%';
}

/// True when `expr` is a single atom needing no parentheses on the right of a
/// rewritten compound assignment: an identifier, number, or dotted chain. Any
/// expression containing a top-level operator, call, index, or string literal
/// returns false and is parenthesized to preserve operator precedence.
fn isAtomicRhs(expr: []const u8) bool {
    if (expr.len == 0) return false;
    for (expr) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$')) return false;
    }
    return true;
}

/// ZTS620: rewrite `x === true` / `x !== false` -> `x` and `x === false`
/// / `x !== true` -> `!x` (and the operand-reversed forms), in place on the
/// line that carries the comparison. The strict checker only fires for a
/// statically-boolean value operand, so dropping the literal comparison is
/// behavior-preserving: for a boolean `x`, `x === true` is exactly `x`.
///
/// `column` is the 1-based column at which the comparison *operator*
/// (`===`/`!==`) starts on `line` -- the location `IrView.getLoc` reports for
/// a binary-expression node. `positive` selects the `x` form (`=== true` /
/// `!== false`) over the negated `!x` form; the caller reads it from the
/// diagnostic help text.
///
/// Conservative by design: the *value* operand must be a simple lvalue (an
/// identifier or dotted-identifier chain such as `a` or `a.b.c`). A value
/// operand containing a call, index, or operator is refused with
/// `UnsupportedRefactor` so the comparison stays a flagged hard error rather
/// than risk a mis-parsed span or an unparenthesised `!`-precedence change.
pub fn redundantBoolCompareReplacement(
    allocator: std.mem.Allocator,
    line: []const u8,
    column: u32,
    positive: bool,
) ![]u8 {
    if (column == 0) return error.UnsupportedRefactor;
    const op_start: usize = @as(usize, column) - 1;
    if (op_start + 3 > line.len) return error.UnsupportedRefactor;

    // Operator: strict equality or strict inequality at the diagnostic column.
    const op = line[op_start .. op_start + 3];
    if (!std.mem.eql(u8, op, "===") and !std.mem.eql(u8, op, "!==")) return error.UnsupportedRefactor;

    // Left operand: scan backwards over whitespace, then over an operand token.
    const left_ws_end = trimSpacesBack(line, op_start);
    const left_start = scanOperandTokenBack(line, left_ws_end) orelse return error.UnsupportedRefactor;
    const left_tok = line[left_start..left_ws_end];

    // Right operand: scan forwards over whitespace, then over an operand token.
    const right_start = skipSpaces(line, op_start + 3);
    const right_tok = scanOperandToken(line, right_start) orelse return error.UnsupportedRefactor;
    const right_end = right_start + right_tok.len;

    const left_is_literal = isBoolLiteralToken(left_tok);
    const right_is_literal = isBoolLiteralToken(right_tok);
    // Exactly one side is the boolean literal (the strict checker's invariant).
    if (left_is_literal == right_is_literal) return error.UnsupportedRefactor;

    const value = if (left_is_literal) right_tok else left_tok;
    if (!isSimpleLvalue(value)) return error.UnsupportedRefactor;

    // The comparison span on the line is [left_start, right_end). Replace it
    // with the bare boolean (`x`) or its negation (`!x`), preserving everything
    // around it.
    const replacement_core = if (positive)
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "!{s}", .{value});
    defer allocator.free(replacement_core);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        line[0..left_start],
        replacement_core,
        line[right_end..],
    });
}

/// Scan a single operand token starting at `pos`: either a boolean literal
/// (`true`/`false`) or a simple-lvalue chain (`a`, `a.b.c`). Returns the token
/// slice, or null when `pos` does not begin one. Used to bound the operand
/// spans of a ZTS620 comparison without a full expression parser.
fn scanOperandToken(line: []const u8, pos: usize) ?[]const u8 {
    if (pos >= line.len or !isIdentStart(line[pos])) return null;
    var end = pos + 1;
    while (end < line.len) {
        const c = line[end];
        if (isIdentContinue(c)) {
            end += 1;
            continue;
        }
        if (c == '.' and end + 1 < line.len and isIdentStart(line[end + 1])) {
            end += 1;
            continue;
        }
        break;
    }
    return line[pos..end];
}

/// Find the start index of the operand token whose last character is at
/// `end - 1` (exclusive `end`), walking back over ident-continue characters and
/// dotted-chain separators. Returns null when `[?..end)` is not a valid simple
/// operand (e.g. it is preceded by a `)` or `]`, signalling a call/index whose
/// span this line-local scan cannot bound safely).
fn scanOperandTokenBack(line: []const u8, end: usize) ?usize {
    if (end == 0) return null;
    var start = end;
    while (start > 0) {
        const c = line[start - 1];
        if (isIdentContinue(c)) {
            start -= 1;
            continue;
        }
        // A dot continues a member chain only when an identifier sits on both
        // sides of it (`a.b`), never a leading dot or `).foo`.
        if (c == '.' and start >= 2 and (isIdentContinue(line[start - 2]))) {
            start -= 1;
            continue;
        }
        break;
    }
    if (start == end) return null;
    if (!isIdentStart(line[start])) return null;
    // Refuse a token that is the tail of a larger member/call/index expression
    // the line-local scan cannot bound (`obj().foo`, `a[i].foo`): the `.` before
    // `start` was not consumed because its left side was `)`/`]`. Rewriting only
    // the tail would splice `!foo` after `obj().`, producing `obj().!foo`.
    if (start > 0) {
        const before = line[start - 1];
        if (before == '.' or before == ')' or before == ']') return null;
    }
    return start;
}

/// Trim trailing spaces/tabs from `[0..end)`, returning the new exclusive end.
fn trimSpacesBack(line: []const u8, end: usize) usize {
    var e = end;
    while (e > 0 and (line[e - 1] == ' ' or line[e - 1] == '\t')) e -= 1;
    return e;
}

fn isBoolLiteralToken(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "true") or std.mem.eql(u8, tok, "false");
}

fn skipSpaces(line: []const u8, pos: usize) usize {
    var i = pos;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

/// Read the positive/negated form of a ZTS620 rewrite from the diagnostic help
/// text. The strict checker emits `... use the boolean directly: \`x\`` for the
/// `x` form and `... negate the boolean directly: \`!x\`` for the `!x` form.
fn redundantBoolComparePositive(help: ?[]const u8) ?bool {
    const text = help orelse return null;
    if (std.mem.indexOf(u8, text, "use the boolean directly") != null) return true;
    if (std.mem.indexOf(u8, text, "negate the boolean directly") != null) return false;
    return null;
}

/// A simple lvalue is an identifier or dotted-identifier chain: re-evaluating
/// it is side-effect-free, so `lhs = lhs OP rhs` preserves behavior.
fn isSimpleLvalue(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!isIdentStart(s[0])) return false;
    var prev_dot = false;
    for (s, 0..) |c, idx| {
        if (c == '.') {
            // No leading/trailing/double dots.
            if (idx == 0 or idx == s.len - 1 or prev_dot) return false;
            prev_dot = true;
            continue;
        }
        if (!isIdentContinue(c)) return false;
        prev_dot = false;
    }
    return true;
}

const AliasReplacement = struct {
    line: u32,
    replacement: []const u8,
    original_line: []const u8,
};

fn capabilityAliasReplacement(
    allocator: std.mem.Allocator,
    source: []const u8,
    diag: precompile.json_diag.JsonDiagnostic,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
) !Repair {
    const call_line = sourceLine(source, diag.line) orelse return error.UnsupportedRefactor;
    const ident = identifierAtColumn(call_line, diag.column) orelse return error.UnsupportedRefactor;
    const alias = findLiteralLetAlias(allocator, source, ident, diag.line, diagnostics) catch |err| switch (err) {
        error.UnsupportedRefactor => return error.UnsupportedRefactor,
        else => return err,
    };
    // alias.replacement / alias.original_line are heap-owned; free them if the
    // message dupe below OOMs (they are never appended to result.repairs on
    // that path, so no later cleanup reclaims them).
    errdefer allocator.free(alias.replacement);
    errdefer allocator.free(alias.original_line);
    return .{
        .intent = .canonicalize_capability_key_alias,
        .line = alias.line,
        .column = 1,
        .message = try allocator.dupe(u8, "make capability key alias compiler-visible"),
        .replacement = alias.replacement,
        .original = alias.original_line,
    };
}

fn identifierAtColumn(line: []const u8, column: u32) ?[]const u8 {
    if (column == 0) return null;
    var start: usize = @as(usize, column) - 1;
    if (start >= line.len) return null;
    while (start < line.len and std.ascii.isWhitespace(line[start])) start += 1;
    if (start >= line.len or !isIdentStart(line[start])) return null;
    var end = start + 1;
    while (end < line.len and isIdentContinue(line[end])) end += 1;
    return line[start..end];
}

fn findLiteralLetAlias(
    allocator: std.mem.Allocator,
    source: []const u8,
    ident: []const u8,
    use_line: u32,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
) !AliasReplacement {
    const block_start = enclosingBlockStartLine(source, use_line) orelse return error.UnsupportedRefactor;
    var line_num: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (line_num >= block_start and line_num < use_line) {
                if (try literalLetAliasReplacement(allocator, source[start..i], ident, line_num, diagnostics)) |replacement| return replacement;
            }
            line_num += 1;
            start = i + 1;
        }
    }
    return error.UnsupportedRefactor;
}

fn literalLetAliasReplacement(
    allocator: std.mem.Allocator,
    line: []const u8,
    ident: []const u8,
    line_num: u32,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
) !?AliasReplacement {
    if (!hasDiagnosticAt(diagnostics, "ZTS604", line_num)) return null;
    const trimmed_left = trimLeft(line, " \t");
    if (!std.mem.startsWith(u8, trimmed_left, "let ")) return null;
    const rest = trimmed_left["let ".len..];
    if (!std.mem.startsWith(u8, rest, ident)) return null;
    const after_name = rest[ident.len..];
    if (after_name.len > 0 and isIdentContinue(after_name[0])) return null;
    const eq = assignmentEquals(after_name) orelse return null;
    const rhs = trimLeft(after_name[eq + 1 ..], " \t");
    if (!isStaticLiteralExpression(rhs)) return null;
    return .{
        .line = line_num,
        .replacement = try avoidableLetReplacement(allocator, line),
        .original_line = try allocator.dupe(u8, line),
    };
}

fn enclosingBlockStartLine(source: []const u8, use_line: u32) ?u32 {
    var line_num: u32 = 1;
    var start: usize = 0;
    var depth: i32 = 0;
    var best: ?u32 = null;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (line_num >= use_line) break;
            updateBlockDepth(source[start..i], line_num, &depth, &best);
            line_num += 1;
            start = i + 1;
        }
    }
    if (line_num < use_line) updateBlockDepth(source[start..], line_num, &depth, &best);
    return best;
}

fn updateBlockDepth(line: []const u8, line_num: u32, depth: *i32, best: *?u32) void {
    for (line) |c| {
        if (c == '{') {
            depth.* += 1;
            best.* = line_num + 1;
        } else if (c == '}') {
            depth.* -= 1;
            if (depth.* < 0) depth.* = 0;
        }
    }
}

fn hasDiagnosticAt(diagnostics: []const precompile.json_diag.JsonDiagnostic, code: []const u8, line: u32) bool {
    for (diagnostics) |diag| {
        if (diag.line == line and std.mem.eql(u8, diag.code, code)) return true;
    }
    return false;
}

fn isStaticLiteralExpression(source: []const u8) bool {
    const trimmed = trimRight(source, " \t\r;");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '"' or trimmed[0] == '\'') return quotedLiteralConsumes(trimmed, trimmed[0]) == trimmed.len;
    if (trimmed[0] == '`') return quotedLiteralConsumes(trimmed, '`') == trimmed.len and std.mem.indexOf(u8, trimmed, "${") == null;
    for (trimmed) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn quotedLiteralConsumes(source: []const u8, quote: u8) usize {
    if (source.len == 0 or source[0] != quote) return 0;
    var escaped = false;
    var i: usize = 1;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return 0;
}

fn trimLeft(source: []const u8, values: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len and std.mem.indexOfScalar(u8, values, source[start]) != null) {
        start += 1;
    }
    return source[start..];
}

fn trimRight(source: []const u8, values: []const u8) []const u8 {
    var end = source.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, source[end - 1]) != null) {
        end -= 1;
    }
    return source[0..end];
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn assignmentEquals(source: []const u8) ?usize {
    for (source, 0..) |c, i| {
        if (c != '=') continue;
        if (i + 1 < source.len and source[i + 1] == '>') continue;
        return i;
    }
    return null;
}

pub fn sourceLine(source: []const u8, line_num: u32) ?[]const u8 {
    const span = lineSpan(source, line_num) orelse return null;
    return source[span.start..span.end];
}

pub const Span = struct { start: usize, end: usize };

/// The half-open byte span of line `line_num`, excluding its newline. Every
/// line-keyed producer replaces its line entire, so this is the span of the
/// repair it emits, and deriving it in one place is what let the producers
/// move to the span vocabulary without each learning to count bytes.
pub fn lineSpan(source: []const u8, line_num: u32) ?Span {
    if (line_num == 0) return null;
    var current: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (current == line_num) return .{ .start = start, .end = i };
            current += 1;
            start = i + 1;
        }
    }
    if (current == line_num) return .{ .start = start, .end = source.len };
    return null;
}

// ---------------------------------------------------------------------------
// Applying repairs
// ---------------------------------------------------------------------------
//
// One path. There used to be two: a line-keyed one that walked lines and
// refused a replacement containing a newline, and this span-keyed one. A
// whole-line rewrite is a span rewrite over the line's bytes, so the first was
// a special case of the second wearing its own guards, its own errors, and a
// scheduling rule that existed to keep the two apart.

/// Convert a 1-based (line, column) byte position into a byte offset into
/// `source`. Returns null when the position is out of range. Column is a byte
/// column (the tokenizer computes it as `pos - line_start + 1`), and the
/// TypeScript stripper preserves byte positions by blanking stripped spans
/// with spaces, so a diagnostic column maps to the same byte offset in the
/// original source the rewriter scans.
fn lineColToOffset(source: []const u8, line: u32, column: u32) ?usize {
    if (line == 0 or column == 0) return null;
    var current: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (current < line and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            current += 1;
            line_start = i + 1;
        }
    }
    if (current != line) return null;
    const offset = line_start + (@as(usize, column) - 1);
    if (offset > source.len) return null;
    return offset;
}

/// Apply a set of repairs to `source`, returning fresh owned output. This is
/// the only application path.
///
/// The set must be NON-OVERLAPPING: any two spans that overlap are a caller bug
/// (the normalize loop only ever passes the innermost non-overlapping subset
/// per pass), and are rejected with `error.OverlappingRepairs`. Two whole-line
/// repairs on one line have identical spans and are refused by that same rule,
/// which is what the retired line-keyed applier's same-line check was for; two
/// repairs on one line whose spans do not overlap now both apply, which it
/// could not express.
///
/// Each repair's `original` snapshot must still match `source[start..end)`,
/// else `error.StaleRepair`. A span outside the source is
/// `error.RepairOutOfBounds`. Spans are spliced in ascending order so an
/// earlier splice never shifts a later span's offsets.
pub fn applyRepairs(
    allocator: std.mem.Allocator,
    source: []const u8,
    rewrites: []const Repair,
) ![]u8 {
    if (rewrites.len == 0) return allocator.dupe(u8, source);

    // Order indices by ascending start offset so we can both detect overlaps
    // and splice deterministically. A bounded insertion sort over a small set.
    const order = try allocator.alloc(usize, rewrites.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    for (1..order.len) |i| {
        var j = i;
        while (j > 0 and rewrites[order[j - 1]].start_offset > rewrites[order[j]].start_offset) : (j -= 1) {
            const tmp = order[j - 1];
            order[j - 1] = order[j];
            order[j] = tmp;
        }
    }

    // Validate bounds, overlap, and the original snapshot for each span.
    var prev_end: ?usize = null;
    var prev_start: ?usize = null;
    for (order) |idx| {
        const rw = rewrites[idx];
        if (rw.start_offset > rw.end_offset or rw.end_offset > source.len) return error.RepairOutOfBounds;
        if (prev_end) |pe| {
            if (rw.start_offset < pe) return error.OverlappingRepairs;
        }
        // Two empty spans at one offset do not trip the `<` test above, and two
        // repairs that both replace nothing at the same point are still two
        // answers to one question.
        if (prev_start) |ps| {
            if (rw.start_offset == ps and rw.end_offset == prev_end.?) return error.OverlappingRepairs;
        }
        if (!std.mem.eql(u8, source[rw.start_offset..rw.end_offset], rw.original)) return error.StaleRepair;
        prev_start = rw.start_offset;
        prev_end = rw.end_offset;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (order) |idx| {
        const rw = rewrites[idx];
        try out.appendSlice(allocator, source[cursor..rw.start_offset]);
        try out.appendSlice(allocator, rw.replacement);
        cursor = rw.end_offset;
    }
    try out.appendSlice(allocator, source[cursor..]);
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Span-repair construction (from diagnostics)
// ---------------------------------------------------------------------------

/// Apply the one span-keyed rewrite that the requested intent asks for at
/// `line`, returning fresh owned source.
///
/// The normalize loop drives `buildRepairs` over a whole file and
/// applies every non-overlapping rewrite per pass. A repair client asks a
/// narrower question - "realize this one intent, at this one line" - and until
/// this entry point existed it had no way to ask it: the five span-keyed
/// intents were reachable only by normalizing the entire file, which changes
/// far more than the diagnostic the client is answering.
///
/// Refuses rather than guesses in three cases. No matching rewrite means the
/// construct is not one a provably-safe rewrite can be formed for, and it stays
/// a flagged hard error. More than one match on the line means the intent does
/// not name a unique construct - `Intent` carries no column, so there is
/// nothing to disambiguate with. A rewrite that spans other rewrites is left
/// alone, because splicing an outer construct while an inner one is still
/// present is the ordering the normalize loop resolves over several passes and
/// a single-intent apply has only one.
pub fn applyStatementIntent(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    intent: RepairIntent,
    line: u32,
) ![]u8 {
    var check = try precompile.runCheckOnlyFromSource(allocator, source, virtual_path, null, true, null, false);
    defer check.deinit(allocator);

    var stmt_result = Result{ .file = "" };
    defer stmt_result.deinit(allocator);
    try buildSpanRepairs(allocator, source, check.json_diagnostics.items, &stmt_result);

    var chosen: ?Repair = null;
    for (stmt_result.repairs.items) |rw| {
        if (rw.intent != intent) continue;
        if (offsetLine(source, rw.start_offset) != line) continue;
        if (chosen != null) return error.UnsupportedRepairIntent;
        chosen = rw;
    }
    const only = chosen orelse return error.UnsupportedRepairIntent;

    for (stmt_result.repairs.items) |other| {
        if (other.start_offset == only.start_offset and other.end_offset == only.end_offset) continue;
        const contains = only.start_offset <= other.start_offset and other.end_offset <= only.end_offset;
        if (contains) return error.UnsupportedRepairIntent;
    }

    var one = [_]Repair{only};
    return applyRepairs(allocator, source, &one);
}

/// The 1-based line `offset` falls on.
pub fn offsetLine(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// Translate the diagnostics from one analysis pass into span-keyed
/// rewrites. The sibling of `buildRefactors` for the multi-line / convention
/// rules: each landed rule dispatches on `diag.code` to a builder that derives
/// the construct's byte span from the source and the diagnostic's start
/// position, returning `error.UnsupportedRefactor` to leave the construct a
/// flagged hard error when a provably-safe rewrite cannot be formed.
fn buildSpanRepairs(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: []const precompile.json_diag.JsonDiagnostic,
    result: *Result,
) !void {
    for (diagnostics) |diag| {
        // ZTS612 (impure arm) and ZTS621 (chained) share one rewrite: both are
        // repaired by lifting the conditional into an expression-position
        // `match`, and both report at the `?` token the scanner keys off.
        if (std.mem.eql(u8, diag.code, "ZTS612") or std.mem.eql(u8, diag.code, "ZTS621")) {
            const rw = ternaryToMatchRewrite(allocator, source, diag.line, diag.column) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendSpanRepairUnique(allocator, source, result, rw);
        } else if (std.mem.eql(u8, diag.code, "ZTS615")) {
            const rw = templateHoistRewrite(allocator, source, diag.line, diag.column) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendSpanRepairUnique(allocator, source, result, rw);
        } else if (std.mem.eql(u8, diag.code, "ZTS618")) {
            const rw = nestedDestructureRewrite(allocator, source, diag.line, diag.column) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendSpanRepairUnique(allocator, source, result, rw);
        } else if (std.mem.eql(u8, diag.code, "ZTS619")) {
            const rw = unusedIndexAliasRewrite(allocator, source, diag.line, diag.column) catch |err| switch (err) {
                error.UnsupportedRefactor => continue,
                else => return err,
            };
            try appendSpanRepairUnique(allocator, source, result, rw);
        }
    }
}

/// ZTS612 canonical_ternary_impure and ZTS621 canonical_ternary_chain: rewrite
/// `cond ? a : b` into an expression-position `match` so it works in const
/// initializers and return positions, where an if/else statement cannot. A pure
/// unchained `?:` is idiomatic under spec 5.4 and is never rewritten.
///
/// Canonical target: `match (!!(cond)) { when true: a, default: b }` (the
/// condition is parenthesized so `!!` coerces the whole expression).
///
/// The double-negation `!!cond` is load-bearing for behavior preservation, not
/// cosmetic. A ternary tests the *truthiness* of `cond` (the VM's `if_false`
/// coerces with `toConditionBool`), whereas a `match` boolean-literal arm tests
/// *strict equality* against `true` (`strict_eq`). For a `cond` that is truthy
/// but not the literal `true` (e.g. a non-empty string or non-zero number),
/// `cond ? a : b` yields `a` while `match (cond) { when true: a, default: b }`
/// would fall to `default`. `!` also coerces with `toConditionBool` and raises
/// the same bool-error on the same un-coercible values, so `!!cond` reproduces
/// the ternary's branch selection exactly for every `cond`. Both forms evaluate
/// `cond` once.
///
/// `column` is the 1-based column of the `?` token (the location the strict
/// checker reports for a ternary node). From there the condition span is found
/// by scanning back to the nearest enclosing expression boundary, and the
/// then/else spans by scanning forward across the matching `:` and to the end
/// of the else branch. Any span that cannot be bounded with the conservative
/// scanner (an unbalanced bracket, a boundary the scanner does not recognise)
/// is refused with `error.UnsupportedRefactor`, leaving the ternary a flagged
/// hard error rather than risking a behavior-changing splice.
fn ternaryToMatchRewrite(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    column: u32,
) !Repair {
    const q = lineColToOffset(source, line, column) orelse return error.UnsupportedRefactor;
    if (q >= source.len or source[q] != '?') return error.UnsupportedRefactor;
    // `?.` (optional chain) and `??` (nullish) are not ternaries.
    if (q + 1 < source.len and (source[q + 1] == '.' or source[q + 1] == '?')) return error.UnsupportedRefactor;

    var cond_start = ternaryConditionStart(source, q) orelse return error.UnsupportedRefactor;
    // A `return <ternary>` statement: the backward scan stops at the line/source
    // boundary and sweeps the `return` keyword into the condition. Step past a
    // leading `return ` so the condition is the bare boolean expression.
    cond_start = skipLeadingReturn(source, cond_start, q);
    const colon = ternaryMatchingColon(source, q + 1) orelse return error.UnsupportedRefactor;
    const else_end = ternaryElseEnd(source, colon + 1) orelse return error.UnsupportedRefactor;

    const cond = std.mem.trim(u8, source[cond_start..q], " \t");
    const then_branch = std.mem.trim(u8, source[q + 1 .. colon], " \t");
    const else_branch = std.mem.trim(u8, source[colon + 1 .. else_end], " \t");
    if (cond.len == 0 or then_branch.len == 0 or else_branch.len == 0) return error.UnsupportedRefactor;

    // The spliced span begins at the first non-space byte of the condition so
    // the surrounding indentation/operators are preserved verbatim.
    const real_start = cond_start + leadingSpaces(source[cond_start..q]);

    // Parenthesize the condition: `!!` is unary and binds tighter than the
    // relational/equality operators a condition usually ends in, so `!!a === b`
    // would mis-parse as `(!!a) === b`. `!!(a === b)` coerces the whole
    // condition to a strict boolean, reproducing the ternary's truthiness test.
    const replacement = try std.fmt.allocPrint(
        allocator,
        "match (!!({s})) {{ when true: {s}, default: {s} }}",
        .{ cond, then_branch, else_branch },
    );
    errdefer allocator.free(replacement);
    const original = try allocator.dupe(u8, source[real_start..else_end]);
    errdefer allocator.free(original);

    return .{
        .intent = .replace_ternary_with_if,
        .start_offset = real_start,
        .end_offset = else_end,
        .replacement = replacement,
        .original = original,
    };
}

fn leadingSpaces(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// If `source[start..end)` (after leading whitespace) begins with the `return`
/// keyword followed by whitespace, return the offset just past that whitespace
/// so the ternary condition excludes the keyword. Otherwise return `start`
/// unchanged.
fn skipLeadingReturn(source: []const u8, start: usize, end: usize) usize {
    var i = start + leadingSpaces(source[start..end]);
    const kw = "return";
    if (i + kw.len <= end and std.mem.eql(u8, source[i .. i + kw.len], kw)) {
        const after = i + kw.len;
        if (after < end and (source[after] == ' ' or source[after] == '\t')) {
            i = after;
            while (i < end and (source[i] == ' ' or source[i] == '\t')) i += 1;
            return i;
        }
    }
    return start;
}

/// Find the start offset of a ternary condition, scanning back from the `?` at
/// `q`. The condition runs back to the nearest enclosing expression boundary at
/// bracket depth zero: an assignment `=` (not `==`/`=>`/`<=`/`>=`/`!=`), an
/// open bracket `([{`, a comma, a semicolon, a `return`/`=>` keyword boundary,
/// or the start of the line/source. Brackets and string/template literals are
/// balanced so a boundary character inside them does not terminate the scan.
/// Returns null when the scan cannot find a clean boundary.
fn ternaryConditionStart(source: []const u8, q: usize) ?usize {
    var i: usize = q;
    var depth: i32 = 0;
    while (i > 0) {
        const c = source[i - 1];
        switch (c) {
            ')', ']', '}' => {
                depth += 1;
                i -= 1;
            },
            '(', '[', '{' => {
                if (depth == 0) return i; // boundary: opening bracket
                depth -= 1;
                i -= 1;
            },
            ',', ';' => {
                if (depth == 0) return i;
                i -= 1;
            },
            ':', '?' => {
                // `c == source[i-1]`, so returning `i` starts the condition
                // just after this boundary. A depth-0 `:` belongs to an
                // enclosing ternary (or an object key / label); a depth-0 `?`
                // is an enclosing ternary's `?` whose else-branch contains this
                // one (right-associative chains). The condition of *this*
                // ternary cannot extend back past either.
                if (depth == 0) return i;
                i -= 1;
            },
            '\n' => {
                if (depth == 0) return i;
                i -= 1;
            },
            '"', '\'', '`' => {
                // Skip back over a string/template literal.
                const lit_start = scanStringBack(source, i - 1, c) orelse return null;
                i = lit_start;
            },
            '=' => {
                if (depth != 0) {
                    i -= 1;
                    continue;
                }
                // Distinguish a plain assignment `=` (boundary) from a
                // comparison/arrow operator that is part of the condition.
                const prev: u8 = if (i >= 2) source[i - 2] else 0;
                const next: u8 = if (i < source.len) source[i] else 0;
                const is_compare = prev == '=' or prev == '!' or prev == '<' or prev == '>';
                const is_arrow = next == '>';
                const is_eqeq = next == '=';
                if (is_arrow) {
                    // `=>` is a boundary: the ternary condition is the arrow's
                    // expression body and starts just after the `>` (the `=` is
                    // at i-1, the `>` at i). Without this, `(x) => cond ? a : b`
                    // would sweep `(x) => cond` into the condition, yielding an
                    // always-truthy `match (!!((x) => cond))`.
                    return i + 1;
                }
                if (is_compare or is_eqeq) {
                    i -= 1;
                    continue;
                }
                return i; // plain assignment: condition begins after the `=`
            },
            else => i -= 1,
        }
    }
    if (depth == 0) return 0;
    return null;
}

/// From `start` (the offset just past the `?`), find the offset of the `:`
/// that closes this ternary. Right-associative: the matching colon is the
/// first `:` at the same nesting depth, but a *nested* ternary consumes its own
/// colon, so an inner `?` increments a pending-colon counter. Brackets and
/// string/template literals are balanced. Returns null when no matching colon
/// is found.
fn ternaryMatchingColon(source: []const u8, start: usize) ?usize {
    var i: usize = start;
    var depth: i32 = 0;
    var pending: u32 = 0; // nested ternaries awaiting their own colon
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                i += 1;
            },
            '"', '\'', '`' => {
                const after = scanStringForward(source, i, c) orelse return null;
                i = after;
            },
            '?' => {
                // `?.` and `??` are not nested ternaries.
                if (i + 1 < source.len and (source[i + 1] == '.' or source[i + 1] == '?')) {
                    i += 2;
                    continue;
                }
                if (depth == 0) pending += 1;
                i += 1;
            },
            ':' => {
                if (depth == 0) {
                    if (pending == 0) return i;
                    pending -= 1;
                }
                i += 1;
            },
            ';', '\n' => {
                if (depth == 0) return null; // unterminated on this statement
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// From `start` (just past the closing `:`), find the exclusive end of the
/// else branch: the first boundary at depth zero (`,` `;` `)` `]` `}` newline,
/// or end of source). Brackets and string/template literals are balanced.
fn ternaryElseEnd(source: []const u8, start: usize) ?usize {
    var i: usize = start;
    var depth: i32 = 0;
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                if (depth == 0) return i;
                depth -= 1;
                i += 1;
            },
            '"', '\'', '`' => {
                const after = scanStringForward(source, i, c) orelse return null;
                i = after;
            },
            ',', ';', '\n' => {
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return i;
}

/// Scan forward over a string or template literal that opens at `open`
/// (`source[open] == quote`). Returns the offset just past the closing quote,
/// or null when unterminated. Template literals (`` ` ``) only track escapes,
/// not nested `${...}` interpolations: a `${...}` cannot contain an unbalanced
/// closing backtick, so for the bracket/colon scans above treating the whole
/// template as opaque is sufficient and conservative.
fn scanStringForward(source: []const u8, open: usize, quote: u8) ?usize {
    var i: usize = open + 1;
    var escaped = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == quote) return i + 1;
    }
    return null;
}

/// Scan backward over a string or template literal whose closing quote is at
/// `close` (`source[close] == quote`). Returns the offset of the opening quote,
/// or null when the literal cannot be bounded (an escaped opener mid-scan makes
/// a backward scan ambiguous, so refuse). Conservative: any backslash before
/// the matching opener aborts the scan.
fn scanStringBack(source: []const u8, close: usize, quote: u8) ?usize {
    var i: usize = close;
    while (i > 0) {
        i -= 1;
        if (source[i] == quote) {
            // Count preceding backslashes; an odd count means this quote is
            // escaped and is not the opener. A backward scan cannot resolve
            // that cheaply, so refuse.
            var bs: usize = 0;
            var j = i;
            while (j > 0 and source[j - 1] == '\\') : (j -= 1) bs += 1;
            if (bs % 2 == 0) return i;
            return null;
        }
        if (source[i] == '\n') return null;
    }
    return null;
}

/// ZTS615 canonical_template_complex_interp: hoist each complex `${expr}` in a
/// template literal into a `const` immediately above the statement, then
/// interpolate the new name. The canonical rule wants every template
/// interpolation to be a bare identifier or a literal-keyed property access
/// (`isSimpleTemplateInterp`); anything else (a call, an index, an operator
/// expression) is hoisted.
///
/// Canonical target, for `  const g = ` + "`" + `Hi ${u.up()}` + "`" + `;`:
///     const __zt_<off> = u.up();
///     const g = ` + "`" + `Hi ${__zt_<off>}` + "`" + `;
///
/// The generated binding name `__zt_<off>` is derived from the byte offset of
/// the interpolation's opening `${`, never a mutable counter, so the normal
/// form is unique and confluent: the same input always yields the same name.
///
/// Behavior preservation: template interpolations evaluate left-to-right at the
/// point the template is evaluated. Hoisting each complex interp, in source
/// order, to a `const` on the line directly above preserves that order and the
/// single evaluation point. The hoisted expression sits in statement position
/// where its value is identical to its value in interpolation position.
///
/// Scope is deliberately narrow for provable safety: the entire enclosing
/// statement must be on ONE physical line (`column` reports the template
/// literal start; a multi-line template or statement is refused so the
/// line-local splice never straddles a construct it cannot see). Any interp
/// whose `${...}` cannot be balanced is refused, leaving ZTS615 a flagged hard
/// error. A template inside a function that opens on the same line (an arrow
/// or a `function` keyword before the backtick) is also refused: the hoisted
/// `const` would land outside that function, capturing the wrong binding for
/// any parameter or local the interpolation references and moving evaluation
/// from call time to definition time.
fn templateHoistRewrite(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    column: u32,
) !Repair {
    const tmpl_start = lineColToOffset(source, line, column) orelse return error.UnsupportedRefactor;
    if (tmpl_start >= source.len or source[tmpl_start] != '`') return error.UnsupportedRefactor;

    // The enclosing statement must be a single physical line: bound it by the
    // surrounding newlines.
    const line_start = lineStartOffset(source, tmpl_start);
    const line_end = std.mem.indexOfScalarPos(u8, source, tmpl_start, '\n') orelse source.len;
    const stmt = source[line_start..line_end];

    // The hoisted `const` is emitted at line_start, so a statement preceding the
    // template on the SAME physical line would have its side effects reordered
    // after the hoist. Refuse when anything but a binding/return precedes the
    // template: a `;` in the prefix signals a prior statement on the line.
    if (std.mem.indexOfScalar(u8, source[line_start..tmpl_start], ';') != null) {
        return error.UnsupportedRefactor;
    }

    // A function opening before the template on this line would put the
    // hoisted `const` outside that function's scope.
    if (prefixOpensFunctionScope(source[line_start..tmpl_start])) {
        return error.UnsupportedRefactor;
    }

    // Find the matching closing backtick of this template, staying on one line.
    const tmpl_close = templateCloseOffset(source, tmpl_start, line_end) orelse return error.UnsupportedRefactor;

    // Collect every complex `${...}` in this template, in source order.
    var hoists: std.ArrayListUnmanaged(struct { expr_start: usize, expr_end: usize, name: []u8 }) = .empty;
    defer {
        for (hoists.items) |h| allocator.free(h.name);
        hoists.deinit(allocator);
    }

    var i: usize = tmpl_start + 1;
    while (i < tmpl_close) {
        if (source[i] == '\\') {
            i += 2;
            continue;
        }
        if (source[i] == '$' and i + 1 < tmpl_close and source[i + 1] == '{') {
            const expr_start = i + 2;
            const close = matchingBrace(source, expr_start, tmpl_close) orelse return error.UnsupportedRefactor;
            const inner = std.mem.trim(u8, source[expr_start..close], " \t");
            if (inner.len == 0) return error.UnsupportedRefactor;
            if (!isSimpleTemplateInterpText(inner)) {
                const name = try std.fmt.allocPrint(allocator, "__zt_{d}", .{i});
                errdefer allocator.free(name);
                try hoists.append(allocator, .{ .expr_start = expr_start, .expr_end = close, .name = name });
            }
            i = close + 1;
            continue;
        }
        i += 1;
    }

    if (hoists.items.len == 0) return error.UnsupportedRefactor;

    const indent = stmt[0..leadingSpaces(stmt)];

    // Build the replacement: one hoist `const` per complex interp (in order),
    // then the original statement line with each `${expr}` replaced by
    // `${name}`.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (hoists.items) |h| {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "const ");
        try out.appendSlice(allocator, h.name);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, std.mem.trim(u8, source[h.expr_start..h.expr_end], " \t"));
        try out.appendSlice(allocator, ";\n");
    }
    // Emit the statement with interps replaced.
    var cursor = line_start;
    for (hoists.items) |h| {
        try out.appendSlice(allocator, source[cursor..h.expr_start]);
        try out.appendSlice(allocator, h.name);
        cursor = h.expr_end;
    }
    try out.appendSlice(allocator, source[cursor..line_end]);

    const replacement = try out.toOwnedSlice(allocator);
    errdefer allocator.free(replacement);
    const original = try allocator.dupe(u8, source[line_start..line_end]);
    errdefer allocator.free(original);

    return .{
        .intent = .name_const_above_template,
        .start_offset = line_start,
        .end_offset = line_end,
        .replacement = replacement,
        .original = original,
    };
}

/// Offset of the start of the line containing `pos` (the byte just after the
/// previous newline, or 0).
fn lineStartOffset(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// Find the closing backtick of a template literal that opens at `open`,
/// scanning forward but not past `limit`. `${...}` interpolations are skipped
/// with brace balancing (an interp may contain a backtick inside a nested
/// string or template). Returns null when the template does not close before
/// `limit` (e.g. a multi-line template, which this rewriter refuses).
fn templateCloseOffset(source: []const u8, open: usize, limit: usize) ?usize {
    var i: usize = open + 1;
    while (i < limit) {
        const c = source[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '`') return i;
        if (c == '$' and i + 1 < limit and source[i + 1] == '{') {
            const close = matchingBrace(source, i + 2, limit) orelse return null;
            i = close + 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Given `start` just past a `${`, return the offset of the matching `}`,
/// balancing nested braces and skipping string/template literals. Bounded by
/// `limit`. Returns null when no match is found before `limit`.
fn matchingBrace(source: []const u8, start: usize, limit: usize) ?usize {
    var i: usize = start;
    var depth: i32 = 0;
    while (i < limit) {
        const c = source[i];
        switch (c) {
            '{' => {
                depth += 1;
                i += 1;
            },
            '}' => {
                if (depth == 0) return i;
                depth -= 1;
                i += 1;
            },
            '"', '\'', '`' => {
                const after = scanStringForward(source, i, c) orelse return null;
                if (after > limit) return null;
                i = after;
            },
            else => i += 1,
        }
    }
    return null;
}

/// Mirror of the strict checker's `isSimpleTemplateInterp`, but over text: a
/// simple interpolation is a bare identifier or a dotted-identifier chain
/// (`a`, `a.b.c`). Anything else (a call, an index, an operator, whitespace
/// between tokens) is complex and gets hoisted. Kept conservative: when in
/// doubt the text is treated as complex (hoisted), never as simple.
fn isSimpleTemplateInterpText(s: []const u8) bool {
    return isSimpleLvalue(s);
}

/// True when `prefix` (the statement-line text before the template literal)
/// opens a function scope: an `=>` arrow or a word-bounded `function` keyword.
/// Purely textual and deliberately over-broad (a `=>` inside a string in the
/// prefix also matches): a false positive only suppresses the auto-fix and
/// leaves ZTS615 a flagged hard error, never produces a wrong rewrite.
fn prefixOpensFunctionScope(prefix: []const u8) bool {
    if (std.mem.indexOf(u8, prefix, "=>") != null) return true;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, prefix, i, "function")) |at| {
        const before_ok = at == 0 or !isIdentContinue(prefix[at - 1]);
        const after = at + "function".len;
        const after_ok = after >= prefix.len or !isIdentContinue(prefix[after]);
        if (before_ok and after_ok) return true;
        i = at + 1;
    }
    return false;
}

/// True when `text` has balanced `()`, `[]`, and `{}` delimiters and no
/// unterminated string/template literal. Used to detect an expression that does
/// not finish on its own line, so a single-line rewrite refuses it instead of
/// silently truncating. Strings are skipped with the `scanStringForward`
/// idiom, so a delimiter inside a literal does not count.
fn delimitersBalanced(text: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                depth -= 1;
                if (depth < 0) return false;
                i += 1;
            },
            '"', '\'', '`' => {
                i = scanStringForward(text, i, c) orelse return false;
            },
            else => i += 1,
        }
    }
    return depth == 0;
}

/// ZTS618 canonical_destructure_depth: flatten a simple nested object pattern.
///
/// Supported shape:
///   `const {outer: {inner}} = expr;`
///
/// The output names the intermediate object, then destructures the nested
/// fields from that name:
///   `const {outer} = expr;`
///   `const {inner} = outer;`
fn nestedDestructureRewrite(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    column: u32,
) !Repair {
    const pos = lineColToOffset(source, line, column) orelse return error.UnsupportedRefactor;
    const line_start = lineStartOffset(source, pos);
    const line_end = lineEndOffset(source, pos);
    const line_text = source[line_start..line_end];
    const trimmed_left = trimLeft(line_text, " \t");
    const indent = line_text[0 .. line_text.len - trimmed_left.len];
    if (!std.mem.startsWith(u8, trimmed_left, "const ")) return error.UnsupportedRefactor;

    const open = std.mem.indexOfScalar(u8, line_text, '{') orelse return error.UnsupportedRefactor;
    const close_abs = matchingDelimiter(source, line_start + open, '{', '}', line_end) orelse return error.UnsupportedRefactor;
    const close = close_abs - line_start;
    const eq = findTopLevelChar(source, close_abs + 1, line_end, '=') orelse return error.UnsupportedRefactor;
    const rhs = std.mem.trim(u8, source[eq + 1 .. line_end], " \t");
    if (rhs.len == 0) return error.UnsupportedRefactor;
    // The replacement captures the RHS only up to this line's newline. If the
    // expression does not finish on this line (an unbalanced `(`/`[`/`{` or an
    // unterminated string, e.g. `= makeUser(\n ...\n)`), refuse rather than emit
    // a truncated, broken two-line replacement. Mirrors the multiline guard the
    // ZTS617 lift rewriter applies to its signature.
    if (!delimitersBalanced(rhs)) return error.UnsupportedRefactor;

    const pattern = std.mem.trim(u8, line_text[open + 1 .. close], " \t");
    const colon = topLevelColon(pattern) orelse return error.UnsupportedRefactor;
    const outer = std.mem.trim(u8, pattern[0..colon], " \t");
    if (!isSimpleIdentifier(outer)) return error.UnsupportedRefactor;
    // The rewrite introduces `outer` as a binding, so nothing else in the file
    // may bind it. Asked through the validator's own predicate rather than
    // re-derived here: a producer that refused on a weaker condition would
    // advertise `repair_available` for an edit `validateApplication` then
    // refuses, and `apply_repair` drops the whole batch on one refusal.
    if (repairPolicy.bindsOutsideLines(source, line, 1, outer)) return error.UnsupportedRefactor;

    const nested = std.mem.trim(u8, pattern[colon + 1 ..], " \t");
    if (nested.len < 2 or nested[0] != '{' or nested[nested.len - 1] != '}') return error.UnsupportedRefactor;
    const inner = std.mem.trim(u8, nested[1 .. nested.len - 1], " \t");
    if (!isFlatIdentifierList(inner)) return error.UnsupportedRefactor;

    const replacement = try std.fmt.allocPrint(
        allocator,
        "{s}const {{{s}}} = {s}\n{s}const {{{s}}} = {s};",
        .{ indent, outer, rhs, indent, inner, outer },
    );
    errdefer allocator.free(replacement);
    const original = try allocator.dupe(u8, source[line_start..line_end]);
    errdefer allocator.free(original);

    return .{
        .intent = .flatten_destructure,
        .start_offset = line_start,
        .end_offset = line_end,
        .replacement = replacement,
        .original = original,
    };
}

/// ZTS619 canonical_unused_index_alias: collapse
/// `for (const pair of items.entries()) { const [_i, item] = pair; ... }`
/// to `for (const item of items) { ... }`.
fn unusedIndexAliasRewrite(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    column: u32,
) !Repair {
    const pos = lineColToOffset(source, line, column) orelse return error.UnsupportedRefactor;
    const for_start = lineStartOffset(source, pos);
    const for_end = lineEndOffset(source, pos);
    const for_line = source[for_start..for_end];
    const for_shape = parseForEntriesLine(for_line) orelse return error.UnsupportedRefactor;

    if (for_end >= source.len or source[for_end] != '\n') return error.UnsupportedRefactor;
    const destructure_start = for_end + 1;
    const destructure_end = lineEndOffset(source, destructure_start);
    const destructure_line = source[destructure_start..destructure_end];
    const destructure = parseIndexAliasDestructure(destructure_line, for_shape.binding) orelse return error.UnsupportedRefactor;

    const span_end = if (destructure_end < source.len and source[destructure_end] == '\n')
        destructure_end + 1
    else
        destructure_end;
    // Both dropped names must be dead from here on. The loop body is not the
    // whole obligation: `repair_validator.lawDropUnusedIndexAlias` re-derives
    // this over everything after the region, so checking only as far as the
    // closing brace would advertise a repair the validator then refuses.
    if (identifierTokenAppears(source[span_end..], for_shape.binding)) return error.UnsupportedRefactor;
    if (identifierTokenAppears(source[span_end..], destructure.index)) return error.UnsupportedRefactor;

    const replacement = try std.fmt.allocPrint(
        allocator,
        "{s}for (const {s} of {s}) {{\n",
        .{ for_shape.indent, destructure.value, for_shape.iterable },
    );
    errdefer allocator.free(replacement);
    const original = try allocator.dupe(u8, source[for_start..span_end]);
    errdefer allocator.free(original);

    return .{
        .intent = .drop_unused_index_alias,
        .start_offset = for_start,
        .end_offset = span_end,
        .replacement = replacement,
        .original = original,
    };
}

fn lineEndOffset(source: []const u8, pos: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
}

fn scanIdentEnd(source: []const u8, start: usize, end: usize) ?usize {
    if (start >= end or !isIdentStart(source[start])) return null;
    var i = start + 1;
    while (i < end and isIdentContinue(source[i])) i += 1;
    return i;
}

fn isSimpleIdentifier(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentContinue(c)) return false;
    }
    return true;
}

fn identifierTokenAppears(source: []const u8, ident: []const u8) bool {
    if (ident.len == 0) return false;
    var i: usize = 0;
    while (i < source.len) {
        if (!isIdentStart(source[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < source.len and isIdentContinue(source[i])) i += 1;
        if (std.mem.eql(u8, source[start..i], ident)) return true;
    }
    return false;
}

fn findTopLevelChar(source: []const u8, start: usize, end: usize, target: u8) ?usize {
    var i = start;
    var depth: i32 = 0;
    while (i < end) {
        const c = source[i];
        switch (c) {
            '(', '[', '{' => {
                depth += 1;
                i += 1;
            },
            ')', ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                i += 1;
            },
            '"', '\'', '`' => {
                const after = scanStringForward(source, i, c) orelse return null;
                if (after > end) return null;
                i = after;
            },
            else => {
                if (depth == 0 and c == target) return i;
                i += 1;
            },
        }
    }
    return null;
}

fn matchingDelimiter(source: []const u8, open: usize, open_ch: u8, close_ch: u8, limit: usize) ?usize {
    if (open >= limit or source[open] != open_ch) return null;
    var i = open + 1;
    var depth: u32 = 0;
    while (i < limit) {
        const c = source[i];
        if (c == open_ch) {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == close_ch) {
            if (depth == 0) return i;
            depth -= 1;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            const after = scanStringForward(source, i, c) orelse return null;
            if (after > limit) return null;
            i = after;
            continue;
        }
        i += 1;
    }
    return null;
}

fn topLevelColon(source: []const u8) ?usize {
    var i: usize = 0;
    var depth: i32 = 0;
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            '{', '[', '(' => {
                depth += 1;
                i += 1;
            },
            '}', ']', ')' => {
                if (depth == 0) return null;
                depth -= 1;
                i += 1;
            },
            ':' => {
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn isFlatIdentifierList(source: []const u8) bool {
    var rest = std.mem.trim(u8, source, " \t");
    if (rest.len == 0) return false;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, rest, ',');
        const item = std.mem.trim(u8, if (comma) |c| rest[0..c] else rest, " \t");
        if (!isSimpleIdentifier(item)) return false;
        if (comma == null) return true;
        rest = std.mem.trim(u8, rest[comma.? + 1 ..], " \t");
        if (rest.len == 0) return false;
    }
}

const ForEntriesLine = struct {
    indent: []const u8,
    binding: []const u8,
    iterable: []const u8,
};

fn parseForEntriesLine(line: []const u8) ?ForEntriesLine {
    const trimmed = trimLeft(line, " \t");
    const indent = line[0 .. line.len - trimmed.len];
    const prefix = "for (const ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];
    const binding_end = scanIdentEnd(rest, 0, rest.len) orelse return null;
    const binding = rest[0..binding_end];
    if (!isSimpleIdentifier(binding)) return null;
    rest = rest[binding_end..];
    rest = trimLeft(rest, " \t");
    if (!std.mem.startsWith(u8, rest, "of ")) return null;
    rest = trimLeft(rest["of ".len..], " \t");

    const entries = std.mem.lastIndexOf(u8, rest, ".entries()") orelse return null;
    const iterable = std.mem.trim(u8, rest[0..entries], " \t");
    if (iterable.len == 0) return null;
    var tail = trimLeft(rest[entries + ".entries()".len ..], " \t");
    if (tail.len == 0 or tail[0] != ')') return null;
    tail = trimLeft(tail[1..], " \t");
    if (tail.len == 0 or tail[0] != '{') return null;
    if (std.mem.trim(u8, tail[1..], " \t").len != 0) return null;
    return .{ .indent = indent, .binding = binding, .iterable = iterable };
}

const IndexAliasDestructure = struct {
    value: []const u8,
    /// The alias the rewrite drops. The caller re-derives that it is dead
    /// rather than trusting the diagnostic that reported it unused.
    index: []const u8,
};

fn parseIndexAliasDestructure(line: []const u8, pair_binding: []const u8) ?IndexAliasDestructure {
    const trimmed = trimLeft(line, " \t");
    const prefix = "const [";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
    const pattern = trimmed[prefix.len..close];
    const comma = std.mem.indexOfScalar(u8, pattern, ',') orelse return null;
    if (std.mem.indexOfScalarPos(u8, pattern, comma + 1, ',') != null) return null;
    const index_name = std.mem.trim(u8, pattern[0..comma], " \t");
    const value_name = std.mem.trim(u8, pattern[comma + 1 ..], " \t");
    if (!isSimpleIdentifier(index_name) or !isSimpleIdentifier(value_name)) return null;

    var tail = trimLeft(trimmed[close + 1 ..], " \t");
    if (tail.len == 0 or tail[0] != '=') return null;
    tail = std.mem.trim(u8, tail[1..], " \t;");
    if (!std.mem.eql(u8, tail, pair_binding)) return null;
    return .{ .value = value_name, .index = index_name };
}

fn appendSpanRepairUnique(
    allocator: std.mem.Allocator,
    source: []const u8,
    result: *Result,
    repair: Repair,
) !void {
    var owned = repair;
    // A span producer computes its own offsets and knows nothing about lines.
    // The line is filled here so every repair reports a position, whichever
    // side built it - the wire, the rewrite trace, and the M4 law check all
    // read one.
    owned.line = offsetLine(source, owned.start_offset);
    owned.column = 1;
    for (result.repairs.items) |existing| {
        if (existing.start_offset == owned.start_offset and existing.end_offset == owned.end_offset) {
            freeRepairOwned(allocator, &owned);
            return;
        }
    }
    result.repairs.append(allocator, owned) catch |err| {
        freeRepairOwned(allocator, &owned);
        return err;
    };
}

/// Select the subset of `rewrites` that can be applied together in one pass:
/// drop any rewrite whose span is strictly contained in another (apply the
/// inner one first, post-order), and any whose span overlaps another without
/// nesting (ambiguous; leave for a later pass). The fixed-point loop re-derives
/// rewrites against the new source each pass, so a dropped outer rewrite is
/// retried once its inner children are resolved. The returned slice borrows
/// from `rewrites`; the caller owns the backing list.
fn selectNonOverlapping(
    allocator: std.mem.Allocator,
    rewrites: []const Repair,
) ![]const Repair {
    var keep: std.ArrayListUnmanaged(Repair) = .empty;
    errdefer keep.deinit(allocator);
    outer: for (rewrites, 0..) |a, i| {
        for (rewrites, 0..) |b, j| {
            if (i == j) continue;
            const a_contains_b = a.start_offset <= b.start_offset and b.end_offset <= a.end_offset;
            const b_contains_a = b.start_offset <= a.start_offset and a.end_offset <= b.end_offset;
            const disjoint = a.end_offset <= b.start_offset or b.end_offset <= a.start_offset;
            // `a` is dropped this pass when it strictly contains another span:
            // apply the inner one first (post-order), retry `a` next pass once
            // its child is resolved.
            if (a_contains_b and !b_contains_a) continue :outer;
            // Partial overlap with neither containing the other is ambiguous;
            // keep only the earlier-starting span this pass so the result is
            // deterministic. (Equal spans are de-duplicated before this point.)
            if (!disjoint and !a_contains_b and !b_contains_a and a.start_offset > b.start_offset) continue :outer;
        }
        try keep.append(allocator, a);
    }
    return keep.toOwnedSlice(allocator);
}

pub fn simulateRepairs(
    allocator: std.mem.Allocator,
    file: []const u8,
    result: *const Result,
) !SimulationSummary {
    const source = try zts.file_io.readFile(allocator, file, 10 * 1024 * 1024);
    defer allocator.free(source);

    const proposed = try applyRepairs(allocator, source, result.repairs.items);
    defer allocator.free(proposed);

    var simulation = try edit_simulate.simulate(allocator, .{
        .file = file,
        .content = proposed,
        .before = source,
    });
    defer simulation.deinit(allocator);

    return .{
        .ok = simulation.new_count == 0,
        .total = simulation.total,
        .new_count = simulation.new_count,
        .preexisting_count = simulation.preexisting_count,
    };
}

// ---------------------------------------------------------------------------
// Fixed-point normalizer
// ---------------------------------------------------------------------------

/// Backstop on the rewrite loop. Each pass strictly reduces the count of
/// canonical-band diagnostics, so a real handler converges in a handful of
/// passes; the cap only defends against a future refactor that fails to reduce
/// the measure (which must never silently report `canonical`). Hitting the cap
/// leaves `converged = false`.
pub const max_normalize_iterations: u32 = 64;

fn isCanonicalBandCode(code: []const u8) bool {
    return zts.PolicyCatalog.isCanonicalProfileCode(code);
}

/// JSX and TSX sources are outside the formatter's coverage: a bare tokenizer
/// run is not in JSX mode, so element text would be re-read as code.
fn isJsxLike(path: []const u8) bool {
    return zts.classifySourcePath(path) == .tsx;
}

pub const NormalizeResult = struct {
    /// The handler source after reaching the rewrite fixed point. Owned.
    canonical_source: []u8,
    /// Ordered intents applied across all passes (one per rewritten node).
    rewrite_trace: std.ArrayListUnmanaged(RepairIntent) = .empty,
    /// True when the loop reached a fixed point (no refactor fired) rather than
    /// hitting the iteration cap or aborting on a per-pass gate.
    converged: bool,
    /// True iff zero canonical-band diagnostics at `error` severity remain in
    /// `canonical_source`. Distinct from `converged`: a handler with an
    /// unrewritten ternary converges (no refactor fires) yet is not fully
    /// canonical.
    ///
    /// Advisories do not deny it. Spec 4.2.1: a non-idiomatic spelling "is
    /// never an error and never fails a build", and a row whose precondition
    /// fails emits no rewrite, so a file carrying one has nothing left to
    /// apply - which is what Canonical Normal Form means. Counting advisories
    /// here made `--write` refuse a legal program for a preference it could
    /// not act on. The progress measure inside the loop (`countBand`) still
    /// counts every band diagnostic, because a rewrite that clears an advisory
    /// has made progress and the loop must not read it as a stall.
    fully_canonical: bool,
    /// Passes actually run.
    iterations: u32,
    /// Canonical-band diagnostics at `error` severity still present after
    /// normalization (0 when `fully_canonical`).
    residual: u32,
    /// Owned details for every remaining canonical-profile diagnostic,
    /// advisories included. This is the reporting channel, so it is wider than
    /// `residual`: a client that reads only the count would never learn the
    /// preference the profile named.
    residual_diagnostics: std.ArrayListUnmanaged(ResidualDiagnostic) = .empty,
    /// True when the canonical formatter printed `canonical_source`. A false
    /// here is not a rewrite failure: the printer covers constructs one at a
    /// time and refuses the rest, so the bytes are the rewrite fixed point in
    /// the layout the author wrote.
    printed: bool,
    /// Why the formatter refused, when it did. Reported rather than dropped so
    /// a gate names the construct instead of the file alone.
    printer_refusal: ?zts.printer.Refusal = null,
    /// True when `canonical_source` differs from the bytes handed in. The
    /// verdict `--check` reads: a file that needed no rewrite can still need a
    /// layout, and an iteration count cannot see that.
    changed: bool,

    pub fn deinit(self: *NormalizeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_source);
        self.rewrite_trace.deinit(allocator);
        for (self.residual_diagnostics.items) |*diag| diag.deinit(allocator);
        self.residual_diagnostics.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResidualDiagnostic = struct {
    code: []u8,
    severity: []u8,
    message: []u8,
    file: []u8,
    line: u32,
    column: u32,
    suggestion: ?[]u8,
    repair_intent: ?[]const u8,
    reason: []const u8,

    pub fn deinit(self: *ResidualDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.severity);
        allocator.free(self.message);
        allocator.free(self.file);
        if (self.suggestion) |s| allocator.free(s);
        self.* = undefined;
    }
};

/// Normalize a handler file: read it, then drive `normalizeSource`.
pub fn normalize(allocator: std.mem.Allocator, file: []const u8) !NormalizeResult {
    return normalizeWithSchema(allocator, file, null);
}

/// `normalize` for a handler whose analysis needs a SQL schema. A `zttp:sql`
/// query is type-checked against the schema, so without one every pass fails
/// with `MissingSqlSchema` and the file cannot be normalized at all - it is not
/// that the file resists rewriting, it is that the analysis never ran.
pub fn normalizeWithSchema(
    allocator: std.mem.Allocator,
    file: []const u8,
    sql_schema_path: ?[]const u8,
) !NormalizeResult {
    const source = try zts.file_io.readFile(allocator, file, 10 * 1024 * 1024);
    defer allocator.free(source);
    return normalizeSourceWithSchema(allocator, source, file, sql_schema_path);
}

/// Reduce `source` to its Canonical Normal Form by applying every available
/// canonical refactor to a fixed point. Confluent and terminating: at most one
/// refactor applies per source line per pass (`applyRefactors` rejects
/// overlaps), every emitted refactor is a closed-form local rewrite whose
/// output carries no refactorable node of the same kind, and each pass strictly
/// reduces the canonical-diagnostic measure. A per-pass `edit_simulate` gate
/// rejects any pass that would introduce a new violation.
pub fn normalizeSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
) !NormalizeResult {
    return normalizeSourceWithSchema(allocator, source, virtual_path, null);
}

/// What a caller wants out of a normalize run.
pub const NormalizeOptions = struct {
    sql_schema_path: ?[]const u8 = null,
    /// Run the canonical formatter over the rewrite fixed point.
    ///
    /// A caller that presents the result as its own edit turns this off. The
    /// pi veto's salvage-on-reject is that caller: it normalizes only a
    /// would-be-reject and writes the result back as the model's edit, so with
    /// layout on, one `let` the model should have written `const` came back as
    /// a whole-file reindent. Its own comment calls the salvage surgical, and
    /// the guard it uses to detect one - the bytes changed - is true for
    /// almost every file once layout runs.
    layout: bool = true,
};

pub fn normalizeSourceWithSchema(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    sql_schema_path: ?[]const u8,
) !NormalizeResult {
    return normalizeSourceWithOptions(allocator, source, virtual_path, .{
        .sql_schema_path = sql_schema_path,
    });
}

pub fn normalizeSourceWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    options: NormalizeOptions,
) !NormalizeResult {
    const sql_schema_path = options.sql_schema_path;
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    var trace: std.ArrayListUnmanaged(RepairIntent) = .empty;
    errdefer trace.deinit(allocator);

    var iterations: u32 = 0;
    var converged = false;
    while (iterations < max_normalize_iterations) {
        var check = try precompile.runCheckOnlyFromSource(allocator, current, virtual_path, sql_schema_path, true, null, false);
        defer check.deinit(allocator);
        const cur_band = countBand(check.json_diagnostics.items);

        // Line-keyed single-line refactors take priority each pass; they are
        // the original Phase-1 rewriters and rely on `applyRefactors`' overlap
        // guard.
        var result = Result{ .file = virtual_path };
        defer result.deinit(allocator);
        try buildLineRepairs(allocator, current, check.json_diagnostics.items, &result);

        // Span-keyed multi-line / convention rewrites for this pass.
        var stmt_result = Result{ .file = "" };
        defer stmt_result.deinit(allocator);
        try buildSpanRepairs(allocator, current, check.json_diagnostics.items, &stmt_result);

        if (result.repairs.items.len == 0 and stmt_result.repairs.items.len == 0) {
            converged = true;
            break;
        }

        const Step = struct { next: []u8, intents: []const RepairIntent, intents_owned: bool };
        const step: ?Step = blk: {
            if (result.repairs.items.len > 0) {
                const next = applyRepairs(allocator, current, result.repairs.items) catch |err| switch (err) {
                    // A pass we cannot apply deterministically (two repairs
                    // whose spans overlap, a stale snapshot, a span outside the
                    // source) stops the loop short of a fixed point rather than
                    // guessing.
                    error.OverlappingRepairs,
                    error.StaleRepair,
                    error.RepairOutOfBounds,
                    => break :blk null,
                    else => return err,
                };
                break :blk .{ .next = next, .intents = &.{}, .intents_owned = false };
            }
            // No line-derived repairs this pass: apply the innermost
            // non-overlapping subset of span repairs, post-order.
            const subset = selectNonOverlapping(allocator, stmt_result.repairs.items) catch |err| return err;
            defer allocator.free(subset);
            if (subset.len == 0) break :blk null;
            const next = applyRepairs(allocator, current, subset) catch |err| switch (err) {
                error.OverlappingRepairs,
                error.StaleRepair,
                error.RepairOutOfBounds,
                => break :blk null,
                else => return err,
            };
            const intents = try allocator.alloc(RepairIntent, subset.len);
            for (subset, 0..) |rw, i| intents[i] = rw.intent;
            break :blk .{ .next = next, .intents = intents, .intents_owned = true };
        };
        const s = step orelse break;
        const next = s.next;

        // Per-pass gate. Reject a rewrite that fails to parse/type-check (a
        // malformed replacement) or that does not strictly reduce the
        // canonical-band measure (no progress -> would loop to the cap).
        // Spec-discharge / flow diagnostics that a *fixed* strict error
        // unmasks are deliberately ignored: they are latent properties of the
        // handler, not introduced by the rewrite, and removing the masking
        // strict error is exactly the canonicalization we want.
        var next_check = try precompile.runCheckOnlyFromSource(allocator, next, virtual_path, sql_schema_path, true, null, false);
        const hard_errors = next_check.parse_errors + next_check.type_errors + next_check.bool_errors;
        const next_band = countBand(next_check.json_diagnostics.items);
        next_check.deinit(allocator);
        if (hard_errors > 0 or next_band >= cur_band) {
            allocator.free(next);
            if (s.intents_owned) allocator.free(s.intents);
            break;
        }

        // Record the applied intents. On an OOM here, free the freshly-built
        // `next` and any owned `intents` before propagating so the only live
        // allocations remain `current` and `trace` (both covered by errdefer).
        {
            errdefer allocator.free(next);
            errdefer if (s.intents_owned) allocator.free(s.intents);
            if (result.repairs.items.len > 0) {
                for (result.repairs.items) |r| {
                    try trace.append(allocator, r.intent);
                }
            } else {
                for (s.intents) |intent| try trace.append(allocator, intent);
            }
        }
        if (s.intents_owned) allocator.free(s.intents);
        allocator.free(current);
        current = next;
        iterations += 1;
    }

    // The layout pass runs last, over the rewrite fixed point, so a rewrite
    // never has to produce canonical whitespace and the printer never has to
    // understand a half-applied rewrite. It fails closed: a construct outside
    // its coverage leaves the rewritten bytes exactly as they are.
    var refusal: zts.printer.Refusal = undefined;
    var printed = false;
    if (options.layout) {
        if (zts.printer.print(allocator, current, .{
            .jsx = isJsxLike(virtual_path),
            .reason_out = &refusal,
        })) |formatted| {
            allocator.free(current);
            current = formatted;
            printed = true;
        } else |err| switch (err) {
            error.UnprintableConstruct => {},
            error.OutOfMemory => return err,
        }
    }

    // Collected over `current`, which is what this call emits: the canonical
    // source on stdout, or the bytes `--write` puts on disk. So a residual
    // diagnostic's line and column index the canonical source and not the file
    // as it stands before the run, even though `file` names that path. The
    // alternative - measuring the input - would report diagnostics the rewrite
    // loop has already cleared.
    var residual_diagnostics = try collectCanonicalResidualDiagnostics(allocator, current, virtual_path, sql_schema_path);
    errdefer {
        for (residual_diagnostics.items) |*diag| diag.deinit(allocator);
        residual_diagnostics.deinit(allocator);
    }
    var residual: u32 = 0;
    for (residual_diagnostics.items) |diag| {
        if (std.mem.eql(u8, diag.severity, "error")) residual += 1;
    }
    return .{
        .canonical_source = current,
        .rewrite_trace = trace,
        .converged = converged,
        .fully_canonical = residual == 0,
        .iterations = iterations,
        .residual = residual,
        .residual_diagnostics = residual_diagnostics,
        .printed = printed,
        // No refusal to report when the formatter was never asked to run.
        .printer_refusal = if (printed or !options.layout) null else refusal,
        .changed = !std.mem.eql(u8, source, current),
    };
}

/// Count the canonical-band diagnostics in a diagnostic set, at every
/// severity. This is the normalize loop's progress measure and not its verdict:
/// a pass that turns an advisory into its idiomatic spelling has made progress,
/// and a measure blind to advisories would read that pass as a stall and stop
/// the loop. The verdict - `fully_canonical` - counts errors only.
fn countBand(diagnostics: []const precompile.json_diag.JsonDiagnostic) u32 {
    var n: u32 = 0;
    for (diagnostics) |diag| {
        if (isCanonicalBandCode(diag.code)) n += 1;
    }
    return n;
}

/// Collect canonical-band diagnostics remaining in `source`.
fn collectCanonicalResidualDiagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    sql_schema_path: ?[]const u8,
) !std.ArrayListUnmanaged(ResidualDiagnostic) {
    var check = try precompile.runCheckOnlyFromSource(allocator, source, virtual_path, sql_schema_path, true, null, false);
    defer check.deinit(allocator);

    var out: std.ArrayListUnmanaged(ResidualDiagnostic) = .empty;
    errdefer {
        for (out.items) |*diag| diag.deinit(allocator);
        out.deinit(allocator);
    }
    for (check.json_diagnostics.items) |diag| {
        if (!isCanonicalBandCode(diag.code)) continue;
        var owned = try cloneResidualDiagnostic(allocator, diag);
        errdefer owned.deinit(allocator);
        try out.append(allocator, owned);
    }
    return out;
}

fn cloneResidualDiagnostic(
    allocator: std.mem.Allocator,
    diag: precompile.json_diag.JsonDiagnostic,
) !ResidualDiagnostic {
    const rule = zts.PolicyCatalog.findByCode(diag.code);
    var out = ResidualDiagnostic{
        .code = try allocator.dupe(u8, diag.code),
        .severity = &.{},
        .message = &.{},
        .file = &.{},
        .line = diag.line,
        .column = diag.column,
        .suggestion = null,
        .repair_intent = if (rule) |r| if (r.repair) |intent| intent.asString() else null else null,
        .reason = "no behavior-preserving normalizer rewrite applied",
    };
    errdefer out.deinit(allocator);
    out.severity = try allocator.dupe(u8, diag.severity);
    out.message = try allocator.dupe(u8, diag.message);
    out.file = try allocator.dupe(u8, diag.file);
    if (diag.suggestion) |s| out.suggestion = try allocator.dupe(u8, s);
    return out;
}

pub fn writeNormalizeJson(
    writer: anytype,
    file: []const u8,
    nr: *const NormalizeResult,
    written: bool,
) !void {
    const hash = zts.policyHash();
    try writer.writeAll("{\"ok\":true,\"file\":");
    try writeJsonString(writer, file);
    try writer.writeAll(",\"policy_hash\":");
    try writeJsonString(writer, &hash);
    try writer.print(
        ",\"converged\":{},\"fullyCanonical\":{},\"iterations\":{d},\"residual\":{d},\"written\":{}",
        .{ nr.converged, nr.fully_canonical, nr.iterations, nr.residual, written },
    );
    try writer.writeAll(",\"rewriteTrace\":[");
    for (nr.rewrite_trace.items, 0..) |intent, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, intent.asString());
    }
    try writer.writeAll("],\"residualDiagnostics\":[");
    for (nr.residual_diagnostics.items, 0..) |*diag, i| {
        if (i > 0) try writer.writeByte(',');
        try writeResidualDiagnosticJson(writer, diag);
    }
    try writer.writeAll("],\"canonicalSource\":");
    try writeJsonString(writer, nr.canonical_source);
    try writer.writeAll("}\n");
}

fn writeResidualDiagnosticJson(writer: anytype, diag: *const ResidualDiagnostic) !void {
    try writer.writeAll("{\"code\":");
    try writeJsonString(writer, diag.code);
    try writer.writeAll(",\"severity\":");
    try writeJsonString(writer, diag.severity);
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, diag.message);
    try writer.writeAll(",\"file\":");
    try writeJsonString(writer, diag.file);
    try writer.print(",\"line\":{d},\"column\":{d}", .{ diag.line, diag.column });
    try writer.writeAll(",\"suggestion\":");
    if (diag.suggestion) |s| {
        try writeJsonString(writer, s);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"repairIntent\":");
    if (diag.repair_intent) |intent| {
        try writeJsonString(writer, intent);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"reason\":");
    try writeJsonString(writer, diag.reason);
    try writer.writeByte('}');
}

/// `zts normalize <file> [--write] [--check] [--json]` — the gofmt-for-
/// semantics surface. Default prints canonical source; `--write` rewrites in
/// place (refusing unless fully canonical); `--check` exits 1 when not yet
/// canonical (CI gate); `--json` emits a structured envelope with the rewrite
/// trace. Reachable as both `zts normalize` and `zttp normalize`.
pub fn runNormalizeWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var file: ?[]const u8 = null;
    var write_mode = false;
    var check_mode = false;
    var json_mode = false;
    var sql_schema_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--write")) {
            write_mode = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--sql-schema")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            sql_schema_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--help")) {
            printNormalizeHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-") and file == null) {
            file = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    const path = file orelse {
        const usage = "Usage: zts normalize <file> [--write] [--check] [--json] [--sql-schema <path>]\n";
        _ = std.c.write(std.c.STDERR_FILENO, usage.ptr, usage.len);
        std.process.exit(1);
    };
    if (write_mode and check_mode) return error.InvalidArgument;

    var nr = try normalizeWithSchema(allocator, path, sql_schema_path);
    defer nr.deinit(allocator);

    if (json_mode) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
        // `written` is the machine channel's answer to "is the file on disk
        // canonical now", so it has to agree with every condition the write
        // path checks - the formatter refusal included. It reported true for a
        // file the refusal then declined to write.
        try writeNormalizeJson(
            &aw.writer,
            path,
            &nr,
            write_mode and nr.fully_canonical and nr.converged and nr.printed,
        );
        buf = aw.toArrayList();
        if (buf.items.len > 0) _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
    }

    if (!nr.printed) reportPrinterRefusal(path, nr.printer_refusal);

    if (check_mode) {
        // gofmt -l semantics: the file is "clean" only if it is ALREADY in
        // canonical form, i.e. normalize changed nothing and no canonical-band
        // diagnostic remains. The measure is the bytes, not the pass count: a
        // file no rewrite fires on can still be laid out differently, and an
        // iteration count cannot see that.
        //
        // A file the formatter refused is not canonical either, and reporting
        // it clean made the CI gate green over every file that was never laid
        // out - it is `--write`'s exit 1 and `--check`'s exit 0 disagreeing
        // about one file. A refusal leaves the bytes untouched, so `changed`
        // is false and cannot carry this on its own.
        if (nr.changed or !nr.fully_canonical or !nr.printed) {
            if (!json_mode) {
                _ = std.c.write(std.c.STDERR_FILENO, path.ptr, path.len);
                _ = std.c.write(std.c.STDERR_FILENO, "\n", 1);
            }
            std.process.exit(1);
        }
        return;
    }

    if (write_mode) {
        // Never silently accept a partial normalization: refuse the write when
        // the loop did not reach a fixed point or a canonical-band diagnostic
        // remains (an unrewritten construct from a not-yet-implemented phase).
        if (!nr.converged or !nr.fully_canonical) {
            if (!json_mode) {
                const msg = "normalize: not fully canonical; refusing --write (run `zts check` for residual)\n";
                _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
            }
            std.process.exit(1);
        }
        // A file the formatter refused would be written in the author's
        // layout under a name that claims canonical form. Decline instead.
        if (!nr.printed) {
            if (!json_mode) {
                const msg = "normalize: the canonical formatter refused this file; refusing --write\n";
                _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
            }
            std.process.exit(1);
        }
        try zts.file_io.writeFile(allocator, path, nr.canonical_source);
        return;
    }

    if (!json_mode and nr.canonical_source.len > 0) {
        _ = std.c.write(std.c.STDOUT_FILENO, nr.canonical_source.ptr, nr.canonical_source.len);
    }
}

/// Name the construct on stderr. A refusal that printed nothing would be read
/// as coverage, and the gate over the corpus is what widens the printer.
fn reportPrinterRefusal(path: []const u8, reason: ?zts.printer.Refusal) void {
    const head = "normalize: printer refused ";
    _ = std.c.write(std.c.STDERR_FILENO, head.ptr, head.len);
    _ = std.c.write(std.c.STDERR_FILENO, path.ptr, path.len);
    const text = if (reason) |r| r.text() else "unknown";
    _ = std.c.write(std.c.STDERR_FILENO, ": ", 2);
    _ = std.c.write(std.c.STDERR_FILENO, text.ptr, text.len);
    _ = std.c.write(std.c.STDERR_FILENO, "\n", 1);
}

fn printNormalizeHelp() void {
    const help =
        \\zts normalize - rewrite a handler into Canonical Normal Form
        \\
        \\Usage: zts normalize <file> [--write] [--check] [--json] [--sql-schema <path>]
        \\
        \\  (default)      print the canonical source to stdout
        \\  --write        rewrite the file in place (refuses unless fully canonical)
        \\  --check        exit 1 if the file is not already canonical (CI gate)
        \\  --json         emit a structured envelope with the rewrite trace
        \\  --sql-schema   schema a `zttp:sql` handler is type-checked against
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

pub fn writeJson(writer: anytype, result: *const Result) !void {
    try writeJsonWithSimulation(writer, result, null);
}

pub fn writeJsonWithSimulation(
    writer: anytype,
    result: *const Result,
    simulation: ?SimulationSummary,
) !void {
    const hash = zts.policyHash();
    try writer.writeAll("{\"ok\":true,\"file\":");
    try writeJsonString(writer, result.file);
    try writer.writeAll(",\"policy_hash\":");
    try writeJsonString(writer, &hash);
    try writer.writeAll(",\"refactors\":[");
    for (result.repairs.items, 0..) |r, i| {
        if (i > 0) try writer.writeByte(',');
        // v1 keeps its spelling. D3 §6 freezes v1 command shapes, so this is
        // the one surface where the legacy names still appear.
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, legacyKind(r.intent));
        try writer.print(",\"line\":{d},\"column\":{d},\"message\":", .{ r.line, r.column });
        try writeJsonString(writer, r.message);
        try writer.writeAll(",\"replacement\":");
        try writeJsonString(writer, r.replacement);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    if (simulation) |sim| {
        try writer.print(
            ",\"simulation\":{{\"ok\":{},\"total\":{d},\"new\":{d},\"preexisting\":{d}}}",
            .{ sim.ok, sim.total, sim.new_count, sim.preexisting_count },
        );
    }
    try writer.writeAll("}\n");
}

pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var file: ?[]const u8 = null;
    var json_mode = false;
    var simulate_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--simulate")) {
            simulate_mode = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-") and file == null) {
            file = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    const path = file orelse {
        const usage = "Usage: zts canonicalize <file> --json [--simulate]\n";
        _ = std.c.write(std.c.STDERR_FILENO, usage.ptr, usage.len);
        std.process.exit(1);
    };
    if (!json_mode) return error.InvalidArgument;

    var result = try collect(allocator, path);
    defer result.deinit(allocator);
    const simulation = if (simulate_mode)
        try simulateRepairs(allocator, path, &result)
    else
        null;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    try writeJsonWithSimulation(&aw.writer, &result, simulation);
    buf = aw.toArrayList();
    if (buf.items.len > 0) _ = std.c.write(std.c.STDOUT_FILENO, buf.items.ptr, buf.items.len);
}

fn printHelp() void {
    const help =
        \\zts canonicalize - preview canonical local refactors
        \\
        \\Usage: zts canonicalize <file> --json [--simulate]
        \\
        \\Emits rewrite intents only. --simulate applies previews in memory and
        \\runs edit-simulate; it never writes source.
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

test "canonicalFunctionReplacement rewrites arrow expression" {
    const got = try canonicalFunctionReplacement(std.testing.allocator, "const parse = (x: number): number => x;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("function parse(x: number): number { return x; }", got);
}

test "canonicalFunctionReplacement rewrites exported arrow expression" {
    const got = try canonicalFunctionReplacement(std.testing.allocator, "export const load = (id: string): Response => Response.text(id);");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("export function load(id: string): Response { return Response.text(id); }", got);
}

test "canonicalFunctionReplacement wraps single arrow param" {
    const got = try canonicalFunctionReplacement(std.testing.allocator, "const id = x => x;");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("function id(x) { return x; }", got);
}

test "canonicalFunctionReplacement rejects typed const bindings" {
    try std.testing.expectError(
        error.UnsupportedRefactor,
        canonicalFunctionReplacement(std.testing.allocator, "const parse: Parser = (x: number): number => x;"),
    );
}

test "canonicalFunctionReplacement rejects generic arrow helpers" {
    try std.testing.expectError(
        error.UnsupportedRefactor,
        canonicalFunctionReplacement(std.testing.allocator, "const id = <T>(x: T): T => x;"),
    );
}

test "avoidableLetReplacement rewrites local let" {
    const got = try avoidableLetReplacement(std.testing.allocator, "    let key = \"API_KEY\";");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("    const key = \"API_KEY\";", got);
}

test "avoidableLetReplacement rewrites for-of binding" {
    const got = try avoidableLetReplacement(std.testing.allocator, "for (let item of items) {");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("for (const item of items) {", got);
}

test "redundantBoolCompareReplacement rewrites `=== true` to bare boolean" {
    // `  const ok = ready === true;` -- `===` operator starts at column 20.
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  const ok = ready === true;", 20, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  const ok = ready;", got);
}

test "redundantBoolCompareReplacement rewrites `=== false` to negation" {
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  const ok = ready === false;", 20, false);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  const ok = !ready;", got);
}

test "redundantBoolCompareReplacement rewrites `!== false` to bare boolean" {
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  const ok = ready !== false;", 20, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  const ok = ready;", got);
}

test "redundantBoolCompareReplacement rewrites literal-on-left form" {
    // `  if (true === ready) { ... }` -- `===` operator starts at column 12.
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  if (true === ready) { return Response.text(\"a\"); }", 12, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  if (ready) { return Response.text(\"a\"); }", got);
}

test "redundantBoolCompareReplacement preserves trailing line content for `if`" {
    // `  if (ready === true) { ... }` -- `===` operator starts at column 13.
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  if (ready === true) { return Response.text(\"a\"); }", 13, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  if (ready) { return Response.text(\"a\"); }", got);
}

test "redundantBoolCompareReplacement keeps member-access value operand" {
    // `  const ok = req.ready === true;` -- `===` operator starts at column 24.
    const got = try redundantBoolCompareReplacement(std.testing.allocator, "  const ok = req.ready === true;", 24, true);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("  const ok = req.ready;", got);
}

test "redundantBoolCompareReplacement refuses a non-simple value operand" {
    // A call-valued operand (`ready()`) cannot be re-spelled as a bare boolean
    // without re-deriving its span and risking a behavior change: refuse it.
    // `  const ok = ready() === true;` -- `===` operator starts at column 22.
    try std.testing.expectError(
        error.UnsupportedRefactor,
        redundantBoolCompareReplacement(std.testing.allocator, "  const ok = ready() === true;", 22, true),
    );
}

fn expectCanonicalizeEnvelope(json: []const u8, file: []const u8, expected_count: usize) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    errdefer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    const ok = obj.get("ok") orelse return error.MissingOk;
    const file_value = obj.get("file") orelse return error.MissingFile;
    const hash = obj.get("policy_hash") orelse return error.MissingPolicyHash;
    const refactors = obj.get("refactors") orelse return error.MissingRefactors;
    try std.testing.expect(ok == .bool and ok.bool);
    try std.testing.expect(file_value == .string);
    try std.testing.expectEqualStrings(file, file_value.string);
    try std.testing.expect(hash == .string);
    try std.testing.expectEqual(@as(usize, 64), hash.string.len);
    try std.testing.expect(refactors == .array);
    try std.testing.expectEqual(expected_count, refactors.array.items.len);
    for (refactors.array.items) |item| {
        try std.testing.expect(item == .object);
        const refactor = item.object;
        try std.testing.expect((refactor.get("kind") orelse return error.MissingKind) == .string);
        try std.testing.expect((refactor.get("line") orelse return error.MissingLine) == .integer);
        try std.testing.expect((refactor.get("column") orelse return error.MissingColumn) == .integer);
        try std.testing.expect((refactor.get("message") orelse return error.MissingMessage) == .string);
        try std.testing.expect((refactor.get("replacement") orelse return error.MissingReplacement) == .string);
    }
    return parsed;
}

fn collectAndWriteJson(source: []const u8) !struct { json: []u8, file: []const u8 } {
    const virtual_path = "handler.ts";
    var preview = try collectFromSource(std.testing.allocator, source, virtual_path);
    defer preview.deinit(std.testing.allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    try writeJson(&aw.writer, &preview);
    buf = aw.toArrayList();

    const json = try buf.toOwnedSlice(std.testing.allocator);
    errdefer std.testing.allocator.free(json);
    // Dupe so callers can keep their `defer free(out.file)` symmetry.
    const file = try std.testing.allocator.dupe(u8, virtual_path);
    return .{ .json = json, .file = file };
}

test "writeJson envelope is stable with no refactors" {
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    const out = try collectAndWriteJson(source);
    defer std.testing.allocator.free(out.json);
    defer std.testing.allocator.free(out.file);

    var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 0);
    defer parsed.deinit();
}

test "every rewrite row has a v1 name, and only the renamed five differ" {
    // The mapping is the whole compatibility surface. Five rows are renamed
    // and the other two are their own tag; asserting both directions is what
    // stops a future row from quietly acquiring a sixth legacy name, or a
    // renamed one from losing its v1 spelling.
    try std.testing.expectEqualStrings("canonicalize_arrow_helper", legacyKind(.replace_arrow_with_function));
    try std.testing.expectEqualStrings("canonicalize_export_function", legacyKind(.replace_export_arrow_with_function));
    try std.testing.expectEqualStrings("canonicalize_let_const", legacyKind(.replace_let_with_const));
    try std.testing.expectEqualStrings("canonicalize_compound_assign", legacyKind(.replace_compound_assign_with_explicit));
    try std.testing.expectEqualStrings("canonicalize_redundant_bool_compare", legacyKind(.drop_redundant_bool_compare));

    try std.testing.expectEqualStrings("canonicalize_for_of_const", legacyKind(.canonicalize_for_of_const));
    try std.testing.expectEqualStrings("canonicalize_capability_key_alias", legacyKind(.canonicalize_capability_key_alias));

    // An intent that never reached the line-keyed path renders as its tag:
    // there is no v1 output to stay compatible with.
    try std.testing.expectEqualStrings("replace_ternary_with_if", legacyKind(.replace_ternary_with_if));

    var renamed: usize = 0;
    for (rewrite_row_intents) |intent| {
        if (!std.mem.eql(u8, legacyKind(intent), @tagName(intent))) renamed += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), renamed);
}

test "every graded rewrite this rewriter emits discharges against its law" {
    // The differential check, and the reason the validator lives in `zts` with
    // its own scanners rather than calling back into this file. Two independent
    // derivations of the same law run over the same real input: this rewriter
    // produces the edit, and `repair_validator` re-derives what the edit should
    // have been and compares byte for byte. Agreeing proves both; a unit test
    // on either alone proves only that it agrees with itself.
    //
    // Driven off `rewrite_row_intents`, so a row that becomes gradable without
    // a fixture here fails the coverage assertion at the end rather than
    // slipping through untested.
    const allocator = std.testing.allocator;
    const fixtures = [_]struct { intent: RepairIntent, source: []const u8 }{
        .{ .intent = .replace_let_with_const, .source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count });
        \\}
        },
        .{ .intent = .canonicalize_for_of_const, .source =
        \\function handler(req: Request): Response {
        \\  const items = [1, 2];
        \\  for (let item of items) {
        \\    Response.json({ item });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
        },
        .{ .intent = .replace_compound_assign_with_explicit, .source =
        \\function handler(req: Request): Response {
        \\  let total = 10;
        \\  total -= 2 + 3;
        \\  return Response.json({ total });
        \\}
        },
        .{ .intent = .replace_arrow_with_function, .source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a, b });
        \\}
        },
        .{ .intent = .replace_export_arrow_with_function, .source =
        \\export const load = (id: string): Response => Response.text(id);
        \\function handler(req: Request): Response {
        \\  return load("x");
        \\}
        },
        .{ .intent = .drop_redundant_bool_compare, .source =
        \\function handler(req: Request): Response {
        \\  const ready = true;
        \\  if (ready === true) { return Response.json({ ok: true }); }
        \\  return Response.json({ ok: false });
        \\}
        },
        // The two region rewrites. Their laws re-derive a replacement spanning
        // more than one line and re-derive their own preconditions, so this
        // pairing is the only place either is checked against the rewriter that
        // produces it.
        .{ .intent = .flatten_destructure, .source =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name);
        \\}
        },
        .{ .intent = .drop_unused_index_alias, .source =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
        },
    };

    var checked: usize = 0;
    for (fixtures) |fixture| {
        if (!repairPolicy.isGradable(fixture.intent)) continue;

        // Both builders, not just the line-keyed one. `collectFromSource` runs
        // `buildLineRepairs` alone, so driving this test off it would have left
        // every span-keyed rewrite - which is every multi-line one - collecting
        // nothing and reporting a pass over the rows it did reach.
        var check = try precompile.runCheckOnlyFromSource(allocator, fixture.source, "handler.ts", null, true, null, false);
        defer check.deinit(allocator);
        var result = Result{ .file = "handler.ts" };
        defer result.deinit(allocator);
        try buildLineRepairs(allocator, fixture.source, check.json_diagnostics.items, &result);
        try buildSpanRepairs(allocator, fixture.source, check.json_diagnostics.items, &result);

        var found: ?Repair = null;
        for (result.repairs.items) |r| {
            if (r.intent == fixture.intent) {
                found = r;
                break;
            }
        }
        const refactor = found orelse {
            std.debug.print("no {s} refactor emitted for its fixture\n", .{@tagName(fixture.intent)});
            return error.TestFailed;
        };

        var one = [_]Repair{refactor};
        const repaired = try applyRepairs(allocator, fixture.source, &one);
        defer allocator.free(repaired);

        switch (try repairPolicy.validateApplication(
            allocator,
            fixture.intent,
            fixture.source,
            repaired,
            refactor.line,
        )) {
            .equivalent => checked += 1,
            .not_law_shape => |why| {
                std.debug.print("{s}: the rewriter and its law disagree: {s}\n", .{ @tagName(fixture.intent), why });
                return error.TestFailed;
            },
            .no_validator => {
                std.debug.print("{s} is gradable and has no validator\n", .{@tagName(fixture.intent)});
                return error.TestFailed;
            },
            .undecided => |why| {
                std.debug.print("{s}: its validator formed no answer: {s}\n", .{ @tagName(fixture.intent), why });
                return error.TestFailed;
            },
        }
    }

    // Every gradable row this rewriter can emit is covered above. A new one
    // fails here rather than shipping a graded intent nothing cross-checks.
    var gradable_rows: usize = 0;
    for (rewrite_row_intents) |intent| {
        if (repairPolicy.isGradable(intent)) gradable_rows += 1;
    }
    try std.testing.expectEqual(gradable_rows, checked);
}

test "writeJson envelope covers all deterministic refactor kinds" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        kind: []const u8,
        replacement: []const u8,
    }{
        .{
            .name = "reused arrow helper",
            .source =
            \\const parse = (x: number): number => x;
            \\function handler(req: Request): Response {
            \\  const a = parse(1);
            \\  const b = parse(2);
            \\  return Response.json({ a, b });
            \\}
            ,
            .kind = "canonicalize_arrow_helper",
            .replacement = "function parse(x: number): number { return x; }",
        },
        .{
            .name = "exported function const",
            .source =
            \\export const load = (id: string): Response => Response.text(id);
            \\function handler(req: Request): Response {
            \\  return load("x");
            \\}
            ,
            .kind = "canonicalize_export_function",
            .replacement = "export function load(id: string): Response { return Response.text(id); }",
        },
        .{
            .name = "avoidable let",
            .source =
            \\function handler(req: Request): Response {
            \\  let count = 1;
            \\  return Response.json({ count });
            \\}
            ,
            .kind = "canonicalize_let_const",
            .replacement = "  const count = 1;",
        },
        .{
            .name = "for-of let",
            .source =
            \\function handler(req: Request): Response {
            \\  const items = [1, 2];
            \\  for (let item of items) {
            \\    Response.json({ item });
            \\  }
            \\  return Response.json({ ok: true });
            \\}
            ,
            .kind = "canonicalize_for_of_const",
            .replacement = "  for (const item of items) {",
        },
        .{
            .name = "capability alias",
            .source =
            \\import { env } from "zttp:env";
            \\function handler(req: Request): Response {
            \\  let key = "API_KEY";
            \\  const value = env(key);
            \\  return Response.json({ value });
            \\}
            ,
            .kind = "canonicalize_capability_key_alias",
            .replacement = "  const key = \"API_KEY\";",
        },
    };

    for (cases) |case| {
        const out = try collectAndWriteJson(case.source);
        defer std.testing.allocator.free(out.json);
        defer std.testing.allocator.free(out.file);

        var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 1);
        defer parsed.deinit();
        const refactor = parsed.value.object.get("refactors").?.array.items[0].object;
        try std.testing.expectEqualStrings(case.kind, refactor.get("kind").?.string);
        try std.testing.expectEqualStrings(case.replacement, refactor.get("replacement").?.string);
        _ = case.name;
    }
}

test "unsupported typed function-valued const is skipped, not fatal" {
    const source =
        \\structural Loader = (id: string) => Response;
        \\export const load: Loader = (id: string): Response => Response.text(id);
        \\function handler(req: Request): Response {
        \\  return load("x");
        \\}
    ;
    const out = try collectAndWriteJson(source);
    defer std.testing.allocator.free(out.json);
    defer std.testing.allocator.free(out.file);

    var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 0);
    defer parsed.deinit();
}

test "generic arrow helper preview is skipped, not malformed" {
    const source =
        \\const id = <T>(x: T): T => x;
        \\function handler(req: Request): Response {
        \\  const a = id(1);
        \\  const b = id(2);
        \\  return Response.json({ a, b });
        \\}
    ;
    const out = try collectAndWriteJson(source);
    defer std.testing.allocator.free(out.json);
    defer std.testing.allocator.free(out.file);

    var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 0);
    defer parsed.deinit();
}

test "dynamic literal-prefix capability alias is not treated as static" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  let key = "API_" + req.headers["x"];
        \\  const value = env(key);
        \\  return Response.json({ value });
        \\}
    ;
    const out = try collectAndWriteJson(source);
    defer std.testing.allocator.free(out.json);
    defer std.testing.allocator.free(out.file);

    var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 1);
    defer parsed.deinit();
    const refactor = parsed.value.object.get("refactors").?.array.items[0].object;
    try std.testing.expectEqualStrings("canonicalize_let_const", refactor.get("kind").?.string);
}

test "capability alias preview stays in enclosing scope" {
    const source =
        \\import { env } from "zttp:env";
        \\function other(req: Request): Response {
        \\  let key = "API_KEY";
        \\  return Response.text(key);
        \\}
        \\function handler(req: Request): Response {
        \\  let key = req.headers["x"];
        \\  const value = env(key);
        \\  return Response.json({ value });
        \\}
    ;
    const out = try collectAndWriteJson(source);
    defer std.testing.allocator.free(out.json);
    defer std.testing.allocator.free(out.file);

    var parsed = try expectCanonicalizeEnvelope(out.json, out.file, 2);
    defer parsed.deinit();
    const refactors = parsed.value.object.get("refactors").?.array.items;
    for (refactors) |item| {
        try std.testing.expect(!std.mem.eql(u8, "canonicalize_capability_key_alias", item.object.get("kind").?.string));
    }
}

test "applyRepairs applies a replacement that spans lines" {
    // The retired line-keyed applier refused any replacement containing a
    // newline, so a rewrite that changed the shape of a statement had to go
    // through a second, separate path. One path now, and this is the case that
    // proves the restriction is gone rather than relocated.
    const source =
        \\function handler(req: Request): Response {
        \\  const n = 1;
        \\  return Response.json({ n });
        \\}
    ;
    const span = lineSpan(source, 2).?;
    const repair = Repair{
        .intent = .replace_ternary_with_if,
        .start_offset = span.start,
        .end_offset = span.end,
        .line = 2,
        .column = 3,
        .message = "",
        .replacement = "  const a = 1;\n  const n = a;",
        .original = "  const n = 1;",
    };
    const out = try applyRepairs(std.testing.allocator, source, &.{repair});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "const a = 1;\n  const n = a;") != null);
    // The lines around it are untouched, so the splice took the span and not
    // the line's neighbourhood.
    try std.testing.expect(std.mem.indexOf(u8, out, "function handler(req: Request): Response {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return Response.json({ n });") != null);
}

test "applyRepairs applies two repairs on one line when their spans are disjoint" {
    // The line-keyed applier refused this pair for a reason that was about the
    // applier and not about the program: it walked lines, so one line could
    // carry one rewrite. Two disjoint spans are two independent edits, and the
    // overlap rule is what decides them now.
    const source = "const pair = [alpha, beta];\n";
    const alpha_start = std.mem.indexOf(u8, source, "alpha").?;
    const beta_start = std.mem.indexOf(u8, source, "beta").?;
    const first = Repair{
        .intent = .replace_let_with_const,
        .start_offset = alpha_start,
        .end_offset = alpha_start + "alpha".len,
        .line = 1,
        .column = 1,
        .message = "",
        .replacement = "one",
        .original = "alpha",
    };
    const second = Repair{
        .intent = .replace_let_with_const,
        .start_offset = beta_start,
        .end_offset = beta_start + "beta".len,
        .line = 1,
        .column = 1,
        .message = "",
        .replacement = "two",
        .original = "beta",
    };
    const out = try applyRepairs(std.testing.allocator, source, &.{ first, second });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("const pair = [one, two];\n", out);

    // And the same two spans overlapping is still refused, so the pair above
    // passes because the spans are disjoint and not because the rule went away.
    const overlapping = Repair{
        .intent = .replace_let_with_const,
        .start_offset = alpha_start,
        .end_offset = beta_start + "beta".len,
        .line = 1,
        .column = 1,
        .message = "",
        .replacement = "one, two",
        .original = source[alpha_start .. beta_start + "beta".len],
    };
    try std.testing.expectError(
        error.OverlappingRepairs,
        applyRepairs(std.testing.allocator, source, &.{ first, overlapping }),
    );
}

test "applyRepairs rejects a stale snapshot on a line-derived span" {
    const source =
        \\function handler(req: Request): Response {
        \\  const count = 1;
        \\  return Response.json({ count });
        \\}
    ;
    const span = lineSpan(source, 2).?;
    const repair = Repair{
        .intent = .replace_let_with_const,
        .start_offset = span.start,
        .end_offset = span.end,
        .line = 2,
        .column = 3,
        .message = "let binding is never reassigned",
        .replacement = "  const count = 1;",
        .original = "  let count = 1;",
    };
    try std.testing.expectError(error.StaleRepair, applyRepairs(std.testing.allocator, source, &.{repair}));
}

test "applyRepairs rejects two repairs covering the same bytes" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count });
        \\}
    ;
    const span = lineSpan(source, 2).?;
    const first = Repair{
        .intent = .replace_let_with_const,
        .start_offset = span.start,
        .end_offset = span.end,
        .line = 2,
        .column = 3,
        .message = "let binding is never reassigned",
        .replacement = "  const count = 1;",
        .original = "  let count = 1;",
    };
    const second = Repair{
        .intent = .canonicalize_capability_key_alias,
        .start_offset = span.start,
        .end_offset = span.end,
        .line = 2,
        .column = 1,
        .message = "make capability key alias compiler-visible",
        .replacement = "  const count = 1;",
        .original = "  let count = 1;",
    };
    try std.testing.expectError(error.OverlappingRepairs, applyRepairs(std.testing.allocator, source, &.{ first, second }));
}

test "applyRepairs applies repairs on several lines and edit simulation stays clean" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  const items = [1, 2];
        \\  for (let item of items) {
        \\    Response.json({ item });
        \\  }
        \\  return Response.json({ count });
        \\}
    ;
    const first_span = lineSpan(source, 2).?;
    const second_span = lineSpan(source, 4).?;
    const first = Repair{
        .intent = .replace_let_with_const,
        .start_offset = first_span.start,
        .end_offset = first_span.end,
        .line = 2,
        .column = 3,
        .message = "let binding is never reassigned",
        .replacement = "  const count = 1;",
        .original = "  let count = 1;",
    };
    const second = Repair{
        .intent = .canonicalize_for_of_const,
        .start_offset = second_span.start,
        .end_offset = second_span.end,
        .line = 4,
        .column = 3,
        .message = "for-of binding uses let",
        .replacement = "  for (const item of items) {",
        .original = "  for (let item of items) {",
    };
    const proposed = try applyRepairs(std.testing.allocator, source, &.{ first, second });
    defer std.testing.allocator.free(proposed);
    try std.testing.expect(std.mem.indexOf(u8, proposed, "let ") == null);

    // Both lets are rewritten and no canonical diagnostic remains: re-collecting
    // on the multi-line rewrite yields zero refactors. (edit_simulate's
    // new_count would also count the latent ZTS500 this Spec-less handler always
    // had, which the rewrite did not introduce.)
    var after = try collectFromSource(std.testing.allocator, proposed, "handler.ts");
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after.repairs.items.len);
}

test "invalid applied replacement is caught by edit simulation" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count });
        \\}
    ;
    const bad_span = lineSpan(source, 2).?;
    const bad = Repair{
        .intent = .replace_let_with_const,
        .start_offset = bad_span.start,
        .end_offset = bad_span.end,
        .line = 2,
        .column = 3,
        .message = "let binding is never reassigned",
        .replacement = "  const = ;",
        .original = "  let count = 1;",
    };
    const proposed = try applyRepairs(std.testing.allocator, source, &.{bad});
    defer std.testing.allocator.free(proposed);

    var simulated = try edit_simulate.simulate(std.testing.allocator, .{
        .file = "handler.ts",
        .content = proposed,
        .before = source,
    });
    defer simulated.deinit(std.testing.allocator);
    try std.testing.expect(simulated.new_count > 0);
}

test "collect output can clear canonical diagnostic through edit simulation" {
    const source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a, b });
        \\}
    ;
    var preview = try collectFromSource(std.testing.allocator, source, "handler.ts");
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), preview.repairs.items.len);
    try std.testing.expectEqual(RepairIntent.replace_arrow_with_function, preview.repairs.items[0].intent);

    const proposed = try std.fmt.allocPrint(
        std.testing.allocator,
        \\{s}
        \\function handler(req: Request): Response {{
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({{ a, b }});
        \\}}
    ,
        .{preview.repairs.items[0].replacement},
    );
    defer std.testing.allocator.free(proposed);

    // Applying the refactor clears the canonical diagnostic: re-collecting on
    // the rewritten source yields no further refactor. (Asserting on the full
    // diagnostic total would be wrong: removing the masking strict error
    // unmasks a latent ZTS500 spec-discharge diagnostic this handler always
    // had, which the rewrite did not introduce.)
    var after = try collectFromSource(std.testing.allocator, proposed, "handler.ts");
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after.repairs.items.len);
}

test "collect output can clear capability alias diagnostic through edit simulation" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  let key = "API_KEY";
        \\  const value = env(key);
        \\  return Response.json({ value });
        \\}
    ;
    var preview = try collectFromSource(std.testing.allocator, source, "handler.ts");
    defer preview.deinit(std.testing.allocator);
    try std.testing.expect(preview.repairs.items.len >= 1);

    var proposed = try std.ArrayList(u8).initCapacity(std.testing.allocator, source.len + 8);
    defer proposed.deinit(std.testing.allocator);
    try proposed.appendSlice(std.testing.allocator, "import { env } from \"zttp:env\";\n");
    try proposed.appendSlice(std.testing.allocator, "function handler(req: Request): Response {\n");
    try proposed.appendSlice(std.testing.allocator, preview.repairs.items[0].replacement);
    try proposed.appendSlice(std.testing.allocator, "\n");
    try proposed.appendSlice(std.testing.allocator, "  const value = env(key);\n");
    try proposed.appendSlice(std.testing.allocator, "  return Response.json({ value });\n");
    try proposed.appendSlice(std.testing.allocator, "}\n");

    // Re-collecting on the rewritten source yields no further refactor: the
    // capability-alias canonical diagnostic is cleared by the rewrite.
    var after = try collectFromSource(std.testing.allocator, proposed.items, "handler.ts");
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after.repairs.items.len);
}

test "normalizeSource fixes avoidable let to const and is fully canonical" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(nr.iterations >= 1);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "const count = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "let count") == null);
}

test "normalizeSource records the rewrite trace" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.rewrite_trace.items.len >= 1);
    try std.testing.expectEqual(RepairIntent.replace_let_with_const, nr.rewrite_trace.items[0]);
}

test "normalizeSource rewrites `=== true` comparison and is fully canonical" {
    const source =
        \\function handler(req: Request): Response {
        \\  const ready = req.method === "GET";
        \\  if (ready === true) { return Response.text("ready"); }
        \\  return Response.text("not");
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(nr.iterations >= 1);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "if (ready)") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "=== true") == null);

    var found = false;
    for (nr.rewrite_trace.items) |intent| {
        if (intent == .drop_redundant_bool_compare) found = true;
    }
    try std.testing.expect(found);
}

test "normalizeSource rewrites `=== false` comparison to negation" {
    const source =
        \\function handler(req: Request): Response {
        \\  const ready = req.method === "GET";
        \\  if (ready === false) { return Response.text("not"); }
        \\  return Response.text("ready");
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "if (!ready)") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "=== false") == null);
}

test "redundant-bool-compare rewrite is behavior-equivalent (contract diff)" {
    // The non-canonical `before` carries a ZTS620 hard error, so it never
    // extracts a contract. Drive the rewriter to its canonical output, then
    // prove that output is behaviorally equivalent to an independently
    // hand-written reference handler that expresses the same two response
    // paths with the bare boolean. Both are canonical, so both extract a
    // contract; `diffContracts` compares the observable behavior.
    const before =
        \\function handler(req: Request): Response {
        \\  const ready = req.method === "GET";
        \\  if (ready === true) { return Response.text("ready"); }
        \\  return Response.text("not");
        \\}
    ;
    const reference =
        \\function handler(req: Request): Response {
        \\  const ready = req.method === "GET";
        \\  if (ready) { return Response.text("ready"); }
        \\  return Response.text("not");
        \\}
    ;

    var nr = try normalizeSource(std.testing.allocator, before, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);

    var lhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, nr.canonical_source, "handler.ts", null, true, null, false);
    defer lhs.deinit(std.testing.allocator);
    var rhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, reference, "handler.ts", null, true, null, false);
    defer rhs.deinit(std.testing.allocator);

    const lhs_contract = lhs.contract orelse return error.NoContractFromCanonicalOutput;
    const rhs_contract = rhs.contract orelse return error.NoContractFromReference;

    var diff = try zts.contract_diff.diffContracts(std.testing.allocator, &lhs_contract, &rhs_contract);
    defer diff.deinit(std.testing.allocator);
    try std.testing.expect(diff.behavioralVerdict().isSafeNoOp());
}

test "normalizeSource: ternary is rewritten to an expression-position match and is fully canonical" {
    // ZTS612 lands as a span-keyed rewrite: `cond ? a : b` becomes
    // `match (!!(cond)) { when true: a, default: b }`, which is valid in the
    // const-initializer position the ternary occupied. The loop converges with
    // no residual canonical-band diagnostic.
    // The vehicle is an impure arm: since spec 5.4 admitted the pure unchained
    // `?:` as idiomatic, only an effectful or chained ternary reaches the
    // rewriter at all.
    const source =
        \\function fallbackStatus(): number { return 500; }
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  const status = ok ? 200 : fallbackStatus();
        \\  return Response.json({ status });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(nr.iterations >= 1);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    // The canonical formatter lays a `match` body out one arm per line, so the
    // rewrite is asserted arm by arm rather than as the one line it used to
    // print on.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "match (!!(ok)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "when true: 200,") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "default: fallbackStatus()") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "?") == null);

    var found = false;
    for (nr.rewrite_trace.items) |intent| {
        if (intent == .replace_ternary_with_if) found = true;
    }
    try std.testing.expect(found);
}

test "normalizeSource: ternary with a relational condition parenthesizes the whole condition" {
    // Regression guard: a bare `!!cond` mis-parses as `(!!a) === b` when the
    // condition ends in a relational/equality operator, silently flipping the
    // branch selection. The condition must be parenthesized: `!!(a === b)`.
    // (Contract-diff equivalence compares surfaces, not expression semantics,
    // so this is asserted textually.)
    const source =
        \\function fallbackStatus(): number { return 500; }
        \\function handler(req: Request): Response {
        \\  const status = req.method === "GET" ? 200 : fallbackStatus();
        \\  return Response.json({ status });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "match (!!(req.method === \"GET\"))") != null);
    // The broken precedence form must never appear.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "!!req.method") == null);
}

test "a file the formatter refuses reports it, and its bytes do not move" {
    // The two verdicts `--check` and `--write` read. A refusal leaves the
    // bytes where they were, so `changed` is false, and `--check` calling that
    // canonical was the gate reporting green over files that were never laid
    // out.
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return <div>hello</div>;
        \\}
    ;
    var nr = try normalizeSource(allocator, source, "handler.tsx");
    defer nr.deinit(allocator);

    try std.testing.expect(!nr.printed);
    try std.testing.expectEqual(zts.printer.Refusal.jsx_source, nr.printer_refusal.?);
    try std.testing.expect(!nr.changed);
}

test "layout off returns the rewrite fixed point in the author's whitespace" {
    // The pi veto writes this result back as the model's own edit, so a
    // salvage that reindented the file would land a whole-file diff for one
    // rewritten token.
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\        let total = 1;
        \\        total += 2;
        \\        return Response.json({ total });
        \\}
    ;
    var nr = try normalizeSourceWithOptions(allocator, source, "handler.ts", .{ .layout = false });
    defer nr.deinit(allocator);

    try std.testing.expect(!nr.printed);
    try std.testing.expect(nr.printer_refusal == null);
    // The rewrite fired: `+=` is not canonical.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "total = total + 2;") != null);
    // The author's eight-space indent is still there.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "\n        return Response.json") != null);
}

test "layout on lays the same source out" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\        let total = 1;
        \\        total += 2;
        \\        return Response.json({ total });
        \\}
    ;
    var nr = try normalizeSource(allocator, source, "handler.ts");
    defer nr.deinit(allocator);

    try std.testing.expect(nr.printed);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "\n  return Response.json") != null);
}

test "normalizeSource is idempotent on a reused arrow helper" {
    const source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a, b });
        \\}
    ;
    var first = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, first.canonical_source, "function parse") != null);

    var second = try normalizeSource(std.testing.allocator, first.canonical_source, "handler.ts");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.canonical_source, second.canonical_source);
    // A normalized handler is a fixed point: re-normalizing applies nothing.
    try std.testing.expectEqual(@as(u32, 0), second.iterations);
}

test "normalizeSource: a ternary in an arrow body bounds the condition at `=>`" {
    // Regression: ternaryConditionStart must treat `=>` as a boundary, not sweep
    // the arrow params into the condition (which would yield an always-truthy
    // `match (!!((x) => cond))`).
    const source =
        \\function minusOne(): number { return -1; }
        \\const clamp = (x: number): number => x > 0 ? 1 : minusOne();
        \\function handler(req: Request): Response {
        \\  const v = clamp(2);
        \\  return Response.json({ v });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "match (!!(x > 0))") != null);
    // The broken form would have swept the arrow params into the condition.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "!!((x") == null);
}

test "scanOperandTokenBack refuses a member tail of a call/index chain" {
    // `obj().foo`: the `.` before `foo` is preceded by `)`, so the operand
    // cannot be bounded line-locally. Refuse rather than return the partial
    // `foo` (which would splice `!foo` after `obj().`, producing `obj().!foo`).
    const line = "  const ok = obj().foo === false;";
    const foo_end = std.mem.indexOf(u8, line, "foo").? + 3;
    try std.testing.expectEqual(@as(?usize, null), scanOperandTokenBack(line, foo_end));
    // A plain dotted chain is still accepted.
    const ok_line = "  const ok = a.b.c === true;";
    const c_end = std.mem.indexOf(u8, ok_line, "c ").? + 1;
    try std.testing.expect(scanOperandTokenBack(ok_line, c_end) != null);
}

test "templateHoistRewrite refuses when a prior statement shares the physical line" {
    // `foo(); const g = ...`: hoisting at line_start would evaluate the
    // interpolation before foo(), reordering side effects.
    const source = "  foo(); const g = `Hi ${u.up()}!`;\n";
    const bt = std.mem.indexOfScalar(u8, source, '`').?;
    try std.testing.expectError(
        error.UnsupportedRefactor,
        templateHoistRewrite(std.testing.allocator, source, 1, @intCast(bt + 1)),
    );
}

// ---------------------------------------------------------------------------
// ZTS612 ternary -> match (span-keyed)
// ---------------------------------------------------------------------------

test "applyRepairs splices a single span and validates the snapshot" {
    const source = "const x = a ? 1 : 2;\n";
    const rw = Repair{
        .intent = .replace_ternary_with_if,
        .start_offset = 10,
        .end_offset = 19,
        .replacement = try std.testing.allocator.dupe(u8, "match (!!a) { when true: 1, default: 2 }"),
        .original = try std.testing.allocator.dupe(u8, "a ? 1 : 2"),
    };
    var rws = [_]Repair{rw};
    defer for (&rws) |*r| r.deinit(std.testing.allocator);
    const out = try applyRepairs(std.testing.allocator, source, &rws);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("const x = match (!!a) { when true: 1, default: 2 };\n", out);
}

test "applyRepairs rejects a stale snapshot" {
    const source = "const x = a ? 1 : 2;\n";
    var rw = Repair{
        .intent = .replace_ternary_with_if,
        .start_offset = 10,
        .end_offset = 19,
        .replacement = try std.testing.allocator.dupe(u8, "X"),
        .original = try std.testing.allocator.dupe(u8, "b ? 1 : 2"), // wrong
    };
    defer rw.deinit(std.testing.allocator);
    var rws = [_]Repair{rw};
    try std.testing.expectError(error.StaleRepair, applyRepairs(std.testing.allocator, source, &rws));
}

test "applyRepairs rejects overlapping spans" {
    const source = "abcdefghij";
    var a = Repair{
        .intent = .replace_ternary_with_if,
        .start_offset = 0,
        .end_offset = 5,
        .replacement = try std.testing.allocator.dupe(u8, "X"),
        .original = try std.testing.allocator.dupe(u8, "abcde"),
    };
    var b = Repair{
        .intent = .replace_ternary_with_if,
        .start_offset = 3,
        .end_offset = 8,
        .replacement = try std.testing.allocator.dupe(u8, "Y"),
        .original = try std.testing.allocator.dupe(u8, "defgh"),
    };
    defer a.deinit(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    var rws = [_]Repair{ a, b };
    try std.testing.expectError(error.OverlappingRepairs, applyRepairs(std.testing.allocator, source, &rws));
}

test "lineColToOffset maps a 1-based position to a byte offset" {
    const source = "ab\ncde\nfgh";
    try std.testing.expectEqual(@as(?usize, 0), lineColToOffset(source, 1, 1));
    try std.testing.expectEqual(@as(?usize, 4), lineColToOffset(source, 2, 2)); // 'd'
    try std.testing.expectEqual(@as(?usize, 7), lineColToOffset(source, 3, 1)); // 'f'
    try std.testing.expectEqual(@as(?usize, null), lineColToOffset(source, 9, 1));
}

test "ternaryToMatchRewrite builds the canonical match form for a const initializer" {
    const source = "  const status = ok ? 200 : 500;\n";
    // `?` is at 1-based column 21 on line 1.
    var rw = try ternaryToMatchRewrite(std.testing.allocator, source, 1, 21);
    defer rw.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok ? 200 : 500", rw.original);
    try std.testing.expectEqualStrings("match (!!(ok)) { when true: 200, default: 500 }", rw.replacement);
    try std.testing.expectEqual(RepairIntent.replace_ternary_with_if, rw.intent);
}

test "ternaryToMatchRewrite handles a return-position ternary" {
    const source = "  return ok ? Response.text(\"y\") : Response.text(\"n\");\n";
    // `?` after `ok` is at column 13.
    var rw = try ternaryToMatchRewrite(std.testing.allocator, source, 1, 13);
    defer rw.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok ? Response.text(\"y\") : Response.text(\"n\")", rw.original);
    try std.testing.expectEqualStrings(
        "match (!!(ok)) { when true: Response.text(\"y\"), default: Response.text(\"n\") }",
        rw.replacement,
    );
}

test "ternaryToMatchRewrite refuses an optional chain and a nullish operator" {
    // `?.` is at column 4; `??` is at column 4 in the second source.
    const oc = "  a?.b;\n";
    try std.testing.expectError(error.UnsupportedRefactor, ternaryToMatchRewrite(std.testing.allocator, oc, 1, 4));
    const nc = "  a ?? b;\n";
    try std.testing.expectError(error.UnsupportedRefactor, ternaryToMatchRewrite(std.testing.allocator, nc, 1, 5));
}

test "normalizeSource ternary rewrite is behavior-equivalent (contract diff)" {
    // The non-canonical `before` carries a ZTS612 hard error, so it never
    // extracts a contract. Normalize it to the canonical `match` form, then
    // prove that output is behaviorally equivalent to an independently
    // hand-written reference handler that expresses the same two response
    // paths with a `match`. Both are canonical, so both extract a contract;
    // `diffContracts` compares the observable behavior.
    const before =
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  return ok ? Response.text("ready") : Response.text("not");
        \\}
    ;
    const reference =
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  return match (!!ok) { when true: Response.text("ready"), default: Response.text("not") };
        \\}
    ;

    var nr = try normalizeSource(std.testing.allocator, before, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);

    var lhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, nr.canonical_source, "handler.ts", null, true, null, false);
    defer lhs.deinit(std.testing.allocator);
    var rhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, reference, "handler.ts", null, true, null, false);
    defer rhs.deinit(std.testing.allocator);

    const lhs_contract = lhs.contract orelse return error.NoContractFromCanonicalOutput;
    const rhs_contract = rhs.contract orelse return error.NoContractFromReference;

    var diff = try zts.contract_diff.diffContracts(std.testing.allocator, &lhs_contract, &rhs_contract);
    defer diff.deinit(std.testing.allocator);
    try std.testing.expect(diff.behavioralVerdict().isSafeNoOp());
}

test "normalizeSource unchains a right-associative nested ternary and stops" {
    // `a ? x : b ? y : z` is two ternaries. Only the outer one is a defect: a
    // conditional expression may not be an arm of another (spec 5.4). Rewriting
    // it leaves the inner `b ? y : z` standing alone, at which point it is a
    // pure unchained `?:` and therefore idiomatic. The fixed point keeps it.
    const source =
        \\function handler(req: Request): Response {
        \\  const a = req.method === "GET";
        \\  const b = req.method === "POST";
        \\  const status = a ? 200 : b ? 201 : 500;
        \\  return Response.json({ status });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "match (!!(a)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "when true: 200,") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "default: b ? 201 : 500") != null);

    // Idempotence: the normalized output is a fixed point.
    var again = try normalizeSource(std.testing.allocator, nr.canonical_source, "handler.ts");
    defer again.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(nr.canonical_source, again.canonical_source);
    try std.testing.expectEqual(@as(u32, 0), again.iterations);
}

test "normalizeSource ternary rewrite preserves strings containing ? and :" {
    // The chained form is the vehicle, so the scanner has to find the outer
    // `:` past both the strings' punctuation and the inner ternary's own
    // `?`/`:`. The inner ternary survives as an idiomatic pure `?:`.
    const source =
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  const alt = req.method === "POST";
        \\  const msg = ok ? "yes? a:b" : alt ? "no:x?y" : "z";
        \\  return Response.text(msg);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "when true: \"yes? a:b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "default: alt ? \"no:x?y\" : \"z\"") != null);
}

test "normalizeSource ternary inside an object-literal value is rewritten in place" {
    const source =
        \\function fallbackStatus(): number { return 500; }
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  return Response.json({ code: ok ? 200 : fallbackStatus(), ok });
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "code: match (!!(ok)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "when true: 200,") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "default: fallbackStatus()") != null);
}

// ---------------------------------------------------------------------------
// ZTS615 complex template interpolation -> hoisted const (span-keyed)
// ---------------------------------------------------------------------------

test "templateHoistRewrite hoists a single complex interpolation" {
    const source = "  const g = `Hi ${u.up()}!`;\n";
    // The template literal opens at the backtick on column 13.
    var rw = try templateHoistRewrite(std.testing.allocator, source, 1, 13);
    defer rw.deinit(std.testing.allocator);
    try std.testing.expectEqual(RepairIntent.name_const_above_template, rw.intent);
    // The replacement hoists the call into a const above and interpolates the
    // generated name; the name is derived from the byte offset of the `${`.
    const off = std.mem.indexOf(u8, source, "${").?; // offset of `$`
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "  const __zt_{d} = u.up();\n  const g = `Hi ${{__zt_{d}}}!`;",
        .{ off, off },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, rw.replacement);
}

test "templateHoistRewrite refuses a template with only simple interpolations" {
    const source = "  const g = `Hi ${name} and ${a.b.c}`;\n";
    try std.testing.expectError(error.UnsupportedRefactor, templateHoistRewrite(std.testing.allocator, source, 1, 13));
}

test "templateHoistRewrite refuses a template inside a same-line arrow function" {
    // Hoisting above the line would move `n.toUpperCase()` outside the arrow,
    // where `n` is unbound (or a different outer binding).
    const source = "  const rows = names.map((n) => `Row ${n.toUpperCase()}`);\n";
    const bt = std.mem.indexOfScalar(u8, source, '`').?;
    try std.testing.expectError(
        error.UnsupportedRefactor,
        templateHoistRewrite(std.testing.allocator, source, 1, @intCast(bt + 1)),
    );
}

test "templateHoistRewrite refuses a template inside a same-line function body" {
    const source = "  function greet(u) { return `Hi ${u.up()}`; }\n";
    const bt = std.mem.indexOfScalar(u8, source, '`').?;
    try std.testing.expectError(
        error.UnsupportedRefactor,
        templateHoistRewrite(std.testing.allocator, source, 1, @intCast(bt + 1)),
    );
}

test "templateHoistRewrite still hoists when `function` only prefixes an identifier" {
    const source = "  const functionalGreeting = `Hi ${u.up()}!`;\n";
    const bt = std.mem.indexOfScalar(u8, source, '`').?;
    var rw = try templateHoistRewrite(std.testing.allocator, source, 1, @intCast(bt + 1));
    defer rw.deinit(std.testing.allocator);
    try std.testing.expectEqual(RepairIntent.name_const_above_template, rw.intent);
}

test "normalizeSource hoists a complex template interpolation and is fully canonical" {
    const source =
        \\function handler(req: Request): Response {
        \\  const name = req.headers["x-name"];
        \\  const greeting = `Hello, ${name.toUpperCase()}!`;
        \\  return Response.text(greeting);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, " = name.toUpperCase();") != null);
    // The template now interpolates a bare generated identifier, not a call.
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, ".toUpperCase()}") == null);

    var found = false;
    for (nr.rewrite_trace.items) |intent| {
        if (intent == .name_const_above_template) found = true;
    }
    try std.testing.expect(found);
}

test "normalizeSource hoists multiple complex interpolations in source order, idempotently" {
    const source =
        \\function handler(req: Request): Response {
        \\  const a = req.headers["a"];
        \\  const b = req.headers["b"];
        \\  const s = `${a.toUpperCase()} and ${b.toLowerCase()}`;
        \\  return Response.text(s);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);
    // Two hoisted consts, the first for `a.toUpperCase()` (earlier in source).
    const first = std.mem.indexOf(u8, nr.canonical_source, " = a.toUpperCase();") orelse return error.MissingFirstHoist;
    const second = std.mem.indexOf(u8, nr.canonical_source, " = b.toLowerCase();") orelse return error.MissingSecondHoist;
    try std.testing.expect(first < second);

    var again = try normalizeSource(std.testing.allocator, nr.canonical_source, "handler.ts");
    defer again.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(nr.canonical_source, again.canonical_source);
    try std.testing.expectEqual(@as(u32, 0), again.iterations);
}

test "normalizeSource template hoist is behavior-equivalent (contract diff)" {
    // The non-canonical `before` carries a ZTS615 hard error, so it never
    // extracts a contract. Normalize it, then prove the hoisted output is
    // behaviorally equivalent to an independently hand-written reference that
    // names the interpolation in an explicit `const`.
    const before =
        \\function handler(req: Request): Response {
        \\  const name = req.headers["x-name"];
        \\  const greeting = `Hello, ${name.toUpperCase()}!`;
        \\  return Response.text(greeting);
        \\}
    ;
    const reference =
        \\function handler(req: Request): Response {
        \\  const name = req.headers["x-name"];
        \\  const upper = name.toUpperCase();
        \\  const greeting = `Hello, ${upper}!`;
        \\  return Response.text(greeting);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, before, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.fully_canonical);

    var lhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, nr.canonical_source, "handler.ts", null, true, null, false);
    defer lhs.deinit(std.testing.allocator);
    var rhs = try precompile.runCheckOnlyFromSource(std.testing.allocator, reference, "handler.ts", null, true, null, false);
    defer rhs.deinit(std.testing.allocator);

    const lhs_contract = lhs.contract orelse return error.NoContractFromCanonicalOutput;
    const rhs_contract = rhs.contract orelse return error.NoContractFromReference;

    var diff = try zts.contract_diff.diffContracts(std.testing.allocator, &lhs_contract, &rhs_contract);
    defer diff.deinit(std.testing.allocator);
    try std.testing.expect(diff.behavioralVerdict().isSafeNoOp());
}

test "normalizeSource refuses to hoist a multi-line template (left as residual)" {
    // The line-local hoist deliberately only handles single-line statements; a
    // template that wraps across lines is refused and stays a flagged ZTS615
    // hard error rather than risk an unsound splice.
    // `req.url`, not an invented field: with `Request` typed, a name the
    // record does not carry makes this fixture prove a different thing than
    // the multi-line hoist it is here to pin.
    const source = "function handler(req: Request): Response {\n  const g = `a ${req.url.toUpperCase()}\nb`;\n  return Response.text(g);\n}\n";
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(!nr.fully_canonical);
    try std.testing.expect(nr.residual >= 1);
}

test "normalizeSource refuses to hoist inside a single-line function (left as residual)" {
    // The interpolation references the function's parameter `n`; a hoisted
    // const above the line would sit outside the function where `n` is
    // unbound (or a different outer binding).
    const source =
        \\function greet(n: string): string { return `Row ${n.toUpperCase()}`; }
        \\function handler(req: Request): Response {
        \\  return Response.text(greet("a"));
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(!nr.fully_canonical);
    try std.testing.expect(nr.residual >= 1);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "`Row ${n.toUpperCase()}`") != null);
}

test "normalizeSource reports dynamic computed access as residual diagnostic" {
    const source =
        \\function handler(req: Request): Response {
        \\  const key = req.headers["x-key"];
        \\  const value = req.headers[key];
        \\  return Response.text(value);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(!nr.fully_canonical);
    try std.testing.expect(nr.residual >= 1);

    var found = false;
    for (nr.residual_diagnostics.items) |diag| {
        if (std.mem.eql(u8, diag.code, "ZTS605")) {
            found = true;
            try std.testing.expect(diag.repair_intent == null);
        }
    }
    try std.testing.expect(found);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    try writeNormalizeJson(&aw.writer, "handler.ts", &nr, false);
    buf = aw.toArrayList();
    const json = try buf.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const residual = (parsed.value.object.get("residualDiagnostics") orelse return error.MissingResidualDiagnostics).array;
    try std.testing.expect(residual.items.len >= 1);
    try std.testing.expectEqualStrings("ZTS605", residual.items[0].object.get("code").?.string);
}

test "normalizeSource flattens a simple nested object destructure" {
    const source =
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(name);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "const { user } = payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "const { name } = user;") != null);

    var found = false;
    for (nr.rewrite_trace.items) |intent| {
        if (intent == .flatten_destructure) found = true;
    }
    try std.testing.expect(found);
}

test "normalizeSource refuses nested destructure flattening that would shadow a live binding" {
    const source =
        \\const user = "global";
        \\function handler(req: Request): Response {
        \\  const payload = { user: { name: "ada" } };
        \\  const {user: {name}} = payload;
        \\  return Response.text(user + name);
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(!nr.fully_canonical);
    try std.testing.expect(nr.residual >= 1);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "const { user: { name } } = payload;") != null);
}

// One non-canonical source per rewrite the normalizer can apply. Spec 4.2.1
// requires a second `normalize` of canonical source to produce identical bytes,
// and rows compose, so the failure mode that matters is a rewrite that
// oscillates or re-fires on its own output. This table is the day-one guard for
// that: `scripts/check-normalize-idempotent.sh` runs the same property over
// `examples/`, but only four example files trigger any rewrite at all, so the
// corpus alone would leave every row untested.
//
// Add a row here whenever a rewrite is added. `iterations >= 1` on the first
// pass is asserted so a source that silently stops triggering its rewrite fails
// loudly instead of passing as a vacuous fixed point.
const NormalizeCase = struct { name: []const u8, source: []const u8 };

const normalize_cases = [_]NormalizeCase{
    .{
        .name = "let -> const",
        .source =
        \\function handler(req: Request): Response {
        \\  let n = 1;
        \\  return Response.json({ n });
        \\}
        ,
    },
    .{
        .name = "for-of let -> const",
        .source =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (let item of items) {
        \\    Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
        ,
    },
    .{
        .name = "reused arrow helper -> named function",
        .source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a, b });
        \\}
        ,
    },
    .{
        .name = "compound assignment -> explicit",
        .source =
        \\function handler(req: Request): Response {
        \\  let n = 0;
        \\  n += 1;
        \\  return Response.json({ n });
        \\}
        ,
    },
    .{
        .name = "redundant bool compare",
        .source =
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  if (ok === true) {
        \\    return Response.text("yes");
        \\  }
        \\  return Response.text("no");
        \\}
        ,
    },
    .{
        .name = "impure ternary -> match",
        .source =
        \\function fallbackStatus(): number { return 500; }
        \\function handler(req: Request): Response {
        \\  const ok = req.method === "GET";
        \\  const status = ok ? 200 : fallbackStatus();
        \\  return Response.json({ status });
        \\}
        ,
    },
    .{
        .name = "chained ternary -> match",
        .source =
        \\function handler(req: Request): Response {
        \\  const a = req.method === "GET";
        \\  const b = req.method === "POST";
        \\  const status = a ? 200 : b ? 201 : 500;
        \\  return Response.json({ status });
        \\}
        ,
    },
    .{
        .name = "complex template interpolation -> hoisted const",
        .source =
        \\function handler(req: Request): Response {
        \\  const a = req.headers["a"];
        \\  const s = `${a.toUpperCase()}!`;
        \\  return Response.text(s);
        \\}
        ,
    },
    .{
        .name = "unused entries index alias",
        .source =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
        ,
    },
};

test "normalize is byte-idempotent over every rewrite" {
    for (normalize_cases) |case| {
        var once = try normalizeSource(std.testing.allocator, case.source, "handler.ts");
        defer once.deinit(std.testing.allocator);

        if (once.iterations == 0) {
            std.debug.print("\ncase '{s}' triggered no rewrite\n", .{case.name});
            return error.CaseNoLongerTriggersRewrite;
        }

        var twice = try normalizeSource(std.testing.allocator, once.canonical_source, "handler.ts");
        defer twice.deinit(std.testing.allocator);

        if (!std.mem.eql(u8, once.canonical_source, twice.canonical_source)) {
            std.debug.print(
                "\ncase '{s}' is not idempotent\n--- once ---\n{s}\n--- twice ---\n{s}\n",
                .{ case.name, once.canonical_source, twice.canonical_source },
            );
            return error.NormalizeNotIdempotent;
        }
        // A fixed point applies nothing on the second pass, which is stricter
        // than byte-equality alone: a rewrite that undid itself would produce
        // equal bytes with a non-zero iteration count.
        if (twice.iterations != 0) {
            std.debug.print("\ncase '{s}' still rewrites on pass 2\n", .{case.name});
            return error.NormalizeNotAtFixedPoint;
        }
    }
}

test "normalizeSource drops an unused entries index alias" {
    const source =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    Response.text(item);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "for (const item of items) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "const [_i, item]") == null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, ".entries()") == null);

    var found = false;
    for (nr.rewrite_trace.items) |intent| {
        if (intent == .drop_unused_index_alias) found = true;
    }
    try std.testing.expect(found);
}

test "normalizeSource refuses entries alias rewrite when pair binding is still read" {
    const source =
        \\function handler(req: Request): Response {
        \\  const items = ["a", "b"];
        \\  for (const pair of items.entries()) {
        \\    const [_i, item] = pair;
        \\    Response.text(pair[1]);
        \\  }
        \\  return Response.text("done");
        \\}
    ;
    var nr = try normalizeSource(std.testing.allocator, source, "handler.ts");
    defer nr.deinit(std.testing.allocator);
    try std.testing.expect(nr.converged);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "for (const pair of items.entries())") != null);
    try std.testing.expect(std.mem.indexOf(u8, nr.canonical_source, "Response.text(pair[1]);") != null);

    // The row still reports and still declines to rewrite, and the file is
    // still canonical: ZTS619 is spec 4.2.1's `element iteration` row, so it
    // reports at advisory severity and does not deny Canonical Normal Form.
    // This assertion used to read `!fully_canonical` and `residual >= 1`, which
    // were standing in for "a diagnostic remains" - so it is made to say that
    // instead of a verdict the advisory no longer moves.
    try std.testing.expect(nr.fully_canonical);
    try std.testing.expectEqual(@as(u32, 0), nr.residual);
    var saw_advisory = false;
    for (nr.residual_diagnostics.items) |diag| {
        if (std.mem.eql(u8, diag.code, "ZTS619")) {
            try std.testing.expectEqualStrings("advisory", diag.severity);
            saw_advisory = true;
        }
    }
    try std.testing.expect(saw_advisory);
}

test "compoundAssignReplacement parenthesizes a compound rhs to preserve precedence" {
    const allocator = std.testing.allocator;

    // A single atom needs no parens (and must not gain any, to match the
    // canonical form and the existing repair tests).
    {
        const out = try compoundAssignReplacement(allocator, "  n += 1;");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("  n = n + 1;", out);
    }
    {
        const out = try compoundAssignReplacement(allocator, "  state.total *= factor;");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("  state.total = state.total * factor;", out);
    }

    // A compound rhs MUST be parenthesized: without parens this reassociates to
    // (total - fee) + tax and silently changes the value.
    {
        const out = try compoundAssignReplacement(allocator, "  total -= fee + tax;");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("  total = total - (fee + tax);", out);
    }
    {
        const out = try compoundAssignReplacement(allocator, "  x /= a * b;");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("  x = x / (a * b);", out);
    }
    // No trailing semicolon: still parenthesized.
    {
        const out = try compoundAssignReplacement(allocator, "  x -= a - b");
        defer allocator.free(out);
        try std.testing.expectEqualStrings("  x = x - (a - b)", out);
    }
    // A trailing comment defeats the textual split; refuse rather than mangle.
    try std.testing.expectError(error.UnsupportedRefactor, compoundAssignReplacement(allocator, "  n += a + b; // note"));
}

test "delimitersBalanced detects expressions that do not finish on the line" {
    try std.testing.expect(delimitersBalanced("makeUser(1, 2)"));
    try std.testing.expect(delimitersBalanced("payload"));
    try std.testing.expect(delimitersBalanced("{ a: 1 };"));
    // A delimiter inside a string literal does not count toward the balance.
    try std.testing.expect(delimitersBalanced("f(\")\")"));
    // Unbalanced openers (a multiline RHS) and unterminated strings are refused.
    try std.testing.expect(!delimitersBalanced("makeUser("));
    try std.testing.expect(!delimitersBalanced("{"));
    try std.testing.expect(!delimitersBalanced("f(\"unterminated"));
}

test "nestedDestructureRewrite refuses a multiline right-hand side" {
    const source =
        \\function handler(req: Request): Response {
        \\  const {user: {name}} = makeUser(
        \\    1,
        \\  );
        \\  return Response.json({ name });
        \\}
    ;
    try std.testing.expectError(
        error.UnsupportedRefactor,
        nestedDestructureRewrite(std.testing.allocator, source, 2, 3),
    );
}

test "nestedDestructureRewrite flattens a single-line nested pattern" {
    const source =
        \\function handler(req: Request): Response {
        \\  const {user: {name}} = makeUser(1);
        \\  return Response.json({ name });
        \\}
    ;
    var rw = try nestedDestructureRewrite(std.testing.allocator, source, 2, 3);
    defer rw.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, rw.replacement, "const {user} = makeUser(1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rw.replacement, "const {name} = user;") != null);
}

// ---------------------------------------------------------------------------
// Confluence: critical pairs over the rewrite rows
// ---------------------------------------------------------------------------

/// The rewrite rows the normalizer can emit. Kept beside the confluence check
/// so a new row that nobody pairs against is visible as a gap rather than
/// silently untested.
pub const rewrite_row_intents = [_]RepairIntent{
    .replace_arrow_with_function,
    .canonicalize_capability_key_alias,
    .replace_compound_assign_with_explicit,
    .replace_export_arrow_with_function,
    .canonicalize_for_of_const,
    .replace_let_with_const,
    .drop_redundant_bool_compare,
    .flatten_destructure,
    .drop_unused_index_alias,
};

/// Apply only the refactors of one row kind, to a fixed point.
///
/// The normalizer's own loop applies every enabled row per pass. Restricting to
/// one row is what makes a critical pair observable: it lets the harness drive
/// A-then-B and B-then-A over the same input and compare where they land.
fn normalizeOnlyIntent(
    allocator: std.mem.Allocator,
    source: []const u8,
    virtual_path: []const u8,
    intent: RepairIntent,
) ![]u8 {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);

    var pass: u32 = 0;
    while (pass < max_normalize_iterations) : (pass += 1) {
        // Both builders, not just the line-keyed one. `collectFromSource` runs
        // `buildLineRepairs` alone, so driving the pairs off it would leave
        // every span-keyed row - `flatten_destructure` and
        // `drop_unused_index_alias`, the two multi-line ones - selecting
        // nothing, joining unchanged text against unchanged text, and reporting
        // a pass over a pair it never formed.
        var check = precompile.runCheckOnlyFromSource(allocator, current, virtual_path, null, true, null, false) catch break;
        defer check.deinit(allocator);
        var result = Result{ .file = virtual_path };
        defer result.deinit(allocator);
        try buildLineRepairs(allocator, current, check.json_diagnostics.items, &result);
        try buildSpanRepairs(allocator, current, check.json_diagnostics.items, &result);

        var selected: std.ArrayListUnmanaged(Repair) = .empty;
        defer selected.deinit(allocator);
        var seen_lines: std.ArrayListUnmanaged(u32) = .empty;
        defer seen_lines.deinit(allocator);
        for (result.repairs.items) |r| {
            if (r.intent != intent) continue;
            // `applyRefactors` refuses two refactors on one line; take the
            // first and let the next pass pick up the rest.
            if (std.mem.indexOfScalar(u32, seen_lines.items, r.line) != null) continue;
            try seen_lines.append(allocator, r.line);
            try selected.append(allocator, r);
        }
        if (selected.items.len == 0) break;

        const next = applyRepairs(allocator, current, selected.items) catch break;
        allocator.free(current);
        current = next;
    }
    return current;
}

/// Row pairs that are known not to join, with the reason.
///
/// Empty, which is the state D3 requires: it calls a non-joining pair a build
/// failure, and the harness below fails on any pair not listed here. The list
/// exists as the interim step the roadmap allows - record a failure as a
/// fixture when closing it needs a rule change rather than a normalizer fix -
/// and its one entry has been closed.
///
/// That entry was `canonicalize_let_const` against
/// `canonicalize_redundant_bool_compare`: rewriting the binding to `const`
/// first disabled the comparison row, so one program had two canonical forms.
/// The cause was a type guard comparing against `idx_boolean` by identity while
/// a `const` binding keeps its literal type; `checkRedundantBoolCompare` now
/// widens first.
///
/// An entry that starts joining also fails the test, so the list can only
/// shrink.
const known_non_joining = [_]struct {
    a: RepairIntent,
    b: RepairIntent,
    why: []const u8,
}{};

fn isKnownNonJoining(a: RepairIntent, b: RepairIntent) bool {
    for (known_non_joining) |pair| {
        if (pair.a == a and pair.b == b) return true;
        if (pair.a == b and pair.b == a) return true;
    }
    return false;
}

test "rewrite rows join in either order" {
    const allocator = std.testing.allocator;

    // Each fixture enables more than one row, which is what makes it a
    // critical pair rather than two independent rewrites. Sources are inline
    // rather than drawn from examples/: the obligation is over the rows, and a
    // corpus file that happens not to trigger a pair proves nothing about it.
    const fixtures = [_]struct { name: []const u8, source: []const u8 }{
        .{
            .name = "let-const beside a compound assign",
            .source =
            \\function handler(req: Request): Response {
            \\  let total = 1;
            \\  total += 2;
            \\  let label = "x";
            \\  return Response.text(label + total);
            \\}
            \\
            ,
        },
        .{
            .name = "let-const beside a redundant bool compare",
            .source =
            \\function handler(req: Request): Response {
            \\  let ready = true;
            \\  if (ready === true) { return Response.text("a"); }
            \\  return Response.text("b");
            \\}
            \\
            ,
        },
        .{
            .name = "for-of const beside a let-const",
            .source =
            \\function handler(req: Request): Response {
            \\  let out = "";
            \\  for (let item of ["a", "b"]) { out = out + item; }
            \\  return Response.text(out);
            \\}
            \\
            ,
        },
        .{
            .name = "nested destructure beside a let-const",
            .source =
            \\function handler(req: Request): Response {
            \\  let payload = { data: { name: "ada" } };
            \\  const {data: {name}} = payload;
            \\  return Response.text(name);
            \\}
            \\
            ,
        },
        .{
            .name = "unused index alias beside a let-const",
            .source =
            \\function handler(req: Request): Response {
            \\  let items = ["a", "b"];
            \\  let out = "";
            \\  for (const pair of items.entries()) {
            \\    const [_i, item] = pair;
            \\    out = out + item;
            \\  }
            \\  return Response.text(out);
            \\}
            \\
            ,
        },
        .{
            .name = "arrow to function beside a let-const",
            .source =
            \\const parse = (x: number): number => x;
            \\function handler(req: Request): Response {
            \\  let total = 0;
            \\  const a = parse(1);
            \\  const b = parse(2);
            \\  return Response.json({ total, a, b });
            \\}
            \\
            ,
        },
        .{
            .name = "export arrow to function beside a let-const",
            .source =
            \\export const load = (id: string): Response => Response.text(id);
            \\function handler(req: Request): Response {
            \\  let id = "x";
            \\  return load(id);
            \\}
            \\
            ,
        },
        .{
            .name = "capability key alias beside a redundant bool compare",
            .source =
            \\import { env } from "zttp:env";
            \\function handler(req: Request): Response {
            \\  let key = "API_KEY";
            \\  const ready = env(key) !== "";
            \\  if (ready === true) { return Response.text("a"); }
            \\  return Response.text("b");
            \\}
            \\
            ,
        },
    };

    // The floor, asserted before anything the pair loop reports is believed. A
    // row that fires on no fixture is paired over unchanged text against
    // unchanged text: every such pair joins trivially and `non_joining` stays
    // 0, so the count reads as coverage of rows the harness never drove. This
    // is the check that catches it - delete a fixture and the row it carries
    // fails here rather than passing silently.
    for (rewrite_row_intents) |intent| {
        var fired = false;
        for (fixtures) |fixture| {
            const only = try normalizeOnlyIntent(allocator, fixture.source, "conf.ts", intent);
            defer allocator.free(only);
            if (!std.mem.eql(u8, only, fixture.source)) {
                fired = true;
                break;
            }
        }
        if (!fired) {
            std.debug.print("[confluence] no fixture drives {s}\n", .{@tagName(intent)});
            return error.TestFailed;
        }
    }

    var non_joining: usize = 0;
    var matched_known: usize = 0;
    for (fixtures) |fixture| {
        for (rewrite_row_intents, 0..) |a, i| {
            for (rewrite_row_intents[i + 1 ..]) |b| {
                const ab_first = try normalizeOnlyIntent(allocator, fixture.source, "conf.ts", a);
                defer allocator.free(ab_first);
                const ab = try normalizeOnlyIntent(allocator, ab_first, "conf.ts", b);
                defer allocator.free(ab);

                const ba_first = try normalizeOnlyIntent(allocator, fixture.source, "conf.ts", b);
                defer allocator.free(ba_first);
                const ba = try normalizeOnlyIntent(allocator, ba_first, "conf.ts", a);
                defer allocator.free(ba);

                if (!std.mem.eql(u8, ab, ba)) {
                    if (isKnownNonJoining(a, b)) {
                        matched_known += 1;
                        continue;
                    }
                    non_joining += 1;
                    std.debug.print(
                        "[confluence] {s}: {s} then {s} does not join {s} then {s}\n",
                        .{ fixture.name, @tagName(a), @tagName(b), @tagName(b), @tagName(a) },
                    );
                }
            }
        }
    }

    // Reported as a count rather than an assertion on the first mismatch, so a
    // run names every unrecorded non-joining pair at once instead of stopping
    // at the first.
    try std.testing.expectEqual(@as(usize, 0), non_joining);

    // Ratchets the other way too: a recorded pair that starts joining means
    // the entry is stale and should be deleted, the same rule the module
    // boundary and proof-swallow allowlists follow.
    try std.testing.expect(matched_known >= known_non_joining.len);
}
