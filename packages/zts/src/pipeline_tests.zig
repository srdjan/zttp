//! Tests for the analysis pipeline: resolution, checked passes, contract extraction, and module analysis sessions.

const std = @import("std");
const parser_mod = @import("zts-engine").parser;
const bool_checker_mod = @import("bool_checker.zig");
const type_checker_mod = @import("type_checker.zig");
const strict_checker_mod = @import("strict_checker.zig");
const handler_verifier_mod = @import("handler_verifier.zig");
const handler_function_mod = @import("handler_function.zig");
const flow_checker_mod = @import("flow_checker.zig");
const context_mod = @import("zts-engine").context;
const type_env_mod = @import("type_env.zig");
const type_pool_mod = @import("type_pool.zig");
const modules_mod = @import("zts-engine").modules;
const module_types_mod = @import("module_types.zig");
const abi_types_mod = @import("abi_types.zig");
const ir_mod = @import("zts-engine").parser.ir;
const handler_contract_mod = @import("zts-contracts").handler_contract;
const contract_builder_mod = @import("contract_builder.zig");
const manifest_registry_mod = @import("manifest_registry.zig");
const bytecode_mod = @import("zts-engine").bytecode;
const source_frontend_mod = @import("zts-engine").source_frontend;
const string_mod = @import("zts-engine").string;
const effect_inference = @import("effect_inference.zig");
const NodeIndex = ir_mod.NodeIndex;
const IrView = ir_mod.IrView;
const TypeChecker = type_checker_mod.TypeChecker;
const AtomTable = context_mod.AtomTable;
const TypeEnv = type_env_mod.TypeEnv;
const TypePool = type_pool_mod.TypePool;
const TypeSyntax = parser_mod.type_syntax;
const HandlerContract = handler_contract_mod.HandlerContract;
const VerificationInfo = handler_contract_mod.VerificationInfo;
const ContractBuilder = contract_builder_mod.ContractBuilder;
const PatternDispatchTable = bytecode_mod.PatternDispatchTable;
const pipeline_mod = @import("pipeline.zig");
const ExtractContractOptions = pipeline_mod.ExtractContractOptions;
const ContractExtraction = pipeline_mod.ContractExtraction;
const ModuleAnalysisSession = pipeline_mod.ModuleAnalysisSession;
const ParsedModule = pipeline_mod.ParsedModule;
const extractContract = pipeline_mod.extractContract;
const resolve = pipeline_mod.resolve;
const TypeEnvStorage = pipeline_mod.TypeEnvStorage;
const ModuleFacts = pipeline_mod.ModuleFacts;
const ImportedEffect = pipeline_mod.ImportedEffect;
const ExportEffect = pipeline_mod.ExportEffect;
const buildModuleFacts = pipeline_mod.buildModuleFacts;
const CheckedModule = pipeline_mod.CheckedModule;
const LoadedModuleEffects = pipeline_mod.LoadedModuleEffects;
const importedEffectsForLoadedModule = pipeline_mod.importedEffectsForLoadedModule;
const ResolvedModule = pipeline_mod.ResolvedModule;
const ModuleSourceTypeInput = pipeline_mod.ModuleSourceTypeInput;
const EffectFacts = pipeline_mod.EffectFacts;
const extractPreparedEvalContract = pipeline_mod.extractPreparedEvalContract;
const projectFlowProperties = pipeline_mod.projectFlowProperties;
const FlowWithoutHandler = pipeline_mod.FlowWithoutHandler;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const JsParser = parser_mod.JsParser;

fn parseSourceForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    js_parser: JsParser,
    root: NodeIndex,
} {
    var js_parser = try JsParser.init(allocator, source);
    errdefer js_parser.deinit();
    const root = try js_parser.parse();
    return .{ .js_parser = js_parser, .root = root };
}

fn readGraphBaselineFile(allocator: std.mem.Allocator, path: []const u8) modules_mod.module_graph.ReadFileError![]const u8 {
    const source: []const u8 = if (std.mem.endsWith(u8, path, "shared.ts"))
        \\import { sqlOne } from "zttp:sql";
        \\export function shared() {
        \\  return fetchSync("https://shared.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "left.ts"))
        \\import { shared } from "./shared.ts";
        \\import { env } from "zttp:env";
        \\export function left() {
        \\  shared();
        \\  env("LEFT_TOKEN");
        \\  return fetchSync("https://left.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "right.ts"))
        \\import { shared } from "./shared.ts";
        \\import { cacheGet } from "zttp:cache";
        \\export function right() {
        \\  shared();
        \\  cacheGet("RIGHT_CACHE", "key");
        \\  return fetchSync("https://right.example/a");
        \\}
    else if (std.mem.endsWith(u8, path, "typed-bad.ts"))
        \\export function request() {
        \\  const port: number = "bad";
        \\  return fetchSync("https://typed-dependency.example/a");
        \\}
    else
        return error.FileNotFound;

    return allocator.dupe(u8, source);
}

fn readSiblingEffectFile(allocator: std.mem.Allocator, path: []const u8) modules_mod.module_graph.ReadFileError![]const u8 {
    if (!std.mem.endsWith(u8, path, "dep.ts")) return error.FileNotFound;
    return allocator.dupe(u8,
        \\import { cacheSet } from "zttp:cache";
        \\export function mutate() { cacheSet("state", "key", "value"); }
    );
}

const GraphCallbackModule = enum {
    shared,
    left,
    right,
    entry,
};

const GraphCallbackProbe = struct {
    modules: [4]GraphCallbackModule = undefined,
    count: usize = 0,
    fail_after: ?usize = null,
};

threadlocal var active_graph_callback_probe: ?*GraphCallbackProbe = null;

fn graphCallbackModule(type_checker: *const TypeChecker) ?GraphCallbackModule {
    for (0..type_checker.ir_view.nodeCount()) |idx| {
        const node: NodeIndex = @intCast(idx);
        const tag = type_checker.ir_view.getTag(node) orelse continue;
        if (tag != .import_decl) continue;
        const import_decl = type_checker.ir_view.getImportDecl(node) orelse continue;
        const module_name = type_checker.ir_view.getString(import_decl.module_idx) orelse continue;
        if (std.mem.eql(u8, module_name, "zttp:sql")) return .shared;
        if (std.mem.eql(u8, module_name, "zttp:env")) return .left;
        if (std.mem.eql(u8, module_name, "zttp:cache")) return .right;
        if (std.mem.eql(u8, module_name, "zttp:fetch")) return .entry;
    }
    return null;
}

fn recordGraphContractTypeCheck(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
    const probe = active_graph_callback_probe orelse return error.GraphCallbackProbeMissing;
    if (probe.count >= probe.modules.len) return error.GraphCallbackCountExceeded;
    probe.modules[probe.count] = graphCallbackModule(type_checker) orelse
        return error.GraphCallbackModuleUnknown;
    probe.count += 1;
    if (probe.fail_after == probe.count) return error.GraphCallbackRefused;
    return type_checker.check(root);
}

fn serializeContractForTest(allocator: std.mem.Allocator, contract: *const HandlerContract) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try handler_contract_mod.writeContractJson(contract, &output.writer);
    return output.toOwnedSlice();
}

fn extractSessionContractForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    opts: ExtractContractOptions,
) !ContractExtraction {
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(
        allocator,
        ParsedModule.fromExisting(view, root, &atoms),
        .{ .extraction = opts },
    );
    defer analysis.deinit();
    try analysis.complete();

    var contract = try analysis.extractContract(filename);
    errdefer contract.deinit(allocator);
    return .{
        .contract = contract,
        .export_effects = analysis.takeExportEffects(),
    };
}

fn hasSpecDiagnosticKind(
    contract: *const HandlerContract,
    kind: handler_contract_mod.SpecDiagnostic.Kind,
) bool {
    for (contract.spec_diagnostics.items) |diagnostic| {
        if (diagnostic.kind == kind) return true;
    }
    return false;
}

fn expectStringSlices(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_item, actual_item| {
        try testing.expectEqualStrings(expected_item, actual_item);
    }
}

test "ParsedModule.fromExisting wraps an IR view" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const x = true;\n");
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    try testing.expect(view.isValid(parsed.root));
}

test "pipeline.resolve does not emit a module after analysis allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const enabled = true;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, resolve(failing.allocator(), parsed, .{ .strict = false }));
}

test "TypeEnvStorage rejects a poisoned TypePool" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, storage.initWithSource(failing.allocator(), .omitted));
    try testing.expect(storage.envPtr() == null);
    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
}

test "TypeEnvStorage rejects a late poisoned TypePool" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    storage.pool = TypePool.init(allocator);
    defer storage.pool.deinit(allocator);
    try storage.pool.ensureHealthy();
    storage.env = TypeEnv.init(allocator, &storage.pool);
    defer storage.env.deinit();
    try storage.pool.ensureHealthy();
    module_types_mod.populateModuleTypes(&storage.env, &storage.pool, allocator);
    abi_types_mod.populateHandlerAbiTypes(&storage.env, &storage.pool, allocator);
    try storage.pool.ensureHealthy();
    try storage.env.populateSourceTypes(.omitted);
    try storage.pool.ensureHealthy();

    const record = storage.pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = storage.pool.idx_string,
        .optional = false,
    }});
    try storage.pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = storage.pool.makeReadonly(failing.allocator(), record);

    try testing.expectError(error.OutOfMemory, storage.finishInitialization());
    try testing.expect(storage.envPtr() == null);
}

test "TypeEnvStorage initializes module types with omitted source types" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);

    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
}

test "TypeEnvStorage rejects a second initialization before allocation" {
    const allocator = testing.allocator;
    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);

    try storage.initWithSource(allocator, .omitted);
    const original_env = storage.envPtr().?;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    try testing.expectError(
        error.TypeEnvironmentAlreadyInitialized,
        storage.initWithSource(failing.allocator(), .omitted),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(original_env, storage.envPtr().?);
    try storage.pool.ensureHealthy();

    storage.deinit(allocator);
    try testing.expect(storage.envPtr() == null);
    try storage.initWithSource(allocator, .omitted);
    try testing.expect(storage.envPtr() != null);
    try storage.pool.ensureHealthy();
}

fn rejectingContractTypeCheck(_: *TypeChecker, _: NodeIndex) anyerror!u32 {
    return error.TestTypeCheckRan;
}

test "ModuleAnalysisSession requires completion and permits one extraction" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text('ok'); }\n";
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(allocator, parsed, .{});
    defer analysis.deinit();

    try testing.expectError(error.AnalysisNotCompleted, analysis.facts());
    try testing.expectError(error.AnalysisNotCompleted, analysis.pathEffectFacts());
    try testing.expectError(error.AnalysisNotCompleted, analysis.setImportedEffects(&.{}));
    try testing.expectError(error.AnalysisNotCompleted, analysis.extractContract("owner.ts"));
    try analysis.complete();
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    _ = try analysis.facts();
    const first_path_effects = try analysis.pathEffectFacts();
    const second_path_effects = try analysis.pathEffectFacts();
    switch (first_path_effects) {
        .complete => |first| switch (second_path_effects) {
            .complete => |second| try testing.expect(first == second),
            .unavailable => return error.EffectFactsExpected,
        },
        .unavailable => return error.EffectFactsExpected,
    }
    try analysis.setImportedEffects(&.{});

    var contract = try analysis.extractContract("owner.ts");
    defer contract.deinit(allocator);
    try testing.expectEqualStrings("owner.ts", contract.handler.path);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("owner.ts"),
    );
}

test "partial contract facts do not suppress imported export type diagnostics" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator,
        \\import { sha256 as digest } from "zttp:crypto";
        \\digest("a", "b");
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var storage: TypeEnvStorage = .{};
    try storage.initWithSource(allocator, .omitted);
    defer storage.deinit(allocator);
    var partial = ModuleFacts{ .allocator = allocator };
    defer partial.deinit();
    var resolved = try resolve(allocator, parsed, .{
        .type_env = storage.envPtr(),
        .strict = false,
        .module_facts = &partial,
    });
    defer resolved.deinit();
    try testing.expectEqual(@as(u32, 1), resolved.typeErrorCount());
    const diagnostic = resolved.type_checker.?.getDiagnostics()[0];
    try testing.expectEqual(type_checker_mod.DiagnosticKind.arg_count_mismatch, diagnostic.kind);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message, "expected 1, got 2") != null);
}

test "ModuleAnalysisSession caches unavailable path effects after one attempt" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{});
    defer analysis.deinit();
    try analysis.complete();
    const changed = [_]ImportedEffect{.{ .slot = 0, .effect = .{ .callable = .{ .writes = true } } }};

    failing.fail_index = failing.alloc_index;
    switch (try analysis.pathEffectFacts()) {
        .unavailable => {},
        .complete => return error.UnavailableEffectFactsExpected,
    }
    try testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&changed));
    try testing.expectError(error.ImportedEffectsFrozen, analysis.setContractContext(.{ .imported_effects = &changed }));
    try analysis.setContractContext(.{ .has_default_response = true });
    switch (try analysis.pathEffectFacts()) {
        .unavailable => {},
        .complete => return error.UnavailableEffectFactsExpected,
    }
}

test "ModuleAnalysisSession freezes imported summaries for paths and contracts" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator,
        \\import { run } from "./helper.ts";
        \\function handler(req) { run(); return Response.text("ok"); }
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    for ([_]ModuleAnalysisSession.Profile{ .contract_only, .sound_extraction, .full }) |profile| {
        for ([_]bool{ false, true }) |writes| {
            var analysis: ModuleAnalysisSession = .{};
            switch (profile) {
                .contract_only => try analysis.initContractOnly(allocator, parsed, .{}),
                .sound_extraction => try analysis.initSoundExtraction(allocator, parsed, .{ .strict = false }),
                .full => try analysis.initFull(allocator, parsed, .{ .strict = false }),
            }
            defer analysis.deinit();
            try analysis.complete();
            const facts_ptr = try analysis.facts();
            try testing.expectEqual(@as(usize, 1), facts_ptr.imports.items.len);
            const slot = facts_ptr.imports.items[0].slot;
            const selected = [_]ImportedEffect{.{ .slot = slot, .effect = .{ .callable = .{ .writes = writes } } }};
            const changed = [_]ImportedEffect{.{ .slot = slot, .effect = .{ .callable = .{ .writes = !writes } } }};

            // Completion still permits dependency assembly. Both setters can
            // replace a genuinely different summary before facts are requested.
            try analysis.setImportedEffects(&changed);
            try analysis.setContractContext(.{ .imported_effects = &selected });
            try analysis.setImportedEffects(&changed);
            try analysis.setImportedEffects(&selected);
            const path_effects = switch (try analysis.pathEffectFacts()) {
                .complete => |effects| effects,
                .unavailable => return error.EffectFactsExpected,
            };
            const path_row = path_effects.lookup("handler") orelse return error.FunctionNotFound;
            try testing.expectEqual(writes, path_row.writes);
            try testing.expect(!path_row.lower_bound);

            try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&changed));
            try testing.expectError(error.ImportedEffectsFrozen, analysis.setContractContext(.{
                .imported_effects = &changed,
                .has_default_response = true,
            }));
            try testing.expect(!analysis.contract_context.has_default_response);

            // Equal values in separate storage do not change dependencies.
            // Verification and dispatch metadata may arrive after path facts.
            const equivalent = selected;
            const verification = VerificationInfo{
                .exhaustive_returns = true,
                .results_safe = true,
                .unreachable_code = true,
            };
            var dispatch = PatternDispatchTable.init(allocator);
            defer dispatch.deinit();
            try analysis.setImportedEffects(&equivalent);
            try analysis.setContractContext(.{
                .imported_effects = &equivalent,
                .dispatch = &dispatch,
                .has_default_response = true,
                .verification = verification,
            });
            var contract = try analysis.extractContract("frozen.ts");
            defer contract.deinit(allocator);
            const properties = contract.properties orelse return error.PropertiesMissing;
            try testing.expectEqual(!writes, properties.read_only);
            try testing.expectEqual(verification, contract.verification.?);
            try testing.expect(contract.aot.?.has_default);
            const cached = switch (try analysis.pathEffectFacts()) {
                .complete => |effects| effects,
                .unavailable => return error.EffectFactsExpected,
            };
            try testing.expect(path_effects == cached);
            try testing.expectEqual(writes, cached.lookup("handler").?.writes);
        }
    }
}

