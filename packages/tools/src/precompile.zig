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
pub const formatFailureSections = check_mod.formatFailureSections;
pub const generateTypeDefs = check_mod.generateTypeDefs;
const syncCheckResultProperties = check_mod.syncCheckResultProperties;
const appendSpecDiagnosticsJson = check_mod.appendSpecDiagnosticsJson;
pub const appendExportCapsuleDiagnostics = check_mod.appendExportCapsuleDiagnostics;
const appendCanonicalPublicHelperDiagnostics = check_mod.appendCanonicalPublicHelperDiagnostics;
const refreshContractSpecDiagnostics = check_mod.refreshContractSpecDiagnostics;

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

const imports_mod = @import("precompile_imports.zig");
pub const ImportReader = imports_mod.ImportReader;
pub const FlowModuleGraph = imports_mod.FlowModuleGraph;
pub const SourceScan = imports_mod.SourceScan;
pub const scanSource = imports_mod.scanSource;
const max_import_depth = imports_mod.max_import_depth;
const ImportedFile = imports_mod.ImportedFile;
const collectImportedFailableCalls = imports_mod.collectImportedFailableCalls;
const resolveCheckImportPath = imports_mod.resolveCheckImportPath;

const precompile_virtual_imports_mod = @import("precompile_virtual_imports.zig");
const precompile_check_run_mod = @import("precompile_check_run.zig");
const precompile_stderr_mod = @import("precompile_stderr.zig");
const precompile_contract_mod = @import("precompile_contract.zig");
const precompile_gen_tests_mod = @import("precompile_gen_tests.zig");
const precompile_cli_mod = @import("precompile_cli.zig");
const debugPrint = precompile_stderr_mod.debugPrint;
const printParseErrors = precompile_stderr_mod.printParseErrors;
const debugPrintStripError = precompile_stderr_mod.debugPrintStripError;
pub const reportSpecErrors = precompile_contract_mod.reportSpecErrors;
pub const main = precompile_cli_mod.main;
pub const runCompileWithArgs = precompile_cli_mod.runCompileWithArgs;
pub const CheckOptions = precompile_check_run_mod.CheckOptions;
pub const CheckedObserver = precompile_check_run_mod.CheckedObserver;
pub const CheckedView = precompile_check_run_mod.CheckedView;
pub const readFailureReason = precompile_stderr_mod.readFailureReason;
pub const runCheckOnlyWithOptions = precompile_check_run_mod.runCheckOnlyWithOptions;
const stampFaultCoverage = precompile_check_run_mod.stampFaultCoverage;
const summarizeGeneratedPaths = precompile_check_run_mod.summarizeGeneratedPaths;
const PathAnalysis = precompile_check_run_mod.PathAnalysis;
const applyContractFacts = precompile_check_run_mod.applyContractFacts;
pub const runCheckOnlyFromSourceWithOptions = precompile_check_run_mod.runCheckOnlyFromSourceWithOptions;
pub const runGenTests = precompile_gen_tests_mod.runGenTests;
const validateVirtualModuleImports = precompile_virtual_imports_mod.validateVirtualModuleImports;
const VirtualImportDiagnostic = precompile_virtual_imports_mod.VirtualImportDiagnostic;
const analyzeAot = precompile_contract_mod.analyzeAot;
const extractContractFromAnalysis = precompile_contract_mod.extractContractFromAnalysis;
const reportCompletedFlow = precompile_contract_mod.reportCompletedFlow;
const validateContractPolicyInputs = precompile_contract_mod.validateContractPolicyInputs;
const buildMultiModuleContract = precompile_contract_mod.buildMultiModuleContract;
pub const MultiModuleBuild = precompile_contract_mod.MultiModuleBuild;
pub const DependencyContracts = precompile_contract_mod.DependencyContracts;
pub const DependencyFacts = precompile_contract_mod.DependencyFacts;
pub const collectDependencyContracts = precompile_contract_mod.collectDependencyContracts;
pub const mergeDependencyContracts = precompile_contract_mod.mergeDependencyContracts;
pub const foldDependencyProperties = precompile_contract_mod.foldDependencyProperties;

/// Resolves a call site to a row of the acceptance kernel's guard catalog.
///
/// The row index is what the proof IR carries. The consumer looks the row up in
/// its own table, so nothing the producer writes about the module, the export,
/// or the argument position is taken as an answer.
const GuardResolver = struct {
    checker: ?*const zts.StrictChecker,
    view: zts.parser.IrView,
    atoms: *zts.AtomTable,

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
        return .{ .context = self, .resolve = resolve, .atoms = self.atoms };
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

    if (zts.classifySourcePath(filename) != .typescript) return error.UnsupportedSourceExtension;
    var diag_view = zts.SourceView.of(source);
    diag_view.name = filename;
    diag_view.normalize_positions = true;
    var strings = zts.StringTable.init(allocator);
    defer strings.deinit();
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = switch (try js_parser.parseAdmission()) {
        .accepted => |accepted| accepted,
        .parser_refused => |refusal| {
            printParseErrors(allocator, diag_view, js_parser.getProjectedErrors());
            return refusal.first_error;
        },
        .terminal_admission_refused => |failure| {
            const err = zts.prepareErrorForAdmissionFailure(failure);
            if (js_parser.getLastAdmissionObservation()) |diagnostic| {
                debugPrintStripError(filename, err, json_diag.stripDiagnosticFromAdmission(source, diagnostic));
            } else {
                debugPrintStripError(filename, err, null);
            }
            return err;
        },
        .recovered_admission_refused => unreachable,
    };

    try validateVirtualModuleImports(
        zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants),
        &atoms,
        filename,
        null,
    );

    // Check for file imports before proceeding with single-module compilation
    const has_file_imports = hasFileImports(zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants));

    if (has_file_imports) {
        if (!builtin.is_test) debugPrint("File imports detected, building module graph...\n", .{});
        return compileMultiModule(
            allocator,
            source,
            filename,
            &strings,
            &atoms,
            emit_contract,
            policy,
            sql_schema_path,
            manifest_registry,
            opts,
        );
    }

    const ir_view_check = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    try js_parser.type_store.validateRuntimeOwners(allocator, ir_view_check);
    var parsed = zts.pipeline.ParsedModule.fromTypedExisting(ir_view_check, root, &atoms, &js_parser.type_store);
    parsed.scopes = &js_parser.scopes;

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(
        allocator,
        parsed,
        .{
            .source_types = .direct,
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
    // reportCompletedFlow (flow violations), and the PathGenerator block (fault violations).
    var all_violations: std.ArrayList(zts.property_diagnostics.PropertyViolation) = .empty;
    defer {
        zts.property_diagnostics.deinitViolations(allocator, all_violations.items);
        all_violations.deinit(allocator);
    }

    // Run handler verification if requested
    var verify_info: ?VerificationInfo = null;
    var state_isolated: bool = false;
    var shares_state: bool = false;
    var state_write: ?handler_contract.PropertyCause = null;
    // result_safe and optional_safe default false (unproven) until verification runs and passes.
    var result_safe: bool = false;
    var optional_safe: bool = false;
    const handler_fn = zts.findHandlerFunction(ir_view_check, root);
    const env_public: []const []const u8 = if (policy) |*configured| configured.envPublic() else &.{};
    try analysis.prepareChecked(handler_fn, .{ .module_facts = try analysis.facts(), .env_public = env_public });
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
                    zts.property_diagnostics.writeViolationsJsonl(&vj_aw.writer, allocator, all_violations.items, handler_tests) catch |err| {
                        vj_aw.deinit();
                        return err;
                    };
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
            shares_state = verifier.has_module_mutation or verifier.unresolved_route_dispatch;
            state_isolated = !shares_state;

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

    defer code_gen.freeOwnedConstantPayloads();
    const func = try code_gen.generate(root);

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
            .atoms = &atoms,
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

    // Every compiled handler needs its contract for auto-sandboxing.
    // The contract reads its route table from the pattern analysis.
    var contract: ?HandlerContract = null;
    errdefer if (contract) |*built| built.deinit(allocator);
    {
        var route_analysis = try analyzeAot(allocator, &js_parser, &atoms, root);
        defer if (route_analysis) |*t| t.deinit(allocator);

        contract = try extractContractFromAnalysis(
            &analysis,
            filename,
            .{ .aot = route_analysis, .verification = verify_info },
        );
        // `extractContract` ran the flow pass and applied it to the contract.
        if (handler_fn != null) {
            const completed = try analysis.completedFlow();
            try reportCompletedFlow(
                allocator,
                completed,
                analysis.flowErrorCount(),
                true,
                &all_violations,
                ir_view_check,
            );
            // The verifier names the writes that it can read. The flow
            // evaluation joins the ones that it follows through a parameter, a
            // call result, or an element read, and a handler it cannot follow.
            const flow_shares_state = precompile_check_run_mod.flowSharesState(completed);
            if (emit_verify and flow_shares_state) {
                shares_state = true;
                state_isolated = false;
            }
            if (emit_verify and shares_state) {
                const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
                const unreported: []const precompile_check_run_mod.WriteSite = if (flow_shares_state)
                    try precompile_check_run_mod.unreportedWrites(allocator, completed, checked.verifierDiagnostics(), &.{})
                else
                    &.{};
                defer if (flow_shares_state) allocator.free(unreported);
                state_write = precompile_check_run_mod.firstWriteCause(ir_view_check, checked.verifierDiagnostics(), unreported, &.{}, null);
                for (unreported) |site| {
                    if (builtin.is_test) continue;
                    var output: std.ArrayList(u8) = .empty;
                    defer output.deinit(allocator);
                    var output_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
                    const flow_write = [_]zts.VerifierDiagnostic{precompile_check_run_mod.flowWriteDiagnostic(site)};
                    zts.DiagnosticProjection.writeAll(.verifier, diag_view, &flow_write, ir_view_check, &output_writer.writer) catch {};
                    output = output_writer.toArrayList();
                    if (output.items.len > 0) debugPrint("{s}", .{output.items});
                }
            }
        }
        try validateContractPolicyInputs(allocator, filename, &contract.?, sql_schema_path, policy);
        try precompile_contract_mod.disclosePublicEnv(allocator, &contract.?, env_public);

        // Inject verification-derived properties (Checks 2, 6, 7)
        try applyContractFacts(allocator, &contract.?, .{ .verifier = .{
            .state_isolated = state_isolated,
            .shares_state = shares_state,
            .result_safe = result_safe,
            .optional_safe = optional_safe,
            .state_write = state_write,
        } });
        try refreshContractSpecDiagnostics(allocator, &contract.?);
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
                defer jsonl_buf.deinit(allocator);
                var jsonl_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &jsonl_buf);
                const jsonl_written = gen.writeJsonl(&jsonl_aw.writer);
                jsonl_buf = jsonl_aw.toArrayList();
                // An allocating writer fails only when it cannot allocate.
                jsonl_written catch return error.OutOfMemory;
                generated_tests_jsonl = try jsonl_buf.toOwnedSlice(allocator);
            }

            var path_analysis: ?PathAnalysis = if (contract != null)
                try summarizeGeneratedPaths(allocator, &gen, true)
            else
                null;
            defer if (path_analysis) |*summary| summary.deinit(allocator);

            // Fault coverage analysis on generated paths
            var fc = zts.FaultCoverageChecker.init(allocator, gen.getTests());
            defer fc.deinit();
            try fc.analyze();
            const fc_report = fc.getReport();
            var fault_stamp = try stampFaultCoverage(allocator, ir_view_check, &gen, &fc);
            defer fault_stamp.deinit(allocator);

            // The check path and this path write the record and the property
            // bit for every handler through `applyContractFacts`. A handler
            // with no failable site holds `fault_covered` when the analysis
            // is complete.
            if (path_analysis) |*summary| {
                summary.takeFaultStamp(&fault_stamp);
                try applyContractFacts(allocator, &contract.?, .{ .paths = summary });
                // The path facts change cost_bounded and fault_covered, so the
                // ZTS500 must be discharged again against them.
                try refreshContractSpecDiagnostics(allocator, &contract.?);
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
                ) catch |err| {
                    viol_aw.deinit();
                    return err;
                };
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

/// True when the parsed IR has a file import declaration. The build and the
/// check share this predicate, so that both read the same graph.
pub fn hasFileImports(view: zts.IrView) bool {
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
    emit_contract: bool,
    policy: ?HandlerPolicy,
    sql_schema_path: ?[]const u8,
    manifest_registry: ?*const zts.ManifestRegistry,
    opts: CompileOptions,
) !CompiledHandler {
    // Build module graph
    var graph = zts.modules.ModuleGraph.init(allocator);
    defer graph.deinit();

    graph.build(filename, entry_source, readFilePosixForGraph) catch |err| {
        if (!builtin.is_test) {
            debugPrint("Module graph error: {}\n", .{err});
            var message_buffer: [1024]u8 = undefined;
            const message = graph.importRefusalMessage(&message_buffer);
            if (message.len > 0) debugPrint("{s}\n", .{message});
        }
        return err;
    };

    graph.checkBindings() catch |err| {
        var message_buffer: [1024]u8 = undefined;
        if (!builtin.is_test) debugPrint("{s}\n", .{graph.bindingRefusalMessage(&message_buffer)});
        return err;
    };

    if (!builtin.is_test) debugPrint("Module graph: {d} modules ({d} dependencies)\n", .{
        graph.module_list.items.len,
        graph.dependencyCount(),
    });

    // Compile all modules with shared atoms
    var module_compiler = zts.modules.ModuleCompiler.init(allocator, atoms, strings);
    module_compiler.record_witnesses = opts.emit_proof_evidence;
    var compile_result = module_compiler.compileAll(&graph) catch |err| {
        debugPrint("Multi-module compilation error: {}\n", .{err});
        return err;
    };
    defer compile_result.deinit();
    defer {
        for (compile_result.codegens) |*cg| cg.freeOwnedConstantPayloads();
    }

    // Each checked dependency leaves the signatures of its exports here, for
    // the modules that import it.
    var exports = zts.ExportedSignatures.init(allocator);
    defer exports.deinit();
    // Check every module, dependencies first and the entry last. Code
    // generation above already ran on the kept parsers, so no bytecode moves.
    // The module state facts fold over the whole graph for the contract.
    var shares_state = false;
    // The ZTS310 findings of the dependency verifier, by flow module id: the
    // position in execution order plus one, because the entry is module 0.
    var reported_writes: std.ArrayList(precompile_check_run_mod.WriteSite) = .empty;
    defer reported_writes.deinit(allocator);
    var evidences: std.ArrayList(zts.ProofEvidence) = .empty;
    defer {
        for (evidences.items) |*evidence| evidence.deinit();
        evidences.deinit(allocator);
    }
    for (0..compile_result.modules.len) |module_index| {
        var checks = try checkGraphModule(allocator, &graph, &compile_result, module_index, atoms, &exports, opts, null);
        defer checks.deinit(allocator);
        if (checks.evidence) |*evidence| {
            evidences.append(allocator, evidence.*) catch |err| {
                evidence.deinit();
                return err;
            };
        }
        if (checks.verify_failed) return .{ .verify_failed = true };
        for (checks.mutation_nodes) |node| {
            try reported_writes.append(allocator, .{ .module = @intCast(module_index + 1), .node = node });
        }
        if (checks.has_module_mutation or checks.unresolved_route_dispatch) shares_state = true;
    }

    // The evidence of each module folds into one program. A graph that the fold
    // cannot classify is refused here, with the entry file named.
    var proof_evidence: ?zts.ProofEvidence = null;
    errdefer if (proof_evidence) |*evidence| evidence.deinit();
    if (opts.emit_proof_evidence) {
        const entry_position = evidences.items.len - 1;
        proof_evidence = zts.foldProofEvidence(
            allocator,
            &evidences.items[entry_position],
            evidences.items[0..entry_position],
        ) catch |err| {
            if (!builtin.is_test) {
                var message_buffer: [256]u8 = undefined;
                debugPrint("{s}: {s}\n", .{ filename, foldRefusalMessage(&message_buffer, err) });
            }
            return err;
        };
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

    const contract = try buildMultiModuleContract(allocator, &graph, &compile_result, atoms, &exports, .{
        .filename = filename,
        .emit_contract = emit_contract,
        .emit_verify = opts.emit_verify,
        .strict = opts.strict,
        .policy = policy,
        .sql_schema_path = sql_schema_path,
        .manifest_registry = manifest_registry,
        .shares_state = shares_state,
        .reported_writes = reported_writes.items,
    });

    return .{
        .bytecode = entry_bytecode,
        .dep_bytecodes = dep_bytecodes,
        .contract = contract,
        .proof_evidence = proof_evidence,
    };
}

/// What the checks of one graph module leave for the caller. The contract
/// build folds the two state facts over the whole graph.
pub const GraphModuleChecks = struct {
    verify_failed: bool = false,
    has_module_mutation: bool = false,
    unresolved_route_dispatch: bool = false,
    /// The proof evidence of this module, when the caller asked for it. The
    /// caller owns it.
    evidence: ?zts.ProofEvidence = null,
    /// The node of each ZTS310 finding that the verifier made in this module, so
    /// a flow finding at the same node is not reported a second time. The caller
    /// frees it with `deinit`.
    mutation_nodes: []const ir.NodeIndex = &.{},

    pub fn deinit(self: *GraphModuleChecks, allocator: std.mem.Allocator) void {
        allocator.free(self.mutation_nodes);
        self.mutation_nodes = &.{};
    }
};

const max_assert_walk_depth: u16 = 1024;

/// True when a top-level statement of the program is an `assert`, in the
/// program body or in a block that is not inside a function. The walk stops at
/// each function and descends through the shared child map. A program nested
/// beyond the depth limit counts as holding one, so the walk fails closed.
fn hasTopLevelAssert(view: zts.IrView, node: ir.NodeIndex, depth: u16) bool {
    if (depth >= max_assert_walk_depth) return true;
    const tag = view.getTag(node) orelse return false;
    switch (tag) {
        .assert_stmt => return true,
        .function_decl, .function_expr, .arrow_function => return false,
        else => {
            var children = view.expressionChildren(node);
            while (children.next()) |child| {
                if (hasTopLevelAssert(view, child, depth + 1)) return true;
            }
            return false;
        },
    }
}

fn printGraphDiagnostics(
    allocator: std.mem.Allocator,
    owner: anytype,
    comptime formatFn: anytype,
    view: zts.SourceView,
) void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
    formatFn(owner, view, &writer.writer) catch {};
    output = writer.toArrayList();
    if (output.items.len > 0) debugPrint("{s}", .{output.items});
}

/// The message of a dependency that holds a top-level `assert`.
const dependency_assert_message = "a dependency may not hold a top-level assert, because a failed one leaves the later exports undefined";

/// The format of the refusal of a file import that has no type across modules.
/// It takes the imported name.
pub const untyped_import_format = "import '{s}' has no type that can cross modules. Export a non-generic function or a value with a declared type.";

/// The reason that `foldProofEvidence` refused a graph, in the words of the build.
pub fn foldRefusalMessage(buffer: []u8, err: error{ ModuleNotClassified, GraphResultLimit, OutOfMemory, ProgramTooDeep }) []const u8 {
    return std.fmt.bufPrint(buffer, "the proof evidence of the module graph does not fold: {s}", .{switch (err) {
        error.ModuleNotClassified => "a module holds a Result binding that the proof IR cannot classify",
        error.GraphResultLimit => "the modules bind more Results than one certificate carries",
        error.OutOfMemory => "out of memory",
        error.ProgramTooDeep => "a module nests deeper than the proof IR walk",
    }}) catch "the proof evidence of the module graph does not fold";
}

/// Where `checkGraphModule` reports when its caller is a check. A check reports
/// each finding as a coded diagnostic with the file at fault and keeps going to
/// the next stage of that module, where the build prints to stderr and stops.
/// The caller reads the counts after the call.
pub const GraphSink = struct {
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(json_diag.JsonDiagnostic),
    json_mode: bool,
    bool_errors: u32 = 0,
    bool_warnings: u32 = 0,
    type_errors: u32 = 0,
    strict_errors: u32 = 0,
    strict_warnings: u32 = 0,
    strict_advisories: u32 = 0,
    verify_errors: u32 = 0,
    verify_warnings: u32 = 0,
    link_errors: u32 = 0,

    pub fn errorTotal(self: *const GraphSink) u32 {
        return self.bool_errors + self.type_errors + self.strict_errors + self.verify_errors + self.link_errors;
    }

    /// Append one checker diagnostic of a module. Its position is read against
    /// the source of that module.
    pub fn appendChecker(
        self: *GraphSink,
        comptime source: zts.DiagnosticProjection.Source,
        diag: anytype,
        view: zts.IrView,
        path: []const u8,
        text: []const u8,
    ) !void {
        var projected = json_diag.fromCheckerDiagnostic(self.allocator, source, diag, view, path) orelse return;
        errdefer projected.deinit(self.allocator);
        try self.place(&projected, path, text);
        try self.diagnostics.append(self.allocator, projected);
    }

    /// Give a diagnostic its own copy of the path, and read its position
    /// against the source text.
    fn place(self: *GraphSink, projected: *json_diag.JsonDiagnostic, path: []const u8, text: []const u8) !void {
        projected.file = try self.allocator.dupe(u8, path);
        projected.file_owned = true;
        const mapped = (zts.SourceView{ .text = text, .normalize_positions = true }).position(projected.line, projected.column);
        projected.line = mapped.line;
        projected.column = mapped.column;
    }

    /// Append the coded refusal of a module that cannot join the program, and
    /// count it.
    pub fn appendLink(self: *GraphSink, kind: diagnostic_catalog.DriverKind, path: []const u8, message: []const u8) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        var refusal: json_diag.JsonDiagnostic = .{
            .code = diagnostic_catalog.driverCode(kind),
            .severity = "error",
            .message = owned_message,
            .file = path,
            .line = 1,
            .column = 1,
            .suggestion = null,
            .message_owned = true,
        };
        errdefer refusal.deinit(self.allocator);
        refusal.file = try self.allocator.dupe(u8, path);
        refusal.file_owned = true;
        try self.diagnostics.append(self.allocator, refusal);
        self.link_errors += 1;
        if (!self.json_mode and !builtin.is_test) debugPrint("{s}: {s} {s}\n", .{ path, refusal.code, message });
    }
};

