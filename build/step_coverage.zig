//! Step coverage: every top-level step's work must be run by something.
//!
//! This walks the real dependency graph, not the source. A named step is not
//! what `test` depends on - `test_step.dependOn(&run_server_tests.step)`
//! names the Run step, and `b.step("test-server", ...)` names a separate
//! top-level step over the same Run - so "is test-server reachable from
//! test" is the wrong question. The right one is whether each top-level
//! step's dependency closure is covered, and only the graph can answer it.
//!
//! A step counts as run when `zig build test` reaches it, when
//! scripts/verify.sh or a CI workflow invokes the step that reaches it, or
//! when one of those runs the same shell gate the step wraps - five steps
//! are covered only by that last route. Anything left must carry a row in
//! scripts/manual-steps.allow saying why a human asks for it.
//!
//! scripts/test-examples.sh is why this exists: it was documented as
//! outside `zig build test` and run only from verify.sh, and 56 example
//! suites went unrun while `zig build test` reported a pass.
//!
//! It must run last, after every top-level step exists.

const std = @import("std");

pub fn add(b: *std.Build, test_step: *std.Build.Step) void {
    const coverage_sources = blk: {
        var acc: std.ArrayList(u8) = .empty;
        acc.appendSlice(b.allocator, @embedFile("../scripts/verify.sh")) catch @panic("OOM");
        // Read the workflow directory rather than embedding a fixed list,
        // so a workflow added later is a coverage source without anyone
        // having to remember this gate.
        var wf = b.build_root.handle.openDir(b.graph.io, ".github/workflows", .{ .iterate = true }) catch
            @panic("step coverage: .github/workflows is missing; this gate would credit no CI invocation");
        defer wf.close(b.graph.io);
        var it = wf.iterate();
        var workflows: usize = 0;
        while (it.next(b.graph.io) catch @panic("step coverage: cannot iterate .github/workflows")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;
            const text = wf.readFileAlloc(b.graph.io, entry.name, b.allocator, .unlimited) catch
                @panic("step coverage: cannot read a workflow file");
            acc.appendSlice(b.allocator, text) catch @panic("OOM");
            acc.append(b.allocator, '\n') catch @panic("OOM");
            workflows += 1;
        }
        // Floor on this gate's own input. With no coverage text every step
        // reads as manual and the allowlist would have to name all of them;
        // with a truncated read, steps quietly become "uncovered".
        if (workflows == 0) @panic("step coverage: no CI workflow files read; the coverage input is empty");
        break :blk acc.items;
    };
    if (std.mem.indexOf(u8, coverage_sources, "zig build ") == null) {
        @panic("step coverage: the coverage text names no `zig build` invocation; the scan is broken");
    }

    var covered = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    var name_buf: [128]u8 = undefined;
    collectReachable(test_step, &covered);
    for (b.top_level_steps.values()) |tls| {
        if (verifyInvokes(coverage_sources, tls.step.name, &name_buf)) {
            collectReachable(&tls.step, &covered);
        }
    }
    if (covered.count() < 50) {
        @panic("step coverage: the covered closure is implausibly small; the graph walk is broken");
    }

    const manual_src = @embedFile("../scripts/manual-steps.allow");
    var report: std.ArrayList(u8) = .empty;
    var violations: usize = 0;
    var manual_rows: usize = 0;
    var step_count: usize = 0;

    for (b.top_level_steps.values()) |tls| {
        step_count += 1;
        const declared_manual = allowNames(manual_src, tls.step.name);
        var own = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
        collectReachable(&tls.step, &own);
        var unrun: usize = 0;
        var it = own.keyIterator();
        while (it.next()) |entry| {
            const dep = entry.*;
            if (dep.id == .top_level) continue;
            if (covered.contains(dep)) continue;
            // A step that only wraps a shell gate is run when something
            // runs that script, whichever Run step instance does it.
            if (runStepScript(dep)) |script| {
                if (std.mem.indexOf(u8, coverage_sources, script) != null) continue;
            }
            unrun += 1;
        }
        if (unrun > 0 and !declared_manual) {
            report.print(b.allocator, "  {s}: {d} of {d} dependency steps are run by nothing\n", .{ tls.step.name, unrun, own.count() }) catch @panic("OOM");
            violations += 1;
        }
        if (unrun == 0 and declared_manual) {
            report.print(b.allocator, "  {s}: listed in scripts/manual-steps.allow, but something runs it now - delete the row\n", .{tls.step.name}) catch @panic("OOM");
            violations += 1;
        }
    }

    // A row naming a step that no longer exists is a claim about nothing.
    var lines = std.mem.splitScalar(u8, manual_src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        manual_rows += 1;
        if (b.top_level_steps.get(name) == null) {
            report.print(b.allocator, "  {s}: listed in scripts/manual-steps.allow, but no such build step exists\n", .{name}) catch @panic("OOM");
            violations += 1;
        }
    }
    if (manual_rows == 0) {
        @panic("step coverage: scripts/manual-steps.allow parsed zero rows; the allowlist read is broken");
    }

    const step_coverage_step = b.step("test-step-coverage", "Check every build step's work is run by something");
    if (violations > 0) {
        const message = std.fmt.allocPrint(b.allocator, "step coverage: {d} problem(s)\n{s}\nRun the step from scripts/verify.sh, a CI workflow, or `zig build test`; or add a row to scripts/manual-steps.allow with the reason a human asks for it.", .{ violations, report.items }) catch @panic("OOM");
        step_coverage_step.dependOn(&b.addFail(message).step);
    } else {
        const ok = b.addSystemCommand(&.{ "/bin/echo", b.fmt("step coverage: OK ({d} steps, {d} run by hand with a stated reason)", .{ step_count, manual_rows }) });
        ok.has_side_effects = true;
        step_coverage_step.dependOn(&ok.step);
    }
    test_step.dependOn(step_coverage_step);
}

/// Collect every step reachable from `root`, including `root` itself.
fn collectReachable(
    root: *std.Build.Step,
    seen: *std.AutoHashMap(*std.Build.Step, void),
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
fn runStepScript(step: *std.Build.Step) ?[]const u8 {
    const run = step.cast(std.Build.Step.Run) orelse return null;
    for (run.argv.items) |arg| {
        switch (arg) {
            .bytes => |text| {
                if (std.mem.startsWith(u8, text, "scripts/") and
                    std.mem.endsWith(u8, text, ".sh")) return text;
            },
            else => {},
        }
    }
    return null;
}

/// True when `verify.sh` runs `zig build <name>`.
fn verifyInvokes(verify_src: []const u8, name: []const u8, buf: []u8) bool {
    const needle = std.fmt.bufPrint(buf, "zig build {s}", .{name}) catch return false;
    var rest = verify_src;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        // The name must not be a prefix of a longer step name: `zig build test`
        // must not answer for `zig build test-zruntime`.
        const after = rest[idx + needle.len ..];
        const terminated = after.len == 0 or after[0] == ' ' or after[0] == '\n' or after[0] == '\r';
        if (terminated) return true;
        rest = after;
    }
    return false;
}

/// True when `allow_src` has a row whose first field is `name`.
fn allowNames(allow_src: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, allow_src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (std.mem.eql(u8, first, name)) return true;
    }
    return false;
}
