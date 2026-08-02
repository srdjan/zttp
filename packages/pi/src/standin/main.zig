//! Development entrypoint for the deterministic playbook server.

const std = @import("std");
const builtin = @import("builtin");
const server_mod = @import("server.zig");

const usage =
    \\Usage: zig build zttp-standin -- [--port PORT]
    \\
    \\Serve the deterministic add-route playbook on loopback.
    \\The default port is ephemeral.
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (builtin.mode == .Debug) debug_alloc.allocator() else std.heap.smp_allocator;

    const port = try parsePort(init.args);
    var server = try server_mod.Server.init(allocator, port, null);
    defer server.deinit();
    std.debug.print("zttp-standin port={d}\n", .{server.port});
    try server.serve();
}

fn parsePort(args: std.process.Args) !u16 {
    var iterator = std.process.Args.Iterator.init(args);
    defer iterator.deinit();
    _ = iterator.next();
    var port: u16 = 0;
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        }
        if (!std.mem.eql(u8, arg, "--port")) {
            std.debug.print("Unknown argument: {s}\n{s}", .{ arg, usage });
            return error.InvalidArgument;
        }
        const value = iterator.next() orelse return error.MissingPort;
        port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    }
    return port;
}
