//! Private, short-lived filesystem boundary for production flow simulation.

const std = @import("std");

const temp_root = "/tmp";
const name_prefix = "zttp-flow-simulator-";
const creation_attempts = 16;

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    root: std.Io.Dir,
    abs_path: [:0]u8,
    previous_cwd: ?[]u8 = null,

    /// Creates a private directory without removing or reusing an existing path.
    /// The returned workspace owns `abs_path` and both directory handles.
    pub fn create(allocator: std.mem.Allocator, io: std.Io) !Workspace {
        var parent = try std.Io.Dir.openDirAbsolute(io, temp_root, .{});
        errdefer parent.close(io);

        for (0..creation_attempts) |_| {
            var random_bytes: [16]u8 = undefined;
            try io.randomSecure(&random_bytes);
            const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
            var name_buffer: [name_prefix.len + random_hex.len]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ name_prefix, random_hex });

            parent.createDir(io, name, privateDirPermissions()) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer parent.deleteTree(io, name) catch {};

            const abs_path = try std.Io.Dir.realPathFileAlloc(parent, io, name, allocator);
            errdefer allocator.free(abs_path);
            var root = try parent.openDir(io, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            errdefer root.close(io);

            return .{
                .allocator = allocator,
                .io = io,
                .parent = parent,
                .root = root,
                .abs_path = abs_path,
            };
        }
        return error.WorkspaceNameExhausted;
    }

    /// Restores the previous working directory before removing the workspace.
    /// If restoration fails, the workspace is deliberately left in place so the
    /// process is never stranded inside a directory that cleanup removed.
    pub fn deinit(self: *Workspace) !void {
        defer self.* = undefined;
        defer self.allocator.free(self.abs_path);
        defer self.parent.close(self.io);
        self.root.close(self.io);

        if (self.previous_cwd) |previous_cwd| {
            defer self.allocator.free(previous_cwd);
            try std.Io.Threaded.chdir(previous_cwd);
        }
        try self.parent.deleteTree(self.io, std.fs.path.basename(self.abs_path));
    }

    /// Releases the handles and restores the prior directory, but leaves the
    /// directory on disk and hands its path to the caller, who owns the slice
    /// and the directory. Used when a validation run fails: the artifact it
    /// wrote is the only evidence of why, and `deinit` would delete it.
    pub fn abandon(self: *Workspace) ![:0]u8 {
        defer self.* = undefined;
        defer self.parent.close(self.io);
        self.root.close(self.io);

        if (self.previous_cwd) |previous_cwd| {
            defer self.allocator.free(previous_cwd);
            try std.Io.Threaded.chdir(previous_cwd);
        }
        return self.abs_path;
    }

    /// Makes this workspace current until `deinit` restores the prior directory.
    pub fn enter(self: *Workspace) !void {
        if (self.previous_cwd != null) return error.WorkspaceAlreadyEntered;

        const previous_cwd_z = try std.Io.Dir.realPathFileAlloc(
            std.Io.Dir.cwd(),
            self.io,
            ".",
            self.allocator,
        );
        defer self.allocator.free(previous_cwd_z);
        const previous_cwd = try self.allocator.dupe(u8, previous_cwd_z);
        errdefer self.allocator.free(previous_cwd);

        try std.Io.Threaded.chdir(self.abs_path);
        self.previous_cwd = previous_cwd;
    }

    /// Restores one initial fixture beneath the exclusively-created root.
    pub fn restoreFile(self: *const Workspace, relative_path: []const u8, bytes: []const u8) !void {
        if (!isSafeRelativePath(relative_path)) return error.UnsafeWorkspacePath;
        if (std.fs.path.dirname(relative_path)) |parent_path| {
            _ = try self.root.createDirPathStatus(self.io, parent_path, privateDirPermissions());
        }
        const file = try self.root.createFile(self.io, relative_path, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
    }
};

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    for (path) |byte| if (byte == 0 or byte == '\\') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return false;
        }
    }
    return true;
}

fn privateFilePermissions() std.Io.File.Permissions {
    return @enumFromInt(0o600);
}

fn privateDirPermissions() std.Io.File.Permissions {
    return @enumFromInt(0o700);
}

const testing = std.testing;

test "deinit removes the workspace and abandon leaves it for inspection" {
    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var removed = try Workspace.create(testing.allocator, io);
    const removed_path = try testing.allocator.dupeZ(u8, removed.abs_path);
    defer testing.allocator.free(removed_path);
    try removed.restoreFile("handler.ts", "export default 1;\n");
    try removed.deinit();
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, removed_path, .{ .follow_symlinks = false }),
    );

    var kept = try Workspace.create(testing.allocator, io);
    try kept.restoreFile("handler.ts", "export default 1;\n");
    const kept_path = try kept.abandon();
    defer testing.allocator.free(kept_path);
    // The directory and its contents survive, which is the whole point: a
    // failed validation leaves its evidence behind.
    const stat = try std.Io.Dir.cwd().statFile(io, kept_path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    var kept_dir = try std.Io.Dir.openDirAbsolute(io, kept_path, .{});
    defer kept_dir.close(io);
    const handler = try kept_dir.statFile(io, "handler.ts", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, handler.kind);

    var parent = try std.Io.Dir.openDirAbsolute(io, temp_root, .{});
    defer parent.close(io);
    try parent.deleteTree(io, std.fs.path.basename(kept_path));
}
