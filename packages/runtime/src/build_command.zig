//! `zttp build` and the artifact pipeline that `zttp compile` and
//! `zttp deploy --local` share (prepareProjectArtifact + buildArtifact).
//! compile_command.zig and deploy_command.zig hold the other two commands.
//! Dispatch and error-to-exit-code translation stay in dev_cli.main; the help
//! printers are internal because only these commands invoke them.

const std = @import("std");
const writeAllFd = @import("posix_util.zig").writeAllFd;
const builtin = @import("builtin");

const zts = @import("zts");
const zts_cli = @import("zts_cli");
const precompile = zts_cli.precompile;
const deploy_manifest = zts_cli.deploy_manifest;
const shared = @import("cli_shared.zig");
const artifact_graph = @import("artifact_graph.zig");
const contract_runtime = @import("contract_runtime.zig");
const pcc = @import("zttp_proof_checker");
const proof_activation = @import("proof_activation.zig");
const proof_certificate = @import("proof_certificate.zig");
const self_extract = @import("self_extract.zig");
const attest_build_receipt = @import("attest/build_receipt.zig");
const live_reload = @import("live_reload.zig");
const proof_ledger = @import("proof_ledger.zig");
const project_config_mod = @import("project_config");
const retired_authority = project_config_mod.retired_authority;
const cli_paths = @import("cli_paths.zig");
const cli_doctor = @import("cli_doctor.zig");
const resolveRuntimeBinary = cli_paths.resolveRuntimeBinary;
const compile_command = @import("compile_command.zig");
const deploy_command = @import("deploy_command.zig");
const parseCompileCommandArgs = compile_command.parseCompileCommandArgs;
const discoverExplicitCompileContext = compile_command.discoverExplicitCompileContext;
const LocalDeployArgError = deploy_command.LocalDeployArgError;
const parseLocalDeployCommandArgs = deploy_command.parseLocalDeployCommandArgs;

pub const no_attest_flag: []const u8 = "--no-attest";

/// Shared help text describing `--no-attest`. Three command help printers
/// all advertise the same flag; one source of truth prevents drift.
pub const no_attest_help_block: []const u8 =
    \\  --no-attest           Skip proof-receipt signing for this build.
    \\                        Default is to sign with the persistent
    \\                        identity at ~/.zttp/attest/keypair.bin.
    \\
;

const BuildCommandOptions = struct {
    output_override: ?[]const u8,
    attest_requested: bool,
};

pub const CommandArgError = union(enum) {
    missing_output_value,
    missing_handler_path,
    missing_output_flag,
    unknown_arg: []const u8,
};

const BuildCommandParse = union(enum) {
    help,
    ok: BuildCommandOptions,
    err: CommandArgError,
};

pub const ProjectCompileContext = struct {
    sql_schema_path: ?[]u8 = null,
    policy: ?zts.HandlerPolicy = null,
    /// The policy text, kept so the build check reads the policy that `zttp check` reads.
    policy_source: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        project: *const project_config_mod.ProjectConfig,
    ) !ProjectCompileContext {
        var context: ProjectCompileContext = .{};
        errdefer context.deinit(allocator);

        context.sql_schema_path = try project.resolvedSqlitePath(allocator);
        const policy_source = project.readPolicySource(allocator) catch |err| {
            std.debug.print(
                "Configured capability policy '{s}' could not be loaded: {s}\n",
                .{ project.policy orelse "", @errorName(err) },
            );
            return error.PolicyContextFailed;
        };
        context.policy_source = policy_source;
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

    pub fn deinit(self: *ProjectCompileContext, allocator: std.mem.Allocator) void {
        if (self.sql_schema_path) |path| allocator.free(path);
        if (self.policy) |*policy| policy.deinit(allocator);
        if (self.policy_source) |source| allocator.free(source);
        self.* = .{};
    }

    pub fn policyPtr(self: *const ProjectCompileContext) ?*const zts.HandlerPolicy {
        return if (self.policy) |*policy| policy else null;
    }
};

pub const ProjectArtifact = struct {
    project: project_config_mod.ProjectConfig,
    compile_context: ProjectCompileContext,
    handler_path: []u8,
    output_path: []u8,
    project_name: []const u8,

    pub fn deinit(self: *ProjectArtifact, allocator: std.mem.Allocator) void {
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
pub fn prepareProjectArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    subdir: []const u8,
    output_override: ?[]const u8,
) !ProjectArtifact {
    var project_opt = try project_config_mod.discover(allocator, io, null);
    errdefer if (project_opt) |*p| p.deinit(allocator);
    var project = project_opt orelse return error.NoProjectConfig;
    project_opt = null;
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
            try printBuildHelp();
            return error.UnknownOption;
        },
        .missing_handler_path,
        .missing_output_flag,
        => unreachable,
    }
}

pub fn projectRunCommand(allocator: std.mem.Allocator, artifact: *const ProjectArtifact) ![]u8 {
    return allocator.dupe(u8, artifact.output_path);
}

pub fn buildCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = switch (parseBuildCommandArgs(argv)) {
        .help => {
            try printBuildHelp();
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
        .policy = artifact.compile_context.policyPtr(),
        .policy_source = artifact.compile_context.policy_source,
        .attest_requested = opts.attest_requested,
    });

    const run_command = try projectRunCommand(allocator, &artifact);
    defer allocator.free(run_command);
    std.debug.print(
        \\
        \\Built: {s}
        \\Run:   {s}
        \\
    , .{ artifact.output_path, run_command });
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

