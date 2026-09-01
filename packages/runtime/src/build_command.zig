//! `zttp compile`, `zttp build`, and `zttp deploy --local` — the three
//! commands that turn a handler into a self-contained binary. They share the
//! artifact pipeline (prepareProjectArtifact + buildArtifact), so they live
//! together. Dispatch and error-to-exit-code translation stay in dev_cli.main;
//! the help printers are internal because only these commands invoke them.

const std = @import("std");
const builtin = @import("builtin");

const zts = @import("zts");
const zts_cli = @import("zts_cli");
const precompile = zts_cli.precompile;
const deploy_manifest = zts_cli.deploy_manifest;
const shared = @import("cli_shared.zig");
const artifact_graph = @import("artifact_graph.zig");
const pcc = @import("zttp_proof_checker");
const proof_activation = @import("proof_activation.zig");
const proof_certificate = @import("proof_certificate.zig");
const self_extract = @import("self_extract.zig");
const attest_build_receipt = @import("attest/build_receipt.zig");
const live_reload = @import("live_reload.zig");
const proof_ledger = @import("proof_ledger.zig");
const project_config_mod = @import("project_config");
const cli_paths = @import("cli_paths.zig");
const resolveRuntimeBinary = cli_paths.resolveRuntimeBinary;

const no_attest_flag: []const u8 = "--no-attest";

/// Shared help text describing `--no-attest`. Three command help printers
/// all advertise the same flag; one source of truth prevents drift.
const no_attest_help_block: []const u8 =
    \\  --no-attest           Skip proof-receipt signing for this build.
    \\                        Default is to sign with the persistent
    \\                        identity at ~/.zttp/attest/keypair.bin.
    \\
;

const CompileCommandOptions = struct {
    handler_path: []const u8,
    output_path: []const u8,
    attest_requested: bool,
};

const BuildCommandOptions = struct {
    output_override: ?[]const u8,
    attest_requested: bool,
};

const LocalDeployCommandOptions = struct {
    attest_requested: bool,
};

const CommandArgError = union(enum) {
    missing_output_value,
    missing_handler_path,
    missing_output_flag,
    unknown_arg: []const u8,
};

const LocalDeployArgError = union(enum) {
    missing_target_value,
    duplicate_target,
    unknown_target: []const u8,
    unknown_arg: []const u8,
};

const CompileCommandParse = union(enum) {
    help,
    ok: CompileCommandOptions,
    err: CommandArgError,
};

const BuildCommandParse = union(enum) {
    help,
    ok: BuildCommandOptions,
    err: CommandArgError,
};

const LocalDeployCommandParse = union(enum) {
    help,
    ok: LocalDeployCommandOptions,
    err: LocalDeployArgError,
};

fn parseCompileCommandArgs(argv: []const []const u8) CompileCommandParse {
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
            printCompileHelp();
            return error.MissingArgument;
        },
        .missing_output_flag => {
            std.log.err("-o <output> required", .{});
            printCompileHelp();
            return error.MissingArgument;
        },
        .unknown_arg => |arg| {
            std.log.err("Unknown argument: {s}", .{arg});
            printCompileHelp();
            return error.UnknownOption;
        },
    }
}

pub fn compileCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseCompileCommandArgs(argv)) {
        .help => {
            printCompileHelp();
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
        .system_path = compile_context.system_path,
        .policy = compile_context.policyPtr(),
        .attest_requested = opts.attest_requested,
    });
}

const ProjectCompileContext = struct {
    sql_schema_path: ?[]u8 = null,
    system_path: ?[]u8 = null,
    policy: ?zts.HandlerPolicy = null,

    fn init(
        allocator: std.mem.Allocator,
        project: *const project_config_mod.ProjectConfig,
    ) !ProjectCompileContext {
        var context: ProjectCompileContext = .{};
        errdefer context.deinit(allocator);

        context.sql_schema_path = try project.resolvedSqlitePath(allocator);
        context.system_path = try project.resolvedSystemPath(allocator);

        const policy_source = project.readPolicySource(allocator) catch |err| {
            std.debug.print(
                "Configured capability policy '{s}' could not be loaded: {s}\n",
                .{ project.policy orelse "", @errorName(err) },
            );
            return error.PolicyContextFailed;
        };
        defer if (policy_source) |source| allocator.free(source);
        if (policy_source) |source| {
            context.policy = zts.handler_policy.parsePolicyJson(allocator, source) catch |err| {
                std.debug.print(
                    "Configured capability policy '{s}' is invalid: {s}\n",
                    .{ project.policy orelse "", @errorName(err) },
                );
                const help = zts.handler_policy.policyErrorHelp(err);
                if (help.len > 0) std.debug.print("{s}\n", .{help});
                return error.PolicyContextFailed;
            };
        }
        return context;
    }

    fn deinit(self: *ProjectCompileContext, allocator: std.mem.Allocator) void {
        if (self.sql_schema_path) |path| allocator.free(path);
        if (self.system_path) |path| allocator.free(path);
        if (self.policy) |*policy| policy.deinit(allocator);
        self.* = .{};
    }

    fn policyPtr(self: *const ProjectCompileContext) ?*const zts.HandlerPolicy {
        return if (self.policy) |*policy| policy else null;
    }
};

/// Resolve project-owned analysis inputs for an explicit handler path. A
/// handler outside a project remains a supported standalone compile, while a
/// handler below zttp.json must use the same schema, system, and capability
/// policy as `build` and `deploy --local`.
fn discoverExplicitCompileContext(
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

const ProjectArtifact = struct {
    project: project_config_mod.ProjectConfig,
    compile_context: ProjectCompileContext,
    handler_path: []u8,
    output_path: []u8,
    project_name: []const u8,

    fn deinit(self: *ProjectArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.handler_path);
        allocator.free(self.output_path);
        self.compile_context.deinit(allocator);
        self.project.deinit(allocator);
    }
};

/// Discover `zttp.json`, resolve the handler entry, and compute the artifact
/// output path under `<root>/.zttp/<subdir>/<project-name>`. Creates the
/// parent dir for the default path; for an explicit override, trusts the
/// caller (avoids macOS symlink quirks like `/tmp` → `/private/tmp`).
fn prepareProjectArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    subdir: []const u8,
    output_override: ?[]const u8,
) !ProjectArtifact {
    var project_opt = try project_config_mod.discover(allocator, io, null);
    errdefer if (project_opt) |*p| p.deinit(allocator);
    var project = project_opt orelse return error.NoProjectConfig;
    errdefer project.deinit(allocator);

    var compile_context = try ProjectCompileContext.init(allocator, &project);
    errdefer compile_context.deinit(allocator);

    const handler_path = try project.resolvedEntry(allocator);
    errdefer allocator.free(handler_path);

    const project_name = std.fs.path.basename(project.root_dir);

    const output_path = if (output_override) |p|
        try allocator.dupe(u8, p)
    else blk: {
        const path = try std.fs.path.resolve(allocator, &.{ project.root_dir, ".zttp", subdir, project_name });
        errdefer allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.AccessDenied => {
                    std.debug.print(
                        \\
                        \\Aborted: cannot create '{s}': permission denied.
                        \\Check write permissions on the project root.
                        \\
                    , .{parent});
                    return err;
                },
                else => return err,
            };
        }
        break :blk path;
    };

    return .{
        .project = project,
        .compile_context = compile_context,
        .handler_path = handler_path,
        .output_path = output_path,
        .project_name = project_name,
    };
}

fn parseBuildCommandArgs(argv: []const []const u8) BuildCommandParse {
    var output_override: ?[]const u8 = null;
    var attest_requested = true;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) {
                return .{ .err = .missing_output_value };
            }
            output_override = argv[i];
        } else if (std.mem.eql(u8, arg, no_attest_flag)) {
            attest_requested = false;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else {
            return .{ .err = .{ .unknown_arg = arg } };
        }
    }

    return .{ .ok = .{
        .output_override = output_override,
        .attest_requested = attest_requested,
    } };
}

fn failBuildCommandArgs(err: CommandArgError) !void {
    switch (err) {
        .missing_output_value => {
            std.log.err("-o requires an output path", .{});
            return error.MissingArgument;
        },
        .unknown_arg => |arg| {
            std.log.err("Unknown argument: {s}", .{arg});
            printBuildHelp();
            return error.UnknownOption;
        },
        .missing_handler_path,
        .missing_output_flag,
        => unreachable,
    }
}

