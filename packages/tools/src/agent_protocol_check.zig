//! Agent protocol `check` operation and diagnostic rendering.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const json_diagnostics = @import("json_diagnostics.zig");
const precompile = @import("precompile.zig");
const policy_catalog = zts.PolicyCatalog;
const repairPolicy = zts.RepairPolicy;
const testing = std.testing;
const request_mod = @import("agent_protocol_request.zig");
const CapturedFile = request_mod.CapturedFile;
const RootSourceReader = request_mod.RootSourceReader;
const support_mod = @import("agent_protocol_support.zig");
const respond = support_mod.respond;
const parse = support_mod.parse;
const respondWithRootSourceReader = support_mod.respondWithRootSourceReader;
const ChangingRootReader = support_mod.ChangingRootReader;
const dispatch_mod = @import("agent_protocol_dispatch.zig");
const handleRequestWithRootReader = dispatch_mod.handleRequestWithRootReader;

pub fn runCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    json: *std.json.Stringify,
    diagnostics: *std.Io.Writer.Allocating,
    canonical_root: []const u8,
    file: *const CapturedFile,
) !bool {
    // The same bytes the digest covers, so a byte offset published beside a
    // digest indexes into what that digest names.
    const source = file.effective_source;
    const digest = file.source_digest;

    var diag_json: std.json.Stringify = .{ .writer = &diagnostics.writer };

    var result = precompile.runCheckOnlyFromSourceWithOptions(allocator, source, file.absolute_path, .{
        .json_mode = true,
        .sql_schema_path = null,
    }) catch |err| switch (err) {
        // The v1 path reports this as a ZTS700 diagnostic rather than a crash;
        // the v2 wire keeps it a diagnostic too, so the two surfaces agree on
        // what a missing schema is.
        error.MissingSqlSchema => {
            try diag_json.beginArray();
            try writeDiagnostic(&diag_json, allocator, io, canonical_root, .{
                .code = zts.DiagnosticCatalog.driverCode(.missing_sql_schema),
                .severity = "error",
                .message = "zttp:sql queries require a SQL schema, which this operation cannot supply",
                .file = file.relative_path,
                .line = 1,
                .column = 1,
                .suggestion = "configure sqlite in zttp.json, or check this handler through `zts check --sql-schema`",
            }, digest, source);
            try diag_json.endArray();
            try writeCheckPayload(json, null, file.relative_path, digest, 1, 0);
            return false;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    try diag_json.beginArray();
    for (result.json_diagnostics.items) |diag| {
        try writeDiagnostic(&diag_json, allocator, io, canonical_root, diag, digest, source);
    }
    try diag_json.endArray();

    try writeCheckPayload(
        json,
        &result,
        file.relative_path,
        digest,
        result.totalErrors(),
        result.totalWarnings(),
    );
    return result.totalErrors() == 0;
}

pub fn writeCheckPayload(
    json: *std.json.Stringify,
    result: ?*const precompile.CheckResult,
    file_rel: []const u8,
    digest: [64]u8,
    errors: u32,
    warnings: u32,
) !void {
    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("source_digest");
    try json.write(&digest);

    try json.objectField("counts");
    try json.beginObject();
    try json.objectField("errors");
    try json.write(errors);
    try json.objectField("warnings");
    try json.write(warnings);
    try json.endObject();

    try json.objectField("properties");
    if (result) |r| {
        if (r.properties) |props| {
            // Generated from the struct, so a property added to the contract
            // reaches the wire without an edit here and cannot be silently
            // dropped.
            try json.beginObject();
            inline for (@typeInfo(zts.HandlerProperties).@"struct".field_names) |field| {
                try json.objectField(field);
                switch (@FieldType(zts.HandlerProperties, field)) {
                    bool => try json.write(@field(props, field)),
                    ?u32 => if (@field(props, field)) |v| try json.write(v) else try json.write(null),
                    else => @compileError("unhandled HandlerProperties field type: " ++ @typeName(@FieldType(zts.HandlerProperties, field))),
                }
            }
            try json.endObject();
        } else try json.write(null);
    } else try json.write(null);

    // This operation reports source-analysis facts from the contract. It does
    // not reconstruct residual obligations or claim consumer coverage. Only
    // `zttp proofs verify` answers whether the artifact covers its guards.
    try json.objectField("guarded_categories");
    if (result) |r| {
        if (r.contract) |*contract| {
            try json.beginArray();
            inline for (.{
                .{ "env", contract.env.dynamic },
                .{ "egress", contract.egress.dynamic },
                .{ "cache", contract.cache.dynamic },
                .{ "sql", contract.sql.dynamic },
            }) |category| {
                if (category[1]) try json.write(category[0]);
            }
            try json.endArray();
        } else try json.write(null);
    } else try json.write(null);

    try json.objectField("paths");
    if (result) |r| {
        try json.beginObject();
        try json.objectField("enumerated");
        try json.write(r.paths_enumerated);
        try json.objectField("exhaustive");
        try json.write(r.paths_exhaustive);
        // Phase 0 replaced a bare bool with a cause; the wire carries the cause.
        try json.objectField("coverage_note");
        try json.write(r.paths_coverage_note);
        try json.endObject();
    } else try json.write(null);

    try json.objectField("contract_available");
    try json.write(if (result) |r| r.contract != null else false);

    try json.objectField("contract_body");
    if (result) |r| {
        if (r.contract) |*contract| {
            // The precompile contract owns the absolute path it read. The
            // agent protocol is project-root relative, and exposing that host
            // path makes identical projects produce different envelopes and
            // non-replayable tool results. A shallow view is sufficient: the
            // writer only borrows the contract and `file_rel` outlives it.
            var portable_contract = contract.*;
            portable_contract.handler.path = file_rel;
            try json.beginWriteRaw();
            try zts.handler_contract.writeContractJsonV2(&portable_contract, json.writer);
            json.endWriteRaw();
        } else try json.write(null);
    } else try json.write(null);

    try json.endObject();
}

/// One source-bound diagnostic.
///
/// `span` is the half-open byte range of the token the diagnostic points at,
/// carried from the producer's own location. It is the token's extent and not
/// the enclosing construct's - a diagnostic about a `let` binding spans `let`
/// and not the statement - because that is what the parser knows without a
/// second pass, and a wider span nothing computes would be a lie of precision.
/// `start == end` means the producer's position carried no extent at all,
/// which a synthetic or fallback location does.
///
/// `repair_available` answers from `meta.validators` rather than a constant.
/// Spec 4.8 permits advertising an exact repair only when a registered
/// equivalence validator exists, so the flag is true exactly when this
/// diagnostic's repair intent has a row whose method is implemented.
///
/// Seven rows answer true: six declared laws under M4 and the pure chained
/// ternary kernel slice under M3. The validator
/// re-derives the declared law's rewrite from the original and requires the
/// candidate to match it byte for byte. Every other row is still `planned` and
/// answers false.
fn writeDiagnostic(
    json: *std.json.Stringify,
    allocator: std.mem.Allocator,
    io: std.Io,
    canonical_root: []const u8,
    diag: json_diagnostics.JsonDiagnostic,
    digest: [64]u8,
    source: []const u8,
) !void {
    try json.beginObject();
    try json.objectField("code");
    try json.write(diag.code);
    try json.objectField("rule_id");
    if (policy_catalog.findByCode(diag.code)) |rule| {
        try json.write(rule.name);
    } else {
        // The ZTS0xx parser band and the ZTS2xx type-checker band are real
        // codes outside the policy-hashed registry, so they have no rule name.
        try json.write(null);
    }
    try json.objectField("severity");
    try json.write(diag.severity);
    try json.objectField("message");
    try json.write(diag.message);
    try json.objectField("file");
    // Project-relative on the wire. The checker reports the absolute path it
    // was handed, and spec 4.8 resolves every request path inside the project
    // root, so publishing the absolute form would both leak the host layout and
    // hand back a path the client cannot use in a follow-up request. A path
    // that will not relativize is outside the root and is published as-is
    // rather than hidden.
    if (agent_identity.canonicalRelPath(allocator, io, canonical_root, diag.file)) |rel| {
        defer allocator.free(rel);
        try json.write(rel);
    } else |_| {
        try json.write(diag.file);
    }
    try json.objectField("source_digest");
    try json.write(&digest);
    try json.objectField("line");
    try json.write(diag.line);
    try json.objectField("column");
    try json.write(diag.column);
    try json.objectField("byte_offset");
    // Derived from the reported line and column, independently of the span
    // below, which the producer carries from the token's own extent. Two
    // derivations of one number, and a test pins them equal: a disagreement
    // means a producer's position and the source it was computed against have
    // drifted apart, which is the failure this field would otherwise hide.
    try json.write(byteOffsetOf(source, diag.line, diag.column));
    try json.objectField("span");
    try json.beginObject();
    try json.objectField("start");
    try json.write(diag.start_offset);
    try json.objectField("end");
    try json.write(diag.end_offset);
    try json.endObject();
    try json.objectField("suggestion");
    if (diag.suggestion) |sug| try json.write(sug) else try json.write(null);
    try json.objectField("repair_available");
    try json.write(repairAvailableFor(diag));
    try json.endObject();
}

/// True when the rule behind this diagnostic carries a repair intent whose
/// equivalence validator is registered and implemented. A code with no rule, or
/// a rule with no typed repair, answers false: an unclassified rewrite is
/// exactly what must not be advertised.
fn repairAvailableFor(diag: json_diagnostics.JsonDiagnostic) bool {
    const intent = diag.repair_intent orelse return false;
    return repairPolicy.isGradable(intent);
}

/// Byte offset of a 1-based line and column. Exact for the reported position;
/// the end of the range is not published because no producer computes one.
pub fn byteOffsetOf(source: []const u8, line: u32, column: u32) usize {
    var current_line: u32 = 1;
    var idx: usize = 0;
    while (idx < source.len and current_line < line) : (idx += 1) {
        if (source[idx] == '\n') current_line += 1;
    }
    const offset = idx + @as(usize, if (column > 0) column - 1 else 0);
    return @min(offset, source.len);
}

const ErrorRootReader = struct {
    read_count: u32 = 0,

    fn read(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
        _: usize,
    ) anyerror![]u8 {
        const reader: *ErrorRootReader = @ptrCast(@alignCast(context orelse return error.MissingContext));
        reader.read_count += 1;
        return error.OutOfMemory;
    }

    fn rootSourceReader(reader: *ErrorRootReader) RootSourceReader {
        return .{
            .context = reader,
            .readFn = read,
        };
    }
};

test "check dispatches when graph discovery rejects an imported resolver target" {
    const allocator = testing.allocator;
    const source =
        \\import { gone } from "./gone.ts";
        \\function handler(req: Request): Response {
        \\  return Response.json({ value: gone });
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer allocator.free(request);

    const raw = try respond(allocator, request);
    defer allocator.free(raw);
    var response = try parse(allocator, raw);
    defer response.deinit();
    const envelope = response.value.object;
    try testing.expect(envelope.get("error") == null);
    try testing.expect(envelope.get("payload").? == .object);
    try testing.expectEqualStrings(
        "h.ts",
        envelope.get("payload").?.object.get("file").?.string,
    );
}

test "a root read allocation failure reports file_unreadable" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = "export const value = 1;\n" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);
    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer allocator.free(request);

    var error_reader = ErrorRootReader{};
    const raw = try respondWithRootSourceReader(
        allocator,
        request,
        error_reader.rootSourceReader(),
    );
    defer allocator.free(raw);
    try testing.expectEqual(@as(u32, 1), error_reader.read_count);

    var response = try parse(allocator, raw);
    defer response.deinit();
    const protocol_error = response.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", protocol_error.get("code").?.string);
    try testing.expectEqualStrings("input.file", protocol_error.get("field").?.string);
}

test "check on a clean handler succeeds with no diagnostics" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqual(@as(usize, 0), obj.get("diagnostics").?.array.items.len);

    const payload = obj.get("payload").?.object;
    try testing.expectEqualStrings("h.ts", payload.get("file").?.string);
    try testing.expectEqual(@as(usize, 64), payload.get("source_digest").?.string.len);
    try testing.expectEqual(@as(i64, 0), payload.get("counts").?.object.get("errors").?.integer);
    const contract_body = payload.get("contract_body") orelse return error.TestUnexpectedResult;
    try testing.expect(contract_body == .object);
    const contract_version = contract_body.object.get("version") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 2), contract_version.integer);
}

