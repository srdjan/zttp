//! pi_repair_plan - compile a handler proof failure into typed repair plans.

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const property_goals = @import("../property_goals.zig");
const counterexample = zts.counterexample;
const flow_checker = zts.flow_checker;
const writeJsonString = zts.writeJsonString;
const repair_plan = zts.repair_plan;

const name = "pi_repair_plan";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "repair-plan",
    .effect = .persist_agent_state,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Generate compiler-native typed repair plans for a handler.
    \\The tool runs handler verification and property witness analysis,
    \\then returns structured repair intents for the narrow supported v1
    \\cases: unchecked Result.value, unchecked optional use, missing
    \\fallback Response, no_secret_leakage, no_credential_leakage,
    \\injection_safe, input_validated, and pii_contained. The compiler
    \\does not edit files; apply one plan,
    \\then re-run the veto / goal check until the proof passes.
    ,
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"goals":{"type":"array","items":{"type":"string"}}},"required":["path"]}
    ,
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidToolArgsJson;
    const obj = parsed.value.object;

    const path_val = obj.get("path") orelse return error.InvalidToolArgsJson;
    if (path_val != .string) return error.InvalidToolArgsJson;

    var goals_count: usize = 0;
    if (obj.get("goals")) |g| {
        if (g != .array) return error.InvalidToolArgsJson;
        goals_count = g.array.items.len;
    }

    const out = try allocator.alloc([]const u8, 1 + goals_count);
    errdefer allocator.free(out);
    out[0] = try allocator.dupe(u8, path_val.string);

    if (obj.get("goals")) |g| {
        for (g.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidToolArgsJson;
            out[i + 1] = try allocator.dupe(u8, item.string);
        }
    }
    return out;
}

fn parseGoal(s: []const u8) ?counterexample.PropertyTag {
    return property_goals.parseDriveableGoal(s);
}

pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a path\n");

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, args[0]);
    defer allocator.free(absolute);

    const source = zts.file_io.readFile(allocator, absolute, common.default_output_limit) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": failed to read {s}: {s}\n",
            .{ args[0], @errorName(e) },
        );
    };
    defer allocator.free(source);

    return planFromSource(allocator, source, args[0], args[1..], true);
}

