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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

pub const JsParser = parser_mod.JsParser;

fn parseSourceForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    js_parser: JsParser,
    root: NodeIndex,
} {
    var js_parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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

fn graphCallbackModule(view: IrView) ?GraphCallbackModule {
    for (0..view.nodeCount()) |idx| {
        const node: NodeIndex = @intCast(idx);
        const tag = view.getTag(node) orelse continue;
        if (tag != .import_decl) continue;
        const import_decl = view.getImportDecl(node) orelse continue;
        const module_name = view.getString(import_decl.module_idx) orelse continue;
        if (std.mem.eql(u8, module_name, "zttp:sql")) return .shared;
        if (std.mem.eql(u8, module_name, "zttp:env")) return .left;
        if (std.mem.eql(u8, module_name, "zttp:cache")) return .right;
        if (std.mem.eql(u8, module_name, "zttp:fetch")) return .entry;
    }
    return null;
}

fn recordGraphModuleScan(view: IrView) anyerror!void {
    const probe = active_graph_callback_probe orelse return error.GraphCallbackProbeMissing;
    if (probe.count >= probe.modules.len) return error.GraphCallbackCountExceeded;
    probe.modules[probe.count] = graphCallbackModule(view) orelse
        return error.GraphCallbackModuleUnknown;
    probe.count += 1;
    if (probe.fail_after == probe.count) return error.GraphCallbackRefused;
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
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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

fn rejectingModuleScan(_: IrView) anyerror!void {
    return error.TestModuleScanRan;
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
    var parser = try JsParser.initAdmission(allocator, allocator,
        \\import { run } from "./helper.ts";
        \\function handler(req) { run(); return Response.text("ok"); }
    , .compile);
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
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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
    // A slot-only lookup would take `leaky` for the `env` import and hide the fetchSync.
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
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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
    try session.initSoundExtraction(allocator, parsed, .{ .strict = false, .flow = true });
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
        .module_scan = rejectingModuleScan,
        .capture_export_effects = true,
    });
    defer analysis.deinit();

    try analysis.complete();
    try testing.expectError(error.TestModuleScanRan, analysis.extractContract("custom.ts"));
    try testing.expect(analysis.resolved.?.type_checker != null);
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
    var js_parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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

    var js_parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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

        fn scan(_: IrView) anyerror!void {
            call_count += 1;
        }
    };

    var default_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
    });
    defer default_contract.deinit(allocator);

    Callback.call_count = 0;
    var custom_contract = try extractContract(allocator, source, "handler.ts", .{
        .strict = false,
        .module_scan = Callback.scan,
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

test "extractContract refuses a virtual entry path and an unmapped extension" {
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

    try testing.expectError(
        error.UnsupportedSourceExtension,
        extractContract(allocator, "function handler(req) { return Response.text(\"ok\"); }", "<untyped-entry>", .{ .strict = false }),
    );

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

test "extractContract applies entry types in a module graph" {
    const source =
        \\import { helper } from "./dep.ts";
        \\function handler(req: Request): Response {
        \\  const port: number = "bad";
        \\  return Response.text(helper() + String(port));
        \\}
    ;

    try testing.expectError(
        error.SoundModeViolation,
        extractContract(testing.allocator, source, "/source-selection/entry.ts", .{
            .strict = false,
            .read_file = readSourceSelectionGraphFile,
        }),
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
        .module_scan = recordGraphModuleScan,
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
    var js_parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
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
    // Each must not raise a mismatch of its own on top of ZTS105.
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
}

/// How many ZTS104 and ZTS106 diagnostics the boolean checker reported over one source.
fn expectArithCounts(source: []const u8, comptime arith: usize, comptime addable: usize) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(arith, countKind(diagnostics, bool_checker_mod.DiagnosticKind.arithmetic_on_non_numeric));
            try testing.expectEqual(addable, countKind(diagnostics, bool_checker_mod.DiagnosticKind.add_on_non_addable));
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "plus on a parameter declared number or undefined is refused" {
    try expectArithCounts(
        "function inc(x: number | undefined): number { return x + 1; }",
        0,
        1,
    );
}

test "times on a result that may be undefined is refused" {
    try expectArithCounts(
        \\function pick(flag: boolean): number | undefined { return flag ? 3 : undefined; }
        \\const x = pick(false);
        \\const total = x * 2;
    ,
        1,
        0,
    );
}

test "minus on an optional field is refused" {
    try expectArithCounts(
        \\structural Box = { n?: number };
        \\const b: Box = {};
        \\const total = b.n - 1;
    ,
        1,
        0,
    );
}

test "unary minus on a value that may be undefined is refused" {
    try expectArithCounts(
        "function neg(x: number | undefined): number { return -x; }",
        1,
        0,
    );
}

test "plus on an array index read is refused" {
    try expectArithCounts(
        \\const xs: number[] = [1, 2];
        \\const total = xs[5] + 1;
    ,
        0,
        1,
    );
}

test "times on a parameter declared unknown is refused" {
    try expectArithCounts(
        "function twice(v: unknown): number { return v * 2; }",
        1,
        0,
    );
}

test "plus on a parameter declared number or null is refused" {
    try expectArithCounts(
        "function inc(x: number | null): number { return x + 1; }",
        0,
        1,
    );
}

test "a refused plus does not refuse the times around it" {
    try expectArithCounts(
        "function f(x: number | undefined): number { return (x + 1) * 2; }",
        0,
        1,
    );
}

test "minus on a type parameter is refused" {
    try expectArithCounts(
        "const f = <T>(v: T): number => v - 1;",
        1,
        0,
    );
}

test "unary minus on a boolean is refused" {
    try expectArithCounts(
        "function neg(b: boolean): number { return -b; }",
        1,
        0,
    );
}

test "a plus on an optional string leaves the times around it alone" {
    try expectArithCounts(
        \\structural Box = { s?: string };
        \\const b: Box = {};
        \\const total = (b.s + 1) * 2;
    ,
        0,
        1,
    );
}

test "the refusal of an optional number names the type and the guard to write" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqualStrings("'number | undefined' operand in '*' operator; arithmetic requires numbers", diagnostics[0].message);
            try testing.expectEqualStrings(
                "compare with undefined in an if and compute inside the branch, or supply a default with ??",
                diagnostics[0].help orelse "",
            );
        }
    };
    try withSession(testing.allocator, "function f(x: number | undefined): number { return x * 2; }", Probe.run);
}

test "the refusal of a nullable number gives the null help text" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqualStrings(
                "compare with null in an if, and compute inside the branch",
                diagnostics[0].help orelse "",
            );
        }
    };
    try withSession(testing.allocator, "function f(x: number | null): number { return x * 2; }", Probe.run);
}

test "the refusal of a number that may be null or undefined gives the nested if help text" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqualStrings(
                "compare with undefined and with null in nested ifs, and compute inside the inner branch",
                diagnostics[0].help orelse "",
            );
        }
    };
    try withSession(testing.allocator, "function f(x: number | null | undefined): number { return x * 2; }", Probe.run);
}

test "the refusal of an unknown operand gives the typeof help text" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqualStrings("'unknown' operand in '*' operator; arithmetic requires numbers", diagnostics[0].message);
            try testing.expectEqualStrings(
                "narrow the value to number first, for example with typeof in an if",
                diagnostics[0].help orelse "",
            );
        }
    };
    try withSession(testing.allocator, "function f(v: unknown): number { return v * 2; }", Probe.run);
}

test "a plus on an optional number reports the addition message" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.boolDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqualStrings("'number | undefined' operand in '+' operator; addition requires numbers", diagnostics[0].message);
        }
    };
    try withSession(testing.allocator, "function f(x: number | undefined): number { return x + 1; }", Probe.run);
}

test "arithmetic on a value proven to be a number is accepted" {
    try expectArithCounts(
        "function f(x: number | undefined): number { if (x !== undefined) { return x + 1; } return 0; }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(x: number | undefined): number { return x !== undefined ? x + 1 : 0; }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(x: number | undefined): boolean { return x !== undefined && x * 2 > 1; }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(xs: number[]): number[] { return xs.map((v: number): number => v * 2); }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(x: number | undefined): number { if (x === undefined) { return 0; } return x + 1; }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(x: number | undefined): number { return (x ?? 0) + 1; }",
        0,
        0,
    );
    try expectArithCounts(
        "function f(v: unknown): number { if (typeof v === \"number\") { return v * 2; } return 0; }",
        0,
        0,
    );
    try expectArithCounts(
        \\function f(xs: number[]): number {
        \\  let total = 0;
        \\  for (const v of xs) { total = total + v * 2; }
        \\  return total;
        \\}
    ,
        0,
        0,
    );
    try expectArithCounts(
        \\structural Msg = { kind: "n", value: number } | { kind: "s", text: string };
        \\function f(m: Msg): number {
        \\  return match (m) {
        \\    when { kind: "n", value }: value + 1
        \\    default: 0
        \\  };
        \\}
    ,
        0,
        0,
    );
    try expectArithCounts(
        "function f(xs: number[]): number { return xs.length - 1; }",
        0,
        0,
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

        fn scan(view: IrView) anyerror!void {
            for (0..view.nodeCount()) |index| {
                const node: NodeIndex = @intCast(index);
                if (view.getTag(node) != .import_decl) continue;
                entries += 1;
                return;
            }
            dependencies += 1;
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
            .module_scan = Probe.scan,
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
        3291,
        "985662da1c1d4bdab93ddee83f81696915821427d4b17382aa3a1ef783bb94ce",
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
        3295,
        "2f4c36d04c9e366911a1cae42980834801a07becf5bafd8f99e4be7380797828",
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

test "ModuleAnalysisSession leaves the flow properties unproven for a module with no handler" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "const value = 1;\n");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);

    var session: ModuleAnalysisSession = .{};
    try session.initSoundExtraction(allocator, parsed, .{ .strict = false, .flow = true });
    defer session.deinit();
    try session.complete();
    var contract = try session.extractContract("no-handler.ts");
    defer contract.deinit(allocator);
    const properties = contract.properties orelse return error.PropertiesMissing;
    try testing.expectEqual(false, properties.no_secret_leakage);
    try testing.expectEqual(false, properties.injection_safe);
    try testing.expect(!properties.deterministic);
}

// ---------------------------------------------------------------------------
// Builtin result types (U1a of the builtin result types plan)
//
// Each form is assigned to `structural Nope = { zz: Bytes };`. A form with a
// type gets one ZTS200 whose message names that type. A form with no type
// gets none, which is how an untyped result passes today.
// ---------------------------------------------------------------------------

/// The one ZTS200 that `source` must report, with its exact message.
fn expectOneMismatch(source: []const u8, comptime message: []const u8) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.type_mismatch, diagnostics[0].kind);
            try testing.expectEqualStrings(message, diagnostics[0].message);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

/// `source` must report no type diagnostic.
fn expectNoTypeDiagnostic(source: []const u8) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            try testing.expectEqual(@as(usize, 0), session.resolved.typeDiagnostics().len);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "builtin result: length of an array is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: length of a string literal is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = "abc".length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: length of a string is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = s.length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Math.floor of a number is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(n: number): number { const p: Nope = Math.floor(n); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Math.PI is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Math.PI; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Number.MAX_SAFE_INTEGER is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Number.MAX_SAFE_INTEGER; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: parseInt of a string and a radix is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = parseInt(s, 10); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Number of a string is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = Number(s); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Number.isInteger of a number is boolean" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(n: number): number { const p: Nope = Number.isInteger(n); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: String of a number is string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(n: number): number { const p: Nope = String(n); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: indexOf on a string is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = s.indexOf("b"); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: split on a string is string array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = s.split(","); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: toUpperCase on a string is string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = s.toUpperCase(); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: repeat on a string is string or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = s.repeat(2); return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Date.now is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Date.now(); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: renderToString is string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = renderToString("x"); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Headers get on a request is string or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(req: Request): number { const p: Nope = req.headers.get("x"); return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Headers has on a request is boolean" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(req: Request): number { const p: Nope = req.headers.has("x"); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "false proof F1: the length of an array is not a string" {
    try expectOneMismatch(
        \\function f(xs: number[]): number { const a: string = xs.length; return 0; }
    , "type 'number' is not assignable to type 'string'");
}

test "false proof F2: a header that may be missing is not a string" {
    try expectOneMismatch(
        \\function f(req: Request): number { const token: string = req.headers.get("x"); return 0; }
    , "type 'string | undefined' is not assignable to type 'string'");
}

test "builtin result: an argument of the wrong type leaves the result untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = Math.floor(s); return 0; }
    );
}

test "builtin result: an argument that may be undefined leaves the result untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(n: number | undefined): number { const p: Nope = Math.floor(n); return 0; }
    );
}

test "builtin result: a missing argument leaves the result untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Math.floor(); return 0; }
    );
}

