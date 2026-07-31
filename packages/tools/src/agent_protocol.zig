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
const json_diagnostics = @import("json_diagnostics.zig");
const precompile = @import("precompile.zig");
const canonicalize = @import("canonicalize.zig");

const rule_registry = zts.rule_registry;
const restriction_registry = zts.restriction_registry;

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
        "compiler_version",      "profile_id",        "policy_version",
        "policy_hash",           "idiom_table_hash",  "restriction_matrix_hash",
        "builtin_registry_hash", "operations",        "error_codes",
        "severities",            "idioms",            "limits",
        "module_catalog",        "deferred_sections",
    } },
    .{ .op = .features, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"features"} },
    .{ .op = .restrictions, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"restrictions"} },
    .{ .op = .describe_rule, .status = .implemented, .input_fields = &.{"rule"}, .payload_fields = &.{"rules"} },
    .{ .op = .modules, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "graph", "builtins", "extensions", "rejected", "module_graph_hash",
    } },
    .{ .op = .check, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "file", "source_digest", "counts", "properties", "paths", "contract_available",
    } },
    .{ .op = .canonicalize, .status = .implemented, .input_fields = &.{ "file", "simulate" }, .payload_fields = &.{
        "file", "source_digest", "candidates", "simulation",
    } },
    .{ .op = .normalize, .status = .implemented, .input_fields = &.{ "file", "write" }, .payload_fields = &.{
        "file",                 "source_digest", "converged",     "fully_canonical",
        "iterations",           "residual",      "rewrite_trace", "canonical_source",
        "residual_diagnostics",
    } },
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
    .{ .name = "diagnostic_span", .note = "phase 6: JsonDiagnostic carries line and column and no byte range, so a diagnostic publishes an exact byte_offset and no half-open span. Threading offsets through every producer lands with the repair vocabulary" },
    .{ .name = "contract_body", .note = "phase 6: writeContractJson emits mixed-case v1 keys, so check publishes contract_available and leaves the body to `zts check --json --contract` until a snake_case serializer exists" },
    .{ .name = "extension_manifests", .note = "phase 6: no zttp-ext manifest is authenticated yet, so every extension specifier is reported as unavailable and the extensions list is empty" },
    .{ .name = "rule_severity", .note = "no registry can answer it: severity is chosen at each emission site, not per rule - handler_verifier emits ZTS305 as warning and ZTS500 as error from one category. Publishing a derived value would be a guess" },
    .{ .name = "repair_budget", .note = "phase 6: the repair-iteration and tool-call budget is a loop policy no code implements" },
};

/// True when the operation reads a source file, and therefore binds the digest
/// of a real module environment rather than the context-free one.
fn takesFile(spec: *const OperationSpec) bool {
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

    // Transient strings for staleness messages, freed once the response is
    // written. Nothing in the response borrows request memory past this scope.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

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

    const input = root.get("input") orelse std.json.Value{ .null = {} };

    // A file-bound operation binds the digest of the environment it actually
    // read. Everything else binds the context-free digest - the built-in
    // registry with an empty module set - so `expected` has something to
    // compare for every operation and the envelope field is never empty.
    var graph: ?module_graph_record.GraphRecord = null;
    defer if (graph) |*g| g.deinit(allocator);
    var file_rel: ?[]const u8 = null;
    defer if (file_rel) |r| allocator.free(r);

    if (takesFile(spec)) {
        const file_value = switch (input) {
            .object => |o| o.get("file"),
            else => null,
        } orelse return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
            .code = .malformed_request,
            .message = "input.file is required for this operation",
            .field = "input.file",
        });
        if (file_value != .string) {
            return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), .{
                .code = .malformed_request,
                .message = "input.file must be a string",
                .field = "input.file",
            });
        }
        file_rel = agent_identity.canonicalRelPath(allocator, io, canonical_root, file_value.string) catch null;
        graph = module_graph_record.build(allocator, io, canonical_root, file_value.string) catch |err| {
            return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), switch (err) {
                error.PathOutsideProjectRoot => .{
                    .code = .path_outside_project_root,
                    .message = "input.file resolves outside the project root",
                    .field = "input.file",
                },
                error.EntryUnreadable => .{
                    .code = .file_unreadable,
                    .message = "input.file could not be read",
                    .field = "input.file",
                },
                error.GraphTooLarge => .{
                    .code = .internal_error,
                    .message = "the module graph exceeds this compiler's module cap",
                    .field = "input.file",
                },
                error.ProjectRootUnresolvable => .{
                    .code = .project_root_unresolvable,
                    .message = "project_root stopped resolving while the graph was read",
                    .field = "project_root",
                },
                error.OutOfMemory => return err,
            });
        };
    }

    const identity = Identity{
        .policy_hash = rule_registry.policyHash(),
        .module_graph_hash = if (graph) |g| g.hash else module_graph_record.contextFreeHash(),
    };

    // Writing is `apply_repair`'s job, and that operation is phase 6. Refusing
    // here is louder than accepting the flag and ignoring it, which would
    // report a rewrite the client believes was persisted.
    if (op == .normalize and boolField(input, "write")) {
        return writeErrorEnvelope(&json, op_name, identity, .{
            .code = .operation_not_implemented,
            .message = "normalize does not write in schema version 2; apply the returned canonical_source through apply_repair (phase 6)",
            .field = "input.write",
        });
    }

    // Spec 4.8: one guard rule for every operation, run before any work. When
    // `apply_repair` lands in phase 6, this ordering is what makes a stale
    // request write nothing.
    if (try checkExpected(arena.allocator(), root.get("expected"), identity)) |stale| {
        return writeErrorEnvelope(&json, op_name, identity, stale);
    }

    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    var payload_json: std.json.Stringify = .{ .writer = &payload.writer };

    // Operations that produce source-bound diagnostics write them here; the
    // rest leave the array empty.
    var diagnostics: std.Io.Writer.Allocating = .init(allocator);
    defer diagnostics.deinit();

    const success = switch (op) {
        .meta => try writeMetaPayload(&payload_json),
        .features => try writeFeaturesPayload(&payload_json),
        .restrictions => try writeRestrictionsPayload(&payload_json),
        .describe_rule => try writeDescribeRulePayload(&payload_json, input),
        .modules => try writeModulesPayload(&payload_json, &graph.?),
        .canonicalize => try runCanonicalize(allocator, &payload_json, canonical_root, file_rel.?, input),
        .normalize => try runNormalize(allocator, &payload_json, canonical_root, file_rel.?),
        .check => try runCheck(
            allocator,
            io,
            &payload_json,
            &diagnostics,
            canonical_root,
            file_rel.?,
        ),
        else => unreachable, // every other row is `.deferred` and returned above
    };

    const diagnostics_json = if (diagnostics.writer.buffered().len > 0)
        diagnostics.writer.buffered()
    else
        "[]";
    try writeEnvelope(&json, op_name, identity, success, payload.writer.buffered(), diagnostics_json, null);
}

