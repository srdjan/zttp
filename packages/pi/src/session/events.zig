//! Session persistence primitives: checksummed event frames + meta.json.
//!
//! Event schema `v3` keeps the raw journal append-only, assigns stable logical
//! entry IDs, and persists model-projection checkpoints independently from the
//! proof and ledger history.
//! Metadata schema `v4` adds the required expert protocol identity. The event
//! envelope did not change, so its framed wire remains v3.

const std = @import("std");
const zts = @import("zts");
const ui_payload = @import("../ui_payload.zig");
const json_writer = @import("../providers/json_writer.zig");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;

pub const schema_version: u32 = 3;
pub const meta_schema_version: u32 = 4;

const frame_magic = "ZTE3";
const frame_header_len = frame_magic.len + @sizeOf(u64) + 32;
const frame_footer_magic = "3ETZ";
const frame_footer_len = @sizeOf(u64) + frame_footer_magic.len;
const max_frame_payload_bytes: usize = 64 * 1024 * 1024;

const EventKind = enum {
    user_text,
    model_text,
    tool_use,
    tool_use_batch,
    tool_result,
    proof_card,
    diagnostic_box,
    verified_patch,
    system_note,
    autoloop_outcome,
    turn_end,
    session_summary,
    compaction_checkpoint,
};

pub const EntryId = u64;

pub const CompactionReason = enum { manual, threshold, overflow };

pub const CompactionCheckpoint = struct {
    summary: []const u8,
    first_kept_entry_id: EntryId,
    reason: CompactionReason,
    tokens_before: u64 = 0,
    estimated_tokens_after: u64 = 0,
    summary_input_tokens: u64 = 0,
    summary_output_tokens: u64 = 0,
    will_retry: bool = false,
    read_files: []const []const u8 = &.{},
    modified_files: []const []const u8 = &.{},
};

pub const TurnEndReason = enum {
    approved,
    veto_exhausted,
    budget_roundtrips,
    budget_tool_calls,
    /// Turn ended on the wall-clock time limit rather than the round-trip or
    /// tool-call count, so a stalled session is distinguishable from one that
    /// merely ran out of round-trips.
    budget_timeout,
    approval_denied,
    error_exit,
};

pub const TurnEnd = struct {
    reason: TurnEndReason,
};

/// One per expert session, appended at session close. Carries the signals the
/// release scorecard is staked on (see STRATEGY.md): expert success rate
/// (`reached_proof` aggregated across sessions), round-trips to first green
/// proof (`round_trips_to_first_green`), and the proven-path ratio
/// (`proven_properties / tracked_properties`). `verified_patch_count` is the
/// number of edits the compiler veto approved this session - the authoritative
/// "handler advanced" signal, since a plain-text turn (e.g. a clarifying
/// question) ends `approved` without applying an edit.
pub const SessionSummary = struct {
    turn_count: u32 = 0,
    total_roundtrips: u32 = 0,
    verified_patch_count: u32 = 0,
    reached_proof: bool = false,
    /// Model round-trips accumulated up to and including the turn that produced
    /// the first verified edit. 0 when no edit was applied this session.
    round_trips_to_first_green: u32 = 0,
    /// Proof guarantees discharged on the final verified handler, over the
    /// number tracked (see PropertiesSnapshot.guaranteeCounts). Both 0 when the
    /// session never reached a verified edit.
    proven_properties: u32 = 0,
    tracked_properties: u32 = 0,
    workflow_hint_count: u32 = 0,
    high_confidence_workflow_hint_count: u32 = 0,
    raw_first_draft_veto_pass_count: u32 = 0,
    first_attempt_green_count: u32 = 0,
    veto_retry_count: u32 = 0,
    tool_call_count: u32 = 0,
    /// Edits that landed via the compiler-authored repair lane with no model
    /// round-trip (model-free applies). Over verified_patch_count this is the
    /// "% of edits that became model-free" win.
    compiler_authored_apply_count: u32 = 0,
    last_workflow_kind: []const u8 = "unknown",
    last_workflow_confidence: []const u8 = "low",
    final_outcome: TurnEndReason = .approved,

    /// Fraction of tracked proof guarantees discharged for the final handler.
    /// 0 when nothing was proven this session.
    pub fn provenPathRatio(self: SessionSummary) f32 {
        if (self.tracked_properties == 0) return 0;
        return @as(f32, @floatFromInt(self.proven_properties)) /
            @as(f32, @floatFromInt(self.tracked_properties));
    }
};

pub const AutoloopVerdict = enum {
    achieved,
    exhausted_iters,
    exhausted_time,
    stalled,
    regression_blocked,
    /// User requested cancellation (Ctrl-C) and the autoloop returned
    /// at the next phase boundary. Distinct from achieved and stalled
    /// because the property may be in any state - the run was cut
    /// short by the user, not by progress or budget.
    cancelled,

    pub fn asString(self: AutoloopVerdict) []const u8 {
        return @tagName(self);
    }
};

pub const AutoloopOutcome = struct {
    verdict: AutoloopVerdict,
    final_patch_hash: ?[32]u8 = null,
    goals_met: []const []const u8 = &.{},
    goals_unmet: []const []const u8 = &.{},
    iterations: u32 = 0,
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
    reasoning_content: ?[]const u8 = null,
};

pub const DisplayMessage = struct {
    llm_text: []const u8,
    ui_payload: ?ui_payload.UiPayload = null,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    ok: bool,
    llm_text: []const u8,
    ui_payload: ?ui_payload.UiPayload = null,
};

pub const EventRecord = union(EventKind) {
    user_text: []const u8,
    model_text: []const u8,
    tool_use: ToolUse,
    tool_use_batch: []const ToolUse,
    tool_result: ToolResult,
    proof_card: DisplayMessage,
    diagnostic_box: DisplayMessage,
    verified_patch: DisplayMessage,
    system_note: []const u8,
    autoloop_outcome: AutoloopOutcome,
    turn_end: TurnEnd,
    session_summary: SessionSummary,
    compaction_checkpoint: CompactionCheckpoint,
};

const Envelope = struct {
    record: EventRecord,
    entry_id: ?EntryId = null,
    part_index: ?u32 = null,
};

pub const Meta = struct {
    schema_version: u32 = meta_schema_version,
    session_id: []const u8,
    workspace_realpath: []const u8,
    created_at_unix_ms: i64,
    parent_id: ?[]const u8 = null,
    policy_hash: []const u8,
    /// Exact identity of the stable persona, schema-v2 compiler authority, and
    /// ordered provider-neutral tool catalog used by this session.
    protocol_hash: []const u8,
    /// String tag of the ApprovalPolicy in effect when the session was created
    /// ("ask", "auto_approve", "auto_reject"). Written on first create; re-read
    /// on --resume so the policy persists across sessions without re-passing flags.
    approval_policy: ?[]const u8 = null,
    /// Public provider identity ("local", "claude", or "openai"). Optional
    /// only while decoding sessions created before provider persistence.
    provider: ?[]const u8 = null,
    /// Exact provider-scoped model id. Optional only for historical metadata.
    model: ?[]const u8 = null,
};

pub fn appendEvent(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    record: EventRecord,
) !void {
    if (isTranscriptRecord(record)) return error.InvalidEventIdentity;
    return appendEnvelope(allocator, events_path, .{ .record = record });
}

pub fn appendEntryEvent(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    entry_id: EntryId,
    part_index: ?u32,
    record: EventRecord,
) !void {
    if (!isTranscriptRecord(record) or entry_id == 0) return error.InvalidEventIdentity;
    return appendEnvelope(allocator, events_path, .{
        .record = record,
        .entry_id = entry_id,
        .part_index = part_index,
    });
}

