//! Durable, bounded metadata records for agent turns.
//!
//! The server owns one recorder for its full lifetime. Each admitted turn
//! reserves enough ceiling space for one maximum-size terminal record. All
//! writes, reservations, and health changes use the same mutex.

const std = @import("std");
const builtin = @import("builtin");

pub const format_version: u8 = 1;
pub const max_record_bytes: u64 = 512;
pub const TurnId = [16]u8;

pub const RecordKind = enum {
    admit,
    pre,
    post,
    terminal,
};

pub const Effect = enum {
    provider_fetch,
    tool_call,
};

pub const AuthorizationDecision = enum {
    allowed,
    denied,
};

pub const OutcomeClass = enum {
    not_started,
    outcome_unknown,
    completed,
};

pub const TerminalTag = enum {
    completed,
    failed,
    deadline_exceeded,
    budget_exhausted,
    recorder_unavailable,
    outcome_unknown,
    tool_denied,
    tool_failed,

    pub fn isLatchTag(self: TerminalTag) bool {
        return switch (self) {
            .completed, .failed => false,
            .deadline_exceeded,
            .budget_exhausted,
            .recorder_unavailable,
            .outcome_unknown,
            .tool_denied,
            .tool_failed,
            => true,
        };
    }
};

/// A record contains metadata only. It has no field for a prompt, argument,
/// result, header, URL, path, or credential.
pub const Record = struct {
    turn_id: TurnId,
    sequence: u32,
    kind: RecordKind,
    monotonic_ns: i128,

    effect: ?Effect = null,
    round: ?u32 = null,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    authorization: ?AuthorizationDecision = null,
    outcome_class: ?OutcomeClass = null,
    head_received: ?bool = null,
    status: ?u16 = null,
    terminal_tag: ?TerminalTag = null,

    agent_name: ?[]const u8 = null,
    catalog_digest: ?[]const u8 = null,
    runtime_policy_hash: ?[]const u8 = null,
    wall_time_unix_ns: ?i128 = null,
};

pub const RecorderError = error{
    InvalidRecord,
    RecordTooLarge,
    CeilingExceeded,
    DuplicateReservation,
    MissingReservation,
    RecorderUnhealthy,
    RecorderWriteFailed,
    RecorderFlushFailed,
    MakeDirectoryFailed,
    FileOpenFailed,
    FileLockFailed,
    DirectorySyncFailed,
    ClockUnavailable,
    NotMemoryRecorder,
};

const Mutex = struct {
    inner: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(std.Options.debug_io);
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock(std.Options.debug_io);
    }
};

const FileSink = struct {
    fd: std.c.fd_t,
    path: []u8,
};

const MemorySink = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    fail_write_after: ?u32 = null,
    fail_next_flush: bool = false,
};

