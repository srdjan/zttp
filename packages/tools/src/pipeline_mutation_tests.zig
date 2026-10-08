//! Mutation tests for the full in-process check.
//!
//! The in-process check is the call `zts check --json` makes:
//! `precompile.runCheckOnlyFromSourceWithOptions`. It runs the strip, parse,
//! import, boolean, type, strict, verifier, flow, contract, path, and spec
//! stages in one pass. The golden corpus pins what it says about 129 well-formed
//! files. This file pins what it does with a damaged one.
//!
//! The inputs are the `.ts` and `.tsx` files under `tests/corpus` and
//! `examples`, read from the repository when the test runs. Each file yields a
//! fixed number of mutants from a PRNG seeded by the file path, so a failure
//! reproduces from the path and the mutant index alone. The mutation kinds
//! rotate in a fixed order: a bit flip, a byte deletion, a byte insertion from a
//! set of interesting bytes, a duplicated line, a deleted line, a swap of two
//! adjacent tokens, an inserted syntax fragment, and a truncation.
//!
//! The contract, for every mutant:
//!   1. The check returns a result or an error from `allowed_errors`. Any other
//!      error fails and prints the mutant. Out-of-memory cannot occur here,
//!      since the allocator never refuses, but it stays in the list because the
//!      check is allowed to report it.
//!   2. In a result, every JSON diagnostic names a line inside the mutant and a
//!      column inside that line, one past its last byte at most.
//!   3. The same mutant checked twice gives the same stage list, the same
//!      diagnostics, byte for byte, or the same error.
//!   4. No memory leaks under `std.testing.allocator`.
//!   5. No panic, hang, or stack overflow. The test process would abort.
//!
//! Each run counts what it did. The test asserts that the input count is above
//! a floor, that the mutant count equals inputs times mutants per input, and
//! that every mutation kind ran, so a test that found no files or ran no
//! mutation fails. `ZTTP_FUZZ_ITERATIONS` replaces the default number of
//! mutants per input, for a longer manual run.
//!
//! The default is small because one mutant costs two full runs of the check, about
//! 15 ms each in a Debug build. The kind of each mutant follows the running mutant
//! count, so the kinds stay evenly spread however few mutants each file gets.

const std = @import("std");
const precompile = @import("precompile.zig");

// ----------------------------------------------------------------------------
// Contract
// ----------------------------------------------------------------------------

/// The errors the check may return for source text alone. The list comes from
/// reading `runCheckOnPreparedSource` and the calls it makes with no schema,
/// system file, policy, or declaration in `CheckOptions`:
///
///   OutOfMemory             any allocation can fail.
///   TypePoolCapacityExceeded  `pipeline.resolve` and `TypeEnvStorage.init` raise
///                           it when a source defines more types than the pool
///                           holds.
///   UnresolvedTypeBinding   `pipeline.resolve` and `pipeline.check` raise it for
///                           a type name the pass cannot bind.
///   MissingSqlSchema        `validateSqlContractNative` raises it for a `sql`
///                           query when `sql_schema_path` is null.
///   ScopeDurableUnsupported `buildContractWithPolicy` raises it for a handler
///                           that uses both `zttp:scope` and `zttp:durable`.
///
/// Every other name in the check's inferred error set comes from a file, a
/// policy, a declaration, or a system config, and none of those is supplied.
const allowed_errors = [_]anyerror{
    error.OutOfMemory,
    error.TypePoolCapacityExceeded,
    error.UnresolvedTypeBinding,
    error.MissingSqlSchema,
    error.ScopeDurableUnsupported,
};

fn isAllowedError(err: anyerror) bool {
    for (allowed_errors) |allowed| {
        if (err == allowed) return true;
    }
    return false;
}

/// Index of the first diagnostic whose line or column lies outside `source`,
/// or null when all lie inside. Lines are 1-based. The last line starts after
/// the final newline. A column is 1-based and may point one past the last byte
/// of its line.
fn firstDiagnosticOutside(source: []const u8, diagnostics: []const precompile.json_diag.JsonDiagnostic) ?usize {
    const lines = std.mem.count(u8, source, "\n") + 1;
    for (diagnostics, 0..) |diag, index| {
        if (diag.line < 1 or diag.line > lines) return index;
        if (diag.column < 1) return index;
        var line_start: usize = 0;
        var line: usize = 1;
        while (line < diag.line) : (line += 1) {
            line_start = (std.mem.findScalarPos(u8, source, line_start, '\n') orelse return index) + 1;
        }
        const line_end = std.mem.findScalarPos(u8, source, line_start, '\n') orelse source.len;
        if (diag.column > line_end - line_start + 1) return index;
    }
    return null;
}

