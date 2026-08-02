//! Deterministic add-route authoring and OpenAI Responses SSE rendering.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const expert_workflow = @import("../expert_workflow.zig");
const request = @import("request.zig");

pub const version = "step-4a-v1";
pub const protocol = "openai-responses-sse";

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
    if (hint.kind != .route_add) return renderMiss(allocator, parsed.ask);

    const spec = try parseRouteIntent(allocator, parsed.ask);
    defer deinitRouteSpec(allocator, spec);

    return switch (parsed.step_index) {
        0 => blk: {
            const args = try renderReadArgs(allocator, spec.file);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 0, "workspace_read_file", args);
        },
        1 => try renderToolCall(allocator, 1, "zts_expert_modules", "{}"),
        2 => blk: {
            const handler_name = try routeHandlerName(allocator, spec.method, spec.path);
            defer allocator.free(handler_name);
            const proposed = try synthesizeRoute(allocator, parsed.source, spec, handler_name);
            defer allocator.free(proposed);
            const args = try renderApplyArgs(allocator, spec.file, proposed, parsed.source);
            defer allocator.free(args);
            break :blk try renderToolCall(allocator, 2, "apply_edit", args);
        },
        else => try renderText(
            allocator,
            "The deterministic add-route playbook is complete. No further step is available.",
        ),
    };
}

pub fn renderMiss(allocator: std.mem.Allocator, ask: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(
        allocator,
        "[standin-miss] The deterministic playbook server understood the ask as: \"{s}\". " ++
            "This step supports add-route only. Use a hosted model, or point " ++
            "ZTS_OPENAI_BASE_URL at a real local model.",
        .{ask},
    );
    defer allocator.free(text);
    return renderText(allocator, text);
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
    var words = std.mem.tokenizeAny(u8, ask, " \t\r\n`\"'(),;");
    while (words.next()) |word| {
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
    const open = std.mem.indexOfScalarPos(u8, source, start, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) {
                    var end = i + 1;
                    if (end < source.len and source[end] == '\n') end += 1;
                    const out = try allocator.alloc(u8, source.len - (end - start));
                    errdefer allocator.free(out);
                    @memcpy(out[0..start], source[0..start]);
                    @memcpy(out[start .. start + source.len - end], source[end..]);
                    return out;
                }
            },
            else => {},
        }
    }
    return null;
}

fn renderReadArgs(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("{\"path\":");
    try writeJsonString(buf.writer(), file);
    try buf.writer().writeByte('}');
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
        .step_index = 2,
        .source = "function handler(req: Request): Response { return Response.json({ old: true }); }\n",
    };
    const body = try renderResponse(testing.allocator, parsed);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "event: response.function_call_arguments.delta") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"apply_edit\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "data: [DONE]") != null);
}
