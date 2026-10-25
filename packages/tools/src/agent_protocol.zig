//! `zts agent --stdin-json`: the version-2 agent protocol transport.
//!
//! One request object in, one response object out (spec 4.8). The version-1
//! commands stay exactly as they are - nothing here edits a v1 emitter - and
//! their bare arrays and v1 objects are not advanced-profile responses.
//!
//! Every field name on this wire is snake_case, and every byte is written
//! through `std.json.Stringify`. Response JSON goes to stdout; logs go to
//! stderr; the process exits 0 whenever it produced a response, including a
//! response carrying a protocol `error` object, because the envelope carries
//! the verdict.

const std = @import("std");
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const expert_meta = @import("expert_meta.zig");
const edit_simulate = @import("edit_simulate.zig");
const json_diagnostics = @import("json_diagnostics.zig");
const precompile = @import("precompile.zig");
const canonicalize = @import("canonicalize.zig");
const example_registry = @import("example_registry.zig");
const decision_registry = @import("decision_registry.zig");

const policy_catalog = zts.PolicyCatalog;
const idiomCatalog = zts.IdiomCatalog;
const restrictionCatalog = zts.RestrictionCatalog;
const repairPolicy = zts.RepairPolicy;
const moduleMetadata = zts.ModuleMetadata;

const agent_protocol_envelope_mod = @import("agent_protocol_envelope.zig");
const agent_protocol_request_mod = @import("agent_protocol_request.zig");
const agent_protocol_dispatch_mod = @import("agent_protocol_dispatch.zig");
const agent_protocol_check_mod = @import("agent_protocol_check.zig");
const agent_protocol_cli_mod = @import("agent_protocol_cli.zig");
const agent_protocol_support_mod = @import("agent_protocol_support.zig");
pub const Operation = agent_protocol_envelope_mod.Operation;
pub const ErrorCode = agent_protocol_envelope_mod.ErrorCode;
pub const Status = agent_protocol_envelope_mod.Status;
pub const OperationSpec = agent_protocol_envelope_mod.OperationSpec;
pub const operations = agent_protocol_envelope_mod.operations;
pub const DeferredSection = agent_protocol_envelope_mod.DeferredSection;
pub const deferred_sections = agent_protocol_envelope_mod.deferred_sections;
const takesFile = agent_protocol_envelope_mod.takesFile;
pub const specFor = agent_protocol_envelope_mod.specFor;
pub const schemaHash = agent_protocol_envelope_mod.schemaHash;
pub const exampleRegistryHash = agent_protocol_envelope_mod.exampleRegistryHash;
pub const RootSourceReader = agent_protocol_request_mod.RootSourceReader;
const CapturedFile = agent_protocol_request_mod.CapturedFile;
pub const handleRequest = agent_protocol_dispatch_mod.handleRequest;
pub const handleRequestWithRootReader = agent_protocol_dispatch_mod.handleRequestWithRootReader;
const writeCheckPayload = agent_protocol_check_mod.writeCheckPayload;
const byteOffsetOf = agent_protocol_check_mod.byteOffsetOf;
pub const runWithArgs = agent_protocol_cli_mod.runWithArgs;
const respond = agent_protocol_support_mod.respond;
const parse = agent_protocol_support_mod.parse;
const currentTestRepairBinding = agent_protocol_support_mod.currentTestRepairBinding;
const TestStaleBindingField = agent_protocol_support_mod.TestStaleBindingField;
const testRepairJson = agent_protocol_support_mod.testRepairJson;
const let_handler = agent_protocol_support_mod.let_handler;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every implemented operation emits exactly its declared payload_fields" {
    const a = testing.allocator;
    for (&operations) |*spec| {
        if (spec.status != .implemented) continue;
        // A file-bound operation gets a real fixture: an empty input would
        // answer with a protocol error and an empty payload, and the gate would
        // pass while proving nothing.
        const input = if (takesFile(spec))
            "{\"file\":\"packages/tools/tests/fixtures/contract/plain_ts.ts\"}"
        else
            "{}";
        const req = try a.print(
            \\{{"schema_version":2,"operation":"{s}","project_root":".","input":{s}}}
        , .{ @tagName(spec.op), input });
        defer a.free(req);
        const out = try respond(a, req);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();

        const payload = parsed.value.object.get("payload").?.object;
        try testing.expectEqual(spec.payload_fields.len, payload.count());
        for (spec.payload_fields) |field| {
            if (payload.get(field) == null) {
                std.debug.print("{s} declares payload field {s} and does not emit it\n", .{ @tagName(spec.op), field });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "negotiation fires before the operation is even looked at" {
    // A v1 client naming an operation this binary never had must still reach
    // the frozen response, not unknown_operation.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":99,"operation":"transpile","project_root":"/nope","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("schema_version_unsupported").?.bool);
}

test "an unknown operation is a protocol error, not a diagnostic" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"transpile","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    try testing.expectEqual(@as(usize, 0), obj.get("diagnostics").?.array.items.len);
    try testing.expectEqualStrings("transpile", obj.get("operation").?.string);
    const err = obj.get("error").?.object;
    try testing.expectEqualStrings("unknown_operation", err.get("code").?.string);
    try testing.expectEqualStrings("operation", err.get("field").?.string);
}

test "an error response still carries the identity block" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"transpile","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(&zts.policyHash(), obj.get("policy_hash").?.string);
    try testing.expectEqualStrings("zts-model-1", obj.get("profile_id").?.string);
}

test "apply_repair is outside the direct-cut operation vocabulary" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const request = try a.print(
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[]}}}}
    , .{root});
    defer a.free(request);
    const output = try respond(a, request);
    defer a.free(output);
    var parsed = try parse(a, output);
    defer parsed.deinit();
    try testing.expectEqualStrings("unknown_operation", parsed.value.object.get("error").?.object.get("code").?.string);
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .unlimited);
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "captured root releases owned bytes and paths after graph allocation failure" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = "export const value = 1;\n" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", allocator);
    defer allocator.free(root);

    const FailAfterRead = struct {
        fn read(
            context: ?*anyopaque,
            capture_allocator: std.mem.Allocator,
            _: std.Io,
            path: []const u8,
            max_bytes: usize,
        ) anyerror![]u8 {
            const failing: *testing.FailingAllocator = @ptrCast(@alignCast(context.?));
            const source = try zts.file_io.readFile(capture_allocator, path, max_bytes);
            failing.fail_index = failing.alloc_index;
            return source;
        }
    };
    var failing = testing.FailingAllocator.init(allocator, .{});
    try testing.expectError(error.OutOfMemory, CapturedFile.init(
        failing.allocator(),
        testing.io,
        .{ .context = &failing, .readFn = FailAfterRead.read },
        root,
        "h.ts",
        .modules,
        .null,
    ));
    try testing.expect(failing.has_induced_failure);
}