test "check binds graph digest diagnostics and contract to one captured root source" {
    const allocator = testing.allocator;
    const source_a =
        \\function handler(req: Request): Response {
        \\  return Response.json({ now: Date.now() });
        \\}
    ;
    const source_b = "export function handler(\n";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "h.ts",
        .data = source_a,
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer allocator.free(request);

    var changing_reader = ChangingRootReader{
        .directory = tmp.dir,
        .path = "h.ts",
        .replacement = source_b,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try handleRequestWithRootReader(
        allocator,
        testing.io,
        request,
        &output.writer,
        changing_reader.rootSourceReader(),
    );

    try testing.expectEqual(@as(u32, 1), changing_reader.read_count);

    var expected_graph = try module_graph_record.buildWithEntrySource(
        allocator,
        testing.io,
        root,
        "h.ts",
        source_a,
    );
    defer expected_graph.deinit(allocator);
    const expected_digest = agent_identity.sourceDigest(source_a);

    var response = try parse(allocator, output.writer.buffered());
    defer response.deinit();
    const envelope = response.value.object;
    try testing.expectEqualStrings(&expected_graph.hash, envelope.get("module_graph_hash").?.string);

    const payload = envelope.get("payload").?.object;
    try testing.expectEqualStrings(&expected_digest, payload.get("source_digest").?.string);

    const diagnostics = envelope.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const diagnostic = diagnostics.items[0].object;
    try testing.expectEqualStrings("ZTS500", diagnostic.get("code").?.string);
    try testing.expectEqualStrings(&expected_digest, diagnostic.get("source_digest").?.string);

    try testing.expect(payload.get("contract_available").?.bool);
    const contract = payload.get("contract_body").?.object;
    try testing.expectEqual(@as(i64, 2), contract.get("version").?.integer);
    const handler = contract.get("handler").?.object;
    try testing.expectEqualStrings("h.ts", handler.get("path").?.string);
    try testing.expectEqual(@as(i64, 1), handler.get("line").?.integer);
    try testing.expectEqual(@as(i64, 17), handler.get("column").?.integer);
    const spec_diagnostics = contract.get("spec_diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), spec_diagnostics.items.len);
    try testing.expectEqualStrings(
        "ZTS500",
        spec_diagnostics.items[0].object.get("code").?.string,
    );

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings(source_b, on_disk);
}

test "check response is identical for identical projects at different roots" {
    const allocator = testing.allocator;
    const source =
        \\export function handler(req: Request): Response {
        \\    return Response.json({ ok: true });
        \\}
        \\
    ;
    var first = testing.tmpDir(.{});
    defer first.cleanup();
    var second = testing.tmpDir(.{});
    defer second.cleanup();
    try first.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = source });
    try second.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = source });
    const first_root = try std.Io.Dir.realPathFileAlloc(first.dir, testing.io, ".", allocator);
    defer allocator.free(first_root);
    const second_root = try std.Io.Dir.realPathFileAlloc(second.dir, testing.io, ".", allocator);
    defer allocator.free(second_root);

    const first_request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{first_root});
    defer allocator.free(first_request);
    const second_request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{second_root});
    defer allocator.free(second_request);
    const first_response = try respond(allocator, first_request);
    defer allocator.free(first_response);
    const second_response = try respond(allocator, second_request);
    defer allocator.free(second_response);

    try testing.expectEqualStrings(first_response, second_response);
}

