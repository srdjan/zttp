//! Tokenizer for the core JavaScript syntax consumed by the ZTS parser.
//!
//! Single-pass tokenization with column tracking and lookahead for arrow
//! function detection.

const std = @import("std");
const token = @import("token.zig");

pub const Token = token.Token;
pub const TokenType = token.TokenType;
pub const SourceLocation = token.SourceLocation;
pub const lookupKeyword = token.lookupKeyword;

pub const TriviaObservation = union(enum) {
    unterminated_comment: struct {
        opener: u32,
        @"resume": u32,
    },
};

/// An interval that the source producer erases before runtime recovery.
/// The recovery operation owns this storage. Scanner calls borrow it.
pub const RecoveryErasure = struct {
    start: u32,
    end: u32,
};

/// Tokenizer state
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,

    /// Whether we just saw a token that could precede a regex
    can_be_regex: bool,

    /// Template literal depth
    template_depth: u8,

    /// Brace nesting depth within each template substitution level.
    /// subst_brace_depths[d] counts unmatched '{' seen after the '${' that
    /// opened substitution depth d+1. A '}' only closes the substitution
    /// (routing to scanTemplateMiddleOrTail) when the depth for that level is 0.
    /// A u16 counts exactly past the parser's nesting limit of 512. The count
    /// saturates at 65535 instead of overflowing, because a u8 panicked in safe
    /// builds on 256 unmatched braces and the parser refuses that nesting anyway.
    subst_brace_depths: [16]u16,

    /// Cached token for lookahead
    current: Token,
    has_current: bool,

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .can_be_regex = true,
            .template_depth = 0,
            .subst_brace_depths = [_]u16{0} ** 16,
            .current = undefined,
            .has_current = false,
        };
    }

    /// Get the current column number (1-indexed)
    pub fn column(self: *const Tokenizer) u32 {
        return self.pos - self.line_start + 1;
    }

    /// Get the next token
    pub fn next(self: *Tokenizer) Token {
        return self.nextWithObservation(null);
    }

    /// Get the next committed token and report terminal trivia.
    pub fn nextObserved(self: *Tokenizer, observation: *?TriviaObservation) Token {
        observation.* = null;
        return self.nextWithObservation(observation);
    }

    /// Rescan a proven misaligned recovery string through admitted erasures.
    /// The token must come from this source. Intervals remain borrowed.
    pub fn rescanRecoveryString(self: *Tokenizer, token_value: Token, erasures: []const RecoveryErasure) !Token {
        const end = std.math.add(u32, token_value.start, token_value.len) catch return error.InvalidRecoveryErasure;
        if (token_value.type != .string_literal or token_value.len == 0 or @as(usize, end) > self.source.len or
            token_value.line == 0 or token_value.column == 0 or token_value.start < token_value.column - 1 or
            (self.source[token_value.start] != '\'' and self.source[token_value.start] != '"'))
        {
            return error.InvalidRecoveryErasure;
        }
        var previous_end: u32 = 0;
        for (erasures) |span| {
            if (span.start >= span.end or @as(usize, span.end) > self.source.len or
                span.start < previous_end or (span.start <= token_value.start and token_value.start < span.end))
            {
                return error.InvalidRecoveryErasure;
            }
            previous_end = span.end;
        }
        self.pos = token_value.start + 1;
        self.line = token_value.line;
        self.line_start = token_value.start - (token_value.column - 1);
        self.has_current = false;
        const rescanned = self.scanStringCore(self.source[token_value.start], token_value.start, token_value.column, token_value.line, erasures);
        self.updateRegexState(rescanned.type);
        return rescanned;
    }

    fn nextWithObservation(
        self: *Tokenizer,
        observation: ?*?TriviaObservation,
    ) Token {
        if (self.skipWhitespaceAndComments(observation)) {
            return self.makeToken(.eof, 0);
        }

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, 0);
        }

        const start = self.pos;
        const start_col = self.column();
        const start_line = self.line;
        const c = self.advance();

        const tok = switch (c) {
            '(' => self.tok1(start, start_col, start_line, .lparen),
            ')' => self.tok1(start, start_col, start_line, .rparen),
            '[' => self.tok1(start, start_col, start_line, .lbracket),
            ']' => self.tok1(start, start_col, start_line, .rbracket),
            ',' => self.tok1(start, start_col, start_line, .comma),
            ';' => self.tok1(start, start_col, start_line, .semicolon),
            ':' => self.tok1(start, start_col, start_line, .colon),
            '~' => self.tok1(start, start_col, start_line, .tilde),

            '{' => blk: {
                // Track nested braces within template substitutions so that a
                // '}' closing an object literal or block is not mistaken for
                // the end of the ${...} substitution.
                if (self.template_depth > 0 and self.template_depth <= 16) {
                    self.subst_brace_depths[self.template_depth - 1] +|= 1;
                }
                break :blk self.tok1(start, start_col, start_line, .lbrace);
            },
            '}' => blk: {
                if (self.template_depth > 0) {
                    const depth_idx = self.template_depth - 1;
                    if (depth_idx < 16 and self.subst_brace_depths[depth_idx] > 0) {
                        // This '}' closes a nested brace within the substitution,
                        // not the substitution itself.
                        self.subst_brace_depths[depth_idx] -= 1;
                        break :blk self.tok1(start, start_col, start_line, .rbrace);
                    }
                    // The '}' closes the '${' substitution. Reset the depth entry
                    // and scan the template middle or tail.
                    if (depth_idx < 16) self.subst_brace_depths[depth_idx] = 0;
                    break :blk self.scanTemplateMiddleOrTail(start, start_col, start_line);
                }
                break :blk self.tok1(start, start_col, start_line, .rbrace);
            },

            '?' => self.scanQuestion(start, start_col, start_line),
            '+' => self.scanPlus(start, start_col, start_line),
            '-' => self.scanMinus(start, start_col, start_line),
            '*' => self.scanStar(start, start_col, start_line),
            '/' => self.scanSlash(start, start_col, start_line),
            '%' => self.scanPercent(start, start_col, start_line),
            '=' => self.scanEquals(start, start_col, start_line),
            '!' => self.scanBang(start, start_col, start_line),
            '<' => self.scanLessThan(start, start_col, start_line),
            '>' => self.scanGreaterThan(start, start_col, start_line),
            '&' => self.scanAmpersand(start, start_col, start_line),
            '|' => self.scanPipe(start, start_col, start_line),
            '^' => self.scanCaret(start, start_col, start_line),
            '.' => self.scanDot(start, start_col, start_line),

            '"', '\'' => self.scanString(c, start, start_col, start_line),
            '`' => self.scanTemplateLiteral(start, start_col, start_line),
            '0'...'9' => self.scanNumber(start, start_col, start_line),

            '@' => self.tok1(start, start_col, start_line, .at_sign),

            else => blk: {
                if (isIdentifierStart(c)) {
                    break :blk self.scanIdentifier(start, start_col, start_line);
                }
                // A byte above ASCII is one token, not one per byte. One
                // character outside ASCII is two or three bytes in UTF-8, and
                // emitting an `invalid` token for each made the parser report
                // the same fault two or three times over. The run also absorbs
                // the ASCII identifier characters around it, so `caf` + `é` is
                // one token rather than an identifier followed by a fault.
                if (c >= 0x80) {
                    while (self.pos < self.source.len and
                        (self.source[self.pos] >= 0x80 or isIdentifierChar(self.source[self.pos])))
                    {
                        self.pos += 1;
                    }
                    break :blk self.tokN(start, start_col, start_line, .invalid);
                }
                break :blk self.tok1(start, start_col, start_line, .invalid);
            },
        };

        self.updateRegexState(tok.type);
        return tok;
    }

    // --- Token constructors ---

    fn tok1(self: *const Tokenizer, start: u32, col: u32, line: u32, t: TokenType) Token {
        _ = self;
        return .{ .type = t, .start = start, .len = 1, .line = line, .column = col };
    }

    fn tok2(self: *const Tokenizer, start: u32, col: u32, line: u32, t: TokenType) Token {
        _ = self;
        return .{ .type = t, .start = start, .len = 2, .line = line, .column = col };
    }

    fn tok3(self: *const Tokenizer, start: u32, col: u32, line: u32, t: TokenType) Token {
        _ = self;
        return .{ .type = t, .start = start, .len = 3, .line = line, .column = col };
    }

    fn tok4(self: *const Tokenizer, start: u32, col: u32, line: u32, t: TokenType) Token {
        _ = self;
        return .{ .type = t, .start = start, .len = 4, .line = line, .column = col };
    }

    fn tokN(self: *const Tokenizer, start: u32, col: u32, line: u32, t: TokenType) Token {
        return .{ .type = t, .start = start, .len = self.pos - start, .line = line, .column = col };
    }

    // --- Operator scanning ---

    fn scanQuestion(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('?')) {
            if (self.match('=')) return self.tok3(start, col, line, .question_question_assign);
            return self.tok2(start, col, line, .question_question);
        }
        if (self.match('.')) {
            if (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos -= 1;
                return self.tok1(start, col, line, .question);
            }
            return self.tok2(start, col, line, .question_dot);
        }
        return self.tok1(start, col, line, .question);
    }

    fn scanPlus(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('+')) return self.tok2(start, col, line, .plus_plus);
        if (self.match('=')) return self.tok2(start, col, line, .plus_assign);
        return self.tok1(start, col, line, .plus);
    }

    fn scanMinus(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('-')) return self.tok2(start, col, line, .minus_minus);
        if (self.match('=')) return self.tok2(start, col, line, .minus_assign);
        return self.tok1(start, col, line, .minus);
    }

    fn scanStar(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('*')) {
            if (self.match('=')) return self.tok3(start, col, line, .star_star_assign);
            return self.tok2(start, col, line, .star_star);
        }
        if (self.match('=')) return self.tok2(start, col, line, .star_assign);
        return self.tok1(start, col, line, .star);
    }

    fn scanSlash(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('=')) return self.tok2(start, col, line, .slash_assign);
        if (self.can_be_regex) {
            if (self.scanRegexLiteral(start, col, line)) |tok| {
                return tok;
            }
        }
        // RegExp literals not supported - treat / as division when not a regex
        return self.tok1(start, col, line, .slash);
    }

    fn scanPercent(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('=')) return self.tok2(start, col, line, .percent_assign);
        return self.tok1(start, col, line, .percent);
    }

    fn scanEquals(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('=')) {
            if (self.match('=')) return self.tok3(start, col, line, .eq_eq);
            return self.tok2(start, col, line, .eq);
        }
        if (self.match('>')) return self.tok2(start, col, line, .arrow);
        return self.tok1(start, col, line, .assign);
    }

    fn scanBang(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('=')) {
            if (self.match('=')) return self.tok3(start, col, line, .ne_ne);
            return self.tok2(start, col, line, .ne);
        }
        return self.tok1(start, col, line, .bang);
    }

    fn scanLessThan(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('<')) {
            if (self.match('=')) return self.tok3(start, col, line, .lt_lt_assign);
            return self.tok2(start, col, line, .lt_lt);
        }
        if (self.match('=')) return self.tok2(start, col, line, .le);
        return self.tok1(start, col, line, .lt);
    }

    fn scanGreaterThan(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('>')) {
            if (self.match('>')) {
                if (self.match('=')) return self.tok4(start, col, line, .gt_gt_gt_assign);
                return self.tok3(start, col, line, .gt_gt_gt);
            }
            if (self.match('=')) return self.tok3(start, col, line, .gt_gt_assign);
            return self.tok2(start, col, line, .gt_gt);
        }
        if (self.match('=')) return self.tok2(start, col, line, .ge);
        return self.tok1(start, col, line, .gt);
    }

    fn scanRegexLiteral(self: *Tokenizer, start: u32, col: u32, line: u32) ?Token {
        const saved = self.saveState();
        var in_class = false;
        var escaped = false;

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r') {
                self.restoreState(saved);
                return null;
            }
            self.pos += 1;

            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '[') {
                in_class = true;
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                continue;
            }
            if (c == '/' and !in_class) {
                // Optional flags
                while (self.pos < self.source.len) {
                    const f = self.source[self.pos];
                    if (std.ascii.isAlphabetic(f)) {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                const len = self.pos - start;
                return .{ .type = .regex_literal, .start = start, .len = len, .line = line, .column = col };
            }
        }

        self.restoreState(saved);
        return null;
    }

    fn scanAmpersand(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('&')) {
            if (self.match('=')) return self.tok3(start, col, line, .ampersand_ampersand_assign);
            return self.tok2(start, col, line, .ampersand_ampersand);
        }
        if (self.match('=')) return self.tok2(start, col, line, .ampersand_assign);
        return self.tok1(start, col, line, .ampersand);
    }

    fn scanPipe(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('|')) {
            if (self.match('=')) return self.tok3(start, col, line, .pipe_pipe_assign);
            return self.tok2(start, col, line, .pipe_pipe);
        }
        if (self.match('>')) return self.tok2(start, col, line, .pipe_gt);
        if (self.match('=')) return self.tok2(start, col, line, .pipe_assign);
        return self.tok1(start, col, line, .pipe);
    }

    fn scanCaret(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        if (self.match('=')) return self.tok2(start, col, line, .caret_assign);
        return self.tok1(start, col, line, .caret);
    }

    fn scanDot(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        // `...` spread. Peek both following dots before consuming: the previous
        // `match('.') and match('.')` form consumed the first dot via the
        // short-circuited && even when the second failed, so `..` silently lost
        // its second dot (token reported len 1 while pos advanced 2).
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
            self.pos += 2;
            return self.tok3(start, col, line, .spread);
        }
        if (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            return self.scanNumber(start, col, line);
        }
        return self.tok1(start, col, line, .dot);
    }

    // --- Literal scanning ---

    fn stringToken(self: *const Tokenizer, start: u32, col: u32, line: u32, kind: TokenType, has_escape: bool) Token {
        var result = self.tokN(start, col, line, kind);
        result.has_escape = has_escape;
        return result;
    }

    fn scanString(self: *Tokenizer, quote: u8, start: u32, col: u32, line: u32) Token {
        return self.scanStringCore(quote, start, col, line, &.{});
    }

    fn scanStringCore(self: *Tokenizer, quote: u8, start: u32, col: u32, line: u32, erasures: []const RecoveryErasure) Token {
        var erasure_index: usize = 0;
        var has_escape = false;
        while (self.pos < self.source.len) {
            const byte = self.recoveryByte(self.pos, erasures, &erasure_index);
            if (byte == quote) break;
            if (byte == '\\' and self.pos + 1 < self.source.len) {
                has_escape = true;
                if (self.recoveryByte(self.pos + 1, erasures, &erasure_index) == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 2;
                }
                self.pos += 2;
            } else {
                // Recovery erases bytes only for scanning. Consumers still
                // decode the original token slice, including its backslashes.
                if (erasures.len > 0 and self.source[self.pos] == '\\') has_escape = true;
                if (byte == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 1;
                }
                self.pos += 1;
            }
        }
        if (self.pos < self.source.len) self.pos += 1;
        return self.stringToken(start, col, line, .string_literal, has_escape);
    }

    fn recoveryByte(self: *const Tokenizer, offset: u32, erasures: []const RecoveryErasure, index: *usize) u8 {
        while (index.* < erasures.len and erasures[index.*].end <= offset) index.* += 1;
        const byte = self.source[offset];
        if (index.* < erasures.len and erasures[index.*].start <= offset and byte != '\n') return ' ';
        return byte;
    }

    fn scanTemplateLiteral(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        var has_escape = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '`') {
                self.pos += 1;
                return self.stringToken(start, col, line, .template_literal, has_escape);
            } else if (c == '$' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                self.pos += 2;
                self.template_depth +|= 1;
                return self.stringToken(start, col, line, .template_head, has_escape);
            } else if (c == '\\' and self.pos + 1 < self.source.len) {
                has_escape = true;
                if (self.source[self.pos + 1] == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 2;
                }
                self.pos += 2;
            } else {
                if (c == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 1;
                }
                self.pos += 1;
            }
        }
        return self.stringToken(start, col, line, .template_literal, has_escape);
    }

    fn scanTemplateMiddleOrTail(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        var has_escape = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '`') {
                self.pos += 1;
                self.template_depth -|= 1;
                return self.stringToken(start, col, line, .template_tail, has_escape);
            } else if (c == '$' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                self.pos += 2;
                return self.stringToken(start, col, line, .template_middle, has_escape);
            } else if (c == '\\' and self.pos + 1 < self.source.len) {
                has_escape = true;
                if (self.source[self.pos + 1] == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 2;
                }
                self.pos += 2;
            } else {
                if (c == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 1;
                }
                self.pos += 1;
            }
        }
        self.template_depth -|= 1;
        return self.stringToken(start, col, line, .template_tail, has_escape);
    }

    /// Advance over a run of digits accepted by `accept`, treating `_` as a
    /// separator between them and reporting whether one was seen. The `_` test
    /// is the same comparison the old `accept(c) or c == '_'` condition made, so
    /// recording it is free.
    fn scanDigitRun(self: *Tokenizer, comptime accept: fn (u8) bool) bool {
        var saw_separator = false;
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (accept(c)) continue;
            if (c != '_') break;
            saw_separator = true;
        }
        return saw_separator;
    }

    /// A `_` between digits is always lexed into the number token in both
    /// parser profiles, and the token records that it was there. The internal
    /// expression profile strips separators, while a program rejects them. Stopping the scan at
    /// the `_` instead would split `1_000` into the number `1` and the identifier
    /// `_000`, which ASI accepts as two statements and no diagnostic ever reports.
    fn scanNumber(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        var saw_separator = false;

        // Handle hex, octal, binary
        if (start < self.source.len and self.source[start] == '0' and self.pos < self.source.len) {
            const next_char = self.source[self.pos];
            if (next_char == 'x' or next_char == 'X') {
                self.pos += 1;
                return self.numberToken(start, col, line, self.scanDigitRun(isHexDigit));
            }
            if (next_char == 'b' or next_char == 'B') {
                self.pos += 1;
                return self.numberToken(start, col, line, self.scanDigitRun(isBinaryDigit));
            }
            if (next_char == 'o' or next_char == 'O') {
                self.pos += 1;
                return self.numberToken(start, col, line, self.scanDigitRun(isOctalDigit));
            }
        }

        saw_separator = self.scanDigitRun(isDigit);

        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                self.pos += 1;
                saw_separator = self.scanDigitRun(isDigit) or saw_separator;
            }
        }

        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) self.pos += 1;
        }

        return self.numberToken(start, col, line, saw_separator);
    }

    fn numberToken(self: *const Tokenizer, start: u32, col: u32, line: u32, has_separator: bool) Token {
        var result = self.tokN(start, col, line, .number);
        result.has_separator = has_separator;
        return result;
    }

    fn scanIdentifier(self: *Tokenizer, start: u32, col: u32, line: u32) Token {
        while (self.pos < self.source.len and isIdentifierChar(self.source[self.pos])) self.pos += 1;

        // A byte above ASCII where the identifier ends belongs to the same
        // name a reader sees: `café` is one identifier on the page, so it is
        // one token here rather than `caf` followed by a fault. Reporting the
        // fault against the whole name is what lets the parser say what is
        // wrong instead of reporting that `=` was expected.
        if (self.pos < self.source.len and self.source[self.pos] >= 0x80) {
            while (self.pos < self.source.len and
                (self.source[self.pos] >= 0x80 or isIdentifierChar(self.source[self.pos])))
            {
                self.pos += 1;
            }
            return self.tokN(start, col, line, .invalid);
        }

        const text = self.source[start..self.pos];
        const token_type = lookupKeyword(text) orelse .identifier;
        return self.tokN(start, col, line, token_type);
    }

    // --- Utility ---

    fn advance(self: *Tokenizer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn match(self: *Tokenizer, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn makeToken(self: *const Tokenizer, token_type: TokenType, len: u32) Token {
        return .{
            .type = token_type,
            .start = self.pos - len,
            .len = len,
            .line = self.line,
            .column = if (self.pos >= self.line_start + len) self.pos - self.line_start - len + 1 else 1,
        };
    }

    fn skipWhitespaceAndComments(
        self: *Tokenizer,
        observation: ?*?TriviaObservation,
    ) bool {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                },
                '/' => {
                    if (self.pos + 1 < self.source.len) {
                        if (self.source[self.pos + 1] == '/') {
                            self.pos += 2;
                            while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                        } else if (self.source[self.pos + 1] == '*') {
                            const opener = self.pos;
                            self.pos += 2;
                            var terminated = false;
                            while (self.pos + 1 < self.source.len) {
                                if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                                    self.pos += 2;
                                    terminated = true;
                                    break;
                                }
                                if (self.source[self.pos] == '\n') {
                                    self.line += 1;
                                    self.line_start = self.pos + 1;
                                }
                                self.pos += 1;
                            }
                            if (!terminated) {
                                if (observation) |output| {
                                    output.* = .{ .unterminated_comment = .{
                                        .opener = opener,
                                        .@"resume" = self.pos,
                                    } };
                                    return true;
                                }
                            }
                        } else return false;
                    } else return false;
                },
                else => return false,
            }
        }
        return false;
    }

    fn updateRegexState(self: *Tokenizer, tok_type: TokenType) void {
        self.can_be_regex = switch (tok_type) {
            .lparen,
            .lbracket,
            .lbrace,
            .comma,
            .semicolon,
            .colon,
            .question,
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
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .star_star,
            .lt,
            .le,
            .gt,
            .ge,
            .eq,
            .ne,
            .eq_eq,
            .ne_ne,
            .ampersand,
            .pipe,
            .caret,
            .ampersand_ampersand,
            .pipe_pipe,
            .question_question,
            .bang,
            .tilde,
            .kw_return,
            .kw_throw,
            .kw_new,
            .kw_typeof,
            .kw_void,
            .kw_delete,
            .kw_in,
            .kw_instanceof,
            .kw_case,
            .arrow,
            => true,
            else => false,
        };
    }

    /// Resume at the end of source bytes that another parser erased.
    ///
    /// The caller passes a tokenizer copy taken immediately after the current
    /// keyword. The erased bytes must not affect lexical state. Only their LF
    /// bytes affect the position of the next surviving token.
    pub fn resumeAfterRawErasure(
        self: *Tokenizer,
        raw_end: u32,
        previous_runtime_token: Token,
    ) void {
        std.debug.assert(self.pos <= raw_end);
        std.debug.assert(@as(usize, raw_end) <= self.source.len);
        self.advanceRawPosition(raw_end);

        const previous_is_initial = previous_runtime_token.type == .eof and
            previous_runtime_token.start == 0 and
            previous_runtime_token.len == 0 and
            previous_runtime_token.line == 1 and
            previous_runtime_token.column == 1;
        if (previous_is_initial) {
            self.can_be_regex = true;
        } else {
            self.updateRegexState(previous_runtime_token.type);
        }
    }

    /// Resume after a raw scanner consumed the complete template that produced
    /// `token`. The current tokenizer state is immediately after its `${`.
    pub fn resumeAfterRawTemplate(self: *Tokenizer, token_value: Token, raw_end: u32) void {
        std.debug.assert(token_value.type == .template_head);
        std.debug.assert(@as(usize, token_value.start) < self.source.len);
        std.debug.assert(self.source[token_value.start] == '`');
        std.debug.assert(self.pos <= raw_end);
        std.debug.assert(@as(usize, raw_end) <= self.source.len);
        std.debug.assert(self.template_depth > 0);

        const depth_index = self.template_depth - 1;
        if (depth_index < self.subst_brace_depths.len) {
            self.subst_brace_depths[depth_index] = 0;
        }
        self.template_depth -= 1;
        self.advanceRawPosition(raw_end);
        self.updateRegexState(.template_tail);
    }

    /// Rewind a string token and resume at its first unescaped LF. The caller
    /// supplies the runtime token that precedes the malformed string.
    pub fn resumeMalformedStringAt(
        self: *Tokenizer,
        token_value: Token,
        raw_resume: u32,
        previous_runtime_token: Token,
    ) void {
        std.debug.assert(token_value.type == .string_literal);
        std.debug.assert(raw_resume >= token_value.start);
        std.debug.assert(raw_resume < token_value.start + token_value.len);
        std.debug.assert(@as(usize, raw_resume) < self.source.len);
        std.debug.assert(self.source[raw_resume] == '\n');

        self.pos = token_value.start;
        self.line = token_value.line;
        self.line_start = token_value.start -| (token_value.column -| 1);
        self.resumeAfterRawErasure(raw_resume, previous_runtime_token);
    }

    fn advanceRawPosition(self: *Tokenizer, raw_end: u32) void {
        while (self.pos < raw_end) {
            const byte = self.source[self.pos];
            self.pos += 1;
            if (byte == '\n') {
                self.line += 1;
                self.line_start = self.pos;
            }
        }
    }

    /// Save state for lookahead
    pub fn saveState(self: *const Tokenizer) TokenizerState {
        return .{
            .pos = self.pos,
            .line = self.line,
            .line_start = self.line_start,
            .can_be_regex = self.can_be_regex,
            .template_depth = self.template_depth,
            .subst_brace_depths = self.subst_brace_depths,
        };
    }

    /// Restore state
    pub fn restoreState(self: *Tokenizer, state: TokenizerState) void {
        self.pos = state.pos;
        self.line = state.line;
        self.line_start = state.line_start;
        self.can_be_regex = state.can_be_regex;
        self.template_depth = state.template_depth;
        self.subst_brace_depths = state.subst_brace_depths;
    }
};

