//! Runs the committed mutation probes against the proof-checker test root.
//!
//! Each mutant gets a private copy of the working-tree package and a fresh
//! local Zig cache. Compilation and execution are separate so a source edit
//! that does not compile cannot be mistaken for a killed mutant.

const std = @import("std");

const Mutant = struct {
    id: []const u8,
    file: []const u8,
    old: []const u8,
    new: []const u8,
    equivalent: ?[]const u8,
};

// Read at run time, not @import-ed. An imported .zon was measured not to
// invalidate the build cache when only the list changed: the runner kept
// probing a deleted list and reported rows that no longer existed.
var mutants: []const Mutant = &.{};

// The Phase 0 suite contains 276 tests. This floor allows only a small loss.
const minimum_test_count: usize = 270;
const test_timeout_seconds: u64 = 10;
const process_output_limit: std.Io.Limit = .limited(8 * 1024 * 1024);
const baseline_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } };
const compile_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } };
const test_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(test_timeout_seconds), .clock = .awake } };

const Outcome = enum {
    pending,
    killed,
    survived,
    no_compile,
    timeout,
    no_apply,
    harness_error,
};

const Result = struct {
    outcome: Outcome = .pending,
    output: []u8 = &.{},
    match_count: usize = 0,
};

const Work = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    zig_exe: []const u8,
    kernel_path: []const u8,
    temp_path: []const u8,
    results: []Result,
    next: std.atomic.Value(usize) = .init(0),
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.GateFailed and err != error.InvalidArguments) {
            std.debug.print("proof-checker mutants: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const zig_arg = args.next() orelse return usage();
    const kernel_arg = args.next() orelse return usage();
    const list_arg = args.next() orelse return usage();
    if (args.next() != null) return usage();

    var list_arena = std.heap.ArenaAllocator.init(allocator);
    defer list_arena.deinit();
    mutants = loadList(list_arena.allocator(), io, list_arg) catch return error.GateFailed;

    const zig_exe = try std.Io.Dir.cwd().realPathFileAlloc(io, zig_arg, allocator);
    defer allocator.free(zig_exe);
    const kernel_path = try std.Io.Dir.cwd().realPathFileAlloc(io, kernel_arg, allocator);
    defer allocator.free(kernel_path);

    const temp_path = try createPrivateTemp(allocator, io, init.environ_map);
    defer allocator.free(temp_path);
    defer std.Io.Dir.cwd().deleteTree(io, temp_path) catch |err| {
        std.debug.print("proof-checker mutants: could not remove {s}: {s}\n", .{ temp_path, @errorName(err) });
    };

    const floor_ok = runFloor(allocator, io, zig_exe, kernel_path, temp_path) catch |err| {
        std.debug.print("proof-checker mutants: floor could not run: {s}\n", .{@errorName(err)});
        return error.GateFailed;
    };
    if (!floor_ok) return error.GateFailed;

    // The floor and every mutant must see one immutable working-tree snapshot.
    // In particular, a concurrent edit must not give later rows a newer suite.
    const snapshot_path = try std.fs.path.join(allocator, &.{ temp_path, "baseline" });
    defer allocator.free(snapshot_path);

    const production_files = loadProductionFiles(allocator, io, snapshot_path) catch |err| {
        std.debug.print("proof-checker mutants: could not enumerate kernel sources: {s}\n", .{@errorName(err)});
        return error.GateFailed;
    };
    defer {
        for (production_files) |file| allocator.free(file);
        allocator.free(production_files);
    }
    if (!validateList(production_files)) return error.GateFailed;

    const results = try allocator.alloc(Result, mutants.len);
    defer allocator.free(results);
    @memset(results, .{});
    defer for (results) |result| std.heap.smp_allocator.free(result.output);

    var work = Work{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .zig_exe = zig_exe,
        .kernel_path = snapshot_path,
        .temp_path = temp_path,
        .results = results,
    };

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = @max(@as(usize, 1), @min(cpu_count, mutants.len));
    std.debug.print(
        "proof-checker mutants: running {d} rows with {d} workers; per-test timeout {d}s\n",
        .{ mutants.len, worker_count, test_timeout_seconds },
    );

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    var joined = false;
    errdefer if (!joined) for (threads[0..spawned]) |thread| thread.join();
    while (spawned < worker_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, worker, .{&work});
    }
    for (threads) |thread| thread.join();
    joined = true;

    const failed = printReport(production_files, results);
    if (failed) return error.GateFailed;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: proof-checker-mutants <zig-exe> <proof-checker-package> <mutant-list.zon>\n", .{});
    return error.InvalidArguments;
}

