//! pi_apply_repair_plan - turn one compiler repair intent into a verified
//! in-memory edit candidate. This tool never writes files.

const std = @import("std");
const zts = @import("zts");
const edit_simulate = @import("zts_cli").edit_simulate;
const registry_mod = @import("../registry/registry.zig");
const ui_payload = @import("../ui_payload.zig");
const common = @import("common.zig");
const repair_apply = @import("repair_apply.zig");
const zts_agent_client = @import("zts_agent_client.zig");

const writeJsonString = zts.writeJsonString;
const repairPolicy = zts.RepairPolicy;

const name = "pi_apply_repair_plan";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "apply-repair-plan",
    .effect = .read_workspace,
    .context_policy = .exact,
    .description =
    \\Preview one or more exact bound repair candidates returned by
    \\zts_expert_canonicalize. The compiler rechecks source, profile, policy,
    \\module-graph, and semantics identity, applies the repairs in memory, and returns
    \\proposed_content. This tool never writes files.
    ,
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"repairs":{"type":"array","items":{"type":"object"},"minItems":1}},"required":["path","repairs"]}
    ,
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

const RepairIntent = repair_apply.Intent;

pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return executeAtRoot(allocator, io_backend.io(), ".", args);
}

fn executeAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a JSON input argument\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return registry_mod.ToolResult.err(allocator, name ++ ": expected JSON object\n");
    const input = parsed.value.object;
    const path_value = input.get("path") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"path\"\n");
    const repairs_value = input.get("repairs") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"repairs\"\n");
    if (path_value != .string or repairs_value != .array or repairs_value.array.items.len == 0) {
        return registry_mod.ToolResult.err(allocator, name ++ ": \"path\" must be a string and \"repairs\" a non-empty array\n");
    }

    const identity = commonRepairIdentity(repairs_value.array.items) orelse {
        return registry_mod.ToolResult.err(allocator, name ++ ": every repair must carry the same complete bound identity\n");
    };

    var repairs_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer repairs_buf.deinit();
    try std.json.Stringify.value(repairs_value, .{}, repairs_buf.writer());

    var input_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer input_buf.deinit();
    var input_json: std.json.Stringify = .{ .writer = input_buf.writer() };
    try input_json.beginObject();
    try input_json.objectField("file");
    try input_json.write(path_value.string);
    try input_json.objectField("repairs");
    try input_json.write(repairs_value);
    try input_json.endObject();

    const projection = try zts_agent_client.invokeForToolAtRoot(allocator, io, workspace_root, .{
        .operation = .simulate_edit,
        .input_json = input_buf.written(),
        .expected = .{
            .profile_id = identity.profile_id,
            .policy_hash = identity.policy_hash,
            .module_graph_hash = identity.module_graph_hash,
        },
    });
    errdefer allocator.free(projection.llm_text);
    if (!projection.ok) return .{ .ok = false, .llm_text = projection.llm_text };

    var response = std.json.parseFromSlice(std.json.Value, allocator, projection.llm_text, .{}) catch
        return error.MalformedProtocolResponse;
    defer response.deinit();
    const envelope = response.value.object;
    const payload = envelope.get("payload").?.object;
    const proposed = payload.get("proposed_content") orelse return error.MalformedProtocolResponse;
    const source_digest = payload.get("source_digest") orelse return error.MalformedProtocolResponse;
    const new_count_value = payload.get("new_count") orelse return error.MalformedProtocolResponse;
    const preexisting_count_value = payload.get("preexisting_count") orelse return error.MalformedProtocolResponse;
    if (proposed != .string or source_digest != .string or
        !std.mem.eql(u8, source_digest.string, identity.source_digest)) return error.MalformedProtocolResponse;
    const new_count = protocolCount(new_count_value) orelse return error.MalformedProtocolResponse;
    const preexisting_count = protocolCount(preexisting_count_value) orelse return error.MalformedProtocolResponse;
    const total = std.math.add(u32, new_count, preexisting_count) catch return error.MalformedProtocolResponse;

    const summary = try std.fmt.allocPrint(
        allocator,
        "{d} new, {d} preexisting",
        .{ new_count, preexisting_count },
    );
    defer allocator.free(summary);
    var ui: ui_payload.UiPayload = .{ .protocol_repair = try ui_payload.ProtocolRepairPayload.init(
        allocator,
        path_value.string,
        proposed.string,
        repairs_buf.written(),
        source_digest.string,
        identity.profile_id,
        identity.policy_hash,
        identity.module_graph_hash,
        summary,
        .{
            .total = total,
            .new = new_count,
            .preexisting = preexisting_count,
        },
    ) };
    errdefer ui.deinit(allocator);
    return .{
        .ok = true,
        .llm_text = projection.llm_text,
        .ui_payload = ui,
    };
}

