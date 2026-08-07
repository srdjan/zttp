const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const perf_histogram = b.option(bool, "perf_histogram", "Enable interpreter opcode histogram collection") orelse false;
    // analyzer_only strips the VM, SQLite, and libc from the build graph so the
    // static analysis pipeline can target wasm64-freestanding. The normal
    // build leaves it false and behaves exactly as before.
    const analyzer_only = b.option(bool, "analyzer_only", "Build the static analyzer only (no interpreter, SQLite, or libc) for wasm/freestanding targets") orelse false;
    const sdk_dep = b.dependency("zttp_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const modules_dep = b.dependency("zttp_modules", .{
        .target = target,
        .optimize = optimize,
    });
    // `zts-base` is the bottom of the tier graph: vocabulary and pure helpers
    // that name nothing else in this package. Declared as its own module so a
    // higher tier reaches it by name. A relative import across this line would
    // compile a second copy of the file into the importing module, and the two
    // copies' types would not be interchangeable.
    // `scripts/check-zts-layering.sh` fails on that; see
    // docs/plans/2026-08-07-021-zts-three-module-split-plan.md.
    const base_mod = b.addModule("zts-base", .{
        .root_source_file = b.path("src/base_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !analyzer_only,
    });

    // `zts-contracts` is data and serialization: what a contract and its
    // receipts are, never how they are produced. Both `zts` (which holds them
    // at run time) and `zts-compiler` (which produces them at build time)
    // depend on it, and it depends on neither.
    const contracts_mod = b.addModule("zts-contracts", .{
        .root_source_file = b.path("src/contracts_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !analyzer_only,
    });
    contracts_mod.addImport("zts-base", base_mod);

    // `zts-engine` runs a handler; `zts-compiler` decides whether one is
    // proven. The engine may not name the compiler - that direction is the
    // cycle the split exists to prevent - so the engine module is declared
    // first and the compiler depends on it, never the reverse.
    const engine_mod = b.addModule("zts-engine", .{
        .root_source_file = b.path("src/engine_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !analyzer_only,
    });
    engine_mod.addImport("zts-base", base_mod);
    engine_mod.addImport("zts-contracts", contracts_mod);

    const compiler_mod = b.addModule("zts-compiler", .{
        .root_source_file = b.path("src/compiler_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !analyzer_only,
    });
    compiler_mod.addImport("zts-base", base_mod);
    compiler_mod.addImport("zts-contracts", contracts_mod);
    compiler_mod.addImport("zts-engine", engine_mod);

    // `zts` is the umbrella every consumer imports. It holds no implementation:
    // src/root.zig re-exports the four tiers above, so a consumer's
    // `@import("zts")` keeps resolving exactly the names it always did while
    // the tiers underneath are separately compiled and separately layered.
    const mod = b.addModule("zts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !analyzer_only,
    });
    mod.addImport("zts-base", base_mod);
    mod.addImport("zts-contracts", contracts_mod);
    mod.addImport("zts-engine", engine_mod);
    mod.addImport("zts-compiler", compiler_mod);

    const build_options = b.addOptions();
    build_options.addOption(bool, "perf_histogram", perf_histogram);
    build_options.addOption(bool, "analyzer_only", analyzer_only);
    // Every module that reads a build option needs its own copy: options are
    // per-module, and the engine's `analyzer_only` gates are what strip the VM
    // subtree for the wasm target.
    mod.addOptions("build_options", build_options);
    base_mod.addOptions("build_options", build_options);
    contracts_mod.addOptions("build_options", build_options);
    engine_mod.addOptions("build_options", build_options);
    compiler_mod.addOptions("build_options", build_options);
    if (!analyzer_only) {
        // sqlite.zig is analyzed only in the engine module, so only that
        // module compiles the C source. Adding it to the umbrella as well
        // put both copies in one binary and the linker reported every
        // sqlite3_* symbol as a duplicate definition.
        engine_mod.addCSourceFile(.{
            .file = b.path("deps/sqlite/sqlite3.c"),
            // THREADSAFE=2 (multi-thread): each connection is used by one
            // thread at a time, which matches the per-runtime SqliteDb model.
            // The HTTP server runs requests on a worker-thread pool, so
            // THREADSAFE=0 (single-thread, all mutexing compiled out) would
            // corrupt shared SQLite global state across concurrent requests.
            .flags = &.{ "-D_GNU_SOURCE", "-DHAVE_MREMAP=0", "-DSQLITE_THREADSAFE=2", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
        });
        engine_mod.addIncludePath(b.path("deps/sqlite"));
    }
    // The virtual module bindings are analyzed in the engine module.
    engine_mod.addImport("zttp-sdk", sdk_dep.module("zttp-sdk"));
    engine_mod.addImport("zttp-modules", modules_dep.module("zttp-modules"));
}
