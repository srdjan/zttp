//! Native ZTS import graph report and tier-layering gate.
//!
//! The command reads tracked and untracked nonignored paths through Git. It reads the five
//! build module names and roots from `build/packages.zig` during each run.

const std = @import("std");

const prefix = "packages/zts/src/";
const manifest_path = "scripts/zts-tiers.allow";
const build_path = "build/packages.zig";
const min_files = 100;
const min_edges = 400;
const min_named_edges = 50;

const tier_names = [_][]const u8{
    "zts-base",
    "zts-contracts",
    "zts",
    "zts-compiler",
    "zts-umbrella",
};
const tier_count = tier_names.len;

// Phase 3 removes the optional source frontend and compile-time evaluator.
// The report keeps the surviving engine entry points and report shape.
const engine_roots = [_][]const u8{
    "context.zig",
    "interpreter.zig",
    "pool.zig",
    "builtins/root.zig",
    "parser/root.zig",
    "http.zig",
    "source_frontend.zig",
    "modules/root.zig",
    "bytecode_cache.zig",
};

const BuildRoot = struct {
    module_name: []const u8,
    source_root: []const u8,
};

const File = struct {
    path: []const u8,
    tier: ?u8 = null,
    edges: std.ArrayListUnmanaged(usize) = .empty,
    named_tiers: std.ArrayListUnmanaged(u8) = .empty,
    unresolved: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *File, allocator: std.mem.Allocator) void {
        self.edges.deinit(allocator);
        self.named_tiers.deinit(allocator);
        for (self.unresolved.items) |spec| allocator.free(spec);
        self.unresolved.deinit(allocator);
    }
};

const Graph = struct {
    files: []File,
    listing: []u8,

    fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        allocator.free(self.listing);
        self.* = undefined;
    }
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn deriveBuildRoots(source: []const u8) ![tier_count]BuildRoot {
    const table_marker = "const zts_roots";
    const table_start = std.mem.find(u8, source, table_marker) orelse
        return error.MissingRootsTable;
    const table_tail = source[table_start..];
    const table_end_offset = std.mem.find(u8, table_tail, "\n    };") orelse
        return error.InvalidRootsTable;
    const table = table_tail[0..table_end_offset];
    var roots: [tier_count]BuildRoot = undefined;
    var cursor: usize = 0;
    for (&roots) |*root| {
        const name_marker = ".name = \"";
        const name_at_rel = std.mem.find(u8, table[cursor..], name_marker) orelse
            return error.InvalidRootsTable;
        const name_start = cursor + name_at_rel + name_marker.len;
        const name_end_rel = std.mem.findScalar(u8, table[name_start..], '"') orelse
            return error.InvalidRootsTable;
        const name_end = name_start + name_end_rel;

        const src_marker = ".src = \"src/";
        const src_at_rel = std.mem.find(u8, table[name_end..], src_marker) orelse
            return error.InvalidRootsTable;
        const src_start = name_end + src_at_rel + src_marker.len;
        const src_end_rel = std.mem.findScalar(u8, table[src_start..], '"') orelse
            return error.InvalidRootsTable;
        const src_end = src_start + src_end_rel;
        root.* = .{
            .module_name = table[name_start..name_end],
            .source_root = table[src_start..src_end],
        };
        cursor = src_end;
    }
    if (std.mem.find(u8, table[cursor..], ".name = \"") != null)
        return error.InvalidRootsTable;
    return roots;
}

fn gitSourceZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: std.process.Child.Cwd,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "packages/zts" },
        .cwd = cwd,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.GitLsFilesFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.GitLsFilesFailed;
        },
    }
    return result.stdout;
}

fn lessPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "source census includes an unstaged module and excludes ignored files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const init = try std.process.run(allocator, io, .{ .argv = &.{ "git", "init", "-q" }, .cwd = .{ .dir = tmp.dir } });
    defer allocator.free(init.stdout);
    defer allocator.free(init.stderr);
    try std.testing.expect(init.term == .exited and init.term.exited == 0);
    try tmp.dir.createDirPath(io, "packages/zts/src");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "packages/zts/src/ignored.zig\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/zts/src/new module.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/zts/src/ignored.zig", .data = "" });
    const listing = try gitSourceZig(io, allocator, .{ .dir = tmp.dir });
    defer allocator.free(listing);
    try std.testing.expectEqualStrings("packages/zts/src/new module.zig\x00", listing);
}

