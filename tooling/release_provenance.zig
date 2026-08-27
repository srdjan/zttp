//! Authoritative release-evidence provenance validator.
//!
//! Coverage and convergence publishers record the clean source commit they
//! measured. A later commit may contain only the generated evidence outputs;
//! any other changed path makes the evidence stale for the release tree.

const std = @import("std");

pub const evidence_files = [_][]const u8{
    "docs/coverage.json",
    "docs/convergence.json",
};

const generated_evidence_paths = [_][]const u8{
    "docs/coverage.json",
    "docs/coverage.md",
    "docs/convergence.json",
    "docs/convergence.md",
};

pub const Report = struct {
    source_commits: std.ArrayList([]u8) = .empty,
    errors: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.source_commits.items) |commit| allocator.free(commit);
        self.source_commits.deinit(allocator);
        for (self.errors.items) |message| allocator.free(message);
        self.errors.deinit(allocator);
        self.* = .{};
    }

    fn addError(
        self: *Report,
        allocator: std.mem.Allocator,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(allocator, format, args);
        errdefer allocator.free(message);
        try self.errors.append(allocator, message);
    }

    fn addCommit(self: *Report, allocator: std.mem.Allocator, commit: []const u8) !void {
        const owned = try allocator.dupe(u8, commit);
        errdefer allocator.free(owned);
        try self.source_commits.append(allocator, owned);
    }
};

const GitResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *GitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    argv: []const []const u8,
) !GitResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    return .{
        .ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn isFullLowerHexCommit(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn fieldIsTrue(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn isGeneratedEvidencePath(path: []const u8) bool {
    for (generated_evidence_paths) |allowed| {
        if (std.mem.eql(u8, path, allowed)) return true;
    }
    return false;
}

fn validateEvidenceFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    relative_path: []const u8,
    report: *Report,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        try report.addError(
            allocator,
            "{s} is unreadable: {s}",
            .{ relative_path, @errorName(err) },
        );
        return;
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        try report.addError(
            allocator,
            "{s} is invalid JSON: {s}",
            .{ relative_path, @errorName(err) },
        );
        return;
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => {
            try report.addError(allocator, "{s} must contain a JSON object", .{relative_path});
            return;
        },
    };

    for ([_][]const u8{ "complete", "publishable", "publicationMode" }) |field| {
        if (!fieldIsTrue(object, field)) {
            try report.addError(allocator, "{s} must record {s}=true", .{ relative_path, field });
        }
    }
    const source_dirty = object.get("sourceDirty");
    if (source_dirty == null or source_dirty.? != .bool or source_dirty.?.bool) {
        try report.addError(allocator, "{s} must record sourceDirty=false", .{relative_path});
    }

    const source_value = object.get("sourceCommit") orelse {
        try report.addError(allocator, "{s} has no full lowercase sourceCommit", .{relative_path});
        return;
    };
    if (source_value != .string or !isFullLowerHexCommit(source_value.string)) {
        try report.addError(allocator, "{s} has no full lowercase sourceCommit", .{relative_path});
        return;
    }
    const source_commit = source_value.string;
    try report.addCommit(allocator, source_commit);

    const commit_spec = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{source_commit});
    defer allocator.free(commit_spec);
    var exists = try runGit(allocator, io, root, &.{ "git", "cat-file", "-e", commit_spec });
    defer exists.deinit(allocator);
    if (!exists.ok) {
        try report.addError(
            allocator,
            "{s} names sourceCommit {s} that is absent from this checkout",
            .{ relative_path, source_commit },
        );
        return;
    }

    var ancestor = try runGit(
        allocator,
        io,
        root,
        &.{ "git", "merge-base", "--is-ancestor", source_commit, "HEAD" },
    );
    defer ancestor.deinit(allocator);
    if (!ancestor.ok) {
        try report.addError(
            allocator,
            "{s} sourceCommit {s} is not an ancestor of HEAD",
            .{ relative_path, source_commit },
        );
        return;
    }

    const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{source_commit});
    defer allocator.free(range);
    var changed = try runGit(
        allocator,
        io,
        root,
        &.{ "git", "diff", "--name-only", range, "--" },
    );
    defer changed.deinit(allocator);
    if (!changed.ok) {
        try report.addError(
            allocator,
            "{s} cannot compare sourceCommit {s} with HEAD",
            .{ relative_path, source_commit },
        );
        return;
    }
    var lines = std.mem.tokenizeAny(u8, changed.stdout, "\r\n");
    while (lines.next()) |changed_path| {
        if (isGeneratedEvidencePath(changed_path)) continue;
        try report.addError(
            allocator,
            "{s} is stale because {s} changed after sourceCommit {s}",
            .{ relative_path, changed_path, source_commit },
        );
    }
}

