//! Repository-only P9 evidence. Reads the frozen fixtures without exemptions;
//! neither production dispatch nor the public embedding API imports this tool.
const std = @import("std");
const zts = @import("zts");
const compiler = @import("zts-compiler");
const precompile = @import("precompile.zig");
const precision = @import("flow_precision_expectations.zig");
const p0 = @import("flow_false_proofs.zig");
const inputs = @import("flow_shadow_inputs.zig");

const Property = enum { no_secret_leakage, no_credential_leakage, input_validated, pii_contained, injection_safe };
const Status = enum { PROVEN, UNPROVEN, REFUSED, NO_VERDICT };
const Expect = enum { prove, refuse, refuse_or_unprove, prove_or_unprove, observe, not_applicable };
const Observation = [5]Status;
const no_verdict: Observation = @splat(.NO_VERDICT);
const Case = inputs.Case;

const Totals = struct {
    cases: usize = 0,
    property_rows: usize = 0,
    precision_bits: usize = 0,
    p0_bits: usize = 0,
    contrast_bits: usize = 0,
    mismatches: usize = 0,
    differences: usize = 0,
    unresolved: usize = 0,
    source_errors: usize = 0,
    not_applicable: usize = 0,
    diagnostic_differences: usize = 0,
};

const Evidence = struct {
    production: std.ArrayList([]const u8) = .empty,
    shadow: std.ArrayList([]const u8) = .empty,
};

fn recordDiagnostic(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, engine: enum { production, shadow }, diagnostic: precompile.json_diag.JsonDiagnostic, evidence: *Evidence) !void {
    const normalized = .{ .code = diagnostic.code, .severity = diagnostic.severity, .message = diagnostic.message, .file = diagnostic.file, .line = diagnostic.line, .column = diagnostic.column, .start_offset = diagnostic.start_offset, .end_offset = diagnostic.end_offset, .suggestion = diagnostic.suggestion, .repair_intent = if (diagnostic.repair_intent) |intent| intent.asString() else null };
    try line(writer, .{ .record = if (engine == .production) "production_diagnostic" else "shadow_diagnostic", .case = case, .diagnostic = normalized });
    if (diagnostic.code.len == 6 and std.mem.startsWith(u8, diagnostic.code, "ZTS40") and diagnostic.code[5] >= '0' and diagnostic.code[5] <= '8') {
        const key = try std.json.Stringify.valueAlloc(allocator, normalized, .{});
        switch (engine) {
            .production => try evidence.production.append(allocator, key),
            .shadow => try evidence.shadow.append(allocator, key),
        }
    }
}

fn compareDiagnostics(writer: *std.Io.Writer, case: Case, evidence: Evidence, totals: *Totals) !void {
    inline for (.{ .{ "production", evidence.production.items, evidence.shadow.items }, .{ "shadow", evidence.shadow.items, evidence.production.items } }) |side| {
        for (side[1], 0..) |key, index| {
            var occurrence: usize = 0;
            for (side[1][0 .. index + 1]) |prior| if (std.mem.eql(u8, key, prior)) {
                occurrence += 1;
            };
            var other_count: usize = 0;
            for (side[2]) |other| if (std.mem.eql(u8, key, other)) {
                other_count += 1;
            };
            if (occurrence > other_count) {
                totals.diagnostic_differences += 1;
                try line(writer, .{ .record = "diagnostic_difference", .case = case, .engine = side[0], .occurrence = occurrence, .diagnostic_json = key });
            }
        }
    }
}

