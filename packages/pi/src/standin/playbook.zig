//! Deterministic task playbooks and OpenAI Responses SSE rendering.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const expert_workflow = @import("../expert_workflow.zig");
const defect_seeds = @import("defect_seeds.zig");
const range = @import("range.zig");
const request = @import("request.zig");

pub const version = range.version;
pub const protocol = "openai-responses-sse";

pub const kinds = [_]expert_workflow.TaskKind{
    .route_add,
    .review_explain,
    .env_feature,
    .test_generation,
    .violation_fix,
};

pub const RouteSpec = struct {
    file: []const u8,
    method: []const u8,
    path: []const u8,
    body_schema: ?[]const u8 = null,
    response_schema: ?[]const u8 = null,
    status: u16 = 200,
};

pub fn renderResponse(
    allocator: std.mem.Allocator,
    parsed: request.ParsedRequest,
) ![]u8 {
    const hint = expert_workflow.classify(parsed.ask);
    if (!range.hasKind(hint.kind)) return renderMiss(allocator, parsed.ask);

    return switch (hint.kind) {
        .route_add => renderRouteAdd(allocator, parsed),
        .review_explain => renderReviewExplain(allocator, parsed),
        .env_feature => renderEnvFeature(allocator, parsed),
        .test_generation => renderTestGeneration(allocator, parsed),
        .violation_fix => renderViolationFix(allocator, parsed),
        else => renderMiss(allocator, parsed.ask),
    };
}

pub fn hasPlaybook(kind: expert_workflow.TaskKind) bool {
    for (kinds) |candidate| {
        if (candidate == kind) return true;
    }
    return false;
}

fn renderRouteAdd(allocator: std.mem.Allocator, parsed: request.ParsedRequest) ![]u8 {
    const spec = try parseRouteIntent(allocator, parsed.ask);
    defer deinitRouteSpec(allocator, spec);

    return switch (parsed.step_index) {
        0 => blk: {
            const args = try renderReadArgs(allocator, spec.file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "workspace_read_file", args);
        },
        1 => blk: {
            const args = try renderVerifyPathsArgs(allocator, spec.file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 1, "zts_expert_verify_paths", args);
        },
        2 => try renderToolCall(allocator, 2, "zts_expert_modules", "{}"),
        // Steps 3 and 4 are the pre-apply proof this migration's own persona
        // rewrite made mandatory: "Author the COMPLETE file content yourself.
        // Dry-run the draft with `zts_expert_edit_simulate` and resolve every
        // new violation. Submit exactly one `apply_edit` call." The playbook
        // went straight from facts to apply, so the offline path demonstrated
        // the behavior the hosted path is measured for not doing. Both steps
        // send identical bytes, so the simulate verdict is about the draft that
        // actually lands.
        3, 4 => blk: {
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "add-route");
            const handler_name = try routeHandlerName(allocator, spec.method, spec.path);
            defer allocator.free(handler_name);
            const proposed = try synthesizeRoute(allocator, source, spec, handler_name);
            defer allocator.free(proposed);
            const args = try renderApplyArgs(allocator, spec.file, proposed, source);
            defer allocator.free(args);
            const tool = if (parsed.step_index == 3) "zts_expert_edit_simulate" else "apply_edit";
            break :blk try renderToolCall(allocator, parsed.step_index, tool, args);
        },
        else => try renderText(
            allocator,
            "The deterministic add-route playbook is complete. No further step is available.",
        ),
    };
}

pub fn renderMiss(allocator: std.mem.Allocator, ask: []const u8) ![]u8 {
    var text = TextBuffer.init(allocator);
    defer text.deinit();
    const writer = text.writer();
    try writer.print(
        "[standin-miss] The deterministic playbook server understood the ask as: \"{s}\". " ++
            "The supported range is ",
        .{ask},
    );
    for (range.entries, 0..) |entry, index| {
        if (index > 0) {
            if (index + 1 == range.entries.len) {
                try writer.writeAll(", and ");
            } else {
                try writer.writeAll(", ");
            }
        }
        try writer.writeAll(entry.id);
    }
    try writer.writeAll(
        ". Run `zig build zttp-standin -- --range` to inspect it. " ++
            "Use a hosted model, or point ZTS_OPENAI_BASE_URL at a real local model.",
    );
    const owned = try text.toOwnedSlice();
    defer allocator.free(owned);
    return renderText(allocator, owned);
}

fn renderReviewExplain(allocator: std.mem.Allocator, parsed: request.ParsedRequest) ![]u8 {
    const is_review = if (range.findByPrompt(parsed.ask)) |entry|
        std.mem.eql(u8, entry.id, "review")
    else
        containsFold(parsed.ask, "review");
    return switch (parsed.step_index) {
        0 => if (is_review) blk: {
            const args = try renderReadArgs(allocator, findFile(parsed.ask) orelse "handler.ts");
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "workspace_read_file", args);
        } else try renderToolCall(allocator, 0, "zts_expert_modules", "{}"),
        else => if (is_review)
            // Review answers in text and applies no edit, so an unreadable
            // file costs an answer rather than a file.
            renderReviewText(allocator, parsed.source orelse "")
        else
            renderText(
                allocator,
                "The deterministic playbook server used the live module facts. In ZigTS, `Response.json(value)` creates a JSON response. A handler must return a Response on every path. Example: `function handler(req: Request): Response { return Response.json({ ok: true }); }`.",
            ),
    };
}

