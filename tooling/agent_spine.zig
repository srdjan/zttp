//! Native repository agent-spine checker and navigation command.
//!
//! The build graph passes a task census to `check`. This command never starts
//! a nested Zig build. Repository-specific values stay in `agents.json`.

const std = @import("std");

const area_marker = "<!-- agent-spine: area -->";
const area_open = "<!-- generated: areas -->";
const area_close = "<!-- end generated: areas -->";
const gate_open = "<!-- generated: gates -->";
const gate_close = "<!-- end generated: gates -->";
const max_file_bytes = 16 * 1024 * 1024;
const max_area_lines = 80;

pub const ExitCode = enum(u8) {
    clean = 0,
    rule_failure = 1,
    usage_failure = 2,
};

pub const CheckOptions = struct {
    root: []const u8 = ".",
    tasks_file: []const u8,
    write: bool = false,
};

pub const BriefOptions = struct {
    root: []const u8 = ".",
    paths: []const []const u8 = &.{},
};

pub const Command = union(enum) {
    check: CheckOptions,
    brief: BriefOptions,
};

pub const FailureKind = enum {
    completion_floor,
    task_classification,
    command_policy,
    area_contract,
    decision_ledger,
    decision_liveness,
    solution_binding,
    line_anchor,
    symbol_anchor,
    docs_policy,
    generated_markers,
    generated_drift,
};

const Intent = enum { verify, build, run, measure, operate };
const Effect = enum { none, @"local-write", @"remote-read", @"remote-write" };
const Approval = enum { none, @"explicit-user" };
const DocsPolicy = enum { off, strict };
const WorkspaceKind = enum { @"zig-build", json, pattern };

const Workspace = struct {
    manifest: []const u8,
    cwd: []const u8,
    kind: WorkspaceKind,
};

const Docs = struct {
    decisions: []const u8,
    solutions: []const u8,
    concepts: ?[]const u8 = null,
    canonicalGate: ?[]const u8 = null,
};

const SpineCommand = struct {
    task: []const u8,
    cwd: ?[]const u8 = null,
    intent: Intent,
    effect: Effect,
    approval: Approval,
    does: []const u8,
    requiredWhen: ?[]const u8 = null,
    always: ?bool = null,
    seconds: ?f64 = null,
    outputBytes: ?usize = null,
};

const Spine = struct {
    runner: []const u8,
    root: []const u8 = "AGENTS.md",
    areaFile: []const u8 = "AGENTS.md",
    docsPolicy: DocsPolicy = .off,
    sourceExtensions: []const []const u8,
    workspaces: []const Workspace,
    authorities: []const []const u8,
    vendored: []const []const u8,
    skipDirs: []const []const u8,
    docs: Docs,
    commands: []const SpineCommand,
};

const Area = struct {
    dir: []const u8,
    file: []const u8,
    owns: []const u8,
    boundary: []const u8,
    invariants: []const []const u8,
    decisions: []const []const u8,
    tasks: []const []const u8,
};

const Decision = struct {
    id: []const u8,
    title: []const u8,
    status: []const u8,
    decided: []const u8,
    binds: []const []const u8,
    gate: []const u8,
    reason: []const u8,
    supersedes: ?[]const u8,
    superseded_by: ?[]const u8,
};

const Solution = struct {
    file: []const u8,
    binds: []const []const u8,
    proves: []const u8,
};

const Failure = struct {
    kind: FailureKind,
    message: []const u8,
};

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_dir: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    spine: Spine,
    tracked: []const []const u8,
    tasks: []const []const u8,
    areas: []const Area,
    decisions: []const Decision,
    solutions: []const Solution,

    fn deinit(self: *Context) void {
        self.root_dir.close(self.io);
        self.arena.deinit();
    }

    fn a(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const argv = try collectArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, argv);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);

    const command = parseCommand(argv[1..]) catch {
        try stderr.interface.writeAll(
            "usage: agent-spine check --tasks FILE [--root REPO] [--write]\n" ++
                "       agent-spine brief [--root REPO] [path ...]\n",
        );
        try stderr.interface.flush();
        std.process.exit(@intFromEnum(ExitCode.usage_failure));
    };
    const code = execute(allocator, init.io, command, &stdout.interface, &stderr.interface) catch |err| blk: {
        try stderr.interface.print("spine: configuration or I/O failure: {s}\n", .{@errorName(err)});
        break :blk ExitCode.usage_failure;
    };
    try stdout.interface.flush();
    try stderr.interface.flush();
    if (code != .clean) std.process.exit(@intFromEnum(code));
}

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: Command,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    return switch (command) {
        .check => |options| executeCheck(allocator, io, options, stdout, stderr),
        .brief => |options| executeBrief(allocator, io, options, stdout, stderr),
    };
}

fn executeCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CheckOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    var ctx = loadContext(allocator, io, options.root, options.tasks_file, stderr) catch |err| switch (err) {
        error.GitCensusFailed => {
            try stderr.writeAll("spine: git ls-files failed; restore the repository census and rerun the check\n");
            return .rule_failure;
        },
        error.DiagnosticReported => return .usage_failure,
        else => return err,
    };
    defer ctx.deinit();

    var failures: std.ArrayList(Failure) = .empty;
    defer failures.deinit(allocator);
    try checkAll(&ctx, options.write, &failures);
    if (failures.items.len != 0) {
        for (failures.items) |failure| {
            try stderr.print("spine[{s}]: {s}\n", .{ @tagName(failure.kind), failure.message });
        }
        return .rule_failure;
    }
    try stdout.writeAll("agent spine checks passed\n");
    return .clean;
}

fn executeBrief(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: BriefOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExitCode {
    var ctx = loadContext(allocator, io, options.root, null, stderr) catch |err| {
        if (err == error.GitCensusFailed) {
            try stderr.writeAll("brief: git ls-files failed; restore the repository census and rerun brief\n");
            return .rule_failure;
        }
        if (err == error.DiagnosticReported) return .usage_failure;
        try stderr.print("brief: cannot load the spine: {s}\n", .{@errorName(err)});
        return .usage_failure;
    };
    defer ctx.deinit();
    if (ctx.areas.len == 0) {
        try stderr.print("brief: no marked area contracts found; add {s} to a nested {s}\n", .{ area_marker, ctx.spine.areaFile });
        return .rule_failure;
    }
    if (ctx.decisions.len == 0) {
        try stderr.print("brief: {s} holds no decisions\n", .{ctx.spine.docs.decisions});
        return .rule_failure;
    }

    if (options.paths.len == 0) {
        try writeOrientation(&ctx, stdout);
    } else {
        for (options.paths, 0..) |path, index| {
            if (index != 0) try stdout.writeAll("\n------------------------------------------------------------------------------\n\n");
            try writePathBrief(&ctx, path, stdout);
        }
    }
    return .clean;
}

fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var iterator = std.process.Args.Iterator.init(args_vector);
    defer iterator.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }
    while (iterator.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
    return list.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn parseCommand(argv: []const []const u8) !Command {
    if (argv.len == 0) return error.InvalidArgument;
    if (std.mem.eql(u8, argv[0], "check")) {
        var root: []const u8 = ".";
        var tasks: ?[]const u8 = null;
        var write = false;
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--root")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArgument;
                root = argv[i];
            } else if (std.mem.eql(u8, argv[i], "--tasks")) {
                i += 1;
                if (i >= argv.len) return error.InvalidArgument;
                tasks = argv[i];
            } else if (std.mem.eql(u8, argv[i], "--write")) {
                write = true;
            } else return error.InvalidArgument;
        }
        return .{ .check = .{ .root = root, .tasks_file = tasks orelse return error.InvalidArgument, .write = write } };
    }
    if (std.mem.eql(u8, argv[0], "brief")) {
        var root: []const u8 = ".";
        var first_path: usize = argv.len;
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--root")) {
                if (first_path != argv.len) return error.InvalidArgument;
                i += 1;
                if (i >= argv.len) return error.InvalidArgument;
                root = argv[i];
            } else {
                first_path = i;
                break;
            }
        }
        return .{ .brief = .{ .root = root, .paths = argv[first_path..] } };
    }
    return error.InvalidArgument;
}

fn loadContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    tasks_file: ?[]const u8,
    diagnostics: *std.Io.Writer,
) !Context {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        try reportLoadFailure(diagnostics, "repository root", root_path, err, "correct --root");
        return error.DiagnosticReported;
    };
    errdefer root_dir.close(io);

    const manifest_bytes = readFile(root_dir, io, a, "agents.json") catch |err| {
        try reportLoadFailure(diagnostics, "manifest", "agents.json", err, "create or correct agents.json");
        return error.DiagnosticReported;
    };
    const spine = std.json.parseFromSliceLeaky(Spine, a, manifest_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        try reportLoadFailure(diagnostics, "manifest", "agents.json", err, "fix its required fields and enum values");
        return error.DiagnosticReported;
    };

    const tracked = try trackedPaths(a, io, root_path, root_dir);
    const tasks = if (tasks_file) |path| readTasks(root_dir, io, a, path) catch |err| {
        try reportLoadFailure(diagnostics, "task census", path, err, "pass the readable graph file through --tasks");
        return error.DiagnosticReported;
    } else &.{};
    const areas = try loadAreas(root_dir, io, a, spine, tracked, diagnostics);
    const decision_source = readFile(root_dir, io, a, spine.docs.decisions) catch |err| {
        try reportLoadFailure(diagnostics, "decision ledger", spine.docs.decisions, err, "restore the configured ledger path");
        return error.DiagnosticReported;
    };
    const decisions = try parseDecisions(a, decision_source);
    const solutions = try loadSolutions(root_dir, io, a, spine, tracked, diagnostics);
    return .{
        .allocator = allocator,
        .io = io,
        .root_path = root_path,
        .root_dir = root_dir,
        .arena = arena,
        .spine = spine,
        .tracked = tracked,
        .tasks = tasks,
        .areas = areas,
        .decisions = decisions,
        .solutions = solutions,
    };
}

fn reportLoadFailure(
    writer: *std.Io.Writer,
    subject: []const u8,
    path: []const u8,
    err: anyerror,
    remedy: []const u8,
) !void {
    try writer.print("spine: cannot read {s} {s}: {s}; {s}\n", .{ subject, path, @errorName(err), remedy });
}

fn readFile(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return dir.readFileAllocOptions(io, path, allocator, .limited(max_file_bytes), .of(u8), 0);
}

