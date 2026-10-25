//! Agent protocol `canonicalize` and `normalize` operations.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const canonicalize = @import("canonicalize.zig");
const idiomCatalog = zts.IdiomCatalog;
const repairPolicy = zts.RepairPolicy;
const testing = std.testing;
const request_mod = @import("agent_protocol_request.zig");
const CapturedFile = request_mod.CapturedFile;
const envelope_mod = @import("agent_protocol_envelope.zig");
const Identity = envelope_mod.Identity;
const RepairBinding = request_mod.RepairBinding;
const support_mod = @import("agent_protocol_support.zig");
const let_handler = support_mod.let_handler;
const ChangingRootReader = support_mod.ChangingRootReader;
const respondWithRootSourceReader = support_mod.respondWithRootSourceReader;
const parse = support_mod.parse;
const respond = support_mod.respond;

// ---------------------------------------------------------------------------
// canonicalize and normalize
// ---------------------------------------------------------------------------

/// Spec 4.8: "Until a rewrite has a registered equivalence validator,
/// `canonicalize` and `normalize` MUST report it as a proposed refactor, not a
/// mechanical repair."
///
/// The grade was a constant while no row was implemented, which made it true
/// by accident. It answers from the registry now, so a rewrite is called
/// mechanical exactly when something discharges it - the same condition
/// `repair_available` keys on, read from the same place.
fn candidateGrade(intent: zts.RepairIntent) []const u8 {
    return if (repairPolicy.isGradable(intent)) "mechanical_repair" else "proposed_refactor";
}

pub fn boolField(input: std.json.Value, name: []const u8) bool {
    const obj = switch (input) {
        .object => |o| o,
        else => return false,
    };
    const value = obj.get(name) orelse return false;
    return value == .bool and value.bool;
}

pub fn runCanonicalize(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    file: *const CapturedFile,
    identity: Identity,
    input: std.json.Value,
) !bool {
    const source = file.effective_source;
    const digest = file.source_digest;

    var result = try canonicalize.collectFromSource(allocator, source, file.absolute_path);
    defer result.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file.relative_path);
    try json.objectField("source_digest");
    try json.write(&digest);

    try json.objectField("candidates");
    try json.beginArray();
    for (result.repairs.items) |repair| {
        try json.beginObject();
        // D3 §5's `repair` carries the typed intent, not a per-producer string.
        // `Refactor` used to carry one and that is what made the third parallel
        // vocabulary: five of its names differed from the tag by more than
        // spelling. The legacy names survive only on the frozen v1 surface.
        try json.objectField("intent");
        try json.write(@tagName(repair.intent));
        try json.objectField("diagnostic_code");
        try json.write(repair.diagnostic_code);
        try json.objectField("grade");
        try json.write(candidateGrade(repair.intent));
        // The row from the equivalence-validator registry, so a client reads
        // what would discharge this rewrite and whether anything runs it, in
        // the same object as the rewrite. Null for an intent with no row.
        try json.objectField("validator");
        if (repairPolicy.findValidator(repair.intent)) |row| {
            try json.beginObject();
            try json.objectField("method");
            try json.write(row.method.id());
            try json.objectField("status");
            try json.write(@tagName(row.status));
            try json.objectField("precondition");
            if (row.precondition) |p| try json.write(p) else try json.write(null);
            try json.endObject();
        } else {
            try json.write(null);
        }
        // The idiom row this repair realizes, read off the repair rather than
        // hardcoded null: the line-derived repairs all fix canonical-profile
        // restrictions and carry none, but the vocabulary is one now, so a
        // span-derived repair that realizes a row publishes it here.
        try json.objectField("idiom_id");
        if (repair.idiom_id) |id| try json.write(id) else try json.write(null);
        // The half-open byte span, which is what a repair is keyed on. `line`
        // and `column` stay beside it: they are what the v1 surface names and
        // what a human reads.
        try json.objectField("span");
        try json.beginObject();
        try json.objectField("start");
        try json.write(repair.start_offset);
        try json.objectField("end");
        try json.write(repair.end_offset);
        try json.endObject();
        try json.objectField("line");
        try json.write(repair.line);
        try json.objectField("column");
        try json.write(repair.column);
        try json.objectField("message");
        try json.write(repair.message);
        // D3 §5: the v1 JSON drops original_line, so a client cannot
        // re-validate staleness. The v2 wire publishes it.
        try json.objectField("original");
        try json.write(repair.original);
        try json.objectField("replacement");
        try json.write(repair.replacement);
        try json.objectField("bound");
        try RepairBinding.current(digest, identity).writeJson(json);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("simulation");
    if (boolField(input, "simulate")) {
        const summary = try canonicalize.simulateRepairsFromSource(
            allocator,
            source,
            file.absolute_path,
            &result,
        );
        try json.beginObject();
        try json.objectField("ok");
        try json.write(summary.ok);
        try json.objectField("total");
        try json.write(summary.total);
        try json.objectField("new_count");
        try json.write(summary.new_count);
        try json.objectField("preexisting_count");
        try json.write(summary.preexisting_count);
        try json.endObject();
    } else {
        // Present and null rather than absent: the key set of a payload is part
        // of the operation's published schema, and a client should not have to
        // distinguish "not requested" from "field removed".
        try json.write(null);
    }

    try json.endObject();
    // Candidates are proposals, not failures. A file with refactors available
    // is still a file that canonicalized successfully.
    return true;
}

