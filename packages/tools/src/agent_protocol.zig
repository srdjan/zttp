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
const example_registry = @import("example_registry.zig");
const decision_registry = @import("decision_registry.zig");

const policy_catalog = zts.PolicyCatalog;
const idiomCatalog = zts.IdiomCatalog;
const restrictionCatalog = zts.RestrictionCatalog;
const repairPolicy = zts.RepairPolicy;
const moduleMetadata = zts.ModuleMetadata;

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
        "restriction_matrix_hash", "builtin_registry_hash", "operations",
        "error_codes",             "severities",            "idioms",
        "limits",                  "module_catalog",        "deferred_sections",
        "validators",              "verifiers",             "ambient_names",
        "type_serialization",      "grammar",               "source_frontends",
        "examples",                "decisions",
    } },
    .{ .op = .features, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"features"} },
    .{ .op = .restrictions, .status = .implemented, .input_fields = &.{}, .payload_fields = &.{"restrictions"} },
    .{ .op = .describe_rule, .status = .implemented, .input_fields = &.{"rule"}, .payload_fields = &.{"rules"} },
    .{ .op = .modules, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "graph", "builtins", "extensions", "rejected", "module_graph_hash",
    } },
    .{ .op = .check, .status = .implemented, .input_fields = &.{"file"}, .payload_fields = &.{
        "file", "source_digest", "counts", "properties", "paths", "contract_available", "contract_body",
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
    .{ .op = .apply_repair, .status = .implemented, .input_fields = &.{ "file", "repairs" }, .payload_fields = &.{
        "file", "applied", "source_digest", "module_graph_hash", "refusal",
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

const RepairBinding = struct {
    source_digest: [64]u8,
    profile_id: []const u8,
    policy_hash: [64]u8,
    module_graph_hash: [64]u8,

    fn current(source_digest: [64]u8, identity: Identity) RepairBinding {
        return .{
            .source_digest = source_digest,
            .profile_id = agent_identity.profile_id,
            .policy_hash = identity.policy_hash,
            .module_graph_hash = identity.module_graph_hash,
        };
    }

    fn writeJson(self: RepairBinding, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("source_digest");
        try json.write(&self.source_digest);
        try json.objectField("profile_id");
        try json.write(self.profile_id);
        try json.objectField("policy_hash");
        try json.write(&self.policy_hash);
        try json.objectField("module_graph_hash");
        try json.write(&self.module_graph_hash);
        try json.endObject();
    }
};

const RepairBindingCheck = union(enum) {
    valid,
    malformed: []const u8,
    stale: []const u8,
};

fn checkRepairBinding(value: ?std.json.Value, expected: RepairBinding) RepairBindingCheck {
    const object = switch (value orelse return .{ .malformed = "a repair must carry its `bound` identity object" }) {
        .object => |o| o,
        else => return .{ .malformed = "repair `bound` must be an object" },
    };
    if (object.count() != 4) {
        return .{ .malformed = "repair `bound` must contain exactly source_digest, profile_id, policy_hash, and module_graph_hash" };
    }

    const fields = [_]struct { name: []const u8, expected: []const u8 }{
        .{ .name = "source_digest", .expected = &expected.source_digest },
        .{ .name = "profile_id", .expected = expected.profile_id },
        .{ .name = "policy_hash", .expected = &expected.policy_hash },
        .{ .name = "module_graph_hash", .expected = &expected.module_graph_hash },
    };
    for (fields) |field| {
        const supplied = object.get(field.name) orelse
            return .{ .malformed = "repair `bound` is missing a required identity field" };
        if (supplied != .string) {
            return .{ .malformed = "every repair `bound` identity field must be a string" };
        }
        if (!std.mem.eql(u8, supplied.string, field.expected)) {
            return .{ .stale = field.name };
        }
    }
    return .valid;
}

fn contextFreeIdentity() Identity {
    return .{
        .policy_hash = zts.policyHash(),
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
                error.UnsupportedSourceExtension => .{
                    .code = .unsupported_source_extension,
                    .message = "input.file must use the .ts or .tsx extension",
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

    var identity = Identity{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = if (graph) |g| g.hash else module_graph_record.contextFreeHash(),
    };

    // Writing is `apply_repair`'s job, and that operation is phase 6. Refusing
    // here is louder than accepting the flag and ignoring it, which would
    // report a rewrite the client believes was persisted.
    if (op == .normalize and boolField(input, "write")) {
        return writeErrorEnvelope(&json, op_name, identity, .{
            .code = .operation_not_implemented,
            .message = "normalize does not write in schema version 2; apply the returned canonical_source through apply_repair",
            .field = "input.write",
        });
    }

    // Spec 4.8: one guard rule for every operation, run before any work. This
    // ordering is what makes a stale
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

    const meta_view = if (op == .meta)
        parseMetaView(input) catch return writeErrorEnvelope(&json, op_name, identity, .{
            .code = .malformed_request,
            .message = "input.view must be either bootstrap or full",
            .field = "input.view",
        })
    else
        null;

    const success = switch (op) {
        .meta => try writeMetaPayload(&payload_json, meta_view.?),
        .features => try writeFeaturesPayload(&payload_json),
        .restrictions => try writeRestrictionsPayload(&payload_json),
        .describe_rule => try writeDescribeRulePayload(&payload_json, input),
        .modules => try writeModulesPayload(&payload_json, &graph.?),
        .canonicalize => try runCanonicalize(allocator, &payload_json, canonical_root, file_rel.?, identity, input),
        .normalize => try runNormalize(allocator, &payload_json, canonical_root, file_rel.?),
        .check => try runCheck(
            allocator,
            io,
            &payload_json,
            &diagnostics,
            canonical_root,
            file_rel.?,
        ),
        .verify => try runVerify(allocator, &payload_json, canonical_root, file_rel.?, input),
        .simulate_edit => try runSimulateEdit(allocator, &payload_json, canonical_root, file_rel.?, identity, input),
        .apply_repair => try runApplyRepair(allocator, io, &payload_json, canonical_root, file_rel.?, &identity, input),
    };
    // No `else` prong: spec 4.8's operation set is closed and every member is
    // served, so an unhandled one is a compile error rather than a runtime
    // `unreachable`. The `.deferred` early-return above still stands - it is
    // what a future added-but-unbuilt operation would take.

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

const MetaView = enum { bootstrap, full };

fn parseMetaView(input: std.json.Value) error{InvalidMetaView}!MetaView {
    const view = switch (input) {
        .null => return .full,
        .object => |object| object.get("view") orelse return .full,
        else => return error.InvalidMetaView,
    };
    if (view != .string) return error.InvalidMetaView;
    return std.meta.stringToEnum(MetaView, view.string) orelse error.InvalidMetaView;
}

fn writeMetaPayload(json: *std.json.Stringify, view: MetaView) !bool {
    return switch (view) {
        .bootstrap => writeBootstrapMetaPayload(json),
        .full => writeFullMetaPayload(json),
    };
}

fn writeOperationCatalog(json: *std.json.Stringify, include_payload_fields: bool) !void {
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
        if (include_payload_fields) {
            try json.objectField("payload_fields");
            try json.beginArray();
            for (spec.payload_fields) |f| try json.write(f);
            try json.endArray();
            try json.objectField("deferred_note");
            if (spec.deferred_note) |n| try json.write(n) else try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn writeSourceFrontends(json: *std.json.Stringify, include_grammar: bool) !void {
    const frontend_hash = zts.tsxFrontendGrammarHash();
    const core_hash = zts.grammarHash();
    try json.beginArray();
    try json.beginObject();
    try json.objectField("profile_id");
    try json.write(zts.TsxFrontendCatalog.profile_id);
    try json.objectField("grammar_hash");
    try json.write(&frontend_hash);
    try json.objectField("target_profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("target_grammar_hash");
    try json.write(&core_hash);
    try json.objectField("lowering_target");
    try json.write(zts.TsxFrontendCatalog.lowering_target);
    if (include_grammar) {
        try json.objectField("grammar");
        try json.beginArray();
        for (zts.TsxFrontendCatalog.productions()) |production| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(production.name);
            try json.objectField("rhs");
            try json.write(production.rhs);
            try json.endObject();
        }
        try json.endArray();
    }
    try json.endObject();
    try json.endArray();
}

fn writeBootstrapMetaPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();
    try json.objectField("view");
    try json.write("bootstrap");
    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&zts.policyHash());
    try json.objectField("grammar_hash");
    try json.write(&zts.grammarHash());
    try json.objectField("idiom_table_hash");
    try json.write(&zts.idiomTableHash());
    try json.objectField("restriction_matrix_hash");
    try json.write(&zts.restrictionMatrixHash());
    try json.objectField("builtin_registry_hash");
    try json.write(&moduleMetadata.builtinRegistryHash());
    try json.objectField("source_frontends");
    try writeSourceFrontends(json, false);
    try json.objectField("operations");
    try writeOperationCatalog(json, false);
    try json.objectField("full_meta_request");
    try json.beginObject();
    try json.objectField("operation");
    try json.write("meta");
    try json.objectField("input");
    try json.beginObject();
    try json.objectField("view");
    try json.write("full");
    try json.endObject();
    try json.endObject();
    try json.objectField("full_meta_sections");
    try json.beginArray();
    for (specFor(.meta).payload_fields) |field| try json.write(field);
    try json.endArray();
    try json.endObject();
    return true;
}

fn writeFullMetaPayload(json: *std.json.Stringify) !bool {
    try json.beginObject();

    try json.objectField("compiler_version");
    try json.write(expert_meta.compiler_version);
    try json.objectField("profile_id");
    try json.write(agent_identity.profile_id);
    try json.objectField("policy_version");
    try json.write(expert_meta.policy_version);
    try json.objectField("policy_hash");
    try json.write(&zts.policyHash());
    try json.objectField("grammar_hash");
    try json.write(&zts.grammarHash());

    try json.objectField("operations");
    try writeOperationCatalog(json, true);

    try json.objectField("error_codes");
    try json.beginArray();
    inline for (@typeInfo(ErrorCode).@"enum".fields) |field| try json.write(field.name);
    try json.endArray();

    try json.objectField("idiom_table_hash");
    try json.write(&zts.idiomTableHash());
    try json.objectField("restriction_matrix_hash");
    try json.write(&zts.restrictionMatrixHash());
    try json.objectField("builtin_registry_hash");
    try json.write(&moduleMetadata.builtinRegistryHash());
    try json.objectField("source_frontends");
    try writeSourceFrontends(json, true);

    try json.objectField("severities");
    try json.beginObject();
    try json.objectField("set");
    try json.beginArray();
    // Derived from the stable projection, so the closed wire set stays aligned
    // with every checker without exposing a checker-specific severity type.
    inline for (@typeInfo(zts.DiagnosticProjection.Severity).@"enum".fields) |field| {
        const severity: zts.DiagnosticProjection.Severity = @enumFromInt(field.value);
        try json.write(severity.label());
    }
    try json.endArray();
    try json.objectField("success_rule");
    try json.write("a response reports success true exactly when it produced no error diagnostic, so warnings and advisories never fail a check");
    try json.endObject();

    try json.objectField("idioms");
    try json.beginArray();
    for (idiomCatalog.idioms()) |*entry| {
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
    for (zts.builtinModules) |binding| {
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

    // Spec section 8's grammar, production for production, in document order.
    // `scripts/check-grammar-drift.sh` compares the registry behind this to the
    // document itself, so what a client reads here is the section.
    //
    // Every row carries its enforcement point. The section is a structural
    // over-approximation by its own preamble - several productions admit forms
    // the prose excludes - and a grammar published without that distinction
    // would teach an agent to write programs this compiler refuses.
    try json.objectField("grammar");
    try json.beginArray();
    for (zts.GrammarCatalog.productions()) |p| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(p.name);
        try json.objectField("rhs");
        try json.write(p.rhs);
        try json.objectField("enforcement");
        try json.write(p.enforcement.id());
        // The rule that refuses what the production over-admits, where that
        // rule is a member of the policy-hashed registry.
        try json.objectField("rule_code");
        if (p.rule_code) |code| try json.write(code) else try json.write(null);
        // Set instead of `rule_code` when the refusal comes from a band the
        // registry does not cover, so the row still says who answers.
        try json.objectField("note");
        if (p.note) |note| try json.write(note) else try json.write(null);
        try json.endObject();
    }
    try json.endArray();

    // The decision kinds a client keys on (spec 4.8), versioned, each with the
    // response fields that carry it and the next action it admits. The `Id`
    // enum behind this is the wire vocabulary every refusal is written from, so
    // a kind on the wire and a kind published here cannot differ.
    try json.objectField("decisions");
    try json.beginObject();
    try json.objectField("version");
    try json.write(decision_registry.version);
    try json.objectField("kinds");
    try json.beginArray();
    for (&decision_registry.decisions) |row| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(row.id.wire());
        try json.objectField("next_action");
        try json.write(@tagName(row.next_action));
        try json.objectField("description");
        try json.write(row.description);
        try json.objectField("parameters");
        try json.beginArray();
        for (row.parameters) |param| try json.write(param);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();

    // One canonical minimal example per admitted surface form (spec 4.8), so
    // an agent learns the ZTS-specific spellings here rather than from hidden
    // instructions. Every example is checked by the test that publishes it and
    // must report nothing at any severity, so a form that stops being legal
    // fails the build instead of teaching a program the compiler refuses.
    try json.objectField("examples");
    try json.beginArray();
    for (&example_registry.examples) |entry| {
        try json.beginObject();
        try json.objectField("feature");
        try json.write(entry.feature);
        try json.objectField("source");
        try json.write(entry.source);
        try json.endObject();
    }
    try json.endArray();

    // The ambient table (spec 6): the names a handler writes without importing
    // them. Both halves are registry-generated - the values are the
    // `known_globals` list the checker itself reads, and every type row is
    // resolved through the checker's own entry by a gate in `ambient_names`, so
    // a name published here is a name the compiler admits.
    try json.objectField("ambient_names");
    try json.beginObject();
    try json.objectField("types");
    try json.beginArray();
    for (zts.AmbientCatalog.typeNames()) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        // Where the name gets its meaning, which is also whether a later
        // declaration can shadow it.
        try json.objectField("origin");
        try json.write(entry.origin.id());
        // Type arguments the name requires. `Dict` is written `Dict<K, V>` and
        // nothing else, so the name alone is half a spelling.
        try json.objectField("arity");
        try json.write(entry.arity);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("values");
    try json.beginArray();
    for (zts.AmbientCatalog.valueNames()) |name| try json.write(name);
    try json.endArray();
    try json.endObject();

    // The canonical type serialization (spec 5.4). A type digest is an identity
    // a client may cache; the version is what tells it whether a cached
    // identity still applies after a compiler upgrade.
    try json.objectField("type_serialization");
    try json.beginObject();
    try json.objectField("version");
    try json.write(zts.TypeSerialization.version);
    try json.objectField("digest_algorithm");
    try json.write(zts.TypeSerialization.digest_algorithm);
    try json.objectField("digest_encoding");
    try json.write("lowercase hex");
    try json.objectField("max_depth");
    try json.write(zts.TypeSerialization.max_depth);
    try json.objectField("note");
    try json.write("the digest is sha256 over one canonical string per type; two structurally identical types serialize identically and a type graph deeper than max_depth has no identity");
    try json.endObject();

    // The equivalence-validator registry (D3 section 4). Published so a client
    // can read why a repair is or is not advertised, rather than inferring it
    // from a flag with no stated reason.
    try json.objectField("validators");
    try json.beginArray();
    for (repairPolicy.validators()) |row| {
        try json.beginObject();
        try json.objectField("intent");
        try json.write(@tagName(row.intent));
        try json.objectField("method");
        try json.write(row.method.id());
        try json.objectField("status");
        try json.write(@tagName(row.status));
        try json.objectField("precondition");
        if (row.precondition) |p| try json.write(p) else try json.write(null);
        try json.objectField("gradable");
        try json.write(row.gradable());
        try json.endObject();
    }
    try json.endArray();

    // The verifier discovery registry: every property `verify` will answer
    // about, and the family of reasoning that decides it. Derived from
    // `proof_trace.property_info`, which a comptime check ties to
    // `HandlerProperties`, so a new contract property appears here without an
    // edit and `verify` can never advertise a name it would then refuse.
    try json.objectField("verifiers");
    try json.beginArray();
    for (zts.proof_trace.verifiers) |v| {
        try json.beginObject();
        try json.objectField("property");
        try json.write(v.id);
        try json.objectField("kind");
        try json.write(v.kind.asString());
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
    for (restrictionCatalog.restrictions()) |*entry| {
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

    for (restrictionCatalog.restrictions()) |*entry| {
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
    for (policy_catalog.rules()) |*rule| {
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
    for (zts.builtinModules) |binding| {
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
/// `apply_repair`: the same repairs as `simulate_edit`, written to disk.
///
/// The only operation on this wire that writes, and it is gated four ways
/// before it does. Every repair's intent must be gradable, meaning the registry
/// says something discharges it - spec 4.8 permits advertising an exact repair
/// only under that condition, and applying one unasked is a stronger claim than
/// advertising it. Each repair is then applied on its own and discharged
/// against its law on the actual edit, so a rewriter that mis-locates a
/// construct is caught here rather than trusted. The result runs the veto, and
/// a single new diagnostic refuses the whole set. The write happens once, at
/// the end, from a buffer that passed all three.
///
/// Atomic by construction: repairs accumulate in memory and any refusal returns
/// before the file is touched, so a rejected set leaves the file exactly as it
/// was rather than half-repaired.
fn runApplyRepair(
    allocator: std.mem.Allocator,
    io: std.Io,
    json: *std.json.Stringify,
    canonical_root: []const u8,
    file_rel: []const u8,
    identity: *Identity,
    input: ?std.json.Value,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    const source = try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const before_digest = agent_identity.sourceDigest(source);

    var repairs: std.ArrayListUnmanaged(canonicalize.Repair) = .empty;
    defer repairs.deinit(allocator);
    if (try parseRepairs(allocator, json, &repairs, file_rel, before_digest, identity.*, input, source)) |refused| return refused;

    if (repairs.items.len == 0) {
        return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .no_repairs, "`repairs` must carry at least one repair");
    }

    // Gradability first, before anything is applied: refusing early keeps the
    // reason about the request rather than about a rewrite it should not have
    // reached.
    for (repairs.items) |r| {
        if (!repairPolicy.isGradable(r.intent)) {
            return try writeApplyRefusalWithGraph(
                json,
                file_rel,
                before_digest,
                identity.module_graph_hash,
                .ungraded_intent,
                "this operation applies only repairs a registered validator discharges; read meta.validators, and use simulate_edit to preview an ungraded one",
            );
        }
    }

    // Validate the set as a set before applying any of it. Every repair's span
    // is an offset into the file as read, so overlap and staleness are facts
    // about the request that must be settled against those bytes: applying one
    // repair first would move the others and turn "these two repairs conflict"
    // into "this repair is stale", which names the wrong one. The spliced
    // result is discarded; only the verdict is wanted here.
    {
        const dry = canonicalize.applyRepairs(allocator, source, repairs.items) catch |err| switch (err) {
            error.StaleRepair => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .stale_repair, "a repair's `original` does not match the file as it stands"),
            error.OverlappingRepairs => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .overlapping_repairs, "two repairs cover the same bytes"),
            error.RepairOutOfBounds => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it"),
            else => return err,
        };
        allocator.free(dry);
    }

    // Then one at a time, each discharged against its own law on the edit it
    // produced. A bulk apply followed by one check could not say which repair
    // was wrong, and could not catch two rewrites that are each wrong in ways
    // that cancel in the final text.
    //
    // Descending by start offset, which is what the span vocabulary requires
    // and the line vocabulary hid: splicing at the highest offset first leaves
    // every lower span, and every line number below it, exactly where the
    // client computed it. Ascending order would shift the rest by the length
    // difference after the first splice.
    const order = try allocator.alloc(usize, repairs.items.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    for (1..order.len) |i| {
        var j = i;
        while (j > 0 and repairs.items[order[j - 1]].start_offset < repairs.items[order[j]].start_offset) : (j -= 1) {
            const tmp = order[j - 1];
            order[j - 1] = order[j];
            order[j] = tmp;
        }
    }

    var current = try allocator.dupe(u8, source);
    defer allocator.free(current);
    for (order) |idx| {
        const r = repairs.items[idx];
        var one = [_]canonicalize.Repair{r};
        const next = canonicalize.applyRepairs(allocator, current, &one) catch |err| switch (err) {
            error.StaleRepair => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .stale_repair, "a repair's `original` does not match the file as it stands"),
            error.OverlappingRepairs => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .overlapping_repairs, "two repairs cover the same bytes"),
            error.RepairOutOfBounds => return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it"),
            else => return err,
        };

        switch (try repairPolicy.validateApplication(allocator, r.intent, current, next, r.line)) {
            .equivalent => {},
            .not_law_shape => |why| {
                allocator.free(next);
                return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .not_law_shape, why);
            },
            .no_validator => {
                allocator.free(next);
                return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .ungraded_intent, "no validator discharges this intent");
            },
            // The validator ran and formed no answer. That is its own refusal
            // code rather than one of the two above: the edit was neither
            // graded wrong nor left ungraded, and folding it into either would
            // tell the client something that did not happen.
            .undecided => |why| {
                allocator.free(next);
                return try writeApplyRefusalWithGraph(json, file_rel, before_digest, identity.module_graph_hash, .undecided_equivalence, why);
            },
        }

        allocator.free(current);
        current = next;
    }

    var verdict = try edit_simulate.simulate(allocator, .{
        .file = abs,
        .content = current,
        .before = source,
    });
    defer verdict.deinit(allocator);
    if (verdict.new_count > 0) {
        return try writeApplyRefusalWithGraph(
            json,
            file_rel,
            before_digest,
            identity.module_graph_hash,
            .veto,
            "the repaired file carries diagnostics the original did not; nothing was written",
        );
    }

    // Derive the identity of the bytes that passed validation before mutating
    // the file. Imported modules still come from disk, while the entry module
    // is read from `current`, so an edit that changes imports is represented in
    // the post-edit graph without a write-first failure window.
    var post_graph = module_graph_record.buildWithEntrySource(
        allocator,
        io,
        canonical_root,
        file_rel,
        current,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return try writeApplyRefusalWithGraph(
            json,
            file_rel,
            before_digest,
            identity.module_graph_hash,
            .veto,
            "the repaired module graph could not be resolved; nothing was written",
        ),
    };
    defer post_graph.deinit(allocator);

    try zts.file_io.writeFile(allocator, abs, current);
    const after_digest = agent_identity.sourceDigest(current);
    identity.module_graph_hash = post_graph.hash;

    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
    try json.objectField("applied");
    try json.write(repairs.items.len);
    // The digest of what is now on disk, so the client's next request can bind
    // to the file it just changed rather than the one it read.
    try json.objectField("source_digest");
    try json.write(&after_digest);
    try json.objectField("module_graph_hash");
    try json.write(&identity.module_graph_hash);
    try json.objectField("refusal");
    try json.write(null);
    try json.endObject();
    return true;
}

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
/// Shared by `simulate_edit` and `apply_repair` so the two cannot disagree
/// about what a repair is - a client that previewed a set and then applied it
/// must not find the second call parsing it differently.
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
fn runSimulateEdit(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    canonical_root: []const u8,
    file_rel: []const u8,
    identity: Identity,
    input: ?std.json.Value,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    const source = try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const digest = agent_identity.sourceDigest(source);

    var repairs: std.ArrayListUnmanaged(canonicalize.Repair) = .empty;
    defer repairs.deinit(allocator);
    // Shared with `apply_repair`: a client that previewed a set and then
    // applied it must not find the second call parsing it differently. The
    // refusal shape differs by operation, so the parser writes `apply_repair`'s
    // and simulate maps it - both carry the same `reason` strings.
    if (try parseRepairs(allocator, json, &repairs, file_rel, digest, identity, input, source)) |refused| return refused;

    if (repairs.items.len == 0) {
        return try writeSimulateRefusal(json, file_rel, digest, .no_repairs, "`repairs` must carry at least one repair; simulating nothing has no answer to give");
    }

    const proposed = canonicalize.applyRepairs(allocator, source, repairs.items) catch |err| switch (err) {
        error.StaleRepair => return try writeSimulateRefusal(json, file_rel, digest, .stale_repair, "a repair's `original` does not match the file as it stands; re-read the file and re-derive the repair"),
        error.OverlappingRepairs => return try writeSimulateRefusal(json, file_rel, digest, .overlapping_repairs, "two repairs cover the same bytes, so which one applies is undefined"),
        error.RepairOutOfBounds => return try writeSimulateRefusal(json, file_rel, digest, .repair_out_of_range, "a repair names a line past the end of the file, or a byte span outside it"),
        else => return err,
    };
    defer allocator.free(proposed);

    var verdict = try edit_simulate.simulate(allocator, .{
        .file = abs,
        .content = proposed,
        .before = source,
    });
    defer verdict.deinit(allocator);

    try json.beginObject();
    try json.objectField("file");
    try json.write(file_rel);
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
fn runVerify(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    canonical_root: []const u8,
    file_rel: []const u8,
    input: ?std.json.Value,
) !bool {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file_rel });
    defer allocator.free(abs);

    // An optional `content` override is what closes the propose -> simulate ->
    // verify cycle without a write. `simulate_edit` hands back
    // `proposed_content`; without this a client could only verify the file it
    // had not repaired yet, and would have to write the candidate to disk
    // through `apply_repair` just to ask about it.
    //
    // The digest covers whatever was analyzed, so a verdict about supplied
    // bytes is never bound to the digest of bytes on disk that nobody checked.
    const supplied: ?[]const u8 = blk: {
        const obj = (input orelse break :blk null).object;
        const value = obj.get("content") orelse break :blk null;
        if (value != .string) break :blk null;
        break :blk value.string;
    };

    const source = if (supplied) |c|
        try allocator.dupe(u8, c)
    else
        try zts.file_io.readFile(allocator, abs, 10 * 1024 * 1024);
    defer allocator.free(source);
    const digest = agent_identity.sourceDigest(source);

    var result = (if (supplied != null)
        precompile.runCheckOnlyFromSource(allocator, source, abs, null, true, null, false)
    else
        precompile.runCheckOnlyWithOptions(allocator, abs, .{
            .json_mode = true,
            .sql_schema_path = null,
            .system_path = null,
        })) catch |err| switch (err) {
        // Every property is undecided rather than false: the analysis never
        // ran, and reporting `not_proven` would claim a verdict nothing
        // produced.
        error.MissingSqlSchema => {
            try writeVerifyPayload(allocator, json, file_rel, digest, null, input);
            return false;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    try writeVerifyPayload(allocator, json, file_rel, digest, result.proof_trace_json, input);
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
    try json.write(if (holds) "proven" else "not_proven");

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
            inline for (@typeInfo(zts.HandlerProperties).@"struct".fields) |field| {
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

    try json.objectField("contract_body");
    if (result) |r| {
        if (r.contract) |*contract| {
            try json.beginWriteRaw();
            try zts.handler_contract.writeContractJsonV2(contract, json.writer);
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
/// Eight rows answer true, every one of them under M4: the validator
/// re-derives the declared law's rewrite from the original and requires the
/// candidate to match it byte for byte. Six are line-local, and two -
/// `flatten_destructure` (ZTS618) and `drop_unused_index_alias` (ZTS619) -
/// replace a run of lines and also re-derive the precondition that makes the
/// rewrite an equivalence. Every other row is still `planned` and answers
/// false.
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
    try json.write(repairAvailableFor(diag.code));
    try json.endObject();
}

/// True when the rule behind this diagnostic carries a repair intent whose
/// equivalence validator is registered and implemented. A code with no rule, or
/// a rule with no typed repair, answers false: an unclassified rewrite is
/// exactly what must not be advertised.
fn repairAvailableFor(code: []const u8) bool {
    const rule = policy_catalog.findByCode(code) orelse return false;
    const intent = rule.repair orelse return false;
    return repairPolicy.isGradable(intent);
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
/// mechanical repair."
///
/// The grade was a constant while no row was implemented, which made it true
/// by accident. It answers from the registry now, so a rewrite is called
/// mechanical exactly when something discharges it - the same condition
/// `repair_available` keys on, read from the same place.
fn candidateGrade(intent: zts.RepairIntent) []const u8 {
    return if (repairPolicy.isGradable(intent)) "mechanical_repair" else "proposed_refactor";
}

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
    identity: Identity,
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
    for (result.repairs.items) |repair| {
        try json.beginObject();
        // D3 §5's `repair` carries the typed intent, not a per-producer string.
        // `Refactor` used to carry one and that is what made the third parallel
        // vocabulary: five of its names differed from the tag by more than
        // spelling. The legacy names survive only on the frozen v1 surface.
        try json.objectField("intent");
        try json.write(@tagName(repair.intent));
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
        const summary = try canonicalize.simulateRepairs(allocator, abs, &result);
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
        try repair.object.put(arena, "bound", .{ .object = bound });
    }

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    var json: std.json.Stringify = .{ .writer = &encoded.writer };
    try json.write(parsed.value);
    return respond(allocator, encoded.writer.buffered());
}

fn currentTestRepairBinding(
    allocator: std.mem.Allocator,
    canonical_root: []const u8,
    file: []const u8,
) !RepairBinding {
    const abs = try std.fs.path.resolve(allocator, &.{ canonical_root, file });
    defer allocator.free(abs);
    const source = try zts.file_io.readFile(allocator, abs, module_graph_record.max_source_bytes);
    defer allocator.free(source);
    var graph = try module_graph_record.build(allocator, testing.io, canonical_root, file);
    defer graph.deinit(allocator);
    return RepairBinding.current(agent_identity.sourceDigest(source), .{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = graph.hash,
    });
}

const TestStaleBindingField = enum { none, source_digest, profile_id, policy_hash, module_graph_hash };

fn testRepairJson(
    allocator: std.mem.Allocator,
    intent: []const u8,
    line: u32,
    original: []const u8,
    replacement: []const u8,
    binding: RepairBinding,
    stale_field: TestStaleBindingField,
) ![]u8 {
    const stale = "stale";
    return std.fmt.allocPrint(allocator,
        \\{{"intent":"{s}","line":{d},"original":{f},"replacement":{f},"bound":{{"source_digest":"{s}","profile_id":"{s}","policy_hash":"{s}","module_graph_hash":"{s}"}}}}
    , .{
        intent,
        line,
        std.json.fmt(original, .{}),
        std.json.fmt(replacement, .{}),
        if (stale_field == .source_digest) stale else &binding.source_digest,
        if (stale_field == .profile_id) stale else binding.profile_id,
        if (stale_field == .policy_hash) stale else &binding.policy_hash,
        if (stale_field == .module_graph_hash) stale else &binding.module_graph_hash,
    });
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

test "meta bootstrap view is bounded and routes to full discovery" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{"view":"bootstrap"}}
    );
    defer a.free(out);

    // This response is injected into every new agent transcript. A full meta
    // response is intentionally much larger and remains available on demand.
    try testing.expect(out.len <= 8 * 1024);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("success").?.bool);
    const payload = root.get("payload").?.object;
    try testing.expectEqualStrings("bootstrap", payload.get("view").?.string);
    try testing.expectEqualStrings(&zts.policyHash(), payload.get("policy_hash").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    try testing.expectEqualStrings(&zts.idiomTableHash(), payload.get("idiom_table_hash").?.string);
    try testing.expectEqualStrings(&zts.restrictionMatrixHash(), payload.get("restriction_matrix_hash").?.string);
    try testing.expectEqual(@as(usize, 64), payload.get("builtin_registry_hash").?.string.len);
    const frontend = payload.get("source_frontends").?.array.items[0].object;
    try testing.expectEqualStrings(zts.TsxFrontendCatalog.profile_id, frontend.get("profile_id").?.string);
    try testing.expectEqualStrings(&zts.tsxFrontendGrammarHash(), frontend.get("grammar_hash").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), frontend.get("target_grammar_hash").?.string);
    try testing.expect(frontend.get("grammar") == null);

    const ops = payload.get("operations").?.array;
    try testing.expectEqual(operations.len, ops.items.len);
    const full = payload.get("full_meta_request").?.object;
    try testing.expectEqualStrings("meta", full.get("operation").?.string);
    try testing.expectEqualStrings("full", full.get("input").?.object.get("view").?.string);
    const sections = payload.get("full_meta_sections").?.array;
    try testing.expect(sections.items.len > 0);
    try testing.expect(payload.get("grammar") == null);
    try testing.expect(payload.get("examples") == null);
}

test "meta refuses an unknown view" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{"view":"verbose"}}
    );
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("success").?.bool);
    const protocol_error = root.get("error").?.object;
    try testing.expectEqualStrings("malformed_request", protocol_error.get("code").?.string);
    try testing.expectEqualStrings("input.view", protocol_error.get("field").?.string);
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
    // The sections no registry can generate are named, not stubbed. Counted
    // against the table rather than a floor: the floor was a stand-in for "the
    // list is populated" and had to be edited down every time a section closed,
    // which is a number drifting behind the thing it describes.
    const sections = payload.get("deferred_sections").?.array;
    try testing.expectEqual(deferred_sections.len, sections.items.len);
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

test "spec 4.8's operation set is closed and every member is served" {
    // This test used to drive `apply_repair` and assert
    // `operation_not_implemented`, which was the honest answer while three
    // operations were unbuilt. There are none left, so it asserts the state
    // that replaced it. A future operation added as `.deferred` fails here and
    // has to say so deliberately rather than inheriting a passing test.
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
    try testing.expectEqual(@as(usize, @typeInfo(Operation).@"enum".fields.len), operations.len);
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
    try testing.expectEqualStrings(&zts.policyHash(), obj.get("policy_hash").?.string);
    try testing.expectEqualStrings("zts-advanced-1", obj.get("profile_id").?.string);
}

test "a matching expected block passes the guard" {
    const a = testing.allocator;
    const policy = zts.policyHash();
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
    try testing.expect(std.mem.indexOf(u8, message, &zts.policyHash()) != null);
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
    // A stale request never reaches the code that would act on it. The example
    // is `apply_repair` on purpose: it is the one operation that writes, so
    // "the guard runs first" is the difference between a refusal and a file
    // changed on the strength of a policy the client no longer has.
    //
    // The file exists and carries a real, applicable repair, so the only thing
    // standing between the request and a write is the guard. Asserting the file
    // is byte-identical afterwards is the part that matters; the error code
    // alone would not distinguish "refused" from "wrote, then refused".
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}},
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

test "restrictions publishes every matrix row, not only the frozen v1 set" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"restrictions","project_root":".","input":{}}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("restrictions").?.array;
    try testing.expectEqual(restrictionCatalog.restrictions().len, rows.items.len);
    try testing.expect(rows.items.len > restrictionCatalog.v1Count());

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
    // Two rows remain: `restriction.unchecked-recursion` (not a rejection by
    // design) and `restriction.unbound-native-module` (enforced outside the rule
    // registry). `restriction.interface` left this set when phase 7 refused the
    // form with ZTS049; it had been waiting on a migration policy that is now
    // decided. An exact count, so closing or opening a gap has to come here and
    // say which.
    try testing.expectEqual(@as(usize, 2), unenforced);
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
        json_diagnostics.allowed_feature_names.len + restrictionCatalog.restrictions().len,
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
            try testing.expect(restrictionCatalog.findById(id) != null);
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
    try testing.expectEqual(policy_catalog.rules().len, rules.items.len);
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

test "modules refuses a JavaScript entry extension" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.js",
        .data = "export function handler(req) { return Response.text('ok'); }\n",
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"handler.js"}}}}
    , .{root});
    defer a.free(req);

    const out = try respond(a, req);
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqualStrings("unsupported_source_extension", err.get("code").?.string);
    try testing.expectEqualStrings("input.file", err.get("field").?.string);
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
    const contract_body = payload.get("contract_body") orelse return error.TestUnexpectedResult;
    try testing.expect(contract_body == .object);
    const contract_version = contract_body.object.get("version") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 2), contract_version.integer);
    try testing.expect(contract_body.object.get("service_calls") != null);
    try testing.expect(contract_body.object.get("serviceCalls") == null);
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

    const request = try std.fmt.allocPrint(allocator,
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
    \\  return Response.json({ n });
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
            try testing.expect(d.get("byte_offset").?.integer > 0);
            // A range, not a point: the diagnostic names the token it points
            // at. An empty span here would mean the producer had no extent,
            // which is the state this task closed.
            try testing.expect(end > start);
        }
    }
    try testing.expect(found_chain);
}