const Sink = union(enum) {
    file: FileSink,
    memory: MemorySink,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    mutex: Mutex = .{},
    sink: Sink,
    ceiling: u64,
    bytes_written: u64 = 0,
    reserved_bytes: u64 = 0,
    healthy: bool = true,
    reservations: std.AutoHashMapUnmanaged(TurnId, void) = .empty,

    pub fn initMemory(allocator: std.mem.Allocator, ceiling: u64) Recorder {
        return .{
            .allocator = allocator,
            .sink = .{ .memory = .{} },
            .ceiling = ceiling,
        };
    }

    pub fn initFile(allocator: std.mem.Allocator, directory: []const u8, ceiling: u64) !Recorder {
        return initFileWithSync(allocator, directory, ceiling, syncDirectory);
    }

    fn initFileWithSync(
        allocator: std.mem.Allocator,
        directory: []const u8,
        ceiling: u64,
        comptime directory_sync: fn (std.mem.Allocator, []const u8) RecorderError!void,
    ) !Recorder {
        if (directory.len == 0) return error.MakeDirectoryFailed;
        try makePath(allocator, directory);

        const start_unix_ns = try realtimeNowNs();
        const file_name = try std.fmt.allocPrint(
            allocator,
            "turns-{d}-{d}.jsonl",
            .{ start_unix_ns, std.c.getpid() },
        );
        defer allocator.free(file_name);

        const path = try std.fs.path.join(allocator, &.{ directory, file_name });
        errdefer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            path_z,
            .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .EXCL = true,
                .APPEND = true,
            },
            0o600,
        ) catch return error.FileOpenFailed;
        errdefer std.Io.Threaded.closeFd(fd);
        errdefer _ = std.c.unlink(path_z);

        if (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
            return error.FileLockFailed;
        }

        try directory_sync(allocator, directory);

        return .{
            .allocator = allocator,
            .sink = .{ .file = .{ .fd = fd, .path = path } },
            .ceiling = ceiling,
        };
    }

    pub fn deinit(self: *Recorder) void {
        switch (self.sink) {
            .file => |file| {
                std.Io.Threaded.closeFd(file.fd);
                self.allocator.free(file.path);
            },
            .memory => |*memory| memory.bytes.deinit(self.allocator),
        }
        self.reservations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isHealthy(self: *Recorder) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.healthy;
    }

    pub fn filePath(self: *const Recorder) ?[]const u8 {
        return switch (self.sink) {
            .file => |file| file.path,
            .memory => null,
        };
    }

    /// Write the admission record and reserve one maximum-size terminal line.
    /// A ceiling refusal is expected capacity behavior and leaves health set.
    /// Serialization and reservation-allocation failures make admission
    /// unavailable for the process and latch the recorder unhealthy.
    pub fn admit(self: *Recorder, record: Record) !void {
        var line_buf: [max_record_bytes]u8 = undefined;
        const line = serialize(record, &line_buf) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.healthy = false;
            return err;
        };
        if (record.kind != .admit) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.healthy = false;
            return error.InvalidRecord;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireHealthyLocked();
        if (self.reservations.contains(record.turn_id)) return error.DuplicateReservation;
        if (!fits(self.bytes_written, self.reserved_bytes, line.len, max_record_bytes, self.ceiling)) {
            return error.CeilingExceeded;
        }

        self.reservations.put(self.allocator, record.turn_id, {}) catch |err| {
            self.healthy = false;
            return err;
        };
        errdefer _ = self.reservations.remove(record.turn_id);
        try self.persistLocked(line);
        self.bytes_written += @intCast(line.len);
        self.reserved_bytes += max_record_bytes;
    }

    /// Write a non-terminal record without consuming live turn reservations.
    pub fn append(self: *Recorder, record: Record) !void {
        return self.appendRecord(record, false);
    }

    fn appendRecord(self: *Recorder, record: Record, unhealthy_on_failure: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        errdefer if (unhealthy_on_failure) {
            self.healthy = false;
        };

        if (record.kind == .admit or record.kind == .terminal) return error.InvalidRecord;
        var line_buf: [max_record_bytes]u8 = undefined;
        const line = try serialize(record, &line_buf);

        try self.requireHealthyLocked();
        if (!fits(self.bytes_written, self.reserved_bytes, line.len, 0, self.ceiling)) {
            return error.CeilingExceeded;
        }

        try self.persistLocked(line);
        self.bytes_written += @intCast(line.len);
    }

    /// Write a terminal record from the reservation made for this turn.
    pub fn terminal(self: *Recorder, record: Record) !void {
        if (record.kind != .terminal) return error.InvalidRecord;
        var line_buf: [max_record_bytes]u8 = undefined;
        const line = try serialize(record, &line_buf);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireHealthyLocked();
        if (!self.reservations.contains(record.turn_id)) return error.MissingReservation;

        try self.persistLocked(line);
        self.bytes_written += @intCast(line.len);
        self.reserved_bytes -= max_record_bytes;
        _ = self.reservations.remove(record.turn_id);
    }

    pub fn appendPre(
        self: *Recorder,
        turn_id: TurnId,
        sequence: u32,
        round: u32,
        now_ns: i128,
    ) !void {
        return self.append(.{
            .turn_id = turn_id,
            .sequence = sequence,
            .kind = .pre,
            .monotonic_ns = now_ns,
            .effect = .provider_fetch,
            .round = round,
            .authorization = .allowed,
        });
    }

    pub fn appendPost(
        self: *Recorder,
        turn_id: TurnId,
        sequence: u32,
        round: u32,
        outcome_class: OutcomeClass,
        head_received: bool,
        status: ?u16,
        now_ns: i128,
    ) !void {
        return self.appendRecord(.{
            .turn_id = turn_id,
            .sequence = sequence,
            .kind = .post,
            .monotonic_ns = now_ns,
            .effect = .provider_fetch,
            .round = round,
            .outcome_class = outcome_class,
            .head_received = head_received,
            .status = status,
        }, true);
    }

    pub fn appendToolPre(
        self: *Recorder,
        turn_id: TurnId,
        sequence: u32,
        round: u32,
        call_id: []const u8,
        tool_name: []const u8,
        now_ns: i128,
    ) !void {
        return self.append(.{
            .turn_id = turn_id,
            .sequence = sequence,
            .kind = .pre,
            .monotonic_ns = now_ns,
            .effect = .tool_call,
            .round = round,
            .call_id = call_id,
            .tool_name = tool_name,
            .authorization = .allowed,
        });
    }

    pub fn appendToolPost(
        self: *Recorder,
        turn_id: TurnId,
        sequence: u32,
        round: u32,
        call_id: []const u8,
        outcome_class: OutcomeClass,
        head_received: bool,
        status: ?u16,
        now_ns: i128,
    ) !void {
        return self.appendRecord(.{
            .turn_id = turn_id,
            .sequence = sequence,
            .kind = .post,
            .monotonic_ns = now_ns,
            .effect = .tool_call,
            .round = round,
            .call_id = call_id,
            .outcome_class = outcome_class,
            .head_received = head_received,
            .status = status,
        }, true);
    }

    /// Return replay bytes. The slice is stable until the next recorder write.
    pub fn memoryBytes(self: *Recorder) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.sink) {
            .memory => |*memory| memory.bytes.items,
            .file => error.NotMemoryRecorder,
        };
    }

    pub fn failNextMemoryWrite(self: *Recorder) !void {
        return self.failMemoryWriteAfter(0);
    }

    /// Inject one memory write failure after `successful_writes` more writes.
    /// This supports deterministic pre/post failure tests without file I/O.
    pub fn failMemoryWriteAfter(self: *Recorder, successful_writes: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.sink) {
            .memory => |*memory| memory.fail_write_after = successful_writes,
            .file => return error.NotMemoryRecorder,
        }
    }

    pub fn failNextMemoryFlush(self: *Recorder) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.sink) {
            .memory => |*memory| memory.fail_next_flush = true,
            .file => return error.NotMemoryRecorder,
        }
    }

    fn requireHealthyLocked(self: *const Recorder) RecorderError!void {
        if (!self.healthy) return error.RecorderUnhealthy;
    }

    fn persistLocked(self: *Recorder, line: []const u8) RecorderError!void {
        self.writeLocked(line) catch {
            self.healthy = false;
            return error.RecorderWriteFailed;
        };
        self.flushLocked() catch {
            self.healthy = false;
            return error.RecorderFlushFailed;
        };
    }

    fn writeLocked(self: *Recorder, line: []const u8) !void {
        switch (self.sink) {
            .file => |file| try writeAllChecked(file.fd, line),
            .memory => |*memory| {
                if (memory.fail_write_after) |remaining| {
                    if (remaining == 0) {
                        memory.fail_write_after = null;
                        return error.InjectedWriteFailure;
                    }
                    memory.fail_write_after = remaining - 1;
                }
                try memory.bytes.appendSlice(self.allocator, line);
            },
        }
    }

    fn flushLocked(self: *Recorder) !void {
        switch (self.sink) {
            .file => |file| try durableSync(file.fd),
            .memory => |*memory| {
                if (memory.fail_next_flush) {
                    memory.fail_next_flush = false;
                    return error.InjectedFlushFailure;
                }
            },
        }
    }
};

