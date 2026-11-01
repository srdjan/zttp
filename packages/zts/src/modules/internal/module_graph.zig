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
const atom_table_mod = @import("../../atom_table.zig");
const object = @import("../../object.zig");
const known_globals = @import("zts-base").known_globals;

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
    dependencies: []ModuleIndex,
    state: DfsState,

    const DfsState = enum { unvisited, visiting, visited };

    pub fn initParser(self: *const Module, allocator: std.mem.Allocator) !zts_parser.JsParser {
        return zts_parser.JsParser.initAdmission(allocator, allocator, self.source, .compile);
    }

    pub fn parse(_: *const Module, parser: *zts_parser.JsParser) !zts_parser.NodeIndex {
        return switch (try parser.parseAdmission()) {
            .accepted => |root| root,
            .parser_refused => |refusal| return refusal.first_error,
            .terminal_admission_refused => |failure| return source_frontend.prepareErrorForAdmissionFailure(failure),
            .recovered_admission_refused => unreachable,
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

/// Admit one module's source. A parser refusal passes here and is reported
/// when the module is parsed for compilation.
fn admitModule(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !void {
    switch (source_frontend.classifyPath(path)) {
        .unsupported, .virtual_javascript => return error.UnsupportedSourceExtension,
        .typescript => {},
    }
    var parser = try zts_parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    switch (try parser.parseAdmission()) {
        .accepted, .parser_refused => {},
        .recovered_admission_refused => unreachable,
        .terminal_admission_refused => |failure| {
            const line = try source_frontend.formatAdmissionRefusal(allocator, source, path, failure);
            defer allocator.free(line);
            std.debug.print("{s}\n", .{line});
            return source_frontend.prepareErrorForAdmissionFailure(failure);
        },
    }
}

/// Why `checkBindings` refused a graph. `name` is owned by the graph. Both paths
/// borrow from the graph and stay as the graph holds them. `second_path` is empty
/// unless the refusal involves two modules.
pub const BindingRefusal = struct {
    kind: Kind,
    name: []const u8,
    first_path: []const u8,
    second_path: []const u8,

    pub const Kind = enum { ambiguous, reserved, dependency_handler, missing_export };
};

pub const CheckBindingsError = error{
    AmbiguousBinding,
    ReservedBinding,
    DependencyBindsHandler,
    MissingExport,
    OutOfMemory,
};

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(ModuleIndex),
    module_list: std.ArrayList(Module),
    execution_order: []ModuleIndex,
    /// Detail of the last refusal that `checkBindings` returned.
    binding_refusal: ?BindingRefusal = null,

    /// Whether a top-level binding would overwrite a global that the runtime installs.
    pub const isReservedName = known_globals.isRuntimeGlobal;

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
        if (self.binding_refusal) |refusal| self.allocator.free(refusal.name);
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
        const entry_idx = try self.addModule(owned_path, owned_source, !prepared_eval);

        // Recursively discover dependencies
        try self.discoverDependencies(entry_idx, read_file, 0);

        // Topological sort
        try self.topologicalSort();
    }

    /// Add a module to the graph. Takes ownership of both path and source.
    /// A prepared-evaluation entry skips admission because its source was admitted earlier.
    fn addModule(
        self: *ModuleGraph,
        owned_path: []const u8,
        owned_source: []const u8,
        admit: bool,
    ) !ModuleIndex {
        const idx: ModuleIndex = @intCast(self.module_list.items.len);

        var ownership_transferred = false;
        errdefer if (!ownership_transferred) {
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
        };
        if (admit) try admitModule(self.allocator, owned_source, owned_path);

        try self.module_list.append(self.allocator, .{
            .path = owned_path,
            .source = owned_source,
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
                    const dep_idx = try self.addModule(resolved_path, dep_source, true);

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

    /// Format the last `checkBindings` refusal into `buffer`. Paths appear as the
    /// graph holds them. The text is empty when no refusal is recorded.
    pub fn bindingRefusalMessage(self: *const ModuleGraph, buffer: []u8) []const u8 {
        const refusal = self.binding_refusal orelse return "";
        const written = switch (refusal.kind) {
            .ambiguous => std.fmt.bufPrint(
                buffer,
                "Top-level name '{s}' is bound in both '{s}' and '{s}'. Modules share one namespace, so rename one binding.",
                .{ refusal.name, refusal.first_path, refusal.second_path },
            ),
            .reserved => std.fmt.bufPrint(
                buffer,
                "Top-level name '{s}' in '{s}' is a built-in global. Modules share one namespace with built-ins, so rename the binding.",
                .{ refusal.name, refusal.first_path },
            ),
            .dependency_handler => std.fmt.bufPrint(
                buffer,
                "Dependency '{s}' binds 'handler'. Only the entry file may bind 'handler', so rename the binding.",
                .{refusal.first_path},
            ),
            .missing_export => std.fmt.bufPrint(
                buffer,
                "Module '{s}' imports '{s}' from '{s}', but that module does not export '{s}' as a value. Use `import type` for a type.",
                .{ refusal.first_path, refusal.name, refusal.second_path, refusal.name },
            ),
        } catch return "Module bindings are refused.";
        return written;
    }

    /// Refuse a graph whose modules cannot share one global namespace. The
    /// modules of a graph run as one program: every top-level value binding
    /// is a global that the last module loaded wins, and built-ins live in
    /// the same namespace. Call this after `build` and before compilation. A
    /// graph without dependencies passes. `build` never calls it, because
    /// `packages/pi` reaches `build` and a new error there would change
    /// model-visible output. A module that fails to parse also passes here:
    /// compilation reports that parse error.
    ///
    /// Refused: two modules that bind one top-level value name, a module that
    /// binds a built-in global, a dependency that binds `handler`, and a named
    /// import that its target module does not export. Type declarations are
    /// not value bindings. Import bindings that name the identical export are
    /// one binding.
    pub fn checkBindings(self: *ModuleGraph) CheckBindingsError!void {
        if (self.binding_refusal) |refusal| self.allocator.free(refusal.name);
        self.binding_refusal = null;
        if (self.dependencyCount() == 0) return;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const facts = try arena.alloc(ModuleFacts, self.module_list.items.len);
        for (facts) |*fact| fact.* = .{};
        var owners = std.StringHashMap(Owner).init(arena);
        const entry_index = self.execution_order[self.execution_order.len - 1];

        for (self.execution_order) |module_index| {
            const module = &self.module_list.items[module_index];
            var atoms = atom_table_mod.AtomTable.init(self.allocator);
            defer atoms.deinit();
            var parser = try module.initParser(self.allocator);
            defer parser.deinit();
            parser.setAtomTable(&atoms);
            _ = module.parse(&parser) catch return;
            const view = zts_parser.IrView.fromIRStore(&parser.nodes, &parser.constants);

            const imports = try collectImports(arena, view, &atoms);
            const exports = try collectExports(arena, view, &atoms);
            facts[module_index].exports = exports;

            const importing_dir = file_resolver.dirName(module.path);
            for (imports) |import| {
                const target = try self.fileImportTarget(arena, import.specifier, importing_dir) orelse continue;
                if (!facts[target].exports.contains(import.imported)) {
                    return self.refuse(.missing_export, import.imported, module.path, self.module_list.items[target].path);
                }
            }

            const global_scope = parser.scopes.getScope(0);
            for (global_scope.bindings.items) |binding| {
                const name = try arena.dupe(u8, binding.name);
                if (known_globals.isRuntimeGlobal(name)) return self.refuse(.reserved, name, module.path, "");
                if (module_index != entry_index and std.mem.eql(u8, name, "handler")) {
                    return self.refuse(.dependency_handler, name, module.path, "");
                }
                const identity = try self.bindingIdentity(arena, module.path, name, imports, importing_dir);
                const gop = try owners.getOrPut(name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .identity = identity, .path = module.path };
                } else if (!std.mem.eql(u8, gop.value_ptr.identity, identity)) {
                    return self.refuse(.ambiguous, name, gop.value_ptr.path, module.path);
                }
            }
        }
    }

    /// The identity of a top-level binding. Two bindings with the same identity
    /// are one binding: the module that defines an export, and each module
    /// that imports that export under its own name.
    fn bindingIdentity(
        self: *const ModuleGraph,
        arena: std.mem.Allocator,
        module_path: []const u8,
        name: []const u8,
        imports: []const ImportEntry,
        importing_dir: []const u8,
    ) CheckBindingsError![]const u8 {
        for (imports) |import| {
            if (!std.mem.eql(u8, import.local, name)) continue;
            const owner_path: []const u8 = if (try self.fileImportTarget(arena, import.specifier, importing_dir)) |target|
                self.module_list.items[target].path
            else
                import.specifier;
            return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ owner_path, import.imported });
        }
        return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ module_path, name });
    }

    /// A file import of one module, with the module that it names.
    pub const FileImportLink = struct {
        /// The specifier as written in the importing module.
        specifier: []const u8,
        /// The name of the export.
        imported: []const u8,
        /// The index in `module_list` of the target module, or null when the
        /// specifier names no module of the graph.
        target: ?ModuleIndex,
    };

    /// Every file import of the module whose parsed IR is `view`, resolved to
    /// the module it targets by the rule that `checkBindings` uses. A virtual
    /// import is left out. Strings are copied into `arena`.
    pub fn fileImportLinks(
        self: *const ModuleGraph,
        arena: std.mem.Allocator,
        importing_path: []const u8,
        view: zts_parser.IrView,
        atoms: *atom_table_mod.AtomTable,
    ) CheckBindingsError![]const FileImportLink {
        const imports = try collectImports(arena, view, atoms);
        const importing_dir = file_resolver.dirName(importing_path);
        var links = std.ArrayList(FileImportLink).empty;
        for (imports) |import| {
            switch (resolver.resolve(import.specifier)) {
                .file => {},
                .virtual, .unknown => continue,
            }
            try links.append(arena, .{
                .specifier = import.specifier,
                .imported = import.imported,
                .target = try self.fileImportTarget(arena, import.specifier, importing_dir),
            });
        }
        return links.items;
    }

    /// The module that a file import names, or null for a virtual or unknown specifier.
    fn fileImportTarget(
        self: *const ModuleGraph,
        arena: std.mem.Allocator,
        specifier: []const u8,
        importing_dir: []const u8,
    ) CheckBindingsError!?ModuleIndex {
        const file_specifier = switch (resolver.resolve(specifier)) {
            .file => |file| file,
            .virtual, .unknown => return null,
        };
        const resolved = file_resolver.resolve(arena, file_specifier, importing_dir, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return self.modules.get(resolved);
    }

    fn refuse(
        self: *ModuleGraph,
        kind: BindingRefusal.Kind,
        name: []const u8,
        first_path: []const u8,
        second_path: []const u8,
    ) CheckBindingsError {
        self.binding_refusal = .{
            .kind = kind,
            .name = try self.allocator.dupe(u8, name),
            .first_path = first_path,
            .second_path = second_path,
        };
        return switch (kind) {
            .ambiguous => error.AmbiguousBinding,
            .reserved => error.ReservedBinding,
            .dependency_handler => error.DependencyBindsHandler,
            .missing_export => error.MissingExport,
        };
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
// Binding check support
// ============================================================================

const ImportEntry = struct {
    local: []const u8,
    imported: []const u8,
    specifier: []const u8,
};

const ModuleFacts = struct {
    exports: std.StringHashMapUnmanaged(void) = .empty,
};

const Owner = struct {
    identity: []const u8,
    path: []const u8,
};

fn atomName(atom_index: u16, atoms: *atom_table_mod.AtomTable) ?[]const u8 {
    const atom: object.Atom = @fromBackingInt(@intCast(atom_index));
    if (atom.isPredefined()) return atom.toPredefinedName();
    return atoms.getName(atom);
}

/// Every named import of a module, with strings copied into `arena`.
fn collectImports(
    arena: std.mem.Allocator,
    view: zts_parser.IrView,
    atoms: *atom_table_mod.AtomTable,
) std.mem.Allocator.Error![]const ImportEntry {
    var entries = std.ArrayList(ImportEntry).empty;
    for (0..view.nodeCount()) |index| {
        const tag = view.getTag(@intCast(index)) orelse continue;
        if (tag != .import_decl) continue;
        const decl = view.getImportDecl(@intCast(index)) orelse continue;
        const specifier = view.getString(decl.module_idx) orelse continue;
        for (0..decl.specifiers_count) |position| {
            const spec_index = view.getListIndex(decl.specifiers_start, @intCast(position));
            const spec = view.getImportSpec(spec_index) orelse continue;
            const imported = atomName(spec.imported_atom, atoms) orelse continue;
            const local = atomName(spec.local_binding.name_atom, atoms) orelse continue;
            try entries.append(arena, .{
                .local = try arena.dupe(u8, local),
                .imported = try arena.dupe(u8, imported),
                .specifier = try arena.dupe(u8, specifier),
            });
        }
    }
    return entries.items;
}

/// The names that a module exports: `export function` and `export const`.
fn collectExports(
    arena: std.mem.Allocator,
    view: zts_parser.IrView,
    atoms: *atom_table_mod.AtomTable,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (0..view.nodeCount()) |index| {
        const tag = view.getTag(@intCast(index)) orelse continue;
        if (tag != .export_decl) continue;
        const decl = view.getExportDecl(@intCast(index)) orelse continue;
        if (decl.declaration == zts_parser.null_node) continue;
        const declaration_tag = view.getTag(decl.declaration) orelse continue;
        switch (declaration_tag) {
            .function_decl, .var_decl => {},
            else => continue,
        }
        const var_decl = view.getVarDecl(decl.declaration) orelse continue;
        const name = atomName(var_decl.binding.name_atom, atoms) orelse continue;
        try names.put(arena, try arena.dupe(u8, name), {});
    }
    return names;
}

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    CircularImport,
    AmbiguousBinding,
    ReservedBinding,
    DependencyBindsHandler,
    MissingExport,
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
    // Force growth through allocations so SafeAllocator remapping cannot skip a fault index.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), Context.run, .{});
}

test "graph refuses every hard admission producer" {
    const cases = [_]struct { kind: zts_parser.type_syntax.AdmissionKind, err: anyerror, source: []const u8 }{
        .{ .kind = .any_type, .err = error.UnsupportedAnyType, .source = "import type { A } /* ; */ from \"./a\";\nconst value: any = 1;\n" },
        .{ .kind = .as_assertion, .err = error.UnsupportedAsAssertion, .source = "import type { A } /* ; */ from \"./a\";\nconst value = source as string;\n" },
        .{ .kind = .satisfies_assertion, .err = error.UnsupportedSatisfiesAssertion, .source = "import type { A } /* ; */ from \"./a\";\nconst value = source satisfies string;\n" },
        .{ .kind = .unterminated_string, .err = error.UnterminatedString, .source = "import type { A } /* ; */ from \"./a\";\nconst value = \"open\nconst after = 1;\n" },
        .{ .kind = .nominal_base_not_scalar, .err = error.NominalBaseNotScalar, .source = "import type { A } /* ; */ from \"./a\";\nnominal Box = T;\n" },
        .{ .kind = .interface_declaration, .err = error.InterfaceDeclaration, .source = "import type { A } /* ; */ from \"./a\";\ninterface Box { value: string }\n" },
        .{ .kind = .type_alias_declaration, .err = error.TypeAliasDeclaration, .source = "import type { A } /* ; */ from \"./a\";\ntype Box = string;\n" },
        .{ .kind = .distinct_type_declaration, .err = error.DistinctTypeDeclaration, .source = "import type { A } /* ; */ from \"./a\";\ndistinct type Box = string;\n" },
        .{ .kind = .retired_types_import, .err = error.LegacyTypesImport, .source = "import type { A } /* ; */ from \"./a\";\nimport type { Value } from '" ++ @import("zts-base").module_specifier.retired_types_module ++ "';\n" },
        .{ .kind = .default_parameter, .err = error.DefaultParameter, .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value = 1) { return value; }\n" },
        .{ .kind = .optional_parameter, .err = error.OptionalParameter, .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value?: string) { return value; }\n" },
        .{ .kind = .default_export, .err = error.DefaultExport, .source = "import type { A } /* ; */ from \"./a\";\nexport default 1;\n" },
        .{ .kind = .mutable_export, .err = error.MutableExport, .source = "import type { A } /* ; */ from \"./a\";\nexport let value = 1;\n" },
        .{ .kind = .array_type_alias, .err = error.ArrayTypeAlias, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = Array<string>;\n" },
        .{ .kind = .readonly_array_type_alias, .err = error.ReadonlyArrayTypeAlias, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = ReadonlyArray<string>;\n" },
        .{ .kind = .void_type, .err = error.VoidType, .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = void;\n" },
        .{ .kind = .nesting_too_deep, .err = error.NestingTooDeep, .source = "import type { A } /* ; */ from \"./a\";\nconst value: {{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{ string;\n" },
    };
    try std.testing.expectEqual(@typeInfo(zts_parser.type_syntax.AdmissionKind).@"enum".field_names.len, cases.len);
    var seen = std.EnumSet(zts_parser.type_syntax.AdmissionKind).empty;
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
        try std.testing.expectError(case.err, graph.build("entry.ts", case.source, Reader.read));
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
    try std.testing.expectError(error.UnterminatedComment, comment_graph.build("entry.ts", "/* unfinished\n", Reader.read));
    var virtual = ModuleGraph.init(std.testing.allocator);
    defer virtual.deinit();
    try std.testing.expectError(error.UnsupportedSourceExtension, virtual.build("<virtual>", "const value: any = 1;", Reader.read));
    const accepted_contrasts = [_][]const u8{
        "const marker: \"open\n = \"open\"; export const value = 1;\n",
        "const value: number = ;\n",
    };
    for (accepted_contrasts) |source| {
        var graph = ModuleGraph.init(std.testing.allocator);
        defer graph.deinit();
        try graph.build("entry.ts", source, Reader.read);
        try std.testing.expectEqual(@as(usize, 1), graph.module_list.items.len);
    }
    var unsupported = ModuleGraph.init(std.testing.allocator);
    defer unsupported.deinit();
    try std.testing.expectError(error.UnsupportedSourceExtension, unsupported.build("entry.js", "", Reader.read));
}

test "graph refuses an imported module with an unterminated comment" {
    const Reader = struct {
        fn read(allocator: std.mem.Allocator, _: []const u8) ReadFileError![]const u8 {
            return allocator.dupe(u8, "export const value = 1; /* open") catch return error.OutOfMemory;
        }
    };
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try std.testing.expectError(
        error.UnterminatedComment,
        graph.build("entry.ts", "import { value } from \"./lib.ts\";\nexport const result = value;\n", Reader.read),
    );
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
    var module: Module = .{ .path = "entry.ts", .source = source, .dependencies = &.{}, .state = .unvisited };
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

// ============================================================================
// Binding checks
// ============================================================================

fn bindingsReadFile(allocator: std.mem.Allocator, path: []const u8) ReadFileError![]const u8 {
    const source: []const u8 = if (std.mem.endsWith(u8, path, "/a.ts"))
        "function label(): string { return \"a\"; }\nexport function fromA(): string { return label(); }\n"
    else if (std.mem.endsWith(u8, path, "/b.ts"))
        "function label(): string { return \"b\"; }\nexport function fromB(): string { return label(); }\n"
    else if (std.mem.endsWith(u8, path, "/utils.ts"))
        "export function greet(name: string): string { return name; }\nfunction hidden(): string { return \"h\"; }\n"
    else if (std.mem.endsWith(u8, path, "/user.ts"))
        "import { greet } from \"./utils.ts\";\nexport function hello(): string { return greet(\"a\"); }\n"
    else if (std.mem.endsWith(u8, path, "/types_a.ts"))
        "structural Box = { v: string };\nexport function fromTypesA(): string { return \"a\"; }\n"
    else if (std.mem.endsWith(u8, path, "/types_b.ts"))
        "structural Box = { v: string };\nexport function fromTypesB(): string { return \"b\"; }\n"
    else if (std.mem.endsWith(u8, path, "/env_user.ts"))
        "import { env } from \"zttp:env\";\nexport function readA(): string { return env(\"A\") ?? \"\"; }\n"
    else if (std.mem.endsWith(u8, path, "/other_env.ts"))
        "import { env } from \"zttp:other\";\nexport function readB(): string { return env(\"B\"); }\n"
    else if (std.mem.endsWith(u8, path, "/res.ts"))
        "function Response(): string { return \"x\"; }\nexport function fromRes(): string { return Response(); }\n"
    else if (std.mem.endsWith(u8, path, "/dep_handler.ts"))
        "export function handler(req: Request): Response { return Response.text(\"d\"); }\n"
    else
        return error.FileNotFound;

    return allocator.dupe(u8, source) catch return error.OutOfMemory;
}

fn buildBindingsGraph(graph: *ModuleGraph, entry_source: []const u8) !void {
    try graph.build("/app/h.ts", entry_source, bindingsReadFile);
}

test "checkBindings refuses two modules that bind one top-level name" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { fromA } from \"./a.ts\";\nimport { fromB } from \"./b.ts\";\nexport function handler(req: Request): Response { return Response.text(fromA()); }\n");

    try std.testing.expectError(error.AmbiguousBinding, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqual(BindingRefusal.Kind.ambiguous, refusal.kind);
    try std.testing.expectEqualStrings("label", refusal.name);
    try std.testing.expectEqualStrings("/app/a.ts", refusal.first_path);
    try std.testing.expectEqualStrings("/app/b.ts", refusal.second_path);
}

test "checkBindings words the ambiguous binding refusal" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { fromA } from \"./a.ts\";\nimport { fromB } from \"./b.ts\";\nexport function handler(req: Request): Response { return Response.text(fromA()); }\n");

    try std.testing.expectError(error.AmbiguousBinding, graph.checkBindings());
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Top-level name 'label' is bound in both '/app/a.ts' and '/app/b.ts'. Modules share one namespace, so rename one binding.",
        graph.bindingRefusalMessage(&buffer),
    );
}

test "checkBindings refuses an import alias that another module binds" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { greet as label } from \"./utils.ts\";\nimport { fromA } from \"./a.ts\";\nexport function handler(req: Request): Response { return Response.text(label(\"x\")); }\n");

    try std.testing.expectError(error.AmbiguousBinding, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqualStrings("label", refusal.name);
    try std.testing.expectEqualStrings("/app/a.ts", refusal.first_path);
    try std.testing.expectEqualStrings("/app/h.ts", refusal.second_path);
}