fn line(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn recordProductionEvidence(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, trace: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trace, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProductionTraceObjectMissing;
    for (std.enums.values(Property)) |property| {
        const item = parsed.value.object.get(@tagName(property)) orelse continue;
        if (item != .object) return error.ProductionTracePropertyObjectMissing;
        try line(writer, .{
            .record = "production_evidence",
            .case = case,
            .property = @tagName(property),
            .holds = item.object.get("holds") orelse .null,
            .counterexample = item.object.get("counterexample") orelse .null,
            .resisted = item.object.get("resisted") orelse .null,
        });
    }
}

fn recordShadowWitness(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, diagnostic: compiler.flow_report.Diagnostic, view: zts.IrView) !void {
    const cx = compiler.counterexample;
    const Candidate = struct {
        request: cx.ConcreteRequest,
        io_stubs: []const cx.IoStubEntry,
        replay_jsonl: []const u8,
    };
    const property = compiler.flow_report.propertyTagForKind(diagnostic.kind);
    var solved: ?cx.CounterexampleWitness = null;
    defer if (solved) |*value| value.deinit(allocator);
    var replay: std.Io.Writer.Allocating = .init(allocator);
    defer replay.deinit();
    var candidate: ?Candidate = null;
    const location = view.getLoc(diagnostic.node);
    if (diagnostic.witness) |witness| if (property) |tag| {
        const position: cx.SourceSpan = .{ .line = if (location) |loc| loc.line else 0, .column = if (location) |loc| loc.column else 0 };
        solved = try cx.solve(allocator, .{ .property = tag, .origin = position, .sink = position, .summary = diagnostic.message, .constraints = witness.path_constraints, .io_calls = witness.io_calls });
        try cx.writeJsonl(&replay.writer, solved.?);
        candidate = .{ .request = solved.?.request, .io_stubs = solved.?.io_stubs, .replay_jsonl = replay.written() };
    };
    // A solver candidate is reviewable replay input, not a successful replay
    // or proof that a replay-pure transform accepts its synthetic values.
    try line(writer, .{ .record = "shadow_witness", .case = case, .kind = @tagName(diagnostic.kind), .node = diagnostic.node, .location = location, .property = if (property) |tag| @tagName(tag) else null, .witness = diagnostic.witness, .candidate = candidate, .runtime_replay = "not_run" });
}

fn holds(properties: anytype, property: Property) bool {
    return switch (property) {
        inline else => |p| @field(properties, @tagName(p)),
    };
}

fn verdict(held: bool, witnessed: bool) !Status {
    if (held and witnessed) return error.ContradictoryFlowVerdict;
    return if (held) .PROVEN else if (witnessed) .REFUSED else .UNPROVEN;
}

fn accepts(expect: Expect, actual: Status) bool {
    return switch (expect) {
        .prove => actual == .PROVEN,
        .refuse => actual == .REFUSED,
        .refuse_or_unprove => actual == .REFUSED or actual == .UNPROVEN,
        .prove_or_unprove => actual == .PROVEN or actual == .UNPROVEN,
        .observe => actual != .NO_VERDICT,
        .not_applicable => actual == .NO_VERDICT,
    };
}

fn codeWitnesses(code: []const u8, property: Property) bool {
    const codes: []const []const u8 = switch (property) {
        .no_secret_leakage => &.{ "ZTS400", "ZTS402", "ZTS404", "ZTS406" },
        .no_credential_leakage => &.{ "ZTS401", "ZTS403", "ZTS405", "ZTS408" },
        .injection_safe => &.{"ZTS407"},
        // The shared diagnostic vocabulary witnesses three properties only.
        // Keep the other two unproven, without inventing a refusal witness.
        .input_validated, .pii_contained => &.{},
    };
    for (codes) |candidate| if (std.mem.eql(u8, code, candidate)) return true;
    return false;
}

fn production(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, source: []const u8, schema: ?[]const u8, allow_preflow_block: bool, evidence: *Evidence) !?Observation {
    var result = try precompile.runCheckOnlyFromSourceWithOptions(allocator, source, case.path, .{ .json_mode = true, .sql_schema_path = schema });
    defer result.deinit(allocator);
    for (result.json_diagnostics.items) |diagnostic| try recordDiagnostic(allocator, writer, case, .production, diagnostic, evidence);
    if (result.proof_trace_json) |trace| {
        try line(writer, .{ .record = "production_proof_trace", .case = case, .proof_trace_json = trace });
        try recordProductionEvidence(allocator, writer, case, trace);
    }
    var stages: std.ArrayList([]const u8) = .empty;
    var stage_iterator = result.stages_run.iterator();
    while (stage_iterator.next()) |stage| try stages.append(allocator, @tagName(stage));
    const blockers = .{ .parse_errors = result.parse_errors, .bool_errors = result.bool_errors, .type_errors = result.type_errors, .strict_errors = result.strict_errors };
    try line(writer, .{ .record = "production_admission", .case = case, .stages = stages.items, .blockers = blockers, .flow_reached = result.stages_run.contains(.flow) });
    if (!result.stages_run.contains(.flow)) {
        if (!allow_preflow_block) return error.ProductionFlowStageMissing;
        // Flow replacement shares the admitted/typed prefix. A parse/type/
        // strict refusal or a non-handler module has no flow invocation to
        // replace; never force the shadow past that production boundary.
        try line(writer, .{ .record = "flow_not_applicable", .case = case, .stages = stages.items, .blockers = blockers, .diagnostic_contract = "shared_production_prefix" });
        return null;
    }
    const properties = result.properties orelse return error.ProductionPropertiesMissing;
    var observed: Observation = undefined;
    for (std.enums.values(Property)) |property| {
        var witnessed = false;
        for (result.json_diagnostics.items) |diagnostic| if (codeWitnesses(diagnostic.code, property)) {
            witnessed = true;
        };
        observed[@intFromEnum(property)] = try verdict(holds(properties, property), witnessed);
    }
    return observed;
}

fn shadow(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, source: []const u8, totals: *Totals, evidence: *Evidence) !Observation {
    var owner: zts.DirectCheckSource = undefined;
    try owner.initInPlace(allocator, allocator, source, case.path);
    defer owner.deinit();
    const capabilities = owner.acceptedCapabilities() orelse {
        try line(writer, .{ .record = "shadow_admission", .case = case, .outcome = @tagName(std.meta.activeTag(owner.outcome().*)) });
        return error.ShadowAdmissionRefused;
    };
    const handler = zts.findHandlerFunction(capabilities.ir_view, capabilities.root) orelse return error.ShadowHandlerMissing;
    const parsed = zts.parsedModuleFromDirectCheck(&owner) orelse return error.ShadowModuleFactsUnavailable;
    var facts = try zts.pipeline.buildModuleFacts(allocator, parsed, null);
    defer facts.deinit();
    var graph = try precompile.loadFlowModulesForCheck(allocator, parsed, source, &facts, case.path, null);
    defer graph.deinit();
    try line(writer, .{ .record = "shadow_module_graph", .case = case, .complete = graph.complete, .initialization_order = graph.initialization_order.items });
    for (graph.views.items) |module| try line(writer, .{ .record = "shadow_module", .case = case, .id = module.id, .path = module.path, .revision = std.fmt.bytesToHex(module.revision, .lower), .imports = module.imports });
    var evaluator = compiler.flow_interp.FlowInterp.init(allocator, capabilities.ir_view, capabilities.atoms);
    defer evaluator.deinit();
    evaluator.captures = graph.views.items[0].captures;
    evaluator.modules = graph.views.items;
    evaluator.initialization_order = graph.initialization_order.items;
    evaluator.modules_complete = graph.complete;
    const report = try evaluator.analyzeHandlerReport(handler);
    try line(writer, .{ .record = "shadow_evaluation", .case = case, .cleared = report.evaluation.cleared, .steps = evaluator.steps, .events = report.events.len, .unresolved = report.evaluation.unresolved.len });
    try line(writer, .{ .record = "shadow_defended_paths", .case = case, .paths = report.defended_paths });
    for (report.evaluation.unresolved) |unresolved| {
        totals.unresolved += 1;
        if (unresolved.module >= graph.views.items.len) return error.UnresolvedModuleMissing;
        const module = graph.views.items[unresolved.module];
        const location = module.ir_view.getLoc(unresolved.node);
        try line(writer, .{ .record = "unresolved", .case = case, .module = module.id, .path = module.path, .node = unresolved.node, .tag = @tagName(unresolved.tag), .owner = @tagName(unresolved.owner), .location = location, .source_line = if (module.id == 0) (if (location) |loc| zts.sourceLine(source, loc.line) else null) else null });
    }
    for (report.events) |event| {
        if (event.module >= graph.views.items.len) return error.SinkModuleMissing;
        const module = graph.views.items[event.module];
        try line(writer, .{ .record = "shadow_sink", .case = case, .module = module.id, .path = module.path, .node = event.source_node, .callsite = event.node, .sink = @tagName(event.sink), .location = module.ir_view.getLoc(event.source_node), .reached = event.reached });
    }
    for (report.diagnostics) |diagnostic| {
        try recordShadowWitness(allocator, writer, case, diagnostic, capabilities.ir_view);
        if (precompile.json_diag.fromCheckerDiagnostic(allocator, .flow, diagnostic, capabilities.ir_view, case.path)) |projected| {
            try recordDiagnostic(allocator, writer, case, .shadow, projected, evidence);
        } else return error.ShadowDiagnosticProjectionMissing;
    }
    var observed: Observation = undefined;
    for (std.enums.values(Property)) |property| {
        var witnessed = false;
        for (report.diagnostics) |diagnostic| {
            const tag = compiler.flow_report.propertyTagForKind(diagnostic.kind) orelse continue;
            if (std.mem.eql(u8, @tagName(tag), @tagName(property))) witnessed = true;
        }
        observed[@intFromEnum(property)] = try verdict(holds(report.properties, property), witnessed);
    }
    return observed;
}

const Compared = struct { old: Observation, new: Observation, applicable: bool = true };

fn observe(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, source: []const u8, schema: ?[]const u8, totals: *Totals) !Compared {
    return observeMode(allocator, writer, case, source, schema, totals, false);
}

fn observeMode(allocator: std.mem.Allocator, writer: *std.Io.Writer, case: Case, source: []const u8, schema: ?[]const u8, totals: *Totals, allow_preflow_block: bool) !Compared {
    totals.cases += 1;
    var evidence: Evidence = .{};
    const possible_old = production(allocator, writer, case, source, schema, allow_preflow_block, &evidence) catch |err| {
        totals.source_errors += 1;
        try line(writer, .{ .record = "case_error", .case = case, .engine = "production", .error_name = @errorName(err) });
        return .{ .old = no_verdict, .new = no_verdict };
    };
    const old = possible_old orelse {
        totals.not_applicable += 1;
        return .{ .old = no_verdict, .new = no_verdict, .applicable = false };
    };
    const new = shadow(allocator, writer, case, source, totals, &evidence) catch |err| failed: {
        totals.source_errors += 1;
        try line(writer, .{ .record = "case_error", .case = case, .engine = "shadow", .error_name = @errorName(err) });
        break :failed no_verdict;
    };
    try compareDiagnostics(writer, case, evidence, totals);
    return .{ .old = old, .new = new };
}

fn row(writer: *std.Io.Writer, case: Case, property: Property, expect: Expect, old: Status, new: Status, totals: *Totals) !void {
    const matches = accepts(expect, new) and (old != .NO_VERDICT or expect == .not_applicable);
    totals.property_rows += 1;
    if (!matches) totals.mismatches += 1;
    if (old != new) totals.differences += 1;
    try line(writer, .{ .record = "property", .case = case, .property = @tagName(property), .expected = @tagName(expect), .production = @tagName(old), .shadow = @tagName(new), .matches = matches, .changed = old != new });
}

fn floors(entries: usize, bits: usize, fixtures: usize, contrasts: usize) !void {
    if (entries != 48 or bits != 214 or fixtures != 38 or contrasts != 4) return error.FrozenFloorChanged;
}

fn requiredProperty(entry: anytype, property: Property) bool {
    var it = entry.expect.iterator();
    while (it.next()) |bit| if (std.mem.eql(u8, @tagName(bit), @tagName(property))) return true;
    return false;
}

fn selection(args: []const []const u8) !inputs.Selection {
    var selected: inputs.Selection = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--census")) selected.census = true else if (std.mem.eql(u8, arg, "--diagnostic-corpus")) selected.diagnostic_corpus = true else if (std.mem.eql(u8, arg, "--codegen")) selected.codegen = true else return error.UnexpectedArguments;
    }
    return selected;
}