test "repair_available is true for the one intent with an implemented validator" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ZTS620 carries `drop_redundant_bool_compare`, whose registry row reached
    // `.implemented`. The sibling test above pins the other direction: ZTS621
    // names no implemented validator and still answers false. Both matter -
    // a flag that is true everywhere advertises exactly as little as one that
    // is false everywhere.
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

    const req = try std.fmt.allocPrint(a,
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

test "apply_repair writes a graded repair and rebinds the digest" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\import { marker } from "./util.ts";
        \\
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    let name = "world";
        \\    return Response.json({ hello: name, marker });
        \\}
        \\
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "util.ts", .data = "export const marker = 1;\n" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    var before_graph = try module_graph_record.build(a, testing.io, root, "h.ts");
    const before_hash = before_graph.hash;
    before_graph.deinit(a);
    try testing.expect(!std.mem.eql(u8, &before_hash, &module_graph_record.contextFreeHash()));

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":7,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 1), payload.get("applied").?.integer);
    try testing.expect(payload.get("refusal").? == .null);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") == null);

    // The digest names what is now on disk, so the client's next request binds
    // to the file it just changed rather than the one it read.
    const digest = agent_identity.sourceDigest(on_disk);
    try testing.expectEqualStrings(&digest, payload.get("source_digest").?.string);

    var after_graph = try module_graph_record.build(a, testing.io, root, "h.ts");
    defer after_graph.deinit(a);
    try testing.expect(!std.mem.eql(u8, &before_hash, &after_graph.hash));
    try testing.expect(!std.mem.eql(u8, &after_graph.hash, &module_graph_record.contextFreeHash()));
    try testing.expectEqualStrings(&after_graph.hash, payload.get("module_graph_hash").?.string);
    try testing.expectEqualStrings(
        parsed.value.object.get("module_graph_hash").?.string,
        payload.get("module_graph_hash").?.string,
    );

    const followup_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"modules","project_root":"{s}","input":{{"file":"h.ts"}},"expected":{{"module_graph_hash":"{s}"}}}}
    , .{ root, payload.get("module_graph_hash").?.string });
    defer a.free(followup_req);
    const followup_out = try respond(a, followup_req);
    defer a.free(followup_out);
    var followup = try parse(a, followup_out);
    defer followup.deinit();
    try testing.expect(followup.value.object.get("success").?.bool);
}

