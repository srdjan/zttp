//! Development entrypoint for the deterministic playbook server.

const std = @import("std");
const builtin = @import("builtin");
const range = @import("range.zig");
const server_mod = @import("server.zig");

const usage =
    \\Usage: zig build zttp-standin -- [--port PORT | --range]
    \\
    \\Serve the deterministic playbooks on loopback, or print their range.
    \\The default port is ephemeral.
    \\
;

pub const Command = union(enum) {
    serve: u16,
    range,
    help,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (builtin.mode == .Debug) debug_alloc.allocator() else std.heap.smp_allocator;

    const command = try parseProcessArgs(allocator, init.args);
    switch (command) {
        .range => {
            const document = try range.renderDocument(allocator);
            defer allocator.free(document);
            try writeStdout(document);
        },
        .help => try writeStderr(usage),
        .serve => |port| {
            var server = try server_mod.Server.init(allocator, port, null);
            defer server.deinit();
            std.debug.print("zttp-standin port={d}\n", .{server.port});
            try server.serve();
        },
    }
}

fn parseProcessArgs(allocator: std.mem.Allocator, process_args: std.process.Args) !Command {
    var iterator = std.process.Args.Iterator.init(process_args);
    defer iterator.deinit();
    _ = iterator.next();

    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    while (iterator.next()) |arg| try args.append(allocator, arg);

    const command = parseCommandArgs(args.items) catch |err| {
        if (err == error.InvalidArgument) {
            const unknown = findUnknownArgument(args.items) orelse return err;
            std.debug.print("Unknown argument: {s}\n{s}", .{ unknown, usage });
        }
        return err;
    };
    args.deinit(allocator);
    return command;
}

pub fn parseCommandArgs(args: []const []const u8) !Command {
    var port: ?u16 = null;
    var range_requested = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            if (port != null or range_requested) return error.InvalidArgumentCombination;
            if (index + 1 != args.len) return error.InvalidArgumentCombination;
            return .help;
        }
        if (std.mem.eql(u8, arg, "--range")) {
            if (port != null or range_requested) return error.InvalidArgumentCombination;
            range_requested = true;
            continue;
        }
        if (!std.mem.eql(u8, arg, "--port")) {
            return error.InvalidArgument;
        }
        if (range_requested or port != null) return error.InvalidArgumentCombination;
        index += 1;
        const value = if (index < args.len) args[index] else return error.MissingPort;
        port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    }
    if (range_requested) return .range;
    return .{ .serve = port orelse 0 };
}

fn findUnknownArgument(args: []const []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            continue;
        }
        if (!std.mem.eql(u8, arg, "--help") and
            !std.mem.eql(u8, arg, "-h") and
            !std.mem.eql(u8, arg, "--range")) return arg;
    }
    return null;
}

fn writeStdout(text: []const u8) !void {
    try writeFile(std.c.STDOUT_FILENO, text);
}

fn writeStderr(text: []const u8) !void {
    try writeFile(std.c.STDERR_FILENO, text);
}

fn writeFile(file_descriptor: c_int, text: []const u8) !void {
    var remaining = text;
    while (remaining.len > 0) {
        const result = std.c.write(file_descriptor, remaining.ptr, remaining.len);
        if (result < 0) {
            if (std.posix.errno(result) == .INTR) continue;
            return error.OutputWriteFailed;
        }
        const written: usize = @intCast(result);
        if (written == 0) return error.OutputWriteFailed;
        remaining = remaining[written..];
    }
}
