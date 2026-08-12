//! Token definitions for the JavaScript/JSX parser
//!
//! Enhanced tokens with full source location tracking for better error messages.

const std = @import("std");

/// Token types for JavaScript and JSX
pub const TokenType = enum(u8) {
    // Literals
    number,
    string_literal,
    identifier,
    true_lit,
    false_lit,
    null_lit,
    undefined_lit,
    regex_literal,

    // Template literals
    template_literal, // Complete `string`
    template_head, // `string${
    template_middle, // }string${
    template_tail, // }string`

    // Operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    star_star, // **
    plus_plus, // ++
    minus_minus, // --

    // Comparison
    eq, // ==
    eq_eq, // ===
    ne, // !=
    ne_ne, // !==
    lt, // <
    le, // <=
    gt, // >
    ge, // >=

    // Logical & Bitwise
    ampersand, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    ampersand_ampersand, // &&
    pipe_pipe, // ||
    pipe_gt, // |>
    question_question, // ??
    question_dot, // ?.
    bang, // !

    // Shift
    lt_lt, // <<
    gt_gt, // >>
    gt_gt_gt, // >>>

    // Assignment
    assign, // =
    plus_assign, // +=
    minus_assign, // -=
    star_assign, // *=
    slash_assign, // /=
    percent_assign, // %=
    ampersand_assign, // &=
    pipe_assign, // |=
    caret_assign, // ^=
    lt_lt_assign, // <<=
    gt_gt_assign, // >>=
    gt_gt_gt_assign, // >>>=
    star_star_assign, // **=
    ampersand_ampersand_assign, // &&=
    pipe_pipe_assign, // ||=
    question_question_assign, // ??=

    // Punctuation
    lparen, // (
    rparen, // )
    lbrace, // {
    rbrace, // }
    lbracket, // [
    rbracket, // ]
    comma, // ,
    dot, // .
    semicolon, // ;
    colon, // :
    question, // ?
    arrow, // =>
    spread, // ...

    // JSX-specific

    // Keywords
    kw_var,
    kw_let,
    kw_const,
    kw_function,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_do,
    kw_for,
    kw_in,
    kw_of,
    kw_break,
    kw_continue,
    kw_switch,
    kw_case,
    kw_default,
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_new,
    kw_this,
    kw_typeof,
    kw_void,
    kw_delete,
    kw_instanceof,
    kw_yield,
    kw_async,
    kw_await,
    kw_import,
    kw_export,
    kw_from,
    kw_as,
    kw_class,
    kw_extends,
    kw_super,
    kw_static,
    kw_get,
    kw_set,
    kw_debugger,
    kw_with,

    // TypeScript keywords (unsupported but tokenized for detection)
    kw_enum,
    kw_implements,
    kw_public,
    kw_private,
    kw_protected,

    // Match expression keywords
    kw_match,
    kw_when,

    // Assert statement
    kw_assert,

    // Decorator
    at_sign, // @

    // Special
    eof,
    invalid,
};

/// Source location for error reporting
pub const SourceLocation = struct {
    line: u32,
    column: u32,
    offset: u32,
    /// Exclusive end of the token this location names, so a location is a
    /// half-open byte span and not only a point (spec 4.8's diagnostic shape).
    ///
    /// It is the token's own extent, not the enclosing construct's: a node
    /// takes the location of the token that opened it, so a diagnostic about a
    /// `let` binding spans `let` and not the statement. That is what the parser
    /// knows without a second pass, and naming it exactly is better than a
    /// wider span nothing computes.
    ///
    /// A value at or below `offset` means the extent is unknown, which is what
    /// a synthetic or fallback location carries. `span()` reports those as
    /// empty at the point rather than inventing a width.
    end_offset: u32 = 0,

    pub fn span(self: SourceLocation) struct { start: u32, end: u32 } {
        return .{
            .start = self.offset,
            .end = if (self.end_offset > self.offset) self.end_offset else self.offset,
        };
    }

    pub fn format(self: SourceLocation, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{ self.line, self.column });
    }
};

