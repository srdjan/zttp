//! pi_repair_plan - compile a handler proof failure into typed repair plans.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const property_goals = @import("../property_goals.zig");
const pi_goal_check = @import("pi_goal_check.zig");
const repair_apply = @import("repair_apply.zig");
const counterexample = zts.counterexample;
const flow_checker = zts.flow_checker;
const writeJsonString = zts.writeJsonString;
const repair_plan = zts.repair_plan;

const name = "pi_repair_plan";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "repair-plan",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Generate compiler-native repair plans for a handler.
    \\The tool runs the production check and reports every rejection with
    \\at least one plan. A plan with an edit template, such as an
    \\unchecked Result.value guard, is a concrete edit. An
    \\apply_repair_intent plan names a repair intent in edit_intent.kind:
    \\pass it to pi_apply_repair_plan. A follow_diagnostic_help plan has
    \\edit_intent.kind manual_edit: follow its summary by hand, because no
    \\tool applies it. ok is false while any rejection remains. The
    \\compiler does not edit files; apply one plan,
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

    return planFromSource(allocator, source, args[0], args[1..]);
}

/// Run handler verification + property-witness analysis over an in-memory
/// source snapshot and return the typed repair-plan JSON. `rel_path` is the
/// workspace-relative handler path used for source preparation; the
/// `source` bytes (not the file on disk at `rel_path`) are analyzed, so a
/// draft that has not been written yet can still be planned. `goal_args` are
/// goal name strings; an empty slice means the default supported goal set.
pub fn planFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    rel_path: []const u8,
    goal_args: []const []const u8,
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

    var observed: Observed = .{
        .allocator = allocator,
        .goals = goals.items,
        .source_view = .{ .text = source, .normalize_positions = true },
        .diagnostics = registry_mod.helpers.TextBuffer.init(allocator),
        .witnesses = registry_mod.helpers.TextBuffer.init(allocator),
        .plans = registry_mod.helpers.TextBuffer.init(allocator),
    };
    defer observed.deinit();

    var check = common.runProductionCheck(allocator, source, rel_path, .{
        .context = &observed,
        .on_checked = onChecked,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return registry_mod.ToolResult.errFmt(allocator, name ++ ": production check failed: {s}\n", .{@errorName(e)}),
    };
    defer check.deinit(allocator);

    // The check stopped before the verifier. A file with no handler that passed
    // every earlier stage keeps its error. Any other early stop is a refusal that
    // `zts check` reports, and the tool reports it too (Decision 46(a)). The
    // diagnostics list cannot tell the two apart: the spec stage adds a ZTS500 to
    // a file with no handler.
    if (!observed.ran) {
        if (common.hasNoHandler(&check)) {
            return registry_mod.ToolResult.err(allocator, name ++ ": no handler function found in file\n");
        }
        try writeEarlyStop(&observed, check.json_diagnostics.items);
    } else {
        try writeProductionRest(&observed, check.json_diagnostics.items);
    }

    // `properties` and `flow_unresolved` are set after the observer runs.
    const unproven = try pi_goal_check.unprovenFromCheck(allocator, &check, goals.items);
    defer allocator.free(unproven);
    const has_failures = !observed.ran or observed.has_failures or observed.reported_error or unproven.len > 0;

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    const policy_hash = zts.policyHash();
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (has_failures) "false" else "true");
    try w.writeAll(",\"policy_hash\":\"");
    try w.writeAll(&policy_hash);
    try w.writeAll("\",\"goals\":[");
    for (goals.items, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, g.asString());
    }
    try w.writeAll("],\"diagnostics\":[");
    try w.writeAll(observed.diagnostics.written());
    try w.writeAll("],\"witnesses\":[");
    try w.writeAll(observed.witnesses.written());
    try w.writeAll("],\"plans\":[");
    try w.writeAll(observed.plans.written());
    try w.writeAll("]}\n");

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    return .{ .ok = !has_failures, .llm_text = llm_text };
}

/// A requested-goal flow diagnostic that `fromFlowDiagnostic` gave no plan.
/// The production diagnostic with the same code and position gets a help plan.
const UnplannedFlow = struct {
    code: []const u8,
    line: u32,
    column: u32,
    witness_index: usize,
};