/// Spec 4.8: a supplied `expected` field that does not match the recomputed
/// identity fails the request, naming the mismatched field and both values.
/// An absent block skips the guard entirely.
///
/// An unrecognized key inside `expected` is malformed rather than ignored:
/// silently skipping a misspelled guard field would report success for a
/// request the client believed was guarded, which is the exact failure the
/// guard exists to prevent.
fn checkExpected(
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
                .field = try std.fmt.allocPrint(arena, "expected.{s}", .{key}),
            };

        if (kv.value_ptr.* != .string) {
            return ProtocolError{
                .code = .malformed_request,
                .message = "expected fields must be strings",
                .field = try std.fmt.allocPrint(arena, "expected.{s}", .{key}),
            };
        }

        const supplied = kv.value_ptr.string;
        if (!std.mem.eql(u8, supplied, actual)) {
            return ProtocolError{
                .code = .identity_mismatch,
                .message = try std.fmt.allocPrint(
                    arena,
                    "expected.{s} is stale: request said {s}, this compiler reports {s}",
                    .{ key, supplied, actual },
                ),
                .field = try std.fmt.allocPrint(arena, "expected.{s}", .{key}),
            };
        }
    }
    return null;
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

    try json.objectField("idiom_table_hash");
    try json.write(&zts.idiom_registry.tableHash());
    try json.objectField("restriction_matrix_hash");
    try json.write(&restriction_registry.matrixHash());
    try json.objectField("builtin_registry_hash");
    try json.write(&zts.module_manifest.registryHashFromBindings(&zts.builtin_modules.all));

    try json.objectField("severities");
    try json.beginObject();
    try json.objectField("set");
    try json.beginArray();
    // Derived from the checker's enum, so the closed set on the wire is the one
    // the compiler can actually emit.
    inline for (@typeInfo(zts.strict_checker.Severity).@"enum".fields) |field| {
        const severity: zts.strict_checker.Severity = @enumFromInt(field.value);
        try json.write(severity.label());
    }
    try json.endArray();
    try json.objectField("success_rule");
    try json.write("a response reports success true exactly when it produced no error diagnostic, so warnings and advisories never fail a check");
    try json.endObject();

    try json.objectField("idioms");
    try json.beginArray();
    for (&zts.idiom_registry.entries) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("operation");
        try json.write(entry.operation);
        try json.objectField("idiomatic");
        try json.write(entry.idiomatic);
        try json.objectField("superseded");
        try json.write(entry.superseded);
        try json.objectField("precondition");
        try json.write(entry.precondition);
        // The rewrite that realizes the row, or null when the row is
        // advisory-only. Spec 4.2.1 permits a row with no mechanical rewrite.
        try json.objectField("rewrite_rule");
        if (entry.rewrite_rule) |rule| try json.write(rule) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();

    // Only constants the code enforces. The repair-iteration and tool-call
    // budget spec 4.8 also asks for is a loop policy nothing implements, so it
    // is a deferred section rather than a number invented here.
    try json.objectField("limits");
    try json.beginObject();
    try json.objectField("normalize_iterations");
    try json.write(canonicalize.max_normalize_iterations);
    try json.objectField("request_bytes");
    try json.write(edit_simulate.max_stdin_json_bytes);
    try json.objectField("source_bytes");
    try json.write(module_graph_record.max_source_bytes);
    try json.objectField("module_graph_modules");
    try json.write(module_graph_record.max_modules);
    try json.endObject();

    try json.objectField("module_catalog");
    try json.beginArray();
    for (zts.builtin_modules.all) |binding| {
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(binding.specifier);
        try json.objectField("name");
        try json.write(binding.name);
        try json.objectField("required_capabilities");
        try json.beginArray();
        for (binding.required_capabilities) |cap| try json.write(@tagName(cap));
        try json.endArray();
        try json.objectField("exports");
        try json.beginArray();
        for (binding.exports) |exp| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(exp.name);
            try json.objectField("effect");
            try json.write(@tagName(exp.effect));
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
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
// features, restrictions, describe_rule
// ---------------------------------------------------------------------------

/// Every surface form the profile has an opinion about. `restriction_id` links a
/// refused form to its matrix row; an admitted form has none.
///
/// D3 §6 sketched `{ id, category, status }`. There is no category data behind
/// `category` - the v1 table never had one - so the field is absent rather than
/// invented, and the link to the matrix takes its place.
fn writeFeaturesPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("features");
    try json.beginArray();

    for (json_diagnostics.allowed_feature_names) |name| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(name);
        try json.objectField("status");
        try json.write("allowed");
        try json.objectField("restriction_id");
        try json.write(null);
        try json.endObject();
    }
    for (&restriction_registry.entries) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.feature);
        try json.objectField("status");
        try json.write("blocked");
        try json.objectField("restriction_id");
        try json.write(entry.id);
        try json.endObject();
    }

    try json.endArray();
    try json.endObject();
    return true;
}