/// The stage list and diagnostics of a result as bytes, in the form the golden
/// corpus uses, so that two runs compare with one `eql`.
fn serialize(gpa: std.mem.Allocator, result: *const precompile.CheckResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("stages:");
    var stages = result.stages_run.iterator();
    while (stages.next()) |stage| try w.print(" {s}", .{@tagName(stage)});
    try w.writeByte('\n');
    for (result.json_diagnostics.items) |*diag| {
        try precompile.json_diag.writeDiagnosticJson(w, diag);
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

// ----------------------------------------------------------------------------
// Mutations
// ----------------------------------------------------------------------------

const Kind = enum {
    flip_bit,
    delete_bytes,
    insert_bytes,
    duplicate_line,
    delete_line,
    swap_tokens,
    insert_fragment,
    truncate,
};

const kind_count = @typeInfo(Kind).@"enum".fields.len;

/// Bytes that end a token, open or close a group, start a string or comment,
/// break a line, or fall outside ASCII, which the tokenizer must still accept.
const interesting_bytes = [_]u8{
    '{',  '}',  '(', ')',  '[', ']',  '<',  '>',  ';',  ':',  ',',
    '"',  '\'', '`', '\\', '$', '/',  '*',  '\n', '\r', '\t', ' ',
    '0',  '=',  '!', '?',  '.', 0x00, 0x01, 0x7f, 0x80, 0xc3, 0xe2,
    0xf0, 0xff,
};

const fragments = [_][]const u8{
    "{", "}", "(", ")", ";", "match", "when", "default:", "=>", "<a>",
};

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// A position in `source`, in `0..=source.len`. Half of the draws land on the
/// first byte of a token, because a fragment inserted there changes the token
/// stream while a fragment inserted in the middle of a token mostly changes
/// one token.
fn pickPosition(random: std.Random, source: []const u8) usize {
    if (source.len == 0) return 0;
    var pos = random.uintAtMost(usize, source.len);
    if (random.boolean()) {
        while (pos > 0 and pos < source.len and !isBlank(source[pos - 1])) pos -= 1;
    }
    return pos;
}

fn applyMutation(
    gpa: std.mem.Allocator,
    random: std.Random,
    kind: Kind,
    source: []const u8,
    out: *std.ArrayList(u8),
) !void {
    out.clearRetainingCapacity();
    switch (kind) {
        .flip_bit => {
            try out.appendSlice(gpa, source);
            if (source.len == 0) return;
            const pos = random.uintLessThan(usize, source.len);
            out.items[pos] ^= @as(u8, 1) << random.uintAtMost(u3, 7);
        },
        .delete_bytes => {
            if (source.len == 0) return;
            const pos = random.uintLessThan(usize, source.len);
            const count = @min(source.len - pos, random.intRangeAtMost(usize, 1, 4));
            try out.appendSlice(gpa, source[0..pos]);
            try out.appendSlice(gpa, source[pos + count ..]);
        },
        .insert_bytes => {
            const pos = random.uintAtMost(usize, source.len);
            try out.appendSlice(gpa, source[0..pos]);
            const count = random.intRangeAtMost(usize, 1, 3);
            for (0..count) |_| {
                try out.append(gpa, interesting_bytes[random.uintLessThan(usize, interesting_bytes.len)]);
            }
            try out.appendSlice(gpa, source[pos..]);
        },
        .duplicate_line, .delete_line => {
            if (source.len == 0) return;
            const pos = random.uintLessThan(usize, source.len);
            const start = if (std.mem.findScalarLast(u8, source[0..pos], '\n')) |nl| nl + 1 else 0;
            const end = if (std.mem.findScalarPos(u8, source, pos, '\n')) |nl| nl + 1 else source.len;
            if (kind == .delete_line) {
                try out.appendSlice(gpa, source[0..start]);
                try out.appendSlice(gpa, source[end..]);
            } else {
                try out.appendSlice(gpa, source[0..end]);
                if (end == source.len and source[end - 1] != '\n') try out.append(gpa, '\n');
                try out.appendSlice(gpa, source[start..end]);
                try out.appendSlice(gpa, source[end..]);
            }
        },
        .swap_tokens => {
            // A token is a maximal run of non-blank bytes. The swap exchanges
            // the first token at or after a random point with the next one.
            var pos = if (source.len == 0) 0 else random.uintLessThan(usize, source.len);
            while (pos > 0 and !isBlank(source[pos - 1])) pos -= 1;
            while (pos < source.len and isBlank(source[pos])) pos += 1;
            var first_end = pos;
            while (first_end < source.len and !isBlank(source[first_end])) first_end += 1;
            var second = first_end;
            while (second < source.len and isBlank(source[second])) second += 1;
            var second_end = second;
            while (second_end < source.len and !isBlank(source[second_end])) second_end += 1;
            if (pos == first_end or second == second_end) {
                // Fewer than two tokens from here on: flip a bit instead.
                try out.appendSlice(gpa, source);
                if (source.len > 0) out.items[random.uintLessThan(usize, source.len)] ^= 0x20;
                return;
            }
            try out.appendSlice(gpa, source[0..pos]);
            try out.appendSlice(gpa, source[second..second_end]);
            try out.appendSlice(gpa, source[first_end..second]);
            try out.appendSlice(gpa, source[pos..first_end]);
            try out.appendSlice(gpa, source[second_end..]);
        },
        .insert_fragment => {
            const pos = pickPosition(random, source);
            try out.appendSlice(gpa, source[0..pos]);
            try out.appendSlice(gpa, fragments[random.uintLessThan(usize, fragments.len)]);
            try out.appendSlice(gpa, source[pos..]);
        },
        .truncate => {
            if (source.len == 0) return;
            try out.appendSlice(gpa, source[0..random.uintLessThan(usize, source.len)]);
        },
    }
}

// ----------------------------------------------------------------------------
// Iteration control
// ----------------------------------------------------------------------------

const default_mutants_per_input: usize = 4;

const IterationsError = error{InvalidFuzzIterations};

/// The mutant count per input. `raw` is the value of `ZTTP_FUZZ_ITERATIONS`
/// when set. A value that is not a positive integer is an error, because a typo
/// that silently fell back to the default would make a long run look like a
/// short one.
fn parseMutantsPerInput(raw: ?[]const u8) IterationsError!usize {
    const text = raw orelse return default_mutants_per_input;
    const value = std.fmt.parseInt(usize, text, 10) catch return error.InvalidFuzzIterations;
    if (value == 0) return error.InvalidFuzzIterations;
    return value;
}

fn mutantsPerInput() IterationsError!usize {
    const raw: ?[]const u8 = if (std.c.getenv("ZTTP_FUZZ_ITERATIONS")) |ptr| std.mem.span(ptr) else null;
    return parseMutantsPerInput(raw);
}

// ----------------------------------------------------------------------------
// Inputs
// ----------------------------------------------------------------------------

const InputRoot = struct {
    /// Directory relative to the repository root, which is the working
    /// directory of every `zig build` test step.
    dir: []const u8,
    /// Files with a `.ts` or `.tsx` extension below `dir`. The test fails when
    /// fewer are found. Raise it in the commit that adds files, to the count the
    /// test finds. Never lower it to make a deletion pass.
    floor: usize,
};

const input_roots = [_]InputRoot{
    .{ .dir = "tests/corpus", .floor = 129 },
    .{ .dir = "examples", .floor = 61 },
};

const max_file_bytes = 1024 * 1024;

const InputError = error{InputsBelowFloor};

fn isSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

/// The `.ts` and `.tsx` paths below `dir_path`, relative to the working
/// directory and sorted. The caller frees each path and the slice.
fn discoverSources(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isSourcePath(entry.path)) continue;
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        errdefer gpa.free(full);
        try paths.append(gpa, full);
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return paths.toOwnedSlice(gpa);
}

fn freeSources(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}

fn requireFloor(found: usize, floor: usize) InputError!void {
    if (found < floor) return error.InputsBelowFloor;
}

// ----------------------------------------------------------------------------
// Runner
// ----------------------------------------------------------------------------

const Stats = struct {
    inputs: usize = 0,
    mutants: usize = 0,
    by_kind: [kind_count]usize = @splat(0),
    /// Mutants whose check returned a result.
    results: usize = 0,
    /// Mutants whose check returned an allowed error.
    errors: usize = 0,
    /// Mutants whose result carried at least one diagnostic.
    with_diagnostics: usize = 0,
    /// Diagnostics whose position was checked.
    diagnostics: usize = 0,
    /// Mutants whose second run was compared with the first.
    replays: usize = 0,
    /// Contract violations. Each one printed its mutant.
    failures: usize = 0,
};

const max_printed_failures = 8;
const max_printed_mutant = 4096;

fn fail(
    stats: *Stats,
    path: []const u8,
    index: usize,
    kind: Kind,
    mutant: []const u8,
    comptime what: []const u8,
    args: anytype,
) void {
    stats.failures += 1;
    if (stats.failures > max_printed_failures) return;
    std.debug.print("pipeline mutation failure: " ++ what ++ "\n  input {s}, mutant {d}, kind {s}, {d} bytes\n", args ++ .{ path, index, @tagName(kind), mutant.len });
    const shown = mutant[0..@min(mutant.len, max_printed_mutant)];
    std.debug.print("  mutant{s}:\n{f}\n", .{ if (shown.len < mutant.len) " (cut)" else "", std.zig.fmtString(shown) });
}

/// Run the check once on `source`. A result comes back as its serialization
/// and the diagnostics' position verdict. An error comes back as itself.
const Outcome = union(enum) {
    result: struct { bytes: []u8, outside: ?struct { code: []const u8, line: u32, column: u32 }, diagnostics: usize },
    err: anyerror,
};

fn runOnce(gpa: std.mem.Allocator, source: []const u8, path: []const u8) !Outcome {
    var result = precompile.runCheckOnlyFromSourceWithOptions(gpa, source, path, .{
        .json_mode = true,
        .persist_witnesses = false,
    }) catch |err| return .{ .err = err };
    defer result.deinit(gpa);
    return .{ .result = .{
        .bytes = try serialize(gpa, &result),
        .outside = if (firstDiagnosticOutside(source, result.json_diagnostics.items)) |at| .{
            .code = result.json_diagnostics.items[at].code,
            .line = result.json_diagnostics.items[at].line,
            .column = result.json_diagnostics.items[at].column,
        } else null,
        .diagnostics = result.json_diagnostics.items.len,
    } };
}

fn checkMutant(
    gpa: std.mem.Allocator,
    stats: *Stats,
    path: []const u8,
    index: usize,
    kind: Kind,
    mutant: []const u8,
) !void {
    const first = try runOnce(gpa, mutant, path);
    defer switch (first) {
        .result => |r| gpa.free(r.bytes),
        .err => {},
    };
    switch (first) {
        .err => |err| {
            if (isAllowedError(err)) {
                stats.errors += 1;
            } else {
                fail(stats, path, index, kind, mutant, "the check returned error.{s}, which is not in the allowed list", .{@errorName(err)});
            }
        },
        .result => |r| {
            stats.results += 1;
            stats.diagnostics += r.diagnostics;
            if (r.diagnostics > 0) stats.with_diagnostics += 1;
            if (r.outside) |at| {
                fail(stats, path, index, kind, mutant, "diagnostic {s} at line {d}, column {d} lies outside the mutant", .{ at.code, at.line, at.column });
            }
        },
    }

    const second = try runOnce(gpa, mutant, path);
    defer switch (second) {
        .result => |r| gpa.free(r.bytes),
        .err => {},
    };
    stats.replays += 1;
    switch (first) {
        .err => |a| switch (second) {
            .err => |b| if (a != b) {
                fail(stats, path, index, kind, mutant, "two runs returned error.{s} and error.{s}", .{ @errorName(a), @errorName(b) });
            },
            .result => fail(stats, path, index, kind, mutant, "the first run returned error.{s} and the second a result", .{@errorName(a)}),
        },
        .result => |a| switch (second) {
            .err => |b| fail(stats, path, index, kind, mutant, "the first run returned a result and the second error.{s}", .{@errorName(b)}),
            .result => |b| if (!std.mem.eql(u8, a.bytes, b.bytes)) {
                fail(stats, path, index, kind, mutant, "two runs gave different diagnostics\n--- first ---\n{s}--- second ---\n{s}", .{ a.bytes, b.bytes });
            },
        },
    }
}

fn mutateFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    path: []const u8,
    per_input: usize,
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(source);
    stats.inputs += 1;

    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0x5a54_5455_3334, path));
    const random = prng.random();
    var mutant: std.ArrayList(u8) = .empty;
    defer mutant.deinit(gpa);
    for (0..per_input) |index| {
        const kind: Kind = @enumFromInt(stats.mutants % kind_count);
        try applyMutation(gpa, random, kind, source, &mutant);
        stats.mutants += 1;
        stats.by_kind[@intFromEnum(kind)] += 1;
        try checkMutant(gpa, stats, path, index, kind, mutant.items);
    }
}

