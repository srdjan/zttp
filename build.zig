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
const corpus = @import("build/corpus.zig");
const flow_census = @import("build/flow_census.zig");
const tooling = @import("build/tooling.zig");
const artifacts = @import("build/artifacts.zig");
const goldens = @import("build/goldens.zig");
const runtime_tests = @import("build/runtime_tests.zig");
const bench = @import("build/bench.zig");
const smoke = @import("build/smoke.zig");
const step_coverage = @import("build/step_coverage.zig");
const agent_spine = @import("build/agent_spine.zig");

pub fn build(b: *std.Build) void {
    const ctx = Context.init(b);

    const pkgs = packages.add(ctx);
    const tools = tooling.add(ctx);
    const proofs = proof_gates.add(ctx, tools);
    const host = host_tests.add(ctx, proofs);
    const diagnostic_corpus = corpus.add(ctx);
    const flow_census_gate = flow_census.add(ctx);
    const capability_audit = repo_gates.addCapabilityAudit(ctx);
    const gates = repo_gates.add(ctx, tools);
    const gate_floor_probe = repo_gates.addGateFloorProbe(ctx, gates.kernel_safety_gate);
    capability_audit.step.dependOn(&gate_floor_probe.step);
    gates.docs_drift_step.dependOn(&gate_floor_probe.step);
    const bins = artifacts.add(ctx, gates);
    const golden = goldens.add(ctx, bins);
    artifacts.addRunSteps(ctx, bins);
    const unit = runtime_tests.addUnit(ctx);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&unit.run_unit_tests.step);
    test_step.dependOn(&unit.run_cli_tests.step);
    // Enclosing host roots cover the focused subsets listed in host_tests.zig.
    for (host.runs) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&capability_audit.step);
    test_step.dependOn(gates.kernel_safety_step);
    test_step.dependOn(&gates.module_boundary.step);
    test_step.dependOn(&gates.release_workflow.step);
    test_step.dependOn(&gates.proof_swallow.step);
    test_step.dependOn(&proofs.residual_guards_drift.step);
    test_step.dependOn(&gates.zts_layering.step);
    test_step.dependOn(&tools.run_release_check_tests.step);
    test_step.dependOn(&tools.run_evidence_publish_tests.step);
    test_step.dependOn(tools.native_gate_test_step);
    test_step.dependOn(&tools.run_release_provenance_tests.step);
    test_step.dependOn(&tools.run_coverage_union_tests.step);
    test_step.dependOn(tools.production_branch_metric_test_step);
    test_step.dependOn(golden.generic_intersection_cli_step);
    // `zttp-standin` is deliberately not installed, so nothing else forces it
    // to compile and a break in that path would surface only when somebody ran
    // the step by hand. Compile it here, without installing it.
    test_step.dependOn(&tools.standin_exe.step);
    // The docs drift and link gates run here, and only here: neither Run step is
    // cached, so `zig build test` always executes both scripts.
    // scripts/verify.sh deliberately does not invoke test-docs-drift or
    // test-doc-links a second time.
    test_step.dependOn(gates.docs_drift_step);
    test_step.dependOn(&gates.doc_links.step);
    test_step.dependOn(&gates.idiom_table.step);
    test_step.dependOn(&gates.canonical_style.step);
    test_step.dependOn(&gates.grammar_drift.step);
    test_step.dependOn(&gates.decision_registry.step);
    test_step.dependOn(&gates.meta_drift.step);
    test_step.dependOn(&gates.agent_determinism.step);
    test_step.dependOn(&gates.convergence_emitter.step);
    test_step.dependOn(&gates.evidence_marker.step);
    test_step.dependOn(&golden.run_module_governance.step);
    test_step.dependOn(pkgs.zts_test_step);
    test_step.dependOn(&pkgs.run_sdk_tests.step);
    test_step.dependOn(&pkgs.run_modules_tests.step);
    test_step.dependOn(&pkgs.run_proof_checker_tests.step);
    test_step.dependOn(&proofs.run_proof_ratchet_tests.step);
    test_step.dependOn(&proofs.proof_ratchet_drift.step);
    test_step.dependOn(&proofs.proof_checker_purity.step);
    test_step.dependOn(&proofs.diagnostic_producers.step);
    test_step.dependOn(diagnostic_corpus.step);
    test_step.dependOn(flow_census_gate.step);
    test_step.dependOn(&proofs.script_reachability.step);
    test_step.dependOn(golden.expert_golden_step);
    test_step.dependOn(golden.contract_golden_step);
    test_step.dependOn(&bins.runtime_purity_cmd.step);

    runtime_tests.addIntegration(ctx, bins, test_step);
    // addIntegration registers test-examples, so the lookup must follow it.
    const examples_step = b.top_level_steps.get("test-examples") orelse @panic("runtime_tests.addIntegration registers test-examples");
    examples_step.step.dependOn(&gate_floor_probe.step);

    // Release build step (with handler precompilation if provided)
    const release_step = b.step("release", "Build optimized release binaries (zttp, zttp-runtime, zts)");
    release_step.dependOn(b.getInstallStep());
    const bench_exe = bench.addRuntimeBench(ctx, test_step);
    smoke.add(ctx);
    bench.addCompileBench(ctx, test_step, bench_exe);

    const spine = agent_spine.add(ctx);
    test_step.dependOn(spine.check_step);
    test_step.dependOn(spine.test_step);
    const coverage_step = step_coverage.register(b);
    step_coverage.attachScriptCensus(b, test_step, proofs.script_reachability, tools.repo_gate_exe);
    agent_spine.attachTaskCensus(b, spine);
    step_coverage.add(b, test_step, coverage_step);
    const test_selection = @import("build/test_selection.zig");
    if (ctx.test_filters.len == 0) {
        // A fixed filter such as the stand-in suite's must also select a test.
        test_selection.attach(b, tools.repo_gate_exe, ctx.test_selections.items, false);
    } else {
        // An aggregate with filtered roots cannot establish its advertised
        // invariants. Retain useful filtering only on explicitly named suites.
        test_step.dependencies.clearRetainingCapacity();
        test_step.dependOn(&b.addFail("test rejects -Dtest-filter; use a named test suite for developer selection").step);
        test_selection.attach(b, tools.repo_gate_exe, ctx.test_selections.items, true);
    }
}