/// Exclusive, session-scoped writer for one v3 journal. Opening validates and
/// recovers the complete journal once, then holds a sidecar lock until deinit.
/// Each append checks that the validated EOF is unchanged and validates only
/// the new typed envelope before writing and syncing it.
pub const JournalWriter = struct {
    lock_fd: std.c.fd_t,
    events_fd: std.c.fd_t,
    validated_size: u64,
    poisoned: bool = false,
    owns_lock: bool = true,
    sequence: JournalSequence = .{},

    pub fn open(allocator: std.mem.Allocator, events_path: []const u8) !JournalWriter {
        return openWithMode(allocator, events_path, true);
    }

    /// Claim and validate a journal that must already exist. Resume uses this
    /// so missing history cannot be silently replaced with an empty file.
    pub fn openExisting(allocator: std.mem.Allocator, events_path: []const u8) !JournalWriter {
        return openWithMode(allocator, events_path, false);
    }

    fn openWithMode(
        allocator: std.mem.Allocator,
        events_path: []const u8,
        create: bool,
    ) !JournalWriter {
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{events_path});
        defer allocator.free(lock_path);
        const lock_path_z = try allocator.dupeZ(u8, lock_path);
        defer allocator.free(lock_path_z);
        const lock_fd = try std.posix.openatZ(
            std.posix.AT.FDCWD,
            lock_path_z,
            .{ .ACCMODE = .WRONLY, .CREAT = true },
            0o600,
        );
        errdefer std.Io.Threaded.closeFd(lock_fd);
        try lockExclusiveNonBlocking(lock_fd);
        errdefer _ = std.c.flock(lock_fd, std.posix.LOCK.UN);

        try recoverTail(allocator, events_path);
        const events_path_z = try allocator.dupeZ(u8, events_path);
        defer allocator.free(events_path_z);
        const events_fd = if (create)
            try std.posix.openatZ(
                std.posix.AT.FDCWD,
                events_path_z,
                .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true },
                0o600,
            )
        else
            try std.posix.openatZ(
                std.posix.AT.FDCWD,
                events_path_z,
                .{ .ACCMODE = .RDWR, .APPEND = true },
                0,
            );
        errdefer std.Io.Threaded.closeFd(events_fd);
        const size = (try zts.file_io.fstatFd(events_fd)).size;
        const sequence = try deriveJournalSequence(allocator, events_fd, size);
        return .{
            .lock_fd = lock_fd,
            .events_fd = events_fd,
            .validated_size = size,
            .sequence = sequence,
        };
    }

    pub fn deinit(self: *JournalWriter) void {
        if (self.owns_lock) _ = std.c.flock(self.lock_fd, std.posix.LOCK.UN);
        std.Io.Threaded.closeFd(self.events_fd);
        std.Io.Threaded.closeFd(self.lock_fd);
        self.* = undefined;
    }

    pub fn duplicate(self: *const JournalWriter) !JournalWriter {
        if (self.poisoned) return error.JournalWriterPoisoned;
        const lock_fd = std.c.dup(self.lock_fd);
        if (lock_fd < 0) return error.SessionLockFailed;
        errdefer std.Io.Threaded.closeFd(lock_fd);
        const events_fd = std.c.dup(self.events_fd);
        if (events_fd < 0) return error.SessionLockFailed;
        return .{
            .lock_fd = lock_fd,
            .events_fd = events_fd,
            .validated_size = self.validated_size,
            .owns_lock = false,
            .sequence = self.sequence,
        };
    }

    pub fn transferLockOwnership(from: *JournalWriter, to: *JournalWriter) !void {
        if (!from.owns_lock or to.owns_lock) return error.InvalidJournalLockTransfer;
        from.owns_lock = false;
        to.owns_lock = true;
    }

    pub fn refresh(
        self: *JournalWriter,
        allocator: std.mem.Allocator,
        events_path: []const u8,
    ) !void {
        try recoverTail(allocator, events_path);
        self.validated_size = (try zts.file_io.fstatFd(self.events_fd)).size;
        self.sequence = try deriveJournalSequence(allocator, self.events_fd, self.validated_size);
        self.poisoned = false;
    }

    pub fn appendEvent(
        self: *JournalWriter,
        allocator: std.mem.Allocator,
        record: EventRecord,
    ) !void {
        if (isTranscriptRecord(record)) return error.InvalidEventIdentity;
        return self.appendEnvelope(allocator, .{ .record = record });
    }

    pub fn appendEntryEvent(
        self: *JournalWriter,
        allocator: std.mem.Allocator,
        entry_id: EntryId,
        part_index: ?u32,
        record: EventRecord,
    ) !void {
        if (!isTranscriptRecord(record) or entry_id == 0) return error.InvalidEventIdentity;
        return self.appendEnvelope(allocator, .{
            .record = record,
            .entry_id = entry_id,
            .part_index = part_index,
        });
    }

    fn appendEnvelope(
        self: *JournalWriter,
        allocator: std.mem.Allocator,
        envelope: Envelope,
    ) !void {
        if (self.poisoned) return error.JournalWriterPoisoned;
        var buf = TextBuffer.init(allocator);
        defer buf.deinit();

        try writeEnvelopeJson(buf.writer(), envelope);
        const payload = buf.written();
        if (payload.len > max_frame_payload_bytes) return error.EventTooLarge;
        try validateEnvelopePayload(allocator, payload);
        var next_sequence = self.sequence;
        try applySequenceTransition(allocator, &next_sequence, payload);
        errdefer self.poisoned = true;
        const current_size = (try zts.file_io.fstatFd(self.events_fd)).size;
        if (current_size != self.validated_size) return error.ConcurrentJournalMutation;

        var header: [frame_header_len]u8 = undefined;
        @memcpy(header[0..frame_magic.len], frame_magic);
        std.mem.writeInt(u64, header[frame_magic.len .. frame_magic.len + @sizeOf(u64)], @intCast(payload.len), .big);
        std.crypto.hash.sha2.Sha256.hash(payload, header[frame_magic.len + @sizeOf(u64) ..], .{});
        var footer: [frame_footer_len]u8 = undefined;
        std.mem.writeInt(u64, footer[0..@sizeOf(u64)], @intCast(payload.len), .big);
        @memcpy(footer[@sizeOf(u64)..], frame_footer_magic);

        try writeAllFd(self.events_fd, &header);
        try writeAllFd(self.events_fd, payload);
        try writeAllFd(self.events_fd, &footer);
        try writeAllFd(self.events_fd, "\n");
        if (std.c.fsync(self.events_fd) != 0) return error.SyncFailure;
        const frame_len = std.math.add(
            u64,
            frame_header_len + frame_footer_len + 1,
            @as(u64, @intCast(payload.len)),
        ) catch return error.EventTooLarge;
        self.validated_size = std.math.add(u64, self.validated_size, frame_len) catch
            return error.EventTooLarge;
        self.sequence = next_sequence;
    }
};

fn lockExclusiveNonBlocking(fd: std.c.fd_t) !void {
    while (true) switch (std.posix.errno(std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => return,
        .INTR => continue,
        .AGAIN => return error.SessionAlreadyActive,
        else => return error.SessionLockFailed,
    };
}

fn appendEnvelope(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    envelope: Envelope,
) !void {
    var writer = try JournalWriter.open(allocator, events_path);
    defer writer.deinit();
    return writer.appendEnvelope(allocator, envelope);
}

fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var total: usize = 0;
    while (total < bytes.len) {
        const rc = std.c.write(fd, bytes[total..].ptr, bytes.len - total);
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return error.WriteFailure;
        total += @intCast(rc);
    }
}

