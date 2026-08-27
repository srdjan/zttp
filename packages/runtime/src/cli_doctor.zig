//! `zttp doctor` and its diagnostic printers, extracted from dev_cli.zig.
//!
//! Validates the project discovered from the current directory (or an
//! explicit path / handler file) and prints a checklist for the files and
//! runtime options that affect local development.
//!
//! The `--release` passport moved to tooling/release_check.zig
//! (`zig build release-check`): every check it runs reads a file that exists
//! in this repository and in no user project, so it was repository tooling
//! shipped inside the user-facing binary.

const std = @import("std");
const builtin = @import("builtin");
const project_config_mod = @import("project_config");
const zts_cli = @import("zts_cli");
const precompile = zts_cli.precompile;
const self_extract = @import("self_extract.zig");
const cli_paths = @import("cli_paths.zig");
const cli_auth = @import("cli_auth.zig");
const pi_app = @import("pi_app");

pub fn doctorCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    // Rejected by name rather than left to fall through to path handling,
    // where it would read as "cannot read --release: FileNotFound".
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "--release")) {
        std.debug.print(
            "zttp doctor --release moved to repository tooling: run `zig build release-check -- --json` from a zttp checkout.\n",
            .{},
        );
        return error.InvalidArgument;
    }

    if (argv.len > 1) {
        std.debug.print("zttp doctor accepts at most one path.\n\n", .{});
        printDoctorHelp();
        return error.InvalidArgument;
    }

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const start_path = if (argv.len > 0) argv[0] else null;
    var project = try project_config_mod.discover(allocator, io, start_path);
    defer if (project) |*p| p.deinit(allocator);

    if (project) |*cfg| {
        var failures: usize = 0;

        std.debug.print("zttp doctor\n", .{});
        std.debug.print("Project root: {s}\n\n", .{cfg.root_dir});

        printDoctorOk("manifest", cfg.manifest_path);
        printDoctorPlatform();
        printDoctorRuntimeTemplate(allocator);

        const entry = try cfg.resolvedEntry(allocator);
        defer allocator.free(entry);
        const entry_ok = doctorPathExists(io, entry);
        if (!entry_ok) failures += 1;
        printDoctorPath("entry", entry, entry_ok);

        const sqlite_path = try cfg.resolvedSqlitePath(allocator);
        defer if (sqlite_path) |path| allocator.free(path);

        const policy_path = try cfg.resolvedPolicyPath(allocator);
        defer if (policy_path) |path| allocator.free(path);
        const policy_ready = if (policy_path) |path| doctorPathExists(io, path) else true;
        if (policy_path) |path| {
            if (!policy_ready) failures += 1;
            printDoctorPath("policy", path, policy_ready);
        } else {
            printDoctorSkip("policy", "not configured");
        }

        if (entry_ok and policy_ready) {
            if (runDoctorAnalyzerForProject(allocator, cfg, entry, sqlite_path)) |check_value| {
                var check = check_value;
                defer check.deinit(allocator);
                if (check.totalErrors() > 0) {
                    failures += 1;
                    printDoctorCheckFailure(&check);
                } else {
                    std.debug.print("[ok]   check    handler passes analyzer\n", .{});
                }
            } else |err| {
                failures += 1;
                printDoctorAnalyzerError(err);
            }
        } else {
            printDoctorSkip("check", if (!entry_ok) "entry missing" else "configured policy missing");
        }

        if (try cfg.resolvedStaticDir(allocator)) |static_dir| {
            defer allocator.free(static_dir);
            const ok = doctorPathExists(io, static_dir);
            if (!ok) failures += 1;
            printDoctorPath("static", static_dir, ok);
        } else {
            printDoctorSkip("static", "not configured");
        }

        if (sqlite_path) |path| {
            std.debug.print("[info] sqlite   {s}\n", .{path});
        } else {
            printDoctorSkip("sqlite", "not configured");
        }

        if (try cfg.resolvedDurableDir(allocator)) |durable_dir| {
            defer allocator.free(durable_dir);
            std.debug.print("[info] durable  {s}\n", .{durable_dir});
        } else {
            printDoctorSkip("durable", "not configured");
        }

        if (try cfg.resolvedSystemPath(allocator)) |system_path| {
            defer allocator.free(system_path);
            const ok = doctorPathExists(io, system_path);
            if (!ok) failures += 1;
            printDoctorPath("system", system_path, ok);
        } else {
            printDoctorSkip("system", "not configured");
        }

        if (cfg.outbound_hosts.len > 1) {
            std.debug.print("[fail] outbound multiple outboundHosts are configured; current runtime accepts one\n", .{});
            return error.UnsupportedMultipleOutboundHosts;
        }
        if (cfg.outbound_http) {
            if (cfg.outbound_hosts.len == 1) {
                std.debug.print("[ok]   outbound host allowlist: {s}\n", .{cfg.outbound_hosts[0]});
            } else {
                std.debug.print("[warn] outbound enabled without host allowlist\n", .{});
            }
        } else {
            printDoctorSkip("outbound", "not enabled");
        }

        const tests_path = try std.fs.path.resolve(allocator, &.{ cfg.root_dir, "tests", "handler.test.jsonl" });
        defer allocator.free(tests_path);
        printDoctorOptionalPath("tests", tests_path, doctorPathExists(io, tests_path));

        printDoctorExpertProvider(allocator);

        std.debug.print("\n", .{});
        if (failures > 0) {
            std.debug.print("Doctor: {d} required check{s} failed\n", .{ failures, if (failures == 1) @as([]const u8, "") else "s" });
            std.debug.print("Next: fix the failed row above, then run `zttp doctor` again.\n", .{});
            return error.DoctorFailed;
        }
        std.debug.print("Doctor: OK\n", .{});
        std.debug.print("Next: zttp dev\n", .{});
        return;
    }

    if (start_path) |path| {
        std.debug.print("No zttp.json found. Treating '{s}' as ad hoc source.\n", .{path});
        std.Io.Dir.access(std.Io.Dir.cwd(), io, path, .{}) catch |err| {
            std.debug.print("[fail] source   cannot read {s}: {}\n", .{ path, err });
            std.debug.print("Next: pass a readable handler path or run inside a project with zttp.json.\n", .{});
            return error.FileNotFound;
        };
        std.debug.print("Doctor: OK\n", .{});
        return;
    }

    return error.NoProjectConfig;
}

