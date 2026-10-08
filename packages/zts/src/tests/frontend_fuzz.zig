//! Fuzz and stress tests for the source frontends: the tokenizer, the
//! TypeScript stripper, the TSX lowerer, and the parser.
//!
//! The contract these tests pin is narrower than "the frontend is correct".
//! For any input, each stage must return a result or a typed error. It must
//! not panic, hang, overflow the stack, leak, or read outside the source. Any
//! position it reports must lie inside the source it was given, and an error
//! that is not an out-of-memory error must say where it happened. Per stage:
//!
//!   tokenizer  finishes within source.len + 1 tokens and ends in EOF. Every
//!              token span lies inside the source and starts at or after the
//!              end of the previous token. Line and column match a recount
//!              from the bytes. A save and restore replays the same tokens.
//!   stripper   returns a result or a StripError. A result keeps the length of
//!              the source unless a span edit says otherwise, and its type map,
//!              diagnostics, and span edits stay inside both texts. A refusal
//!              carries a diagnostic inside the source.
//!   lowerer    returns a result or InvalidTsx with a diagnostic inside the
//!              source. A source without `<` comes back unchanged.
//!   parser     returns a program or an error from a closed set. A refusal has
//!              recorded errors, and each recorded span lies inside the input.
//!
//! Inputs come from three places. A small hand-written seed corpus covers one
//! construct family per entry. A PRNG stress loop mutates those seeds and
//! assembles fragments from a fixed seed, so a failure reproduces. Generators
//! build nesting at and past each documented depth limit. Each test counts
//! what it ran and asserts the count, so a test that ran nothing fails.
//!
//! `ZTTP_FUZZ_ITERATIONS` replaces the default iteration count of every stress
//! loop, for a longer manual run. `zig build test --fuzz` is not supported.

const std = @import("std");
const builtin = @import("builtin");
const tokenizer_mod = @import("../parser/tokenizer.zig");
const parse_mod = @import("../parser/parse.zig");
const stripper = @import("../stripper.zig");
const tsx_lowerer = @import("../tsx_lowerer.zig");
const source_frontend = @import("../source_frontend.zig");

const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const Parser = parse_mod.Parser;

// ----------------------------------------------------------------------------
// Seed corpus
// ----------------------------------------------------------------------------

/// Largest input one fuzz call reads. Every seed must fit.
const max_source = 4096;

const seeds = [_][]const u8{
    // statements and declarations
    "const x = 1;",
    "  \n\t\r\n  ",
    "let a = 1; let b = a + 2 * 3 - (4 / 5) % 6;",
    "export function handler(req: Request): Response {\n  return Response.json({ ok: true });\n}\n",
    "import { a, b } from \"zttp:json\";\nexport const k = 1;\n",
    "import type { T } from \"x\";\nexport default function () {}\n",
    // match, one seed per pattern family
    "function f(cmd: Command): string {\n  return match (cmd) {\n    when { kind: \"echo\", text }: text\n    when { kind: \"ping\" }: \"pong\"\n  };\n}\n",
    "const r = match (v) {\n  when null: \"null\"\n  when boolean: \"b\"\n  when number: \"n\"\n  when string: \"s\"\n  when array: \"a\"\n  when Dict: \"d\"\n  when Bytes: \"y\"\n  default: \"x\"\n};\n",
    "const r = match (xs) { when [a, b]: a when [] : 0 default: 1 };",
    "match (req) { when { method: \"GET\", path: \"/h\" }: 1 default: 2 };",
    // template literals
    "const s = `a ${1 + 2} b ${`x${y}`} c`;",
    "const s = `${ {a: {b: 1}}.a }`;",
    "const s = `abc ${",
    "const s = `${ {`${ {} }`} }`;",
    // type annotations
    "function f(a: number, b: string[]): { x: number } | null { return null; }",
    "structural Box<T> = { v: T };\nconst b: Box<Array<number>> = { v: [1] };",
    "nominal Id = string;\nstructural P = { id: Id; tags: string[] };\n",
    "const a = x as number; const b = y satisfies string; let c: any = 1;",
    "function f(a?: number, b: number = 2) {}",
    "interface I { a: number } type T = string; distinct type D = number;",
    "const v = <number>x;",
    "function f(x: ((a: number) => number)[]): Array<Array<string>> { return []; }",
    // JSX
    "const v = <div class=\"a\" id={x}>Hi {name}<span /></div>;",
    "const v = <><A {...p} /><B /></>;",
    "const v = <a></b>;",
    "const v = <a><b>",
    "const v: JSX.Element = <ul>{items.map((t: Item): JSX.Element => <li key={t.id}>{t.text}</li>)}</ul>;",
    "const v = <p>{\"</p>\"}{`<b>`}{/* c */ x}</p>;",
    "const v = <a title='x\"y' b=\"c'd\" flag />;",
    "const v = a < b && c > d ? <Ok /> : <No />;",
    "const v = <a {x}/>;",
    "const v = <a b={} />;",
    // comments, strings, numbers, unicode
    "// line\n/* block\n multi */ const a = 1; /* unterminated",
    "const s = \"a\\nb\\u00e9\\x41\"; const t = 'it\\'s';",
    "const s = \"a\\\nb\";",
    "const s = \"abc",
    "const caf\xc3\xa9 = 1; const s = \"\xe2\x82\xac\xf0\x9f\x98\x80\";",
    "const n = [0x1F, 0b101, 0o17, 1_000, 1e10, .5, 5., 1.5e-3, 0xZZ, 1e+];",
    // operators
    "a ?? b; a?.b; a?.[0]; a ??= 1; x **= 2; a >>>= 1; a ? b : c; a?.5:1;",
    "const r = /ab+c/gi; const d = a / b / c;",
    "const o = { ...a, b: 1 }; f(...xs); [...ys];",
    "const f = (x: number): number => x * 2; [1,2].map((v) => v + 1).filter(v => v > 1);",
    "for (const x of range(0, 10)) { if (x > 3) { break; } }",
    "const k = comptime(1 / 3); const j = comptime(Env.NAME);",
    "assert x > 0;",
    // refused forms
    "class A {} async function f() { await g(); } var x = 1; while (true) {} switch (x) {} new Foo(); try {} catch (e) {} x == y; x++;",
    "const { a, b } = o; const [c, d] = xs;",
    "@ # \\ ` ~ ^ | \x00 \x01 \xff",
    // nesting and expression profile
    "((((((((((1))))))))))",
    "[[[[[[[1]]]]]]]",
    "{a:{a:{a:{a:1}}}}",
    "1 + 2 * (3 - 4)",
    "[1, 2, 3].map((v) => v * 2)",
};

