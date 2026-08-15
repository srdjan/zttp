//! Host-only capability for applying a previously simulated v2 repair set.
//!
//! This module deliberately exports no `ToolDef`. The model may select and
//! preview repairs, but only the host loop can receive this capability after
//! its approval boundary.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const agent_identity = zts_cli.agent_identity;
const agent_protocol = zts_cli.agent_protocol;
const TextBuffer = @import("../text_buffer.zig").TextBuffer;

pub const ExpectedIdentity = struct {
    profile_id: []const u8,
    policy_hash: []const u8,
    module_graph_hash: []const u8,
};

pub const ApplyRequest = struct {
    workspace_root: []const u8,
    file: []const u8,
    repairs_json: []const u8,
    expected: ExpectedIdentity,
    proposed_content: []const u8,
};

pub const Applied = struct {
    source_digest: [64]u8,
    module_graph_hash: [64]u8,
};

pub const Refusal = struct {
    code: []u8,
    message: []u8,

    pub fn deinit(self: *Refusal, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    applied: Applied,
    refused: Refusal,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .applied => {},
            .refused => |*refusal| refusal.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Injected write edge used by the loop. Tests can provide a recording or
/// refusing implementation without exposing a registry operation.
pub const RepairWriter = struct {
    context: ?*anyopaque,
    apply_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ApplyRequest,
    ) anyerror!Outcome,

    pub fn apply(
        self: RepairWriter,
        allocator: std.mem.Allocator,
        io: std.Io,
        request: ApplyRequest,
    ) anyerror!Outcome {
        return self.apply_fn(self.context, allocator, io, request);
    }

    pub fn protocol() RepairWriter {
        return .{ .context = null, .apply_fn = applyProtocol };
    }
};

fn applyProtocol(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ApplyRequest,
) anyerror!Outcome {
    var repairs = std.json.parseFromSlice(std.json.Value, allocator, request.repairs_json, .{}) catch
        return error.InvalidRepairsJson;
    defer repairs.deinit();
    if (repairs.value != .array or repairs.value.array.items.len == 0) return error.InvalidRepairsJson;

    const canonical_root = try agent_identity.canonicalRoot(allocator, io, request.workspace_root);
    defer allocator.free(canonical_root);
    const preview_request = try encodeRequest(allocator, canonical_root, request, repairs.value, "simulate_edit");
    defer allocator.free(preview_request);

    const preview_json = try invokeProtocol(allocator, io, preview_request, "simulate_edit");
    defer allocator.free(preview_json);
    var preview = try parseEnvelope(allocator, preview_json, "simulate_edit");
    defer preview.deinit();
    if (!preview.success()) return refusalFromEnvelope(allocator, &preview);
    if (!matchesExpectedIdentity(preview.root(), request.expected, true)) return error.MalformedProtocolResponse;
    const preview_payload = preview.payload();
    const preview_content = stringField(preview_payload, "proposed_content") orelse
        return error.MalformedProtocolResponse;
    if (!std.mem.eql(u8, preview_content, request.proposed_content)) return error.PreviewMismatch;

    const apply_request = try encodeRequest(allocator, canonical_root, request, repairs.value, "apply_repair");
    defer allocator.free(apply_request);
    const response_json = try invokeProtocol(allocator, io, apply_request, "apply_repair");
    defer allocator.free(response_json);
    var response = try parseEnvelope(allocator, response_json, "apply_repair");
    defer response.deinit();
    if (!response.success()) return refusalFromEnvelope(allocator, &response);
    if (!matchesExpectedIdentity(response.root(), request.expected, false)) return error.MalformedProtocolResponse;

    const payload = response.payload();
    const applied_count = unsignedField(payload, "applied") orelse return error.MalformedProtocolResponse;
    if (std.math.cast(u32, repairs.value.array.items.len) != applied_count) return error.MalformedProtocolResponse;
    const source_digest = digestField(payload, "source_digest") orelse return error.MalformedProtocolResponse;
    const module_graph_hash = digestField(payload, "module_graph_hash") orelse return error.MalformedProtocolResponse;
    const envelope_graph_hash = digestField(response.root(), "module_graph_hash") orelse return error.MalformedProtocolResponse;
    if (!std.mem.eql(u8, &module_graph_hash, &envelope_graph_hash)) return error.MalformedProtocolResponse;
    if (payload.get("refusal") == null or payload.get("refusal").? != .null) return error.MalformedProtocolResponse;

    const resolved = try agent_identity.canonicalRelPath(allocator, io, canonical_root, request.file);
    defer allocator.free(resolved);
    const absolute = try std.fs.path.resolve(allocator, &.{ canonical_root, resolved });
    defer allocator.free(absolute);
    const on_disk = try zts.file_io.readFile(allocator, absolute, 10 * 1024 * 1024);
    defer allocator.free(on_disk);
    if (!std.mem.eql(u8, on_disk, request.proposed_content)) return error.AppliedContentMismatch;
    const actual_digest = agent_identity.sourceDigest(on_disk);
    if (!std.mem.eql(u8, &actual_digest, &source_digest)) return error.AppliedContentMismatch;

    return .{ .applied = .{
        .source_digest = source_digest,
        .module_graph_hash = module_graph_hash,
    } };
}

fn encodeRequest(
    allocator: std.mem.Allocator,
    canonical_root: []const u8,
    request: ApplyRequest,
    repairs: std.json.Value,
    operation: []const u8,
) ![]u8 {
    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(agent_identity.schema_version);
    try json.objectField("operation");
    try json.write(operation);
    try json.objectField("project_root");
    try json.write(canonical_root);
    try json.objectField("input");
    try json.beginObject();
    try json.objectField("file");
    try json.write(request.file);
    try json.objectField("repairs");
    try json.write(repairs);
    try json.endObject();
    try json.objectField("expected");
    try json.beginObject();
    try json.objectField("profile_id");
    try json.write(request.expected.profile_id);
    try json.objectField("policy_hash");
    try json.write(request.expected.policy_hash);
    try json.objectField("module_graph_hash");
    try json.write(request.expected.module_graph_hash);
    try json.endObject();
    try json.endObject();
    return out.toOwnedSlice();
}

fn invokeProtocol(
    allocator: std.mem.Allocator,
    io: std.Io,
    request_json: []const u8,
    expected_operation: []const u8,
) ![]u8 {
    var response = TextBuffer.init(allocator);
    defer response.deinit();
    try agent_protocol.handleRequest(allocator, io, request_json, response.writer());

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.written(), .{}) catch
        return error.MalformedProtocolResponse;
    defer parsed.deinit();
    if (parsed.value != .object or
        !std.mem.eql(u8, stringField(parsed.value.object, "operation") orelse return error.MalformedProtocolResponse, expected_operation))
        return error.MalformedProtocolResponse;
    return allocator.dupe(u8, response.written());
}

