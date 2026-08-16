//! Shared deterministic application for compiler-native repair intents.
//!
//! Two dispatches, split by what the rewrite needs to see.
//!
//! `applyIntent` is source-only and line-local. It covers four canonicalize
//! refactors (`replace_let_with_const`, `canonicalize_for_of_const`,
//! `replace_arrow_with_function`, `replace_export_arrow_with_function`) plus
//! the two insertion intents and the two span-local rewrites.
//!
//! `applyStatementIntent` covers the two whose construct spans more than the
//! line it is reported on (`replace_chained_ternary_with_match`). That needs a fresh analysis pass to derive the
//! construct's byte span, so they take a path as well as source and run through
//! `canonicalize.applyStatementIntent`. They are a separate entry point rather
//! than a branch inside `applyIntent` because `applyIntent`'s contract - pure,
//! source in and source out, no compiler run - is what several callers rely on.
//!
//! `canonicalize_capability_key_alias` is in neither: it needs cross-line scope
//! analysis, so the AST rewrite tool runs it through `canonicalize.collect`
//! directly.

const std = @import("std");
const canonicalize = @import("zts_cli").canonicalize;

pub const Intent = struct {
    plan_id: []const u8,
    intent_kind: []const u8,
    line: u32,
    template: []const u8,
};

/// Recognised intent kinds. Kept in sync with `RepairIntent` in
/// `packages/zts/src/repair_intent.zig`: the compiler emits the typed
/// enum, this enum is what the apply pipeline actually executes.
/// `canonicalize_capability_key_alias` is intentionally absent — that
/// refactor requires file-level scope analysis the AST tool runs through
/// `canonicalize.collect` rather than through this source-only dispatch.
pub const RepairKind = enum {
    insert_guard_before_line,
    add_trailing_return,
    replace_let_with_const,
    canonicalize_for_of_const,
    replace_arrow_with_function,
    replace_export_arrow_with_function,
    replace_compound_assign_with_explicit,
    drop_redundant_bool_compare,

    pub fn fromString(s: []const u8) ?RepairKind {
        return std.meta.stringToEnum(RepairKind, s);
    }
};

/// The intents whose construct spans more than the line the diagnostic reports,
/// served by `applyStatementIntent`. Disjoint from `RepairKind` by construction:
/// an intent belongs to exactly one apply path, and a caller that guesses wrong
/// gets `UnsupportedRepairIntent` rather than a rewrite from the wrong family.
pub const StatementKind = enum {
    replace_chained_ternary_with_match,

    pub fn fromString(s: []const u8) ?StatementKind {
        return std.meta.stringToEnum(StatementKind, s);
    }

    fn asIntent(self: StatementKind) canonicalize.RepairIntent {
        return switch (self) {
            .replace_chained_ternary_with_match => .replace_chained_ternary_with_match,
        };
    }
};

/// Realize one span-keyed intent at `line` against `source`, analyzed as
/// `path`. The path is what the analysis attributes diagnostics to and what
/// selects TypeScript stripping, so it must be the file the source came from
/// (or the virtual path a caller is simulating it under), not a placeholder.
pub fn applyStatementIntent(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    intent_kind: []const u8,
    line: u32,
) ![]u8 {
    const kind = StatementKind.fromString(intent_kind) orelse return error.UnsupportedRepairIntent;
    return canonicalize.applyStatementIntent(allocator, source, path, kind.asIntent(), line);
}

pub fn applyIntent(
    allocator: std.mem.Allocator,
    source: []const u8,
    intent: Intent,
) ![]u8 {
    const kind = RepairKind.fromString(intent.intent_kind) orelse
        return error.UnsupportedRepairIntent;
    return switch (kind) {
        .insert_guard_before_line => insertTemplateBeforeLine(allocator, source, intent.line, intent.template),
        .add_trailing_return => insertTemplateBeforeLastClosingBrace(allocator, source, intent.template),
        .replace_let_with_const, .canonicalize_for_of_const => applyAvoidableLet(allocator, source, intent.line),
        .replace_arrow_with_function, .replace_export_arrow_with_function => applyCanonicalFunction(allocator, source, intent.line),
        .replace_compound_assign_with_explicit => applyCompoundAssign(allocator, source, intent.line),
        .drop_redundant_bool_compare => applyRedundantBoolCompare(allocator, source, intent.line),
    };
}

