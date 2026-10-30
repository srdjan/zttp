//! Fuzz and stress tests for the source frontends: the tokenizer, the
//! direct TypeScript parser and runtime parser.
//!
//! The contract these tests pin is narrower than "the frontend is correct".
//! For any input, each stage must return a result or a typed error. It must
//! not panic, hang, overflow the stack, leak, or read outside the source. Any
//! physical span it reports must lie inside the source it was given, and an
//! error that is not an out-of-memory error must say where it happened. Per stage:
//!
//!   tokenizer  finishes within source.len + 1 tokens and ends in EOF. Every
//!              token span lies inside the source and starts at or after the
//!              end of the previous token. Line and column match a recount
//!              from the bytes. A save and restore replays the same tokens.
//!   typed      returns an admitted program or a classified refusal in compile
//!              and collect modes. Syntax owners and physical diagnostic spans
//!              refer to the original source. Published positions retain their
//!              admission presentation coordinates.
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
const source_frontend = @import("../source_frontend.zig");
const TypeSyntax = @import("../parser/type_syntax.zig");

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
    "structural Box<T> = { v: T }; const b: Box<number> = { v: 1 };",
    "function id<T>(value: T): T { return value; } const n = id<number>(1);",
    "import type { Shape } from \"./types\";\nconst n: number = 1;",
    "export type { Shape } from \"./types\";\nconst n: number = 1;",
    "const value = <T>(1);",
    "const value: any = 1;",
    "const value = ;",
    "const value: { /* unfinished",
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
    outcomes: std.EnumArray(std.meta.Tag(source_frontend.DirectCheckOutcome), usize) = .initFill(0),
    annotations: usize = 0,
    declarations: usize = 0,
    signatures: usize = 0,
    generics: usize = 0,
    type_modules: usize = 0,
    erased_prefixes: usize = 0,
};

