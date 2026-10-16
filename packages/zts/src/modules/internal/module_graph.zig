//! Module Dependency Graph
//!
//! Builds a dependency graph from an entry file by recursively scanning
//! import declarations. Performs topological sort for correct execution
//! order and detects circular imports.

const std = @import("std");
const file_resolver = @import("file_resolver.zig");
const resolver = @import("resolver.zig");

// Engine types
const zts_parser = @import("../../parser/root.zig");
const context = @import("../../context.zig");
const source_frontend = @import("../../source_frontend.zig");

pub const ModuleIndex = u16;

/// Maximum import nesting depth to prevent runaway recursion
const MAX_NESTING_DEPTH = 32;

/// Callback type for reading file contents. Returns owned slice or error.
pub const ReadFileFn = *const fn (allocator: std.mem.Allocator, path: []const u8) ReadFileError![]const u8;

pub const ReadFileError = error{
    FileNotFound,
    OutOfMemory,
    FileTooBig,
    AccessDenied,
    Unexpected,
    InputOutput,
    IsDir,
    SystemResources,
    InvalidArgument,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    WouldBlock,
    OperationAborted,
    ProcessNotFound,
};

pub const Module = struct {
    path: []const u8,
    source: []const u8,
    source_profile: SourceProfile = .raw,
    dependencies: []ModuleIndex,
    state: DfsState,

    const DfsState = enum { unvisited, visiting, visited };

    pub const SourceProfile = enum { direct, raw };

    pub fn initParser(self: *const Module, allocator: std.mem.Allocator) !zts_parser.JsParser {
        return switch (self.source_profile) {
            .direct => zts_parser.JsParser.initAdmission(allocator, allocator, self.source, .compile),
            .raw => zts_parser.JsParser.init(allocator, self.source),
        };
    }

    pub fn parse(self: *const Module, parser: *zts_parser.JsParser) !zts_parser.NodeIndex {
        return switch (self.source_profile) {
            .raw => parser.parse(),
            .direct => switch (try parser.parseAdmission()) {
                .accepted => |root| root,
                .parser_refused => |refusal| return refusal.first_error,
                .terminal_admission_refused => |failure| return source_frontend.prepareErrorForAdmissionFailure(failure),
                .recovered_admission_refused => unreachable,
            },
        };
    }

    fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        if (self.dependencies.len > 0) {
            allocator.free(self.dependencies);
        }
    }
};

