//! pi_goal_candidate - compose proof repair tools into one non-writing
//! candidate generator.
//!
//! The model should still apply the returned bytes through the normal edit
//! path. This tool only reduces round-trips by running the deterministic repair
//! lane in memory and returning a compiler-verified candidate source snapshot.

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const json_writer = @import("../providers/json_writer.zig");
const pi_repair_plan = @import("pi_repair_plan.zig");
const pi_apply_repair_plan = @import("pi_apply_repair_plan.zig");
const repair_apply = @import("repair_apply.zig");

const writeJsonString = zts.writeJsonString;

const name = "pi_goal_candidate";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "goal-candidate",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Run the compiler-native repair lane in memory and return a verified
    \\candidate source snapshot for one or more property goals. This tool
    \\never writes files. It calls pi_repair_plan, dry-runs supported repair
    \\intents through pi_apply_repair_plan, and returns proposed_content only
    \\after edit-simulate reports zero new violations. Apply returned bytes
    \\through propose_change_set or another compiler-vetoed writer.
    ,
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"goals":{"type":"array","items":{"type":"string"}},"max_repairs":{"type":"integer","minimum":1,"maximum":8}},"required":["path"]}
    ,
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

const ParsedInput = struct {
    path: []const u8,
    goals: []const []const u8,
    max_repairs: usize,

    fn deinit(self: *ParsedInput, allocator: std.mem.Allocator) void {
        if (self.goals.len > 0) allocator.free(self.goals);
        self.* = .{ .path = "", .goals = &.{}, .max_repairs = 1 };
    }
};

const ParsedPlan = struct {
    id: []u8,
    raw_json: []u8,
    line_target: u32,

    fn deinit(self: *ParsedPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.raw_json);
        self.* = .{ .id = &.{}, .raw_json = &.{}, .line_target = 0 };
    }
};

const ParsedPlans = struct {
    items: []ParsedPlan,

    fn deinit(self: *ParsedPlans, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

const ApplyJson = struct {
    ok: bool,
    proposed_content: ?[]u8 = null,
    reason: ?[]u8 = null,
    message: ?[]u8 = null,

    fn deinit(self: *ApplyJson, allocator: std.mem.Allocator) void {
        if (self.proposed_content) |s| allocator.free(s);
        if (self.reason) |s| allocator.free(s);
        if (self.message) |s| allocator.free(s);
        self.* = .{ .ok = false };
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a JSON input argument\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n");
    };
    defer parsed.deinit();
    var input = parseInput(allocator, parsed.value) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": expected { path, goals?, max_repairs? }\n");
    };
    defer input.deinit(allocator);

    // Read the source once and compute a repair candidate without writing workspace files.
    const source = readWorkspaceFile(allocator, input.path) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": failed to read {s}: {s}\n",
            .{ input.path, @errorName(e) },
        );
    };
    defer allocator.free(source);

    var detailed = computeCandidateInternal(
        allocator,
        source,
        input.path,
        input.goals,
        input.max_repairs,
        true,
    ) catch |err| switch (err) {
        error.InvalidRepairPlanJson => return registry_mod.ToolResult.err(allocator, name ++ ": pi_repair_plan returned invalid JSON\n"),
        error.InvalidApplyPlanJson => return registry_mod.ToolResult.err(allocator, name ++ ": pi_apply_repair_plan returned invalid JSON\n"),
        else => return err,
    };
    defer detailed.deinit(allocator);

    return switch (detailed.status) {
        .already_satisfied => try alreadySatisfied(allocator, input, detailed.candidate.plans_json),
        .no_repair_plans => try noCandidate(allocator, input, "no_repair_plans", "pi_repair_plan found violations but no supported repair plans"),
        .all_repairs_failed => try noCandidate(
            allocator,
            input,
            detailed.candidate.reason,
            "all supported repair candidates failed edit-simulate",
        ),
        .candidate_verified => try candidateResult(
            allocator,
            input,
            detailed.candidate.plan_ids,
            detailed.candidate.proposed_content.?,
            detailed.candidate.plan_ids.len,
            detailed.last_apply_json orelse "{}",
        ),
    };
}

