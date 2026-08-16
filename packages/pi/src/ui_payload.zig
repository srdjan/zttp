const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const json_writer = @import("providers/json_writer.zig");
const payload_memory = @import("payload_memory.zig");

pub const DiagnosticItem = struct {
    code: []u8,
    severity: []u8,
    path: []u8,
    line: u32,
    column: u32,
    message: []u8,
    introduced_by_patch: ?bool = null,

    pub fn init(
        allocator: std.mem.Allocator,
        code: []const u8,
        severity: []const u8,
        path: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
        introduced_by_patch: ?bool,
    ) !DiagnosticItem {
        return .{
            .code = try allocator.dupe(u8, code),
            .severity = try allocator.dupe(u8, severity),
            .path = try allocator.dupe(u8, path),
            .line = line,
            .column = column,
            .message = try allocator.dupe(u8, message),
            .introduced_by_patch = introduced_by_patch,
        };
    }

    pub fn clone(self: DiagnosticItem, allocator: std.mem.Allocator) !DiagnosticItem {
        return payload_memory.cloneOwned(DiagnosticItem, self, allocator);
    }

    pub fn deinit(self: *DiagnosticItem, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(DiagnosticItem, self, allocator);
    }
};

pub const DiagnosticsPayload = struct {
    summary: []u8,
    items: []DiagnosticItem,

    pub fn clone(self: DiagnosticsPayload, allocator: std.mem.Allocator) !DiagnosticsPayload {
        return payload_memory.cloneOwned(DiagnosticsPayload, self, allocator);
    }

    pub fn deinit(self: *DiagnosticsPayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(DiagnosticsPayload, self, allocator);
    }
};

pub const ProofStats = struct {
    total: u32,
    new: u32,
    preexisting: ?u32 = null,
};

pub const ProofCardPayload = struct {
    title: []u8,
    summary: []u8,
    stats: ProofStats,
    highlights: [][]u8,

    pub fn clone(self: ProofCardPayload, allocator: std.mem.Allocator) !ProofCardPayload {
        return payload_memory.cloneOwned(ProofCardPayload, self, allocator);
    }

    pub fn deinit(self: *ProofCardPayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(ProofCardPayload, self, allocator);
    }
};

pub const CommandOutcomePayload = struct {
    title: []u8,
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,
    command: []u8,

    pub fn clone(self: CommandOutcomePayload, allocator: std.mem.Allocator) !CommandOutcomePayload {
        return payload_memory.cloneOwned(CommandOutcomePayload, self, allocator);
    }

    pub fn deinit(self: *CommandOutcomePayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(CommandOutcomePayload, self, allocator);
    }
};

pub const RepairCandidatePayload = struct {
    path: []u8,
    plan_id: []u8,
    intent_kind: []u8,
    proposed_content: []u8,
    verification_ok: bool,
    verification_summary: []u8,
    stats: ProofStats,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        plan_id: []const u8,
        intent_kind: []const u8,
        proposed_content: []const u8,
        verification_ok: bool,
        verification_summary: []const u8,
        stats: ProofStats,
    ) !RepairCandidatePayload {
        return .{
            .path = try allocator.dupe(u8, path),
            .plan_id = try allocator.dupe(u8, plan_id),
            .intent_kind = try allocator.dupe(u8, intent_kind),
            .proposed_content = try allocator.dupe(u8, proposed_content),
            .verification_ok = verification_ok,
            .verification_summary = try allocator.dupe(u8, verification_summary),
            .stats = stats,
        };
    }

    pub fn clone(self: RepairCandidatePayload, allocator: std.mem.Allocator) !RepairCandidatePayload {
        return payload_memory.cloneOwned(RepairCandidatePayload, self, allocator);
    }

    pub fn deinit(self: *RepairCandidatePayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(RepairCandidatePayload, self, allocator);
    }
};

/// A v2 repair selection that the compiler simulated against one exact source
/// and identity tuple. Unlike `RepairCandidatePayload`, this carries no legacy
/// plan id: the protocol has no stable candidate id, so provenance is the
/// exact repair array plus its binding.
pub const ProtocolRepairPayload = struct {
    path: []u8,
    proposed_content: []u8,
    repairs_json: []u8,
    source_digest: []u8,
    profile_id: []u8,
    policy_hash: []u8,
    module_graph_hash: []u8,
    verification_summary: []u8,
    stats: ProofStats,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        proposed_content: []const u8,
        repairs_json: []const u8,
        source_digest: []const u8,
        profile_id: []const u8,
        policy_hash: []const u8,
        module_graph_hash: []const u8,
        verification_summary: []const u8,
        stats: ProofStats,
    ) !ProtocolRepairPayload {
        const path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(path_owned);
        const content_owned = try allocator.dupe(u8, proposed_content);
        errdefer allocator.free(content_owned);
        const repairs_owned = try allocator.dupe(u8, repairs_json);
        errdefer allocator.free(repairs_owned);
        const digest_owned = try allocator.dupe(u8, source_digest);
        errdefer allocator.free(digest_owned);
        const profile_owned = try allocator.dupe(u8, profile_id);
        errdefer allocator.free(profile_owned);
        const policy_owned = try allocator.dupe(u8, policy_hash);
        errdefer allocator.free(policy_owned);
        const graph_owned = try allocator.dupe(u8, module_graph_hash);
        errdefer allocator.free(graph_owned);
        const summary_owned = try allocator.dupe(u8, verification_summary);
        errdefer allocator.free(summary_owned);
        return .{
            .path = path_owned,
            .proposed_content = content_owned,
            .repairs_json = repairs_owned,
            .source_digest = digest_owned,
            .profile_id = profile_owned,
            .policy_hash = policy_owned,
            .module_graph_hash = graph_owned,
            .verification_summary = summary_owned,
            .stats = stats,
        };
    }

    pub fn clone(self: ProtocolRepairPayload, allocator: std.mem.Allocator) !ProtocolRepairPayload {
        return payload_memory.cloneOwned(ProtocolRepairPayload, self, allocator);
    }

    pub fn deinit(self: *ProtocolRepairPayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(ProtocolRepairPayload, self, allocator);
    }
};

pub const PropertiesSnapshot = struct {
    pure: bool,
    read_only: bool,
    stateless: bool,
    retry_safe: bool,
    deterministic: bool,
    has_egress: bool,
    no_secret_leakage: bool,
    no_credential_leakage: bool,
    input_validated: bool,
    pii_contained: bool,
    idempotent: bool,
    max_io_depth: ?u32 = null,
    injection_safe: bool,
    state_isolated: bool,
    fault_covered: bool,
    result_safe: bool,
    optional_safe: bool,
    cost_bounded: bool = false,
    post_only: bool = false,
    canonical: bool = false,

    pub const ChangeKind = enum { promoted, demoted };

    pub const Change = struct {
        name: []const u8,
        kind: ChangeKind,
    };

    /// Walk the boolean fields of `after` against `before` and invoke `visitor`
    /// once per field whose value flipped. Missing `before` means no baseline;
    /// every after-field is treated as unchanged. Kept as an inline visitor so
    /// the compile-time field walk inlines at each call site and the caller
    /// decides how to render or collect the changes.
    pub inline fn forEachChange(
        before_opt: ?PropertiesSnapshot,
        after: PropertiesSnapshot,
        comptime Visitor: type,
        visitor: Visitor,
    ) !void {
        const before = before_opt orelse return;
        inline for (@typeInfo(PropertiesSnapshot).@"struct".fields) |field| {
            if (field.type != bool) continue;
            const after_val = @field(after, field.name);
            const before_val = @field(before, field.name);
            if (after_val and !before_val) {
                try visitor.visit(.{ .name = field.name, .kind = .promoted });
            } else if (!after_val and before_val) {
                try visitor.visit(.{ .name = field.name, .kind = .demoted });
            }
        }
    }

    pub const GuaranteeCounts = struct { proven: u32, tracked: u32 };

    /// Count the analyzer-discharged proof guarantees in this snapshot. Each
    /// boolean field is a handler-wide guarantee the analyzer either proved
    /// (true) or did not (false). `has_egress` is excluded because it records a
    /// neutral fact (the handler makes egress), not a guarantee, and the
    /// non-boolean `max_io_depth` is skipped by the field-type filter. Because
    /// zts proofs hold handler-wide over the exhaustively-enumerated path
    /// space rather than per response path, `proven / tracked` is the fraction
    /// of tracked guarantees discharged for the handler - the session
    /// "proven-path ratio".
    pub fn guaranteeCounts(self: PropertiesSnapshot) GuaranteeCounts {
        var proven: u32 = 0;
        var tracked: u32 = 0;
        inline for (@typeInfo(PropertiesSnapshot).@"struct".fields) |field| {
            if (field.type != bool) continue;
            if (comptime std.mem.eql(u8, field.name, "has_egress")) continue;
            tracked += 1;
            if (@field(self, field.name)) proven += 1;
        }
        return .{ .proven = proven, .tracked = tracked };
    }
};

pub const ViolationDeltaItem = struct {
    stable_key: []u8,
    code: []u8,
    severity: []u8,
    message: []u8,
    line: u32,
    column: u32,
    introduced_by_patch: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        stable_key: []const u8,
        code: []const u8,
        severity: []const u8,
        message: []const u8,
        line: u32,
        column: u32,
        introduced_by_patch: bool,
    ) !ViolationDeltaItem {
        return .{
            .stable_key = try allocator.dupe(u8, stable_key),
            .code = try allocator.dupe(u8, code),
            .severity = try allocator.dupe(u8, severity),
            .message = try allocator.dupe(u8, message),
            .line = line,
            .column = column,
            .introduced_by_patch = introduced_by_patch,
        };
    }

    pub fn clone(self: ViolationDeltaItem, allocator: std.mem.Allocator) !ViolationDeltaItem {
        return payload_memory.cloneOwned(ViolationDeltaItem, self, allocator);
    }

    pub fn deinit(self: *ViolationDeltaItem, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(ViolationDeltaItem, self, allocator);
    }
};