/// The sections the artifact tail is about to embed, exactly as written.
const ArtifactAcceptanceInput = struct {
    certificate: ?[]const u8,
    bytecode: []const u8,
    dep_bytecodes: []const []const u8,
    contract_json: ?[]const u8,
    policy_section: []const u8,
    policy_section_digest: [32]u8,
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
    /// Production acceptance of the artifact about to be written: the same
    /// consumer check the served binary runs at startup. It returns
    /// `error.ProofAcceptanceFailed` after naming the refusal, so a build
    /// never writes a binary that would refuse to serve.
    accept_artifact: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: ArtifactAcceptanceInput,
    ) anyerror!void,
    create_artifact: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        runtime_binary: []const u8,
        output_path: []const u8,
        payload: self_extract.PayloadInput,
    ) anyerror!void,
};

fn retiredArtifactFeature(input: ArtifactTailInput) ?retired_authority.Feature {
    var facts: retired_authority.Facts = .{};
    if (input.contract) |contract| facts = retired_authority.contractFacts(contract);
    return retired_authority.first(facts);
}

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

/// Run the consumer acceptance the served binary runs at startup
/// (`server_activation.acceptEmbeddedCertificate`) over the sections about to be written.
/// A build that passes here produces a binary that production acceptance
/// accepts; a build that fails here would have produced one that refuses to
/// serve. Provenance is `.absent`: production policy requires none, and this
/// build has not verified any signature.
fn acceptArtifactCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: ArtifactAcceptanceInput,
) !void {
    const contract_json = input.contract_json orelse {
        reportBuildRefusal("the artifact carries no contract, so nothing can be checked");
        return error.ProofAcceptanceFailed;
    };
    const raw = contract_runtime.parseContractJson(allocator, contract_json) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            reportBuildRefusal("the serialized contract does not parse");
            return error.ProofAcceptanceFailed;
        },
    };
    var validated = contract_runtime.validate(raw, .{ .bytecode = input.bytecode }) catch {
        // `validate` has no allocating path, so every error is a refusal.
        reportBuildRefusal("the serialized contract fails validation");
        return error.ProofAcceptanceFailed;
    };
    defer validated.deinit();

    const identity = artifact_graph.identityFromRuntimeContract(validated.view());

    const assessment = try proof_activation.accept(allocator, .{
        .certificate = input.certificate,
        .bytecode = input.bytecode,
        .dep_bytecodes = input.dep_bytecodes,
        .contract_section = contract_json,
        .policy_section_digest = input.policy_section_digest,
        .policy_section = input.policy_section,
        .identity = identity,
        .provenance = .absent,
    }, pcc.policy.production);

    if (contract_runtime.promote(&validated, assessment, input.policy_section_digest) == null) {
        if (!builtin.is_test) {
            if (assessment.rejection()) |rejection| {
                std.debug.print(
                    "Build refused: production acceptance failed at {s} ({s}); the artifact would refuse to serve.\n",
                    .{ rejection.stage.name(), rejection.code.text() },
                );
            } else {
                std.debug.print("Build refused: production acceptance did not complete; the artifact would refuse to serve.\n", .{});
            }
        }
        return error.ProofAcceptanceFailed;
    }
}

fn reportBuildRefusal(reason: []const u8) void {
    if (builtin.is_test) return;
    std.debug.print("Build refused: {s}; the artifact would refuse to serve.\n", .{reason});
}

const production_artifact_tail_capabilities = ArtifactTailCapabilities{
    .context = null,
    .serialize_contract = serializeContractCapability,
    .sign_contract = signContractCapability,
    .accept_artifact = acceptArtifactCapability,
    .create_artifact = createArtifactCapability,
};

fn writeArtifactTail(
    allocator: std.mem.Allocator,
    input: ArtifactTailInput,
    capabilities: ArtifactTailCapabilities,
) !void {
    if (retiredArtifactFeature(input)) |feature| {
        if (!builtin.is_test) std.debug.print("Build refused retired runtime authority: {s}\n", .{feature.sentence()});
        return error.UnsupportedRuntimeAuthority;
    }
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
                @as([32]u8, @splat(0)),
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

    // Refuse before writing: the served binary runs this same acceptance at
    // startup, and a deploy that reports success for a binary that will not
    // start is worse than a refused build. No file is created on refusal.
    try capabilities.accept_artifact(capabilities.context, allocator, .{
        .certificate = if (certificate) |value| value.bytes else null,
        .bytecode = input.bytecode,
        .dep_bytecodes = input.dep_bytecodes,
        .contract_json = contract_json,
        .policy_section = policy_section,
        .policy_section_digest = runtime_policy_digest,
    });

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
        .capability_bounded = handler_contract.capability_budget.len > 0,
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
    policy: ?*const zts.HandlerPolicy = null,
    policy_source: ?[]const u8 = null,
    /// Service name to record in the proof ledger entry. Null when the
    /// build is not part of a named project (`compile`/`build` paths);
    /// set to the project name on the `deploy --local` path.
    ledger_service_name: ?[]const u8 = null,
    /// Whether the caller asked for an embedded attestation JWS.
    attest_requested: bool,
};

/// What the build did. A caller, and a test, learns from it whether a receipt
/// was signed or a ledger row written, without reading stderr.
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
    handler_sha256: [std.crypto.hash.sha2.Sha256.digest_length]u8 = @as([std.crypto.hash.sha2.Sha256.digest_length]u8, @splat(0)),
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
    /// Runs the same analysis as `zttp check` and returns its count of spec
    /// errors, so that a build refuses what `zttp check` and `zttp test` refuse.
    check: *const fn (?*anyopaque, std.mem.Allocator, BuildCompileInput) anyerror!u32 = checkCapability,
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
    policy: ?*const zts.HandlerPolicy,
    policy_source: ?[]const u8 = null,
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
        .policy = if (input.policy) |policy| policy.* else null,
    });
}

