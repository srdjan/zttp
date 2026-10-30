//! `zttp deploy --local`: build the project handler into a self-contained
//! binary and record the deploy in the local proof ledger. The artifact
//! pipeline (`buildArtifact`) and the project resolution live in
//! build_command.zig.

const std = @import("std");
const writeAllFd = @import("posix_util.zig").writeAllFd;

const build_command = @import("build_command.zig");
const buildArtifact = build_command.buildArtifact;
const prepareProjectArtifact = build_command.prepareProjectArtifact;
const projectRunCommand = build_command.projectRunCommand;
const no_attest_flag = build_command.no_attest_flag;
const no_attest_help_block = build_command.no_attest_help_block;

const LocalDeployCommandOptions = struct {
    attest_requested: bool,
};

pub const LocalDeployArgError = union(enum) {
    missing_target_value,
    duplicate_target,
    unknown_target: []const u8,
    unknown_arg: []const u8,
};

const LocalDeployCommandParse = union(enum) {
    help,
    ok: LocalDeployCommandOptions,
    err: LocalDeployArgError,
};

pub fn parseLocalDeployCommandArgs(argv: []const []const u8) LocalDeployCommandParse {
    var attest_requested = true;
    var target_seen = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help")) {
            return .help;
        }
        if (std.mem.eql(u8, arg, no_attest_flag)) {
            attest_requested = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--local")) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            if (target_seen) return .{ .err = .duplicate_target };
            i += 1;
            if (i >= argv.len or std.mem.startsWith(u8, argv[i], "-")) {
                return .{ .err = .missing_target_value };
            }
            target_seen = true;
            if (!std.mem.eql(u8, argv[i], "local")) {
                return .{ .err = .{ .unknown_target = argv[i] } };
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            if (target_seen) return .{ .err = .duplicate_target };
            const value = arg["--target=".len..];
            if (value.len == 0) return .{ .err = .missing_target_value };
            target_seen = true;
            if (!std.mem.eql(u8, value, "local")) {
                return .{ .err = .{ .unknown_target = value } };
            }
            continue;
        }
        return .{ .err = .{ .unknown_arg = arg } };
    }

    return .{ .ok = .{ .attest_requested = attest_requested } };
}

fn failLocalDeployCommandArgs(err: LocalDeployArgError) !void {
    switch (err) {
        .missing_target_value => {
            std.debug.print("--target requires exactly one value: local.\n\n", .{});
            try printLocalDeployHelp();
            return error.MissingArgument;
        },
        .duplicate_target => {
            std.debug.print("Pass --target only once.\n\n", .{});
            try printLocalDeployHelp();
            return error.InvalidArgument;
        },
        .unknown_target => |target| {
            std.debug.print("Unknown deploy target: {s}. Only 'local' is supported.\n\n", .{target});
            try printLocalDeployHelp();
            return error.InvalidArgument;
        },
        .unknown_arg => |arg| {
            std.debug.print("Unknown argument for `zttp deploy --local`: {s}\n\n", .{arg});
            try printLocalDeployHelp();
            return error.UnknownOption;
        },
    }
}

pub fn localDeployCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseLocalDeployCommandArgs(argv)) {
        .help => {
            try printLocalDeployHelp();
            return;
        },
        .ok => |opts| opts,
        .err => |err| return failLocalDeployCommandArgs(err),
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var artifact = try prepareProjectArtifact(allocator, io_backend.io(), "deploy", null);
    defer artifact.deinit(allocator);

    // proof_ledger.appendEvent writes the relative path `.zttp/proofs.jsonl`,
    // so anchor CWD at the project root before buildArtifact emits the ledger
    // row. The summary block below advertises the ledger; failure here must
    // surface, not silently warn.
    try std.Io.Threaded.chdir(artifact.project.root_dir);

    try buildArtifact(allocator, .{
        .handler_path = artifact.handler_path,
        .output_path = artifact.output_path,
        .sql_schema_path = artifact.compile_context.sql_schema_path,
        .policy = artifact.compile_context.policyPtr(),
        .policy_source = artifact.compile_context.policy_source,
        .ledger_service_name = artifact.project_name,
        .attest_requested = opts.attest_requested,
    });

    const run_command = try projectRunCommand(allocator, &artifact);
    defer allocator.free(run_command);
    std.debug.print(
        \\
        \\Deployed: {s}
        \\Run:      {s}
        \\Try:      curl http://{s}:{d}/
        \\Ledger:   .zttp/proofs.jsonl (kind=deploy)
        \\
        \\Note:     serves plain HTTP and binds 127.0.0.1 by default. For public
        \\          traffic, terminate TLS at a reverse proxy and set the host.
        \\
        \\Inspect the proof ledger: zttp proofs list
        \\
    , .{ artifact.output_path, run_command, artifact.project.host, artifact.project.port });
}

fn printLocalDeployHelp() !void {
    const help =
        \\zttp deploy [--no-attest]
        \\  (--local is an accepted alias; deploy takes no arguments)
        \\
        \\Build a self-contained binary for the handler in this project and
        \\record the deploy in the local proof ledger. No cloud credentials,
        \\Docker, or network access required.
        \\
        \\Reads zttp.json from the current directory or any parent.
        \\Output: .zttp/deploy/<project-name>
        \\Ledger: .zttp/proofs.jsonl (appends a kind=deploy row)
        \\
        \\Options:
        \\  --local               Use the local target (this command)
        \\  --target local        Same as --local
        \\
    ++ no_attest_help_block ++
        \\  --help                Show this help
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}