/// `x === true` -> `x`, `x === false` -> `!x`, and the two `!==` mirrors.
///
/// `Intent` carries no column, so the comparison is located by scanning the
/// line. The scan refuses unless exactly one candidate operator is present:
/// with two, there is no way to tell which one the diagnostic meant, and
/// rewriting the wrong one would silently change a different expression.
/// `redundantBoolCompareReplacement` then applies its own conservative rules
/// on top - it only rewrites when the value operand is a simple lvalue.
fn applyRedundantBoolCompare(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
) ![]u8 {
    const target = canonicalize.sourceLine(source, line) orelse return error.InvalidRepairLine;

    var found_col: ?u32 = null;
    var found_positive = false;
    var i: usize = 0;
    while (i + 3 <= target.len) : (i += 1) {
        const op = target[i .. i + 3];
        const is_eq = std.mem.eql(u8, op, "===");
        if (!is_eq and !std.mem.eql(u8, op, "!==")) continue;
        const polarity = boolComparePolarity(target, i, is_eq) orelse continue;
        // A second candidate on the same line makes the target ambiguous.
        if (found_col != null) return error.UnsupportedRepairIntent;
        found_col = @intCast(i + 1);
        found_positive = polarity;
    }

    const column = found_col orelse return error.UnsupportedRepairIntent;
    const replacement = canonicalize.redundantBoolCompareReplacement(
        allocator,
        target,
        column,
        found_positive,
    ) catch |e| switch (e) {
        error.UnsupportedRefactor => return error.UnsupportedRepairIntent,
        else => return e,
    };
    defer allocator.free(replacement);
    return replaceLine(allocator, source, line, replacement);
}

/// True when the comparison at `op_start` has a boolean literal on exactly one
/// side, returning the polarity the rewrite needs: `x === true` and
/// `x !== false` both mean the bare value, the other two mean its negation.
fn boolComparePolarity(line: []const u8, op_start: usize, is_eq: bool) ?bool {
    const left = std.mem.trimEnd(u8, line[0..op_start], " \t");
    const right = std.mem.trimStart(u8, line[op_start + 3 ..], " \t");

    const left_true = std.mem.endsWith(u8, left, "true");
    const left_false = std.mem.endsWith(u8, left, "false");
    const right_true = std.mem.startsWith(u8, right, "true");
    const right_false = std.mem.startsWith(u8, right, "false");

    const left_lit = left_true or left_false;
    const right_lit = right_true or right_false;
    // The checker's invariant: exactly one side is the literal.
    if (left_lit == right_lit) return null;

    const literal_is_true = if (left_lit) left_true else right_true;
    return if (is_eq) literal_is_true else !literal_is_true;
}

fn applyCompoundAssign(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
) ![]u8 {
    const target = canonicalize.sourceLine(source, line) orelse return error.InvalidRepairLine;
    const replacement = canonicalize.compoundAssignReplacement(allocator, target) catch |e| switch (e) {
        error.UnsupportedRefactor => return error.UnsupportedRepairIntent,
        else => return e,
    };
    defer allocator.free(replacement);
    return replaceLine(allocator, source, line, replacement);
}

fn applyAvoidableLet(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
) ![]u8 {
    const target = canonicalize.sourceLine(source, line) orelse return error.InvalidRepairLine;
    const replacement = canonicalize.avoidableLetReplacement(allocator, target) catch |e| switch (e) {
        error.UnsupportedRefactor => return error.UnsupportedRepairIntent,
        else => return e,
    };
    defer allocator.free(replacement);
    return replaceLine(allocator, source, line, replacement);
}

fn applyCanonicalFunction(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
) ![]u8 {
    const target = canonicalize.sourceLine(source, line) orelse return error.InvalidRepairLine;
    const indent = leadingWhitespace(target);
    const inner = canonicalize.canonicalFunctionReplacement(allocator, target) catch |e| switch (e) {
        error.UnsupportedRefactor => return error.UnsupportedRepairIntent,
        else => return e,
    };
    defer allocator.free(inner);
    const replacement = try std.fmt.allocPrint(allocator, "{s}{s}", .{ indent, inner });
    defer allocator.free(replacement);
    return replaceLine(allocator, source, line, replacement);
}