/// The whole section-12 matrix, including the rows the frozen v1 surface never
/// published. `enforced_by` and `unenforced_note` are both published: a client
/// that reads only the exclusion list would otherwise believe six rows are
/// enforced when the compiler admits them.
fn writeRestrictionsPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("restrictions");
    try json.beginArray();

    for (&restriction_registry.entries) |*entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("feature");
        try json.write(entry.feature);
        try json.objectField("boundary");
        try json.write(entry.boundary);
        try json.objectField("nature");
        try json.write(entry.nature.label());
        try json.objectField("note");
        try json.write(entry.note);
        try json.objectField("alternative");
        if (entry.alternative) |a| try json.write(a) else try json.write(null);
        try json.objectField("failure_class");
        if (entry.failure_class) |f| try json.write(f) else try json.write(null);
        try json.objectField("proof_unlocked");
        if (entry.proof_unlocked) |p| try json.write(p) else try json.write(null);
        try json.objectField("enforced_by");
        try json.beginArray();
        for (entry.enforced_by) |code| try json.write(code);
        try json.endArray();
        try json.objectField("unenforced_note");
        if (entry.unenforced_note) |n| try json.write(n) else try json.write(null);
        try json.endObject();
    }

    try json.endArray();
    try json.endObject();
    return true;
}

