//! Host-authoritative preparation for ordered source change sets.
//!
//! This module performs no writes. It turns a model proposal into owned,
//! canonical targets and exact baselines that later proof and transaction
//! stages can bind.

const std = @import("std");
const project_config = @import("project_config");
const turn = @import("turn.zig");
const common = @import("tools/common.zig");
const file_io = @import("zts").file_io;

pub const max_changes: usize = 32;
pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const max_aggregate_bytes: usize = 32 * 1024 * 1024;

pub const BaselineState = union(enum) {
    absent,
    present: []u8,

    pub fn bytes(self: BaselineState) ?[]const u8 {
        return switch (self) {
            .absent => null,
            .present => |value| value,
        };
    }

    fn deinit(self: *BaselineState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .absent => {},
            .present => |value| allocator.free(value),
        }
        self.* = .absent;
    }
};

pub const PreparedChange = struct {
    authored_path: []u8,
    resolved_path: []u8,
    candidate: []u8,
    baseline: BaselineState,
    baseline_sha256: [32]u8,
    rewrite_trace: [][]u8 = &.{},

    pub fn deinit(self: *PreparedChange, allocator: std.mem.Allocator) void {
        allocator.free(self.authored_path);
        allocator.free(self.resolved_path);
        allocator.free(self.candidate);
        self.baseline.deinit(allocator);
        for (self.rewrite_trace) |intent| allocator.free(intent);
        allocator.free(self.rewrite_trace);
        self.* = undefined;
    }
};

pub const PreparedChangeSet = struct {
    workspace_root: []u8,
    project_root: []u8,
    changes: []PreparedChange,

    pub fn deinit(self: *PreparedChangeSet, allocator: std.mem.Allocator) void {
        for (self.changes) |*change| change.deinit(allocator);
        allocator.free(self.changes);
        allocator.free(self.workspace_root);
        allocator.free(self.project_root);
        self.* = undefined;
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    proposal: turn.ChangeSet,
) !PreparedChangeSet {
    if (proposal.len() > max_changes) return error.TooManyChanges;

    const canonical_workspace = try common.resolveInsideWorkspace(allocator, workspace_root, ".");
    errdefer allocator.free(canonical_workspace);
    const changes = try allocator.alloc(PreparedChange, proposal.len());
    errdefer allocator.free(changes);
    var initialized: usize = 0;
    errdefer for (changes[0..initialized]) |*change| change.deinit(allocator);

    var aggregate_bytes: usize = 0;
    var common_project_root: ?[]u8 = null;
    errdefer if (common_project_root) |root| allocator.free(root);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var index: usize = 0;
    while (index < proposal.len()) : (index += 1) {
        const model_change = proposal.at(index);
        if (std.fs.path.isAbsolute(model_change.file)) return error.AbsoluteTargetUnsupported;
        if (!isSupportedSourcePath(model_change.file)) return error.UnsupportedSourceTarget;
        if (model_change.content.len > max_file_bytes) return error.ChangeTooLarge;
        aggregate_bytes = std.math.add(usize, aggregate_bytes, model_change.content.len) catch
            return error.ChangeSetTooLarge;
        if (aggregate_bytes > max_aggregate_bytes) return error.ChangeSetTooLarge;

        const lexical_path = try std.fs.path.resolve(allocator, &.{ canonical_workspace, model_change.file });
        defer allocator.free(lexical_path);
        const resolved_path = try common.resolveInsideWorkspace(allocator, canonical_workspace, model_change.file);
        errdefer allocator.free(resolved_path);
        if (!std.mem.eql(u8, lexical_path, resolved_path)) return error.SymlinkTargetUnsupported;
        try requireExistingParent(io, resolved_path);
        try requireRegularOrAbsent(io, resolved_path);

        for (changes[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.resolved_path, resolved_path)) return error.DuplicateTarget;
        }

        const baseline: BaselineState = if (file_io.readFile(allocator, resolved_path, max_file_bytes)) |bytes|
            .{ .present = bytes }
        else |err| switch (err) {
            error.FileNotFound => .absent,
            else => return err,
        };
        errdefer {
            var owned = baseline;
            owned.deinit(allocator);
        }
        if (baseline.bytes()) |before| {
            if (std.mem.eql(u8, before, model_change.content)) return error.NoOpChange;
        }

        const project_root = try discoverProjectRoot(allocator, io, canonical_workspace, resolved_path, baseline == .present);
        defer allocator.free(project_root);
        if (common_project_root) |root| {
            if (!std.mem.eql(u8, root, project_root)) return error.CrossProjectChangeSet;
        } else {
            common_project_root = try allocator.dupe(u8, project_root);
        }

        changes[index] = .{
            .authored_path = try allocator.dupe(u8, model_change.file),
            .resolved_path = resolved_path,
            .candidate = try allocator.dupe(u8, model_change.content),
            .baseline = baseline,
            .baseline_sha256 = digestBaseline(baseline.bytes()),
            .rewrite_trace = &.{},
        };
        initialized += 1;
    }

    return .{
        .workspace_root = canonical_workspace,
        .project_root = common_project_root.?,
        .changes = changes,
    };
}