pub const DiffHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

pub const ProveSummary = struct {
    classification: []u8,
    proof_level: []u8,
    recommendation: []u8,
    counterexample: ?[]u8 = null,
    laws_used: [][]u8,

    pub fn clone(self: ProveSummary, allocator: std.mem.Allocator) !ProveSummary {
        return payload_memory.cloneOwned(ProveSummary, self, allocator);
    }

    pub fn deinit(self: *ProveSummary, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(ProveSummary, self, allocator);
    }
};

pub const SystemProofSummary = struct {
    system_path: []u8,
    proof_level: []u8,
    all_links_resolved: bool,
    all_responses_covered: bool,
    payload_compatible: bool,
    injection_safe: bool,
    no_secret_leakage: bool,
    no_credential_leakage: bool,
    retry_safe: bool,
    fault_covered: bool,
    state_isolated: bool,
    max_system_io_depth: ?u32 = null,
    dynamic_links: u32,
    warnings: [][]u8,

    pub fn clone(self: SystemProofSummary, allocator: std.mem.Allocator) !SystemProofSummary {
        return payload_memory.cloneOwned(SystemProofSummary, self, allocator);
    }

    pub fn deinit(self: *SystemProofSummary, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(SystemProofSummary, self, allocator);
    }
};

/// One virtual-module call in a witness's IO stub script. Mirrors
/// `zts.counterexample.IoStubEntry` but holds owned strings so the body can
/// outlive the analyzer that produced it.
pub const WitnessStub = struct {
    seq: u32,
    module: []u8,
    func: []u8,
    result_json: []u8,

    pub fn clone(self: WitnessStub, allocator: std.mem.Allocator) !WitnessStub {
        return payload_memory.cloneOwned(WitnessStub, self, allocator);
    }

    pub fn deinit(self: *WitnessStub, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(WitnessStub, self, allocator);
    }
};

/// Concrete counterexample for a property violation: the request that drives
/// the handler down the violating path, the IO stub script that pins the
/// virtual-module return values, and the source span endpoints. Replayable
/// via `zts.counterexample.writeJsonl` against the runtime's `--test`
/// path. The stable `key` is the same digest `witness_key.forWitness`
/// produces; consumers compare witness identity by byte equality on `key`.
pub const WitnessBody = struct {
    key: []u8,
    property: []u8,
    summary: []u8,
    origin_line: u32,
    origin_column: u32,
    sink_line: u32,
    sink_column: u32,
    request_method: []u8,
    request_url: []u8,
    request_has_auth: bool,
    request_body: ?[]u8,
    io_stubs: []WitnessStub,

    pub fn clone(self: WitnessBody, allocator: std.mem.Allocator) !WitnessBody {
        return payload_memory.cloneOwned(WitnessBody, self, allocator);
    }

    pub fn deinit(self: *WitnessBody, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(WitnessBody, self, allocator);
    }
};

pub fn cloneWitnessBodySlice(
    allocator: std.mem.Allocator,
    items: []const WitnessBody,
) ![]WitnessBody {
    const copy = try allocator.alloc(WitnessBody, items.len);
    errdefer allocator.free(copy);
    for (copy) |*body| body.* = undefined;
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            copy[i].deinit(allocator);
        }
    }
    while (i < items.len) : (i += 1) {
        copy[i] = try items[i].clone(allocator);
    }
    return copy;
}

pub fn freeWitnessBodySlice(
    allocator: std.mem.Allocator,
    items: []WitnessBody,
) void {
    for (items) |*body| body.deinit(allocator);
    allocator.free(items);
}

pub const VerifiedChange = struct {
    file: []u8,
    baseline_state: []u8,
    baseline_sha256: []u8,
    candidate_sha256: []u8,
    before: ?[]u8,
    after: []u8,
    unified_diff: []u8,
    rewrite_trace: [][]u8 = &.{},

    pub fn clone(self: VerifiedChange, allocator: std.mem.Allocator) !VerifiedChange {
        return payload_memory.cloneOwned(VerifiedChange, self, allocator);
    }

    pub fn deinit(self: *VerifiedChange, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(VerifiedChange, self, allocator);
    }
};

pub const VerifiedProofInput = struct {
    path: []u8,
    state: []u8,
    sha256: []u8,

    pub fn clone(self: VerifiedProofInput, allocator: std.mem.Allocator) !VerifiedProofInput {
        return payload_memory.cloneOwned(VerifiedProofInput, self, allocator);
    }

    pub fn deinit(self: *VerifiedProofInput, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(VerifiedProofInput, self, allocator);
    }
};

/// One durable receipt for an ordered source change set. The transaction and
/// compiler proof share `transaction_id`; every source and proof input needed
/// to reproduce or audit the decision is listed explicitly.
pub const VerifiedChangeSetPayload = struct {
    proof_schema_version: []u8,
    transaction_id: []u8,
    compiler_version: []u8,
    profile_id: []u8,
    policy_hash: []u8,
    grammar_hash: []u8,
    semantics_hash: []u8,
    diagnostic_catalog_hash: []u8,
    read_set_digest: []u8,
    applied_at_unix_ms: i64,
    system_proven: bool,
    baseline_primary_properties: ?PropertiesSnapshot = null,
    primary_properties: ?PropertiesSnapshot = null,
    proof_roots: [][]u8,
    changes: []VerifiedChange,
    proof_inputs: []VerifiedProofInput,
    repair_plan_ids: [][]u8 = &.{},
    goal_context: [][]u8 = &.{},
    witnesses_defeated: []WitnessBody = &.{},
    witnesses_new: []WitnessBody = &.{},

    pub fn clone(self: VerifiedChangeSetPayload, allocator: std.mem.Allocator) !VerifiedChangeSetPayload {
        return payload_memory.cloneOwned(VerifiedChangeSetPayload, self, allocator);
    }

    pub fn deinit(self: *VerifiedChangeSetPayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(VerifiedChangeSetPayload, self, allocator);
    }
};

fn cloneStringSlice(allocator: std.mem.Allocator, items: []const []u8) ![][]u8 {
    const copy = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(copy);
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            allocator.free(copy[i]);
        }
        allocator.free(copy);
    }
    while (i < items.len) : (i += 1) {
        copy[i] = try allocator.dupe(u8, items[i]);
    }
    return copy;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub const SessionTreeNode = struct {
    session_id: []u8,
    parent_id: ?[]u8,
    created_at_unix_ms: i64,
    depth: usize,
    is_current: bool,
    is_orphan_root: bool,

    pub fn clone(self: SessionTreeNode, allocator: std.mem.Allocator) !SessionTreeNode {
        return payload_memory.cloneOwned(SessionTreeNode, self, allocator);
    }

    pub fn deinit(self: *SessionTreeNode, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(SessionTreeNode, self, allocator);
    }
};

pub const SessionTreePayload = struct {
    nodes: []SessionTreeNode,

    pub fn clone(self: SessionTreePayload, allocator: std.mem.Allocator) !SessionTreePayload {
        return payload_memory.cloneOwned(SessionTreePayload, self, allocator);
    }

    pub fn deinit(self: *SessionTreePayload, allocator: std.mem.Allocator) void {
        payload_memory.freeOwned(SessionTreePayload, self, allocator);
    }
};

pub const UiPayload = union(enum) {
    session_tree: SessionTreePayload,
    diagnostics: DiagnosticsPayload,
    proof_card: ProofCardPayload,
    command_outcome: CommandOutcomePayload,
    repair_candidate: RepairCandidatePayload,
    protocol_repair: ProtocolRepairPayload,
    verified_change_set: VerifiedChangeSetPayload,
    plain_text: []u8,

    pub fn clone(self: UiPayload, allocator: std.mem.Allocator) !UiPayload {
        // Hand-written where the struct payloads are generic: a union clone has
        // to name the active variant to rebuild the tag, and `deinit` has to
        // choose which variant a freed payload becomes.
        return switch (self) {
            .session_tree => |payload| .{ .session_tree = try payload.clone(allocator) },
            .diagnostics => |payload| .{ .diagnostics = try payload.clone(allocator) },
            .proof_card => |payload| .{ .proof_card = try payload.clone(allocator) },
            .command_outcome => |payload| .{ .command_outcome = try payload.clone(allocator) },
            .repair_candidate => |payload| .{ .repair_candidate = try payload.clone(allocator) },
            .protocol_repair => |payload| .{ .protocol_repair = try payload.clone(allocator) },
            .verified_change_set => |payload| .{ .verified_change_set = try payload.clone(allocator) },
            .plain_text => |text| .{ .plain_text = try allocator.dupe(u8, text) },
        };
    }

    pub fn deinit(self: *UiPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .session_tree => |*payload| payload.deinit(allocator),
            .diagnostics => |*payload| payload.deinit(allocator),
            .proof_card => |*payload| payload.deinit(allocator),
            .command_outcome => |*payload| payload.deinit(allocator),
            .repair_candidate => |*payload| payload.deinit(allocator),
            .protocol_repair => |*payload| payload.deinit(allocator),
            .verified_change_set => |*payload| payload.deinit(allocator),
            .plain_text => |text| allocator.free(text),
        }
        self.* = .{ .plain_text = &.{} };
    }
};

