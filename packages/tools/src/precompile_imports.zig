//! Imported-file analysis for CHECK: the flow module graph, the imported
//! effect collection, and the imported fault scan. The orchestrators that call
//! these live in precompile.zig. D-006 binds the reader paths, calls, order,
//! and revision selection of both traversals, not this file placement.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const ir = zts.parser;

const readFilePosix = zts.file_io.readFile;

/// Deepest chain of imports that the cross-file walk follows: the handler's
/// helper, the helper's own helper, and so on. A chain past this stays
/// unresolved, which fails closed.
pub const max_import_depth = 8;

/// The files being summarized, outermost first. A file that imports itself,
/// directly or through others, finds its own path here and stays unresolved.
const ImportStack = struct {
    paths: [max_import_depth][]const u8 = undefined,
    len: usize = 0,

    fn contains(self: *const ImportStack, path: []const u8) bool {
        for (self.paths[0..self.len]) |open| {
            if (std.mem.eql(u8, open, path)) return true;
        }
        return false;
    }
};

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
/// Both import walkers (`scanImportedFileTree` for fault coverage and
/// `analyzeImportedFunction` for flow) start here, so a change to how an
/// imported file is loaded is one change.
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

/// Retains the exact source snapshots observed by CHECK's flow reader. Repeated
/// reads are deliberately not coalesced: a reader can serve a different nested
/// dependency revision even when two parent files have identical bytes.
/// Root parser storage remains borrowed from the caller; every helper parser,
/// atom table, capture table and import edge stays owned until deinit.
pub const FlowModuleGraph = struct {
    const Owned = struct {
        path: []u8,
        file: ImportedFile,
        captures: zts.pipeline.FlowCaptureTable,
        id: zts.pipeline.FlowModuleId,
    };

    allocator: std.mem.Allocator,
    views: std.ArrayList(zts.pipeline.FlowModuleView) = .empty,
    initialization_order: std.ArrayList(zts.pipeline.FlowModuleId) = .empty,
    /// Effects computed by this same traversal; using them must not reread
    /// imports or borrow the independent fault scan's revision selection.
    imported_effects: std.ArrayList(zts.pipeline.ImportedEffect) = .empty,
    owned: std.ArrayList(*Owned) = .empty,
    root_path: []u8,
    root_captures: *zts.pipeline.FlowCaptureTable,
    /// A failed load, type check, cycle, depth or finite-ID bound must not turn
    /// an unvisited module initializer into evidence that it is clean.
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
        for (self.owned.items) |owner| {
            owner.captures.deinit();
            owner.file.deinit();
            allocator.free(owner.path);
            allocator.destroy(owner);
        }
        self.owned.deinit(allocator);
        self.root_captures.deinit();
        allocator.destroy(self.root_captures);
        allocator.free(self.root_path);
    }

    fn load(self: *FlowModuleGraph, reader: ?ImportReader, path: []const u8) !?*Owned {
        if (self.views.items.len > std.math.maxInt(zts.pipeline.FlowModuleId)) {
            self.complete = false;
            return null;
        }
        const allocator = self.allocator;
        const owner = try allocator.create(Owned);
        errdefer allocator.destroy(owner);
        owner.path = try allocator.dupe(u8, path);
        errdefer allocator.free(owner.path);
        try owner.file.load(allocator, reader, owner.path);
        errdefer owner.file.deinit();
        owner.captures = try zts.pipeline.FlowCaptureTable.init(allocator, &owner.file.source_owner.parser.scopes);
        errdefer owner.captures.deinit();
        owner.id = @intCast(self.views.items.len);
        var revision: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(owner.file.source, &revision, .{});
        try self.owned.ensureUnusedCapacity(allocator, 1);
        try self.views.append(allocator, .{
            .id = owner.id,
            .path = owner.path,
            .revision = revision,
            .root = owner.file.root,
            .ir_view = owner.file.view,
            .atoms = &owner.file.source_owner.atoms,
            .captures = &owner.captures,
            .imports = &.{},
        });
        self.owned.appendAssumeCapacity(owner);
        return owner;
    }

    fn finishModule(self: *FlowModuleGraph, id: zts.pipeline.FlowModuleId, targets: []const zts.pipeline.FlowImportTarget) !void {
        self.views.items[id].imports = try self.allocator.dupe(zts.pipeline.FlowImportTarget, targets);
        try self.initialization_order.append(self.allocator, id);
    }
};

