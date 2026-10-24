//! Gates over the acceptance kernel and the proof boundary: mutation probes,
//! kernel purity, the trusted-boundary ratchet, residual guards,
//! and the proof-review package tests.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    proof_checker_purity: *std.Build.Step.Run,
    script_reachability: *std.Build.Step.Run,
    diagnostic_producers: *std.Build.Step.Run,
    proof_ratchet_drift: *std.Build.Step.Run,
    residual_guards_drift: *std.Build.Step.Run,
    residual_guards_drift_step: *std.Build.Step,
    run_proof_ratchet_tests: *std.Build.Step.Run,
    run_proof_review_pkg_tests: *std.Build.Step.Run,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const test_filters = ctx.test_filters;
    const tools_dep = ctx.tools_dep;

    // Probe committed single-point mutations against a private copy of the
    // working tree. This gate is explicit because each row needs a fresh Zig
    // cache and the current suite has survivors that Phase 0 must pin.
    const proof_checker_mutants_mod = b.createModule(.{
        .root_source_file = tools_dep.path("src/proof_checker_mutants.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const proof_checker_mutants_exe = b.addExecutable(.{
        .name = "proof-checker-mutants",
        .root_module = proof_checker_mutants_mod,
    });
    const proof_checker_mutants_cmd = b.addRunArtifact(proof_checker_mutants_exe);
    proof_checker_mutants_cmd.addArg(b.graph.zig_exe);
    proof_checker_mutants_cmd.addDirectoryArg(ctx.proof_checker_dep.path(""));
    proof_checker_mutants_cmd.addFileArg(tools_dep.path("src/proof_checker_mutants.zon"));
    proof_checker_mutants_cmd.has_side_effects = true;
    const proof_checker_mutants_step = b.step("test-proof-checker-mutants", "Run the committed mutants against the acceptance kernel suite");
    proof_checker_mutants_step.dependOn(&proof_checker_mutants_cmd.step);

    // The kernel's own floor: the suite above reports a pass whether it
    // collected two hundred tests or none, so a separate gate asserts the
    // corpus is non-empty and the package still imports nothing.
    const proof_checker_purity = ctx.addGate(&.{ "bash", "scripts/check-proof-checker.sh" }, "test-proof-checker-purity", "Check the acceptance kernel is a leaf with a non-empty suite");
    proof_checker_purity.run.has_side_effects = true;

    // Every script in scripts/ must be invoked by something or say why not. A
    // gate nothing runs reports nothing, which reads the same as a gate that
    // found nothing - and scripts/test-zruntime.sh sat in the tree invoking a
    // root file that had been deleted, called by nobody.
    const script_reachability = ctx.addGate(&.{ "bash", "scripts/check-script-reachability.sh" }, "test-script-reachability", "Check every script in scripts/ is invoked or declared manual");
    script_reachability.run.has_side_effects = true;

    // Every advertised diagnostic variant must have a construction site. The
    // rule-coverage gate in packages/pi keys on `rule.code`, so a dead variant
    // sharing a code with a live producer is permanently satisfied and cannot
    // be reported - three did exactly that.
    const diagnostic_producers = ctx.addGate(&.{ "bash", "scripts/check-diagnostic-producers.sh" }, "test-diagnostic-producers", "Check every advertised diagnostic variant has a producer");
    diagnostic_producers.run.has_side_effects = true;

    // The published trusted boundary against the one the kernel implements.
    const proof_ratchet_drift = ctx.addGate(&.{ "bash", "scripts/check-proof-ratchet.sh" }, "test-proof-ratchet-drift", "Check the published trusted boundary against the kernel");
    proof_ratchet_drift.run.has_side_effects = true;

    // The residual-guard boundary: consumer catalog, compiler mirror, enabled
    // families, measured conversions, and published documentation.
    const residual_guards_drift = ctx.addGate(&.{ "bash", "scripts/check-residual-guards.sh" }, "test-residual-guards-drift", "Check residual guard catalogs, evidence, and docs");
    const residual_extract_mod = b.createModule(.{
        .root_source_file = b.path("scripts/residual_guard_extract.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    residual_extract_mod.addImport("residual", b.createModule(.{
        .root_source_file = b.path("packages/proof-checker/src/residual.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    residual_extract_mod.addImport("guard_catalog", b.createModule(.{
        .root_source_file = b.path("packages/zts/src/guard_catalog.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    const residual_extract = b.addExecutable(.{ .name = "residual-guard-extract", .root_module = residual_extract_mod });
    residual_guards_drift.run.addArtifactArg(residual_extract);
    residual_guards_drift.run.has_side_effects = true;

    // The trusted-boundary ratchet. Rooted at its own file because nothing in
    // the product imports it: it is a corpus plus assertions, and a file no
    // analyzed root reaches contributes no tests.
    const proof_ratchet_tests = ctx.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = ctx.runtime_dep.path("src/proof_ratchet.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zts", .module = ctx.zts_dep.module("zts") },
                .{ .name = "zts_cli", .module = ctx.zts_cli_mod },
                .{ .name = "zttp_proof_checker", .module = ctx.proofCheckerMod() },
                .{ .name = "project_config", .module = ctx.project_config_mod },
            },
        }),
    });
    const run_proof_ratchet_tests = ctx.addRunTest(proof_ratchet_tests);
    const proof_ratchet_step = b.step("test-proof-ratchet", "Check the disclosed trusted boundary against what the kernel re-derives");
    proof_ratchet_step.dependOn(&run_proof_ratchet_tests.step);

    // zttp proof-review package tests. Context.zig states why its dependency
    // carries perf_histogram.
    const proof_review_pkg_tests = ctx.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = ctx.proof_review_pkg_dep.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zts", .module = ctx.zts_dep.module("zts") },
                .{ .name = "zts_cli", .module = ctx.zts_cli_mod },
            },
        }),
    });
    const run_proof_review_pkg_tests = ctx.addRunTest(proof_review_pkg_tests);
    const proof_review_pkg_test_step = b.step("test-proof-review", "Run zttp proof-review package tests");
    proof_review_pkg_test_step.dependOn(&run_proof_review_pkg_tests.step);

    return .{
        .proof_checker_purity = proof_checker_purity.run,
        .script_reachability = script_reachability.run,
        .diagnostic_producers = diagnostic_producers.run,
        .proof_ratchet_drift = proof_ratchet_drift.run,
        .residual_guards_drift = residual_guards_drift.run,
        .residual_guards_drift_step = residual_guards_drift.step,
        .run_proof_ratchet_tests = run_proof_ratchet_tests,
        .run_proof_review_pkg_tests = run_proof_review_pkg_tests,
    };
}
