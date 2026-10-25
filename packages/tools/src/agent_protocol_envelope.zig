//! Agent protocol schema hash, operation table, negotiation, and the response envelope.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const expert_meta = @import("expert_meta.zig");
const canonicalize = @import("canonicalize.zig");
const example_registry = @import("example_registry.zig");
const testing = std.testing;

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
    unsupported_source_extension,
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
    .{ .op = .meta, .status = .implemented, .input_fields = &.{"view"}, .payload_fields = &.{
        "compiler_version",        "profile_id",            "policy_version",
        "policy_hash",             "grammar_hash",          "idiom_table_hash",
        "restriction_matrix_hash", "builtin_registry_hash", "example_registry_hash",
        "operations",              "error_codes",           "severities",
        "idioms",                  "limits",                "module_catalog",
        "deferred_sections",       "validators",            "verifiers",
        "ambient_names",           "type_serialization",    "grammar",
        "examples",                "module_examples",       "decisions",
        "source_frontends",
    } },
    .{ .op = .features, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"features"} },
    .{ .op = .restrictions, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"restrictions"} },
    .{ .op = .describe_rule, .status = .implemented, .input_fields = &.{"rule"}, .payload_fields = &.{"rules"} },
    .{ .op = .modules, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "graph", "builtins", "extensions", "rejected", "module_graph_hash",
    } },
    .{ .op = .check, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "file", "source_digest", "counts", "properties", "guarded_categories", "paths", "contract_available", "contract_body",
    } },
    .{ .op = .canonicalize, .status = .implemented, .input_fields = &.{ "file", "simulate" }, .payload_fields = &.{
        "file", "source_digest", "candidates", "simulation",
    } },
    .{ .op = .normalize, .status = .implemented, .input_fields = &.{ "file", "write" }, .payload_fields = &.{
        "file",                 "source_digest", "converged",     "fully_canonical",
        "iterations",           "residual",      "rewrite_trace", "canonical_source",
        "residual_diagnostics",
    } },
    .{ .op = .simulate_edit, .status = .implemented, .input_fields = &.{ "file", "repairs" }, .payload_fields = &.{
        "file",              "source_digest",    "ok",          "new_count",
        "preexisting_count", "proposed_content", "diagnostics", "refusal",
    } },
    .{ .op = .verify, .status = .implemented, .input_fields = &.{ "file", "properties", "content" }, .payload_fields = &.{
        "file", "source_digest", "results",
    } },
};

/// Payload sections spec 4.8 requires that no registry can generate yet. Ground
/// rule 3 of the master plan forbids hand-writing them, so `meta` publishes this
/// list instead of a prose stub, and a client reads one machine-readable answer
/// rather than discovering absence key by key.
pub const DeferredSection = struct { name: []const u8, note: []const u8 };

pub const deferred_sections = [_]DeferredSection{
    .{ .name = "extension_manifests", .note = "waits on a trust policy, not on a phase: a manifest is authenticated only against trusted issuers, pinned or transparent keys, rotation, and revocation (spec 13.4), and a self-asserted manifest is not proof (13.5). Until then every zttp-ext specifier is reported under `rejected` as unavailable rather than silently resolved, and the extensions list is empty" },
    .{ .name = "rule_severity", .note = "no registry can answer it: severity is chosen at each emission site, not per rule - handler_verifier emits ZTS305 as warning and ZTS500 as error from one category. Publishing a derived value would be a guess" },
    .{ .name = "repair_budget", .note = "decided rather than scheduled: the repair-iteration and tool-call budget is a client's loop policy, and nothing in this compiler runs that loop or could enforce a number published here. It closes when a loop lands that enforces one, not before" },
};

/// True when the operation reads a source file, and therefore binds the digest
/// of a real module environment rather than the context-free one.
pub fn takesFile(spec: *const OperationSpec) bool {
    for (spec.input_fields) |field| {
        if (std.mem.eql(u8, field, "file")) return true;
    }
    return false;
}

