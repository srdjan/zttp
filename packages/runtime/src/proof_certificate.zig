//! Assembling a proof certificate from what the compiler produced.
//!
//! This is the producer side of the boundary. It reads the compiler's proof IR,
//! its translation witnesses, and the properties the contract says were
//! discharged, and writes them into the acceptance kernel's wire format. It
//! decides nothing: every claim here is a statement the consumer re-derives or
//! grades, and a property the compiler did not discharge is written down as not
//! established rather than left out.
//!
//! The kernel's record types are used directly rather than mirrored, so a
//! schema change is a compile error here instead of a certificate the consumer
//! rejects at run time.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const artifact_graph = @import("artifact_graph.zig");

const cert = pcc.certificate;
const graph = pcc.executable_graph;
const ps = pcc.proof_system;

pub const Error = error{
    OutOfMemory,
    BufferTooSmall,
    /// The proof IR carries no function, so there is no entry function for the
    /// totality obligation to be about.
    NoEntryFunction,
    TooManyMembers,
    TooManyFunctions,
    MalformedBytecodeStream,
    EmptyGraph,
    NotOrdered,
    DuplicateMember,
    MissingRequiredKind,
    ZeroCommitment,
};

/// What the contract says the compiler discharged. Read once, at the call site
/// that holds the contract, so this file never reaches into contract shapes.
pub const DischargedProperties = struct {
    results_checked: bool = false,
    no_secret_leakage: bool = false,
    state_isolated: bool = false,
    deterministic: bool = false,
    read_only: bool = false,
    retry_safe: bool = false,
    capability_bounded: bool = false,

    pub fn holds(self: DischargedProperties, property: ps.Property) bool {
        return switch (property) {
            // Totality is decided from the proof IR, not from a contract field.
            .response_total => false,
            .results_checked => self.results_checked,
            .no_secret_leakage => self.no_secret_leakage,
            .state_isolated => self.state_isolated,
            .deterministic => self.deterministic,
            .read_only => self.read_only,
            .retry_safe => self.retry_safe,
            .capability_bounded => self.capability_bounded,
        };
    }
};

pub const Inputs = struct {
    evidence: *const zts.ProofEvidence,
    properties: DischargedProperties,
    /// The artifact sections, minus the proof IR member, which this file
    /// computes and adds.
    artifact: artifact_graph.ArtifactInputs,
    /// Digest of the serialized contract, for the identity section.
    contract_digest: [32]u8,
    /// The artifact was built with an ephemeral identity or an unpinned runtime
    /// policy.
    development: bool = false,
};

pub const Built = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    members: []graph.Member,
    executable_root: [32]u8,
    ir_root: [32]u8,
    certificate_digest: [32]u8,

    pub fn deinit(self: *Built) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.members);
    }
};

fn irNodes(allocator: std.mem.Allocator, evidence: *const zts.ProofEvidence) Error![]cert.IrNode {
    const nodes = try allocator.alloc(cert.IrNode, evidence.proof.nodes.len);
    errdefer allocator.free(nodes);
    for (evidence.proof.nodes, 0..) |node, index| {
        nodes[index] = .{
            .id = node.id,
            .tag = tagFor(node.tag),
            .is_handler = if (evidence.proof.handler_function) |handler| handler == node.id else false,
            .parent = node.parent,
            .first_child = node.first_child,
            .child_count = node.child_count,
            .digest = node.digest,
        };
    }
    return nodes;
}

/// The compiler's lowering alphabet and the kernel's are the same alphabet with
/// two definitions. This switch is exhaustive on both sides, so adding a tag to
/// one without the other is a compile error rather than a silent remap.
fn tagFor(tag: zts.ProofIrTag) ps.NodeTag {
    return switch (tag) {
        .function => .function,
        .sequence => .sequence,
        .branch => .branch,
        .loop_node => .loop_node,
        .return_node => .return_node,
        .plain => .plain,
    };
}

fn ruleFor(rule: zts.ProofRule) ps.Rule {
    return switch (rule) {
        .return_total => .return_total,
        .branch_both_arms_total => .branch_both_arms_total,
        .sequence_member_total => .sequence_member_total,
        .loop_never_total => .loop_never_total,
    };
}