pub const TokenizerState = struct {
    pos: u32,
    line: u32,
    line_start: u32,
    can_be_regex: bool,
    template_depth: u8,
    // Saved so a single-token lookahead that crosses a '{' or '}' inside a
    // template substitution does not permanently corrupt the brace-depth
    // counters when the lookahead is rewound via restoreState.
    subst_brace_depths: [16]u16,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentifierChar(c: u8) bool {
    return isIdentifierStart(c) or isDigit(c);
}

// --- Tests ---

test "basic tokenization" {
    var tokenizer = Tokenizer.init("let x = 42;");

    const let_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_let, let_tok.type);
    try std.testing.expectEqual(@as(u32, 1), let_tok.line);

    const x_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, x_tok.type);
    try std.testing.expectEqualStrings("x", x_tok.text("let x = 42;"));

    const eq_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.assign, eq_tok.type);

    const num_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.number, num_tok.type);

    const semi_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.semicolon, semi_tok.type);

    const eof_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.eof, eof_tok.type);
}

test "template literals" {
    var tokenizer = Tokenizer.init("`hello ${name}!`");

    const head = tokenizer.next();
    try std.testing.expectEqual(TokenType.template_head, head.type);

    const name_tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, name_tok.type);

    const tail = tokenizer.next();
    try std.testing.expectEqual(TokenType.template_tail, tail.type);
}

