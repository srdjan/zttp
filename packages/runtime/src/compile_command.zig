//! `zttp compile`: build a self-contained binary from an explicit handler
//! path and `-o` output. The artifact pipeline (`buildArtifact`) and the
//! shared project context live in build_command.zig.

const std = @import("std");
const writeAllFd = @import("posix_util.zig").writeAllFd;

const project_config_mod = @import("project_config");
const build_command = @import("build_command.zig");
const buildArtifact = build_command.buildArtifact;
const CommandArgError = build_command.CommandArgError;
const ProjectCompileContext = build_command.ProjectCompileContext;
const no_attest_flag = build_command.no_attest_flag;
const no_attest_help_block = build_command.no_attest_help_block;

const CompileCommandOptions = struct {
    handler_path: []const u8,
    output_path: []const u8,
    attest_requested: bool,
};

const CompileCommandParse = union(enum) {
    help,
    ok: CompileCommandOptions,
    err: CommandArgError,
};

pub fn parseCompileCommandArgs(argv: []const []const u8) CompileCommandParse {
    var handler_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var attest_requested = true;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) {
                return .{ .err = .missing_output_value };
            }
            output_path = argv[i];
        } else if (std.mem.eql(u8, arg, no_attest_flag)) {
            attest_requested = false;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            handler_path = arg;
        } else {
            // Reject unknown `-`-prefixed flags rather than silently
            // dropping them. Symmetric with buildCommand at :2106-2110.
            // Without this branch, a typo like `--ouptut` was swallowed
            // and the build proceeded against the wrong (or default)
            // state with no diagnostic.
            return .{ .err = .{ .unknown_arg = arg } };
        }
    }

    if (handler_path == null) {
        return .{ .err = .missing_handler_path };
    }
    if (output_path == null) {
        return .{ .err = .missing_output_flag };
    }

    return .{ .ok = .{
        .handler_path = handler_path.?,
        .output_path = output_path.?,
        .attest_requested = attest_requested,
    } };
}

fn failCompileCommandArgs(err: CommandArgError) !void {
    switch (err) {
        .missing_output_value => {
            std.log.err("-o requires an output path", .{});
            return error.MissingArgument;
        },
        .missing_handler_path => {
            std.log.err("handler file path required", .{});
            try printCompileHelp();
            return error.MissingArgument;
        },
        .missing_output_flag => {
            std.log.err("-o <output> required", .{});
            try printCompileHelp();
            return error.MissingArgument;
        },
        .unknown_arg => |arg| {
            std.log.err("Unknown argument: {s}", .{arg});
            try printCompileHelp();
            return error.UnknownOption;
        },
    }
}

pub fn compileCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseCompileCommandArgs(argv)) {
        .help => {
            try printCompileHelp();
            return;
        },
        .ok => |opts| opts,
        .err => |err| return failCompileCommandArgs(err),
    };

    var compile_context = try discoverExplicitCompileContext(allocator, opts.handler_path);
    defer compile_context.deinit(allocator);

    try buildArtifact(allocator, .{
        .handler_path = opts.handler_path,
        .output_path = opts.output_path,
        .sql_schema_path = compile_context.sql_schema_path,
        .policy = compile_context.policyPtr(),
        .policy_source = compile_context.policy_source,
        .attest_requested = opts.attest_requested,
    });
}

/// Resolve project-owned analysis inputs for an explicit handler path. A
/// handler outside a project remains a supported standalone compile, while a
/// handler below zttp.json must use the same schema and capability
/// policy as `build` and `deploy --local`.
pub fn discoverExplicitCompileContext(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
) !ProjectCompileContext {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var project = try project_config_mod.discover(allocator, io_backend.io(), handler_path);
    defer if (project) |*config| config.deinit(allocator);
    const config = if (project) |*value| value else return .{};
    return try ProjectCompileContext.init(allocator, config);
}

fn printCompileHelp() !void {
    const help =
        \\zttp compile <handler.ts> -o <output>
        \\
        \\Compile a handler into a self-contained binary.
        \\Verification is mandatory: the handler must pass all checks.
        \\The output binary wraps the zttp runtime template, which must be
        \\installed alongside zttp as `zttp-runtime`.
        \\
        \\Options:
        \\  -o, --output <PATH>   Output binary path (required)
        \\
    ++ no_attest_help_block ++
        \\  --help                Show this help
        \\
        \\For a no-args version that auto-detects from zttp.json, use
        \\`zttp build` instead.
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}
