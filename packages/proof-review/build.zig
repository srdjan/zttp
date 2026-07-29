const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const perf_histogram = b.option(bool, "perf_histogram", "Enable interpreter opcode histogram collection") orelse false;

    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram,
    });
    const zts_mod = zts_dep.module("zts");

    const tools_dep = b.dependency("zttp_tools", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram,
    });
    const zts_cli_mod = tools_dep.module("zts_cli");

    _ = b.addModule("zttp_proof_review", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zts", .module = zts_mod },
            .{ .name = "zts_cli", .module = zts_cli_mod },
        },
    });
}