fn rewriteRuleFor(kind: zts.TranslationRewriteKind) ps.Rule {
    return switch (kind) {
        .get_loc_add,
        .get_loc_get_loc_add,
        .push_const_call,
        .get_field_call,
        .if_false_goto,
        .drop_goto,
        => .rewrite_peephole_fusion,
        .compaction => .rewrite_compaction,
    };
}

const ObligationBuilder = struct {
    allocator: std.mem.Allocator,
    obligations: std.ArrayList(cert.Obligation) = .empty,
    evidence: std.ArrayList(cert.Evidence) = .empty,

    fn deinit(self: *ObligationBuilder) void {
        self.obligations.deinit(self.allocator);
        self.evidence.deinit(self.allocator);
    }

    fn index(self: *ObligationBuilder) u32 {
        return @intCast(self.obligations.items.len - 1);
    }

    fn add(self: *ObligationBuilder, obligation: cert.Obligation) Error!void {
        try self.obligations.append(self.allocator, obligation);
    }

    fn note(self: *ObligationBuilder, entry: cert.Evidence) Error!void {
        try self.evidence.append(self.allocator, entry);
    }
};

/// Build and encode the certificate for one compiled handler.
pub fn build(allocator: std.mem.Allocator, inputs: Inputs) Error!Built {
    const nodes = try irNodes(allocator, inputs.evidence);
    defer allocator.free(nodes);

    const entry = inputs.evidence.proof.handler_function orelse return error.NoEntryFunction;
    if (entry >= nodes.len or nodes[entry].tag != .function) return error.NoEntryFunction;
    const ir_root = cert.irRootFromNodes(nodes);

    var artifact = inputs.artifact;
    artifact.proof_ir_digest = ir_root;
    artifact.proof_certificate_digest = [_]u8{0} ** 32;
    const members = try allocator.alloc(graph.Member, artifact_graph.max_members);
    errdefer allocator.free(members);
    const built_members = try artifact_graph.build(allocator, artifact_graph.fromArtifact(artifact), members);

    var builder = ObligationBuilder{ .allocator = allocator };
    defer builder.deinit();

    // Obligations are reconstructed by the consumer from the proof system's own
    // rules, so the producer emits the whole alphabet in canonical order. A
    // consumer policy can raise the bar on any of them; it cannot shrink the
    // set, because a set a policy could shrink is a set a producer could
    // arrange to have shrunk.
    inline for (@typeInfo(ps.Property).@"enum".fields) |field| {
        const property: ps.Property = @enumFromInt(field.value);
        if (property.subjectIsEntryFunction()) {
            try builder.add(.{
                .property = property,
                .subject_kind = .function,
                .subject_id = entry,
            });
            try appendTotalityEvidence(&builder, inputs.evidence, nodes, entry);
        } else {
            try builder.add(.{
                .property = property,
                .subject_kind = .handler,
                .subject_id = 0,
            });
            try builder.note(.{
                .obligation_index = builder.index(),
                .edge = if (inputs.properties.holds(property)) .tested else .not_established,
                .rule = null,
                .node_id = 0,
                .aux = 0,
            });
        }
    }

    std.mem.sort(cert.Obligation, builder.obligations.items, {}, struct {
        fn lt(_: void, a: cert.Obligation, b: cert.Obligation) bool {
            return cert.Obligation.order(a, b) == .lt;
        }
    }.lt);

    const witnesses = try translationWitnesses(allocator, inputs.evidence);
    defer allocator.free(witnesses);
    const rewrites = try rewriteRecords(allocator, inputs.evidence);
    defer allocator.free(rewrites);
    const trusted = try trustedEdges(allocator, inputs.evidence);
    defer allocator.free(trusted);

    var parts = cert.Parts{
        .identity = .{
            .executable_root = [_]u8{0} ** 32,
            .ir_root = ir_root,
            .contract_digest = inputs.contract_digest,
            .development = inputs.development,
        },
        .graph = built_members,
        .obligations = builder.obligations.items,
        .ir = nodes,
        .evidence = builder.evidence.items,
        .translation = witnesses,
        .rewrites = rewrites,
        .trusted = trusted,
    };

    const bytes = try allocator.alloc(u8, cert.encodedSize(parts));
    errdefer allocator.free(bytes);

    // Encode once with both self-references zeroed. The resulting commitment
    // covers every certificate section, then becomes an executable-graph
    // member. A second canonical encoding writes that graph root into identity.
    const provisional = try cert.encode(parts, bytes);
    var budget = pcc.limits.Budget.init(.{});
    const decoded = cert.decode(provisional, .{}, &budget) catch unreachable;
    const certificate_digest = cert.commitmentDigest(provisional, decoded) catch unreachable;

    var found_certificate_member = false;
    for (built_members) |*member| {
        if (member.kind != .proof_certificate) continue;
        member.digest = certificate_digest;
        found_certificate_member = true;
    }
    if (!found_certificate_member) return error.MissingRequiredKind;

    const executable_root = try graph.computeRoot(built_members);
    parts.identity.executable_root = executable_root;
    const encoded = try cert.encode(parts, bytes);

    const owned_members = try allocator.alloc(graph.Member, built_members.len);
    @memcpy(owned_members, built_members);
    allocator.free(members);

    return .{
        .allocator = allocator,
        .bytes = bytes[0..encoded.len],
        .members = owned_members,
        .executable_root = executable_root,
        .ir_root = ir_root,
        .certificate_digest = certificate_digest,
    };
}