fn trackedFiles(allocator: std.mem.Allocator, listing: []u8) ![]File {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, listing, 0);
    while (iterator.next()) |path| {
        if (path.len == 0 or !std.mem.startsWith(u8, path, prefix) or
            !std.mem.endsWith(u8, path, ".zig")) continue;
        try paths.append(allocator, path);
    }
    std.mem.sort([]const u8, paths.items, {}, lessPath);
    if (paths.items.len < min_files) {
        std.debug.print(
            "zts graph: only {d} files under {s}; expected at least {d}. " ++
                "The file list or path prefix changed.\n",
            .{ paths.items.len, prefix, min_files },
        );
        return error.FileFloor;
    }
    const files = try allocator.alloc(File, paths.items.len);
    errdefer allocator.free(files);
    for (files, paths.items) |*file, path| file.* = .{ .path = path };
    return files;
}

fn appendUnique(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(T), value: T) !void {
    for (list.items) |present| {
        if (present == value) return;
    }
    try list.append(allocator, value);
}

fn comparePath(path: []const u8, file: File) std.math.Order {
    return std.mem.order(u8, path, file.path);
}

fn pathIndex(files: []const File, path: []const u8) ?usize {
    return std.sort.binarySearch(File, files, path, comparePath);
}

fn normalizedTarget(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    specifier: []const u8,
) ![]u8 {
    const directory = std.fs.path.dirnamePosix(source_path) orelse "";
    const absolute = try std.fs.path.resolvePosix(allocator, &.{ "/", directory, specifier });
    if (absolute.len == 0 or absolute[0] != '/') return absolute;
    defer allocator.free(absolute);
    return try allocator.dupe(u8, absolute[1..]);
}

fn importEnd(line: []const u8, start: usize) ?usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (line[index] == '\\') {
            index += 1;
            continue;
        }
        if (line[index] == '"') return index;
    }
    return null;
}

fn codeBeforeComment(line: []const u8) []const u8 {
    var quote_count: usize = 0;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        if (line[index] == '\\') {
            index += 1;
            continue;
        }
        if (line[index] == '"') {
            quote_count += 1;
        } else if (line[index] == '/' and line[index + 1] == '/' and quote_count % 2 == 0) {
            return line[0..index];
        }
    }
    return line;
}

fn moduleTier(roots: [tier_count]BuildRoot, specifier: []const u8) ?u8 {
    for (roots, 0..) |root, index| {
        if (std.mem.eql(u8, root.module_name, specifier)) return @intCast(index);
    }
    return null;
}

fn scanFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    files: []File,
    file_index: usize,
    roots: [tier_count]BuildRoot,
) !void {
    const source = try readFile(io, allocator, files[file_index].path);
    defer allocator.free(source);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = codeBeforeComment(raw_line);
        var cursor: usize = 0;
        const marker = "@import(\"";
        while (std.mem.find(u8, line[cursor..], marker)) |at_rel| {
            const spec_start = cursor + at_rel + marker.len;
            const spec_end = importEnd(line, spec_start) orelse break;
            const specifier = line[spec_start..spec_end];
            cursor = spec_end + 1;
            if (std.mem.endsWith(u8, specifier, ".zig")) {
                const target = try normalizedTarget(allocator, files[file_index].path, specifier);
                defer allocator.free(target);
                if (pathIndex(files, target)) |target_index| {
                    try appendUnique(usize, allocator, &files[file_index].edges, target_index);
                } else {
                    var duplicate = false;
                    for (files[file_index].unresolved.items) |present| {
                        if (std.mem.eql(u8, present, specifier)) duplicate = true;
                    }
                    if (!duplicate) {
                        try files[file_index].unresolved.append(allocator, try allocator.dupe(u8, specifier));
                    }
                }
            } else if (moduleTier(roots, specifier)) |tier| {
                try appendUnique(u8, allocator, &files[file_index].named_tiers, tier);
            }
        }
    }
    std.mem.sort(usize, files[file_index].edges.items, {}, std.sort.asc(usize));
    std.mem.sort(u8, files[file_index].named_tiers.items, {}, std.sort.asc(u8));
}

fn loadGraph(io: std.Io, allocator: std.mem.Allocator, roots: [tier_count]BuildRoot) !Graph {
    const listing = try gitSourceZig(io, allocator, .inherit);
    errdefer allocator.free(listing);
    const files = try trackedFiles(allocator, listing);
    errdefer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    for (files, 0..) |_, index| try scanFile(io, allocator, files, index, roots);
    return .{ .files = files, .listing = listing };
}