/// Retain the production flow traversal's parser and capture owners. The
/// fault reader remains independent, and explicit paths keep their read order.
/// Extensionless imports use the owner-approved compiler `.ts` selection.
/// A production caller must first pass CHECK's existing root admission,
/// boolean, type, strict and handler-selection gates. This loader does not
/// repeat or bypass those gates on the root source.
pub fn loadFlowModulesForCheck(
    allocator: std.mem.Allocator,
    parsed: zts.pipeline.ParsedModule,
    source: []const u8,
    facts: *const zts.pipeline.ModuleFacts,
    handler_path: []const u8,
    reader: ?ImportReader,
) !FlowModuleGraph {
    var graph = try FlowModuleGraph.init(allocator, parsed, source, handler_path);
    errdefer graph.deinit();
    var stack: ImportStack = .{};
    stack.paths[0] = graph.root_path;
    stack.len = 1;
    var analyses = try collectImportedAnalyses(allocator, facts, handler_path, &stack, reader, &graph, 0);
    defer analyses.deinit(allocator);
    try graph.finishModule(0, analyses.targets.items);
    graph.imported_effects = analyses.effects;
    analyses.effects = .empty;
    return graph;
}

/// The retained target and effect of one reader-selected imported export.
const ImportedFunctionAnalysis = struct {
    effect: zts.pipeline.ExportEffect = .blocked,
    target: ?zts.pipeline.FlowFunctionRef = null,
};

const ImportedFunctionAnalyses = struct {
    effects: std.ArrayList(zts.pipeline.ImportedEffect) = .empty,
    targets: std.ArrayList(zts.pipeline.FlowImportTarget) = .empty,

    fn deinit(self: *ImportedFunctionAnalyses, allocator: std.mem.Allocator) void {
        self.effects.deinit(allocator);
        self.targets.deinit(allocator);
    }
};