/// State the production check's observer fills. The three buffers hold the
/// diagnostics, witnesses, and plans lists without their brackets.
const Observed = struct {
    allocator: std.mem.Allocator,
    goals: []const counterexample.PropertyTag,
    /// Maps the observer's raw positions to the ones `zts check --json` reports.
    source_view: zts.SourceView,
    diagnostics: registry_mod.helpers.TextBuffer,
    witnesses: registry_mod.helpers.TextBuffer,
    plans: registry_mod.helpers.TextBuffer,
    unplanned_flow: std.ArrayListUnmanaged(UnplannedFlow) = .empty,
    diag_count: usize = 0,
    plan_count: usize = 0,
    ran: bool = false,
    has_failures: bool = false,
    /// True when the tool reported a production diagnostic of error severity.
    reported_error: bool = false,

    fn deinit(self: *Observed) void {
        self.diagnostics.deinit();
        self.witnesses.deinit();
        self.plans.deinit();
        self.unplanned_flow.deinit(self.allocator);
    }
};
fn onChecked(context: *anyopaque, view: zts_cli.precompile.CheckedView) error{OutOfMemory}!void {
    const observed: *Observed = @ptrCast(@alignCast(context));
    writeObserved(observed, view) catch |e| switch (e) {
        // A write into the in-memory buffer fails only when it cannot grow.
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    observed.ran = true;
}

/// Write the production diagnostics of an early stop, then one plan for each
/// error. The verifier did not run, so there is no other list to extend.
fn writeEarlyStop(
    observed: *Observed,
    diagnostics: []const zts_cli.json_diagnostics.JsonDiagnostic,
) !void {
    for (diagnostics) |diag| try appendProductionDiagnostic(observed, diag);
}

/// After the verifier ran: append each production diagnostic that is neither a
/// verifier nor a flow diagnostic, then a help plan for each requested-goal
/// flow error that got no flow plan.
fn writeProductionRest(
    observed: *Observed,
    diagnostics: []const zts_cli.json_diagnostics.JsonDiagnostic,
) !void {
    for (diagnostics) |diag| {
        if (common.isCodeFrom(.verifier, diag.code) or common.isCodeFrom(.flow, diag.code)) continue;
        try appendProductionDiagnostic(observed, diag);
    }
    for (observed.unplanned_flow.items) |entry| {
        for (diagnostics) |diag| {
            if (diag.line != entry.line or diag.column != entry.column) continue;
            if (!std.mem.eql(u8, diag.code, entry.code)) continue;
            if (!std.mem.eql(u8, diag.severity, "error")) break;
            observed.reported_error = true;
            try appendProductionPlan(observed, diag, "wit", entry.witness_index);
            break;
        }
    }
}

/// The repair intent of `diag` when the apply step can run it.
fn supportedIntent(diag: zts_cli.json_diagnostics.JsonDiagnostic) ?zts.RepairIntent {
    const intent = diag.repair_intent orelse return null;
    _ = repair_apply.RepairKind.fromString(intent.asString()) orelse return null;
    return intent;
}

fn appendProductionPlan(
    observed: *Observed,
    diag: zts_cli.json_diagnostics.JsonDiagnostic,
    closes_prefix: []const u8,
    closes_index: usize,
) !void {
    const plan = repair_plan.fromProductionDiagnostic(.{
        .line = diag.line,
        .column = diag.column,
        .help = diag.suggestion,
        .result_shape = diag.result_shape,
        .supported_intent = supportedIntent(diag),
    });
    observed.plan_count += 1;
    const w = observed.plans.writer();
    if (observed.plan_count > 1) try w.writeByte(',');
    try writePlan(w, observed.allocator, observed.plan_count, plan, closes_prefix, closes_index, diag.result_subject);
}

/// Append `diag` to the diagnostics list and, for an error, its plan.
fn appendProductionDiagnostic(
    observed: *Observed,
    diag: zts_cli.json_diagnostics.JsonDiagnostic,
) !void {
    const w = observed.diagnostics.writer();
    if (observed.diag_count > 0) try w.writeByte(',');
    observed.diag_count += 1;
    try common.writeProductionDiagnostic(w, observed.diag_count, diag);
    if (!std.mem.eql(u8, diag.severity, "error")) return;
    observed.reported_error = true;
    try appendProductionPlan(observed, diag, "diag", observed.diag_count);
}

fn writeObserved(observed: *Observed, view: zts_cli.precompile.CheckedView) !void {
    const allocator = observed.allocator;
    const goals = observed.goals;
    const ir_view = view.ir_view;
    const dw = observed.diagnostics.writer();
    const ww = observed.witnesses.writer();
    const pw = observed.plans.writer();
    observed.has_failures = hasVerifierErrors(view.verifier_diagnostics) or
        hasRequestedFlowDiagnostics(view.flow_diagnostics, goals);

    for (view.verifier_diagnostics) |diag| {
        const loc = mappedLoc(observed, ir_view, diag.node) orelse continue;
        if (observed.diag_count > 0) try dw.writeByte(',');
        observed.diag_count += 1;
        const diag_id = try allocator.print("diag_{d:0>3}", .{observed.diag_count});
        defer allocator.free(diag_id);
        try writeVerifierDiagnostic(dw, diag_id, diag, loc.line, loc.column);
    }

    var witness_index: usize = 0;
    for (view.flow_diagnostics) |diag| {
        // Use the shared diagnostic projection for counterexample generation.
        const projection = zts.DiagnosticProjection.projectFlowWitness(diag, ir_view) orelse continue;
        if (!goalRequested(goals, projection.property)) continue;
        const at = observed.source_view.position(projection.line, projection.column);
        var witness = zts.solveCounterexample(allocator, .{
            .property = projection.property,
            .origin = .{ .line = at.line, .column = at.column },
            .sink = .{ .line = at.line, .column = at.column },
            .summary = projection.summary,
            .constraints = projection.constraints,
            .io_calls = projection.io_calls,
        }) catch continue;
        defer witness.deinit(allocator);

        if (witness_index > 0) try ww.writeByte(',');
        witness_index += 1;
        const witness_id = try allocator.print("wit_{d:0>3}", .{witness_index});
        defer allocator.free(witness_id);
        try writeWitness(ww, witness_id, diag, witness);
    }

    var diag_index: usize = 0;
    for (view.verifier_diagnostics) |diag| {
        const loc = mappedLoc(observed, ir_view, diag.node) orelse continue;
        diag_index += 1;
        // A verifier error with no typed repair still gets a plan: its help text.
        const plan = repair_plan.fromVerifierDiagnostic(diag, .{ .line = loc.line, .column = loc.column }) orelse
            if (diag.severity == .err) repair_plan.fromProductionDiagnostic(.{
                .line = loc.line,
                .column = loc.column,
                .help = diag.help,
                .result_shape = null,
                .supported_intent = null,
            }) else continue;
        const subject_name = repairSubjectName(ir_view, view.atoms, diag);
        observed.plan_count += 1;
        if (observed.plan_count > 1) try pw.writeByte(',');
        try writePlan(pw, allocator, observed.plan_count, plan, "diag", diag_index, subject_name);
    }

    witness_index = 0;
    for (view.flow_diagnostics) |diag| {
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (!goalRequested(goals, tag)) continue;
        const loc = mappedLoc(observed, ir_view, diag.node) orelse continue;
        witness_index += 1;
        const plan = repair_plan.fromFlowDiagnostic(diag, tag, .{ .line = loc.line, .column = loc.column }) orelse {
            try observed.unplanned_flow.append(allocator, .{
                .code = zts.DiagnosticProjection.code(.flow, diag.kind),
                .line = loc.line,
                .column = loc.column,
                .witness_index = witness_index,
            });
            continue;
        };
        observed.plan_count += 1;
        if (observed.plan_count > 1) try pw.writeByte(',');
        try writePlan(pw, allocator, observed.plan_count, plan, "wit", witness_index, null);
    }
}

/// The position of `node` as `zts check --json` reports it.
fn mappedLoc(observed: *const Observed, ir_view: zts.IrView, node: zts.parser.NodeIndex) ?zts.SourcePosition {
    const loc = ir_view.getLoc(node) orelse return null;
    return observed.source_view.position(loc.line, loc.column);
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
    try writer.writeAll(",\"code\":");
    try writeJsonString(writer, zts.DiagnosticProjection.code(.verifier, diag.kind));
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
    const id = try allocator.print("rp_{d:0>3}", .{index});
    defer allocator.free(id);
    const closes = try allocator.print("{s}_{d:0>3}", .{ closes_prefix, closes_index });
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
    const unbound_optional = plan.kind == .narrow_optional_before_use and subject_name == null;
    try writeJsonString(writer, if (unbound_optional) repair_plan.unbound_optional_summary else plan.summary);
    try writer.writeAll(",\"edit_intent\":{\"kind\":");
    if (plan.edit_intent.repair_intent) |intent| {
        try writeJsonString(writer, intent.asString());
    } else {
        try writeJsonString(writer, plan.edit_intent.kind.asString());
    }
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
            // The template is inserted into source as code. A shape that no
            // inserted line can repair gets a comment, which is valid code and
            // carries the advice to the next retry.
            if (plan.result_shape) |shape| switch (shape) {
                .error_on_ok_path => return allocator.print("if ({s}.ok) return Response.json({{ ok: true }});", .{name_text}),
                .function_alias => return allocator.dupe(u8, "// call the Result function directly and bind the call to a const"),
                .unbound_call => return allocator.dupe(u8, "// bind the call to a const, then check its ok before you read its value"),
                .ambiguous_upvalue => return allocator.dupe(u8, "// give each Result binding in the file a unique name"),
                .depth_limit => return allocator.dupe(u8, "// split the expression into const bindings"),
                else => {},
            };
            return allocator.print("if (!{s}.ok) return Response.json({{ error: {s}.error }}, {{ status: 400 }});", .{ name_text, name_text });
        },
        .narrow_optional_before_use => {
            // No name: an inserted line cannot guard a variable that does not
            // exist, so the template is a comment that carries the advice.
            const name_text = subject_name orelse return allocator.dupe(u8, "// bind the value to a const, then check it for undefined before you read it");
            return allocator.print("if ({s} === undefined) return Response.json({{ error: \"missing value\" }}, {{ status: 400 }});", .{name_text});
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
    if (tag != .member_access and tag != .optional_chain and tag != .computed_access) return null;
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
    return atoms.getName(@fromBackingInt(@intCast(binding.name_atom)));
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
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = parseJson("1");
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
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
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (appName === undefined)") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (value === undefined)") == null);
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

