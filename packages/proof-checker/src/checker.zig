//! The acceptance kernel.
//!
//! Everything here is work the consumer does for itself. It reads the
//! certificate as data, recomputes what the certificate claims, and compares.
//! It never reads a producer verdict, never touches the filesystem, the clock,
//! the network, or a signer, and never allocates.

const std = @import("std");

const capability_policy = @import("capability_policy.zig");
const cert_mod = @import("certificate.zig");
const declaration = @import("declaration.zig");
const graph = @import("executable_graph.zig");
const invariant = @import("invariant.zig");
const limits_mod = @import("limits.zig");
const policy_mod = @import("policy.zig");
const ps = @import("proof_system.zig");
const residual = @import("residual.zig");
const tool_catalog = @import("tool_catalog.zig");
const verdict = @import("verdict.zig");

const Assessment = verdict.Assessment;
const Budget = limits_mod.Budget;
const Policy = policy_mod.Policy;
const Rejection = verdict.Rejection;
const SemanticState = verdict.SemanticState;

/// Scratch the kernel borrows for the totality fold.
///
/// The kernel allocates nothing, so the one array it needs - a bit per proof-IR
/// node - comes from the caller. Sizing it here rather than putting it on the
/// stack keeps the acceptance path off a large frame in whatever thread the
/// server happens to run startup on.
pub fn scratchBytes(limits: limits_mod.Limits) usize {
    return irBitBytes(limits) * 3 + depthBytes(limits) + rangeStackBytes(limits);
}

fn irBitBytes(limits: limits_mod.Limits) usize {
    return (@as(usize, limits.max_ir_nodes) + 7) / 8;
}

fn depthBytes(limits: limits_mod.Limits) usize {
    return @as(usize, limits.max_ir_nodes) * @sizeOf(u16);
}

fn rangeStackBytes(limits: limits_mod.Limits) usize {
    return @as(usize, limits.max_witnesses) * @sizeOf(u64);
}

const BitSet = struct {
    bytes: []u8,

    fn init(bytes: []u8) BitSet {
        @memset(bytes, 0);
        return .{ .bytes = bytes };
    }

    fn get(self: BitSet, index: u32) bool {
        const byte = index / 8;
        if (byte >= self.bytes.len) return false;
        return (self.bytes[byte] >> @intCast(index % 8)) & 1 == 1;
    }

    fn set(self: BitSet, index: u32, value: bool) void {
        const byte = index / 8;
        if (byte >= self.bytes.len) return;
        const mask = @as(u8, 1) << @intCast(index % 8);
        if (value) {
            self.bytes[byte] |= mask;
        } else {
            self.bytes[byte] &= ~mask;
        }
    }
};

const DepthTable = struct {
    bytes: []u8,

    fn get(self: DepthTable, index: u32) u16 {
        const start = @as(usize, index) * @sizeOf(u16);
        return std.mem.readInt(u16, self.bytes[start..][0..2], .little);
    }

    fn set(self: DepthTable, index: u32, value: u16) void {
        const start = @as(usize, index) * @sizeOf(u16);
        std.mem.writeInt(u16, self.bytes[start..][0..2], value, .little);
    }
};

const RangeStack = struct {
    bytes: []u8,
    len: u32 = 0,

    fn reset(self: *RangeStack) void {
        self.len = 0;
    }

    fn last(self: RangeStack) ?u64 {
        if (self.len == 0) return null;
        const start = @as(usize, self.len - 1) * @sizeOf(u64);
        return std.mem.readInt(u64, self.bytes[start..][0..8], .little);
    }

    fn pop(self: *RangeStack) void {
        std.debug.assert(self.len > 0);
        self.len -= 1;
    }

    fn push(self: *RangeStack, value: u64) void {
        const start = @as(usize, self.len) * @sizeOf(u64);
        std.mem.writeInt(u64, self.bytes[start..][0..8], value, .little);
        self.len += 1;
    }
};

pub const Inputs = struct {
    /// The certificate bytes, exactly as they were embedded or fetched.
    certificate: []const u8,
    /// The executable-graph inventory the consumer recomputed from the artifact
    /// it holds. Not the producer's list: the point of the comparison is that
    /// these two were derived independently.
    observed_graph: []const graph.Member,
    /// What a separate provenance check established, if one ran. Provenance is
    /// carried through so a caller can report it, and it never raises or lowers
    /// a semantic state.
    provenance: verdict.ProvenanceState = .absent,
    /// At least `scratchBytes(policy.limits)` bytes the kernel may use for the
    /// duration of the call. It reads nothing out of them and leaves nothing in
    /// them that matters.
    scratch: []u8,
    /// One entry per query in the certificate's solver section: whether an
    /// isolated solver, run by the caller outside this kernel, discharged it.
    ///
    /// The kernel runs no solver: it has no process, no clock, and no I/O. It
    /// consumes the answer instead, and an answer it was not given is not a
    /// yes. A shorter slice than the certificate's solver section therefore
    /// refuses those edges rather than assuming them, which is what makes a
    /// missing adapter fail closed instead of silently permissive.
    solver_results: []const bool = &.{},
    /// The exact serialized runtime capability policy this artifact was built
    /// against, when the caller has it.
    ///
    /// Separate from `Policy` on purpose. `Policy` is the consumer's question -
    /// which properties, at which grades. This is the resource authority: which
    /// environment key, endpoint, namespace, or query name a guarded operation
    /// may reach. Conflating them would let a permissive acceptance policy
    /// widen a resource allowlist. The kernel recomputes the digest from these
    /// bytes and decodes them itself; bytes are required, and a digest without
    /// bytes proves only that two sides hashed the same blob.
    runtime_policy: ?RuntimeCapabilityPolicyInput = null,
    /// Exact canonical invariant specification bytes supplied by the
    /// deployment artifact. The checker decodes and hashes them itself.
    invariant_spec: ?[]const u8 = null,
    /// Ledger calls decoded independently from final bytecode by the loader.
    observed_invariant_operations: []const invariant.ObservedOperation = &.{},
    /// Exact canonical `ZTCAT1` tool catalog bytes supplied by the deployment
    /// artifact, when the handler has a tool catalog. The checker decodes and
    /// hashes them itself and requires the one graph member that names them.
    tool_catalog: ?[]const u8 = null,
    /// Exact canonical `ZTDCL1` declaration bytes supplied by the deployment
    /// artifact, when the handler carries a declaration. The checker decodes
    /// and hashes them itself and requires the one graph member that names
    /// them.
    declaration: ?[]const u8 = null,
};

pub const RuntimeCapabilityPolicyInput = struct {
    bytes: []const u8,
};

fn rejectAt(
    state: SemanticState,
    provenance: verdict.ProvenanceState,
    budget: Budget,
    limits: limits_mod.Limits,
    rejection: Rejection,
) Assessment {
    return Assessment.reject(state, provenance, rejection, budget.spent(limits));
}

/// Run semantic acceptance over one certificate and one recomputed inventory.
pub fn check(inputs: Inputs, policy: Policy) Assessment {
    var budget = Budget.init(policy.limits);
    const limits = policy.limits;

    policy.validate() catch |err| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .policy,
            .code = switch (err) {
                error.EmptyRequirementSet => .policy_requires_nothing,
                error.EmptyProofSystemSet,
                error.EmptySchemaVersionSet,
                error.DuplicateRequirement,
                => .proof_system_not_selected,
                error.EmptyEpochSet => .semantics_epoch_not_selected,
            },
            .recertifiable = false,
        });
    };

    const certificate = cert_mod.decodeAccepting(
        inputs.certificate,
        policy.schema_versions,
        limits,
        &budget,
    ) catch |err| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = if (err == error.WorkBudgetExhausted) .limits else .decode,
            .code = cert_mod.reasonFor(err),
            .recertifiable = true,
        });
    };

    if (!policy.acceptsProofSystem(certificate.proof_system)) {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .proof_system_identity,
            .code = .unsupported_proof_system,
            .actual = .{ .scalar = @intFromEnum(certificate.proof_system) },
            .recertifiable = true,
        });
    }
    if (!policy.acceptsEpoch(certificate.semantics_epoch)) {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .proof_system_identity,
            .code = .unsupported_semantics_epoch,
            .actual = .{ .scalar = certificate.semantics_epoch },
            .recertifiable = true,
        });
    }

    const certificate_digest = cert_mod.commitmentDigest(inputs.certificate, certificate) catch |err| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, .{
            .stage = .decode,
            .code = cert_mod.reasonFor(err),
            .recertifiable = true,
        });
    };
    if (bindExecutableGraph(certificate, certificate_digest, inputs.observed_graph, &budget)) |rejection| {
        return rejectAt(.parsed, inputs.provenance, budget, limits, rejection);
    }

    // Everything above establishes that the certificate describes exactly the
    // artifact in hand. Nothing above establishes what the artifact does.

    if (inputs.scratch.len < scratchBytes(limits)) {
        return rejectAt(.integrity_verified, inputs.provenance, budget, limits, .{
            .stage = .limits,
            .code = .work_budget_exhausted,
            .recertifiable = false,
        });
    }

    const bit_bytes = irBitBytes(limits);
    const invariant_start = bit_bytes * 2;
    const depth_start = bit_bytes * 3;
    const range_start = depth_start + depthBytes(limits);
    var session = Session{
        .certificate = certificate,
        .runtime_policy = inputs.runtime_policy,
        .policy = policy,
        .solver_results = inputs.solver_results,
        .budget = &budget,
        .total = BitSet.init(inputs.scratch[0..bit_bytes]),
        .declared = BitSet.init(inputs.scratch[bit_bytes..invariant_start]),
        .invariant_nodes = BitSet.init(inputs.scratch[invariant_start..depth_start]),
        .depths = .{ .bytes = inputs.scratch[depth_start..range_start] },
        .active_ranges = .{ .bytes = inputs.scratch[range_start..] },
        .invariant_spec = inputs.invariant_spec,
        .observed_invariant_operations = inputs.observed_invariant_operations,
        .tool_catalog = inputs.tool_catalog,
        .declaration = inputs.declaration,
    };

    const outcome = session.run() catch |err| {
        return rejectAt(.integrity_verified, inputs.provenance, budget, limits, .{
            .stage = .limits,
            .code = switch (err) {
                error.WorkBudgetExhausted => .work_budget_exhausted,
                error.Truncated => .truncated_input,
                else => .unknown_enum_member,
            },
            .recertifiable = true,
        });
    };

    if (outcome.rejection) |rejection| {
        // A rejection that happened after grading still reports the grade the
        // consumer reached. "Checked to here, and refused for this reason" is
        // more use to an operator than a bare refusal.
        return .{
            .semantic = outcome.state,
            .provenance = inputs.provenance,
            .grade = outcome.grade,
            .development_only = certificate.identity.development,
            .rejection = rejection,
            .work_spent = budget.spent(limits),
            .guards = outcome.guards,
            .invariants = outcome.invariants,
            .properties = outcome.properties,
            .disclosed_edges = outcome.disclosed_edges,
        };
    }

    return .{
        .semantic = outcome.state,
        .provenance = inputs.provenance,
        .grade = outcome.grade,
        .development_only = certificate.identity.development,
        .rejection = null,
        .work_spent = budget.spent(limits),
        .disclosed_edges = outcome.disclosed_edges,
        .properties = outcome.properties,
        .guards = outcome.guards,
        .invariants = outcome.invariants,
    };
}

const Outcome = struct {
    state: SemanticState,
    grade: ?verdict.AssuranceGrade = null,
    rejection: ?Rejection = null,
    properties: verdict.PropertyVerdicts = .{},
    disclosed_edges: u32 = 0,
    guards: verdict.GuardVerdicts = .{},
    invariants: verdict.InvariantVerdicts = .{},
};