test "check payload reports guarded categories separately from properties" {
    const allocator = testing.allocator;
    const digest = @as([64]u8, @splat('0'));

    var no_result_output: std.Io.Writer.Allocating = .init(allocator);
    defer no_result_output.deinit();
    var no_result_json: std.json.Stringify = .{ .writer = &no_result_output.writer };
    try writeCheckPayload(&no_result_json, null, "handler.ts", digest, 1, 0);
    var no_result = try parse(allocator, no_result_output.writer.buffered());
    defer no_result.deinit();
    try testing.expect(no_result.value.object.get("guarded_categories").? == .null);

    var static_result = precompile.CheckResult{
        .contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts")),
    };
    defer static_result.deinit(allocator);
    var static_output: std.Io.Writer.Allocating = .init(allocator);
    defer static_output.deinit();
    var static_json: std.json.Stringify = .{ .writer = &static_output.writer };
    try writeCheckPayload(&static_json, &static_result, "handler.ts", digest, 0, 0);
    var static_payload = try parse(allocator, static_output.writer.buffered());
    defer static_payload.deinit();
    try testing.expectEqual(@as(usize, 0), static_payload.value.object.get("guarded_categories").?.array.items.len);

    var guarded_result = precompile.CheckResult{
        .contract = zts.handler_contract.emptyContract(try allocator.dupe(u8, "handler.ts")),
    };
    defer guarded_result.deinit(allocator);
    guarded_result.contract.?.env.dynamic = true;
    guarded_result.contract.?.egress.dynamic = true;
    guarded_result.contract.?.cache.dynamic = true;
    guarded_result.contract.?.sql.dynamic = true;
    var guarded_output: std.Io.Writer.Allocating = .init(allocator);
    defer guarded_output.deinit();
    var guarded_json: std.json.Stringify = .{ .writer = &guarded_output.writer };
    try writeCheckPayload(&guarded_json, &guarded_result, "handler.ts", digest, 0, 0);
    var guarded_payload = try parse(allocator, guarded_output.writer.buffered());
    defer guarded_payload.deinit();
    const categories = guarded_payload.value.object.get("guarded_categories").?.array;
    try testing.expectEqual(@as(usize, 4), categories.items.len);
    for (categories.items, [_][]const u8{ "env", "egress", "cache", "sql" }) |actual, expected| {
        try testing.expectEqualStrings(expected, actual.string);
    }
    try testing.expect(guarded_payload.value.object.get("properties").? == .null);
}

