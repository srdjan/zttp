//! Imported-file analysis for CHECK: the flow module graph and the imported
//! fault scan. The orchestrators that call these live in precompile.zig. The
//! flow modules of a handler with file imports come from the module graph
//! (`flowModulesForGraph`); the fault scan reads each file through its own
//! reader.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const ir = zts.parser;

const readFilePosix = zts.file_io.readFile;

/// Deepest chain of imports that the cross-file walk follows: the handler's
/// helper, the helper's own helper, and so on. A chain past this stays
/// unresolved, which fails closed.
pub const max_import_depth = 8;

/// Where the bytes of an imported file come from. A null reader means the
/// working tree (`readFilePosix`). A caller that analyzes a revision other than
/// the working tree passes a reader that serves that revision, so a helper is
/// read at the same revision as the handler that imports it. A read failure of
/// any kind is the same answer as an unreadable file: the existing blocked or
/// unresolved verdict. The reader owns its own size cap.
pub const ImportReader = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
};

/// One imported file, read, prepared, parsed, and reduced to its module facts.
/// The import walkers (`scanImportedFileTree` for fault coverage and
/// `scanSource`) start here, so a change to how an imported file is loaded is
/// one change.
///
/// Initialize in place with `load`. The parser holds a pointer to `atoms`, so
/// the struct must not move after `load`.
pub const ImportedFile = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    source_owner: zts.DirectCheckSource,
    root: ir.NodeIndex,
    view: zts.IrView,
    module_facts: zts.pipeline.ModuleFacts,

    /// Every read, admission, parse, validation, or facts failure is `Unreadable`.
    /// Neither caller distinguishes these failures. Allocation failure retains
    /// this projection. Failed loading leaves no valid object for `deinit`.
    pub fn load(
        self: *ImportedFile,
        allocator: std.mem.Allocator,
        reader: ?ImportReader,
        path: []const u8,
    ) error{Unreadable}!void {
        const source = (if (reader) |r|
            r.read(r.context, allocator, path)
        else
            readFilePosix(allocator, path, 10 * 1024 * 1024)) catch return error.Unreadable;
        errdefer allocator.free(source);
        try self.loadOwned(allocator, source, path);
    }

    /// Parse source the caller already holds. On success the file owns `source`
    /// (allocated with `allocator`); on failure the caller still owns it.
    pub fn loadOwned(
        self: *ImportedFile,
        allocator: std.mem.Allocator,
        source: []u8,
        path: []const u8,
    ) error{Unreadable}!void {
        self.allocator = allocator;
        self.source = source;
        self.source_owner.initCompileInPlace(allocator, allocator, self.source, path) catch return error.Unreadable;
        errdefer self.source_owner.deinit();
        const parsed = zts.parsedModuleFromDirectCheck(&self.source_owner) orelse return error.Unreadable;
        self.root = parsed.root;
        self.view = parsed.ir_view;
        self.module_facts = zts.pipeline.buildModuleFacts(
            allocator,
            parsed,
            null,
        ) catch return error.Unreadable;
    }

    pub fn deinit(self: *ImportedFile) void {
        self.module_facts.deinit();
        self.source_owner.deinit();
        self.allocator.free(self.source);
    }
};

/// The result of parsing one file without checking it: whether it has a
/// top-level `handler` function, and the paths of its relative imports as CHECK
/// resolves them (`resolveCheckImportPath`, the same rule both traversals use).
/// The same file is `error.Unparseable` here exactly when `ImportedFile.load`
/// cannot load it, so an edge listed here is an edge CHECK follows.
pub const SourceScan = struct {
    has_handler: bool,
    /// Owned by the allocator that `scanSource` received. Duplicates removed.
    imports: []const []const u8,

    pub fn deinit(self: *SourceScan, allocator: std.mem.Allocator) void {
        for (self.imports) |path| allocator.free(path);
        allocator.free(self.imports);
    }
};

