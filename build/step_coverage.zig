//! How the live build graph reaches every build task: the aggregate, the shared
//! sequential verification routes, the release-only routes, or none (manual).
//! The graph supplies task identity; verification_routes supplies executable
//! external argv. Comments, labels and command fragments grant no coverage.
//! `check-spine` holds each task's declared route and manual reason in agents.json
//! against this classification, so that file is the one owner of "this step is
//! manual, and why".
const std = @import("std");
const routes = @import("../tooling/verification_routes.zig");

/// Register before the task census snapshots the complete graph.
pub fn register(b: *std.Build) *std.Build.Step {
    return b.step("test-step-coverage", "Check every build step's work is run by something");
}

const StepSet = std.AutoHashMap(*std.Build.Step, void);

/// How the live graph reaches a build step. Each value is one answer to "what runs
/// the work this step does?", tried in this order.
pub const Reach = enum {
    /// Every dependency step is reached by `zig build test`.
    aggregate,
    /// Reached by the sequential verification routes, but not by the aggregate.
    verify,
    /// Reached only by the release-only routes.
    release,
    /// Reached by none of them: a human asks for it.
    manual,
};

pub const Classified = struct {
    name: []const u8,
    reach: Reach,
    /// Dependency steps that nothing in the covered graph runs, and the closure size.
    unrun: usize,
    own: usize,
};

/// The one walk of the build graph. The coverage check and the task census that
/// `check-spine` reads both take their facts from it. Call it after every top-level
/// step exists.
pub fn classify(b: *std.Build, test_step: *std.Build.Step) []const Classified {
    routes.validate(&routes.routes) catch @panic("invalid executable verification routes");
    var aggregate_covered = StepSet.init(b.allocator);
    var base_covered = StepSet.init(b.allocator);
    var covered = StepSet.init(b.allocator);
    collectReachable(test_step, &aggregate_covered);
    collectReachable(test_step, &base_covered);
    collectReachable(test_step, &covered);
    for (routes.routes) |route| {
        const name = routes.buildTask(route.argv) orelse continue;
        const tls = b.top_level_steps.get(name) orelse @panic("verification route names no live build task");
        if (!route.release_only and !route.release_pipeline) collectReachable(&tls.step, &base_covered);
        collectReachable(&tls.step, &covered);
    }
    if (covered.count() < 50) {
        @panic("step coverage: the covered closure is implausibly small; the graph walk is broken");
    }

    var classified: std.ArrayList(Classified) = .empty;
    for (b.top_level_steps.values()) |tls| {
        var own = StepSet.init(b.allocator);
        collectReachable(&tls.step, &own);
        // A step that only wraps a shell gate is run when something runs that
        // script, whichever Run step instance does it.
        const unrun = unrunCount(&own, &covered, .all);
        const reach: Reach = if (unrunCount(&own, &aggregate_covered, .none) == 0)
            .aggregate
        else if (unrunCount(&own, &base_covered, .base) == 0)
            .verify
        else if (unrun == 0)
            .release
        else
            .manual;
        classified.append(b.allocator, .{ .name = tls.step.name, .reach = reach, .unrun = unrun, .own = own.count() }) catch @panic("OOM");
    }
    return classified.items;
}

pub fn add(b: *std.Build, test_step: *std.Build.Step, step_coverage_step: *std.Build.Step, classified: []const Classified) void {
    var counts = std.EnumArray(Reach, usize).initFill(0);
    for (classified) |step| counts.set(step.reach, counts.get(step.reach) + 1);
    // A walk that finds no aggregate step or too few steps is a broken census, and a census
    // that reads nothing would let every step pass as covered.
    if (classified.len < 50 or counts.get(.aggregate) == 0) {
        @panic("step coverage: the task classification is implausibly small; the graph walk is broken");
    }
    const ok = b.addSystemCommand(&.{ "/bin/echo", b.fmt("step coverage: OK ({d} steps: {d} aggregate, {d} verify, {d} release-only, {d} manual; check-spine holds each route)", .{ classified.len, counts.get(.aggregate), counts.get(.verify), counts.get(.release), counts.get(.manual) }) });
    ok.has_side_effects = true;
    step_coverage_step.dependOn(&ok.step);
    test_step.dependOn(step_coverage_step);
}

/// Which verification-route scripts count as running a step's wrapped script.
const ScriptRoutes = enum { none, base, all };

/// Count the steps in `own` that nothing in `covered` runs and whose wrapped
/// script, if any, is not run by a counted route.
fn unrunCount(own: *StepSet, covered: *StepSet, scripts: ScriptRoutes) usize {
    var unrun: usize = 0;
    var it = own.keyIterator();
    while (it.next()) |entry| {
        const dep = entry.*;
        if (dep.tag == .top_level) continue;
        if (covered.contains(dep)) continue;
        if (scripts != .none) {
            if (runStepScript(dep)) |script| {
                var executed = false;
                for (routes.routes) |route| {
                    if ((route.release_only or route.release_pipeline) and scripts == .base) continue;
                    const path = routes.script(route.argv) orelse continue;
                    if (std.mem.eql(u8, path, script)) executed = true;
                }
                if (executed) continue;
            }
        }
        unrun += 1;
    }
    return unrun;
}

/// Collect every step reachable from `root`, including `root` itself.
fn collectReachable(
    root: *std.Build.Step,
    seen: *StepSet,
) void {
    if (seen.contains(root)) return;
    seen.put(root, {}) catch @panic("OOM");
    for (root.dependencies.items) |dep| collectReachable(dep, seen);
}

/// A `scripts/....sh` path named in a Run step's literal argv, if any.
///
/// Several build steps only wrap a shell gate, and `scripts/verify.sh` runs
/// some of those scripts directly rather than through `zig build <step>`. The
/// work is done either way, so the coverage question is about the script, not
/// about which Run step instance executed it.
pub fn runStepScript(step: *std.Build.Step) ?[]const u8 {
    const run = step.cast(std.Build.Step.Run) orelse return null;
    var argv: [2][]const u8 = undefined;
    var count: usize = 0;
    for (run.argv.items[0..@min(2, run.argv.items.len)]) |arg| {
        argv[count] = switch (arg) {
            .bytes => |text| text,
            else => return null,
        };
        count += 1;
    }
    return routes.script(argv[0..count]);
}

/// A script route is an executable argv in the covered graph or the driver.
/// The shell wrapper receives this census; source comments are never scanned.
pub fn attachScriptCensus(b: *std.Build, test_step: *std.Build.Step, run: *std.Build.Step.Run, repo_gate: *std.Build.Step.Compile) void {
    var covered = StepSet.init(b.allocator);
    collectReachable(test_step, &covered);
    for (routes.routes) |route| {
        if (routes.buildTask(route.argv)) |name| collectReachable(&b.top_level_steps.get(name).?.step, &covered);
    }
    var paths = std.StringHashMap(void).init(b.allocator);
    var it = covered.keyIterator();
    while (it.next()) |entry| {
        if (runStepScript(entry.*)) |path| paths.put(path, {}) catch @panic("OOM");
    }
    for (routes.routes) |route| {
        if (routes.script(route.argv)) |path| paths.put(path, {}) catch @panic("OOM");
    }
    var census: std.ArrayList(u8) = .empty;
    var names = paths.keyIterator();
    while (names.next()) |path| {
        census.appendSlice(b.allocator, path.*) catch @panic("OOM");
        census.append(b.allocator, 0) catch @panic("OOM");
    }
    const generated = b.addWriteFiles();
    run.addArtifactArg(repo_gate);
    run.addFileArg(generated.add("script-execution-routes.txt", census.items));
}