test "a bound canonicalize candidate round-trips unchanged through simulate" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const propose_req = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(propose_req);
    const propose_out = try respond(a, propose_req);
    defer a.free(propose_out);
    var proposed = try parse(a, propose_out);
    defer proposed.deinit();

    const proposal = proposed.value.object;
    const candidate = proposal.get("payload").?.object.get("candidates").?.array.items[0];
    const bound = candidate.object.get("bound").?.object;
    try testing.expectEqualStrings(
        proposal.get("payload").?.object.get("source_digest").?.string,
        bound.get("source_digest").?.string,
    );
    try testing.expectEqualStrings(proposal.get("profile_id").?.string, bound.get("profile_id").?.string);
    try testing.expectEqualStrings(proposal.get("policy_hash").?.string, bound.get("policy_hash").?.string);
    try testing.expectEqualStrings(
        proposal.get("module_graph_hash").?.string,
        bound.get("module_graph_hash").?.string,
    );

    const simulate_req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{f}]}}}}
    , .{ root, std.json.fmt(candidate, .{}) });
    defer a.free(simulate_req);
    const simulate_out = try respond(a, simulate_req);
    defer a.free(simulate_out);
    var simulated = try parse(a, simulate_out);
    defer simulated.deinit();
    const simulated_payload = simulated.value.object.get("payload").?.object;
    try testing.expect(simulated_payload.get("ok").?.bool);
    try testing.expect(std.mem.indexOf(u8, simulated_payload.get("proposed_content").?.string, "const name") != null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "simulate refuses an unbound repair" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    {
        const operation = "simulate_edit";
        const req = try a.print(
            \\{{"schema_version":2,"operation":"{s}","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}}}}
        , .{ operation, root });
        defer a.free(req);
        const out = try respond(a, req);
        defer a.free(out);
        var refused = try parse(a, out);
        defer refused.deinit();
        try testing.expectEqualStrings(
            "malformed_repair",
            refused.value.object.get("payload").?.object.get("refusal").?.object.get("reason").?.string,
        );
    }

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "simulate refuses every stale repair binding" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const binding = try currentTestRepairBinding(a, root, "h.ts");

    for ([_]TestStaleBindingField{ .source_digest, .profile_id, .policy_hash, .module_graph_hash, .semantics_hash }) |stale_field| {
        const repair = try testRepairJson(
            a,
            "replace_let_with_const",
            6,
            "    let name = \"world\";",
            "    const name = \"world\";",
            binding,
            stale_field,
        );
        defer a.free(repair);
        {
            const operation = "simulate_edit";
            const req = try a.print(
                \\{{"schema_version":2,"operation":"{s}","project_root":"{s}","input":{{"file":"h.ts","repairs":[{s}]}}}}
            , .{ operation, root, repair });
            defer a.free(req);
            const out = try respond(a, req);
            defer a.free(out);
            var refused = try parse(a, out);
            defer refused.deinit();
            try testing.expectEqualStrings(
                "stale_repair",
                refused.value.object.get("payload").?.object.get("refusal").?.object.get("reason").?.string,
            );
        }
    }

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "simulate refuses a mixed-binding batch atomically" {
    const a = testing.allocator;
    const source =
        \\
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    let first = "a";
        \\    let second = "b";
        \\    return Response.json({ first: first, second: second });
        \\}
        \\
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const binding = try currentTestRepairBinding(a, root, "h.ts");
    const first = try testRepairJson(a, "replace_let_with_const", 6, "    let first = \"a\";", "    const first = \"a\";", binding, .none);
    defer a.free(first);
    const second = try testRepairJson(a, "replace_let_with_const", 7, "    let second = \"b\";", "    const second = \"b\";", binding, .profile_id);
    defer a.free(second);

    {
        const operation = "simulate_edit";
        const req = try a.print(
            \\{{"schema_version":2,"operation":"{s}","project_root":"{s}","input":{{"file":"h.ts","repairs":[{s},{s}]}}}}
        , .{ operation, root, first, second });
        defer a.free(req);
        const out = try respond(a, req);
        defer a.free(out);
        var refused = try parse(a, out);
        defer refused.deinit();
        try testing.expectEqualStrings(
            "stale_repair",
            refused.value.object.get("payload").?.object.get("refusal").?.object.get("reason").?.string,
        );
    }

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(source, on_disk);
}

test "an external client completes propose, simulate, verify over the wire" {
    // Item 8's observable. Three `respond` calls and nothing else: no
    // canonicalize call in process, no shared state between steps, and each
    // request carries only what the previous response published.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // 1. Propose.
    const propose_req = try a.print(
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(propose_req);
    const propose_out = try respond(a, propose_req);
    defer a.free(propose_out);
    var proposed = try parse(a, propose_out);
    defer proposed.deinit();
    const candidate = proposed.value.object.get("payload").?.object.get("candidates").?.array.items[0];

    // 2. Simulate, using the candidate's own fields verbatim.
    const simulate_req = try a.print(
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{f}]}}}}
    , .{ root, std.json.fmt(candidate, .{}) });
    defer a.free(simulate_req);
    const simulate_out = try respond(a, simulate_req);
    defer a.free(simulate_out);
    var simulated = try parse(a, simulate_out);
    defer simulated.deinit();
    const sim_payload = simulated.value.object.get("payload").?.object;
    try testing.expect(sim_payload.get("ok").?.bool);

    // 3. Verify the candidate itself. Without the `content` override the client
    // could only ask about the file it has not repaired, and would have to
    // write the candidate to disk merely to ask about it.
    const verify_req = try a.print(
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["state_isolated","canonical"],"content":{f}}}}}
    , .{ root, std.json.fmt(sim_payload.get("proposed_content").?.string, .{}) });
    defer a.free(verify_req);
    const verify_out = try respond(a, verify_req);
    defer a.free(verify_out);
    var verified = try parse(a, verify_out);
    defer verified.deinit();

    const results = verified.value.object.get("payload").?.object.get("results").?.array;
    for (results.items) |r| {
        try testing.expectEqualStrings("analyzer_proved", r.object.get("grade").?.string);
    }

    // The file on disk never changed: the whole cycle is read-only.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") != null);
}