fn selectSourceProfile(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !Module.SourceProfile {
    switch (source_frontend.classifyPath(path)) {
        .unsupported => return error.UnsupportedSourceExtension,
        .virtual_javascript => return .raw,
        .typescript => {},
    }
    var parser = try zts_parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    return switch (try parser.parseAdmission()) {
        .accepted, .parser_refused => .direct,
        .recovered_admission_refused => unreachable,
        .terminal_admission_refused => |failure| blk: {
            std.debug.print("TypeScript strip failed for module '{s}': {}\n", .{
                path, source_frontend.prepareErrorForAdmissionFailure(failure),
            });
            break :blk .raw;
        },
    };
}

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(ModuleIndex),
    module_list: std.ArrayList(Module),
    execution_order: []ModuleIndex,

    pub fn init(allocator: std.mem.Allocator) ModuleGraph {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(ModuleIndex).init(allocator),
            .module_list = std.ArrayList(Module).empty,
            .execution_order = &.{},
        };
    }

    pub fn deinit(self: *ModuleGraph) void {
        for (self.module_list.items) |*m| {
            m.deinit(self.allocator);
        }
        self.module_list.deinit(self.allocator);
        self.modules.deinit();
        if (self.execution_order.len > 0) {
            self.allocator.free(self.execution_order);
        }
    }

    /// Get the number of modules (excluding the entry file)
    pub fn dependencyCount(self: *const ModuleGraph) usize {
        if (self.execution_order.len == 0) return 0;
        // Last element in execution_order is the entry file
        return self.execution_order.len - 1;
    }

    /// Build the module graph starting from the entry file.
    /// The entry file itself is added as the last module in execution_order.
    pub fn build(
        self: *ModuleGraph,
        entry_path: []const u8,
        entry_source: []const u8,
        read_file: ReadFileFn,
    ) !void {
        return self.buildEntry(entry_path, entry_source, read_file, false);
    }

    /// Build a fixed prepared-evaluation entry with ordinary file dependencies.
    pub fn buildPreparedEval(
        self: *ModuleGraph,
        entry_path: []const u8,
        entry_source: []const u8,
        read_file: ReadFileFn,
    ) !void {
        if (source_frontend.classifyPath(entry_path) != .virtual_javascript) return error.UnsupportedSourceExtension;
        return self.buildEntry(entry_path, entry_source, read_file, true);
    }

    fn buildEntry(
        self: *ModuleGraph,
        entry_path: []const u8,
        entry_source: []const u8,
        read_file: ReadFileFn,
        prepared_eval: bool,
    ) !void {
        // Add entry module (dupe path and source since addModule takes ownership)
        const owned_path = try self.allocator.dupe(u8, entry_path);
        const owned_source = self.allocator.dupe(u8, entry_source) catch |err| {
            self.allocator.free(owned_path);
            return err;
        };
        const entry_idx = try self.addModuleWithProfile(owned_path, owned_source, if (prepared_eval) .direct else null);

        // Recursively discover dependencies
        try self.discoverDependencies(entry_idx, read_file, 0);

        // Topological sort
        try self.topologicalSort();
    }

    /// Add a module to the graph. Takes ownership of both path and source.
    fn addModule(self: *ModuleGraph, owned_path: []const u8, owned_source: []const u8) !ModuleIndex {
        return self.addModuleWithProfile(owned_path, owned_source, null);
    }

    fn addModuleWithProfile(
        self: *ModuleGraph,
        owned_path: []const u8,
        owned_source: []const u8,
        entry_profile: ?Module.SourceProfile,
    ) !ModuleIndex {
        const idx: ModuleIndex = @intCast(self.module_list.items.len);

        var ownership_transferred = false;
        errdefer if (!ownership_transferred) {
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
        };
        const source_profile = entry_profile orelse try selectSourceProfile(self.allocator, owned_source, owned_path);

        try self.module_list.append(self.allocator, .{
            .path = owned_path,
            .source = owned_source,
            .source_profile = source_profile,
            .dependencies = &.{},
            .state = .unvisited,
        });
        ownership_transferred = true;

        // HashMap borrows path from the module (module owns it)
        try self.modules.put(owned_path, idx);

        return idx;
    }

    fn discoverDependencies(self: *ModuleGraph, module_idx: ModuleIndex, read_file: ReadFileFn, depth: u32) !void {
        if (depth > MAX_NESTING_DEPTH) return error.ImportNestingTooDeep;

        var module = &self.module_list.items[module_idx];
        const module_path = module.path;

        // Quick-parse to extract import declarations
        var js_parser = try module.initParser(self.allocator);
        defer js_parser.deinit();

        _ = module.parse(&js_parser) catch return; // Parse errors handled later during compilation
        const view = zts_parser.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

        // Extract file imports
        var deps = std.ArrayList(ModuleIndex).empty;
        errdefer deps.deinit(self.allocator);

        const node_count = view.nodeCount();
        for (0..node_count) |idx| {
            const tag = view.getTag(@intCast(idx)) orelse continue;
            if (tag != .import_decl) continue;

            const import_decl = view.getImportDecl(@intCast(idx)) orelse continue;
            const module_str = view.getString(import_decl.module_idx) orelse continue;

            // Only process file imports (skip virtual modules)
            const resolve_result = resolver.resolve(module_str);
            switch (resolve_result) {
                .file => |specifier| {
                    const importing_dir = file_resolver.dirName(module_path);
                    const resolved_path = try file_resolver.resolve(self.allocator, specifier, importing_dir, null);

                    // Check if already in graph (dedup)
                    if (self.modules.get(resolved_path)) |existing_idx| {
                        self.allocator.free(resolved_path);
                        try deps.append(self.allocator, existing_idx);
                        continue;
                    }

                    // Read the file
                    const dep_source = read_file(self.allocator, resolved_path) catch {
                        std.debug.print(
                            "Module graph read failed: importer={s} specifier={s} resolved={s}\n",
                            .{ module_path, specifier, resolved_path },
                        );
                        self.allocator.free(resolved_path);
                        return error.ImportFileNotFound;
                    };

                    // addModule takes ownership of resolved_path and dep_source
                    const dep_idx = try self.addModule(resolved_path, dep_source);

                    try deps.append(self.allocator, dep_idx);

                    // Recurse into the dependency
                    try self.discoverDependencies(dep_idx, read_file, depth + 1);
                },
                .virtual, .unknown => {},
            }
        }

        // Re-fetch module pointer (module_list may have been reallocated)
        module = &self.module_list.items[module_idx];
        module.dependencies = try deps.toOwnedSlice(self.allocator);
    }

    fn topologicalSort(self: *ModuleGraph) !void {
        var order = std.ArrayList(ModuleIndex).empty;
        errdefer order.deinit(self.allocator);

        // Reset all states
        for (self.module_list.items) |*m| {
            m.state = .unvisited;
        }

        // DFS from each unvisited module
        for (0..self.module_list.items.len) |i| {
            if (self.module_list.items[i].state == .unvisited) {
                try self.dfsVisit(@intCast(i), &order);
            }
        }

        self.execution_order = try order.toOwnedSlice(self.allocator);
    }

    fn dfsVisit(self: *ModuleGraph, idx: ModuleIndex, order: *std.ArrayList(ModuleIndex)) !void {
        var module = &self.module_list.items[idx];

        if (module.state == .visiting) return error.CircularImport;
        if (module.state == .visited) return;

        module.state = .visiting;

        for (module.dependencies) |dep_idx| {
            try self.dfsVisit(dep_idx, order);
        }

        module.state = .visited;
        try order.append(self.allocator, idx);
    }
};

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    CircularImport,
    ImportFileNotFound,
    ImportNestingTooDeep,
    OutOfMemory,
};