fn renderReviewText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var text = TextBuffer.init(allocator);
    defer text.deinit();
    const writer = text.writer();
    try writer.writeAll("The deterministic playbook server inspected the supplied handler source. ");
    if (std.mem.indexOf(u8, source, "function handler(") != null) {
        try writer.writeAll("Visible observation: it contains a `function handler` declaration. ");
    } else {
        try writer.writeAll("Visible observation: it does not contain a `function handler` declaration. ");
    }

    if (hasUncheckedResultValue(source)) {
        try writer.writeAll(
            "Visible observation: `result.value` follows `validateJson` with a missing visible `result.ok` guard. " ++
                "Add a guard before that value read. ",
        );
    } else if (std.mem.indexOf(u8, source, "if (!result.ok)") != null) {
        try writer.writeAll("Visible observation: the source contains a `result.ok` guard. ");
    } else {
        try writer.writeAll("Visible observation: this limited review found no unchecked `result.value` read after `validateJson`. ");
    }
    try writer.writeAll(
        "This deterministic review did not run the compiler and makes no compiler verdict. " ++
            "Run `zttp check handler.ts` for diagnostics and the proof record before you change the handler.",
    );
    const owned = try text.toOwnedSlice();
    defer allocator.free(owned);
    return renderText(allocator, owned);
}

fn renderEnvFeature(allocator: std.mem.Allocator, parsed: request.ParsedRequest) ![]u8 {
    const file = findFile(parsed.ask) orelse "handler.ts";
    return switch (parsed.step_index) {
        0 => try renderToolCall(allocator, 0, "zts_expert_modules", "{}"),
        1 => blk: {
            const args = try renderReadArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 1, "workspace_read_file", args);
        },
        2 => blk: {
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "add-env");
            const variable = findEnvName(parsed.ask) orelse "APP_NAME";
            const transform = try synthesizeEnvFeature(allocator, source, variable);
            break :blk switch (transform) {
                .edit => |proposed| blk_edit: {
                    defer allocator.free(proposed);
                    const args = try renderApplyArgs(allocator, file, proposed, source);
                    defer allocator.free(args);
                    break :blk_edit try renderToolCall(allocator, 2, "apply_edit", args);
                },
                .unsupported_handler => renderSourceMiss(
                    allocator,
                    "environment",
                    "the supplied source has no supported `function handler` body",
                ),
                .conflicting_env_import => renderSourceMiss(
                    allocator,
                    "environment",
                    "the supplied source has a conflicting `zttp:env` import",
                ),
                .existing_read => renderSourceMiss(
                    allocator,
                    "environment",
                    "the supplied source already reads the requested environment variable",
                ),
            };
        },
        else => try renderText(
            allocator,
            "The deterministic environment playbook is complete. No further step is available.",
        ),
    };
}

fn renderTestGeneration(allocator: std.mem.Allocator, parsed: request.ParsedRequest) ![]u8 {
    const handler_file = findFile(parsed.ask) orelse "handler.ts";
    const test_file = findJsonlFile(parsed.ask) orelse "handler.test.jsonl";
    return switch (parsed.step_index) {
        0 => blk: {
            const args = try renderReadArgs(allocator, handler_file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "workspace_read_file", args);
        },
        1 => blk: {
            const args = try renderVerifyPathsArgs(allocator, handler_file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 1, "zts_expert_verify_paths", args);
        },
        2 => blk: {
            const args = try renderReadArgs(allocator, test_file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 2, "workspace_read_file", args);
        },
        3 => blk: {
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "write-test");
            const proposed = try synthesizeTestFile(allocator, source);
            defer allocator.free(proposed);
            const args = try renderApplyArgs(allocator, test_file, proposed, source);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 3, "apply_edit", args);
        },
        else => try renderText(
            allocator,
            "The deterministic test-generation playbook is complete. No further step is available.",
        ),
    };
}

/// The seeded arm: submit a draft the veto is meant to reject, then repair it.
///
/// Steps 0 through 2 are the ordinary facts-first sequence, so the arm differs
/// from the plain fix playbook only in what it submits. Step 3 is the defect.
/// Step 4 exists solely for the rejection path, and is guarded on
/// `rejected_drafts` rather than on the step index: a salvaged draft also
/// advances the index by one, having been normalized and applied, and repairing
/// an edit that already landed would overwrite it.
///
/// The source must be the seed's own bytes. Without that check an ask naming a
/// seeded code would make the stand-in fire a scripted defect at whatever file
/// happened to be open, which is the same class of mistake as authoring from an
/// empty baseline.
fn renderSeededViolationFix(
    allocator: std.mem.Allocator,
    parsed: request.ParsedRequest,
    seed: *const defect_seeds.DefectSeed,
    file: []const u8,
) ![]u8 {
    return switch (parsed.step_index) {
        0 => blk: {
            const args = try renderVerifyPathsArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "zts_expert_verify_paths", args);
        },
        1 => blk: {
            const args = try renderReadArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 1, "pi_repair_plan", args);
        },
        2 => blk: {
            const args = try renderReadArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 2, "workspace_read_file", args);
        },
        3 => blk: {
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "fix");
            if (!std.mem.eql(u8, source, seed.seed_source)) {
                break :blk try renderSourceMiss(
                    allocator,
                    "violation-fix",
                    "the ask names a seeded diagnostic but the file is not that seed's source",
                );
            }
            const args = try renderApplyArgs(allocator, file, seed.bad_draft, source);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 3, "apply_edit", args);
        },
        4 => blk: {
            if (parsed.rejected_drafts == 0) {
                break :blk try renderText(
                    allocator,
                    "The seeded draft was not rejected, so there is nothing to repair.",
                );
            }
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "fix");
            // The rejected bytes were never written, so the baseline is still
            // the seed source the read recovered.
            const args = try renderApplyArgs(allocator, file, seed.good_draft, source);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 4, "apply_edit", args);
        },
        else => try renderText(
            allocator,
            "The seeded violation-fix arm is complete. No further step is available.",
        ),
    };
}