/// Run on one module of a loaded graph the checks that the single-module path
/// runs on its only module: virtual import validation, the boolean, type, and
/// strict checks, the verifier, and the bytecode verifier. `module_index`
/// counts in execution order, so dependencies come first and the entry last.
///
/// A dependency has no handler, so it gets the module verifier. It is exempt
/// from ZTS061 alone, because a dependency exports functions by nature, and it
/// may not hold a top-level `assert`: a failed one ends module initialization
/// and leaves the later exports undefined.
///
/// With no `sink` the findings print to stderr and the first refusal returns an
/// error, as the build needs. With a `sink` each finding is a coded diagnostic,
/// the boolean, type, and strict stages all report before the refusal, and an
/// error that the sink counted needs no message from the caller.
pub fn checkGraphModule(
    allocator: std.mem.Allocator,
    graph: *const zts.modules.ModuleGraph,
    compile_result: *const zts.modules.CompileResult,
    module_index: usize,
    atoms: *zts.AtomTable,
    exports: *zts.ExportedSignatures,
    opts: CompileOptions,
    sink: ?*GraphSink,
) !GraphModuleChecks {
    const is_entry = module_index == compile_result.modules.len - 1;
    const module = &graph.module_list.items[graph.execution_order[module_index]];
    const parser = &compile_result.parsers[module_index];
    const compiled = &compile_result.modules[module_index];
    const root = compiled.root;
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);
    var diag_view = zts.SourceView.of(module.source);
    diag_view.name = module.path;
    diag_view.normalize_positions = true;

    var import_diagnostic: ?VirtualImportDiagnostic = null;
    validateVirtualModuleImports(view, atoms, module.path, if (sink != null) &import_diagnostic else null) catch |err| {
        if (sink) |s| {
            s.link_errors += 1;
            if (s.json_mode) if (import_diagnostic) |found| {
                var projected = try precompile_virtual_imports_mod.virtualImportJsonDiagnostic(allocator, found, module.path);
                errdefer projected.deinit(allocator);
                try s.place(&projected, module.path, module.source);
                try s.diagnostics.append(allocator, projected);
            };
        }
        return err;
    };

    // What this module knows of its file imports: the signature or value type
    // that the checked target module exports under the imported name, or none.
    var link_arena = std.heap.ArenaAllocator.init(allocator);
    defer link_arena.deinit();
    const file_imports = try precompile_contract_mod.fileImportSignatures(link_arena.allocator(), graph, module.path, view, atoms, exports);

    if (!is_entry and hasTopLevelAssert(view, root, 0)) {
        if (sink) |s| {
            try s.appendLink(.module_link_refused, module.path, dependency_assert_message);
        } else if (!builtin.is_test) debugPrint("{s}: " ++ dependency_assert_message ++ "\n", .{module.path});
        return error.DependencyTopLevelAssert;
    }

    var parsed = zts.pipeline.ParsedModule.fromTypedExisting(view, root, atoms, &parser.type_store);
    parsed.scopes = &parser.scopes;
    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(allocator, parsed, .{
        .source_types = .direct,
        .strict = opts.strict,
        .manifest_registry = opts.manifest_registry,
        .policy_sections = if (opts.policy) |*configured| configured.declaredSections() else .{},
        .select_verifier = opts.emit_verify,
        .select_flow = false,
        .allow_raw_exported_boundary = !is_entry,
        .file_import_signatures = &file_imports,
    });
    defer analysis.deinit();
    try analysis.complete();
    const resolved = try analysis.resolvedForReport();

    // A file import with no type that crosses a module would hand the later
    // checks a value they cannot read, so the build stops here.
    const untyped_checker = if (resolved.type_checker) |*checker| checker else return error.AnalysisPassIncomplete;
    if (untyped_checker.firstUntypedFileImport()) |name| {
        if (sink) |s| {
            const message = try allocator.print(untyped_import_format, .{name});
            defer allocator.free(message);
            try s.appendLink(.file_import_untyped, module.path, message);
        } else if (!builtin.is_test) debugPrint("{s}: " ++ untyped_import_format ++ "\n", .{ module.path, name });
        analysis.refuseResolution();
        return error.FileImportUntyped;
    }

    // One message per node: a boolean or strict diagnostic under a node that
    // has a type error repeats it.
    if (sink != null) resolved.dropRepeatsOfTypeErrors();

    const bool_diags = resolved.boolDiagnostics();
    if (sink) |s| {
        s.bool_errors += @intCast(resolved.bool_error_count);
        s.bool_warnings += @intCast(bool_diags.len -| resolved.bool_error_count);
        if (s.json_mode) {
            for (bool_diags) |diag| try s.appendChecker(.boolean, diag, view, module.path, module.source);
        } else if (bool_diags.len > 0 and !builtin.is_test) {
            printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatBoolDiagnostics, diag_view);
        }
    } else {
        if (bool_diags.len > 0 and !builtin.is_test) {
            debugPrint("\n", .{});
            printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatBoolDiagnostics, diag_view);
            debugPrint("{d} boolean check error(s), {d} warning(s)\n", .{
                resolved.bool_error_count,
                bool_diags.len - resolved.bool_error_count,
            });
        }
        if (resolved.bool_error_count > 0) {
            analysis.refuseResolution();
            if (!builtin.is_test) debugPrint("\nBoolean check failed for {s}\n", .{module.path});
            return error.SoundModeViolation;
        }
    }

    if (sink) |s| {
        s.type_errors += @intCast(resolved.typeErrorCount());
        if (s.json_mode) {
            for (resolved.typeDiagnostics()) |diag| try s.appendChecker(.type, diag, view, module.path, module.source);
        } else if (resolved.typeDiagnostics().len > 0 and !builtin.is_test) {
            printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatTypeDiagnostics, diag_view);
        }
    } else {
        if (resolved.typeDiagnostics().len > 0 and !builtin.is_test) {
            printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatTypeDiagnostics, diag_view);
        }
        if (resolved.typeErrorCount() > 0) {
            analysis.refuseResolution();
            if (!builtin.is_test) debugPrint("\nType check failed for {s}\n", .{module.path});
            return error.SoundModeViolation;
        }
    }

    if (resolved.strict_checker != null) {
        const strict_diags = resolved.strictDiagnostics();
        if (sink) |s| {
            s.strict_errors += @intCast(resolved.strict_error_count);
            for (strict_diags) |diag| {
                switch (diag.severity) {
                    .err => {},
                    .warning => s.strict_warnings += 1,
                    .advisory => s.strict_advisories += 1,
                }
                try s.appendChecker(.strict, diag, view, module.path, module.source);
            }
            if (!s.json_mode and strict_diags.len > 0 and !builtin.is_test) {
                printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatStrictDiagnostics, diag_view);
            }
        } else {
            if (strict_diags.len > 0 and !builtin.is_test) {
                printGraphDiagnostics(allocator, resolved, zts.pipeline.ResolvedModule.formatStrictDiagnostics, diag_view);
            }
            if (resolved.strict_error_count > 0) {
                analysis.refuseResolution();
                if (!builtin.is_test) debugPrint("\nStrict check failed for {s}\n", .{module.path});
                return error.SoundModeViolation;
            }
        }
    }
    if (sink) |s| {
        if (s.bool_errors + s.type_errors + s.strict_errors > 0) {
            analysis.refuseResolution();
            return error.SoundModeViolation;
        }
    }

    if (!is_entry) {
        const checker = if (resolved.type_checker) |*checker| checker else return error.AnalysisPassIncomplete;
        try checker.recordExportedSignatures(root, graph.execution_order[module_index], exports);
    }

    var checks: GraphModuleChecks = .{};
    errdefer checks.deinit(allocator);
    if (opts.emit_verify) {
        const handler_fn = if (is_entry) findHandlerFunction(view, root) else null;
        const facts = try analysis.facts();
        var error_count: u32 = 0;
        var ran = false;
        if (is_entry) {
            if (handler_fn) |hf| {
                try analysis.prepareChecked(hf, .{ .module_facts = facts });
                error_count = try analysis.runVerifier(hf);
                ran = true;
            } else if (!builtin.is_test) {
                debugPrint("Warning: no handler function found for verification\n", .{});
            }
        } else {
            error_count = try analysis.runModuleVerifier(.{ .module_facts = facts });
            ran = true;
        }
        if (ran) {
            const checked = analysis.checkedModule() orelse return error.AnalysisPassIncomplete;
            const diags = checked.verifierDiagnostics();
            if (sink) |s| {
                s.verify_errors += error_count;
                s.verify_warnings += @intCast(diags.len -| error_count);
                if (s.json_mode) {
                    for (diags) |diag| try s.appendChecker(.verifier, diag, view, module.path, module.source);
                } else if (diags.len > 0 and !builtin.is_test) {
                    printGraphDiagnostics(allocator, &checked.verifier, zts.HandlerVerifier.formatDiagnostics, diag_view);
                }
            } else if (diags.len > 0 and !builtin.is_test) {
                debugPrint("\n", .{});
                printGraphDiagnostics(allocator, &checked.verifier, zts.HandlerVerifier.formatDiagnostics, diag_view);
                debugPrint("{d} error(s), {d} warning(s)\n", .{ error_count, diags.len - error_count });
            }
            var mutation_nodes: std.ArrayList(ir.NodeIndex) = .empty;
            errdefer mutation_nodes.deinit(allocator);
            for (diags) |diag| {
                if (diag.kind == .module_scope_mutation) try mutation_nodes.append(allocator, diag.node);
            }
            checks.mutation_nodes = try mutation_nodes.toOwnedSlice(allocator);
            checks.has_module_mutation = checked.verifier.has_module_mutation;
            checks.unresolved_route_dispatch = checked.verifier.unresolved_route_dispatch;
            if (error_count > 0) {
                if (sink == null and !builtin.is_test) debugPrint("\nVerification failed for {s}\n", .{module.path});
                checks.verify_failed = true;
                return checks;
            }
        }
    }

    try verifyModuleBytecode(module.path, &compiled.func);

    if (opts.emit_proof_evidence) {
        checks.evidence = try moduleProofEvidence(
            allocator,
            view,
            root,
            &compile_result.recorders[module_index],
            if (resolved.strict_checker) |*checker| checker else null,
            atoms,
            module.path,
            is_entry,
        );
    }
    return checks;
}