test "apply_repair accepts a repair keyed on a byte span" {
    // The span is what a repair is keyed on now. `line` still works - the test
    // above sends one, and a field cannot be removed inside schema version 2 -
    // but a client that took `span` off a `canonicalize` candidate must be able
    // to hand it straight back, which is the round trip the two operations
    // exist to make possible.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const target = "    let name = \"world\";";
    const start = std.mem.indexOf(u8, let_handler, target).?;

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","span":{{"start":{d},"end":{d}}},"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}}}}
    , .{ root, start, start + target.len });
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 1), payload.get("applied").?.integer);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") == null);
}

test "apply_repair accepts the one wired idiom row" {
    // ZTS619 is spec 4.2.1's `element iteration` row and the only idiom row
    // with a rewrite behind it. Its validator row said M2, which cannot
    // discharge a rewrite that deletes a statement, so the repair was
    // advertised as a proposal and this operation refused it. Under the M4 law
    // it is applied, and the law re-derives both the header rewrite and the
    // two facts that make it an equivalence.
    const a = testing.allocator;
    const source =
        \\export function handler(req: Request): Response {
        \\    const arr = [10, 20];
        \\    const out = [];
        \\    for (const pair of arr.entries()) {
        \\        const [_i, x] = pair;
        \\        out.push(x);
        \\    }
        \\    return Response.json({ out });
        \\}
        \\
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = source });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const target = "    for (const pair of arr.entries()) {\n        const [_i, x] = pair;\n";
    const start = std.mem.indexOf(u8, source, target).?;

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"drop_unused_index_alias","span":{{"start":{d},"end":{d}}},"original":"    for (const pair of arr.entries()) {{\n        const [_i, x] = pair;\n","replacement":"    for (const x of arr) {{\n"}}]}}}}
    , .{ root, start, start + target.len });
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("success").?.bool);
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 1), payload.get("applied").?.integer);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "for (const x of arr) {") != null);
    try testing.expect(std.mem.indexOf(u8, on_disk, ".entries()") == null);
    try testing.expect(std.mem.indexOf(u8, on_disk, "const [_i, x]") == null);
}