const RepairIdentity = struct {
    source_digest: []const u8,
    profile_id: []const u8,
    policy_hash: []const u8,
    module_graph_hash: []const u8,
    semantics_hash: []const u8,
};

fn commonRepairIdentity(repairs: []const std.json.Value) ?RepairIdentity {
    var identity: ?RepairIdentity = null;
    for (repairs) |repair| {
        if (repair != .object) return null;
        const bound_value = repair.object.get("bound") orelse return null;
        if (bound_value != .object) return null;
        const bound = bound_value.object;
        const current: RepairIdentity = .{
            .source_digest = stringValue(bound.get("source_digest")) orelse return null,
            .profile_id = stringValue(bound.get("profile_id")) orelse return null,
            .policy_hash = stringValue(bound.get("policy_hash")) orelse return null,
            .module_graph_hash = stringValue(bound.get("module_graph_hash")) orelse return null,
            .semantics_hash = stringValue(bound.get("semantics_hash")) orelse return null,
        };
        if (identity) |first| {
            if (!sameRepairIdentity(first, current)) return null;
        } else {
            identity = current;
        }
    }
    return identity;
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return if (present == .string) present.string else null;
}

fn protocolCount(value: std.json.Value) ?u32 {
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(u32, value.integer);
}

fn sameRepairIdentity(a: RepairIdentity, b: RepairIdentity) bool {
    return std.mem.eql(u8, a.source_digest, b.source_digest) and
        std.mem.eql(u8, a.profile_id, b.profile_id) and
        std.mem.eql(u8, a.policy_hash, b.policy_hash) and
        std.mem.eql(u8, a.module_graph_hash, b.module_graph_hash) and
        std.mem.eql(u8, a.semantics_hash, b.semantics_hash);
}