fn probeExpectation(expect: inputs.census.Expect) Expect {
    return switch (expect) {
        .hold => .prove,
        .refuse => .refuse,
        .refuse_or_unprove => .refuse_or_unprove,
        .hold_or_unprove => .prove_or_unprove,
    };
}

fn extended(init: std.process.Init, writer: *std.Io.Writer, scratch: []const u8, selected: inputs.Selection, totals: *Totals) !usize {
    const loaded = try inputs.load(init.arena.allocator(), init.io, scratch, selected);
    for (loaded.workspaces.items) |workspace| try line(writer, .{ .record = if (workspace.handler_present) "codegen_workspace" else "no_handler_workspace", .workspace = workspace });
    for (loaded.inputs.items) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const case = input.case;
        // Generated census files are private scratch inputs. Retain their
        // exact bytes in evidence before cleanup removes the materialization.
        if (input.probe) |probe| for (probe.files) |file| {
            try line(writer, .{ .record = "census_source", .case = case, .name = file.name, .source = file.text });
        };
        const compared: Compared = if (input.source) |source| try observeMode(arena.allocator(), writer, case, source, input.schema, totals, input.allow_preflow_block) else failed: {
            totals.cases += 1;
            totals.source_errors += 1;
            try line(writer, .{ .record = "case_error", .case = case, .engine = "source", .error_name = input.error_name orelse "SourceMissing" });
            break :failed .{ .old = no_verdict, .new = no_verdict };
        };
        if (input.probe) |probe| try line(writer, .{ .record = "census_expectation", .case = case, .group = @tagName(probe.group), .label = if (probe.label) |label| @tagName(label) else null, .sink = if (probe.sink) |sink| @tagName(sink) else null, .kind = probe.kind, .property = @tagName(probe.property), .expected = @tagName(probe.expect), .reason = probe.reason });
        for (std.enums.values(Property)) |property| {
            var expect: Expect = if (compared.applicable) .observe else .not_applicable;
            if (input.probe) |probe| if (std.mem.eql(u8, @tagName(probe.property), @tagName(property))) {
                expect = probeExpectation(probe.expect);
            };
            try row(writer, case, property, expect, compared.old[@intFromEnum(property)], compared.new[@intFromEnum(property)], totals);
        }
        try writer.flush();
    }
    try line(writer, .{ .record = "extended_inventory", .selection = selected, .census_groups = loaded.census_groups, .census_columns = loaded.census_columns, .diagnostic_families = loaded.diagnostic_families, .codegen_descriptors = loaded.descriptors, .codegen_handlers = loaded.codegen_handlers, .codegen_without_handler = loaded.codegen_without_handler, .analyzed_inputs = loaded.inputs.items.len });
    loaded.checkFloors(selected) catch |err| {
        totals.source_errors += 1;
        try line(writer, .{ .record = "input_floor_error", .error_name = @errorName(err) });
    };
    return loaded.inputs.items.len;
}