test "ModuleAnalysisSession frozen imported effects retain slots and result kinds" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) { return Response.text('ok'); }");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const outcomes = [_]ExportEffect{ .{ .callable = .{} }, .{ .data = .{} }, .blocked };
    for (outcomes, 0..) |outcome, index| {
        var analysis: ModuleAnalysisSession = .{};
        try analysis.initContractOnly(allocator, parsed, .{});
        defer analysis.deinit();
        try analysis.complete();
        const selected = [_]ImportedEffect{.{ .slot = 0, .effect = outcome }};
        try analysis.setImportedEffects(&selected);
        _ = try analysis.pathEffectFacts();
        const equivalent = selected;
        try analysis.setImportedEffects(&equivalent);
        try analysis.setContractContext(.{ .imported_effects = &equivalent });
        for (outcomes, 0..) |other, other_index| {
            if (index == other_index) continue;
            const changed = [_]ImportedEffect{.{ .slot = 0, .effect = other }};
            try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&changed));
        }
        const changed_slot = [_]ImportedEffect{.{ .slot = 1, .effect = outcome }};
        try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&changed_slot));
        try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&.{}));
    }
}

test "ModuleAnalysisSession does not retry a refused sound analysis" {
    const allocator = testing.allocator;
    const source =
        \\if ({}) { const unreachable = true; }
        \\function handler(req) { return Response.text("ok"); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{ .strict = false });
    defer analysis.deinit();

    try testing.expectError(error.SoundModeViolation, analysis.complete());
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    try testing.expectError(error.AnalysisNotCompleted, analysis.extractContract("refused.ts"));
}

test "ModuleAnalysisSession cleans a partial completion failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{ .extraction = .{
        .capture_export_effects = true,
    } });
    defer analysis.deinit();

    try testing.expectError(error.OutOfMemory, analysis.complete());
    try testing.expect(failing.has_induced_failure);
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
}

test "ModuleAnalysisSession publishes owned exports for both extraction profiles" {
    const allocator = testing.allocator;
    const source =
        \\export function sibling() { return Date.now(); }
        \\function handler(req) { return Response.text("ok"); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    inline for (.{ ModuleAnalysisSession.Profile.contract_only, .sound_extraction }) |profile| {
        var analysis: ModuleAnalysisSession = .{};
        const extraction_opts = ExtractContractOptions{
            .strict = false,
            .capture_export_effects = true,
        };
        if (profile == .contract_only) {
            try analysis.initContractOnly(allocator, parsed, .{ .extraction = extraction_opts });
        } else {
            try analysis.initSoundExtraction(allocator, parsed, extraction_opts);
        }
        try analysis.complete();

        var contract = try analysis.extractContract("exports.ts");
        const contract_json = try serializeContractForTest(allocator, &contract);
        defer allocator.free(contract_json);
        try testing.expect(std.mem.indexOf(u8, contract_json, "effectAnalysisComplete") == null);
        try testing.expect(std.mem.indexOf(u8, contract_json, "effect_analysis_complete") == null);
        contract.deinit(allocator);
        var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
        analysis.deinit();
        defer effects.deinit(allocator);

        switch (effects.lookup("sibling")) {
            .callable => |row| try testing.expect(!row.deterministic),
            .data, .blocked => return error.CallableExportExpected,
        }
    }
}

test "contract summary keeps selected handler separate from first named effect row" {
    const allocator = testing.allocator;
    const source =
        \\import { cacheSet } from "zttp:cache";
        \\{
        \\  function handler(req) { return Response.text("local"); }
        \\}
        \\function handler(req): Effects<Response, "clock"> {
        \\  cacheSet("state", "key", "value", 10);
        \\  return Response.text("global");
        \\}
    ;
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "duplicate-handler.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initFull(allocator, ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    ), .{
        .source_types = .direct,
        .strict = false,
    });
    defer analysis.deinit();
    try analysis.complete();
    var result = try analysis.extractContract("duplicate-handler.ts");
    defer result.deinit(allocator);

    const contract = &result;
    const props = contract.properties orelse return error.MissingProperties;
    try testing.expect(!props.pure);
    try testing.expect(!props.read_only);
    try testing.expect(!props.stateless);
    try testing.expect(!props.retry_safe);
    try testing.expect(props.deterministic);
    try testing.expect(!props.has_egress);
    try testing.expect(!props.idempotent);

    try testing.expect(contract.effect_analysis_complete);
    try testing.expect(contract.capability_budget.has(.clock));
    try testing.expect(!contract.capability_budget.has(.policy_check));
    try testing.expect(!hasSpecDiagnosticKind(contract, .budget_exceeded));
    try testing.expect(!hasSpecDiagnosticKind(contract, .helper_budget_exceeded));
}

test "ambient egress summary follows inline callbacks but not named callback values" {
    const allocator = testing.allocator;
    const named_source =
        \\export function leaky() {
        \\  return fetchSync("https://named.example/a");
        \\}
        \\function handler(req) {
        \\  [1].map(leaky);
        \\  return Response.text("ok");
        \\}
    ;
    const inline_source =
        \\function handler(req) {
        \\  [1].map(() => fetchSync("https://inline.example/a"));
        \\  return Response.text("ok");
        \\}
    ;
    var named = try extractSessionContractForTest(
        allocator,
        named_source,
        "named-callback.ts",
        .{ .strict = false, .capture_export_effects = true },
    );
    defer named.deinit(allocator);
    var inline_callback = try extractSessionContractForTest(
        allocator,
        inline_source,
        "inline-callback.ts",
        .{ .strict = false },
    );
    defer inline_callback.deinit(allocator);

    const named_props = named.contract.properties orelse return error.MissingProperties;
    const inline_props = inline_callback.contract.properties orelse return error.MissingProperties;
    try testing.expect(!named_props.has_egress);
    try testing.expect(inline_props.has_egress);

    const exports = named.export_effects orelse return error.ExportEffectsMissing;
    switch (exports.lookup("leaky")) {
        .callable => |row| {
            try testing.expect(row.pure);
            try testing.expect(!row.has_egress);
            try testing.expect(!row.writes);
            try testing.expect(row.lower_bound);
        },
        .data, .blocked => return error.CallableExportExpected,
    }

    try testing.expectEqual(@as(usize, 1), named.contract.function_effect_capsules.items.len);
    const capsule = named.contract.function_effect_capsules.items[0];
    try testing.expectEqualStrings("leaky", capsule.function);
    try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
    try testing.expectEqual(@as(usize, 0), capsule.inferred.items.len);
    try testing.expect(!capsule.discharged);
    try testing.expect(capsule.exported);
    try testing.expect(capsule.handler_reachable);
}

test "a local function sharing a slot with an import atom still reports its egress" {
    const allocator = testing.allocator;
    const source =
        \\import { env as length } from "zttp:env";
        \\function handler(req) {
        \\  const a = 1;
        \\  const b = 2;
        \\  const c = 3;
        \\  function leaky() { return fetchSync("https://legacy.example/a"); }
        \\  leaky();
        \\  return Response.text("ok");
        \\}
    ;
    var extraction = try extractSessionContractForTest(
        allocator,
        source,
        "generic-precedence.ts",
        .{ .strict = false },
    );
    defer extraction.deinit(allocator);

    const props = extraction.contract.properties orelse return error.MissingProperties;
    // The old slot-only lookup took `leaky` for the `env` import and hid the fetchSync.
    try testing.expect(props.has_egress);
}

test "no-handler properties include every unused builtin import" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        read_only: bool,
        stateless: bool,
        retry_safe: bool,
    }{
        .{
            .source = "import { cacheGet } from \"zttp:cache\";",
            .read_only = true,
            .stateless = false,
            .retry_safe = true,
        },
        .{
            .source = "import { cacheSet } from \"zttp:cache\";",
            .read_only = false,
            .stateless = false,
            .retry_safe = false,
        },
    };

    for (cases) |case| {
        var extraction = try extractSessionContractForTest(
            allocator,
            case.source,
            "no-handler-builtin.ts",
            .{ .strict = false },
        );
        defer extraction.deinit(allocator);
        const contract = &extraction.contract;
        const props = contract.properties orelse return error.MissingProperties;
        try testing.expect(!props.pure);
        try testing.expectEqual(case.read_only, props.read_only);
        try testing.expectEqual(case.stateless, props.stateless);
        try testing.expectEqual(case.retry_safe, props.retry_safe);
        try testing.expect(!props.deterministic);
        try testing.expect(!props.has_egress);
        try testing.expect(!props.idempotent);
        try testing.expect(!contract.effect_analysis_complete);
    }
}

test "no-handler properties include an unused registered partner import" {
    const allocator = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:legacy-summary",
        \\  "exports": [
        \\    { "name": "lookup", "effect": "read", "returns": "result" }
        \\  ]
        \\}
    ;
    var manifest = try @import("zts-engine").module_manifest.parse(allocator, manifest_json);
    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    var extraction = try extractSessionContractForTest(
        allocator,
        "import { lookup } from \"zttp-ext:legacy-summary\";",
        "no-handler-partner.ts",
        .{ .strict = false, .manifest_registry = &registry },
    );
    defer extraction.deinit(allocator);

    const contract = &extraction.contract;
    const props = contract.properties orelse return error.MissingProperties;
    try testing.expect(!props.pure);
    try testing.expect(props.read_only);
    try testing.expect(props.stateless);
    try testing.expect(props.retry_safe);
    try testing.expect(!props.deterministic);
    try testing.expect(!props.has_egress);
    try testing.expect(!props.idempotent);
    try testing.expect(!contract.effect_analysis_complete);
}

test "late export capture failure releases a transferred rate limit namespace" {
    const allocator = testing.allocator;
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\export function allowed() { return rateCheck("login-attempts", 5, 60); }
        \\function handler(req) { return Response.text(String(allowed())); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.init(allocator, source);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    const Run = struct {
        fn extract(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initContractOnly(run_allocator, module, .{ .extraction = .{
                .capture_export_effects = true,
            } });
            defer analysis.deinit();
            try analysis.complete();

            var contract = try analysis.extractContract("rate-limit.ts");
            defer contract.deinit(run_allocator);
            try testing.expect(contract.rate_limiting != null);
            var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
            defer effects.deinit(run_allocator);
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.extract(counting.allocator(), parsed);
    try testing.expect(counting.alloc_index > 0);

    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = counting.alloc_index - 1,
    });
    try testing.expectError(error.OutOfMemory, Run.extract(failing.allocator(), parsed));
    try testing.expect(failing.has_induced_failure);
}

test "ModuleAnalysisSession refuses extraction retry after allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(failing.allocator(), parsed, .{ .extraction = .{
        .capture_export_effects = true,
    } });
    defer analysis.deinit();
    try analysis.complete();

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, analysis.extractContract("allocation.ts"));
    try testing.expect(failing.has_induced_failure);
    try testing.expect(analysis.contract_effect_facts == null);
    try testing.expect(analysis.takeExportEffects() == null);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("allocation.ts"),
    );
}

test "ModuleAnalysisSession profiles preserve type diagnostic acceptance" {
    const allocator = testing.allocator;
    const source =
        \\const joined = 1 + "y";
        \\function handler(req: Request): Response {
        \\  return Response.text(String(joined));
        \\}
    ;
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "profile.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parsed = ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    );

    var contract_only: ModuleAnalysisSession = .{};
    try contract_only.initContractOnly(allocator, parsed, .{
        .extraction = .{ .source_types = .direct },
    });
    defer contract_only.deinit();
    try contract_only.complete();
    var contract = try contract_only.extractContract("profile.ts");
    defer contract.deinit(allocator);

    var sound: ModuleAnalysisSession = .{};
    try sound.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .source_types = .direct,
    });
    defer sound.deinit();
    try testing.expectError(error.SoundModeViolation, sound.complete());
}

test "ModuleAnalysisSession full profile supports typed and untyped extraction" {
    const allocator = testing.allocator;
    const typed_source = "function handler(req: Request): Response { return Response.text('ok'); }\n";
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, typed_source, "typed.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const typed_parsed = ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    );

    var typed: ModuleAnalysisSession = .{};
    try typed.initFull(allocator, typed_parsed, .{
        .source_types = .direct,
        .strict = false,
    });
    defer typed.deinit();
    try testing.expect(!typed.type_env_storage.initialized);
    try testing.expect(typed.resolved == null);
    try typed.complete();
    try testing.expect((try typed.resolvedForReport()).type_checker != null);
    var typed_contract = try typed.extractContract("typed.ts");
    defer typed_contract.deinit(allocator);

    var untyped_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer untyped_state.js_parser.deinit();
    const untyped_view = IrView.fromIRStore(&untyped_state.js_parser.nodes, &untyped_state.js_parser.constants);
    const untyped_parsed = ParsedModule.fromExisting(untyped_view, untyped_state.root, null);
    var untyped: ModuleAnalysisSession = .{};
    try untyped.initFull(allocator, untyped_parsed, .{ .strict = false });
    defer untyped.deinit();
    try untyped.complete();
    try testing.expect((try untyped.resolvedForReport()).type_checker == null);
    try testing.expectEqual(ModuleAnalysisSession.PassState.ready, untyped.contract_type_state);
    var untyped_contract = try untyped.extractContract("untyped.ts");
    defer untyped_contract.deinit(allocator);
    try testing.expectEqual(ModuleAnalysisSession.PassState.completed, untyped.contract_type_state);
}

test "ModuleAnalysisSession keeps skipped passes distinct" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_function_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{ .strict = false });
    defer session.deinit();
    try session.complete();
    try testing.expectEqual(ModuleAnalysisSession.PassState.skipped, session.verifier_state);
    try testing.expectEqual(ModuleAnalysisSession.PassState.skipped, session.flow_state);
    try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
    try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
}

