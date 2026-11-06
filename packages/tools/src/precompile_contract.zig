//! Contract and policy building for a parsed handler or a multi-module bundle.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;
const ir = zts.parser;
const handler_contract = zts.handler_contract;
const HandlerContract = zts.HandlerContract;
const VerificationInfo = handler_contract.VerificationInfo;
const handler_policy = zts.handler_policy;
const HandlerPolicy = zts.HandlerPolicy;
const check_mod = @import("precompile_check.zig");
const CheckResult = check_mod.CheckResult;
const findHandlerFunction = zts.findHandlerFunction;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;
const sql_mod = @import("precompile_sql.zig");
const validateSqlContract = sql_mod.validateSqlContract;
const imports_mod = @import("precompile_imports.zig");
const check_run_mod = @import("precompile_check_run.zig");
const refreshContractSpecDiagnostics = check_mod.refreshContractSpecDiagnostics;
const applyContractFacts = check_run_mod.applyContractFacts;

const AotAnalysis = struct {
    dispatch: ?*zts.PatternDispatchTable = null,
    default_response: ?zts.HandlerAnalyzer.StaticResponseInfo = null,

    pub fn deinit(self: *AotAnalysis, allocator: std.mem.Allocator) void {
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

pub fn analyzeAot(
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
            // exhaustive: .dynamic routes are not ahead-of-time patterns; this count only reports them.
            else => {},
        }
    }
    return count;
}

const ContractExtractionOptions = struct {
    aot: ?AotAnalysis = null,
    verification: ?VerificationInfo = null,
    imported_effects: []const zts.pipeline.ImportedEffect = &.{},
};