fn runRoots(gpa: std.mem.Allocator, io: std.Io, roots: []const InputRoot, per_input: usize) !Stats {
    var stats: Stats = .{};
    for (roots) |root| {
        const paths = try discoverSources(gpa, io, root.dir);
        defer freeSources(gpa, paths);
        try requireFloor(paths.len, root.floor);
        for (paths) |path| try mutateFile(gpa, io, &stats, path, per_input);
    }
    return stats;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "pipeline mutation: the check holds its contract on mutated corpus and examples" {
    const gpa = std.testing.allocator;
    const per_input = try mutantsPerInput();
    const stats = try runRoots(gpa, std.testing.io, &input_roots, per_input);

    var floor_total: usize = 0;
    for (input_roots) |root| floor_total += root.floor;
    try std.testing.expect(stats.inputs >= floor_total);
    try std.testing.expectEqual(stats.inputs * per_input, stats.mutants);
    for (stats.by_kind) |count| {
        try std.testing.expect(count == stats.mutants / kind_count or count == (stats.mutants + kind_count - 1) / kind_count);
    }
    try std.testing.expectEqual(stats.mutants, stats.results + stats.errors);
    try std.testing.expectEqual(stats.mutants, stats.replays);
    // A run that never produced a diagnostic checked no position.
    try std.testing.expect(stats.with_diagnostics > 0);
    try std.testing.expect(stats.diagnostics >= stats.with_diagnostics);
    try std.testing.expectEqual(@as(usize, 0), stats.failures);
}

test "pipeline mutation: an empty input directory is below the floor" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.md", .data = "not a source" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);

    const paths = try discoverSources(gpa, std.testing.io, path);
    defer freeSources(gpa, paths);
    try std.testing.expectEqual(@as(usize, 0), paths.len);
    try std.testing.expectError(error.InputsBelowFloor, requireFloor(paths.len, 1));
    try requireFloor(0, 0);
}

