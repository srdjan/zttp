//! auto_repair - turn a failed-veto draft into compiler-authored retry guidance.
//!
//! When a model edit fails the compiler veto, the repair lane (pi_repair_plan)
//! often already knows the exact fix: a typed repair plan with a concrete
//! template keyed to a diagnostic line. This module formats those plans plus
//! the single smallest counterexample witness into a compact block the retry
//! prompt injects, so a needed model retry converges in one shot instead of
//! re-deriving the fix across several round-trips.
//!
//! Pure: it parses a pi_repair_plan JSON envelope and emits text. It never
//! writes files, calls the model, or applies an edit.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

/// Maximum repair templates to surface in a retry block. Past a handful the
/// signal-to-token ratio drops and the model is better served re-reading the
/// handler; the cap also bounds prompt growth.
pub const max_templates: usize = 8;

/// Maximum io stubs to show for the chosen counterexample witness. A failing
/// path with more than this is summarised by its first few calls; the goal is
/// to ground the model, not to dump the whole trace.
pub const max_witness_stubs: usize = 4;

/// True when the deterministic repair lane is worth running on a veto failure.
/// SQL failures have their own escalation path in the loop, and a failure with
/// zero NEW violations carries no plans to author from.
pub fn shouldRunLane(sql_failure: bool, new_violations: u32) bool {
    return !sql_failure and new_violations > 0;
}

const fix_header = "COMPILER-AUTHORED FIX. The analyzer already derived these exact repairs " ++
    "for your failed draft. Apply them at the given lines and emit a new, " ++
    "complete edit:\n";
const advice_header = "COMPILER ADVICE. No tool applies these; make each edit by hand in your new, complete edit:\n";

/// Build a retry-guidance block from a pi_repair_plan JSON envelope: the
/// compiler-authored fixes first, then the help-text plans as advice. Returns
/// null when the envelope carries no plan to show (the caller then falls back
/// to the raw diagnostics alone). The returned bytes are owned by `allocator`
/// and end with a newline.
pub fn buildRetryBlock(allocator: std.mem.Allocator, plan_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, plan_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const plans = blk: {
        const v = obj.get("plans") orelse break :blk null;
        break :blk if (v == .array) v.array.items else null;
    };
    if (plans == null or plans.?.len == 0) return null;

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    var shown: usize = 0;
    for (plans.?) |plan_val| {
        if (shown >= max_templates) break;
        if (plan_val != .object) continue;
        const po = plan_val.object;
        const intent = objField(po, "edit_intent") orelse continue;
        const intent_kind = strField(intent, "kind") orelse "";
        // A help-text plan names no edit; the advice section below lists it.
        if (std.mem.eql(u8, intent_kind, "manual_edit")) continue;
        const template = strField(intent, "template") orelse continue;
        const kind = strField(po, "kind") orelse "repair";
        const line = lineFromTarget(po);
        if (template.len == 0) {
            // A repair-intent plan carries no template: name the intent and the tool that runs it.
            const summary = strField(po, "summary") orelse continue;
            if (shown == 0) try w.writeAll(fix_header);
            shown += 1;
            try w.print("  {d}. line {d} [{s}]: {s} (repair intent: {s}; apply it with pi_apply_repair_plan)\n", .{ shown, line, kind, summary, intent_kind });
            continue;
        }
        if (shown == 0) try w.writeAll(fix_header);
        shown += 1;
        try w.print("  {d}. line {d} [{s}]: {s}\n", .{ shown, line, kind, template });
    }

    // Help-text plans are advice: the model makes the edit itself.
    var advised: usize = 0;
    for (plans.?) |plan_val| {
        if (shown + advised >= max_templates) break;
        if (plan_val != .object) continue;
        const po = plan_val.object;
        const intent = objField(po, "edit_intent") orelse continue;
        const intent_kind = strField(intent, "kind") orelse "";
        if (!std.mem.eql(u8, intent_kind, "manual_edit")) continue;
        const summary = strField(po, "summary") orelse continue;
        if (advised == 0) try w.writeAll(advice_header);
        advised += 1;
        try w.print("  {d}. line {d}: {s}\n", .{ shown + advised, lineFromTarget(po), summary });
    }
    if (shown + advised == 0) return null;

    if (smallestWitness(obj)) |wit| {
        try w.writeAll("FAILING INPUT (smallest counterexample):\n");
        try writeWitness(w, wit);
    }

    return try buf.toOwnedSlice();
}

fn objField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return if (v == .bool) v.bool else false;
}

