//! Host-side test roots for the tools and pi packages, and the explicit
//! real-model MLX gate.

const std = @import("std");
const Context = @import("Context.zig");
const proof_gates = @import("proof_gates.zig");

pub const HostTestRoot = struct {
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
    needs_install: bool = false,
};

// Host-side test roots for the tools and pi packages. Roots that differ only
// in source file, step name, description, and which extra modules they
// import, so they are declared as data and built in one loop.
//
// Several exist because their file is only reached through a *named module*
// (`zts_cli`), which is never an addTest root, so no other suite collects
// their `test {}` blocks. Rooting at the file directly is the only way they
// run at all; see the `collected_via_named_module` note on each entry.
//
// scripts/check-docs-drift.sh reads the step names out of this table and
// holds docs/internals/testing.md to them.
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
    .{ .owner = .tools, .src = "src/vocab_envelope.zig", .step = "test-vocab-envelope", .desc = "Run published vocabulary envelope derivation tests" },
    .{ .owner = .tools, .src = "src/instruction_counter.zig", .step = "test-instruction-counter", .desc = "Run retired-instruction counter tests" },
    .{ .owner = .pi, .src = "src/tests.zig", .step = "test-expert-app", .desc = "Run zts expert in-process app tests", .project_config = true, .pi_modules = true, .needs_install = true },
    .{ .owner = .pi, .src = "src/expert_reach_tests.zig", .step = "test-provable-reach", .desc = "Check bounded reach admission and report integrity (offline)", .project_config = true, .pi_modules = true, .needs_install = true },
    // Focused subset covering only the record/replay layer: runs offline,
    // never needs an API key, and does not transitively pull in the
    // tools/skills tests, so it stays fast.
    .{ .owner = .pi, .src = "src/cassette_tests.zig", .step = "test-cassette", .desc = "Run pi provider cassette harness tests (offline)", .project_config = true, .pi_modules = true },
    .{ .owner = .pi, .src = "src/simulator_tests.zig", .step = "test-simulator", .desc = "Run fail-closed full-flow simulator tests (offline)", .project_config = true, .pi_modules = true },
    .{ .owner = .pi, .src = "src/standin_tests.zig", .step = "test-standin", .desc = "Run the deterministic stand-in through the real expert loop", .project_config = true, .pi_modules = true, .standin_only = true },
};

pub const Result = struct {
    /// The Run step of each root, in table order, for the aggregate `test` step.
    runs: [host_test_roots.len]*std.Build.Step.Run,
    /// The `test-project-config` root, evidence for the invariant drift gate.
    project_config: *std.Build.Step.Run,
};

/// Build every root in `host_test_roots` and the MLX gate.
pub fn add(ctx: Context, gates: proof_gates.Result) Result {
    const b = ctx.b;
    const optimize = ctx.optimize;
    const residual_guards_drift_step = gates.residual_guards_drift_step;

    const standin_range_doc = b.addOptions();
    standin_range_doc.addOption(
        []const u8,
        "contents",
        @embedFile("../packages/pi/docs/standin-range.md"),
    );

    // The accounting list behind docs/coverage.md's unseeded remainder. Kept as
    // a text file rather than a Zig table so it reads like the repository's
    // other allowlists, and reaches the gate the same way the range document
    // does.
    const unseeded_rules = b.addOptions();
    unseeded_rules.addOption(
        []const u8,
        "contents",
        @embedFile("../scripts/unseeded-rules.allow"),
    );

    var host_test_runs: [host_test_roots.len]*std.Build.Step.Run = undefined;
    var project_config_run: ?*std.Build.Step.Run = null;
    for (host_test_roots, 0..) |root, i| {
        const owner_dep = switch (root.owner) {
            .tools => ctx.tools_dep,
            .pi => ctx.pi_dep,
        };
        const tests = b.addTest(.{
            .filters = if (root.standin_only) &.{"stand-in"} else ctx.test_filters,
            .root_module = b.createModule(.{
                .root_source_file = owner_dep.path(root.src),
                .target = b.graph.host,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        tests.root_module.addImport("zts", ctx.zts_host_mod);
        // The acceptance kernel is a leaf and takes no options, so wiring it
        // into every host root costs nothing and keeps the table free of a flag
        // that would need updating each time a file starts naming it.
        tests.root_module.addImport("zttp_proof_checker", ctx.proofCheckerMod());
        if (root.project_config) tests.root_module.addImport("project_config", ctx.project_config_mod);
        if (root.pi_modules) {
            tests.root_module.addImport("zts_cli", ctx.pi_zts_cli_host_mod);
        }
        if (root.standin_only) tests.root_module.addOptions("standin_range_doc", standin_range_doc);
        if (root.standin_only) tests.root_module.addOptions("unseeded_rules", unseeded_rules);
        host_test_runs[i] = b.addRunArtifact(tests);
        if (root.needs_install) {
            host_test_runs[i].step.dependOn(b.getInstallStep());
        }
        b.step(root.step, root.desc).dependOn(&host_test_runs[i].step);
        // The residual gate's source comparison is useful only if its
        // behavioral evidence compiles and runs. Keep that dependency on the
        // named gate so a broken probe cannot be reported as guard agreement.
        if (root.standin_only) residual_guards_drift_step.dependOn(&host_test_runs[i].step);
        if (std.mem.eql(u8, root.step, "test-project-config")) {
            project_config_run = host_test_runs[i];
        }
    }

    // Explicit real-model gate. It is intentionally absent from the aggregate
    // test step because zttp never manages the developer's MLX server.
    const mlx_e2e_tests = b.addTest(.{
        .filters = &.{"local MLX expert flow"},
        .root_module = b.createModule(.{
            .root_source_file = ctx.pi_host_dep.path("src/mlx_e2e_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }),
        .test_runner = .{
            .path = ctx.pi_host_dep.path("src/mlx_e2e_runner.zig"),
            .mode = .simple,
        },
    });
    mlx_e2e_tests.root_module.addImport("zts", ctx.zts_host_mod);
    mlx_e2e_tests.root_module.addImport("project_config", ctx.project_config_mod);
    mlx_e2e_tests.root_module.addImport("zts_cli", ctx.pi_zts_cli_host_mod);
    const run_mlx_e2e_tests = b.addRunArtifact(mlx_e2e_tests);
    const mlx_e2e_step = b.step("test-expert-mlx-e2e", "Run the real local MLX expert flow");
    mlx_e2e_step.dependOn(&run_mlx_e2e_tests.step);

    return .{
        .runs = host_test_runs,
        .project_config = project_config_run orelse @panic("host_test_roots has no test-project-config row"),
    };
}