test "apply_repair refuses a span outside the file" {
    // The floor under the test above: a span the client made up is refused
    // rather than clamped, so "the span form works" is not satisfied by an
    // applier that ignores the span it was given.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","span":{{"start":10,"end":99999}},"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 0), payload.get("applied").?.integer);
    try testing.expectEqualStrings("repair_out_of_range", payload.get("refusal").?.object.get("reason").?.string);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
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

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(req);
    const out = try respond(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const candidates = parsed.value.object.get("payload").?.object.get("candidates").?.array;
    try testing.expect(candidates.items.len >= 1);
    for (candidates.items) |item| {
        const c = item.object;
        const span = c.get("span").?.object;
        const start: usize = @intCast(span.get("start").?.integer);
        const end: usize = @intCast(span.get("end").?.integer);
        try testing.expect(end <= let_handler.len);
        try testing.expectEqualStrings(let_handler[start..end], c.get("original").?.string);
    }
}

test "a bound canonicalize candidate round-trips unchanged through simulate and apply" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const propose_req = try std.fmt.allocPrint(a,
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

    const simulate_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"simulate_edit","project_root":"{s}","input":{{"file":"h.ts","repairs":[{f}]}}}}
    , .{ root, std.json.fmt(candidate, .{}) });
    defer a.free(simulate_req);
    const simulate_out = try respond(a, simulate_req);
    defer a.free(simulate_out);
    var simulated = try parse(a, simulate_out);
    defer simulated.deinit();
    try testing.expect(simulated.value.object.get("payload").?.object.get("ok").?.bool);

    const apply_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{f}]}}}}
    , .{ root, std.json.fmt(candidate, .{}) });
    defer a.free(apply_req);
    const apply_out = try respond(a, apply_req);
    defer a.free(apply_out);
    var applied = try parse(a, apply_out);
    defer applied.deinit();
    try testing.expect(applied.value.object.get("success").?.bool);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "const name") != null);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") == null);
}

