//! Agent protocol `simulate_edit` operation and its repair parsing.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const edit_simulate = @import("edit_simulate.zig");
const canonicalize = @import("canonicalize.zig");
const decision_registry = @import("decision_registry.zig");
const testing = std.testing;
const envelope_mod = @import("agent_protocol_envelope.zig");
const Identity = envelope_mod.Identity;
const request_mod = @import("agent_protocol_request.zig");
const RepairBinding = request_mod.RepairBinding;
const checkRepairBinding = request_mod.checkRepairBinding;
const CapturedFile = request_mod.CapturedFile;
const support_mod = @import("agent_protocol_support.zig");
const parse = support_mod.parse;
const respond = support_mod.respond;
const let_handler = support_mod.let_handler;
const currentTestRepairBinding = support_mod.currentTestRepairBinding;
const testRepairJson = support_mod.testRepairJson;
const ChangingRootReader = support_mod.ChangingRootReader;
const respondWithRootSourceReader = support_mod.respondWithRootSourceReader;

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

/// Run the analyzer once and write both the payload and the diagnostics array.
///
/// `success` is exactly "produced no error diagnostic" (spec 4.8): warnings and
/// advisories never fail a check.
fn writeApplyRefusalWithGraph(
    json: *std.json.Stringify,
    file_rel: []const u8,
    digest: [64]u8,
    module_graph_hash: [64]u8,
    decision: decision_registry.Id,
    message: []const u8,
) !bool {
    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("applied");
    try json.write(0);
    // The digest the file still carries: nothing was written, and a client
    // must be able to see that from the response rather than infer it.
    try json.objectField("source_digest");
    try json.write(&digest);
    try json.objectField("module_graph_hash");
    try json.write(&module_graph_hash);
    try json.objectField("refusal");
    try json.beginObject();
    try json.objectField("reason");
    try json.write(decision.wire());
    try json.objectField("message");
    try json.write(message);
    // The next action, from the decision registry rather than from this call
    // site: a client branches on it instead of parsing the message.
    try json.objectField("next_action");
    try json.write(@tagName(decision_registry.get(decision).next_action));
    try json.endObject();
    try json.endObject();
    return false;
}

/// Decode `input.repairs` into line-keyed refactors. Returns a refusal verdict
/// when the request is malformed, and null when `repairs` is populated.
///
/// Shared decoder for the compiler-owned repair candidate vocabulary.
fn parseRepairs(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    out: *std.ArrayListUnmanaged(canonicalize.Repair),
    file_rel: []const u8,
    digest: [64]u8,
    identity: Identity,
    input: ?std.json.Value,
    /// The bytes the digest covers. A `line`-form repair is resolved to its
    /// span against these, so both forms reach the applier as spans.
    source: []const u8,
) !?bool {
    const expected_binding = RepairBinding.current(digest, identity);
    const items: []const std.json.Value = blk: {
        const obj = (input orelse break :blk &.{}).object;
        const value = obj.get("repairs") orelse break :blk &.{};
        if (value != .array) break :blk &.{};
        break :blk value.array.items;
    };

    for (items) |item| {
        if (item != .object) return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "each entry in `repairs` must be an object");
        const o = item.object;

        switch (checkRepairBinding(o.get("bound"), expected_binding)) {
            .valid => {},
            .malformed => |message| return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, message),
            .stale => return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .stale_repair, "a repair's `bound` identity is stale; re-run canonicalize"),
        }

        const intent_value = o.get("intent") orelse
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "a repair must name its `intent`");
        if (intent_value != .string)
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`intent` must be a string");
        const intent = zts.RepairIntent.fromString(intent_value.string) orelse
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .unknown_intent, "`intent` is not a member of the repair vocabulary; read meta.validators for the closed set");
        const diagnostic_code_value = o.get("diagnostic_code") orelse
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "a repair must name the exact compiler diagnostic that authorized it");
        if (diagnostic_code_value != .string or diagnostic_code_value.string.len == 0)
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`diagnostic_code` must be a nonempty string");

        // A repair is keyed on a byte span. `line` is the older spelling of the
        // same thing for a whole-line rewrite, and it keeps working: within
        // schema version 2 a field cannot be removed, and every repair the
        // previous release published named a line. `span` is the added optional
        // field, it is what `canonicalize` now publishes, and it is the only
        // form that can express a rewrite crossing a line boundary.
        var start_offset: usize = 0;
        var end_offset: usize = 0;
        var line: u32 = 0;
        if (o.get("span")) |span_value| {
            if (span_value != .object)
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`span` must be an object with `start` and `end`");
            const start_value = span_value.object.get("start") orelse
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`span` must carry `start`");
            const end_value = span_value.object.get("end") orelse
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`span` must carry `end`");
            if (start_value != .integer or start_value.integer < 0 or
                end_value != .integer or end_value.integer < start_value.integer)
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`span.start` and `span.end` must be byte offsets with start <= end");
            start_offset = @intCast(start_value.integer);
            end_offset = @intCast(end_value.integer);
            if (end_offset > source.len)
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it");
            line = canonicalize.offsetLine(source, start_offset);
        } else if (o.get("line")) |line_value| {
            if (line_value != .integer or line_value.integer < 1 or line_value.integer > std.math.maxInt(u32))
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`line` must be a positive integer");
            line = @intCast(line_value.integer);
            const span = canonicalize.lineSpan(source, line) orelse
                return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it");
            start_offset = span.start;
            end_offset = span.end;
        } else {
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "a repair must carry the `span` it applies to, or the `line` for a whole-line repair");
        }

        const replacement_value = o.get("replacement") orelse
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "a repair must carry its `replacement`");
        if (replacement_value != .string)
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`replacement` must be a string");

        // Required, not optional. An absent snapshot would make the staleness
        // check silently skip, which is the one thing this field exists for.
        const original_value = o.get("original") orelse
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "a repair must carry `original`, the snapshot of the bytes it replaces");
        if (original_value != .string)
            return try writeApplyRefusalWithGraph(json, file_rel, digest, identity.module_graph_hash, .malformed_repair, "`original` must be a string");

        try out.append(allocator, .{
            .intent = intent,
            .diagnostic_code = diagnostic_code_value.string,
            .start_offset = start_offset,
            .end_offset = end_offset,
            .line = line,
            .column = 1,
            .message = "",
            .replacement = replacement_value.string,
            .original = original_value.string,
        });
    }
    return null;
}

