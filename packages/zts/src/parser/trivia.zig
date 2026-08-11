//! Comments and blank-line runs, which the IR discards.
//!
//! The canonical formatter (D3 section 2) prints from the IR, and the IR knows
//! nothing about either: `skipWhitespaceAndComments` consumes both and records
//! neither. Every layout rule about comments depends on getting them back, so
//! this is the first half of the formatter and lands before any printing.
//!
//! **Collected after the parse, not during it.** The plan said "the parser
//! retains comments", and the parser is the wrong place for two measured
//! reasons. The tokenizer backtracks - `saveState`/`restoreState` re-scan the
//! same bytes, so recording inline would double-count and need a high-water
//! mark to undo. And the `Parser` is returned by value from `init`, which
//! already consumes the first token, so a sink pointer into it would either
//! dangle or miss the leading trivia of the file.
//!
//! What this does instead is drive the tokenizer over the source a second time
//! and read the gaps between consecutive tokens. That is exact rather than
//! approximate: the bytes between one token's end and the next token's start
//! are whitespace and comments by construction, so the gap scanner needs no
//! string, template, or regex logic to avoid mistaking `"// not a comment"` for
//! a comment - the tokenizer already put that inside a token.
//!
//! One limitation, named rather than left to be discovered: a bare tokenizer
//! run is not in JSX mode, since only the parser turns that on. Inside JSX
//! text, `//` lexes as two operators and the bytes after it are ordinary
//! tokens, so a comment marker in element text is not mistaken for a comment -
//! but the text itself is tokenized as code, and a gap inside it is reported
//! as whitespace. No layout rule reads JSX text yet; the printer will need its
//! own answer when it covers JSX.

const std = @import("std");
const token = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const Kind = enum {
    /// `// ...` up to but not including the newline.
    line_comment,
    /// `/* ... */`, including both delimiters. May span lines.
    block_comment,
    /// One or more empty lines. `blank_lines` carries how many, because the
    /// layout rule collapses a run to one and a rule about a run cannot be
    /// stated from a record per line.
    blank_line_run,
};

pub const Trivia = struct {
    kind: Kind,
    /// Half-open byte span, in the source this was collected from.
    start: u32,
    end: u32,
    /// 1-based line the trivia starts on.
    line: u32,
    /// Empty lines in the run. Zero for a comment.
    blank_lines: u32 = 0,
    /// True when a comment is the first non-whitespace on its line. An own-line
    /// comment attaches to what follows it; a trailing comment stays on the
    /// line it shares with code. False for a blank-line run.
    own_line: bool = false,
};

/// Collect every comment and blank-line run in `source`, in ascending order.
///
/// The caller owns the returned slice.
pub fn collect(allocator: std.mem.Allocator, source: []const u8) ![]Trivia {
    var out: std.ArrayListUnmanaged(Trivia) = .empty;
    errdefer out.deinit(allocator);

    var tz = Tokenizer.init(source);
    var cursor: u32 = 0;
    var line: u32 = 1;

    while (true) {
        const tok = tz.next();
        const gap_end = @min(tok.start, @as(u32, @intCast(source.len)));
        if (gap_end > cursor) {
            line = try scanGap(allocator, &out, source, cursor, gap_end, line);
        }
        if (tok.type == .eof) break;

        const next_cursor = tok.start + tok.len;
        // A tokenizer that stopped advancing would spin here rather than fail,
        // and a hang is the worst way to report malformed input. `.invalid`
        // tokens have a length, so this only fires on a defect.
        if (next_cursor <= cursor) break;
        line += countNewlines(source[cursor..next_cursor]);
        cursor = next_cursor;
    }

    return out.toOwnedSlice(allocator);
}

