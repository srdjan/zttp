//! In-memory collection of one complete interaction flow.
//!
//! Model requests and raw responses arrive synchronously through `CaptureSink`.
//! Turns, approval previews, transcript events, and exact workspace snapshots
//! are added at the production loop boundary. Promotion is delegated to the
//! crash-safe content-addressed store only after collection is complete.

const std = @import("std");
const zts = @import("zts");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const artifact = @import("artifact.zig");
const observation = @import("observation.zig");
const recording_storage = @import("recording_storage.zig");
const capture_sink = @import("../providers/capture_sink.zig");
const cassette_client = @import("../providers/cassette_client.zig");
const cassette_record = @import("../providers/cassette_record.zig");
const context_budget = @import("../context_budget.zig");
const model_request = @import("../providers/model_request.zig");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");

/// Safe, metadata-only progress emitted after a model exchange is fully
/// captured. Prompt, response, tool arguments, and workspace bytes are never
/// present in this event surface.
pub const ModelCallCompleted = struct {
    global_call_index: usize,
    turn_index: u32,
    turn_call_index: u32,
    purpose: model_request.Purpose,
    estimated_input_tokens: u64,
    estimate_source: context_budget.EstimateSource,
    reported_input_tokens: u64,
    logical_input_tokens: u64,
    input_observation_source: context_budget.InputObservationSource,
    output_tokens: u64,
    output_limit_tokens: u32,
    wire_bytes: u64,
};

pub const ModelCallFailed = struct {
    attempt_index: usize,
    provider: model_request.Provider,
    latency_ms: ?u64,
    http_status: ?u16,
    failure: anyerror,
};

pub const ProgressEvent = union(enum) {
    model_call_completed: ModelCallCompleted,
    model_call_failed: ModelCallFailed,
};

pub const ProgressObserver = struct {
    context: *anyopaque,
    on_event: *const fn (context: *anyopaque, event: ProgressEvent) void,

    pub fn emit(self: ProgressObserver, event: ProgressEvent) void {
        self.on_event(self.context, event);
    }
};

pub const Options = struct {
    case_name: []const u8,
    evidence_class: artifact.EvidenceClass,
    executable: bool = true,
    provider: artifact.Provider,
    model: []const u8,
    model_revision: ?[]const u8 = null,
    mlx_lm_version: ?[]const u8 = null,
    /// Declared local stack, for a server that reports no MLX-LM fingerprint.
    /// Set together or not at all - `artifact.zig` refuses half a pair.
    runtime_name: ?[]const u8 = null,
    runtime_version: ?[]const u8 = null,
    /// Absolute ignored-worktree path for metadata-only live response
    /// diagnostics. The diagnostic observer is disabled when this is null.
    diagnostics_path: ?[]const u8 = null,
    /// Borrowed observer for operator-facing, metadata-only live progress.
    /// Recording correctness never depends on this best-effort side channel.
    progress: ?ProgressObserver = null,
    workspace_allowlist: []const []const u8,
};

const PendingTurn = struct {
    index: u32,
    user_input: []const u8,
    transcript_start: usize,
    decision: artifact.ApprovalDecision,
    model_calls: u32 = 0,
    approvals: u32 = 0,
};

