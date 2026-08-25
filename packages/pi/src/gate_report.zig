//! Pure aggregator over a gate-record JSONL byte slice.
//!
//! It answers the two questions milestone M0 exists to answer: the measured
//! contract pass rate per tool, and the measured turn volume per niche per day.
//! A malformed line is counted and skipped, never fatal, because a truncated
//! tail is normal for a log that is still being written.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

pub const supported_schema_version: i64 = 1;

pub const ToolStat = struct {
    tool_name: []u8,
    calls: u64 = 0,
    gate_passed: u64 = 0,
    executed_ok: u64 = 0,
};

pub const NicheDay = struct {
    tool_set_hash_hex: []u8,
    task_class: []u8,
    /// Days since the Unix epoch, UTC.
    day_unix: i64,
    turns: u64 = 0,
};

pub const Report = struct {
    tools: []ToolStat,
    niche_days: []NicheDay,
    turns_total: u64,
    malformed_lines: u64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.tools) |stat| allocator.free(stat.tool_name);
        allocator.free(self.tools);
        for (self.niche_days) |day| {
            allocator.free(day.tool_set_hash_hex);
            allocator.free(day.task_class);
        }
        allocator.free(self.niche_days);
        self.* = .{ .tools = &.{}, .niche_days = &.{}, .turns_total = 0, .malformed_lines = 0 };
    }
};

pub fn aggregate(allocator: std.mem.Allocator, jsonl: []const u8) !Report {
    var tools: std.ArrayListUnmanaged(ToolStat) = .empty;
    errdefer {
        for (tools.items) |stat| allocator.free(stat.tool_name);
        tools.deinit(allocator);
    }
    var days: std.ArrayListUnmanaged(NicheDay) = .empty;
    errdefer {
        for (days.items) |day| {
            allocator.free(day.tool_set_hash_hex);
            allocator.free(day.task_class);
        }
        days.deinit(allocator);
    }

    var turns_total: u64 = 0;
    var malformed: u64 = 0;

    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch {
            malformed += 1;
            continue;
        };
        if (parsed != .object) {
            malformed += 1;
            continue;
        }
        const obj = parsed.object;

        const version = obj.get("schema_version") orelse {
            malformed += 1;
            continue;
        };
        if (version != .integer or version.integer != supported_schema_version) {
            malformed += 1;
            continue;
        }

        const hash = stringField(obj, "tool_set_hash") orelse {
            malformed += 1;
            continue;
        };
        const task_class = stringField(obj, "task_class") orelse {
            malformed += 1;
            continue;
        };
        const unix_ms = integerField(obj, "unix_ms") orelse {
            malformed += 1;
            continue;
        };

        turns_total += 1;
        try bumpDay(allocator, &days, hash, task_class, @divFloor(unix_ms, std.time.ms_per_day));

        const calls = obj.get("calls") orelse continue;
        if (calls != .array) continue;
        for (calls.array.items) |item| {
            if (item != .object) continue;
            const name = stringField(item.object, "tool_name") orelse continue;
            const gate_pass = switch (item.object.get("gate_pass") orelse continue) {
                .bool => |b| b,
                else => continue,
            };
            const executed_ok = switch (item.object.get("execution_ok") orelse std.json.Value{ .null = {} }) {
                .bool => |b| b,
                else => false,
            };
            const stat = try findOrAddTool(allocator, &tools, name);
            stat.calls += 1;
            if (gate_pass) stat.gate_passed += 1;
            if (executed_ok) stat.executed_ok += 1;
        }
    }

    const tool_slice = try tools.toOwnedSlice(allocator);
    const day_slice = try days.toOwnedSlice(allocator);
    std.mem.sort(ToolStat, tool_slice, {}, lessToolName);
    std.mem.sort(NicheDay, day_slice, {}, lessNicheDay);

    return .{
        .tools = tool_slice,
        .niche_days = day_slice,
        .turns_total = turns_total,
        .malformed_lines = malformed,
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

/// Returns a pointer into `tools`, which a later append can invalidate. The
/// caller uses it immediately and never holds it across another call.
fn findOrAddTool(
    allocator: std.mem.Allocator,
    tools: *std.ArrayListUnmanaged(ToolStat),
    name: []const u8,
) !*ToolStat {
    for (tools.items) |*stat| {
        if (std.mem.eql(u8, stat.tool_name, name)) return stat;
    }
    const owned = try allocator.dupe(u8, name);
    errdefer allocator.free(owned);
    try tools.append(allocator, .{ .tool_name = owned });
    return &tools.items[tools.items.len - 1];
}

fn bumpDay(
    allocator: std.mem.Allocator,
    days: *std.ArrayListUnmanaged(NicheDay),
    hash: []const u8,
    task_class: []const u8,
    day_unix: i64,
) !void {
    for (days.items) |*day| {
        if (day.day_unix == day_unix and
            std.mem.eql(u8, day.tool_set_hash_hex, hash) and
            std.mem.eql(u8, day.task_class, task_class))
        {
            day.turns += 1;
            return;
        }
    }
    const owned_hash = try allocator.dupe(u8, hash);
    errdefer allocator.free(owned_hash);
    const owned_class = try allocator.dupe(u8, task_class);
    errdefer allocator.free(owned_class);
    try days.append(allocator, .{
        .tool_set_hash_hex = owned_hash,
        .task_class = owned_class,
        .day_unix = day_unix,
        .turns = 1,
    });
}

fn lessToolName(_: void, a: ToolStat, b: ToolStat) bool {
    return std.mem.order(u8, a.tool_name, b.tool_name) == .lt;
}

fn lessNicheDay(_: void, a: NicheDay, b: NicheDay) bool {
    if (a.day_unix != b.day_unix) return a.day_unix < b.day_unix;
    const by_hash = std.mem.order(u8, a.tool_set_hash_hex, b.tool_set_hash_hex);
    if (by_hash != .eq) return by_hash == .lt;
    return std.mem.order(u8, a.task_class, b.task_class) == .lt;
}

pub fn render(report: Report, writer: *std.Io.Writer) !void {
    try writer.print(
        "gate report: {d} turns, {d} malformed lines\n\n",
        .{ report.turns_total, report.malformed_lines },
    );

    try writer.writeAll("contract pass rate per tool\n");
    if (report.tools.len == 0) try writer.writeAll("  no tool call recorded\n");
    for (report.tools) |stat| {
        const rate = if (stat.calls == 0)
            @as(f64, 0)
        else
            @as(f64, @floatFromInt(stat.gate_passed)) * 100.0 / @as(f64, @floatFromInt(stat.calls));
        try writer.print(
            "  {s}: {d}/{d} gate ({d:.1}%), {d} executed ok\n",
            .{ stat.tool_name, stat.gate_passed, stat.calls, rate, stat.executed_ok },
        );
    }

    try writer.writeAll("\nturn volume per niche per day\n");
    if (report.niche_days.len == 0) try writer.writeAll("  no turn recorded\n");
    for (report.niche_days) |day| {
        const short = day.tool_set_hash_hex[0..@min(12, day.tool_set_hash_hex.len)];
        try writer.print(
            "  day {d} niche {s}/{s}: {d} turns\n",
            .{ day.day_unix, day.task_class, short, day.turns },
        );
    }
}

/// `zttp gate-report <path>`: read a gate log and print the two measured
/// numbers M0 exists to produce.
pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    if (argv.len < 1) return error.MissingGateLogPath;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, argv[0], allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(contents);

    var report = try aggregate(allocator, contents);
    defer report.deinit(allocator);

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try render(report, buf.writer());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeAll(buf.written());
    try stdout.interface.flush();
}