test "builtin result: split with a separator that is not a string stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string, n: number): number { const p: Nope = s.split(n); return 0; }
    );
}

test "builtin result: the length of a string that may be undefined stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string | undefined): number { const p: Nope = s.length; return 0; }
    );
}

test "builtin result: a parameter named Math keeps its own type" {
    try expectNoTypeDiagnostic(
        \\structural M = { floor: (n: number) => string };
        \\function f(Math: M): string { const s: string = Math.floor(1); return s; }
    );
}

test "builtin result: a parameter named Math is not the builtin" {
    try expectOneMismatch(
        \\structural M = { floor: (n: number) => string };
        \\structural Nope = { zz: Bytes };
        \\function f(Math: M): number { const p: Nope = Math.floor(1); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: a top-level binding named Math is not the builtin" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\const Math = { floor: (n: number): string => "x" };
        \\function f(): number { const p: Nope = Math.floor(1); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: a parameter named parseInt is not the builtin" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(parseInt: (s: string) => string): number { const p: Nope = parseInt("1"); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

// ---------------------------------------------------------------------------
// Builtin result types (U1b of the builtin result types plan): array
// receivers, argument shapes, JSON, Object, and Array. Each form is assigned
// to `Nope` as above.
// ---------------------------------------------------------------------------

test "builtin result: indexOf on an array is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.indexOf(1); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: includes on an array is boolean" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.includes(1); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: join on an array is string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.join(","); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: join with a separator that is not a string is still string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], n: number): number { const p: Nope = xs.join(n); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: slice on an array is the receiver array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.slice(0, 1); return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: splice on an array is the receiver array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { const p: Nope = xs.splice(0, 1); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: pop on an array is the element or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.pop(); return 0; }
    , "type 'number | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: shift on an array is the element or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { const p: Nope = xs.shift(); return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "false proof: the last element of an array may be undefined" {
    try expectOneMismatch(
        \\function f(xs: number[]): number { const last: number = xs.pop(); return last; }
    , "type 'number | undefined' is not assignable to type 'number'");
}

test "builtin result: push on an array is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.push(1, 2); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: unshift on an array is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.unshift(1); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: forEach on an array is undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (n: number) => number): number { const p: Nope = xs.forEach(cb); return 0; }
    , "type 'undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: concat of two number arrays is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], ys: number[]): number { const p: Nope = xs.concat(ys); return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: concat of a number array and a string array has both element types" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], ys: string[]): number { const p: Nope = xs.concat(ys); return 0; }
    , "type 'number | string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: concat of a string onto a number array has both element types" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], s: string): number { const p: Nope = xs.concat(s); return 0; }
    , "type 'number | string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: concat of an argument with no type stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], ys: number[] | undefined): number { const p: Nope = xs.concat(ys); return 0; }
    );
}

test "builtin result: map is the array of the callback return type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (n: number) => string): number { const p: Nope = xs.map(cb); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: map with a callback that has no type stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (n: number) => unknown): number { const p: Nope = xs.map(cb); return 0; }
    );
}

test "builtin result: reduce with an initial value joins its type and the callback return" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (acc: number, n: number) => number): number { const p: Nope = xs.reduce(cb, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: reduce keeps the initial value type when it differs from the callback return" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (acc: string | number, n: number) => number): number { const p: Nope = xs.reduce(cb, ""); return 0; }
    , "type 'string | number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: reduce with no initial value joins the element and the callback return" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (acc: number | string, n: number) => string): number { const p: Nope = xs.reduce(cb); return 0; }
    , "type 'number | string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: map with a callback whose parameter does not accept the element is ZTS203 and adds no result type" {
    try expectOneArgMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[], cb: (n: number) => number): number { const p: Nope = xs.map(cb); return 0; }
    , "callback parameter '#1' is 'number', but map passes 'string'");
}

test "builtin result: map with a callback that takes more required parameters than the runtime passes is ZTS203 and adds no result type" {
    try expectOneArgMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (n: number, i: number, a: number[], extra: number) => string): number { const p: Nope = xs.map(cb); return 0; }
    , "callback parameter '#4' is 'number', but map passes 'undefined'");
}

test "builtin result: reduce with an accumulator that does not accept the callback return is ZTS203 and adds no result type" {
    try expectOneArgMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], cb: (acc: string, n: number) => number): number { const p: Nope = xs.reduce(cb, ""); return 0; }
    , "callback parameter '#1' is 'string', but reduce passes 'number'");
}

/// The one ZTS201 (`missing_field`) that `source` must report, with its exact message and help.
fn expectOneMissingField(source: []const u8, comptime message: []const u8, comptime help: []const u8) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.missing_field, diagnostics[0].kind);
            try testing.expectEqual(type_checker_mod.Severity.err, diagnostics[0].severity);
            try testing.expectEqualStrings(message, diagnostics[0].message);
            try testing.expectEqualStrings(help, diagnostics[0].help orelse return error.HelpMissing);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "string index: an index read on a string is ZTS201 with a repair" {
    try expectOneMissingField(
        \\function f(): number { const s: string = "ab"; const c: string = s[0]; return 0; }
    , "an index read on a string yields undefined", "use s.charAt(i) or s.slice(i, i + 1)");
}

test "string index: an index read on a string literal is ZTS201" {
    try expectOneMissingField(
        \\function f(): number { const c = "ab"[0]; return 0; }
    , "an index read on a string yields undefined", "use s.charAt(i) or s.slice(i, i + 1)");
}

test "string index: an index read on a string parameter is ZTS201" {
    try expectOneMissingField(
        \\function f(s: string): number { const c = s[1]; return 0; }
    , "an index read on a string yields undefined", "use s.charAt(i) or s.slice(i, i + 1)");
}

test "string index: charAt, slice, and length on a string report nothing" {
    try expectNoTypeDiagnostic(
        \\function f(s: string): number { const a: string = s.charAt(0); const b: string = s.slice(0, 1); return s.length; }
    );
}

test "string index: an index read on a string array keeps string or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { const p: Nope = xs[0]; return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "string index: an index read on a union of string and string array is string or undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(x: string | string[]): number { const p: Nope = x[0]; return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

const non_record_member_message = "member does not exist on this type at runtime";
const non_record_member_help = "number and boolean values have no members; strings and arrays have only the methods that docs/typescript.md lists";
const unknown_member_message = "a member read on an unknown value; narrow it first";
const unknown_member_help = "check the value with typeof, isDict, or a match arm before you read a member";
const union_call_message = "a member that some union member does not have is called; narrow the union first";
const union_call_help = "check the discriminant or the type before you call the member";

test "member access: toFixed on a number is ZTS201" {
    try expectOneMissingField(
        \\function f(n: number): number { const s = n.toFixed(2); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: toString on a number literal binding is ZTS201" {
    try expectOneMissingField(
        \\function f(): number { const n = 3; const s = n.toString(); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: a member read on a boolean is ZTS201" {
    try expectOneMissingField(
        \\function f(b: boolean): number { const x = b.foo; return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: a member call on a string that the runtime does not install is ZTS201" {
    try expectOneMissingField(
        \\function f(s: string): number { const x = s.foo(); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: sort on an array is ZTS201 because the runtime does not install it" {
    try expectOneMissingField(
        \\function f(xs: number[]): number { const ys = xs.sort(); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: reverse on an array is ZTS201 because the runtime does not install it" {
    try expectOneMissingField(
        \\function f(xs: number[]): number { const ys = xs.reverse(); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: a member that a tuple does not have is ZTS201" {
    try expectOneMissingField(
        \\function f(t: [number, string]): number { const x = t.foo; return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: trim on a union of string and string array is ZTS201" {
    try expectOneMissingField(
        \\function f(x: string | string[]): number { const y = x.trim(); return 0; }
    , non_record_member_message, non_record_member_help);
}

test "member access: slice on a union of string and string array is installed on both" {
    try expectNoTypeDiagnostic(
        \\function f(x: string | string[]): number { const y = x.slice(0, 1); return 0; }
    );
}

test "member access: a member call on an unknown value is ZTS201" {
    try expectOneMissingField(
        \\function f(u: unknown): number { const y = u.trim(); return 0; }
    , unknown_member_message, unknown_member_help);
}

test "member access: a member read on an unknown value reports nothing" {
    try expectNoTypeDiagnostic(
        \\function f(u: unknown): number { const y = u.foo; const z = u.foo.bar; return 0; }
    );
}

test "member access: a read on a union of named records types the shared field" {
    try expectOneMismatch(
        \\structural A = { kind: "a"; n: number };
        \\structural B = { kind: "b"; s: string };
        \\structural Nope = { zz: Bytes };
        \\function f(x: A | B): number { const p: Nope = x.kind; return 0; }
    , "type '\"a\" | \"b\"' is not assignable to type '{ zz: Bytes }'");
}

test "member access: trim on the unknown result of dictGet over a Dict from isDict is ZTS201" {
    try expectOneMissingField(
        \\import { dictGet } from "zttp:collections";
        \\function f(u: unknown): number { if (isDict(u)) { const v = dictGet(u, "k"); const y = v.trim(); } return 0; }
    , unknown_member_message, unknown_member_help);
}

test "member access: trim on the typed result of dictGet is left to the absent read check" {
    try expectNoTypeDiagnostic(
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function f(): number { const d = dictSet(dictEmpty(), "k", 5); const v = dictGet(d, "k"); const y = v.trim(); return 0; }
    );
}

test "member access: a typeof guard gives an unknown value a member" {
    try expectNoTypeDiagnostic(
        \\function f(u: unknown): number { if (typeof u === "string") { const y = u.trim(); } return 0; }
    );
}

test "member access: a member that a union of records lacks is ZTS201 when called" {
    try expectOneMissingField(
        \\structural A = { kind: "a"; f: (n: number) => number };
        \\structural B = { kind: "b"; g: number };
        \\function run(x: A | B): number { return x.f(2); }
    , union_call_message, union_call_help);
}

test "member access: a member that a record and a string do not share is ZTS201 when called" {
    try expectOneMissingField(
        \\structural A = { f: (n: number) => number };
        \\function run(x: A | string): number { return x.f(2); }
    , union_call_message, union_call_help);
}

test "member access: a union member that lacks a read member makes the read optional" {
    try expectOneMismatch(
        \\structural P = { age: number };
        \\structural Nope = { zz: Bytes };
        \\function f(x: P | string): number { const a: Nope = x.age; return 0; }
    , "type 'number | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "member access: string members, length, array methods, and tuple length report nothing" {
    try expectNoTypeDiagnostic(
        \\function f(s: string, xs: number[], t: [number, string], g: (n: number) => number): number {
        \\  const a = s.toUpperCase();
        \\  const b = s.length;
        \\  const c = xs.map(g);
        \\  const d = xs.length;
        \\  const e = t.length;
        \\  return 0;
        \\}
    );
}

test "member access: a record field that holds a function is still callable" {
    try expectNoTypeDiagnostic(
        \\structural A = { f: (n: number) => number };
        \\function run(r: A): number { return r.f(2); }
    );
}

test "member access: a builtin constant reports nothing" {
    try expectNoTypeDiagnostic(
        \\function f(): number { return Math.PI; }
    );
}

// K1a: the types of the `zttp:collections` calls that read a Dict, and a Dict
// that a typed annotation reaches. Each form is assigned to
// `structural Nope = { zz: Bytes };` so that the message prints its type.

test "dict types: dictEmpty is a Dict with no key and no value" {
    try expectOneMismatch(
        \\import { dictEmpty } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictEmpty(); return 0; }
    , "type 'Dict<never, never>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictSet on an empty Dict takes the widened key and value" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictSet(dictEmpty(), "a", 1); return 0; }
    , "type 'Dict<string, number>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictSet with a second value type joins the value types" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictSet(dictSet(dictEmpty(), "a", 1), "b", "two"); return 0; }
    , "type 'Dict<string, number | string>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictSet with a number key after a string key joins the key types" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictSet(dictSet(dictEmpty(), "a", 1), 2, 3); return 0; }
    , "type 'Dict<string | number, number>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictGet reads the value type or undefined" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictGet(dictSet(dictSet(dictEmpty(), "a", 1), "b", "two"), "a"); return 0; }
    , "type 'number | string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictGet on an empty Dict is undefined" {
    try expectOneMismatch(
        \\import { dictEmpty, dictGet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictGet(dictEmpty(), "x"); return 0; }
    , "type 'undefined' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictHas is boolean" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet, dictHas } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictHas(dictSet(dictEmpty(), "a", 1), "a"); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictRemove keeps the Dict type" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet, dictRemove } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictRemove(dictSet(dictEmpty(), "a", 1), "a"); return 0; }
    , "type 'Dict<string, number>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: dictEntries is an array of key and value pairs" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet, dictEntries } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = dictEntries(dictSet(dictEmpty(), "a", 1)); return 0; }
    , "type '[string, number][]' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: a Dict from isDict keeps dictGet unknown" {
    try expectOneMismatch(
        \\import { dictGet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(u: unknown): number { if (isDict(u)) { const p: Nope = dictGet(u, "a"); } return 0; }
    , "type 'unknown' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: a Dict built by dictSet reaches a typed annotation" {
    try expectNoTypeDiagnostic(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\function f(): number { const d: Dict<string, number> = dictSet(dictEmpty(), "a", 1); return 0; }
    );
}

test "dict types: an empty Dict reaches any typed annotation" {
    try expectNoTypeDiagnostic(
        \\import { dictEmpty } from "zttp:collections";
        \\function f(): number { const d: Dict<string, number> = dictEmpty(); return 0; }
    );
}

test "dict types: a Dict of number keys does not reach a Dict of string keys" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\function f(): number { const d: Dict<string, number> = dictSet(dictEmpty(), 2, 1); return 0; }
    , "type 'Dict<number, number>' is not assignable to type 'Dict<string, number>'");
}

test "dict types: dictGet accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictGet } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictGet(d, "a"); return 0; }
    );
}

test "dict types: dictHas accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictHas } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictHas(d, "a"); return 0; }
    );
}

test "dict types: dictSet accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictSet } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictSet(d, "a", 1); return 0; }
    );
}

test "dict types: dictRemove accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictRemove } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictRemove(d, "a"); return 0; }
    );
}

test "dict types: dictEntries accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictEntries } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictEntries(d); return 0; }
    );
}

test "dict types: dictMapValues accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictMapValues } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictMapValues(d, (x, k) => x); return 0; }
    );
}

test "dict types: dictFilter accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictFilter } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictFilter(d, (x, k) => true); return 0; }
    );
}