pub const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    options: Options,
    turns: std.ArrayList(artifact.TurnExpectation) = .empty,
    responses: std.ArrayList(artifact.ResponseFixture) = .empty,
    approval_expectations: std.ArrayList(artifact.ApprovalExpectation) = .empty,
    events: std.ArrayList(artifact.EventExpectation) = .empty,
    model_calls: std.ArrayList(artifact.ModelCheckpoint) = .empty,
    approval_checkpoints: std.ArrayList(artifact.ApprovalCheckpoint) = .empty,
    transcript_items: std.ArrayList(artifact.TranscriptItem) = .empty,
    apply_receipts: std.ArrayList(artifact.ApplyReceipt) = .empty,
    initial_workspace: std.ArrayList(artifact.WorkspaceFixture) = .empty,
    turn_workspaces: std.ArrayList(artifact.TurnWorkspaceCheckpoint) = .empty,
    expected_workspace: std.ArrayList(artifact.WorkspaceFixture) = .empty,
    changes: std.ArrayList(artifact.WorkspaceChange) = .empty,
    fixtures: std.ArrayList(recording_storage.FixtureBytes) = .empty,
    fixture_bytes: usize = 0,
    input_anchor: ?context_budget.InputAnchor = null,
    compaction_bridge_anchor: ?context_budget.InputAnchor = null,
    pending_turn: ?PendingTurn = null,
    captured_initial: bool = false,
    captured_expected: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator, options: Options) !Recorder {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const case_name = try owned.dupe(u8, options.case_name);
        const model = try owned.dupe(u8, options.model);
        const model_revision = if (options.model_revision) |value| try owned.dupe(u8, value) else null;
        const mlx_lm_version = if (options.mlx_lm_version) |value| try owned.dupe(u8, value) else null;
        const runtime_name = if (options.runtime_name) |value| try owned.dupe(u8, value) else null;
        const runtime_version = if (options.runtime_version) |value| try owned.dupe(u8, value) else null;
        if ((runtime_name == null) != (runtime_version == null)) return error.IncompleteRuntimeIdentity;
        const diagnostics_path = if (options.diagnostics_path) |value| path: {
            if (!std.fs.path.isAbsolute(value)) return error.DiagnosticsPathMustBeAbsolute;
            break :path try owned.dupe(u8, value);
        } else null;
        if (options.workspace_allowlist.len > artifact.Limits.files) return error.FlowLimitExceeded;
        const workspace_allowlist = try owned.alloc([]const u8, options.workspace_allowlist.len);
        for (options.workspace_allowlist, 0..) |path, index| {
            if (!artifact.isSafeRelativePath(path)) return error.UnsafePath;
            workspace_allowlist[index] = try owned.dupe(u8, path);
        }
        std.mem.sort([]const u8, workspace_allowlist, {}, lessThanPath);
        for (workspace_allowlist, 0..) |path, index| {
            if (index > 0 and std.mem.eql(u8, workspace_allowlist[index - 1], path)) {
                return error.DuplicateWorkspacePath;
            }
        }
        return .{
            .arena = arena,
            .options = .{
                .case_name = case_name,
                .evidence_class = options.evidence_class,
                .executable = options.executable,
                .provider = options.provider,
                .model = model,
                .model_revision = model_revision,
                .mlx_lm_version = mlx_lm_version,
                .runtime_name = runtime_name,
                .runtime_version = runtime_version,
                .diagnostics_path = diagnostics_path,
                .progress = options.progress,
                .workspace_allowlist = workspace_allowlist,
            },
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn captureSink(self: *Recorder) capture_sink.CaptureSink {
        return .{
            .context = self,
            .record_fn = recordModelExchange,
            .diagnostics_fn = if (self.options.diagnostics_path != null or self.options.progress != null)
                recordResponseDiagnostics
            else
                null,
        };
    }

    pub fn approvalFn(self: *Recorder) loop.ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = recordApproval } };
    }

    pub fn captureInitialWorkspace(self: *Recorder, root_abs: []const u8) !void {
        if (self.captured_initial or self.pending_turn != null or self.turns.items.len != 0) {
            return error.InvalidRecorderState;
        }
        try self.captureWorkspace(root_abs, .initial_workspace, "initial/", &self.initial_workspace);
        self.captured_initial = true;
    }

    pub fn beginTurn(
        self: *Recorder,
        user_input: []const u8,
        transcript_start: usize,
        decision: artifact.ApprovalDecision,
    ) !void {
        if (!self.captured_initial or self.captured_expected or self.pending_turn != null) {
            return error.InvalidRecorderState;
        }
        if (self.turns.items.len != 0 and self.turn_workspaces.items.len != self.turns.items.len) {
            return error.MissingTurnWorkspaceCheckpoint;
        }
        if (self.turns.items.len >= artifact.Limits.turns) return error.FlowLimitExceeded;
        self.pending_turn = .{
            .index = @intCast(self.turns.items.len),
            .user_input = try self.allocator().dupe(u8, user_input),
            .transcript_start = transcript_start,
            .decision = decision,
        };
    }

    pub fn finishTurn(
        self: *Recorder,
        result: loop.TurnResult,
        transcript: *const transcript_mod.Transcript,
    ) !void {
        const pending = self.pending_turn orelse return error.InvalidRecorderState;
        if (pending.transcript_start > transcript.len()) return error.InvalidRecorderState;

        const final_text = observation.lastModelText(transcript, pending.transcript_start) orelse "";
        try self.turns.append(self.allocator(), .{
            .index = pending.index,
            .user_input = pending.user_input,
            .outcome = observation.outcomeFromResult(result),
            .final_response_sha256 = artifact.Sha256Hex.fromBytes(final_text),
            .raw_first_draft_veto_pass = result.rawFirstDraftVetoPass(),
            .first_attempt_green = result.firstAttemptGreen(),
        });

        for (transcript.entries.items[pending.transcript_start..]) |*entry| {
            const event = try observation.eventForEntry(
                self.allocator(),
                @intCast(self.events.items.len),
                pending.index,
                entry,
            );
            try self.events.append(self.allocator(), event);
            try self.transcript_items.append(self.allocator(), .{
                .index = @intCast(self.transcript_items.items.len),
                .turn_index = pending.index,
                .kind = observation.transcriptKind(entry),
                .payload_sha256 = event.payload_sha256,
            });
            if (event.kind == .verified_patch or event.kind == .verified_change_set) {
                const receipt_digest = try observation.applyReceiptDigest(self.allocator(), entry);
                try self.apply_receipts.append(self.allocator(), .{
                    .index = @intCast(self.apply_receipts.items.len),
                    .turn_index = pending.index,
                    .payload_sha256 = receipt_digest,
                });
            }
        }
        try self.events.append(self.allocator(), .{
            .index = @intCast(self.events.items.len),
            .turn_index = pending.index,
            .kind = .turn_end,
            .payload_sha256 = artifact.Sha256Hex.fromBytes(@tagName(result.end_reason)),
        });
        self.pending_turn = null;
    }

    /// Binds the exact workspace after the most recently completed Turn.
    /// Callers record this checkpoint before beginning a later Turn.
    pub fn captureTurnWorkspace(self: *Recorder, root_abs: []const u8) !void {
        if (!self.captured_initial or self.captured_expected or self.pending_turn != null or
            self.turns.items.len == 0 or self.turn_workspaces.items.len + 1 != self.turns.items.len)
        {
            return error.InvalidRecorderState;
        }
        const turn_index: u32 = @intCast(self.turn_workspaces.items.len);
        var files: std.ArrayList(artifact.WorkspaceFixture) = .empty;
        const prefix = try std.fmt.allocPrint(self.allocator(), "turns/{d}/", .{turn_index});
        try self.captureWorkspace(root_abs, .turn_workspace, prefix, &files);
        try self.turn_workspaces.append(self.allocator(), .{
            .turn_index = turn_index,
            .files = files.items,
        });
    }

    pub fn captureExpectedWorkspace(self: *Recorder, root_abs: []const u8) !void {
        if (!self.captured_initial or self.captured_expected or self.pending_turn != null or
            self.turns.items.len == 0 or self.turn_workspaces.items.len + 1 != self.turns.items.len)
        {
            return error.InvalidRecorderState;
        }
        try self.captureWorkspace(root_abs, .expected_workspace, "expected/", &self.expected_workspace);
        try self.computeChanges();
        self.captured_expected = true;
    }

    pub fn promote(self: *Recorder, case_root_abs: []const u8) !artifact.Sha256Hex {
        if (!self.captured_initial or !self.captured_expected or self.pending_turn != null) {
            return error.InvalidRecorderState;
        }
        const zero = artifact.Sha256Hex{ .bytes = [_]u8{'0'} ** 64 };
        const manifest = artifact.FlowManifest{
            .schema_version = artifact.schema_version,
            .flow_version = zero,
            .case_name = self.options.case_name,
            .evidence_class = self.options.evidence_class,
            .executable = self.options.executable,
            .provider = self.options.provider,
            .model = self.options.model,
            .model_revision = self.options.model_revision,
            .mlx_lm_version = self.options.mlx_lm_version,
            .runtime_name = self.options.runtime_name,
            .runtime_version = self.options.runtime_version,
            .turns = self.turns.items,
            .model_responses = self.responses.items,
            .approvals = self.approval_expectations.items,
            .events = self.events.items,
            .allowed_workspace_changes = self.changes.items,
            .initial_workspace = self.initial_workspace.items,
            .turn_workspaces = self.turn_workspaces.items,
            .expected_workspace = self.expected_workspace.items,
            .trace = .{ .path = "trace.json", .sha256 = zero },
        };
        const trace = artifact.InteractionTrace{
            .schema_version = artifact.schema_version,
            .model_calls = self.model_calls.items,
            .approvals = self.approval_checkpoints.items,
            .transcript_items = self.transcript_items.items,
            .apply_receipts = self.apply_receipts.items,
        };
        return recording_storage.promote(self.arena.child_allocator, .{
            .case_root_abs = case_root_abs,
            .manifest = &manifest,
            .trace = &trace,
            .fixtures = self.fixtures.items,
        });
    }

    fn allocator(self: *Recorder) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn recordModelExchange(
        context: *anyopaque,
        global_call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const pending = if (self.pending_turn) |*turn| turn else return error.InvalidRecorderState;
        if (global_call_index != self.model_calls.items.len or
            snapshot.config.provider != self.options.provider or
            !std.mem.eql(u8, snapshot.config.model, self.options.model))
        {
            return error.InconsistentModelExchange;
        }
        // A Chat Completions provider always supplies the digest of its wire
        // body; a recording that lost it would replay as an absent-versus-
        // present mismatch on every call, so refuse it at capture time.
        if (recordsWireDigest(self.options.provider) and snapshot.wire_request_sha256 == null) {
            return error.InconsistentModelExchange;
        }
        const request_budget = snapshot.budget orelse return error.InconsistentModelExchange;
        if (self.model_calls.items.len >= artifact.Limits.model_checkpoints) return error.FlowLimitExceeded;
        if (raw_response.len > artifact.Limits.trace_or_response_bytes) return error.FlowLimitExceeded;
        if (self.options.provider == .local and self.options.mlx_lm_version == null) {
            self.options.mlx_lm_version = try mlxLmVersion(self.allocator(), raw_response);
        }

        const response_bytes = try cassette_record.serializeCassette(self.allocator(), raw_response, .{
            .provider = self.options.provider,
            .scenario = self.options.case_name,
            .stream = snapshot.config.stream,
            .model = self.options.model,
            .request_sha256 = if (snapshot.wire_request_sha256) |digest| digest.slice() else null,
        });
        var decode_arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer decode_arena.deinit();
        const decoded = try cassette_client.replay(decode_arena.allocator(), .{
            .header = .{
                .provider = self.options.provider,
                .stream = snapshot.config.stream,
                .request_sha256 = if (snapshot.wire_request_sha256) |digest|
                    digest.slice()
                else
                    null,
            },
            .body = raw_response,
        });
        const reported_input_tokens = try context_budget.normalizeLogicalInput(
            self.options.provider,
            decoded.usage,
        );
        const epoch: context_budget.UsageEpoch = .{
            .provider = self.options.provider,
            .model = self.options.model,
            .checkpoint_generation = snapshot.projection_first_kept_entry_id orelse 0,
        };
        // Production tracks stable normal-request usage only. A null anchor
        // makes both calls return the fresh-estimate and raw-report defaults,
        // so summarization needs no separate branch here.
        const is_normal = snapshot.config.purpose == .normal;
        if (is_normal) {
            if (self.input_anchor) |anchor| {
                if (!epoch.eql(anchor.usage.epoch)) {
                    self.compaction_bridge_anchor = anchor;
                    self.input_anchor = null;
                }
            }
        }
        const anchor = if (is_normal) self.input_anchor else null;
        const bridge = if (is_normal) self.compaction_bridge_anchor else null;
        const selected = try context_budget.selectInputEstimate(.{
            .epoch = epoch,
            .current_budget = request_budget,
            .anchor = anchor,
            .compaction_bridge = bridge,
        });
        const observed = try context_budget.observeLogicalInput(.{
            .epoch = epoch,
            .current_budget = request_budget,
            .anchor = anchor,
            .compaction_bridge = bridge,
            .reported_tokens = reported_input_tokens,
        });
        if (is_normal and reported_input_tokens > 0) {
            self.input_anchor = .{
                .usage = .{
                    .epoch = epoch,
                    .logical_input_tokens = observed.logical_input_tokens,
                },
                .budget = request_budget,
            };
            self.compaction_bridge_anchor = null;
        }
        try self.reserveFixtureBytes(response_bytes.len, artifact.Limits.trace_or_response_bytes);
        const response_path = try std.fmt.allocPrint(
            self.allocator(),
            "responses/{d}.jsonl",
            .{global_call_index},
        );
        const index: u32 = @intCast(global_call_index);
        try self.responses.append(self.allocator(), .{
            .index = index,
            .turn_index = pending.index,
            .call_index = pending.model_calls,
            .path = response_path,
            .sha256 = artifact.Sha256Hex.fromBytes(response_bytes),
        });
        try self.model_calls.append(self.allocator(), .{
            .index = index,
            .turn_index = pending.index,
            .call_index = pending.model_calls,
            .transcript_prefix_count = std.math.cast(u32, snapshot.items.len) orelse return error.FlowLimitExceeded,
            .transcript_sha256 = artifactDigest(snapshot.transcript_sha256),
            .request_context_sha256 = artifactDigest(snapshot.request_context_sha256),
            .transient_user_text_sha256 = if (snapshot.transient_user_text_sha256) |digest|
                artifactDigest(digest)
            else
                null,
            .wire_request_sha256 = if (snapshot.wire_request_sha256) |digest|
                artifactDigest(digest)
            else
                null,
            .request_budget = request_budget,
            .normalized_input_tokens = reported_input_tokens,
            .projection_first_kept_entry_id = snapshot.projection_first_kept_entry_id,
        });
        try self.fixtures.append(self.allocator(), .{
            .role = .response,
            .path = response_path,
            .bytes = response_bytes,
        });
        const turn_call_index = pending.model_calls;
        pending.model_calls += 1;
        if (self.options.progress) |progress| progress.emit(.{
            .model_call_completed = .{
                .global_call_index = global_call_index,
                .turn_index = pending.index,
                .turn_call_index = turn_call_index,
                .purpose = snapshot.config.purpose,
                .estimated_input_tokens = selected.tokens,
                .estimate_source = selected.source,
                .reported_input_tokens = observed.reported_tokens,
                .logical_input_tokens = observed.logical_input_tokens,
                .input_observation_source = observed.source,
                .output_tokens = decoded.usage.output_tokens,
                .output_limit_tokens = snapshot.config.max_output_tokens,
                .wire_bytes = request_budget.bytes.wire,
            },
        });
    }

    fn recordResponseDiagnostics(
        context: *anyopaque,
        attempt_index: usize,
        diagnostic_context: capture_sink.ResponseDiagnosticContext,
        diagnostics: capture_sink.ResponseDiagnostics,
    ) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        if (diagnostics.failure) |failure| {
            if (self.options.progress) |progress| progress.emit(.{
                .model_call_failed = .{
                    .attempt_index = attempt_index,
                    .provider = diagnostic_context.provider,
                    .latency_ms = diagnostics.latency_ms,
                    .http_status = diagnostics.http_status,
                    .failure = failure,
                },
            });
        }
        const path = self.options.diagnostics_path orelse return;
        const line = try serializeResponseDiagnostics(
            self.allocator(),
            self.options.case_name,
            attempt_index,
            diagnostic_context,
            diagnostics,
        );
        defer self.allocator().free(line);
        appendDiagnosticLine(self.allocator(), path, line) catch |err| {
            std.debug.print(
                "[response-diagnostics] metadata append failed: {s}\n",
                .{@errorName(err)},
            );
            return err;
        };
    }

    fn recordApproval(context: *anyopaque, preview: loop.ChangeSetApprovalPreview) anyerror!bool {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const pending = if (self.pending_turn) |*turn| turn else return error.InvalidRecorderState;
        if (self.approval_checkpoints.items.len >= artifact.Limits.approval_checkpoints) {
            return error.FlowLimitExceeded;
        }
        const index: u32 = @intCast(self.approval_checkpoints.items.len);
        try self.approval_expectations.append(self.allocator(), .{
            .index = index,
            .turn_index = pending.index,
            .checkpoint_index = pending.approvals,
            .decision = pending.decision,
        });
        try self.approval_checkpoints.append(self.allocator(), .{
            .index = index,
            .turn_index = pending.index,
            .checkpoint_index = pending.approvals,
            .preview_sha256 = try observation.approvalPreviewDigest(self.allocator(), preview),
        });
        pending.approvals += 1;
        return pending.decision == .approve;
    }

    fn captureWorkspace(
        self: *Recorder,
        root_abs: []const u8,
        role: artifact.FixtureRole,
        fixture_prefix: []const u8,
        inventory: *std.ArrayList(artifact.WorkspaceFixture),
    ) !void {
        if (!std.fs.path.isAbsolute(root_abs)) return error.UnsafePath;
        var io_backend = std.Io.Threaded.init(self.allocator(), .{ .environ = .empty });
        defer io_backend.deinit();
        const io = io_backend.io();
        var root = try std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true, .follow_symlinks = false });
        defer root.close(io);
        var walker = try root.walk(self.allocator());
        defer walker.deinit();

        var paths: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (entry.kind != .file or !artifact.isSafeRelativePath(entry.path)) return error.UnsafePath;
            // `.zttp/` is agent-owned scratch, not case source: `pi_goal_check`
            // persists witnesses to `.zttp/witnesses/<hash>/`. The directory
            // name carries a per-run hash, so capturing it would make the
            // expected workspace differ from itself on the next recording.
            if (artifact.isAgentScratch(entry.path)) continue;
            if (!self.workspacePathAllowed(entry.path)) {
                // Name the path. The refusal is usually a model that wrote a
                // file the case never declared, and the operator cannot decide
                // between declaring it and treating it as a failure without
                // knowing which file it was.
                std.debug.print(
                    "[recorder] undeclared workspace path '{s}' in {s}; declared:",
                    .{ entry.path, @tagName(role) },
                );
                for (self.options.workspace_allowlist) |allowed| {
                    std.debug.print(" '{s}'", .{allowed});
                }
                std.debug.print("\n", .{});
                return error.UndeclaredWorkspacePath;
            }
            if (paths.items.len >= artifact.Limits.files) return error.FlowLimitExceeded;
            try paths.append(self.allocator(), try self.allocator().dupe(u8, entry.path));
        }
        std.mem.sort([]const u8, paths.items, {}, lessThanPath);
        for (paths.items) |path| {
            const absolute = try std.fs.path.join(self.allocator(), &.{ root_abs, path });
            const bytes = try zts.file_io.readFile(self.allocator(), absolute, artifact.Limits.workspace_file_bytes);
            try self.reserveFixtureBytes(bytes.len, artifact.Limits.workspace_file_bytes);
            const fixture_path = try std.fmt.allocPrint(self.allocator(), "{s}{s}", .{ fixture_prefix, path });
            try inventory.append(self.allocator(), .{
                .path = path,
                .sha256 = artifact.Sha256Hex.fromBytes(bytes),
            });
            try self.fixtures.append(self.allocator(), .{
                .role = role,
                .path = fixture_path,
                .bytes = bytes,
            });
        }
    }

    fn workspacePathAllowed(self: *const Recorder, path: []const u8) bool {
        for (self.options.workspace_allowlist) |allowed| {
            if (std.mem.eql(u8, allowed, path)) return true;
        }
        return false;
    }

    fn computeChanges(self: *Recorder) !void {
        var initial_index: usize = 0;
        var expected_index: usize = 0;
        while (initial_index < self.initial_workspace.items.len or expected_index < self.expected_workspace.items.len) {
            if (initial_index == self.initial_workspace.items.len) {
                const expected = self.expected_workspace.items[expected_index];
                try self.changes.append(self.allocator(), .{ .path = expected.path, .kind = .created });
                expected_index += 1;
                continue;
            }
            if (expected_index == self.expected_workspace.items.len) {
                const initial = self.initial_workspace.items[initial_index];
                try self.changes.append(self.allocator(), .{ .path = initial.path, .kind = .deleted });
                initial_index += 1;
                continue;
            }
            const initial = self.initial_workspace.items[initial_index];
            const expected = self.expected_workspace.items[expected_index];
            switch (std.mem.order(u8, initial.path, expected.path)) {
                .lt => {
                    try self.changes.append(self.allocator(), .{ .path = initial.path, .kind = .deleted });
                    initial_index += 1;
                },
                .gt => {
                    try self.changes.append(self.allocator(), .{ .path = expected.path, .kind = .created });
                    expected_index += 1;
                },
                .eq => {
                    if (!initial.sha256.eql(expected.sha256)) {
                        try self.changes.append(self.allocator(), .{ .path = initial.path, .kind = .changed });
                    }
                    initial_index += 1;
                    expected_index += 1;
                },
            }
        }
    }

    fn reserveFixtureBytes(self: *Recorder, bytes: usize, per_file_limit: usize) !void {
        if (bytes > per_file_limit or bytes > artifact.Limits.case_bytes - self.fixture_bytes) {
            return error.FlowLimitExceeded;
        }
        self.fixture_bytes += bytes;
    }
};