fn countNewlines(text: []const u8) u32 {
    var count: u32 = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// Line and column must name a place inside `text`. Lines are 1-based and the
/// last line starts after the final newline. They must also equal the position
/// recounted from the bytes before `start`, the offset the diagnostic names.
fn expectPositionInside(text: []const u8, start: u32, line: u32, column: u32) !void {
    try std.testing.expect(line >= 1);
    try std.testing.expect(line <= countNewlines(text) + 1);
    try std.testing.expect(column >= 1);
    try std.testing.expect(start <= text.len);
    const before = text[0..start];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |newline| newline + 1 else 0;
    try std.testing.expectEqual(countNewlines(before) + 1, line);
    try std.testing.expectEqual(@as(u32, @intCast(start - line_start + 1)), column);
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
// Direct typed source contract
// ----------------------------------------------------------------------------

fn initTypedOwner(
    owner: *source_frontend.DirectCheckSource,
    allocator: std.mem.Allocator,
    type_allocator: std.mem.Allocator,
    src: []const u8,
    mode: TypeSyntax.AdmissionMode,
) !void {
    switch (mode) {
        .compile => try owner.initCompileInPlace(allocator, type_allocator, src, "fuzz.ts"),
        .collect => try owner.initInPlace(allocator, type_allocator, src, "fuzz.ts"),
    }
}

fn expectSpanInside(src: []const u8, start: u32, end: u32) !void {
    try std.testing.expect(start <= end);
    try std.testing.expect(end <= src.len);
}

fn expectAdmissionInside(src: []const u8, diagnostic: TypeSyntax.AdmissionDiagnostic) !void {
    try expectSpanInside(src, diagnostic.span.start, diagnostic.span.end);
    const position = diagnostic.positionIn(src);
    // Admission presentation retains compatibility cursor rewinds.
    // Its coordinates need not equal the physical span's line and column.
    if (diagnostic.presentation != null) {
        try std.testing.expect(position.line >= 1);
        try std.testing.expect(position.column >= 1);
    } else {
        try expectPositionInside(src, diagnostic.span.start, position.line, position.column);
    }
}

fn checkTyped(
    allocator: std.mem.Allocator,
    src: []const u8,
    mode: TypeSyntax.AdmissionMode,
    stats: *Stats,
) !void {
    var owner: source_frontend.DirectCheckSource = undefined;
    try initTypedOwner(&owner, allocator, allocator, src, mode);
    defer owner.deinit();
    try std.testing.expectEqualStrings(src, owner.sourceView().text);
    stats.outcomes.getPtr(std.meta.activeTag(owner.outcome().*)).* += 1;
    switch (owner.outcome().*) {
        .accepted => |root| {
            stats.ok += 1;
            const accepted = owner.acceptedCapabilities() orelse return error.MissingAcceptedCapabilities;
            try std.testing.expectEqual(root, accepted.root);
            try std.testing.expectEqual(.program, accepted.ir_view.getTag(root).?);
            try std.testing.expect(!owner.parser.hasErrors());
            const store = accepted.type_store;
            try store.validate();
            stats.annotations += store.annotations.items.len;
            stats.declarations += store.declarations.items.len;
            stats.signatures += store.function_signatures.items.len;
            stats.generics += store.generic_owners.items.len;
            stats.type_modules += store.type_only_modules.items.len;
            stats.erased_prefixes += store.erased_type_prefixes.items.len;
        },
        .recovered_admission_refused => {
            try std.testing.expectEqual(TypeSyntax.AdmissionMode.collect, mode);
            stats.rejected += 1;
            const diagnostics = owner.selectedAdmissionDiagnostics();
            try std.testing.expect(diagnostics.len > 0);
            for (diagnostics) |diagnostic| try expectAdmissionInside(src, diagnostic);
            stats.located += 1;
        },
        .parser_refused => |refusal| {
            stats.rejected += 1;
            try expectKnownParserError(refusal.first_error);
            const errors = owner.parserErrors();
            try std.testing.expectEqual(refusal.projected_error_count, errors.len);
            try std.testing.expect(errors.len > 0);
            for (errors) |recorded| {
                const location = recorded.location;
                try expectPositionInside(src, location.offset, location.line, location.column);
                const span = location.span();
                try expectSpanInside(src, span.start, span.end);
            }
            stats.located += 1;
        },
        .terminal_admission_refused => |failure| {
            stats.rejected += 1;
            switch (failure) {
                .diagnostic => |diagnostic| try expectAdmissionInside(src, diagnostic),
                .unterminated_comment => |comment| {
                    try expectSpanInside(src, comment.opener, comment.@"resume");
                    try std.testing.expect(comment.opener + 2 <= src.len);
                    try std.testing.expectEqualStrings("/*", src[comment.opener..][0..2]);
                },
            }
            stats.located += 1;
        },
    }
    if (owner.outcome().* != .accepted) {
        try std.testing.expect(owner.acceptedCapabilities() == null);
    }
    if (owner.parser.getLastAdmissionObservation()) |diagnostic| try expectAdmissionInside(src, diagnostic);
}

fn expectTypedStats(stats: Stats, mode: TypeSyntax.AdmissionMode, syntax_floor: bool) !void {
    try std.testing.expectEqual(stats.calls, stats.ok + stats.rejected);
    try std.testing.expectEqual(stats.rejected, stats.located);
    try std.testing.expect(stats.ok > 0);
    try std.testing.expect(stats.rejected > 0);
    try std.testing.expect(stats.located > 0);
    if (mode == .compile) try std.testing.expectEqual(@as(usize, 0), stats.outcomes.get(.recovered_admission_refused));
    if (syntax_floor) {
        inline for (@typeInfo(std.meta.Tag(source_frontend.DirectCheckOutcome)).@"enum".field_names) |field| {
            const tag: std.meta.Tag(source_frontend.DirectCheckOutcome) = @fromBackingInt(@intCast(@backingInt(@field(std.meta.Tag(source_frontend.DirectCheckOutcome), field))));
            if (mode != .compile or tag != .recovered_admission_refused) {
                try std.testing.expect(stats.outcomes.get(tag) > 0);
            }
        }
        try std.testing.expect(stats.annotations > 0);
        try std.testing.expect(stats.declarations > 0);
        try std.testing.expect(stats.signatures > 0);
        try std.testing.expect(stats.generics > 0);
        try std.testing.expect(stats.type_modules > 0);
        try std.testing.expect(stats.erased_prefixes > 0);
    }
}

test "direct admission replay retains the unterminated string after a colon" {
    const source = ":'\n";
    for ([_]TypeSyntax.AdmissionMode{ .compile, .collect }) |mode| {
        var owner: source_frontend.DirectCheckSource = undefined;
        try initTypedOwner(&owner, std.testing.allocator, std.testing.allocator, source, mode);
        defer owner.deinit();

        try std.testing.expect(owner.acceptedCapabilities() == null);
        try std.testing.expectEqual(.terminal_admission_refused, std.meta.activeTag(owner.outcome().*));
        const failure = owner.outcome().terminal_admission_refused;
        try std.testing.expectEqual(.diagnostic, std.meta.activeTag(failure));
        try std.testing.expectEqual(@as(usize, 1), owner.parser.getAdmissionDiagnostics().len);
        const diagnostic = failure.diagnostic;
        try std.testing.expectEqual(.unterminated_string, diagnostic.kind);
        try std.testing.expectEqual(@as(u32, 2), diagnostic.span.start);
        try std.testing.expectEqual(@as(u32, 3), diagnostic.span.end);
        const position = diagnostic.positionIn(source);
        try std.testing.expectEqual(@as(u32, 1), position.line);
        try std.testing.expectEqual(@as(u32, 3), position.column);
    }
}

test "source-only admission observes the unterminated string after a colon" {
    const source = ":'\n";
    const failure = (try source_frontend.checkSourceAdmission(std.testing.allocator, source)) orelse
        return error.ExpectedSourceAdmissionRefusal;
    try std.testing.expectEqual(.diagnostic, std.meta.activeTag(failure));
    const diagnostic = failure.diagnostic;
    try std.testing.expectEqual(.unterminated_string, diagnostic.kind);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.span.start);
    try std.testing.expectEqual(@as(u32, 3), diagnostic.span.end);
    const position = diagnostic.positionIn(source);
    try std.testing.expectEqual(@as(u32, 1), position.line);
    try std.testing.expectEqual(@as(u32, 3), position.column);
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
    "TooManyConstants",
    "TooManyShapes",
    "JumpTooFar",
};

fn expectKnownParserError(err: anyerror) !void {
    for (parser_errors) |name| {
        if (std.mem.eql(u8, name, @errorName(err))) return;
    }
    std.debug.print("unclassified parser error: {s}\n", .{@errorName(err)});
    return error.UnclassifiedParserError;
}

/// Parse the original input and check its result and diagnostic positions.
fn checkParseInput(
    allocator: std.mem.Allocator,
    input: []const u8,
    mode: ParseMode,
    stats: *Stats,
) !void {
    var parser = (switch (mode) {
        .program => Parser.init(allocator, input),
        .expression => Parser.initExpression(allocator, input),
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
            try expectPositionInside(input, loc.offset, loc.line, loc.column);
            const span = loc.span();
            try std.testing.expect(span.start <= span.end);
            try std.testing.expect(span.end <= input.len);
            stats.located += 1;
        }
    }
}

fn checkParser(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    try checkParseInput(allocator, src, .program, stats);
}

fn checkExpression(allocator: std.mem.Allocator, src: []const u8, stats: *Stats) !void {
    try checkParseInput(allocator, src, .expression, stats);
}

// ----------------------------------------------------------------------------
// Targets
// ----------------------------------------------------------------------------

const Target = enum { tokenizer, typed_compile, typed_collect, parser, expression };

fn checkOne(target: Target, src: []const u8, stats: *Stats) !void {
    const allocator = std.testing.allocator;
    stats.calls += 1;
    stats.bytes += src.len;
    if (src.len == 0) stats.empty += 1;
    switch (target) {
        .tokenizer => try checkTokenizer(src, stats),
        .typed_compile => try checkTyped(allocator, src, .compile, stats),
        .typed_collect => try checkTyped(allocator, src, .collect, stats),
        .parser => try checkParser(allocator, src, stats),
        .expression => try checkExpression(allocator, src, stats),
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
    .{ .name = "generic", .prefix = "structural Deep = ", .open = "Box<", .core = "string", .close = ">", .suffix = ";" },
    .{ .name = "object", .prefix = "structural Deep = ", .open = "{ a: ", .core = "string", .close = "}", .suffix = ";" },
    .{ .name = "paren", .prefix = "structural Deep = ", .open = "(", .core = "string", .close = ")", .suffix = ";" },
    .{ .name = "function type", .prefix = "structural Deep = ", .open = "(a: ", .core = "string", .close = ") => string", .suffix = ";" },
    .{ .name = "annotation", .prefix = "const x: ", .open = "Box<", .core = "string", .close = ">", .suffix = " = [];" },
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

test "nesting: direct admission accepts type depth 512 and refuses opener 513" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 6), type_shapes.len);
    for ([_]TypeSyntax.AdmissionMode{ .compile, .collect }) |mode| {
        var accepted: usize = 0;
        var refused: usize = 0;
        for (type_shapes) |shape| {
            for ([_]usize{ 1, 64, 512 }) |depth| {
                errdefer std.debug.print("type depth {d} {s} in {s}\n", .{ depth, shape.name, @tagName(mode) });
                var source = try buildNested(allocator, shape, depth);
                defer source.deinit(allocator);
                var owner: source_frontend.DirectCheckSource = undefined;
                try initTypedOwner(&owner, allocator, allocator, source.items, mode);
                defer owner.deinit();
                try std.testing.expectEqual(.accepted, std.meta.activeTag(owner.outcome().*));
                try std.testing.expect(owner.acceptedCapabilities() != null);
                accepted += 1;
            }
            for ([_]usize{ 513, 2000, very_deep }) |depth| {
                errdefer std.debug.print("type depth {d} {s} in {s}\n", .{ depth, shape.name, @tagName(mode) });
                var source = try buildNested(allocator, shape, depth);
                defer source.deinit(allocator);
                var owner: source_frontend.DirectCheckSource = undefined;
                try initTypedOwner(&owner, allocator, allocator, source.items, mode);
                defer owner.deinit();
                switch (owner.outcome().*) {
                    .terminal_admission_refused => |failure| switch (failure) {
                        .diagnostic => |diagnostic| {
                            try std.testing.expectEqual(TypeSyntax.AdmissionKind.nesting_too_deep, diagnostic.kind);
                            try expectAdmissionInside(source.items, diagnostic);
                        },
                        else => return error.ExpectedTypeNestingDiagnostic,
                    },
                    else => return error.ExpectedTypeNestingRefusal,
                }
                try std.testing.expect(owner.acceptedCapabilities() == null);
                refused += 1;
            }
        }
        try std.testing.expectEqual(3 * type_shapes.len, accepted);
        try std.testing.expectEqual(3 * type_shapes.len, refused);
    }
}

