//! Fuzz and stress tests for the source frontends: tokenizer, TypeScript
//! stripper, TSX lowerer, and parser.

const std = @import("std");
const tokenizer_mod = @import("../parser/tokenizer.zig");

// Regression: `subst_brace_depths` was a `u8` counter, so 256 unmatched `{`
// inside one `${...}` substitution panicked with integer overflow in a safe
// build. The braces here balance, so the substitution must still close at its
// own `}` and the literal must end in a template tail.
test "tokenizer: 300 nested braces inside a template substitution do not overflow" {
    const allocator = std.testing.allocator;
    const nested = 300;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "`${");
    try source.appendNTimes(allocator, '{', nested);
    try source.appendNTimes(allocator, '}', nested);
    try source.appendSlice(allocator, "}`");

    var tokenizer = tokenizer_mod.Tokenizer.init(source.items);
    var lbrace: usize = 0;
    var rbrace: usize = 0;
    var last_before_eof: tokenizer_mod.TokenType = .eof;
    var count: usize = 0;
    while (true) {
        const tok = tokenizer.next();
        count += 1;
        try std.testing.expect(count <= source.items.len + 1);
        if (tok.type == .eof) break;
        if (tok.type == .lbrace) lbrace += 1;
        if (tok.type == .rbrace) rbrace += 1;
        last_before_eof = tok.type;
    }
    try std.testing.expectEqual(@as(usize, nested), lbrace);
    try std.testing.expectEqual(@as(usize, nested), rbrace);
    try std.testing.expectEqual(tokenizer_mod.TokenType.template_tail, last_before_eof);
}

// Past the counter's range the count saturates. The tokenization after that
// point is not meaningful, but the tokenizer must still terminate without a
// panic, and the parser refuses this nesting long before it reaches it.
test "tokenizer: braces beyond the counter range saturate instead of panicking" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "`${");
    try source.appendNTimes(allocator, '{', 70_000);

    var tokenizer = tokenizer_mod.Tokenizer.init(source.items);
    var count: usize = 0;
    while (true) {
        const tok = tokenizer.next();
        count += 1;
        try std.testing.expect(count <= source.items.len + 1);
        if (tok.type == .eof) break;
    }
    try std.testing.expectEqual(@as(usize, 70_000 + 1 + 1), count);
}
