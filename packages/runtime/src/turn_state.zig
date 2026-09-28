//! Per-request state for one accepted agent turn.
//!
//! The server creates this state after agent admission. Frame 0 borrows it
//! through `HttpRequestView`; nested tool frames do not. The state owns only
//! bounded metadata. Prompt, provider payload, tool arguments, and tool results
//! do not enter it.

const std = @import("std");
const zq = @import("zts");
const turn_recorder = @import("turn_recorder.zig");

pub const TurnId = turn_recorder.TurnId;
pub const OutcomeClass = turn_recorder.OutcomeClass;
pub const TerminalTag = turn_recorder.TerminalTag;
pub const Recorder = turn_recorder.Recorder;

/// A bounded, server-scoped identity for one provider-selected tool call.
/// A4 composes it from the turn identity, round ordinal, and provider call ID.
pub const CallIdentity = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const ProviderPhase = zq.trace.ProviderPhase;

pub const TurnState = struct {
    allocator: std.mem.Allocator,
    id: TurnId,
    limits: zq.handler_contract.AgentLimits,
    deadline_ns: u64,
    recorder: *Recorder,

    /// Number of provider fetch attempts admitted by a durable pre-record.
    round: u32 = 0,
    /// Zero-based ordinal shared by the active provider pre/post pair.
    provider_ordinal: ?u32 = null,
    provider_timeout_ms: ?u32 = null,
    provider_started_ns: u64 = 0,
    tool_calls_total: u32 = 0,
    tool_calls_current_round: u32 = 0,
    call_identities: []CallIdentity,
    call_identity_count: usize = 0,
    /// Set after the durable tool pre-record and cleared only after the tool
    /// outcome is established and its post-record is attempted.
    tool_in_flight: bool = false,
    /// A nested fetch reached the outer turn deadline. The tool cannot hide
    /// this by catching its 599 response and returning another response.
    tool_deadline_hit: bool = false,

    /// The first failure closes the latch. Later failures cannot replace it.
    latch: ?TerminalTag = null,
    sequence: u32 = 1,

    provider_phase: ProviderPhase = .not_started,
    provider_status: ?u16 = null,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        id: TurnId,
        limits: zq.handler_contract.AgentLimits,
        deadline_ns: u64,
        recorder: *Recorder,
    ) std.mem.Allocator.Error!Self {
        const call_identities = try allocator.alloc(CallIdentity, @intCast(limits.tool_calls));
        errdefer allocator.free(call_identities);
        return .{
            .allocator = allocator,
            .id = id,
            .limits = limits,
            .deadline_ns = deadline_ns,
            .recorder = recorder,
            .call_identities = call_identities,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.call_identities);
        self.* = undefined;
    }

    pub fn closeLatch(self: *Self, tag: TerminalTag) void {
        std.debug.assert(tag.isLatchTag());
        if (self.latch == null) self.latch = tag;
    }

    pub fn deadlineExpired(self: *const Self, now_ns: u64) bool {
        return now_ns >= self.deadline_ns;
    }

    /// Return the fetch timeout in whole milliseconds. Callers check
    /// `deadlineExpired` first. The outbound watchdog accepts no value below
    /// one millisecond, so a positive sub-millisecond remainder maps to one.
    pub fn effectiveOutboundTimeoutMs(self: *const Self, configured_ms: u32, now_ns: u64) u32 {
        if (self.deadlineExpired(now_ns)) return 1;
        const remaining_ns = self.deadline_ns - now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @min(configured_ms, @as(u32, @intCast(@min(remaining_ms, std.math.maxInt(u32)))));
    }

    pub fn roundBudgetExhausted(self: *const Self) bool {
        return self.round >= self.limits.rounds;
    }

    /// Spend one provider round only after the recorder accepted its pre-row.
    pub fn spendRound(self: *Self) void {
        std.debug.assert(!self.roundBudgetExhausted());
        self.provider_ordinal = self.round;
        self.round += 1;
        self.tool_calls_current_round = 0;
        self.call_identity_count = 0;
        self.provider_phase = .not_started;
        self.provider_status = null;
    }

    pub fn toolBudgetExhausted(self: *const Self) bool {
        return self.tool_calls_total >= self.limits.tool_calls or
            self.tool_calls_current_round >= self.limits.tool_calls_per_round;
    }

    /// Spend before name resolution. Invalid and unknown calls consume budget.
    pub fn spendToolCall(self: *Self) void {
        std.debug.assert(!self.toolBudgetExhausted());
        self.tool_calls_total += 1;
        self.tool_calls_current_round += 1;
    }

    /// Register one identity in the active round. False means it was already
    /// admitted. The backing slice is bounded by the total call budget.
    pub fn registerCallIdentity(self: *Self, identity: CallIdentity) bool {
        for (self.call_identities[0..self.call_identity_count]) |existing| {
            if (std.mem.eql(u8, &existing, &identity)) return false;
        }
        std.debug.assert(self.call_identity_count < self.call_identities.len);
        self.call_identities[self.call_identity_count] = identity;
        self.call_identity_count += 1;
        return true;
    }

    pub fn beginTool(self: *Self) void {
        std.debug.assert(!self.tool_in_flight);
        self.tool_in_flight = true;
        self.tool_deadline_hit = false;
    }

    pub fn markToolDeadlineHit(self: *Self) void {
        if (!self.tool_in_flight) return;
        self.tool_deadline_hit = true;
        self.closeLatch(.outcome_unknown);
    }

    pub fn finishTool(self: *Self) void {
        self.tool_in_flight = false;
        self.tool_deadline_hit = false;
    }

    pub fn setProviderTimeout(self: *Self, configured_ms: u32, now_ns: u64) void {
        self.provider_timeout_ms = self.effectiveOutboundTimeoutMs(configured_ms, now_ns);
    }

    pub fn requestStarted(self: *Self) void {
        std.debug.assert(self.provider_phase == .not_started);
        self.provider_phase = .request_started;
    }

    pub fn headReceived(self: *Self, status: u16) void {
        std.debug.assert(self.provider_phase == .request_started);
        self.provider_phase = .head_received;
        self.provider_status = status;
    }

    pub fn responseCompleted(self: *Self) void {
        std.debug.assert(self.provider_phase == .head_received);
        self.provider_phase = .completed;
    }

    pub fn providerOutcome(self: *const Self) OutcomeClass {
        return switch (self.provider_phase) {
            .not_started => .not_started,
            .request_started, .head_received => .outcome_unknown,
            .completed => .completed,
        };
    }

    pub fn nextSequence(self: *const Self) u32 {
        return self.sequence;
    }

    pub fn recordSucceeded(self: *Self) void {
        self.sequence += 1;
    }

    pub fn terminalTag(self: *const Self, status: u16, handler_timed_out: bool) TerminalTag {
        if (self.tool_in_flight or self.latch == .outcome_unknown) return .outcome_unknown;
        if (self.latch == .deadline_exceeded or handler_timed_out) return .deadline_exceeded;
        if (self.latch) |tag| return tag;
        return if (status >= 200 and status < 300) .completed else .failed;
    }
};