/// The acceptance rule comes from the check path alone.
fn checkCapability(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: BuildCompileInput,
) anyerror!u32 {
    var check = try precompile.runCheckOnlyFromSourceWithOptions(allocator, input.source, input.handler_path, .{
        .sql_schema_path = input.sql_schema_path,
        .policy_source = input.policy_source,
        // Quiet: the compile above already printed its diagnostics; the spec
        // sections are printed once below.
        .json_mode = true,
    });
    defer check.deinit(allocator);
    const spec_errors = check.specErrors();
    if (spec_errors > 0 and !builtin.is_test) {
        cli_doctor.printCheckStageFailures(&check, "  ");
        cli_doctor.printCheckFailureSections(allocator, &check, input.handler_path);
    }
    return spec_errors;
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
    if (builtin.target.os.tag == .macos) codesignAdHoc(allocator, path);
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

pub fn buildArtifact(allocator: std.mem.Allocator, request: BuildRequest) !void {
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
        std.log.err("Failed to read handler '{s}': {s}", .{ handler_path, precompile.readFailureReason(err) });
        // Printed above; a distinct error lets the command exit 1 without a
        // stack trace and without hiding an unprinted FileNotFound elsewhere.
        return error.HandlerReadFailed;
    };
    defer allocator.free(source);

    const compile_input: BuildCompileInput = .{
        .source = source,
        .handler_path = handler_path,
        .sql_schema_path = request.sql_schema_path,
        .policy = request.policy,
        .policy_source = request.policy_source,
    };

    std.log.info("Compiling {s}...", .{handler_path});
    shared.step("Compiling handler...");

    var compiled = caps.compile(caps.context, allocator, compile_input) catch |err| {
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

    // After the compile, so that a parse or type error prints once. The compile
    // path derives its own contract and never gates on spec diagnostics.
    const spec_errors = try caps.check(caps.context, allocator, compile_input);
    if (spec_errors > 0) {
        std.debug.print(
            \\
            \\Aborted: {s} has {d} spec error(s) that `zttp check` also reports. No binary was written.
            \\Fix the errors above, or declare a narrow Proof capsule with only the properties the handler holds.
            \\
        , .{ handler_path, spec_errors });
        return error.ProofAcceptanceFailed;
    }

    const retired_input: ArtifactTailInput = .{
        .runtime_binary = "",
        .output_path = output_path,
        .attest_requested = attest_requested,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = if (compiled.contract) |*contract| contract else null,
        .proof_evidence = if (compiled.proof_evidence) |*evidence| evidence else null,
        .configured_policy = request.policy,
    };
    const retired_feature = retiredArtifactFeature(retired_input);
    if (retired_feature) |feature| {
        if (!builtin.is_test) std.debug.print("Build refused retired runtime authority: {s}\n", .{feature.sentence()});
        return error.UnsupportedRuntimeAuthority;
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
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return;
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

fn printBuildHelp() !void {
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
    try writeAllFd(std.c.STDOUT_FILENO, help);
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
            .accept_artifact = acceptArtifactPassThrough,
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
        try std.testing.expect(!std.mem.eql(u8, &digest, &@as([32]u8, @splat(0))));
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
        @as(u32, @typeInfo(pcc.proof_system.Property).@"enum".field_names.len),
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

test "a build certificate claims capability_bounded only under a declared Effects ceiling" {
    const allocator = std.testing.allocator;
    const plain =
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("ok");
        \\}
    ;
    const bounded =
        \\import { sha256 } from "zttp:crypto";
        \\export function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text(sha256("zttp"));
        \\}
    ;

    var plain_compiled = try precompile.compileHandler(allocator, plain, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
    });
    defer plain_compiled.deinit(allocator);
    const plain_contract = plain_compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(!dischargedProperties(&plain_contract).capability_bounded);

    var bounded_compiled = try precompile.compileHandler(allocator, bounded, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
    });
    defer bounded_compiled.deinit(allocator);
    const bounded_contract = bounded_compiled.contract orelse return error.TestUnexpectedResult;
    try std.testing.expect(dischargedProperties(&bounded_contract).capability_bounded);
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
    if (accepted.rejection()) |rejection| {
        std.debug.print(
            "unexpected rejection: {s} / {s}\n",
            .{ rejection.stage.name(), rejection.code.text() },
        );
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(pcc.SemanticState.policy_accepted, accepted.semantic());
    try std.testing.expect(accepted.grade() != null);

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
    try std.testing.expectEqual(pcc.verdict.Stage.artifact_binding, rejected.rejection().?.stage);
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
        if (result.rejection()) |rejection| {
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
        inline for (@typeInfo(pcc.proof_system.Property).@"enum".field_names) |field| {
            const property: pcc.proof_system.Property = @fromBackingInt(@intCast(@backingInt(@field(pcc.proof_system.Property, field))));
            try std.testing.expectEqual(
                static_result.properties.accepted(property),
                result.properties.accepted(property),
            );
        }
    }
}

test "proofs verify accepts a bundled guarded artifact by handing acceptance its policy section" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var policy = try zts.handler_policy.parsePolicyJson(
        allocator,
        "{\"env\":{\"allow\":[\"APP_NAME\"]}}",
    );
    defer policy.deinit(allocator);

    // A computed env key: the compiler cannot enumerate it, so the artifact
    // carries a guard that only the runtime policy section can discharge.
    const source =
        \\import { env } from "zttp:env";
        \\export function handler(req: Request): Response {
        \\  if (env(req.method) !== undefined) {
        \\    return Response.text("set");
        \\  }
        \\  return Response.text("missing");
        \\}
    ;
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
        .policy = policy,
    });
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    try zts.file_io.writeFile(allocator, "runtime", "runtime-template");
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "handler.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
        .configured_policy = &policy,
    }, production_artifact_tail_capabilities);

    // The fixture is sound before it is bundled: production acceptance, handed
    // the policy bytes, accepts it and counts one covered guard. Without this
    // the verify assertions below could pass or fail for another reason.
    {
        const path_z = try allocator.dupeSentinel(u8, "handler.bin", 0);
        defer allocator.free(path_z);
        var loaded = blk: {
            var payload = (try self_extract.detectPath(allocator, path_z)) orelse return error.TestUnexpectedResult;
            errdefer payload.deinit(allocator);
            const raw = try contract_runtime.parseContractJson(allocator, payload.contract_json orelse return error.TestUnexpectedResult);
            const validated = try contract_runtime.validate(raw, .{ .bytecode = payload.bytecode });
            break :blk LoadedArtifact{ .payload = payload, .contract = validated, .allocator = allocator };
        };
        defer loaded.deinit();
        try std.testing.expect(loaded.payload.policy_section != null);
        const assessment = try proof_activation.accept(allocator, loaded.activationInputs(), pcc.policy.production);
        try std.testing.expect(assessment.accepted());
        try std.testing.expectEqual(@as(u32, 1), assessment.guards.required);
        try std.testing.expectEqual(@as(u32, 1), assessment.guards.covered);
    }

    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    try zts.file_io.writeFile(allocator, "handler.contract.json", contract_json);

    var write_out = std.Io.Writer.Allocating.init(allocator);
    defer write_out.deinit();
    var write_err = std.Io.Writer.Allocating.init(allocator);
    defer write_err.deinit();
    try proofs_bundle.writeBundle(allocator, .{
        .contract_path = "handler.contract.json",
        .binary_path = "handler.bin",
        .out_dir = "bundle",
    }, &write_out.writer, &write_err.writer);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(allocator);
    defer err.deinit();
    proofs_bundle.verify(allocator, "bundle", true, &out.writer, &err.writer) catch |e| {
        std.debug.print("verify failed with {s}:\n{s}\n", .{ @errorName(e), out.writer.buffered() });
        return e;
    };
    const text = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "REJECTED") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Guards:    1 of 1 covered (env_key)") != null);
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
        @backingInt(pcc.certificate.EdgeKind.not_established);
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