const seed_floor = 40;
const seed_bytes = blk: {
    var total: usize = 0;
    for (seeds) |seed| total += seed.len;
    break :blk total;
};

comptime {
    for (seeds) |seed| {
        if (seed.len > max_source) @compileError("a seed exceeds max_source");
    }
    if (seeds.len < seed_floor) @compileError("the seed corpus fell below its floor");
}

/// `Smith.slice` reads a 4-byte little-endian length before the bytes. A raw
/// string handed to the corpus would lose its first four bytes to that prefix.
fn framed(comptime raw: []const u8) []const u8 {
    const prefix = std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, raw.len)));
    const out = prefix ++ raw[0..].*;
    return &out;
}

const corpus = blk: {
    var out: [seeds.len][]const u8 = undefined;
    for (seeds, 0..) |seed, index| out[index] = framed(seed);
    break :blk out;
};

// ----------------------------------------------------------------------------
// Iteration control
// ----------------------------------------------------------------------------

const IterationsError = error{InvalidFuzzIterations};

/// The iteration count for one stress loop. `raw` is the value of
/// `ZTTP_FUZZ_ITERATIONS` when set. A value that is not a positive integer is
/// an error, because a typo that silently fell back to the default would make
/// a long run look like a short one.
fn parseIterations(raw: ?[]const u8, default: usize) IterationsError!usize {
    const text = raw orelse return default;
    const value = std.fmt.parseInt(usize, text, 10) catch return error.InvalidFuzzIterations;
    if (value == 0) return error.InvalidFuzzIterations;
    return value;
}

fn iterationsFor(default: usize) IterationsError!usize {
    const raw: ?[]const u8 = if (std.c.getenv("ZTTP_FUZZ_ITERATIONS")) |ptr| std.mem.span(ptr) else null;
    return parseIterations(raw, default);
}

// ----------------------------------------------------------------------------
// Counters and helpers
// ----------------------------------------------------------------------------

const Stats = struct {
    /// Inputs handed to the target.
    calls: usize = 0,
    /// Bytes across all inputs.
    bytes: usize = 0,
    /// Inputs of length zero.
    empty: usize = 0,
    /// Inputs the stage accepted.
    ok: usize = 0,
    /// Inputs the stage refused with an error other than out-of-memory.
    rejected: usize = 0,
    /// Refusals whose reported position was checked against the source.
    located: usize = 0,
    /// Tokens produced by the tokenizer target.
    tokens: usize = 0,
    /// Save and restore replays that were compared.
    replays: usize = 0,
};

fn countNewlines(text: []const u8) u32 {
    var count: u32 = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// Line and column must name a place inside `text`. Lines are 1-based and the
/// last line starts after the final newline.
fn expectPositionInside(text: []const u8, line: u32, column: u32) !void {
    try std.testing.expect(line >= 1);
    try std.testing.expect(line <= countNewlines(text) + 1);
    try std.testing.expect(column >= 1);
}

// ----------------------------------------------------------------------------
// Tokenizer contract
// ----------------------------------------------------------------------------

const replay_points = 3;
const replay_tokens = 8;

fn checkTokenizer(src: []const u8, stats: *Stats) !void {
    var tokenizer = Tokenizer.init(src);
    var recorded: [max_source + 1]Token = undefined;
    var states: [replay_points]tokenizer_mod.TokenizerState = undefined;
    var state_at: [replay_points]usize = @splat(std.math.maxInt(usize));

    var count: usize = 0;
    var prev_end: u64 = 0;
    // Incremental recount of line and column from the bytes.
    var cursor: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;

    while (true) {
        // Save the tokenizer before the tokens at a few fixed points so that a
        // restore can be compared with what the first pass produced.
        for (0..replay_points) |point| {
            if (state_at[point] == std.math.maxInt(usize) and count == (point + 1) * (src.len + 1) / (replay_points + 1)) {
                states[point] = tokenizer.saveState();
                state_at[point] = count;
            }
        }

        const tok = tokenizer.next();
        try std.testing.expect(count <= src.len);
        recorded[count] = tok;
        count += 1;

        if (tok.type == .eof) {
            try std.testing.expectEqual(@as(u32, @intCast(src.len)), tok.start);
            try std.testing.expectEqual(@as(u32, 0), tok.len);
            break;
        }

        try std.testing.expect(tok.len >= 1);
        try std.testing.expect(@as(u64, tok.start) + tok.len <= src.len);
        try std.testing.expect(tok.start >= prev_end);
        prev_end = @as(u64, tok.start) + tok.len;

        while (cursor < tok.start) : (cursor += 1) {
            if (src[cursor] == '\n') {
                line += 1;
                line_start = cursor + 1;
            }
        }
        try std.testing.expectEqual(line, tok.line);
        try std.testing.expectEqual(@as(u32, @intCast(tok.start - line_start + 1)), tok.column);
    }
    stats.tokens += count;

    // EOF is sticky.
    const again = tokenizer.next();
    try std.testing.expectEqual(tokenizer_mod.TokenType.eof, again.type);
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), again.start);

    // A restored tokenizer replays the tokens the first pass produced.
    for (0..replay_points) |point| {
        const at = state_at[point];
        if (at == std.math.maxInt(usize)) continue;
        tokenizer.restoreState(states[point]);
        var index = at;
        var replayed: usize = 0;
        while (index < count and replayed < replay_tokens) : ({
            index += 1;
            replayed += 1;
        }) {
            const tok = tokenizer.next();
            try std.testing.expectEqual(recorded[index].type, tok.type);
            try std.testing.expectEqual(recorded[index].start, tok.start);
            try std.testing.expectEqual(recorded[index].len, tok.len);
        }
        stats.replays += 1;
    }
}