test "check publishes a null contract_body when no contract exists" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "module.ts",
        .data = "export function handler(\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const request = try allocator.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"module.ts"}}}}
    , .{root});
    defer allocator.free(request);
    const response = try respond(allocator, request);
    defer allocator.free(response);

    var parsed = try parse(allocator, response);
    defer parsed.deinit();
    const payload_value = parsed.value.object.get("payload") orelse return error.TestUnexpectedResult;
    const contract_available = payload_value.object.get("contract_available") orelse return error.TestUnexpectedResult;
    const contract_body = payload_value.object.get("contract_body") orelse return error.TestUnexpectedResult;
    try testing.expect(!contract_available.bool);
    try testing.expect(contract_body == .null);
}

const ternary_chain_handler =
    \\export function handler(req: Request): Response {
    \\  const n = req.method === "GET" ? 1 : req.method === "POST" ? 2 : 3;
    \\  return Response.json({ n: n });
    \\}
    \\
;

test "check on a rejected handler binds every diagnostic to the digest" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A chained ternary: ZTS621, an error-severity canonical-profile rule.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = ternary_chain_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(obj.get("error") == null);

    const digest = obj.get("payload").?.object.get("source_digest").?.string;
    const diags = obj.get("diagnostics").?.array;
    try testing.expect(diags.items.len >= 1);

    var found_chain = false;
    for (diags.items) |item| {
        const d = item.object;
        // Every diagnostic binds the same digest and a project-relative path,
        // so a client can re-validate without knowing the host layout.
        try testing.expectEqualStrings(digest, d.get("source_digest").?.string);
        try testing.expectEqualStrings("h.ts", d.get("file").?.string);
        try testing.expectEqual(
            std.mem.eql(u8, d.get("code").?.string, "ZTS621"),
            d.get("repair_available").?.bool,
        );
        // The span is a half-open byte range into the bytes the digest covers,
        // and its start is the same number `byte_offset` reaches from the line
        // and column. The two are computed independently - the producer carries
        // the span off the token, the writer walks the source for the offset -
        // so equality here is a cross-check and not a restatement.
        const span = d.get("span").?.object;
        const start: usize = @intCast(span.get("start").?.integer);
        const end: usize = @intCast(span.get("end").?.integer);
        try testing.expectEqual(@as(i64, @intCast(start)), d.get("byte_offset").?.integer);
        try testing.expect(end >= start);
        try testing.expect(end <= ternary_chain_handler.len);
        if (std.mem.eql(u8, d.get("code").?.string, "ZTS621")) {
            found_chain = true;
            try testing.expectEqualStrings("canonical_ternary_chain", d.get("rule_id").?.string);
            try testing.expectEqualStrings("error", d.get("severity").?.string);
            // The diagnostic anchors on the `?` of the outer conditional, the
            // first `?` in the fixture, and the span covers that one byte.
            const outer_question = std.mem.indexOf(u8, ternary_chain_handler, "? 1 :").?;
            try testing.expectEqual(@as(i64, @intCast(outer_question)), d.get("byte_offset").?.integer);
            try testing.expectEqual(outer_question + 1, end);
            // A range, not a point: the diagnostic names the token it points
            // at. An empty span here would mean the producer had no extent,
            // which is the state this task closed.
            try testing.expect(end > start);
        }
    }
    try testing.expect(found_chain);
}