test "ModuleAnalysisSession refuses publication after failed selected passes" {
    const allocator = testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.text('ok'); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_function_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    inline for (.{ true, false }) |select_verifier| {
        var failing = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = std.math.maxInt(usize),
        });
        var session: ModuleAnalysisSession = .{};
        try session.initFull(failing.allocator(), parsed, .{
            .strict = false,
            .select_verifier = select_verifier,
            .select_flow = !select_verifier,
        });
        defer session.deinit();
        try session.complete();
        try session.prepareChecked(handler, .{ .module_facts = try session.facts() });

        failing.fail_index = failing.alloc_index;
        if (select_verifier) {
            try testing.expectError(error.OutOfMemory, session.runVerifier(handler));
            try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
        } else {
            try testing.expectError(error.OutOfMemory, session.runFlow(handler));
            try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
        }
        try testing.expect(failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectError(error.AnalysisPassIncomplete, session.extractContract("failed-pass.ts"));
        try testing.expect(session.takeExportEffects() == null);
    }
}

test "ModuleAnalysisSession explicit refusal stops selected passes and extraction" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_function_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{
        .strict = false,
        .select_verifier = true,
        .select_flow = true,
    });
    defer session.deinit();
    try session.complete();
    session.refuseResolution();
    _ = (try session.resolvedForReport()).boolDiagnostics();
    try testing.expectError(error.AnalysisPassUnavailable, session.runVerifier(handler));
    try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
    try testing.expectError(error.AnalysisNotResolved, session.extractContract("refused.ts"));
}

test "ModuleAnalysisSession extraction runs the selected flow pass once" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(
        allocator,
        "function handler(req) { return Response.text('ok'); }\n",
    );
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    const handler = handler_function_mod.findHandlerFunction(view, parsed.root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initContractOnly(allocator, parsed, .{ .select_flow = true });
    defer session.deinit();
    try session.complete();
    var contract = try session.extractContract("flow-after.ts");
    defer contract.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), session.flowErrorCount());
    _ = try session.completedFlow();
    try testing.expectError(error.AnalysisPassUnavailable, session.runFlow(handler));
}

fn extractOwnedSessionResultsForTest(allocator: std.mem.Allocator) !ContractExtraction {
    const source = "export function sibling() { return Date.now(); }\n" ++
        "function handler(req: Request): Response { return Response.text('ok'); }\n";
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initInPlace(allocator, allocator, source, "owned.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);

    var session: ModuleAnalysisSession = .{};
    try session.initContractOnly(
        allocator,
        ParsedModule.fromTypedExisting(view, accepted.root, accepted.atoms, accepted.type_store),
        .{ .extraction = .{ .source_types = .direct, .capture_export_effects = true } },
    );
    defer session.deinit();
    try session.complete();
    var contract = try session.extractContract("owned.ts");
    errdefer contract.deinit(allocator);
    return .{
        .contract = contract,
        .export_effects = session.takeExportEffects() orelse return error.ExportEffectsMissing,
    };
}

test "ModuleAnalysisSession results survive every borrowed input" {
    const allocator = testing.allocator;
    var extraction = try extractOwnedSessionResultsForTest(allocator);
    defer extraction.deinit(allocator);
    try testing.expectEqualStrings("owned.ts", extraction.contract.handler.path);
    switch (extraction.export_effects.?.lookup("sibling")) {
        .callable => |row| try testing.expect(!row.deterministic),
        .data, .blocked => return error.CallableExportExpected,
    }
}

test "ModuleAnalysisSession runs a custom callback only during extraction" {
    const allocator = testing.allocator;
    var source_owner: source_frontend_mod.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, "function handler(req) { return Response.text('ok'); }\n", "custom.ts");
    defer source_owner.deinit();
    const accepted = source_owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const parsed = ParsedModule.fromTypedExisting(accepted.ir_view, accepted.root, accepted.atoms, accepted.type_store);
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .source_types = .direct,
        .type_check = rejectingContractTypeCheck,
        .capture_export_effects = true,
    });
    defer analysis.deinit();

    try analysis.complete();
    try testing.expectError(error.TestTypeCheckRan, analysis.extractContract("custom.ts"));
    try testing.expect(analysis.contract_checker != null);
    try testing.expect(analysis.resolved.?.type_checker != null);
    try testing.expect(&analysis.contract_checker.? != &analysis.resolved.?.type_checker.?);
    try testing.expect(analysis.contract_facts == null);
    try testing.expect(analysis.takeExportEffects() == null);
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("custom.ts"),
    );
}

test "ModuleAnalysisSession keeps resolution and contract facts distinct" {
    const allocator = testing.allocator;
    const manifest_json =
        \\{
        \\  "schemaVersion": 1,
        \\  "specifier": "zttp-ext:owner-test",
        \\  "exports": [{ "name": "lookup", "effect": "read", "returns": "result" }]
        \\}
    ;
    var manifest = try @import("zts-engine").module_manifest.parse(allocator, manifest_json);
    var registry = manifest_registry_mod.Registry.init(allocator);
    defer registry.deinit();
    registry.register(manifest) catch |err| {
        manifest.deinit(allocator);
        return err;
    };

    const source =
        \\import { lookup } from "zttp-ext:owner-test";
        \\function handler(req) { return Response.text("ok"); }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    const root = try js_parser.parse();
    const view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, &atoms);

    var registry_analysis: ModuleAnalysisSession = .{};
    try registry_analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .manifest_registry = &registry,
    });
    defer registry_analysis.deinit();
    try registry_analysis.complete();
    var registry_contract = try registry_analysis.extractContract("registry.ts");
    defer registry_contract.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), registry_contract.modules.items.len);
    try testing.expectEqualStrings("zttp-ext:owner-test", registry_contract.modules.items[0]);

    var explicit_facts = try buildModuleFacts(allocator, parsed, null);
    defer explicit_facts.deinit();
    var explicit_analysis: ModuleAnalysisSession = .{};
    try explicit_analysis.initSoundExtraction(allocator, parsed, .{
        .strict = false,
        .manifest_registry = &registry,
        .module_facts = &explicit_facts,
    });
    try explicit_analysis.complete();
    var explicit_contract = try explicit_analysis.extractContract("explicit.ts");
    try testing.expectEqual(@as(usize, 0), explicit_contract.modules.items.len);
    explicit_contract.deinit(allocator);
    explicit_analysis.deinit();
    try testing.expectEqual(@as(usize, 1), explicit_facts.imports.items.len);
}

test "CheckedModule does not complete a verifier pass after allocation failure" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) {}\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_function_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checked = try CheckedModule.init(failing.allocator(), &resolved, .{});
    defer checked.deinit();
    try testing.expectError(error.OutOfMemory, checked.runVerifier(handler_func));
    try testing.expect(!checked.verifierCompleted());
}

test "CheckedModule rejects a TypePool poisoned after resolve" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) { return Response.text('ok'); }\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var storage: TypeEnvStorage = .{};
    try storage.initWithSource(allocator, .omitted);
    defer storage.deinit(allocator);

    var resolved = try resolve(allocator, parsed, .{ .type_env = storage.envPtr(), .strict = false });
    defer resolved.deinit();
    const handler_func = handler_function_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    const record = storage.pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = storage.pool.idx_string,
        .optional = false,
    }});
    try storage.pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = storage.pool.makeReadonly(failing.allocator(), record);

    var checked = try CheckedModule.init(allocator, &resolved, .{});
    defer checked.deinit();
    try testing.expectError(error.OutOfMemory, checked.runVerifier(handler_func));
}

test "CheckedModule runs verifier and flow independently or together" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text('ok'); }\n";
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_function_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var verifier_only = try CheckedModule.init(allocator, &resolved, .{});
    defer verifier_only.deinit();
    try testing.expectEqual(@as(u32, 0), try verifier_only.runVerifier(handler_func));
    try testing.expect(verifier_only.verifierCompleted());
    try testing.expect(!verifier_only.flowCompleted());

    var flow_only = try CheckedModule.init(allocator, &resolved, .{});
    defer flow_only.deinit();
    try testing.expectEqual(@as(u32, 0), try flow_only.runFlow(handler_func));
    try testing.expect(!flow_only.verifierCompleted());
    try testing.expect(flow_only.flowCompleted());

    var both = try CheckedModule.init(allocator, &resolved, .{});
    defer both.deinit();
    _ = try both.runVerifier(handler_func);
    _ = try both.runFlow(handler_func);
    try testing.expect(both.verifierCompleted());
    try testing.expect(both.flowCompleted());
}

test "CheckedModule rejects completed and failed pass retries" {
    const allocator = testing.allocator;
    const source =
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.text('ok'); }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();
    const handler_func = handler_function_mod.findHandlerFunction(view, parsed_state.root) orelse
        return error.HandlerNotFound;

    var completed = try CheckedModule.init(allocator, &resolved, .{});
    defer completed.deinit();
    _ = try completed.runVerifier(handler_func);
    _ = try completed.runFlow(handler_func);
    try testing.expectError(error.PassAlreadyRun, completed.runVerifier(handler_func));
    try testing.expectError(error.PassAlreadyRun, completed.runFlow(handler_func));

    var verifier_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_verifier = try CheckedModule.init(verifier_failing.allocator(), &resolved, .{});
    defer failed_verifier.deinit();
    try testing.expectError(error.OutOfMemory, failed_verifier.runVerifier(handler_func));
    try testing.expect(verifier_failing.has_induced_failure);
    try testing.expectError(error.PassAlreadyRun, failed_verifier.runVerifier(handler_func));
    try testing.expect(!failed_verifier.verifierCompleted());

    var flow_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_flow = try CheckedModule.init(flow_failing.allocator(), &resolved, .{});
    defer failed_flow.deinit();
    try testing.expectError(error.OutOfMemory, failed_flow.runFlow(handler_func));
    try testing.expect(flow_failing.has_induced_failure);
    try testing.expectError(error.PassAlreadyRun, failed_flow.runFlow(handler_func));
    try testing.expect(!failed_flow.flowCompleted());
}

test "missing handler leaves checked passes incomplete" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const value = true;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .strict = false });
    defer resolved.deinit();

    try testing.expect(handler_function_mod.findHandlerFunction(view, parsed_state.root) == null);
    var checked = try CheckedModule.init(allocator, &resolved, .{});
    defer checked.deinit();
    try testing.expect(!checked.verifierCompleted());
    try testing.expect(!checked.flowCompleted());
}

fn completedFlowProperties(checked: *const CheckedModule) !flow_checker_mod.FlowProperties {
    if (!checked.flowCompleted()) return error.FlowNotCompleted;
    return checked.flow_checker.getProperties();
}

test "flow projection requires completion and preserves leaking and safe results" {
    const allocator = testing.allocator;
    const leaking_source =
        \\import { env } from "zttp:env";
        \\function handler(req) { return Response.json({ value: env("SECRET") }); }
    ;
    var leaking_state = try parseSourceForTest(allocator, leaking_source);
    defer leaking_state.js_parser.deinit();
    const leaking_view = IrView.fromIRStore(&leaking_state.js_parser.nodes, &leaking_state.js_parser.constants);
    const leaking_parsed = ParsedModule.fromExisting(leaking_view, leaking_state.root, null);
    var leaking_resolved = try resolve(allocator, leaking_parsed, .{ .strict = false });
    defer leaking_resolved.deinit();
    const leaking_handler = handler_function_mod.findHandlerFunction(leaking_view, leaking_state.root) orelse
        return error.HandlerNotFound;
    var leaking = try CheckedModule.init(allocator, &leaking_resolved, .{});
    defer leaking.deinit();

    try testing.expectError(error.FlowNotCompleted, completedFlowProperties(&leaking));
    _ = try leaking.runFlow(leaking_handler);
    try testing.expect(!(try completedFlowProperties(&leaking)).no_secret_leakage);

    const safe_source = "function handler(req) { return Response.json({ value: 'safe' }); }\n";
    var safe_state = try parseSourceForTest(allocator, safe_source);
    defer safe_state.js_parser.deinit();
    const safe_view = IrView.fromIRStore(&safe_state.js_parser.nodes, &safe_state.js_parser.constants);
    const safe_parsed = ParsedModule.fromExisting(safe_view, safe_state.root, null);
    var safe_resolved = try resolve(allocator, safe_parsed, .{ .strict = false });
    defer safe_resolved.deinit();
    const safe_handler = handler_function_mod.findHandlerFunction(safe_view, safe_state.root) orelse
        return error.HandlerNotFound;
    var safe = try CheckedModule.init(allocator, &safe_resolved, .{});
    defer safe.deinit();
    _ = try safe.runFlow(safe_handler);
    try testing.expect((try completedFlowProperties(&safe)).no_secret_leakage);
}

test "pipeline.resolve runs BoolChecker on clean source" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const x = true;\nconst y = !x;\n");
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    try testing.expectEqual(@as(u32, 0), resolved.bool_error_count);
    try testing.expectEqual(@as(u32, 0), resolved.typeErrorCount());
    try testing.expectEqual(@as(usize, 0), resolved.typeDiagnostics().len);
}

test "pipeline.resolve flags pointless object truthy condition" {
    const allocator = testing.allocator;
    // Mirror bool_checker.zig:2258 — object literal in `if` is always truthy.
    const source: []const u8 = "if ({}) { let x = 1; }";

    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    const root = try js_parser.parse();
    const ir_view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

    const parsed = ParsedModule.fromExisting(ir_view, root, null);
    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    // One object-literal condition gives one diagnostic, as the bool checker's
    // own `if ({})` test pins.
    try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
    try testing.expectEqual(@as(usize, 1), resolved.boolDiagnostics().len);
    try testing.expectEqual(bool_checker_mod.DiagnosticKind.condition_not_boolean, resolved.boolDiagnostics()[0].kind);
}

test "pipeline.resolve rejects optional module value in boolean context" {
    const allocator = testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\const secret = env("TOKEN");
        \\if (!secret) { const missing = true; }
    ;
    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .omitted);

    var resolved = try resolve(allocator, parsed, .{
        .type_env = storage.envPtr(),
        .strict = false,
    });
    defer resolved.deinit();

    try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
    try testing.expectEqual(bool_checker_mod.DiagnosticKind.not_operand_not_boolean, resolved.boolDiagnostics()[0].kind);
}

test "pipeline.resolve runs strict checker without type context" {
    const allocator = testing.allocator;
    const source: []const u8 = "function handler(req) { let x = 1; return Response.json({ x: x }); }";

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();

    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var resolved = try resolve(allocator, parsed, .{ .type_env = null });
    defer resolved.deinit();

    try testing.expect(resolved.strict_checker != null);
    try testing.expect(resolved.strict_error_count > 0);
    var saw_avoidable_let = false;
    for (resolved.strictDiagnostics()) |diag| {
        if (diag.kind == .avoidable_let) saw_avoidable_let = true;
    }
    try testing.expect(saw_avoidable_let);
}