fn serializeResponseDiagnostics(
    allocator: std.mem.Allocator,
    case_name: []const u8,
    attempt_index: usize,
    diagnostic_context: capture_sink.ResponseDiagnosticContext,
    diagnostics: capture_sink.ResponseDiagnostics,
) ![]u8 {
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    try std.json.Stringify.value(.{
        .v = @as(u32, 1),
        .case_name = case_name,
        .provider = diagnostic_context.provider,
        .model = diagnostic_context.model,
        .attempt_index = attempt_index,
        .latency_ms = diagnostics.latency_ms,
        .http_status = diagnostics.http_status,
        .finish_reason = diagnostics.finish_reason,
        .completion_tokens = diagnostics.completion_tokens,
        .field_presence = diagnostics.field_presence,
        .parser_warnings = diagnostics.parser_warnings,
        .error_name = if (diagnostics.failure) |failure| @errorName(failure) else null,
    }, .{}, writer);
    try writer.writeByte('\n');
    return buffer.toOwnedSlice();
}

fn appendDiagnosticLine(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
) !void {
    return appendDiagnosticLineWithWriter(allocator, path, line, .{});
}

const DiagnosticWriter = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, std.c.fd_t, []const u8) isize = writeDiagnosticBytes,
};

fn appendDiagnosticLineWithWriter(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    diagnostic_writer: DiagnosticWriter,
) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidDiagnosticsPath;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, parent);
    const fd = try zts.file_io.openAppend(allocator, path);
    defer std.Io.Threaded.closeFd(fd);
    try lockDiagnosticFile(fd);
    defer _ = std.c.flock(fd, std.posix.LOCK.UN);
    const clean_eof = (try zts.file_io.fstatFd(fd)).size;
    writeDiagnosticLine(fd, line, diagnostic_writer) catch |write_err| {
        rollbackDiagnosticFile(fd, clean_eof) catch return error.DiagnosticsRollbackFailed;
        return write_err;
    };
}