fn writeEnvelopeJson(writer: *std.Io.Writer, envelope: Envelope) !void {
    try writer.writeAll("{\"v\":");
    try writer.print("{d}", .{schema_version});
    if (envelope.entry_id) |entry_id| {
        try writer.writeAll(",\"entry_id\":");
        try writer.print("{d}", .{entry_id});
    }
    if (envelope.part_index) |part_index| {
        try writer.writeAll(",\"part_index\":");
        try writer.print("{d}", .{part_index});
    }
    try writer.writeAll(",\"k\":");
    try json_writer.writeString(writer, kindTag(envelope.record));
    try writer.writeAll(",\"d\":");
    try writePayload(writer, envelope.record);
    try writer.writeByte('}');
}

pub const Reader = struct {
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    offset: u64 = 0,
    size: u64,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Reader {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.Io.Threaded.closeFd(fd);
        return .{ .allocator = allocator, .fd = fd, .size = (try zts.file_io.fstatFd(fd)).size };
    }

    pub fn deinit(self: *Reader) void {
        std.Io.Threaded.closeFd(self.fd);
        self.* = undefined;
    }

    pub fn next(self: *Reader) !?[]u8 {
        if (self.offset == self.size) return null;
        if (self.size - self.offset < frame_header_len + frame_footer_len + 1) {
            var first: [1]u8 = undefined;
            try preadExact(self.fd, &first, self.offset);
            if (self.offset == 0 and first[0] == '{') return error.SchemaVersionUnsupported;
            return error.IncompleteEventFrame;
        }

        var header: [frame_header_len]u8 = undefined;
        try preadExact(self.fd, &header, self.offset);
        if (!std.mem.eql(u8, header[0..frame_magic.len], frame_magic)) {
            if (self.offset == 0 and header[0] == '{') return error.SchemaVersionUnsupported;
            return error.CorruptEventsLog;
        }
        const payload_len_u64 = std.mem.readInt(u64, header[frame_magic.len .. frame_magic.len + @sizeOf(u64)], .big);
        const payload_len = std.math.cast(usize, payload_len_u64) orelse return error.EventTooLarge;
        if (payload_len > max_frame_payload_bytes) return error.EventTooLarge;
        const frame_len = std.math.add(
            u64,
            frame_header_len + frame_footer_len + 1,
            payload_len_u64,
        ) catch return error.EventTooLarge;
        if (frame_len > self.size - self.offset) return error.IncompleteEventFrame;

        const payload = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(payload);
        try preadExact(self.fd, payload, self.offset + frame_header_len);
        var footer: [frame_footer_len]u8 = undefined;
        try preadExact(self.fd, &footer, self.offset + frame_header_len + payload_len_u64);
        if (std.mem.readInt(u64, footer[0..@sizeOf(u64)], .big) != payload_len_u64 or
            !std.mem.eql(u8, footer[@sizeOf(u64)..], frame_footer_magic))
        {
            return error.CorruptEventsLog;
        }
        var terminator: [1]u8 = undefined;
        try preadExact(
            self.fd,
            &terminator,
            self.offset + frame_header_len + payload_len_u64 + frame_footer_len,
        );
        if (terminator[0] != '\n') return error.CorruptEventsLog;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, header[frame_magic.len + @sizeOf(u64) ..])) {
            return error.CorruptEventsLog;
        }
        self.offset += frame_len;
        return payload;
    }
};

fn preadExact(fd: std.c.fd_t, bytes: []u8, offset: u64) !void {
    var read_total: usize = 0;
    while (read_total < bytes.len) {
        const rc = std.c.pread(fd, bytes[read_total..].ptr, bytes.len - read_total, @intCast(offset + read_total));
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return error.IncompleteEventFrame;
        read_total += @intCast(rc);
    }
}

pub fn recoverIncompleteTail(allocator: std.mem.Allocator, events_path: []const u8) !void {
    var writer = try JournalWriter.openExisting(allocator, events_path);
    writer.deinit();
}

fn recoverTail(
    allocator: std.mem.Allocator,
    events_path: []const u8,
) !void {
    if (!zts.file_io.fileExists(allocator, events_path)) return;
    const path_z = try allocator.dupeZ(u8, events_path);
    defer allocator.free(path_z);
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0);
    defer std.Io.Threaded.closeFd(fd);
    const size = (try zts.file_io.fstatFd(fd)).size;
    if (size == 0) return;

    var first: [1]u8 = undefined;
    try preadExact(fd, &first, 0);
    if (first[0] == '{') return error.SchemaVersionUnsupported;

    var offset: u64 = 0;
    while (offset < size) {
        if (size - offset < frame_header_len + frame_footer_len + 1) break;
        var header: [frame_header_len]u8 = undefined;
        try preadExact(fd, &header, offset);
        if (!std.mem.eql(u8, header[0..frame_magic.len], frame_magic)) {
            return error.CorruptEventsLog;
        }
        const payload_len = std.mem.readInt(u64, header[frame_magic.len .. frame_magic.len + @sizeOf(u64)], .big);
        if (payload_len > max_frame_payload_bytes) return error.EventTooLarge;
        const frame_len = std.math.add(
            u64,
            frame_header_len + frame_footer_len + 1,
            payload_len,
        ) catch return error.EventTooLarge;
        if (frame_len > size - offset) break;
        var footer: [frame_footer_len]u8 = undefined;
        try preadExact(fd, &footer, offset + frame_header_len + payload_len);
        if (std.mem.readInt(u64, footer[0..@sizeOf(u64)], .big) != payload_len or
            !std.mem.eql(u8, footer[@sizeOf(u64)..], frame_footer_magic))
        {
            return error.CorruptEventsLog;
        }
        var terminator: [1]u8 = undefined;
        try preadExact(fd, &terminator, offset + frame_header_len + payload_len + frame_footer_len);
        if (terminator[0] != '\n') return error.CorruptEventsLog;
        const payload = try allocator.alloc(u8, @intCast(payload_len));
        defer allocator.free(payload);
        try preadExact(fd, payload, offset + frame_header_len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, header[frame_magic.len + @sizeOf(u64) ..])) {
            return error.CorruptEventsLog;
        }
        try validateEnvelopePayload(allocator, payload);
        offset += frame_len;
    }
    if (offset != size) {
        if (std.c.ftruncate(fd, @intCast(offset)) != 0) return error.TruncateFailure;
        if (std.c.fsync(fd) != 0) return error.SyncFailure;
    }
}

const JournalSequence = struct {
    next_entry_id: EntryId = 1,
    legacy_tool_entry_id: ?EntryId = null,
    next_legacy_part: u32 = 0,
};

fn deriveJournalSequence(
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    size: u64,
) !JournalSequence {
    var sequence: JournalSequence = .{};
    var reader: Reader = .{ .allocator = allocator, .fd = fd, .size = size };
    while (try reader.next()) |payload| {
        defer allocator.free(payload);
        try applySequenceTransition(allocator, &sequence, payload);
    }
    return sequence;
}

