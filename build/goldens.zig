//! Checks that run the built `zts` and `zttp` binaries against committed
//! fixtures: module governance, the public contract goldens, the comptime and
//! generic-intersection matrices, and the direct-tool expert contract.
//!
//! scripts/update-contract-goldens.sh and scripts/update-expert-goldens.sh
//! mirror the addExpertGolden entries here; change both together.

const std = @import("std");
const Context = @import("Context.zig");
const artifacts = @import("artifacts.zig");

pub const Result = struct {
    run_module_governance: *std.Build.Step.Run,
    contract_golden_step: *std.Build.Step,
    comptime_cli_step: *std.Build.Step,
    generic_intersection_cli_step: *std.Build.Step,
    expert_golden_step: *std.Build.Step,
};

pub fn add(ctx: Context, bins: artifacts.Binaries) Result {
    const b = ctx.b;
    const zts_exe = bins.zts_exe;
    const cli_exe = bins.cli_exe;

    const run_module_governance = b.addRunArtifact(zts_exe);
    run_module_governance.addArgs(&.{ "verify-modules", "--builtins", "--strict", "--json" });
    const module_governance_step = b.step("test-module-governance", "Run built-in module governance audit");
    module_governance_step.dependOn(&run_module_governance.step);

    // Golden-output checks that run the built `zts` binary and assert
    // stdout is byte-identical to a fixture. Covers the direct-command v1 JSON
    // contract for `meta`, `verify-paths`, and `describe-rule`.
    // Regenerate the fixtures with `scripts/update-expert-goldens.sh` (or by
    // rerunning each command and redirecting into
    // packages/tools/tests/fixtures/expert/) after a deliberate contract
    // change; see docs/zts-expert-contract.md.
    // Public-contract goldens. These pin the analyzer's observable output for a
    // handler set chosen to span distinct analysis paths (plain TS, JSX, every
    // virtual module, durable/workflow) plus the three enumeration commands.
    // Their purpose is refactor safety: a change that claims to preserve
    // behavior must leave every byte here untouched. Contract JSON carries no
    // timestamps, absolute paths, or version strings, so it is byte-stable by
    // construction (verified by rerunning each command before committing).
    // Regenerate with `scripts/update-contract-goldens.sh` after a DELIBERATE
    // contract change, and review the diff: a golden that moves without an
    // intended reason is the gate doing its job.
    const contract_golden_step = b.step("test-contract-golden", "Check analyzer contract output against golden fixtures");
    const contract_fixtures = "packages/tools/tests/fixtures/contract";
    // Exit codes are part of the pinned contract: plain_ts proves clean, the
    // other three carry warnings and exit 1 today.
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/plain_ts.ts", "--json", "--contract",
    }, contract_fixtures ++ "/plain_ts.contract.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/jsx.tsx", "--json", "--contract",
    }, contract_fixtures ++ "/jsx.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/modules_all.ts", "--json", "--contract",
    }, contract_fixtures ++ "/modules_all.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/durable_approval.ts", "--json", "--contract",
    }, contract_fixtures ++ "/durable_approval.contract.golden.json", 1);
    // M4 T2: a clean tool catalog proves clean; the refused one pins its ZTS513
    // diagnostic, so a change to the catalog rules moves a byte here.
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/tool_catalog.ts", "--json", "--contract",
    }, contract_fixtures ++ "/tool_catalog.contract.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/tool_catalog_refused.ts", "--json", "--contract",
    }, contract_fixtures ++ "/tool_catalog_refused.contract.golden.json", 1);
    // B8.2: a tool input arrives structurally typed, so passing a field where a
    // nominal type is required is refused (ZTS203); an explicit annotation in
    // the handler, the developer's reviewed act, brands it.
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/tool_nominal_forged.ts", "--json", "--contract",
    }, contract_fixtures ++ "/tool_nominal_forged.contract.golden.json", 1);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{
        "check", contract_fixtures ++ "/tool_nominal_branded.ts", "--json", "--contract",
    }, contract_fixtures ++ "/tool_nominal_branded.contract.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "features", "--json" }, contract_fixtures ++ "/features.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "modules", "--json" }, contract_fixtures ++ "/modules.golden.json", 0);
    addExpertGolden(b, contract_golden_step, zts_exe, &.{ "restrictions", "--json" }, contract_fixtures ++ "/restrictions.golden.json", 0);

    // Comptime strip failures predate the ZTS registry and currently expose
    // only StripError.ComptimeEvaluationFailed. Pin that exact real-CLI
    // identity, its unregistered JSON shape, and an accepted safe contrast.
    // There is no registry rule to add to the expert replay or coverage page.
    const comptime_cli_step = b.step("test-comptime-cli-matrix", "Run comptime CLI reject and safe-contrast fixtures");
    const comptime_fixtures = "packages/tools/tests/fixtures/comptime";
    addExpertExitCheck(b, comptime_cli_step, zts_exe, &.{
        "check", comptime_fixtures ++ "/safe.ts", "--json",
    }, 0);
    const comptime_reject = b.addRunArtifact(zts_exe);
    comptime_reject.addArgs(&.{ "check", comptime_fixtures ++ "/reject_random.ts", "--json" });
    comptime_reject.expectExitCode(1);
    comptime_reject.expectStdOutEqual("{\"success\":false,\"diagnostics\":[]}\n");
    comptime_reject.expectStdErrEqual("TypeScript strip error: error.ComptimeEvaluationFailed\n");
    comptime_cli_step.dependOn(&comptime_reject.step);

    // Instantiating a generic application must preserve every intersection
    // obligation, including members beyond sixteen. Run the real analyzer so
    // the gate protects the public verdict, not only the representation.
    const generic_intersection_cli_step = b.step(
        "test-generic-intersection-cli-matrix",
        "Run wide generic-intersection reject and safe-contrast fixtures",
    );
    const generic_intersection_fixtures = "packages/tools/tests/fixtures/generic-intersection";
    addExpertExitCheck(b, generic_intersection_cli_step, zts_exe, &.{
        "check", generic_intersection_fixtures ++ "/accept_all_17.ts", "--json",
    }, 0);
    addExpertGolden(b, generic_intersection_cli_step, zts_exe, &.{
        "check", generic_intersection_fixtures ++ "/reject_member_17.ts", "--json",
    }, generic_intersection_fixtures ++ "/reject_member_17.golden.json", 1);

    const expert_golden_step = b.step("test-expert-golden", "Check zts direct tool contract against golden fixtures");
    const fixtures_root = "packages/tools/tests/fixtures/expert";
    // `meta --json` leads with `compiler_version`, which bumps every release.
    // Pinning it in a byte-exact golden made the fixture stale on each release
    // for no contract value. Assert the version-independent tail exactly (policy
    // hash, module hash, rule count, categories, mode) and only that the
    // version field is present, so the meaningful contract stays covered.
    addExpertMetaGolden(b, expert_golden_step, zts_exe, fixtures_root ++ "/meta.golden.json");
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/clean_handler.ts",
        "--json",
    }, fixtures_root ++ "/verify_paths_clean.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/missing.ts",
        "--json",
    }, fixtures_root ++ "/verify_paths_missing.golden.json", 1);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{ "search", "guard", "--json" }, fixtures_root ++ "/search_guard.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{ "describe-rule", "ZTS303", "--json" }, fixtures_root ++ "/describe_rule_ZTS303.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "canonicalize",
        fixtures_root ++ "/canonicalize_mixed.ts",
        "--json",
    }, fixtures_root ++ "/canonicalize_mixed.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "canonicalize",
        fixtures_root ++ "/canonicalize_mixed.ts",
        "--json",
        "--simulate",
    }, fixtures_root ++ "/canonicalize_mixed_simulate.golden.json", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/clean_handler.ts",
    }, fixtures_root ++ "/verify_paths_clean_text.golden.txt", 0);
    addExpertGolden(b, expert_golden_step, zts_exe, &.{
        "verify-paths",
        fixtures_root ++ "/missing.ts",
    }, fixtures_root ++ "/verify_paths_missing_text.golden.txt", 1);

    // Exit-code contract for help/error paths. Stdout isn't pinned because
    // help text edits should not break tests; only the exit code is part of
    // the contract. The `expert` command now lives only in the developer
    // `zttp` binary (cli_exe); analyzer commands stay on `zts` (zts_exe).
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "expert", "--help" }, 0);
    // Compiler-only goal runs must never consult cloud credentials or local
    // model readiness. Keep this at the executable boundary so dispatch and
    // environment injection cannot regress independently of the pi unit tests.
    const goal_without_model = b.addRunArtifact(cli_exe);
    goal_without_model.addArgs(&.{
        "expert",
        "--handler",
        fixtures_root ++ "/clean_handler.ts",
        "--goal",
        "no_secret_leakage",
        "--max-iters",
        "1",
        "--no-session",
    });
    goal_without_model.removeEnvironmentVariable("HOME");
    goal_without_model.removeEnvironmentVariable("ANTHROPIC_API_KEY");
    goal_without_model.removeEnvironmentVariable("OPENAI_API_KEY");
    goal_without_model.setEnvironmentVariable("ZTTP_MLX_BASE_URL", "http://127.0.0.1:1");
    goal_without_model.expectExitCode(0);
    goal_without_model.expectStdOutMatch("autoloop verdict: achieved");
    expert_golden_step.dependOn(&goal_without_model.step);

    // `init --expert` performs the same readiness check before scaffolding.
    // The follow-up absence check is the execution floor for that ordering.
    const init_preflight_root = b.addWriteFiles();
    _ = init_preflight_root.add("preflight-fixture", "");
    const init_preflight = b.addRunArtifact(cli_exe);
    init_preflight.addArgs(&.{ "init", "demo", "--expert" });
    init_preflight.setCwd(init_preflight_root.getDirectory());
    init_preflight.removeEnvironmentVariable("HOME");
    init_preflight.removeEnvironmentVariable("ANTHROPIC_API_KEY");
    init_preflight.removeEnvironmentVariable("OPENAI_API_KEY");
    init_preflight.removeEnvironmentVariable("DEEPSEEK_API_KEY");
    init_preflight.setEnvironmentVariable("ZTTP_MLX_BASE_URL", "http://127.0.0.1:1");
    init_preflight.expectExitCode(1);
    // Names the default provider's credential, so moving the default without
    // moving this line fails here rather than shipping a message for a provider
    // the preflight no longer checks.
    init_preflight.expectStdErrMatch("--provider deepseek requires DEEPSEEK_API_KEY");
    const init_preflight_absence = b.addSystemCommand(&.{ "/bin/test", "!", "-e", "demo" });
    init_preflight_absence.setCwd(init_preflight_root.getDirectory());
    init_preflight_absence.step.dependOn(&init_preflight.step);
    expert_golden_step.dependOn(&init_preflight_absence.step);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "meta", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "verify-paths", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{ "verify-paths", fixtures_root ++ "/clean_handler.ts", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "expert", "no-such-sub" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "ledger", "--help" }, 0);
    addExpertExitCheck(b, expert_golden_step, zts_exe, &.{"verify-paths"}, 1);

    // Machine-command unknown-flag contract (plan 009): a typo'd flag is a loud
    // non-zero exit via the clean dev-CLI mapping, not a silently-ignored arg
    // that yields wrong output for tool/CI callers; valid invocations stay
    // exit 0. These run the developer `zttp` binary (cli_exe), which owns the
    // invalid-arguments message; the analyzer `zts` binary shares the same
    // dispatch. Stdout is intentionally not pinned.
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "features", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "features", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "modules", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "modules", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "meta", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "meta", "--json" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "describe-rule", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "describe-rule", "ZTS303" }, 0);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "search", "--josn" }, 1);
    addExpertExitCheck(b, expert_golden_step, cli_exe, &.{ "search", "guard" }, 0);

    return .{
        .run_module_governance = run_module_governance,
        .contract_golden_step = contract_golden_step,
        .comptime_cli_step = comptime_cli_step,
        .generic_intersection_cli_step = generic_intersection_cli_step,
        .expert_golden_step = expert_golden_step,
    };
}