/// One acceptance run's working state.
///
/// Everything the session does is a recomputation. It walks the proof IR the
/// certificate carries, folds totality itself, checks that each rule the
/// producer cited actually applies where it said, re-relates the translation
/// witnesses, and only then asks the policy whether what it established is
/// enough.
const Session = struct {
    certificate: cert_mod.Certificate,
    runtime_policy: ?RuntimeCapabilityPolicyInput,
    policy: Policy,
    solver_results: []const bool,
    budget: *Budget,
    total: BitSet,
    declared: BitSet,
    depths: DepthTable,
    active_ranges: RangeStack,
    invariant_nodes: BitSet,
    invariant_spec: ?[]const u8,
    observed_invariant_operations: []const invariant.ObservedOperation,
    tool_catalog: ?[]const u8,
    declaration: ?[]const u8,

    const SessionError = cert_mod.DecodeError;

    fn reject(stage: verdict.Stage, code: verdict.ReasonCode, subject: verdict.Subject) Outcome {
        return .{
            .state = .integrity_verified,
            .rejection = .{
                .stage = stage,
                .code = code,
                .subject = subject,
                .recertifiable = code != .fabricated_property,
            },
        };
    }

    fn run(self: *Session) SessionError!Outcome {
        // The proof IR is a graph member, so its root is already bound to the
        // artifact. Recomputing it here is what ties the section the checker is
        // about to walk to that commitment.
        const recomputed = try cert_mod.irRootFromTable(self.certificate.ir);
        if (!std.mem.eql(u8, &recomputed, &self.certificate.identity.ir_root)) {
            return reject(.artifact_binding, .proof_ir_digest_mismatch, .none);
        }

        if (try self.checkIrShape()) |rejection| return rejection;
        if (try self.checkObligationSet()) |rejection| return rejection;

        try self.markDeclared();
        try self.foldTotality();

        if (try self.checkTranslation()) |rejection| return rejection;

        const invariants = switch (try self.checkInvariantCoverage()) {
            .rejected => |outcome| return outcome,
            .covered => |covered| covered,
        };

        if (try self.checkToolCatalog()) |rejection| return rejection;
        if (try self.checkDeclaration()) |rejection| return rejection;

        const guards = switch (try self.checkGuardCoverage()) {
            .rejected => |outcome| return outcome,
            .covered => |verdicts| verdicts,
        };

        var outcome = try self.checkEvidence();
        outcome.guards = guards;
        outcome.invariants = invariants;
        return outcome;
    }

    /// Relate the supplied `ZTCAT1` bytes to the one `tool_catalog` graph
    /// member. The member's digest is already bound to the executable root;
    /// this stage is what ties it to bytes the kernel decoded itself.
    ///
    /// Bytes with no member, and a member with no bytes, are both refused: a
    /// catalog the graph does not commit to is not accepted, and a commitment
    /// to a catalog nobody supplied cannot be checked.
    fn checkToolCatalog(self: *Session) SessionError!?Outcome {
        const bytes = self.tool_catalog orelse {
            var graph_index: u32 = 0;
            while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
                try self.budget.spend(1);
                const member = try self.certificate.graph.get(graph_index);
                if (member.kind == .tool_catalog) {
                    return reject(.tool_catalog, .tool_catalog_member_missing, memberSubject(member));
                }
            }
            return null;
        };

        _ = tool_catalog.decode(bytes) catch
            return reject(.tool_catalog, .tool_catalog_undecodable, .none);
        const catalog_digest = tool_catalog.digest(bytes);

        var members: u32 = 0;
        var graph_index: u32 = 0;
        while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
            try self.budget.spend(1);
            const member = try self.certificate.graph.get(graph_index);
            if (member.kind != .tool_catalog) continue;
            members += 1;
            // The graph refuses a duplicate (kind, ordinal) at binding, so a
            // second catalog member carries a nonzero ordinal and is refused
            // here rather than counted.
            if (member.ordinal != 0 or !std.mem.eql(u8, &member.digest, &catalog_digest)) {
                return .{ .state = .integrity_verified, .rejection = .{
                    .stage = .tool_catalog,
                    .code = .tool_catalog_digest_mismatch,
                    .subject = memberSubject(member),
                    .expected = .{ .digest = member.digest },
                    .actual = .{ .digest = catalog_digest },
                    .recertifiable = true,
                } };
            }
        }
        if (members != 1) {
            return reject(.tool_catalog, .tool_catalog_member_missing, .none);
        }
        return null;
    }

    /// Relate the supplied `ZTDCL1` bytes to the one `declaration` graph
    /// member, as `checkToolCatalog` does for the catalog. The member's
    /// digest is already bound to the executable root; this stage ties it to
    /// bytes the kernel decoded itself.
    ///
    /// Bytes with no member, and a member with no bytes, are both refused: a
    /// declaration the graph does not commit to is not accepted, and a
    /// commitment to a declaration nobody supplied cannot be checked.
    fn checkDeclaration(self: *Session) SessionError!?Outcome {
        const bytes = self.declaration orelse {
            var graph_index: u32 = 0;
            while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
                try self.budget.spend(1);
                const member = try self.certificate.graph.get(graph_index);
                if (member.kind == .declaration) {
                    return reject(.declaration, .declaration_member_missing, memberSubject(member));
                }
            }
            return null;
        };

        _ = declaration.decode(bytes) catch
            return reject(.declaration, .declaration_undecodable, .none);
        const declaration_digest = declaration.digest(bytes);

        var members: u32 = 0;
        var graph_index: u32 = 0;
        while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
            try self.budget.spend(1);
            const member = try self.certificate.graph.get(graph_index);
            if (member.kind != .declaration) continue;
            members += 1;
            // The graph refuses a duplicate (kind, ordinal) at binding, so a
            // second declaration member carries a nonzero ordinal and is
            // refused here rather than counted.
            if (member.ordinal != 0 or !std.mem.eql(u8, &member.digest, &declaration_digest)) {
                return .{ .state = .integrity_verified, .rejection = .{
                    .stage = .declaration,
                    .code = .declaration_digest_mismatch,
                    .subject = memberSubject(member),
                    .expected = .{ .digest = member.digest },
                    .actual = .{ .digest = declaration_digest },
                    .recertifiable = true,
                } };
            }
        }
        if (members != 1) {
            return reject(.declaration, .declaration_member_missing, .none);
        }
        return null;
    }

    const InvariantOutcome = union(enum) {
        covered: verdict.InvariantVerdicts,
        rejected: Outcome,
    };

    /// Relate the structured specification, proof IR, translation witnesses,
    /// and independently decoded final-bytecode ledger calls.
    fn checkInvariantCoverage(self: *Session) SessionError!InvariantOutcome {
        const zero = [_]u8{0} ** 32;
        const declared_digest = self.certificate.identity.invariant_spec_digest;
        const configured = !std.mem.eql(u8, &declared_digest, &zero);

        if (!configured) {
            if (self.invariant_spec != null) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_spec_digest_mismatch, .none) };
            }
            if (self.certificate.invariants.len() != 0 or self.observed_invariant_operations.len != 0) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_spec_missing, .none) };
            }
            var graph_index: u32 = 0;
            while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
                try self.budget.spend(1);
                const member = try self.certificate.graph.get(graph_index);
                if (member.kind == .invariant_spec or member.kind == .invariant_ledger_adapter) {
                    return .{ .rejected = reject(.invariant_coverage, .invariant_spec_missing, .{
                        .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal },
                    }) };
                }
            }
            var node_index: u32 = 0;
            while (node_index < self.certificate.ir.len()) : (node_index += 1) {
                try self.budget.spend(1);
                if ((try self.certificate.ir.get(node_index)).tag == .ledger_call) {
                    return .{ .rejected = reject(.invariant_coverage, .invariant_spec_missing, .{ .ir_node = node_index }) };
                }
            }
            return .{ .covered = .{} };
        }

        const spec_bytes = self.invariant_spec orelse
            return .{ .rejected = reject(.invariant_coverage, .invariant_spec_missing, .none) };
        const spec = invariant.decode(spec_bytes) catch
            return .{ .rejected = reject(.invariant_coverage, .invariant_spec_undecodable, .none) };
        const spec_digest = invariant.digest(spec_bytes);
        if (!std.mem.eql(u8, &spec_digest, &declared_digest)) {
            return .{ .rejected = .{ .state = .integrity_verified, .rejection = .{
                .stage = .invariant_coverage,
                .code = .invariant_spec_digest_mismatch,
                .expected = .{ .digest = declared_digest },
                .actual = .{ .digest = spec_digest },
                .recertifiable = true,
            } } };
        }

        var spec_members: u32 = 0;
        var adapter_members: u32 = 0;
        const adapter_digest = invariant.adapterDigest();
        var graph_index: u32 = 0;
        while (graph_index < self.certificate.graph.len()) : (graph_index += 1) {
            try self.budget.spend(1);
            const member = try self.certificate.graph.get(graph_index);
            switch (member.kind) {
                .invariant_spec => {
                    spec_members += 1;
                    if (member.ordinal != 0 or !std.mem.eql(u8, &member.digest, &spec_digest)) {
                        return .{ .rejected = reject(.invariant_coverage, .invariant_spec_digest_mismatch, .{
                            .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal },
                        }) };
                    }
                },
                .invariant_ledger_adapter => {
                    adapter_members += 1;
                    if (member.ordinal != 0 or !std.mem.eql(u8, &member.digest, &adapter_digest)) {
                        return .{ .rejected = reject(.invariant_coverage, .invariant_adapter_identity_mismatch, .{
                            .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal },
                        }) };
                    }
                },
                // exhaustive: this walk counts the two invariant members and
                // nothing else. A kind the arms above do not name increments
                // neither counter, and both counters are then required to be
                // exactly 1 below, so skipping a kind here cannot turn a
                // missing or duplicated invariant member into coverage. The
                // digest of every other kind is checked by the graph walk that
                // verified integrity before this stage runs.
                else => {},
            }
        }
        if (spec_members != 1) {
            return .{ .rejected = reject(.invariant_coverage, .invariant_spec_member_missing, .none) };
        }
        if (adapter_members != 1) {
            return .{ .rejected = reject(.invariant_coverage, .invariant_adapter_member_missing, .none) };
        }
        if (self.certificate.invariants.len() == 0 and self.observed_invariant_operations.len == 0) {
            return .{ .rejected = reject(.invariant_coverage, .invariant_operation_required, .none) };
        }
        if (self.observed_invariant_operations.len > self.policy.limits.max_invariant_operations) {
            return .{ .rejected = reject(.limits, .work_budget_exhausted, .none) };
        }

        // One bit per declared kind, read through the schema-neutral kind view
        // so a schema 1 and a schema 2 document that name the same kinds
        // produce the same mask. The ordinal is bounded before it reaches the
        // shift: the catalog asserts the bound at compile time, and a mask
        // built from an out-of-range ordinal would name a kind that is not the
        // one declared.
        var kind_bits: u32 = 0;
        var kind_index: u16 = 0;
        while (kind_index < spec.kind_count) : (kind_index += 1) {
            try self.budget.spend(1);
            const declared_kind = spec.kindAt(kind_index) catch
                return .{ .rejected = reject(.invariant_coverage, .invariant_spec_undecodable, .none) };
            const ordinal = invariant.kindInfo(declared_kind).wire_ordinal;
            if (ordinal == 0 or ordinal > @bitSizeOf(u32)) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_spec_undecodable, .none) };
            }
            kind_bits |= @as(u32, 1) << @intCast(ordinal - 1);
        }

        var result = verdict.InvariantVerdicts{
            .configured = true,
            .kind_bits = kind_bits,
        };
        var previous_witness: ?cert_mod.InvariantWitness = null;
        var previous_observed: ?invariant.ObservedOperation = null;
        var index: u32 = 0;
        while (index < self.certificate.invariants.len()) : (index += 1) {
            try self.budget.spend(4);
            const supplied = try self.certificate.invariants.get(index);
            if (previous_witness) |previous| {
                switch (cert_mod.InvariantWitness.order(previous, supplied)) {
                    .lt => {},
                    .eq => return .{ .rejected = reject(.invariant_coverage, .invariant_member_duplicate, .{ .code_offset = supplied.code_offset }) },
                    .gt => return .{ .rejected = reject(.invariant_coverage, .invariant_member_out_of_order, .{ .code_offset = supplied.code_offset }) },
                }
            }
            previous_witness = supplied;

            if (index >= self.observed_invariant_operations.len) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_member_extra, .{ .code_offset = supplied.code_offset }) };
            }
            const observed = self.observed_invariant_operations[index];
            if (previous_observed) |previous| {
                if (invariant.ObservedOperation.order(previous, observed) != .lt) {
                    return .{ .rejected = reject(.invariant_coverage, .invariant_observed_mismatch, .{ .code_offset = observed.code_offset }) };
                }
            }
            previous_observed = observed;
            if (observed.function_ordinal != supplied.function_ordinal or
                observed.code_offset != supplied.code_offset or
                observed.operation != supplied.operation)
            {
                return .{ .rejected = reject(.invariant_coverage, .invariant_observed_mismatch, .{ .code_offset = supplied.code_offset }) };
            }

            if (supplied.ir_node >= self.certificate.ir.len()) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_member_extra, .{ .ir_node = supplied.ir_node }) };
            }
            const node = try self.certificate.ir.get(supplied.ir_node);
            if (node.tag != .ledger_call) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_member_extra, .{ .ir_node = supplied.ir_node }) };
            }
            if (node.aux >= invariant.catalog.len) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_operation_unknown, .{ .ir_node = supplied.ir_node }) };
            }
            if (self.invariant_nodes.get(supplied.ir_node)) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_member_duplicate, .{ .ir_node = supplied.ir_node }) };
            }
            self.invariant_nodes.set(supplied.ir_node, true);
            const expected = invariant.catalog[node.aux];
            if (supplied.operation != expected.operation) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_operation_mismatch, .{ .ir_node = supplied.ir_node }) };
            }
            if (supplied.sink != expected.sink) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_sink_mismatch, .{ .ir_node = supplied.ir_node }) };
            }
            if (supplied.impl_id != expected.impl_id) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_impl_identity_mismatch, .{ .ir_node = supplied.ir_node }) };
            }

            if (supplied.translation_index >= self.certificate.translation.len()) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_translation_missing, .{ .ir_node = supplied.ir_node }) };
            }
            const emission = try self.certificate.translation.get(supplied.translation_index);
            if (emission.kind != .emission or emission.ir_node != supplied.ir_node or
                emission.scope_ir_node != supplied.scope_ir_node or supplied.code_offset < emission.code_start or
                @as(u64, supplied.code_offset) >= @as(u64, emission.code_start) + emission.code_len)
            {
                return .{ .rejected = reject(.invariant_coverage, .invariant_translation_missing, .{ .ir_node = supplied.ir_node }) };
            }

            result.covered += 1;
            if (expected.writes) result.writes += 1;
        }
        if (self.observed_invariant_operations.len > self.certificate.invariants.len()) {
            const extra = self.observed_invariant_operations[self.certificate.invariants.len()];
            return .{ .rejected = reject(.invariant_coverage, .invariant_member_missing, .{ .code_offset = extra.code_offset }) };
        }

        var node_index: u32 = 0;
        while (node_index < self.certificate.ir.len()) : (node_index += 1) {
            try self.budget.spend(1);
            const node = try self.certificate.ir.get(node_index);
            if (node.tag != .ledger_call) continue;
            result.required += 1;
            if (node.aux >= invariant.catalog.len) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_operation_unknown, .{ .ir_node = node_index }) };
            }
            if (!self.invariant_nodes.get(node_index)) {
                return .{ .rejected = reject(.invariant_coverage, .invariant_member_missing, .{ .ir_node = node_index }) };
            }
        }
        if (!result.ready()) {
            return .{ .rejected = reject(.invariant_coverage, .invariant_member_missing, .none) };
        }
        return .{ .covered = result };
    }

    const GuardOutcome = union(enum) {
        covered: verdict.GuardVerdicts,
        rejected: Outcome,
    };

    /// Reconstruct the residual guard set from the proof IR and the consumer's
    /// own catalog, then check the certificate's list against it.
    ///
    /// The IR says where the guarded calls are and which catalog row each
    /// matches; the catalog says what a row implies. The certificate's records
    /// restate both, and a restatement that disagrees is refused. Nothing here
    /// reads a guard kind, a rule, a sink, or a policy section from the
    /// producer as an answer - only as a claim to compare.
    fn checkGuardCoverage(self: *Session) SessionError!GuardOutcome {
        var verdicts = verdict.GuardVerdicts{};

        // The plan the certificate carries must be the plan its identity names,
        // and the graph member for it - when present - must be that same digest.
        const plan_digest = try cert_mod.residualPlanDigestFromTable(self.certificate.residual);
        if (!std.mem.eql(u8, &plan_digest, &self.certificate.identity.residual_plan_digest)) {
            return .{ .rejected = reject(.guard_coverage, .residual_plan_digest_mismatch, .none) };
        }
        var member_index: u32 = 0;
        while (member_index < self.certificate.graph.len()) : (member_index += 1) {
            const member = try self.certificate.graph.get(member_index);
            if (member.kind != .residual_plan) continue;
            if (!std.mem.eql(u8, &member.digest, &plan_digest)) {
                return .{ .rejected = reject(.guard_coverage, .residual_plan_digest_mismatch, .{
                    .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal },
                }) };
            }
        }

        // Decode the resource authority once, from bytes, against the digest
        // the certificate committed to.
        var decoded: ?capability_policy.Policy = null;
        if (self.runtime_policy) |input| {
            decoded = capability_policy.decode(
                input.bytes,
                self.certificate.identity.runtime_policy_digest,
            ) catch {
                return .{ .rejected = reject(.guard_coverage, .runtime_policy_undecodable, .none) };
            };
        }

        var supplied_index: u32 = 0;
        var previous: ?cert_mod.ResidualObligation = null;
        var node_index: u32 = 0;
        while (node_index < self.certificate.ir.len()) : (node_index += 1) {
            try self.budget.spend(1);
            const node = try self.certificate.ir.get(node_index);
            if (node.tag != .capability_call) continue;

            // The IR names a catalog row. A row outside the consumer's catalog
            // is not a guarded operation the consumer knows how to cover.
            if (node.aux >= residual.catalog.len) {
                return .{ .rejected = reject(.guard_coverage, .guard_operation_unknown, .{ .ir_node = node.id }) };
            }
            const entry = residual.catalog[node.aux];
            if (!residual.enabled_families.contains(entry.kind.family())) {
                return .{ .rejected = reject(.guard_coverage, .guard_family_disabled, .{ .ir_node = node.id }) };
            }
            const expected = cert_mod.ResidualObligation{
                .kind = entry.kind,
                .normalization = entry.kind.normalization(),
                .sink = entry.kind.sink(),
                .section = entry.kind.section(),
                .impl_id = entry.impl_id,
                .operation_id = node.id,
            };
            verdicts.required += 1;
            verdicts.kinds |= @as(u8, 1) << @intCast(@intFromEnum(entry.kind) - 1);

            if (supplied_index >= self.certificate.residual.len()) {
                return .{ .rejected = reject(.guard_coverage, .guard_member_missing, .{ .ir_node = node.id }) };
            }
            const supplied = try self.certificate.residual.get(supplied_index);
            supplied_index += 1;

            if (previous) |prev| {
                switch (cert_mod.ResidualObligation.order(prev, supplied)) {
                    .lt => {},
                    .eq => return .{ .rejected = reject(.guard_coverage, .guard_member_duplicate, .{ .ir_node = supplied.operation_id }) },
                    .gt => return .{ .rejected = reject(.guard_coverage, .guard_member_out_of_order, .{ .ir_node = supplied.operation_id }) },
                }
            }
            previous = supplied;

            if (supplied.operation_id != expected.operation_id) {
                return .{ .rejected = reject(.guard_coverage, .guard_member_missing, .{ .ir_node = node.id }) };
            }
            if (supplied.kind != expected.kind) {
                return .{ .rejected = reject(.guard_coverage, .guard_kind_mismatch, .{ .ir_node = node.id }) };
            }
            if (supplied.normalization != expected.normalization) {
                return .{ .rejected = reject(.guard_coverage, .guard_normalization_mismatch, .{ .ir_node = node.id }) };
            }
            if (supplied.sink != expected.sink) {
                return .{ .rejected = reject(.guard_coverage, .guard_sink_mismatch, .{ .ir_node = node.id }) };
            }
            if (supplied.section != expected.section) {
                return .{ .rejected = reject(.guard_coverage, .guard_section_mismatch, .{ .ir_node = node.id }) };
            }
            if (supplied.impl_id != expected.impl_id) {
                return .{ .rejected = .{
                    .state = .integrity_verified,
                    .rejection = .{
                        .stage = .guard_coverage,
                        .code = .guard_impl_identity_mismatch,
                        .subject = .{ .ir_node = node.id },
                        .expected = .{ .scalar = expected.impl_id },
                        .actual = .{ .scalar = supplied.impl_id },
                        .recertifiable = true,
                    },
                } };
            }

            // A guarded operation with no configured category is not guarded.
            // An absent policy is not an empty allowlist and is not a licence.
            const policy_bytes = decoded orelse {
                return .{ .rejected = reject(.guard_coverage, .runtime_policy_missing, .{ .ir_node = node.id }) };
            };
            if (!policy_bytes.categoryEnabled(entry.kind)) {
                return .{ .rejected = reject(.guard_coverage, .guard_category_not_configured, .{ .ir_node = node.id }) };
            }

            verdicts.covered += 1;
        }

        // A record the IR never asked for is an operation the consumer did not
        // reconstruct, which means the producer is describing a program the
        // consumer cannot see.
        if (supplied_index < self.certificate.residual.len()) {
            const extra = try self.certificate.residual.get(supplied_index);
            return .{ .rejected = reject(.guard_coverage, .guard_member_extra, .{ .ir_node = extra.operation_id }) };
        }

        return .{ .covered = verdicts };
    }

    /// The IR has to be a forest of the shape the wire form promises before any
    /// fold over it means anything: ids in order, children contiguous and after
    /// their parent, parents before their children.
    fn checkIrShape(self: *Session) SessionError!?Outcome {
        const count = self.certificate.ir.len();
        if (count == 0) return reject(.evidence_check, .proof_node_unknown, .none);

        var handler_count: u32 = 0;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            try self.budget.spend(1);
            const node = try self.certificate.ir.get(index);

            if (node.id != index) return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = index });
            if (node.is_handler) {
                if (node.tag != .function) {
                    return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = index });
                }
                handler_count += 1;
            }
            if (index == 0) {
                if (node.parent != 0) return reject(.evidence_check, .proof_node_cycle, .{ .ir_node = index });
                self.depths.set(index, 1);
            } else if (node.parent >= index) {
                // A parent at or after its child is a cycle in a tree that is
                // supposed to be ordered. Refusing here is what makes the fold
                // below a single reverse sweep instead of a search.
                return reject(.evidence_check, .proof_node_cycle, .{ .ir_node = index });
            } else {
                const parent = try self.certificate.ir.get(node.parent);
                const parent_end = @as(u64, parent.first_child) + parent.child_count;
                if (index < parent.first_child or index >= parent_end) {
                    return reject(.evidence_check, .proof_node_parent_mismatch, .{ .ir_node = index });
                }
                const parent_depth = self.depths.get(node.parent);
                if (parent_depth >= self.policy.limits.max_depth) {
                    return reject(.limits, .proof_depth_exceeded, .{ .ir_node = index });
                }
                self.depths.set(index, parent_depth + 1);
            }

            if (index == 0 and self.policy.limits.max_depth < 1) {
                return reject(.limits, .proof_depth_exceeded, .{ .ir_node = index });
            }

            if (node.child_count == 0) continue;
            if (node.first_child <= index) {
                return reject(.evidence_check, .proof_node_cycle, .{ .ir_node = index });
            }
            const end = @as(u64, node.first_child) + node.child_count;
            if (end > count) return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = index });
            var child_id = node.first_child;
            while (@as(u64, child_id) < end) : (child_id += 1) {
                try self.budget.spend(1);
                const child = try self.certificate.ir.get(child_id);
                if (child.parent != index) {
                    return reject(.evidence_check, .proof_node_parent_mismatch, .{ .ir_node = child_id });
                }
            }
        }
        if (handler_count != 1) return reject(.evidence_check, .proof_node_unknown, .none);
        return null;
    }

    /// The entry function is the unique compiler-selected handler marker that
    /// participates in the proof-IR root.
    fn entryFunction(self: *Session) SessionError!?u32 {
        var index: u32 = 0;
        while (index < self.certificate.ir.len()) : (index += 1) {
            const node = try self.certificate.ir.get(index);
            if (node.is_handler) return node.id;
        }
        return null;
    }

    /// Reconstruct the obligation set and compare it, member for member, with
    /// the one the certificate supplied.
    ///
    /// The set comes from the proof system, not from the policy. A policy can
    /// raise the bar on an obligation; it must not be able to remove one,
    /// because a set a policy can shrink is a set a producer can arrange to
    /// have shrunk.
    fn checkObligationSet(self: *Session) SessionError!?Outcome {
        const entry = (try self.entryFunction()) orelse
            return reject(.obligation_reconstruction, .obligation_subject_unknown, .none);

        const expected_count = @typeInfo(ps.Property).@"enum".fields.len;
        if (self.certificate.obligations.len() != expected_count) {
            return reject(
                .obligation_reconstruction,
                if (self.certificate.obligations.len() < expected_count)
                    .obligation_missing
                else
                    .obligation_extra,
                .none,
            );
        }

        var index: u32 = 0;
        var previous: ?cert_mod.Obligation = null;
        while (index < self.certificate.obligations.len()) : (index += 1) {
            try self.budget.spend(1);
            const supplied = try self.certificate.obligations.get(index);
            if (previous) |prev| {
                switch (cert_mod.Obligation.order(prev, supplied)) {
                    .lt => {},
                    .eq => return reject(.obligation_reconstruction, .obligation_duplicate, obligationSubject(supplied)),
                    .gt => return reject(.obligation_reconstruction, .obligation_out_of_order, obligationSubject(supplied)),
                }
            }
            previous = supplied;

            const expected = reconstructed(supplied.property, entry);
            if (cert_mod.Obligation.order(expected, supplied) != .eq) {
                return reject(.obligation_reconstruction, .obligation_subject_unknown, obligationSubject(supplied));
            }
        }

        // Every property in the alphabet appears. The count and the ordering
        // above make one pass enough to say so.
        var seen = std.EnumSet(ps.Property).initEmpty();
        index = 0;
        while (index < self.certificate.obligations.len()) : (index += 1) {
            seen.insert((try self.certificate.obligations.get(index)).property);
        }
        inline for (@typeInfo(ps.Property).@"enum".fields) |field| {
            const property: ps.Property = @enumFromInt(field.value);
            if (!seen.contains(property)) {
                return reject(.obligation_reconstruction, .obligation_missing, .{ .property = property });
            }
        }
        return null;
    }

    /// Which nodes the certificate declares total rather than proving.
    ///
    /// Only a `trusted` edge on the totality obligation can declare one. A
    /// tested or solver edge cannot: those grades are about a property, not
    /// about the shape of a proof, and letting them stand in here would let a
    /// producer buy totality with a weaker word than the one it costs.
    fn markDeclared(self: *Session) SessionError!void {
        var index: u32 = 0;
        while (index < self.certificate.evidence.len()) : (index += 1) {
            try self.budget.spend(1);
            const entry = try self.certificate.evidence.get(index);
            if (entry.edge != .trusted or entry.rule != null) continue;
            const obligation = self.certificate.obligations.get(entry.obligation_index) catch continue;
            if (obligation.property != .response_total) continue;
            if (entry.node_id >= self.certificate.ir.len()) continue;
            self.declared.set(entry.node_id, true);
        }
    }

    /// The consumer's own totality fold. Children always have larger ids than
    /// their parent, so one reverse sweep settles it.
    fn foldTotality(self: *Session) SessionError!void {
        var index: u32 = self.certificate.ir.len();
        while (index > 0) {
            index -= 1;
            try self.budget.spend(1);
            const node = try self.certificate.ir.get(index);
            const value = switch (node.tag) {
                .return_node => true,
                .function => node.child_count > 0 and self.total.get(node.first_child),
                .sequence => self.anyChildTotal(node),
                .branch => node.child_count == 2 and self.allChildrenTotal(node),
                // A guarded call returns a value; it never returns a Response
                // from the handler, so it establishes no totality.
                .loop_node, .plain, .capability_call, .ledger_call => false,
            };
            self.total.set(index, value or self.declared.get(index));
        }
    }

    fn anyChildTotal(self: *Session, node: cert_mod.IrNode) bool {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (self.total.get(node.first_child + i)) return true;
        }
        return false;
    }

    fn allChildrenTotal(self: *Session, node: cert_mod.IrNode) bool {
        if (node.child_count == 0) return false;
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            if (!self.total.get(node.first_child + i)) return false;
        }
        return true;
    }

    /// The rule that closes totality at `node`, derived here rather than read.
    fn ruleAt(self: *Session, node: cert_mod.IrNode) ?ps.Rule {
        return switch (node.tag) {
            .return_node => .return_total,
            .sequence => if (self.anyChildTotal(node)) .sequence_member_total else null,
            .branch => if (node.child_count == 2 and self.allChildrenTotal(node))
                .branch_both_arms_total
            else
                null,
            .loop_node => .loop_never_total,
            .function, .plain, .capability_call, .ledger_call => null,
        };
    }

    /// Relate the proof IR to the final bytecode.
    ///
    /// Two relations are checkable from the certificate alone, and both are
    /// checked: emissions inside one function's buffer nest without partially
    /// overlapping, and every jump lands exactly on the start of the member it
    /// names. What is not checked is that the bytes at those offsets decode to
    /// the instructions the witnesses describe; that edge is disclosed as
    /// trusted rather than implied.
    fn checkTranslation(self: *Session) SessionError!?Outcome {
        const witnesses = self.certificate.translation;
        if (witnesses.len() == 0) return null;

        var previous: ?cert_mod.Witness = null;
        var active_scope: ?u32 = null;
        var index: u32 = 0;
        while (index < witnesses.len()) : (index += 1) {
            try self.budget.spend(2);
            const witness = try witnesses.get(index);
            if (previous) |prev| {
                if (cert_mod.Witness.order(prev, witness) != .lt) {
                    return reject(.translation_check, .witness_range_overlaps, .{ .code_offset = witness.code_start });
                }
            }
            previous = witness;
            if (witness.ir_node >= self.certificate.ir.len() or
                witness.target_ir >= self.certificate.ir.len() or
                witness.scope_ir_node >= self.certificate.ir.len())
            {
                return reject(.translation_check, .witness_range_out_of_bounds, .{ .ir_node = witness.ir_node });
            }
            const scope = try self.certificate.ir.get(witness.scope_ir_node);
            if (scope.tag != .function) {
                return reject(.translation_check, .witness_range_out_of_bounds, .{ .ir_node = witness.scope_ir_node });
            }

            if (witness.kind == .emission) {
                if (active_scope == null or active_scope.? != witness.scope_ir_node) {
                    self.active_ranges.reset();
                    active_scope = witness.scope_ir_node;
                }
                const start: u64 = witness.code_start;
                const end = start + witness.code_len;
                while (self.active_ranges.last()) |active_end| {
                    if (active_end > start) break;
                    self.active_ranges.pop();
                }
                if (self.active_ranges.last()) |active_end| {
                    if (end > active_end) {
                        return reject(
                            .translation_check,
                            .witness_range_overlaps,
                            .{ .code_offset = witness.code_start },
                        );
                    }
                }
                if (witness.code_len > 0) self.active_ranges.push(end);
                continue;
            }

            // A jump. Its target must be where the member it names was emitted,
            // inside the same function's buffer.
            var found = false;
            var probe: u32 = 0;
            while (probe < witnesses.len()) : (probe += 1) {
                try self.budget.spend(1);
                const candidate = try witnesses.get(probe);
                if (candidate.kind != .emission) continue;
                if (candidate.scope_ir_node != witness.scope_ir_node) continue;
                if (candidate.ir_node != witness.target_ir) continue;
                if (candidate.code_start != witness.target_offset) break;
                found = true;
                break;
            }
            if (!found) {
                return reject(
                    .translation_check,
                    .jump_target_mismatch,
                    .{ .code_offset = witness.target_offset },
                );
            }
        }

        return self.checkRewrites();
    }

    fn checkRewrites(self: *Session) SessionError!?Outcome {
        var index: u32 = 0;
        while (index < self.certificate.rewrites.len()) : (index += 1) {
            try self.budget.spend(1);
            const rewrite = try self.certificate.rewrites.get(index);
            if (rewrite.rule.family() != .translation) {
                return reject(.translation_check, .rewrite_unknown, .{ .rule = rewrite.rule });
            }
            const before: i64 = rewrite.before_len;
            const after: i64 = rewrite.after_len;
            if (after - before != rewrite.delta) {
                return reject(
                    .translation_check,
                    .rewrite_span_mismatch,
                    .{ .code_offset = rewrite.before_offset },
                );
            }
            if (rewrite.rule == .rewrite_peephole_fusion and rewrite.after_len > rewrite.before_len) {
                // A fusion that grew is not a fusion.
                return reject(
                    .translation_check,
                    .rewrite_span_mismatch,
                    .{ .code_offset = rewrite.before_offset },
                );
            }
        }
        return null;
    }

    /// Check each obligation's evidence, then grade what was established and
    /// ask the policy whether it is enough.
    fn checkEvidence(self: *Session) SessionError!Outcome {
        var grades = [_]?verdict.AssuranceGrade{null} ** (@typeInfo(ps.Property).@"enum".fields.len);
        var answered = [_]bool{false} ** grades.len;
        var refused = [_]bool{false} ** grades.len;

        var index: u32 = 0;
        while (index < self.certificate.evidence.len()) : (index += 1) {
            try self.budget.spend(2);
            const entry = try self.certificate.evidence.get(index);
            if (entry.obligation_index >= self.certificate.obligations.len()) {
                return reject(.evidence_check, .obligation_missing, .none);
            }
            const obligation = try self.certificate.obligations.get(entry.obligation_index);
            const slot = @intFromEnum(obligation.property) - 1;
            answered[slot] = true;

            if (!validEvidenceShape(entry, obligation.property)) {
                return reject(.evidence_check, .evidence_edge_invalid, .{ .property = obligation.property });
            }

            // Every edge names a node, whether or not it carries a rule. An
            // edge at a node the IR does not have states nothing.
            if (entry.node_id >= self.certificate.ir.len()) {
                return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = entry.node_id });
            }

            if (entry.edge == .not_established) {
                refused[slot] = true;
                continue;
            }

            if (entry.edge == .solver) {
                if (!self.policy.allow_solver_edges) {
                    return reject(.solver, .solver_edge_not_permitted, .{ .property = obligation.property });
                }
                // `aux` names the query in the certificate's solver section.
                if (entry.aux >= self.certificate.solver.len()) {
                    return reject(.solver, .solver_query_too_large, .{ .property = obligation.property });
                }
                const query = try self.certificate.solver.get(entry.aux);
                if (query.obligation_index != entry.obligation_index or
                    !solverKindApplies(query.query_kind, obligation.property))
                {
                    return reject(.solver, .solver_query_mismatch, .{ .property = obligation.property });
                }
                if (entry.aux >= self.solver_results.len or !self.solver_results[entry.aux]) {
                    // No answer, or an answer that was not "discharged". Both
                    // are inconclusive, and inconclusive is a rejection.
                    return reject(.solver, .solver_inconclusive, .{ .property = obligation.property });
                }
            }

            if (entry.rule) |rule| {
                const node = try self.certificate.ir.get(entry.node_id);
                switch (rule.family()) {
                    // `validEvidenceShape` already tied each family to its edge
                    // and property, so a mismatch was refused above as
                    // `evidence_edge_invalid`.
                    .totality => {
                        std.debug.assert(entry.edge == .proved and obligation.property == .response_total);
                        // The consumer derives the rule itself and compares. A
                        // producer that cites a rule which does not apply here
                        // is refused even when the fold happens to agree.
                        const derived = self.ruleAt(node) orelse
                            return reject(.evidence_check, .rule_premise_unmet, .{ .rule = rule });
                        if (derived != rule) {
                            return reject(.evidence_check, .rule_premise_unmet, .{ .rule = rule });
                        }
                    },
                    .translation => {
                        std.debug.assert(entry.edge == .translation_validated);
                        if (self.certificate.translation.len() == 0) {
                            return reject(.translation_check, .witness_missing, .{ .rule = rule });
                        }
                    },
                }
            }

            if (entry.edge == .trusted and entry.rule == null) {
                // A declared edge has to be disclosed in the trusted inventory,
                // not only used. Otherwise the certificate leans on something it
                // never wrote down.
                if (!try self.trustedEdgeDeclared(entry.node_id)) {
                    return reject(.evidence_check, .trusted_edge_undeclared, .{ .ir_node = entry.node_id });
                }
            }

            if (entry.edge.grade()) |grade| {
                grades[slot] = if (grades[slot]) |existing|
                    verdict.AssuranceGrade.weakest(existing, grade)
                else
                    grade;
            }
        }

        // The trusted inventory names theorem-chain dependencies, not inert
        // annotations. Every current trusted family supports totality, so its
        // declared grade caps that property before policy evaluation.
        const totality_slot = @intFromEnum(ps.Property.response_total) - 1;
        var has_opcode_dependency = false;
        var trusted_index: u32 = 0;
        while (trusted_index < self.certificate.trusted.len()) : (trusted_index += 1) {
            try self.budget.spend(1);
            const edge = try self.certificate.trusted.get(trusted_index);
            if (edge.grade != .trusted) {
                return reject(.evidence_check, .evidence_edge_invalid, .{ .property = .response_total });
            }
            if (edge.family == .node and edge.member_id >= self.certificate.ir.len()) {
                return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = edge.member_id });
            }
            if (edge.family == .opcode) has_opcode_dependency = true;
            grades[totality_slot] = if (grades[totality_slot]) |existing|
                verdict.AssuranceGrade.weakest(existing, edge.grade)
            else
                edge.grade;
        }
        if (self.certificate.translation.len() > 0 and !has_opcode_dependency) {
            return reject(.evidence_check, .trusted_edge_undeclared, .{ .property = .response_total });
        }

        // Totality is the one obligation the consumer settles for itself. A
        // certificate claiming it for a handler whose fold says otherwise is a
        // fabricated property, and no amount of evidence changes that.
        const entry_function = (try self.entryFunction()) orelse
            return reject(.obligation_reconstruction, .obligation_subject_unknown, .none);
        if (!refused[totality_slot] and grades[totality_slot] != null and !self.total.get(entry_function)) {
            return .{
                .state = .integrity_verified,
                .rejection = .{
                    .stage = .evidence_check,
                    .code = .fabricated_property,
                    .subject = .{ .property = .response_total },
                    .recertifiable = false,
                },
            };
        }

        var index2: usize = 0;
        while (index2 < answered.len) : (index2 += 1) {
            if (!answered[index2]) {
                const property: ps.Property = @enumFromInt(index2 + 1);
                return reject(.evidence_check, .obligation_without_evidence, .{ .property = property });
            }
        }

        // Everything above is what the consumer established. What follows is
        // whether the consumer wanted it.
        var property_verdicts: verdict.PropertyVerdicts = .{};
        inline for (@typeInfo(ps.Property).@"enum".fields) |field| {
            const property: ps.Property = @enumFromInt(field.value);
            const slot = @intFromEnum(property) - 1;
            if (grades[slot]) |grade| property_verdicts.recordGrade(property, grade);
        }
        var weakest: ?verdict.AssuranceGrade = null;
        for (self.policy.required) |requirement| {
            const slot = @intFromEnum(requirement.property) - 1;
            if (refused[slot] or grades[slot] == null) {
                return .{
                    .state = .proof_checked,
                    .rejection = .{
                        .stage = .policy,
                        .code = .required_property_not_established,
                        .subject = .{ .property = requirement.property },
                        .recertifiable = true,
                    },
                };
            }
            const grade = grades[slot].?;
            if (!grade.atLeastAsStrongAs(requirement.min_grade)) {
                return .{
                    .state = .proof_checked,
                    .rejection = .{
                        .stage = .policy,
                        .code = .grade_below_floor,
                        .subject = .{ .property = requirement.property },
                        .expected = .{ .scalar = requirement.min_grade.toWire() },
                        .actual = .{ .scalar = grade.toWire() },
                        .recertifiable = true,
                    },
                };
            }
            weakest = if (weakest) |current|
                verdict.AssuranceGrade.weakest(current, grade)
            else
                grade;
            property_verdicts.accept(requirement.property);
        }

        if (self.certificate.identity.development and !self.policy.allow_development) {
            return .{
                .state = .proof_checked,
                .grade = weakest,
                .rejection = .{
                    .stage = .policy,
                    .code = .development_artifact_refused,
                    .recertifiable = true,
                },
            };
        }

        return .{
            .state = .policy_accepted,
            .grade = weakest,
            .properties = property_verdicts,
            .disclosed_edges = try self.countDisclosedEdges(),
        };
    }

    fn countDisclosedEdges(self: *Session) SessionError!u32 {
        var count: u32 = 0;
        var index: u32 = 0;
        while (index < self.certificate.evidence.len()) : (index += 1) {
            try self.budget.spend(1);
            const entry = try self.certificate.evidence.get(index);
            if (entry.edge == .not_established or entry.edge.checked()) continue;
            const obligation = try self.certificate.obligations.get(entry.obligation_index);
            if (self.policy.requires(obligation.property)) count += 1;
        }
        if (self.policy.requires(.response_total)) count += self.certificate.trusted.len();
        return count;
    }

    fn trustedEdgeDeclared(self: *Session, node_id: u32) SessionError!bool {
        var index: u32 = 0;
        while (index < self.certificate.trusted.len()) : (index += 1) {
            try self.budget.spend(1);
            const edge = try self.certificate.trusted.get(index);
            if (edge.family == .node and @as(u32, edge.member_id) == node_id) return true;
        }
        return false;
    }
};

