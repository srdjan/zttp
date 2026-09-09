const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const perf_histogram_enabled = b.option(bool, "perf_histogram", "Enable interpreter opcode histogram collection") orelse false;
    const studio_enabled = b.option(bool, "studio", "Compile the browser proof workbench (zttp studio) into the dev CLI") orelse false;
    const edge_enabled = b.option(bool, "edge", "Compile the in-process edge runtime (zttp edge) into the binaries") orelse false;
    const strip_enabled = b.option(bool, "strip", "Strip debug info from the installed zttp/zts/zttp-runtime binaries (release artifacts)") orelse false;
    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const zts_mod = zts_dep.module("zts");
    const zts_host_dep = b.dependency("zts", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const zts_host_mod = zts_host_dep.module("zts");

    const tools_dep = b.dependency("zttp_tools", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const zts_cli_mod = tools_dep.module("zts_cli");
    const project_config_mod = tools_dep.module("project_config");

    const runtime_dep = b.dependency("zttp_runtime", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
        .studio = studio_enabled,
        .edge = edge_enabled,
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
    const zts_bench_mod = zts_bench_dep.module("zts");

    // Pi dependency: used for the in-process expert tool tests below. The
    // `pi_app` module itself is linked into the developer `zttp` binary via
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
    // Capture git commit for reproducible build metadata. Failure to read
    // git is non-fatal: the precompile binary falls back to the sentinel
    // "unknown", so tarball builds and CI environments without a .git
    // directory still produce a well-formed `__GIT_COMMIT__` substitution.
    const git_commit_sha = detectGitCommit(b);

    // Handler path option (required for main build)
    const handler_path = b.option([]const u8, "handler", "Handler file to precompile (required)");
    const aot_enabled = b.option(bool, "aot", "Enable native AOT handler generation") orelse false;
    const verify_enabled = b.option(bool, "verify", "Enable compile-time handler verification") orelse false;
    const contract_enabled = b.option(bool, "contract", "Emit handler contract manifest (contract.json)") orelse false;
    const openapi_enabled = b.option(bool, "openapi", "Emit OpenAPI manifest (openapi.json)") orelse false;
    const sdk_target = b.option([]const u8, "sdk", "Emit generated SDK artifact (values: ts)");
    const sql_schema_path = b.option([]const u8, "sql-schema", "SQLite schema snapshot (.sqlite) or schema SQL file for zttp:sql validation");
    const policy_path = b.option([]const u8, "policy", "Capability policy JSON file for precompiled handlers");
    const system_path = b.option([]const u8, "system", "System definition file for cross-handler contract linking");
    const replay_path = b.option([]const u8, "replay", "Replay trace file for regression verification at build time");
    const test_file_path = b.option([]const u8, "test-file", "Run handler tests from JSONL file at build time");
    const prove_spec = b.option([]const u8, "prove", "Prove upgrade safety (format: contract.json or contract.json:traces.jsonl)");
    const generate_tests = b.option(bool, "generate-tests", "Generate exhaustive test cases from path analysis") orelse false;

    // External enrichment flags (optional, for cross-referencing with code generators)
    const manifest_path = b.option([]const u8, "manifest", "External manifest JSON for cross-referencing against handler contract");
    const expect_properties_path = b.option([]const u8, "expect-properties", "Expected handler properties JSON for build-time verification");
    const data_labels_path = b.option([]const u8, "data-labels", "External data label declarations JSON for flow checker enrichment");
    const fault_severity_path = b.option([]const u8, "fault-severity", "External fault severity overrides JSON for coverage analysis");
    const generator_pack_path = b.option([]const u8, "generator-pack", "Generator integration pack JSON for external manifest/property/data-label/replay/report wiring");
    const report_format = b.option([]const u8, "report", "Emit structured build report (values: json)");

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
    zts_build_options.addOption(bool, "perf_histogram", perf_histogram_enabled);
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
                .flags = &.{ "-D_GNU_SOURCE", "-DHAVE_MREMAP=0", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
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
    // when that stops being true.
    const proof_checker_dep = b.dependency("zttp_proof_checker", .{
        .target = target,
        .optimize = optimize,
    });
    const proof_checker_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = proof_checker_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_proof_checker_tests = b.addRunArtifact(proof_checker_tests);
    const proof_checker_test_step = b.step("test-proof-checker", "Run the consumer acceptance kernel tests");
    proof_checker_test_step.dependOn(&run_proof_checker_tests.step);

    // The kernel's own floor: the suite above reports a pass whether it
    // collected two hundred tests or none, so a separate gate asserts the
    // corpus is non-empty and the package still imports nothing.
    const proof_checker_purity = b.addSystemCommand(&.{ "bash", "scripts/check-proof-checker.sh" });
    proof_checker_purity.has_side_effects = true;
    const proof_checker_purity_step = b.step("test-proof-checker-purity", "Check the acceptance kernel is a leaf with a non-empty suite");
    proof_checker_purity_step.dependOn(&proof_checker_purity.step);

    // Every script in scripts/ must be invoked by something or say why not. A
    // gate nothing runs reports nothing, which reads the same as a gate that
    // found nothing - and scripts/test-zruntime.sh sat in the tree invoking a
    // root file that had been deleted, called by nobody.
    const script_reachability = b.addSystemCommand(&.{ "bash", "scripts/check-script-reachability.sh" });
    script_reachability.has_side_effects = true;
    const script_reachability_step = b.step("test-script-reachability", "Check every script in scripts/ is invoked or declared manual");
    script_reachability_step.dependOn(&script_reachability.step);

    // Every advertised diagnostic variant must have a construction site. The
    // rule-coverage gate in packages/pi keys on `rule.code`, so a dead variant
    // sharing a code with a live producer is permanently satisfied and cannot
    // be reported - three did exactly that.
    const diagnostic_producers = b.addSystemCommand(&.{ "bash", "scripts/check-diagnostic-producers.sh" });
    diagnostic_producers.has_side_effects = true;
    const diagnostic_producers_step = b.step("test-diagnostic-producers", "Check every advertised diagnostic variant has a producer");
    diagnostic_producers_step.dependOn(&diagnostic_producers.step);

    // The published trusted boundary against the one the kernel implements.
    const proof_ratchet_drift = b.addSystemCommand(&.{ "bash", "scripts/check-proof-ratchet.sh" });
    proof_ratchet_drift.has_side_effects = true;
    const proof_ratchet_drift_step = b.step("test-proof-ratchet-drift", "Check the published trusted boundary against the kernel");
    proof_ratchet_drift_step.dependOn(&proof_ratchet_drift.step);

    // The residual-guard boundary: consumer catalog, compiler mirror, enabled
    // families, measured conversions, and published documentation.
    const residual_guards_drift = b.addSystemCommand(&.{ "bash", "scripts/check-residual-guards.sh" });
    residual_guards_drift.has_side_effects = true;
    const residual_guards_drift_step = b.step("test-residual-guards-drift", "Check residual guard catalogs, evidence, and docs");
    residual_guards_drift_step.dependOn(&residual_guards_drift.step);

    // The trusted-boundary ratchet. Rooted at its own file because nothing in
    // the product imports it: it is a corpus plus assertions, and a file no
    // analyzed root reaches contributes no tests.
    const proof_ratchet_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = runtime_dep.path("src/proof_ratchet.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zts", .module = zts_dep.module("zts") },
                .{ .name = "zts_cli", .module = zts_cli_mod },
                .{ .name = "zttp_proof_checker", .module = proof_checker_dep.module("zttp_proof_checker") },
            },
        }),
    });
    const run_proof_ratchet_tests = b.addRunArtifact(proof_ratchet_tests);
    const proof_ratchet_step = b.step("test-proof-ratchet", "Check the disclosed trusted boundary against what the kernel re-derives");
    proof_ratchet_step.dependOn(&run_proof_ratchet_tests.step);

    // zttp proof-review package tests
    // Pass perf_histogram so the build-graph dedups this dep with the one
    // runtime threads through its own modules. Without it the option-set
    // hashes diverge and Zig instantiates zttp_proof_review twice, splitting
    // type identity across the proof-review/runtime boundary.
    const proof_review_pkg_dep = b.dependency("zttp_proof_review", .{
        .target = target,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const proof_review_pkg_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = proof_review_pkg_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zts", .module = zts_dep.module("zts") },
                .{ .name = "zts_cli", .module = zts_cli_mod },
            },
        }),
    });
    const run_proof_review_pkg_tests = b.addRunArtifact(proof_review_pkg_tests);
    const proof_review_pkg_test_step = b.step("test-proof-review", "Run zttp proof-review package tests");
    proof_review_pkg_test_step.dependOn(&run_proof_review_pkg_tests.step);

    // Host-side test roots for the tools and pi packages. Nine roots that
    // differ only in source file, step name, description, and which extra
    // modules they import, so they are declared as data and built in one loop.
    //
    // Several exist because their file is only reached through a *named module*
    // (`zts_cli`), which is never an addTest root, so no other suite collects
    // their `test {}` blocks. Rooting at the file directly is the only way they
    // run at all; see the `collected_via_named_module` note on each entry.
    const pi_host_tools_dep = b.dependency("zttp_tools", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });
    const pi_zts_cli_host_mod = pi_host_tools_dep.module("zts_cli");
    const pi_host_dep = b.dependency("zttp_pi", .{
        .target = b.graph.host,
        .optimize = optimize,
        .perf_histogram = perf_histogram_enabled,
    });

    const HostTestRoot = struct {
        /// Which package owns the root source file.
        owner: enum { tools, pi },
        src: []const u8,
        step: []const u8,
        desc: []const u8,
        /// `edit_simulate.zig` and the machine commands resolve the project SQL
        /// schema through the shared project_config module.
        project_config: bool = false,
        /// The pi roots consume the shared tool cores through named modules
        /// rather than relative imports, so their file graphs stay disjoint.
        pi_modules: bool = false,
        standin_only: bool = false,
    };

    const host_test_roots = [_]HostTestRoot{
        .{ .owner = .tools, .src = "src/precompile.zig", .step = "test-precompile", .desc = "Run precompile tool tests" },
        // collected_via_named_module: canonicalize.zig is reached only through
        // the `zts_cli` module, so this root is what runs its tests.
        .{ .owner = .tools, .src = "src/canonicalize.zig", .step = "test-canonicalize", .desc = "Run canonicalize/normalize tool tests", .project_config = true },
        .{ .owner = .tools, .src = "src/property_expectations.zig", .step = "test-property-expectations", .desc = "Run property expectations tool tests" },
        .{ .owner = .tools, .src = "src/system_rollout.zig", .step = "test-rollout", .desc = "Run rollout planner tests" },
        .{ .owner = .tools, .src = "src/expert.zig", .step = "test-expert", .desc = "Run zts expert v1 contract tripwires" },
        // collected_via_named_module: zts_cli.zig and the command files it
        // imports (describe_rule.zig, search_rules.zig, ...) are reached only
        // through the `zts_cli` module. Same rationale as canonicalize.
        .{ .owner = .tools, .src = "src/zts_cli.zig", .step = "test-zts-cli", .desc = "Run analyzer dispatch + machine-command module tests", .project_config = true },
        .{ .owner = .tools, .src = "src/deploy_manifest.zig", .step = "test-deploy-manifest", .desc = "Run deploy manifest renderer tests" },
        // collected_via_named_module: training_export.zig is reached only
        // through the `zts_cli` command table, and the `zts_cli` root does not
        // analyze it, so this root is what runs its tests. Verified 2026-08-26
        // by test count: the zts_cli suite stayed at 140 with the file added.
        .{ .owner = .tools, .src = "src/training_export.zig", .step = "test-training-export", .desc = "Run ZTS training-export bundle tests", .project_config = true },
        // collected_via_named_module: agent_identity.zig is re-exported by
        // zts_cli.zig but not yet referenced by any analyzed code, and Zig only
        // collects tests from files it analyzes - so the `zts_cli` root runs
        // none of them. Its own root does. Same rationale as canonicalize.
        .{ .owner = .tools, .src = "src/agent_identity.zig", .step = "test-agent-identity", .desc = "Run v2 agent protocol identity primitive tests" },
        // collected_via_named_module: same as agent_identity - nothing analyzed
        // references it yet, so only its own root runs its tests.
        .{ .owner = .tools, .src = "src/module_graph_record.zig", .step = "test-module-graph-record", .desc = "Run v2 resolved module graph and digest tests" },
        .{ .owner = .tools, .src = "src/agent_protocol.zig", .step = "test-agent-protocol", .desc = "Run v2 agent protocol envelope tests", .project_config = true },
        // Audited 2026-07-31: these eight files carry tests that no root
        // collected, so none had ever run. Zig collects tests only from files a
        // root analyzes, and a file reached solely through a named module - or
        // through an unreferenced re-export - is not analyzed. Verified by
        // planting a failing test in every tools file and recording which ones
        // the aggregate suite reported.
        //
        // The same audit ran over zts, runtime, and pi on 2026-07-31: 276 files
        // carry tests and every one is collected. 274 by `zig build test`,
        // `runtime/src/studio.zig` by the `zig build test-cli -Dstudio` step in
        // scripts/verify.sh (studio compiles out by default), and
        // `runtime/src/zruntime_tests.zig` by `zig build test-zruntime`. No new
        // root needed there: those three packages reach their files through
        // analyzed imports, not through named modules the way tools does.
        .{ .owner = .tools, .src = "src/module_audit.zig", .step = "test-module-audit", .desc = "Run module-contract audit tests", .project_config = true },
        .{ .owner = .tools, .src = "src/manifest_alignment.zig", .step = "test-manifest-alignment", .desc = "Run manifest alignment tests", .project_config = true },
        .{ .owner = .tools, .src = "src/smt_solver.zig", .step = "test-smt-solver", .desc = "Run SMT solver harness tests", .project_config = true },
        .{ .owner = .tools, .src = "src/verify_paths_core.zig", .step = "test-verify-paths-core", .desc = "Run behavior-path verification core tests", .project_config = true },
        .{ .owner = .tools, .src = "src/report.zig", .step = "test-report", .desc = "Run analyzer report renderer tests", .project_config = true },
        .{ .owner = .tools, .src = "src/project_config.zig", .step = "test-project-config", .desc = "Run project config discovery tests" },
        .{ .owner = .tools, .src = "src/proof_quest_fixture.zig", .step = "test-proof-quest-fixture", .desc = "Run proof quest fixture tests", .project_config = true },
        .{ .owner = .tools, .src = "src/openapi_manifest.zig", .step = "test-openapi-manifest", .desc = "Run OpenAPI manifest tests", .project_config = true },
        .{ .owner = .pi, .src = "src/tests.zig", .step = "test-expert-app", .desc = "Run zts expert in-process app tests", .project_config = true, .pi_modules = true },
        // Focused subset covering only the record/replay layer: runs offline,
        // never needs an API key, and does not transitively pull in the
        // tools/skills tests, so it stays fast.
        .{ .owner = .pi, .src = "src/cassette_tests.zig", .step = "test-cassette", .desc = "Run pi provider cassette harness tests (offline)", .project_config = true, .pi_modules = true },
        .{ .owner = .pi, .src = "src/simulator_tests.zig", .step = "test-simulator", .desc = "Run fail-closed full-flow simulator tests (offline)", .project_config = true, .pi_modules = true },
        .{ .owner = .pi, .src = "src/standin_tests.zig", .step = "test-standin", .desc = "Run the deterministic stand-in through the real expert loop", .project_config = true, .pi_modules = true, .standin_only = true },
    };

    const standin_range_doc = b.addOptions();
    standin_range_doc.addOption(
        []const u8,
        "contents",
        @embedFile("packages/pi/docs/standin-range.md"),
    );

    // The accounting list behind docs/coverage.md's unseeded remainder. Kept as
    // a text file rather than a Zig table so it reads like the repository's
    // other allowlists, and reaches the gate the same way the range document
    // does.
    const unseeded_rules = b.addOptions();
    unseeded_rules.addOption(
        []const u8,
        "contents",
        @embedFile("scripts/unseeded-rules.allow"),
    );

    var host_test_runs: [host_test_roots.len]*std.Build.Step.Run = undefined;
    for (host_test_roots, 0..) |root, i| {
        const owner_dep = switch (root.owner) {
            .tools => tools_dep,
            .pi => pi_dep,
        };
        const tests = b.addTest(.{
            .filters = if (root.standin_only) &.{"stand-in"} else test_filters,
            .root_module = b.createModule(.{
                .root_source_file = owner_dep.path(root.src),
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        tests.root_module.addImport("zts", zts_host_mod);
        // The acceptance kernel is a leaf and takes no options, so wiring it
        // into every host root costs nothing and keeps the table free of a flag
        // that would need updating each time a file starts naming it.
        tests.root_module.addImport(
            "zttp_proof_checker",
            proof_checker_dep.module("zttp_proof_checker"),
        );
        if (root.project_config) tests.root_module.addImport("project_config", project_config_mod);
        if (root.pi_modules) {
            tests.root_module.addImport("zts_cli", pi_zts_cli_host_mod);
        }
        if (root.standin_only) tests.root_module.addOptions("standin_range_doc", standin_range_doc);
        if (root.standin_only) tests.root_module.addOptions("unseeded_rules", unseeded_rules);
        host_test_runs[i] = b.addRunArtifact(tests);
        b.step(root.step, root.desc).dependOn(&host_test_runs[i].step);
        // The residual gate's source comparison is useful only if its
        // behavioral evidence compiles and runs. Keep that dependency on the
        // named gate so a broken probe cannot be reported as guard agreement.
        if (root.standin_only) residual_guards_drift_step.dependOn(&host_test_runs[i].step);
    }

    // Explicit real-model gate. It is intentionally absent from the aggregate
    // test step because zttp never manages the developer's MLX server.
    const mlx_e2e_tests = b.addTest(.{
        .filters = &.{"local MLX expert flow"},
        .root_module = b.createModule(.{
            .root_source_file = pi_host_dep.path("src/mlx_e2e_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }),
        .test_runner = .{
            .path = pi_host_dep.path("src/mlx_e2e_runner.zig"),
            .mode = .simple,
        },
    });
    mlx_e2e_tests.root_module.addImport("zts", zts_host_mod);
    mlx_e2e_tests.root_module.addImport("project_config", project_config_mod);
    mlx_e2e_tests.root_module.addImport("zts_cli", pi_zts_cli_host_mod);
    const run_mlx_e2e_tests = b.addRunArtifact(mlx_e2e_tests);
    const mlx_e2e_step = b.step("test-expert-mlx-e2e", "Run the real local MLX expert flow");
    mlx_e2e_step.dependOn(&run_mlx_e2e_tests.step);

    const capability_audit = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-capability-helpers.sh" });
    const capability_audit_step = b.step("test-capability-audit", "Run capability helper audit");
    capability_audit_step.dependOn(&capability_audit.step);

    // Authoritative release-evidence provenance gate. It is Zig-native so the
    // release path has no language/toolchain dependency beyond this build.
    const release_provenance_mod = b.createModule(.{
        .root_source_file = b.path("tooling/release_provenance.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const release_provenance_exe = b.addExecutable(.{
        .name = "release-provenance",
        .root_module = release_provenance_mod,
    });
    const release_provenance_cmd = b.addRunArtifact(release_provenance_exe);
    release_provenance_cmd.has_side_effects = true;
    const release_provenance_step = b.step("release-provenance", "Validate release evidence provenance");
    release_provenance_step.dependOn(&release_provenance_cmd.step);
    const release_provenance_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = release_provenance_mod,
    });
    const run_release_provenance_tests = b.addRunArtifact(release_provenance_tests);
    const release_provenance_test_step = b.step("test-release-provenance", "Run release provenance tests");
    release_provenance_test_step.dependOn(&run_release_provenance_tests.step);

    // Release-readiness passport: repository tooling, deliberately not part of
    // any installed binary. It reads this repository's own files, so it means
    // nothing inside a user project; it shipped as `zttp doctor --release`
    // until it moved to tooling/.
    const release_check_mod = b.createModule(.{
        .root_source_file = b.path("tooling/release_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    release_check_mod.addImport("zts", zts_host_mod);
    release_check_mod.addImport("release_provenance", release_provenance_mod);
    const release_check_exe = b.addExecutable(.{
        .name = "release-check",
        .root_module = release_check_mod,
    });
    const release_check_cmd = b.addRunArtifact(release_check_exe);
    release_check_cmd.has_side_effects = true;
    if (b.args) |args| release_check_cmd.addArgs(args);
    const release_check_step = b.step("release-check", "Print this repository's release-readiness passport");
    release_check_step.dependOn(&release_check_cmd.step);

    const release_check_tests = b.addTest(.{ .filters = test_filters, .root_module = release_check_mod });
    const run_release_check_tests = b.addRunArtifact(release_check_tests);
    const release_check_test_step = b.step("test-release-check", "Run release-passport tests");
    release_check_test_step.dependOn(&run_release_check_tests.step);

    // Validate the actual passport exported by the scripted demo through the
    // canonical framed-event reader instead of a shell or Python reimplementation.
    const demo_passport_check_mod = b.createModule(.{
        .root_source_file = pi_host_dep.path("src/demo_passport_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_passport_check_mod.addImport("zts", zts_host_mod);
    const demo_passport_check_exe = b.addExecutable(.{
        .name = "demo-passport-check",
        .root_module = demo_passport_check_mod,
    });
    const demo_passport_check_cmd = b.addRunArtifact(demo_passport_check_exe);
    demo_passport_check_cmd.has_side_effects = true;
    if (b.args) |args| demo_passport_check_cmd.addArgs(args);
    const demo_passport_check_step = b.step("demo-passport-check", "Validate an exported proof passport");
    demo_passport_check_step.dependOn(&demo_passport_check_cmd.step);
    const demo_passport_check_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = demo_passport_check_mod,
    });
    const run_demo_passport_check_tests = b.addRunArtifact(demo_passport_check_tests);
    const demo_passport_check_test_step = b.step("test-demo-passport-check", "Run proof-passport checker tests");
    demo_passport_check_test_step.dependOn(&run_demo_passport_check_tests.step);

    // Repository-only AST metric. The live command receives the tracked Zig
    // source list from a NUL-safe script; its unit tests pin the AST definition
    // and its input floors. It is never installed in user projects.
    const production_branch_metric_mod = b.createModule(.{
        .root_source_file = b.path("tooling/production_branch_metric.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const production_branch_metric_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = production_branch_metric_mod,
    });
    const run_production_branch_metric_tests = b.addRunArtifact(production_branch_metric_tests);
    const production_branch_metric_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh" });
    const production_branch_metric_step = b.step("production-branch-metric", "Measure production branch points in tracked Zig sources");
    production_branch_metric_step.dependOn(&production_branch_metric_cmd.step);
    const production_branch_metric_json_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh", "--json" });
    const production_branch_metric_json_step = b.step("production-branch-metric-json", "Measure production branch points as JSON");
    production_branch_metric_json_step.dependOn(&production_branch_metric_json_cmd.step);
    const production_branch_metric_test_step = b.step("test-production-branch-metric", "Test and run the production branch metric");
    production_branch_metric_test_step.dependOn(&run_production_branch_metric_tests.step);
    production_branch_metric_test_step.dependOn(&production_branch_metric_cmd.step);

    // Development-only deterministic author. It speaks the OpenAI Responses
    // wire on loopback and is never part of the install step.
    const standin_mod = b.createModule(.{
        .root_source_file = pi_host_dep.path("src/standin_main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const standin_exe = b.addExecutable(.{
        .name = "zttp-standin",
        .root_module = standin_mod,
    });
    const standin_cmd = b.addRunArtifact(standin_exe);
    standin_cmd.has_side_effects = true;
    if (b.args) |args| standin_cmd.addArgs(args);
    const standin_step = b.step("zttp-standin", "Run the deterministic playbook server");
    standin_step.dependOn(&standin_cmd.step);

    // Repository-only expert qualification decision. It consumes exactly
    // three report-only live-run records and never edits the model registry.
    const expert_qualification_mod = b.createModule(.{
        .root_source_file = pi_host_dep.path("src/expert_qualification.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const expert_qualification_exe = b.addExecutable(.{
        .name = "expert-qualification",
        .root_module = expert_qualification_mod,
    });
    const expert_qualification_cmd = b.addRunArtifact(expert_qualification_exe);
    expert_qualification_cmd.has_side_effects = true;
    if (b.args) |args| expert_qualification_cmd.addArgs(args);
    const expert_qualification_step = b.step(
        "expert-qualification",
        "Assess three report-only expert qualification runs",
    );
    expert_qualification_step.dependOn(&expert_qualification_cmd.step);

    const module_boundary = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-module-boundary.sh" });
    const module_boundary_step = b.step("test-module-boundary", "Check consumer reach into zts internals against the allowlist");
    module_boundary_step.dependOn(&module_boundary.step);

    const release_workflow = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-release-workflow.sh" });
    const release_workflow_step = b.step("test-release-workflow", "Check release workflow invariants");
    release_workflow_step.dependOn(&release_workflow.step);

    const proof_swallow = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-proof-swallow.sh" });
    const proof_swallow_step = b.step("test-proof-swallow", "Check the proof pipeline for unreviewed swallowed errors");
    proof_swallow_step.dependOn(&proof_swallow.step);

    const zts_layering = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-zts-layering.sh" });
    const zts_layering_step = b.step("test-zts-layering", "Check zts tier assignments import only downward");
    zts_layering_step.dependOn(&zts_layering.step);

    const convergence_emitter = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-convergence-emitter.sh" });
    const convergence_emitter_step = b.step("test-convergence-emitter", "Check the convergence marker has one producer and one consumer");
    convergence_emitter_step.dependOn(&convergence_emitter.step);

    const evidence_marker = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-evidence-marker.sh" });
    evidence_marker.step.dependOn(&run_release_provenance_tests.step);
    const evidence_marker_step = b.step("test-evidence-marker", "Check release evidence marker and publisher boundaries");
    evidence_marker_step.dependOn(&evidence_marker.step);

    const expert_qualification_boundary = b.addSystemCommand(&.{
        "python3",
        "scripts/test-expert-qualification.py",
    });
    const expert_qualification_boundary_step = b.step(
        "test-expert-qualification",
        "Check report-only expert qualification boundaries",
    );
    expert_qualification_boundary_step.dependOn(&expert_qualification_boundary.step);

    const docs_drift = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-docs-drift.sh" });
    const docs_drift_step = b.step("test-docs-drift", "Check docs against current registry and build paths");
    docs_drift_step.dependOn(&docs_drift.step);

    const idiom_table = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-idiom-table.sh" });
    const idiom_table_step = b.step("test-idiom-table", "Check spec 4.2.1's idiom table against the registry");
    idiom_table_step.dependOn(&idiom_table.step);

    const canonical_style = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-canonical-style.sh" });
    const canonical_style_step = b.step("test-canonical-style", "Check the canonical-style skill's examples against the rule registry");
    canonical_style_step.dependOn(&canonical_style.step);

    const grammar_drift = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-grammar-drift.sh" });
    const grammar_drift_step = b.step("test-grammar-drift", "Check spec section 8's grammar against the registry");
    grammar_drift_step.dependOn(&grammar_drift.step);

    const decision_registry_gate = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-decision-registry.sh" });
    const decision_registry_step = b.step("test-decision-registry", "Check every published decision kind is emitted somewhere");
    decision_registry_step.dependOn(&decision_registry_gate.step);

    const meta_drift = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-meta-drift.sh" });
    const meta_drift_step = b.step("test-meta-drift", "Check meta's published registry hashes against their pins");
    meta_drift_step.dependOn(&meta_drift.step);

    const doc_links = b.addSystemCommand(&.{ "/bin/bash", "scripts/audit-docs.sh" });
    const doc_links_step = b.step("test-doc-links", "Check docs for broken relative links");
    doc_links_step.dependOn(&doc_links.step);

    // Internal precompile tool used by build steps and the zts CLI.
    const precompile_exe = b.addExecutable(.{
        .name = "precompile",
        .root_module = b.createModule(.{
            .root_source_file = tools_dep.path("src/precompile.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    precompile_exe.root_module.addImport("zts", zts_host_mod);

    // Runtime template binary — used for self-contained outputs and direct
    // runtime tests. Minimal dependencies:
    // only what's needed to serve HTTP and execute a (possibly embedded)
    // handler. No pi_app, no deploy, no zts_cli.
    const runtime_exe = b.addExecutable(.{
        .name = "zttp-runtime",
        .root_module = runtime_dep.module("runtime_main"),
    });

    var embedded_handler_step: ?*std.Build.Step = null;

    // If handler is specified, precompile it and add as dependency
    if (handler_path) |path| {
        // Run precompile tool to generate embedded handler
        const run_precompile = b.addRunArtifact(precompile_exe);
        if (aot_enabled) {
            run_precompile.addArg("--aot");
        }
        if (verify_enabled) {
            run_precompile.addArg("--verify");
        }
        if (openapi_enabled) {
            run_precompile.addArg("--openapi");
        }
        if (sdk_target) |sdk| {
            run_precompile.addArg("--sdk");
            run_precompile.addArg(sdk);
        }
        if (sql_schema_path) |sql_schema| {
            run_precompile.addArg("--sql-schema");
            run_precompile.addArg(sql_schema);
        }
        if (system_path) |system| {
            run_precompile.addArg("--system");
            run_precompile.addArg(system);
        }
        if (contract_enabled) {
            run_precompile.addArg("--contract");
        }
        if (policy_path) |policy| {
            run_precompile.addArg("--policy");
            run_precompile.addArg(policy);
        }
        if (replay_path) |rp| {
            run_precompile.addArg("--replay");
            run_precompile.addArg(rp);
        }
        if (test_file_path) |tf| {
            run_precompile.addArg("--test-file");
            run_precompile.addArg(tf);
        }
        if (prove_spec) |ps| {
            run_precompile.addArg("--prove");
            run_precompile.addArg(ps);
        }
        if (generate_tests) {
            run_precompile.addArg("--generate-tests");
        }
        if (manifest_path) |mp| {
            run_precompile.addArg("--manifest");
            run_precompile.addArg(mp);
        }
        if (expect_properties_path) |ep| {
            run_precompile.addArg("--expect-properties");
            run_precompile.addArg(ep);
        }
        if (data_labels_path) |dl| {
            run_precompile.addArg("--data-labels");
            run_precompile.addArg(dl);
        }
        if (fault_severity_path) |fs| {
            run_precompile.addArg("--fault-severity");
            run_precompile.addArg(fs);
        }
        if (generator_pack_path) |gp| {
            run_precompile.addArg("--generator-pack");
            run_precompile.addArg(gp);
        }
        if (report_format) |rf| {
            run_precompile.addArg("--report");
            run_precompile.addArg(rf);
        }
        if (git_commit_sha) |sha| {
            run_precompile.addArg("--git-commit");
            run_precompile.addArg(sha);
        }
        run_precompile.addArg(path);
        run_precompile.addArg("packages/runtime/generated/embedded_handler.zig");

        // Create the generated directories if they don't exist
        const mkdir_step = b.addSystemCommand(&.{ "/bin/mkdir", "-p", "packages/runtime/generated" });
        run_precompile.step.dependOn(&mkdir_step.step);
        embedded_handler_step = &run_precompile.step;

        // Runtime and user-facing CLI both depend on precompile completing.
        runtime_exe.step.dependOn(&run_precompile.step);

        // Add the generated module (with zts dependency for transpiled handlers)
        runtime_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = b.path("packages/runtime/generated/embedded_handler.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    } else {
        // No handler specified - create a stub module
        runtime_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = runtime_dep.path("src/embedded_handler_stub.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    }

    b.installArtifact(runtime_exe);

    // Developer CLI — the primary user-facing `zttp` binary. Contains init,
    // dev, serve, check, compile, prove, mock, link, expert, local deploy,
    // doctor, and the proof/proof-ledger tools. Hosted deploy account verbs
    // are intentionally absent from CLI dispatch in the beta.
    const cli_exe = b.addExecutable(.{
        .name = "zttp",
        .root_module = runtime_dep.module("cli_main"),
    });
    if (embedded_handler_step) |step| {
        cli_exe.step.dependOn(step);
        cli_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = b.path("packages/runtime/generated/embedded_handler.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    } else {
        cli_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = runtime_dep.path("src/embedded_handler_stub.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    }
    b.installArtifact(cli_exe);

    // Compiler/analyzer CLI installed for IDE and CI integrations that call
    // the analyzer directly. Pi-free by design: the interactive `expert` and
    // session `ledger` commands live only in the developer `zttp` binary, so
    // the ~37 KLOC agent (and its network/credential surface) is compiled
    // exactly once across the whole build.
    const zts_exe = b.addExecutable(.{
        .name = "zts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zts_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    zts_exe.root_module.addImport("zts_cli", zts_cli_mod);
    b.installArtifact(zts_exe);

    // The drift gate must inspect this build's executable, not a possibly
    // stale installation left in zig-out by an earlier invocation.
    meta_drift.addFileArg(zts_exe.getEmittedBin());

    const zts_overview_drift = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-zts-language-overview.sh" });
    zts_overview_drift.addFileArg(zts_exe.getEmittedBin());
    docs_drift_step.dependOn(&zts_overview_drift.step);

    // Chrome is not a standard build dependency, so keep real-browser
    // interaction coverage explicit and fail loudly when the local toolchain
    // is unavailable.
    const zts_overview_browser = b.addSystemCommand(&.{ "node", "scripts/test-zts-language-overview-browser.mjs" });
    const zts_overview_browser_step = b.step("test-zts-overview-browser", "Test the ZTS language overview in headless Chrome");
    zts_overview_browser_step.dependOn(&zts_overview_browser.step);

    // Strip debug info from the three installed binaries when -Dstrip is set.
    // The release workflow passes -Dstrip so shipped tarballs stay small; local
    // builds keep symbols by default. Stripping happens at link time, so it is
    // correct for every cross-compiled -Dtarget.
    if (strip_enabled) {
        runtime_exe.root_module.strip = true;
        cli_exe.root_module.strip = true;
        zts_exe.root_module.strip = true;
    }

    // Runtime purity guard: the deployable `zttp-runtime` template and the
    // pi-free `zts` analyzer must carry no expert-agent / model-provider
    // surface; the developer `zttp` binary is the sole pi host. Enforces the
    // invariant against future regressions. See scripts/check-runtime-purity.sh.
    const runtime_purity_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-runtime-purity.sh" });
    runtime_purity_cmd.addFileArg(cli_exe.getEmittedBin());
    runtime_purity_cmd.addFileArg(runtime_exe.getEmittedBin());
    runtime_purity_cmd.addFileArg(zts_exe.getEmittedBin());
    // Emit the sealed ZTS training contract bundle. The script supplies commit
    // and worktree state; the exporter refuses a dirty tree.
    const training_export_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/zts-training-export.sh" });
    training_export_cmd.addFileArg(zts_exe.getEmittedBin());
    training_export_cmd.has_side_effects = true;
    if (b.args) |args| training_export_cmd.addArgs(args);
    const training_export_step = b.step("zts-training-export", "Emit the sealed ZTS training contract bundle");
    training_export_step.dependOn(&training_export_cmd.step);

    const runtime_purity_step = b.step("test-runtime-purity", "Assert the deployed runtime and analyzer carry no agent/provider surface");
    runtime_purity_step.dependOn(&runtime_purity_cmd.step);

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
            .root_source_file = tools_dep.path("src/wasm_analyzer.zig"),
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
    const wasm_publish_test_cmd = b.addSystemCommand(&.{ "python3", "scripts/test-wasm-playground-publish.py" });
    wasm_publish_test_cmd.has_side_effects = true;
    const wasm_publish_test_step = b.step("test-wasm-playground-publish", "Run website WASM publication tests");
    wasm_publish_test_step.dependOn(&wasm_publish_test_cmd.step);

    const run_module_governance = b.addRunArtifact(zts_exe);
    run_module_governance.addArgs(&.{ "verify-modules", "--builtins", "--strict", "--json" });
    const module_governance_step = b.step("test-module-governance", "Run built-in module governance audit");
    module_governance_step.dependOn(&run_module_governance.step);

    // Golden-output checks that run the built `zts` binary and assert
    // stdout is byte-identical to a fixture. Covers the direct-command v1 JSON
    // contract for `meta`, `verify-paths`, and `describe-rule`.
    // Regenerate the fixtures with `scripts/update-expert-goldens.sh` (or by
    // rerunning each command and redirecting into
    // packages/tools/tests/fixtures/expert/) after a deliberate contract
    // change; see docs/zts-expert-contract.md.
    // Public-contract goldens. These pin the analyzer's observable output for a
    // handler set chosen to span distinct analysis paths (plain TS, JSX, every
    // virtual module, durable/workflow) plus the three enumeration commands.
    // Their purpose is refactor safety: a change that claims to preserve
    // behavior must leave every byte here untouched. Contract JSON carries no
    // timestamps, absolute paths, or version strings, so it is byte-stable by
    // construction (verified by rerunning each command before committing).
    // Regenerate with `scripts/update-contract-goldens.sh` after a DELIBERATE
    // contract change, and review the diff: a golden that moves without an
    // intended reason is the gate doing its job.
    const contract_golden_step = b.step("test-contract-golden", "Check analyzer contract output against golden fixtures");
    const contract_fixtures = "packages/tools/tests/fixtures/contract";
    // Exit codes are part of the pinned contract: plain_ts proves clean, the
    // other three carry warnings and exit 1 today.
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/plain_ts.ts", "--json", "--contract",
    }, contract_fixtures ++ "/plain_ts.contract.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/jsx.tsx", "--json", "--contract",
    }, contract_fixtures ++ "/jsx.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/modules_all.ts", "--json", "--contract",
    }, contract_fixtures ++ "/modules_all.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/durable_approval.ts", "--json", "--contract",
    }, contract_fixtures ++ "/durable_approval.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "features", "--json" }, contract_fixtures ++ "/features.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "modules", "--json" }, contract_fixtures ++ "/modules.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "restrictions", "--json" }, contract_fixtures ++ "/restrictions.golden.json", 0);

    // Comptime strip failures predate the ZTS registry and currently expose
    // only StripError.ComptimeEvaluationFailed. Pin that exact real-CLI
    // identity, its unregistered JSON shape, and an accepted safe contrast.
    // There is no registry rule to add to the expert replay or coverage page.
    const comptime_cli_step = b.step("test-comptime-cli-matrix", "Run comptime CLI reject and safe-contrast fixtures");
    const comptime_fixtures = "packages/tools/tests/fixtures/comptime";
    addExpertExitCheck(b, comptime_cli_step, zts_exe, &.{
        "check", comptime_fixtures ++ "/safe.ts", "--json",
    }, 0);
    const comptime_reject = b.addRunArtifact(zts_exe);
    comptime_reject.addArgs(&.{ "check", comptime_fixtures ++ "/reject_random.ts", "--json" });
    comptime_reject.expectExitCode(1);
    comptime_reject.expectStdOutEqual("{\"success\":false,\"diagnostics\":[]}\n");
    comptime_reject.expectStdErrEqual("TypeScript strip error: error.ComptimeEvaluationFailed\n");
    comptime_cli_step.dependOn(&comptime_reject.step);

    // Instantiating a generic application must preserve every intersection
    // obligation, including members beyond sixteen. Run the real analyzer so
    // the gate protects the public verdict, not only the representation.
    const generic_intersection_cli_step = b.step(
        "test-generic-intersection-cli-matrix",
        "Run wide generic-intersection reject and safe-contrast fixtures",
    );
    const generic_intersection_fixtures = "packages/tools/tests/fixtures/generic-intersection";
    addExpertExitCheck(b, generic_intersection_cli_step, zts_exe, &.{
        "check", generic_intersection_fixtures ++ "/accept_all_17.ts", "--json",
    }, 0);
    addExpertGolden(b, generic_intersection_cli_step, zts_exe, &.{
        "check", generic_intersection_fixtures ++ "/reject_member_17.ts", "--json",
    }, generic_intersection_fixtures ++ "/reject_member_17.golden.json", 1);

    const expert_golden_step = b.step("test-expert-golden", "Check zts direct tool contract against golden fixtures");
    const fixtures_root = "packages/tools/tests/fixtures/expert";
    // `meta --json` leads with `compiler_version`, which bumps every release.
    // Pinning it in a byte-exact golden made the fixture stale on each release
    // for no contract value. Assert the version-independent tail exactly (policy
    // hash, module hash, rule count, categories, mode) and only that the
    // version field is present, so the meaningful contract stays covered.
    addExpertMetaGolden(b, expert_golden_step, zts_exe, fixtures_root ++ "/meta.golden.json");
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/clean_handler.ts",
        "--json",
    }, fixtures_root ++ "/verify_paths_clean.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/missing.ts",
        "--json",
    }, fixtures_root ++ "/verify_paths_missing.golden.json", 1);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{ "search", "guard", "--json" }, fixtures_root ++ "/search_guard.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{ "describe-rule", "ZTS303", "--json" }, fixtures_root ++ "/describe_rule_ZTS303.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "canonicalize",
        fixtures_root ++ "/canonicalize_mixed.ts",
        "--json",
    }, fixtures_root ++ "/canonicalize_mixed.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "canonicalize",
        fixtures_root ++ "/canonicalize_mixed.ts",
        "--json",
        "--simulate",
    }, fixtures_root ++ "/canonicalize_mixed_simulate.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/clean_handler.ts",
    }, fixtures_root ++ "/verify_paths_clean_text.golden.txt", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/missing.ts",
    }, fixtures_root ++ "/verify_paths_missing_text.golden.txt", 1);

    // Exit-code contract for help/error paths. Stdout isn't pinned because
    // help text edits should not break tests; only the exit code is part of
    // the contract. The `expert` command now lives only in the developer
    // `zttp` binary (cli_exe); analyzer commands stay on `zts` (zts_exe).
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "expert", "--help" }, 0);
    // Compiler-only goal runs must never consult cloud credentials or local
    // model readiness. Keep this at the executable boundary so dispatch and
    // environment injection cannot regress independently of the pi unit tests.
    const goal_without_model = b.addRunArtifact(cli_exe);
    goal_without_model.addArgs(&.{
        "expert",
        "--handler",
        fixtures_root ++ "/clean_handler.ts",
        "--goal",
        "no_secret_leakage",
        "--max-iters",
        "1",
        "--no-session",
    });
    goal_without_model.removeEnvironmentVariable("HOME");
    goal_without_model.removeEnvironmentVariable("ANTHROPIC_API_KEY");
    goal_without_model.removeEnvironmentVariable("OPENAI_API_KEY");
    goal_without_model.setEnvironmentVariable("ZTTP_MLX_BASE_URL", "http://127.0.0.1:1");
    goal_without_model.expectExitCode(0);
    goal_without_model.expectStdOutMatch("autoloop verdict: achieved");
    expert_golden_step.dependOn(&goal_without_model.step);

    // `init --expert` performs the same readiness check before scaffolding.
    // The follow-up absence check is the execution floor for that ordering.
    const init_preflight_root = b.addWriteFiles();
    _ = init_preflight_root.add("preflight-fixture", "");
    const init_preflight = b.addRunArtifact(cli_exe);
    init_preflight.addArgs(&.{ "init", "demo", "--expert" });
    init_preflight.setCwd(init_preflight_root.getDirectory());
    init_preflight.removeEnvironmentVariable("HOME");
    init_preflight.removeEnvironmentVariable("ANTHROPIC_API_KEY");
    init_preflight.removeEnvironmentVariable("OPENAI_API_KEY");
    init_preflight.removeEnvironmentVariable("DEEPSEEK_API_KEY");
    init_preflight.setEnvironmentVariable("ZTTP_MLX_BASE_URL", "http://127.0.0.1:1");
    init_preflight.expectExitCode(1);
    // Names the default provider's credential, so moving the default without
    // moving this line fails here rather than shipping a message for a provider
    // the preflight no longer checks.
    init_preflight.expectStdErrMatch("--provider deepseek requires DEEPSEEK_API_KEY");
    const init_preflight_absence = b.addSystemCommand(&.{ "/bin/test", "!", "-e", "demo" });
    init_preflight_absence.setCwd(init_preflight_root.getDirectory());
    init_preflight_absence.step.dependOn(&init_preflight.step);
    expert_golden_step.dependOn(&init_preflight_absence.step);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "meta", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "verify-paths", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "verify-paths", fixtures_root ++ "/clean_handler.ts", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "expert", "no-such-sub" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "ledger", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{"verify-paths"}, 1);

    // Machine-command unknown-flag contract (plan 009): a typo'd flag is a loud
    // non-zero exit via the clean dev-CLI mapping, not a silently-ignored arg
    // that yields wrong output for tool/CI callers; valid invocations stay
    // exit 0. These run the developer `zttp` binary (cli_exe), which owns the
    // invalid-arguments message; the analyzer `zts` binary shares the same
    // dispatch. Stdout is intentionally not pinned.
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "features", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "features", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "modules", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "modules", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "meta", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "meta", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "describe-rule", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "describe-rule", "ZTS303" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "search", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "search", "guard" }, 0);

    // Run command: runs the runtime binary directly, without triggering the
    // full install step (which would also link the dev CLI and bench binaries).
    const run_cmd = b.addRunArtifact(runtime_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Dev CLI run command for convenience: `zig build cli -- expert`
    const cli_run_cmd = b.addRunArtifact(cli_exe);
    if (b.args) |args| {
        cli_run_cmd.addArgs(args);
    }
    const cli_run_step = b.step("cli", "Run the zttp CLI");
    cli_run_step.dependOn(&cli_run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = runtime_dep.module("runtime_main_tests"),
    });

    // Runtime-side tests (main.zig root) — covers runtime_cli, cli_shared,
    // server, edge_server, studio, and proof_adapter via the test block in
    // main.zig. NOT zruntime, the handler-instance test root: it is the root of
    // its own module, so a file import from main.zig collects none of its
    // tests. Measured at 521 tests with and without that import.
    // `zig build test-zruntime` is the only step that runs that root, and
    // `scripts/verify.sh` runs it separately.
    attachEmbeddedHandlerStub(unit_tests, runtime_dep, zts_mod);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Dev-CLI-side tests (cli_main.zig root) — covers dev_cli and its
    // dependencies (deploy, pi_app wiring, zts_cli delegation).
    const cli_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = runtime_dep.module("cli_main_tests"),
        .test_runner = .{
            .path = runtime_dep.path("src/cli_test_runner.zig"),
            .mode = .simple,
        },
    });
    attachEmbeddedHandlerStub(cli_tests, runtime_dep, zts_mod);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const cli_test_step = b.step("test-cli", "Run developer CLI unit tests");
    cli_test_step.dependOn(&run_cli_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    // Every host test root from the table above.
    for (host_test_runs) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&capability_audit.step);
    test_step.dependOn(&module_boundary.step);
    test_step.dependOn(&release_workflow.step);
    test_step.dependOn(&proof_swallow.step);
    test_step.dependOn(&residual_guards_drift.step);
    test_step.dependOn(&zts_layering.step);
    test_step.dependOn(&run_release_check_tests.step);
    test_step.dependOn(&run_release_provenance_tests.step);
    test_step.dependOn(&run_demo_passport_check_tests.step);
    test_step.dependOn(wasm_publish_test_step);
    test_step.dependOn(production_branch_metric_test_step);
    test_step.dependOn(comptime_cli_step);
    test_step.dependOn(generic_intersection_cli_step);
    // `zttp-standin` is deliberately not installed, so nothing else forces it
    // to compile and a break in that path would surface only when somebody ran
    // the step by hand. Compile it here, without installing it.
    test_step.dependOn(&standin_exe.step);
    // The docs drift and link gates run here, and only here: neither Run step is
    // cached, so `zig build test` always executes both scripts. CI and
    // scripts/verify.sh deliberately do not invoke test-docs-drift or
    // test-doc-links a second time.
    test_step.dependOn(docs_drift_step);
    test_step.dependOn(&doc_links.step);
    test_step.dependOn(&convergence_emitter.step);
    test_step.dependOn(&evidence_marker.step);
    test_step.dependOn(&expert_qualification_boundary.step);
    test_step.dependOn(&run_module_governance.step);
    test_step.dependOn(zts_test_step);
    test_step.dependOn(&run_sdk_tests.step);
    test_step.dependOn(&run_modules_tests.step);
    test_step.dependOn(&run_proof_review_pkg_tests.step);
    test_step.dependOn(&run_proof_checker_tests.step);
    test_step.dependOn(&run_proof_ratchet_tests.step);
    test_step.dependOn(&proof_ratchet_drift.step);
    test_step.dependOn(&proof_checker_purity.step);
    test_step.dependOn(&diagnostic_producers.step);
    test_step.dependOn(&script_reachability.step);
    test_step.dependOn(expert_golden_step);
    test_step.dependOn(contract_golden_step);
    test_step.dependOn(&runtime_purity_cmd.step);

    // ZRuntime tests (native Zig runtime)
    const zruntime_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = runtime_dep.module("zruntime"),
    });
    attachEmbeddedHandlerStub(zruntime_tests, runtime_dep, zts_mod);
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
        .filters = test_filters,
        .root_module = runtime_dep.module("server_tests"),
    });
    attachEmbeddedHandlerStub(server_tests, runtime_dep, zts_mod);
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
    examples_cmd.addFileArg(cli_exe.getEmittedBin());
    examples_cmd.has_side_effects = true;
    const examples_test_step = b.step("test-examples", "Run the example handler suites");
    examples_test_step.dependOn(&examples_cmd.step);
    test_step.dependOn(&examples_cmd.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "zttp-bench",
        .root_module = runtime_bench_dep.module("benchmark"),
    });
    attachEmbeddedHandlerStub(bench_exe, runtime_bench_dep, zts_bench_mod);
    // Bench is not installed by default. `zig build bench` still builds and
    // runs it; the artifact is available via the cache or an explicit install.

    // Benchmark run command
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    // Run the benchmark binary multiple times through bench-diff.sh directly
    // (best-of-N handling lives in the script to tame microbench variance).
    const bench_check_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/bench-diff.sh" });
    bench_check_cmd.addArg("--baseline");
    bench_check_cmd.addFileArg(b.path("benchmarks/perf-baseline.json"));
    bench_check_cmd.addArg("--bench");
    bench_check_cmd.addFileArg(bench_exe.getEmittedBin());
    bench_check_cmd.has_side_effects = true;

    // Release build step (with handler precompilation if provided)
    const release_step = b.step("release", "Build optimized release binaries (zttp, zttp-runtime, zts)");
    release_step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);
    const bench_check_step = b.step("bench-check", "Compare benchmark output against the checked-in perf baseline");
    bench_check_step.dependOn(&bench_check_cmd.step);
    const bench_record_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/bench-record.sh" });
    bench_record_cmd.addArg("--baseline");
    bench_record_cmd.addFileArg(b.path("benchmarks/perf-baseline.json"));
    bench_record_cmd.addArg("--bench");
    bench_record_cmd.addFileArg(bench_exe.getEmittedBin());
    bench_record_cmd.has_side_effects = true;
    const bench_record_step = b.step("bench-record", "Record a five-run benchmark baseline from clean committed source");
    bench_record_step.dependOn(&bench_record_cmd.step);
    const bench_diff_test_cmd = b.addSystemCommand(&.{ "python3", "scripts/test-bench-diff.py" });
    bench_diff_test_cmd.has_side_effects = true;
    const bench_diff_test_step = b.step("test-bench-diff", "Run benchmark sampling and comparison tests");
    bench_diff_test_step.dependOn(&bench_diff_test_cmd.step);
    test_step.dependOn(bench_diff_test_step);

    // End-to-end smoke for the v1 user flow:
    // init -> doctor -> check -> build -> deploy.
    // The script builds the CLI itself; the step does not reference cli_exe so
    // CI can invoke it as a single command without depending on install steps.
    // studio is compiled out by default, so it is smoke-tested separately by
    // `zig build smoke-studio` (which builds with -Dstudio).
    const smoke_v1_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/smoke-v1.sh" });
    smoke_v1_cmd.has_side_effects = true;
    const smoke_v1_step = b.step("smoke-v1", "Run the v1 user-flow smoke test in a temp dir");
    smoke_v1_step.dependOn(&smoke_v1_cmd.step);

    const panic_isolation_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-panic-isolation.sh", "--skip-build", "--zttp" });
    panic_isolation_cmd.addArg(b.getInstallPath(.bin, "zttp"));
    panic_isolation_cmd.has_side_effects = true;
    panic_isolation_cmd.step.dependOn(b.getInstallStep());

    const module_scope_panic_probe_mod = b.createModule(.{
        .root_source_file = runtime_dep.path("src/module_scope_panic_probe.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    module_scope_panic_probe_mod.addImport("zts", zts_host_mod);
    const module_scope_panic_probe = b.addExecutable(.{
        .name = "module-scope-panic-probe",
        .root_module = module_scope_panic_probe_mod,
    });
    const run_module_scope_panic_probe = b.addRunArtifact(module_scope_panic_probe);
    const module_scope_panic_probe_step = b.step(
        "test-module-scope-panic",
        "Verify module authorization isolation across a recovered panic",
    );
    module_scope_panic_probe_step.dependOn(&run_module_scope_panic_probe.step);

    const panic_isolation_step = b.step("test-panic-isolation", "Run handler panic isolation E2E test");
    panic_isolation_step.dependOn(&panic_isolation_cmd.step);
    panic_isolation_step.dependOn(&run_module_scope_panic_probe.step);

    const smoke_studio_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/smoke-studio.sh" });
    smoke_studio_cmd.has_side_effects = true;
    const smoke_studio_step = b.step("smoke-studio", "Run the opt-in studio smoke test (-Dstudio) in a temp dir");
    smoke_studio_step.dependOn(&smoke_studio_cmd.step);

    const smoke_getting_started_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/smoke-getting-started.sh" });
    smoke_getting_started_cmd.has_side_effects = true;
    const smoke_getting_started_step = b.step("smoke-getting-started", "Run the Getting Started guide smoke test in a temp dir");
    smoke_getting_started_step.dependOn(&smoke_getting_started_cmd.step);

    const smoke_demo_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/smoke-demo.sh" });
    smoke_demo_cmd.has_side_effects = true;
    const smoke_demo_step = b.step("smoke-demo", "Run the Proof Theater demo smoke test in a temp dir");
    smoke_demo_step.dependOn(&smoke_demo_cmd.step);

    // Compile-time microbench: parse + codegen ns/bytes/IR-nodes per compile
    // across a small synthesized corpus. Scaffolding for Phase 8 tuning of
    // reserveCapacity capacity hints.
    const compile_bench_exe = b.addExecutable(.{
        .name = "zttp-compile-bench",
        .root_module = runtime_dep.module("compile_benchmark"),
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
        .filters = test_filters,
        .root_module = runtime_dep.module("compile_benchmark"),
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

    // System linking step (cross-handler contract verification)
    if (system_path) |sys_path| {
        const run_system = b.addRunArtifact(zts_exe);
        run_system.addArg("link");
        run_system.addArg(sys_path);
        if (b.args) |args| {
            run_system.addArgs(args);
        }
        const system_step = b.step("system", "Cross-handler contract linking");
        system_step.dependOn(&run_system.step);
    }

    // ------------------------------------------------------------------
    // Step coverage: every top-level step's work must be run by something.
    //
    // This walks the real dependency graph, not the source. A named step is not
    // what `test` depends on - `test_step.dependOn(&run_server_tests.step)`
    // names the Run step, and `b.step("test-server", ...)` names a separate
    // top-level step over the same Run - so "is test-server reachable from
    // test" is the wrong question. The right one is whether each top-level
    // step's dependency closure is covered, and only the graph can answer it.
    //
    // A step counts as run when `zig build test` reaches it, when
    // scripts/verify.sh or a CI workflow invokes the step that reaches it, or
    // when one of those runs the same shell gate the step wraps - five steps
    // are covered only by that last route. Anything left must carry a row in
    // scripts/manual-steps.allow saying why a human asks for it.
    //
    // scripts/test-examples.sh is why this exists: it was documented as
    // outside `zig build test` and run only from verify.sh, and 56 example
    // suites went unrun while `zig build test` reported a pass.
    // ------------------------------------------------------------------
    {
        const coverage_sources = blk: {
            var acc: std.ArrayList(u8) = .empty;
            acc.appendSlice(b.allocator, @embedFile("scripts/verify.sh")) catch @panic("OOM");
            // Read the workflow directory rather than embedding a fixed list,
            // so a workflow added later is a coverage source without anyone
            // having to remember this gate.
            var wf = b.build_root.handle.openDir(b.graph.io, ".github/workflows", .{ .iterate = true }) catch
                @panic("step coverage: .github/workflows is missing; this gate would credit no CI invocation");
            defer wf.close(b.graph.io);
            var it = wf.iterate();
            var workflows: usize = 0;
            while (it.next(b.graph.io) catch @panic("step coverage: cannot iterate .github/workflows")) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;
                const text = wf.readFileAlloc(b.graph.io, entry.name, b.allocator, .unlimited) catch
                    @panic("step coverage: cannot read a workflow file");
                acc.appendSlice(b.allocator, text) catch @panic("OOM");
                acc.append(b.allocator, '\n') catch @panic("OOM");
                workflows += 1;
            }
            // Floor on this gate's own input. With no coverage text every step
            // reads as manual and the allowlist would have to name all of them;
            // with a truncated read, steps quietly become "uncovered".
            if (workflows == 0) @panic("step coverage: no CI workflow files read; the coverage input is empty");
            break :blk acc.items;
        };
        if (std.mem.indexOf(u8, coverage_sources, "zig build ") == null) {
            @panic("step coverage: the coverage text names no `zig build` invocation; the scan is broken");
        }

        var covered = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
        var name_buf: [128]u8 = undefined;
        collectReachable(test_step, &covered);
        for (b.top_level_steps.values()) |tls| {
            if (verifyInvokes(coverage_sources, tls.step.name, &name_buf)) {
                collectReachable(&tls.step, &covered);
            }
        }
        if (covered.count() < 50) {
            @panic("step coverage: the covered closure is implausibly small; the graph walk is broken");
        }

        const manual_src = @embedFile("scripts/manual-steps.allow");
        var report: std.ArrayList(u8) = .empty;
        var violations: usize = 0;
        var manual_rows: usize = 0;
        var step_count: usize = 0;

        for (b.top_level_steps.values()) |tls| {
            step_count += 1;
            const declared_manual = allowNames(manual_src, tls.step.name);
            var own = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
            collectReachable(&tls.step, &own);
            var unrun: usize = 0;
            var it = own.keyIterator();
            while (it.next()) |entry| {
                const dep = entry.*;
                if (dep.id == .top_level) continue;
                if (covered.contains(dep)) continue;
                // A step that only wraps a shell gate is run when something
                // runs that script, whichever Run step instance does it.
                if (runStepScript(dep)) |script| {
                    if (std.mem.indexOf(u8, coverage_sources, script) != null) continue;
                }
                unrun += 1;
            }
            if (unrun > 0 and !declared_manual) {
                report.print(b.allocator, "  {s}: {d} of {d} dependency steps are run by nothing\n", .{ tls.step.name, unrun, own.count() }) catch @panic("OOM");
                violations += 1;
            }
            if (unrun == 0 and declared_manual) {
                report.print(b.allocator, "  {s}: listed in scripts/manual-steps.allow, but something runs it now - delete the row\n", .{tls.step.name}) catch @panic("OOM");
                violations += 1;
            }
        }

        // A row naming a step that no longer exists is a claim about nothing.
        var lines = std.mem.splitScalar(u8, manual_src, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const name = fields.next() orelse continue;
            manual_rows += 1;
            if (b.top_level_steps.get(name) == null) {
                report.print(b.allocator, "  {s}: listed in scripts/manual-steps.allow, but no such build step exists\n", .{name}) catch @panic("OOM");
                violations += 1;
            }
        }
        if (manual_rows == 0) {
            @panic("step coverage: scripts/manual-steps.allow parsed zero rows; the allowlist read is broken");
        }

        const step_coverage_step = b.step("test-step-coverage", "Check every build step's work is run by something");
        if (violations > 0) {
            const message = std.fmt.allocPrint(b.allocator, "step coverage: {d} problem(s)\n{s}\nRun the step from scripts/verify.sh, a CI workflow, or `zig build test`; or add a row to scripts/manual-steps.allow with the reason a human asks for it.", .{ violations, report.items }) catch @panic("OOM");
            step_coverage_step.dependOn(&b.addFail(message).step);
        } else {
            const ok = b.addSystemCommand(&.{ "/bin/echo", b.fmt("step coverage: OK ({d} steps, {d} run by hand with a stated reason)", .{ step_count, manual_rows }) });
            ok.has_side_effects = true;
            step_coverage_step.dependOn(&ok.step);
        }
        test_step.dependOn(step_coverage_step);
    }
}

/// Run `git rev-parse --short=12 HEAD` once at configure time so the
/// precompile binary can stamp embedded handlers with a real commit hash.
/// Returns null on any failure (missing git, detached worktree, snapshot
/// tarball with no .git directory). The caller treats null as "fall back to
/// the precompile sentinel" rather than failing the build.
/// Attach the `embedded_handler` stub that every runtime-rooted test and bench
/// target needs. A production build replaces this import with the precompiled
/// handler bytecode (`-Dhandler`); a test build has no handler, so it resolves
/// to the stub. The `zts` module must be the one matching the target's optimize
/// mode, or the module graph collides (see the zts_bench_dep comment).
fn attachEmbeddedHandlerStub(
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

fn detectGitCommit(b: *std.Build) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .cwd = if (b.build_root.path) |p| .{ .path = p } else .inherit,
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}

fn addExpertGolden(
    b: *std.Build,
    step: *std.Build.Step,
    zts_exe: *std.Build.Step.Compile,
    args: []const []const u8,
    golden_rel: []const u8,
    expected_exit: u8,
) void {
    addExpertRun(b, step, zts_exe, args, expected_exit, golden_rel);
}

/// Version-agnostic golden for `meta --json`. The command's first field is
/// `compiler_version`, which changes every release; matching the whole line
/// byte-for-byte pinned it and made the fixture stale on each version bump.
/// Instead assert the version-independent tail (from `,"policy_version"` to the
/// end) byte-exactly, plus that a `compiler_version` field is present. The
/// golden's stored version value is therefore illustrative, not compared.
fn addExpertMetaGolden(
    b: *std.Build,
    step: *std.Build.Step,
    zts_exe: *std.Build.Step.Compile,
    golden_rel: []const u8,
) void {
    const golden = b.build_root.handle.readFileAlloc(b.graph.io, golden_rel, b.allocator, .unlimited) catch |err| {
        std.debug.panic("missing expert golden fixture {s}: {s}", .{ golden_rel, @errorName(err) });
    };
    const marker = ",\"policy_version\":";
    const idx = std.mem.indexOf(u8, golden, marker) orelse
        std.debug.panic("meta golden {s} is missing the {s} field", .{ golden_rel, marker });
    const version_independent_tail = golden[idx..];

    const run = b.addRunArtifact(zts_exe);
    run.addArgs(&.{ "meta", "--json" });
    run.expectExitCode(0);
    run.expectStdOutMatch("{\"compiler_version\":\"");
    run.expectStdOutMatch(version_independent_tail);
    step.dependOn(&run.step);
}

/// When `golden_rel` is null, only the exit code is asserted — help/error
/// text is not part of the contract, so editorial changes don't break the
/// build.
fn addExpertExitCheck(
    b: *std.Build,
    step: *std.Build.Step,
    zts_exe: *std.Build.Step.Compile,
    args: []const []const u8,
    expected_exit: u8,
) void {
    addExpertRun(b, step, zts_exe, args, expected_exit, null);
}

fn addExpertRun(
    b: *std.Build,
    step: *std.Build.Step,
    zts_exe: *std.Build.Step.Compile,
    args: []const []const u8,
    expected_exit: u8,
    golden_rel: ?[]const u8,
) void {
    const run = b.addRunArtifact(zts_exe);
    run.addArgs(args);
    run.expectExitCode(expected_exit);
    // Zig 0.16's run-step still fails non-zero commands that write to stderr
    // unless a stderr check exists. Matching the empty string keeps the
    // contract at "only the exit code matters" for exit-only checks.
    if (golden_rel == null and expected_exit != 0) {
        run.expectStdErrMatch("");
    }
    if (golden_rel) |rel| {
        const expected = b.build_root.handle.readFileAlloc(b.graph.io, rel, b.allocator, .unlimited) catch |err| {
            std.debug.panic("missing expert golden fixture {s}: {s}", .{ rel, @errorName(err) });
        };
        // Declare the fixture as an input so editing it invalidates the run
        // step's cache. Without this the step reports success from a cached
        // result and the gate silently stops comparing: verified by tampering
        // with a golden and watching the check still pass.
        run.expectStdOutEqual(expected);
    }
    step.dependOn(&run.step);
}

/// Collect every step reachable from `root`, including `root` itself.
fn collectReachable(
    root: *std.Build.Step,
    seen: *std.AutoHashMap(*std.Build.Step, void),
) void {
    if (seen.contains(root)) return;
    seen.put(root, {}) catch @panic("OOM");
    for (root.dependencies.items) |dep| collectReachable(dep, seen);
}

/// A `scripts/....sh` path named in a Run step's literal argv, if any.
///
/// Several build steps only wrap a shell gate, and `scripts/verify.sh` runs
/// some of those scripts directly rather than through `zig build <step>`. The
/// work is done either way, so the coverage question is about the script, not
/// about which Run step instance executed it.
fn runStepScript(step: *std.Build.Step) ?[]const u8 {
    const run = step.cast(std.Build.Step.Run) orelse return null;
    for (run.argv.items) |arg| {
        switch (arg) {
            .bytes => |text| {
                if (std.mem.startsWith(u8, text, "scripts/") and
                    std.mem.endsWith(u8, text, ".sh")) return text;
            },
            else => {},
        }
    }
    return null;
}

/// True when `verify.sh` runs `zig build <name>`.
fn verifyInvokes(verify_src: []const u8, name: []const u8, buf: []u8) bool {
    const needle = std.fmt.bufPrint(buf, "zig build {s}", .{name}) catch return false;
    var rest = verify_src;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        // The name must not be a prefix of a longer step name: `zig build test`
        // must not answer for `zig build test-zruntime`.
        const after = rest[idx + needle.len ..];
        const terminated = after.len == 0 or after[0] == ' ' or after[0] == '\n' or after[0] == '\r';
        if (terminated) return true;
        rest = after;
    }
    return false;
}

/// True when `allow_src` has a row whose first field is `name`.
fn allowNames(allow_src: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, allow_src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (std.mem.eql(u8, first, name)) return true;
    }
    return false;
}