test "pipeline mutation: discovery keeps only ts and tsx sources" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.ts", .data = "const a = 1;" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/b.tsx", .data = "const b = 2;" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.sql", .data = "select 1;" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d.jsonl", .data = "{}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);

    const paths = try discoverSources(gpa, std.testing.io, path);
    defer freeSources(gpa, paths);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "/a.ts"));
    try std.testing.expect(std.mem.endsWith(u8, paths[1], "/sub/b.tsx"));
}

fn diagnosticAt(line: u32, column: u32) precompile.json_diag.JsonDiagnostic {
    return .{
        .code = "ZTS000",
        .severity = "error",
        .message = "probe",
        .file = "probe.ts",
        .line = line,
        .column = column,
        .suggestion = null,
    };
}

test "pipeline mutation: the position contract refuses a line or column outside the source" {
    const source = "ab\ncde\n\nf";
    // Lines: "ab" (2), "cde" (3), "" (0), "f" (1). A column may be one past the end.
    try std.testing.expectEqual(@as(?usize, null), firstDiagnosticOutside(source, &.{
        diagnosticAt(1, 1),
        diagnosticAt(1, 3),
        diagnosticAt(2, 4),
        diagnosticAt(3, 1),
        diagnosticAt(4, 2),
    }));
    const outside = [_]precompile.json_diag.JsonDiagnostic{
        diagnosticAt(0, 1),
        diagnosticAt(5, 1),
        diagnosticAt(1, 0),
        diagnosticAt(1, 4),
        diagnosticAt(3, 2),
        diagnosticAt(4, 3),
    };
    for (outside) |diag| {
        try std.testing.expectEqual(@as(?usize, 0), firstDiagnosticOutside(source, &.{diag}));
    }
    // The verdict names the first offender, not the first diagnostic.
    try std.testing.expectEqual(@as(?usize, 1), firstDiagnosticOutside(source, &.{ diagnosticAt(1, 1), diagnosticAt(9, 1) }));
    try std.testing.expectEqual(@as(?usize, 0), firstDiagnosticOutside("", &.{diagnosticAt(2, 1)}));
    try std.testing.expectEqual(@as(?usize, null), firstDiagnosticOutside("", &.{diagnosticAt(1, 1)}));
}