/// The rule registry, optionally filtered to one rule by name or code. An
/// unknown rule is an empty list and `success: true` - the closed operation set
/// answers "no such rule" as data, not as a protocol failure.
///
/// No `severity` field: see the `rule_severity` deferred section.
fn writeDescribeRulePayload(json: *std.json.Stringify, input: std.json.Value) !bool {
    const filter: ?[]const u8 = blk: {
        const obj = switch (input) {
            .object => |o| o,
            else => break :blk null,
        };
        const value = obj.get("rule") orelse break :blk null;
        break :blk if (value == .string) value.string else null;
    };

    try json.beginObject();
    try json.objectField("rules");
    try json.beginArray();
    for (&rule_registry.all_rules) |*rule| {
        if (filter) |name| {
            if (!std.mem.eql(u8, rule.name, name) and !std.mem.eql(u8, rule.code, name)) continue;
        }
        try json.beginObject();
        try json.objectField("name");
        try json.write(rule.name);
        try json.objectField("code");
        try json.write(rule.code);
        try json.objectField("category");
        try json.write(rule.category.label());
        try json.objectField("description");
        try json.write(rule.description);
        try json.objectField("example");
        if (rule.example) |e| try json.write(e) else try json.write(null);
        try json.objectField("help");
        try json.write(rule.help);
        try json.objectField("repair_intent");
        if (rule.repair) |r| try json.write(@tagName(r)) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return true;
}

// ---------------------------------------------------------------------------
// modules
// ---------------------------------------------------------------------------

/// The resolved module environment for one entry file (spec 4.8): the relative
/// graph with source digests, the built-in registry, authenticated extensions,
/// every rejected candidate, and one digest over the whole environment.
///
/// The payload's `module_graph_hash` and the envelope's are the same value,
/// computed once - a client that binds one has bound the other.
fn writeModulesPayload(
    json: *std.json.Stringify,
    graph: *const module_graph_record.GraphRecord,
) !bool {
    try json.beginObject();

    try json.objectField("graph");
    try json.beginArray();
    for (graph.modules) |module| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(module.path);
        try json.objectField("source_digest");
        try json.write(&module.source_digest);
        try json.objectField("imports");
        try json.beginArray();
        for (module.imports) |import| {
            try json.beginObject();
            try json.objectField("specifier");
            try json.write(import.specifier);
            try json.objectField("kind");
            try json.write(@tagName(import.kind));
            try json.objectField("target");
            try json.write(import.target);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("builtins");
    try json.beginArray();
    for (zts.builtin_modules.all) |binding| {
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(binding.specifier);
        try json.objectField("name");
        try json.write(binding.name);
        try json.objectField("required_capabilities");
        try json.beginArray();
        for (binding.required_capabilities) |cap| try json.write(@tagName(cap));
        try json.endArray();
        try json.objectField("exports");
        try json.beginArray();
        for (binding.exports) |exp| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(exp.name);
            try json.objectField("effect");
            try json.write(@tagName(exp.effect));
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    // Empty until a manifest is authenticated; see the extension_manifests
    // deferred section. An extension specifier in source shows up under
    // `rejected`, never silently resolved.
    try json.objectField("extensions");
    try json.beginArray();
    try json.endArray();

    try json.objectField("rejected");
    try json.beginArray();
    for (graph.rejected) |rejection| {
        try json.beginObject();
        try json.objectField("specifier");
        try json.write(rejection.specifier);
        try json.objectField("importer");
        try json.write(rejection.importer);
        try json.objectField("reason");
        try json.write(rejection.reason);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("module_graph_hash");
    try json.write(&graph.hash);

    try json.endObject();
    return graph.rejected.len == 0;
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

/// Run the analyzer once and write both the payload and the diagnostics array.
///
/// `success` is exactly "produced no error diagnostic" (spec 4.8): warnings and
/// advisories never fail a check.
fn runCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    json: *std.json.Stringify,
    diagnostics: *std.Io.Writer.Allocating,
    canonical_root: []const u8,
    file_rel: []const u8,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    // The same bytes the digest covers, so a byte offset published beside a
    // digest indexes into what that digest names.
    const source = try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const digest = agent_identity.sourceDigest(source);

    var diag_json: std.json.Stringify = .{ .writer = &diagnostics.writer };

    var result = precompile.runCheckOnlyWithOptions(allocator, abs, .{
        .json_mode = true,
        .sql_schema_path = null,
        .system_path = null,
    }) catch |err| switch (err) {
        // The v1 path reports this as a ZTS700 diagnostic rather than a crash;
        // the v2 wire keeps it a diagnostic too, so the two surfaces agree on
        // what a missing schema is.
        error.MissingSqlSchema => {
            try diag_json.beginArray();
            try writeDiagnostic(&diag_json, allocator, io, canonical_root, .{
                .code = "ZTS700",
                .severity = "error",
                .message = "zttp:sql queries require a SQL schema, which this operation cannot supply",
                .file = file_rel,
                .line = 1,
                .column = 1,
                .suggestion = "configure sqlite in zttp.json, or check this handler through `zts check --sql-schema`",
            }, digest, source);
            try diag_json.endArray();
            try writeCheckPayload(json, null, file_rel, digest, 1, 0);
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

    try writeCheckPayload(json, &result, file_rel, digest, result.totalErrors(), result.totalWarnings());
    return result.totalErrors() == 0;
}

fn writeCheckPayload(
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
            inline for (@typeInfo(zts.handler_contract.HandlerProperties).@"struct".fields) |field| {
                try json.objectField(field.name);
                switch (field.type) {
                    bool => try json.write(@field(props, field.name)),
                    ?u32 => if (@field(props, field.name)) |v| try json.write(v) else try json.write(null),
                    else => @compileError("unhandled HandlerProperties field type: " ++ @typeName(field.type)),
                }
            }
            try json.endObject();
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

    try json.endObject();
}

/// One source-bound diagnostic.
///
/// Two deliberate absences, both published in `meta.deferred_sections`:
/// no `span`, because no producer computes a half-open byte range and inventing
/// an end would be a lie of precision; and `repair_available` is uniformly
/// false, because spec 4.8 permits advertising an exact repair only when a
/// registered equivalence validator exists, and that registry is phase 6.
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
    if (rule_registry.findByCode(diag.code)) |rule| {
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
    try json.write(byteOffsetOf(source, diag.line, diag.column));
    try json.objectField("suggestion");
    if (diag.suggestion) |sug| try json.write(sug) else try json.write(null);
    try json.objectField("repair_available");
    try json.write(false);
    try json.endObject();
}

/// Byte offset of a 1-based line and column. Exact for the reported position;
/// the end of the range is not published because no producer computes one.
fn byteOffsetOf(source: []const u8, line: u32, column: u32) usize {
    var current_line: u32 = 1;
    var idx: usize = 0;
    while (idx < source.len and current_line < line) : (idx += 1) {
        if (source[idx] == '\n') current_line += 1;
    }
    const offset = idx + @as(usize, if (column > 0) column - 1 else 0);
    return @min(offset, source.len);
}

// ---------------------------------------------------------------------------
// canonicalize and normalize
// ---------------------------------------------------------------------------

/// Spec 4.8: "Until a rewrite has a registered equivalence validator,
/// `canonicalize` and `normalize` MUST report it as a proposed refactor, not a
/// mechanical repair." No validator registry exists before phase 6, so the
/// grade is constant, and it is written from here so phase 6 changes one line.
const candidate_grade = "proposed_refactor";

fn boolField(input: std.json.Value, name: []const u8) bool {
    const obj = switch (input) {
        .object => |o| o,
        else => return false,
    };
    const value = obj.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn runCanonicalize(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    canonical_root: []const u8,
    file_rel: []const u8,
    input: std.json.Value,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    const source = try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const digest = agent_identity.sourceDigest(source);

    var result = try canonicalize.collect(allocator, abs);
    defer result.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("source_digest");
    try json.write(&digest);

    try json.objectField("candidates");
    try json.beginArray();
    for (result.refactors.items) |refactor| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(refactor.kind);
        try json.objectField("grade");
        try json.write(candidate_grade);
        // No Refactor kind corresponds to an idiom row today: measured against
        // the catalog, every line-keyed refactor repairs a canonical-profile
        // restriction, while the idiom table picks among admitted spellings.
        // The one wired pair (drop_unused_index_alias) is a span-keyed rewrite
        // and surfaces in normalize's rewrite_trace instead.
        try json.objectField("idiom_id");
        try json.write(null);
        try json.objectField("line");
        try json.write(refactor.line);
        try json.objectField("column");
        try json.write(refactor.column);
        try json.objectField("message");
        try json.write(refactor.message);
        // D3 §5: the v1 JSON drops original_line, so a client cannot
        // re-validate staleness. The v2 wire publishes it.
        try json.objectField("original");
        if (refactor.original_line) |line| try json.write(line) else try json.write(null);
        try json.objectField("replacement");
        try json.write(refactor.replacement);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("simulation");
    if (boolField(input, "simulate")) {
        const summary = try canonicalize.simulateRefactors(allocator, abs, &result);
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

fn runNormalize(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    canonical_root: []const u8,
    file_rel: []const u8,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    const source = try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const digest = agent_identity.sourceDigest(source);

    var result = try canonicalize.normalize(allocator, abs);
    defer result.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
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
        try json.write(candidate_grade);
        // The phase 0 back-reference: an applied intent resolves to the idiom
        // row it realizes, where one exists.
        try json.objectField("idiom_id");
        if (zts.idiom_registry.findByRewriteRule(name)) |idiom| {
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
        // A file-bound operation gets a real fixture: an empty input would
        // answer with a protocol error and an empty payload, and the gate would
        // pass while proving nothing.
        const input = if (takesFile(spec))
            "{\"file\":\"packages/tools/tests/fixtures/contract/plain_ts.ts\"}"
        else
            "{}";
        const req = try std.fmt.allocPrint(a,
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

test "a matching expected block passes the guard" {
    const a = testing.allocator;
    const policy = rule_registry.policyHash();
    const graph = module_graph_record.contextFreeHash();
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"meta","project_root":".","input":{{}},
        \\ "expected":{{"profile_id":"zts-advanced-1","policy_hash":"{s}","module_graph_hash":"{s}"}}}}
    , .{ policy, graph });
    defer a.free(req);

    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    try testing.expect(parsed.value.object.get("error") == null);
}

test "a stale policy_hash fails with both values named" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hash":"0000000000000000000000000000000000000000000000000000000000000000"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(!obj.get("success").?.bool);
    const err = obj.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hash", err.get("field").?.string);
    // Both values, so a client re-binds without a second round trip.
    const message = err.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, message, "0000000000") != null);
    try testing.expect(std.mem.indexOf(u8, message, &rule_registry.policyHash()) != null);
}

test "a stale profile_id fails the same way" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"profile_id":"zts-1"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.profile_id", err.get("field").?.string);
}

test "a stale module_graph_hash fails the same way" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"module_graph_hash":"deadbeef"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.module_graph_hash", err.get("field").?.string);
}

test "an omitted or empty expected block skips the guard" {
    const a = testing.allocator;
    for ([_][]const u8{
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
        ,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},"expected":{}}
        ,
    }) |body| {
        const out = try respond(a, body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("success").?.bool);
    }
}

test "an unknown key inside expected is malformed, not ignored" {
    // Silently skipping a misspelled guard field would report success for a
    // request the client believed was guarded.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hashh":"x"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hashh", err.get("field").?.string);
}

test "a non-string expected value is malformed" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{},
        \\ "expected":{"policy_hash":2}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("expected.policy_hash", err.get("field").?.string);
}

test "the guard runs before the operation does any work" {
    // A deferred operation reports operation_not_implemented before the guard,
    // and an implemented one reports staleness before dispatching - so a stale
    // request never reaches the code that would act on it.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"apply_repair","project_root":".","input":{},
        \\ "expected":{"policy_hash":"0000000000000000000000000000000000000000000000000000000000000000"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "operation_not_implemented",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "restrictions publishes every matrix row, not only the frozen v1 set" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    try testing.expectEqual(restriction_registry.entries.len, rows.items.len);
    try testing.expect(rows.items.len > restriction_registry.v1_count);

    const first = rows.items[0].object;
    try testing.expect(std.mem.startsWith(u8, first.get("id").?.string, "restriction."));
    try testing.expect(first.get("nature") != null);
    try testing.expect(first.get("enforced_by").? == .array);
}

test "restrictions publishes the rows nothing enforces as unenforced" {
    // Six rows the profile excludes on paper and admits in practice. A client
    // reading only the exclusion list would otherwise believe they are enforced.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    var unenforced: usize = 0;
    for (rows.items) |row| {
        const codes = row.object.get("enforced_by").?.array;
        const note = row.object.get("unenforced_note").?;
        if (codes.items.len == 0) {
            try testing.expect(note == .string);
            unenforced += 1;
        } else {
            try testing.expect(note == .null);
        }
    }
    try testing.expect(unenforced >= 6);
}

test "features publishes both halves and links refused forms to the matrix" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"features","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const items = parsed.value.object.get("payload").?.object.get("features").?.array;
    try testing.expectEqual(
        json_diagnostics.allowed_feature_names.len + restriction_registry.entries.len,
        items.items.len,
    );
    var allowed: usize = 0;
    for (items.items) |f| {
        const status = f.object.get("status").?.string;
        if (std.mem.eql(u8, status, "allowed")) {
            allowed += 1;
            try testing.expect(f.object.get("restriction_id").? == .null);
        } else {
            try testing.expectEqualStrings("blocked", status);
            const id = f.object.get("restriction_id").?.string;
            try testing.expect(restriction_registry.findById(id) != null);
        }
    }
    try testing.expectEqual(json_diagnostics.allowed_feature_names.len, allowed);
}

test "describe_rule with no filter returns every registry rule" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
    try testing.expectEqual(rule_registry.all_rules.len, rules.items.len);
    // No severity field: it is a property of the emission site, not the rule.
    try testing.expect(rules.items[0].object.get("severity") == null);
}

