//! The CHECK facade: run the analysis pipeline on a handler and return a `CheckResult`.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;
const ir = zts.parser;
const handler_contract = zts.handler_contract;
const VerificationInfo = handler_contract.VerificationInfo;
const handler_policy = zts.handler_policy;
const json_diag = @import("json_diagnostics.zig");
const check_mod = @import("precompile_check.zig");
const CheckResult = check_mod.CheckResult;
const syncCheckResultProperties = check_mod.syncCheckResultProperties;
const appendSpecDiagnosticsJson = check_mod.appendSpecDiagnosticsJson;
const appendCanonicalPublicHelperDiagnostics = check_mod.appendCanonicalPublicHelperDiagnostics;
const refreshSpecDiagnostics = check_mod.refreshSpecDiagnostics;
const readFilePosix = zts.file_io.readFile;
const imports_mod = @import("precompile_imports.zig");
const ImportReader = imports_mod.ImportReader;
const FlowModuleGraph = imports_mod.FlowModuleGraph;
const flowModulesForSingleModule = imports_mod.flowModulesForSingleModule;
const collectImportedFailableCalls = imports_mod.collectImportedFailableCalls;
const findHandlerFunction = zts.findHandlerFunction;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;
const readFailureReason = stderr_mod.readFailureReason;
const printParseErrors = stderr_mod.printParseErrors;
const virtual_imports_mod = @import("precompile_virtual_imports.zig");
const VirtualImportDiagnostic = virtual_imports_mod.VirtualImportDiagnostic;
const validateVirtualModuleImports = virtual_imports_mod.validateVirtualModuleImports;
const contract_mod = @import("precompile_contract.zig");
const graph_check_mod = @import("precompile_graph_check.zig");
const GraphCheck = graph_check_mod.GraphCheck;
const precompile_mod = @import("precompile.zig");
const extractContractFromAnalysis = contract_mod.extractContractFromAnalysis;
const validateContractPolicyInputs = contract_mod.validateContractPolicyInputs;
const appendPolicyDiagnostics = contract_mod.appendPolicyDiagnostics;

/// What a check hands an observer once the verifier and flow passes have run.
/// Everything is borrowed and lives only during the callback: copy what you keep.
pub const CheckedView = struct {
    ir_view: zts.IrView,
    atoms: *zts.AtomTable,
    handler_fn: zts.parser.NodeIndex,
    verifier_diagnostics: []const zts.VerifierDiagnostic,
    flow_diagnostics: []const zts.FlowDiagnostic,
};