test "string escape flags survive lookahead and recovery rescanning" {
    const cases = [_]struct { text: []const u8, escaped: bool }{
        .{ .text = "\"plain\" next", .escaped = false },
        .{ .text = "'plain' next", .escaped = false },
        .{ .text = "\"line\\nvalue\" next", .escaped = true },
        .{ .text = "\"\\\\\" next", .escaped = true },
        .{ .text = "`plain` next", .escaped = false },
        .{ .text = "`line\\nvalue` next", .escaped = true },
        .{ .text = "\"\\u{1F600}\" next", .escaped = true },
    };
    for (cases) |case| {
        var tokenizer = Tokenizer.init(case.text);
        const state = tokenizer.saveState();
        const first = tokenizer.next();
        try std.testing.expectEqual(case.escaped, first.has_escape);
        tokenizer.restoreState(state);
        try std.testing.expectEqualDeep(first, tokenizer.next());
        const next = tokenizer.next();
        try std.testing.expectEqual(TokenType.identifier, next.type);
        try std.testing.expect(!next.has_escape);
    }
    var recovery = Tokenizer.init("\"a\\qb\"");
    const raw = recovery.next();
    const rescanned = try recovery.rescanRecoveryString(raw, &.{.{ .start = 2, .end = 4 }});
    try std.testing.expect(rescanned.has_escape);
    try std.testing.expectEqualDeep(raw, rescanned);
}