test "describe_rule filters by code and by name" {
    const a = testing.allocator;
    for ([_][]const u8{
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS303"}}
        ,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"unchecked_result_value"}}
        ,
    }) |body| {
        const out = try respond(a, body);
        defer a.free(out);
        var parsed = try parse(a, out);
        defer parsed.deinit();
        const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
        try testing.expectEqual(@as(usize, 1), rules.items.len);
        try testing.expectEqualStrings("ZTS303", rules.items[0].object.get("code").?.string);
        try testing.expectEqualStrings("unchecked_result_value", rules.items[0].object.get("name").?.string);
    }
}

test "describe_rule with an unknown rule succeeds with an empty list" {
    // The closed operation set answers "no such rule" as data, not as a
    // protocol failure.
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"describe_rule","project_root":".","input":{"rule":"ZTS999"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    try testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("payload").?.object.get("rules").?.array.items.len,
    );
    try testing.expect(parsed.value.object.get("error") == null);
}

test "meta names rule_severity as a section no registry can answer" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const sections = parsed.value.object.get("payload").?.object.get("deferred_sections").?.array;
    var found = false;
    for (sections.items) |sec| {
        if (std.mem.eql(u8, sec.object.get("name").?.string, "rule_severity")) found = true;
    }
    try testing.expect(found);
}