fn run(init: std.process.Init) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const selected = try selection(args[1..]);
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    var expected_bits: usize = 0;
    for (precision.entries) |entry| expected_bits += entry.expect.count();
    try floors(precision.entries.len, expected_bits, p0.fixtures.len, p0.contrasts.len);
    // A private generated directory supplies the one inline SQL schema. Its
    // lifetime spans production analysis; the working-tree fixtures stay fixed.
    const scratch = try std.fmt.allocPrint(init.arena.allocator(), ".zig-cache/flow-shadow-{d}", .{std.Io.Timestamp.now(init.io, .awake).nanoseconds});
    try std.Io.Dir.cwd().createDirPath(init.io, scratch);
    defer std.Io.Dir.cwd().deleteTree(init.io, scratch) catch |err| std.debug.print("shadow scratch cleanup: {t}\n", .{err});
    const schema_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/schema.sql", .{scratch});
    var totals: Totals = .{};
    for (precision.entries) |entry| {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const case: Case = .{ .group = "precision", .name = entry.path, .path = entry.path };
        totals.precision_bits += entry.expect.count();
        const source = zts.file_io.readFile(allocator, entry.path, 1024 * 1024) catch |err| {
            totals.source_errors += 1;
            try line(writer, .{ .record = "case_error", .case = case, .engine = "source", .error_name = @errorName(err) });
            // Count every missing case and property explicitly in the report.
            totals.cases += 1;
            for (std.enums.values(Property)) |property| try row(writer, case, property, if (requiredProperty(entry, property)) .prove else .observe, .NO_VERDICT, .NO_VERDICT, &totals);
            continue;
        };
        const observed = try observe(allocator, writer, case, source, entry.sql_schema_path, &totals);
        for (std.enums.values(Property)) |property| {
            try row(writer, case, property, if (requiredProperty(entry, property)) .prove else .observe, observed.old[@intFromEnum(property)], observed.new[@intFromEnum(property)], &totals);
        }
        try writer.flush();
    }
    inline for (.{ .{ "p0", p0.fixtures, Expect.refuse_or_unprove }, .{ "contrast", p0.contrasts, Expect.prove } }) |group| {
        for (group[1]) |fixture| {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const case: Case = .{ .group = group[0], .name = fixture.name, .path = "flow-false-proof.ts" };
            if (fixture.sql_schema) |schema| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = schema_path, .data = schema });
            const observed = try observe(arena.allocator(), writer, case, fixture.source, if (fixture.sql_schema != null) schema_path else null, &totals);
            const property = std.meta.stringToEnum(Property, @tagName(fixture.property)).?;
            if (group[2] == .prove) totals.contrast_bits += 1 else totals.p0_bits += 1;
            try row(writer, case, property, group[2], observed.old[@intFromEnum(property)], observed.new[@intFromEnum(property)], &totals);
            try writer.flush();
        }
    }
    try floors(precision.entries.len, totals.precision_bits, totals.p0_bits, totals.contrast_bits);
    if (totals.cases != 90 or totals.property_rows != 282) return error.ExecutedFloorChanged;
    const extra_count = try extended(init, writer, scratch, selected, &totals);
    if (totals.cases != 90 + extra_count or totals.property_rows != 282 + 5 * extra_count) return error.ExecutedFloorChanged;
    try line(writer, .{ .record = "summary", .totals = totals, .precision_entries = precision.entries.len, .frozen_expected_bits = expected_bits, .p0_fixtures = p0.fixtures.len, .contrasts = p0.contrasts.len });
    try writer.flush();
    std.debug.print("flow shadow: {d} cases, {d} properties, {d} expectation misses, {d} verdict differences, {d} diagnostic differences, {d} unresolved, {d} source errors, {d} not applicable\n", .{
        totals.cases, totals.property_rows, totals.mismatches, totals.differences, totals.diagnostic_differences, totals.unresolved, totals.source_errors, totals.not_applicable,
    });
    return totals.mismatches == 0 and totals.unresolved == 0 and totals.source_errors == 0 and totals.diagnostic_differences == 0;
}

