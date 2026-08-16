//! Immutable proof snapshot and conservative proof read set.
//!
//! The compiler still uses filesystem-backed readers. We therefore capture
//! every source and configuration input under the selected project once, bind
//! those exact bytes into a read set, and materialize baseline and aggregate
//! candidate trees from the same capture. No live source file is changed.

const std = @import("std");
const zts = @import("zts");
const project_config = @import("project_config");
const change_set = @import("change_set.zig");
const common = @import("tools/common.zig");

pub const max_read_entries: usize = 4096;
pub const max_read_file_bytes: usize = 32 * 1024 * 1024;
pub const max_read_set_bytes: usize = 128 * 1024 * 1024;
var scratch_counter = std.atomic.Value(u64).init(0);

pub const ReadState = union(enum) {
    absent,
    present: []u8,

    pub fn bytes(self: ReadState) ?[]const u8 {
        return switch (self) {
            .absent => null,
            .present => |value| value,
        };
    }

    fn deinit(self: *ReadState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .absent => {},
            .present => |value| allocator.free(value),
        }
        self.* = .absent;
    }
};

pub const ReadEntry = struct {
    absolute_path: []u8,
    relative_path: []u8,
    state: ReadState,
    sha256: [32]u8,

    fn deinit(self: *ReadEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.absolute_path);
        allocator.free(self.relative_path);
        self.state.deinit(allocator);
        self.* = undefined;
    }
};

