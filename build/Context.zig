//! Build options and package dependencies shared by every build/*.zig file.
//!
//! Resolved once, in the order `zig build -h` lists the options, and handed
//! to each part of the build graph by value.

const std = @import("std");
const Context = @This();
const selection = @import("test_selection.zig");

b: *std.Build,
target: std.Build.ResolvedTarget,
optimize: std.lang.Optimize,
test_filters: []const []const u8,
test_selections: *std.ArrayList(selection.Run),
test_count_paths: *std.AutoHashMap(*std.Build.Step.Compile, std.Build.LazyPath),
perf_histogram_enabled: bool,
strip_enabled: bool,
precompile: PrecompileOptions,

zts_dep: *std.Build.Dependency,
zts_mod: *std.Build.Module,
zts_host_mod: *std.Build.Module,
zts_bench_mod: *std.Build.Module,
tools_dep: *std.Build.Dependency,
zts_cli_mod: *std.Build.Module,
project_config_mod: *std.Build.Module,
runtime_dep: *std.Build.Dependency,
runtime_bench_dep: *std.Build.Dependency,
pi_dep: *std.Build.Dependency,
pi_host_dep: *std.Build.Dependency,
pi_zts_cli_host_mod: *std.Build.Module,
zttp_sdk_dep: *std.Build.Dependency,
zttp_modules_dep: *std.Build.Dependency,
proof_checker_dep: *std.Build.Dependency,

/// The `-D` options that drive handler precompilation (`-Dhandler`).
pub const PrecompileOptions = struct {
    handler_path: ?[]const u8,
    verify_enabled: bool,
    contract_enabled: bool,
    sql_schema_path: ?[]const u8,
    policy_path: ?[]const u8,
};