fn pathExists(dir: std.Io.Dir, io: std.Io, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn trackedPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    root_dir: std.Io.Dir,
) ![]const []const u8 {
    const identity = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root_path, "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.GitCensusFailed;
    defer allocator.free(identity.stdout);
    defer allocator.free(identity.stderr);
    const identity_ok = switch (identity.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!identity_ok) return error.GitCensusFailed;
    const reported_root = std.mem.trim(u8, identity.stdout, " \t\r\n");
    const actual_root = try std.Io.Dir.realPathFileAlloc(root_dir, io, ".", allocator);
    defer allocator.free(actual_root);
    const canonical_reported = std.Io.Dir.realPathFileAbsoluteAlloc(io, reported_root, allocator) catch return error.GitCensusFailed;
    defer allocator.free(canonical_reported);
    if (!std.mem.eql(u8, actual_root, canonical_reported)) return error.GitCensusFailed;

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", root_path, "ls-files", "-z" },
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.GitCensusFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return error.GitCensusFailed;

    var paths: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, result.stdout, 0);
    while (iterator.next()) |raw| {
        // Git's NUL-delimited paths are exact names, including whitespace.
        const path = raw;
        if (path.len == 0) continue;
        if (try pathExists(root_dir, io, path)) try paths.append(allocator, try allocator.dupe(u8, path));
    }
    return paths.toOwnedSlice(allocator);
}

fn readTasks(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const source = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(max_file_bytes), .of(u8), 0)
    else
        try readFile(dir, io, allocator, path);
    var tasks: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const task = std.mem.trim(u8, line, " \t\r");
        if (task.len != 0) try tasks.append(allocator, task);
    }
    return tasks.toOwnedSlice(allocator);
}

fn loadAreas(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    spine: Spine,
    tracked: []const []const u8,
    diagnostics: *std.Io.Writer,
) ![]const Area {
    var areas: std.ArrayList(Area) = .empty;
    for (tracked) |path| {
        if (!std.mem.eql(u8, std.fs.path.basename(path), spine.areaFile)) continue;
        if (std.mem.eql(u8, path, spine.root)) continue;
        if (isSkipped(spine, path)) continue;
        const source = readFile(dir, io, allocator, path) catch |err| {
            try reportLoadFailure(diagnostics, "area contract", path, err, "restore readable marked area content");
            return error.DiagnosticReported;
        };
        if (std.mem.indexOf(u8, source, area_marker) == null) continue;
        try areas.append(allocator, try parseArea(allocator, path, source, spine.runner));
    }
    std.mem.sort(Area, areas.items, {}, struct {
        fn lessThan(_: void, left: Area, right: Area) bool {
            return std.mem.lessThan(u8, left.dir, right.dir);
        }
    }.lessThan);
    return areas.toOwnedSlice(allocator);
}

fn parseArea(allocator: std.mem.Allocator, file: []const u8, source: []const u8, runner: []const u8) !Area {
    const dir = std.fs.path.dirname(file) orelse "";
    const title_start = findAreaTitle(source) orelse source.len;
    const title_end = std.mem.indexOfScalarPos(u8, source, title_start, '\n') orelse source.len;
    const after_title = source[@min(title_end + 1, source.len)..];
    var paragraphs: std.ArrayList([]const u8) = .empty;
    var blocks = std.mem.splitSequence(u8, after_title, "\n\n");
    while (blocks.next()) |raw| {
        const paragraph = std.mem.trim(u8, raw, " \t\r\n");
        if (paragraph.len == 0 or std.mem.eql(u8, paragraph, area_marker)) continue;
        if (std.mem.startsWith(u8, paragraph, "## ")) break;
        try paragraphs.append(allocator, try collapseSpace(allocator, paragraph));
        if (paragraphs.items.len == 2) break;
    }

    const invariant_body = section(source, "Invariants");
    var invariants: std.ArrayList([]const u8) = .empty;
    var invariant_tasks: std.ArrayList([]const u8) = .empty;
    var line_it = std.mem.splitScalar(u8, invariant_body, '\n');
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "- ")) {
            if (current.items.len != 0) try finishInvariant(allocator, current.items, runner, &invariants, &invariant_tasks);
            current.clearRetainingCapacity();
            try current.appendSlice(allocator, line[2..]);
        } else if (current.items.len != 0 and std.mem.trim(u8, line, " \t\r").len != 0) {
            try current.append(allocator, ' ');
            try current.appendSlice(allocator, std.mem.trim(u8, line, " \t\r"));
        } else if (current.items.len != 0) {
            try finishInvariant(allocator, current.items, runner, &invariants, &invariant_tasks);
            current.clearRetainingCapacity();
        }
    }
    if (current.items.len != 0) try finishInvariant(allocator, current.items, runner, &invariants, &invariant_tasks);

    var decisions: std.ArrayList([]const u8) = .empty;
    try collectDecisionIds(allocator, section(source, "Decisions that bind here"), &decisions);
    var tasks: std.ArrayList([]const u8) = .empty;
    try collectTaskMentions(allocator, source, runner, &tasks);

    return .{
        .dir = dir,
        .file = file,
        .owns = if (paragraphs.items.len > 0) paragraphs.items[0] else "",
        .boundary = if (paragraphs.items.len > 1) paragraphs.items[1] else "",
        .invariants = try invariants.toOwnedSlice(allocator),
        .decisions = try decisions.toOwnedSlice(allocator),
        .tasks = try tasks.toOwnedSlice(allocator),
    };
}

fn findAreaTitle(source: []const u8) ?usize {
    if (std.mem.startsWith(u8, source, "# ")) return 0;
    if (std.mem.indexOf(u8, source, "\n# ")) |index| return index + 1;
    return null;
}

fn finishInvariant(
    allocator: std.mem.Allocator,
    raw: []const u8,
    runner: []const u8,
    invariants: *std.ArrayList([]const u8),
    tasks: *std.ArrayList([]const u8),
) !void {
    const text = try allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    try invariants.append(allocator, text);
    try collectTaskMentions(allocator, text, runner, tasks);
}

fn section(source: []const u8, heading: []const u8) []const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "## ")) |start| {
        const name_start = start + 3;
        const line_end = std.mem.indexOfScalarPos(u8, source, name_start, '\n') orelse source.len;
        if (std.mem.eql(u8, std.mem.trim(u8, source[name_start..line_end], " \t\r"), heading)) {
            const body_start = @min(line_end + 1, source.len);
            const body = source[body_start..];
            const end = std.mem.indexOf(u8, body, "\n## ") orelse body.len;
            return body[0..end];
        }
        cursor = line_end;
    }
    return "";
}

fn collectDecisionIds(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i + 5 <= source.len) : (i += 1) {
        if (source[i] != 'D' or source[i + 1] != '-') continue;
        const id = source[i .. i + 5];
        if (std.ascii.isDigit(id[2]) and std.ascii.isDigit(id[3]) and std.ascii.isDigit(id[4])) {
            if (!containsString(out.items, id)) try out.append(allocator, id);
            i += 4;
        }
    }
}

fn collectTaskMentions(
    allocator: std.mem.Allocator,
    source: []const u8,
    runner: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var rest = source;
    while (std.mem.indexOf(u8, rest, runner)) |index| {
        var start = index + runner.len;
        while (start < rest.len and rest[start] == ' ') start += 1;
        var end = start;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == ':' or rest[end] == '_' or rest[end] == '-')) end += 1;
        if (end > start and !containsString(out.items, rest[start..end])) try out.append(allocator, rest[start..end]);
        rest = rest[end..];
    }
}

fn parseDecisions(allocator: std.mem.Allocator, source: []const u8) ![]const Decision {
    var result: std.ArrayList(Decision) = .empty;
    var cursor: usize = 0;
    while (findDecisionHeading(source, cursor)) |heading| {
        const next: Heading = findDecisionHeading(source, heading.body_start) orelse .{ .start = source.len, .body_start = source.len, .id = "", .title = "" };
        const entry = try foldDecisionMetadata(allocator, source[heading.body_start..next.start]);
        const binds_text = metadata(entry, "Binds") orelse "";
        var binds: std.ArrayList([]const u8) = .empty;
        var bind_it = std.mem.splitScalar(u8, binds_text, ',');
        while (bind_it.next()) |raw| {
            const value = std.mem.trim(u8, raw, " \t\r\n");
            if (value.len != 0) try binds.append(allocator, value);
        }
        try result.append(allocator, .{
            .id = heading.id,
            .title = heading.title,
            .status = metadata(entry, "Status") orelse "",
            .decided = metadata(entry, "Decided") orelse "",
            .binds = try binds.toOwnedSlice(allocator),
            .gate = metadata(entry, "Gate") orelse "",
            .reason = decisionReason(entry),
            .supersedes = metadata(entry, "Supersedes"),
            .superseded_by = metadata(entry, "Superseded-by"),
        });
        cursor = next.start;
        if (cursor >= source.len) break;
    }
    return result.toOwnedSlice(allocator);
}

fn foldDecisionMetadata(allocator: std.mem.Allocator, entry: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, entry, '\n');
    var metadata_open = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const metadata_line = std.mem.startsWith(u8, line, "- ") and std.mem.indexOfScalar(u8, line, ':') != null;
        const continuation = metadata_open and line.len != 0 and (line[0] == ' ' or line[0] == '\t') and
            !std.mem.startsWith(u8, trimmed, "- ") and !std.mem.startsWith(u8, trimmed, "* ") and !std.mem.startsWith(u8, trimmed, "+ ");
        if (continuation) {
            try output.append(allocator, ' ');
            try output.appendSlice(allocator, trimmed);
            continue;
        }
        if (output.items.len != 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, line);
        metadata_open = metadata_line;
    }
    return output.toOwnedSlice(allocator);
}

const Heading = struct { start: usize, body_start: usize, id: []const u8, title: []const u8 };

fn findDecisionHeading(source: []const u8, from: usize) ?Heading {
    var rest = source[from..];
    while (std.mem.indexOf(u8, rest, "### D-")) |relative| {
        const start = from + (source[from..].len - rest.len) + relative;
        const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start + 4 .. line_end];
        if (line.len >= 6 and line[0] == 'D' and line[1] == '-' and
            std.ascii.isDigit(line[2]) and std.ascii.isDigit(line[3]) and std.ascii.isDigit(line[4]) and line[5] == ' ')
        {
            return .{ .start = start, .body_start = @min(line_end + 1, source.len), .id = line[0..5], .title = std.mem.trim(u8, line[6..], " \t\r") };
        }
        rest = source[@min(line_end + 1, source.len)..];
    }
    return null;
}

fn metadata(entry: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, entry, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "- ")) continue;
        const body = line[2..];
        if (body.len <= key.len or !std.mem.eql(u8, body[0..key.len], key) or body[key.len] != ':') continue;
        return std.mem.trim(u8, body[key.len + 1 ..], " \t\r");
    }
    return null;
}

fn decisionReason(entry: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, entry, '\n');
    var saw_metadata = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (!saw_metadata) continue;
            while (lines.next()) |candidate| {
                const prose = std.mem.trim(u8, candidate, " \t\r");
                if (prose.len == 0) continue;
                if (std.mem.startsWith(u8, prose, "- ") or std.mem.startsWith(u8, prose, "#")) return "";
                return prose;
            }
            return "";
        }
        if (std.mem.startsWith(u8, trimmed, "- ") and std.mem.indexOfScalar(u8, trimmed, ':') != null) {
            saw_metadata = true;
            continue;
        }
        if (saw_metadata) return "";
    }
    return "";
}