test "dict types: dictFold accepts a Dict of string keys" {
    try expectNoTypeDiagnostic(
        \\import { dictFold } from "zttp:collections";
        \\function f(d: Dict<string, number>): number { const v = dictFold(d, (acc, x, k) => acc, 0); return 0; }
    );
}

test "dict types: an unannotated let of an empty Dict takes a Dict with entries" {
    try expectNoTypeDiagnostic(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\function f(): number { let d = dictEmpty(); d = dictSet(d, "a", 1); return 0; }
    );
}

test "dict types: an unannotated let of an empty Dict takes a loop accumulator" {
    try expectNoTypeDiagnostic(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\function f(): number { let d = dictEmpty(); for (const k of ["a", "b"]) { d = dictSet(d, k, 1); } return 0; }
    );
}

test "dict types: a let of a Dict with entries keeps its type as a let of an array does" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet } from "zttp:collections";
        \\function f(): number { let d = dictSet(dictEmpty(), "a", 1); d = dictSet(d, "b", "x"); return 0; }
    , "type 'Dict<string, number | string>' is not assignable to type 'Dict<string, number>'");
}

test "dict types: a const of an empty Dict keeps the empty Dict type" {
    try expectOneMismatch(
        \\import { dictEmpty } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const d = dictEmpty(); const p: Nope = d; return 0; }
    , "type 'Dict<never, never>' is not assignable to type '{ zz: Bytes }'");
}

test "dict types: a union of two Dict types keeps the declared dictGet type" {
    try expectOneMismatch(
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\structural Nope = { zz: Bytes };
        \\function f(c: boolean): number {
        \\  const d = c ? dictSet(dictEmpty(), "a", 1) : dictSet(dictEmpty(), "a", "x");
        \\  const p: Nope = dictGet(d, "a");
        \\  return 0;
        \\}
    , "type 'unknown' is not assignable to type '{ zz: Bytes }'");
}

// K1b: the callbacks of `dictFold`, `dictMapValues`, and `dictFilter` over a
// typed Dict. The runtime passes `(accumulator, value, key)` to the fold and
// `(value, key)` to the other two.

const dict_callback_setup =
    \\import { dictEmpty, dictSet, dictFold, dictMapValues, dictFilter } from "zttp:collections";
    \\structural Nope = { zz: Bytes };
    \\
;

test "dict callbacks: dictFold with a seeded accumulator is that type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { const p: Nope = dictFold(d, (acc, value, key) => acc + value, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: the fold target returns a number" {
    try expectNoTypeDiagnostic(dict_callback_setup ++
        \\function f(): number {
        \\  const d = dictSet(dictSet(dictEmpty(), "a", 1), "b", 2);
        \\  return dictFold(d, (acc, value, key) => acc + value, 0);
        \\}
    );
}

test "dict callbacks: dictFold binds the value parameter to the value type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc, value, key) => { const p: Nope = value; return acc; }, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictFold binds the key parameter to the key type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc, value, key) => { const p: Nope = key; return acc; }, 0); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictFold binds the accumulator to the widened seed" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc, value, key) => { const p: Nope = acc; return acc; }, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: a fold callback that returns another type leaves the result unknown" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { const p: Nope = dictFold(d, (acc, value, key) => String(value), 0); return 0; }
    , "type 'unknown' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: an annotated fold parameter that refuses the value is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc: number, v: string, k: string): number => acc, 0); return 0; }
    , "callback parameter 'v' is 'string', but dictFold passes 'number'");
}

test "dict callbacks: an annotated fold parameter that refuses the key is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc: number, v: number, k: number): number => acc, 0); return 0; }
    , "callback parameter 'k' is 'number', but dictFold passes 'string'");
}

test "dict callbacks: an annotated fold accumulator that refuses the seed is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc: string, v: number, k: string): string => acc, 0); return 0; }
    , "callback parameter 'acc' is 'string', but dictFold passes 'number'");
}

test "dict callbacks: an annotated fold accumulator that refuses the callback result is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (acc: number, v: number, k: string) => String(v), 0); return 0; }
    , "callback parameter 'acc' is 'number', but dictFold passes 'string'");
}

test "dict callbacks: a named fold callback that accepts what the runtime passes is clean" {
    try expectNoTypeDiagnostic(dict_callback_setup ++
        \\function g(acc: number, v: number, k: string): number { return acc + v; }
        \\function f(d: Dict<string, number>): number { return dictFold(d, g, 0); }
    );
}

test "dict callbacks: a named fold callback that refuses the value is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function g(acc: number, v: string, k: string): number { return acc; }
        \\function f(d: Dict<string, number>): number { dictFold(d, g, 0); return 0; }
    , "callback parameter '#2' is 'string', but dictFold passes 'number'");
}

test "dict callbacks: a fold callback that requires four parameters is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFold(d, (a: number, v: number, k: string, e: number): number => a, 0); return 0; }
    , "callback parameter 'e' is 'number', but dictFold passes 'undefined'");
}

test "dict callbacks: dictMapValues is a Dict of the callback result" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { const p: Nope = dictMapValues(d, (v, k) => String(v)); return 0; }
    , "type 'Dict<string, string>' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictMapValues binds the key parameter to the key type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictMapValues(d, (v, k) => { const p: Nope = k; return v; }); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: an annotated dictMapValues parameter that refuses the value is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictMapValues(d, (v: string, k: string) => v); return 0; }
    , "callback parameter 'v' is 'string', but dictMapValues passes 'number'");
}

test "dict callbacks: dictMapValues over an empty Dict is the empty Dict" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(): number { const p: Nope = dictMapValues(dictEmpty(), (v, k) => 1); return 0; }
    , "type 'Dict<never, never>' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictFold over an empty Dict is the widened seed" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(): number { const p: Nope = dictFold(dictEmpty(), (acc, value, key) => acc + value, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictFilter keeps the Dict type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { const p: Nope = dictFilter(d, (v, k) => v > 1); return 0; }
    , "type 'Dict<string, number>' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: dictFilter binds the value parameter to the value type" {
    try expectOneMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFilter(d, (v, k) => { const p: Nope = v; return true; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "dict callbacks: a dictFilter callback that returns a number is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFilter(d, (v, k) => v); return 0; }
    , "argument type does not match parameter type: expected () => boolean, got () => number");
}

test "dict callbacks: an annotated dictFilter parameter that refuses the value is ZTS203" {
    try expectOneArgMismatch(dict_callback_setup ++
        \\function f(d: Dict<string, number>): number { dictFilter(d, (v: string, k: string) => true); return 0; }
    , "callback parameter 'v' is 'string', but dictFilter passes 'number'");
}

test "dict callbacks: a named dictFilter callback that accepts what the runtime passes is clean" {
    try expectNoTypeDiagnostic(dict_callback_setup ++
        \\function big(v: number, k: string): boolean { return v > 1; }
        \\function f(d: Dict<string, number>): number { dictFilter(d, big); return 0; }
    );
}

test "dict callbacks: arithmetic on the value of a Dict from isDict is refused" {
    try expectArithCounts(dict_callback_setup ++
        \\function f(u: unknown): number { if (isDict(u)) { dictFold(u, (acc, value, key) => acc + value, 0); } return 0; }
    , 0, 2);
}

test "dict callbacks: a callback over a union of Dict types keeps today's behavior" {
    try expectNoTypeDiagnostic(dict_callback_setup ++
        \\function f(c: boolean): number {
        \\  const d = c ? dictSet(dictEmpty(), "a", 1) : dictSet(dictEmpty(), "a", "x");
        \\  dictFold(d, (acc, value, key) => acc, 0);
        \\  return 0;
        \\}
    );
}

test "builtin result: an array method on a receiver that may be undefined stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[] | undefined): number { const p: Nope = xs.pop(); return 0; }
    );
}

test "builtin result: an array method through an optional chain stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs?.pop(); return 0; }
    );
}

test "builtin result: pop on an array literal widens the element type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = [1, 2].pop(); return 0; }
    , "type 'number | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: pop on an empty array literal stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = [].pop(); return 0; }
    );
}

test "builtin result: JSON.stringify of a number array is string" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = JSON.stringify(xs); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: JSON.stringify of a recursive type may be undefined" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural Tree = { kids: Tree[] };
        \\function f(t: Tree): number { const p: Nope = JSON.stringify(t); return 0; }
    , "type 'string | undefined' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: JSON.stringify of an unknown value stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(u: unknown): number { const p: Nope = JSON.stringify(u); return 0; }
    );
}

test "builtin result: JSON.stringify of a function stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(cb: (n: number) => number): number { const p: Nope = JSON.stringify(cb); return 0; }
    );
}

test "builtin result: JSON.stringify with no argument stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = JSON.stringify(); return 0; }
    );
}

test "builtin result: JSON.parse is unknown" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = JSON.parse(s); return 0; }
    , "type 'unknown' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: JSON.tryParse is a Result with an unknown value" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = JSON.tryParse(s); return 0; }
    , "type '{ ok: boolean; value?: unknown; error?: string; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result error type: the error of err(5) is not a string at a string parameter" {
    try expectOneArgMismatch(
        \\import { err } from "zttp:result";
        \\function shout(s: string): string {
        \\  return s.toUpperCase();
        \\}
        \\function f(): number {
        \\  const r = err(5);
        \\  if (!r.ok) {
        \\    const e = r.error;
        \\    if (e !== undefined) {
        \\      const t = shout(e);
        \\    }
        \\  }
        \\  return 0;
        \\}
    , "argument type does not match parameter type: expected string, got number");
}

test "result error type: the error of jwtVerify is a string at a string parameter" {
    try expectNoTypeDiagnostic(
        \\import { jwtVerify } from "zttp:auth";
        \\function shout(s: string): string {
        \\  return s.toUpperCase();
        \\}
        \\function f(token: string): number {
        \\  const r = jwtVerify(token, "secret");
        \\  if (!r.ok) {
        \\    const e = r.error;
        \\    if (e !== undefined) {
        \\      const t = shout(e);
        \\    }
        \\  }
        \\  return 0;
        \\}
    );
}

test "result error type: the error of parseJson is not a string" {
    try expectOneMismatch(
        \\import { parseJson } from "zttp:json";
        \\function f(text: string): number {
        \\  const s: string = parseJson(text).error;
        \\  return 0;
        \\}
    , "type 'unknown' is not assignable to type 'string'");
}

test "result error type: a Result with an unknown error is accepted as a Result argument" {
    try expectNoTypeDiagnostic(
        \\import { err, mapResult } from "zttp:result";
        \\function f(): number {
        \\  const r = mapResult(err(5), (v) => v);
        \\  return 0;
        \\}
    );
}

test "result shape: a record literal is not a Result at mapResult" {
    try expectOneArgMismatch(
        \\import { mapResult } from "zttp:result";
        \\function f(): number {
        \\  const r = mapResult({ ok: true, value: 21 }, (n: number) => String(n));
        \\  return 0;
        \\}
    , "mapResult argument 1 must be a Result, got '{ ok: true; value: 21 }'");
}

