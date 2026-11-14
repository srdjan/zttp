//! The project test suite, run against a candidate change set before the
//! approval prompt. The result goes to the developer on the result card. It
//! never reaches the model and never refuses a change set.

const std = @import("std");
const zts = @import("zts");
const project_config = @import("project_config");
const change_set = @import("change_set.zig");
const workspace_snapshot = @import("workspace_snapshot.zig");
const tools_common = @import("tools/common.zig");

/// Longest test name or error line kept from the `zttp test` output.
const max_kept_line_bytes: usize = 160;

pub const TestRun = union(enum) {
    /// No suite in the project, or the host did not enable the run.
    none,
    /// `zttp test` ran the suite. `results` is the text after `Results: `.
    ran: Ran,
    /// `zttp test` could not run the suite. The payload is its first error line.
    not_runnable: []const u8,

    pub const Ran = struct {
        results: []const u8,
        failing: []const []const u8,
    };
};

/// Run `<binary> test <suite>` against the candidate overlay. A null `binary`
/// or a project without the default suite gives `.none`. The result strings
/// live in `arena`.
pub fn run(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    binary: ?[]const u8,
    snapshot: *const workspace_snapshot.Snapshot,
    prepared: *const change_set.PreparedChangeSet,
) !TestRun {
    const zttp_binary = binary orelse return .none;
    const suite_path = try std.fs.path.resolve(allocator, &.{ snapshot.project_root, project_config.default_test_suite });
    defer allocator.free(suite_path);
    if (!zts.file_io.fileExists(allocator, suite_path)) return .none;

    var overlay = snapshot.materializeCandidate(allocator, prepared) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .not_runnable = "the candidate workspace could not be created" },
    };
    defer overlay.deinit();

    var outcome = tools_common.runCommand(
        allocator,
        overlay.root,
        &.{ zttp_binary, "test", suite_path },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .not_runnable = "zttp test did not start" },
    };
    defer outcome.deinit(allocator);
    if (outcome.exit_code == null) return .{ .not_runnable = "zttp test ended without an exit code" };

    // `zttp test` prints to stderr; stdout is read only when stderr is empty.
    const text = if (outcome.stderr.len > 0) outcome.stderr else outcome.stdout;
    return parseOutput(arena, text);
}

/// Map `zttp test` output to a run. A `Results:` line means the suite ran.
/// Without one, the first nonempty line is the reason it could not.
pub fn parseOutput(arena: std.mem.Allocator, text: []const u8) !TestRun {
    var results: ?[]const u8 = null;
    var first_line: ?[]const u8 = null;
    var failing: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (first_line == null) first_line = line;
        if (std.mem.startsWith(u8, line, "Results: ")) {
            results = line["Results: ".len..];
        } else if (std.mem.startsWith(u8, line, "  FAIL  ")) {
            try failing.append(arena, try arena.dupe(u8, clip(line["  FAIL  ".len..])));
        }
    }
    const ran_results = results orelse {
        const reason = first_line orelse "zttp test printed nothing";
        return .{ .not_runnable = try arena.dupe(u8, clip(std.mem.trim(u8, reason, " \t"))) };
    };
    return .{ .ran = .{
        .results = try arena.dupe(u8, clip(ran_results)),
        .failing = failing.items,
    } };
}

fn clip(line: []const u8) []const u8 {
    return line[0..@min(line.len, max_kept_line_bytes)];
}

const testing = std.testing;

test "parseOutput: a Results line and FAIL rows make a ran result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text =
        "\nTesting src/handler.ts (3 tests)\n\n" ++
        "  PASS  first\n" ++
        "  FAIL  second\n" ++
        "        body does not contain: old\n" ++
        "  UNCHECKED  third\n" ++
        "  FAIL  fourth\n" ++
        "\nResults: 1 passed, 2 failed, 1 unchecked, 4 total\n";
    const parsed = try parseOutput(arena_state.allocator(), text);
    try testing.expectEqualStrings("1 passed, 2 failed, 1 unchecked, 4 total", parsed.ran.results);
    try testing.expectEqual(@as(usize, 2), parsed.ran.failing.len);
    try testing.expectEqualStrings("second", parsed.ran.failing[0]);
    try testing.expectEqualStrings("fourth", parsed.ran.failing[1]);
}

test "parseOutput: output without a Results line gives the first line as the reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseOutput(
        arena_state.allocator(),
        "zttp test cannot run with multiple outboundHosts; current runtime accepts one.\nerror: x\n",
    );
    try testing.expectEqualStrings(
        "zttp test cannot run with multiple outboundHosts; current runtime accepts one.",
        parsed.not_runnable,
    );
}

test "parseOutput: empty output is not runnable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseOutput(arena_state.allocator(), "\n\n");
    try testing.expectEqualStrings("zttp test printed nothing", parsed.not_runnable);
}