pub fn specFor(op: Operation) *const OperationSpec {
    for (&operations) |*spec| {
        if (spec.op == op) return spec;
    }
    unreachable; // the table is exhaustive; the test below proves it
}

/// Stable identity of the complete schema-v2 protocol vocabulary. This covers
/// the common envelope, every operation's declared input and payload fields,
/// and the closed error set. Evidence manifests bind this hash so a protocol
/// change cannot replay under an older schema identity.
pub fn schemaHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    schemaHashField(&hasher, "domain", "zts-agent-protocol-schema-v2");
    var version_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_bytes, agent_identity.schema_version, .big);
    schemaHashField(&hasher, "schema-version", &version_bytes);
    schemaHashField(&hasher, "profile-id", agent_identity.profile_id);
    inline for (&.{
        "schema_version", "operation",   "profile_id",        "compiler_version",
        "policy_version", "policy_hash", "module_graph_hash", "success",
        "payload",        "diagnostics", "error",             "code",
        "message",        "field",
    }, 0..) |field, index| {
        schemaHashIndex(&hasher, "envelope-field-index", index);
        schemaHashField(&hasher, "envelope-field", field);
    }
    for (&operations, 0..) |spec, operation_index| {
        schemaHashIndex(&hasher, "operation-index", operation_index);
        schemaHashField(&hasher, "operation", @tagName(spec.op));
        schemaHashField(&hasher, "status", @tagName(spec.status));
        for (spec.input_fields, 0..) |field, field_index| {
            schemaHashIndex(&hasher, "input-field-index", field_index);
            schemaHashField(&hasher, "input-field", field);
        }
        for (spec.payload_fields, 0..) |field, field_index| {
            schemaHashIndex(&hasher, "payload-field-index", field_index);
            schemaHashField(&hasher, "payload-field", field);
        }
        schemaHashField(
            &hasher,
            "deferred-note",
            spec.deferred_note orelse "",
        );
    }
    inline for (@typeInfo(ErrorCode).@"enum".field_names, 0..) |field, error_index| {
        schemaHashIndex(&hasher, "error-index", error_index);
        schemaHashField(&hasher, "error-code", field);
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

pub fn exampleRegistryHash() [64]u8 {
    return example_registry.catalogHash();
}

fn schemaHashField(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, value: []const u8) void {
    schemaHashFrame(hasher, label);
    schemaHashFrame(hasher, value);
}

fn schemaHashIndex(hasher: *std.crypto.hash.sha2.Sha256, label: []const u8, value: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    schemaHashField(hasher, label, &bytes);
}

fn schemaHashFrame(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .big);
    hasher.update(&length);
    hasher.update(value);
}

test "schema hash is deterministic lowercase hex" {
    const first = schemaHash();
    try std.testing.expectEqualStrings(&first, &schemaHash());
    try std.testing.expectEqual(@as(usize, 64), first.len);
    for (first) |byte| try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
}

// ---------------------------------------------------------------------------
// Request and response plumbing
// ---------------------------------------------------------------------------

/// A protocol-level failure. Not a diagnostic: it names a request field, never
/// a source span. Any allocated `message` or `field` lives in the per-request
/// arena, which outlives the write.
const ProtocolError = struct {
    code: ErrorCode,
    message: []const u8,
    field: ?[]const u8,
};

pub const Identity = struct {
    policy_hash: [64]u8,
    module_graph_hash: [64]u8,
};