pub fn writeJson(writer: *std.Io.Writer, payload: UiPayload) !void {
    try writer.writeByte('{');
    switch (payload) {
        .plain_text => |text| {
            try writer.writeAll("\"kind\":\"plain_text\",\"text\":");
            try json_writer.writeString(writer, text);
        },
        .session_tree => |tree| {
            try writer.writeAll("\"kind\":\"session_tree\",\"nodes\":[");
            for (tree.nodes, 0..) |node, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeByte('{');
                try writer.writeAll("\"session_id\":");
                try json_writer.writeString(writer, node.session_id);
                try writer.writeAll(",\"parent_id\":");
                if (node.parent_id) |parent_id| {
                    try json_writer.writeString(writer, parent_id);
                } else {
                    try writer.writeAll("null");
                }
                try writer.writeAll(",\"created_at_unix_ms\":");
                try writer.print("{d}", .{node.created_at_unix_ms});
                try writer.writeAll(",\"depth\":");
                try writer.print("{d}", .{node.depth});
                try writer.writeAll(",\"is_current\":");
                try writer.writeAll(if (node.is_current) "true" else "false");
                try writer.writeAll(",\"is_orphan_root\":");
                try writer.writeAll(if (node.is_orphan_root) "true" else "false");
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        },
        .diagnostics => |diagnostics| {
            try writer.writeAll("\"kind\":\"diagnostics\",\"summary\":");
            try json_writer.writeString(writer, diagnostics.summary);
            try writer.writeAll(",\"items\":[");
            for (diagnostics.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeByte('{');
                try writer.writeAll("\"code\":");
                try json_writer.writeString(writer, item.code);
                try writer.writeAll(",\"severity\":");
                try json_writer.writeString(writer, item.severity);
                try writer.writeAll(",\"path\":");
                try json_writer.writeString(writer, item.path);
                try writer.writeAll(",\"line\":");
                try writer.print("{d}", .{item.line});
                try writer.writeAll(",\"column\":");
                try writer.print("{d}", .{item.column});
                try writer.writeAll(",\"message\":");
                try json_writer.writeString(writer, item.message);
                if (item.introduced_by_patch) |introduced_by_patch| {
                    try writer.writeAll(",\"introduced_by_patch\":");
                    try writer.writeAll(if (introduced_by_patch) "true" else "false");
                }
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        },
        .proof_card => |proof| {
            try writer.writeAll("\"kind\":\"proof_card\",\"title\":");
            try json_writer.writeString(writer, proof.title);
            try writer.writeAll(",\"summary\":");
            try json_writer.writeString(writer, proof.summary);
            try writer.writeAll(",\"stats\":{\"total\":");
            try writer.print("{d}", .{proof.stats.total});
            try writer.writeAll(",\"new\":");
            try writer.print("{d}", .{proof.stats.new});
            if (proof.stats.preexisting) |preexisting| {
                try writer.writeAll(",\"preexisting\":");
                try writer.print("{d}", .{preexisting});
            }
            try writer.writeAll("},\"highlights\":[");
            for (proof.highlights, 0..) |highlight, i| {
                if (i > 0) try writer.writeByte(',');
                try json_writer.writeString(writer, highlight);
            }
            try writer.writeByte(']');
        },
        .command_outcome => |command| {
            try writer.writeAll("\"kind\":\"command_outcome\",\"title\":");
            try json_writer.writeString(writer, command.title);
            try writer.writeAll(",\"exit_code\":");
            if (command.exit_code) |exit_code| {
                try writer.print("{d}", .{exit_code});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"stdout\":");
            try json_writer.writeString(writer, command.stdout);
            try writer.writeAll(",\"stderr\":");
            try json_writer.writeString(writer, command.stderr);
            try writer.writeAll(",\"command\":");
            try json_writer.writeString(writer, command.command);
        },
        .repair_candidate => |candidate| {
            try writer.writeAll("\"kind\":\"repair_candidate\",\"path\":");
            try json_writer.writeString(writer, candidate.path);
            try writer.writeAll(",\"plan_id\":");
            try json_writer.writeString(writer, candidate.plan_id);
            try writer.writeAll(",\"intent_kind\":");
            try json_writer.writeString(writer, candidate.intent_kind);
            try writer.writeAll(",\"proposed_content\":");
            try json_writer.writeString(writer, candidate.proposed_content);
            try writer.writeAll(",\"verification_ok\":");
            try writer.writeAll(if (candidate.verification_ok) "true" else "false");
            try writer.writeAll(",\"verification_summary\":");
            try json_writer.writeString(writer, candidate.verification_summary);
            try writer.writeAll(",\"stats\":{\"total\":");
            try writer.print("{d}", .{candidate.stats.total});
            try writer.writeAll(",\"new\":");
            try writer.print("{d}", .{candidate.stats.new});
            if (candidate.stats.preexisting) |preexisting| {
                try writer.writeAll(",\"preexisting\":");
                try writer.print("{d}", .{preexisting});
            }
            try writer.writeByte('}');
        },
        .protocol_repair => |repair| {
            try writer.writeAll("\"kind\":\"protocol_repair\",\"path\":");
            try json_writer.writeString(writer, repair.path);
            try writer.writeAll(",\"proposed_content\":");
            try json_writer.writeString(writer, repair.proposed_content);
            try writer.writeAll(",\"repairs\":");
            try writer.writeAll(repair.repairs_json);
            try writer.writeAll(",\"source_digest\":");
            try json_writer.writeString(writer, repair.source_digest);
            try writer.writeAll(",\"profile_id\":");
            try json_writer.writeString(writer, repair.profile_id);
            try writer.writeAll(",\"policy_hash\":");
            try json_writer.writeString(writer, repair.policy_hash);
            try writer.writeAll(",\"module_graph_hash\":");
            try json_writer.writeString(writer, repair.module_graph_hash);
            try writer.writeAll(",\"verification_summary\":");
            try json_writer.writeString(writer, repair.verification_summary);
            try writer.writeAll(",\"stats\":{\"total\":");
            try writer.print("{d}", .{repair.stats.total});
            try writer.writeAll(",\"new\":");
            try writer.print("{d}", .{repair.stats.new});
            if (repair.stats.preexisting) |preexisting| {
                try writer.writeAll(",\"preexisting\":");
                try writer.print("{d}", .{preexisting});
            }
            try writer.writeByte('}');
        },
        .verified_change_set => |receipt| {
            try writer.writeAll("\"kind\":\"verified_change_set\",\"proof_schema_version\":");
            try json_writer.writeString(writer, receipt.proof_schema_version);
            try writer.writeAll(",\"transaction_id\":");
            try json_writer.writeString(writer, receipt.transaction_id);
            try writer.writeAll(",\"compiler_version\":");
            try json_writer.writeString(writer, receipt.compiler_version);
            try writer.writeAll(",\"profile_id\":");
            try json_writer.writeString(writer, receipt.profile_id);
            try writer.writeAll(",\"policy_hash\":");
            try json_writer.writeString(writer, receipt.policy_hash);
            try writer.writeAll(",\"grammar_hash\":");
            try json_writer.writeString(writer, receipt.grammar_hash);
            try writer.writeAll(",\"semantics_hash\":");
            try json_writer.writeString(writer, receipt.semantics_hash);
            try writer.writeAll(",\"diagnostic_catalog_hash\":");
            try json_writer.writeString(writer, receipt.diagnostic_catalog_hash);
            try writer.writeAll(",\"read_set_digest\":");
            try json_writer.writeString(writer, receipt.read_set_digest);
            try writer.writeAll(",\"applied_at_unix_ms\":");
            try writer.print("{d}", .{receipt.applied_at_unix_ms});
            try writer.writeAll(",\"system_proven\":");
            try writer.writeAll(if (receipt.system_proven) "true" else "false");
            try writer.writeAll(",\"baseline_primary_properties\":");
            try writePropertiesSnapshot(writer, receipt.baseline_primary_properties);
            try writer.writeAll(",\"primary_properties\":");
            try writePropertiesSnapshot(writer, receipt.primary_properties);
            try writer.writeAll(",\"proof_roots\":[");
            for (receipt.proof_roots, 0..) |root, index| {
                if (index > 0) try writer.writeByte(',');
                try json_writer.writeString(writer, root);
            }
            try writer.writeAll("],\"changes\":[");
            for (receipt.changes, 0..) |change, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"file\":");
                try json_writer.writeString(writer, change.file);
                try writer.writeAll(",\"baseline_state\":");
                try json_writer.writeString(writer, change.baseline_state);
                try writer.writeAll(",\"baseline_sha256\":");
                try json_writer.writeString(writer, change.baseline_sha256);
                try writer.writeAll(",\"candidate_sha256\":");
                try json_writer.writeString(writer, change.candidate_sha256);
                try writer.writeAll(",\"before\":");
                if (change.before) |before| try json_writer.writeString(writer, before) else try writer.writeAll("null");
                try writer.writeAll(",\"after\":");
                try json_writer.writeString(writer, change.after);
                try writer.writeAll(",\"unified_diff\":");
                try json_writer.writeString(writer, change.unified_diff);
                try writer.writeAll(",\"rewrite_trace\":[");
                for (change.rewrite_trace, 0..) |rewrite, rewrite_index| {
                    if (rewrite_index > 0) try writer.writeByte(',');
                    try json_writer.writeString(writer, rewrite);
                }
                try writer.writeAll("]}");
            }
            try writer.writeAll("],\"proof_inputs\":[");
            for (receipt.proof_inputs, 0..) |input, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"path\":");
                try json_writer.writeString(writer, input.path);
                try writer.writeAll(",\"state\":");
                try json_writer.writeString(writer, input.state);
                try writer.writeAll(",\"sha256\":");
                try json_writer.writeString(writer, input.sha256);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
            try writeOptionalStringArray(writer, "repair_plan_ids", receipt.repair_plan_ids);
            try writeOptionalStringArray(writer, "goal_context", receipt.goal_context);
            try writeOptionalWitnessBodyArray(writer, "witnesses_defeated", receipt.witnesses_defeated);
            try writeOptionalWitnessBodyArray(writer, "witnesses_new", receipt.witnesses_new);
        },
    }
    try writer.writeByte('}');
}