fn fits(written: u64, reserved: u64, line_len: usize, extra_reservation: u64, ceiling: u64) bool {
    const line_u64: u64 = @intCast(line_len);
    const used = std.math.add(u64, written, reserved) catch return false;
    const with_line = std.math.add(u64, used, line_u64) catch return false;
    const total = std.math.add(u64, with_line, extra_reservation) catch return false;
    return total <= ceiling;
}

fn validateRecord(record: Record) RecorderError!void {
    for ([_]?[]const u8{
        record.call_id,
        record.tool_name,
        record.agent_name,
        record.catalog_digest,
        record.runtime_policy_hash,
    }) |value| {
        if (value) |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRecord;
        }
    }

    const has_admit_fields = record.agent_name != null or
        record.catalog_digest != null or
        record.runtime_policy_hash != null or
        record.wall_time_unix_ns != null;
    const has_effect_fields = record.effect != null or record.round != null or
        record.call_id != null or record.tool_name != null or record.authorization != null or
        record.outcome_class != null or record.head_received != null or
        record.status != null;

    switch (record.kind) {
        .admit => {
            if (record.agent_name == null or record.catalog_digest == null or
                record.runtime_policy_hash == null or record.wall_time_unix_ns == null or
                has_effect_fields or record.terminal_tag != null)
            {
                return error.InvalidRecord;
            }
        },
        .pre => {
            if (record.effect == null or record.round == null or record.authorization == null or
                record.outcome_class != null or record.head_received != null or
                record.status != null or record.terminal_tag != null or has_admit_fields)
            {
                return error.InvalidRecord;
            }
            try validateCallIdentity(record.effect.?, record.call_id);
            if ((record.effect.? == .tool_call) != (record.tool_name != null)) return error.InvalidRecord;
        },
        .post => {
            if (record.effect == null or record.round == null or
                record.outcome_class == null or record.head_received == null or
                record.tool_name != null or record.authorization != null or record.terminal_tag != null or has_admit_fields)
            {
                return error.InvalidRecord;
            }
            try validateCallIdentity(record.effect.?, record.call_id);
        },
        .terminal => {
            if (record.terminal_tag == null or has_effect_fields or has_admit_fields) {
                return error.InvalidRecord;
            }
        },
    }
}

