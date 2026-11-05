//! The graph checks of `zts check` for a handler with file imports.
//!
//! `zts compile` checks every module of such a handler. A check that reads the
//! entry alone would pass a handler whose dependency the build refuses. A
//! `GraphCheck` loads the module graph, compiles it, and runs `checkGraphModule`
//! on each dependency with a sink, so that a check reports each refusal that the
//! build makes, with the file at fault. The entry then runs the stages of
//! `runCheckOnParsedSource` on the parser of the graph, with typed file imports.
//!
//! A `GraphCheck` lives on the heap. The analysis of the entry borrows its atom
//! table, parser, and export signatures, so none of them may move.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const ir = zts.parser;
const handler_contract = zts.handler_contract;
const HandlerContract = handler_contract.HandlerContract;
const diagnostic_catalog = zts.DiagnosticCatalog;
const precompile = @import("precompile.zig");
const json_diag = @import("json_diagnostics.zig");
const check_mod = @import("precompile_check.zig");
const CheckResult = check_mod.CheckResult;
const imports_mod = @import("precompile_imports.zig");
const ImportReader = imports_mod.ImportReader;
const FlowModuleGraph = imports_mod.FlowModuleGraph;
const contract_mod = @import("precompile_contract.zig");
const check_run_mod = @import("precompile_check_run.zig");
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;

const SourceReader = zts.modules.module_graph.SourceReader;
const ReadFileError = zts.modules.module_graph.ReadFileError;

/// Carries an `ImportReader` into the reader of the module graph. The graph
/// reads through it, so a base revision selected by a caller reaches the graph.
const ReaderAdapter = struct {
    inner: ImportReader,

    /// Any failure that is not an allocation failure is a missing file, which is
    /// the answer `ImportReader` documents for an unreadable one.
    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ReadFileError![]const u8 {
        const self: *ReaderAdapter = @ptrCast(@alignCast(context));
        return self.inner.read(self.inner.context, allocator, path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.FileNotFound,
        };
    }
};

/// What the caller of `GraphCheck.run` supplies.
pub const RunOptions = struct {
    handler_path: []const u8,
    source: []const u8,
    import_reader: ?ImportReader,
    skip_contract: bool,
    json_mode: bool,
    policy: ?zts.HandlerPolicy,
    sql_schema_path: ?[]const u8,
};

pub const Outcome = enum {
    /// Every module passed its checks. The entry has no finding yet.
    passed,
    /// The graph or a dependency was refused. The result holds the findings.
    refused,
};

/// Whether `GraphCheck.mergeInto` produced the merged contract.
pub const MergeOutcome = enum { merged, refused };