test "a repair plan reads the same from two different workspaces" {
    // The flow recorder captures this tool's result into a transcript and
    // replays it from a fresh directory. Any part of the output that depends on
    // where the run lives makes the replayed transcript differ from the
    // recorded one, which fails the case rather than the tool.
    const source =
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = parseJson("1");
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
    var first = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer first.deinit(testing.allocator);
    const first_text = try testing.allocator.dupe(u8, first.llm_text);
    defer testing.allocator.free(first_text);

    try std.Io.Threaded.chdir(second_tree.abs_path);
    var second = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer second.deinit(testing.allocator);

    // The source reaches the verifier, so the compared output holds a plan.
    try testing.expect(std.mem.indexOf(u8, first_text, "\"plans\":[{\"id\":\"rp_001\"") != null);
    try testing.expectEqualStrings(first_text, second.llm_text);
}

test "tool description names repair plan authority boundary" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "does not edit files") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "unchecked Result.value") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "pass it to pi_apply_repair_plan") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "edit_intent.kind manual_edit: follow its summary by hand") != null);
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

test "planFromSource is not ok while a requested goal is unproven" {
    const source =
        \\function handler(req: Request): Response {
        \\  fetchSync("https://api.example.com", { method: "POST", body: req.body });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{"pii_contained"});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
}