test "extractContract accepts authored TypeScript and honors strict opt out" {
    const source =
        \\function handler(req: Request): Response {
        \\  let message: string = "ok";
        \\  return Response.text(message);
        \\}
    ;

    var contract = try extractContract(testing.allocator, source, "handler.ts", .{
        .strict = false,
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqualStrings("handler.ts", contract.handler.path);
}

test "extractContract preserves single-file custom callback output" {
    const allocator = testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const value = env("TOKEN");
        \\  return Response.json({ value: value });
        \\}
    ;
    const Callback = struct {
        var call_count: usize = 0;

        fn check(type_checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
            const error_count = try type_checker.check(root);
            try testing.expectEqual(@as(u32, 0), error_count);
            try testing.expectEqual(@as(usize, 0), type_checker.getDiagnostics().len);
            call_count += 1;
            // Preserve acceptance of a nonzero callback count without diagnostics.
            return 7;
        }
    };

    var default_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
    });
    defer default_contract.deinit(allocator);

    Callback.call_count = 0;
    var custom_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
        .type_check = Callback.check,
    });
    defer custom_contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), Callback.call_count);
    try expectStringSlices(&.{"TOKEN"}, custom_contract.env.literal.items);
    try expectStringSlices(&.{"zttp:env"}, custom_contract.modules.items);

    const default_json = try serializeContractForTest(allocator, &default_contract);
    defer allocator.free(default_json);
    const custom_json = try serializeContractForTest(allocator, &custom_contract);
    defer allocator.free(custom_json);
    try testing.expectEqualStrings(default_json, custom_json);
}

test "extractContract rejects boolean diagnostics with strict disabled" {
    const source =
        \\if ({}) { const unreachable: boolean = true; }
        \\function handler(req: Request): Response { return Response.text("ok"); }
    ;

    try testing.expectError(
        error.SoundModeViolation,
        extractContract(testing.allocator, source, "handler.ts", .{
            .strict = false,
        }),
    );
}

test "extractContract keeps typed and virtual entry source rules distinct" {
    const allocator = testing.allocator;
    const typed_source =
        \\function handler(req: Request): Response {
        \\  const port: number = "bad";
        \\  return Response.text(String(port));
        \\}
    ;

    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, typed_source, "typed-entry.ts", .{ .strict = false }),
    );

    var untyped_contract = try extractContract(
        allocator,
        "function handler(req) { const port = \"bad\"; return Response.text(String(port)); }",
        "<untyped-entry>",
        .{ .strict = false },
    );
    defer untyped_contract.deinit(allocator);
    try testing.expectEqualStrings("<untyped-entry>", untyped_contract.handler.path);

    try testing.expectError(
        error.UnsupportedSourceExtension,
        extractContract(allocator, "function handler(req) { return Response.text(\"ok\"); }", "mapped-entry.js", .{ .strict = false }),
    );
}

test "extractContract keeps dependency annotations outside entry typing" {
    const source =
        \\import { request } from "./typed-bad.ts";
        \\function handler(req) { return Response.text("ok"); }
    ;

    var contract = try extractContract(testing.allocator, source, "/baseline/type-entry.ts", .{
        .strict = false,
        .read_file = readGraphBaselineFile,
    });
    defer contract.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), contract.egress.endpoints.items.len);
    try testing.expectEqualStrings(
        "https://typed-dependency.example:443",
        contract.egress.endpoints.items[0],
    );
}

test "extractContract preserves graph callback order and merged contract bytes" {
    const allocator = testing.allocator;
    const source =
        \\import { left } from "./left.ts";
        \\import { right } from "./right.ts";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req: Request): Response {
        \\  left();
        \\  right();
        \\  return fetchSync("https://entry.example/a");
        \\}
    ;
    const options = ExtractContractOptions{
        .strict = false,
        .type_check = recordGraphContractTypeCheck,
        .read_file = readGraphBaselineFile,
    };

    var success_probe = GraphCallbackProbe{};
    active_graph_callback_probe = &success_probe;
    defer active_graph_callback_probe = null;
    var custom_contract = try extractContract(allocator, source, "/baseline/entry.ts", options);
    active_graph_callback_probe = null;
    defer custom_contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), success_probe.count);
    try testing.expectEqualSlices(
        GraphCallbackModule,
        &.{ .shared, .left, .right, .entry },
        success_probe.modules[0..success_probe.count],
    );
    try expectStringSlices(
        &.{
            "https://shared.example:443",
            "https://left.example:443",
            "https://right.example:443",
            "https://entry.example:443",
        },
        custom_contract.egress.endpoints.items,
    );
    try expectStringSlices(&.{"LEFT_TOKEN"}, custom_contract.env.literal.items);
    try expectStringSlices(&.{"RIGHT_CACHE"}, custom_contract.cache.namespaces.items);

    var default_contract = try extractContract(allocator, source, "/baseline/entry.ts", .{
        .strict = false,
        .read_file = readGraphBaselineFile,
    });
    defer default_contract.deinit(allocator);
    const custom_json = try serializeContractForTest(allocator, &custom_contract);
    defer allocator.free(custom_json);
    const default_json = try serializeContractForTest(allocator, &default_contract);
    defer allocator.free(default_json);
    try testing.expectEqualStrings(default_json, custom_json);

    var refusal_probe = GraphCallbackProbe{ .fail_after = 2 };
    active_graph_callback_probe = &refusal_probe;
    try testing.expectError(
        error.GraphCallbackRefused,
        extractContract(allocator, source, "/baseline/entry.ts", options),
    );
    try testing.expectEqual(@as(usize, 2), refusal_probe.count);
    try testing.expectEqualSlices(
        GraphCallbackModule,
        &.{ .shared, .left },
        refusal_probe.modules[0..refusal_probe.count],
    );
}

test "loaded graph corrects entry effects before merge" {
    const allocator = testing.allocator;
    const entry_source =
        \\import { mutate } from "./dep.ts";
        \\function handler(req) { mutate(); return Response.text("ok"); }
    ;
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build("/effects/entry.ts", entry_source, readSiblingEffectFile);

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = string_mod.StringTable.init(allocator);
    defer strings.deinit();
    var compiler = modules_mod.ModuleCompiler.init(allocator, &atoms, &strings);
    var compiled = try compiler.compileAll(&graph);
    defer compiled.deinit();
    defer {
        for (compiled.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
    }

    const profiles = [_]ModuleAnalysisSession.Profile{ .contract_only, .sound_extraction };
    for (profiles) |profile| {
        var merged = try handler_contract_mod.initMergedContract(allocator, "/effects/entry.ts");
        defer merged.deinit(allocator);
        var loaded: std.ArrayList(LoadedModuleEffects) = .empty;
        defer {
            for (loaded.items) |*item| item.deinit(allocator);
            loaded.deinit(allocator);
        }

        for (compiled.modules, compiled.parsers, 0..) |module, *parser, index| {
            const graph_index = graph.execution_order[index];
            const graph_module = &graph.module_list.items[graph_index];
            const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
            const parsed = ParsedModule.fromExisting(view, module.root, &atoms);
            var analysis: ModuleAnalysisSession = .{};
            const extraction_opts = ExtractContractOptions{
                .strict = false,
                .capture_export_effects = true,
            };
            if (profile == .contract_only) {
                try analysis.initContractOnly(allocator, parsed, .{ .extraction = extraction_opts });
            } else {
                try analysis.initSoundExtraction(allocator, parsed, extraction_opts);
            }
            defer analysis.deinit();
            try analysis.complete();

            const imported = try importedEffectsForLoadedModule(
                allocator,
                &graph,
                graph_index,
                try analysis.facts(),
                loaded.items,
            );
            defer allocator.free(imported);
            try analysis.setImportedEffects(imported);

            var contract = try analysis.extractContract(graph_module.path);
            defer contract.deinit(allocator);
            const is_entry = index == compiled.modules.len - 1;
            if (is_entry) {
                const properties = contract.properties orelse return error.PropertiesMissing;
                try testing.expect(!properties.read_only);
                try testing.expect(!properties.stateless);
            }
            try handler_contract_mod.mergeModuleContract(allocator, &merged, &contract, is_entry);

            var effects = analysis.takeExportEffects() orelse return error.ExportEffectsMissing;
            loaded.append(allocator, .{
                .graph_index = graph_index,
                .effects = effects,
            }) catch |err| {
                effects.deinit(allocator);
                return err;
            };
        }
        try testing.expect(merged.properties == null);
    }
}

test "extractContract merges capabilities from relative imports" {
    const allocator = testing.allocator;
    const file_io = @import("zts-engine").file_io;

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const dependency_path = try allocator.print("{s}/dependency.ts", .{dir});
    defer allocator.free(dependency_path);
    try file_io.writeFile(
        allocator,
        dependency_path,
        "export function request() { return fetchSync('http://localhost:1'); }",
    );

    const entry_path = try allocator.print("{s}/entry.ts", .{dir});
    defer allocator.free(entry_path);
    const source =
        "import { request } from './dependency.ts'; function handler(req) { return request(req, undefined); }";

    var contract = try extractContract(allocator, source, entry_path, .{
        .strict = false,
        .read_file = file_io.readFileForModuleGraph,
    });
    defer contract.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), contract.egress.endpoints.items.len);
    try testing.expectEqualStrings("http://localhost:1", contract.egress.endpoints.items[0]);

    try file_io.writeFile(
        allocator,
        dependency_path,
        "if ({}) { const unreachable = true; } export function request() { return fetchSync('http://localhost:1'); }",
    );
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = false,
            .read_file = file_io.readFileForModuleGraph,
        }),
    );

    try file_io.writeFile(
        allocator,
        dependency_path,
        "export function request() { let response = fetchSync('http://localhost:1'); return response; }",
    );
    var non_strict_contract = try extractContract(allocator, source, entry_path, .{
        .strict = false,
        .read_file = file_io.readFileForModuleGraph,
    });
    non_strict_contract.deinit(allocator);
    try testing.expectError(
        error.SoundModeViolation,
        extractContract(allocator, source, entry_path, .{
            .strict = true,
            .read_file = file_io.readFileForModuleGraph,
        }),
    );
}

test "the three index consumers reuse an injected index" {
    // The half of C2's gate that cannot pass vacuously. C1 made injection
    // behavior-neutral by construction - an analyzer with no index builds an
    // identical private one - so identical output proves nothing about whether
    // the work is shared. `owned_facts == null` proves it directly.
    // The flow interpreter resolves bindings directly from its retained IR.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) { return Response.json({ok: true}); }
    ;

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var facts = try buildModuleFacts(allocator, parsed, null);
    defer facts.deinit();
    // The index must be non-trivial, or the assertions below would hold for an
    // empty one and say nothing.
    try std.testing.expect(facts.imports.items.len >= 2);

    var resolved = try resolve(allocator, parsed, .{ .module_facts = &facts });
    defer resolved.deinit();

    try std.testing.expectEqual(&facts, resolved.bool_checker.facts.?);
    try std.testing.expect(resolved.bool_checker.owned_facts == null);
    try std.testing.expect(resolved.strict_checker != null);
    try std.testing.expectEqual(&facts, resolved.strict_checker.?.facts.?);
    try std.testing.expect(resolved.strict_checker.?.owned_facts == null);

    const handler_func = handler_function_mod.findHandlerFunction(view, parsed_state.root).?;
    var checked = try CheckedModule.init(allocator, &resolved, .{ .module_facts = &facts });
    defer checked.deinit();
    _ = try checked.runVerifier(handler_func);
    _ = try checked.runFlow(handler_func);

    try std.testing.expectEqual(&facts, checked.verifier.facts.?);
    try std.testing.expect(checked.verifier.owned_facts == null);
}

test "with no injected index each analyzer still builds its own" {
    // The fallback C1 relies on and C3 still needs, since precompile has sites
    // C3 has not reached. Asserted so a future change cannot quietly make
    // injection mandatory.
    const allocator = std.testing.allocator;
    const source = "import { env } from \"zttp:env\";\n";

    var parsed_state = try parseSourceForTest(allocator, source);
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var resolved = try resolve(allocator, parsed, .{});
    defer resolved.deinit();

    try std.testing.expect(resolved.bool_checker.facts == null);
    try std.testing.expect(resolved.bool_checker.owned_facts != null);
}

/// Parse, resolve, check, and extract a contract, releasing everything it
/// allocated. Used by the failure sweep below: the acceptance criterion for
/// reset item 0a is that every compile path, including every failure stage,
/// leaks nothing, and a sweep can only assert that against one function that
/// owns the whole sequence.
fn runCompilePhasesForTest(allocator: std.mem.Allocator, source: []const u8) !void {
    var js_parser = try JsParser.init(allocator, source);
    defer js_parser.deinit();
    const root = try js_parser.parse();

    const view = IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, root, null);

    const handler_func = handler_function_mod.findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, parsed, .{
        .strict = false,
        .select_verifier = true,
        .select_flow = true,
    });
    defer session.deinit();
    try session.complete();
    try session.prepareChecked(handler_func, .{ .module_facts = try session.facts() });
    _ = try session.runVerifier(handler_func);
    _ = try session.runFlow(handler_func);

    var contract = try session.extractContract("sweep.ts");
    contract.deinit(allocator);
}

test "every compile stage releases what it allocated at any failure index" {
    const allocator = testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req) {
        \\  const make = () => sha256("x");
        \\  if (req.url === "/a") return Response.json({ hash: make() });
        \\  return Response.text("ok");
        \\}
        \\
    ;
    // The successful run first, both as a control and to learn how many
    // allocations the sweep has to cover.
    var counting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    try runCompilePhasesForTest(counting.allocator(), source);
    const total = counting.alloc_index;
    try testing.expect(total > 0);

    // Each iteration fails one allocation. A leak on any unwind path is
    // reported by std.testing.allocator when the test ends, which is the
    // assertion; the error value itself is not interesting.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = i });
        runCompilePhasesForTest(failing.allocator(), source) catch {};
    }
}

// ---------------------------------------------------------------------------
// The refused-expression type (`t_error`) and its containment
// ---------------------------------------------------------------------------

/// What a probe sees: the phases the real pipeline ran over one TypeScript
/// source. The error type is private to the type checker, so every probe goes
/// through the real phases and reads what the other checkers decided.
const Session = struct {
    allocator: std.mem.Allocator,
    resolved: *ResolvedModule,
    parsed: ParsedModule,
    handler: ?NodeIndex,
};

fn withSession(
    allocator: std.mem.Allocator,
    source: []const u8,
    comptime run: fn (Session) anyerror!void,
) !void {
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initInPlace(allocator, allocator, source, "probe.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    const view = IrView.fromIRStore(&frontend.parser.nodes, &frontend.parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, accepted.root, accepted.atoms, accepted.type_store);

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .{ .direct = .{
        .store = accepted.type_store,
        .ir_view = view,
        .atoms = accepted.atoms,
    } });

    var resolved = try resolve(allocator, parsed, .{ .type_env = storage.envPtr(), .strict = true });
    defer resolved.deinit();
    try run(.{
        .allocator = allocator,
        .resolved = &resolved,
        .parsed = parsed,
        .handler = handler_function_mod.findHandlerFunction(view, accepted.root),
    });
}

