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
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const expert_meta = @import("expert_meta.zig");
const edit_simulate = @import("edit_simulate.zig");

const rule_registry = zts.rule_registry;

/// The closed operation set (spec 4.8).
pub const Operation = enum {
    meta,
    features,
    restrictions,
    describe_rule,
    modules,
    check,
    canonicalize,
    simulate_edit,
    apply_repair,
    normalize,
    verify,
};

/// Closed set, published in `meta`. D3 §6 lists eight; `operation_not_implemented`
/// is the ninth, added because phase 1 serves eight of the spec's eleven
/// operations and calling a named member of the closed operation set "unknown"
/// would be false. A structured unsupported result is for source constructs, not
/// for an unbuilt operation.
pub const ErrorCode = enum {
    unknown_operation,
    malformed_request,
    unsupported_schema_version,
    project_root_unresolvable,
    path_outside_project_root,
    file_unreadable,
    identity_mismatch,
    operation_not_implemented,
    internal_error,
};

pub const Status = enum { implemented, deferred };

pub const OperationSpec = struct {
    op: Operation,
    status: Status,
    input_fields: []const []const u8,
    payload_fields: []const []const u8,
    /// Set for `deferred`: which phase builds it, so `meta` says when rather
    /// than only that it is missing.
    deferred_note: ?[]const u8 = null,
};

/// The dispatch gate and the `meta.payload.operations` source, one table. An
/// operation missing from this table cannot be dispatched, and one present here
/// cannot be omitted from `meta`.
pub const operations = [_]OperationSpec{
    // payload_fields is what the payload actually emits today, not what spec 4.8
    // eventually requires: the gate below reads a live `meta` response and
    // compares key for key, so a field advertised here and not written is a
    // failing test rather than a promise on the wire. Task 11 grows both
    // together.
    .{ .op = .meta, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{
        "compiler_version",  "profile_id", "policy_version",
        "policy_hash",       "operations", "error_codes",
        "deferred_sections",
    } },
    .{ .op = .features, .status = .deferred, .input_fields = &.{}, .payload_fields = &.{"features"}, .deferred_note = "phase 1 task 7" },
    .{ .op = .restrictions, .status = .deferred, .input_fields = &.{"by"}, .payload_fields = &.{"restrictions"}, .deferred_note = "phase 1 task 7" },
    .{ .op = .describe_rule, .status = .deferred, .input_fields = &.{"rule"}, .payload_fields = &.{"rules"}, .deferred_note = "phase 1 task 7" },
    .{ .op = .modules, .status = .deferred, .input_fields = &.{"file"}, .payload_fields = &.{
        "graph", "builtins", "extensions", "rejected", "module_graph_hash",
    }, .deferred_note = "phase 1 task 8" },
    .{ .op = .check, .status = .deferred, .input_fields = &.{"file"}, .payload_fields = &.{
        "file", "source_digest", "counts", "properties", "paths", "contract_available",
    }, .deferred_note = "phase 1 task 9" },
    .{ .op = .canonicalize, .status = .deferred, .input_fields = &.{ "file", "simulate" }, .payload_fields = &.{
        "file", "source_digest", "candidates", "simulation",
    }, .deferred_note = "phase 1 task 10" },
    .{ .op = .normalize, .status = .deferred, .input_fields = &.{"file"}, .payload_fields = &.{
        "file",                 "source_digest", "converged",     "fully_canonical",
        "iterations",           "residual",      "rewrite_trace", "canonical_source",
        "residual_diagnostics",
    }, .deferred_note = "phase 1 task 10" },
    .{ .op = .simulate_edit, .status = .deferred, .input_fields = &.{ "file", "repairs" }, .payload_fields = &.{
        "ok", "new_count", "preexisting_count", "diagnostics",
    }, .deferred_note = "phase 6: needs the unified repair vocabulary" },
    .{ .op = .apply_repair, .status = .deferred, .input_fields = &.{ "file", "repairs" }, .payload_fields = &.{
        "applied", "source_digest", "module_graph_hash",
    }, .deferred_note = "phase 6: needs the equivalence-validator registry" },
    .{ .op = .verify, .status = .deferred, .input_fields = &.{ "file", "properties" }, .payload_fields = &.{"results"}, .deferred_note = "phase 6: needs the verifier discovery registry" },
};

/// Payload sections spec 4.8 requires that no registry can generate yet. Ground
/// rule 3 of the master plan forbids hand-writing them, so `meta` publishes this
/// list instead of a prose stub, and a client reads one machine-readable answer
/// rather than discovering absence key by key.
pub const DeferredSection = struct { name: []const u8, note: []const u8 };