test "result shape: collectAll of non-Results is ZTS203" {
    try expectOneArgMismatch(
        \\import { collectAll } from "zttp:result";
        \\function f(): number {
        \\  const r = collectAll([1, 2]);
        \\  return 0;
        \\}
    , "collectAll argument 1 must be an array of Results, got '[1, 2]'");
}

test "result shape: an andThen callback that returns a number is ZTS203" {
    try expectOneArgMismatch(
        \\import { andThen, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = andThen(ok(1), (n) => 5);
        \\  return 0;
        \\}
    , "andThen callback must return a Result, got '5'");
}

test "result shape: a named andThen callback that adds to its parameter is ZTS203" {
    try expectOneArgMismatch(
        \\import { andThen, ok } from "zttp:result";
        \\function inc(n: number): number { return n + 1; }
        \\function f(): number {
        \\  const r = andThen(ok(1), inc);
        \\  return 0;
        \\}
    , "andThen callback must return a Result, got 'number'");
}

test "result shape: a named orElse callback that returns a string is ZTS203" {
    try expectOneArgMismatch(
        \\import { err, orElse } from "zttp:result";
        \\function recover(e: unknown): string { return "x"; }
        \\function f(): number {
        \\  const r = orElse(err("x"), recover);
        \\  return 0;
        \\}
    , "orElse callback must return a Result, got 'string'");
}

test "result shape: a number is not a Result at unwrapOr" {
    try expectOneArgMismatch(
        \\import { unwrapOr } from "zttp:result";
        \\function f(): number {
        \\  const r = unwrapOr(5, 0);
        \\  return 0;
        \\}
    , "unwrapOr argument 1 must be a Result, got '5'");
}

test "result shape: collectAll of Results has no diagnostic" {
    try expectNoTypeDiagnostic(
        \\import { collectAll, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = collectAll([ok(1), ok(2)]);
        \\  return 0;
        \\}
    );
}

test "result shape: collectAll of mixed ok and err has no diagnostic" {
    try expectNoTypeDiagnostic(
        \\import { collectAll, err, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = collectAll([ok(1), err("first"), err("second")]);
        \\  return 0;
        \\}
    );
}

test "result shape: collectAll of an empty array has no diagnostic" {
    try expectNoTypeDiagnostic(
        \\import { collectAll } from "zttp:result";
        \\function f(): number {
        \\  const r = collectAll([]);
        \\  return 0;
        \\}
    );
}

test "result shape: an andThen callback that returns a Result has no diagnostic" {
    try expectNoTypeDiagnostic(
        \\import { andThen, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = andThen(ok(1), (n) => ok(2));
        \\  return 0;
        \\}
    );
}

test "result shape: a Result from a module export is accepted at mapResult" {
    try expectNoTypeDiagnostic(
        \\import { mapResult } from "zttp:result";
        \\import { parseJson } from "zttp:json";
        \\function f(text: string): number {
        \\  const r = mapResult(parseJson(text), (v) => v);
        \\  return 0;
        \\}
    );
}

test "result type: ok(21) carries the number value and a never error" {
    try expectOneMismatch(
        \\import { ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = ok(21); return 0; }
    , "type '{ ok: boolean; value?: number; error?: never; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result type: err(\"x\") carries the string error and a never value" {
    try expectOneMismatch(
        \\import { err } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = err("x"); return 0; }
    , "type '{ ok: boolean; value?: never; error?: string; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result type: unwrapOr of ok(21) and 0 is number" {
    try expectOneMismatch(
        \\import { ok, unwrapOr } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = unwrapOr(ok(21), 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "result type: unwrapOr of err(\"x\") and -1 is number" {
    try expectOneMismatch(
        \\import { err, unwrapOr } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = unwrapOr(err("x"), -1); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "result type: unwrapOr of ok(21) and a string is a union" {
    try expectOneMismatch(
        \\import { ok, unwrapOr } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = unwrapOr(ok(21), "none"); return 0; }
    , "type 'number | string' is not assignable to type '{ zz: Bytes }'");
}

test "result type: a ternary of ok and err is one Result record" {
    try expectOneMismatch(
        \\import { err, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(flag: boolean): number {
        \\  const r = flag ? ok(1) : err("x");
        \\  const p: Nope = r;
        \\  return 0;
        \\}
    , "type '{ ok: boolean; value?: number; error?: string; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result type: the value of a joined Result reads as number after the ok guard" {
    try expectOneMismatch(
        \\import { err, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(flag: boolean): number {
        \\  const r = flag ? ok(1) : err("x");
        \\  if (r.ok) {
        \\    const p: Nope = r.value;
        \\  }
        \\  return 0;
        \\}
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "result type: a local function named ok keeps its own type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function ok(x: number): string { return "x"; }
        \\function f(): number { const p: Nope = ok(21); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: an andThen callback that adds to its parameter is ZTS203" {
    try expectOneArgMismatch(
        \\import { andThen, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = andThen(ok(1), (n) => n + 1);
        \\  return 0;
        \\}
    , "andThen callback must return a Result, got 'number'");
}

test "result combinator: an annotated andThen callback that adds to its parameter is ZTS203" {
    try expectOneArgMismatch(
        \\import { andThen, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = andThen(ok(1), (n: number) => n + 1);
        \\  return 0;
        \\}
    , "andThen callback must return a Result, got 'number'");
}

test "result combinator: a reduce callback that returns the element under a string accumulator is ZTS203" {
    try expectOneArgMismatch(
        \\function f(): number { [1, 2].reduce((acc: string, n: number) => n, ""); return 0; }
    , "callback parameter 'acc' is 'string', but reduce passes 'number'");
}

test "result combinator: mapResult of ok(21) and a doubling callback is a number Result" {
    try expectOneMismatch(
        \\import { mapResult, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = mapResult(ok(21), (n) => n * 2); return 0; }
    , "type '{ ok: boolean; value?: number; error?: never; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: a mapResult callback parameter takes the value type" {
    try expectOneMismatch(
        \\import { mapResult, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = mapResult(ok(21), (n) => { const s: string = n; return s; });
        \\  return 0;
        \\}
    , "type 'number' is not assignable to type 'string'");
}

test "result combinator: an annotated mapResult callback that refuses the value is ZTS203" {
    try expectOneArgMismatch(
        \\import { mapResult, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = mapResult(ok(21), (s: string) => s);
        \\  return 0;
        \\}
    , "callback parameter 's' is 'string', but mapResult passes 'number'");
}

test "result combinator: a named mapResult callback that refuses the value is ZTS203" {
    try expectOneArgMismatch(
        \\import { mapResult, ok } from "zttp:result";
        \\function up(s: string): string { return s; }
        \\function f(): number {
        \\  const r = mapResult(ok(21), up);
        \\  return 0;
        \\}
    , "callback parameter '#1' is 'string', but mapResult passes 'number'");
}

test "result combinator: an annotated mapResult callback that accepts the value has no diagnostic" {
    try expectNoTypeDiagnostic(
        \\import { mapResult, ok } from "zttp:result";
        \\function f(): number {
        \\  const r = mapResult(ok(21), (n: number) => String(n));
        \\  return 0;
        \\}
    );
}

test "result combinator: mapError of err(\"boom\") and a join callback has a string error" {
    try expectOneMismatch(
        \\import { err, mapError } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = mapError(err("boom"), (e) => [e, "!"].join("")); return 0; }
    , "type '{ ok: boolean; value?: never; error?: string; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: andThen of ok(1) and a string Result is a string Result with a never error" {
    try expectOneMismatch(
        \\import { andThen, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = andThen(ok(1), (n) => ok(String(n))); return 0; }
    , "type '{ ok: boolean; value?: string; error?: never; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: orElse of err(\"x\") and ok(0) is a number Result with a never error" {
    try expectOneMismatch(
        \\import { err, ok, orElse } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = orElse(err("x"), (e) => ok(0)); return 0; }
    , "type '{ ok: boolean; value?: number; error?: never; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: collectAll of an ok and an err is a number array Result with a string error" {
    try expectOneMismatch(
        \\import { collectAll, err, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = collectAll([ok(1), err("e")]); return 0; }
    , "type '{ ok: boolean; value?: number[]; error?: string; errors?: never }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: collectAll of an empty array keeps the table record" {
    try expectOneMismatch(
        \\import { collectAll } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = collectAll([]); return 0; }
    , "type '{ ok: boolean; value?: unknown; error?: unknown; errors?: unknown }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: an andThen callback parameter takes the number value of a mapResult chain" {
    try expectOneMismatch(
        \\import { andThen, mapResult, ok } from "zttp:result";
        \\structural Nope = { zz: Bytes };
        \\function f(): number {
        \\  const doubled = mapResult(ok(21), (n) => n * 2);
        \\  const chained = andThen(doubled, (m) => { const q: Nope = m; return ok(m + 1); });
        \\  return 0;
        \\}
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: an annotated mapError callback is not refused when the payload may sit under errors" {
    try expectNoTypeDiagnostic(
        \\import { err, mapError } from "zttp:result";
        \\function f(): number {
        \\  const r = mapError(err("boom"), (e: string) => e);
        \\  return 0;
        \\}
    );
}

test "result errors: a validateJson error read after the failure guard may be undefined" {
    try expectOneArgMismatch(
        \\import { validateJson } from "zttp:validate";
        \\function shout(s: string): string {
        \\  return s.toUpperCase();
        \\}
        \\function f(text: string): number {
        \\  const r = validateJson("user", text);
        \\  if (!r.ok) {
        \\    const t = shout(r.error);
        \\  }
        \\  return 0;
        \\}
    , "argument type does not match parameter type: expected string, got string | undefined");
}

test "result errors: a jwtVerify error read after the failure guard is a string" {
    try expectNoTypeDiagnostic(
        \\import { jwtVerify } from "zttp:auth";
        \\function shout(s: string): string {
        \\  return s.toUpperCase();
        \\}
        \\function f(token: string): number {
        \\  const r = jwtVerify(token, "secret");
        \\  if (!r.ok) {
        \\    const t = shout(r.error);
        \\  }
        \\  return 0;
        \\}
    );
}

test "result errors: a validateJson error with a nullish fallback is a string" {
    try expectNoTypeDiagnostic(
        \\import { validateJson } from "zttp:validate";
        \\function f(text: string): number {
        \\  const r = validateJson("user", text);
        \\  const reason = r.error ?? "none";
        \\  const s: string = reason;
        \\  return 0;
        \\}
    );
}

test "result errors: a validateJson Result declares unknown errors and an error that may be undefined" {
    try expectOneMismatch(
        \\import { validateJson } from "zttp:validate";
        \\structural Nope = { zz: Bytes };
        \\function f(text: string): number { const p: Nope = validateJson("user", text); return 0; }
    , "type '{ ok: boolean; value?: unknown; error?: string | undefined; errors?: unknown }' is not assignable to type '{ zz: Bytes }'");
}

test "result combinator: a mapResult callback annotated number refuses a JSON value" {
    try expectOneArgMismatch(
        \\import { mapResult } from "zttp:result";
        \\import { parseJson } from "zttp:json";
        \\function f(text: string): number {
        \\  const r = mapResult(parseJson(text), (n: number) => n + 1);
        \\  return 0;
        \\}
    , "callback parameter 'n' is 'number', but mapResult passes 'unknown'");
}

test "builtin result: Object.keys of a record is a string array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural O = { a: number };
        \\function f(o: O): number { const p: Nope = Object.keys(o); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Object.keys of a string stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = Object.keys(s); return 0; }
    );
}

test "builtin result: Object.hasOwn is boolean" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural O = { a: number };
        \\function f(o: O): number { const p: Nope = Object.hasOwn(o, "a"); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Object.values of a record is an unknown array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural O = { a: number };
        \\function f(o: O): number { const p: Nope = Object.values(o); return 0; }
    , "type 'unknown[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Object.entries of a record is an array of string and unknown pairs" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural O = { a: number };
        \\function f(o: O): number { const p: Nope = Object.entries(o); return 0; }
    , "type '[string, unknown][]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Object.values of an object literal is not a number array" {
    try expectOneMismatch(
        \\function f(): number { const vs: number[] = Object.values({ a: 1, b: 2 }); return 0; }
    , "type 'unknown[]' is not assignable to type 'number[]'");
}

test "builtin result: Object.values and Object.entries of a string stay untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = Object.values(s); const q: Nope = Object.entries(s); return 0; }
    );
}

test "builtin result: Array.isArray is boolean" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = Array.isArray(xs); return 0; }
    , "type 'boolean' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Array.of of numbers is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Array.of(1, 2); return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Array.of with an argument that has no type stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(n: number | undefined): number { const p: Nope = Array.of(1, Math.floor(n)); return 0; }
    );
}

test "builtin result: Array.of with no argument stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const p: Nope = Array.of(); return 0; }
    );
}

test "builtin result: Array.from of a string is a string array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string): number { const p: Nope = Array.from(s); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Array.from of an array is the same array type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = Array.from(xs); return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: Array.from with a map function stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(s: string, cb: (c: string) => number): number { const p: Nope = Array.from(s, cb); return 0; }
    );
}

test "builtin result: a parameter named JSON keeps its own type" {
    try expectOneMismatch(
        \\structural J = { parse: (s: string) => number };
        \\structural Nope = { zz: Bytes };
        \\function f(JSON: J): number { const p: Nope = JSON.parse("1"); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: a parameter named Array keeps its own type" {
    try expectOneMismatch(
        \\structural A = { isArray: (x: number) => string };
        \\structural Nope = { zz: Bytes };
        \\function f(Array: A): number { const p: Nope = Array.isArray(1); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "builtin result: concat of a number array and a string array is assignable to the array of the union" {
    try expectNoTypeDiagnostic(
        \\function f(xs: number[], ys: string[]): number { const p: (number | string)[] = xs.concat(ys); return 0; }
    );
}

test "callback parameter: the index of a map callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { xs.map((v, i) => { const p: Nope = i; return v; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the array of a map callback is the receiver array type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.map((v, i, a) => { const p: Nope = a; return v; }); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a filter callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.filter((v, i) => { const p: Nope = i; return true; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a forEach callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.forEach((v, i) => { const p: Nope = i; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a find callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.find((v, i) => { const p: Nope = i; return true; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a findIndex callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.findIndex((v, i) => { const p: Nope = i; return true; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a some callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.some((v, i) => { const p: Nope = i; return true; }); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the array of an every callback is the receiver array type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.every((v, i, a) => { const p: Nope = a; return true; }); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: both parameters of a toSorted comparator are the element type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.toSorted((a, b) => { const p: Nope = a; return 0; }); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.toSorted((a, b) => { const p: Nope = b; return 0; }); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: reduce with an initial value is typed by the widened initial value" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { const p: Nope = xs.reduce((acc, v) => acc + v, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: reduce that sums into a number is accepted" {
    try expectNoTypeDiagnostic(
        \\function f(xs: number[]): number { const total: number = xs.reduce((acc, v) => acc + v, 0); return total; }
    );
}

test "callback parameter: the accumulator of a reduce callback is the widened initial value type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.reduce((acc, v) => { const p: Nope = acc; return acc; }, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the accumulator of a reduce with no initial value is the element type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.reduce((acc, v) => { const p: Nope = acc; return v; }); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the element of a reduce callback is the element type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.reduce((acc, v) => { const p: Nope = v; return acc; }, 0); return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the index of a reduce callback is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.reduce((acc, v, i) => { const p: Nope = i; return acc; }, 0); return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: the array of a reduce callback is the receiver array type" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: string[]): number { xs.reduce((acc, v, i, a) => { const p: Nope = a; return acc; }, 0); return 0; }
    , "type 'string[]' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: a reduce callback that returns a different type than its accumulator is refused" {
    try expectOneMismatch(
        \\function f(xs: number[]): number { xs.reduce((acc, v) => String(v), 0); return 0; }
    , "reduce callback returns 'string', but its accumulator is 'number'");
}

test "callback parameter: a reduce callback with an annotated accumulator is not refused for its return" {
    try expectNoTypeDiagnostic(
        \\function f(xs: number[]): number { xs.reduce((acc: number | string, v) => String(v), 0); return 0; }
    );
}

test "callback parameter: a reduce callback whose return has no type leaves the accumulator untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[], g: unknown): number { xs.reduce((acc, v) => { const p: Nope = acc; return g; }, 0); return 0; }
    );
}

test "callback parameter: the element of for...of over range is number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { for (const i of range(3)) { const p: Nope = i; } return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: a parameter named range keeps its own type in for...of" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(range: (n: number) => string[]): number { for (const s of range(3)) { const p: Nope = s; } return 0; }
    , "type 'string' is not assignable to type '{ zz: Bytes }'");
}

test "for...of over a tuple of numbers binds the variable to number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { for (const n of [1, 2, 3]) { const p: Nope = n; } return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "for...of over a mixed tuple binds the union of the widened element types" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { for (const s of ["a", 1]) { const p: Nope = s; } return 0; }
    , "type 'string | number' is not assignable to type '{ zz: Bytes }'");
}

test "for...of over a union of an array and a tuple binds the union of the element types" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(u: number[] | [string, string]): number { for (const v of u) { const p: Nope = v; } return 0; }
    , "type 'number | string' is not assignable to type '{ zz: Bytes }'");
}

test "for...of nested over an array of mixed rows binds the inner variable to number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { for (const row of [[1, 2], [3]]) { for (const m of row) { const p: Nope = m; } } return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "for...of over a tuple keeps the published let accumulation clean" {
    try expectNoTypeDiagnostic(
        \\function f(): number { let total = 0; for (const n of [1, 2, 3]) { total = total + n; } return total; }
    );
}

test "for...of over a tuple of numbers refuses a string method on the variable" {
    try expectOneMissingField(
        \\function f(): number { let out = ""; for (const s of [1, 2]) { out = s.toUpperCase(); } return 0; }
    , non_record_member_message, non_record_member_help);
}

test "for...of over a union with a member that is not an array or tuple leaves the variable untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(u: number[] | string): number { for (const v of u) { const p: Nope = v; } return 0; }
    );
}

test "array literal binding: a const of numbers is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const ys = [4, 5]; const p: Nope = ys; return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: a let of numbers is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { let ys = [4, 4]; const p: Nope = ys; return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: a const of mixed elements is a tuple of the widened types" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const t = ["a", 1]; const p: Nope = t; return 0; }
    , "type '[string, number]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: an empty literal is an unknown array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const out = []; const p: Nope = out; return 0; }
    , "type 'unknown[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: a literal longer than the inference buffer is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const ys = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34]; const p: Nope = ys; return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: an incompatible first element in a wide annotated array is rejected" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const ys: number[] = [
        \\    "bad", 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0,
        \\  ];
        \\  return ys.length;
        \\}
    , "type '\"bad\" | 0[]' is not assignable to type 'number[]'");
}

test "array literal binding: an incompatible element after the inference buffer is rejected" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const ys: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    "bad",
        \\  ];
        \\  return ys.length;
        \\}
    , "type '0 | \"bad\"[]' is not assignable to type 'number[]'");
}