fn tierIndex(name: []const u8) ?u8 {
    for (tier_names, 0..) |tier, index| {
        if (std.mem.eql(u8, tier, name)) return @intCast(index);
    }
    return null;
}

fn parseManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    files: []File,
) !void {
    const source = readFile(io, allocator, manifest_path) catch {
        std.debug.print("zts layering: missing {s}\n", .{manifest_path});
        return error.ManifestMismatch;
    };
    defer allocator.free(source);
    var errors: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw| {
        line_number += 1;
        const comment = std.mem.findScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..comment], " \t\r");
        if (line.len == 0) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const tier_word = words.next() orelse continue;
        const relative = words.next();
        if (relative == null or words.next() != null) {
            if (errors == 0) std.debug.print("zts layering: the manifest does not match the tree:\n", .{});
            errors += 1;
            std.debug.print("  {s}:{d}: expected '<tier> <path>', got {s}\n", .{ manifest_path, line_number, line });
            continue;
        }
        const tier = tierIndex(tier_word) orelse {
            if (errors == 0) std.debug.print("zts layering: the manifest does not match the tree:\n", .{});
            errors += 1;
            std.debug.print("  {s}:{d}: unknown tier {s}\n", .{ manifest_path, line_number, tier_word });
            continue;
        };
        const full_path = try allocator.print("{s}{s}", .{ prefix, relative.? });
        defer allocator.free(full_path);
        const index = pathIndex(files, full_path) orelse {
            if (errors == 0) std.debug.print("zts layering: the manifest does not match the tree:\n", .{});
            errors += 1;
            std.debug.print("  {s}:{d}: names no source file: {s}\n", .{ manifest_path, line_number, relative.? });
            continue;
        };
        if (files[index].tier) |present| {
            if (errors == 0) std.debug.print("zts layering: the manifest does not match the tree:\n", .{});
            errors += 1;
            std.debug.print("  {s}:{d}: {s} already assigned to {s}\n", .{ manifest_path, line_number, relative.?, tier_names[present] });
            continue;
        }
        files[index].tier = tier;
    }
    for (files) |file| {
        if (file.tier == null) {
            if (errors == 0) std.debug.print("zts layering: the manifest does not match the tree:\n", .{});
            errors += 1;
            std.debug.print("  {s}: no row for {s}\n", .{ manifest_path, file.path[prefix.len..] });
        }
    }
    if (errors != 0) {
        std.debug.print("Every source file needs exactly one row, and every row needs a file.\n", .{});
        return error.ManifestMismatch;
    }
}

fn rootFileIndex(files: []const File, relative: []const u8) ?usize {
    for (files, 0..) |file, index| {
        if (std.mem.eql(u8, file.path[prefix.len..], relative)) return index;
    }
    return null;
}

fn namedImportViolates(source_tier: u8, target_tier: u8) bool {
    return source_tier < target_tier;
}

// Every current tier is a separate build module. Any relative edge across a
// tier line compiles a second copy and is illegal.
fn relativeImportViolates(source_tier: u8, target_tier: u8) bool {
    return source_tier != target_tier;
}

const LayeringCounts = struct {
    edges: usize = 0,
    cross: usize = 0,
    named: usize = 0,
    named_violations: usize = 0,
    relative_violations: usize = 0,
};

fn countLayering(files: []const File) LayeringCounts {
    var counts: LayeringCounts = .{};
    for (files) |file| {
        const source_tier = file.tier.?;
        counts.edges += file.edges.items.len;
        counts.named += file.named_tiers.items.len;
        for (file.named_tiers.items) |target_tier| {
            if (namedImportViolates(source_tier, target_tier)) counts.named_violations += 1;
        }
        for (file.edges.items) |target_index| {
            const target_tier = files[target_index].tier.?;
            if (source_tier == target_tier) continue;
            counts.cross += 1;
            if (relativeImportViolates(source_tier, target_tier)) counts.relative_violations += 1;
        }
    }
    return counts;
}

