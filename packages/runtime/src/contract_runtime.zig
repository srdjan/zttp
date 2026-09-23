//! Runtime contract: lightweight parser for the embedded contract JSON.
//!
//! The compile-time contract extraction (handler_contract.zig) proves handler
//! properties, env vars, routes, and egress hosts. That contract is embedded in
//! self-extracting binaries but was previously unused at runtime ("v1 emission
//! only"). This module makes the runtime contract-aware: startup env validation,
//! route pre-filtering, and property-driven behavior.

const std = @import("std");
const zq = @import("zts");
const pcc = @import("zttp_proof_checker");
const runtime_config = @import("runtime_config.zig");
const project_config = @import("project_config");
const HandlerContract = zq.HandlerContract;
const HandlerProperties = zq.HandlerProperties;
const CostEnvelope = zq.handler_contract.CostEnvelope;
const ModuleCapability = zq.module_binding.ModuleCapability;
const capability_count = zq.module_binding.capability_count;
const cost_meter = zq.CostMeter;

pub const CapabilityMatrix = zq.handler_contract.CapabilityMatrix;
pub const CostCeilings = runtime_config.CostCeilings;
pub const DurableWorkflowProperties = runtime_config.DurableWorkflowProperties;

/// Proven handler properties extracted from the contract.
/// Each field is a mathematical proof, not an annotation.
pub const Properties = struct {
    pure: bool = false,
    read_only: bool = false,
    stateless: bool = false,
    retry_safe: bool = false,
    deterministic: bool = false,
    has_egress: bool = false,
    no_secret_leakage: bool = false,
    no_credential_leakage: bool = false,
    input_validated: bool = false,
    pii_contained: bool = false,
    injection_safe: bool = false,
    idempotent: bool = false,
    state_isolated: bool = false,
    max_io_depth: ?u32 = null,
    fault_covered: bool = false,
    result_safe: bool = false,
    optional_safe: bool = false,
};

/// A proven API route (method + path pattern).
pub const Route = struct {
    method: []const u8,
    path: []const u8,
};

/// What the contract says about one tool, lowered for the startup cross-check
/// against the accepted catalog. The contract is producer output; the accepted
/// catalog is what the runtime serves, and a difference refuses to start.
pub const ToolSummary = struct {
    name: []const u8,
    /// Uppercase ASCII, split from the route key at its first space.
    method: []const u8,
    path: []const u8,
    max_input_bytes: u32,
};

/// One tool from the accepted `ZTCAT1` catalog, with both schemas compiled.
/// The string fields borrow from `AcceptedCatalog.bytes`.
pub const AcceptedTool = struct {
    name: []const u8,
    method: []const u8,
    path: []const u8,
    max_input_bytes: u32,
    input: zq.tool_schema.CompiledToolSchema,
    output: zq.tool_schema.CompiledToolSchema,
};

/// The tool catalog lowered from the section bytes that passed acceptance,
/// never from producer output. Owns a copy of those bytes and every compiled
/// schema.
pub const AcceptedCatalog = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    entries: []AcceptedTool,

    pub fn deinit(self: *AcceptedCatalog) void {
        for (self.entries) |*entry| {
            entry.input.deinit();
            entry.output.deinit();
        }
        self.allocator.free(self.entries);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn find(self: *const AcceptedCatalog, name: []const u8) ?*const AcceptedTool {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// The tool served on this request, matched the way `routerMatch` matches a
    /// route key: the method without regard to case, and the path with `:param`
    /// segments as wildcards.
    pub fn match(self: *const AcceptedCatalog, method: []const u8, path: []const u8) ?*const AcceptedTool {
        for (self.entries) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.method, method) and matchPath(entry.path, path)) return entry;
        }
        return null;
    }
};

/// Why a promotion that the kernel accepted still refuses to start.
/// The verdict of a tool body check: `ok`, or a refusal reason and byte offset.
pub const ToolVerdict = zq.tool_schema.ValidateResult;

/// One producer tool entry, as the contract carries it.
pub const ToolEntry = zq.handler_contract.ToolEntry;

/// The largest 2xx tool response body the runtime validates. A larger one is a
/// refusal, not a pass: an output the check never read is not an output it
/// admitted.
pub const max_tool_output_bytes: u32 = zq.tool_schema.max_input_bytes_ceiling;

/// Check a request body against the tool's input schema and byte bound, before
/// any JS value exists. `scratch` is the request arena.
pub fn validateToolInput(scratch: std.mem.Allocator, tool: *const AcceptedTool, body: []const u8) std.mem.Allocator.Error!ToolVerdict {
    return zq.tool_schema.validate(scratch, &tool.input, body, tool.max_input_bytes);
}

/// Check a 2xx response body against the tool's output schema (B8.4).
pub fn validateToolOutput(scratch: std.mem.Allocator, tool: *const AcceptedTool, body: []const u8) std.mem.Allocator.Error!ToolVerdict {
    return zq.tool_schema.validate(scratch, &tool.output, body, max_tool_output_bytes);
}

pub const PromoteError = std.mem.Allocator.Error || error{
    /// The accepted section bytes do not decode. Acceptance already decoded
    /// them, so this is an invariant violation, and it refuses rather than
    /// serves without a catalog.
    AcceptedToolCatalogUndecodable,
    /// A schema in the accepted catalog does not compile under the closed
    /// subset. The kernel does not re-check the subset, so this is where an
    /// out-of-subset schema stops.
    ToolSchemaNotCompilable,
    /// The contract's tool list and the accepted catalog disagree on the set
    /// of names, or on a method, path, or byte bound.
    ToolCatalogContractMismatch,
    /// The contract lists tools and no catalog section was accepted.
    ToolCatalogMissing,
};

/// How aggressively the runtime pool may reuse a warmed handler runtime.
pub const PoolingPolicy = enum {
    ephemeral, // one runtime per request
    reuse_bounded_by_count, // recycle after N requests
    reuse_bounded_by_ttl, // recycle after wall-clock TTL
    reuse_unbounded, // pure + deterministic + state-isolated only
};

pub const PoolingThresholds = struct {
    max_requests: u32 = 64,
    ttl_ns: u64 = 30 * std.time.ns_per_s,
    /// `reuse_unbounded` runtimes are otherwise never recycled by count/TTL,
    /// so their Context's AtomTable can grow toward the hard 0xFFFE (65,534)
    /// interned-atom cap (see context.zig's `intern`) over a long process
    /// lifetime. 32,768 is half that cap: real headroom for legitimately
    /// shape-diverse handlers (varied JSON payloads, dynamic property keys)
    /// while still forcing a recycle well before the fail-closed OOM guard
    /// would turn into a standing per-slot outage.
    max_dynamic_atoms: u32 = 32_768,
};

/// Map proven contract properties to a lifecycle policy. Null falls back to
/// `.reuse_bounded_by_count`.
///
/// The argument is a proof-checked contract, not a validated one. Recycling a
/// runtime without resetting it is a decision about whether the handler leaves
/// state behind, and the compiler's word for that is a claim until a consumer
/// checks it. An artifact with no accepted certificate lands on the
/// conservative policy, which is what null means here.
pub fn derivePoolingPolicy(contract: ?*const ProofCheckedContract) PoolingPolicy {
    const rc = contract orelse return .reuse_bounded_by_count;
    const p = rc.properties;
    if (p.pure and p.deterministic and p.state_isolated) return .reuse_unbounded;
    if (p.read_only and p.state_isolated) return .reuse_bounded_by_ttl;
    return .reuse_bounded_by_count;
}

// ---------------------------------------------------------------------------
// Proof-checked promotion.
//
// `ValidatedRuntimeContract` says the embedded contract binds to the artifact
// this process loaded: same bytecode hash, same policy hash, same capability
// matrix, same source identity. That is integrity, and it is what makes the
// contract's *claims* readable. It is not a check of any claim.
//
// `ProofCheckedContract` says an independent consumer checker reconstructed the
// obligations, checked the evidence, and accepted under a pinned policy. Only
// this type may drive behavior that is unsound if a claim is wrong: the proof
// response cache, unbounded runtime reuse, result and optional safety, and the
// durable-workflow guarantees.
//
// The split is enforced by construction. The only way to make one is to hand
// `promote` an assessment the acceptance kernel itself produced and marked
// accepted; there is no literal, no default, and no field to set.
// ---------------------------------------------------------------------------

pub const ProofCheckedContract = struct {
    /// The properties the consumer accepted. A snapshot, not a borrow: the
    /// promotion outlives no allocation of the contract it came from.
    properties: Properties,
    durable_workflow: DurableWorkflowProperties,
    /// Whether any route reads request headers or body. Not a proof result, but
    /// the proof cache's key is method and URL only, so it is carried alongside.
    reads_request_state: bool,
    /// The weakest edge the accepted certificate leaned on.
    grade: pcc.AssuranceGrade,
    /// The artifact declared an ephemeral identity or an unpinned runtime
    /// policy. A consumer that accepted one asked for it.
    development_only: bool,
    /// The guarded operations the consumer reconstructed and covered. Beside
    /// the properties, never inside them: a guard authorizes one live value and
    /// discharges nothing. `required > 0` marks a generation whose behavior
    /// depends on the installed policy, which is what makes a hot swap - it
    /// replaces the executable without re-running acceptance - inadmissible.
    guards: pcc.verdict.GuardVerdicts,
    /// Application-invariant coverage and activation state. Coverage comes
    /// from the acceptance kernel. Runtime readiness starts as not checked and
    /// changes to ready only after pool construction installs and validates
    /// the protected native store.
    invariants: InvariantStatus,
    /// The policy this generation was accepted against. The executable root,
    /// the contract, the residual plan, and this digest install and retire
    /// together; a request reads one generation's tuple or none of it.
    runtime_policy_digest: [32]u8,
    /// The tool catalog lowered from the accepted section bytes. Null when the
    /// artifact carries no catalog. Owned: release it with `deinit`.
    tool_catalog: ?AcceptedCatalog = null,
    /// Construction gate, the same one `ValidatedRuntimeContract` uses: the
    /// field's type names a file-private opaque, so no struct literal outside
    /// this file can produce one. `promote` is the only way in.
    _proof: ValidationProof,

    pub fn deinit(self: *ProofCheckedContract) void {
        if (self.tool_catalog) |*catalog| catalog.deinit();
        self.tool_catalog = null;
    }
};

