//! The golden diagnostic corpus gate (tests/corpus) and its golden writer.
//!
//! `test-diagnostic-corpus` runs the gate over every case, then the gate's own
//! unit tests. `diagnostic-corpus-write` rewrites the goldens and is a human
//! action, listed in scripts/manual-steps.allow. Arguments after `--` filter
//! both by path substring; a filter that matches no case fails the gate.
//!
//! The gate also reads `instruction_counter.zig` (same module root, so no
//! import wiring is needed) and fails a case above its instruction budget;
//! `-- --report-costs` lists every case's cost, `-- --cpu-time` forces the
//! report-only fallback source. Both are gate flags, not filters.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    /// The named step. `zig build test` depends on it.
    step: *std.Build.Step,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const gate_mod = b.createModule(.{
        .root_source_file = ctx.tools_dep.path("src/diagnostic_corpus_gate.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    gate_mod.addImport("zts", ctx.zts_host_mod);
    gate_mod.addImport("zttp_proof_checker", ctx.proofCheckerMod());
    const gate_exe = b.addExecutable(.{
        .name = "diagnostic-corpus-gate",
        .root_module = gate_mod,
    });

    // A Run step caches on its argv and binary, never on the files it reads,
    // so without has_side_effects an edited case or golden would not rerun it.
    const check = b.addRunArtifact(gate_exe);
    check.has_side_effects = true;
    if (b.args) |args| check.addArgs(args);
    const corpus_step = b.step("test-diagnostic-corpus", "Check every tests/corpus case against its golden diagnostics");
    corpus_step.dependOn(&check.step);

    // A probe is code: the gate's own tests hang off the same named step, so a
    // probe that does not compile fails here instead of vanishing.
    const gate_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = gate_mod,
    });
    const run_gate_tests = b.addRunArtifact(gate_tests);
    corpus_step.dependOn(&run_gate_tests.step);

    const write = b.addRunArtifact(gate_exe);
    write.addArg("--write");
    if (b.args) |args| write.addArgs(args);
    write.has_side_effects = true;
    const write_step = b.step("diagnostic-corpus-write", "Rewrite the tests/corpus goldens from the current check output");
    write_step.dependOn(&write.step);

    return .{ .step = corpus_step };
}
