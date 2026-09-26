//! The wasm64 analyzer for the in-browser proof playground, and its publisher.

const std = @import("std");
const Context = @import("Context.zig");

/// Returns the publisher's test step, which the aggregate `test` step runs.
pub fn add(ctx: Context) *std.Build.Step {
    const b = ctx.b;

    // WebAssembly analyzer — the zts static analysis pipeline compiled to
    // wasm64-freestanding for the in-browser proof playground. It runs the
    // same `runCheckOnlyFromSource` path as `zts check --json`, so the
    // playground renders the real compiler's verdict, not an approximation.
    // wasm64 (not wasm32) because the value layer's NaN-boxing assumes 64-bit
    // pointers. `analyzer_only` strips the interpreter, JIT, GC, SQLite, libc.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm64,
        .os_tag = .freestanding,
    });
    const wasm_zts_dep = b.dependency("zts", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .analyzer_only = true,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "zts-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = ctx.tools_dep.path("src/wasm_analyzer.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.root_module.addImport("zts", wasm_zts_dep.module("zts"));
    // Reactor-style module: no _start, exported functions only.
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const wasm_step = b.step("wasm", "Build the zts analyzer as a wasm64-freestanding module for the web playground");
    wasm_step.dependOn(&wasm_install.step);
    const wasm_publish_mod = b.createModule(.{
        .root_source_file = b.path("tooling/wasm_playground_publish.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    const wasm_publish_exe = b.addExecutable(.{
        .name = "wasm-playground-publish",
        .root_module = wasm_publish_mod,
    });
    const wasm_publish_cmd = b.addRunArtifact(wasm_publish_exe);
    wasm_publish_cmd.addArg("--wasm");
    wasm_publish_cmd.addFileArg(wasm_exe.getEmittedBin());
    if (b.args) |args| wasm_publish_cmd.addArgs(args);
    wasm_publish_cmd.has_side_effects = true;
    const wasm_publish_step = b.step("wasm-playground-publish", "Build and publish the website analyzer WASM");
    wasm_publish_step.dependOn(&wasm_publish_cmd.step);
    const wasm_publish_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = wasm_publish_mod,
    });
    const wasm_publish_test_cmd = b.addRunArtifact(wasm_publish_tests);
    const wasm_publish_test_step = b.step("test-wasm-playground-publish", "Run website WASM publication tests");
    wasm_publish_test_step.dependOn(&wasm_publish_test_cmd.step);
    return wasm_publish_test_step;
}