fn expectTypedValueNesting(owner: *const source_frontend.DirectCheckSource) !void {
    switch (owner.outcome().*) {
        .parser_refused => {
            try std.testing.expect(owner.parserErrors().len > 0);
            for (owner.parserErrors()) |diagnostic| {
                if (diagnostic.kind == .nesting_too_deep) return;
            }
            return error.ExpectedValueNestingDiagnostic;
        },
        .terminal_admission_refused => |failure| switch (failure) {
            .diagnostic => |diagnostic| try std.testing.expectEqual(TypeSyntax.AdmissionKind.nesting_too_deep, diagnostic.kind),
            .unterminated_comment => return error.ExpectedValueNestingDiagnostic,
        },
        else => return error.ExpectedValueNestingRefusal,
    }
}

test "nesting: direct admission survives every value shape and guards tracked depth" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 14), value_shapes.len);
    for ([_]TypeSyntax.AdmissionMode{ .compile, .collect }) |mode| {
        var stats: Stats = .{};
        for (value_shapes) |shape| {
            for ([_]usize{ 1, 64, 512, 513, 2000, deep_guarded }) |depth| {
                errdefer std.debug.print("value depth {d} {s} in {s}\n", .{ depth, shape.name, @tagName(mode) });
                var source = try buildNested(allocator, shape, depth);
                defer source.deinit(allocator);
                try checkOne(if (mode == .compile) .typed_compile else .typed_collect, source.items, &stats);
            }
        }
        try std.testing.expectEqual(6 * value_shapes.len, stats.calls);
        try expectTypedStats(stats, mode, false);
        for ([_]usize{ 0, 3 }) |index| {
            const shape = value_shapes[index];
            var shallow = try buildNested(allocator, shape, 1);
            defer shallow.deinit(allocator);
            var accepted: source_frontend.DirectCheckSource = undefined;
            try initTypedOwner(&accepted, allocator, allocator, shallow.items, mode);
            defer accepted.deinit();
            try std.testing.expectEqual(.accepted, std.meta.activeTag(accepted.outcome().*));
            var deep = try buildNested(allocator, shape, 513);
            defer deep.deinit(allocator);
            var refused: source_frontend.DirectCheckSource = undefined;
            try initTypedOwner(&refused, allocator, allocator, deep.items, mode);
            defer refused.deinit();
            try expectTypedValueNesting(&refused);
        }
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
            var parser = try Parser.initExpression(allocator, source.items);
            defer parser.deinit();
            _ = try parser.parseExpressionOnly();
        }
        for ([_]usize{ 65, 600, very_deep }) |depth| {
            var source = try buildNested(allocator, shape, depth);
            defer source.deinit(allocator);
            var parser = try Parser.initExpression(allocator, source.items);
            defer parser.deinit();
            try std.testing.expectError(error.ParseError, parser.parseExpressionOnly());
            try std.testing.expect(parserNestingTooDeep(&parser));
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

const AllocationTarget = enum { parser, compile_runtime, compile_types, collect_runtime, collect_types };

/// Runtime and syntax allocations fail independently. A classified refusal
/// remains fail-closed after allocation failure; claiming acceptance does not.
fn oomStage(allocator: std.mem.Allocator, target: AllocationTarget, src: []const u8) !void {
    switch (target) {
        .parser => try oomParse(allocator, src),
        .compile_runtime, .compile_types, .collect_runtime, .collect_types => {
            const runtime_allocator = switch (target) {
                .compile_runtime, .collect_runtime => allocator,
                else => std.testing.allocator,
            };
            const type_allocator = switch (target) {
                .compile_types, .collect_types => allocator,
                else => std.testing.allocator,
            };
            const mode: TypeSyntax.AdmissionMode = switch (target) {
                .compile_runtime, .compile_types => .compile,
                else => .collect,
            };
            var owner: source_frontend.DirectCheckSource = undefined;
            try initTypedOwner(&owner, runtime_allocator, type_allocator, src, mode);
            defer owner.deinit();
            switch (owner.outcome().*) {
                .accepted => {},
                .parser_refused => |refusal| {
                    try expectKnownParserError(refusal.first_error);
                    return error.Refused;
                },
                .recovered_admission_refused, .terminal_admission_refused => return error.Refused,
            }
        },
    }
}

fn oomParse(allocator: std.mem.Allocator, src: []const u8) !void {
    var parser = Parser.init(allocator, src) catch return error.OutOfMemory;
    defer parser.deinit();
    _ = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try expectKnownParserError(err);
            return error.Refused;
        },
    };
}