fn countKind(diagnostics: anytype, kind: anytype) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == kind) count += 1;
    }
    return count;
}

test "one refused operator gives one type diagnostic" {
    const source =
        \\function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  const m: number = n + "y";
        \\  return Response.text(String(m));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, diagnostics[0].kind);
            try testing.expectEqual(@as(usize, 1), session.resolved.type_checker.?.refusedExpressionCount());
        }
    }.run);
}

test "a refused value used again gives no second diagnostic" {
    // The refused sum flows into a binding, a call argument, and a ternary.
    // Each used to raise a mismatch of its own on top of ZTS105.
    const source =
        \\function twice(x: number): number {
        \\  return x + x;
        \\}
        \\function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  const m = n + "y";
        \\  const k: number = m;
        \\  const t: number = twice(m);
        \\  const u: number = n === 1 ? m : 2;
        \\  return Response.text(String(k + t + u));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, diagnostics[0].kind);
        }
    }.run);
}

test "the error type exists only where a type error was reported" {
    // A refused expression implies a reported error. That is the direction a
    // regression breaks: an error type with no diagnostic would be accepted
    // everywhere, silently. The converse holds too: a source with no refused
    // operator never produces the type.
    const refusing = [_][]const u8{
        "function f(n: number): number {\n  const m: number = n + \"y\";\n  return m;\n}",
        "function f(n: number): string {\n  const s = n + \"y\" + \"z\";\n  return s;\n}",
        "function f(n: number): string {\n  const s = n + \"y\";\n  return s.toUpperCase();\n}",
        "function f(n: number): number {\n  return n === 1 ? n + \"y\" : 2;\n}",
        "const n: number = 1;\nif (n + \"y\") { const k = 1; }",
    };
    const clean = [_][]const u8{
        "function f(n: number): number {\n  const m: number = n + 2;\n  return m;\n}",
        "function f(parts: string[]): string {\n  return parts.join(\"\");\n}",
        "const a: string = \"x\";\nconst b = a === \"x\" ? 1 : 2;",
    };
    inline for (refusing) |source| {
        try withSession(testing.allocator, source, struct {
            fn run(session: Session) anyerror!void {
                try testing.expect(session.resolved.type_checker.?.refusedExpressionCount() > 0);
                try testing.expect(session.resolved.typeErrorCount() > 0);
                // Every source adds a string to the number `n`, so the first
                // reported error is the string-add refusal.
                try testing.expectEqual(type_checker_mod.DiagnosticKind.string_add, session.resolved.typeDiagnostics()[0].kind);
            }
        }.run);
    }
    inline for (clean) |source| {
        try withSession(testing.allocator, source, struct {
            fn run(session: Session) anyerror!void {
                try testing.expectEqual(@as(usize, 0), session.resolved.type_checker.?.refusedExpressionCount());
                try testing.expectEqual(@as(u32, 0), session.resolved.typeErrorCount());
            }
        }.run);
    }
}

test "the public inference getter hides the error type and any type built from it" {
    const source =
        \\const n: number = 1;
        \\const joined = n + "y";
        \\const list = [n + "y", "z"];
        \\const pick = n === 1 ? n + "y" : "z";
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var seen: usize = 0;
            var node: NodeIndex = 0;
            while (node < view.nodeCount()) : (node += 1) {
                const tag = view.getTag(node) orelse continue;
                // Every expression kind the sources above build from a refused sum.
                switch (tag) {
                    .binary_op, .array_literal, .ternary => {},
                    else => continue,
                }
                const inferred = checker.inferTypeWithoutDiagnostics(node);
                // Whatever another checker is handed must not mention the error
                // type, however deep: it is unknown to them or a real type.
                try testing.expect(!checker.env.pool.mentionsError(inferred));
                if (tag == .binary_op) {
                    const bin = view.getBinary(node) orelse continue;
                    if (bin.op == .add) {
                        try testing.expectEqual(type_pool_mod.null_type_idx, inferred);
                        seen += 1;
                    }
                }
            }
            try testing.expect(seen >= 3);
        }
    }.run);
}

test "a refused condition is still refused by the boolean checker" {
    // If the error type leaked, `isAssignableTo(error, boolean)` would answer
    // yes and the condition would pass as boolean.
    try withSession(testing.allocator, "const n: number = 1;\nif (n + \"y\") { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            try testing.expectEqual(
                @as(usize, 1),
                countKind(session.resolved.boolDiagnostics(), bool_checker_mod.DiagnosticKind.condition_not_boolean),
            );
        }
    }.run);
    try withSession(testing.allocator, "const n: number = 1;\nconst q: boolean = !(n + \"y\");", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(
                @as(usize, 1),
                countKind(session.resolved.boolDiagnostics(), bool_checker_mod.DiagnosticKind.not_operand_not_boolean),
            );
        }
    }.run);
}

test "a refused operand is unknown to the strict checker, not a type it can reason from" {
    // If the error type leaked, `isAssignableTo(null, error)` would answer yes
    // and the strict checker would claim the operand admits null (ZTS624), a
    // statement about a type it was never given.
    try withSession(testing.allocator, "const n: number = 1;\nconst q = (n + \"y\") ?? 0;", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            try testing.expectEqual(
                @as(usize, 0),
                countKind(session.resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.nullish_operator_on_null),
            );
        }
    }.run);
}

const refused_flow_source =
    \\import { env } from "zttp:env";
    \\function handler(req: Request): Response {
    \\  const token = env("API_TOKEN");
    \\  const joined = token + "!";
    \\  const shout = joined.toUpperCase();
    \\  return Response.text(shout);
    \\}
;

test "an error-typed receiver does not make the flow checker or the verifier clean" {
    // `joined` holds a refused sum, so its binding type is the error type and
    // `joined.toUpperCase()` has an error-typed receiver. The flow checker asks
    // the type checker what the receiver is; it must get "unknown", and the
    // secret must still reach the response as a finding. The verifier does not
    // read inferred types, and its verdict is unchanged.
    try withSession(testing.allocator, refused_flow_source, struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 1), session.resolved.typeDiagnostics().len);
            var checked = try CheckedModule.init(session.allocator, session.resolved, .{});
            defer checked.deinit();
            _ = try checked.runVerifier(session.handler.?);
            _ = try checked.runFlow(session.handler.?);
            try testing.expectEqual(
                @as(usize, 1),
                countKind(checked.flowDiagnostics(), flow_checker_mod.DiagnosticKind.secret_in_response),
            );
            try testing.expectEqual(
                @as(usize, 1),
                countKind(checked.verifierDiagnostics(), handler_verifier_mod.DiagnosticKind.unchecked_optional_use),
            );
        }
    }.run);
}

test "a refused payload is a dynamic response schema in the contract, not an inferred one" {
    // The contract builder asks the type checker for the payload's type to
    // derive a response schema. A refused payload must come back unknown, which
    // the builder records as a dynamic response, never as a concrete schema.
    const head = "import { routerMatch } from \"zttp:router\";\n" ++
        "function getX(req: Request): Response {\n  const n: number = 1;\n";
    const tail = "\n  return Response.json(joined);\n}\n" ++
        "const routes = { \"GET /x\": getX };\n" ++
        "function handler(req: Request): Response {\n" ++
        "  const found = routerMatch(routes, req);\n" ++
        "  if (found !== undefined) {\n    return found.handler(req);\n  }\n" ++
        "  return Response.json({ error: \"Not Found\" }, { status: 404 });\n}";
    try withSession(testing.allocator, head ++ "  const joined = n + \"y\";" ++ tail, struct {
        fn run(session: Session) anyerror!void {
            var contract = try extractContractOnlyForTest(session, true);
            defer contract.deinit(session.allocator);
            try testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
            const route = contract.api.routes.items[0];
            try testing.expectEqual(@as(usize, 1), route.responses.items.len);
            try testing.expect(route.responses.items[0].schema == .dynamic);
        }
    }.run);
    // The same route with an unrefused payload does infer a schema, so the
    // dynamic answer above comes from the refusal and not from the route shape.
    try withSession(testing.allocator, head ++ "  const joined = n + 2;" ++ tail, struct {
        fn run(session: Session) anyerror!void {
            var contract = try extractContractOnlyForTest(session, false);
            defer contract.deinit(session.allocator);
            const route = contract.api.routes.items[0];
            try testing.expect(route.responses.items[0].schema == .inline_json);
        }
    }.run);
}

test "a request header read inside a spread operand is a header parameter of the route" {
    // The API scan once dropped spread operands, so this header never reached
    // the contract's API section.
    const source = "import { routerMatch } from \"zttp:router\";\n" ++
        "function getA(req: Request): Response {\n" ++
        "  return Response.json({ ...{ auth: req.headers[\"authorization\"] } });\n}\n" ++
        "const routes = { \"GET /a\": getA };\n" ++
        "function handler(req: Request): Response {\n" ++
        "  const found = routerMatch(routes, req);\n" ++
        "  if (found === undefined) return Response.text(\"nf\");\n" ++
        "  return found.handler(req);\n}";
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            var contract = try extractContractOnlyForTest(session, false);
            defer contract.deinit(session.allocator);
            try testing.expectEqual(@as(usize, 1), contract.api.routes.items.len);
            const route = contract.api.routes.items[0];
            try testing.expectEqual(@as(usize, 1), route.header_params.items.len);
            try testing.expectEqualStrings("authorization", route.header_params.items[0].name);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// One message per node when `check` reports every computed stage
// ---------------------------------------------------------------------------

test "dropRepeatsOfTypeErrors removes a boolean diagnostic on the node a type error names" {
    try withSession(testing.allocator, "const n: number = 1;\nif (n + \"y\") { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            // Both stages report the same expression before the drop.
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(usize, 0), resolved.boolDiagnostics().len);
            try testing.expectEqual(@as(u32, 0), resolved.bool_error_count);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors keeps a boolean diagnostic on a different node" {
    const source =
        \\const n: number = 1;
        \\const m: number = n + "y";
        \\if (5) { const k = 1; }
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(usize, 1), resolved.typeDiagnostics().len);
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors removes a strict diagnostic below a type error and keeps one beside it" {
    // The first call has too many arguments (a type error on the call node), and
    // its second argument is a partly annotated arrow (ZTS601 below that node).
    // The second statement holds the same arrow outside any type error.
    const source =
        \\function one(a: number): number {
        \\  return a;
        \\}
        \\function handler(req: Request): Response {
        \\  const x: number = one(1, (a: number, b) => a);
        \\  const y = (a: number, b) => a;
        \\  return Response.text(String(x));
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            try testing.expect(resolved.typeErrorCount() > 0);
            const before = countKind(resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.missing_public_annotation);
            resolved.dropRepeatsOfTypeErrors();
            const after = countKind(resolved.strictDiagnostics(), strict_checker_mod.DiagnosticKind.missing_public_annotation);
            // One diagnostic below the call node and one in the second statement.
            try testing.expectEqual(@as(usize, 2), before);
            try testing.expectEqual(@as(usize, 1), after);
        }
    }.run);
}

test "dropRepeatsOfTypeErrors does nothing without a type error" {
    try withSession(testing.allocator, "const n: number = 1;\nif (5) { const k = 1; }", struct {
        fn run(session: Session) anyerror!void {
            const resolved = session.resolved;
            resolved.dropRepeatsOfTypeErrors();
            try testing.expectEqual(@as(u32, 1), resolved.bool_error_count);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// Boolean-context operands typed under the guards of `&&` and `||`
// ---------------------------------------------------------------------------

/// The boolean checker's error count over one source that passes the type
/// checker, read through the real phases.
fn expectBoolErrors(source: []const u8, comptime expected: u32) !void {
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(expected, session.resolved.bool_error_count);
        }
    }.run);
}

const guard_union_decl = "structural Ev = { kind: \"a\", flag: boolean } | { kind: \"b\", n: number };\n";

test "the right operand of && is typed under the left operand's guard" {
    // An optional boolean read after an undefined test.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v !== undefined && v;",
        0,
    );
    // A discriminant test selects the member that has the field.
    try expectBoolErrors(
        guard_union_decl ++ "const f = (e: Ev): boolean => e.kind === \"a\" && e.flag;",
        0,
    );
    // A chain of tests: each guard reaches every operand to its right.
    try expectBoolErrors(
        "const f = (a: boolean | undefined, b: boolean | undefined): boolean =>" ++
            " a !== undefined && b !== undefined && a && b;",
        0,
    );
    // A condition that is itself a conjunction, in `if` and in a ternary.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => { if (v !== undefined && v) { return 1; } return 0; };",
        0,
    );
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => v !== undefined && v ? 1 : 0;",
        0,
    );
}

test "the right operand of || is typed under the negated left guard" {
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined || !v;",
        0,
    );
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined || v;",
        0,
    );
    // The disjunction of two tests is false only when both failed.
    try expectBoolErrors(
        "const f = (a: boolean | undefined, b: boolean | undefined): boolean =>" ++
            " a === undefined || b === undefined || a || b;",
        0,
    );
}

test "a guard does not reach an operand the left side does not decide" {
    // `||` runs its right side when the left one was false, so a test that
    // narrows the true branch narrows nothing there.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v !== undefined || v;",
        1,
    );
    // `&&` runs its right side when the left one was true.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v === undefined && v;",
        1,
    );
    // The false side of a conjunction decides neither of its operands.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => (v !== undefined && v) || v;",
        1,
    );
    // An operand with no guard keeps its declared type.
    try expectBoolErrors(
        "const f = (v: boolean | undefined): boolean => v && true;",
        1,
    );
}

test "a guard of && ends with the expression it guards" {
    try expectBoolErrors(
        "const f = (v: boolean | undefined): number => {\n" ++
            "  const both = v !== undefined && v;\n" ++
            "  return v ? 1 : 0;\n" ++
            "};",
        1,
    );
}