fn validEvidenceShape(entry: cert_mod.Evidence, property: ps.Property) bool {
    return switch (entry.edge) {
        .proved => entry.rule != null and
            entry.rule.?.family() == .totality and
            property == .response_total,
        .translation_validated => entry.rule != null and
            entry.rule.?.family() == .translation and
            property == .response_total,
        .solver, .trusted => entry.rule == null and property == .response_total,
        .tested, .not_established => entry.rule == null,
    };
}

fn solverKindApplies(kind: cert_mod.SolverQueryKind, property: ps.Property) bool {
    return switch (kind) {
        .opcode_equivalence => property == .response_total,
    };
}

fn reconstructed(property: ps.Property, entry: u32) cert_mod.Obligation {
    return if (property.subjectIsEntryFunction())
        .{ .property = property, .subject_kind = .function, .subject_id = entry }
    else
        .{ .property = property, .subject_kind = .handler, .subject_id = 0 };
}

fn obligationSubject(obligation: cert_mod.Obligation) verdict.Subject {
    return .{ .obligation = .{
        .property = obligation.property,
        .subject_id = obligation.subject_id,
    } };
}

fn bindingRejection(code: verdict.ReasonCode, subject: verdict.Subject) Rejection {
    return .{
        .stage = .artifact_binding,
        .code = code,
        .subject = subject,
        .recertifiable = true,
    };
}

fn memberSubject(member: graph.Member) verdict.Subject {
    return .{ .graph_member = .{ .kind = @intFromEnum(member.kind), .ordinal = member.ordinal } };
}

