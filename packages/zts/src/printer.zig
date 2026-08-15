//! The canonical formatter (D3 section 2), fail closed.
//!
//! ## What it prints from, and why not the IR
//!
//! D3 section 2 said "an AST-to-source printer over the parsed IR plus
//! retained trivia". Measured against this repository, that shape cannot print
//! this repository's sources. The IR the parser produces is type-erased:
//! `stripper.strip` blanks every annotation before `JsParser` sees the text,
//! so a printer over the IR would delete every `: T`, every `type` and
//! `interface` declaration, and the `import type` clauses of 23 of the 58
//! tracked example files. `TypeMapKind` has no member for a type-only import
//! at all, so that loss is not even recoverable from the side table.
//!
//! What this prints from instead is the token stream of the source as written,
//! plus the trivia pass and the stripper's type map. Every token is carried
//! through verbatim - only the whitespace between tokens is decided here - so
//! annotations, `import type`, `0xff`, and a template literal's interior all
//! survive by construction rather than by a rule that remembers them.
//!
//! ## Fail closed, and how that is enforced rather than declared
//!
//! Coverage widens construct by construct, and what is not covered returns
//! `error.UnprintableConstruct` with a `Refusal` naming the reason, so a gate
//! can name the file rather than skip it silently. The last refusal is the one
//! that makes the rest mean something: the printer re-lexes its own output and
//! compares the token sequence against its input. A layout defect that would
//! have changed the program becomes a refusal instead of a rewritten file.
//!
//! ## Types are opaque
//!
//! A type annotation, a type argument list, and a whole `type`, `interface`,
//! or `distinct type` declaration are printed as the bytes the author wrote.
//! The stripper already decided where each one starts and ends - that is what
//! the type map is - and re-deciding it here would be a second answer to a
//! question that already has one. So the canonical form of this phase does not
//! canonicalize type layout, the same way it does not reflow a comment. It
//! also removes the `<` ambiguity from the layout engine: a `<` the stripper
//! did not record is a comparison, and prints spaced like one.

const std = @import("std");
const token_mod = @import("parser/token.zig");
const Token = token_mod.Token;
const TokenType = token_mod.TokenType;
const Tokenizer = @import("parser/tokenizer.zig").Tokenizer;
const trivia = @import("parser/trivia.zig");
const source_frontend = @import("source_frontend.zig");

pub const Error = error{ UnprintableConstruct, OutOfMemory };

/// Why the printer refused. Reported so a gate names the construct rather than
/// the file alone; widening coverage is driven by which of these the corpus
/// produces.
pub const Refusal = enum {
    /// JSX and TSX: a bare tokenizer run is not in JSX mode, so element text
    /// would be re-tokenized as code.
    jsx_source,
    /// A CR in the source. Line endings are LF here and a printer that
    /// normalized them would be rewriting bytes it was not asked about.
    carriage_return,
    /// The tokenizer produced `.invalid`.
    invalid_token,
    /// A token whose spacing or structure this printer does not decide.
    unsupported_token,
    /// Brackets that do not nest.
    unbalanced_brackets,
    /// A statement that ends without `;`, which ASI would terminate. The
    /// printer never inserts a token, so it refuses rather than join two
    /// statements onto one line.
    missing_semicolon,
    /// A comment somewhere no layout rule places it.
    comment_position,
    /// The TypeScript stripper rejected the source, so the type spans this
    /// printer needs do not exist.
    strip_failed,
    /// The output did not re-lex to its input. A defect guard: the refusal is
    /// the failure, not the rewritten file.
    self_check,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .jsx_source => "JSX source",
            .carriage_return => "CRLF line ending",
            .invalid_token => "invalid token",
            .unsupported_token => "unsupported token",
            .unbalanced_brackets => "unbalanced brackets",
            .missing_semicolon => "statement without a semicolon",
            .comment_position => "comment in an unplaceable position",
            .strip_failed => "TypeScript stripping failed",
            .self_check => "output did not re-lex to its input",
        };
    }
};

pub const Options = struct {
    /// True for `.tsx` and `.jsx` sources, which are refused.
    jsx: bool = false,
    /// The soft target. A line with no break point may exceed it.
    width: u32 = 80,
    /// Set to the reason when the printer refuses.
    reason_out: ?*Refusal = null,
};

/// Print `source` in canonical form. The caller owns the result.
pub fn print(allocator: std.mem.Allocator, source: []const u8, options: Options) Error![]u8 {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const printed = try printInto(arena, source, options, true);
    return allocator.dupe(u8, printed);
}

fn refuse(options: Options, reason: Refusal) Error {
    if (options.reason_out) |out| out.* = reason;
    return error.UnprintableConstruct;
}

// ---------------------------------------------------------------------------
// Chunks: the tree the layout rules run over
// ---------------------------------------------------------------------------

const GroupKind = enum {
    /// `( ... )` holding a comma list: call arguments, a parameter list.
    call_args,
    /// `( ... )` that is not a comma list: a condition, a grouping paren.
    paren,
    /// `[ ... ]` array literal.
    array,
    /// `[ ... ]` index access.
    index,
    /// `{ ... }` holding statements.
    block,
    /// `{ ... }` holding `match` arms.
    match_body,
    /// `{ ... }` holding a comma list: an object literal, an import clause.
    object,

    fn opener(self: GroupKind) u8 {
        return switch (self) {
            .call_args, .paren => '(',
            .array, .index => '[',
            .block, .match_body, .object => '{',
        };
    }

    fn closer(self: GroupKind) u8 {
        return switch (self) {
            .call_args, .paren => ')',
            .array, .index => ']',
            .block, .match_body, .object => '}',
        };
    }

    /// D3 section 2: trailing commas in multi-line lists. A grouping paren, a
    /// condition, and an index are not lists, and a trailing comma in one is a
    /// syntax error rather than a style.
    fn takesTrailingComma(self: GroupKind) bool {
        return switch (self) {
            .call_args, .array, .object => true,
            .paren, .index, .block, .match_body => false,
        };
    }
};

const Chunk = union(enum) {
    tok: TokenInfo,
    /// Source printed exactly as written: a type annotation, a type argument
    /// list, or a whole type declaration.
    verbatim: []const u8,
    comment: Comment,
    /// One blank line, whatever the length of the run it came from.
    blank,
    group: *Group,
};

const Comment = struct {
    text: []const u8,
    own_line: bool,
    line: u32,
};

const TokenInfo = struct {
    tok: Token,
    text: []const u8,
    /// `+`, `-`, `!`, `~` in prefix position.
    unary: bool = false,
    /// `?` opening a ternary, and the `:` that closes one.
    ternary: bool = false,
    /// A property name: the token before it is `.` or `?.`. A keyword there is
    /// a name, and binds to what follows it.
    property: bool = false,
};