fn reportLayering(
    io: std.Io,
    allocator: std.mem.Allocator,
    graph: *Graph,
    roots: [tier_count]BuildRoot,
    writer: *std.Io.Writer,
) !void {
    try parseManifest(io, allocator, graph.files);
    const counts = countLayering(graph.files);
    const edge_count = counts.edges;
    const cross_count = counts.cross;
    const named_count = counts.named;
    const named_violations = counts.named_violations;
    const relative_violations = counts.relative_violations;
    if (named_violations != 0) {
        std.debug.print("zts layering: {d} module-name imports point from a lower tier to a higher one:\n", .{named_violations});
        for (graph.files) |file| {
            const source_tier = file.tier.?;
            for (file.named_tiers.items) |target_tier| {
                if (namedImportViolates(source_tier, target_tier)) {
                    std.debug.print("    {s}  ->  @import(\"{s}\")\n", .{ file.path[prefix.len..], roots[target_tier].module_name });
                }
            }
        }
        std.debug.print(
            "A tier may name its own tier and any lower tier, never a higher tier.\n",
            .{},
        );
        return error.LayeringViolation;
    }
    if (relative_violations != 0) {
        std.debug.print("zts layering: {d} relative imports cross a module line illegally:\n", .{relative_violations});
        for (graph.files) |file| {
            for (file.edges.items) |target_index| {
                if (relativeImportViolates(file.tier.?, graph.files[target_index].tier.?)) {
                    std.debug.print("    {s}  ->  {s}\n", .{ file.path[prefix.len..], graph.files[target_index].path[prefix.len..] });
                }
            }
        }
        std.debug.print("Reach a split tier by module name instead of a relative path.\n", .{});
        return error.LayeringViolation;
    }
    if (named_count < min_named_edges) {
        std.debug.print(
            "zts layering: only {d} by-name imports were examined; expected at least {d}. " ++
                "The module names derived from {s} no longer match the tree.\n",
            .{ named_count, min_named_edges, build_path },
        );
        return error.NamedEdgeFloor;
    }

    var tier_sizes = @as([tier_count]usize, @splat(0));
    for (graph.files) |file| tier_sizes[file.tier.?] += 1;
    var reached_count: usize = 0;
    var unreachable_count: usize = 0;
    const seen = try allocator.alloc(bool, graph.files.len);
    defer allocator.free(seen);
    const stack = try allocator.alloc(usize, graph.files.len);
    defer allocator.free(stack);
    for (roots, 0..) |root, tier| {
        @memset(seen, false);
        const root_index = rootFileIndex(graph.files, root.source_root) orelse {
            std.debug.print("zts layering: tier {s} names a missing root: {s}\n", .{ tier_names[tier], root.source_root });
            return error.MissingTierRoot;
        };
        if (graph.files[root_index].tier.? != tier) {
            std.debug.print("zts layering: {s} has the wrong manifest tier\n", .{root.source_root});
            return error.WrongTierRoot;
        }
        var stack_len: usize = 1;
        stack[0] = root_index;
        seen[root_index] = true;
        while (stack_len != 0) {
            stack_len -= 1;
            const current = stack[stack_len];
            for (graph.files[current].edges.items) |target| {
                if (graph.files[target].tier.? == tier and !seen[target]) {
                    seen[target] = true;
                    stack[stack_len] = target;
                    stack_len += 1;
                }
            }
        }
        for (graph.files, 0..) |file, index| {
            if (file.tier.? != tier) continue;
            if (seen[index]) {
                reached_count += 1;
            } else {
                if (unreachable_count == 0) std.debug.print("zts layering: files are not reachable from their tier root:\n", .{});
                unreachable_count += 1;
                std.debug.print("    {s}  (tier {s}, root {s})\n", .{ file.path[prefix.len..], tier_names[tier], root.source_root });
            }
        }
    }
    if (unreachable_count != 0) {
        std.debug.print("A file no root reaches does not run its test blocks.\n", .{});
        return error.UnreachableTierFile;
    }

    try writer.print(
        "zts layering: OK ({d} files, {d} edges, {d} cross-tier, {d} by-name, {d} reachable; ",
        .{ graph.files.len, edge_count, cross_count, named_count, reached_count },
    );
    for (tier_names, 0..) |name, tier| {
        if (tier != 0) try writer.writeAll(", ");
        try writer.print("{s} {d}", .{ name, tier_sizes[tier] });
    }
    try writer.writeAll(")\n");
}