test "arrow functions" {
    var tokenizer = Tokenizer.init("(x) => x * 2");

    try std.testing.expectEqual(TokenType.lparen, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.identifier, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.rparen, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.arrow, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.identifier, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.star, tokenizer.next().type);
    try std.testing.expectEqual(TokenType.number, tokenizer.next().type);
}

test "column tracking" {
    var tokenizer = Tokenizer.init("let x");

    const let_tok = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 1), let_tok.column);

    const x_tok = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 5), x_tok.column);
}

test "multiline column tracking" {
    var tokenizer = Tokenizer.init("a\nb");

    const a_tok = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 1), a_tok.line);
    try std.testing.expectEqual(@as(u32, 1), a_tok.column);

    const b_tok = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 2), b_tok.line);
    try std.testing.expectEqual(@as(u32, 1), b_tok.column);
}

test "long identifier length and column do not truncate" {
    const allocator = std.testing.allocator;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendNTimes(allocator, ' ', 70_000);
    try source.appendNTimes(allocator, 'x', 70_000);

    var tokenizer = Tokenizer.init(source.items);
    const tok = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, tok.type);
    try std.testing.expectEqual(@as(u32, 70_001), tok.column);
    try std.testing.expectEqual(@as(u32, 70_000), tok.len);
}

test "state save and restore" {
    var tokenizer = Tokenizer.init("a b c");

    _ = tokenizer.next(); // a
    const state = tokenizer.saveState();

    _ = tokenizer.next(); // b
    _ = tokenizer.next(); // c

    tokenizer.restoreState(state);
    const b_tok = tokenizer.next();
    try std.testing.expectEqualStrings("b", b_tok.text("a b c"));
}

