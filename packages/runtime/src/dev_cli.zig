const std = @import("std");
const builtin = @import("builtin");

const project_config_mod = @import("project_config");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const proofs_cli = @import("proofs_cli.zig");
const proof_cli = @import("proof_cli.zig");
const witnesses_cli = @import("witnesses_cli.zig");
const shared = @import("cli_shared.zig");
const runtime_cli = @import("runtime_cli.zig");
const feature_options = @import("runtime_feature_options");
const embedded_handler = @import("embedded_handler");
const proof_ledger = @import("proof_ledger.zig");
const ratchet_command = @import("ratchet_command.zig");
const pi_app = @import("pi_app");
const verify_cli = @import("verify_cli.zig");
const cli_args = @import("cli_args.zig");
const cli_tour = @import("cli_tour.zig");
const cli_paths = @import("cli_paths.zig");
const resolveDeveloperServeBinary = cli_paths.resolveDeveloperServeBinary;
const resolveReentryBinaryAfterChdir = cli_paths.resolveReentryBinaryAfterChdir;
const cli_doctor = @import("cli_doctor.zig");
const doctorCommand = cli_doctor.doctorCommand;
const printDoctorHelp = cli_doctor.printDoctorHelp;
const cli_auth = @import("cli_auth.zig");
const doctorPathExists = cli_doctor.doctorPathExists;
const runDoctorAnalyzerForProject = cli_doctor.runDoctorAnalyzerForProject;
const hasHelpFlag = cli_args.hasHelpFlag;
const hasLongHelpFlag = cli_args.hasLongHelpFlag;
const deployArgsRequestCloud = cli_args.deployArgsRequestCloud;
const printNoProjectConfigDiagnostic = cli_args.printNoProjectConfigDiagnostic;
const handlePreflightError = cli_args.handlePreflightError;
const template_choices = cli_args.template_choices;
const demo_command = @import("demo_command.zig");
const test_command = @import("test_command.zig");
const init_command = @import("init_command.zig");
const build_command = @import("build_command.zig");
const dev_command = @import("dev_command.zig");
const cli_help = @import("cli_help.zig");

test {
    // Command modules are reached only through `main`'s dispatch, which the
    // test build does not analyze. Reference them here so their own test
    // blocks (and the sibling files they transitively pull in, e.g. the
    // analyzer/serve paths) are collected by `zig build test-cli`.
    _ = @import("cli_templates.zig");
    _ = @import("demo_command.zig");
    _ = @import("test_command.zig");
    _ = @import("init_command.zig");
    _ = @import("build_command.zig");
    _ = @import("dev_command.zig");
    _ = @import("ratchet_command.zig");
    _ = @import("cli_help.zig");
    _ = @import("workflow_queue_cli.zig");
    _ = @import("durable_dead_runs_cli.zig");
    // cli_auth and verify_cli are likewise only reached via main's dispatch;
    // reference them so their tests (API-key store 0600 perms/masking, and the
    // Ed25519 verifier arg parsing incl. trust-key validation) actually run.
    _ = @import("cli_auth.zig");
    _ = @import("verify_cli.zig");
}

/// Print the model-backend setup message and exit when no provider key is
/// configured. Shared by `dispatchExpert` and the `init --expert` pre-check so
/// the message lives in one place and can fire before any side effects (for
/// `init --expert`, before scaffolding).
fn ensureModelBackendOrExit() void {
    if (pi_app.envHasModelBackend()) return;
    std.debug.print(
        \\zttp expert needs a model backend.
        \\
        \\Quickest path:
        \\  zttp auth claude   # paste your key once, stored at ~/.zttp/providers.json
        \\
        \\Or set one of these environment variables and run `zttp expert` again:
        \\  ANTHROPIC_API_KEY   (recommended)  https://console.anthropic.com/
        \\  OPENAI_API_KEY
        \\
        \\See `zttp expert --help` for details.
        \\
    , .{});
    std.process.exit(1);
}

