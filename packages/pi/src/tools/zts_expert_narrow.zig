//! zts_expert_narrow - per-path label flow report for a handler.
//!
//! Runs the production check on the handler and reports each diagnostic together with
//! the path constraints that witness it (method comparisons, stub truthiness,
//! result-ok narrowing). The expert uses this to suggest a discriminating
//! guard that would close a leak on one branch without restructuring the
//! handler; the autoloop uses it as the input to /guard-for synthesis.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
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

    var observed: Observed = .{
        .body = registry_mod.helpers.TextBuffer.init(allocator),
    };
    defer observed.body.deinit();

    var check = common.runProductionCheck(allocator, source, path, .{
        .context = &observed,
        .on_checked = onChecked,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": production check failed: {s}\n",
            .{@errorName(e)},
        ),
    };
    defer check.deinit(allocator);

    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try w.writeAll("{\"path\":\"");
    try w.writeAll(path);
    if (observed.ran) {
        try w.writeAll("\",\"witnesses\":[");
        try w.writeAll(observed.body.written());
        try w.writeAll("]}");
        return .{ .ok = true, .llm_text = try text_buf.toOwnedSlice() };
    }

    // The check stopped before the verifier. A file with no handler that passed
    // every earlier stage keeps its error; any other early stop is a refusal that
    // `zts check` reports, and the tool reports it with no witnesses.
    if (common.hasNoHandler(&check)) {
        return registry_mod.ToolResult.err(
            allocator,
            name ++ ": no handler function found in file\n",
        );
    }
    try w.writeAll("\",\"diagnostics\":[");
    try common.writeProductionDiagnostics(w, check.json_diagnostics.items);
    try w.writeAll("],\"witnesses\":[]}");
    return .{ .ok = false, .llm_text = try text_buf.toOwnedSlice() };
}

/// State the production check's observer fills. `body` holds the witness
/// objects, separated by commas.
const Observed = struct {
    body: registry_mod.helpers.TextBuffer,
    ran: bool = false,
};

fn onChecked(context: *anyopaque, view: zts_cli.precompile.CheckedView) error{OutOfMemory}!void {
    const observed: *Observed = @ptrCast(@alignCast(context));
    writeWitnesses(observed.body.writer(), view.flow_diagnostics) catch |e| switch (e) {
        // A write into the in-memory buffer fails only when it cannot grow.
        error.WriteFailed => return error.OutOfMemory,
    };
    observed.ran = true;
}

fn writeWitnesses(
    writer: *std.Io.Writer,
    diagnostics: []const flow_checker.Diagnostic,
) !void {
    var emitted: usize = 0;
    for (diagnostics) |diag| {
        const witness = diag.witness orelse continue;
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (emitted > 0) try writer.writeByte(',');
        emitted += 1;
        try writeWitness(writer, tag, diag, witness);
    }
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

const testing = std.testing;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("../test_support/cwd.zig");

fn narrowIn(
    allocator: std.mem.Allocator,
    label: []const u8,
    files: []const [2][]const u8,
) !registry_mod.ToolResult {
    var tmp = try IsolatedTmp.init(allocator, label);
    defer tmp.cleanup(allocator);
    for (files) |file| try tmp.writeFile(allocator, file[0], file[1]);

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    return run(allocator, "handler.ts");
}

test "narrow reads a secret leak that passes through a relative import" {
    var result = try narrowIn(testing.allocator, "narrow-import-leak", &.{
        .{
            "handler.ts",
            \\import { env } from "zttp:env";
            \\import { wrap } from "./utils.ts";
            \\
            \\function handler(req: Request): Response {
            \\  const secret = env("SECRET_KEY");
            \\  if (secret !== undefined) {
            \\    return Response.json({ leaked: wrap(secret) });
            \\  }
            \\  return Response.json({ ok: true });
            \\}
            \\
        },
        .{
            "utils.ts",
            \\export structural Wrapped = string;
            \\
            \\export function wrap(value: string): Wrapped {
            \\  return [value, "!"].join("");
            \\}
            \\
        },
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.llm_text, "\"property\":\"no_secret_leakage\""));
}

test "narrow on a file with no handler keeps its error" {
    var result = try narrowIn(testing.allocator, "narrow-no-handler", &.{.{
        "handler.ts",
        \\const x = 1;
        \\
    }});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqualStrings("zts_expert_narrow: no handler function found in file\n", result.llm_text);
}

test "narrow stops at a type error and returns the production diagnostic" {
    var result = try narrowIn(testing.allocator, "narrow-type-error", &.{.{
        "handler.ts",
        \\function handler(req: Request): Response {
        \\  const n: number = "a";
        \\  return Response.json({ n: n });
        \\}
        \\
    }});
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expectEqualStrings("{\"path\":\"handler.ts\",\"diagnostics\":[{\"id\":\"diag_001\",\"code\":\"ZTS200\",\"severity\":\"error\",\"line\":2,\"column\":3,\"message\":\"type '\\\"a\\\"' is not assignable to type 'number'\"}],\"witnesses\":[]}", result.llm_text);
}