pub fn main(init: std.process.Init) !void {
    if (!try run(init)) std.process.exit(1);
}

test "shadow verdicts distinguish a counterexample from unknown provenance" {
    try std.testing.expectEqual(Status.PROVEN, try verdict(true, false));
    try std.testing.expectEqual(Status.REFUSED, try verdict(false, true));
    try std.testing.expectEqual(Status.UNPROVEN, try verdict(false, false));
    try std.testing.expectError(error.ContradictoryFlowVerdict, verdict(true, true));
    try std.testing.expect(!accepts(.refuse_or_unprove, .PROVEN));
    try std.testing.expect(!accepts(.refuse_or_unprove, .NO_VERDICT));
    try std.testing.expect(accepts(.refuse_or_unprove, .UNPROVEN));
    try std.testing.expect(!codeWitnesses("ZTS407", .no_secret_leakage));
    try std.testing.expect(codeWitnesses("ZTS402", .no_secret_leakage));
}

test "shadow floors reject every missing corpus dimension" {
    try floors(48, 214, 38, 4);
    try std.testing.expectError(error.FrozenFloorChanged, floors(47, 214, 38, 4));
    try std.testing.expectError(error.FrozenFloorChanged, floors(48, 213, 38, 4));
    try std.testing.expectError(error.FrozenFloorChanged, floors(48, 214, 37, 4));
    try std.testing.expectError(error.FrozenFloorChanged, floors(48, 214, 38, 3));
}