/// Validate, configure, and launch the expert agent. Shared by the `expert`
/// command and by `init --expert` (which scaffolds, chdir's into the project,
/// then calls this with no extra args).
fn dispatchExpert(allocator: std.mem.Allocator, expert_args: []const []const u8) !void {
    if (hasHelpFlag(expert_args)) {
        cli_help.printExpertHelp();
        return;
    }
    switch (cli_args.validateExpertArgs(expert_args)) {
        .ok => {},
        .unknown_flag => |flag| {
            std.debug.print("zttp expert does not accept flag '{s}'. See `zttp expert --help`.\n", .{flag});
            std.process.exit(1);
        },
        .unexpected_arg => |arg| {
            std.debug.print(
                "zttp expert does not accept subcommand or positional argument '{s}'. See `zttp expert --help`.\n",
                .{arg},
            );
            std.process.exit(1);
        },
    }
    _ = pi_app.parseExpertFlags(expert_args) catch |err| {
        std.debug.print("{s}", .{pi_app.flagErrorMessage(err)});
        std.process.exit(2);
    };
    ensureModelBackendOrExit();
    const witness_replay_lib = @import("witness_replay_lib.zig");
    const perf_probe_lib = @import("perf_probe_lib.zig");
    const equivalence_probe_lib = @import("equivalence_probe_lib.zig");
    pi_app.setInvocationArgv(expert_args);
    pi_app.witness_replay.setReplayFn(witness_replay_lib.replayWitnessJsonl);
    pi_app.perf_probe.setProbeFn(perf_probe_lib.recordPerfReceipt);
    pi_app.equivalence_probe.setProbeFn(equivalence_probe_lib.recordEquivalenceReceipt);
    pi_app.capsule_probe.setProbeFn(dev_command.capsuleReplayProbe);
    try pi_app.run(allocator);
}

// ---------------------------------------------------------------------------
// The `zttp` command table. Dispatch reads it, and the help listing is checked
// against it, so a command cannot be added to one and forgotten in the other.
//
// The analyzer commands are deliberately absent: they live in
// `zts_cli.commands`, which the `zts` binary and this one already share.
//
// Each wrapper keeps its own error-to-exit-code mapping. That is not an
// oversight to be generated away later: measured, no two of these agree on
// which errors exit 1, which print a remediation line first, and which reprint
// their own `--help`, so a shared prologue would have to encode all 22
// vocabularies to reproduce the current output byte for byte.
// ---------------------------------------------------------------------------

fn cmdAuth(ctx: cli_help.Ctx) anyerror!void {
    cli_auth.authCommand(ctx.allocator, ctx.args) catch |err| switch (err) {
        error.InvalidArgument, error.NotATty, error.EmptyKey, error.InvalidKey => std.process.exit(1),
        else => return err,
    };
    return;
}

