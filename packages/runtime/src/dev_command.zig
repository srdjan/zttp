//! `zttp dev` - the local edit loop. `dev` is the magnet surface (implies
//! --watch --prove) and runs the analyzer gate (runDevPreflight) before
//! serving. Dispatch and error-to-exit-code translation stay in dev_cli.main.

const std = @import("std");
const builtin = @import("builtin");

const zts = @import("zts");
const zts_cli = @import("zts_cli");
const precompile = zts_cli.precompile;
const shared = @import("cli_shared.zig");
const project_config_mod = @import("project_config");
const runtime_cli = @import("runtime_cli.zig");
const cli_paths = @import("cli_paths.zig");
const resolveDeveloperServeBinary = cli_paths.resolveDeveloperServeBinary;
const cli_doctor = @import("cli_doctor.zig");
const doctorPathExists = cli_doctor.doctorPathExists;
const printCheckStageFailures = cli_doctor.printCheckStageFailures;

/// Check the serve flags that `dev` forwards to its serve child. `dev` owns
/// `--no-prove`, so the serve parser never sees it. A bad flag prints the same
/// plain message as `zttp serve`, under the `dev` name, and returns
/// `error.InvalidServeFlags`. This runs before the analyzer preflight.
fn validateForwardedServeFlags(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var forwarded = std.ArrayList([]const u8).empty;
    defer forwarded.deinit(allocator);
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--no-prove")) continue;
        try forwarded.append(allocator, arg);
    }
    runtime_cli.validateServeFlags(allocator, forwarded.items) catch |err| {
        if (!builtin.is_test) {
            var buf: [256]u8 = undefined;
            std.debug.print("{s}\n", .{runtime_cli.formatFlagFailure(&buf, "dev", err, forwarded.items)});
        }
        return error.InvalidServeFlags;
    };
}

pub fn devCommand(allocator: std.mem.Allocator, program_path: []const u8, argv: []const []const u8) !void {
    try validateForwardedServeFlags(allocator, argv);
    try runDevPreflight(allocator, argv, "dev");

    const serve_binary = try resolveDeveloperServeBinary(allocator, program_path);
    defer allocator.free(serve_binary);

    // `zttp dev` is the magnet surface: it implies `--watch --prove` so the
    // proof HUD lights up on the first save. `--no-prove` opts out of proof
    // verification but still watches; both flags can be passed explicitly to
    // be a no-op (idempotent).
    const user_no_prove = shared.hasFlag(argv, "--no-prove");
    const user_has_watch = shared.hasFlag(argv, "--watch");
    const user_has_prove = shared.hasFlag(argv, "--prove");

    var child_args = std.ArrayList([]const u8).empty;
    defer child_args.deinit(allocator);
    try child_args.append(allocator, serve_binary);
    try child_args.append(allocator, "serve");
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--no-prove")) continue;
        try child_args.append(allocator, arg);
    }
    if (!user_has_watch) try child_args.append(allocator, "--watch");
    if (!user_has_prove and !user_no_prove) try child_args.append(allocator, "--prove");

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var child = try std.process.spawn(io, .{
        .argv = child_args.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    propagateChildExit(child.wait(io) catch return);
}

/// Mirror the serve child's exit code into the `dev` parent. Without
/// this, a child that `std.process.exit(1)`s (port in use, missing handler,
/// failed server init) leaves the parent returning 0, so callers and CI read
/// a hard failure as success.
fn propagateChildExit(term: std.process.Child.Term) void {
    if (childExitCode(term)) |code| std.process.exit(code);
}

/// Decide the parent exit code for a finished serve child, split out from
/// `propagateChildExit` so it is unit-testable without `std.process.exit`.
/// Non-zero exits and fatal signals propagate. SIGINT remains a clean stop so
/// Ctrl+C keeps its interactive dev behavior.
fn childExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| if (code != 0) code else null,
        .signal => |signal| if (signal == .INT)
            null
        else
            128 + @as(u8, @intCast(@intFromEnum(signal))),
        .stopped, .unknown => null,
    };
}

/// The project's configured capability policy, for a boundary that is about to
/// publish a verdict. A configured policy that cannot be read is a refusal, not
/// an absent policy, so both callers stop rather than analyze without it.
/// Caller frees.
fn loadConfiguredPolicy(
    allocator: std.mem.Allocator,
    project: ?*const project_config_mod.ProjectConfig,
    context: []const u8,
) !?[]u8 {
    const cfg = project orelse return null;
    return cfg.readPolicySource(allocator) catch |err| {
        if (!builtin.is_test) {
            std.debug.print(
                "{s} could not load configured capability policy '{s}': {s}\n",
                .{ context, cfg.policy orelse "", @errorName(err) },
            );
            std.debug.print("Next: repair the policy entry in zttp.json or restore the policy file.\n", .{});
        }
        return error.CheckFailed;
    };
}