// ----------------------------------------------------------------------------
// Stripper contract
// ----------------------------------------------------------------------------

fn checkStripWith(allocator: std.mem.Allocator, src: []const u8, base: stripper.StripOptions, stats: *Stats) !void {
    var options = base;
    var diag: ?stripper.StripDiagnostic = null;
    options.diagnostic_out = &diag;
    const newlines = countNewlines(src);

    var result = stripper.strip(allocator, src, options) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => {
            stats.rejected += 1;
            if (diag) |d| {
                try expectPositionInside(src, d.line, d.column);
                stats.located += 1;
            }
            return;
        },
    };
    defer result.deinit();
    stats.ok += 1;

    if (result.span_edits.len == 0 and !options.collect_all_diagnostics) {
        // Stripping is offset-preserving unless a span edit says otherwise.
        try std.testing.expectEqual(src.len, result.code.len);
    }
    var prev_stripped_end: u32 = 0;
    var prev_source_end: u32 = 0;
    for (result.span_edits) |edit| {
        try std.testing.expect(edit.stripped_start <= edit.stripped_end);
        try std.testing.expect(edit.stripped_end <= result.code.len);
        try std.testing.expect(edit.source_start <= edit.source_end);
        try std.testing.expect(edit.source_end <= src.len);
        try std.testing.expect(edit.stripped_start >= prev_stripped_end);
        try std.testing.expect(edit.source_start >= prev_source_end);
        prev_stripped_end = edit.stripped_end;
        prev_source_end = edit.source_end;
    }
    for (result.type_map.entries.items) |entry| {
        try std.testing.expect(entry.source_start <= entry.source_end);
        try std.testing.expect(entry.source_end <= src.len);
        try std.testing.expect(entry.name_start <= entry.name_end);
        try std.testing.expect(entry.name_end <= src.len);
        try std.testing.expect(entry.context_line >= 1);
        try std.testing.expect(entry.context_line <= newlines + 1);
    }
    for (result.diagnostics) |d| {
        try expectPositionInside(src, d.line, d.column);
        const at = result.sourcePosition(src, d.line, d.column);
        try expectPositionInside(src, at.line, at.column);
    }
    const probes = [_]u32{ 0, @intCast(result.code.len / 2), @intCast(result.code.len) };
    for (probes) |probe| {
        try std.testing.expect(result.sourceOffset(probe) <= src.len);
    }
}

const strip_variants = [_]struct { name: []const u8, options: stripper.StripOptions }{
    .{ .name = "default", .options = .{} },
    .{ .name = "tsx_mode", .options = .{ .tsx_mode = true } },
    .{ .name = "comptime", .options = .{ .enable_comptime = true, .comptime_env = .{} } },
    .{ .name = "collect_all_diagnostics", .options = .{ .collect_all_diagnostics = true } },
};

fn checkStripper(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    for (strip_variants) |variant| {
        checkStripWith(allocator, src, variant.options, stats) catch |err| {
            std.debug.print("stripper variant {s} failed\n", .{variant.name});
            return err;
        };
    }
}

// ----------------------------------------------------------------------------
// TSX lowerer contract
// ----------------------------------------------------------------------------

fn checkLowerer(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    var diag: ?tsx_lowerer.Diagnostic = null;
    var result = tsx_lowerer.lower(allocator, src, &diag) catch |err| switch (err) {
        error.OutOfMemory => return,
        error.SourceTooLarge => return error.UnexpectedSourceTooLarge,
        error.InvalidTsx => {
            stats.rejected += 1;
            const d = diag orelse return error.InvalidTsxWithoutDiagnostic;
            try expectPositionInside(src, d.line, d.column);
            stats.located += 1;
            return;
        },
    };
    defer result.deinit();
    stats.ok += 1;

    var prev_stripped_end: u32 = 0;
    var prev_source_end: u32 = 0;
    for (result.span_edits) |edit| {
        try std.testing.expect(edit.stripped_start <= edit.stripped_end);
        try std.testing.expect(edit.stripped_end <= result.code.len);
        try std.testing.expect(edit.source_start <= edit.source_end);
        try std.testing.expect(edit.source_end <= src.len);
        try std.testing.expect(edit.stripped_start >= prev_stripped_end);
        try std.testing.expect(edit.source_start >= prev_source_end);
        prev_stripped_end = edit.stripped_end;
        prev_source_end = edit.source_end;
    }
    if (std.mem.indexOfScalar(u8, src, '<') == null) {
        try std.testing.expectEqualStrings(src, result.code);
    }
}

// ----------------------------------------------------------------------------
// Parser contract
// ----------------------------------------------------------------------------

const ParseMode = enum { program, expression };