/// Run handler verification + property-witness analysis over an in-memory
/// source snapshot and return the typed repair-plan JSON. `rel_path` is the
/// workspace-relative handler path used only to key the witness corpus; the
/// `source` bytes (not the file on disk at `rel_path`) are analyzed, so a
/// draft that has not been written yet can still be planned. `goal_args` are
/// goal name strings; an empty slice means the default supported goal set.
/// `persist_witnesses` controls whether materialised witnesses are written to
/// the on-disk corpus: the tool path persists, but the in-loop auto-repair
/// feedback lane passes false so computing retry guidance stays side-effect
/// free (no cwd-relative writes).
pub fn planFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    rel_path: []const u8,
    goal_args: []const []const u8,
    persist_witnesses: bool,
) anyerror!registry_mod.ToolResult {
    var goals: std.ArrayListUnmanaged(counterexample.PropertyTag) = .empty;
    defer goals.deinit(allocator);
    if (goal_args.len == 0) {
        try goals.appendSlice(allocator, &property_goals.supported_goals);
    } else {
        for (goal_args) |g| {
            const tag = parseGoal(g) orelse {
                return registry_mod.ToolResult.errFmt(allocator, name ++ ": unknown goal {s}\n", .{g});
            };
            try goals.append(allocator, tag);
        }
    }

    var prepared = zts.PreparedSource.init(allocator, source, rel_path, .{ .comptime_env = .{} }) catch |e| {
        return registry_mod.ToolResult.errFmt(allocator, name ++ ": TypeScript strip failed: {s}\n", .{@errorName(e)});
    };
    defer prepared.deinit();

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const program_root = js_parser.parse() catch |e| {
        return registry_mod.ToolResult.errFmt(allocator, name ++ ": parse failed: {s}\n", .{@errorName(e)});
    };
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);
    const handler_fn = zts.findHandlerFunction(ir_view, program_root) orelse {
        return registry_mod.ToolResult.err(allocator, name ++ ": no handler function found in file\n");
    };

    var verifier = zts.HandlerVerifier.init(allocator, ir_view, &atoms, null, null);
    defer verifier.deinit();
    _ = try verifier.verify(handler_fn);

    var checker = zts.FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();

    const policy_hash = zts.policyHash();
    try w.writeAll("{\"ok\":");
    const has_failures = hasVerifierErrors(verifier.getDiagnostics()) or
        hasRequestedFlowDiagnostics(checker.getDiagnostics(), goals.items);
    try w.writeAll(if (has_failures) "false" else "true");
    try w.writeAll(",\"policy_hash\":\"");
    try w.writeAll(&policy_hash);
    try w.writeAll("\",\"goals\":[");
    for (goals.items, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, g.asString());
    }
    try w.writeAll("],\"diagnostics\":[");

    var plan_index: usize = 0;
    var diag_index: usize = 0;
    var first_diag = true;
    for (verifier.getDiagnostics()) |diag| {
        const loc = ir_view.getLoc(diag.node) orelse continue;
        if (!first_diag) try w.writeByte(',');
        first_diag = false;
        diag_index += 1;
        const diag_id = try std.fmt.allocPrint(allocator, "diag_{d:0>3}", .{diag_index});
        defer allocator.free(diag_id);
        try writeVerifierDiagnostic(w, diag_id, diag, loc.line, loc.column);
    }
    try w.writeAll("],\"witnesses\":[");

    // Persist materialised witnesses into the on-disk corpus. The corpus
    // is keyed by the workspace-relative handler path (rel_path) so the
    // same handler maps to the same directory across tool invocations.
    // Failures here are non-fatal: the repair plan still surfaces, just
    // without persistence.
    const corpus_dir = if (persist_witnesses)
        (zts.witness_corpus.corpusDir(allocator, rel_path) catch null)
    else
        null;
    defer if (corpus_dir) |d| allocator.free(d);
    if (corpus_dir) |d| {
        zts.witness_corpus.ensureCorpusDir(allocator, d, rel_path) catch {};
    }

    var first_witness = true;
    var witness_index: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        // Share the projection with the compiler's own witness persistence, so
        // a repair plan and the on-disk corpus never disagree about what a
        // diagnostic's witness contains.
        const projection = zts.DiagnosticProjection.projectFlowWitness(diag, ir_view) orelse continue;
        if (!goalRequested(goals.items, projection.property)) continue;
        var witness = zts.solveCounterexample(allocator, .{
            .property = projection.property,
            .origin = .{ .line = projection.line, .column = projection.column },
            .sink = .{ .line = projection.line, .column = projection.column },
            .summary = projection.summary,
            .constraints = projection.constraints,
            .io_calls = projection.io_calls,
        }) catch continue;
        defer witness.deinit(allocator);

        if (corpus_dir) |d| {
            if (zts.witness_corpus.persist(allocator, d, witness)) |pres| {
                var owned = pres;
                owned.deinit(allocator);
            } else |_| {}
        }

        if (!first_witness) try w.writeByte(',');
        first_witness = false;
        witness_index += 1;
        const witness_id = try std.fmt.allocPrint(allocator, "wit_{d:0>3}", .{witness_index});
        defer allocator.free(witness_id);
        try writeWitness(w, witness_id, diag, witness);
    }

    try w.writeAll("],\"plans\":[");
    var first_plan = true;
    diag_index = 0;
    for (verifier.getDiagnostics()) |diag| {
        const loc = ir_view.getLoc(diag.node) orelse continue;
        diag_index += 1;
        const plan = repair_plan.fromVerifierDiagnostic(diag, .{ .line = loc.line, .column = loc.column }) orelse continue;
        const subject_name = repairSubjectName(ir_view, &atoms, diag);
        plan_index += 1;
        if (!first_plan) try w.writeByte(',');
        first_plan = false;
        try writePlan(w, allocator, plan_index, plan, "diag", diag_index, subject_name);
    }

    witness_index = 0;
    for (checker.getDiagnostics()) |diag| {
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (!goalRequested(goals.items, tag)) continue;
        const loc = ir_view.getLoc(diag.node) orelse continue;
        witness_index += 1;
        const plan = repair_plan.fromFlowDiagnostic(diag, tag, .{ .line = loc.line, .column = loc.column }) orelse continue;
        plan_index += 1;
        if (!first_plan) try w.writeByte(',');
        first_plan = false;
        try writePlan(w, allocator, plan_index, plan, "wit", witness_index, null);
    }
    try w.writeAll("]}\n");

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    return .{ .ok = !has_failures, .llm_text = llm_text };
}