fn applySequenceTransition(
    allocator: std.mem.Allocator,
    sequence: *JournalSequence,
    payload: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch
        return error.CorruptEventsLog;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptEventsLog;
    const object = parsed.value.object;
    const kind_value = object.get("k") orelse return error.CorruptEventsLog;
    if (kind_value != .string) return error.CorruptEventsLog;
    const kind = std.meta.stringToEnum(EventKind, kind_value.string) orelse
        return error.CorruptEventsLog;
    const entry_value = object.get("entry_id");
    if (entry_value) |raw_entry| {
        if (raw_entry != .integer or raw_entry.integer <= 0) return error.CorruptEventsLog;
        const entry_id = std.math.cast(EntryId, raw_entry.integer) orelse
            return error.CorruptEventsLog;
        const part_value = object.get("part_index");
        if (kind == .tool_use and part_value != null) {
            const raw_part = part_value orelse return error.CorruptEventsLog;
            if (raw_part != .integer or raw_part.integer < 0) return error.CorruptEventsLog;
            const part = std.math.cast(u32, raw_part.integer) orelse
                return error.CorruptEventsLog;
            if (part == 0) {
                if (entry_id != sequence.next_entry_id) return error.CorruptEventsLog;
                sequence.next_entry_id = std.math.add(EntryId, sequence.next_entry_id, 1) catch
                    return error.EventIdentityOverflow;
                sequence.legacy_tool_entry_id = entry_id;
                sequence.next_legacy_part = 1;
            } else {
                const current_tool_id = sequence.legacy_tool_entry_id orelse
                    return error.CorruptEventsLog;
                if (entry_id != current_tool_id or part != sequence.next_legacy_part) {
                    return error.CorruptEventsLog;
                }
                sequence.next_legacy_part = std.math.add(u32, part, 1) catch
                    return error.EventIdentityOverflow;
            }
        } else {
            if (entry_id != sequence.next_entry_id) return error.CorruptEventsLog;
            sequence.next_entry_id = std.math.add(EntryId, sequence.next_entry_id, 1) catch
                return error.EventIdentityOverflow;
            sequence.legacy_tool_entry_id = null;
            sequence.next_legacy_part = 0;
        }
        return;
    }

    if (kind == .compaction_checkpoint) {
        const data = object.get("d") orelse return error.CorruptEventsLog;
        if (data != .object) return error.CorruptEventsLog;
        const first_kept = data.object.get("first_kept_entry_id") orelse
            return error.CorruptEventsLog;
        if (first_kept != .integer or first_kept.integer <= 0) return error.CorruptEventsLog;
        const kept_id = std.math.cast(EntryId, first_kept.integer) orelse
            return error.CorruptEventsLog;
        // The next entry ID is an exclusive tail boundary. It represents a
        // checkpoint whose summary covers every entry currently in the raw
        // journal; a later append with that ID becomes the first visible suffix
        // entry. Anything beyond the next ID is still a corrupt cut identity.
        if (kept_id > sequence.next_entry_id) return error.CorruptEventsLog;
    }
}

fn validateEnvelopePayload(allocator: std.mem.Allocator, payload: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch
        return error.CorruptEventsLog;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CorruptEventsLog;
    const object = parsed.value.object;
    const version = object.get("v") orelse return error.CorruptEventsLog;
    const kind = object.get("k") orelse return error.CorruptEventsLog;
    const data = object.get("d") orelse return error.CorruptEventsLog;
    if (version != .integer or version.integer != schema_version or kind != .string) {
        return error.CorruptEventsLog;
    }
    const event_kind = std.meta.stringToEnum(EventKind, kind.string) orelse
        return error.CorruptEventsLog;
    const entry_id = object.get("entry_id");
    const part_index = object.get("part_index");
    const transcript_record = switch (event_kind) {
        .user_text, .model_text, .tool_use, .tool_use_batch, .tool_result, .proof_card, .diagnostic_box, .verified_patch, .system_note => true,
        .autoloop_outcome, .turn_end, .session_summary, .compaction_checkpoint => false,
    };
    if (transcript_record) {
        const id = entry_id orelse return error.CorruptEventsLog;
        if (id != .integer or id.integer <= 0) {
            return error.CorruptEventsLog;
        }
    } else if (entry_id != null or part_index != null) return error.CorruptEventsLog;
    if (part_index) |part| {
        if (event_kind != .tool_use or part != .integer or part.integer < 0) {
            return error.CorruptEventsLog;
        }
    }
    switch (event_kind) {
        .user_text, .model_text, .system_note => if (data != .string) return error.CorruptEventsLog,
        .tool_use => try validateToolUseValue(data),
        .tool_use_batch => {
            if (data != .array or data.array.items.len == 0) return error.CorruptEventsLog;
            for (data.array.items) |item| try validateToolUseValue(item);
        },
        .tool_result => {
            if (data != .object) return error.CorruptEventsLog;
            const id = data.object.get("tool_use_id") orelse return error.CorruptEventsLog;
            const name = data.object.get("tool_name") orelse return error.CorruptEventsLog;
            const ok = data.object.get("ok") orelse return error.CorruptEventsLog;
            const text = data.object.get("llm_text") orelse data.object.get("body") orelse
                return error.CorruptEventsLog;
            if (id != .string or name != .string or ok != .bool or text != .string) {
                return error.CorruptEventsLog;
            }
        },
        .proof_card, .diagnostic_box, .verified_patch => if (data != .string and data != .object) {
            return error.CorruptEventsLog;
        },
        .autoloop_outcome, .turn_end, .session_summary, .compaction_checkpoint => if (data != .object) {
            return error.CorruptEventsLog;
        },
    }
}

fn validateToolUseValue(value: std.json.Value) !void {
    if (value != .object) return error.CorruptEventsLog;
    const id = value.object.get("id") orelse return error.CorruptEventsLog;
    const name = value.object.get("name") orelse return error.CorruptEventsLog;
    const args = value.object.get("args_json") orelse return error.CorruptEventsLog;
    if (id != .string or name != .string or args != .string) return error.CorruptEventsLog;
    if (value.object.get("reasoning_content")) |reasoning| {
        if (reasoning != .string) return error.CorruptEventsLog;
    }
}

pub fn nextEntryId(allocator: std.mem.Allocator, events_path: []const u8) !EntryId {
    if (!zts.file_io.fileExists(allocator, events_path)) return 1;
    var writer = try JournalWriter.openExisting(allocator, events_path);
    defer writer.deinit();
    return writer.sequence.next_entry_id;
}

pub fn copyJournal(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    if (!zts.file_io.fileExists(allocator, source_path)) return error.FileNotFound;
    var source_writer = try JournalWriter.open(allocator, source_path);
    defer source_writer.deinit();
    return copyJournalClaimed(allocator, source_path, destination_path);
}

/// Copy a journal while the caller holds its `JournalWriter` lock. This is
/// used by `/fork`, whose current session already owns the source lock.
pub fn copyJournalClaimed(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    const source_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_z);
    const destination_z = try allocator.dupeZ(u8, destination_path);
    defer allocator.free(destination_z);
    const source_fd = try std.posix.openatZ(std.posix.AT.FDCWD, source_z, .{ .ACCMODE = .RDONLY }, 0);
    defer std.Io.Threaded.closeFd(source_fd);
    const destination_fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        destination_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o600,
    );
    defer std.Io.Threaded.closeFd(destination_fd);

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = std.posix.read(source_fd, &buffer) catch return error.ReadFailure;
        if (count == 0) break;
        try writeAllFd(destination_fd, buffer[0..count]);
    }
    if (std.c.fsync(destination_fd) != 0) return error.SyncFailure;
}

