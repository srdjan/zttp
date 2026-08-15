//! In-process client for the version-2 ZTS agent protocol.
//!
//! Request projection and response decoding are pure. Filesystem access and
//! protocol execution stay in `invokeAtRoot` / `invokeFromCwd`, where both the
//! allocator and `std.Io` backend are explicit.

const std = @import("std");
const zts_cli = @import("zts_cli");
const agent_identity = zts_cli.agent_identity;
const agent_protocol = zts_cli.agent_protocol;
const TextBuffer = @import("../text_buffer.zig").TextBuffer;

/// Operations this read-only client exposes. `apply_repair` is deliberately
/// absent: writing remains behind Pi's approval and receipt boundary.
pub const Operation = enum {
    meta,
    features,
    restrictions,
    describe_rule,
    modules,
    check,
    canonicalize,
    simulate_edit,
    normalize,
    verify,
};

pub const ExpectedIdentity = struct {
    profile_id: ?[]const u8 = null,
    policy_hash: ?[]const u8 = null,
    module_graph_hash: ?[]const u8 = null,
};

pub const Request = struct {
    operation: Operation,
    input_json: []const u8,
    expected: ?ExpectedIdentity = null,
};

pub const MalformedReason = enum {
    invalid_json,
    invalid_envelope,
    schema_mismatch,
    operation_mismatch,
};

pub const RefusalKind = enum {
    protocol_error,
    operation_refusal,
};

/// Owns the parsed response document. Slices returned by accessors borrow it.
pub const Envelope = struct {
    document: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Envelope) void {
        self.document.deinit();
        self.* = undefined;
    }

    pub fn root(self: *const Envelope) std.json.ObjectMap {
        return self.document.value.object;
    }

    pub fn operation(self: *const Envelope) []const u8 {
        return self.root().get("operation").?.string;
    }

    pub fn errorCode(self: *const Envelope) ?[]const u8 {
        const value = self.root().get("error") orelse return null;
        return value.object.get("code").?.string;
    }
};

pub const Refusal = struct {
    kind: RefusalKind,
    envelope: Envelope,
};

/// Protocol failures are data, not Zig errors. The final variant is reserved
/// for failures before a valid protocol response exists, such as allocation,
/// filesystem canonicalization, or writer failure.
pub const Outcome = union(enum) {
    success: Envelope,
    refusal: Refusal,
    malformed_response: MalformedReason,
    transport_or_internal_error: anyerror,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .success => |*envelope| envelope.deinit(),
            .refusal => |*refusal| refusal.envelope.deinit(),
            .malformed_response, .transport_or_internal_error => {},
        }
        self.* = undefined;
    }
};

pub const RequestError = error{InvalidInputJson};

pub const ToolProjection = struct {
    ok: bool,
    llm_text: []u8,
};

/// Serialize the exact request object accepted by `zts agent --stdin-json`.
/// `input_json` is parsed before projection so malformed or multiple values
/// cannot be spliced into the envelope.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    request: Request,
) (RequestError || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var input = std.json.parseFromSlice(std.json.Value, allocator, request.input_json, .{}) catch
        return error.InvalidInputJson;
    defer input.deinit();

    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(agent_identity.schema_version);
    try json.objectField("operation");
    try json.write(@tagName(request.operation));
    try json.objectField("project_root");
    try json.write(project_root);
    try json.objectField("input");
    try json.write(input.value);
    if (request.expected) |expected| {
        try json.objectField("expected");
        try json.beginObject();
        if (expected.profile_id) |value| {
            try json.objectField("profile_id");
            try json.write(value);
        }
        if (expected.policy_hash) |value| {
            try json.objectField("policy_hash");
            try json.write(value);
        }
        if (expected.module_graph_hash) |value| {
            try json.objectField("module_graph_hash");
            try json.write(value);
        }
        try json.endObject();
    }
    try json.endObject();
    return out.toOwnedSlice();
}