/// Recompute the root over the certificate's inventory, compare that inventory
/// member by member against the one the consumer derived from the artifact, and
/// confirm the root the certificate committed to.
///
/// Returns null when the binding holds.
fn bindExecutableGraph(
    certificate: cert_mod.Certificate,
    certificate_digest: [32]u8,
    observed: []const graph.Member,
    budget: *Budget,
) ?Rejection {
    if (std.mem.allEqual(u8, &certificate.identity.executable_root, 0)) {
        return bindingRejection(.zero_commitment, .none);
    }

    var hasher = graph.RootHasher.init(certificate.graph.len()) catch {
        return bindingRejection(.zero_commitment, .none);
    };

    var index: u32 = 0;
    var observed_index: usize = 0;
    while (index < certificate.graph.len()) : (index += 1) {
        budget.spend(2) catch return .{
            .stage = .limits,
            .code = .work_budget_exhausted,
            .recertifiable = true,
        };

        const claimed = certificate.graph.get(index) catch {
            return bindingRejection(.graph_member_missing, .{ .section = @intFromEnum(cert_mod.SectionTag.graph) });
        };

        hasher.push(claimed) catch |err| return bindingRejection(switch (err) {
            error.DuplicateMember => .graph_member_duplicate,
            else => .graph_member_out_of_order,
        }, memberSubject(claimed));

        // Advance past anything the consumer observed that the certificate does
        // not mention: extra executable bytes are the dangerous direction.
        while (observed_index < observed.len and
            graph.Member.order(observed[observed_index], claimed) == .lt)
        {
            return bindingRejection(.graph_member_extra, memberSubject(observed[observed_index]));
        }

        if (observed_index >= observed.len) {
            return bindingRejection(.graph_member_missing, memberSubject(claimed));
        }
        const seen = observed[observed_index];
        switch (graph.Member.order(seen, claimed)) {
            .gt => return bindingRejection(.graph_member_missing, memberSubject(claimed)),
            .lt => unreachable, // handled above
            .eq => {
                if (!std.mem.eql(u8, &seen.digest, &claimed.digest)) {
                    return .{
                        .stage = .artifact_binding,
                        .code = .graph_member_digest_mismatch,
                        .subject = memberSubject(claimed),
                        .expected = .{ .digest = claimed.digest },
                        .actual = .{ .digest = seen.digest },
                        .recertifiable = true,
                    };
                }
                observed_index += 1;
            },
        }
    }

    if (observed_index < observed.len) {
        return bindingRejection(.graph_member_extra, memberSubject(observed[observed_index]));
    }

    hasher.checkRequiredKinds() catch {
        return bindingRejection(.graph_member_missing, .none);
    };

    const recomputed = hasher.finish() catch {
        return bindingRejection(.zero_commitment, .none);
    };
    if (!std.mem.eql(u8, &recomputed, &certificate.identity.executable_root)) {
        return .{
            .stage = .artifact_binding,
            .code = .executable_root_mismatch,
            .expected = .{ .digest = certificate.identity.executable_root },
            .actual = .{ .digest = recomputed },
            .recertifiable = true,
        };
    }

    // The proof IR is itself a graph member, so the IR root the certificate
    // states must be the digest the inventory committed to.
    var ir_index: u32 = 0;
    while (ir_index < certificate.graph.len()) : (ir_index += 1) {
        const member = certificate.graph.get(ir_index) catch break;
        if (member.kind != .proof_ir) continue;
        if (!std.mem.eql(u8, &member.digest, &certificate.identity.ir_root)) {
            return .{
                .stage = .artifact_binding,
                .code = .proof_ir_digest_mismatch,
                .subject = memberSubject(member),
                .expected = .{ .digest = member.digest },
                .actual = .{ .digest = certificate.identity.ir_root },
                .recertifiable = true,
            };
        }
        break;
    }

    var certificate_index: u32 = 0;
    while (certificate_index < certificate.graph.len()) : (certificate_index += 1) {
        const member = certificate.graph.get(certificate_index) catch break;
        if (member.kind != .proof_certificate) continue;
        if (!std.mem.eql(u8, &member.digest, &certificate_digest)) {
            return .{
                .stage = .artifact_binding,
                .code = .proof_certificate_digest_mismatch,
                .subject = memberSubject(member),
                .expected = .{ .digest = member.digest },
                .actual = .{ .digest = certificate_digest },
                .recertifiable = true,
            };
        }
        break;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectAt(result: Assessment, stage: verdict.Stage, code: verdict.ReasonCode) !void {
    try testing.expect(result.rejection != null);
    try testing.expectEqual(stage, result.rejection.?.stage);
    try testing.expectEqual(code, result.rejection.?.code);
}

/// Bind test parts with the same public encoder and root calculation as a producer.
fn encodeBoundTestParts(buffer: []u8, source: cert_mod.Parts, members: []graph.Member) !usize {
    std.mem.sort(graph.Member, members, {}, struct {
        fn lt(_: void, a: graph.Member, b: graph.Member) bool {
            return graph.Member.order(a, b) == .lt;
        }
    }.lt);
    var parts = source;
    for (members) |*member| {
        if (member.kind == .proof_certificate) member.digest = [_]u8{0} ** 32;
    }
    parts.graph = members;
    parts.identity.executable_root = [_]u8{0} ** 32;
    const provisional = try cert_mod.encode(parts, buffer);
    var budget = Budget.init(.{});
    const decoded = try cert_mod.decode(provisional, .{}, &budget);
    const commitment = try cert_mod.commitmentDigest(provisional, decoded);
    for (members) |*member| {
        if (member.kind == .proof_certificate) member.digest = commitment;
    }
    parts.identity.executable_root = try graph.computeRoot(members);
    return (try cert_mod.encode(parts, buffer)).len;
}

pub const test_support = struct {
    pub fn digest(seed: u8) [32]u8 {
        var out: [32]u8 = undefined;
        @memset(&out, seed);
        return out;
    }

    /// A well-formed minimal artifact: one handler that always returns, its
    /// executable-graph inventory, and a certificate that reaches acceptance
    /// under the production policy.
    pub const Fixture = struct {
        members: [9]graph.Member,
        ir: [3]cert_mod.IrNode,
        obligations: [8]cert_mod.Obligation,
        evidence: [10]cert_mod.Evidence,
        witnesses: [3]cert_mod.Witness,
        rewrites: [1]cert_mod.Rewrite,
        trusted: [1]cert_mod.TrustedEdge,
        buffer: [8192]u8 = undefined,
        len: usize = 0,
        scratch: [scratch_len]u8 = undefined,

        const scratch_len = scratchBytes(.{});

        pub fn bytes(self: *const Fixture) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn graphMembers(self: *const Fixture) []const graph.Member {
            return &self.members;
        }

        pub fn parts(self: *Fixture) cert_mod.Parts {
            return .{
                .identity = .{
                    .executable_root = graph.computeRoot(&self.members) catch unreachable,
                    .ir_root = cert_mod.irRootFromNodes(&self.ir),
                    .contract_digest = digest(2),
                    .development = false,
                },
                .graph = &self.members,
                .obligations = &self.obligations,
                .ir = &self.ir,
                .evidence = &self.evidence,
                .translation = &self.witnesses,
                .rewrites = &self.rewrites,
                .trusted = &self.trusted,
            };
        }

        pub fn encode(self: *Fixture) !void {
            var members = self.members;
            std.mem.sort(graph.Member, &members, {}, struct {
                fn lt(_: void, a: graph.Member, b: graph.Member) bool {
                    return graph.Member.order(a, b) == .lt;
                }
            }.lt);
            self.members = members;
            var built = self.parts();
            built.identity.ir_root = cert_mod.irRootFromNodes(&self.ir);
            // The proof IR is a graph member, so its digest has to move with it.
            for (&self.members) |*member| {
                if (member.kind == .proof_ir) member.digest = built.identity.ir_root;
            }
            try self.encodeParts(built);
        }

        pub fn encodeParts(self: *Fixture, certificate_parts: cert_mod.Parts) !void {
            var built = certificate_parts;
            for (&self.members) |*member| {
                if (member.kind == .proof_certificate) member.digest = [_]u8{0} ** 32;
            }
            built.identity.executable_root = [_]u8{0} ** 32;
            const provisional = try cert_mod.encode(built, &self.buffer);
            var budget = Budget.init(.{});
            const decoded = try cert_mod.decode(provisional, .{}, &budget);
            const certificate_digest = try cert_mod.commitmentDigest(provisional, decoded);
            for (&self.members) |*member| {
                if (member.kind == .proof_certificate) member.digest = certificate_digest;
            }
            built.identity.executable_root = try graph.computeRoot(&self.members);
            const encoded = try cert_mod.encode(built, &self.buffer);
            self.len = encoded.len;
        }

        pub fn inputs(self: *Fixture) Inputs {
            return .{
                .certificate = self.bytes(),
                .observed_graph = self.graphMembers(),
                .scratch = &self.scratch,
            };
        }
    };

    /// A handler with one guarded environment read.
    ///
    /// The proof IR carries the guarded call, the certificate carries one
    /// residual obligation for it, and the serialized policy configures the env
    /// category. Every adversarial test below starts here and changes one thing.
    pub const GuardedFixture = struct {
        members: [10]graph.Member,
        ir: [4]cert_mod.IrNode,
        obligations: [8]cert_mod.Obligation,
        evidence: [10]cert_mod.Evidence,
        residual_plan: [1]cert_mod.ResidualObligation,
        buffer: [8192]u8 = undefined,
        len: usize = 0,
        policy_bytes: [256]u8 = undefined,
        policy_len: usize = 0,
        scratch: [Fixture.scratch_len]u8 = undefined,

        pub fn bytes(self: *const GuardedFixture) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn policySlice(self: *const GuardedFixture) []const u8 {
            return self.policy_bytes[0..self.policy_len];
        }

        pub fn policyDigest(self: *const GuardedFixture) [32]u8 {
            var out: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(self.policySlice(), &out, .{});
            return out;
        }

        /// Serialize an env-only capability policy with one allowed key.
        pub fn writePolicy(self: *GuardedFixture, entries: []const []const u8) void {
            var at: usize = 0;
            self.policy_bytes[at] = 1;
            at += 1;
            std.mem.writeInt(u16, self.policy_bytes[at..][0..2], @intCast(entries.len), .little);
            at += 2;
            for (entries) |entry| {
                std.mem.writeInt(u16, self.policy_bytes[at..][0..2], @intCast(entry.len), .little);
                at += 2;
                @memcpy(self.policy_bytes[at..][0..entry.len], entry);
                at += entry.len;
            }
            // Three unconfigured categories and no permitted address scope.
            for (0..3) |section| {
                self.policy_bytes[at] = 0;
                at += 1;
                std.mem.writeInt(u16, self.policy_bytes[at..][0..2], 0, .little);
                at += 2;
                _ = section;
            }
            self.policy_bytes[at] = 0;
            at += 1;
            self.policy_len = at;
        }

        /// Serialize a valid SQL-only policy. The read/write tag makes this a
        /// stronger negative than an absent policy: every supplied byte would
        /// cover the SQL row if the independent family gate were missing.
        pub fn writeSqlPolicy(self: *GuardedFixture, name: []const u8, read_only: bool) void {
            var at: usize = 0;
            for (0..3) |_| {
                self.policy_bytes[at] = 0;
                at += 1;
                std.mem.writeInt(u16, self.policy_bytes[at..][0..2], 0, .little);
                at += 2;
            }
            self.policy_bytes[at] = 1;
            at += 1;
            std.mem.writeInt(u16, self.policy_bytes[at..][0..2], 1, .little);
            at += 2;
            self.policy_bytes[at] = if (read_only) 1 else 0;
            at += 1;
            std.mem.writeInt(u16, self.policy_bytes[at..][0..2], @intCast(name.len), .little);
            at += 2;
            @memcpy(self.policy_bytes[at..][0..name.len], name);
            at += name.len;
            self.policy_bytes[at] = 0;
            at += 1;
            self.policy_len = at;
        }

        pub fn parts(self: *GuardedFixture) cert_mod.Parts {
            return .{
                .identity = .{
                    .executable_root = [_]u8{0} ** 32,
                    .ir_root = cert_mod.irRootFromNodes(&self.ir),
                    .contract_digest = digest(2),
                    .residual_plan_digest = cert_mod.residualPlanDigest(&self.residual_plan),
                    .runtime_policy_digest = self.policyDigest(),
                    .development = false,
                },
                .graph = &self.members,
                .obligations = &self.obligations,
                .ir = &self.ir,
                .evidence = &self.evidence,
                .residual = &self.residual_plan,
            };
        }

        pub fn encode(self: *GuardedFixture) !void {
            std.mem.sort(graph.Member, &self.members, {}, struct {
                fn lt(_: void, a: graph.Member, b: graph.Member) bool {
                    return graph.Member.order(a, b) == .lt;
                }
            }.lt);
            var built = self.parts();
            for (&self.members) |*member| {
                switch (member.kind) {
                    .proof_ir => member.digest = built.identity.ir_root,
                    .residual_plan => member.digest = built.identity.residual_plan_digest,
                    .runtime_policy_bytes => member.digest = built.identity.runtime_policy_digest,
                    .proof_certificate => member.digest = [_]u8{0} ** 32,
                    // exhaustive: the arms above are the members whose digest
                    // this rebuild owns - each is a fold over bytes just
                    // recomputed here. Every other kind carries a digest taken
                    // from the artifact, and overwriting one would replace
                    // observed bytes with a restated claim.
                    else => {},
                }
            }
            built.identity.executable_root = [_]u8{0} ** 32;
            built.graph = &self.members;
            const provisional = try cert_mod.encode(built, &self.buffer);
            var budget = Budget.init(.{});
            const decoded = try cert_mod.decode(provisional, .{}, &budget);
            const certificate_digest = try cert_mod.commitmentDigest(provisional, decoded);
            for (&self.members) |*member| {
                if (member.kind == .proof_certificate) member.digest = certificate_digest;
            }
            built.identity.executable_root = try graph.computeRoot(&self.members);
            const encoded = try cert_mod.encode(built, &self.buffer);
            self.len = encoded.len;
        }

        pub fn inputs(self: *GuardedFixture) Inputs {
            return .{
                .certificate = self.bytes(),
                .observed_graph = &self.members,
                .scratch = &self.scratch,
                .runtime_policy = .{ .bytes = self.policySlice() },
            };
        }
    };

    pub fn buildGuarded() !GuardedFixture {
        var fixture = GuardedFixture{
            .members = .{
                .{ .kind = .main_bytecode, .ordinal = 0, .digest = digest(1) },
                .{ .kind = .contract_bytes, .ordinal = 0, .digest = digest(2) },
                .{ .kind = .runtime_policy_bytes, .ordinal = 0, .digest = digest(3) },
                .{ .kind = .source_profile_core, .ordinal = 0, .digest = digest(4) },
                .{ .kind = .core_grammar, .ordinal = 0, .digest = digest(5) },
                .{ .kind = .semantics, .ordinal = 0, .digest = digest(6) },
                .{ .kind = .capability_matrix, .ordinal = 0, .digest = digest(7) },
                .{ .kind = .proof_ir, .ordinal = 0, .digest = digest(8) },
                .{ .kind = .proof_certificate, .ordinal = 0, .digest = digest(9) },
                .{ .kind = .residual_plan, .ordinal = 0, .digest = digest(10) },
            },
            // function -> sequence -> { guarded call, return }
            .ir = .{
                .{ .id = 0, .tag = .function, .is_handler = true, .parent = 0, .first_child = 1, .child_count = 1, .digest = digest(20) },
                .{ .id = 1, .tag = .sequence, .parent = 0, .first_child = 2, .child_count = 2, .digest = digest(21) },
                .{ .id = 2, .tag = .capability_call, .parent = 1, .first_child = 0, .child_count = 0, .digest = digest(22), .aux = 0 },
                .{ .id = 3, .tag = .return_node, .parent = 1, .first_child = 0, .child_count = 0, .digest = digest(23) },
            },
            .obligations = .{
                .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
                .{ .property = .results_checked, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .no_secret_leakage, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .state_isolated, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .deterministic, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .read_only, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .retry_safe, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .capability_bounded, .subject_kind = .handler, .subject_id = 0 },
            },
            .evidence = .{
                .{ .obligation_index = 0, .edge = .proved, .rule = .sequence_member_total, .node_id = 1, .aux = 0 },
                testedFor(0),
                testedFor(1),
                testedFor(2),
                testedFor(3),
                testedFor(4),
                testedFor(5),
                testedFor(6),
                testedFor(7),
                testedFor(7),
            },
            .residual_plan = .{
                .{
                    .kind = .env_key,
                    .normalization = .identifier_exact_v1,
                    .sink = .env_read,
                    .section = .env,
                    .impl_id = residual.guard_impl.env_read_v1,
                    .operation_id = 2,
                },
            },
        };
        fixture.writePolicy(&.{"API_KEY"});
        try fixture.encode();
        return fixture;
    }

    fn testedFor(index: u32) cert_mod.Evidence {
        return .{
            .obligation_index = index,
            .edge = .tested,
            .rule = null,
            .node_id = 0,
            .aux = 0,
        };
    }

    pub fn build() !Fixture {
        var fixture = Fixture{
            .members = .{
                .{ .kind = .main_bytecode, .ordinal = 0, .digest = digest(1) },
                .{ .kind = .contract_bytes, .ordinal = 0, .digest = digest(2) },
                .{ .kind = .runtime_policy_bytes, .ordinal = 0, .digest = digest(3) },
                .{ .kind = .source_profile_core, .ordinal = 0, .digest = digest(4) },
                .{ .kind = .core_grammar, .ordinal = 0, .digest = digest(5) },
                .{ .kind = .semantics, .ordinal = 0, .digest = digest(6) },
                .{ .kind = .capability_matrix, .ordinal = 0, .digest = digest(7) },
                .{ .kind = .proof_ir, .ordinal = 0, .digest = digest(8) },
                .{ .kind = .proof_certificate, .ordinal = 0, .digest = digest(9) },
            },
            // function -> sequence -> return
            .ir = .{
                .{ .id = 0, .tag = .function, .is_handler = true, .parent = 0, .first_child = 1, .child_count = 1, .digest = digest(20) },
                .{ .id = 1, .tag = .sequence, .parent = 0, .first_child = 2, .child_count = 1, .digest = digest(21) },
                .{ .id = 2, .tag = .return_node, .parent = 1, .first_child = 0, .child_count = 0, .digest = digest(22) },
            },
            .obligations = .{
                .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
                .{ .property = .results_checked, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .no_secret_leakage, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .state_isolated, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .deterministic, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .read_only, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .retry_safe, .subject_kind = .handler, .subject_id = 0 },
                .{ .property = .capability_bounded, .subject_kind = .handler, .subject_id = 0 },
            },
            .evidence = .{
                .{ .obligation_index = 0, .edge = .proved, .rule = .sequence_member_total, .node_id = 1, .aux = 0 },
                .{ .obligation_index = 0, .edge = .translation_validated, .rule = .emission_contiguous, .node_id = 0, .aux = 0 },
                .{ .obligation_index = 0, .edge = .translation_validated, .rule = .jump_target_resolved, .node_id = 0, .aux = 0 },
                testedFor(1),
                testedFor(2),
                testedFor(3),
                testedFor(4),
                testedFor(5),
                testedFor(6),
                testedFor(7),
            },
            .witnesses = .{
                .{ .ir_node = 1, .code_start = 0, .code_len = 8, .target_ir = 1, .target_offset = 0, .scope_ir_node = 0, .kind = .emission },
                .{ .ir_node = 2, .code_start = 2, .code_len = 4, .target_ir = 2, .target_offset = 2, .scope_ir_node = 0, .kind = .emission },
                .{ .ir_node = 1, .code_start = 3, .code_len = 0, .target_ir = 2, .target_offset = 2, .scope_ir_node = 0, .kind = .jump },
            },
            .rewrites = .{
                .{ .rule = .rewrite_peephole_fusion, .before_offset = 0, .before_len = 4, .after_offset = 0, .after_len = 3, .delta = -1 },
            },
            .trusted = .{
                .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
            },
        };
        try fixture.encode();
        return fixture;
    }
};

const test_invariant_spec = invariant.magic.* ++ [_]u8{
    1, 0, // schema
    1, 0, // balance_conservation_v1
    6, 0, // ledger id length
    1, 0, // currency count
} ++ "ledger" ++ "USD" ++ [_]u8{2};

/// The same ledger and currencies under wire schema 2, which names its kinds
/// in a sorted record list instead of in the header.
const test_invariant_spec_v2 = invariant.magic.* ++ [_]u8{
    2, 0, // schema
    1, 0, // declared kind count
    6, 0, // ledger id length
    1, 0, // currency count
} ++ "ledger" ++ "USD" ++ [_]u8{2} ++ [_]u8{
    1, 0, // balance_conservation_v1
    0, 0, // payload length
};

const test_invariant_account_payload = [_]u8{
    2, 0, // matcher count
    1, // exact
    13, 0, // length
} ++ "clearing:main" ++ [_]u8{
    2, // prefix
    6, 0, // length
} ++ "asset:";

/// The same ledger again, declaring both catalog kinds. Per-kind reporting has
/// nothing to say until a document declares more than one kind.
const test_invariant_spec_two_kinds = invariant.magic.* ++ [_]u8{
    2, 0, // schema
    2, 0, // declared kind count
    6, 0, // ledger id length
    1, 0, // currency count
} ++ "ledger" ++ "USD" ++ [_]u8{2} ++ [_]u8{
    1, 0, // balance_conservation_v1
    0, 0, // payload length
    2,                                  0, // declared_accounts_v1
    test_invariant_account_payload.len, 0,
} ++ test_invariant_account_payload;

const InvariantTestFixture = struct {
    members: [11]graph.Member,
    ir: [4]cert_mod.IrNode,
    obligations: [8]cert_mod.Obligation,
    evidence: [10]cert_mod.Evidence,
    translation: [3]cert_mod.Witness,
    trusted: [1]cert_mod.TrustedEdge,
    invariant_witnesses: [1]cert_mod.InvariantWitness,
    observed: [1]invariant.ObservedOperation,
    /// The specification bytes the certificate is built over and the consumer
    /// is handed. Both wire schemas run the same acceptance path.
    spec: []const u8,
    buffer: [8192]u8 = undefined,
    len: usize = 0,
    scratch: [scratchBytes(.{})]u8 = undefined,

    fn parts(self: *InvariantTestFixture, invariant_witnesses: []const cert_mod.InvariantWitness) cert_mod.Parts {
        return .{
            .identity = .{
                .executable_root = graph.computeRoot(&self.members) catch unreachable,
                .ir_root = cert_mod.irRootFromNodes(&self.ir),
                .contract_digest = test_support.digest(2),
                .invariant_spec_digest = invariant.digest(self.spec),
                .development = false,
            },
            .graph = &self.members,
            .obligations = &self.obligations,
            .ir = &self.ir,
            .evidence = &self.evidence,
            .translation = &self.translation,
            .trusted = &self.trusted,
            .invariants = invariant_witnesses,
        };
    }

    fn encodeWith(self: *InvariantTestFixture, invariant_witnesses: []const cert_mod.InvariantWitness) !void {
        for (&self.members) |*member| {
            if (member.kind == .proof_ir) member.digest = cert_mod.irRootFromNodes(&self.ir);
            if (member.kind == .proof_certificate) member.digest = [_]u8{0} ** 32;
        }
        std.mem.sort(graph.Member, &self.members, {}, struct {
            fn lessThan(_: void, a: graph.Member, b: graph.Member) bool {
                return graph.Member.order(a, b) == .lt;
            }
        }.lessThan);

        var built = self.parts(invariant_witnesses);
        built.identity.executable_root = [_]u8{0} ** 32;
        const provisional = try cert_mod.encode(built, &self.buffer);
        var budget = Budget.init(.{});
        const decoded = try cert_mod.decode(provisional, .{}, &budget);
        const certificate_digest = try cert_mod.commitmentDigest(provisional, decoded);
        for (&self.members) |*member| {
            if (member.kind == .proof_certificate) member.digest = certificate_digest;
        }
        built.graph = &self.members;
        built.identity.executable_root = try graph.computeRoot(&self.members);
        self.len = (try cert_mod.encode(built, &self.buffer)).len;
    }

    fn inputs(self: *InvariantTestFixture) Inputs {
        return .{
            .certificate = self.buffer[0..self.len],
            .observed_graph = &self.members,
            .scratch = &self.scratch,
            .invariant_spec = self.spec,
            .observed_invariant_operations = &self.observed,
        };
    }
};

fn buildInvariantFixture() !InvariantTestFixture {
    return buildInvariantFixtureFor(test_invariant_spec);
}

fn buildInvariantFixtureFor(spec: []const u8) !InvariantTestFixture {
    var fixture = InvariantTestFixture{
        .spec = spec,
        .members = .{
            .{ .kind = .main_bytecode, .ordinal = 0, .digest = test_support.digest(1) },
            .{ .kind = .contract_bytes, .ordinal = 0, .digest = test_support.digest(2) },
            .{ .kind = .runtime_policy_bytes, .ordinal = 0, .digest = test_support.digest(3) },
            .{ .kind = .source_profile_core, .ordinal = 0, .digest = test_support.digest(4) },
            .{ .kind = .core_grammar, .ordinal = 0, .digest = test_support.digest(5) },
            .{ .kind = .semantics, .ordinal = 0, .digest = test_support.digest(6) },
            .{ .kind = .capability_matrix, .ordinal = 0, .digest = test_support.digest(7) },
            .{ .kind = .proof_ir, .ordinal = 0, .digest = test_support.digest(8) },
            .{ .kind = .proof_certificate, .ordinal = 0, .digest = test_support.digest(9) },
            .{ .kind = .invariant_spec, .ordinal = 0, .digest = invariant.digest(spec) },
            .{ .kind = .invariant_ledger_adapter, .ordinal = 0, .digest = invariant.adapterDigest() },
        },
        .ir = .{
            .{ .id = 0, .tag = .function, .is_handler = true, .parent = 0, .first_child = 1, .child_count = 1, .digest = test_support.digest(20) },
            .{ .id = 1, .tag = .sequence, .parent = 0, .first_child = 2, .child_count = 2, .digest = test_support.digest(21) },
            .{ .id = 2, .tag = .ledger_call, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(22), .aux = 0 },
            .{ .id = 3, .tag = .return_node, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(23) },
        },
        .obligations = .{
            .{ .property = .response_total, .subject_kind = .function, .subject_id = 0 },
            .{ .property = .results_checked, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .no_secret_leakage, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .state_isolated, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .deterministic, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .read_only, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .retry_safe, .subject_kind = .handler, .subject_id = 0 },
            .{ .property = .capability_bounded, .subject_kind = .handler, .subject_id = 0 },
        },
        .evidence = .{
            .{ .obligation_index = 0, .edge = .proved, .rule = .sequence_member_total, .node_id = 1, .aux = 0 },
            .{ .obligation_index = 0, .edge = .translation_validated, .rule = .emission_contiguous, .node_id = 0, .aux = 0 },
            .{ .obligation_index = 0, .edge = .translation_validated, .rule = .jump_target_resolved, .node_id = 0, .aux = 0 },
            test_support.testedFor(1),
            test_support.testedFor(2),
            test_support.testedFor(3),
            test_support.testedFor(4),
            test_support.testedFor(5),
            test_support.testedFor(6),
            test_support.testedFor(7),
        },
        .translation = .{
            .{ .ir_node = 1, .code_start = 0, .code_len = 8, .target_ir = 1, .target_offset = 0, .scope_ir_node = 0, .kind = .emission },
            .{ .ir_node = 2, .code_start = 2, .code_len = 1, .target_ir = 2, .target_offset = 2, .scope_ir_node = 0, .kind = .emission },
            .{ .ir_node = 3, .code_start = 4, .code_len = 2, .target_ir = 3, .target_offset = 4, .scope_ir_node = 0, .kind = .emission },
        },
        .trusted = .{
            .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        },
        .invariant_witnesses = .{
            .{
                .ir_node = 2,
                .scope_ir_node = 0,
                .function_ordinal = 0,
                .code_offset = 2,
                .translation_index = 1,
                .operation = .post,
                .sink = .ledger_post,
                .impl_id = invariant.catalog[0].impl_id,
            },
        },
        .observed = .{
            .{ .function_ordinal = 0, .code_offset = 2, .operation = .post },
        },
    };
    try fixture.encodeWith(&fixture.invariant_witnesses);
    return fixture;
}

/// The same artifact with its one ledger call site reading a balance instead of
/// writing a posting group. Nothing else moves: the call site is still named by
/// the proof IR, still witnessed, and still independently observed.
fn buildBalanceOnlyInvariantFixtureFor(spec: []const u8) !InvariantTestFixture {
    var fixture = try buildInvariantFixtureFor(spec);
    fixture.ir[2].aux = 1;
    fixture.invariant_witnesses[0].operation = .balance;
    fixture.invariant_witnesses[0].sink = .ledger_balance;
    fixture.invariant_witnesses[0].impl_id = invariant.catalog[1].impl_id;
    fixture.observed[0].operation = .balance;
    try fixture.encodeWith(&fixture.invariant_witnesses);
    return fixture;
}

test "a configured invariant is checked independently from property and guard verdicts" {
    var fixture = try buildInvariantFixture();
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected invariant rejection: {s} / {s}\n", .{
            rejection.stage.name(),
            rejection.code.text(),
        });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
    try testing.expect(result.invariants.configured);
    try testing.expectEqual(@as(u32, 1), result.invariants.required);
    try testing.expectEqual(@as(u32, 1), result.invariants.covered);
    try testing.expectEqual(@as(u32, 1), result.invariants.writes);
    try testing.expect(result.invariants.ready());
    try testing.expectEqual(@as(u32, 1), result.invariants.kind_bits);
    try testing.expectEqual(@as(u32, 0), result.guards.required);
}

test "a schema 2 invariant specification is accepted and reports the same kind bits" {
    // The schema 2 document declares the same ledger, currencies and kinds as
    // the schema 1 one above. Acceptance and the reported mask must not depend
    // on which schema carried them, and the digest the certificate binds must
    // be the one this document hashes to under its own domain.
    var fixture = try buildInvariantFixtureFor(test_invariant_spec_v2);
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected schema 2 invariant rejection: {s} / {s}\n", .{
            rejection.stage.name(),
            rejection.code.text(),
        });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
    try testing.expect(result.invariants.configured);
    try testing.expectEqual(@as(u32, 1), result.invariants.required);
    try testing.expectEqual(@as(u32, 1), result.invariants.covered);
    try testing.expectEqual(@as(u32, 1), result.invariants.writes);
    try testing.expect(result.invariants.ready());
    try testing.expectEqual(@as(u32, 1), result.invariants.kind_bits);
}

test "a schema 2 certificate bound to the schema 1 digest of the same ledger is refused" {
    // The two schemas hash under different domains, so a certificate that
    // carries the schema 1 digest cannot stand for schema 2 bytes even when
    // both declare the same ledger, currencies and kinds.
    var fixture = try buildInvariantFixtureFor(test_invariant_spec_v2);
    var under_v1_domain = std.crypto.hash.sha2.Sha256.init(.{});
    under_v1_domain.update(invariant.digest_domain);
    under_v1_domain.update(test_invariant_spec_v2);
    const borrowed = under_v1_domain.finalResult();
    for (&fixture.members) |*member| {
        if (member.kind == .invariant_spec) member.digest = borrowed;
    }
    try fixture.encodeWith(&fixture.invariant_witnesses);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.invariant_coverage, result.rejection.?.stage);
    try testing.expectEqual(
        verdict.ReasonCode.invariant_spec_digest_mismatch,
        result.rejection.?.code,
    );
}

test "missing and extra invariant witnesses reject" {
    var missing = try buildInvariantFixture();
    try missing.encodeWith(&.{});
    var result = check(missing.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.invariant_coverage, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.invariant_member_missing, result.rejection.?.code);

    var extra = try buildInvariantFixture();
    const witnesses = [_]cert_mod.InvariantWitness{
        extra.invariant_witnesses[0],
        .{
            .ir_node = 2,
            .scope_ir_node = 0,
            .function_ordinal = 0,
            .code_offset = 3,
            .translation_index = 1,
            .operation = .post,
            .sink = .ledger_post,
            .impl_id = invariant.catalog[0].impl_id,
        },
    };
    try extra.encodeWith(&witnesses);
    result = check(extra.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.invariant_member_extra, result.rejection.?.code);
}