const zts_expert_narrow = @import("zts_expert_narrow.zig");

/// Run the three expert tools on `app_name_handler` in a fresh workspace whose
/// `zttp.json` names `policy_text`, and report what each one says about
/// `no_secret_leakage`.
const ToolVerdicts = struct {
    goal_check_ok: bool,
    repair_plan_ok: bool,
    narrow_reports_witness: bool,
    production_proves: bool,
};

const app_name_handler =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  const name = env("APP_NAME");
    \\  if (name === undefined) { return Response.json({ ok: false }); }
    \\  return Response.json({ app: name });
    \\}
    \\
;

fn toolVerdictsUnder(policy_text: []const u8) !ToolVerdicts {
    const allocator = testing.allocator;
    var tree = try IsolatedTmp.init(allocator, "expert-tools-env-public");
    defer tree.cleanup(allocator);
    try tree.writeFile(allocator, "zttp.json", "{\"policy\":\"policy.json\"}");
    try tree.writeFile(allocator, "policy.json", policy_text);
    try tree.writeFile(allocator, "handler.ts", app_name_handler);

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};
    try std.Io.Threaded.chdir(tree.abs_path);

    var goal_check = try pi_goal_check.evaluateSource(allocator, app_name_handler, "handler.ts", &.{"no_secret_leakage"});
    defer goal_check.deinit(allocator);
    var plan = try planFromSource(allocator, app_name_handler, "handler.ts", &.{"no_secret_leakage"});
    defer plan.deinit(allocator);
    var narrow = try zts_expert_narrow.run(allocator, "handler.ts");
    defer narrow.deinit(allocator);
    var check = try common.runProductionCheck(allocator, app_name_handler, "handler.ts", null);
    defer check.deinit(allocator);
    const unproven = try pi_goal_check.unprovenFromCheck(allocator, &check, &.{.no_secret_leakage});
    defer allocator.free(unproven);

    return .{
        .goal_check_ok = goal_check.ok,
        .repair_plan_ok = plan.ok,
        .narrow_reports_witness = std.mem.indexOf(u8, narrow.llm_text, "\"property\":\"no_secret_leakage\"") != null,
        .production_proves = unproven.len == 0,
    };
}