fn cmdInit(ctx: cli_help.Ctx) anyerror!void {
    // `init --expert` hands off to the agent after scaffolding. If the agent
    // cannot launch (no provider key), say so before creating any files so
    // the user is not scaffolded into a dead end. Gate on the authoritative
    // parse so this never fires for `--help`, `--extension`, or an `--expert`
    // that was actually consumed as another flag's value.
    if (init_command.willEnterExpert(ctx.args)) {
        cli_auth.injectStoredProvidersIntoEnv(ctx.allocator);
        ensureModelBackendOrExit();
    }
    const outcome = init_command.initCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.HelpRequested) {
            init_command.printInitHelp();
            return;
        }
        if (err == error.MissingProjectName) {
            std.debug.print("zttp init requires a project name.\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        if (err == error.MissingTemplate) {
            std.debug.print("--template requires one of: " ++ template_choices ++ ".\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        if (err == error.InvalidTemplate) {
            std.debug.print("Unknown template. Choose one of: " ++ template_choices ++ ".\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        if (err == error.InvalidProjectName) {
            std.debug.print("Invalid project name. Use letters, numbers, '-' or '_', starting with a letter or number.\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        if (err == error.MissingExtensionName) {
            std.debug.print("zttp init --extension requires a name.\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        if (err == error.InvalidArgument or err == error.UnknownOption) {
            std.debug.print("Invalid init arguments.\n\n", .{});
            init_command.printInitHelp();
            std.process.exit(1);
        }
        return err;
    };
    if (outcome.enter_expert) {
        if (outcome.project_name) |proj| {
            // Stored provider keys were already injected by the pre-scaffold
            // backend check above (willEnterExpert was true), so no re-inject
            // is needed here before the handoff.
            std.Io.Threaded.chdir(proj) catch |e| {
                std.debug.print("init --expert: could not enter '{s}': {s}\n", .{ proj, @errorName(e) });
                std.process.exit(1);
            };
            return dispatchExpert(ctx.allocator, &.{});
        }
    }
    return;
}

fn cmdDev(ctx: cli_help.Ctx) anyerror!void {
    if (hasLongHelpFlag(ctx.args)) {
        dev_command.printDevHelp();
        return;
    }
    dev_command.devCommand(ctx.allocator, ctx.argv0, ctx.args) catch |err| {
        if (handlePreflightError(err, ctx.command)) std.process.exit(1);
        return err;
    };
    return;
}

fn cmdStudio(ctx: cli_help.Ctx) anyerror!void {
    if (hasLongHelpFlag(ctx.args)) {
        dev_command.printStudioHelp();
        return;
    }
    if (!feature_options.enable_studio) shared.featureCompiledOut("studio", "studio");
    dev_command.studioCommand(ctx.allocator, ctx.argv0, ctx.args) catch |err| {
        if (handlePreflightError(err, ctx.command)) std.process.exit(1);
        return err;
    };
    return;
}

fn cmdDemo(ctx: cli_help.Ctx) anyerror!void {
    demo_command.demoCommand(ctx.allocator, ctx.argv0, ctx.args) catch |err| {
        if (err == error.HelpRequested) {
            demo_command.printDemoHelp();
            return;
        }
        if (err == error.MissingOptionValue) {
            std.debug.print("demo option requires a value.\n\n", .{});
            demo_command.printDemoHelp();
            std.process.exit(1);
        }
        if (err == error.InvalidPort) {
            std.debug.print("--port requires a number from 1 to 65535.\n\n", .{});
            demo_command.printDemoHelp();
            std.process.exit(1);
        }
        if (err == error.OutputExists) {
            std.debug.print("--out target already exists. Pick a new directory; zttp demo will not overwrite files.\n", .{});
            std.process.exit(1);
        }
        if (err == error.InvalidOutputPath) {
            std.debug.print("--out must end in a simple directory name using letters, numbers, '-' or '_'.\n", .{});
            std.process.exit(1);
        }
        if (err == error.UnknownOption) {
            std.debug.print("Unknown demo option.\n\n", .{});
            demo_command.printDemoHelp();
            std.process.exit(1);
        }
        return err;
    };
    return;
}

fn cmdServe(ctx: cli_help.Ctx) anyerror!void {
    // Convenience: dev CLI can also serve a handler locally for quick testing.
    // Map parse/usage failures to a clean nonzero exit with a hint instead of
    // propagating a raw Zig error (which prints a stack trace).
    runtime_cli.serveCommandWithEnviron(ctx.allocator, ctx.args, ctx.environ) catch |err| {
        std.debug.print("serve: {s}. Run `zttp serve --help` for usage.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    return;
}

fn cmdEdge(ctx: cli_help.Ctx) anyerror!void {
    try runtime_cli.edgeCommand(ctx.allocator, ctx.args);
    return;
}

fn cmdWorkflowQueue(ctx: cli_help.Ctx) anyerror!void {
    try runtime_cli.workflowQueueCommand(ctx.allocator, ctx.args);
    return;
}

fn cmdDurable(ctx: cli_help.Ctx) anyerror!void {
    try runtime_cli.durableCommand(ctx.allocator, ctx.args);
    return;
}

fn cmdDoctor(ctx: cli_help.Ctx) anyerror!void {
    if (hasHelpFlag(ctx.args)) {
        printDoctorHelp();
        return;
    }
    doctorCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.NoProjectConfig) {
            printNoProjectConfigDiagnostic(ctx.command);
            std.process.exit(1);
        }
        if (err == error.FileNotFound or
            err == error.UnsupportedMultipleOutboundHosts or
            err == error.CheckFailed or
            err == error.DoctorFailed or
            err == error.InvalidArgument)
        {
            std.process.exit(1);
        }
        return err;
    };
    return;
}

fn cmdTest(ctx: cli_help.Ctx) anyerror!void {
    test_command.testCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.HelpRequested) {
            test_command.printTestHelp();
            return;
        }
        if (err == error.NoProjectConfig) {
            printNoProjectConfigDiagnostic(ctx.command);
            std.process.exit(1);
        }
        if (err == error.FileNotFound) {
            std.process.exit(1);
        }
        if (err == error.UnknownOption or err == error.TooManyArguments) {
            if (err == error.UnknownOption) {
                std.debug.print("zttp test accepts a single optional tests.jsonl path; flags are not supported here.\n\n", .{});
            } else {
                std.debug.print("zttp test accepts at most one tests.jsonl path.\n\n", .{});
            }
            test_command.printTestHelp();
            std.process.exit(1);
        }
        if (err == error.CheckFailed or err == error.UnsupportedMultipleOutboundHosts) {
            std.process.exit(1);
        }
        return err;
    };
    return;
}

fn cmdCompile(ctx: cli_help.Ctx) anyerror!void {
    build_command.compileCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.NoProjectConfig) {
            printNoProjectConfigDiagnostic(ctx.command);
            std.process.exit(1);
        }
        if (err == error.MissingArgument) {
            std.process.exit(1);
        }
        return err;
    };
    return;
}