pub const deferred_sections = [_]DeferredSection{
    .{ .name = "grammar", .note = "phase 6: section 8 lives in spec prose, with no machine-readable production table to generate from" },
    .{ .name = "examples", .note = "phase 6: no per-form example registry exists" },
    .{ .name = "ambient_names", .note = "phase 4: the section 6 ambient table lands with Dict, JSON, and Bytes" },
    .{ .name = "validators", .note = "phase 6: the equivalence-validator taxonomy (D3 §4) has no registry yet" },
    .{ .name = "type_serialization", .note = "phase 2: the canonical type serialization is D1's artifact" },
    .{ .name = "decisions", .note = "phase 6: no next-action or semantic-decision registry exists" },
    .{ .name = "verifiers", .note = "phase 6: property discovery arrives with the verify operation" },
    .{ .name = "repair_budget", .note = "phase 6: the repair-iteration and tool-call budget is a loop policy no code implements" },
};

pub fn specFor(op: Operation) *const OperationSpec {
    for (&operations) |*spec| {
        if (spec.op == op) return spec;
    }
    unreachable; // the table is exhaustive; the test below proves it
}

// ---------------------------------------------------------------------------
// Request and response plumbing
// ---------------------------------------------------------------------------

const ProtocolError = struct {
    code: ErrorCode,
    message: []const u8,
    field: ?[]const u8,
    /// Set when `message` is heap-allocated for this response.
    owned_message: bool = false,
};

const Identity = struct {
    policy_hash: [64]u8,
    module_graph_hash: [64]u8,
};

fn contextFreeIdentity() Identity {
    return .{
        .policy_hash = rule_registry.policyHash(),
        .module_graph_hash = module_graph_record.contextFreeHash(),
    };
}

/// Handle one request. Always writes exactly one JSON object and a trailing
/// newline; a malformed or unsupported request produces a response, never an
/// error return. The error set covers only writer failure and allocation.
pub fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request_json: []const u8,
    writer: *std.Io.Writer,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch {
        return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "request body is not valid JSON",
            .field = null,
        });
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "request must be a JSON object",
            .field = null,
        }),
    };

    // Version negotiation comes before every other check, so a client of any
    // version reaches the frozen response without needing to be understood.
    const version_value = root.get("schema_version") orelse
        return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "schema_version is required",
            .field = "schema_version",
        });
    if (version_value != .integer) {
        return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "schema_version must be an integer",
            .field = "schema_version",
        });
    }
    if (version_value.integer != @as(i64, agent_identity.schema_version)) {
        return writeNegotiation(&json);
    }

    const op_value = root.get("operation") orelse
        return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "operation is required",
            .field = "operation",
        });
    if (op_value != .string) {
        return writeErrorEnvelope(&json, null, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "operation must be a string",
            .field = "operation",
        });
    }
    const op_name = op_value.string;
    const op = std.meta.stringToEnum(Operation, op_name) orelse
        return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .unknown_operation,
            .message = "operation is not a member of the version-2 operation set",
            .field = "operation",
        });

    const spec = specFor(op);
    if (spec.status == .deferred) {
        return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .operation_not_implemented,
            .message = spec.deferred_note orelse "operation is not implemented by this compiler",
            .field = "operation",
        });
    }

    const root_value = root.get("project_root") orelse
        return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "project_root is required",
            .field = "project_root",
        });
    if (root_value != .string) {
        return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "project_root must be a string",
            .field = "project_root",
        });
    }
    const canonical_root = agent_identity.canonicalRoot(allocator, io, root_value.string) catch
        return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .project_root_unresolvable,
            .message = "project_root does not resolve to an existing directory",
            .field = "project_root",
        });
    defer allocator.free(canonical_root);

    // Operations that take no `file` bind the context-free environment digest:
    // the built-in registry with an empty module set. `expected` therefore has
    // something to compare for every operation, and the envelope field is never
    // empty.
    const identity = contextFreeIdentity();

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    var payload_json: std.json.Stringify = .{ .writer = &payload.writer };

    const success = switch (op) {
        .meta => try writeMetaPayload(&payload_json),
        else => unreachable, // every other row is `.deferred` and returned above
    };

    try writeEnvelope(&json, op_name, identity, success, payload.writer.buffered(), "[]", null);
}