/// Promote a validated contract using an acceptance the kernel produced.
///
/// Returns null for anything short of acceptance, including an assessment that
/// reached `proof_checked` but failed the policy. There is no partial
/// promotion: a property that did not clear the consumer's bar does not get to
/// drive the runtime a little.
///
/// `tool_catalog_section` is the exact `ZTCAT1` section that was handed to the
/// acceptance run, or null when the artifact carries none. When present it is
/// lowered into an `AcceptedCatalog` and cross-checked against the contract's
/// tool list; an error return is a refusal to start, never a promotion
/// without the catalog.
pub fn promote(
    validated: *const ValidatedRuntimeContract,
    assessment: pcc.Assessment,
    runtime_policy_digest: [32]u8,
    tool_catalog_section: ?[]const u8,
) PromoteError!?ProofCheckedContract {
    if (!assessment.accepted()) return null;
    const grade = assessment.grade orelse return null;
    // Coverage is part of acceptance, not a note beside it. A certificate
    // whose reconstructed guards are not all covered describes operations the
    // consumer could not account for, and the kernel rejects it; this refuses
    // to promote one that arrives uncovered by any other route.
    if (!assessment.guards.ready()) return null;

    const contract_tools = validated.view().tools;
    var tool_catalog: ?AcceptedCatalog = null;
    errdefer if (tool_catalog) |*catalog| catalog.deinit();
    if (tool_catalog_section) |bytes| {
        tool_catalog = try lowerAcceptedCatalog(validated.view().allocator, bytes);
        try crossCheckToolCatalog(&tool_catalog.?, contract_tools);
    } else if (contract_tools.len != 0) {
        return error.ToolCatalogMissing;
    }

    return .{
        .properties = acceptedProperties(validated.properties(), assessment.properties),
        .durable_workflow = acceptedWorkflowProperties(
            validated.durableWorkflowProperties(),
            assessment.properties,
        ),
        .reads_request_state = validated.view().reads_request_state,
        .grade = grade,
        .development_only = assessment.development_only,
        .guards = assessment.guards,
        .invariants = InvariantStatus.fromVerdicts(assessment.invariants),
        .runtime_policy_digest = runtime_policy_digest,
        .tool_catalog = tool_catalog,
        ._proof = validation_proof,
    };
}

/// Decode the accepted `ZTCAT1` bytes and compile every schema they carry.
/// The dev-mode catalog (M4 T3, decision Q4): the producer's tool list encoded with
/// the same encoder the build uses and lowered with the same code as an accepted
/// catalog, so `zttp dev` answers a tool request exactly as a deployment would.
/// It carries no acceptance claim: nothing checked it. Null when there are no
/// tools.
pub fn lowerProducerToolCatalog(allocator: std.mem.Allocator, tools: []const zq.handler_contract.ToolEntry) !?AcceptedCatalog {
    const bytes = (try project_config.tool_catalog_encoding.encode(allocator, tools)) orelse return null;
    defer allocator.free(bytes);
    return try lowerAcceptedCatalog(allocator, bytes);
}

fn lowerAcceptedCatalog(allocator: std.mem.Allocator, bytes: []const u8) PromoteError!AcceptedCatalog {
    const owned = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned);
    const catalog = pcc.tool_catalog.decode(owned) catch return error.AcceptedToolCatalogUndecodable;

    const entries = try allocator.alloc(AcceptedTool, catalog.entry_count);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |*entry| {
            entry.input.deinit();
            entry.output.deinit();
        }
        allocator.free(entries);
    }

    var iterator = catalog.entries();
    while (iterator.next() catch return error.AcceptedToolCatalogUndecodable) |entry| {
        if (filled >= entries.len) return error.AcceptedToolCatalogUndecodable;
        var input = try compileAcceptedSchema(allocator, entry.input_schema);
        errdefer input.deinit();
        const output = try compileAcceptedSchema(allocator, entry.output_schema);
        entries[filled] = .{
            .name = entry.name,
            .method = entry.method,
            .path = entry.path,
            .max_input_bytes = entry.max_input_bytes,
            .input = input,
            .output = output,
        };
        filled += 1;
    }
    if (filled != entries.len) return error.AcceptedToolCatalogUndecodable;

    return .{ .allocator = allocator, .bytes = owned, .entries = entries };
}

fn compileAcceptedSchema(allocator: std.mem.Allocator, schema: []const u8) PromoteError!zq.tool_schema.CompiledToolSchema {
    return zq.tool_schema.compile(allocator, schema) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SchemaNotInSubset => return error.ToolSchemaNotCompilable,
    };
}

/// The accepted catalog wins, and a disagreement is a refusal rather than a
/// merge: the same set of names, and for each the same method, path, and
/// input byte bound.
fn crossCheckToolCatalog(catalog: *const AcceptedCatalog, contract_tools: []const ToolSummary) PromoteError!void {
    // Both directions: the contract is producer output and may repeat a name,
    // so one direction plus equal counts would let [a, a] stand for [a, b].
    if (catalog.entries.len != contract_tools.len) return error.ToolCatalogContractMismatch;
    for (catalog.entries) |entry| {
        for (contract_tools) |tool| {
            if (std.mem.eql(u8, tool.name, entry.name)) break;
        } else return error.ToolCatalogContractMismatch;
    }
    for (contract_tools) |tool| {
        const entry = catalog.find(tool.name) orelse return error.ToolCatalogContractMismatch;
        if (!std.mem.eql(u8, entry.method, tool.method) or
            !std.mem.eql(u8, entry.path, tool.path) or
            entry.max_input_bytes != tool.max_input_bytes)
        {
            return error.ToolCatalogContractMismatch;
        }
    }
}

pub const NativeAdapterAssumption = enum {
    not_applicable,
    trusted,
};

pub const InvariantRuntimeReadiness = enum {
    not_applicable,
    not_checked,
    ready,
};

/// Machine-readable invariant status for an accepted artifact generation.
/// Static coverage and live runtime readiness remain separate fields because
/// the acceptance kernel does not open or validate the protected store.
pub const InvariantStatus = struct {
    configured: bool = false,
    required: u32 = 0,
    covered: u32 = 0,
    writes: u32 = 0,
    reads: u32 = 0,
    /// Whether a covered call site can modify protected ledger state. A report,
    /// and the one a rendered summary must state before its coverage counts: a
    /// reader who does not see it reads "coverage 1 of 1" as "the conservation
    /// predicate ran". It never enters `coverageReady`, and the activation
    /// condition in `server.zig` does not consult it.
    write_applicability: pcc.verdict.WriteApplicability = .not_applicable,
    /// Which kinds the accepted specification declared, one bit per kind at its
    /// wire ordinal less one. Carried so a report can answer per kind without
    /// re-reading the specification document.
    kind_bits: u32 = 0,
    native_adapter_assumption: NativeAdapterAssumption = .not_applicable,
    runtime_readiness: InvariantRuntimeReadiness = .not_applicable,

    pub fn fromVerdicts(verdicts: pcc.verdict.InvariantVerdicts) InvariantStatus {
        return .{
            .configured = verdicts.configured,
            .required = verdicts.required,
            .covered = verdicts.covered,
            .writes = verdicts.writes,
            .reads = verdicts.required -| verdicts.writes,
            .write_applicability = verdicts.writeApplicability(),
            .kind_bits = verdicts.kind_bits,
            .native_adapter_assumption = if (verdicts.configured) .trusted else .not_applicable,
            .runtime_readiness = if (verdicts.configured) .not_checked else .not_applicable,
        };
    }

    /// Write applicability for one declared kind, answered through the kernel's
    /// own helper so this file holds no second opinion about it.
    pub fn writeApplicabilityFor(
        self: InvariantStatus,
        kind: pcc.invariant.Kind,
    ) pcc.verdict.WriteApplicability {
        return pcc.verdict.writeApplicabilityForKind(
            self.kind_bits,
            self.write_applicability,
            kind,
        );
    }

    pub fn coverageReady(self: InvariantStatus) bool {
        return self.configured and self.required > 0 and self.required == self.covered;
    }
};

fn acceptedProperties(
    claimed: Properties,
    verdicts: pcc.verdict.PropertyVerdicts,
) Properties {
    return .{
        .read_only = claimed.read_only and verdicts.accepted(.read_only),
        .retry_safe = claimed.retry_safe and verdicts.accepted(.retry_safe),
        .deterministic = claimed.deterministic and verdicts.accepted(.deterministic),
        .no_secret_leakage = claimed.no_secret_leakage and verdicts.accepted(.no_secret_leakage),
        .state_isolated = claimed.state_isolated and verdicts.accepted(.state_isolated),
        .result_safe = claimed.result_safe and verdicts.accepted(.results_checked),
    };
}

fn acceptedWorkflowProperties(
    claimed: DurableWorkflowProperties,
    verdicts: pcc.verdict.PropertyVerdicts,
) DurableWorkflowProperties {
    return .{
        .retry_safe = claimed.retry_safe and verdicts.accepted(.retry_safe),
    };
}

/// Test-only promotion. Named so a reader can see at a glance that a call site
/// is a test, and file-private so no consumer can reach it.
fn promotedForTest(validated: *const ValidatedRuntimeContract) ProofCheckedContract {
    return .{
        .properties = validated.properties(),
        .durable_workflow = validated.durableWorkflowProperties(),
        .reads_request_state = validated.view().reads_request_state,
        .grade = .translation_validated,
        .development_only = false,
        .guards = .{},
        .invariants = .{},
        .runtime_policy_digest = [_]u8{0} ** 32,
        ._proof = validation_proof,
    };
}