fn renderViolationFix(allocator: std.mem.Allocator, parsed: request.ParsedRequest) ![]u8 {
    const file = findFile(parsed.ask) orelse "handler.ts";
    if (defect_seeds.findByAsk(parsed.ask)) |seed| {
        return renderSeededViolationFix(allocator, parsed, seed, file);
    }
    return switch (parsed.step_index) {
        0 => blk: {
            const args = try renderVerifyPathsArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "zts_expert_verify_paths", args);
        },
        1 => blk: {
            const args = try renderReadArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 1, "pi_repair_plan", args);
        },
        2 => blk: {
            const args = try renderReadArgs(allocator, file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 2, "workspace_read_file", args);
        },
        3 => blk: {
            const source = parsed.source orelse break :blk try renderUnreadableSource(allocator, "fix");
            const transform = try synthesizeViolationFix(allocator, source);
            break :blk switch (transform) {
                .edit => |proposed| blk_edit: {
                    defer allocator.free(proposed);
                    const args = try renderApplyArgs(allocator, file, proposed, source);
                    defer allocator.free(args);
                    break :blk_edit try renderToolCall(allocator, 3, "apply_edit", args);
                },
                .unsupported_seed => renderSourceMiss(
                    allocator,
                    "violation-fix",
                    "the supplied source does not contain the supported unchecked validateJson result shape",
                ),
                .already_guarded => renderSourceMiss(
                    allocator,
                    "violation-fix",
                    "the supplied source already has a visible `result.ok` guard",
                ),
            };
        },
        else => try renderText(
            allocator,
            "The deterministic violation-fix playbook is complete. No further step is available.",
        ),
    };
}

const EnvTransform = union(enum) {
    edit: []u8,
    unsupported_handler,
    conflicting_env_import,
    existing_read,
};

fn synthesizeEnvFeature(
    allocator: std.mem.Allocator,
    source: []const u8,
    variable: []const u8,
) !EnvTransform {
    const handler_open = findHandlerBodyOpen(source) orelse return .unsupported_handler;
    const env_import = "import { env } from \"zttp:env\";";
    const has_env_import = std.mem.indexOf(u8, source, env_import) != null;
    if (hasConflictingEnvImport(source, env_import)) {
        return .conflicting_env_import;
    }

    const read_marker = try std.fmt.allocPrint(allocator, "env(\"{s}\")", .{variable});
    defer allocator.free(read_marker);
    if (std.mem.indexOf(u8, source, read_marker) != null) return .existing_read;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (!has_env_import) {
        try out.appendSlice(allocator, env_import);
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, source[0 .. handler_open + 1]);
    try out.print(allocator, "\n    env(\"{s}\");", .{variable});
    try out.appendSlice(allocator, source[handler_open + 1 ..]);
    return .{ .edit = try out.toOwnedSlice(allocator) };
}

fn synthesizeTestFile(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const test_case =
        \\{"type":"test","name":"GET /health returns 200"}
        \\{"type":"request","method":"GET","url":"/health","headers":{},"body":null}
        \\{"type":"expect","status":200,"bodyContains":"ok"}
        \\
    ;
    if (std.mem.indexOf(u8, source, "GET /health returns 200") != null) {
        return allocator.dupe(u8, source);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, source);
    if (source.len > 0 and source[source.len - 1] != '\n') try out.append(allocator, '\n');
    if (source.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, test_case);
    return try out.toOwnedSlice(allocator);
}

const ViolationTransform = union(enum) {
    edit: []u8,
    unsupported_seed,
    already_guarded,
};