/// Frozen across all present and future schema versions (spec 4.8). Three keys,
/// no envelope, no diagnostics. A future v3 binary must return exactly this to a
/// v1 client, so this function takes no envelope state and never gains a field.
fn writeNegotiation(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("schema_version_unsupported");
    try json.write(true);
    try json.objectField("supported_schema_versions");
    try json.beginArray();
    for (agent_identity.supported_schema_versions) |v| try json.write(v);
    try json.endArray();
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.endObject();
    try json.writer.writeByte('\n');
}

fn writeErrorEnvelope(
    json: *std.json.Stringify,
    op_name: ?[]const u8,
    identity: Identity,
    err: ProtocolError,
) !void {
    try writeEnvelope(json, op_name, identity, false, "{}", "[]", err);
}

fn writeEnvelope(
    json: *std.json.Stringify,
    op_name: ?[]const u8,
    identity: Identity,
    success: bool,
    payload_json: []const u8,
    diagnostics_json: []const u8,
    err: ?ProtocolError,
) !void {
    try json.beginObject();
    try json.objectField("schema_version");
    try json.write(agent_identity.schema_version);
    try json.objectField("operation");
    if (op_name) |name| try json.write(name) else try json.write(null);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&identity.policy_hash);
    try json.objectField("module_graph_hash");
    try json.write(&identity.module_graph_hash);
    try json.objectField("success");
    try json.write(success);
    try json.objectField("payload");
    try writeRaw(json, payload_json);
    try json.objectField("diagnostics");
    try writeRaw(json, diagnostics_json);
    // An error response still carries the identity block: a client that hit a
    // staleness or boundary failure needs the current values to recover, and one
    // that hit an unknown operation needs to know which binary answered.
    if (err) |e| {
        try json.objectField("error");
        try json.beginObject();
        try json.objectField("code");
        try json.write(@tagName(e.code));
        try json.objectField("message");
        try json.write(e.message);
        try json.objectField("field");
        if (e.field) |f| try json.write(f) else try json.write(null);
        try json.endObject();
    }
    try json.endObject();
    try json.writer.writeByte('\n');
}

/// Splice an already-serialized value in as one token. The payload writers build
/// their object separately so the envelope can keep spec 4.8's field order
/// without every operation threading the outer writer.
fn writeRaw(json: *std.json.Stringify, bytes: []const u8) !void {
    try json.beginWriteRaw();
    try json.writer.writeAll(bytes);
    json.endWriteRaw();
}

// ---------------------------------------------------------------------------
// meta
// ---------------------------------------------------------------------------

fn writeMetaPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();

    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&rule_registry.policyHash());

    try json.objectField("operations");
    try json.beginArray();
    for (&operations) |*spec| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(@tagName(spec.op));
        try json.objectField("status");
        try json.write(@tagName(spec.status));
        try json.objectField("input_fields");
        try json.beginArray();
        for (spec.input_fields) |f| try json.write(f);
        try json.endArray();
        try json.objectField("payload_fields");
        try json.beginArray();
        for (spec.payload_fields) |f| try json.write(f);
        try json.endArray();
        try json.objectField("deferred_note");
        if (spec.deferred_note) |n| try json.write(n) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("error_codes");
    try json.beginArray();
    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| try json.write(field.name);
    try json.endArray();

    try json.objectField("deferred_sections");
    try json.beginArray();
    for (&deferred_sections) |*section| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(section.name);
        try json.objectField("note");
        try json.write(section.note);
        try json.endObject();
    }
    try json.endArray();

    try json.endObject();
    return true;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var stdin_json = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--stdin-json")) {
            stdin_json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "help"))
        {
            printHelp();
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!stdin_json) {
        printHelp();
        return error.InvalidArgument;
    }

    const request = try edit_simulate.readAllStdin(allocator);
    defer allocator.free(request);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try handleRequest(allocator, io_backend.io(), request, &out.writer);

    const bytes = out.writer.buffered();
    if (bytes.len > 0) _ = std.c.write(std.c.STDOUT_FILENO, bytes.ptr, bytes.len);
}