/// Runtime view of the proven contract.
/// Owns all allocated memory; call deinit() when done.
pub const RuntimeContract = struct {
    env_vars: []const []const u8,
    env_dynamic: bool,
    routes: []const Route,
    routes_dynamic: bool,
    /// True when any route reads request headers or body (the contract carried
    /// non-empty `headerParams`/`bodyParams` or their `*Dynamic` flags). The
    /// proof cache keys on method+URL only, so a handler whose response depends
    /// on request headers (auth, content-negotiation) must not be cached - one
    /// caller's response would be replayed to every other caller of the same
    /// URL. Defaults false; an older contract that omits the param lists is
    /// treated as header-independent.
    reads_request_state: bool = false,
    properties: Properties,
    durable_workflow_properties: DurableWorkflowProperties = .{},
    /// Null when the embedded contract did not emit a sandbox block (old
    /// contract, or contract parse fell through). A non-null matrix with
    /// len == 0 is a legitimate state for handlers that import only
    /// capability-free modules (e.g. zttp:router).
    capabilities: ?CapabilityMatrix = null,
    /// Exact core and optional frontend identity used to compile the artifact.
    source_identity: zq.SourceIdentity = .{},
    source_is_tsx: bool = false,
    /// SHA-256 of the bytecode blob, stamped at build time. All-zero means
    /// the contract did not carry a sandbox block.
    artifact_sha256: [32]u8 = [_]u8{0} ** 32,
    /// SHA-256 of the zts rule registry used to extract this contract.
    /// All-zero means the contract did not carry a sandbox block.
    policy_hash: [32]u8 = [_]u8{0} ** 32,
    modules: []const []const u8 = &.{},
    cost_envelope: ?CostEnvelope = null,
    /// The contract's tool list, kept for the startup cross-check against the
    /// accepted catalog. Empty for a handler with no tool catalog.
    tools: []const ToolSummary = &.{},
    allocator: std.mem.Allocator,

    pub fn hasCapability(self: *const RuntimeContract, cap: ModuleCapability) bool {
        const caps = self.capabilities orelse return false;
        return caps.has(cap);
    }

    pub fn deinit(self: *RuntimeContract) void {
        for (self.env_vars) |v| self.allocator.free(v);
        self.allocator.free(self.env_vars);
        for (self.routes) |r| {
            self.allocator.free(r.method);
            self.allocator.free(r.path);
        }
        self.allocator.free(self.routes);
        for (self.modules) |m| self.allocator.free(m);
        self.allocator.free(self.modules);
        if (self.cost_envelope) |*envelope| envelope.deinit(self.allocator);
        freeToolSummaries(self.allocator, self.tools);
    }

    /// Check if a request method+path matches any proven route.
    /// Returns true if routes are dynamic (can't pre-filter) or if a match is found.
    pub fn matchesRoute(self: *const RuntimeContract, method: []const u8, path: []const u8) bool {
        if (self.routes_dynamic) return true;
        if (self.routes.len == 0) return true; // no route info extracted
        for (self.routes) |route| {
            if (std.ascii.eqlIgnoreCase(route.method, method) and matchPath(route.path, path)) {
                return true;
            }
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Raw / Validated newtype split
//
// `parseContractJson` and `fromHandlerContract` return a `RawRuntimeContract`.
// The runtime hot path accepts `ValidatedRuntimeContract`, which is
// constructible only via `validate`. That gates the three integrity checks
// (capability matrix, policy hash, embedded artifact hash) at the type level
// so the request loop cannot be wired against an unvalidated contract.
//
// Env-var presence stays a separate `validateEnvVars` call so the server keeps
// emitting one error line per missing var.
// ---------------------------------------------------------------------------

pub const RawRuntimeContract = struct {
    inner: RuntimeContract,

    pub fn deinit(self: *RawRuntimeContract) void {
        self.inner.deinit();
    }

    /// Read-only view for tools that only need summary fields (e.g. `attest`)
    /// without forcing validation.
    pub fn rawView(self: *const RawRuntimeContract) *const RuntimeContract {
        return &self.inner;
    }
};

// ---------------------------------------------------------------------------
// Validation sentinel — closes Wave 1B/2D P0 #4 (2026-05-23 review).
//
// `ValidatedRuntimeContract.inner` used to be a public field with no
// type-level construction gate, so callers could synthesise a fake
// "validated" contract with a `ValidatedRuntimeContract{ .inner = ... }`
// literal and bypass `verifyCapabilityMatrix` / `verifyPolicyHash` /
// `verifyArtifactHash` entirely. The `ValidationProof` struct below carries
// a function-pointer field whose argument type is a file-private opaque:
// external code cannot name `SentinelMarker`, so it cannot declare a
// function of the matching signature, and anonymous struct literal
// coercion has nowhere to land. The only path that produces a
// `ValidationProof` value is `validation_proof` inside this file, and the
// only path that wraps it into a `ValidatedRuntimeContract` is `validate`
// or the explicitly-named internal helper `validatedFromInner` used by
// tests in this module.
// ---------------------------------------------------------------------------

const SentinelMarker = opaque {};
fn validatedMarker(_: *const SentinelMarker) void {}
const ValidationProof = struct {
    marker: *const fn (*const SentinelMarker) void,
};
const validation_proof: ValidationProof = .{ .marker = validatedMarker };

pub const ValidatedRuntimeContract = struct {
    inner: RuntimeContract,
    /// Construction gate; only `validate` (and the file-private
    /// `validatedFromInner` test helper) can populate this field because
    /// the type's function-pointer argument refers to a non-pub opaque.
    /// Do not name this field from outside this file.
    _proof: ValidationProof,

    pub fn deinit(self: *ValidatedRuntimeContract) void {
        self.inner.deinit();
    }

    pub fn view(self: *const ValidatedRuntimeContract) *const RuntimeContract {
        return &self.inner;
    }

    pub fn properties(self: *const ValidatedRuntimeContract) Properties {
        return self.inner.properties;
    }

    pub fn durableWorkflowProperties(self: *const ValidatedRuntimeContract) DurableWorkflowProperties {
        return self.inner.durable_workflow_properties;
    }

    pub fn hasCapability(self: *const ValidatedRuntimeContract, cap: ModuleCapability) bool {
        return self.inner.hasCapability(cap);
    }

    pub fn matchesRoute(
        self: *const ValidatedRuntimeContract,
        method: []const u8,
        path: []const u8,
    ) bool {
        return self.inner.matchesRoute(method, path);
    }
};

/// File-private constructor used by tests in this module and by helpers
/// that have either run the integrity checks themselves or are exercising
/// a code path that does not need them (e.g. unit tests that probe
/// `derivePoolingPolicy`). External modules cannot call this because the
/// declaration is not `pub`, and they cannot reproduce its return value
/// because they cannot name `ValidationProof`.
fn validatedFromInner(inner: RuntimeContract) ValidatedRuntimeContract {
    return .{ .inner = inner, ._proof = validation_proof };
}

pub const ValidateOptions = struct {
    /// Embedded bytecode blob whose SHA-256 must match the contract's
    /// `artifact_sha256`. Skipping the check for a non-zero hash is unsafe;
    /// pass null only when the contract carries no artifact hash (live reload
    /// from in-memory HandlerContract) or when the caller is genuinely running
    /// without embedded bytecode.
    bytecode: ?[]const u8 = null,
};

/// Promote a Raw contract to Validated by enforcing integrity invariants:
/// capability-matrix drift, policy-hash drift, and artifact-hash drift. On
/// success, the inner storage transfers into the returned Validated; on
/// failure, it is freed.
pub fn validate(
    raw: RawRuntimeContract,
    opts: ValidateOptions,
) !ValidatedRuntimeContract {
    var inner = raw.inner;
    errdefer inner.deinit();
    try verifyCapabilityMatrix(&inner);
    try verifySourceIdentity(&inner);
    try verifyPolicyHash(&inner);
    try verifyArtifactHash(&inner, opts.bytecode);
    return validatedFromInner(inner);
}

/// Parse a contract JSON blob into a RuntimeContract: the shared contract
/// codec followed by the runtime projection. The runtime and the analyzer
/// therefore read one wire format through one reader.
pub fn parseContractJson(allocator: std.mem.Allocator, source: []const u8) !RawRuntimeContract {
    var hc = try zq.handler_contract.parseFromJson(allocator, source);
    defer hc.deinit(allocator);
    return fromHandlerContract(allocator, &hc);
}

/// Match a route pattern (e.g. "/users/:id") against a request path (e.g. "/users/42").
/// Supports :param segments as wildcards.
fn matchPath(pattern: []const u8, path: []const u8) bool {
    var pat_iter = std.mem.splitScalar(u8, pattern, '/');
    var path_iter = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pat_seg = pat_iter.next();
        const path_seg = path_iter.next();

        if (pat_seg == null and path_seg == null) return true;
        if (pat_seg == null or path_seg == null) return false;

        const ps = pat_seg.?;
        const rs = path_seg.?;

        // :param is a wildcard segment
        if (ps.len > 0 and ps[0] == ':') continue;
        // * is a catch-all
        if (std.mem.eql(u8, ps, "*")) return true;

        if (!std.mem.eql(u8, ps, rs)) return false;
    }
}

/// Validate that all proven env vars are set. Returns list of missing var names.
pub fn validateEnvVars(allocator: std.mem.Allocator, contract: *const ValidatedRuntimeContract) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer missing.deinit(allocator);

    for (contract.view().env_vars) |name| {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        if (std.c.getenv(name_z) == null) {
            try missing.append(allocator, name);
        }
    }

    return try missing.toOwnedSlice(allocator);
}

/// Build a RawRuntimeContract directly from an engine HandlerContract.
/// Allocates all strings with the given allocator. Caller owns the result.
pub fn fromHandlerContract(allocator: std.mem.Allocator, hc: *const HandlerContract) !RawRuntimeContract {
    // Copy env vars
    var env_vars: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (env_vars.items) |v| allocator.free(v);
        env_vars.deinit(allocator);
    }
    for (hc.env.literal.items) |s| {
        const duped = try allocator.dupe(u8, s);
        errdefer allocator.free(duped);
        try env_vars.append(allocator, duped);
    }

    // Copy API routes (method + path)
    var routes: std.ArrayList(Route) = .empty;
    errdefer {
        for (routes.items) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        routes.deinit(allocator);
    }
    var reads_request_state = false;
    for (hc.api.routes.items) |api_route| {
        // A route with no method or no path cannot be matched, and putting one
        // in the table would be worse than dropping it: `matchesRoute` passes
        // everything when the table is empty, so a single unmatchable entry
        // turns the pre-filter from "allow all" into "reject all".
        if (api_route.method.len == 0 or api_route.path.len == 0) continue;
        if (api_route.header_params.items.len > 0 or api_route.header_params_dynamic or
            api_route.request_bodies.items.len > 0 or api_route.request_bodies_dynamic)
        {
            reads_request_state = true;
        }
        const method = try allocator.dupe(u8, api_route.method);
        errdefer allocator.free(method);
        const path = try allocator.dupe(u8, api_route.path);
        errdefer allocator.free(path);
        try routes.append(allocator, .{ .method = method, .path = path });
    }

    // Convert properties. A contract that carried no `properties` block
    // asserted nothing, so every runtime property stays false. Do NOT fall
    // back to a default-constructed HandlerProperties here: that type defaults
    // no_secret_leakage, no_credential_leakage, input_validated,
    // pii_contained, injection_safe, and state_isolated to true, which would
    // turn "nothing was proven" into "six security properties are proven".
    // state_isolated also feeds derivePoolingPolicy, so the mistake would
    // promote a handler to TTL runtime reuse on an unproven contract.
    const runtime_properties: Properties = if (hc.properties) |hp| .{
        .pure = hp.pure,
        .read_only = hp.read_only,
        .stateless = hp.stateless,
        .retry_safe = hp.retry_safe,
        .deterministic = hp.deterministic,
        .has_egress = hp.has_egress,
        .no_secret_leakage = hp.no_secret_leakage,
        .no_credential_leakage = hp.no_credential_leakage,
        .input_validated = hp.input_validated,
        .pii_contained = hp.pii_contained,
        .injection_safe = hp.injection_safe,
        .idempotent = hp.idempotent,
        .state_isolated = hp.state_isolated,
        .max_io_depth = hp.max_io_depth,
        .fault_covered = hp.fault_covered,
        .result_safe = hp.result_safe,
        .optional_safe = hp.optional_safe,
    } else .{};

    var modules: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (modules.items) |m| allocator.free(m);
        modules.deinit(allocator);
    }
    for (hc.modules.items) |m| {
        const duped = try allocator.dupe(u8, m);
        errdefer allocator.free(duped);
        try modules.append(allocator, duped);
    }

    var cost_envelope: ?CostEnvelope = null;
    errdefer if (cost_envelope) |*envelope| envelope.deinit(allocator);
    if (hc.cost_envelope) |*envelope| {
        cost_envelope = try envelope.dupeOwned(allocator);
    }

    var tools: std.ArrayList(ToolSummary) = .empty;
    errdefer {
        freeToolSummaryItems(allocator, tools.items);
        tools.deinit(allocator);
    }
    for (hc.tools.items) |tool| {
        // The same split the `ZTCAT1` encoder makes, so the two sides of the
        // startup cross-check compare like with like.
        const space = std.mem.indexOfScalar(u8, tool.route, ' ') orelse return error.ToolRouteInvalid;
        if (space == 0 or space + 1 >= tool.route.len) return error.ToolRouteInvalid;
        try tools.ensureUnusedCapacity(allocator, 1);
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const method = try std.ascii.allocUpperString(allocator, tool.route[0..space]);
        errdefer allocator.free(method);
        const path = try allocator.dupe(u8, tool.route[space + 1 ..]);
        tools.appendAssumeCapacity(.{
            .name = name,
            .method = method,
            .path = path,
            .max_input_bytes = tool.max_input_bytes,
        });
    }

    const cost_envelope_out = cost_envelope;
    cost_envelope = null;

    // Take ownership of the three lists one at a time, each with its own
    // errdefer. Doing this inline in the struct literal below leaks: a
    // successful `toOwnedSlice` empties its list, which disarms that list's
    // errdefer, so a later allocation failure in the same literal drops the
    // slices already taken.
    const env_vars_out = try env_vars.toOwnedSlice(allocator);
    errdefer {
        for (env_vars_out) |v| allocator.free(v);
        allocator.free(env_vars_out);
    }
    const routes_out = try routes.toOwnedSlice(allocator);
    errdefer {
        for (routes_out) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(routes_out);
    }
    const modules_out = try modules.toOwnedSlice(allocator);
    errdefer {
        for (modules_out) |m| allocator.free(m);
        allocator.free(modules_out);
    }
    const tools_out = try tools.toOwnedSlice(allocator);
    errdefer freeToolSummaries(allocator, tools_out);

    return .{ .inner = .{
        .env_vars = env_vars_out,
        .env_dynamic = hc.env.dynamic,
        .routes = routes_out,
        .routes_dynamic = hc.api.routes_dynamic,
        .reads_request_state = reads_request_state,
        .properties = runtime_properties,
        .durable_workflow_properties = .{
            .retry_safe = hc.durable.workflow.properties.retry_safe,
            .idempotent = hc.durable.workflow.properties.idempotent,
            .fault_covered = hc.durable.workflow.properties.fault_covered,
        },
        .capabilities = hc.capabilities,
        .source_identity = hc.source_identity,
        .source_is_tsx = std.mem.endsWith(u8, hc.handler.path, ".tsx"),
        .artifact_sha256 = hc.artifact_sha256,
        .policy_hash = hc.policy_hash,
        .modules = modules_out,
        .cost_envelope = cost_envelope_out,
        .tools = tools_out,
        .allocator = allocator,
    } };
}

