//! Crash-safe persistence for an already-collected flow cassette.
//!
//! Collection stays outside this module. Promotion writes a complete private
//! staging case, validates it with `artifact.loadCase`, moves the immutable
//! generation into place, and only then atomically replaces `case.json`.

const std = @import("std");
const artifact = @import("artifact.zig");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;

const stage_name = ".promotion-staging";
const pointer_temp_name = ".case.json.tmp";

pub const FixtureBytes = struct {
    role: artifact.FixtureRole,
    /// Generation-relative path, such as `responses/0.jsonl` or
    /// `initial/handler.ts`.
    path: []const u8,
    bytes: []const u8,
};

pub const PromotionInput = struct {
    case_root_abs: []const u8,
    manifest: *const artifact.FlowManifest,
    trace: *const artifact.InteractionTrace,
    fixtures: []const FixtureBytes,
};

const FaultPoint = enum {
    stage_write,
    stage_sync,
    generation_rename,
    generation_sync,
    pointer_write,
    pointer_rename,
    pointer_sync,
    active_revalidate,
    superseded_cleanup,
    staging_cleanup,
};

const Hooks = struct {
    fail_at: ?FaultPoint = null,

    fn reach(self: Hooks, point: FaultPoint) !void {
        if (self.fail_at == point) return error.InjectedPromotionFault;
    }
};

/// Narrow test-only surface for deterministic persistence fault injection.
pub const testing = struct {
    pub const PromotionFault = FaultPoint;

    pub fn promoteWithFault(
        allocator: std.mem.Allocator,
        input: PromotionInput,
        fault: PromotionFault,
    ) !artifact.Sha256Hex {
        return promoteWithHooks(allocator, input, .{ .fail_at = fault });
    }
};

/// Persist and activate one content-addressed generation.
///
/// `error.RecoveryRequired` means a previous attempt left private staging,
/// pointer-temporary, or destination-generation state. When an operation fails
/// after the atomic pointer swap, `error.ActivatedRecoveryRequired` reports
/// truthfully that the new generation is active but recovery work remains.
pub fn promote(allocator: std.mem.Allocator, input: PromotionInput) !artifact.Sha256Hex {
    return promoteWithHooks(allocator, input, .{});
}