/// Decode one response object and validate the stable envelope fields needed
/// by every caller. `parseFromSlice` rejects a second non-whitespace value.
pub fn decodeResponse(
    allocator: std.mem.Allocator,
    expected_operation: Operation,
    response_json: []const u8,
) Outcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch
        return .{ .malformed_response = .invalid_json };
    errdefer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return malformed(&parsed, .invalid_envelope),
    };
    const schema_version = integerField(root, "schema_version") orelse
        return malformed(&parsed, .invalid_envelope);
    if (schema_version != agent_identity.schema_version) {
        return malformed(&parsed, .schema_mismatch);
    }
    const operation = stringField(root, "operation") orelse
        return malformed(&parsed, .invalid_envelope);
    if (!std.mem.eql(u8, operation, @tagName(expected_operation))) {
        return malformed(&parsed, .operation_mismatch);
    }
    _ = stringField(root, "profile_id") orelse return malformed(&parsed, .invalid_envelope);
    _ = stringField(root, "compiler_version") orelse return malformed(&parsed, .invalid_envelope);
    _ = stringField(root, "policy_version") orelse return malformed(&parsed, .invalid_envelope);
    _ = stringField(root, "policy_hash") orelse return malformed(&parsed, .invalid_envelope);
    _ = stringField(root, "module_graph_hash") orelse return malformed(&parsed, .invalid_envelope);
    const success = boolField(root, "success") orelse return malformed(&parsed, .invalid_envelope);
    const payload = root.get("payload") orelse return malformed(&parsed, .invalid_envelope);
    const diagnostics = root.get("diagnostics") orelse return malformed(&parsed, .invalid_envelope);
    if (payload != .object or diagnostics != .array) return malformed(&parsed, .invalid_envelope);

    const error_value = root.get("error");
    if (error_value) |value| {
        if (success or !validProtocolError(value)) return malformed(&parsed, .invalid_envelope);
    }

    const envelope: Envelope = .{ .document = parsed };
    if (success) return .{ .success = envelope };
    return .{ .refusal = .{
        .kind = if (error_value != null) .protocol_error else .operation_refusal,
        .envelope = envelope,
    } };
}

/// Canonicalize an explicit workspace root, execute one in-process request,
/// then decode exactly one response envelope.
pub fn invokeAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    request: Request,
) Outcome {
    const canonical_root = agent_identity.canonicalRoot(allocator, io, workspace_root) catch |err|
        return .{ .transport_or_internal_error = err };
    defer allocator.free(canonical_root);

    const request_json = encodeRequest(allocator, canonical_root, request) catch |err|
        return .{ .transport_or_internal_error = err };
    defer allocator.free(request_json);

    var response = TextBuffer.init(allocator);
    defer response.deinit();
    agent_protocol.handleRequest(allocator, io, request_json, response.writer()) catch |err|
        return .{ .transport_or_internal_error = err };
    return decodeResponse(allocator, request.operation, response.written());
}

/// Production convenience boundary: derive the workspace from cwd using the
/// caller's I/O backend, then pass the canonical root to `invokeAtRoot`.
pub fn invokeFromCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
) Outcome {
    return invokeAtRoot(allocator, io, ".", request);
}

/// Execute one discovery/read request with the package's explicit threaded-I/O
/// boundary and preserve the complete version-2 envelope for the model-facing
/// tool result. Invalid transport output is an internal error, never a guessed
/// protocol response.
pub fn invokeForTool(
    allocator: std.mem.Allocator,
    request: Request,
) anyerror!ToolProjection {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    return invokeForToolAtRoot(allocator, io_backend.io(), ".", request);
}

/// Testable/effect-explicit form of `invokeForTool`. Production wrappers use
/// cwd, while workflow controllers and E2E tests can inject the exact project
/// root whose identity the request must bind.
pub fn invokeForToolAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    request: Request,
) anyerror!ToolProjection {
    var outcome = invokeAtRoot(allocator, io, workspace_root, request);
    defer outcome.deinit();
    return projectToolOutcome(allocator, &outcome);
}

fn projectToolOutcome(allocator: std.mem.Allocator, outcome: *Outcome) anyerror!ToolProjection {
    return switch (outcome.*) {
        .success => |*envelope| .{
            .ok = true,
            .llm_text = try renderEnvelope(allocator, envelope),
        },
        .refusal => |*refusal| .{
            .ok = false,
            .llm_text = try renderEnvelope(allocator, &refusal.envelope),
        },
        .malformed_response => error.MalformedProtocolResponse,
        .transport_or_internal_error => |err| err,
    };
}