fn loadSolutions(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    spine: Spine,
    tracked: []const []const u8,
    diagnostics: *std.Io.Writer,
) ![]const Solution {
    var solutions: std.ArrayList(Solution) = .empty;
    const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{normalizePath(spine.docs.solutions)});
    for (tracked) |path| {
        if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, ".md")) continue;
        const source = readFile(dir, io, allocator, path) catch |err| {
            try reportLoadFailure(diagnostics, "solution note", path, err, "restore readable tracked solution content");
            return error.DiagnosticReported;
        };
        try solutions.append(allocator, try parseSolution(allocator, path, source));
    }
    return solutions.toOwnedSlice(allocator);
}

fn parseSolution(allocator: std.mem.Allocator, file: []const u8, source: []const u8) !Solution {
    if (!std.mem.startsWith(u8, source, "---\n")) return .{ .file = file, .binds = &.{}, .proves = "" };
    const end = std.mem.indexOfPos(u8, source, 4, "\n---") orelse return .{ .file = file, .binds = &.{}, .proves = "" };
    const frontmatter = source[4..end];
    var binds: std.ArrayList([]const u8) = .empty;
    var proves: []const u8 = "";
    var in_binds = false;
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "binds:")) {
            in_binds = true;
        } else if (in_binds and std.mem.startsWith(u8, trimmed, "- ")) {
            try binds.append(allocator, trimQuotes(std.mem.trim(u8, trimmed[2..], " \t")));
        } else {
            in_binds = false;
            if (std.mem.startsWith(u8, trimmed, "proves:")) proves = trimQuotes(std.mem.trim(u8, trimmed[7..], " \t"));
        }
    }
    return .{ .file = file, .binds = try binds.toOwnedSlice(allocator), .proves = proves };
}

fn checkAll(ctx: *Context, write: bool, failures: *std.ArrayList(Failure)) !void {
    try checkFloors(ctx, failures);
    if (failures.items.len != 0) return;
    try checkTasks(ctx, failures);
    try checkCommands(ctx, failures);
    try checkAreas(ctx, failures);
    try checkLedger(ctx, failures);
    try checkSolutions(ctx, failures);
    try checkAnchors(ctx, failures);
    try checkDocsPolicy(ctx, failures);
    try checkGenerated(ctx, write, failures);
}

fn addFailure(ctx: *Context, failures: *std.ArrayList(Failure), kind: FailureKind, comptime format: []const u8, args: anytype) !void {
    try failures.append(ctx.allocator, .{ .kind = kind, .message = try std.fmt.allocPrint(ctx.a(), format, args) });
}

fn checkFloors(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    if (!std.mem.eql(u8, ctx.spine.runner, "zig build")) try addFailure(ctx, failures, .completion_floor, "agents.json runner {s} is unsupported by the native task census; use zig build", .{ctx.spine.runner});
    if (ctx.spine.workspaces.len == 0) try addFailure(ctx, failures, .completion_floor, "agents.json declares no workspaces; add one manifest-backed workspace", .{});
    for (ctx.spine.workspaces) |workspace| {
        if (!try pathExists(ctx.root_dir, ctx.io, workspace.manifest)) try addFailure(ctx, failures, .completion_floor, "agents.json workspace manifest {s} does not exist; correct the path", .{workspace.manifest});
        if (workspace.kind != .@"zig-build") try addFailure(ctx, failures, .completion_floor, "agents.json workspace {s} uses a non-native kind; set kind to zig-build", .{workspace.manifest});
        if (workspace.cwd.len != 0) try addFailure(ctx, failures, .completion_floor, "agents.json workspace {s} uses cwd {s}; the native graph census supports only the repository root", .{ workspace.manifest, workspace.cwd });
    }
    if (ctx.areas.len == 0) try addFailure(ctx, failures, .completion_floor, "no marked area contracts found; add {s} to one nested {s}", .{ area_marker, ctx.spine.areaFile });
    if (ctx.tasks.len == 0) try addFailure(ctx, failures, .completion_floor, "the task census is empty; pass the completed build graph through --tasks", .{});
    var verify_count: usize = 0;
    for (ctx.spine.commands) |command| if (command.intent == .verify) {
        verify_count += 1;
    };
    if (verify_count == 0) try addFailure(ctx, failures, .completion_floor, "agents.json declares no verify command; classify at least one task with intent verify", .{});
    if (ctx.decisions.len == 0) try addFailure(ctx, failures, .completion_floor, "{s} holds no parsed decisions; add one D-NNN entry", .{ctx.spine.docs.decisions});
    if (ctx.tracked.len == 0) try addFailure(ctx, failures, .completion_floor, "git ls-files found no existing tracked paths; restore the census before checking the spine", .{});
}

fn commandName(allocator: std.mem.Allocator, command: SpineCommand) ![]const u8 {
    _ = allocator;
    return command.task;
}

fn checkTasks(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    for (ctx.tasks, 0..) |task, index| {
        for (ctx.tasks[0..index]) |earlier| if (std.mem.eql(u8, task, earlier)) {
            try addFailure(ctx, failures, .task_classification, "task census repeats {s}; emit each build task once", .{task});
            break;
        };
        var matches: usize = 0;
        for (ctx.spine.commands) |command| {
            const name = try commandName(ctx.a(), command);
            if (std.mem.eql(u8, name, task)) matches += 1;
        }
        if (matches == 0) try addFailure(ctx, failures, .task_classification, "agents.json does not classify task {s}; add one commands row", .{task});
        if (matches > 1) try addFailure(ctx, failures, .task_classification, "agents.json classifies task {s} {d} times; keep one commands row", .{ task, matches });
    }
    for (ctx.spine.commands) |command| {
        const name = try commandName(ctx.a(), command);
        if (!containsString(ctx.tasks, name)) try addFailure(ctx, failures, .task_classification, "agents.json classifies stale task {s}; remove it or restore the build task", .{name});
    }
}

fn checkCommands(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    for (ctx.spine.commands) |command| {
        if (command.cwd) |cwd| if (cwd.len != 0) try addFailure(ctx, failures, .command_policy, "agents.json command {s} uses cwd {s}; classify only root build tasks from the passed graph", .{ command.task, cwd });
        if (command.effect == .@"remote-write" and command.approval != .@"explicit-user") {
            try addFailure(ctx, failures, .command_policy, "agents.json lets {s} mutate a remote store without explicit-user approval; change approval", .{command.task});
        }
    }
}

fn checkAreas(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    for (ctx.areas) |area| {
        const source = try readFile(ctx.root_dir, ctx.io, ctx.a(), area.file);
        const lines = std.mem.count(u8, source, "\n") + 1;
        if (lines > max_area_lines) try addFailure(ctx, failures, .area_contract, "{s} has {d} lines, over the {d}-line cap; move detail to a solution note", .{ area.file, lines, max_area_lines });
        if (area.owns.len == 0) try addFailure(ctx, failures, .area_contract, "{s} has no opening ownership paragraph; state what the area owns", .{area.file});
        if (area.boundary.len == 0) try addFailure(ctx, failures, .area_contract, "{s} has no second boundary paragraph; state what may cross the boundary", .{area.file});
        if (area.boundary.len != 0 and std.mem.indexOf(u8, area.boundary, ctx.spine.runner) == null and
            std.ascii.indexOfIgnoreCase(area.boundary, "no import boundary") == null and std.mem.indexOf(u8, area.boundary, "D-") == null)
        {
            try addFailure(ctx, failures, .area_contract, "{s}'s boundary names no enforcing task, no decision, and no explicit absence; state which condition applies", .{area.file});
        }
        if (std.mem.indexOf(u8, source, "## Decisions that bind here") == null) try addFailure(ctx, failures, .area_contract, "{s} has no Decisions that bind here section; add the binding decision ids", .{area.file});
        if (area.invariants.len == 0) try addFailure(ctx, failures, .area_contract, "{s} has no invariant; add one bold invariant with its proving gate", .{area.file});
        for (area.invariants) |invariant| {
            if (!std.mem.startsWith(u8, invariant, "**") or std.mem.indexOfPos(u8, invariant, 2, "**") == null) try addFailure(ctx, failures, .area_contract, "{s} has an invariant without a bold lead sentence; wrap the lead in **", .{area.file});
            var invariant_tasks: std.ArrayList([]const u8) = .empty;
            defer invariant_tasks.deinit(ctx.allocator);
            try collectTaskMentions(ctx.allocator, invariant, ctx.spine.runner, &invariant_tasks);
            if (invariant_tasks.items.len == 0) {
                try addFailure(ctx, failures, .area_contract, "{s} has an invariant without a {s} gate; name the proving task", .{ area.file, ctx.spine.runner });
            } else {
                for (invariant_tasks.items) |task| if (!containsString(ctx.tasks, task)) try addFailure(ctx, failures, .area_contract, "{s} has an invariant that names missing task {s} {s}; correct the proving gate", .{ area.file, ctx.spine.runner, task });
            }
        }
        for (area.tasks) |task| if (!containsString(ctx.tasks, task)) try addFailure(ctx, failures, .area_contract, "{s} names missing task {s} {s}; correct the invariant gate", .{ area.file, ctx.spine.runner, task });
        for (area.decisions) |id| if (findDecision(ctx.decisions, id) == null) try addFailure(ctx, failures, .area_contract, "{s} cites {s}, which is absent from {s}; add or correct the ledger entry", .{ area.file, id, ctx.spine.docs.decisions });
    }
}

fn checkLedger(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    var previous: usize = 0;
    for (ctx.decisions, 0..) |decision, index| {
        const number = std.fmt.parseInt(usize, decision.id[2..], 10) catch 0;
        if (number <= previous) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} is duplicated or out of order; keep unique ascending ids", .{ ctx.spine.docs.decisions, decision.id });
        previous = number;
        for (ctx.decisions[0..index]) |earlier| if (std.mem.eql(u8, earlier.id, decision.id)) try addFailure(ctx, failures, .decision_ledger, "{s}: duplicate decision id {s}; keep one historical entry", .{ ctx.spine.docs.decisions, decision.id });
        if (!std.mem.eql(u8, decision.status, "standing") and !std.mem.eql(u8, decision.status, "superseded")) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} has Status {s}; use standing or superseded", .{ ctx.spine.docs.decisions, decision.id, decision.status });
        if (!isIsoDate(decision.decided)) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} has no ISO Decided date; use YYYY-MM-DD", .{ ctx.spine.docs.decisions, decision.id });
        if (decision.binds.len == 0) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} binds nothing; add a path, directory, or glob", .{ ctx.spine.docs.decisions, decision.id });
        if (std.mem.eql(u8, decision.status, "standing") and decision.reason.len == 0) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} has no prose reason; add the specific reason", .{ ctx.spine.docs.decisions, decision.id });
        if (decision.gate.len == 0) {
            try addFailure(ctx, failures, .decision_ledger, "{s}: {s} has no Gate field; name a task or explicitly use none", .{ ctx.spine.docs.decisions, decision.id });
        } else if (!std.mem.eql(u8, decision.gate, "none")) {
            const prefix = try std.fmt.allocPrint(ctx.a(), "{s} ", .{ctx.spine.runner});
            if (!std.mem.startsWith(u8, decision.gate, prefix) or !containsString(ctx.tasks, decision.gate[prefix.len..])) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} names gate {s}, which is not a task; use {s} <task> or none", .{ ctx.spine.docs.decisions, decision.id, decision.gate, ctx.spine.runner });
        }
        if (std.mem.eql(u8, decision.status, "standing") and !decisionIsLive(ctx, decision)) {
            const bindings = try std.mem.join(ctx.a(), ", ", decision.binds);
            try addFailure(ctx, failures, .decision_liveness, "{s}: {s} is standing but Binds [{s}] match no existing tracked path and no area cites it; correct the bindings or supersede it", .{ ctx.spine.docs.decisions, decision.id, bindings });
        }
        if (std.mem.eql(u8, decision.status, "superseded") and decision.superseded_by == null) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} is superseded but names no Superseded-by entry; add the reciprocal link", .{ ctx.spine.docs.decisions, decision.id });
        if (decision.supersedes) |id| {
            const old = findDecision(ctx.decisions, id);
            if (old == null or !std.mem.eql(u8, old.?.status, "superseded") or old.?.superseded_by == null or !std.mem.eql(u8, old.?.superseded_by.?, decision.id)) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} Supersedes {s} without a superseded status and reciprocal Superseded-by link; update both entries", .{ ctx.spine.docs.decisions, decision.id, id });
        }
        if (decision.superseded_by) |id| {
            const replacement = findDecision(ctx.decisions, id);
            if (!std.mem.eql(u8, decision.status, "superseded") or replacement == null or replacement.?.supersedes == null or !std.mem.eql(u8, replacement.?.supersedes.?, decision.id)) try addFailure(ctx, failures, .decision_ledger, "{s}: {s} Superseded-by {s} lacks superseded status or a reciprocal Supersedes link; update both entries", .{ ctx.spine.docs.decisions, decision.id, id });
        }
    }
}