fn appendTotalityEvidence(
    builder: *ObligationBuilder,
    evidence: *const zts.ProofEvidence,
    nodes: []const cert.IrNode,
    entry: u32,
) Error!void {
    const obligation = builder.index();

    if (!evidence.handlerIsTotal()) {
        try builder.note(.{
            .obligation_index = obligation,
            .edge = .not_established,
            .rule = null,
            .node_id = entry,
            .aux = 0,
        });
        return;
    }

    // The rule that closes the entry function's body. The consumer re-derives
    // the whole fold; this names where the producer thinks it lands, so a
    // producer that cites the wrong rule is caught even when the fold agrees.
    const body = nodes[entry].first_child;
    if (zts.compilerProofRuleAt(evidence.proof, evidence.total, body)) |rule| {
        try builder.note(.{
            .obligation_index = obligation,
            .edge = .proved,
            .rule = ruleFor(rule),
            .node_id = body,
            .aux = 0,
        });
    }

    // Every node whose totality is declared rather than derived. Each one caps
    // the grade for this obligation.
    for (evidence.declared) |declared| {
        try builder.note(.{
            .obligation_index = obligation,
            .edge = .trusted,
            .rule = null,
            .node_id = declared,
            .aux = 0,
        });
    }

    if (evidence.emissions.len > 0) {
        try builder.note(.{
            .obligation_index = obligation,
            .edge = .translation_validated,
            .rule = .emission_contiguous,
            .node_id = entry,
            .aux = 0,
        });
    }
    if (evidence.jumps.len > 0) {
        try builder.note(.{
            .obligation_index = obligation,
            .edge = .translation_validated,
            .rule = .jump_target_resolved,
            .node_id = entry,
            .aux = 0,
        });
    }
}

fn translationWitnesses(
    allocator: std.mem.Allocator,
    evidence: *const zts.ProofEvidence,
) Error![]cert.Witness {
    const total = evidence.emissions.len + evidence.jumps.len;
    const out = try allocator.alloc(cert.Witness, total);
    errdefer allocator.free(out);
    var index: usize = 0;
    for (evidence.emissions) |emission| {
        out[index] = .{
            .ir_node = emission.node,
            .code_start = emission.code_start,
            .code_len = emission.code_len,
            .target_ir = emission.node,
            .target_offset = emission.code_start,
            .scope_ir_node = emission.scope,
            .kind = .emission,
        };
        index += 1;
    }
    for (evidence.jumps) |jump| {
        out[index] = .{
            .ir_node = jump.node,
            .code_start = jump.instruction_offset,
            .code_len = 0,
            .target_ir = jump.target_node,
            .target_offset = jump.target_offset,
            .scope_ir_node = jump.scope,
            .kind = .jump,
        };
        index += 1;
    }
    // Sorted by scope, then by start, then widest first. The consumer checks
    // containment in one pass over this order instead of comparing every pair,
    // which is what keeps the check linear in the number of witnesses.
    std.mem.sort(cert.Witness, out, {}, struct {
        fn lt(_: void, a: cert.Witness, b: cert.Witness) bool {
            return cert.Witness.order(a, b) == .lt;
        }
    }.lt);
    return out;
}