pub const Materialized = struct {
    allocator: std.mem.Allocator,
    scratch_name: []u8,
    root: []u8,

    pub fn deinit(self: *Materialized) void {
        var io_backend = std.Io.Threaded.init(self.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        if (std.Io.Dir.openDirAbsolute(io_backend.io(), "/tmp", .{})) |tmp_dir_value| {
            var tmp_dir = tmp_dir_value;
            defer tmp_dir.close(io_backend.io());
            tmp_dir.deleteTree(io_backend.io(), self.scratch_name) catch {};
        } else |_| {}
        self.allocator.free(self.scratch_name);
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn pathFor(self: *const Materialized, allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
        return std.fs.path.resolve(allocator, &.{ self.root, relative_path });
    }
};

pub const Snapshot = struct {
    project_root: []u8,
    entries: []ReadEntry,

    pub fn capture(allocator: std.mem.Allocator, prepared: *const change_set.PreparedChangeSet) !Snapshot {
        var entries: std.ArrayList(ReadEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        var total_bytes: usize = 0;
        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        try collectInputs(
            allocator,
            io_backend.io(),
            prepared.project_root,
            prepared.project_root,
            &entries,
            &total_bytes,
        );

        for (prepared.changes) |change| {
            if (!containsAbsolute(entries.items, change.resolved_path)) {
                const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
                try appendAbsent(allocator, &entries, change.resolved_path, relative);
            }
            try captureDiscoveryAbsences(allocator, &entries, prepared.project_root, change.resolved_path);
        }
        try captureNamedAbsence(allocator, &entries, prepared.project_root, "system.json");
        try captureNamedAbsence(allocator, &entries, prepared.project_root, "zttp.json");
        try captureConfiguredInputs(
            allocator,
            io_backend.io(),
            &entries,
            prepared.project_root,
            &total_bytes,
        );

        std.mem.sort(ReadEntry, entries.items, {}, struct {
            fn lessThan(_: void, left: ReadEntry, right: ReadEntry) bool {
                return std.mem.lessThan(u8, left.relative_path, right.relative_path);
            }
        }.lessThan);

        return .{
            .project_root = try allocator.dupe(u8, prepared.project_root),
            .entries = try entries.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        allocator.free(self.project_root);
        self.* = undefined;
    }

    pub fn materializeBaseline(self: *const Snapshot, allocator: std.mem.Allocator) !Materialized {
        return self.materialize(allocator, null);
    }

    pub fn materializeCandidate(
        self: *const Snapshot,
        allocator: std.mem.Allocator,
        prepared: *const change_set.PreparedChangeSet,
    ) !Materialized {
        return self.materialize(allocator, prepared);
    }

    fn materialize(
        self: *const Snapshot,
        allocator: std.mem.Allocator,
        overlay: ?*const change_set.PreparedChangeSet,
    ) !Materialized {
        var now: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(@enumFromInt(@intFromEnum(std.posix.CLOCK.REALTIME)), &now);
        const sequence = scratch_counter.fetchAdd(1, .seq_cst);
        const name = try std.fmt.allocPrint(
            allocator,
            "zttp-proof-{d}-{d}-{d}",
            .{ @as(u64, @intCast(now.sec)), @as(u64, @intCast(now.nsec)), sequence },
        );
        errdefer allocator.free(name);
        const root = try std.fs.path.resolve(allocator, &.{ "/tmp", name });
        errdefer allocator.free(root);

        var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        const io = io_backend.io();
        var tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
        defer tmp_dir.close(io);
        try std.Io.Dir.createDirPath(tmp_dir, io, name);
        errdefer tmp_dir.deleteTree(io, name) catch {};

        for (self.entries) |entry| {
            const bytes = entry.state.bytes() orelse continue;
            const target = try std.fs.path.resolve(allocator, &.{ root, entry.relative_path });
            defer allocator.free(target);
            try writeOwnedFile(allocator, io, target, bytes);
        }
        if (overlay) |prepared| {
            for (prepared.changes) |change| {
                const relative = common.relativeToRoot(prepared.project_root, change.resolved_path);
                const target = try std.fs.path.resolve(allocator, &.{ root, relative });
                defer allocator.free(target);
                try writeOwnedFile(allocator, io, target, change.candidate);
            }
        }
        return .{ .allocator = allocator, .scratch_name = name, .root = root };
    }

    pub fn recheck(self: *const Snapshot, allocator: std.mem.Allocator) !void {
        for (self.entries) |entry| {
            const resolved = common.resolveInsideWorkspace(allocator, self.project_root, entry.relative_path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.ProofReadSetChanged,
            };
            defer allocator.free(resolved);
            if (!std.mem.eql(u8, resolved, entry.absolute_path)) return error.ProofReadSetChanged;
            const current = zts.file_io.readFile(allocator, entry.absolute_path, max_read_file_bytes) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            defer if (current) |bytes| allocator.free(bytes);
            const digest = digestReadState(current);
            if (!std.mem.eql(u8, &digest, &entry.sha256)) return error.ProofReadSetChanged;
        }
    }
};

fn collectInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    directory: []const u8,
    entries: *std.ArrayList(ReadEntry),
    total_bytes: *usize,
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (isExcludedName(entry.name)) continue;
        const absolute = try std.fs.path.resolve(allocator, &.{ directory, entry.name });
        defer allocator.free(absolute);
        switch (entry.kind) {
            .directory => try collectInputs(allocator, io, project_root, absolute, entries, total_bytes),
            .file => {
                if (!isProofInput(entry.name)) continue;
                if (entries.items.len >= max_read_entries) return error.ProofReadSetTooLarge;
                const bytes = try zts.file_io.readFile(allocator, absolute, max_read_file_bytes);
                errdefer allocator.free(bytes);
                total_bytes.* = std.math.add(usize, total_bytes.*, bytes.len) catch
                    return error.ProofReadSetTooLarge;
                if (total_bytes.* > max_read_set_bytes) return error.ProofReadSetTooLarge;
                const relative = common.relativeToRoot(project_root, absolute);
                try entries.append(allocator, .{
                    .absolute_path = try allocator.dupe(u8, absolute),
                    .relative_path = try allocator.dupe(u8, relative),
                    .state = .{ .present = bytes },
                    .sha256 = digestReadState(bytes),
                });
            },
            .sym_link => {
                if (isProofInput(entry.name)) return error.SymlinkProofInputUnsupported;
            },
            else => {},
        }
    }
}

fn isExcludedName(name: []const u8) bool {
    const excluded = [_][]const u8{ ".git", ".zttp", ".zig-cache", "zig-out", "node_modules", "dist", "coverage" };
    for (excluded) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

fn isProofInput(name: []const u8) bool {
    const extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".json", ".sql", ".sqlite", ".sqlite3", ".db" };
    for (extensions) |extension| if (std.mem.endsWith(u8, name, extension)) return true;
    return false;
}

fn containsAbsolute(entries: []const ReadEntry, absolute: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.absolute_path, absolute)) return true;
    return false;
}