// ---------------------------------------------------------------------------
// Artifact round-trip through the producer and consumer
// ---------------------------------------------------------------------------

const proofs_bundle = @import("proofs/bundle.zig");

/// Test probes that deliberately write artifacts the server must refuse, and
/// that read the written payload back, skip production acceptance.
fn acceptArtifactPassThrough(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: ArtifactAcceptanceInput,
) !void {}

/// Captures the payload the artifact tail would write, serialized exactly as
/// `self_extract.create` serializes it, so a test reads it back the way a
/// deployed binary does.
const PayloadCapture = struct {
    allocator: std.mem.Allocator,
    serialized: ?[]u8 = null,

    fn deinit(self: *PayloadCapture) void {
        if (self.serialized) |bytes| self.allocator.free(bytes);
    }

    fn capture(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        payload: self_extract.PayloadInput,
    ) !void {
        const self: *PayloadCapture = @ptrCast(@alignCast(context.?));
        if (self.serialized) |old| self.allocator.free(old);
        self.serialized = null;
        self.serialized = try self_extract.serializePayload(self.allocator, payload);
    }

    fn capabilities(self: *PayloadCapture) ArtifactTailCapabilities {
        return .{
            .context = self,
            .serialize_contract = serializeContractCapability,
            .sign_contract = signContractCapability,
            .accept_artifact = acceptArtifactPassThrough,
            .create_artifact = capture,
        };
    }
};

/// A deployed artifact as the serving binary holds it: the parsed payload and
/// the contract validated from its own section 3.
const LoadedArtifact = struct {
    payload: self_extract.Payload,
    contract: contract_runtime.ValidatedRuntimeContract,
    allocator: std.mem.Allocator,

    fn deinit(self: *LoadedArtifact) void {
        self.contract.deinit();
        self.payload.deinit(self.allocator);
    }

    /// The same activation inputs `server_activation.acceptEmbeddedCertificate` builds.
    fn activationInputs(self: *const LoadedArtifact) proof_activation.Inputs {
        const view = self.contract.view();
        return .{
            .certificate = self.payload.certificate,
            .bytecode = self.payload.bytecode,
            .dep_bytecodes = self.payload.dep_bytecodes,
            .contract_section = self.payload.contract_json,
            .policy_section_digest = self.payload.policy_section_sha256,
            .policy_section = self.payload.policy_section,
            .identity = .{
                .module_specifiers = view.modules,
                .core_profile_id = view.source_identity.core_profile.id(),
                .core_grammar_hash = view.source_identity.core_grammar_hash,
                .semantics_hash = view.source_identity.semantics_hash,
                .capability_hash = if (view.capabilities) |caps| caps.hash else @as([32]u8, @splat(0)),
            },
        };
    }
};

/// Compile `source`, run the production artifact tail over it, and load the
/// payload it would have written.
fn loadArtifactForSource(allocator: std.mem.Allocator, source: []const u8) !LoadedArtifact {
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    var capture = PayloadCapture{ .allocator = allocator };
    defer capture.deinit();
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
    }, capture.capabilities());

    var payload = (try self_extract.parse(allocator, capture.serialized orelse return error.TestUnexpectedResult)) orelse
        return error.TestUnexpectedResult;
    errdefer payload.deinit(allocator);
    const raw = try contract_runtime.parseContractJson(allocator, payload.contract_json orelse return error.TestUnexpectedResult);
    const validated = try contract_runtime.validate(raw, .{ .bytecode = payload.bytecode });
    return .{ .payload = payload, .contract = validated, .allocator = allocator };
}

fn expectRefusedAt(assessment: pcc.Assessment, stage: pcc.verdict.Stage, code: pcc.ReasonCode) !void {
    const rejection = assessment.rejection() orelse return error.TestUnexpectedResult;
    std.testing.expectEqual(code, rejection.code) catch |err| {
        std.debug.print("refused with {s} at {s}\n", .{ rejection.code.text(), rejection.stage.name() });
        return err;
    };
    try std.testing.expectEqual(stage, rejection.stage);
}