fn addExpertGolden(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    args: []const []const u8,
    golden_rel: []const u8,
    expected_exit: u8,
) void {
    addExpertRun(b, step, exe, args, expected_exit, golden_rel);
}

/// Version-agnostic golden for `meta --json`. The command's first field is
/// `compiler_version`, which changes every release; matching the whole line
/// byte-for-byte pinned it and made the fixture stale on each version bump.
/// Instead assert the version-independent tail (from `,"policy_version"` to the
/// end) byte-exactly, plus that a `compiler_version` field is present. The
/// golden's stored version value is therefore illustrative, not compared.
fn addExpertMetaGolden(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    golden_rel: []const u8,
) void {
    const golden = b.build_root.handle.readFileAlloc(b.graph.io, golden_rel, b.allocator, .unlimited) catch |err| {
        std.debug.panic("missing expert golden fixture {s}: {s}", .{ golden_rel, @errorName(err) });
    };
    const marker = ",\"policy_version\":";
    const idx = std.mem.indexOf(u8, golden, marker) orelse
        std.debug.panic("meta golden {s} is missing the {s} field", .{ golden_rel, marker });
    const version_independent_tail = golden[idx..];

    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "meta", "--json" });
    run.expectExitCode(0);
    run.expectStdOutMatch("{\"compiler_version\":\"");
    run.expectStdOutMatch(version_independent_tail);
    step.dependOn(&run.step);
}