test "array literal binding: a late empty array does not hide an incompatible prefix" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const ys: number[] = [
        \\    "bad", 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    [],
        \\  ];
        \\  return ys.length;
        \\}
    , "type '\"bad\" | 0 | never[][]' is not assignable to type 'number[]'");
}

test "array literal binding: a late empty object does not hide an incompatible prefix" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const ys: number[] = [
        \\    "bad", 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    {},
        \\  ];
        \\  return ys.length;
        \\}
    , "type '\"bad\" | 0 | {  }[]' is not assignable to type 'number[]'");
}

test "array literal binding: an empty array does not stop a later incompatible element" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const ys: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    [], "bad",
        \\  ];
        \\  return ys.length;
        \\}
    , "type '0 | never[] | \"bad\"[]' is not assignable to type 'number[]'");
}

test "array literal binding: a late spread does not hide an incompatible prefix" {
    try expectOneMismatch(
        \\function f(): number {
        \\  const tail: number[] = [1, 2];
        \\  const ys: number[] = [
        \\    "bad", 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    ...tail,
        \\  ];
        \\  return ys.length;
        \\}
    , "type '\"bad\" | number[]' is not assignable to type 'number[]'");
}

test "array literal binding: an unresolved element does not stop a later incompatible element" {
    try expectOneMismatch(
        \\function g(x) { return x; }
        \\function f(): number {
        \\  const ys: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    g(1), "bad",
        \\  ];
        \\  return ys.length;
        \\}
    , "type 'unknown[]' is not assignable to type 'number[]'");
}