test "the walk records a boolean-context operand's type inside a function declaration" {
    // The boolean checker does not walk a `function` declaration body, so a
    // corpus case cannot see these types yet. The type checker does walk it,
    // and the recorded types are what the boolean checker will read.
    const source =
        \\function f(v: boolean | undefined): boolean {
        \\  return v !== undefined && v;
        \\}
        \\function g(v: boolean | undefined): boolean {
        \\  return v === undefined || !v;
        \\}
    ;
    try withSession(testing.allocator, source, struct {
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var operands: usize = 0;
            var idx: NodeIndex = 0;
            while (idx < view.nodeCount()) : (idx += 1) {
                if (view.getTag(idx) != .binary_op) continue;
                const bin = view.getBinary(idx) orelse continue;
                if (bin.op != .and_op and bin.op != .or_op) continue;
                for ([_]NodeIndex{ bin.left, bin.right }) |operand| {
                    const recorded = checker.contextTypeOf(operand) orelse return error.OperandNotRecorded;
                    try testing.expect(checker.env.isAssignableTo(recorded, checker.env.pool.idx_boolean));
                    operands += 1;
                }
            }
            try testing.expectEqual(@as(usize, 4), operands);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// Boolean-context false positives: intrinsic guards, nested members, typeof
// over unknown, and for-of element variables
// ---------------------------------------------------------------------------

/// Fail unless the type checker recorded a boolean type for each of the
/// `expected` boolean-context operands of `source`: the conditions of `if` and
/// ternary, and the operands of `!`, `&&` and `||`. The boolean checker walks
/// only arrows and module code today, so a `function` declaration is read here
/// through the types the type checker recorded, which are the ones the boolean
/// checker will read once it walks those bodies.
fn expectEveryContextBoolean(source: []const u8, comptime expected: usize) !void {
    const Probe = struct {
        fn operand(checker: *type_checker_mod.TypeChecker, node: NodeIndex) !void {
            const recorded = checker.contextTypeOf(node) orelse return error.OperandNotRecorded;
            try testing.expect(checker.env.isAssignableTo(recorded, checker.env.pool.idx_boolean));
        }
        fn run(session: Session) anyerror!void {
            const checker = &session.resolved.type_checker.?;
            const view = session.parsed.ir_view;
            var seen: usize = 0;
            var idx: NodeIndex = 0;
            while (idx < view.nodeCount()) : (idx += 1) {
                switch (view.getTag(idx) orelse continue) {
                    .if_stmt => {
                        try operand(checker, (view.getIfStmt(idx) orelse continue).condition);
                        seen += 1;
                    },
                    .ternary => {
                        try operand(checker, (view.getTernary(idx) orelse continue).condition);
                        seen += 1;
                    },
                    .unary_op => {
                        const un = view.getUnary(idx) orelse continue;
                        if (un.op != .not) continue;
                        try operand(checker, un.operand);
                        seen += 1;
                    },
                    .binary_op => {
                        const bin = view.getBinary(idx) orelse continue;
                        if (bin.op != .and_op and bin.op != .or_op) continue;
                        try operand(checker, bin.left);
                        try operand(checker, bin.right);
                        seen += 2;
                    },
                    // exhaustive: test probe: node kinds without a condition operand are not counted, and the test compares the count to an expected value.
                    else => {},
                }
            }
            try testing.expectEqual(expected, seen);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "isDict and isBytes are booleans in every boolean context" {
    try expectBoolErrors(
        "const f = (d: unknown): number => { if (isDict(d)) { return 1; } return 0; };",
        0,
    );
    try expectBoolErrors(
        "const f = (d: unknown): boolean => !isDict(d) || (isBytes(d) && true);",
        0,
    );
    try expectBoolErrors(
        "const f = (d: unknown): number => isBytes(d) ? 1 : 0;",
        0,
    );
    // Control: an unknown value itself is still not a boolean.
    try expectBoolErrors(
        "const f = (d: unknown): number => { if (d) { return 1; } return 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function classify(doc: unknown): number {
        \\  if (isDict(doc)) { return 1; }
        \\  return !isBytes(doc) ? 2 : 3;
        \\}
    , 3);
}

test "a member read through a record parameter's named field is typed" {
    const todo = "structural Todo = { text: string, done: boolean };\n";
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): number => p.todo.done ? 1 : 0;",
        0,
    );
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): boolean => !p.todo.done && p.todo.done;",
        0,
    );
    // Control: the field read resolves to its declared type, which is a string.
    try expectBoolErrors(
        todo ++ "const f = (p: { todo: Todo }): number => p.todo.text ? 1 : 0;",
        1,
    );
    try expectEveryContextBoolean(todo ++
        \\function progress(props: { todo: Todo }): number {
        \\  return props.todo.done ? 1 : 0;
        \\}
    , 1);
}

test "typeof over an unknown value refines it to the named primitive" {
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"boolean\") { if (v) { return 1; } } return 0; };",
        0,
    );
    // The negated form refines the other branch.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v !== \"boolean\") { return 0; } return v ? 1 : 0; };",
        0,
    );
    // Control: a refinement to a string is not a boolean.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"string\") { if (v) { return 1; } } return 0; };",
        1,
    );
    // Control: the refinement ends with the branch.
    try expectBoolErrors(
        "const f = (v: unknown): number => { if (typeof v === \"boolean\") { return 1; } return v ? 1 : 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function flagOf(v: unknown): number {
        \\  if (typeof v === "boolean") {
        \\    if (v) { return 1; }
        \\  }
        \\  return 0;
        \\}
    , 2);
}

test "the element variable of for-of over an array takes the element type" {
    try expectBoolErrors(
        "const f = (flags: boolean[]): number => { for (const flag of flags) { if (flag) { return 1; } } return 0; };",
        0,
    );
    // Control: a string element is not a boolean.
    try expectBoolErrors(
        "const f = (names: string[]): number => { for (const name of names) { if (name) { return 1; } } return 0; };",
        1,
    );
    try expectEveryContextBoolean(
        \\function firstSet(flags: boolean[]): number {
        \\  for (const flag of flags) {
        \\    if (flag) { return 1; }
        \\  }
        \\  return 0;
        \\}
    , 1);
}

// ---------------------------------------------------------------------------
// Declared parameter types in the boolean checker's diagnostics
// ---------------------------------------------------------------------------

/// Whether the boolean checker reported a diagnostic of `kind` over one source.
fn expectBoolKind(source: []const u8, comptime kind: bool_checker_mod.DiagnosticKind, comptime expected: bool) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            var seen = false;
            for (session.resolved.boolDiagnostics()) |diagnostic| {
                if (diagnostic.kind == kind) seen = true;
            }
            try testing.expectEqual(expected, seen);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "arithmetic on a parameter declared string is refused" {
    try expectBoolKind(
        "const f = (s: string): number => s - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
    try expectBoolKind(
        "const f = (b: boolean): number => b * 2;",
        .arithmetic_on_non_numeric,
        true,
    );
    try expectBoolKind(
        "const f = (xs: number[]): number => 2 / xs;",
        .arithmetic_on_non_numeric,
        true,
    );
    // An optional string is not a number either.
    try expectBoolKind(
        "const f = (s: string | undefined): number => s - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
    // A union of string literals is a string.
    try expectBoolKind(
        "const f = (m: \"GET\" | \"POST\"): number => m - 1;",
        .arithmetic_on_non_numeric,
        true,
    );
}

test "arithmetic on a parameter declared number is accepted" {
    try expectBoolKind(
        "const f = (n: number, m: number): number => n - m * 2;",
        .arithmetic_on_non_numeric,
        false,
    );
    // The lattice has no optional number, so this stays undecided.
    try expectBoolKind(
        "const f = (n: number | undefined): number => n - 1;",
        .arithmetic_on_non_numeric,
        false,
    );
    // Unknown and generic parameters stay undecided.
    try expectBoolKind(
        "const f = (v: unknown): number => v - 1;",
        .arithmetic_on_non_numeric,
        false,
    );
}

test "plus on a parameter declared boolean or object is refused" {
    try expectBoolKind(
        "const f = (b: boolean): number => b + 1;",
        .add_on_non_addable,
        true,
    );
    try expectBoolKind(
        "const f = (xs: number[]): number => 1 + xs;",
        .add_on_non_addable,
        true,
    );
    try expectBoolKind(
        "const f = (a: number, b: number): number => a + b;",
        .add_on_non_addable,
        false,
    );
}

test "a fallback on a parameter that cannot be undefined is reported" {
    try expectBoolKind(
        "const f = (s: string): string => s ?? \"x\";",
        .nullish_on_non_nullable,
        true,
    );
    try expectBoolKind(
        "const f = (s: string | undefined): string => s ?? \"x\";",
        .nullish_on_non_nullable,
        false,
    );
    try expectBoolKind(
        "const f = (n: number | undefined): number => n ?? 1;",
        .nullish_on_non_nullable,
        false,
    );
}

test "a comparison with undefined or typeof on a parameter with a known type is reported" {
    try expectBoolKind(
        "const f = (s: string): boolean => s === undefined;",
        .tautological_comparison,
        true,
    );
    try expectBoolKind(
        "const f = (s: string): boolean => typeof s === \"string\";",
        .tautological_comparison,
        true,
    );
    try expectBoolKind(
        "const f = (s: string | undefined): boolean => s === undefined;",
        .tautological_comparison,
        false,
    );
    try expectBoolKind(
        "const f = (v: unknown): boolean => typeof v === \"string\";",
        .tautological_comparison,
        false,
    );
}

test "a typed parameter does not change the bytecode annotations" {
    // The declared type feeds the diagnostics only. Specializing an operator
    // on a declared parameter type would move precompiled bytecode.
    try withSession(testing.allocator, "const f = (a: number, b: number): number => a + b;", struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(u32, 0), session.resolved.bool_checker.node_types.count());
        }
    }.run);
}

fn extractSoundSessionForTest(
    allocator: std.mem.Allocator,
    parsed: ParsedModule,
    options: ExtractContractOptions,
) !HandlerContract {
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, options);
    defer analysis.deinit();
    try analysis.complete();
    return analysis.extractContract("existing-checker.ts");
}

fn extractContractOnlyForTest(session: Session, expect_refusal: bool) !HandlerContract {
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(session.allocator, session.parsed, .{ .extraction = .{ .strict = false } });
    defer analysis.deinit();
    try analysis.complete();
    try testing.expectEqual(expect_refusal, analysis.contract_checker.?.refusedExpressionCount() > 0);
    return analysis.extractContract("probe.ts");
}

fn expectExistingCheckerFacts(contract: *const HandlerContract, authored: bool) !void {
    try testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    try testing.expectEqualStrings(
        if (authored) "string" else "unknown",
        contract.holes.items[0].expected_type,
    );
    var saw_proof = false;
    for (contract.function_capsules.items) |capsule| {
        if (!std.mem.eql(u8, capsule.function, "proved")) continue;
        try testing.expectEqual(if (authored) @as(usize, 1) else 0, capsule.declared.items.len);
        if (authored) try testing.expectEqualStrings("deterministic", capsule.declared.items[0]);
        saw_proof = true;
    }
    try testing.expect(saw_proof);
    var saw_effect = false;
    for (contract.function_effect_capsules.items) |capsule| {
        if (!std.mem.eql(u8, capsule.function, "effectful")) continue;
        try testing.expectEqual(if (authored) @as(usize, 1) else 0, capsule.declared.items.len);
        if (authored) {
            try testing.expectEqualStrings("crypto", capsule.declared.items[0]);
            try testing.expectEqual(@as(usize, 1), capsule.inferred.items.len);
            try testing.expectEqualStrings("crypto", capsule.inferred.items[0]);
        }
        saw_effect = true;
    }
    try testing.expect(saw_effect);
}

test "sound extraction sessions preserve source selection and direct ownership" {
    const allocator = testing.allocator;
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\function proved(value: string): Proof<string, "deterministic"> { return value; }
        \\function effectful(value: string): Effects<string, "crypto"> { return sha256(value); }
        \\function incomplete(): string { return hole(); }
        \\function handler(req: Request): Response {
        \\  return Response.text(effectful(proved(incomplete())));
        \\}
        \\
    ;
    var direct_atoms = AtomTable.init(allocator);
    defer direct_atoms.deinit();
    var direct_parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer direct_parser.deinit();
    direct_parser.setAtomTable(&direct_atoms);
    const direct_root = try direct_parser.parse();
    const direct_view = IrView.fromIRStore(&direct_parser.nodes, &direct_parser.constants);
    const direct_parsed = ParsedModule.fromTypedExisting(
        direct_view,
        direct_root,
        &direct_atoms,
        &direct_parser.type_store,
    );
    const direct_unbound = ParsedModule.fromExisting(direct_view, direct_root, &direct_atoms);
    var omitted = try extractSoundSessionForTest(allocator, direct_parsed, .{ .source_types = .omitted, .strict = false });
    defer omitted.deinit(allocator);
    try expectExistingCheckerFacts(&omitted, false);

    var direct = try extractSoundSessionForTest(allocator, direct_parsed, .{ .source_types = .direct, .strict = false });
    defer direct.deinit(allocator);
    try expectExistingCheckerFacts(&direct, true);

    try testing.expectError(
        error.DirectTypeSyntaxUnavailable,
        extractSoundSessionForTest(allocator, direct_unbound, .{ .source_types = .direct, .strict = false }),
    );
}

threadlocal var source_selection_graph_reads: usize = 0;

const sourceSelectionGraphEntry =
    \\import { helper } from "./dep.ts";
    \\function handler(req: Request): Proof<Response, "pure"> { return Response.text(helper()); }
;

fn readSourceSelectionGraphFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) modules_mod.module_graph.ReadFileError![]const u8 {
    source_selection_graph_reads += 1;
    if (!std.mem.endsWith(u8, path, "dep.ts")) return error.FileNotFound;
    return allocator.dupe(u8,
        \\export function helper(): Proof<string, "deterministic"> { return "ok"; }
    );
}