fn parseInput(allocator: std.mem.Allocator, value: std.json.Value) !ParsedInput {
    if (value != .object) return error.InvalidToolArgsJson;
    const obj = value.object;
    const path_val = obj.get("path") orelse return error.InvalidToolArgsJson;
    if (path_val != .string) return error.InvalidToolArgsJson;

    var goals: []const []const u8 = &.{};
    if (obj.get("goals")) |goals_val| {
        if (goals_val != .array) return error.InvalidToolArgsJson;
        goals = try goalsFromValue(allocator, goals_val);
    }
    errdefer if (goals.len > 0) allocator.free(goals);

    var max_repairs: usize = 1;
    if (obj.get("max_repairs")) |max_val| {
        if (max_val != .integer or max_val.integer < 1 or max_val.integer > 8) return error.InvalidToolArgsJson;
        max_repairs = @intCast(max_val.integer);
    }

    return .{ .path = path_val.string, .goals = goals, .max_repairs = max_repairs };
}

fn goalsFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return error.InvalidToolArgsJson;
    const items = value.array.items;
    if (items.len == 0) return &.{};
    const borrowed = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(borrowed);
    for (items, 0..) |item, i| {
        if (item != .string) return error.InvalidToolArgsJson;
        borrowed[i] = item.string;
    }
    return borrowed;
}

fn readWorkspaceFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const common = @import("common.zig");
    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);
    return zts.file_io.readFile(allocator, absolute, common.default_output_limit);
}

fn parsePlans(allocator: std.mem.Allocator, json_text: []const u8) !ParsedPlans {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolOutput;
    const plans_val = parsed.value.object.get("plans") orelse return .{ .items = try allocator.alloc(ParsedPlan, 0) };
    if (plans_val != .array) return .{ .items = try allocator.alloc(ParsedPlan, 0) };

    // Only a plan the apply step can run is a candidate. A help-text plan
    // (`manual_edit`) is advice for the author.
    var applicable: usize = 0;
    for (plans_val.array.items) |plan_val| {
        if (isApplicable(plan_val)) applicable += 1;
    }
    const items = try allocator.alloc(ParsedPlan, applicable);
    errdefer allocator.free(items);
    var next: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < next) : (i += 1) items[i].deinit(allocator);
    }

    for (plans_val.array.items) |plan_val| {
        if (plan_val != .object) return error.InvalidToolOutput;
        const id_val = plan_val.object.get("id") orelse return error.InvalidToolOutput;
        if (id_val != .string) return error.InvalidToolOutput;
        if (!isApplicable(plan_val)) continue;

        var raw_buf = registry_mod.helpers.TextBuffer.init(allocator);
        defer raw_buf.deinit();
        try std.json.Stringify.value(plan_val, .{}, raw_buf.writer());

        const id_copy = try allocator.dupe(u8, id_val.string);
        errdefer allocator.free(id_copy);
        const raw_json = try raw_buf.toOwnedSlice();
        errdefer allocator.free(raw_json);

        items[next] = .{
            .id = id_copy,
            .raw_json = raw_json,
            .line_target = extractEditIntentLine(plan_val),
        };
        next += 1;
    }

    return .{ .items = items };
}

/// True when the plan names an edit intent that `repair_apply` runs.
fn isApplicable(plan_val: std.json.Value) bool {
    if (plan_val != .object) return false;
    const intent = plan_val.object.get("edit_intent") orelse return false;
    if (intent != .object) return false;
    const kind = intent.object.get("kind") orelse return false;
    if (kind != .string) return false;
    return repair_apply.RepairKind.fromString(kind.string) != null;
}

fn extractEditIntentLine(plan_val: std.json.Value) u32 {
    if (plan_val != .object) return 0;
    const intent = plan_val.object.get("edit_intent") orelse return 0;
    if (intent != .object) return 0;
    const line = intent.object.get("line") orelse return 0;
    if (line != .integer or line.integer <= 0) return 0;
    return std.math.cast(u32, line.integer) orelse 0;
}