test "invariant call must lie within its full expression emission" {
    var fixture = try buildInvariantFixture();
    fixture.translation[1].code_len = 2;
    fixture.invariant_witnesses[0].code_offset = 3;
    fixture.observed[0].code_offset = 3;
    try fixture.encodeWith(&fixture.invariant_witnesses);
    try testing.expect(check(fixture.inputs(), policy_mod.production).accepted());

    for ([_]u32{ 1, 4 }) |offset| {
        fixture.invariant_witnesses[0].code_offset = offset;
        fixture.observed[0].code_offset = offset;
        try fixture.encodeWith(&fixture.invariant_witnesses);
        const result = check(fixture.inputs(), policy_mod.production);
        try testing.expectEqual(verdict.ReasonCode.invariant_translation_missing, result.rejection.?.code);
    }
}

test "a forged invariant operation cannot borrow a real call site" {
    var fixture = try buildInvariantFixture();
    var forged = fixture.invariant_witnesses;
    forged[0].operation = .balance;
    forged[0].sink = .ledger_balance;
    forged[0].impl_id = invariant.catalog[1].impl_id;
    fixture.observed[0].operation = .balance;
    try fixture.encodeWith(&forged);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.invariant_coverage, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.invariant_operation_mismatch, result.rejection.?.code);
}

test "a balance-only artifact is covered and reports vacuous write applicability" {
    var fixture = try buildBalanceOnlyInvariantFixtureFor(test_invariant_spec);
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected balance-only rejection: {s} / {s}\n", .{
            rejection.stage.name(),
            rejection.code.text(),
        });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
    try testing.expect(result.invariants.configured);
    try testing.expectEqual(@as(u32, 1), result.invariants.required);
    try testing.expectEqual(@as(u32, 1), result.invariants.covered);
    try testing.expectEqual(@as(u32, 0), result.invariants.writes);
    // The read call site is genuinely covered, so the artifact is ready. The
    // report says what is missing; it does not relabel readiness.
    try testing.expect(result.invariants.ready());
    try testing.expectEqual(
        verdict.WriteApplicability.vacuous,
        result.invariants.writeApplicability(),
    );
    try testing.expectEqual(
        verdict.WriteApplicability.vacuous,
        result.invariants.writeApplicabilityFor(.balance_conservation_v1),
    );
    // A kind this document does not declare is not vacuous, it is absent.
    try testing.expectEqual(
        verdict.WriteApplicability.not_applicable,
        result.invariants.writeApplicabilityFor(.declared_accounts_v1),
    );
}

test "a post-bearing artifact reports covered write applicability for every declared kind" {
    var fixture = try buildInvariantFixtureFor(test_invariant_spec_two_kinds);
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected two-kind rejection: {s} / {s}\n", .{
            rejection.stage.name(),
            rejection.code.text(),
        });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
    try testing.expectEqual(@as(u32, 1), result.invariants.writes);
    try testing.expectEqual(@as(u32, 0b11), result.invariants.kind_bits);
    try testing.expectEqual(
        verdict.WriteApplicability.covered,
        result.invariants.writeApplicability(),
    );
    try testing.expectEqual(
        verdict.WriteApplicability.covered,
        result.invariants.writeApplicabilityFor(.balance_conservation_v1),
    );
    try testing.expectEqual(
        verdict.WriteApplicability.covered,
        result.invariants.writeApplicabilityFor(.declared_accounts_v1),
    );

    // Both catalog kinds gate `post`, so per-kind applicability is degenerate:
    // the same artifact read-only reports vacuous for both, not for one.
    var read_only = try buildBalanceOnlyInvariantFixtureFor(test_invariant_spec_two_kinds);
    const read_only_result = check(read_only.inputs(), policy_mod.production);
    try testing.expect(read_only_result.accepted());
    try testing.expectEqual(
        verdict.WriteApplicability.vacuous,
        read_only_result.invariants.writeApplicabilityFor(.balance_conservation_v1),
    );
    try testing.expectEqual(
        verdict.WriteApplicability.vacuous,
        read_only_result.invariants.writeApplicabilityFor(.declared_accounts_v1),
    );
}

test "a configured artifact exhibiting no ledger operation rejects with invariant_operation_required" {
    var fixture = try buildInvariantFixture();
    try fixture.encodeWith(&.{});
    var inputs = fixture.inputs();
    inputs.observed_invariant_operations = &.{};
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.Stage.invariant_coverage, result.rejection.?.stage);
    try testing.expectEqual(
        verdict.ReasonCode.invariant_operation_required,
        result.rejection.?.code,
    );
    // A rejected artifact reports no applicability at all. Vacuity is a report
    // about an accepted artifact, never a softer landing for a refused one.
    try testing.expectEqual(
        verdict.WriteApplicability.not_applicable,
        result.invariants.writeApplicability(),
    );
}

test "a declared write absent from independent observation rejects rather than reporting vacuous" {
    // The witness list names a posting group the loader never found. The exact
    // count comparison refuses it; write applicability is never reached.
    var unobserved = try buildInvariantFixture();
    var unobserved_inputs = unobserved.inputs();
    unobserved_inputs.observed_invariant_operations = &.{};
    var result = check(unobserved_inputs, policy_mod.production);
    try testing.expectEqual(verdict.Stage.invariant_coverage, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.invariant_member_extra, result.rejection.?.code);
    try testing.expectEqual(
        verdict.WriteApplicability.not_applicable,
        result.invariants.writeApplicability(),
    );

    // The other direction: the loader found a posting group the certificate
    // does not witness. Reporting that as vacuous would hide a real write.
    var unwitnessed = try buildInvariantFixture();
    try unwitnessed.encodeWith(&.{});
    result = check(unwitnessed.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.invariant_member_missing, result.rejection.?.code);
    try testing.expectEqual(
        verdict.WriteApplicability.not_applicable,
        result.invariants.writeApplicability(),
    );

    // A witness that renames the observed write as a read is a forgery, not a
    // read-only topology.
    var forged = try buildInvariantFixture();
    forged.invariant_witnesses[0].operation = .balance;
    forged.invariant_witnesses[0].sink = .ledger_balance;
    forged.invariant_witnesses[0].impl_id = invariant.catalog[1].impl_id;
    try forged.encodeWith(&forged.invariant_witnesses);
    result = check(forged.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.invariant_observed_mismatch, result.rejection.?.code);
    try testing.expectEqual(
        verdict.WriteApplicability.not_applicable,
        result.invariants.writeApplicability(),
    );
}

test "tampered invariant specification bytes reject before coverage" {
    var fixture = try buildInvariantFixture();
    var tampered = test_invariant_spec.*;
    tampered[tampered.len - 1] = 3;
    var inputs = fixture.inputs();
    inputs.invariant_spec = &tampered;
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.invariant_spec_digest_mismatch, result.rejection.?.code);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .none), std.meta.activeTag(result.rejection.?.subject));
    const expected_digest = invariant.digest(test_invariant_spec);
    try testing.expectEqualSlices(u8, &expected_digest, &result.rejection.?.expected.?.digest);
}

test "invariant coverage refuses observations beyond the configured limit" {
    var fixture = try buildInvariantFixture();
    const observed = [_]invariant.ObservedOperation{
        fixture.observed[0],
        .{ .function_ordinal = 0, .code_offset = 4, .operation = .post },
    };
    var inputs = fixture.inputs();
    inputs.observed_invariant_operations = &observed;
    var limited = policy_mod.production;
    limited.limits.max_invariant_operations = 1;
    try expectAt(check(inputs, limited), .limits, .work_budget_exhausted);
}

test "an invariant witness cannot name a return node" {
    var fixture = try buildInvariantFixture();
    fixture.invariant_witnesses[0].ir_node = 3;
    fixture.invariant_witnesses[0].translation_index = 2;
    fixture.invariant_witnesses[0].code_offset = 4;
    fixture.observed[0].code_offset = 4;
    try fixture.encodeWith(&fixture.invariant_witnesses);
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_member_extra);
}

test "an invariant witness needs its own scope and a valid translation index" {
    var scope = try buildInvariantFixture();
    scope.invariant_witnesses[0].scope_ir_node = 1;
    try scope.encodeWith(&scope.invariant_witnesses);
    try expectAt(check(scope.inputs(), policy_mod.production), .invariant_coverage, .invariant_translation_missing);

    var absent = try buildInvariantFixture();
    absent.invariant_witnesses[0].translation_index = @intCast(absent.translation.len);
    try absent.encodeWith(&absent.invariant_witnesses);
    try expectAt(check(absent.inputs(), policy_mod.production), .invariant_coverage, .invariant_translation_missing);
}

test "an unconfigured invariant refuses supplied specification bytes" {
    var fixture = try test_support.build();
    var inputs = fixture.inputs();
    inputs.invariant_spec = test_invariant_spec;
    try expectAt(check(inputs, policy_mod.production), .invariant_coverage, .invariant_spec_digest_mismatch);
}

test "an unconfigured invariant refuses observed operations" {
    var fixture = try test_support.build();
    const observed = [_]invariant.ObservedOperation{.{ .function_ordinal = 0, .code_offset = 2, .operation = .post }};
    var inputs = fixture.inputs();
    inputs.observed_invariant_operations = &observed;
    try expectAt(check(inputs, policy_mod.production), .invariant_coverage, .invariant_spec_missing);
}

test "an unconfigured invariant refuses invariant graph members" {
    var fixture = try buildInvariantFixture();
    var parts = fixture.parts(&.{});
    parts.identity.invariant_spec_digest = [_]u8{0} ** 32;
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    var inputs = fixture.inputs();
    inputs.invariant_spec = null;
    inputs.observed_invariant_operations = &.{};
    const result = check(inputs, policy_mod.production);
    try expectAt(result, .invariant_coverage, .invariant_spec_missing);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .graph_member), std.meta.activeTag(result.rejection.?.subject));
}

test "an unconfigured invariant refuses a ledger call in the IR" {
    var fixture = try test_support.build();
    fixture.ir[2].tag = .ledger_call;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_spec_missing);
}

test "an invariant witness offset must match the independent observation" {
    var fixture = try buildInvariantFixture();
    fixture.observed[0].code_offset = 3;
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_observed_mismatch);
}

test "duplicate and descending invariant witnesses keep distinct reasons" {
    var fixture = try buildInvariantFixture();
    var witnesses = [_]cert_mod.InvariantWitness{ fixture.invariant_witnesses[0], fixture.invariant_witnesses[0] };
    try fixture.encodeWith(&witnesses);
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_member_duplicate);

    witnesses[1].code_offset = 1;
    try fixture.encodeWith(&witnesses);
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_member_out_of_order);
}

test "one ledger node cannot use two ordered witnesses" {
    var fixture = try buildInvariantFixture();
    fixture.translation[1].code_len = 2;
    var witnesses = [_]cert_mod.InvariantWitness{ fixture.invariant_witnesses[0], fixture.invariant_witnesses[0] };
    witnesses[1].code_offset = 3;
    const observed = [_]invariant.ObservedOperation{
        fixture.observed[0],
        .{ .function_ordinal = 0, .code_offset = 3, .operation = .post },
    };
    try fixture.encodeWith(&witnesses);
    var inputs = fixture.inputs();
    inputs.observed_invariant_operations = &observed;
    try expectAt(check(inputs, policy_mod.production), .invariant_coverage, .invariant_member_duplicate);
}

test "duplicate independent observations reject before witness comparison" {
    var fixture = try buildInvariantFixture();
    fixture.translation[1].code_len = 2;
    var witnesses = [_]cert_mod.InvariantWitness{ fixture.invariant_witnesses[0], fixture.invariant_witnesses[0] };
    witnesses[1].code_offset = 3;
    const observed = [_]invariant.ObservedOperation{ fixture.observed[0], fixture.observed[0] };
    try fixture.encodeWith(&witnesses);
    var inputs = fixture.inputs();
    inputs.observed_invariant_operations = &observed;
    const result = check(inputs, policy_mod.production);
    try expectAt(result, .invariant_coverage, .invariant_observed_mismatch);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .code_offset), std.meta.activeTag(result.rejection.?.subject));
    try testing.expectEqual(@as(u32, 2), result.rejection.?.subject.code_offset);
}

test "an invariant witness cannot use a jump as its emission" {
    var fixture = try buildInvariantFixture();
    const translation = [_]cert_mod.Witness{
        fixture.translation[0],                                                                                                   fixture.translation[1], fixture.translation[2],
        .{ .ir_node = 2, .code_start = 3, .code_len = 1, .target_ir = 2, .target_offset = 2, .scope_ir_node = 0, .kind = .jump },
    };
    var witness = fixture.invariant_witnesses;
    witness[0].translation_index = 3;
    witness[0].code_offset = 3;
    fixture.observed[0].code_offset = 3;
    var parts = fixture.parts(&witness);
    parts.translation = &translation;
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_translation_missing);
}

test "a second ledger call needs a witness when witness and observation counts agree" {
    var fixture = try buildInvariantFixture();
    const ir = [_]cert_mod.IrNode{
        fixture.ir[0],
        fixture.ir[1],
        fixture.ir[2],
        .{ .id = 3, .tag = .ledger_call, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(24), .aux = 0 },
        .{ .id = 4, .tag = .return_node, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(25) },
    };
    var ordered_ir = ir;
    ordered_ir[1].child_count = 3;
    const translation = [_]cert_mod.Witness{
        fixture.translation[0],
        fixture.translation[1],
        .{ .ir_node = 3, .code_start = 4, .code_len = 1, .target_ir = 3, .target_offset = 4, .scope_ir_node = 0, .kind = .emission },
        .{ .ir_node = 4, .code_start = 6, .code_len = 2, .target_ir = 4, .target_offset = 6, .scope_ir_node = 0, .kind = .emission },
    };
    var parts = fixture.parts(&fixture.invariant_witnesses);
    parts.ir = &ordered_ir;
    parts.translation = &translation;
    parts.identity.ir_root = cert_mod.irRootFromNodes(&ordered_ir);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    const result = check(fixture.inputs(), policy_mod.production);
    try expectAt(result, .invariant_coverage, .invariant_member_missing);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .ir_node), std.meta.activeTag(result.rejection.?.subject));
    try testing.expectEqual(@as(u32, 3), result.rejection.?.subject.ir_node);
}

test "an invariant specification that cannot decode rejects" {
    const invalid = [_]u8{0};
    var fixture = try buildInvariantFixtureFor(&invalid);
    try expectAt(check(fixture.inputs(), policy_mod.production), .invariant_coverage, .invariant_spec_undecodable);
}

test "missing invariant graph members reject independently" {
    var fixture = try buildInvariantFixture();
    var without_spec: [10]graph.Member = undefined;
    @memcpy(without_spec[0..9], fixture.members[0..9]);
    without_spec[9] = fixture.members[10];
    const parts = fixture.parts(&fixture.invariant_witnesses);
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &without_spec);
    var inputs = fixture.inputs();
    inputs.observed_graph = &without_spec;
    try expectAt(check(inputs, policy_mod.production), .invariant_coverage, .invariant_spec_member_missing);

    var other = try buildInvariantFixture();
    var without_adapter: [10]graph.Member = undefined;
    @memcpy(&without_adapter, other.members[0..10]);
    const other_parts = other.parts(&other.invariant_witnesses);
    other.len = try encodeBoundTestParts(&other.buffer, other_parts, &without_adapter);
    var other_inputs = other.inputs();
    other_inputs.observed_graph = &without_adapter;
    try expectAt(check(other_inputs, policy_mod.production), .invariant_coverage, .invariant_adapter_member_missing);
}

test "an invariant spec member at a nonzero ordinal rejects even with the right digest" {
    var fixture = try buildInvariantFixture();
    fixture.members[9].ordinal = 1;
    const parts = fixture.parts(&fixture.invariant_witnesses);
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    var inputs = fixture.inputs();
    inputs.observed_graph = &fixture.members;
    try expectAt(check(inputs, policy_mod.production), .invariant_coverage, .invariant_spec_digest_mismatch);
}

test "an opcode inventory edge may name an id past the proof IR" {
    // Only a node edge is bounded by the IR length. An opcode id names a
    // bytecode opcode, so bounding it by the node count would refuse a sound
    // certificate whose handler has fewer nodes than the opcode's number.
    var fixture = try test_support.build();
    fixture.trusted[0].member_id = @intCast(fixture.ir.len + 7);
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(result.rejection == null);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
}

test "invariant adapter, operation, sink, and implementation identities reject" {
    var adapter = try buildInvariantFixture();
    for (&adapter.members) |*member| {
        if (member.kind == .invariant_ledger_adapter) member.digest = test_support.digest(0x78);
    }
    const parts = adapter.parts(&adapter.invariant_witnesses);
    adapter.len = try encodeBoundTestParts(&adapter.buffer, parts, &adapter.members);
    try expectAt(check(adapter.inputs(), policy_mod.production), .invariant_coverage, .invariant_adapter_identity_mismatch);

    var operation = try buildInvariantFixture();
    operation.ir[2].aux = @intCast(invariant.catalog.len);
    try operation.encodeWith(&operation.invariant_witnesses);
    try expectAt(check(operation.inputs(), policy_mod.production), .invariant_coverage, .invariant_operation_unknown);

    var sink = try buildInvariantFixture();
    sink.invariant_witnesses[0].sink = .ledger_balance;
    try sink.encodeWith(&sink.invariant_witnesses);
    try expectAt(check(sink.inputs(), policy_mod.production), .invariant_coverage, .invariant_sink_mismatch);

    var impl = try buildInvariantFixture();
    impl.invariant_witnesses[0].impl_id +%= 1;
    try impl.encodeWith(&impl.invariant_witnesses);
    try expectAt(check(impl.inputs(), policy_mod.production), .invariant_coverage, .invariant_impl_identity_mismatch);
}

test "a guarded artifact is accepted, and its guards are counted apart from its properties" {
    var fixture = try test_support.buildGuarded();
    const result = check(fixture.inputs(), policy_mod.production);

    if (result.rejection) |rejection| {
        std.debug.print(
            "unexpected rejection: {s} / {s}\n",
            .{ rejection.stage.name(), rejection.code.text() },
        );
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expectEqual(@as(u32, 1), result.guards.required);
    try testing.expectEqual(@as(u32, 1), result.guards.covered);
    try testing.expect(result.guards.ready());
    try testing.expect(result.guards.kinds & (@as(u8, 1) << 0) != 0);

    // A covered guard is not a discharged property. Nothing about the guard
    // appears in the property verdicts, and the grade is still the weakest
    // static edge.
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .tested), result.grade);
    inline for (@typeInfo(ps.Property).@"enum".fields) |field| {
        const property: ps.Property = @enumFromInt(field.value);
        try testing.expectEqual(@as(?verdict.AssuranceGrade, .tested), result.properties.gradeFor(property));
    }
}

test "a certificate with no guarded call is ready with nothing to guard" {
    var fixture = try test_support.build();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(result.accepted());
    try testing.expectEqual(@as(u32, 0), result.guards.required);
    // Vacuously ready is the honest answer for a handler that guards nothing.
    try testing.expect(result.guards.ready());
    try testing.expectEqual(@as(u8, 0), result.guards.kinds);
}

test "the immediate predecessor proof system is refused at decode" {
    var fixture = try test_support.buildGuarded();
    std.mem.writeInt(u16, fixture.buffer[10..12], 1, .little);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(
        verdict.ReasonCode.unknown_enum_member,
        result.rejection.?.code,
    );
}

test "an omitted, extra, duplicated, or reordered guard rejects" {
    var missing = try test_support.buildGuarded();
    var parts = missing.parts();
    parts.residual = &.{};
    parts.identity.residual_plan_digest = cert_mod.residualPlanDigest(&.{});
    for (&missing.members) |*member| {
        if (member.kind == .residual_plan) member.digest = parts.identity.residual_plan_digest;
    }
    parts.graph = &missing.members;
    try encodeGuardedParts(&missing, parts);
    var result = check(missing.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.guard_coverage, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.guard_member_missing, result.rejection.?.code);

    var extra = try test_support.buildGuarded();
    const two = [_]cert_mod.ResidualObligation{
        extra.residual_plan[0],
        .{
            .kind = .env_key,
            .normalization = .identifier_exact_v1,
            .sink = .env_read,
            .section = .env,
            .impl_id = residual.guard_impl.env_read_v1,
            .operation_id = 3,
        },
    };
    var extra_parts = extra.parts();
    extra_parts.residual = &two;
    extra_parts.identity.residual_plan_digest = cert_mod.residualPlanDigest(&two);
    for (&extra.members) |*member| {
        if (member.kind == .residual_plan) member.digest = extra_parts.identity.residual_plan_digest;
    }
    extra_parts.graph = &extra.members;
    try encodeGuardedParts(&extra, extra_parts);
    result = check(extra.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.guard_member_extra, result.rejection.?.code);

    var duplicate = try test_support.buildGuarded();
    const two_calls = [_]cert_mod.IrNode{
        duplicate.ir[0],
        duplicate.ir[1],
        duplicate.ir[2],
        .{ .id = 3, .tag = .capability_call, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(24), .aux = 0 },
        .{ .id = 4, .tag = .return_node, .parent = 1, .first_child = 0, .child_count = 0, .digest = test_support.digest(25) },
    };
    var ir = two_calls;
    ir[1].child_count = 3;
    const duplicated = [_]cert_mod.ResidualObligation{ duplicate.residual_plan[0], duplicate.residual_plan[0] };
    var duplicate_parts = duplicate.parts();
    duplicate_parts.ir = &ir;
    duplicate_parts.identity.ir_root = cert_mod.irRootFromNodes(&ir);
    duplicate_parts.residual = &duplicated;
    duplicate_parts.identity.residual_plan_digest = cert_mod.residualPlanDigest(&duplicated);
    for (&duplicate.members) |*member| {
        if (member.kind == .proof_ir) member.digest = duplicate_parts.identity.ir_root;
        if (member.kind == .residual_plan) member.digest = duplicate_parts.identity.residual_plan_digest;
    }
    duplicate.len = try encodeBoundTestParts(&duplicate.buffer, duplicate_parts, &duplicate.members);
    try expectAt(check(duplicate.inputs(), policy_mod.production), .guard_coverage, .guard_member_duplicate);

    var descending = duplicated;
    descending[1].operation_id = 1;
    duplicate_parts.residual = &descending;
    duplicate_parts.identity.residual_plan_digest = cert_mod.residualPlanDigest(&descending);
    for (&duplicate.members) |*member| {
        if (member.kind == .residual_plan) member.digest = duplicate_parts.identity.residual_plan_digest;
    }
    duplicate.len = try encodeBoundTestParts(&duplicate.buffer, duplicate_parts, &duplicate.members);
    try expectAt(check(duplicate.inputs(), policy_mod.production), .guard_coverage, .guard_member_out_of_order);
}