/// Render a payload as legible human lines for the REPL and `expert --print`.
/// Returns `true` when it emitted a structured rendering, `false` when the
/// variant has no human form here and the caller should fall back to the
/// entry's plain `llm_text`. Only the proof-bearing variants are handled,
/// because those are the ones whose `llm_text` is otherwise raw analyzer JSON.
pub fn writeLegible(writer: *std.Io.Writer, payload: UiPayload) !bool {
    switch (payload) {
        .proof_card => |proof| {
            try writer.writeAll("PROVEN  ");
            try writer.writeAll(proof.title);
            try writer.writeByte('\n');
            try writer.print(
                "  {s} ({d} total, {d} new",
                .{ proof.summary, proof.stats.total, proof.stats.new },
            );
            if (proof.stats.preexisting) |preexisting| {
                try writer.print(", {d} preexisting", .{preexisting});
            }
            try writer.writeByte(')');
            try writer.writeByte('\n');
            if (proof.highlights.len > 0) {
                try writer.writeAll("  properties:");
                for (proof.highlights) |highlight| {
                    try writer.writeByte(' ');
                    try writer.writeAll(highlight);
                }
                try writer.writeByte('\n');
            }
            return true;
        },
        .verified_change_set => |receipt| {
            try writer.print(
                "verified change set: {d} file{s} ({s})\n",
                .{
                    receipt.changes.len,
                    if (receipt.changes.len == 1) "" else "s",
                    receipt.transaction_id,
                },
            );
            for (receipt.changes) |change| try writer.print("  {s}\n", .{change.file});
            if (receipt.system_proven) try writer.writeAll("  aggregate system proof passed\n");
            return true;
        },
        .diagnostics => |diagnostics| {
            try writer.writeAll("diagnostics: ");
            try writer.writeAll(diagnostics.summary);
            try writer.writeByte('\n');
            for (diagnostics.items) |item| {
                try writer.print(
                    "  {s} {s}:{d}:{d} {s}\n",
                    .{ item.code, item.path, item.line, item.column, item.message },
                );
            }
            return true;
        },
        else => return false,
    }
}