/// Every error `Parser.parse` and `parseExpressionOnly` may return. The set is
/// closed on purpose: an error that is not here is new behavior to classify.
const parser_errors = [_][]const u8{
    "OutOfMemory",
    "ParseError",
    "UnexpectedToken",
    "MissingSemicolon",
    "InvalidNumber",
    "InvalidEscapeSequence",
    "StringLineContinuation",
    "TooManyLocals",
};

fn expectKnownParserError(err: anyerror) !void {
    for (parser_errors) |name| {
        if (std.mem.eql(u8, name, @errorName(err))) return;
    }
    std.debug.print("unclassified parser error: {s}\n", .{@errorName(err)});
    return error.UnclassifiedParserError;
}

/// Parse `input` and check what came back. `view` maps a position in `input`
/// back to the file the author wrote, when a frontend rewrote the text.
fn checkParseInput(
    allocator: std.mem.Allocator,
    input: []const u8,
    mode: ParseMode,
    view: ?stripper.SourceView,
    stats: *Stats,
) !void {
    var parser = (switch (mode) {
        .program => Parser.init(allocator, input),
        .expression => Parser.initExpression(allocator, input, .comptime_expression),
    }) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
    defer parser.deinit();

    const outcome = switch (mode) {
        .program => parser.parse(),
        .expression => parser.parseExpressionOnly(),
    };
    if (outcome) |_| {
        stats.ok += 1;
        try std.testing.expect(!parser.hasErrors());
        return;
    } else |err| {
        try expectKnownParserError(err);
        if (err == error.OutOfMemory) return;
        stats.rejected += 1;
        try std.testing.expect(parser.hasErrors());
        for (parser.getErrors()) |recorded| {
            const loc = recorded.location;
            try expectPositionInside(input, loc.line, loc.column);
            const span = loc.span();
            try std.testing.expect(span.start <= span.end);
            try std.testing.expect(span.end <= input.len);
            if (view) |v| {
                const at = v.position(loc.line, loc.column);
                try expectPositionInside(v.text, at.line, at.column);
            }
            stats.located += 1;
        }
    }
}

fn checkParser(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    try checkParseInput(allocator, src, .program, null, stats);
}

fn checkExpression(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    try checkParseInput(allocator, src, .expression, null, stats);
}

/// The path real sources take: strip, lower TSX, then parse the result.
fn checkPipelineAs(allocator: std.mem.Allocator, src: []const u8, path: []const u8, options: stripper.StripOptions, stats: *Stats) !void {
    var prepared = source_frontend.PreparedSource.init(allocator, src, path, options) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => {
            stats.rejected += 1;
            return;
        },
    };
    defer prepared.deinit();
    try checkParseInput(allocator, prepared.parserInput(), .program, prepared.sourceView(), stats);
}

fn checkPipeline(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    try checkPipelineAs(allocator, src, "fuzz.ts", .{}, stats);
    try checkPipelineAs(allocator, src, "fuzz.tsx", .{}, stats);
    try checkPipelineAs(allocator, src, "fuzz.tsx", .{ .enable_comptime = true, .comptime_env = .{} }, stats);
}

// ----------------------------------------------------------------------------
// Targets
// ----------------------------------------------------------------------------

const Target = enum { tokenizer, stripper, lowerer, parser, expression, pipeline };

fn checkOne(target: Target, src: []const u8, stats: *Stats) !void {
    const allocator = std.testing.allocator;
    stats.calls += 1;
    stats.bytes += src.len;
    if (src.len == 0) stats.empty += 1;
    switch (target) {
        .tokenizer => try checkTokenizer(src, stats),
        .stripper => try checkStripper(allocator, src, stats),
        .lowerer => try checkLowerer(allocator, src, stats),
        .parser => try checkParser(allocator, src, stats),
        .expression => try checkExpression(allocator, src, stats),
        .pipeline => try checkPipeline(allocator, src, stats),
    }
}

const FuzzRun = struct {
    target: Target,
    stats: Stats = .{},
};

fn fuzzOne(run: *FuzzRun, smith: *std.testing.Smith) anyerror!void {
    var buf: [max_source]u8 = undefined;
    const len = smith.slice(&buf);
    checkOne(run.target, buf[0..len], &run.stats) catch |err| {
        std.debug.print("{s} failed on seed input \"{f}\"\n", .{ @tagName(run.target), std.zig.fmtString(buf[0..len]) });
        return err;
    };
}

/// Run the seed corpus through `std.testing.fuzz` and prove that every seed
/// reached the target with its intended bytes. Plain `zig build test` runs each
/// seed once and then the empty input once.
fn runSeeds(target: Target) !Stats {
    var run: FuzzRun = .{ .target = target };
    try std.testing.fuzz(&run, fuzzOne, .{ .corpus = &corpus });
    if (builtin.fuzz) return run.stats;
    try std.testing.expectEqual(seeds.len + 1, run.stats.calls);
    try std.testing.expectEqual(@as(usize, 1), run.stats.empty);
    try std.testing.expectEqual(seed_bytes, run.stats.bytes);
    return run.stats;
}

// ----------------------------------------------------------------------------
// PRNG stress inputs
// ----------------------------------------------------------------------------

const fragments = [_][]const u8{
    "{",        "}",            "(",           ")",        "[",         "]",          "<",          ">",       "</",
    "/>",       "`",            "${",          "\"",       "'",         "\\",         "\\n",        "\n",      "\r\n",
    "//",       "/*",           "*/",          "/",        "*",         "?.",         "??",         "...",     "=>",
    ";",        ":",            ",",           ".",        "=",         "==",         "+",          "++",      "-",
    "!",        "&&",           "||",          "@",        "#",         "0x",         "0b1",        "1_0",     "1e+",
    ".5",       "const ",       "let ",        "var ",     "function ", "return ",    "if (",       "else ",   "for (",
    "of ",      "match (",      "when ",       "default:", "null",      "undefined",  "true",       "number",  "string",
    "Array<",   "Promise<",     "structural ", "nominal ", "as ",       "satisfies ", "interface ", "type ",   "any",
    "export ",  "import ",      "from ",       "class ",   "async ",    "await ",     "comptime(",  "assert ", "x",
    "foo",      "Foo",          "div",         "<div>",    "</div>",    "<A ",        "{...p}",     "k={",     "=\"v\"",
    "\xc3\xa9", "\xe2\x82\xac", "\xff",        "\x00",     "  ",        "\t",         "$",          "_",       "`${",
};