fn writeVerifierDiagnostic(
    writer: *std.Io.Writer,
    id: []const u8,
    diag: zts.VerifierDiagnostic,
    line: u32,
    column: u32,
) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, @tagName(diag.kind));
    try writer.writeAll(",\"severity\":");
    try writeJsonString(writer, diag.severity.label());
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{column});
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, diag.message);
    if (diag.help) |help| {
        try writer.writeAll(",\"help\":");
        try writeJsonString(writer, help);
    }
    try writer.writeByte('}');
}

fn writeWitness(
    writer: *std.Io.Writer,
    id: []const u8,
    diag: flow_checker.Diagnostic,
    witness: counterexample.CounterexampleWitness,
) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"property\":");
    try writeJsonString(writer, witness.property.asString());
    try writer.writeAll(",\"summary\":");
    try writeJsonString(writer, diag.message);
    try writer.writeAll(",\"origin\":{\"line\":");
    try writer.print("{d}", .{witness.origin.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{witness.origin.column});
    try writer.writeAll("},\"sink\":{\"line\":");
    try writer.print("{d}", .{witness.sink.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{witness.sink.column});
    try writer.writeAll("},\"request\":{\"method\":");
    try writeJsonString(writer, witness.request.method);
    try writer.writeAll(",\"url\":");
    try writeJsonString(writer, witness.request.url);
    try writer.writeAll(",\"has_auth_header\":");
    try writer.writeAll(if (witness.request.has_auth_header) "true" else "false");
    try writer.writeAll("},\"io_stubs\":[");
    for (witness.io_stubs, 0..) |stub, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"seq\":");
        try writer.print("{d}", .{stub.seq});
        try writer.writeAll(",\"module\":");
        try writeJsonString(writer, stub.module);
        try writer.writeAll(",\"fn\":");
        try writeJsonString(writer, stub.func);
        try writer.writeAll(",\"result\":");
        try writer.writeAll(stub.result_json);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writePlan(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    index: usize,
    plan: repair_plan.Plan,
    closes_prefix: []const u8,
    closes_index: usize,
    subject_name: ?[]const u8,
) !void {
    const id = try std.fmt.allocPrint(allocator, "rp_{d:0>3}", .{index});
    defer allocator.free(id);
    const closes = try std.fmt.allocPrint(allocator, "{s}_{d:0>3}", .{ closes_prefix, closes_index });
    defer allocator.free(closes);
    const template = try concreteTemplate(allocator, plan, subject_name);
    defer allocator.free(template);

    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, plan.kind.asString());
    try writer.writeAll(",\"target\":{\"line\":");
    try writer.print("{d}", .{plan.target.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{plan.target.column});
    try writer.writeAll("},\"behavioral_change\":");
    try writer.writeAll(if (plan.behavioral_change) "true" else "false");
    try writer.writeAll(",\"summary\":");
    try writeJsonString(writer, plan.summary);
    try writer.writeAll(",\"edit_intent\":{\"kind\":");
    try writeJsonString(writer, plan.edit_intent.kind.asString());
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{plan.edit_intent.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{plan.edit_intent.column});
    try writer.writeAll(",\"template\":");
    try writeJsonString(writer, template);
    if (subject_name) |name_text| {
        try writer.writeAll(",\"bindings\":{\"subject\":");
        try writeJsonString(writer, name_text);
        try writer.writeByte('}');
    }
    try writer.writeAll("},\"closes\":[");
    try writeJsonString(writer, closes);
    try writer.writeAll("]}");
}

pub fn concreteTemplate(
    allocator: std.mem.Allocator,
    plan: repair_plan.Plan,
    subject_name: ?[]const u8,
) ![]u8 {
    return switch (plan.kind) {
        .check_result_before_value => {
            const name_text = subject_name orelse "result";
            return std.fmt.allocPrint(
                allocator,
                "if (!{s}.ok) return Response.json({{ error: {s}.error }}, {{ status: 400 }});",
                .{ name_text, name_text },
            );
        },
        .narrow_optional_before_use => {
            const name_text = subject_name orelse "value";
            return std.fmt.allocPrint(
                allocator,
                "if ({s} === undefined) return Response.json({{ error: \"missing value\" }}, {{ status: 400 }});",
                .{name_text},
            );
        },
        else => allocator.dupe(u8, plan.edit_intent.template),
    };
}

pub fn repairSubjectName(
    ir_view: zts.IrView,
    atoms: *zts.AtomTable,
    diag: zts.VerifierDiagnostic,
) ?[]const u8 {
    return switch (diag.kind) {
        .unchecked_result_value, .unchecked_optional_access => memberObjectName(ir_view, atoms, diag.node),
        .unchecked_optional_use => identifierName(ir_view, atoms, diag.node),
        else => null,
    };
}

fn memberObjectName(
    ir_view: zts.IrView,
    atoms: *zts.AtomTable,
    node: zts.parser.NodeIndex,
) ?[]const u8 {
    const tag = ir_view.getTag(node) orelse return null;
    if (tag == .identifier) return identifierName(ir_view, atoms, node);
    if (tag != .member_access and tag != .optional_chain) return null;
    const member = ir_view.getMember(node) orelse return null;
    return identifierName(ir_view, atoms, member.object);
}

fn identifierName(
    ir_view: zts.IrView,
    atoms: *zts.AtomTable,
    node: zts.parser.NodeIndex,
) ?[]const u8 {
    const tag = ir_view.getTag(node) orelse return null;
    if (tag != .identifier) return null;
    const binding = ir_view.getBinding(node) orelse return null;
    // `slot` identifies storage for locals, arguments, and upvalues. The parser
    // keeps the source-level identifier in `name_atom` for every binding kind.
    return atoms.getName(@enumFromInt(binding.name_atom));
}

fn hasRequestedFlowDiagnostics(
    diagnostics: []const flow_checker.Diagnostic,
    goals: []const counterexample.PropertyTag,
) bool {
    for (diagnostics) |diag| {
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (goalRequested(goals, tag)) return true;
    }
    return false;
}

fn hasVerifierErrors(diagnostics: []const zts.VerifierDiagnostic) bool {
    for (diagnostics) |diag| {
        if (diag.severity == .err) return true;
    }
    return false;
}

fn goalRequested(goals: []const counterexample.PropertyTag, tag: counterexample.PropertyTag) bool {
    for (goals) |g| if (g == tag) return true;
    return false;
}

const testing = std.testing;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwdPathAlloc = @import("../test_support/cwd.zig").cwdPathAlloc;

test "decodeJson accepts path and goals" {
    const args = try decodeJson(testing.allocator, "{\"path\":\"h.ts\",\"goals\":[\"injection_safe\"]}");
    defer {
        for (args) |arg| testing.allocator.free(arg);
        testing.allocator.free(args);
    }
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("h.ts", args[0]);
    try testing.expectEqualStrings("injection_safe", args[1]);
}

test "parseGoal accepts every property the solver models" {
    try testing.expectEqual(counterexample.PropertyTag.no_secret_leakage, parseGoal("no_secret_leakage").?);
    try testing.expectEqual(counterexample.PropertyTag.no_credential_leakage, parseGoal("no_credential_leakage").?);
    try testing.expectEqual(counterexample.PropertyTag.injection_safe, parseGoal("injection_safe").?);
    try testing.expectEqual(counterexample.PropertyTag.input_validated, parseGoal("input_validated").?);
    try testing.expectEqual(counterexample.PropertyTag.pii_contained, parseGoal("pii_contained").?);
    // A structural fact is not a goal: no falsifying input to aim at.
    try testing.expect(parseGoal("read_only") == null);
}

test "execute rejects a property the solver does not model" {
    // See pi_goal_check: `read_only` is a structural fact, not a goal with a
    // counterexample to drive toward.
    var result = try execute(testing.allocator, &.{ "examples/handler/handler.ts", "read_only" });
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "unknown goal read_only") != null);
}