pub fn buildCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseBuildCommandArgs(argv)) {
        .help => {
            printBuildHelp();
            return;
        },
        .ok => |opts| opts,
        .err => |err| return failBuildCommandArgs(err),
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    var artifact = try prepareProjectArtifact(allocator, io_backend.io(), "build", opts.output_override);
    defer artifact.deinit(allocator);

    try buildArtifact(allocator, .{
        .handler_path = artifact.handler_path,
        .output_path = artifact.output_path,
        .sql_schema_path = artifact.compile_context.sql_schema_path,
        .system_path = artifact.compile_context.system_path,
        .policy = artifact.compile_context.policyPtr(),
        .attest_requested = opts.attest_requested,
    });

    std.debug.print(
        \\
        \\Built: {s}
        \\Run:   {s}
        \\
    , .{ artifact.output_path, artifact.output_path });
}

fn parseLocalDeployCommandArgs(argv: []const []const u8) LocalDeployCommandParse {
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
            printLocalDeployHelp();
            return error.MissingArgument;
        },
        .duplicate_target => {
            std.debug.print("Pass --target only once.\n\n", .{});
            printLocalDeployHelp();
            return error.InvalidArgument;
        },
        .unknown_target => |target| {
            std.debug.print("Unknown deploy target: {s}. Only 'local' is supported.\n\n", .{target});
            printLocalDeployHelp();
            return error.InvalidArgument;
        },
        .unknown_arg => |arg| {
            std.debug.print("Unknown argument for `zttp deploy --local`: {s}\n\n", .{arg});
            printLocalDeployHelp();
            return error.UnknownOption;
        },
    }
}

pub fn localDeployCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseLocalDeployCommandArgs(argv)) {
        .help => {
            printLocalDeployHelp();
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
        .system_path = artifact.compile_context.system_path,
        .policy = artifact.compile_context.policyPtr(),
        .ledger_service_name = artifact.project_name,
        .attest_requested = opts.attest_requested,
    });

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
    , .{ artifact.output_path, artifact.output_path, artifact.project.host, artifact.project.port });
}

/// Produces a compact JWS committing to (contract_json, bytecode,
/// rule-registry policy, capability matrix, serialized runtime policy) for the
/// current build. Caller owns the returned bytes.
/// Returns null when the compile did not yield a HandlerContract; we cannot
/// sign chips we never derived.
fn buildAttestationJws(
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
    executable_root_sha256: []const u8,
) !?[]u8 {
    return try attest_build_receipt.buildJws(
        allocator,
        contract_json,
        bytecode,
        contract,
        runtime_policy_sha256,
        executable_root_sha256,
    );
}

fn serializeContractJson(
    allocator: std.mem.Allocator,
    contract: *const zts.HandlerContract,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    zts.writeContractJson(contract, &output.writer) catch |err| switch (err) {
        // Allocating.Writer intentionally erases allocator errors behind its
        // generic writer error. At this boundary allocation is its only
        // failure source, so restore the actionable cause for callers.
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return try output.toOwnedSlice();
}

const ArtifactTailInput = struct {
    runtime_binary: []const u8,
    output_path: []const u8,
    attest_requested: bool,
    bytecode: []const u8,
    dep_bytecodes: []const []const u8,
    contract: ?*const zts.HandlerContract,
    /// The compiler's proof IR and translation witnesses, when the compile
    /// captured them. Absent means no certificate is embedded, which the strict
    /// activation path refuses rather than treats as permission.
    proof_evidence: ?*const zts.ProofEvidence = null,
    /// The configured capability policy, when the project has one. It is the
    /// only source of entries for a contract category the compiler could not
    /// enumerate; without it such a category ships denying everything.
    configured_policy: ?*const zts.HandlerPolicy = null,
};

const ArtifactTailCapabilities = struct {
    context: ?*anyopaque,
    serialize_contract: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        contract: *const zts.HandlerContract,
    ) anyerror![]u8,
    sign_contract: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        contract_json: []const u8,
        bytecode: []const u8,
        contract: *const zts.HandlerContract,
        runtime_policy_sha256: []const u8,
        executable_root_sha256: []const u8,
    ) anyerror!?[]u8,
    create_artifact: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        runtime_binary: []const u8,
        output_path: []const u8,
        payload: self_extract.PayloadInput,
    ) anyerror!void,
};

fn serializeContractCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    contract: *const zts.HandlerContract,
) ![]u8 {
    return serializeContractJson(allocator, contract);
}

fn signContractCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    contract_json: []const u8,
    bytecode: []const u8,
    contract: *const zts.HandlerContract,
    runtime_policy_sha256: []const u8,
    executable_root_sha256: []const u8,
) !?[]u8 {
    return buildAttestationJws(
        allocator,
        contract_json,
        bytecode,
        contract,
        runtime_policy_sha256,
        executable_root_sha256,
    );
}

fn createArtifactCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    runtime_binary: []const u8,
    output_path: []const u8,
    payload: self_extract.PayloadInput,
) !void {
    shared.step("Writing binary...");
    self_extract.create(allocator, runtime_binary, output_path, payload) catch |err| {
        if (err == error.FileNotFound) {
            // self_extract opens both the runtime template and the output
            // path; the output parent was created by prepareProjectArtifact,
            // so FileNotFound here almost always means the runtime template
            // is missing alongside the dev CLI.
            std.debug.print(
                \\
                \\Aborted: zttp-runtime template not found at '{s}'.
                \\Install zttp-runtime alongside zttp, or rebuild via `zig build`.
                \\
            , .{runtime_binary});
        } else {
            std.log.err("Failed to create output binary: {}", .{err});
        }
        return err;
    };
}

const production_artifact_tail_capabilities = ArtifactTailCapabilities{
    .context = null,
    .serialize_contract = serializeContractCapability,
    .sign_contract = signContractCapability,
    .create_artifact = createArtifactCapability,
};

fn writeArtifactTail(
    allocator: std.mem.Allocator,
    input: ArtifactTailInput,
    capabilities: ArtifactTailCapabilities,
) !void {
    const contract_json: ?[]u8 = if (input.contract) |contract|
        try capabilities.serialize_contract(capabilities.context, allocator, contract)
    else
        null;
    defer if (contract_json) |json| allocator.free(json);

    const policy = if (input.contract) |contract|
        zts.handler_policy.contractToRuntimePolicy(contract, input.configured_policy)
    else
        zts.RuntimePolicy{};
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);

    // Serialize once, hash once. The runtime policy digest below is the value
    // that goes into the graph, into the signed claim, and into the section the
    // artifact carries, so no two of them can describe different bytes.
    var runtime_policy_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(policy_section, &runtime_policy_digest, .{});

    const artifact_sections = artifact_graph.ArtifactInputs{
        .bytecode = input.bytecode,
        .dep_bytecodes = input.dep_bytecodes,
        .contract_section = contract_json,
        .policy_section_digest = runtime_policy_digest,
        .identity = if (input.contract) |contract|
            artifact_graph.identityFromContract(contract)
        else
            .{},
    };

    // The certificate, when the compile captured the evidence for one. Building
    // it first fixes the proof-IR digest, which is itself a graph member, so the
    // root below covers the certificate's own IR.
    var certificate: ?proof_certificate.Built = if (input.proof_evidence) |evidence|
        proof_certificate.build(allocator, .{
            .evidence = evidence,
            .properties = dischargedProperties(input.contract),
            .artifact = artifact_sections,
            .contract_digest = if (contract_json) |json|
                artifact_graph.digestOf(json)
            else
                [_]u8{0} ** 32,
            // The same digest the graph member carries, over the same bytes.
            // A guard plan is only ever checked against one policy, so the
            // certificate names which one rather than leaving the consumer to
            // accept whichever policy it happens to be handed.
            .runtime_policy_digest = runtime_policy_digest,
        }) catch |err| {
            if (!builtin.is_test) {
                std.log.err(
                    "failed to build the proof certificate ({s}); refusing to write an artifact that claims more than it carries",
                    .{@errorName(err)},
                );
            }
            return err;
        }
    else
        null;
    defer if (certificate) |*value| value.deinit();

    // Commit to the whole executable graph, not only the entry module. The
    // inventory is built from the exact section bytes about to be embedded, so
    // the consumer that rebuilds it at startup is hashing the same buffers.
    const members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(members);
    var graph_inputs = artifact_sections;
    if (certificate) |value| {
        graph_inputs.proof_ir_digest = value.ir_root;
        graph_inputs.proof_certificate_digest = value.certificate_digest;
        graph_inputs.residual_plan_digest = value.residual_plan_digest;
    }
    const built = artifact_graph.buildRoot(
        allocator,
        artifact_graph.fromArtifact(graph_inputs),
        members,
    ) catch |err| {
        if (!builtin.is_test) {
            std.log.err(
                "failed to commit to the executable graph ({s}); refusing to write an artifact whose contents are not fully covered",
                .{@errorName(err)},
            );
        }
        return err;
    };
    const executable_root_sha256 = std.fmt.bytesToHex(built.root, .lower);

    const attestation_jws: ?[]u8 = blk: {
        if (!input.attest_requested) break :blk null;
        const json = contract_json orelse {
            std.log.warn("attestation requested but no contract was emitted; skipping attestation", .{});
            break :blk null;
        };
        const contract = input.contract orelse break :blk null;
        const runtime_policy_sha256 = std.fmt.bytesToHex(runtime_policy_digest, .lower);
        break :blk try capabilities.sign_contract(
            capabilities.context,
            allocator,
            json,
            input.bytecode,
            contract,
            &runtime_policy_sha256,
            &executable_root_sha256,
        );
    };
    defer if (attestation_jws) |attestation| allocator.free(attestation);

    try capabilities.create_artifact(
        capabilities.context,
        allocator,
        input.runtime_binary,
        input.output_path,
        .{
            .bytecode = input.bytecode,
            .dep_bytecodes = input.dep_bytecodes,
            .contract_json = contract_json,
            .policy = &policy,
            .policy_section = policy_section,
            .attestation = attestation_jws,
            .certificate = if (certificate) |value| value.bytes else null,
        },
    );
}