/// Only the exit code is asserted: help/error text is not part of the
/// contract, so editorial changes don't break the build.
fn addExpertExitCheck(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    args: []const []const u8,
    expected_exit: u8,
) void {
    addExpertRun(b, step, exe, args, expected_exit, null);
}

/// When `golden_rel` is null, only the exit code is asserted.
fn addExpertRun(
    b: *std.Build,
    step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    args: []const []const u8,
    expected_exit: u8,
    golden_rel: ?[]const u8,
) void {
    const run = b.addRunArtifact(exe);
    run.addArgs(args);
    // A handler argument is a plain string in argv, so the run step does not
    // see it as an input and reuses a cached result after the handler is
    // edited: measured by breaking a fixture and watching the step still pass.
    // Declare each one as a file input so the edit reruns the command. A
    // golden that tests the missing-file path passes a handler that does not
    // exist on purpose; there is nothing to track for it.
    for (args) |arg| {
        if (!std.mem.endsWith(u8, arg, ".ts") and !std.mem.endsWith(u8, arg, ".tsx")) continue;
        if (std.fs.path.isAbsolute(arg)) continue;
        b.build_root.handle.access(b.graph.io, arg, .{}) catch continue;
        run.addFileInput(b.path(arg));
    }
    run.expectExitCode(expected_exit);
    // Zig 0.16's run-step still fails non-zero commands that write to stderr
    // unless a stderr check exists. Matching the empty string keeps the
    // contract at "only the exit code matters" for exit-only checks.
    if (golden_rel == null and expected_exit != 0) {
        run.expectStdErrMatch("");
    }
    if (golden_rel) |rel| {
        const expected = b.build_root.handle.readFileAlloc(b.graph.io, rel, b.allocator, .unlimited) catch |err| {
            std.debug.panic("missing expert golden fixture {s}: {s}", .{ rel, @errorName(err) });
        };
        // The golden text is embedded in the step, so editing a golden
        // invalidates the cache. The handler source is declared above.
        run.expectStdOutEqual(expected);
    }
    step.dependOn(&run.step);
}
