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
                \\Generate packages/modules/module-specs/*.json from the typed Zig
                \\module bindings. With --check, compare instead of writing and exit
                \\non-zero if any file is stale.
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

    if (!check_mode) {
        const line = try std.fmt.allocPrint(allocator, "module-spec-render: wrote {d} module specs\n", .{written});
        defer allocator.free(line);
        writeOut(line);
        return;
    }

    if (stale.items.len == 0) {
        if (json_mode) {
            writeOut("{\"inSync\":true,\"stale\":[]}\n");
        } else {
            writeOut("module-spec-render --check: all module specs are in sync\n");
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
        writeErr("module-spec-render --check: these module specs are stale:\n");
        for (stale.items) |p| {
            writeErr("  ");
            writeErr(p);
            writeErr("\n");
        }
        writeErr("run `zts module-spec-render` to regenerate them\n");
    }
    std.process.exit(1);
}