pub fn validateRepository(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !Report {
    var report: Report = .{};
    errdefer report.deinit(allocator);
    for (evidence_files) |path| {
        try validateEvidenceFile(allocator, io, root, path, &report);
    }
    return report;
}

pub fn passes(allocator: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    var report = validateRepository(allocator, io, root) catch return false;
    defer report.deinit(allocator);
    return report.errors.items.len == 0;
}

pub fn main(_: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var report = try validateRepository(allocator, io, ".");
    defer report.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    if (report.errors.items.len != 0) {
        for (report.errors.items) |message| {
            try stderr_writer.interface.print("release provenance: {s}\n", .{message});
        }
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }

    try stdout_writer.interface.writeAll("release evidence provenance OK:");
    for (report.source_commits.items) |commit| {
        try stdout_writer.interface.print(" {s}", .{commit[0..12]});
    }
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn expectErrorContaining(report: *const Report, needle: []const u8) !void {
    for (report.errors.items) |message| {
        if (std.mem.indexOf(u8, message, needle) != null) return;
    }
    return error.ExpectedProvenanceError;
}

fn commitRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    message: []const u8,
    paths: []const []const u8,
) !void {
    if (paths.len != 0) {
        var add_args: std.ArrayList([]const u8) = .empty;
        defer add_args.deinit(allocator);
        try add_args.appendSlice(allocator, &.{ "git", "add", "--" });
        try add_args.appendSlice(allocator, paths);
        var add = try runGit(allocator, io, root, add_args.items);
        defer add.deinit(allocator);
        if (!add.ok) return error.GitAddFailed;
    }
    var result = try runGit(allocator, io, root, &.{
        "git",
        "-c",
        "user.name=zttp test",
        "-c",
        "user.email=test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-qm",
        message,
    });
    defer result.deinit(allocator);
    if (!result.ok) return error.GitCommitFailed;
}

fn headCommit(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    var result = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer result.deinit(allocator);
    if (!result.ok) return error.GitRevParseFailed;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

const EvidenceOptions = struct {
    complete: bool = true,
    source_dirty: bool = false,
};

fn writeEvidence(
    tmp: *std.testing.TmpDir,
    source_commit: []const u8,
    options: EvidenceOptions,
) !void {
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"complete\":{},\"publishable\":true,\"publicationMode\":true,\"sourceCommit\":\"{s}\",\"sourceDirty\":{}}}\n",
        .{ options.complete, source_commit, options.source_dirty },
    );
    defer std.testing.allocator.free(payload);
    for (evidence_files) |path| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = payload });
    }
}

test "accepts clean evidence followed only by generated outputs" {
    const allocator = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var init = try runGit(allocator, io, root, &.{ "git", "init", "-q" });
    defer init.deinit(allocator);
    try std.testing.expect(init.ok);
    try commitRepo(allocator, io, root, "source", &.{});
    const source_commit = try headCommit(allocator, io, root);
    defer allocator.free(source_commit);
    try writeEvidence(&tmp, source_commit, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/coverage.md", .data = "coverage\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/convergence.md", .data = "convergence\n" });
    try commitRepo(allocator, io, root, "evidence", &generated_evidence_paths);

    var report = try validateRepository(allocator, io, root);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), report.errors.items.len);
}

test "rejects source changes after evidence was measured" {
    const allocator = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var init = try runGit(allocator, io, root, &.{ "git", "init", "-q" });
    defer init.deinit(allocator);
    try std.testing.expect(init.ok);
    try commitRepo(allocator, io, root, "source", &.{});
    const source_commit = try headCommit(allocator, io, root);
    defer allocator.free(source_commit);
    try writeEvidence(&tmp, source_commit, .{});
    try commitRepo(allocator, io, root, "evidence", &evidence_files);
    try tmp.dir.writeFile(io, .{ .sub_path = "runtime.zig", .data = "pub const changed = true;\n" });
    try commitRepo(allocator, io, root, "later source", &.{"runtime.zig"});

    var report = try validateRepository(allocator, io, root);
    defer report.deinit(allocator);
    try expectErrorContaining(&report, "runtime.zig changed after sourceCommit");
}

test "rejects a source commit outside HEAD ancestry" {
    const allocator = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var init = try runGit(allocator, io, root, &.{ "git", "init", "-q" });
    defer init.deinit(allocator);
    try std.testing.expect(init.ok);
    try commitRepo(allocator, io, root, "source", &.{});
    const source_commit = try headCommit(allocator, io, root);
    defer allocator.free(source_commit);
    var orphan = try runGit(allocator, io, root, &.{ "git", "checkout", "--orphan", "unrelated" });
    defer orphan.deinit(allocator);
    try std.testing.expect(orphan.ok);
    try commitRepo(allocator, io, root, "unrelated", &.{});
    try writeEvidence(&tmp, source_commit, .{});

    var report = try validateRepository(allocator, io, root);
    defer report.deinit(allocator);
    try expectErrorContaining(&report, "is not an ancestor of HEAD");
}

test "rejects missing commits and dirty or incomplete evidence" {
    const allocator = std.testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var init = try runGit(allocator, io, root, &.{ "git", "init", "-q" });
    defer init.deinit(allocator);
    try std.testing.expect(init.ok);
    try commitRepo(allocator, io, root, "source", &.{});
    try writeEvidence(&tmp, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .{
        .complete = false,
        .source_dirty = true,
    });

    var report = try validateRepository(allocator, io, root);
    defer report.deinit(allocator);
    try expectErrorContaining(&report, "complete=true");
    try expectErrorContaining(&report, "sourceDirty=false");
    try expectErrorContaining(&report, "absent from this checkout");
}