fn lockDiagnosticFile(fd: std.c.fd_t) !void {
    while (true) {
        const result = std.c.flock(fd, std.posix.LOCK.EX);
        if (result == 0) return;
        if (std.posix.errno(result) != .INTR) return error.DiagnosticsLockFailed;
    }
}

fn rollbackDiagnosticFile(fd: std.c.fd_t, clean_eof: u64) !void {
    while (true) {
        const result = std.c.ftruncate(fd, @intCast(clean_eof));
        if (result == 0) return;
        if (std.posix.errno(result) != .INTR) return error.DiagnosticsRollbackFailed;
    }
}

fn writeDiagnosticLine(
    fd: std.c.fd_t,
    line: []const u8,
    diagnostic_writer: DiagnosticWriter,
) !void {
    var written: usize = 0;
    while (written < line.len) {
        const count = diagnostic_writer.write_fn(
            diagnostic_writer.context,
            fd,
            line[written..],
        );
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) continue;
            return error.DiagnosticsWriteFailed;
        }
        if (count == 0) return error.DiagnosticsWriteFailed;
        written += @intCast(count);
    }
}

fn writeDiagnosticBytes(_: ?*anyopaque, fd: std.c.fd_t, bytes: []const u8) isize {
    return std.c.write(fd, bytes.ptr, bytes.len);
}