test "planFromSource plans repairs from an in-memory draft" {
    const source =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = validateJson("item", req.body);
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{}, false);
    defer result.deinit(testing.allocator);
    // The draft accesses result.value without checking result.ok: a failure
    // with a concrete check_result_before_value repair template.
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"plans\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (!result.ok)") != null);
}

test "planFromSource preserves a local optional binding name in its repair" {
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const appName = env("APP_NAME");
        \\  return Response.json({ appName: appName });
        \\}
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{}, false);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (appName === undefined)") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (value === undefined)") == null);
}

test "planFromSource prepares TSX before analysis" {
    const source =
        \\export function handler(req: Request): Response {
        \\  const view = <div />;
        \\  return Response.text("ok");
        \\}
    ;
    var result = try planFromSource(std.testing.allocator, source, "handler.tsx", &.{}, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.llm_text, "parse failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.llm_text, "\"policy_hash\"") != null);
}

test "an unreadable path is reported as the caller wrote it, not as an absolute path" {
    // The message goes into the transcript, which a recorded flow replays from
    // a different directory. Printing the resolved absolute path made this
    // failure text differ between the recording and its replay, so a case whose
    // agent asked for a missing file could never promote.
    var tree = try IsolatedTmp.init(testing.allocator, "repair-plan-missing-file");
    defer tree.cleanup(testing.allocator);
    const saved_cwd = try cwdPathAlloc(testing.allocator);
    defer testing.allocator.free(saved_cwd);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};
    try std.Io.Threaded.chdir(tree.abs_path);

    var result = try execute(testing.allocator, &.{"handler.ts"});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expectEqualStrings(
        "pi_repair_plan: failed to read handler.ts: FileNotFound\n",
        result.llm_text,
    );
    try testing.expect(std.mem.indexOf(u8, result.llm_text, tree.abs_path) == null);
}