test "raw erasure resumes inside a comment at the exact surviving token" {
    const source = "import type { A } /* ; */ from \"./a\";";
    var tokenizer = Tokenizer.init(source);
    const keyword = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_import, keyword.type);

    const raw_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').? + 1);
    const initial = Token.synthetic(.eof, .{
        .line = 1,
        .column = 1,
        .offset = 0,
    });
    tokenizer.resumeAfterRawErasure(raw_end, initial);

    const surviving = tokenizer.next();
    try std.testing.expectEqual(TokenType.star, surviving.type);
    try std.testing.expectEqual(@as(u32, 1), surviving.line);
    try std.testing.expectEqual(@as(u32, 24), surviving.column);
}

test "raw erasure preserves opaque lexical and cached state" {
    const source = "`head${export type { `opaque;${value}` /re/ { } };}\nnext";
    var tokenizer = Tokenizer.init(source);
    try std.testing.expectEqual(TokenType.template_head, tokenizer.next().type);
    const keyword = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_export, keyword.type);

    tokenizer.current = keyword;
    tokenizer.has_current = true;
    const template_depth = tokenizer.template_depth;
    const subst_brace_depths = tokenizer.subst_brace_depths;
    const cached = tokenizer.current;
    const has_cached = tokenizer.has_current;
    const raw_end: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source, ';').? + 1);

    tokenizer.resumeAfterRawErasure(raw_end, keyword);

    try std.testing.expectEqual(template_depth, tokenizer.template_depth);
    try std.testing.expectEqualSlices(u16, &subst_brace_depths, &tokenizer.subst_brace_depths);
    try std.testing.expect(std.meta.eql(cached, tokenizer.current));
    try std.testing.expectEqual(has_cached, tokenizer.has_current);
}