fn replaceLine(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    replacement: []const u8,
) ![]u8 {
    const offset = lineStartOffset(source, line) orelse return error.InvalidRepairLine;
    const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, source[0..offset]);
    try out.appendSlice(allocator, replacement);
    try out.appendSlice(allocator, source[line_end..]);
    return try out.toOwnedSlice(allocator);
}

pub fn pathEscapesWorkspace(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    var parts = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn insertTemplateBeforeLine(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32,
    template: []const u8,
) ![]u8 {
    const offset = lineStartOffset(source, line) orelse return error.InvalidRepairLine;
    const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    const indent = leadingWhitespace(source[offset..line_end]);
    return spliceLine(allocator, source, offset, indent, template);
}

fn insertTemplateBeforeLastClosingBrace(
    allocator: std.mem.Allocator,
    source: []const u8,
    template: []const u8,
) ![]u8 {
    var scan = source.len;
    while (scan > 0) {
        scan -= 1;
        if (source[scan] != '}') continue;
        const line_start = lineStartBeforeOffset(source, scan);
        const indent = leadingWhitespace(source[line_start..scan]);
        const inner_indent = try std.fmt.allocPrint(allocator, "{s}  ", .{indent});
        defer allocator.free(inner_indent);
        return spliceLine(allocator, source, line_start, inner_indent, template);
    }
    return error.InvalidRepairLine;
}

fn spliceLine(
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
    indent: []const u8,
    template: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, source[0..offset]);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, template);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, source[offset..]);
    return try out.toOwnedSlice(allocator);
}

fn lineStartOffset(source: []const u8, line: u32) ?usize {
    if (line == 0) return null;
    if (line == 1) return 0;
    var current: u32 = 1;
    for (source, 0..) |ch, i| {
        if (ch != '\n') continue;
        current += 1;
        if (current == line) return i + 1;
    }
    return null;
}

fn lineStartBeforeOffset(source: []const u8, offset: usize) usize {
    var i = offset;
    while (i > 0) {
        if (source[i - 1] == '\n') return i;
        i -= 1;
    }
    return 0;
}

fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

const testing = std.testing;