test "shadow modes reject unknown flags and retain census verdict strength" {
    const selected = try selection(&.{ "--census", "--codegen", "--diagnostic-corpus" });
    try std.testing.expect(selected.census and selected.codegen and selected.diagnostic_corpus);
    try std.testing.expectError(error.UnexpectedArguments, selection(&.{"--ignore-unresolved"}));
    try std.testing.expect(!accepts(probeExpectation(.refuse), .UNPROVEN));
    try std.testing.expect(accepts(probeExpectation(.hold_or_unprove), .UNPROVEN));
    try std.testing.expect(!accepts(probeExpectation(.hold_or_unprove), .REFUSED));
    _ = inputs;
}

test "diagnostic comparison preserves duplicate witnesses and exact text" {
    const allocator = std.testing.allocator;
    var evidence: Evidence = .{};
    defer evidence.production.deinit(allocator);
    defer evidence.shadow.deinit(allocator);
    try evidence.production.appendSlice(allocator, &.{ "same", "same" });
    try evidence.shadow.append(allocator, "same");
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var totals: Totals = .{};
    const case: Case = .{ .group = "probe", .name = "duplicates", .path = "handler.ts" };
    try compareDiagnostics(&output.writer, case, evidence, &totals);
    try std.testing.expectEqual(@as(usize, 1), totals.diagnostic_differences);
    try evidence.shadow.append(allocator, "same");
    totals = .{};
    try compareDiagnostics(&output.writer, case, evidence, &totals);
    try std.testing.expectEqual(@as(usize, 0), totals.diagnostic_differences);
    evidence.shadow.items[1] = "changed text";
    try compareDiagnostics(&output.writer, case, evidence, &totals);
    try std.testing.expectEqual(@as(usize, 2), totals.diagnostic_differences);
}