/// Verify the bytecode of one module. A refusal prints the module path.
pub fn verifyModuleBytecode(module_path: []const u8, func: *const zts.FunctionBytecode) !void {
    const verified = zts.BytecodeVerifier.verify(func);
    if (!verified.valid) {
        debugPrint("Bytecode verification failed for {s} at offset {d}: {s}\n", .{
            module_path,
            verified.offset,
            verified.message,
        });
        return error.BytecodeVerificationFailed;
    }
}

/// The proof evidence of one module of a loaded graph. The proof IR of this
/// module is lowered from the parse that code generation just walked, while its
/// witnesses still name parser nodes. A dependency has no handler. Its guards
/// resolve against its own strict checker, so the resolver and the module stay
/// together. The caller owns the evidence.
pub fn moduleProofEvidence(
    allocator: std.mem.Allocator,
    view: zts.IrView,
    root: ir.NodeIndex,
    recorder: *zts.TranslationRecorder,
    strict_checker: ?*const zts.StrictChecker,
    atoms: *zts.AtomTable,
    module_path: []const u8,
    is_entry: bool,
) !zts.ProofEvidence {
    recorder.check() catch |err| {
        debugPrint("{s}: translation evidence is incomplete ({s}); refusing to emit a proof certificate\n", .{ module_path, @errorName(err) });
        return error.TranslationWitnessIncomplete;
    };
    const handler_source: ?ir.NodeIndex = if (is_entry)
        findHandlerFunction(view, root) orelse return error.HandlerNotFound
    else
        null;
    var guard_resolver = GuardResolver{
        .checker = strict_checker,
        .view = view,
        .atoms = atoms,
    };
    return zts.buildProofEvidence(
        allocator,
        view,
        root,
        handler_source,
        recorder,
        guard_resolver.resolver(),
    );
}

const readFilePosixForGraph = zts.file_io.readFileForModuleGraph;

const findHandlerFunction = zts.findHandlerFunction;

/// Derive contract.json path from the output .zig path.
const deriveSiblingPath = util.deriveSiblingPath;

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
        \\export function handler(req: Request): Response {
        \\  return Response.text(readSecret());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readSecret(): string {
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

test "compileHandler proves no_secret_leakage for a name only when the policy lists it in env.public" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Response {
        \\  return Response.text(env("APP_NAME") ?? "zttp");
        \\}
    ;

    var allow_only = try handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"APP_NAME\"]}}");
    defer allow_only.deinit(allocator);
    var refused = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .policy = allow_only });
    defer refused.deinit(allocator);
    const refused_contract = refused.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(!refused_contract.properties.?.no_secret_leakage);
    try std.testing.expectEqual(@as(usize, 0), refused_contract.env.public.items.len);

    var listed = try handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}");
    defer listed.deinit(allocator);
    var held = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .policy = listed });
    defer held.deinit(allocator);
    const held_contract = held.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(held_contract.properties.?.no_secret_leakage);
    try std.testing.expectEqual(@as(usize, 1), held_contract.env.public.items.len);
    try std.testing.expectEqualStrings("APP_NAME", held_contract.env.public.items[0]);

    // No policy at all is the conservative case.
    var bare = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true });
    defer bare.deinit(allocator);
    try std.testing.expect(!bare.contract.?.properties.?.no_secret_leakage);
}

test "compileHandler discloses env.public in the merged contract of a file-import graph" {
    const entry_source =
        \\import { readName } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(readName());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readName(): string {
        \\  return env("APP_NAME") ?? "";
        \\}
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts", dep_source);

    const allocator = std.testing.allocator;
    var policy = try handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}");
    defer policy.deinit(allocator);
    var compiled = try fixture.compile(.{ .emit_contract = true, .policy = policy });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), contract.env.public.items.len);
    try std.testing.expectEqualStrings("APP_NAME", contract.env.public.items[0]);
}

test "compileHandler carries loaded graph effects into the merged properties" {
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
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.pure);
    try std.testing.expect(!props.read_only);
    try std.testing.expect(!props.stateless);
    try std.testing.expect(!props.retry_safe);
}

test "multi-module compile without verification extracts the flow facts and no isolation fact" {
    const deploy_manifest = @import("deploy_manifest.zig");
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

    const allocator = std.testing.allocator;
    var compiled = try fixture.compile(.{ .emit_contract = true });
    defer compiled.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
    const merged = compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(merged.properties != null);

    const extracted = try deploy_manifest.extractProvenFacts(allocator, &merged);
    defer allocator.free(extracted.routes_buf);

    // No verifier ran, so state isolation is unproven. The flow evaluation
    // follows the whole graph without verification, as for a single module.
    try std.testing.expect(!extracted.facts.state_isolated);
    try std.testing.expect(extracted.facts.injection_safe);
    try std.testing.expect(extracted.facts.deterministic);
    try std.testing.expect(extracted.facts.no_secret_leakage);
    try std.testing.expect(extracted.facts.no_credential_leakage);
    try std.testing.expect(extracted.facts.input_validated);
    try std.testing.expect(extracted.facts.pii_contained);
}

test "multi-module compile extracts the proven facts of a verified graph" {
    const deploy_manifest = @import("deploy_manifest.zig");
    var fixture = try importFixture(capsuleEntry("no_secret_leakage"),
        \\export function f(): string {
        \\  return "x";
        \\}
        \\
    );
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const merged = compiled.contract orelse return error.TestUnexpectedResult;
    const extracted = try deploy_manifest.extractProvenFacts(allocator, &merged);
    defer allocator.free(extracted.routes_buf);
    try std.testing.expectEqual(@as(@TypeOf(extracted.facts.proof_level), .complete), extracted.facts.proof_level);
    try std.testing.expect(extracted.facts.retry_safe);
    try std.testing.expect(extracted.facts.read_only);
    try std.testing.expect(extracted.facts.injection_safe);
    try std.testing.expect(extracted.facts.idempotent);
    try std.testing.expect(extracted.facts.state_isolated);
    try std.testing.expect(extracted.facts.deterministic);
    try std.testing.expect(extracted.facts.no_secret_leakage);
    try std.testing.expect(extracted.facts.no_credential_leakage);
    try std.testing.expect(extracted.facts.input_validated);
    try std.testing.expect(extracted.facts.pii_contained);
    try std.testing.expect(extracted.facts.results_safe);
    try std.testing.expect(extracted.facts.fault_covered);
}