/// `simulate_edit`: apply a set of repairs in memory and report what the
/// compiler says about the result. Never writes.
///
/// The repairs are the objects `canonicalize` published as candidates - same
/// vocabulary, round-tripped. That is what the deferral was waiting on: before
/// the vocabulary collapsed there was no single shape a client could take from
/// one operation and hand to another.
///
/// `original` is required on every repair, and is why. It is the client's
/// snapshot of the line it decided to change, re-validated here against the
/// file as it stands. A client that read a file, thought about it, and sent
/// repairs against bytes that have since moved gets `stale_repair` rather than
/// a splice into a program it never saw.
pub fn runSimulateEdit(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    file: *const CapturedFile,
    identity: Identity,
    input: ?std.json.Value,
) !bool {
    const source = file.effective_source;
    const digest = file.source_digest;

    var repairs: std.ArrayListUnmanaged(canonicalize.Repair) = .empty;
    defer repairs.deinit(allocator);
    // Canonicalize and simulate share one decoder, so a candidate cannot change
    // meaning between discovery and proof.
    if (try parseRepairs(allocator, json, &repairs, file.relative_path, digest, identity, input, source)) |refused| return refused;

    if (repairs.items.len == 0) {
        return try writeSimulateRefusal(json, file.relative_path, digest, .no_repairs, "`repairs` must carry at least one repair; simulating nothing has no answer to give");
    }

    const proposed = canonicalize.applyRepairs(allocator, source, repairs.items) catch |err| switch (err) {
        error.StaleRepair => return try writeSimulateRefusal(json, file.relative_path, digest, .stale_repair, "a repair's `original` does not match the file as it stands; re-read the file and re-derive the repair"),
        error.OverlappingRepairs => return try writeSimulateRefusal(json, file.relative_path, digest, .overlapping_repairs, "two repairs cover the same bytes, so which one applies is undefined"),
        error.RepairOutOfBounds => return try writeSimulateRefusal(json, file.relative_path, digest, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it"),
        else => return err,
    };
    defer allocator.free(proposed);

    var verdict = try edit_simulate.simulate(allocator, .{
        .file = file.absolute_path,
        .content = proposed,
        .before = source,
    });
    defer verdict.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file.relative_path);
    try json.objectField("source_digest");
    try json.write(&digest);
    try json.objectField("ok");
    try json.write(verdict.new_count == 0);
    try json.objectField("new_count");
    try json.write(verdict.new_count);
    try json.objectField("preexisting_count");
    try json.write(verdict.preexisting_count);
    try json.objectField("proposed_content");
    try json.write(proposed);
    try json.objectField("diagnostics");
    try json.beginArray();
    for (verdict.violations.items) |v| {
        try json.beginObject();
        try json.objectField("code");
        try json.write(v.code);
        try json.objectField("severity");
        try json.write(v.severity);
        try json.objectField("message");
        try json.write(v.message);
        try json.objectField("line");
        try json.write(v.line);
        try json.objectField("column");
        try json.write(v.column);
        try json.objectField("is_new");
        try json.write(v.introduced_by_patch);
        try json.endObject();
    }
    try json.endArray();
    // Present and null rather than absent, matching every other optional field
    // on this wire: the key set of a payload is part of the operation's
    // published schema, and a client should not have to distinguish "succeeded"
    // from "field removed".
    try json.objectField("refusal");
    try json.write(null);
    try json.endObject();

    // `ok` is "introduced nothing new", which is the veto's semantics: a client
    // repairing a file that already has violations must not be blocked by the
    // ones it did not cause.
    return verdict.new_count == 0;
}

