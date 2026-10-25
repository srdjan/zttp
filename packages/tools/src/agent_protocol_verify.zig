//! Agent protocol `verify` operation.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const precompile = @import("precompile.zig");
const testing = std.testing;
const request_mod = @import("agent_protocol_request.zig");
const CapturedFile = request_mod.CapturedFile;
const support_mod = @import("agent_protocol_support.zig");
const ChangingRootReader = support_mod.ChangingRootReader;
const respondWithRootSourceReader = support_mod.respondWithRootSourceReader;
const parse = support_mod.parse;
const let_handler = support_mod.let_handler;
const respond = support_mod.respond;

/// `verify`: answer, per requested property, whether the compiler discharged it.
///
/// Distinct from `check`, which reports every property and every diagnostic and
/// leaves the client to search. A client asking "does this hold" wants that
/// question answered for the properties it named, including the answer that a
/// name it used is not a property this compiler decides.
///
/// The verdicts are projected from `proofTrace`, the compiler's own rendering,
/// rather than recomputed. Recomputing would be a second implementation of the
/// thing being reported on, and the two could disagree - which is the failure
/// mode a verification surface can least afford.
pub fn runVerify(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    file: *const CapturedFile,
    input: ?std.json.Value,
) !bool {
    var result = precompile.runCheckOnlyFromSourceWithOptions(
        allocator,
        file.effective_source,
        file.absolute_path,
        .{
            .json_mode = true,
            .sql_schema_path = null,
        },
    ) catch |err| switch (err) {
        // Every property is undecided rather than false: the analysis never
        // ran, and reporting `analyzer_not_proved` would claim a verdict nothing
        // produced.
        error.MissingSqlSchema => {
            try writeVerifyPayload(allocator, json, file.relative_path, file.source_digest, null, input);
            return false;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    try writeVerifyPayload(
        allocator,
        json,
        file.relative_path,
        file.source_digest,
        result.proof_trace_json,
        input,
    );
    return result.totalErrors() == 0;
}

/// The requested property ids, or every id in the registry when `properties` is
/// absent or empty. Asking about nothing is a request nobody means to make, and
/// answering it with an empty array would look like "none of them hold".
fn writeVerifyPayload(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    file_rel: []const u8,
    digest: [64]u8,
    proof_trace_json: ?[]const u8,
    input: ?std.json.Value,
) !void {
    var traces: ?std.json.Parsed(std.json.Value) = null;
    defer if (traces) |*t| t.deinit();
    if (proof_trace_json) |raw| {
        traces = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null;
    }

    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("source_digest");
    try json.write(&digest);

    try json.objectField("results");
    try json.beginArray();

    const requested: ?[]const std.json.Value = blk: {
        const obj = (input orelse break :blk null).object;
        const value = obj.get("properties") orelse break :blk null;
        if (value != .array or value.array.items.len == 0) break :blk null;
        break :blk value.array.items;
    };

    if (requested) |items| {
        for (items) |item| {
            if (item != .string) continue;
            try writeVerifyResult(json, item.string, traces);
        }
    } else {
        for (zts.proof_trace.verifiers) |v| {
            try writeVerifyResult(json, v.id, traces);
        }
    }

    try json.endArray();
    try json.endObject();
}

pub fn writeStringArray(json: *std.json.Stringify, items: []const []const u8) !void {
    try json.beginArray();
    for (items) |item| try json.write(item);
    try json.endArray();
}

fn writeVerifyResult(
    json: *std.json.Stringify,
    id: []const u8,
    traces: ?std.json.Parsed(std.json.Value),
) !void {
    try json.beginObject();
    try json.objectField("property");
    try json.write(id);

    const kind = zts.proof_trace.verifierKind(id) orelse {
        // Named, and not a property this compiler decides. Reported per
        // property rather than failing the request: a client discovering the
        // registry by asking is a normal use of this operation.
        try json.objectField("grade");
        try json.write("unknown_property");
        try json.objectField("evidence");
        try json.write(null);
        try json.endObject();
        return;
    };

    const entry = findTraceEntry(traces, id);
    if (entry == null) {
        // In the registry, absent from the trace: the file produced no
        // contract, so nothing decided this either way.
        try json.objectField("grade");
        try json.write("not_decided");
        try json.objectField("evidence");
        try json.beginObject();
        try json.objectField("kind");
        try json.write(kind.asString());
        try json.objectField("summary");
        try json.write("the file did not analyze far enough to produce a contract");
        try json.endObject();
        try json.endObject();
        return;
    }

    const obj = entry.?.object;
    const holds = if (obj.get("holds")) |h| h == .bool and h.bool else false;
    try json.objectField("grade");
    // The analyzer's own verdict about a source file. Deliberately not
    // "proven": nothing here checked an artifact, and no consumer accepted
    // anything. Artifact-level acceptance is `zttp proofs verify`, and it
    // reports a separate set of states. Reporting the weaker result under the
    // stronger word is the confusion the proof-carrying work exists to remove.
    try json.write(if (holds) "analyzer_proved" else "analyzer_not_proved");

    try json.objectField("evidence");
    try json.beginObject();
    try json.objectField("kind");
    // The trace's own `kind` when it carries one: a property's family is
    // static, but the trace is what actually decided this file.
    if (obj.get("kind")) |k| {
        if (k == .string) try json.write(k.string) else try json.write(kind.asString());
    } else {
        try json.write(kind.asString());
    }
    try json.objectField("summary");
    if (obj.get("summary")) |s| {
        if (s == .string) try json.write(s.string) else try json.write(null);
    } else {
        try json.write(null);
    }
    // The concrete demonstration, when the compiler derived one. A failed
    // verify without it is a verdict; with it, it is a reproduction.
    try json.objectField("counterexample");
    if (obj.get("counterexample")) |c| try json.write(c) else try json.write(null);
    try json.objectField("resisted");
    if (obj.get("resisted")) |r| try json.write(r) else try json.write(null);
    try json.endObject();

    try json.endObject();
}

fn findTraceEntry(traces: ?std.json.Parsed(std.json.Value), id: []const u8) ?std.json.Value {
    const parsed = traces orelse return null;
    if (parsed.value != .object) return null;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, id)) return kv.value_ptr.*;
    }
    return null;
}