fn appendAbsent(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ReadEntry),
    absolute: []const u8,
    relative: []const u8,
) !void {
    if (containsAbsolute(entries.items, absolute)) return;
    if (entries.items.len >= max_read_entries) return error.ProofReadSetTooLarge;
    try entries.append(allocator, .{
        .absolute_path = try allocator.dupe(u8, absolute),
        .relative_path = try allocator.dupe(u8, relative),
        .state = .absent,
        .sha256 = digestReadState(null),
    });
}

fn captureDiscoveryAbsences(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ReadEntry),
    project_root: []const u8,
    target: []const u8,
) !void {
    var current = std.fs.path.dirname(target) orelse return;
    while (common.isPathInsideRoot(project_root, current)) {
        const candidate = try std.fs.path.resolve(allocator, &.{ current, "zttp.json" });
        defer allocator.free(candidate);
        const relative = common.relativeToRoot(project_root, candidate);
        try captureAbsentIfMissing(allocator, entries, candidate, relative);
        if (std.mem.eql(u8, current, project_root)) break;
        current = std.fs.path.dirname(current) orelse break;
    }
}

fn captureNamedAbsence(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ReadEntry),
    root: []const u8,
    name: []const u8,
) !void {
    const absolute = try std.fs.path.resolve(allocator, &.{ root, name });
    defer allocator.free(absolute);
    try captureAbsentIfMissing(allocator, entries, absolute, name);
}

fn captureConfiguredInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: *std.ArrayList(ReadEntry),
    project_root: []const u8,
    total_bytes: *usize,
) !void {
    const manifest_path = try std.fs.path.resolve(allocator, &.{ project_root, "zttp.json" });
    defer allocator.free(manifest_path);
    const manifest_stat = std.Io.Dir.cwd().statFile(io, manifest_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (manifest_stat.kind != .file) return error.InvalidProjectManifest;

    var config = try project_config.loadAbsolute(allocator, io, manifest_path);
    defer config.deinit(allocator);
    const entry_path = try config.resolvedEntry(allocator);
    defer allocator.free(entry_path);
    try captureConfiguredPath(allocator, io, entries, project_root, entry_path, total_bytes);
    if (try config.resolvedSqlitePath(allocator)) |path| {
        defer allocator.free(path);
        try captureConfiguredPath(allocator, io, entries, project_root, path, total_bytes);
    }
    if (try config.resolvedSystemPath(allocator)) |path| {
        defer allocator.free(path);
        try captureConfiguredPath(allocator, io, entries, project_root, path, total_bytes);
    }
}

fn captureConfiguredPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: *std.ArrayList(ReadEntry),
    project_root: []const u8,
    absolute: []const u8,
    total_bytes: *usize,
) !void {
    if (!common.isPathInsideRoot(project_root, absolute)) return error.ProofContextOutsideProject;
    if (containsAbsolute(entries.items, absolute)) return;
    const relative = common.relativeToRoot(project_root, absolute);
    const stat = std.Io.Dir.cwd().statFile(io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return appendAbsent(allocator, entries, absolute, relative),
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkProofInputUnsupported;
    if (stat.kind != .file) return error.NonRegularProofInput;
    if (entries.items.len >= max_read_entries) return error.ProofReadSetTooLarge;
    const bytes = try zts.file_io.readFile(allocator, absolute, max_read_file_bytes);
    errdefer allocator.free(bytes);
    total_bytes.* = std.math.add(usize, total_bytes.*, bytes.len) catch return error.ProofReadSetTooLarge;
    if (total_bytes.* > max_read_set_bytes) return error.ProofReadSetTooLarge;
    const owned_absolute = try allocator.dupe(u8, absolute);
    errdefer allocator.free(owned_absolute);
    const owned_relative = try allocator.dupe(u8, relative);
    errdefer allocator.free(owned_relative);
    try entries.append(allocator, .{
        .absolute_path = owned_absolute,
        .relative_path = owned_relative,
        .state = .{ .present = bytes },
        .sha256 = digestReadState(bytes),
    });
}

fn captureAbsentIfMissing(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ReadEntry),
    absolute: []const u8,
    relative: []const u8,
) !void {
    if (containsAbsolute(entries.items, absolute)) return;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    _ = std.Io.Dir.cwd().statFile(io_backend.io(), absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return appendAbsent(allocator, entries, absolute, relative),
        else => return err,
    };
}