fn checkSolutions(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    for (ctx.solutions) |solution| {
        if (ctx.spine.docsPolicy == .strict and solution.binds.len == 0) try addFailure(ctx, failures, .solution_binding, "{s} has no binds list; add current paths or set docsPolicy off", .{solution.file});
        for (solution.binds) |binding| {
            const path = stripSymbol(binding);
            const exists = bindingHasWildcard(binding) or try pathExists(ctx.root_dir, ctx.io, path);
            if (!exists) {
                try addFailure(ctx, failures, .solution_binding, "{s} binds {s}, which does not exist; correct or remove the binding", .{ solution.file, binding });
                continue;
            }
            if (bindingHasWildcard(binding) and !bindingMatchesAny(ctx.tracked, &.{stripSymbol(binding)})) try addFailure(ctx, failures, .solution_binding, "{s} binds {s}, which matches no tracked path; correct the glob", .{ solution.file, binding });
            if (!bindingHasWildcard(binding)) {
                if (std.mem.indexOfScalar(u8, binding, '#')) |hash| {
                    const symbol = binding[hash + 1 ..];
                    const source = try readFile(ctx.root_dir, ctx.io, ctx.a(), path);
                    if (!try declaresSymbol(ctx.a(), path, source, symbol)) try addFailure(ctx, failures, .solution_binding, "{s} binds {s}, but {s} declares no {s}; use a current declaration", .{ solution.file, binding, path, symbol });
                }
            }
        }
        if (solution.proves.len != 0) {
            const prefix = try std.fmt.allocPrint(ctx.a(), "{s} ", .{ctx.spine.runner});
            if (!std.mem.startsWith(u8, solution.proves, prefix) or !containsString(ctx.tasks, solution.proves[prefix.len..])) try addFailure(ctx, failures, .solution_binding, "{s} proves {s}, which is not a task; name a current {s} task", .{ solution.file, solution.proves, ctx.spine.runner });
        }
    }
}

fn checkAnchors(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    for (ctx.tracked) |document| {
        if (!std.mem.endsWith(u8, document, ".md") or isVendored(ctx.spine, document)) continue;
        const source = try readFile(ctx.root_dir, ctx.io, ctx.a(), document);
        var i: usize = 0;
        while (i < source.len) {
            if (i + 2 < source.len and std.mem.eql(u8, source[i .. i + 3], "```")) {
                const end = std.mem.indexOfPos(u8, source, i + 3, "```") orelse break;
                i = end + 3;
                continue;
            }
            if (source[i] == '`') {
                const end = std.mem.indexOfScalarPos(u8, source, i + 1, '`') orelse break;
                try checkAnchorText(ctx, failures, document, source[i + 1 .. end]);
                i = end + 1;
                continue;
            }
            if (i + 1 < source.len and source[i] == ']' and source[i + 1] == '(') {
                const end = std.mem.indexOfScalarPos(u8, source, i + 2, ')') orelse break;
                try checkAnchorText(ctx, failures, document, source[i + 2 .. end]);
                i = end + 1;
                continue;
            }
            i += 1;
        }
    }
}

fn checkAnchorText(ctx: *Context, failures: *std.ArrayList(Failure), document: []const u8, raw: []const u8) !void {
    const text = std.mem.trim(u8, raw, " <>\t\r\n");
    if (std.mem.indexOf(u8, text, "://") != null) return;
    const parsed = parseSourceAnchor(ctx.spine, text) orelse return;
    switch (parsed.kind) {
        .line => try addFailure(ctx, failures, .line_anchor, "{s} anchors {s} by line; replace it with a file or #symbol reference", .{ document, text }),
        .symbol => {
            const target = try resolveAnchorPath(ctx, document, parsed.path);
            if (target == null) {
                try addFailure(ctx, failures, .symbol_anchor, "{s} anchors {s}, but the target does not exist; correct the relative path", .{ document, text });
                return;
            }
            const source = try readFile(ctx.root_dir, ctx.io, ctx.a(), target.?);
            if (!try declaresSymbol(ctx.a(), target.?, source, parsed.value)) try addFailure(ctx, failures, .symbol_anchor, "{s} anchors {s}, but {s} declares no {s}; use a current top-level declaration", .{ document, text, target.?, parsed.value });
        },
    }
}

const ParsedAnchor = struct { kind: enum { line, symbol }, path: []const u8, value: []const u8 };

fn parseSourceAnchor(spine: Spine, text: []const u8) ?ParsedAnchor {
    for (spine.sourceExtensions) |raw_extension| {
        const extension = std.mem.trimStart(u8, raw_extension, ".");
        var marker_buffer: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buffer, ".{s}", .{extension}) catch continue;
        const ext_at = std.mem.indexOf(u8, text, marker) orelse continue;
        const after = ext_at + marker.len;
        if (after >= text.len) continue;
        const path = text[0..after];
        if (std.mem.indexOfScalar(u8, path, ':') != null) continue;
        if (text[after] == '#') {
            const symbol = text[after + 1 ..];
            if (isIdentifier(symbol)) return .{ .kind = .symbol, .path = path, .value = symbol };
        }
        if (text[after] == ':') {
            const location = text[after + 1 ..];
            if (isLineLocation(location)) return .{ .kind = .line, .path = path, .value = location };
        }
    }
    return null;
}

fn resolveAnchorPath(ctx: *Context, document: []const u8, path: []const u8) !?[]const u8 {
    const doc_dir = std.fs.path.dirname(document) orelse "";
    if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or std.mem.indexOfScalar(u8, path, '/') == null) {
        const joined = try std.fs.path.join(ctx.a(), &.{ doc_dir, path });
        const relative = normalizePath(joined);
        if (try pathExists(ctx.root_dir, ctx.io, relative)) return relative;
    }
    const root_relative = normalizePath(path);
    if (try pathExists(ctx.root_dir, ctx.io, root_relative)) return root_relative;
    if (doc_dir.len != 0) {
        const joined = try std.fs.path.join(ctx.a(), &.{ doc_dir, path });
        if (try pathExists(ctx.root_dir, ctx.io, joined)) return joined;
    }
    return null;
}

fn declaresSymbol(allocator: std.mem.Allocator, path: []const u8, source: []const u8, symbol: []const u8) !bool {
    if (std.mem.endsWith(u8, path, ".zig")) return declaresZigSymbol(allocator, source, symbol);
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return declaresTypeScriptSymbol(source, symbol);
    return false;
}

fn declaresZigSymbol(allocator: std.mem.Allocator, source: []const u8, symbol: []const u8) !bool {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    for (tree.rootDecls()) |node| {
        var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_buffer, node)) |function| {
            if (function.name_token) |name_token| {
                if (std.mem.eql(u8, tree.tokenSlice(name_token), symbol)) return true;
            }
            continue;
        }
        if (tree.fullVarDecl(node)) |variable| {
            const name_token = variable.ast.mut_token + 1;
            if (tree.tokenTag(name_token) == .identifier and std.mem.eql(u8, tree.tokenSlice(name_token), symbol)) return true;
        }
    }
    return false;
}

fn declaresTypeScriptSymbol(source: []const u8, symbol: []const u8) bool {
    var depth: usize = 0;
    var state: enum { code, line_comment, block_comment, single, double, template, regex, regex_class } = .code;
    var expect_name = false;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (state) {
            .line_comment => {
                if (byte == '\n') state = .code;
                i += 1;
            },
            .block_comment => {
                if (byte == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    state = .code;
                    i += 2;
                } else i += 1;
            },
            .single => {
                if (byte == '\\') i += @min(@as(usize, 2), source.len - i) else {
                    if (byte == '\'') state = .code;
                    i += 1;
                }
            },
            .double => {
                if (byte == '\\') i += @min(@as(usize, 2), source.len - i) else {
                    if (byte == '"') state = .code;
                    i += 1;
                }
            },
            .template => {
                if (byte == '\\') i += @min(@as(usize, 2), source.len - i) else {
                    if (byte == '`') state = .code;
                    i += 1;
                }
            },
            .regex => {
                if (byte == '\\') {
                    i += @min(@as(usize, 2), source.len - i);
                } else {
                    if (byte == '[') state = .regex_class else if (byte == '/') state = .code;
                    i += 1;
                }
            },
            .regex_class => {
                if (byte == '\\') {
                    i += @min(@as(usize, 2), source.len - i);
                } else {
                    if (byte == ']') state = .regex;
                    i += 1;
                }
            },
            .code => {
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') {
                    state = .line_comment;
                    i += 2;
                    continue;
                }
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') {
                    state = .block_comment;
                    i += 2;
                    continue;
                }
                if (byte == '/' and startsRegexLiteral(source, i)) {
                    state = .regex;
                    i += 1;
                    continue;
                }
                if (byte == '\'') {
                    state = .single;
                    i += 1;
                    continue;
                }
                if (byte == '"') {
                    state = .double;
                    i += 1;
                    continue;
                }
                if (byte == '`') {
                    state = .template;
                    i += 1;
                    continue;
                }
                if (byte == '{') {
                    depth += 1;
                    i += 1;
                    continue;
                }
                if (byte == '}') {
                    depth -|= 1;
                    i += 1;
                    continue;
                }
                if (depth == 0 and (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$')) {
                    const start = i;
                    i += 1;
                    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '$')) i += 1;
                    const token = source[start..i];
                    if (expect_name) {
                        if (std.mem.eql(u8, token, symbol)) return true;
                        expect_name = false;
                    } else if (std.mem.eql(u8, token, "const") or std.mem.eql(u8, token, "let") or std.mem.eql(u8, token, "function") or std.mem.eql(u8, token, "class") or std.mem.eql(u8, token, "type") or std.mem.eql(u8, token, "interface") or std.mem.eql(u8, token, "enum")) {
                        expect_name = true;
                    }
                    continue;
                }
                i += 1;
            },
        }
    }
    return false;
}