test "folded handler expressions retain production proof acceptance" {
    const allocator = std.testing.allocator;
    var artifact = try loadArtifactForSource(allocator,
        \\function isGet(req: Request): boolean { return req.method === "GET"; }
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  const folded = (1.5 + 2.5) / 2;
        \\  const truth = !(5 < 2);
        \\  const side = true || isGet(req);
        \\  return Response.json({ value: folded, truth: truth, side: side });
        \\}
    );
    defer artifact.deinit();
    const assessment = try proof_activation.accept(allocator, artifact.activationInputs(), pcc.policy.production);
    try std.testing.expect(assessment.accepted());
}

test "a changed runtime policy member is refused at artifact binding (B8.8)" {
    const allocator = std.testing.allocator;
    var artifact = try loadArtifactForSource(allocator,
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("ok");
        \\}
    );
    defer artifact.deinit();
    const policy_section = artifact.payload.policy_section orelse return error.TestUnexpectedResult;

    // A consistent change: new bytes and their own digest, so the only thing
    // that disagrees is the `runtime_policy_bytes` member the certificate names.
    const changed = try allocator.dupe(u8, policy_section);
    defer allocator.free(changed);
    changed[changed.len - 1] +%= 1;
    var changed_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(changed, &changed_digest, .{});

    var inputs = artifact.activationInputs();
    inputs.policy_section = changed;
    inputs.policy_section_digest = changed_digest;
    const assessment = try proof_activation.accept(allocator, inputs, pcc.policy.production);
    try expectRefusedAt(assessment, .artifact_binding, .graph_member_digest_mismatch);
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
    // A `-`-prefixed unknown such as the typo `--ouptut` returns UnknownOption,
    // the same as buildCommand.
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
    retired_module: ?[]const u8 = null,
    compile_error: ?anyerror = null,

    read_calls: usize = 0,
    compile_calls: usize = 0,
    check_calls: usize = 0,
    spec_errors: u32 = 0,
    resolve_calls: usize = 0,
    tail_calls: usize = 0,
    codesign_calls: usize = 0,
    ledger_calls: usize = 0,
    tail_saw_contract: bool = false,
    tail_saw_attest: bool = false,
    compile_saw_sql_schema: bool = false,
    compile_saw_policy: bool = false,
    check_policy_source: ?[]const u8 = null,
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

    fn check(context: ?*anyopaque, _: std.mem.Allocator, input: BuildCompileInput) anyerror!u32 {
        const self = of(context);
        self.check_calls += 1;
        self.check_policy_source = input.policy_source;
        return self.spec_errors;
    }

    fn compile(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: BuildCompileInput,
    ) anyerror!precompile.CompiledHandler {
        const self = of(context);
        self.compile_calls += 1;
        self.compile_saw_sql_schema = input.sql_schema_path != null;
        self.compile_saw_policy = input.policy != null;
        if (self.compile_error) |err| return err;
        const bytecode = try allocator.dupe(u8, self.bytecode);
        errdefer allocator.free(bytecode);
        // A retired module needs a contract to carry it.
        var contract: ?zts.HandlerContract = if (self.with_contract or self.retired_module != null)
            try emptyProbeContract(allocator)
        else
            null;
        errdefer if (contract) |*built| built.deinit(allocator);
        if (self.retired_module) |module| {
            const owned_module = try allocator.dupe(u8, module);
            errdefer allocator.free(owned_module);
            try contract.?.modules.append(allocator, owned_module);
        }
        return .{
            .bytecode = bytecode,
            .contract = contract,
        };
    }

    fn resolveRuntime(context: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        of(context).resolve_calls += 1;
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
            .check = check,
            .resolve_runtime_binary = resolveRuntime,
            .write_tail = writeTail,
            .codesign = codesign,
            .append_ledger = appendLedger,
        };
    }
};

test "every retired module refuses a build before replacing artifact output" {
    const allocator = std.testing.allocator;
    const retired = [_][]const u8{
        "zttp:durable",
        "zttp:workflow",
        "zttp:queue",
        "zttp:scope",
        "zttp:io",
        "zttp:service",
        "zttp:ledger",
        "zttp:tool",
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(output_path);
    const artifact_path = try std.fs.path.join(allocator, &.{ output_path, "artifact.bin" });
    defer allocator.free(artifact_path);

    for (retired) |module| {
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "artifact.bin",
            .data = "sentinel",
        });
        var probe = BuildProbe{ .retired_module = module };
        try std.testing.expectError(error.UnsupportedRuntimeAuthority, runBuild(allocator, .{
            .handler_path = "handler.ts",
            .output_path = artifact_path,
            .attest_requested = true,
        }, probe.capabilities()));

        try std.testing.expectEqual(@as(usize, 1), probe.compile_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.resolve_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.tail_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.codesign_calls);
        try std.testing.expectEqual(@as(usize, 0), probe.ledger_calls);
        const output = try zts.file_io.readFile(allocator, artifact_path, 64);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("sentinel", output);
    }
}

test "a deploy build signs, codesigns, and records one ledger row" {
    var probe = BuildProbe{};
    var policy = zts.HandlerPolicy{};
    const receipt = try runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = ".zttp/deploy/demo",
        .sql_schema_path = "schema.sql",
        .policy = &policy,
        .policy_source = "{}",
        .ledger_service_name = "demo",
        .attest_requested = true,
    }, probe.capabilities());
    // The build check reads the same policy text as `zttp check`.
    try std.testing.expectEqualStrings("{}", probe.check_policy_source.?);

    try std.testing.expectEqual(@as(usize, 1), probe.read_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.compile_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.tail_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.codesign_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.ledger_calls);
    try std.testing.expect(probe.compile_saw_sql_schema);
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

