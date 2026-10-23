//! Executable verification routes shared by the driver and build-graph census.
//! Labels describe commands; only argv contributes execution coverage.
const std = @import("std");

pub const Route = struct {
    label: []const u8,
    argv: []const []const u8,
    release_only: bool = false,
    release_pipeline: bool = false,
};

pub const routes = [_]Route{
    .{ .label = "aggregate unit suite", .argv = &.{ "zig", "build", "test" } },
    .{ .label = "standalone runtime root", .argv = &.{ "zig", "build", "test-zruntime" } },
    .{ .label = "release binaries", .argv = &.{ "zig", "build", "-Doptimize=fast" } },
    .{ .label = "handler precompilation", .argv = &.{ "zig", "build", "-Dhandler=examples/handler/handler.ts", "-Dverify", "-Dcontract" } },
    .{ .label = "v1 user-flow smoke", .argv = &.{ "zig", "build", "smoke-v1" } },
    .{ .label = "handler panic isolation", .argv = &.{ "zig", "build", "test-panic-isolation" } },
    .{ .label = "normalization idempotence", .argv = &.{ "bash", "scripts/check-normalize-idempotent.sh" } },
    .{ .label = "installer archive safety", .argv = &.{ "bash", "scripts/test-install-archive-safety.sh" } },
    .{ .label = "strict semantics specification", .argv = &.{ "bash", "scripts/check-semantics-spec.sh" } },
    .{ .label = "module binding specifications", .argv = &.{ "./zig-out/bin/zts", "module-spec-render", "--check" } },
    .{ .label = "curated release notes", .argv = &.{ "sh", "scripts/test-release-notes.sh" }, .release_only = true },
    .{ .label = "release evidence provenance", .argv = &.{ "zig", "build", "release-provenance" }, .release_only = true },
    // Release-only checks previously called directly by release.sh. Keeping
    // them here makes their executable route and classification one fact.
    .{ .label = "getting started smoke", .argv = &.{ "zig", "build", "smoke-getting-started" }, .release_only = true, .release_pipeline = true },
    .{ .label = "release passport", .argv = &.{ "zig", "build", "release-check", "--", "--json" }, .release_only = true, .release_pipeline = true },
    .{ .label = "advisory benchmark", .argv = &.{ "zig", "build", "bench-check" }, .release_only = true, .release_pipeline = true },
    .{ .label = "formatting", .argv = &.{ "zig", "fmt", "--check", "build.zig", "zts_main.zig", "scripts/kernel_safety_gate.zig", "scripts/residual_guard_extract.zig", "build/", "packages/", "tooling/" } },
};

pub fn validate(items: []const Route) !void {
    var aggregate: usize = 0;
    var runtime: usize = 0;
    for (items) |route| {
        const ordinary = !route.release_only and !route.release_pipeline;
        if (route.argv.len == 0) return error.EmptyCommand;
        const task = buildTask(route.argv) orelse continue;
        if (ordinary and std.mem.eql(u8, task, "test")) aggregate += 1;
        if (ordinary and std.mem.eql(u8, task, "test-zruntime")) runtime += 1;
    }
    if (aggregate != 1 or runtime != 1) return error.InvalidVerificationFloor;
}

pub fn buildTask(argv: []const []const u8) ?[]const u8 {
    if (argv.len < 2 or !std.mem.eql(u8, argv[0], "zig") or !std.mem.eql(u8, argv[1], "build")) return null;
    if (argv.len == 2 or std.mem.startsWith(u8, argv[2], "-")) return "install";
    return argv[2];
}

pub fn script(argv: []const []const u8) ?[]const u8 {
    // The executable is argv[0], or argv[1] for a shell command. Arguments
    // containing a path are not evidence that the script is executed.
    if (argv.len == 0) return null;
    const index: usize = if (std.mem.eql(u8, argv[0], "bash") or std.mem.eql(u8, argv[0], "sh") or
        std.mem.eql(u8, argv[0], "/bin/bash") or std.mem.eql(u8, argv[0], "/bin/sh")) 1 else 0;
    if (argv.len <= index) return null;
    const path = argv[index];
    return if (std.mem.startsWith(u8, path, "scripts/") and std.mem.endsWith(u8, path, ".sh")) path else null;
}

test "coverage requires argv while labels and comments have no authority" {
    const removed: Route = .{ .label = "zig build test-zruntime # scripts/orphan.sh", .argv = &.{} };
    try std.testing.expectEqual(@as(?[]const u8, null), buildTask(removed.argv));
    try std.testing.expectEqual(@as(?[]const u8, null), script(removed.argv));
    try std.testing.expectEqualStrings("test-zruntime", buildTask(&.{ "zig", "build", "test-zruntime" }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), script(&.{ "echo", "scripts/orphan.sh" }));
    try std.testing.expectEqualStrings("scripts/gate.sh", script(&.{ "bash", "scripts/gate.sh" }).?);
}

test "deleting runtime execution while retaining its label rejects the live route table" {
    try validate(&routes);
    var removed = routes;
    removed[1].label = "zig build test-zruntime # standalone runtime root";
    removed[1].argv = &.{};
    try std.testing.expectError(error.EmptyCommand, validate(&removed));
    removed[1].argv = &.{ "echo", "zig build test-zruntime" };
    try std.testing.expectError(error.InvalidVerificationFloor, validate(&removed));
}

test "mandatory routes cannot be moved out of ordinary verification" {
    try validate(&routes);
    var rejected: usize = 0;
    for (routes, 0..) |route, index| {
        const task = buildTask(route.argv);
        const mandatory = (task != null and
            (std.mem.eql(u8, task.?, "test") or std.mem.eql(u8, task.?, "test-zruntime")));
        if (!mandatory) continue;
        var changed = routes;
        changed[index].release_only = true;
        try std.testing.expectError(error.InvalidVerificationFloor, validate(&changed));
        rejected += 1;
        changed[index].release_only = false;
        changed[index].release_pipeline = true;
        try std.testing.expectError(error.InvalidVerificationFloor, validate(&changed));
        rejected += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), rejected);
}

test "build selection rejects empty named suites and filtered aggregate execution" {
    const cases = [_]struct { task: []const u8, filter: []const u8, diagnostic: ?[]const u8 }{
        .{ .task = "test-zts", .filter = "Interpreter basic arithmetic", .diagnostic = null },
        .{ .task = "test-zts", .filter = "__h3_nonexistent_test__", .diagnostic = "test filter selected zero tests" },
        .{ .task = "test", .filter = "__h3_nonexistent_test__", .diagnostic = "test rejects -Dtest-filter" },
    };
    var verdicts: usize = 0;
    const zig = std.testing.environ.getPosix("ZTTP_ZIG_EXE") orelse return error.MissingProbeCompiler;
    for (cases) |case| {
        const filter = try std.testing.allocator.print("-Dtest-filter={s}", .{case.filter});
        defer std.testing.allocator.free(filter);
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{ zig, "build", case.task, filter, "-j2" },
            .stderr_limit = .limited(1024 * 1024),
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        if (case.diagnostic) |diagnostic| {
            try std.testing.expect(result.term == .exited and result.term.exited != 0);
            try std.testing.expect(std.mem.find(u8, result.stderr, diagnostic) != null);
        } else {
            if (result.term != .exited or result.term.exited != 0) std.debug.print("selection probe: {s}\n", .{result.stderr});
            try std.testing.expect(result.term == .exited and result.term.exited == 0);
        }
        verdicts += 1;
    }
    try std.testing.expectEqual(cases.len, verdicts);
}
