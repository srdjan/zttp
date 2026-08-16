//! Full-flow cassette execution through the production Pi loop.

const std = @import("std");
const zts = @import("zts");
const artifact = @import("artifact.zig");
const loop = @import("../loop.zig");
const agent = @import("../agent.zig");
const model_client = @import("model_client.zig");
const model_request = @import("../providers/model_request.zig");
const observation = @import("observation.zig");
const registry_mod = @import("../registry/registry.zig");
const transcript_mod = @import("../transcript.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const RunResult = struct {
    flow_version: artifact.Sha256Hex,
    evidence_class: artifact.EvidenceClass,
    turns: usize,
    model_calls: usize,
    expected_model_calls: usize,
    approvals: usize,
    expected_approvals: usize,
    complete_consumption: bool,
};

pub const ApprovalValidator = struct {
    allocator: std.mem.Allocator,
    expectations: []const artifact.ApprovalExpectation,
    checkpoints: []const artifact.ApprovalCheckpoint,
    cursor: usize = 0,
    turn_index: u32 = 0,
    last_mismatch: ?artifact.ReplayMismatch = null,

    pub fn init(
        allocator: std.mem.Allocator,
        expectations: []const artifact.ApprovalExpectation,
        checkpoints: []const artifact.ApprovalCheckpoint,
    ) ApprovalValidator {
        return .{
            .allocator = allocator,
            .expectations = expectations,
            .checkpoints = checkpoints,
        };
    }

    pub fn beginTurn(self: *ApprovalValidator, turn_index: u32) void {
        self.turn_index = turn_index;
    }

    pub fn asApprovalFn(self: *ApprovalValidator) loop.ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = approvalFn } };
    }

    pub fn consumedCount(self: *const ApprovalValidator) usize {
        return self.cursor;
    }

    pub fn lastMismatch(self: *const ApprovalValidator) ?artifact.ReplayMismatch {
        return self.last_mismatch;
    }

    pub fn finish(self: *ApprovalValidator) !void {
        if (self.cursor != self.expectations.len or self.cursor != self.checkpoints.len) {
            return self.fail(.{ .unconsumed_checkpoint = .{
                .component = .trace,
                .turn_index = self.turn_index,
                .checkpoint_index = @intCast(self.cursor),
            } });
        }
    }

    fn approvalFn(context: *anyopaque, preview: loop.ChangeSetApprovalPreview) anyerror!bool {
        const self: *ApprovalValidator = @ptrCast(@alignCast(context));
        if (self.cursor >= self.expectations.len or self.cursor >= self.checkpoints.len) {
            return self.fail(.{ .approval_mismatch = .{
                .component = .trace,
                .turn_index = self.turn_index,
                .checkpoint_index = @intCast(self.cursor),
            } });
        }
        const expectation = self.expectations[self.cursor];
        const checkpoint = self.checkpoints[self.cursor];
        const observed = try observation.approvalPreviewDigest(self.allocator, preview);
        if (expectation.index != self.cursor or checkpoint.index != self.cursor or
            expectation.turn_index != self.turn_index or checkpoint.turn_index != self.turn_index or
            expectation.checkpoint_index != checkpoint.checkpoint_index or
            !observed.eql(checkpoint.preview_sha256))
        {
            return self.fail(.{ .approval_mismatch = .{
                .component = .trace,
                .turn_index = self.turn_index,
                .checkpoint_index = checkpoint.checkpoint_index,
            } });
        }
        self.cursor += 1;
        return expectation.decision == .approve;
    }

    fn fail(self: *ApprovalValidator, mismatch: artifact.ReplayMismatch) error{ReplayMismatch} {
        self.last_mismatch = mismatch;
        return error.ReplayMismatch;
    }
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    flow_case: *const artifact.FlowCase,
    registry: *const registry_mod.Registry,
    request_config: model_request.Config,
    last_mismatch: ?artifact.ReplayMismatch = null,
    event_cursor: usize = 0,
    transcript_cursor: usize = 0,
    receipt_cursor: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        flow_case: *const artifact.FlowCase,
        registry: *const registry_mod.Registry,
        request_config: model_request.Config,
    ) Runner {
        return .{
            .allocator = allocator,
            .flow_case = flow_case,
            .registry = registry,
            .request_config = request_config,
        };
    }

    pub fn lastMismatch(self: *const Runner) ?artifact.ReplayMismatch {
        return self.last_mismatch;
    }

    pub fn run(self: *Runner) !RunResult {
        self.last_mismatch = null;
        self.event_cursor = 0;
        self.transcript_cursor = 0;
        self.receipt_cursor = 0;
        if (!self.flow_case.descriptor.executable or !self.flow_case.manifest.executable) {
            return self.fail(.{ .non_executable_case = .{ .component = .manifest } });
        }

        var io_backend = std.Io.Threaded.init(self.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        var workspace = try Workspace.create(self.allocator, io_backend.io());
        const result = self.runInWorkspace(&workspace);
        try workspace.deinit();
        return result;
    }

    fn runInWorkspace(self: *Runner, workspace: *Workspace) !RunResult {
        try self.restoreInitialWorkspace(workspace);
        try workspace.enter();

        var replay_client = model_client.Client.init(
            model_client.Script.fromFlowCase(self.flow_case),
            self.request_config,
        );
        var approvals = ApprovalValidator.init(
            self.allocator,
            self.flow_case.manifest.approvals,
            self.flow_case.trace.approvals,
        );
        const resolved_model = try @import("../providers/models.zig").resolveForProvider(
            self.request_config.provider,
            self.request_config.model,
        );
        var session = agent.AgentSession.initControlled(
            self.allocator,
            resolved_model,
            self.request_config,
        );
        defer session.deinit(self.allocator);
        var controller: agent.RequestController = .{
            .allocator = self.allocator,
            .session = &session,
            .raw_client = replay_client.asModelClient(),
            .summarizer = replay_client.asSummarizer(),
        };
        const transcript = &session.transcript;

        for (self.flow_case.manifest.turns, 0..) |expected, turn_position| {
            approvals.beginTurn(expected.index);
            const transcript_start = transcript.len();
            const result = loop.runTurnWith(
                self.allocator,
                controller.asModelClient(),
                self.registry,
                transcript,
                expected.user_input,
                .{
                    .workspace_root = ".",
                    .max_attempts = loop.interactive_max_attempts,
                    .approval_fn = approvals.asApprovalFn(),
                    .replay_mode = false,
                    .turn_timeout_ms = 0,
                },
            ) catch |err| {
                if (err == error.ReplayMismatch) {
                    self.last_mismatch = replay_client.lastMismatch() orelse approvals.lastMismatch();
                    // Printed rather than only stored. A `response_underflow`
                    // says the replay asked for a model turn the recording
                    // does not hold, and the two numbers that identify it -
                    // which turn diverged, and how many checkpoints exist -
                    // are here and nowhere the caller can reach.
                    if (self.last_mismatch) |mismatch| {
                        std.debug.print(
                            "[replay] {s} at turn {d}/{d}, model checkpoints recorded: {d}\n",
                            .{
                                @tagName(mismatch),
                                turn_position,
                                self.flow_case.manifest.turns.len,
                                self.flow_case.manifest.model_responses.len,
                            },
                        );
                    }
                }
                std.debug.print("[replay] turn {d} failed: {s}\n", .{ turn_position, @errorName(err) });
                return err;
            };
            try self.validateTurn(expected, result, transcript, transcript_start);
            if (turn_position + 1 < self.flow_case.manifest.turns.len) {
                const checkpoint = self.flow_case.manifest.turn_workspaces[turn_position];
                const prefix = try std.fmt.allocPrint(self.allocator, "turns/{d}/", .{checkpoint.turn_index});
                defer self.allocator.free(prefix);
                try self.validateWorkspaceSnapshot(
                    workspace.abs_path,
                    checkpoint.files,
                    .turn_workspace,
                    prefix,
                );
            }
        }

        replay_client.finish() catch |err| {
            if (err == error.ReplayMismatch) self.last_mismatch = replay_client.lastMismatch();
            return err;
        };
        approvals.finish() catch |err| {
            if (err == error.ReplayMismatch) self.last_mismatch = approvals.lastMismatch();
            return err;
        };
        if (self.event_cursor != self.flow_case.manifest.events.len) {
            return self.fail(.{ .unconsumed_checkpoint = .{ .component = .trace } });
        }
        if (self.transcript_cursor != self.flow_case.trace.transcript_items.len or
            self.receipt_cursor != self.flow_case.trace.apply_receipts.len)
        {
            return self.fail(.{ .unconsumed_checkpoint = .{ .component = .trace } });
        }
        try self.validateWorkspaceSnapshot(
            workspace.abs_path,
            self.flow_case.manifest.expected_workspace,
            .expected_workspace,
            "expected/",
        );
        return .{
            .flow_version = self.flow_case.flow_version,
            .evidence_class = self.flow_case.manifest.evidence_class,
            .turns = self.flow_case.manifest.turns.len,
            .model_calls = replay_client.consumedCount(),
            .expected_model_calls = self.flow_case.trace.model_calls.len,
            .approvals = approvals.consumedCount(),
            .expected_approvals = self.flow_case.trace.approvals.len,
            .complete_consumption = true,
        };
    }

    fn restoreInitialWorkspace(self: *Runner, workspace: *const Workspace) !void {
        for (self.flow_case.fixtures) |fixture| {
            if (fixture.role != .initial_workspace) continue;
            const prefix = "initial/";
            if (!std.mem.startsWith(u8, fixture.path, prefix)) {
                return self.fail(.{ .initial_state_mismatch = .{ .component = .initial_workspace } });
            }
            try workspace.restoreFile(fixture.path[prefix.len..], fixture.bytes);
        }
    }

    fn validateTurn(
        self: *Runner,
        expected: artifact.TurnExpectation,
        result: loop.TurnResult,
        transcript: *const transcript_mod.Transcript,
        transcript_start: usize,
    ) !void {
        if (observation.outcomeFromResult(result) != expected.outcome) {
            return self.fail(.{ .turn_outcome_mismatch = .{
                .component = .trace,
                .turn_index = expected.index,
            } });
        }
        const draft_expectation = expected.draftExpectation() catch unreachable;
        if (!draft_expectation.matches(result.draft_quality)) {
            return self.fail(.{ .turn_outcome_mismatch = .{
                .component = .trace,
                .turn_index = expected.index,
            } });
        }
        const final_text = observation.lastModelText(transcript, transcript_start) orelse "";
        if (!artifact.Sha256Hex.fromBytes(final_text).eql(expected.final_response_sha256)) {
            return self.fail(.{ .turn_outcome_mismatch = .{
                .component = .trace,
                .turn_index = expected.index,
            } });
        }
        for (transcript.entries.items[transcript_start..]) |*entry| {
            const event = try observation.eventForEntry(
                self.allocator,
                @intCast(self.event_cursor),
                expected.index,
                entry,
            );
            try self.expectEvent(event);
            try self.expectTranscriptItem(expected.index, entry, event.payload_sha256);
            if (event.kind == .verified_patch or event.kind == .verified_change_set) {
                const receipt_digest = try observation.applyReceiptDigest(self.allocator, entry);
                try self.expectApplyReceipt(expected.index, receipt_digest);
            }
        }
        try self.expectEvent(.{
            .index = @intCast(self.event_cursor),
            .turn_index = expected.index,
            .kind = .turn_end,
            .payload_sha256 = artifact.Sha256Hex.fromBytes(@tagName(result.end_reason)),
        });
    }

    fn expectEvent(self: *Runner, observed: artifact.EventExpectation) !void {
        if (self.event_cursor >= self.flow_case.manifest.events.len) {
            return self.fail(.{ .turn_outcome_mismatch = .{
                .component = .trace,
                .turn_index = observed.turn_index,
                .first_divergent_event = @intCast(self.event_cursor),
            } });
        }
        const expected = self.flow_case.manifest.events[self.event_cursor];
        if (expected.index != self.event_cursor or expected.turn_index != observed.turn_index or
            expected.kind != observed.kind or !expected.payload_sha256.eql(observed.payload_sha256))
        {
            return self.fail(.{ .turn_outcome_mismatch = .{
                .component = .trace,
                .turn_index = observed.turn_index,
                .first_divergent_event = @intCast(self.event_cursor),
            } });
        }
        self.event_cursor += 1;
    }

    fn expectTranscriptItem(
        self: *Runner,
        turn_index: u32,
        entry: *const transcript_mod.OwnedEntry,
        payload_sha256: artifact.Sha256Hex,
    ) !void {
        if (self.transcript_cursor >= self.flow_case.trace.transcript_items.len) {
            return self.traceMismatch(turn_index);
        }
        const expected = self.flow_case.trace.transcript_items[self.transcript_cursor];
        if (expected.index != self.transcript_cursor or expected.turn_index != turn_index or
            expected.kind != observation.transcriptKind(entry) or
            !expected.payload_sha256.eql(payload_sha256))
        {
            return self.traceMismatch(turn_index);
        }
        self.transcript_cursor += 1;
    }

    fn expectApplyReceipt(
        self: *Runner,
        turn_index: u32,
        payload_sha256: artifact.Sha256Hex,
    ) !void {
        if (self.receipt_cursor >= self.flow_case.trace.apply_receipts.len) {
            return self.traceMismatch(turn_index);
        }
        const expected = self.flow_case.trace.apply_receipts[self.receipt_cursor];
        if (expected.index != self.receipt_cursor or expected.turn_index != turn_index or
            !expected.payload_sha256.eql(payload_sha256))
        {
            return self.traceMismatch(turn_index);
        }
        self.receipt_cursor += 1;
    }

    fn traceMismatch(self: *Runner, turn_index: u32) error{ReplayMismatch} {
        return self.fail(.{ .turn_outcome_mismatch = .{
            .component = .trace,
            .turn_index = turn_index,
            .first_divergent_event = @intCast(self.transcript_cursor),
        } });
    }

    fn validateWorkspaceSnapshot(
        self: *Runner,
        workspace_abs: []const u8,
        expected_files: []const artifact.WorkspaceFixture,
        component: artifact.Component,
        fixture_prefix: []const u8,
    ) !void {
        var io_backend = std.Io.Threaded.init(self.allocator, .{ .environ = .empty });
        defer io_backend.deinit();
        const io = io_backend.io();
        var root = try std.Io.Dir.openDirAbsolute(io, workspace_abs, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var actual_files: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            // The recorder never captured agent scratch, and the replayed tools
            // write it again, so counting it here would fail every case whose
            // agent reached a witness-writing tool.
            if (artifact.isAgentScratch(entry.path)) continue;
            if (entry.kind != .file or
                artifact.findWorkspace(expected_files, entry.path) == null)
            {
                return self.fail(.{ .workspace_mismatch = .{ .component = component } });
            }
            actual_files += 1;
        }
        if (actual_files != expected_files.len) {
            return self.fail(.{ .workspace_mismatch = .{ .component = component } });
        }

        for (expected_files) |expected| {
            const expected_bytes = self.workspaceFixtureBytes(component, fixture_prefix, expected.path) orelse
                return self.fail(.{ .workspace_mismatch = .{ .component = component } });
            const path = try std.fs.path.join(self.allocator, &.{ workspace_abs, expected.path });
            defer self.allocator.free(path);
            const actual = zts.file_io.readFile(
                self.allocator,
                path,
                artifact.Limits.workspace_file_bytes,
            ) catch return self.fail(.{ .workspace_mismatch = .{ .component = component } });
            defer self.allocator.free(actual);
            if (!std.mem.eql(u8, actual, expected_bytes)) {
                return self.fail(.{ .workspace_mismatch = .{ .component = component } });
            }
        }
    }

    fn workspaceFixtureBytes(
        self: *const Runner,
        role: artifact.Component,
        prefix: []const u8,
        path: []const u8,
    ) ?[]const u8 {
        const fixture_role: artifact.FixtureRole = switch (role) {
            .turn_workspace => .turn_workspace,
            .expected_workspace => .expected_workspace,
            else => return null,
        };
        for (self.flow_case.fixtures) |fixture| {
            if (fixture.role == fixture_role and
                std.mem.startsWith(u8, fixture.path, prefix) and
                std.mem.eql(u8, fixture.path[prefix.len..], path)) return fixture.bytes;
        }
        return null;
    }

    fn fail(self: *Runner, mismatch: artifact.ReplayMismatch) error{ReplayMismatch} {
        self.last_mismatch = mismatch;
        return error.ReplayMismatch;
    }
};

pub const approvalPreviewDigest = observation.approvalPreviewDigest;