fn artifactDigest(digest: model_request.Sha256Hex) artifact.Sha256Hex {
    return .{ .bytes = digest.bytes };
}

/// Every provider hashes the exact serialized request body before transport.
/// Replay rebuilds and hashes the same bytes before releasing a response.
fn recordsWireDigest(provider: artifact.Provider) bool {
    _ = provider;
    return true;
}

fn mlxLmVersion(allocator: std.mem.Allocator, raw_response: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw_response, .{
        .duplicate_field_behavior = .@"error",
    }) catch return null;
    if (parsed != .object) return null;
    const fingerprint = parsed.object.get("system_fingerprint") orelse return null;
    if (fingerprint != .string) return null;
    const end = std.mem.indexOfScalar(u8, fingerprint.string, '-') orelse fingerprint.string.len;
    const version = fingerprint.string[0..end];
    if (version.len == 0) return null;
    for (version) |byte| if (!std.ascii.isDigit(byte) and byte != '.') return null;
    return try allocator.dupe(u8, version);
}

const ShortDiagnosticWrite = struct {
    calls: usize = 0,

    fn write(context: ?*anyopaque, fd: std.c.fd_t, bytes: []const u8) isize {
        const self: *ShortDiagnosticWrite = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls != 1) return 0;
        const count = @min(bytes.len, 7);
        return std.c.write(fd, bytes.ptr, count);
    }
};