pub fn runNormalize(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    file: *const CapturedFile,
) !bool {
    const source = file.effective_source;
    const digest = file.source_digest;

    var result = try canonicalize.normalizeSourceWithOptions(
        allocator,
        source,
        file.absolute_path,
        .{
            .sql_schema_path = null,
            .layout = true,
        },
    );
    defer result.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file.relative_path);
    try json.objectField("source_digest");
    try json.write(&digest);
    try json.objectField("converged");
    try json.write(result.converged);
    try json.objectField("fully_canonical");
    try json.write(result.fully_canonical);
    try json.objectField("iterations");
    try json.write(result.iterations);
    try json.objectField("residual");
    try json.write(result.residual);

    try json.objectField("rewrite_trace");
    try json.beginArray();
    for (result.rewrite_trace.items) |intent| {
        const name = @tagName(intent);
        try json.beginObject();
        try json.objectField("intent");
        try json.write(name);
        try json.objectField("grade");
        try json.write(candidateGrade(intent));
        // The phase 0 back-reference: an applied intent resolves to the idiom
        // row it realizes, where one exists.
        try json.objectField("idiom_id");
        if (idiomCatalog.findByRewriteRule(name)) |idiom| {
            try json.write(idiom.id);
        } else {
            try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("canonical_source");
    try json.write(result.canonical_source);

    try json.objectField("residual_diagnostics");
    try json.beginArray();
    for (result.residual_diagnostics.items) |diag| {
        try json.beginObject();
        try json.objectField("code");
        try json.write(diag.code);
        try json.objectField("severity");
        try json.write(diag.severity);
        try json.objectField("message");
        try json.write(diag.message);
        try json.objectField("line");
        try json.write(diag.line);
        try json.objectField("column");
        try json.write(diag.column);
        try json.objectField("suggestion");
        if (diag.suggestion) |sug| try json.write(sug) else try json.write(null);
        try json.objectField("repair_intent");
        if (diag.repair_intent) |intent| try json.write(intent) else try json.write(null);
        try json.objectField("reason");
        try json.write(diag.reason);
        try json.endObject();
    }
    try json.endArray();

    try json.endObject();
    // Spec 4.8 requires normalization to reach a fixed point. Residual
    // canonical-band diagnostics mean it did not, so the operation reports the
    // shortfall rather than calling a partial normalization a success.
    return result.converged and result.fully_canonical;
}

test "canonicalize derives candidates from one captured source" {
    const allocator = testing.allocator;
    const source_b = "export function handler(\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts","simulate":true}}}}
    , .{root});
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
    const candidates = payload.get("candidates").?.array;
    try testing.expectEqual(@as(usize, 1), candidates.items.len);
    try testing.expectEqualStrings(
        "ZTS604",
        candidates.items[0].object.get("diagnostic_code").?.string,
    );
    const simulation = payload.get("simulation").?.object;
    try testing.expect(simulation.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 0), simulation.get("total").?.integer);
    try testing.expectEqual(@as(i64, 0), simulation.get("new_count").?.integer);
    try testing.expectEqual(@as(i64, 0), simulation.get("preexisting_count").?.integer);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "normalize derives canonical source from one captured source" {
    const allocator = testing.allocator;
    const source_b = "export function handler(\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
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
    const canonical_source = payload.get("canonical_source").?.string;
    try testing.expect(std.mem.indexOf(u8, canonical_source, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, canonical_source, "let name") == null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "canonicalize publishes the span a repair is keyed on" {
    // The producing end of the round trip: a candidate carries the span, and
    // the span names exactly the bytes its `original` snapshot copied. A
    // candidate whose span and snapshot disagreed would round-trip into a
    // `stale_repair` the client could not have avoided.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const candidates = parsed.value.object.get("payload").?.object.get("candidates").?.array;
    try testing.expect(candidates.items.len >= 1);
    // The one avoidable `let` in the fixture is the first candidate, and its
    // snapshot is the whole `let` line (line 6).
    const first = candidates.items[0].object;
    try testing.expectEqualStrings("replace_let_with_const", first.get("intent").?.string);
    try testing.expectEqualStrings("    let name = \"world\";", first.get("original").?.string);
    for (candidates.items) |item| {
        const c = item.object;
        const span = c.get("span").?.object;
        const start: usize = @intCast(span.get("start").?.integer);
        const end: usize = @intCast(span.get("end").?.integer);
        try testing.expect(end <= let_handler.len);
        try testing.expectEqualStrings(let_handler[start..end], c.get("original").?.string);
    }
}

test "canonicalize candidates carry a grade and the original span text" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    // Candidates are proposals, not failures.
    try testing.expect(parsed.value.object.get("success").?.bool);

    const candidates = payload.get("candidates").?.array;
    try testing.expect(candidates.items.len >= 1);
    const first = candidates.items[0].object;
    // Spec 4.8: a candidate is a mechanical repair exactly when a registered
    // validator discharges it, and a proposed refactor otherwise. This one is
    // `replace_let_with_const`, whose M4 row is implemented.
    try testing.expectEqualStrings("mechanical_repair", first.get("grade").?.string);
    try testing.expect(first.get("replacement").? == .string);
    // D3 §5: v1 drops original_line at the JSON boundary, so a client cannot
    // re-validate staleness. The v2 wire carries it.
    try testing.expect(first.get("original").? == .string);
    // The fixture opens with two empty lines, so the `let` is on line 6.
    try testing.expectEqual(@as(i64, 6), first.get("line").?.integer);

    // D3 §5: the v2 candidate carries the typed intent, not a producer-local
    // string. `canonicalize_let_const` is the v1 name for this row and must not
    // appear here - shipping it would freeze the third vocabulary into the
    // protocol, which is the thing item 8 exists to prevent.
    try testing.expectEqualStrings("replace_let_with_const", first.get("intent").?.string);
    try testing.expect(first.get("kind") == null);

    // The validator row travels with the rewrite, so a client reads what would
    // discharge it and whether anything runs it without a second request.
    const validator = first.get("validator").?.object;
    try testing.expectEqualStrings("M4", validator.get("method").?.string);
    try testing.expectEqualStrings("implemented", validator.get("status").?.string);
    try testing.expect(validator.get("precondition").? == .string);
}

test "canonicalize simulates only when asked, and says so either way" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const plain = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(plain);
    const plain_out = try respond(a, plain);
    defer a.free(plain_out);
    var plain_parsed = try parse(a, plain_out);
    defer plain_parsed.deinit();
    // Present and null: the key set is part of the published schema, so a
    // client never has to tell "not requested" from "field removed".
    try testing.expect(plain_parsed.value.object.get("payload").?.object.get("simulation").? == .null);

    const simulated = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts","simulate":true}}}}
    , .{root});
    defer a.free(simulated);
    const sim_out = try respond(a, simulated);
    defer a.free(sim_out);
    var sim_parsed = try parse(a, sim_out);
    defer sim_parsed.deinit();
    const summary = sim_parsed.value.object.get("payload").?.object.get("simulation").?.object;
    try testing.expect(summary.get("ok").? == .bool);
    try testing.expect(summary.get("new_count").? == .integer);
    try testing.expect(summary.get("preexisting_count").? == .integer);
}