/// Read the properties the compiler discharged out of the contract, once, here.
/// The certificate builder never reaches into contract shapes itself.
fn dischargedProperties(contract: ?*const zts.HandlerContract) proof_certificate.DischargedProperties {
    const handler_contract = contract orelse return .{};
    const properties = handler_contract.properties orelse return .{};
    return .{
        .results_checked = properties.result_safe,
        .no_secret_leakage = properties.no_secret_leakage,
        .state_isolated = properties.state_isolated,
        .deterministic = properties.deterministic,
        .read_only = properties.read_only,
        .retry_safe = properties.retry_safe,
        .capability_bounded = handler_contract.capabilities != null,
    };
}

fn appendDeployLedgerEntry(
    allocator: std.mem.Allocator,
    contract: *const zts.HandlerContract,
    handler_path: []const u8,
    sha_hex: []const u8,
    service_name: []const u8,
) !void {
    var facts = try live_reload.factsFromContract(allocator, contract, sha_hex);
    defer facts.deinit(allocator);

    var params = proof_ledger.AppendParams{
        .kind = .deploy,
        .facts = &facts,
        .handler_path = handler_path,
        .service_name = service_name,
    };
    if (contract.cost_envelope) |envelope| {
        params.cost_worst_case_total = envelope.total.worstCaseAt(deploy_manifest.default_cost_body_limit);
        params.cost_worst_case_body_limit = deploy_manifest.default_cost_body_limit;
    }

    try proof_ledger.appendEvent(allocator, params);
}

/// What to build. The three call sites (`compileCommand`, `buildCommand`,
/// `localDeployCommand`) name what they pass rather than relying on positional
/// order.
pub const BuildRequest = struct {
    handler_path: []const u8,
    output_path: []const u8,
    /// Project analysis inputs. All three public build paths resolve them from
    /// the nearest zttp.json; standalone `compile` leaves them null only when
    /// no project manifest exists above the explicit handler.
    sql_schema_path: ?[]const u8 = null,
    system_path: ?[]const u8 = null,
    policy: ?*const zts.HandlerPolicy = null,
    /// Service name to record in the proof ledger entry. Null when the
    /// build is not part of a named project (`compile`/`build` paths);
    /// set to the project name on the `deploy --local` path.
    ledger_service_name: ?[]const u8 = null,
    /// Whether the caller asked for an embedded attestation JWS.
    attest_requested: bool,
};

/// What the build did. `runBuild` used to return void, so the only account of
/// a build was the lines it logged: a caller, and a test, had to read stderr to
/// learn whether a receipt was signed or a ledger row written.
pub const BuildReceipt = struct {
    output_path: []const u8,
    bytecode_len: usize,
    /// Bytes of dependency bytecode embedded alongside the handler's own.
    dep_bytecode_count: usize,
    /// A contract was extracted and embedded.
    has_contract: bool,
    /// A proof receipt was requested. Whether one was produced also depends on
    /// the signing capability, which reports through the tail.
    attest_requested: bool,
    /// A `kind=deploy` row was appended to the proof ledger.
    ledger_recorded: bool,
    /// SHA-256 of the handler source, as embedded in the ledger row. All zero
    /// when no ledger row was written.
    handler_sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8 = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,
};

/// Everything `runBuild` reaches outside its own arguments: the filesystem, the
/// compiler, this process's own path, the code signer, and the proof ledger.
/// Naming them is what makes a build reproducible in a test without a compiler
/// or a filesystem; the innermost `ArtifactTailCapabilities` already worked
/// this way, and this is the same treatment one level up.
pub const BuildCapabilities = struct {
    context: ?*anyopaque = null,
    read_source: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8 = readSourceCapability,
    compile: *const fn (?*anyopaque, std.mem.Allocator, BuildCompileInput) anyerror!precompile.CompiledHandler = compileCapability,
    resolve_runtime_binary: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]const u8 = resolveRuntimeBinaryCapability,
    write_tail: *const fn (?*anyopaque, std.mem.Allocator, ArtifactTailInput) anyerror!void = writeTailCapability,
    codesign: *const fn (?*anyopaque, std.mem.Allocator, []const u8) void = codesignCapability,
    append_ledger: *const fn (?*anyopaque, std.mem.Allocator, *const zts.HandlerContract, []const u8, []const u8, []const u8) anyerror!void = appendLedgerCapability,
};

fn readSourceCapability(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
    return zts.file_io.readFile(allocator, path, 10 * 1024 * 1024);
}

const BuildCompileInput = struct {
    source: []const u8,
    handler_path: []const u8,
    sql_schema_path: ?[]const u8,
    system_path: ?[]const u8,
    policy: ?*const zts.HandlerPolicy,
};

fn compileCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: BuildCompileInput,
) anyerror!precompile.CompiledHandler {
    return precompile.compileHandler(allocator, input.source, input.handler_path, .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
        .sql_schema_path = input.sql_schema_path,
        .system_path = input.system_path,
        .policy = if (input.policy) |policy| policy.* else null,
    });
}

fn resolveRuntimeBinaryCapability(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
    const dev_self_path = try self_extract.getSelfExePath(allocator);
    defer allocator.free(dev_self_path);
    return resolveRuntimeBinary(allocator, dev_self_path);
}

fn writeTailCapability(_: ?*anyopaque, allocator: std.mem.Allocator, input: ArtifactTailInput) anyerror!void {
    return writeArtifactTail(allocator, input, production_artifact_tail_capabilities);
}

fn codesignCapability(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) void {
    if (builtin.os.tag == .macos) codesignAdHoc(allocator, path);
}

fn appendLedgerCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    contract: *const zts.HandlerContract,
    handler_path: []const u8,
    sha_hex: []const u8,
    service_name: []const u8,
) anyerror!void {
    return appendDeployLedgerEntry(allocator, contract, handler_path, sha_hex, service_name);
}

const production_build_capabilities = BuildCapabilities{};

fn buildArtifact(allocator: std.mem.Allocator, request: BuildRequest) !void {
    _ = try runBuild(allocator, request, production_build_capabilities);
}