fn validateCallIdentity(effect: Effect, call_id: ?[]const u8) RecorderError!void {
    switch (effect) {
        .provider_fetch => if (call_id != null) return error.InvalidRecord,
        .tool_call => if (call_id == null) return error.InvalidRecord,
    }
}

fn serialize(record: Record, out: *[max_record_bytes]u8) RecorderError![]const u8 {
    try validateRecord(record);
    var writer = std.Io.Writer.fixed(out);
    writeRecordJson(&writer, record) catch return error.RecordTooLarge;
    if (writer.end > max_record_bytes) return error.RecordTooLarge;
    return out[0..writer.end];
}

fn writeRecordJson(writer: *std.Io.Writer, record: Record) !void {
    const turn_hex = std.fmt.bytesToHex(record.turn_id, .lower);
    try writer.print(
        "{{\"version\":{d},\"turnId\":\"{s}\",\"sequence\":{d},\"kind\":\"{s}\",\"monotonicNs\":{d}",
        .{ format_version, &turn_hex, record.sequence, @tagName(record.kind), record.monotonic_ns },
    );

    if (record.effect) |effect| try writeEnumField(writer, "effect", @tagName(effect));
    if (record.round) |round| try writer.print(",\"round\":{d}", .{round});
    if (record.call_id) |call_id| try writeStringField(writer, "callId", call_id);
    if (record.tool_name) |tool_name| try writeStringField(writer, "toolName", tool_name);
    if (record.authorization) |decision| try writeEnumField(writer, "authorization", @tagName(decision));
    if (record.outcome_class) |class| try writeEnumField(writer, "class", @tagName(class));
    if (record.head_received) |received| {
        try writer.writeAll(",\"headReceived\":");
        try writer.writeAll(if (received) "true" else "false");
    }
    if (record.status) |status| try writer.print(",\"status\":{d}", .{status});
    if (record.terminal_tag) |tag| try writeEnumField(writer, "terminalTag", @tagName(tag));
    if (record.agent_name) |name| try writeStringField(writer, "agentName", name);
    if (record.catalog_digest) |digest| try writeStringField(writer, "catalogDigest", digest);
    if (record.runtime_policy_hash) |hash| try writeStringField(writer, "runtimePolicyHash", hash);
    if (record.wall_time_unix_ns) |time| try writer.print(",\"wallTimeUnixNs\":{d}", .{time});
    try writer.writeAll("}\n");
}

