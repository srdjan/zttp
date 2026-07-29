//! `module-spec-render` — write or check the generated module spec JSON.
//!
//! The Zig bindings are authoritative; `packages/modules/module-specs/*.json`
//! is generated from them. This mirrors the `spec-render` / `spec-render
//! --check` pair for the semantics registry, with one difference: there are 24
//! documents rather than one, so `--check` reports EVERY stale path before
//! exiting. A gate that names one file when four are stale costs a full cycle
//! per file.

const std = @import("std");
const zts = @import("zts");

const file_io = zts.file_io;
const builtin_modules = zts.builtin_modules;
const render = zts.module_spec_render;

fn isHelpToken(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

fn writeOut(s: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, s.ptr, s.len);
}

fn writeErr(s: []const u8) void {
    _ = std.c.write(std.c.STDERR_FILENO, s.ptr, s.len);
}

/// The documentation mirror and its managed region. Only the Module Catalog
/// table is generated; the rest of that file is prose no binding contains.
const readme_path = "docs/virtual-modules/README.md";
const begin_marker = "<!-- BEGIN GENERATED: module catalog. Edit the Zig bindings, then run `zttp module-spec-render`. -->\n";
const end_marker = "<!-- END GENERATED: module catalog -->";

const Region = struct { before: []const u8, body: []const u8, after: []const u8 };

/// Split the README around its managed region. A missing marker is an error,
/// not a silent skip: the generator must never write a file whose boundary it
/// could not find.
fn splitRegion(doc: []const u8) !Region {
    const begin = std.mem.indexOf(u8, doc, begin_marker) orelse return error.MissingBeginMarker;
    const body_start = begin + begin_marker.len;
    const end = std.mem.indexOfPos(u8, doc, body_start, end_marker) orelse return error.MissingEndMarker;
    return .{
        .before = doc[0..body_start],
        .body = doc[body_start..end],
        .after = doc[end..],
    };
}

pub fn runModuleSpecRenderCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var check_mode = false;
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            writeOut(
                \\module-spec-render [--check] [--json]
                \\
                \\Generate packages/modules/module-specs/*.json and the Module Catalog
                \\table in docs/virtual-modules/README.md from the typed Zig module
                \\bindings. With --check, compare instead of writing and exit non-zero
                \\if any artifact is stale.
                \\
            );
            return;
        } else {
            return error.InvalidArgument;
        }
    }

    const allocator = std.heap.smp_allocator;

    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(allocator);
    var written: usize = 0;

    for (builtin_modules.builtins, builtin_modules.builtin_governance_entries) |binding, gov| {
        const rendered = try render.renderModuleSpec(allocator, binding, gov.module_path);
        defer allocator.free(rendered);

        if (check_mode) {
            // An unreadable file is stale, not a skip. A gate that passes
            // silently when its input is missing is worse than no gate.
            const existing = file_io.readFile(allocator, gov.spec_path, 1 << 20) catch {
                try stale.append(allocator, gov.spec_path);
                continue;
            };
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, rendered)) {
                try stale.append(allocator, gov.spec_path);
            }
        } else {
            try file_io.writeFile(allocator, gov.spec_path, rendered);
            written += 1;
        }
    }

    // The documentation mirror: same data, same generator, one gate step.
    {
        const table = try render.renderModuleCatalogTable(allocator, &builtin_modules.builtins);
        defer allocator.free(table);

        const doc = try file_io.readFile(allocator, readme_path, 1 << 20);
        defer allocator.free(doc);
        const region = splitRegion(doc) catch {
            // A clean message, not a stack trace: the operator needs to know a
            // marker is gone, and the generator must never guess at a boundary
            // it could not find.
            writeErr("module-spec-render: cannot find the generated region markers in " ++ readme_path ++ "\n");
            std.process.exit(2);
        };

        if (check_mode) {
            if (!std.mem.eql(u8, region.body, table)) try stale.append(allocator, readme_path);
        } else {
            var next: std.ArrayList(u8) = .empty;
            defer next.deinit(allocator);
            try next.appendSlice(allocator, region.before);
            try next.appendSlice(allocator, table);
            try next.appendSlice(allocator, region.after);
            try file_io.writeFile(allocator, readme_path, next.items);
            written += 1;
        }
    }

    if (!check_mode) {
        const line = try std.fmt.allocPrint(allocator, "module-spec-render: wrote {d} artifacts\n", .{written});
        defer allocator.free(line);
        writeOut(line);
        return;
    }

    if (stale.items.len == 0) {
        if (json_mode) {
            writeOut("{\"inSync\":true,\"stale\":[]}\n");
        } else {
            writeOut("module-spec-render --check: all generated module artifacts are in sync\n");
        }
        return;
    }

    if (json_mode) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"inSync\":false,\"stale\":[");
        for (stale.items, 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, p);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "]}\n");
        writeOut(buf.items);
    } else {
        writeErr("module-spec-render --check: these generated module artifacts are stale:\n");
        for (stale.items) |p| {
            writeErr("  ");
            writeErr(p);
            writeErr("\n");
        }
        writeErr("run `zts module-spec-render` to regenerate them\n");
    }
    std.process.exit(1);
}