test "pipeline mutation: the error list is closed" {
    try std.testing.expect(isAllowedError(error.OutOfMemory));
    try std.testing.expect(isAllowedError(error.MissingSqlSchema));
    try std.testing.expect(!isAllowedError(error.FileNotFound));
    try std.testing.expect(!isAllowedError(error.Unexpected));
}

test "pipeline mutation: ZTTP_FUZZ_ITERATIONS accepts only a positive integer" {
    try std.testing.expectEqual(default_mutants_per_input, try parseMutantsPerInput(null));
    try std.testing.expectEqual(@as(usize, 8), try parseMutantsPerInput("8"));
    try std.testing.expectEqual(@as(usize, 800), try parseMutantsPerInput("800"));
    for ([_][]const u8{ "", "0", "-8", "8x", "ten", "1.5" }) |bad| {
        try std.testing.expectError(error.InvalidFuzzIterations, parseMutantsPerInput(bad));
    }
}

test "pipeline mutation: every kind changes a sample source and repeats from its seed" {
    const gpa = std.testing.allocator;
    const sample =
        \\import { a } from "zttp:json";
        \\export function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(gpa);
    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(gpa);
    for (0..kind_count) |k| {
        const kind: Kind = @enumFromInt(k);
        var changed = false;
        // Some single draws are no-ops (a swap of equal tokens), so look at a few.
        for (0..8) |draw| {
            var prng_a: std.Random.DefaultPrng = .init(draw);
            var prng_b: std.Random.DefaultPrng = .init(draw);
            try applyMutation(gpa, prng_a.random(), kind, sample, &first);
            try applyMutation(gpa, prng_b.random(), kind, sample, &second);
            try std.testing.expectEqualStrings(first.items, second.items);
            if (!std.mem.eql(u8, first.items, sample)) changed = true;
        }
        try std.testing.expect(changed);
    }
}

