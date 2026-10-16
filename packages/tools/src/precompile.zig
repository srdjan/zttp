//! Build-time TypeScript/JavaScript precompiler
//!
//! Compiles handler files to bytecode at build time for embedding in the binary.
//! This eliminates runtime parsing overhead and removes the need for source files
//! in deployment.
//!
//! Usage: precompile [--verify] [--contract] [--sql-schema path] [--policy policy.json] <handler.ts> <output.zig>

const std = @import("std");
const builtin = @import("builtin");
const pcc = @import("zttp_proof_checker");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;
const ir = zts.parser;
const handler_contract = zts.handler_contract;
const writeContractJson = zts.writeContractJson;
const HandlerContract = zts.HandlerContract;
const VerificationInfo = handler_contract.VerificationInfo;
const handler_policy = zts.handler_policy;
const HandlerPolicy = zts.HandlerPolicy;
pub const json_diag = @import("json_diagnostics.zig");
const sqlite = zts.sqlite;
const util = @import("precompile_util.zig");
const retired_authority = @import("project_config").retired_authority;

const args_mod = @import("precompile_args.zig");
const PrecompileOptions = args_mod.PrecompileOptions;
const parsePrecompileArgSlice = args_mod.parsePrecompileArgSlice;
const collectModuleManifestPaths = args_mod.collectModuleManifestPaths;
const buildManifestRegistryFromPaths = args_mod.buildManifestRegistryFromPaths;
const collectArgs = args_mod.collectArgs;

const check_mod = @import("precompile_check.zig");
pub const CheckResult = check_mod.CheckResult;
pub const Stage = check_mod.Stage;
pub const StageSet = check_mod.StageSet;
pub const formatProofCard = check_mod.formatProofCard;
pub const generateTypeDefs = check_mod.generateTypeDefs;
const syncCheckResultProperties = check_mod.syncCheckResultProperties;
const appendSpecDiagnosticsJson = check_mod.appendSpecDiagnosticsJson;
pub const appendExportCapsuleDiagnostics = check_mod.appendExportCapsuleDiagnostics;
const appendCanonicalPublicHelperDiagnostics = check_mod.appendCanonicalPublicHelperDiagnostics;
const refreshSpecDiagnostics = check_mod.refreshSpecDiagnostics;

/// Stderr diagnostic print. On freestanding/wasm there is no stderr and
/// `std.debug.print` pulls a threaded IO stack that does not compile, so the
/// call is comptime-elided. Native builds behave exactly like `std.debug.print`.
fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.target.os.tag != .freestanding) {
        std.debug.print(fmt, args);
    }
}

/// Print a TypeScript strip failure with `file:line:column` and a remediation
/// message when the stripper supplied a structured diagnostic, falling back to
/// the bare error name when it did not (OOM and other location-free failures).
/// Render parse errors for a person: the ZTS code, `file:line:column`, the
/// source line, and an underline. Positions are translated out of the stripped
/// text into the file the author wrote. Caller owns the result.
fn renderParseErrors(
    allocator: std.mem.Allocator,
    view: zts.SourceView,
    errors: []const zts.ParseError,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try zts.DiagnosticProjection.writeParseErrors(view, errors, &aw.writer);
    return aw.toOwnedSlice();
}

/// Print `renderParseErrors` to stderr. A rendering failure falls back to the
/// position and message, so a parse failure is never reported as nothing.
fn printParseErrors(
    allocator: std.mem.Allocator,
    view: zts.SourceView,
    errors: []const zts.ParseError,
) void {
    if (renderParseErrors(allocator, view, errors)) |text| {
        defer allocator.free(text);
        debugPrint("{s}", .{text});
    } else |_| {
        for (errors) |parse_error| {
            debugPrint("{s}:{d}:{d}: {s}\n", .{
                view.name orelse "<source>",
                parse_error.location.line,
                parse_error.location.column,
                parse_error.message,
            });
        }
    }
}

fn debugPrintStripError(path: []const u8, err: anyerror, diag: ?zts.StripDiagnostic) void {
    if (diag) |d| {
        debugPrint("{s}:{d}:{d}: {s}\n", .{ path, d.line, d.column, d.kind.message() });
    } else {
        debugPrint("TypeScript strip error in {s}: {}\n", .{ path, err });
    }
}

const AotAnalysis = struct {
    dispatch: ?*zts.PatternDispatchTable = null,
    default_response: ?zts.HandlerAnalyzer.StaticResponseInfo = null,

    fn deinit(self: *AotAnalysis, allocator: std.mem.Allocator) void {
        if (self.dispatch) |dispatch| {
            dispatch.deinit();
            allocator.destroy(dispatch);
        }
        if (self.default_response) |resp| {
            if (resp.body.len > 0) {
                allocator.free(resp.body);
            }
        }
    }
};

pub const CompiledHandler = struct {
    bytecode: []const u8 = &.{},
    /// Set when handler verification fails. violations_jsonl/summary are populated
    /// with counterexample tests. No bytecode is generated.
    verify_failed: bool = false,
    /// Additional dependency module bytecodes (for file imports).
    /// Stored in execution order, entry module is NOT included.
    dep_bytecodes: ?[]const []const u8 = null,
    /// Contract manifest (when --contract is passed)
    contract: ?HandlerContract = null,
    /// Generated test JSONL (when a contract is emitted)
    generated_tests: ?[]const u8 = null,
    /// Counterexample tests for fault coverage violations (when violations exist)
    violations_jsonl: ?[]const u8 = null,
    /// Pre-formatted violations summary for build output (when violations exist)
    violations_summary: ?[]const u8 = null,
    /// Canonical proof IR plus the translation witnesses code generation and
    /// the optimizer recorded. Present only when the caller asked for it: the
    /// relation between an IR member and its final bytecode offsets exists only
    /// during compilation, so it is captured here or not at all.
    proof_evidence: ?zts.ProofEvidence = null,

    pub fn deinit(self: *CompiledHandler, allocator: std.mem.Allocator) void {
        if (self.proof_evidence) |*evidence| {
            evidence.deinit();
        }
        if (self.dep_bytecodes) |deps| {
            for (deps) |dep| {
                allocator.free(dep);
            }
            allocator.free(deps);
        }
        if (self.contract) |*c| {
            c.deinit(allocator);
        }
        if (self.generated_tests) |gt| {
            allocator.free(gt);
        }
        if (self.violations_jsonl) |vj| {
            allocator.free(vj);
        }
        if (self.violations_summary) |vs| {
            allocator.free(vs);
        }
        if (self.bytecode.len > 0) {
            allocator.free(self.bytecode);
        }
    }
};

const readFilePosix = zts.file_io.readFile;

/// Write a file synchronously using posix operations
pub const writeFilePosix = util.writeFilePosix;

/// Deepest chain of imports that the cross-file walk follows: the handler's
/// helper, the helper's own helper, and so on. A chain past this stays
/// unresolved, which fails closed.
const max_import_depth = 8;

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
/// `importedFunctionSummary` for flow) start here, so a change to how an
/// imported file is loaded is one change.
///
/// Initialize in place with `load`. The parser holds a pointer to `atoms`, so
/// the struct must not move after `load`.
const ImportedFile = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    source_owner: zts.DirectCheckSource,
    root: ir.NodeIndex,
    view: zts.IrView,
    module_facts: zts.pipeline.ModuleFacts,

    /// Every read, admission, parse, validation, or facts failure is `Unreadable`.
    /// Neither caller distinguishes these failures. Allocation failure retains
    /// this projection. Failed loading leaves no valid object for `deinit`.
    fn load(
        self: *ImportedFile,
        allocator: std.mem.Allocator,
        reader: ?ImportReader,
        path: []const u8,
    ) error{Unreadable}!void {
        self.allocator = allocator;
        self.source = (if (reader) |r|
            r.read(r.context, allocator, path)
        else
            readFilePosix(allocator, path, 10 * 1024 * 1024)) catch return error.Unreadable;
        errdefer allocator.free(self.source);

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

    fn deinit(self: *ImportedFile) void {
        self.module_facts.deinit();
        self.source_owner.deinit();
        self.allocator.free(self.source);
    }
};

/// Sink summaries for every function imported from a sibling file, keyed by the
/// local binding slot (plan unit F7). Each imported module is read and walked on
/// its own, and the modules it imports in turn are summarized first, so a sink
/// two files deep reaches the handler's call.
///
/// A failed flow summary stays absent, so the flow checker treats the call as
/// unresolved. Its effect entry stays present as blocked, so effects also fail
/// closed without a second file read.
const ImportedFunctionAnalysis = struct {
    summary: ?zts.pipeline.ImportedSummary = null,
    effect: zts.pipeline.ExportEffect = .blocked,

    fn deinit(self: *ImportedFunctionAnalysis, allocator: std.mem.Allocator) void {
        if (self.summary) |*summary| summary.deinit(allocator);
        self.summary = null;
    }
};

const ImportedFunctionAnalyses = struct {
    flow: std.ArrayList(zts.pipeline.ImportedFnSummary) = .empty,
    effects: std.ArrayList(zts.pipeline.ImportedEffect) = .empty,

    fn deinit(self: *ImportedFunctionAnalyses, allocator: std.mem.Allocator) void {
        for (self.flow.items) |*entry| entry.summary.deinit(allocator);
        self.flow.deinit(allocator);
        self.effects.deinit(allocator);
    }
};

fn collectImportedFnSummaries(
    allocator: std.mem.Allocator,
    facts: *const zts.pipeline.ModuleFacts,
    importer_path: []const u8,
    stack: *ImportStack,
    /// Where each imported file's bytes come from; null is the working tree.
    reader: ?ImportReader,
) error{OutOfMemory}!ImportedFunctionAnalyses {
    var out: ImportedFunctionAnalyses = .{};
    errdefer out.deinit(allocator);
    // Browser analysis receives one source buffer and has no filesystem. Keep
    // the conservative empty answer while compiling the POSIX reader entirely
    // out of the freestanding build.
    if (comptime builtin.target.os.tag == .freestanding) return out;

    const base_dir = std.fs.path.dirname(importer_path) orelse ".";

    for (facts.imports.items) |rec| {
        if (rec.resolution != .unresolved) continue;
        if (!std.mem.startsWith(u8, rec.module_specifier, "./") and
            !std.mem.startsWith(u8, rec.module_specifier, "../")) continue;

        const path = try std.fs.path.resolve(allocator, &.{ base_dir, rec.module_specifier });
        defer allocator.free(path);

        var imported = try importedFunctionSummary(
            allocator,
            path,
            rec.module_specifier,
            rec.imported_name,
            stack,
            reader,
        );
        defer imported.deinit(allocator);
        if (imported.summary) |summary| {
            try out.flow.append(allocator, .{ .slot = rec.slot, .summary = summary });
            imported.summary = null;
        }
        try out.effects.append(allocator, .{ .slot = rec.slot, .effect = imported.effect });
    }
    return out;
}

/// What the scan of the handler's imported files answered, one entry per
/// non-builtin import record, keyed by the record's local slot. The entries
/// borrow their strings from `strings`.
const ImportedFaultScan = struct {
    entries: std.ArrayList(zts.PathGenerator.ImportScanEntry) = .empty,
    strings: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ImportedFaultScan, allocator: std.mem.Allocator) void {
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

fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

/// Scan the files that the handler imports for failable calls, for fault
/// coverage (unit F2 of the R4 plan). The polarity is the opposite of
/// `collectImportedFnSummaries`: for the flow checker a missing entry is the
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
fn collectImportedFailableCalls(
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
                const path = try std.fs.path.resolve(allocator, &.{ handler_dir, rec.module_specifier });
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
        const text = try std.fmt.allocPrint(allocator, "./{s}", .{path[handler_dir.len + 1 ..]});
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
        const child = try std.fs.path.resolve(allocator, &.{ base_dir, rec.module_specifier });
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

/// Walk one imported file and answer its independent flow and effect results.
/// `specifier` is the importer's path spelling for flow diagnostics.
fn importedFunctionSummary(
    allocator: std.mem.Allocator,
    path: []const u8,
    specifier: []const u8,
    name: []const u8,
    stack: *ImportStack,
    reader: ?ImportReader,
) error{OutOfMemory}!ImportedFunctionAnalysis {
    var result: ImportedFunctionAnalysis = .{};
    errdefer result.deinit(allocator);
    if (stack.len >= max_import_depth or stack.contains(path)) return result;
    stack.paths[stack.len] = path;
    stack.len += 1;
    defer stack.len -= 1;

    var file: ImportedFile = undefined;
    file.load(allocator, reader, path) catch return result;
    defer file.deinit();
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
    // that file's sinks and effects to this file. A failed type check retains
    // the old early stop. Effects still inspect the loaded IR with every
    // nested file import blocked, without reading another file.
    var nested: ImportedFunctionAnalyses = if (type_check_clean)
        try collectImportedFnSummaries(allocator, module_facts, path, stack, reader)
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
        var flow = zts.FlowChecker.init(allocator, view, capabilities.atoms);
        defer flow.deinit();
        flow.facts = module_facts;
        if (type_checker) |*checker| flow.setTypeChecker(checker);
        for (nested.flow.items) |*entry| flow.setFileFunctionSummary(entry.slot, &entry.summary);

        result.summary = flow.exportedSummary(specifier, name) catch null;
        if (type_checker) |*checker| {
            checker.ensureHealthy() catch {
                if (result.summary) |*owned| owned.deinit(allocator);
                result.summary = null;
                type_check_clean = false;
            };
        }
    }

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

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (builtin.mode == .Debug) debug_alloc.allocator() else std.heap.smp_allocator;

    const argv = try collectArgs(allocator, init.args);
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    try runCompileWithArgs(allocator, argv[1..]);
}

pub fn runCompileWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = parsePrecompileArgSlice(argv) catch |err| {
        if (err == error.MissingArgument) return;
        return err;
    };

    // Partner virtual-module manifests (--module-manifest <path>, repeatable).
    // Read, parse, validate, and register before compilation. Failures here
    // fail loud: a malformed manifest must not silently compile to nothing.
    const manifest_paths = collectModuleManifestPaths(allocator, argv) catch |err| {
        if (err == error.MissingArgument) return;
        return err;
    };
    defer allocator.free(manifest_paths);

    var manifest_registry = if (manifest_paths.len > 0)
        try buildManifestRegistryFromPaths(allocator, manifest_paths)
    else
        zts.ManifestRegistry.init(allocator);
    defer manifest_registry.deinit();

    const registry_ptr: ?*const zts.ManifestRegistry =
        if (manifest_paths.len > 0) &manifest_registry else null;

    const handler_path_final = opts.handler_path;
    const output_path_final = opts.output_path;
    const emit_verify = opts.emit_verify;
    const emit_contract = opts.emit_contract;
    const sql_schema_path = opts.sql_schema_path;
    const policy_path = opts.policy_path;

    // Read the handler source file (using posix for synchronous I/O)
    const source = readFilePosix(allocator, handler_path_final, 10 * 1024 * 1024) catch |err| {
        debugPrint("Error reading handler file '{s}': {}\n", .{ handler_path_final, err });
        return err;
    };
    defer allocator.free(source);

    var policy: ?HandlerPolicy = null;
    defer if (policy) |*p| p.deinit(allocator);
    if (policy_path) |path| {
        const policy_source = readFilePosix(allocator, path, 1024 * 1024) catch |err| {
            debugPrint("Error reading policy file '{s}': {}\n", .{ path, err });
            return err;
        };
        defer allocator.free(policy_source);

        policy = handler_policy.parsePolicyJson(allocator, policy_source) catch |err| {
            debugPrint("Error parsing policy file '{s}': {}\n", .{ path, err });
            const help = handler_policy.policyErrorHelp(err);
            if (help.len > 0) debugPrint("{s}\n", .{help});
            return err;
        };
    }

    debugPrint("Compiling handler: {s} ({d} bytes)\n", .{ handler_path_final, source.len });

    // Compile the handler to bytecode (+ optional verification + optional contract)
    var compiled = compileHandler(allocator, source, handler_path_final, .{
        .emit_verify = emit_verify,
        .emit_contract = emit_contract,
        .policy = policy,
        .sql_schema_path = sql_schema_path,
        .manifest_registry = registry_ptr,
    }) catch |err| {
        debugPrint("Compilation failed: {}\n", .{err});
        return err;
    };
    defer compiled.deinit(allocator);

    var retired_facts: retired_authority.Facts = .{};
    if (compiled.contract) |*contract| retired_facts = retired_authority.contractFacts(contract);
    if (retired_authority.first(retired_facts)) |feature| {
        debugPrint("Precompile refused retired runtime authority: {s}\n", .{feature.sentence()});
        return error.UnsupportedRuntimeAuthority;
    }

    // Deferred verification failure: violations enriched with counterexamples, return error now.
    if (compiled.verify_failed) {
        if (compiled.violations_jsonl) |viol_jsonl| {
            const viol_path = deriveSiblingPath(allocator, output_path_final, "handler.violations.jsonl") catch |err| {
                debugPrint("Error deriving violations output path: {}\n", .{err});
                return error.VerificationFailed;
            };
            defer allocator.free(viol_path);
            writeFilePosix(viol_path, viol_jsonl, allocator) catch |err| {
                debugPrint("Error writing violations file '{s}': {}\n", .{ viol_path, err });
            };
            if (compiled.violations_summary) |summary| debugPrint("{s}", .{summary});
            debugPrint("  Counterexample tests written to: {s}\n", .{viol_path});
            debugPrint("  Run: zig build run -- {s} --test {s}\n", .{ output_path_final, viol_path });
        } else if (compiled.violations_summary) |summary| {
            debugPrint("{s}", .{summary});
        }
        return error.VerificationFailed;
    }

    debugPrint("Generated bytecode: {d} bytes\n", .{compiled.bytecode.len});

    // Write the output Zig file
    writeZigFile(output_path_final, compiled, policy, allocator) catch |err| {
        debugPrint("Error writing output file '{s}': {}\n", .{ output_path_final, err });
        return err;
    };

    debugPrint("Wrote embedded handler to: {s}\n", .{output_path_final});

    // Print sandbox report when auto-deriving from contract (no explicit policy)
    if (policy == null) {
        if (compiled.contract) |*contract| {
            printSandboxReport(contract);
        }
    }

    // Print handler effect properties
    if (compiled.contract) |*contract| {
        printPropertiesReport(contract);
    }

    if (compiled.contract) |*contract| {
        // Stamp the compiled-artifact hash so the runtime can verify the
        // embedded bytecode at boot against the contract it shipped with.
        std.crypto.hash.sha2.Sha256.hash(compiled.bytecode, &contract.artifact_sha256, .{});

        // Write contract.json alongside the output if requested
        if (emit_contract) {
            const contract_path = deriveSiblingPath(allocator, output_path_final, "contract.json") catch |err| {
                debugPrint("Error deriving contract path: {}\n", .{err});
                return err;
            };
            defer allocator.free(contract_path);

            var json_output: std.ArrayList(u8) = .empty;
            defer json_output.deinit(allocator);
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_output);

            writeContractJson(contract, &aw.writer) catch |err| {
                debugPrint("Error serializing contract: {}\n", .{err});
                return err;
            };
            json_output = aw.toArrayList();

            writeFilePosix(contract_path, json_output.items, allocator) catch |err| {
                debugPrint("Error writing contract file '{s}': {}\n", .{ contract_path, err });
                return err;
            };

            debugPrint("Wrote contract manifest to: {s}\n", .{contract_path});
        }

        // Write the generated tests. A contract build always generates them
        // to populate the behavioral paths.
        if (compiled.generated_tests) |tests_jsonl| {
            const tests_path = deriveSiblingPath(allocator, output_path_final, "handler.auto-tests.jsonl") catch |err| {
                debugPrint("Error deriving test output path: {}\n", .{err});
                return err;
            };
            defer allocator.free(tests_path);

            writeFilePosix(tests_path, tests_jsonl, allocator) catch |err| {
                debugPrint("Error writing generated tests '{s}': {}\n", .{ tests_path, err });
                return err;
            };

            debugPrint("Wrote generated tests to: {s}\n", .{tests_path});
        }

        // Write property violation counterexample tests and print unified summary.
        // violations_summary covers all analyzers (flow, verifier, fault coverage).
        // violations_jsonl is only present when fault-coverage counterexamples exist.
        if (compiled.violations_jsonl) |viol_jsonl| {
            const viol_path = deriveSiblingPath(allocator, output_path_final, "handler.violations.jsonl") catch |err| {
                debugPrint("Error deriving violations output path: {}\n", .{err});
                return err;
            };
            defer allocator.free(viol_path);

            writeFilePosix(viol_path, viol_jsonl, allocator) catch |err| {
                debugPrint("Error writing violations file '{s}': {}\n", .{ viol_path, err });
                return err;
            };

            if (compiled.violations_summary) |summary| {
                debugPrint("{s}", .{summary});
            }
            debugPrint("  Counterexample tests written to: {s}\n", .{viol_path});
            debugPrint("  Run: zig build run -- {s} --test {s}\n", .{ output_path_final, viol_path });
        } else if (compiled.violations_summary) |summary| {
            // Violations from flow or verifier analysis (no counterexample JSONL).
            debugPrint("{s}", .{summary});
        }
    }
}

/// Run the full analysis pipeline without generating bytecode.
/// Returns a CheckResult with all verification, contract, and coverage data.
pub const CheckOptions = struct {
    sql_schema_path: ?[]const u8 = null,
    json_mode: bool = false,
    skip_contract: bool = false,
    /// Capability policy JSON source. When present, the contract is validated
    /// against it and each violation becomes a coded POL diagnostic rather than
    /// the `error.PolicyViolation` the build path raises: a check reports, it
    /// does not abort. Null means no policy, which is what a project that
    /// declares none has, and the POL rules stay silent.
    policy_source: ?[]const u8 = null,
    /// Where the files the handler imports are read from. Null reads the
    /// working tree. A caller that checks a revision other than the working
    /// tree (the PR gate, for the base side) passes a reader for that
    /// revision, so a helper is analyzed at the revision of the handler that
    /// imports it. Borrowed for the call.
    import_reader: ?ImportReader = null,
};

pub fn runCheckOnly(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    sql_schema_path: ?[]const u8,
    json_mode: bool,
) !CheckResult {
    return runCheckOnlyWithOptions(allocator, handler_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = json_mode,
    });
}

/// Plain reason for the common handler-read failures. Any other error keeps
/// its Zig error name, so no failure is hidden. Only the text output uses
/// this: the `--json` message and the ZTS000 diagnostic keep `@errorName`.
fn readFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        else => @errorName(err),
    };
}

test "readFailureReason gives plain text for common read errors and keeps other names" {
    try std.testing.expectEqualStrings("no such file", readFailureReason(error.FileNotFound));
    try std.testing.expectEqualStrings("permission denied", readFailureReason(error.AccessDenied));
    try std.testing.expectEqualStrings("is a directory", readFailureReason(error.IsDir));
    try std.testing.expectEqualStrings("FileTooBig", readFailureReason(error.FileTooBig));
}

pub fn runCheckOnlyWithOptions(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    opts: CheckOptions,
) !CheckResult {
    const source = readFilePosix(allocator, handler_path, 10 * 1024 * 1024) catch |err| {
        if (!opts.json_mode) {
            debugPrint("Error reading handler file '{s}': {s}\n", .{ handler_path, readFailureReason(err) });
            return err;
        }
        // In JSON mode an unreadable handler must surface as a structured
        // ZTS000 diagnostic, not a raw Zig stack trace: IDE/CI callers parse
        // stdout and cannot read a propagated error. The CLI's existing
        // json_mode branch then renders writeErrorJson and exits 1.
        var result = CheckResult{};
        // errdefer frees `result` (and any owned diagnostic message) on every
        // error return below, so the catch arms only need to free state not yet
        // handed to `result`.
        errdefer result.deinit(allocator);
        const message = std.fmt.allocPrint(
            allocator,
            "cannot read handler file '{s}': {s}",
            .{ handler_path, @errorName(err) },
        ) catch {
            // Allocation failed: fall back to propagating the original error
            // rather than emitting an empty (and therefore misleading) JSON.
            return err;
        };
        result.json_diagnostics.append(allocator, .{
            .code = diagnostic_catalog.driverCode(.compiler_io_failure),
            .severity = "error",
            .message = message,
            .file = handler_path,
            .line = 0,
            .column = 0,
            .suggestion = null,
            .message_owned = true,
        }) catch {
            // `message` is not yet owned by `result`; free it here. `result`
            // itself is cleaned by the errdefer above.
            allocator.free(message);
            return err;
        };
        result.parse_errors = 1;
        return result;
    };
    defer allocator.free(source);
    return runCheckOnlyFromSourceWithOptions(allocator, source, handler_path, opts);
}

const PathAnalysis = struct {
    paths_enumerated: u32,
    paths_exhaustive: bool,
    behaviors_exhaustive: bool,
    /// Why coverage is or is not complete. A static string from
    /// `PathGenerator.Coverage.note`, so nothing owns it.
    paths_coverage_note: []const u8,
    max_io_depth: ?u32,
    cost_bounded: bool,
    cost_envelope: ?handler_contract.CostEnvelope,
    behaviors: std.ArrayList(handler_contract.BehaviorPath),
    fault_coverage: handler_contract.FaultCoverageInfo,
    fault_clean: bool,
    /// Where the first unseen failable call sits, when there is one. The
    /// snippet is the export name, a static string from the module binding.
    fault_unseen_cause: ?handler_contract.PropertyCause,
    /// The cause's snippet when it was allocated (it names an imported file).
    /// Whoever takes the cause for a contract moves this to the contract and
    /// sets it null; otherwise `deinit` frees it.
    fault_unseen_snippet_owned: ?[]const u8 = null,

    fn deinit(self: *PathAnalysis, allocator: std.mem.Allocator) void {
        if (self.fault_unseen_snippet_owned) |snippet| allocator.free(snippet);
        if (self.cost_envelope) |*envelope| envelope.deinit(allocator);
        for (self.behaviors.items) |*behavior| behavior.deinit(allocator);
        self.behaviors.deinit(allocator);
    }
};

fn analyzeHandlerPaths(
    state_allocator: std.mem.Allocator,
    output_allocator: std.mem.Allocator,
    ir_view: zts.IrView,
    atoms: *zts.AtomTable,
    module_facts: *const zts.pipeline.ModuleFacts,
    analysis_session: *zts.pipeline.ModuleAnalysisSession,
    handler_fn: ir.NodeIndex,
    handler_path: []const u8,
    include_behaviors: bool,
    import_reader: ?ImportReader,
) !PathAnalysis {
    // Fault coverage reads every file the handler imports, because a failable
    // call there is on no path of this handler. A null scan (no filesystem)
    // leaves each such import counted as unseen.
    var imported = try collectImportedFailableCalls(state_allocator, module_facts, handler_path, import_reader);
    defer if (imported) |*scan| scan.deinit(state_allocator);
    const path_effects = try analysis_session.pathEffectFacts();
    var generator = zts.PathGenerator.init(state_allocator, ir_view, atoms, path_effects);
    defer generator.deinit();
    // The CHECK analysis owner keeps these facts alive through path cleanup.
    generator.facts = module_facts;
    generator.setImportedScan(if (imported) |scan| scan.entries.items else null);
    try generator.generate(handler_fn);

    var analysis = try summarizeGeneratedPaths(output_allocator, &generator, include_behaviors);
    errdefer analysis.deinit(output_allocator);
    const tests = generator.getTests();

    var checker = zts.FaultCoverageChecker.init(output_allocator, tests);
    defer checker.deinit();
    try checker.analyze();
    const stamp = try stampFaultCoverage(output_allocator, ir_view, &generator, &checker);
    analysis.fault_coverage = stamp.coverage;
    analysis.fault_clean = stamp.clean;
    analysis.fault_unseen_cause = stamp.unseen_cause;
    analysis.fault_unseen_snippet_owned = stamp.unseen_snippet_owned;
    return analysis;
}

/// The fault coverage facts of one generated path set: the record the contract
/// carries, the `fault_covered` property bit, and the cause of the first unseen
/// call. The check path and the compile path both take them from here, so the
/// record, the property, and the cause cannot disagree between the two.
const FaultStamp = struct {
    coverage: handler_contract.FaultCoverageInfo,
    clean: bool,
    /// Where the first unseen failable call sits, when there is one. The
    /// snippet is the export name (a static string from the module binding) or
    /// the allocation in `unseen_snippet_owned`.
    unseen_cause: ?handler_contract.PropertyCause,
    /// The cause's snippet when it was allocated (it names an imported file).
    /// Whoever takes the cause moves it and sets this null; otherwise the
    /// caller frees it.
    unseen_snippet_owned: ?[]const u8,

    fn deinit(self: *FaultStamp, allocator: std.mem.Allocator) void {
        if (self.unseen_snippet_owned) |snippet| allocator.free(snippet);
        self.unseen_snippet_owned = null;
    }
};

/// Read the fault facts from a generator and a checker that already ran
/// `analyze` over the generator's tests.
fn stampFaultCoverage(
    output_allocator: std.mem.Allocator,
    ir_view: zts.IrView,
    generator: *zts.PathGenerator,
    checker: *const zts.FaultCoverageChecker,
) !FaultStamp {
    const report = checker.getReport();
    const unseen = generator.unseenFailableCalls();
    const analysis_complete = generator.faultAnalysisComplete();
    var stamp = FaultStamp{
        .coverage = .{
            .total_failable = report.total_failable,
            .covered = report.covered,
            .warnings = report.warning_count,
            .unseen_calls = @intCast(unseen.len),
            .upstream_fallback_sites = report.upstream_fallback_sites,
            .analysis_complete = analysis_complete,
        },
        .clean = report.isClean() and analysis_complete,
        .unseen_cause = null,
        .unseen_snippet_owned = null,
    };
    if (unseen.len > 0) {
        const loc = if (unseen[0].node == ir.null_node) null else ir_view.getLoc(unseen[0].node);
        const described = try unseen[0].describe(output_allocator);
        if (described.owned) stamp.unseen_snippet_owned = described.text;
        stamp.unseen_cause = .{
            .line = if (loc) |l| l.line else 0,
            .column = if (loc) |l| l.column else 0,
            .snippet = described.text,
        };
    }
    return stamp;
}

/// Summarize paths already generated by the caller. Fault analysis stays local.
fn summarizeGeneratedPaths(
    output_allocator: std.mem.Allocator,
    generator: *zts.PathGenerator,
    include_behaviors: bool,
) !PathAnalysis {
    const tests = generator.getTests();
    var analysis = PathAnalysis{
        .paths_enumerated = @intCast(tests.len),
        // Ask the generator rather than recomputing the MAX_PATHS comparison:
        // it also knows whether anything was summarized instead of enumerated,
        // which this copy of the predicate used to miss (spec gap 11).
        .paths_exhaustive = generator.pathsExhaustive(),
        .behaviors_exhaustive = generator.pathsExhaustive() and generator.getHandlerTests().len == tests.len,
        .paths_coverage_note = generator.coverage().note(),
        .max_io_depth = null,
        .cost_bounded = false,
        .cost_envelope = null,
        .behaviors = .empty,
        .fault_coverage = .{ .total_failable = 0, .covered = 0, .warnings = 0, .analysis_complete = false },
        .fault_clean = false,
        .fault_unseen_cause = null,
    };
    errdefer analysis.deinit(output_allocator);

    if (tests.len > 0) {
        analysis.cost_envelope = try generator.buildCostEnvelope(output_allocator);
        analysis.max_io_depth = switch (analysis.cost_envelope.?.total) {
            .constant => |count| count,
            else => null,
        };
        // Not conjoined with `exhaustive`: a summarized loop loses path
        // coverage but keeps its symbolic cost bound, and truncation already
        // forces the total to unbounded, so the class test alone covers it.
        analysis.cost_bounded = analysis.cost_envelope.?.total.class() != .unbounded;
    }
    if (include_behaviors) {
        analysis.behaviors = try generator.toBehaviorPaths(output_allocator);
    }

    return analysis;
}

/// Like runCheckOnly but operates on pre-read source. When skip_contract
/// is true, stages 7-10 (verification, contract, paths, fault coverage)
/// are skipped - only parse and type checking run, enough to detect errors.
pub fn runCheckOnlyFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    sql_schema_path: ?[]const u8,
    json_mode: bool,
    skip_contract: bool,
) !CheckResult {
    return runCheckOnlyFromSourceWithOptions(allocator, source, handler_path, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = json_mode,
        .skip_contract = skip_contract,
    });
}

pub fn runCheckOnlyFromSourceWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    opts: CheckOptions,
) !CheckResult {
    return runCheckOnlyFromSourceWithPathAllocator(
        allocator,
        allocator,
        source,
        handler_path,
        opts,
    );
}

/// Direct TypeScript diagnostics use original source coordinates.
/// The legacy virtual path retains its source-view mapping.
fn runCheckOnlyFromSourceWithPathAllocator(
    allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    opts: CheckOptions,
) !CheckResult {
    var prepared_source: ?zts.PreparedSource = null;
    defer if (prepared_source) |*prepared| prepared.deinit();
    // The legacy path reports the boundary before source-view mapping.
    var already_mapped: usize = 0;

    var result = try runCheckOnPreparedSource(
        allocator,
        path_allocator,
        source,
        handler_path,
        opts,
        &prepared_source,
        &already_mapped,
    );
    errdefer result.deinit(allocator);
    if (prepared_source) |*prepared| {
        remapDiagnosticsToSource(&result, prepared.sourceView(), already_mapped);
    } else if (result.is_typescript and result.stages_run.contains(.parse)) {
        remapDiagnosticsToSource(&result, .{ .text = source, .normalize_positions = true }, already_mapped);
    }

    return result;
}

/// Apply source-view coordinates after the recorded diagnostic boundary.
fn remapDiagnosticsToSource(
    result: *CheckResult,
    source_view: zts.SourceView,
    already_mapped: usize,
) void {
    const items = result.json_diagnostics.items;
    for (items[@min(already_mapped, items.len)..]) |*diagnostic| {
        const mapped = source_view.position(diagnostic.line, diagnostic.column);
        diagnostic.line = mapped.line;
        diagnostic.column = mapped.column;
    }
}

fn appendCheckAdmissionDiagnostic(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    source: []const u8,
    diagnostic: zts.parser.type_syntax.AdmissionDiagnostic,
    handler_path: []const u8,
) void {
    const projected = json_diag.fromAdmissionError(source, diagnostic, handler_path);
    result.json_diagnostics.append(allocator, projected) catch {};
    if (!builtin.is_test) {
        debugPrint("{s}:{d}:{d}: {s}{s}{s}\n", .{
            handler_path,
            projected.line,
            projected.column,
            projected.message,
            if (projected.suggestion != null) "; " else "",
            projected.suggestion orelse "",
        });
    }
}

fn checkAdmissionFailureError(failure: zts.parser.AdmissionFailure) zts.PrepareSourceError {
    return switch (failure) {
        .unterminated_comment => error.UnterminatedComment,
        .diagnostic => |diagnostic| switch (diagnostic.kind) {
            .any_type => error.UnsupportedAnyType,
            .as_assertion => error.UnsupportedAsAssertion,
            .satisfies_assertion => error.UnsupportedSatisfiesAssertion,
            .unterminated_string => error.UnterminatedString,
            .nominal_base_not_scalar => error.NominalBaseNotScalar,
            .interface_declaration => error.InterfaceDeclaration,
            .type_alias_declaration => error.TypeAliasDeclaration,
            .distinct_type_declaration => error.DistinctTypeDeclaration,
            .legacy_types_import => error.LegacyTypesImport,
            .default_parameter => error.DefaultParameter,
            .optional_parameter => error.OptionalParameter,
            .default_export => error.DefaultExport,
            .mutable_export => error.MutableExport,
            .array_type_alias => error.ArrayTypeAlias,
            .readonly_array_type_alias => error.ReadonlyArrayTypeAlias,
            .void_type => error.VoidType,
            .nesting_too_deep => error.NestingTooDeep,
        },
    };
}

fn runCheckOnPreparedSource(
    allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    opts: CheckOptions,
    prepared_out: *?zts.PreparedSource,
    already_mapped: *usize,
) !CheckResult {
    const sql_schema_path = opts.sql_schema_path;
    const json_mode = opts.json_mode;
    const skip_contract = opts.skip_contract;
    var result = CheckResult{};
    errdefer result.deinit(allocator);
    result.line_count = @intCast(std.mem.count(u8, source, "\n") + 1);

    const source_kind = zts.classifySourcePath(handler_path);
    result.is_typescript = source_kind.isTyped();

    result.stages_run.insert(.strip);
    var source_owner: zts.DirectCheckSource = undefined;
    var source_owner_initialized = false;
    defer if (source_owner_initialized) source_owner.deinit();

    var legacy_atoms = zts.AtomTable.init(allocator);
    defer legacy_atoms.deinit();
    var legacy_parser: ?zts.parser.JsParser = null;
    defer if (legacy_parser) |*parser| parser.deinit();

    const parsed_input: struct {
        parser: *zts.parser.JsParser,
        atoms: *zts.AtomTable,
        root: ir.NodeIndex,
    } = switch (source_kind) {
        .unsupported => {
            if (!builtin.is_test) {
                debugPrint("{s}: ZTS052 source files must use the .ts extension. Rename the handler to .ts.\n", .{handler_path});
            }
            result.json_diagnostics.append(
                allocator,
                json_diag.fromUnsupportedSourceExtension(handler_path),
            ) catch {};
            result.parse_errors = 1;
            return result;
        },
        .typescript => typed: {
            source_owner.initInPlace(allocator, allocator, source, handler_path) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (!builtin.is_test) debugPrint("TypeScript strip error: {}\n", .{err});
                    result.parse_errors = 1;
                    return result;
                },
                else => return err,
            };
            source_owner_initialized = true;
            switch (source_owner.outcome().*) {
                .recovered_admission_refused => {
                    const diagnostics = source_owner.selectedAdmissionDiagnostics();
                    for (diagnostics) |diagnostic| {
                        appendCheckAdmissionDiagnostic(allocator, &result, source, diagnostic, handler_path);
                    }
                    remapDiagnosticsToSource(&result, .{ .text = source, .normalize_positions = true }, 0);
                    result.parse_errors = @intCast(diagnostics.len);
                    return result;
                },
                .terminal_admission_refused => |failure| {
                    if (source_owner.terminalAdmissionDiagnostic()) |diagnostic| {
                        appendCheckAdmissionDiagnostic(allocator, &result, source, diagnostic, handler_path);
                    }
                    if (!builtin.is_test) debugPrint("TypeScript strip error: {}\n", .{checkAdmissionFailureError(failure)});
                    result.parse_errors = 1;
                    return result;
                },
                .parser_refused => {
                    result.stages_run.insert(.parse);
                    const errors = source_owner.parserErrors();
                    if (json_mode) {
                        for (errors) |parse_error| {
                            var diagnostic = json_diag.fromParseErrorOwned(allocator, parse_error, handler_path);
                            result.json_diagnostics.append(allocator, diagnostic) catch diagnostic.deinit(allocator);
                        }
                    } else if (!builtin.is_test) {
                        printParseErrors(allocator, source_owner.sourceView(), errors);
                    }
                    result.parse_errors = @intCast(errors.len);
                    return result;
                },
                .accepted => {
                    result.stages_run.insert(.parse);
                    const capabilities = source_owner.acceptedCapabilities() orelse return error.DirectTypeSyntaxUnavailable;
                    break :typed .{
                        .parser = &source_owner.parser,
                        .atoms = capabilities.atoms,
                        .root = capabilities.root,
                    };
                },
            }
        },
        .virtual_javascript => virtual: {
            prepared_out.* = try zts.PreparedSource.init(allocator, source, handler_path, .{});
            const prepared = &prepared_out.*.?;
            legacy_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
            const parser = &legacy_parser.?;
            parser.setAtomTable(&legacy_atoms);
            result.stages_run.insert(.parse);
            const root = parser.parse() catch {
                const errors = parser.errors.getErrors();
                if (json_mode) {
                    for (errors) |parse_error| {
                        var diagnostic = json_diag.fromParseErrorOwned(allocator, parse_error, handler_path);
                        result.json_diagnostics.append(allocator, diagnostic) catch diagnostic.deinit(allocator);
                    }
                } else if (!builtin.is_test) {
                    printParseErrors(allocator, prepared.sourceView(), errors);
                }
                result.parse_errors = @intCast(errors.len);
                return result;
            };
            break :virtual .{
                .parser = parser,
                .atoms = &legacy_atoms,
                .root = root,
            };
        },
    };
    already_mapped.* = result.json_diagnostics.items.len;
    var diag_view = zts.SourceView.of(source);
    diag_view.name = handler_path;
    const js_parser = parsed_input.parser;
    const atoms = parsed_input.atoms;
    const root = parsed_input.root;

    // Stage 3: Import validation
    result.stages_run.insert(.imports);
    var import_diagnostic: ?VirtualImportDiagnostic = null;
    validateVirtualModuleImports(
        zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants),
        atoms,
        handler_path,
        &import_diagnostic,
    ) catch {
        if (json_mode) {
            if (import_diagnostic) |diagnostic| {
                const message = switch (diagnostic.kind) {
                    .unknown_module => try std.fmt.allocPrint(
                        allocator,
                        "unknown virtual module '{s}'",
                        .{diagnostic.module},
                    ),
                    .missing_export => try std.fmt.allocPrint(
                        allocator,
                        "module '{s}' does not export '{s}'",
                        .{ diagnostic.module, diagnostic.missing_export.? },
                    ),
                };
                errdefer allocator.free(message);
                const suggestion = switch (diagnostic.kind) {
                    .unknown_module => "Use a specifier published by meta.module_catalog.",
                    .missing_export => "Use an export published for this module by meta.module_catalog.",
                };
                try result.json_diagnostics.append(allocator, .{
                    .code = diagnostic_catalog.virtualImportCode(diagnostic.kind),
                    .severity = "error",
                    .message = message,
                    .file = handler_path,
                    .line = diagnostic.line,
                    .column = diagnostic.column,
                    .suggestion = suggestion,
                    .message_owned = true,
                });
            }
        }
        result.parse_errors = 1;
        return result;
    };

    // Stage 4: IR optimization
    _ = zts.parser.optimizeIR(
        allocator,
        &js_parser.nodes,
        &js_parser.constants,
        root,
    ) catch {};

    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = if (source_kind.isTyped())
        zts.parsedModuleFromDirectCheck(&source_owner) orelse return error.DirectTypeSyntaxUnavailable
    else
        zts.pipeline.ParsedModule.fromExisting(ir_view, root, atoms);

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(
        allocator,
        parsed,
        .{
            .source_types = if (source_kind.isTyped()) .direct else .omitted,
            .strict = true,
            .manifest_registry = null,
            // Which sections the project's policy declares, so a computed
            // capability resource gets the diagnostic that matches what the
            // author has actually written.
            .policy_sections = if (opts.policy_source) |policy_source|
                zts.handler_policy.declaredSectionsFromJson(allocator, policy_source)
            else
                .{},
            .select_verifier = !skip_contract,
            .select_flow = !skip_contract,
        },
    );
    defer analysis.deinit();
    try analysis.complete();
    const resolved = try analysis.resolvedForReport();
    // One message per node: a boolean or strict diagnostic under a node that
    // has a type error repeats it.
    resolved.dropRepeatsOfTypeErrors();
    result.stages_run.insert(.boolean);

    {
        const bool_diags = resolved.boolDiagnostics();
        result.bool_errors = @intCast(resolved.bool_error_count);
        result.bool_warnings = @intCast(bool_diags.len -| result.bool_errors);
        if (bool_diags.len > 0) {
            if (json_mode) {
                for (bool_diags) |diag| {
                    if (json_diag.fromCheckerDiagnostic(allocator, .boolean, diag, ir_view, handler_path)) |jd| {
                        result.json_diagnostics.append(allocator, jd) catch {
                            var owned = jd;
                            owned.deinit(allocator);
                        };
                    }
                }
            } else {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
                resolved.formatBoolDiagnostics(diag_view, &aw.writer) catch {};
                buf = aw.toArrayList();
                if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});
            }
        }
        // No return on errors: the type and strict stages already ran inside
        // `resolve`, and an error in one must not hide the others.
        if (result.bool_errors == 0) {
            result.bool_specializations = resolved.bool_checker.node_types.count();
        }
    }

    if (source_kind.isTyped()) {
        result.stages_run.insert(.types);
        const tc_diags = resolved.typeDiagnostics();
        result.type_errors = @intCast(resolved.typeErrorCount());
        if (tc_diags.len > 0) {
            if (json_mode) {
                for (tc_diags) |diag| {
                    if (json_diag.fromCheckerDiagnostic(allocator, .type, diag, ir_view, handler_path)) |jd| {
                        result.json_diagnostics.append(allocator, jd) catch {
                            var owned = jd;
                            owned.deinit(allocator);
                        };
                    }
                }
            } else {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
                resolved.formatTypeDiagnostics(diag_view, &aw.writer) catch {};
                buf = aw.toArrayList();
                if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});
            }
        }
    }

    if (resolved.strict_checker != null) {
        result.stages_run.insert(.strict);
        const strict_diags = resolved.strictDiagnostics();
        result.strict_errors = @intCast(resolved.strict_error_count);
        // Count by severity rather than by subtraction. `len - errors` folded
        // advisories into the warning count, and a warning sets exit code 2, so
        // a non-idiomatic spelling changed the exit code of a build - which
        // spec 4.2.1 forbids in the same sentence that admits the row. The
        // severity set is closed and ordered: only `.err` may fail a check, and
        // `.advisory` is strictly weaker than `.warning`.
        var strict_warnings: u32 = 0;
        var strict_advisories: u32 = 0;
        for (strict_diags) |diag| {
            switch (diag.severity) {
                .err => {},
                .warning => strict_warnings += 1,
                .advisory => strict_advisories += 1,
            }
        }
        result.strict_warnings = strict_warnings;
        result.strict_advisories = strict_advisories;
        if (strict_diags.len > 0) {
            for (strict_diags) |diag| {
                if (json_diag.fromCheckerDiagnostic(allocator, .strict, diag, ir_view, handler_path)) |jd| {
                    result.json_diagnostics.append(allocator, jd) catch {
                        var owned = jd;
                        owned.deinit(allocator);
                    };
                }
            }
            if (!json_mode) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
                resolved.formatStrictDiagnostics(diag_view, &aw.writer) catch {};
                buf = aw.toArrayList();
                if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});
            }
        }
    }

    // All three computed stages are reported above. Any error in them stops
    // the check before the verifier and flow stages, as before.
    if (result.bool_errors > 0 or result.type_errors > 0 or result.strict_errors > 0) {
        analysis.refuseResolution();
        return result;
    }

    if (skip_contract) return result;

    var imported_analyses: ImportedFunctionAnalyses = .{};
    defer imported_analyses.deinit(allocator);
    var verify_info: ?VerificationInfo = null;
    if (zts.findHandlerFunction(ir_view, root)) |hf| {
        // Sink summaries for helpers imported from sibling files. Without them
        // the flow checker has no body to walk for such a call and has to
        // treat its value as untraceable, which costs every property the
        // value's sink decides. With them the importer applies its own
        // argument labels to the sinks inside each helper.
        var import_stack: ImportStack = .{};
        const handler_resolved = std.fs.path.resolve(allocator, &.{handler_path}) catch null;
        defer if (handler_resolved) |p| allocator.free(p);
        if (handler_resolved) |p| {
            import_stack.paths[0] = p;
            import_stack.len = 1;
        }
        imported_analyses = try collectImportedFnSummaries(
            allocator,
            try analysis.facts(),
            handler_path,
            &import_stack,
            opts.import_reader,
        );

        try analysis.prepareChecked(hf, .{
            .module_facts = try analysis.facts(),
            .imported_fn_summaries = imported_analyses.flow.items,
        });
        _ = try analysis.runVerifier(hf);
        _ = try analysis.runFlow(hf);
        const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
        result.verify_ran = true;
        result.stages_run.insert(.verifier);
        result.stages_run.insert(.flow);
        result.verify_errors = @intCast(checked.verifier_error_count);
        const verifier_diags = checked.verifierDiagnostics();
        result.verify_warnings = @intCast(verifier_diags.len -| result.verify_errors);

        if (verifier_diags.len > 0) {
            if (json_mode) {
                for (verifier_diags) |diag| {
                    if (json_diag.fromCheckerDiagnostic(allocator, .verifier, diag, ir_view, handler_path)) |jd| {
                        result.json_diagnostics.append(allocator, jd) catch {
                            var owned = jd;
                            owned.deinit(allocator);
                        };
                    }
                }
            } else {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
                checked.verifier.formatDiagnostics(diag_view, &aw.writer) catch {};
                buf = aw.toArrayList();
                if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});
            }
        }

        result.state_isolated = !checked.verifier.has_module_mutation and !checked.verifier.unresolved_route_dispatch;
        if (result.verify_errors == 0) {
            result.exhaustive_returns = true;
            result.results_safe = true;
            result.optionals_safe = true;
            verify_info = .{
                .exhaustive_returns = true,
                .results_safe = true,
                .unreachable_code = false,
                .bytecode_verified = false,
            };
            for (verifier_diags) |d| {
                if (d.kind == .unreachable_after_return) {
                    result.no_unreachable = false;
                    break;
                }
            }
        }

        result.flow_errors = @intCast(checked.flow_error_count);
        const flow_diags = checked.flowDiagnostics();
        result.flow_warnings = @intCast(flow_diags.len -| result.flow_errors);
        if (json_mode) {
            for (flow_diags) |diag| {
                if (json_diag.fromCheckerDiagnostic(allocator, .flow, diag, ir_view, handler_path)) |jd| {
                    result.json_diagnostics.append(allocator, jd) catch {
                        var owned = jd;
                        owned.deinit(allocator);
                    };
                }
            }
        }
        // Non-JSON stderr output is emitted by projectCompletedFlow from the
        // same FlowChecker instance; avoid printing twice.

    }

    // Stage 8: Contract. Untyped full analysis creates a separate real type
    // session only now. The contract borrows the completed session.
    result.contract = try extractContractFromAnalysis(
        &analysis,
        handler_path,
        .{
            .verification = verify_info,
            .imported_effects = imported_analyses.effects.items,
        },
    );
    if (zts.findHandlerFunction(ir_view, root) != null) {
        try projectCompletedFlow(
            allocator,
            &result.contract.?,
            try analysis.completedFlow(),
            0,
            false,
            null,
            ir_view,
        );
    } else {
        try projectCompletedFlow(allocator, &result.contract.?, null, 0, false, null, ir_view);
    }
    try validateContractPolicyInputs(allocator, handler_path, &result.contract.?, sql_schema_path, null);
    result.stages_run.insert(.contract);

    // Stage 8b: capability policy. Reported, not thrown.
    //
    // `validateContractPolicyInputs` receives no policy above:
    // its `enforcePolicyForContract` raises `error.PolicyViolation`, which is
    // right for a build (refuse to emit an artifact) and wrong for a check,
    // which has to report every finding it can see. The same
    // `handler_policy.validateContract` runs here and each violation becomes a
    // coded POL diagnostic instead.
    //
    // Without this the allow-list was invisible to `zts check`, to
    // `zts edit-simulate`, and therefore to the expert veto: a handler reading
    // an env var the project forbids passed all three with exit 0, and POL001
    // through POL008 were codes nothing ever emitted.
    if (opts.policy_source) |policy_source| {
        result.stages_run.insert(.policy);
        if (result.contract) |*contract_ref| {
            try appendPolicyDiagnostics(allocator, &result, contract_ref, policy_source, handler_path);
        }
    }

    if (result.contract) |*c| {
        if (c.properties) |*props| {
            props.state_isolated = result.state_isolated;
            props.result_safe = result.results_safe;
            props.optional_safe = result.optionals_safe;
        }
    }
    syncCheckResultProperties(&result);

    // Stage 9: Path generation + Stage 10: Fault coverage
    {
        const handler_fn = findHandlerFunction(ir_view, root);
        if (handler_fn) |hf| {
            var path_analysis = try analyzeHandlerPaths(
                path_allocator,
                allocator,
                ir_view,
                atoms,
                try analysis.facts(),
                &analysis,
                hf,
                handler_path,
                result.contract != null,
                opts.import_reader,
            );
            defer path_analysis.deinit(allocator);

            result.stages_run.insert(.paths);
            result.paths_enumerated = path_analysis.paths_enumerated;
            result.paths_exhaustive = path_analysis.paths_exhaustive;
            result.paths_coverage_note = path_analysis.paths_coverage_note;
            result.max_io_depth = path_analysis.max_io_depth;
            result.fault_total = path_analysis.fault_coverage.total_failable;
            result.fault_covered = path_analysis.fault_coverage.covered;
            result.fault_unseen = path_analysis.fault_coverage.unseen_calls;

            // Populate behavioral contract
            if (result.contract) |*c| {
                if (c.properties) |*props| {
                    props.max_io_depth = result.max_io_depth;
                    props.cost_bounded = path_analysis.cost_bounded;
                    props.fault_covered = path_analysis.fault_clean;
                }
                c.property_provenance.fault_covered = path_analysis.fault_unseen_cause;
                // The cause borrows its snippet, so the contract takes the
                // allocation that backs it.
                if (c.owned_fault_cause_snippet) |old| allocator.free(old);
                c.owned_fault_cause_snippet = path_analysis.fault_unseen_snippet_owned;
                path_analysis.fault_unseen_snippet_owned = null;
                if (path_analysis.cost_envelope) |envelope| {
                    c.cost_envelope = envelope;
                    path_analysis.cost_envelope = null;
                }
                c.behaviors = path_analysis.behaviors;
                path_analysis.behaviors = .empty;
                c.behaviors_exhaustive = path_analysis.behaviors_exhaustive;
                c.fault_coverage = path_analysis.fault_coverage;
            }
        }
    }

    // Stage 11: Proof trace - per-property reasoning for the proof card.
    // Renders while the IR view and flow diagnostics are still alive; the
    // result is a pre-formatted JSON object stored on CheckResult.
    if (result.contract) |*c| {
        result.stages_run.insert(.trace);
        var trace_arena = std.heap.ArenaAllocator.init(allocator);
        defer trace_arena.deinit();
        const flow_for_trace = if (analysis.checkedModule()) |checked| checked.flowDiagnostics() else &.{};
        const defended_for_trace = if (analysis.checkedModule()) |checked| checked.defendedPaths() else &.{};
        if (zts.proof_trace.collect(
            trace_arena.allocator(),
            c,
            flow_for_trace,
            defended_for_trace,
            ir_view,
            result.paths_enumerated,
            result.paths_exhaustive,
        )) |traces| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
            const ok = if (zts.proof_trace.writeJson(&aw.writer, traces)) |_| true else |_| false;
            buf = aw.toArrayList();
            if (ok) result.proof_trace_json = allocator.dupe(u8, buf.items) catch null;
        } else |_| {}
    }

    // Later analysis stages mutate contract.properties, so keep the flat
    // CheckResult mirror aligned with the finalized contract before returning.
    syncCheckResultProperties(&result);
    result.stages_run.insert(.spec);
    try refreshSpecDiagnostics(allocator, &result);
    result.stages_run.insert(.canonical);
    appendCanonicalPublicHelperDiagnostics(allocator, &result, handler_path);
    if (json_mode) appendSpecDiagnosticsJson(allocator, &result, handler_path);

    return result;
}

/// Parse handler source and write one JSONL test case per proven behavioral path.
/// Returns the number of test cases written. Returns 0 when no handler function
/// is found. Callers should check for parse errors via stderr.
pub fn runGenTests(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    writer: anytype,
) !u32 {
    const source = readFilePosix(allocator, handler_path, 10 * 1024 * 1024) catch |err| {
        debugPrint("Error reading handler file '{s}': {}\n", .{ handler_path, err });
        return err;
    };
    defer allocator.free(source);

    var strip_diag: ?zts.StripDiagnostic = null;
    var prepared = zts.PreparedSource.init(allocator, source, handler_path, .{
        .diagnostic_out = &strip_diag,
    }) catch |err| {
        debugPrintStripError(handler_path, err, strip_diag);
        return err;
    };
    defer prepared.deinit();

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    var js_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = js_parser.parse() catch {
        printParseErrors(allocator, prepared.sourceView(), js_parser.errors.getErrors());
        return error.ParseError;
    };

    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse return 0;

    var effect_facts: ?zts.EffectFacts = zts.buildEffectFacts(
        allocator,
        ir_view,
        &atoms,
        root,
        .{},
    ) catch null;
    defer if (effect_facts) |*owned_effects| owned_effects.deinit(allocator);
    const path_effects: zts.EffectFactsRef = if (effect_facts) |*completed_effects|
        .{ .complete = completed_effects }
    else
        .unavailable;
    var gen = zts.PathGenerator.init(allocator, ir_view, &atoms, path_effects);
    defer gen.deinit();
    try gen.generate(handler_fn);
    try gen.writeJsonl(writer);
    return @intCast(gen.getHandlerTests().len);
}

/// Resolves a call site to a row of the acceptance kernel's guard catalog.
///
/// The row index is what the proof IR carries. The consumer looks the row up in
/// its own table, so nothing the producer writes about the module, the export,
/// or the argument position is taken as an answer.
const GuardResolver = struct {
    checker: ?*const zts.StrictChecker,
    view: zts.parser.IrView,

    fn resolve(context: *const anyopaque, node: zts.parser.ir.NodeIndex) ?u32 {
        const self: *const GuardResolver = @ptrCast(@alignCast(context));
        const checker = self.checker orelse return null;
        const call = self.view.getCall(node) orelse return null;
        const imported = checker.importedFunctionForCallee(call.callee) orelse return null;
        const index = pcc.residual.lookupIndex(imported.module, imported.name, 0) orelse return null;
        if (call.args_count == 0) return null;
        const argument = self.view.getListIndex(call.args_start, 0);
        // A compiler-visible argument keeps the static path and pays no residual
        // lookup. Only what the compiler could not resolve becomes an obligation.
        if (checker.isLiteralOrStaticTemplate(argument)) return null;
        return index;
    }

    fn resolver(self: *const GuardResolver) zts.ProofResolver {
        return .{ .context = self, .resolve = resolve };
    }
};

pub const CompileOptions = struct {
    emit_verify: bool = false,
    emit_contract: bool = false,
    strict: bool = true,
    policy: ?HandlerPolicy = null,
    sql_schema_path: ?[]const u8 = null,
    generate_tests: bool = false,
    /// Partner virtual-module manifests registered for this compile.
    /// The registry must outlive the call.
    manifest_registry: ?*const zts.ManifestRegistry = null,
    /// Capture the canonical proof IR and the translation witnesses. Off by
    /// default: recording costs a null check per emitted node and an owned copy
    /// of the witness arrays, and only a caller producing a certificate needs
    /// them.
    emit_proof_evidence: bool = false,
};

const shared_analysis_clean_source =
    \\structural Guardrails<T> = Proof<T, "result_safe">;
    \\
    \\function handler(req: Request): Guardrails<Response> {
    \\  return Response.json({ ok: true });
    \\}
;

test "default check records its exact public stage set" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        shared_analysis_clean_source,
        "shared-analysis-default.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(allocator);

    const expected = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(result.verify_ran);
    try std.testing.expect(result.contract != null);
}

test "skip_contract stops after the exact computed stage set" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        shared_analysis_clean_source,
        "shared-analysis-skip-contract.ts",
        .{
            .json_mode = true,
            .skip_contract = true,
        },
    );
    defer result.deinit(allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(!result.verify_ran);
    try std.testing.expect(!result.results_safe);
    try std.testing.expect(!result.optionals_safe);
    try std.testing.expect(result.properties == null);
    try std.testing.expect(result.contract == null);
    try std.testing.expect(result.proof_trace_json == null);
}

test "formatIsoTimestamp produces ISO-8601 UTC" {
    var buf: [24]u8 = undefined;
    const got = zts.pipeline.formatIsoTimestamp(&buf, 1_700_000_000);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", got);
}

test "compile and check agree on summarized and exhaustive behavior paths" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, exhaustive: bool }{
        .{
            .source =
            \\function handler(req: Request): Proof<Response, "pure"> {
            \\  const items = ["a", "b"];
            \\  for (const item of items) { const copy = item; }
            \\  return Response.text("ok");
            \\}
            ,
            .exhaustive = false,
        },
        .{
            .source = "function handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }",
            .exhaustive = true,
        },
    };
    for (cases) |case| {
        var checked = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "behavior-coverage.ts", .{
            .json_mode = true,
        });
        defer checked.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), checked.totalErrors());
        try std.testing.expectEqual(case.exhaustive, checked.paths_exhaustive);
        try std.testing.expectEqual(case.exhaustive, checked.contract.?.behaviors_exhaustive);
        var compiled = try compileHandler(allocator, case.source, "behavior-coverage.ts", .{
            .emit_contract = true,
            .generate_tests = true,
        });
        defer compiled.deinit(allocator);
        try std.testing.expect(compiled.bytecode.len > 0);
        try std.testing.expect(compiled.generated_tests != null);
        try std.testing.expectEqual(case.exhaustive, compiled.contract.?.behaviors_exhaustive);
    }
}

pub fn compileHandler(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: CompileOptions,
) !CompiledHandler {
    const emit_verify = opts.emit_verify;
    const emit_contract = opts.emit_contract;
    const policy = opts.policy;
    const sql_schema_path = opts.sql_schema_path;
    const generate_tests = opts.generate_tests;
    const manifest_registry = opts.manifest_registry;

    const source_kind = zts.classifySourcePath(filename);
    var strip_diag: ?zts.StripDiagnostic = null;
    var prepared = zts.PreparedSource.init(allocator, source, filename, .{
        .diagnostic_out = &strip_diag,
    }) catch |err| {
        debugPrintStripError(filename, err, strip_diag);
        return err;
    };
    defer prepared.deinit();
    if (source_kind.isTyped() and !builtin.is_test) debugPrint("TypeScript stripped successfully\n", .{});

    // Rendered against the author's file, not the stripped text that was
    // parsed; see runCheckOnPreparedSource.
    const diag_view = prepared.sourceView();

    // Initialize string table and atom table for parsing
    var strings = zts.StringTable.init(allocator);
    defer strings.deinit();

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    // Parse the source code (single pass for IR + bytecode)
    var js_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const root = js_parser.parse() catch |err| {
        // Print parse errors
        printParseErrors(allocator, diag_view, js_parser.errors.getErrors());
        return err;
    };

    const needs_contract = true; // Always extract for auto-sandboxing

    try validateVirtualModuleImports(
        zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants),
        &atoms,
        filename,
        null,
    );

    // Check for file imports before proceeding with single-module compilation
    const has_file_imports = hasFileImports(&js_parser, root);

    if (has_file_imports) {
        if (!builtin.is_test) debugPrint("File imports detected, building module graph...\n", .{});
        return compileMultiModule(
            allocator,
            source,
            filename,
            &strings,
            &atoms,
            needs_contract,
            emit_contract,
            policy,
            sql_schema_path,
            manifest_registry,
        );
    }

    // Optimize IR (cold-start-friendly single pass)
    _ = zts.parser.optimizeIR(
        allocator,
        &js_parser.nodes,
        &js_parser.constants,
        root,
    ) catch {};

    const ir_view_check = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = zts.pipeline.ParsedModule.fromExisting(ir_view_check, root, &atoms);

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(
        allocator,
        parsed,
        .{
            .type_map = prepared.typeMap(),
            .strict = opts.strict,
            .manifest_registry = manifest_registry,
            // Which sections the author wrote, not what is in them: the
            // classifier needs to know whether a computed resource has anything
            // that could cover it.
            .policy_sections = if (policy) |*configured| configured.declaredSections() else .{},
            .select_verifier = emit_verify,
            .select_flow = true,
        },
    );
    defer analysis.deinit();
    try analysis.complete();
    const resolved = try analysis.resolvedForReport();

    {
        const bool_diags = resolved.boolDiagnostics();
        if (bool_diags.len > 0 and !builtin.is_test) {
            debugPrint("\n", .{});
            var bool_output: std.ArrayList(u8) = .empty;
            defer bool_output.deinit(allocator);
            var bool_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &bool_output);
            resolved.formatBoolDiagnostics(diag_view, &bool_aw.writer) catch {};
            bool_output = bool_aw.toArrayList();
            if (bool_output.items.len > 0) {
                debugPrint("{s}", .{bool_output.items});
            }
            debugPrint("{d} boolean check error(s), {d} warning(s)\n", .{
                resolved.bool_error_count,
                bool_diags.len - resolved.bool_error_count,
            });
        }
        if (resolved.bool_error_count > 0) {
            analysis.refuseResolution();
            if (!builtin.is_test) debugPrint("\nBoolean check failed for {s}\n", .{filename});
            return error.SoundModeViolation;
        }
        if (!builtin.is_test) debugPrint("Boolean check passed\n", .{});
    }

    if (prepared.typeMap() != null) {
        const tc_diags = resolved.typeDiagnostics();
        if (tc_diags.len > 0 and !builtin.is_test) {
            var tc_output: std.ArrayList(u8) = .empty;
            defer tc_output.deinit(allocator);
            var tc_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &tc_output);
            resolved.formatTypeDiagnostics(diag_view, &tc_aw.writer) catch {};
            tc_output = tc_aw.toArrayList();
            if (tc_output.items.len > 0) {
                debugPrint("{s}", .{tc_output.items});
            }
        }
        if (resolved.typeErrorCount() > 0) {
            analysis.refuseResolution();
            if (!builtin.is_test) debugPrint("\nType check failed for {s}\n", .{filename});
            return error.SoundModeViolation;
        }
        if (!builtin.is_test) debugPrint("Type check passed\n", .{});
    }

    if (resolved.strict_checker != null) {
        const strict_diags = resolved.strictDiagnostics();
        if (strict_diags.len > 0 and !builtin.is_test) {
            var strict_output: std.ArrayList(u8) = .empty;
            defer strict_output.deinit(allocator);
            var strict_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &strict_output);
            resolved.formatStrictDiagnostics(diag_view, &strict_aw.writer) catch {};
            strict_output = strict_aw.toArrayList();
            if (strict_output.items.len > 0) {
                debugPrint("{s}", .{strict_output.items});
            }
        }
        if (resolved.strict_error_count > 0) {
            analysis.refuseResolution();
            if (!builtin.is_test) debugPrint("\nStrict check failed for {s}\n", .{filename});
            return error.SoundModeViolation;
        }
        if (!builtin.is_test) debugPrint("Strict check passed\n", .{});
    }

    // Unified violations list: collects from FlowChecker, HandlerVerifier, and
    // FaultCoverageChecker. Declared here so it spans the verifier block,
    // projectCompletedFlow (flow violations), and the PathGenerator block (fault violations).
    var all_violations: std.ArrayList(zts.property_diagnostics.PropertyViolation) = .empty;
    defer {
        zts.property_diagnostics.deinitViolations(allocator, all_violations.items);
        all_violations.deinit(allocator);
    }

    // Run handler verification if requested
    var verify_info: ?VerificationInfo = null;
    var state_isolated: bool = true;
    // result_safe and optional_safe default false (unproven) until verification runs and passes.
    var result_safe: bool = false;
    var optional_safe: bool = false;
    const handler_fn = zts.findHandlerFunction(ir_view_check, root);
    try analysis.prepareChecked(handler_fn, .{ .module_facts = try analysis.facts() });
    if (emit_verify) {
        if (handler_fn) |hf| {
            const error_count = try analysis.runVerifier(hf);
            const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
            const verifier = &checked.verifier;
            const diags = checked.verifierDiagnostics();

            if (diags.len > 0 and !builtin.is_test) {
                debugPrint("\n", .{});
                var diag_output: std.ArrayList(u8) = .empty;
                defer diag_output.deinit(allocator);
                var diag_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &diag_output);
                verifier.formatDiagnostics(diag_view, &diag_aw.writer) catch {};
                diag_output = diag_aw.toArrayList();
                if (diag_output.items.len > 0) {
                    debugPrint("{s}", .{diag_output.items});
                }
                debugPrint("{d} error(s), {d} warning(s)\n", .{
                    error_count,
                    diags.len - error_count,
                });
            }

            // Collect violations before deciding to fail so counterexample tests can be
            // generated and returned even when verification fails.
            zts.property_diagnostics.collectVerifierViolations(allocator, &all_violations, diags, ir_view_check);

            if (error_count > 0) {
                // Run PathGenerator to fill counterexample refs for result_unsafe violations
                // before returning the failure result.
                const path_effects = try analysis.pathEffectFacts();
                var gen = zts.PathGenerator.init(allocator, ir_view_check, &atoms, path_effects);
                defer gen.deinit();
                gen.generate(hf) catch {};
                const handler_tests = gen.getHandlerTests();
                zts.property_diagnostics.fillVerifierCounterexamples(all_violations.items, handler_tests);

                var viol_jsonl_result: ?[]const u8 = null;
                var viol_summary_result: ?[]const u8 = null;
                if (all_violations.items.len > 0) {
                    var vj_buf: std.ArrayList(u8) = .empty;
                    var vj_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &vj_buf);
                    zts.property_diagnostics.writeViolationsJsonl(&vj_aw.writer, allocator, all_violations.items, handler_tests) catch {};
                    vj_buf = vj_aw.toArrayList();
                    if (vj_buf.items.len > 0) {
                        viol_jsonl_result = try vj_buf.toOwnedSlice(allocator);
                    } else {
                        vj_buf.deinit(allocator);
                    }
                    var vs_buf: std.ArrayList(u8) = .empty;
                    var vs_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &vs_buf);
                    zts.property_diagnostics.formatViolationsSummary(&vs_aw.writer, all_violations.items, filename, null) catch {};
                    vs_buf = vs_aw.toArrayList();
                    if (vs_buf.items.len > 0) {
                        viol_summary_result = try vs_buf.toOwnedSlice(allocator);
                    } else {
                        vs_buf.deinit(allocator);
                    }
                }

                if (!builtin.is_test) debugPrint("\nVerification failed for {s}\n", .{filename});
                return .{
                    .verify_failed = true,
                    .violations_jsonl = viol_jsonl_result,
                    .violations_summary = viol_summary_result,
                };
            }

            // Track verification results for contract
            var has_unreachable = false;
            for (diags) |d| {
                if (d.kind == .unreachable_after_return) {
                    has_unreachable = true;
                    break;
                }
            }
            verify_info = .{
                .exhaustive_returns = true,
                .results_safe = error_count == 0,
                .unreachable_code = has_unreachable,
                .bytecode_verified = true, // will be set after bytecode gen
            };
            state_isolated = !verifier.has_module_mutation and !verifier.unresolved_route_dispatch;

            // unchecked_result_value and unchecked_optional_* are .err severity,
            // so reaching here (error_count == 0) guarantees both properties hold.
            result_safe = true;
            optional_safe = true;

            if (!builtin.is_test) debugPrint("Verification passed\n", .{});
        } else {
            if (!builtin.is_test) debugPrint("Warning: no handler function found for verification\n", .{});
        }
    }

    var code_gen = zts.parser.CodeGen.initWithIRStore(
        allocator,
        &js_parser.nodes,
        &js_parser.constants,
        &js_parser.scopes,
        &strings,
        &atoms,
    );
    defer code_gen.deinit();

    // Translation evidence, captured while code generation still knows where
    // each IR member went. After this function returns, the IR is gone and the
    // offsets have already been moved by the optimizer.
    var witness_recorder: ?zts.TranslationRecorder = if (opts.emit_proof_evidence)
        zts.TranslationRecorder.init(allocator)
    else
        null;
    defer if (witness_recorder) |*recorder| recorder.deinit();
    if (witness_recorder) |*recorder| code_gen.witness = recorder;

    // Wire type annotations from BoolChecker for type-directed opcode specialization.
    // The map is owned by `resolved.bool_checker`; pass-through borrow is safe
    // because `resolved` outlives the codegen pass.
    if (resolved.bool_checker.node_types.count() > 0) {
        code_gen.setNodeTypes(&resolved.bool_checker.node_types);
    }

    const func = try code_gen.generate(root);
    defer code_gen.freeOwnedConstantPayloads();

    if (!builtin.is_test) debugPrint("Parsed successfully: {d} bytes of bytecode\n", .{func.code.len});

    // Bytecode verification: reject malformed bytecode before serialization
    const verify_bc = zts.BytecodeVerifier.verify(&func);
    if (!verify_bc.valid) {
        debugPrint("Bytecode verification failed at offset {d}: {s}\n", .{
            verify_bc.offset,
            verify_bc.message,
        });
        return error.BytecodeVerificationFailed;
    }

    // The proof IR is lowered from the same parse code generation just walked,
    // and the witnesses are attached to it here rather than later, because
    // `js_parser` does not outlive this function.
    var proof_evidence: ?zts.ProofEvidence = null;
    errdefer if (proof_evidence) |*evidence| evidence.deinit();
    if (witness_recorder) |*recorder| {
        recorder.check() catch |err| {
            debugPrint("Translation evidence is incomplete ({s}); refusing to emit a proof certificate\n", .{@errorName(err)});
            return error.TranslationWitnessIncomplete;
        };
        const proof_view = zts.parser.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        const handler_source = zts.findHandlerFunction(proof_view, root) orelse
            return error.HandlerNotFound;
        // A guarded call is one the strict checker would refuse today: a
        // capability export in the consumer's catalog whose resource argument
        // is not compiler-visible. Both halves of that question are answered by
        // the same code that answers `ZTS602`, so the plan and the diagnostic
        // cannot disagree about what a handler does.
        var guard_resolver = GuardResolver{
            .checker = if (resolved.strict_checker) |*checker| checker else null,
            .view = proof_view,
        };
        proof_evidence = try zts.buildProofEvidence(
            allocator,
            proof_view,
            root,
            handler_source,
            recorder,
            guard_resolver.resolver(),
        );
    }

    // Get object literal shapes from parser
    const shapes = code_gen.shapes.items;
    if (!builtin.is_test) debugPrint("Collected {d} object literal shapes\n", .{shapes.len});

    // Serialize bytecode with atoms AND shapes for complete cache format
    var buffer: [256 * 1024]u8 = undefined; // 256KB buffer
    var writer = zts.bytecode_cache.SliceWriter{ .buffer = &buffer };

    zts.bytecode_cache.serializeBytecodeWithAtomsAndShapes(&func, &atoms, shapes, &writer, allocator) catch |err| {
        debugPrint("Serialization error: {}\n", .{err});
        return err;
    };

    // Copy the serialized data to owned memory
    const serialized = writer.getWritten();
    const bytecode_data = try allocator.dupe(u8, serialized);
    errdefer allocator.free(bytecode_data);

    // Build contract if requested or needed for policy validation.
    // The contract reads its route table from the pattern analysis.
    var contract: ?HandlerContract = null;
    errdefer if (contract) |*built| built.deinit(allocator);
    if (needs_contract) {
        var route_analysis = try analyzeAot(allocator, &js_parser, &atoms, root);
        defer if (route_analysis) |*t| t.deinit(allocator);

        contract = try extractContractFromAnalysis(
            &analysis,
            filename,
            .{ .aot = route_analysis, .verification = verify_info },
        );
        if (handler_fn) |hf| {
            const flow_errors = try analysis.runFlow(hf);
            try projectCompletedFlow(
                allocator,
                &contract.?,
                try analysis.completedFlow(),
                flow_errors,
                true,
                &all_violations,
                ir_view_check,
            );
        } else {
            try projectCompletedFlow(allocator, &contract.?, null, 0, true, &all_violations, ir_view_check);
        }
        try validateContractPolicyInputs(allocator, filename, &contract.?, sql_schema_path, policy);

        // Inject verification-derived properties (Checks 2, 6, 7)
        if (contract.?.properties) |*props| {
            props.state_isolated = state_isolated;
            props.result_safe = result_safe;
            props.optional_safe = optional_safe;
        }
    }

    // Generate exhaustive test cases from path analysis.
    // Also runs when emitting a contract, to populate behavioral paths.
    var generated_tests_jsonl: ?[]const u8 = null;
    errdefer if (generated_tests_jsonl) |bytes| allocator.free(bytes);
    var violations_jsonl: ?[]const u8 = null;
    errdefer if (violations_jsonl) |bytes| allocator.free(bytes);
    var violations_summary: ?[]const u8 = null;
    errdefer if (violations_summary) |bytes| allocator.free(bytes);
    if (generate_tests or (emit_contract and contract != null)) {
        if (handler_fn) |hf| {
            // See analyzeHandlerPaths: the imported files decide `fault_covered`.
            var path_module_facts = try zts.pipeline.buildModuleFacts(allocator, parsed, null);
            defer path_module_facts.deinit();
            var imported_scan = try collectImportedFailableCalls(
                allocator,
                &path_module_facts,
                filename,
                null,
            );
            defer if (imported_scan) |*scan| scan.deinit(allocator);
            const path_effects = try analysis.pathEffectFacts();
            var gen = zts.PathGenerator.init(allocator, ir_view_check, &atoms, path_effects);
            defer gen.deinit();
            gen.facts = &path_module_facts;
            gen.setImportedScan(if (imported_scan) |scan| scan.entries.items else null);

            try gen.generate(hf);

            const handler_tests = gen.getHandlerTests();
            const test_count = handler_tests.len;
            if (test_count > 0) {
                var jsonl_buf: std.ArrayList(u8) = .empty;
                var jsonl_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &jsonl_buf);
                gen.writeJsonl(&jsonl_aw.writer) catch {};
                jsonl_buf = jsonl_aw.toArrayList();
                generated_tests_jsonl = try jsonl_buf.toOwnedSlice(allocator);
            }

            if (contract != null) {
                var path_analysis = try summarizeGeneratedPaths(allocator, &gen, true);
                defer path_analysis.deinit(allocator);
                if (contract.?.properties) |*props| {
                    props.max_io_depth = path_analysis.max_io_depth;
                    props.cost_bounded = path_analysis.cost_bounded;
                }
                contract.?.cost_envelope = path_analysis.cost_envelope;
                path_analysis.cost_envelope = null;

                contract.?.behaviors = path_analysis.behaviors;
                path_analysis.behaviors = .empty;
                contract.?.behaviors_exhaustive = path_analysis.behaviors_exhaustive;
            }

            // Fault coverage analysis on generated paths
            var fc = zts.FaultCoverageChecker.init(allocator, gen.getTests());
            defer fc.deinit();
            try fc.analyze();
            const fc_report = fc.getReport();
            var fault_stamp = try stampFaultCoverage(allocator, ir_view_check, &gen, &fc);
            defer fault_stamp.deinit(allocator);

            // The check path writes the record for every handler. This path
            // writes it, and the property bit, only when a failable site or an
            // incomplete analysis gives the record something to say. The cause
            // is stamped the way the check path stamps it.
            const stamp_fault = fc_report.total_failable > 0 or !gen.faultAnalysisComplete();
            if (contract) |*c| {
                if (stamp_fault) {
                    if (c.properties) |*props| props.fault_covered = fault_stamp.clean;
                    c.fault_coverage = fault_stamp.coverage;
                }
                c.property_provenance.fault_covered = fault_stamp.unseen_cause;
                // The cause borrows its snippet, so the contract takes the
                // allocation that backs it.
                if (c.owned_fault_cause_snippet) |old| allocator.free(old);
                c.owned_fault_cause_snippet = fault_stamp.unseen_snippet_owned;
                fault_stamp.unseen_snippet_owned = null;
            }

            if (fc_report.total_failable > 0) {
                if (!builtin.is_test) {
                    var fc_buf: std.ArrayList(u8) = .empty;
                    var fc_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &fc_buf);
                    fc.formatMatrix(fc_report, &fc_aw.writer) catch {};
                    fc_buf = fc_aw.toArrayList();
                    if (fc_buf.items.len > 0) {
                        debugPrint("{s}", .{fc_buf.items});
                    }
                    fc_buf.deinit(allocator);

                    if (fc_report.warning_count > 0) {
                        var diag_buf: std.ArrayList(u8) = .empty;
                        var diag_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &diag_buf);
                        fc.formatDiagnostics(&diag_aw.writer) catch {};
                        diag_buf = diag_aw.toArrayList();
                        if (diag_buf.items.len > 0) {
                            debugPrint("{s}", .{diag_buf.items});
                        }
                        diag_buf.deinit(allocator);
                    }
                }
            }

            // Collect fault coverage violations into the unified all_violations list.
            // Flow and verifier violations were already collected earlier.
            if (fc_report.warning_count > 0) {
                zts.property_diagnostics.collectFaultViolations(
                    allocator,
                    &all_violations,
                    fc_report.diagnostics,
                    handler_tests,
                );
            }

            // Fill counterexample refs for result_unsafe violations now that tests exist.
            zts.property_diagnostics.fillVerifierCounterexamples(
                all_violations.items,
                handler_tests,
            );

            // Generate JSONL counterexamples and summary from all violations
            // (fault coverage, flow, and verifier combined).
            if (all_violations.items.len > 0) {
                var viol_buf: std.ArrayList(u8) = .empty;
                var viol_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &viol_buf);
                zts.property_diagnostics.writeViolationsJsonl(
                    &viol_aw.writer,
                    allocator,
                    all_violations.items,
                    handler_tests,
                ) catch {};
                viol_buf = viol_aw.toArrayList();
                if (viol_buf.items.len > 0) {
                    violations_jsonl = try viol_buf.toOwnedSlice(allocator);
                } else {
                    viol_buf.deinit(allocator);
                }

                // Pre-format violations summary for build output. Path is unknown here;
                // the emit section in main() appends the file path separately.
                var sum_buf: std.ArrayList(u8) = .empty;
                var sum_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &sum_buf);
                zts.property_diagnostics.formatViolationsSummary(
                    &sum_aw.writer,
                    all_violations.items,
                    filename,
                    null,
                ) catch {};
                sum_buf = sum_aw.toArrayList();
                if (sum_buf.items.len > 0) {
                    violations_summary = try sum_buf.toOwnedSlice(allocator);
                } else {
                    sum_buf.deinit(allocator);
                }
            }

            if (!builtin.is_test) {
                debugPrint("Generated {d} test case(s) from path analysis\n", .{test_count});
            }
        }
    }

    return .{
        .bytecode = bytecode_data,
        .contract = contract,
        .generated_tests = generated_tests_jsonl,
        .violations_jsonl = violations_jsonl,
        .violations_summary = violations_summary,
        .proof_evidence = proof_evidence,
    };
}

fn resolveImportedAtomName(
    atom_value: u32,
    atoms: ?*zts.AtomTable,
) ?[]const u8 {
    const atom: zts.Atom = @enumFromInt(atom_value);
    if (atom.isPredefined()) return atom.toPredefinedName();
    if (atoms) |table| return table.getName(atom);
    return null;
}

const VirtualImportDiagnostic = struct {
    kind: diagnostic_catalog.VirtualImportKind,
    module: []const u8,
    missing_export: ?[]const u8 = null,
    line: u32,
    column: u32,
};

fn validateVirtualModuleImports(
    view: zts.IrView,
    atoms: ?*zts.AtomTable,
    filename: []const u8,
    diagnostic_out: ?*?VirtualImportDiagnostic,
) !void {
    const node_count = view.nodeCount();
    for (0..node_count) |idx| {
        const node_idx: ir.NodeIndex = @intCast(idx);
        const tag = view.getTag(node_idx) orelse continue;
        if (tag != .import_decl) continue;

        const import_decl = view.getImportDecl(node_idx) orelse continue;
        const module_str = view.getString(import_decl.module_idx) orelse continue;
        const location = view.getLoc(node_idx);
        const line: u32 = if (location) |loc| loc.line else 1;
        const column: u32 = if (location) |loc| loc.column else 1;
        const binding = zts.builtin_modules.fromSpecifier(module_str) orelse {
            // A specifier in the built-in namespace that resolves to nothing
            // is an import of a module that does not exist, and it used to
            // pass with no diagnostic at all: `fromSpecifier` returning null
            // skipped the declaration entirely, so this function only ever
            // checked the exports of modules that were there. Removing
            // `zttp:websocket` is what made the hole visible - every handler
            // still importing it reported clean. Spec rev 4 4.5 has the rule:
            // an unknown module makes the certified build fail closed.
            //
            // `zttp-ext:` is a different namespace, resolved against the
            // session's manifest registry rather than the comptime table, and
            // is deliberately not judged here.
            if (std.mem.startsWith(u8, module_str, "zttp:")) {
                if (diagnostic_out) |out| out.* = .{
                    .kind = .unknown_module,
                    .module = module_str,
                    .line = line,
                    .column = column,
                };
                if (!builtin.is_test) debugPrint(
                    "import error: unknown module '{s}'\n  --> {s}\n  run `zttp modules` for the modules that exist\n",
                    .{ module_str, filename },
                );
                return error.UnknownVirtualModule;
            }
            continue;
        };

        var name_buf: [32][]const u8 = undefined;
        var name_count: usize = 0;
        var j: u8 = 0;
        while (j < import_decl.specifiers_count) : (j += 1) {
            const spec_idx = view.getListIndex(import_decl.specifiers_start, j);
            const spec = view.getImportSpec(spec_idx) orelse continue;
            const imported_name = resolveImportedAtomName(spec.imported_atom, atoms) orelse continue;
            if (name_count < name_buf.len) {
                name_buf[name_count] = imported_name;
                name_count += 1;
            }
        }

        if (zts.modules.validateImports(binding, name_buf[0..name_count])) |missing| {
            if (diagnostic_out) |out| out.* = .{
                .kind = .missing_export,
                .module = module_str,
                .missing_export = missing,
                .line = line,
                .column = column,
            };
            if (!builtin.is_test) debugPrint(
                "import error: module '{s}' does not export '{s}'\n  --> {s}\n",
                .{ module_str, missing, filename },
            );
            return error.InvalidImportSpecifier;
        }
    }
}

/// Scan parsed IR for file import declarations
fn hasFileImports(js_parser: *zts.parser.JsParser, _: ir.NodeIndex) bool {
    const view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const node_count = view.nodeCount();

    for (0..node_count) |idx| {
        const tag = view.getTag(@intCast(idx)) orelse continue;
        if (tag != .import_decl) continue;

        const import_decl = view.getImportDecl(@intCast(idx)) orelse continue;
        const module_str = view.getString(import_decl.module_idx) orelse continue;

        const result = zts.modules.resolver.resolve(module_str);
        switch (result) {
            .file => return true,
            .virtual, .unknown => {},
        }
    }

    return false;
}

/// Compile a handler with file imports as a multi-module bundle
pub fn discoverModulePaths(
    allocator: std.mem.Allocator,
    entry_source: []const u8,
    filename: []const u8,
) ![][]u8 {
    var graph = zts.modules.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build(filename, entry_source, readFilePosixForGraph);

    const paths = try allocator.alloc([]u8, graph.module_list.items.len);
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (graph.module_list.items, 0..) |module, index| {
        paths[index] = try allocator.dupe(u8, module.path);
        initialized += 1;
    }
    return paths;
}

pub fn freeModulePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Compile a handler with file imports as a multi-module bundle.
fn compileMultiModule(
    allocator: std.mem.Allocator,
    entry_source: []const u8,
    filename: []const u8,
    strings: *zts.StringTable,
    atoms: *zts.AtomTable,
    needs_contract: bool,
    emit_contract: bool,
    policy: ?HandlerPolicy,
    sql_schema_path: ?[]const u8,
    manifest_registry: ?*const zts.ManifestRegistry,
) !CompiledHandler {
    // Build module graph
    var graph = zts.modules.ModuleGraph.init(allocator);
    defer graph.deinit();

    graph.build(filename, entry_source, readFilePosixForGraph) catch |err| {
        if (!builtin.is_test) debugPrint("Module graph error: {}\n", .{err});
        return err;
    };

    if (!builtin.is_test) debugPrint("Module graph: {d} modules ({d} dependencies)\n", .{
        graph.module_list.items.len,
        graph.dependencyCount(),
    });

    // Compile all modules with shared atoms
    var module_compiler = zts.modules.ModuleCompiler.init(allocator, atoms, strings);
    var compile_result = module_compiler.compileAll(&graph) catch |err| {
        debugPrint("Multi-module compilation error: {}\n", .{err});
        return err;
    };
    defer compile_result.deinit();
    defer {
        for (compile_result.codegens) |*cg| cg.freeOwnedConstantPayloads();
    }

    // Serialize each module and collect dependency bytecodes
    const mod_count = compile_result.modules.len;
    var dep_bytecodes = try allocator.alloc([]const u8, mod_count - 1);
    // `alloc` returns uninitialized slices; freeing garbage pointers would
    // crash. Walk only the populated prefix on the unwind path (same idiom
    // as b8f0bbb).
    var dep_bytecodes_initialized: usize = 0;
    errdefer {
        for (dep_bytecodes[0..dep_bytecodes_initialized]) |d| allocator.free(d);
        allocator.free(dep_bytecodes);
    }

    // Serialize dependency modules (all except last, which is the entry)
    for (compile_result.modules[0 .. mod_count - 1], 0..) |*compiled_mod, i| {
        var buffer: [256 * 1024]u8 = undefined;
        var writer = zts.bytecode_cache.SliceWriter{ .buffer = &buffer };

        zts.bytecode_cache.serializeBytecodeWithAtomsAndShapes(
            &compiled_mod.func,
            atoms,
            compiled_mod.shapes,
            &writer,
            allocator,
        ) catch |err| {
            debugPrint("Dependency serialization error: {}\n", .{err});
            return err;
        };

        dep_bytecodes[i] = try allocator.dupe(u8, writer.getWritten());
        dep_bytecodes_initialized = i + 1;
    }

    // Serialize entry module (last in execution order)
    const entry_mod = &compile_result.modules[mod_count - 1];
    var entry_buffer: [256 * 1024]u8 = undefined;
    var entry_writer = zts.bytecode_cache.SliceWriter{ .buffer = &entry_buffer };

    zts.bytecode_cache.serializeBytecodeWithAtomsAndShapes(
        &entry_mod.func,
        atoms,
        entry_mod.shapes,
        &entry_writer,
        allocator,
    ) catch |err| {
        debugPrint("Entry serialization error: {}\n", .{err});
        return err;
    };

    const entry_bytecode = try allocator.dupe(u8, entry_writer.getWritten());
    errdefer allocator.free(entry_bytecode);

    if (!builtin.is_test) debugPrint("Multi-module bundle: {d} dependency modules + entry\n", .{dep_bytecodes.len});

    var contract: ?HandlerContract = null;
    if (needs_contract) {
        contract = try buildMultiModuleContract(
            allocator,
            &graph,
            &compile_result,
            atoms,
            filename,
            emit_contract,
            policy,
            sql_schema_path,
            manifest_registry,
        );
    }

    return .{
        .bytecode = entry_bytecode,
        .dep_bytecodes = dep_bytecodes,
        .contract = contract,
    };
}

const readFilePosixForGraph = zts.file_io.readFileForModuleGraph;

fn analyzeAot(
    allocator: std.mem.Allocator,
    js_parser: *zts.parser.JsParser,
    atoms: *zts.AtomTable,
    root: ir.NodeIndex,
) !?AotAnalysis {
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const handler_fn = findHandlerFunction(ir_view, root) orelse return null;

    var analyzer = zts.HandlerAnalyzer.init(allocator, ir_view, atoms);
    defer analyzer.deinit();
    analyzer.enableJsonBodyParsePatterns();

    var dispatch = try analyzer.analyze(handler_fn);
    const default_response = try analyzer.analyzeDirectReturn(handler_fn);

    if (dispatch) |d| {
        const emittable = countAotPatterns(d);
        if (emittable == 0) {
            d.deinit();
            allocator.destroy(d);
            dispatch = null;
        }
    }

    if (dispatch == null and default_response == null) {
        return null;
    }

    return .{
        .dispatch = dispatch,
        .default_response = default_response,
    };
}

fn countAotPatterns(dispatch: *const zts.PatternDispatchTable) usize {
    var count: usize = 0;
    for (dispatch.patterns) |pattern| {
        switch (pattern.pattern_type) {
            .exact => count += 1,
            .prefix => {},
            else => {},
        }
    }
    return count;
}

const findHandlerFunction = zts.findHandlerFunction;

const ContractExtractionOptions = struct {
    aot: ?AotAnalysis = null,
    verification: ?VerificationInfo = null,
    imported_effects: []const zts.pipeline.ImportedEffect = &.{},
};

fn extractContractFromAnalysis(
    analysis: *zts.pipeline.ModuleAnalysisSession,
    filename: []const u8,
    opts: ContractExtractionOptions,
) !HandlerContract {
    try analysis.setContractContext(.{
        .dispatch = if (opts.aot) |aot_analysis| aot_analysis.dispatch else null,
        .has_default_response = if (opts.aot) |aot_analysis| aot_analysis.default_response != null else false,
        .verification = opts.verification,
        .imported_effects = opts.imported_effects,
    });
    return analysis.extractContract(filename);
}

fn projectCompletedFlow(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    flow: ?*const zts.FlowChecker,
    flow_errors: u32,
    fresh: bool,
    violations_out: ?*std.ArrayList(zts.property_diagnostics.PropertyViolation),
    ir_view: zts.IrView,
) !void {
    if (flow) |completed| {
        const flow_diags = completed.getDiagnostics();
        if (fresh and flow_diags.len > 0 and !builtin.is_test) {
            debugPrint("\n", .{});
            var flow_output: std.ArrayList(u8) = .empty;
            defer flow_output.deinit(allocator);
            var flow_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &flow_output);
            completed.formatDiagnostics(zts.SourceView.of(""), &flow_aw.writer) catch {};
            flow_output = flow_aw.toArrayList();
            if (flow_output.items.len > 0) debugPrint("{s}", .{flow_output.items});
            debugPrint("{d} flow error(s), {d} warning(s)\n", .{
                flow_errors,
                flow_diags.len - flow_errors,
            });
        }

        const flow_props = completed.getProperties();
        if (contract.properties) |*props| {
            props.no_secret_leakage = flow_props.no_secret_leakage;
            props.no_credential_leakage = flow_props.no_credential_leakage;
            props.input_validated = flow_props.input_validated;
            props.pii_contained = flow_props.pii_contained;
            props.injection_safe = flow_props.injection_safe;
            props.deterministic = props.deterministic and flow_props.deterministic;
            props.idempotent = props.deterministic and props.retry_safe;
        }
        if (violations_out) |vout| {
            zts.property_diagnostics.collectFlowViolations(allocator, vout, flow_diags, ir_view);
        }
        if (fresh and !builtin.is_test and flow_errors == 0) debugPrint("Flow analysis passed\n", .{});
    }
}

fn validateContractPolicyInputs(
    allocator: std.mem.Allocator,
    filename: []const u8,
    contract: *HandlerContract,
    sql_schema_path: ?[]const u8,
    policy: ?HandlerPolicy,
) !void {
    try validateSqlContract(allocator, contract, sql_schema_path);
    try enforcePolicyForContract(allocator, filename, contract, policy);
    if (policy != null and !builtin.is_test) debugPrint("Capability policy check passed\n", .{});
}

fn buildContractOnlyFromParsed(
    allocator: std.mem.Allocator,
    parsed: zts.pipeline.ParsedModule,
    filename: []const u8,
    sql_schema_path: ?[]const u8,
    manifest_registry: ?*const zts.ManifestRegistry,
) !HandlerContract {
    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initContractOnly(
        allocator,
        parsed,
        .{
            .extraction = .{ .manifest_registry = manifest_registry },
            .select_flow = true,
        },
    );
    defer analysis.deinit();
    try analysis.complete();

    var contract = try extractContractFromAnalysis(
        &analysis,
        filename,
        .{},
    );
    errdefer contract.deinit(allocator);

    const handler_func = findHandlerFunction(parsed.ir_view, parsed.root);
    if (handler_func) |hf| {
        const flow_errors = try analysis.runFlow(hf);
        try projectCompletedFlow(
            allocator,
            &contract,
            try analysis.completedFlow(),
            flow_errors,
            true,
            null,
            parsed.ir_view,
        );
    } else {
        try projectCompletedFlow(allocator, &contract, null, 0, true, null, parsed.ir_view);
    }
    try validateContractPolicyInputs(allocator, filename, &contract, sql_schema_path, null);
    return contract;
}

fn buildMultiModuleContract(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    atoms: *zts.AtomTable,
    entry_filename: []const u8,
    emit_contract: bool,
    policy: ?HandlerPolicy,
    sql_schema_path: ?[]const u8,
    manifest_registry: ?*const zts.ManifestRegistry,
) !HandlerContract {
    var merged = try handler_contract.initMergedContract(allocator, entry_filename);
    errdefer merged.deinit(allocator);

    const entry_index = compile_result.modules.len - 1;
    var policy_checked = false;
    var loaded_effects: std.ArrayList(zts.pipeline.LoadedModuleEffects) = .empty;
    defer {
        for (loaded_effects.items) |*loaded| loaded.deinit(allocator);
        loaded_effects.deinit(allocator);
    }

    for (compile_result.modules, compile_result.parsers, 0..) |compiled_module, *js_parser, idx| {
        const graph_idx = graph.execution_order[idx];
        const module = &graph.module_list.items[graph_idx];
        const is_entry = idx == entry_index;

        var temp_aot = if (is_entry and emit_contract)
            try analyzeAot(allocator, js_parser, atoms, compiled_module.root)
        else
            null;
        defer if (temp_aot) |*aot| aot.deinit(allocator);

        const module_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        const parsed = zts.pipeline.ParsedModule.fromExisting(module_view, compiled_module.root, atoms);
        var module_analysis: zts.pipeline.ModuleAnalysisSession = .{};
        try module_analysis.initContractOnly(
            allocator,
            parsed,
            .{ .extraction = .{
                .dispatch = if (temp_aot) |analysis| analysis.dispatch else null,
                .has_default_response = if (temp_aot) |analysis| analysis.default_response != null else false,
                .manifest_registry = manifest_registry,
                .capture_export_effects = true,
            } },
        );
        defer module_analysis.deinit();
        try module_analysis.complete();

        const imported_effects = try zts.pipeline.importedEffectsForLoadedModule(
            allocator,
            graph,
            graph_idx,
            try module_analysis.facts(),
            loaded_effects.items,
        );
        defer allocator.free(imported_effects);
        try module_analysis.setImportedEffects(imported_effects);

        var module_contract = try module_analysis.extractContract(module.path);
        defer module_contract.deinit(allocator);
        var pending_export_effects = module_analysis.takeExportEffects();
        errdefer if (pending_export_effects) |*effects| effects.deinit(allocator);
        try loaded_effects.append(allocator, .{
            .graph_index = graph_idx,
            .effects = pending_export_effects orelse return error.AnalysisPassIncomplete,
        });
        pending_export_effects = null;

        try validateSqlContract(allocator, &module_contract, sql_schema_path);
        try enforcePolicyForContract(allocator, module.path, &module_contract, policy);
        if (policy != null) policy_checked = true;

        try handler_contract.mergeModuleContract(allocator, &merged, &module_contract, is_entry);
    }

    if (policy_checked) {
        if (!builtin.is_test) debugPrint("Capability policy check passed\n", .{});
    }

    return merged;
}

/// Validate `zttp:sql` queries against a schema database. SQLite is a C
/// dependency unavailable on freestanding/wasm, and the analyzer build has no
/// `--sql-schema` input, so the native implementation is referenced only
/// inside the comptime-gated branch and stays out of the wasm module graph.
fn validateSqlContract(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    sql_schema_path: ?[]const u8,
) !void {
    if (comptime builtin.target.os.tag != .freestanding) {
        return validateSqlContractNative(allocator, contract, sql_schema_path);
    }
}

fn validateSqlContractNative(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    sql_schema_path: ?[]const u8,
) !void {
    if (contract.sql.queries.items.len == 0) return;

    const schema_path = sql_schema_path orelse {
        if (!builtin.is_test) {
            debugPrint("zttp:sql queries require --sql-schema <schema.sql|schema.sqlite>\n", .{});
        }
        return error.MissingSqlSchema;
    };

    var db = try openSqlSchemaDatabase(allocator, schema_path);
    defer db.close();

    for (contract.sql.queries.items) |*query| {
        var analysis = zts.analyzeSqlStatement(allocator, query.statement) catch |err| {
            if (!builtin.is_test) {
                debugPrint("Unsupported SQL statement for query '{s}': {s}\n", .{ query.name, query.statement });
            }
            return err;
        };
        defer analysis.deinit(allocator);

        var stmt = db.prepare(query.statement) catch {
            if (!builtin.is_test) {
                debugPrint("SQL validation failed for query '{s}': {s}\n", .{ query.name, db.errmsg() });
            }
            return error.InvalidSqlQuery;
        };
        defer stmt.finalize();

        try ensureNamedParameters(&stmt, query.name);

        query.operation = analysis.operation.toString();
        for (query.tables.items) |table| allocator.free(table);
        query.tables.clearAndFree(allocator);
        for (analysis.tables.items) |table| {
            try handler_contract.appendUniqueString(allocator, &query.tables, table, false);
        }
    }
}

fn openSqlSchemaDatabase(allocator: std.mem.Allocator, schema_path: []const u8) !sqlite.Db {
    if (std.mem.endsWith(u8, schema_path, ".sql")) {
        const schema_source = try readFilePosix(allocator, schema_path, 10 * 1024 * 1024);
        defer allocator.free(schema_source);

        var db = try sqlite.Db.openInMemory();
        errdefer db.close();
        try db.exec(allocator, schema_source);
        return db;
    }

    return sqlite.Db.openReadOnly(allocator, schema_path);
}

fn ensureNamedParameters(stmt: *sqlite.Stmt, query_name: []const u8) !void {
    const count = stmt.paramCount();
    for (1..count + 1) |idx| {
        if (stmt.paramName(idx) == null) {
            if (!builtin.is_test) {
                debugPrint("SQL query '{s}' uses positional parameters; only named parameters are supported\n", .{query_name});
            }
            return error.PositionalSqlParameter;
        }
    }
}

fn enforcePolicyForContract(
    allocator: std.mem.Allocator,
    label_path: []const u8,
    contract: *const HandlerContract,
    policy: ?HandlerPolicy,
) !void {
    const p = policy orelse return;

    var report = try handler_policy.validateContract(allocator, contract, &p);
    defer report.deinit(allocator);

    if (!report.hasViolations()) return;

    if (!@import("builtin").is_test) {
        debugPrint("\nCapability policy violations in {s}:\n", .{label_path});
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
        handler_policy.formatViolations(&report, &aw.writer) catch {};
        output = aw.toArrayList();
        if (output.items.len > 0) {
            debugPrint("{s}", .{output.items});
        }
    }
    return error.PolicyViolation;
}

/// The check-path counterpart of `enforcePolicyForContract`.
///
/// Same validation, different verdict shape: a build refuses to emit, a check
/// reports and keeps going, so every violation reaches the author (and the
/// veto) at once rather than the first one aborting the run.
///
/// A policy that will not parse is itself a diagnostic. Returning silently
/// would make a typo in `zttp.json` read as "no violations", which is the
/// fail-open this whole path exists to close.
fn appendPolicyDiagnostics(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    contract: *const HandlerContract,
    policy_source: []const u8,
    handler_path: []const u8,
) !void {
    var policy = handler_policy.parsePolicyJson(allocator, policy_source) catch {
        const message = try allocator.dupe(u8, "capability policy is not valid JSON, or its sections are not objects");
        errdefer allocator.free(message);
        try result.json_diagnostics.append(allocator, .{
            .code = diagnostic_catalog.driverCode(.compiler_io_failure),
            .severity = "error",
            .message = message,
            .file = handler_path,
            .line = 0,
            .column = 0,
            .suggestion = "check the `policy` entry in zttp.json points at a well-formed policy file",
            .message_owned = true,
        });
        result.policy_errors += 1;
        return;
    };
    defer policy.deinit(allocator);

    var report = try handler_policy.validateContract(allocator, contract, &policy);
    defer report.deinit(allocator);

    for (report.violations.items) |violation| {
        const kind = diagnostic_catalog.policyKind(violation.category, violation.kind);
        const message = switch (violation.kind) {
            .literal_not_allowed => try std.fmt.allocPrint(
                allocator,
                "{s} '{s}' is not in the capability policy allow-list",
                .{ handler_policy.categoryLiteralLabel(violation.category), violation.value orelse "" },
            ),
        };
        errdefer allocator.free(message);

        try result.json_diagnostics.append(allocator, .{
            .code = diagnostic_catalog.policyCode(kind),
            .severity = "error",
            .message = message,
            .file = handler_path,
            .line = 0,
            .column = 0,
            .suggestion = "add it to the policy file, or remove the access from the handler",
            .message_owned = true,
        });
        result.policy_errors += 1;
    }
}

fn printSandboxReport(contract: *const HandlerContract) void {
    const env_restricted = !contract.env.dynamic;
    const egress_restricted = !contract.egress.dynamic;
    const cache_restricted = !contract.cache.dynamic;
    const sql_restricted = !contract.sql.dynamic;

    if (env_restricted and egress_restricted and cache_restricted and sql_restricted) {
        debugPrint("Sandbox: complete (all access statically proven)\n", .{});
    } else {
        debugPrint("Sandbox derived from contract:\n", .{});
    }

    printSandboxSection("env", contract.env.literal.items, env_restricted, "no dynamic access");
    printSandboxSection("egress", contract.egress.endpoints.items, egress_restricted, "no dynamic access");
    printSandboxSection("cache", contract.cache.namespaces.items, cache_restricted, "no dynamic access");
    printSqlSandboxSection(contract);
}

fn printPropertiesReport(contract: *const HandlerContract) void {
    const props = contract.properties orelse return;

    debugPrint("Handler Properties:\n", .{});

    const fields = [_]struct { name: []const u8, value: bool, desc: []const u8 }{
        .{ .name = "pure", .value = props.pure, .desc = "handler is a deterministic function of the request" },
        .{ .name = "read_only", .value = props.read_only, .desc = "no state mutations via virtual modules" },
        .{ .name = "stateless", .value = props.stateless, .desc = "independent of mutable state" },
        .{ .name = "retry_safe", .value = props.retry_safe, .desc = "safe for Lambda auto-retry on timeout" },
        .{ .name = "deterministic", .value = props.deterministic, .desc = "no Date.now(), Math.random(), or performance.now()" },
        .{ .name = "injection_safe", .value = props.injection_safe, .desc = "no unvalidated input in sinks" },
        .{ .name = "idempotent", .value = props.idempotent, .desc = "safe for at-least-once delivery" },
        .{ .name = "state_isolated", .value = props.state_isolated, .desc = "no cross-request data leakage" },
        .{ .name = "result_safe", .value = props.result_safe, .desc = "all result.ok accesses guarded (requires -Dverify)" },
        .{ .name = "optional_safe", .value = props.optional_safe, .desc = "all optionals narrowed before use (requires -Dverify)" },
    };

    for (fields) |f| {
        const label = if (f.value) "PROVEN" else "---   ";
        debugPrint("  {s} {s: <15} {s}\n", .{ label, f.name, f.desc });
    }

    if (props.max_io_depth) |depth| {
        debugPrint("  PROVEN {s: <15} max {d} I/O calls per request\n", .{ "max_io_depth", depth });
    }
    if (contract.cost_envelope) |envelope| {
        switch (envelope.total) {
            .constant => {},
            .linear => |linear| {
                debugPrint(
                    "  PROVEN {s: <15} total <= {d}+{d}*|source| calls per request ({s})\n",
                    .{ "cost_envelope", linear.base, linear.coefficient, linear.source.desc },
                );
            },
            .unbounded => |source| {
                debugPrint("  ---    {s: <15} unbounded ({s})\n", .{ "cost_envelope", source.desc });
            },
        }
    }
}

fn printSqlSandboxSection(contract: *const HandlerContract) void {
    if (contract.sql.dynamic) {
        debugPrint("  sql: unrestricted (dynamic access detected)\n", .{});
        return;
    }
    if (contract.sql.queries.items.len == 0) {
        debugPrint("  sql: restricted to [] (none proven, no dynamic access)\n", .{});
        return;
    }

    debugPrint("  sql: restricted to [", .{});
    for (contract.sql.queries.items, 0..) |query, idx| {
        if (idx > 0) debugPrint(", ", .{});
        debugPrint("{s}", .{query.name});
    }
    debugPrint("] ({d} proven, no dynamic access)\n", .{contract.sql.queries.items.len});
}

fn printSandboxSection(name: []const u8, items: []const []const u8, restricted: bool, reason: []const u8) void {
    if (!restricted) {
        debugPrint("  {s}: unrestricted (dynamic access detected)\n", .{name});
        return;
    }
    if (items.len == 0) {
        debugPrint("  {s}: restricted to [] (none proven, {s})\n", .{ name, reason });
        return;
    }
    debugPrint("  {s}: restricted to [", .{name});
    for (items, 0..) |item, i| {
        if (i > 0) debugPrint(", ", .{});
        debugPrint("{s}", .{item});
    }
    debugPrint("] ({d} proven, {s})\n", .{ items.len, reason });
}

/// Derive contract.json path from the output .zig path.
const deriveSiblingPath = util.deriveSiblingPath;

fn writeZigFile(
    path: []const u8,
    compiled: CompiledHandler,
    policy: ?HandlerPolicy,
    allocator: std.mem.Allocator,
) !void {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
    const writer = &aw.writer;

    try writer.writeAll("//! Auto-generated embedded handler bytecode\n");
    try writer.writeAll("//! Do not edit - regenerate with: zig build -Dhandler=<path>\n");
    try writer.writeAll("\n");

    try writer.writeAll("const std = @import(\"std\");\n");
    try writer.writeAll("const zq = @import(\"zts\");\n\n");

    try writer.writeAll("pub const bytecode = [_]u8{\n");
    try writeBytecodeArray(writer, compiled.bytecode);
    try writer.writeAll("};\n");

    // Write dependency module bytecodes if present
    if (compiled.dep_bytecodes) |deps| {
        try writer.print("\npub const dep_count: u16 = {d};\n\n", .{deps.len});
        for (deps, 0..) |dep, i| {
            try writer.print("const dep_{d} = [_]u8{{\n", .{i});
            try writeBytecodeArray(writer, dep);
            try writer.writeAll("};\n\n");
        }
        try writer.print("pub const dep_bytecodes = [_][]const u8{{\n", .{});
        for (0..deps.len) |i| {
            try writer.print("    &dep_{d},\n", .{i});
        }
        try writer.writeAll("};\n");
    } else {
        try writer.writeAll("\npub const dep_count: u16 = 0;\n");
        try writer.writeAll("pub const dep_bytecodes = [_][]const u8{};\n");
    }

    const contract_ptr = if (compiled.contract) |*c| c else null;
    try writeCapabilityPolicy(writer, policy, contract_ptr);

    output = aw.toArrayList();
    try writeFilePosix(path, output.items, allocator);
}

fn writeCapabilityPolicy(writer: anytype, policy: ?HandlerPolicy, contract: ?*const HandlerContract) !void {
    try writer.writeAll("\npub const capability_policy = @import(\"zts\").handler_policy.RuntimePolicy{\n");
    if (policy) |p| {
        // Explicit policy takes precedence
        try writePolicySectionFromAllowList(writer, "env", p.env);
        try writePolicySectionFromAllowList(writer, "egress", p.egress);
        try writePolicySectionFromAllowList(writer, "cache", p.cache);
        try writePolicySectionFromAllowList(writer, "sql", p.sql);
    } else if (contract) |c| {
        // Auto-derive from contract proven facts
        try writeContractDerivedSection(writer, "env", c.env.literal.items, c.env.dynamic);
        try writeContractDerivedSection(writer, "egress", c.egress.endpoints.items, c.egress.dynamic);
        try writeContractDerivedSection(writer, "cache", c.cache.namespaces.items, c.cache.dynamic);
        try writeSqlContractDerivedSection(writer, c);
    } else {
        // No policy, no contract: permissive
        try writePolicySectionFromAllowList(writer, "env", null);
        try writePolicySectionFromAllowList(writer, "egress", null);
        try writePolicySectionFromAllowList(writer, "cache", null);
        try writePolicySectionFromAllowList(writer, "sql", null);
    }
    try writer.print("    .egress_scopes = .{{ .bits = {d} }},\n", .{
        if (policy) |p| p.egress_scopes.bits else 0,
    });
    try writer.writeAll("};\n");
    try writer.writeAll("pub const runtime_policy_index_required = ");
    try writer.writeAll(if (contract) |c|
        if (handler_policy.contractRequiresRuntimePolicyIndex(c)) "true;\n" else "false;\n"
    else
        "false;\n");
}

fn writePolicySectionFromAllowList(writer: anytype, field_name: []const u8, section: ?handler_policy.AllowList) !void {
    try writer.print("    .{s} = ", .{field_name});
    if (section) |allow| {
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (allow.values.items.len == 0) {
            try writer.writeAll("        .values = &[_][]const u8{},\n");
        } else {
            try writer.writeAll("        .values = &[_][]const u8{\n");
            for (allow.values.items) |item| {
                try writer.writeAll("            ");
                try writeZigStringLiteral(writer, item);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
        return;
    }
    try writer.writeAll(".{},\n");
}

/// Write a policy section derived from contract proven facts.
/// When dynamic is false, restrict to exactly the proven literals.
/// When dynamic is true, leave permissive.
fn writeContractDerivedSection(writer: anytype, field_name: []const u8, literals: []const []const u8, dynamic: bool) !void {
    try writer.print("    .{s} = ", .{field_name});
    if (!dynamic) {
        // Static: restrict to proven literals
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (literals.len == 0) {
            try writer.writeAll("        .values = &[_][]const u8{},\n");
        } else {
            try writer.writeAll("        .values = &[_][]const u8{\n");
            for (literals) |item| {
                try writer.writeAll("            ");
                try writeZigStringLiteral(writer, item);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    } else {
        // Dynamic: can't restrict
        try writer.writeAll(".{},\n");
    }
}

fn writeSqlContractDerivedSection(writer: anytype, contract: *const HandlerContract) !void {
    // Emit the per-query allowlist with each query's operation so the
    // precompiled binary enforces the db.read/db.write split (not a flat,
    // operation-agnostic name list).
    try writer.writeAll("    .sql = ");
    if (!contract.sql.dynamic) {
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (contract.sql.queries.items.len == 0) {
            try writer.writeAll("        .queries = &[_]@import(\"zts\").handler_policy.SqlQueryInfo{},\n");
        } else {
            try writer.writeAll("        .queries = &[_]@import(\"zts\").handler_policy.SqlQueryInfo{\n");
            for (contract.sql.queries.items) |query| {
                const op = if (handler_policy.sqlQueryIsReadOnly(query)) "select" else "write";
                try writer.writeAll("            .{ .name = ");
                try writeZigStringLiteral(writer, query.name);
                try writer.print(", .operation = \"{s}\", .statement = \"\" }},\n", .{op});
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    } else {
        try writer.writeAll(".{},\n");
    }
}

fn writeBytecodeArray(writer: anytype, bytecode_data: []const u8) !void {
    var i: usize = 0;
    while (i < bytecode_data.len) {
        try writer.writeAll("    ");
        const row_end = @min(i + 16, bytecode_data.len);
        while (i < row_end) {
            const byte = bytecode_data[i];
            var buf: [5]u8 = undefined;
            buf[0] = '0';
            buf[1] = 'x';
            buf[2] = hexChar(@truncate(byte >> 4));
            buf[3] = hexChar(@truncate(byte & 0x0f));
            buf[4] = ',';
            try writer.writeAll(buf[0..]);
            i += 1;
            if (i < row_end) try writer.writeAll(" ");
        }
        try writer.writeAll("\n");
    }
}

fn writeZigStringLiteral(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                var buf: [4]u8 = undefined;
                buf[0] = '\\';
                buf[1] = 'x';
                buf[2] = hexChar(@truncate(c >> 4));
                buf[3] = hexChar(@truncate(c & 0x0f));
                try writer.writeAll(&buf);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}

fn hexChar(n: u4) u8 {
    const hex_chars = "0123456789abcdef";
    return hex_chars[n];
}

const CompileGraphFixture = struct {
    tmp: std.testing.TmpDir,
    entry_source: []const u8,
    entry_path: [:0]u8,

    fn init(entry_name: []const u8, entry_source: []const u8) !CompileGraphFixture {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry_name, .data = entry_source });
        const entry_path = try tmp.dir.realPathFileAlloc(std.testing.io, entry_name, allocator);
        return .{ .tmp = tmp, .entry_source = entry_source, .entry_path = entry_path };
    }

    fn deinit(self: *CompileGraphFixture) void {
        std.testing.allocator.free(self.entry_path);
        self.tmp.cleanup();
    }

    fn add(self: *CompileGraphFixture, name: []const u8, source: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = source });
    }

    fn compile(self: *const CompileGraphFixture, opts: CompileOptions) !CompiledHandler {
        return compileHandler(std.testing.allocator, self.entry_source, self.entry_path, opts);
    }
};

fn expectSameGraphArtifact(first: *const CompiledHandler, second: *const CompiledHandler) !void {
    try std.testing.expectEqualSlices(u8, first.bytecode, second.bytecode);

    const first_deps = first.dep_bytecodes orelse return error.TestUnexpectedResult;
    const second_deps = second.dep_bytecodes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first_deps.len, second_deps.len);
    for (first_deps, second_deps) |first_dep, second_dep| {
        try std.testing.expectEqualSlices(u8, first_dep, second_dep);
    }

    var first_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first_json.deinit();
    try writeContractJson(&first.contract.?, &first_json.writer);
    var second_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second_json.deinit();
    try writeContractJson(&second.contract.?, &second_json.writer);
    try std.testing.expectEqualStrings(first_json.written(), second_json.written());
}

test "compileHandler aggregates contract across file imports" {
    const entry_source =
        \\import { readSecret } from "./dep.ts";
        \\export function handler(req) {
        \\  return Response.text(readSecret());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readSecret() {
        \\  return env("JWT_SECRET") ?? "";
        \\}
    ;

    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts", dep_source);

    const allocator = std.testing.allocator;
    var policy = try handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"JWT_SECRET\"]}}");
    defer policy.deinit(allocator);

    var compiled = try fixture.compile(.{
        .emit_contract = true,
        .policy = policy,
    });
    defer compiled.deinit(allocator);

    try std.testing.expect(compiled.dep_bytecodes != null);
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.env.literal.items.len);
    try std.testing.expectEqualStrings("JWT_SECRET", contract.env.literal.items[0]);
}

test "compileHandler keeps merged properties null after loaded graph effects" {
    const entry_source =
        \\import { saveAlias } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  saveAlias();
        \\  return Response.text("ok");
        \\}
        \\
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { cacheSet } from "zttp:cache";
        \\function save(): undefined { cacheSet("items", "key", "value"); return undefined; }
        \\export const saveAlias = save;
        \\
    );

    var compiled = try fixture.compile(.{ .emit_contract = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
    const merged = compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(merged.properties == null);
}

test "compileHandler rejects disallowed policy from imported module" {
    const entry_source =
        \\import { readSecret } from "./dep.ts";
        \\export function handler(req) {
        \\  return Response.text(readSecret());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readSecret() {
        \\  return env("JWT_SECRET") ?? "";
        \\}
    ;

    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts", dep_source);

    const allocator = std.testing.allocator;
    var policy = try handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"PUBLIC_KEY\"]}}");
    defer policy.deinit(allocator);

    try std.testing.expectError(
        error.PolicyViolation,
        fixture.compile(.{ .policy = policy }),
    );
}

test "compileHandler graph accepts current type boolean and strict diagnostics" {
    // Single-module checks reject these nodes. Graph compilation currently accepts them.
    const typed_dependency =
        \\export function count(): number {
        \\  const value: number = "wrong";
        \\  return value;
        \\}
        \\
    ;
    const typed_entry =
        \\import { count } from "./dep.ts";
        \\const typedMarker: number = 1;
        \\export function handler(req) {
        \\  if (5) return Response.text(String(count() + typedMarker));
        \\  return Response.text("zero");
        \\}
        \\
    ;
    const untyped_entry =
        \\import { count } from "./dep.ts";
        \\export function handler(req) {
        \\  return Response.text(String(count()));
        \\}
        \\
    ;
    const cases = [_][]const u8{ typed_entry, untyped_entry };

    for (cases) |entry_source| {
        var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
        defer fixture.deinit();
        try fixture.add("dep.ts", typed_dependency);

        var strict = try fixture.compile(.{ .emit_contract = true, .strict = true });
        defer strict.deinit(std.testing.allocator);
        var relaxed = try fixture.compile(.{ .emit_contract = true, .strict = false });
        defer relaxed.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), strict.dep_bytecodes.?.len);
        try expectSameGraphArtifact(&strict, &relaxed);
    }

    var unsupported = try CompileGraphFixture.init("entry.js", untyped_entry);
    defer unsupported.deinit();
    try unsupported.add("dep.ts", typed_dependency);
    try std.testing.expectError(error.UnsupportedSourceExtension, unsupported.compile(.{}));
}

test "compileHandler preserves fanout order shared dependencies and imported routes" {
    const entry_source =
        \\import { left } from "./left.ts";
        \\import { right } from "./right.ts";
        \\export function handler(req: Request): Response {
        \\  left(req);
        \\  return right(req);
        \\}
        \\
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("left.ts",
        \\import { env } from "zttp:env";
        \\import { shared } from "./shared.ts";
        \\export function left(req: Request): Response {
        \\  shared(req);
        \\  return Response.text(env("LEFT_SECRET") ?? "");
        \\}
        \\
    );
    try fixture.add("right.ts",
        \\import { env } from "zttp:env";
        \\import { shared } from "./shared.ts";
        \\export function right(req: Request): Response {
        \\  shared(req);
        \\  return Response.text(env("RIGHT_SECRET") ?? "");
        \\}
        \\
    );
    try fixture.add("shared.ts",
        \\import { env } from "zttp:env";
        \\import { routerMatch } from "zttp:router";
        \\function status(req: Request): Response {
        \\  return Response.text(env("SHARED_SECRET") ?? "ok");
        \\}
        \\const routes = { "GET /shared": status };
        \\export function shared(req: Request): Response {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.text("missing", { status: 404 });
        \\}
        \\
    );

    var first = try fixture.compile(.{ .emit_contract = true });
    defer first.deinit(std.testing.allocator);
    var second = try fixture.compile(.{ .emit_contract = true });
    defer second.deinit(std.testing.allocator);
    try expectSameGraphArtifact(&first, &second);

    try std.testing.expectEqual(@as(usize, 3), first.dep_bytecodes.?.len);
    const contract = &first.contract.?;
    try std.testing.expectEqual(@as(usize, 3), contract.env.literal.items.len);
    try std.testing.expectEqualStrings("SHARED_SECRET", contract.env.literal.items[0]);
    try std.testing.expectEqualStrings("LEFT_SECRET", contract.env.literal.items[1]);
    try std.testing.expectEqualStrings("RIGHT_SECRET", contract.env.literal.items[2]);
    try std.testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
    try std.testing.expectEqualStrings("GET", contract.api.routes.items[0].method);
    try std.testing.expectEqualStrings("/shared", contract.api.routes.items[0].path);
    try std.testing.expect(contract.verification == null);
    try std.testing.expect(contract.properties == null);
    try std.testing.expect(contract.fault_coverage == null);
}

fn buildTestContractForSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    sql_schema_path: ?[]const u8,
) !HandlerContract {
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    var js_parser = try zts.parser.JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const root = try js_parser.parse();
    const view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    return buildContractOnlyFromParsed(
        allocator,
        zts.pipeline.ParsedModule.fromExisting(view, root, &atoms),
        filename,
        sql_schema_path,
        null,
    );
}

fn failContractTypeCheck(_: *zts.TypeChecker, _: ir.NodeIndex) anyerror!u32 {
    return error.OutOfMemory;
}

test "contract construction propagates type-check allocation failure" {
    const allocator = std.testing.allocator;
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    const source = "function handler(req) { return Response.text('ok'); }";
    var js_parser = try zts.parser.JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = try js_parser.parse();
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = zts.pipeline.ParsedModule.fromExisting(ir_view, root, &atoms);

    try std.testing.expectError(
        error.OutOfMemory,
        zts.pipeline.extractContractFromParsed(
            allocator,
            parsed,
            "<contract-type-oom>",
            .{ .type_check = failContractTypeCheck },
        ),
    );
}

test "runCheckOnly propagates path analysis allocation failure" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const value = env("NAME") ?? "world";
        \\  return Response.text(value);
        \\}
    ;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        runCheckOnlyFromSourceWithPathAllocator(
            std.testing.allocator,
            failing.allocator(),
            source,
            "path-analysis-entrypoint-oom.ts",
            .{},
        ),
    );
}

const AllocationImportReader = struct {
    file_count: usize,
    reads: usize = 0,

    fn read(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *AllocationImportReader = @ptrCast(@alignCast(raw));
        self.reads += 1;
        // The unused import needs no flow summary. A missing first read keeps
        // the chain fixture focused on the whole-file fault scan.
        if (self.file_count > 1 and self.reads == 1) return error.FileNotFound;
        const name = std.fs.path.basename(path);
        if (!std.mem.startsWith(u8, name, "lib") or !std.mem.endsWith(u8, name, ".ts")) return error.FileNotFound;
        const index = try std.fmt.parseInt(usize, name[3 .. name.len - 3], 10);
        if (index >= self.file_count) return error.FileNotFound;
        if (index + 1 == self.file_count) return allocator.dupe(u8, "export function helper(): string { return 'ok'; }");
        return std.fmt.allocPrint(
            allocator,
            "import {{ helper as next }} from './lib{d}.ts'; export function helper(): string {{ return next(); }}",
            .{index + 1},
        );
    }
};

fn checkImportAllocationFixture(allocator: std.mem.Allocator, reader: *AllocationImportReader) !CheckResult {
    const source =
        \\import { helper } from "./lib0.ts";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage" | "canonical" | "cost_bounded"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    return runCheckOnlyFromSourceWithOptions(allocator, source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = .{ .context = reader, .read = AllocationImportReader.read },
    });
}

fn expectImportAllocationCleanup(file_count: usize) !void {
    var baseline_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer baseline_arena.deinit();
    var counted = std.testing.FailingAllocator.init(baseline_arena.allocator(), .{});
    var reader: AllocationImportReader = .{ .file_count = file_count };
    var baseline = try checkImportAllocationFixture(counted.allocator(), &reader);
    {
        defer baseline.deinit(counted.allocator());
        try std.testing.expectEqual(@as(u32, 0), baseline.totalErrors());
        try std.testing.expectEqual(@as(u32, 1), baseline.paths_enumerated);
        try std.testing.expectEqual(file_count + 1, reader.reads);
        const contract = baseline.contract orelse return error.TestUnexpectedResult;
        const coverage = contract.fault_coverage orelse return error.TestUnexpectedResult;
        try std.testing.expect(coverage.analysis_complete);
        try std.testing.expectEqual(@as(u32, 0), coverage.unseen_calls);
    }
    try std.testing.expect(counted.alloc_index > 0);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);

    // Accounting checks every release through CHECK's allocator. The arena
    // also reclaims a failed probe's storage before the next failure point.
    for (0..counted.alloc_index) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_index });
        var failed_reader: AllocationImportReader = .{ .file_count = file_count };
        if (checkImportAllocationFixture(failing.allocator(), &failed_reader)) |value| {
            var result = value;
            result.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        if (failing.allocated_bytes != failing.freed_bytes) {
            std.debug.print("CHECK import cleanup: files={d}, failure_index={d}\n", .{ file_count, fail_index });
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "CHECK releases allocations when a sibling import scan fails" {
    try expectImportAllocationCleanup(1);
}

test "CHECK releases allocations when a nested import scan fails" {
    try expectImportAllocationCleanup(max_import_depth - 1);
}

/// Determinism lives here rather than in `contract_builder.zig`: the contract
/// builder answers only whether there was a handler to walk, and the flow walk
/// that decides the property runs in this file. Its test helper never ran that
/// walk, so the assertions below were passing on a value nothing had computed.
fn contractDeterminism(allocator: std.mem.Allocator, source: []const u8) !struct { deterministic: bool, idempotent: bool } {
    var contract = try buildTestContractForSource(allocator, source, "handler.ts", null);
    defer contract.deinit(allocator);
    const props = contract.properties orelse return error.MissingProperties;
    return .{ .deterministic = props.deterministic, .idempotent = props.idempotent };
}

test "a varying read that only reaches a log keeps determinism" {
    // The property the flow answer exists to give back: the timestamp reaches
    // stderr and stops, so the response is the same on every run. The presence
    // rules demoted this handler, and `idempotent` with it.
    const props = try contractDeterminism(std.testing.allocator,
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", { at: Date.now() });
        \\  return Response.json({ ok: true });
        \\}
    );
    try std.testing.expect(props.deterministic);
}

test "a minted id in the response costs determinism and idempotence" {
    // `idempotent` is derived from determinism, and is re-derived after the
    // flow answer lands. Without that it read PROVEN beside a cleared
    // `deterministic` - the worse of the two to get wrong, since it means safe
    // under at-least-once delivery.
    const props = try contractDeterminism(std.testing.allocator,
        \\import { uuid } from "zttp:id";
        \\function handler(req) { return Response.json({ id: uuid() }); }
    );
    try std.testing.expect(!props.deterministic);
    try std.testing.expect(!props.idempotent);
}

test "buildTestContractForSource keeps decodeQuery schemas out of request bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { schemaCompile } from "zttp:validate";
        \\import { decodeQuery } from "zttp:decode";
        \\
        \\schemaCompile("search.query", JSON.stringify({
        \\  type: "object",
        \\  properties: {
        \\    verbose: { type: "boolean" },
        \\  },
        \\}));
        \\
        \\function search(req) {
        \\  const query = decodeQuery("search.query", req.query ?? {});
        \\  return Response.json(true);
        \\}
        \\
        \\const routes = {
        \\  "GET /search": search,
        \\};
        \\
        \\export function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) return found.handler(req);
        \\  return Response.json({ error: "not found" }, { status: 404 });
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = source });

    const allocator = std.testing.allocator;
    const entry_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(entry_path);

    var contract = try buildTestContractForSource(allocator, source, entry_path, null);
    defer contract.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
    const route = contract.api.routes.items[0];
    try std.testing.expectEqualStrings("GET", route.method);
    try std.testing.expectEqualStrings("/search", route.path);
    try std.testing.expectEqual(@as(usize, 1), route.query_params.items.len);
    try std.testing.expectEqualStrings("verbose", route.query_params.items[0].name);
    try std.testing.expectEqualStrings("{\"type\":\"boolean\"}", route.query_params.items[0].schema_json);
    try std.testing.expectEqual(@as(usize, 0), route.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), route.request_schema_refs.items.len);
}

test "schema contract preserves supported JSON stringify literal bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\schemaCompile("matrix", JSON.stringify({
        \\  type: "object",
        \\  "required": ["title", "count", "enabled", "items"],
        \\  properties: {
        \\    title: { type: "string", description: "line\nquote:\" slash:\\ tab:\t" },
        \\    count: { type: "number", minimum: -1.5, maximum: 2.25 },
        \\    enabled: { type: "boolean", default: true },
        \\    items: { type: "array", items: { type: "integer" } },
        \\    absent: null,
        \\    examples: [0, -2, 3.5, false, null],
        \\  },
        \\}));
        \\function handler(req) { return Response.json({ ok: true }); }
    ;

    var contract = try buildTestContractForSource(allocator, source, "schema-matrix.ts", null);
    defer contract.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.api.schemas.items.len);
    try std.testing.expect(!contract.api.schemas_dynamic);
    try std.testing.expectEqualStrings("matrix", contract.api.schemas.items[0].name);
    try std.testing.expectEqualStrings(
        "{\"type\": \"object\", \"required\": [\"title\", \"count\", \"enabled\", \"items\"], \"properties\": {\"title\": {\"type\": \"string\", \"description\": \"line\\nquote:\\\" slash:\\\\ tab:\\t\"}, \"count\": {\"type\": \"number\", \"minimum\": -1.5, \"maximum\": 2.25}, \"enabled\": {\"type\": \"boolean\", \"default\": true}, \"items\": {\"type\": \"array\", \"items\": {\"type\": \"integer\"}}, \"absent\": null, \"examples\": [0, -2, 3.5, false, null]}}",
        contract.api.schemas.items[0].schema_json,
    );
}

test "schema contract retains raw JSON bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\schemaCompile("raw", ' { "type" : "string" } ');
        \\function handler(req) { return Response.text("ok"); }
    ;

    var contract = try buildTestContractForSource(allocator, source, "raw-schema.ts", null);
    defer contract.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.api.schemas.items.len);
    try std.testing.expect(!contract.api.schemas_dynamic);
    try std.testing.expectEqualStrings(" { \"type\" : \"string\" } ", contract.api.schemas.items[0].schema_json);
}

test "schema contract marks readable dynamic forms and malformed raw JSON dynamic" {
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{
        \\import { schemaCompile } from "zttp:validate";
        \\const schema = { type: "object" };
        \\schemaCompile("direct", schema);
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\const schema = { type: "object" };
        \\schemaCompile("stringify-root", JSON.stringify(schema));
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\const base = { type: "object" };
        \\schemaCompile("spread", JSON.stringify({ ...base, properties: {} }));
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\const values = ["string", "number"];
        \\schemaCompile("array-spread", JSON.stringify({ enum: ["boolean", ...values] }));
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\function schemaType() { return "object"; }
        \\schemaCompile("call", JSON.stringify({ type: schemaType() }));
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\function register() {
        \\  const JSON = { stringify: (value) => "ignored" };
        \\  schemaCompile("local-shadow", JSON.stringify({ type: "object" }));
        \\}
        \\register();
        \\function handler(req) { return Response.text("ok"); }
        ,
        \\import { schemaCompile } from "zttp:validate";
        \\schemaCompile("malformed", '{"type":');
        \\function handler(req) { return Response.text("ok"); }
    };

    for (cases) |source| {
        var contract = try buildTestContractForSource(allocator, source, "dynamic-schema.ts", null);
        try std.testing.expectEqual(@as(usize, 0), contract.api.schemas.items.len);
        try std.testing.expect(contract.api.schemas_dynamic);
        contract.deinit(allocator);
    }
}

test "schema contract keeps the current top-level JSON shadow behavior" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\const JSON = { stringify: (value) => "ignored" };
        \\schemaCompile("global-shadow", JSON.stringify({ type: "string" }));
        \\function handler(req) { return Response.text("ok"); }
    ;

    var contract = try buildTestContractForSource(allocator, source, "global-json-shadow.ts", null);
    defer contract.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), contract.api.schemas.items.len);
    try std.testing.expect(!contract.api.schemas_dynamic);
    try std.testing.expectEqualStrings(
        "{\"type\": \"string\"}",
        contract.api.schemas.items[0].schema_json,
    );
}

test "schema contract refuses computed object keys before extraction" {
    const allocator = std.testing.allocator;
    const source =
        \\import { schemaCompile } from "zttp:validate";
        \\const key = "type";
        \\schemaCompile("computed", JSON.stringify({ [key]: "object" }));
        \\function handler(req) { return Response.text("ok"); }
    ;

    const result = buildTestContractForSource(allocator, source, "computed-schema-key.ts", null);
    if (result) |built| {
        var contract = built;
        contract.deinit(allocator);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.ParseError, err);
    }
}

test "runCheckOnlyFromSource: helper reaching outside its Effects ceiling gets ZTS503" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): Effects<string, "env"> {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "ceiling.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_503 = false;
    var saw_505 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .effect_undeclared and std.mem.eql(u8, d.spec_name, "crypto")) saw_503 = true;
        if (d.kind == .effect_over_declared and std.mem.eql(u8, d.spec_name, "env")) saw_505 = true;
    }
    try std.testing.expect(saw_503);
    try std.testing.expect(saw_505);
    try std.testing.expect(contract.function_effect_capsules.items.len >= 1);
}

test "runCheckOnlyFromSource: helper exceeding handler Effects budget gets ZTS607" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "env"> {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "budget.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_607 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .helper_budget_exceeded) {
            saw_607 = true;
            try std.testing.expectEqualStrings("crypto", d.spec_name);
            try std.testing.expectEqualStrings("digest", d.function.?);
        }
    }
    try std.testing.expect(saw_607);
    // The handler's declared budget is recorded on the contract.
    try std.testing.expectEqual(@as(u8, 1), contract.capability_budget.len);
}

test "runCheckOnlyFromSource: canonical reused arrow helper fails strict check" {
    const allocator = std.testing.allocator;
    const source =
        \\const parse = (x: number): number => x;
        \\
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-arrow.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_608 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS608")) {
            saw_608 = true;
            try std.testing.expectEqualStrings("error", d.severity);
        }
    }
    try std.testing.expect(saw_608);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: one-way public helper effects diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\nominal Digest = string;
        \\
        \\export function digest(s: Digest): Digest {
        \\  const out: Digest = sha256(s);
        \\  return out;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  const seed: Digest = "x";
        \\  return Response.text(digest(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-effects.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_610 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS610")) {
            saw_610 = true;
            try std.testing.expectEqualStrings("error", d.severity);
        }
    }
    try std.testing.expect(saw_610);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: one-way public helper proof diagnostic" {
    const allocator = std.testing.allocator;
    const source =
        \\nominal Stable = string;
        \\
        \\export function stable(s: Stable): Stable {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const seed: Stable = "x";
        \\  return Response.text(stable(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_611 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS611")) {
            saw_611 = true;
            try std.testing.expectEqualStrings("error", d.severity);
        }
    }
    try std.testing.expect(saw_611);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: proof capsule diagnostic covers an unreachable exported helper" {
    const allocator = std.testing.allocator;
    // `unrelated` is exported and the handler never calls it. Export is what
    // the rule conditions on: the module's public surface owes its callers a
    // capsule whether or not this handler is one of them.
    const source =
        \\nominal Unrelated = string;
        \\
        \\export function unrelated(s: Unrelated): Unrelated {
        \\  return s;
        \\}
        \\
        \\function stable(s: string): string {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text(stable("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-unrelated-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_611 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS611")) saw_611 = true;
    }
    try std.testing.expect(saw_611);
    try std.testing.expect(result.canonical_errors > 0);
}

test "runCheckOnlyFromSource: proof capsule diagnostic ignores non-capsule specs" {
    const allocator = std.testing.allocator;
    const source =
        \\nominal Stable = string;
        \\
        \\export function stable(s: Stable): Stable {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const seed: Stable = "x";
        \\  return Response.text(stable(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-result-safe-proof.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    for (result.json_diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS611"));
    }
    try std.testing.expectEqual(@as(u32, 0), result.canonical_errors);
}

test "formatProofCard: canonical public helper diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\nominal Digest = string;
        \\
        \\export function digest(s: Digest): Digest {
        \\  const out: Digest = sha256(s);
        \\  return out;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  const seed: Digest = "x";
        \\  return Response.text(digest(seed));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-effects-text.ts", .{});
    defer result.deinit(allocator);
    try std.testing.expect(result.canonical_errors > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "one-way-effects-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Canonical diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS610") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "one-way-effects-text.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Effects<...>") != null);
}

test "formatProofCard: capability policy diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const value = env("OTHER_NAME") ?? "x";
        \\  return Response.json({ value: value });
        \\}
    ;
    const policy_source =
        \\{ "env": { "allow": ["APP_NAME"] } }
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "policy-text.ts", .{
        .policy_source = policy_source,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), result.policy_errors);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "policy-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Capability policy diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "POL001") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "OTHER_NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "add it to the policy file") != null);
}

test "runCheckOnlyWithOptions: json mode emits ZTS000 for an unreadable handler" {
    const allocator = std.testing.allocator;
    // A missing handler in JSON mode must produce a structured ZTS000 result,
    // not a propagated Zig error that would dump a raw stack trace to IDE/CI.
    var result = try runCheckOnlyWithOptions(
        allocator,
        "/nonexistent/zttp-cli2-missing.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(StageSet.initEmpty(), result.stages_run);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS000", diagnostic.code);
    try std.testing.expectEqualStrings("error", diagnostic.severity);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "cannot read handler file") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.file, "zttp-cli2-missing.ts") != null);
    try std.testing.expect(result.contract == null);
    try std.testing.expect(result.properties == null);
    try std.testing.expect(result.proof_trace_json == null);
}

test "runCheckOnlyWithOptions: non-json mode still propagates a missing-handler error" {
    const allocator = std.testing.allocator;
    // Without --json, the readable line is printed and the error propagates so
    // the CLI maps it to a clean exit; assert the error path is preserved.
    try std.testing.expectError(
        error.FileNotFound,
        runCheckOnlyWithOptions(allocator, "/nonexistent/zttp-cli2-missing.ts", .{ .json_mode = false }),
    );
}

test "compileHandler keeps its default missing-handler outputs" {
    var compiled = try compileHandler(
        std.testing.allocator,
        "const value = 1;",
        "shared-analysis-missing-handler.ts",
        .{},
    );
    defer compiled.deinit(std.testing.allocator);

    try std.testing.expect(compiled.bytecode.len > 0);
    try std.testing.expect(!compiled.verify_failed);
    try std.testing.expect(compiled.proof_evidence == null);
    const contract = &(compiled.contract orelse return error.MissingContract);
    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.deterministic);
    try std.testing.expect(!props.result_safe);
    try std.testing.expect(!props.optional_safe);
    try std.testing.expect(contract.fault_coverage == null);
}

test "formatProofCard: spec-less handler renders ZTS500 lines matching the footer count" {
    const allocator = std.testing.allocator;
    // A handler with no Proof<T, P> activates the default proof profile, whose
    // unsatisfiable properties trip error-severity ZTS500 spec diagnostics.
    // Those used to be counted in the footer but never printed; assert they
    // now render and that the printed error lines equal the footer count.
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "spec-less-text.ts", .{});
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var spec_err_count: usize = 0;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err) spec_err_count += 1;
    }
    try std.testing.expect(spec_err_count > 0);
    // The footer count is exactly the error-severity spec diagnostics for this
    // handler (no other error category fires), so the printed lines must match.
    try std.testing.expectEqual(@as(u32, @intCast(spec_err_count)), result.totalErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "spec-less-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Spec diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS500") != null);

    // Count printed error-severity spec lines: each renders as "    ZTSxxx (error) ".
    var printed: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, buf.items, search_from, " (error) ")) |pos| {
        printed += 1;
        search_from = pos + " (error) ".len;
    }
    try std.testing.expectEqual(spec_err_count, printed);
}

test "formatProofCard: the card names the demotion site --json already carried" {
    // The two surfaces were said to share one source of truth, and did not:
    // `--json` printed "; demoted at line L:C by `snippet`" from `diag.cause`
    // and the card spelled its own suffix without it. So `zttp check` named the
    // failing spec and left out the line number, which is the half that turns
    // one property into one edit.
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ at: Date.now() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "demoted-text.ts", .{});
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var caused: usize = 0;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err and d.cause != null) caused += 1;
    }
    // The floor: with no caused diagnostic the assertions below would pass over
    // a card that renders nothing at all.
    try std.testing.expect(caused > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "demoted-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "demoted at line") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Date.now()") != null);
}

test "formatProofCard: strict canonical diagnostics are visible in text mode" {
    const allocator = std.testing.allocator;
    const source =
        \\const parse = (x: number): number => x;
        \\
        \\function handler(req: Request): Response {
        \\  const a = parse(1);
        \\  const b = parse(2);
        \\  return Response.json({ a: a, b: b });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "one-way-arrow-text.ts", .{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.canonical_errors);
    try std.testing.expect(result.strict_errors > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "one-way-arrow-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Canonical diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ZTS608") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "one-way-arrow-text.ts") != null);
}

test "runCheckOnlyFromSource: composed Spec and Effects preserves handler budget diagnostics" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Proof<Effects<Response, "env">, "state_isolated"> {
        \\  return Response.text(sha256("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "composed-budget.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    var saw_506 = false;
    var saw_json_506 = false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .budget_exceeded and std.mem.eql(u8, d.spec_name, "crypto")) {
            saw_506 = true;
            try std.testing.expect(d.function == null);
        }
    }
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS506")) saw_json_506 = true;
    }
    try std.testing.expect(saw_506);
    try std.testing.expect(saw_json_506);
}

test "runCheckOnlyFromSource: missing capsule ignores unreachable helpers" {
    const allocator = std.testing.allocator;
    const source =
        \\function unused(): string {
        \\  return String(Date.now());
        \\}
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unreachable-capsule.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind == .missing_capsule) return error.TestUnexpectedResult;
    }
}

test "runCheckOnlyFromSource: handler Effects budget covering reached capabilities is clean" {
    const allocator = std.testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(sha256("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "ok.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        try std.testing.expect(d.kind != .budget_exceeded);
        try std.testing.expect(d.kind != .helper_budget_exceeded);
    }
}

test "runCheckOnlyFromSource: a helper with no Effects ceiling is never flagged" {
    const allocator = std.testing.allocator;
    // `digest` reaches crypto but declares no `Effects<...>` ceiling, and the
    // handler declares no budget. Capsules are opt-in: nothing is flagged.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest("x"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "noceiling.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    for (contract.spec_diagnostics.items) |d| {
        try std.testing.expect(d.kind != .effect_undeclared);
        try std.testing.expect(d.kind != .effect_over_declared);
        try std.testing.expect(d.kind != .budget_exceeded);
        try std.testing.expect(d.kind != .helper_budget_exceeded);
    }
}

test "holes: each site reports its expected type and the unspent budget" {
    const allocator = std.testing.allocator;
    // Two holes in different return positions. The handler's budget declares
    // three capabilities and spends two, so `crypto` is what is left to spend
    // filling either hole.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function slug(s: string): string {
        \\  return hole();
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "env" | "policy_check" | "crypto"> {
        \\  if (req.method === "GET") {
        \\    return Response.json({ region: env("REGION"), slug: slug("x") });
        \\  }
        \\  return hole();
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);

    var saw_slug = false;
    var saw_handler = false;
    for (contract.holes.items) |h| {
        if (std.mem.eql(u8, h.function, "slug")) {
            saw_slug = true;
            try std.testing.expectEqualStrings("string", h.expected_type);
        }
        if (std.mem.eql(u8, h.function, "handler")) {
            saw_handler = true;
            // The capsule expansion is erased: the returned value never carries
            // the phantom marker field, so reporting it would be a lie about
            // what the expression must construct.
            try std.testing.expectEqualStrings("Response", h.expected_type);
        }
        try std.testing.expect(h.budget_declared);
        try std.testing.expectEqual(@as(usize, 1), h.remaining_budget.items.len);
        try std.testing.expectEqualStrings("crypto", h.remaining_budget.items[0]);
    }
    try std.testing.expect(saw_slug);
    try std.testing.expect(saw_handler);
}

test "holes: each site reports the properties its own function has not discharged" {
    const allocator = std.testing.allocator;
    // The handler declares no Spec, so the default profile demands the full
    // set and reports every property it does not hold. `mint` breaks two the
    // handler needs and carries no capsule declaring them (ZTS606), so a hole
    // in `mint` owes those rather than the handler's list.
    const source =
        \\import { uuid } from "zttp:id";
        \\
        \\function mint(): string {
        \\  const v = uuid();
        \\  return hole();
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  if (req.method === "GET") return Response.json({ id: mint() });
        \\  return hole();
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);

    for (contract.holes.items) |h| {
        // Every entry is a single property name. The implicit default profile
        // reports its failures as one comma-joined diagnostic, which is right
        // for the HUD and useless to a consumer that wants to match on names.
        try std.testing.expect(h.undischarged.items.len > 0);
        for (h.undischarged.items) |name| {
            try std.testing.expect(std.mem.indexOfScalar(u8, name, ',') == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, name, ' ') == null);
        }

        if (std.mem.eql(u8, h.function, "mint")) {
            // Attributed to the helper, so the handler's own failures are not
            // on this list: `pure` is there because `mint` breaks it, not
            // because the handler does.
            var saw_deterministic = false;
            for (h.undischarged.items) |name| {
                if (std.mem.eql(u8, name, "deterministic")) saw_deterministic = true;
            }
            try std.testing.expect(saw_deterministic);
        }
    }
}

test "holes: each site reports the bindings it can be filled from" {
    const allocator = std.testing.allocator;
    // `later` is declared below the hole, so it is not material an expression
    // there can use, and neither is the hole's own binding.
    const source =
        \\function handler(req: Request): Response {
        \\  const early: string = "a";
        \\  const filled: string = hole();
        \\  const later: number = 3;
        \\  return Response.json({ filled: filled, later: later });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 2), in_scope.len);
    // The parameter first, then declarations in the order they were written.
    try std.testing.expectEqualStrings("req", in_scope[0].name);
    try std.testing.expectEqualStrings("Request", in_scope[0].type_name);
    try std.testing.expectEqualStrings("early", in_scope[1].name);
    try std.testing.expectEqualStrings("string", in_scope[1].type_name);
}

test "holes: a binding with no annotation is reported as unknown" {
    const allocator = std.testing.allocator;
    // An honest absence rather than a guess: an agent that reads a wrong type
    // writes an expression that does not compile.
    const source =
        \\import { uuid } from "zttp:id";
        \\function mint(): string {
        \\  const v = uuid();
        \\  return hole();
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ id: mint() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 1), in_scope.len);
    try std.testing.expectEqualStrings("v", in_scope[0].name);
    try std.testing.expectEqualStrings("unknown", in_scope[0].type_name);
}

test "holes: a hole inside a nested function declaration is attributed to the enclosing function" {
    const allocator = std.testing.allocator;
    // A function declaration holds its function as the `init` of var_decl
    // data. Reading it as function data left the hole with no owner.
    const source =
        \\function handler(req: Request): Response {
        \\  const outer: string = "a";
        \\  function inner(): string {
        \\    const local: string = "b";
        \\    return hole();
        \\  }
        \\  return Response.json({ v: inner() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    try std.testing.expectEqualStrings("handler", contract.holes.items[0].function);

    const in_scope = contract.holes.items[0].in_scope.items;
    try std.testing.expectEqual(@as(usize, 3), in_scope.len);
    try std.testing.expectEqualStrings("req", in_scope[0].name);
    try std.testing.expectEqualStrings("outer", in_scope[1].name);
    try std.testing.expectEqualStrings("local", in_scope[2].name);
}

test "holes: a hole inside a nested function declaration expects the nested function's return type" {
    const allocator = std.testing.allocator;
    // The hole is attributed to the enclosing function, which keeps its scope,
    // but the expression it stands for returns from the nested function, so
    // the expected type is the nested declaration's, not the handler's. The
    // innermost declaration wins.
    const source =
        \\function handler(req: Request): Response {
        \\  function inner(): string {
        \\    return hole();
        \\  }
        \\  function outer(): string {
        \\    function deep(): number {
        \\      return hole();
        \\    }
        \\    return String(deep());
        \\  }
        \\  return Response.json({ v: inner(), w: outer() });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "holes.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 2), contract.holes.items.len);
    for (contract.holes.items) |h| try std.testing.expectEqualStrings("handler", h.function);
    try std.testing.expectEqualStrings("string", contract.holes.items[0].expected_type);
    try std.testing.expectEqualStrings("number", contract.holes.items[1].expected_type);
}

test "holes: a finished program reports none" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "done.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = if (result.contract) |*c| c else return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 0), contract.holes.items.len);
}

test "ZTS623: a module-internal helper may not declare an Effects ceiling" {
    const allocator = std.testing.allocator;
    // Spec 5.7 makes placement decidable: exported with a nonempty row MUST
    // declare, module-internal MUST NOT. The internal ceiling proves nothing
    // the compiler does not infer, and ZTS607 already bounds the helper through
    // the handler's budget.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): Effects<string, "crypto"> {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(digest("zttp"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "internal.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_623 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS623")) saw_623 = true;
    }
    try std.testing.expect(saw_623);
}

test "ZTS623: dropping the internal ceiling satisfies the placement rule" {
    const allocator = std.testing.allocator;
    // Same program with the internal ceiling removed. The handler's budget
    // still bounds `digest`, so nothing about the proof weakens.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\
        \\function digest(s: string): string {
        \\  sha256(s);
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(digest("zttp"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "internal.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    for (result.json_diagnostics.items) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS623"));
        // The budget check must still be satisfied: no helper-budget breach.
        try std.testing.expect(!std.mem.eql(u8, d.code, "ZTS607"));
    }
}

test "appendExportCapsuleDiagnostics: the docs mode asks only for a Proof capsule" {
    const allocator = std.testing.allocator;
    // The effects half of this mode retired with ZTS507: once ZTS610 stopped
    // testing `handler_reachable`, it refused exactly the helpers the warning
    // asked about, so the flag now covers the proof half alone.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\nominal Region = string;
        \\
        \\export function region(): Region {
        \\  const value: Region = env("REGION") ?? "unknown";
        \\  return value;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(region());
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "docs.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    appendExportCapsuleDiagnostics(allocator, &result, "docs.ts");

    var saw_507 = false;
    var saw_508 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS507")) saw_507 = true;
        if (std.mem.eql(u8, d.code, "ZTS508")) saw_508 = true;
    }
    try std.testing.expect(!saw_507);
    try std.testing.expect(saw_508);
    // The capability that would have been ZTS507's subject is still reported,
    // unconditionally and as an error, by the always-on rule.
    var saw_610 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS610")) saw_610 = true;
    }
    try std.testing.expect(saw_610);
}

test "runCheckOnly keeps mirrored properties aligned with finalized fault coverage" {
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\
        \\function handler(req: Request): Proof<Response, "fault_covered"> {
        \\  const auth = jwtVerify("token", "secret");
        \\  if (!auth.ok) {
        \\    return Response.text("unauthorized", { status: 401 });
        \\  }
        \\  return Response.text("ok");
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expect(result.fault_total > 0);

    const mirrored = result.properties orelse return error.MissingProperties;
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const finalized = contract.properties orelse return error.MissingProperties;

    try std.testing.expect(finalized.fault_covered);
    try std.testing.expectEqual(finalized.fault_covered, mirrored.fault_covered);
}

test "runCheckOnlyFromSource keeps diagnostics off stderr in test mode" {
    // Regression guard: every non-JSON std.debug.print diagnostic in
    // runCheckOnlyFromSource must stay gated behind !builtin.is_test.
    // The Zig build runner flags any test that writes to stderr, so a
    // dropped gate here turns a passing test into a build failure
    // (this is exactly how the strict-diagnostic leak was caught).
    const source =
        \\function handler(req: Request): Response {
        \\  const path = req.path;
        \\  const data = fetchSync(["https://example.internal", path].join(""));
        \\  return Response.json(data);
        \\}
    ;

    // json_mode = false routes diagnostics through the std.debug.print path.
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{});
    defer result.deinit(std.testing.allocator);

    // Strict mode (default) rejects the implicit-unknown fetchSync result.
    try std.testing.expect(result.strict_errors > 0);
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource: ZTS202 arg-count message survives json capture without use-after-free" {
    // Regression (ENG-3): the ZTS202/ZTS203 dynamic message is allocPrint'd on
    // the checker allocator, which the pipeline tears down before the JSON is
    // serialized. fromCheckerDiagnostic must dupe the message into the
    // long-lived CheckResult allocator at capture time, or the --json /
    // edit-simulate surface reads freed bytes (0xaa in debug). Using the
    // leak-checked testing.allocator also proves the new owned-message path has
    // no leak or double-free.
    const allocator = std.testing.allocator;
    const source =
        \\function digest(s: string): string {
        \\  return s;
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(digest());
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "argcount.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_202 = false;
    for (result.json_diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.code, "ZTS202")) continue;
        saw_202 = true;
        // The message must be intact, not freed-memory garbage.
        try std.testing.expect(std.unicode.utf8ValidateSlice(d.message));
        try std.testing.expect(std.mem.indexOfScalar(u8, d.message, 0xaa) == null);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "wrong number of arguments") != null);
    }
    try std.testing.expect(saw_202);
}

test "a pure-typed callback parameter contributes the empty row" {
    const allocator = std.testing.allocator;
    // D2 section 4's I3: a function type with no capsule declares the empty
    // row - spec 6.5's "its callback MUST be pure" made representable. The
    // call through `f` used to defeat the row entirely and report ZTS512.
    const source =
        \\nominal Count = number;
        \\
        \\export function apply(f: (n: number) => number, x: Count): Effects<number, "clock"> {
        \\  return f(x);
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "pure-callback.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var saw_512 = false;
    var saw_505 = false;
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, "ZTS512")) saw_512 = true;
        if (std.mem.eql(u8, d.code, "ZTS505")) saw_505 = true;
    }
    try std.testing.expect(!saw_512);
    // The row is empty, so declaring "clock" is over-declaration - a real
    // answer about the program where there had been a refusal to answer.
    try std.testing.expect(saw_505);
}

test "an unreached exported helper with a nonempty row reports ZTS610" {
    const allocator = std.testing.allocator;
    // Spec 5.7 says "an exported function with a nonempty inferred effect row
    // MUST declare" with no reachability condition. `unused` is never called
    // from the handler and still owes a ceiling.
    const source =
        \\import { env } from "zttp:env";
        \\
        \\structural OptionalSecret = string | undefined;
        \\
        \\export function unused(): OptionalSecret {
        \\  return env("API_KEY");
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unreached-helper.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var repair: ?[]const u8 = null;
    for (result.json_diagnostics.items) |d| {
        if (!std.mem.eql(u8, d.code, "ZTS610")) continue;
        repair = d.suggestion;
    }
    const found = repair orelse return error.MissingZTS610;
    // The repair is computed from the inferred row, not a fixed string.
    try std.testing.expect(std.mem.indexOf(u8, found, "env") != null);
}

test "zts check --types path rejects exported handler local mismatch" {
    const source =
        \\export function handler(req: Request): Response {
        \\  const n: number = "not a number";
        \\  return Response.json({});
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "exported-local.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expect(result.totalErrors() >= 1);
}

test "check reports a boolean error and a type error on different nodes" {
    // The type stage and the boolean stage each find a different mistake. The
    // check used to stop at the first stage with errors and show one of them.
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  if (5) {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text(String(m));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "two-stages.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.bool_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS100", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[1].code);
}

test "check reports one message for a condition that is a refused operator" {
    // `n + "y"` is the type error and also the condition. The boolean checker
    // would add ZTS100 for the same expression.
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  if (n + "y") {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "one-node.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.bool_errors);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[0].code);
}

test "check reports a strict error beside a type error" {
    // An unannotated handler is ZTS601, and the refused sum is ZTS105.
    const source =
        \\function handler(req: Request) {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  return Response.text(String(m));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "strict-beside.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.strict_errors);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS105", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS601", result.json_diagnostics.items[1].code);
}

test "check still stops before the verifier when a computed stage has an error" {
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const n: number = 1;
        \\  if (n + "y") {
        \\    return Response.text("a");
        \\  }
        \\  return Response.text("b");
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "stops.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.totalErrors() > 0);
    try std.testing.expect(!result.verify_ran);
}

test "runCheckOnlyFromSource: no Spec activates all supported specs for TS" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "default-specs.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(zts.spec_discharge.v1_specs.len, contract.declared_specs.items.len);
    for (zts.spec_discharge.v1_specs) |spec| {
        try std.testing.expect(handler_contract.containsString(contract.declared_specs.items, spec.name));
    }
    try std.testing.expect(result.totalErrors() > 0);
}

test "runCheckOnlyFromSource refuses unsupported source extensions with ZTS052" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    for ([_][]const u8{ "handler.js", "handler.tsx" }) |filename| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, filename, .{
            .json_mode = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings("ZTS052", result.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings(filename, result.json_diagnostics.items[0].file);
        try std.testing.expect(result.contract == null);
    }
}

test "runCheckOnlyFromSource refuses raw JSX in TypeScript with ZTS002" {
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.html(<main>hello</main>);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS002", result.json_diagnostics.items[0].code);
    try std.testing.expect(result.contract == null);
}

test "CHECK reports collected strip refusals before an earlier parse failure" {
    const source =
        \\const broken = ;
        \\const asserted = "asserted" as string;
        \\const constrained = "constrained" satisfies string;
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "mixed-errors.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS042", result.json_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("ZTS043", result.json_diagnostics.items[1].code);
    try std.testing.expect(result.contract == null);

    try std.testing.expectError(error.UnsupportedAsAssertion, compileHandler(std.testing.allocator, source, "mixed-errors.ts", .{}));
}

test "CHECK keeps the current tolerated annotation text suffix" {
    const source =
        \\function handler(req: Request): Response {
        \\  const text: string tolerated_suffix = "ready";
        \\  return Response.text(text);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "annotation-suffix.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK retains the recognized type before a tolerated annotation suffix" {
    const source =
        \\function handler(req: Request): Response {
        \\  const text: string tolerated_suffix = 1;
        \\  return Response.text(text);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "annotation-suffix.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    const expected = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    try std.testing.expectEqual(expected, result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try std.testing.expectEqualStrings("ZTS200", result.json_diagnostics.items[0].code);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource treats declared comptime as an ordinary function" {
    const source =
        \\function comptime(value: string): string { return value; }
        \\function handler(req: Request): Response {
        \\  return Response.text(comptime("ready"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

test "runCheckOnlyFromSource refuses unbound comptime and resource through ZTS629" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        ambient: []const u8,
    }{
        .{
            .name = "comptime.ts",
            .source =
            \\function handler(req: Request): Response {
            \\  return Response.text(String(comptime("ready")));
            \\}
            ,
            .ambient = "comptime",
        },
        .{
            .name = "resource.ts",
            .source =
            \\function handler(req: Request): Response {
            \\  return Response.text(String(resource("item")));
            \\}
            ,
            .ambient = "resource",
        },
    };

    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, case.name, .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);

        const diagnostic = for (result.json_diagnostics.items) |candidate| {
            if (std.mem.eql(u8, candidate.code, "ZTS629")) break candidate;
        } else return error.TestExpectedEqual;
        var expected_message: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(&expected_message, "unpublished ambient global '{s}'", .{case.ambient});
        try std.testing.expectEqualStrings(message, diagnostic.message);
        try std.testing.expect(result.contract == null);
    }
}

test "runCheckOnlyFromSource refuses legacy zttp types import with ZTS053" {
    const allocator = std.testing.allocator;
    const source =
        \\import type { Spec } from "zttp:types";
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS053", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses default parameters with ZTS054" {
    const allocator = std.testing.allocator;
    const source =
        \\function label(prefix: string = "item"): string {
        \\  return prefix;
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS054", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional parameter shorthand with ZTS055" {
    const allocator = std.testing.allocator;
    const source =
        \\function label(prefix?: string): string {
        \\  return prefix ?? "item";
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS055", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "replace `name?: T` with `name: T | undefined`",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses default exports with ZTS056" {
    const allocator = std.testing.allocator;
    const source =
        \\export default function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS056", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "write a named export, for example `export function handler(...) { ... }`",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses mutable exports with ZTS057" {
    const allocator = std.testing.allocator;
    const source =
        \\export let version: number = 1;
        \\export function handler(req: Request): Response {
        \\  return Response.json({ version: version });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS057", diagnostic.code);
    try std.testing.expectEqualStrings("handler.ts", diagnostic.file);
    try std.testing.expectEqualStrings(
        "use `export const` for module values and keep reassignment inside a function activation",
        diagnostic.suggestion.?,
    );
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses Array generic spelling with ZTS058" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(items: Array<number>): number {
        \\  return items[0];
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS058", diagnostic.code);
    try std.testing.expectEqualStrings("write `T[]`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses ReadonlyArray generic spelling with ZTS059" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(items: ReadonlyArray<number>): number {
        \\  return items[0];
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS059", diagnostic.code);
    try std.testing.expectEqualStrings("write `readonly T[]`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses void type spelling with ZTS060" {
    const allocator = std.testing.allocator;
    const source =
        \\function ignore(value: string): void {
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS060", diagnostic.code);
    try std.testing.expectEqualStrings("write `undefined`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource reports ZTS061 for a raw exported boundary" {
    const allocator = std.testing.allocator;
    const source =
        \\export function expose(value: string): string {
        \\  return value;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.text(expose("ok"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    var zts061_count: usize = 0;
    for (result.json_diagnostics.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.code, "ZTS061")) continue;
        zts061_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "type `string` exposes raw `string`") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), zts061_count);
    try std.testing.expectEqual(@as(u32, 2), result.strict_errors);
}

test "runCheckOnlyFromSource explicitly refuses unary void" {
    const allocator = std.testing.allocator;
    const source =
        \\const ignored = void 0;
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("evaluate the operand as a statement when its effects are required, then use `undefined` explicitly", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses debugger statements" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  debugger;
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove the statement", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses empty statements" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  ;
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove the standalone `;`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses when wildcard arms" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const status = match (req.method) {
        \\    when _: 200,
        \\  };
        \\  return Response.json({ status: status });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("write `default:`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses object declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const { method, url } = req;
        \\  return Response.json({ method: method, url: url });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each member with explicit `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses destructuring renames" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const { method: requestMethod } = req;
        \\  return Response.json({ method: requestMethod });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each member with explicit `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses array declaration destructuring" {
    const allocator = std.testing.allocator;
    const source =
        \\function first(pair: [string, number]): string {
        \\  const [name, count] = pair;
        \\  return name + String(count);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("bind the source to a name, then read each element with explicit indexed `const` bindings", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses object literal shorthand" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.method;
        \\  return Response.json({ value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("write the field and value explicitly, for example `{ value: value }`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses computed record keys" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const key = req.method;
        \\  return Response.json({ [key]: "value" });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("use a literal field name, or `Dict` for dynamic keys", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses the in operator" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const present = "authorization" in req.headers;
        \\  return Response.json({ present: present });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("use the explicit predicate for the value kind, such as `dictHas`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses unary plus" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = +req.path;
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("remove it from a number expression, or use an admitted boundary parser for text", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional calls" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.callback?.();
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("check for `undefined`, then call the function directly", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses optional computed access" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const value = req.headers?.["authorization"];
        \\  return Response.json({ value: value });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("check for `undefined`, then use indexed access", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses template interpolation" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const message = `hello ${req.method}`;
        \\  return Response.text(message);
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS001", diagnostic.code);
    try std.testing.expectEqualStrings("build a string array with explicit `String(...)` conversions and call `.join(\"\")`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses string addition" {
    const allocator = std.testing.allocator;
    const source =
        \\function concatText(left: string, right: string): string {
        \\  return left + right;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.text(concatText("hello ", "world"));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS105", diagnostic.code);
    try std.testing.expectEqualStrings("build a string array with explicit `String(...)` conversions and call `.join(\"\")`", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource keeps numeric addition" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const total = 20 + 22;
        \\  return Response.json({ total: total });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource refuses an unpublished ambient global" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  const secret = process.env.JWT_SECRET;
        \\  return Response.json({ authenticated: secret !== undefined });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.strict_errors);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    const diagnostic = result.json_diagnostics.items[0];
    try std.testing.expectEqualStrings("ZTS629", diagnostic.code);
    try std.testing.expectEqualStrings("unpublished ambient global 'process'", diagnostic.message);
    try std.testing.expectEqualStrings("Import a published virtual-module capability or use an ambient name listed by meta.ambient_names.", diagnostic.suggestion.?);
    try std.testing.expect(result.contract == null);
}

test "runCheckOnlyFromSource repairs raw fetchSync through zttp fetch" {
    const source =
        \\function handler(req: Request): Response {
        \\  return fetchSync("https://example.internal");
        \\}
    ;

    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);

    const diagnostic = for (result.json_diagnostics.items) |candidate| {
        if (std.mem.eql(u8, candidate.code, "ZTS629")) break candidate;
    } else return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("unpublished ambient global 'fetchSync'", diagnostic.message);
    try std.testing.expectEqualStrings(
        "Import `fetch` from `zttp:fetch` and call `fetch(...)`; raw `fetchSync` is outside the model-minimal ambient namespace.",
        diagnostic.suggestion.?,
    );
}

test "runCheckOnlyFromSource: explicit Spec narrows active spec set" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "declared-only.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.declared_specs.items.len);
    try std.testing.expectEqualStrings("deterministic", contract.declared_specs.items[0]);
    try std.testing.expectEqual(@as(usize, 0), contract.spec_diagnostics.items.len);
}

test "runCheckOnlyFromSource: explicit unknown Spec suppresses defaults and emits ZTS502" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "made_up"> {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "unknown-only.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.declared_specs.items.len);
    try std.testing.expectEqualStrings("made_up", contract.declared_specs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.unknown_name, contract.spec_diagnostics.items[0].kind);
}

test "compileHandler honors a registered partner manifest" {
    const allocator = std.testing.allocator;

    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:partner",
        \\  "backend": "native-zig",
        \\  "requiredCapabilities": ["network"],
        \\  "exports": [
        \\    { "name": "writeRow", "effect": "write", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try zts.ModuleMetadata.parse(allocator, manifest_json);

    var registry = zts.ManifestRegistry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    const source =
        \\import { writeRow } from "zttp-ext:partner";
        \\function handler(req: Request): Response {
        \\  writeRow("k", "v");
        \\  return Response.text("ok");
        \\}
    ;

    var compiled = try compileHandler(allocator, source, "handler.ts", .{
        .emit_contract = true,
        .manifest_registry = &registry,
    });
    defer compiled.deinit(allocator);

    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expect(handler_contract.containsString(contract.modules.items, "zttp-ext:partner"));

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.idempotent);
}

test "contract policy validation checks zttp:sql queries against schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\import { sql } from "zttp:sql";
        \\
        \\sql("createUser", "INSERT INTO users (name) VALUES (:name)");
        \\sql("getUser", "SELECT id, name FROM users WHERE id = :id");
        \\
        \\export function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    const schema =
        \\CREATE TABLE users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL
        \\);
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "schema.sql", .data = schema });

    const allocator = std.testing.allocator;
    const entry_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(entry_path);
    const schema_path = try tmp.dir.realPathFileAlloc(std.testing.io, "schema.sql", allocator);
    defer allocator.free(schema_path);

    var contract = try buildTestContractForSource(allocator, source, entry_path, schema_path);
    defer contract.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), contract.sql.queries.items.len);
    try std.testing.expectEqualStrings("createUser", contract.sql.queries.items[0].name);
    try std.testing.expectEqualStrings("insert", contract.sql.queries.items[0].operation);
    try std.testing.expectEqual(@as(usize, 1), contract.sql.queries.items[0].tables.items.len);
    try std.testing.expectEqualStrings("users", contract.sql.queries.items[0].tables.items[0]);
    try std.testing.expectEqualStrings("getUser", contract.sql.queries.items[1].name);
    try std.testing.expectEqualStrings("select", contract.sql.queries.items[1].operation);
}

test "contract policy validation requires schema when zttp:sql is used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\import { sql } from "zttp:sql";
        \\
        \\sql("getUser", "SELECT id, name FROM users WHERE id = :id");
        \\
        \\export function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = source });

    const allocator = std.testing.allocator;
    const entry_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(entry_path);

    try std.testing.expectError(
        error.MissingSqlSchema,
        buildTestContractForSource(allocator, source, entry_path, null),
    );
}

test "compileHandler rejects invalid virtual-module imports" {
    const allocator = std.testing.allocator;
    const source =
        \\import { definitelyMissing } from "zttp:sql";
        \\
        \\function handler(req) {
        \\  return Response.json({ ok: definitelyMissing });
        \\}
    ;

    try std.testing.expectError(
        error.InvalidImportSpecifier,
        compileHandler(allocator, source, "handler.ts", .{}),
    );
}

test "compileHandler rejects an import of a module that does not exist" {
    // The export check only ever ran for modules the table knows, so an import
    // of a module that is not there at all reported clean. `zttp:websocket`
    // was removed in this beta and every handler still importing it passed.
    const allocator = std.testing.allocator;
    const source =
        \\import { send } from "zttp:websocket";
        \\
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;

    try std.testing.expectError(
        error.UnknownVirtualModule,
        compileHandler(allocator, source, "handler.ts", .{}),
    );
}

test "runCheckOnly returns structured diagnostics for invalid virtual imports" {
    const cases = [_]struct {
        source: []const u8,
        code: []const u8,
        message: []const u8,
    }{
        .{
            .source =
            \\import { send } from "zttp:websocket";
            \\function handler(req: Request): Response { return Response.json({ ok: true }); }
            ,
            .code = "ZTS206",
            .message = "unknown virtual module 'zttp:websocket'",
        },
        .{
            .source =
            \\import { requireJWT } from "zttp:auth";
            \\function handler(req: Request): Response { return Response.json({ ok: true }); }
            ,
            .code = "ZTS207",
            .message = "module 'zttp:auth' does not export 'requireJWT'",
        },
    };

    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings(case.code, result.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings(case.message, result.json_diagnostics.items[0].message);
    }
}

test "compileHandler emits result_unsafe counterexample when jwtVerify result is unchecked" {
    const allocator = std.testing.allocator;
    // Handler accesses .value without checking .ok - triggers result_unsafe verification error
    const source =
        \\import { parseBearer } from "zttp:auth";
        \\import { jwtVerify } from "zttp:auth";
        \\
        \\function handler(req: Request): Response {
        \\  const token = parseBearer(req.headers.get("authorization") ?? "");
        \\  if (token === undefined) return Response.json({ error: "no token" }, { status: 401 });
        \\  const result = jwtVerify(token, "secret");
        \\  return Response.json({ user: result.value });
        \\}
    ;

    var compiled = try compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
    });
    defer compiled.deinit(allocator);

    try std.testing.expect(compiled.verify_failed);
    // violations_jsonl must be populated with a result-unsafe counterexample
    const vj = compiled.violations_jsonl orelse return error.MissingViolationsJsonl;
    try std.testing.expect(std.mem.indexOf(u8, vj, "result-unsafe") != null);
    // The counterexample io stub must include a {ok:false} failure case for jwtVerify
    try std.testing.expect(std.mem.indexOf(u8, vj, "jwtVerify") != null);
    try std.testing.expect(std.mem.indexOf(u8, vj, "\"ok\":false") != null);
}

test "compileHandler projects verifier properties only when verification runs" {
    const allocator = std.testing.allocator;
    // Handler that properly checks jwtVerify result and env optional before use.
    // Uses Response.text to avoid object-literal AOT serialization (pre-existing
    // leak in serializeObjectLiteral is unrelated to this test).
    const source =
        \\import { parseBearer } from "zttp:auth";
        \\import { jwtVerify } from "zttp:auth";
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Response {
        \\  const token = parseBearer(req.headers.get("authorization") ?? "");
        \\  if (token === undefined) return Response.text("no token", { status: 401 });
        \\  const result = jwtVerify(token, "secret");
        \\  if (!result.ok) return Response.text(result.error, { status: 401 });
        \\  const name = env("NAME") ?? "world";
        \\  return Response.text(name);
        \\}
    ;

    var without_verification = try compileHandler(allocator, source, "handler.ts", .{
        .emit_contract = true,
    });
    defer without_verification.deinit(allocator);

    try std.testing.expect(!without_verification.verify_failed);
    const unverified_contract = without_verification.contract orelse return error.MissingContract;
    const unverified_props = unverified_contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!unverified_props.result_safe);
    try std.testing.expect(!unverified_props.optional_safe);

    var with_verification = try compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
    });
    defer with_verification.deinit(allocator);

    try std.testing.expect(!with_verification.verify_failed);
    const contract = with_verification.contract orelse return error.MissingContract;
    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(props.result_safe);
    try std.testing.expect(props.optional_safe);
}

test "contract-only extraction without TypeMap preserves verifier properties" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  if (5) return Response.text(jwtVerify("token", "secret").value);
        \\  return Response.text(process.env.NAME);
        \\}
    ;

    var contract = try buildTestContractForSource(
        allocator,
        source,
        "shared-analysis-contract-only.js",
        null,
    );
    defer contract.deinit(allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.result_safe);
    try std.testing.expect(!props.optional_safe);
}

test "writeBytecodeArray emits zig-fmt stable rows" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);

    const bytes = [_]u8{ 0x01, 0xab, 0xff };
    try writeBytecodeArray(&aw.writer, &bytes);
    output = aw.toArrayList();

    try std.testing.expectEqualStrings(
        "    0x01, 0xab, 0xff,\n",
        output.items,
    );
}

test "writeCapabilityPolicy emits zig-fmt stable empty allowlists" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);

    const policy = HandlerPolicy{
        .env = .{},
        .egress = .{},
        .egress_scopes = .{ .bits = 5 },
        .cache = .{},
        .sql = .{},
    };
    try writeCapabilityPolicy(&aw.writer, policy, null);
    output = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, output.items, ".values = &[_][]const u8{},") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".values = &[_][]const u8{\n        },") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".egress_scopes = .{ .bits = 5 },") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "runtime_policy_index_required = false;") != null);

    output.clearRetainingCapacity();
    aw = .fromArrayList(allocator, &output);
    var guarded = handler_contract.emptyContract("borrowed-test-path.ts");
    guarded.env.dynamic = true;
    try writeCapabilityPolicy(&aw.writer, null, &guarded);
    output = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, output.items, "runtime_policy_index_required = true;") != null);
}

test {
    _ = @import("precompile_args.zig");
    _ = @import("pipeline_mutation_tests.zig");
}

// ---------------------------------------------------------------------------
// Serialized-bytecode goldens
//
// The contract goldens pin what the analyzer SAYS about a handler. Nothing
// pinned what the compiler EMITS for one, which is the artifact the product
// signs and ships. These do.
//
// Sources are inline, not the fixtures under tests/fixtures/contract/. Two
// approaches were tried and rejected first: `@embedFile` with a relative path is
// rejected by Zig ("embed of file outside package path"), and injecting the
// fixtures as anonymous build imports broke every OTHER test root that includes
// this file because those roots have no such import. `zig build
// test-precompile` was green while `zig build test` was not.
//
// Inline sources cover plain control flow, arithmetic, and virtual-module
// imports.
//
// To regenerate after a DELIBERATE codegen change: run the test, read the actual
// hash it prints, and paste it in. There is no update script on purpose - a hash
// change should cost a moment's thought about why the bytes moved. Verified
// capable of failing: renumbering `push_const` in bytecode.zig drifts both.
// ---------------------------------------------------------------------------

const bytecode_golden_cases = [_]struct {
    name: []const u8,
    source: []const u8,
    /// sha256 of the serialized bytecode, lowercase hex.
    sha256: []const u8,
}{
    .{
        .name = "plain",
        .source =
        \\function handler(req: Request): Response {
        \\    const n = 1 + 2;
        \\    if (req.path === "/health") {
        \\        return Response.json({ ok: true, n: n });
        \\    }
        \\    return Response.text("not found", { status: 404 });
        \\}
        ,
        .sha256 = "0c6cba6b15e14cdf3d02be205df66039453c474e1eba741285d01faec4aa899a",
    },
    .{
        .name = "virtual modules",
        .source =
        \\import { env } from "zttp:env";
        \\import { sha256 } from "zttp:crypto";
        \\import { cacheGet, cacheSet } from "zttp:cache";
        \\
        \\function handler(req: Request): Response {
        \\    const token = env("API_TOKEN") ?? "";
        \\    const cached = cacheGet("sessions", token);
        \\    if (cached !== undefined) {
        \\        return Response.json({ hit: true, value: cached });
        \\    }
        \\    const digest = sha256(token);
        \\    cacheSet("sessions", token, digest, 60);
        \\    return Response.json({ hit: false, digest: digest });
        \\}
        ,
        .sha256 = "b47edaefb4ef8f663a35872a28c823bc7e5982845cacb9381314db971f4030e2",
    },
};

test "serialized bytecode matches the committed goldens" {
    const allocator = std.testing.allocator;
    var drifted: usize = 0;

    for (bytecode_golden_cases) |case| {
        var compiled = compileHandler(allocator, case.source, "golden.ts", .{}) catch |err| {
            std.debug.print("\nbytecode golden: {s} failed to compile: {t}\n", .{ case.name, err });
            return err;
        };
        defer compiled.deinit(allocator);

        // A fixture that fails verification emits no bytecode, so an empty
        // golden would pass vacuously. Refuse that.
        try std.testing.expect(!compiled.verify_failed);
        try std.testing.expect(compiled.bytecode.len > 0);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(compiled.bytecode, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, case.sha256, &actual)) {
            // Report every drifting fixture before failing. A gate that names one
            // when both moved costs a full cycle per fixture.
            std.debug.print(
                "\nbytecode golden drift: {s}\n  expected {s}\n  actual   {s}\n  ({d} bytes)\n",
                .{ case.name, case.sha256, actual, compiled.bytecode.len },
            );
            drifted += 1;
        }
    }
    if (drifted > 0) return error.BytecodeGoldenDrift;
}

// The obligation past the sixteenth member of a generic intersection.
//
// `instantiateCompositeMembers` once copied members into a fixed `[16]TypeIndex`
// buffer and rebuilt the intersection from that prefix, so a seventeenth member
// was dropped and the value that should have failed it was accepted. The copy is
// allocator-backed now, and `type_env.zig` unit-tests that seventeen members
// survive the pool. These two cases assert the end-user verdict instead: what
// `zts check` answers about a value that violates only the last obligation.
//
// The fixture must keep its generic application. `instantiateCompositeMembers`
// returns `.unchanged` when no member changed, so an intersection of plain record
// literals never rebuilds from the copied prefix - measured: the same seventeen
// members written without `Box<string>` reject under the truncating implementation
// too, and would have stood here as a permanent false pass.
const wide_intersection_members =
    \\structural Box<T> = { boxed: T };
    \\structural Wide =
    \\  Box<string> &
    \\  { f01: string } & { f02: string } & { f03: string } & { f04: string } &
    \\  { f05: string } & { f06: string } & { f07: string } & { f08: string } &
    \\  { f09: string } & { f10: string } & { f11: string } & { f12: string } &
    \\  { f13: string } & { f14: string } & { f15: string } &
    \\  { last: string };
    \\
;

const wide_intersection_satisfied =
    \\function handler(req: Request): Response {
    \\  const v: Wide = { boxed: "b", f01: "v", f02: "v", f03: "v", f04: "v",
    \\    f05: "v", f06: "v", f07: "v", f08: "v", f09: "v", f10: "v", f11: "v",
    \\    f12: "v", f13: "v", f14: "v", f15: "v", last: "v" };
    \\  return Response.json(v);
    \\}
    \\
;

const wide_intersection_violated =
    \\function handler(req: Request): Response {
    \\  const v: Wide = { boxed: "b", f01: "v", f02: "v", f03: "v", f04: "v",
    \\    f05: "v", f06: "v", f07: "v", f08: "v", f09: "v", f10: "v", f11: "v",
    \\    f12: "v", f13: "v", f14: "v", f15: "v" };
    \\  return Response.json(v);
    \\}
    \\
;

test "generic intersection fixture carries the members it claims" {
    // The floor. Both assertions below are about the seventeenth member, and a
    // fixture that lost a member, or lost `Box<`, satisfies them over a shape
    // that cannot reproduce the defect at all.
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_members, "Box<string>") != null);
    try std.testing.expectEqual(@as(usize, 16), std.mem.count(u8, wide_intersection_members, ": string }"));
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_members, "{ last: string }") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_violated, "last:") == null);
    try std.testing.expect(std.mem.indexOf(u8, wide_intersection_satisfied, "last: \"v\"") != null);
}

test "zts check rejects a value that violates only the seventeenth intersection member" {
    const allocator = std.testing.allocator;
    const source = try std.mem.concat(allocator, u8, &.{ wide_intersection_members, wide_intersection_violated });
    defer allocator.free(source);

    var check = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer check.deinit(allocator);

    // The exact count, not "more than zero": a second type error would mean the
    // fixture stopped isolating the obligation it names.
    try std.testing.expectEqual(@as(u32, 1), check.type_errors);
    try std.testing.expectEqual(@as(u32, 0), check.parse_errors);
}

test "zts check accepts the same value once the seventeenth member is satisfied" {
    const allocator = std.testing.allocator;
    const source = try std.mem.concat(allocator, u8, &.{ wide_intersection_members, wide_intersection_satisfied });
    defer allocator.free(source);

    var check = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer check.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), check.type_errors);
    try std.testing.expectEqual(@as(u32, 0), check.parse_errors);
}

// An intersection member spelled as a name carries the same weight as one
// spelled inline.
//
// `resolveType` substitutes an alias name only when the whole annotation matches
// it, so a name written inside a compound expression stays a `t_ref`
// (`type_env.zig`, "TypeEnv intersection alias type AB = A & B"). An unresolved
// name reaches the blanket-true that D1 amendment A1 will delete, so the member
// was discharged instead of checked: this pair once measured 0 named against 1
// inline, the same value missing the same field.
//
// The intersection-target loop applies A1's rule at that one site now
// (`type_pool.zig`, "Intersection target"), so both spellings reject. The pair
// stays because the asymmetry is what a regression here looks like: a change
// that reopens the fail-open moves `named` back to 0 while leaving `inlined`
// green, and only the contrast catches that.
const named_intersection_members =
    \\structural A = { a: string };
    \\structural B = { b: string };
    \\structural AB = A & B;
    \\function handler(req: Request): Response {
    \\  const v: AB = { a: "x" };
    \\  return Response.json(v);
    \\}
    \\
;

const inline_intersection_members =
    \\structural AB = { a: string } & { b: string };
    \\function handler(req: Request): Response {
    \\  const v: AB = { a: "x" };
    \\  return Response.json(v);
    \\}
    \\
;

test "a named intersection member is checked, like the inline spelling" {
    const allocator = std.testing.allocator;

    var named = try runCheckOnlyFromSourceWithOptions(allocator, named_intersection_members, "handler.ts", .{
        .json_mode = true,
    });
    defer named.deinit(allocator);
    var inlined = try runCheckOnlyFromSourceWithOptions(allocator, inline_intersection_members, "handler.ts", .{
        .json_mode = true,
    });
    defer inlined.deinit(allocator);

    // Neither source may fail to parse, or both counts below are zero for a
    // reason that has nothing to do with assignability.
    try std.testing.expectEqual(@as(u32, 0), named.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), inlined.parse_errors);

    // The contrast is the claim: the same missing field, rejected either way.
    // Asserting both, rather than only the named case, is what makes a silent
    // return to the fail-open visible.
    try std.testing.expectEqual(@as(u32, 1), inlined.type_errors);
    try std.testing.expectEqual(@as(u32, 1), named.type_errors);
}

test "check keeps typed imported builtin methods deterministic" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { normalizeLabel } from "./label.ts";
        \\function handler(req: Request): Response {
        \\  const body = req.body ?? "";
        \\  return Response.json({ label: normalizeLabel(body) });
        \\}
        \\
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "label.ts", .data =
        \\export structural LabelText = string;
        \\export structural NormalizedLabel = string;
        \\export function normalizeLabel(text: LabelText): NormalizedLabel {
        \\  return text.trim().toLowerCase();
        \\}
        \\
    });
    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
    defer allocator.free(handler_path);

    var result = try runCheckOnlyWithOptions(allocator, handler_path, .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(properties.deterministic);
    try std.testing.expect(properties.idempotent);
    try std.testing.expect(properties.no_secret_leakage);
    try std.testing.expect(properties.no_credential_leakage);
}

/// A handler file with sibling modules in one temporary directory, for the
/// cross-file flow tests. `check` runs the analyzer the way `zttp check` does.
const SiblingFixture = struct {
    tmp: std.testing.TmpDir,
    handler_path: [:0]u8,

    fn init(handler_source: []const u8) !SiblingFixture {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = handler_source });
        const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
        return .{ .tmp = tmp, .handler_path = handler_path };
    }

    fn deinit(self: *SiblingFixture) void {
        std.testing.allocator.free(self.handler_path);
        self.tmp.cleanup();
    }

    fn add(self: *SiblingFixture, name: []const u8, source: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = source });
    }

    fn check(self: *SiblingFixture) !CheckResult {
        return runCheckOnlyWithOptions(std.testing.allocator, self.handler_path, .{ .json_mode = true });
    }
};

fn hasDiagnosticCode(result: *const CheckResult, code: []const u8) bool {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

/// The first diagnostic with `code`, or null.
fn diagnosticWithCode(result: *const CheckResult, code: []const u8) ?json_diag.JsonDiagnostic {
    for (result.json_diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
}

const sibling_cache_writer =
    \\import { cacheSet } from "zttp:cache";
    \\export function save(): undefined {
    \\  cacheSet("items", "key", "value");
    \\  return undefined;
    \\}
    \\
;

test "CHECK applies a sibling writer effect to handler properties" {
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\function handler(req: Request): Proof<Response, "read_only" | "retry_safe"> {
        \\  save();
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", sibling_cache_writer);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(!properties.idempotent);
    var refused_read_only = false;
    var refused_retry_safe = false;
    for (result.contract.?.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.kind != .not_discharged) continue;
        if (std.mem.eql(u8, diagnostic.spec_name, "read_only")) refused_read_only = true;
        if (std.mem.eql(u8, diagnostic.spec_name, "retry_safe")) refused_retry_safe = true;
    }
    try std.testing.expect(refused_read_only);
    try std.testing.expect(refused_retry_safe);
}

test "CHECK applies sibling effects through an alias and a holder" {
    const cases = [_]struct {
        imported_name: []const u8,
        call: []const u8,
        dependency: []const u8,
    }{
        .{
            .imported_name = "saveAlias",
            .call = "saveAlias()",
            .dependency =
            \\import { cacheSet } from "zttp:cache";
            \\function save(): undefined { cacheSet("items", "key", "value"); return undefined; }
            \\export const saveAlias = save;
            \\
            ,
        },
        .{
            .imported_name = "holder",
            .call = "holder.save()",
            .dependency =
            \\import { cacheSet } from "zttp:cache";
            \\function save(): undefined { cacheSet("items", "key", "value"); return undefined; }
            \\export const holder = { save };
            \\
            ,
        },
    };

    for (cases) |case| {
        const handler = try std.fmt.allocPrint(
            std.testing.allocator,
            "import {{ {s} }} from \"./dep.ts\";\nfunction handler(req: Request): Response {{ {s}; return Response.text(\"ok\"); }}\n",
            .{ case.imported_name, case.call },
        );
        defer std.testing.allocator.free(handler);
        var fixture = try SiblingFixture.init(handler);
        defer fixture.deinit();
        try fixture.add("dep.ts", case.dependency);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        const properties = result.contract.?.properties.?;
        try std.testing.expect(!properties.read_only);
        try std.testing.expect(!properties.retry_safe);
    }
}

test "CHECK applies a sibling writer effect through two imports" {
    var fixture = try SiblingFixture.init(
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response { relay(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { save } from "./dep.ts";
        \\export function relay(): undefined { return save(); }
        \\
    );
    try fixture.add("dep.ts", sibling_cache_writer);

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

test "CHECK reports incomplete effects for an imported callback invocation" {
    var fixture = try SiblingFixture.init(
        \\import { run } from "./dep.ts";
        \\function clean(): undefined { return undefined; }
        \\function handler(req: Request): Response { run(clean); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function run(callback) { callback(); return undefined; }
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(properties.has_egress);
    try std.testing.expect(!contract.effect_analysis_complete);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.proof_trace_json orelse return error.TestUnexpectedResult,
        "Effect analysis is incomplete",
    ) != null);
}

test "CHECK preserves sibling cache reads and egress facts" {
    const cases = [_]struct {
        name: []const u8,
        dependency: []const u8,
        stateless: bool,
        has_egress: bool,
    }{
        .{
            .name = "readIt",
            .dependency =
            \\import { cacheGet } from "zttp:cache";
            \\export function readIt(): string | undefined { return cacheGet("items", "key"); }
            \\
            ,
            .stateless = false,
            .has_egress = false,
        },
        .{
            .name = "readIt",
            .dependency =
            \\import { fetchSync } from "zttp:fetch";
            \\export function readIt(): string { return fetchSync("https://example.com"); }
            \\
            ,
            .stateless = false,
            .has_egress = true,
        },
    };

    for (cases) |case| {
        const handler = try std.fmt.allocPrint(
            std.testing.allocator,
            "import {{ {s} }} from \"./dep.ts\";\nfunction handler(req: Request): Response {{ return Response.text({s}() ?? \"\"); }}\n",
            .{ case.name, case.name },
        );
        defer std.testing.allocator.free(handler);
        var fixture = try SiblingFixture.init(handler);
        defer fixture.deinit();
        try fixture.add("dep.ts", case.dependency);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        const properties = result.contract.?.properties.?;
        try std.testing.expectEqual(case.stateless, properties.stateless);
        try std.testing.expectEqual(case.has_egress, properties.has_egress);
    }
}

test "CHECK keeps pure and data sibling controls clean" {
    var fixture = try SiblingFixture.init(
        \\import { pure, label } from "./dep.ts";
        \\function handler(req: Request): Response { return Response.text(pure(label)); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function pure(value: string): string { return value.toUpperCase(); }
        \\export const label = "clean";
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(properties.read_only);
    try std.testing.expect(properties.retry_safe);
    try std.testing.expect(properties.stateless);
    try std.testing.expect(!properties.has_egress);
}

test "CHECK does not classify a factory-produced callable as data" {
    var fixture = try SiblingFixture.init(
        \\import { save } from "./dep.ts";
        \\function handler(req: Request): Response { save(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { cacheSet } from "zttp:cache";
        \\function writer() { cacheSet("items", "key", "value"); return undefined; }
        \\function factory() { return writer; }
        \\export const save = factory();
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

test "CHECK blocks effects for missing unreadable and malformed sibling exports" {
    const cases = [_]?[]const u8{
        null,
        "export function other(): string { return \"ok\"; }\n",
        "export function work( {{{\n",
    };
    for (cases) |dependency| {
        var fixture = try SiblingFixture.init(
            \\import { work } from "./dep.ts";
            \\function handler(req: Request): Response { work(); return Response.text("ok"); }
            \\
        );
        defer fixture.deinit();
        if (dependency) |source| try fixture.add("dep.ts", source);

        var result = try fixture.check();
        defer result.deinit(std.testing.allocator);
        const properties = result.contract.?.properties.?;
        try std.testing.expect(!properties.read_only);
        try std.testing.expect(!properties.retry_safe);
    }
}

test "CHECK blocks effects at an import cycle" {
    var fixture = try SiblingFixture.init(
        \\import { first } from "./a.ts";
        \\function handler(req: Request): Response { first(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { second } from "./b.ts";
        \\export function first(): undefined { return second(); }
        \\
    );
    try fixture.add("b.ts",
        \\import { first } from "./a.ts";
        \\export function second(): undefined { return first(); }
        \\
    );

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

test "CHECK blocks effects past the sibling import depth limit" {
    var fixture = try SiblingFixture.init(
        \\import { f0 } from "./f0.ts";
        \\function handler(req: Request): Response { f0(); return Response.text("ok"); }
        \\
    );
    defer fixture.deinit();
    for (0..max_import_depth) |index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "f{d}.ts", .{index});
        defer std.testing.allocator.free(name);
        const source = if (index + 1 < max_import_depth)
            try std.fmt.allocPrint(
                std.testing.allocator,
                "import {{ f{d} }} from \"./f{d}.ts\";\nexport function f{d}(): undefined {{ return f{d}(); }}\n",
                .{ index + 1, index + 1, index, index + 1 },
            )
        else
            try std.fmt.allocPrint(
                std.testing.allocator,
                "export function f{d}(): undefined {{ return undefined; }}\n",
                .{index},
            );
        defer std.testing.allocator.free(source);
        try fixture.add(name, source);
    }

    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

const logs_param_helper =
    \\import { logInfo } from "zttp:log";
    \\export function logIt(x: string): number {
    \\  logInfo(x, { n: 1 });
    \\  return 1;
    \\}
    \\
;

test "an imported helper that logs its secret parameter refuses the call that passes one" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = logIt(s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    const diag = diagnosticWithCode(&result, "ZTS402") orelse return error.TestExpectedEqual;
    // The report names the importer's call, the same text a direct sink has,
    // and says where in the imported file the sink is.
    try std.testing.expectEqualStrings("secret data flows into console output", diag.message);
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.suggestion orelse "", "./dep.ts") != null);
}

test "an imported helper called with a clean literal keeps no_secret_leakage" {
    var fixture = try SiblingFixture.init(
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logIt("hello");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(!hasDiagnosticCode(&result, "ZTS402"));
}

test "an imported helper that logs its own secret refuses every call" {
    var fixture = try SiblingFixture.init(
        \\import { logOwn } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logOwn();
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\export function logOwn(): number {
        \\  logInfo(env("API_TOKEN") ?? "", { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(hasDiagnosticCode(&result, "ZTS402"));
}

test "an imported helper that returns its parameter in a response refuses a secret" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { wrap } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  return wrap(s);
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function wrap(x: string): Response {
        \\  return Response.json({ v: x });
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
}

test "a sink two imports deep reports at the handler's call" {
    const handler =
        \\import { env } from "zttp:env";
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = relay(s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    ;
    var fixture = try SiblingFixture.init(handler);
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { logIt } from "./dep.ts";
        \\export function relay(x: string): number {
        \\  return logIt(x);
        \\}
        \\
    );
    try fixture.add("dep.ts", logs_param_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
    try std.testing.expect(hasDiagnosticCode(&result, "ZTS402"));

    // Control: the same chain called with a literal leaks nothing.
    var clean = try SiblingFixture.init(
        \\import { relay } from "./a.ts";
        \\function handler(req: Request): Response {
        \\  const n = relay("hello");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer clean.deinit();
    try clean.add("a.ts",
        \\import { logIt } from "./dep.ts";
        \\export function relay(x: string): number {
        \\  return logIt(x);
        \\}
        \\
    );
    try clean.add("dep.ts", logs_param_helper);
    var clean_result = try clean.check();
    defer clean_result.deinit(std.testing.allocator);
    try std.testing.expect(clean_result.contract.?.properties.?.no_secret_leakage);
}

test "an imported helper whose file will not parse leaves the secret unproven" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { logIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = logIt(env("API_TOKEN") ?? "");
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function logIt(x: string): number {{{\n");
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
}

test "an imported helper with more parameters than the summary cap leaves the secret unproven" {
    var fixture = try SiblingFixture.init(
        \\import { env } from "zttp:env";
        \\import { many } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const s = env("API_TOKEN") ?? "";
        \\  const n = many("a", "b", "c", "d", "e", "f", "g", "h", s);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { logInfo } from "zttp:log";
        \\export function many(a: string, b: string, c: string, d: string, e: string, f: string, g: string, h: string, i: string): number {
        \\  logInfo(i, { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_secret_leakage);
}

test "an imported helper that sends its user input to a host demotes the importer's egress properties" {
    var fixture = try SiblingFixture.init(
        \\import { postIt } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = postIt(req.url);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function postIt(x: string): number {
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: x });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.injection_safe);
    try std.testing.expect(!properties.input_validated);
}

test "an imported helper reads the authorization header of the request it is passed" {
    var fixture = try SiblingFixture.init(
        \\import { audit } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const n = audit(req);
        \\  return Response.json({ ok: n });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { logInfo } from "zttp:log";
        \\export function audit(req: Request): number {
        \\  logInfo(req.headers["authorization"] ?? "", { n: 1 });
        \\  return 1;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.contract.?.properties.?.no_credential_leakage);
}

/// Exercise the public check pipeline. The census below counts properties only
/// after the direct and routed sources both falsify that exact property.
const RoutedPropertyProbe = struct {
    property: []const u8,
    proof_property: ?pcc.proof_system.Property = null,
    flow_property: ?zts.counterexample.PropertyTag = null,
    imports: []const u8 = "",
    globals: []const u8 = "",
    body: []const u8,
};

fn routedPropertySource(allocator: std.mem.Allocator, probe: RoutedPropertyProbe, routed: bool) ![]u8 {
    const annotation = if (std.mem.eql(u8, probe.property, "response_total")) "state_isolated" else probe.property;
    if (!routed) return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\nfunction handler(req: Request): Proof<Response, \"{s}\"> {{ {s} }}\n",
        .{ probe.imports, probe.globals, annotation, probe.body },
    );
    return std.fmt.allocPrint(
        allocator,
        "import {{ routerMatch }} from \"zttp:router\";\n{s}\n{s}\n" ++
            "function route(req: Request): Response {{ {s} }}\n" ++
            "const routes = {{ \"GET /probe\": route }};\n" ++
            "function handler(req: Request): Proof<Response, \"{s}\"> {{\n" ++
            "const found = routerMatch(routes, req);\n" ++
            "if (found === undefined) return Response.text(\"not found\", {{ status: 404 }});\n" ++
            "return found.handler(req);\n}}\n",
        .{ probe.imports, probe.globals, probe.body, annotation },
    );
}

fn routedProbeHolds(comptime property: []const u8, result: CheckResult) !bool {
    if (comptime std.mem.eql(u8, property, "response_total")) return result.exhaustive_returns;
    const contract = result.contract orelse {
        std.debug.print("router census has no contract for {s}\n", .{property});
        for (result.json_diagnostics.items) |diagnostic| {
            std.debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
        }
        return error.MissingProbeContract;
    };
    const properties = contract.properties orelse return error.MissingProbeProperties;
    return @field(properties, property);
}

test "router property census observes direct and routed violations for every obligation" {
    const allocator = std.testing.allocator;
    const probes = [_]RoutedPropertyProbe{
        .{ .property = "response_total", .proof_property = .response_total, .body = "if (req.method === \"GET\") return Response.text(\"ok\");" },
        .{ .property = "result_safe", .proof_property = .results_checked, .imports = "import { jwtVerify } from \"zttp:auth\";", .body = "const result = jwtVerify(req.url, \"secret\"); return Response.json({ claims: result.value });" },
        .{ .property = "state_isolated", .proof_property = .state_isolated, .globals = "let counter: number = 0;", .body = "counter = counter + 1; return Response.json({ counter: counter });" },
        .{ .property = "deterministic", .proof_property = .deterministic, .body = "return Response.json({ now: Date.now() });" },
        .{ .property = "read_only", .proof_property = .read_only, .imports = "import { cacheSet } from \"zttp:cache\";", .body = "cacheSet(\"probe\", \"key\", req.url, 60); return Response.text(\"ok\");" },
        .{ .property = "retry_safe", .proof_property = .retry_safe, .imports = "import { cacheSet } from \"zttp:cache\";", .body = "cacheSet(\"probe\", \"key\", req.url, 60); return Response.text(\"ok\");" },
        .{ .property = "no_secret_leakage", .proof_property = .no_secret_leakage, .flow_property = .no_secret_leakage, .imports = "import { env } from \"zttp:env\";", .body = "return Response.json({ key: env(\"SECRET_KEY\") });" },
        .{ .property = "no_credential_leakage", .flow_property = .no_credential_leakage, .body = "return Response.json({ credential: req.headers.get(\"authorization\") });" },
        .{ .property = "input_validated", .flow_property = .input_validated, .imports = "import { fetch } from \"zttp:fetch\";", .body = "fetch(\"https://api.example.com/collect\", { body: req.body ?? \"\" }); return Response.text(\"ok\");" },
        .{ .property = "pii_contained", .flow_property = .pii_contained, .imports = "import { fetch } from \"zttp:fetch\";", .body = "fetch(\"https://example.com\", { method: \"POST\", body: req.url }); return Response.text(\"ok\");" },
        .{ .property = "injection_safe", .flow_property = .injection_safe, .body = "return Response.html(req.url);" },
        .{ .property = "fault_covered", .imports = "import { jwtVerify } from \"zttp:auth\";", .body = "const result = jwtVerify(req.url, \"secret\"); if (!result.ok) return Response.text(\"accepted failure\", { status: 200 }); return Response.text(\"ok\");" },
        .{ .property = "optional_safe", .imports = "import { env } from \"zttp:env\";", .body = "const value = env(\"HOME\"); return Response.json({ length: value.length });" },
    };
    var proof_observed = std.enums.EnumSet(pcc.proof_system.Property).initEmpty();
    var flow_observed = std.enums.EnumSet(zts.counterexample.PropertyTag).initEmpty();
    inline for (probes) |probe| {
        for ([_]bool{ false, true }) |routed| {
            const source = try routedPropertySource(allocator, probe, routed);
            defer allocator.free(source);
            var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-census.ts", .{ .json_mode = true });
            defer result.deinit(allocator);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            if (try routedProbeHolds(probe.property, result)) {
                std.debug.print("router census still proves {s} (routed={})\n", .{ probe.property, routed });
                return error.RoutedPropertyNotRejected;
            }
        }
        if (probe.proof_property) |property| proof_observed.insert(property);
        if (probe.flow_property) |property| flow_observed.insert(property);
    }

    // A capability ceiling is checked through the public policy result. Its
    // module scan covers the whole IR, including route functions.
    const capability_probe = RoutedPropertyProbe{
        .property = "state_isolated",
        .imports = "import { env } from \"zttp:env\";",
        .body = "env(\"FORBIDDEN\"); return Response.text(\"ok\");",
    };
    for ([_]bool{ false, true }) |routed| {
        const source = try routedPropertySource(allocator, capability_probe, routed);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-capability-census.ts", .{
            .json_mode = true,
            .policy_source = "{\"env\":{\"allow\":[\"PUBLIC_KEY\"]}}",
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.policy_errors);
        var forbidden_env = false;
        for (result.json_diagnostics.items) |diagnostic| {
            if (std.mem.eql(u8, diagnostic.code, "POL001")) forbidden_env = true;
        }
        try std.testing.expect(forbidden_env);
    }
    proof_observed.insert(.capability_bounded);
    inline for (std.meta.fields(pcc.proof_system.Property)) |field| {
        try std.testing.expect(proof_observed.contains(@enumFromInt(field.value)));
    }
    inline for (std.meta.fields(zts.counterexample.PropertyTag)) |field| {
        try std.testing.expect(flow_observed.contains(@enumFromInt(field.value)));
    }
}

test "router public checks prove clean routes and fail closed on unresolved dispatch" {
    const allocator = std.testing.allocator;
    const clean_probe = RoutedPropertyProbe{
        .property = "deterministic",
        .body = "return Response.text(\"ok\");",
    };
    const source = try routedPropertySource(allocator, clean_probe, true);
    defer allocator.free(source);
    var clean = try runCheckOnlyFromSourceWithOptions(allocator, source, "router-clean.ts", .{ .json_mode = true });
    defer clean.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), clean.totalErrors());
    try std.testing.expect(clean.exhaustive_returns);
    // Route-only analysis paths are not runnable handler behavior samples.
    try std.testing.expect(!clean.contract.?.behaviors_exhaustive);
    const direct_source = try routedPropertySource(allocator, clean_probe, false);
    defer allocator.free(direct_source);
    var direct = try runCheckOnlyFromSourceWithOptions(allocator, direct_source, "direct-clean.ts", .{ .json_mode = true });
    defer direct.deinit(allocator);
    try std.testing.expect(direct.contract.?.behaviors_exhaustive);
    const clean_properties = clean.contract.?.properties.?;
    const checked_fields = .{
        "result_safe",       "optional_safe",         "state_isolated",  "deterministic", "read_only",
        "retry_safe",        "stateless",             "idempotent",      "fault_covered", "cost_bounded",
        "no_secret_leakage", "no_credential_leakage", "input_validated", "pii_contained", "injection_safe",
    };
    inline for (checked_fields) |field| try std.testing.expect(@field(clean_properties, field));

    // An assignment makes the dispatch unstable even though both visible
    // function bodies are clean. No property may treat missing call facts as
    // evidence that the call is safe.
    const unresolved_source =
        \\import { routerMatch } from "zttp:router";
        \\function route(req: Request): Response { return Response.text("ok"); }
        \\const routes = { "GET /probe": route };
        \\routes["GET /probe"] = route;
        \\function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.text("not found", { status: 404 });
        \\  return found.handler(req);
        \\}
    ;
    var unresolved = try runCheckOnlyFromSourceWithOptions(allocator, unresolved_source, "router-unresolved.ts", .{ .json_mode = true });
    defer unresolved.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), unresolved.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), unresolved.type_errors);
    try std.testing.expect(!unresolved.exhaustive_returns);
    const unresolved_properties = unresolved.contract.?.properties.?;
    inline for (checked_fields) |field| {
        if (@field(unresolved_properties, field)) {
            std.debug.print("unresolved route still proves {s}\n", .{field});
            return error.UnresolvedRoutePropertyProven;
        }
    }
}

fn parseFailureText(allocator: std.mem.Allocator, source: []const u8, path: []const u8) ![]u8 {
    var prepared = try zts.PreparedSource.init(allocator, source, path, .{});
    defer prepared.deinit();
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    if (js_parser.parse()) |_| return error.TestExpectedParseFailure else |_| {}
    return renderParseErrors(allocator, prepared.sourceView(), js_parser.errors.getErrors());
}

test "parse failure text names the code, file, line, and underline" {
    // These are the paths that printed `file:line:col: message` alone:
    // `check`, `gen-tests`, and compile all render through printParseErrors.
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "const a = 1;\nconst b = while;\n", "demo.ts");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "error[ZTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  --> demo.ts:2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2 | const b = while;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "^") != null);
}

test "parse failure text underlines the unsupported keyword and keeps its suggestion" {
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "let n = 0;\nwhile (n < 3) { n = n + 1; }\n", "loop.ts");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "error[ZTS001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  --> loop.ts:2:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  2 | while (n < 3) { n = n + 1; }\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "   | ^^^^^\n") != null);
}

test "parse failure text counts characters on a multi-byte line" {
    const allocator = std.testing.allocator;
    const text = try parseFailureText(allocator, "const s = \"é✓\"; while (s) {}\n", "wide.ts");
    defer allocator.free(text);
    // Sixteen characters precede `while`, though the line holds twenty bytes
    // before it.
    try std.testing.expect(std.mem.indexOf(u8, text, "   | " ++ " " ** 16 ++ "^^^^^\n") != null);
}

// ---------------------------------------------------------------------------
// Fault coverage reads the files the handler imports (R4 unit F2)
// ---------------------------------------------------------------------------

/// A handler whose one `fetch` is checked, and which calls `enrich` from a
/// sibling file. Whether `fault_covered` holds depends on that sibling.
const fault_sibling_handler =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./dep.ts";
    \\function handler(req: Request): Response {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, b: enrich() });
    \\}
    \\
;

const fault_unchecked_helper =
    \\import { fetch } from "zttp:fetch";
    \\export function enrich(): string {
    \\  const res = fetch("https://api.example.com/b");
    \\  return res.body;
    \\}
    \\
;

fn faultCovered(result: *const CheckResult) !bool {
    return (result.contract orelse return error.TestExpectedEqual).properties.?.fault_covered;
}

fn faultUnseenCalls(result: *const CheckResult) !u32 {
    return (result.contract orelse return error.TestExpectedEqual).fault_coverage.?.unseen_calls;
}

/// The text that names the first unseen call, from the handler's provenance.
fn faultCauseSnippet(result: *const CheckResult) ![]const u8 {
    const contract = result.contract orelse return error.TestExpectedEqual;
    const cause = contract.property_provenance.fault_covered orelse return error.TestExpectedEqual;
    return cause.snippet;
}

test "a sibling helper with an unchecked fetch blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", fault_unchecked_helper);
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 1), try faultUnseenCalls(&result));
    // The cause sits on the handler's import line and names the sibling.
    const cause = result.contract.?.property_provenance.fault_covered.?;
    try std.testing.expectEqual(@as(u32, 2), cause.line);
    try std.testing.expectEqualStrings("fetch in ./dep.ts", cause.snippet);
    // The proof trace prints the same text.
    try std.testing.expect(std.mem.indexOf(u8, result.proof_trace_json orelse "", "The first is `fetch in ./dep.ts`.") != null);
}

test "a sibling helper with only pure code keeps fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function enrich(): string {
        \\  return "pure".toUpperCase();
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 0), try faultUnseenCalls(&result));
    try std.testing.expect(result.contract.?.property_provenance.fault_covered == null);
}

test "a failable call two files deep blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { inner } from "./deeper.ts";
        \\export function enrich(): string {
        \\  return inner();
        \\}
        \\
    );
    try fixture.add("deeper.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function inner(): string {
        \\  const res = fetch("https://api.example.com/c");
        \\  return res.body;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("fetch in ./deeper.ts", try faultCauseSnippet(&result));
}

test "a sibling that exports a failable builtin as a value blocks fault_covered" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { enrich } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body, b: enrich });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export const enrich = fetch;
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("fetch in ./dep.ts", try faultCauseSnippet(&result));
}

test "a sibling that does not exist blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 1), try faultUnseenCalls(&result));
    try std.testing.expectEqualStrings("./dep.ts (unreadable)", try faultCauseSnippet(&result));
}

test "a sibling that does not parse blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function enrich( {{{\n");
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("./dep.ts (unreadable)", try faultCauseSnippet(&result));
}

test "a bare specifier import blocks fault_covered" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { identity } from "lodash";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body });
        \\}
        \\
    );
    defer fixture.deinit();
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("lodash (not a relative path)", try faultCauseSnippet(&result));
}

test "an import cycle through the handler ends without listing the handler's own sites" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    // The helper imports the handler back. The handler's own fetch is checked
    // and the scan must not list it again.
    try fixture.add("dep.ts",
        \\import { handler } from "./handler.ts";
        \\export function enrich(): string {
        \\  return "x";
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), try faultUnseenCalls(&result));
    try std.testing.expect(try faultCovered(&result));
}

test "an import cycle between siblings still finds a failable call inside it" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { other } from "./other.ts";
        \\export function enrich(): string {
        \\  return other();
        \\}
        \\
    );
    try fixture.add("other.ts",
        \\import { enrich } from "./dep.ts";
        \\import { fetch } from "zttp:fetch";
        \\export function other(): string {
        \\  const res = fetch("https://api.example.com/d");
        \\  return res.body;
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqualStrings("fetch in ./other.ts", try faultCauseSnippet(&result));
}

test "two names imported from one failing sibling count once per record" {
    var fixture = try SiblingFixture.init(
        \\import { fetch } from "zttp:fetch";
        \\import { enrich, extra } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ error: "upstream" }, { status: 502 });
        \\  }
        \\  return Response.json({ a: res.body, b: enrich(), c: extra() });
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\import { fetch } from "zttp:fetch";
        \\export function enrich(): string {
        \\  const res = fetch("https://api.example.com/b");
        \\  return res.body;
        \\}
        \\export function extra(): string {
        \\  return "x";
        \\}
        \\
    );
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    // One unseen call for each import record, not for each call site.
    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expectEqual(@as(u32, 2), try faultUnseenCalls(&result));
}

test "a chain of imports past the depth limit blocks fault_covered" {
    var fixture = try SiblingFixture.init(fault_sibling_handler);
    defer fixture.deinit();
    // dep.ts -> f1.ts -> ... -> f9.ts, nine files below the handler.
    try fixture.add("dep.ts",
        \\import { f1 } from "./f1.ts";
        \\export function enrich(): string { return f1(); }
        \\
    );
    var index: usize = 1;
    while (index <= 9) : (index += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.ts", .{index});
        var body_buf: [128]u8 = undefined;
        const body = if (index < 9)
            try std.fmt.bufPrint(&body_buf, "import {{ f{d} }} from \"./f{d}.ts\";\nexport function f{d}(): string {{ return f{d}(); }}\n", .{ index + 1, index + 1, index, index + 1 })
        else
            try std.fmt.bufPrint(&body_buf, "export function f9(): string {{ return \"end\"; }}\n", .{});
        try fixture.add(name, body);
    }
    var result = try fixture.check();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!try faultCovered(&result));
    try std.testing.expect(std.mem.endsWith(u8, try faultCauseSnippet(&result), "(import chain too deep)"));
}

test "collectImportedFailableCalls answers every non-builtin record" {
    const handler_source =
        \\import { fetch } from "zttp:fetch";
        \\import { enrich } from "./dep.ts";
        \\import { identity } from "lodash";
        \\function handler(req) {
        \\  return Response.json({ a: identity(enrich()) });
        \\}
        \\
    ;
    var fixture = try SiblingFixture.init(handler_source);
    defer fixture.deinit();
    try fixture.add("dep.ts", "export function enrich(): string { return \"x\"; }\n");

    const allocator = std.testing.allocator;
    var parser = try zts.parser.JsParser.init(allocator, handler_source);
    defer parser.deinit();
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var facts = try zts.pipeline.buildModuleFacts(allocator, zts.pipeline.ParsedModule.fromExisting(view, root, &atoms), null);
    defer facts.deinit();

    var scan = (try collectImportedFailableCalls(allocator, &facts, fixture.handler_path, null)) orelse return error.TestExpectedEqual;
    defer scan.deinit(allocator);

    // `fetch` is a builtin and has no entry; the other two records do.
    try std.testing.expectEqual(@as(usize, 2), scan.entries.items.len);
    var clean: usize = 0;
    var blocked: usize = 0;
    for (scan.entries.items) |entry| switch (entry.scan) {
        .clean => clean += 1,
        .blocked => |b| {
            blocked += 1;
            try std.testing.expectEqual(zts.PathGenerator.BlockReason.not_relative, b.reason);
        },
        .failable => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), clean);
    try std.testing.expectEqual(@as(usize, 1), blocked);
}

// ---------------------------------------------------------------------------
// One fault coverage record across check, compile, and text output
// ---------------------------------------------------------------------------

/// A failable call whose result is read but never tested: no path records it,
/// so the walk lists it as unseen and `fault_covered` is refused.
const unseen_call_handler =
    \\import { jwtVerify } from "zttp:auth";
    \\function handler(req: Request): Response {
    \\  return Response.text(jwtVerify("t", "s").error);
    \\}
;

/// A checked failable call inside a loop. The walk takes the loop body once,
/// so the path set is a summary and the analysis is not complete.
const looped_call_handler =
    \\import { jwtVerify } from "zttp:auth";
    \\function handler(req: Request): Response {
    \\  for (const i of range(2)) {
    \\    const auth = jwtVerify("token", "secret");
    \\    if (!auth.ok) {
    \\      return Response.text("unauthorized", { status: 401 });
    \\    }
    \\  }
    \\  return Response.text("ok");
    \\}
;

test "an incomplete fault analysis writes isCovered false" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, looped_call_handler, "looped.ts", .{ .json_mode = true });
    defer result.deinit(allocator);

    const contract = &(result.contract orelse return error.TestUnexpectedResult);
    // The floor: the record must exist and count the call, or the assertions
    // below would hold over a handler the analysis never looked at.
    const fc = contract.fault_coverage orelse return error.TestUnexpectedResult;
    try std.testing.expect(fc.total_failable > 0);
    try std.testing.expect(!contract.properties.?.fault_covered);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeContractJson(contract, &out.writer);
    const fault_start = std.mem.indexOf(u8, out.written(), "\"faultCoverage\"") orelse return error.TestUnexpectedResult;
    const fault_json = out.written()[fault_start..];
    try std.testing.expect(std.mem.indexOf(u8, fault_json, "\"isCovered\": false") != null);

    // Not clean: the analysis is incomplete or it carries warnings.
    try std.testing.expect(!(fc.isCovered() and fc.warnings == 0));
}

test "a decoded and re-encoded check contract keeps its fault coverage bytes" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, looped_call_handler, "looped.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    const contract = &(result.contract orelse return error.TestUnexpectedResult);

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try writeContractJson(contract, &first.writer);

    var decoded = try zts.handler_contract.parseFromJson(allocator, first.written());
    defer decoded.deinit(allocator);
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try writeContractJson(&decoded, &second.writer);

    const start_first = std.mem.indexOf(u8, first.written(), "\"faultCoverage\"") orelse return error.TestUnexpectedResult;
    const start_second = std.mem.indexOf(u8, second.written(), "\"faultCoverage\"") orelse return error.TestUnexpectedResult;
    const end_first = std.mem.indexOfPos(u8, first.written(), start_first, "  },") orelse return error.TestUnexpectedResult;
    const end_second = std.mem.indexOfPos(u8, second.written(), start_second, "  },") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(first.written()[start_first..end_first], second.written()[start_second..end_second]);
}

test "compileHandler stamps the fault coverage record, the property, and the cause for an unseen call" {
    const allocator = std.testing.allocator;
    var compiled = try compileHandler(allocator, unseen_call_handler, "unseen.ts", .{ .emit_contract = true });
    defer compiled.deinit(allocator);

    const contract = &(compiled.contract orelse return error.TestUnexpectedResult);
    const fc = contract.fault_coverage orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), fc.unseen_calls);
    try std.testing.expect(!fc.isCovered());
    try std.testing.expect(!contract.properties.?.fault_covered);
    const cause = contract.property_provenance.fault_covered orelse return error.TestUnexpectedResult;
    try std.testing.expect(cause.snippet.len > 0);
}

test "compileHandler and the check path agree on the fault coverage record" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: handler_contract.FaultCoverageInfo,
    }{
        .{
            .source = unseen_call_handler,
            .expected = .{
                .total_failable = 0,
                .covered = 0,
                .warnings = 0,
                .unseen_calls = 1,
                .upstream_fallback_sites = 0,
                .analysis_complete = false,
            },
        },
        .{
            .source = looped_call_handler,
            .expected = .{
                .total_failable = 1,
                .covered = 1,
                .warnings = 0,
                .unseen_calls = 0,
                .upstream_fallback_sites = 0,
                .analysis_complete = false,
            },
        },
    };
    for (cases) |case| {
        const source = case.source;
        var compiled = try compileHandler(allocator, source, "agree.ts", .{ .emit_contract = true });
        defer compiled.deinit(allocator);
        var checked = try runCheckOnlyFromSourceWithOptions(allocator, source, "agree.ts", .{ .json_mode = true });
        defer checked.deinit(allocator);

        const compiled_contract = &(compiled.contract orelse return error.TestUnexpectedResult);
        const checked_contract = &(checked.contract orelse return error.TestUnexpectedResult);
        const compiled_fc = compiled_contract.fault_coverage orelse return error.TestUnexpectedResult;
        const checked_fc = checked_contract.fault_coverage orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.expected, checked_fc);
        try std.testing.expectEqual(case.expected, compiled_fc);
        try std.testing.expect(!checked_contract.properties.?.fault_covered);
        try std.testing.expect(!compiled_contract.properties.?.fault_covered);
        try std.testing.expectEqual(
            checked_contract.property_provenance.fault_covered != null,
            compiled_contract.property_provenance.fault_covered != null,
        );
    }
}

test "formatProofCard: the card lists fault_covered and counts the call sites not on any path" {
    const allocator = std.testing.allocator;
    var result = try runCheckOnlyFromSourceWithOptions(allocator, unseen_call_handler, "unseen-text.ts", .{ .json_mode = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), result.fault_unseen);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    formatProofCard(&aw.writer, &result, "unseen-text.ts");
    buf = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "fault_covered") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "failable call sites covered, 1 not on any path") != null);
}

// ---------------------------------------------------------------------------
// Public CHECK reader trace
// ---------------------------------------------------------------------------

/// Records each resolved request path and serves the matching source revision.
const TracingImportReader = struct {
    sources: []const []const u8,
    paths: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TracingImportReader, allocator: std.mem.Allocator) void {
        for (self.paths.items) |path| allocator.free(path);
        self.paths.deinit(allocator);
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *TracingImportReader = @ptrCast(@alignCast(context));
        const read_index = self.paths.items.len;
        const path_copy = try allocator.dupe(u8, path);
        self.paths.append(allocator, path_copy) catch |err| {
            allocator.free(path_copy);
            return err;
        };
        if (read_index >= self.sources.len) return error.UnexpectedRead;
        return allocator.dupe(u8, self.sources[read_index]);
    }

    fn reader(self: *TracingImportReader) ImportReader {
        return .{ .context = self, .read = read };
    }
};

test "CHECK keeps the reader trace for two names imported from one file" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { first, second } from "./lib.ts";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage" | "canonical" | "cost_bounded"> {
        \\  return Response.json({ first: first(), second: second() });
        \\}
        \\
    ;
    // Only the final revision is fault-clean. Earlier fault reads must fail
    // the public unseen-call assertion. The first flow/effect revision writes,
    // so the exact reads also prove that effects use the flow load.
    const reader_sources = [_][]const u8{
        "import { cacheSet } from \"zttp:cache\";\n" ++
            "export function first(): string { cacheSet(\"n\", \"k\", \"v\"); return \"first\"; }\n" ++
            fault_unchecked_helper,
        "export function second(): string { return \"second\"; }\n" ++ fault_unchecked_helper,
        "export function first(): string { return \"first\"; }\n" ++
            "export function second(): string { return \"second\"; }\n",
    };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = tracing_reader.reader(),
    });
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/lib.ts",
        "/virtual/lib.ts",
        "/virtual/lib.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(u32, 1), result.paths_enumerated);
    try std.testing.expect(result.paths_exhaustive);
    try std.testing.expect(result.proof_trace_json != null);

    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(properties.no_secret_leakage);
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
    try std.testing.expect(!properties.idempotent);
    try std.testing.expect(!properties.stateless);
    try std.testing.expect(!properties.has_egress);
    try std.testing.expectEqual(false, properties.fault_covered);
    try std.testing.expectEqual(@as(usize, 1), contract.behaviors.items.len);
    try std.testing.expect(contract.behaviors_exhaustive);
    try std.testing.expectEqual(handler_contract.FaultCoverageInfo{
        .total_failable = 0,
        .covered = 0,
        .warnings = 0,
        .unseen_calls = 0,
        .upstream_fallback_sites = 0,
        .analysis_complete = true,
    }, contract.fault_coverage orelse return error.TestUnexpectedResult);
}

test "CHECK accepts a compile-caught imported type and retains measured direct effects" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { clean } from "./lib.ts";
        \\function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(clean("x"));
        \\}
        \\
    ;
    const dependency =
        "const marker: \"open\n" ++
        " = \"open\";\n" ++
        "export function clean(value: string): string { return value.toUpperCase(); }\n";
    const reader_sources = [_][]const u8{ dependency, dependency };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(
        allocator,
        handler_source,
        "/virtual/handler.ts",
        .{
            .json_mode = true,
            .import_reader = tracing_reader.reader(),
        },
    );
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/lib.ts",
        "/virtual/lib.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    const contract = result.contract orelse return error.TestUnexpectedResult;
    const properties = contract.properties orelse return error.TestUnexpectedResult;
    try std.testing.expect(contract.effect_analysis_complete);
    try std.testing.expect(!properties.pure);
    try std.testing.expect(properties.read_only);
}

test "CHECK stops nested effect reads after an imported type failure" {
    const allocator = std.testing.allocator;
    const handler_source =
        \\import { outer } from "./a.ts";
        \\function handler(req: Request): Response { return Response.text(outer()); }
        \\
    ;
    const failed_outer =
        \\import { inner } from "./b.ts";
        \\export function outer(): string {
        \\  const value: number = "wrong";
        \\  return inner();
        \\}
        \\
    ;
    const reader_sources = [_][]const u8{
        failed_outer,
        failed_outer,
        "export function inner(): string { return \"ok\"; }\n",
    };
    var tracing_reader: TracingImportReader = .{ .sources = &reader_sources };
    defer tracing_reader.deinit(allocator);

    var result = try runCheckOnlyFromSourceWithOptions(allocator, handler_source, "/virtual/handler.ts", .{
        .json_mode = true,
        .import_reader = tracing_reader.reader(),
    });
    defer result.deinit(allocator);

    const expected_paths = [_][]const u8{
        "/virtual/a.ts",
        "/virtual/a.ts",
        "/virtual/b.ts",
    };
    try std.testing.expectEqual(expected_paths.len, tracing_reader.paths.items.len);
    for (expected_paths, tracing_reader.paths.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    const properties = result.contract.?.properties.?;
    try std.testing.expect(!properties.read_only);
    try std.testing.expect(!properties.retry_safe);
}

// ---------------------------------------------------------------------------
// One loader for an imported file
// ---------------------------------------------------------------------------

/// Serves one in-memory file named `lib.ts` and refuses every other path.
const MemoryImportReader = struct {
    source: []const u8,
    reads: u32 = 0,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *MemoryImportReader = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (!std.mem.endsWith(u8, path, "lib.ts")) return error.FileNotFound;
        return allocator.dupe(u8, self.source);
    }

    fn reader(self: *MemoryImportReader) ImportReader {
        return .{ .context = self, .read = read };
    }
};

test "ImportedFile loads the file a reader serves and reduces it to module facts" {
    var served: MemoryImportReader = .{ .source =
        \\import { fetch } from "zttp:fetch";
        \\export function enrich(): string {
        \\  return "x";
        \\}
        \\
    };
    var file: ImportedFile = undefined;
    try file.load(std.testing.allocator, served.reader(), "/virtual/lib.ts");
    defer file.deinit();

    try std.testing.expectEqual(@as(u32, 1), served.reads);
    try std.testing.expectEqual(@as(usize, 1), file.module_facts.imports.items.len);
    try std.testing.expectEqualStrings("zttp:fetch", file.module_facts.imports.items[0].module_specifier);
}

test "ImportedFile is unreadable when the reader fails or the source does not parse" {
    var served: MemoryImportReader = .{ .source = "export function enrich(): string { return \"x\"; }\n" };
    var file: ImportedFile = undefined;
    // The reader refuses this path, and the loader leaves nothing to free.
    try std.testing.expectError(error.Unreadable, file.load(std.testing.allocator, served.reader(), "/virtual/other.ts"));
    try std.testing.expectEqual(@as(u32, 1), served.reads);

    var broken: MemoryImportReader = .{ .source = "const b = while;\n" };
    try std.testing.expectError(error.Unreadable, file.load(std.testing.allocator, broken.reader(), "/virtual/lib.ts"));
    try std.testing.expectEqual(@as(u32, 1), broken.reads);
}

test "ImportedFile without a reader reads the working tree" {
    var fixture = try SiblingFixture.init("function handler(req) { return Response.text(\"x\"); }\n");
    defer fixture.deinit();
    try fixture.add("lib.ts", "export function enrich(): string { return \"x\"; }\n");
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(fixture.handler_path).?, "lib.ts" });
    defer std.testing.allocator.free(lib_path);

    var file: ImportedFile = undefined;
    try file.load(std.testing.allocator, null, lib_path);
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 0), file.module_facts.imports.items.len);

    var missing: ImportedFile = undefined;
    try std.testing.expectError(error.Unreadable, missing.load(std.testing.allocator, null, "/nonexistent/zttp-u7/lib.ts"));
}

test "precompile refuses every retired module before replacing generated output" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { specifier: []const u8, symbol: []const u8 }{
        .{ .specifier = "zttp:durable", .symbol = "run" },
        .{ .specifier = "zttp:workflow", .symbol = "call" },
        .{ .specifier = "zttp:queue", .symbol = "send" },
        .{ .specifier = "zttp:scope", .symbol = "scope" },
        .{ .specifier = "zttp:io", .symbol = "parallel" },
        .{ .specifier = "zttp:service", .symbol = "serviceCall" },
        .{ .specifier = "zttp:ledger", .symbol = "balance" },
        .{ .specifier = "zttp:tool", .symbol = "toolInput" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(
            allocator,
            "import {{ {s} }} from \"{s}\";\n" ++
                "function handler(req: Request): Response {{ return Response.text(\"ok\"); }}\n",
            .{ case.symbol, case.specifier },
        );
        defer allocator.free(source);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = source });
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "embedded_handler.zig",
            .data = "sentinel",
        });
        const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
        defer allocator.free(handler_path);
        const output_path = try tmp.dir.realPathFileAlloc(
            std.testing.io,
            "embedded_handler.zig",
            allocator,
        );
        defer allocator.free(output_path);

        try std.testing.expectError(
            error.UnknownVirtualModule,
            runCompileWithArgs(allocator, &.{ "--contract", handler_path, output_path }),
        );
        const output = try zts.file_io.readFile(allocator, output_path, 64);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("sentinel", output);
    }
}

test "the analyzer refuses every retired module with ZTS206" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { module: []const u8, symbol: []const u8 }{
        .{ .module = "zttp:durable", .symbol = "run" },
        .{ .module = "zttp:workflow", .symbol = "call" },
        .{ .module = "zttp:queue", .symbol = "send" },
        .{ .module = "zttp:scope", .symbol = "scope" },
        .{ .module = "zttp:io", .symbol = "parallel" },
        .{ .module = "zttp:service", .symbol = "serviceCall" },
        .{ .module = "zttp:ledger", .symbol = "balance" },
        .{ .module = "zttp:tool", .symbol = "toolInput" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator, "import {{ {s} }} from \"{s}\";\n" ++
            "function handler(req: Request): Response {{ return Response.text(\"ready\"); }}\n", .{ case.symbol, case.module });
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        const diagnostic = result.json_diagnostics.items[0];
        try std.testing.expectEqualStrings("ZTS206", diagnostic.code);
        const message = try std.fmt.allocPrint(allocator, "unknown virtual module '{s}'", .{case.module});
        defer allocator.free(message);
        try std.testing.expectEqualStrings(message, diagnostic.message);
        try std.testing.expect(result.contract == null);
    }
}

test "ordinary calls and explicit HTML rendering remain accepted" {
    const source =
        \\function title(value: string): string { return value; }
        \\function handler(req: Request): Response {
        \\  return Response.html(renderToString(h("main", null, title("ready"))));
        \\}
    ;
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
        .skip_contract = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
}

const LegacyCompoundDiagnostic = struct {
    code: []const u8,
    message: []const u8,
    line: u32,
    column: u32,
    suggestion: ?[]const u8 = null,
};

fn legacyCompoundSource(allocator: std.mem.Allocator, annotation: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "function handler(req: Request): Response {{\n" ++
            "  const value: {s} = undefined;\n" ++
            "  return Response.text(\"ok\");\n" ++
            "}}\n",
        .{annotation},
    );
}

fn expectLegacyCompoundDiagnostic(
    actual: json_diag.JsonDiagnostic,
    expected: LegacyCompoundDiagnostic,
) !void {
    try std.testing.expectEqualStrings(expected.code, actual.code);
    try std.testing.expectEqualStrings("error", actual.severity);
    try std.testing.expectEqualStrings(expected.message, actual.message);
    try std.testing.expectEqualStrings("handler.ts", actual.file);
    try std.testing.expectEqual(expected.line, actual.line);
    try std.testing.expectEqual(expected.column, actual.column);
    if (expected.suggestion) |suggestion| {
        try std.testing.expectEqualStrings(suggestion, actual.suggestion.?);
    } else {
        try std.testing.expect(actual.suggestion == null);
    }
    try std.testing.expect(actual.repair_intent == null);
}

test "CHECK preserves repeated-name fallback through growth and source offsets" {
    const allocator = std.testing.allocator;
    const Layout = enum { plain, reordered, same_line };
    const cases = [_]struct {
        count: usize,
        layout: Layout,
        leading_spaces: usize,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{ .count = 6, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 8, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 8, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 8, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 6, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 244, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 238, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 9, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 9, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS202", .message = "wrong number of arguments: expected 2, got 1", .line = 9, .column = 8, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 303, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 297, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 14, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 14, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 14, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 12, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 598, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 592, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .plain, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 15, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .plain, .leading_spaces = 1, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 15, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .reordered, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 15, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 13, .layout = .same_line, .leading_spaces = 0, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 1, .column = 657, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 47, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 1, .column = 651, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
        .{ .count = 7, .layout = .reordered, .leading_spaces = 3, .diagnostics = &.{
            .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 2, .column = 9, .suggestion = null },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
            .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 9, .column = 3, .suggestion = "Import a published virtual-module capability or use an ambient name listed by meta.ambient_names." },
        } },
    };
    const number_function = "function useNumber(value: number): number {\n  inner(value);\n  function inner(item: number): number { return item; }\n  return value;\n}\n";
    const text_function = "function useText(value: string): string {\n  inner(value, \"\");\n  function inner(item: string, suffix: string): string { return item; }\n  return value;\n}\n";
    const handler = "export function handler(req: Request): Response {\n  return Response.json({ number: useNumber(1), text: useText(\"x\") });\n}\n";
    const expected_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |case| {
        try std.testing.expect(case.count >= 5);
        try std.testing.expect(case.count <= 13);
        try std.testing.expect(case.leading_spaces <= 3);
        var source_writer = std.Io.Writer.Allocating.init(allocator);
        defer source_writer.deinit();
        for (0..case.leading_spaces) |_| try source_writer.writer.writeByte(' ');
        try source_writer.writer.writeAll(if (case.layout == .reordered) text_function else number_function);
        for (0..case.count - 5) |index| {
            try source_writer.writer.print("function padding{d}(value: number): number {{ return value; }}\n", .{index});
        }
        try source_writer.writer.writeAll(if (case.layout == .reordered) number_function else text_function);
        try source_writer.writer.writeAll(handler);
        if (case.layout == .same_line) try source_writer.writer.writeByte('\n');
        const source = try allocator.dupe(u8, source_writer.written());
        defer allocator.free(source);
        if (case.layout == .same_line) {
            for (source[0 .. source.len - 1]) |*byte| {
                if (byte.* == '\n') byte.* = ' ';
            }
        }
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        const error_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(error_count - 1, result.strict_errors);
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(error_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 17), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves legacy compound type diagnostics and semantic prefixes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        annotation: []const u8,
        message: []const u8,
    }{
        .{ .annotation = "{ \"x\": number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x: }", .message = "type 'undefined' is not assignable to type '{ x: unknown }'" },
        .{ .annotation = "{ /*c*/ x: number }", .message = "type 'undefined' is not assignable to type '{  }'" },
        .{ .annotation = "{ x: number /*c*/ }", .message = "type 'undefined' is not assignable to type '{ x: number }'" },
        .{ .annotation = "{ x: number y: string }", .message = "type 'undefined' is not assignable to type '{ x: number; y: string }'" },
        .{ .annotation = "number |", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "{ x: number } &", .message = "type 'undefined' is not assignable to type '{ x: number }'" },
        .{ .annotation = "(x: number y: string) => number", .message = "type 'undefined' is not assignable to type '(x: number, y: string) => number'" },
        .{ .annotation = "(x: number) number", .message = "type 'undefined' is not assignable to type '(x: number) => void'" },
        .{ .annotation = "(x: number) =>", .message = "type 'undefined' is not assignable to type '(x: number) => void'" },
        .{ .annotation = "(number)", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "() => number", .message = "type 'undefined' is not assignable to type '() => number'" },
        .{ .annotation = "number [ ]", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "number /*c*/ []", .message = "type 'undefined' is not assignable to type 'number'" },
        .{ .annotation = "{ cb: (x?: number) => number }", .message = "type 'undefined' is not assignable to type '{ cb: (x: number) => number }'" },
        .{ .annotation = "{ any: number }", .message = "type 'undefined' is not assignable to type '{ any: number }'" },
        .{ .annotation = "string | 200", .message = "type 'undefined' is not assignable to type 'string | 200'" },
        .{ .annotation = "string | 1.5", .message = "type 'undefined' is not assignable to type 'string | 1'" },
        .{ .annotation = "string | 0x10", .message = "type 'undefined' is not assignable to type 'string | 0'" },
        .{ .annotation = "string | 1_000", .message = "type 'undefined' is not assignable to type 'string | 1'" },
        .{ .annotation = "true", .message = "type 'undefined' is not assignable to type 'true'" },
        .{ .annotation = "`\\${string}`", .message = "type 'undefined' is not assignable to type '`\\${string}`'" },
        .{ .annotation = "`x${}`", .message = "type 'undefined' is not assignable to type '`x${unknown}`'" },
        .{ .annotation = "\"GET\"", .message = "type 'undefined' is not assignable to type '\"GET\"'" },
        .{ .annotation = "(200)", .message = "type 'undefined' is not assignable to type '200'" },
        .{ .annotation = "(| number | string)", .message = "type 'undefined' is not assignable to type 'number | string'" },
        .{ .annotation = "readonly number[]", .message = "type 'undefined' is not assignable to type 'readonly number[]'" },
        .{ .annotation = "[string, number]", .message = "type 'undefined' is not assignable to type '[string, number]'" },
        .{ .annotation = "readonly [string, number]", .message = "type 'undefined' is not assignable to type '[string, number]'" },
        .{ .annotation = "`outer${`any`}`", .message = "type 'undefined' is not assignable to type '`outer${`any`}`'" },
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |case| {
        const source = try legacyCompoundSource(allocator, case.annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = case.message,
            .line = 2,
            .column = 3,
        });
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 31), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves legacy compound root admission parse diagnostics" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "| number | string",
        "& { x: number }",
        "1.5",
        "0x10",
        "1e3",
        "1_000",
        "32768",
        "/*c*/ number",
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse });
    const expected = [_]LegacyCompoundDiagnostic{
        .{
            .code = "ZTS002",
            .message = "const declarations must have an initializer",
            .line = 2,
            .column = 14,
        },
        .{
            .code = "ZTS047",
            .message = "statement is not terminated; this profile has no automatic semicolon insertion",
            .line = 2,
            .column = 9,
        },
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try legacyCompoundSource(allocator, annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
        try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, expected) |actual, diagnostic| {
            try expectLegacyCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}

test "CHECK preserves legacy compound unclosed syntax diagnostics" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "{ x: number",
        "`a${number",
        "(x: number => number",
        "number [",
    };
    const expected_stages = StageSet.initMany(&.{ .strip, .parse });
    const expected = [_]LegacyCompoundDiagnostic{
        .{
            .code = "ZTS002",
            .message = "const declarations must have an initializer",
            .line = 5,
            .column = 1,
        },
        .{
            .code = "ZTS047",
            .message = "statement is not terminated; this profile has no automatic semicolon insertion",
            .line = 2,
            .column = 9,
        },
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try legacyCompoundSource(allocator, annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
        try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, expected) |actual, diagnostic| {
            try expectLegacyCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}

test "CHECK preserves legacy preparation diagnostics and recovery boundaries" {
    const allocator = std.testing.allocator;
    const any_suggestion = "use specific types (string, number, object) or union types instead";
    const cases = [_]struct {
        annotation: []const u8,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .annotation = "(x?: number) => number",
            .diagnostics = &.{.{
                .code = "ZTS055",
                .message = "optional parameter shorthand is not part of this profile",
                .line = 2,
                .column = 18,
                .suggestion = "replace `name?: T` with `name: T | undefined`",
            }},
        },
        .{
            .annotation = "{ value: any }",
            .diagnostics = &.{.{
                .code = "ZTS041",
                .message = "'any' type is not supported",
                .line = 2,
                .column = 25,
                .suggestion = any_suggestion,
            }},
        },
        .{
            .annotation = "number many",
            .diagnostics = &.{.{
                .code = "ZTS041",
                .message = "'any' type is not supported",
                .line = 2,
                .column = 24,
                .suggestion = any_suggestion,
            }},
        },
        .{
            .annotation = "number Array<string>",
            .diagnostics = &.{.{
                .code = "ZTS058",
                .message = "`Array<T>` is not a type spelling in this profile",
                .line = 2,
                .column = 23,
                .suggestion = "write `T[]`",
            }},
        },
        .{
            .annotation = "number ReadonlyArray<string>",
            .diagnostics = &.{.{
                .code = "ZTS059",
                .message = "`ReadonlyArray<T>` is not a type spelling in this profile",
                .line = 2,
                .column = 23,
                .suggestion = "write `readonly T[]`",
            }},
        },
        .{
            .annotation = "any Array<string>",
            .diagnostics = &.{
                .{
                    .code = "ZTS041",
                    .message = "'any' type is not supported",
                    .line = 2,
                    .column = 16,
                    .suggestion = any_suggestion,
                },
                .{
                    .code = "ZTS058",
                    .message = "`Array<T>` is not a type spelling in this profile",
                    .line = 2,
                    .column = 20,
                    .suggestion = "write `T[]`",
                },
            },
        },
        .{
            .annotation = "(" ** 513 ++ "number" ++ ")" ** 513 ++ " any",
            .diagnostics = &.{.{
                .code = "ZTS044",
                .message = "type syntax nests too deeply",
                .line = 2,
                .column = 528,
                .suggestion = "simplify or split it (nesting limit is 512)",
            }},
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        const source = try legacyCompoundSource(allocator, case.annotation);
        defer allocator.free(source);
        var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
            .json_mode = true,
            .skip_contract = true,
        });
        defer result.deinit(allocator);

        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        const count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expect(count > 0);
        try std.testing.expectEqual(count, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, diagnostic| {
            try expectLegacyCompoundDiagnostic(actual, diagnostic);
        }
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);

    const CompatibilityStage = enum { strip, parse, contract_without_handler, contract };
    const proof_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
        "but it does not hold: cost_bounded, deterministic, fault_covered, idempotent, optional_safe, result_safe. " ++
        "Return a narrow Proof capsule with only the properties it holds, e.g. " ++
        "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | " ++
        "\"state_isolated\" | \"pure\" | \"stateless\" | \"no_secret_leakage\" | " ++
        "\"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
        "\"injection_safe\" | \"canonical\">`.";
    const compatibility_cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: CompatibilityStage,
        parse_errors: u32,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .name = "caught_then_comment",
            .source = "const value: \"open\n = \"open\";\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS008",
                .message = "unterminated string literal",
                .line = 1,
                .column = 19,
                .suggestion = "close the quote, or write the newline as \\n",
            }},
        },
        .{
            .name = "comment_only",
            .source = "/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "prior_hard_rows",
            .source = "const first: any = 1;\nconst second: void = undefined;\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS060",
                .message = "`void` is not a type spelling in this profile",
                .line = 2,
                .column = 15,
                .suggestion = "write `undefined`",
            }},
        },
        .{
            .name = "prior_parser_error",
            .source = "const broken = ;\n/* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "parameter_type_comment",
            .source = "function f(value: string /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "general_type_comment",
            .source = "const value: string /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "interface_body_comment",
            .source = "interface Shape { /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS049",
                .message = "`interface` is not a declaration form in this profile",
                .line = 1,
                .column = 1,
                .suggestion = "write `structural Name = { ... };`",
            }},
        },
        .{
            .name = "template_text_control",
            .source = "const value = `/* unfinished`;\n",
            .stage = .contract_without_handler,
            .parse_errors = 0,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .name = "template_interpolation_control",
            .source = "const text = `${/* unfinished}`;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS001",
                .message = "template interpolation is not supported",
                .line = 1,
                .column = 14,
                .suggestion = "build a string array with explicit `String(...)` conversions and call `.join(\"\")`",
            }},
        },
        .{
            .name = "generic_owner_nonmatch",
            .source = "const x = <void> + 1; /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS060",
                .message = "`void` is not a type spelling in this profile",
                .line = 1,
                .column = 12,
                .suggestion = "write `undefined`",
            }},
        },
        .{
            .name = "assertion_comment",
            .source = "const x = y as number /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS042",
                .message = "'as' type assertion is not supported",
                .line = 1,
                .column = 16,
                .suggestion = "use type-safe patterns instead",
            }},
        },
        .{
            .name = "annotation_void_comment",
            .source = "const x: void /* unfinished\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{},
        },
        .{
            .name = "assertion_later_void",
            .source = "const x = y as number | void;\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS042",
                .message = "'as' type assertion is not supported",
                .line = 1,
                .column = 16,
                .suggestion = "use type-safe patterns instead",
            }},
        },
        .{
            .name = "assertion_any_comment",
            .source = "const x = y as number | any /* unfinished\n",
            .stage = .strip,
            .parse_errors = 2,
            .diagnostics = &.{
                .{
                    .code = "ZTS042",
                    .message = "'as' type assertion is not supported",
                    .line = 1,
                    .column = 16,
                    .suggestion = "use type-safe patterns instead",
                },
                .{
                    .code = "ZTS041",
                    .message = "'any' type is not supported",
                    .line = 1,
                    .column = 25,
                    .suggestion = any_suggestion,
                },
            },
        },
        .{
            .name = "terminal_template_depth",
            .source = "function f(): `${" ++ "{" ** 512 ++ " return 1; }\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS044",
                .message = "type syntax nests too deeply",
                .line = 1,
                .column = 529,
                .suggestion = "simplify or split it (nesting limit is 512)",
            }},
        },
        .{
            .name = "template_tail_slash",
            .source = "const text = `${1}` / 2; import type { Spec } from \"zttp:types\"; / 3;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS001",
                .message = "template interpolation is not supported",
                .line = 1,
                .column = 14,
                .suggestion = "build a string array with explicit `String(...)` conversions and call `.join(\"\")`",
            }},
        },
        .{
            .name = "later_parser_error",
            .source = "const broken = ;\nconst later = ;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS002",
                .message = "expected expression",
                .line = 1,
                .column = 16,
            }},
        },
        .{
            .name = "recovery_first_template_head",
            .source = "const broken = ; `${function f(x: any) {}}`;\n",
            .stage = .parse,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS002",
                .message = "expected expression",
                .line = 1,
                .column = 16,
            }},
        },
        .{
            .name = "template_tail_slash_boundary",
            .source = "const text = `${1}` / 2;import type { Spec } from \"zttp:types\"; / 3;\n",
            .stage = .strip,
            .parse_errors = 1,
            .diagnostics = &.{.{
                .code = "ZTS053",
                .message = "`zttp:types` is not a module in this profile",
                .line = 1,
                .column = 25,
                .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names",
            }},
        },
    };
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    const handler_free_contract_stages = StageSet.initMany(&.{
        .strip,  .parse,    .imports, .boolean, .types,
        .strict, .contract, .trace,   .spec,    .canonical,
    });
    var compatibility_observed: usize = 0;
    for (compatibility_cases) |case| {
        errdefer std.debug.print("CHECK compatibility baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);

        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .contract_without_handler => handler_free_contract_stages,
            .contract => full_stages,
        };
        const has_contract = switch (case.stage) {
            .strip, .parse => false,
            .contract_without_handler, .contract => true,
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(case.parse_errors, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(has_contract, result.contract != null);
        const expected_errors: u32 = if (has_contract)
            @intCast(case.diagnostics.len)
        else
            case.parse_errors;
        try std.testing.expectEqual(expected_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        compatibility_observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 19), compatibility_cases.len);
    try std.testing.expectEqual(compatibility_cases.len, compatibility_observed);
}

test "CHECK keeps TypeScript and virtual JavaScript routing distinct" {
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    const typed_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const virtual_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .strict });
    const cases = [_]struct {
        path: []const u8,
        is_typescript: bool,
    }{
        .{ .path = "routing.ts", .is_typescript = true },
        .{ .path = "<routing>", .is_typescript = false },
    };

    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            source,
            case.path,
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(case.is_typescript, result.is_typescript);
        try std.testing.expectEqual(if (case.is_typescript) typed_stages else virtual_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.strict_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqualStrings("ZTS601", result.json_diagnostics.items[0].code);
        try std.testing.expect(!result.verify_ran);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK preserves source preparation allocation failure projection" {
    const source = "const value: string = \"ok\";\n";
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var result = try runCheckOnlyFromSourceWithOptions(
        failing.allocator(),
        source,
        "allocation.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(failing.allocator());

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK preserves validation allocation failure projection" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "import type ");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "`${");
    try source.appendSlice(std.testing.allocator, "value");
    for (0..513) |_| try source.appendSlice(std.testing.allocator, "}`");
    try source.appendSlice(std.testing.allocator, ";\n");

    var calibration = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
        .resize_fail_index = std.math.maxInt(usize),
    });
    var atoms = zts.AtomTable.init(calibration.allocator());
    defer atoms.deinit();
    var parser = try zts.parser.JsParser.initAdmission(
        calibration.allocator(),
        calibration.allocator(),
        source.items,
        .collect,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = switch (try parser.parseAdmission()) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), parser.type_store.type_only_modules.items.len);
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    try std.testing.expectEqual(zts.parser.NodeTag.program, view.getTag(root).?);

    const validation_alloc_index = calibration.alloc_index;
    const validation_resize_index = calibration.resize_index;
    calibration.fail_index = validation_alloc_index;
    calibration.resize_fail_index = validation_resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        parser.type_store.validateRuntimeOwners(calibration.allocator(), view),
    );
    try std.testing.expect(calibration.has_induced_failure);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = validation_alloc_index,
        .resize_fail_index = validation_resize_index,
    });
    var result = try runCheckOnlyFromSourceWithOptions(
        failing.allocator(),
        source.items,
        "validation-allocation.ts",
        .{ .json_mode = true },
    );
    defer result.deinit(failing.allocator());

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    try std.testing.expect(result.contract == null);
}

test "CHECK preserves legacy absent compound propagated errors" {
    const allocator = std.testing.allocator;
    const annotations = [_][]const u8{
        "``",
        "((())) | Unsupported",
        "((()))[] | string",
        "((())) | ((p0: number, p1: number, p2: number, p3: number, " ++
            "p4: number, p5: number, p6: number, p7: number, " ++
            "p8: number, p9: number, p10: number, p11: number, " ++
            "p12: number, p13: number, p14: number, p15: number) => number)",
    };
    var observed: usize = 0;
    for (annotations) |annotation| {
        const source = try legacyCompoundSource(allocator, annotation);
        defer allocator.free(source);
        try std.testing.expectError(
            error.UnresolvedTypeBinding,
            runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
                .json_mode = true,
                .skip_contract = true,
            }),
        );
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), annotations.len);
    try std.testing.expectEqual(annotations.len, observed);
}
test "CHECK preserves present generic bodies with absent semantic types" {
    const source =
        "structural Empty<T> = ();\n" ++
        "const bare: Empty = \"x\";\n" ++
        "const applied: Empty<string> = \"x\";\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    try std.testing.expectError(
        error.UnresolvedTypeBinding,
        runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        }),
    );
}

test "CHECK preserves declaration admission and named type outcomes" {
    const allocator = std.testing.allocator;
    const FailureStage = enum { parse, types, contract };
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: FailureStage,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .name = "root", .source = "structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .name = "leading_spaces", .source = "  structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 3, .suggestion = null } },
        .{ .name = "after_newline", .source = "const seed = 1;\n  structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 3, .suggestion = null } },
        .{ .name = "after_semicolon", .source = "const seed = 1; structural Alias = number;\nconst value: Alias = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 17, .suggestion = null } },
        .{ .name = "nested_left", .source = "function handler(req: Request): Response {\nstructural Alias = number;\nconst value: Alias = \"x\";\nreturn Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "nested_indented", .source = "function handler(req: Request): Response {\n  structural Alias = number;\n  const value: Alias = \"x\";\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 3, .suggestion = null } },
        .{ .name = "nominal_runtime_collision", .source = "nominal UserId = string;\nfunction UserId(value: string): string {\n  return value;\n}\nfunction handler(req: Request): Response {\n  const value = UserId(\"x\");\n  return Response.text(value);\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS214", .message = "`UserId` is a nominal type, not a constructor", .line = 6, .column = 23, .suggestion = "brand at an annotated declaration: `const x: Name = value;`" } },
        .{ .name = "structural_runtime_collision", .source = "structural UserId = string;\nfunction UserId(value: string): string {\n  return value;\n}\nfunction handler(req: Request): Response {\n  const value = UserId(\"x\");\n  return Response.text(value);\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "eager_alias", .source = "structural A = string;\nstructural B = A;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "forward_alias", .source = "structural B = A;\nstructural A = string;\nstructural A = number;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'A'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "nested_alias_global", .source = "function define(): number {\nstructural A = string;\nreturn 1;\n}\nconst value: A = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 5, .column = 1, .suggestion = null } },
        .{ .name = "unused_cycle", .source = "structural A = A | number;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "used_cycle", .source = "structural A = A | number;\nconst value: A = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS212", .message = "recursive type alias 'A' has a cycle no data constructor guards", .line = 2, .column = 1, .suggestion = "route the recursion through a record, a tuple, or an array, the way `type JsonValue = ... | readonly JsonValue[]` does; a union or intersection edge does not guard it" } },
        .{ .name = "forward_alias_number", .source = "structural B = A;\nstructural A = string;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "suffixed_alias_string", .source = "structural A = string;\nstructural B = A tolerated_suffix;\nstructural A = number;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'A'", .line = 4, .column = 1, .suggestion = null } },
        .{ .name = "suffixed_alias_number", .source = "structural A = string;\nstructural B = A tolerated_suffix;\nstructural A = number;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .name = "primitive_declaration", .source = "structural string = number;\nstructural B = string;\nconst value: B = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "primitive_annotation", .source = "structural string = number;\nconst value: string = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .name = "primitive_nominal", .source = "structural string = number;\nnominal UserId = string;\nconst value: UserId = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'UserId'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "primitive_nested", .source = "structural string = number;\nstructural B = string | boolean;\nconst value: B = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string | boolean'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "named_arrays", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: Alias[][] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Alias[]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "grouped_arrays", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: (Alias)[][] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Alias[][]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_root", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: readonly Items = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'readonly string[]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_record", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: { field: readonly Items } = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type '{ field: Readonly<Items> }'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_tuple", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: [readonly Items] = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type '[Readonly<Items>]'", .line = 3, .column = 1, .suggestion = null } },
        .{ .name = "readonly_nullable", .source = "structural Alias = number;\nstructural Items = string[];\nconst value: readonly Items | undefined = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'readonly string[] | undefined'", .line = 3, .column = 1, .suggestion = null } },
    };
    const types_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("declaration baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        switch (case.stage) {
            .parse => {
                try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
                try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .types => {
                try std.testing.expectEqual(types_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 1), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .contract => {
                try std.testing.expectEqual(full_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract != null);
            },
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}
test "CHECK preserves declaration suffix refusals and empty bodies" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .source = "structural Alias = number any;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" } },
        .{ .source = "structural Alias = number void;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `undefined`" } },
        .{ .source = "structural Alias = number Array<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `T[]`" } },
        .{ .source = "structural Alias = number ReadonlyArray<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS059", .message = "`ReadonlyArray<T>` is not a type spelling in this profile", .line = 1, .column = 27, .suggestion = "write `readonly T[]`" } },
        .{ .source = "structural Alias = ;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .source = "structural Alias = ();\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
    };
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        if (case.strip_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expect(result.contract == null);
        } else {
            try std.testing.expectEqual(full_stages, result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expect(result.contract != null);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}
test "CHECK preserves nominal refusals and keyword alias names" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .source = "nominal Bad = void;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = Array<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = ReadonlyArray<string>;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = (x?: number) => number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad = any;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" } },
        .{ .source = "nominal Bad = ;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 12, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "nominal Bad   ;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
        .{ .source = "structural true = number;\nconst value: true = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural null = number;\nconst value: null = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural undefined = number;\nconst value: undefined = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "structural function = number;\nconst value: function = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        if (case.strip_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK retains distinct nominal any and scalar refusal positions" {
    const allocator = std.testing.allocator;
    const source =
        "nominal Bad = number any;\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 2), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
    try std.testing.expect(result.contract == null);
    const expected = [_]LegacyCompoundDiagnostic{
        .{
            .code = "ZTS041",
            .message = "'any' type is not supported",
            .line = 1,
            .column = 22,
            .suggestion = "use specific types (string, number, object) or union types instead",
        },
        .{
            .code = "ZTS048",
            .message = "a nominal declaration carries scalar identity only",
            .line = 1,
            .column = 15,
            .suggestion = "its base must be `string`, `number`, or `boolean`",
        },
    };
    try std.testing.expectEqual(expected.len, result.json_diagnostics.items.len);
    for (result.json_diagnostics.items, expected) |actual, diagnostic| {
        try expectLegacyCompoundDiagnostic(actual, diagnostic);
    }
}
test "CHECK admits declaration literals and blank-line continuations" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, message: []const u8, line: u32 }{
        .{ .source = "structural N = 1;\nconst value: N = 2;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type '2' is not assignable to type '1'", .line = 2 },
        .{ .source = "structural U = | number | string;\nconst value: U = true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type 'true' is not assignable to type 'number | string'", .line = 2 },
        .{ .source = "structural A = number |\n\nstring;\nconst value: A = true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type 'true' is not assignable to type 'number | string'", .line = 4 },
        .{ .source = "structural A = { id: number } &\n\n{ tag: string };\nconst value: A = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .message = "type '1' is not assignable to type '{ id: number } & { tag: string }'", .line = 4 },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = case.message,
            .line = case.line,
            .column = 1,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves comment gaps around type declarations" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .source = "structural /*c*/ A = number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "structural A /*c*/ = number;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 20, .suggestion = null } },
        .{ .source = "structural A = number\n/*c*/;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .diagnostic = .{ .code = "ZTS001", .message = "empty statements are not supported", .line = 2, .column = 6, .suggestion = "remove the standalone `;`" } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expect(result.contract == null);
    }
}
test "CHECK preserves generic admission and projection outcomes" {
    const allocator = std.testing.allocator;
    const FailureStage = enum { strip, parse, types, contract };
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        stage: FailureStage,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{ .name = "adjacent_function", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_function", .source = "function id <T>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 18, .suggestion = "')'" }} },
        .{ .name = "generic_arrow", .source = "const id = <T>(x: T): T => x;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_alias", .source = "structural Box <T> = { value: T };\nconst probe: Box<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nested_function", .source = "function outer(): number {\n  function id<T>(x: T): T { return x; }\n  return id(\"x\");\n}\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 3, .column = 3, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" }} },
        .{ .name = "function_default", .source = "function make<T = string>(x: T): T { return x; }\nconst probe: number = make(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "alias_default", .source = "structural Box<T = string> = { value: T };\nconst probe: Box<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "function_constraint_default", .source = "function id<T extends string = number>(x: T): T { return x; }\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "alias_constraint_default", .source = "structural Box<T extends string = number> = { value: T };\nconst probe: Box<number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: number }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "eight_parameters", .source = "function f<A,B,C,D,E,F,G,H>(x: H): H { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nine_parameters_eight_arguments", .source = "function f<A,B,C,D,E,F,G,H,I>(x: I): I { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected I, got \"x\"", .line = 2, .column = 82, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'I' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nine_parameters_nine_arguments", .source = "function f<A,B,C,D,E,F,G,H,I>(x: I): I { return x; }\nconst probe: number = f<string,string,string,string,string,string,string,string,string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected I, got \"x\"", .line = 2, .column = 89, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'I' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nine_alias_parameters", .source = "structural N<A,B,C,D,E,F,G,H,I> = I;\nconst probe: N<string,string,string,string,string,string,string,string,number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'N<string, string, string, string, string, string, string, string, number>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nongeneric_then_generic", .source = "structural Box = number;\nstructural Box<T> = T;\nconst bare: Box = \"x\";\nconst applied: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } } },
        .{ .name = "generic_then_nongeneric", .source = "structural Box<T> = T;\nstructural Box = number;\nconst bare: Box = \"x\";\nconst applied: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 4, .column = 1, .suggestion = null } } },
        .{ .name = "alias_before_parameter", .source = "structural T = number;\nfunction f<T>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 3, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'number' is not assignable to type 'string'", .line = 3, .column = 1, .suggestion = null } } },
        .{ .name = "duplicate_parameters", .source = "function f<T,T>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "repeated_generic_alias", .source = "structural Box<T> = { value: T };\nstructural Box<T> = T;\nconst probe: Box<string> = 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '1' is not assignable to type 'string'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "repeated_nongeneric_alias", .source = "structural Box = string;\nstructural Box = number;\nconst probe: Box = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "application_array", .source = "structural Box<T> = { value: T };\nconst probe: Box<string>[] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "grouped_application_array", .source = "structural Box<T> = { value: T };\nconst probe: (Box<string>)[] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Box<string>[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "nested_application", .source = "structural Box<T> = { value: T };\nconst probe: Box<Box<string>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: { value: string } }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "readonly_application", .source = "structural Box<T> = { value: T };\nconst probe: Readonly<Box<string>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "union_application", .source = "structural Box<T> = { value: T };\nconst probe: Box<string> | number = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: string } | number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "record_application", .source = "structural Box<T> = { value: T };\nconst probe: { field: Box<string> } = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ field: Box<string> }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "tuple_application", .source = "structural Box<T> = { value: T };\nconst probe: [Box<string>] = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '[Box<string>]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "adjacent_call", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id<string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "spaced_call", .source = "function id<T>(x: T): T { return x; }\nconst probe: number = id<string> (\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'boolean' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "comparison_control", .source = "const cond = true;\nconst left = 1;\nconst right = 2;\nconst value = cond ? left < right : right > left;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "shift_control", .source = "const value = 8 >> 1;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "comparison_shift_control", .source = "const a = 1;\nconst b = 2;\nconst c = 1;\nconst value = a < b >> c;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "comparison_unsigned_shift_control", .source = "const a = 1;\nconst b = 2;\nconst c = 1;\nconst value = a < b >>> c;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 5, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "method_call", .source = "const object = { id: <T>(value: T): T => value };\nconst probe: number = object.id<string>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .contract, .diagnostics = &.{.{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." }} },
        .{ .name = "triple_closer", .source = "structural Box<T> = { value: T };\nconst probe: Box<Box<Box<string>>> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ value: { value: { value: string } } }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "application_missing_comma", .source = "structural Box<T> = { value: T };\nconst probe: Box<string number> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Box<string, number>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "application_missing_close", .source = "structural Box<T> = { value: T };\nconst probe: Box<string = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{ .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 6, .column = 1, .suggestion = null }, .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 2, .column = 7, .suggestion = null } } },
        .{ .name = "call_missing_comma", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<string number>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "call_missing_close", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<string(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'boolean' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "user_alias_too_few", .source = "structural Duo<A,B> = { first: A; second: B };\nconst probe: Duo<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Duo<string>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "user_alias_too_many", .source = "structural Duo<A,B> = { first: A; second: B };\nconst probe: Duo<string,number,boolean> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Duo<string, number, boolean>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "partial_surplus", .source = "structural User = { id: number };\nconst probe: Partial<User,string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ id?: number }'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "partial_missing", .source = "structural User = { id: number };\nconst probe: Partial<> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Partial<>'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "dict_one", .source = "const probe: Dict<string> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Dict<string>'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "dict_three", .source = "const probe: Dict<string,number,boolean> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type 'Dict<string, number, boolean>'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "proof_replacement", .source = "structural Proof<T,P> = T;\nconst probe: Proof<number,\"pure\"> = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "effects_replacement", .source = "structural Effects<T,E> = T;\nconst probe: Effects<number,\"env\"> = \"x\";\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "forward_constraint", .source = "function f<T,U extends T>(a: T,b: U): U { return b; }\nconst probe: string = f(1,2);\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument 2 for 'U' does not satisfy constraint T", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "nested_comma_constraint", .source = "function f<T extends Record<string,number>>(value: T): T { return value; }\nconst probe: number = f({ id: \"x\" });\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument { id: \"x\" } for 'T' does not satisfy constraint Record<string, number>", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_constraint", .source = "function f<T extends any>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument \"x\" for 'T' does not satisfy constraint any", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_call_argument", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<any>(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected any, got \"x\"", .line = 2, .column = 31, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'any' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "removed_default", .source = "function f<T = any>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "unclosed_function_angles", .source = "function f<T(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .parse, .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 11, .suggestion = "'('" }} },
        .{ .name = "utility_collision", .source = "structural Partial<T> = number;\nstructural User = { id: string };\nconst probe: Partial<User> = undefined;\nfunction handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ id?: string }'", .line = 3, .column = 1, .suggestion = null }} },
        .{ .name = "void_constraint", .source = "function f<T extends void>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" }} },
        .{ .name = "array_default", .source = "function f<T = Array<string>>(value: T): T { return value; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 1, .column = 16, .suggestion = "write `T[]`" }} },
        .{ .name = "array_call_argument", .source = "function id<T>(value: T): T { return value; }\nconst probe: number = id<Array<string>>(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostics = &.{.{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 2, .column = 26, .suggestion = "write `T[]`" }} },
        .{ .name = "quoted_comma_one_call", .source = "function f<T>(x: T): T { return x; }\nconst probe: number = f<\"a,b\">(\"a\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS210", .message = "wrong number of type arguments: expected 1, got 2", .line = 2, .column = 31, .suggestion = "Give one type argument for each declared type parameter." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_comma_two_call", .source = "function f<T,U>(x: T,y: U): T { return x; }\nconst probe: number = f<\"a,b\">(\"a\",1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected b, got 1", .line = 2, .column = 36, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"a\"' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_angle_default", .source = "function f<T = \">\",U = number>(x: U): U { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "quoted_comma_default", .source = "function f<T = \"a,b\",U = number>(x: U): U { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'U' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "comment_call", .source = "function f<T>(x: T): T { return x; }\nconst probe: number = f<string /* , */>(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS210", .message = "wrong number of type arguments: expected 1, got 2", .line = 2, .column = 40, .suggestion = "Give one type argument for each declared type parameter." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "comment_parameters", .source = "function f<T /* , */ ,U>(x: T,y: U): T { return x; }\nconst probe: number = f(\"x\",1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter '*/'", .line = 2, .column = 24, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "dictkey_constraint", .source = "function f<T extends DictKey>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'number' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "dictkey_default", .source = "function f<T extends DictKey = string>(x: T): T { return x; }\nconst probe: string = f(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument 1 for 'T' does not satisfy constraint DictKey", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'string'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "readonly_inline_record", .source = "const probe: { field: Readonly<{ id: number }> } = undefined;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '{ field: { id: number } }'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "readonly_inline_tuple", .source = "const probe: [Readonly<{ id: number }>] = undefined;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'undefined' is not assignable to type '[{ id: number }]'", .line = 1, .column = 1, .suggestion = null }} },
        .{ .name = "name32_root", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name33_root", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name32_array", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[]): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[] { return x; }\nconst probe: number[] = f([\"x\"]);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string[]' is not assignable to type 'number[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "name33_array", .source = "function f<TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT>(x: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[]): TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT[] { return x; }\nconst probe: number[] = f([\"x\"]);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string[]' is not assignable to type 'number[]'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "empty_first_name", .source = "function f<=string,T extends number>(x: T): T { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "constraint_control", .source = "function f<T extends number>(x: T): T { return x; }\nconst probe: number = f(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS209", .message = "type argument \"x\" for 'T' does not satisfy constraint number", .line = 2, .column = 24, .suggestion = null }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "empty_alias_parameters", .source = "structural Box<> = number;\nconst bare: Box = \"x\";\nconst applied: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box'", .line = 2, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null } } },
        .{ .name = "parenthesized_arrow_spaced_window", .source = "const id = (<T> (value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 2, .column = 25, .suggestion = "Name the type argument at the call site." }, .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null } } },
        .{ .name = "parenthesized_arrow_adjacent_window", .source = "const id = (<T>(value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "assignment_arrow_spaced_window", .source = "const id = <T> (value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{.{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null }} },
        .{ .name = "empty_generic_alias_body", .source = "structural Box<> = ;\nconst bare: Box = \"x\";\nconst applied: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{ .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box'", .line = 2, .column = 1, .suggestion = null }, .{ .code = "ZTS200", .message = "type '\"x\"' is not assignable to type 'Box<>'", .line = 3, .column = 1, .suggestion = null } } },
    };
    const types_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("generic baseline failed: {s}\n", .{case.name});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        try std.testing.expect(case.diagnostics.len > 0);
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        const errors: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(errors, result.totalErrors());
        switch (case.stage) {
            .strip => {
                try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
                try std.testing.expectEqual(errors, result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .parse => {
                try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
                try std.testing.expectEqual(errors, result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .types => {
                try std.testing.expectEqual(types_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(errors, result.type_errors);
                try std.testing.expect(result.contract == null);
            },
            .contract => {
                try std.testing.expectEqual(full_stages, result.stages_run);
                try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
                try std.testing.expectEqual(@as(u32, 0), result.type_errors);
                try std.testing.expect(result.contract != null);
            },
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 77), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}
test "CHECK preserves ignored generic syntax and raw semantic projection" {
    const cases = [_][]const u8{
        "structural Box<T>=T;\nconst value: Box<number> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T> = T;\nconst value: Box<number>=\"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = (left < right)> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends { value: Missing < } = boolean> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends Wrap<{ value: Missing < }, string> = boolean> = number;\nconst value: Box<> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = /x> = number; /* tail */\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = (left > right)> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends { value: Missing > }> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T extends \"a=b\" = boolean> = number;\nconst value: Box<string> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "structural Box<T = Wrap<(x: string) => number, string>> = number;\nconst value: Box<string,number> = \"x\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
    };
    const stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    var observed: usize = 0;
    for (cases) |source| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS200",
            .message = "type '\"x\"' is not assignable to type 'number'",
            .line = 2,
            .column = 1,
            .suggestion = null,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves a caught generic string diagnostic" {
    const source =
        "structural Box<T = (\"x\n)> = number;\n" ++
        "const value: Box<string> = \"x\";\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS008",
        .message = "unterminated string literal",
        .line = 1,
        .column = 23,
        .suggestion = "close the quote, or write the newline as \\n",
    });
}

test "CHECK preserves the any suffix refusal in a generic alias name" {
    const source =
        "structural Many<A,B,C,D,E,F,G,H> = H;\n" ++
        "const value: Many<string,string,string,string,string,string,string,number> = undefined;\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
    try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 0), result.type_errors);
    try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
    try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS041",
        .message = "'any' type is not supported",
        .line = 2,
        .column = 15,
        .suggestion = "use specific types (string, number, object) or union types instead",
    });
}

test "CHECK preserves the general generic arrow window after an assignment comment" {
    const source =
        "const id = /* gap */ <T> (value: T): T => value;\n" ++
        "const probe: number = id(\"x\");\n" ++
        "function handler(req: Request): Response { return Response.text(\"ok\"); }\n";
    var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
        .json_mode = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
    try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
    try std.testing.expectEqual(@as(u32, 2), result.type_errors);
    try std.testing.expectEqual(@as(u32, 2), result.totalErrors());
    try std.testing.expect(result.contract == null);
    try std.testing.expectEqual(@as(usize, 2), result.json_diagnostics.items.len);
    try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
        .code = "ZTS208",
        .message = "no argument determines type parameter 'T>'",
        .line = 2,
        .column = 25,
        .suggestion = "Name the type argument at the call site.",
    });
    try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[1], .{
        .code = "ZTS200",
        .message = "type 'T' is not assignable to type 'number'",
        .line = 2,
        .column = 1,
        .suggestion = null,
    });
}

test "CHECK preserves arrow capture after line comment text" {
    const cases = [_]struct {
        source: []const u8,
        parse_refusal: bool,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .source = "const id = // note\n<T>(value: T): T => value;\n" ++
                "const probe: number = id(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parse_refusal = false,
            .diagnostics = &.{
                .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected T, got \"x\"", .line = 3, .column = 26, .suggestion = null },
                .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
            },
        },
        .{
            .source = "const id = // note\n<T> (value: T): T => value;\n" ++
                "const probe: number = id(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parse_refusal = true,
            .diagnostics = &.{.{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 2, .column = 1, .suggestion = null }},
        },
        .{
            .source = "const id = // note=\n<T> (value: T): T => value;\n" ++
                "const probe: number = id(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parse_refusal = false,
            .diagnostics = &.{
                .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 3, .column = 25, .suggestion = "Name the type argument at the call site." },
                .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
            },
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        try std.testing.expect(result.contract == null);
        if (case.parse_refusal) {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 2), result.type_errors);
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves legacy predicate target and return classification" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        type_failure: bool,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .source = "function guard(value: unknown): missing is string { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .type_failure = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .source = "function guard(value: unknown): \"x is y\" { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .type_failure = false, .diagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." } },
        .{ .source = "function guard(value: unknown): value\tis\tstring { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .type_failure = true, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 51, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
    };
    const typed_stages = StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
    const full_stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        if (case.type_failure) {
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try std.testing.expectEqual(typed_stages, result.stages_run);
            try std.testing.expect(result.contract == null);
        } else {
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try std.testing.expectEqual(full_stages, result.stages_run);
            try std.testing.expect(result.contract != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
}

test "CHECK preserves nominal declarations with ignored generic lists" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        strip_refusal: bool,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{ .source = "nominal Id<T> = string;\nconst value: Id = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = false, .diagnostic = .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'Id'", .line = 2, .column = 1, .suggestion = null } },
        .{ .source = "nominal Id<T> = T;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .strip_refusal = true, .diagnostic = .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 17, .suggestion = "its base must be `string`, `number`, or `boolean`" } },
    };
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        if (case.strip_refusal) {
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        } else {
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
}

test "CHECK preserves orphan generic prefix refusal positions" {
    const cases = [_]struct { source: []const u8, column: u32 }{
        .{ .source = "const value = <T> extends string;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 19 },
        .{ .source = "const value = (<T> extends string);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 20 },
        .{ .source = "<T> extends string;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .column = 5 },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS002",
            .message = "expected expression",
            .line = 1,
            .column = case.column,
            .suggestion = null,
        });
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves admitted generic prefixes without function owners" {
    const cases = [_][]const u8{
        "const value = <T>{ id: 1 };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = (<T>{ id: 1 });\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <T>(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "<T>{ const value = 1; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <>{ id: 1 };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <>(1);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = (<> (1));\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <T>(<U>(1));\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <T>{ id: <U>(1) };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
        "const value = <T>((x) => x);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n",
    };
    const stages = StageSet.initMany(&.{
        .strip, .parse,    .imports, .boolean, .types, .strict,    .verifier,
        .flow,  .contract, .paths,   .trace,   .spec,  .canonical,
    });
    const diagnostic: LegacyCompoundDiagnostic = .{
        .code = "ZTS500",
        .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
        .line = 2,
        .column = 17,
        .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`.",
    };
    var observed: usize = 0;
    for (cases) |source| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract != null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], diagnostic);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves adjacent generic prefix refusals" {
    const cases = [_]struct { prefix: []const u8, column: u32 }{
        .{ .prefix = "const value = <T><U>{ id: 1 };", .column = 15 },
        .{ .prefix = "const value = <T><U>(1);", .column = 15 },
        .{ .prefix = "const value = (<T><U>{ id: 1 });", .column = 16 },
        .{ .prefix = "const value = (<T><U>(1));", .column = 16 },
        .{ .prefix = "<T><U>{ const value = 1; }", .column = 1 },
    };
    inline for (cases) |case| {
        const source = case.prefix ++ "\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n";
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expect(result.contract == null);
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
            .code = "ZTS002",
            .message = "raw JSX is not supported; use ordinary TypeScript expressions",
            .line = 1,
            .column = case.column,
            .suggestion = null,
        });
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
}

test "CHECK preserves typed parameter refusals across function header comments" {
    const cases = [_]struct {
        source: []const u8,
        parameter_column: ?u32,
    }{
        .{
            .source = "function /* gap */ identity<T>(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = 37,
        },
        .{
            .source = "function identity<T>/* gap */(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = 36,
        },
        .{
            .source = "function identity<T>(value: T): T { return value; }\n" ++
                "const probe: number = identity(\"x\");\n" ++
                "function handler(req: Request): Response { return Response.text(\"ok\"); }\n",
            .parameter_column = null,
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try std.testing.expect(result.contract == null);
        if (case.parameter_column) |column| {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 0), result.type_errors);
            try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
                .code = "ZTS003",
                .message = "unexpected token",
                .line = 1,
                .column = column,
                .suggestion = "')'",
            });
        } else {
            try std.testing.expectEqual(StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }), result.stages_run);
            try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
            try std.testing.expectEqual(@as(u32, 1), result.type_errors);
            try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], .{
                .code = "ZTS200",
                .message = "type 'string' is not assignable to type 'number'",
                .line = 2,
                .column = 1,
                .suggestion = null,
            });
        }
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves typed arrow return forms and parameter refusals" {
    const FailureStage = enum { strip, parse, types, strict, contract };
    const proof_diagnostic: LegacyCompoundDiagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostic: LegacyCompoundDiagnostic }{
        .{ .source = "const guard = (candidate, marker: unknown): candidate is string => typeof candidate === \"string\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strict, .diagnostic = .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 1, .column = 15, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" } },
        .{ .source = "const echo = (value: string): string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const echo = (value?: string): string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 20, .suggestion = "replace `name?: T` with `name: T | undefined`" } },
        .{ .source = "const echo = (value?) => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 20, .suggestion = "')'" } },
        .{ .source = "function echo(value?: string): string { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 20, .suggestion = "replace `name?: T` with `name: T | undefined`" } },
        .{ .source = "function echo(value?) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 20, .suggestion = "')'" } },
        .{ .source = "const echo = (value: string = \"x\"): string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 29, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
        .{ .source = "const echo = async (value: string): string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS001", .message = "'async' functions are not supported", .line = 1, .column = 14, .suggestion = "handlers run synchronously - use 'fetch' from zttp:fetch for outbound I/O" } },
        .{ .source = "const result = [\"a\"].map((value: string): string => value);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const object = { echo: (value: string): string => value };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const echo = ((value: string): string => value);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const make = (): (value: string) => string => (value: string): string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const guard = (value: unknown): missing is string => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const guard = (value: unknown): \"x is y\" => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const guard = (value: unknown): value\tis\tstring => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 15, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "const guard = (readonly: unknown): readonly\tis\tstring => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 15, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "const echo = value: string => value;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 14, .suggestion = null } },
        .{ .source = "const choice = true ? \"a\" : \"b\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const choice = true ? (1) : (2);\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const make = (): (value: string) => string;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "unexpected ')'", .line = 1, .column = 16, .suggestion = null } },
        .{ .source = "function guard(value: unknown): value is { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "const guard = (value: unknown): value is => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
        .{ .source = "function guard(value: unknown): value\tis { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 44, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "const guard = (value: unknown): value\tis => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS204", .message = "return type does not match declared return type", .line = 1, .column = 15, .suggestion = "the enclosing function's declared return type is what this value must match; when it comes back from a virtual-module call, wrap it rather than returning it directly" } },
        .{ .source = "function guard(value: unknown): value is string   { return true; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostic = .{ .code = "ZTS211", .message = "type predicate 'guard' is not verified by its body", .line = 1, .column = 1, .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !." } },
        .{ .source = "const guard = (value: unknown): value is string   => true;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = proof_diagnostic },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("arrow baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .types, .strict => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strip or case.stage == .parse) 1 else 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) 1 else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strict) 1 else 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves predicate marker classification" {
    const FailureStage = enum { types, contract };
    const cases = [_]struct {
        source: []const u8,
        stage: FailureStage,
        diagnostic: LegacyCompoundDiagnostic,
    }{
        .{
            .source = "function guard(candidate: unknown): candidate is \"a is b\" { return true; }\n",
            .stage = .types,
            .diagnostic = .{
                .code = "ZTS211",
                .message = "type predicate 'guard' is not verified by its body",
                .line = 1,
                .column = 1,
                .suggestion = "Return one admitted narrowing test over the named parameter, combined with &&, || or !.",
            },
        },
        .{
            .source = "function guard(candidate: unknown): candidate\tis \"a is b\" { return true; }\n",
            .stage = .contract,
            .diagnostic = .{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: cost_bounded, deterministic, fault_covered, idempotent, optional_safe, result_safe. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\">`.",
            },
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .types => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .contract, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) 1 else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves type-only module admission and refusal diagnostics" {
    const FailureStage = enum { strip, parse, contract };
    const proof_diagnostic: LegacyCompoundDiagnostic = .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 2, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostic: LegacyCompoundDiagnostic }{
        .{ .source = "import type { A } from \"./a\";\nexport type { B }\nexport structural Shape = { value: string };\nexport nominal Id = string;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 6, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number { import type { A } from \"./a\"; return 1; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 29, .suggestion = null } },
        .{ .source = "function helper(): number { export type { A }; return 1; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 29, .suggestion = null } },
        .{ .source = "{ import type { A } from \"./a\"; const live = 1; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 3, .suggestion = null } },
        .{ .source = "import type { A } from \"./a;b\";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import /* gap */ type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "import type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" } },
        .{ .source = "import type { A } /* \"zttp:types\" */ from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strip, .diagnostic = .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" } },
        .{ .source = "export type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type { A }   \nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type\n{ A };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 1, .suggestion = null } },
        .{ .source = "import\ntype { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 3, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "import type nonsense;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "export type { broken nonsense };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\n  import type { A } from \"./a\";\n  return 1;\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "function helper(): number {\n  export type { A };\n  return 1;\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "{\n  import type { A } from \"./a\";\n  const live = 1;\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 2, .column = 3, .suggestion = null } },
        .{ .source = "{import type { A } from \"./a\";}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {import type { A } from \"./a\";return 1;}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {export type { A };return 1;}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "{\nimport type { A } from \"./a\";\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 4, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\nimport type { A } from \"./a\";\nreturn 1;\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 5, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "function helper(): number {\nexport type { A };\nreturn 1;\n}\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 5, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = " import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 2, .suggestion = null } },
        .{ .source = "const live: number = 1;import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .contract, .diagnostic = .{ .code = proof_diagnostic.code, .message = proof_diagnostic.message, .line = 2, .column = proof_diagnostic.column, .suggestion = proof_diagnostic.suggestion } },
        .{ .source = "const live: number = 1; import type { A } from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'import X from' default imports are not supported; use named imports: import { x } from \"module\"", .line = 1, .column = 25, .suggestion = null } },
        .{ .source = "import type { A } from \"./a\";export type { B };\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostic = .{ .code = "ZTS002", .message = "'export' must be followed by 'function', 'const', or 'let'", .line = 1, .column = 30, .suggestion = null } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("module baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        const expected_stages = switch (case.stage) {
            .strip => StageSet.initMany(&.{.strip}),
            .parse => StageSet.initMany(&.{ .strip, .parse }),
            .contract => StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical }),
        };
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .contract) 0 else 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.stage == .contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 28), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves lexical diagnostics inside type-only modules" {
    const cases = [_]struct { source: []const u8, contract: bool, diagnostics: []const LegacyCompoundDiagnostic }{
        .{ .source = "import type \"open\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 18, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type \"open\\\nclosed\";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 4, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type `${" ++ ("{" ** 511) ++ "1" ++ ("}" ** 512) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type `${" ++ ("{" ** 512) ++ ";" ++ ("}" ** 513) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 1, .column = 527, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
        .{ .source = "import type " ++ ("`${" ** 511) ++ "1" ++ ("}`" ** 511) ++ ";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type " ++ ("`${" ** 513) ++ "1" ++ ("}`" ** 513) ++ ";\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = true, .diagnostics = &.{
            .{ .code = "ZTS500", .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold", .line = 3, .column = 17, .suggestion = "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, but it does not hold: fault_covered. Return a narrow Proof capsule with only the properties it holds, e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | \"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`." },
        } },
        .{ .source = "import type \"open\nimport type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 2, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type `${\"open\n\"}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 21, .suggestion = "close the quote, or write the newline as \\n" },
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 5, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type \"open\nconst broken = ;\nimport type { Spec } from \"zttp:types\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 3, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type `${" ++ ("{" ** 511) ++ "`${" ++ ("{" ** 512) ++ ";" ++ ("}" ** 513) ++ "}`" ++ ("}" ** 512) ++ "}`;\nconst live: number = 1;\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .contract = false, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 1, .column = 1041, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("module lexical baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        const expected_stages = if (case.contract)
            StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict, .verifier, .flow, .contract, .paths, .trace, .spec, .canonical })
        else
            StageSet.initMany(&.{.strip});
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.contract) 0 else @intCast(case.diagnostics.len)), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(case.contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves typed generic arrows and comment classification" {
    const FailureStage = enum { parse, types, strict };
    const cases = [_]struct { source: []const u8, stage: FailureStage, diagnostics: []const LegacyCompoundDiagnostic }{
        .{ .source = "const id=<T>(value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id=(<T> (value: T): T => value);\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS208", .message = "no argument determines type parameter 'T>'", .line = 2, .column = 25, .suggestion = "Name the type argument at the call site." },
            .{ .code = "ZTS200", .message = "type 'T' is not assignable to type 'number'", .line = 2, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id = // note\n<T = string>(value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "raw JSX is not supported; use ordinary TypeScript expressions", .line = 2, .column = 1, .suggestion = null },
        } },
        .{ .source = "const id = // note=\n<T = string> (value: T): T => value;\nconst probe: number = id(\"x\");\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .types, .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 3, .column = 1, .suggestion = null },
        } },
        .{ .source = "function // note\nidentity<T>(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strict, .diagnostics = &.{
            .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 2, .column = 12, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" },
        } },
        .{ .source = "function identity<T>// note\n(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .strict, .diagnostics = &.{
            .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 2, .column = 1, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" },
        } },
        .{ .source = "function /* before */ identity<T>/* after */(value) { return value; }\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .stage = .parse, .diagnostics = &.{
            .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 31, .suggestion = "'('" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("generic header baseline failed for source:\n{s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const expected_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        const expected_stages = if (case.stage == .parse)
            StageSet.initMany(&.{ .strip, .parse })
        else
            StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict });
        try std.testing.expectEqual(expected_stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.stage == .parse) expected_count else 0), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .types) expected_count else 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, if (case.stage == .strict) expected_count else 0), result.strict_errors);
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves repeated global declaration bindings" {
    const Case = enum {
        two_typed,
        typed_untyped,
        untyped_typed_bad,
        two_typed_bad,
    };
    const proof_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
        "but it does not hold: cost_bounded, deterministic, fault_covered, idempotent, optional_safe, result_safe. " ++
        "Return a narrow Proof capsule with only the properties it holds, e.g. " ++
        "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | " ++
        "\"state_isolated\" | \"pure\" | \"stateless\" | \"no_secret_leakage\" | " ++
        "\"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
        "\"injection_safe\" | \"canonical\">`.";
    const cases = [_]struct {
        case: Case,
        source: []const u8,
        type_errors: u32,
        has_contract: bool,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .case = .two_typed,
            .source = "const value: number = 1;\n" ++
                "const value: string = \"x\";\n",
            .type_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .case = .typed_untyped,
            .source = "const value: number = 1;\n" ++
                "const value = \"x\";\n",
            .type_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 1,
                .column = 1,
                .suggestion = proof_suggestion,
            }},
        },
        .{
            .case = .untyped_typed_bad,
            .source = "const value = 1;\n" ++
                "const value: string = 2;\n",
            .type_errors = 1,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS200",
                .message = "type '2' is not assignable to type 'string'",
                .line = 2,
                .column = 1,
            }},
        },
        .{
            .case = .two_typed_bad,
            .source = "const value: number = \"x\";\n" ++
                "const value: string = 2;\n",
            .type_errors = 2,
            .has_contract = false,
            .diagnostics = &.{
                .{
                    .code = "ZTS200",
                    .message = "type '\"x\"' is not assignable to type 'number'",
                    .line = 1,
                    .column = 1,
                },
                .{
                    .code = "ZTS200",
                    .message = "type '2' is not assignable to type 'string'",
                    .line = 2,
                    .column = 1,
                },
            },
        },
    };
    var seen = std.EnumSet(Case).initEmpty();
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(case.type_errors, result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.has_contract, result.contract != null);
        seen.insert(case.case);
    }
    try std.testing.expectEqual(std.meta.fields(Case).len, seen.count());
}

test "CHECK preserves nominal generic diagnostic order before scalar refusal" {
    const cases = [_]struct { source: []const u8, diagnostics: []const LegacyCompoundDiagnostic }{
        .{ .source = "nominal Id<T extends void> = T;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 30, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void>;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 27, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void> = ;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 30, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends any> = T;", .diagnostics = &.{
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 29, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "nominal Id<T extends void> = any;", .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 22, .suggestion = "write `undefined`" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const expected_count: u32 = @intCast(case.diagnostics.len);
        try std.testing.expectEqual(expected_count, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(expected_count, result.parse_errors);
        try std.testing.expectEqual(@as(u32, 0), result.type_errors);
        try std.testing.expectEqual(@as(u32, 0), result.strict_errors);
        try std.testing.expect(result.contract == null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}

test "CHECK preserves measured lookup winners shadows and captures" {
    const ambient_suggestion =
        "Import a published virtual-module capability or use an ambient name listed by " ++
        "meta.ambient_names.";
    const predicate_suggestion =
        "Return one admitted narrowing test over the named parameter, combined with &&, || or !.";
    const return_suggestion =
        "the enclosing function's declared return type is what this value must match; " ++
        "when it comes back from a virtual-module call, wrap it rather than returning it directly";
    const untyped_contract_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full " ++
        "default profile, but it does not hold: fault_covered. Return a narrow Proof capsule " ++
        "with only the properties it holds, e.g. `function handler(req: Request): " ++
        "Proof<Response, \"deterministic\" | \"read_only\" | \"retry_safe\" | \"idempotent\" | " ++
        "\"state_isolated\" | \"pure\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | " ++
        "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | " ++
        "\"pii_contained\" | \"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";
    const capture_contract_suggestion =
        "this handler returns no Proof<T, P> capsule, so the compiler must prove the full " ++
        "default profile, but it does not hold: fault_covered, idempotent, pure, read_only, " ++
        "retry_safe, stateless. Return a narrow Proof capsule with only the properties it holds, " ++
        "e.g. `function handler(req: Request): Proof<Response, \"deterministic\" | " ++
        "\"state_isolated\" | \"result_safe\" | \"optional_safe\" | \"no_secret_leakage\" | " ++
        "\"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
        "\"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";
    const cases = [_]struct {
        source: []const u8,
        type_errors: u32,
        strict_errors: u32,
        has_contract: bool,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .source =
            \\function useNumber(value: number): number {
            \\  inner(value);
            \\  function inner(item: number): number { return item; }
            \\  return value;
            \\}
            \\function useText(value: string): string {
            \\  inner(value, "");
            \\  function inner(item: string, suffix: string): string { return item; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: useNumber(1), text: useText("x") });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 2,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS203", .message = "argument type does not match parameter type: expected number, got string", .line = 7, .column = 9 },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 2, .column = 3, .suggestion = ambient_suggestion },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'inner'", .line = 7, .column = 3, .suggestion = ambient_suggestion },
            },
        },
        .{
            .source =
            \\{
            \\  function isText(value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "first";
            \\  if (isText(raw)) { const text: string = raw; }
            \\}
            \\{
            \\  function isText(skip: number, value: string | number): value is string {
            \\    return typeof value === "string";
            \\  }
            \\  const raw: string | number = "second";
            \\  if (isText(0, raw)) { const text: string = raw; }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ ok: true });
            \\}
            \\
            ,
            .type_errors = 2,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS211", .message = "type predicate 'isText' is not verified by its body", .line = 9, .column = 3, .suggestion = predicate_suggestion },
                .{ .code = "ZTS200", .message = "type 'string | number' is not assignable to type 'string'", .line = 13, .column = 25 },
            },
        },
        .{
            .source =
            \\function numericValue(): number {
            \\  const value: number = make();
            \\  function make(): number { return 1; }
            \\  return value;
            \\}
            \\function textValue(): string {
            \\  const value: string = make();
            \\  function make(): string { return "text"; }
            \\  return value;
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ number: numericValue(), text: textValue() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 1,
            .has_contract = false,
            .diagnostics = &.{
                .{ .code = "ZTS200", .message = "type 'string' is not assignable to type 'number'", .line = 2, .column = 3 },
                .{ .code = "ZTS629", .message = "unpublished ambient global 'make'", .line = 7, .column = 25, .suggestion = ambient_suggestion },
            },
        },
        .{
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = "typed";
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem() });
            \\}
            \\
            ,
            .type_errors = 0,
            .strict_errors = 0,
            .has_contract = true,
            .diagnostics = &.{.{
                .code = "ZTS500",
                .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                .line = 9,
                .column = 24,
                .suggestion = untyped_contract_suggestion,
            }},
        },
        .{
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): string => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: string = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_errors = 0,
            .strict_errors = 0,
            .has_contract = true,
            .diagnostics = &.{
                .{
                    .code = "ZTS500",
                    .message = "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
                    .line = 12,
                    .column = 24,
                    .suggestion = capture_contract_suggestion,
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: pure)",
                    .line = 12,
                    .column = 24,
                    .suggestion = "annotate `compute` with `Proof<T, \"pure\">` and satisfy it, or inline the helper into the handler.",
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: read_only)",
                    .line = 12,
                    .column = 24,
                    .suggestion = "annotate `compute` with `Proof<T, \"read_only\">` and satisfy it, or inline the helper into the handler.",
                },
                .{
                    .code = "ZTS606",
                    .message = "helper breaks a handler-demanded property and carries no Proof<...> capsule (failing spec: deterministic)",
                    .line = 12,
                    .column = 24,
                    .suggestion = "annotate `compute` with `Proof<T, \"deterministic\">` and satisfy it, or inline the helper into the handler.",
                },
            },
        },
        .{
            .source =
            \\const item: number = 1;
            \\function readItem(): string {
            \\  const item = "inferred";
            \\  {
            \\    const item: string = 2;
            \\    return item;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ top: item, nested: readItem() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS200",
                .message = "type '2' is not assignable to type 'string'",
                .line = 5,
                .column = 5,
            }},
        },
        .{
            .source =
            \\function compute(): number {
            \\  const value: number = 1;
            \\  const readOuter = (): number => value;
            \\  {
            \\    const value: string = "inner";
            \\    const readInner = (): number => value;
            \\    const outerResult: number = readOuter();
            \\    const innerResult: number = readInner();
            \\    return outerResult;
            \\  }
            \\}
            \\export function handler(req: Request): Response {
            \\  return Response.json({ value: compute() });
            \\}
            \\
            ,
            .type_errors = 1,
            .strict_errors = 0,
            .has_contract = false,
            .diagnostics = &.{.{
                .code = "ZTS204",
                .message = "return type does not match declared return type",
                .line = 6,
                .column = 23,
                .suggestion = return_suggestion,
            }},
        },
    };
    var observed: usize = 0;
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(
            std.testing.allocator,
            case.source,
            "handler.ts",
            .{ .json_mode = true },
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expectEqual(case.type_errors, result.type_errors);
        try std.testing.expectEqual(case.strict_errors, result.strict_errors);
        try std.testing.expectEqual(
            @as(u32, @intCast(case.diagnostics.len)),
            result.totalErrors(),
        );
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.has_contract, result.contract != null);
        observed += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), cases.len);
    try std.testing.expectEqual(cases.len, observed);
}
test "CHECK preserves measured recovery contexts and raw recognition guards" {
    const allocator = std.testing.allocator;
    const any_message = "'any' type is not supported";
    const any_suggestion = "use specific types (string, number, object) or union types instead";
    const namespace_message = "'import * as X' namespace imports are not supported; use named imports: import { x } from \"module\"";
    const type_diagnostic: LegacyCompoundDiagnostic = .{
        .code = "ZTS050",
        .message = "`type` is not a declaration form in this profile",
        .line = 1,
        .column = 1,
        .suggestion = "write `structural Name = ...;`",
    };
    const interface_diagnostic: LegacyCompoundDiagnostic = .{
        .code = "ZTS049",
        .message = "`interface` is not a declaration form in this profile",
        .line = 1,
        .column = 1,
        .suggestion = "write `structural Name = { ... };`",
    };
    const default_diagnostic: LegacyCompoundDiagnostic = .{
        .code = "ZTS054",
        .message = "default parameters are not part of this profile",
        .line = 1,
        .column = 14,
        .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body",
    };
    const nominal_diagnostic: LegacyCompoundDiagnostic = .{
        .code = "ZTS048",
        .message = "a nominal declaration carries scalar identity only",
        .line = 1,
        .column = 11,
        .suggestion = "its base must be `string`, `number`, or `boolean`",
    };
    const cases = [_]struct {
        source: []const u8,
        parser_stage: bool,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{
            .source = "while (true) { const x: any = 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS041", .message = any_message, .line = 1, .column = 25, .suggestion = any_suggestion }},
        },
        .{
            .source = "const x: /* closed */ any = 1;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 1, .column = 8 },
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 7 },
            },
        },
        .{
            .source = "function f(x: /* closed */ any) { return x; }\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "')'" }},
        },
        .{
            .source = "function f(): /* closed */ any { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "'{'" }},
        },
        .{
            .source = "const x = value as \"open\n; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 20, .suggestion = "use type-safe patterns instead" },
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 25, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = any_message, .line = 2, .column = 16, .suggestion = any_suggestion },
            },
        },
        .{
            .source = "import * as ns from \"./dep.ts\";\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS002", .message = namespace_message, .line = 1, .column = 1 }},
        },
        .{
            .source = "import * as ns from \"./dep.ts\";\nconst x = value as number;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 2, .column = 20, .suggestion = "use type-safe patterns instead" }},
        },
        .{
            .source = "import * as ns from \"./dep.ts\"\nconst x = value as number;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS002", .message = namespace_message, .line = 1, .column = 1 }},
        },
        .{
            .source = "function f(): number {\n  while (true) { const x: number = 1; }\n  return 1;\n}\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "'while' is not supported", .line = 2, .column = 3, .suggestion = "use 'for-of' with a finite collection instead" }},
        },
        .{
            .source = " export default 1;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "default exports are not supported", .line = 1, .column = 9, .suggestion = "write a named export, for example `export function handler(...) { ... }`" }},
        },
        .{
            .source = "export/*c*/let x = 1;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS001", .message = "mutable exports are not supported", .line = 1, .column = 12, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" }},
        },
        .{
            .source = "type Alias/* c */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "type Alias<T>/* c */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface Shape;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "interface Shape/*c*/;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "nominal Bad = T\n;type Alias = number;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" }},
        },
        .{
            .source = "type Alias /* open",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "type Alias<T> /* open",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface A {} ;type B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{interface_diagnostic},
        },
        .{
            .source = "type A = number\n;type B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{type_diagnostic},
        },
        .{
            .source = "interface A {} ;\ntype B = number;\n",
            .parser_stage = false,
            .diagnostics = &.{
                interface_diagnostic,
                .{ .code = "ZTS050", .message = "`type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = ...;`" },
            },
        },
        .{
            .source = "function f(x = function () {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{ default_diagnostic, .{ .code = "ZTS041", .message = any_message, .line = 1, .column = 35, .suggestion = any_suggestion } },
        },
        .{
            .source = "function f({ x }, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS041", .message = any_message, .line = 1, .column = 22, .suggestion = any_suggestion }},
        },
        .{
            .source = "function f(x = 1, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{ default_diagnostic, .{ .code = "ZTS041", .message = any_message, .line = 1, .column = 22, .suggestion = any_suggestion } },
        },
        .{
            .source = "nominal N /* gap */ = string;\n",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal N /* gap */ = any;\n",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal N<T> /* gap */ = string;\n",
            .parser_stage = false,
            .diagnostics = &.{.{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 1, .column = 14, .suggestion = "its base must be `string`, `number`, or `boolean`" }},
        },
        .{
            .source = "nominal N /* open",
            .parser_stage = false,
            .diagnostics = &.{nominal_diagnostic},
        },
        .{
            .source = "nominal /* gap */ N = string;\n",
            .parser_stage = true,
            .diagnostics = &.{.{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 1 }},
        },
        .{
            .source = "function f({ x } = {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: any = {}, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 23, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 32, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 42, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: Box<number, string>, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 43, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: \"open\n, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 24, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 6, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x = y => y, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x = a == b, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 19, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }?: number, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 17, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 31, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }) { return 1; } while (true) {} return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 43, .suggestion = "bind one parameter, then read its members explicitly in the body" },
                .{ .code = "ZTS001", .message = "'while' is not supported", .line = 1, .column = 64, .suggestion = "use 'for-of' with a finite collection instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }: /* gap */ number) { return 1; } while (true) {} return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 43, .suggestion = "bind one parameter, then read its members explicitly in the body" },
                .{ .code = "ZTS001", .message = "'while' is not supported", .line = 1, .column = 82, .suggestion = "use 'for-of' with a finite collection instead" },
            },
        },
        .{
            .source = "function outer(): number { function inner({ x }) { return 1; } const later: any = 1; return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 77, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 3, .column = 1, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f({ x }: /* closed */ any, y: void) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 40, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "function f({ x }:\n /* closed */ any,\n y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 4, .column = 1, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y = 1) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 37, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
            },
        },
        .{
            .source = "function f(x:\t/* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r /* closed */ any, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 39, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ any, y: /* closed */ any, z: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 61, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* closed */ number, y: number) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "')'" },
            },
        },
        .{
            .source = "const x:\n /* closed */ number = 1; const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\n /* closed */ number { return 1; } const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 45, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const x:\r any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 10, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\r any { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x?\r: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 13, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 16, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x:\r number, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 26, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const x:\r /* closed */ number = 1; const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 45, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f():\r /* closed */ number { return 1; } const y: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 58, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed =\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed = 1 ===\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 14, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 23, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function\r f(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f\r(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 15, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function\r (x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 24, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T>\r(x: any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 18, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 29, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = <T>\r(x: any) => x;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 18, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = <T>\r value; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = id<T>\r(1); const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 35, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural\r X = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X\r = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X<T>\r = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 40, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X =\r number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 37, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "structural X = number\n\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 16, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed =\r1; type\r X = any;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 17 },
            },
        },
        .{
            .source = "nominal N =\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 13, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "interface X extends\r any {};\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 21, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 1, .column = 1, .suggestion = "write `structural Name = { ... };`" },
            },
        },
        .{
            .source = "import\r type { X } from './x.ts'; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r type { X } from './x.ts'; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r structural X = number; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 44, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r default\r 1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 1, .column = 1, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 32, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "export\r let value: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS057", .message = "mutable exports are not part of this profile", .line = 1, .column = 1, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const seed = value as\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 23, .suggestion = "use type-safe patterns instead" },
            },
        },
        .{
            .source = "const seed = value satisfies\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS043", .message = "'satisfies' type assertion is not supported", .line = 1, .column = 30, .suggestion = "use type-safe patterns instead" },
            },
        },
        .{
            .source = "const seed: () =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(): () =>\r any { return value; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 21, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: () =>\r any) { return 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 22, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: (x: any) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 22, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: (x: void) =>\r number = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 14, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "const f: (x: void) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 23, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 1, .column = 14, .suggestion = "write `undefined`" },
            },
        },
        .{
            .source = "const f: (x: \"open\n) =>\r any = value;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 19, .suggestion = "close the quote, or write the newline as \\n" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 6, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f: () =>\r () =>\r any = value;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS002", .message = "const declarations must have an initializer", .line = 1, .column = 20 },
                .{ .code = "ZTS047", .message = "statement is not terminated; this profile has no automatic semicolon insertion", .line = 1, .column = 7 },
            },
        },
        .{
            .source = "interface X extends () =>\r any {};\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 28, .suggestion = "use specific types (string, number, object) or union types instead" },
                .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 1, .column = 1, .suggestion = "write `structural Name = { ... };`" },
            },
        },
        .{
            .source = "const f = value as () =>\r any;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 1, .column = 20, .suggestion = "use type-safe patterns instead" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 27, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function/* gap */f<T>(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 25, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function/* gap */f<T>(x?\r: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 24, .suggestion = "')'" },
            },
        },
        .{
            .source = "function/* gap */f(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 22, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function f<T>/* gap */(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 26, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function/* gap */f<T>({x}: /* gap */ number, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "destructured parameters are not supported", .line = 1, .column = 23, .suggestion = "bind one parameter, then read its members explicitly in the body" },
            },
        },
        .{
            .source = "function/* gap */f(x: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 21, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 22, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x?: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 22, .suggestion = "')'" },
            },
        },
        .{
            .source = "function f/* gap */(x =\r 1, y: any) { return 1; }\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "default parameters are not supported", .line = 1, .column = 23, .suggestion = "accept `T | undefined` and resolve the default at the start of the body" },
            },
        },
        .{
            .source = "function f<T = string>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T = string>\r; const seed =\r1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 53, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: number) { const seed =\r1; const later: any = 1; }\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 53, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f(x: /* gap */ number) {} const seed =\r1; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 66, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function(x: number) { return 1; };\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "function expressions are not supported", .line = 1, .column = 11, .suggestion = "use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead" },
            },
        },
        .{
            .source = "const f = function(x?: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 1, .column = 21, .suggestion = "replace `name?: T` with `name: T | undefined`" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 24, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function(x = 1, y: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 1, .column = 22, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 30, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function<T>\r(x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 26, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function g<T>\r(x: any) { return 1; };\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 28, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "const f = function/* gap */(x: any) { return 1; };\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS001", .message = "function expressions are not supported", .line = 1, .column = 11, .suggestion = "use arrow functions '(x) => x * 2' or function declarations 'function name() { }' instead" },
            },
        },
        .{
            .source = "function f<T as number>\r; const later: any = 1;\n",
            .parser_stage = false,
            .diagnostics = &.{
                .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 39, .suggestion = "use specific types (string, number, object) or union types instead" },
            },
        },
        .{
            .source = "function f<T = string>\r;\n",
            .parser_stage = true,
            .diagnostics = &.{
                .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 24, .suggestion = "'('" },
            },
        },
        .{
            .source = "function f<T> /* unfinished\n",
            .parser_stage = false,
            .diagnostics = &.{},
        },
        .{ .source = "import\r { value } from './x.ts'; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 47, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "export type\r { X }; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 34, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "import\r type { X } from \"open\nconst later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 1, .column = 29, .suggestion = "close the quote, or write the newline as \\n" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const seed =\r1;import\r type { X } from 'zttp:types';\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 15, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import\r type `${\"open\n}` from 'zttp:types';\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 1, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "const seed =\r1;export\r default\r 1; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 1, .column = 15, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 46, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "export\r const seed = 1; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 38, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r(1); const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 36, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r{ ok: 1 }; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 42, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "<T>\r{ const later: any = 1; }\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 19, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r(1 + ); const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 39, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r/* gap */(1); const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 46, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "const value = <T>\r extends Missing; const later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 1, .column = 49, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
    };
    try std.testing.expectEqual(@as(usize, 129), cases.len);
    for (cases) |case| {
        errdefer std.debug.print("CHECK recovery context failed: {s}\n", .{case.source});
        var result = try runCheckOnlyFromSourceWithOptions(allocator, case.source, "handler.ts", .{
            .json_mode = true,
        });
        defer result.deinit(allocator);
        const stages = if (case.parser_stage)
            StageSet.initMany(&.{ .strip, .parse })
        else
            StageSet.initMany(&.{.strip});
        try std.testing.expectEqual(stages, result.stages_run);
        const expected_errors: u32 = @intCast(@max(1, case.diagnostics.len));
        try std.testing.expectEqual(expected_errors, result.parse_errors);
        try std.testing.expectEqual(expected_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        try std.testing.expect(result.is_typescript);
        try std.testing.expect(!result.verify_ran);
        try std.testing.expect(result.contract == null);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
    }
}

test "CHECK preserves absent structural aliases at comment boundaries" {
    const cases = [_]struct {
        source: []const u8,
        diagnostics: []const LegacyCompoundDiagnostic,
    }{
        .{ .source = "structural X/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .diagnostics = &.{} },
        .{ .source = "structural X/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { const x: X = 1; return Response.text(\"ok\"); }\n", .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'X'", .line = 2, .column = 59 },
        } },
        .{ .source = "structural X<T>/* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { const x: X<number> = 1; return Response.text(\"ok\"); }\n", .diagnostics = &.{
            .{ .code = "ZTS200", .message = "type '1' is not assignable to type 'X<number>'", .line = 2, .column = 59 },
        } },
        .{ .source = "structural X\r /* c */\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .diagnostics = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u32, 0), result.parse_errors);
        try std.testing.expect(result.stages_run.contains(.types));
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.type_errors);
        try std.testing.expectEqual(result.type_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| {
            try expectLegacyCompoundDiagnostic(actual, expected);
        }
        try std.testing.expectEqual(case.diagnostics.len == 0, result.contract != null);
    }
}

test "CHECK preserves raw module recovery and the complete nested parser batch" {
    const cases = [_]struct { source: []const u8, parser_stage: bool, diagnostics: []const LegacyCompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst later = \"open\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 20, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst later: any = 1;\n", .parser_stage = false, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live: \"const\" = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
        .{ .source = "function f() {\nimport type { A } /* ; */ from \"./a\";\nconst live: \"return\" = 1;\n}\n", .parser_stage = true, .diagnostics = &.{
            .{ .code = "ZTS002", .message = "expected expression", .line = 2, .column = 24, .suggestion = null },
            .{ .code = "ZTS003", .message = "unexpected token", .line = 5, .column = 1, .suggestion = "'}'" },
        } },
    };
    try std.testing.expectEqual(@as(usize, 6), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (case.parser_stage) StageSet.initMany(&.{ .strip, .parse }) else StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, @intCast(case.diagnostics.len)), result.parse_errors);
        try std.testing.expectEqual(result.parse_errors, result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| try expectLegacyCompoundDiagnostic(actual, expected);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK preserves spaced function call-list selection and strict refusal" {
    const cases = [_]struct { source: []const u8, strict: bool, diagnostic: LegacyCompoundDiagnostic }{
        .{ .source = "function id <T>(x) { return x; }\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .strict = true, .diagnostic = .{ .code = "ZTS601", .message = "strict ZigTS requires explicit function parameter and return types", .line = 1, .column = 16, .suggestion = "annotate each parameter and the return type, for example `function handler(req: Request): Response`" } },
        .{ .source = "function id <T> (x) { return x; }\nfunction handler(req: Request): Proof<Response, \"pure\"> { return Response.text(\"ok\"); }\n", .strict = false, .diagnostic = .{ .code = "ZTS003", .message = "unexpected token", .line = 1, .column = 13, .suggestion = "'('" } },
    };
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        const stages = if (case.strict) StageSet.initMany(&.{ .strip, .parse, .imports, .boolean, .types, .strict }) else StageSet.initMany(&.{ .strip, .parse });
        try std.testing.expectEqual(stages, result.stages_run);
        try std.testing.expectEqual(@as(u32, if (case.strict) 0 else 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, if (case.strict) 1 else 0), result.strict_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expect(result.contract == null);
    }
}

test "CHECK observes every admission kind after the measured recovery divergence" {
    const Kind = zts.parser.type_syntax.AdmissionKind;
    const cases = [_]struct { source: []const u8, kind: ?Kind, diagnostics: []const LegacyCompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value: any = 1;\n", .kind = .any_type, .diagnostics = &.{
            .{ .code = "ZTS041", .message = "'any' type is not supported", .line = 2, .column = 14, .suggestion = "use specific types (string, number, object) or union types instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = source as string;\n", .kind = .as_assertion, .diagnostics = &.{
            .{ .code = "ZTS042", .message = "'as' type assertion is not supported", .line = 2, .column = 25, .suggestion = "use type-safe patterns instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = source satisfies string;\n", .kind = .satisfies_assertion, .diagnostics = &.{
            .{ .code = "ZTS043", .message = "'satisfies' type assertion is not supported", .line = 2, .column = 32, .suggestion = "use type-safe patterns instead" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value = \"open\nconst after = 1;\n", .kind = .unterminated_string, .diagnostics = &.{
            .{ .code = "ZTS008", .message = "unterminated string literal", .line = 2, .column = 20, .suggestion = "close the quote, or write the newline as \\n" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nnominal Box = T;\n", .kind = .nominal_base_not_scalar, .diagnostics = &.{
            .{ .code = "ZTS048", .message = "a nominal declaration carries scalar identity only", .line = 2, .column = 15, .suggestion = "its base must be `string`, `number`, or `boolean`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ninterface Box { value: string }\n", .kind = .interface_declaration, .diagnostics = &.{
            .{ .code = "ZTS049", .message = "`interface` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = { ... };`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ntype Box = string;\n", .kind = .type_alias_declaration, .diagnostics = &.{
            .{ .code = "ZTS050", .message = "`type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `structural Name = ...;`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\ndistinct type Box = string;\n", .kind = .distinct_type_declaration, .diagnostics = &.{
            .{ .code = "ZTS051", .message = "`distinct type` is not a declaration form in this profile", .line = 2, .column = 1, .suggestion = "write `nominal Name = string;`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nimport type { Value } from 'zttp:types';\n", .kind = .legacy_types_import, .diagnostics = &.{
            .{ .code = "ZTS053", .message = "`zttp:types` is not a module in this profile", .line = 2, .column = 1, .suggestion = "remove this import because `Proof<T, P>` and `Effects<T, R>` are ambient type names" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value = 1) { return value; }\n", .kind = .default_parameter, .diagnostics = &.{
            .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 18, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(value?: string) { return value; }\n", .kind = .optional_parameter, .diagnostics = &.{
            .{ .code = "ZTS055", .message = "optional parameter shorthand is not part of this profile", .line = 2, .column = 17, .suggestion = "replace `name?: T` with `name: T | undefined`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nexport default 1;\n", .kind = .default_export, .diagnostics = &.{
            .{ .code = "ZTS056", .message = "default exports are not part of this profile", .line = 2, .column = 1, .suggestion = "write a named export, for example `export function handler(...) { ... }`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nexport let value = 1;\n", .kind = .mutable_export, .diagnostics = &.{
            .{ .code = "ZTS057", .message = "mutable exports are not part of this profile", .line = 2, .column = 1, .suggestion = "use `export const` for module values and keep reassignment inside a function activation" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = Array<string>;\n", .kind = .array_type_alias, .diagnostics = &.{
            .{ .code = "ZTS058", .message = "`Array<T>` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `T[]`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = ReadonlyArray<string>;\n", .kind = .readonly_array_type_alias, .diagnostics = &.{
            .{ .code = "ZTS059", .message = "`ReadonlyArray<T>` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `readonly T[]`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nstructural Box = void;\n", .kind = .void_type, .diagnostics = &.{
            .{ .code = "ZTS060", .message = "`void` is not a type spelling in this profile", .line = 2, .column = 18, .suggestion = "write `undefined`" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nconst value: {{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{ string;\n", .kind = .nesting_too_deep, .diagnostics = &.{
            .{ .code = "ZTS044", .message = "type syntax nests too deeply", .line = 2, .column = 526, .suggestion = "simplify or split it (nesting limit is 512)" },
        } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\n/* unfinished\n", .kind = null, .diagnostics = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 18), cases.len);
    try std.testing.expectEqual(std.meta.fields(Kind).len + 1, cases.len);
    var seen = std.EnumSet(Kind).initEmpty();
    var location_free: usize = 0;
    for (cases) |case| {
        errdefer std.debug.print("recovery producer failed: {any}\n", .{case.kind});
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(case.diagnostics.len, result.json_diagnostics.items.len);
        for (result.json_diagnostics.items, case.diagnostics) |actual, expected| try expectLegacyCompoundDiagnostic(actual, expected);
        try std.testing.expect(result.contract == null);
        if (case.kind) |kind| {
            try std.testing.expect(!seen.contains(kind));
            try std.testing.expectEqual(@as(usize, 1), case.diagnostics.len);
            seen.insert(kind);
        } else {
            try std.testing.expectEqual(@as(usize, 0), case.diagnostics.len);
            location_free += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), location_free);
    inline for (std.meta.tags(Kind)) |kind| try std.testing.expect(seen.contains(kind));
}

test "CHECK preserves raw recovery header comments" {
    const cases = [_]struct { source: []const u8, parser_stage: bool, diagnostic: LegacyCompoundDiagnostic }{
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* x = 1 */) { return 1; }\n", .parser_stage = false, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 17, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* ) */) { return 1; }\n", .parser_stage = true, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(/* unfinished\n", .parser_stage = true, .diagnostic = .{ .code = "ZTS002", .message = "expected expression", .line = 1, .column = 24, .suggestion = null } },
        .{ .source = "import type { A } /* ; */ from \"./a\";\nfunction f(x: number, /* x = 1 */) { return 1; }\n", .parser_stage = false, .diagnostic = .{ .code = "ZTS054", .message = "default parameters are not part of this profile", .line = 2, .column = 28, .suggestion = "replace `name: T = value` with `name: T | undefined`, then resolve `const resolved = name ?? value;` at the start of the body" } },
    };
    try std.testing.expectEqual(@as(usize, 4), cases.len);
    for (cases) |case| {
        var result = try runCheckOnlyFromSourceWithOptions(std.testing.allocator, case.source, "handler.ts", .{ .json_mode = true });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (case.parser_stage) StageSet.initMany(&.{ .strip, .parse }) else StageSet.initMany(&.{.strip}), result.stages_run);
        try std.testing.expectEqual(@as(u32, 1), result.parse_errors);
        try std.testing.expectEqual(@as(u32, 1), result.totalErrors());
        try std.testing.expectEqual(@as(usize, 1), result.json_diagnostics.items.len);
        try expectLegacyCompoundDiagnostic(result.json_diagnostics.items[0], case.diagnostic);
        try std.testing.expect(result.contract == null);
    }
}