fn comparePlanLineDesc(_: void, a: ParsedPlan, b: ParsedPlan) bool {
    return a.line_target > b.line_target;
}

fn buildApplyArgsJson(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    plan_raw_json: []const u8,
) ![]u8 {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try w.writeAll("{\"path\":");
    try json_writer.writeString(w, path);
    try w.writeAll(",\"source\":");
    try json_writer.writeString(w, source);
    try w.writeAll(",\"plan\":");
    try w.writeAll(plan_raw_json);
    try w.writeByte('}');
    return try text_buf.toOwnedSlice();
}

fn parseApplyJson(allocator: std.mem.Allocator, json_text: []const u8) !ApplyJson {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolOutput;
    const obj = parsed.value.object;
    const ok_val = obj.get("ok") orelse return error.InvalidToolOutput;
    if (ok_val != .bool) return error.InvalidToolOutput;

    const proposed_content = if (obj.get("proposed_content")) |v| try dupeOptionalString(allocator, v) else null;
    errdefer if (proposed_content) |s| allocator.free(s);
    const reason = if (obj.get("reason")) |v| try dupeOptionalString(allocator, v) else null;
    errdefer if (reason) |s| allocator.free(s);
    const message = if (obj.get("message")) |v| try dupeOptionalString(allocator, v) else null;
    errdefer if (message) |s| allocator.free(s);

    return .{
        .ok = ok_val.bool,
        .proposed_content = proposed_content,
        .reason = reason,
        .message = message,
    };
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    if (value == .null) return null;
    if (value != .string) return error.InvalidToolOutput;
    return try allocator.dupe(u8, value.string);
}

fn alreadySatisfied(
    allocator: std.mem.Allocator,
    input: ParsedInput,
    repair_json: []const u8,
) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try writePrefix(w, input, true, "already_satisfied");
    try w.writeAll(",\"repairs_applied\":0,\"plan_ids\":[],\"proposed_content\":null,\"repair_plan\":");
    try w.writeAll(std.mem.trim(u8, repair_json, " \t\r\n"));
    try w.writeAll("}\n");
    return .{ .ok = true, .llm_text = try text_buf.toOwnedSlice() };
}

fn noCandidate(
    allocator: std.mem.Allocator,
    input: ParsedInput,
    reason: []const u8,
    message: []const u8,
) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try writePrefix(w, input, false, reason);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, message);
    try w.writeAll(",\"repairs_applied\":0,\"plan_ids\":[],\"proposed_content\":null}\n");
    return .{ .ok = false, .llm_text = try text_buf.toOwnedSlice() };
}

fn candidateResult(
    allocator: std.mem.Allocator,
    input: ParsedInput,
    plan_ids: []const []const u8,
    proposed_content: []const u8,
    repairs_applied: usize,
    last_apply_json: []const u8,
) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try writePrefix(w, input, true, "candidate_verified");
    try w.print(",\"repairs_applied\":{d},\"plan_ids\":[", .{repairs_applied});
    for (plan_ids, 0..) |id, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, id);
    }
    try w.writeAll("],\"proposed_content\":");
    try writeJsonString(w, proposed_content);
    try w.writeAll(",\"last_apply_result\":");
    try w.writeAll(last_apply_json);
    try w.writeAll("}\n");
    return .{ .ok = true, .llm_text = try text_buf.toOwnedSlice() };
}

fn writePrefix(writer: *std.Io.Writer, input: ParsedInput, ok: bool, reason: []const u8) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"applied\":false,\"path\":");
    try writeJsonString(writer, input.path);
    try writer.writeAll(",\"goals\":[");
    for (input.goals, 0..) |goal, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, goal);
    }
    try writer.writeAll("],\"reason\":");
    try writeJsonString(writer, reason);
}