fn writeEnumField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print(",\"{s}\":\"{s}\"", .{ name, value });
}

fn writeStringField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print(",\"{s}\":", .{name});
    try writeJsonString(writer, value);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn writeAllChecked(fd: std.c.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const result = std.c.write(fd, remaining.ptr, remaining.len);
        if (result < 0) {
            if (std.posix.errno(result) == .INTR) continue;
            return error.WriteFailed;
        }
        if (result == 0) return error.WriteFailed;
        remaining = remaining[@intCast(result)..];
    }
}

const SyncMethod = enum { fullfsync, fsync };

fn syncMethod(comptime os: std.Target.Os.Tag) SyncMethod {
    return switch (os) {
        .macos => .fullfsync,
        else => .fsync,
    };
}

fn durableSync(fd: std.c.fd_t) !void {
    const result = switch (comptime syncMethod(builtin.os.tag)) {
        .fullfsync => std.c.fcntl(fd, std.c.F.FULLFSYNC, @as(c_int, 0)),
        .fsync => std.c.fsync(fd),
    };
    if (result != 0) return error.FlushFailed;
}

fn realtimeNowNs() RecorderError!i128 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => {},
        else => return error.ClockUnavailable,
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn makePath(allocator: std.mem.Allocator, path: []const u8) RecorderError!void {
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] != '/' and index + 1 != path.len) continue;
        const end = if (path[index] == '/') index else index + 1;
        if (end == 0) continue;
        const component = path[0..end];
        const component_z = allocator.dupeZ(u8, component) catch return error.MakeDirectoryFailed;
        defer allocator.free(component_z);
        switch (std.posix.errno(std.posix.system.mkdir(component_z, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.MakeDirectoryFailed,
        }
    }
}

fn syncDirectory(allocator: std.mem.Allocator, directory: []const u8) RecorderError!void {
    const directory_z = allocator.dupeZ(u8, directory) catch return error.DirectorySyncFailed;
    defer allocator.free(directory_z);
    const fd = std.posix.openatZ(
        std.posix.AT.FDCWD,
        directory_z,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    ) catch return error.DirectorySyncFailed;
    defer std.Io.Threaded.closeFd(fd);
    if (std.c.fsync(fd) != 0) return error.DirectorySyncFailed;
}

fn testTurnId(byte: u8) TurnId {
    return [_]u8{byte} ** 16;
}

fn testAdmit(turn_id: TurnId, sequence: u32) Record {
    return .{
        .turn_id = turn_id,
        .sequence = sequence,
        .kind = .admit,
        .monotonic_ns = 20,
        .agent_name = "assistant",
        .catalog_digest = "catalog-sha256",
        .runtime_policy_hash = "policy-sha256",
        .wall_time_unix_ns = 10,
    };
}

fn testTerminal(turn_id: TurnId, sequence: u32, tag: TerminalTag) Record {
    return .{
        .turn_id = turn_id,
        .sequence = sequence,
        .kind = .terminal,
        .monotonic_ns = 30,
        .terminal_tag = tag,
    };
}

fn expectExactKeys(record: Record, expected: []const []const u8) !void {
    var buffer: [max_record_bytes]u8 = undefined;
    const line = try serialize(record, &buffer);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(expected.len, object.count());
    for (expected) |key| try std.testing.expect(object.get(key) != null);
}