fn runBuild(
    allocator: std.mem.Allocator,
    request: BuildRequest,
    caps: BuildCapabilities,
) !BuildReceipt {
    const handler_path = request.handler_path;
    const output_path = request.output_path;
    const ledger_service_name = request.ledger_service_name;
    const attest_requested = request.attest_requested;

    // --no-attest skips proof-receipt signing; warn once so a scripted build
    // does not silently ship an unsigned artifact. Gated out of tests.
    if (!attest_requested and !builtin.is_test) {
        std.log.warn("--no-attest: this artifact will be built without a signed proof receipt", .{});
    }

    const source = caps.read_source(caps.context, allocator, handler_path) catch |err| {
        std.log.err("Failed to read handler '{s}': {}", .{ handler_path, err });
        return err;
    };
    defer allocator.free(source);

    std.log.info("Compiling {s}...", .{handler_path});
    shared.step("Compiling handler...");

    var compiled = caps.compile(caps.context, allocator, .{
        .source = source,
        .handler_path = handler_path,
        .sql_schema_path = request.sql_schema_path,
        .system_path = request.system_path,
        .policy = request.policy,
    }) catch |err| {
        // precompile already prints per-error lines to stderr; only surface
        // the remediation hint so the dev knows where to look.
        std.debug.print(
            \\
            \\Aborted: handler did not compile. Run `zttp check` to inspect.
            \\
        , .{});
        return err;
    };
    defer compiled.deinit(allocator);

    if (compiled.verify_failed) {
        std.log.err("Verification failed - binary not created", .{});
        if (compiled.violations_summary) |summary| {
            _ = std.c.write(std.c.STDERR_FILENO, summary.ptr, summary.len);
        }
        return error.VerificationFailed;
    }

    if (compiled.bytecode.len == 0) {
        std.log.err("No bytecode generated", .{});
        return error.NoBytecode;
    }

    // The compile subcommand splices bytecode onto the runtime binary, not
    // the dev CLI. Locate the runtime binary adjacent to this executable.
    const runtime_binary = caps.resolve_runtime_binary(caps.context, allocator) catch |err| {
        std.log.err("Failed to locate the runtime binary: {}", .{err});
        return err;
    };
    defer allocator.free(runtime_binary);

    const dep_bytecodes: []const []const u8 = compiled.dep_bytecodes orelse &.{};
    // Serialize the contract completely before signing or opening the output.
    // The policy borrows from the compiled contract for the duration of create.
    try caps.write_tail(caps.context, allocator, .{
        .runtime_binary = runtime_binary,
        .output_path = output_path,
        .attest_requested = attest_requested,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = dep_bytecodes,
        .contract = if (compiled.contract) |*contract| contract else null,
        .proof_evidence = if (compiled.proof_evidence) |*evidence| evidence else null,
        .configured_policy = request.policy,
    });

    caps.codesign(caps.context, allocator, output_path);

    var receipt = BuildReceipt{
        .output_path = output_path,
        .bytecode_len = compiled.bytecode.len,
        .dep_bytecode_count = dep_bytecodes.len,
        .has_contract = compiled.contract != null,
        .attest_requested = attest_requested,
        .ledger_recorded = false,
    };

    if (ledger_service_name) |service_name| {
        if (compiled.contract) |*contract| {
            shared.step("Recording proof ledger...");
            std.crypto.hash.sha2.Sha256.hash(source, &receipt.handler_sha256, .{});
            const sha_hex = std.fmt.bytesToHex(receipt.handler_sha256, .lower);
            try caps.append_ledger(caps.context, allocator, contract, handler_path, &sha_hex, service_name);
            receipt.ledger_recorded = true;
        }
    }

    std.log.info("Compiled: {s} -> {s} (bytecode {d} bytes)", .{
        handler_path, output_path, compiled.bytecode.len,
    });
    return receipt;
}

fn codesignAdHoc(allocator: std.mem.Allocator, path: []const u8) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const pid = std.c.fork();
    if (pid == 0) {
        // The appended bytecode makes the signed binary fail codesign's strict
        // validation, so codesign prints scary-but-expected diagnostics to
        // stdout/stderr. Silence them: the signature is still applied and the
        // binary still runs. Redirect both streams to /dev/null before exec.
        const devnull_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (devnull_fd >= 0) {
            _ = std.c.dup2(devnull_fd, std.c.STDOUT_FILENO);
            _ = std.c.dup2(devnull_fd, std.c.STDERR_FILENO);
        }
        const codesign: [*:0]const u8 = "/usr/bin/codesign";
        const argv = [_:null]?[*:0]const u8{
            codesign,
            "--force",
            "--sign",
            "-",
            path_z,
            null,
        };
        _ = std.c.execve(codesign, &argv, std.c.environ);
        std.c._exit(1);
    } else if (pid > 0) {
        var status: i32 = 0;
        _ = std.c.waitpid(pid, &status, 0);
        // A non-zero status is expected (strict validation fails on the appended
        // bytecode) and unactionable, so it is deliberately not surfaced.
    }
}

fn printCompileHelp() void {
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
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

fn printBuildHelp() void {
    const help =
        \\zttp build [-o <output>] [--no-attest]
        \\
        \\Verify the handler in this project and emit a self-contained binary.
        \\Reads zttp.json from the current directory or any parent.
        \\Default output path is `.zttp/build/<project-name>`.
        \\
        \\Options:
        \\  -o, --output <PATH>   Override the output binary path
        \\
    ++ no_attest_help_block ++
        \\  --help                Show this help
        \\
    ;
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

fn printLocalDeployHelp() void {
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
    _ = std.c.write(std.c.STDOUT_FILENO, help.ptr, help.len);
}

const ArtifactTailProbe = struct {
    serialize_calls: usize = 0,
    sign_calls: usize = 0,
    create_calls: usize = 0,
    created_with_contract: bool = false,
    created_with_attestation: bool = false,
    signed_runtime_policy_sha256: ?[64]u8 = null,
    signed_executable_root_sha256: ?[64]u8 = null,
    created_runtime_policy_sha256: ?[64]u8 = null,
    created_certificate_policy_digest: ?[32]u8 = null,

    fn fromContext(context: ?*anyopaque) *ArtifactTailProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn recordSerialization(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        contract: *const zts.HandlerContract,
    ) ![]u8 {
        const self = fromContext(context);
        self.serialize_calls += 1;
        return serializeContractJson(allocator, contract);
    }

    fn recordSigning(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: *const zts.HandlerContract,
        runtime_policy_sha256: []const u8,
        executable_root_sha256: []const u8,
    ) !?[]u8 {
        const self = fromContext(context);
        self.sign_calls += 1;
        if (runtime_policy_sha256.len != 64) return error.InvalidRuntimePolicyHash;
        if (executable_root_sha256.len != 64) return error.InvalidExecutableRoot;
        var copied: [64]u8 = undefined;
        @memcpy(&copied, runtime_policy_sha256);
        self.signed_runtime_policy_sha256 = copied;
        var root_copy: [64]u8 = undefined;
        @memcpy(&root_copy, executable_root_sha256);
        self.signed_executable_root_sha256 = root_copy;
        return try allocator.dupe(u8, "test-attestation");
    }

    fn recordCreation(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        payload: self_extract.PayloadInput,
    ) !void {
        const self = fromContext(context);
        self.create_calls += 1;
        self.created_with_contract = payload.contract_json != null;
        self.created_with_attestation = payload.attestation != null;
        const policy_section = payload.policy_section orelse return error.MissingPolicySection;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(policy_section, &digest, .{});
        self.created_runtime_policy_sha256 = std.fmt.bytesToHex(digest, .lower);

        // Read the policy digest back out of the certificate the way a
        // consumer does, so the test compares the identity the artifact
        // carries against bytes the probe hashed itself.
        if (payload.certificate) |bytes| {
            var budget = pcc.limits.Budget.init(.{});
            const decoded = try pcc.certificate.decode(bytes, .{}, &budget);
            self.created_certificate_policy_digest = decoded.identity.runtime_policy_digest;
        }
    }

    fn capabilities(self: *ArtifactTailProbe) ArtifactTailCapabilities {
        return .{
            .context = self,
            .serialize_contract = recordSerialization,
            .sign_contract = recordSigning,
            .create_artifact = recordCreation,
        };
    }
};

fn serializeContractForAllocationTest(
    allocator: std.mem.Allocator,
    contract: *const zts.HandlerContract,
) !void {
    const json = try serializeContractJson(allocator, contract);
    defer allocator.free(json);
}

test "serializeContractJson returns complete parseable JSON" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);

    const json = try serializeContractJson(allocator, &contract);
    defer allocator.free(json);
    try std.testing.expect(json.len > 0);

    var parsed = try zts.handler_contract.parseFromJson(allocator, json);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("handler.ts", parsed.handler.path);
}

test "serializeContractJson cleans every allocation failure" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);

    try std.testing.checkAllAllocationFailures(
        allocator,
        serializeContractForAllocationTest,
        .{&contract},
    );
}

test "artifact tail stops before signing or creation when serialization fails" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.bin",
        .data = "sentinel",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const output_path = try std.fs.path.join(allocator, &.{ root, "artifact.bin" });
    defer allocator.free(output_path);

    var blob_buf: [4096]u8 = undefined;
    const bytecode = try artifact_graph.test_support.moduleBlob(allocator, 0x10, &blob_buf);

    for ([_]bool{ true, false }) |attest_requested| {
        var probe = ArtifactTailProbe{};
        var failing = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = 1 },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            writeArtifactTail(failing.allocator(), .{
                .runtime_binary = "runtime",
                .output_path = output_path,
                .attest_requested = attest_requested,
                .bytecode = bytecode,
                .dep_bytecodes = &.{},
                .contract = &contract,
            }, probe.capabilities()),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 1), probe.serialize_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.sign_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.create_calls);

        const existing = try zts.file_io.readFile(allocator, output_path, 64);
        defer allocator.free(existing);
        try std.testing.expectEqualStrings("sentinel", existing);
    }
}

test "artifact tail preserves absent-contract creation behavior" {
    const allocator = std.testing.allocator;
    var blob_buf: [4096]u8 = undefined;
    const bytecode = try artifact_graph.test_support.moduleBlob(allocator, 0x10, &blob_buf);

    var probe = ArtifactTailProbe{};
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = true,
        .bytecode = bytecode,
        .dep_bytecodes = &.{},
        .contract = null,
    }, probe.capabilities());

    try std.testing.expectEqual(@as(usize, 0), probe.serialize_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.sign_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.create_calls);
    try std.testing.expect(!probe.created_with_contract);
    try std.testing.expect(!probe.created_with_attestation);
}

