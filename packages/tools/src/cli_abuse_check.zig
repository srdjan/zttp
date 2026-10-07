//! CLI abuse check (U5.3).
//!
//! Runs the BUILT `zts` binary against hostile input in a new temporary
//! directory and pins what a caller such as an IDE or a CI job can rely on:
//! the process exits (it is not killed by a signal and does not hang), the
//! exit code is the exact one the CLI uses today, and with `--json` the
//! standard output is either empty or exactly one complete JSON document.
//!
//! Hostile inputs: an empty file, a missing path, a directory given as the
//! file, a file past the 10 MiB read cap, invalid UTF-8, a NUL byte, nesting
//! past the parser limit, and unknown flags.
//!
//! Each input runs twice, once in text mode and once with `--json`. Unknown
//! flags are a usage error that prints stderr text and no JSON, so those cases
//! assert an empty standard output.
//!
//! Project discovery walks every ancestor of the input path looking for
//! `zttp.json`. A stray `zttp.json` above the temporary directory would change
//! what `zts` does, so the check refuses to run when it finds one.
//!
//! The exit code is 1 for every case today. That is the observed contract,
//! not a design statement: `zts_main.zig` maps usage errors to 1, the analyzer
//! returns 1 when it reports an error or an unproven property, and an I/O
//! failure in text mode leaves `main` through an error return, which also
//! exits 1. A change to any of those fails this check on purpose.
//!
//! The check fails when it ran fewer cases than it declares.
//!
//! Usage: cli-abuse-check <zts>

const std = @import("std");

const Io = std.Io;

/// A file past the 10 MiB cap in `precompile.zig` (`readFilePosix`), by one byte.
const over_cap_bytes: usize = 10 * 1024 * 1024 + 1;
/// Parenthesis depth past the parser nesting limit (512).
const nest_depth: usize = 600;
/// Per-invocation deadline. The slowest case reads 10 MiB and finishes in well
/// under a second; the deadline only has to separate "slow" from "hung".
const deadline_seconds: i64 = 30;

const Input = enum {
    empty_file,
    missing_path,
    directory,
    over_cap,
    invalid_utf8,
    nul_byte,
    deep_nesting,
    unknown_flag,
};

const Mode = enum { text, json };

const Case = struct {
    name: []const u8,
    input: Input,
    mode: Mode,
    /// The exit code the CLI uses for this input today.
    exit_code: u8,
    /// For a JSON case that reports diagnostics: the code the first one carries.
    /// Null when the case reports no diagnostic.
    diagnostic_code: ?[]const u8 = null,
    /// For a JSON case: the value of the top-level `success` field.
    success: bool = false,
};