/// Internal compatibility seam for the autonomous semantic-repair lane.
///
/// The model-facing tool is being cut to the bound v2 repair protocol. The
/// autoloop and goal-candidate reducer still consume proof-diagnostic plans,
/// which are a different ADT. Keeping that lane behind a named helper prevents
/// it from depending on the public tool schema while it is migrated separately.
pub fn executeSemanticPlan(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a JSON input argument\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return registry_mod.ToolResult.err(allocator, name ++ ": expected JSON object\n");
    const obj = parsed.value.object;

    const path_value = obj.get("path") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"path\"\n");
    const plan_value = obj.get("plan") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"plan\"\n");
    if (path_value != .string or plan_value != .object) {
        return registry_mod.ToolResult.err(allocator, name ++ ": \"path\" must be a string and \"plan\" must be an object\n");
    }
    const path = path_value.string;
    const intent = parseRepairIntent(plan_value) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": plan must contain id and edit_intent { kind, line, column, template }\n");
    };

    const source = if (obj.get("source")) |source_value| blk: {
        if (source_value != .string) return registry_mod.ToolResult.err(allocator, name ++ ": \"source\" must be a string when present\n");
        if (repair_apply.pathEscapesWorkspace(path)) return registry_mod.ToolResult.err(allocator, name ++ ": path escapes workspace\n");
        break :blk try allocator.dupe(u8, source_value.string);
    } else blk: {
        const root = try common.workspaceRoot(allocator);
        defer allocator.free(root);
        const absolute = try common.resolveInsideWorkspace(allocator, root, path);
        defer allocator.free(absolute);
        break :blk zts.file_io.readFile(allocator, absolute, common.default_output_limit) catch |e| {
            return registry_mod.ToolResult.errFmt(
                allocator,
                name ++ ": failed to read {s}: {s}\n",
                .{ path, @errorName(e) },
            );
        };
    };
    defer allocator.free(source);

    const proposed = repair_apply.applyIntent(allocator, source, intent) catch |e| switch (e) {
        error.UnsupportedRepairIntent => {
            return try unsupportedResult(allocator, intent);
        },
        error.InvalidRepairLine => {
            return try invalidLineResult(allocator, intent);
        },
        else => return e,
    };
    defer allocator.free(proposed);

    var result = try edit_simulate.simulate(allocator, .{
        .file = path,
        .content = proposed,
        .before = source,
    });
    defer result.deinit(allocator);

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();

    try w.writeAll("{\"ok\":");
    try w.writeAll(if (result.new_count == 0) "true" else "false");
    try w.writeAll(",\"applied\":false,\"path\":");
    try writeJsonString(w, path);
    try w.writeAll(",\"plan_id\":");
    try writeJsonString(w, intent.plan_id);
    try w.writeAll(",\"intent_kind\":");
    try writeJsonString(w, intent.intent_kind);
    try w.writeAll(",\"proposed_content\":");
    try writeJsonString(w, proposed);
    try w.writeAll(",\"equivalence\":");
    try writeEquivalenceJson(allocator, w, intent, source, proposed);
    try w.writeAll(",\"verification\":");
    try edit_simulate.writeResultJson(w, &result);
    try w.writeByte('}');
    try w.writeByte('\n');

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    const verification_summary = try std.fmt.allocPrint(
        allocator,
        "{d} total, {d} new, {d} preexisting",
        .{ result.total, result.new_count, result.preexisting_count },
    );
    defer allocator.free(verification_summary);
    var payload: ui_payload.UiPayload = .{ .repair_candidate = try ui_payload.RepairCandidatePayload.init(
        allocator,
        path,
        intent.plan_id,
        intent.intent_kind,
        proposed,
        result.new_count == 0,
        verification_summary,
        .{
            .total = result.total,
            .new = result.new_count,
            .preexisting = result.preexisting_count,
        },
    ) };
    errdefer payload.deinit(allocator);
    return .{
        .ok = result.new_count == 0,
        .llm_text = llm_text,
        .ui_payload = payload,
    };
}

/// Publish what the intent's registered equivalence validator says about this
/// candidate, or `null` when the intent has none.
///
/// This is a different question from `verification`, which asks whether the
/// candidate introduces new diagnostics. A candidate can be clean and still not
/// be the rewrite the law describes - `x === true` edited to `!x` type-checks
/// exactly as well as `x` does and means the opposite. Only the discharge
/// separates them, which is why an implemented row is what `repair_available`
/// keys on rather than a clean simulate.
fn writeEquivalenceJson(
    allocator: std.mem.Allocator,
    w: anytype,
    intent: RepairIntent,
    source: []const u8,
    proposed: []const u8,
) !void {
    const typed = std.meta.stringToEnum(zts.RepairIntent, intent.intent_kind) orelse {
        try w.writeAll("null");
        return;
    };
    const row = repairPolicy.findValidator(typed) orelse {
        try w.writeAll("null");
        return;
    };

    switch (try repairPolicy.validateApplication(allocator, typed, source, proposed, intent.line)) {
        .no_validator => try w.writeAll("null"),
        .equivalent => {
            try w.writeAll("{\"method\":");
            try writeJsonString(w, row.method.id());
            try w.writeAll(",\"discharged\":true,\"precondition\":");
            try writeJsonString(w, row.precondition orelse "");
            try w.writeByte('}');
        },
        // Both of these report `discharged:false`, and they are different
        // facts: one is "the edit is not the law's rewrite", the other is "the
        // validator formed no answer". Neither is an equivalence, so neither
        // may read as one, and the reason string is what separates them.
        .not_law_shape, .undecided => |why| {
            try w.writeAll("{\"method\":");
            try writeJsonString(w, row.method.id());
            try w.writeAll(",\"discharged\":false,\"reason\":");
            try writeJsonString(w, why);
            try w.writeByte('}');
        },
    }
}