pub fn writeEventLine(writer: *std.Io.Writer, record: EventRecord) !void {
    try writeEnvelopeJson(writer, .{ .record = record });
    try writer.writeByte('\n');
}

pub fn writeEntryEventLine(
    writer: *std.Io.Writer,
    entry_id: EntryId,
    part_index: ?u32,
    record: EventRecord,
) !void {
    if (!isTranscriptRecord(record) or entry_id == 0) return error.InvalidEventIdentity;
    try writeEnvelopeJson(writer, .{
        .record = record,
        .entry_id = entry_id,
        .part_index = part_index,
    });
    try writer.writeByte('\n');
}

fn isTranscriptRecord(record: EventRecord) bool {
    return switch (record) {
        .user_text,
        .model_text,
        .tool_use,
        .tool_use_batch,
        .tool_result,
        .proof_card,
        .diagnostic_box,
        .verified_patch,
        .system_note,
        => true,
        .autoloop_outcome, .turn_end, .session_summary, .compaction_checkpoint => false,
    };
}

fn kindTag(record: EventRecord) []const u8 {
    return switch (record) {
        .user_text => "user_text",
        .model_text => "model_text",
        .tool_use => "tool_use",
        .tool_use_batch => "tool_use_batch",
        .tool_result => "tool_result",
        .proof_card => "proof_card",
        .diagnostic_box => "diagnostic_box",
        .verified_patch => "verified_patch",
        .system_note => "system_note",
        .autoloop_outcome => "autoloop_outcome",
        .turn_end => "turn_end",
        .session_summary => "session_summary",
        .compaction_checkpoint => "compaction_checkpoint",
    };
}

fn writePayload(writer: *std.Io.Writer, record: EventRecord) !void {
    switch (record) {
        .user_text, .model_text, .system_note => |body| try json_writer.writeString(writer, body),
        .tool_use => |tu| {
            try writer.writeByte('{');
            try writer.writeAll("\"id\":");
            try json_writer.writeString(writer, tu.id);
            try writer.writeAll(",\"name\":");
            try json_writer.writeString(writer, tu.name);
            try writer.writeAll(",\"args_json\":");
            try json_writer.writeString(writer, tu.args_json);
            if (tu.reasoning_content) |reasoning| {
                try writer.writeAll(",\"reasoning_content\":");
                try json_writer.writeString(writer, reasoning);
            }
            try writer.writeByte('}');
        },
        .tool_use_batch => |batch| {
            try writer.writeByte('[');
            for (batch, 0..) |tu, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeByte('{');
                try writer.writeAll("\"id\":");
                try json_writer.writeString(writer, tu.id);
                try writer.writeAll(",\"name\":");
                try json_writer.writeString(writer, tu.name);
                try writer.writeAll(",\"args_json\":");
                try json_writer.writeString(writer, tu.args_json);
                if (tu.reasoning_content) |reasoning| {
                    try writer.writeAll(",\"reasoning_content\":");
                    try json_writer.writeString(writer, reasoning);
                }
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        },
        .tool_result => |tr| {
            try writer.writeByte('{');
            try writer.writeAll("\"tool_use_id\":");
            try json_writer.writeString(writer, tr.tool_use_id);
            try writer.writeAll(",\"tool_name\":");
            try json_writer.writeString(writer, tr.tool_name);
            try writer.writeAll(",\"ok\":");
            try writer.writeAll(if (tr.ok) "true" else "false");
            try writer.writeAll(",\"llm_text\":");
            try json_writer.writeString(writer, tr.llm_text);
            try writer.writeAll(",\"body\":");
            try json_writer.writeString(writer, tr.llm_text);
            if (tr.ui_payload) |payload| {
                try writer.writeAll(",\"ui_payload\":");
                try ui_payload.writeJson(writer, payload);
            }
            try writer.writeByte('}');
        },
        .proof_card => |message| try writeDisplayPayload(writer, message),
        .diagnostic_box => |message| try writeDisplayPayload(writer, message),
        .verified_patch => |message| try writeDisplayPayload(writer, message),
        .autoloop_outcome => |outcome| try writeAutoloopOutcomePayload(writer, outcome),
        .turn_end => |te| {
            try writer.writeByte('{');
            try writer.writeAll("\"reason\":");
            try json_writer.writeString(writer, @tagName(te.reason));
            try writer.writeByte('}');
        },
        .session_summary => |s| try writeSessionSummaryPayload(writer, s),
        .compaction_checkpoint => |checkpoint| try writeCompactionCheckpointPayload(writer, checkpoint),
    }
}

fn writeCompactionCheckpointPayload(writer: *std.Io.Writer, checkpoint: CompactionCheckpoint) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"summary\":");
    try json_writer.writeString(writer, checkpoint.summary);
    try writer.writeAll(",\"first_kept_entry_id\":");
    try writer.print("{d}", .{checkpoint.first_kept_entry_id});
    try writer.writeAll(",\"reason\":");
    try json_writer.writeString(writer, @tagName(checkpoint.reason));
    try writer.print(",\"tokens_before\":{d}", .{checkpoint.tokens_before});
    try writer.print(",\"estimated_tokens_after\":{d}", .{checkpoint.estimated_tokens_after});
    try writer.print(",\"summary_input_tokens\":{d}", .{checkpoint.summary_input_tokens});
    try writer.print(",\"summary_output_tokens\":{d}", .{checkpoint.summary_output_tokens});
    try writer.writeAll(",\"will_retry\":");
    try writer.writeAll(if (checkpoint.will_retry) "true" else "false");
    try writer.writeAll(",\"read_files\":[");
    for (checkpoint.read_files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, file);
    }
    try writer.writeAll("],\"modified_files\":[");
    for (checkpoint.modified_files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, file);
    }
    try writer.writeAll("]}");
}

fn writeSessionSummaryPayload(writer: *std.Io.Writer, s: SessionSummary) !void {
    try writer.writeByte('{');
    try writer.print("\"turn_count\":{d}", .{s.turn_count});
    try writer.print(",\"total_roundtrips\":{d}", .{s.total_roundtrips});
    try writer.print(",\"verified_patch_count\":{d}", .{s.verified_patch_count});
    try writer.writeAll(",\"reached_proof\":");
    try writer.writeAll(if (s.reached_proof) "true" else "false");
    try writer.print(",\"round_trips_to_first_green\":{d}", .{s.round_trips_to_first_green});
    try writer.print(",\"proven_properties\":{d}", .{s.proven_properties});
    try writer.print(",\"tracked_properties\":{d}", .{s.tracked_properties});
    try writer.print(",\"proven_path_ratio\":{d:.3}", .{s.provenPathRatio()});
    try writer.print(",\"workflow_hint_count\":{d}", .{s.workflow_hint_count});
    try writer.print(",\"high_confidence_workflow_hint_count\":{d}", .{s.high_confidence_workflow_hint_count});
    try writer.print(",\"raw_first_draft_veto_pass_count\":{d}", .{s.raw_first_draft_veto_pass_count});
    try writer.print(",\"first_attempt_green_count\":{d}", .{s.first_attempt_green_count});
    try writer.print(",\"veto_retry_count\":{d}", .{s.veto_retry_count});
    try writer.print(",\"tool_call_count\":{d}", .{s.tool_call_count});
    try writer.print(",\"compiler_authored_apply_count\":{d}", .{s.compiler_authored_apply_count});
    try writer.writeAll(",\"last_workflow_kind\":");
    try json_writer.writeString(writer, s.last_workflow_kind);
    try writer.writeAll(",\"last_workflow_confidence\":");
    try json_writer.writeString(writer, s.last_workflow_confidence);
    try writer.writeAll(",\"final_outcome\":");
    try json_writer.writeString(writer, @tagName(s.final_outcome));
    try writer.writeByte('}');
}