fn runDevPreflight(allocator: std.mem.Allocator, argv: []const []const u8, command: []const u8) !void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const explicit_path = shared.findPositionalPath(argv);
    var project = try project_config_mod.discover(allocator, io, explicit_path);
    defer if (project) |*p| p.deinit(allocator);

    const target = if (explicit_path) |path|
        path
    else if (project) |*cfg|
        try cfg.resolvedEntry(allocator)
    else
        return error.NoProjectConfig;
    defer if (explicit_path == null) allocator.free(target);

    if (!doctorPathExists(io, target)) {
        if (!builtin.is_test) {
            std.debug.print("zttp {s} preflight failed: handler not found: {s}\n", .{ command, target });
            std.debug.print("Next: update `entry` in zttp.json or pass an explicit handler path.\n", .{});
        }
        return error.FileNotFound;
    }

    const explicit_sqlite = optionValue(argv, "--sqlite");

    const discovered_sqlite = if (explicit_sqlite == null and project != null)
        try project.?.resolvedSqlitePath(allocator)
    else
        null;
    defer if (discovered_sqlite) |path| allocator.free(path);

    const sqlite_path = explicit_sqlite orelse discovered_sqlite;

    var preflight_label: [64]u8 = undefined;
    const policy_source = try loadConfiguredPolicy(
        allocator,
        if (project) |*cfg| cfg else null,
        std.fmt.bufPrint(&preflight_label, "zttp {s} preflight", .{command}) catch "zttp preflight",
    );
    defer if (policy_source) |source| allocator.free(source);

    var check = precompile.runCheckOnlyWithOptions(allocator, target, .{
        .sql_schema_path = sqlite_path,
        .policy_source = policy_source,
    }) catch |err| {
        if (!builtin.is_test) {
            std.debug.print("zttp {s} preflight could not run for {s}: {}\n", .{ command, target, err });
            std.debug.print("Next: run `zttp check {s}` for full diagnostics.\n", .{target});
        }
        return error.CheckFailed;
    };
    defer check.deinit(allocator);

    if (check.totalErrors() > 0) {
        if (!builtin.is_test) {
            std.debug.print("zttp {s} preflight failed for {s}: {d} error(s)\n", .{ command, target, check.totalErrors() });
            printCheckStageFailures(&check, "  ");
            std.debug.print("Next: fix the errors above, then rerun `zttp {s}`.\n", .{command});
        }
        return error.CheckFailed;
    }

    if (!builtin.is_test) {
        var card_buf: std.ArrayList(u8) = .empty;
        defer card_buf.deinit(allocator);
        var card_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &card_buf);
        precompile.formatProofCard(&card_aw.writer, &check, target);
        card_buf = card_aw.toArrayList();
        if (card_buf.items.len > 0) {
            _ = std.c.write(std.c.STDERR_FILENO, card_buf.items.ptr, card_buf.items.len);
        }
    }
}

fn optionValue(argv: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (!std.mem.eql(u8, argv[i], name)) continue;
        return if (i + 1 < argv.len) argv[i + 1] else null;
    }
    return null;
}

pub fn printDevHelp() void {
    const help =
        \\zttp dev [options] [handler.ts]
        \\
        \\Start the local edit loop. The command runs the analyzer, then
        \\serves the handler with watch mode enabled. By default it also
        \\proves each change before hot-swapping the running handler.
        \\
        \\Common options:
        \\  -p, --port <PORT>     Port to listen on (project default: 3000)
        \\  -h, --host <HOST>     Host to bind to (project default: 127.0.0.1)
        \\  --no-prove            Watch and reload without contract proof gating
        \\  --outbound-http       Enable native outbound HTTP bridge
        \\  --sqlite <FILE>       SQLite database for zttp:sql
        \\  --no-env-check        Skip startup env validation
        \\  --help                Show this help
        \\
        \\If no handler path is passed, the entry in zttp.json is used.
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

test "childExitCode propagates a failed serve child but not a clean stop" {
    // A serve child that std.process.exit(N)s (port in use, missing handler)
    // must surface code N to the dev parent.
    try std.testing.expectEqual(@as(?u8, 1), childExitCode(.{ .exited = 1 }));
    try std.testing.expectEqual(@as(?u8, 2), childExitCode(.{ .exited = 2 }));
    // A clean exit and SIGINT (Ctrl+C of a healthy session) stay 0.
    try std.testing.expectEqual(@as(?u8, null), childExitCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(?u8, null), childExitCode(.{ .signal = .INT }));
    // Fatal child-only signals must not make dev report success.
    try std.testing.expectEqual(@as(?u8, 139), childExitCode(.{ .signal = .SEGV }));
    try std.testing.expectEqual(@as(?u8, 134), childExitCode(.{ .signal = .ABRT }));
    try std.testing.expectEqual(@as(?u8, 137), childExitCode(.{ .signal = .KILL }));
}

test "devCommand refuses a bad serve flag before the analyzer preflight" {
    const testing = std.testing;
    // The handler path does not exist. Preflight would return FileNotFound, so
    // InvalidServeFlags proves the flag check ran first.
    const missing = "no-such-dev-handler.ts";
    try testing.expectError(error.InvalidServeFlags, devCommand(testing.allocator, "zttp", &.{ "-p", "abc", missing }));
    try testing.expectError(error.InvalidServeFlags, devCommand(testing.allocator, "zttp", &.{ "-p", "99999", missing }));
    try testing.expectError(error.InvalidServeFlags, devCommand(testing.allocator, "zttp", &.{ missing, "--port" }));
    try testing.expectError(error.InvalidServeFlags, devCommand(testing.allocator, "zttp", &.{ "--bogus", missing }));
    // A flag `dev` owns passes the check and reaches preflight.
    try testing.expectError(error.FileNotFound, devCommand(testing.allocator, "zttp", &.{ "--no-prove", "-p", "3000", missing }));
}

test "runDevPreflight reports analyzer failure before starting dev loop" {
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
        \\  "entry": "src/handler.ts"
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/handler.ts",
        .data =
        \\function handler(req) {
        \\    return Response.text("ok");
        \\}
        ,
    });

    try testing.expectError(error.CheckFailed, runDevPreflight(testing.allocator, &.{}, "dev"));
}

test "runDevPreflight rejects a handler outside the project capability policy" {
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
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"policy.json\"}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "policy.json",
        .data = "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/handler.ts",
        .data =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const value = env("OTHER_NAME") ?? "fallback";
        \\  return Response.json({ value: value });
        \\}
        ,
    });

    try testing.expectError(error.CheckFailed, runDevPreflight(testing.allocator, &.{}, "dev"));
}