pub fn parse(allocator: std.mem.Allocator, value: std.json.Value) !UiPayload {
    if (value != .object) return error.InvalidUiPayload;
    const obj = value.object;
    const kind_val = obj.get("kind") orelse return error.InvalidUiPayload;
    if (kind_val != .string) return error.InvalidUiPayload;

    if (std.mem.eql(u8, kind_val.string, "plain_text")) {
        const text_val = obj.get("text") orelse return error.InvalidUiPayload;
        if (text_val != .string) return error.InvalidUiPayload;
        return .{ .plain_text = try allocator.dupe(u8, text_val.string) };
    }
    if (std.mem.eql(u8, kind_val.string, "session_tree")) {
        const nodes_val = obj.get("nodes") orelse return error.InvalidUiPayload;
        if (nodes_val != .array) return error.InvalidUiPayload;
        const nodes = try allocator.alloc(SessionTreeNode, nodes_val.array.items.len);
        errdefer allocator.free(nodes);
        for (nodes) |*node| node.* = undefined;
        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                nodes[i].deinit(allocator);
            }
            allocator.free(nodes);
        }
        while (i < nodes_val.array.items.len) : (i += 1) {
            const item = nodes_val.array.items[i];
            if (item != .object) return error.InvalidUiPayload;
            const item_obj = item.object;
            const session_id = getString(item_obj, "session_id") orelse return error.InvalidUiPayload;
            const parent_id = getOptionalString(item_obj, "parent_id") catch return error.InvalidUiPayload;
            const created_at_unix_ms = getInteger(item_obj, "created_at_unix_ms") orelse return error.InvalidUiPayload;
            const depth = getUnsigned(item_obj, "depth") orelse return error.InvalidUiPayload;
            const is_current = getBool(item_obj, "is_current") orelse return error.InvalidUiPayload;
            const is_orphan_root = getBool(item_obj, "is_orphan_root") orelse return error.InvalidUiPayload;
            nodes[i] = .{
                .session_id = try allocator.dupe(u8, session_id),
                .parent_id = if (parent_id) |pid| try allocator.dupe(u8, pid) else null,
                .created_at_unix_ms = created_at_unix_ms,
                .depth = depth,
                .is_current = is_current,
                .is_orphan_root = is_orphan_root,
            };
        }
        return .{ .session_tree = .{ .nodes = nodes } };
    }
    if (std.mem.eql(u8, kind_val.string, "diagnostics")) {
        const summary = getString(obj, "summary") orelse return error.InvalidUiPayload;
        const items_val = obj.get("items") orelse return error.InvalidUiPayload;
        if (items_val != .array) return error.InvalidUiPayload;
        const items = try allocator.alloc(DiagnosticItem, items_val.array.items.len);
        errdefer allocator.free(items);
        for (items) |*item| item.* = undefined;
        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                items[i].deinit(allocator);
            }
            allocator.free(items);
        }
        while (i < items_val.array.items.len) : (i += 1) {
            const item_val = items_val.array.items[i];
            if (item_val != .object) return error.InvalidUiPayload;
            const item_obj = item_val.object;
            items[i] = try DiagnosticItem.init(
                allocator,
                getString(item_obj, "code") orelse return error.InvalidUiPayload,
                getString(item_obj, "severity") orelse return error.InvalidUiPayload,
                getString(item_obj, "path") orelse return error.InvalidUiPayload,
                @intCast(getUnsigned(item_obj, "line") orelse return error.InvalidUiPayload),
                @intCast(getUnsigned(item_obj, "column") orelse return error.InvalidUiPayload),
                getString(item_obj, "message") orelse return error.InvalidUiPayload,
                getBool(item_obj, "introduced_by_patch"),
            );
        }
        return .{ .diagnostics = .{
            .summary = try allocator.dupe(u8, summary),
            .items = items,
        } };
    }
    if (std.mem.eql(u8, kind_val.string, "proof_card")) {
        const title = getString(obj, "title") orelse return error.InvalidUiPayload;
        const summary = getString(obj, "summary") orelse return error.InvalidUiPayload;
        const stats_val = obj.get("stats") orelse return error.InvalidUiPayload;
        if (stats_val != .object) return error.InvalidUiPayload;
        const stats_obj = stats_val.object;
        const highlights_val = obj.get("highlights") orelse return error.InvalidUiPayload;
        if (highlights_val != .array) return error.InvalidUiPayload;
        const highlights = try allocator.alloc([]u8, highlights_val.array.items.len);
        errdefer allocator.free(highlights);
        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                allocator.free(highlights[i]);
            }
            allocator.free(highlights);
        }
        while (i < highlights_val.array.items.len) : (i += 1) {
            const highlight = highlights_val.array.items[i];
            if (highlight != .string) return error.InvalidUiPayload;
            highlights[i] = try allocator.dupe(u8, highlight.string);
        }
        return .{ .proof_card = .{
            .title = try allocator.dupe(u8, title),
            .summary = try allocator.dupe(u8, summary),
            .stats = .{
                .total = @intCast(getUnsigned(stats_obj, "total") orelse return error.InvalidUiPayload),
                .new = @intCast(getUnsigned(stats_obj, "new") orelse return error.InvalidUiPayload),
                .preexisting = if (getUnsigned(stats_obj, "preexisting")) |preexisting|
                    @intCast(preexisting)
                else
                    null,
            },
            .highlights = highlights,
        } };
    }
    if (std.mem.eql(u8, kind_val.string, "command_outcome")) {
        const title = getString(obj, "title") orelse return error.InvalidUiPayload;
        const stdout = getString(obj, "stdout") orelse return error.InvalidUiPayload;
        const stderr = getString(obj, "stderr") orelse return error.InvalidUiPayload;
        const command = getString(obj, "command") orelse return error.InvalidUiPayload;
        return .{ .command_outcome = .{
            .title = try allocator.dupe(u8, title),
            .exit_code = if (getUnsigned(obj, "exit_code")) |exit_code|
                @intCast(exit_code)
            else
                null,
            .stdout = try allocator.dupe(u8, stdout),
            .stderr = try allocator.dupe(u8, stderr),
            .command = try allocator.dupe(u8, command),
        } };
    }
    if (std.mem.eql(u8, kind_val.string, "repair_candidate")) {
        const stats_val = obj.get("stats") orelse return error.InvalidUiPayload;
        if (stats_val != .object) return error.InvalidUiPayload;
        const stats_obj = stats_val.object;
        return .{ .repair_candidate = try RepairCandidatePayload.init(
            allocator,
            getString(obj, "path") orelse return error.InvalidUiPayload,
            getString(obj, "plan_id") orelse return error.InvalidUiPayload,
            getString(obj, "intent_kind") orelse return error.InvalidUiPayload,
            getString(obj, "proposed_content") orelse return error.InvalidUiPayload,
            getBool(obj, "verification_ok") orelse return error.InvalidUiPayload,
            getString(obj, "verification_summary") orelse return error.InvalidUiPayload,
            .{
                .total = @intCast(getUnsigned(stats_obj, "total") orelse return error.InvalidUiPayload),
                .new = @intCast(getUnsigned(stats_obj, "new") orelse return error.InvalidUiPayload),
                .preexisting = if (getUnsigned(stats_obj, "preexisting")) |preexisting|
                    @intCast(preexisting)
                else
                    null,
            },
        ) };
    }
    if (std.mem.eql(u8, kind_val.string, "protocol_repair")) {
        const stats_val = obj.get("stats") orelse return error.InvalidUiPayload;
        const repairs_val = obj.get("repairs") orelse return error.InvalidUiPayload;
        if (stats_val != .object or repairs_val != .array) return error.InvalidUiPayload;
        var repairs_buf = TextBuffer.init(allocator);
        defer repairs_buf.deinit();
        try std.json.Stringify.value(repairs_val, .{}, repairs_buf.writer());
        const stats_obj = stats_val.object;
        return .{ .protocol_repair = try ProtocolRepairPayload.init(
            allocator,
            getString(obj, "path") orelse return error.InvalidUiPayload,
            getString(obj, "proposed_content") orelse return error.InvalidUiPayload,
            repairs_buf.written(),
            getString(obj, "source_digest") orelse return error.InvalidUiPayload,
            getString(obj, "profile_id") orelse return error.InvalidUiPayload,
            getString(obj, "policy_hash") orelse return error.InvalidUiPayload,
            getString(obj, "module_graph_hash") orelse return error.InvalidUiPayload,
            getString(obj, "verification_summary") orelse return error.InvalidUiPayload,
            .{
                .total = @intCast(getUnsigned(stats_obj, "total") orelse return error.InvalidUiPayload),
                .new = @intCast(getUnsigned(stats_obj, "new") orelse return error.InvalidUiPayload),
                .preexisting = if (getUnsigned(stats_obj, "preexisting")) |preexisting|
                    @intCast(preexisting)
                else
                    null,
            },
        ) };
    }
    if (std.mem.eql(u8, kind_val.string, "verified_change_set")) {
        const changes_value = obj.get("changes") orelse return error.InvalidUiPayload;
        const inputs_value = obj.get("proof_inputs") orelse return error.InvalidUiPayload;
        const roots_value = obj.get("proof_roots") orelse return error.InvalidUiPayload;
        if (changes_value != .array or changes_value.array.items.len == 0 or
            inputs_value != .array or inputs_value.array.items.len == 0 or
            roots_value != .array or roots_value.array.items.len == 0)
        {
            return error.InvalidUiPayload;
        }
        const transaction_id = getString(obj, "transaction_id") orelse return error.InvalidUiPayload;
        const policy_hash = getString(obj, "policy_hash") orelse return error.InvalidUiPayload;
        const grammar_hash = getString(obj, "grammar_hash") orelse return error.InvalidUiPayload;
        const semantics_hash = getString(obj, "semantics_hash") orelse return error.InvalidUiPayload;
        const diagnostic_hash = getString(obj, "diagnostic_catalog_hash") orelse return error.InvalidUiPayload;
        const read_set_digest = getString(obj, "read_set_digest") orelse return error.InvalidUiPayload;
        const hashes = [_][]const u8{
            transaction_id,
            policy_hash,
            grammar_hash,
            semantics_hash,
            diagnostic_hash,
            read_set_digest,
        };
        for (hashes) |hash| if (!isLowerHex64(hash)) return error.InvalidUiPayload;

        const changes = try parseVerifiedChanges(allocator, changes_value.array.items);
        errdefer {
            for (changes) |*change| change.deinit(allocator);
            allocator.free(changes);
        }
        const proof_inputs = try parseVerifiedProofInputs(allocator, inputs_value.array.items);
        errdefer {
            for (proof_inputs) |*input| input.deinit(allocator);
            allocator.free(proof_inputs);
        }
        const proof_roots = try parseStringArrayField(allocator, roots_value);
        errdefer freeStringSlice(allocator, proof_roots);
        const repair_plan_ids = try parseStringArrayField(allocator, obj.get("repair_plan_ids"));
        errdefer freeStringSlice(allocator, repair_plan_ids);
        const goal_context = try parseStringArrayField(allocator, obj.get("goal_context"));
        errdefer freeStringSlice(allocator, goal_context);
        const witnesses_defeated = try parseWitnessBodyArray(allocator, obj.get("witnesses_defeated"));
        errdefer freeWitnessBodySlice(allocator, witnesses_defeated);
        const witnesses_new = try parseWitnessBodyArray(allocator, obj.get("witnesses_new"));
        errdefer freeWitnessBodySlice(allocator, witnesses_new);

        const proof_schema_copy = try allocator.dupe(u8, getString(obj, "proof_schema_version") orelse return error.InvalidUiPayload);
        errdefer allocator.free(proof_schema_copy);
        const transaction_copy = try allocator.dupe(u8, transaction_id);
        errdefer allocator.free(transaction_copy);
        const compiler_copy = try allocator.dupe(u8, getString(obj, "compiler_version") orelse return error.InvalidUiPayload);
        errdefer allocator.free(compiler_copy);
        const profile_copy = try allocator.dupe(u8, getString(obj, "profile_id") orelse return error.InvalidUiPayload);
        errdefer allocator.free(profile_copy);
        const policy_copy = try allocator.dupe(u8, policy_hash);
        errdefer allocator.free(policy_copy);
        const grammar_copy = try allocator.dupe(u8, grammar_hash);
        errdefer allocator.free(grammar_copy);
        const semantics_copy = try allocator.dupe(u8, semantics_hash);
        errdefer allocator.free(semantics_copy);
        const diagnostic_copy = try allocator.dupe(u8, diagnostic_hash);
        errdefer allocator.free(diagnostic_copy);
        const read_set_copy = try allocator.dupe(u8, read_set_digest);
        errdefer allocator.free(read_set_copy);

        return .{ .verified_change_set = .{
            .proof_schema_version = proof_schema_copy,
            .transaction_id = transaction_copy,
            .compiler_version = compiler_copy,
            .profile_id = profile_copy,
            .policy_hash = policy_copy,
            .grammar_hash = grammar_copy,
            .semantics_hash = semantics_copy,
            .diagnostic_catalog_hash = diagnostic_copy,
            .read_set_digest = read_set_copy,
            .applied_at_unix_ms = getInteger(obj, "applied_at_unix_ms") orelse return error.InvalidUiPayload,
            .system_proven = getBool(obj, "system_proven") orelse return error.InvalidUiPayload,
            .baseline_primary_properties = try parsePropertiesSnapshot(obj.get("baseline_primary_properties")),
            .primary_properties = try parsePropertiesSnapshot(obj.get("primary_properties")),
            .proof_roots = proof_roots,
            .changes = changes,
            .proof_inputs = proof_inputs,
            .repair_plan_ids = repair_plan_ids,
            .goal_context = goal_context,
            .witnesses_defeated = witnesses_defeated,
            .witnesses_new = witnesses_new,
        } };
    }

    return .{ .plain_text = try std.fmt.allocPrint(
        allocator,
        "Unsupported UI payload kind: {s}",
        .{kind_val.string},
    ) };
}

fn parseVerifiedChanges(allocator: std.mem.Allocator, values: []const std.json.Value) ![]VerifiedChange {
    const changes = try allocator.alloc(VerifiedChange, values.len);
    for (changes) |*change| change.* = undefined;
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            changes[initialized].deinit(allocator);
        }
        allocator.free(changes);
    }
    while (initialized < values.len) : (initialized += 1) {
        const value = values[initialized];
        if (value != .object) return error.InvalidUiPayload;
        const obj = value.object;
        const baseline_state = getString(obj, "baseline_state") orelse return error.InvalidUiPayload;
        const baseline_sha256 = getString(obj, "baseline_sha256") orelse return error.InvalidUiPayload;
        const candidate_sha256 = getString(obj, "candidate_sha256") orelse return error.InvalidUiPayload;
        if ((!std.mem.eql(u8, baseline_state, "present") and !std.mem.eql(u8, baseline_state, "absent")) or
            !isLowerHex64(baseline_sha256) or !isLowerHex64(candidate_sha256))
        {
            return error.InvalidUiPayload;
        }
        const rewrite_trace = try parseStringArrayField(allocator, obj.get("rewrite_trace"));
        errdefer freeStringSlice(allocator, rewrite_trace);
        const file = try allocator.dupe(u8, getString(obj, "file") orelse return error.InvalidUiPayload);
        errdefer allocator.free(file);
        const state = try allocator.dupe(u8, baseline_state);
        errdefer allocator.free(state);
        const baseline = try allocator.dupe(u8, baseline_sha256);
        errdefer allocator.free(baseline);
        const candidate = try allocator.dupe(u8, candidate_sha256);
        errdefer allocator.free(candidate);
        const before_value = try getOptionalString(obj, "before");
        const before = if (before_value) |bytes| try allocator.dupe(u8, bytes) else null;
        errdefer if (before) |bytes| allocator.free(bytes);
        const after = try allocator.dupe(u8, getString(obj, "after") orelse return error.InvalidUiPayload);
        errdefer allocator.free(after);
        const diff = try allocator.dupe(u8, getString(obj, "unified_diff") orelse return error.InvalidUiPayload);
        errdefer allocator.free(diff);
        changes[initialized] = .{
            .file = file,
            .baseline_state = state,
            .baseline_sha256 = baseline,
            .candidate_sha256 = candidate,
            .before = before,
            .after = after,
            .unified_diff = diff,
            .rewrite_trace = rewrite_trace,
        };
    }
    return changes;
}