/// Parse `source` (as the file at `path`) and list its relative imports. No
/// type check, strict pass, or CHECK runs. Any admission or parse failure is
/// `Unparseable`: the edges of that file are unknown.
pub fn scanSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
) error{ OutOfMemory, Unparseable }!SourceScan {
    const owned = try allocator.dupe(u8, source);
    errdefer allocator.free(owned);
    var file: ImportedFile = undefined;
    file.loadOwned(allocator, owned, path) catch return error.Unparseable;
    defer file.deinit();

    const base_dir = std.fs.path.dirname(path) orelse ".";
    var found: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (found.items) |item| allocator.free(item);
        found.deinit(allocator);
    }
    for (file.module_facts.imports.items) |rec| {
        if (rec.resolution != .unresolved) continue;
        if (!isRelativeSpecifier(rec.module_specifier)) continue;
        const target = try resolveCheckImportPath(allocator, base_dir, rec.module_specifier);
        errdefer allocator.free(target);
        var seen = false;
        for (found.items) |item| {
            if (std.mem.eql(u8, item, target)) seen = true;
        }
        if (seen) {
            allocator.free(target);
            continue;
        }
        try found.append(allocator, target);
    }
    return .{
        .has_handler = zts.findHandlerFunction(file.view, file.root) != null,
        .imports = try found.toOwnedSlice(allocator),
    };
}

/// The modules that the flow checker follows, with the import edges between
/// them and their initialization order. The entry is module 0 and borrows the
/// parser of the caller. A module graph supplies the other modules from the
/// parsers that code generation kept (`flowModulesForGraph`). Each capture table
/// and import edge stays owned until deinit.
pub const FlowModuleGraph = struct {
    allocator: std.mem.Allocator,
    views: std.ArrayList(zts.pipeline.FlowModuleView) = .empty,
    initialization_order: std.ArrayList(zts.pipeline.FlowModuleId) = .empty,
    /// The effects of the imports of the entry. Empty for a single module.
    imported_effects: std.ArrayList(zts.pipeline.ImportedEffect) = .empty,
    /// Capture tables of the graph modules that `fromModuleGraph` borrows; this owns them.
    graph_captures: std.ArrayList(*zts.pipeline.FlowCaptureTable) = .empty,
    root_path: []u8,
    root_captures: *zts.pipeline.FlowCaptureTable,
    /// An import with no module to follow must not turn an unvisited module
    /// initializer into evidence that it is clean.
    complete: bool = true,

    fn init(allocator: std.mem.Allocator, parsed: zts.pipeline.ParsedModule, source: []const u8, path: []const u8) !FlowModuleGraph {
        const atoms = parsed.atoms orelse return error.MissingFlowAtoms;
        const scopes = parsed.scopes orelse return error.MissingFlowScopes;
        const resolved = try std.fs.path.resolve(allocator, &.{path});
        errdefer allocator.free(resolved);
        const captures = try allocator.create(zts.pipeline.FlowCaptureTable);
        errdefer allocator.destroy(captures);
        captures.* = try zts.pipeline.FlowCaptureTable.init(allocator, scopes);
        errdefer captures.deinit();
        var graph: FlowModuleGraph = .{ .allocator = allocator, .root_path = resolved, .root_captures = captures };
        errdefer graph.views.deinit(allocator);
        var revision: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &revision, .{});
        try graph.views.append(allocator, .{
            .id = 0,
            .path = resolved,
            .revision = revision,
            .root = parsed.root,
            .ir_view = parsed.ir_view,
            .atoms = atoms,
            .captures = captures,
            .imports = &.{},
        });
        return graph;
    }

    pub fn deinit(self: *FlowModuleGraph) void {
        const allocator = self.allocator;
        for (self.views.items) |view| allocator.free(view.imports);
        self.views.deinit(allocator);
        self.initialization_order.deinit(allocator);
        self.imported_effects.deinit(allocator);
        for (self.graph_captures.items) |table| {
            table.deinit();
            allocator.destroy(table);
        }
        self.graph_captures.deinit(allocator);
        self.root_captures.deinit();
        allocator.destroy(self.root_captures);
        allocator.free(self.root_path);
    }

    fn finishModule(self: *FlowModuleGraph, id: zts.pipeline.FlowModuleId, targets: []const zts.pipeline.FlowImportTarget) !void {
        self.views.items[id].imports = try self.allocator.dupe(zts.pipeline.FlowImportTarget, targets);
        try self.initialization_order.append(self.allocator, id);
    }
};