fn writeAutoloopOutcomePayload(
    writer: *std.Io.Writer,
    outcome: AutoloopOutcome,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"verdict\":");
    try json_writer.writeString(writer, outcome.verdict.asString());
    try writer.writeAll(",\"iterations\":");
    try writer.print("{d}", .{outcome.iterations});
    try writer.writeAll(",\"goals_met\":[");
    for (outcome.goals_met, 0..) |goal, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, goal);
    }
    try writer.writeAll("],\"goals_unmet\":[");
    for (outcome.goals_unmet, 0..) |goal, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, goal);
    }
    try writer.writeByte(']');
    if (outcome.final_patch_hash) |hash| {
        try writer.writeAll(",\"final_patch_hash\":\"");
        const hex = std.fmt.bytesToHex(hash, .lower);
        try writer.writeAll(&hex);
        try writer.writeByte('"');
    }
    try writer.writeByte('}');
}

fn writeDisplayPayload(
    writer: *std.Io.Writer,
    message: DisplayMessage,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"llm_text\":");
    try json_writer.writeString(writer, message.llm_text);
    try writer.writeAll(",\"body\":");
    try json_writer.writeString(writer, message.llm_text);
    if (message.ui_payload) |payload| {
        try writer.writeAll(",\"ui_payload\":");
        try ui_payload.writeJson(writer, payload);
    }
    try writer.writeByte('}');
}

pub fn readMeta(allocator: std.mem.Allocator, meta_path: []const u8) !Meta {
    const bytes = try zts.file_io.readFile(allocator, meta_path, 1 * 1024 * 1024);
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return error.InvalidMetaJson;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidMetaJson;
    const obj = parsed.value.object;

    const version_val = obj.get("schema_version") orelse return error.InvalidMetaJson;
    if (version_val != .integer or version_val.integer < 0) return error.InvalidMetaJson;
    const version: u32 = std.math.cast(u32, version_val.integer) orelse return error.SchemaVersionUnsupported;
    if (version != meta_schema_version) return error.SchemaVersionUnsupported;

    const session_id = getRequiredString(obj, "session_id") orelse return error.InvalidMetaJson;
    const workspace_realpath = getRequiredString(obj, "workspace_realpath") orelse return error.InvalidMetaJson;
    const created_at = obj.get("created_at_unix_ms") orelse return error.InvalidMetaJson;
    if (created_at != .integer) return error.InvalidMetaJson;

    const session_id_copy = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_id_copy);
    const workspace_copy = try allocator.dupe(u8, workspace_realpath);
    errdefer allocator.free(workspace_copy);

    const parent_id = if (getRequiredString(obj, "parent_id")) |pid|
        try allocator.dupe(u8, pid)
    else
        null;
    errdefer if (parent_id) |pid| allocator.free(pid);

    const policy_hash_value = getRequiredString(obj, "policy_hash") orelse
        return error.InvalidMetaJson;
    if (!isLowerHexDigest(policy_hash_value)) return error.InvalidMetaJson;
    const policy_hash = try allocator.dupe(u8, policy_hash_value);
    errdefer allocator.free(policy_hash);

    const protocol_hash_value = getRequiredString(obj, "protocol_hash") orelse
        return error.InvalidMetaJson;
    if (!isLowerHexDigest(protocol_hash_value)) return error.InvalidMetaJson;
    const protocol_hash = try allocator.dupe(u8, protocol_hash_value);
    errdefer allocator.free(protocol_hash);

    const approval_policy = if (getRequiredString(obj, "approval_policy")) |ap|
        try allocator.dupe(u8, ap)
    else
        null;
    errdefer if (approval_policy) |ap| allocator.free(ap);

    const provider = if (getRequiredString(obj, "provider")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (provider) |value| allocator.free(value);

    const model = if (getRequiredString(obj, "model")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (model) |value| allocator.free(value);

    return .{
        .schema_version = version,
        .session_id = session_id_copy,
        .workspace_realpath = workspace_copy,
        .created_at_unix_ms = created_at.integer,
        .parent_id = parent_id,
        .policy_hash = policy_hash,
        .protocol_hash = protocol_hash,
        .approval_policy = approval_policy,
        .provider = provider,
        .model = model,
    };
}

pub fn writeMeta(allocator: std.mem.Allocator, meta_path: []const u8, meta: Meta) !void {
    if (!isLowerHexDigest(meta.policy_hash)) return error.InvalidPolicyHash;
    if (!isLowerHexDigest(meta.protocol_hash)) return error.InvalidProtocolHash;
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();

    var stream: std.json.Stringify = .{
        .writer = buf.writer(),
        .options = .{ .whitespace = .indent_2 },
    };
    try stream.beginObject();
    try stream.objectField("schema_version");
    try stream.write(meta_schema_version);
    try stream.objectField("session_id");
    try stream.write(meta.session_id);
    try stream.objectField("workspace_realpath");
    try stream.write(meta.workspace_realpath);
    try stream.objectField("created_at_unix_ms");
    try stream.write(meta.created_at_unix_ms);
    if (meta.parent_id) |parent_id| {
        try stream.objectField("parent_id");
        try stream.write(parent_id);
    }
    try stream.objectField("policy_hash");
    try stream.write(meta.policy_hash);
    try stream.objectField("protocol_hash");
    try stream.write(meta.protocol_hash);
    if (meta.approval_policy) |ap| {
        try stream.objectField("approval_policy");
        try stream.write(ap);
    }
    if (meta.provider) |provider| {
        try stream.objectField("provider");
        try stream.write(provider);
    }
    if (meta.model) |model| {
        try stream.objectField("model");
        try stream.write(model);
    }
    try stream.endObject();
    try buf.writer().writeByte('\n');

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{meta_path});
    defer allocator.free(tmp_path);
    try zts.file_io.writeFile(allocator, tmp_path, buf.written());

    const old_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(old_z);
    const new_z = try allocator.dupeZ(u8, meta_path);
    defer allocator.free(new_z);
    if (std.c.rename(old_z, new_z) != 0) return error.WriteFailure;
}

pub fn freeMeta(allocator: std.mem.Allocator, meta: *Meta) void {
    allocator.free(meta.session_id);
    allocator.free(meta.workspace_realpath);
    if (meta.parent_id) |parent_id| allocator.free(parent_id);
    allocator.free(meta.policy_hash);
    allocator.free(meta.protocol_hash);
    if (meta.approval_policy) |ap| allocator.free(ap);
    if (meta.provider) |provider| allocator.free(provider);
    if (meta.model) |model| allocator.free(model);
    meta.* = .{
        .schema_version = meta_schema_version,
        .session_id = &.{},
        .workspace_realpath = &.{},
        .created_at_unix_ms = 0,
        .parent_id = null,
        .policy_hash = &.{},
        .protocol_hash = &.{},
        .approval_policy = null,
    };
}

fn isLowerHexDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

const testing = std.testing;
const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;

fn initTmp(allocator: std.mem.Allocator) !IsolatedTmp {
    return IsolatedTmp.init(allocator, "events");
}

fn readWhole(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try zts.file_io.readFile(allocator, path, 1 * 1024 * 1024);
}

test "appendEntryEvent frames a v3 user_text event with stable identity" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEntryEvent(allocator, path, 1, null, .{ .user_text = "hello world" });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"v\":3") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"entry_id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"user_text\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"hello world\"") != null);
}

