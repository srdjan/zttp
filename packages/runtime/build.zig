const std = @import("std");

const RuntimeFeatureConfig = struct {
    enable_live_reload: bool,
    enable_studio: bool,
    enable_edge: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const perf_histogram = b.option(bool, "perf_histogram", "Enable interpreter opcode histogram collection") orelse false;
    const enable_studio_opt = b.option(bool, "studio", "Compile the browser proof workbench (zttp studio) into the dev CLI") orelse false;
    const enable_edge_opt = b.option(bool, "edge", "Compile the in-process edge runtime (zttp edge) into the binaries") orelse false;

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
    const project_config_mod = tools_dep.module("project_config");

    const pi_dep = b.dependency("zttp_pi", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram,
    });
    const pi_app_mod = pi_dep.module("pi_app");

    const proof_review_dep = b.dependency("zttp_proof_review", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram,
    });
    const proof_review_mod = proof_review_dep.module("zttp_proof_review");

    const runtime_features = runtimeFeatureOptions(b, .{
        .enable_live_reload = false,
        .enable_studio = false,
        .enable_edge = enable_edge_opt,
    });
    const cli_features = runtimeFeatureOptions(b, .{
        .enable_live_reload = true,
        .enable_studio = enable_studio_opt,
        .enable_edge = enable_edge_opt,
    });

    const runtime_main = b.addModule("runtime_main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_main.addImport("zts", zts_mod);
    runtime_main.addImport("project_config", project_config_mod);
    runtime_main.addOptions("runtime_feature_options", runtime_features);

    const runtime_main_tests = b.addModule("runtime_main_tests", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_main_tests.addImport("zts", zts_mod);
    runtime_main_tests.addImport("project_config", project_config_mod);
    runtime_main_tests.addOptions("runtime_feature_options", runtime_features);

    const cli_main = b.addModule("cli_main", .{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_main.addImport("zts", zts_mod);
    cli_main.addImport("zts_cli", zts_cli_mod);
    cli_main.addImport("pi_app", pi_app_mod);
    cli_main.addImport("project_config", project_config_mod);
    cli_main.addImport("zttp_proof_review", proof_review_mod);
    cli_main.addOptions("runtime_feature_options", cli_features);

    const cli_main_tests = b.addModule("cli_main_tests", .{
        .root_source_file = b.path("src/cli_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_main_tests.addImport("zts", zts_mod);
    cli_main_tests.addImport("zts_cli", zts_cli_mod);
    cli_main_tests.addImport("pi_app", pi_app_mod);
    cli_main_tests.addImport("project_config", project_config_mod);
    cli_main_tests.addImport("zttp_proof_review", proof_review_mod);
    cli_main_tests.addOptions("runtime_feature_options", cli_features);

    // Named `zruntime` for the `test-zruntime` step it backs. The root is the
    // end-to-end test file: the runtime itself is handler_instance.zig, and
    // this module carries no product code of its own.
    const zruntime = b.addModule("zruntime", .{
        .root_source_file = b.path("src/zruntime_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    zruntime.addImport("zts", zts_mod);
    zruntime.addOptions("runtime_feature_options", runtime_features);

    // test-server: integration suite rooted at server_test.zig. It pulls in
    // server.zig (and transitively engine_adapter -> zruntime / runtime_pool),
    // so it needs the same imports the runtime template uses: zts, the
    // feature options, and (attached by the top-level build) the
    // embedded_handler anon import.
    const server_tests = b.addModule("server_tests", .{
        .root_source_file = b.path("src/server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_tests.addImport("zts", zts_mod);
    server_tests.addOptions("runtime_feature_options", runtime_features);

    // The benchmark harness lives in bench/, outside the product source tree,
    // so it reaches the runtime through a module rather than by relative path
    // (a `../src/...` import is outside the harness module's own path). One
    // module, rooted at the file that owns `HandlerInstance`, so the harness
    // and the runtime agree on the `RuntimeConfig` type.
    const runtime_instance = b.addModule("runtime_instance", .{
        .root_source_file = b.path("src/handler_instance.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_instance.addImport("zts", zts_mod);
    runtime_instance.addOptions("runtime_feature_options", runtime_features);
    runtime_instance.addAnonymousImport("embedded_handler", .{
        .root_source_file = b.path("src/embedded_handler_stub.zig"),
        .imports = &.{.{ .name = "zts", .module = zts_mod }},
    });

    const benchmark = b.addModule("benchmark", .{
        .root_source_file = b.path("bench/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    benchmark.addImport("zts", zts_mod);
    benchmark.addImport("runtime_instance", runtime_instance);
    benchmark.addOptions("runtime_feature_options", runtime_features);

    const compile_benchmark = b.addModule("compile_benchmark", .{
        .root_source_file = b.path("bench/compile_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compile_benchmark.addImport("zts", zts_mod);
}

fn runtimeFeatureOptions(b: *std.Build, config: RuntimeFeatureConfig) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "enable_live_reload", config.enable_live_reload);
    options.addOption(bool, "enable_studio", config.enable_studio);
    options.addOption(bool, "enable_edge", config.enable_edge);
    return options;
}