fn cmdBuild(ctx: cli_help.Ctx) anyerror!void {
    build_command.buildCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.NoProjectConfig) {
            printNoProjectConfigDiagnostic(ctx.command);
            std.process.exit(1);
        }
        if (err == error.MissingArgument or err == error.UnknownOption) {
            std.process.exit(1);
        }
        return err;
    };
    return;
}

fn cmdRatchet(ctx: cli_help.Ctx) anyerror!void {
    ratchet_command.run(ctx.allocator, ctx.args) catch |err| switch (err) {
        error.MissingArgument,
        error.UnknownSubcommand,
        error.UnknownFlag,
        error.TooManyArguments,
        error.BaselineFlagRemoved,
        error.NonRatchetableSpec,
        => std.process.exit(1),
        error.HandlerCompileFailed, error.Regression => std.process.exit(1),
        else => return err,
    };
    return;
}

fn cmdLedger(ctx: cli_help.Ctx) anyerror!void {
    // Session ledger management (list, resume, export, replay). Lives only
    // in the developer CLI; the pi-free `zts` analyzer binary does not
    // carry it.
    try pi_app.runLedgerCommand(ctx.allocator, ctx.args);
    return;
}

fn cmdExpert(ctx: cli_help.Ctx) anyerror!void {
    return dispatchExpert(ctx.allocator, ctx.args);
}

fn cmdDeploy(ctx: cli_help.Ctx) anyerror!void {
    if (deployArgsRequestCloud(ctx.args)) |flag| {
        std.debug.print(
            "zttp deploy with `{s}` selects hosted cloud deploy, which is not available in this beta.\n" ++
                "Run `zttp deploy` without the flag to build a self-contained binary you can run anywhere.\n",
            .{flag},
        );
        std.process.exit(1);
    }
    build_command.localDeployCommand(ctx.allocator, ctx.args) catch |err| {
        if (err == error.NoProjectConfig) {
            printNoProjectConfigDiagnostic(ctx.command);
            std.process.exit(1);
        }
        if (err == error.MissingArgument or err == error.InvalidArgument or err == error.UnknownOption) {
            std.process.exit(1);
        }
        // buildArtifact already printed a remediation line for each
        // of these; exit cleanly so the user does not also see a
        // Zig panic-style stack trace.
        switch (err) {
            error.ParseError,
            error.VerificationFailed,
            error.NoBytecode,
            error.FileNotFound,
            error.AccessDenied,
            => std.process.exit(1),
            else => return err,
        }
    };
    return;
}

