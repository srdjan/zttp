//! zts_expert_effects - report the inferred effect row for every named
//! function in a source file.
//!
//! Bottom-up effect inference extends the proof boundary across helpers.
//! Each named function gets capabilities, determinism, purity, recursion,
//! and egress flags. The expert calls this before proposing edits so it
//! can warn the user when an edit widens a helper's effect row.

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const name = "zts_expert_effects";

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

    common.admitToolSource(allocator, source, path) catch |e| {
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
    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
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

    var analyzer = zts.EffectAnalyzer.init(allocator, ir_view, &atoms);
    defer analyzer.deinit();
    analyzer.analyze(program_root) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": analyze failed: {s}\n",
            .{@errorName(e)},
        );
    };

    var type_pool = zts.TypePool.init(allocator);
    defer type_pool.deinit(allocator);
    try type_pool.ensureHealthy();
    var type_env = zts.TypeEnv.init(allocator, &type_pool);
    defer type_env.deinit();
    try type_pool.ensureHealthy();
    try type_env.populateSourceTypes(.{ .direct = .{
        .store = &js_parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });
    try type_pool.ensureHealthy();

    const ctx: WriteContext = .{ .allocator = allocator, .env = &type_env, .ir_view = ir_view };
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    try writeEnvelope(text_buf.writer(), ctx, path, analyzer.all());

    return .{
        .ok = true,
        .llm_text = try text_buf.toOwnedSlice(),
    };
}

/// What `writeFunction` needs to resolve a function's declared `Effects<...>`
/// ceiling: the type env (return-type lookup), the IR view (declaration
/// line), and an allocator for the transient member list.
const WriteContext = struct {
    allocator: std.mem.Allocator,
    env: *const zts.TypeEnv,
    ir_view: zts.IrView,
};

fn writeEnvelope(
    writer: *std.Io.Writer,
    ctx: WriteContext,
    path: []const u8,
    functions: []const zts.FunctionEffect,
) !void {
    try writer.writeAll("{\"path\":\"");
    try writer.writeAll(path);
    try writer.writeAll("\",\"functions\":[");
    for (functions, 0..) |fe, i| {
        if (i > 0) try writer.writeByte(',');
        try writeFunction(writer, ctx, fe);
    }
    try writer.writeAll("]}");
}

fn writeFunction(
    writer: *std.Io.Writer,
    ctx: WriteContext,
    fe: zts.FunctionEffect,
) !void {
    try writer.writeAll("{\"name\":\"");
    try writer.writeAll(fe.name);
    try writer.writeAll("\",\"pure\":");
    try writer.writeAll(if (fe.row.pure) "true" else "false");
    try writer.writeAll(",\"deterministic\":");
    try writer.writeAll(if (fe.row.deterministic) "true" else "false");
    try writer.writeAll(",\"recursive\":");
    try writer.writeAll(if (fe.row.recursive) "true" else "false");
    try writer.writeAll(",\"has_egress\":");
    try writer.writeAll(if (fe.row.has_egress) "true" else "false");
    try writer.writeAll(",\"capabilities\":[");
    var first = true;
    var it = fe.row.capabilities.iterator();
    while (it.next()) |cap| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeByte('"');
        try writer.writeAll(@tagName(cap));
        try writer.writeByte('"');
    }
    // An empty `declared` array means the function carries no `Effects<...>`,
    // unless `declaredUnreadable` is true - then an annotation is present and
    // this could not read it. The agent must not treat the two as the same.
    try writer.writeAll("],\"declared\":[");
    var declared_unreadable = false;
    {
        var declared: std.ArrayListUnmanaged([]const u8) = .empty;
        defer declared.deinit(ctx.allocator);
        const signature = signature: {
            const owner = switch (ctx.ir_view.getTag(fe.decl_node) orelse break :signature null) {
                .function_decl => (ctx.ir_view.getVarDecl(fe.decl_node) orelse break :signature null).init,
                .function_expr, .arrow_function => fe.decl_node,
                else => break :signature null,
            };
            const reference = ctx.env.functionTypeRef(ctx.ir_view, owner) orelse break :signature null;
            break :signature ctx.env.getFunctionSignature(reference);
        };
        if (signature) |sig| {
            const extraction = try ctx.env.extractEffectMembers(sig.return_type, &declared);
            declared_unreadable = extraction.non_literal;
        }
        for (declared.items, 0..) |capname, j| {
            if (j > 0) try writer.writeByte(',');
            try writer.writeByte('"');
            try writer.writeAll(capname);
            try writer.writeByte('"');
        }
    }
    try writer.writeAll("],\"declaredUnreadable\":");
    try writer.writeAll(if (declared_unreadable) "true" else "false");
    try writer.writeAll("}");
}

test "effect reports retain declared ceilings and unreadable markers" {
    const cases = [_]struct { source: []const u8, functions: []const u8 }{
        .{ .source = "export function handler(req: Request): Effects<Response, \"env\" | \"clock\"> { return Response.text(\"ok\"); }", .functions = "[{\"name\":\"handler\",\"pure\":true,\"deterministic\":true,\"recursive\":false,\"has_egress\":false,\"capabilities\":[],\"declared\":[\"env\",\"clock\"],\"declaredUnreadable\":false}]" },
        .{ .source = "export function handler(req: Request): Effects<Response, string> { return Response.text(\"ok\"); }", .functions = "[{\"name\":\"handler\",\"pure\":true,\"deterministic\":true,\"recursive\":false,\"has_egress\":false,\"capabilities\":[],\"declared\":[],\"declaredUnreadable\":true}]" },
    };
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = case.source });
        const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, "handler.ts", std.testing.allocator);
        defer std.testing.allocator.free(path);
        var result = try run(std.testing.allocator, path);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.ok);
        const expected = try std.mem.concat(std.testing.allocator, u8, &.{ "{\"path\":\"", path, "\",\"functions\":", case.functions, "}" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result.llm_text);
    }
}