const Tarjan = struct {
    const Frame = struct {
        node: usize,
        next_child: usize = 0,
    };

    allocator: std.mem.Allocator,
    files: []const File,
    next_index: usize = 0,
    indices: []usize,
    lows: []usize,
    on_stack: []bool,
    stack: std.ArrayListUnmanaged(usize) = .empty,
    work: std.ArrayListUnmanaged(Frame) = .empty,
    components: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty,

    fn deinit(self: *Tarjan) void {
        self.allocator.free(self.indices);
        self.allocator.free(self.lows);
        self.allocator.free(self.on_stack);
        self.stack.deinit(self.allocator);
        self.work.deinit(self.allocator);
        for (self.components.items) |*component| component.deinit(self.allocator);
        self.components.deinit(self.allocator);
    }

    fn beginNode(self: *Tarjan, node: usize) !void {
        self.indices[node] = self.next_index;
        self.lows[node] = self.next_index;
        self.next_index += 1;
        try self.stack.append(self.allocator, node);
        self.on_stack[node] = true;
    }

    fn finishNode(self: *Tarjan, node: usize) !void {
        if (self.lows[node] != self.indices[node]) return;
        var component: std.ArrayListUnmanaged(usize) = .empty;
        errdefer component.deinit(self.allocator);
        while (true) {
            const member = self.stack.pop().?;
            self.on_stack[member] = false;
            try component.append(self.allocator, member);
            if (member == node) break;
        }
        try self.components.append(self.allocator, component);
    }

    fn visit(self: *Tarjan, start: usize) !void {
        std.debug.assert(self.work.items.len == 0);
        try self.beginNode(start);
        try self.work.append(self.allocator, .{ .node = start });

        while (self.work.items.len != 0) {
            const frame = &self.work.items[self.work.items.len - 1];
            const children = self.files[frame.node].edges.items;
            if (frame.next_child < children.len) {
                const child = children[frame.next_child];
                frame.next_child += 1;
                if (self.indices[child] == std.math.maxInt(usize)) {
                    try self.beginNode(child);
                    try self.work.append(self.allocator, .{ .node = child });
                } else if (self.on_stack[child]) {
                    self.lows[frame.node] = @min(self.lows[frame.node], self.indices[child]);
                }
                continue;
            }

            const node = frame.node;
            _ = self.work.pop();
            if (self.work.items.len != 0) {
                const parent = self.work.items[self.work.items.len - 1].node;
                self.lows[parent] = @min(self.lows[parent], self.lows[node]);
            }
            try self.finishNode(node);
        }
    }
};

fn tarjan(allocator: std.mem.Allocator, files: []const File) !Tarjan {
    const indices = try allocator.alloc(usize, files.len);
    errdefer allocator.free(indices);
    @memset(indices, std.math.maxInt(usize));
    const lows = try allocator.alloc(usize, files.len);
    errdefer allocator.free(lows);
    const on_stack = try allocator.alloc(bool, files.len);
    errdefer allocator.free(on_stack);
    @memset(on_stack, false);
    var state: Tarjan = .{
        .allocator = allocator,
        .files = files,
        .indices = indices,
        .lows = lows,
        .on_stack = on_stack,
    };
    errdefer {
        state.stack.deinit(allocator);
        state.work.deinit(allocator);
        for (state.components.items) |*component| component.deinit(allocator);
        state.components.deinit(allocator);
    }
    for (files, 0..) |_, node| {
        if (state.indices[node] == std.math.maxInt(usize)) try state.visit(node);
    }
    return state;
}

fn lessComponent(_: void, lhs: std.ArrayListUnmanaged(usize), rhs: std.ArrayListUnmanaged(usize)) bool {
    return lhs.items.len > rhs.items.len;
}

fn fillClosure(
    files: []const File,
    roots: []const usize,
    edge_offsets: []const usize,
    removed: []const bool,
    seen: []bool,
    queue: []usize,
) void {
    std.debug.assert(seen.len == files.len);
    std.debug.assert(queue.len == files.len);
    std.debug.assert(edge_offsets.len == files.len);
    @memset(seen, false);
    var head: usize = 0;
    var tail: usize = 0;
    for (roots) |root| {
        if (!seen[root]) {
            seen[root] = true;
            queue[tail] = root;
            tail += 1;
        }
    }
    while (head < tail) : (head += 1) {
        const source = queue[head];
        for (files[source].edges.items, 0..) |target, edge_index| {
            if (removed[edge_offsets[source] + edge_index] or seen[target]) continue;
            seen[target] = true;
            queue[tail] = target;
            tail += 1;
        }
    }
}

fn countSeen(seen: []const bool) usize {
    var count: usize = 0;
    for (seen) |present| count += @intFromBool(present);
    return count;
}