fn writeOwnedFile(allocator: std.mem.Allocator, io: std.Io, target: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(target) orelse return error.InvalidSnapshotPath;
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, parent);
    try zts.file_io.writeFile(allocator, target, bytes);
}

pub fn digestReadState(bytes: ?[]const u8) [32]u8 {
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

test "snapshot materializes one baseline and aggregate candidate overlay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old-a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/helper.ts", .data = "old-helper" });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    const tail = [_]@import("turn.zig").Change{.{ .file = "src/new.tsx", .content = "new-file" }};
    var prepared = try change_set.prepare(testing.allocator, root, .{
        .file = "src/a.ts",
        .content = "new-a",
        .additional = &tail,
    });
    defer prepared.deinit(testing.allocator);
    var snapshot = try Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    var baseline = try snapshot.materializeBaseline(testing.allocator);
    defer baseline.deinit();
    var candidate = try snapshot.materializeCandidate(testing.allocator, &prepared);
    defer candidate.deinit();

    const baseline_a = try baseline.pathFor(testing.allocator, "src/a.ts");
    defer testing.allocator.free(baseline_a);
    const candidate_a = try candidate.pathFor(testing.allocator, "src/a.ts");
    defer testing.allocator.free(candidate_a);
    const candidate_new = try candidate.pathFor(testing.allocator, "src/new.tsx");
    defer testing.allocator.free(candidate_new);
    const before = try zts.file_io.readFile(testing.allocator, baseline_a, 64);
    defer testing.allocator.free(before);
    const after = try zts.file_io.readFile(testing.allocator, candidate_a, 64);
    defer testing.allocator.free(after);
    const added = try zts.file_io.readFile(testing.allocator, candidate_new, 64);
    defer testing.allocator.free(added);
    try testing.expectEqualStrings("old-a", before);
    try testing.expectEqualStrings("new-a", after);
    try testing.expectEqualStrings("new-file", added);
}

test "snapshot recheck detects changed and newly created proof inputs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{ .file = "src/a.ts", .content = "new" });
    defer prepared.deinit(testing.allocator);
    var snapshot = try Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);
    try snapshot.recheck(testing.allocator);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "concurrent" });
    try testing.expectError(error.ProofReadSetChanged, snapshot.recheck(testing.allocator));
}

test "snapshot captures configured proof inputs regardless of extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "old" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "schema.custom", .data = "exact-schema" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handlers.custom", .data = "{\"handlers\":[]}" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/a.ts\",\"sqlite\":\"schema.custom\",\"system\":\"handlers.custom\"}",
    });
    const root_z = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_z);
    const root = try testing.allocator.dupe(u8, root_z);
    defer testing.allocator.free(root);
    var prepared = try change_set.prepare(testing.allocator, root, .{ .file = "src/a.ts", .content = "new" });
    defer prepared.deinit(testing.allocator);
    var snapshot = try Snapshot.capture(testing.allocator, &prepared);
    defer snapshot.deinit(testing.allocator);

    var saw_schema = false;
    var saw_system = false;
    for (snapshot.entries) |entry| {
        if (std.mem.eql(u8, entry.relative_path, "schema.custom")) saw_schema = entry.state == .present;
        if (std.mem.eql(u8, entry.relative_path, "handlers.custom")) saw_system = entry.state == .present;
    }
    try testing.expect(saw_schema);
    try testing.expect(saw_system);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "schema.custom", .data = "changed-schema" });
    try testing.expectError(error.ProofReadSetChanged, snapshot.recheck(testing.allocator));
}
