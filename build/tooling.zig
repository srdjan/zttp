//! Repository-only executables and their tests: release provenance, coverage
//! union, the release passport, the branch metric,
//! the stand-in author, native gates, and the reach measurement. None
//! of them is installed.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    repo_gate_exe: *std.Build.Step.Compile,
    zts_graph_gate_exe: *std.Build.Step.Compile,
    native_gate_test_step: *std.Build.Step,
    evidence_marker_tests: *std.Build.Step.Compile,
    evidence_publish_exe: *std.Build.Step.Compile,
    run_evidence_publish_tests: *std.Build.Step.Run,
    run_release_provenance_tests: *std.Build.Step.Run,
    run_coverage_union_tests: *std.Build.Step.Run,
    run_release_check_tests: *std.Build.Step.Run,
    production_branch_metric_test_step: *std.Build.Step,
    standin_exe: *std.Build.Step.Compile,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const optimize = ctx.optimize;
    const test_filters = ctx.test_filters;
    const zts_host_mod = ctx.zts_host_mod;
    const pi_host_dep = ctx.pi_host_dep;

    const repo_gate_mod = b.createModule(.{
        .root_source_file = b.path("tooling/repo_gate.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const repo_gate_exe = b.addExecutable(.{ .name = "repo-gate", .root_module = repo_gate_mod });
    const repo_gate_tests = ctx.addTest(.{ .root_module = repo_gate_mod });
    const run_repo_gate_tests = ctx.addRunTest(repo_gate_tests);
    const graph_gate_mod = b.createModule(.{
        .root_source_file = b.path("tooling/zts_graph_gate.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const zts_graph_gate_exe = b.addExecutable(.{ .name = "zts-graph-gate", .root_module = graph_gate_mod });
    const graph_gate_tests = ctx.addTest(.{ .root_module = graph_gate_mod });
    const run_graph_gate_tests = ctx.addRunTest(graph_gate_tests);
    const native_gate_test_step = b.step("test-native-gates", "Run native repository gate tests");
    native_gate_test_step.dependOn(&run_repo_gate_tests.step);
    native_gate_test_step.dependOn(&run_graph_gate_tests.step);

    // Separate gate processes inherit the same redirected stdout descriptor.
    // A positional writer would erase the prefix or the preceding verdict.
    const stream_probe = b.addSystemCommand(&.{
        "/bin/sh",                  "-c",
        \\set -eu
        \\probe_file=$(mktemp)
        \\trap 'rm -f "$probe_file"' EXIT
        \\{ printf 'native gate prefix\n'; "$1" release-workflow scripts/release.sh; "$2" layering; } > "$probe_file"
        \\test "$(head -n 1 "$probe_file")" = 'native gate prefix'
        \\test "$(grep -c '^release script: ' "$probe_file")" -eq 1
        \\test "$(grep -c '^zts layering: OK ' "$probe_file")" -eq 1
        \\printf 'native gate stream probe: earlier output and both verdicts preserved\n'
        ,
        "native-gate-stream-probe",
    });
    stream_probe.addArtifactArg(repo_gate_exe);
    stream_probe.addArtifactArg(zts_graph_gate_exe);
    stream_probe.setCwd(b.path("."));
    stream_probe.has_side_effects = true;
    native_gate_test_step.dependOn(&stream_probe.step);

    const routes_mod = b.createModule(.{ .root_source_file = b.path("tooling/verification_routes.zig"), .target = b.graph.host, .optimize = optimize });
    const route_tests = ctx.addTest(.{ .root_module = routes_mod });
    const run_route_tests = ctx.addRunTest(route_tests);
    run_route_tests.setCwd(b.path("."));
    run_route_tests.setEnvironmentVariable("ZTTP_ZIG_EXE", b.graph.zig_exe);
    native_gate_test_step.dependOn(&run_route_tests.step);
    const verify_exe = b.addExecutable(.{
        .name = "verify",
        .root_module = b.createModule(.{ .root_source_file = b.path("tooling/verify.zig"), .target = b.graph.host, .optimize = optimize }),
    });
    const verify_run = b.addRunArtifact(verify_exe);
    verify_run.addArg(b.graph.zig_exe);
    verify_run.setCwd(b.path("."));
    verify_run.has_side_effects = true;
    verify_run.addPassthruArgs();
    b.step("verify", "Run the sequential local verification driver").dependOn(&verify_run.step);

    // Release evidence parsing and rendering stay in repository-only native
    // commands. The publication shells keep the stable entry-point names.
    const evidence_marker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tooling/evidence_marker.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const evidence_publish_mod = b.createModule(.{
        .root_source_file = b.path("tooling/evidence_publish.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const evidence_publish_exe = b.addExecutable(.{
        .name = "evidence-publish",
        .root_module = evidence_publish_mod,
    });
    const evidence_publish_cmd = b.addRunArtifact(evidence_publish_exe);
    evidence_publish_cmd.has_side_effects = true;
    evidence_publish_cmd.addPassthruArgs();
    const evidence_publish_step = b.step("evidence-publish", "Render validated release evidence");
    evidence_publish_step.dependOn(&evidence_publish_cmd.step);
    const evidence_publish_tests = ctx.addTest(.{ .root_module = evidence_publish_mod });
    const run_evidence_publish_tests = ctx.addRunTest(evidence_publish_tests);
    const evidence_publish_test_step = b.step("test-evidence-publish", "Run native evidence publisher tests");
    evidence_publish_test_step.dependOn(&run_evidence_publish_tests.step);

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
    const release_provenance_tests = ctx.addTest(.{
        .filters = test_filters,
        .root_module = release_provenance_mod,
    });
    const run_release_provenance_tests = ctx.addRunTest(release_provenance_tests);
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
    coverage_union_cmd.addPassthruArgs();
    const coverage_union_step = b.step("coverage-union", "Union the tripped rules across published runs of one corpus identity");
    coverage_union_step.dependOn(&coverage_union_cmd.step);
    const coverage_union_tests = ctx.addTest(.{
        .filters = test_filters,
        .root_module = coverage_union_mod,
    });
    const run_coverage_union_tests = ctx.addRunTest(coverage_union_tests);
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
    release_check_cmd.addPassthruArgs();
    const release_check_step = b.step("release-check", "Print this repository's release-readiness passport");
    release_check_step.dependOn(&release_check_cmd.step);

    const release_check_tests = ctx.addTest(.{ .filters = test_filters, .root_module = release_check_mod });
    const run_release_check_tests = ctx.addRunTest(release_check_tests);
    // The repository-version test reads README.md, VERSION, and the package
    // manifests by relative path, so it must run from the repository root
    // whatever directory the invoker used.
    run_release_check_tests.setCwd(b.path("."));
    const release_check_test_step = b.step("test-release-check", "Run release-passport tests");
    release_check_test_step.dependOn(&run_release_check_tests.step);

    // Repository-only AST metric. The live command receives the tracked Zig
    // source list from a NUL-safe script; its unit tests pin the AST definition
    // and its input floors. It is never installed in user projects.
    const production_branch_metric_mod = b.createModule(.{
        .root_source_file = b.path("tooling/production_branch_metric.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const production_branch_metric_tests = ctx.addTest(.{
        .filters = test_filters,
        .root_module = production_branch_metric_mod,
    });
    const run_production_branch_metric_tests = ctx.addRunTest(production_branch_metric_tests);
    const production_branch_metric = ctx.addGate(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh" }, "production-branch-metric", "Measure production branch points in tracked Zig sources");
    _ = ctx.addGate(&.{ "/bin/bash", "scripts/run-production-branch-metric.sh", "--json" }, "production-branch-metric-json", "Measure production branch points as JSON");
    const production_branch_metric_test_step = b.step("test-production-branch-metric", "Test and run the production branch metric");
    production_branch_metric_test_step.dependOn(&run_production_branch_metric_tests.step);
    production_branch_metric_test_step.dependOn(&production_branch_metric.run.step);

    // Development-only deterministic author. It speaks non-streaming Chat
    // Completions on loopback and is never part of the install step.
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
    standin_cmd.addPassthruArgs();
    const standin_step = b.step("zttp-standin", "Run the deterministic playbook server");
    standin_step.dependOn(&standin_cmd.step);

    return .{
        .repo_gate_exe = repo_gate_exe,
        .zts_graph_gate_exe = zts_graph_gate_exe,
        .native_gate_test_step = native_gate_test_step,
        .evidence_marker_tests = evidence_marker_tests,
        .evidence_publish_exe = evidence_publish_exe,
        .run_evidence_publish_tests = run_evidence_publish_tests,
        .run_release_provenance_tests = run_release_provenance_tests,
        .run_coverage_union_tests = run_coverage_union_tests,
        .run_release_check_tests = run_release_check_tests,
        .production_branch_metric_test_step = production_branch_metric_test_step,
        .standin_exe = standin_exe,
    };
}