const interesting_bytes = "{}[]()<>`$\\\"'/*\n\r\t ;:,.?=!&|%-+0aZ_@#~^\x80\xc3\xa9\xff\x00";

fn soup(rng: std.Random, buf: []u8) usize {
    const target_len = 1 + rng.uintLessThan(usize, 400);
    var len: usize = 0;
    while (len < target_len) {
        const fragment = fragments[rng.uintLessThan(usize, fragments.len)];
        if (len + fragment.len > buf.len) break;
        @memcpy(buf[len..][0..fragment.len], fragment);
        len += fragment.len;
    }
    return len;
}

fn noise(rng: std.Random, buf: []u8) usize {
    const len = 1 + rng.uintLessThan(usize, 256);
    for (buf[0..len]) |*byte| {
        byte.* = if (rng.boolean())
            rng.int(u8)
        else
            interesting_bytes[rng.uintLessThan(usize, interesting_bytes.len)];
    }
    return len;
}

fn mutate(rng: std.Random, buf: []u8) usize {
    const seed = seeds[rng.uintLessThan(usize, seeds.len)];
    @memcpy(buf[0..seed.len], seed);
    var len = seed.len;
    const operations = 1 + rng.uintLessThan(u8, 4);
    for (0..operations) |_| {
        if (len == 0) break;
        switch (rng.uintLessThan(u8, 5)) {
            0 => buf[rng.uintLessThan(usize, len)] = interesting_bytes[rng.uintLessThan(usize, interesting_bytes.len)],
            1 => {
                const at = rng.uintLessThan(usize, len);
                const cut = @min(1 + rng.uintLessThan(usize, 16), len - at);
                std.mem.copyForwards(u8, buf[at..], buf[at + cut .. len]);
                len -= cut;
            },
            2 => {
                const at = rng.uintLessThan(usize, len);
                const copy = @min(1 + rng.uintLessThan(usize, 32), len - at);
                if (len + copy <= buf.len) {
                    std.mem.copyBackwards(u8, buf[at + copy .. len + copy], buf[at..len]);
                    len += copy;
                }
            },
            3 => {
                const at = rng.uintLessThan(usize, len + 1);
                const fragment = fragments[rng.uintLessThan(usize, fragments.len)];
                if (len + fragment.len <= buf.len) {
                    std.mem.copyBackwards(u8, buf[at + fragment.len .. len + fragment.len], buf[at..len]);
                    @memcpy(buf[at..][0..fragment.len], fragment);
                    len += fragment.len;
                }
            },
            else => len = rng.uintLessThan(usize, len + 1),
        }
    }
    return len;
}

fn generate(rng: std.Random, buf: []u8) usize {
    const mode = rng.uintLessThan(u8, 8);
    if (mode < 4) return mutate(rng, buf);
    if (mode < 7) return soup(rng, buf);
    return noise(rng, buf);
}

fn runStress(target: Target, seed: u64, default_iterations: usize) !Stats {
    const iterations = try iterationsFor(default_iterations);
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var buf: [max_source]u8 = undefined;
    var stats: Stats = .{};
    for (0..iterations) |_| {
        const len = generate(rng, &buf);
        checkOne(target, buf[0..len], &stats) catch |err| {
            // A failing input is the whole reproduction, so print it.
            std.debug.print("{s} failed on generated input \"{f}\"\n", .{ @tagName(target), std.zig.fmtString(buf[0..len]) });
            return err;
        };
    }
    try std.testing.expectEqual(iterations, stats.calls);
    return stats;
}

// ----------------------------------------------------------------------------
// Tests: harness
// ----------------------------------------------------------------------------

test "fuzz harness: each framed seed reaches the callback with its intended bytes" {
    try std.testing.expect(seeds.len >= seed_floor);
    var buf: [max_source]u8 = undefined;
    inline for (seeds, 0..) |seed, index| {
        var smith: std.testing.Smith = .{ .in = corpus[index] };
        const len = smith.slice(&buf);
        try std.testing.expectEqualStrings(seed, buf[0..len]);
    }
}

test "fuzz harness: ZTTP_FUZZ_ITERATIONS accepts positive integers only" {
    try std.testing.expectEqual(@as(usize, 7), try parseIterations(null, 7));
    try std.testing.expectEqual(@as(usize, 50), try parseIterations("50", 7));
    try std.testing.expectError(error.InvalidFuzzIterations, parseIterations("0", 7));
    try std.testing.expectError(error.InvalidFuzzIterations, parseIterations("abc", 7));
    try std.testing.expectError(error.InvalidFuzzIterations, parseIterations("", 7));
    try std.testing.expectError(error.InvalidFuzzIterations, parseIterations("-3", 7));
}

// ----------------------------------------------------------------------------
// Tests: regressions
// ----------------------------------------------------------------------------

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

    var tokenizer = Tokenizer.init(source.items);
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

    var tokenizer = Tokenizer.init(source.items);
    var count: usize = 0;
    while (true) {
        const tok = tokenizer.next();
        count += 1;
        try std.testing.expect(count <= source.items.len + 1);
        if (tok.type == .eof) break;
    }
    try std.testing.expectEqual(@as(usize, 70_000 + 1 + 1), count);
}