fn freeToolSummaryItems(allocator: std.mem.Allocator, tools: []const ToolSummary) void {
    for (tools) |tool| {
        allocator.free(tool.name);
        allocator.free(tool.method);
        allocator.free(tool.path);
    }
}

fn freeToolSummaries(allocator: std.mem.Allocator, tools: []const ToolSummary) void {
    freeToolSummaryItems(allocator, tools);
    allocator.free(tools);
}

/// Rebuild the capability matrix from the currently-linked registry for
/// this handler's imports. Compare against `contract.capabilities.hash` to
/// detect drift between a compiled contract and the runtime binary.
pub fn deriveLiveCapabilityMatrix(contract: *const RuntimeContract) CapabilityMatrix {
    return zq.computeCapabilityMatrix(contract.modules);
}

/// Verify the embedded matrix still matches what the linked registry would
/// produce. Returns error.CapabilityMatrixMismatch on drift. Skips silently
/// when the contract did not carry a sandbox block.
pub fn verifyCapabilityMatrix(contract: *const RuntimeContract) !void {
    const stored = contract.capabilities orelse return;
    const live = deriveLiveCapabilityMatrix(contract);
    if (!std.mem.eql(u8, &live.hash, &stored.hash)) {
        return error.CapabilityMatrixMismatch;
    }
}

/// Verify that the artifact was produced by the linked core grammar,
/// semantics registry, and optional source frontend. Missing identity is a
/// refusal, not a compatibility skip: a runtime cannot safely infer which
/// language accepted the embedded bytes.
pub fn verifySourceIdentity(contract: *const RuntimeContract) !void {
    const identity = contract.source_identity;
    if (!identity.isStamped()) return error.SourceIdentityMissing;
    if (identity.core_profile != .model_1) return error.SourceProfileMismatch;
    const live = zq.sourceIdentityForPath(if (contract.source_is_tsx) "handler.tsx" else "handler.ts");
    if (!std.mem.eql(u8, &identity.core_grammar_hash, &live.core_grammar_hash)) {
        return error.CoreGrammarHashMismatch;
    }
    if (!std.mem.eql(u8, &identity.semantics_hash, &live.semantics_hash)) {
        return error.SemanticsHashMismatch;
    }

    if (contract.source_is_tsx != (identity.frontend != null)) return error.SourceFrontendMismatch;
    if (identity.frontend) |frontend| {
        if (frontend.profile != .tsx_1) return error.SourceFrontendMismatch;
        if (!std.mem.eql(u8, &frontend.grammar_hash, &live.frontend.?.grammar_hash)) {
            return error.FrontendGrammarHashMismatch;
        }
    }
}

/// Compare the embedded policy hash against the linked rule registry.
/// Returns error.PolicyHashMismatch on drift. All-zero means "not emitted",
/// which skips the check.
pub fn verifyPolicyHash(contract: *const RuntimeContract) !void {
    if (std.mem.allEqual(u8, &contract.policy_hash, 0)) return;
    const hex = zq.policyHash();
    var live: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&live, &hex) catch return error.PolicyHashMismatch;
    if (!std.mem.eql(u8, &live, &contract.policy_hash)) {
        return error.PolicyHashMismatch;
    }
}

