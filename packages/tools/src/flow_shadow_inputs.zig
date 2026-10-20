//! Inputs for the explicit P9 evidence modes. No corpus or golden is rewritten.
const std = @import("std");
const zts = @import("zts");
pub const census = @import("flow_census_probes.zig");

pub const Selection = struct {
    census: bool = false,
    diagnostic_corpus: bool = false,
    codegen: bool = false,
};

pub const Case = struct { group: []const u8, name: []const u8, path: []const u8 };
pub const Input = struct {
    case: Case,
    source: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    allow_preflow_block: bool = false,
    probe: ?census.Probe = null,
};
pub const Workspace = struct {
    descriptor: []const u8,
    generation: []const u8,
    case_name: []const u8,
    handler_present: bool,
};
pub const Loaded = struct {
    inputs: std.ArrayList(Input) = .empty,
    workspaces: std.ArrayList(Workspace) = .empty,
    census_groups: [3]usize = @splat(0),
    census_columns: [census.column_count]usize = @splat(0),
    diagnostic_families: [4]usize = @splat(0),
    descriptors: [2]usize = @splat(0),
    codegen_handlers: usize = 0,
    codegen_without_handler: usize = 0,

    pub fn checkFloors(self: Loaded, selected: Selection) !void {
        if (selected.census) {
            if (!std.mem.eql(usize, &self.census_groups, &.{ 504, 206, 24 })) return error.CensusFloorChanged;
            for (self.census_columns[0..census.hand_column]) |count| if (count < census.minimum_per_column) return error.CensusColumnMissing;
        }
        if (selected.diagnostic_corpus) {
            var total: usize = 0;
            for (self.diagnostic_families) |count| {
                if (count == 0) return error.DiagnosticFamilyMissing;
                total += count;
            }
            if (total != 182) return error.DiagnosticFloorChanged;
        }
        if (selected.codegen and (!std.mem.eql(usize, &self.descriptors, &.{ 13, 16 }) or self.codegen_handlers != 18 or self.codegen_without_handler != 11)) return error.CodegenFloorChanged;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sources(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, suffix: []const u8) ![][]const u8 {
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.path, suffix)) {
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    };
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return paths.toOwnedSlice(allocator);
}

fn readInput(allocator: std.mem.Allocator, input: *Input, path: []const u8) void {
    input.source = zts.file_io.readFile(allocator, path, 1024 * 1024) catch |err| {
        input.error_name = @errorName(err);
        return;
    };
}