// ============================================================================
// Tests
// ============================================================================

fn testReadFile(allocator: std.mem.Allocator, path: []const u8) ReadFileError![]const u8 {
    // Mock: return allocated source based on path (caller owns result)
    const source: []const u8 = if (std.mem.endsWith(u8, path, "utils.ts"))
        "export function greet(name) { return [\"Hello \", name].join(\"\"); }"
    else if (std.mem.endsWith(u8, path, "helpers.ts"))
        "export function add(a, b) { return a + b; }"
    else if (std.mem.endsWith(u8, path, "circular_a.ts"))
        "import { b } from \"./circular_b.ts\"; export const a = 1;"
    else if (std.mem.endsWith(u8, path, "circular_b.ts"))
        "import { a } from \"./circular_a.ts\"; export const b = 2;"
    else
        return error.FileNotFound;

    return allocator.dupe(u8, source) catch return error.OutOfMemory;
}

test "module graph: no imports" {
    const allocator = std.testing.allocator;
    var graph = ModuleGraph.init(allocator);
    defer graph.deinit();

    const source = "export function handler(req) { return Response.json({ok: true}); }";
    try graph.build("/app/handler.ts", source, testReadFile);

    try std.testing.expectEqual(@as(usize, 1), graph.module_list.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.dependencyCount());
}

test "module graph: single file import" {
    const allocator = std.testing.allocator;
    var graph = ModuleGraph.init(allocator);
    defer graph.deinit();

    const source = "import { greet } from \"./utils.ts\"; export function handler(req) { return Response.text(greet(\"world\")); }";
    try graph.build("/app/handler.ts", source, testReadFile);

    try std.testing.expectEqual(@as(usize, 2), graph.module_list.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencyCount());
    // utils.ts should come before handler.ts in execution order
    try std.testing.expectEqual(@as(usize, 2), graph.execution_order.len);
}