test "simulate and apply refuse an unbound repair" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    for ([_][]const u8{ "simulate_edit", "apply_repair" }) |operation| {
        const req = try std.fmt.allocPrint(a,
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

test "simulate and apply refuse every stale repair binding" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);
    const binding = try currentTestRepairBinding(a, root, "h.ts");

    for ([_]TestStaleBindingField{ .source_digest, .profile_id, .policy_hash, .module_graph_hash }) |stale_field| {
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
        for ([_][]const u8{ "simulate_edit", "apply_repair" }) |operation| {
            const req = try std.fmt.allocPrint(a,
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

test "simulate and apply refuse a mixed-binding batch atomically" {
    const a = testing.allocator;
    const source =
        \\
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
        \\    let first = "a";
        \\    let second = "b";
        \\    return Response.json({ first, second });
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

    for ([_][]const u8{ "simulate_edit", "apply_repair" }) |operation| {
        const req = try std.fmt.allocPrint(a,
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

test "apply_repair refuses an ungraded intent without touching the file" {
    // The gate that separates this operation from `simulate_edit`. Applying a
    // rewrite unasked is a stronger claim than advertising it, so only an
    // intent a registered validator discharges may be written.
    // `add_trailing_return` is correctly ungradable - it exists to change what
    // the program does - and must never be auto-applied.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"add_trailing_return","line":6,"original":"    let name = \"world\";","replacement":"    return Response.json({{}});"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 0), payload.get("applied").?.integer);
    try testing.expectEqualStrings("ungraded_intent", payload.get("refusal").?.object.get("reason").?.string);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
}

test "apply_repair is atomic: a rejected set leaves the file untouched" {
    // Two repairs, the first applicable and the second stale. Repairs
    // accumulate in memory and any refusal returns before the file is touched,
    // so the file must not come back half-repaired - which is the failure a
    // client cannot recover from, because it no longer matches either the
    // digest it read or the one it expected.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}},{{"intent":"replace_let_with_const","line":7,"original":"    let other = 1;","replacement":"    const other = 1;"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 0), payload.get("applied").?.integer);
    try testing.expect(payload.get("refusal").? == .object);

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);

    // The refusal's own digest has to be the digest of what is on disk. Byte
    // equality above proves the file did not move; this proves the response did
    // not lie about it, which is the field a client rebinds from and the one
    // thing a half-applied write would make wrong.
    const reported = payload.get("source_digest").?.string;
    const actual = agent_identity.sourceDigest(on_disk);
    try testing.expectEqualStrings(&actual, reported);
}

test "apply_repair refuses an overlapping set and writes nothing" {
    // The refusal exists in the apply path and no test reached it through the
    // wire until now. Two repairs on the same line cover the same bytes, so
    // which one applies is undefined - the set is refused whole.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"world\";"}},{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"earth\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 0), payload.get("applied").?.integer);
    try testing.expectEqualStrings(
        "overlapping_repairs",
        payload.get("refusal").?.object.get("reason").?.string,
    );

    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expectEqualStrings(let_handler, on_disk);
    const reported = payload.get("source_digest").?.string;
    const actual = agent_identity.sourceDigest(on_disk);
    try testing.expectEqualStrings(&actual, reported);
}

test "apply_repair refuses an edit its own law does not discharge" {
    // The discharge runs on the actual edit, not on the intent name. A repair
    // that claims `replace_let_with_const` and rewrites the line to something
    // else is caught here rather than trusted, which is why the validator
    // re-derives independently instead of calling the rewriter.
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h.ts", .data = let_handler });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"apply_repair","project_root":"{s}","input":{{"file":"h.ts","repairs":[{{"intent":"replace_let_with_const","line":6,"original":"    let name = \"world\";","replacement":"    const name = \"attacker\";"}}]}}}}
    , .{root});
    defer a.free(req);
    const out = try respondWithCurrentRepairBindings(a, req);
    defer a.free(out);

    var parsed = try parse(a, out);
    defer parsed.deinit();
    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqual(@as(i64, 0), payload.get("applied").?.integer);
    try testing.expectEqualStrings("not_law_shape", payload.get("refusal").?.object.get("reason").?.string);

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
    const req = try std.fmt.allocPrint(a,
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
    const req = try std.fmt.allocPrint(a,
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
    const req = try std.fmt.allocPrint(a,
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
    const propose_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"canonicalize","project_root":"{s}","input":{{"file":"h.ts"}}}}
    , .{root});
    defer a.free(propose_req);
    const propose_out = try respond(a, propose_req);
    defer a.free(propose_out);
    var proposed = try parse(a, propose_out);
    defer proposed.deinit();
    const candidate = proposed.value.object.get("payload").?.object.get("candidates").?.array.items[0];

    // 2. Simulate, using the candidate's own fields verbatim.
    const simulate_req = try std.fmt.allocPrint(a,
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
    // write the candidate to disk to ask about it - which is `apply_repair`'s
    // job and still deferred.
    const verify_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["state_isolated","canonical"],"content":{f}}}}}
    , .{ root, std.json.fmt(sim_payload.get("proposed_content").?.string, .{}) });
    defer a.free(verify_req);
    const verify_out = try respond(a, verify_req);
    defer a.free(verify_out);
    var verified = try parse(a, verify_out);
    defer verified.deinit();

    const results = verified.value.object.get("payload").?.object.get("results").?.array;
    for (results.items) |r| {
        try testing.expectEqualStrings("proven", r.object.get("grade").?.string);
    }

    // The file on disk never changed: the whole cycle is read-only.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "h.ts", a, .limited(4096));
    defer a.free(on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "let name") != null);
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

    const file_req = try std.fmt.allocPrint(a,
        \\{{"schema_version":2,"operation":"verify","project_root":"{s}","input":{{"file":"h.ts","properties":["canonical"]}}}}
    , .{root});
    defer a.free(file_req);
    const file_out = try respond(a, file_req);
    defer a.free(file_out);
    var from_file = try parse(a, file_out);
    defer from_file.deinit();

    const content_req = try std.fmt.allocPrint(a,
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
        \\  return Response.json({ k: env("SECRET") ?? "none" });
        \\}
        \\
    });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", a);
    defer a.free(root);

    const req = try std.fmt.allocPrint(a,
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
    try testing.expectEqualStrings("not_proven", leak.get("grade").?.string);
    const evidence = leak.get("evidence").?.object;
    try testing.expectEqualStrings("flow-trace", evidence.get("kind").?.string);
    // A failed verify with a counterexample is a reproduction, not a verdict.
    try testing.expect(evidence.get("counterexample").? == .object);

    try testing.expectEqualStrings("proven", results.items[1].object.get("grade").?.string);

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

    const req = try std.fmt.allocPrint(a,
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

test "meta publishes the verifier registry it will answer about" {
    const a = testing.allocator;
    const out = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":"."}
    );
    defer a.free(out);
    var parsed = try parse(a, out);
    defer parsed.deinit();

    const verifiers = parsed.value.object.get("payload").?.object.get("verifiers").?.array;
    try testing.expectEqual(zts.proof_trace.verifiers.len, verifiers.items.len);

    // The registry advertises wire names. Publishing the internal spelling
    // would name a property `verify` then answers `unknown_property` about.
    var saw_results_safe = false;
    for (verifiers.items) |item| {
        const id = item.object.get("property").?.string;
        try testing.expect(zts.proof_trace.isVerifier(id));
        if (std.mem.eql(u8, id, "results_safe")) saw_results_safe = true;
    }
    try testing.expect(saw_results_safe);

    // The section retires in the same change that makes it answerable.
    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "verifiers"));
    }
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

    const req = try std.fmt.allocPrint(a,
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
    const meta_req = try std.fmt.allocPrint(a,
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
    \\
    \\
    \\structural Guardrails<T> = Proof<T, "state_isolated">;
    \\
    \\export function handler(req: Request): Guardrails<Response> {
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
    // Spec 4.8: a candidate is a mechanical repair exactly when a registered
    // validator discharges it, and a proposed refactor otherwise. This one is
    // `replace_let_with_const`, whose M4 row is implemented.
    try testing.expectEqualStrings("mechanical_repair", first.get("grade").?.string);
    try testing.expect(first.get("replacement").? == .string);
    // D3 §5: v1 drops original_line at the JSON boundary, so a client cannot
    // re-validate staleness. The v2 wire carries it.
    try testing.expect(first.get("original").? == .string);
    try testing.expect(first.get("line").?.integer > 0);

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
        \\
        \\structural Guardrails<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guardrails<Response> {
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
    // The other side of the same rule. This row named M2 and could not be
    // discharged by it - the rewrite deletes a statement, so the trees differ
    // by construction - and it now names M4 with a law that re-derives both the
    // header rewrite and the two preconditions the producer used to check for
    // itself. The one idiom row with a wired rewrite is therefore gradable, and
    // `apply_repair` will take it.
    try testing.expectEqualStrings("mechanical_repair", entry.get("grade").?.string);
}

fn metaPayload(a: std.mem.Allocator, out: *[]u8) !std.json.Parsed(std.json.Value) {
    out.* = try respond(a,
        \\{"schema_version":2,"operation":"meta","project_root":".","input":{}}
    );
    return parse(a, out.*);
}

test "meta publishes the registry hashes it binds work to" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings(&zts.policyHash(), payload.get("policy_hash").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    try testing.expectEqualStrings(&zts.idiomTableHash(), payload.get("idiom_table_hash").?.string);
    try testing.expectEqualStrings(&zts.restrictionMatrixHash(), payload.get("restriction_matrix_hash").?.string);
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
    // Derived from the stable projection, so the wire set is what every checker
    // can emit - three since phase 0 added advisory.
    try testing.expectEqual(
        @typeInfo(zts.DiagnosticProjection.Severity).@"enum".fields.len,
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
    try testing.expectEqual(idiomCatalog.idioms().len, idioms.items.len);

    var wired: usize = 0;
    for (idioms.items) |item| {
        const row = item.object;
        try testing.expect(std.mem.startsWith(u8, row.get("id").?.string, "idiom."));
        try testing.expect(row.get("precondition").? == .string);
        if (row.get("rewrite_rule").? == .string) {
            wired += 1;
            // A named rewrite must resolve back to this row, or the mapping a
            // client follows from a normalize trace is broken.
            const entry = idiomCatalog.findByRewriteRule(row.get("rewrite_rule").?.string).?;
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
    try testing.expectEqual(zts.builtinModules.len, catalog.items.len);
    for (catalog.items) |item| {
        const module = item.object;
        try testing.expect(std.mem.startsWith(u8, module.get("specifier").?.string, "zttp:"));
        try testing.expect(module.get("exports").?.array.items.len >= 1);
        try testing.expect(module.get("required_capabilities").? == .array);
    }
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
        // A file that fails in the stripper for a different reason.
        "export function handler(req: Request): any {\n  return Response.text(\"x\");\n}\n",
        // A file that fails in the parser rather than the stripper.
        "export function handler(req) {\n  const n = 0x;\n  return Response.json({ n });\n}\n",
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

        const req = try std.fmt.allocPrint(a,
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

test "meta publishes every decision kind a refusal can carry, with its next action" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const section = parsed.value.object.get("payload").?.object.get("decisions").?.object;
    try testing.expectEqual(@as(i64, decision_registry.version), section.get("version").?.integer);

    const kinds = section.get("kinds").?.array;
    try testing.expectEqual(decision_registry.decisions.len, kinds.items.len);
    for (kinds.items, &decision_registry.decisions) |item, row| {
        const published = item.object;
        try testing.expectEqualStrings(row.id.wire(), published.get("id").?.string);
        try testing.expectEqualStrings(@tagName(row.next_action), published.get("next_action").?.string);
        try testing.expect(published.get("parameters").?.array.items.len > 0);
    }

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section_row| {
        try testing.expect(!std.mem.eql(u8, section_row.object.get("name").?.string, "decisions"));
    }
}

test "a refusal on the wire carries a published kind and its next action" {
    // The end the registry exists for. A client reads `refusal.reason`, looks
    // it up in `meta.decisions`, and branches on `next_action` - so the string
    // a real refusal emits has to be one of the published identifiers, and the
    // next action beside it has to be the registry's.
    const a = testing.allocator;
    const req =
        \\{"schema_version":2,"operation":"apply_repair","project_root":".","input":{"file":"packages/tools/tests/fixtures/contract/plain_ts.ts","repairs":[]}}
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
    // A malformed request is not evidence the file moved, and the wire says so.
    try testing.expectEqualStrings("fix_the_request", refusal.get("next_action").?.string);
    const envelope_hash = parsed.value.object.get("module_graph_hash").?.string;
    const payload_hash = parsed.value.object.get("payload").?.object.get("module_graph_hash").?.string;
    try testing.expectEqualStrings(envelope_hash, payload_hash);
    try testing.expect(!std.mem.eql(u8, payload_hash, &module_graph_record.contextFreeHash()));
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
    // The legality gate. `runCheckOnlyFromSource` is the same path `zts check`
    // takes, so an example that stops being legal fails here rather than
    // teaching a form this compiler now refuses. Warnings count: an example
    // that checks with a warning is one an agent would copy into a warning.
    const a = testing.allocator;
    for (&example_registry.examples) |entry| {
        var result = try precompile.runCheckOnlyFromSource(a, entry.source, "example.ts", null, true, null, false);
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

test "every published example exercises the form it names" {
    // A clean example that no longer contains its form still checks clean, so
    // legality alone would let an edit hollow one out. The evidence is read
    // from the parse tree or the stripper's type map wherever either records
    // the form, and from the source only for the three that leave no trace.
    const a = testing.allocator;
    for (&example_registry.examples) |entry| {
        var strip_result = try zts.strip(a, entry.source, .{ .enable_comptime = true, .comptime_env = .{} });
        defer strip_result.deinit();

        var parser = try zts.parser.JsParser.init(a, strip_result.code);
        defer parser.deinit();
        const root = try parser.parse();
        _ = root;
        const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);

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
            .type_annotation => |kind| blk: {
                for (strip_result.type_map.entries.items) |item| {
                    if (item.kind == kind) break :blk true;
                }
                break :blk false;
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
    // no example contains: `while` is refused by this profile and appears in
    // none of them.
    const a = testing.allocator;
    const entry = example_registry.findByFeature("match expression") orelse
        return error.TestExpectedExample;

    var strip_result = try zts.strip(a, entry.source, .{});
    defer strip_result.deinit();
    var parser = try zts.parser.JsParser.init(a, strip_result.code);
    defer parser.deinit();
    _ = try parser.parse();
    const view = zts.IrView.fromIRStore(&parser.nodes, &parser.constants);

    var saw_while = false;
    var saw_match = false;
    var i: zts.parser.NodeIndex = 0;
    while (i < view.nodeCount()) : (i += 1) {
        const tag = view.getTag(i) orelse continue;
        if (tag == .while_stmt) saw_while = true;
        if (tag == .match_expr) saw_match = true;
    }
    try testing.expect(saw_match);
    try testing.expect(!saw_while);
}

test "the examples section stops being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    const rows = payload.get("examples").?.array;
    try testing.expectEqual(example_registry.examples.len, rows.items.len);
    for (rows.items, &example_registry.examples) |item, entry| {
        try testing.expectEqualStrings(entry.feature, item.object.get("feature").?.string);
        try testing.expectEqualStrings(entry.source, item.object.get("source").?.string);
    }
    for (payload.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "examples"));
    }
}

test "meta publishes section 8's grammar production for production, in order" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    try testing.expectEqualStrings(&zts.grammarHash(), payload.get("grammar_hash").?.string);
    const rows = payload.get("grammar").?.array;
    const table = zts.GrammarCatalog.productions();
    try testing.expectEqual(table.len, rows.items.len);

    // Order is part of the published artifact: the document reads top down, and
    // the drift gate compares the two in that order.
    for (rows.items, table) |item, p| {
        const row = item.object;
        try testing.expectEqualStrings(p.name, row.get("name").?.string);
        try testing.expectEqualStrings(p.rhs, row.get("rhs").?.string);
        try testing.expectEqualStrings(p.enforcement.id(), row.get("enforcement").?.string);
    }
    try testing.expectEqualStrings("Module", rows.items[0].object.get("name").?.string);
}

test "meta publishes the TSX frontend grammar bound to its core target" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const payload = parsed.value.object.get("payload").?.object;
    const frontends = payload.get("source_frontends").?.array;
    try testing.expectEqual(@as(usize, 1), frontends.items.len);
    const frontend = frontends.items[0].object;
    try testing.expectEqualStrings(zts.TsxFrontendCatalog.profile_id, frontend.get("profile_id").?.string);
    try testing.expectEqualStrings(&zts.tsxFrontendGrammarHash(), frontend.get("grammar_hash").?.string);
    try testing.expectEqualStrings(agent_identity.profile_id, frontend.get("target_profile_id").?.string);
    try testing.expectEqualStrings(&zts.grammarHash(), frontend.get("target_grammar_hash").?.string);
    try testing.expectEqualStrings(zts.TsxFrontendCatalog.lowering_target, frontend.get("lowering_target").?.string);

    const rows = frontend.get("grammar").?.array;
    try testing.expectEqual(zts.TsxFrontendCatalog.productions().len, rows.items.len);
    for (rows.items, zts.TsxFrontendCatalog.productions()) |item, production| {
        try testing.expectEqualStrings(production.name, item.object.get("name").?.string);
        try testing.expectEqualStrings(production.rhs, item.object.get("rhs").?.string);
    }
}

test "a production that over-admits says which rule refuses the excess" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const rows = parsed.value.object.get("payload").?.object.get("grammar").?.array;

    var check_rows: usize = 0;
    for (rows.items) |item| {
        const row = item.object;
        const has_code = row.get("rule_code").? != .null;
        const has_note = row.get("note").? != .null;
        if (std.mem.eql(u8, row.get("enforcement").?.string, "parse_time")) {
            try testing.expect(!has_code and !has_note);
            continue;
        }
        check_rows += 1;
        // Exactly one of the two, on the wire as well as in the table: a row
        // that says "something else refuses this" and names nothing is not
        // actionable by the client reading it.
        try testing.expect(has_code != has_note);
        if (has_code) {
            const code = row.get("rule_code").?.string;
            try testing.expect(zts.PolicyCatalog.findByCode(code) != null);
        }
    }
    // The floor. A payload of nothing but parse_time rows would satisfy the
    // loop while publishing the over-approximation as if it were exact.
    try testing.expect(check_rows >= 10);
}

test "the grammar section stops being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        try testing.expect(!std.mem.eql(u8, section.object.get("name").?.string, "grammar"));
    }
}

test "meta publishes the ambient value names as the known-globals list itself" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const ambient = parsed.value.object.get("payload").?.object.get("ambient_names").?.object;
    const values = ambient.get("values").?.array;

    // Both directions against the source list: a global the checker knows and
    // this does not publish teaches an agent to import a name it need not, and
    // a name published here that the checker does not know teaches it to call
    // one that does not exist.
    const known = zts.AmbientCatalog.valueNames();
    try testing.expectEqual(known.len, values.items.len);
    for (known, 0..) |name, i| {
        try testing.expectEqualStrings(name, values.items[i].string);
    }
}

test "every published ambient type name carries its origin and its arity" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const ambient = parsed.value.object.get("payload").?.object.get("ambient_names").?.object;
    const rows = ambient.get("types").?.array;
    const table = zts.AmbientCatalog.typeNames();
    try testing.expectEqual(table.len, rows.items.len);

    var saw_generic = false;
    for (rows.items, table) |item, entry| {
        const row = item.object;
        try testing.expectEqualStrings(entry.name, row.get("name").?.string);
        try testing.expectEqualStrings(entry.origin.id(), row.get("origin").?.string);
        try testing.expectEqual(@as(i64, entry.arity), row.get("arity").?.integer);
        if (entry.arity > 0) saw_generic = true;
    }
    // The floor for the arity field: a table of arity-zero rows would satisfy
    // the loop above while proving nothing about the field.
    try testing.expect(saw_generic);

    // `Dict` is the value kind spec 6.2 names, and it is written with two type
    // arguments or not at all.
    var dict_arity: ?u8 = null;
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, "Dict")) dict_arity = entry.arity;
    }
    try testing.expectEqual(@as(?u8, 2), dict_arity);
}