const captured_refusal_source =
    "const value: any = 1;\n" ++
    "function handler(req: Request): Response { return Response.text(\"captured\"); }\n";
const captured_refusal_digest = "c8b4df16533c13f0566e41167dfd71099034d0660147424605c41ab19be39989";

test "check ignores content override and retains one captured refusal" {
    const allocator = testing.allocator;
    const replacement_source =
        "function handler(req: Request): Response { return Response.text(\"replacement\"); }\n";
    const override_source =
        "function handler(req: Request): Response { return Response.text(\"override\"); }\n";

    const captured_digest = agent_identity.sourceDigest(captured_refusal_source);
    try testing.expectEqualStrings(captured_refusal_digest, &captured_digest);
    const replacement_digest = agent_identity.sourceDigest(replacement_source);
    const override_digest = agent_identity.sourceDigest(override_source);
    try testing.expect(!std.mem.eql(u8, &captured_digest, &replacement_digest));
    try testing.expect(!std.mem.eql(u8, &captured_digest, &override_digest));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "h.ts",
        .data = captured_refusal_source,
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts","content":{f}}}}}
    , .{ root, std.json.fmt(override_source, .{}) });
    defer allocator.free(request);

    var changing_reader = ChangingRootReader{
        .directory = tmp.dir,
        .path = "h.ts",
        .replacement = replacement_source,
    };
    const raw = try respondWithRootSourceReader(
        allocator,
        request,
        changing_reader.rootSourceReader(),
    );
    defer allocator.free(raw);
    try testing.expectEqual(@as(u32, 1), changing_reader.read_count);

    var expected_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        captured_refusal_source,
    );
    defer expected_graph.deinit(allocator);

    var response = try parse(allocator, raw);
    defer response.deinit();
    const envelope = response.value.object;
    try testing.expect(envelope.get("error") == null);
    try testing.expect(!envelope.get("success").?.bool);
    try testing.expectEqualStrings(
        &expected_graph.hash,
        envelope.get("module_graph_hash").?.string,
    );

    const payload = envelope.get("payload").?.object;
    try testing.expectEqualStrings(
        captured_refusal_digest,
        payload.get("source_digest").?.string,
    );
    try testing.expectEqual(@as(i64, 1), payload.get("counts").?.object.get("errors").?.integer);
    try testing.expect(!payload.get("contract_available").?.bool);
    try testing.expect(payload.get("contract_body").? == .null);

    const diagnostics = envelope.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const diagnostic = diagnostics.items[0].object;
    try testing.expectEqualStrings("ZTS041", diagnostic.get("code").?.string);
    try testing.expectEqual(@as(i64, 1), diagnostic.get("line").?.integer);
    try testing.expectEqual(@as(i64, 14), diagnostic.get("column").?.integer);
    try testing.expectEqualStrings(
        captured_refusal_digest,
        diagnostic.get("source_digest").?.string,
    );

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(replacement_source, on_disk);
}