fn startsRegexLiteral(source: []const u8, slash: usize) bool {
    var index = slash;
    while (index > 0) {
        index -= 1;
        if (std.ascii.isWhitespace(source[index])) continue;
        return std.mem.indexOfScalar(u8, "=(:,[!&|?{;", source[index]) != null;
    }
    return true;
}

fn checkDocsPolicy(ctx: *Context, failures: *std.ArrayList(Failure)) !void {
    if (ctx.spine.docsPolicy != .strict) return;
    for (ctx.tracked) |path| {
        if (!std.mem.endsWith(u8, path, ".md") or isVendored(ctx.spine, path)) continue;
        const solutions_prefix = try std.fmt.allocPrint(ctx.a(), "{s}/", .{normalizePath(ctx.spine.docs.solutions)});
        if (containsString(ctx.spine.authorities, path) or std.mem.eql(u8, path, ctx.spine.docs.decisions) or
            (ctx.spine.docs.concepts != null and std.mem.eql(u8, path, ctx.spine.docs.concepts.?)) or
            std.mem.startsWith(u8, path, solutions_prefix)) continue;
        var is_area = false;
        for (ctx.areas) |area| if (std.mem.eql(u8, area.file, path)) {
            is_area = true;
            break;
        };
        if (!is_area) try addFailure(ctx, failures, .docs_policy, "{s} is tracked but undeclared; add it as an authority, area, solution, or vendored path", .{path});
    }
}

fn checkGenerated(ctx: *Context, write: bool, failures: *std.ArrayList(Failure)) !void {
    const current = try readFile(ctx.root_dir, ctx.io, ctx.a(), ctx.spine.root);
    if (!validGeneratedMarkers(current)) {
        try addFailure(ctx, failures, .generated_markers, "{s} needs one ordered complete pair for each generated areas and gates block; repair the markers", .{ctx.spine.root});
        return;
    }
    const areas = try renderAreas(ctx);
    const gates = try renderGates(ctx);
    const with_areas = try replaceBlock(ctx.a(), current, area_open, area_close, areas);
    const regenerated = try replaceBlock(ctx.a(), with_areas, gate_open, gate_close, gates);
    const left = try normalizeGenerated(ctx.a(), current);
    const right = try normalizeGenerated(ctx.a(), regenerated);
    if (std.mem.eql(u8, left, right)) return;
    if (write and failures.items.len == 0) {
        var atomic = try ctx.root_dir.createFileAtomic(ctx.io, ctx.spine.root, .{ .replace = true });
        defer atomic.deinit(ctx.io);
        try atomic.file.writeStreamingAll(ctx.io, regenerated);
        try atomic.file.sync(ctx.io);
        try atomic.replace(ctx.io);
    } else try addFailure(ctx, failures, .generated_drift, "{s}'s generated blocks disagree with agents.json; run {s} check-spine -- --write after other failures are clean", .{ ctx.spine.root, ctx.spine.runner });
}

fn validMarkerPair(source: []const u8, open: []const u8, close: []const u8) bool {
    if (std.mem.count(u8, source, open) != 1 or std.mem.count(u8, source, close) != 1) return false;
    return std.mem.indexOf(u8, source, open).? < std.mem.indexOf(u8, source, close).?;
}

fn validGeneratedMarkers(source: []const u8) bool {
    if (!validMarkerPair(source, area_open, area_close) or !validMarkerPair(source, gate_open, gate_close)) return false;
    const areas_start = std.mem.indexOf(u8, source, area_open).?;
    const areas_end = std.mem.indexOf(u8, source, area_close).?;
    const gates_start = std.mem.indexOf(u8, source, gate_open).?;
    const gates_end = std.mem.indexOf(u8, source, gate_close).?;
    return areas_start < areas_end and areas_end < gates_start and gates_start < gates_end;
}

fn renderAreas(ctx: *Context) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(ctx.a());
    try output.writer.writeAll("| Area | Owns |\n| --- | --- |\n");
    for (ctx.areas) |area| try output.writer.print("| [`{s}/`]({s}) | {s} |\n", .{ area.dir, area.file, try summarise(ctx.a(), area.owns) });
    return output.toOwnedSlice();
}

fn renderGates(ctx: *Context) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(ctx.a());
    try output.writer.writeAll("| Gate | Proves | Required when | Measured |\n| --- | --- | --- | --- |\n");
    for (ctx.spine.commands) |command| {
        if (command.intent != .verify) continue;
        const name = try commandName(ctx.a(), command);
        if (command.seconds) |seconds| {
            try output.writer.print("| `{s} {s}` | {s} | {s} | {d:.1}s |\n", .{ ctx.spine.runner, name, command.does, command.requiredWhen orelse "-", seconds });
        } else {
            try output.writer.print("| `{s} {s}` | {s} | {s} | not measured |\n", .{ ctx.spine.runner, name, command.does, command.requiredWhen orelse "-" });
        }
    }
    return output.toOwnedSlice();
}

fn replaceBlock(allocator: std.mem.Allocator, source: []const u8, open: []const u8, close: []const u8, body: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, open).?;
    const end = std.mem.indexOfPos(u8, source, start + open.len, close).?;
    return std.fmt.allocPrint(allocator, "{s}{s}\n\n{s}\n{s}", .{ source[0..start], open, std.mem.trimEnd(u8, body, "\n"), source[end..] });
}