test "current behavior accepts two residual-plan graph members with a nonzero ordinal" {
    var fixture = try test_support.buildGuarded();
    var members: [11]graph.Member = undefined;
    @memcpy(members[0..fixture.members.len], &fixture.members);
    members[10] = .{ .kind = .residual_plan, .ordinal = 1, .digest = fixture.parts().identity.residual_plan_digest };
    const parts = fixture.parts();
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &members);
    var inputs = fixture.inputs();
    inputs.observed_graph = &members;
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);

    // Both certificates add one graph record. The residual member scan adds
    // no work beyond the record decoding and graph binding shared by both.
    var ordinary = try test_support.buildGuarded();
    var ordinary_members: [11]graph.Member = undefined;
    @memcpy(ordinary_members[0..ordinary.members.len], &ordinary.members);
    ordinary_members[10] = .{ .kind = .source_profile_frontend, .ordinal = 0, .digest = test_support.digest(0x79) };
    const ordinary_parts = ordinary.parts();
    ordinary.len = try encodeBoundTestParts(&ordinary.buffer, ordinary_parts, &ordinary_members);
    var ordinary_inputs = ordinary.inputs();
    ordinary_inputs.observed_graph = &ordinary_members;
    const ordinary_result = check(ordinary_inputs, policy_mod.production);
    try testing.expectEqual(SemanticState.policy_accepted, ordinary_result.semantic);
    try testing.expect(ordinary_result.rejection == null);
    try testing.expectEqual(ordinary_result.work_spent, result.work_spent);
}

test "current behavior skips rewrite checks when translation is empty" {
    var fixture = try test_support.buildGuarded();
    const invalid = [_]cert_mod.Rewrite{.{ .rule = .rewrite_peephole_fusion, .before_offset = 0, .before_len = 4, .after_offset = 0, .after_len = 9, .delta = 0 }};
    var parts = fixture.parts();
    parts.rewrites = &invalid;
    try encodeGuardedParts(&fixture, parts);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);
}

test "a guard that disagrees with the consumer's catalog rejects on every field" {
    const Case = struct {
        name: []const u8,
        code: verdict.ReasonCode,
        apply: *const fn (*cert_mod.ResidualObligation) void,
    };
    const cases = [_]Case{
        .{ .name = "kind", .code = .guard_kind_mismatch, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.kind = .cache_namespace;
            }
        }.f },
        .{ .name = "normalization", .code = .guard_normalization_mismatch, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.normalization = .endpoint_v1;
            }
        }.f },
        .{ .name = "sink", .code = .guard_sink_mismatch, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.sink = .cache_operation;
            }
        }.f },
        .{ .name = "section", .code = .guard_section_mismatch, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.section = .cache;
            }
        }.f },
        .{ .name = "implementation", .code = .guard_impl_identity_mismatch, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.impl_id = 99;
            }
        }.f },
        .{ .name = "operation", .code = .guard_member_missing, .apply = struct {
            fn f(o: *cert_mod.ResidualObligation) void {
                o.operation_id = 3;
            }
        }.f },
    };

    for (cases) |case| {
        var fixture = try test_support.buildGuarded();
        case.apply(&fixture.residual_plan[0]);
        try fixture.encode();
        const result = check(fixture.inputs(), policy_mod.production);
        testing.expectEqual(case.code, result.rejection.?.code) catch |err| {
            std.debug.print("guard '{s}' mismatch was not refused as expected\n", .{case.name});
            return err;
        };
        try testing.expectEqual(verdict.Stage.guard_coverage, result.rejection.?.stage);
        if (case.code == .guard_impl_identity_mismatch) {
            try testing.expectEqual(@as(u64, residual.guard_impl.env_read_v1), result.rejection.?.expected.?.scalar);
            try testing.expectEqual(@as(u64, 99), result.rejection.?.actual.?.scalar);
        }
    }
}

test "a guarded call naming a catalog row that does not exist rejects" {
    var fixture = try test_support.buildGuarded();
    fixture.ir[2].aux = @intCast(residual.catalog.len);
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.guard_operation_unknown, result.rejection.?.code);
}

test "a fully consistent SQL guard remains disabled" {
    var fixture = try test_support.buildGuarded();
    const row = residual.lookupIndex("zttp:sql", "sqlOne", 0) orelse
        return error.TestUnexpectedResult;
    const entry = residual.catalog[row];
    fixture.ir[2].aux = row;
    fixture.residual_plan[0] = .{
        .kind = entry.kind,
        .normalization = entry.kind.normalization(),
        .sink = entry.kind.sink(),
        .section = entry.kind.section(),
        .impl_id = entry.impl_id,
        .operation_id = 2,
    };
    fixture.writeSqlPolicy("listTodos", true);
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.guard_coverage, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.guard_family_disabled, result.rejection.?.code);
}

test "a guarded operation with no configured category rejects" {
    var fixture = try test_support.buildGuarded();
    // Every category unconfigured. An absent allowlist is not an empty one.
    fixture.policy_len = 0;
    var at: usize = 0;
    for (0..4) |_| {
        fixture.policy_bytes[at] = 0;
        at += 1;
        std.mem.writeInt(u16, fixture.policy_bytes[at..][0..2], 0, .little);
        at += 2;
    }
    fixture.policy_bytes[at] = 0;
    at += 1;
    fixture.policy_len = at;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(
        verdict.ReasonCode.guard_category_not_configured,
        result.rejection.?.code,
    );
}

test "a guarded artifact with no policy bytes rejects rather than assuming any" {
    var fixture = try test_support.buildGuarded();
    var inputs = fixture.inputs();
    inputs.runtime_policy = null;
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.runtime_policy_missing, result.rejection.?.code);
}

test "policy bytes that do not hash to the committed digest reject" {
    var fixture = try test_support.buildGuarded();
    // Same shape, different entry: the certificate committed to the other bytes.
    var other = try test_support.buildGuarded();
    other.writePolicy(&.{"OTHER_KEY"});
    var inputs = fixture.inputs();
    inputs.runtime_policy = .{ .bytes = other.policySlice() };
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(
        verdict.ReasonCode.runtime_policy_undecodable,
        result.rejection.?.code,
    );
}

test "a residual plan that is not the one the identity names rejects" {
    var fixture = try test_support.buildGuarded();
    var parts = fixture.parts();
    parts.identity.residual_plan_digest = test_support.digest(0x7C);
    for (&fixture.members) |*member| {
        if (member.kind == .residual_plan) member.digest = test_support.digest(0x7C);
    }
    parts.graph = &fixture.members;
    try encodeGuardedParts(&fixture, parts);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(
        verdict.ReasonCode.residual_plan_digest_mismatch,
        result.rejection.?.code,
    );
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .none), std.meta.activeTag(result.rejection.?.subject));
}

test "a residual-plan graph member must name the actual plan" {
    var fixture = try test_support.buildGuarded();
    for (&fixture.members) |*member| {
        if (member.kind == .residual_plan) member.digest = test_support.digest(0x7D);
    }
    const parts = fixture.parts();
    try encodeGuardedParts(&fixture, parts);
    const result = check(fixture.inputs(), policy_mod.production);
    try expectAt(result, .guard_coverage, .residual_plan_digest_mismatch);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .graph_member), std.meta.activeTag(result.rejection.?.subject));
}

test "the immediate predecessor schema is refused by production" {
    var fixture = try test_support.buildGuarded();
    std.mem.writeInt(u16, fixture.buffer[8..10], 2, .little);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(
        verdict.ReasonCode.unsupported_schema_version,
        result.rejection.?.code,
    );
}

/// Re-encode a guarded fixture from parts a test built by hand, keeping the
/// certificate's self-commitment and executable root consistent.
fn encodeGuardedParts(
    fixture: *test_support.GuardedFixture,
    certificate_parts: cert_mod.Parts,
) !void {
    var built = certificate_parts;
    for (&fixture.members) |*member| {
        if (member.kind == .proof_certificate) member.digest = [_]u8{0} ** 32;
    }
    built.graph = &fixture.members;
    built.identity.executable_root = [_]u8{0} ** 32;
    const provisional = try cert_mod.encode(built, &fixture.buffer);
    var budget = Budget.init(.{});
    const decoded = try cert_mod.decode(provisional, .{}, &budget);
    const certificate_digest = try cert_mod.commitmentDigest(provisional, decoded);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_certificate) member.digest = certificate_digest;
    }
    built.identity.executable_root = try graph.computeRoot(&fixture.members);
    const encoded = try cert_mod.encode(built, &fixture.buffer);
    fixture.len = encoded.len;
}

test "the disclosed edge count is reported next to the grade" {
    var fixture = try test_support.build();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(result.accepted());
    // Production relies on three tested property edges and the trusted opcode
    // relation under translation. A grade that hid those would report the
    // checks without the assumptions beneath them.
    try testing.expectEqual(@as(u32, 4), result.disclosed_edges);
}

test "unchecked evidence and its trusted inventory are both disclosed" {
    var fixture = try test_support.build();
    fixture.evidence[0] = .{
        .obligation_index = 0,
        .edge = .trusted,
        .rule = null,
        .node_id = 0,
        .aux = 0,
    };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.trusted = &trusted;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(result.accepted());
    try testing.expectEqual(@as(u32, 6), result.disclosed_edges);
}

test "translation cannot omit its trusted opcode dependency" {
    var fixture = try test_support.build();
    fixture.trusted[0].family = .node;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.trusted_edge_undeclared, result.rejection.?.code);
}

test "a matching certificate and inventory reach policy acceptance" {
    var fixture = try test_support.build();
    const result = check(fixture.inputs(), policy_mod.production);

    if (result.rejection) |rejection| {
        std.debug.print("unexpected rejection: {s} / {s}\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.accepted());
    // The opcode relation under the translation witnesses is still trusted, so
    // it is the honest weakest edge for the accepted theorem chain.
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .trusted), result.grade);
    try testing.expect(result.properties.accepted(.no_secret_leakage));
    try testing.expect(!result.properties.accepted(.read_only));
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .tested), result.properties.gradeFor(.read_only));
    try testing.expect(result.work_spent > 0);
}

test "a policy that requires nothing is refused before anything is read" {
    var fixture = try test_support.build();
    const empty = Policy{
        .proof_systems = &[_]ps.ProofSystem{.zttp_pcc_v3},
        .semantics_epochs = &[_]u32{ps.semantics_epoch},
        .required = &.{},
    };
    const result = check(fixture.inputs(), empty);
    try testing.expectEqual(verdict.ReasonCode.policy_requires_nothing, result.rejection.?.code);
    try testing.expect(!result.rejection.?.recertifiable);
}

test "mutating any observed member class rejects at artifact binding" {
    var fixture = try test_support.build();
    for (0..fixture.members.len) |index| {
        var observed = fixture.members;
        observed[index].digest[0] +%= 1;
        var inputs = fixture.inputs();
        inputs.observed_graph = &observed;
        const result = check(inputs, policy_mod.production);
        try testing.expectEqual(verdict.Stage.artifact_binding, result.rejection.?.stage);
        try testing.expectEqual(
            verdict.ReasonCode.graph_member_digest_mismatch,
            result.rejection.?.code,
        );
        try testing.expect(result.rejection.?.recertifiable);
    }
}

test "a valid certificate attached to another artifact rejects" {
    var fixture = try test_support.build();
    var other = try test_support.build();
    other.members[0].digest = test_support.digest(0x5A);
    try other.encode();

    // The certificate is internally valid and its own roots agree. It simply
    // does not describe the artifact the consumer is holding.
    var inputs = other.inputs();
    inputs.observed_graph = fixture.graphMembers();
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.Stage.artifact_binding, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.graph_member_digest_mismatch, result.rejection.?.code);
}

test "an artifact carrying a member the certificate omits rejects" {
    var fixture = try test_support.build();
    var observed: [10]graph.Member = undefined;
    @memcpy(observed[0..9], &fixture.members);
    observed[9] = .{ .kind = .dep_bytecode, .ordinal = 0, .digest = test_support.digest(99) };
    std.mem.sort(graph.Member, &observed, {}, struct {
        fn lt(_: void, a: graph.Member, b: graph.Member) bool {
            return graph.Member.order(a, b) == .lt;
        }
    }.lt);

    var inputs = fixture.inputs();
    inputs.observed_graph = &observed;
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.graph_member_extra, result.rejection.?.code);
}

test "an artifact missing a member the certificate names rejects" {
    var fixture = try test_support.build();
    var inputs = fixture.inputs();
    inputs.observed_graph = fixture.members[0 .. fixture.members.len - 1];
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.graph_member_missing, result.rejection.?.code);
}

test "a root different from the committed graph root rejects" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.identity.executable_root = test_support.digest(0x71);
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    try expectAt(check(fixture.inputs(), policy_mod.production), .artifact_binding, .executable_root_mismatch);
}

test "a zero executable commitment rejects" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.identity.executable_root = [_]u8{0} ** 32;
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    try expectAt(check(fixture.inputs(), policy_mod.production), .artifact_binding, .zero_commitment);
}

test "a graph without a required kind rejects even when the lists agree" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    const without_main = fixture.members[1..];
    parts.graph = without_main;
    parts.identity.executable_root = try graph.computeRoot(without_main);
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    var inputs = fixture.inputs();
    inputs.observed_graph = without_main;
    try expectAt(check(inputs, policy_mod.production), .artifact_binding, .graph_member_missing);
}

test "a proof IR graph member that differs from the identity rejects" {
    var fixture = try test_support.build();
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = test_support.digest(0x72);
    }
    var parts = fixture.parts();
    parts.identity.executable_root = try graph.computeRoot(&fixture.members);
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    try expectAt(check(fixture.inputs(), policy_mod.production), .artifact_binding, .proof_ir_digest_mismatch);
}

test "a certificate graph member that differs from its commitment rejects" {
    var fixture = try test_support.build();
    for (&fixture.members) |*member| {
        if (member.kind == .proof_certificate) member.digest = test_support.digest(0x73);
    }
    var parts = fixture.parts();
    parts.identity.executable_root = try graph.computeRoot(&fixture.members);
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    try expectAt(check(fixture.inputs(), policy_mod.production), .artifact_binding, .proof_certificate_digest_mismatch);
}

test "an observed member after the last claimed member rejects" {
    var fixture = try test_support.build();
    var observed: [10]graph.Member = undefined;
    @memcpy(observed[0..fixture.members.len], &fixture.members);
    observed[9] = .{ .kind = .declaration, .ordinal = 0, .digest = test_support.digest(0x74) };
    var inputs = fixture.inputs();
    inputs.observed_graph = &observed;
    try expectAt(check(inputs, policy_mod.production), .artifact_binding, .graph_member_extra);
}

test "duplicate and descending graph members keep their exact reasons" {
    var fixture = try test_support.build();
    var members = fixture.members;
    members[1] = members[0];
    var parts = fixture.parts();
    parts.graph = &members;
    parts.identity.executable_root = test_support.digest(0x75);
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    var inputs = fixture.inputs();
    inputs.observed_graph = &members;
    try expectAt(check(inputs, policy_mod.production), .artifact_binding, .graph_member_duplicate);

    members[0] = fixture.members[1];
    members[1] = fixture.members[0];
    parts.graph = &members;
    fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
    try expectAt(check(inputs, policy_mod.production), .artifact_binding, .graph_member_out_of_order);
}

test "an unsupported semantics epoch rejects" {
    var fixture = try test_support.build();
    const epochs = [_]u32{ps.semantics_epoch + 7};
    const other = Policy{
        .proof_systems = policy_mod.production.proof_systems,
        .semantics_epochs = &epochs,
        .required = policy_mod.production.required,
    };
    const result = check(fixture.inputs(), other);
    try testing.expectEqual(verdict.ReasonCode.unsupported_semantics_epoch, result.rejection.?.code);
    try testing.expectEqual(verdict.Stage.proof_system_identity, result.rejection.?.stage);
}

test "empty policy identity sets are refused before certificate parsing" {
    var fixture = try test_support.build();
    var no_systems = policy_mod.production;
    no_systems.proof_systems = &.{};
    try expectAt(check(fixture.inputs(), no_systems), .policy, .proof_system_not_selected);

    var no_epochs = policy_mod.production;
    no_epochs.semantics_epochs = &.{};
    try expectAt(check(fixture.inputs(), no_epochs), .policy, .semantics_epoch_not_selected);
}

test "a starved work budget rejects at the limits stage" {
    var fixture = try test_support.build();
    var starved = policy_mod.production;
    starved.limits.max_work = 2;
    const result = check(fixture.inputs(), starved);
    try testing.expectEqual(verdict.Stage.limits, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.work_budget_exhausted, result.rejection.?.code);
}

test "checking is deterministic" {
    var fixture = try test_support.build();
    const first = check(fixture.inputs(), policy_mod.production);
    const second = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(first.semantic, second.semantic);
    try testing.expectEqual(first.work_spent, second.work_spent);
    try testing.expectEqual(first.grade, second.grade);
}

test "provenance is carried through and never raises the semantic state" {
    var fixture = try test_support.build();
    var inputs = fixture.inputs();
    inputs.provenance = .trusted_origin;
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.ProvenanceState.trusted_origin, result.provenance);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);

    // And an unsigned artifact with the same evidence is accepted just the same.
    var unsigned = fixture.inputs();
    unsigned.provenance = .absent;
    const without = check(unsigned, policy_mod.production);
    try testing.expect(without.accepted());
    try testing.expectEqual(verdict.ProvenanceState.absent, without.provenance);
}

test "a totality rule whose return premise fails is refused" {
    var fixture = try test_support.build();
    // The handler no longer returns on any path; the certificate still claims
    // it does.
    fixture.ir[2].tag = .plain;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.rule_premise_unmet, result.rejection.?.code);
}

test "a graded totality claim on a nonreturning handler is fabricated" {
    var fixture = try test_support.build();
    fixture.ir[2].tag = .plain;
    fixture.evidence[0] = test_support.testedFor(0);
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try expectAt(result, .evidence_check, .fabricated_property);
    try testing.expect(!result.rejection.?.recertifiable);
}

test "one branch arm cannot establish totality" {
    var fixture = try test_support.build();
    fixture.ir[1].tag = .branch;
    fixture.evidence[0] = test_support.testedFor(0);
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .fabricated_property);
}

test "a childless function cannot inherit a sibling's totality" {
    var fixture = try test_support.build();
    fixture.ir[0].child_count = 2;
    fixture.ir[1].tag = .function;
    fixture.ir[1].first_child = 2;
    fixture.ir[1].child_count = 0;
    fixture.ir[2].parent = 0;
    fixture.evidence[0] = test_support.testedFor(0);
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .fabricated_property);
}

test "a disclosed trusted node can declare handler totality" {
    var fixture = try test_support.build();
    fixture.ir[2].tag = .plain;
    fixture.evidence[0] = .{ .obligation_index = 0, .edge = .trusted, .rule = null, .node_id = 0, .aux = 0 };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.identity.ir_root = cert_mod.irRootFromNodes(&fixture.ir);
    parts.trusted = &trusted;
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    try fixture.encodeParts(parts);
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);
}

test "each obligation needs evidence" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.evidence = fixture.evidence[0..9];
    try fixture.encodeParts(parts);
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .obligation_without_evidence);
}

test "an evidence obligation index at the count bound rejects" {
    var fixture = try test_support.build();
    fixture.evidence[9].obligation_index = @intCast(fixture.obligations.len);
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .obligation_missing);
}

test "refused totality evidence prevents a fabricated-property verdict" {
    var fixture = try test_support.build();
    fixture.ir[2].tag = .plain;
    fixture.evidence[0] = test_support.testedFor(0);
    const evidence = fixture.evidence ++ [_]cert_mod.Evidence{.{ .obligation_index = 0, .edge = .not_established, .rule = null, .node_id = 0, .aux = 0 }};
    var parts = fixture.parts();
    parts.ir = &fixture.ir;
    parts.identity.ir_root = cert_mod.irRootFromNodes(&fixture.ir);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    parts.evidence = &evidence;
    try fixture.encodeParts(parts);
    try expectAt(check(fixture.inputs(), policy_mod.production), .policy, .required_property_not_established);
}

test "an optional trusted totality edge is not counted as disclosed" {
    var fixture = try test_support.build();
    var policy = policy_mod.production;
    const required = [_]policy_mod.Requirement{.{ .property = .results_checked, .min_grade = .tested }};
    policy.required = &required;
    const result = check(fixture.inputs(), policy);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);
    try testing.expectEqual(@as(u32, 1), result.disclosed_edges);
}

test "an opcode inventory edge cannot disclose a trusted proof node" {
    var fixture = try test_support.build();
    fixture.evidence[0] = .{ .obligation_index = 0, .edge = .trusted, .rule = null, .node_id = 0, .aux = 0 };
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .trusted_edge_undeclared);
}

test "tested evidence also needs an existing proof node" {
    var fixture = try test_support.build();
    fixture.evidence[3].node_id = @intCast(fixture.ir.len);
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "refused evidence defeats graded evidence for the same property" {
    var fixture = try test_support.build();
    const evidence = fixture.evidence ++ [_]cert_mod.Evidence{.{
        .obligation_index = 1,
        .edge = .not_established,
        .rule = null,
        .node_id = 0,
        .aux = 0,
    }};
    var parts = fixture.parts();
    parts.evidence = &evidence;
    try fixture.encodeParts(parts);
    const required = [_]policy_mod.Requirement{.{ .property = .results_checked, .min_grade = .tested }};
    var policy = policy_mod.production;
    policy.required = &required;
    try expectAt(check(fixture.inputs(), policy), .policy, .required_property_not_established);
}

test "a nontrusted grade in the trusted inventory rejects" {
    var fixture = try test_support.build();
    fixture.trusted[0].grade = .tested;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .evidence_edge_invalid);
}