/// Scan one inter-token gap, which holds only whitespace and comments.
/// Returns the line number at `end`.
fn scanGap(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Trivia),
    source: []const u8,
    start: u32,
    end: u32,
    start_line: u32,
) !u32 {
    var i = start;
    var line = start_line;
    // Newlines seen since the last comment or the start of the gap. The first
    // newline ends whatever line the previous token was on, so a run of N
    // newlines leaves N-1 empty lines behind it.
    var pending_newlines: u32 = 0;
    var run_start: u32 = start;

    while (i < end) {
        const c = source[i];
        if (c == '\n') {
            if (pending_newlines == 0) run_start = i;
            pending_newlines += 1;
            line += 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c != '/') {
            // Not whitespace and not a comment: the gap is not what this
            // scanner was promised. Stop rather than record a guess.
            break;
        }

        try flushBlankRun(allocator, out, outLine(line, pending_newlines), run_start, i, &pending_newlines);

        const own_line = i == start or firstOnLine(source, i);
        if (i + 1 < end and source[i + 1] == '/') {
            var j = i + 2;
            while (j < end and source[j] != '\n') j += 1;
            try out.append(allocator, .{
                .kind = .line_comment,
                .start = i,
                .end = j,
                .line = line,
                .own_line = own_line,
            });
            i = j;
            continue;
        }
        if (i + 1 < end and source[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < end) : (j += 1) {
                if (source[j] == '*' and source[j + 1] == '/') {
                    j += 2;
                    break;
                }
            } else j = end;
            const comment_line = line;
            line += countNewlines(source[i..j]);
            try out.append(allocator, .{
                .kind = .block_comment,
                .start = i,
                .end = j,
                .line = comment_line,
                .own_line = own_line,
            });
            i = j;
            continue;
        }
        break;
    }

    try flushBlankRun(allocator, out, outLine(line, pending_newlines), run_start, i, &pending_newlines);
    return line;
}

/// The line a pending blank run started on.
fn outLine(current_line: u32, pending: u32) u32 {
    return if (current_line > pending) current_line - pending else 1;
}

fn flushBlankRun(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Trivia),
    line: u32,
    start: u32,
    end: u32,
    pending: *u32,
) !void {
    defer pending.* = 0;
    // One newline ends the previous line and leaves nothing empty behind it.
    if (pending.* < 2) return;
    try out.append(allocator, .{
        .kind = .blank_line_run,
        .start = start,
        .end = end,
        .line = line,
        .blank_lines = pending.* - 1,
    });
}

fn countNewlines(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn firstOnLine(source: []const u8, offset: u32) bool {
    var i = offset;
    while (i > 0) {
        const c = source[i - 1];
        if (c == '\n') return true;
        if (c != ' ' and c != '\t' and c != '\r') return false;
        i -= 1;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Attachment
// ---------------------------------------------------------------------------
//
// Attachment is a query over offsets rather than a field on a node. A node
// carries the byte span of the token that opened it, so "the comments directly
// above this node" and "the comment on this node's line" are both answerable
// from the trivia list and the node's own position, and no node has to grow a
// pointer for the printer's benefit.

/// The own-line comments directly above `node_start`, with no code between them
/// and it. A blank-line run does not break the attachment - a comment separated
/// from its declaration by a blank line still documents it - but a comment that
/// another declaration sits under is that declaration's, not this one's.
///
/// The result is a sub-slice of `trivia`, so it stays in source order.
pub fn leadingFor(trivia: []const Trivia, node_start: u32) []const Trivia {
    var end: usize = 0;
    while (end < trivia.len and trivia[end].start < node_start) end += 1;

    var begin = end;
    while (begin > 0) {
        const t = trivia[begin - 1];
        if (t.kind == .blank_line_run) {
            begin -= 1;
            continue;
        }
        if (!t.own_line) break;
        begin -= 1;
    }

    // Trim blank runs off both ends: they separate, they do not attach.
    while (begin < end and trivia[begin].kind == .blank_line_run) begin += 1;
    while (end > begin and trivia[end - 1].kind == .blank_line_run) end -= 1;
    return trivia[begin..end];
}

/// The trailing comment on `line`, if any: a comment that shares its line with
/// code and therefore stays on it.
pub fn trailingOn(trivia: []const Trivia, line: u32) ?Trivia {
    for (trivia) |t| {
        if (t.kind == .blank_line_run) continue;
        if (t.line == line and !t.own_line) return t;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn collectTest(source: []const u8) ![]Trivia {
    return collect(testing.allocator, source);
}

test "a file with no comments retains nothing" {
    const t = try collectTest("const a = 1;\nconst b = 2;\n");
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 0), t.len);
}

test "a line comment is retained with its own bytes" {
    const source = "// leading\nconst a = 1;\n";
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(Kind.line_comment, t[0].kind);
    try testing.expectEqualStrings("// leading", source[t[0].start..t[0].end]);
    try testing.expectEqual(@as(u32, 1), t[0].line);
    try testing.expect(t[0].own_line);
}

test "a trailing comment is distinguished from an own-line one" {
    const source =
        \\const a = 1; // trailing
        \\// own line
        \\const b = 2;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expect(!t[0].own_line);
    try testing.expectEqualStrings("// trailing", source[t[0].start..t[0].end]);
    try testing.expect(t[1].own_line);
    try testing.expectEqualStrings("// own line", source[t[1].start..t[1].end]);

    try testing.expect(trailingOn(t, 1) != null);
    try testing.expect(trailingOn(t, 2) == null);
}

test "a block comment keeps its bytes verbatim across lines" {
    const source = "/* one\n   two */\nconst a = 1;\n";
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(Kind.block_comment, t[0].kind);
    try testing.expectEqualStrings("/* one\n   two */", source[t[0].start..t[0].end]);
}

test "a comment marker inside a string is not a comment" {
    // The reason this pass rides the tokenizer instead of scanning bytes: a
    // byte scanner would report a comment here, and a printer would then delete
    // half a string literal.
    const t = try collectTest("const a = \"// not a comment\";\n");
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 0), t.len);
}

test "two blank lines are one run, not two facts" {
    const source = "const a = 1;\n\n\nconst b = 2;\n";
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(Kind.blank_line_run, t[0].kind);
    try testing.expectEqual(@as(u32, 2), t[0].blank_lines);
}

test "a single newline between declarations is not a blank run" {
    const t = try collectTest("const a = 1;\nconst b = 2;\n");
    defer testing.allocator.free(t);
    try testing.expectEqual(@as(usize, 0), t.len);
}

test "a comment above a declaration attaches to it and not to the one before" {
    const source =
        \\const a = 1;
        \\// documents b
        \\const b = 2;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);

    const b_start: u32 = @intCast(std.mem.indexOf(u8, source, "const b").?);
    const leading_b = leadingFor(t, b_start);
    try testing.expectEqual(@as(usize, 1), leading_b.len);
    try testing.expectEqualStrings("// documents b", source[leading_b[0].start..leading_b[0].end]);

    // The declaration before it owns nothing: the comment is below it.
    const a_start: u32 = @intCast(std.mem.indexOf(u8, source, "const a").?);
    try testing.expectEqual(@as(usize, 0), leadingFor(t, a_start).len);
}

