const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk_dep = b.dependency("zttp_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const sdk_mod = sdk_dep.module("zttp-sdk");

    // freestanding wasm (the browser playground analyzer) has no libc to link.
    const needs_libc = target.result.os.tag != .freestanding;

    _ = b.addModule("zttp-modules", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = needs_libc,
        .imports = &.{
            .{ .name = "zttp-sdk", .module = sdk_mod },
        },
    });
}