fn malformed(
    parsed: *std.json.Parsed(std.json.Value),
    reason: MalformedReason,
) Outcome {
    parsed.deinit();
    return .{ .malformed_response = reason };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    const value = object.get(name) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn validProtocolError(value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    if (stringField(object, "code") == null or stringField(object, "message") == null) return false;
    const field = object.get("field") orelse return false;
    return field == .null or field == .string;
}

fn renderEnvelope(allocator: std.mem.Allocator, envelope: *const Envelope) ![]u8 {
    var out = TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.write(envelope.document.value);
    try out.writer().writeByte('\n');
    return out.toOwnedSlice();
}

const testing = std.testing;

test "zts agent client projects an exact version-2 request" {
    const encoded = try encodeRequest(testing.allocator, "/workspace", .{
        .operation = .check,
        .input_json = "{\"file\":\"handler.ts\"}",
        .expected = .{
            .profile_id = "zts-model-1",
            .policy_hash = "policy",
            .module_graph_hash = "modules",
        },
    });
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings(
        "{\"schema_version\":2,\"operation\":\"check\",\"project_root\":\"/workspace\",\"input\":{\"file\":\"handler.ts\"},\"expected\":{\"profile_id\":\"zts-model-1\",\"policy_hash\":\"policy\",\"module_graph_hash\":\"modules\"}}",
        encoded,
    );
}

test "zts agent client decodes success and refusal envelopes" {
    const success_json =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"p","module_graph_hash":"m","success":true,"payload":{},"diagnostics":[]}
    ;
    var success = decodeResponse(testing.allocator, .meta, success_json);
    defer success.deinit();
    switch (success) {
        .success => |*envelope| try testing.expectEqualStrings("meta", envelope.operation()),
        else => return error.TestExpectedSuccess,
    }

    const refusal_json =
        \\{"schema_version":2,"operation":"meta","profile_id":"zts-model-1","compiler_version":"1","policy_version":"1","policy_hash":"p","module_graph_hash":"m","success":false,"payload":{},"diagnostics":[],"error":{"code":"identity_mismatch","message":"stale","field":"expected.policy_hash"}}
    ;
    var refusal = decodeResponse(testing.allocator, .meta, refusal_json);
    defer refusal.deinit();
    switch (refusal) {
        .refusal => |*value| {
            try testing.expectEqual(RefusalKind.protocol_error, value.kind);
            try testing.expectEqualStrings("identity_mismatch", value.envelope.errorCode().?);
        },
        else => return error.TestExpectedRefusal,
    }
}

test "zts agent client propagates stale expected identity through the real protocol" {
    var outcome = invokeFromCwd(testing.allocator, testing.io, .{
        .operation = .meta,
        .input_json = "{}",
        .expected = .{ .policy_hash = "stale-policy-hash" },
    });
    defer outcome.deinit();

    switch (outcome) {
        .refusal => |*refusal| {
            try testing.expectEqual(RefusalKind.protocol_error, refusal.kind);
            try testing.expectEqualStrings("identity_mismatch", refusal.envelope.errorCode().?);
            try testing.expectEqualStrings(
                "expected.policy_hash",
                refusal.envelope.root().get("error").?.object.get("field").?.string,
            );
        },
        else => return error.TestExpectedRefusal,
    }
}

test "zts agent client rejects invalid and multiple responses" {
    var invalid = decodeResponse(testing.allocator, .meta, "not-json");
    defer invalid.deinit();
    try testing.expectEqual(MalformedReason.invalid_json, invalid.malformed_response);

    var multiple = decodeResponse(testing.allocator, .meta, "{}\n{}");
    defer multiple.deinit();
    try testing.expectEqual(MalformedReason.invalid_json, multiple.malformed_response);
}

test "zts agent client returns an out-of-root protocol refusal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = "function handler(): Response { return Response.text(\"ok\"); }" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var outcome = invokeAtRoot(testing.allocator, testing.io, root, .{
        .operation = .check,
        .input_json = "{\"file\":\"../outside.ts\"}",
    });
    defer outcome.deinit();
    switch (outcome) {
        .refusal => |*refusal| {
            try testing.expectEqual(RefusalKind.protocol_error, refusal.kind);
            try testing.expectEqualStrings("path_outside_project_root", refusal.envelope.errorCode().?);
        },
        else => return error.TestExpectedRefusal,
    }
}

test "zts agent tool projection preserves a stale-identity refusal envelope" {
    const projection = try invokeForTool(testing.allocator, .{
        .operation = .meta,
        .input_json = "{}",
        .expected = .{ .policy_hash = "stale-policy-hash" },
    });
    defer testing.allocator.free(projection.llm_text);

    try testing.expect(!projection.ok);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, projection.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("schema_version").?.integer);
    try testing.expectEqualStrings(
        "identity_mismatch",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}