fn synthesizeViolationFix(allocator: std.mem.Allocator, source: []const u8) !ViolationTransform {
    const result_marker = "const result = validateJson(\"item\", req.body);";
    const result_start = std.mem.indexOf(u8, source, result_marker) orelse return .unsupported_seed;
    const data_marker = "const data = result.value;";
    const data_start = std.mem.indexOfPos(u8, source, result_start + result_marker.len, data_marker) orelse {
        return .unsupported_seed;
    };
    const guard_marker = "if (!result.ok)";
    if (std.mem.indexOfPos(u8, source, result_start + result_marker.len, guard_marker)) |guard_start| {
        if (guard_start < data_start) return .already_guarded;
    }

    const line_start = std.mem.lastIndexOfScalar(u8, source[0..data_start], '\n') orelse return .unsupported_seed;
    const indentation = source[line_start + 1 .. data_start];
    if (!isIndentation(indentation)) return .unsupported_seed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, source[0 .. line_start + 1]);
    try out.print(
        allocator,
        "{s}if (!result.ok) {{\n{s}    return Response.json({{ error: result.error }}, {{ status: 400 }});\n{s}}}\n",
        .{ indentation, indentation, indentation },
    );
    try out.appendSlice(allocator, source[line_start + 1 ..]);
    return .{ .edit = try out.toOwnedSlice(allocator) };
}

/// No read has produced usable bytes for the target file.
///
/// Refuse rather than author from "". `apply_edit` writes unconditionally -
/// `before` is a veto baseline, not a compare-and-swap - so a stub built from
/// nothing would replace whatever the user actually had, and an empty baseline
/// means the draft proves clean on the way out.
fn renderUnreadableSource(allocator: std.mem.Allocator, playbook_name: []const u8) ![]u8 {
    return renderSourceMiss(
        allocator,
        playbook_name,
        "the target file could not be read, because it is missing or larger than one tool result carries",
    );
}

fn renderSourceMiss(allocator: std.mem.Allocator, playbook_name: []const u8, reason: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(
        allocator,
        "[standin-miss] The deterministic {s} playbook did not apply an edit: {s}. " ++
            "Use a hosted model, or point ZTS_OPENAI_BASE_URL at a real local model.",
        .{ playbook_name, reason },
    );
    defer allocator.free(text);
    return renderText(allocator, text);
}

/// Index just past a run of source that must not be read as code: a quoted or
/// templated literal, or a comment. Returns null when `i` does not start one.
///
/// Every brace scan below needs this. Counting raw braces treats a `}` inside
/// `Response.json({ msg: "}" })` as a real close and cuts the handler at the
/// wrong byte.
fn skipNonCode(source: []const u8, i: usize) ?usize {
    switch (source[i]) {
        '"', '\'', '`' => {
            const quote = source[i];
            var j = i + 1;
            while (j < source.len) : (j += 1) {
                if (source[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (source[j] == quote) return j + 1;
            }
            return source.len;
        },
        '/' => {
            if (i + 1 >= source.len) return null;
            if (source[i + 1] == '/') {
                const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse return source.len;
                return nl;
            }
            if (source[i + 1] == '*') {
                const close = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return source.len;
                return close + 2;
            }
            return null;
        },
        else => return null,
    }
}

/// Index of the `}` matching the `{` at `open`, skipping literals and comments.
fn matchBrace(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < source.len) {
        if (skipNonCode(source, i)) |next| {
            i = next;
            continue;
        }
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// Index of the `{` that opens `function handler`'s body.
///
/// Two things sit between the name and the body and both can contain a brace.
/// The parameter list can be destructured (`function handler({ req }: Ctx)`),
/// which is why the scan starts after the matching `)` rather than at the first
/// `{`. The return annotation can be an object type
/// (`function handler(req: Request): { ok: boolean } {`), which is why a brace
/// whose match is followed by another brace is treated as the annotation and
/// skipped. Splicing into either produced source that was not valid.
fn findHandlerBodyOpen(source: []const u8) ?usize {
    const handler_start = std.mem.indexOf(u8, source, "function handler(") orelse return null;
    const paren_open = handler_start + "function handler".len;

    var depth: usize = 0;
    var i = paren_open;
    const paren_close = while (i < source.len) {
        if (skipNonCode(source, i)) |next| {
            i = next;
            continue;
        }
        switch (source[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break i;
            },
            else => {},
        }
        i += 1;
    } else return null;

    var candidate = blk: {
        var j = paren_close + 1;
        while (j < source.len) {
            if (skipNonCode(source, j)) |next| {
                j = next;
                continue;
            }
            if (source[j] == '{') break :blk j;
            j += 1;
        }
        return null;
    };

    // An object return type is a balanced brace group with the body's brace
    // after it. A plain return type such as `: Response` has no such group.
    if (matchBrace(source, candidate)) |close| {
        var k = close + 1;
        while (k < source.len and std.ascii.isWhitespace(source[k])) k += 1;
        if (k < source.len and source[k] == '{') candidate = k;
    }
    return candidate;
}

fn hasUncheckedResultValue(source: []const u8) bool {
    const result_marker = "const result = validateJson(";
    const result_start = std.mem.indexOf(u8, source, result_marker) orelse return false;
    const data_marker = "const data = result.value;";
    const data_start = std.mem.indexOfPos(u8, source, result_start + result_marker.len, data_marker) orelse return false;
    const guard_marker = "if (!result.ok)";
    if (std.mem.indexOfPos(u8, source, result_start + result_marker.len, guard_marker)) |guard_start| {
        return guard_start > data_start;
    }
    return true;
}

fn hasConflictingEnvImport(source: []const u8, allowed_import: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "import ") and
            std.mem.indexOf(u8, line, "zttp:env") != null and
            !std.mem.eql(u8, line, allowed_import))
        {
            return true;
        }
    }
    return false;
}