fn parseVerifiedProofInputs(allocator: std.mem.Allocator, values: []const std.json.Value) ![]VerifiedProofInput {
    const inputs = try allocator.alloc(VerifiedProofInput, values.len);
    for (inputs) |*input| input.* = undefined;
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            inputs[initialized].deinit(allocator);
        }
        allocator.free(inputs);
    }
    while (initialized < values.len) : (initialized += 1) {
        const value = values[initialized];
        if (value != .object) return error.InvalidUiPayload;
        const obj = value.object;
        const state_value = getString(obj, "state") orelse return error.InvalidUiPayload;
        const digest_value = getString(obj, "sha256") orelse return error.InvalidUiPayload;
        if ((!std.mem.eql(u8, state_value, "present") and !std.mem.eql(u8, state_value, "absent")) or
            !isLowerHex64(digest_value))
        {
            return error.InvalidUiPayload;
        }
        const path = try allocator.dupe(u8, getString(obj, "path") orelse return error.InvalidUiPayload);
        errdefer allocator.free(path);
        const state = try allocator.dupe(u8, state_value);
        errdefer allocator.free(state);
        const digest = try allocator.dupe(u8, digest_value);
        errdefer allocator.free(digest);
        inputs[initialized] = .{ .path = path, .state = state, .sha256 = digest };
    }
    return inputs;
}

fn isLowerHex64(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn parseHash32(value_opt: ?std.json.Value) !?[32]u8 {
    const value = value_opt orelse return null;
    return switch (value) {
        .null => null,
        .string => |s| blk: {
            if (s.len != 64) return error.InvalidUiPayload;
            var out: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const hi = hexNibble(s[i * 2]) orelse return error.InvalidUiPayload;
                const lo = hexNibble(s[i * 2 + 1]) orelse return error.InvalidUiPayload;
                out[i] = (hi << 4) | lo;
            }
            break :blk out;
        },
        else => error.InvalidUiPayload,
    };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn writeOptionalStringArray(
    writer: *std.Io.Writer,
    field_name: []const u8,
    items: []const []u8,
) !void {
    if (items.len == 0) return;
    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("\":[");
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeOptionalWitnessBodyArray(
    writer: *std.Io.Writer,
    field_name: []const u8,
    items: []const WitnessBody,
) !void {
    if (items.len == 0) return;
    try writer.writeAll(",\"");
    try writer.writeAll(field_name);
    try writer.writeAll("\":[");
    for (items, 0..) |body, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"key\":");
        try json_writer.writeString(writer, body.key);
        try writer.writeAll(",\"property\":");
        try json_writer.writeString(writer, body.property);
        try writer.writeAll(",\"summary\":");
        try json_writer.writeString(writer, body.summary);
        try writer.print(
            ",\"origin\":{{\"line\":{d},\"column\":{d}}},\"sink\":{{\"line\":{d},\"column\":{d}}},\"request\":{{\"method\":",
            .{ body.origin_line, body.origin_column, body.sink_line, body.sink_column },
        );
        try json_writer.writeString(writer, body.request_method);
        try writer.writeAll(",\"url\":");
        try json_writer.writeString(writer, body.request_url);
        try writer.writeAll(",\"has_auth_header\":");
        try writer.writeAll(if (body.request_has_auth) "true" else "false");
        if (body.request_body) |b| {
            try writer.writeAll(",\"body\":");
            try json_writer.writeString(writer, b);
        } else {
            try writer.writeAll(",\"body\":null");
        }
        try writer.writeAll("},\"io_stubs\":[");
        for (body.io_stubs, 0..) |stub, si| {
            if (si > 0) try writer.writeByte(',');
            try writer.print("{{\"seq\":{d},\"module\":", .{stub.seq});
            try json_writer.writeString(writer, stub.module);
            try writer.writeAll(",\"func\":");
            try json_writer.writeString(writer, stub.func);
            try writer.writeAll(",\"result_json\":");
            try json_writer.writeString(writer, stub.result_json);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');
}

fn writePropertiesSnapshot(writer: *std.Io.Writer, snapshot: ?PropertiesSnapshot) !void {
    if (snapshot) |value| {
        try writer.writeByte('{');
        inline for (@typeInfo(PropertiesSnapshot).@"struct".fields, 0..) |field, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeByte('"');
            try writer.writeAll(field.name);
            try writer.writeAll("\":");
            switch (@typeInfo(field.type)) {
                .bool => try writer.writeAll(if (@field(value, field.name)) "true" else "false"),
                .optional => {
                    if (@field(value, field.name)) |number| {
                        try writer.print("{d}", .{number});
                    } else {
                        try writer.writeAll("null");
                    }
                },
                else => @compileError("unsupported PropertiesSnapshot field type"),
            }
        }
        try writer.writeByte('}');
        return;
    }
    try writer.writeAll("null");
}

fn parsePropertiesSnapshot(value_opt: ?std.json.Value) !?PropertiesSnapshot {
    const value = value_opt orelse return null;
    return switch (value) {
        .null => null,
        .object => |obj| .{
            .pure = getBoolOrDefault(obj, "pure", false),
            .read_only = getBoolOrDefault(obj, "read_only", false),
            .stateless = getBoolOrDefault(obj, "stateless", false),
            .retry_safe = getBoolOrDefault(obj, "retry_safe", false),
            .deterministic = getBoolOrDefault(obj, "deterministic", false),
            .has_egress = getBoolOrDefault(obj, "has_egress", false),
            .no_secret_leakage = getBoolOrDefault(obj, "no_secret_leakage", false),
            .no_credential_leakage = getBoolOrDefault(obj, "no_credential_leakage", false),
            .input_validated = getBoolOrDefault(obj, "input_validated", false),
            .pii_contained = getBoolOrDefault(obj, "pii_contained", false),
            .idempotent = getBoolOrDefault(obj, "idempotent", false),
            .max_io_depth = try getOptionalUnsignedValue(obj.get("max_io_depth")),
            .injection_safe = getBoolOrDefault(obj, "injection_safe", false),
            .state_isolated = getBoolOrDefault(obj, "state_isolated", false),
            .fault_covered = getBoolOrDefault(obj, "fault_covered", false),
            .result_safe = getBoolOrDefault(obj, "result_safe", false),
            .optional_safe = getBoolOrDefault(obj, "optional_safe", false),
            .canonical = getBoolOrDefault(obj, "canonical", false),
        },
        else => error.InvalidUiPayload,
    };
}

fn parseDiffHunks(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]DiffHunk {
    const value = value_opt orelse return allocator.alloc(DiffHunk, 0);
    if (value == .null) return allocator.alloc(DiffHunk, 0);
    if (value != .array) return error.InvalidUiPayload;

    const hunks = try allocator.alloc(DiffHunk, value.array.items.len);
    errdefer allocator.free(hunks);
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidUiPayload;
        const item_obj = item.object;
        hunks[i] = .{
            .old_start = @intCast(getUnsigned(item_obj, "old_start") orelse return error.InvalidUiPayload),
            .old_count = @intCast(getUnsigned(item_obj, "old_count") orelse return error.InvalidUiPayload),
            .new_start = @intCast(getUnsigned(item_obj, "new_start") orelse return error.InvalidUiPayload),
            .new_count = @intCast(getUnsigned(item_obj, "new_count") orelse return error.InvalidUiPayload),
        };
    }
    return hunks;
}

fn parseViolationDeltaItems(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]ViolationDeltaItem {
    const value = value_opt orelse return allocator.alloc(ViolationDeltaItem, 0);
    if (value == .null) return allocator.alloc(ViolationDeltaItem, 0);
    if (value != .array) return error.InvalidUiPayload;

    const violations = try allocator.alloc(ViolationDeltaItem, value.array.items.len);
    errdefer allocator.free(violations);
    for (violations) |*item| item.* = undefined;
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            violations[i].deinit(allocator);
        }
        allocator.free(violations);
    }
    while (i < value.array.items.len) : (i += 1) {
        const item = value.array.items[i];
        if (item != .object) return error.InvalidUiPayload;
        const item_obj = item.object;
        violations[i] = try ViolationDeltaItem.init(
            allocator,
            getString(item_obj, "stable_key") orelse return error.InvalidUiPayload,
            getString(item_obj, "code") orelse return error.InvalidUiPayload,
            getString(item_obj, "severity") orelse return error.InvalidUiPayload,
            getString(item_obj, "message") orelse return error.InvalidUiPayload,
            @intCast(getUnsigned(item_obj, "line") orelse return error.InvalidUiPayload),
            @intCast(getUnsigned(item_obj, "column") orelse return error.InvalidUiPayload),
            getBool(item_obj, "introduced_by_patch") orelse return error.InvalidUiPayload,
        );
    }
    return violations;
}