test "the expert tools agree with the production check on a public env name" {
    const listed = try toolVerdictsUnder("{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}");
    try testing.expect(listed.production_proves);
    try testing.expect(listed.goal_check_ok);
    try testing.expect(listed.repair_plan_ok);
    try testing.expect(!listed.narrow_reports_witness);

    const unlisted = try toolVerdictsUnder("{\"env\":{\"allow\":[\"APP_NAME\"]}}");
    try testing.expect(!unlisted.production_proves);
    try testing.expect(!unlisted.goal_check_ok);
    try testing.expect(!unlisted.repair_plan_ok);
    try testing.expect(unlisted.narrow_reports_witness);
}

const shape_guard = "if (!r.ok) return Response.json({ error: r.error }, { status: 400 });";

const plan_head =
    \\import { parseJson } from "zttp:json";
    \\
    \\function handler(req: Request): Proof<Response, "deterministic"> {
    \\  const r = parseJson("1");
    \\
;

/// Plan `source` and check that the first plan carries `summary` and `template`.
fn expectFirstPlan(source: []const u8, summary: []const u8, template: []const u8) !void {
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    const plans_at = std.mem.indexOf(u8, result.llm_text, "\"plans\":[") orelse return error.NoPlans;
    const plans = result.llm_text[plans_at..];
    const expected = try std.fmt.allocPrint(testing.allocator, "\"summary\":\"{s}\",\"edit_intent\":{{\"kind\":\"insert_guard_before_line\"", .{summary});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, plans, expected) != null);
    const expected_template = try std.fmt.allocPrint(testing.allocator, "\"template\":\"{s}\"", .{template});
    defer testing.allocator.free(expected_template);
    try testing.expect(std.mem.indexOf(u8, plans, expected_template) != null);
}

/// Production stops this source before the verifier, so the tool reports the
/// stage diagnostic as the first one and a Result plan for it as the first plan.
fn expectEarlyStopPlan(source: []const u8, code: []const u8, summary: []const u8) !void {
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    const expected = try std.fmt.allocPrint(testing.allocator, "\"diagnostics\":[{{\"id\":\"diag_001\",\"code\":\"{s}\"", .{code});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, expected) != null);
    const plans_at = std.mem.indexOf(u8, result.llm_text, "\"plans\":[") orelse return error.NoPlans;
    const plans = result.llm_text[plans_at..];
    try testing.expect(std.mem.startsWith(u8, plans, "\"plans\":[{\"id\":\"rp_001\",\"kind\":\"check_result_before_value\""));
    const expected_summary = try std.fmt.allocPrint(testing.allocator, "\"summary\":\"{s}\"", .{summary});
    defer testing.allocator.free(expected_summary);
    try testing.expect(std.mem.indexOf(u8, plans, expected_summary) != null);
    const expected_template = try std.fmt.allocPrint(testing.allocator, "\"template\":\"{s}\"", .{shape_guard});
    defer testing.allocator.free(expected_template);
    try testing.expect(std.mem.indexOf(u8, plans, expected_template) != null);
}

test "repair plan: an unguarded value read keeps the guard" {
    try expectFirstPlan(plan_head ++
        \\  const v = r.value;
        \\  return Response.json({ v: v });
        \\}
    , "Add an explicit non-2xx early return before reading result.value.", shape_guard);
}

test "repair plan: an unguarded error read gets the failure guard" {
    try expectFirstPlan(plan_head ++
        \\  const e = r.error;
        \\  return Response.json({ e: e });
        \\}
    , "Read result.error only after if (!result.ok), or write result.error ?? fallback.", shape_guard);
}