test "translation evidence without any witness rejects" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.translation = &.{};
    try fixture.encodeParts(parts);
    try expectAt(check(fixture.inputs(), policy_mod.production), .translation_check, .witness_missing);
}

test "citing a rule that does not apply at the named node rejects" {
    var fixture = try test_support.build();
    fixture.evidence[0].rule = .branch_both_arms_total;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.rule_premise_unmet, result.rejection.?.code);
}

test "proved evidence without a kernel rule rejects" {
    var fixture = try test_support.build();
    fixture.evidence[4].edge = .proved;
    fixture.evidence[4].rule = null;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.evidence_edge_invalid, result.rejection.?.code);
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
}

test "a translation rule cited as a source-level proof is a category error" {
    var fixture = try test_support.build();
    fixture.evidence[0].rule = .jump_target_resolved;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.evidence_edge_invalid, result.rejection.?.code);
}

test "an omitted obligation rejects" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.obligations = fixture.obligations[0..7];
    parts.evidence = fixture.evidence[0..9];
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.obligation_reconstruction, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.obligation_missing, result.rejection.?.code);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .none), std.meta.activeTag(result.rejection.?.subject));
}

test "an extra obligation rejects before reconstructing properties" {
    var fixture = try test_support.build();
    const obligations = fixture.obligations ++ [_]cert_mod.Obligation{fixture.obligations[7]};
    var parts = fixture.parts();
    parts.obligations = &obligations;
    try fixture.encodeParts(parts);
    try expectAt(check(fixture.inputs(), policy_mod.production), .obligation_reconstruction, .obligation_extra);
}

test "a duplicated or reordered obligation rejects" {
    var fixture = try test_support.build();
    fixture.obligations[1] = fixture.obligations[0];
    try fixture.encode();
    var result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.obligation_duplicate, result.rejection.?.code);

    var reordered = try test_support.build();
    std.mem.swap(cert_mod.Obligation, &reordered.obligations[0], &reordered.obligations[1]);
    try reordered.encode();
    result = check(reordered.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.obligation_out_of_order, result.rejection.?.code);
}

test "an obligation whose subject is not the entry function rejects" {
    var fixture = try test_support.build();
    fixture.obligations[0].subject_id = 2;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.obligation_subject_unknown, result.rejection.?.code);
}

test "a proof IR that does not fold into its stated root rejects" {
    var fixture = try test_support.build();
    // Move the IR without moving the root the certificate states.
    var parts = fixture.parts();
    parts.identity.ir_root = test_support.digest(0x77);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = test_support.digest(0x77);
    }
    parts.graph = &fixture.members;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.proof_ir_digest_mismatch, result.rejection.?.code);
}

test "a cyclic or out-of-order proof IR rejects" {
    var fixture = try test_support.build();
    fixture.ir[1].parent = 2;
    try fixture.encode();
    var result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.proof_node_parent_mismatch, result.rejection.?.code);

    var backwards = try test_support.build();
    backwards.ir[0].first_child = 0;
    try backwards.encode();
    result = check(backwards.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.proof_node_cycle, result.rejection.?.code);
}

test "a child whose parent disagrees with its owner rejects" {
    var fixture = try test_support.build();
    fixture.ir[2].parent = 0;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.proof_node_parent_mismatch, result.rejection.?.code);
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
}

test "proof IR depth is bounded by policy" {
    var fixture = try test_support.build();
    var shallow = policy_mod.production;
    shallow.limits.max_depth = 2;

    const result = check(fixture.inputs(), shallow);
    try expectAt(result, .limits, .proof_depth_exceeded);
}

test "an incorrect proof node id rejects" {
    var fixture = try test_support.build();
    fixture.ir[1].id = 9;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "a handler marker on a nonfunction rejects" {
    var fixture = try test_support.build();
    fixture.ir[0].is_handler = false;
    fixture.ir[1].is_handler = true;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "a root with a nonzero parent rejects" {
    var fixture = try test_support.build();
    fixture.ir[0].parent = 1;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_cycle);
}

test "a proof node cannot name itself as parent" {
    var fixture = try test_support.build();
    fixture.ir[0].child_count = 0;
    fixture.ir[1].parent = 1;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_cycle);
}

test "a parent must claim every child that names it" {
    var fixture = try test_support.build();
    const ir = [_]cert_mod.IrNode{
        fixture.ir[0],                                                                                                   fixture.ir[1], fixture.ir[2],
        .{ .id = 3, .tag = .plain, .parent = 0, .first_child = 0, .child_count = 0, .digest = test_support.digest(24) },
    };
    var parts = fixture.parts();
    parts.ir = &ir;
    parts.identity.ir_root = cert_mod.irRootFromNodes(&ir);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_parent_mismatch);
}

test "a proof node cannot claim children beyond the IR" {
    var fixture = try test_support.build();
    fixture.ir[1].child_count = 5;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "two parents cannot both claim the same child" {
    var fixture = try test_support.build();
    fixture.ir[0].child_count = 2;
    fixture.ir[2].parent = 0;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_parent_mismatch);
}

test "the root depth guard names the root at a zero depth limit" {
    var fixture = try test_support.build();
    var policy = policy_mod.production;
    policy.limits.max_depth = 0;
    const result = check(fixture.inputs(), policy);
    try expectAt(result, .limits, .proof_depth_exceeded);
    try testing.expectEqual(@as(std.meta.Tag(verdict.Subject), .ir_node), std.meta.activeTag(result.rejection.?.subject));
    try testing.expectEqual(@as(u32, 0), result.rejection.?.subject.ir_node);
}

test "two handler markers reject" {
    var fixture = try test_support.build();
    fixture.ir[1].tag = .function;
    fixture.ir[1].is_handler = true;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "the handler count implies the empty IR refusal" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.ir = &.{};
    parts.identity.ir_root = cert_mod.irRootFromNodes(&.{});
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "the handler shape check precedes both entry-function lookups" {
    var fixture = try test_support.build();
    fixture.ir[0].is_handler = false;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .evidence_check, .proof_node_unknown);
}

test "canonical order and count imply every obligation is present" {
    var fixture = try test_support.build();
    fixture.obligations[7] = fixture.obligations[6];
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .obligation_reconstruction, .obligation_duplicate);
}

test "a jump witness naming the wrong target offset rejects" {
    var fixture = try test_support.build();
    fixture.witnesses[2].target_offset = 5;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.translation_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.jump_target_mismatch, result.rejection.?.code);
}

test "emission ranges that partially overlap reject" {
    var fixture = try test_support.build();
    // Node 2's range now starts inside node 1's and runs past its end: neither
    // nested nor disjoint.
    fixture.witnesses[1].code_start = 6;
    fixture.witnesses[1].code_len = 8;
    fixture.witnesses[2].target_offset = 6;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.witness_range_overlaps, result.rejection.?.code);
}

test "emission ranges reject overlap with any active ancestor" {
    var fixture = try test_support.build();
    const emissions = [_]cert_mod.Witness{
        .{ .ir_node = 0, .code_start = 0, .code_len = 100, .target_ir = 0, .target_offset = 0, .scope_ir_node = 0, .kind = .emission },
        .{ .ir_node = 1, .code_start = 10, .code_len = 80, .target_ir = 1, .target_offset = 10, .scope_ir_node = 0, .kind = .emission },
        .{ .ir_node = 2, .code_start = 20, .code_len = 10, .target_ir = 2, .target_offset = 20, .scope_ir_node = 0, .kind = .emission },
        .{ .ir_node = 2, .code_start = 40, .code_len = 55, .target_ir = 2, .target_offset = 40, .scope_ir_node = 0, .kind = .emission },
    };
    var parts = fixture.parts();
    parts.translation = &emissions;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.witness_range_overlaps, result.rejection.?.code);
}

test "a rewrite whose spans do not add up rejects" {
    var fixture = try test_support.build();
    fixture.rewrites[0].delta = -4;
    try fixture.encode();
    var result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.rewrite_span_mismatch, result.rejection.?.code);

    var grown = try test_support.build();
    grown.rewrites[0].after_len = 9;
    grown.rewrites[0].delta = 5;
    try grown.encode();
    result = check(grown.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.rewrite_span_mismatch, result.rejection.?.code);
}

test "a rewrite with a source-level rule rejects" {
    var fixture = try test_support.build();
    fixture.rewrites[0].rule = .sequence_member_total;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .translation_check, .rewrite_unknown);
}

test "a witness pointing outside the proof IR rejects" {
    var fixture = try test_support.build();
    fixture.witnesses[0].ir_node = 99;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.witness_range_out_of_bounds, result.rejection.?.code);
}

test "an emission target must name a proof node" {
    var fixture = try test_support.build();
    fixture.witnesses[1].target_ir = @intCast(fixture.ir.len);
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .translation_check, .witness_range_out_of_bounds);
}

test "a nested emission may end at its ancestor boundary" {
    var fixture = try test_support.build();
    fixture.witnesses[1].code_len = 6;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);
}

test "emission ranges reset between function scopes" {
    var fixture = try test_support.build();
    const ir = [_]cert_mod.IrNode{
        .{ .id = 0, .tag = .function, .is_handler = true, .parent = 0, .first_child = 1, .child_count = 2, .digest = test_support.digest(20) },
        .{ .id = 1, .tag = .return_node, .parent = 0, .first_child = 0, .child_count = 0, .digest = test_support.digest(21) },
        .{ .id = 2, .tag = .function, .parent = 0, .first_child = 3, .child_count = 1, .digest = test_support.digest(22) },
        .{ .id = 3, .tag = .return_node, .parent = 2, .first_child = 0, .child_count = 0, .digest = test_support.digest(23) },
    };
    const translation = [_]cert_mod.Witness{
        .{ .ir_node = 1, .code_start = 0, .code_len = 5, .target_ir = 1, .target_offset = 0, .scope_ir_node = 0, .kind = .emission },
        .{ .ir_node = 3, .code_start = 1, .code_len = 5, .target_ir = 3, .target_offset = 1, .scope_ir_node = 2, .kind = .emission },
    };
    var evidence = fixture.evidence;
    evidence[0] = .{ .obligation_index = 0, .edge = .not_established, .rule = null, .node_id = 0, .aux = 0 };
    var parts = fixture.parts();
    parts.ir = &ir;
    parts.translation = &translation;
    parts.evidence = &evidence;
    parts.identity.ir_root = cert_mod.irRootFromNodes(&ir);
    for (&fixture.members) |*member| {
        if (member.kind == .proof_ir) member.digest = parts.identity.ir_root;
    }
    fixture.len = try encodeBoundTestParts(&fixture.buffer, parts, &fixture.members);
    var policy = policy_mod.production;
    const required = [_]policy_mod.Requirement{.{ .property = .results_checked, .min_grade = .tested }};
    policy.required = &required;
    const result = check(fixture.inputs(), policy);
    try testing.expectEqual(SemanticState.policy_accepted, result.semantic);
    try testing.expect(result.rejection == null);
}

test "duplicate translation witnesses reject" {
    var fixture = try test_support.build();
    const witnesses = [_]cert_mod.Witness{ fixture.witnesses[0], fixture.witnesses[0] };
    var parts = fixture.parts();
    parts.translation = &witnesses;
    try fixture.encodeParts(parts);
    try expectAt(check(fixture.inputs(), policy_mod.production), .translation_check, .witness_range_overlaps);
}

test "a translation scope must name a function" {
    var fixture = try test_support.build();
    fixture.witnesses[1].scope_ir_node = 1;
    try fixture.encode();
    try expectAt(check(fixture.inputs(), policy_mod.production), .translation_check, .witness_range_out_of_bounds);
}

test "a property the producer did not establish is refused by a policy that requires it" {
    var fixture = try test_support.build();
    // Index 3 answers `results_checked`, which the production policy requires.
    fixture.evidence[3].edge = .not_established;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.policy, result.rejection.?.stage);
    try testing.expectEqual(
        verdict.ReasonCode.required_property_not_established,
        result.rejection.?.code,
    );
    // The proof was still checked; it is the policy that said no.
    try testing.expectEqual(SemanticState.proof_checked, result.semantic);
}

test "a property a policy does not require may go unestablished" {
    var fixture = try test_support.build();
    // `read_only` is answered "no", and no shipped policy requires it.
    fixture.evidence[8].edge = .not_established;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(result.accepted());
}

test "a grade below the policy floor rejects and says both sides" {
    var fixture = try test_support.build();
    // The checked translation still depends on trusted opcode meaning, so a
    // policy that demands translation-validated totality must reject it.

    const requirements = [_]policy_mod.Requirement{
        .{ .property = .response_total, .min_grade = .translation_validated },
    };
    const strict = Policy{
        .proof_systems = policy_mod.production.proof_systems,
        .semantics_epochs = policy_mod.production.semantics_epochs,
        .required = &requirements,
    };
    const result = check(fixture.inputs(), strict);
    try testing.expectEqual(verdict.ReasonCode.grade_below_floor, result.rejection.?.code);
    try testing.expectEqual(
        @as(u64, verdict.AssuranceGrade.translation_validated.toWire()),
        result.rejection.?.expected.?.scalar,
    );
    try testing.expectEqual(
        @as(u64, verdict.AssuranceGrade.trusted.toWire()),
        result.rejection.?.actual.?.scalar,
    );
}

test "declared trusted opcode dependencies cap translation assurance" {
    var fixture = try test_support.build();
    const requirements = [_]policy_mod.Requirement{
        .{ .property = .response_total, .min_grade = .translation_validated },
    };
    const translation_only = Policy{
        .proof_systems = policy_mod.production.proof_systems,
        .semantics_epochs = policy_mod.production.semantics_epochs,
        .required = &requirements,
    };

    const result = check(fixture.inputs(), translation_only);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.ReasonCode.grade_below_floor, result.rejection.?.code);
    try testing.expectEqual(
        @as(u64, verdict.AssuranceGrade.trusted.toWire()),
        result.rejection.?.actual.?.scalar,
    );
}

test "a declared edge that is not disclosed in the trusted inventory rejects" {
    var fixture = try test_support.build();
    fixture.evidence[0].edge = .trusted;
    fixture.evidence[0].rule = null;
    fixture.evidence[0].node_id = 1;
    // The inventory still only mentions the opcode edge, not node 1.
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.trusted_edge_undeclared, result.rejection.?.code);
}

test "trusted evidence at a node the proof IR does not have rejects" {
    // A trusted edge carries no rule, so it never reaches the rule path's node
    // bound. The inventory disclosing the same absent node does not make it
    // real: the disclosure has to point at something the consumer can see.
    var fixture = try test_support.build();
    const absent: u32 = @intCast(fixture.parts().ir.len);
    fixture.evidence[0] = .{
        .obligation_index = 0,
        .edge = .trusted,
        .rule = null,
        .node_id = absent,
        .aux = 0,
    };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .node, .member_id = @intCast(absent), .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.trusted = &trusted;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.proof_node_unknown, result.rejection.?.code);
    try testing.expectEqual(absent, result.rejection.?.subject.ir_node);
}

test "trusted evidence does not match an inventory node that differs above sixteen bits" {
    // The inventory stores a node as u16 and evidence names it as u32. A node
    // that differs only above bit 15 is a different node, not a disclosed one.
    var fixture = try test_support.build();
    fixture.evidence[0] = .{
        .obligation_index = 0,
        .edge = .trusted,
        .rule = null,
        .node_id = 0x1_0000,
        .aux = 0,
    };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.trusted = &trusted;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.ReasonCode.proof_node_unknown, result.rejection.?.code);
    try testing.expectEqual(@as(u32, 0x1_0000), result.rejection.?.subject.ir_node);
}

test "an inventory node the proof IR does not have rejects" {
    var fixture = try test_support.build();
    const absent: u16 = @intCast(fixture.parts().ir.len);
    fixture.evidence[0] = .{
        .obligation_index = 0,
        .edge = .trusted,
        .rule = null,
        .node_id = 0,
        .aux = 0,
    };
    const trusted = [_]cert_mod.TrustedEdge{
        .{ .family = .node, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .node, .member_id = absent, .reason = .not_modeled, .grade = .trusted },
        .{ .family = .opcode, .member_id = 0, .reason = .not_modeled, .grade = .trusted },
    };
    var parts = fixture.parts();
    parts.trusted = &trusted;
    try fixture.encodeParts(parts);

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.proof_node_unknown, result.rejection.?.code);
    try testing.expectEqual(@as(u32, absent), result.rejection.?.subject.ir_node);
}

test "a solver edge is refused unless the consumer asked for one" {
    var fixture = try test_support.build();
    fixture.evidence[1].edge = .solver;
    fixture.evidence[1].rule = null;
    var parts = fixture.parts();
    const queries = [_]cert_mod.SolverQuery{
        .{ .obligation_index = 0, .query_kind = .opcode_equivalence },
    };
    parts.solver = &queries;
    try fixture.encodeParts(parts);

    var result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.solver, result.rejection.?.stage);
    try testing.expectEqual(verdict.ReasonCode.solver_edge_not_permitted, result.rejection.?.code);

    // Permitted, but nobody ran a solver. Silence is not a yes.
    var permissive = policy_mod.production;
    permissive.allow_solver_edges = true;
    result = check(fixture.inputs(), permissive);
    try testing.expectEqual(verdict.ReasonCode.solver_inconclusive, result.rejection.?.code);

    // An adapter that ran and could not decide is also not a yes.
    var inputs = fixture.inputs();
    const inconclusive = [_]bool{false};
    inputs.solver_results = &inconclusive;
    result = check(inputs, permissive);
    try testing.expectEqual(verdict.ReasonCode.solver_inconclusive, result.rejection.?.code);

    // Discharged. The edge now grades, and it grades weaker than a proof.
    const discharged = [_]bool{true};
    inputs.solver_results = &discharged;
    result = check(inputs, permissive);
    try testing.expect(result.accepted());
    try testing.expectEqual(@as(?verdict.AssuranceGrade, .trusted), result.grade);

    // A query index outside the certificate's own solver section is refused
    // before any result is consulted.
    fixture.evidence[1].aux = 7;
    parts = fixture.parts();
    parts.solver = &queries;
    try fixture.encodeParts(parts);
    var wide = fixture.inputs();
    wide.solver_results = &discharged;
    result = check(wide, permissive);
    try testing.expectEqual(verdict.ReasonCode.solver_query_too_large, result.rejection.?.code);
}

test "a solver answer cannot discharge a different obligation" {
    var fixture = try test_support.build();
    fixture.evidence[1] = .{
        .obligation_index = 0,
        .edge = .solver,
        .rule = null,
        .node_id = 0,
        .aux = 0,
    };
    var parts = fixture.parts();
    const queries = [_]cert_mod.SolverQuery{
        .{ .obligation_index = 1, .query_kind = .opcode_equivalence },
    };
    parts.solver = &queries;
    try fixture.encodeParts(parts);

    const requirements = [_]policy_mod.Requirement{
        .{ .property = .response_total, .min_grade = .trusted },
    };
    const solver_policy = Policy{
        .proof_systems = policy_mod.production.proof_systems,
        .semantics_epochs = policy_mod.production.semantics_epochs,
        .required = &requirements,
        .allow_solver_edges = true,
    };
    const discharged = [_]bool{true};
    var inputs = fixture.inputs();
    inputs.solver_results = &discharged;

    const result = check(inputs, solver_policy);
    try testing.expectEqual(verdict.ReasonCode.solver_query_mismatch, result.rejection.?.code);
    try testing.expectEqual(verdict.Stage.solver, result.rejection.?.stage);
}

test "a solver query index at the section bound rejects" {
    var fixture = try test_support.build();
    fixture.evidence[1].edge = .solver;
    fixture.evidence[1].rule = null;
    fixture.evidence[1].aux = 1;
    const queries = [_]cert_mod.SolverQuery{.{ .obligation_index = 0, .query_kind = .opcode_equivalence }};
    var parts = fixture.parts();
    parts.solver = &queries;
    try fixture.encodeParts(parts);
    var policy = policy_mod.production;
    policy.allow_solver_edges = true;
    try expectAt(check(fixture.inputs(), policy), .solver, .solver_query_too_large);
}

test "a development artifact is checked and never accepted for production" {
    var fixture = try test_support.build();
    var parts = fixture.parts();
    parts.identity.development = true;
    try fixture.encodeParts(parts);

    const strict = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.development_artifact_refused, strict.rejection.?.code);
    try testing.expectEqual(SemanticState.proof_checked, strict.semantic);
    // It was still checked, and the grade it reached is reported.
    try testing.expect(strict.grade != null);

    var permissive = policy_mod.development;
    permissive.required = policy_mod.production.required;
    const local = check(fixture.inputs(), permissive);
    try testing.expect(local.accepted());
    try testing.expect(local.development_only);
}

test "scratch smaller than the kernel needs is refused rather than truncated" {
    var fixture = try test_support.build();
    var inputs = fixture.inputs();
    inputs.scratch = fixture.scratch[0..8];
    const result = check(inputs, policy_mod.production);
    try testing.expectEqual(verdict.Stage.limits, result.rejection.?.stage);
    try testing.expect(!result.rejection.?.recertifiable);
}

test "scratchBytes covers three bits per node at the configured bound" {
    const needed = scratchBytes(.{ .max_ir_nodes = 64, .max_witnesses = 4 });
    try testing.expectEqual(@as(usize, 184), needed);
    try testing.expect(scratchBytes(.{}) > 0);
}

/// The minimal accepted artifact plus `extra` tool catalog members, one per
/// ordinal from zero, each carrying the digest of `catalog`.
fn CatalogFixture(comptime extra: usize) type {
    return BindingFixture(extra, 0);
}

/// The minimal accepted artifact plus `extra` declaration members, one per
/// ordinal from zero, each carrying the digest of `declarationBytes`.
fn DeclarationFixture(comptime extra: usize) type {
    return BindingFixture(0, extra);
}