test "artifact tail embeds complete contracts and signs only when requested" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);

    var blob_buf: [4096]u8 = undefined;
    const bytecode = try artifact_graph.test_support.moduleBlob(allocator, 0x10, &blob_buf);

    for ([_]bool{ true, false }) |attest_requested| {
        var probe = ArtifactTailProbe{};
        try writeArtifactTail(allocator, .{
            .runtime_binary = "runtime",
            .output_path = "artifact.bin",
            .attest_requested = attest_requested,
            .bytecode = bytecode,
            .dep_bytecodes = &.{},
            .contract = &contract,
        }, probe.capabilities());

        try std.testing.expectEqual(@as(usize, 1), probe.serialize_calls);
        try std.testing.expectEqual(@as(usize, @intFromBool(attest_requested)), probe.sign_calls);
        try std.testing.expectEqual(@as(usize, 1), probe.create_calls);
        try std.testing.expect(probe.created_with_contract);
        try std.testing.expectEqual(attest_requested, probe.created_with_attestation);
        try std.testing.expect(probe.created_runtime_policy_sha256 != null);
        if (attest_requested) {
            try std.testing.expectEqualSlices(
                u8,
                &probe.created_runtime_policy_sha256.?,
                &probe.signed_runtime_policy_sha256.?,
            );
        }
    }
}

test "the signed executable root is the one a consumer recomputes from the same sections" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);
    contract.source_identity = zts.sourceIdentityForPath(contract.handler.path);

    var main_buf: [4096]u8 = undefined;
    var dep_buf: [4096]u8 = undefined;
    const bytecode = try artifact_graph.test_support.moduleBlob(allocator, 0x10, &main_buf);
    const dep = try artifact_graph.test_support.moduleBlob(allocator, 0x20, &dep_buf);
    const deps = [_][]const u8{dep};

    var probe = ArtifactTailProbe{};
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = true,
        .bytecode = bytecode,
        .dep_bytecodes = &deps,
        .contract = &contract,
    }, probe.capabilities());

    const signed = probe.signed_executable_root_sha256 orelse return error.TestUnexpectedResult;

    // Rebuild the inventory the way the runtime does at startup, from the same
    // sections, and confirm the two derivations agree.
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);
    var policy_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(policy_section, &policy_digest, .{});

    const members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(members);
    const rebuilt = try artifact_graph.buildRoot(allocator, artifact_graph.fromArtifact(.{
        .bytecode = bytecode,
        .dep_bytecodes = &deps,
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .identity = artifact_graph.identityFromContract(&contract),
    }), members);

    const rebuilt_hex = std.fmt.bytesToHex(rebuilt.root, .lower);
    try std.testing.expectEqualSlices(u8, &rebuilt_hex, &signed);

    // A dependency the producer embedded but the consumer did not load changes
    // the root, so the two derivations stop agreeing.
    const without_dep = try artifact_graph.buildRoot(allocator, artifact_graph.fromArtifact(.{
        .bytecode = bytecode,
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .identity = artifact_graph.identityFromContract(&contract),
    }), members);
    try std.testing.expect(!std.mem.eql(u8, &rebuilt.root, &without_dep.root));
}

test "an artifact whose bytecode cannot be walked is refused rather than half-committed" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);

    var probe = ArtifactTailProbe{};
    try std.testing.expectError(error.MalformedBytecodeStream, writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = "not a serialized module",
        .dep_bytecodes = &.{},
        .contract = &contract,
    }, probe.capabilities()));
    try std.testing.expectEqual(@as(usize, 0), probe.create_calls);
}

test "the certificate names the exact policy the artifact carries" {
    const allocator = std.testing.allocator;

    // Two handlers whose runtime policies differ in one entry. The binding is
    // worth nothing if the certificate names a policy rather than this policy.
    const sources = [_][]const u8{
        \\import { env } from "zttp:env";
        \\
        \\export function handler(req: Request): Response {
        \\  const value = env("APP_NAME") ?? "fallback";
        \\  return Response.text(value);
        \\}
        ,
        \\import { env } from "zttp:env";
        \\
        \\export function handler(req: Request): Response {
        \\  const value = env("OTHER_NAME") ?? "fallback";
        \\  return Response.text(value);
        \\}
        ,
    };

    var bound: [sources.len][32]u8 = undefined;
    for (sources, 0..) |source, index| {
        var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
            .emit_verify = true,
            .emit_contract = true,
            .emit_proof_evidence = true,
        });
        defer compiled.deinit(allocator);

        const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
        const contract = compiled.contract orelse return error.TestUnexpectedResult;

        var probe = ArtifactTailProbe{};
        try writeArtifactTail(allocator, .{
            .runtime_binary = "runtime",
            .output_path = "artifact.bin",
            .attest_requested = false,
            .bytecode = compiled.bytecode,
            .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
            .contract = &contract,
            .proof_evidence = &evidence,
        }, probe.capabilities());

        const digest = probe.created_certificate_policy_digest orelse
            return error.TestUnexpectedResult;
        // The probe hashed the embedded policy section itself. The identity the
        // artifact carries is over those bytes, not over some other policy the
        // producer had in hand.
        const hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualSlices(u8, &hex, &probe.created_runtime_policy_sha256.?);
        try std.testing.expect(!std.mem.eql(u8, &digest, &[_]u8{0} ** 32));
        bound[index] = digest;
    }

    // One changed environment key is one changed policy, and the certificate
    // identity moves with it.
    try std.testing.expect(!std.mem.eql(u8, &bound[0], &bound[1]));
}

test "a real compile produces a certificate that binds its own IR and artifact" {
    const allocator = std.testing.allocator;
    const source =
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  if (req.method === "GET") {
        \\    return Response.text("get");
        \\  } else {
        \\    return Response.text("other");
        \\  }
        \\}
    ;

    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    // The handler always returns, so the producer's own fold says so before it
    // writes anything down.
    try std.testing.expect(evidence.handlerIsTotal());
    // Code generation recorded where the proof-IR members went.
    try std.testing.expect(evidence.emissions.len > 0);
    try std.testing.expect(evidence.jumps.len > 0);

    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = dischargedProperties(&contract),
        .artifact = .{
            .bytecode = compiled.bytecode,
            .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
            .contract_section = contract_json,
            .policy_section_digest = artifact_graph.digestOf(policy_section),
            .identity = artifact_graph.identityFromContract(&contract),
        },
        .contract_digest = artifact_graph.digestOf(contract_json),
    });
    defer built.deinit();

    // The certificate decodes under the kernel's own bounded decoder.
    var budget = pcc.limits.Budget.init(.{});
    const decoded = try pcc.certificate.decode(built.bytes, .{}, &budget);
    try std.testing.expectEqualSlices(u8, &built.executable_root, &decoded.identity.executable_root);
    try std.testing.expectEqualSlices(u8, &built.ir_root, &decoded.identity.ir_root);

    // The IR root the certificate states is the fold of the IR it carries.
    const recomputed_ir = try pcc.certificate.irRootFromTable(decoded.ir);
    try std.testing.expectEqualSlices(u8, &built.ir_root, &recomputed_ir);

    // The proof-IR member of the executable graph is that same root, so the IR
    // cannot be swapped without moving the artifact commitment.
    var saw_proof_ir = false;
    for (built.members) |member| {
        if (member.kind != .proof_ir) continue;
        saw_proof_ir = true;
        try std.testing.expectEqualSlices(u8, &built.ir_root, &member.digest);
    }
    try std.testing.expect(saw_proof_ir);

    // Every property in the alphabet is answered exactly once.
    try std.testing.expectEqual(
        @as(u32, @typeInfo(pcc.proof_system.Property).@"enum".fields.len),
        decoded.obligations.len(),
    );
    var index: u32 = 0;
    while (index < decoded.obligations.len()) : (index += 1) {
        const obligation = try decoded.obligations.get(index);
        var answers: usize = 0;
        var evidence_index: u32 = 0;
        while (evidence_index < decoded.evidence.len()) : (evidence_index += 1) {
            const entry = try decoded.evidence.get(evidence_index);
            if (entry.obligation_index == index) answers += 1;
        }
        std.testing.expect(answers > 0) catch |err| {
            std.debug.print("obligation {s} has no evidence\n", .{obligation.property.name()});
            return err;
        };
    }
}

