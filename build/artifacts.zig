//! The installed binaries (`zttp-runtime`, `zttp`, `zts`), optional handler
//! precompilation, and the steps that inspect or run those binaries.

const std = @import("std");
const Context = @import("Context.zig");
const repo_gates = @import("repo_gates.zig");

pub const Binaries = struct {
    runtime_exe: *std.Build.Step.Compile,
    cli_exe: *std.Build.Step.Compile,
    zts_exe: *std.Build.Step.Compile,
    runtime_purity_cmd: *std.Build.Step.Run,
};

pub fn add(ctx: Context, gates: repo_gates.Result) Binaries {
    const b = ctx.b;
    const zts_mod = ctx.zts_mod;
    const runtime_dep = ctx.runtime_dep;

    // Internal precompile tool used by build steps and the zts CLI.
    const precompile_exe = b.addExecutable(.{
        .name = "precompile",
        .root_module = b.createModule(.{
            .root_source_file = ctx.tools_dep.path("src/precompile.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    precompile_exe.root_module.addImport("zts", ctx.zts_host_mod);
    precompile_exe.root_module.addImport("zttp_proof_checker", ctx.proofCheckerMod());

    // Runtime template binary — used for self-contained outputs and direct
    // runtime tests. Minimal dependencies:
    // only what's needed to serve HTTP and execute a (possibly embedded)
    // handler. No pi_app, no deploy, no zts_cli.
    const runtime_exe = b.addExecutable(.{
        .name = "zttp-runtime",
        .root_module = runtime_dep.module("runtime_main"),
    });

    var embedded_handler_step: ?*std.Build.Step = null;

    // If handler is specified, precompile it and add as dependency
    if (ctx.precompile.handler_path) |path| {
        // Run precompile tool to generate embedded handler
        const run_precompile = b.addRunArtifact(precompile_exe);
        addPrecompileArgs(run_precompile, ctx.precompile, ctx.git_commit_sha);
        run_precompile.addArg(path);
        run_precompile.addArg("packages/runtime/generated/embedded_handler.zig");

        // Create the generated directories if they don't exist
        const mkdir_step = b.addSystemCommand(&.{ "/bin/mkdir", "-p", "packages/runtime/generated" });
        run_precompile.step.dependOn(&mkdir_step.step);
        embedded_handler_step = &run_precompile.step;

        // Runtime and user-facing CLI both depend on precompile completing.
        runtime_exe.step.dependOn(&run_precompile.step);

        // Add the generated module (with zts dependency for transpiled handlers)
        runtime_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = b.path("packages/runtime/generated/embedded_handler.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    } else {
        // No handler specified - create a stub module
        Context.attachEmbeddedHandlerStub(runtime_exe, runtime_dep, zts_mod);
    }

    b.installArtifact(runtime_exe);

    // Developer CLI — the primary user-facing `zttp` binary. Contains init,
    // dev, serve, check, compile, prove, mock, link, expert, local deploy,
    // doctor, and the proof/proof-ledger tools. Hosted deploy account verbs
    // are intentionally absent from CLI dispatch in the beta.
    const cli_exe = b.addExecutable(.{
        .name = "zttp",
        .root_module = runtime_dep.module("cli_main"),
    });
    if (embedded_handler_step) |step| {
        cli_exe.step.dependOn(step);
        cli_exe.root_module.addAnonymousImport("embedded_handler", .{
            .root_source_file = b.path("packages/runtime/generated/embedded_handler.zig"),
            .imports = &.{
                .{ .name = "zts", .module = zts_mod },
            },
        });
    } else {
        Context.attachEmbeddedHandlerStub(cli_exe, runtime_dep, zts_mod);
    }
    b.installArtifact(cli_exe);

    // Compiler/analyzer CLI installed for IDE and CI integrations that call
    // the analyzer directly. Pi-free by design: the interactive `expert` and
    // session `ledger` commands live only in the developer `zttp` binary, so
    // the ~37 KLOC agent (and its network/credential surface) is compiled
    // exactly once across the whole build.
    const zts_exe = b.addExecutable(.{
        .name = "zts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zts_main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
        }),
    });
    zts_exe.root_module.addImport("zts_cli", ctx.zts_cli_mod);
    b.installArtifact(zts_exe);

    // The drift gate must inspect this build's executable, not a possibly
    // stale installation left in zig-out by an earlier invocation.
    gates.meta_drift.addFileArg(zts_exe.getEmittedBin());

    const zts_overview_drift = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-zts-language-overview.sh" });
    zts_overview_drift.addFileArg(zts_exe.getEmittedBin());
    gates.docs_drift_step.dependOn(&zts_overview_drift.step);

    // Chrome is not a standard build dependency, so keep real-browser
    // interaction coverage explicit and fail loudly when the local toolchain
    // is unavailable.
    _ = ctx.addGate(&.{ "node", "scripts/test-zts-language-overview-browser.mjs" }, "test-zts-overview-browser", "Test the ZTS language overview in headless Chrome");

    // Strip debug info from the three installed binaries when -Dstrip is set.
    // The release workflow passes -Dstrip so shipped tarballs stay small; local
    // builds keep symbols by default. Stripping happens at link time, so it is
    // correct for every cross-compiled -Dtarget.
    if (ctx.strip_enabled) {
        runtime_exe.root_module.strip = true;
        cli_exe.root_module.strip = true;
        zts_exe.root_module.strip = true;
    }

    // Runtime purity guard: the deployable `zttp-runtime` template and the
    // pi-free `zts` analyzer must carry no expert-agent / model-provider
    // surface; the developer `zttp` binary is the sole pi host. Enforces the
    // invariant against future regressions. See scripts/check-runtime-purity.sh.
    const runtime_purity_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/check-runtime-purity.sh" });
    runtime_purity_cmd.addFileArg(cli_exe.getEmittedBin());
    runtime_purity_cmd.addFileArg(runtime_exe.getEmittedBin());
    runtime_purity_cmd.addFileArg(zts_exe.getEmittedBin());
    // Emit the sealed ZTS training contract bundle. The script supplies commit
    // and worktree state; the exporter refuses a dirty tree.
    const training_export_cmd = b.addSystemCommand(&.{ "/bin/bash", "scripts/zts-training-export.sh" });
    training_export_cmd.addFileArg(zts_exe.getEmittedBin());
    training_export_cmd.has_side_effects = true;
    if (b.args) |args| training_export_cmd.addArgs(args);
    const training_export_step = b.step("zts-training-export", "Emit the sealed ZTS training contract bundle");
    training_export_step.dependOn(&training_export_cmd.step);

    const runtime_purity_step = b.step("test-runtime-purity", "Assert the deployed runtime and analyzer carry no agent/provider surface");
    runtime_purity_step.dependOn(&runtime_purity_cmd.step);

    return .{
        .runtime_exe = runtime_exe,
        .cli_exe = cli_exe,
        .zts_exe = zts_exe,
        .runtime_purity_cmd = runtime_purity_cmd,
    };
}

/// Forward each precompilation `-D` option that is set to the precompile tool.
fn addPrecompileArgs(
    run_precompile: *std.Build.Step.Run,
    opts: Context.PrecompileOptions,
    git_commit_sha: ?[]const u8,
) void {
    if (opts.aot_enabled) {
        run_precompile.addArg("--aot");
    }
    if (opts.verify_enabled) {
        run_precompile.addArg("--verify");
    }
    if (opts.openapi_enabled) {
        run_precompile.addArg("--openapi");
    }
    if (opts.sdk_target) |sdk| {
        run_precompile.addArg("--sdk");
        run_precompile.addArg(sdk);
    }
    if (opts.sql_schema_path) |sql_schema| {
        run_precompile.addArg("--sql-schema");
        run_precompile.addArg(sql_schema);
    }
    if (opts.system_path) |system| {
        run_precompile.addArg("--system");
        run_precompile.addArg(system);
    }
    if (opts.contract_enabled) {
        run_precompile.addArg("--contract");
    }
    if (opts.policy_path) |policy| {
        run_precompile.addArg("--policy");
        run_precompile.addArg(policy);
    }
    if (opts.replay_path) |rp| {
        run_precompile.addArg("--replay");
        run_precompile.addArg(rp);
    }
    if (opts.test_file_path) |tf| {
        run_precompile.addArg("--test-file");
        run_precompile.addArg(tf);
    }
    if (opts.prove_spec) |ps| {
        run_precompile.addArg("--prove");
        run_precompile.addArg(ps);
    }
    if (opts.generate_tests) {
        run_precompile.addArg("--generate-tests");
    }
    if (opts.manifest_path) |mp| {
        run_precompile.addArg("--manifest");
        run_precompile.addArg(mp);
    }
    if (opts.expect_properties_path) |ep| {
        run_precompile.addArg("--expect-properties");
        run_precompile.addArg(ep);
    }
    if (opts.declaration_path) |dl| {
        run_precompile.addArg("--declaration");
        run_precompile.addArg(dl);
    }
    if (opts.fault_severity_path) |fs| {
        run_precompile.addArg("--fault-severity");
        run_precompile.addArg(fs);
    }
    if (opts.generator_pack_path) |gp| {
        run_precompile.addArg("--generator-pack");
        run_precompile.addArg(gp);
    }
    if (opts.report_format) |rf| {
        run_precompile.addArg("--report");
        run_precompile.addArg(rf);
    }
    if (git_commit_sha) |sha| {
        run_precompile.addArg("--git-commit");
        run_precompile.addArg(sha);
    }
}

/// `zig build run` and `zig build cli`: run the runtime or the dev CLI
/// directly, without triggering the full install step (which would also link
/// the dev CLI and bench binaries).
pub fn addRunSteps(ctx: Context, bins: Binaries) void {
    const b = ctx.b;
    const run_cmd = b.addRunArtifact(bins.runtime_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Dev CLI run command for convenience: `zig build cli -- expert`
    const cli_run_cmd = b.addRunArtifact(bins.cli_exe);
    if (b.args) |args| {
        cli_run_cmd.addArgs(args);
    }
    const cli_run_step = b.step("cli", "Run the zttp CLI");
    cli_run_step.dependOn(&cli_run_cmd.step);
}

/// System linking step (cross-handler contract verification), present only
/// when `-Dsystem` names a system definition.
pub fn addSystemLink(ctx: Context, bins: Binaries) void {
    const b = ctx.b;
    const sys_path = ctx.precompile.system_path orelse return;
    const run_system = b.addRunArtifact(bins.zts_exe);
    run_system.addArg("link");
    run_system.addArg(sys_path);
    if (b.args) |args| {
        run_system.addArgs(args);
    }
    const system_step = b.step("system", "Cross-handler contract linking");
    system_step.dependOn(&run_system.step);
}