const test_limits: zq.handler_contract.AgentLimits = .{
    .rounds = 2,
    .tool_calls = 3,
    .tool_calls_per_round = 2,
    .argument_bytes = 1024,
    .result_bytes = 1024,
    .turn_deadline_ms = 1000,
    .provider_request_bytes = 2048,
};

test "turn state covers every outcome class and terminal tag" {
    var recorder = Recorder.initMemory(std.testing.allocator, 64 * 1024);
    defer recorder.deinit();
    var turn = try TurnState.init(
        std.testing.allocator,
        [_]u8{0x2a} ** 16,
        test_limits,
        10 * std.time.ns_per_s,
        &recorder,
    );
    defer turn.deinit();

    var observed_classes = [_]bool{false} ** @typeInfo(OutcomeClass).@"enum".fields.len;
    observed_classes[@intFromEnum(turn.providerOutcome())] = true;
    turn.requestStarted();
    observed_classes[@intFromEnum(turn.providerOutcome())] = true;
    turn.headReceived(200);
    turn.responseCompleted();
    observed_classes[@intFromEnum(turn.providerOutcome())] = true;
    for (observed_classes) |observed| try std.testing.expect(observed);

    var observed_tags = [_]bool{false} ** @typeInfo(TerminalTag).@"enum".fields.len;
    observed_tags[@intFromEnum(turn.terminalTag(200, false))] = true;
    observed_tags[@intFromEnum(turn.terminalTag(500, false))] = true;
    inline for (@typeInfo(TerminalTag).@"enum".fields) |field| {
        const tag: TerminalTag = @enumFromInt(field.value);
        if (tag.isLatchTag()) {
            turn.latch = null;
            turn.closeLatch(tag);
            observed_tags[@intFromEnum(turn.terminalTag(200, false))] = true;
        }
    }
    turn.latch = null;
    observed_tags[@intFromEnum(turn.terminalTag(200, true))] = true;
    for (observed_tags) |observed| try std.testing.expect(observed);

    try std.testing.expectEqual(@as(usize, test_limits.tool_calls), turn.call_identities.len);
}