test "raw erasure advances LF positions without parsing opaque bytes" {
    const source = "import type opaque\n{ /ignored/ }\n;\nnext";
    var tokenizer = Tokenizer.init(source);
    const keyword = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_import, keyword.type);

    const raw_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').? + 1);
    var previous_tokenizer = Tokenizer.init(";");
    const previous = previous_tokenizer.next();
    tokenizer.resumeAfterRawErasure(raw_end, previous);

    const surviving = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, surviving.type);
    try std.testing.expectEqualStrings("next", surviving.text(source));
    try std.testing.expectEqual(@as(u32, 4), surviving.line);
    try std.testing.expectEqual(@as(u32, 1), surviving.column);
}

test "raw erasure restores regex eligibility from the runtime predecessor" {
    const source = "import type opaque;/abc/;";
    const raw_end: u32 = @intCast(std.mem.indexOfScalar(u8, source, ';').? + 1);

    var previous_semicolon_tokenizer = Tokenizer.init(";");
    const previous_semicolon = previous_semicolon_tokenizer.next();
    var after_semicolon = Tokenizer.init(source);
    _ = after_semicolon.next();
    after_semicolon.resumeAfterRawErasure(raw_end, previous_semicolon);
    try std.testing.expectEqual(TokenType.regex_literal, after_semicolon.next().type);

    var previous_identifier_tokenizer = Tokenizer.init("name");
    const previous_identifier = previous_identifier_tokenizer.next();
    var after_identifier = Tokenizer.init(source);
    _ = after_identifier.next();
    after_identifier.resumeAfterRawErasure(raw_end, previous_identifier);
    try std.testing.expectEqual(TokenType.slash, after_identifier.next().type);

    const initial = Token.synthetic(.eof, .{
        .line = 1,
        .column = 1,
        .offset = 0,
    });
    var after_initial = Tokenizer.init(source);
    _ = after_initial.next();
    after_initial.resumeAfterRawErasure(raw_end, initial);
    try std.testing.expectEqual(TokenType.regex_literal, after_initial.next().type);
}