test "meta publishes the type serialization version a cached digest is valid under" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    const section = parsed.value.object.get("payload").?.object.get("type_serialization").?.object;
    try testing.expectEqual(@as(i64, zts.TypeSerialization.version), section.get("version").?.integer);
    try testing.expectEqualStrings("sha256", section.get("digest_algorithm").?.string);
    try testing.expectEqual(@as(i64, zts.TypeSerialization.max_depth), section.get("max_depth").?.integer);
}

test "two independently parsed identical types serialize to one digest" {
    // What the published version is a version OF. Without this the section
    // would advertise a stable identity that nothing had measured.
    const a = testing.allocator;
    var pool = zts.TypePool.init(a);
    defer pool.deinit(a);

    const source = "{ id: string, tags: string[] }";
    const first = zts.parseTypeExpr(&pool, a, source);
    const second = zts.parseTypeExpr(&pool, a, source);
    try testing.expect(first != second); // the pool does not intern

    const digest_a = try zts.typeDigest(&pool, a, first);
    const digest_b = try zts.typeDigest(&pool, a, second);
    try testing.expectEqualSlices(u8, &digest_a, &digest_b);

    // The floor: a different type gets a different digest, so the equality
    // above is the encoding's doing and not a constant.
    const other = zts.parseTypeExpr(&pool, a, "{ id: number, tags: string[] }");
    const digest_c = try zts.typeDigest(&pool, a, other);
    try testing.expect(!std.mem.eql(u8, &digest_a, &digest_c));
}

test "the two sections this change makes answerable stop being deferred" {
    const a = testing.allocator;
    var raw: []u8 = undefined;
    var parsed = try metaPayload(a, &raw);
    defer a.free(raw);
    defer parsed.deinit();

    for (parsed.value.object.get("payload").?.object.get("deferred_sections").?.array.items) |section| {
        const name = section.object.get("name").?.string;
        try testing.expect(!std.mem.eql(u8, name, "ambient_names"));
        try testing.expect(!std.mem.eql(u8, name, "type_serialization"));
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