test "compileHandler rejects disallowed policy from imported module" {
    const entry_source =
        \\import { readSecret } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(readSecret());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readSecret(): string {
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

// ---------------------------------------------------------------------------
// Unit G3: the contract of a graph build holds each property across the graph.
// ---------------------------------------------------------------------------

const graph_verified: CompileOptions = .{ .emit_verify = true, .emit_contract = true };

fn graphProperties(compiled: *const CompiledHandler) !handler_contract.HandlerProperties {
    const contract = compiled.contract orelse return error.MissingContract;
    return contract.properties orelse error.MissingProperties;
}

const secret_dep =
    \\import { env } from "zttp:env";
    \\export function f(): string {
    \\  return env("SECRET_KEY") ?? "";
    \\}
    \\
;

fn capsuleEntry(comptime capsule: []const u8) []const u8 {
    return "import { f } from \"./dep.ts\";\n" ++
        "export function handler(req: Request): Proof<Response, \"" ++ capsule ++ "\"> {\n" ++
        "  return Response.text(f());\n}\n";
}

test "compileHandler graph holds no_secret_leakage for a clean graph" {
    var fixture = try importFixture(capsuleEntry("no_secret_leakage"),
        \\export function f(): string {
        \\  return "hello";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(props.no_secret_leakage);
    try std.testing.expectEqual(@as(usize, 0), compiled.contract.?.spec_diagnostics.items.len);
}

test "compileHandler graph clears no_secret_leakage when a dependency secret reaches the response" {
    var fixture = try importFixture(capsuleEntry("result_safe"), secret_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.no_secret_leakage);
}

const label_entry =
    \\import { label } from "./dep.ts";
    \\export function handler(req: Request): Proof<Response, "result_safe"> {
    \\  return Response.text(label);
    \\}
    \\
;

test "compileHandler graph keeps the flow properties for a const data export" {
    var fixture = try importFixture(label_entry,
        \\export const label: string = "x";
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(props.no_secret_leakage);
    try std.testing.expect(props.no_credential_leakage);
    try std.testing.expect(props.injection_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.state_isolated);
}

test "compileHandler graph refuses a let data export before the evaluator sees it" {
    var fixture = try importFixture(label_entry,
        \\export let label: string = "x";
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.MutableExport, fixture.compile(graph_verified));
}

test "compileHandler graph carries the secret label through a const data export" {
    var fixture = try importFixture(
        \\import { key } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(key);
        \\}
        \\
    ,
        \\import { env } from "zttp:env";
        \\export const key: string = env("SECRET_KEY") ?? "";
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.no_secret_leakage);
}

test "compileHandler graph clears state_isolated for a write through an imported const array" {
    var fixture = try importFixture(
        \\import { seen } from "./dep.ts";
        \\function pick(): number[] {
        \\  return seen;
        \\}
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const alias = pick();
        \\  alias.push(1);
        \\  return Response.text("ok");
        \\}
        \\
    ,
        \\export const seen: number[] = [];
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.state_isolated);
}

const record_entry =
    \\import { record } from "./dep.ts";
    \\export function handler(req: Request): Proof<Response, "result_safe"> {
    \\  record();
    \\  return Response.text("ok");
    \\}
    \\
;

test "compileHandler graph clears state_isolated when a dependency pushes onto its own module array" {
    var fixture = try importFixture(record_entry,
        \\const seen: number[] = [];
        \\export function record(): undefined {
        \\  seen.push(1);
        \\  return undefined;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.state_isolated);
}

test "compileHandler graph clears state_isolated for a dependency push that only the flow evaluator finds" {
    var fixture = try importFixture(record_entry,
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\export function record(): undefined {
        \\  addTo(seen);
        \\  return undefined;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.state_isolated);
}

const add_to_helper =
    \\export function addTo(xs: number[]): undefined {
    \\  xs.push(1);
    \\  return undefined;
    \\}
    \\
;

test "compileHandler graph clears state_isolated when an imported helper writes an imported array passed to it" {
    var fixture = try importFixture(
        \\import { seen } from "./dep.ts";
        \\import { addTo } from "./helpers.ts";
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  addTo(seen);
        \\  return Response.text("ok");
        \\}
        \\
    ,
        \\export const seen: number[] = [];
        \\
    );
    defer fixture.deinit();
    try fixture.add("helpers.ts", add_to_helper);
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.state_isolated);
}

test "compileHandler graph keeps state_isolated when an imported helper writes a request-local array" {
    var fixture = try importFixture(
        \\import { addTo } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  const local: number[] = [];
        \\  addTo(local);
        \\  return Response.text("ok");
        \\}
        \\
    , add_to_helper);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(props.state_isolated);
}

const table_entry =
    \\import { table } from "./dep.ts";
    \\export function handler(req: Request): Proof<Response, "result_safe"> {
    \\  return Response.text(String(table.length));
    \\}
    \\
;

test "compileHandler graph keeps state_isolated when a dependency writes a local array during module initialization" {
    var local_fixture = try importFixture(table_entry,
        \\function build(): number[] {
        \\  const out: number[] = [];
        \\  out.push(1);
        \\  return out;
        \\}
        \\export const table: number[] = build();
        \\
    );
    defer local_fixture.deinit();
    var local_compiled = try local_fixture.compile(graph_verified);
    defer local_compiled.deinit(std.testing.allocator);
    try std.testing.expect((try graphProperties(&local_compiled)).state_isolated);
}

// The verifier names the push inside `build` whether or not a request runs it,
// so a write during initialization alone still removes state_isolated.
test "compileHandler graph clears state_isolated for a dependency helper that writes its module array during initialization" {
    var module_fixture = try importFixture(table_entry,
        \\const log: number[] = [];
        \\function build(): number[] {
        \\  log.push(1);
        \\  return log;
        \\}
        \\export const table: number[] = build();
        \\
    );
    defer module_fixture.deinit();
    var module_compiled = try module_fixture.compile(graph_verified);
    defer module_compiled.deinit(std.testing.allocator);
    try std.testing.expect(!(try graphProperties(&module_compiled)).state_isolated);
}

const entry_write_entry =
    \\import { value } from "./dep.ts";
    \\const seen: number[] = [];
    \\function pick(): number[] {
    \\  return seen;
    \\}
    \\export function handler(req: Request): Response {
    \\  const alias = pick();
    \\  alias.push(1);
    \\  return Response.text(String(value()));
    \\}
    \\
;

test "compileHandler graph names the entry write that removed state_isolated" {
    var fixture = try importFixture(entry_write_entry,
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expect(!(try graphProperties(&compiled)).state_isolated);
    const cause = contract.property_provenance.state_write orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 8), cause.line);
    try std.testing.expectEqual(@as(u32, 13), cause.column);
    try std.testing.expectEqualStrings("a write to module state", cause.snippet);
    try std.testing.expect(contract.property_provenance.state_write_removed.contains(.state_isolated));
}

test "compileHandler graph names the flow-only write of a dependency as the cause" {
    const allocator = std.testing.allocator;
    var fixture = try importFixture(record_entry,
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\export function record(): undefined {
        \\  addTo(seen);
        \\  return undefined;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expect(!(try graphProperties(&compiled)).state_isolated);
    const dep_path = try fixtureFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const cause = contract.property_provenance.state_write orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(dep_path, cause.file orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u32, 3), cause.line);
    try std.testing.expectEqual(@as(u32, 10), cause.column);
    try std.testing.expectEqualStrings("a write to module state", cause.snippet);
    try std.testing.expect(contract.property_provenance.state_write_removed.contains(.state_isolated));
}

fn fixtureFilePath(fixture: *const CompileGraphFixture, name: []const u8) ![]u8 {
    const directory = std.fs.path.dirname(fixture.entry_path) orelse return error.TestUnexpectedResult;
    return std.fs.path.join(std.testing.allocator, &.{ directory, name });
}

/// The suggestion of the implicit default-profile row, which a graph compile
/// keeps when the handler returns no capsule.
fn defaultProfileSuggestion(compiled: *const CompiledHandler) ![]const u8 {
    const contract = compiled.contract orelse return error.MissingContract;
    for (contract.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.implicit_default) return diagnostic.suggestion orelse error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

const bump_default_entry =
    \\import { bump } from "./dep.ts";
    \\export function handler(req: Request): Response {
    \\  return Response.text(String(bump()));
    \\}
    \\
;

const bump_dep =
    \\let count = 0;
    \\
    \\export function bump(): number {
    \\  count = count + 1;
    \\  return count;
    \\}
    \\
;

test "compileHandler graph names the write of a dependency in the default-profile suggestion" {
    const allocator = std.testing.allocator;
    var fixture = try importFixture(bump_default_entry, bump_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const dep_path = try fixtureFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 4 removes deterministic, idempotent, read_only, retry_safe, state_isolated, stateless. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, try defaultProfileSuggestion(&compiled), ending));
}

test "compileHandler graph names the uncalled writer of a dependency in a graph with no capsule" {
    const allocator = std.testing.allocator;
    var fixture = try importFixture(
        \\import { bump } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
        \\
    , bump_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const dep_path = try fixtureFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 4 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, try defaultProfileSuggestion(&compiled), ending));
}

test "compileHandler graph names the entry write when the entry and a dependency both write module state" {
    const allocator = std.testing.allocator;
    var fixture = try importFixture(
        \\import { bump } from "./dep.ts";
        \\let hits = 0;
        \\function mark(): number {
        \\  hits = hits + 1;
        \\  return hits;
        \\}
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(mark() + bump()));
        \\}
        \\
    , bump_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const cause = contract.property_provenance.state_write orelse return error.TestUnexpectedResult;
    try std.testing.expect(cause.file == null);
    try std.testing.expectEqual(@as(u32, 4), cause.line);
    try std.testing.expectEqual(@as(u32, 8), cause.column);
}

test "compileHandler graph names the write of the dependency that runs first" {
    const allocator = std.testing.allocator;
    var fixture = try CompileGraphFixture.init("entry.ts",
        \\import { bumpA } from "./a.ts";
        \\import { bumpB } from "./b.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bumpA() + bumpB()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { base } from "./b.ts";
        \\let hitsA = 0;
        \\export function bumpA(): number {
        \\  hitsA = hitsA + 1;
        \\  return hitsA + base();
        \\}
        \\
    );
    try fixture.add("b.ts",
        \\let hitsB = 0;
        \\
        \\export function base(): number {
        \\  return 1;
        \\}
        \\
        \\export function bumpB(): number {
        \\  hitsB = hitsB + 1;
        \\  return hitsB;
        \\}
        \\
    );
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const dep_path = try fixtureFilePath(&fixture, "b.ts");
    defer allocator.free(dep_path);
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 8 removes deterministic, idempotent, read_only, retry_safe, state_isolated, stateless. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, try defaultProfileSuggestion(&compiled), ending));
}

test "compileHandler graph names the flow-only write of a dependency that comes before a verifier write" {
    const allocator = std.testing.allocator;
    var fixture = try importFixture(
        \\import { record } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(record()));
        \\}
        \\
    ,
        \\const seen: number[] = [];
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\let count = 0;
        \\export function record(): number {
        \\  addTo(seen);
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(allocator);
    const dep_path = try fixtureFilePath(&fixture, "dep.ts");
    defer allocator.free(dep_path);
    const ending = try std.fmt.allocPrint(
        allocator,
        " The write to module state at `{s}` line 3 removes deterministic, idempotent, read_only, retry_safe, state_isolated, stateless. To keep them, remove every write to module state that a ZTS310 row names.",
        .{dep_path},
    );
    defer allocator.free(ending);
    try std.testing.expect(std.mem.endsWith(u8, try defaultProfileSuggestion(&compiled), ending));
}

test "compileHandler graph keeps the one-file default-profile sentence for a write in the entry" {
    const allocator = std.testing.allocator;
    var compiled = try compileHandler(allocator,
        \\let count = 0;
        \\
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(bump()));
        \\}
        \\
    , "single.ts", graph_verified);
    defer compiled.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(
        u8,
        try defaultProfileSuggestion(&compiled),
        " The write to module state at line 4 removes deterministic, idempotent, pure, read_only, retry_safe, state_isolated, stateless. To keep them, copy the value into a local before the write, or move the state to zttp:cache.",
    ));
}

const LoadedFlowGraph = struct {
    graph: zts.modules.ModuleGraph,
    strings: zts.StringTable,
    atoms: zts.AtomTable,
    compile_result: zts.modules.CompileResult,
    flow: FlowModuleGraph,

    fn load(self: *LoadedFlowGraph, fixture: *const CompileGraphFixture) !void {
        const allocator = std.testing.allocator;
        self.graph = zts.modules.ModuleGraph.init(allocator);
        errdefer self.graph.deinit();
        try self.graph.build(fixture.entry_path, fixture.entry_source, readFilePosixForGraph);
        self.strings = zts.StringTable.init(allocator);
        errdefer self.strings.deinit();
        self.atoms = zts.AtomTable.init(allocator);
        errdefer self.atoms.deinit();
        var module_compiler = zts.modules.ModuleCompiler.init(allocator, &self.atoms, &self.strings);
        self.compile_result = try module_compiler.compileAll(&self.graph);
        errdefer self.compile_result.deinit();
        self.flow = try imports_mod.flowModulesForGraph(allocator, &self.graph, &self.compile_result, &self.atoms);
    }

    fn deinit(self: *LoadedFlowGraph) void {
        self.flow.deinit();
        for (self.compile_result.codegens) |*cg| cg.freeOwnedConstantPayloads();
        self.compile_result.deinit();
        self.atoms.deinit();
        self.strings.deinit();
        self.graph.deinit();
    }
};

test "flow modules of a graph with a const data export are complete" {
    var fixture = try importFixture(label_entry,
        \\export const label: string = "x";
        \\
    );
    defer fixture.deinit();
    var loaded: LoadedFlowGraph = undefined;
    try loaded.load(&fixture);
    defer loaded.deinit();
    try std.testing.expect(loaded.flow.complete);
}

test "flow modules of a graph with function exports are complete" {
    var fixture = try importFixture(capsuleEntry("result_safe"),
        \\export function f(): string {
        \\  return "hello";
        \\}
        \\
    );
    defer fixture.deinit();
    var loaded: LoadedFlowGraph = undefined;
    try loaded.load(&fixture);
    defer loaded.deinit();
    try std.testing.expect(loaded.flow.complete);
    try std.testing.expectEqual(@as(usize, 2), loaded.flow.views.items.len);
    try std.testing.expectEqualSlices(zts.pipeline.FlowModuleId, &.{ 1, 0 }, loaded.flow.initialization_order.items);
}

