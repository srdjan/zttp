//! Writes the `requiredProperties` key of `zttp.json` for the `/contract` command.
//!
//! The file is parsed as a raw JSON object and only that key changes. Every
//! other key keeps its value and its place, including keys this build does not
//! know. The read, the edit, and the write all happen under the workspace lock
//! after recovery, so no change set commits at the same time and no edit works
//! from a stale list. `file_io.writeFile` writes a temporary file in the same
//! directory and renames it over the target with mode 0600. The writer first
//! resolves `zttp.json` to its real path, so a symlink stays a symlink and its
//! target changes, and it gives the rewritten file the mode of the old file.

const std = @import("std");
const zts = @import("zts");
const change_transaction = @import("change_transaction.zig");

pub const manifest_name = "zttp.json";
pub const key = "requiredProperties";

const max_manifest_bytes = 1024 * 1024;

pub const Edit = union(enum) {
    /// Append each name that is not listed yet. A listed name keeps its place.
    add: []const []const u8,
    /// Remove one name.
    drop: []const u8,
};

pub const Edited = struct {
    /// The names that `requiredProperties` holds after the edit, in file order. Owned.
    names: [][]u8,
    /// False when the edit changed nothing, so the file was not written.
    changed: bool,

    pub fn deinit(self: *Edited, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
        self.* = undefined;
    }
};

/// Apply `edit` to `requiredProperties` in the `zttp.json` of `workspace_root`.
/// An existing key keeps its place. A new key goes at the end.
///
/// `error.WorkspaceChangeSetActive` means another holder has the workspace
/// lock. `error.ManifestInvalid` means `zttp.json` is not a JSON object.
/// `error.ManifestDuplicateKey` means a key occurs twice in it.
/// `error.RequiredPropertiesInvalid` means its `requiredProperties` is not an
/// array of strings. In every case the file stays as it was.
pub fn editRequiredProperties(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    edit: Edit,
) !Edited {
    var workspace = try change_transaction.RecoveredWorkspace.acquire(allocator, workspace_root);
    defer workspace.deinit();

    const link_path = try std.fs.path.join(allocator, &.{ workspace.root(), manifest_name });
    defer allocator.free(link_path);
    const manifest_path = try realPath(allocator, link_path);
    defer allocator.free(manifest_path);
    const bytes = try zts.file_io.readFile(allocator, manifest_path, max_manifest_bytes);
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.DuplicateField => return error.ManifestDuplicateKey,
        else => return error.ManifestInvalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.ManifestInvalid;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (parsed.value.object.get(key)) |current| {
        if (current != .array) return error.RequiredPropertiesInvalid;
        for (current.array.items) |item| {
            if (item != .string) return error.RequiredPropertiesInvalid;
            try names.append(allocator, item.string);
        }
    }

    const changed = try apply(allocator, &names, edit);
    if (changed) {
        const arena = parsed.arena.allocator();
        var list = std.json.Array.init(arena);
        for (names.items) |name| try list.append(.{ .string = name });
        try parsed.value.object.put(arena, key, .{ .array = list });

        const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(rendered);
        const text = try std.mem.concat(allocator, u8, &.{ rendered, "\n" });
        defer allocator.free(text);
        const mode = try modeOf(allocator, manifest_path);
        try zts.file_io.writeFile(allocator, manifest_path, text);
        const path_z = try allocator.dupeSentinel(u8, manifest_path, 0);
        defer allocator.free(path_z);
        if (std.c.chmod(path_z, @intCast(mode & 0o7777)) != 0) return error.WriteFailure;
    }
    return .{ .names = try dupeNames(allocator, names.items), .changed = changed };
}

/// The path of `path` with every symlink resolved.
fn realPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    var resolved: [std.c.PATH_MAX + 1]u8 = undefined;
    const found = std.c.realpath(path_z, &resolved) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(found));
}

/// The permission bits of the file at `path`.
fn modeOf(allocator: std.mem.Allocator, path: []const u8) !u32 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer std.Io.Threaded.closeFd(fd);
    return (try zts.file_io.fstatFd(fd)).mode;
}

/// Edit `names` in place and report whether it changed.
fn apply(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), edit: Edit) !bool {
    var changed = false;
    switch (edit) {
        .add => |added| for (added) |name| {
            if (contains(names.items, name)) continue;
            try names.append(allocator, name);
            changed = true;
        },
        .drop => |name| {
            var index: usize = 0;
            while (index < names.items.len) {
                if (!std.mem.eql(u8, names.items[index], name)) {
                    index += 1;
                    continue;
                }
                _ = names.orderedRemove(index);
                changed = true;
            }
        },
    }
    return changed;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |listed| if (std.mem.eql(u8, listed, name)) return true;
    return false;
}

fn dupeNames(allocator: std.mem.Allocator, names: []const []const u8) ![][]u8 {
    const copy = try allocator.alloc([]u8, names.len);
    var done: usize = 0;
    errdefer {
        for (copy[0..done]) |name| allocator.free(name);
        allocator.free(copy);
    }
    for (names, 0..) |name, index| {
        copy[index] = try allocator.dupe(u8, name);
        done = index + 1;
    }
    return copy;
}