fn parseProveSummary(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !?ProveSummary {
    const value = value_opt orelse return null;
    return switch (value) {
        .null => null,
        .object => |obj| blk: {
            const laws_used = try parseStringArrayField(allocator, obj.get("laws_used"));
            errdefer freeStringSlice(allocator, laws_used);
            const counterexample = blk_counterexample: {
                const text = try getOptionalString(obj, "counterexample");
                break :blk_counterexample if (text) |t| try allocator.dupe(u8, t) else null;
            };
            errdefer if (counterexample) |text| allocator.free(text);
            break :blk .{
                .classification = try allocator.dupe(u8, getString(obj, "classification") orelse return error.InvalidUiPayload),
                .proof_level = try allocator.dupe(u8, getString(obj, "proof_level") orelse return error.InvalidUiPayload),
                .recommendation = try allocator.dupe(u8, getString(obj, "recommendation") orelse ""),
                .counterexample = counterexample,
                .laws_used = laws_used,
            };
        },
        else => error.InvalidUiPayload,
    };
}

fn parseSystemProofSummary(allocator: std.mem.Allocator, value_opt: ?std.json.Value) !?SystemProofSummary {
    const value = value_opt orelse return null;
    return switch (value) {
        .null => null,
        .object => |obj| blk: {
            const warnings = try parseStringArrayField(allocator, obj.get("warnings"));
            errdefer freeStringSlice(allocator, warnings);
            break :blk .{
                .system_path = try allocator.dupe(u8, getString(obj, "system_path") orelse return error.InvalidUiPayload),
                .proof_level = try allocator.dupe(u8, getString(obj, "proof_level") orelse return error.InvalidUiPayload),
                .all_links_resolved = getBoolOrDefault(obj, "all_links_resolved", false),
                .all_responses_covered = getBoolOrDefault(obj, "all_responses_covered", false),
                .payload_compatible = getBoolOrDefault(obj, "payload_compatible", false),
                .injection_safe = getBoolOrDefault(obj, "injection_safe", false),
                .no_secret_leakage = getBoolOrDefault(obj, "no_secret_leakage", false),
                .no_credential_leakage = getBoolOrDefault(obj, "no_credential_leakage", false),
                .retry_safe = getBoolOrDefault(obj, "retry_safe", false),
                .fault_covered = getBoolOrDefault(obj, "fault_covered", false),
                .state_isolated = getBoolOrDefault(obj, "state_isolated", false),
                .max_system_io_depth = try getOptionalUnsignedValue(obj.get("max_system_io_depth")),
                .dynamic_links = @intCast(getUnsignedOrDefault(obj, "dynamic_links", 0)),
                .warnings = warnings,
            };
        },
        else => error.InvalidUiPayload,
    };
}

fn parseStringArrayField(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![][]u8 {
    const value = value_opt orelse return allocator.alloc([]u8, 0);
    if (value == .null) return allocator.alloc([]u8, 0);
    if (value != .array) return error.InvalidUiPayload;

    const items = try allocator.alloc([]u8, value.array.items.len);
    errdefer allocator.free(items);
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            allocator.free(items[i]);
        }
        allocator.free(items);
    }
    while (i < value.array.items.len) : (i += 1) {
        const item = value.array.items[i];
        if (item != .string) return error.InvalidUiPayload;
        items[i] = try allocator.dupe(u8, item.string);
    }
    return items;
}

fn parseWitnessBodyArray(
    allocator: std.mem.Allocator,
    value_opt: ?std.json.Value,
) ![]WitnessBody {
    const value = value_opt orelse return allocator.alloc(WitnessBody, 0);
    if (value == .null) return allocator.alloc(WitnessBody, 0);
    if (value != .array) return error.InvalidUiPayload;

    const items = try allocator.alloc(WitnessBody, value.array.items.len);
    errdefer allocator.free(items);
    for (items) |*body| body.* = undefined;
    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            items[i].deinit(allocator);
        }
        allocator.free(items);
    }
    while (i < value.array.items.len) : (i += 1) {
        items[i] = try parseWitnessBody(allocator, value.array.items[i]);
    }
    return items;
}

fn parseWitnessBody(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !WitnessBody {
    if (value != .object) return error.InvalidUiPayload;
    const obj = value.object;

    const origin_obj = obj.get("origin") orelse return error.InvalidUiPayload;
    if (origin_obj != .object) return error.InvalidUiPayload;
    const sink_obj = obj.get("sink") orelse return error.InvalidUiPayload;
    if (sink_obj != .object) return error.InvalidUiPayload;
    const request_obj = obj.get("request") orelse return error.InvalidUiPayload;
    if (request_obj != .object) return error.InvalidUiPayload;

    const key_copy = try allocator.dupe(u8, getString(obj, "key") orelse return error.InvalidUiPayload);
    errdefer allocator.free(key_copy);
    const property_copy = try allocator.dupe(u8, getString(obj, "property") orelse return error.InvalidUiPayload);
    errdefer allocator.free(property_copy);
    const summary_copy = try allocator.dupe(u8, getString(obj, "summary") orelse "");
    errdefer allocator.free(summary_copy);
    const method_copy = try allocator.dupe(u8, getString(request_obj.object, "method") orelse return error.InvalidUiPayload);
    errdefer allocator.free(method_copy);
    const url_copy = try allocator.dupe(u8, getString(request_obj.object, "url") orelse return error.InvalidUiPayload);
    errdefer allocator.free(url_copy);
    const has_auth = getBoolOrDefault(request_obj.object, "has_auth_header", false);
    const body_text = try getOptionalString(request_obj.object, "body");
    const body_copy: ?[]u8 = if (body_text) |t| try allocator.dupe(u8, t) else null;
    errdefer if (body_copy) |b| allocator.free(b);

    const stubs_value = obj.get("io_stubs") orelse return error.InvalidUiPayload;
    if (stubs_value != .array) return error.InvalidUiPayload;
    const stubs = try allocator.alloc(WitnessStub, stubs_value.array.items.len);
    errdefer allocator.free(stubs);
    for (stubs) |*stub| stub.* = undefined;
    var si: usize = 0;
    errdefer {
        while (si > 0) {
            si -= 1;
            stubs[si].deinit(allocator);
        }
    }
    while (si < stubs_value.array.items.len) : (si += 1) {
        const stub_val = stubs_value.array.items[si];
        if (stub_val != .object) return error.InvalidUiPayload;
        const stub_obj = stub_val.object;
        const seq_value = getUnsigned(stub_obj, "seq") orelse return error.InvalidUiPayload;
        const module_copy = try allocator.dupe(u8, getString(stub_obj, "module") orelse return error.InvalidUiPayload);
        errdefer allocator.free(module_copy);
        const func_copy = try allocator.dupe(u8, getString(stub_obj, "func") orelse return error.InvalidUiPayload);
        errdefer allocator.free(func_copy);
        const result_copy = try allocator.dupe(u8, getString(stub_obj, "result_json") orelse return error.InvalidUiPayload);
        stubs[si] = .{
            .seq = @intCast(seq_value),
            .module = module_copy,
            .func = func_copy,
            .result_json = result_copy,
        };
    }

    return .{
        .key = key_copy,
        .property = property_copy,
        .summary = summary_copy,
        .origin_line = @intCast(getUnsigned(origin_obj.object, "line") orelse return error.InvalidUiPayload),
        .origin_column = @intCast(getUnsigned(origin_obj.object, "column") orelse return error.InvalidUiPayload),
        .sink_line = @intCast(getUnsigned(sink_obj.object, "line") orelse return error.InvalidUiPayload),
        .sink_column = @intCast(getUnsigned(sink_obj.object, "column") orelse return error.InvalidUiPayload),
        .request_method = method_copy,
        .request_url = url_copy,
        .request_has_auth = has_auth,
        .request_body = body_copy,
        .io_stubs = stubs,
    };
}

pub fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidUiPayload,
    };
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

pub fn getBoolOrDefault(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    return getBool(obj, key) orelse default;
}

pub fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

pub fn getUnsigned(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(usize, value.integer);
}

fn getUnsignedOrDefault(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    return getUnsigned(obj, key) orelse default;
}

fn getOptionalUnsignedValue(value_opt: ?std.json.Value) !?u32 {
    const value = value_opt orelse return null;
    return switch (value) {
        .null => null,
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidUiPayload;
            break :blk std.math.cast(u32, integer) orelse return error.InvalidUiPayload;
        },
        else => error.InvalidUiPayload,
    };
}

const testing = std.testing;

fn roundTrip(allocator: std.mem.Allocator, payload: UiPayload) !UiPayload {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try writeJson(buf.writer(), payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.written(), .{});
    defer parsed.deinit();
    return try parse(allocator, parsed.value);
}

test "plain_text payload round-trips" {
    var payload: UiPayload = .{ .plain_text = try testing.allocator.dupe(u8, "hello") };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .plain_text => |text| try testing.expectEqualStrings("hello", text),
        else => return error.TestFailed,
    }
}

test "generic clone deep-copies nested slices and frees idempotently" {
    const a = testing.allocator;

    const highlights = try a.alloc([]u8, 1);
    highlights[0] = try a.dupe(u8, "proof complete");
    var payload: ProofCardPayload = .{
        .title = try a.dupe(u8, "Proof"),
        .summary = try a.dupe(u8, "verified"),
        .stats = .{ .total = 3, .new = 1, .preexisting = 2 },
        .highlights = highlights,
    };
    defer payload.deinit(a);

    var copy = try payload.clone(a);
    defer copy.deinit(a);

    // A deep copy, not an aliasing one.
    try testing.expectEqualStrings("Proof", copy.title);
    try testing.expectEqualStrings("proof complete", copy.highlights[0]);
    try testing.expect(copy.title.ptr != payload.title.ptr);
    try testing.expect(copy.highlights.ptr != payload.highlights.ptr);
    try testing.expect(copy.highlights[0].ptr != payload.highlights[0].ptr);
    try testing.expectEqual(@as(u32, 2), copy.stats.preexisting.?);

    // Freeing twice is a no-op: the walk blanks pointer fields as it goes, so a
    // caller that deinits a payload it already released does not double free.
    copy.deinit(a);
}