test "memory recorder writes bounded metadata records in sequence" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    const turn_id = testTurnId(0xab);

    try recorder.admit(testAdmit(turn_id, 0));
    try recorder.appendPre(turn_id, 1, 0, 21);
    try recorder.appendPost(turn_id, 2, 0, .completed, true, 200, 22);
    try recorder.terminal(testTerminal(turn_id, 3, .completed));

    const bytes = try recorder.memoryBytes();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(line.len + 1 <= max_record_bytes);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"admit\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"pre\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"class\":\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"terminalTag\":\"completed\"") != null);
}

test "each record kind has its exact parsed metadata fields" {
    const turn_id = testTurnId(12);
    try expectExactKeys(testAdmit(turn_id, 0), &.{
        "version",
        "turnId",
        "sequence",
        "kind",
        "monotonicNs",
        "agentName",
        "catalogDigest",
        "runtimePolicyHash",
        "wallTimeUnixNs",
    });
    try expectExactKeys(.{
        .turn_id = turn_id,
        .sequence = 1,
        .kind = .pre,
        .monotonic_ns = 21,
        .effect = .provider_fetch,
        .round = 0,
        .authorization = .allowed,
    }, &.{
        "version",
        "turnId",
        "sequence",
        "kind",
        "monotonicNs",
        "effect",
        "round",
        "authorization",
    });
    try expectExactKeys(.{
        .turn_id = turn_id,
        .sequence = 2,
        .kind = .post,
        .monotonic_ns = 22,
        .effect = .provider_fetch,
        .round = 0,
        .outcome_class = .completed,
        .head_received = true,
        .status = 200,
    }, &.{
        "version",
        "turnId",
        "sequence",
        "kind",
        "monotonicNs",
        "effect",
        "round",
        "class",
        "headReceived",
        "status",
    });
    try expectExactKeys(testTerminal(turn_id, 3, .completed), &.{
        "version",
        "turnId",
        "sequence",
        "kind",
        "monotonicNs",
        "terminalTag",
    });
}

test "largest accepted metadata values stay within one record" {
    const turn_id = [_]u8{0xff} ** 16;
    var buffer: [max_record_bytes]u8 = undefined;
    const admit_line = try serialize(.{
        .turn_id = turn_id,
        .sequence = std.math.maxInt(u32),
        .kind = .admit,
        .monotonic_ns = std.math.maxInt(i128),
        .agent_name = "a" ** 64,
        .catalog_digest = "b" ** 64,
        .runtime_policy_hash = "c" ** 64,
        .wall_time_unix_ns = std.math.maxInt(i128),
    }, &buffer);
    try std.testing.expect(admit_line.len <= max_record_bytes);

    const post_line = try serialize(.{
        .turn_id = turn_id,
        .sequence = std.math.maxInt(u32),
        .kind = .post,
        .monotonic_ns = std.math.maxInt(i128),
        .effect = .tool_call,
        .round = std.math.maxInt(u32),
        .call_id = "d" ** 64,
        .outcome_class = .outcome_unknown,
        .head_received = true,
        .status = 599,
    }, &buffer);
    try std.testing.expect(post_line.len <= max_record_bytes);

    const pre_line = try serialize(.{
        .turn_id = turn_id,
        .sequence = std.math.maxInt(u32),
        .kind = .pre,
        .monotonic_ns = std.math.maxInt(i128),
        .effect = .tool_call,
        .round = std.math.maxInt(u32),
        .call_id = "d" ** 64,
        .tool_name = "e" ** 64,
        .authorization = .allowed,
    }, &buffer);
    try std.testing.expect(pre_line.len <= max_record_bytes);
}

