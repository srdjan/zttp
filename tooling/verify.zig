//! Run the canonical gate sequentially, retaining separate build processes.
const std = @import("std");
const routes = @import("verification_routes.zig");

pub fn main(init: std.process.Init) !void {
    try routes.validate(&routes.routes);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const single_release = args.len == 4 and std.mem.eql(u8, args[2], "--release-route");
    if (!single_release and (args.len < 2 or args.len > 3 or
        (args.len == 3 and !std.mem.eql(u8, args[2], "--release"))))
        std.process.fatal("usage: verify ZIG [--release | --release-route TASK]", .{});
    const release = args.len == 3 or single_release;
    var executed: usize = 0;
    for (routes.routes) |route| {
        if (single_release) {
            if (!route.release_pipeline) continue;
            if (!std.mem.eql(u8, routes.buildTask(route.argv) orelse continue, args[3])) continue;
        } else if (route.release_pipeline) continue;
        if (route.release_only and !release) continue;
        executed += 1;
        if (route.expert_metadata) {
            try checkExpertMetadata(init.arena.allocator(), init.io);
            continue;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(init.arena.allocator(), route.argv);
        if (argv.items.len > 0 and std.mem.eql(u8, argv.items[0], "zig")) argv.items[0] = args[1];
        // Pool-heavy test roots must remain separate processes. Limit the
        // aggregate's scheduling on macOS to preserve teardown isolation.
        if (@import("builtin").target.os.tag == .macos and std.mem.eql(u8, route.argv[route.argv.len - 1], "test"))
            try argv.append(init.arena.allocator(), "-j1");
        std.debug.print("\n>> {s}\n", .{route.label});
        var child = try std.process.spawn(init.io, .{ .argv = argv.items });
        const term = try child.wait(init.io);
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

fn checkExpertMetadata(allocator: std.mem.Allocator, io: std.Io) !void {
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "policy-hash.txt", allocator, .limited(128));
    const hash = try std.process.run(allocator, io, .{ .argv = &.{ "./zig-out/bin/zts", "describe-rule", "--hash" } });
    if (hash.term != .exited or hash.term.exited != 0 or
        !std.mem.eql(u8, std.mem.trim(u8, hash.stdout, "\r\n"), std.mem.trim(u8, expected, "\r\n")))
        return error.PolicyHashMismatch;
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "./zig-out/bin/zts", "meta", "--json" } });
    if (result.term != .exited or result.term.exited != 0) return error.MetadataCommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    const object = if (parsed.value == .object) parsed.value.object else return error.InvalidMetadata;
    const count = object.get("rule_count") orelse return error.InvalidMetadata;
    const policy = object.get("policy_hash") orelse return error.InvalidMetadata;
    if (count != .integer or count.integer < 25 or policy != .string or policy.string.len != 64)
        return error.InvalidMetadata;
    std.debug.print("policy hash and expert metadata OK\n", .{});
}