fn cmdVerify(ctx: cli_help.Ctx) anyerror!void {
    const opts = verify_cli.parseArgs(ctx.args) catch |err| switch (err) {
        error.HelpRequested => {
            verify_cli.printHelp();
            return;
        },
        error.MissingArgument => {
            std.debug.print("zttp verify: <url> is required\n\n", .{});
            verify_cli.printHelp();
            std.process.exit(verify_cli.exit_arg_error);
        },
        error.UnknownArgument, error.TooManyArguments, error.InvalidTrustKey => {
            std.debug.print("zttp verify: invalid arguments\n\n", .{});
            verify_cli.printHelp();
            std.process.exit(verify_cli.exit_arg_error);
        },
    };
    const code = try verify_cli.run(ctx.allocator, opts);
    if (code != 0) std.process.exit(code);
    return;
}

fn cmdProofs(ctx: cli_help.Ctx) anyerror!void {
    // Expected user-input errors are explained on stderr by proofs_cli
    // itself; only unexpected ones (ctx.allocator, etc.) bubble.
    proofs_cli.run(ctx.allocator, ctx.args) catch |err| {
        if (proofs_cli.isExpectedUserError(err)) std.process.exit(1);
        return err;
    };
    return;
}

fn cmdProof(ctx: cli_help.Ctx) anyerror!void {
    // Deprecated alias for `zttp proofs replay`, kept for one release and
    // deliberately absent from `help --all`. proof_cli.run prints the
    // migration note. Expected user errors (missing capsule, policy
    // mismatch, regression) are explained on stderr; only unexpected ones
    // bubble.
    proof_cli.run(ctx.allocator, ctx.args) catch |err| {
        if (proof_cli.isExpectedUserError(err)) std.process.exit(1);
        return err;
    };
    return;
}

fn cmdWitnesses(ctx: cli_help.Ctx) anyerror!void {
    witnesses_cli.run(ctx.allocator, ctx.args) catch |err| {
        if (witnesses_cli.isExpectedUserError(err)) std.process.exit(1);
        return err;
    };
    return;
}

fn cmdVersion(_: cli_help.Ctx) anyerror!void {
    shared.printVersion();
    return;
}

fn cmdHelp(ctx: cli_help.Ctx) anyerror!void {
    if (cli_help.hasAllFlag(ctx.args)) cli_help.printHelpAll() else cli_help.printHelp();
}