test "admission reserves terminal capacity and ceiling refusal stays healthy" {
    var sizing = Recorder.initMemory(std.testing.allocator, 4096);
    defer sizing.deinit();
    const turn_id = testTurnId(1);
    try sizing.admit(testAdmit(turn_id, 0));
    const admit_len = (try sizing.memoryBytes()).len;

    var recorder = Recorder.initMemory(std.testing.allocator, @intCast(admit_len + max_record_bytes));
    defer recorder.deinit();
    try recorder.admit(testAdmit(turn_id, 0));
    try std.testing.expectError(
        error.CeilingExceeded,
        recorder.appendPre(turn_id, 1, 0, 21),
    );
    try std.testing.expect(recorder.isHealthy());
    try recorder.terminal(testTerminal(turn_id, 1, .failed));
}

test "admission rejects a reservation that does not fit" {
    var recorder = Recorder.initMemory(std.testing.allocator, max_record_bytes);
    defer recorder.deinit();
    try std.testing.expectError(
        error.CeilingExceeded,
        recorder.admit(testAdmit(testTurnId(2), 0)),
    );
    try std.testing.expect(recorder.isHealthy());
    try std.testing.expectEqual(@as(usize, 0), (try recorder.memoryBytes()).len);
}

test "terminal requires the reservation for its turn" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    const admitted = testTurnId(3);
    const other = testTurnId(4);
    try recorder.admit(testAdmit(admitted, 0));
    try std.testing.expectError(
        error.MissingReservation,
        recorder.terminal(testTerminal(other, 1, .failed)),
    );
    try recorder.terminal(testTerminal(admitted, 1, .completed));
    try std.testing.expectError(
        error.MissingReservation,
        recorder.terminal(testTerminal(admitted, 2, .completed)),
    );
}

test "write failure latches unhealthy" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    try recorder.failNextMemoryWrite();
    try std.testing.expectError(
        error.RecorderWriteFailed,
        recorder.admit(testAdmit(testTurnId(5), 0)),
    );
    try std.testing.expect(!recorder.isHealthy());
    try std.testing.expectError(
        error.RecorderUnhealthy,
        recorder.admit(testAdmit(testTurnId(6), 0)),
    );
}

test "memory sink can fail the post write after a successful pre write" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    const turn_id = testTurnId(11);
    try recorder.admit(testAdmit(turn_id, 0));
    try recorder.failMemoryWriteAfter(1);
    try recorder.appendPre(turn_id, 1, 0, 21);
    try std.testing.expectError(
        error.RecorderWriteFailed,
        recorder.appendPost(turn_id, 2, 0, .completed, true, 200, 22),
    );
    try std.testing.expect(!recorder.isHealthy());
    const bytes = try recorder.memoryBytes();
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"pre\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"post\"") == null);
}

test "post ceiling failure latches unhealthy without using terminal reservation" {
    const turn_id = testTurnId(14);
    var sizing = Recorder.initMemory(std.testing.allocator, 4096);
    defer sizing.deinit();
    try sizing.admit(testAdmit(turn_id, 0));
    try sizing.appendPre(turn_id, 1, 0, 21);
    const through_pre = (try sizing.memoryBytes()).len;

    var recorder = Recorder.initMemory(std.testing.allocator, @intCast(through_pre + max_record_bytes));
    defer recorder.deinit();
    try recorder.admit(testAdmit(turn_id, 0));
    try recorder.appendPre(turn_id, 1, 0, 21);
    try std.testing.expectError(
        error.CeilingExceeded,
        recorder.appendPost(turn_id, 2, 0, .completed, true, 200, 22),
    );
    try std.testing.expect(!recorder.isHealthy());
    const bytes = try recorder.memoryBytes();
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"post\"") == null);
    try std.testing.expectEqual(@as(usize, through_pre), bytes.len);
}

test "flush failure latches unhealthy after bytes may have been written" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    try recorder.failNextMemoryFlush();
    try std.testing.expectError(
        error.RecorderFlushFailed,
        recorder.admit(testAdmit(testTurnId(7), 0)),
    );
    try std.testing.expect(!recorder.isHealthy());
    try std.testing.expect((try recorder.memoryBytes()).len > 0);
}