const cases = [_]Case{
    .{ .name = "empty file, text", .input = .empty_file, .mode = .text, .exit_code = 1 },
    .{ .name = "empty file, json", .input = .empty_file, .mode = .json, .exit_code = 1 },
    .{ .name = "missing path, text", .input = .missing_path, .mode = .text, .exit_code = 1 },
    .{ .name = "missing path, json", .input = .missing_path, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS000" },
    .{ .name = "directory as file, text", .input = .directory, .mode = .text, .exit_code = 1 },
    .{ .name = "directory as file, json", .input = .directory, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS000" },
    .{ .name = "file over the 10 MiB cap, text", .input = .over_cap, .mode = .text, .exit_code = 1 },
    .{ .name = "file over the 10 MiB cap, json", .input = .over_cap, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS000" },
    .{ .name = "invalid UTF-8, text", .input = .invalid_utf8, .mode = .text, .exit_code = 1 },
    .{ .name = "invalid UTF-8, json", .input = .invalid_utf8, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS046" },
    .{ .name = "NUL byte, text", .input = .nul_byte, .mode = .text, .exit_code = 1 },
    .{ .name = "NUL byte, json", .input = .nul_byte, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS002" },
    .{ .name = "nesting past the limit, text", .input = .deep_nesting, .mode = .text, .exit_code = 1 },
    .{ .name = "nesting past the limit, json", .input = .deep_nesting, .mode = .json, .exit_code = 1, .diagnostic_code = "ZTS044" },
    .{ .name = "unknown flag, text", .input = .unknown_flag, .mode = .text, .exit_code = 1 },
    .{ .name = "unknown flag, json", .input = .unknown_flag, .mode = .json, .exit_code = 1 },
};

const Check = struct {
    gpa: std.mem.Allocator,
    io: Io,
    zts: []const u8,
    /// The temporary directory the child runs in.
    work: []const u8,
    passed: usize = 0,
    failed: usize = 0,

    fn pass(self: *Check, name: []const u8) void {
        self.passed += 1;
        std.debug.print("  PASS  {s}\n", .{name});
    }

    fn fail(self: *Check, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.failed += 1;
        std.debug.print("  FAIL  {s}: " ++ fmt ++ "\n", .{name} ++ args);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const zts = args.next() orelse return usage();

    const tmp_root = init.environ_map.get("TMPDIR") orelse "/tmp";
    var name_buf: [64]u8 = undefined;
    const now: u64 = @intCast(Io.Clock.real.now(io).toNanoseconds());
    const work_name = try std.fmt.bufPrint(&name_buf, "zts-cli-abuse-{x}", .{now});
    const work = try std.fs.path.join(gpa, &.{ tmp_root, work_name });
    defer gpa.free(work);
    try Io.Dir.cwd().createDirPath(io, work);
    defer Io.Dir.cwd().deleteTree(io, work) catch {};

    if (!std.fs.path.isAbsolute(work)) {
        std.debug.print("error: the temporary directory {s} is not absolute, so its ancestors cannot be checked for zttp.json\n", .{work});
        std.process.exit(1);
    }
    if (try findProjectConfigAbove(gpa, io, work)) |found| {
        defer gpa.free(found);
        std.debug.print(
            "error: {s} exists above the temporary directory {s}.\n" ++
                "`zts` discovers a project by walking every ancestor of the input path, so this file would change what the cases measure.\n" ++
                "Point TMPDIR at a directory with no zttp.json in any ancestor and run again.\n",
            .{ found, work },
        );
        std.process.exit(1);
    }

    try populate(gpa, io, work);

    var check = Check{ .gpa = gpa, .io = io, .zts = zts, .work = work };
    std.debug.print("cli abuse: {s}\n", .{zts});
    for (cases) |case| runCase(&check, case);

    const ran = check.passed + check.failed;
    std.debug.print("cli abuse: {d} of {d} cases passed\n", .{ check.passed, ran });
    // Floor on the check's own input: a harness that ran fewer cases than it
    // defines checked less than its name says.
    if (ran != cases.len) {
        std.debug.print("error: ran {d} cases, but this check defines {d}\n", .{ ran, cases.len });
        std.process.exit(1);
    }
    if (check.failed > 0) std.process.exit(1);
}

fn usage() void {
    std.debug.print("usage: cli-abuse-check <zts>\n", .{});
    std.process.exit(2);
}

/// Returns the path of the first `zttp.json` found in `start` or any ancestor.
fn findProjectConfigAbove(gpa: std.mem.Allocator, io: Io, start: []const u8) !?[]u8 {
    var current: []const u8 = start;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ current, "zttp.json" });
        errdefer gpa.free(candidate);
        if (Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return candidate;
        } else |err| switch (err) {
            error.FileNotFound => gpa.free(candidate),
            else => return err,
        }
        current = std.fs.path.dirname(current) orelse return null;
    }
}

/// Create every hostile input the cases name. `missing_path` is deliberately
/// not created.
fn populate(gpa: std.mem.Allocator, io: Io, work: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try writeInput(gpa, io, work, "empty.ts", "");
    const dir_path = try std.fs.path.join(gpa, &.{ work, "dir.ts" });
    defer gpa.free(dir_path);
    try cwd.createDirPath(io, dir_path);
    // Invalid UTF-8: a lone 0xFF, an overlong lead byte, and a truncated sequence.
    try writeInput(gpa, io, work, "bad-utf8.ts", "\xff\xfe\xc3\x28 const x = 1;\n");
    try writeInput(gpa, io, work, "nul.ts", "const x = 1;\x00const y = 2;\n");

    const big = try gpa.alloc(u8, over_cap_bytes);
    defer gpa.free(big);
    @memset(big, 'a');
    try writeInput(gpa, io, work, "over-cap.ts", big);

    var nest: std.ArrayList(u8) = .empty;
    defer nest.deinit(gpa);
    try nest.appendSlice(gpa, "const x = ");
    try nest.appendNTimes(gpa, '(', nest_depth);
    try nest.append(gpa, '1');
    try nest.appendNTimes(gpa, ')', nest_depth);
    try nest.appendSlice(gpa, ";\n");
    try writeInput(gpa, io, work, "nest.ts", nest.items);
}

fn writeInput(gpa: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn fileFor(input: Input) []const u8 {
    return switch (input) {
        .empty_file => "empty.ts",
        .missing_path => "does-not-exist.ts",
        .directory => "dir.ts",
        .over_cap => "over-cap.ts",
        .invalid_utf8 => "bad-utf8.ts",
        .nul_byte => "nul.ts",
        .deep_nesting => "nest.ts",
        // A valid, empty file: the flag is the hostile part.
        .unknown_flag => "empty.ts",
    };
}

fn runCase(check: *Check, case: Case) void {
    var argv: [5][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = check.zts;
    argc += 1;
    argv[argc] = "check";
    argc += 1;
    argv[argc] = fileFor(case.input);
    argc += 1;
    if (case.mode == .json) {
        argv[argc] = "--json";
        argc += 1;
    }
    if (case.input == .unknown_flag) {
        argv[argc] = "--no-such-flag";
        argc += 1;
    }

    const result = std.process.run(check.gpa, check.io, .{
        .argv = argv[0..argc],
        .cwd = .{ .path = check.work },
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(deadline_seconds), .clock = .awake } },
    }) catch |err| {
        check.fail(case.name, "the process did not finish within {d}s or could not run: {s}", .{ deadline_seconds, @errorName(err) });
        return;
    };
    defer check.gpa.free(result.stdout);
    defer check.gpa.free(result.stderr);

    const code = switch (result.term) {
        .exited => |code| code,
        else => {
            check.fail(case.name, "the process did not exit normally: {any}\nstderr:\n{s}", .{ result.term, result.stderr });
            return;
        },
    };
    if (code != case.exit_code) {
        check.fail(case.name, "exit code {d}, expected {d}\nstderr:\n{s}", .{ code, case.exit_code, result.stderr });
        return;
    }

    if (case.input == .unknown_flag) {
        if (result.stdout.len != 0) {
            check.fail(case.name, "an unknown flag wrote {d} byte(s) to stdout, expected none", .{result.stdout.len});
            return;
        }
        check.pass(case.name);
        return;
    }

    if (case.mode == .json) {
        if (result.stdout.len == 0) {
            check.pass(case.name);
            return;
        }
        if (!jsonMatches(check, case, result.stdout)) return;
    }
    check.pass(case.name);
}

/// True when `stdout` is exactly one complete JSON document that matches the
/// case. Records the failure itself otherwise.
fn jsonMatches(check: *Check, case: Case, stdout: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, check.gpa, stdout, .{}) catch |err| {
        check.fail(case.name, "stdout is not one complete JSON document ({s}), {d} byte(s)", .{ @errorName(err), stdout.len });
        return false;
    };
    defer parsed.deinit();
    const problem = describeMismatch(parsed.value, case) orelse return true;
    check.fail(case.name, "{s}", .{problem});
    return false;
}

/// Returns a description of how `value` differs from what the case expects,
/// or null when it matches.
fn describeMismatch(value: std.json.Value, case: Case) ?[]const u8 {
    const root = switch (value) {
        .object => |object| object,
        else => return "the JSON document is not an object",
    };
    const success = switch (root.get("success") orelse return "the JSON object has no `success` field") {
        .bool => |flag| flag,
        else => return "`success` is not a boolean",
    };
    if (success != case.success) return "`success` has the wrong value";
    const expected_code = case.diagnostic_code orelse return null;
    const diagnostics = switch (root.get("diagnostics") orelse return "the JSON object has no `diagnostics` field") {
        .array => |array| array,
        else => return "`diagnostics` is not an array",
    };
    if (diagnostics.items.len == 0) return "`diagnostics` is empty";
    const first = switch (diagnostics.items[0]) {
        .object => |object| object,
        else => return "the first diagnostic is not an object",
    };
    const code = switch (first.get("code") orelse return "the first diagnostic has no `code`") {
        .string => |text| text,
        else => return "the first diagnostic `code` is not a string",
    };
    if (!std.mem.eql(u8, code, expected_code)) return "the first diagnostic carries a different code than expected";
    return null;
}