test "normalize reaches a fixed point and writes nothing to disk" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(payload.get("converged").?.bool);
    // One `let` takes one rewrite pass.
    try testing.expectEqual(@as(i64, 1), payload.get("iterations").?.integer);
    const canonical = payload.get("canonical_source").?.string;
    try testing.expect(std.mem.indexOf(u8, canonical, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, canonical, "let name") == null);
    // The rewrite happened in memory only.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .unlimited);
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "normalize with write true is refused, not silently ignored" {
    // Accepting the flag and ignoring it would report a rewrite the client
    // believes was persisted.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts","write":true}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("operation_not_implemented", err.get("code").?.string);
    try testing.expectEqualStrings("input.write", err.get("field").?.string);
    try testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "propose_change_set") != null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .unlimited);
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "normalize write refusal precedes the stale identity guard" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts","write":true}},"expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, module_graph_record.contextFreeHash() });
    defer allocator.free(request);

    const raw = try respond(allocator, request);
    defer allocator.free(raw);
    var response = try parse(allocator, raw);
    defer response.deinit();
    const protocol_error = response.value.object.get("error").?.object;
    try testing.expectEqualStrings("operation_not_implemented", protocol_error.get("code").?.string);
    try testing.expectEqualStrings("input.write", protocol_error.get("field").?.string);
}