fn relative(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.findScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

const Descriptor = struct { case_name: []const u8, active_generation: []const u8 };
const File = struct { path: []const u8, sha256: []const u8 };
const Manifest = struct { case_name: []const u8, flow_version: []const u8, expected_workspace: []const File };

fn codegenWorkspace(allocator: std.mem.Allocator, loaded: *Loaded, case_path: []const u8, descriptor_path: []const u8) !void {
    const descriptor_bytes = try zts.file_io.readFile(allocator, descriptor_path, 1024 * 1024);
    const descriptor = try std.json.parseFromSlice(Descriptor, allocator, descriptor_bytes, .{ .ignore_unknown_fields = true });
    const active = descriptor.value.active_generation;
    if (active.len != 64) return error.InvalidGeneration;
    for (active) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidGeneration;
    const generation = try std.fs.path.join(allocator, &.{ case_path, "generations", active });
    const manifest_path = try std.fs.path.join(allocator, &.{ generation, "manifest.json" });
    const manifest_bytes = try zts.file_io.readFile(allocator, manifest_path, 1024 * 1024);
    const manifest = (try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = true })).value;
    if (!std.mem.eql(u8, active, manifest.flow_version) or !std.mem.eql(u8, descriptor.value.case_name, manifest.case_name)) return error.GenerationIdentityMismatch;
    var handler: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var schema: ?[]const u8 = null;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (manifest.expected_workspace) |file| {
        if (!relative(file.path)) return error.UnsafeWorkspacePath;
        const prior = try seen.getOrPut(allocator, file.path);
        if (prior.found_existing) return error.DuplicateWorkspacePath;
        const path = try std.fs.path.join(allocator, &.{ generation, "expected", file.path });
        const bytes = try zts.file_io.readFile(allocator, path, 8 * 1024 * 1024);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), file.sha256)) return error.WorkspaceDigestMismatch;
        if (std.mem.eql(u8, file.path, "handler.ts")) {
            handler = path;
            source = bytes;
        }
        if (std.mem.eql(u8, file.path, "schema.sql")) schema = path;
    }
    try loaded.workspaces.append(allocator, .{ .descriptor = descriptor_path, .generation = active, .case_name = manifest.case_name, .handler_present = handler != null });
    if (handler) |path| {
        loaded.codegen_handlers += 1;
        try loaded.inputs.append(allocator, .{ .case = .{ .group = "codegen", .name = descriptor_path, .path = path }, .source = source, .schema = schema, .allow_preflow_block = true });
    } else loaded.codegen_without_handler += 1;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, scratch: []const u8, selected: Selection) !Loaded {
    var loaded: Loaded = .{};
    if (selected.census) {
        for (try census.generate(allocator)) |probe| {
            loaded.census_groups[@intFromEnum(probe.group)] += 1;
            loaded.census_columns[census.columnOf(probe)] += 1;
            const directory = try std.fs.path.join(allocator, &.{ scratch, probe.name });
            try std.Io.Dir.cwd().createDirPath(io, directory);
            for (probe.files) |file| {
                const path = try std.fs.path.join(allocator, &.{ directory, file.name });
                if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.text });
            }
            try loaded.inputs.append(allocator, .{ .case = .{ .group = "census", .name = probe.name, .path = try std.fs.path.join(allocator, &.{ directory, probe.files[0].name }) }, .source = probe.files[0].text, .probe = probe });
        }
    }
    if (selected.diagnostic_corpus) {
        for (try sources(allocator, io, "tests/corpus", ".ts")) |path| {
            var parts = std.mem.splitScalar(u8, path, '/');
            const family = parts.next() orelse return error.InvalidDiagnosticLayout;
            const kind = parts.next() orelse return error.InvalidDiagnosticLayout;
            _ = parts.next() orelse return error.InvalidDiagnosticLayout;
            if (parts.next() != null) return error.InvalidDiagnosticLayout;
            const family_id: usize = if (std.mem.eql(u8, family, "parse")) 0 else if (std.mem.eql(u8, family, "check")) 2 else return error.InvalidDiagnosticLayout;
            const kind_id: usize = if (std.mem.eql(u8, kind, "good")) 0 else if (std.mem.eql(u8, kind, "bad")) 1 else return error.InvalidDiagnosticLayout;
            loaded.diagnostic_families[family_id + kind_id] += 1;
            // The golden gate passes the path relative to tests/corpus to
            // CHECK. Match that path and its diagnostic file identity exactly.
            var input: Input = .{ .case = .{ .group = "diagnostic", .name = path, .path = path }, .allow_preflow_block = true };
            readInput(allocator, &input, try std.fs.path.join(allocator, &.{ "tests/corpus", path }));
            try loaded.inputs.append(allocator, input);
        }
    }
    if (selected.codegen) {
        const roots = [_][]const u8{ "packages/pi/src/simulator/testdata/empirical/deepseek/codegen", "packages/pi/src/simulator/testdata/empirical/local/codegen" };
        for (roots, 0..) |root, provider| for (try sources(allocator, io, root, "case.json")) |path| {
            if (!std.mem.eql(u8, std.fs.path.basename(path), "case.json")) continue;
            loaded.descriptors[provider] += 1;
            const descriptor_path = try std.fs.path.join(allocator, &.{ root, path });
            const case_path = std.fs.path.dirname(descriptor_path) orelse return error.InvalidCasePath;
            codegenWorkspace(allocator, &loaded, case_path, descriptor_path) catch |err| {
                try loaded.inputs.append(allocator, .{ .case = .{ .group = "codegen", .name = descriptor_path, .path = descriptor_path }, .error_name = @errorName(err) });
            };
        };
    }
    return loaded;
}

test "shadow input paths preserve relative workspace boundaries" {
    try std.testing.expect(relative("lib/settings.ts"));
    for ([_][]const u8{ "", "/tmp/handler.ts", "../handler.ts", "lib/../handler.ts", "lib//handler.ts", "lib\\handler.ts" }) |path| try std.testing.expect(!relative(path));
}

test "default shadow mode leaves extended corpora unopened" {
    const loaded = try load(std.testing.allocator, std.testing.io, "unused", .{});
    try std.testing.expectEqual(@as(usize, 0), loaded.inputs.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.workspaces.items.len);
    try loaded.checkFloors(.{});
}

test "extended floors require every selected input family" {
    var loaded: Loaded = .{ .census_groups = .{ 504, 206, 24 }, .census_columns = @splat(18), .diagnostic_families = .{ 1, 1, 1, 179 }, .descriptors = .{ 13, 16 }, .codegen_handlers = 18, .codegen_without_handler = 11 };
    const all: Selection = .{ .census = true, .diagnostic_corpus = true, .codegen = true };
    try loaded.checkFloors(all);
    loaded.codegen_without_handler -= 1;
    try std.testing.expectError(error.CodegenFloorChanged, loaded.checkFloors(all));
    loaded.codegen_without_handler += 1;
    loaded.descriptors[0] -= 1;
    try std.testing.expectError(error.CodegenFloorChanged, loaded.checkFloors(all));
    loaded.descriptors[0] += 1;
    loaded.census_groups[0] -= 1;
    try std.testing.expectError(error.CensusFloorChanged, loaded.checkFloors(all));
    loaded.census_groups[0] += 1;
    loaded.census_columns[0] = 0;
    try std.testing.expectError(error.CensusColumnMissing, loaded.checkFloors(all));
    loaded.census_columns[0] = 18;
    loaded.diagnostic_families[0] = 0;
    try std.testing.expectError(error.DiagnosticFamilyMissing, loaded.checkFloors(all));
    loaded.diagnostic_families[0] = 1;
    loaded.diagnostic_families[3] -= 1;
    try std.testing.expectError(error.DiagnosticFloorChanged, loaded.checkFloors(all));
}