test "contract-only graph sessions omit every supplied source selection" {
    const allocator = testing.allocator;
    const entry_path = "/source-selection/entry.ts";
    var graph = modules_mod.ModuleGraph.init(allocator);
    defer graph.deinit();
    try graph.build(entry_path, sourceSelectionGraphEntry, readSourceSelectionGraphFile);
    try testing.expectEqual(@as(usize, 2), graph.module_list.items.len);
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var strings = string_mod.StringTable.init(allocator);
    defer strings.deinit();
    var compiler = modules_mod.ModuleCompiler.init(allocator, &atoms, &strings);
    var compiled = try compiler.compileAll(&graph);
    defer compiled.deinit();
    defer for (compiled.codegens) |*codegen| codegen.freeOwnedConstantPayloads();
    try testing.expectEqual(@as(usize, 2), compiled.modules.len);

    const modes = [_]ModuleSourceTypeInput{ .omitted, .direct };
    try testing.expectEqual(@as(usize, 2), modes.len);
    var baseline: [2]?[]u8 = @splat(null);
    defer for (baseline) |bytes| if (bytes) |owned| allocator.free(owned);
    var merged_baseline: ?[]u8 = null;
    defer if (merged_baseline) |owned| allocator.free(owned);
    var observations: usize = 0;
    for (modes) |mode| {
        var merged = try handler_contract_mod.initMergedContract(allocator, entry_path);
        defer merged.deinit(allocator);
        for (compiled.modules, compiled.parsers, 0..) |module, *parser, index| {
            const graph_module = &graph.module_list.items[graph.execution_order[index]];
            const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
            const parsed = ParsedModule.fromTypedExisting(view, module.root, &atoms, &parser.type_store);
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initContractOnly(allocator, parsed, .{ .extraction = .{
                .source_types = mode,
                .strict = false,
            } });
            defer analysis.deinit();
            try analysis.complete();
            try testing.expectEqual(type_env_mod.SourceTypeMode.omitted, analysis.type_env_storage.envPtr().?.sourceTypeMode().?);
            var contract = try analysis.extractContract(graph_module.path);
            defer contract.deinit(allocator);
            const is_entry = index == compiled.modules.len - 1;
            const capsule_count: usize = if (is_entry) 0 else 1;
            try testing.expectEqual(capsule_count, contract.function_capsules.items.len);
            try testing.expectEqual(capsule_count, contract.function_effect_capsules.items.len);
            for (contract.function_capsules.items) |capsule| {
                try testing.expectEqualStrings("helper", capsule.function);
                try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
            }
            for (contract.function_effect_capsules.items) |capsule| {
                try testing.expectEqualStrings("helper", capsule.function);
                try testing.expectEqual(@as(usize, 0), capsule.declared.items.len);
            }
            try testing.expect(contract.declared_specs_implicit);
            const defaults = @import("spec_discharge.zig").v1_spec_names;
            try testing.expect(defaults.len > 1);
            try testing.expectEqual(defaults.len, contract.declared_specs.items.len);
            for (defaults) |expected| {
                var matches: usize = 0;
                for (contract.declared_specs.items) |actual| {
                    if (std.mem.eql(u8, expected, actual)) matches += 1;
                }
                try testing.expectEqual(@as(usize, 1), matches);
            }
            const json = try serializeContractForTest(allocator, &contract);
            defer allocator.free(json);
            if (baseline[index]) |expected| {
                try testing.expectEqualStrings(expected, json);
            } else {
                baseline[index] = try allocator.dupe(u8, json);
            }
            try handler_contract_mod.mergeModuleContract(allocator, &merged, &contract, index == compiled.modules.len - 1);
            observations += 1;
        }
        try testing.expect(merged.properties == null);
        const merged_json = try serializeContractForTest(allocator, &merged);
        defer allocator.free(merged_json);
        if (merged_baseline) |expected| {
            try testing.expectEqualStrings(expected, merged_json);
        } else {
            merged_baseline = try allocator.dupe(u8, merged_json);
        }
    }
    try testing.expectEqual(@as(usize, 4), observations);
}

test "source graph uses compiled direct entry types and omits dependency types" {
    const allocator = testing.allocator;
    const Probe = struct {
        var entries: usize = 0;
        var dependencies: usize = 0;

        fn check(checker: *TypeChecker, root: NodeIndex) anyerror!u32 {
            if (checker.env.getSourceFnSigByName("handler")) |signature| {
                try testing.expectEqual(type_env_mod.SourceTypeMode.direct, checker.env.sourceTypeMode().?);
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                defer names.deinit(checker.env.allocator);
                _ = try checker.env.extractProofMembers(signature.return_type, &names);
                try testing.expectEqual(@as(usize, 1), names.items.len);
                try testing.expectEqualStrings("pure", names.items[0]);
                entries += 1;
            } else {
                try testing.expectEqual(type_env_mod.SourceTypeMode.omitted, checker.env.sourceTypeMode().?);
                try testing.expect(checker.env.getSourceFnSigByName("helper") == null);
                dependencies += 1;
            }
            return checker.check(root);
        }
    };
    const selections = [_]?ModuleSourceTypeInput{ .direct, null };
    for (selections) |selection| {
        Probe.entries = 0;
        Probe.dependencies = 0;
        source_selection_graph_reads = 0;
        var direct = try extractContract(allocator, sourceSelectionGraphEntry, "/source-selection/entry.ts", .{
            .source_types = selection,
            .read_file = readSourceSelectionGraphFile,
            .type_check = Probe.check,
            .strict = false,
        });
        defer direct.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), source_selection_graph_reads);
        try testing.expectEqual(@as(usize, 1), Probe.entries);
        try testing.expectEqual(@as(usize, 1), Probe.dependencies);
        try testing.expect(direct.properties == null);
    }
}

fn expectOmittedHelperReceipt(
    contract: *const HandlerContract,
    function_name: []const u8,
    expected_type: []const u8,
    expected_json_len: usize,
    expected_json_sha256: []const u8,
) !void {
    try testing.expectEqual(@as(usize, 1), contract.function_capsules.items.len);
    const proof = contract.function_capsules.items[0];
    try testing.expectEqualStrings(function_name, proof.function);
    try testing.expectEqual(@as(u32, 1), proof.line);
    try testing.expectEqual(@as(usize, 0), proof.declared.items.len);
    try testing.expect(proof.proven_total);
    try testing.expect(proof.proven_pure);
    try testing.expect(proof.proven_read_only);
    try testing.expect(proof.proven_deterministic);
    try testing.expect(!proof.discharged);
    try testing.expect(!proof.exported);
    try testing.expect(proof.handler_reachable);

    try testing.expectEqual(@as(usize, 1), contract.function_effect_capsules.items.len);
    const effect = contract.function_effect_capsules.items[0];
    try testing.expectEqualStrings(function_name, effect.function);
    try testing.expectEqual(@as(u32, 1), effect.line);
    try testing.expectEqual(@as(usize, 0), effect.declared.items.len);
    try testing.expectEqual(@as(usize, 0), effect.inferred.items.len);
    try testing.expect(!effect.discharged);
    try testing.expect(!effect.exported);
    try testing.expect(effect.handler_reachable);

    try testing.expectEqual(@as(usize, 1), contract.holes.items.len);
    const hole = contract.holes.items[0];
    try testing.expectEqualStrings(function_name, hole.function);
    try testing.expectEqual(@as(u32, 1), hole.line);
    try testing.expectEqual(@as(u32, 36), hole.column);
    try testing.expectEqualStrings(expected_type, hole.expected_type);
    try testing.expectEqual(@as(usize, 0), hole.remaining_budget.items.len);
    try testing.expect(!hole.budget_declared);
    try testing.expectEqual(@as(usize, 0), hole.undischarged.items.len);
    try testing.expectEqual(@as(usize, 0), hole.in_scope.items.len);
    try testing.expectEqual(@as(usize, 1), contract.spec_diagnostics.items.len);

    const json = try serializeContractForTest(testing.allocator, contract);
    defer testing.allocator.free(json);
    try testing.expectEqual(expected_json_len, json.len);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(json);
    const actual_hash = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    try testing.expectEqualStrings(expected_json_sha256, &actual_hash);
}

fn extractOmittedContractForTest(
    allocator: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
) !HandlerContract {
    var source_owner: source_frontend_mod.DirectCheckSource = undefined;
    try source_owner.initInPlace(allocator, allocator, source, filename);
    defer source_owner.deinit();
    const accepted = source_owner.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(
        allocator,
        ParsedModule.fromTypedExisting(accepted.ir_view, accepted.root, accepted.atoms, accepted.type_store),
        .{},
    );
    defer analysis.deinit();
    try analysis.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.omitted,
        analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
    );
    return analysis.extractContract(filename);
}

test "explicit omitted selection preserves native ABI holes and hides authored signatures" {
    const allocator = testing.allocator;
    const abi_source =
        \\function isDict(): number { return hole(); }
        \\function handler(req: Request): Response { return Response.text(String(isDict(undefined))); }
    ;
    var abi_contract = try extractOmittedContractForTest(
        allocator,
        abi_source,
        "omitted-abi-is-dict.ts",
    );
    defer abi_contract.deinit(allocator);
    try expectOmittedHelperReceipt(
        &abi_contract,
        "isDict",
        "boolean",
        3327,
        "bdd94a5843dc02246e3fae8feec409d82f8b2c995924781666da5865c368a358",
    );

    const helper_source =
        \\function helper(): number { return hole(); }
        \\function handler(req: Request): Response { return Response.text(String(helper())); }
    ;
    var helper_contract = try extractOmittedContractForTest(
        allocator,
        helper_source,
        "omitted-ordinary-helper.ts",
    );
    defer helper_contract.deinit(allocator);
    try expectOmittedHelperReceipt(
        &helper_contract,
        "helper",
        "unknown",
        3331,
        "90560e2d00b47ba2ed71a1c6ee10c2d9066987a1fca0ac0235e229da1955f980",
    );
}

test "an empty parser-owned Store selects direct and remains distinct from omitted" {
    const allocator = testing.allocator;
    const source = "function handler(req) { return Response.text(\"ok\"); }\n";
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    try testing.expect(std.meta.eql(
        parser.type_store.checkpoint(),
        std.mem.zeroes(TypeSyntax.Store.Checkpoint),
    ));
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const typed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);

    var direct: ModuleAnalysisSession = .{};
    try direct.initSoundExtraction(allocator, typed, .{
        .source_types = .direct,
        .strict = false,
    });
    defer direct.deinit();
    try direct.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.direct,
        direct.type_env_storage.envPtr().?.sourceTypeMode().?,
    );

    var omitted: ModuleAnalysisSession = .{};
    try omitted.initSoundExtraction(allocator, typed, .{
        .source_types = .omitted,
        .strict = false,
    });
    defer omitted.deinit();
    try omitted.complete();
    try testing.expectEqual(
        type_env_mod.SourceTypeMode.omitted,
        omitted.type_env_storage.envPtr().?.sourceTypeMode().?,
    );

    var missing: ModuleAnalysisSession = .{};
    try missing.initSoundExtraction(
        allocator,
        ParsedModule.fromExisting(view, root, &atoms),
        .{ .source_types = .direct, .strict = false },
    );
    defer missing.deinit();
    try testing.expectError(error.DirectTypeSyntaxUnavailable, missing.complete());
    try testing.expectError(error.AnalysisAlreadyAttempted, missing.complete());
}

test "consumer entry points reject operational source failures before semantic absence" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const value = 1;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);

    var poisoned_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var poisoned_pool = TypePool.init(poisoned_allocator.allocator());
    defer poisoned_pool.deinit(poisoned_allocator.allocator());
    try testing.expect(poisoned_allocator.has_induced_failure);
    var poisoned_env = TypeEnv.init(allocator, &poisoned_pool);
    defer poisoned_env.deinit();
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        null,
        parsed_state.root,
        .{ .type_source = .{ .direct = &poisoned_env } },
    ));

    var failed_env_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var failed_env_pool = TypePool.init(failed_env_allocator.allocator());
    defer failed_env_pool.deinit(failed_env_allocator.allocator());
    var failed_env = TypeEnv.init(failed_env_allocator.allocator(), &failed_env_pool);
    defer failed_env.deinit();
    try failed_env.ensureHealthy();
    try failed_env_pool.ensureHealthy();
    failed_env_allocator.fail_index = failed_env_allocator.alloc_index;
    failed_env.putTypeAlias("induced_failure", failed_env_pool.idx_string);
    try testing.expect(failed_env_allocator.has_induced_failure);
    try testing.expectError(error.OutOfMemory, failed_env.ensureHealthy());
    try failed_env_pool.ensureHealthy();
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        null,
        parsed_state.root,
        .{ .type_source = .{ .direct = &failed_env } },
    ));

    var healthy_pool = TypePool.init(allocator);
    defer healthy_pool.deinit(allocator);
    var healthy_env = TypeEnv.init(allocator, &healthy_pool);
    defer healthy_env.deinit();
    var empty_store = TypeSyntax.Store.init(allocator, "const value = 1;\n");
    defer empty_store.deinit();
    var source_atoms = AtomTable.init(allocator);
    defer source_atoms.deinit();
    try healthy_env.populateSourceTypes(.{ .direct = .{
        .store = &empty_store,
        .ir_view = view,
        .atoms = &source_atoms,
    } });
    var omitted_env_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var omitted_pool = TypePool.init(omitted_env_allocator.allocator());
    defer omitted_pool.deinit(omitted_env_allocator.allocator());
    var omitted_env = TypeEnv.init(omitted_env_allocator.allocator(), &omitted_pool);
    defer omitted_env.deinit();
    try omitted_env.populateSourceTypes(.omitted);
    try omitted_env.ensureHealthy();
    try omitted_pool.ensureHealthy();
    omitted_env_allocator.fail_index = omitted_env_allocator.alloc_index;
    omitted_env.putTypeAlias("induced_failure", omitted_pool.idx_string);
    try testing.expect(omitted_env_allocator.has_induced_failure);
    try testing.expectError(error.OutOfMemory, omitted_env.ensureHealthy());
    try omitted_pool.ensureHealthy();
    try testing.expectError(
        error.OutOfMemory,
        type_env_mod.ConsumerTypeSource.fromEnvironment(&omitted_env),
    );

    var omitted_pool_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failed_omitted_pool = TypePool.init(omitted_pool_allocator.allocator());
    defer failed_omitted_pool.deinit(omitted_pool_allocator.allocator());
    try testing.expect(omitted_pool_allocator.has_induced_failure);
    var failed_omitted_pool_env = TypeEnv.init(allocator, &failed_omitted_pool);
    defer failed_omitted_pool_env.deinit();
    try failed_omitted_pool_env.populateSourceTypes(.omitted);
    try testing.expectError(
        error.OutOfMemory,
        type_env_mod.ConsumerTypeSource.fromEnvironment(&failed_omitted_pool_env),
    );

    var healthy_omitted_pool = TypePool.init(allocator);
    defer healthy_omitted_pool.deinit(allocator);
    var healthy_omitted_env = TypeEnv.init(allocator, &healthy_omitted_pool);
    defer healthy_omitted_env.deinit();
    try healthy_omitted_env.populateSourceTypes(.omitted);
    var wrong_mode = effect_inference.Analyzer.init(allocator, view, null);
    defer wrong_mode.deinit();
    wrong_mode.type_source = .{ .direct = &healthy_omitted_env };
    try testing.expectError(error.TypeSourceModeMismatch, wrong_mode.analyze(parsed_state.root));

    var builder_facts = try ModuleFacts.build(allocator, view, null, null);
    defer builder_facts.deinit();
    var builder_effects = try effect_inference.buildEffectFacts(allocator, view, null, parsed_state.root, .{});
    defer builder_effects.deinit(allocator);

    var other_pool = TypePool.init(allocator);
    defer other_pool.deinit(allocator);
    var other_env = TypeEnv.init(allocator, &other_pool);
    defer other_env.deinit();
    try other_env.populateSourceTypes(.{ .direct = .{
        .store = &empty_store,
        .ir_view = view,
        .atoms = &source_atoms,
    } });
    var wrong_environment = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &healthy_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer wrong_environment.deinit();
    wrong_environment.effect_facts = null;
    wrong_environment.source_types = .{ .direct = &other_env };
    try testing.expectError(error.TypeSourceEnvironmentMismatch, wrong_environment.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));

    var poisoned_builder = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &poisoned_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer poisoned_builder.deinit();
    poisoned_builder.effect_facts = null;
    poisoned_builder.source_types = .{ .direct = &poisoned_env };
    try testing.expectError(error.OutOfMemory, poisoned_builder.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));

    var healthy_builder = ContractBuilder.initForBuild(
        allocator,
        view,
        null,
        &healthy_env,
        null,
        &builder_facts,
        &builder_effects,
    );
    defer healthy_builder.deinit();
    healthy_builder.effect_facts = null;
    healthy_builder.source_types = .{ .direct = &healthy_env };
    try testing.expectError(error.CompletedEffectFactsRequired, healthy_builder.build(
        "operational.ts",
        null,
        null,
        parsed_state.root,
        null,
        false,
        null,
    ));
}