/// A refusal that still fills the payload's published key set. A client reading
/// `ok` must not have to also handle the key being absent.
fn writeSimulateRefusal(
    json: *std.json.Stringify,
    file_rel: []const u8,
    digest: [64]u8,
    decision: decision_registry.Id,
    message: []const u8,
) !bool {
    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("source_digest");
    try json.write(&digest);
    try json.objectField("ok");
    try json.write(false);
    try json.objectField("new_count");
    try json.write(0);
    try json.objectField("preexisting_count");
    try json.write(0);
    try json.objectField("proposed_content");
    try json.write(null);
    try json.objectField("diagnostics");
    try json.beginArray();
    try json.endArray();
    try json.objectField("refusal");
    try json.beginObject();
    try json.objectField("reason");
    try json.write(decision.wire());
    try json.objectField("message");
    try json.write(message);
    // The next action, from the decision registry rather than from this call
    // site: a client branches on it instead of parsing the message.
    try json.objectField("next_action");
    try json.write(@tagName(decision_registry.get(decision).next_action));
    try json.endObject();
    try json.endObject();
    return false;
}

/// Keep hand-authored test requests readable while the production wire
/// requires every repair to carry the identity a real canonicalize response
/// publishes. Tests for missing or stale bindings call `respond` directly.
fn respondWithCurrentRepairBindings(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var parsed = try parse(allocator, request);
    defer parsed.deinit();
    const root = parsed.value.object;
    const project_root = root.get("project_root").?.string;
    const input = root.get("input").?.object;
    const file = input.get("file").?.string;

    const canonical_root = try agent_identity.canonicalRoot(allocator, testing.io, project_root);
    defer allocator.free(canonical_root);
    const file_rel = try agent_identity.canonicalRelPath(allocator, testing.io, canonical_root, file);
    defer allocator.free(file_rel);
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);
    const source = try zts.file_io.readFile(allocator, abs, module_graph_record.max_source_bytes);
    defer allocator.free(source);
    var graph = try module_graph_record.build(allocator, testing.io, canonical_root, file_rel);
    defer graph.deinit(allocator);

    const binding = RepairBinding.current(agent_identity.sourceDigest(source), .{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = graph.hash,
    });
    const repairs = input.get("repairs").?.array;
    for (repairs.items) |*repair| {
        const arena = parsed.arena.allocator();
        var bound: std.json.ObjectMap = .{};
        try bound.put(arena, "source_digest", .{ .string = &binding.source_digest });
        try bound.put(arena, "profile_id", .{ .string = binding.profile_id });
        try bound.put(arena, "policy_hash", .{ .string = &binding.policy_hash });
        try bound.put(arena, "module_graph_hash", .{ .string = &binding.module_graph_hash });
        try bound.put(arena, "semantics_hash", .{ .string = &binding.semantics_hash });
        try repair.object.put(arena, "bound", .{ .object = bound });
        if (repair.object.get("diagnostic_code") == null) {
            try repair.object.put(arena, "diagnostic_code", .{ .string = "ZTS604" });
        }
    }

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var json: std.json.Stringify = .{ .writer = &encoded.writer };
    try json.write(parsed.value);
    return respond(allocator, encoded.writer.buffered());
}