test "checkBindings accepts two modules that import the identical export" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { greet } from \"./utils.ts\";\nimport { hello } from \"./user.ts\";\nexport function handler(req: Request): Response { return Response.text(greet(hello())); }\n");

    try graph.checkBindings();
    try std.testing.expect(graph.binding_refusal == null);
}

test "checkBindings accepts an import of the export that a module binds" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { greet } from \"./utils.ts\";\nexport function handler(req: Request): Response { return Response.text(greet(\"x\")); }\n");

    try graph.checkBindings();
    try std.testing.expect(graph.binding_refusal == null);
}

test "checkBindings ignores type declarations of one name" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { fromTypesA } from \"./types_a.ts\";\nimport { fromTypesB } from \"./types_b.ts\";\nexport function handler(req: Request): Response { return Response.text(fromTypesA()); }\n");

    try graph.checkBindings();
    try std.testing.expect(graph.binding_refusal == null);
}

test "checkBindings accepts one virtual export imported by two modules" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { env } from \"zttp:env\";\nimport { readA } from \"./env_user.ts\";\nexport function handler(req: Request): Response { return Response.text(readA()); }\n");

    try graph.checkBindings();
    try std.testing.expect(graph.binding_refusal == null);
}

test "checkBindings refuses one local name for exports of two virtual modules" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { env } from \"zttp:env\";\nimport { readB } from \"./other_env.ts\";\nexport function handler(req: Request): Response { return Response.text(readB()); }\n");

    try std.testing.expectError(error.AmbiguousBinding, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqualStrings("env", refusal.name);
    try std.testing.expectEqualStrings("/app/other_env.ts", refusal.first_path);
    try std.testing.expectEqualStrings("/app/h.ts", refusal.second_path);
}