/// Token with full location information
pub const Token = struct {
    type: TokenType,
    start: u32, // Byte offset in source
    len: u32, // Token length in bytes
    line: u32, // 1-indexed line number
    column: u32, // 1-indexed column number
    /// Set on a `.number` token whose digits contained a `_`. The tokenizer is
    /// already examining each byte, so recording it there costs nothing, and it
    /// saves the parser a second walk of the token text to decide whether the
    /// separator is allowed in the current profile. Lands in the struct's
    /// existing tail padding: `Token` is 20 bytes with and without it.
    has_separator: bool = false,

    /// Get the text of this token from the source
    pub fn text(self: Token, source: []const u8) []const u8 {
        const end = @min(self.start + self.len, source.len);
        return source[self.start..end];
    }

    /// Get a SourceLocation for this token
    pub fn location(self: Token) SourceLocation {
        return .{
            .line = self.line,
            .column = self.column,
            .offset = self.start,
            .end_offset = self.start + self.len,
        };
    }

    /// Create a "synthetic" token at a location (for error recovery)
    pub fn synthetic(token_type: TokenType, loc: SourceLocation) Token {
        return .{
            .type = token_type,
            .start = loc.offset,
            .len = 0,
            .line = loc.line,
            .column = loc.column,
        };
    }

    /// Check if this token is a keyword
    pub fn isKeyword(self: Token) bool {
        // kw_assert is declared after kw_when, so the upper bound must be
        // kw_assert (the last keyword) or this would wrongly exclude `assert`.
        return @intFromEnum(self.type) >= @intFromEnum(TokenType.kw_var) and
            @intFromEnum(self.type) <= @intFromEnum(TokenType.kw_assert);
    }
};

/// Keyword lookup table
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "var", .kw_var },
    .{ "let", .kw_let },
    .{ "const", .kw_const },
    .{ "function", .kw_function },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "do", .kw_do },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "of", .kw_of },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "switch", .kw_switch },
    .{ "case", .kw_case },
    .{ "default", .kw_default },
    .{ "throw", .kw_throw },
    .{ "try", .kw_try },
    .{ "catch", .kw_catch },
    .{ "finally", .kw_finally },
    .{ "new", .kw_new },
    .{ "this", .kw_this },
    .{ "typeof", .kw_typeof },
    .{ "void", .kw_void },
    .{ "delete", .kw_delete },
    .{ "instanceof", .kw_instanceof },
    .{ "yield", .kw_yield },
    .{ "async", .kw_async },
    .{ "await", .kw_await },
    .{ "import", .kw_import },
    .{ "export", .kw_export },
    .{ "from", .kw_from },
    .{ "as", .kw_as },
    .{ "class", .kw_class },
    .{ "extends", .kw_extends },
    .{ "super", .kw_super },
    .{ "static", .kw_static },
    .{ "get", .kw_get },
    .{ "set", .kw_set },
    .{ "debugger", .kw_debugger },
    .{ "with", .kw_with },
    .{ "enum", .kw_enum },
    .{ "implements", .kw_implements },
    .{ "public", .kw_public },
    .{ "private", .kw_private },
    .{ "protected", .kw_protected },
    .{ "match", .kw_match },
    .{ "when", .kw_when },
    .{ "assert", .kw_assert },
    .{ "true", .true_lit },
    .{ "false", .false_lit },
    .{ "null", .null_lit },
    .{ "undefined", .undefined_lit },
});

/// Look up a keyword from an identifier string
pub fn lookupKeyword(ident: []const u8) ?TokenType {
    return keywords.get(ident);
}

test "token text extraction" {
    const source = "let x = 42;";
    const tok = Token{
        .type = .kw_let,
        .start = 0,
        .len = 3,
        .line = 1,
        .column = 1,
    };
    try std.testing.expectEqualStrings("let", tok.text(source));
}

test "keyword lookup" {
    try std.testing.expectEqual(TokenType.kw_function, lookupKeyword("function").?);
    try std.testing.expectEqual(TokenType.kw_const, lookupKeyword("const").?);
    try std.testing.expectEqual(TokenType.true_lit, lookupKeyword("true").?);
    try std.testing.expect(lookupKeyword("notakeyword") == null);
}

test "token location" {
    const tok = Token{
        .type = .identifier,
        .start = 10,
        .len = 5,
        .line = 2,
        .column = 3,
    };
    const loc = tok.location();
    try std.testing.expectEqual(@as(u32, 2), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.column);
    try std.testing.expectEqual(@as(u32, 10), loc.offset);
}