test "verify derives its verdict from one captured source" {
    const allocator = testing.allocator;
    const source_a =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    const source_b = "export function handler(\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source_a });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"]}}}}
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
    const expected_digest = agent_identity.sourceDigest(source_a);
    try testing.expectEqualStrings(&expected_digest, payload.get("source_digest").?.string);
    const results = payload.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("canonical", results.items[0].object.get("property").?.string);
    try testing.expectEqualStrings("analyzer_proved", results.items[0].object.get("grade").?.string);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "verify uses a refusal override after one captured root read" {
    const allocator = testing.allocator;
    const disk_source =
        "function handler(req: Request): Response { return Response.text(\"disk\"); }\n";
    const replacement_source =
        "function handler(req: Request): Response { return Response.text(\"replacement\"); }\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = disk_source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","content":{f}}}}}
    , .{ root, std.json.fmt(captured_refusal_source, .{}) });
    defer allocator.free(request);

    var changing_reader = ChangingRootReader{
        .directory = tmp.dir,
        .path = "h.ts",
        .replacement = replacement_source,
    };
    const raw = try respondWithRootSourceReader(
        allocator,
        request,
        changing_reader.rootSourceReader(),
    );
    defer allocator.free(raw);
    try testing.expectEqual(@as(u32, 1), changing_reader.read_count);

    var expected_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        captured_refusal_source,
    );
    defer expected_graph.deinit(allocator);

    var response = try parse(allocator, raw);
    defer response.deinit();
    const envelope = response.value.object;
    try testing.expect(envelope.get("error") == null);
    try testing.expect(!envelope.get("success").?.bool);
    try testing.expectEqualStrings(
        &expected_graph.hash,
        envelope.get("module_graph_hash").?.string,
    );
    try testing.expectEqual(@as(usize, 0), envelope.get("diagnostics").?.array.items.len);

    const payload = envelope.get("payload").?.object;
    try testing.expectEqualStrings(
        captured_refusal_digest,
        payload.get("source_digest").?.string,
    );
    const results = payload.get("results").?.array;
    try testing.expectEqual(@as(usize, 19), results.items.len);
    try testing.expectEqual(@as(usize, 19), zts.proof_trace.verifiers.len);
    for (results.items, zts.proof_trace.verifiers) |result, verifier| {
        try testing.expectEqualStrings(
            verifier.id,
            result.object.get("property").?.string,
        );
        try testing.expectEqualStrings("not_decided", result.object.get("grade").?.string);
    }

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(replacement_source, on_disk);
}

test "verify binds its digest to the bytes it analyzed" {
    // A verdict about supplied content must not be bound to the digest of the
    // file on disk: that would name bytes nobody checked.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const file_req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"]}}}}
    , .{root});
    defer a.free(file_req);
    const file_out = try respond(a, file_req);
    defer a.free(file_out);
    var from_file = try parse(a, file_out);
    defer from_file.deinit();

    const content_req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"],"content":"export function handler(req: Request): Response {{ return Response.json({{ ok: true }}); }}\\n"}}}}
    , .{root});
    defer a.free(content_req);
    const content_out = try respond(a, content_req);
    defer a.free(content_out);
    var from_content = try parse(a, content_out);
    defer from_content.deinit();

    const file_digest = from_file.value.object.get("payload").?.object.get("source_digest").?.string;
    const content_digest = from_content.value.object.get("payload").?.object.get("source_digest").?.string;
    try testing.expect(!std.mem.eql(u8, file_digest, content_digest));
}

test "verify override binds graph identity and stale guards to supplied content" {
    const allocator = testing.allocator;
    const disk_source = "export function handler(req: Request): Response { return Response.text(\"disk\"); }\n";
    const override_source = "export function handler(req: Request): Response { return Response.text(\"override\"); }\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = disk_source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    var override_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        override_source,
    );
    defer override_graph.deinit(allocator);
    var disk_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        disk_source,
    );
    defer disk_graph.deinit(allocator);
    try testing.expect(!std.mem.eql(u8, &override_graph.hash, &disk_graph.hash));

    const accepted_request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"],"content":{f}}},"expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, std.json.fmt(override_source, .{}), override_graph.hash });
    defer allocator.free(accepted_request);
    const accepted_raw = try respond(allocator, accepted_request);
    defer allocator.free(accepted_raw);
    var accepted = try parse(allocator, accepted_raw);
    defer accepted.deinit();
    try testing.expect(accepted.value.object.get("error") == null);
    try testing.expectEqualStrings(
        &override_graph.hash,
        accepted.value.object.get("module_graph_hash").?.string,
    );
    const override_digest = agent_identity.sourceDigest(override_source);
    try testing.expectEqualStrings(
        &override_digest,
        accepted.value.object.get("payload").?.object.get("source_digest").?.string,
    );

    const stale_request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"],"content":{f}}},"expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, std.json.fmt(override_source, .{}), disk_graph.hash });
    defer allocator.free(stale_request);
    const stale_raw = try respond(allocator, stale_request);
    defer allocator.free(stale_raw);
    var stale = try parse(allocator, stale_raw);
    defer stale.deinit();
    const stale_error = stale.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", stale_error.get("code").?.string);
    try testing.expectEqualStrings("expected.module_graph_hash", stale_error.get("field").?.string);
    try testing.expectEqualStrings(
        &override_graph.hash,
        stale.value.object.get("module_graph_hash").?.string,
    );
}