test "checkBindings refuses a dependency that binds a built-in global" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { fromRes } from \"./res.ts\";\nexport function handler(req: Request): Response { return Response.text(fromRes()); }\n");

    try std.testing.expectError(error.ReservedBinding, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqual(BindingRefusal.Kind.reserved, refusal.kind);
    try std.testing.expectEqualStrings("Response", refusal.name);
    try std.testing.expectEqualStrings("/app/res.ts", refusal.first_path);
}

test "checkBindings refuses an import alias that names a runtime global" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { greet as console } from \"./utils.ts\";\nexport function handler(req: Request): Response { return Response.text(console(\"x\")); }\n");

    try std.testing.expectError(error.ReservedBinding, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqualStrings("console", refusal.name);
    try std.testing.expectEqualStrings("/app/h.ts", refusal.first_path);
}

test "checkBindings words the reserved binding refusal" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { fromRes } from \"./res.ts\";\nexport function handler(req: Request): Response { return Response.text(fromRes()); }\n");

    try std.testing.expectError(error.ReservedBinding, graph.checkBindings());
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Top-level name 'Response' in '/app/res.ts' is a built-in global. Modules share one namespace with built-ins, so rename the binding.",
        graph.bindingRefusalMessage(&buffer),
    );
}

test "checkBindings refuses a dependency that binds handler" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { handler as inner } from \"./dep_handler.ts\";\nexport function handler(req: Request): Response { return inner(req); }\n");

    try std.testing.expectError(error.DependencyBindsHandler, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqual(BindingRefusal.Kind.dependency_handler, refusal.kind);
    try std.testing.expectEqualStrings("handler", refusal.name);
    try std.testing.expectEqualStrings("/app/dep_handler.ts", refusal.first_path);
}