const diamond_entry =
    \\import { a } from "./a.ts";
    \\import { b } from "./b.ts";
    \\export function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  return Response.text([a(), b()].join(""));
    \\}
    \\
;

fn addDiamond(fixture: *CompileGraphFixture) !void {
    try fixture.add("a.ts",
        \\import { c } from "./c.ts";
        \\export function a(): string {
        \\  return c();
        \\}
        \\
    );
    try fixture.add("b.ts",
        \\import { c } from "./c.ts";
        \\export function b(): string {
        \\  return c();
        \\}
        \\
    );
    try fixture.add("c.ts",
        \\export function c(): string {
        \\  return "c";
        \\}
        \\
    );
}

test "flow modules of a diamond graph initialize the shared dependency once" {
    var fixture = try CompileGraphFixture.init("entry.ts", diamond_entry);
    defer fixture.deinit();
    try addDiamond(&fixture);
    var loaded: LoadedFlowGraph = undefined;
    try loaded.load(&fixture);
    defer loaded.deinit();
    try std.testing.expect(loaded.flow.complete);
    try std.testing.expectEqual(@as(usize, 4), loaded.flow.views.items.len);
    try std.testing.expectEqualSlices(zts.pipeline.FlowModuleId, &.{ 1, 2, 3, 0 }, loaded.flow.initialization_order.items);
}

test "compileHandler graph holds no_secret_leakage over a diamond graph" {
    var fixture = try CompileGraphFixture.init("entry.ts", diamond_entry);
    defer fixture.deinit();
    try addDiamond(&fixture);
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), compiled.dep_bytecodes.?.len);
    try std.testing.expect((try graphProperties(&compiled)).no_secret_leakage);
}

test "compileHandler graph refuses a dependency call outside the entry Effects ceiling" {
    var fixture = try importFixture(
        \\import { f } from "./dep.ts";
        \\export function handler(req: Request): Effects<Response, "crypto"> {
        \\  return Response.text(f());
        \\}
        \\
    , secret_dep);
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph clears state_isolated when a dependency mutates module state" {
    var fixture = try importFixture(capsuleEntry("result_safe"),
        \\let count: number = 0;
        \\export function f(): string {
        \\  count = count + 1;
        \\  return String(count);
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(!(try graphProperties(&compiled)).state_isolated);
}

test "compileHandler graph holds state_isolated when no module mutates state" {
    var fixture = try importFixture(capsuleEntry("state_isolated"),
        \\export function f(): string {
        \\  return "x";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(props.state_isolated);
    try std.testing.expect(props.result_safe);
    try std.testing.expect(props.optional_safe);
}

test "compileHandler graph leaves verifier facts unproven when verification is off" {
    var fixture = try importFixture(capsuleEntry("canonical"),
        \\export function f(): string {
        \\  return "x";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_contract = true });
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.state_isolated);
    try std.testing.expect(!props.result_safe);
    try std.testing.expect(!props.optional_safe);
}

const Props = handler_contract.HandlerProperties;

const StructuralRow = struct {
    dep: []const u8,
    property: []const u8,
    read: *const fn (Props) bool,
    expected: bool,
};

fn readPure(p: Props) bool {
    return p.pure;
}
fn readReadOnly(p: Props) bool {
    return p.read_only;
}
fn readStateless(p: Props) bool {
    return p.stateless;
}
fn readRetrySafe(p: Props) bool {
    return p.retry_safe;
}
fn readIdempotent(p: Props) bool {
    return p.idempotent;
}
fn readDeterministic(p: Props) bool {
    return p.deterministic;
}
fn readFaultCovered(p: Props) bool {
    return p.fault_covered;
}
fn readHasEgress(p: Props) bool {
    return p.has_egress;
}

const structural_rows = [_]StructuralRow{
    .{ .property = "pure", .read = readPure, .expected = false, .dep = secret_dep },
    .{ .property = "read_only", .read = readReadOnly, .expected = false, .dep =
    \\import { cacheSet } from "zttp:cache";
    \\export function f(): string {
    \\  cacheSet("items", "key", "value");
    \\  return "x";
    \\}
    \\
    },
    .{ .property = "stateless", .read = readStateless, .expected = false, .dep =
    \\import { cacheGet } from "zttp:cache";
    \\export function f(): string {
    \\  return cacheGet("items", "key") ?? "";
    \\}
    \\
    },
    .{ .property = "retry_safe", .read = readRetrySafe, .expected = false, .dep =
    \\import { cacheSet } from "zttp:cache";
    \\export function f(): string {
    \\  cacheSet("items", "key", "value");
    \\  return "x";
    \\}
    \\
    },
    .{ .property = "idempotent", .read = readIdempotent, .expected = false, .dep =
    \\import { cacheSet } from "zttp:cache";
    \\export function f(): string {
    \\  cacheSet("items", "key", "value");
    \\  return "x";
    \\}
    \\
    },
    .{ .property = "deterministic", .read = readDeterministic, .expected = false, .dep =
    \\export function f(): string {
    \\  return String(Date.now());
    \\}
    \\
    },
    .{ .property = "fault_covered", .read = readFaultCovered, .expected = false, .dep =
    \\import { jwtVerify } from "zttp:auth";
    \\export function f(): string {
    \\  const result = jwtVerify("token", "secret");
    \\  if (!result.ok) return "no";
    \\  return "yes";
    \\}
    \\
    },
    .{ .property = "has_egress", .read = readHasEgress, .expected = true, .dep =
    \\import { fetch } from "zttp:fetch";
    \\export function f(): string {
    \\  const result = fetch("https://example.com");
    \\  if (!result.ok) return "no";
    \\  return "yes";
    \\}
    \\
    },
};

test "compileHandler graph reads each structural property off the dependency that breaks it" {
    for (structural_rows) |row| {
        var fixture = try importFixture(capsuleEntry("canonical"), row.dep);
        defer fixture.deinit();
        var compiled = try fixture.compile(graph_verified);
        defer compiled.deinit(std.testing.allocator);
        const props = try graphProperties(&compiled);
        const actual = row.read(props);
        std.testing.expectEqual(row.expected, actual) catch |err| {
            std.debug.print("structural property {s}\n", .{row.property});
            return err;
        };
    }
}

test "compileHandler graph holds the structural properties for a graph of pure helpers" {
    var fixture = try importFixture(capsuleEntry("canonical"),
        \\export function f(): string {
        \\  return "x";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.stateless);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.idempotent);
    try std.testing.expect(!props.has_egress);
    try std.testing.expect(props.cost_bounded);
    try std.testing.expectEqual(@as(?u32, 0), props.max_io_depth);
}

test "compileHandler graph clears the cost bound when a dependency makes a module call" {
    var fixture = try importFixture(capsuleEntry("canonical"),
        \\import { cacheGet } from "zttp:cache";
        \\export function f(): string {
        \\  return cacheGet("items", "key") ?? "";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const props = try graphProperties(&compiled);
    try std.testing.expect(!props.cost_bounded);
    try std.testing.expectEqual(@as(?u32, null), props.max_io_depth);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expect(contract.cost_envelope == null);
}

const CapsuleRefusal = struct {
    capsule_entry: []const u8,
    dep: []const u8,
};

const capsule_refusals = [_]CapsuleRefusal{
    .{ .capsule_entry = capsuleEntry("no_secret_leakage"), .dep = secret_dep },
    .{ .capsule_entry = capsuleEntry("deterministic"), .dep =
    \\export function f(): string {
    \\  return String(Date.now());
    \\}
    \\
    },
    .{ .capsule_entry = capsuleEntry("stateless"), .dep =
    \\import { cacheGet } from "zttp:cache";
    \\export function f(): string {
    \\  return cacheGet("items", "key") ?? "";
    \\}
    \\
    },
    .{ .capsule_entry = capsuleEntry("state_isolated"), .dep =
    \\let count: number = 0;
    \\export function f(): string {
    \\  count = count + 1;
    \\  return String(count);
    \\}
    \\
    },
};

test "compileHandler graph refuses a capsule that demands a property a dependency breaks" {
    for (capsule_refusals) |row| {
        var fixture = try importFixture(row.capsule_entry, row.dep);
        defer fixture.deinit();
        try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
    }
}

test "compileHandler graph unions the fetch URLs of a dependency" {
    var fixture = try importFixture(capsuleEntry("result_safe"),
        \\export function f(): string {
        \\  return fetchSync("https://example.com/status");
        \\}
        \\
    );
    defer fixture.deinit();
    // The raw `fetchSync` global is outside the strict profile, and it is the one
    // source of full fetch URLs, so this compile relaxes the strict rules.
    var compiled = try fixture.compile(.{ .emit_verify = true, .emit_contract = true, .strict = false });
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.egress.urls.items.len);
    try std.testing.expectEqualStrings("https://example.com/status", contract.egress.urls.items[0]);
}

fn schemaEntry(comptime schema: []const u8) []const u8 {
    return "import { schemaCompile } from \"zttp:validate\";\n" ++
        "import { f } from \"./dep.ts\";\n" ++
        "schemaCompile(\"user\", JSON.stringify(" ++ schema ++ "));\n" ++
        "export function handler(req: Request): Proof<Response, \"result_safe\"> {\n" ++
        "  return Response.text(f());\n}\n";
}

fn schemaDep(comptime schema: []const u8) []const u8 {
    return "import { schemaCompile } from \"zttp:validate\";\n" ++
        "schemaCompile(\"user\", JSON.stringify(" ++ schema ++ "));\n" ++
        "export function f(): string {\n  return \"x\";\n}\n";
}

test "compileHandler graph refuses two modules that register one schema name with different JSON" {
    var fixture = try importFixture(schemaEntry("{ type: \"object\" }"), schemaDep("{ type: \"string\" }"));
    defer fixture.deinit();
    try std.testing.expectError(error.ApiSchemaConflict, fixture.compile(graph_verified));
}

test "compileHandler graph accepts two modules that register one schema name with identical JSON" {
    var fixture = try importFixture(schemaEntry("{ type: \"object\" }"), schemaDep("{ type: \"object\" }"));
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 1), contract.api.schemas.items.len);
    try std.testing.expectEqualStrings("user", contract.api.schemas.items[0].name);
}

test "compileHandler graph gives identical contract JSON on two compiles" {
    var fixture = try CompileGraphFixture.init("entry.ts", diamond_entry);
    defer fixture.deinit();
    try addDiamond(&fixture);
    var first = try fixture.compile(graph_verified);
    defer first.deinit(std.testing.allocator);
    var second = try fixture.compile(graph_verified);
    defer second.deinit(std.testing.allocator);
    try expectSameGraphArtifact(&first, &second);
}

const graph_clean_entry =
    \\import { value } from "./dep.ts";
    \\export function handler(req: Request): Response {
    \\  return Response.text(String(value()));
    \\}
    \\
;

fn graphDependencyFixture(dep_source: []const u8) !CompileGraphFixture {
    var fixture = try CompileGraphFixture.init("entry.ts", graph_clean_entry);
    errdefer fixture.deinit();
    try fixture.add("dep.ts", dep_source);
    return fixture;
}

test "compileHandler graph refuses a dependency that fails the boolean check" {
    var fixture = try graphDependencyFixture(
        \\export function value(): number {
        \\  if (5) return 1;
        \\  return 2;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a dependency that fails the type check" {
    var fixture = try graphDependencyFixture(
        \\export function value(): number {
        \\  const wrong: number = "wrong";
        \\  return wrong;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a dependency that fails the strict check" {
    var fixture = try graphDependencyFixture(
        \\export function value() {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph skips the strict rules of a dependency when strict is off" {
    var fixture = try CompileGraphFixture.init("entry.ts",
        \\import { typed } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(typed()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function value() {
        \\  return 1;
        \\}
        \\export function typed(): number {
        \\  return 1;
        \\}
        \\
    );
    var compiled = try fixture.compile(.{ .emit_verify = true, .strict = false });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
}

test "compileHandler graph fails verification for a dependency with an unchecked result" {
    var fixture = try graphDependencyFixture(
        \\import { jwtVerify } from "zttp:auth";
        \\export function value(): string {
        \\  const result = jwtVerify("token", "secret");
        \\  return String(result.value);
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.verify_failed);
    try std.testing.expectEqual(@as(usize, 0), compiled.bytecode.len);
}

test "compileHandler graph does not verify a dependency when verification is off" {
    var fixture = try graphDependencyFixture(
        \\import { jwtVerify } from "zttp:auth";
        \\export function value(): string {
        \\  const result = jwtVerify("token", "secret");
        \\  return String(result.value);
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(.{});
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(!compiled.verify_failed);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
}

test "compileHandler graph refuses an invalid virtual import in a dependency" {
    var fixture = try graphDependencyFixture(
        \\import { definitelyMissing } from "zttp:sql";
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.InvalidImportSpecifier, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a top-level assert in a dependency" {
    var fixture = try graphDependencyFixture(
        \\assert 1 === 1, "boot";
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.DependencyTopLevelAssert, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses an assert nested in a top-level block of a dependency" {
    var fixture = try graphDependencyFixture(
        \\if (1 === 1) {
        \\  assert 1 === 1, "boot";
        \\}
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.DependencyTopLevelAssert, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph accepts an assert inside a dependency function" {
    var fixture = try graphDependencyFixture(
        \\export function value(): string {
        \\  assert 1 === 1, "inside";
        \\  return "ok";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
}

test "compileHandler graph exempts a dependency that fails only ZTS061" {
    var fixture = try graphDependencyFixture(
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(!compiled.verify_failed);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
}

test "compileHandler graph refuses a dependency that fails ZTS609" {
    var fixture = try graphDependencyFixture(
        \\export const value = (): number => 1;
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses an entry that fails the boolean check" {
    const entry_source =
        \\import { value } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  if (5) return Response.text("five");
        \\  return Response.text(String(value()));
        \\}
        \\
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph still enforces ZTS061 on the entry" {
    const entry_source =
        \\import { value } from "./dep.ts";
        \\export function label(): string {
        \\  return "entry";
        \\}
        \\export function handler(req: Request): Response {
        \\  return Response.text(String(value()));
        \\}
        \\
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph fails verification for an entry with an unchecked result" {
    const entry_source =
        \\import { jwtVerify } from "zttp:auth";
        \\import { value } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  const result = jwtVerify("token", "secret");
        \\  return Response.text([String(result.value), String(value())].join(""));
        \\}
        \\
    ;
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function value(): number {
        \\  return 1;
        \\}
        \\
    );
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.verify_failed);
}

test "compileHandler graph rejects an entry with an unsupported extension" {
    const entry_source =
        \\import { count } from "./dep.ts";
        \\export function handler(req) {
        \\  return Response.text(String(count()));
        \\}
        \\
    ;
    var unsupported = try CompileGraphFixture.init("entry.js", entry_source);
    defer unsupported.deinit();
    try unsupported.add("dep.ts", "export function count(): number { return 1; }\n");
    try std.testing.expectError(error.UnsupportedSourceExtension, unsupported.compile(.{}));
}

const greet_entry =
    \\import { greet } from "./dep.ts";
    \\export function handler(req: Request): Proof<Response, "state_isolated"> {
    \\  return greet();
    \\}
    \\
;

const greet_dep =
    \\export function greet(): string {
    \\  return "x";
    \\}
    \\
;

fn importFixture(entry_source: []const u8, dep_source: []const u8) !CompileGraphFixture {
    var fixture = try CompileGraphFixture.init("entry.ts", entry_source);
    errdefer fixture.deinit();
    try fixture.add("dep.ts", dep_source);
    return fixture;
}

fn expectImportRefused(entry_source: []const u8, dep_source: []const u8) !void {
    var fixture = try importFixture(entry_source, dep_source);
    defer fixture.deinit();
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

fn expectImportUnproven(entry_source: []const u8, dep_source: []const u8) !void {
    var fixture = try importFixture(entry_source, dep_source);
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(compiled.verify_failed);
    try std.testing.expectEqual(@as(usize, 0), compiled.bytecode.len);
}

fn expectImportCompiles(entry_source: []const u8, dep_source: []const u8) !void {
    var fixture = try importFixture(entry_source, dep_source);
    defer fixture.deinit();
    var compiled = try fixture.compile(.{ .emit_verify = true });
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expect(!compiled.verify_failed);
    try std.testing.expectEqual(@as(usize, 1), compiled.dep_bytecodes.?.len);
}

test "compileHandler graph refuses a string imported from a file where a Response is declared" {
    try expectImportRefused(greet_entry, greet_dep);
}

test "compileHandler graph accepts a dependency helper that declares Response" {
    try expectImportCompiles(greet_entry,
        \\export function greet(): Response {
        \\  return Response.text("x");
        \\}
        \\
    );
}

test "compileHandler graph refuses a string imported from a file and returned through a binding" {
    try expectImportRefused(
        \\import { greet } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const r = greet();
        \\  return r;
        \\}
        \\
    , greet_dep);
}

test "compileHandler graph refuses a string imported from a file under an alias" {
    try expectImportRefused(
        \\import { greet as hello } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return hello();
        \\}
        \\
    , greet_dep);
}

test "compileHandler graph refuses a local function that shares a name with an export of another module" {
    var fixture = try CompileGraphFixture.init("entry.ts",
        \\import { other } from "./dep.ts";
        \\function greet(): Response {
        \\  return Response.text(other());
        \\}
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return greet();
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\export function greet(): string {
        \\  return "x";
        \\}
        \\export function other(): string {
        \\  return "y";
        \\}
        \\
    );
    try std.testing.expectError(error.AmbiguousBinding, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a wrong argument type to an imported function" {
    try expectImportRefused(
        \\import { twice } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(twice("a")));
        \\}
        \\
    ,
        \\export function twice(n: number): number {
        \\  return n * 2;
        \\}
        \\
    );
}

test "compileHandler graph accepts the right argument type to an imported function" {
    try expectImportCompiles(
        \\import { twice } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(twice(2)));
        \\}
        \\
    ,
        \\export function twice(n: number): number {
        \\  return n * 2;
        \\}
        \\
    );
}

test "compileHandler graph reads an exported structural alias of string as string" {
    const alias_dep =
        \\structural Label = string;
        \\export function label(): Label {
        \\  return "x";
        \\}
        \\
    ;
    try expectImportRefused(
        \\import { label } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return label();
        \\}
        \\
    , alias_dep);
    try expectImportCompiles(
        \\import { label } from "./dep.ts";
        \\function show(text: string): Response {
        \\  return Response.text(text);
        \\}
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return show(label());
        \\}
        \\
    , alias_dep);
}

test "compileHandler graph types a dependency that imports from another dependency" {
    const entry_source =
        \\import { mid } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return mid();
        \\}
        \\
    ;
    var fixture = try importFixture(entry_source,
        \\import { base } from "./base.ts";
        \\export function mid(): string {
        \\  return base();
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("base.ts",
        \\export function base(): string {
        \\  return "b";
        \\}
        \\
    );
    try std.testing.expectError(error.SoundModeViolation, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a read of an imported value that may be undefined" {
    try expectImportUnproven(
        \\import { maybe } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(maybe().length));
        \\}
        \\
    ,
        \\export function maybe(): string | undefined {
        \\  return "x";
        \\}
        \\
    );
}

const generic_dep =
    \\export function pick<T>(value: T): T {
    \\  return value;
    \\}
    \\
;

fn expectImportUntyped(entry_source: []const u8, dep_source: []const u8) !void {
    var fixture = try importFixture(entry_source, dep_source);
    defer fixture.deinit();
    try std.testing.expectError(error.FileImportUntyped, fixture.compile(.{ .emit_verify = true }));
}

test "compileHandler graph refuses a generic import that launders an environment value" {
    try expectImportUntyped(
        \\import { env } from "zttp:env";
        \\import { pick } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  const v = pick(env("X"));
        \\  return Response.text(String(v.length));
        \\}
        \\
    , generic_dep);
}

test "compileHandler graph refuses a generic import that yields a returned string" {
    try expectImportUntyped(
        \\import { wrap } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  for (const r of wrap(["a"])) {
        \\    return r;
        \\  }
        \\  return Response.text("x");
        \\}
        \\
    ,
        \\export function wrap<T>(x: T[]): T[] {
        \\  return x;
        \\}
        \\
    );
}

test "compileHandler graph refuses a generic import that is called and not returned" {
    try expectImportUntyped(
        \\import { pick } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(pick(1)));
        \\}
        \\
    , generic_dep);
}

test "compileHandler graph refuses an import of a type predicate" {
    try expectImportUntyped(
        \\import { isText } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(isText("a")));
        \\}
        \\
    ,
        \\export function isText(v: unknown): v is string {
        \\  return typeof v === "string";
        \\}
        \\
    );
}

const limit_dep =
    \\export const limit = 5;
    \\
;

test "compileHandler graph reads an imported number as a number" {
    try expectImportCompiles(
        \\import { limit } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(limit));
        \\}
        \\
    , limit_dep);
}

test "compileHandler graph refuses an imported number where a string is declared" {
    try expectImportRefused(
        \\import { limit } from "./dep.ts";
        \\function show(text: string): Response {
        \\  return Response.text(text);
        \\}
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return show(limit);
        \\}
        \\
    , limit_dep);
}