test "array literal binding: a fixed tuple spread preserves tuple shape" {
    try expectNoTypeDiagnostic(
        \\function f(t: [number, boolean]): number {
        \\  const out: [string, number, boolean] = ["a", ...t];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: a wide fixed tuple spread preserves every position" {
    try expectNoTypeDiagnostic(
        \\function f(xs: [
        \\  number, number, number, number, number, number, number, number,
        \\  number, number, number, number, number, number, number, number,
        \\  number, number, number, number, number, number, number, number,
        \\  number, number, number, number, number, number, number, number,
        \\  boolean
        \\]): number {
        \\  const out: [
        \\    number, number, number, number, number, number, number, number,
        \\    number, number, number, number, number, number, number, number,
        \\    number, number, number, number, number, number, number, number,
        \\    number, number, number, number, number, number, number, number,
        \\    boolean
        \\  ] = [...xs];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: a fixed tuple union spread preserves prefix and suffix positions" {
    try expectNoTypeDiagnostic(
        \\function f(xs: [number, boolean] | [string, number]): number {
        \\  const out: [string, number | string, boolean | number, null] = ["prefix", ...xs, null];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: a fixed tuple union spread preserves correlated alternatives" {
    try expectNoTypeDiagnostic(
        \\function f(xs: [number, boolean] | [string, number]): number {
        \\  const out: [number, boolean] | [string, number] = [...xs];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: multiple fixed tuple union spreads preserve their product" {
    try expectNoTypeDiagnostic(
        \\function f(
        \\  left: [number, boolean] | [string, number],
        \\  right: ["x"] | ["y"],
        \\): number {
        \\  const out:
        \\    [number, boolean, "x"] |
        \\    [number, boolean, "y"] |
        \\    [string, number, "x"] |
        \\    [string, number, "y"] = [...left, ...right];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: duplicate fixed spread paths keep one alternative" {
    try expectNoTypeDiagnostic(
        \\function f(
        \\  a1: [0] | [0, 1], b1: [1, 2] | [2],
        \\  a2: [0] | [0, 1], b2: [1, 2] | [2],
        \\  a3: [0] | [0, 1], b3: [1, 2] | [2],
        \\  a4: [0] | [0, 1], b4: [1, 2] | [2],
        \\  a5: [0] | [0, 1], b5: [1, 2] | [2],
        \\  a6: [0] | [0, 1], b6: [1, 2] | [2],
        \\): number {
        \\  const out: unknown[] = [
        \\    ...a1, ...b1, ...a2, ...b2, ...a3, ...b3,
        \\    ...a4, ...b4, ...a5, ...b5, ...a6, ...b6,
        \\  ];
        \\  return out.length;
        \\}
    );
}

test "array literal binding: a fixed tuple union spread refuses an excluded alternative" {
    try expectOneMismatch(
        \\function f(xs: [number, boolean] | [string, number]): number {
        \\  const out: [number, boolean] = [...xs];
        \\  return out.length;
        \\}
    , "type '[number, boolean] | [string, number]' is not assignable to type '[number, boolean]'");
}

test "array literal binding: a variable array spread does not claim fixed tuple length" {
    try expectOneMismatch(
        \\function f(xs: number[]): number {
        \\  const out: [string, number, boolean] = ["a", ...xs];
        \\  return out.length;
        \\}
    , "type '\"a\" | number[]' is not assignable to type '[string, number, boolean]'");
}

test "array literal binding: empty containers, known spread, and unknown target remain accepted" {
    try expectNoTypeDiagnostic(
        \\structural Box = { value?: number };
        \\function f(): number {
        \\  const tail: number[] = [1, 2];
        \\  const literal_tail: ("a" | "b")[] = ["a", "b"];
        \\  const sequence_union: number[] | [number, number] = tail;
        \\  const nested_arrays: number[][] = [[], [1, 2]];
        \\  const nested_objects: Box[] = [{}, { value: 1 }];
        \\  const spread: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    ...tail,
        \\  ];
        \\  const literal_spread: ("a" | "b")[] = [...literal_tail];
        \\  const union_spread: number[] = [...sequence_union];
        \\  const unknowns: unknown[] = ["ok", {}, [], ...tail];
        \\  return nested_arrays.length + nested_objects.length + spread.length + literal_spread.length + union_spread.length + unknowns.length;
        \\}
    );
}

test "array literal binding: wide heterogeneous inference propagates allocation failure" {
    const allocator = testing.allocator;
    const source =
        \\function f(): number {
        \\  const spread_tail: [string, number] = ["bad", 0];
        \\  const union_tail: number[] | [number, number] = [1, 2];
        \\  const alternative_tail: [number, boolean] | [string, number] = [1, true];
        \\  const ys = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    "bad",
        \\  ];
        \\  const spread = [0, ...spread_tail];
        \\  const union_spread = [...union_tail];
        \\  const alternative_spread = ["prefix", ...alternative_tail, null];
        \\  return ys.length + spread.length + union_spread.length + alternative_spread.length;
        \\}
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        fn analyze(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(run_allocator, module, .{
                .source_types = .direct,
                .strict = false,
            });
            defer analysis.deinit();
            try analysis.complete();
        }
    };

    try testing.checkAllAllocationFailures(allocator, Run.analyze, .{parsed});
}

test "array literal binding: valid annotated arrays at and after the inference buffer are accepted" {
    try expectNoTypeDiagnostic(
        \\function f(): number {
        \\  const at_buffer: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\  ];
        \\  const after_buffer: number[] = [
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0, 0, 0, 0, 0, 0, 0, 0,
        \\    0,
        \\  ];
        \\  return at_buffer.length + after_buffer.length;
        \\}
    );
}

test "container mutation widens every member of a wide inferred numeric union" {
    try expectNoTypeDiagnostic(
        \\function f(n: number): number {
        \\  const box = { ys: [
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    16,
        \\  ] };
        \\  box.ys.push(n);
        \\  return box.ys.length;
        \\}
    );
}

test "container write widens every member of a wide inferred numeric union" {
    try expectNoTypeDiagnostic(
        \\function f(n: number): number {
        \\  const box = { ys: [
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    16,
        \\  ] };
        \\  box.ys[0] = n;
        \\  return box.ys.length;
        \\}
    );
}

test "container mutation refuses a string after widening a wide inferred numeric union" {
    try expectOneArgMismatch(
        \\function f(s: string): number {
        \\  const box = { ys: [
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    16,
        \\  ] };
        \\  box.ys.push(s);
        \\  return box.ys.length;
        \\}
    , "argument type does not match parameter type: expected number, got string");
}

test "container mutation keeps an explicit wide literal union strict" {
    try expectOneArgMismatch(
        \\function f(n: number): number {
        \\  const box: { ys: (0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16)[] } = { ys: [
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    16,
        \\  ] };
        \\  box.ys.push(n);
        \\  return box.ys.length;
        \\}
    , "argument type does not match parameter type: expected 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16, got number");
}

test "container mutation keeps inferred numeric widening at sixteen union members" {
    try expectNoTypeDiagnostic(
        \\function f(n: number): number {
        \\  const box = { ys: [
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    0, 1, 2, 3, 4, 5, 6, 7,
        \\    8, 9, 10, 11, 12, 13, 14, 15,
        \\    15,
        \\  ] };
        \\  box.ys.push(n);
        \\  return box.ys.length;
        \\}
    );
}

const wide_nested_record_union_mutation_source =
    \\structural Nested = { a: 0 } | { b: 0 };
    \\structural Item = {
    \\  kind: number;
    \\  nested: { a: number } | { b: number };
    \\  after: number;
    \\};
    \\function f(u: Nested, item: Item): number {
    \\  const box = { ys: [
    \\    { kind: 0, nested: u, after: 0 },
    \\    { kind: 1, nested: u, after: 1 },
    \\    { kind: 2, nested: u, after: 2 },
    \\    { kind: 3, nested: u, after: 3 },
    \\    { kind: 4, nested: u, after: 4 },
    \\    { kind: 5, nested: u, after: 5 },
    \\    { kind: 6, nested: u, after: 6 },
    \\    { kind: 7, nested: u, after: 7 },
    \\    { kind: 8, nested: u, after: 8 },
    \\    { kind: 9, nested: u, after: 9 },
    \\    { kind: 10, nested: u, after: 10 },
    \\    { kind: 11, nested: u, after: 11 },
    \\    { kind: 12, nested: u, after: 12 },
    \\    { kind: 13, nested: u, after: 13 },
    \\    { kind: 14, nested: u, after: 14 },
    \\    { kind: 15, nested: u, after: 15 },
    \\    { kind: 0, nested: u, after: 0 },
    \\    { kind: 1, nested: u, after: 1 },
    \\    { kind: 2, nested: u, after: 2 },
    \\    { kind: 3, nested: u, after: 3 },
    \\    { kind: 4, nested: u, after: 4 },
    \\    { kind: 5, nested: u, after: 5 },
    \\    { kind: 6, nested: u, after: 6 },
    \\    { kind: 7, nested: u, after: 7 },
    \\    { kind: 8, nested: u, after: 8 },
    \\    { kind: 9, nested: u, after: 9 },
    \\    { kind: 10, nested: u, after: 10 },
    \\    { kind: 11, nested: u, after: 11 },
    \\    { kind: 12, nested: u, after: 12 },
    \\    { kind: 13, nested: u, after: 13 },
    \\    { kind: 14, nested: u, after: 14 },
    \\    { kind: 15, nested: u, after: 15 },
    \\    { kind: 16, nested: u, after: 16 },
    \\  ] };
    \\  box.ys.push(item);
    \\  return box.ys.length;
    \\}
;

test "container mutation snapshots wide unions and record fields before recursive widening" {
    try expectNoTypeDiagnostic(wide_nested_record_union_mutation_source);
}

test "wide recursive write-slot widening propagates allocation failure" {
    const allocator = testing.allocator;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(
        allocator,
        allocator,
        wide_nested_record_union_mutation_source,
        .compile,
    );
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        fn analyze(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(run_allocator, module, .{
                .source_types = .direct,
                .strict = false,
            });
            defer analysis.deinit();
            try analysis.complete();
        }
    };

    try testing.checkAllAllocationFailures(allocator, Run.analyze, .{parsed});
}

const wide_container_record_prefix =
    \\structural A01 = { kind: "01"; v: number };
    \\structural A02 = { kind: "02"; v: number };
    \\structural A03 = { kind: "03"; v: number };
    \\structural A04 = { kind: "04"; v: number };
    \\structural A05 = { kind: "05"; v: number };
    \\structural A06 = { kind: "06"; v: number };
    \\structural A07 = { kind: "07"; v: number };
    \\structural A08 = { kind: "08"; v: number };
    \\structural A09 = { kind: "09"; v: number };
    \\structural A10 = { kind: "10"; v: number };
    \\structural A11 = { kind: "11"; v: number };
    \\structural A12 = { kind: "12"; v: number };
    \\structural A13 = { kind: "13"; v: number };
    \\structural A14 = { kind: "14"; v: number };
    \\structural A15 = { kind: "15"; v: number };
    \\structural A16 = { kind: "16"; v: number };
;

const wide_container_array_members =
    \\structural K01 = { kind: "01" };
    \\structural K02 = { kind: "02" };
    \\structural K03 = { kind: "03" };
    \\structural K04 = { kind: "04" };
    \\structural K05 = { kind: "05" };
    \\structural K06 = { kind: "06" };
    \\structural K07 = { kind: "07" };
    \\structural K08 = { kind: "08" };
    \\structural K09 = { kind: "09" };
    \\structural K10 = { kind: "10" };
    \\structural K11 = { kind: "11" };
    \\structural K12 = { kind: "12" };
    \\structural K13 = { kind: "13" };
    \\structural K14 = { kind: "14" };
    \\structural K15 = { kind: "15" };
    \\structural K16 = { kind: "16" };
    \\structural K17 = { kind: "17" };
;

test "container write checks the seventeenth record union member" {
    try expectOneMismatch(wide_container_record_prefix ++ "\n" ++
        \\structural A17 = { kind: "17"; v: string };
        \\structural U = A01 | A02 | A03 | A04 | A05 | A06 | A07 | A08 |
        \\  A09 | A10 | A11 | A12 | A13 | A14 | A15 | A16 | A17;
        \\function f(x: U, n: number): number { x.v = n; return 0; }
    , "type 'number' is not assignable to type 'string'");
}

test "container mutation checks the seventeenth array union member" {
    try expectOneArgMismatch(wide_container_array_members ++ "\n" ++
        \\structural U = (number | K01)[] | (number | K02)[] |
        \\  (number | K03)[] | (number | K04)[] | (number | K05)[] |
        \\  (number | K06)[] | (number | K07)[] | (number | K08)[] |
        \\  (number | K09)[] | (number | K10)[] | (number | K11)[] |
        \\  (number | K12)[] | (number | K13)[] | (number | K14)[] |
        \\  (number | K15)[] | (number | K16)[] | string[];
        \\function f(xs: U, n: number): number { xs.push(n); return 0; }
    , "argument type does not match parameter type: expected string, got number");
}

test "container write accepts every compatible member of a wide union" {
    try expectNoTypeDiagnostic(wide_container_record_prefix ++ "\n" ++
        \\structural A17 = { kind: "17"; v: number };
        \\structural U = A01 | A02 | A03 | A04 | A05 | A06 | A07 | A08 |
        \\  A09 | A10 | A11 | A12 | A13 | A14 | A15 | A16 | A17;
        \\function f(x: U, n: number): number { x.v = n; return 0; }
    );
}

test "wide container write propagates allocation failure" {
    const allocator = testing.allocator;
    const source = wide_container_record_prefix ++ "\n" ++
        \\structural A17 = { kind: "17"; v: number };
        \\structural U = A01 | A02 | A03 | A04 | A05 | A06 | A07 | A08 |
        \\  A09 | A10 | A11 | A12 | A13 | A14 | A15 | A16 | A17;
        \\function f(x: U, n: number): number { x.v = n; return 0; }
    ;
    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const parsed = ParsedModule.fromTypedExisting(view, root, &atoms, &parser.type_store);
    const Run = struct {
        fn analyze(run_allocator: std.mem.Allocator, module: ParsedModule) !void {
            var analysis: ModuleAnalysisSession = .{};
            try analysis.initSoundExtraction(run_allocator, module, .{
                .source_types = .direct,
                .strict = false,
            });
            defer analysis.deinit();
            try analysis.complete();
        }
    };

    try testing.checkAllAllocationFailures(allocator, Run.analyze, .{parsed});
}

test "container mutation gives a tuple priority after seventeen array union members" {
    try expectOneMismatch(wide_container_array_members ++ "\n" ++
        \\structural U = (number | K01)[] | (number | K02)[] |
        \\  (number | K03)[] | (number | K04)[] | (number | K05)[] |
        \\  (number | K06)[] | (number | K07)[] | (number | K08)[] |
        \\  (number | K09)[] | (number | K10)[] | (number | K11)[] |
        \\  (number | K12)[] | (number | K13)[] | (number | K14)[] |
        \\  (number | K15)[] | (number | K16)[] | (number | K17)[] | [string];
        \\function f(xs: U, n: number): number { xs.push(n); return 0; }
    , "this call changes the length of a tuple, and a tuple type names its length");
}

test "array literal binding: an inferred array of 400 distinct records is accepted" {
    try expectNoTypeDiagnostic(@embedFile("fixtures/typecheck/wide_record_array_400.ts"));
}

test "array literal binding: a module scope const of numbers is a number array" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\const ys = [4, 5];
        \\function f(): number { const p: Nope = ys; return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: a pushed empty literal passes the collect form" {
    try expectNoTypeDiagnostic(
        \\function f(): number { const items = [1, 2]; const out = []; for (const item of items) { out.push(item); } return out.length; }
    );
}

test "array literal binding: a let array takes another array of the same element type" {
    try expectNoTypeDiagnostic(
        \\function f(): number { let zs = [4, 5]; zs = [6, 7]; return zs.length; }
    );
}

test "array literal binding: a literal index read may be undefined" {
    try expectArithCounts(
        \\function f(): number { const ys = [4, 5]; return ys[0] + 1; }
    ,
        0,
        1,
    );
}

test "array literal binding: an annotated array keeps its annotation" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const ys: number[] = [4, 5]; const p: Nope = ys; return 0; }
    , "type 'number[]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: an annotated tuple keeps its annotation" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(): number { const t: [number, number] = [4, 5]; const p: Nope = t; return 0; }
    , "type '[number, number]' is not assignable to type '{ zz: Bytes }'");
}

test "array literal binding: an array literal passed as an argument keeps its literal type" {
    try expectOneArgMismatch(
        \\function g(xs: string[]): number { return xs.length; }
        \\function f(): number { return g([4, 5]); }
    , "argument type does not match parameter type: expected string[], got [4, 5]");
}

test "untyped builtin results: the length of Object.values is a number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\structural O = { a: number };
        \\function f(o: O): number { const p: Nope = Object.values(o).length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "untyped builtin results: arithmetic on the length of Object.values is clean" {
    try expectNoTypeDiagnostic(
        \\structural O = { a: number };
        \\function f(o: O): number { return Object.values(o).length - 1; }
    );
}

test "untyped builtin results: length of a union of a string and a string array is a number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(u: string | string[]): number { const p: Nope = u.length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "untyped builtin results: length of a union of a string and a tuple is a number" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(u: string | [number, number]): number { const p: Nope = u.length; return 0; }
    , "type 'number' is not assignable to type '{ zz: Bytes }'");
}

test "untyped builtin results: arithmetic on the length of a union of a string and a string array is clean" {
    try expectNoTypeDiagnostic(
        \\function f(u: string | string[]): number { return u.length - 1; }
    );
}

test "untyped builtin results: slice of a union of a string and a string array is the union of both results" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(u: string | string[]): number { const p: Nope = u.slice(1); return 0; }
    , "type 'string | string[]' is not assignable to type '{ zz: Bytes }'");
}