test "every diagnostic publishes a span, and it is not vacuous" {
    // The floor under the span field. A producer that filled `end` with `start`
    // everywhere would satisfy "every diagnostic has a span" while publishing
    // no range at all, so the assertion is on the range being real - and on the
    // bytes it names being the ones the message is about.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\export function handler(req: Request): Response {
        \\  let name = "world";
        \\  return Response.json({ name: name });
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
    const diags = parsed.value.object.get("diagnostics").?.array;
    try testing.expect(diags.items.len >= 1);

    var saw_let = false;
    for (diags.items) |item| {
        const d = item.object;
        const span = d.get("span").?.object;
        const start: usize = @intCast(span.get("start").?.integer);
        const end: usize = @intCast(span.get("end").?.integer);
        try testing.expect(end > start);
        if (std.mem.eql(u8, d.get("code").?.string, "ZTS604")) {
            saw_let = true;
            const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
            defer a.free(on_disk);
            // The avoidable-let rule points at the `let` keyword, so that is
            // exactly what its span must cover.
            try testing.expectEqualStrings("let", on_disk[start..end]);
        }
    }
    try testing.expect(saw_let);

    // The section retires in the same change that makes it answerable.
    const meta_req = try a.print(
        \\{{"schema_version":2,"operation":"meta","project_root":"{s}","input":{{}}}}
    , .{root});
    defer a.free(meta_req);
    const meta_out = try respond(a, meta_req);
    defer a.free(meta_out);
    var meta_parsed = try parse(a, meta_out);
    defer meta_parsed.deinit();
    for (meta_parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "diagnostic_span"));
    }
}