test "verify ignores non-string content and accepts an empty string override" {
    const allocator = testing.allocator;
    const disk_source = "export function handler(req: Request): Response { return Response.text(\"disk\"); }\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = disk_source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    var disk_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        disk_source,
    );
    defer disk_graph.deinit(allocator);
    const non_string_request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"],"content":17}}}}
    , .{root});
    defer allocator.free(non_string_request);
    const non_string_raw = try respond(allocator, non_string_request);
    defer allocator.free(non_string_raw);
    var non_string = try parse(allocator, non_string_raw);
    defer non_string.deinit();
    const disk_digest = agent_identity.sourceDigest(disk_source);
    try testing.expectEqualStrings(
        &disk_graph.hash,
        non_string.value.object.get("module_graph_hash").?.string,
    );
    try testing.expectEqualStrings(
        &disk_digest,
        non_string.value.object.get("payload").?.object.get("source_digest").?.string,
    );

    var empty_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        "",
    );
    defer empty_graph.deinit(allocator);
    const empty_request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"],"content":""}}}}
    , .{root});
    defer allocator.free(empty_request);
    const empty_raw = try respond(allocator, empty_request);
    defer allocator.free(empty_raw);
    var empty = try parse(allocator, empty_raw);
    defer empty.deinit();
    const empty_digest = agent_identity.sourceDigest("");
    try testing.expectEqualStrings(
        &empty_graph.hash,
        empty.value.object.get("module_graph_hash").?.string,
    );
    try testing.expectEqualStrings(
        &empty_digest,
        empty.value.object.get("payload").?.object.get("source_digest").?.string,
    );
}

test "verify reads disk before accepting a content override" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"missing.ts","properties":["canonical"],"content":""}}}}
    , .{root});
    defer allocator.free(request);

    const raw = try respond(allocator, request);
    defer allocator.free(raw);
    var response = try parse(allocator, raw);
    defer response.deinit();
    const protocol_error = response.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", protocol_error.get("code").?.string);
    try testing.expectEqualStrings("input.file", protocol_error.get("field").?.string);
}

test "verify answers only the properties it was asked about" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A secret reaching the response body: `no_secret_leakage` fails with a
    // derived counterexample, `deterministic` holds, and a name outside the
    // registry is a fact about the request rather than a failed request.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\import { env } from "zttp:env";
        \\function handler(req: Request): Response {
        \\  const secret = env("SECRET");
        \\  if (secret === undefined) return Response.json({ ok: true });
        \\  return Response.json({ k: secret });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["no_secret_leakage","deterministic","not_a_property"]}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);

    const results = parsed.value.object.get("payload").?.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 3), results.items.len);

    const leak = results.items[0].object;
    try testing.expectEqualStrings("no_secret_leakage", leak.get("property").?.string);
    try testing.expectEqualStrings("analyzer_not_proved", leak.get("grade").?.string);
    const evidence = leak.get("evidence").?.object;
    try testing.expectEqualStrings("flow-trace", evidence.get("kind").?.string);
    // A failed verify with a counterexample is a reproduction, not a verdict.
    try testing.expect(evidence.get("counterexample").? == .object);

    try testing.expectEqualStrings("analyzer_proved", results.items[1].object.get("grade").?.string);

    // Named, and not a property this compiler decides. Reported per property:
    // a client discovering the registry by asking is a normal use.
    const unknown = results.items[2].object;
    try testing.expectEqualStrings("unknown_property", unknown.get("grade").?.string);
    try testing.expect(unknown.get("evidence").? == .null);
}

test "verify with no property list answers the whole registry" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const results = parsed.value.object.get("payload").?.object.get("results").?.array;
    // Asking about nothing is a request nobody means to make, so an absent
    // list means every property rather than an empty answer that would read
    // as "none of them hold".
    try testing.expectEqual(zts.proof_trace.verifiers.len, results.items.len);
}

test "a verifier's published grades are the grades verify can actually answer with" {
    // The registry says which grades a registered property can carry. If
    // `writeVerifyResult` learns a fifth grade and this list does not, the
    // published schema describes an answer the wire no longer gives.
    // `unknown_property` is excluded on purpose: it is the answer to a name
    // outside the registry, so no registry row can ever be graded with it.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["not_a_property"]}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const results = parsed.value.object.get("payload").?.object.get("results").?.array;
    try testing.expectEqual(@as(usize, 1), results.items.len);
    const grade = results.items[0].object.get("grade").?.string;
    try testing.expectEqualStrings("unknown_property", grade);
    for (zts.proof_trace.verify_grades) |g| {
        try testing.expect(!std.mem.eql(u8, g, grade));
    }
}