test "modules returns the resolved graph and binds one hash in two places" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "util.ts", .data = "export const two = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data =
        \\import { env } from "zttp:env";
        \\import { two } from "./util.ts";
        \\export function handler(req) { return Response.json({ two, e: env("X") }); }
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);

    const payload = obj.get("payload").?.object;
    // One digest, bound in the envelope and in the payload.
    try testing.expectEqualStrings(
        obj.get("module_graph_hash").?.string,
        payload.get("module_graph_hash").?.string,
    );
    try testing.expectEqual(@as(usize, 2), payload.get("graph").?.array.items.len);
    try testing.expect(payload.get("builtins").?.array.items.len > 0);
    try testing.expectEqual(@as(usize, 0), payload.get("rejected").?.array.items.len);

    const imports = payload.get("graph").?.array.items[0].object.get("imports").?.array;
    try testing.expectEqualStrings("zttp:env", imports.items[0].object.get("specifier").?.string);
    try testing.expectEqualStrings("builtin", imports.items[0].object.get("kind").?.string);
    try testing.expectEqualStrings("util.ts", imports.items[1].object.get("target").?.string);
}

test "a file-bound operation binds the graph digest, not the context-free one" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "export function handler(req) { return Response.json({ ok: true }); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const bound = parsed.value.object.get("module_graph_hash").?.string;
    try testing.expect(!std.mem.eql(u8, bound, &module_graph_record.contextFreeHash()));
}

