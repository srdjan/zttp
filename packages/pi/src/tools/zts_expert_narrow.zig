//! zts_expert_narrow - per-path label flow report for a handler.
//!
//! Runs FlowChecker on the handler and reports each diagnostic together with
//! the path constraints that witness it (method comparisons, stub truthiness,
//! result-ok narrowing). The expert uses this to suggest a discriminating
//! guard that would close a leak on one branch without restructuring the
//! handler; the autoloop uses it as the input to /guard-for synthesis.

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const flow_checker = zts.flow_checker;
const counterexample = zts.counterexample;
const writeJsonString = zts.writeJsonString;

const name = "zts_expert_narrow";

pub fn run(
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror!registry_mod.ToolResult {
    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);

    const source = zts.file_io.readFile(
        allocator,
        absolute,
        common.default_output_limit,
    ) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": cannot read {s}: {s}\n",
            .{ path, @errorName(e) },
        );
    };
    defer allocator.free(source);

    const source_kind = common.admitToolSource(allocator, source, path) catch |e| {
        switch (e) {
            error.InvalidSourceObservation => return e,
            else => {},
        }
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": TypeScript strip failed: {s}\n",
            .{@errorName(e)},
        );
    };

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = if (source_kind.isTyped())
        try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile)
    else
        try zts.parser.JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const program_root = js_parser.parse() catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": parse failed: {s}\n",
            .{@errorName(e)},
        );
    };
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

    const handler_fn = zts.findHandlerFunction(ir_view, program_root) orelse {
        return registry_mod.ToolResult.err(
            allocator,
            name ++ ": no handler function found in file\n",
        );
    };

    var env_public = try common.discoverEnvPublic(allocator, path);
    defer env_public.deinit(allocator);
    var checker = zts.FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    checker.scopes = &js_parser.scopes;
    checker.env_public = env_public.names();
    _ = checker.check(handler_fn) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": flow check failed: {s}\n",
            .{@errorName(e)},
        );
    };

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    try writeEnvelope(text_buf.writer(), path, checker.getDiagnostics());

    return .{
        .ok = true,
        .llm_text = try text_buf.toOwnedSlice(),
    };
}

fn writeEnvelope(
    writer: *std.Io.Writer,
    path: []const u8,
    diagnostics: []const flow_checker.Diagnostic,
) !void {
    try writer.writeAll("{\"path\":\"");
    try writer.writeAll(path);
    try writer.writeAll("\",\"witnesses\":[");
    var emitted: usize = 0;
    for (diagnostics) |diag| {
        const witness = diag.witness orelse continue;
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (emitted > 0) try writer.writeByte(',');
        emitted += 1;
        try writeWitness(writer, tag, diag, witness);
    }
    try writer.writeAll("]}");
}

fn writeWitness(
    writer: *std.Io.Writer,
    tag: counterexample.PropertyTag,
    diag: flow_checker.Diagnostic,
    witness: flow_checker.Witness,
) !void {
    try writer.writeAll("{\"property\":\"");
    try writer.writeAll(tag.asString());
    try writer.writeAll("\",\"message\":");
    try writeJsonString(writer, diag.message);
    try writer.writeAll(",\"conditions\":[");
    for (witness.path_constraints, 0..) |c, i| {
        if (i > 0) try writer.writeByte(',');
        try writeConstraint(writer, c);
    }
    try writer.writeAll("]}");
}

fn writeConstraint(writer: *std.Io.Writer, c: counterexample.WitnessConstraint) !void {
    switch (c) {
        .req_method => |value| {
            try writer.writeAll("{\"kind\":\"req_method\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .req_method_not => |value| {
            try writer.writeAll("{\"kind\":\"req_method_not\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .req_url => |value| {
            try writer.writeAll("{\"kind\":\"req_url\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .req_url_not => |value| {
            try writer.writeAll("{\"kind\":\"req_url_not\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .req_path => |value| {
            try writer.writeAll("{\"kind\":\"req_path\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .req_path_not => |value| {
            try writer.writeAll("{\"kind\":\"req_path_not\",\"value\":");
            try writeJsonString(writer, value);
            try writer.writeAll("}");
        },
        .stub_truthy => |info| try writeStubConstraint(writer, "stub_truthy", info),
        .stub_falsy => |info| try writeStubConstraint(writer, "stub_falsy", info),
        .stub_present => |info| try writeStubConstraint(writer, "stub_present", info),
        .stub_absent => |info| try writeStubConstraint(writer, "stub_absent", info),
        .result_ok => |info| try writeStubConstraint(writer, "result_ok", info),
        .result_not_ok => |info| try writeStubConstraint(writer, "result_not_ok", info),
        .status_is => |t| {
            // A status test needs its truth value: the stub alone does not say
            // which side of the comparison the path takes.
            try writer.writeAll("{\"kind\":\"status_is\",\"module\":");
            try writeJsonString(writer, t.stub.module);
            try writer.writeAll(",\"func\":");
            try writeJsonString(writer, t.stub.func);
            try writer.print(",\"expect\":{s}}}", .{if (t.expect) "true" else "false"});
        },
    }
}

fn writeStubConstraint(
    writer: *std.Io.Writer,
    kind: []const u8,
    info: counterexample.StubInfo,
) !void {
    try writer.writeAll("{\"kind\":\"");
    try writer.writeAll(kind);
    try writer.writeAll("\",\"module\":");
    try writeJsonString(writer, info.module);
    try writer.writeAll(",\"func\":");
    try writeJsonString(writer, info.func);
    try writer.writeAll("}");
}