fn printHelp() void {
    const help =
        \\zts agent - the version-2 agent protocol over stdin/stdout
        \\
        \\Usage: zts agent --stdin-json
        \\
        \\Reads one request object from stdin and writes one response object to
        \\stdout. Logs go to stderr. Exit status is 0 whenever a response was
        \\written, including a response carrying a protocol error.
        \\
        \\Request:
        \\  {"schema_version":2,"operation":"meta","project_root":"/abs/path",
        \\   "input":{},"expected":{"policy_hash":"..."}}
        \\
        \\Send `meta` first: its payload publishes the operation set, the
        \\identity hashes, and the payload sections this compiler does not yet
        \\generate.
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn respond(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try handleRequest(allocator, testing.io, request, &out.writer);
    return out.toOwnedSlice();
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "the operation table covers the closed operation set exactly once" {
    inline for (@typeInfo(Operation).@"enum".fields) |field| {
        var seen: usize = 0;
        for (&operations) |*spec| {
            if (std.mem.eql(u8, @tagName(spec.op), field.name)) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    try testing.expectEqual(@typeInfo(Operation).@"enum".fields.len, operations.len);
}

test "meta response carries the full identity block" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("schema_version").?.integer);
    try testing.expectEqualStrings("meta", obj.get("operation").?.string);
    try testing.expectEqualStrings("zts-advanced-1", obj.get("profile_id").?.string);
    try testing.expectEqual(@as(usize, 64), obj.get("policy_hash").?.string.len);
    try testing.expectEqual(@as(usize, 64), obj.get("module_graph_hash").?.string.len);
    try testing.expect(obj.get("success").?.bool);
    try testing.expect(obj.get("payload").? == .object);
    try testing.expect(obj.get("diagnostics").? == .array);
    try testing.expect(obj.get("error") == null);
}

test "meta payload publishes every operation and its status" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    const ops = payload.get("operations").?.array;
    try testing.expectEqual(operations.len, ops.items.len);
    inline for (@typeInfo(Operation).@"enum".fields) |field| {
        var seen: usize = 0;
        for (ops.items) |o| {
            if (std.mem.eql(u8, o.object.get("id").?.string, field.name)) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    // The sections no registry can generate are named, not stubbed.
    const sections = payload.get("deferred_sections").?.array;
    try testing.expect(sections.items.len >= 6);
    for (sections.items) |s| {
        try testing.expect(payload.get(s.object.get("name").?.string) == null);
    }
}

test "every implemented operation emits exactly its declared payload_fields" {
    const a = testing.allocator;
    for (&operations) |*spec| {
        if (spec.status != .implemented) continue;
        const req = try std.fmt.allocPrint(a,
            \\{{"schema_version":2,"operation":"{s}","project_root":".","input":{{}}}}
        , .{@tagName(spec.op)});
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

test "an unsupported schema version gets the frozen three-key response" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":1,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(usize, 3), obj.count());
    try testing.expect(obj.get("schema_version_unsupported").?.bool);
    try testing.expectEqual(@as(usize, 1), obj.get("supported_schema_versions").?.array.items.len);
    try testing.expect(obj.get("compiler_version") != null);
    try testing.expect(obj.get("operation") == null);
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

test "a deferred operation says so instead of claiming it is unknown" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"apply_repair","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("operation_not_implemented", err.get("code").?.string);
    // The message names the phase that builds it.
    try testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "phase") != null);
}

test "malformed input is a protocol error naming the offending field" {
    const a = testing.allocator;
    const cases = [_]struct { body: []const u8, field: ?[]const u8 }{
        .{ .body = "not json at all", .field = null },
        .{ .body = "[]", .field = null },
        .{ .body =
        \\{"operation":"meta","project_root":".","input":{}}
        , .field = "schema_version" },
        .{ .body =
        \\{"schema_version":"2","operation":"meta","project_root":".","input":{}}
        , .field = "schema_version" },
        .{ .body =
        \\{"schema_version":2,"project_root":".","input":{}}
        , .field = "operation" },
        .{ .body =
        \\{"schema_version":2,"operation":"meta","input":{}}
        , .field = "project_root" },
    };
    for (cases) |case| {
        const out = try respond(a, case.body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        const err = parsed.value.object.get("error") orelse {
            std.debug.print("no error object for input: {s}\n", .{case.body});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("malformed_request", err.object.get("code").?.string);
        if (case.field) |f| {
            try testing.expectEqualStrings(f, err.object.get("field").?.string);
        }
    }
}

test "an unresolvable project root is its own error code" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":"/no/such/root/here","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("project_root_unresolvable", err.get("code").?.string);
    try testing.expectEqualStrings("project_root", err.get("field").?.string);
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
    try testing.expectEqualStrings(&rule_registry.policyHash(), obj.get("policy_hash").?.string);
    try testing.expectEqualStrings("zts-advanced-1", obj.get("profile_id").?.string);
}

test "identical requests produce byte-identical responses" {
    const a = testing.allocator;
    const req =
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    ;
    const first = try respond(a, req);
    defer a.free(first);
    const second = try respond(a, req);
    defer a.free(second);
    try testing.expectEqualStrings(first, second);
}