test "module graph: fan-out imports" {
    const allocator = std.testing.allocator;
    var graph = ModuleGraph.init(allocator);
    defer graph.deinit();

    const source = "import { greet } from \"./utils.ts\"; import { add } from \"./helpers.ts\"; export function handler(req) { return Response.json({ok: true}); }";
    try graph.build("/app/handler.ts", source, testReadFile);

    try std.testing.expectEqual(@as(usize, 3), graph.module_list.items.len);
    try std.testing.expectEqual(@as(usize, 2), graph.dependencyCount());
}

test "module graph: circular import detected" {
    const allocator = std.testing.allocator;
    var graph = ModuleGraph.init(allocator);
    defer graph.deinit();

    try std.testing.expectError(
        error.CircularImport,
        graph.build("/app/circular_a.ts", "import { b } from \"./circular_b.ts\"; export const a = 1;", testReadFile),
    );
}

test "module graph: typed preparation closes every allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var graph = ModuleGraph.init(allocator);
            defer graph.deinit();

            try graph.build(
                "/app/handler.ts",
                "export function handler(req: Request): Response { return Response.json({ ok: true }); }",
                testReadFile,
            );
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "graph source selection bounds every hard admission producer" {
    const cases = [_]struct { kind: zts_parser.type_syntax.AdmissionKind, source: []const u8 }{
        .{ .kind = .any_type, .source = "import type { A } /* ; */ from \"./a\";\nconst value: any = 1;\n" },
        .{ .kind = .as_assertion, .source = "import type { A } /* ; */ from \"./a\";\nconst value = source as string;\n" },
        .{ .kind = .satisfies_assertion, .source = "import type { A } /* ; */ from \"./a\";\nconst value = source satisfies string;\n" },
        .{ .kind = .unterminated_string, .source = "import type { A } /* ; */ from \"./a\";\nconst value = \"open\nconst after = 1;\n" },
        .{ .kind = .nominal_base_not_scalar, .source = "import type { A } /* ; */ from \"./a\";\nnominal Box = T;\n" },
        .{ .kind = .interface_declaration, .source = "import type { A } /* ; */ from \"./a\";\ninterface Box { value: string }\n" },
        .{ .kind = .type_alias_declaration, .source = "import type { A } /* ; */ from \"./a\";\ntype Box = string;\n" },
        .{ .kind = .distinct_type_declaration, .source = "import type { A } /* ; */ from \"./a\";\ndistinct type Box = string;\n" },
        .{ .kind = .legacy_types_import, .source = "import type { A } /* ; */ from \"./a\";\nimport type { Value } from '" ++ @import("zts-base").module_specifier.retired_types_module ++ "';\n" },
        .{ .kind = .default_parameter, .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value = 1) { return value; }\n" },
        .{ .kind = .optional_parameter, .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value?: string) { return value; }\n" },
        .{ .kind = .default_export, .source = "import type { A } /* ; */ from \"./a\";\nexport default 1;\n" },
        .{ .kind = .mutable_export, .source = "import type { A } /* ; */ from \"./a\";\nexport let value = 1;\n" },
        .{ .kind = .array_type_alias, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = Array<string>;\n" },
        .{ .kind = .readonly_array_type_alias, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = ReadonlyArray<string>;\n" },
        .{ .kind = .void_type, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = void;\n" },
        .{ .kind = .nesting_too_deep, .source = "import type { A } /* ; */ from \"./a\";\nconst value: {{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{ string;\n" },
    };
    try std.testing.expectEqual(std.meta.fields(zts_parser.type_syntax.AdmissionKind).len, cases.len);
    var seen = std.EnumSet(zts_parser.type_syntax.AdmissionKind).initEmpty();
    const Reader = struct {
        fn read(_: std.mem.Allocator, _: []const u8) ReadFileError![]const u8 {
            return error.FileNotFound;
        }
    };
    for (cases) |case| {
        try std.testing.expect(!seen.contains(case.kind));
        seen.insert(case.kind);
        var parser = try zts_parser.JsParser.initAdmission(std.testing.allocator, std.testing.allocator, case.source, .compile);
        defer parser.deinit();
        switch (try parser.parseAdmission()) {
            .terminal_admission_refused => |failure| switch (failure) {
                .diagnostic => |diagnostic| try std.testing.expectEqual(case.kind, diagnostic.kind),
                .unterminated_comment => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        }
        var graph = ModuleGraph.init(std.testing.allocator);
        defer graph.deinit();
        try graph.build("entry.ts", case.source, Reader.read);
        try std.testing.expectEqual(Module.SourceProfile.raw, graph.module_list.items[0].source_profile);
    }
    var comment = try zts_parser.JsParser.initAdmission(std.testing.allocator, std.testing.allocator, "/* unfinished\n", .compile);
    defer comment.deinit();
    switch (try comment.parseAdmission()) {
        .terminal_admission_refused => |failure| switch (failure) {
            .unterminated_comment => {},
            .diagnostic => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    var comment_graph = ModuleGraph.init(std.testing.allocator);
    defer comment_graph.deinit();
    try comment_graph.build("entry.ts", "/* unfinished\n", Reader.read);
    try std.testing.expectEqual(Module.SourceProfile.raw, comment_graph.module_list.items[0].source_profile);
    const contrasts = [_]struct { source: []const u8, path: []const u8, profile: Module.SourceProfile }{
        .{ .source = "const value: any = 1;", .path = "<virtual>", .profile = .raw },
        .{ .source = "const marker: \"open\n = \"open\"; export const value = 1;\n", .path = "entry.ts", .profile = .direct },
        .{ .source = "const value: number = ;\n", .path = "entry.ts", .profile = .direct },
    };
    for (contrasts) |control| {
        var graph = ModuleGraph.init(std.testing.allocator);
        defer graph.deinit();
        try graph.build(control.path, control.source, Reader.read);
        try std.testing.expectEqual(control.profile, graph.module_list.items[0].source_profile);
    }
    var unsupported = ModuleGraph.init(std.testing.allocator);
    defer unsupported.deinit();
    try std.testing.expectError(error.UnsupportedSourceExtension, unsupported.build("entry.js", "", Reader.read));
}

test "graph build allocation failure cannot select raw" {
    const source = "structural Label = string;\nconst label: Label = \"value\";\nexport const result: Label = label;\n";
    const Run = struct {
        fn read(_: std.mem.Allocator, _: []const u8) ReadFileError![]const u8 {
            return error.FileNotFound;
        }
        fn build(allocator: std.mem.Allocator) !void {
            var graph = ModuleGraph.init(allocator);
            defer graph.deinit();
            try graph.build("entry.ts", source, read);
            try std.testing.expectEqual(@as(usize, 1), graph.module_list.items.len);
            try std.testing.expectEqual(Module.SourceProfile.direct, graph.module_list.items[0].source_profile);
        }
    };
    var calibration = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try Run.build(calibration.allocator());
    try std.testing.expect(calibration.alloc_index > 0);
    var native_failures: usize = 0;
    for (0..calibration.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        Run.build(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            native_failures += 1;
        };
    }
    try std.testing.expect(native_failures > 0);
}

test "selected discovery parser distinguishes initialization and parse allocation failures" {
    const source = "structural Label = string;\nconst label: Label = \"ready\";\nimport { value } from \"./dep.ts\";\n";
    const allocator = std.testing.allocator;
    var calibration = std.testing.FailingAllocator.init(allocator, .{});
    var module: Module = .{ .path = "entry.ts", .source = source, .source_profile = .direct, .dependencies = &.{}, .state = .unvisited };
    var parser = try module.initParser(calibration.allocator());
    defer parser.deinit();
    _ = try module.parse(&parser);
    var init_failures: usize = 0;
    var parse_failures: usize = 0;
    var progressed_parse_failures: usize = 0;
    for (0..calibration.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = index });
        var selected = module.initParser(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            init_failures += 1;
            continue;
        };
        defer selected.deinit();
        _ = module.parse(&selected) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            if (selected.current.start > 0) progressed_parse_failures += 1;
            parse_failures += 1;
            continue;
        };
        try std.testing.expect(!failing.has_induced_failure);
    }
    try std.testing.expect(init_failures > 0);
    try std.testing.expect(parse_failures > 0);
    try std.testing.expect(progressed_parse_failures > 0);
}

const GraphSingleFailure = struct {
    failing: std.testing.FailingAllocator,
    const Self = @This();
    fn allocator(self: *Self) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.failing.has_induced_failure) return self.failing.internal_allocator.rawAlloc(len, alignment, ret);
        return self.failing.allocator().rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.failing.internal_allocator.rawResize(memory, alignment, size, ret);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.failing.internal_allocator.rawRemap(memory, alignment, size, ret);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.failing.internal_allocator.rawFree(memory, alignment, ret);
    }
};

test "graph discovery retains its tolerant native parse boundary" {
    const source = "import { value } from \"./dep.ts\";\nconst result: number = value;\n";
    const Run = struct {
        fn read(_: std.mem.Allocator, _: []const u8) ReadFileError![]const u8 {
            // Keep reader allocation healthy to isolate discovery parser failures.
            return std.testing.allocator.dupe(u8, "export const value = 1;\n");
        }
        fn build(failing: *GraphSingleFailure) !usize {
            var graph = ModuleGraph.init(failing.allocator());
            defer graph.deinit();
            try graph.build("/probe/entry.ts", source, read);
            try std.testing.expectEqual(Module.SourceProfile.direct, graph.module_list.items[0].source_profile);
            return graph.module_list.items.len;
        }
    };
    var calibration: GraphSingleFailure = .{ .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{}) };
    try std.testing.expectEqual(@as(usize, 2), try Run.build(&calibration));
    var tolerated: usize = 0;
    var propagated: usize = 0;
    for (0..calibration.failing.alloc_index) |index| {
        var failing: GraphSingleFailure = .{ .failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index }) };
        const count = Run.build(&failing) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.failing.has_induced_failure);
            propagated += 1;
            continue;
        };
        if (count == 1) {
            try std.testing.expect(failing.failing.has_induced_failure);
            tolerated += 1;
        } else try std.testing.expectEqual(@as(usize, 2), count);
    }
    try std.testing.expect(propagated > 0);
    try std.testing.expect(tolerated > 0);
}