/// The flow modules of one loaded module graph, each module once.
///
/// The entry is module 0 and each dependency takes the id of its position in
/// `execution_order` plus one. The views borrow the parsers of `compile_result`,
/// so no file is read again. The initialization order follows `execution_order`,
/// which lists a shared dependency once. A target that the flow evaluator cannot
/// follow (a data export, a bare specifier) leaves `complete` false, the same
/// rule that `flowModulesForSingleModule` applies.
pub fn flowModulesForGraph(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    atoms: *zts.AtomTable,
) !FlowModuleGraph {
    const count = compile_result.modules.len;
    const entry_position = count - 1;
    const entry_module = &graph.module_list.items[graph.execution_order[entry_position]];
    var entry_parsed = zts.pipeline.ParsedModule.fromExisting(
        zts.IrView.fromIRStore(&compile_result.parsers[entry_position].nodes, &compile_result.parsers[entry_position].constants),
        compile_result.modules[entry_position].root,
        atoms,
    );
    entry_parsed.scopes = &compile_result.parsers[entry_position].scopes;
    var flow = try FlowModuleGraph.init(allocator, entry_parsed, entry_module.source, entry_module.path);
    errdefer flow.deinit();

    for (0..entry_position) |position| {
        const module = &graph.module_list.items[graph.execution_order[position]];
        const parser = &compile_result.parsers[position];
        try flow.graph_captures.ensureUnusedCapacity(allocator, 1);
        try flow.views.ensureUnusedCapacity(allocator, 1);
        const captures = try allocator.create(zts.pipeline.FlowCaptureTable);
        errdefer allocator.destroy(captures);
        captures.* = try zts.pipeline.FlowCaptureTable.init(allocator, &parser.scopes);
        flow.graph_captures.appendAssumeCapacity(captures);
        var revision: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(module.source, &revision, .{});
        flow.views.appendAssumeCapacity(.{
            .id = flowIdAtPosition(position, entry_position),
            .path = module.path,
            .revision = revision,
            .root = compile_result.modules[position].root,
            .ir_view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants),
            .atoms = atoms,
            .captures = captures,
            .imports = &.{},
        });
    }

    for (0..count) |position| {
        const module = &graph.module_list.items[graph.execution_order[position]];
        const id = flowIdAtPosition(position, entry_position);
        const view = flow.views.items[id].ir_view;
        var facts = try zts.pipeline.buildModuleFacts(
            allocator,
            zts.pipeline.ParsedModule.fromExisting(view, flow.views.items[id].root, atoms),
            null,
        );
        defer facts.deinit();
        var targets: std.ArrayList(zts.pipeline.FlowImportTarget) = .empty;
        defer targets.deinit(allocator);
        for (facts.imports.items) |rec| {
            if (rec.resolution != .unresolved) continue;
            const specifier = switch (zts.modules.resolver.resolve(rec.module_specifier)) {
                .file => |file| file,
                .virtual, .unknown => {
                    flow.complete = false;
                    continue;
                },
            };
            const path = try zts.modules.file_resolver.resolve(
                allocator,
                specifier,
                zts.modules.file_resolver.dirName(module.path),
                null,
            );
            defer allocator.free(path);
            const target_index = graph.modules.get(path) orelse {
                flow.complete = false;
                continue;
            };
            const target_position = positionInOrder(graph, target_index) orelse {
                flow.complete = false;
                continue;
            };
            const target_id = flowIdAtPosition(target_position, entry_position);
            const function_node = importedFunctionNode(
                flow.views.items[target_id].ir_view,
                atoms,
                rec.imported_name,
            ) orelse {
                flow.complete = false;
                continue;
            };
            const key = importBindingKey(view, rec.slot) orelse {
                flow.complete = false;
                continue;
            };
            try targets.append(allocator, .{ .binding_key = key, .target = .{ .module = target_id, .node = function_node } });
        }
        try flow.finishModule(id, targets.items);
    }
    return flow;
}

fn flowIdAtPosition(position: usize, entry_position: usize) zts.pipeline.FlowModuleId {
    return if (position == entry_position) 0 else @intCast(position + 1);
}

fn positionInOrder(graph: *const zts.modules.ModuleGraph, module_index: zts.modules.module_graph.ModuleIndex) ?usize {
    for (graph.execution_order, 0..) |candidate, position| {
        if (candidate == module_index) return position;
    }
    return null;
}

/// The flow modules of a handler with no file import: the entry alone.
///
/// A handler with a file import goes through `flowModulesForGraph`, so this
/// function reads no file. An import that is neither a builtin nor resolved (a
/// bare specifier) has no module to follow, so `complete` is false. The
/// freestanding build has no module graph, so any import that is not a builtin
/// leaves `complete` false there. A production caller must first pass the root
/// admission, boolean, type, strict, and handler-selection gates of CHECK.
pub fn flowModulesForSingleModule(
    allocator: std.mem.Allocator,
    parsed: zts.pipeline.ParsedModule,
    source: []const u8,
    facts: *const zts.pipeline.ModuleFacts,
    handler_path: []const u8,
) !FlowModuleGraph {
    var graph = try FlowModuleGraph.init(allocator, parsed, source, handler_path);
    errdefer graph.deinit();
    for (facts.imports.items) |record| {
        if (comptime builtin.target.os.tag == .freestanding) {
            if (record.resolution != .builtin) graph.complete = false;
        } else {
            if (record.resolution == .unresolved) graph.complete = false;
        }
    }
    try graph.finishModule(0, &.{});
    return graph;
}