const Group = struct {
    kind: GroupKind,
    children: []Chunk,
    must_break: bool = false,
    /// The token that opened this group, for the `match (...) {` lookback.
    head: ?TokenType = null,
    flat: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Opaque regions
// ---------------------------------------------------------------------------

const Region = struct { start: u32, end: u32 };

/// The spans the layout engine never looks inside. Built from the stripper's
/// type map, which is the one place that already knows where a type starts and
/// stops.
fn collectRegions(
    arena: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error![]Region {
    var prepared = source_frontend.PreparedSource.init(arena, source, "<printer>.ts", .{ .report_errors = false }) catch
        return refuse(options, .strip_failed);
    defer prepared.deinit();
    const type_map = prepared.typeMap() orelse return refuse(options, .strip_failed);

    var regions: std.ArrayListUnmanaged(Region) = .empty;
    for (type_map.entries.items) |entry| {
        if (entry.source_end <= entry.source_start) continue;
        const span: Region = switch (entry.kind) {
            // The recorded span is the interior of the `<...>`, so the
            // delimiters come with it or the layout engine would have to
            // decide what a bare `<` is.
            .generic_params, .call_type_arguments => .{
                .start = entry.source_start -| 1,
                .end = @min(entry.source_end + 1, @as(u32, @intCast(source.len))),
            },
            // A type declaration is opaque as a whole statement: the body span
            // alone would leave `type Foo =` to be laid out as code.
            .type_alias, .distinct_type => .{
                .start = declarationStart(source, entry.name_start),
                .end = declarationEnd(source, entry.source_end),
            },
            .var_annotation,
            .param_annotation,
            .return_annotation,
            .type_guard_annotation,
            => .{ .start = entry.source_start, .end = entry.source_end },
        };
        // The recorded span may carry the whitespace the author left around
        // the type. Trimming it here is what keeps `): string {` from
        // printing with the space twice - once inside the region and once
        // from the spacing rule that put the brace after it.
        const trimmed = trim(source, span);
        if (trimmed.end > trimmed.start and trimmed.end <= source.len) {
            try regions.append(arena, trimmed);
        }
    }

    const items = try regions.toOwnedSlice(arena);
    std.mem.sort(Region, items, {}, struct {
        fn lessThan(_: void, a: Region, b: Region) bool {
            return a.start < b.start;
        }
    }.lessThan);

    // Merge, so a generic parameter list recorded inside a type declaration
    // does not split that declaration into three chunks.
    var merged: std.ArrayListUnmanaged(Region) = .empty;
    for (items) |r| {
        if (merged.items.len > 0) {
            const last = &merged.items[merged.items.len - 1];
            if (r.start <= last.end) {
                last.end = @max(last.end, r.end);
                continue;
            }
        }
        try merged.append(arena, r);
    }
    return merged.toOwnedSlice(arena);
}

/// Walk back from a declaration's name to the start of the statement that
/// declares it: over `type`, `interface`, `structural`, `nominal`,
/// `distinct type`, and any `export`.
fn declarationStart(source: []const u8, name_start: u32) u32 {
    var at = name_start;
    at = skipWordBack(source, at, &.{ "type", "interface", "structural", "nominal" });
    at = skipWordBack(source, at, &.{"distinct"});
    at = skipWordBack(source, at, &.{"export"});
    return at;
}

fn skipWordBack(source: []const u8, from: u32, words: []const []const u8) u32 {
    var i = from;
    while (i > 0 and isSpace(source[i - 1])) i -= 1;
    const word_end = i;
    while (i > 0 and isIdentByte(source[i - 1])) i -= 1;
    const word = source[i..word_end];
    for (words) |w| {
        if (std.mem.eql(u8, word, w)) return i;
    }
    return from;
}

/// Take the `;` that terminates a type declaration into the opaque span, so
/// the statement splitter sees one complete statement either way. The source
/// decides whether there is one; nothing here inserts or removes it.
fn declarationEnd(source: []const u8, body_end: u32) u32 {
    var i = body_end;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    if (i < source.len and source[i] == ';') return i + 1;
    return body_end;
}

fn trim(source: []const u8, span: Region) Region {
    var out = span;
    while (out.start < out.end and isSpace(source[out.start])) out.start += 1;
    while (out.end > out.start and isSpace(source[out.end - 1])) out.end -= 1;
    return out;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn regionAt(regions: []const Region, offset: u32) ?Region {
    for (regions) |r| {
        if (offset >= r.start and offset < r.end) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Lexing
// ---------------------------------------------------------------------------

fn unsupported(t: TokenType) bool {
    return switch (t) {
        .regex_literal,
        .at_sign,
        .plus_plus,
        .minus_minus,
        .kw_class,
        => true,
        else => false,
    };
}

fn lex(arena: std.mem.Allocator, source: []const u8, options: Options) Error![]Token {
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    var tz = Tokenizer.init(source);
    while (true) {
        const tok = tz.next();
        if (tok.type == .eof) break;
        if (tok.type == .invalid) return refuse(options, .invalid_token);
        if (unsupported(tok.type)) return refuse(options, .unsupported_token);
        if (tokens.items.len > 0) {
            const prev = tokens.items[tokens.items.len - 1];
            // A tokenizer that stopped advancing would otherwise spin.
            if (tok.start < prev.start + prev.len) return refuse(options, .invalid_token);
            // ASI's restricted productions: a newline after `return` (or
            // `break`, `continue`, `throw`) terminates the statement there,
            // whatever follows on the next line. Printing the two onto one
            // line would keep every token and change what the program means,
            // which is the one thing the self-check cannot see.
            const gap = source[prev.start + prev.len .. tok.start];
            const restricted = switch (prev.type) {
                .kw_return, .kw_break, .kw_continue, .kw_throw => true,
                else => false,
            };
            if (restricted and tok.type != .semicolon and
                std.mem.indexOfScalar(u8, gap, '\n') != null)
            {
                return refuse(options, .missing_semicolon);
            }
        }
        try tokens.append(arena, tok);
    }
    return tokens.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Building the chunk tree
// ---------------------------------------------------------------------------

const Builder = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    options: Options,
    tokens: []const Token,
    regions: []const Region,
    trivia_items: []const trivia.Trivia,
    ti: usize = 0,
    ci: usize = 0,

    fn build(self: *Builder) Error![]Chunk {
        const top = try self.children(null);
        if (self.ti < self.tokens.len) return refuse(self.options, .unbalanced_brackets);
        return top;
    }

    /// Collect chunks until `closer` (or the end of the token list when null).
    fn children(self: *Builder, closer: ?TokenType) Error![]Chunk {
        var out: std.ArrayListUnmanaged(Chunk) = .empty;
        while (true) {
            const next_offset: u32 = if (self.ti < self.tokens.len)
                self.tokens[self.ti].start
            else
                @intCast(self.source.len);
            try self.drainTrivia(&out, next_offset);

            if (self.ti >= self.tokens.len) {
                if (closer != null) return refuse(self.options, .unbalanced_brackets);
                return out.toOwnedSlice(self.arena);
            }

            const tok = self.tokens[self.ti];
            if (closer) |c| {
                if (tok.type == c) {
                    self.ti += 1;
                    return out.toOwnedSlice(self.arena);
                }
            }
            if (tok.type == .rparen or tok.type == .rbracket or tok.type == .rbrace) {
                return refuse(self.options, .unbalanced_brackets);
            }

            if (regionAt(self.regions, tok.start)) |region| {
                try out.append(self.arena, .{ .verbatim = self.source[region.start..region.end] });
                while (self.ti < self.tokens.len and self.tokens[self.ti].start < region.end) {
                    self.ti += 1;
                }
                continue;
            }

            switch (tok.type) {
                .lparen, .lbracket, .lbrace => try out.append(
                    self.arena,
                    .{ .group = try self.group(out.items) },
                ),
                else => {
                    self.ti += 1;
                    try out.append(self.arena, .{ .tok = .{
                        .tok = tok,
                        .text = self.tokenText(tok),
                    } });
                },
            }
        }
    }

    fn group(self: *Builder, before: []const Chunk) Error!*Group {
        const open = self.tokens[self.ti];
        const head = lastTokenType(before);
        self.ti += 1;
        const kind_closer: TokenType = switch (open.type) {
            .lparen => .rparen,
            .lbracket => .rbracket,
            else => .rbrace,
        };
        const kids = try self.children(kind_closer);

        const g = try self.arena.create(Group);
        g.* = .{
            .kind = try self.classify(open, head, before, kids),
            .children = kids,
            .head = head,
        };
        g.must_break = computeMustBreak(g);
        return g;
    }

    fn classify(
        self: *Builder,
        open: Token,
        head: ?TokenType,
        before: []const Chunk,
        kids: []const Chunk,
    ) Error!GroupKind {
        _ = self;
        const property = lastTokenIsProperty(before);
        return switch (open.type) {
            .lparen => if (callLike(head, property)) .call_args else if (hasTopLevelComma(kids)) .call_args else .paren,
            .lbracket => if (callLike(head, property)) .index else .array,
            else => blk: {
                if (isMatchBody(before)) break :blk .match_body;
                if (holdsStatements(kids)) break :blk .block;
                break :blk .object;
            },
        };
    }

    fn tokenText(self: *Builder, tok: Token) []const u8 {
        return tok.text(self.source);
    }

    /// Emit the trivia that sits before `offset`.
    fn drainTrivia(self: *Builder, out: *std.ArrayListUnmanaged(Chunk), offset: u32) Error!void {
        while (self.ci < self.trivia_items.len and self.trivia_items[self.ci].start < offset) {
            const item = self.trivia_items[self.ci];
            self.ci += 1;
            if (regionAt(self.regions, item.start) != null) continue;
            switch (item.kind) {
                .blank_line_run => try out.append(self.arena, .blank),
                .line_comment, .block_comment => try out.append(self.arena, .{ .comment = .{
                    .text = self.source[item.start..item.end],
                    .own_line = item.own_line,
                    .line = item.line,
                } }),
            }
        }
    }
};

fn lastTokenType(chunks: []const Chunk) ?TokenType {
    var i = chunks.len;
    while (i > 0) {
        i -= 1;
        switch (chunks[i]) {
            .tok => |t| return t.tok.type,
            .group => |g| return switch (g.kind) {
                .call_args, .paren => .rparen,
                .array, .index => .rbracket,
                .block, .match_body, .object => .rbrace,
            },
            .verbatim => return .identifier,
            .comment, .blank => continue,
        }
    }
    return null;
}

/// A keyword the grammar also admits as a property name. After a `.` it is a
/// name and binds to what follows it; anywhere else it is the keyword and
/// stands apart. Treating the two the same printed `for (const i of[0, 1, 2])`
/// and `when[1, 2]:` - every token preserved, so the self-check passed, and
/// the spelling mangled.
fn nameOnlyAfterDot(t: TokenType) bool {
    return switch (t) {
        .kw_get,
        .kw_set,
        .kw_of,
        .kw_from,
        .kw_as,
        .kw_default,
        .kw_static,
        .kw_when,
        => true,
        else => false,
    };
}

/// A `(` or `[` directly after an operand is a call or an index; after
/// anything else it opens a list, a group, or a literal.
fn callLike(head: ?TokenType, property: bool) bool {
    const t = head orelse return false;
    if (nameOnlyAfterDot(t)) return property;
    return switch (t) {
        .identifier,
        .rparen,
        .rbracket,
        .string_literal,
        .template_literal,
        .template_tail,
        => true,
        else => false,
    };
}

/// True when the last token of `chunks` is a property name: the token before
/// it is the `.` or `?.` that made it one.
fn lastTokenIsProperty(chunks: []const Chunk) bool {
    var seen = false;
    var i = chunks.len;
    while (i > 0) {
        i -= 1;
        switch (chunks[i]) {
            .comment, .blank => continue,
            .tok => |t| {
                if (!seen) {
                    seen = true;
                    continue;
                }
                return t.tok.type == .dot or t.tok.type == .question_dot;
            },
            else => return false,
        }
    }
    return false;
}

fn isMatchBody(before: []const Chunk) bool {
    var i = before.len;
    while (i > 0) {
        i -= 1;
        switch (before[i]) {
            .comment, .blank => continue,
            .group => |g| return (g.kind == .call_args or g.kind == .paren) and g.head == .kw_match,
            else => return false,
        }
    }
    return false;
}

fn hasTopLevelComma(kids: []const Chunk) bool {
    for (kids) |c| {
        if (c == .tok and c.tok.tok.type == .comma) return true;
    }
    return false;
}

/// A brace holds statements when its own level carries a `;` or opens with a
/// statement keyword. Deciding by content rather than by the token before the
/// brace keeps an interface body, a block, and an object literal apart without
/// a keyword table that has to stay in step with the grammar.
fn holdsStatements(kids: []const Chunk) bool {
    for (kids) |c| {
        if (c != .tok) continue;
        switch (c.tok.tok.type) {
            .semicolon,
            .kw_return,
            .kw_const,
            .kw_let,
            .kw_if,
            .kw_for,
            .kw_assert,
            .kw_throw,
            .kw_break,
            .kw_continue,
            .kw_import,
            .kw_export,
            .kw_function,
            => return true,
            else => {},
        }
    }
    return false;
}

fn computeMustBreak(g: *Group) bool {
    if (g.kind == .match_body) return g.children.len > 0;
    if (g.kind == .block) return g.children.len > 0;
    for (g.children) |c| {
        switch (c) {
            .comment => return true,
            .group => |child| if (child.must_break) return true,
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Token-level context: unary operators and ternaries
// ---------------------------------------------------------------------------

/// Mark prefix `+`/`-`/`!`/`~` and the `?`/`:` pair of a ternary. Both change
/// spacing, and neither is decidable from the token alone.
fn markContext(chunks: []Chunk, options: Options) Error!void {
    var prev: ?TokenType = null;
    var pending_ternary: u32 = 0;
    for (chunks, 0..) |*c, idx| {
        switch (c.*) {
            .group => |g| try markContext(g.children, options),
            .verbatim => prev = .identifier,
            .comment, .blank => {},
            .tok => |*info| {
                info.property = prev == .dot or prev == .question_dot;
                switch (info.tok.type) {
                    .plus, .minus, .bang, .tilde => {
                        info.unary = !endsOperand(prev);
                        if (info.tok.type == .bang and !info.unary) {
                            return refuse(options, .unsupported_token);
                        }
                    },
                    .question => {
                        // `x?: T` is an optional marker; anything else opens a
                        // ternary and takes the `:` that closes it.
                        const next = nextTokenType(chunks, idx);
                        if (next != .colon) {
                            info.ternary = true;
                            pending_ternary += 1;
                        }
                    },
                    .colon => {
                        if (pending_ternary > 0) {
                            info.ternary = true;
                            pending_ternary -= 1;
                        }
                    },
                    else => {},
                }
                prev = info.tok.type;
            },
        }
    }
}

fn nextTokenType(chunks: []const Chunk, from: usize) ?TokenType {
    var i = from + 1;
    while (i < chunks.len) : (i += 1) {
        switch (chunks[i]) {
            .tok => |t| return t.tok.type,
            .group => |g| return switch (g.kind) {
                .call_args, .paren => .lparen,
                .array, .index => .lbracket,
                .block, .match_body, .object => .lbrace,
            },
            .verbatim => return .identifier,
            .comment, .blank => {},
        }
    }
    return null;
}

fn endsOperand(prev: ?TokenType) bool {
    const t = prev orelse return false;
    return switch (t) {
        .identifier,
        .number,
        .string_literal,
        .template_literal,
        .template_tail,
        .true_lit,
        .false_lit,
        .null_lit,
        .undefined_lit,
        .rparen,
        .rbracket,
        .rbrace,
        .kw_this,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Spacing
// ---------------------------------------------------------------------------

fn isWordToken(t: TokenType) bool {
    return switch (t) {
        .identifier,
        .number,
        .true_lit,
        .false_lit,
        .null_lit,
        .undefined_lit,
        => true,
        else => @intFromEnum(t) >= @intFromEnum(TokenType.kw_var) and
            @intFromEnum(t) <= @intFromEnum(TokenType.kw_assert),
    };
}

fn isBinaryOp(info: TokenInfo) bool {
    return switch (info.tok.type) {
        .plus, .minus => !info.unary,
        .star,
        .slash,
        .percent,
        .star_star,
        .eq,
        .eq_eq,
        .ne,
        .ne_ne,
        .lt,
        .le,
        .gt,
        .ge,
        .ampersand,
        .pipe,
        .caret,
        .ampersand_ampersand,
        .pipe_pipe,
        .pipe_gt,
        .question_question,
        .lt_lt,
        .gt_gt,
        .gt_gt_gt,
        .kw_in,
        .kw_of,
        .kw_as,
        .kw_instanceof,
        => true,
        else => false,
    };
}

fn isAssignOp(t: TokenType) bool {
    return switch (t) {
        .assign,
        .plus_assign,
        .minus_assign,
        .star_assign,
        .slash_assign,
        .percent_assign,
        .ampersand_assign,
        .pipe_assign,
        .caret_assign,
        .lt_lt_assign,
        .gt_gt_assign,
        .gt_gt_gt_assign,
        .star_star_assign,
        .ampersand_ampersand_assign,
        .pipe_pipe_assign,
        .question_question_assign,
        => true,
        else => false,
    };
}

/// What sits to the left of the next token, for the spacing decision. A
/// verbatim chunk (a type) behaves like an identifier; an opener and a closer
/// behave like their brackets.
const Left = struct {
    kind: ?TokenType,
    unary: bool = false,
    ternary: bool = false,
    /// The left side is a type annotation or type declaration printed
    /// verbatim, whose last byte is not necessarily an identifier byte.
    verbatim: bool = false,
    /// The left side is a property name: a `.` or `?.` put it there, so a
    /// keyword in that position is a name and binds like one.
    property: bool = false,
};

fn spaceBetween(left: Left, right: TokenInfo, right_is_opener: bool) bool {
    const l = left.kind orelse return false;
    const r = right.tok.type;

    // Nothing is ever spaced away from the punctuation that binds tightest.
    if (r == .comma or r == .semicolon) return false;
    if (r == .dot or l == .dot) return false;
    if (r == .question_dot or l == .question_dot) return false;
    if (l == .spread) return false;
    if (r == .colon and !right.ternary) return false;
    if (r == .question and !right.ternary) return false;
    if (l == .question and !left.ternary) return false;
    // `${` and the `}` that closes a substitution bind to their expression.
    if (l == .template_head or l == .template_middle) return false;
    if (r == .template_middle or r == .template_tail) return false;
    if (left.unary) return false;
    if (l == .lparen or l == .lbracket) return false;

    if (right_is_opener) {
        return switch (r) {
            .lparen => !callLike(l, left.property) and !left.verbatim,
            .lbracket => !callLike(l, left.property) and !left.verbatim,
            // A brace always stands away from what precedes it, except after
            // an opener or `(`.
            else => l != .lparen and l != .lbracket and l != .lbrace,
        };
    }

    if (isBinaryOp(right) or isAssignOp(r) or r == .arrow) return true;
    if (l == .arrow or isAssignOp(l)) return true;
    if (r == .bang and right.unary) return true;

    if (isWordToken(l) or left.verbatim) {
        if (isWordToken(r)) return true;
        return switch (r) {
            .lparen, .lbracket => false,
            else => true,
        };
    }
    if (isWordToken(r)) {
        return switch (l) {
            .lbrace => true,
            else => true,
        };
    }
    return true;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const indent_width = 2;

const Printer = struct {
    arena: std.mem.Allocator,
    options: Options,
    out: std.ArrayListUnmanaged(u8) = .empty,
    col: u32 = 0,
    left: Left = .{ .kind = null },
    at_line_start: bool = true,

    fn writeIndent(self: *Printer, indent: u32) Error!void {
        try self.out.appendNTimes(self.arena, ' ', indent * indent_width);
        self.col = indent * indent_width;
        self.at_line_start = false;
        self.left = .{ .kind = null };
    }

    fn newline(self: *Printer) Error!void {
        try self.out.append(self.arena, '\n');
        self.col = 0;
        self.at_line_start = true;
        self.left = .{ .kind = null };
    }

    fn writeRaw(self: *Printer, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
        self.col = columnAfter(self.col, text);
    }

    fn emitToken(self: *Printer, info: TokenInfo, is_opener: bool) Error!void {
        if (!self.at_line_start and spaceBetween(self.left, info, is_opener)) {
            try self.out.append(self.arena, ' ');
            self.col += 1;
        }
        const text = try normalizedTokenText(self.arena, info);
        try self.writeRaw(text);
        self.at_line_start = false;
        self.left = .{
            .kind = info.tok.type,
            .unary = info.unary,
            .ternary = info.ternary,
            .property = info.property,
        };
    }

    fn emitVerbatim(self: *Printer, text: []const u8) Error!void {
        // A type argument list binds to the name in front of it: `first<T>`
        // is one thing and `first <T>` does not parse.
        if (text.len > 0 and text[0] == '<') {
            try self.writeRaw(text);
            self.at_line_start = false;
            self.left = .{ .kind = .identifier, .verbatim = true };
            return;
        }
        // Otherwise a verbatim chunk is a type, and it spaces exactly like the
        // identifier it stands in for.
        const as_word = TokenInfo{
            .tok = .{ .type = .identifier, .start = 0, .len = 0, .line = 0, .column = 0 },
            .text = text,
        };
        if (!self.at_line_start and spaceBetween(self.left, as_word, false)) {
            try self.out.append(self.arena, ' ');
            self.col += 1;
        }
        try self.writeRaw(text);
        self.at_line_start = false;
        self.left = .{ .kind = .identifier, .verbatim = true };
    }
};

fn columnAfter(col: u32, text: []const u8) u32 {
    if (std.mem.lastIndexOfScalar(u8, text, '\n')) |at| {
        return @intCast(text.len - at - 1);
    }
    return col + @as(u32, @intCast(text.len));
}

fn firstLineWidth(text: []const u8) u32 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return @intCast(end);
}

/// D3 section 2: double quotes, escaping `"` inside and never `'`.
fn normalizedTokenText(arena: std.mem.Allocator, info: TokenInfo) Error![]const u8 {
    if (info.tok.type != .string_literal) return info.text;
    if (info.text.len < 2 or info.text[0] != '\'') return info.text;

    const body = info.text[1 .. info.text.len - 1];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, '"');
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            // `\'` loses its escape, every other escape keeps it.
            if (body[i + 1] == '\'') {
                try out.append(arena, '\'');
            } else {
                try out.append(arena, c);
                try out.append(arena, body[i + 1]);
            }
            i += 1;
            continue;
        }
        if (c == '"') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Flat rendering: the measurement every break decision reads
// ---------------------------------------------------------------------------

fn flatText(arena: std.mem.Allocator, options: Options, chunks: []const Chunk) Error![]const u8 {
    var p = Printer{ .arena = arena, .options = options };
    p.at_line_start = true;
    try writeChunksFlat(&p, chunks);
    return p.out.items;
}

fn writeChunksFlat(p: *Printer, chunks: []const Chunk) Error!void {
    for (chunks, 0..) |c, idx| {
        switch (c) {
            .tok => |info| {
                // A trailing comma is absent in a single-line list.
                if (info.tok.type == .comma and isLastSignificant(chunks, idx)) continue;
                try p.emitToken(info, false);
            },
            .verbatim => |text| try p.emitVerbatim(text),
            .blank => {},
            .comment => return refuse(p.options, .comment_position),
            .group => |g| try writeGroupFlat(p, g),
        }
    }
}

fn writeGroupFlat(p: *Printer, g: *Group) Error!void {
    const open = TokenInfo{
        .tok = .{ .type = openerType(g.kind), .start = 0, .len = 1, .line = 0, .column = 0 },
        .text = &[_]u8{g.kind.opener()},
    };
    try p.emitToken(open, true);
    const padded = (g.kind == .object or g.kind == .match_body) and g.children.len > 0;
    if (padded) {
        try p.out.append(p.arena, ' ');
        p.col += 1;
        p.left = .{ .kind = .lparen };
    }
    try writeChunksFlat(p, g.children);
    if (padded) {
        try p.out.append(p.arena, ' ');
        p.col += 1;
    }
    const close = TokenInfo{
        .tok = .{ .type = closerType(g.kind), .start = 0, .len = 1, .line = 0, .column = 0 },
        .text = &[_]u8{g.kind.closer()},
    };
    p.left = .{ .kind = if (padded) .lparen else p.left.kind };
    try p.out.append(p.arena, g.kind.closer());
    p.col += 1;
    p.left = .{ .kind = close.tok.type };
}

fn openerType(kind: GroupKind) TokenType {
    return switch (kind) {
        .call_args, .paren => .lparen,
        .array, .index => .lbracket,
        .block, .match_body, .object => .lbrace,
    };
}

fn closerType(kind: GroupKind) TokenType {
    return switch (kind) {
        .call_args, .paren => .rparen,
        .array, .index => .rbracket,
        .block, .match_body, .object => .rbrace,
    };
}

fn isLastSignificant(chunks: []const Chunk, idx: usize) bool {
    var i = idx + 1;
    while (i < chunks.len) : (i += 1) {
        switch (chunks[i]) {
            .blank => {},
            else => return false,
        }
    }
    return true;
}

fn groupFlat(p: *Printer, g: *Group) Error![]const u8 {
    if (g.flat) |cached| return cached;
    var sub = Printer{ .arena = p.arena, .options = p.options };
    sub.at_line_start = true;
    try writeGroupFlat(&sub, g);
    g.flat = sub.out.items;
    return g.flat.?;
}

// ---------------------------------------------------------------------------
// Broken rendering
// ---------------------------------------------------------------------------

const Renderer = struct {
    p: *Printer,
    width: u32,

    fn renderRun(self: *Renderer, chunks: []const Chunk, indent: u32) Error!void {
        for (chunks, 0..) |c, idx| {
            switch (c) {
                .tok => |info| {
                    if (isBinaryOp(info) and self.shouldBreakBefore(chunks, idx, indent)) {
                        try self.p.newline();
                        try self.p.writeIndent(indent + 1);
                    }
                    try self.p.emitToken(info, false);
                },
                .verbatim => |text| try self.p.emitVerbatim(text),
                .blank => {},
                .comment => return refuse(self.p.options, .comment_position),
                .group => |g| try self.renderGroup(g, indent, self.tailWidth(chunks, idx + 1)),
            }
        }
    }

    /// What still has to fit on this line after the group being placed. A
    /// group measured without it prints flat and then pushes the `;` or the
    /// `)` that follows past the target, which is the one place a greedy
    /// printer reports a fit it does not have.
    fn tailWidth(self: *Renderer, chunks: []const Chunk, from: usize) u32 {
        var end = from;
        while (end < chunks.len) : (end += 1) {
            switch (chunks[end]) {
                .comment => break,
                .group => |g| if (g.must_break) break,
                else => {},
            }
        }
        if (end <= from) return 0;
        const text = flatText(self.p.arena, self.p.options, chunks[from..end]) catch return 0;
        return firstLineWidth(text);
    }

    /// Break before an operator when the operand that follows it would push
    /// the line past the target. D3 section 2: chains break before the
    /// operator, never after it.
    fn shouldBreakBefore(self: *Renderer, chunks: []const Chunk, idx: usize, indent: u32) bool {
        var end = idx + 1;
        while (end < chunks.len) : (end += 1) {
            if (chunks[end] == .tok and isBinaryOp(chunks[end].tok)) break;
        }
        const text = flatText(self.p.arena, self.p.options, chunks[idx..end]) catch return false;
        const need = firstLineWidth(text) + 1;
        if (self.p.col + need <= self.width) return false;
        // A break that does not help is not taken: the operand alone already
        // overruns the target, so the line would move and still not fit.
        return (indent + 1) * indent_width + need <= self.width;
    }

    fn renderGroup(self: *Renderer, g: *Group, indent: u32, tail: u32) Error!void {
        if (!g.must_break) {
            const flat = try groupFlat(self.p, g);
            const lead: u32 = if (self.p.at_line_start) 0 else 1;
            if (self.p.col + firstLineWidth(flat) + lead + tail <= self.width) {
                return self.writeFlatGroup(g, flat);
            }
        }
        switch (g.kind) {
            .block => try self.renderBlock(g, indent),
            .match_body => try self.renderMatchBody(g, indent),
            .call_args => if (self.huggable(g.children)) |hug|
                try self.renderHugged(hug, indent)
            else
                try self.renderList(g, indent),
            else => try self.renderList(g, indent),
        }
    }

    /// A call whose last argument is a record, an array, or a block keeps the
    /// brackets on the call's line and breaks that argument itself. The
    /// alternative indents the same content twice and buys two lines of
    /// punctuation for it. D3 section 2 does not name this case; it is added
    /// here because the corpus is full of `Response.json({ ... })` and
    /// `resource(order, { ... })`.
    fn huggable(self: *Renderer, children: []const Chunk) ?Hug {
        const hug = huggableCall(children) orelse return null;
        if (hug.head.len == 0) return hug;
        const head_flat = flatText(self.p.arena, self.p.options, hug.head) catch return null;
        if (std.mem.indexOfScalar(u8, head_flat, '\n') != null) return null;
        // `(`, the arguments before the last, and the bracket that opens it.
        if (self.p.col + 3 + firstLineWidth(head_flat) > self.width) return null;
        return hug;
    }

    fn renderHugged(self: *Renderer, hug: Hug, indent: u32) Error!void {
        const opener = TokenInfo{
            .tok = .{ .type = .lparen, .start = 0, .len = 1, .line = 0, .column = 0 },
            .text = "(",
        };
        try self.p.emitToken(opener, true);
        if (hug.head.len > 0) {
            // `head` stops before the comma that separates it from the hugged
            // argument, because the flat writer drops a comma that ends its
            // chunk list - that is the trailing-comma rule, and here the comma
            // is a separator. Writing it back is what keeps the token stream
            // whole; the self-check caught its absence.
            try writeChunksFlat(self.p, hug.head);
            try self.p.writeRaw(",");
            self.p.left = .{ .kind = .comma };
        }
        try self.renderGroup(hug.tail, indent, 1);
        try self.p.writeRaw(")");
        self.p.left = .{ .kind = .rparen };
    }

    fn writeFlatGroup(self: *Renderer, g: *Group, flat: []const u8) Error!void {
        const opener = TokenInfo{
            .tok = .{ .type = openerType(g.kind), .start = 0, .len = 1, .line = 0, .column = 0 },
            .text = &[_]u8{g.kind.opener()},
        };
        if (!self.p.at_line_start and spaceBetween(self.p.left, opener, true)) {
            try self.p.out.append(self.p.arena, ' ');
            self.p.col += 1;
        }
        try self.p.writeRaw(flat);
        self.p.at_line_start = false;
        self.p.left = .{ .kind = closerType(g.kind) };
    }

    fn renderBlock(self: *Renderer, g: *Group, indent: u32) Error!void {
        const opener = TokenInfo{
            .tok = .{ .type = .lbrace, .start = 0, .len = 1, .line = 0, .column = 0 },
            .text = "{",
        };
        try self.p.emitToken(opener, true);
        try self.p.newline();
        try self.renderStatements(g.children, indent + 1);
        try self.p.writeIndent(indent);
        try self.p.writeRaw("}");
        self.p.left = .{ .kind = .rbrace };
    }

    /// One arm per line. A `match` arm is `when <pattern>:` or `default:`
    /// followed by its expression, and the arms carry no separator at all -
    /// the next `when` is what ends the previous arm. Splitting this body on
    /// commas the way a list is split put every arm of the corpus onto one
    /// line, which is how the shape was found.
    fn renderMatchBody(self: *Renderer, g: *Group, indent: u32) Error!void {
        const opener = TokenInfo{
            .tok = .{ .type = .lbrace, .start = 0, .len = 1, .line = 0, .column = 0 },
            .text = "{",
        };
        try self.p.emitToken(opener, true);
        try self.p.newline();

        var start: usize = 0;
        var i: usize = 0;
        var wrote_any = false;
        while (i <= g.children.len) : (i += 1) {
            const at_end = i == g.children.len;
            const starts_arm = !at_end and g.children[i] == .tok and switch (g.children[i].tok.tok.type) {
                .kw_when, .kw_default => true,
                else => false,
            };
            if (!at_end and !starts_arm) continue;
            if (i == start) continue;

            // An own-line comment written above the next arm sits at the tail
            // of this slice, because `when` is what ends an arm. It documents
            // what follows it, so the boundary moves back over it and the next
            // arm carries it as leading trivia. Left here it was dropped, and
            // the self-check turned the loss into a whole-file refusal that
            // named a re-lex mismatch instead of the comment.
            var arm_end = i;
            while (arm_end > start) : (arm_end -= 1) {
                switch (g.children[arm_end - 1]) {
                    .blank => {},
                    .comment => |cm| if (!cm.own_line) break,
                    else => break,
                }
            }

            const arm = g.children[start..arm_end];
            start = arm_end;
            if (onlyTrivia(arm)) {
                try self.emitLooseTrivia(arm, indent + 1);
                continue;
            }
            try self.emitLeadingTrivia(arm, indent + 1, !wrote_any);
            try self.renderArm(stripTrivia(arm), indent + 1);
            wrote_any = true;
            try self.emitTrailingComment(arm);
            try self.p.newline();
        }
        try self.p.writeIndent(indent);
        try self.p.writeRaw("}");
        self.p.left = .{ .kind = .rbrace };
    }

    /// D3 section 2: the arm expression sits on the pattern's line when it
    /// fits, and one level in on the next line when it does not.
    fn renderArm(self: *Renderer, arm: []const Chunk, indent: u32) Error!void {
        try self.p.writeIndent(indent);
        const flat = flatText(self.p.arena, self.p.options, arm) catch null;
        if (flat) |text| {
            if (!hasMustBreak(arm) and self.p.col + firstLineWidth(text) <= self.width) {
                return self.renderRun(arm, indent);
            }
        }
        const colon = armColon(arm) orelse return self.renderRun(arm, indent);
        try self.renderRun(arm[0 .. colon + 1], indent);
        try self.p.newline();
        try self.p.writeIndent(indent + 1);
        try self.renderRun(arm[colon + 1 ..], indent + 1);
    }

    /// One element per line, with the trailing comma the kind allows.
    fn renderList(self: *Renderer, g: *Group, indent: u32) Error!void {
        const opener = TokenInfo{
            .tok = .{ .type = openerType(g.kind), .start = 0, .len = 1, .line = 0, .column = 0 },
            .text = &[_]u8{g.kind.opener()},
        };
        try self.p.emitToken(opener, true);
        if (g.children.len == 0) {
            try self.p.writeRaw(&[_]u8{g.kind.closer()});
            self.p.left = .{ .kind = closerType(g.kind) };
            return;
        }
        try self.p.newline();

        const elements = try splitOnCommas(self.p.arena, g.children);
        var wrote_any = false;
        for (elements, 0..) |element, ei| {
            if (onlyTrivia(element)) {
                // A comment that shared a line with the element before it was
                // already emitted there; what is left is own-line.
                try self.emitLooseTrivia(element, indent + 1);
                continue;
            }
            try self.emitLeadingTrivia(element, indent + 1, !wrote_any);
            try self.p.writeIndent(indent + 1);
            try self.renderRun(stripTrivia(element), indent + 1);
            wrote_any = true;
            const last = ei + 1 == elements.len or onlyTrailingTrivia(elements[ei + 1 ..]);
            if (!last or g.kind.takesTrailingComma()) {
                try self.p.writeRaw(",");
                self.p.left = .{ .kind = .comma };
            }
            try self.emitTrailingComment(element);
            // The comma separates this element from the next, so a comment
            // the author put after the comma is still on this line.
            if (ei + 1 < elements.len) try self.emitInlineComment(elements[ei + 1]);
            try self.p.newline();
        }
        try self.p.writeIndent(indent);
        try self.p.writeRaw(&[_]u8{g.kind.closer()});
        self.p.left = .{ .kind = closerType(g.kind) };
    }

    /// The comments and blank lines an element carries before its first token.
    /// `first` suppresses a blank line at the top of the group, where it would
    /// separate an element from the bracket rather than from another element.
    fn emitLeadingTrivia(self: *Renderer, element: []const Chunk, indent: u32, first: bool) Error!void {
        var at_start = first;
        for (element) |c| {
            switch (c) {
                .comment => |cm| {
                    if (!cm.own_line) return;
                    try self.p.writeIndent(indent);
                    try self.p.writeRaw(cm.text);
                    try self.p.newline();
                    at_start = false;
                },
                // A blank line between two fields is how a large record is
                // grouped, and dropping it here erased that grouping under a
                // command whose commit message says blank-line runs are
                // retained.
                .blank => if (!at_start) try self.p.newline(),
                else => return,
            }
        }
    }

    /// An element made only of trivia: what sits between the last comma and
    /// the closing bracket, or between two commas. A comment that shared its
    /// line with the element before it was emitted there by
    /// `emitInlineComment`, so only own-line comments are left.
    fn emitLooseTrivia(self: *Renderer, element: []const Chunk, indent: u32) Error!void {
        for (element) |c| {
            switch (c) {
                .comment => |cm| {
                    if (!cm.own_line) continue;
                    try self.p.writeIndent(indent);
                    try self.p.writeRaw(cm.text);
                    try self.p.newline();
                },
                else => {},
            }
        }
    }

    /// The comment the author wrote after the separating comma, which shares
    /// its line with the element that comma follows.
    fn emitInlineComment(self: *Renderer, next: []const Chunk) Error!void {
        for (next) |c| {
            switch (c) {
                .comment => |cm| {
                    if (!cm.own_line) {
                        try self.p.writeRaw(" ");
                        try self.p.writeRaw(cm.text);
                    }
                    return;
                },
                .blank => return,
                else => return,
            }
        }
    }

    fn emitTrailingComment(self: *Renderer, element: []const Chunk) Error!void {
        var i = element.len;
        while (i > 0) {
            i -= 1;
            switch (element[i]) {
                .comment => |cm| {
                    if (cm.own_line) return;
                    try self.p.writeRaw(" ");
                    try self.p.writeRaw(cm.text);
                    return;
                },
                .blank => {},
                else => return,
            }
        }
    }

    // -----------------------------------------------------------------------
    // Statements
    // -----------------------------------------------------------------------

    fn renderStatements(self: *Renderer, chunks: []const Chunk, indent: u32) Error!void {
        var i: usize = 0;
        var pending_blank = false;
        var wrote_any = false;
        while (i < chunks.len) {
            switch (chunks[i]) {
                .blank => {
                    pending_blank = wrote_any;
                    i += 1;
                    continue;
                },
                .comment => |cm| {
                    if (pending_blank) {
                        try self.p.newline();
                        pending_blank = false;
                    }
                    try self.p.writeIndent(indent);
                    try self.p.writeRaw(cm.text);
                    try self.p.newline();
                    wrote_any = true;
                    i += 1;
                    continue;
                },
                else => {},
            }

            const end = try self.statementEnd(chunks, i);
            if (pending_blank) {
                try self.p.newline();
                pending_blank = false;
            }
            try self.p.writeIndent(indent);
            try self.renderRun(chunks[i..end], indent);
            // A trailing comment on the statement's own line.
            if (end < chunks.len and chunks[end] == .comment and !chunks[end].comment.own_line) {
                try self.p.writeRaw(" ");
                try self.p.writeRaw(chunks[end].comment.text);
                i = end + 1;
            } else {
                i = end;
            }
            try self.p.newline();
            wrote_any = true;
        }
    }

    /// Where the statement starting at `from` ends. A statement ends at its
    /// `;`, or at the block that closes a statement form (`if`, `for`,
    /// `function`, a bare block), with `else` continuing the same statement. A
    /// statement that ends any other way is one ASI would have terminated, and
    /// the printer refuses rather than insert a token.
    fn statementEnd(self: *Renderer, chunks: []const Chunk, from: usize) Error!usize {
        if (chunks[from] == .verbatim) return from + 1;

        var i = from;
        var head = chunks[from];
        if (head == .tok and head.tok.tok.type == .kw_export) {
            var j = from + 1;
            while (j < chunks.len and (chunks[j] == .comment or chunks[j] == .blank)) j += 1;
            if (j < chunks.len) head = chunks[j];
            // `export type Foo = ...` is one verbatim chunk after `export`
            // only when the stripper recorded it; otherwise it is a statement.
            if (head == .verbatim) return j + 1;
        }
        const block_form = head == .tok and switch (head.tok.tok.type) {
            .kw_if, .kw_for, .kw_function, .kw_else => true,
            else => false,
        } or (head == .group and head.group.kind == .block);

        while (i < chunks.len) : (i += 1) {
            switch (chunks[i]) {
                .tok => |info| {
                    if (info.tok.type == .semicolon) return i + 1;
                },
                .group => |g| {
                    if (!block_form or g.kind != .block) continue;
                    var j = i + 1;
                    while (j < chunks.len and (chunks[j] == .blank or
                        (chunks[j] == .comment and chunks[j].comment.own_line))) j += 1;
                    if (j < chunks.len and chunks[j] == .tok and
                        chunks[j].tok.tok.type == .kw_else)
                    {
                        i = j;
                        continue;
                    }
                    // A trailing comment stays with the statement it follows.
                    if (i + 1 < chunks.len and chunks[i + 1] == .comment and
                        !chunks[i + 1].comment.own_line)
                    {
                        return i + 1;
                    }
                    return i + 1;
                },
                else => {},
            }
        }
        return refuse(self.p.options, .missing_semicolon);
    }
};

/// The colon that ends a `match` arm's pattern. Only a colon at the arm's own
/// level counts: the one in `when { kind: "echo" }:` sits inside the record
/// pattern and is not it.
fn armColon(arm: []const Chunk) ?usize {
    for (arm, 0..) |c, idx| {
        if (c == .tok and c.tok.tok.type == .colon) return idx;
    }
    return null;
}

const Hug = struct {
    /// The arguments before the last one, without the comma that separates
    /// them from it. Printed flat on the call's own line.
    head: []const Chunk,
    /// The last argument, which is what breaks.
    tail: *Group,
};

/// The argument a call can hug: the last one, when it is a record, an array,
/// or a block, and everything before it is plain enough to print flat.
fn huggableCall(children: []const Chunk) ?Hug {
    var end = children.len;
    while (end > 0) {
        switch (children[end - 1]) {
            .blank => end -= 1,
            // A trailing comma belongs to the layout, not to the argument list.
            .tok => |t| if (t.tok.type == .comma) {
                end -= 1;
            } else return null,
            else => break,
        }
    }
    if (end == 0) return null;
    const last = children[end - 1];
    if (last != .group) return null;
    switch (last.group.kind) {
        .object, .array, .block, .match_body => {},
        else => return null,
    }

    var head = children[0 .. end - 1];
    if (head.len > 0) {
        // The head has to end at an argument boundary, and it has to be
        // printable on one line: a comment or a group that must break in it
        // would have nowhere to go.
        const last_head = head[head.len - 1];
        if (last_head != .tok or last_head.tok.tok.type != .comma) return null;
        if (hasMustBreak(head)) return null;
        // Only a plain argument list hugs. `f({ ... }, { ... })` would hug the
        // second record onto the line the first one already fills, which reads
        // worse than one argument per line - and the corpus writes those the
        // other way.
        for (head) |c| {
            if (c != .group) continue;
            switch (c.group.kind) {
                .object, .array, .block, .match_body => return null,
                else => {},
            }
        }
        head = head[0 .. head.len - 1];
    }
    return .{ .head = head, .tail = last.group };
}

fn hasMustBreak(chunks: []const Chunk) bool {
    for (chunks) |c| {
        switch (c) {
            .comment => return true,
            .group => |g| if (g.must_break) return true,
            else => {},
        }
    }
    return false;
}

/// Split a group's children at its own commas. The commas themselves are
/// dropped: the layout decides where a separator goes, and the trailing-comma
/// rule is what decides whether the last one is written at all.
fn splitOnCommas(arena: std.mem.Allocator, children: []const Chunk) Error![][]const Chunk {
    var out: std.ArrayListUnmanaged([]const Chunk) = .empty;
    var start: usize = 0;
    for (children, 0..) |c, i| {
        if (c != .tok or c.tok.tok.type != .comma) continue;
        try out.append(arena, children[start..i]);
        start = i + 1;
    }
    try out.append(arena, children[start..]);
    return out.toOwnedSlice(arena);
}

/// True when nothing but trivia follows: the elements left carry no token, so
/// the element before them is the last one and owns the trailing comma.
fn onlyTrailingTrivia(rest: []const []const Chunk) bool {
    for (rest) |element| {
        if (!onlyTrivia(element)) return false;
    }
    return true;
}

fn onlyTrivia(chunks: []const Chunk) bool {
    for (chunks) |c| {
        switch (c) {
            .comment, .blank => {},
            else => return false,
        }
    }
    return true;
}

fn stripTrivia(chunks: []const Chunk) []const Chunk {
    var start: usize = 0;
    var end = chunks.len;
    while (start < end and (chunks[start] == .comment or chunks[start] == .blank)) start += 1;
    while (end > start and (chunks[end - 1] == .comment or chunks[end - 1] == .blank)) end -= 1;
    return chunks[start..end];
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

fn printInto(
    arena: std.mem.Allocator,
    source: []const u8,
    options: Options,
    self_check: bool,
) Error![]const u8 {
    if (options.jsx) return refuse(options, .jsx_source);
    if (std.mem.indexOfScalar(u8, source, '\r') != null) {
        return refuse(options, .carriage_return);
    }

    const tokens = try lex(arena, source, options);
    // A file with no tokens is not an empty file. It is a file of comments,
    // and returning "" here - above the self-check, which would have compared
    // the comment lists and refused - printed a license header as zero bytes
    // and let `--write` truncate it with exit 0.
    if (source.len == 0) return "";

    const regions = try collectRegions(arena, source, options);
    const trivia_items = trivia.collect(arena, source) catch return error.OutOfMemory;

    var builder = Builder{
        .arena = arena,
        .source = source,
        .options = options,
        .tokens = tokens,
        .regions = regions,
        .trivia_items = trivia_items,
    };
    const chunks = try builder.build();
    try markContext(chunks, options);

    var p = Printer{ .arena = arena, .options = options };
    var renderer = Renderer{ .p = &p, .width = options.width };
    try renderer.renderStatements(chunks, 0);

    const out = p.out.items;
    if (self_check) try verify(arena, trivia_items, source, out, options);
    return out;
}

/// The floor under every layout rule: the output must carry the same tokens as
/// the input. A trailing comma before a closer is the one difference the
/// layout rules are allowed to make, so it is normalized away on both sides
/// before the comparison.
fn verify(
    arena: std.mem.Allocator,
    source_trivia: []const trivia.Trivia,
    source: []const u8,
    printed: []const u8,
    options: Options,
) Error!void {
    const before = try significantTokens(arena, source, options);
    const after = try significantTokens(arena, printed, options);
    if (before.len != after.len) return refuse(options, .self_check);
    for (before, after) |a, b| {
        if (a.type != b.type) return refuse(options, .self_check);
        if (!std.mem.eql(u8, a.text, b.text)) return refuse(options, .self_check);
    }

    // The input's trivia was collected to build the chunks; collecting it a
    // second time here would answer a question this function was handed.
    const before_comments = try commentTexts(arena, source, source_trivia);
    const after_comments = try commentTexts(arena, printed, null);
    if (before_comments.len != after_comments.len) return refuse(options, .self_check);
    for (before_comments, after_comments) |a, b| {
        if (!std.mem.eql(u8, a, b)) return refuse(options, .self_check);
    }
}

const SigToken = struct { type: TokenType, text: []const u8 };

fn significantTokens(
    arena: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error![]SigToken {
    var out: std.ArrayListUnmanaged(SigToken) = .empty;
    var tz = Tokenizer.init(source);
    var prev_comma = false;
    while (true) {
        const tok = tz.next();
        if (tok.type == .eof) break;
        if (tok.type == .invalid) return refuse(options, .self_check);
        const text = tok.text(source);
        if (prev_comma and (tok.type == .rparen or tok.type == .rbracket or tok.type == .rbrace)) {
            _ = out.pop();
        }
        prev_comma = tok.type == .comma;
        const normalized = try normalizedTokenText(arena, .{ .tok = tok, .text = text });
        try out.append(arena, .{ .type = tok.type, .text = normalized });
    }
    return out.toOwnedSlice(arena);
}

fn commentTexts(
    arena: std.mem.Allocator,
    source: []const u8,
    collected: ?[]const trivia.Trivia,
) Error![][]const u8 {
    const items = collected orelse
        trivia.collect(arena, source) catch return error.OutOfMemory;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (items) |item| {
        if (item.kind == .blank_line_run) continue;
        try out.append(arena, source[item.start..item.end]);
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn printTest(source: []const u8) ![]u8 {
    return print(testing.allocator, source, .{});
}

fn expectPrints(source: []const u8, expected: []const u8) !void {
    const out = try printTest(source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

fn expectRefusal(source: []const u8, reason: Refusal) !void {
    var got: Refusal = undefined;
    const result = print(testing.allocator, source, .{ .reason_out = &got });
    try testing.expectError(error.UnprintableConstruct, result);
    try testing.expectEqual(reason, got);
}

test "a declaration prints with canonical spacing" {
    try expectPrints("const  x=1;\n", "const x = 1;\n");
}

test "a type annotation is printed as written" {
    try expectPrints(
        "const x: string = \"a\";\n",
        "const x: string = \"a\";\n",
    );
}

test "a type argument list binds to the name in front of it" {
    // `first <string>(names)` keeps every token and stops parsing.
    try expectPrints(
        "const head = first<string>(names);\n",
        "const head = first<string>(names);\n",
    );
}

test "a single-quoted string becomes double-quoted" {
    try expectPrints("const x = 'a';\n", "const x = \"a\";\n");
}

test "a quote inside a converted string is escaped" {
    try expectPrints("const x = 'a\"b';\n", "const x = \"a\\\"b\";\n");
}

test "printing twice is byte identical" {
    const source =
        \\const items = [1, 2, 3];
        \\const total = items.length;
        \\
    ;
    const once = try printTest(source);
    defer testing.allocator.free(once);
    const twice = try print(testing.allocator, once, .{});
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "a statement without a semicolon is refused, not joined" {
    try expectRefusal("const a = 1\nconst b = 2\n", .missing_semicolon);
}

test "a newline after return is refused rather than closed up" {
    // ASI terminates the statement at the newline, so joining the two lines
    // would keep every token and return a different value.
    try expectRefusal("function f() {\n  return\n  1;\n}\n", .missing_semicolon);
}

test "a file of nothing but comments keeps them" {
    // The empty-token early return sat above the self-check, so the comment
    // comparison that would have caught this never ran and `--write`
    // truncated a license header to zero bytes with exit 0.
    try expectPrints("// just a note\n// and another\n", "// just a note\n// and another\n");
}

test "an empty file prints as an empty file" {
    try expectPrints("", "");
}

test "a keyword is not glued to the bracket after it" {
    // `of` and `when` are also property names, and treating them as one
    // everywhere printed `for (const i of[0, 1, 2])`: every token preserved,
    // so the self-check passed and the spelling was mangled.
    try expectPrints(
        "for (const i of [0, 1, 2]) {\n  f(i);\n}\n",
        "for (const i of [0, 1, 2]) {\n  f(i);\n}\n",
    );
}

test "a keyword used as a property name still binds to its call" {
    try expectPrints("const x = a.of(1);\n", "const x = a.of(1);\n");
}

test "a blank line between record fields is kept" {
    const source =
        \\const r = {
        \\  alphaAlphaAlpha: 111111111,
        \\
        \\  betaBetaBeta: 222222222,
        \\  gammaGammaGamma: 333333333,
        \\};
        \\
    ;
    try expectPrints(source, source);
}

test "a comment above a match arm stays above it" {
    const source =
        \\const r = match (v) {
        \\  when string: "s"
        \\  // the numeric arm
        \\  when number: "n"
        \\  default: "o"
        \\};
        \\
    ;
    try expectPrints(source, source);
}

test "a trailing comment after the last element stays on its line" {
    const source =
        \\const items = [
        \\  alphaAlphaAlphaAlpha,
        \\  betaBetaBetaBetaBeta,
        \\  gammaGammaGammaGamma, // the third one
        \\];
        \\
    ;
    try expectPrints(source, source);
}

test "a JSX source is refused" {
    var got: Refusal = undefined;
    const result = print(testing.allocator, "const x = 1;\n", .{ .jsx = true, .reason_out = &got });
    try testing.expectError(error.UnprintableConstruct, result);
    try testing.expectEqual(Refusal.jsx_source, got);
}

test "a comment above a declaration keeps its line" {
    try expectPrints(
        \\// documents x
        \\const x = 1;
        \\
    ,
        \\// documents x
        \\const x = 1;
        \\
    );
}

test "a trailing comment stays on its line" {
    try expectPrints("const x = 1; // about x\n", "const x = 1; // about x\n");
}

test "a blank-line run collapses to one" {
    try expectPrints(
        "const a = 1;\n\n\n\nconst b = 2;\n",
        "const a = 1;\n\nconst b = 2;\n",
    );
}

test "a block body is one statement per line" {
    try expectPrints(
        "function f() { return 1; }\n",
        "function f() {\n  return 1;\n}\n",
    );
}

test "a record that fits stays on one line" {
    try expectPrints(
        "const r = {a: 1, b: 2};\n",
        "const r = { a: 1, b: 2 };\n",
    );
}

test "a record that does not fit takes one field per line and a trailing comma" {
    const source = "const r = { alpha: 111111111, beta: 222222222, gamma: 333333333, delta: 444444 };\n";
    try expectPrints(source,
        \\const r = {
        \\  alpha: 111111111,
        \\  beta: 222222222,
        \\  gamma: 333333333,
        \\  delta: 444444,
        \\};
        \\
    );
}

test "a record one column under the target keeps its line, semicolon included" {
    // The `;` counts: a group measured without what follows it reports a fit
    // it does not have. 80 columns exactly, semicolon included.
    const source = "const r = { alpha: 111111111, beta: 222222222, gamma: 333333333, delta: 44444 };\n";
    try expectPrints(source, source);
}

test "an import clause that does not fit takes one specifier per line" {
    try expectPrints("import { alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota } from \"zttp:env\";\n",
        \\import {
        \\  alpha,
        \\  beta,
        \\  gamma,
        \\  delta,
        \\  epsilon,
        \\  zeta,
        \\  eta,
        \\  theta,
        \\  iota,
        \\} from "zttp:env";
        \\
    );
}

test "match arms take one line each, and the expression drops when it does not fit" {
    try expectPrints("const r = match (v) { when string: \"s\" when number: \"n\" default: \"o\" };\n",
        \\const r = match (v) {
        \\  when string: "s"
        \\  when number: "n"
        \\  default: "o"
        \\};
        \\
    );
}

test "a call hugs a record last argument instead of indenting it twice" {
    try expectPrints("const r = resource(order, { self: { href: \"/orders/42\" }, cancel: { method: \"DELETE\" } });\n",
        \\const r = resource(order, {
        \\  self: { href: "/orders/42" },
        \\  cancel: { method: "DELETE" },
        \\});
        \\
    );
}

test "two record arguments do not hug: only the last one can break" {
    try expectPrints("const r = respond({ error: \"aaaaaaaa\", size: 11111, kind: \"bbbbbbbb\" }, { status: 400111 });\n",
        \\const r = respond(
        \\  { error: "aaaaaaaa", size: 11111, kind: "bbbbbbbb" },
        \\  { status: 400111 },
        \\);
        \\
    );
}

test "a type declaration prints as the author wrote it" {
    // Types are opaque: the stripper decided the span, and re-deciding the
    // layout inside it here would be a second answer to a settled question.
    const source =
        \\structural Shape = {
        \\      kind: string;
        \\  size: number;
        \\};
        \\
        \\const x: Shape = { kind: "a", size: 1 };
        \\
    ;
    try expectPrints(source, source);
}

test "a condition never takes a trailing comma" {
    try expectPrints(
        "if (aaaa) {\n  return 1;\n}\n",
        "if (aaaa) {\n  return 1;\n}\n",
    );
}