test "graph preparation propagates native admission allocation failures" {
    const source = "structural Label = string;\nconst label: Label = \"value\";\nexport const result: Label = label;\n";
    const allocator = std.testing.allocator;
    var calibration = std.testing.FailingAllocator.init(allocator, .{});
    const owned_path = try calibration.allocator().dupe(u8, "entry.ts");
    defer calibration.allocator().free(owned_path);
    const owned_source = try calibration.allocator().dupe(u8, source);
    defer calibration.allocator().free(owned_source);
    var parser = try zts_parser.JsParser.initAdmission(calibration.allocator(), calibration.allocator(), owned_source, .compile);
    defer parser.deinit();
    const parse_start = calibration.alloc_index;
    switch (try parser.parseAdmission()) {
        .accepted => {},
        else => return error.TestUnexpectedResult,
    }
    const parse_end = calibration.alloc_index;
    try std.testing.expect(parse_end > parse_start);
    const Reader = struct {
        fn read(_: std.mem.Allocator, _: []const u8) ReadFileError![]const u8 {
            return error.FileNotFound;
        }
    };
    var failures: usize = 0;
    for (parse_start..parse_end) |index| {
        var failing: GraphSingleFailure = .{ .failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = index }) };
        var graph = ModuleGraph.init(failing.allocator());
        defer graph.deinit();
        try std.testing.expectError(error.OutOfMemory, graph.build("entry.ts", source, Reader.read));
        try std.testing.expect(failing.failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), graph.module_list.items.len);
        failures += 1;
    }
    try std.testing.expectEqual(parse_end - parse_start, failures);
    try std.testing.expect(failures > 0);
}