fn createPrivateTemp(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const temp_root = environ.get("TMPDIR") orelse "/tmp";
    const stamp: u64 = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const name = try std.fmt.allocPrint(allocator, "zttp-proof-checker-mutants-{x}-{d}", .{ stamp, attempt });
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ temp_root, name });
        std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
    return error.CouldNotCreateTemporaryDirectory;
}

fn runFloor(
    allocator: std.mem.Allocator,
    io: std.Io,
    zig_exe: []const u8,
    kernel_path: []const u8,
    temp_path: []const u8,
) !bool {
    const copy_path = try std.fs.path.join(allocator, &.{ temp_path, "baseline" });
    defer allocator.free(copy_path);
    try copyPackage(allocator, io, kernel_path, copy_path);

    const cache_path = try std.fs.path.join(allocator, &.{ temp_path, "baseline-cache" });
    defer allocator.free(cache_path);
    defer std.Io.Dir.cwd().deleteTree(io, cache_path) catch {};

    const baseline = std.process.run(allocator, io, .{
        .argv = &.{ zig_exe, "test", "src/test_root.zig", "--cache-dir", cache_path },
        .cwd = .{ .path = copy_path },
        .stdout_limit = process_output_limit,
        .stderr_limit = process_output_limit,
        .timeout = baseline_timeout,
    }) catch |err| {
        std.debug.print("proof-checker mutants: unmutated suite failed to run: {s}\n", .{@errorName(err)});
        return false;
    };
    defer allocator.free(baseline.stdout);
    defer allocator.free(baseline.stderr);

    if (!termSucceeded(baseline.term)) {
        std.debug.print("proof-checker mutants: unmutated suite failed\n{s}{s}\n", .{ baseline.stdout, baseline.stderr });
        return false;
    }

    const count = parsePassingTestCount(baseline.stdout) orelse parsePassingTestCount(baseline.stderr) orelse {
        std.debug.print(
            "proof-checker mutants: floor failed: unmutated suite output has no parsed test count\n{s}{s}\n",
            .{ baseline.stdout, baseline.stderr },
        );
        return false;
    };
    if (count < minimum_test_count) {
        std.debug.print(
            "proof-checker mutants: floor failed: unmutated suite ran {d} tests, below the stated floor of {d}\n",
            .{ count, minimum_test_count },
        );
        return false;
    }
    std.debug.print("proof-checker mutants: floor passed ({d} tests, required {d})\n", .{ count, minimum_test_count });
    return true;
}

fn parsePassingTestCount(output: []const u8) ?usize {
    if (digitsBefore(output, " tests passed.")) |count| return count;
    return digitsBefore(output, " passed;");
}

fn digitsBefore(output: []const u8, suffix: []const u8) ?usize {
    const suffix_at = std.mem.findLast(u8, output, suffix) orelse return null;
    var start = suffix_at;
    while (start > 0 and std.ascii.isDigit(output[start - 1])) start -= 1;
    if (start == suffix_at) return null;
    return std.fmt.parseUnsigned(usize, output[start..suffix_at], 10) catch null;
}

fn loadProductionFiles(allocator: std.mem.Allocator, io: std.Io, kernel_path: []const u8) ![][]u8 {
    const src_path = try std.fs.path.join(allocator, &.{ kernel_path, "src" });
    defer allocator.free(src_path);
    var dir = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "root.zig") or std.mem.eql(u8, entry.name, "test_root.zig")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return files.toOwnedSlice(allocator);
}

fn validateList(production_files: []const []u8) bool {
    var valid = true;
    if (mutants.len == 0) {
        std.debug.print("proof-checker mutants: floor failed: mutant list is empty\n", .{});
        valid = false;
    }

    for (mutants, 0..) |mutant, index| {
        if (mutant.id.len == 0 or mutant.old.len == 0) {
            std.debug.print("proof-checker mutants: floor failed: row {d} has an empty id or old anchor\n", .{index});
            valid = false;
        }
        if (std.mem.findScalar(u8, mutant.file, '/') != null or
            std.mem.findScalar(u8, mutant.file, '\\') != null or
            !std.mem.endsWith(u8, mutant.file, ".zig"))
        {
            std.debug.print("proof-checker mutants: floor failed: row {s} has invalid file '{s}'\n", .{ mutant.id, mutant.file });
            valid = false;
        }
        if (mutant.equivalent) |reason| {
            if (reason.len == 0) {
                std.debug.print("proof-checker mutants: floor failed: row {s} has an empty equivalent reason\n", .{mutant.id});
                valid = false;
            }
        }
        for (mutants[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, mutant.id)) {
                std.debug.print("proof-checker mutants: floor failed: duplicate id {s}\n", .{mutant.id});
                valid = false;
            }
        }
        var known_file = false;
        for (production_files) |file| {
            if (std.mem.eql(u8, file, mutant.file)) {
                known_file = true;
                break;
            }
        }
        if (!known_file) {
            std.debug.print("proof-checker mutants: floor failed: row {s} names non-production file {s}\n", .{ mutant.id, mutant.file });
            valid = false;
        }
    }

    for (production_files) |file| {
        var found = false;
        for (mutants) |mutant| {
            if (std.mem.eql(u8, file, mutant.file)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("proof-checker mutants: floor failed: no row covers production source {s}\n", .{file});
            valid = false;
        }
    }
    return valid;
}