const testing = std.testing;

const two_turns =
    \\{"schema_version":1,"session_id":"s","turn_index":0,"unix_ms":1700000000000,"task_class":"tool_call","tool_set_hash":"aa","model_id":"m","adapter_id":null,"tool_calls_total":2,"tool_calls_gate_passed":1,"first_failure":"missing_required","calls":[{"tool_name":"read","gate_pass":true,"failure":null,"execution_ok":true},{"tool_name":"check","gate_pass":false,"failure":"missing_required","execution_ok":false}],"prompt_tokens":1,"generated_tokens":2,"wall_ns":3}
    \\{"schema_version":1,"session_id":"s","turn_index":1,"unix_ms":1700000100000,"task_class":"tool_call","tool_set_hash":"aa","model_id":"m","adapter_id":null,"tool_calls_total":1,"tool_calls_gate_passed":1,"first_failure":null,"calls":[{"tool_name":"check","gate_pass":true,"failure":null,"execution_ok":true}],"prompt_tokens":1,"generated_tokens":2,"wall_ns":3}
    \\
;

test "aggregate counts calls, gate passes, and executions per tool" {
    var report = try aggregate(testing.allocator, two_turns);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 2), report.turns_total);
    try testing.expectEqual(@as(u64, 0), report.malformed_lines);
    try testing.expectEqual(@as(usize, 2), report.tools.len);

    // Sorted by name: check, read.
    try testing.expectEqualStrings("check", report.tools[0].tool_name);
    try testing.expectEqual(@as(u64, 2), report.tools[0].calls);
    try testing.expectEqual(@as(u64, 1), report.tools[0].gate_passed);
    try testing.expectEqual(@as(u64, 1), report.tools[0].executed_ok);

    try testing.expectEqualStrings("read", report.tools[1].tool_name);
    try testing.expectEqual(@as(u64, 1), report.tools[1].calls);
    try testing.expectEqual(@as(u64, 1), report.tools[1].gate_passed);
}