test "untyped builtin results: a method call on a union of arrays that depends on a callback stays untyped" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function f(u: number[] | string[]): number { const p: Nope = u.map((x) => x); return 0; }
    );
}

test "untyped builtin results: a method that one union member lacks refuses a call on the slice result" {
    try expectOneMissingField(
        \\function f(x: string | string[]): string { return x.slice(1).trim(); }
    , non_record_member_message, non_record_member_help);
}

test "untyped builtin results: a method that every union member has stays clean after the slice" {
    try expectNoTypeDiagnostic(
        \\function f(x: string | string[]): number { return x.slice(1).length; }
    );
}

test "callback parameter: an annotated index parameter keeps its annotation" {
    try expectOneMismatch(
        \\structural Nope = { zz: Bytes };
        \\function f(xs: number[]): number { xs.map((v: number, i: number | string) => { const p: Nope = i; return v; }); return 0; }
    , "type 'number | string' is not assignable to type '{ zz: Bytes }'");
}

test "callback parameter: a named function passed to map is unchanged" {
    try expectNoTypeDiagnostic(
        \\structural Nope = { zz: Bytes };
        \\function g(v, i) { const p: Nope = i; return v; }
        \\function f(xs: number[]): number { xs.map(g); return 0; }
    );
}

/// `source` must report exactly one ZTS203 (`arg_type_mismatch`) with `message`.
fn expectOneArgMismatch(source: []const u8, comptime message: []const u8) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.arg_type_mismatch, diagnostics[0].kind);
            try testing.expectEqualStrings(message, diagnostics[0].message);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "callback acceptance: an annotated map parameter that refuses the element is ZTS203" {
    try expectOneArgMismatch(
        \\function f(): number { [1, 2].map((s: string) => s.toUpperCase()); return 0; }
    , "callback parameter 's' is 'string', but map passes 'number'");
}

test "callback acceptance: a named map callback that refuses the element is ZTS203" {
    try expectOneArgMismatch(
        \\function up(s: string): string { return s.toUpperCase(); }
        \\function f(): number { [1, 2].map(up); return 0; }
    , "callback parameter '#1' is 'string', but map passes 'number'");
}

test "callback acceptance: an annotated filter parameter that refuses the element is ZTS203" {
    try expectOneArgMismatch(
        \\function f(): number { [1, 2].filter((s: string) => s === "a"); return 0; }
    , "callback parameter 's' is 'string', but filter passes 'number'");
}

test "callback acceptance: a named predicate whose parameter accepts the element is accepted" {
    try expectNoTypeDiagnostic(
        \\function big(n: number): boolean { return n > 1; }
        \\function f(): number { [1, 2].filter(big); return 0; }
    );
}

test "callback acceptance: a union receiver passes the union of the element types" {
    try expectOneArgMismatch(
        \\function f(xs: number[] | string[]): number { xs.map((s: string) => s); return 0; }
    , "callback parameter 's' is 'string', but map passes 'number | string'");
}

test "callback acceptance: an annotated index parameter that refuses number is ZTS203" {
    try expectOneArgMismatch(
        \\function f(xs: number[]): number { xs.map((v: number, i: string) => v); return 0; }
    , "callback parameter 'i' is 'string', but map passes 'number'");
}

test "callback acceptance: a forEach parameter past the passed values is ZTS203" {
    try expectOneArgMismatch(
        \\function f(xs: number[]): number { xs.forEach((v: number, i: number, a: number[], extra: number) => v); return 0; }
    , "callback parameter 'extra' is 'number', but forEach passes 'undefined'");
}

test "callback acceptance: a forEach parameter past the passed values that admits undefined is accepted" {
    try expectNoTypeDiagnostic(
        \\function f(xs: number[]): number { xs.forEach((v: number, i: number, a: number[], extra: number | undefined) => v); return 0; }
    );
}

test "callback acceptance: a reduce accumulator that refuses the seed is ZTS203" {
    try expectOneArgMismatch(
        \\function f(): number { [1, 2].reduce((acc: string, n: number) => acc, 0); return 0; }
    , "callback parameter 'acc' is 'string', but reduce passes 'number'");
}

test "callback acceptance: a reduce accumulator that accepts the seed is accepted" {
    try expectNoTypeDiagnostic(
        \\function f(): number { return [1, 2].reduce((acc: number, n: number) => acc + n, 0); }
    );
}

test "callback acceptance: a toSorted comparator parameter that refuses the element is ZTS203" {
    try expectOneArgMismatch(
        \\function f(): number { [1, 2].toSorted((a: string, b: string) => 0); return 0; }
    , "callback parameter 'a' is 'string', but toSorted passes 'number'");
}

test "callback acceptance: an unannotated map callback is accepted" {
    try expectNoTypeDiagnostic(
        \\function f(): number { [1, 2].map((v) => v + 1); return 0; }
    );
}

test "callback acceptance: a module export passed to map is checked against the element" {
    try expectOneArgMismatch(
        \\import { sha256 } from "zttp:crypto";
        \\function f(): number { [1, 2].map(sha256); return 0; }
    , "callback parameter '#1' is 'string', but map passes 'number'");
}

test "callback acceptance: a named function passed to a record method that takes a no-parameter callback keeps the arity refusal" {
    try expectOneArgMismatch(
        \\structural Api = { run: (cb: () => number) => number };
        \\function g(n: number): number { return n; }
        \\function f(api: Api): number { return api.run(g); }
    , "argument type does not match parameter type: expected () => number, got (: number) => number");
}

test "result shape: an andThen callback declared to return unknown is ZTS203" {
    try expectOneArgMismatch(
        \\import { ok, andThen } from "zttp:result";
        \\function g(n: number): unknown { return n; }
        \\function f(): number { const r = andThen(ok(1), g); return 0; }
    , "andThen callback must return a Result, got 'unknown'");
}

// ---------------------------------------------------------------------------
// Response init: the runtime reads `status` and sends no other member
// ---------------------------------------------------------------------------

test "response init: a headers member of a Response.json init is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.json({ ok: true }, { status: 201, headers: { a: "b" } }); }
    , "Response.json does not support the init member 'headers'");
}

test "response init: a headers member of a Response.text init is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.text("x", { headers: { a: "b" } }); }
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member of a Response.html init is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.html("<p>x</p>", { status: 200, headers: { a: "b" } }); }
    , "Response.html does not support the init member 'headers'");
}

test "response init: a headers member of a Response.rawJson init is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.rawJson("{}", { status: 200, headers: { a: "b" } }); }
    , "Response.rawJson does not support the init member 'headers'");
}

test "response init: a member that is not status is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.text("x", { status: 201, statusText: "Made" }); }
    , "Response.text does not support the init member 'statusText'");
}

test "response init: a quoted member name is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response.text("x", { "Content-Type": "text/html" }); }
    , "Response.text does not support the init member 'Content-Type'");
}

test "response init: a headers member of a named init record is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response {
        \\  const init = { status: 201, headers: { a: "b" } };
        \\  return Response.text("x", init);
        \\}
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member of a spread operand is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response {
        \\  const base = { headers: { a: "b" } };
        \\  return Response.json({ ok: true }, { ...base, status: 201 });
        \\}
    , "Response.json does not support the init member 'headers'");
}

test "response init: a headers member of a declared parameter type is ZTS203" {
    try expectOneArgMismatch(
        \\function reply(init: { status: number; headers: { a: string } }): Response { return Response.text("x", init); }
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member of a named record type is ZTS203" {
    try expectOneArgMismatch(
        \\structural Init = { status: number; headers: { a: string } };
        \\function reply(init: Init): Response { return Response.text("x", init); }
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member of one branch of a conditional init is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response {
        \\  return Response.text("x", req.method === "GET" ? { status: 200 } : { status: 404, headers: { a: "b" } });
        \\}
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member behind an optional call is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response?.text("x", { headers: { a: "b" } }); }
    , "Response.text does not support the init member 'headers'");
}

test "response init: a headers member behind a string literal key is ZTS203" {
    try expectOneArgMismatch(
        \\function handler(req: Request): Response { return Response["text"]("x", { headers: { a: "b" } }); }
    , "Response.text does not support the init member 'headers'");
}

test "response init: each unsupported member of an init literal gets a diagnostic" {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 2), diagnostics.len);
            try testing.expectEqualStrings("Response.text does not support the init member 'headers'", diagnostics[0].message);
            try testing.expectEqualStrings("Response.text does not support the init member 'statusText'", diagnostics[1].message);
        }
    };
    try withSession(testing.allocator,
        \\function handler(req: Request): Response { return Response.text("x", { status: 201, headers: { a: "b" }, statusText: "Made" }); }
    , Probe.run);
}

test "response init: a status member alone is accepted on every helper" {
    try expectNoTypeDiagnostic(
        \\function a(req: Request): Response { return Response.json({ ok: true }, { status: 201 }); }
        \\function b(req: Request): Response { return Response.text("x", { status: 202 }); }
        \\function c(req: Request): Response { return Response.html("<p>x</p>", { status: 203 }); }
        \\function d(req: Request): Response { return Response.rawJson("{}", { status: 204 }); }
    );
}

test "response init: a named init record that holds only status is accepted" {
    try expectNoTypeDiagnostic(
        \\function handler(req: Request): Response {
        \\  const init = { status: 404 };
        \\  return Response.json({ error: "not found" }, init);
        \\}
    );
}

test "response init: a redirect status number is accepted" {
    try expectNoTypeDiagnostic(
        \\function handler(req: Request): Response { return Response.redirect("/next", 301); }
    );
}

test "response init: a shadowed Response is a different value" {
    try expectNoTypeDiagnostic(
        \\function f(): string {
        \\  const Response = { text: (body: string, init: { headers: { a: string } }): string => body };
        \\  return Response.text("x", { headers: { a: "b" } });
        \\}
    );
}

// ---------------------------------------------------------------------------
// Response constructor: `Response?.json` and `Response["json"]` call it too
// ---------------------------------------------------------------------------

/// `source` must report exactly one ZTS213 (`unencodable_json_payload`) with `message`.
fn expectOneUnencodablePayload(source: []const u8, comptime message: []const u8) !void {
    const Probe = struct {
        fn run(session: Session) anyerror!void {
            const diagnostics = session.resolved.typeDiagnostics();
            try testing.expectEqual(@as(usize, 1), diagnostics.len);
            try testing.expectEqual(type_checker_mod.DiagnosticKind.unencodable_json_payload, diagnostics[0].kind);
            try testing.expectEqualStrings(message, diagnostics[0].message);
        }
    };
    try withSession(testing.allocator, source, Probe.run);
}

test "response constructor: a Bytes payload behind an optional call is ZTS213" {
    try expectOneUnencodablePayload(
        \\function handler(req: Request): Response { return Response?.json({ raw: requestBody(req) }); }
    , "Response.json cannot encode this payload: Bytes is not a JSON value");
}

test "response constructor: a Bytes payload behind a string literal key is ZTS213" {
    try expectOneUnencodablePayload(
        \\function handler(req: Request): Response { return Response["json"]({ raw: requestBody(req) }); }
    , "Response.json cannot encode this payload: Bytes is not a JSON value");
}

test "response constructor: an optional call has the Response type" {
    try expectOneMismatch(
        \\function f(): string { const s: string = Response?.text("x"); return s; }
    , "type 'Response' is not assignable to type 'string'");
}

test "response constructor: a call through a string literal key has the Response type" {
    try expectOneMismatch(
        \\function f(): string { const s: string = Response["text"]("x"); return s; }
    , "type 'Response' is not assignable to type 'string'");
}

// ---------------------------------------------------------------------------
// Module-state writers across a file import
// ---------------------------------------------------------------------------

/// How the importing module of `analyzeAcrossFile` learns about its dependency.
const DependencyView = enum {
    /// The dependency's export rows carry the verifier writes of its module.
    with_writes,
    /// The dependency's export rows are built without any verifier write.
    without_writes,
    /// The importing module gets a blocked result for every file import.
    blocked,
};

/// One diagnostic row of a helper capsule, owned.
const HelperRow = struct {
    function: []const u8,
    spec: []const u8,
    suggestion: []const u8,
};