/// Callback run once per check that reaches the verifier and flow passes.
/// It may fail only with `OutOfMemory`; keep any other failure in `context`.
pub const CheckedObserver = struct {
    context: *anyopaque,
    on_checked: *const fn (context: *anyopaque, checked: CheckedView) error{OutOfMemory}!void,
};

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
    /// Called once after the verifier and flow passes, when the file has a
    /// handler and the earlier stages passed. Observes only: the check's
    /// output does not change.
    observer: ?CheckedObserver = null,
};

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
        const message = allocator.print("cannot read handler file '{s}': {s}", .{ handler_path, @errorName(err) }) catch {
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

pub const PathAnalysis = struct {
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

    pub fn deinit(self: *PathAnalysis, allocator: std.mem.Allocator) void {
        if (self.fault_unseen_snippet_owned) |snippet| allocator.free(snippet);
        if (self.cost_envelope) |*envelope| envelope.deinit(allocator);
        for (self.behaviors.items) |*behavior| behavior.deinit(allocator);
        self.behaviors.deinit(allocator);
    }

    /// Take the fault facts from a stamp. The snippet allocation moves here,
    /// so the stamp no longer frees it.
    pub fn takeFaultStamp(self: *PathAnalysis, stamp: *FaultStamp) void {
        self.fault_coverage = stamp.coverage;
        self.fault_clean = stamp.clean;
        self.fault_unseen_cause = stamp.unseen_cause;
        self.fault_unseen_snippet_owned = stamp.unseen_snippet_owned;
        stamp.unseen_snippet_owned = null;
    }
};

/// The verifier facts that a driver stamps on the contract properties. Each
/// driver fills every field from its own verifier run; `false` means unproven.
pub const VerifierFacts = struct {
    state_isolated: bool,
    /// The verifier ran and found a write to state that later requests read.
    /// False when verification did not run, so an unverified build keeps its
    /// properties.
    shares_state: bool,
    result_safe: bool,
    optional_safe: bool,
    /// The first write to module state in the entry module, when a driver
    /// found one with a line. It names the cause of each property that
    /// `shares_state` removes.
    state_write: ?handler_contract.PropertyCause = null,
};

/// The facts a driver applies to a contract after its own analysis. A null
/// member leaves that part of the contract untouched, so a driver applies the
/// verifier facts first and the path facts after the passes that sit between.
pub const ContractFacts = struct {
    verifier: ?VerifierFacts = null,
    /// Moved into the contract: the cost envelope, the behaviors, and the
    /// fault cause snippet leave this value. The caller still calls `deinit`
    /// on it for anything not moved.
    paths: ?*PathAnalysis = null,
};

/// A handler whose response can depend on state that earlier requests wrote is
/// not deterministic, and one that writes shared state is not read-only,
/// retry-safe, pure, or stateless. The virtual-module effect row does not see a
/// write to module state, so the verifier fact clears these here.
fn clearSharedStateProperties(props: *handler_contract.HandlerProperties) void {
    props.pure = false;
    props.stateless = false;
    props.read_only = false;
    props.retry_safe = false;
    props.deterministic = false;
    props.idempotent = false;
}

/// Record the write that removed each shared-state property, so a ZTS500 can
/// name it. A property that was already false before the shared-state fact, or
/// that this fact left alone, is not recorded: another cause owns it.
fn recordStateWrite(
    provenance: *handler_contract.PropertyProvenance,
    before: handler_contract.HandlerProperties,
    after: handler_contract.HandlerProperties,
    verifier: VerifierFacts,
) void {
    provenance.state_write = null;
    provenance.state_write_removed = .empty;
    if (!verifier.shares_state) return;
    const write = verifier.state_write orelse return;
    provenance.state_write = write;
    // The verifier fact alone sets `state_isolated`, so the write is its cause
    // whatever the contract held before.
    if (!after.state_isolated) provenance.state_write_removed.insert(.state_isolated);
    if (before.pure and !after.pure) provenance.state_write_removed.insert(.pure);
    if (before.stateless and !after.stateless) provenance.state_write_removed.insert(.stateless);
    if (before.read_only and !after.read_only) provenance.state_write_removed.insert(.read_only);
    if (before.retry_safe and !after.retry_safe) provenance.state_write_removed.insert(.retry_safe);
    if (before.deterministic and !after.deterministic) provenance.state_write_removed.insert(.deterministic);
    if (before.idempotent and !after.idempotent) provenance.state_write_removed.insert(.idempotent);
}

/// The first write to module state in the entry module, in source order, as a
/// cause. `verifier_diagnostics` are the entry module's verifier findings and
/// `sites` the flow writes that the verifier did not name. A write in a
/// dependency module has no line in the entry file, so it gives no cause.
pub fn firstEntryWriteCause(
    ir_view: zts.IrView,
    verifier_diagnostics: []const zts.VerifierDiagnostic,
    sites: []const WriteSite,
) ?handler_contract.PropertyCause {
    var first: ?ir.NodeIndex = null;
    for (verifier_diagnostics) |diagnostic| {
        if (diagnostic.kind != .module_scope_mutation) continue;
        first = zts.spec_discharge.earlierWrite(ir_view, first, diagnostic.node);
    }
    for (sites) |site| {
        if (site.module != 0) continue;
        first = zts.spec_discharge.earlierWrite(ir_view, first, site.node);
    }
    const loc = ir_view.getLoc(first orelse return null) orelse return null;
    return .{ .line = loc.line, .column = loc.column, .snippet = handler_contract.state_write_snippet };
}

/// A write that a request makes to state that outlives it, named by the flow
/// module that holds it and the node of the assignment or call.
pub const WriteSite = struct {
    module: zts.pipeline.FlowModuleId,
    node: ir.NodeIndex,
};

/// The flow half of the shared-state fact. The evaluator followed the handler
/// and a request wrote persistent state, or it could not follow the handler,
/// which proves nothing about state. Every writer of `shares_state` joins this
/// with the verifier fact, so there is one rule and no copy of it.
pub fn flowSharesState(flow: *const zts.FlowChecker) bool {
    return flow.cleared() or flow.persistentWrites().len > 0;
}

const flow_write_message = "a request writes state that outlives it (breaks cross-request isolation)";
const flow_write_help = "copy the value into a local before the write, or move the state to zttp:cache";

/// The ZTS310 warning for a write that the flow evaluator found and the
/// verifier did not name. It points at the write, in the module that holds it.
pub fn flowWriteDiagnostic(site: WriteSite) zts.VerifierDiagnostic {
    return .{
        .severity = .warning,
        .kind = .module_scope_mutation,
        .node = site.node,
        .message = flow_write_message,
        .help = flow_write_help,
    };
}

/// The persistent writes of `flow` that no ZTS310 finding of the verifier names,
/// each site once. `entry_verifier` is the verifier output of the entry module
/// (flow module 0), and `dependency_reported` lists the verifier findings of
/// the dependency modules. The caller frees the slice.
pub fn unreportedWrites(
    allocator: std.mem.Allocator,
    flow: *const zts.FlowChecker,
    entry_verifier: []const zts.VerifierDiagnostic,
    dependency_reported: []const WriteSite,
) ![]WriteSite {
    var sites: std.ArrayList(WriteSite) = .empty;
    errdefer sites.deinit(allocator);
    next_write: for (flow.persistentWrites()) |write| {
        if (write.module == 0) {
            for (entry_verifier) |diagnostic| {
                if (diagnostic.kind == .module_scope_mutation and diagnostic.node == write.node) continue :next_write;
            }
        }
        for (dependency_reported) |reported| {
            if (reported.module == write.module and reported.node == write.node) continue :next_write;
        }
        for (sites.items) |seen| {
            if (seen.module == write.module and seen.node == write.node) continue :next_write;
        }
        try sites.append(allocator, .{ .module = write.module, .node = write.node });
    }
    return sites.toOwnedSlice(allocator);
}

/// The verifier diagnostics of the entry module followed by the ZTS310 warning
/// of each entry write in `sites`. An observer reads this list, so it sees the
/// same verifier-coded diagnostics that `zts check` reports. Returns
/// `verifier_diags` itself when no entry write adds a warning; otherwise the
/// caller frees the slice.
fn withEntryWriteDiagnostics(
    allocator: std.mem.Allocator,
    verifier_diags: []const zts.VerifierDiagnostic,
    sites: []const WriteSite,
    ir_view: zts.IrView,
) ![]const zts.VerifierDiagnostic {
    var added: usize = 0;
    for (sites) |site| {
        if (site.module == 0 and ir_view.getLoc(site.node) != null) added += 1;
    }
    if (added == 0) return verifier_diags;
    const combined = try allocator.alloc(zts.VerifierDiagnostic, verifier_diags.len + added);
    @memcpy(combined[0..verifier_diags.len], verifier_diags);
    var next = verifier_diags.len;
    for (sites) |site| {
        if (site.module != 0 or ir_view.getLoc(site.node) == null) continue;
        combined[next] = flowWriteDiagnostic(site);
        next += 1;
    }
    return combined;
}

/// Report each persistent write that the flow evaluator found and the verifier
/// did not name (`sites`, from `unreportedWrites`), as a ZTS310 warning at the
/// write, in the file of the module that holds it.
fn appendFlowWriteFindings(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    json_mode: bool,
    sites: []const WriteSite,
    graph_check: ?*GraphCheck,
    ir_view: zts.IrView,
    diag_view: zts.SourceView,
    handler_path: []const u8,
) !void {
    for (sites) |site| {
        if (site.module != 0) {
            const gc = graph_check orelse return error.AnalysisPassIncomplete;
            try gc.appendDependencyWrite(result, json_mode, site);
            continue;
        }
        if (ir_view.getLoc(site.node) == null) continue;
        result.verify_warnings += 1;
        const diagnostic = flowWriteDiagnostic(site);
        if (json_mode) {
            var projected = json_diag.fromCheckerDiagnostic(allocator, .verifier, diagnostic, ir_view, handler_path) orelse continue;
            errdefer projected.deinit(allocator);
            try result.json_diagnostics.append(allocator, projected);
        } else if (!builtin.is_test) {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(allocator);
            var output_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
            const single = [_]zts.VerifierDiagnostic{diagnostic};
            zts.DiagnosticProjection.writeAll(.verifier, diag_view, &single, ir_view, &output_writer.writer) catch {};
            output = output_writer.toArrayList();
            if (output.items.len > 0) debugPrint("{s}", .{output.items});
        }
    }
}

/// The one writer of the verifier, path, and fault facts on a contract. Both
/// drivers (`compileHandler` and `runCheckOnParsedSource`) fill a
/// `ContractFacts` from their own analysis and call this, so a new contract
/// fact is added here once. It allocates nothing, so it cannot fail halfway.
pub fn applyContractFacts(
    allocator: std.mem.Allocator,
    contract: *handler_contract.HandlerContract,
    facts: ContractFacts,
) void {
    if (facts.verifier) |verifier| {
        if (contract.properties) |*props| {
            const before = props.*;
            props.state_isolated = verifier.state_isolated;
            if (verifier.shares_state) clearSharedStateProperties(props);
            props.result_safe = verifier.result_safe;
            props.optional_safe = verifier.optional_safe;
            recordStateWrite(&contract.property_provenance, before, props.*, verifier);
        }
    }
    if (facts.paths) |paths| {
        if (contract.properties) |*props| {
            props.max_io_depth = paths.max_io_depth;
            props.cost_bounded = paths.cost_bounded;
            props.fault_covered = paths.fault_clean;
        }
        contract.property_provenance.fault_covered = paths.fault_unseen_cause;
        // The cause borrows its snippet, so the contract takes the
        // allocation that backs it.
        if (contract.owned_fault_cause_snippet) |old| allocator.free(old);
        contract.owned_fault_cause_snippet = paths.fault_unseen_snippet_owned;
        paths.fault_unseen_snippet_owned = null;
        if (paths.cost_envelope) |envelope| {
            contract.cost_envelope = envelope;
            paths.cost_envelope = null;
        }
        contract.behaviors = paths.behaviors;
        paths.behaviors = .empty;
        contract.behaviors_exhaustive = paths.behaviors_exhaustive;
        contract.fault_coverage = paths.fault_coverage;
    }
}

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
    var stamp = try stampFaultCoverage(output_allocator, ir_view, &generator, &checker);
    analysis.takeFaultStamp(&stamp);
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

    pub fn deinit(self: *FaultStamp, allocator: std.mem.Allocator) void {
        if (self.unseen_snippet_owned) |snippet| allocator.free(snippet);
        self.unseen_snippet_owned = null;
    }
};