pub const GraphCheck = struct {
    allocator: std.mem.Allocator,
    strings: zts.StringTable,
    atoms: zts.AtomTable,
    graph: zts.modules.ModuleGraph,
    compile_result: ?zts.modules.CompileResult = null,
    exports: zts.ExportedSignatures,
    evidences: std.ArrayList(zts.ProofEvidence) = .empty,
    /// Owns the rows and strings of the file import signatures of the entry.
    link_arena: std.heap.ArenaAllocator,
    entry_imports: ?zts.FileImportSignatures = null,
    /// A module of the dependencies mutates module state or dispatches an
    /// unresolved route.
    shares_state: bool = false,
    deps: ?contract_mod.DependencyContracts = null,
    dependency_facts: ?contract_mod.DependencyFacts = null,
    reader_adapter: ReaderAdapter = undefined,

    pub fn create(allocator: std.mem.Allocator) !*GraphCheck {
        const self = try allocator.create(GraphCheck);
        self.* = .{
            .allocator = allocator,
            .strings = zts.StringTable.init(allocator),
            .atoms = zts.AtomTable.init(allocator),
            .graph = zts.modules.ModuleGraph.init(allocator),
            .exports = zts.ExportedSignatures.init(allocator),
            .link_arena = std.heap.ArenaAllocator.init(allocator),
        };
        return self;
    }

    pub fn destroy(self: *GraphCheck) void {
        const allocator = self.allocator;
        if (self.deps) |*deps| deps.deinit(allocator);
        for (self.evidences.items) |*evidence| evidence.deinit();
        self.evidences.deinit(allocator);
        if (self.compile_result) |*compile_result| {
            for (compile_result.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
            compile_result.deinit();
        }
        self.exports.deinit();
        self.graph.deinit();
        self.atoms.deinit();
        self.strings.deinit();
        self.link_arena.deinit();
        allocator.destroy(self);
    }

    /// Load the graph, refuse what the build refuses before it compiles, compile
    /// the modules, and check each dependency. Findings go to `result`.
    pub fn run(self: *GraphCheck, result: *CheckResult, opts: RunOptions) !Outcome {
        const allocator = self.allocator;
        const reader: SourceReader = if (opts.import_reader) |import_reader| blk: {
            self.reader_adapter = .{ .inner = import_reader };
            break :blk .{ .contextual = .{ .context = &self.reader_adapter, .read = ReaderAdapter.read } };
        } else .{ .plain = zts.file_io.readFileForModuleGraph };

        self.graph.buildWithReader(opts.handler_path, opts.source, reader) catch |err| {
            if (err == error.OutOfMemory) return err;
            try self.appendImportRefusal(result, opts, reader);
            return .refused;
        };

        self.graph.checkBindings() catch |err| {
            if (err == error.OutOfMemory) return err;
            var buffer: [1024]u8 = undefined;
            const message = self.graph.bindingRefusalMessage(&buffer);
            const file = if (self.graph.binding_refusal) |refusal| refusal.first_path else opts.handler_path;
            try appendLinkRefusal(allocator, result, opts.json_mode, .module_link_refused, file, message);
            return .refused;
        };

        // The front end refuses a dependency before the compiler parses it, so
        // the finding carries the parser or admission code and not a bare error.
        const dependency_count = self.graph.dependencyCount();
        for (self.graph.execution_order[0..dependency_count]) |graph_index| {
            const module = &self.graph.module_list.items[graph_index];
            if (try appendDependencyRefusals(allocator, result, module.source, module.path, opts.json_mode)) return .refused;
        }

        var module_compiler = zts.modules.ModuleCompiler.init(allocator, &self.atoms, &self.strings);
        module_compiler.record_witnesses = !opts.skip_contract;
        self.compile_result = try module_compiler.compileAll(&self.graph);
        const compile_result = &self.compile_result.?;

        var sink: precompile.GraphSink = .{
            .allocator = allocator,
            .diagnostics = &result.json_diagnostics,
            .json_mode = opts.json_mode,
        };
        defer applySink(result, &sink);
        const compile_opts: precompile.CompileOptions = .{
            .emit_verify = !opts.skip_contract,
            .strict = true,
            .policy = opts.policy,
            .manifest_registry = null,
            .emit_proof_evidence = !opts.skip_contract,
        };
        for (0..dependency_count) |position| {
            const errors_before = sink.errorTotal();
            var checks = precompile.checkGraphModule(
                allocator,
                &self.graph,
                compile_result,
                position,
                &self.atoms,
                &self.exports,
                compile_opts,
                &sink,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                // An error that the sink counted already has its diagnostic.
                if (sink.errorTotal() > errors_before) return .refused;
                return err;
            };
            if (checks.evidence) |*evidence| {
                self.evidences.append(allocator, evidence.*) catch |err| {
                    evidence.deinit();
                    return err;
                };
            }
            if (checks.verify_failed) return .refused;
            if (checks.has_module_mutation or checks.unresolved_route_dispatch) self.shares_state = true;
        }
        return .passed;
    }

    fn applySink(result: *CheckResult, sink: *const precompile.GraphSink) void {
        result.bool_errors += sink.bool_errors;
        result.bool_warnings += sink.bool_warnings;
        result.type_errors += sink.type_errors;
        result.strict_errors += sink.strict_errors;
        result.strict_warnings += sink.strict_warnings;
        result.strict_advisories += sink.strict_advisories;
        result.verify_errors += sink.verify_errors;
        result.verify_warnings += sink.verify_warnings;
        result.link_errors += sink.link_errors;
    }

    /// Append the finding for a graph that failed to build.
    fn appendImportRefusal(self: *GraphCheck, result: *CheckResult, opts: RunOptions, reader: SourceReader) !void {
        const allocator = self.allocator;
        if (self.graph.import_refusal) |refusal| {
            // The graph keeps no source for a dependency that admission refused.
            // The front end reads it again and reports the coded cause.
            if (refusal.kind == .not_admitted and zts.classifySourcePath(refusal.module_path) == .typescript) {
                if (reader.read(allocator, refusal.module_path)) |dependency_source| {
                    defer allocator.free(dependency_source);
                    if (try appendDependencyRefusals(allocator, result, dependency_source, refusal.module_path, opts.json_mode)) return;
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                }
            }
        }
        var buffer: [1024]u8 = undefined;
        const message = self.graph.importRefusalMessage(&buffer);
        const file = if (self.graph.import_refusal) |refusal| refusal.module_path else opts.handler_path;
        try appendLinkRefusal(
            allocator,
            result,
            opts.json_mode,
            .module_link_refused,
            file,
            if (message.len > 0) message else "Module imports are refused.",
        );
    }

    pub fn entryIndex(self: *const GraphCheck) usize {
        return self.compile_result.?.modules.len - 1;
    }

    pub fn entryParser(self: *GraphCheck) *zts.parser.JsParser {
        return &self.compile_result.?.parsers[self.entryIndex()];
    }

    pub fn entryRoot(self: *const GraphCheck) ir.NodeIndex {
        return self.compile_result.?.modules[self.entryIndex()].root;
    }

    fn entryModule(self: *const GraphCheck) *const zts.modules.module_graph.Module {
        return &self.graph.module_list.items[self.graph.execution_order[self.entryIndex()]];
    }

    /// The signature table of the file imports of the entry: what each checked
    /// dependency exports under the imported name. It lives as long as `self`.
    pub fn entryFileImports(self: *GraphCheck, view: zts.IrView) !*const zts.FileImportSignatures {
        self.entry_imports = try contract_mod.fileImportSignatures(
            self.link_arena.allocator(),
            &self.graph,
            self.entryModule().path,
            view,
            &self.atoms,
            &self.exports,
        );
        return &self.entry_imports.?;
    }

    /// The flow modules of the graph, each once, over the parsers that code
    /// generation kept.
    pub fn flowModules(self: *GraphCheck) !FlowModuleGraph {
        return imports_mod.flowModulesForGraph(self.allocator, &self.graph, &self.compile_result.?, &self.atoms);
    }

    /// Verify the bytecode of the entry, build its proof evidence, and fold the
    /// evidence of every module into one program. A graph that the fold cannot
    /// classify yields a ZTS063 finding. The folded evidence is not kept: a
    /// check emits no certificate.
    pub fn foldEntryEvidence(
        self: *GraphCheck,
        result: *CheckResult,
        json_mode: bool,
        view: zts.IrView,
        strict_checker: ?*const zts.StrictChecker,
    ) !Outcome {
        const allocator = self.allocator;
        const entry_position = self.entryIndex();
        const compile_result = &self.compile_result.?;
        const entry_path = self.entryModule().path;
        try precompile.verifyModuleBytecode(entry_path, &compile_result.modules[entry_position].func);
        var entry_evidence = try precompile.moduleProofEvidence(
            allocator,
            view,
            compile_result.modules[entry_position].root,
            &compile_result.recorders[entry_position],
            strict_checker,
            &self.atoms,
            entry_path,
            true,
        );
        defer entry_evidence.deinit();
        var folded = zts.foldProofEvidence(allocator, &entry_evidence, self.evidences.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |fold_error| {
                var buffer: [256]u8 = undefined;
                try appendLinkRefusal(
                    allocator,
                    result,
                    json_mode,
                    .module_link_refused,
                    entry_path,
                    precompile.foldRefusalMessage(&buffer, fold_error),
                );
                return .refused;
            },
        };
        folded.deinit();
        return .passed;
    }

    /// Extract the contract of each dependency, and keep them for the merge.
    pub fn collectDependencies(self: *GraphCheck, opts: RunOptions) !void {
        self.deps = try contract_mod.collectDependencyContracts(
            self.allocator,
            &self.graph,
            &self.compile_result.?,
            &self.atoms,
            .{
                .filename = opts.handler_path,
                .emit_contract = false,
                .emit_verify = !opts.skip_contract,
                .strict = true,
                .policy = opts.policy,
                .sql_schema_path = opts.sql_schema_path,
                .manifest_registry = null,
                .shares_state = self.shares_state,
                // A check reports a policy violation on the merged contract. It
                // does not stop at the first dependency.
                .enforce_policy = false,
            },
        );
    }

    /// The effects that the entry imports from its dependencies. The caller
    /// frees the slice.
    pub fn entryImportedEffects(self: *GraphCheck, facts: *const zts.pipeline.ModuleFacts) ![]const zts.pipeline.ImportedEffect {
        const deps = &(self.deps orelse return error.AnalysisPassIncomplete);
        return zts.pipeline.importedEffectsForLoadedModule(
            self.allocator,
            &self.graph,
            self.graph.execution_order[self.entryIndex()],
            facts,
            deps.loaded_effects.items,
        );
    }

    /// Union the contracts of the dependencies into the contract of the entry.
    /// An API schema conflict yields a ZTS063 finding.
    pub fn mergeInto(
        self: *GraphCheck,
        result: *CheckResult,
        json_mode: bool,
        contract: *HandlerContract,
        env_public: []const []const u8,
        filename: []const u8,
    ) !MergeOutcome {
        const deps = &(self.deps orelse return error.AnalysisPassIncomplete);
        var refusal: contract_mod.MergeRefusal = .{};
        self.dependency_facts = contract_mod.mergeDependencyContracts(
            self.allocator,
            contract,
            deps,
            env_public,
            filename,
            &refusal,
        ) catch |err| switch (err) {
            error.ApiSchemaConflict => {
                try appendLinkRefusal(self.allocator, result, json_mode, .module_link_refused, refusal.path, refusal.message());
                return .refused;
            },
            else => return err,
        };
        return .merged;
    }

    /// Hold each structural property only when the dependencies hold it too.
    /// This runs after the path facts, which overwrite the cost facts.
    pub fn foldProperties(self: *const GraphCheck, contract: *HandlerContract) void {
        const facts = self.dependency_facts orelse return;
        contract_mod.foldDependencyProperties(self.allocator, contract, facts.properties, facts.established);
    }
};

/// Append a coded ZTS063 or ZTS064 finding for the module at `path`, and count it.
pub fn appendLinkRefusal(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    json_mode: bool,
    kind: diagnostic_catalog.DriverKind,
    path: []const u8,
    message: []const u8,
) !void {
    var sink: precompile.GraphSink = .{
        .allocator = allocator,
        .diagnostics = &result.json_diagnostics,
        .json_mode = json_mode,
    };
    try sink.appendLink(kind, path, message);
    result.link_errors += sink.link_errors;
}

/// Report why the front end refuses the source of a dependency, under the path
/// of that dependency. Returns true when it refuses the source.
fn appendDependencyRefusals(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    source: []const u8,
    path: []const u8,
    json_mode: bool,
) !bool {
    var source_owner: zts.DirectCheckSource = undefined;
    source_owner.initInPlace(allocator, allocator, source, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    defer source_owner.deinit();
    const start = result.json_diagnostics.items.len;
    if (!try check_run_mod.appendSourceRefusals(allocator, result, &source_owner, source, path, json_mode)) return false;
    // A parser finding keeps the coordinates of the parser. Read them against
    // the source of this dependency.
    switch (source_owner.outcome().*) {
        .parser_refused => check_run_mod.remapDiagnosticsToSource(result, .{ .text = source, .normalize_positions = true }, start),
        else => {},
    }
    // The path belongs to the graph, which the result outlives.
    for (result.json_diagnostics.items[start..]) |*diagnostic| {
        if (diagnostic.file_owned) continue;
        diagnostic.file = try allocator.dupe(u8, path);
        diagnostic.file_owned = true;
    }
    return true;
}