fn isSupportedSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

fn requireExistingParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.MissingTargetParent;
    const stat = std.Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingTargetParent,
        else => return err,
    };
    if (stat.kind != .directory) return error.MissingTargetParent;
}

fn requireRegularOrAbsent(io: std.Io, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => {},
        .sym_link => return error.SymlinkTargetUnsupported,
        else => return error.NonRegularTarget,
    }
}

fn discoverProjectRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    resolved_path: []const u8,
    target_exists: bool,
) ![]u8 {
    const anchor = if (target_exists)
        resolved_path
    else
        std.fs.path.dirname(resolved_path) orelse return error.MissingTargetParent;
    var config = try project_config.discover(allocator, io, anchor);
    defer if (config) |*value| value.deinit(allocator);
    if (config) |value| {
        if (!common.isPathInsideRoot(workspace_root, value.root_dir)) return error.ProjectOutsideWorkspace;
        return try allocator.dupe(u8, value.root_dir);
    }
    return try allocator.dupe(u8, workspace_root);
}

pub fn digestBaseline(bytes: ?[]const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    if (bytes) |value| {
        hasher.update("present\x00");
        hasher.update(value);
    } else {
        hasher.update("absent\x00");
    }
    return hasher.finalResult();
}

const testing = std.testing;

fn rootPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const path_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, io_backend.io(), ".", allocator);
    defer allocator.free(path_z);
    return allocator.dupe(u8, path_z);
}

test "prepare owns ordered present and absent baselines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    const root = try rootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const tail = [_]turn.Change{.{ .file = "src/b.tsx", .content = "new" }};

    var prepared = try prepare(testing.allocator, root, .{
        .file = "src/a.ts",
        .content = "changed",
        .additional = &tail,
    });
    defer prepared.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), prepared.changes.len);
    try testing.expectEqualStrings("old", prepared.changes[0].baseline.bytes().?);
    try testing.expect(prepared.changes[1].baseline == .absent);
    try testing.expectEqualStrings("src/b.tsx", prepared.changes[1].authored_path);
}

test "prepare rejects duplicate aliases no-ops and unsupported targets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    const root = try rootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);

    const duplicate = [_]turn.Change{.{ .file = "src/./a.ts", .content = "other" }};
    try testing.expectError(error.DuplicateTarget, prepare(testing.allocator, root, .{
        .file = "src/a.ts",
        .content = "new",
        .additional = &duplicate,
    }));
    try testing.expectError(error.NoOpChange, prepare(testing.allocator, root, .{
        .file = "src/a.ts",
        .content = "old",
    }));
    try testing.expectError(error.UnsupportedSourceTarget, prepare(testing.allocator, root, .{
        .file = "zttp.json",
        .content = "{}",
    }));
    try testing.expectError(error.MissingTargetParent, prepare(testing.allocator, root, .{
        .file = "missing/a.ts",
        .content = "new",
    }));
}

test "prepare rejects path escapes and symlink targets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    try tmp.dir.symLink(testing.io, "a.ts", "src/link.ts", .{});
    const root = try rootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);

    try testing.expectError(error.PathOutsideWorkspace, prepare(testing.allocator, root, .{
        .file = "../escape.ts",
        .content = "new",
    }));
    try testing.expectError(error.SymlinkTargetUnsupported, prepare(testing.allocator, root, .{
        .file = "src/link.ts",
        .content = "new",
    }));
}

test "prepare rejects targets from separate projects" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "one/src");
    try tmp.dir.createDirPath(testing.io, "two/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one/zttp.json", .data = "{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two/zttp.json", .data = "{}" });
    const root = try rootPath(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const tail = [_]turn.Change{.{ .file = "two/src/b.ts", .content = "b" }};

    try testing.expectError(error.CrossProjectChangeSet, prepare(testing.allocator, root, .{
        .file = "one/src/a.ts",
        .content = "a",
        .additional = &tail,
    }));
}