const Envelope = struct {
    document: std.json.Parsed(std.json.Value),

    fn deinit(self: *Envelope) void {
        self.document.deinit();
        self.* = undefined;
    }

    fn root(self: *const Envelope) std.json.ObjectMap {
        return self.document.value.object;
    }

    fn success(self: *const Envelope) bool {
        return self.root().get("success").?.bool;
    }

    fn payload(self: *const Envelope) std.json.ObjectMap {
        return self.root().get("payload").?.object;
    }
};

fn parseEnvelope(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    operation: []const u8,
) !Envelope {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.MalformedProtocolResponse;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.MalformedProtocolResponse;
    const root = parsed.value.object;
    if (unsignedField(root, "schema_version") != agent_identity.schema_version or
        !std.mem.eql(u8, stringField(root, "operation") orelse return error.MalformedProtocolResponse, operation) or
        stringField(root, "profile_id") == null or
        stringField(root, "policy_hash") == null or
        digestField(root, "module_graph_hash") == null)
        return error.MalformedProtocolResponse;
    const success_value = root.get("success") orelse return error.MalformedProtocolResponse;
    const payload_value = root.get("payload") orelse return error.MalformedProtocolResponse;
    const diagnostics_value = root.get("diagnostics") orelse return error.MalformedProtocolResponse;
    if (success_value != .bool or payload_value != .object or diagnostics_value != .array)
        return error.MalformedProtocolResponse;
    return .{ .document = parsed };
}

fn refusalFromEnvelope(allocator: std.mem.Allocator, envelope: *const Envelope) !Outcome {
    const root = envelope.root();
    var code: []const u8 = "operation_refused";
    var message: []const u8 = "the repair operation was refused";
    if (root.get("error")) |error_value| {
        if (error_value != .object) return error.MalformedProtocolResponse;
        code = stringField(error_value.object, "code") orelse return error.MalformedProtocolResponse;
        message = stringField(error_value.object, "message") orelse return error.MalformedProtocolResponse;
    } else if (envelope.payload().get("refusal")) |refusal_value| {
        if (refusal_value == .object) {
            code = stringField(refusal_value.object, "reason") orelse return error.MalformedProtocolResponse;
            message = stringField(refusal_value.object, "message") orelse return error.MalformedProtocolResponse;
        }
    }
    const code_owned = try allocator.dupe(u8, code);
    errdefer allocator.free(code_owned);
    return .{ .refused = .{
        .code = code_owned,
        .message = try allocator.dupe(u8, message),
    } };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u32 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(u32, value.integer);
}

fn digestField(object: std.json.ObjectMap, name: []const u8) ?[64]u8 {
    const value = stringField(object, name) orelse return null;
    if (value.len != 64) return null;
    var digest: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return null;
        digest[index] = byte;
    }
    return digest;
}

fn matchesExpectedIdentity(
    root: std.json.ObjectMap,
    expected: ExpectedIdentity,
    include_graph: bool,
) bool {
    if (!std.mem.eql(u8, stringField(root, "profile_id") orelse return false, expected.profile_id) or
        !std.mem.eql(u8, stringField(root, "policy_hash") orelse return false, expected.policy_hash)) return false;
    if (include_graph and
        !std.mem.eql(u8, stringField(root, "module_graph_hash") orelse return false, expected.module_graph_hash)) return false;
    return true;
}

