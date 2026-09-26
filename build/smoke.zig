//! End-to-end smoke tests and the panic-isolation checks. None is a
//! dependency of `zig build test`.

const std = @import("std");
const Context = @import("Context.zig");

pub fn add(ctx: Context) void {
    const b = ctx.b;

    // End-to-end smoke for the v1 user flow:
    // init -> doctor -> check -> build -> deploy.
    // The script builds the CLI itself; the step does not reference cli_exe so
    // CI can invoke it as a single command without depending on install steps.
    // studio is compiled out by default, so it is smoke-tested separately by
    // `zig build smoke-studio` (which builds with -Dstudio).
    const smoke_v1 = ctx.addGate(&.{ "/bin/bash", "scripts/smoke-v1.sh" }, "smoke-v1", "Run the v1 user-flow smoke test in a temp dir");
    smoke_v1.run.has_side_effects = true;

    const panic_isolation_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/test-panic-isolation.sh", "--skip-build", "--zttp" });
    panic_isolation_cmd.addArg(b.getInstallPath(.bin, "zttp"));
    panic_isolation_cmd.has_side_effects = true;
    panic_isolation_cmd.step.dependOn(b.getInstallStep());

    const module_scope_panic_probe_mod = b.createModule(.{
        .root_source_file = ctx.runtime_dep.path("src/module_scope_panic_probe.zig"),
        .target = b.graph.host,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    module_scope_panic_probe_mod.addImport("zts", ctx.zts_host_mod);
    const module_scope_panic_probe = b.addExecutable(.{
        .name = "module-scope-panic-probe",
        .root_module = module_scope_panic_probe_mod,
    });
    const run_module_scope_panic_probe = b.addRunArtifact(module_scope_panic_probe);
    const module_scope_panic_probe_step = b.step(
        "test-module-scope-panic",
        "Verify module authorization isolation across a recovered panic",
    );
    module_scope_panic_probe_step.dependOn(&run_module_scope_panic_probe.step);

    const panic_isolation_step = b.step("test-panic-isolation", "Run handler panic isolation E2E test");
    panic_isolation_step.dependOn(&panic_isolation_cmd.step);
    panic_isolation_step.dependOn(&run_module_scope_panic_probe.step);

    const smoke_studio = ctx.addGate(&.{ "/bin/bash", "scripts/smoke-studio.sh" }, "smoke-studio", "Run the opt-in studio smoke test (-Dstudio) in a temp dir");
    smoke_studio.run.has_side_effects = true;

    const smoke_getting_started = ctx.addGate(&.{ "/bin/bash", "scripts/smoke-getting-started.sh" }, "smoke-getting-started", "Run the Getting Started guide smoke test in a temp dir");
    smoke_getting_started.run.has_side_effects = true;

    const smoke_demo = ctx.addGate(&.{ "/bin/bash", "scripts/smoke-demo.sh" }, "smoke-demo", "Run the Proof Theater demo smoke test in a temp dir");
    smoke_demo.run.has_side_effects = true;
}
