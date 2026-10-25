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

pub fn projectCompletedFlow(
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
        zts.pipeline.projectFlowProperties(contract, flow_props);
        if (violations_out) |vout| {
            zts.property_diagnostics.collectFlowViolations(allocator, vout, flow_diags, ir_view);
        }
        if (fresh and !builtin.is_test and flow_errors == 0) debugPrint("Flow analysis passed\n", .{});
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

pub fn buildMultiModuleContract(
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
        var parsed = zts.pipeline.ParsedModule.fromExisting(module_view, compiled_module.root, atoms);
        parsed.scopes = &js_parser.scopes;
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

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initSoundExtraction(allocator, parsed, .{ .type_check = failContractTypeCheck, .strict = false });
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