/// Fail each allocation of one stage configuration in turn, the way
/// `std.testing.checkAllAllocationFailures` does, and return how many
/// allocations it made. The standard helper reports a swallowed failure
/// without saying where, so this one prints the stack of the allocation that
/// was made to fail. A success after a failed allocation is the error: it means
/// the failure was dropped and the stage still claimed a clean result.
fn sweepAllocationFailures(target: AllocationTarget, src: []const u8) !usize {
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var total: usize = 0;
    {
        var counting = std.testing.FailingAllocator.init(no_resize.allocator(), .{});
        // The unlimited run may refuse the input; only its allocation count matters.
        oomStage(counting.allocator(), target, src) catch |err| switch (err) {
            error.Refused => {},
            else => return err,
        };
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        total = counting.alloc_index;
    }
    for (0..total) |fail_index| {
        var failing = std.testing.FailingAllocator.init(no_resize.allocator(), .{ .fail_index = fail_index });
        if (oomStage(failing.allocator(), target, src)) |_| {
            if (!failing.has_induced_failure) return error.NondeterministicAllocation;
            std.debug.print("allocation {d} of {d} failed and the stage still succeeded:\n", .{ fail_index, total });
            std.debug.dumpStackTrace(&failing.getStackTrace());
            return error.SwallowedOutOfMemory;
        } else |err| {
            switch (err) {
                error.OutOfMemory, error.Refused => {},
                else => return err,
            }
            if (!failing.has_induced_failure) return error.NondeterministicAllocation;
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
    var eligible_seeds: usize = 0;
    var runs = std.EnumArray(AllocationTarget, usize).initFill(0);
    var allocations = std.EnumArray(AllocationTarget, usize).initFill(0);
    for (seeds) |seed| {
        if (seed.len > oom_seed_limit) continue;
        eligible_seeds += 1;
        for (std.enums.values(AllocationTarget)) |target| {
            allocations.getPtr(target).* += sweepAllocationFailures(target, seed) catch |err| {
                std.debug.print("{s} allocation sweep failed on \"{f}\"\n", .{ @tagName(target), std.zig.fmtString(seed) });
                return err;
            };
            runs.getPtr(target).* += 1;
        }
    }
    try std.testing.expect(eligible_seeds >= 20);
    for (std.enums.values(AllocationTarget)) |target| {
        try std.testing.expectEqual(eligible_seeds, runs.get(target));
        try std.testing.expect(allocations.get(target) > 0);
    }
}

// ----------------------------------------------------------------------------
// Tests: seeds through std.testing.fuzz
// ----------------------------------------------------------------------------

test "fuzz: tokenizer holds its contract on every seed" {
    const stats = try runSeeds(.tokenizer);
    try std.testing.expect(stats.tokens > seeds.len);
    try std.testing.expect(stats.replays > 0);
}

test "fuzz: direct compile holds its contract on every seed" {
    try expectTypedStats(try runSeeds(.typed_compile), .compile, true);
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

test "fuzz: direct collect holds its contract on every seed" {
    try expectTypedStats(try runSeeds(.typed_collect), .collect, true);
}

// ----------------------------------------------------------------------------
// Tests: PRNG stress
// ----------------------------------------------------------------------------

test "stress: tokenizer holds its contract on generated input" {
    const stats = try runStress(.tokenizer, 0x70C3_0001, 5000);
    try std.testing.expect(stats.tokens > stats.calls);
    try std.testing.expect(stats.replays > 0);
}

test "stress: direct admission holds its contract on generated input in both modes" {
    try expectTypedStats(try runStress(.typed_compile, 0x70C3_0002, 400), .compile, false);
    try expectTypedStats(try runStress(.typed_collect, 0x70C3_0002, 400), .collect, false);
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

test "stress: direct compile holds its contract on the pipeline input stream" {
    try expectTypedStats(try runStress(.typed_compile, 0x70C3_0006, 200), .compile, false);
}