test "a trailing comment does not attach to the next declaration" {
    const source =
        \\const a = 1; // about a
        \\const b = 2;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    const b_start: u32 = @intCast(std.mem.indexOf(u8, source, "const b").?);
    try testing.expectEqual(@as(usize, 0), leadingFor(t, b_start).len);
}

test "a blank line separates but does not detach" {
    const source =
        \\const a = 1;
        \\
        \\// documents b
        \\
        \\const b = 2;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    const b_start: u32 = @intCast(std.mem.indexOf(u8, source, "const b").?);
    const leading_b = leadingFor(t, b_start);
    try testing.expectEqual(@as(usize, 1), leading_b.len);
    try testing.expectEqualStrings("// documents b", source[leading_b[0].start..leading_b[0].end]);
}

test "consecutive own-line comments attach as one block" {
    const source =
        \\// first
        \\// second
        \\const a = 1;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    const a_start: u32 = @intCast(std.mem.indexOf(u8, source, "const a").?);
    const leading = leadingFor(t, a_start);
    try testing.expectEqual(@as(usize, 2), leading.len);
    try testing.expectEqualStrings("// first", source[leading[0].start..leading[0].end]);
    try testing.expectEqualStrings("// second", source[leading[1].start..leading[1].end]);
}

test "trivia offsets index the source they were collected from" {
    // The floor under every span above: a table whose offsets did not index
    // this source would still satisfy the counts, so each test slices the
    // source with the span and compares text. This one states the invariant
    // over a file carrying every kind at once.
    const source =
        \\// header
        \\
        \\/* block */
        \\const a = 1; // trailing
        \\
        \\
        \\const b = 2;
        \\
    ;
    const t = try collectTest(source);
    defer testing.allocator.free(t);
    for (t) |item| {
        try testing.expect(item.end <= source.len);
        try testing.expect(item.start <= item.end);
        switch (item.kind) {
            .line_comment => try testing.expect(std.mem.startsWith(u8, source[item.start..item.end], "//")),
            .block_comment => {
                try testing.expect(std.mem.startsWith(u8, source[item.start..item.end], "/*"));
                try testing.expect(std.mem.endsWith(u8, source[item.start..item.end], "*/"));
            },
            .blank_line_run => {
                for (source[item.start..item.end]) |c| {
                    try testing.expect(c == '\n' or c == ' ' or c == '\t' or c == '\r');
                }
                try testing.expect(item.blank_lines >= 1);
            },
        }
    }
}
