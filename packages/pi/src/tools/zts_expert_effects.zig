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

    var prepared = zts.PreparedSource.init(allocator, source, path, .{}) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": TypeScript strip failed: {s}\n",
            .{@errorName(e)},
        );
    };
    defer prepared.deinit();

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.init(allocator, prepared.parserInput());
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

    // A type env populated from the strip pass lets the report show each
    // function's declared `Effects<...>` ceiling next to the inferred row,
    // so the expert can surface declared-vs-inferred drift.
    var type_pool = zts.TypePool.init(allocator);
    defer type_pool.deinit(allocator);
    try type_pool.ensureHealthy();
    var type_env = zts.TypeEnv.init(allocator, &type_pool);
    defer type_env.deinit();
    try type_pool.ensureHealthy();
    if (prepared.typeMap()) |type_map| try type_env.populateFromTypeMap(type_map);
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
        if (ctx.ir_view.signatureOffset(fe.decl_node)) |offset| {
            if (ctx.env.getFnSigAt(offset)) |sig| {
                const extraction = try ctx.env.extractEffectMembers(sig.return_type, &declared);
                declared_unreadable = extraction.non_literal;
            }
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
