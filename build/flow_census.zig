//! Build wiring for the flow census gate (plan F0).
//!
//! `test-flow-census` runs the gate over the generated probe census, then the
//! gate's own unit tests. The probes and the expected verdicts live in
//! packages/tools/src/flow_census_probes.zig, and the allowlist of the
//! verdicts the checker does not yet meet is scripts/flow-census.allow.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    /// The named step. `zig build test` depends on it.
    step: *std.Build.Step,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const gate_mod = b.createModule(.{
        .root_source_file = ctx.tools_dep.path("src/flow_census_gate.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    gate_mod.addImport("zts", ctx.zts_host_mod);
    gate_mod.addImport("zttp_proof_checker", ctx.proofCheckerMod());
    const gate_exe = b.addExecutable(.{
        .name = "flow-census-gate",
        .root_module = gate_mod,
    });

    // A Run step caches on its argv and binary, never on the files it reads,
    // so without has_side_effects an edited allowlist would not rerun it.
    const check = b.addRunArtifact(gate_exe);
    check.has_side_effects = true;
    if (b.args) |args| check.addArgs(args);
    const census_step = b.step("test-flow-census", "Check the flow checker's leak verdicts over the generated probe census");
    census_step.dependOn(&check.step);

    // A probe is code: the gate's own tests hang off the same named step, so a
    // probe that does not compile fails here instead of vanishing.
    const gate_tests = b.addTest(.{
        .filters = ctx.test_filters,
        .root_module = gate_mod,
    });
    const run_gate_tests = b.addRunArtifact(gate_tests);
    census_step.dependOn(&run_gate_tests.step);

    return .{ .step = census_step };
}