fn normalizeGenerated(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var in_space = false;
    var dash_run: usize = 0;
    for (source) |byte| {
        if (byte == ' ' or byte == '\t') {
            in_space = true;
            continue;
        }
        if (byte == '-') {
            dash_run += 1;
            continue;
        }
        if (dash_run != 0) {
            const count = if (dash_run >= 3) 3 else dash_run;
            try output.appendNTimes(allocator, '-', count);
            dash_run = 0;
        }
        if (byte == '\n') {
            while (output.items.len != 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
            try output.append(allocator, '\n');
            in_space = false;
            continue;
        }
        if (in_space and output.items.len != 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, ' ');
        in_space = false;
        try output.append(allocator, byte);
    }
    if (dash_run != 0) try output.appendNTimes(allocator, '-', if (dash_run >= 3) 3 else dash_run);
    return output.toOwnedSlice(allocator);
}

fn writeOrientation(ctx: *Context, writer: *std.Io.Writer) !void {
    try writer.print("ROOT AUTHORITY  {s}\n\nAREAS\n", .{ctx.spine.root});
    for (ctx.areas) |area| try writer.print("  {s}  {s}\n", .{ area.dir, try summarise(ctx.a(), area.owns) });
    try writer.writeAll("\nGATES\n");
    for (ctx.spine.commands) |command| if (command.intent == .verify) try writeGate(ctx, writer, command);
    var approval_header = false;
    for (ctx.spine.commands) |command| {
        if (command.approval != .@"explicit-user") continue;
        if (!approval_header) {
            try writer.writeAll("\nNEVER RUN WITHOUT THE OPERATOR ASKING\n");
            approval_header = true;
        }
        try writer.print("  {s} {s}  {s}\n", .{ ctx.spine.runner, try commandName(ctx.a(), command), command.does });
    }
    try writer.writeAll("\nAUTHORITIES\n");
    for (ctx.spine.authorities) |authority| try writer.print("  {s}\n", .{authority});
    try writer.print("  decisions  {s}\n  solutions  {s}\n", .{ ctx.spine.docs.decisions, ctx.spine.docs.solutions });
    if (ctx.spine.docs.concepts) |concepts| try writer.print("  concepts   {s}\n", .{concepts});
}

fn writePathBrief(ctx: *Context, path: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("{s}\n\nROOT AUTHORITY  {s}\n", .{ path, ctx.spine.root });
    const area = nearestArea(ctx.areas, path);
    if (area) |found| {
        try writer.print("\nAREA  {s} ({s})\n  {s}\n  {s}\n  Invariants:\n", .{ found.dir, found.file, found.owns, found.boundary });
        for (found.invariants) |invariant| try writer.print("    - {s}\n", .{boldLead(invariant)});
    } else try writer.writeAll("\nAREA  none; the root authority is the complete contract\n");

    try writer.writeAll("\nDECISIONS\n");
    var decision_count: usize = 0;
    for (ctx.decisions) |decision| {
        if (!std.mem.eql(u8, decision.status, "standing")) continue;
        const bound = bindingMatchesAny(&.{path}, decision.binds) or if (area) |found| containsString(found.decisions, decision.id) else false;
        if (!bound) continue;
        decision_count += 1;
        try writer.print("  {s}  {s} ({s})  {s}\n", .{ decision.id, ctx.spine.docs.decisions, decision.id, decision.title });
    }
    if (decision_count == 0) try writer.writeAll("  none\n");

    try writer.writeAll("\nNOTES\n");
    var note_count: usize = 0;
    for (ctx.solutions) |solution| {
        if (!bindingMatchesAny(&.{path}, solution.binds)) continue;
        note_count += 1;
        if (solution.proves.len == 0) {
            try writer.print("  {s}\n", .{solution.file});
        } else {
            try writer.print("  {s} ({s})\n", .{ solution.file, solution.proves });
        }
    }
    if (note_count == 0) try writer.writeAll("  none\n");

    var gate_names: std.ArrayList([]const u8) = .empty;
    defer gate_names.deinit(ctx.allocator);
    if (area) |found| for (found.tasks) |task| if (!containsString(gate_names.items, task)) try gate_names.append(ctx.allocator, task);
    for (ctx.decisions) |decision| {
        if (!std.mem.eql(u8, decision.status, "standing")) continue;
        if (!bindingMatchesAny(&.{path}, decision.binds) and !(if (area) |found| containsString(found.decisions, decision.id) else false)) continue;
        const prefix = try std.fmt.allocPrint(ctx.a(), "{s} ", .{ctx.spine.runner});
        if (std.mem.startsWith(u8, decision.gate, prefix) and !containsString(gate_names.items, decision.gate[prefix.len..])) try gate_names.append(ctx.allocator, decision.gate[prefix.len..]);
    }
    for (ctx.solutions) |solution| if (bindingMatchesAny(&.{path}, solution.binds)) {
        const prefix = try std.fmt.allocPrint(ctx.a(), "{s} ", .{ctx.spine.runner});
        if (std.mem.startsWith(u8, solution.proves, prefix) and !containsString(gate_names.items, solution.proves[prefix.len..])) try gate_names.append(ctx.allocator, solution.proves[prefix.len..]);
    };
    for (ctx.spine.commands) |command| if (command.always orelse false) {
        const name = try commandName(ctx.a(), command);
        if (!containsString(gate_names.items, name)) try gate_names.append(ctx.allocator, name);
    };
    try writer.writeAll("\nGATES\n");
    if (ctx.spine.docs.canonicalGate) |canonical| try writer.print("  canonical  {s}\n", .{canonical});
    for (gate_names.items) |name| {
        const command = findCommand(ctx.spine.commands, name);
        if (command) |found| try writeGate(ctx, writer, found) else try writer.print("  {s} {s}\n", .{ ctx.spine.runner, name });
    }
}

fn writeGate(ctx: *Context, writer: *std.Io.Writer, command: SpineCommand) !void {
    const name = try commandName(ctx.a(), command);
    try writer.print("  {s} {s}  {s}\n", .{ ctx.spine.runner, name, command.requiredWhen orelse command.does });
}

fn nearestArea(areas: []const Area, path: []const u8) ?Area {
    var result: ?Area = null;
    for (areas) |area| if (matchesBinding(path, area.dir) and (result == null or area.dir.len > result.?.dir.len)) {
        result = area;
    };
    return result;
}

fn findCommand(commands: []const SpineCommand, name: []const u8) ?SpineCommand {
    for (commands) |command| {
        if (command.cwd == null and std.mem.eql(u8, command.task, name)) return command;
    }
    return null;
}

fn findDecision(decisions: []const Decision, id: []const u8) ?Decision {
    for (decisions) |decision| if (std.mem.eql(u8, decision.id, id)) return decision;
    return null;
}

fn decisionIsLive(ctx: *Context, decision: Decision) bool {
    if (bindingMatchesAny(ctx.tracked, decision.binds)) return true;
    for (ctx.areas) |area| if (containsString(area.decisions, decision.id)) return true;
    return false;
}

fn matchesBinding(path_raw: []const u8, pattern_raw: []const u8) bool {
    const path = normalizePath(path_raw);
    const pattern = normalizePath(pattern_raw);
    if (std.mem.eql(u8, path, pattern)) return true;
    if (!bindingHasWildcard(pattern)) return std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == '/';
    return globMatch(path, pattern);
}

fn globMatch(path: []const u8, pattern: []const u8) bool {
    var path_index: usize = 0;
    var pattern_index: usize = 0;
    var star_after: ?usize = null;
    var star_path: usize = 0;
    var star_crosses_slash = false;

    while (path_index < path.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_crosses_slash = pattern_index + 1 < pattern.len and pattern[pattern_index + 1] == '*';
            pattern_index += if (star_crosses_slash) 2 else 1;
            star_after = pattern_index;
            star_path = path_index;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == path[path_index]) {
            pattern_index += 1;
            path_index += 1;
            continue;
        }
        if (star_after) |after| {
            if (star_path >= path.len or (!star_crosses_slash and path[star_path] == '/')) return false;
            star_path += 1;
            path_index = star_path;
            pattern_index = after;
            continue;
        }
        return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn bindingMatchesAny(paths: []const []const u8, bindings: []const []const u8) bool {
    for (bindings) |binding| for (paths) |path| if (matchesBinding(path, stripSymbol(binding))) return true;
    return false;
}

fn bindingHasWildcard(binding: []const u8) bool {
    return std.mem.indexOfScalar(u8, binding, '*') != null;
}

fn stripSymbol(binding: []const u8) []const u8 {
    return binding[0 .. std.mem.indexOfScalar(u8, binding, '#') orelse binding.len];
}

fn normalizePath(value: []const u8) []const u8 {
    var result = std.mem.trim(u8, value, " \t\r\n");
    while (std.mem.startsWith(u8, result, "./")) result = result[2..];
    while (std.mem.endsWith(u8, result, "/")) result = result[0 .. result.len - 1];
    return result;
}

fn isSkipped(spine: Spine, path: []const u8) bool {
    if (isVendored(spine, path)) return true;
    for (spine.skipDirs) |skip| if (matchesBinding(path, skip)) return true;
    return false;
}

fn isVendored(spine: Spine, path: []const u8) bool {
    for (spine.vendored) |prefix| if (matchesBinding(path, prefix)) return true;
    return false;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn isIsoDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |byte, index| if (index != 4 and index != 7 and !std.ascii.isDigit(byte)) return false;
    return true;
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_' or value[0] == '$')) return false;
    for (value[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$')) return false;
    return true;
}

fn isLineLocation(value: []const u8) bool {
    if (value.len == 0) return false;
    var dash_count: usize = 0;
    var digits_before: usize = 0;
    var digits_after: usize = 0;
    for (value) |byte| {
        if (byte == '-') {
            dash_count += 1;
            if (dash_count > 1) return false;
        } else if (!std.ascii.isDigit(byte)) return false else if (dash_count == 0) {
            digits_before += 1;
        } else {
            digits_after += 1;
        }
    }
    return digits_before != 0 and (dash_count == 0 or digits_after != 0);
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '\'' and value[value.len - 1] == '\'') or (value[0] == '"' and value[value.len - 1] == '"'))) return value[1 .. value.len - 1];
    return value;
}

fn collapseSpace(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var pending = false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending = true;
            continue;
        }
        if (pending and output.items.len != 0) try output.append(allocator, ' ');
        pending = false;
        try output.append(allocator, byte);
    }
    return output.toOwnedSlice(allocator);
}

fn summarise(allocator: std.mem.Allocator, paragraph: []const u8) ![]const u8 {
    const first = std.mem.indexOf(u8, paragraph, ". ") orelse return allocator.dupe(u8, paragraph);
    if (first + 1 >= 45) return allocator.dupe(u8, paragraph[0 .. first + 1]);
    const second_start = first + 2;
    const second = std.mem.indexOfPos(u8, paragraph, second_start, ". ") orelse return allocator.dupe(u8, paragraph);
    return allocator.dupe(u8, paragraph[0 .. second + 1]);
}

fn boldLead(invariant: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, invariant, "**")) return invariant;
    const end = std.mem.indexOfPos(u8, invariant, 2, "**") orelse return invariant;
    return invariant[2..end];
}

const FixtureMutation = enum {
    no_workspace,
    no_marked_area,
    no_tasks,
    no_verify,
    no_decisions,
    deleted_tracked_paths,
    git_failure,
    missing_task_classification,
    duplicate_task_classification,
    stale_task_classification,
    remote_write_without_approval,
    invariant_without_gate,
    ledger_bad_status,
    ledger_duplicate_id,
    ledger_bad_date,
    ledger_no_bindings,
    ledger_no_reason,
    ledger_no_reciprocal_supersession,
    ledger_stale_decision,
    stale_solution_binding,
    inline_line_range,
    link_line_anchor,
    missing_zig_symbol,
    nested_zig_symbol,
    missing_ts_symbol,
    nested_ts_symbol,
    regex_ts_symbol,
    strict_undeclared_document,
    missing_marker,
    duplicate_marker,
    reversed_marker,
    crossing_markers,
    generated_drift,
    write_refuses_other_failure,
    ledger_missing_gate,
};

const RejectionScenario = struct {
    mutation: FixtureMutation,
    kind: ?FailureKind,
    diagnostic: []const u8,
    write: bool = false,
};