test "compileHandler graph types an exported alias of a function by the function" {
    try expectImportRefused(
        \\import { alias } from "./dep.ts";
        \\function show(text: string): Response {
        \\  return Response.text(text);
        \\}
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return show(alias());
        \\}
        \\
    ,
        \\function helper(): number {
        \\  return 1;
        \\}
        \\export const alias = helper;
        \\
    );
}

test "compileHandler graph refuses a read of an imported value that is declared undefined" {
    try expectImportUnproven(
        \\import { label } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return Response.text(String(label.length));
        \\}
        \\
    ,
        \\export const label: string | undefined = undefined;
        \\
    );
}

test "compileHandler graph accepts an import of a type" {
    try expectImportCompiles(
        \\import type { Label } from "./dep.ts";
        \\import { greet } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return greet();
        \\}
        \\
    ,
        \\export structural Label = string;
        \\export function greet(): Response {
        \\  return Response.text("x");
        \\}
        \\
    );
}

test "compileHandler graph refuses an import cycle" {
    var fixture = try importFixture(
        \\import { a } from "./dep.ts";
        \\export function handler(req: Request): Proof<Response, "state_isolated"> {
        \\  return a();
        \\}
        \\
    ,
        \\import { b } from "./back.ts";
        \\export function a(): Response {
        \\  return b();
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("back.ts",
        \\import { a } from "./dep.ts";
        \\export function b(): Response {
        \\  return a();
        \\}
        \\
    );
    try std.testing.expectError(error.CircularImport, fixture.compile(.{ .emit_verify = true }));
}

// ---------------------------------------------------------------------------
// Check parity: `zts check` reports each refusal that `zts compile` makes
// ---------------------------------------------------------------------------

fn parityEntry(comptime capsule: []const u8) []const u8 {
    return "import { f } from \"./lib.ts\";\n" ++
        "export function handler(req: Request): Proof<Response, \"" ++ capsule ++ "\"> {\n" ++
        "  return Response.text(f());\n}\n";
}

const parity_schema_entry =
    \\import { schemaCompile } from "zttp:validate";
    \\import { f } from "./lib.ts";
    \\schemaCompile("user", JSON.stringify({ type: "object" }));
    \\export function handler(req: Request): Proof<Response, "result_safe"> {
    \\  return Response.text(f());
    \\}
    \\
;

const parity_schema_lib =
    \\import { schemaCompile } from "zttp:validate";
    \\schemaCompile("user", JSON.stringify({ type: "string" }));
    \\export function f(): string {
    \\  return "x";
    \\}
    \\
;

const parity_pure_lib =
    \\export function f(): string {
    \\  return "x";
    \\}
    \\
;

const ParityFile = struct { name: []const u8, source: []const u8 };

const ParityRow = struct {
    label: []const u8,
    entry: []const u8,
    files: []const ParityFile,
    policy: ?[]const u8 = null,
    /// The code of the first `zts check` diagnostic, and the basename of its file.
    code: []const u8,
    file: []const u8,
};

fn parityFixture(entry: []const u8, files: []const ParityFile) !CompileGraphFixture {
    var fixture = try CompileGraphFixture.init("entry.ts", entry);
    errdefer fixture.deinit();
    for (files) |file| try fixture.add(file.name, file.source);
    return fixture;
}

/// True when `compileHandler` refuses the graph: it fails, or the verifier does.
fn compileRefuses(fixture: *const CompileGraphFixture, policy_json: ?[]const u8) !bool {
    const allocator = std.testing.allocator;
    var policy: ?HandlerPolicy = if (policy_json) |json| try handler_policy.parsePolicyJson(allocator, json) else null;
    defer if (policy) |*configured| configured.deinit(allocator);
    var compiled = fixture.compile(.{ .emit_verify = true, .emit_contract = true, .policy = policy }) catch return true;
    defer compiled.deinit(allocator);
    return compiled.verify_failed;
}

fn parityCheck(fixture: *const CompileGraphFixture, policy_json: ?[]const u8) !CheckResult {
    return runCheckOnlyWithOptions(std.testing.allocator, fixture.entry_path, .{
        .json_mode = true,
        .policy_source = policy_json,
    });
}

const parity_refused_rows = [_]ParityRow{
    .{
        .label = "dependency type error",
        .entry = parityEntry("result_safe"),
        .files = &.{.{ .name = "lib.ts", .source = "export function f(): string {\n  const n: number = \"a\";\n  return \"x\";\n}\n" }},
        .code = "ZTS200",
        .file = "lib.ts",
    },
    .{
        .label = "dependency parse error",
        .entry = parityEntry("result_safe"),
        .files = &.{.{ .name = "lib.ts", .source = "export function f(): string {\n  const b = while;\n  return \"x\";\n}\n" }},
        .code = "ZTS002",
        .file = "lib.ts",
    },
    .{
        .label = "generic export imported",
        .entry = "import { pick } from \"./lib.ts\";\n" ++
            "export function handler(req: Request): Proof<Response, \"result_safe\"> {\n  return Response.text(pick(\"a\"));\n}\n",
        .files = &.{.{ .name = "lib.ts", .source = "export function pick<T>(x: T): T {\n  return x;\n}\n" }},
        .code = "ZTS064",
        .file = "entry.ts",
    },
    .{
        .label = "named import the target does not export",
        .entry = "import { missing } from \"./lib.ts\";\n" ++
            "export function handler(req: Request): Proof<Response, \"result_safe\"> {\n  return Response.text(missing());\n}\n",
        .files = &.{.{ .name = "lib.ts", .source = parity_pure_lib }},
        .code = "ZTS063",
        .file = "entry.ts",
    },
    .{
        .label = "import of a file that does not exist",
        .entry = "import { f } from \"./nope.ts\";\n" ++
            "export function handler(req: Request): Proof<Response, \"result_safe\"> {\n  return Response.text(f());\n}\n",
        .files = &.{},
        .code = "ZTS063",
        .file = "entry.ts",
    },
    .{
        .label = "import cycle",
        .entry = parityEntry("result_safe"),
        .files = &.{
            .{ .name = "lib.ts", .source = "import { g } from \"./back.ts\";\nexport function f(): string {\n  return g();\n}\n" },
            .{ .name = "back.ts", .source = "import { f } from \"./lib.ts\";\nexport function g(): string {\n  return f();\n}\n" },
        },
        .code = "ZTS063",
        .file = "lib.ts",
    },
    .{
        .label = "one top-level name bound in two modules",
        .entry = "import { f } from \"./lib.ts\";\nconst shared: string = \"b\";\n" ++
            "export function handler(req: Request): Proof<Response, \"result_safe\"> {\n  return Response.text([f(), shared].join(\"\"));\n}\n",
        .files = &.{.{ .name = "lib.ts", .source = "const shared: string = \"a\";\nexport function f(): string {\n  return shared;\n}\n" }},
        .code = "ZTS063",
        .file = "lib.ts",
    },
    .{
        .label = "dependency binds a built-in global",
        .entry = parityEntry("result_safe"),
        .files = &.{.{ .name = "lib.ts", .source = "const Math: number = 1;\nexport function f(): string {\n  return String(Math);\n}\n" }},
        .code = "ZTS063",
        .file = "lib.ts",
    },
    .{
        .label = "dependency binds handler",
        .entry = parityEntry("result_safe"),
        .files = &.{.{
            .name = "lib.ts",
            .source = "export function handler(req: Request): Response {\n  return Response.text(\"x\");\n}\n" ++
                "export function f(): string {\n  return \"x\";\n}\n",
        }},
        .code = "ZTS063",
        .file = "lib.ts",
    },
    .{
        .label = "dependency top-level assert",
        .entry = parityEntry("result_safe"),
        .files = &.{.{ .name = "lib.ts", .source = "assert 1 === 1, \"boot\";\nexport function f(): string {\n  return \"x\";\n}\n" }},
        .code = "ZTS063",
        .file = "lib.ts",
    },
    .{
        // A mutation is a ZTS310 warning in the dependency. The capsule of the
        // entry demands state_isolated, so the compile refuses on the spec.
        .label = "dependency mutates module state under a state_isolated capsule",
        .entry = parityEntry("state_isolated"),
        .files = &.{.{
            .name = "lib.ts",
            .source = "let count: number = 0;\nexport function f(): string {\n  count = count + 1;\n  return String(count);\n}\n",
        }},
        .code = "ZTS310",
        .file = "lib.ts",
    },
    .{
        .label = "two modules register one API schema name with different JSON",
        .entry = parity_schema_entry,
        .files = &.{.{ .name = "lib.ts", .source = parity_schema_lib }},
        .code = "ZTS063",
        .file = "lib.ts",
    },
};

test "check parity: zts check reports each refusal that zts compile makes, with the file at fault" {
    for (parity_refused_rows) |row| {
        errdefer std.debug.print("parity row failed: {s}\n", .{row.label});
        var fixture = try parityFixture(row.entry, row.files);
        defer fixture.deinit();
        var checked = try parityCheck(&fixture, row.policy);
        defer checked.deinit(std.testing.allocator);
        try std.testing.expect(checked.json_diagnostics.items.len > 0);
        try std.testing.expectEqualStrings(row.code, checked.json_diagnostics.items[0].code);
        try std.testing.expectEqualStrings(row.file, std.fs.path.basename(checked.json_diagnostics.items[0].file));
        try std.testing.expect(checked.totalErrors() > 0);
        try std.testing.expect(try compileRefuses(&fixture, row.policy));
    }
}

const sibling_helper_handler =
    \\import { apiToken, displayName } from "./lib/settings.ts";
    \\
    \\structural Guard<T> = Proof<T, "state_isolated" | "no_secret_leakage">;
    \\
    \\export function handler(req: Request): Guard<Response> {
    \\  const token = apiToken();
    \\  if (token === undefined) {
    \\    return Response.json({ error: "settings unavailable" }, { status: 503 });
    \\  }
    \\  return Response.json({ name: displayName() });
    \\}
    \\
;

// The seed of the corpus case `sibling-helper` in packages/pi/src/expert_codegen_record.zig.
const sibling_helper_seed =
    \\import { env } from "zttp:env";
    \\
    \\export structural ApiToken = string | undefined;
    \\export structural DisplayName = string;
    \\
    \\export function apiToken(): ApiToken {
    \\  return env("API_TOKEN");
    \\}
    \\
    \\export function displayName(): DisplayName {
    \\  return env("APP_NAME") ?? "unnamed";
    \\}
    \\
;

const sibling_helper_policy = "{\"env\":{\"allow\":[\"APP_NAME\",\"API_TOKEN\"],\"public\":[\"APP_NAME\"]}}";

test "check parity: a graph that compiles passes zts check with no error" {
    const allocator = std.testing.allocator;

    var pure = try parityFixture(parityEntry("result_safe"), &.{.{ .name = "lib.ts", .source = parity_pure_lib }});
    defer pure.deinit();
    var pure_checked = try parityCheck(&pure, null);
    defer pure_checked.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), pure_checked.totalErrors());
    try std.testing.expect(!(try compileRefuses(&pure, null)));

    var sibling = try parityFixture(sibling_helper_handler, &.{});
    defer sibling.deinit();
    try sibling.tmp.dir.createDirPath(std.testing.io, "lib");
    try sibling.add("lib/settings.ts", sibling_helper_seed);
    var sibling_checked = try parityCheck(&sibling, sibling_helper_policy);
    defer sibling_checked.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), sibling_checked.totalErrors());
    try std.testing.expect(!(try compileRefuses(&sibling, sibling_helper_policy)));
}