fn rewriteRecords(
    allocator: std.mem.Allocator,
    evidence: *const zts.ProofEvidence,
) Error![]cert.Rewrite {
    const out = try allocator.alloc(cert.Rewrite, evidence.rewrites.len);
    errdefer allocator.free(out);
    for (evidence.rewrites, 0..) |rewrite, index| {
        out[index] = .{
            .rule = rewriteRuleFor(rewrite.kind),
            .before_offset = rewrite.before_offset,
            .before_len = rewrite.before_len,
            .after_offset = rewrite.after_offset,
            .after_len = rewrite.after_len,
            .delta = rewrite.delta,
        };
    }
    return out;
}

fn trustedEdges(
    allocator: std.mem.Allocator,
    evidence: *const zts.ProofEvidence,
) Error![]cert.TrustedEdge {
    // One disclosed edge per declared node, plus the byte-level decode of the
    // final bytecode, which the kernel does not model: it checks that the
    // witnesses hold together, not that the bytes at those offsets are the
    // instructions the witnesses describe.
    const out = try allocator.alloc(cert.TrustedEdge, evidence.declared.len + 1);
    errdefer allocator.free(out);
    for (evidence.declared, 0..) |declared, index| {
        out[index] = .{
            .family = .node,
            .member_id = @truncate(declared),
            .reason = .not_modeled,
            .grade = .trusted,
        };
    }
    out[evidence.declared.len] = .{
        .family = .opcode,
        .member_id = 0,
        .reason = .not_modeled,
        .grade = .trusted,
    };
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the compiler and the kernel agree on the proof-IR alphabet" {
    // The lowering duplicates the kernel's numbering because the kernel is a
    // leaf and must not become the compiler's dependency. This is where the two
    // copies are held against each other.
    inline for (@typeInfo(zts.ProofIrTag).@"enum".fields) |field| {
        const tag: zts.ProofIrTag = @enumFromInt(field.value);
        try testing.expectEqual(
            @as(u16, @intFromEnum(tagFor(tag))),
            @as(u16, field.value),
        );
    }
    // The kernel's alphabet may run ahead of the compiler's while a producer
    // side is being built, but only by members named here. A tag the kernel
    // gained that nobody wrote down is the drift this test exists to catch.
    const kernel_only = [_]ps.NodeTag{.capability_call};
    try testing.expectEqual(
        @typeInfo(zts.ProofIrTag).@"enum".fields.len + kernel_only.len,
        @typeInfo(ps.NodeTag).@"enum".fields.len,
    );
    for (kernel_only) |tag| {
        // Each one must be outside the compiler's numbering, so no compiler tag
        // can silently map onto it.
        try testing.expect(@intFromEnum(tag) > @typeInfo(zts.ProofIrTag).@"enum".fields.len);
    }

    inline for (@typeInfo(zts.ProofRule).@"enum".fields) |field| {
        const rule: zts.ProofRule = @enumFromInt(field.value);
        try testing.expectEqual(
            @as(u16, @intFromEnum(ruleFor(rule))),
            @as(u16, field.value),
        );
    }
}

test "every rewrite kind maps onto a translation rule" {
    inline for (@typeInfo(zts.TranslationRewriteKind).@"enum".fields) |field| {
        const kind: zts.TranslationRewriteKind = @enumFromInt(field.value);
        const rule = rewriteRuleFor(kind);
        try testing.expectEqual(ps.RuleFamily.translation, rule.family());
    }
}

test "a discharged property answers, and an undischarged one still answers" {
    const none = DischargedProperties{};
    const all = DischargedProperties{
        .results_checked = true,
        .no_secret_leakage = true,
        .state_isolated = true,
        .deterministic = true,
        .read_only = true,
        .retry_safe = true,
        .capability_bounded = true,
    };
    inline for (@typeInfo(ps.Property).@"enum".fields) |field| {
        const property: ps.Property = @enumFromInt(field.value);
        try testing.expect(!none.holds(property));
        if (property != .response_total) try testing.expect(all.holds(property));
    }
}