test "checkBindings refuses an import that the target does not export" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { missing } from \"./utils.ts\";\nexport function handler(req: Request): Response { return Response.text(missing()); }\n");

    try std.testing.expectError(error.MissingExport, graph.checkBindings());
    const refusal = graph.binding_refusal.?;
    try std.testing.expectEqual(BindingRefusal.Kind.missing_export, refusal.kind);
    try std.testing.expectEqualStrings("missing", refusal.name);
    try std.testing.expectEqualStrings("/app/h.ts", refusal.first_path);
    try std.testing.expectEqualStrings("/app/utils.ts", refusal.second_path);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Module '/app/h.ts' imports 'missing' from '/app/utils.ts', but that module does not export 'missing' as a value. Use `import type` for a type.",
        graph.bindingRefusalMessage(&buffer),
    );
}

test "checkBindings refuses an import of a binding that the target does not export" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "import { hidden } from \"./utils.ts\";\nexport function handler(req: Request): Response { return Response.text(hidden()); }\n");

    try std.testing.expectError(error.MissingExport, graph.checkBindings());
    try std.testing.expectEqualStrings("hidden", graph.binding_refusal.?.name);
}

test "checkBindings accepts a graph without dependencies" {
    var graph = ModuleGraph.init(std.testing.allocator);
    defer graph.deinit();
    try buildBindingsGraph(&graph, "export function handler(req: Request): Response { return Response.text(\"x\"); }\n");

    try graph.checkBindings();
}