test "aggregate buckets turns by niche and by calendar day" {
    var report = try aggregate(testing.allocator, two_turns);
    defer report.deinit(testing.allocator);

    // Both turns are the same niche on the same UTC day.
    try testing.expectEqual(@as(usize, 1), report.niche_days.len);
    try testing.expectEqual(@as(u64, 2), report.niche_days[0].turns);
    try testing.expectEqualStrings("tool_call", report.niche_days[0].task_class);
}

test "aggregate separates two calendar days in the same niche" {
    const across_days = two_turns ++
        \\{"schema_version":1,"session_id":"s","turn_index":2,"unix_ms":1700100000000,"task_class":"tool_call","tool_set_hash":"aa","model_id":"m","adapter_id":null,"tool_calls_total":0,"tool_calls_gate_passed":0,"first_failure":null,"calls":[],"prompt_tokens":1,"generated_tokens":2,"wall_ns":3}
        \\
    ;
    var report = try aggregate(testing.allocator, across_days);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.niche_days.len);
}

test "aggregate separates two niches on the same day" {
    const two_niches = two_turns ++
        \\{"schema_version":1,"session_id":"s","turn_index":2,"unix_ms":1700000200000,"task_class":"tool_call","tool_set_hash":"bb","model_id":"m","adapter_id":null,"tool_calls_total":0,"tool_calls_gate_passed":0,"first_failure":null,"calls":[],"prompt_tokens":1,"generated_tokens":2,"wall_ns":3}
        \\
    ;
    var report = try aggregate(testing.allocator, two_niches);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.niche_days.len);
}

test "a turn with no tool call adds volume but no tool rows" {
    const empty_turn =
        \\{"schema_version":1,"session_id":"s","turn_index":0,"unix_ms":1700000000000,"task_class":"tool_call","tool_set_hash":"aa","model_id":"m","adapter_id":null,"tool_calls_total":0,"tool_calls_gate_passed":0,"first_failure":null,"calls":[],"prompt_tokens":1,"generated_tokens":2,"wall_ns":3}
        \\
    ;
    var report = try aggregate(testing.allocator, empty_turn);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), report.turns_total);
    try testing.expectEqual(@as(usize, 0), report.tools.len);
    try testing.expectEqual(@as(usize, 1), report.niche_days.len);
}

test "a malformed line is counted and skipped, not fatal" {
    const with_garbage = two_turns ++ "{not json\n" ++ "\n";
    var report = try aggregate(testing.allocator, with_garbage);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), report.turns_total);
    try testing.expectEqual(@as(u64, 1), report.malformed_lines);
}

test "an unsupported schema version is counted as malformed" {
    const future =
        \\{"schema_version":99,"session_id":"s","turn_index":0,"unix_ms":1700000000000,"task_class":"t","tool_set_hash":"aa","model_id":"m","adapter_id":null,"tool_calls_total":0,"tool_calls_gate_passed":0,"first_failure":null,"calls":[],"prompt_tokens":0,"generated_tokens":0,"wall_ns":0}
        \\
    ;
    var report = try aggregate(testing.allocator, future);
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), report.turns_total);
    try testing.expectEqual(@as(u64, 1), report.malformed_lines);
}

test "render prints a pass rate per tool and a volume per niche day" {
    var report = try aggregate(testing.allocator, two_turns);
    defer report.deinit(testing.allocator);
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    try render(report, buf.writer());
    const text = buf.written();
    try testing.expect(std.mem.indexOf(u8, text, "check") != null);
    try testing.expect(std.mem.indexOf(u8, text, "read") != null);
    // check: 1 of 2 gate passes.
    try testing.expect(std.mem.indexOf(u8, text, "50.0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "turns") != null);
}

test "aggregate over an empty input yields an empty report" {
    var report = try aggregate(testing.allocator, "");
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), report.turns_total);
    try testing.expectEqual(@as(usize, 0), report.tools.len);
    try testing.expectEqual(@as(usize, 0), report.niche_days.len);
}