const importBindingKey = zts.pipeline.flowImportBindingKey;
const importedFunctionNode = zts.pipeline.flowExportedFunctionNode;

/// What the scan of the handler's imported files answered, one entry per
/// non-builtin import record, keyed by the record's local slot. The entries
/// borrow their strings from `strings`.
pub const ImportedFaultScan = struct {
    entries: std.ArrayList(zts.PathGenerator.ImportScanEntry) = .empty,
    strings: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ImportedFaultScan, allocator: std.mem.Allocator) void {
        for (self.strings.items) |s| allocator.free(s);
        self.strings.deinit(allocator);
        self.entries.deinit(allocator);
    }

    fn own(self: *ImportedFaultScan, allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        try self.strings.append(allocator, copy);
        return copy;
    }
};

/// Select the compiler's `.ts` default before either independent traversal
/// reads. Explicit paths keep their existing identity and reader calls.
pub fn resolveCheckImportPath(allocator: std.mem.Allocator, base_dir: []const u8, specifier: []const u8) error{OutOfMemory}![]const u8 {
    const normalized = try std.fs.path.resolve(allocator, &.{ base_dir, specifier });
    if (std.fs.path.extension(normalized).len != 0) return normalized;
    defer allocator.free(normalized);
    // The runtime loader joins the importer's directory with the specifier and
    // appends the probe extension (`file_resolver.resolve`). `normalized` is
    // already that join, so the extension is appended directly: passing it back
    // through `resolve` with an empty directory rooted a relative path (`/lib.ts`).
    return std.mem.concat(allocator, u8, &.{ normalized, ".ts" });
}

fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

/// Scan the files that the handler imports for failable calls, for fault
/// coverage (unit F2 of the R4 plan). A missing or partial answer would mean
/// "scanned clean". So this returns one entry for every import record of the
/// handler that is not a builtin, and every failure to reach a verdict is a
/// blocking entry, never an omitted one.
///
/// Returns null, never an empty list, on a freestanding build: the browser
/// analyzer has one source buffer and no filesystem, so no record has an answer.
///
/// A `./` or `../` import is resolved, read, stripped, parsed, and scanned as a
/// whole file, then every relative import of that file in turn. The visited
/// set holds the handler's own path first, so a cycle through the handler
/// ends without listing the handler's own sites (the generator scans those).
/// A partner record, a bare specifier, a file that cannot be resolved, read,
/// stripped, or parsed, and a chain past `max_import_depth` each give a
/// blocking entry.
pub fn collectImportedFailableCalls(
    allocator: std.mem.Allocator,
    facts: *const zts.pipeline.ModuleFacts,
    handler_path: []const u8,
    /// Where each imported file's bytes come from; null is the working tree.
    reader: ?ImportReader,
) error{OutOfMemory}!?ImportedFaultScan {
    if (comptime builtin.target.os.tag == .freestanding) return null;

    var out: ImportedFaultScan = .{};
    errdefer out.deinit(allocator);

    const handler_resolved = try std.fs.path.resolve(allocator, &.{handler_path});
    defer allocator.free(handler_resolved);
    const handler_dir = std.fs.path.dirname(handler_resolved) orelse ".";

    // The answer for a start file does not depend on which record names it, so
    // two names imported from one file share one scan.
    var memo: std.StringHashMapUnmanaged(zts.PathGenerator.ImportScan) = .empty;
    defer {
        var keys = memo.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        memo.deinit(allocator);
    }

    for (facts.imports.items) |rec| {
        const scan: zts.PathGenerator.ImportScan = switch (rec.resolution) {
            .builtin => continue,
            .partner => .{ .blocked = .{ .file = try out.own(allocator, rec.module_specifier), .reason = .partner } },
            .unresolved => blk: {
                if (!isRelativeSpecifier(rec.module_specifier)) {
                    break :blk .{ .blocked = .{ .file = try out.own(allocator, rec.module_specifier), .reason = .not_relative } };
                }
                const path = try resolveCheckImportPath(allocator, handler_dir, rec.module_specifier);
                defer allocator.free(path);
                if (memo.get(path)) |known| break :blk known;

                var visited: std.StringHashMapUnmanaged(void) = .empty;
                defer {
                    var keys = visited.keyIterator();
                    while (keys.next()) |key| allocator.free(key.*);
                    visited.deinit(allocator);
                }
                try visited.ensureUnusedCapacity(allocator, 1);
                visited.putAssumeCapacityNoClobber(try allocator.dupe(u8, handler_resolved), {});

                const result = try scanImportedFileTree(allocator, &out, &visited, path, rec.module_specifier, handler_dir, 1, reader);
                const key = try allocator.dupe(u8, path);
                errdefer allocator.free(key);
                try memo.put(allocator, key, result);
                break :blk result;
            },
        };
        try out.entries.append(allocator, .{ .slot = rec.slot, .scan = scan });
    }
    return out;
}