test "model_text JSON projection uses the documented v3 envelope" {
    const allocator = testing.allocator;
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try writeEventLine(buf.writer(), .{ .model_text = "hello" });

    const line = std.mem.trim(u8, buf.written(), "\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 3), obj.get("v").?.integer);
    try testing.expectEqualStrings("model_text", obj.get("k").?.string);
    // `d` is a bare string for model_text (not an object), as documented.
    try testing.expectEqualStrings("hello", obj.get("d").?.string);
}

test "appendEvent serializes tool_result with llm_text body alias and ui_payload" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEntryEvent(allocator, path, 1, null, .{ .tool_result = .{
        .tool_use_id = "toolu_1",
        .tool_name = "zts_expert_verify_paths",
        .ok = false,
        .llm_text = "{\"ok\":false}",
        .ui_payload = .{ .plain_text = @constCast("fallback") },
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"llm_text\":\"{\\\"ok\\\":false}\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"body\":\"{\\\"ok\\\":false}\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"ui_payload\":{\"kind\":\"plain_text\"") != null);
}

test "appendEvent serializes verified_patch with ui_payload" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    var patch: ui_payload.UiPayload = .{ .verified_patch = .{
        .file = try allocator.dupe(u8, "handler.ts"),
        .policy_hash = try allocator.dupe(u8, "a" ** 64),
        .applied_at_unix_ms = 42,
        .stats = .{ .total = 0, .new = 0, .preexisting = 0 },
        .before = null,
        .after = try allocator.dupe(u8, "export default {}"),
        .unified_diff = try allocator.alloc(u8, 0),
        .hunks = try allocator.alloc(ui_payload.DiffHunk, 0),
        .violations = try allocator.alloc(ui_payload.ViolationDeltaItem, 0),
        .before_properties = null,
        .after_properties = null,
        .prove = null,
        .system = null,
        .rule_citations = try allocator.alloc([]u8, 0),
        .post_apply_ok = true,
        .post_apply_summary = null,
    } };
    defer patch.deinit(allocator);

    try appendEntryEvent(allocator, path, 1, null, .{ .verified_patch = .{
        .llm_text = "verified: handler.ts",
        .ui_payload = patch,
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"verified_patch\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"ui_payload\":{\"kind\":\"verified_patch\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"policy_hash\":\"aaaaa") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"post_apply_ok\":true") != null);
}

test "appendEvent serializes proof_card as a display object" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEntryEvent(allocator, path, 1, null, .{ .proof_card = .{
        .llm_text = "{\"summary\":{\"total\":0}}",
        .ui_payload = null,
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"proof_card\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"llm_text\":\"{\\\"summary\\\":{\\\"total\\\":0}}\"") != null);
}

test "writeMeta/readMeta round-trip current schema" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "meta.json");
    defer allocator.free(path);

    try writeMeta(allocator, path, .{
        .session_id = "sid",
        .workspace_realpath = "/tmp/ws",
        .created_at_unix_ms = 123,
        .parent_id = "parent",
        .policy_hash = "a" ** 64,
        .protocol_hash = "b" ** 64,
        .provider = "local",
        .model = "LiquidAI/LFM2.5-2.6B-MLX-8bit",
    });

    var meta = try readMeta(allocator, path);
    defer freeMeta(allocator, &meta);

    try testing.expectEqual(@as(u32, meta_schema_version), meta.schema_version);
    try testing.expectEqualStrings("sid", meta.session_id);
    try testing.expectEqualStrings("/tmp/ws", meta.workspace_realpath);
    try testing.expectEqual(@as(i64, 123), meta.created_at_unix_ms);
    try testing.expectEqualStrings("parent", meta.parent_id.?);
    try testing.expectEqualStrings("b" ** 64, meta.protocol_hash);
    try testing.expectEqualStrings("local", meta.provider.?);
    try testing.expectEqualStrings("LiquidAI/LFM2.5-2.6B-MLX-8bit", meta.model.?);
}

test "current metadata requires canonical policy and protocol identities" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "meta.json");
    defer allocator.free(path);

    try zts.file_io.writeFile(
        allocator,
        path,
        \\{"schema_version":4,"session_id":"sid","workspace_realpath":"/tmp/ws","created_at_unix_ms":123,"policy_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        ,
    );
    try testing.expectError(error.InvalidMetaJson, readMeta(allocator, path));

    try testing.expectError(error.InvalidProtocolHash, writeMeta(allocator, path, .{
        .session_id = "sid",
        .workspace_realpath = "/tmp/ws",
        .created_at_unix_ms = 123,
        .policy_hash = "a" ** 64,
        .protocol_hash = "NOT-A-DIGEST",
    }));
    try testing.expectError(error.InvalidPolicyHash, writeMeta(allocator, path, .{
        .session_id = "sid",
        .workspace_realpath = "/tmp/ws",
        .created_at_unix_ms = 123,
        .policy_hash = "A" ** 64,
        .protocol_hash = "b" ** 64,
    }));
}

test "appendEvent serializes autoloop_outcome with goals and final hash" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*b, i| b.* = @intCast(i);

    try appendEvent(allocator, path, .{ .autoloop_outcome = .{
        .verdict = .achieved,
        .final_patch_hash = hash,
        .goals_met = &.{ "retry_safe", "pure" },
        .goals_unmet = &.{},
        .iterations = 3,
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"autoloop_outcome\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"verdict\":\"achieved\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"iterations\":3") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"retry_safe\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"goals_unmet\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"final_patch_hash\":\"000102") != null);
}

test "appendEvent omits final_patch_hash when null" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .autoloop_outcome = .{
        .verdict = .exhausted_iters,
        .goals_met = &.{},
        .goals_unmet = &.{"retry_safe"},
        .iterations = 8,
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"verdict\":\"exhausted_iters\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "final_patch_hash") == null);
}

test "readMeta rejects older metadata schema versions after the protocol cutover" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "meta.json");
    defer allocator.free(path);

    try zts.file_io.writeFile(
        allocator,
        path,
        \\{"schema_version":1,"session_id":"sid","workspace_realpath":"/tmp/ws","created_at_unix_ms":123}
        ,
    );

    try testing.expectError(error.SchemaVersionUnsupported, readMeta(allocator, path));
}

test "appendEvent serializes turn_end with reason" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_roundtrips } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"turn_end\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"reason\":\"budget_roundtrips\"") != null);
}

test "appendEvent serializes a wall-clock timeout end reason distinctly" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_timeout } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"reason\":\"budget_timeout\"") != null);
    // Must not collapse into the round-trip bucket the scorecard reads.
    try testing.expect(std.mem.indexOf(u8, raw, "budget_roundtrips") == null);
}

test "appendEvent removes an incomplete crash tail before the next frame" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    const fd = try zts.file_io.openAppend(allocator, path);
    // A short binary frame can coincidentally end in a newline byte. Recovery
    // must validate the frame structure rather than trust that final byte.
    _ = std.c.write(fd, "ZTE3partial\n".ptr, "ZTE3partial\n".len);
    std.Io.Threaded.closeFd(fd);
    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_timeout } });

    var reader = try Reader.open(allocator, path);
    defer reader.deinit();
    const first = (try reader.next()) orelse return error.TestExpectedFirstFrame;
    defer allocator.free(first);
    const second = (try reader.next()) orelse return error.TestExpectedSecondFrame;
    defer allocator.free(second);
    try testing.expect((try reader.next()) == null);
    try testing.expect(std.mem.indexOf(u8, first, "\"approved\"") != null);
    try testing.expect(std.mem.indexOf(u8, second, "\"budget_timeout\"") != null);
}