fn graphRoots(allocator: std.mem.Allocator, files: []const File) ![]usize {
    const roots = try allocator.alloc(usize, engine_roots.len);
    errdefer allocator.free(roots);
    var missing: usize = 0;
    for (engine_roots, 0..) |relative, index| {
        roots[index] = rootFileIndex(files, relative) orelse {
            if (missing == 0) std.debug.print("zts import graph: engine roots no longer exist:", .{});
            missing += 1;
            std.debug.print(" {s}", .{relative});
            continue;
        };
    }
    if (missing != 0) {
        std.debug.print(". Update the roots or the closure measures the wrong subject.\n", .{});
        return error.MissingEngineRoot;
    }
    return roots;
}

fn reportImportGraph(allocator: std.mem.Allocator, graph: *Graph, writer: *std.Io.Writer) !void {
    var edge_count: usize = 0;
    for (graph.files) |file| edge_count += file.edges.items.len;
    if (edge_count < min_edges) {
        std.debug.print(
            "zts import graph: only {d} relative import edges; expected at least {d}. " ++
                "The import syntax or scan changed.\n",
            .{ edge_count, min_edges },
        );
        return error.EdgeFloor;
    }
    const roots = try graphRoots(allocator, graph.files);
    defer allocator.free(roots);
    const edge_offsets = try allocator.alloc(usize, graph.files.len);
    defer allocator.free(edge_offsets);
    var edge_offset: usize = 0;
    for (graph.files, 0..) |file, source| {
        edge_offsets[source] = edge_offset;
        edge_offset += file.edges.items.len;
    }
    std.debug.assert(edge_offset == edge_count);
    const removed = try allocator.alloc(bool, edge_count);
    defer allocator.free(removed);
    @memset(removed, false);
    var current = try allocator.alloc(bool, graph.files.len);
    defer allocator.free(current);
    var candidate = try allocator.alloc(bool, graph.files.len);
    defer allocator.free(candidate);
    const queue = try allocator.alloc(usize, graph.files.len);
    defer allocator.free(queue);
    fillClosure(graph.files, roots, edge_offsets, removed, current, queue);

    var top_level: usize = 0;
    for (graph.files) |file| {
        if (std.mem.findScalar(u8, file.path[prefix.len..], '/') == null) top_level += 1;
    }
    try writer.print("zts import graph: {d} files, {d} relative import edges\n", .{ graph.files.len, edge_count });
    try writer.print("  {d} at the top level of {s}, {d} in subdirectories\n", .{ top_level, prefix, graph.files.len - top_level });

    var components = try tarjan(allocator, graph.files);
    defer components.deinit();
    std.mem.sort(std.ArrayListUnmanaged(usize), components.components.items, {}, lessComponent);
    var multi_count: usize = 0;
    for (components.components.items) |component| multi_count += @intFromBool(component.items.len > 1);
    try writer.print("\nstrongly connected components larger than one file: {d}\n", .{multi_count});
    for (components.components.items) |*component| {
        if (component.items.len <= 1) continue;
        std.mem.sort(usize, component.items, graph.files, struct {
            fn less(files: []const File, lhs: usize, rhs: usize) bool {
                return std.mem.order(u8, files[lhs].path, files[rhs].path) == .lt;
            }
        }.less);
        try writer.print("  size {d}: ", .{component.items.len});
        for (component.items, 0..) |member, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(graph.files[member].path[prefix.len..]);
        }
        try writer.writeByte('\n');
    }

    const initial_count = countSeen(current);
    try writer.print("\nengine closure: {d} of {d} files reachable from\n  ", .{ initial_count, graph.files.len });
    for (engine_roots, 0..) |root, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(root);
    }
    try writer.writeAll("\n\nback edges carrying the closure, ranked by files freed:\n");

    var ranked: usize = 0;
    while (true) {
        const current_count = countSeen(current);
        var best_source: ?usize = null;
        var best_target: usize = 0;
        var best_slot: usize = 0;
        var best_gain: usize = 1;
        for (graph.files, 0..) |file, source| {
            if (!current[source]) continue;
            for (file.edges.items, 0..) |target, edge_index| {
                const slot = edge_offsets[source] + edge_index;
                if (!current[target] or removed[slot]) continue;
                removed[slot] = true;
                fillClosure(graph.files, roots, edge_offsets, removed, candidate, queue);
                const gain = current_count - countSeen(candidate);
                removed[slot] = false;
                if (gain > best_gain) {
                    best_source = source;
                    best_target = target;
                    best_slot = slot;
                    best_gain = gain;
                }
            }
        }
        const source = best_source orelse break;
        removed[best_slot] = true;
        ranked += 1;
        fillClosure(graph.files, roots, edge_offsets, removed, candidate, queue);
        const after_count = countSeen(candidate);
        try writer.print(
            "  {s: <36} -> {s: <30} frees {d: >3}, closure {d: >3}\n",
            .{ graph.files[source].path[prefix.len..], graph.files[best_target].path[prefix.len..], best_gain, after_count },
        );
        std.mem.swap([]bool, &current, &candidate);
    }
    if (ranked == 0) {
        try writer.writeAll("  none: no single edge frees more than one file\n");
    } else {
        try writer.print("\n{d} cuts take the engine closure from {d} to {d}\n", .{ ranked, initial_count, countSeen(current) });
    }

    var unresolved_count: usize = 0;
    for (graph.files) |file| unresolved_count += file.unresolved.items.len;
    if (unresolved_count != 0) {
        try writer.writeAll("\nrelative imports that resolve to no source file:\n");
        for (graph.files) |file| {
            if (file.unresolved.items.len == 0) continue;
            std.mem.sort([]u8, file.unresolved.items, {}, struct {
                fn less(_: void, lhs: []u8, rhs: []u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.less);
            try writer.print("  {s}: ", .{file.path[prefix.len..]});
            for (file.unresolved.items, 0..) |specifier, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.writeAll(specifier);
            }
            try writer.writeByte('\n');
        }
    }
}