fn isIndentation(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != ' ' and byte != '\t') return false;
    }
    return true;
}

pub fn parseRouteIntent(allocator: std.mem.Allocator, ask: []const u8) !RouteSpec {
    const file = findFile(ask) orelse "handler.ts";
    const method = findMethod(ask) orelse "GET";
    const path = findPath(ask) orelse "/";
    const status = findKeyValue(ask, "status") orelse "200";

    const file_arg = try std.fmt.allocPrint(allocator, "file={s}", .{file});
    defer allocator.free(file_arg);
    const method_arg = try std.fmt.allocPrint(allocator, "method={s}", .{method});
    defer allocator.free(method_arg);
    const path_arg = try std.fmt.allocPrint(allocator, "path={s}", .{path});
    defer allocator.free(path_arg);
    const status_arg = try std.fmt.allocPrint(allocator, "status={s}", .{status});
    defer allocator.free(status_arg);

    return parseRouteSpecArgs(allocator, &.{ "route", file_arg, method_arg, path_arg, status_arg });
}

pub fn parseRouteSpecArgs(allocator: std.mem.Allocator, args: []const []const u8) !RouteSpec {
    if (args.len == 0) return error.InvalidRouteSpec;
    if (args.len == 1 and std.mem.indexOfScalar(u8, args[0], '{') != null) {
        return parseJsonSpec(allocator, args[0]);
    }
    return parseKvSpec(allocator, args);
}

fn parseJsonSpec(allocator: std.mem.Allocator, raw: []const u8) !RouteSpec {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRouteSpec,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRouteSpec;
    const obj = parsed.value.object;
    const kind = getString(obj, "kind") orelse return error.InvalidRouteSpec;
    if (!std.mem.eql(u8, kind, "route")) return error.InvalidRouteSpec;
    const status = if (obj.get("status")) |value| blk: {
        if (value != .integer or value.integer < 100 or value.integer > 599) return error.InvalidRouteSpec;
        break :blk @as(u16, @intCast(value.integer));
    } else 200;
    const file = try allocator.dupe(u8, getString(obj, "file") orelse return error.InvalidRouteSpec);
    errdefer allocator.free(file);
    const method = try allocator.dupe(u8, getString(obj, "method") orelse return error.InvalidRouteSpec);
    errdefer allocator.free(method);
    const path = try allocator.dupe(u8, getString(obj, "path") orelse return error.InvalidRouteSpec);
    errdefer allocator.free(path);
    const body_schema = if (getString(obj, "body_schema")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (body_schema) |value| allocator.free(value);
    const response_schema = if (getString(obj, "response_schema")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (response_schema) |value| allocator.free(value);
    const spec: RouteSpec = .{
        .file = file,
        .method = method,
        .path = path,
        .body_schema = body_schema,
        .response_schema = response_schema,
        .status = status,
    };
    if (!validRouteSpec(spec)) return error.InvalidRouteSpec;
    return spec;
}

fn parseKvSpec(allocator: std.mem.Allocator, args: []const []const u8) !RouteSpec {
    var file: ?[]u8 = null;
    errdefer if (file) |value| allocator.free(value);
    var method: ?[]u8 = null;
    errdefer if (method) |value| allocator.free(value);
    var path: ?[]u8 = null;
    errdefer if (path) |value| allocator.free(value);
    var body_schema: ?[]u8 = null;
    errdefer if (body_schema) |value| allocator.free(value);
    var response_schema: ?[]u8 = null;
    errdefer if (response_schema) |value| allocator.free(value);
    var status: u16 = 200;
    var start: usize = 0;
    if (std.mem.eql(u8, args[0], "route")) start = 1;
    for (args[start..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidRouteSpec;
        const key = arg[0..eq];
        const value = arg[eq + 1 ..];
        if (std.mem.eql(u8, key, "file")) {
            if (file != null) return error.InvalidRouteSpec;
            file = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "method")) {
            if (method != null) return error.InvalidRouteSpec;
            method = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "path")) {
            if (path != null) return error.InvalidRouteSpec;
            path = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "body") or std.mem.eql(u8, key, "body_schema")) {
            if (body_schema != null) return error.InvalidRouteSpec;
            body_schema = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "response") or std.mem.eql(u8, key, "response_schema")) {
            if (response_schema != null) return error.InvalidRouteSpec;
            response_schema = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "status")) {
            status = std.fmt.parseInt(u16, value, 10) catch return error.InvalidRouteSpec;
            if (status < 100 or status > 599) return error.InvalidRouteSpec;
        } else return error.InvalidRouteSpec;
    }
    const spec: RouteSpec = .{
        .file = file orelse return error.InvalidRouteSpec,
        .method = method orelse return error.InvalidRouteSpec,
        .path = path orelse return error.InvalidRouteSpec,
        .body_schema = body_schema,
        .response_schema = response_schema,
        .status = status,
    };
    if (!validRouteSpec(spec)) return error.InvalidRouteSpec;
    return spec;
}

fn deinitRouteSpec(allocator: std.mem.Allocator, spec: RouteSpec) void {
    if (spec.file.len > 0) allocator.free(spec.file);
    if (spec.method.len > 0) allocator.free(spec.method);
    if (spec.path.len > 0) allocator.free(spec.path);
    if (spec.body_schema) |value| allocator.free(value);
    if (spec.response_schema) |value| allocator.free(value);
}

