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

pub fn run(
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror!registry_mod.ToolResult {
    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
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

pub fn renderFromSource(
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
    // Both paths come from one walk, which avoids duplicate manifest reads.
    var project_paths = try zts_cli.edit_simulate.discoverProjectPaths(allocator, source_path);
    defer project_paths.deinit(allocator);
    const sql_schema_path = project_paths.sqlite;
    // The analyzer's own failures are results, not Zig errors leaving the tool.
    // `MissingSqlSchema` used to escape `execute` and reach the autoloop as an
    // aborting error and the model as opaque text with no frames.
    var check = zts_cli.precompile.runCheckOnlyFromSourceWithOptions(
        allocator,
        source,
        relative,
        .{
            .sql_schema_path = sql_schema_path,
            .json_mode = true,
        },
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
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"holes\":[{") != null);
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
    const filler = &@as([400:0]u8, @splat('x'));
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