test "modules reports a rejected import and stops claiming success" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "import { gone } from \"./gone.ts\";\nexport const x = gone;\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const obj = parsed.value.object;
    // The environment resolved, so this is not a protocol error - but it did
    // not resolve completely, so it is not a success either.
    try testing.expect(!obj.get("success").?.bool);
    try testing.expect(obj.get("error") == null);
    const rejected = obj.get("payload").?.object.get("rejected").?.array;
    try testing.expectEqual(@as(usize, 1), rejected.items.len);
    try testing.expectEqualStrings("file_unreadable", rejected.items[0].object.get("reason").?.string);
}

test "modules without input.file is malformed, not an empty graph" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"modules","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "modules on a path outside the project root is refused" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "app");
    const base = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, "app", a);
    defer a.free(base);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"../escape.ts"}}}}
    , .{base});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("path_outside_project_root", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
}

test "modules on a missing entry file reports file_unreadable" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"modules","project_root":".","input":{"file":"no/such/handler.ts"}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("file_unreadable", err.get("code").?.string);
}

test "a stale module_graph_hash is caught against the real graph" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "export function handler(req) { return Response.json({ ok: true }); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    // The context-free digest is a real hash, and the wrong one for a file
    // request: the guard must compare against what the operation read.
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.ts"}},
        \\ "expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, module_graph_record.contextFreeHash() });
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("identity_mismatch", err.get("code").?.string);
    try testing.expectEqualStrings("expected.module_graph_hash", err.get("field").?.string);
}

test "check on a clean handler succeeds with no diagnostics" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guardrails = Spec<"state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Response & Guardrails {
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
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
}

test "check on a rejected handler binds every diagnostic to the digest" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A chained ternary: ZTS621, an error-severity canonical-profile rule.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\export function handler(req: Request): Response {
        \\  const n = req.method === "GET" ? 1 : req.method === "POST" ? 2 : 3;
        \\  return Response.json({ n });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
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
        try testing.expect(!d.get("repair_available").?.bool);
        try testing.expect(d.get("span") == null);
        if (std.mem.eql(u8, d.get("code").?.string, "ZTS621")) {
            found_chain = true;
            try testing.expectEqualStrings("canonical_ternary_chain", d.get("rule_id").?.string);
            try testing.expectEqualStrings("error", d.get("severity").?.string);
            try testing.expect(d.get("byte_offset").?.integer > 0);
        }
    }
    try testing.expect(found_chain);
}

test "byte_offset indexes into the bytes the digest covers" {
    const source = "export const a = 1;\nexport const b = 2;\n";
    try testing.expectEqual(@as(usize, 0), byteOffsetOf(source, 1, 1));
    try testing.expectEqual(@as(usize, 7), byteOffsetOf(source, 1, 8));
    try testing.expectEqual(@as(usize, 20), byteOffsetOf(source, 2, 1));
    // A column past the end clamps rather than pointing outside the buffer.
    try testing.expectEqual(source.len, byteOffsetOf(source, 9, 400));
}

test "success is exactly no error diagnostic, not no diagnostic" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ZTS305 unused_variable is emitted at warning severity (measured), so this
    // handler carries a diagnostic and still succeeds - spec 4.8's success rule.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guardrails = Spec<"state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Response & Guardrails {
        \\    const unused = 1;
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guardrails = Spec<"state_isolated" | "injection_safe">;
        \\
        \\export function handler(req: Request): Response & Guardrails {
        \\    return Response.json({ ok: true });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"check","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const paths = parsed.value.object.get("payload").?.object.get("paths").?.object;
    try testing.expect(paths.get("enumerated").?.integer >= 1);
    try testing.expect(paths.get("exhaustive").? == .bool);
    // Phase 0 replaced a bare bool with a cause; the wire carries the cause.
    try testing.expect(paths.get("coverage_note").?.string.len > 0);
}

const let_handler =
    \\import type { Spec } from "zttp:types";
    \\
    \\type Guardrails = Spec<"state_isolated">;
    \\
    \\export function handler(req: Request): Response & Guardrails {
    \\    let name = "world";
    \\    return Response.json({ hello: name });
    \\}
    \\
;

test "canonicalize candidates carry a grade and the original span text" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
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
    // Spec 4.8: without a registered validator every candidate is a proposed
    // refactor, never a mechanical repair.
    try testing.expectEqualStrings("proposed_refactor", first.get("grade").?.string);
    try testing.expect(first.get("replacement").? == .string);
    // D3 §5: v1 drops original_line at the JSON boundary, so a client cannot
    // re-validate staleness. The v2 wire carries it.
    try testing.expect(first.get("original").? == .string);
    try testing.expect(first.get("line").?.integer > 0);
}