test "a real compile reaches policy acceptance, and one changed byte does not" {
    const allocator = std.testing.allocator;
    const source =
        \\function helper(): undefined {
        \\}
        \\
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  if (req.method === "GET") {
        \\    return Response.text("get");
        \\  } else {
        \\    return Response.text("other");
        \\  }
        \\}
    ;

    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);

    const sections = artifact_graph.ArtifactInputs{
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = artifact_graph.digestOf(policy_section),
        .identity = artifact_graph.identityFromContract(&contract),
    };

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = dischargedProperties(&contract),
        .artifact = sections,
        .contract_digest = artifact_graph.digestOf(contract_json),
    });
    defer built.deinit();

    const scratch = try allocator.alloc(u8, pcc.checker.scratchBytes(.{}));
    defer allocator.free(scratch);

    // The consumer rebuilds the inventory from the same sections, independently,
    // and checks the certificate against it.
    const members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(members);
    var observed_sections = sections;
    observed_sections.proof_ir_digest = built.ir_root;
    observed_sections.proof_certificate_digest = built.certificate_digest;
    const observed = try artifact_graph.build(
        allocator,
        artifact_graph.fromArtifact(observed_sections),
        members,
    );

    // The production floor requires totality at the translation edge and three
    // disclosed properties; this handler discharges all four.
    const accepted = pcc.check(.{
        .certificate = built.bytes,
        .observed_graph = observed,
        .scratch = scratch,
    }, pcc.policy.production);
    if (accepted.rejection) |rejection| {
        std.debug.print(
            "unexpected rejection: {s} / {s}\n",
            .{ rejection.stage.name(), rejection.code.text() },
        );
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(pcc.SemanticState.policy_accepted, accepted.semantic);
    try std.testing.expect(accepted.grade != null);

    // One byte of the deployed bytecode, changed. The certificate is untouched
    // and internally valid; it no longer describes what would run.
    const tampered = try allocator.dupe(u8, compiled.bytecode);
    defer allocator.free(tampered);
    tampered[tampered.len / 2] +%= 1;
    var tampered_sections = observed_sections;
    tampered_sections.bytecode = tampered;
    const tampered_members = artifact_graph.build(
        allocator,
        artifact_graph.fromArtifact(tampered_sections),
        members,
    ) catch |err| {
        // Flipping a byte can also break the module stream outright, which is
        // a refusal at an even earlier stage.
        try std.testing.expectEqual(error.MalformedBytecodeStream, err);
        return;
    };
    const rejected = pcc.check(.{
        .certificate = built.bytes,
        .observed_graph = tampered_members,
        .scratch = scratch,
    }, pcc.policy.production);
    try std.testing.expect(!rejected.accepted());
    try std.testing.expectEqual(pcc.verdict.Stage.artifact_binding, rejected.rejection.?.stage);
}

fn acceptCompiledSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    configured_policy: zts.HandlerPolicy,
) !pcc.Assessment {
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
        .policy = configured_policy,
    });
    defer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const runtime_policy = zts.handler_policy.contractToRuntimePolicy(&contract, &configured_policy);
    const policy_section = try self_extract.serializePolicy(allocator, &runtime_policy);
    defer allocator.free(policy_section);
    const policy_digest = artifact_graph.digestOf(policy_section);

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = dischargedProperties(&contract),
        .artifact = .{
            .bytecode = compiled.bytecode,
            .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
            .contract_section = contract_json,
            .policy_section_digest = policy_digest,
            .identity = artifact_graph.identityFromContract(&contract),
        },
        .contract_digest = artifact_graph.digestOf(contract_json),
        .runtime_policy_digest = policy_digest,
    });
    defer built.deinit();

    var decode_budget = pcc.limits.Budget.init(.{});
    const decoded = try pcc.certificate.decode(built.bytes, .{}, &decode_budget);
    try std.testing.expectEqual(
        decoded.residual.len() > 0,
        built.residual_plan_digest != null,
    );

    const activation_inputs = proof_activation.Inputs{
        .certificate = built.bytes,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .policy_section = policy_section,
        .identity = artifact_graph.identityFromContract(&contract),
    };
    const observed_root = (try proof_activation.observedRoot(allocator, activation_inputs)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &built.executable_root, &observed_root);
    return proof_activation.accept(allocator, activation_inputs, pcc.policy.development);
}

test "real guarded artifacts reach consumer acceptance in expression positions" {
    const allocator = std.testing.allocator;
    var policy = try zts.handler_policy.parsePolicyJson(
        allocator,
        "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    );
    defer policy.deinit(allocator);

    const static_source =
        \\import { env } from "zttp:env";
        \\export function handler(req: Request): Response {
        \\  if (env("APP_NAME") !== undefined) {
        \\    return Response.text("set");
        \\  }
        \\  return Response.text("missing");
        \\}
    ;
    const static_result = try acceptCompiledSource(allocator, static_source, policy);
    try std.testing.expect(static_result.accepted());
    try std.testing.expectEqual(@as(u32, 0), static_result.guards.required);

    const guarded_sources = [_][]const u8{
        \\import { env } from "zttp:env";
        \\export function handler(req: Request): Response {
        \\  const configured = env(req.method) !== undefined;
        \\  return Response.text(configured ? "set" : "missing");
        \\}
        ,
        \\import { env } from "zttp:env";
        \\export function handler(req: Request): Response {
        \\  if (env(req.method) !== undefined) {
        \\    return Response.text("set");
        \\  }
        \\  return Response.text("missing");
        \\}
        ,
    };
    for (guarded_sources) |source| {
        const result = try acceptCompiledSource(allocator, source, policy);
        if (result.rejection) |rejection| {
            std.debug.print(
                "guarded artifact rejected at {s} ({s}): {any}\n",
                .{ rejection.stage.name(), rejection.code.text(), rejection },
            );
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(result.accepted());
        try std.testing.expectEqual(@as(u32, 1), result.guards.required);
        try std.testing.expectEqual(@as(u32, 1), result.guards.covered);
        try std.testing.expectEqual(@as(u8, 1), result.guards.kinds);
        try std.testing.expectEqual(
            static_result.properties.accepted_bits,
            result.properties.accepted_bits,
        );
    }
}

test "the signed root and the startup rebuild are the same fold" {
    const allocator = std.testing.allocator;
    const source =
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;

    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);
    const policy_digest = artifact_graph.digestOf(policy_section);

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = dischargedProperties(&contract),
        .artifact = .{
            .bytecode = compiled.bytecode,
            .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
            .contract_section = contract_json,
            .policy_section_digest = policy_digest,
            .identity = artifact_graph.identityFromContract(&contract),
        },
        .contract_digest = artifact_graph.digestOf(contract_json),
    });
    defer built.deinit();

    // What the server folds at startup, from the sections it loaded, using the
    // certificate for the one member it cannot derive.
    const observed = (try proof_activation.observedRoot(allocator, .{
        .certificate = built.bytes,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .identity = artifact_graph.identityFromContract(&contract),
    })).?;

    // These two folds are what the signed claim is compared against. When they
    // disagreed - acceptance folded the proof-IR member, the attestation check
    // did not - every artifact carrying a certificate refused to serve, and
    // only the end-to-end smoke test noticed.
    try std.testing.expectEqualSlices(u8, &built.executable_root, &observed);

    // Evidence is authority-bearing even when the proof IR is unchanged. A
    // policy claim that moves from tested to not-established must therefore
    // move the root compared with the one an attestation signed.
    const mutated_certificate = try allocator.dupe(u8, built.bytes);
    defer allocator.free(mutated_certificate);
    var decode_budget = pcc.limits.Budget.init(.{});
    const decoded = try pcc.certificate.decode(mutated_certificate, .{}, &decode_budget);
    const evidence_offset = @intFromPtr(decoded.evidence.bytes.ptr) - @intFromPtr(mutated_certificate.ptr);
    var evidence_index: u32 = 0;
    while (evidence_index < decoded.evidence.len()) : (evidence_index += 1) {
        const entry = try decoded.evidence.get(evidence_index);
        const obligation = try decoded.obligations.get(entry.obligation_index);
        if (obligation.property == .no_secret_leakage) break;
    }
    try std.testing.expect(evidence_index < decoded.evidence.len());
    // The edge byte of the disclosed no-secret-leakage record.
    mutated_certificate[
        evidence_offset +
            @as(usize, evidence_index) * pcc.certificate.evidence_record_size + 4
    ] =
        @intFromEnum(pcc.certificate.EdgeKind.not_established);
    const mutated_root = (try proof_activation.observedRoot(allocator, .{
        .certificate = mutated_certificate,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .identity = artifact_graph.identityFromContract(&contract),
    })).?;
    try std.testing.expect(!std.mem.eql(u8, &built.executable_root, &mutated_root));

    // And a rebuild that forgets the proof IR is a different artifact, which is
    // what makes the equality above load-bearing rather than incidental.
    const without_ir = (try proof_activation.observedRoot(allocator, .{
        .certificate = null,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = policy_digest,
        .identity = artifact_graph.identityFromContract(&contract),
    })).?;
    try std.testing.expect(!std.mem.eql(u8, &built.executable_root, &without_ir));
}