fn validRouteSpec(spec: RouteSpec) bool {
    return spec.file.len > 0 and validMethod(spec.method) and spec.path.len > 0 and spec.path[0] == '/';
}

fn validMethod(method: []const u8) bool {
    const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    for (methods) |candidate| {
        if (std.ascii.eqlIgnoreCase(method, candidate)) return true;
    }
    return false;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn findFile(ask: []const u8) ?[]const u8 {
    if (findKeyValue(ask, "file")) |value| return value;
    // `.` cannot be a separator here because it is inside every filename, so a
    // name ending a sentence keeps its full stop and matched nothing. The
    // playbook then silently retargeted handler.ts, editing a file the user had
    // not named. Every other extractor already strips trailing punctuation.
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;");
    while (words.next()) |raw| {
        const word = std.mem.trimEnd(u8, raw, ".!?");
        if (std.mem.endsWith(u8, word, ".ts") or std.mem.endsWith(u8, word, ".tsx") or
            std.mem.endsWith(u8, word, ".js") or std.mem.endsWith(u8, word, ".jsx"))
        {
            return word;
        }
    }
    return null;
}

fn findMethod(ask: []const u8) ?[]const u8 {
    const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),.;:");
    while (words.next()) |word| {
        for (methods) |method| {
            if (std.ascii.eqlIgnoreCase(word, method)) return method;
        }
    }
    return null;
}

fn findPath(ask: []const u8) ?[]const u8 {
    if (findKeyValue(ask, "path")) |value| return value;
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;");
    while (words.next()) |word| {
        if (word.len == 0 or word[0] != '/') continue;
        return std.mem.trimEnd(u8, word, ".!?");
    }
    return null;
}

fn findKeyValue(ask: []const u8, key: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;");
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(word[0..eq], key)) continue;
        return std.mem.trimEnd(u8, word[eq + 1 ..], ".!?");
    }
    return null;
}

fn findJsonlFile(ask: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;");
    while (words.next()) |word| {
        if (std.mem.endsWith(u8, word, ".jsonl")) return std.mem.trimEnd(u8, word, ".!?");
    }
    return null;
}

/// The environment variable the ask names.
///
/// Taking the first ALL-CAPS token read a bare acronym rather than the
/// variable: "Read the API key from DATABASE_URL" answered API, and the
/// generated handler then read the wrong variable while still passing the
/// veto. An underscore is what actually distinguishes a variable name from an
/// acronym in these asks, so a token carrying one wins outright; without one,
/// the longest candidate beats a short acronym.
fn findEnvName(ask: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;:.");
    while (words.next()) |word| {
        if (word.len < 2 or !std.ascii.isUpper(word[0])) continue;
        var valid = true;
        for (word) |ch| {
            if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch) and ch != '_') {
                valid = false;
                break;
            }
        }
        if (!valid) continue;
        if (std.mem.indexOfScalar(u8, word, '_') != null) return word;
        if (best == null or word.len > best.?.len) best = word;
    }
    return best;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn routeHandlerName(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "handle");
    try appendPascalToken(allocator, &out, method);
    var it = std.mem.tokenizeAny(u8, path, "/-_:{}");
    while (it.next()) |part| try appendPascalToken(allocator, &out, part);
    if (out.items.len == "handle".len + method.len) try out.appendSlice(allocator, "Root");
    return try out.toOwnedSlice(allocator);
}

fn appendPascalToken(allocator: std.mem.Allocator, out: *std.ArrayList(u8), token: []const u8) !void {
    var upper_next = true;
    for (token) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) {
            upper_next = true;
            continue;
        }
        if (upper_next) {
            try out.append(allocator, std.ascii.toUpper(ch));
            upper_next = false;
        } else {
            try out.append(allocator, std.ascii.toLower(ch));
        }
    }
}