test "a spec error from the check stops the build before the artifact is written" {
    var probe = BuildProbe{ .spec_errors = 1 };
    try std.testing.expectError(error.ProofAcceptanceFailed, runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .attest_requested = true,
    }, probe.capabilities()));

    try std.testing.expectEqual(@as(usize, 1), probe.check_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.resolve_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.tail_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.codesign_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.ledger_calls);
}

test "a build refuses a handler that breaks its own declared capsule" {
    var probe = BuildProbe{
        .source =
        \\function handler(req: Request): Proof<Response, "deterministic"> {
        \\  return Response.json({ now: Date.now() });
        \\}
        ,
    };
    var caps = probe.capabilities();
    caps.check = checkCapability;
    try std.testing.expectError(error.ProofAcceptanceFailed, runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .attest_requested = true,
    }, caps));

    try std.testing.expectEqual(@as(usize, 1), probe.compile_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.tail_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.resolve_calls);
}

test "a build accepts the handler with no I/O and no capsule" {
    var probe = BuildProbe{
        .source =
        \\function handler(req: Request): Response {
        \\  if (req.path === "/health") {
        \\    return Response.json({ ok: true });
        \\  }
        \\  return Response.text("Not Found", { status: 404 });
        \\}
        ,
    };
    var caps = probe.capabilities();
    caps.check = checkCapability;
    _ = try runBuild(std.testing.allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .attest_requested = true,
    }, caps);

    try std.testing.expectEqual(@as(usize, 1), probe.compile_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.tail_calls);
}

const app_name_source =
    \\import { env } from "zttp:env";
    \\
    \\function handler(req: Request): Proof<Response, "no_secret_leakage"> {
    \\  return Response.json({ app: env("APP_NAME") ?? "zttp" });
    \\}
;

/// Build `app_name_source` as a project would, with the real compile and the
/// real check, and the policy text that the project hands both of them.
fn buildAppNameHandler(policy_text: []const u8) !usize {
    const allocator = std.testing.allocator;
    var policy = try zts.handler_policy.parsePolicyJson(allocator, policy_text);
    defer policy.deinit(allocator);
    var probe = BuildProbe{ .source = app_name_source };
    var caps = probe.capabilities();
    caps.compile = compileCapability;
    caps.check = checkCapability;
    _ = try runBuild(allocator, .{
        .handler_path = "handler.ts",
        .output_path = "out",
        .policy = &policy,
        .policy_source = policy_text,
        .attest_requested = false,
    }, caps);
    return probe.tail_calls;
}

test "a build accepts a returned env value that the project policy lists in env.public" {
    const tail_calls = try buildAppNameHandler("{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}");
    try std.testing.expectEqual(@as(usize, 1), tail_calls);
}

test "a build refuses the same handler when the project policy does not list the name in env.public" {
    try std.testing.expectError(
        error.ProofAcceptanceFailed,
        buildAppNameHandler("{\"env\":{\"allow\":[\"APP_NAME\"]}}"),
    );
}

test "two policies that differ only in env.public serialize the same runtime policy" {
    const allocator = std.testing.allocator;
    var compiled_source = try precompile.compileHandler(allocator, app_name_source, "handler.ts", .{ .emit_contract = true });
    defer compiled_source.deinit(allocator);
    const contract = compiled_source.contract orelse return error.TestUnexpectedResult;

    var with_public = try zts.handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"APP_NAME\"],\"public\":[\"APP_NAME\"]}}");
    defer with_public.deinit(allocator);
    var without_public = try zts.handler_policy.parsePolicyJson(allocator, "{\"env\":{\"allow\":[\"APP_NAME\"]}}");
    defer without_public.deinit(allocator);

    const first = zts.handler_policy.contractToRuntimePolicy(&contract, &with_public);
    const second = zts.handler_policy.contractToRuntimePolicy(&contract, &without_public);
    const first_bytes = try self_extract.serializePolicy(allocator, &first);
    defer allocator.free(first_bytes);
    const second_bytes = try self_extract.serializePolicy(allocator, &second);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
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
    try std.testing.expectEqualStrings("{\"env\":{\"allow\":[\"APP_NAME\"]}}", context.policy_source.?);

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
        .policy = &policy,
    }));
}

