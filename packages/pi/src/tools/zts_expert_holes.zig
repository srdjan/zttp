//! zts_expert_holes - report every `hole()` in a file, with the frame the
//! compiler already knows about each one.
//!
//! A hole is the compiler describing a program with one expression missing.
//! Filling it needs three facts: where the gap is, what type the expression
//! must produce, and what capability budget is still unspent. All three come
//! out of the contract already, and `zts_check` already carries them - buried
//! in a full proof envelope the agent has to search.
//!
//! Narrowing that to the gaps themselves is the point rather than a
//! convenience. A turn that regenerates a whole file emits from the model's
//! full distribution and lets the veto reject; a turn that fills one typed hole
//! in a known context is choosing one expression. The narrower the frame, the
//! smaller the emittable set - which is the mechanism, not a nicety.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");

const name = "zts_expert_holes";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "holes",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\List every `hole()` in a handler with the frame around it: the
    \\enclosing function, the line and column, the type the expression
    \\must produce, the bindings in scope with their types, the properties
    \\that function has not discharged, and the capability budget the
    \\handler declared but has not yet spent.
    \\
    \\`hole()` is typed `never`, so a program with holes still type-checks
    \\and still proves its properties - the compiler describes the frame
    \\and only the expression is missing. Reaching one at runtime answers
    \\501, not 500.
    \\
    \\Fill one hole per turn rather than regenerating the file. The frame
    \\is what narrows the expression: `inScope` is the material to build
    \\from, `expectedType` is what it must produce, `remainingBudget` is
    \\what it may spend, and `undischarged` is what it must not break. A
    \\binding typed "unknown" carries no annotation the compiler could
    \\read, so treat its type as open rather than assuming one. An empty
    \\list means the program has no holes left.
    ,
    .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    return registry_mod.helpers.decodeSingleStringField(allocator, args_json, "path");
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a path\n");

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, args[0]);
    defer allocator.free(absolute);
    const relative = common.relativeToRoot(root, absolute);

    // Read at the ordinary tool limit, not at the filler's source budget. That
    // budget bounds what the *filler* can echo back; enforcing it on the read
    // made a handler over ~15 KB fail with a bare `FileTooBig` and no way to
    // list a single hole in it, and it made the filler's own
    // `proposed_content_too_large` refusal unreachable, since the read had
    // already rejected every source the refusal was written for.
    const source = zts.file_io.readFile(allocator, absolute, common.default_output_limit) catch |err| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": failed to read {s}: {s}\n",
            .{ relative, @errorName(err) },
        );
    };
    defer allocator.free(source);
    return renderFromSource(allocator, source, absolute, relative);
}