fn parseRepairIntent(plan_value: std.json.Value) !RepairIntent {
    if (plan_value != .object) return error.InvalidToolArgsJson;
    const plan = plan_value.object;
    const id_value = plan.get("id") orelse return error.InvalidToolArgsJson;
    const edit_intent_value = plan.get("edit_intent") orelse return error.InvalidToolArgsJson;
    if (id_value != .string or edit_intent_value != .object) return error.InvalidToolArgsJson;

    const edit_intent = edit_intent_value.object;
    const kind_value = edit_intent.get("kind") orelse return error.InvalidToolArgsJson;
    const line_value = edit_intent.get("line") orelse return error.InvalidToolArgsJson;
    const column_value = edit_intent.get("column") orelse return error.InvalidToolArgsJson;
    const template_value = edit_intent.get("template") orelse return error.InvalidToolArgsJson;
    if (kind_value != .string or line_value != .integer or column_value != .integer or template_value != .string) {
        return error.InvalidToolArgsJson;
    }
    if (line_value.integer < 1 or line_value.integer > std.math.maxInt(u32)) return error.InvalidToolArgsJson;
    if (column_value.integer < 0 or column_value.integer > std.math.maxInt(u32)) return error.InvalidToolArgsJson;
    return .{
        .plan_id = id_value.string,
        .intent_kind = kind_value.string,
        .line = @intCast(line_value.integer),
        .template = template_value.string,
    };
}

fn unsupportedResult(
    allocator: std.mem.Allocator,
    intent: RepairIntent,
) !registry_mod.ToolResult {
    return jsonFailure(
        allocator,
        intent,
        "unsupported_repair_intent",
        "pi_apply_repair_plan v1 only supports insert_guard_before_line and add_trailing_return",
    );
}

fn invalidLineResult(
    allocator: std.mem.Allocator,
    intent: RepairIntent,
) !registry_mod.ToolResult {
    return jsonFailure(
        allocator,
        intent,
        "invalid_repair_line",
        "repair intent line does not exist in the source snapshot",
    );
}

fn jsonFailure(
    allocator: std.mem.Allocator,
    intent: RepairIntent,
    reason: []const u8,
    message: []const u8,
) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try w.writeAll("{\"ok\":false,\"applied\":false,\"plan_id\":");
    try writeJsonString(w, intent.plan_id);
    try w.writeAll(",\"intent_kind\":");
    try writeJsonString(w, intent.intent_kind);
    try w.writeAll(",\"reason\":");
    try writeJsonString(w, reason);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, message);
    try w.writeAll("}\n");

    return .{ .ok = false, .llm_text = try text_buf.toOwnedSlice() };
}

const testing = std.testing;