test "insert guard intent preserves target indentation" {
    const source =
        \\function handler(req: Request): Response {
        \\  const data = auth.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_001",
        .intent_kind = "insert_guard_before_line",
        .line = 2,
        .template = "if (!auth.ok) return Response.json({ error: auth.error }, { status: 400 });",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  if (!auth.ok)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  const data") != null);
}

test "add trailing return intent inserts inside the outer scope" {
    const source =
        \\function handler(req: Request): Response {
        \\  const data = auth.value;
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_002",
        .intent_kind = "add_trailing_return",
        .line = 3,
        .template = "return Response.json({ data: data });",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  return Response.json") != null);
    const return_idx = std.mem.indexOf(u8, out, "return Response.json").?;
    const brace_idx = std.mem.lastIndexOfScalar(u8, out, '}').?;
    try testing.expect(return_idx < brace_idx);
}

test "replace_let_with_const intent rewrites a local let line" {
    const source =
        \\function handler(req: Request): Response {
        \\  let count = 1;
        \\  return Response.json({ count: count });
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_g1",
        .intent_kind = "replace_let_with_const",
        .line = 2,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  const count = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "let ") == null);
}

test "replace_compound_assign_with_explicit rewrites a compound assignment" {
    const source =
        \\function handler(req: Request): Response {
        \\  let n = 0;
        \\  n += 1;
        \\  return Response.json({ n: n });
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_ca",
        .intent_kind = "replace_compound_assign_with_explicit",
        .line = 3,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  n = n + 1;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+=") == null);
}

test "replace_compound_assign_with_explicit expands a dotted-identifier target" {
    const source =
        \\function handler(req: Request): Response {
        \\  state.total *= factor;
        \\  return Response.json({});
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_ca_dot",
        .intent_kind = "replace_compound_assign_with_explicit",
        .line = 2,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  state.total = state.total * factor;") != null);
}

test "replace_compound_assign_with_explicit refuses a call-base target" {
    // `f().x += 1` would re-evaluate `f()`; the transform must bail so the
    // agent falls back to a manual edit rather than changing behavior.
    const source =
        \\function handler(req: Request): Response {
        \\  obj.compute().total *= 2;
        \\  return Response.json({});
        \\}
    ;
    try testing.expectError(error.UnsupportedRepairIntent, applyIntent(testing.allocator, source, .{
        .plan_id = "rp_ca2",
        .intent_kind = "replace_compound_assign_with_explicit",
        .line = 2,
        .template = "",
    }));
}

test "replace_compound_assign_with_explicit refuses an indexed target" {
    const source =
        \\function handler(req: Request): Response {
        \\  totals[i] += 1;
        \\  return Response.json({});
        \\}
    ;
    try testing.expectError(error.UnsupportedRepairIntent, applyIntent(testing.allocator, source, .{
        .plan_id = "rp_ca3",
        .intent_kind = "replace_compound_assign_with_explicit",
        .line = 2,
        .template = "",
    }));
}

test "canonicalize_for_of_const intent rewrites a for-of let binding" {
    const source =
        \\function handler(req: Request): Response {
        \\  const items = [1, 2];
        \\  for (let item of items) {
        \\    Response.json({ item: item });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_g2",
        .intent_kind = "canonicalize_for_of_const",
        .line = 3,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  for (const item of items)") != null);
}

test "replace_arrow_with_function intent rewrites an arrow helper" {
    const source =
        \\const parse = (x: number): number => x;
        \\function handler(req: Request): Response {
        \\  return Response.json({ a: parse(1) });
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_g3",
        .intent_kind = "replace_arrow_with_function",
        .line = 1,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "function parse(x: number): number { return x; }") != null);
}

test "replace_export_arrow_with_function rewrites an exported arrow helper" {
    const source =
        \\export const load = (id: string): Response => Response.text(id);
        \\function handler(req: Request): Response {
        \\  return load("x");
        \\}
    ;
    const out = try applyIntent(testing.allocator, source, .{
        .plan_id = "rp_g4",
        .intent_kind = "replace_export_arrow_with_function",
        .line = 1,
        .template = "",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "export function load(id: string): Response { return Response.text(id); }") != null);
}

test "canonicalize_capability_key_alias is not dispatched source-only" {
    // capability alias needs cross-line scope analysis through
    // canonicalize.collect; the AST tool runs that path itself rather
    // than going through applyIntent.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  let key = "API_KEY";
        \\  const value = env(key);
        \\  return Response.json({ value: value });
        \\}
    ;
    try testing.expectError(error.UnsupportedRepairIntent, applyIntent(testing.allocator, source, .{
        .plan_id = "rp_g5",
        .intent_kind = "canonicalize_capability_key_alias",
        .line = 3,
        .template = "",
    }));
}

test "applyIntent lowers drop_redundant_bool_compare to the bare boolean" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const ready = req.method === "GET";
        \\  if (ready === true) { return Response.text("a"); }
        \\  return Response.text("b");
        \\}
        \\
    ;
    const out = try applyIntent(allocator, source, .{
        .plan_id = "p",
        .intent_kind = "drop_redundant_bool_compare",
        .line = 3,
        .template = "",
    });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (ready) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "=== true") == null);
    // Everything outside the rewritten span survives.
    try std.testing.expect(std.mem.indexOf(u8, out, "req.method === \"GET\"") != null);
}

test "applyIntent lowers the false form to a negation" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const ready = false;
        \\  if (ready === false) { return Response.text("a"); }
        \\  return Response.text("b");
        \\}
        \\
    ;
    const out = try applyIntent(allocator, source, .{
        .plan_id = "p",
        .intent_kind = "drop_redundant_bool_compare",
        .line = 3,
        .template = "",
    });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "if (!ready) {") != null);
}

test "applyIntent refuses an ambiguous line with two comparisons" {
    const allocator = std.testing.allocator;
    // Two candidate operators on one line: `Intent` carries no column, so
    // there is no way to tell which one the diagnostic meant. Rewriting a
    // guess would silently change the other expression.
    const source =
        \\function handler(req: Request): Response {
        \\  const a = true;
        \\  const b = true;
        \\  if (a === true && b === true) { return Response.text("x"); }
        \\  return Response.text("y");
        \\}
        \\
    ;
    try std.testing.expectError(error.UnsupportedRepairIntent, applyIntent(allocator, source, .{
        .plan_id = "p",
        .intent_kind = "drop_redundant_bool_compare",
        .line = 4,
        .template = "",
    }));
}