test "simulate_edit applies repairs to one captured source" {
    const allocator = testing.allocator;
    const source_b = "export function handler(\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const binding = try currentTestRepairBinding(allocator, root, "h.ts");
    const repair = try testRepairJson(
        allocator,
        "replace_let_with_const",
        6,
        "    let name = \"world\";",
        "    const name = \"world\";",
        binding,
        .none,
    );
    defer allocator.free(repair);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{s}]}}}}
    , .{ root, repair });
    defer allocator.free(request);

    var changing_reader = ChangingRootReader{
        .directory = tmp.dir,
        .path = "h.ts",
        .replacement = source_b,
    };
    const raw = try respondWithRootSourceReader(
        allocator,
        request,
        changing_reader.rootSourceReader(),
    );
    defer allocator.free(raw);
    try testing.expectEqual(@as(u32, 1), changing_reader.read_count);

    var response = try parse(allocator, raw);
    defer response.deinit();
    const payload = response.value.object.get("payload").?.object;
    const expected_digest = agent_identity.sourceDigest(let_handler);
    try testing.expectEqualStrings(&expected_digest, payload.get("source_digest").?.string);
    try testing.expect(payload.get("refusal").? == .null);
    const proposed = payload.get("proposed_content").?.string;
    try testing.expect(std.mem.indexOf(u8, proposed, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, proposed, "let name") == null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "the guard runs before the operation does any work" {
    // A stale request never reaches operation dispatch. This repair is
    // deliberately unbound, so a dispatch-first implementation would report
    // malformed_repair instead of the required identity mismatch.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}},
        \\ "expected":{{"policy_hash":"0000000000000000000000000000000000000000000000000000000000000000"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "identity_mismatch",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "simulate_edit round-trips a canonicalize candidate" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // The repair is exactly what `canonicalize` published: same intent name,
    // same `original` snapshot, same replacement. That round trip is what the
    // unified vocabulary bought, and the reason this operation was deferred
    // until it existed.
    const req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(payload.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 0), payload.get("new_count").?.integer);
    try testing.expect(std.mem.indexOf(u8, payload.get("proposed_content").?.string, "const name") != null);
    // Never writes: the file on disk still carries the `let`.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") != null);
}

test "simulate_edit refuses a repair whose snapshot has moved" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // `original` is required for exactly this: a client that read the file,
    // thought about it, and sent repairs against bytes that have since moved
    // must not get a splice into a program it never saw.
    const req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"mars\";","replacement":"    const name = \"mars\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(!payload.get("ok").?.bool);
    try testing.expectEqualStrings("stale_repair", payload.get("refusal").?.object.get("reason").?.string);
    // The published key set is intact on a refusal: a client reading `ok`
    // must not also have to handle the key being absent.
    try testing.expect(payload.get("diagnostics").? == .array);
    try testing.expect(payload.get("proposed_content").? == .null);
}

test "simulate_edit refuses a repair outside the vocabulary" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // The v1 spelling is not the vocabulary. Accepting it here would recreate
    // the second vocabulary inside the protocol that just retired it.
    const req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"canonicalize_let_const","line":6,"original":"x","replacement":"y"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings("unknown_intent", payload.get("refusal").?.object.get("reason").?.string);
}

test "a refusal on the wire carries a published kind and its next action" {
    // The end the registry exists for. A client reads `refusal.reason`, looks
    // it up in `meta.decisions`, and branches on `next_action` - so the string
    // a real refusal emits has to be one of the published identifiers, and the
    // next action beside it has to be the registry's.
    const a = testing.allocator;
    const req =
        \\{"schema_version":2,"operation":"simulate_edit","project_root":".","input":{"file":"packages/tools/tests/fixtures/contract/plain_ts.ts","repairs":[]}}
    ;
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const refusal = parsed.value.object.get("payload").?.object.get("refusal").?.object;
    const reason = refusal.get("reason").?.string;
    const row = blk: {
        for (&decision_registry.decisions) |*candidate| {
            if (std.mem.eql(u8, candidate.id.wire(), reason)) break :blk candidate;
        }
        std.debug.print("refusal names an unpublished kind: {s}\n", .{reason});
        return error.UnpublishedDecisionKind;
    };
    try testing.expectEqualStrings("no_repairs", reason);
    try testing.expectEqualStrings(@tagName(row.next_action), refusal.get("next_action").?.string);
    try testing.expectEqualStrings("fix_the_request", refusal.get("next_action").?.string);
    const envelope_hash = parsed.value.object.get("module_graph_hash").?.string;
    try testing.expect(!std.mem.eql(u8, envelope_hash, &module_graph_record.contextFreeHash()));
}