/// Re-hash the embedded bytecode and compare against the contract. Skips
/// when the hash is absent (all-zero) or no bytecode was provided.
pub fn verifyArtifactHash(contract: *const RuntimeContract, bytecode: ?[]const u8) !void {
    if (std.mem.allEqual(u8, &contract.artifact_sha256, 0)) return;
    const blob = bytecode orelse return;
    var live: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &live, .{});
    if (!std.mem.eql(u8, &live, &contract.artifact_sha256)) {
        return error.ArtifactHashMismatch;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parseContractJson minimal" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 10,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "routes": [],
        \\  "modules": [],
        \\  "functions": {},
        \\  "env": {"literal": ["JWT_SECRET", "DB_URL"], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "serviceCalls": [],
        \\  "cache": {"namespaces": [], "dynamic": false},
        \\  "sql": {"backend": "sqlite", "queries": [], "dynamic": false},
        \\  "durable": {"used": false, "keys": {"literal": [], "dynamic": false}, "steps": [], "timers": false, "signals": {"literal": [], "dynamic": false}, "producerKeys": {"literal": [], "dynamic": false}},
        \\  "api": {"schemas": [], "requests": {"schemaRefs": [], "dynamic": false}, "auth": {"bearer": false, "jwt": false}, "routes": [], "schemasDynamic": false, "routesDynamic": false},
        \\  "verification": null,
        \\  "aot": null,
        \\  "faultCoverage": null,
        \\  "rateLimiting": null,
        \\  "properties": null,
        \\  "behaviors": [],
        \\  "behaviorsExhaustive": false
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    const contract = &raw.inner;

    try std.testing.expectEqual(@as(usize, 2), contract.env_vars.len);
    try std.testing.expectEqualStrings("JWT_SECRET", contract.env_vars[0]);
    try std.testing.expectEqualStrings("DB_URL", contract.env_vars[1]);
    try std.testing.expect(!contract.env_dynamic);
    try std.testing.expectEqual(@as(usize, 0), contract.routes.len);
    try std.testing.expect(!contract.properties.pure);
    try std.testing.expect(!contract.durable_workflow_properties.retry_safe);
    try std.testing.expect(!contract.durable_workflow_properties.idempotent);
    try std.testing.expect(!contract.durable_workflow_properties.fault_covered);
}

test "parseContractJson reads durable workflow properties" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "durable": {
        \\    "workflow": {
        \\      "properties": {
        \\        "retrySafe": true,
        \\        "idempotent": true,
        \\        "faultCovered": true
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();

    try std.testing.expect(raw.inner.durable_workflow_properties.retry_safe);
    try std.testing.expect(raw.inner.durable_workflow_properties.idempotent);
    try std.testing.expect(raw.inner.durable_workflow_properties.fault_covered);
}

test "parseContractJson with properties and routes" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 10,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "routes": [],
        \\  "modules": [],
        \\  "functions": {},
        \\  "env": {"literal": ["API_KEY"], "dynamic": true},
        \\  "egress": {"endpoints": ["api.stripe.com"], "dynamic": false},
        \\  "serviceCalls": [],
        \\  "cache": {"namespaces": [], "dynamic": false},
        \\  "sql": {"backend": "sqlite", "queries": [], "dynamic": false},
        \\  "durable": {"used": false, "keys": {"literal": [], "dynamic": false}, "steps": [], "timers": false, "signals": {"literal": [], "dynamic": false}, "producerKeys": {"literal": [], "dynamic": false}},
        \\  "api": {"schemas": [], "requests": {"schemaRefs": [], "dynamic": false}, "auth": {"bearer": true, "jwt": true}, "routes": [{"method": "GET", "path": "/health", "requestSchemaRefs": [], "requestSchemaDynamic": false, "requiresBearer": false, "requiresJwt": false, "pathParams": [], "queryParams": [], "headerParams": [], "queryParamsDynamic": false, "headerParamsDynamic": false, "requestBodies": [], "requestBodiesDynamic": false, "responses": [], "responsesDynamic": false, "responseStatus": 200, "responseContentType": "application/json", "responseSchemaRef": null, "responseSchema": null, "responseSchemaDynamic": false}, {"method": "POST", "path": "/users/:id", "requestSchemaRefs": [], "requestSchemaDynamic": false, "requiresBearer": true, "requiresJwt": true, "pathParams": [], "queryParams": [], "headerParams": [], "queryParamsDynamic": false, "headerParamsDynamic": false, "requestBodies": [], "requestBodiesDynamic": false, "responses": [], "responsesDynamic": false, "responseStatus": 201, "responseContentType": "application/json", "responseSchemaRef": null, "responseSchema": null, "responseSchemaDynamic": false}], "schemasDynamic": false, "routesDynamic": false},
        \\  "verification": {"exhaustiveReturns": true, "resultsSafe": true, "unreachableCode": true, "bytecodeVerified": true},
        \\  "aot": null,
        \\  "faultCoverage": null,
        \\  "rateLimiting": null,
        \\  "properties": {"pure": false, "readOnly": true, "stateless": true, "retrySafe": true, "deterministic": true, "hasEgress": true, "noSecretLeakage": true, "noCredentialLeakage": true, "inputValidated": false, "piiContained": false, "injectionSafe": true, "idempotent": false, "stateIsolated": true, "maxIoDepth": 3, "faultCovered": true, "resultSafe": true, "optionalSafe": true},
        \\  "behaviors": [],
        \\  "behaviorsExhaustive": false
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    const contract = &raw.inner;

    try std.testing.expectEqual(@as(usize, 1), contract.env_vars.len);
    try std.testing.expectEqualStrings("API_KEY", contract.env_vars[0]);
    try std.testing.expect(contract.env_dynamic);

    try std.testing.expectEqual(@as(usize, 2), contract.routes.len);
    try std.testing.expectEqualStrings("GET", contract.routes[0].method);
    try std.testing.expectEqualStrings("/health", contract.routes[0].path);
    try std.testing.expectEqualStrings("POST", contract.routes[1].method);
    try std.testing.expectEqualStrings("/users/:id", contract.routes[1].path);
    try std.testing.expect(!contract.routes_dynamic);

    const p = contract.properties;
    try std.testing.expect(!p.pure);
    try std.testing.expect(p.read_only);
    try std.testing.expect(p.stateless);
    try std.testing.expect(p.retry_safe);
    try std.testing.expect(p.deterministic);
    try std.testing.expect(p.has_egress);
    try std.testing.expect(p.no_secret_leakage);
    try std.testing.expect(p.injection_safe);
    try std.testing.expect(p.state_isolated);
    try std.testing.expectEqual(@as(u32, 3), p.max_io_depth.?);
    try std.testing.expect(p.fault_covered);
    try std.testing.expect(p.result_safe);
    try std.testing.expect(p.optional_safe);

    // Both routes carry empty headerParams, so the handler is input-independent
    // and the proof cache stays eligible.
    try std.testing.expect(!contract.reads_request_state);
}

test "parseContractJson flags reads_request_state when a route reads headers" {
    const allocator = std.testing.allocator;
    // A route declaring a non-empty headerParams (e.g. reads req.headers
    // ['x-api-key']). The proof cache keys on method+URL only, so this handler
    // must be excluded from caching.
    const source =
        \\{
        \\  "api": {"routes": [{"method": "GET", "path": "/me", "headerParams": [{"name": "x-api-key", "kind": "header"}], "headerParamsDynamic": false}], "routesDynamic": false},
        \\  "properties": {"pure": false, "readOnly": true, "stateless": true, "retrySafe": true, "deterministic": true, "hasEgress": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    try std.testing.expect(raw.inner.reads_request_state);
}

test "parseContractJson flags reads_request_state on dynamic header access" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "api": {"routes": [{"method": "GET", "path": "/me", "headerParams": [], "headerParamsDynamic": true}], "routesDynamic": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    try std.testing.expect(raw.inner.reads_request_state);
}

// Regression: parseContractJson handles allocator failure at every internal
// allocation point without leaking. The embedded contract is parsed at
// startup from the self-extracting binary; any leak under memory pressure
// would degrade subsequent runtime behavior. The test exercises a contract
// with multiple env vars, routes, and modules so the errdefer ladder on
// every loop iteration sees both staged-allocation and append-failure paths.
fn parseContractFailingAlloc(allocator: std.mem.Allocator) !void {
    const source =
        \\{
        \\  "version": 10,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "routes": [],
        \\  "modules": ["zttp:env", "zttp:crypto"],
        \\  "functions": {},
        \\  "env": {"literal": ["JWT_SECRET", "DB_URL", "API_KEY"], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "serviceCalls": [],
        \\  "cache": {"namespaces": [], "dynamic": false},
        \\  "sql": {"backend": "sqlite", "queries": [], "dynamic": false},
        \\  "durable": {"used": false, "keys": {"literal": [], "dynamic": false}, "steps": [], "timers": false, "signals": {"literal": [], "dynamic": false}, "producerKeys": {"literal": [], "dynamic": false}},
        \\  "api": {"schemas": [], "requests": {"schemaRefs": [], "dynamic": false}, "auth": {"bearer": false, "jwt": false}, "routes": [{"method": "GET", "path": "/a"}, {"method": "POST", "path": "/b"}], "schemasDynamic": false, "routesDynamic": false},
        \\  "verification": null,
        \\  "aot": null,
        \\  "faultCoverage": null,
        \\  "rateLimiting": null,
        \\  "properties": null,
        \\  "behaviors": [],
        \\  "behaviorsExhaustive": false
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    raw.deinit();
}

test "parseContractJson tolerates allocator failure at every step" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseContractFailingAlloc,
        .{},
    );
}

test "matchPath exact" {
    try std.testing.expect(matchPath("/health", "/health"));
    try std.testing.expect(!matchPath("/health", "/users"));
    try std.testing.expect(!matchPath("/health", "/health/extra"));
}

test "matchPath with params" {
    try std.testing.expect(matchPath("/users/:id", "/users/42"));
    try std.testing.expect(matchPath("/users/:id", "/users/abc"));
    try std.testing.expect(!matchPath("/users/:id", "/users/42/extra"));
    try std.testing.expect(!matchPath("/users/:id", "/users"));
}

test "matchPath catch-all" {
    try std.testing.expect(matchPath("/api/*", "/api/anything"));
    try std.testing.expect(matchPath("/api/*", "/api/deep/path"));
}

test "matchesRoute with proven routes" {
    const allocator = std.testing.allocator;
    const method1 = try allocator.dupe(u8, "GET");
    const path1 = try allocator.dupe(u8, "/health");
    const method2 = try allocator.dupe(u8, "POST");
    const path2 = try allocator.dupe(u8, "/users/:id");
    var routes_buf = [_]Route{
        .{ .method = method1, .path = path1 },
        .{ .method = method2, .path = path2 },
    };

    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &routes_buf,
        .routes_dynamic = false,
        .properties = .{},
        .allocator = allocator,
    };

    try std.testing.expect(contract.matchesRoute("GET", "/health"));
    try std.testing.expect(contract.matchesRoute("POST", "/users/42"));
    try std.testing.expect(!contract.matchesRoute("DELETE", "/health"));
    try std.testing.expect(!contract.matchesRoute("GET", "/unknown"));

    // Don't call deinit - we used stack buffers, just free the duped strings
    allocator.free(method1);
    allocator.free(path1);
    allocator.free(method2);
    allocator.free(path2);
}

test "matchesRoute with dynamic routes passes everything" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = true,
        .properties = .{},
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(contract.matchesRoute("GET", "/anything"));
    try std.testing.expect(contract.matchesRoute("DELETE", "/whatever"));
}

test "matchesRoute with no routes passes everything" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(contract.matchesRoute("GET", "/anything"));
}

test "fromHandlerContract converts properties and env vars" {
    const allocator = std.testing.allocator;

    // Build a minimal HandlerContract
    var hc = HandlerContract{
        .handler = .{ .path = try allocator.dupe(u8, "handler.ts"), .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{
            .literal = .empty,
            .dynamic = false,
        },
        .egress = .{
            .endpoints = .empty,
            .urls = .empty,
            .dynamic = false,
        },
        .cache = .{
            .namespaces = .empty,
            .dynamic = false,
        },
        .sql = .{
            .backend = "sqlite",
            .queries = .empty,
            .dynamic = false,
        },
        .durable = .{
            .used = false,
            .keys = .{ .literal = .empty, .dynamic = false },
            .steps = .empty,
            .timers = false,
            .signals = .{ .literal = .empty, .dynamic = false },
            .producer_keys = .{ .literal = .empty, .dynamic = false },
        },
        .scope = .{
            .used = false,
            .names = .empty,
            .dynamic = false,
            .max_depth = 0,
        },
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
        .source_identity = zq.sourceIdentityForPath("handler.ts"),
    };
    defer hc.deinit(allocator);

    // Add an env var
    try hc.env.literal.append(allocator, try allocator.dupe(u8, "API_KEY"));
    hc.durable.workflow.properties.retry_safe = true;
    hc.durable.workflow.properties.idempotent = true;
    hc.durable.workflow.properties.fault_covered = true;

    var raw = try fromHandlerContract(allocator, &hc);
    defer raw.deinit();
    const rc = &raw.inner;

    try std.testing.expectEqual(@as(usize, 1), rc.env_vars.len);
    try std.testing.expectEqualStrings("API_KEY", rc.env_vars[0]);
    try std.testing.expect(!rc.env_dynamic);
    try std.testing.expect(rc.properties.read_only);
    try std.testing.expect(rc.properties.retry_safe);
    try std.testing.expect(rc.properties.deterministic);
    try std.testing.expect(!rc.properties.pure);
    try std.testing.expect(rc.durable_workflow_properties.retry_safe);
    try std.testing.expect(rc.durable_workflow_properties.idempotent);
    try std.testing.expect(rc.durable_workflow_properties.fault_covered);
    try std.testing.expectEqual(zq.CoreProfile.model_1, rc.source_identity.core_profile);
    try std.testing.expect(rc.source_identity.isStamped());
    try std.testing.expect(rc.source_identity.frontend == null);
}

// Drift guard: parseContractJson is a second, hand-rolled reader of the contract
// wire format, separate from the canonical writer/parser pair in the engine. It
// stays decoupled (it reads only the subset of fields the runtime needs) on the
// condition that the wire keys it hardcodes match what the writer emits. This
// test pins that link: it emits a contract through the canonical writer and
// reads it back here, so any future writer-side key rename (env/literal,
// api/routes/method/path, properties.*, modules, durable.workflow.properties.*)
// fails loudly instead of silently disabling a runtime check.
test "contract wire format round-trips between writer and runtime parser" {
    const allocator = std.testing.allocator;

    var hc = HandlerContract{
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
    defer hc.deinit(allocator);

    try hc.env.literal.append(allocator, try allocator.dupe(u8, "API_KEY"));
    try hc.modules.append(allocator, try allocator.dupe(u8, "zttp:crypto"));
    hc.durable.workflow.properties.retry_safe = true;
    hc.durable.workflow.properties.idempotent = true;
    hc.durable.workflow.properties.fault_covered = true;
    try hc.api.routes.append(allocator, .{
        .method = try allocator.dupe(u8, "GET"),
        .path = try allocator.dupe(u8, "/users"),
        .request_schema_refs = .empty,
        .request_schema_dynamic = false,
        .requires_bearer = false,
        .requires_jwt = false,
    });

    // Emit through the canonical wire-format writer.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try zq.writeContractJson(&hc, &aw.writer);

    // Read it back through the runtime's hand-rolled parser.
    var raw = try parseContractJson(allocator, aw.writer.buffered());
    defer raw.deinit();
    const rc = &raw.inner;

    try std.testing.expectEqual(@as(usize, 1), rc.env_vars.len);
    try std.testing.expectEqualStrings("API_KEY", rc.env_vars[0]);
    try std.testing.expectEqual(@as(usize, 1), rc.modules.len);
    try std.testing.expectEqualStrings("zttp:crypto", rc.modules[0]);
    try std.testing.expectEqual(@as(usize, 1), rc.routes.len);
    try std.testing.expectEqualStrings("GET", rc.routes[0].method);
    try std.testing.expectEqualStrings("/users", rc.routes[0].path);
    try std.testing.expect(rc.properties.read_only);
    try std.testing.expect(rc.properties.retry_safe);
    try std.testing.expect(rc.properties.deterministic);
    try std.testing.expect(!rc.properties.pure);
    try std.testing.expect(rc.durable_workflow_properties.retry_safe);
    try std.testing.expect(rc.durable_workflow_properties.idempotent);
    try std.testing.expect(rc.durable_workflow_properties.fault_covered);
}

test "parseContractJson reads sandbox block" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 12,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": ["zttp:crypto", "zttp:auth"],
        \\  "sandbox": {
        \\    "capabilities": ["clock", "crypto"],
        \\    "capabilityHash": "0000000000000000000000000000000000000000000000000000000000000000"
        \\  },
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    const contract = &raw.inner;

    try std.testing.expect(contract.capabilities != null);
    try std.testing.expectEqual(@as(u8, 2), contract.capabilities.?.len);
    try std.testing.expect(contract.hasCapability(.clock));
    try std.testing.expect(contract.hasCapability(.crypto));
    try std.testing.expect(!contract.hasCapability(.stderr));
    try std.testing.expectEqual(@as(usize, 2), contract.modules.len);
}

test "validate promotes Raw to Validated when integrity checks pass" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    raw.inner.source_identity = zq.sourceIdentityForPath("handler.ts");
    var validated = try validate(raw, .{});
    defer validated.deinit();

    try std.testing.expect(validated.view().capabilities == null);
}

test "validate rejects artifact-hash drift" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    raw.inner.source_identity = zq.sourceIdentityForPath("handler.ts");
    raw.inner.artifact_sha256 = [_]u8{0xAB} ** 32;
    try std.testing.expectError(
        error.ArtifactHashMismatch,
        validate(raw, .{ .bytecode = "totally different" }),
    );
}