test "repair_available follows the exact diagnostic intent and implemented validator" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ZTS620 carries `drop_redundant_bool_compare`, whose registry row reached
    // `.implemented`. The sibling test above also pins the M3 direction for a
    // pure ZTS621 instance. Both matter: a flag that ignores the producer's
    // exact instance intent can advertise a repair whose precondition failed.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\export function handler(req: Request): Response {
        \\  const ready = true;
        \\  if (ready === true) { return Response.json({ ok: true }); }
        \\  return Response.json({ ok: false });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();

    var found = false;
    for (parsed.value.object.get("diagnostics").?.array.items) |item| {
        const d = item.object;
        if (!std.mem.eql(u8, d.get("code").?.string, "ZTS620")) continue;
        found = true;
        try testing.expectEqualStrings("canonical_redundant_bool_compare", d.get("rule_id").?.string);
        try testing.expect(d.get("repair_available").?.bool);
    }
    try testing.expect(found);
}

test "success is exactly no error diagnostic, not no diagnostic" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ZTS305 unused_variable is emitted at warning severity (measured), so this
    // handler carries a diagnostic and still succeeds - spec 4.8's success rule.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    const unused = 1;
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const diags = obj.get("diagnostics").?.array;

    var warnings: usize = 0;
    var errors: usize = 0;
    for (diags.items) |item| {
        const sev = item.object.get("severity").?.string;
        if (std.mem.eql(u8, sev, "warning")) warnings += 1;
        if (std.mem.eql(u8, sev, "error")) errors += 1;
    }
    try testing.expect(warnings >= 1);
    try testing.expectEqual(@as(usize, 0), errors);
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqual(
        @as(i64, @intCast(warnings)),
        obj.get("payload").?.object.get("counts").?.object.get("warnings").?.integer,
    );
}

