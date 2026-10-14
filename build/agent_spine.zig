//! Repository spine commands. The completed graph supplies the task census.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    check_run: *std.Build.Step.Run,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const mod = b.createModule(.{
        .root_source_file = b.path("tooling/agent_spine.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
    });
    const exe = b.addExecutable(.{ .name = "agent-spine", .root_module = mod });
    const check_run = b.addRunArtifact(exe);
    check_run.addArg("check");
    check_run.has_side_effects = true;
    if (b.args) |args| check_run.addArgs(args);
    const check_step = b.step("check-spine", "Check repository authorities, decisions, and task policy");
    check_step.dependOn(&check_run.step);

    const brief_run = b.addRunArtifact(exe);
    brief_run.addArg("brief");
    brief_run.has_side_effects = true;
    if (b.args) |args| brief_run.addArgs(args);
    b.step("brief", "Show the rules and gates that govern repository files").dependOn(&brief_run.step);

    // This root stays unfiltered: an unmatched filter would run no probes.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test-spine", "Run native spine behavior and rejection probes");
    test_step.dependOn(&run_tests.step);
    return .{ .check_run = check_run, .check_step = check_step, .test_step = test_step };
}

/// Call after every top-level step exists, before the coverage walk.
pub fn attachTaskCensus(b: *std.Build, check_run: *std.Build.Step.Run) void {
    const names = b.allocator.alloc([]const u8, b.top_level_steps.count()) catch @panic("OOM");
    for (b.top_level_steps.values(), 0..) |step, i| names[i] = step.step.name;
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var census: std.ArrayList(u8) = .empty;
    for (names) |name| {
        census.appendSlice(b.allocator, name) catch @panic("OOM");
        census.append(b.allocator, '\n') catch @panic("OOM");
    }
    const generated = b.addWriteFiles();
    const path = generated.add("agent-spine-tasks.txt", census.items);
    check_run.addArg("--tasks");
    check_run.addFileArg(path);
}