test "parseContractJson returns null capabilities when sandbox block is absent" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;
    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();
    const contract = &raw.inner;
    try std.testing.expect(contract.capabilities == null);
    try std.testing.expect(!contract.hasCapability(.crypto));
}

test "verifyCapabilityMatrix passes for a live-derived matrix" {
    const allocator = std.testing.allocator;
    // Build modules and a matching matrix from the live registry
    var modules_list: std.ArrayList([]const u8) = .empty;
    errdefer modules_list.deinit(allocator);
    try modules_list.append(allocator, try allocator.dupe(u8, "zttp:crypto"));
    try modules_list.append(allocator, try allocator.dupe(u8, "zttp:auth"));

    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .modules = try modules_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer contract.deinit();

    contract.capabilities = deriveLiveCapabilityMatrix(&contract);
    try std.testing.expectEqual(@as(u8, 2), contract.capabilities.?.len);

    try verifyCapabilityMatrix(&contract);
}

test "verifyCapabilityMatrix detects drift" {
    const allocator = std.testing.allocator;
    var modules_list: std.ArrayList([]const u8) = .empty;
    errdefer modules_list.deinit(allocator);
    try modules_list.append(allocator, try allocator.dupe(u8, "zttp:crypto"));

    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .modules = try modules_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer contract.deinit();

    // Seed a non-null matrix whose hash does not match the live derivation.
    contract.capabilities = CapabilityMatrix{
        .len = 1,
        .items = blk: {
            var items: [capability_count]ModuleCapability = undefined;
            items[0] = .crypto;
            break :blk items;
        },
        .hash = [_]u8{0xAA} ** 32,
    };

    try std.testing.expectError(
        error.CapabilityMatrixMismatch,
        verifyCapabilityMatrix(&contract),
    );
}

test "verifyCapabilityMatrix skips when matrix is absent" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    try verifyCapabilityMatrix(&contract);
}

test "derivePoolingPolicy: null contract falls back to bounded count" {
    try std.testing.expectEqual(PoolingPolicy.reuse_bounded_by_count, derivePoolingPolicy(null));
}

test "derivePoolingPolicy: pure+deterministic+isolated = unbounded" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{
            .pure = true,
            .deterministic = true,
            .state_isolated = true,
        },
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    try std.testing.expectEqual(PoolingPolicy.reuse_unbounded, derivePoolingPolicy(&promotedForTest(&validated)));
}

test "derivePoolingPolicy: read_only+isolated = ttl" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{
            .read_only = true,
            .state_isolated = true,
        },
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    try std.testing.expectEqual(PoolingPolicy.reuse_bounded_by_ttl, derivePoolingPolicy(&promotedForTest(&validated)));
}

test "derivePoolingPolicy: has_egress = bounded count" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{
            .has_egress = true,
            .state_isolated = true,
        },
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    try std.testing.expectEqual(PoolingPolicy.reuse_bounded_by_count, derivePoolingPolicy(&promotedForTest(&validated)));
}

test "verifyPolicyHash passes when hash matches live registry" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    const hex = zq.policyHash();
    _ = try std.fmt.hexToBytes(&contract.policy_hash, &hex);
    try verifyPolicyHash(&contract);
}

test "verifyPolicyHash rejects drift" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .policy_hash = [_]u8{0xAB} ** 32,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.PolicyHashMismatch, verifyPolicyHash(&contract));
}

test "verifyPolicyHash skips when hash is absent" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    try verifyPolicyHash(&contract);
}

test "verifyArtifactHash matches bytecode digest" {
    const bytecode = "some fake bytecode blob";
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytecode, &expected, .{});
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .artifact_sha256 = expected,
        .allocator = std.testing.allocator,
    };
    try verifyArtifactHash(&contract, bytecode);
}

test "verifyArtifactHash rejects tampered bytecode" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .artifact_sha256 = [_]u8{0xFF} ** 32,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectError(error.ArtifactHashMismatch, verifyArtifactHash(&contract, "anything"));
}

test "verifyArtifactHash skips when hash is absent" {
    var contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    try verifyArtifactHash(&contract, "anything");
}

test "derivePoolingPolicy: !state_isolated = bounded count" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{
            .pure = true,
            .deterministic = true,
            .state_isolated = false,
        },
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    try std.testing.expectEqual(PoolingPolicy.reuse_bounded_by_count, derivePoolingPolicy(&promotedForTest(&validated)));
}

// ---------------------------------------------------------------------------
// Construction gate — Wave 1B/2D P0 #4 (2026-05-23 review). External code
// cannot literal-construct a `ValidatedRuntimeContract` because the
// `_proof` field's function-pointer type refers to a file-private opaque
// (`SentinelMarker`). We cannot author a compile-fail test for that case
// (Zig has no negative-compilation harness), so we pin the positive path's
// proof identity and the structural shape of the sentinel signature
// instead. If a future refactor weakens either, these assertions break.
// ---------------------------------------------------------------------------

test "validatedFromInner installs the canonical validation_proof" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    const direct = validatedFromInner(contract);
    try std.testing.expect(direct._proof.marker == validation_proof.marker);
}

test "promotion exposes only properties that cleared the policy" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{
            .read_only = true,
            .state_isolated = true,
            .no_secret_leakage = true,
            .result_safe = true,
        },
        .durable_workflow_properties = .{
            .retry_safe = true,
            .idempotent = true,
            .fault_covered = true,
        },
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    var property_verdicts: pcc.verdict.PropertyVerdicts = .{};
    property_verdicts.recordGrade(.response_total, .trusted);
    property_verdicts.recordGrade(.results_checked, .tested);
    property_verdicts.recordGrade(.no_secret_leakage, .tested);
    property_verdicts.recordGrade(.capability_bounded, .tested);
    property_verdicts.accept(.response_total);
    property_verdicts.accept(.results_checked);
    property_verdicts.accept(.no_secret_leakage);
    property_verdicts.accept(.capability_bounded);
    const assessment = pcc.Assessment{
        .semantic = .policy_accepted,
        .provenance = .absent,
        .grade = .trusted,
        .development_only = false,
        .rejection = null,
        .work_spent = 1,
        .properties = property_verdicts,
    };

    const digest = [_]u8{0xab} ** 32;
    const promoted = (try promote(&validated, assessment, digest, null)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(promoted.properties.no_secret_leakage);
    try std.testing.expect(promoted.properties.result_safe);
    try std.testing.expect(!promoted.properties.read_only);
    try std.testing.expect(!promoted.properties.state_isolated);
    try std.testing.expect(!promoted.durable_workflow.retry_safe);
    try std.testing.expect(!promoted.durable_workflow.idempotent);
    try std.testing.expect(!promoted.durable_workflow.fault_covered);
    // The policy this generation was accepted against travels with it, and a
    // handler with nothing to guard says so with zeroes rather than by leaving
    // the question open.
    try std.testing.expectEqualSlices(u8, &digest, &promoted.runtime_policy_digest);
    try std.testing.expectEqual(@as(u32, 0), promoted.guards.required);
    try std.testing.expect(!promoted.invariants.configured);
    try std.testing.expectEqual(InvariantRuntimeReadiness.not_applicable, promoted.invariants.runtime_readiness);

    // An accepted assessment whose guards are not all covered describes
    // operations nothing accounted for. It does not become a weaker promotion;
    // it becomes no promotion.
    var uncovered = assessment;
    uncovered.guards = .{ .required = 2, .covered = 1 };
    try std.testing.expect((try promote(&validated, uncovered, digest, null)) == null);

    var covered = assessment;
    covered.guards = .{ .required = 2, .covered = 2, .kinds = 0x01 };
    const guarded = (try promote(&validated, covered, digest, null)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), guarded.guards.required);
    // Guard coverage is beside the properties, never inside them: the same
    // property set comes back.
    try std.testing.expectEqual(promoted.properties, guarded.properties);

    var invariant_covered = assessment;
    invariant_covered.invariants = .{
        .configured = true,
        .required = 2,
        .covered = 2,
        .writes = 1,
        .kind_bits = 1,
    };
    const invariant_contract = (try promote(&validated, invariant_covered, digest, null)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(invariant_contract.invariants.coverageReady());
    try std.testing.expectEqual(@as(u32, 1), invariant_contract.invariants.reads);
    try std.testing.expectEqual(NativeAdapterAssumption.trusted, invariant_contract.invariants.native_adapter_assumption);
    try std.testing.expectEqual(InvariantRuntimeReadiness.not_checked, invariant_contract.invariants.runtime_readiness);
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.covered,
        invariant_contract.invariants.write_applicability,
    );
}

