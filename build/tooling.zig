//! Repository-only executables and their tests: release provenance, coverage
//! union, the release passport, the proof-passport checker, the branch metric,
//! the stand-in author, expert qualification, and the reach measurement. None
//! of them is installed.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    run_release_provenance_tests: *std.Build.Step.Run,
    run_coverage_union_tests: *std.Build.Step.Run,
    run_release_check_tests: *std.Build.Step.Run,
    run_demo_passport_check_tests: *std.Build.Step.Run,
    production_branch_metric_test_step: *std.Build.Step,
    standin_exe: *std.Build.Step.Compile,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const optimize = ctx.optimize;
    const test_filters = ctx.test_filters;
    const zts_host_mod = ctx.zts_host_mod;
    const pi_host_dep = ctx.pi_host_dep;

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

    // The coverage union across every published run of one corpus identity.
    // Zig rather than the python3 heredoc it replaces: AGENTS.md says existing
    // python is legacy to be removed as each area is touched, and this area was
    // touched because its first-run guard made publishing a new corpus identity
    // impossible.
    const coverage_union_mod = b.createModule(.{
        .root_source_file = b.path("tooling/coverage_union.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const coverage_union_exe = b.addExecutable(.{
        .name = "coverage-union",
        .root_module = coverage_union_mod,
    });
    const coverage_union_cmd = b.addRunArtifact(coverage_union_exe);
    coverage_union_cmd.has_side_effects = true;
    if (b.args) |args| coverage_union_cmd.addArgs(args);
    const coverage_union_step = b.step("coverage-union", "Union the tripped rules across published runs of one corpus identity");
    coverage_union_step.dependOn(&coverage_union_cmd.step);
    const coverage_union_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = coverage_union_mod,
    });
    const run_coverage_union_tests = b.addRunArtifact(coverage_union_tests);
    const coverage_union_test_step = b.step("test-coverage-union", "Run coverage-union tests");
    coverage_union_test_step.dependOn(&run_coverage_union_tests.step);

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
    const production_branch_metric = ctx.addGate(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh" }, "production-branch-metric", "Measure production branch points in tracked Zig sources");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh", "--json" }, "production-branch-metric-json", "Measure production branch points as JSON");
    const production_branch_metric_test_step = b.step("test-production-branch-metric", "Test and run the production branch metric");
    production_branch_metric_test_step.dependOn(&run_production_branch_metric_tests.step);
    production_branch_metric_test_step.dependOn(&production_branch_metric.run.step);

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

    // Repository-only reach measurement. A normal build or test never calls
    // a model; the executable requires an explicit live mode and confirmation.
    const reach_mod = b.createModule(.{
        .root_source_file = pi_host_dep.path("src/expert_reach_main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zts", .module = zts_host_mod },
            .{ .name = "zts_cli", .module = ctx.pi_zts_cli_host_mod },
            .{ .name = "project_config", .module = ctx.project_config_mod },
        },
    });
    const reach_exe = b.addExecutable(.{ .name = "provable-reach", .root_module = reach_mod });
    const reach_cmd = b.addRunArtifact(reach_exe);
    reach_cmd.has_side_effects = true;
    reach_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| reach_cmd.addArgs(args);
    b.step("provable-reach", "Run reference admission, offline smoke, or an authorized fresh reach measurement").dependOn(&reach_cmd.step);

    return .{
        .run_release_provenance_tests = run_release_provenance_tests,
        .run_coverage_union_tests = run_coverage_union_tests,
        .run_release_check_tests = run_release_check_tests,
        .run_demo_passport_check_tests = run_demo_passport_check_tests,
        .production_branch_metric_test_step = production_branch_metric_test_step,
        .standin_exe = standin_exe,
    };
}
