//! zts_expert_fill_hole - spend a turn on exactly one hole.
//!
//! `zts_expert_query` operation `holes` publishes the frame around each `hole()`, and the persona
//! asks the agent to fill one per turn. Asking is not the mechanism. A turn that
//! hands back a whole file is emitting from the model's full distribution no
//! matter what the instruction said, and the veto is left to reject whatever
//! came out - which is the subtractive loop holes exist to replace.
//!
//! This tool is the enforcement. Its input is one expression and one hole's
//! coordinates, and the edit it produces replaces the bytes of that `hole()`
//! call and nothing else. There is no argument that could make it touch a
//! second line, so "one hole per turn" stops being an instruction the model can
//! decline and becomes the shape of the only edit it can make.
//!
//! That is the structural half of convergence: with a whole file in play the
//! emittable set is every program the model might write, and the fence rejects.
//! Here the compiler has already fixed the program apart from one expression in
//! a known context, so the emittable set per step is the set of expressions of
//! one type over a known set of bindings. The set shrinks because the frame
//! shrinks, not because the model got better.
//!
//! The tool never writes. It returns the proposed content and the veto verdict,
//! the same contract `zts_expert_ast_rewrite` has, so the agent decides whether
//! to commit.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const edit_simulate = zts_cli.edit_simulate;
const registry_mod = @import("../registry/registry.zig");
const ui_payload = @import("../ui_payload.zig");
const common = @import("common.zig");
const repair_apply = @import("repair_apply.zig");

const writeJsonString = zts.writeJsonString;

const name = "zts_expert_fill_hole";

/// The exact source text of a hole. `hole()` is a builtin taking no arguments,
/// so the call site is these six bytes and the match can be exact rather than a
/// scan for a name followed by a paren.
const hole_call = "hole()";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "fill hole",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Replace one `hole()` with one expression and report the compiler's
    \\verdict. Takes the `line` and `column` from a `zts_expert_query` holes entry
    \\and the expression to put there.
    \\
    \\This is the only edit the tool can make: the bytes of that `hole()` call
    \\are replaced and nothing else in the file moves. Use it instead of
    \\rewriting the file - the frame from query operation `holes` (expectedType,
    \\inScope, remainingBudget, undischarged) is the whole specification of the
    \\expression, and a file rewrite throws that away.
    \\
    \\The tool never writes. It returns `proposed_content` and the veto
    \\verdict; commit it yourself when `ok` is true. When `ok` is false the
    \\expression is wrong, not the file - ask for the frame again and write a
    \\different expression at the same site.
    ,
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer","minimum":1},"column":{"type":"integer","minimum":1},"expression":{"type":"string","description":"The expression to put where the hole is. No trailing semicolon: a hole sits in expression position."}},"required":["path","line","column","expression"]}
    ,
    .decode_json = registry_mod.helpers.decodeJsonPassthrough,
    .execute = execute,
};

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) return registry_mod.ToolResult.err(allocator, name ++ ": requires a JSON input argument\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{}) catch {
        return registry_mod.ToolResult.err(allocator, name ++ ": invalid JSON input\n");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return registry_mod.ToolResult.err(allocator, name ++ ": expected JSON object\n");
    const obj = parsed.value.object;

    const path_value = obj.get("path") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"path\"\n");
    const line_value = obj.get("line") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"line\"\n");
    const column_value = obj.get("column") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"column\"\n");
    const expression_value = obj.get("expression") orelse return registry_mod.ToolResult.err(allocator, name ++ ": missing \"expression\"\n");
    if (path_value != .string or line_value != .integer or column_value != .integer or expression_value != .string) {
        return registry_mod.ToolResult.err(allocator, name ++ ": \"path\" and \"expression\" must be strings, \"line\" and \"column\" must be integers\n");
    }
    if (line_value.integer < 1 or line_value.integer > std.math.maxInt(u32) or
        column_value.integer < 1 or column_value.integer > std.math.maxInt(u32))
    {
        return registry_mod.ToolResult.err(allocator, name ++ ": \"line\" or \"column\" out of range\n");
    }

    const path = path_value.string;
    const line: u32 = @intCast(line_value.integer);
    const column: u32 = @intCast(column_value.integer);
    const expression = std.mem.trim(u8, expression_value.string, " \t\r\n");

    if (repair_apply.pathEscapesWorkspace(path)) {
        return registry_mod.ToolResult.err(allocator, name ++ ": path escapes workspace\n");
    }
    if (expression.len == 0) {
        return try refusal(allocator, path, line, column, "empty_expression", "a hole must be filled with an expression; an empty one would leave the call site malformed");
    }

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);

    // At the ordinary tool limit: the source budget is enforced by
    // `holeReplacementFitsOutput` below, which answers with a structured
    // refusal naming the reason. Enforcing it on the read instead produced a
    // bare `FileTooBig` and made that refusal's own first clause unreachable.
    const source = zts.file_io.readFile(allocator, absolute, common.default_output_limit) catch |e| {
        return registry_mod.ToolResult.errFmt(allocator, name ++ ": failed to read {s}: {s}\n", .{ path, @errorName(e) });
    };
    defer allocator.free(source);

    if (!common.holeReplacementFitsOutput(source.len, expression.len)) {
        return try refusal(
            allocator,
            path,
            line,
            column,
            "proposed_content_too_large",
            "the replacement would exceed the full proposed-content result limit; use a smaller expression",
        );
    }

    const offset = holeOffsetAt(source, line, column) orelse {
        return try refusal(
            allocator,
            path,
            line,
            column,
            "no_hole_at_site",
            "no `hole()` starts at that line and column; re-run zts_expert_query operation holes, because a fill earlier in the turn moves every later hole's coordinates",
        );
    };

    const proposed = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        source[0..offset],
        expression,
        source[offset + hole_call.len ..],
    });
    defer allocator.free(proposed);

    var verdict = try edit_simulate.simulate(allocator, .{
        .file = absolute,
        .content = proposed,
        .before = source,
    });
    defer verdict.deinit(allocator);

    return try buildResult(allocator, .{
        .path = path,
        .line = line,
        .column = column,
        .expression = expression,
        .proposed = proposed,
        .verdict = &verdict,
    });
}

