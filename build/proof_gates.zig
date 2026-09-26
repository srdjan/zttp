//! Gates over the acceptance kernel and the proof boundary: mutation probes,
//! kernel purity, the trusted-boundary ratchet, residual guards, invariant and
//! vocabulary drift, and the proof-review package tests.

const std = @import("std");
const Context = @import("Context.zig");
const packages = @import("packages.zig");

pub const Result = struct {
    proof_checker_purity: *std.Build.Step.Run,
    script_reachability: *std.Build.Step.Run,
    diagnostic_producers: *std.Build.Step.Run,
    proof_ratchet_drift: *std.Build.Step.Run,
    residual_guards_drift: *std.Build.Step.Run,
    residual_guards_drift_step: *std.Build.Step,
    invariant_drift_step: *std.Build.Step,
    run_proof_ratchet_tests: *std.Build.Step.Run,
    run_proof_review_pkg_tests: *std.Build.Step.Run,
};

pub fn add(ctx: Context, pkgs: packages.Result) Result {
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
    residual_guards_drift.run.has_side_effects = true;

    // Application-invariant drift is useful only with compiled evidence from
    // the kernel, compiler, protected native module, and runtime observer.
    //
    // The gate is a host Zig command. It imports the surfaces that are data -
    // the kernel operation catalog, the kind table, the linked native binding,
    // and the authoring renderer - and text-scans only the surfaces that are
    // code, because there is no regex in Zig and a typed import cannot be
    // misparsed.
    //
    // `has_side_effects` is load-bearing. A Run step is cached on its
    // executable and its arguments, never on the files the program reads at
    // run time, so without this the gate reports a cached pass after
    // docs/verification.md changes and stops noticing drift.
    const invariant_gate_mod = b.createModule(.{
        .root_source_file = tools_dep.path("src/invariant_drift_gate.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    invariant_gate_mod.addImport("zts", ctx.zts_host_mod);
    invariant_gate_mod.addImport("zttp_proof_checker", ctx.proofCheckerMod());
    const invariant_gate_exe = b.addExecutable(.{
        .name = "invariant-drift-gate",
        .root_module = invariant_gate_mod,
    });
    const invariant_gate_cmd = b.addRunArtifact(invariant_gate_exe);
    invariant_gate_cmd.has_side_effects = true;
    const invariant_drift_step = b.step("test-invariant-drift", "Check invariant catalogs, compiled evidence, and docs");
    invariant_drift_step.dependOn(&invariant_gate_cmd.step);
    invariant_drift_step.dependOn(&pkgs.run_proof_checker_tests.step);
    invariant_drift_step.dependOn(&pkgs.run_modules_tests.step);

    // The published vocabulary envelope and its drift gate: producer obligation
    // P1. Section 6 of docs/consumer-contract.md states sixteen closed alphabets
    // as literal counts in prose. Three review rounds verified them by hand and
    // each found counts that had drifted. This compares them mechanically.
    const vocab_envelope_mod = b.createModule(.{
        .root_source_file = tools_dep.path("src/vocab_envelope_gate.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    vocab_envelope_mod.addImport("zts", ctx.zts_host_mod);
    vocab_envelope_mod.addImport("zttp_proof_checker", ctx.proofCheckerMod());
    const vocab_envelope_exe = b.addExecutable(.{
        .name = "vocab-envelope-gate",
        .root_module = vocab_envelope_mod,
    });
    const vocab_envelope_check = b.addRunArtifact(vocab_envelope_exe);
    vocab_envelope_check.addArg("--check");
    vocab_envelope_check.has_side_effects = true;
    const vocab_envelope_step = b.step("test-vocab-envelope-drift", "Check the published vocabulary envelope against the tree");
    vocab_envelope_step.dependOn(&vocab_envelope_check.step);

    // A probe is code: one that does not compile runs no check, and a failed
    // build and a passing gate both emit no failure message. The gate's own
    // tests hang off the same named step for that reason.
    const vocab_envelope_gate_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = vocab_envelope_mod,
    });
    const run_vocab_envelope_gate_tests = b.addRunArtifact(vocab_envelope_gate_tests);
    vocab_envelope_step.dependOn(&run_vocab_envelope_gate_tests.step);

    const vocab_envelope_write = b.addRunArtifact(vocab_envelope_exe);
    vocab_envelope_write.addArgs(&.{ "--out", "docs/consumer-contract-envelope.json" });
    vocab_envelope_write.has_side_effects = true;
    const vocab_envelope_write_step = b.step("vocab-envelope-write", "Regenerate the published vocabulary envelope");
    vocab_envelope_write_step.dependOn(&vocab_envelope_write.step);
    invariant_drift_step.dependOn(pkgs.zts_test_step);

    // A probe is code. One that does not compile runs no check, and a failed
    // build and a passing gate both emit no failure message, so the gate's own
    // unit tests hang off the same named step as the gate.
    const invariant_gate_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = invariant_gate_mod,
    });
    const run_invariant_gate_tests = b.addRunArtifact(invariant_gate_tests);
    const invariant_gate_test_step = b.step("test-invariant-gate", "Run the invariant drift gate's own parser and probe-table tests");
    invariant_gate_test_step.dependOn(&run_invariant_gate_tests.step);
    invariant_drift_step.dependOn(&run_invariant_gate_tests.step);

    // The gate binary on its own, so a single mutation probe can be run
    // directly and read from its exit status. Routing a probe through the
    // aggregate step above would mix the gate's verdict with seven test suites.
    const invariant_gate_install = b.addInstallArtifact(invariant_gate_exe, .{
        .dest_dir = .{ .override = .{ .custom = "tooling" } },
    });
    const invariant_gate_step = b.step("invariant-gate", "Build the invariant drift gate into zig-out/tooling");
    invariant_gate_step.dependOn(&invariant_gate_install.step);

    // The trusted-boundary ratchet. Rooted at its own file because nothing in
    // the product imports it: it is a corpus plus assertions, and a file no
    // analyzed root reaches contributes no tests.
    const proof_ratchet_tests = b.addTest(.{
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
            },
        }),
    });
    const run_proof_ratchet_tests = b.addRunArtifact(proof_ratchet_tests);
    const proof_ratchet_step = b.step("test-proof-ratchet", "Check the disclosed trusted boundary against what the kernel re-derives");
    proof_ratchet_step.dependOn(&run_proof_ratchet_tests.step);

    // zttp proof-review package tests. Context.zig states why its dependency
    // carries perf_histogram.
    const proof_review_pkg_tests = b.addTest(.{
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
    const run_proof_review_pkg_tests = b.addRunArtifact(proof_review_pkg_tests);
    const proof_review_pkg_test_step = b.step("test-proof-review", "Run zttp proof-review package tests");
    proof_review_pkg_test_step.dependOn(&run_proof_review_pkg_tests.step);

    // The remaining evidence roots do not exist yet; build.zig passes them to
    // addInvariantDriftEvidence once they do.

    return .{
        .proof_checker_purity = proof_checker_purity.run,
        .script_reachability = script_reachability.run,
        .diagnostic_producers = diagnostic_producers.run,
        .proof_ratchet_drift = proof_ratchet_drift.run,
        .residual_guards_drift = residual_guards_drift.run,
        .residual_guards_drift_step = residual_guards_drift.step,
        .invariant_drift_step = invariant_drift_step,
        .run_proof_ratchet_tests = run_proof_ratchet_tests,
        .run_proof_review_pkg_tests = run_proof_review_pkg_tests,
    };
}

/// The invariant drift gate's evidence roots that other files create. All of
/// the gate's build wiring stays in this file because
/// packages/tools/src/invariant_drift_gate.zig reads it as text, and its
/// mutation probes edit that text.
pub fn addInvariantDriftEvidence(
    invariant_drift_step: *std.Build.Step,
    run_project_config_tests: *std.Build.Step.Run,
    run_unit_tests: *std.Build.Step.Run,
    run_cli_tests: *std.Build.Step.Run,
) void {
    // The tools root that collects invariant_author.zig through its
    // re-export from project_config.zig.
    invariant_drift_step.dependOn(&run_project_config_tests.step);
    // The runtime root (main.zig).
    invariant_drift_step.dependOn(&run_unit_tests.step);
    // The invariant status renderer is anchored from `cli_main.zig`, so the
    // developer CLI root is the only one that compiles and runs its tests.
    // The drift gate asserts that the renderer's source states write
    // applicability before its counts and keeps the deployment assumption
    // outside every branch; both are source scans, and a source scan proves
    // nothing about what the renderer produced. Naming a test in the gate's
    // evidence table without this dependency would be the gate claiming a
    // test ran when nothing made it compile.
    invariant_drift_step.dependOn(&run_cli_tests.step);
}