test "raw template resume drops its frame and uses template tail regex state" {
    const source = "`head${hidden}` /value/;";
    var tokenizer = Tokenizer.init(source);
    const head = tokenizer.next();
    try std.testing.expectEqual(TokenType.template_head, head.type);
    try std.testing.expectEqual(@as(u8, 1), tokenizer.template_depth);

    const raw_end: u32 = @intCast(std.mem.indexOfScalarPos(u8, source, head.start + head.len, '`').? + 1);
    tokenizer.resumeAfterRawTemplate(head, raw_end);
    try std.testing.expectEqual(@as(u8, 0), tokenizer.template_depth);
    try std.testing.expectEqual(TokenType.slash, tokenizer.next().type);
}

test "malformed string resume restores the LF raw boundary" {
    const source = "const value = \"open\nconst after = 1;";
    var tokenizer = Tokenizer.init(source);
    const keyword = tokenizer.next();
    _ = tokenizer.next();
    _ = tokenizer.next();
    const string = tokenizer.next();
    try std.testing.expectEqual(TokenType.string_literal, string.type);
    const lf: u32 = @intCast(std.mem.indexOfScalar(u8, string.text(source), '\n').? + string.start);

    tokenizer.resumeMalformedStringAt(string, lf, keyword);
    try std.testing.expectEqual(lf, tokenizer.pos);
    try std.testing.expectEqual(@as(u32, 1), tokenizer.line);
    const after = tokenizer.next();
    try std.testing.expectEqual(TokenType.kw_const, after.type);
    try std.testing.expectEqual(@as(u32, 2), after.line);
}

test "observed token request reports a leading unfinished comment" {
    const source = "/* unfinished";
    var tokenizer = Tokenizer.init(source);
    var observation: ?TriviaObservation = null;

    const eof = tokenizer.nextObserved(&observation);
    try std.testing.expectEqual(TokenType.eof, eof.type);
    try std.testing.expect(observation != null);
    switch (observation.?) {
        .unterminated_comment => |failure| {
            try std.testing.expectEqual(@as(u32, 0), failure.opener);
            try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), failure.@"resume");
            try std.testing.expectEqual(failure.@"resume", tokenizer.pos);
        },
    }
}