test "turn terminal keeps the first latch and applies timeout precedence" {
    var recorder = Recorder.initMemory(std.testing.allocator, 64 * 1024);
    defer recorder.deinit();
    var turn = try TurnState.init(
        std.testing.allocator,
        [_]u8{0x17} ** 16,
        test_limits,
        10 * std.time.ns_per_s,
        &recorder,
    );
    defer turn.deinit();

    turn.closeLatch(.outcome_unknown);
    turn.closeLatch(.recorder_unavailable);
    try std.testing.expectEqual(TerminalTag.outcome_unknown, turn.latch.?);
    try std.testing.expectEqual(TerminalTag.outcome_unknown, turn.terminalTag(200, true));

    turn.latch = null;
    try std.testing.expectEqual(TerminalTag.deadline_exceeded, turn.terminalTag(200, true));
}

test "turn outbound timeout cannot exceed its remaining deadline" {
    var recorder = Recorder.initMemory(std.testing.allocator, 64 * 1024);
    defer recorder.deinit();
    var turn = try TurnState.init(
        std.testing.allocator,
        [_]u8{0x35} ** 16,
        test_limits,
        20 * std.time.ns_per_ms,
        &recorder,
    );
    defer turn.deinit();

    try std.testing.expectEqual(@as(u32, 20), turn.effectiveOutboundTimeoutMs(100, 0));
    try std.testing.expectEqual(@as(u32, 5), turn.effectiveOutboundTimeoutMs(100, 15 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u32, 1), turn.effectiveOutboundTimeoutMs(100, 20 * std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(u32, 1), turn.effectiveOutboundTimeoutMs(100, 20 * std.time.ns_per_ms));
}

test "tool calls spend budget before validation and deduplicate within a round" {
    var recorder = Recorder.initMemory(std.testing.allocator, 64 * 1024);
    defer recorder.deinit();
    var turn = try TurnState.init(
        std.testing.allocator,
        [_]u8{0x44} ** 16,
        test_limits,
        10 * std.time.ns_per_s,
        &recorder,
    );
    defer turn.deinit();

    turn.spendToolCall();
    const first = [_]u8{0x11} ** 32;
    try std.testing.expect(turn.registerCallIdentity(first));
    try std.testing.expect(!turn.registerCallIdentity(first));
    try std.testing.expectEqual(@as(u32, 1), turn.tool_calls_total);
    try std.testing.expectEqual(@as(u32, 1), turn.tool_calls_current_round);

    turn.spendRound();
    try std.testing.expect(turn.registerCallIdentity(first));
    try std.testing.expectEqual(@as(usize, 1), turn.call_identity_count);
}

test "tool in flight wins terminal timeout classification" {
    var recorder = Recorder.initMemory(std.testing.allocator, 64 * 1024);
    defer recorder.deinit();
    var turn = try TurnState.init(
        std.testing.allocator,
        [_]u8{0x55} ** 16,
        test_limits,
        10 * std.time.ns_per_s,
        &recorder,
    );
    defer turn.deinit();

    turn.beginTool();
    try std.testing.expectEqual(TerminalTag.outcome_unknown, turn.terminalTag(200, true));
    turn.finishTool();
    try std.testing.expectEqual(TerminalTag.deadline_exceeded, turn.terminalTag(200, true));
}