fn freeHelperRows(allocator: std.mem.Allocator, rows: []HelperRow) void {
    for (rows) |row| {
        allocator.free(row.function);
        allocator.free(row.spec);
        allocator.free(row.suggestion);
    }
    allocator.free(rows);
}

/// Analyze `dependency` as `./b.ts` with the verifier on, take its export
/// rows, and discharge the helper capsules of `entry`, which imports it.
/// Returns the failing-capsule rows of the entry helpers in source order.
fn analyzeAcrossFile(
    allocator: std.mem.Allocator,
    dependency: []const u8,
    entry: []const u8,
    view: DependencyView,
) ![]HelperRow {
    var dep_frontend: source_frontend_mod.DirectCheckSource = undefined;
    try dep_frontend.initCompileInPlace(allocator, allocator, dependency, "b.ts");
    defer dep_frontend.deinit();
    const dep_accepted = dep_frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var dep: ModuleAnalysisSession = .{};
    try dep.initFull(allocator, ParsedModule.fromTypedExisting(
        dep_accepted.ir_view,
        dep_accepted.root,
        dep_accepted.atoms,
        dep_accepted.type_store,
    ), .{
        .source_types = .direct,
        .strict = false,
        .select_verifier = true,
        .allow_raw_exported_boundary = true,
    });
    defer dep.deinit();
    try dep.complete();
    _ = try dep.runModuleVerifier(.{});
    var write_nodes: std.ArrayList(NodeIndex) = .empty;
    defer write_nodes.deinit(allocator);
    const checked = dep.checkedModule() orelse return error.TestUnexpectedResult;
    for (checked.verifierDiagnostics()) |diagnostic| {
        if (diagnostic.kind != .module_scope_mutation) continue;
        try write_nodes.append(allocator, diagnostic.node);
    }
    if (view == .with_writes) try dep.setStateWriteNodes(write_nodes.items);
    dep.extraction_opts.capture_export_effects = true;
    var dep_contract = try dep.extractContract("b.ts");
    defer dep_contract.deinit(allocator);
    var exports = dep.takeExportEffects() orelse return error.ExportEffectsMissing;
    defer exports.deinit(allocator);

    var entry_frontend: source_frontend_mod.DirectCheckSource = undefined;
    try entry_frontend.initCompileInPlace(allocator, allocator, entry, "handler.ts");
    defer entry_frontend.deinit();
    const entry_accepted = entry_frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var session: ModuleAnalysisSession = .{};
    try session.initFull(allocator, ParsedModule.fromTypedExisting(
        entry_accepted.ir_view,
        entry_accepted.root,
        entry_accepted.atoms,
        entry_accepted.type_store,
    ), .{
        .source_types = .direct,
        .strict = false,
        .allow_raw_exported_boundary = true,
    });
    defer session.deinit();
    try session.complete();
    var imported: std.ArrayList(ImportedEffect) = .empty;
    defer imported.deinit(allocator);
    for ((try session.facts()).imports.items) |record| {
        const effect: ExportEffect = if (view == .blocked) .blocked else exports.lookup(record.imported_name);
        try imported.append(allocator, .{ .slot = record.slot, .effect = effect });
    }
    try session.setImportedEffects(imported.items);
    var table = try session.dischargeHelperCapsules(.{});
    defer table.deinit(allocator);

    var rows: std.ArrayList(HelperRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.function);
            allocator.free(row.spec);
            allocator.free(row.suggestion);
        }
        rows.deinit(allocator);
    }
    for (table.capsules.items) |capsule| {
        for (capsule.diagnostics.items) |diagnostic| {
            const function = try allocator.dupe(u8, capsule.name);
            errdefer allocator.free(function);
            const spec = try allocator.dupe(u8, diagnostic.spec_name);
            errdefer allocator.free(spec);
            const suggestion = try allocator.dupe(u8, diagnostic.suggestion orelse "");
            errdefer allocator.free(suggestion);
            try rows.append(allocator, .{ .function = function, .spec = spec, .suggestion = suggestion });
        }
    }
    return rows.toOwnedSlice(allocator);
}

/// The export row that `source` gives the export `name`, with the verifier
/// writes of the module, or an error when it is not a callable.
fn exportRowForTest(allocator: std.mem.Allocator, source: []const u8, name: []const u8) !effect_inference.EffectRow {
    var frontend: source_frontend_mod.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(allocator, allocator, source, "b.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestUnexpectedResult;
    var dep: ModuleAnalysisSession = .{};
    try dep.initFull(allocator, ParsedModule.fromTypedExisting(
        accepted.ir_view,
        accepted.root,
        accepted.atoms,
        accepted.type_store,
    ), .{
        .source_types = .direct,
        .strict = false,
        .select_verifier = true,
        .allow_raw_exported_boundary = true,
    });
    defer dep.deinit();
    try dep.complete();
    _ = try dep.runModuleVerifier(.{});
    var write_nodes: std.ArrayList(NodeIndex) = .empty;
    defer write_nodes.deinit(allocator);
    const checked = dep.checkedModule() orelse return error.TestUnexpectedResult;
    for (checked.verifierDiagnostics()) |diagnostic| {
        if (diagnostic.kind != .module_scope_mutation) continue;
        try write_nodes.append(allocator, diagnostic.node);
    }
    try dep.setStateWriteNodes(write_nodes.items);
    dep.extraction_opts.capture_export_effects = true;
    var contract = try dep.extractContract("b.ts");
    defer contract.deinit(allocator);
    var exports = dep.takeExportEffects() orelse return error.ExportEffectsMissing;
    defer exports.deinit(allocator);
    return switch (exports.lookup(name)) {
        .callable => |row| row,
        .data, .blocked => error.CallableExportExpected,
    };
}

const counter_dependency =
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
    \\export function relay(): number {
    \\  return bump();
    \\}
;

test "an export row carries writes_module_state for a function that reaches a module write" {
    const allocator = testing.allocator;
    try testing.expect((try exportRowForTest(allocator, counter_dependency, "bump")).writes_module_state);
    try testing.expect((try exportRowForTest(allocator, counter_dependency, "relay")).writes_module_state);
    try testing.expect(!(try exportRowForTest(allocator, counter_dependency, "peek")).writes_module_state);
}

test "an export row carries writes_module_state for a holder whose user writes" {
    const allocator = testing.allocator;
    const holder =
        \\let count = 0;
        \\
        \\function bump(): number {
        \\  count = count + 1;
        \\  return count;
        \\}
        \\
        \\export const api = { bump: bump };
    ;
    try testing.expect((try exportRowForTest(allocator, holder, "api")).writes_module_state);
}

test "an export row carries writes_module_state for a holder with an inline arrow that writes" {
    const allocator = testing.allocator;
    const holder =
        \\let count = 0;
        \\
        \\export const api = { bump: (): number => { count = count + 1; return count; } };
    ;
    try testing.expect((try exportRowForTest(allocator, holder, "api")).writes_module_state);
}

test "an export row of a holder with no write keeps writes_module_state clear" {
    const allocator = testing.allocator;
    const holder =
        \\let count = 0;
        \\
        \\function peek(): number {
        \\  return count;
        \\}
        \\
        \\export const api = { peek: peek };
    ;
    try testing.expect(!(try exportRowForTest(allocator, holder, "api")).writes_module_state);
}

const read_only_tally_prefix =
    \\import { bump, peek, relay } from "./b.ts";
    \\
;

test "a read_only helper that calls an imported module writer fails with the import named" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function tally(): Proof<number, "read_only"> {
        \\  return bump();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("tally", rows[0].function);
    try testing.expectEqualStrings("read_only", rows[0].spec);
    try testing.expectEqualStrings(
        "`tally` reaches `bump` from `./b.ts`, which writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching `bump`.",
        rows[0].suggestion,
    );
}

test "a read_only helper that reaches an imported writer through a local relay fails with the fixed text" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function inner(): number {
        \\  return 1;
        \\}
        \\
        \\function outer(): number {
        \\  return inner() + bump();
        \\}
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return outer();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("tally", rows[0].function);
    try testing.expectEqualStrings(
        "`tally` reaches a function in another file that writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching the writer.",
        rows[0].suggestion,
    );
}

test "a read_only helper over a clean export of a module that holds a writer passes" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function tally(): Proof<number, "read_only"> {
        \\  return peek();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "a read_only helper that holds an imported module writer as a value fails" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function mapped(): Proof<number, "read_only"> {
        \\  return [1].map(bump)[0];
        \\}
        \\
        \\function held(): Proof<number, "read_only"> {
        \\  const f = bump;
        \\  return 1;
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("mapped", rows[0].function);
    try testing.expectEqualStrings("read_only", rows[0].spec);
    try testing.expectEqualStrings(
        "`mapped` reaches `bump` from `./b.ts`, which writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching `bump`.",
        rows[0].suggestion,
    );
    try testing.expectEqualStrings("held", rows[1].function);
    try testing.expectEqualStrings("read_only", rows[1].spec);
    try testing.expectEqualStrings(
        "`held` reaches `bump` from `./b.ts`, which writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching `bump`.",
        rows[1].suggestion,
    );
}

test "a read_only helper over a blocked import keeps the lower-bound text" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function tally(): Proof<number, "read_only"> {
        \\  return bump();
        \\}
    , .blocked);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("read_only", rows[0].spec);
    try testing.expectEqualStrings(
        "this function calls through a value whose body the compiler cannot see, so no property can be proved about it; call the helper by name instead.",
        rows[0].suggestion,
    );
}

test "pure and deterministic rows over an imported writer keep their generic text" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function tally(): Proof<number, "pure" | "deterministic"> {
        \\  return bump();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("pure", rows[0].spec);
    try testing.expectEqualStrings(
        "remove module calls and clock or RNG reads so the helper stays pure.",
        rows[0].suggestion,
    );
    try testing.expectEqualStrings("deterministic", rows[1].spec);
    try testing.expectEqualStrings(
        "remove the clock or RNG read (Date.now, Math.random, performance.now) from the helper.",
        rows[1].suggestion,
    );
}

test "a chain of ten local functions to an imported writer fails read_only and is no lower bound" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function f0(): number { return bump(); }
        \\function f1(): number { return f0(); }
        \\function f2(): number { return f1(); }
        \\function f3(): number { return f2(); }
        \\function f4(): number { return f3(); }
        \\function f5(): number { return f4(); }
        \\function f6(): number { return f5(); }
        \\function f7(): number { return f6(); }
        \\function f8(): number { return f7(); }
        \\function f9(): number { return f8(); }
        \\function tally(): Proof<number, "read_only"> {
        \\  return f9();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("tally", rows[0].function);
    try testing.expectEqualStrings(
        "`tally` reaches a function in another file that writes module state, so it cannot prove `read_only`: remove `read_only` from the capsule, or stop reaching the writer.",
        rows[0].suggestion,
    );
}

test "a read_only helper over an imported holder with an inline writer fails" {
    const allocator = testing.allocator;
    const holder =
        \\let count = 0;
        \\
        \\export const api = { bump: (): number => { count = count + 1; return count; } };
    ;
    const rows = try analyzeAcrossFile(allocator, holder,
        \\import { api } from "./b.ts";
        \\
        \\function tally(): Proof<number, "read_only"> {
        \\  return api.bump();
        \\}
    , .with_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("tally", rows[0].function);
    try testing.expectEqualStrings("read_only", rows[0].spec);
}

test "a read_only helper passes when the dependency export rows were built with no verifier write" {
    const allocator = testing.allocator;
    const rows = try analyzeAcrossFile(allocator, counter_dependency, read_only_tally_prefix ++
        \\function tally(): Proof<number, "read_only"> {
        \\  return bump();
        \\}
    , .without_writes);
    defer freeHelperRows(allocator, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "ModuleAnalysisSession freezes writes_module_state in imported effects" {
    const allocator = testing.allocator;
    var parsed_state = try parseSourceForTest(allocator, "function handler(req) { return Response.text('ok'); }");
    defer parsed_state.js_parser.deinit();
    const view = IrView.fromIRStore(&parsed_state.js_parser.nodes, &parsed_state.js_parser.constants);
    const parsed = ParsedModule.fromExisting(view, parsed_state.root, null);
    var analysis: ModuleAnalysisSession = .{};
    try analysis.initContractOnly(allocator, parsed, .{});
    defer analysis.deinit();
    try analysis.complete();
    const selected = [_]ImportedEffect{.{ .slot = 0, .effect = .{ .callable = .{ .writes_module_state = true } } }};
    const changed = [_]ImportedEffect{.{ .slot = 0, .effect = .{ .callable = .{} } }};
    try analysis.setImportedEffects(&selected);
    _ = try analysis.pathEffectFacts();
    const equivalent = selected;
    try analysis.setImportedEffects(&equivalent);
    try testing.expectError(error.ImportedEffectsFrozen, analysis.setImportedEffects(&changed));
}