/// The name that the report gives a file: the path from the handler's
/// directory with a leading `./`, or the whole path when the file lies outside.
fn importedFileDisplay(
    allocator: std.mem.Allocator,
    out: *ImportedFaultScan,
    handler_dir: []const u8,
    path: []const u8,
) error{OutOfMemory}![]const u8 {
    if (path.len > handler_dir.len + 1 and
        std.mem.startsWith(u8, path, handler_dir) and
        path[handler_dir.len] == std.fs.path.sep)
    {
        const text = try allocator.print("./{s}", .{path[handler_dir.len + 1 ..]});
        defer allocator.free(text);
        return out.own(allocator, text);
    }
    return out.own(allocator, path);
}

/// Scan one file, then every relative import of it, for failable calls. The
/// first failable call or the first blocking cause ends the walk, so the answer
/// names one file. `display` is how the report names this file.
fn scanImportedFileTree(
    allocator: std.mem.Allocator,
    out: *ImportedFaultScan,
    visited: *std.StringHashMapUnmanaged(void),
    path: []const u8,
    display_in: []const u8,
    handler_dir: []const u8,
    depth: usize,
    reader: ?ImportReader,
) error{OutOfMemory}!zts.PathGenerator.ImportScan {
    const display = try out.own(allocator, display_in);
    const blocked = struct {
        fn at(file: []const u8, reason: zts.PathGenerator.BlockReason) zts.PathGenerator.ImportScan {
            return .{ .blocked = .{ .file = file, .reason = reason } };
        }
    }.at;

    // A file already on the walk is scanned, or being scanned, by the frame
    // that opened it. A whole-file scan is idempotent, so this loses nothing.
    if (visited.contains(path)) return .clean;
    if (depth >= max_import_depth) return blocked(display, .too_deep);
    try visited.ensureUnusedCapacity(allocator, 1);
    visited.putAssumeCapacityNoClobber(try allocator.dupe(u8, path), {});

    var file: ImportedFile = undefined;
    file.load(allocator, reader, path) catch return blocked(display, .unreadable);
    defer file.deinit();
    const module_facts = &file.module_facts;

    var sites: std.ArrayList(zts.PathGenerator.UnseenCall) = .empty;
    defer sites.deinit(allocator);
    zts.PathGenerator.scanImportedFile(allocator, file.view, module_facts.imports.items, &sites) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidIR => return blocked(display, .unreadable),
    };
    if (sites.items.len > 0) {
        return .{ .failable = .{
            .file = display,
            .module = sites.items[0].module,
            .func = sites.items[0].func,
        } };
    }

    const base_dir = std.fs.path.dirname(path) orelse ".";
    for (module_facts.imports.items) |rec| {
        switch (rec.resolution) {
            .builtin => continue,
            .partner => return blocked(try out.own(allocator, rec.module_specifier), .partner),
            .unresolved => {},
        }
        if (!isRelativeSpecifier(rec.module_specifier)) {
            return blocked(try out.own(allocator, rec.module_specifier), .not_relative);
        }
        const child = try resolveCheckImportPath(allocator, base_dir, rec.module_specifier);
        defer allocator.free(child);
        const child_display = try importedFileDisplay(allocator, out, handler_dir, child);
        const result = try scanImportedFileTree(allocator, out, visited, child, child_display, handler_dir, depth + 1, reader);
        switch (result) {
            .clean => {},
            .failable, .blocked => return result,
        }
    }
    return .clean;
}