/// The minimal accepted artifact plus `catalogs` tool catalog members and
/// `declarations` declaration members, one per ordinal from zero within each
/// kind. `inputs` supplies the catalog bytes when `catalogs` is not zero, and
/// the declaration bytes when `declarations` is not zero.
fn BindingFixture(comptime catalogs: usize, comptime declarations: usize) type {
    return struct {
        const Self = @This();

        base: test_support.Fixture,
        members: [9 + catalogs + declarations]graph.Member,
        catalog_buf: [1024]u8 = undefined,
        catalog_len: usize = 0,
        declaration_buf: [1024]u8 = undefined,
        declaration_len: usize = 0,
        buffer: [8192]u8 = undefined,
        len: usize = 0,

        fn catalog(self: *const Self) []const u8 {
            return self.catalog_buf[0..self.catalog_len];
        }

        fn declarationBytes(self: *const Self) []const u8 {
            return self.declaration_buf[0..self.declaration_len];
        }

        fn encode(self: *Self) !void {
            for (&self.members) |*member| {
                if (member.kind == .proof_certificate) member.digest = [_]u8{0} ** 32;
            }
            std.mem.sort(graph.Member, &self.members, {}, struct {
                fn lessThan(_: void, a: graph.Member, b: graph.Member) bool {
                    return graph.Member.order(a, b) == .lt;
                }
            }.lessThan);
            var built = self.base.parts();
            built.graph = &self.members;
            built.identity.executable_root = [_]u8{0} ** 32;
            const provisional = try cert_mod.encode(built, &self.buffer);
            var budget = Budget.init(.{});
            const decoded = try cert_mod.decode(provisional, .{}, &budget);
            const certificate_digest = try cert_mod.commitmentDigest(provisional, decoded);
            for (&self.members) |*member| {
                if (member.kind == .proof_certificate) member.digest = certificate_digest;
            }
            built.identity.executable_root = try graph.computeRoot(&self.members);
            self.len = (try cert_mod.encode(built, &self.buffer)).len;
        }

        fn inputs(self: *Self) Inputs {
            return .{
                .certificate = self.buffer[0..self.len],
                .observed_graph = &self.members,
                .scratch = &self.base.scratch,
                .tool_catalog = if (catalogs == 0) null else self.catalog(),
                .declaration = if (declarations == 0) null else self.declarationBytes(),
            };
        }

        fn build() !Self {
            var self = Self{ .base = try test_support.build(), .members = undefined };
            self.catalog_len = tool_catalog.test_support.sample(&self.catalog_buf).len;
            self.declaration_len = declaration.test_support.sample(&self.declaration_buf).len;
            const catalog_digest = tool_catalog.digest(self.catalog());
            const declaration_digest = declaration.digest(self.declarationBytes());
            @memcpy(self.members[0..9], &self.base.members);
            for (0..catalogs) |ordinal| {
                self.members[9 + ordinal] = .{ .kind = .tool_catalog, .ordinal = @intCast(ordinal), .digest = catalog_digest };
            }
            for (0..declarations) |ordinal| {
                self.members[9 + catalogs + ordinal] = .{ .kind = .declaration, .ordinal = @intCast(ordinal), .digest = declaration_digest };
            }
            try self.encode();
            return self;
        }
    };
}

fn expectRejected(result: Assessment, code: verdict.ReasonCode) !void {
    const rejection = result.rejection orelse {
        std.debug.print("expected {s}, accepted\n", .{code.text()});
        return error.TestUnexpectedResult;
    };
    if (rejection.code != code) {
        std.debug.print("expected {s}, got {s} / {s}\n", .{ code.text(), rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
}

test "a tool catalog matching its graph member is accepted" {
    var fixture = try CatalogFixture(1).build();
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected rejection: {s} / {s}\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
}

test "one mutated catalog byte rejects with tool_catalog_digest_mismatch" {
    var fixture = try CatalogFixture(1).build();
    var tampered: [1024]u8 = undefined;
    const original = fixture.catalog();
    @memcpy(tampered[0..original.len], original);
    // A byte inside the first description: the bytes still decode, so only the
    // digest can refuse them.
    const at = std.mem.indexOf(u8, original, "Echo the input").?;
    tampered[at] = 'e';
    var inputs = fixture.inputs();
    inputs.tool_catalog = tampered[0..original.len];
    const result = check(inputs, policy_mod.production);
    try expectRejected(result, .tool_catalog_digest_mismatch);
    try testing.expectEqual(verdict.Stage.tool_catalog, result.rejection.?.stage);
}

test "a graph member naming another catalog digest rejects" {
    var fixture = try CatalogFixture(1).build();
    for (&fixture.members) |*member| {
        if (member.kind == .tool_catalog) member.digest[0] +%= 1;
    }
    try fixture.encode();
    try expectRejected(check(fixture.inputs(), policy_mod.production), .tool_catalog_digest_mismatch);
}

test "a second tool catalog member rejects" {
    var fixture = try CatalogFixture(2).build();
    try expectRejected(check(fixture.inputs(), policy_mod.production), .tool_catalog_digest_mismatch);
}

test "catalog bytes with no graph member reject" {
    var fixture = try test_support.build();
    var buf: [1024]u8 = undefined;
    var inputs = fixture.inputs();
    inputs.tool_catalog = tool_catalog.test_support.sample(&buf);
    try expectRejected(check(inputs, policy_mod.production), .tool_catalog_member_missing);
}

test "a tool catalog member with no catalog bytes rejects" {
    var fixture = try CatalogFixture(1).build();
    var inputs = fixture.inputs();
    inputs.tool_catalog = null;
    try expectRejected(check(inputs, policy_mod.production), .tool_catalog_member_missing);
}

test "undecodable catalog bytes reject before the digest is compared" {
    var fixture = try CatalogFixture(1).build();
    var inputs = fixture.inputs();
    inputs.tool_catalog = "ZTCAT1\x00\x00\x01\x00\x00\x00";
    try expectRejected(check(inputs, policy_mod.production), .tool_catalog_undecodable);
}

test "every tool catalog reason code is observed" {
    var seen = std.EnumSet(verdict.ReasonCode).initEmpty();

    var matching = try CatalogFixture(1).build();
    var buf: [1024]u8 = undefined;

    var mutated = matching.inputs();
    var tampered: [1024]u8 = undefined;
    const original = matching.catalog();
    @memcpy(tampered[0..original.len], original);
    tampered[std.mem.indexOf(u8, original, "Echo the input").?] = 'e';
    mutated.tool_catalog = tampered[0..original.len];

    var no_bytes = matching.inputs();
    no_bytes.tool_catalog = null;

    var undecodable = matching.inputs();
    undecodable.tool_catalog = "not a catalog";

    var plain = try test_support.build();
    var no_member = plain.inputs();
    no_member.tool_catalog = tool_catalog.test_support.sample(&buf);

    for ([_]Inputs{ mutated, no_bytes, undecodable, no_member }) |inputs| {
        const result = check(inputs, policy_mod.production);
        if (result.rejection) |rejection| seen.insert(rejection.code);
    }

    inline for (@typeInfo(verdict.ReasonCode).@"enum".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "tool_catalog_")) {
            const code: verdict.ReasonCode = @enumFromInt(field.value);
            if (!seen.contains(code)) {
                std.debug.print("{s} is never observed\n", .{field.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "an artifact with no declaration and no declaration member passes the declaration stage" {
    var fixture = try test_support.build();
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected rejection: {s} / {s}\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
}

test "a declaration matching its graph member is accepted" {
    var fixture = try DeclarationFixture(1).build();
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected rejection: {s} / {s}\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
}

test "a tool catalog and a declaration each matching their member are accepted" {
    var fixture = try BindingFixture(1, 1).build();
    const result = check(fixture.inputs(), policy_mod.production);
    if (result.rejection) |rejection| {
        std.debug.print("unexpected rejection: {s} / {s}\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expect(result.accepted());
}

/// The fixture's declaration with one byte of a reason changed. The bytes
/// still decode, so only the digest can refuse them.
fn tamperedDeclaration(original: []const u8, out: *[1024]u8) []const u8 {
    @memcpy(out[0..original.len], original);
    const at = std.mem.indexOf(u8, original, "Payment token.").?;
    out[at] = 'p';
    return out[0..original.len];
}

test "one mutated declaration byte rejects with declaration_digest_mismatch" {
    var fixture = try DeclarationFixture(1).build();
    var tampered: [1024]u8 = undefined;
    var inputs = fixture.inputs();
    inputs.declaration = tamperedDeclaration(fixture.declarationBytes(), &tampered);
    _ = try declaration.decode(inputs.declaration.?);
    const result = check(inputs, policy_mod.production);
    try expectRejected(result, .declaration_digest_mismatch);
    try testing.expectEqual(verdict.Stage.declaration, result.rejection.?.stage);
}

test "a graph member naming another declaration digest rejects" {
    var fixture = try DeclarationFixture(1).build();
    for (&fixture.members) |*member| {
        if (member.kind == .declaration) member.digest[0] +%= 1;
    }
    try fixture.encode();
    try expectRejected(check(fixture.inputs(), policy_mod.production), .declaration_digest_mismatch);
}

test "a second declaration member rejects" {
    var fixture = try DeclarationFixture(2).build();
    try expectRejected(check(fixture.inputs(), policy_mod.production), .declaration_digest_mismatch);
}

test "declaration bytes with no graph member reject" {
    var fixture = try test_support.build();
    var buf: [1024]u8 = undefined;
    var inputs = fixture.inputs();
    inputs.declaration = declaration.test_support.sample(&buf);
    const result = check(inputs, policy_mod.production);
    try expectRejected(result, .declaration_member_missing);
    try testing.expectEqual(verdict.Stage.declaration, result.rejection.?.stage);
}

test "a declaration member with no declaration bytes rejects and names the member" {
    var fixture = try DeclarationFixture(1).build();
    var inputs = fixture.inputs();
    inputs.declaration = null;
    const result = check(inputs, policy_mod.production);
    try expectRejected(result, .declaration_member_missing);
    try testing.expectEqual(verdict.Stage.declaration, result.rejection.?.stage);
    try testing.expectEqual(verdict.Subject{ .graph_member = .{
        .kind = @intFromEnum(graph.MemberKind.declaration),
        .ordinal = 0,
    } }, result.rejection.?.subject);
}

test "undecodable declaration bytes reject before the digest is compared" {
    var fixture = try DeclarationFixture(1).build();
    var inputs = fixture.inputs();
    inputs.declaration = "ZTDCL1\x00\x00\x01\x00\x00\x00\x00";
    try expectRejected(check(inputs, policy_mod.production), .declaration_undecodable);
}

test "every declaration reason code is observed" {
    var seen = std.EnumSet(verdict.ReasonCode).initEmpty();

    var matching = try DeclarationFixture(1).build();
    var buf: [1024]u8 = undefined;

    var mutated = matching.inputs();
    var tampered: [1024]u8 = undefined;
    mutated.declaration = tamperedDeclaration(matching.declarationBytes(), &tampered);

    var no_bytes = matching.inputs();
    no_bytes.declaration = null;

    var undecodable = matching.inputs();
    undecodable.declaration = "not a declaration";

    var plain = try test_support.build();
    var no_member = plain.inputs();
    no_member.declaration = declaration.test_support.sample(&buf);

    for ([_]Inputs{ mutated, no_bytes, undecodable, no_member }) |inputs| {
        const result = check(inputs, policy_mod.production);
        if (result.rejection) |rejection| {
            try testing.expectEqual(verdict.Stage.declaration, rejection.stage);
            seen.insert(rejection.code);
        }
    }

    var codes: usize = 0;
    inline for (@typeInfo(verdict.ReasonCode).@"enum".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "declaration_")) {
            codes += 1;
            const code: verdict.ReasonCode = @enumFromInt(field.value);
            if (!seen.contains(code)) {
                std.debug.print("{s} is never observed\n", .{field.name});
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqual(@as(usize, 3), codes);
}

const ReasonProbe = enum { root_mismatch, zero_root, trailing_member, missing_evidence, fabricated_totality };

fn runReasonProbe(probe: ReasonProbe) !Assessment {
    var fixture = try test_support.build();
    switch (probe) {
        .root_mismatch => {
            var parts = fixture.parts();
            parts.identity.executable_root = test_support.digest(0x71);
            fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
            return check(fixture.inputs(), policy_mod.production);
        },
        .zero_root => {
            var parts = fixture.parts();
            parts.identity.executable_root = [_]u8{0} ** 32;
            fixture.len = (try cert_mod.encode(parts, &fixture.buffer)).len;
            return check(fixture.inputs(), policy_mod.production);
        },
        .trailing_member => {
            var members: [10]graph.Member = undefined;
            @memcpy(members[0..9], &fixture.members);
            members[9] = .{ .kind = .declaration, .ordinal = 0, .digest = test_support.digest(0x74) };
            var inputs = fixture.inputs();
            inputs.observed_graph = &members;
            return check(inputs, policy_mod.production);
        },
        .missing_evidence => {
            var parts = fixture.parts();
            parts.evidence = fixture.evidence[0..9];
            try fixture.encodeParts(parts);
            return check(fixture.inputs(), policy_mod.production);
        },
        .fabricated_totality => {
            fixture.ir[2].tag = .plain;
            fixture.evidence[0] = test_support.testedFor(0);
            try fixture.encode();
            return check(fixture.inputs(), policy_mod.production);
        },
    }
}

/// A code not in the probe table needs a named public-entry test or a closed
/// decoder mechanism here. Adding an enum member requires a new row or probe.
fn reasonAllowlist(code: verdict.ReasonCode) ?[]const u8 {
    return switch (code) {
        .executable_root_mismatch,
        .zero_commitment,
        .graph_member_extra,
        .obligation_without_evidence,
        .fabricated_property,
        => null,

        .certificate_too_large,
        .truncated_input,
        .bad_magic,
        .unknown_section_tag,
        .duplicate_section,
        .missing_required_section,
        .trailing_data,
        .section_too_large,
        .section_length_mismatch,
        .count_exceeds_limit,
        .section_not_canonically_ordered,
        .reserved_field_nonzero,
        => "certificate.test.every decode error is observed through the public decoder and reasonFor maps each error",
        .unsupported_schema_version, .unknown_enum_member => "checker tests for predecessor schema, proof system, and certificate decoder enum values pin the exact decode code",
        .work_budget_exhausted => "checker.test.a starved work budget rejects at the limits stage pins the budget result",
        .proof_depth_exceeded => "checker.test.proof IR depth is bounded by policy uses a three-deep IR and max_depth two",
        .unsupported_proof_system => "ProofSystem currently has one member; a validated nonempty policy cannot exclude it without widening that enum",
        .unsupported_semantics_epoch => "checker.test.an unsupported semantics epoch rejects supplies a different policy epoch",

        .graph_member_missing => "checker tests for a missing observed member and a required kind each pin this code",
        .graph_member_digest_mismatch => "checker.test.mutating any observed member class rejects at artifact binding checks every member class",
        .graph_member_out_of_order, .graph_member_duplicate => "checker.test.duplicate and descending graph members keep their exact reasons checks RootHasher refusals",
        .proof_ir_digest_mismatch => "checker tests for a mismatched graph member and a mismatched IR root pin both producers",
        .proof_certificate_digest_mismatch => "checker.test.a certificate graph member that differs from its commitment rejects checks the commitment",

        .obligation_missing => "checker.test.an omitted obligation rejects checks the exact count guard",
        .obligation_extra => "checker.test.an extra obligation rejects before reconstructing properties checks the count guard",
        .obligation_duplicate, .obligation_out_of_order => "checker.test.a duplicated or reordered obligation rejects checks canonical order",
        .obligation_subject_unknown => "checker.test.an obligation whose subject is not the entry function rejects checks reconstruction",
        .rule_premise_unmet => "checker tests for a missing return premise and an inapplicable cited rule pin this reason",
        .proof_node_cycle => "checker.test.a root with a nonzero parent rejects checks the root shape",
        .proof_node_unknown => "checker tests for a bad node id, wrong handler tag, and two handlers pin shape refusals",
        .trusted_edge_undeclared => "checker.test.translation cannot omit its trusted opcode dependency checks the inventory",
        .evidence_edge_invalid => "checker tests for a missing kernel rule and a nontrusted inventory grade pin this reason",
        .proof_node_parent_mismatch => "checker.test.a child whose parent disagrees with its owner rejects checks ownership",

        .witness_missing => "checker.test.translation evidence without any witness rejects checks the missing witness",
        .witness_range_overlaps => "checker tests for partial and ancestor range overlap pin this reason",
        .witness_range_out_of_bounds => "checker.test.a witness pointing outside the proof IR rejects checks bounds",
        .jump_target_mismatch => "checker.test.a jump witness naming the wrong target offset rejects checks its target",
        .rewrite_unknown => "checker.test.a rewrite with a source-level rule rejects checks the rule family",
        .rewrite_span_mismatch => "checker.test.a rewrite whose spans do not add up rejects checks both bad spans",
        .solver_edge_not_permitted, .solver_inconclusive, .solver_query_too_large => "checker.test.a solver edge is refused unless the consumer asked for one checks all three paths",
        .solver_query_mismatch => "checker.test.a solver answer cannot discharge a different obligation checks the query link",

        .required_property_not_established => "checker.test.refused evidence defeats graded evidence for the same property checks refusal dominance",
        .grade_below_floor => "checker.test.a grade below the policy floor rejects and says both sides checks the grade",
        .development_artifact_refused => "checker.test.a development artifact is checked and never accepted for production checks deployment policy",
        .proof_system_not_selected, .semantics_epoch_not_selected => "checker.test.empty policy identity sets are refused before certificate parsing checks policy validation",
        .policy_requires_nothing => "checker.test.a policy that requires nothing is refused before anything is read checks empty requirements",

        .guard_member_missing, .guard_member_extra, .guard_member_duplicate, .guard_member_out_of_order => "checker.test.an omitted, extra, duplicated, or reordered guard rejects checks the four list paths",
        .guard_kind_mismatch, .guard_normalization_mismatch, .guard_sink_mismatch, .guard_section_mismatch, .guard_impl_identity_mismatch => "checker.test.a guard that disagrees with the consumer's catalog rejects on every field checks each catalog field",
        .guard_operation_unknown => "checker.test.a guarded call naming a catalog row that does not exist rejects checks catalog bounds",
        .guard_category_not_configured => "checker.test.a guarded operation with no configured category rejects checks the policy category",
        .residual_plan_digest_mismatch => "checker.test.a residual plan that is not the one the identity names rejects checks the plan digest",
        .runtime_policy_missing => "checker.test.a guarded artifact with no policy bytes rejects rather than assuming any checks absent authority",
        .runtime_policy_undecodable => "checker.test.policy bytes that do not hash to the committed digest reject checks policy bytes",
        .guard_family_disabled => "checker.test.a fully consistent SQL guard remains disabled checks the family gate",

        .invariant_spec_missing => "checker tests for observed operations, graph members, and ledger calls on the unconfigured path pin this code",
        .invariant_spec_undecodable => "checker.test.an invariant specification that cannot decode rejects checks the spec decoder",
        .invariant_spec_digest_mismatch => "checker tests for supplied bytes without configuration and tampered spec bytes pin the digest",
        .invariant_spec_member_missing, .invariant_adapter_member_missing => "checker.test.missing invariant graph members reject independently checks both bound members",
        .invariant_adapter_identity_mismatch => "checker.test.invariant adapter, operation, sink, and implementation identities reject checks adapter identity",
        .invariant_operation_required => "checker.test.a configured artifact exhibiting no ledger operation rejects with invariant_operation_required checks emptiness",
        .invariant_member_missing => "checker.test.a second ledger call needs a witness when witness and observation counts agree checks the IR scan",
        .invariant_member_extra => "checker.test.missing and extra invariant witnesses reject checks the independent count",
        .invariant_member_duplicate, .invariant_member_out_of_order => "checker.test.duplicate and descending invariant witnesses keep distinct reasons checks canonical order",
        .invariant_operation_unknown, .invariant_sink_mismatch, .invariant_impl_identity_mismatch => "checker.test.invariant adapter, operation, sink, and implementation identities reject checks catalog comparison",
        .invariant_operation_mismatch => "checker.test.a forged invariant operation cannot borrow a real call site checks operation identity",
        .invariant_translation_missing => "checker.test.invariant call must lie within its full expression emission checks translation coverage",
        .invariant_observed_mismatch => "checker.test.an invariant witness offset must match the independent observation checks independent offsets",

        .tool_catalog_undecodable, .tool_catalog_digest_mismatch, .tool_catalog_member_missing => "checker.test.every tool catalog reason code is observed constructs each public-check rejection",
        .declaration_undecodable, .declaration_digest_mismatch, .declaration_member_missing => "checker.test.every declaration reason code is observed constructs each public-check rejection",
    };
}

test "every reason code has a public-check probe or an explained producer" {
    const probes = [_]struct { code: verdict.ReasonCode, stage: verdict.Stage, input: ReasonProbe }{
        .{ .code = .executable_root_mismatch, .stage = .artifact_binding, .input = .root_mismatch },
        .{ .code = .zero_commitment, .stage = .artifact_binding, .input = .zero_root },
        .{ .code = .graph_member_extra, .stage = .artifact_binding, .input = .trailing_member },
        .{ .code = .obligation_without_evidence, .stage = .evidence_check, .input = .missing_evidence },
        .{ .code = .fabricated_property, .stage = .evidence_check, .input = .fabricated_totality },
    };
    var probed = std.EnumSet(verdict.ReasonCode).initEmpty();
    for (probes) |probe| {
        try testing.expect(!probed.contains(probe.code));
        try expectAt(try runReasonProbe(probe.input), probe.stage, probe.code);
        probed.insert(probe.code);
    }
    inline for (std.meta.fields(verdict.ReasonCode)) |field| {
        const code: verdict.ReasonCode = @enumFromInt(field.value);
        if (reasonAllowlist(code)) |mechanism| {
            try testing.expect(mechanism.len > 0);
            try testing.expect(!probed.contains(code));
        } else {
            try testing.expect(probed.contains(code));
        }
    }
}