fn worker(work: *Work) void {
    while (true) {
        const index = work.next.fetchAdd(1, .monotonic);
        if (index >= mutants.len) return;
        work.results[index] = runMutant(work, index) catch |err| .{
            .outcome = .harness_error,
            .output = std.fmt.allocPrint(work.allocator, "{s}", .{@errorName(err)}) catch &.{},
        };
    }
}

fn runMutant(work: *const Work, index: usize) !Result {
    const mutant = mutants[index];
    const row_name = try std.fmt.allocPrint(work.allocator, "row-{d}-{s}", .{ index, mutant.id });
    defer work.allocator.free(row_name);
    const copy_path = try std.fs.path.join(work.allocator, &.{ work.temp_path, row_name });
    defer work.allocator.free(copy_path);
    try copyPackage(work.allocator, work.io, work.kernel_path, copy_path);

    const file_path = try std.fs.path.join(work.allocator, &.{ copy_path, "src", mutant.file });
    defer work.allocator.free(file_path);
    const source = try std.Io.Dir.cwd().readFileAlloc(work.io, file_path, work.allocator, .unlimited);
    defer work.allocator.free(source);
    const match_count = std.mem.count(u8, source, mutant.old);
    if (match_count != 1) return .{ .outcome = .no_apply, .match_count = match_count };

    const changed = try std.mem.replaceOwned(u8, work.allocator, source, mutant.old, mutant.new);
    defer work.allocator.free(changed);
    try std.Io.Dir.cwd().writeFile(work.io, .{ .sub_path = file_path, .data = changed });

    const cache_path = try std.fs.path.join(work.allocator, &.{ copy_path, ".mutant-cache" });
    defer work.allocator.free(cache_path);
    defer std.Io.Dir.cwd().deleteTree(work.io, cache_path) catch {};
    const test_binary = try std.fs.path.join(work.allocator, &.{ copy_path, "mutant-test" });
    defer work.allocator.free(test_binary);
    const emit_arg = try std.fmt.allocPrint(work.allocator, "-femit-bin={s}", .{test_binary});
    defer work.allocator.free(emit_arg);

    const compile = std.process.run(work.allocator, work.io, .{
        .argv = &.{ work.zig_exe, "test", "src/test_root.zig", "--test-no-exec", emit_arg, "--cache-dir", cache_path },
        .cwd = .{ .path = copy_path },
        .stdout_limit = process_output_limit,
        .stderr_limit = process_output_limit,
        .timeout = compile_timeout,
    }) catch |err| switch (err) {
        error.Timeout => return .{ .outcome = .timeout },
        else => return .{
            .outcome = .harness_error,
            .output = try std.fmt.allocPrint(work.allocator, "compiler invocation: {s}", .{@errorName(err)}),
        },
    };
    defer work.allocator.free(compile.stdout);
    defer work.allocator.free(compile.stderr);
    if (!termSucceeded(compile.term)) {
        return .{
            .outcome = .no_compile,
            .output = try combineOutput(work.allocator, compile.stdout, compile.stderr),
        };
    }

    const execution = std.process.run(work.allocator, work.io, .{
        .argv = &.{test_binary},
        .cwd = .{ .path = copy_path },
        .stdout_limit = process_output_limit,
        .stderr_limit = process_output_limit,
        .timeout = test_timeout,
    }) catch |err| switch (err) {
        error.Timeout => return .{ .outcome = .timeout },
        else => return .{
            .outcome = .harness_error,
            .output = try std.fmt.allocPrint(work.allocator, "test invocation: {s}", .{@errorName(err)}),
        },
    };
    defer work.allocator.free(execution.stdout);
    defer work.allocator.free(execution.stderr);
    return .{ .outcome = if (termSucceeded(execution.term)) .survived else .killed };
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn combineOutput(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stdout, stderr });
}