const commands = [_]cli_help.Command{
    .{ .name = "auth", .run = cmdAuth, .section = .credentials, .args = "claude", .blurb = "Store an Anthropic API key for expert (measured, supported)" },
    .{ .name = "init", .run = cmdInit, .section = .core, .args = "<name> [--template basic|api|htmx]", .blurb = "Create a project" },
    .{ .name = "dev", .run = cmdDev, .section = .core, .args = "[handler.ts]", .blurb = "Run locally, watch and prove on save" },
    .{ .name = "studio", .run = cmdStudio, .section = .run_and_inspect, .args = "[handler.ts]", .blurb = "Optional browser proof workbench" },
    .{ .name = "demo", .run = cmdDemo, .section = .run_and_inspect, .blurb = "Guided local proof theater" },
    .{ .name = "serve", .run = cmdServe, .section = .run_and_inspect, .args = "[handler.ts]", .blurb = "Run a handler without watch or proof" },
    .{ .name = "edge", .run = cmdEdge, .section = .run_and_inspect, .args = "[--config FILE]", .blurb = "Optional in-process edge runtime (-Dedge)" },
    .{ .name = "workflow-queue", .run = cmdWorkflowQueue, .section = .run_and_inspect, .args = "[list|show|replay|discard] --durable <DIR>", .blurb = "Inspect workflow queue dead letters" },
    .{ .name = "durable", .run = cmdDurable, .section = .run_and_inspect, .args = "dead-runs [list|show|replay|discard] --durable <DIR>", .blurb = "Inspect durable runs that permanently failed recovery" },
    .{ .name = "doctor", .run = cmdDoctor, .section = .run_and_inspect, .args = "[path]", .blurb = "Check project readiness" },
    .{ .name = "test", .run = cmdTest, .section = .core, .args = "[tests.jsonl]", .blurb = "Run handler tests" },
    .{ .name = "compile", .run = cmdCompile, .section = .package, .args = "<handler.ts> -o <bin>", .blurb = "Build a binary from an explicit path" },
    .{ .name = "build", .run = cmdBuild, .section = .package, .args = "[-o <bin>]", .blurb = "Emit a self-contained binary" },
    .{ .name = "ratchet", .run = cmdRatchet, .section = .advanced, .args = "show <handler.ts>", .blurb = "Print declared vs proven spec sets" },
    .{ .name = "ledger", .run = cmdLedger, .section = .proof_ledger, .args = "[export|replay]", .blurb = "Export or replay an expert-session verified-patch ledger" },
    .{ .name = "expert", .run = cmdExpert, .section = .core, .blurb = "Interactive compiler-in-the-loop agent", .injects_stored_providers = true },
    .{ .name = "deploy", .run = cmdDeploy, .section = .core, .blurb = "Build, prove, deploy (local default)" },
    .{ .name = "verify", .run = cmdVerify, .section = .proof_ledger, .args = "<url>", .blurb = "Verify a deployed proof receipt" },
    .{ .name = "proofs", .run = cmdProofs, .section = .proof_ledger, .args = "[list|show|diff|watch|export|badge|bundle|verify|gate|replay]" },
    .{ .name = "proof", .run = cmdProof, .section = .unlisted },
    .{ .name = "witnesses", .run = cmdWitnesses, .section = .advanced, .args = "[list|pin|unpin|prune|synthesize]", .blurb = "Falsifying-input corpus" },
    .{ .name = "version", .run = cmdVersion, .section = .advanced, .alias = "--version", .blurb = "Show version" },
    .{ .name = "help", .alias = "--help", .run = cmdHelp, .section = .unlisted },
};

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void =
        if (builtin.mode == .Debug) .init else {};
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (builtin.mode == .Debug) debug_alloc.allocator() else std.heap.smp_allocator;

    const args = try shared.collectArgs(allocator, init.args);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    const user_args = args[1..];
    const command = if (user_args.len == 0) "" else user_args[0];

    if (user_args.len == 0) {
        if (embedded_handler.bytecode.len > 0) {
            try runtime_cli.serveCommandWithEnviron(allocator, &.{}, init.environ);
            return;
        }
        cli_help.printHelp();
        return;
    }

    // Delegate the full shared analyzer surface to the same code path `zts`
    // uses. Membership lives in one place (`zts_cli.commands`), so the two
    // binaries can never expose a different command set. `compile` is in the
    // table below instead: it builds a binary here but precompiles to .zig in
    // `zts`, so it is deliberately excluded from the shared registry.
    if (zts_cli.isAnalyzerCommand(command)) {
        zts_cli.run(allocator, user_args) catch |err| {
            if (err == error.NoProjectConfig) {
                printNoProjectConfigDiagnostic(command);
                std.process.exit(1);
            }
            // Usage errors (bad/unknown/missing flags or args) must not escape
            // as a raw Zig stack trace: IDE/CI cannot read those. Map them to a
            // clean one-line message and exit 1. Generic across every analyzer
            // command routed through this dispatch.
            if (err == error.InvalidArgument or
                err == error.InvalidArguments or
                err == error.MissingArgument or
                err == error.UnknownArgument or
                err == error.UnknownOption or
                err == error.UnknownFlag or
                err == error.TooManyArguments)
            {
                std.debug.print(
                    "zttp {s}: invalid arguments ({s}). Run `zttp {s} --help` for usage.\n",
                    .{ command, @errorName(err), command },
                );
                std.process.exit(1);
            }
            return err;
        };
        return;
    }

    for (commands) |c| {
        const matched = std.mem.eql(u8, command, c.name) or
            (c.alias != null and std.mem.eql(u8, command, c.alias.?));
        if (!matched) continue;
        // Stored provider keys are for the expert agent only. Handler
        // execution paths (`dev`/`serve`) must see the caller's explicit
        // environment.
        if (c.injects_stored_providers) cli_auth.injectStoredProvidersIntoEnv(allocator);
        return c.run(.{
            .allocator = allocator,
            .args = user_args[1..],
            .environ = init.environ,
            .command = command,
            .argv0 = args[0],
        });
    }

    std.debug.print("Unknown command: {s}\n\n", .{command});
    cli_help.printHelp();
    std.process.exit(1);
}

