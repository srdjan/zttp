//! Run the canonical gate sequentially, retaining separate build processes.
//! Each route appends one line to `.zttp/gate-ledger.jsonl`: the record of
//! which gates fail and how long each takes.
const std = @import("std");
const routes = @import("verification_routes.zig");

const ledger_dir = ".zttp";
const ledger_path = ".zttp/gate-ledger.jsonl";

pub fn main(init: std.process.Init) !void {
    try routes.validate(&routes.routes);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const single_release = args.len == 4 and std.mem.eql(u8, args[2], "--release-route");
    if (!single_release and (args.len < 2 or args.len > 3 or
        (args.len == 3 and !std.mem.eql(u8, args[2], "--release"))))
        std.process.fatal("usage: verify ZIG [--release | --release-route TASK]", .{});
    const release = args.len == 3 or single_release;
    const commit = describeCommit(init);
    var executed: usize = 0;
    for (routes.routes) |route| {
        if (single_release) {
            if (!route.release_pipeline) continue;
            if (!std.mem.eql(u8, routes.buildTask(route.argv) orelse continue, args[3])) continue;
        } else if (route.release_pipeline) continue;
        if (route.release_only and !release) continue;
        executed += 1;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(init.arena.allocator(), route.argv);
        if (argv.items.len > 0 and std.mem.eql(u8, argv.items[0], "zig")) argv.items[0] = args[1];
        // Pool-heavy test roots must remain separate processes. Limit the
        // aggregate's scheduling on macOS to preserve teardown isolation.
        if (@import("builtin").target.os.tag == .macos and std.mem.eql(u8, route.argv[route.argv.len - 1], "test"))
            try argv.append(init.arena.allocator(), "-j1");
        std.debug.print("\n>> {s}\n", .{route.label});
        const started = std.Io.Clock.Timestamp.now(init.io, .awake);
        var child = try std.process.spawn(init.io, .{ .argv = argv.items });
        const term = try child.wait(init.io);
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake));
        appendLedgerLine(init, commit, route.label, term, elapsed.raw.toMilliseconds()) catch |err|
            std.debug.print("verify: gate ledger line not written: {s}\n", .{@errorName(err)});
        switch (term) {
            .exited => |code| if (code != 0) std.process.exit(code),
            else => std.process.fatal("verification command terminated: {s}", .{route.label}),
        }
    }
    if (executed == 0) std.process.fatal("no verification route selected", .{});
    if (single_release) {
        std.debug.print("\nverify.sh: selected route {s} passed\n", .{args[3]});
        return;
    }
    std.debug.print("\nverify.sh: all {s}gates passed\n", .{if (release) "per-commit and release " else "per-commit "});
}

/// The commit under test, with a `-dirty` suffix when the tree has changes.
fn describeCommit(init: std.process.Init) []const u8 {
    const result = std.process.run(init.arena.allocator(), init.io, .{
        .argv = &.{ "git", "describe", "--always", "--dirty", "--abbrev=40", "--exclude=*" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(4096),
    }) catch return "unknown";
    return switch (result.term) {
        .exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \t\r\n") else "unknown",
        else => "unknown",
    };
}

fn appendLedgerLine(
    init: std.process.Init,
    commit: []const u8,
    label: []const u8,
    term: std.process.Child.Term,
    ms: i64,
) !void {
    const io = init.io;
    var line: std.Io.Writer.Allocating = .init(init.arena.allocator());
    var json: std.json.Stringify = .{ .writer = &line.writer };
    try json.beginObject();
    try json.objectField("time");
    try json.write(std.Io.Clock.real.now(io).toSeconds());
    try json.objectField("commit");
    try json.write(commit);
    try json.objectField("route");
    try json.write(label);
    try json.objectField("exit");
    switch (term) {
        .exited => |code| try json.write(code),
        else => try json.write(null),
    }
    try json.objectField("ms");
    try json.write(ms);
    try json.endObject();
    try line.writer.writeByte('\n');

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ledger_dir);
    var file = try cwd.createFile(io, ledger_path, .{ .truncate = false });
    defer file.close(io);
    try file.writePositionalAll(io, line.written(), try file.length(io));
}