fn promoteWithHooks(
    allocator: std.mem.Allocator,
    input: PromotionInput,
    hooks: Hooks,
) !artifact.Sha256Hex {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var io_backend = std.Io.Threaded.init(scratch, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    try validateCaseRoot(scratch, io, input.case_root_abs);
    var root = try std.Io.Dir.openDirAbsolute(io, input.case_root_abs, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root.close(io);
    try requireAbsent(root, io, stage_name);
    try requireAbsent(root, io, pointer_temp_name);

    const trace_bytes = try renderJson(scratch, input.trace.*);
    var prepared = try prepareManifest(scratch, input.manifest, trace_bytes, input.fixtures);
    const flow_version = try artifact.computeFlowVersion(scratch, &prepared.manifest, prepared.hash_fixtures);
    prepared.manifest.flow_version = flow_version;

    const descriptor = artifact.CaseDescriptor{
        .schema_version = artifact.schema_version,
        .case_name = prepared.manifest.case_name,
        .evidence_class = prepared.manifest.evidence_class,
        .executable = prepared.manifest.executable,
        .active_generation = flow_version,
    };
    const manifest_bytes = try renderJson(scratch, prepared.manifest);
    const descriptor_bytes = try renderJson(scratch, descriptor);

    const previous_generation = try activeGeneration(allocator, input.case_root_abs);
    if (previous_generation) |previous| {
        if (previous.eql(flow_version)) return flow_version;
    }

    try root.createDir(io, stage_name, privateDirPermissions());
    var stage = try root.openDir(io, stage_name, .{ .iterate = true, .follow_symlinks = false });
    defer stage.close(io);

    const generation_rel = try std.fmt.allocPrint(scratch, "generations/{s}", .{flow_version.slice()});
    try stage.createDirPath(io, generation_rel);
    try hooks.reach(.stage_write);
    const manifest_path = try std.fmt.allocPrint(scratch, "{s}/manifest.json", .{generation_rel});
    try writeExclusive(stage, io, manifest_path, manifest_bytes);
    const trace_path = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ generation_rel, prepared.manifest.trace.path });
    try writeExclusiveWithParents(stage, io, trace_path, trace_bytes);
    for (input.fixtures) |fixture| {
        const path = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ generation_rel, fixture.path });
        try writeExclusiveWithParents(stage, io, path, fixture.bytes);
    }
    try writeExclusive(stage, io, "case.json", descriptor_bytes);
    try hooks.reach(.stage_sync);
    try syncDirectoryTree(scratch, io, stage);

    const staged_root_abs = try std.fs.path.join(scratch, &.{ input.case_root_abs, stage_name });
    var loaded = artifact.loadCase(allocator, staged_root_abs);
    defer loaded.deinit();
    switch (loaded) {
        // The reason is printed rather than discarded. This is the recorder
        // refusing an artifact it wrote itself one statement earlier, so the
        // `Diagnostic` is the only thing that says which component and which
        // path disagreed - and the staging directory is gone by the time a
        // caller sees `InvalidArtifact`, so there is nothing left to inspect.
        .failure => |diagnostic| {
            std.debug.print(
                "[recording-storage] staged artifact did not load back: {s} in {s}, path '{s}'\n",
                .{
                    @tagName(diagnostic.kind),
                    @tagName(diagnostic.component),
                    diagnostic.path[0..diagnostic.path_len],
                },
            );
            return error.InvalidArtifact;
        },
        .available => |flow_case| if (!flow_case.flow_version.eql(flow_version)) return error.InvalidArtifact,
    }

    _ = root.createDirPathStatus(io, "generations", privateDirPermissions()) catch |err| switch (err) {
        error.PathAlreadyExists => return error.RecoveryRequired,
        else => return err,
    };
    const generations_stat = try root.statFile(io, "generations", .{ .follow_symlinks = false });
    if (generations_stat.kind != .directory) return error.RecoveryRequired;

    const staged_generation = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ stage_name, generation_rel });
    // The exclusively-created staging directory is also the promotion lock.
    // Once held, an existing destination can only be stale recovery state.
    try requireAbsent(root, io, generation_rel);
    try hooks.reach(.generation_rename);
    try root.rename(staged_generation, root, generation_rel, io);
    try hooks.reach(.generation_sync);
    try syncNamedDirectory(root, io, "generations");
    try syncDir(root);

    try hooks.reach(.pointer_write);
    try writeExclusive(root, io, pointer_temp_name, descriptor_bytes);
    try hooks.reach(.pointer_rename);
    try root.rename(pointer_temp_name, root, "case.json", io);
    hooks.reach(.pointer_sync) catch return error.ActivatedRecoveryRequired;
    syncDir(root) catch return error.ActivatedRecoveryRequired;

    hooks.reach(.active_revalidate) catch return error.ActivatedRecoveryRequired;
    requireActiveGeneration(allocator, input.case_root_abs, flow_version) catch
        return error.ActivatedRecoveryRequired;

    if (previous_generation) |previous| {
        hooks.reach(.superseded_cleanup) catch return error.ActivatedRecoveryRequired;
        const previous_rel = std.fmt.allocPrint(scratch, "generations/{s}", .{previous.slice()}) catch
            return error.ActivatedRecoveryRequired;
        root.deleteTree(io, previous_rel) catch return error.ActivatedRecoveryRequired;
        syncNamedDirectory(root, io, "generations") catch return error.ActivatedRecoveryRequired;
    }

    hooks.reach(.staging_cleanup) catch return error.ActivatedRecoveryRequired;
    root.deleteTree(io, stage_name) catch return error.ActivatedRecoveryRequired;
    syncDir(root) catch return error.ActivatedRecoveryRequired;
    return flow_version;
}

