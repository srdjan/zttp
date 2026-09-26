//! Build graph for zttp. Each part lives in build/*.zig; this file calls them
//! in order and assembles the aggregate `test` step.
//!
//! The call order is the order `zig build -l` lists the steps, and
//! build/step_coverage.zig must run last because it walks every top-level
//! step. build/Context.zig holds the `-D` options and package dependencies.

const std = @import("std");
const Context = @import("build/Context.zig");
const packages = @import("build/packages.zig");
const proof_gates = @import("build/proof_gates.zig");
const host_tests = @import("build/host_tests.zig");
const repo_gates = @import("build/repo_gates.zig");
const tooling = @import("build/tooling.zig");
const artifacts = @import("build/artifacts.zig");
const wasm = @import("build/wasm.zig");
const goldens = @import("build/goldens.zig");
const runtime_tests = @import("build/runtime_tests.zig");
const bench = @import("build/bench.zig");
const smoke = @import("build/smoke.zig");
const step_coverage = @import("build/step_coverage.zig");

pub fn build(b: *std.Build) void {
    const ctx = Context.init(b);

    const pkgs = packages.add(ctx);
    const proofs = proof_gates.add(ctx, pkgs);
    const host_test_runs = host_tests.add(ctx, proofs);
    const capability_audit = repo_gates.addCapabilityAudit(ctx);
    const tools = tooling.add(ctx);
    const gates = repo_gates.add(ctx, tools);
    const bins = artifacts.add(ctx, gates);
    const wasm_publish_test_step = wasm.add(ctx);
    const golden = goldens.add(ctx, bins);
    artifacts.addRunSteps(ctx, bins);
    const unit = runtime_tests.addUnit(ctx, proofs.invariant_drift_step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&unit.run_unit_tests.step);
    test_step.dependOn(&unit.run_cli_tests.step);
    // Every host test root from the table in build/host_tests.zig.
    for (host_test_runs) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&capability_audit.step);
    test_step.dependOn(&gates.module_boundary.step);
    test_step.dependOn(&gates.release_workflow.step);
    test_step.dependOn(&gates.proof_swallow.step);
    test_step.dependOn(&proofs.residual_guards_drift.step);
    test_step.dependOn(proofs.invariant_drift_step);
    test_step.dependOn(&gates.zts_layering.step);
    test_step.dependOn(&tools.run_release_check_tests.step);
    test_step.dependOn(&tools.run_release_provenance_tests.step);
    test_step.dependOn(&tools.run_coverage_union_tests.step);
    test_step.dependOn(&tools.run_demo_passport_check_tests.step);
    test_step.dependOn(wasm_publish_test_step);
    test_step.dependOn(tools.production_branch_metric_test_step);
    test_step.dependOn(golden.comptime_cli_step);
    test_step.dependOn(golden.generic_intersection_cli_step);
    // `zttp-standin` is deliberately not installed, so nothing else forces it
    // to compile and a break in that path would surface only when somebody ran
    // the step by hand. Compile it here, without installing it.
    test_step.dependOn(&tools.standin_exe.step);
    // The docs drift and link gates run here, and only here: neither Run step is
    // cached, so `zig build test` always executes both scripts. CI and
    // scripts/verify.sh deliberately do not invoke test-docs-drift or
    // test-doc-links a second time.
    test_step.dependOn(gates.docs_drift_step);
    test_step.dependOn(&gates.doc_links.step);
    test_step.dependOn(&gates.convergence_emitter.step);
    test_step.dependOn(&gates.evidence_marker.step);
    test_step.dependOn(&gates.expert_qualification_boundary.step);
    test_step.dependOn(&golden.run_module_governance.step);
    test_step.dependOn(pkgs.zts_test_step);
    test_step.dependOn(&pkgs.run_sdk_tests.step);
    test_step.dependOn(&pkgs.run_modules_tests.step);
    test_step.dependOn(&proofs.run_proof_review_pkg_tests.step);
    test_step.dependOn(&pkgs.run_proof_checker_tests.step);
    test_step.dependOn(&proofs.run_proof_ratchet_tests.step);
    test_step.dependOn(&proofs.proof_ratchet_drift.step);
    test_step.dependOn(&proofs.proof_checker_purity.step);
    test_step.dependOn(&proofs.diagnostic_producers.step);
    test_step.dependOn(&proofs.script_reachability.step);
    test_step.dependOn(golden.expert_golden_step);
    test_step.dependOn(golden.contract_golden_step);
    test_step.dependOn(&bins.runtime_purity_cmd.step);

    runtime_tests.addIntegration(ctx, bins, test_step);

    // Release build step (with handler precompilation if provided)
    const release_step = b.step("release", "Build optimized release binaries (zttp, zttp-runtime, zts)");
    release_step.dependOn(b.getInstallStep());
    const bench_exe = bench.addRuntimeBench(ctx, test_step);
    smoke.add(ctx);
    bench.addCompileBench(ctx, test_step, bench_exe);
    artifacts.addSystemLink(ctx, bins);

    step_coverage.add(b, test_step);
}