const rejection_scenarios = [_]RejectionScenario{
    .{ .mutation = .no_workspace, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: agents.json declares no workspaces; add one manifest-backed workspace\n" },
    .{ .mutation = .no_marked_area, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: no marked area contracts found; add <!-- agent-spine: area --> to one nested AGENTS.md\n" },
    .{ .mutation = .no_tasks, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: the task census is empty; pass the completed build graph through --tasks\n" },
    .{ .mutation = .no_verify, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: agents.json declares no verify command; classify at least one task with intent verify\n" },
    .{ .mutation = .no_decisions, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: docs/decisions.md holds no parsed decisions; add one D-NNN entry\n" },
    .{ .mutation = .deleted_tracked_paths, .kind = .completion_floor, .diagnostic = "spine[completion_floor]: git ls-files found no existing tracked paths; restore the census before checking the spine\n" },
    .{ .mutation = .git_failure, .kind = null, .diagnostic = "spine: git ls-files failed; restore the repository census and rerun the check\n" },
    .{ .mutation = .missing_task_classification, .kind = .task_classification, .diagnostic = "spine[task_classification]: agents.json does not classify task extra; add one commands row\n" },
    .{ .mutation = .duplicate_task_classification, .kind = .task_classification, .diagnostic = "spine[task_classification]: agents.json classifies task verify 2 times; keep one commands row\n" },
    .{ .mutation = .stale_task_classification, .kind = .task_classification, .diagnostic = "spine[task_classification]: agents.json classifies stale task stale; remove it or restore the build task\n" },
    .{ .mutation = .remote_write_without_approval, .kind = .command_policy, .diagnostic = "spine[command_policy]: agents.json lets verify mutate a remote store without explicit-user approval; change approval\n" },
    .{ .mutation = .invariant_without_gate, .kind = .area_contract, .diagnostic = "spine[area_contract]: core/AGENTS.md has an invariant without a zig build gate; name the proving task\n" },
    .{ .mutation = .ledger_bad_status, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 has Status active; use standing or superseded\n" },
    .{ .mutation = .ledger_duplicate_id, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 is duplicated or out of order; keep unique ascending ids\n" },
    .{ .mutation = .ledger_bad_date, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 has no ISO Decided date; use YYYY-MM-DD\n" },
    .{ .mutation = .ledger_no_bindings, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 binds nothing; add a path, directory, or glob\n" },
    .{ .mutation = .ledger_no_reason, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 has no prose reason; add the specific reason\n" },
    .{ .mutation = .ledger_no_reciprocal_supersession, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 Superseded-by D-002 lacks superseded status or a reciprocal Supersedes link; update both entries\n" },
    .{ .mutation = .ledger_stale_decision, .kind = .decision_liveness, .diagnostic = "spine[decision_liveness]: docs/decisions.md: D-002 is standing but Binds [missing/path] match no existing tracked path and no area cites it; correct the bindings or supersede it\n" },
    .{ .mutation = .stale_solution_binding, .kind = .solution_binding, .diagnostic = "spine[solution_binding]: docs/solutions/note.md binds missing.zig#gone, which does not exist; correct or remove the binding\n" },
    .{ .mutation = .inline_line_range, .kind = .line_anchor, .diagnostic = "spine[line_anchor]: docs/solutions/note.md anchors src/main.zig:1-2 by line; replace it with a file or #symbol reference\n" },
    .{ .mutation = .link_line_anchor, .kind = .line_anchor, .diagnostic = "spine[line_anchor]: docs/solutions/note.md anchors ../../src/main.zig:1-2 by line; replace it with a file or #symbol reference\n" },
    .{ .mutation = .missing_zig_symbol, .kind = .symbol_anchor, .diagnostic = "spine[symbol_anchor]: docs/solutions/note.md anchors src/main.zig#missing, but src/main.zig declares no missing; use a current top-level declaration\n" },
    .{ .mutation = .nested_zig_symbol, .kind = .symbol_anchor, .diagnostic = "spine[symbol_anchor]: docs/solutions/note.md anchors src/main.zig#nested, but src/main.zig declares no nested; use a current top-level declaration\n" },
    .{ .mutation = .missing_ts_symbol, .kind = .symbol_anchor, .diagnostic = "spine[symbol_anchor]: docs/solutions/note.md anchors src/handler.ts#missing, but src/handler.ts declares no missing; use a current top-level declaration\n" },
    .{ .mutation = .nested_ts_symbol, .kind = .symbol_anchor, .diagnostic = "spine[symbol_anchor]: docs/solutions/note.md anchors src/handler.ts#nestedTs, but src/handler.ts declares no nestedTs; use a current top-level declaration\n" },
    .{ .mutation = .regex_ts_symbol, .kind = .symbol_anchor, .diagnostic = "spine[symbol_anchor]: docs/solutions/note.md anchors src/handler.ts#invented, but src/handler.ts declares no invented; use a current top-level declaration\n" },
    .{ .mutation = .strict_undeclared_document, .kind = .docs_policy, .diagnostic = "spine[docs_policy]: UNDECLARED.md is tracked but undeclared; add it as an authority, area, solution, or vendored path\n" },
    .{ .mutation = .missing_marker, .kind = .generated_markers, .diagnostic = "spine[generated_markers]: AGENTS.md needs one ordered complete pair for each generated areas and gates block; repair the markers\n" },
    .{ .mutation = .duplicate_marker, .kind = .generated_markers, .diagnostic = "spine[generated_markers]: AGENTS.md needs one ordered complete pair for each generated areas and gates block; repair the markers\n" },
    .{ .mutation = .reversed_marker, .kind = .generated_markers, .diagnostic = "spine[generated_markers]: AGENTS.md needs one ordered complete pair for each generated areas and gates block; repair the markers\n" },
    .{ .mutation = .crossing_markers, .kind = .generated_markers, .diagnostic = "spine[generated_markers]: AGENTS.md needs one ordered complete pair for each generated areas and gates block; repair the markers\n" },
    .{ .mutation = .generated_drift, .kind = .generated_drift, .diagnostic = "spine[generated_drift]: AGENTS.md's generated blocks disagree with agents.json; run zig build check-spine -- --write after other failures are clean\n" },
    .{ .mutation = .write_refuses_other_failure, .kind = .generated_drift, .diagnostic = "spine[command_policy]: agents.json lets verify mutate a remote store without explicit-user approval; change approval\n", .write = true },
    .{ .mutation = .ledger_missing_gate, .kind = .decision_ledger, .diagnostic = "spine[decision_ledger]: docs/decisions.md: D-001 has no Gate field; name a task or explicitly use none\n" },
};

comptime {
    var seen = std.EnumSet(FailureKind).initEmpty();
    for (rejection_scenarios) |scenario| if (scenario.kind) |kind| seen.insert(kind);
    for (@typeInfo(FailureKind).@"enum".fields) |field| {
        const kind: FailureKind = @enumFromInt(field.value);
        if (!seen.contains(kind)) @compileError("rejection_scenarios misses " ++ field.name);
    }
}

test "public rejection census observes completion floor failures" {
    try runRejectionScenarios(rejection_scenarios[0..6]);
}

test "public rejection census observes Git task command and area failures" {
    try runRejectionScenarios(rejection_scenarios[6..12]);
}

test "public rejection census observes decision ledger failures" {
    try runRejectionScenarios(rejection_scenarios[12..18]);
}

test "public rejection census observes liveness binding and anchor failures" {
    try runRejectionScenarios(rejection_scenarios[18..24]);
}

test "public rejection census observes symbol policy and marker failures" {
    try runRejectionScenarios(rejection_scenarios[24..29]);
}

test "public rejection census observes marker drift and guarded write failures" {
    try runRejectionScenarios(rejection_scenarios[29..]);
}

fn runRejectionScenarios(scenarios: []const RejectionScenario) !void {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCommandFixture(testing.io, &tmp, true);
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "init", "-q" });
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "add", "." });

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();

    const clean_write = try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
        .write = true,
    } }, &stdout.writer, &stderr.writer);
    try testing.expectEqual(ExitCode.clean, clean_write);

    const generated_root = try tmp.dir.readFileAlloc(testing.io, "AGENTS.md", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(generated_root);

    var expected = std.EnumSet(FailureKind).initEmpty();
    var observed = std.EnumSet(FailureKind).initEmpty();
    for (scenarios) |scenario| {
        stdout.clearRetainingCapacity();
        stderr.clearRetainingCapacity();
        const before = try execute(testing.allocator, testing.io, .{ .check = .{
            .root = root,
            .tasks_file = "tasks.txt",
        } }, &stdout.writer, &stderr.writer);
        try testing.expectEqual(ExitCode.clean, before);

        try applyFixtureMutation(testing.allocator, testing.io, &tmp, root, scenario.mutation);
        stdout.clearRetainingCapacity();
        stderr.clearRetainingCapacity();
        const rejected = try execute(testing.allocator, testing.io, .{ .check = .{
            .root = root,
            .tasks_file = "tasks.txt",
            .write = scenario.write,
        } }, &stdout.writer, &stderr.writer);
        if (rejected != .rule_failure) std.debug.print("mutation {s} returned {s}\n", .{ @tagName(scenario.mutation), @tagName(rejected) });
        try testing.expectEqual(ExitCode.rule_failure, rejected);
        try expectDiagnosticLine(stderr.written(), scenario.diagnostic);
        if (scenario.kind) |kind| {
            expected.insert(kind);
            var header_buffer: [64]u8 = undefined;
            const header = try std.fmt.bufPrint(&header_buffer, "spine[{s}]:", .{@tagName(kind)});
            try expectDiagnosticLine(stderr.written(), header);
            observed.insert(kind);
        }
        if (scenario.mutation == .write_refuses_other_failure) {
            const unchanged = try tmp.dir.readFileAlloc(testing.io, "AGENTS.md", testing.allocator, .limited(64 * 1024));
            defer testing.allocator.free(unchanged);
            try testing.expectEqualStrings(generated_root, unchanged);
        }

        try restoreCommandFixture(testing.allocator, testing.io, &tmp, root, generated_root);
        stdout.clearRetainingCapacity();
        stderr.clearRetainingCapacity();
        const restored = try execute(testing.allocator, testing.io, .{ .check = .{
            .root = root,
            .tasks_file = "tasks.txt",
        } }, &stdout.writer, &stderr.writer);
        try testing.expectEqual(ExitCode.clean, restored);
    }
    try testing.expect(observed.eql(expected));
}

test "public check reads an area marker before its title" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCommandFixture(testing.io, &tmp, true);
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "init", "-q" });
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "add", "." });
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();
    try testing.expectEqual(ExitCode.clean, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
        .write = true,
    } }, &stdout.writer, &stderr.writer));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "core/AGENTS.md", .data =
        \\<!-- agent-spine: area -->
        \\# core
        \\
        \\The core area owns the fixture source.
        \\
        \\No import boundary applies. The `zig build verify` task checks the invariant.
        \\
        \\## Invariants
        \\
        \\- **The fixture source stays present.** Proved by `zig build verify`.
        \\
        \\## Decisions that bind here
        \\
        \\D-001
        \\
    });
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try testing.expectEqual(ExitCode.clean, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
    } }, &stdout.writer, &stderr.writer));
}

test "public check names unreadable configuration inputs" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCommandFixture(testing.io, &tmp, true);
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "init", "-q" });
    try runGitFixture(testing.allocator, testing.io, root, &.{ "git", "add", "." });
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();
    try testing.expectEqual(ExitCode.clean, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
        .write = true,
    } }, &stdout.writer, &stderr.writer));
    const generated_root = try tmp.dir.readFileAlloc(testing.io, "AGENTS.md", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(generated_root);

    try tmp.dir.deleteFile(testing.io, "tasks.txt");
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try testing.expectEqual(ExitCode.usage_failure, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
    } }, &stdout.writer, &stderr.writer));
    try expectDiagnosticLine(stderr.written(), "spine: cannot read task census tasks.txt: FileNotFound; pass the readable graph file through --tasks\n");
    try restoreCommandFixture(testing.allocator, testing.io, &tmp, root, generated_root);

    try tmp.dir.deleteFile(testing.io, "docs/decisions.md");
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try testing.expectEqual(ExitCode.usage_failure, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
    } }, &stdout.writer, &stderr.writer));
    try expectDiagnosticLine(stderr.written(), "spine: cannot read decision ledger docs/decisions.md: FileNotFound; restore the configured ledger path\n");
    try restoreCommandFixture(testing.allocator, testing.io, &tmp, root, generated_root);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agents.json", .data = "{}\n" });
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try testing.expectEqual(ExitCode.usage_failure, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
    } }, &stdout.writer, &stderr.writer));
    try expectDiagnosticLine(stderr.written(), "spine: cannot read manifest agents.json: MissingField; fix its required fields and enum values\n");
    try restoreCommandFixture(testing.allocator, testing.io, &tmp, root, generated_root);
    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try testing.expectEqual(ExitCode.clean, try execute(testing.allocator, testing.io, .{ .check = .{
        .root = root,
        .tasks_file = "tasks.txt",
    } }, &stdout.writer, &stderr.writer));
}

fn writeCommandFixture(io: std.Io, tmp: *std.testing.TmpDir, safe_approval: bool) !void {
    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.createDirPath(io, "docs/solutions");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tasks.txt", .data = "verify\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void { const nested = 1; _ = nested; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/handler.ts", .data =
        \\const pattern = /export const invented = 1/;
        \\export const handler = () => 1;
        \\function outer() { const nestedTs = 1; return nestedTs; }
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data =
        \\# Fixture
        \\
        \\<!-- generated: areas -->
        \\
        \\<!-- end generated: areas -->
        \\
        \\<!-- generated: gates -->
        \\
        \\<!-- end generated: gates -->
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/AGENTS.md", .data =
        \\# core
        \\
        \\<!-- agent-spine: area -->
        \\
        \\The core area owns the fixture source.
        \\
        \\No import boundary applies. The `zig build verify` task checks the invariant.
        \\
        \\## Invariants
        \\
        \\- **The fixture source stays present.** Proved by `zig build verify`.
        \\
        \\## Decisions that bind here
        \\
        \\D-001
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/decisions.md", .data =
        \\# Decisions
        \\
        \\### D-001 Keep the fixture small
        \\
        \\- Status: standing
        \\- Decided: 2026-10-14
        \\- Binds: src
        \\- Gate: zig build verify
        \\
        \\A small fixture makes each rejection cause visible.
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/solutions/note.md", .data =
        \\---
        \\binds:
        \\  - src/main.zig
        \\proves: zig build verify
        \\---
        \\
        \\# Fixture note
        \\
    });
    try writeCommandManifest(io, tmp, safe_approval);
}