// ----------------------------------------------------------------------------
// Nesting generators
// ----------------------------------------------------------------------------

/// A source built as `prefix`, `open` repeated `depth` times, `core`, `close`
/// repeated `depth` times, then `suffix`.
const Shape = struct {
    name: []const u8,
    prefix: []const u8 = "",
    open: []const u8,
    core: []const u8,
    close: []const u8,
    suffix: []const u8 = "",
};

fn buildNested(allocator: std.mem.Allocator, shape: Shape, depth: usize) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, shape.prefix);
    for (0..depth) |_| try out.appendSlice(allocator, shape.open);
    try out.appendSlice(allocator, shape.core);
    for (0..depth) |_| try out.appendSlice(allocator, shape.close);
    try out.appendSlice(allocator, shape.suffix);
    return out;
}

const type_shapes = [_]Shape{
    .{ .name = "tuple", .prefix = "structural Deep = ", .open = "[", .core = "string", .close = "]", .suffix = ";" },
    .{ .name = "generic", .prefix = "structural Deep = ", .open = "Array<", .core = "string", .close = ">", .suffix = ";" },
    .{ .name = "object", .prefix = "structural Deep = ", .open = "{ a: ", .core = "string", .close = "}", .suffix = ";" },
    .{ .name = "paren", .prefix = "structural Deep = ", .open = "(", .core = "string", .close = ")", .suffix = ";" },
    .{ .name = "function type", .prefix = "structural Deep = ", .open = "(a: ", .core = "string", .close = ") => string", .suffix = ";" },
    .{ .name = "annotation", .prefix = "const x: ", .open = "Array<", .core = "string", .close = ">", .suffix = " = [];" },
};

const value_shapes = [_]Shape{
    .{ .name = "paren", .prefix = "const x = ", .open = "(", .core = "1", .close = ")", .suffix = ";" },
    .{ .name = "array", .prefix = "const x = ", .open = "[", .core = "1", .close = "]", .suffix = ";" },
    .{ .name = "object", .prefix = "const x = ", .open = "{ a: ", .core = "1", .close = "}", .suffix = ";" },
    .{ .name = "call", .prefix = "const x = ", .open = "f(", .core = "1", .close = ")", .suffix = ";" },
    .{ .name = "arrow", .prefix = "const x = ", .open = "() => ", .core = "1", .close = "", .suffix = ";" },
    .{ .name = "unary", .prefix = "const x = ", .open = "!", .core = "1", .close = "", .suffix = ";" },
    .{ .name = "ternary", .prefix = "const x = ", .open = "a ? b : ", .core = "1", .close = "", .suffix = ";" },
    .{ .name = "block", .open = "{ ", .core = "", .close = "}" },
    .{ .name = "if", .open = "if (a) { ", .core = "", .close = "}" },
    .{ .name = "function", .open = "function f() { ", .core = "", .close = "}" },
    .{ .name = "template", .prefix = "const x = ", .open = "`${", .core = "1", .close = "}`", .suffix = ";" },
    .{ .name = "match", .prefix = "const x = ", .open = "match (a) { when 1: ", .core = "1", .close = " default: 2 }", .suffix = ";" },
    .{ .name = "spread object", .prefix = "const x = ", .open = "{ ...", .core = "a", .close = "}", .suffix = ";" },
    .{ .name = "member chain", .prefix = "const x = a", .open = ".b", .core = "", .close = "", .suffix = ";" },
};

const jsx_shapes = [_]Shape{
    .{ .name = "element", .open = "<a>", .core = "x", .close = "</a>" },
    .{ .name = "expression", .open = "<a>{", .core = "x", .close = "}</a>" },
    .{ .name = "attribute", .open = "<a b={", .core = "x", .close = "}/>" },
    .{ .name = "fragment", .open = "<>", .core = "x", .close = "</>" },
    .{ .name = "call in expression", .open = "<a>{f(", .core = "x", .close = ")}</a>" },
};

/// Past every documented limit, far enough that a recursion with no guard
/// would overflow the native stack.
const very_deep = 20_000;

/// For stages that stop at a depth guard of 512 or less: ten times the guard is
/// enough to show the guard fires, and the build cost stays small.
const deep_guarded = 5_000;

fn parserNestingTooDeep(parser: *const Parser) bool {
    for (parser.getErrors()) |recorded| {
        if (recorded.kind == .nesting_too_deep) return true;
    }
    return false;
}

// The stripper limit is 512 levels of type syntax and of value nesting that
// the stripper tracks itself. The error carries a diagnostic.
test "nesting: the stripper refuses type nesting past 512 and accepts it below" {
    const allocator = std.testing.allocator;
    for (type_shapes) |shape| {
        for ([_]usize{ 1, 64, 512 }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            if (stripper.strip(allocator, source.items, .{})) |stripped| {
                var result = stripped;
                result.deinit();
            } else |err| try std.testing.expect(err != error.NestingTooDeep);
        }
        for ([_]usize{ 513, 2000, very_deep }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var diag: ?stripper.StripDiagnostic = null;
            try std.testing.expectError(
                error.NestingTooDeep,
                stripper.strip(allocator, source.items, .{ .diagnostic_out = &diag }),
            );
            try std.testing.expectEqual(stripper.StripDiagnosticKind.nesting_too_deep, diag.?.kind);
        }
    }
}

