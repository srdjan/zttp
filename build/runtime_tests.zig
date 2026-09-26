//! Runtime-rooted test suites: the runtime and dev-CLI unit roots, the
//! standalone zruntime root, the server facade suite, the example handler
//! suites, and the reference-tools artifact check.

const std = @import("std");
const Context = @import("Context.zig");
const artifacts = @import("artifacts.zig");

pub const UnitRuns = struct {
    run_unit_tests: *std.Build.Step.Run,
    run_cli_tests: *std.Build.Step.Run,
};

/// The runtime (main.zig) and dev CLI (cli_main.zig) unit roots. Both are
/// evidence for the invariant drift gate.
pub fn addUnit(ctx: Context, invariant_drift_step: *std.Build.Step) UnitRuns {
    const b = ctx.b;
    const runtime_dep = ctx.runtime_dep;

    // Tests
    const unit_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = runtime_dep.module("runtime_main_tests"),
    });

    // Runtime-side tests (main.zig root) — covers runtime_cli, cli_shared,
    // server, edge_server, studio, and proof_adapter via the test block in
    // main.zig. NOT zruntime, the handler-instance test root: it is the root of
    // its own module, so a file import from main.zig collects none of its
    // tests. Measured at 521 tests with and without that import.
    // `zig build test-zruntime` is the only step that runs that root, and
    // `scripts/verify.sh` runs it separately.
    Context.attachEmbeddedHandlerStub(unit_tests, runtime_dep, ctx.zts_mod);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    invariant_drift_step.dependOn(&run_unit_tests.step);

    // Dev-CLI-side tests (cli_main.zig root) — covers dev_cli and its
    // dependencies (deploy, pi_app wiring, zts_cli delegation).
    const cli_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = runtime_dep.module("cli_main_tests"),
        .test_runner = .{
            .path = runtime_dep.path("src/cli_test_runner.zig"),
            .mode = .simple,
        },
    });
    Context.attachEmbeddedHandlerStub(cli_tests, runtime_dep, ctx.zts_mod);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_test_step = b.step("test-cli", "Run developer CLI unit tests");
    cli_test_step.dependOn(&run_cli_tests.step);

    // The invariant status renderer is anchored from `cli_main.zig`, so this
    // root is the only one that compiles and runs its tests. The drift gate
    // asserts that the renderer's source states write applicability before
    // its counts and keeps the deployment assumption outside every branch;
    // both are source scans, and a source scan proves nothing about what the
    // renderer produced. Naming a test in the gate's evidence table without
    // this dependency would be the gate claiming a test ran when nothing made
    // it compile.
    invariant_drift_step.dependOn(&run_cli_tests.step);

    return .{ .run_unit_tests = run_unit_tests, .run_cli_tests = run_cli_tests };
}

/// Suites that need the built binaries or run long. Every one except
/// test-zruntime is a dependency of `test_step`.
pub fn addIntegration(ctx: Context, bins: artifacts.Binaries, test_step: *std.Build.Step) void {
    const b = ctx.b;
    const runtime_dep = ctx.runtime_dep;

    // ZRuntime tests (native Zig runtime)
    const zruntime_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = runtime_dep.module("zruntime"),
    });
    Context.attachEmbeddedHandlerStub(zruntime_tests, runtime_dep, ctx.zts_mod);
    const run_zruntime_tests = b.addRunArtifact(zruntime_tests);
    const zruntime_test_step = b.step("test-zruntime", "Run ZRuntime unit tests");
    zruntime_test_step.dependOn(&run_zruntime_tests.step);
    // Deliberately not a dependency of `zig build test`: this root holds the
    // pool-heavy handler-instance tests, and running the same root twice in
    // parallel has produced intermittent libc/JIT/arena teardown TRAPs on
    // macOS. `scripts/verify.sh` runs it as its own step.

    // test-server: server/runtime facade integration suite (Phase 0b gate).
    // Tests through public entry points (Server.init/deinit, HandlerPool
    // execute*, RuntimeConfig) — never interpreter/JIT internals.
    const server_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = runtime_dep.module("server_tests"),
    });
    Context.attachEmbeddedHandlerStub(server_tests, runtime_dep, ctx.zts_mod);
    const run_server_tests = b.addRunArtifact(server_tests);
    const server_test_step = b.step("test-server", "Run server/runtime facade integration tests");
    server_test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_server_tests.step);

    // Example handler suites. These were left out of `zig build test` and run
    // only from scripts/verify.sh, and the exclusion was documented rather than
    // enforced - so `zig build test` reported a pass while 56 suites went
    // unrun, and an example claiming a proof property the compiler had stopped
    // discharging (examples/sql/sql-crud.ts, ZTS500) surfaced only in verify.
    // The suites take about 24 seconds, which does not buy an exclusion.
    //
    // The binary comes in as a file argument rather than the script building
    // the tree itself: a nested `zig build` inside a running build would
    // re-enter the build graph.
    const examples_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-examples.sh" });
    examples_cmd.addFileArg(bins.cli_exe.getEmittedBin());
    examples_cmd.has_side_effects = true;
    const examples_test_step = b.step("test-examples", "Run the example handler suites");
    examples_test_step.dependOn(&examples_cmd.step);
    test_step.dependOn(&examples_cmd.step);

    // M4 T7, check C7: build examples/tools with the real zttp binary, run the
    // artifact, and drive it over loopback with no replay. The example suite
    // above counts suites, so it cannot notice this one going missing; this
    // step fails on its own when it runs fewer cases than it declares.
    const reference_tools_mod = b.createModule(.{
        .root_source_file = b.path("packages/runtime/src/reference_tools_check.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    reference_tools_mod.addImport("zts", ctx.zts_host_mod);
    const reference_tools_exe = b.addExecutable(.{
        .name = "reference-tools-check",
        .root_module = reference_tools_mod,
    });
    const reference_tools_cmd = b.addRunArtifact(reference_tools_exe);
    reference_tools_cmd.addFileArg(bins.cli_exe.getEmittedBin());
    // `zttp build` wraps the runtime template it finds beside its own binary.
    reference_tools_cmd.addFileArg(bins.runtime_exe.getEmittedBin());
    reference_tools_cmd.addDirectoryArg(b.path("examples/tools"));
    reference_tools_cmd.has_side_effects = true;
    const reference_tools_step = b.step("test-reference-tools", "Build examples/tools, run the artifact, and check each boundary case over loopback");
    reference_tools_step.dependOn(&reference_tools_cmd.step);
    test_step.dependOn(&reference_tools_cmd.step);
}