/// Read the fault facts from a generator and a checker that already ran
/// `analyze` over the generator's tests.
pub fn stampFaultCoverage(
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
pub fn summarizeGeneratedPaths(
    output_allocator: std.mem.Allocator,
    generator: *zts.PathGenerator,
    include_behaviors: bool,
) !PathAnalysis {
    const tests = generator.getTests();
    var analysis = PathAnalysis{
        .paths_enumerated = @intCast(tests.len),
        // Ask the generator rather than recomputing the MAX_PATHS comparison:
        // it also knows whether anything was summarized instead of enumerated.
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
            // exhaustive: .linear and .unbounded have no fixed I/O depth, so the report leaves it null.
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

/// Like runCheckOnly but operates on pre-read source. `opts.skip_contract` skips
/// stages 7-10 (verification, contract, paths, fault coverage): only parse and
/// type checking run, enough to detect errors.
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
pub fn runCheckOnlyFromSourceWithPathAllocator(
    allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    opts: CheckOptions,
) !CheckResult {
    var already_mapped: usize = 0;

    var result = runCheckOnParsedSource(
        allocator,
        path_allocator,
        source,
        handler_path,
        opts,
        &already_mapped,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.MissingSqlSchema => return err,
        else => {
            var diagnostic = try json_diag.fromAnalyzerError(allocator, handler_path, err);
            errdefer diagnostic.deinit(allocator);
            var refused = CheckResult{ .parse_errors = 1, .analyzer_error = err };
            try refused.json_diagnostics.append(allocator, diagnostic);
            return refused;
        },
    };
    errdefer result.deinit(allocator);
    if (result.is_typescript and result.stages_run.contains(.parse)) {
        remapDiagnosticsToSource(&result, .{ .text = source, .normalize_positions = true }, already_mapped);
    }

    return result;
}

/// Apply source-view coordinates after the recorded diagnostic boundary.
pub fn remapDiagnosticsToSource(
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

/// Report why the front end refused a source, under `path`, and say whether it
/// did. An accepted source leaves the result unchanged except for the parse
/// stage. The entry and each dependency of a graph go through here.
pub fn appendSourceRefusals(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    source_owner: *zts.DirectCheckSource,
    source: []const u8,
    path: []const u8,
    json_mode: bool,
) !bool {
    switch (source_owner.outcome().*) {
        .recovered_admission_refused => {
            const start = result.json_diagnostics.items.len;
            const diagnostics = source_owner.selectedAdmissionDiagnostics();
            for (diagnostics) |diagnostic| {
                appendCheckAdmissionDiagnostic(allocator, result, source, diagnostic, path);
            }
            remapDiagnosticsToSource(result, .{ .text = source, .normalize_positions = true }, start);
            result.parse_errors += @intCast(diagnostics.len);
            return true;
        },
        .terminal_admission_refused => |failure| {
            if (source_owner.terminalAdmissionDiagnostic()) |diagnostic| {
                appendCheckAdmissionDiagnostic(allocator, result, source, diagnostic, path);
            }
            if (!builtin.is_test) debugPrint("TypeScript strip error: {}\n", .{zts.prepareErrorForAdmissionFailure(failure)});
            result.parse_errors += 1;
            return true;
        },
        .parser_refused => {
            result.stages_run.insert(.parse);
            const errors = source_owner.parserErrors();
            if (json_mode) {
                for (errors) |parse_error| {
                    var diagnostic = json_diag.fromParseErrorOwned(allocator, parse_error, path);
                    result.json_diagnostics.append(allocator, diagnostic) catch diagnostic.deinit(allocator);
                }
            } else if (!builtin.is_test) {
                printParseErrors(allocator, source_owner.sourceView(), errors);
            }
            result.parse_errors += @intCast(errors.len);
            return true;
        },
        .accepted => {
            result.stages_run.insert(.parse);
            return false;
        },
    }
}

fn runCheckOnParsedSource(
    allocator: std.mem.Allocator,
    path_allocator: std.mem.Allocator,
    source: []const u8,
    handler_path: []const u8,
    opts: CheckOptions,
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

    const parsed_input: struct {
        parser: *zts.parser.JsParser,
        atoms: *zts.AtomTable,
        root: ir.NodeIndex,
    } = switch (source_kind) {
        .unsupported, .virtual_javascript => {
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
            if (try appendSourceRefusals(allocator, &result, &source_owner, source, handler_path, json_mode)) return result;
            const capabilities = source_owner.acceptedCapabilities() orelse return error.DirectTypeSyntaxUnavailable;
            break :typed .{
                .parser = &source_owner.parser,
                .atoms = capabilities.atoms,
                .root = capabilities.root,
            };
        },
    };
    already_mapped.* = result.json_diagnostics.items.len;
    var diag_view = zts.SourceView.of(source);
    diag_view.name = handler_path;
    var js_parser = parsed_input.parser;
    var atoms = parsed_input.atoms;
    var root = parsed_input.root;

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
                var projected = try virtual_imports_mod.virtualImportJsonDiagnostic(allocator, diagnostic, handler_path);
                errdefer projected.deinit(allocator);
                try result.json_diagnostics.append(allocator, projected);
            }
        }
        result.parse_errors = 1;
        return result;
    };

    var ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    var handler_fn = zts.findHandlerFunction(ir_view, root);
    result.has_handler = handler_fn != null;
    var parsed = zts.parsedModuleFromDirectCheck(&source_owner) orelse return error.DirectTypeSyntaxUnavailable;
    parsed.scopes = &js_parser.scopes;

    // The policy is parsed once and stays alive for the whole analysis: the
    // declared sections and the `env.public` names both come from it, and the
    // flow checker borrows the names. A policy that does not parse yields
    // neither, which keeps every `env` name secret; `appendPolicyDiagnostics`
    // reports the parse failure.
    var live_policy: ?zts.HandlerPolicy = if (opts.policy_source) |policy_source|
        zts.handler_policy.parsePolicyJsonOrNull(allocator, policy_source)
    else
        null;
    defer if (live_policy) |*policy| policy.deinit(allocator);
    const env_public: []const []const u8 = if (live_policy) |*policy| policy.envPublic() else &.{};

    // A handler with a file import gets every check that the build runs on each
    // module. The graph keeps the parsers that code generation walked, so the
    // entry is analyzed over the parser of the graph, with typed file imports.
    var graph_check: ?*GraphCheck = null;
    defer if (graph_check) |graph| graph.destroy();
    var entry_imports: ?*const zts.FileImportSignatures = null;
    if (comptime builtin.target.os.tag != .freestanding) {
        if (handler_fn != null and precompile_mod.hasFileImports(ir_view)) {
            const graph = try GraphCheck.create(allocator);
            graph_check = graph;
            const graph_opts: graph_check_mod.RunOptions = .{
                .handler_path = handler_path,
                .source = source,
                .import_reader = opts.import_reader,
                .skip_contract = skip_contract,
                .json_mode = json_mode,
                .policy = live_policy,
                .sql_schema_path = sql_schema_path,
            };
            const outcome = try graph.run(&result, graph_opts);
            // `remapDiagnosticsToSource` reads each later diagnostic against
            // the entry source. Every finding so far has its own coordinates.
            already_mapped.* = result.json_diagnostics.items.len;
            if (outcome == .refused) return result;
            js_parser = graph.entryParser();
            root = graph.entryRoot();
            atoms = &graph.atoms;
            ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
            handler_fn = zts.findHandlerFunction(ir_view, root);
            parsed = zts.pipeline.ParsedModule.fromTypedExisting(ir_view, root, atoms, &js_parser.type_store);
            parsed.scopes = &js_parser.scopes;
            entry_imports = try graph.entryFileImports(ir_view);
        }
    }

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(
        allocator,
        parsed,
        .{
            .source_types = .direct,
            .strict = true,
            .manifest_registry = null,
            // Which sections the project's policy declares, so a computed
            // capability resource gets the diagnostic that matches what the
            // author has actually written.
            .policy_sections = if (live_policy) |*policy| policy.declaredSections() else .{},
            .select_verifier = !skip_contract,
            .select_flow = !skip_contract,
            .file_import_signatures = entry_imports,
        },
    );
    defer analysis.deinit();
    try analysis.complete();
    const resolved = try analysis.resolvedForReport();
    // A file import with no type that crosses a module would hand the later
    // checks a value they cannot read, as the build refuses it.
    if (graph_check != null) {
        const untyped_checker = if (resolved.type_checker) |*checker| checker else return error.AnalysisPassIncomplete;
        if (untyped_checker.firstUntypedFileImport()) |name| {
            const message = try allocator.print(precompile_mod.untyped_import_format, .{name});
            defer allocator.free(message);
            try graph_check_mod.appendLinkRefusal(allocator, &result, json_mode, .file_import_untyped, handler_path, message);
            analysis.refuseResolution();
            already_mapped.* = result.json_diagnostics.items.len;
            return result;
        }
    }
    // One message per node: a boolean or strict diagnostic under a node that
    // has a type error repeats it.
    resolved.dropRepeatsOfTypeErrors();
    result.stages_run.insert(.boolean);

    {
        const bool_diags = resolved.boolDiagnostics();
        result.bool_errors += @intCast(resolved.bool_error_count);
        result.bool_warnings += @intCast(bool_diags.len -| resolved.bool_error_count);
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

    result.stages_run.insert(.types);
    const tc_diags = resolved.typeDiagnostics();
    result.type_errors += @intCast(resolved.typeErrorCount());
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

    if (resolved.strict_checker != null) {
        result.stages_run.insert(.strict);
        const strict_diags = resolved.strictDiagnostics();
        result.strict_errors += @intCast(resolved.strict_error_count);
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
        result.strict_warnings += strict_warnings;
        result.strict_advisories += strict_advisories;
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

    var imported_graph: ?FlowModuleGraph = null;
    defer if (imported_graph) |*graph| graph.deinit();
    var verify_info: ?VerificationInfo = null;
    // True only when the verifier ran and found a shared-state write.
    var shares_state = false;
    var state_write: ?handler_contract.PropertyCause = null;
    if (handler_fn) |hf| {
        // A graph supplies the flow modules from the parsers that it compiled.
        // The fault scan below performs its own independent traversal and reads.
        imported_graph = if (graph_check) |gc|
            try gc.flowModules()
        else
            try flowModulesForSingleModule(allocator, parsed, source, try analysis.facts(), handler_path);
        const graph = &imported_graph.?;
        result.imports_complete = graph.complete;

        try analysis.prepareChecked(hf, .{
            .module_facts = try analysis.facts(),
            .flow_modules = graph.views.items,
            .flow_initialization_order = graph.initialization_order.items,
            .flow_modules_complete = graph.complete,
            .env_public = env_public,
        });
        _ = try analysis.runVerifier(hf);
        _ = try analysis.runFlow(hf);
        const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
        const verifier_diags = checked.verifierDiagnostics();
        // The writes are found before the observer runs, so the observer sees
        // each flow-sourced ZTS310 warning that `zts check` reports.
        const flow_shares_state = flowSharesState(&checked.flow_checker);
        const write_sites: []const WriteSite = if (flow_shares_state)
            try unreportedWrites(
                allocator,
                &checked.flow_checker,
                verifier_diags,
                if (graph_check) |gc| gc.reported_writes.items else &.{},
            )
        else
            &.{};
        defer allocator.free(write_sites);
        if (opts.observer) |obs| {
            const observed_diags = try withEntryWriteDiagnostics(allocator, verifier_diags, write_sites, ir_view);
            defer if (observed_diags.ptr != verifier_diags.ptr) allocator.free(observed_diags);
            try obs.on_checked(obs.context, .{
                .ir_view = ir_view,
                .atoms = atoms,
                .handler_fn = hf,
                .verifier_diagnostics = observed_diags,
                .flow_diagnostics = checked.flowDiagnostics(),
            });
        }
        result.verify_ran = true;
        result.stages_run.insert(.verifier);
        result.stages_run.insert(.flow);
        result.verify_errors += @intCast(checked.verifier_error_count);
        result.verify_warnings += @intCast(verifier_diags.len -| checked.verifier_error_count);

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

        shares_state = checked.verifier.has_module_mutation or checked.verifier.unresolved_route_dispatch;
        if (graph_check) |gc| shares_state = shares_state or gc.shares_state;
        if (flow_shares_state) {
            shares_state = true;
            try appendFlowWriteFindings(allocator, &result, json_mode, write_sites, graph_check, ir_view, diag_view, handler_path);
        }
        result.state_isolated = !shares_state;
        if (shares_state) state_write = firstEntryWriteCause(ir_view, verifier_diags, write_sites);
        if (result.verify_errors == 0) {
            result.exhaustive_returns = true;
            result.results_safe = true;
            result.optionals_safe = true;
            result.no_unreachable = for (verifier_diags) |d| {
                if (d.kind == .unreachable_after_return) break false;
            } else true;
            verify_info = .{
                .exhaustive_returns = true,
                .results_safe = true,
                .unreachable_code = !result.no_unreachable,
                .bytecode_verified = false,
            };
        }

        result.flow_errors = @intCast(checked.flow_error_count);
        const flow_diags = checked.flowDiagnostics();
        result.flow_warnings = @intCast(flow_diags.len -| result.flow_errors);
        result.flow_unresolved = checked.flow_checker.unresolvedCount();
        if (json_mode) {
            for (flow_diags) |diag| {
                if (json_diag.fromCheckerDiagnostic(allocator, .flow, diag, ir_view, handler_path)) |jd| {
                    result.json_diagnostics.append(allocator, jd) catch {
                        var owned = jd;
                        owned.deinit(allocator);
                    };
                }
            }
        } else if (flow_diags.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
            checked.flow_checker.formatDiagnostics(diag_view, &aw.writer) catch {};
            buf = aw.toArrayList();
            if (!builtin.is_test and buf.items.len > 0) debugPrint("{s}", .{buf.items});
        }
    }

    // The proof evidence of the modules folds into one program, as the build
    // folds it. A graph that the fold cannot classify is refused here.
    if (graph_check) |gc| {
        if (result.verify_errors == 0) {
            const strict_checker: ?*const zts.StrictChecker = if (resolved.strict_checker) |*checker| checker else null;
            const folded = try gc.foldEntryEvidence(&result, json_mode, ir_view, strict_checker);
            if (folded == .refused) return result;
        }
    }

    // Stage 8: Contract. Untyped full analysis creates a separate real type
    // session only now. The contract borrows the completed session.
    var entry_effects: ?[]const zts.pipeline.ImportedEffect = null;
    defer if (entry_effects) |effects| allocator.free(effects);
    if (graph_check) |gc| {
        try gc.collectDependencies(.{
            .handler_path = handler_path,
            .source = source,
            .import_reader = opts.import_reader,
            .skip_contract = skip_contract,
            .json_mode = json_mode,
            .policy = live_policy,
            .sql_schema_path = sql_schema_path,
        });
        entry_effects = try gc.entryImportedEffects(try analysis.facts());
    }
    result.contract = try extractContractFromAnalysis(
        &analysis,
        handler_path,
        .{
            .verification = verify_info,
            .imported_effects = if (entry_effects) |effects|
                effects
            else if (imported_graph) |*graph|
                graph.imported_effects.items
            else
                &.{},
        },
    );
    try validateContractPolicyInputs(allocator, handler_path, &result.contract.?, sql_schema_path, null);
    if (graph_check) |gc| {
        // The contract of the build is the merge of the entry and each
        // dependency, so the policy and spec reports below read the same facts.
        const merged = try gc.mergeInto(&result, json_mode, &result.contract.?, env_public, handler_path);
        if (merged == .refused) {
            result.contract.?.deinit(allocator);
            result.contract = null;
            return result;
        }
    } else {
        try contract_mod.disclosePublicEnv(allocator, &result.contract.?, env_public);
    }
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
        applyContractFacts(allocator, c, .{ .verifier = .{
            .state_isolated = result.state_isolated,
            .shares_state = shares_state,
            .result_safe = result.results_safe,
            .optional_safe = result.optionals_safe,
            .state_write = state_write,
        } });
    }
    syncCheckResultProperties(&result);

    // Stage 9: Path generation + Stage 10: Fault coverage
    {
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
                applyContractFacts(allocator, c, .{ .paths = &path_analysis });
                // The cost facts of the paths came from the entry alone. The
                // dependencies decide what survives of them.
                if (graph_check) |gc| {
                    gc.foldProperties(c);
                    if (c.properties) |properties| result.max_io_depth = properties.max_io_depth;
                }
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
        const traces = try zts.proof_trace.collect(
            trace_arena.allocator(),
            c,
            flow_for_trace,
            defended_for_trace,
            ir_view,
            result.paths_enumerated,
            result.paths_exhaustive,
        );
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
        const trace_written = zts.proof_trace.writeJson(&aw.writer, traces);
        buf = aw.toArrayList();
        // An allocating writer fails only when it cannot allocate.
        trace_written catch return error.OutOfMemory;
        result.proof_trace_json = try allocator.dupe(u8, buf.items);
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