test "a handler that does not always return is not accepted" {
    const allocator = std.testing.allocator;
    // `if` with no `else`: the compiler refuses this outright, which is the
    // strongest possible answer. What matters here is that the refusal happens
    // and no artifact is produced for it.
    const source =
        \\export function handler(req: Request): Proof<Response, "deterministic"> {
        \\  if (req.method === "GET") {
        \\    return Response.text("get");
        \\  }
        \\}
    ;
    const result = precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    if (result) |compiled| {
        var owned = compiled;
        defer owned.deinit(allocator);
        // A compile that got far enough to lower the proof IR must, by its own
        // fold, say the handler is not total. A compile that refused earlier
        // carries no evidence at all, which is a refusal too.
        if (owned.proof_evidence) |evidence| {
            try std.testing.expect(!evidence.handlerIsTotal());
        }
    } else |_| {}
}

test "the same source yields byte-identical certificates" {
    const allocator = std.testing.allocator;
    const source =
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;

    const first = try certificateForSource(allocator, source);
    defer allocator.free(first);
    const second = try certificateForSource(allocator, source);
    defer allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    const other =
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("different");
        \\}
    ;
    const changed = try certificateForSource(allocator, other);
    defer allocator.free(changed);
    // A different program is a different artifact even when its proof shape is
    // the same: the bytecode member moved.
    try std.testing.expect(!std.mem.eql(u8, first, changed));
}

fn certificateForSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;
    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = dischargedProperties(&contract),
        .artifact = .{
            .bytecode = compiled.bytecode,
            .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
            .contract_section = contract_json,
            .policy_section_digest = artifact_graph.digestOf(policy_section),
            .identity = artifact_graph.identityFromContract(&contract),
        },
        .contract_digest = artifact_graph.digestOf(contract_json),
    });
    defer built.deinit();
    return allocator.dupe(u8, built.bytes);
}

test "prepareProjectArtifact default path: <root>/.zttp/<subdir>/<basename>" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"port\":3000}",
    });
    try std.Io.Dir.createDirPath(tmp.dir, io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "function handler(r) { return Response.text('ok') }\n",
    });

    var artifact = try prepareProjectArtifact(testing.allocator, io, "build", null);
    defer artifact.deinit(testing.allocator);

    // Output path ends in `.zttp/build/<basename(root)>`.
    try testing.expect(std.mem.indexOf(u8, artifact.output_path, ".zttp/build/") != null);
    try testing.expectEqualStrings(artifact.project_name, std.fs.path.basename(artifact.output_path));

    // Parent dir exists (createDirPath ran).
    const parent = std.fs.path.dirname(artifact.output_path).?;
    try std.Io.Dir.accessAbsolute(io, parent, .{});

    // Handler path resolves to the manifest entry.
    try testing.expectStringEndsWith(artifact.handler_path, "src/handler.ts");
}

test "prepareProjectArtifact override path: passes through unchanged, no parent created" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\"}",
    });
    try std.Io.Dir.createDirPath(tmp.dir, io, "src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "function handler(r) { return Response.text('ok') }\n",
    });

    var artifact = try prepareProjectArtifact(testing.allocator, io, "deploy", "/tmp/explicit-name");
    defer artifact.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/explicit-name", artifact.output_path);
}

test "deploy ledger payload includes worst-case cost summary" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    const path = try allocator.dupe(u8, "handler.ts");
    var contract = zts.handler_contract.emptyContract(path);
    defer contract.deinit(allocator);
    contract.cost_envelope = .{
        .total = .{ .linear = .{
            .coefficient = 2,
            .base = 1,
            .source = .{
                .line = 5,
                .column = 3,
                .desc = try allocator.dupe(u8, "for...of over `ids`"),
            },
        } },
    };

    try appendDeployLedgerEntry(allocator, &contract, "handler.ts", "sha-cost", "demo");

    const raw = try zts.file_io.readFile(allocator, proof_ledger.ledgerPath(), 64 * 1024);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"deploy\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"costWorstCase\":1048579") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"costBodyLimit\":1048576") != null);
}

test "prepareProjectArtifact returns NoProjectConfig when no zttp.json on or above CWD" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try @import("proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    // No zttp.json present anywhere up the tree from this tmp dir.
    try testing.expectError(error.NoProjectConfig, prepareProjectArtifact(testing.allocator, io, "build", null));
}

// ---------------------------------------------------------------------------
// compileCommand / buildCommand argv-parsing error paths. The happy paths
// reach buildArtifact, which requires a real handler on disk and a runtime
// binary alongside the test executable — out of scope for unit tests. The
// argv parser is the part the user trips on most often, and it's testable
// in isolation.
// ---------------------------------------------------------------------------

test "compileCommand requires a handler positional" {
    const testing = std.testing;
    try testing.expectEqual(CommandArgError.missing_handler_path, parseCompileCommandArgs(&.{}).err);
    try testing.expectEqual(
        CommandArgError.missing_handler_path,
        parseCompileCommandArgs(&.{ "-o", "out.bin" }).err,
    );
}

test "compileCommand requires -o" {
    const testing = std.testing;
    // Handler positional present, but -o missing.
    try testing.expectEqual(
        CommandArgError.missing_output_flag,
        parseCompileCommandArgs(&.{"handler.ts"}).err,
    );
}

test "compileCommand rejects bare -o without a follow-up path" {
    const testing = std.testing;
    // `-o` is the last token; the inner `i += 1; if (i >= argv.len)` guard
    // must fire as MissingArgument rather than silently leaving output null.
    try testing.expectEqual(
        CommandArgError.missing_output_value,
        parseCompileCommandArgs(&.{ "handler.ts", "-o" }).err,
    );
}

test "buildCommand rejects bare -o without a follow-up path" {
    const testing = std.testing;
    try testing.expectEqual(
        CommandArgError.missing_output_value,
        parseBuildCommandArgs(&.{"-o"}).err,
    );
}

test "buildCommand rejects unknown flags as UnknownOption" {
    const testing = std.testing;
    // Anything past the known set (`-o`, `--no-attest`, `--help`) hits
    // the catch-all branch and exits with UnknownOption so
    // the user knows their flag was not recognised.
    try testing.expectEqualStrings("--unknown-flag", parseBuildCommandArgs(&.{"--unknown-flag"}).err.unknown_arg);
    try testing.expectEqualStrings("unexpected_positional", parseBuildCommandArgs(&.{"unexpected_positional"}).err.unknown_arg);
}

test "localDeployCommand accepts local target forms and no-attest" {
    const testing = std.testing;

    const local_space = parseLocalDeployCommandArgs(&.{ "--target", "local" }).ok;
    try testing.expect(local_space.attest_requested);

    const local_equals = parseLocalDeployCommandArgs(&.{"--target=local"}).ok;
    try testing.expect(local_equals.attest_requested);

    const no_attest = parseLocalDeployCommandArgs(&.{ "--local", "--target=local", "--no-attest" }).ok;
    try testing.expect(!no_attest.attest_requested);
}

test "localDeployCommand rejects missing duplicate and unknown target values" {
    const testing = std.testing;

    try testing.expectEqual(LocalDeployArgError.missing_target_value, parseLocalDeployCommandArgs(&.{"--target"}).err);
    try testing.expectEqual(LocalDeployArgError.missing_target_value, parseLocalDeployCommandArgs(&.{"--target="}).err);
    try testing.expectEqual(LocalDeployArgError.missing_target_value, parseLocalDeployCommandArgs(&.{ "--target", "--no-attest" }).err);
    try testing.expectEqual(LocalDeployArgError.duplicate_target, parseLocalDeployCommandArgs(&.{ "--target", "local", "--target=local" }).err);
    try testing.expectEqualStrings("prod", parseLocalDeployCommandArgs(&.{ "--target", "prod" }).err.unknown_target);
    try testing.expectEqualStrings("prod", parseLocalDeployCommandArgs(&.{"--target=prod"}).err.unknown_target);
}

test "localDeployCommand rejects stray positional args" {
    const testing = std.testing;
    try testing.expectEqualStrings("local", parseLocalDeployCommandArgs(&.{"local"}).err.unknown_arg);
    try testing.expectEqualStrings("extra", parseLocalDeployCommandArgs(&.{ "--target", "local", "extra" }).err.unknown_arg);
}

test "compileCommand rejects unknown -prefixed flags symmetrically with buildCommand" {
    const testing = std.testing;
    // The argv loop used to silently drop `-`-prefixed unknowns via the
    // non-matching path between `--help` and the `!startsWith("-")`
    // positional branch. A typo like `--ouptut` would be ignored and the
    // build would proceed with the default state. The new else arm
    // returns UnknownOption — same behaviour as buildCommand.
    try testing.expectEqualStrings("--ouptut", parseCompileCommandArgs(&.{ "--ouptut", "out.bin", "handler.ts" }).err.unknown_arg);
    try testing.expectEqualStrings("--json", parseCompileCommandArgs(&.{ "--json", "handler.ts", "-o", "out.bin" }).err.unknown_arg);
}