pub fn synthesizeRoute(
    allocator: std.mem.Allocator,
    source: []const u8,
    spec: RouteSpec,
    handler_name: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const has_router = std.mem.indexOf(u8, source, "zttp:router") != null;
    const has_routes = std.mem.indexOf(u8, source, "const routes = {") != null;
    const has_spec_import = std.mem.indexOf(u8, source, "from \"zttp:types\"") != null;
    const has_guardrails_alias = std.mem.indexOf(u8, source, "type Guardrails =") != null;

    if (!has_router) {
        if (!has_spec_import) try out.appendSlice(allocator, "import type { Spec } from \"zttp:types\";\n");
        try out.appendSlice(allocator, "import { routerMatch } from \"zttp:router\";\n");
    }
    if (spec.body_schema != null and std.mem.indexOf(u8, source, "zttp:validate") == null) {
        try out.appendSlice(allocator, "import { validateJson } from \"zttp:validate\";\n");
    }
    if (out.items.len > 0 and source.len > 0) try out.append(allocator, '\n');

    if (!has_router and !has_guardrails_alias) {
        try out.appendSlice(allocator,
            \\type Guardrails = Spec<
            \\    | "deterministic"
            \\    | "idempotent"
            \\    | "no_secret_leakage"
            \\    | "injection_safe"
            \\>;
            \\
            \\
        );
    }

    const stripped_handler: ?[]u8 = if (!has_router) try stripFunctionHandlerAlloc(allocator, source) else null;
    defer if (stripped_handler) |bytes| allocator.free(bytes);
    const source_without_handler = stripped_handler orelse source;

    if (has_routes) {
        try appendWithRouteEntry(allocator, &out, source_without_handler, spec, handler_name);
    } else {
        try out.appendSlice(allocator, source_without_handler);
        if (source_without_handler.len > 0 and source_without_handler[source_without_handler.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.append(allocator, '\n');
        try out.print(allocator, "const routes = {{\n    \"{s} {s}\": {s},\n}};\n\n", .{ spec.method, spec.path, handler_name });
    }

    if (!has_router) {
        try out.appendSlice(allocator,
            \\function handler(req: Request): Response & Guardrails {
            \\    const found = routerMatch(routes, req);
            \\    if (found !== undefined) {
            \\        req.params = found.params;
            \\        return found.handler(req);
            \\    }
            \\    return Response.json({ error: "not_found" }, { status: 404 });
            \\}
            \\
            \\
        );
    } else {
        try out.append(allocator, '\n');
    }
    try out.print(allocator, "function {s}(req: Request): Response {{\n", .{handler_name});
    if (spec.body_schema) |schema| {
        try out.print(
            allocator,
            "    const body = validateJson(\"{s}\", req.body);\n" ++
                "    if (!body.ok) return Response.json({{ errors: body.errors }}, {{ status: 400 }});\n" ++
                "    return Response.json({{ ok: true, data: body.value }}, {{ status: {d} }});\n",
            .{ schema, spec.status },
        );
    } else {
        try out.print(allocator, "    return Response.json({{ ok: true }}, {{ status: {d} }});\n", .{spec.status});
    }
    try out.appendSlice(allocator, "}\n");

    return try out.toOwnedSlice(allocator);
}

fn appendWithRouteEntry(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source: []const u8,
    spec: RouteSpec,
    handler_name: []const u8,
) !void {
    const marker = "const routes = {";
    const start = std.mem.indexOf(u8, source, marker) orelse {
        try out.appendSlice(allocator, source);
        return;
    };
    const close = std.mem.indexOfPos(u8, source, start + marker.len, "};") orelse {
        try out.appendSlice(allocator, source);
        return;
    };
    try out.appendSlice(allocator, source[0..close]);
    if (close > 0 and source[close - 1] != '\n') try out.append(allocator, '\n');
    try out.print(allocator, "    \"{s} {s}\": {s},\n", .{ spec.method, spec.path, handler_name });
    try out.appendSlice(allocator, source[close..]);
    if (source.len > 0 and source[source.len - 1] != '\n') try out.append(allocator, '\n');
}

fn stripFunctionHandlerAlloc(allocator: std.mem.Allocator, source: []const u8) !?[]u8 {
    const start = std.mem.indexOf(u8, source, "function handler(") orelse return null;
    // Shares findHandlerBodyOpen's parameter-list and return-type handling, and
    // matchBrace's literal awareness. Counting raw braces from the first `{`
    // closed early on a handler returning `Response.json({ msg: "}" })`.
    const open = findHandlerBodyOpen(source) orelse return null;
    const close = matchBrace(source, open) orelse return null;

    var end = close + 1;
    if (end < source.len and source[end] == '\n') end += 1;
    const out = try allocator.alloc(u8, source.len - (end - start));
    errdefer allocator.free(out);
    @memcpy(out[0..start], source[0..start]);
    @memcpy(out[start .. start + source.len - end], source[end..]);
    return out;
}

fn renderReadArgs(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"path\":");
    try writeJsonString(buf.writer(), file);
    try buf.writer().writeByte('}');
    return try buf.toOwnedSlice();
}

fn renderVerifyPathsArgs(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"paths\":[");
    try writeJsonString(buf.writer(), file);
    try buf.writer().writeAll("]}");
    return try buf.toOwnedSlice();
}

fn renderApplyArgs(
    allocator: std.mem.Allocator,
    file: []const u8,
    content: []const u8,
    before: []const u8,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writer.writeAll("{\"file\":");
    try writeJsonString(writer, file);
    try writer.writeAll(",\"content\":");
    try writeJsonString(writer, content);
    try writer.writeAll(",\"before\":");
    try writeJsonString(writer, before);
    try writer.writeByte('}');
    return try buf.toOwnedSlice();
}