test "a persisting plan reads the same from two different workspaces" {
    // The flow recorder captures this tool's result into a transcript and
    // replays it from a fresh directory. Any part of the output that depends on
    // where the run lives makes the replayed transcript differ from the
    // recorded one, which fails the case rather than the tool.
    const source =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = validateJson("item", req.body);
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;

    var first_tree = try IsolatedTmp.init(testing.allocator, "repair-plan-workspace-a");
    defer first_tree.cleanup(testing.allocator);
    var second_tree = try IsolatedTmp.init(testing.allocator, "repair-plan-workspace-b");
    defer second_tree.cleanup(testing.allocator);

    const saved_cwd = try cwdPathAlloc(testing.allocator);
    defer testing.allocator.free(saved_cwd);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    try std.Io.Threaded.chdir(first_tree.abs_path);
    var first = try planFromSource(testing.allocator, source, "handler.ts", &.{}, true);
    defer first.deinit(testing.allocator);
    const first_text = try testing.allocator.dupe(u8, first.llm_text);
    defer testing.allocator.free(first_text);

    try std.Io.Threaded.chdir(second_tree.abs_path);
    var second = try planFromSource(testing.allocator, source, "handler.ts", &.{}, true);
    defer second.deinit(testing.allocator);

    try testing.expectEqualStrings(first_text, second.llm_text);
}

test "tool description names repair plan authority boundary" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "does not edit files") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "unchecked Result.value") != null);
}

test "concreteTemplate uses extracted subject names" {
    const plan = repair_plan.fromVerifierDiagnostic(
        .{
            .severity = .err,
            .kind = .unchecked_result_value,
            .node = 0,
            .message = "result.value accessed without checking result.ok first",
            .help = null,
        },
        .{ .line = 8, .column = 12 },
    ) orelse return error.MissingPlan;
    const template = try concreteTemplate(testing.allocator, plan, "authResult");
    defer testing.allocator.free(template);
    try testing.expect(std.mem.indexOf(u8, template, "authResult.ok") != null);
    try testing.expect(std.mem.indexOf(u8, template, "authResult.error") != null);
}