test "repair plan: an error read on the ok path gets an ok-first guard" {
    try expectFirstPlan(plan_head ++
        \\  if (r.ok) {
        \\    return Response.json({ e: r.error });
        \\  }
        \\  return Response.text("no");
        \\}
    , "Result.error is undefined on the ok path. Read it after if (result.ok) return ..., or write result.error ?? fallback.", "if (r.ok) return Response.json({ ok: true });");
}

test "repair plan: a comparison of ok with true gets ZTS620 and a Result plan before the verifier" {
    try expectEarlyStopPlan(plan_head ++
        \\  if (r.ok === true) {
        \\    return Response.json({ v: r.value });
        \\  }
        \\  return Response.text("no");
        \\}
    , "ZTS620", "Replace this check with if (!result.ok) return ... . The proof does not accept === true, isOk(), isErr(), or match as a check.");
}

test "repair plan: a closure read gets a check inside the closure" {
    try expectFirstPlan(plan_head ++
        \\  const read = (): unknown => {
        \\    return r.value;
        \\  };
        \\  return Response.json({ v: read() });
        \\}
    , "Check result.ok inside the closure before it reads result.value. A check outside the closure does not reach it.", shape_guard);
}

test "repair plan: a read inside an assert gets a check before the statement" {
    try expectFirstPlan(plan_head ++
        \\  assert r.value !== undefined, Response.text("no");
        \\  return Response.text("ok");
        \\}
    , "Check result.ok in an if statement before the assert, throw, switch, or try statement that reads the Result.", shape_guard);
}

test "repair plan: an unknown Result member gets ZTS201 and a Result plan before the verifier" {
    try expectEarlyStopPlan(plan_head ++
        \\  const x = r.foo;
        \\  return Response.json({ x: x });
        \\}
    , "ZTS201", "Read only result.ok, result.value, result.error, or result.errors, each with a plain member name.");
}

test "repair plan: a computed key resolves its subject" {
    try expectFirstPlan(plan_head ++
        \\  const k = "value";
        \\  const v = r[k];
        \\  return Response.json({ v: v });
        \\}
    , "Read only result.ok, result.value, result.error, or result.errors, each with a plain member name.", shape_guard);
}

test "repair plan: a Result method call gets ZTS100 and a Result plan before the verifier" {
    try expectEarlyStopPlan(plan_head ++
        \\  if (r.isOk()) {
        \\    return Response.text("yes");
        \\  }
        \\  return Response.text("no");
        \\}
    , "ZTS100", "Use result.ok. A Result has no methods, so replace the method call with if (!result.ok) return ... .");
}

test "repair plan: an alias asks for a check and result.value" {
    try expectFirstPlan(plan_head ++
        \\  const a = r;
        \\  return Response.text("ok");
        \\}
    , "Keep the Result in its one const. Check result.ok in this function, then copy result.value.", shape_guard);
}

test "repair plan: a Result function without a call asks for a direct call" {
    try expectFirstPlan(plan_head ++
        \\  const f = parseJson;
        \\  return Response.text("ok");
        \\}
    , "Call the Result function directly and bind the call to a const.", "// call the Result function directly and bind the call to a const");
}

test "repair plan: a Result argument asks for result.value" {
    try expectFirstPlan(plan_head ++
        \\  const s = String(r);
        \\  return Response.text(s);
        \\}
    , "Check result.ok in this function, then pass result.value, not the Result. Pass the Result itself only to a zttp:result function that takes a Result.", shape_guard);
}

test "repair plan: a returned Result gets ZTS204 and a Result plan before the verifier" {
    try expectEarlyStopPlan(plan_head ++
        \\  if (req.method === "GET") {
        \\    return r;
        \\  }
        \\  return Response.text("ok");
        \\}
    , "ZTS204", "Check result.ok in this function, then return result.value or a Response, not the Result.");
}

test "repair plan: a Result in an object asks for result.value" {
    try expectFirstPlan(plan_head ++
        \\  const box = { r: r };
        \\  return Response.text("ok");
        \\}
    , "Check result.ok in this function, then store result.value, not the Result.", shape_guard);
}

test "repair plan: a spread Result asks for result.value" {
    try expectFirstPlan(plan_head ++
        \\  const box = { ...r };
        \\  return Response.text("ok");
        \\}
    , "Check result.ok in this function, then store result.value, not the Result.", shape_guard);
}