pub fn init(b: *std.Build) Context {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_selections = b.allocator.create(std.ArrayList(selection.Run)) catch @panic("OOM");
    test_selections.* = .empty;
    const test_count_paths = b.allocator.create(std.AutoHashMap(*std.Build.Step.Compile, std.Build.LazyPath)) catch @panic("OOM");
    test_count_paths.* = .init(b.allocator);

    // `-Dtest-filter="<substring>"` runs only the matching tests. Zig takes
    // this at compile time, not as a runtime argument to the test binary, so
    // the `-- --test-filter ...` form documented elsewhere panics the runner.
    // Without a working filter, a command written to run one gated test runs
    // the whole root instead - which is how a live recording meant for a
    // single case cleared every committed cassette.
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Run only tests whose name contains this substring",
    );
    // `&.{f}` would point at an array in this function's frame, which is gone
    // once `init` returns the Context; copy it into the build allocator.
    const test_filters: []const []const u8 = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};
    const bench_optimize: std.lang.Optimize = .fast;
    const perf_histogram_enabled = b.option(bool, "perf_histogram", "Enable interpreter opcode histogram collection") orelse false;
    const strip_enabled = b.option(bool, "strip", "Strip debug info from the installed zttp/zts/zttp-runtime binaries (release artifacts)") orelse false;
    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const zts_host_dep = b.dependency("zts", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    const tools_dep = b.dependency("zttp_tools", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    const runtime_dep = b.dependency("zttp_runtime", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const runtime_bench_dep = b.dependency("zttp_runtime", .{
        .target = target,
        .optimize = bench_optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    // The benchmark exe is built ReleaseFast. Its embedded_handler import must
    // resolve `zts` to the matching ReleaseFast module - wiring the Debug
    // `zts` here collides the module graph (file exists in modules zts and
    // zts0) and breaks `zig build bench` on a Debug-default toolchain.
    const zts_bench_dep = b.dependency("zts", .{
        .target = target,
        .optimize = bench_optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    // Pi dependency: used for the in-process expert tool tests. The `pi_app`
    // module itself is linked into the developer `zttp` binary via
    // packages/runtime/build.zig (cli_main), not here — the standalone `zts`
    // analyzer binary is intentionally pi-free.
    const pi_dep = b.dependency("zttp_pi", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    // Sub-dependencies needed for zts test module construction
    const zttp_sdk_dep = b.dependency("zttp_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const zttp_modules_dep = b.dependency("zttp_modules", .{
        .target = target,
        .optimize = optimize,
    });

    // Handler path option (required for main build)
    const precompile: PrecompileOptions = .{
        .handler_path = b.option([]const u8, "handler", "Handler file to precompile (required)"),
        .verify_enabled = b.option(bool, "verify", "Enable compile-time handler verification") orelse false,
        .contract_enabled = b.option(bool, "contract", "Emit handler contract manifest (contract.json)") orelse false,
        .sql_schema_path = b.option([]const u8, "sql-schema", "SQLite schema snapshot (.sqlite) or schema SQL file for zttp:sql validation"),
        .policy_path = b.option([]const u8, "policy", "Capability policy JSON file for precompiled handlers"),
    };

    // Consumer acceptance kernel. Each function enables runtime safety with
    // @setRuntimeSafety(true), enforced by test-kernel-safety. A dependency
    // module's optimize mode did not isolate runtime safety from a ReleaseFast
    // root module when measured on Zig 0.16.0.
    const proof_checker_dep = b.dependency("zttp_proof_checker", .{
        .target = target,
        .optimize = optimize,
    });

    // Host-side builds of tools and pi, for the host test roots and the
    // repository-only executables that run on the build machine.
    const pi_host_tools_dep = b.dependency("zttp_tools", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const pi_host_dep = b.dependency("zttp_pi", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    return .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .test_selections = test_selections,
        .test_count_paths = test_count_paths,
        .perf_histogram_enabled = perf_histogram_enabled,
        .strip_enabled = strip_enabled,
        .precompile = precompile,
        .zts_dep = zts_dep,
        .zts_mod = zts_dep.module("zts"),
        .zts_host_mod = zts_host_dep.module("zts"),
        .zts_bench_mod = zts_bench_dep.module("zts"),
        .tools_dep = tools_dep,
        .zts_cli_mod = tools_dep.module("zts_cli"),
        .project_config_mod = tools_dep.module("project_config"),
        .runtime_dep = runtime_dep,
        .runtime_bench_dep = runtime_bench_dep,
        .pi_dep = pi_dep,
        .pi_host_dep = pi_host_dep,
        .pi_zts_cli_host_mod = pi_host_tools_dep.module("zts_cli"),
        .zttp_sdk_dep = zttp_sdk_dep,
        .zttp_modules_dep = zttp_modules_dep,
        .proof_checker_dep = proof_checker_dep,
    };
}

/// The acceptance kernel module, a leaf that takes no options.
pub fn proofCheckerMod(ctx: Context) *std.Build.Module {
    return ctx.proof_checker_dep.module("zttp_proof_checker");
}

/// Developer filters retain the package runner but must collect real tests.
pub fn addTest(ctx: Context, original: std.Build.TestOptions) *std.Build.Step.Compile {
    var options = original;
    var count_path: ?std.Build.LazyPath = null;
    // A developer filter replaces any fixed filter. A fixed filter on its own
    // still gets the non-empty runner, so a suite whose filter matches no test
    // fails instead of reporting a pass over zero tests.
    const effective: []const []const u8 = if (ctx.test_filters.len != 0) ctx.test_filters else original.filters;
    if (effective.len != 0) {
        options.filters = effective;
        const selected = original.test_runner orelse std.Build.Step.Compile.TestRunner{
            .path = std.Build.LazyPath.zig_lib.path(ctx.b, "compiler/test_runner.zig"),
            .mode = .server,
        };
        options.root_module.addImport("selected_test_runner", ctx.b.createModule(.{
            .root_source_file = selected.path,
            .target = options.root_module.resolved_target,
            .optimize = options.root_module.optimize,
        }));
        const runner_options = ctx.b.addOptions();
        runner_options.addOption(bool, "simple", selected.mode == .simple);
        runner_options.addOption([]const u8, "filter", effective[0]);
        count_path = std.Build.LazyPath.cache_root.path(ctx.b, ctx.b.fmt("test-selection-{x}-{d}-{t}.txt", .{
            std.hash.Wyhash.hash(0, effective[0]), ctx.test_count_paths.count(), ctx.optimize,
        }));
        runner_options.addOptionPathUntracked("count_path", count_path.?);
        options.root_module.addOptions("selection_runner_options", runner_options);
        options.test_runner = .{ .path = ctx.b.path("tooling/nonempty_test_runner.zig"), .mode = selected.mode };
    }
    const compile = ctx.b.addTest(options);
    if (count_path) |path| ctx.test_count_paths.put(compile, path) catch @panic("OOM");
    return compile;
}

pub fn addRunTest(ctx: Context, compile: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = ctx.b.addRunArtifact(compile);
    if (ctx.test_count_paths.get(compile)) |path| {
        run.has_side_effects = true;
        ctx.test_selections.append(ctx.b.allocator, .{ .step = &run.step, .count_path = path }) catch @panic("OOM");
    }
    return run;
}

/// A shell gate: one Run step over a script, exposed as its own named step.
pub const Gate = struct {
    run: *std.Build.Step.Run,
    step: *std.Build.Step,
};

/// Wrap `argv` in a Run step and a top-level step named `name`. The caller
/// decides whether the Run step has side effects.
pub fn addGate(ctx: Context, argv: []const []const u8, name: []const u8, description: []const u8) Gate {
    const run = ctx.b.addSystemCommand(argv);
    const step = ctx.b.step(name, description);
    step.dependOn(&run.step);
    return .{ .run = run, .step = step };
}

/// Attach the `embedded_handler` stub that every runtime-rooted test and bench
/// target needs. A production build replaces this import with the precompiled
/// handler bytecode (`-Dhandler`); a test build has no handler, so it resolves
/// to the stub. The `zts` module must be the one matching the target's optimize
/// mode, or the module graph collides (see the zts_bench_dep comment).
pub fn attachEmbeddedHandlerStub(
    compile: *std.Build.Step.Compile,
    owner_dep: *std.Build.Dependency,
    zts_module: *std.Build.Module,
) void {
    compile.root_module.addAnonymousImport("embedded_handler", .{
        .root_source_file = owner_dep.path("src/embedded_handler_stub.zig"),
        .imports = &.{
            .{ .name = "zts", .module = zts_module },
        },
    });
}
