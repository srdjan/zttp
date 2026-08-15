//! Versioned wire contract for fail-closed flow-cassette artifacts.

const std = @import("std");
const models = @import("../providers/models.zig");
const context_budget = @import("../context_budget.zig");

pub const schema_version: u32 = 1;

pub const Limits = struct {
    pub const manifest_bytes: usize = 1 * 1024 * 1024;
    pub const trace_or_response_bytes: usize = 8 * 1024 * 1024;
    pub const workspace_file_bytes: usize = 8 * 1024 * 1024;
    pub const case_bytes: usize = 128 * 1024 * 1024;
    pub const path_bytes: usize = 1024;
    pub const files: usize = 1024;
    pub const turns: usize = 32;
    pub const model_checkpoints: usize = 256;
    pub const approval_checkpoints: usize = 256;
    pub const diagnostic_bytes: usize = 256;
};

pub const Sha256Hex = struct {
    bytes: [64]u8,

    pub fn fromBytes(bytes: []const u8) Sha256Hex {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return .{ .bytes = std.fmt.bytesToHex(digest, .lower) };
    }

    pub fn eql(a: Sha256Hex, b: Sha256Hex) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn slice(self: *const Sha256Hex) []const u8 {
        return &self.bytes;
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Sha256Hex {
        const raw = try std.json.innerParse([]const u8, allocator, source, options);
        if (raw.len != 64) return error.UnexpectedToken;
        var out: Sha256Hex = undefined;
        for (raw, 0..) |byte, i| {
            if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.UnexpectedToken;
            out.bytes[i] = byte;
        }
        return out;
    }

    pub fn jsonStringify(self: Sha256Hex, json: anytype) !void {
        try json.write(&self.bytes);
    }
};

pub const EvidenceClass = enum { empirical_model, deterministic_harness };
pub const Provider = models.Provider;
pub const ApprovalDecision = enum { approve, reject };
pub const TurnOutcome = enum {
    approved,
    approval_denied,
    veto_exhausted,
    budget_roundtrips,
    budget_tool_calls,
    budget_timeout,
    error_exit,
};
pub const EventKind = enum {
    user_text,
    model_text,
    tool_use,
    tool_result,
    proof_card,
    diagnostic_box,
    verified_patch,
    system_note,
    turn_end,
};
pub const TranscriptItemKind = enum {
    user_text,
    model_text,
    assistant_tool_use,
    tool_result,
    proof_card,
    diagnostic_box,
    verified_patch,
    system_note,
};
pub const WorkspaceChangeKind = enum { created, changed, deleted };

pub const CaseDescriptor = struct {
    schema_version: u32,
    case_name: []const u8,
    evidence_class: EvidenceClass,
    executable: bool,
    active_generation: Sha256Hex,
};

pub const TurnExpectation = struct {
    index: u32,
    user_input: []const u8,
    outcome: TurnOutcome,
    final_response_sha256: Sha256Hex,
    /// The provider-specific first-draft result captured for this turn.
    /// Historical artifacts omit it and decode as null.
    first_draft_veto_pass: ?bool = null,

    pub fn jsonStringify(self: TurnExpectation, json: anytype) !void {
        try json.beginObject();
        try json.objectField("index");
        try json.write(self.index);
        try json.objectField("user_input");
        try json.write(self.user_input);
        try json.objectField("outcome");
        try json.write(self.outcome);
        try json.objectField("final_response_sha256");
        try json.write(self.final_response_sha256);
        if (self.first_draft_veto_pass) |expectation| {
            try json.objectField("first_draft_veto_pass");
            try json.write(expectation);
        }
        try json.endObject();
    }
};

pub const ResponseFixture = struct {
    index: u32,
    turn_index: u32,
    call_index: u32,
    path: []const u8,
    sha256: Sha256Hex,
};

pub const ApprovalExpectation = struct {
    index: u32,
    turn_index: u32,
    checkpoint_index: u32,
    decision: ApprovalDecision,
};

pub const EventExpectation = struct {
    index: u32,
    turn_index: u32,
    kind: EventKind,
    payload_sha256: Sha256Hex,
};

pub const WorkspaceFixture = struct {
    path: []const u8,
    sha256: Sha256Hex,
};

pub const TurnWorkspaceCheckpoint = struct {
    turn_index: u32,
    files: []const WorkspaceFixture,
};

pub const WorkspaceChange = struct {
    path: []const u8,
    kind: WorkspaceChangeKind,
};

pub const ArtifactReference = struct {
    path: []const u8,
    sha256: Sha256Hex,
};

pub const FlowManifest = struct {
    schema_version: u32,
    flow_version: Sha256Hex,
    case_name: []const u8,
    evidence_class: EvidenceClass,
    executable: bool,
    provider: Provider,
    model: []const u8,
    /// Exact source revision when the local model cache exposes it. Historical
    /// manifests omit this field and decode as null.
    model_revision: ?[]const u8 = null,
    /// MLX-LM version reported by the local server response fingerprint.
    /// Cloud and historical manifests omit it.
    mlx_lm_version: ?[]const u8 = null,
    /// The local server stack, for a stack that reports no MLX-LM
    /// fingerprint. rapid-mlx sends no `system_fingerprint` and exposes no
    /// version over HTTP, so the recorder cannot read the identity off the
    /// wire and the operator declares it instead. The two fields are present
    /// together or absent together: a name with no version names nothing
    /// reproducible. Cloud and historical manifests omit both.
    runtime_name: ?[]const u8 = null,
    runtime_version: ?[]const u8 = null,
    turns: []const TurnExpectation,
    model_responses: []const ResponseFixture,
    approvals: []const ApprovalExpectation,
    events: []const EventExpectation,
    allowed_workspace_changes: []const WorkspaceChange,
    initial_workspace: []const WorkspaceFixture,
    turn_workspaces: []const TurnWorkspaceCheckpoint,
    expected_workspace: []const WorkspaceFixture,
    trace: ArtifactReference,
};

pub const ModelCheckpoint = struct {
    index: u32,
    turn_index: u32,
    call_index: u32,
    transcript_prefix_count: u32,
    transcript_sha256: Sha256Hex,
    request_context_sha256: Sha256Hex,
    transient_user_text_sha256: ?Sha256Hex,
    wire_request_sha256: ?Sha256Hex = null,
    /// Complete provider-neutral request accounting. Historical artifacts
    /// omit it; every new recording writes it.
    request_budget: ?context_budget.RequestBudget = null,
    /// Provider-reported logical input after cache fields are normalized.
    /// Historical artifacts omit it; every new recording writes it.
    normalized_input_tokens: ?u64 = null,
    /// Stable raw-entry cut used by the active model projection, when any.
    projection_first_kept_entry_id: ?u64 = null,
};

pub const ApprovalCheckpoint = struct {
    index: u32,
    turn_index: u32,
    checkpoint_index: u32,
    preview_sha256: Sha256Hex,
};

pub const TranscriptItem = struct {
    index: u32,
    turn_index: u32,
    kind: TranscriptItemKind,
    payload_sha256: Sha256Hex,
};

pub const ApplyReceipt = struct {
    index: u32,
    turn_index: u32,
    payload_sha256: Sha256Hex,
};

pub const InteractionTrace = struct {
    schema_version: u32,
    model_calls: []const ModelCheckpoint,
    approvals: []const ApprovalCheckpoint,
    transcript_items: []const TranscriptItem,
    apply_receipts: []const ApplyReceipt,
};

pub const FixtureRole = enum { trace, response, initial_workspace, turn_workspace, expected_workspace };

pub const LoadedFixture = struct {
    role: FixtureRole,
    path: []const u8,
    bytes: []const u8,
};