fn diagnosticTestPath(
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    name: []const u8,
) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const cwd = try std.Io.Dir.realPathFileAlloc(
        std.Io.Dir.cwd(),
        io_backend.io(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        name,
    });
}

test "diagnostic append rolls back a partial line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try diagnosticTestPath(std.testing.allocator, tmp, "rollback.jsonl");
    defer std.testing.allocator.free(path);
    const first = "{\"record\":1}\n";
    const failed = "{\"record\":2}\n";
    const last = "{\"record\":3}\n";
    try appendDiagnosticLine(std.testing.allocator, path, first);
    var short_write: ShortDiagnosticWrite = .{};
    try std.testing.expectError(
        error.DiagnosticsWriteFailed,
        appendDiagnosticLineWithWriter(std.testing.allocator, path, failed, .{
            .context = &short_write,
            .write_fn = ShortDiagnosticWrite.write,
        }),
    );
    try appendDiagnosticLine(std.testing.allocator, path, last);

    const bytes = try zts.file_io.readFile(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(first ++ last, bytes);
}

const ConcurrentDiagnosticAppend = struct {
    path: []const u8,
    line: []const u8,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentDiagnosticAppend) void {
        for (0..20) |_| {
            appendDiagnosticLine(std.heap.page_allocator, self.path, self.line) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

test "diagnostic append keeps concurrent records separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try diagnosticTestPath(std.testing.allocator, tmp, "concurrent.jsonl");
    defer std.testing.allocator.free(path);
    var left: ConcurrentDiagnosticAppend = .{ .path = path, .line = "{\"writer\":\"a\"}\n" };
    var right: ConcurrentDiagnosticAppend = .{ .path = path, .line = "{\"writer\":\"b\"}\n" };
    const left_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticAppend.run, .{&left});
    const right_thread = try std.Thread.spawn(.{}, ConcurrentDiagnosticAppend.run, .{&right});
    left_thread.join();
    right_thread.join();
    try std.testing.expect(left.failure == null);
    try std.testing.expect(right.failure == null);

    const bytes = try zts.file_io.readFile(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(
            std.mem.eql(u8, line, "{\"writer\":\"a\"}") or
                std.mem.eql(u8, line, "{\"writer\":\"b\"}"),
        );
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 40), count);
}

test "local response fingerprint exposes the MLX-LM version" {
    const version = (try mlxLmVersion(
        std.testing.allocator,
        "{\"system_fingerprint\":\"0.31.3-0.32.0-macOS\"}",
    )).?;
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("0.31.3", version);
    try std.testing.expect((try mlxLmVersion(
        std.testing.allocator,
        "{\"system_fingerprint\":\"unknown-build\"}",
    )) == null);
}

fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