test "check publishes the path-coverage cause, not only a bool" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try a.print(
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const paths = parsed.value.object.get("payload").?.object.get("paths").?.object;
    // The handler is one unbranched return: one path, fully enumerated.
    try testing.expectEqual(@as(i64, 1), paths.get("enumerated").?.integer);
    try testing.expect(paths.get("exhaustive").?.bool);
    // Phase 0 replaced a bare bool with a cause; the wire carries the cause.
    try testing.expectEqualStrings("exhaustive", paths.get("coverage_note").?.string);
}

test "check never answers success false with an empty diagnostics array" {
    // The property, not the one input that motivated it. An unterminated string
    // was raised by the stripper before the parser ran, and `check --json`
    // answered `success:false` with no diagnostics at all: a machine client was
    // told the file failed and told nothing about why, which is the one shape a
    // diagnostic wire must never take.
    const a = testing.allocator;
    const sources = [_][]const u8{
        // The motivating input.
        "export function handler(req) {\n  const s = \"unterminated;\n  return Response.text(s);\n}\n",
        // A file that fails type-position admission for a different reason.
        "export function handler(req: Request): any {\n  return Response.text(\"x\");\n}\n",
        // A file that fails on runtime syntax in the parser.
        "export function handler(req) {\n  const n = 0x;\n  return Response.json({ n: n });\n}\n",
        // A file that fails after parsing, in the checker.
        "export function handler(req) { return Response.json({ ok: true }); }\n",
        // And one that does not fail at all, so the assertion below is about
        // the pairing rather than about everything being broken.
        "structural G<T> = Proof<T, \"state_isolated\">;\nexport function handler(req: Request): G<Response> {\n  return Response.json({ ok: true });\n}\n",
    };

    var saw_failure = false;
    var saw_success = false;
    for (sources) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
        const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
        defer a.free(root);

        const req = try a.print(
            \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
        , .{root});
        defer a.free(req);
        const out = try respond(a, req);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();

        const success = parsed.value.object.get("success").?.bool;
        const diagnostics = parsed.value.object.get("diagnostics").?.array;
        if (success) {
            saw_success = true;
        } else {
            saw_failure = true;
            if (diagnostics.items.len == 0) {
                std.debug.print("check answered success:false with no diagnostics for:\n{s}\n", .{source});
                return error.FailureWithoutDiagnostic;
            }
        }
    }
    // The floor, both ways: a run where nothing failed would satisfy the loop
    // without testing the property, and one where nothing succeeded would mean
    // the fixtures stopped being a mix.
    try testing.expect(saw_failure);
    try testing.expect(saw_success);
}
