//! Runtime and compile-time benchmarks, the checked-in perf baseline, and
//! their harness tests.

const std = @import("std");
const Context = @import("Context.zig");

/// Returns the benchmark executable, which addCompileBench makes `test` compile.
pub fn addRuntimeBench(ctx: Context, test_step: *std.Build.Step) *std.Build.Step.Compile {
    const b = ctx.b;

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "zttp-bench",
        .root_module = ctx.runtime_bench_dep.module("benchmark"),
    });
    Context.attachEmbeddedHandlerStub(bench_exe, ctx.runtime_bench_dep, ctx.zts_bench_mod);
    // Bench is not installed by default. `zig build bench` still builds and
    // runs it; the artifact is available via the cache or an explicit install.

    // Benchmark run command
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Release benchmark policy is implemented in Zig beside the other
    // repository tooling. Best-of-N sampling tames microbenchmark variance.
    const benchmark_tool_mod = b.createModule(.{
        .root_source_file = b.path("tooling/benchmark.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    benchmark_tool_mod.addImport("zts", ctx.zts_host_mod);
    const benchmark_tool_exe = b.addExecutable(.{
        .name = "zttp-benchmark",
        .root_module = benchmark_tool_mod,
    });
    const bench_check_cmd = b.addRunArtifact(benchmark_tool_exe);
    bench_check_cmd.addArgs(&.{ "check", "--baseline" });
    bench_check_cmd.addFileArg(b.path("benchmarks/perf-baseline.json"));
    bench_check_cmd.addArg("--bench");
    bench_check_cmd.addFileArg(bench_exe.getEmittedBin());
    bench_check_cmd.has_side_effects = true;

    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);
    const bench_check_step = b.step("bench-check", "Compare benchmark output against the checked-in perf baseline");
    bench_check_step.dependOn(&bench_check_cmd.step);
    const bench_record_cmd = b.addRunArtifact(benchmark_tool_exe);
    bench_record_cmd.addArgs(&.{ "record", "--baseline" });
    bench_record_cmd.addFileArg(b.path("benchmarks/perf-baseline.json"));
    bench_record_cmd.addArg("--bench");
    bench_record_cmd.addFileArg(bench_exe.getEmittedBin());
    bench_record_cmd.addArgs(&.{ "--zig", b.graph.zig_exe });
    bench_record_cmd.has_side_effects = true;
    const bench_record_step = b.step("bench-record", "Record a five-run benchmark baseline from clean committed source");
    bench_record_step.dependOn(&bench_record_cmd.step);
    const benchmark_tool_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = benchmark_tool_mod,
    });
    const bench_diff_test_cmd = b.addRunArtifact(benchmark_tool_tests);
    const bench_diff_test_step = b.step("test-bench-diff", "Run benchmark sampling and comparison tests");
    bench_diff_test_step.dependOn(&bench_diff_test_cmd.step);
    test_step.dependOn(bench_diff_test_step);

    return bench_exe;
}

pub fn addCompileBench(ctx: Context, test_step: *std.Build.Step, bench_exe: *std.Build.Step.Compile) void {
    const b = ctx.b;

    // Compile-time microbench: parse + codegen ns/bytes/IR-nodes per compile
    // across a small synthesized corpus. Scaffolding for Phase 8 tuning of
    // reserveCapacity capacity hints.
    const compile_bench_exe = b.addExecutable(.{
        .name = "zttp-compile-bench",
        .root_module = ctx.runtime_dep.module("compile_benchmark"),
    });

    const compile_bench_cmd = b.addRunArtifact(compile_bench_exe);
    // Bench runs are measurements, not cacheable build products.
    compile_bench_cmd.has_side_effects = true;
    if (b.args) |args| {
        compile_bench_cmd.addArgs(args);
    }
    const compile_bench_step = b.step("compile-bench", "Run compile-time microbenchmarks");
    compile_bench_step.dependOn(&compile_bench_cmd.step);

    const compile_bench_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = ctx.runtime_dep.module("compile_benchmark"),
    });
    const run_compile_bench_tests = b.addRunArtifact(compile_bench_tests);
    const compile_bench_test_step = b.step("test-compile-bench", "Run compile-time microbench harness tests");
    compile_bench_test_step.dependOn(&run_compile_bench_tests.step);
    test_step.dependOn(&run_compile_bench_tests.step);

    // Compile (do not run) the benchmark binaries as part of `test`. They import
    // engine internals, so a change that removes an engine symbol breaks them
    // even though no test references them - which is exactly what happened when
    // the JIT was removed: scripts/verify.sh passed while zttp-bench was broken,
    // because the gate never built it. Compiling is enough to catch that class of
    // breakage; running the benchmarks here would import their measurement noise
    // into the gate, so `bench-check` stays a separate step.
    test_step.dependOn(&bench_exe.step);
    test_step.dependOn(&compile_bench_exe.step);
}