pub fn printDoctorHelp() void {
    const help =
        \\zttp doctor [path]
        \\
        \\Validate the project discovered from the current directory, a handler
        \\path, or a zttp.json path. Prints a checklist for the files and
        \\runtime options that affect local development.
        \\
        \\Checks:
        \\  manifest, entry, capability policy, static directory, system file,
        \\  tests fixture, sqlite/durable settings, outbound HTTP configuration,
        \\  and the default expert model provider.
        \\
        \\Examples:
        \\  zttp doctor
        \\  zttp doctor src/handler.ts
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

pub fn runDoctorAnalyzerForProject(
    allocator: std.mem.Allocator,
    cfg: *const project_config_mod.ProjectConfig,
    entry: []const u8,
    sqlite_path: ?[]const u8,
) !precompile.CheckResult {
    const system_for_check = try cfg.resolvedSystemPath(allocator);
    defer if (system_for_check) |path| allocator.free(path);
    const policy_source = try cfg.readPolicySource(allocator);
    defer if (policy_source) |source| allocator.free(source);
    return try precompile.runCheckOnlyWithOptions(allocator, entry, .{
        .sql_schema_path = sqlite_path,
        .system_path = system_for_check,
        .policy_source = policy_source,
    });
}

fn printDoctorAnalyzerError(err: anyerror) void {
    std.debug.print("[fail] check    handler analyzer could not run: {}\n", .{err});
    std.debug.print("       next     run `zttp check` for full diagnostics after fixing the project paths\n", .{});
}

fn printDoctorCheckFailure(check: *const precompile.CheckResult) void {
    std.debug.print("[fail] check    handler analyzer found {d} error(s)\n", .{check.totalErrors()});
    printCheckStageFailures(check, "       ");
    std.debug.print("       next     run `zttp check` for full diagnostics\n", .{});
}

pub fn printCheckStageFailures(check: *const precompile.CheckResult, prefix: []const u8) void {
    if (check.parse_errors > 0) std.debug.print("{s}parse    {d} error(s)\n", .{ prefix, check.parse_errors });
    if (check.bool_errors > 0) std.debug.print("{s}sound    {d} error(s)\n", .{ prefix, check.bool_errors });
    if (check.type_errors > 0) std.debug.print("{s}types    {d} error(s)\n", .{ prefix, check.type_errors });
    if (check.strict_errors > 0) std.debug.print("{s}strict   {d} error(s)\n", .{ prefix, check.strict_errors });
    if (check.verify_errors > 0) std.debug.print("{s}verify   {d} error(s)\n", .{ prefix, check.verify_errors });
    if (check.flow_errors > 0) std.debug.print("{s}flow     {d} error(s)\n", .{ prefix, check.flow_errors });
    if (check.policy_errors > 0) std.debug.print("{s}policy   {d} error(s)\n", .{ prefix, check.policy_errors });
    const spec_errors = check.totalErrors() -|
        (check.parse_errors + check.bool_errors + check.type_errors + check.strict_errors + check.verify_errors + check.flow_errors + check.policy_errors);
    if (spec_errors > 0) std.debug.print("{s}spec     {d} error(s)\n", .{ prefix, spec_errors });
}

fn printDoctorRuntimeTemplate(allocator: std.mem.Allocator) void {
    const self_path = self_extract.getSelfExePath(allocator) catch {
        printDoctorSkip("runtime", "could not locate current executable");
        return;
    };
    defer allocator.free(self_path);

    const runtime_path = cli_paths.resolveRuntimeBinary(allocator, self_path) catch {
        printDoctorSkip("runtime", "zttp-runtime not found beside zttp");
        return;
    };
    defer allocator.free(runtime_path);

    if (std.mem.endsWith(u8, runtime_path, "zttp-runtime")) {
        printDoctorOk("runtime", runtime_path);
    } else {
        std.debug.print("[warn] runtime  using fallback template: {s}\n", .{runtime_path});
    }
}

/// Non-failing readiness row for the product-default expert provider.
fn printDoctorExpertProvider(allocator: std.mem.Allocator) void {
    cli_auth.injectStoredProvidersIntoEnv(allocator);
    pi_app.checkDefaultProviderReadiness(allocator) catch |err| {
        std.debug.print("[info] expert   default provider not ready ({s})\n", .{@errorName(err)});
        if (err == error.MissingAnthropicCredential) {
            std.debug.print("       next     zttp auth claude\n", .{});
        } else if (err == error.MissingOpenAICredential) {
            std.debug.print("       next     zttp auth openai\n", .{});
        } else {
            std.debug.print("       next     mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080\n", .{});
        }
        return;
    };
    printDoctorOk("expert", "default model provider ready");
}

fn printDoctorPlatform() void {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const supported = (os == .macos or os == .linux) and
        (arch == .x86_64 or arch == .aarch64);
    if (supported) {
        std.debug.print("[ok]   {s:<8} {s}-{s}\n", .{ "platform", @tagName(os), @tagName(arch) });
    } else {
        std.debug.print(
            "[warn] platform {s}-{s} is not an officially supported target (macOS/Linux, x86-64/ARM64)\n",
            .{ @tagName(os), @tagName(arch) },
        );
    }
}

pub fn doctorPathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.access(std.Io.Dir.cwd(), io, path, .{}) catch return false;
    }
    return true;
}

fn printDoctorOk(label: []const u8, detail: []const u8) void {
    std.debug.print("[ok]   {s:<8} {s}\n", .{ label, detail });
}

fn printDoctorSkip(label: []const u8, reason: []const u8) void {
    std.debug.print("[skip] {s:<8} {s}\n", .{ label, reason });
}

fn printDoctorPath(label: []const u8, path: []const u8, ok: bool) void {
    if (ok) {
        printDoctorOk(label, path);
    } else {
        std.debug.print("[fail] {s:<8} missing: {s}\n", .{ label, path });
    }
}

fn printDoctorOptionalPath(label: []const u8, path: []const u8, ok: bool) void {
    if (ok) {
        printDoctorOk(label, path);
    } else {
        std.debug.print("[warn] {s:<8} missing: {s}\n", .{ label, path });
    }
}