fn usage() noreturn {
    std.debug.print("usage: zts-graph-gate <layering|import-graph>\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io_backend.deinit();
    const io = io_backend.io();

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse usage();
    if (args.next() != null) usage();

    const build_source = readFile(io, allocator, build_path) catch |failure| {
        std.debug.print("zts graph: cannot read {s}: {s}\n", .{ build_path, @errorName(failure) });
        std.process.exit(1);
    };
    defer allocator.free(build_source);
    const roots = deriveBuildRoots(build_source) catch |failure| {
        std.debug.print(
            "zts graph: {s} does not declare exactly five readable zts roots: {s}\n",
            .{ build_path, @errorName(failure) },
        );
        std.process.exit(1);
    };
    var graph = loadGraph(io, allocator, roots) catch |failure| {
        std.debug.print("zts graph: input collection failed: {s}\n", .{@errorName(failure)});
        std.process.exit(1);
    };
    defer graph.deinit(allocator);

    var output_buffer: [64 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    if (std.mem.eql(u8, command, "layering")) {
        reportLayering(io, allocator, &graph, roots, &output.interface) catch |failure| {
            std.debug.print("zts layering: failed: {s}\n", .{@errorName(failure)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "import-graph")) {
        reportImportGraph(allocator, &graph, &output.interface) catch |failure| {
            std.debug.print("zts import graph: failed: {s}\n", .{@errorName(failure)});
            std.process.exit(1);
        };
    } else {
        usage();
    }
    try output.interface.flush();
}

test "build roots parser reads five module names and source roots" {
    const source =
        \\const zts_roots = [_]struct { name: []const u8, src: []const u8 }{
        \\    .{ .name = "a", .src = "src/a.zig" },
        \\    .{ .name = "b", .src = "src/b.zig" },
        \\    .{ .name = "c", .src = "src/c.zig" },
        \\    .{ .name = "d", .src = "src/d.zig" },
        \\    .{ .name = "e", .src = "src/e.zig" },
        \\    };
    ;
    const roots = try deriveBuildRoots(source);
    try std.testing.expectEqualStrings("c", roots[2].module_name);
    try std.testing.expectEqualStrings("e.zig", roots[4].source_root);
}

test "build roots parser rejects a missing or extra root" {
    const four =
        \\const zts_roots = [_]struct { name: []const u8, src: []const u8 }{
        \\    .{ .name = "a", .src = "src/a.zig" },
        \\    .{ .name = "b", .src = "src/b.zig" },
        \\    .{ .name = "c", .src = "src/c.zig" },
        \\    .{ .name = "d", .src = "src/d.zig" },
        \\    };
    ;
    try std.testing.expectError(error.InvalidRootsTable, deriveBuildRoots(four));

    const six =
        \\const zts_roots = [_]struct { name: []const u8, src: []const u8 }{
        \\    .{ .name = "a", .src = "src/a.zig" },
        \\    .{ .name = "b", .src = "src/b.zig" },
        \\    .{ .name = "c", .src = "src/c.zig" },
        \\    .{ .name = "d", .src = "src/d.zig" },
        \\    .{ .name = "e", .src = "src/e.zig" },
        \\    .{ .name = "f", .src = "src/f.zig" },
        \\    };
    ;
    try std.testing.expectError(error.InvalidRootsTable, deriveBuildRoots(six));
}

test "comment stripping preserves a slash pair inside a string" {
    try std.testing.expectEqualStrings(
        "const x = \"//\"; ",
        codeBeforeComment("const x = \"//\"; // @import(\"hidden.zig\")"),
    );
}

fn testRoots() [tier_count]BuildRoot {
    var roots: [tier_count]BuildRoot = undefined;
    for (tier_names, 0..) |name, index| {
        roots[index] = .{ .module_name = name, .source_root = "root.zig" };
    }
    return roots;
}

test "module names map to their own tier index" {
    const roots = testRoots();
    for (tier_names, 0..) |name, index| {
        try std.testing.expectEqual(@as(?u8, @intCast(index)), moduleTier(roots, name));
    }
    try std.testing.expectEqual(@as(?u8, null), moduleTier(roots, "std"));
    try std.testing.expectEqual(@as(?u8, null), moduleTier(roots, "zts-"));
}

test "relative import targets resolve against the importing directory" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, spec: []const u8, want: []const u8 }{
        .{ .source = "packages/zts/src/a/b.zig", .spec = "c.zig", .want = "packages/zts/src/a/c.zig" },
        .{ .source = "packages/zts/src/a/b.zig", .spec = "../c.zig", .want = "packages/zts/src/c.zig" },
        .{ .source = "packages/zts/src/a/b.zig", .spec = "d/e.zig", .want = "packages/zts/src/a/d/e.zig" },
        .{ .source = "root.zig", .spec = "x.zig", .want = "x.zig" },
    };
    for (cases) |case| {
        const got = try normalizedTarget(allocator, case.source, case.spec);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "import end skips an escaped quote and reports an unclosed import" {
    const line = "@import(\"a\\\"b.zig\") x";
    try std.testing.expectEqual(@as(?usize, 17), importEnd(line, 9));
    try std.testing.expectEqual(@as(?usize, null), importEnd("@import(\"open", 9));
}

fn testFile(allocator: std.mem.Allocator, tier: u8, edges: []const usize, named: []const u8) !File {
    var file: File = .{ .path = "", .tier = tier };
    errdefer file.deinit(allocator);
    try file.edges.appendSlice(allocator, edges);
    try file.named_tiers.appendSlice(allocator, named);
    return file;
}

test "layering counts an upward module name and every cross-tier relative edge" {
    const allocator = std.testing.allocator;
    var files = [_]File{
        // Own-tier name and a same-tier relative edge are legal.
        try testFile(allocator, 0, &.{1}, &.{0}),
        try testFile(allocator, 0, &.{}, &.{}),
        // Lower and own-tier names are legal. The relative edge up to tier 3 is not.
        try testFile(allocator, 2, &.{3}, &.{ 0, 1, 2 }),
        // The name of tier 4 is upward. The relative edge down to tier 0 is still illegal.
        try testFile(allocator, 3, &.{0}, &.{4}),
        try testFile(allocator, 4, &.{}, &.{3}),
    };
    defer for (&files) |*file| file.deinit(allocator);
    const counts = countLayering(&files);
    try std.testing.expectEqual(@as(usize, 3), counts.edges);
    try std.testing.expectEqual(@as(usize, 2), counts.cross);
    try std.testing.expectEqual(@as(usize, 6), counts.named);
    try std.testing.expectEqual(@as(usize, 1), counts.named_violations);
    try std.testing.expectEqual(@as(usize, 2), counts.relative_violations);
}

test "layering counts no violation in a graph that only names down and stays in tier" {
    const allocator = std.testing.allocator;
    var files = [_]File{
        try testFile(allocator, 0, &.{1}, &.{}),
        try testFile(allocator, 0, &.{0}, &.{0}),
        try testFile(allocator, 4, &.{3}, &.{ 0, 1, 2, 3, 4 }),
        try testFile(allocator, 4, &.{}, &.{4}),
    };
    defer for (&files) |*file| file.deinit(allocator);
    const counts = countLayering(&files);
    try std.testing.expectEqual(@as(usize, 3), counts.edges);
    try std.testing.expectEqual(@as(usize, 0), counts.cross);
    try std.testing.expectEqual(@as(usize, 7), counts.named);
    try std.testing.expectEqual(@as(usize, 0), counts.named_violations);
    try std.testing.expectEqual(@as(usize, 0), counts.relative_violations);
}