fn renderFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: []const u8,
    relative: []const u8,
) !registry_mod.ToolResult {
    // This is the same analyzer and contract serializer `zts check --json`
    // uses, called as a library so it works in an isolated workspace that does
    // not contain the zttp build graph.
    // Discovered, not null. Hard-coding the schema null made
    // `validateSqlContract` return `MissingSqlSchema` for every handler
    // importing `zttp:sql`, and the error left the tool as a bare error string
    // - so the one hole the model asked about never came back with a frame.
    // Both paths come from one walk: resolving them separately walked the same
    // ancestors and parsed the same zttp.json twice per render.
    // `try`, not a swallow: this tool publishes an `ok` verdict, and a verdict
    // computed without the system manifest because zttp.json failed to read is
    // the fail-open class AGENTS.md documents.
    var project_paths = try zts_cli.edit_simulate.discoverProjectPaths(allocator, source_path);
    defer project_paths.deinit(allocator);
    const system_path = project_paths.system;
    const sql_schema_path = project_paths.sqlite;
    // The analyzer's own failures are results, not Zig errors leaving the tool.
    // `MissingSqlSchema` used to escape `execute` and reach the autoloop as an
    // aborting error and the model as opaque text with no frames.
    var check = zts_cli.precompile.runCheckOnlyFromSource(
        allocator,
        source,
        relative,
        sql_schema_path,
        true,
        system_path,
        false,
    ) catch |err| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": cannot analyze {s}: {s}\n",
            .{ relative, @errorName(err) },
        );
    };
    defer check.deinit(allocator);

    // Grown, not a fixed 32 KB frame. Overflow used to become
    // `error.StreamTooLong`, which escaped `execute` as a Zig error rather than
    // a ToolResult: the autoloop aborted the run and the model got opaque text
    // with no hole frames at all. The cap still applies, but it is applied to a
    // complete projection - and when the full one does not fit, the holes are
    // published without the diagnostics rather than nothing being published.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const ok = writeProjection(&aw.writer, relative, &check, true) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (aw.written().len <= common.max_hole_tool_result_bytes) {
        return .{
            .ok = ok,
            .llm_text = try allocator.dupe(u8, aw.written()),
        };
    }

    var trimmed: std.Io.Writer.Allocating = .init(allocator);
    defer trimmed.deinit();
    const trimmed_ok = writeProjection(&trimmed.writer, relative, &check, false) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (trimmed.written().len > common.max_hole_tool_result_bytes) {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": {s} has more holes than one result can carry ({d} bytes over the {d}-byte limit); split the file\n",
            .{ relative, trimmed.written().len - common.max_hole_tool_result_bytes, common.max_hole_tool_result_bytes },
        );
    }
    return .{
        .ok = trimmed_ok,
        .llm_text = try allocator.dupe(u8, trimmed.written()),
    };
}

/// `with_diagnostics` false writes the same projection without the diagnostic
/// array, which is the part that grows without bound. The holes and the `ok`
/// verdict are unchanged, so a caller that gets the trimmed form still learns
/// every gap and still learns the program did not check.
fn writeProjection(
    writer: *std.Io.Writer,
    relative: []const u8,
    check: *zts_cli.precompile.CheckResult,
    with_diagnostics: bool,
) std.Io.Writer.Error!bool {
    try writer.writeAll("{\"path\":");
    try zts.writeJsonString(writer, relative);

    if (check.contract) |*contract| {
        try writer.writeAll(",\"holes\":");
        try zts_cli.json_diagnostics.writeHolesJson(writer, contract.holes.items);
        if (check.totalErrors() > 0) {
            try writer.writeAll(",\"diagnostics\":[");
            if (with_diagnostics) try writeDiagnosticsJson(writer, check);
            try writer.writeAll("]}\n");
            return false;
        }
        try writer.writeAll("}\n");
        return true;
    }

    // No contract is different from a valid program with zero holes. Preserve
    // the structured diagnostics and report a failed tool result so callers do
    // not mistake analysis failure for completion.
    try writer.writeAll(",\"holes\":null,\"diagnostics\":[");
    if (with_diagnostics) try writeDiagnosticsJson(writer, check);
    try writer.writeAll("]}\n");
    return false;
}

fn writeDiagnosticsJson(
    writer: *std.Io.Writer,
    check: *const zts_cli.precompile.CheckResult,
) std.Io.Writer.Error!void {
    for (check.json_diagnostics.items, 0..) |*diagnostic, i| {
        if (i > 0) try writer.writeByte(',');
        try zts_cli.json_diagnostics.writeDiagnosticJson(writer, diagnostic);
    }
}

const testing = std.testing;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

test "in-process publisher returns the compiler hole frame" {
    const source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const total = 1;
        \\  return hole();
        \\}
    ;
    var result = try renderFromSource(testing.allocator, source, "handler.ts", "handler.ts");
    defer result.deinit(testing.allocator);

    try testing.expect(result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"holes\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"function\":\"handler\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"line\":3,\"column\":10") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"expectedType\":\"Response\"") != null);
}

test "in-process publisher distinguishes analysis failure from no holes" {
    var result = try renderFromSource(testing.allocator, "function handler(", "broken.ts", "broken.ts");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"holes\":null") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diagnostics\":[{") != null);
}