test "canonicalize simulates only when asked, and says so either way" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const plain = try std.fmt.allocPrint(a,
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

    const simulated = try std.fmt.allocPrint(a,
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

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(payload.get("converged").?.bool);
    try testing.expect(payload.get("iterations").?.integer >= 1);
    try testing.expect(payload.get("canonical_source").?.string.len > 0);
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

    const req = try std.fmt.allocPrint(a,
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
    try testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "apply_repair") != null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .unlimited);
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "normalize maps an applied intent back to the idiom row it realizes" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The ZTS619 vehicle: `.entries()` with an index the body never reads.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guardrails = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guardrails {
        \\    const arr = [10, 20];
        \\    const out = [];
        \\    for (const pair of arr.entries()) {
        \\        const [_i, x] = pair;
        \\        out.push(x);
        \\    }
        \\    return Response.json({ out });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"normalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const trace = parsed.value.object.get("payload").?.object.get("rewrite_trace").?.array;
    try testing.expectEqual(@as(usize, 1), trace.items.len);
    const entry = trace.items[0].object;
    try testing.expectEqualStrings("drop_unused_index_alias", entry.get("intent").?.string);
    try testing.expectEqualStrings("idiom.element-iteration", entry.get("idiom_id").?.string);
    try testing.expectEqualStrings("proposed_refactor", entry.get("grade").?.string);
}

fn metaPayload(a: std.mem.Allocator, out: *[]u8) !std.json.Parsed(std.json.Value) {
    out.* = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    return parse(a, out.*);
}

test "meta publishes the three registry hashes it binds work to" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings(&rule_registry.policyHash(), payload.get("policy_hash").?.string);
    try testing.expectEqualStrings(&zts.idiom_registry.tableHash(), payload.get("idiom_table_hash").?.string);
    try testing.expectEqualStrings(&restriction_registry.matrixHash(), payload.get("restriction_matrix_hash").?.string);
    try testing.expectEqual(@as(usize, 64), payload.get("builtin_registry_hash").?.string.len);
}

test "meta publishes the closed severity set and the rule that decides success" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const severities = parsed.value.object.get("payload").?.object.get("severities").?.object;
    const set = severities.get("set").?.array;
    // Derived from the checker's enum, so the wire set is what the compiler can
    // actually emit - three since phase 0 added advisory.
    try testing.expectEqual(
        @typeInfo(zts.strict_checker.Severity).@"enum".fields.len,
        set.items.len,
    );
    var found_advisory = false;
    for (set.items) |item| {
        if (std.mem.eql(u8, item.string, "advisory")) found_advisory = true;
    }
    try testing.expect(found_advisory);
    try testing.expect(std.mem.indexOf(u8, severities.get("success_rule").?.string, "no error diagnostic") != null);
}

test "meta publishes the idiom table with its rewrite back-reference" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const idioms = parsed.value.object.get("payload").?.object.get("idioms").?.array;
    try testing.expectEqual(zts.idiom_registry.entries.len, idioms.items.len);

    var wired: usize = 0;
    for (idioms.items) |item| {
        const row = item.object;
        try testing.expect(std.mem.startsWith(u8, row.get("id").?.string, "idiom."));
        try testing.expect(row.get("precondition").? == .string);
        if (row.get("rewrite_rule").? == .string) {
            wired += 1;
            // A named rewrite must resolve back to this row, or the mapping a
            // client follows from a normalize trace is broken.
            const entry = zts.idiom_registry.findByRewriteRule(row.get("rewrite_rule").?.string).?;
            try testing.expectEqualStrings(row.get("id").?.string, entry.id);
        }
    }
    // Advisory-only rows are legal (spec 4.2.1), so most rows carry no rewrite.
    try testing.expect(wired >= 1);
}

test "meta limits are the constants the code enforces" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const limits = parsed.value.object.get("payload").?.object.get("limits").?.object;
    try testing.expectEqual(
        @as(i64, canonicalize.max_normalize_iterations),
        limits.get("normalize_iterations").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(edit_simulate.max_stdin_json_bytes)),
        limits.get("request_bytes").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(module_graph_record.max_source_bytes)),
        limits.get("source_bytes").?.integer,
    );
    try testing.expectEqual(
        @as(i64, @intCast(module_graph_record.max_modules)),
        limits.get("module_graph_modules").?.integer,
    );
}

test "meta publishes the built-in module catalog from the bindings" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const catalog = parsed.value.object.get("payload").?.object.get("module_catalog").?.array;
    try testing.expectEqual(zts.builtin_modules.all.len, catalog.items.len);
    for (catalog.items) |item| {
        const module = item.object;
        try testing.expect(std.mem.startsWith(u8, module.get("specifier").?.string, "zttp:"));
        try testing.expect(module.get("exports").?.array.items.len >= 1);
        try testing.expect(module.get("required_capabilities").? == .array);
    }
}

test "the repair budget is deferred rather than guessed" {
    // Spec 4.8 asks limits to publish a repair-iteration and tool-call budget.
    // No code implements that loop policy, so it is named as deferred instead
    // of appearing as an invented number.
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expect(payload.get("limits").?.object.get("repair_iterations") == null);
    var named = false;
    for (payload.get("deferred_sections").?.array.items) |section| {
        if (std.mem.eql(u8, section.object.get("name").?.string, "repair_budget")) named = true;
    }
    try testing.expect(named);
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
