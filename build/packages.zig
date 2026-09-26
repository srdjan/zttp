//! Per-package unit test roots: zts, zttp-sdk, zttp-modules, and the
//! consumer acceptance kernel.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    zts_test_step: *std.Build.Step,
    run_sdk_tests: *std.Build.Step.Run,
    run_modules_tests: *std.Build.Step.Run,
    run_proof_checker_tests: *std.Build.Step.Run,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const test_filters = ctx.test_filters;
    const zts_dep = ctx.zts_dep;
    const zttp_sdk_dep = ctx.zttp_sdk_dep;
    const zttp_modules_dep = ctx.zttp_modules_dep;

    // zts tests.
    //
    // `zig test` collects tests only from the files its root module analyzes,
    // and packages/zts is five modules now (four tiers plus the umbrella that
    // re-exports them). One root over src/root.zig would compile and pass while
    // running none of the tier tests, which is the shape
    // docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md
    // warns about. So there is one root per module, and every one of them is a
    // dependency of `test-zts`.
    const zts_build_options = b.addOptions();
    zts_build_options.addOption(bool, "perf_histogram", ctx.perf_histogram_enabled);
    zts_build_options.addOption(bool, "analyzer_only", false);

    const zts_test_step = b.step("test-zts", "Run zts unit tests");
    const zts_roots = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "zts-base", .src = "src/base_root.zig" },
        .{ .name = "zts-contracts", .src = "src/contracts_root.zig" },
        .{ .name = "zts-engine", .src = "src/engine_root.zig" },
        .{ .name = "zts-compiler", .src = "src/compiler_root.zig" },
        .{ .name = "zts", .src = "src/root.zig" },
    };
    for (zts_roots, 0..) |entry, index| {
        const root = b.createModule(.{
            .root_source_file = zts_dep.path(entry.src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        root.addOptions("build_options", zts_build_options);
        // Each root is a second module over a file that packages/zts/build.zig
        // also compiles, so it needs the same named imports. The module objects
        // come from the dependency, so a tier is the same module here and there
        // rather than a second copy of its files.
        //
        // A root imports the tiers BELOW its own and no others. Importing its
        // own tier makes zig report "file exists in modules 'root' and
        // 'zts-engine'", because this module already analyzes those files.
        // Importing a tier above is worse and quieter: the engine root pulling
        // `zts-compiler` drags in that module's own `zts-engine` dependency, so
        // sqlite3.c is compiled twice into one binary and every sqlite3_*
        // symbol is a duplicate definition. Both are the duplicate-file failure
        // this split exists to prevent, seen from the test side.
        for (zts_roots[0..index]) |lower| {
            root.addImport(lower.name, zts_dep.module(lower.name));
        }
        root.addImport("zttp-sdk", zttp_sdk_dep.module("zttp-sdk"));
        root.addImport("zttp-modules", zttp_modules_dep.module("zttp-modules"));
        // Only the engine root analyzes sqlite.zig, so only it compiles the C.
        // Adding the source to a second root in the same binary made the linker
        // report every sqlite3_* symbol as a duplicate definition.
        if (std.mem.eql(u8, entry.name, "zts-engine")) {
            root.addCSourceFile(.{
                .file = zts_dep.path("deps/sqlite/sqlite3.c"),
                .flags = &.{ "-D_GNU_SOURCE", "-DHAVE_MREMAP=0", "-DSQLITE_THREADSAFE=2", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
            });
            root.addIncludePath(zts_dep.path("deps/sqlite"));
        }
        const tests = b.addTest(.{
            .name = entry.name,
            .filters = test_filters,
            .root_module = root,
        });
        zts_test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const sdk_test_shim_mod = b.createModule(.{
        .root_source_file = zttp_sdk_dep.path("src/test_shim.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zttp-sdk", .module = zttp_sdk_dep.module("zttp-sdk") },
        },
    });
    const sdk_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = zttp_sdk_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zttp-sdk", .module = zttp_sdk_dep.module("zttp-sdk") },
                .{ .name = "zttp-sdk-test-shim", .module = sdk_test_shim_mod },
            },
        }),
    });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const sdk_test_step = b.step("test-sdk", "Run zttp-sdk tests");
    sdk_test_step.dependOn(&run_sdk_tests.step);

    const modules_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = zttp_modules_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zttp-sdk", .module = zttp_sdk_dep.module("zttp-sdk") },
                .{ .name = "zttp-sdk-test-shim", .module = sdk_test_shim_mod },
            },
        }),
    });
    const run_modules_tests = b.addRunArtifact(modules_tests);
    const modules_test_step = b.step("test-modules", "Run zttp-modules tests");
    modules_test_step.dependOn(&run_modules_tests.step);

    // Consumer acceptance kernel. Declared before proof-review so the module is
    // available to every consumer below it, and wired with no imports of its
    // own: the package is a leaf, and `scripts/check-proof-checker.sh` fails
    // when that stops being true. Context.zig states why a release build keeps
    // runtime safety in it.
    const proof_checker_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = ctx.proof_checker_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_proof_checker_tests = b.addRunArtifact(proof_checker_tests);
    const proof_checker_test_step = b.step("test-proof-checker", "Run the consumer acceptance kernel tests");
    proof_checker_test_step.dependOn(&run_proof_checker_tests.step);

    return .{
        .zts_test_step = zts_test_step,
        .run_sdk_tests = run_sdk_tests,
        .run_modules_tests = run_modules_tests,
        .run_proof_checker_tests = run_proof_checker_tests,
    };
}
