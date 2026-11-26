//! Build wiring for the restriction gate.
//!
//! `test-ts-restrictions` runs the gate over `docs/ts-restrictions.md`, then
//! the gate's own unit tests. The probe inputs live in
//! packages/tools/src/ts_restrictions_probes.zig. The expected codes come only
//! from the document, which reaches the gate through build options.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    /// The named step. `zig build test` depends on it.
    step: *std.Build.Step,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const doc = b.addOptions();
    doc.addOption([]const u8, "contents", @embedFile("../docs/ts-restrictions.md"));
    const allow = b.addOptions();
    allow.addOption([]const u8, "contents", @embedFile("../scripts/ts-restrictions-unprobed.allow"));

    const gate_mod = b.createModule(.{
        .root_source_file = ctx.tools_dep.path("src/ts_restrictions_gate.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    gate_mod.addImport("zts", ctx.zts_host_mod);
    gate_mod.addImport("zttp_proof_checker", ctx.proofCheckerHostMod());
    gate_mod.addImport("project_config", ctx.project_config_host_mod);
    gate_mod.addOptions("ts_restrictions_doc", doc);
    gate_mod.addOptions("ts_restrictions_allow", allow);
    const gate_exe = b.addExecutable(.{
        .name = "ts-restrictions-gate",
        .root_module = gate_mod,
    });

    // A Run step caches on its argv and binary, never on the files it reads,
    // so has_side_effects keeps the gate running on every invocation.
    const check = b.addRunArtifact(gate_exe);
    check.has_side_effects = true;
    check.addPassthruArgs();
    const gate_step = b.step("test-ts-restrictions", "Check the compiler against docs/ts-restrictions.md");
    gate_step.dependOn(&check.step);

    // A probe is code: the gate's own tests hang off the same named step.
    const gate_tests = ctx.addTest(.{
        .filters = ctx.test_filters,
        .root_module = gate_mod,
    });
    const run_gate_tests = ctx.addRunTest(gate_tests);
    gate_step.dependOn(&run_gate_tests.step);

    return .{ .step = gate_step };
}