test "appendEvent rolls back a partially written payload before appending" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_roundtrips } });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    {
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0);
        defer std.Io.Threaded.closeFd(fd);
        const size = (try zts.file_io.fstatFd(fd)).size;
        if (std.c.ftruncate(fd, @intCast(size - 5)) != 0) return error.TestTruncateFailed;
    }

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_timeout } });
    var reader = try Reader.open(allocator, path);
    defer reader.deinit();
    const first = (try reader.next()) orelse return error.TestExpectedFirstFrame;
    defer allocator.free(first);
    const second = (try reader.next()) orelse return error.TestExpectedSecondFrame;
    defer allocator.free(second);
    try testing.expect((try reader.next()) == null);
    try testing.expect(std.mem.indexOf(u8, first, "\"approved\"") != null);
    try testing.expect(std.mem.indexOf(u8, second, "\"budget_timeout\"") != null);
}

test "appendEvent rejects a complete checksum-corrupt predecessor" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    const original = try readWhole(allocator, path);
    defer allocator.free(original);
    const corrupt_at = std.mem.indexOf(u8, original, "approved") orelse return error.TestExpectedPayload;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    {
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0);
        defer std.Io.Threaded.closeFd(fd);
        const replacement = "x";
        _ = std.c.pwrite(fd, replacement.ptr, replacement.len, @intCast(corrupt_at));
    }

    try testing.expectError(
        error.CorruptEventsLog,
        appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_timeout } }),
    );
    const after = try readWhole(allocator, path);
    defer allocator.free(after);
    try testing.expectEqual(original.len, after.len);
}

test "JournalWriter validates once and excludes a second session writer" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);
    try zts.file_io.writeFile(allocator, path, "");

    {
        var writer = try JournalWriter.open(allocator, path);
        defer writer.deinit();
        try writer.appendEvent(allocator, .{ .turn_end = .{ .reason = .approved } });
        try writer.appendEvent(allocator, .{ .turn_end = .{ .reason = .budget_timeout } });
        try testing.expectError(error.SessionAlreadyActive, JournalWriter.open(allocator, path));
        try testing.expectError(
            error.SessionAlreadyActive,
            appendEvent(allocator, path, .{ .turn_end = .{ .reason = .error_exit } }),
        );
    }

    var reopened = try JournalWriter.open(allocator, path);
    reopened.deinit();
    var reader = try Reader.open(allocator, path);
    defer reader.deinit();
    var count: usize = 0;
    while (try reader.next()) |payload| {
        allocator.free(payload);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "JournalWriter duplicate transfers exclusion without unlocking aliases" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);
    try zts.file_io.writeFile(allocator, path, "");

    var original = try JournalWriter.open(allocator, path);
    var original_owned = true;
    defer if (original_owned) original.deinit();
    var temporary_alias = try original.duplicate();
    temporary_alias.deinit();
    try testing.expectError(error.SessionAlreadyActive, JournalWriter.open(allocator, path));

    var successor = try original.duplicate();
    var successor_owned = true;
    defer if (successor_owned) successor.deinit();
    try JournalWriter.transferLockOwnership(&original, &successor);
    original.deinit();
    original_owned = false;
    try testing.expectError(error.SessionAlreadyActive, JournalWriter.open(allocator, path));

    successor.deinit();
    successor_owned = false;
    var reopened = try JournalWriter.open(allocator, path);
    reopened.deinit();
}

test "JournalWriter rejects duplicate entry identities without poisoning the journal" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    var writer = try JournalWriter.open(allocator, path);
    defer writer.deinit();
    try writer.appendEntryEvent(allocator, 1, null, .{ .user_text = "first" });
    try testing.expectError(
        error.CorruptEventsLog,
        writer.appendEntryEvent(allocator, 1, null, .{ .model_text = "duplicate" }),
    );
    try testing.expect(!writer.poisoned);
    try writer.appendEntryEvent(allocator, 2, null, .{ .model_text = "second" });
}

test "appendEvent rejects corruption in a complete non-final frame" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .budget_timeout } });
    const original = try readWhole(allocator, path);
    defer allocator.free(original);
    const corrupt_at = std.mem.indexOf(u8, original, "approved") orelse return error.TestExpectedPayload;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    {
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDWR }, 0);
        defer std.Io.Threaded.closeFd(fd);
        _ = std.c.pwrite(fd, "x".ptr, 1, @intCast(corrupt_at));
    }

    try testing.expectError(
        error.CorruptEventsLog,
        appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } }),
    );
}

test "appendEvent rejects a checksummed malformed envelope" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);
    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } });
    const original = try readWhole(allocator, path);
    defer allocator.free(original);
    const payload_len = std.mem.readInt(u64, original[frame_magic.len .. frame_magic.len + @sizeOf(u64)], .big);
    const payload = original[frame_header_len .. frame_header_len + @as(usize, @intCast(payload_len))];
    const kind_at = std.mem.indexOf(u8, payload, "turn_end") orelse return error.TestExpectedPayload;
    var malformed = try allocator.dupe(u8, original);
    defer allocator.free(malformed);
    @memcpy(malformed[frame_header_len + kind_at ..][0..8], "nonsense");
    const malformed_payload = malformed[frame_header_len .. frame_header_len + @as(usize, @intCast(payload_len))];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(malformed_payload, &digest, .{});
    @memcpy(malformed[frame_magic.len + @sizeOf(u64) .. frame_header_len], &digest);
    try zts.file_io.writeFile(allocator, path, malformed);

    try testing.expectError(
        error.CorruptEventsLog,
        appendEvent(allocator, path, .{ .turn_end = .{ .reason = .approved } }),
    );
}

test "appendEvent serializes session_summary with metrics" {
    const allocator = testing.allocator;
    var tmp = try initTmp(allocator);
    defer tmp.cleanup(allocator);

    const path = try tmp.childPath(allocator, "events.jsonl");
    defer allocator.free(path);

    try appendEvent(allocator, path, .{ .session_summary = .{
        .turn_count = 2,
        .total_roundtrips = 5,
        .verified_patch_count = 1,
        .reached_proof = true,
        .round_trips_to_first_green = 4,
        .proven_properties = 12,
        .tracked_properties = 16,
        .workflow_hint_count = 2,
        .high_confidence_workflow_hint_count = 1,
        .raw_first_draft_veto_pass_count = 1,
        .first_attempt_green_count = 2,
        .veto_retry_count = 3,
        .tool_call_count = 5,
        .compiler_authored_apply_count = 2,
        .last_workflow_kind = "route_add",
        .last_workflow_confidence = "high",
        .final_outcome = .approved,
    } });

    const raw = try readWhole(allocator, path);
    defer allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "\"k\":\"session_summary\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"turn_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"verified_patch_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"reached_proof\":true") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"round_trips_to_first_green\":4") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"proven_path_ratio\":0.750") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"workflow_hint_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"raw_first_draft_veto_pass_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"first_attempt_green_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"veto_retry_count\":3") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"tool_call_count\":5") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"compiler_authored_apply_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"last_workflow_kind\":\"route_add\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"last_workflow_confidence\":\"high\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"final_outcome\":\"approved\"") != null);
}

test "SessionSummary.provenPathRatio is zero with no tracked properties" {
    const empty: SessionSummary = .{};
    try testing.expectEqual(@as(f32, 0), empty.provenPathRatio());
}