fn activeGeneration(
    allocator: std.mem.Allocator,
    case_root_abs: []const u8,
) !?artifact.Sha256Hex {
    const pointer_path = try std.fs.path.join(allocator, &.{ case_root_abs, "case.json" });
    defer allocator.free(pointer_path);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const stat = std.Io.Dir.cwd().statFile(io_backend.io(), pointer_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return error.RecoveryRequired;

    var loaded = artifact.loadCase(allocator, case_root_abs);
    defer loaded.deinit();
    return switch (loaded) {
        .available => |flow_case| flow_case.flow_version,
        .failure => error.RecoveryRequired,
    };
}

fn requireActiveGeneration(
    allocator: std.mem.Allocator,
    case_root_abs: []const u8,
    expected: artifact.Sha256Hex,
) !void {
    var loaded = artifact.loadCase(allocator, case_root_abs);
    defer loaded.deinit();
    switch (loaded) {
        .failure => return error.InvalidArtifact,
        .available => |flow_case| if (!flow_case.flow_version.eql(expected)) return error.InvalidArtifact,
    }
}

const Prepared = struct {
    manifest: artifact.FlowManifest,
    hash_fixtures: []artifact.LoadedFixture,
};

fn prepareManifest(
    allocator: std.mem.Allocator,
    source: *const artifact.FlowManifest,
    trace_bytes: []const u8,
    fixtures: []const FixtureBytes,
) !Prepared {
    if (source.schema_version != artifact.schema_version) return error.InvalidArtifact;
    if (!artifact.validCaseName(source.case_name)) return error.UnsafePath;
    if (!artifact.isSafeRelativePath(source.trace.path)) return error.UnsafePath;
    if (fixtures.len + 1 > artifact.Limits.files) return error.InvalidArtifact;

    const responses = try allocator.dupe(artifact.ResponseFixture, source.model_responses);
    const initial = try allocator.dupe(artifact.WorkspaceFixture, source.initial_workspace);
    const turn_workspaces = try allocator.dupe(artifact.TurnWorkspaceCheckpoint, source.turn_workspaces);
    for (turn_workspaces) |*checkpoint| {
        checkpoint.files = try allocator.dupe(artifact.WorkspaceFixture, checkpoint.files);
    }
    const expected = try allocator.dupe(artifact.WorkspaceFixture, source.expected_workspace);
    const used = try allocator.alloc(bool, fixtures.len);
    @memset(used, false);

    for (fixtures, 0..) |fixture, i| {
        if (fixture.role == .trace or !artifact.isSafeRelativePath(fixture.path)) return error.UnsafePath;
        for (fixtures[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, fixture.path)) return error.InvalidArtifact;
        }
    }

    for (responses) |*response| {
        response.sha256 = try digestFixture(fixtures, used, .response, response.path);
    }
    for (initial) |*workspace_file| {
        const path = try std.fmt.allocPrint(allocator, "initial/{s}", .{workspace_file.path});
        workspace_file.sha256 = try digestFixture(fixtures, used, .initial_workspace, path);
    }
    for (turn_workspaces) |*checkpoint| {
        for (@constCast(checkpoint.files)) |*workspace_file| {
            const path = try std.fmt.allocPrint(
                allocator,
                "turns/{d}/{s}",
                .{ checkpoint.turn_index, workspace_file.path },
            );
            workspace_file.sha256 = try digestFixture(fixtures, used, .turn_workspace, path);
        }
    }
    for (expected) |*workspace_file| {
        const path = try std.fmt.allocPrint(allocator, "expected/{s}", .{workspace_file.path});
        workspace_file.sha256 = try digestFixture(fixtures, used, .expected_workspace, path);
    }
    for (used) |was_used| if (!was_used) return error.InvalidArtifact;

    var manifest = source.*;
    manifest.flow_version = .{ .bytes = [_]u8{'0'} ** 64 };
    manifest.model_responses = responses;
    manifest.initial_workspace = initial;
    manifest.turn_workspaces = turn_workspaces;
    manifest.expected_workspace = expected;
    manifest.trace.sha256 = artifact.Sha256Hex.fromBytes(trace_bytes);

    const hash_fixtures = try allocator.alloc(artifact.LoadedFixture, fixtures.len + 1);
    hash_fixtures[0] = .{ .role = .trace, .path = manifest.trace.path, .bytes = trace_bytes };
    for (fixtures, 1..) |fixture, i| {
        hash_fixtures[i] = .{ .role = fixture.role, .path = fixture.path, .bytes = fixture.bytes };
    }
    return .{ .manifest = manifest, .hash_fixtures = hash_fixtures };
}

fn digestFixture(
    fixtures: []const FixtureBytes,
    used: []bool,
    role: artifact.FixtureRole,
    path: []const u8,
) !artifact.Sha256Hex {
    if (!artifact.isSafeRelativePath(path)) return error.UnsafePath;
    var match: ?usize = null;
    for (fixtures, 0..) |fixture, i| {
        if (fixture.role == role and std.mem.eql(u8, fixture.path, path)) {
            if (match != null) return error.InvalidArtifact;
            match = i;
        }
    }
    const index = match orelse return error.InvalidArtifact;
    used[index] = true;
    return artifact.Sha256Hex.fromBytes(fixtures[index].bytes);
}

fn renderJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, out.writer());
    return out.toOwnedSlice();
}

fn validateCaseRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.UnsafePath;
    const normalized = try std.fs.path.resolve(allocator, &.{path});
    if (!std.mem.eql(u8, normalized, path)) return error.UnsafePath;

    var end: usize = 1;
    while (end < path.len) {
        end = std.mem.findScalarPos(u8, path, end, '/') orelse path.len;
        const prefix = path[0..end];
        const stat = std.Io.Dir.cwd().statFile(io, prefix, .{ .follow_symlinks = false }) catch return error.UnsafePath;
        if (stat.kind == .sym_link or stat.kind != .directory) return error.UnsafePath;
        end += 1;
    }
}

fn requireAbsent(dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.RecoveryRequired;
}

fn writeExclusiveWithParents(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try writeExclusive(dir, io, path, bytes);
}

fn writeExclusive(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, path, .{
        .exclusive = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn syncDirectoryTree(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !void {
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var dir = try root.openDir(io, entry.path, .{ .follow_symlinks = false });
        defer dir.close(io);
        try syncDir(dir);
    }
    try syncDir(root);
}

fn syncNamedDirectory(root: std.Io.Dir, io: std.Io, path: []const u8) !void {
    var dir = try root.openDir(io, path, .{ .follow_symlinks = false });
    defer dir.close(io);
    try syncDir(dir);
}

fn syncDir(dir: std.Io.Dir) !void {
    if (std.c.fsync(dir.handle) != 0) return error.DirectorySyncFailed;
}

fn privateFilePermissions() std.Io.File.Permissions {
    return @enumFromInt(0o600);
}

fn privateDirPermissions() std.Io.File.Permissions {
    return @enumFromInt(0o700);
}