/// Byte offset of the `hole()` call that starts at 1-based `line`/`column`, or
/// null when those coordinates do not name one.
///
/// Exact rather than nearest-match on purpose. A stale coordinate is the
/// expected failure in this loop - filling one hole shifts every hole after it
/// on the same line, and lengthens or shortens nothing else - and the useful
/// answer to a stale coordinate is a refusal that says "re-read the frame",
/// not a splice at whatever hole happened to be closest.
fn holeOffsetAt(source: []const u8, line: u32, column: u32) ?usize {
    var current: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (current < line and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            current += 1;
            line_start = i + 1;
        }
    }
    if (current != line) return null;

    const offset = line_start + (@as(usize, column) - 1);
    if (offset + hole_call.len > source.len) return null;
    if (!std.mem.eql(u8, source[offset .. offset + hole_call.len], hole_call)) return null;
    return offset;
}

const BuildArgs = struct {
    path: []const u8,
    line: u32,
    column: u32,
    expression: []const u8,
    proposed: []const u8,
    verdict: *const edit_simulate.SimulateResult,
};

fn buildResult(allocator: std.mem.Allocator, args: BuildArgs) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();

    const ok = args.verdict.new_count == 0;
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (ok) "true" else "false");
    try w.writeAll(",\"applied\":false,\"path\":");
    try writeJsonString(w, args.path);
    try w.print(",\"line\":{d},\"column\":{d},\"expression\":", .{ args.line, args.column });
    try writeJsonString(w, args.expression);
    try w.writeAll(",\"proposed_content\":");
    try writeJsonString(w, args.proposed);
    try w.writeAll(",\"verification\":");
    try edit_simulate.writeResultJson(w, args.verdict);
    try w.writeAll("}\n");

    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);
    if (llm_text.len > common.max_hole_tool_result_bytes) {
        allocator.free(llm_text);
        return refusal(
            allocator,
            args.path,
            args.line,
            args.column,
            "proposed_content_too_large",
            "the complete verified proposal exceeds the tool-result limit; use a smaller expression or handler",
        );
    }

    const summary = try std.fmt.allocPrint(
        allocator,
        "{d} total, {d} new, {d} preexisting",
        .{ args.verdict.total, args.verdict.new_count, args.verdict.preexisting_count },
    );
    defer allocator.free(summary);

    const plan_id = try std.fmt.allocPrint(allocator, "hole_{d}_{d}", .{ args.line, args.column });
    defer allocator.free(plan_id);

    var payload: ui_payload.UiPayload = .{ .repair_candidate = try ui_payload.RepairCandidatePayload.init(
        allocator,
        args.path,
        plan_id,
        "fill_hole",
        args.proposed,
        ok,
        summary,
        .{
            .total = args.verdict.total,
            .new = args.verdict.new_count,
            .preexisting = args.verdict.preexisting_count,
        },
    ) };
    errdefer payload.deinit(allocator);

    return .{ .ok = ok, .llm_text = llm_text, .ui_payload = payload };
}