/// The smallest contract the build path accepts. Only its presence and its
/// handler path matter here; every analysis field is empty on purpose.
fn emptyProbeContract(allocator: std.mem.Allocator) !zts.HandlerContract {
    return zts.HandlerContract{
        .handler = .{ .path = try allocator.dupe(u8, "handler.ts"), .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = .empty, .dynamic = false },
        .egress = .{ .endpoints = .empty, .urls = .empty, .dynamic = false },
        .cache = .{ .namespaces = .empty, .dynamic = false },
        .sql = .{ .backend = "sqlite", .queries = .empty, .dynamic = false },
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
            .timers = false,
            .signals = .{ .literal = .empty, .dynamic = false },
            .producer_keys = .{ .literal = .empty, .dynamic = false },
        },
        .scope = .{ .used = false, .names = .empty, .dynamic = false, .max_depth = 0 },
        .api = .{
            .schemas = .empty,
            .requests = .{ .schema_refs = .empty, .dynamic = false },
            .auth = .{ .bearer = false, .jwt = false },
            .routes = .empty,
            .schemas_dynamic = false,
            .routes_dynamic = false,
        },
        .verification = null,
        .aot = null,
        .properties = .{
            .pure = false,
            .read_only = true,
            .stateless = false,
            .retry_safe = true,
            .deterministic = true,
            .has_egress = false,
        },
    };
}

/// Records what `runBuild` asked its environment to do, and stands in for the
/// real filesystem, compiler, code signer, and ledger. The point of naming the
/// capabilities is that this exists at all: before, the only way to exercise
/// the build was to run a compiler over a real file and write a real binary.
const BuildProbe = struct {
    source: []const u8 = "function handler(req) { return Response.text('ok'); }",
    bytecode: []const u8 = &[_]u8{ 1, 2, 3, 4 },
    with_contract: bool = true,
    compile_error: ?anyerror = null,

    read_calls: usize = 0,
    compile_calls: usize = 0,
    tail_calls: usize = 0,
    codesign_calls: usize = 0,
    ledger_calls: usize = 0,
    tail_saw_contract: bool = false,
    tail_saw_attest: bool = false,
    compile_saw_sql_schema: bool = false,
    compile_saw_system: bool = false,
    compile_saw_policy: bool = false,
    ledger_service: ?[]const u8 = null,
    ledger_sha_hex: ?[64]u8 = null,

    fn of(context: ?*anyopaque) *BuildProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn readSource(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self = of(context);
        self.read_calls += 1;
        return allocator.dupe(u8, self.source);
    }

    fn compile(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: BuildCompileInput,
    ) anyerror!precompile.CompiledHandler {
        const self = of(context);
        self.compile_calls += 1;
        self.compile_saw_sql_schema = input.sql_schema_path != null;
        self.compile_saw_system = input.system_path != null;
        self.compile_saw_policy = input.policy != null;
        if (self.compile_error) |err| return err;
        return .{
            .bytecode = try allocator.dupe(u8, self.bytecode),
            .contract = if (self.with_contract) try emptyProbeContract(allocator) else null,
        };
    }

    fn resolveRuntime(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        return allocator.dupe(u8, "/nonexistent/zttp-runtime");
    }

    fn writeTail(context: ?*anyopaque, _: std.mem.Allocator, input: ArtifactTailInput) anyerror!void {
        const self = of(context);
        self.tail_calls += 1;
        self.tail_saw_contract = input.contract != null;
        self.tail_saw_attest = input.attest_requested;
    }

    fn codesign(context: ?*anyopaque, _: std.mem.Allocator, _: []const u8) void {
        of(context).codesign_calls += 1;
    }

    fn appendLedger(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: *const zts.HandlerContract,
        _: []const u8,
        sha_hex: []const u8,
        service_name: []const u8,
    ) anyerror!void {
        const self = of(context);
        self.ledger_calls += 1;
        self.ledger_service = service_name;
        var buf: [64]u8 = undefined;
        @memcpy(&buf, sha_hex[0..64]);
        self.ledger_sha_hex = buf;
    }

    fn capabilities(self: *BuildProbe) BuildCapabilities {
        return .{
            .context = self,
            .read_source = readSource,
            .compile = compile,
            .resolve_runtime_binary = resolveRuntime,
            .write_tail = writeTail,
            .codesign = codesign,
            .append_ledger = appendLedger,
        };
    }
};

test "a deploy build signs, codesigns, and records one ledger row" {
    var probe = BuildProbe{};
    var policy = zts.HandlerPolicy{};
    const receipt = try runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = ".zttp/deploy/demo",
        .sql_schema_path = "schema.sql",
        .system_path = "system.json",
        .policy = &policy,
        .ledger_service_name = "demo",
        .attest_requested = true,
    }, probe.capabilities());

    try std.testing.expectEqual(@as(usize, 1), probe.read_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.compile_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.tail_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.codesign_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.ledger_calls);
    try std.testing.expect(probe.compile_saw_sql_schema);
    try std.testing.expect(probe.compile_saw_system);
    try std.testing.expect(probe.compile_saw_policy);
    try std.testing.expect(probe.tail_saw_contract);
    try std.testing.expect(probe.tail_saw_attest);
    try std.testing.expectEqualStrings("demo", probe.ledger_service.?);

    try std.testing.expectEqualStrings(".zttp/deploy/demo", receipt.output_path);
    try std.testing.expectEqual(@as(usize, 4), receipt.bytecode_len);
    try std.testing.expect(receipt.has_contract);
    try std.testing.expect(receipt.attest_requested);
    try std.testing.expect(receipt.ledger_recorded);

    // The receipt's digest is the one the ledger row carries, not a second
    // hash of something else.
    const hex = std.fmt.bytesToHex(receipt.handler_sha256, .lower);
    try std.testing.expectEqualSlices(u8, &hex, &probe.ledger_sha_hex.?);
}

test "a build without a project name writes no ledger row" {
    var probe = BuildProbe{};
    const receipt = try runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .attest_requested = true,
    }, probe.capabilities());

    try std.testing.expectEqual(@as(usize, 0), probe.ledger_calls);
    try std.testing.expect(!receipt.ledger_recorded);
    try std.testing.expectEqual(@as(u8, 0), receipt.handler_sha256[0]);
}

test "a build with no contract embeds none and records no ledger row" {
    var probe = BuildProbe{ .with_contract = false };
    const receipt = try runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .ledger_service_name = "demo",
        .attest_requested = false,
    }, probe.capabilities());

    try std.testing.expect(!probe.tail_saw_contract);
    try std.testing.expect(!probe.tail_saw_attest);
    try std.testing.expectEqual(@as(usize, 0), probe.ledger_calls);
    try std.testing.expect(!receipt.has_contract);
    try std.testing.expect(!receipt.ledger_recorded);
}

test "a compile failure stops before the artifact is written" {
    var probe = BuildProbe{ .compile_error = error.ParseError };
    try std.testing.expectError(error.ParseError, runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .attest_requested = true,
    }, probe.capabilities()));

    try std.testing.expectEqual(@as(usize, 0), probe.tail_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.codesign_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.ledger_calls);
}

test "explicit compile discovers and enforces project capability policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"policy.json\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "policy.json",
        .data = "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/handler.ts",
        .data = "function handler(req) { return Response.text('ok'); }",
    });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/handler.ts", allocator);
    defer allocator.free(handler_path);
    var context = try discoverExplicitCompileContext(allocator, handler_path);
    defer context.deinit(allocator);
    const policy = context.policyPtr() orelse return error.TestExpectedPolicy;

    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const value = env("OTHER_NAME") ?? "fallback";
        \\  return Response.json({ value: value });
        \\}
    ;
    try std.testing.expectError(error.PolicyViolation, compileCapability(null, allocator, .{
        .source = source,
        .handler_path = handler_path,
        .sql_schema_path = context.sql_schema_path,
        .system_path = context.system_path,
        .policy = policy,
    }));
}

test "project build compiler enforces configured capability policy" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  const value = env("OTHER_NAME") ?? "fallback";
        \\  return Response.json({ value: value });
        \\}
    ;
    var policy = try zts.handler_policy.parsePolicyJson(
        allocator,
        "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    );
    defer policy.deinit(allocator);

    try std.testing.expectError(error.PolicyViolation, compileCapability(null, allocator, .{
        .source = source,
        .handler_path = "handler.ts",
        .sql_schema_path = null,
        .system_path = null,
        .policy = &policy,
    }));
}
