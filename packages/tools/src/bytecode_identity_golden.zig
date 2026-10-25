//! Bytecode identity golden (reset phase R0).
//!
//! Later reset phases refactor IR construction and split files. This test shows
//! that the bytecode `zttp build` emits for each tracked handler does not move.
//! Each input goes through `precompile.compileHandler` with the options of the
//! build command (`build_command.zig` `compileCapability`), so the bytes are
//! the ones a deploy artifact carries. The SHA-256 covers the entry module
//! bytes, then each dependency module as a little-endian u64 length and its
//! bytes. A handler without file imports therefore hashes as its plain bytes.
//!
//! Inputs: every `.ts` file under `examples/` and `tests/corpus/check/good/`.
//! A source the compile refuses is recorded as `<path> refused <error>`.
//!
//! The golden is `golden_path`, one `<path> <sha256 | refused error>` line per
//! input, sorted by path. Regenerate it only after a deliberate codegen change:
//! run this suite with `ZTTP_WRITE_BYTECODE_GOLDEN=1` from a fresh cache,
//! because the run step is cached and does not see the variable. Review the diff.
//! The run step does not track the handler sources, so after you edit a handler
//! run the suite from a fresh cache before you trust a pass.
//!
//! Paths are repository-relative and the test reads them from the working
//! directory, which is the repository root under `zig build`, as in
//! `flow_precision_expectations.zig`.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");

const file_io = zts.file_io;

const golden_path = "packages/tools/src/bytecode_identity_golden.txt";
/// Embedded so that an edit to the golden rebuilds the test. The build cache
/// does not track the handler sources, which are read at run time.
const golden = @embedFile("bytecode_identity_golden.txt");
const input_roots = [_][]const u8{ "examples", "tests/corpus/check/good" };
/// Measured 63 inputs on 2026-10-25 (33 examples, 30 corpus cases). A wrong
/// working directory or an empty walk must not pass over zero inputs.
const input_floor: usize = 60;
const max_source_bytes: usize = 1 << 20;

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Repository-relative paths of every `.ts` input, sorted. Caller frees.
fn collectInputs(allocator: std.mem.Allocator) ![][]u8 {
    const io = std.testing.io;
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (input_roots) |root_path| {
        var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ts")) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, entry.path });
            errdefer allocator.free(path);
            try paths.append(allocator, path);
        }
    }
    std.mem.sort([]u8, paths.items, {}, lessThan);
    return paths.toOwnedSlice(allocator);
}

/// One golden line for `path`, without its newline. Caller frees.
fn goldenLine(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const source = try file_io.readFile(allocator, path, max_source_bytes);
    defer allocator.free(source);

    var compiled = precompile.compileHandler(allocator, source, path, .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    }) catch |err| return std.fmt.allocPrint(allocator, "{s} refused {s}", .{ path, @errorName(err) });
    defer compiled.deinit(allocator);

    if (compiled.verify_failed) return std.fmt.allocPrint(allocator, "{s} refused VerificationFailed", .{path});
    if (compiled.bytecode.len == 0) return std.fmt.allocPrint(allocator, "{s} refused NoBytecode", .{path});

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(compiled.bytecode);
    for (compiled.dep_bytecodes orelse &.{}) |dep| {
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, dep.len)));
        hasher.update(dep);
    }
    const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ path, &hex });
}

fn containsLine(lines: []const []const u8, line: []const u8) bool {
    for (lines) |candidate| {
        if (std.mem.eql(u8, candidate, line)) return true;
    }
    return false;
}

test "emitted bytecode matches the committed identity golden" {
    const allocator = std.testing.allocator;

    const paths = try collectInputs(allocator);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    if (paths.len < input_floor) {
        std.debug.print("bytecode identity: {d} inputs, floor is {d}; run from the repository root\n", .{ paths.len, input_floor });
        return error.InputFloor;
    }

    var actual: std.ArrayList([]u8) = .empty;
    defer {
        for (actual.items) |line| allocator.free(line);
        actual.deinit(allocator);
    }
    var digested: usize = 0;
    for (paths) |path| {
        const line = try goldenLine(allocator, path);
        errdefer allocator.free(line);
        if (std.mem.indexOf(u8, line, " refused ") == null) digested += 1;
        try actual.append(allocator, line);
    }
    // Refusing every input would satisfy the floor over a broken compile path.
    try std.testing.expect(digested >= input_floor / 2);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (actual.items) |line| {
        try text.appendSlice(allocator, line);
        try text.append(allocator, '\n');
    }

    if (std.testing.environ.getPosix("ZTTP_WRITE_BYTECODE_GOLDEN") != null) {
        try file_io.writeFile(allocator, golden_path, text.items);
        std.debug.print("bytecode identity: wrote {d} lines ({d} digested) to {s}\n", .{ actual.items.len, digested, golden_path });
        return;
    }

    var golden_lines: std.ArrayList([]const u8) = .empty;
    defer golden_lines.deinit(allocator);
    var split = std.mem.splitScalar(u8, std.mem.trimEnd(u8, golden, "\n"), '\n');
    while (split.next()) |line| try golden_lines.append(allocator, line);

    var drifted: usize = 0;
    for (actual.items) |line| {
        if (containsLine(golden_lines.items, line)) continue;
        std.debug.print("bytecode identity drift: {s}\n  actual line: {s}\n", .{ line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len], line });
        drifted += 1;
    }
    for (golden_lines.items) |line| {
        var found = false;
        for (actual.items) |candidate| {
            if (std.mem.eql(u8, candidate, line)) found = true;
        }
        if (found) continue;
        std.debug.print("bytecode identity golden line has no match: {s}\n", .{line});
    }
    try std.testing.expectEqual(@as(usize, 0), drifted);
    try std.testing.expectEqualStrings(golden, text.items);
}