test "byte_offset indexes into the bytes the digest covers" {
    const source = "export const a = 1;\nexport const b = 2;\n";
    try testing.expectEqual(@as(usize, 0), byteOffsetOf(source, 1, 1));
    try testing.expectEqual(@as(usize, 7), byteOffsetOf(source, 1, 8));
    try testing.expectEqual(@as(usize, 20), byteOffsetOf(source, 2, 1));
    // A column past the end clamps rather than pointing outside the buffer.
    try testing.expectEqual(source.len, byteOffsetOf(source, 9, 400));
}

test "every admitted surface form has an example, and every example names one" {
    // Both directions over the feature table. A form with no example is a hole
    // an agent has to guess its way across; an example naming a form the
    // profile does not admit teaches a program the compiler refuses.
    for (json_diagnostics.allowed_feature_names) |name| {
        if (example_registry.findByFeature(name) == null) {
            std.debug.print("admitted form has no example: {s}\n", .{name});
            return error.MissingExample;
        }
    }
    for (&example_registry.examples) |entry| {
        var admitted = false;
        for (json_diagnostics.allowed_feature_names) |name| {
            if (std.mem.eql(u8, name, entry.feature)) admitted = true;
        }
        if (!admitted) {
            std.debug.print("example names a form that is not admitted: {s}\n", .{entry.feature});
            return error.UnknownExampleFeature;
        }
    }
    try testing.expectEqual(json_diagnostics.allowed_feature_names.len, example_registry.examples.len);
}

test "every published example checks clean, at every severity" {
    // The legality gate. `runCheckOnlyFromSourceWithOptions` is the same path `zts check`
    // takes, so an example that stops being legal fails here rather than
    // teaching a form this compiler now refuses. Warnings count: an example
    // that checks with a warning is one an agent would copy into a warning.
    const a = testing.allocator;
    for (&example_registry.examples) |entry| {
        var result = try precompile.runCheckOnlyFromSourceWithOptions(a, entry.source, "example.ts", .{
            .json_mode = true,
        });
        defer result.deinit(a);
        for (result.json_diagnostics.items) |diag| {
            std.debug.print(
                "example for {s} reports {s} ({s}): {s}\n",
                .{ entry.feature, diag.code, diag.severity, diag.message },
            );
        }
        try testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    }
}

test "every published module example checks clean and names live modules" {
    const a = testing.allocator;
    try testing.expect(example_registry.module_examples.len > 0);
    for (&example_registry.module_examples) |entry| {
        for (entry.modules) |specifier| {
            var found = false;
            for (zts.builtinModules) |binding| {
                if (std.mem.eql(u8, binding.specifier, specifier)) found = true;
            }
            if (!found) {
                std.debug.print("module example {s} names unknown module {s}\n", .{ entry.name, specifier });
                return error.UnknownExampleModule;
            }
        }

        var result = try precompile.runCheckOnlyFromSourceWithOptions(a, entry.source, "module-example.ts", .{
            .json_mode = true,
        });
        defer result.deinit(a);
        for (result.json_diagnostics.items) |diag| {
            std.debug.print(
                "module example {s} reports {s} ({s}): {s}\n",
                .{ entry.name, diag.code, diag.severity, diag.message },
            );
        }
        try testing.expectEqual(@as(usize, 0), result.json_diagnostics.items.len);
    }
}

