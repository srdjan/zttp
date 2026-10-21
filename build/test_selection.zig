//! A developer filter must select tests in the named suite's whole closure.
const std = @import("std");

pub const Run = struct { step: *std.Build.Step, count_path: []const u8 };

const Guard = struct {
    step: std.Build.Step,
    counts: []const []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *Guard = @fieldParentPtr("step", step);
        var selected: usize = 0;
        for (self.counts) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(step.owner.graph.io, path, step.owner.allocator, .limited(64));
            selected += try std.fmt.parseInt(usize, bytes, 10);
        }
        if (selected == 0) return step.fail("test filter selected zero tests in this named suite", .{});
    }
};

/// `require_runs` is set for a developer filter, where a step that reaches no
/// counted run selected nothing and must fail. Without a developer filter only
/// steps that reach a fixed-filter run are guarded, and the rest stay untouched.
pub fn attach(b: *std.Build, runs: []const Run, require_runs: bool) void {
    for (b.top_level_steps.values()) |tls| {
        const aggregate = !require_runs and std.mem.eql(u8, tls.step.name, "test");
        if (!aggregate and !std.mem.startsWith(u8, tls.step.name, "test-") and !std.mem.eql(u8, tls.step.name, "check-spine")) continue;
        var paths: std.ArrayList([]const u8) = .empty;
        for (runs) |run| if (reachable(&tls.step, run.step)) {
            paths.append(b.allocator, run.count_path) catch @panic("OOM");
        };
        if (!require_runs and paths.items.len == 0) continue;
        const guard = b.allocator.create(Guard) catch @panic("OOM");
        guard.* = .{
            .step = .init(.{ .id = .custom, .name = b.fmt("nonempty selection for {s}", .{tls.step.name}), .owner = b, .makeFn = Guard.make }),
            .counts = paths.items,
        };
        // Run every original dependency first. The count is evidence from this
        // invocation, not a source-name heuristic or a stale cached test run.
        for (tls.step.dependencies.items) |dep| guard.step.dependOn(dep);
        tls.step.dependencies.clearRetainingCapacity();
        tls.step.dependOn(&guard.step);
    }
}

fn reachable(root: *std.Build.Step, target: *std.Build.Step) bool {
    if (root == target) return true;
    for (root.dependencies.items) |dep| if (reachable(dep, target)) return true;
    return false;
}