fn copyPackage(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    var source = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source.close(io);
    var dest = try std.Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest.close(io);
    var walker = try source.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(io, entry.path),
        .file => try source.copyFile(entry.path, dest, entry.path, io, .{ .make_path = true }),
        else => return error.UnsupportedPackageEntry,
    };
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn printReport(production_files: []const []u8, results: []const Result) bool {
    var gate_failed = false;
    var total_equivalent: usize = 0;
    var total_killed: usize = 0;
    var total_survived: usize = 0;
    var total_no_compile: usize = 0;
    var total_timeout: usize = 0;
    var total_no_apply: usize = 0;
    var total_harness_error: usize = 0;

    std.debug.print("\nfile                       rows  equivalent  killed  survived  kill rate\n", .{});
    std.debug.print("-------------------------  ----  ----------  ------  --------  ---------\n", .{});
    for (production_files) |file| {
        var rows: usize = 0;
        var equivalent: usize = 0;
        var killed: usize = 0;
        var survived: usize = 0;
        var non_equivalent: usize = 0;
        var non_equivalent_killed: usize = 0;
        for (mutants, results) |mutant, result| {
            if (!std.mem.eql(u8, mutant.file, file)) continue;
            rows += 1;
            if (mutant.equivalent != null) equivalent += 1 else non_equivalent += 1;
            switch (result.outcome) {
                .killed => {
                    killed += 1;
                    if (mutant.equivalent == null) non_equivalent_killed += 1;
                },
                .timeout => {
                    killed += 1;
                    if (mutant.equivalent == null) non_equivalent_killed += 1;
                },
                .survived => survived += 1,
                else => {},
            }
        }
        const rate = if (non_equivalent == 0) 0 else non_equivalent_killed * 100 / non_equivalent;
        std.debug.print("{s: <25}  {d: >4}  {d: >10}  {d: >6}  {d: >8}  {d: >3}% ({d}/{d})\n", .{
            file,
            rows,
            equivalent,
            killed,
            survived,
            rate,
            non_equivalent_killed,
            non_equivalent,
        });
    }

    std.debug.print("\nsurvivors:\n", .{});
    var survivor_count: usize = 0;
    for (mutants, results) |mutant, result| {
        if (result.outcome == .survived) {
            survivor_count += 1;
            std.debug.print("  {s}\t{s}\t{s}\n", .{ mutant.id, mutant.file, firstLine(mutant.old) });
        }
    }
    if (survivor_count == 0) std.debug.print("  none\n", .{});

    std.debug.print("\ntimeouts (counted as killed):\n", .{});
    var timeout_count: usize = 0;
    for (mutants, results) |mutant, result| {
        if (result.outcome == .timeout) {
            timeout_count += 1;
            std.debug.print("  {s}\t{s}\n", .{ mutant.id, mutant.file });
        }
    }
    if (timeout_count == 0) std.debug.print("  none\n", .{});

    std.debug.print("\ninvalid rows and stale equivalent rows:\n", .{});
    var invalid_count: usize = 0;
    for (mutants, results) |mutant, result| {
        const equivalent = mutant.equivalent != null;
        switch (result.outcome) {
            .killed => {
                total_killed += 1;
                if (equivalent) {
                    invalid_count += 1;
                    gate_failed = true;
                    std.debug.print("  {s}: equivalent row was killed - reason is stale\n", .{mutant.id});
                }
            },
            .timeout => {
                total_killed += 1;
                total_timeout += 1;
                if (equivalent) {
                    invalid_count += 1;
                    gate_failed = true;
                    std.debug.print("  {s}: equivalent row timed out - reason is stale\n", .{mutant.id});
                }
            },
            .survived => {
                total_survived += 1;
                if (!equivalent) gate_failed = true;
            },
            .no_compile => {
                total_no_compile += 1;
                invalid_count += 1;
                gate_failed = true;
                std.debug.print("  {s}: NOCOMPILE\n{s}\n", .{ mutant.id, result.output });
            },
            .no_apply => {
                total_no_apply += 1;
                invalid_count += 1;
                gate_failed = true;
                std.debug.print("  row {s} no longer applies - re-anchor it (found {d} matches)\n", .{ mutant.id, result.match_count });
            },
            .harness_error, .pending => {
                total_harness_error += 1;
                invalid_count += 1;
                gate_failed = true;
                std.debug.print("  {s}: harness error: {s}\n", .{ mutant.id, result.output });
            },
        }
        if (equivalent) total_equivalent += 1;
    }
    if (invalid_count == 0) std.debug.print("  none\n", .{});

    std.debug.print(
        "\ntotals: rows {d}, equivalent {d}, killed {d}, survived {d}, timeout {d}, NOCOMPILE {d}, no-apply {d}, harness errors {d}\n",
        .{ mutants.len, total_equivalent, total_killed, total_survived, total_timeout, total_no_compile, total_no_apply, total_harness_error },
    );
    return gate_failed;
}

fn loadList(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const Mutant {
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| {
        std.debug.print("proof-checker mutants: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    var diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc([]const Mutant, arena, source, &diag, .{ .free_on_error = false }) catch |err| {
        std.debug.print("proof-checker mutants: {s} is not a valid mutant list:\n{f}", .{ path, diag });
        return err;
    };
}