pub fn extractContractFromAnalysis(
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

/// Print the completed flow pass diagnostics and collect its violations. The contract already
/// carries the flow results: `ModuleAnalysisSession.extractContract` applied them.
pub fn reportCompletedFlow(
    allocator: std.mem.Allocator,
    completed: *const zts.FlowChecker,
    flow_errors: u32,
    fresh: bool,
    violations_out: ?*std.ArrayList(zts.property_diagnostics.PropertyViolation),
    ir_view: zts.IrView,
) !void {
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

    if (violations_out) |vout| {
        zts.property_diagnostics.collectFlowViolations(allocator, vout, flow_diags, ir_view);
    }
    if (fresh and !builtin.is_test and flow_errors == 0) debugPrint("Flow analysis passed\n", .{});
}

/// Disclose the policy's `env.public` names in the contract `env` object, so a
/// reader of the contract can see which names the `no_secret_leakage` verdict
/// took as non-secret (D-014). Replaces what the contract held; an empty list
/// leaves `env.public` empty and the writer omits it.
pub fn disclosePublicEnv(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    env_public: []const []const u8,
) !void {
    for (contract.env.public.items) |name| allocator.free(name);
    contract.env.public.clearRetainingCapacity();
    try contract.env.public.ensureTotalCapacity(allocator, env_public.len);
    for (env_public) |name| {
        const owned = try allocator.dupe(u8, name);
        contract.env.public.appendAssumeCapacity(owned);
    }
}

pub fn validateContractPolicyInputs(
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

/// What `buildMultiModuleContract` reads besides the loaded graph.
pub const MultiModuleBuild = struct {
    filename: []const u8,
    emit_contract: bool,
    emit_verify: bool,
    strict: bool,
    policy: ?HandlerPolicy,
    sql_schema_path: ?[]const u8,
    manifest_registry: ?*const zts.ManifestRegistry,
    /// True when a module of the graph mutates module state or dispatches an
    /// unresolved route. Read only when `emit_verify` is set.
    shares_state: bool,
    /// Each ZTS310 finding that the verifier made in a dependency module, by
    /// flow module id, so a flow finding at the same node is not reported twice.
    reported_writes: []const check_run_mod.WriteSite = &.{},
    /// Abort on a policy violation in a dependency. A check clears this, because
    /// it reports a violation on the merged contract and does not abort.
    enforce_policy: bool = true,
};

/// The file-import signature table of one module: for each file import, the
/// signature or value type that the checked target module exports under the
/// imported name, or none. Rows and strings live in `arena`.
pub fn fileImportSignatures(
    arena: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    module_path: []const u8,
    view: zts.IrView,
    atoms: *zts.AtomTable,
    exports: *const zts.ExportedSignatures,
) !zts.FileImportSignatures {
    const links = try graph.fileImportLinks(arena, module_path, view, atoms);
    const rows = try arena.alloc(zts.FileImportSignatures.Row, links.len);
    for (links, rows) |link, *row| {
        row.* = .{ .specifier = link.specifier, .imported = link.imported, .sig = null, .value_type = zts.null_type_idx };
        const target = link.target orelse continue;
        const exported = exports.find(target, link.imported) orelse continue;
        row.sig = exported.sig;
        row.value_type = exported.value_type;
    }
    return .{ .source = &exports.pool, .rows = rows };
}

pub const DependencyContract = struct {
    path: []const u8,
    contract: HandlerContract,
    /// The dependency imports a file export whose effect the graph could not resolve.
    blocked_import: bool,
};

/// The contracts of the dependency modules of a graph, in load order, with the
/// export effects that each one loaded.
pub const DependencyContracts = struct {
    loaded_effects: std.ArrayList(zts.pipeline.LoadedModuleEffects) = .empty,
    dependencies: std.ArrayList(DependencyContract) = .empty,
    /// A configured policy checked at least one dependency contract.
    policy_checked: bool = false,

    pub fn deinit(self: *DependencyContracts, allocator: std.mem.Allocator) void {
        for (self.loaded_effects.items) |*loaded| loaded.deinit(allocator);
        self.loaded_effects.deinit(allocator);
        for (self.dependencies.items) |*dependency| dependency.contract.deinit(allocator);
        self.dependencies.deinit(allocator);
    }
};

/// Extract the contract of each dependency module, in load order. The entry is
/// the last module of the compile result and stays out. A policy violation
/// aborts only when `inputs.enforce_policy` is set.
pub fn collectDependencyContracts(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    atoms: *zts.AtomTable,
    inputs: MultiModuleBuild,
) !DependencyContracts {
    const entry_index = compile_result.modules.len - 1;
    var result: DependencyContracts = .{};
    errdefer result.deinit(allocator);

    for (compile_result.modules[0..entry_index], compile_result.parsers[0..entry_index], 0..) |compiled_module, *js_parser, idx| {
        const graph_idx = graph.execution_order[idx];
        const module = &graph.module_list.items[graph_idx];

        const module_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        var parsed = zts.pipeline.ParsedModule.fromExisting(module_view, compiled_module.root, atoms);
        parsed.scopes = &js_parser.scopes;
        var module_analysis: zts.pipeline.ModuleAnalysisSession = .{};
        try module_analysis.initContractOnly(
            allocator,
            parsed,
            .{ .extraction = .{
                .manifest_registry = inputs.manifest_registry,
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
            result.loaded_effects.items,
        );
        defer allocator.free(imported_effects);
        try module_analysis.setImportedEffects(imported_effects);

        var module_contract = try module_analysis.extractContract(module.path);
        errdefer module_contract.deinit(allocator);
        var pending_export_effects = module_analysis.takeExportEffects();
        errdefer if (pending_export_effects) |*effects| effects.deinit(allocator);
        try result.loaded_effects.append(allocator, .{
            .graph_index = graph_idx,
            .effects = pending_export_effects orelse return error.AnalysisPassIncomplete,
        });
        pending_export_effects = null;

        try validateSqlContract(allocator, &module_contract, inputs.sql_schema_path);
        if (inputs.enforce_policy) {
            try enforcePolicyForContract(allocator, module.path, &module_contract, inputs.policy);
            if (inputs.policy != null) result.policy_checked = true;
        }

        var blocked_import = false;
        for (imported_effects) |imported| {
            switch (imported.effect) {
                .blocked => blocked_import = true,
                .callable, .data => {},
            }
        }
        try result.dependencies.append(allocator, .{ .path = module.path, .contract = module_contract, .blocked_import = blocked_import });
    }
    return result;
}

/// Why `mergeDependencyContracts` refused, when the caller asks for the reason.
/// A caller that passes none gets the stderr text that `zts compile` prints.
pub const MergeRefusal = struct {
    /// The dependency at fault. It borrows from the graph.
    path: []const u8 = "",
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const MergeRefusal) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// What the dependencies contribute to the structural properties of the entry.
pub const DependencyFacts = struct {
    properties: ?handler_contract.HandlerProperties,
    established: bool,
};

/// Union the facts of every dependency into the entry contract, then disclose
/// the public environment variables and stamp the source identity, the
/// capability matrix, and the policy hash. Pass the result to
/// `foldDependencyProperties`.
pub fn mergeDependencyContracts(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    deps: *DependencyContracts,
    env_public: []const []const u8,
    filename: []const u8,
    refusal: ?*MergeRefusal,
) !DependencyFacts {
    var effects_complete = contract.effect_analysis_complete;
    var dependency_properties: ?handler_contract.HandlerProperties = null;
    var established = true;
    for (deps.dependencies.items) |*dependency| {
        var conflict: ?handler_contract.ApiSchemaConflict = null;
        if (handler_contract.unionDependencyContract(allocator, contract, &dependency.contract, &conflict)) |_| {} else |err| {
            if (err == error.ApiSchemaConflict) {
                const name = if (conflict) |found| found.name else "";
                if (refusal) |record| {
                    record.path = dependency.path;
                    const written = std.fmt.bufPrint(
                        &record.buffer,
                        "API schema '{s}' is registered with different JSON by another module",
                        .{name},
                    ) catch record.buffer[0..0];
                    record.len = written.len;
                } else if (!builtin.is_test) {
                    debugPrint("{s}: API schema '{s}' is registered with different JSON by another module\n", .{ dependency.path, name });
                }
            }
            return err;
        }
        if (dependency.blocked_import) effects_complete = false;
        if (dependency.contract.properties) |properties| {
            dependency_properties = joinStructural(dependency_properties, properties);
        } else {
            established = false;
        }
    }
    contract.effect_analysis_complete = effects_complete;
    try disclosePublicEnv(allocator, contract, env_public);
    contract.source_identity = zts.sourceIdentityForPath(filename);
    contract.capabilities = zts.computeCapabilityMatrix(contract.modules.items);
    const policy_hex = zts.policyHash();
    _ = try std.fmt.hexToBytes(&contract.policy_hash, &policy_hex);
    return .{ .properties = dependency_properties, .established = established };
}

/// Discharge the `Proof<...>` and `Effects<...>` capsule of every helper in
/// each dependency module of a graph, and append the failing rows to
/// `contract.spec_diagnostics`. The entry is the last module of `compile_result`
/// and stays out: its own helpers are discharged with its contract.
///
/// `extractContract` reads a dependency without authored source types, so it
/// finds no capsule. This opens a second, typed session for each dependency
/// with the verifier and flow passes off. The module's imported effects come
/// from `loaded_effects`. Its writers come from `persistent_writes`, the flow
/// result of the whole graph, and from `reported_writes`, the verifier writes
/// by flow module id. Each row carries the dependency path in `site.file`.
/// ZTS606, the public-helper rules, and the capsule summaries stay entry-only.
pub fn dischargeDependencyCapsules(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    atoms: *zts.AtomTable,
    exports: *const zts.ExportedSignatures,
    loaded_effects: []const zts.pipeline.LoadedModuleEffects,
    persistent_writes: []const zts.pipeline.PersistentWrite,
    reported_writes: []const check_run_mod.WriteSite,
    inputs: MultiModuleBuild,
    contract: *HandlerContract,
) !void {
    const entry_index = compile_result.modules.len - 1;
    for (compile_result.modules[0..entry_index], compile_result.parsers[0..entry_index], 0..) |compiled_module, *js_parser, position| {
        const graph_idx = graph.execution_order[position];
        const module = &graph.module_list.items[graph_idx];
        const module_id: zts.pipeline.FlowModuleId = @intCast(position + 1);

        const module_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
        var parsed = zts.pipeline.ParsedModule.fromTypedExisting(module_view, compiled_module.root, atoms, &js_parser.type_store);
        parsed.scopes = &js_parser.scopes;

        var link_arena = std.heap.ArenaAllocator.init(allocator);
        defer link_arena.deinit();
        const file_imports = try fileImportSignatures(link_arena.allocator(), graph, module.path, module_view, atoms, exports);

        var session: zts.pipeline.ModuleAnalysisSession = .{};
        try session.initFull(allocator, parsed, .{
            .source_types = .direct,
            .strict = inputs.strict,
            .manifest_registry = inputs.manifest_registry,
            .select_verifier = false,
            .select_flow = false,
            .allow_raw_exported_boundary = true,
            .file_import_signatures = &file_imports,
        });
        defer session.deinit();
        try session.complete();

        const imported_effects = try zts.pipeline.importedEffectsForLoadedModule(
            allocator,
            graph,
            graph_idx,
            try session.facts(),
            loaded_effects,
        );
        defer allocator.free(imported_effects);
        try session.setImportedEffects(imported_effects);

        // The graph compile also stores the entry's writes, so keep this
        // module's id exactly.
        var verifier_writes: std.ArrayList(ir.NodeIndex) = .empty;
        defer verifier_writes.deinit(allocator);
        for (reported_writes) |site| {
            if (site.module == module_id) try verifier_writes.append(allocator, site.node);
        }
        var writers = try zts.pipeline.StateWriterList.forModule(
            allocator,
            module_view,
            module_id,
            persistent_writes,
            verifier_writes.items,
        );
        defer writers.deinit(allocator);

        var table = try session.dischargeHelperCapsules(writers.view());
        defer table.deinit(allocator);
        for (table.capsules.items) |*capsule| {
            try appendCapsuleRows(allocator, contract, capsule.name, module.path, capsule.line, capsule.column, capsule.diagnostics.items);
            try appendCapsuleRows(allocator, contract, capsule.name, module.path, capsule.line, capsule.column, capsule.effect_diagnostics.items);
        }
    }
}

/// Copy the rows of one dependency helper into the merged contract, placed in
/// the file of that dependency.
fn appendCapsuleRows(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    function_name: []const u8,
    module_path: []const u8,
    line: u32,
    column: u32,
    rows: []const handler_contract.SpecDiagnostic,
) !void {
    for (rows) |row| {
        var copy = try row.clone(allocator);
        errdefer copy.deinit(allocator);
        if (copy.function == null) copy.function = try allocator.dupe(u8, function_name);
        const file = try allocator.dupe(u8, module_path);
        if (copy.site) |*site| {
            if (site.file) |old| allocator.free(old);
            site.file = file;
        } else {
            copy.site = .{ .file = file, .line = line, .column = column };
        }
        try contract.spec_diagnostics.append(allocator, copy);
    }
}

/// Build the contract of a handler with file imports.
///
/// The base is the full contract of the entry module with its authored source
/// types, so the entry capsule, budget, and intent survive. Each dependency
/// yields a contract-only extraction, whose facts are unioned into the base.
/// The flow pass runs once over the deduplicated graph modules in load order.
/// Every property that the graph cannot establish reads false: a property never
/// reads true from the entry alone.
pub fn buildMultiModuleContract(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    atoms: *zts.AtomTable,
    exports: *const zts.ExportedSignatures,
    inputs: MultiModuleBuild,
) !HandlerContract {
    const entry_index = compile_result.modules.len - 1;
    var deps = try collectDependencyContracts(allocator, graph, compile_result, atoms, inputs);
    defer deps.deinit(allocator);
    var policy_checked = deps.policy_checked;

    // The entry: a full session with its authored source types and file-import table.
    const entry_graph_idx = graph.execution_order[entry_index];
    const entry_module = &graph.module_list.items[entry_graph_idx];
    const entry_parser = &compile_result.parsers[entry_index];
    const entry_root = compile_result.modules[entry_index].root;
    const entry_view = zts.IrView.fromIRStore(&entry_parser.nodes, &entry_parser.constants);
    var parsed = zts.pipeline.ParsedModule.fromTypedExisting(entry_view, entry_root, atoms, &entry_parser.type_store);
    parsed.scopes = &entry_parser.scopes;

    var link_arena = std.heap.ArenaAllocator.init(allocator);
    defer link_arena.deinit();
    const file_imports = try fileImportSignatures(link_arena.allocator(), graph, entry_module.path, entry_view, atoms, exports);

    var flow_modules = try imports_mod.flowModulesForGraph(allocator, graph, compile_result, atoms);
    defer flow_modules.deinit();

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(allocator, parsed, .{
        .source_types = .direct,
        .strict = inputs.strict,
        .manifest_registry = inputs.manifest_registry,
        .policy_sections = if (inputs.policy) |*configured| configured.declaredSections() else .{},
        .select_verifier = inputs.emit_verify,
        .select_flow = true,
        .file_import_signatures = &file_imports,
    });
    defer analysis.deinit();
    try analysis.complete();

    const facts = try analysis.facts();
    const env_public: []const []const u8 = if (inputs.policy) |*configured| configured.envPublic() else &.{};
    const handler_fn = findHandlerFunction(entry_view, entry_root);
    try analysis.prepareChecked(handler_fn, .{
        .module_facts = facts,
        .flow_modules = flow_modules.views.items,
        .flow_initialization_order = flow_modules.initialization_order.items,
        .flow_modules_complete = flow_modules.complete,
        .env_public = env_public,
    });

    var verify_info: ?VerificationInfo = null;
    if (inputs.emit_verify) {
        if (handler_fn) |hf| {
            // `checkGraphModule` already ran the verifier on the entry and found no error.
            const error_count = try analysis.runVerifier(hf);
            if (error_count > 0) return error.AnalysisPassIncomplete;
            const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
            var has_unreachable = false;
            for (checked.verifierDiagnostics()) |diagnostic| {
                if (diagnostic.kind == .unreachable_after_return) has_unreachable = true;
            }
            verify_info = .{
                .exhaustive_returns = true,
                .results_safe = true,
                .unreachable_code = has_unreachable,
                .bytecode_verified = true,
            };
        }
    }

    const entry_imported_effects = try zts.pipeline.importedEffectsForLoadedModule(
        allocator,
        graph,
        entry_graph_idx,
        facts,
        deps.loaded_effects.items,
    );
    defer allocator.free(entry_imported_effects);

    var temp_aot = if (inputs.emit_contract)
        try analyzeAot(allocator, entry_parser, atoms, entry_root)
    else
        null;
    defer if (temp_aot) |*aot| aot.deinit(allocator);

    var contract = try extractContractFromAnalysis(&analysis, inputs.filename, .{
        .aot = temp_aot,
        .verification = verify_info,
        .imported_effects = entry_imported_effects,
    });
    errdefer contract.deinit(allocator);
    // The flow evaluation joins the shared-state fact: the verifier names the
    // writes that it can read, and the evaluator follows the rest.
    var shares_state = inputs.shares_state;
    var state_write: ?handler_contract.PropertyCause = null;
    if (handler_fn != null) {
        const completed = try analysis.completedFlow();
        try reportCompletedFlow(allocator, completed, analysis.flowErrorCount(), true, null, entry_view);
        if (check_run_mod.flowSharesState(completed)) {
            shares_state = true;
            if (inputs.emit_verify) {
                const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
                const unreported = try check_run_mod.unreportedWrites(allocator, completed, checked.verifierDiagnostics(), inputs.reported_writes);
                defer allocator.free(unreported);
                // The cause is a line of the entry file. A write in a dependency
                // module has no line there, so it keeps the generic hint.
                state_write = check_run_mod.firstEntryWriteCause(entry_view, checked.verifierDiagnostics(), unreported);
                for (unreported) |site| try printFlowWrite(allocator, graph, compile_result, site);
            }
        }
    }
    try validateContractPolicyInputs(allocator, inputs.filename, &contract, inputs.sql_schema_path, inputs.policy);
    if (inputs.policy != null) policy_checked = true;
    if (policy_checked and !builtin.is_test) debugPrint("Capability policy check passed\n", .{});

    const dependency_facts = try mergeDependencyContracts(allocator, &contract, &deps, env_public, inputs.filename, null);

    const verified = inputs.emit_verify and handler_fn != null;
    applyContractFacts(allocator, &contract, .{ .verifier = .{
        .state_isolated = verified and !shares_state,
        .shares_state = verified and shares_state,
        .result_safe = verified,
        .optional_safe = verified,
        .state_write = state_write,
    } });

    if (inputs.emit_contract) {
        if (handler_fn) |hf| try applyGraphPaths(allocator, &contract, &analysis, parsed, atoms, hf, inputs.filename);
    }
    foldDependencyProperties(allocator, &contract, dependency_facts.properties, dependency_facts.established);
    // A dependency contract has no authored source types, so its helpers are
    // discharged here, once the flow result of the whole graph exists.
    const flow_writes: []const zts.pipeline.PersistentWrite = if (handler_fn != null)
        (try analysis.completedFlow()).persistentWrites()
    else
        &.{};
    try dischargeDependencyCapsules(
        allocator,
        graph,
        compile_result,
        atoms,
        exports,
        deps.loaded_effects.items,
        flow_writes,
        inputs.reported_writes,
        inputs,
        &contract,
    );
    try refreshContractSpecDiagnostics(allocator, &contract);
    try refuseSpecErrors(&contract, inputs.filename);
    return contract;
}

/// Print the ZTS310 warning of a write that the flow evaluator found and the
/// verifier did not name, at the write, in the file of the module that holds
/// it. `site.module` is a flow module id: 0 for the entry, and the position of a
/// dependency in execution order plus one otherwise. A test build prints none.
fn printFlowWrite(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    site: check_run_mod.WriteSite,
) !void {
    if (builtin.is_test) return;
    const position: usize = if (site.module == 0) compile_result.modules.len - 1 else site.module - 1;
    if (position >= compile_result.modules.len) return error.AnalysisPassIncomplete;
    const module = &graph.module_list.items[graph.execution_order[position]];
    const parser = &compile_result.parsers[position];
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    if (view.getLoc(site.node) == null) return;
    var diag_view = zts.SourceView.of(module.source);
    diag_view.name = module.path;
    diag_view.normalize_positions = true;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var output_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
    const single = [_]zts.VerifierDiagnostic{check_run_mod.flowWriteDiagnostic(site)};
    {
        errdefer output = output_writer.toArrayList();
        try zts.DiagnosticProjection.writeAll(.verifier, diag_view, &single, view, &output_writer.writer);
    }
    output = output_writer.toArrayList();
    if (output.items.len > 0) debugPrint("{s}", .{output.items});
}

/// Keep, across the dependencies, the structural facts that every one of them holds.
fn joinStructural(
    joined: ?handler_contract.HandlerProperties,
    next: handler_contract.HandlerProperties,
) handler_contract.HandlerProperties {
    var out = joined orelse return next;
    out.pure = out.pure and next.pure;
    out.read_only = out.read_only and next.read_only;
    out.stateless = out.stateless and next.stateless;
    out.retry_safe = out.retry_safe and next.retry_safe;
    out.has_egress = out.has_egress or next.has_egress;
    return out;
}

/// Hold a structural property only when the entry and every dependency hold it.
/// A dependency contract that carries no properties establishes none, so the
/// properties read false. The cost bound counts module calls on the paths of the
/// entry. A pure dependency makes no module call, so the bound stands. Any other
/// dependency adds calls that the entry paths do not show, so the bound, the I/O
/// depth, and the cost envelope are all cleared.
pub fn foldDependencyProperties(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    dependency: ?handler_contract.HandlerProperties,
    established: bool,
) void {
    const props = if (contract.properties) |*value| value else return;
    if (!established) {
        props.pure = false;
        props.read_only = false;
        props.stateless = false;
        props.retry_safe = false;
        props.fault_covered = false;
    }
    if (dependency) |held| {
        props.pure = props.pure and held.pure;
        props.read_only = props.read_only and held.read_only;
        props.stateless = props.stateless and held.stateless;
        props.retry_safe = props.retry_safe and held.retry_safe;
        props.has_egress = props.has_egress or held.has_egress;
    }
    props.idempotent = props.deterministic and props.retry_safe;
    const all_pure = established and (dependency == null or dependency.?.pure);
    if (all_pure) return;
    props.cost_bounded = false;
    props.max_io_depth = null;
    if (contract.cost_envelope) |*envelope| envelope.deinit(allocator);
    contract.cost_envelope = null;
}

/// Run the path enumeration and the fault coverage analysis on the entry
/// handler, as the single-module build does. The files that the entry imports
/// decide `fault_covered`.
fn applyGraphPaths(
    allocator: std.mem.Allocator,
    contract: *HandlerContract,
    analysis: *zts.pipeline.ModuleAnalysisSession,
    parsed: zts.pipeline.ParsedModule,
    atoms: *zts.AtomTable,
    handler_fn: ir.NodeIndex,
    filename: []const u8,
) !void {
    var path_module_facts = try zts.pipeline.buildModuleFacts(allocator, parsed, null);
    defer path_module_facts.deinit();
    var imported_scan = try imports_mod.collectImportedFailableCalls(allocator, &path_module_facts, filename, null);
    defer if (imported_scan) |*scan| scan.deinit(allocator);
    const path_effects = try analysis.pathEffectFacts();
    var gen = zts.PathGenerator.init(allocator, parsed.ir_view, atoms, path_effects);
    defer gen.deinit();
    gen.facts = &path_module_facts;
    gen.setImportedScan(if (imported_scan) |scan| scan.entries.items else null);
    try gen.generate(handler_fn);

    var summary = try check_run_mod.summarizeGeneratedPaths(allocator, &gen, true);
    defer summary.deinit(allocator);
    var fc = zts.FaultCoverageChecker.init(allocator, gen.getTests());
    defer fc.deinit();
    try fc.analyze();
    var fault_stamp = try check_run_mod.stampFaultCoverage(allocator, parsed.ir_view, &gen, &fc);
    defer fault_stamp.deinit(allocator);
    summary.takeFaultStamp(&fault_stamp);
    applyContractFacts(allocator, contract, .{ .paths = &summary });
}

/// Which spec errors a caller gates on: the ones the author asked for, or those
/// and the implicit default profile too.
pub const SpecGate = enum { authored, every };

/// Print each spec error that `gate` reaches, and return the count.
pub fn reportSpecErrors(contract: *const HandlerContract, filename: []const u8, gate: SpecGate) u32 {
    var count: u32 = 0;
    for (contract.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.kind.severity() != .err) continue;
        if (gate == .authored and diagnostic.implicit_default) continue;
        count += 1;
        const place_file = if (diagnostic.site) |site| (site.file orelse filename) else filename;
        if (!builtin.is_test) debugPrint("{s}: {s} {s}\n", .{
            place_file,
            diagnostic_catalog.specCode(diagnostic.kind),
            diagnostic.spec_name,
        });
    }
    return count;
}

/// Refuse a compile when an authored spec error remains. The implicit default
/// profile is advisory here, as it is on the single-module compile path. A sealed
/// build gates it on the merged contract in `runBuild`.
fn refuseSpecErrors(contract: *const HandlerContract, filename: []const u8) !void {
    if (reportSpecErrors(contract, filename, .authored) > 0) return error.SpecDiagnosticsRefused;
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
pub fn appendPolicyDiagnostics(
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
            .literal_not_allowed => try allocator.print("{s} '{s}' is not in the capability policy allow-list", .{ handler_policy.categoryLiteralLabel(violation.category), violation.value orelse "" }),
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

fn buildTestContractForSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    sql_schema_path: ?[]const u8,
) !HandlerContract {
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const root = try js_parser.parse();
    const view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = zts.pipeline.ParsedModule.fromExisting(view, root, &atoms);

    // This path has no policy, so `env_public` stays empty and every literal
    // `env` name is secret: the verdict is conservative, never optimistic.
    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{ .strict = false, .flow = true });
    defer analysis.deinit();
    try analysis.complete();

    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);

    // `extractContract` ran the flow pass and applied it to the contract.
    if (findHandlerFunction(parsed.ir_view, parsed.root) != null) {
        try reportCompletedFlow(
            allocator,
            try analysis.completedFlow(),
            analysis.flowErrorCount(),
            true,
            null,
            parsed.ir_view,
        );
    }
    try validateContractPolicyInputs(allocator, filename, &contract, sql_schema_path, null);
    return contract;
}

fn failContractModuleScan(_: zts.IrView) anyerror!void {
    return error.OutOfMemory;
}

test "contract construction propagates type-check allocation failure" {
    const allocator = std.testing.allocator;
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();

    const source = "function handler(req) { return Response.text('ok'); }";
    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = try js_parser.parse();
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = zts.pipeline.ParsedModule.fromExisting(ir_view, root, &atoms);

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{ .module_scan = failContractModuleScan, .strict = false });
    defer analysis.deinit();
    try analysis.complete();
    try std.testing.expectError(error.OutOfMemory, analysis.extractContract("<contract-type-oom>"));
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

test "contract-only extraction without source types preserves verifier properties" {
    const allocator = std.testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  if (5) return Response.text(jwtVerify("token", "secret").value);
        \\  return Response.text(process.env.NAME);
        \\}
    ;

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = try js_parser.parse();
    const view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initContractOnly(allocator, zts.pipeline.ParsedModule.fromExisting(view, root, &atoms), .{});
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract("shared-analysis-contract-only.js");
    defer contract.deinit(allocator);

    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.result_safe);
    try std.testing.expect(!props.optional_safe);
}