test "bound canonicalize candidate previews through v2 without writing" {
    const source =
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    let name = "world";
        \\    return Response.json({ hello: name });
        \\}
        \\
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var proposed = zts_agent_client.invokeAtRoot(testing.allocator, testing.io, root, .{
        .operation = .canonicalize,
        .input_json = "{\"file\":\"h.ts\"}",
    });
    defer proposed.deinit();
    var candidate = switch (proposed) {
        .success => |*envelope| envelope.root().get("payload").?.object.get("candidates").?.array.items[0],
        else => return error.TestExpectedSuccess,
    };

    var args_buf = registry_mod.helpers.TextBuffer.init(testing.allocator);
    defer args_buf.deinit();
    var json: std.json.Stringify = .{ .writer = args_buf.writer() };
    try json.beginObject();
    try json.objectField("path");
    try json.write("h.ts");
    try json.objectField("repairs");
    try json.beginArray();
    try json.write(candidate);
    try json.endArray();
    try json.endObject();

    var preview = try executeAtRoot(testing.allocator, testing.io, root, &.{args_buf.written()});
    defer preview.deinit(testing.allocator);
    try testing.expect(preview.ok);
    switch (preview.ui_payload.?) {
        .protocol_repair => |repair| {
            try testing.expectEqualStrings("h.ts", repair.path);
            try testing.expectEqualStrings(
                candidate.object.get("bound").?.object.get("source_digest").?.string,
                repair.source_digest,
            );
            try testing.expect(std.mem.indexOf(u8, repair.proposed_content, "const name") != null);
            try testing.expect(std.mem.indexOf(u8, repair.repairs_json, "replace_let_with_const") != null);
        },
        else => return error.TestExpectedProtocolRepair,
    }

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(source, on_disk);

    var candidate_bound = candidate.object.get("bound").?.object;
    for ([_][]const u8{ "source_digest", "profile_id", "policy_hash", "module_graph_hash", "semantics_hash" }) |field| {
        const field_ptr = candidate_bound.getPtr(field).?;
        const original = field_ptr.*;
        field_ptr.* = .{ .string = "stale-binding" };

        var stale_binding_args = registry_mod.helpers.TextBuffer.init(testing.allocator);
        defer stale_binding_args.deinit();
        var stale_json: std.json.Stringify = .{ .writer = stale_binding_args.writer() };
        try stale_json.beginObject();
        try stale_json.objectField("path");
        try stale_json.write("h.ts");
        try stale_json.objectField("repairs");
        try stale_json.beginArray();
        try stale_json.write(candidate);
        try stale_json.endArray();
        try stale_json.endObject();

        var stale_binding = try executeAtRoot(testing.allocator, testing.io, root, &.{stale_binding_args.written()});
        defer stale_binding.deinit(testing.allocator);
        try testing.expect(!stale_binding.ok);
        try testing.expect(stale_binding.ui_payload == null);
        field_ptr.* = original;
    }

    const moved = source ++ "// concurrent change\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = moved });
    var stale = try executeAtRoot(testing.allocator, testing.io, root, &.{args_buf.written()});
    defer stale.deinit(testing.allocator);
    try testing.expect(!stale.ok);
    try testing.expect(stale.ui_payload == null);
    const after_stale = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(after_stale);
    try testing.expectEqualStrings(moved, after_stale);
}

test "bound repair preview rejects mixed identity before protocol invocation" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        \\[
        \\  {"bound":{"source_digest":"same","profile_id":"zts-model-1","policy_hash":"policy-a","module_graph_hash":"graph","semantics_hash":"semantics"}},
        \\  {"bound":{"source_digest":"same","profile_id":"zts-model-1","policy_hash":"policy-b","module_graph_hash":"graph","semantics_hash":"semantics"}}
        \\]
    ,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(commonRepairIdentity(parsed.value.array.items) == null);
}

test "insertTemplateBeforeLine preserves target indentation" {
    const source =
        \\function handler(req: Request): Response {
        \\  const data = auth.value;
        \\  return Response.json({ data: data });
        \\}
    ;
    const out = try repair_apply.applyIntent(
        testing.allocator,
        source,
        .{
            .plan_id = "rp_001",
            .intent_kind = "insert_guard_before_line",
            .line = 2,
            .template = "if (!auth.ok) return Response.json({ error: auth.error }, { status: 400 });",
        },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  if (!auth.ok)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  const data") != null);
}

test "insertTemplateBeforeLastClosingBrace inserts inside the outer scope" {
    const source =
        \\function handler(req: Request): Response {
        \\  const data = auth.value;
        \\}
    ;
    const out = try repair_apply.applyIntent(
        testing.allocator,
        source,
        .{
            .plan_id = "rp_002",
            .intent_kind = "add_trailing_return",
            .line = 3,
            .template = "return Response.json({ data: data });",
        },
    );
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  return Response.json") != null);
    const return_idx = std.mem.indexOf(u8, out, "return Response.json").?;
    const brace_idx = std.mem.lastIndexOfScalar(u8, out, '}').?;
    try testing.expect(return_idx < brace_idx);
}

test "unsupported intent returns typed failure" {
    const intent: RepairIntent = .{
        .plan_id = "rp_001",
        .intent_kind = "replace_sink_expression",
        .line = 2,
        .template = "replace it",
    };
    var result = try unsupportedResult(testing.allocator, intent);
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "unsupported_repair_intent") != null);
}

