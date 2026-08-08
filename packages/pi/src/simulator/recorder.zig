//! In-memory collection of one complete interaction flow.
//!
//! Model requests and raw responses arrive synchronously through `CaptureSink`.
//! Turns, approval previews, transcript events, and exact workspace snapshots
//! are added at the production loop boundary. Promotion is delegated to the
//! crash-safe content-addressed store only after collection is complete.

const std = @import("std");
const zts = @import("zts");
const artifact = @import("artifact.zig");
const observation = @import("observation.zig");
const recording_storage = @import("recording_storage.zig");
const capture_sink = @import("../providers/capture_sink.zig");
const cassette_client = @import("../providers/cassette_client.zig");
const cassette_record = @import("../providers/cassette_record.zig");
const model_request = @import("../providers/model_request.zig");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");

pub const Options = struct {
    case_name: []const u8,
    evidence_class: artifact.EvidenceClass,
    executable: bool = true,
    provider: artifact.Provider,
    model: []const u8,
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
    pending_turn: ?PendingTurn = null,
    captured_initial: bool = false,
    captured_expected: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator, options: Options) !Recorder {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const case_name = try owned.dupe(u8, options.case_name);
        const model = try owned.dupe(u8, options.model);
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
                .workspace_allowlist = workspace_allowlist,
            },
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn captureSink(self: *Recorder) capture_sink.CaptureSink {
        return .{ .context = self, .record_fn = recordModelExchange };
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
            if (event.kind == .verified_patch) {
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
            artifactProvider(snapshot.config.provider) != self.options.provider or
            !std.mem.eql(u8, snapshot.config.model, self.options.model))
        {
            return error.InconsistentModelExchange;
        }
        if (self.model_calls.items.len >= artifact.Limits.model_checkpoints) return error.FlowLimitExceeded;
        if (raw_response.len > artifact.Limits.trace_or_response_bytes) return error.FlowLimitExceeded;

        const response_bytes = try cassette_record.serializeCassette(self.allocator(), raw_response, .{
            .provider = cassetteProvider(self.options.provider),
            .scenario = self.options.case_name,
            .stream = snapshot.config.stream,
            .model = self.options.model,
        });
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
        });
        try self.fixtures.append(self.allocator(), .{
            .role = .response,
            .path = response_path,
            .bytes = response_bytes,
        });
        pending.model_calls += 1;
    }

    fn recordApproval(context: *anyopaque, preview: loop.ApprovalPreview) anyerror!bool {
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
            if (!self.workspacePathAllowed(entry.path)) return error.UndeclaredWorkspacePath;
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

fn artifactProvider(provider: model_request.Provider) artifact.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn cassetteProvider(provider: artifact.Provider) cassette_client.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn artifactDigest(digest: model_request.Sha256Hex) artifact.Sha256Hex {
    return .{ .bytes = digest.bytes };
}

fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