test "check parity: examples/handler/handler-with-imports.ts passes zts check and zts compile" {
    const allocator = std.testing.allocator;
    const path = "examples/handler/handler-with-imports.ts";
    var checked = try runCheckOnlyWithOptions(allocator, path, .{ .json_mode = true });
    defer checked.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), checked.totalErrors());

    const source = try zts.file_io.readFile(allocator, path, 1024 * 1024);
    defer allocator.free(source);
    var compiled = try compileHandler(allocator, source, path, .{ .emit_verify = true, .emit_contract = true });
    defer compiled.deinit(allocator);
    try std.testing.expect(!compiled.verify_failed);
}

test "check parity: zts check reports the default profile failure of an uncalled state change in a dependency (smoke-v1 shape)" {
    // The shape of the negative step in scripts/smoke-v1.sh: the handler holds no
    // capsule and never calls `bump`, yet the dependency mutates module state.
    // `zttp build` counts one spec error on the merged contract through
    // `reportSpecErrors(contract, filename, .every)`.
    const allocator = std.testing.allocator;
    var fixture = try CompileGraphFixture.init("entry.ts",
        \\import { bump } from "./dep.ts";
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("dep.ts",
        \\let count: number = 0;
        \\export function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );
    var compiled = try fixture.compile(.{ .emit_verify = true, .emit_contract = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expectEqual(@as(u32, 1), reportSpecErrors(&contract, "entry.ts", .every));

    var checked = try runCheckOnlyWithOptions(allocator, fixture.entry_path, .{ .json_mode = true });
    defer checked.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), checked.specErrors());
    try std.testing.expectEqualStrings("ZTS500", checked.json_diagnostics.items[checked.json_diagnostics.items.len - 1].code);
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
    try std.testing.expect(contract.properties != null);
    try std.testing.expect(contract.fault_coverage != null);
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
    // of a module that is not there at all, such as the removed
    // `zttp:websocket`, must be refused and not reported clean.
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

test "compileHandler claims state isolation only when the verifier ran and found no module mutation" {
    const allocator = std.testing.allocator;
    const source =
        \\let counter: number = 0;
        \\function handler(req: Request): Response {
        \\  counter = counter + 1;
        \\  return Response.text("ok");
        \\}
    ;

    // Without --verify no pass checked state isolation, so the contract
    // must not claim it.
    var unverified = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true });
    defer unverified.deinit(allocator);
    const unverified_props = (unverified.contract orelse return error.MissingContract).properties orelse return error.MissingProperties;
    try std.testing.expect(!unverified_props.state_isolated);

    // With --verify the mutation is found and the compile fails.
    var verified = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer verified.deinit(allocator);
    try std.testing.expect(verified.verify_failed);
}

test "compileHandler without verification keeps the read-only family over a module write" {
    const allocator = std.testing.allocator;
    const source =
        \\let counter: number = 0;
        \\function handler(req: Request): Response {
        \\  counter = counter + 1;
        \\  return Response.text("ok");
        \\}
    ;
    // No pass checked the write, so the contract discloses no claim about it
    // beyond the unproven state isolation.
    var unverified = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true });
    defer unverified.deinit(allocator);
    const props = (unverified.contract orelse return error.MissingContract).properties orelse return error.MissingProperties;
    try std.testing.expect(!props.state_isolated);
    try std.testing.expect(props.read_only);
    try std.testing.expect(props.retry_safe);
    try std.testing.expect(props.deterministic);
    try std.testing.expect(props.idempotent);
    try std.testing.expect(props.pure);
    try std.testing.expect(props.stateless);
}

test "compileHandler refuses a declared no_secret_leakage over a leak in the contract" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
        \\  const secret: string = env("SECRET_KEY") ?? "";
        \\  return Response.text(secret);
        \\}
    ;
    var compiled = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(!props.no_secret_leakage);
    try std.testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);
    const diag = contract.spec_diagnostics.items[0];
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.not_discharged, diag.kind);
    try std.testing.expectEqualStrings("no_secret_leakage", diag.spec_name);
}

test "compileHandler discharges a declared result_safe that the verifier proved" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;
    var compiled = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const props = contract.properties orelse return error.MissingProperties;
    try std.testing.expect(props.result_safe);
    try std.testing.expectEqual(@as(usize, 0), contract.spec_diagnostics.items.len);
}

test "compileHandler without strict checking does not claim canonical form" {
    const allocator = std.testing.allocator;
    // ZTS613: compound assignment is outside the canonical profile.
    const source =
        \\function handler(req: Request): Response {
        \\  let n = 1;
        \\  n += 1;
        \\  return Response.text(String(n));
        \\}
    ;
    var relaxed = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .strict = false });
    defer relaxed.deinit(allocator);
    const props = (relaxed.contract orelse return error.MissingContract).properties orelse return error.MissingProperties;
    try std.testing.expect(!props.canonical);
}

test {
    _ = @import("precompile_args.zig");
    _ = check_mod;
    _ = @import("pipeline_mutation_tests.zig");
    _ = @import("flow_false_proofs.zig");
    _ = @import("flow_precision_expectations.zig");
    _ = @import("precompile_stderr.zig");
    _ = @import("precompile_cli.zig");
    _ = @import("precompile_contract.zig");
    _ = @import("precompile_check_tests.zig");
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

// ---------------------------------------------------------------------------
// One fault coverage record across check, compile, and text output
// ---------------------------------------------------------------------------

/// A failable call inside a closure body that the handler reaches through an
/// alias: `walkPaths` does not enter a nested function, and a call by the
/// alias is not expanded, so no path records the call. The walk lists it as
/// unseen and `fault_covered` is refused. (A call by the closure's own name is
/// expanded, and a failable call nested in a returned or initializer
/// expression is recorded since the I/O tracker descends.)
const unseen_call_handler =
    \\import { jwtVerify } from "zttp:auth";
    \\function handler(req: Request): Response {
    \\  const read = (): string => jwtVerify("t", "s").error;
    \\  const again = read;
    \\  return Response.text(again());
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
    // The cause names the unseen call, which sits on line 3 of the source.
    try std.testing.expectEqualStrings("jwtVerify", cause.snippet);
    try std.testing.expectEqual(@as(u32, 3), cause.line);
}

test "compileHandler and the check path both hold fault_covered for a handler with no failable site" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req: Request): Response {
        \\  if (req.path === "/health") {
        \\    return Response.json({ ok: true });
        \\  }
        \\  return Response.text("Not Found", { status: 404 });
        \\}
    ;
    var compiled = try compileHandler(allocator, source, "no-io.ts", .{ .emit_contract = true });
    defer compiled.deinit(allocator);
    const contract = &(compiled.contract orelse return error.TestUnexpectedResult);
    const fc = contract.fault_coverage orelse return error.TestUnexpectedResult;
    // The floor: the walk saw the handler and counted no failable site.
    try std.testing.expectEqual(@as(u32, 0), fc.total_failable);
    try std.testing.expect(fc.analysis_complete);
    try std.testing.expect(fc.isCovered());
    try std.testing.expect(contract.properties.?.fault_covered);

    var checked = try runCheckOnlyFromSourceWithOptions(allocator, source, "no-io.ts", .{});
    defer checked.deinit(allocator);
    try std.testing.expect((checked.contract orelse return error.TestUnexpectedResult).properties.?.fault_covered);
    try std.testing.expectEqual(@as(u32, 0), checked.totalErrors());
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
// Dependency helper capsules: the graph compile holds a helper of an imported
// module to the `Proof<...>` and `Effects<...>` that it declares.
// ---------------------------------------------------------------------------

