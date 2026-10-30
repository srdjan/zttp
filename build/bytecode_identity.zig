//! Build wiring for the bytecode identity gate (reset unit 8b).
//!
//! `test-bytecode-identity` compiles every tracked handler and compares the
//! bytecode digests with packages/tools/src/bytecode_identity_golden.txt. The
//! gate reads the handler sources at run time, so its Run step has side effects
//! and reruns on every invocation. The golden text is embedded in the gate
//! binary, so an edit to the golden rebuilds it.

const std = @import("std");
const Context = @import("Context.zig");

pub const Result = struct {
    /// The named step. `zig build test` depends on it.
    step: *std.Build.Step,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const gate_mod = b.createModule(.{
        .root_source_file = ctx.tools_dep.path("src/bytecode_identity_golden.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    gate_mod.addImport("zts", ctx.zts_host_mod);
    gate_mod.addImport("zttp_proof_checker", ctx.proofCheckerMod());
    gate_mod.addImport("project_config", ctx.project_config_mod);
    const gate_exe = b.addExecutable(.{
        .name = "bytecode-identity-gate",
        .root_module = gate_mod,
    });

    // A Run step caches on its argv and binary, never on the files it reads,
    // so has_side_effects keeps the gate running on every invocation. The
    // working directory stays the repository root, where the inputs live.
    const check = b.addRunArtifact(gate_exe);
    check.has_side_effects = true;
    check.addPassthruArgs();
    const identity_step = b.step("test-bytecode-identity", "Check that emitted handler bytecode matches the committed identity golden");
    identity_step.dependOn(&check.step);

    return .{ .step = identity_step };
}