test "non-admission validation failures keep recorder healthy" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    try std.testing.expectError(error.InvalidRecord, recorder.append(.{
        .turn_id = testTurnId(8),
        .sequence = 0,
        .kind = .pre,
        .monotonic_ns = 20,
        .effect = .provider_fetch,
        .round = 0,
    }));
    try std.testing.expect(recorder.isHealthy());
}

test "admission serialization failure latches unhealthy" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    var large = testAdmit(testTurnId(8), 0);
    large.agent_name = "x" ** max_record_bytes;
    try std.testing.expectError(error.RecordTooLarge, recorder.admit(large));
    try std.testing.expect(!recorder.isHealthy());
}

test "admission reservation allocation failure latches unhealthy" {
    var backing: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var recorder = Recorder.initMemory(fixed.allocator(), 4096);
    defer recorder.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        recorder.admit(testAdmit(testTurnId(13), 0)),
    );
    try std.testing.expect(!recorder.isHealthy());
}

test "metadata strings are JSON escaped" {
    var recorder = Recorder.initMemory(std.testing.allocator, 4096);
    defer recorder.deinit();
    var record = testAdmit(testTurnId(9), 0);
    record.agent_name = "a\"b\\c\n";
    try recorder.admit(record);
    const bytes = try recorder.memoryBytes();
    try std.testing.expect(std.mem.find(u8, bytes, "\"agentName\":\"a\\\"b\\\\c\\n\"") != null);
}

test "file recorder creates a private locked append file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);

    var recorder = try Recorder.initFile(allocator, directory, 4096);
    const path = recorder.filePath().?;
    try std.testing.expect(std.mem.startsWith(u8, std.fs.path.basename(path), "turns-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".jsonl"));
    try recorder.admit(testAdmit(testTurnId(10), 0));
    try recorder.terminal(testTerminal(testTurnId(10), 1, .completed));

    const lock_path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(lock_path_z);
    const lock_fd = try std.posix.openatZ(std.posix.AT.FDCWD, lock_path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer std.Io.Threaded.closeFd(lock_fd);
    try std.testing.expect(std.c.flock(lock_fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0);

    const path_copy = try allocator.dupe(u8, path);
    defer allocator.free(path_copy);
    recorder.deinit();

    const path_z = try allocator.dupeZ(u8, path_copy);
    defer allocator.free(path_z);
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer std.Io.Threaded.closeFd(fd);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_copy, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"kind\":\"terminal\"") != null);
}

test "file recorder creates its directory and requires its sync" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const directory = try std.fs.path.join(allocator, &.{ root, "new", "turns" });
    defer allocator.free(directory);

    var recorder = try Recorder.initFile(allocator, directory, 4096);
    defer recorder.deinit();

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, directory, .{});
    dir.close(std.testing.io);
    try std.testing.expect(recorder.filePath() != null);

    const failing_directory = try std.fs.path.join(allocator, &.{ root, "failed", "turns" });
    defer allocator.free(failing_directory);
    const FailingDirectorySync = struct {
        fn call(_: std.mem.Allocator, _: []const u8) RecorderError!void {
            return error.DirectorySyncFailed;
        }
    };
    try std.testing.expectError(
        error.DirectorySyncFailed,
        Recorder.initFileWithSync(allocator, failing_directory, 4096, FailingDirectorySync.call),
    );

    var failed_dir = try std.Io.Dir.cwd().openDir(std.testing.io, failing_directory, .{ .iterate = true });
    defer failed_dir.close(std.testing.io);
    var entries = failed_dir.iterate();
    try std.testing.expect(try entries.next(std.testing.io) == null);
}

test "durable sync selects fullfsync only on macOS" {
    try std.testing.expectEqual(SyncMethod.fullfsync, syncMethod(.macos));
    try std.testing.expectEqual(SyncMethod.fsync, syncMethod(.linux));
}

test "latch tag census excludes only completed and failed" {
    inline for (std.meta.fields(TerminalTag)) |field| {
        const tag: TerminalTag = @enumFromInt(field.value);
        const expected = tag != .completed and tag != .failed;
        try std.testing.expectEqual(expected, tag.isLatchTag());
    }
}
