//! Agent protocol command line entry: `runWithArgs` and its help text.

const std = @import("std");
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const edit_simulate = @import("edit_simulate.zig");
const dispatch_mod = @import("agent_protocol_dispatch.zig");
const handleRequest = dispatch_mod.handleRequest;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var stdin_json = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--stdin-json")) {
            stdin_json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "help"))
        {
            try printHelp();
            return;
        } else {
            return error.InvalidArgument;
        }
    }
    if (!stdin_json) {
        try printHelp();
        return error.InvalidArgument;
    }

    const request = try edit_simulate.readAllStdin(allocator);
    defer allocator.free(request);

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try handleRequest(allocator, io_backend.io(), request, &out.writer);

    const bytes = out.writer.buffered();
    if (bytes.len > 0) try writeAllFd(std.c.STDOUT_FILENO, bytes);
}

fn printHelp() !void {
    const help =
        \\zts agent - the version-2 agent protocol over stdin/stdout
        \\
        \\Usage: zts agent --stdin-json
        \\
        \\Reads one request object from stdin and writes one response object to
        \\stdout. Logs go to stderr. Exit status is 0 whenever a response was
        \\written, including a response carrying a protocol error.
        \\
        \\Request:
        \\  {"schema_version":2,"operation":"meta","project_root":"/abs/path",
        \\   "input":{},"expected":{"policy_hash":"..."}}
        \\
        \\Send `meta` first: its payload publishes the operation set, the
        \\identity hashes, and the payload sections this compiler does not yet
        \\generate.
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}