test "shadow evidence preserves actual path request I O and guard values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sources = [_][]const u8{
        "import { env } from \"zttp:env\"; function handler(req) { if (req.path === \"/leak\") return Response.text(env(\"API_TOKEN\")); return Response.text(\"public\"); }",
        "import { escapeHtml } from \"zttp:text\"; function handler(req) { return Response.html(escapeHtml(req.url)); }",
    };
    var found_witness = false;
    var found_guard = false;
    for (sources) |source| {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        var diagnostics: Evidence = .{};
        var totals: Totals = .{};
        _ = try shadow(allocator, &output.writer, .{ .group = "probe", .name = "evidence", .path = "flow-evidence.ts" }, source, &totals, &diagnostics);
        var records = std.mem.tokenizeScalar(u8, output.written(), '\n');
        while (records.next()) |record| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, record, .{});
            defer parsed.deinit();
            const object = parsed.value.object;
            const kind = object.get("record").?.string;
            if (std.mem.eql(u8, kind, "shadow_witness") and object.get("candidate").? != .null) {
                const candidate = object.get("candidate").?.object;
                try std.testing.expectEqualStrings("not_run", object.get("runtime_replay").?.string);
                try std.testing.expectEqualStrings("/leak", candidate.get("request").?.object.get("url").?.string);
                const constraints = object.get("witness").?.object.get("path_constraints").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), constraints.len);
                try std.testing.expectEqualStrings("/leak", constraints[0].object.get("req_path").?.string);
                const calls = object.get("witness").?.object.get("io_calls").?.array.items;
                try std.testing.expectEqual(@as(usize, 1), calls.len);
                try std.testing.expectEqualStrings("env", calls[0].object.get("func").?.string);
                const stubs = candidate.get("io_stubs").?.array.items;
                try std.testing.expectEqual(@as(i64, 0), stubs[0].object.get("seq").?.integer);
                try std.testing.expectEqualStrings("\"secret-sentinel\"", stubs[0].object.get("result_json").?.string);
                var replay = std.mem.tokenizeScalar(u8, candidate.get("replay_jsonl").?.string, '\n');
                var replay_rows: usize = 0;
                while (replay.next()) |row_bytes| {
                    const replay_row = try std.json.parseFromSlice(std.json.Value, allocator, row_bytes, .{});
                    defer replay_row.deinit();
                    replay_rows += 1;
                    try std.testing.expect(replay_row.value.object.contains("type"));
                }
                try std.testing.expectEqual(@as(usize, 3), replay_rows);
                found_witness = true;
            }
            if (std.mem.eql(u8, kind, "shadow_defended_paths")) for (object.get("paths").?.array.items) |path| {
                if (path.object.get("guard_func").? == .null) continue;
                if (!std.mem.eql(u8, path.object.get("property").?.string, "injection_safe")) continue;
                try std.testing.expectEqualStrings("validated", path.object.get("safe_form").?.string);
                try std.testing.expectEqualStrings("escapeHtml", path.object.get("guard_func").?.string);
                try std.testing.expectEqualStrings("Response.html", path.object.get("sink_label").?.string);
                found_guard = true;
            };
        }
    }
    try std.testing.expect(found_witness);
    try std.testing.expect(found_guard);
}

