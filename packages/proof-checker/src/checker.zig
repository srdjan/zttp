//! The acceptance kernel.
//!
//! Everything here is work the consumer does for itself. It reads the
//! certificate as data, recomputes what the certificate claims, and compares.
//! It never reads a producer verdict, never touches the filesystem, the clock,
//! the network, or a signer, and never allocates.

const std = @import("std");

const cert_mod = @import("certificate.zig");
const graph = @import("executable_graph.zig");
const limits_mod = @import("limits.zig");
const policy_mod = @import("policy.zig");
const ps = @import("proof_system.zig");
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
    return irBitBytes(limits) * 2 + depthBytes(limits) + rangeStackBytes(limits);
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
                error.EmptyProofSystemSet, error.DuplicateRequirement => .proof_system_not_selected,
                error.EmptyEpochSet => .semantics_epoch_not_selected,
            },
            .recertifiable = false,
        });
    };

    const certificate = cert_mod.decode(inputs.certificate, limits, &budget) catch |err| {
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
    const depth_start = bit_bytes * 2;
    const range_start = depth_start + depthBytes(limits);
    var session = Session{
        .certificate = certificate,
        .policy = policy,
        .solver_results = inputs.solver_results,
        .budget = &budget,
        .total = BitSet.init(inputs.scratch[0..bit_bytes]),
        .declared = BitSet.init(inputs.scratch[bit_bytes..depth_start]),
        .depths = .{ .bytes = inputs.scratch[depth_start..range_start] },
        .active_ranges = .{ .bytes = inputs.scratch[range_start..] },
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
    };
}

const Outcome = struct {
    state: SemanticState,
    grade: ?verdict.AssuranceGrade = null,
    rejection: ?Rejection = null,
    properties: verdict.PropertyVerdicts = .{},
    disclosed_edges: u32 = 0,
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
    policy: Policy,
    solver_results: []const bool,
    budget: *Budget,
    total: BitSet,
    declared: BitSet,
    depths: DepthTable,
    active_ranges: RangeStack,

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

        return self.checkEvidence();
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
                .loop_node, .plain => false,
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
            .function, .plain => null,
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
                if (entry.node_id >= self.certificate.ir.len()) {
                    return reject(.evidence_check, .proof_node_unknown, .{ .ir_node = entry.node_id });
                }
                const node = try self.certificate.ir.get(entry.node_id);
                switch (rule.family()) {
                    .totality => {
                        if (obligation.property != .response_total) {
                            return reject(.evidence_check, .rule_family_mismatch, .{ .rule = rule });
                        }
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
                        if (entry.edge != .translation_validated) {
                            return reject(.evidence_check, .rule_family_mismatch, .{ .rule = rule });
                        }
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
            if (edge.family == .node and edge.member_id == @as(u16, @truncate(node_id))) return true;
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
        .proof_systems = &[_]ps.ProofSystem{.zttp_pcc_v1},
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

test "a fabricated totality claim is refused, and it is not recertifiable" {
    var fixture = try test_support.build();
    // The handler no longer returns on any path; the certificate still claims
    // it does.
    fixture.ir[2].tag = .plain;
    try fixture.encode();

    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
    // The cited rule stops applying first, which is the same refusal one step
    // earlier: either way the consumer never takes the producer's word.
    try testing.expect(result.rejection.?.code == .rule_premise_unmet or
        result.rejection.?.code == .fabricated_property);
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
    try testing.expect(!result.accepted());
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
    try testing.expect(result.rejection.?.code == .proof_node_cycle or
        result.rejection.?.code == .proof_node_parent_mismatch);

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
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.evidence_check, result.rejection.?.stage);
}

test "proof IR depth is bounded by policy" {
    var fixture = try test_support.build();
    var shallow = policy_mod.production;
    shallow.limits.max_depth = 1;

    const result = check(fixture.inputs(), shallow);
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.limits, result.rejection.?.stage);
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

test "a witness pointing outside the proof IR rejects" {
    var fixture = try test_support.build();
    fixture.witnesses[0].ir_node = 99;
    try fixture.encode();
    const result = check(fixture.inputs(), policy_mod.production);
    try testing.expectEqual(verdict.ReasonCode.witness_range_out_of_bounds, result.rejection.?.code);
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
    try testing.expect(!result.accepted());
    try testing.expectEqual(verdict.Stage.solver, result.rejection.?.stage);
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

test "scratchBytes covers two bits per node at the configured bound" {
    const needed = scratchBytes(.{ .max_ir_nodes = 64, .max_witnesses = 4 });
    try testing.expectEqual(@as(usize, 176), needed);
    try testing.expect(scratchBytes(.{}) > 0);
}