test "direct source contracts preserve certificate bytes and proof IR" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only"> {
        \\  return Response.text("ok");
        \\}
        ,
        \\export function handler(req: Request): Proof< Response , "deterministic" | "read_only" > {
        \\  if (req.method === "GET") { return Response.text("get"); }
        \\  else { return Response.text("other"); }
        \\}
        ,
    };
    try std.testing.expectEqual(@as(usize, 2), fixtures.len);
    const expected_certificates = [_]struct { len: usize, sha256: []const u8, proof_nodes: usize }{
        .{ .len = 1349, .sha256 = "d0e1f43a66a5697ce9221b224c36f31daaa7840e47f6dfb5bc7cbeb79441eb47", .proof_nodes = 5 },
        .{ .len = 1729, .sha256 = "55aa6a1c532ddde121e8b1799ce680555e71bf6618fa5a82dd7aa4779efbb66a", .proof_nodes = 9 },
    };
    for (fixtures, expected_certificates) |source, expected| {
        var direct: zts.DirectCheckSource = undefined;
        try direct.initCompileInPlace(allocator, allocator, source, "handler.ts");
        defer direct.deinit();
        const accepted = direct.acceptedCapabilities() orelse return error.TestUnexpectedResult;
        const direct_root = accepted.root;
        const direct_view = accepted.ir_view;
        const direct_handler = zts.findHandlerFunction(direct_view, direct_root) orelse
            return error.TestUnexpectedResult;
        var direct_proof = try zts.lowerProofIr(allocator, direct_view, direct_root, direct_handler, null);
        defer direct_proof.deinit();
        try std.testing.expectEqual(expected.proof_nodes, direct_proof.nodes.len);
        var direct_analysis: zts.pipeline.ModuleAnalysisSession = .{};
        try direct_analysis.initFull(allocator, .fromTypedExisting(
            direct_view,
            direct_root,
            accepted.atoms,
            accepted.type_store,
        ), .{ .source_types = .direct });
        defer direct_analysis.deinit();
        try direct_analysis.complete();
        var direct_contract = try direct_analysis.extractContract("handler.ts");
        defer direct_contract.deinit(allocator);
        const direct_json = try serializeContractJson(allocator, &direct_contract);
        defer allocator.free(direct_json);
        try std.testing.expectEqual(@as(usize, 2242), direct_json.len);
        var contract_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(direct_json, &contract_digest, .{});
        const contract_hex = std.fmt.bytesToHex(contract_digest, .lower);
        try std.testing.expectEqualStrings("60c5416f75d7730c4af2cab4c4ee7873d2a8ddb974d2911759e84c6fe3d7902d", &contract_hex);

        // Contract parity is independent of compiler and certificate encoding.
        // Both certificate builds receive the same completed compilation.
        var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
            .emit_proof_evidence = true,
        });
        defer compiled.deinit(allocator);
        const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualDeep(direct_proof.nodes, evidence.proof.nodes);
        try std.testing.expectEqual(direct_proof.handler_function, evidence.proof.handler_function);
        const direct_policy = zts.handler_policy.contractToRuntimePolicy(&direct_contract, null);
        const direct_policy_bytes = try self_extract.serializePolicy(allocator, &direct_policy);
        defer allocator.free(direct_policy_bytes);
        const inputs = proof_certificate.Inputs{
            .evidence = &evidence,
            .properties = dischargedProperties(&direct_contract),
            .artifact = .{
                .bytecode = compiled.bytecode,
                .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
                .contract_section = direct_json,
                .policy_section_digest = artifact_graph.digestOf(direct_policy_bytes),
                .identity = artifact_graph.identityFromContract(&direct_contract),
            },
            .contract_digest = artifact_graph.digestOf(direct_json),
            .runtime_policy_digest = artifact_graph.digestOf(direct_policy_bytes),
            .development = false,
        };
        var direct_certificate = try proof_certificate.build(allocator, inputs);
        defer direct_certificate.deinit();
        try std.testing.expectEqual(expected.len, direct_certificate.bytes.len);
        var certificate_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(direct_certificate.bytes, &certificate_digest, .{});
        const certificate_hex = std.fmt.bytesToHex(certificate_digest, .lower);
        try std.testing.expectEqualStrings(expected.sha256, &certificate_hex);
        try std.testing.checkAllAllocationFailures(allocator, buildDirectCertificateForAllocationTest, .{inputs});
    }
}

fn buildDirectCertificateForAllocationTest(
    allocator: std.mem.Allocator,
    inputs: proof_certificate.Inputs,
) !void {
    var built = try proof_certificate.build(allocator, inputs);
    defer built.deinit();
    try std.testing.expect(built.bytes.len > 0);
}

// ---------------------------------------------------------------------------
// The build refuses what production acceptance refuses
// ---------------------------------------------------------------------------

/// The production artifact tail with only artifact creation replaced, so a test
/// runs the real acceptance and sees whether the build reached creation.
const ProductionAcceptanceProbe = struct {
    create_calls: usize = 0,

    fn recordCreation(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: self_extract.PayloadInput,
    ) !void {
        const self: *ProductionAcceptanceProbe = @ptrCast(@alignCast(context.?));
        self.create_calls += 1;
    }

    fn capabilities(self: *ProductionAcceptanceProbe) ArtifactTailCapabilities {
        var caps = production_artifact_tail_capabilities;
        caps.context = self;
        caps.create_artifact = recordCreation;
        return caps;
    }
};

/// A secret env value in the response body: the compile succeeds and emits a
/// certificate, and production acceptance refuses it at the policy stage
/// (`required_property_not_established`), as `zttp deploy` did in the field.
const refused_by_production_source =
    \\import { env } from "zttp:env";
    \\function handler(req: Request): Response {
    \\  const v = env("SECRET_KEY");
    \\  return Response.text(v === undefined ? "none" : v);
    \\}
;

const accepted_by_production_source =
    \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
    \\  return Response.text("ok");
    \\}
;

fn compileForProductionTail(allocator: std.mem.Allocator, source: []const u8) !precompile.CompiledHandler {
    return precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
}

test "a handler that production acceptance refuses never reaches artifact creation" {
    const allocator = std.testing.allocator;
    var compiled = try compileForProductionTail(allocator, refused_by_production_source);
    defer compiled.deinit(allocator);
    // The fixture reaches acceptance with everything a build normally has.
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    var probe = ProductionAcceptanceProbe{};
    try std.testing.expectError(error.ProofAcceptanceFailed, writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
    }, probe.capabilities()));
    try std.testing.expectEqual(@as(usize, 0), probe.create_calls);
}

test "a handler that production acceptance accepts reaches artifact creation once" {
    const allocator = std.testing.allocator;
    var compiled = try compileForProductionTail(allocator, accepted_by_production_source);
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    var probe = ProductionAcceptanceProbe{};
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
    }, probe.capabilities());
    try std.testing.expectEqual(@as(usize, 1), probe.create_calls);
}

test "production acceptance in the build refuses a missing certificate and a missing contract" {
    const allocator = std.testing.allocator;
    var compiled = try compileForProductionTail(allocator, accepted_by_production_source);
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    var no_certificate = ProductionAcceptanceProbe{};
    try std.testing.expectError(error.ProofAcceptanceFailed, writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = null,
    }, no_certificate.capabilities()));
    try std.testing.expectEqual(@as(usize, 0), no_certificate.create_calls);

    var no_contract = ProductionAcceptanceProbe{};
    try std.testing.expectError(error.ProofAcceptanceFailed, writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = null,
        .proof_evidence = &evidence,
    }, no_contract.capabilities()));
    try std.testing.expectEqual(@as(usize, 0), no_contract.create_calls);
}