test "repair plan: a match on a Result gets the failure guard" {
    try expectFirstPlan(plan_head ++
        \\  const v = match (r) { when { ok: true, value: x }: x default: 0 };
        \\  return Response.json({ v: v });
        \\}
    , "Replace match with if (!result.ok) return ... , then read result.value.", shape_guard);
}

test "repair plan: an unbound call asks for a binding" {
    try expectFirstPlan(plan_head ++
        \\  const v = parseJson("2").value;
        \\  return Response.json({ v: v });
        \\}
    , "Bind the call to a const, then check its ok before you read its value.", "// bind the call to a const, then check its ok before you read its value");
}

test "repair plan: a shared captured name asks for unique names" {
    try expectFirstPlan(
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  if (req.method === "GET") {
        \\    const r = parseJson("1");
        \\    if (!r.ok) {
        \\      return Response.json({ bad: true }, { status: 400 });
        \\    }
        \\    return Response.json({ v: r.value });
        \\  }
        \\  const r = parseJson("2");
        \\  const read = (): unknown => {
        \\    return r.value;
        \\  };
        \\  return Response.json({ v: read() });
        \\}
    , "Give each Result binding in the file a unique name.", "// give each Result binding in the file a unique name");
}

test "repair plan: any other use asks for plain member reads" {
    try expectFirstPlan(plan_head ++
        \\  const same = r === r;
        \\  return Response.json({ same: same });
        \\}
    , "Use a Result only through result.ok, result.value, result.error, and result.errors.", shape_guard);
}

// A3 part 2b (Decision 39): a read with no binding cannot take a guard line
// that names a variable, so the plan tells the author to bind the value first.

fn optionalReadPlan() !repair_plan.Plan {
    return repair_plan.fromVerifierDiagnostic(
        .{
            .severity = .err,
            .kind = .unchecked_optional_access,
            .node = 0,
            .message = "read on a value that may be undefined, without checking for undefined",
            .help = null,
        },
        .{ .line = 4, .column = 20 },
    ) orelse error.MissingPlan;
}

test "a plan for an optional read with no binding says to bind the value first" {
    var text_buf = registry_mod.helpers.TextBuffer.init(testing.allocator);
    defer text_buf.deinit();
    try writePlan(text_buf.writer(), testing.allocator, 1, try optionalReadPlan(), "diag", 1, null);
    const text = try text_buf.toOwnedSlice();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"summary\":\"Bind the value to a const first, then check it for undefined.\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"template\":\"// bind the value to a const, then check it for undefined before you read it\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (value === undefined)") == null);
}

test "a plan for an optional read on a named binding keeps the guard line" {
    var text_buf = registry_mod.helpers.TextBuffer.init(testing.allocator);
    defer text_buf.deinit();
    try writePlan(text_buf.writer(), testing.allocator, 1, try optionalReadPlan(), "diag", 1, "appName");
    const text = try text_buf.toOwnedSlice();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"summary\":\"Narrow the optional value, provide a fallback, or return before using it.\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"template\":\"if (appName === undefined) return Response.json({ error: \\\"missing value\\\" }, { status: 400 });\"") != null);
}

test "repair plan: an unguarded read of a possibly undefined value gets ZTS309 and one plan" {
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const xs: string[] = ["a"];
        \\  const first = xs[0];
        \\  return Response.json({ n: first.length });
        \\}
        \\
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(
        u8,
        result.llm_text,
        "\"diagnostics\":[{\"id\":\"diag_001\",\"code\":\"ZTS309\",\"kind\":\"unchecked_optional_access\",\"severity\":\"error\",\"line\":4,\"column\":34,",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diag_002\"") == null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"plans\":[{\"id\":\"rp_001\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"rp_002\"") == null);
}

test "repair plan: a type error stops the check and returns the production diagnostic with one help plan" {
    const source =
        \\function handler(req: Request): Response {
        \\  const n: number = "a";
        \\  return Response.json({ n: n });
        \\}
        \\
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.startsWith(u8, result.llm_text, "{\"ok\":false,"));
    try testing.expect(std.mem.endsWith(
        u8,
        result.llm_text,
        "\"diagnostics\":[{\"id\":\"diag_001\",\"code\":\"ZTS200\",\"severity\":\"error\",\"line\":2,\"column\":3,\"message\":\"type '\\\"a\\\"' is not assignable to type 'number'\",\"help\":\"Change the value or the declared type so that the two types match.\"}],\"witnesses\":[],\"plans\":[{\"id\":\"rp_001\",\"kind\":\"follow_diagnostic_help\",\"target\":{\"line\":2,\"column\":3},\"behavioral_change\":true,\"summary\":\"Change the value or the declared type so that the two types match.\",\"edit_intent\":{\"kind\":\"manual_edit\",\"line\":2,\"column\":3,\"template\":\"\"},\"closes\":[\"diag_001\"]}]}\n",
    ));
}