const testing = std.testing;
const zts_agent_client = @import("zts_agent_client.zig");

test "repair writer capability is explicitly injectable" {
    const Fake = struct {
        calls: u32 = 0,

        fn apply(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: std.Io,
            request: ApplyRequest,
        ) anyerror!Outcome {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            try testing.expectEqualStrings("h.ts", request.file);
            const code = try allocator.dupe(u8, "test_refusal");
            errdefer allocator.free(code);
            return .{ .refused = .{
                .code = code,
                .message = try allocator.dupe(u8, "not applied"),
            } };
        }
    };
    var fake: Fake = .{};
    const writer: RepairWriter = .{ .context = &fake, .apply_fn = Fake.apply };
    var outcome = try writer.apply(testing.allocator, testing.io, .{
        .workspace_root = ".",
        .file = "h.ts",
        .repairs_json = "[]",
        .expected = .{ .profile_id = "p", .policy_hash = "p", .module_graph_hash = "m" },
        .proposed_content = "",
    });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), fake.calls);
    try testing.expectEqualStrings("test_refusal", outcome.refused.code);
}

test "host repair writer applies exact approved v2 candidate" {
    const source =
        \\import type { Spec } from "zttp:types";
        \\
        \\structural Guardrails = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guardrails {
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
    const propose_envelope = switch (proposed) {
        .success => |*envelope| envelope,
        else => return error.TestExpectedSuccess,
    };
    const candidate = propose_envelope.root().get("payload").?.object.get("candidates").?.array.items[0];
    const bound = candidate.object.get("bound").?.object;

    var repairs = TextBuffer.init(testing.allocator);
    defer repairs.deinit();
    var repair_json: std.json.Stringify = .{ .writer = repairs.writer() };
    try repair_json.beginArray();
    try repair_json.write(candidate);
    try repair_json.endArray();

    const simulation_input = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"file\":\"h.ts\",\"repairs\":{s}}}",
        .{repairs.written()},
    );
    defer testing.allocator.free(simulation_input);
    var simulated = zts_agent_client.invokeAtRoot(testing.allocator, testing.io, root, .{
        .operation = .simulate_edit,
        .input_json = simulation_input,
        .expected = .{
            .profile_id = bound.get("profile_id").?.string,
            .policy_hash = bound.get("policy_hash").?.string,
            .module_graph_hash = bound.get("module_graph_hash").?.string,
        },
    });
    defer simulated.deinit();
    const proposed_content = switch (simulated) {
        .success => |*envelope| envelope.root().get("payload").?.object.get("proposed_content").?.string,
        else => return error.TestExpectedSuccess,
    };

    const writer = RepairWriter.protocol();
    const request: ApplyRequest = .{
        .workspace_root = root,
        .file = "h.ts",
        .repairs_json = repairs.written(),
        .expected = .{
            .profile_id = bound.get("profile_id").?.string,
            .policy_hash = bound.get("policy_hash").?.string,
            .module_graph_hash = bound.get("module_graph_hash").?.string,
        },
        .proposed_content = proposed_content,
    };

    var mismatch_request = request;
    mismatch_request.proposed_content = "attacker bytes";
    try testing.expectError(
        error.PreviewMismatch,
        writer.apply(testing.allocator, testing.io, mismatch_request),
    );
    const after_mismatch = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(after_mismatch);
    try testing.expectEqualStrings(source, after_mismatch);

    var stale_request = request;
    stale_request.expected.module_graph_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    var stale = try writer.apply(testing.allocator, testing.io, stale_request);
    defer stale.deinit(testing.allocator);
    switch (stale) {
        .refused => |refusal| try testing.expectEqualStrings("identity_mismatch", refusal.code),
        .applied => return error.TestExpectedRefusal,
    }
    const after_stale = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(after_stale);
    try testing.expectEqualStrings(source, after_stale);

    var outcome = try writer.apply(testing.allocator, testing.io, request);
    defer outcome.deinit(testing.allocator);
    const applied = switch (outcome) {
        .applied => |value| value,
        .refused => return error.TestExpectedApplied,
    };

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(proposed_content, on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "const name") != null);
    const digest = agent_identity.sourceDigest(on_disk);
    try testing.expectEqualSlices(u8, &digest, &applied.source_digest);
}

test "host repair writer rejects an empty selection without writing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "const value = 1;\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const outcome = RepairWriter.protocol().apply(testing.allocator, testing.io, .{
        .workspace_root = root,
        .file = "h.ts",
        .repairs_json = "[]",
        .expected = .{ .profile_id = "x", .policy_hash = "x", .module_graph_hash = "x" },
        .proposed_content = "attacker bytes",
    });
    try testing.expectError(error.InvalidRepairsJson, outcome);
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", testing.allocator, .limited(4096));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(source, on_disk);
}