/// A refusal the agent can act on: it names which precondition failed rather
/// than reporting a generic error, because the two failures have different
/// fixes (write an expression, versus re-read the frame).
fn refusal(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: u32,
    column: u32,
    reason: []const u8,
    message: []const u8,
) !registry_mod.ToolResult {
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();
    try w.writeAll("{\"ok\":false,\"applied\":false,\"path\":");
    try writeJsonString(w, path);
    try w.print(",\"line\":{d},\"column\":{d},\"reason\":", .{ line, column });
    try writeJsonString(w, reason);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, message);
    try w.writeAll("}\n");
    return .{ .ok = false, .llm_text = try text_buf.toOwnedSlice() };
}

const testing = std.testing;

test "holeOffsetAt finds the call at its reported coordinates" {
    const source =
        \\function handler(req) {
        \\  return hole();
        \\}
    ;
    // `  return hole();` - `hole()` starts at column 10.
    const offset = holeOffsetAt(source, 2, 10).?;
    try testing.expectEqualStrings("hole()", source[offset .. offset + 6]);
}

test "holeOffsetAt refuses a coordinate that does not name a hole" {
    const source =
        \\function handler(req) {
        \\  return hole();
        \\}
    ;
    // One byte off is not a near miss to be corrected; it is a stale frame.
    try testing.expect(holeOffsetAt(source, 2, 9) == null);
    try testing.expect(holeOffsetAt(source, 1, 10) == null);
    try testing.expect(holeOffsetAt(source, 9, 1) == null);
}

test "holeOffsetAt picks the named hole when a line carries two" {
    const source = "const pair = [hole(), hole()];";
    const first = holeOffsetAt(source, 1, 15).?;
    const second = holeOffsetAt(source, 1, 23).?;
    try testing.expect(first != second);
    try testing.expectEqualStrings("hole()", source[first .. first + 6]);
    try testing.expectEqualStrings("hole()", source[second .. second + 6]);
}

test "fill uses the publisher's shared proposed-content boundary" {
    const source_len = common.max_hole_handler_source_bytes;
    const allowed = common.maxHoleExpressionBytes(source_len);
    try testing.expect(common.holeReplacementFitsOutput(source_len, allowed));
    try testing.expect(!common.holeReplacementFitsOutput(source_len, allowed + 1));
}

test "execute fills the named hole and leaves the rest of the file alone" {
    const source =
        \\function slug(s: string): string {
        \\  return hole();
        \\}
        \\
        \\function handler(req: Request): Response {
        \\  return Response.json({ slug: slug("x") });
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.sub_path, source);
    defer testing.allocator.free(path);

    // `  return hole();` - column 10.
    const input = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"path\":\"{s}\",\"line\":2,\"column\":10,\"expression\":\"s\"}}",
        .{path},
    );
    defer testing.allocator.free(input);
    var result = try execute(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, result.llm_text, "return s;") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "hole()") == null);
    // The other function is untouched: the edit is the hole's bytes and no
    // others, which is the whole claim this tool makes.
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "Response.json({ slug: slug(\\\"x\\\") })") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"applied\":false") != null);
}

test "execute refuses a coordinate that no longer names a hole" {
    // The expected failure in this loop: filling one hole moves every later
    // hole on the same line, so a second fill against stale coordinates must
    // refuse rather than splice at whatever is nearest.
    const source =
        \\function handler(req: Request): Response {
        \\  return Response.json({ ok: true });
        \\}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.sub_path, source);
    defer testing.allocator.free(path);

    const input = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"path\":\"{s}\",\"line\":2,\"column\":10,\"expression\":\"s\"}}",
        .{path},
    );
    defer testing.allocator.free(input);
    var result = try execute(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "no_hole_at_site") != null);
}

test "execute refuses an empty expression" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(tmp.sub_path, "function handler(req: Request): Response { return hole(); }");
    defer testing.allocator.free(path);

    const input = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"path\":\"{s}\",\"line\":1,\"column\":50,\"expression\":\"   \"}}",
        .{path},
    );
    defer testing.allocator.free(input);
    var result = try execute(testing.allocator, &.{input});
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "empty_expression") != null);
}

fn writeFixture(tmp_sub_path: anytype, source: []const u8) ![]u8 {
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp_sub_path});
    defer testing.allocator.free(root);
    const rel_path = try std.fs.path.join(testing.allocator, &.{ root, "handler.ts" });
    defer testing.allocator.free(rel_path);
    try zts.file_io.writeFile(testing.allocator, rel_path, source);
    return try testing.allocator.dupe(u8, rel_path);
}

test "the description tells the agent not to rewrite the file" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "nothing else in the file moves") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "never writes") != null);
}