test "execute dry-runs an add_trailing_return intent" {
    const input =
        \\{"path":"handler.ts","source":"function handler(req: Request): Proof<Response, \"deterministic\"> {\n  const data = auth.value;\n}","plan":{"id":"rp_002","edit_intent":{"kind":"add_trailing_return","line":3,"column":1,"template":"return Response.json({ data: auth.value });"}}}
    ;
    var result = try executeSemanticPlan(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"applied\":false") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "return Response.json") != null);
    try testing.expect(result.ui_payload != null);
    switch (result.ui_payload.?) {
        .repair_candidate => |candidate| {
            try testing.expectEqualStrings("add_trailing_return", candidate.intent_kind);
            try testing.expect(std.mem.indexOf(u8, candidate.proposed_content, "return Response.json") != null);
            const return_idx = std.mem.indexOf(u8, candidate.proposed_content, "return Response.json").?;
            const brace_idx = std.mem.lastIndexOfScalar(u8, candidate.proposed_content, '}').?;
            try testing.expect(return_idx < brace_idx);
        },
        else => return error.TestFailed,
    }
}

test "a bool-compare candidate carries its discharged equivalence" {
    const input =
        \\{"path":"handler.ts","source":"const ready = true;\nconst go = ready === true;\n","plan":{"id":"rp_010","edit_intent":{"kind":"drop_redundant_bool_compare","line":2,"column":18,"template":""}}}
    ;
    var result = try executeSemanticPlan(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"discharged\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"method\":\"M4\"") != null);
}

test "an intent with no implemented validator publishes a null equivalence" {
    // `add_trailing_return` claims no equivalence and never will: it exists to
    // change what the program does on a path that fell off the end. A null here
    // is the row's classification reaching the wire, not a missing feature.
    const input =
        \\{"path":"handler.ts","source":"function handler(req: Request): Proof<Response, \"deterministic\"> {\n  const data = auth.value;\n}","plan":{"id":"rp_011","edit_intent":{"kind":"add_trailing_return","line":3,"column":1,"template":"return Response.json({ data: auth.value });"}}}
    ;
    var result = try executeSemanticPlan(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"equivalence\":null") != null);
}

test "execute returns typed failure for unsupported intent" {
    const input =
        \\{"path":"handler.ts","source":"function handler() {}","plan":{"id":"rp_003","edit_intent":{"kind":"replace_sink_expression","line":1,"column":1,"template":"replace"}}}
    ;
    var result = try executeSemanticPlan(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "unsupported_repair_intent") != null);
    try testing.expect(result.ui_payload == null);
}

test "execute dry-runs a source-backed guard insertion" {
    const input =
        \\{"path":"handler.ts","source":"function handler(req: Request): Proof<Response, \"deterministic\"> {\n  const data = auth.value;\n  return Response.json({ data: data });\n}","plan":{"id":"rp_001","edit_intent":{"kind":"insert_guard_before_line","line":2,"column":14,"template":"if (!auth.ok) return Response.json({ error: auth.error }, { status: 400 });"}}}
    ;
    var result = try executeSemanticPlan(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"applied\":false") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "if (!auth.ok)") != null);
    try testing.expect(result.ui_payload != null);
    switch (result.ui_payload.?) {
        .repair_candidate => |candidate| {
            try testing.expectEqualStrings("handler.ts", candidate.path);
            try testing.expectEqualStrings("rp_001", candidate.plan_id);
            try testing.expectEqualStrings("insert_guard_before_line", candidate.intent_kind);
            try testing.expect(std.mem.indexOf(u8, candidate.proposed_content, "if (!auth.ok)") != null);
        },
        else => return error.TestFailed,
    }
}
