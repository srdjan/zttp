//! zts_expert_ratchet - report the proven-property set for a handler.
//!
//! Mirrors `zttp ratchet show` from the expert side. The compiler already
//! infers every handler's property set and writes it to contract.json under
//! `provenSpecs`. The expert uses this tool to surface the current proven
//! set so a `/ratchet` or `/tighten` prompt can anchor in compiler facts
//! instead of LLM speculation. Cross-build deltas are derived from the
//! handler's own `Proof<T, P>` declarations. There is no baseline file to
//! pass, so this tool intentionally exposes only the `path` field; the
//! delta belongs to the corresponding CLI surface (`zttp ratchet check`).

const std = @import("std");
const zts = @import("zts");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");

const HandlerProperties = zts.HandlerProperties;

const name = "zts_expert_ratchet";

pub fn run(
    allocator: std.mem.Allocator,
    path: []const u8,
) anyerror!registry_mod.ToolResult {
    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);

    const source = zts.file_io.readFile(allocator, absolute, common.default_output_limit) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": cannot read {s}: {s}\n",
            .{ path, @errorName(e) },
        );
    };
    defer allocator.free(source);

    const precompile = @import("zts_cli").precompile;
    var compiled = precompile.compileHandler(allocator, source, path, .{
        .emit_contract = true,
        .emit_verify = true,
    }) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": compile failed: {s}\n",
            .{@errorName(e)},
        );
    };
    defer compiled.deinit(allocator);

    const contract = compiled.contract orelse {
        return registry_mod.ToolResult.err(allocator, name ++ ": no contract emitted\n");
    };
    const props = contract.properties orelse {
        return registry_mod.ToolResult.err(allocator, name ++ ": no properties emitted\n");
    };

    var buf: [HandlerProperties.max_proven_specs]?[]const u8 = undefined;
    const count = props.provenSpecNames(&buf);

    var out = registry_mod.helpers.TextBuffer.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"path\":\"");
    try w.writeAll(path);
    try w.writeAll("\",\"provenSpecs\":[");
    var emitted: usize = 0;
    for (buf[0..count]) |name_opt| {
        if (name_opt) |nm| {
            if (emitted > 0) try w.writeByte(',');
            emitted += 1;
            try w.writeByte('"');
            try w.writeAll(nm);
            try w.writeByte('"');
        }
    }
    try w.writeAll("]}");

    return .{ .ok = true, .llm_text = try out.toOwnedSlice() };
}