const directCallbackSource =
    \\structural CryptoValue = Effects<string, "crypto">;
    \\function run(callback: (value: string) => CryptoValue, value: string): Effects<string, "crypto"> {
    \\  return callback(value);
    \\}
    \\function handler(req: Request): Response { return Response.text("ok"); }
;

fn expectDirectCallbackFacts(facts: *const EffectFacts) !void {
    var found = false;
    for (facts.all()) |function| {
        if (!std.mem.eql(u8, function.name, "run")) continue;
        try testing.expect(function.row.capabilities.contains(.crypto));
        try testing.expect(!function.row.lower_bound);
        try testing.expect(function.row.deterministic);
        found = true;
    }
    try testing.expect(found);
}

test "direct session population closes allocation failures without retry" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, directCallbackSource, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        fn populate(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(run_allocator, module, .{
                .source_types = .direct,
                .strict = false,
            });
            defer analysis.deinit();
            analysis.complete() catch |err| {
                try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
                return err;
            };
            try testing.expectEqual(
                type_env_mod.SourceTypeMode.direct,
                analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
            );
            try analysis.type_env_storage.envPtr().?.ensureHealthy();
            try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.populate(counting.allocator(), parsed);
    try testing.expect(counting.alloc_index > 0);
    var failures: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        Run.populate(failing.allocator(), parsed) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
    }
    try testing.expect(failures > 0);
}

test "direct callback effect projection closes every allocation failure" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, directCallbackSource, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var marker_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    var marker_storage: TypeEnvStorage = .{};
    defer marker_storage.deinit(marker_allocator.allocator());
    try marker_storage.initWithSource(marker_allocator.allocator(), .{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });
    {
        var marker_control = try effect_inference.buildEffectFacts(
            marker_allocator.allocator(),
            view,
            &atoms,
            root,
            .{ .type_source = .{ .direct = marker_storage.envPtr().? } },
        );
        defer marker_control.deinit(marker_allocator.allocator());
        try expectDirectCallbackFacts(&marker_control);
    }

    marker_allocator.fail_index = marker_allocator.alloc_index;
    try testing.expectError(error.OutOfMemory, effect_inference.buildEffectFacts(
        allocator,
        view,
        &atoms,
        root,
        .{ .type_source = .{ .direct = marker_storage.envPtr().? } },
    ));
    try testing.expect(marker_allocator.has_induced_failure);
    try marker_storage.envPtr().?.ensureHealthy();
    try marker_storage.envPtr().?.pool.ensureHealthy();

    var storage: TypeEnvStorage = .{};
    defer storage.deinit(allocator);
    try storage.initWithSource(allocator, .{ .direct = .{
        .store = &parser.type_store,
        .ir_view = view,
        .atoms = &atoms,
    } });
    var module_facts = try ModuleFacts.build(allocator, view, &atoms, null);
    defer module_facts.deinit();
    const handler = handler_function_mod.findHandlerFunction(view, root);
    const Run = struct {
        fn project(
            run_allocator: std.mem.Allocator,
            ir_view: IrView,
            atom_table: *AtomTable,
            program: NodeIndex,
            env: *const TypeEnv,
            facts: *const ModuleFacts,
            selected_handler: ?NodeIndex,
        ) !void {
            var effects = try effect_inference.buildEffectFacts(
                run_allocator,
                ir_view,
                atom_table,
                program,
                .{
                    .module_facts = facts,
                    .type_source = .{ .direct = env },
                    .contract_projection = .{ .complete = .{
                        .selected_handler = selected_handler,
                    } },
                },
            );
            defer effects.deinit(run_allocator);
            try expectDirectCallbackFacts(&effects);
            _ = try effects.requireContract();
        }
    };

    var counting = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    try Run.project(
        counting.allocator(),
        view,
        &atoms,
        root,
        storage.envPtr().?,
        &module_facts,
        handler,
    );
    try testing.expect(counting.alloc_index > 0);
    var failures: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        Run.project(
            failing.allocator(),
            view,
            &atoms,
            root,
            storage.envPtr().?,
            &module_facts,
            handler,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            continue;
        };
        try testing.expect(!failing.has_induced_failure);
    }
    try testing.expect(failures > 0);
}

test "direct extraction keeps attempted state across allocation failures" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, directCallbackSource, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        const Outcome = enum {
            success,
            failed_before_effects,
            failed_after_effects,
        };

        fn control(base: std.mem.Allocator, module: ParsedModule) !usize {
            var counting = std.testing.FailingAllocator.init(base, .{
                .fail_index = std.math.maxInt(usize),
            });
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(counting.allocator(), module, .{
                .source_types = .direct,
                .strict = false,
                .capture_export_effects = true,
            });
            defer analysis.deinit();
            try analysis.complete();
            const before = counting.alloc_index;
            var contract = try analysis.extractContract("direct-extraction.ts");
            defer contract.deinit(counting.allocator());
            var export_effects = analysis.takeExportEffects() orelse
                return error.ExportEffectsMissing;
            defer export_effects.deinit(counting.allocator());
            try testing.expectEqual(ModuleAnalysisSession.PassState.completed, analysis.extraction_state);
            try testing.expectEqual(@as(usize, 1), contract.function_effect_capsules.items.len);
            try testing.expectEqualStrings(
                "run",
                contract.function_effect_capsules.items[0].function,
            );
            return counting.alloc_index - before;
        }

        fn failAt(
            base: std.mem.Allocator,
            module: ParsedModule,
            offset: usize,
        ) !Outcome {
            var failing = std.testing.FailingAllocator.init(base, .{
                .fail_index = std.math.maxInt(usize),
            });
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(failing.allocator(), module, .{
                .source_types = .direct,
                .strict = false,
                .capture_export_effects = true,
            });
            defer analysis.deinit();
            try analysis.complete();
            failing.fail_index = failing.alloc_index + offset;
            const result = analysis.extractContract("direct-extraction.ts");
            if (result) |contract_value| {
                var contract = contract_value;
                defer contract.deinit(failing.allocator());
                var export_effects = analysis.takeExportEffects() orelse
                    return error.ExportEffectsMissing;
                defer export_effects.deinit(failing.allocator());
                try testing.expect(!failing.has_induced_failure);
                return .success;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expect(failing.has_induced_failure);
                try testing.expectEqual(ModuleAnalysisSession.PassState.attempted, analysis.extraction_state);
                try testing.expect(analysis.takeExportEffects() == null);
                try testing.expectError(
                    error.ContractExtractionAlreadyAttempted,
                    analysis.extractContract("direct-extraction.ts"),
                );
                try testing.expectEqual(
                    type_env_mod.SourceTypeMode.direct,
                    analysis.type_env_storage.envPtr().?.sourceTypeMode().?,
                );
                try analysis.type_env_storage.envPtr().?.ensureHealthy();
                try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
                return if (analysis.contract_effect_facts != null)
                    .failed_after_effects
                else
                    .failed_before_effects;
            }
        }
    };

    const allocation_count = try Run.control(allocator, parsed);
    try testing.expect(allocation_count > 0);
    var failures_before_effects: usize = 0;
    var failures_after_effects: usize = 0;
    for (0..allocation_count) |offset| {
        switch (try Run.failAt(allocator, parsed, offset)) {
            .success => {},
            .failed_before_effects => failures_before_effects += 1,
            .failed_after_effects => failures_after_effects += 1,
        }
    }
    try testing.expect(failures_before_effects > 0);
    try testing.expect(failures_after_effects > 0);
}

test "serialization failure preserves a completed direct extraction" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, directCallbackSource, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(
        allocator,
        ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store),
        .{ .source_types = .direct, .strict = false },
    );
    defer analysis.deinit();
    try analysis.complete();
    var contract = try analysis.extractContract("serialization.ts");
    defer contract.deinit(allocator);
    const baseline = try serializeContractForTest(allocator, &contract);
    defer allocator.free(baseline);
    try testing.expectError(error.AnalysisAlreadyAttempted, analysis.complete());
    try testing.expectError(
        error.ContractExtractionAlreadyAttempted,
        analysis.extractContract("serialization.ts"),
    );

    var no_resize = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    var counting = std.testing.FailingAllocator.init(no_resize.allocator(), .{
        .fail_index = std.math.maxInt(usize),
    });
    const counted = try serializeContractForTest(counting.allocator(), &contract);
    counting.allocator().free(counted);
    try testing.expect(counting.alloc_index > 0);

    var failures: usize = 0;
    var failures_after_progress: usize = 0;
    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(no_resize.allocator(), .{ .fail_index = fail_index });
        const attempted = serializeContractForTest(failing.allocator(), &contract);
        if (attempted) |bytes| {
            defer failing.allocator().free(bytes);
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqualStrings(baseline, bytes);
        } else |err| {
            switch (err) {
                error.OutOfMemory, error.WriteFailed => {},
            }
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            if (fail_index > 0) failures_after_progress += 1;
        }

        try testing.expectEqual(ModuleAnalysisSession.PassState.completed, analysis.extraction_state);
        try analysis.type_env_storage.envPtr().?.ensureHealthy();
        try analysis.type_env_storage.envPtr().?.pool.ensureHealthy();
        try testing.expectEqualStrings("serialization.ts", contract.handler.path);
        const after_failure = try serializeContractForTest(allocator, &contract);
        defer allocator.free(after_failure);
        try testing.expectEqualStrings(baseline, after_failure);
    }
    try testing.expect(failures > 0);
    try testing.expect(failures_after_progress > 0);
}

test "prepared evaluation contracts omit authored signatures and capsules" {
    const source = "function helper(value: number): string { return \"ok\"; } function handler(req: Request): Effects<Response, \"env\"> { return Response.text(helper(\"wrong\")); }";
    var actual = try extractPreparedEvalContract(std.testing.allocator, source, "<eval>", .{ .strict = false });
    defer actual.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<eval>", actual.handler.path);
    try std.testing.expectEqual(@as(usize, 1), actual.function_capsules.items.len);
    try std.testing.expectEqualStrings("helper", actual.function_capsules.items[0].function);
    try std.testing.expectEqual(@as(usize, 0), actual.function_capsules.items[0].declared.items.len);
    try std.testing.expectEqual(@as(usize, 1), actual.function_effect_capsules.items.len);
    try std.testing.expectEqualStrings("helper", actual.function_effect_capsules.items[0].function);
    try std.testing.expectEqual(@as(usize, 0), actual.function_effect_capsules.items[0].declared.items.len);
    try std.testing.expect(actual.declared_specs_implicit);
    try std.testing.expectError(error.UnsupportedSourceExtension, extractPreparedEvalContract(std.testing.allocator, source, "inline.ts", .{}));
}

test "public source contract extraction projects actual flow sinks" {
    const allocator = testing.allocator;
    const cases = [_]struct { source: []const u8, secret_safe: bool, injection_safe: bool }{
        .{ .source = "import { env } from 'zttp:env'; function handler(req: Request): Response { return Response.text(env('API_SECRET') ?? ''); }", .secret_safe = false, .injection_safe = true },
        .{ .source = "import { env } from 'zttp:env'; function handler(req: Request): Response { const unused = env('API_SECRET'); return Response.text('ok'); }", .secret_safe = true, .injection_safe = true },
        .{ .source = "function handler(req: Request): Response { return Response.html(req.url); }", .secret_safe = true, .injection_safe = false },
    };
    for (cases) |case| {
        var contract = try extractContract(allocator, case.source, "flow-projection.ts", .{});
        defer contract.deinit(allocator);
        try testing.expectEqual(case.secret_safe, contract.properties.?.no_secret_leakage);
        try testing.expectEqual(case.injection_safe, contract.properties.?.injection_safe);
    }
}

fn readFlowProjectionDependency(allocator: std.mem.Allocator, path: []const u8) modules_mod.module_graph.ReadFileError![]const u8 {
    if (!std.mem.endsWith(u8, path, "dep.ts")) return error.FileNotFound;
    return allocator.dupe(u8,
        \\import { env } from "zttp:env";
        \\export structural SecretText = string;
        \\export function value(): SecretText { return env("API_SECRET") ?? ""; }
    );
}

test "public merged contracts omit flow claims for both clean and leaking imports" {
    const allocator = testing.allocator;
    const sources = [_][]const u8{
        "import { value } from './dep.ts'; function handler(req: Request): Response { return Response.text(value()); }",
        "import { value } from './dep.ts'; function handler(req: Request): Response { return Response.text('ok'); }",
    };
    for (sources) |source| {
        var contract = try extractContract(allocator, source, "/virtual/flow-projection.ts", .{ .strict = false, .read_file = readFlowProjectionDependency });
        defer contract.deinit(allocator);
        // Merged contracts contain capability facts, but no completed proof
        // profile. Absence cannot be projected as six vacuously true facts.
        try testing.expect(contract.properties == null);
        const json = try serializeContractForTest(allocator, &contract);
        defer allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"properties\": null") != null);
    }
}

test "flow projection preserves independent determinism and retry constraints" {
    var contract = handler_contract_mod.emptyContract(try testing.allocator.dupe(u8, "projection.ts"));
    defer contract.deinit(testing.allocator);
    contract.properties = .{ .pure = true, .read_only = true, .stateless = true, .retry_safe = true, .deterministic = false, .has_egress = false };
    contract.properties.?.deterministic = false;
    contract.properties.?.retry_safe = true;
    projectFlowProperties(&contract, .{});
    try testing.expect(!contract.properties.?.deterministic);
    try testing.expect(!contract.properties.?.idempotent);
    contract.properties.?.deterministic = true;
    contract.properties.?.retry_safe = false;
    projectFlowProperties(&contract, .{});
    try testing.expect(contract.properties.?.deterministic);
    try testing.expect(!contract.properties.?.idempotent);
}

test "ModuleAnalysisSession applies the flow rule for a module with no handler" {
    const allocator = testing.allocator;
    inline for (.{ FlowWithoutHandler.keep_defaults, FlowWithoutHandler.unproven }) |rule| {
        var parsed_state = try parseSourceForTest(allocator, "const value = 1;\n");
        defer parsed_state.js_parser.deinit();
        const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
        const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

        var session: ModuleAnalysisSession = .{};
        try session.initSoundExtraction(allocator, parsed, .{ .strict = false, .flow = rule });
        defer session.deinit();
        try session.complete();
        var contract = try session.extractContract("no-handler.ts");
        defer contract.deinit(allocator);
        const properties = contract.properties orelse return error.PropertiesMissing;
        try testing.expectEqual(rule == .keep_defaults, properties.no_secret_leakage);
        try testing.expectEqual(rule == .keep_defaults, properties.injection_safe);
        try testing.expect(!properties.deterministic);
    }
}