test "nesting: the stripper survives value nesting of any depth" {
    const allocator = std.testing.allocator;
    var refused: usize = 0;
    var accepted: usize = 0;
    for (value_shapes) |shape| {
        for ([_]usize{ 1, 64, 512, 513, 2000, deep_guarded }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            if (stripper.strip(allocator, source.items, .{})) |stripped| {
                var result = stripped;
                result.deinit();
                accepted += 1;
            } else |_| refused += 1;
        }
    }
    try std.testing.expect(accepted > 0);
    try std.testing.expect(refused > 0);
    // Parentheses and calls are tracked: depth 1 passes and depth 513 does not.
    for ([_]usize{ 0, 3 }) |index| {
        const shape = value_shapes[index];
        var shallow = try buildNested(allocator, shape, 1);
        defer shallow.deinit(allocator);
        var ok = try stripper.strip(allocator, shallow.items, .{});
        ok.deinit();
        var deep = try buildNested(allocator, shape, 513);
        defer deep.deinit(allocator);
        try std.testing.expectError(error.NestingTooDeep, stripper.strip(allocator, deep.items, .{}));
    }
}

// The parser limit is 512 levels of statement and expression nesting.
test "nesting: the parser refuses value nesting past its limit with a nesting diagnostic" {
    const allocator = std.testing.allocator;
    for (value_shapes) |shape| {
        // A template with an interpolation is refused at any depth, so it
        // carries no nesting diagnostic. Every other shape is valid when shallow.
        const is_template = std.mem.eql(u8, shape.name, "template");

        for ([_]usize{ 1, 8 }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var parser = try Parser.init(allocator, source.items);
            defer parser.deinit();
            if (is_template) {
                try std.testing.expectError(error.ParseError, parser.parse());
            } else {
                _ = try parser.parse();
            }
        }
        for ([_]usize{ 513, 2000, deep_guarded }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var parser = try Parser.init(allocator, source.items);
            defer parser.deinit();
            if (parser.parse()) |_| {
                return error.NestingAcceptedPastTheLimit;
            } else |_| {}
            try std.testing.expect(parser.hasErrors());
            try std.testing.expectEqual(!is_template, parserNestingTooDeep(&parser));
        }
    }
}

// The expression profile has a limit of 64.
test "nesting: the parser expression profile refuses nesting past 64" {
    const allocator = std.testing.allocator;
    const shapes = [_]Shape{
        .{ .name = "paren", .open = "(", .core = "1", .close = ")" },
        .{ .name = "array", .open = "[", .core = "1", .close = "]" },
        .{ .name = "object", .open = "{ a: ", .core = "1", .close = "}" },
        .{ .name = "call", .open = "f(", .core = "1", .close = ")" },
        .{ .name = "unary", .open = "!", .core = "1", .close = "" },
    };
    for (shapes) |shape| {
        for ([_]usize{ 1, 8 }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var parser = try Parser.initExpression(allocator, source.items, .comptime_expression);
            defer parser.deinit();
            _ = try parser.parseExpressionOnly();
        }
        for ([_]usize{ 65, 600, very_deep }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var parser = try Parser.initExpression(allocator, source.items, .comptime_expression);
            defer parser.deinit();
            try std.testing.expectError(error.ParseError, parser.parseExpressionOnly());
            try std.testing.expect(parserNestingTooDeep(&parser));
        }
    }
}

// The lowerer limit is 64 levels of element nesting, and 64 levels of elements
// nested through expressions.
test "nesting: the TSX lowerer refuses nesting past 64" {
    const allocator = std.testing.allocator;
    for (jsx_shapes) |shape| {
        // Elements nested directly obey the element limit exactly.
        const direct = std.mem.eql(u8, shape.name, "element") or std.mem.eql(u8, shape.name, "fragment");
        if (direct) {
            var at_limit = try buildNested(allocator, shape, 64);
            defer at_limit.deinit(allocator);
            var ok = try tsx_lowerer.lower(allocator, at_limit.items, null);
            ok.deinit();
        }
        for ([_]usize{ 1, 8 }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var ok = try tsx_lowerer.lower(allocator, source.items, null);
            ok.deinit();
        }
        for ([_]usize{ 65, 600, very_deep }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var diag: ?tsx_lowerer.Diagnostic = null;
            try std.testing.expectError(error.InvalidTsx, tsx_lowerer.lower(allocator, source.items, &diag));
            try std.testing.expect(diag != null);
        }
    }
}