test "a refused build leaves an existing output file unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try zts.file_io.writeFile(allocator, "runtime", "runtime-template");
    try zts.file_io.writeFile(allocator, "artifact.bin", "previous build");

    var compiled = try compileForProductionTail(allocator, refused_by_production_source);
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    // The real creation capability: only a refusal before it keeps the file.
    try std.testing.expectError(error.ProofAcceptanceFailed, writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "artifact.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
    }, production_artifact_tail_capabilities));

    const existing = try zts.file_io.readFile(allocator, "artifact.bin", 64);
    defer allocator.free(existing);
    try std.testing.expectEqualStrings("previous build", existing);
}

/// Build a real bundle (handler artifact with a certificate) in the current
/// directory under `bundle/`.
fn writeCertifiedBundleFixture(allocator: std.mem.Allocator) !void {
    try writeCertifiedBundleFixtureFor(allocator,
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "state_isolated" | "no_secret_leakage" | "result_safe"> {
        \\  return Response.text("ok");
        \\}
    );
}

fn writeCertifiedBundleFixtureFor(allocator: std.mem.Allocator, source: []const u8) !void {
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);
    const evidence = compiled.proof_evidence orelse return error.TestUnexpectedResult;
    const contract = compiled.contract orelse return error.TestUnexpectedResult;

    try zts.file_io.writeFile(allocator, "runtime", "runtime-template");
    try writeArtifactTail(allocator, .{
        .runtime_binary = "runtime",
        .output_path = "handler.bin",
        .attest_requested = false,
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract = &contract,
        .proof_evidence = &evidence,
        .configured_policy = null,
    }, production_artifact_tail_capabilities);

    const contract_json = try serializeContractJson(allocator, &contract);
    defer allocator.free(contract_json);
    try zts.file_io.writeFile(allocator, "handler.contract.json", contract_json);

    var write_out = std.Io.Writer.Allocating.init(allocator);
    defer write_out.deinit();
    var write_err = std.Io.Writer.Allocating.init(allocator);
    defer write_err.deinit();
    try proofs_bundle.writeBundle(allocator, .{
        .contract_path = "handler.contract.json",
        .binary_path = "handler.bin",
        .out_dir = "bundle",
    }, &write_out.writer, &write_err.writer);
}

/// Replace one bundle file and rewrite its digest in the manifest, so the
/// integrity check passes and only the payload comparison can notice.
fn replaceBundleComponent(allocator: std.mem.Allocator, file: []const u8, new_bytes: []const u8) !void {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "bundle/{s}", .{file});
    const old_bytes = try zts.file_io.readFile(allocator, path, 256 * 1024 * 1024);
    defer allocator.free(old_bytes);
    const old_hex = std.fmt.bytesToHex(sha256Digest(old_bytes), .lower);
    const new_hex = std.fmt.bytesToHex(sha256Digest(new_bytes), .lower);
    const manifest = try zts.file_io.readFile(allocator, "bundle/bundle.json", 1024 * 1024);
    defer allocator.free(manifest);
    const rewritten = try std.mem.replaceOwned(u8, allocator, manifest, &old_hex, &new_hex);
    defer allocator.free(rewritten);
    try zts.file_io.writeFile(allocator, path, new_bytes);
    try zts.file_io.writeFile(allocator, "bundle/bundle.json", rewritten);
}

fn sha256Digest(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

test "proofs verify refuses a bundle whose certificate file is not the certificate in the binary" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeCertifiedBundleFixture(allocator);
    try replaceBundleComponent(allocator, "certificate", "garbage");

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(allocator);
    defer err.deinit();
    try std.testing.expectError(
        error.BundleComponentMismatch,
        proofs_bundle.verify(allocator, "bundle", false, &out.writer, &err.writer),
    );
    try std.testing.expectEqualStrings(
        "zttp proofs verify: bundle certificate does not match the certificate in the binary\n",
        err.writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "Proof:     REJECTED - bundle certificate does not match the binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "policy_accepted") == null);
}

test "proofs verify refuses a bundle whose contract file is not the contract in the binary" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeCertifiedBundleFixture(allocator);
    try replaceBundleComponent(allocator, "handler.contract.json", "{\"version\":18}");

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(allocator);
    defer err.deinit();
    try std.testing.expectError(
        error.BundleComponentMismatch,
        proofs_bundle.verify(allocator, "bundle", false, &out.writer, &err.writer),
    );
    try std.testing.expectEqualStrings(
        "zttp proofs verify: bundle contract does not match the contract in the binary\n",
        err.writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "Proof:     REJECTED - bundle contract does not match the binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "policy_accepted") == null);
}

test "proofs verify names the properties the kernel re-derived for a guarded Result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeCertifiedBundleFixtureFor(allocator,
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("todo", "{\"type\":\"object\",\"required\":[\"title\"]}");
        \\export function handler(req: Request): Proof<Response, "deterministic" | "read_only" | "result_safe"> {
        \\  const r = validateJson("todo", "{}");
        \\  if (!r.ok) {
        \\    return Response.json({ error: r.errors }, { status: 400 });
        \\  }
        \\  return Response.json({ title: r.value }, { status: 200 });
        \\}
    );

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(allocator);
    defer err.deinit();
    try proofs_bundle.verify(allocator, "bundle", false, &out.writer, &err.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\nChecked:   response_total, results_checked\n") != null);
}

test "proofs verify reports a handler without a Result as re-deriving results_checked too, with no Result read to check" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try proof_ledger.chdirTmpForTest(&tmp);
    defer allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeCertifiedBundleFixture(allocator);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(allocator);
    defer err.deinit();
    try proofs_bundle.verify(allocator, "bundle", false, &out.writer, &err.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\nChecked:   response_total, results_checked\n") != null);
}