fn commandInjectsStoredProviders(command: []const u8) bool {
    return std.mem.eql(u8, command, "expert");
}

test "hasLongHelpFlag preserves -h for host flags" {
    try std.testing.expect(hasLongHelpFlag(&.{"--help"}));
    try std.testing.expect(hasLongHelpFlag(&.{"help"}));
    try std.testing.expect(!hasLongHelpFlag(&.{"-h"}));
    try std.testing.expect(!hasLongHelpFlag(&.{ "-h", "0.0.0.0" }));
}

test "deployArgsRequestCloud requires explicit opt-in and reports the triggering flag" {
    try std.testing.expectEqual(@as(?[]const u8, null), deployArgsRequestCloud(&.{}));
    try std.testing.expectEqual(@as(?[]const u8, null), deployArgsRequestCloud(&.{"--local"}));
    try std.testing.expectEqual(@as(?[]const u8, null), deployArgsRequestCloud(&.{ "--target", "local" }));
    try std.testing.expectEqual(@as(?[]const u8, null), deployArgsRequestCloud(&.{"--target=local"}));
    try std.testing.expectEqual(@as(?[]const u8, null), deployArgsRequestCloud(&.{ "--target", "prod" }));

    try std.testing.expectEqualStrings("--cloud", deployArgsRequestCloud(&.{"--cloud"}).?);
    try std.testing.expectEqualStrings("--region", deployArgsRequestCloud(&.{ "--region", "us-east" }).?);
    try std.testing.expectEqualStrings("--confirm", deployArgsRequestCloud(&.{"--confirm"}).?);
    try std.testing.expectEqualStrings("--wait", deployArgsRequestCloud(&.{"--wait"}).?);
    try std.testing.expectEqualStrings("--no-wait", deployArgsRequestCloud(&.{"--no-wait"}).?);
}

test "stored provider injection is limited to expert direct dispatch" {
    try std.testing.expect(commandInjectsStoredProviders("expert"));
    try std.testing.expect(!commandInjectsStoredProviders("dev"));
    try std.testing.expect(!commandInjectsStoredProviders("serve"));
    try std.testing.expect(!commandInjectsStoredProviders("init"));
    try std.testing.expect(!commandInjectsStoredProviders("doctor"));
}

test "resolveDeveloperServeBinary re-enters developer CLI for studio and dev" {
    const path = try resolveDeveloperServeBinary(std.testing.allocator, "/tmp/bin/zttp");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/bin/zttp", path);

    const fallback = try resolveDeveloperServeBinary(std.testing.allocator, "");
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings("zttp", fallback);
}

test "resolveReentryBinaryAfterChdir preserves PATH lookup for bare names" {
    const bare = try resolveReentryBinaryAfterChdir(std.testing.allocator, "zttp", "/repo");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("zttp", bare);

    const relative = try resolveReentryBinaryAfterChdir(std.testing.allocator, "./zig-out/bin/zttp", "/repo");
    defer std.testing.allocator.free(relative);
    try std.testing.expect(std.mem.endsWith(u8, relative, "/repo/zig-out/bin/zttp"));

    const absolute = try resolveReentryBinaryAfterChdir(std.testing.allocator, "/usr/local/bin/zttp", "/repo");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/usr/local/bin/zttp", absolute);
}

