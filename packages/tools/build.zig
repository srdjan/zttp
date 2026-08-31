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

    // project_config module (shared between CLI tools and runtime)
    const project_config_mod = b.addModule("project_config", .{
        .root_source_file = b.path("src/project_config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    project_config_mod.addImport("zts", zts_mod);

    // zts CLI module
    const zts_cli_mod = b.addModule("zts_cli", .{
        .root_source_file = b.path("src/zts_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const proof_checker_dep = b.dependency("zttp_proof_checker", .{
        .target = target,
        .optimize = optimize,
    });
    zts_cli_mod.addImport("zts", zts_mod);
    zts_cli_mod.addImport("zttp_proof_checker", proof_checker_dep.module("zttp_proof_checker"));
    zts_cli_mod.addImport("project_config", project_config_mod);
}