/// In-memory result of running the repair lane over a source snapshot, for
/// callers (the veto loop's auto-repair hook) that need the verified candidate
/// bytes directly rather than the tool's JSON envelope.
pub const Candidate = struct {
    /// "candidate_verified" | "already_satisfied" | "no_repair_plans" |
    /// "all_repairs_failed" | <last per-plan failure reason>.
    reason: []u8,
    /// The repaired source; non-null only when reason == candidate_verified.
    proposed_content: ?[]u8,
    /// Ids of the repair plans that were applied (empty unless verified).
    plan_ids: [][]u8,
    /// The raw pi_repair_plan output, so the caller can format retry guidance
    /// (templates + witness) without re-running the analysis.
    plans_json: []u8,

    pub fn verified(self: *const Candidate) bool {
        return std.mem.eql(u8, self.reason, "candidate_verified");
    }

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        if (self.proposed_content) |c| allocator.free(c);
        for (self.plan_ids) |id| allocator.free(id);
        allocator.free(self.plan_ids);
        allocator.free(self.plans_json);
        self.* = undefined;
    }
};

const CandidateStatus = enum {
    already_satisfied,
    no_repair_plans,
    all_repairs_failed,
    candidate_verified,
};

const DetailedCandidate = struct {
    status: CandidateStatus,
    candidate: Candidate,
    last_apply_json: ?[]u8 = null,

    fn deinit(self: *DetailedCandidate, allocator: std.mem.Allocator) void {
        self.candidate.deinit(allocator);
        if (self.last_apply_json) |body| allocator.free(body);
        self.* = undefined;
    }
};

/// Run the deterministic repair lane over an in-memory `source` snapshot and
/// return a compiler-verified candidate (or the reason none could be built).
/// Side-effect free: it plans from `source` and
/// dry-runs each supported repair through pi_apply_repair_plan in memory; it
/// never writes files or calls the model.
pub fn candidateFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    rel_path: []const u8,
    goal_args: []const []const u8,
    max_repairs: usize,
) !Candidate {
    const detailed = try computeCandidateInternal(allocator, source, rel_path, goal_args, max_repairs, false);
    return detailed.candidate;
}

