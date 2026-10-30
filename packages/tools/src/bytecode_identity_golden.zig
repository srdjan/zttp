//! Bytecode identity golden (reset phase R0).
//!
//! Later reset phases refactor IR construction and split files. This gate shows
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
//! run `ZTTP_WRITE_BYTECODE_GOLDEN=1 zig build test-bytecode-identity`. Review
//! the diff.
//!
//! This file is the `main` of the `test-bytecode-identity` gate, wired in
//! build/bytecode_identity.zig. The gate step has side effects, so it runs on
//! every invocation and reads the handler sources each time. A source edit
//! cannot leave a stale pass. The gate exits 1 on any failure.
//!
//! Paths are repository-relative and the gate reads them from the working
//! directory, which is the repository root under `zig build`, as in
//! `flow_precision_expectations.zig`.

const std = @import("std");
const zts = @import("zts");
const precompile = @import("precompile.zig");

const file_io = zts.file_io;

const golden_path = "packages/tools/src/bytecode_identity_golden.txt";
/// Embedded so that an edit to the golden rebuilds the gate. The handler
/// sources are read at run time, and the gate step reruns on every invocation.
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
fn collectInputs(allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
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

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.GoldenDrift) std.debug.print("bytecode identity: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;

    const paths = try collectInputs(allocator, init.io);
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
    if (digested < input_floor / 2) {
        std.debug.print("bytecode identity: {d} inputs digested, floor is {d}\n", .{ digested, input_floor / 2 });
        return error.DigestedFloor;
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (actual.items) |line| {
        try text.appendSlice(allocator, line);
        try text.append(allocator, '\n');
    }

    if (init.environ_map.get("ZTTP_WRITE_BYTECODE_GOLDEN") != null) {
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
        drifted += 1;
    }
    if (drifted != 0) return error.GoldenDrift;
    if (!std.mem.eql(u8, golden, text.items)) {
        std.debug.print("bytecode identity drift: golden text differs from the emitted text\n", .{});
        return error.GoldenDrift;
    }
    std.debug.print("bytecode identity: {d} inputs match the golden ({d} digested)\n", .{ actual.items.len, digested });
}