// The tokenizer has no recursion. Its template and brace counters must hold at
// any depth, including past the 16 template levels it tracks braces for.
test "nesting: the tokenizer terminates on templates and braces of any depth" {
    const allocator = std.testing.allocator;
    const shapes = [_]Shape{
        .{ .name = "template", .open = "`${", .core = "1", .close = "}`" },
        .{ .name = "template with braces", .open = "`${ {", .core = "1", .close = "} }`" },
        .{ .name = "brace", .open = "{", .core = "", .close = "}" },
        .{ .name = "template opener only", .open = "`${", .core = "", .close = "" },
        .{ .name = "closer only", .open = "", .core = "`${", .close = "}" },
    };
    for (shapes) |shape| {
        for ([_]usize{ 1, 15, 16, 17, 255, 256, 257, 5000, very_deep }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var tokenizer = Tokenizer.init(source.items);
            var count: usize = 0;
            var prev_end: u64 = 0;
            while (true) {
                const tok = tokenizer.next();
                count += 1;
                try std.testing.expect(count <= source.items.len + 1);
                if (tok.type == .eof) break;
                try std.testing.expect(tok.len >= 1);
                try std.testing.expect(tok.start >= prev_end);
                prev_end = @as(u64, tok.start) + tok.len;
                try std.testing.expect(prev_end <= source.items.len);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Allocation failure
// ----------------------------------------------------------------------------

const StageError = error{
    /// The stage refused the input with a typed error other than out-of-memory.
    /// A refusal is a fail-closed outcome, so it is allowed after a failed
    /// allocation. Only a success is not.
    Refused,
    OutOfMemory,
};

/// Run one configuration of one frontend stage. `variant` selects a stripper
/// option set and is zero for every other stage.
fn oomStage(allocator: std.mem.Allocator, target: Target, variant: usize, src: []const u8) StageError!void {
    switch (target) {
        .stripper => {
            var result = stripper.strip(allocator, src, strip_variants[variant].options) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Refused,
            };
            result.deinit();
        },
        .lowerer => {
            var result = tsx_lowerer.lower(allocator, src, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Refused,
            };
            result.deinit();
        },
        .parser => try oomParse(allocator, src),
        .pipeline => {
            var prepared = source_frontend.PreparedSource.init(allocator, src, "fuzz.tsx", .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Refused,
            };
            defer prepared.deinit();
            try oomParse(allocator, prepared.parserInput());
        },
        .tokenizer, .expression => unreachable,
    }
}

fn oomParse(allocator: std.mem.Allocator, src: []const u8) StageError!void {
    var parser = Parser.init(allocator, src) catch return error.OutOfMemory;
    defer parser.deinit();
    _ = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Refused,
    };
}

const SweepError = error{ SwallowedOutOfMemory, LeakedOnFailure, NondeterministicAllocation };

/// Fail each allocation of one stage configuration in turn, the way
/// `std.testing.checkAllAllocationFailures` does, and return how many
/// allocations it made. The standard helper reports a swallowed failure
/// without saying where, so this one prints the stack of the allocation that
/// was made to fail. A success after a failed allocation is the error: it means
/// the failure was dropped and the stage still claimed a clean result.
fn sweepAllocationFailures(target: Target, variant: usize, src: []const u8) (SweepError || StageError)!usize {
    var total: usize = 0;
    {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        // The unlimited run may refuse the input; only its allocation count matters.
        oomStage(counting.allocator(), target, variant, src) catch |err| switch (err) {
            error.Refused => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
        total = counting.alloc_index;
    }
    for (0..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (oomStage(failing.allocator(), target, variant, src)) |_| {
            if (!failing.has_induced_failure) return error.NondeterministicAllocation;
            std.debug.print("allocation {d} of {d} failed and the stage still succeeded:\n", .{ fail_index, total });
            std.debug.dumpStackTrace(&failing.getStackTrace());
            return error.SwallowedOutOfMemory;
        } else |_| {
            if (failing.allocated_bytes != failing.freed_bytes) {
                std.debug.print("allocation {d} of {d} failed and the stage leaked:\n", .{ fail_index, total });
                std.debug.dumpStackTrace(&failing.getStackTrace());
                return error.LeakedOnFailure;
            }
        }
    }
    return total;
}

/// Longest seed the allocation sweep covers. The sweep reruns a stage once per
/// allocation it makes, so it stays on short inputs.
const oom_seed_limit = 120;

test "allocation failure: no frontend stage leaks or reports success after a failed allocation" {
    var runs: usize = 0;
    var allocations: usize = 0;
    for (seeds) |seed| {
        if (seed.len > oom_seed_limit) continue;
        for ([_]Target{ .stripper, .lowerer, .parser, .pipeline }) |target| {
            const variants: usize = if (target == .stripper) strip_variants.len else 1;
            for (0..variants) |variant| {
                allocations += sweepAllocationFailures(target, variant, seed) catch |err| {
                    std.debug.print("{s} variant {d} allocation sweep failed on \"{f}\"\n", .{ @tagName(target), variant, std.zig.fmtString(seed) });
                    return err;
                };
                runs += 1;
            }
        }
    }
    try std.testing.expect(runs >= 4 * 20);
    try std.testing.expect(allocations >= runs);
}

// ----------------------------------------------------------------------------
// Tests: seeds through std.testing.fuzz
// ----------------------------------------------------------------------------

test "fuzz: tokenizer holds its contract on every seed" {
    const stats = try runSeeds(.tokenizer);
    try std.testing.expect(stats.tokens > seeds.len);
    try std.testing.expect(stats.replays > 0);
}

test "fuzz: stripper holds its contract on every seed" {
    const stats = try runSeeds(.stripper);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
}

test "fuzz: TSX lowerer holds its contract on every seed" {
    const stats = try runSeeds(.lowerer);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
}

test "fuzz: parser holds its contract on every seed" {
    const stats = try runSeeds(.parser);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
}

test "fuzz: parser expression profile holds its contract on every seed" {
    const stats = try runSeeds(.expression);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
}

test "fuzz: strip, lower, and parse pipeline holds its contract on every seed" {
    const stats = try runSeeds(.pipeline);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
}

// ----------------------------------------------------------------------------
// Tests: PRNG stress
// ----------------------------------------------------------------------------

test "stress: tokenizer holds its contract on generated input" {
    const stats = try runStress(.tokenizer, 0x70C3_0001, 5000);
    try std.testing.expect(stats.tokens > stats.calls);
    try std.testing.expect(stats.replays > 0);
}

test "stress: stripper holds its contract on generated input" {
    const stats = try runStress(.stripper, 0x70C3_0002, 400);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
}

test "stress: TSX lowerer holds its contract on generated input" {
    const stats = try runStress(.lowerer, 0x70C3_0003, 1500);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
}

test "stress: parser holds its contract on generated input" {
    const stats = try runStress(.parser, 0x70C3_0004, 1000);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
}

test "stress: parser expression profile holds its contract on generated input" {
    const stats = try runStress(.expression, 0x70C3_0005, 1000);
    try std.testing.expect(stats.rejected > 0);
}

test "stress: strip, lower, and parse pipeline holds its contract on generated input" {
    const stats = try runStress(.pipeline, 0x70C3_0006, 200);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
}