test "doctorPathExists accepts relative paths" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(io, .{
        .sub_path = "zttp.json",
        .data =
        \\{
        \\  "entry": "examples/handler/handler.ts"
        \\}
        ,
    });
    try tmp.dir.createDirPath(io, "examples/handler");
    try tmp.dir.writeFile(io, .{
        .sub_path = "examples/handler/handler.ts",
        .data =
        \\function handler(req: Request): Response {
        \\    return Response.text("ok");
        \\}
        ,
    });

    try testing.expect(doctorPathExists(io, "examples/handler/handler.ts"));
    try testing.expect(!doctorPathExists(io, "examples/handler/missing.ts"));
}

test "doctorCommand passes configured sqlite path into analyzer" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "zttp.json",
        .data =
        \\{
        \\  "entry": "src/handler.ts",
        \\  "sqlite": "schema.sql"
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "schema.sql",
        .data =
        \\CREATE TABLE users (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL
        \\);
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/handler.ts",
        .data =
        \\import { sql, sqlMany } from "zttp:sql";
        \\
        \\sql("listUsers", "SELECT id, name FROM users ORDER BY id ASC");
        \\
        \\function handler(req: Request): Response & Spec<"state_isolated"> {
        \\    return Response.json({ users: sqlMany("listUsers", {}) });
        \\}
        ,
    });

    var project = try project_config_mod.discover(testing.allocator, io, null);
    defer if (project) |*cfg| cfg.deinit(testing.allocator);

    if (project) |*cfg| {
        const entry = try cfg.resolvedEntry(testing.allocator);
        defer testing.allocator.free(entry);
        const sqlite_path = try cfg.resolvedSqlitePath(testing.allocator);
        defer if (sqlite_path) |path| testing.allocator.free(path);

        var check = try runDoctorAnalyzerForProject(testing.allocator, cfg, entry, sqlite_path);
        defer check.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), check.totalErrors());
    } else {
        return error.NoProjectConfig;
    }
}

test "first-run tour marker is durable: absent then created then detected" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});

    try testing.expect(!cli_tour.tourMarkerExistsAt(allocator, base));
    cli_tour.touchTourMarkerAt(allocator, base);
    try testing.expect(cli_tour.tourMarkerExistsAt(allocator, base));
    // Idempotent: a second touch is harmless.
    cli_tour.touchTourMarkerAt(allocator, base);
    try testing.expect(cli_tour.tourMarkerExistsAt(allocator, base));
}

test "every listed command appears in help --all, and every listing has a command" {
    var buf: [cli_help.help_all_buffer_size]u8 = undefined;
    const help_all = cli_help.renderHelpAllForTest(&buf);

    // Direction 1: a command in the table must be advertised, unless it is
    // deliberately unlisted (the deprecated `proof` alias, and `help` itself).
    for (commands) |c| {
        if (c.section == .unlisted) continue;
        var needle: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&needle, "  zttp {s}", .{c.name});
        std.testing.expect(std.mem.indexOf(u8, help_all, line) != null) catch |err| {
            std.debug.print("help --all does not list `zttp {s}`\n", .{c.name});
            return err;
        };
    }

    // Direction 2: every `  zttp <verb>` line in the listing must dispatch,
    // either from this table or from the shared analyzer registry. This is the
    // half that catches a command deleted from dispatch but left in the text.
    var it = std.mem.splitScalar(u8, help_all, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  zttp ")) continue;
        const rest = line["  zttp ".len..];
        const verb_end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        const verb = rest[0..verb_end];
        if (verb.len == 0) continue;
        var found = false;
        for (commands) |c| {
            if (std.mem.eql(u8, verb, c.name)) found = true;
        }
        for (zts_cli.commands) |c| {
            if (std.mem.eql(u8, verb, c.name)) found = true;
        }
        std.testing.expect(found) catch |err| {
            std.debug.print("help --all advertises `zttp {s}`, which nothing dispatches\n", .{verb});
            return err;
        };
    }
}

test "the command table has no duplicate name or alias" {
    for (commands, 0..) |a, i| {
        for (commands[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
            if (a.alias) |alias| {
                try std.testing.expect(!std.mem.eql(u8, alias, b.name));
                if (b.alias) |other| try std.testing.expect(!std.mem.eql(u8, alias, other));
            }
        }
    }
}