test "production evidence retains public counterexample and resisted objects" {
    const allocator = std.testing.allocator;
    var trace: std.Io.Writer.Allocating = .init(allocator);
    defer trace.deinit();
    try compiler.proof_trace.writeJson(&trace.writer, &.{
        .{ .property = "no_secret_leakage", .holds = false, .kind = .flow_trace, .summary = "secret", .counterexample = .{ .kind = .flow_chain, .line = 7, .column = 9, .flow = &.{ "env() call", "response" }, .request_method = "POST", .request_url = "/leak", .request_has_auth = true, .fix = "drop secret" } },
        .{ .property = "injection_safe", .holds = true, .kind = .flow_trace, .summary = "escaped", .resisted = .{ .attack_input = "<script>", .chain = &.{ "request", "escapeHtml", "Response.html" }, .conclusion = "escaped at sink" } },
    });
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try recordProductionEvidence(allocator, &output.writer, .{ .group = "probe", .name = "public-trace", .path = "handler.ts" }, trace.written());
    var records = std.mem.tokenizeScalar(u8, output.written(), '\n');
    const failed = try std.json.parseFromSlice(std.json.Value, allocator, records.next().?, .{});
    defer failed.deinit();
    const counterexample = failed.value.object.get("counterexample").?.object;
    try std.testing.expectEqualStrings("/leak", counterexample.get("request").?.object.get("url").?.string);
    try std.testing.expect(counterexample.get("request").?.object.get("hasAuthHeader").?.bool);
    try std.testing.expectEqual(@as(i64, 7), counterexample.get("sink").?.object.get("line").?.integer);
    try std.testing.expect(failed.value.object.get("resisted").? == .null);
    const held = try std.json.parseFromSlice(std.json.Value, allocator, records.next().?, .{});
    defer held.deinit();
    try std.testing.expect(held.value.object.get("counterexample").? == .null);
    const resisted = held.value.object.get("resisted").?.object;
    try std.testing.expectEqualStrings("escapeHtml", resisted.get("chain").?.array.items[1].string);
    try std.testing.expectEqualStrings("<script>", resisted.get("attackInput").?.string);
    try std.testing.expect(records.next() == null);
}