test "every published example exercises the form it names" {
    // A clean example that no longer contains its form still checks clean, so
    // legality alone would let an edit hollow one out. The evidence is read
    // from the parse tree or the direct syntax store wherever either records
    // the form, and from the source only for the three that leave no trace.
    const a = testing.allocator;
    for (&example_registry.examples) |entry| {
        var frontend: zts.DirectCheckSource = undefined;
        try frontend.initCompileInPlace(a, a, entry.source, "example.ts");
        defer frontend.deinit();
        const accepted = frontend.acceptedCapabilities() orelse return error.TestExpectedExample;
        const view = accepted.ir_view;

        const found = switch (entry.evidence) {
            .node => |tag| blk: {
                var i: zts.parser.NodeIndex = 0;
                while (i < view.nodeCount()) : (i += 1) {
                    if (view.getTag(i) == tag) break :blk true;
                }
                break :blk false;
            },
            .var_kind => |kind| blk: {
                var i: zts.parser.NodeIndex = 0;
                while (i < view.nodeCount()) : (i += 1) {
                    if (view.getTag(i) != .var_decl) continue;
                    const decl = view.getVarDecl(i) orelse continue;
                    if (decl.kind == kind) break :blk true;
                }
                break :blk false;
            },
            .binary_operator => |op| blk: {
                var i: zts.parser.NodeIndex = 0;
                while (i < view.nodeCount()) : (i += 1) {
                    if (view.getTag(i) != .binary_op) continue;
                    const bin = view.getBinary(i) orelse continue;
                    if (bin.op == op) break :blk true;
                }
                break :blk false;
            },
            .syntax => |kind| switch (kind) {
                .parameter_annotation => accepted.type_store.parameter_annotations.items.len > 0,
                .predicate_return => blk: {
                    for (accepted.type_store.function_signatures.items) |signature| {
                        const returned = signature.return_syntax orelse continue;
                        if (std.meta.activeTag(returned.structure) == .predicate) break :blk true;
                    }
                    break :blk false;
                },
            },
            .source_text => |text| std.mem.indexOf(u8, entry.source, text.needle) != null,
        };

        if (!found) {
            std.debug.print("example for {s} does not exercise the form it names\n", .{entry.feature});
            return error.ExampleDoesNotExerciseItsForm;
        }
    }
}

test "the example evidence check can fail, so its verdict means something" {
    // The floor under the gate above. A walk that answered true for everything
    // would pass every row while proving nothing, so this asks it for a form
    // no example contains: `break` is admitted by this profile and appears in
    // none of them.
    const a = testing.allocator;
    const entry = example_registry.findByFeature("match expression") orelse
        return error.TestExpectedExample;

    var frontend: zts.DirectCheckSource = undefined;
    try frontend.initCompileInPlace(a, a, entry.source, "example.ts");
    defer frontend.deinit();
    const accepted = frontend.acceptedCapabilities() orelse return error.TestExpectedExample;
    const view = accepted.ir_view;

    var saw_break = false;
    var saw_match = false;
    var i: zts.parser.NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        const tag = view.getTag(i) orelse continue;
        if (tag == .break_stmt) saw_break = true;
        if (tag == .match_expr) saw_match = true;
    }
    try testing.expect(saw_match);
    try testing.expect(!saw_break);
}

test "two independently parsed identical types serialize to one digest" {
    // What the published version is a version OF. Without this the section
    // would advertise a stable identity that nothing had measured.
    const a = testing.allocator;
    var pool = zts.TypePool.init(a);
    defer pool.deinit(a);

    const source = "{ id: string, tags: string[] }";
    const first = zts.parseTypeText(&pool, a, source);
    const second = zts.parseTypeText(&pool, a, source);
    try testing.expect(first != second); // the pool does not intern

    const digest_a = try zts.typeDigest(&pool, a, first);
    const digest_b = try zts.typeDigest(&pool, a, second);
    try testing.expectEqualSlices(u8, &digest_a, &digest_b);

    // The floor: a different type gets a different digest, so the equality
    // above is the encoding's doing and not a constant.
    const other = zts.parseTypeText(&pool, a, "{ id: number, tags: string[] }");
    const digest_c = try zts.typeDigest(&pool, a, other);
    try testing.expect(!std.mem.eql(u8, &digest_a, &digest_c));
}

comptime {
    _ = @import("agent_protocol_envelope.zig");
    _ = @import("agent_protocol_meta.zig");
    _ = @import("agent_protocol_check.zig");
    _ = @import("agent_protocol_verify.zig");
    _ = @import("agent_protocol_simulate.zig");
    _ = @import("agent_protocol_canon.zig");
}