fn computeCandidateInternal(
    allocator: std.mem.Allocator,
    source: []const u8,
    rel_path: []const u8,
    goal_args: []const []const u8,
    max_repairs: usize,
    capture_last_apply_json: bool,
) !DetailedCandidate {
    var rr = try pi_repair_plan.planFromSource(allocator, source, rel_path, goal_args);
    defer rr.deinit(allocator);
    const plans_json = try allocator.dupe(u8, rr.llm_text);
    errdefer allocator.free(plans_json);

    if (rr.ok) {
        return .{
            .status = .already_satisfied,
            .candidate = .{
                .reason = try allocator.dupe(u8, "already_satisfied"),
                .proposed_content = null,
                .plan_ids = &.{},
                .plans_json = plans_json,
            },
        };
    }

    var plans = parsePlans(allocator, rr.llm_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRepairPlanJson,
    };
    defer plans.deinit(allocator);
    if (plans.items.len == 0) {
        return .{
            .status = .no_repair_plans,
            .candidate = .{
                .reason = try allocator.dupe(u8, "no_repair_plans"),
                .proposed_content = null,
                .plan_ids = &.{},
                .plans_json = plans_json,
            },
        };
    }
    std.sort.insertion(ParsedPlan, plans.items, {}, comparePlanLineDesc);

    var current_source = try allocator.dupe(u8, source);
    defer allocator.free(current_source);
    var applied_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (applied_ids.items) |id| allocator.free(id);
        applied_ids.deinit(allocator);
    }
    var last_apply_json: ?[]u8 = null;
    defer if (last_apply_json) |body| allocator.free(body);
    var last_failure_reason: ?[]u8 = null;
    defer if (last_failure_reason) |r| allocator.free(r);
    var repairs_applied: usize = 0;

    for (plans.items) |plan| {
        if (repairs_applied >= max_repairs) break;
        const apply_args_json = try buildApplyArgsJson(allocator, rel_path, current_source, plan.raw_json);
        defer allocator.free(apply_args_json);
        var apply_result = try pi_apply_repair_plan.executeSemanticPlan(allocator, &.{apply_args_json});
        defer apply_result.deinit(allocator);
        var apply_json = parseApplyJson(allocator, apply_result.llm_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidApplyPlanJson,
        };
        defer apply_json.deinit(allocator);
        if (!apply_json.ok or apply_json.proposed_content == null) {
            // Dupe into a temp BEFORE freeing the previous reason so an OOM
            // cannot trigger a double-free in the function-level defer.
            const reason_copy = try allocator.dupe(u8, apply_json.reason orelse "repair_not_verified");
            if (last_failure_reason) |r| allocator.free(r);
            last_failure_reason = reason_copy;
            continue;
        }
        {
            const next_source = try allocator.dupe(u8, apply_json.proposed_content.?);
            errdefer allocator.free(next_source);
            const id_copy = try allocator.dupe(u8, plan.id);
            errdefer allocator.free(id_copy);
            try applied_ids.ensureUnusedCapacity(allocator, 1);
            if (capture_last_apply_json) {
                const apply_copy = try allocator.dupe(u8, std.mem.trim(u8, apply_result.llm_text, " \t\r\n"));
                if (last_apply_json) |body| allocator.free(body);
                last_apply_json = apply_copy;
            }
            allocator.free(current_source);
            current_source = next_source;
            applied_ids.appendAssumeCapacity(id_copy);
            repairs_applied += 1;
        }
    }

    if (repairs_applied == 0) {
        return .{
            .status = .all_repairs_failed,
            .candidate = .{
                .reason = try allocator.dupe(u8, last_failure_reason orelse "all_repairs_failed"),
                .proposed_content = null,
                .plan_ids = &.{},
                .plans_json = plans_json,
            },
        };
    }

    const proposed = try allocator.dupe(u8, current_source);
    errdefer allocator.free(proposed);
    const reason = try allocator.dupe(u8, "candidate_verified");
    errdefer allocator.free(reason);
    const ids = try applied_ids.toOwnedSlice(allocator);
    const owned_last_apply = last_apply_json;
    last_apply_json = null;
    return .{
        .status = .candidate_verified,
        .candidate = .{
            .reason = reason,
            .proposed_content = proposed,
            .plan_ids = ids,
            .plans_json = plans_json,
        },
        .last_apply_json = owned_last_apply,
    };
}

const testing = std.testing;

test "candidateFromSource verifies a guard repair in memory" {
    const source =
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = parseJson("1");
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    var cand = try candidateFromSource(testing.allocator, source, "handler.ts", &.{}, 4);
    defer cand.deinit(testing.allocator);
    try testing.expect(cand.verified());
    try testing.expect(cand.proposed_content != null);
    try testing.expect(std.mem.find(u8, cand.proposed_content.?, "if (!result.ok)") != null);
    try testing.expect(cand.plan_ids.len >= 1);
    try testing.expect(std.mem.find(u8, cand.plans_json, cand.plan_ids[0]) != null);
}

test "candidateFromSource reports already_satisfied for a clean handler" {
    const clean =
        "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }";
    var cand = try candidateFromSource(testing.allocator, clean, "handler.ts", &.{}, 4);
    defer cand.deinit(testing.allocator);
    try testing.expect(!cand.verified());
    try testing.expectEqualStrings("already_satisfied", cand.reason);
    try testing.expect(cand.proposed_content == null);
}

test "parsePlans sorts higher line targets first" {
    var plans = try parsePlans(testing.allocator,
        \\{"plans":[
        \\{"id":"rp_001","edit_intent":{"kind":"insert_guard_before_line","line":2,"column":1,"template":"a"}},
        \\{"id":"rp_002","edit_intent":{"kind":"insert_guard_before_line","line":8,"column":1,"template":"b"}}
        \\]}
    );
    defer plans.deinit(testing.allocator);
    std.sort.insertion(ParsedPlan, plans.items, {}, comparePlanLineDesc);
    try testing.expectEqualStrings("rp_002", plans.items[0].id);
    try testing.expectEqualStrings("rp_001", plans.items[1].id);
}

