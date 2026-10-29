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
pub const loadFlowModulesForCheck = imports_mod.loadFlowModulesForCheck;
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
pub const main = precompile_cli_mod.main;
pub const runCompileWithArgs = precompile_cli_mod.runCompileWithArgs;
pub const CheckOptions = precompile_check_run_mod.CheckOptions;
pub const readFailureReason = precompile_stderr_mod.readFailureReason;
pub const runCheckOnlyWithOptions = precompile_check_run_mod.runCheckOnlyWithOptions;
const stampFaultCoverage = precompile_check_run_mod.stampFaultCoverage;
const summarizeGeneratedPaths = precompile_check_run_mod.summarizeGeneratedPaths;
pub const runCheckOnlyFromSourceWithOptions = precompile_check_run_mod.runCheckOnlyFromSourceWithOptions;
pub const runGenTests = precompile_gen_tests_mod.runGenTests;
const validateVirtualModuleImports = precompile_virtual_imports_mod.validateVirtualModuleImports;
const analyzeAot = precompile_contract_mod.analyzeAot;
const extractContractFromAnalysis = precompile_contract_mod.extractContractFromAnalysis;
const reportCompletedFlow = precompile_contract_mod.reportCompletedFlow;
const validateContractPolicyInputs = precompile_contract_mod.validateContractPolicyInputs;
const buildMultiModuleContract = precompile_contract_mod.buildMultiModuleContract;

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
    if (source_kind == .unsupported) return error.UnsupportedSourceExtension;
    var diag_view = zts.SourceView.of(source);
    diag_view.name = filename;
    diag_view.normalize_positions = source_kind.isTyped();
    var strings = zts.StringTable.init(allocator);
    defer strings.deinit();
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = switch (source_kind) {
        .typescript => try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile),
        .virtual_javascript => try zts.parser.JsParser.init(allocator, source),
        .unsupported => unreachable,
    };
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = if (source_kind.isTyped()) switch (try js_parser.parseAdmission()) {
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
    } else js_parser.parse() catch |err| {
        printParseErrors(allocator, diag_view, js_parser.getProjectedErrors());
        return err;
    };

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
            emit_contract,
            policy,
            sql_schema_path,
            manifest_registry,
        );
    }

    const ir_view_check = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    if (source_kind.isTyped()) try js_parser.type_store.validateRuntimeOwners(allocator, ir_view_check);
    var parsed = if (source_kind.isTyped())
        zts.pipeline.ParsedModule.fromTypedExisting(ir_view_check, root, &atoms, &js_parser.type_store)
    else
        zts.pipeline.ParsedModule.fromExisting(ir_view_check, root, &atoms);
    parsed.scopes = &js_parser.scopes;

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initFull(
        allocator,
        parsed,
        .{
            .source_types = if (source_kind.isTyped()) .direct else .omitted,
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

    if (source_kind.isTyped()) {
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
    // reportCompletedFlow (flow violations), and the PathGenerator block (fault violations).
    var all_violations: std.ArrayList(zts.property_diagnostics.PropertyViolation) = .empty;
    defer {
        zts.property_diagnostics.deinitViolations(allocator, all_violations.items);
        all_violations.deinit(allocator);
    }

    // Run handler verification if requested
    var verify_info: ?VerificationInfo = null;
    var state_isolated: bool = false;
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
            try reportCompletedFlow(
                allocator,
                try analysis.completedFlow(),
                analysis.flowErrorCount(),
                true,
                &all_violations,
                ir_view_check,
            );
        }
        try validateContractPolicyInputs(allocator, filename, &contract.?, sql_schema_path, policy);
        try precompile_contract_mod.disclosePublicEnv(allocator, &contract.?, env_public);

        // Inject verification-derived properties (Checks 2, 6, 7)
        if (contract.?.properties) |*props| {
            props.state_isolated = state_isolated;
            props.result_safe = result_safe;
            props.optional_safe = optional_safe;
        }
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

            // The check path and this path write the record and the property
            // bit for every handler. A handler with no failable site holds
            // `fault_covered` when the analysis is complete. The cause is
            // stamped the way the check path stamps it.
            if (contract) |*c| {
                if (c.properties) |*props| props.fault_covered = fault_stamp.clean;
                c.fault_coverage = fault_stamp.coverage;
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

    const contract = try buildMultiModuleContract(
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

    return .{
        .bytecode = entry_bytecode,
        .dep_bytecodes = dep_bytecodes,
        .contract = contract,
    };
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
        \\export function handler(req) {
        \\  return Response.text(readName());
        \\}
    ;
    const dep_source =
        \\import { env } from "zttp:env";
        \\export function readName() {
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

test "multi-module compile proves no security property in the extracted facts" {
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
    try std.testing.expect(merged.properties == null);

    const extracted = try deploy_manifest.extractProvenFacts(allocator, &merged);
    defer allocator.free(extracted.routes_buf);

    const names = [_][]const u8{
        "injection_safe",
        "state_isolated",
        "deterministic",
        "no_secret_leakage",
        "no_credential_leakage",
        "input_validated",
        "pii_contained",
    };
    inline for (names) |name| {
        try std.testing.expect(!@field(extracted.facts, name));
    }
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
    _ = @import("pipeline_mutation_tests.zig");
    _ = @import("flow_false_proofs.zig");
    _ = @import("flow_precision_expectations.zig");
    _ = @import("bytecode_identity_golden.zig");
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