test "a read-only generation is coverage ready and reports vacuous write applicability" {
    const contract = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .allocator = std.testing.allocator,
    };
    var validated = validatedFromInner(contract);
    var assessment = pcc.Assessment{
        .semantic = .policy_accepted,
        .provenance = .absent,
        .grade = .trusted,
        .development_only = false,
        .rejection = null,
        .work_spent = 1,
    };
    assessment.invariants = .{
        .configured = true,
        .required = 1,
        .covered = 1,
        .writes = 0,
        .kind_bits = 0b11,
    };
    const promoted = (try promote(&validated, assessment, [_]u8{0xcd} ** 32, null)) orelse
        return error.TestUnexpectedResult;

    // Vacuity is a report, never a relabelling. Coverage readiness reads
    // exactly as it did before the field existed.
    try std.testing.expect(promoted.invariants.coverageReady());
    try std.testing.expectEqual(@as(u32, 1), promoted.invariants.reads);
    try std.testing.expectEqual(@as(u32, 0), promoted.invariants.writes);
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.vacuous,
        promoted.invariants.write_applicability,
    );
    try std.testing.expectEqual(@as(u32, 0b11), promoted.invariants.kind_bits);
    // Both catalog kinds gate `post`, so both declared kinds answer the same.
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.vacuous,
        promoted.invariants.writeApplicabilityFor(.balance_conservation_v1),
    );
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.vacuous,
        promoted.invariants.writeApplicabilityFor(.declared_accounts_v1),
    );

    // An unconfigured generation answers "not applicable" for every kind.
    const unconfigured = InvariantStatus{};
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.not_applicable,
        unconfigured.write_applicability,
    );
    try std.testing.expectEqual(
        pcc.verdict.WriteApplicability.not_applicable,
        unconfigured.writeApplicabilityFor(.balance_conservation_v1),
    );
}

test "ValidationProof argument type is a file-private opaque" {
    const fn_ptr_info = @typeInfo(@TypeOf(validation_proof.marker));
    try std.testing.expect(fn_ptr_info == .pointer);
    const child_info = @typeInfo(fn_ptr_info.pointer.child);
    try std.testing.expect(child_info == .@"fn");
    try std.testing.expectEqual(@as(usize, 1), child_info.@"fn".params.len);
    const param = child_info.@"fn".params[0].type.?;
    const param_info = @typeInfo(param);
    try std.testing.expect(param_info == .pointer);
    const opaque_info = @typeInfo(param_info.pointer.child);
    try std.testing.expect(opaque_info == .@"opaque");
}

test "parseContractJson: errdefer ladders close every failure path" {
    // Walk FailingAllocator.fail_index forward through the function's
    // allocation sequence. testing.allocator catches leaks on the unwind
    // path so any errdefer that forgets a prior allocation surfaces here.
    // Same idiom as `precompile.zig` test
    // "buildServiceTypeContextFromContracts: errdefer ladder closes every
    // failure path" and `pool.zig` Runtime.create.
    const allocator = std.testing.allocator;

    // Minimal input that exercises env literals (the largest dynamically
    // populated array in the minimal parse path). Two entries is enough
    // to expose a partial-fill leak.
    const source =
        \\{
        \\  "version": 10,
        \\  "handler": {"path": "h.ts", "line": 1, "column": 0},
        \\  "routes": [],
        \\  "modules": [],
        \\  "functions": {},
        \\  "env": {"literal": ["JWT_SECRET", "DB_URL"], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "serviceCalls": [],
        \\  "cache": {"namespaces": [], "dynamic": false},
        \\  "sql": {"backend": "sqlite", "queries": [], "dynamic": false},
        \\  "durable": {"used": false, "keys": {"literal": [], "dynamic": false}, "steps": [], "timers": false, "signals": {"literal": [], "dynamic": false}, "producerKeys": {"literal": [], "dynamic": false}},
        \\  "api": {"schemas": [], "requests": {"schemaRefs": [], "dynamic": false}, "auth": {"bearer": false, "jwt": false}, "routes": [], "schemasDynamic": false, "routesDynamic": false},
        \\  "verification": null,
        \\  "aot": null,
        \\  "faultCoverage": null,
        \\  "rateLimiting": null,
        \\  "properties": null,
        \\  "behaviors": [],
        \\  "behaviorsExhaustive": false
        \\}
    ;

    // Find the ceiling allocation count via a successful run.
    var ceiling: usize = 0;
    {
        var probe = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
        var raw = try parseContractJson(probe.allocator(), source);
        ceiling = probe.alloc_index;
        raw.deinit();
    }

    var fail_at: usize = 0;
    while (fail_at < ceiling) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_at });
        const result = parseContractJson(failing.allocator(), source);
        if (result) |ok| {
            var ok_mut = ok;
            ok_mut.deinit();
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

// ---------------------------------------------------------------------------
// Regression guards for the defects the B1 differential harness exposed. The
// harness itself is gone with the second reader it compared against; these
// pin the behavior it proved.
// ---------------------------------------------------------------------------

test "a stamped contract with no sandbox block still validates" {
    // A null capability matrix means "this contract makes no capability
    // statement", which makes verifyCapabilityMatrix skip. Collapsing that
    // into an empty matrix made the check compare the live matrix against an
    // all-zero hash, so every pre-sandbox binary refused to serve.
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    try std.testing.expect(raw.rawView().capabilities == null);
    raw.inner.source_identity = zq.sourceIdentityForPath("handler.ts");

    var validated = try validate(raw, .{});
    defer validated.deinit();
}

test "runtime validation refuses missing or stale source identity" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 18,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;

    const missing = try parseContractJson(allocator, source);
    try std.testing.expectError(error.SourceIdentityMissing, validate(missing, .{}));

    var stale_grammar = try parseContractJson(allocator, source);
    stale_grammar.inner.source_identity = zq.sourceIdentityForPath("handler.ts");
    stale_grammar.inner.source_identity.core_grammar_hash[0] ^= 0xff;
    try std.testing.expectError(error.CoreGrammarHashMismatch, validate(stale_grammar, .{}));

    var stale_semantics = try parseContractJson(allocator, source);
    stale_semantics.inner.source_identity = zq.sourceIdentityForPath("handler.ts");
    stale_semantics.inner.source_identity.semantics_hash[0] ^= 0xff;
    try std.testing.expectError(error.SemanticsHashMismatch, validate(stale_semantics, .{}));
}

test "runtime validation binds the TSX frontend identity" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 18,
        \\  "handler": {"path": "handler.tsx", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;

    var missing_frontend = try parseContractJson(allocator, source);
    missing_frontend.inner.source_identity = zq.sourceIdentityForPath("handler.ts");
    try std.testing.expectError(error.SourceFrontendMismatch, validate(missing_frontend, .{}));

    var stale_frontend = try parseContractJson(allocator, source);
    stale_frontend.inner.source_identity = zq.sourceIdentityForPath("handler.tsx");
    stale_frontend.inner.source_identity.frontend.?.grammar_hash[0] ^= 0xff;
    try std.testing.expectError(error.FrontendGrammarHashMismatch, validate(stale_frontend, .{}));

    var valid = try parseContractJson(allocator, source);
    valid.inner.source_identity = zq.sourceIdentityForPath("handler.tsx");
    var validated = try validate(valid, .{});
    defer validated.deinit();
    try std.testing.expectEqual(zq.SourceFrontendProfile.tsx_1, validated.view().source_identity.frontend.?.profile);
}

test "the module list survives the read" {
    // The codec dropped the top-level `modules` array entirely. The runtime
    // derives the live capability matrix from that list, so an empty one made
    // verifyCapabilityMatrix compare a real stored hash against the
    // empty-set hash.
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": ["zttp:crypto", "zttp:auth"],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();

    const contract = raw.rawView();
    try std.testing.expectEqual(@as(usize, 2), contract.modules.len);
    try std.testing.expectEqualStrings("zttp:crypto", contract.modules[0]);
    try std.testing.expectEqualStrings("zttp:auth", contract.modules[1]);
}

test "a contract with no properties block proves nothing" {
    // HandlerProperties defaults six flow and isolation fields to true, which
    // is right for the analyzer that computes them and wrong for a reader.
    // Relying on those defaults turned "asserted nothing" into "six security
    // properties hold", and state_isolated also drives derivePoolingPolicy.
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "version": 13,
        \\  "handler": {"path": "handler.ts", "line": 1, "column": 0},
        \\  "modules": [],
        \\  "env": {"literal": [], "dynamic": false},
        \\  "egress": {"endpoints": [], "dynamic": false},
        \\  "api": {"routes": [], "routesDynamic": false}
        \\}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();

    const p = raw.rawView().properties;
    try std.testing.expect(!p.no_secret_leakage);
    try std.testing.expect(!p.no_credential_leakage);
    try std.testing.expect(!p.input_validated);
    try std.testing.expect(!p.pii_contained);
    try std.testing.expect(!p.injection_safe);
    try std.testing.expect(!p.state_isolated);
}