test "in-process publisher fails closed when a contract has verification errors" {
    const source =
        \\function handler(req: Request): Response {
        \\  return hole();
        \\}
    ;
    var result = try renderFromSource(testing.allocator, source, "handler.ts", "handler.ts");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"holes\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diagnostics\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "ZTS500") != null);
}

test "in-process publisher preserves discovered system service-call analysis" {
    var tmp = try IsolatedTmp.init(testing.allocator, "holes-system-context");
    defer tmp.cleanup(testing.allocator);

    try tmp.writeFile(testing.allocator, "zttp.json", "{\"system\":\"system.json\"}\n");
    try tmp.writeFile(testing.allocator, "system.json",
        \\{
        \\  "version": 1,
        \\  "handlers": [
        \\    { "name": "gateway", "path": "gateway.ts" },
        \\    { "name": "users", "path": "users.ts" }
        \\  ]
        \\}
    );
    try tmp.writeFile(testing.allocator, "users.ts",
        \\import { routerMatch } from "zttp:router";
        \\function getUser(req: Request): Response { return Response.json({ id: req.params.id }); }
        \\const routes = { "GET /users/:id": getUser };
        \\function handler(req: Request): Response {
        \\  const found = routerMatch(routes, req);
        \\  if (found !== undefined) { req.params = found.params; return found.handler(req); }
        \\  return Response.json({ error: "not found" }, { status: 404 });
        \\}
    );
    const gateway_source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const user = serviceCall("users", "GET /users/:id", {});
        \\  return hole();
        \\}
    ;
    try tmp.writeFile(testing.allocator, "gateway.ts", gateway_source);
    const gateway_path = try tmp.childPath(testing.allocator, "gateway.ts");
    defer testing.allocator.free(gateway_path);

    var result = try renderFromSource(testing.allocator, gateway_source, gateway_path, "gateway.ts");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "serviceCall is missing path param 'id'") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diagnostics\":[{") != null);
}

test "tool description names the three facts a fill needs" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "expected type") != null or
        std.mem.indexOf(u8, tool.description, "type the expression") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "budget") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "Fill one hole per turn") != null);
}

test "in-process publisher answers a zttp:sql handler with a result, not a Zig error" {
    // The publisher used to hard-code `sql_schema_path = null`, so
    // `validateSqlContract` returned `MissingSqlSchema`, and with no catch the
    // error left `execute` entirely: the autoloop aborted and the model got
    // opaque text with no hole frames. The path is discovered now, and a
    // failure that survives discovery is a ToolResult the caller can read.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function handler(req: Request): Response {
        \\  return hole();
        \\}
    ;
    var result = try renderFromSource(testing.allocator, source, "handler.ts", "handler.ts");
    defer result.deinit(testing.allocator);
    try testing.expect(result.llm_text.len > 0);
}

test "a projection too large for one result comes back trimmed, not as an error" {
    // The projection went into a fixed 32 KB buffer and overflow became
    // `error.StreamTooLong`, which escaped `execute` as a Zig error: the
    // autoloop aborted the run and the model got opaque text. Overflow now
    // drops the diagnostics - the unbounded part - and returns the frame.
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("function handler(req: Request): Response {\n");
    // Each line is one type mismatch whose message quotes the offending
    // literal, so enough of them overflow the result limit on the
    // diagnostics alone while staying under the local-variable ceiling.
    const filler = "x" ** 400;
    for (0..250) |i| {
        try source.writer.print("  const v{d}: number = \"{s}\";\n", .{ i, filler });
    }
    try source.writer.writeAll("  return hole();\n}\n");

    var result = try renderFromSource(testing.allocator, source.written(), "big.ts", "big.ts");
    defer result.deinit(testing.allocator);
    try testing.expect(result.llm_text.len <= common.max_hole_tool_result_bytes);
    // The empty array is what proves the overflow path ran: the full
    // projection for this source carries diagnostic objects here.
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"diagnostics\":[]") != null);
}