fn writeCommandManifest(io: std.Io, tmp: *std.testing.TmpDir, safe_approval: bool) !void {
    const approval = if (safe_approval) "explicit-user" else "none";
    var manifest: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer manifest.deinit();
    try manifest.writer.print(
        \\{{
        \\  "runner": "zig build",
        \\  "root": "AGENTS.md",
        \\  "areaFile": "AGENTS.md",
        \\  "docsPolicy": "off",
        \\  "sourceExtensions": ["zig", "ts"],
        \\  "workspaces": [{{"manifest":"build.zig","cwd":"","kind":"zig-build"}}],
        \\  "authorities": ["AGENTS.md", "docs/decisions.md"],
        \\  "vendored": [],
        \\  "skipDirs": [],
        \\  "docs": {{"decisions":"docs/decisions.md","solutions":"docs/solutions","canonicalGate":"zig build verify"}},
        \\  "commands": [{{"task":"verify","intent":"verify","effect":"remote-write","approval":"{s}","does":"checks the fixture","always":true}}]
        \\}}
        \\
    , .{approval});
    try tmp.dir.writeFile(io, .{ .sub_path = "agents.json", .data = manifest.written() });
}

fn expectDiagnosticLine(actual: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected) != null) return;
    std.debug.print("expected diagnostic line:\n{s}\nactual diagnostics:\n{s}\n", .{ expected, actual });
    return error.MissingDiagnostic;
}

fn restoreCommandFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    generated_root: []const u8,
) !void {
    try writeCommandFixture(io, tmp, true);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = generated_root });
    tmp.dir.deleteFile(io, "UNDECLARED.md") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try runGitFixture(allocator, io, root, &.{ "git", "init", "-q" });
    try runGitFixture(allocator, io, root, &.{ "git", "add", "-A" });
}

fn applyFixtureMutation(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    mutation: FixtureMutation,
) !void {
    switch (mutation) {
        .no_workspace,
        .no_verify,
        .duplicate_task_classification,
        .stale_task_classification,
        .remote_write_without_approval,
        .generated_drift,
        .write_refuses_other_failure,
        => try writeMutatedManifest(io, tmp, mutation),
        .strict_undeclared_document => {
            try writeMutatedManifest(io, tmp, mutation);
            try tmp.dir.writeFile(io, .{ .sub_path = "UNDECLARED.md", .data = "undeclared\n" });
            try runGitFixture(allocator, io, root, &.{ "git", "add", "UNDECLARED.md" });
        },
        .no_marked_area, .invariant_without_gate => try writeMutatedArea(io, tmp, mutation),
        .no_tasks => try tmp.dir.writeFile(io, .{ .sub_path = "tasks.txt", .data = "" }),
        .no_decisions,
        .ledger_bad_status,
        .ledger_duplicate_id,
        .ledger_bad_date,
        .ledger_no_bindings,
        .ledger_no_reason,
        .ledger_no_reciprocal_supersession,
        .ledger_stale_decision,
        .ledger_missing_gate,
        => try writeMutatedLedger(io, tmp, mutation),
        .missing_task_classification => try tmp.dir.writeFile(io, .{ .sub_path = "tasks.txt", .data = "verify\nextra\n" }),
        .stale_solution_binding,
        .inline_line_range,
        .link_line_anchor,
        .missing_zig_symbol,
        .nested_zig_symbol,
        .missing_ts_symbol,
        .nested_ts_symbol,
        .regex_ts_symbol,
        => try writeMutatedSolution(io, tmp, mutation),
        .missing_marker, .duplicate_marker, .reversed_marker, .crossing_markers => try writeMutatedRoot(io, tmp, mutation),
        .deleted_tracked_paths => {
            try runGitFixture(allocator, io, root, &.{ "git", "rm", "--cached", "-r", "-q", "." });
            try tmp.dir.writeFile(io, .{ .sub_path = "deleted-path", .data = "tracked then deleted\n" });
            try runGitFixture(allocator, io, root, &.{ "git", "add", "deleted-path" });
            try tmp.dir.deleteFile(io, "deleted-path");
        },
        .git_failure => try tmp.dir.deleteTree(io, ".git"),
    }
}

fn writeMutatedManifest(io: std.Io, tmp: *std.testing.TmpDir, mutation: FixtureMutation) !void {
    const workspaces = if (mutation == .no_workspace)
        "[]"
    else
        "[{\"manifest\":\"build.zig\",\"cwd\":\"\",\"kind\":\"zig-build\"}]";
    const policy = if (mutation == .strict_undeclared_document) "strict" else "off";
    const commands = switch (mutation) {
        .no_verify => "[{\"task\":\"verify\",\"intent\":\"build\",\"effect\":\"none\",\"approval\":\"none\",\"does\":\"checks the fixture\",\"always\":true}]",
        .duplicate_task_classification => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"explicit-user\",\"does\":\"checks the fixture\",\"always\":true},{\"task\":\"verify\",\"intent\":\"run\",\"effect\":\"none\",\"approval\":\"none\",\"does\":\"duplicates the fixture\"}]",
        .stale_task_classification => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"explicit-user\",\"does\":\"checks the fixture\",\"always\":true},{\"task\":\"stale\",\"intent\":\"run\",\"effect\":\"none\",\"approval\":\"none\",\"does\":\"is stale\"}]",
        .remote_write_without_approval => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"none\",\"does\":\"checks the fixture\",\"always\":true}]",
        .generated_drift => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"explicit-user\",\"does\":\"checks changed fixture text\",\"always\":true}]",
        .write_refuses_other_failure => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"none\",\"does\":\"checks changed fixture text\",\"always\":true}]",
        else => "[{\"task\":\"verify\",\"intent\":\"verify\",\"effect\":\"remote-write\",\"approval\":\"explicit-user\",\"does\":\"checks the fixture\",\"always\":true}]",
    };
    var manifest: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer manifest.deinit();
    try manifest.writer.print(
        "{{\"runner\":\"zig build\",\"root\":\"AGENTS.md\",\"areaFile\":\"AGENTS.md\",\"docsPolicy\":\"{s}\",\"sourceExtensions\":[\"zig\",\"ts\"],\"workspaces\":{s},\"authorities\":[\"AGENTS.md\",\"docs/decisions.md\"],\"vendored\":[],\"skipDirs\":[],\"docs\":{{\"decisions\":\"docs/decisions.md\",\"solutions\":\"docs/solutions\",\"canonicalGate\":\"zig build verify\"}},\"commands\":{s}}}\n",
        .{ policy, workspaces, commands },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "agents.json", .data = manifest.written() });
}

fn writeMutatedArea(io: std.Io, tmp: *std.testing.TmpDir, mutation: FixtureMutation) !void {
    const marker = if (mutation == .no_marked_area) "" else "<!-- agent-spine: area -->\n\n";
    const invariant = if (mutation == .invariant_without_gate)
        "- **The fixture source stays present.** Proved by `zig build verify`.\n\n- **Each invariant names its own gate.** zig build"
    else
        "- **The fixture source stays present.** Proved by `zig build verify`.";
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.print(
        "# core\n\n{s}The core area owns the fixture source.\n\nNo import boundary applies. The `zig build verify` task checks the invariant.\n\n## Invariants\n\n{s}\n\n## Decisions that bind here\n\nD-001\n",
        .{ marker, invariant },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "core/AGENTS.md", .data = source.written() });
}

fn writeMutatedLedger(io: std.Io, tmp: *std.testing.TmpDir, mutation: FixtureMutation) !void {
    const source: []const u8 = switch (mutation) {
        .no_decisions => "# Decisions\n",
        .ledger_bad_status => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: active\n- Decided: 2026-10-14\n- Binds: src\n- Gate: zig build verify\n\nA reason remains.\n",
        .ledger_duplicate_id => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: src\n- Gate: zig build verify\n\nA first reason.\n" ++
            "\n### D-001 Duplicate\n\n- Status: superseded\n- Decided: 2026-10-15\n- Binds: src\n- Gate: none\n- Superseded-by: D-001\n",
        .ledger_bad_date => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 14 October 2026\n- Binds: src\n- Gate: zig build verify\n\nA reason remains.\n",
        .ledger_no_bindings => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: \n- Gate: zig build verify\n\nA reason remains.\n",
        .ledger_no_reason => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: src\n- Gate: zig build verify\n",
        .ledger_missing_gate => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: src\n\nA reason remains.\n",
        .ledger_no_reciprocal_supersession => "# Decisions\n\n### D-001 Old rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: src\n- Gate: zig build verify\n- Superseded-by: D-002\n\nOld reason.\n\n### D-002 New rule\n\n- Status: standing\n- Decided: 2026-10-15\n- Binds: src\n- Gate: zig build verify\n\nNew reason.\n",
        .ledger_stale_decision => "# Decisions\n\n### D-001 Fixture rule\n\n- Status: standing\n- Decided: 2026-10-14\n- Binds: src\n- Gate: zig build verify\n\nThe first reason remains.\n" ++
            "\n### D-002 Stale rule\n\n- Status: standing\n- Decided: 2026-10-15\n- Binds: missing/path\n- Gate: zig build verify\n\nThe stale rule has a reason.\n",
        else => unreachable,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/decisions.md", .data = source });
}

fn writeMutatedSolution(io: std.Io, tmp: *std.testing.TmpDir, mutation: FixtureMutation) !void {
    const binding = if (mutation == .stale_solution_binding) "missing.zig#gone" else "src/main.zig";
    const body: []const u8 = switch (mutation) {
        .inline_line_range => "Uses `src/main.zig:1-2`.\n",
        .link_line_anchor => "Uses [main](../../src/main.zig:1-2).\n",
        .missing_zig_symbol => "Uses `src/main.zig#missing`.\n",
        .nested_zig_symbol => "Uses `src/main.zig#nested`.\n",
        .missing_ts_symbol => "Uses `src/handler.ts#missing`.\n",
        .nested_ts_symbol => "Uses `src/handler.ts#nestedTs`.\n",
        .regex_ts_symbol => "Uses `src/handler.ts#invented`.\n",
        else => "Fixture note.\n",
    };
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.print("---\nbinds:\n  - {s}\nproves: zig build verify\n---\n\n# Fixture note\n\n{s}", .{ binding, body });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/solutions/note.md", .data = source.written() });
}

fn writeMutatedRoot(io: std.Io, tmp: *std.testing.TmpDir, mutation: FixtureMutation) !void {
    const source: []const u8 = switch (mutation) {
        .missing_marker => "# Fixture\n\n<!-- generated: areas -->\n<!-- end generated: areas -->\n<!-- generated: gates -->\n",
        .duplicate_marker => "# Fixture\n\n<!-- generated: areas -->\n<!-- generated: areas -->\n<!-- end generated: areas -->\n<!-- generated: gates -->\n<!-- end generated: gates -->\n",
        .reversed_marker => "# Fixture\n\n<!-- end generated: areas -->\n<!-- generated: areas -->\n<!-- generated: gates -->\n<!-- end generated: gates -->\n",
        .crossing_markers => "# Fixture\n\n<!-- generated: areas -->\n<!-- generated: gates -->\n<!-- end generated: areas -->\n<!-- end generated: gates -->\n",
        else => unreachable,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = source });
}

fn runGitFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed) return error.GitFixtureFailed;
}