test "pipeline mutation: mutation of an empty source does not index past it" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(1);
    for (0..kind_count) |k| {
        try applyMutation(gpa, prng.random(), @enumFromInt(k), "", &out);
    }
    for (0..kind_count) |k| {
        try applyMutation(gpa, prng.random(), @enumFromInt(k), "x", &out);
    }
}

// ----------------------------------------------------------------------------
// Regression inputs
//
// Each input below is a mutant the sweep found violating the contract. It runs
// through the same checks as a swept mutant, plus the exact outcome its fix
// restored.
// ----------------------------------------------------------------------------

fn expectContractHolds(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var stats: Stats = .{};
    try checkMutant(gpa, &stats, path, 0, .flip_bit, source);
    try std.testing.expectEqual(@as(usize, 0), stats.failures);
    try std.testing.expectEqual(@as(usize, 1), stats.replays);
}

test "pipeline mutation regression: a string continuation does not shift the line of a later strip diagnostic" {
    // tests/corpus/parse/bad/backslash_before_newline.ts with the space after
    // `return` flipped to a quote. The unterminated string on line 5 was
    // reported on line 4, which the position contract refuses at column 29.
    const gpa = std.testing.allocator;
    const path = "regression/backslash_before_newline_flip.ts";
    const source = "// Proves: a backslash before a real newline inside a string is refused (ZTS045).\n" ++
        "function handler(req: Request): Response {\n" ++
        "    const s = \"a\\\nb\";\n" ++
        "    return\"Response.text(s);\n" ++
        "}\n";
    try expectContractHolds(gpa, path, source);

    const outcome = try runOnce(gpa, source, path);
    defer switch (outcome) {
        .result => |r| gpa.free(r.bytes),
        .err => {},
    };
    switch (outcome) {
        .err => return error.ExpectedResult,
        .result => |r| {
            try std.testing.expect(std.mem.indexOf(u8, r.bytes, "\"code\":\"ZTS008\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, r.bytes, "\"line\":5,") != null);
        },
    }
}

test "pipeline mutation regression: a schema literal with a repeated key is a dynamic schema, not an error" {
    // examples/sql/sql-crud.ts with the `properties:` line of its schema
    // duplicated. The check returned error.DuplicateField from
    // `checkSchemaCompilability` and `zts check --json` died with a trace.
    const gpa = std.testing.allocator;
    const path = "regression/schema_repeated_key.ts";
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\
        \\schemaCompile(
        \\  "todo.create",
        \\  JSON.stringify({
        \\    type: "object",
        \\    properties: { title: { type: "string" } },
        \\    properties: { title: { type: "string" } },
        \\  }),
        \\);
        \\
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    try expectContractHolds(gpa, path, source);

    const outcome = try runOnce(gpa, source, path);
    defer switch (outcome) {
        .result => |r| gpa.free(r.bytes),
        .err => {},
    };
    try std.testing.expect(outcome == .result);
}