fn renderToolCall(
    allocator: std.mem.Allocator,
    step_index: usize,
    name: []const u8,
    args: []const u8,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writer.print(
        "event: response.created\n" ++
            "data: {{\"type\":\"response.created\",\"response\":{{\"id\":\"standin-{d}\",\"object\":\"response\",\"status\":\"in_progress\",\"model\":\"deterministic-playbook\"}}}}\n\n",
        .{step_index},
    );
    try writer.print(
        "event: response.output_item.added\n" ++
            "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{{\"id\":\"standin-item-{d}\",\"type\":\"function_call\",\"call_id\":\"standin-call-{d}\",\"name\":",
        .{ step_index, step_index },
    );
    try writeJsonString(writer, name);
    try writer.writeAll(",\"arguments\":\"\"}}\n\n");
    try writer.writeAll("event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":");
    try writeJsonString(writer, args);
    try writer.writeAll("}\n\n");
    try writer.writeAll("event: response.function_call_arguments.done\ndata: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":");
    try writeJsonString(writer, args);
    try writer.writeAll("}\n\n");
    try writer.print(
        "event: response.output_item.done\n" ++
            "data: {{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"id\":\"standin-item-{d}\",\"type\":\"function_call\",\"call_id\":\"standin-call-{d}\",\"name\":",
        .{ step_index, step_index },
    );
    try writeJsonString(writer, name);
    try writer.writeAll(",\"arguments\":");
    try writeJsonString(writer, args);
    try writer.writeAll("}}\n\n");
    try writer.print(
        "event: response.completed\n" ++
            "data: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"standin-{d}\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"deterministic-playbook\",\"usage\":{{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}}}}\n\n" ++
            "data: [DONE]\n",
        .{step_index},
    );
    return try buf.toOwnedSlice();
}

fn renderText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writer.writeAll(
        "event: response.created\n" ++
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"standin-text\",\"object\":\"response\",\"status\":\"in_progress\",\"model\":\"deterministic-playbook\"}}\n\n" ++
            "event: response.output_item.added\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"standin-message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n" ++
            "event: response.content_part.added\n" ++
            "data: {\"type\":\"response.content_part.added\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
            "event: response.output_text.delta\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":",
    );
    try writeJsonString(writer, text);
    try writer.writeAll("}\n\n");
    try writer.writeAll("event: response.output_text.done\ndata: {\"type\":\"response.output_text.done\",\"output_index\":0,\"content_index\":0,\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}\n\n");
    try writer.writeAll("event: response.content_part.done\ndata: {\"type\":\"response.content_part.done\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}}\n\n");
    try writer.writeAll("event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"standin-message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}]}}\n\n");
    try writer.writeAll(
        "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"standin-text\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"deterministic-playbook\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n" ++
            "data: [DONE]\n",
    );
    return try buf.toOwnedSlice();
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{@as(u16, ch)}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

const testing = std.testing;

test "stand-in natural add-route ask becomes the historical structured route spec" {
    const spec = try parseRouteIntent(
        testing.allocator,
        "Create a handler in handler.ts that responds to GET /health with status=201.",
    );
    defer deinitRouteSpec(testing.allocator, spec);
    try testing.expectEqualStrings("handler.ts", spec.file);
    try testing.expectEqualStrings("GET", spec.method);
    try testing.expectEqualStrings("/health", spec.path);
    try testing.expectEqual(@as(u16, 201), spec.status);
}

test "stand-in add-route steps use tool cassette event names and apply_edit last" {
    const parsed: request.ParsedRequest = .{
        .ask = "Add a GET /health route to handler.ts",
        // The apply step; 3 is the mandated edit_simulate dry-run before it.
        .step_index = 4,
        .source = "function handler(req: Request): Response { return Response.json({ old: true }); }\n",
    };
    const body = try renderResponse(testing.allocator, parsed);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "event: response.function_call_arguments.delta") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"apply_edit\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "data: [DONE]") != null);
}

test "stand-in handler body scan skips destructured parameters and object return types" {
    // The first `{` here is a destructured parameter, not the body.
    const destructured = "function handler({ req }: Ctx): Response {\n    return Response.json({ ok: true });\n}\n";
    const destructured_open = findHandlerBodyOpen(destructured).?;
    try testing.expectEqual(@as(u8, '{'), destructured[destructured_open]);
    try testing.expect(std.mem.startsWith(u8, destructured[destructured_open..], "{\n    return"));

    // Here the first `{` after the parameter list opens the return type.
    const object_return = "function handler(req: Request): { ok: boolean } {\n    return { ok: true };\n}\n";
    const object_open = findHandlerBodyOpen(object_return).?;
    try testing.expect(std.mem.startsWith(u8, object_return[object_open..], "{\n    return"));
}

test "stand-in brace matching ignores braces inside literals and comments" {
    const source = "function handler(req: Request): Response {\n    // a } in a comment\n    return Response.json({ msg: \"}\" });\n}\n";
    const open = findHandlerBodyOpen(source).?;
    const close = matchBrace(source, open).?;
    // Raw counting closed at the brace inside the string literal and cut the
    // handler mid-body; the real close is the last byte before the newline.
    try testing.expectEqual(source.len - 2, close);

    const stripped = (try stripFunctionHandlerAlloc(testing.allocator, source)).?;
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings("", stripped);
}

test "stand-in ask extraction prefers the named variable and tolerates end-of-sentence files" {
    // A bare acronym must not beat the variable the user actually named.
    try testing.expectEqualStrings("DATABASE_URL", findEnvName("Read the API key from DATABASE_URL").?);
    try testing.expectEqualStrings("TIMEOUT", findEnvName("Read the TIMEOUT value").?);

    // A filename ending a sentence keeps its full stop through tokenizing.
    try testing.expectEqualStrings("api.ts", findFile("Add a GET /health route to api.ts.").?);
    try testing.expectEqualStrings("api.ts", findFile("Add a GET /health route to api.ts").?);
}