fn lineFromTarget(plan: std.json.ObjectMap) i64 {
    const target = objField(plan, "target") orelse return 0;
    const v = target.get("line") orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn ioStubCount(wit: std.json.ObjectMap) usize {
    const v = wit.get("io_stubs") orelse return 0;
    return if (v == .array) v.array.items.len else 0;
}

/// Pick the witness with the fewest io stubs (the simplest failing path). Ties
/// resolve to the first such witness, which keeps selection deterministic.
fn smallestWitness(obj: std.json.ObjectMap) ?std.json.ObjectMap {
    const v = obj.get("witnesses") orelse return null;
    if (v != .array) return null;
    var best: ?std.json.ObjectMap = null;
    var best_len: usize = std.math.maxInt(usize);
    for (v.array.items) |item| {
        if (item != .object) continue;
        const len = ioStubCount(item.object);
        if (len < best_len) {
            best_len = len;
            best = item.object;
        }
    }
    return best;
}

fn writeWitness(w: *std.Io.Writer, wit: std.json.ObjectMap) !void {
    const req = objField(wit, "request");
    const method = (if (req) |r| strField(r, "method") else null) orelse "GET";
    const url = (if (req) |r| strField(r, "url") else null) orelse "/";
    const auth = if (req) |r| boolField(r, "has_auth_header") else false;
    const summary = strField(wit, "summary") orelse "";
    try w.print("  {s} {s} (auth: {s}): {s}\n", .{ method, url, if (auth) "yes" else "no", summary });

    const stubs_v = wit.get("io_stubs") orelse return;
    if (stubs_v != .array) return;
    var shown: usize = 0;
    for (stubs_v.array.items) |stub_v| {
        if (shown >= max_witness_stubs) break;
        if (stub_v != .object) continue;
        const so = stub_v.object;
        const module = strField(so, "module") orelse "";
        const func = strField(so, "fn") orelse "";
        shown += 1;
        try w.print("   io: {s}.{s} -> ", .{ module, func });
        if (so.get("result")) |rv| {
            try std.json.Stringify.value(rv, .{}, w);
        } else {
            try w.writeAll("?");
        }
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "shouldRunLane gates on sql failure and new violations" {
    try testing.expect(shouldRunLane(false, 1));
    try testing.expect(!shouldRunLane(true, 1)); // sql has its own path
    try testing.expect(!shouldRunLane(false, 0)); // nothing new to repair
}

test "buildRetryBlock surfaces compiler templates and smallest witness" {
    const plan_json =
        \\{"ok":false,"plans":[
        \\{"id":"rp_001","kind":"check_result_before_value","target":{"line":5,"column":3},
        \\"edit_intent":{"kind":"insert_guard_before_line","line":5,"column":3,
        \\"template":"if (!result.ok) return Response.json({ error: result.error }, { status: 400 });"}}
        \\],"witnesses":[
        \\{"id":"wit_001","property":"injection_safe","summary":"tainted body reaches sql",
        \\"request":{"method":"POST","url":"/items","has_auth_header":false},
        \\"io_stubs":[{"seq":0,"module":"zttp:sql","fn":"sqlExec","result":{"rowsAffected":1}}]}
        \\]}
    ;
    const block = (try buildRetryBlock(testing.allocator, plan_json)) orelse return error.ExpectedBlock;
    defer testing.allocator.free(block);
    try testing.expect(std.mem.indexOf(u8, block, "COMPILER-AUTHORED FIX") != null);
    try testing.expect(std.mem.indexOf(u8, block, "line 5 [check_result_before_value]") != null);
    try testing.expect(std.mem.indexOf(u8, block, "if (!result.ok)") != null);
    try testing.expect(std.mem.indexOf(u8, block, "FAILING INPUT") != null);
    try testing.expect(std.mem.indexOf(u8, block, "POST /items") != null);
    try testing.expect(std.mem.indexOf(u8, block, "zttp:sql.sqlExec") != null);
}

test "buildRetryBlock returns null when there are no plans" {
    const empty = (try buildRetryBlock(testing.allocator, "{\"ok\":true,\"plans\":[]}"));
    try testing.expect(empty == null);
    const malformed = (try buildRetryBlock(testing.allocator, "not json"));
    try testing.expect(malformed == null);
}

test "buildRetryBlock lists help plans as advice, not as a compiler-authored fix" {
    const plan_json =
        \\{"ok":false,"plans":[
        \\{"id":"rp_001","kind":"follow_diagnostic_help","target":{"line":2,"column":3},"behavioral_change":true,
        \\"summary":"Change the value or the declared type so that the two types match.",
        \\"edit_intent":{"kind":"manual_edit","line":2,"column":3,"template":""}}
        \\],"witnesses":[]}
    ;
    const block = (try buildRetryBlock(testing.allocator, plan_json)) orelse return error.ExpectedBlock;
    defer testing.allocator.free(block);
    try testing.expectEqualStrings(
        "COMPILER ADVICE. No tool applies these; make each edit by hand in your new, complete edit:\n" ++
            "  1. line 2: Change the value or the declared type so that the two types match.\n",
        block,
    );
}

test "buildRetryBlock names the repair intent, its apply tool, and the advice" {
    const plan_json =
        \\{"ok":false,"plans":[
        \\{"id":"rp_001","kind":"apply_repair_intent","target":{"line":3,"column":3},
        \\"summary":"write x = x + 1 instead of x += 1",
        \\"edit_intent":{"kind":"replace_compound_assign_with_explicit","line":3,"column":3,"template":""}},
        \\{"id":"rp_002","kind":"follow_diagnostic_help","target":{"line":5,"column":1},"behavioral_change":true,
        \\"summary":"help only","edit_intent":{"kind":"manual_edit","line":5,"column":1,"template":""}}
        \\],"witnesses":[]}
    ;
    const block = (try buildRetryBlock(testing.allocator, plan_json)) orelse return error.ExpectedBlock;
    defer testing.allocator.free(block);
    try testing.expectEqualStrings(
        "COMPILER-AUTHORED FIX. The analyzer already derived these exact repairs " ++
            "for your failed draft. Apply them at the given lines and emit a new, " ++
            "complete edit:\n" ++
            "  1. line 3 [apply_repair_intent]: write x = x + 1 instead of x += 1 (repair intent: replace_compound_assign_with_explicit; apply it with pi_apply_repair_plan)\n" ++
            "COMPILER ADVICE. No tool applies these; make each edit by hand in your new, complete edit:\n" ++
            "  2. line 5: help only\n",
        block,
    );
}
