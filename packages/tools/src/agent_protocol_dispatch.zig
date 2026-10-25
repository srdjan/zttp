//! Agent protocol dispatch: parse a request, negotiate, and run one operation.

const std = @import("std");
const zts = @import("zts");
const agent_identity = @import("agent_identity.zig");
const module_graph_record = @import("module_graph_record.zig");
const canonicalize = @import("canonicalize.zig");
const request_mod = @import("agent_protocol_request.zig");
const readRootSource = request_mod.readRootSource;
const RootSourceReader = request_mod.RootSourceReader;
const envelope_mod = @import("agent_protocol_envelope.zig");
const writeErrorEnvelope = envelope_mod.writeErrorEnvelope;
const contextFreeIdentity = request_mod.contextFreeIdentity;
const writeNegotiation = envelope_mod.writeNegotiation;
const Operation = envelope_mod.Operation;
const specFor = envelope_mod.specFor;
const CapturedFile = request_mod.CapturedFile;
const takesFile = envelope_mod.takesFile;
const Identity = envelope_mod.Identity;
const canon_mod = @import("agent_protocol_canon.zig");
const boolField = canon_mod.boolField;
const checkExpected = envelope_mod.checkExpected;
const meta_mod = @import("agent_protocol_meta.zig");
const parseMetaView = meta_mod.parseMetaView;
const writeMetaPayload = meta_mod.writeMetaPayload;
const writeFeaturesPayload = meta_mod.writeFeaturesPayload;
const writeRestrictionsPayload = meta_mod.writeRestrictionsPayload;
const writeDescribeRulePayload = meta_mod.writeDescribeRulePayload;
const writeModulesPayload = meta_mod.writeModulesPayload;
const runCanonicalize = canon_mod.runCanonicalize;
const runNormalize = canon_mod.runNormalize;
const check_mod = @import("agent_protocol_check.zig");
const runCheck = check_mod.runCheck;
const verify_mod = @import("agent_protocol_verify.zig");
const runVerify = verify_mod.runVerify;
const simulate_mod = @import("agent_protocol_simulate.zig");
const runSimulateEdit = simulate_mod.runSimulateEdit;
const writeEnvelope = envelope_mod.writeEnvelope;

/// Handle one request. Always writes exactly one JSON object and a trailing
/// newline; a malformed or unsupported request produces a response, never an
/// error return. The error set covers only writer failure and allocation.
pub fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    request_json: []const u8,
    writer: *std.Io.Writer,
) !void {
    return handleRequestWithRootReader(allocator, io, request_json, writer, .{
        .context = null,
        .readFn = readRootSource,
    });
}

pub fn handleRequestWithRootReader(
    allocator: std.mem.Allocator,
    io: std.Io,
    request_json: []const u8,
    writer: *std.Io.Writer,
    root_source_reader: RootSourceReader,
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
    var captured: ?CapturedFile = null;
    defer if (captured) |*file| file.deinit(allocator);

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
        captured = CapturedFile.init(
            allocator,
            io,
            root_source_reader,
            canonical_root,
            file_value.string,
            op,
            input,
        ) catch |err| {
            return writeErrorEnvelope(&json, op_name, contextFreeIdentity(), switch (err) {
                error.InvalidSourceObservation => return err,
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
                    .message = "input.file must use the .ts extension",
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

    const captured_file = if (captured) |*file| file else null;

    const identity = Identity{
        .policy_hash = zts.policyHash(),
        .module_graph_hash = if (captured_file) |file|
            file.graph.hash
        else
            module_graph_record.contextFreeHash(),
    };

    // Source mutation belongs to Pi's aggregate propose/prove/apply lane.
    // Refusing here is louder than accepting the flag and ignoring it, which would
    // report a rewrite the client believes was persisted.
    if (op == .normalize and boolField(input, "write")) {
        return writeErrorEnvelope(&json, op_name, identity, .{
            .code = .operation_not_implemented,
            .message = "normalize does not write; submit the returned canonical_source through propose_change_set",
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
        .modules => try writeModulesPayload(&payload_json, &captured_file.?.graph),
        .canonicalize => try runCanonicalize(allocator, &payload_json, captured_file.?, identity, input),
        .normalize => try runNormalize(allocator, &payload_json, captured_file.?),
        .check => try runCheck(
            allocator,
            io,
            &payload_json,
            &diagnostics,
            canonical_root,
            captured_file.?,
        ),
        .verify => try runVerify(allocator, &payload_json, captured_file.?, input),
        .simulate_edit => try runSimulateEdit(allocator, &payload_json, captured_file.?, identity, input),
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