const capsule_stamp_entry =
    \\import { stamp } from "./dep.ts";
    \\
    \\export function handler(req: Request): Proof<Response, "read_only"> {
    \\  const t = stamp();
    \\  return Response.text(String(t));
    \\}
    \\
;

test "compileHandler graph refuses a false Proof capsule on a dependency helper" {
    var fixture = try importFixture(capsule_stamp_entry,
        \\export function stamp(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

const clock_in_entry =
    \\import { greet } from "./dep.ts";
    \\
    \\function stamp(): number {
    \\  return Date.now();
    \\}
    \\
    \\export function handler(req: Request): Response {
    \\  return Response.text([greet(), String(stamp())].join(""));
    \\}
    \\
;

const clock_in_entry_declared =
    \\import { greet } from "./dep.ts";
    \\
    \\function stamp(): number {
    \\  return Date.now();
    \\}
    \\
    \\export function handler(req: Request): Proof<Response, "deterministic"> {
    \\  return Response.text([greet(), String(stamp())].join(""));
    \\}
    \\
;

const greet_ok_dep =
    \\export function greet(): string {
    \\  return "ok";
    \\}
    \\
;

test "compileHandler graph accepts a clock helper of the entry under the default profile and marks all three rows" {
    var fixture = try importFixture(clock_in_entry, greet_ok_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const rows = contract.spec_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.not_discharged, rows[0].kind);
    try std.testing.expect(rows[0].implicit_default);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.missing_capsule, rows[1].kind);
    try std.testing.expectEqualStrings("pure", rows[1].spec_name);
    try std.testing.expect(rows[1].implicit_default);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.missing_capsule, rows[2].kind);
    try std.testing.expectEqualStrings("deterministic", rows[2].spec_name);
    try std.testing.expect(rows[2].implicit_default);
}

test "control: compileHandler graph refuses a clock helper of the entry under a declared deterministic capsule" {
    var fixture = try importFixture(clock_in_entry_declared, greet_ok_dep);
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

const stamp_dropped_suggestion =
    "this handler returns no Proof<T, P> capsule, so the compiler must prove the full default profile, " ++
    "but it does not hold: pure. Return a narrow Proof capsule with only the properties it holds, e.g. " ++
    "`function handler(req: Request): Proof<Response, \"read_only\" | \"retry_safe\" | \"idempotent\" | " ++
    "\"state_isolated\" | \"fault_covered\" | \"stateless\" | \"result_safe\" | \"optional_safe\" | " ++
    "\"no_secret_leakage\" | \"no_credential_leakage\" | \"input_validated\" | \"pii_contained\" | " ++
    "\"injection_safe\" | \"canonical\" | \"cost_bounded\">`.";

const stamp_dropped_source =
    \\function stamp(): number {
    \\  return Date.now();
    \\}
    \\
    \\export function handler(req: Request): Response {
    \\  const t = stamp();
    \\  return Response.text("ok");
    \\}
;

test "compileHandler graph gives a clock helper of the entry the ZTS500 capsule that leaves out the property of each ZTS606 row" {
    var fixture = try importFixture(
        \\import { greet } from "./dep.ts";
        \\
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Response {
        \\  const t = stamp();
        \\  return Response.text(greet());
        \\}
        \\
    , greet_ok_dep);
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const rows = contract.spec_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.not_discharged, rows[0].kind);
    try std.testing.expectEqualStrings(stamp_dropped_suggestion, rows[0].suggestion orelse "(null)");
    try std.testing.expectEqualStrings("pure", rows[1].spec_name);
    try std.testing.expectEqualStrings("deterministic", rows[2].spec_name);
}

test "compileHandler gives a clock helper the ZTS500 capsule that leaves out the property of each ZTS606 row" {
    const allocator = std.testing.allocator;
    var compiled = try compileHandler(allocator, stamp_dropped_source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const rows = contract.spec_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.not_discharged, rows[0].kind);
    try std.testing.expectEqualStrings("pure", rows[0].spec_name);
    try std.testing.expectEqualStrings(stamp_dropped_suggestion, rows[0].suggestion orelse "(null)");
    try std.testing.expectEqualStrings("pure", rows[1].spec_name);
    try std.testing.expectEqualStrings("deterministic", rows[2].spec_name);
}

test "control: compileHandler keeps the authored ZTS606 row under a declared deterministic capsule" {
    const allocator = std.testing.allocator;
    const source =
        \\function stamp(): number {
        \\  return Date.now();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const t = stamp();
        \\  return Response.text("ok");
        \\}
    ;
    var compiled = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    const rows = contract.spec_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(zts.SpecDiagnostic.Kind.missing_capsule, rows[0].kind);
    try std.testing.expect(!rows[0].implicit_default);
    try std.testing.expectEqualStrings("deterministic", rows[0].spec_name);
    try std.testing.expectEqualStrings("annotate `stamp` with `Proof<T, \"deterministic\">` and satisfy it, or inline the helper into the handler.", rows[0].suggestion orelse "(null)");
}

test "compileHandler of a handler that holds every default property keeps no spec diagnostic in the contract" {
    const allocator = std.testing.allocator;
    const source =
        \\export function handler(req: Request): Response {
        \\  return Response.text("ok");
        \\}
    ;
    var compiled = try compileHandler(allocator, source, "handler.ts", .{ .emit_contract = true, .emit_verify = true });
    defer compiled.deinit(allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 0), contract.spec_diagnostics.items.len);
}

const cross_writer_dep =
    \\let count = 0;
    \\
    \\export function bump(): number {
    \\  count = count + 1;
    \\  return count;
    \\}
    \\
;

const cross_writer_entry =
    \\import { bump } from "./dep.ts";
    \\
    \\function tally(): Proof<number, "read_only"> {
    \\  return bump();
    \\}
    \\
    \\export function handler(req: Request): Proof<Response, "injection_safe"> {
    \\  return Response.text("ok");
    \\}
    \\
;

test "compileHandler graph refuses read_only on a helper that calls a module-state writer of a dependency" {
    var fixture = try importFixture(cross_writer_entry, cross_writer_dep);
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses read_only on a dependency helper that calls a module-state writer of a third file" {
    var fixture = try importFixture(
        \\import { tally } from "./a.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    , cross_writer_dep);
    defer fixture.deinit();
    try fixture.add("a.ts",
        \\import { bump } from "./dep.ts";
        \\
        \\export function tally(): Proof<number, "read_only"> {
        \\  return bump();
        \\}
        \\
    );
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses read_only on a helper that calls an inline arrow writer held by a dependency object" {
    var fixture = try importFixture(
        \\import { api } from "./dep.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return api.bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    ,
        \\let count = 0;
        \\
        \\export const api = { bump: (): number => { count = count + 1; return count; } };
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses read_only on a helper that calls a named writer through a dependency holder" {
    var fixture = try importFixture(
        \\import { api } from "./dep.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return api.bump();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    ,
        \\let count = 0;
        \\
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export const api = { bump: bump };
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses read_only on a helper over a relay export over a writer of a third file" {
    var fixture = try importFixture(
        \\import { tally } from "./a.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text("ok");
        \\}
        \\
    , cross_writer_dep);
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\import { bump } from "./dep.ts";
        \\
        \\export function relay(): number {
        \\  return bump();
        \\}
        \\
    );
    try fixture.add("a.ts",
        \\import { relay } from "./b.ts";
        \\
        \\export function tally(): Proof<number, "read_only"> {
        \\  return relay();
        \\}
        \\
    );
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph keeps read_only on a helper over a clean export of a module that also holds a writer" {
    var fixture = try importFixture(
        \\import { peek } from "./dep.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return peek();
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "injection_safe"> {
        \\  return Response.text(String(tally()));
        \\}
        \\
    ,
        \\let count = 0;
        \\
        \\export function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export function peek(): number {
        \\  return 1;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const contract = compiled.contract orelse return error.MissingContract;
    try std.testing.expectEqual(@as(usize, 0), contract.spec_diagnostics.items.len);
}

test "compileHandler graph refuses an Effects ceiling that a dependency helper breaks" {
    var fixture = try importFixture(
        \\import { digest } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(digest());
        \\}
        \\
    ,
        \\import { sha256 } from "zttp:crypto";
        \\
        \\export function digest(): Effects<string, "clock"> {
        \\  return sha256("a");
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses a false Proof capsule on an arrow helper of a dependency" {
    var fixture = try importFixture(capsule_stamp_entry,
        \\const clock = (): Proof<number, "pure"> => {
        \\  return Date.now();
        \\};
        \\
        \\export function stamp(): number {
        \\  return clock();
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses a false capsule on a dependency helper that no module calls" {
    var fixture = try importFixture(
        \\import { one } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(one()));
        \\}
        \\
    ,
        \\export function unused(): Proof<number, "pure"> {
        \\  return Date.now();
        \\}
        \\
        \\export function one(): number {
        \\  return 1;
        \\}
        \\
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses a dependency helper capsule that a module-state write breaks" {
    var fixture = try importFixture(
        \\import { bump } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(bump()));
        \\}
        \\
    ,
        \\let count: number = 0;
        \\
        \\export function bump(): Proof<number, "pure"> {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph refuses a read_only capsule on a dependency helper whose write only the flow evaluator finds" {
    var fixture = try importFixture(
        \\import { run } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "result_safe"> {
        \\  return Response.text(String(run()));
        \\}
        \\
    ,
        \\const seen: number[] = [];
        \\
        \\function addTo(xs: number[]): undefined {
        \\  xs.push(1);
        \\  return undefined;
        \\}
        \\
        \\function record(): Proof<number, "read_only"> {
        \\  addTo(seen);
        \\  return 1;
        \\}
        \\
        \\export function run(): number {
        \\  return record();
        \\}
        \\
    );
    defer fixture.deinit();
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph accepts a true Proof capsule on a dependency helper" {
    var fixture = try importFixture(
        \\import { double } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(double(2)));
        \\}
        \\
    ,
        \\export function double(x: number): Proof<number, "pure" | "total"> {
        \\  return x * 2;
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), compiled.contract.?.spec_diagnostics.items.len);
}

test "compileHandler graph composes a dependency helper capsule through a third file" {
    const entry =
        \\import { viaB } from "./a.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(viaB()));
        \\}
        \\
    ;
    const b_source =
        \\export function one(): number {
        \\  return 1;
        \\}
        \\
    ;
    var held = try CompileGraphFixture.init("entry.ts", entry);
    defer held.deinit();
    try held.add("b.ts", b_source);
    try held.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "read_only"> {
        \\  return one();
        \\}
        \\
    );
    var compiled = try held.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), compiled.contract.?.spec_diagnostics.items.len);

    var refused = try CompileGraphFixture.init("entry.ts", entry);
    defer refused.deinit();
    try refused.add("b.ts", b_source);
    try refused.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "pure"> {
        \\  return one();
        \\}
        \\
    );
    try std.testing.expectError(error.SpecDiagnosticsRefused, refused.compile(graph_verified));
}

test "compileHandler graph refuses deterministic on a dependency helper that calls a clock reader of a third file" {
    var fixture = try CompileGraphFixture.init("entry.ts",
        \\import { viaB } from "./a.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(String(viaB()));
        \\}
        \\
    );
    defer fixture.deinit();
    try fixture.add("b.ts",
        \\export function one(): number {
        \\  return Date.now();
        \\}
        \\
    );
    try fixture.add("a.ts",
        \\import { one } from "./b.ts";
        \\
        \\export function viaB(): Proof<number, "deterministic"> {
        \\  return one();
        \\}
        \\
    );
    try std.testing.expectError(error.SpecDiagnosticsRefused, fixture.compile(graph_verified));
}

test "compileHandler graph compiles a dependency helper whose Effects capability it never reaches" {
    var fixture = try importFixture(
        \\import { label } from "./dep.ts";
        \\
        \\export function handler(req: Request): Proof<Response, "read_only"> {
        \\  return Response.text(label());
        \\}
        \\
    ,
        \\export function label(): Effects<string, "clock"> {
        \\  return "x";
        \\}
        \\
    );
    defer fixture.deinit();
    var compiled = try fixture.compile(graph_verified);
    defer compiled.deinit(std.testing.allocator);
    const rows = compiled.contract.?.spec_diagnostics.items;
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("label", rows[0].function orelse return error.TestUnexpectedResult);
    const site = rows[0].site orelse return error.TestUnexpectedResult;
    const directory = std.fs.path.dirname(fixture.entry_path) orelse return error.TestUnexpectedResult;
    const expected_file = try std.fs.path.join(std.testing.allocator, &.{ directory, "dep.ts" });
    defer std.testing.allocator.free(expected_file);
    try std.testing.expectEqualStrings(expected_file, site.file orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u32, 1), site.line);
}