test "observed token request clears output after complete trivia" {
    const source = "/* complete */ value";
    var tokenizer = Tokenizer.init(source);
    var observation: ?TriviaObservation = .{ .unterminated_comment = .{
        .opener = 11,
        .@"resume" = 12,
    } };

    const value = tokenizer.nextObserved(&observation);
    try std.testing.expectEqual(TokenType.identifier, value.type);
    try std.testing.expectEqualStrings("value", value.text(source));
    try std.testing.expectEqual(@as(?TriviaObservation, null), observation);
}

test "plain lookahead does not consume a committed trivia observation" {
    const source = "/* unfinished";
    var committed = Tokenizer.init(source);
    var lookahead = committed;

    const speculative = lookahead.next();
    try std.testing.expectEqual(TokenType.identifier, speculative.type);
    try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), speculative.start);

    var observation: ?TriviaObservation = null;
    const terminal = committed.nextObserved(&observation);
    try std.testing.expectEqual(TokenType.eof, terminal.type);
    try std.testing.expect(observation != null);
    try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), committed.pos);
}

test "recovery string rescan ignores erased type quotes and preserves LF" {
    const source = "/ from \"./a\";\nconst live: \"const\" = 1;\n}\n";
    var tokenizer = Tokenizer.init(source);
    try std.testing.expectEqual(TokenType.regex_literal, tokenizer.next().type);
    const original = tokenizer.next();
    try std.testing.expectEqual(TokenType.string_literal, original.type);
    const type_start: u32 = @intCast(std.mem.indexOf(u8, source, "\"const\"").?);
    try std.testing.expectEqual(type_start + 1, original.start + original.len);
    const rescanned = try tokenizer.rescanRecoveryString(original, &.{.{
        .start = type_start,
        .end = type_start + @as(u32, "\"const\"".len),
    }});
    try std.testing.expectEqual(original.start, rescanned.start);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), rescanned.start + rescanned.len);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.count(u8, source, "\n") + 1)), tokenizer.line);
    try std.testing.expectEqual(@as(u32, @intCast(source.len)), tokenizer.line_start);
    try std.testing.expectEqual(TokenType.eof, tokenizer.next().type);
}

test "recovery string rescan uses logical erasures for escapes and quotes" {
    const source = "/ from \"./a\";\nconst live: \"escaped\\\n\\\"quote\" = 1;\nconst end = \"ok\";\n";
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "\"escaped").?);
    const end: u32 = @intCast(std.mem.indexOf(u8, source, " = 1;").?);
    const erasures = [_]RecoveryErasure{.{ .start = start, .end = end }};
    var tokenizer = Tokenizer.init(source);
    try std.testing.expectEqual(TokenType.regex_literal, tokenizer.next().type);
    const original = tokenizer.next();
    const rescanned = try tokenizer.rescanRecoveryString(original, &erasures);
    const real_quote: u32 = @intCast(std.mem.indexOf(u8, source, "\"ok\"").?);
    try std.testing.expectEqual(real_quote + 1, rescanned.start + rescanned.len);

    const masked = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(masked);
    for (masked[start..end]) |*byte| if (byte.* != '\n') {
        byte.* = ' ';
    };
    var oracle = Tokenizer.init(masked);
    try std.testing.expectEqual(TokenType.regex_literal, oracle.next().type);
    var expected = oracle.next();
    try std.testing.expect(!expected.has_escape);
    // Coordinates follow the logical erasures; text() still borrows original
    // bytes, so the escape flag must describe that original string content.
    try std.testing.expect(rescanned.has_escape);
    expected.has_escape = true;
    try std.testing.expectEqualDeep(expected, rescanned);
    try std.testing.expectEqual(oracle.pos, tokenizer.pos);
    try std.testing.expectEqual(oracle.line, tokenizer.line);
    try std.testing.expectEqual(oracle.line_start, tokenizer.line_start);
    const word = tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, word.type);
    try std.testing.expectEqualStrings("ok", word.text(source));
}

test "recovery string rescan validates every interval before changing state" {
    const source = "/ from \"./a\";\nconst live: \"const\" = 1;\n}\n";
    var tokenizer = Tokenizer.init(source);
    _ = tokenizer.next();
    const original = tokenizer.next();
    tokenizer.current = original;
    tokenizer.has_current = true;
    const before = tokenizer.saveState();
    const outside: u32 = @intCast(source.len + 1);
    const cases = [_][]const RecoveryErasure{
        &.{.{ .start = 4, .end = 3 }},
        &.{.{ .start = 4, .end = 4 }},
        &.{.{ .start = 4, .end = outside }},
        &.{ .{ .start = 7, .end = 10 }, .{ .start = 6, .end = 7 } },
        &.{ .{ .start = 7, .end = 10 }, .{ .start = 9, .end = 11 } },
        &.{.{ .start = original.start, .end = original.start + 1 }},
    };
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    for (cases) |erasures| {
        try std.testing.expectError(error.InvalidRecoveryErasure, tokenizer.rescanRecoveryString(original, erasures));
        try std.testing.expectEqualDeep(before, tokenizer.saveState());
    }
    var invalid = original;
    invalid.type = .identifier;
    try std.testing.expectError(error.InvalidRecoveryErasure, tokenizer.rescanRecoveryString(invalid, &.{}));
    try std.testing.expectEqualDeep(before, tokenizer.saveState());
}