test "parseApplyJson extracts verified proposed content" {
    var parsed = try parseApplyJson(testing.allocator, "{\"ok\":true,\"proposed_content\":\"next\"}");
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.ok);
    try testing.expectEqualStrings("next", parsed.proposed_content.?);
}

test "execute returns verified candidate without writing the file" {
    const allocator = testing.allocator;
    const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
    const cwdPathAlloc = @import("../test_support/cwd.zig").cwdPathAlloc;

    var tmp = try IsolatedTmp.init(allocator, "goal-candidate");
    defer tmp.cleanup(allocator);

    const source =
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = parseJson("1");
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    try tmp.writeFile(allocator, "handler.ts", source);

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var result = try execute(allocator, &.{"{\"path\":\"handler.ts\",\"max_repairs\":1}"});
    defer result.deinit(allocator);
    try testing.expect(result.ok);
    try testing.expect(std.mem.find(u8, result.llm_text, "\"applied\":false") != null);
    try testing.expect(std.mem.find(u8, result.llm_text, "\"reason\":\"candidate_verified\"") != null);
    try testing.expect(std.mem.find(u8, result.llm_text, "if (!result.ok)") != null);

    const path = try tmp.childPath(allocator, "handler.ts");
    defer allocator.free(path);
    const after = try zts.file_io.readFile(allocator, path, 1024 * 1024);
    defer allocator.free(after);
    try testing.expectEqualStrings(source, after);
}

test "execute does not persist witnesses to the on-disk corpus" {
    // pi_goal_candidate declares effect=.analyze, and the RPC surface denies
    // .persist_agent_state, so execute must create no file under .zttp.
    const allocator = testing.allocator;
    const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
    const cwdPathAlloc = @import("../test_support/cwd.zig").cwdPathAlloc;

    var tmp = try IsolatedTmp.init(allocator, "goal-candidate-corpus");
    defer tmp.cleanup(allocator);

    const source =
        \\import { parseJson } from "zttp:json";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const result = parseJson("1");
        \\  const data = result.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    try tmp.writeFile(allocator, "handler.ts", source);

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var result = try execute(allocator, &.{"{\"path\":\"handler.ts\",\"max_repairs\":1}"});
    defer result.deinit(allocator);
    // A verified candidate proves the repair lane ran over the failing handler.
    try testing.expect(result.ok);
    try testing.expect(std.mem.find(u8, result.llm_text, "\"reason\":\"candidate_verified\"") != null);

    const corpus_root = try tmp.childPath(allocator, ".zttp/witnesses");
    defer allocator.free(corpus_root);
    try testing.expect(!zts.file_io.fileExists(allocator, corpus_root));
}

test "candidateFromSource reports no_repair_plans when every plan is help text" {
    const source =
        \\function handler(req: Request): Response {
        \\  const n: number = "a";
        \\  return Response.json({ n: n });
        \\}
        \\
    ;
    var cand = try candidateFromSource(testing.allocator, source, "handler.ts", &.{}, 4);
    defer cand.deinit(testing.allocator);
    try testing.expectEqualStrings("no_repair_plans", cand.reason);
    try testing.expect(cand.proposed_content == null);
}

test "parseApplyJson handles OOM without leaking partial strings" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var parsed = try parseApplyJson(
                allocator,
                "{\"ok\":true,\"proposed_content\":\"next\",\"reason\":\"ok\",\"message\":\"done\"}",
            );
            defer parsed.deinit(allocator);
            try testing.expect(parsed.ok);
            try testing.expectEqualStrings("next", parsed.proposed_content.?);
            try testing.expectEqualStrings("ok", parsed.reason.?);
            try testing.expectEqualStrings("done", parsed.message.?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}