/// Spec 4.8: a supplied `expected` field that does not match the recomputed
/// identity fails the request, naming the mismatched field and both values.
/// An absent block skips the guard entirely.
///
/// An unrecognized key inside `expected` is malformed rather than ignored:
/// silently skipping a misspelled guard field would report success for a
/// request the client believed was guarded, which is the exact failure the
/// guard exists to prevent.
pub fn checkExpected(
    arena: std.mem.Allocator,
    expected: ?std.json.Value,
    identity: Identity,
) !?ProtocolError {
    const obj = switch (expected orelse return null) {
        .object => |o| o,
        else => return ProtocolError{
            .code = .malformed_request,
            .message = "expected must be an object",
            .field = "expected",
        },
    };

    // ObjectMap preserves insertion order, so two mismatched fields report the
    // first in request order - deterministic for a given request.
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const actual: []const u8 = if (std.mem.eql(u8, key, "profile_id"))
            agent_identity.profile_id
        else if (std.mem.eql(u8, key, "policy_hash"))
            &identity.policy_hash
        else if (std.mem.eql(u8, key, "module_graph_hash"))
            &identity.module_graph_hash
        else
            return ProtocolError{
                .code = .malformed_request,
                .message = "expected carries a field this protocol does not bind",
                .field = try arena.print("expected.{s}", .{key}),
            };

        if (kv.value_ptr.* != .string) {
            return ProtocolError{
                .code = .malformed_request,
                .message = "expected fields must be strings",
                .field = try arena.print("expected.{s}", .{key}),
            };
        }

        const supplied = kv.value_ptr.string;
        if (!std.mem.eql(u8, supplied, actual)) {
            return ProtocolError{
                .code = .identity_mismatch,
                .message = try arena.print("expected.{s} is stale: request said {s}, this compiler reports {s}", .{ key, supplied, actual }),
                .field = try arena.print("expected.{s}", .{key}),
            };
        }
    }
    return null;
}

/// Frozen across all present and future schema versions (spec 4.8). Three keys,
/// no envelope, no diagnostics. A future v3 binary must return exactly this to a
/// v1 client, so this function takes no envelope state and never gains a field.
pub fn writeNegotiation(json: *std.json.Stringify) !void {
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

pub fn writeErrorEnvelope(
    json: *std.json.Stringify,
    op_name: ?[]const u8,
    identity: Identity,
    err: ProtocolError,
) !void {
    try writeEnvelope(json, op_name, identity, false, "{}", "[]", err);
}

pub fn writeEnvelope(
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

test "the operation table covers the closed operation set exactly once" {
    inline for (@typeInfo(Operation).@"enum".field_names) |field| {
        var seen: usize = 0;
        for (&operations) |*spec| {
            if (std.mem.eql(u8, @tagName(spec.op), field)) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
    try testing.expectEqual(@typeInfo(Operation).@"enum".field_names.len, operations.len);
}

test "an implemented operation carries no deferred note" {
    // A note left behind after an operation lands would tell a client the
    // operation is still missing.
    for (&operations) |*spec| {
        switch (spec.status) {
            .implemented => try testing.expect(spec.deferred_note == null),
            .deferred => try testing.expect(spec.deferred_note != null),
        }
    }
}

test "spec 4.8's operation set is closed and every member is served" {
    // The compiler protocol is analysis-only. Every published member must be
    // served; source mutation belongs to Pi's aggregate transaction lane.
    //
    // The deferred branch in `handleRequest` stays: it is what such an
    // operation would take, and the sibling test below pins that a deferred row
    // must carry the note naming the phase that builds it.
    for (&operations) |*spec| {
        if (spec.status == .deferred) {
            std.debug.print("{s} is deferred; update this test deliberately\n", .{@tagName(spec.op)});
            return error.TestFailed;
        }
    }
    try testing.expectEqual(@as(usize, @typeInfo(Operation).@"enum".field_names.len), operations.len);
}

test "a verifier's published inputs are the verify operation's own input fields" {
    // Two spellings of "what verify takes" - the operation schema and the
    // verifier registry - and a client may read either. Pinning them to each
    // other here means the pair cannot drift into disagreeing about a required
    // input, which is the failure spec 4.8's sentence exists to prevent.
    const verify_op = for (&operations) |*op| {
        if (op.op == .verify) break op;
    } else return error.TestExpected;

    try testing.expect(verify_op.input_fields.len > 0);
    try testing.expectEqual(verify_op.input_fields.len, zts.proof_trace.verify_inputs.len);
    for (verify_op.input_fields, zts.proof_trace.verify_inputs) |declared, published| {
        try testing.expectEqualStrings(declared, published);
    }
}