fn collectImportedAnalyses(
    allocator: std.mem.Allocator,
    facts: *const zts.pipeline.ModuleFacts,
    importer_path: []const u8,
    stack: *ImportStack,
    /// Where each imported file's bytes come from; null is the working tree.
    reader: ?ImportReader,
    graph: *FlowModuleGraph,
    importer: zts.pipeline.FlowModuleId,
) error{OutOfMemory}!ImportedFunctionAnalyses {
    var out: ImportedFunctionAnalyses = .{};
    errdefer out.deinit(allocator);
    // Browser analysis receives one source buffer and has no filesystem. Keep
    // the conservative empty answer while compiling the POSIX reader entirely
    // out of the freestanding build.
    if (comptime builtin.target.os.tag == .freestanding) {
        for (facts.imports.items) |record| {
            if (record.resolution != .builtin) graph.complete = false;
        }
        return out;
    }

    const base_dir = std.fs.path.dirname(importer_path) orelse ".";

    for (facts.imports.items) |rec| {
        if (rec.resolution != .unresolved) continue;
        if (!std.mem.startsWith(u8, rec.module_specifier, "./") and
            !std.mem.startsWith(u8, rec.module_specifier, "../"))
        {
            graph.complete = false;
            continue;
        }

        const path = try resolveCheckImportPath(allocator, base_dir, rec.module_specifier);
        defer allocator.free(path);

        const imported = try analyzeImportedFunction(
            allocator,
            path,
            rec.imported_name,
            stack,
            reader,
            graph,
        );
        try out.effects.append(allocator, .{ .slot = rec.slot, .effect = imported.effect });
        if (imported.target) |target| {
            // ImportRecord is slot-keyed, but the interpreter uses the actual
            // IR binding identity so a local with the same slot cannot match.
            const view = graph.views.items[importer].ir_view;
            if (importBindingKey(view, rec.slot)) |key|
                try out.targets.append(allocator, .{ .binding_key = key, .target = target })
            else
                graph.complete = false;
        }
    }
    return out;
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
/// coverage (unit F2 of the R4 plan). The polarity is the opposite of
/// `collectImportedAnalyses`: for the flow checker a missing entry is the
/// conservative answer, and here a missing or partial answer would mean
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

/// Load one imported export and preserve the existing nested read order and
/// type-failure stopping point. Effects use these same retained snapshots.
fn analyzeImportedFunction(
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    stack: *ImportStack,
    reader: ?ImportReader,
    graph: *FlowModuleGraph,
) error{OutOfMemory}!ImportedFunctionAnalysis {
    var result: ImportedFunctionAnalysis = .{};
    if (stack.len >= max_import_depth or stack.contains(path)) {
        graph.complete = false;
        return result;
    }
    stack.paths[stack.len] = path;
    stack.len += 1;
    defer stack.len -= 1;

    const retained_file = (graph.load(reader, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            graph.complete = false;
            return result;
        },
    }) orelse return result;
    const file = &retained_file.file;
    const view = file.view;
    const module_facts = &file.module_facts;

    var type_env_storage: zts.pipeline.TypeEnvStorage = .{};
    defer type_env_storage.deinit(allocator);
    var type_check_clean = true;
    const capabilities = file.source_owner.acceptedCapabilities() orelse return result;
    type_env_storage.initWithSource(allocator, .{ .direct = .{
        .store = capabilities.type_store,
        .ir_view = capabilities.ir_view,
        .atoms = capabilities.atoms,
    } }) catch {
        type_check_clean = false;
    };
    var type_checker: ?zts.TypeChecker = null;
    defer if (type_checker) |*checker| checker.deinit();
    if (type_check_clean) {
        if (type_env_storage.envPtr()) |type_env| {
            type_checker = zts.TypeChecker.init(allocator, view, capabilities.atoms, type_env);
            type_checker.?.scopes = &file.source_owner.parser.scopes;
            const type_errors = type_checker.?.check(file.root) catch blk: {
                type_check_clean = false;
                break :blk 0;
            };
            if (type_errors != 0) type_check_clean = false;
            if (type_check_clean) {
                type_checker.?.ensureHealthy() catch {
                    type_check_clean = false;
                };
            }
        }
    }

    // The helpers of this helper come first, so a call into one of them applies
    // that file's sinks and effects to this file. A failed type check stops
    // the collection early. Effects still inspect the loaded IR with every
    // nested file import blocked, without reading another file.
    var nested: ImportedFunctionAnalyses = if (type_check_clean)
        try collectImportedAnalyses(allocator, module_facts, path, stack, reader, graph, retained_file.id)
    else
        .{};
    defer nested.deinit(allocator);
    if (!type_check_clean) {
        for (module_facts.imports.items) |rec| {
            if (rec.resolution != .unresolved or !isRelativeSpecifier(rec.module_specifier)) continue;
            try nested.effects.append(allocator, .{ .slot = rec.slot, .effect = .blocked });
        }
    }

    if (type_check_clean) {
        const id = retained_file.id;
        try graph.finishModule(id, nested.targets.items);
        if (importedFunctionNode(view, capabilities.atoms, name)) |function_node|
            result.target = .{ .module = id, .node = function_node }
        else
            graph.complete = false;
    } else graph.complete = false;

    var effects = zts.EffectAnalyzer.init(allocator, view, capabilities.atoms);
    defer effects.deinit();
    effects.facts = module_facts;
    effects.type_source = if (type_check_clean)
        .{ .direct = type_env_storage.envPtr().? }
    else
        .omitted;
    effects.imported_effects = nested.effects.items;
    effects.analyze(file.root) catch return result;
    var exported = effects.exportEffects() catch return result;
    defer exported.deinit(allocator);
    result.effect = exported.lookup(name);
    return result;
}