test "repair plan: a file with no handler returns the no-handler error" {
    var result = try planFromSource(testing.allocator, "const x = 1;\n", "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqualStrings("pi_repair_plan: no handler function found in file\n", result.llm_text);
}

test "repair plan: a .js path returns the production ZTS052 diagnostic" {
    const source =
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
        \\
    ;
    var result = try planFromSource(testing.allocator, source, "handler.js", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diagnostics\":[{\"id\":\"diag_001\",\"code\":\"ZTS052\",\"severity\":\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diag_002\"") == null);
    try testing.expect(std.mem.endsWith(u8, result.llm_text, "\"witnesses\":[],\"plans\":[{\"id\":\"rp_001\",\"kind\":\"follow_diagnostic_help\",\"target\":{\"line\":1,\"column\":1},\"behavioral_change\":true,\"summary\":\"rename the handler to .ts\",\"edit_intent\":{\"kind\":\"manual_edit\",\"line\":1,\"column\":1,\"template\":\"\"},\"closes\":[\"diag_001\"]}]}\n"));
}

/// Plan `source` and return the llm text. The caller frees it.
fn planText(source: []const u8) ![]u8 {
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    return testing.allocator.dupe(u8, result.llm_text);
}

test "repair plan: a compound assignment gets ZTS613 and an apply_repair_intent plan" {
    const text = try planText(
        \\function handler(req: Request): Response {
        \\  let x = 1;
        \\  x += 1;
        \\  return Response.json({ x: x });
        \\}
        \\
    );
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"code\":\"ZTS613\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"plans\":[{\"id\":\"rp_001\",\"kind\":\"apply_repair_intent\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"edit_intent\":{\"kind\":\"replace_compound_assign_with_explicit\",\"line\":3") != null);
}

test "repair plan: a type mismatch gets one follow_diagnostic_help plan with the help text" {
    const text = try planText(
        \\function handler(req: Request): Response {
        \\  const n: number = "a";
        \\  return Response.json({ n: n });
        \\}
        \\
    );
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(
        u8,
        text,
        "\"plans\":[{\"id\":\"rp_001\",\"kind\":\"follow_diagnostic_help\",\"target\":{\"line\":2,\"column\":3},\"behavioral_change\":true,\"summary\":\"Change the value or the declared type so that the two types match.\",\"edit_intent\":{\"kind\":\"manual_edit\",\"line\":2,\"column\":3,\"template\":\"\"},\"closes\":[\"diag_001\"]}]}\n",
    ));
    try testing.expect(std.mem.indexOf(u8, text, "\"rp_002\"") == null);
}

test "repair plan: a spec assertion the handler does not satisfy is reported with a plan and ok false" {
    const text = try planText(
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\    const count = Date.now();
        \\    return Response.json({ count: count });
        \\}
        \\
    );
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "{\"ok\":false,"));
    try testing.expect(std.mem.indexOf(u8, text, "\"diagnostics\":[{\"id\":\"diag_001\",\"code\":\"ZTS500\",\"severity\":\"error\",\"line\":1,\"column\":17,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"plans\":[{\"id\":\"rp_001\",\"kind\":\"follow_diagnostic_help\",\"target\":{\"line\":1,\"column\":17},\"behavioral_change\":true,\"summary\":\"remove Date.now(), Math.random(), and performance.now() from the response path.\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"closes\":[\"diag_001\"]") != null);
}

test "repair plan: a verifier error with no typed repair gets a help plan" {
    const source =
        \\let count = 0;
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\    count = count + 1;
        \\    return Response.json({ count: count });
        \\}
        \\
    ;
    var result = try planFromSource(testing.allocator, source, "handler.ts", &.{});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"code\":\"ZTS310\",\"kind\":\"module_scope_mutation\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"kind\":\"follow_diagnostic_help\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"edit_intent\":{\"kind\":\"manual_edit\",\"line\":4,\"column\":11") != null);
}