test "a route with no method never enters the route table" {
    // matchesRoute treats an empty table as "allow everything", so a single
    // unmatchable entry would flip the pre-filter from allow-all to
    // reject-all.
    const allocator = std.testing.allocator;
    const source =
        \\{"version": 13, "api": {"routes": [{"path": "/x"}], "routesDynamic": false}}
    ;

    var raw = try parseContractJson(allocator, source);
    defer raw.deinit();

    const contract = raw.rawView();
    try std.testing.expectEqual(@as(usize, 0), contract.routes.len);
    try std.testing.expect(contract.matchesRoute("GET", "/anything"));
}

test "a wrong-typed route field is rejected outright" {
    // The scanner cannot resynchronize after a type mismatch, so the whole
    // document is refused. That is the safe side: silently skipping the route
    // would empty the route table and widen the pre-filter.
    const allocator = std.testing.allocator;
    const source =
        \\{"version": 13, "api": {"routes": [{"method": "GET", "path": 7}], "routesDynamic": false}}
    ;

    try std.testing.expectError(error.InvalidJson, parseContractJson(allocator, source));
}

// ---------------------------------------------------------------------------
// Accepted tool catalog: lowering and the startup cross-check
// ---------------------------------------------------------------------------

const catalog_test_support = pcc.tool_catalog.test_support;
const closed_test_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}";

const catalog_test_entries = [_]catalog_test_support.SampleEntry{
    .{
        .name = "alpha",
        .path = "/tools/alpha",
        .input_schema = closed_test_schema,
        .output_schema = closed_test_schema,
        .max_input_bytes = 64,
    },
    .{
        .name = "beta",
        .method = "GET",
        .path = "/tools/beta",
        .input_schema = closed_test_schema,
        .output_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"ok\":{\"type\":\"boolean\"}}}",
        .max_input_bytes = 128,
    },
};

const matching_tool_summaries = [_]ToolSummary{
    .{ .name = "alpha", .method = "POST", .path = "/tools/alpha", .max_input_bytes = 64 },
    .{ .name = "beta", .method = "GET", .path = "/tools/beta", .max_input_bytes = 128 },
};

fn testCatalog(buf: []u8, entries: []const catalog_test_support.SampleEntry) []const u8 {
    var w = catalog_test_support.Writer{ .buf = buf };
    catalog_test_support.writeCatalog(&w, entries);
    return w.bytes();
}

fn acceptedTestAssessment() pcc.Assessment {
    return .{
        .semantic = .policy_accepted,
        .provenance = .absent,
        .grade = .trusted,
        .development_only = false,
        .rejection = null,
        .work_spent = 1,
    };
}

/// A validated contract over static tool summaries. Never deinit'd: nothing in
/// it is owned.
fn toolTestContract(tools: []const ToolSummary) ValidatedRuntimeContract {
    return validatedFromInner(.{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .tools = tools,
        .allocator = std.testing.allocator,
    });
}

test "promotion lowers the accepted tool catalog and compiles every schema" {
    var buf: [2048]u8 = undefined;
    const bytes = testCatalog(&buf, &catalog_test_entries);
    const validated = toolTestContract(&matching_tool_summaries);

    var promoted = (try promote(&validated, acceptedTestAssessment(), [_]u8{0} ** 32, bytes)) orelse
        return error.TestUnexpectedResult;
    defer promoted.deinit();

    const catalog = promoted.tool_catalog orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    const beta = catalog.find("beta") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("GET", beta.method);
    try std.testing.expectEqualStrings("/tools/beta", beta.path);
    try std.testing.expectEqual(@as(u32, 128), beta.max_input_bytes);
    // The lowered catalog borrows from its own copy, not from the caller's
    // buffer, so it outlives the section it was lowered from.
    @memset(&buf, 0);
    try std.testing.expectEqualStrings("alpha", catalog.find("alpha").?.name);
}

test "promotion refuses a contract tool list that disagrees with the accepted catalog" {
    var buf: [2048]u8 = undefined;
    const bytes = testCatalog(&buf, &catalog_test_entries);

    const Case = struct { label: []const u8, tools: []const ToolSummary };
    const cases = [_]Case{
        .{ .label = "method", .tools = &.{
            .{ .name = "alpha", .method = "PUT", .path = "/tools/alpha", .max_input_bytes = 64 },
            matching_tool_summaries[1],
        } },
        .{ .label = "path", .tools = &.{
            .{ .name = "alpha", .method = "POST", .path = "/tools/other", .max_input_bytes = 64 },
            matching_tool_summaries[1],
        } },
        .{ .label = "byte bound", .tools = &.{
            .{ .name = "alpha", .method = "POST", .path = "/tools/alpha", .max_input_bytes = 65 },
            matching_tool_summaries[1],
        } },
        .{ .label = "missing name", .tools = matching_tool_summaries[0..1] },
        .{ .label = "extra name", .tools = &.{
            matching_tool_summaries[0],
            matching_tool_summaries[1],
            .{ .name = "gamma", .method = "POST", .path = "/tools/gamma", .max_input_bytes = 1 },
        } },
        .{ .label = "renamed", .tools = &.{
            .{ .name = "alpha2", .method = "POST", .path = "/tools/alpha", .max_input_bytes = 64 },
            matching_tool_summaries[1],
        } },
        // Equal counts, and every contract name is found in the catalog: only
        // the reverse direction sees that beta is not in the contract.
        .{ .label = "repeated name", .tools = &.{ matching_tool_summaries[0], matching_tool_summaries[0] } },
        .{ .label = "no tools", .tools = &.{} },
    };
    for (cases) |case| {
        const validated = toolTestContract(case.tools);
        const result = promote(&validated, acceptedTestAssessment(), [_]u8{0} ** 32, bytes);
        std.testing.expectError(error.ToolCatalogContractMismatch, result) catch |err| {
            std.debug.print("case '{s}' was not refused as a mismatch\n", .{case.label});
            return err;
        };
    }
}

test "promotion refuses a contract listing tools when no catalog was accepted" {
    const validated = toolTestContract(&matching_tool_summaries);
    try std.testing.expectError(
        error.ToolCatalogMissing,
        promote(&validated, acceptedTestAssessment(), [_]u8{0} ** 32, null),
    );

    // No tools and no catalog is an ordinary handler, promoted with none.
    const plain = toolTestContract(&.{});
    var promoted = (try promote(&plain, acceptedTestAssessment(), [_]u8{0} ** 32, null)) orelse
        return error.TestUnexpectedResult;
    defer promoted.deinit();
    try std.testing.expect(promoted.tool_catalog == null);
}

test "promotion refuses an accepted catalog it cannot decode or compile" {
    const validated = toolTestContract(&.{
        .{ .name = "echo", .method = "POST", .path = "/tools/echo", .max_input_bytes = 4096 },
        .{ .name = "lookup", .method = "GET", .path = "/tools/lookup", .max_input_bytes = 1048576 },
    });

    // The kernel sample carries `{"type":"object"}`, which is not closed and
    // so is outside the subset. The kernel does not check the subset; this does.
    var buf: [2048]u8 = undefined;
    try std.testing.expectError(
        error.ToolSchemaNotCompilable,
        promote(&validated, acceptedTestAssessment(), [_]u8{0} ** 32, catalog_test_support.sample(&buf)),
    );

    try std.testing.expectError(
        error.AcceptedToolCatalogUndecodable,
        promote(&validated, acceptedTestAssessment(), [_]u8{0} ** 32, "not a catalog"),
    );
}

test "promotion reads no catalog for an assessment short of acceptance" {
    const validated = toolTestContract(&matching_tool_summaries);
    var refused = acceptedTestAssessment();
    refused.semantic = .integrity_verified;
    refused.grade = null;
    try std.testing.expect((try promote(&validated, refused, [_]u8{0} ** 32, "not a catalog")) == null);
}

test "fromHandlerContract lowers the tool list with an uppercase method" {
    const allocator = std.testing.allocator;
    var hc = zq.handler_contract.emptyContract(try allocator.dupe(u8, "tool.ts"));
    defer hc.deinit(allocator);
    var entry = zq.handler_contract.ToolEntry{
        .name = try allocator.dupe(u8, "ping"),
        .route = try allocator.dupe(u8, "post /tools/ping"),
        .description = try allocator.dupe(u8, "Ping."),
        .input_schema_name = try allocator.dupe(u8, "In"),
        .input_schema_json = try allocator.dupe(u8, closed_test_schema),
        .output_schema_name = try allocator.dupe(u8, "Out"),
        .output_schema_json = try allocator.dupe(u8, closed_test_schema),
        .max_input_bytes = 256,
    };
    hc.tools.append(allocator, entry) catch |err| {
        entry.deinit(allocator);
        return err;
    };

    var raw = try fromHandlerContract(allocator, &hc);
    defer raw.deinit();
    const tools = raw.rawView().tools;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("ping", tools[0].name);
    try std.testing.expectEqualStrings("POST", tools[0].method);
    try std.testing.expectEqualStrings("/tools/ping", tools[0].path);
    try std.testing.expectEqual(@as(u32, 256), tools[0].max_input_bytes);
}

test "the dev catalog lowers the producer's tools with the accepted code and matches routes like routerMatch" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?AcceptedCatalog, null), try lowerProducerToolCatalog(allocator, &.{}));

    var entry = zq.handler_contract.ToolEntry{
        .name = &.{},
        .route = &.{},
        .description = &.{},
        .input_schema_name = &.{},
        .input_schema_json = &.{},
        .output_schema_name = &.{},
        .output_schema_json = &.{},
        .max_input_bytes = 32,
    };
    defer entry.deinit(allocator);
    entry.name = try allocator.dupe(u8, "order");
    entry.route = try allocator.dupe(u8, "post /orders/:id");
    entry.description = try allocator.dupe(u8, "Read one order.");
    entry.input_schema_name = try allocator.dupe(u8, "In");
    entry.input_schema_json = try allocator.dupe(u8, "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}");
    entry.output_schema_name = try allocator.dupe(u8, "Out");
    entry.output_schema_json = try allocator.dupe(u8, "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}");

    var catalog = (try lowerProducerToolCatalog(allocator, &.{entry})) orelse return error.TestExpectedCatalog;
    defer catalog.deinit();
    const tool = catalog.match("POST", "/orders/42") orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("order", tool.name);
    try std.testing.expectEqual(@as(u32, 32), tool.max_input_bytes);
    try std.testing.expect(catalog.match("post", "/orders/7") != null);
    try std.testing.expect(catalog.match("GET", "/orders/42") == null);
    try std.testing.expect(catalog.match("POST", "/orders") == null);

    const verdict = try validateToolInput(allocator, tool, "{\"x\":1}");
    try std.testing.expect(verdict == .refused and verdict.refused.reason == .unknown_field);
}