test "generic clone leaks nothing when an allocation fails partway" {
    const a = testing.allocator;

    const items = try a.alloc(DiagnosticItem, 2);
    items[0] = try DiagnosticItem.init(a, "ZTS001", "error", "handler.ts", 1, 1, "first", null);
    items[1] = try DiagnosticItem.init(a, "ZTS002", "warning", "handler.ts", 2, 2, "second", true);
    var source: DiagnosticsPayload = .{
        .summary = try a.dupe(u8, "2 violations"),
        .items = items,
    };
    defer source.deinit(a);

    // The hand-written clones duped straight into a struct literal with no
    // unwind, so a failure on a later field leaked every field already duped.
    // Walk every failure index: each must report OutOfMemory and leave nothing
    // behind, which the testing allocator asserts at teardown.
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        if (source.clone(failing.allocator())) |cloned| {
            var owned = cloned;
            owned.deinit(failing.allocator());
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try testing.expect(fail_index > 0);
}

test "diagnostics payload round-trips" {
    const items = try testing.allocator.alloc(DiagnosticItem, 1);
    items[0] = try DiagnosticItem.init(
        testing.allocator,
        "ZTS001",
        "error",
        "handler.ts",
        3,
        7,
        "unsupported feature",
        true,
    );
    var payload: UiPayload = .{ .diagnostics = .{
        .summary = try testing.allocator.dupe(u8, "1 violation"),
        .items = items,
    } };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .diagnostics => |diagnostics| {
            try testing.expectEqualStrings("1 violation", diagnostics.summary);
            try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
            try testing.expectEqualStrings("ZTS001", diagnostics.items[0].code);
            try testing.expect(diagnostics.items[0].introduced_by_patch.?);
        },
        else => return error.TestFailed,
    }
}

test "proof card payload round-trips" {
    const highlights = try testing.allocator.alloc([]u8, 2);
    highlights[0] = try testing.allocator.dupe(u8, "retry_safe");
    highlights[1] = try testing.allocator.dupe(u8, "idempotent");
    var payload: UiPayload = .{ .proof_card = .{
        .title = try testing.allocator.dupe(u8, "Compiler verification"),
        .summary = try testing.allocator.dupe(u8, "No new violations"),
        .stats = .{ .total = 1, .new = 0, .preexisting = 1 },
        .highlights = highlights,
    } };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .proof_card => |proof| {
            try testing.expectEqualStrings("Compiler verification", proof.title);
            try testing.expectEqual(@as(u32, 1), proof.stats.total);
            try testing.expectEqual(@as(usize, 2), proof.highlights.len);
        },
        else => return error.TestFailed,
    }
}

test "command outcome payload round-trips" {
    var payload: UiPayload = .{ .command_outcome = .{
        .title = try testing.allocator.dupe(u8, "zig test"),
        .exit_code = 0,
        .stdout = try testing.allocator.dupe(u8, "ok"),
        .stderr = try testing.allocator.dupe(u8, ""),
        .command = try testing.allocator.dupe(u8, "zig build test-zts"),
    } };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .command_outcome => |command| {
            try testing.expectEqualStrings("zig test", command.title);
            try testing.expectEqual(@as(?u8, 0), command.exit_code);
            try testing.expectEqualStrings("zig build test-zts", command.command);
        },
        else => return error.TestFailed,
    }
}

test "repair candidate payload round-trips" {
    var payload: UiPayload = .{ .repair_candidate = try RepairCandidatePayload.init(
        testing.allocator,
        "handler.ts",
        "rp_001",
        "insert_guard_before_line",
        "function handler(req: Request): Response { return Response.json({ ok: true }); }",
        true,
        "0 total, 0 new, 0 preexisting",
        .{ .total = 0, .new = 0, .preexisting = 0 },
    ) };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .repair_candidate => |candidate| {
            try testing.expectEqualStrings("handler.ts", candidate.path);
            try testing.expectEqualStrings("rp_001", candidate.plan_id);
            try testing.expectEqualStrings("insert_guard_before_line", candidate.intent_kind);
            try testing.expect(candidate.verification_ok);
            try testing.expectEqual(@as(u32, 0), candidate.stats.new);
            try testing.expect(std.mem.indexOf(u8, candidate.proposed_content, "Response.json") != null);
        },
        else => return error.TestFailed,
    }
}

test "protocol repair payload round-trips exact binding" {
    var payload: UiPayload = .{ .protocol_repair = try ProtocolRepairPayload.init(
        testing.allocator,
        "handler.ts",
        "const answer = 42;",
        "[{\"intent\":\"replace_let_with_const\",\"bound\":{\"source_digest\":\"source\"}}]",
        "source",
        "zts-model-1",
        "policy",
        "graph",
        "0 new, 1 preexisting",
        .{ .total = 1, .new = 0, .preexisting = 1 },
    ) };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .protocol_repair => |repair| {
            try testing.expectEqualStrings("handler.ts", repair.path);
            try testing.expectEqualStrings("const answer = 42;", repair.proposed_content);
            try testing.expectEqualStrings("zts-model-1", repair.profile_id);
            try testing.expectEqualStrings("policy", repair.policy_hash);
            try testing.expectEqualStrings("graph", repair.module_graph_hash);
            try testing.expect(std.mem.indexOf(u8, repair.repairs_json, "replace_let_with_const") != null);
        },
        else => return error.TestFailed,
    }
}

test "verified change set payload round-trips every proof binding" {
    const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var rewrites = [_][]u8{@constCast("normalize-semicolon")};
    var changes = [_]VerifiedChange{.{
        .file = @constCast("src/a.ts"),
        .baseline_state = @constCast("present"),
        .baseline_sha256 = @constCast(hash),
        .candidate_sha256 = @constCast(hash),
        .before = @constCast("old"),
        .after = @constCast("new"),
        .unified_diff = @constCast("@@ -1,1 +1,1 @@\n-old\n+new\n"),
        .rewrite_trace = &rewrites,
    }};
    var inputs = [_]VerifiedProofInput{.{
        .path = @constCast("src/a.ts"),
        .state = @constCast("present"),
        .sha256 = @constCast(hash),
    }};
    var roots = [_][]u8{@constCast("src/a.ts")};
    const source: VerifiedChangeSetPayload = .{
        .proof_schema_version = @constCast("zttp-aggregate-source-proof-v1"),
        .transaction_id = @constCast(hash),
        .compiler_version = @constCast("0.1.0"),
        .profile_id = @constCast("zttp-public-v1"),
        .policy_hash = @constCast(hash),
        .grammar_hash = @constCast(hash),
        .semantics_hash = @constCast(hash),
        .diagnostic_catalog_hash = @constCast(hash),
        .read_set_digest = @constCast(hash),
        .applied_at_unix_ms = 42,
        .system_proven = true,
        .proof_roots = &roots,
        .changes = &changes,
        .proof_inputs = &inputs,
    };
    var payload: UiPayload = .{ .verified_change_set = try source.clone(testing.allocator) };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);
    switch (roundtripped) {
        .verified_change_set => |receipt| {
            try testing.expectEqualStrings(hash, receipt.transaction_id);
            try testing.expectEqual(@as(usize, 1), receipt.changes.len);
            try testing.expectEqualStrings("src/a.ts", receipt.changes[0].file);
            try testing.expectEqualStrings("new", receipt.changes[0].after);
            try testing.expectEqualStrings("normalize-semicolon", receipt.changes[0].rewrite_trace[0]);
            try testing.expectEqual(@as(usize, 1), receipt.proof_inputs.len);
            try testing.expect(receipt.system_proven);
        },
        else => return error.TestFailed,
    }
}

test "verified change set parser rejects an empty proof cohort" {
    const json =
        \\{"kind":"verified_change_set","changes":[],"proof_inputs":[],"proof_roots":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(error.InvalidUiPayload, parse(testing.allocator, parsed.value));
}

test "session tree payload round-trips" {
    const nodes = try testing.allocator.alloc(SessionTreeNode, 2);
    nodes[0] = .{
        .session_id = try testing.allocator.dupe(u8, "root"),
        .parent_id = null,
        .created_at_unix_ms = 1,
        .depth = 0,
        .is_current = false,
        .is_orphan_root = false,
    };
    nodes[1] = .{
        .session_id = try testing.allocator.dupe(u8, "child"),
        .parent_id = try testing.allocator.dupe(u8, "root"),
        .created_at_unix_ms = 2,
        .depth = 1,
        .is_current = true,
        .is_orphan_root = false,
    };
    var payload: UiPayload = .{ .session_tree = .{ .nodes = nodes } };
    defer payload.deinit(testing.allocator);

    var roundtripped = try roundTrip(testing.allocator, payload);
    defer roundtripped.deinit(testing.allocator);

    switch (roundtripped) {
        .session_tree => |tree| {
            try testing.expectEqual(@as(usize, 2), tree.nodes.len);
            try testing.expectEqualStrings("child", tree.nodes[1].session_id);
            try testing.expect(tree.nodes[1].is_current);
        },
        else => return error.TestFailed,
    }
}
