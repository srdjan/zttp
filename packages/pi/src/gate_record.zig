//! Niche identity, the per-turn gate record, and the sink that receives it.
//!
//! A record carries tool names, counts, enums, hashes, and booleans. It never
//! carries prompt text, tool-argument text, file paths, or credentials.
//!
//! The gate verdict and the execution outcome are separate fields and are
//! never merged. A response with no tool call reads as zero of zero rather
//! than as a fabricated pass.

const std = @import("std");
const contract_gate = @import("contract_gate.zig");
const ToolDef = @import("registry/tool.zig").ToolDef;
const json_writer = @import("providers/json_writer.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const propose_change_set = @import("providers/anthropic/propose_change_set.zig");

pub const RejectionShape = propose_change_set.RejectionShape;

pub const record_schema_version: u32 = 1;

pub const ToolSetHash = [32]u8;

/// Fingerprint the exact tool set offered for a request. Sorting by name makes
/// the hash independent of registration order, and the NUL separators stop a
/// name boundary from being confused with a schema boundary.
pub fn toolSetHash(
    scratch: std.mem.Allocator,
    tools: []const ToolDef,
) error{OutOfMemory}!ToolSetHash {
    const order = try scratch.alloc(usize, tools.len);
    defer scratch.free(order);
    for (order, 0..) |*slot, i| slot.* = i;

    const Ctx = struct {
        tools: []const ToolDef,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, ctx.tools[a].name, ctx.tools[b].name) == .lt;
        }
    };
    std.mem.sort(usize, order, Ctx{ .tools = tools }, Ctx.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (order) |index| {
        hasher.update(tools[index].name);
        hasher.update(&[_]u8{0});
        hasher.update(tools[index].input_schema);
        hasher.update(&[_]u8{0});
    }
    var out: ToolSetHash = undefined;
    hasher.final(&out);
    return out;
}

pub fn hashToHex(hash: ToolSetHash) [64]u8 {
    var out: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0f];
    }
    return out;
}

/// Map a provider-shape refusal onto schema vocabulary.
///
/// Exhaustive with no `else`, so a future shape is a compile error rather than
/// a silently miscounted call.
///
/// Null means no verdict at all. `truncated` is the only such shape: a response
/// cut off at the token cap is a transport outcome, and counting it as a schema
/// violation would inflate the measured contract failure rate with something
/// the model never chose.
///
/// `changes_empty` and `changes_too_many` are lossy on purpose. They are
/// `max_changes` cardinality bounds rather than declared schema, so no
/// `FailureReason` names them precisely and `type_mismatch` is the closest
/// honest bucket. Keep the shape tag beside the mapped reason so a report can
/// still tell them apart without a re-record.
pub fn failureForRejection(shape: RejectionShape) ?contract_gate.FailureReason {
    return switch (shape) {
        .truncated => null,
        .args_not_json => .args_not_json,
        .args_not_object => .args_not_object,
        .args_extra_top_level_key => .undeclared_parameter,
        .changes_missing => .missing_required,
        .changes_not_array => .type_mismatch,
        .changes_empty => .type_mismatch,
        .changes_too_many => .type_mismatch,
        .change_not_object => .type_mismatch,
        .change_file_missing => .missing_required,
        .change_content_missing => .missing_required,
        .change_host_authoritative_key => .undeclared_parameter,
        .change_extra_field => .undeclared_parameter,
        .change_field_type => .type_mismatch,
    };
}

pub const CallOutcome = struct {
    tool_name: []const u8,
    gate_pass: bool,
    /// The gate's first failing check for this call. Null when the gate passed.
    failure: ?contract_gate.FailureReason,
    /// The independent execution verdict, reported after the tool ran. Null
    /// when the tool did not run. Never merged with `gate_pass`.
    execution_ok: ?bool,
};

pub const TurnRecord = struct {
    schema_version: u32 = record_schema_version,
    session_id: []const u8,
    turn_index: u32,
    unix_ms: i64,
    /// Host-assigned. The library never computes it.
    task_class: []const u8,
    tool_set_hash: ToolSetHash,
    model_id: []const u8,
    adapter_id: ?[]const u8,
    tool_calls_total: u32,
    tool_calls_gate_passed: u32,
    first_failure: ?contract_gate.FailureReason,
    calls: []const CallOutcome,
    prompt_tokens: u64,
    generated_tokens: u64,
    wall_ns: u64,
};

pub fn writeJsonl(record: TurnRecord, writer: *std.Io.Writer) !void {
    const hex = hashToHex(record.tool_set_hash);
    try writer.writeAll("{\"schema_version\":");
    try writer.print("{d}", .{record.schema_version});
    try writer.writeAll(",\"session_id\":");
    try json_writer.writeString(writer, record.session_id);
    try writer.print(",\"turn_index\":{d},\"unix_ms\":{d}", .{ record.turn_index, record.unix_ms });
    try writer.writeAll(",\"task_class\":");
    try json_writer.writeString(writer, record.task_class);
    try writer.writeAll(",\"tool_set_hash\":");
    try json_writer.writeString(writer, &hex);
    try writer.writeAll(",\"model_id\":");
    try json_writer.writeString(writer, record.model_id);
    try writer.writeAll(",\"adapter_id\":");
    if (record.adapter_id) |id| {
        try json_writer.writeString(writer, id);
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"tool_calls_total\":{d},\"tool_calls_gate_passed\":{d}",
        .{ record.tool_calls_total, record.tool_calls_gate_passed },
    );
    try writer.writeAll(",\"first_failure\":");
    try writeReason(writer, record.first_failure);
    try writer.writeAll(",\"calls\":[");
    for (record.calls, 0..) |call, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"tool_name\":");
        try json_writer.writeString(writer, call.tool_name);
        try writer.print(",\"gate_pass\":{s}", .{if (call.gate_pass) "true" else "false"});
        try writer.writeAll(",\"failure\":");
        try writeReason(writer, call.failure);
        try writer.writeAll(",\"execution_ok\":");
        if (call.execution_ok) |ok| {
            try writer.writeAll(if (ok) "true" else "false");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.print(
        "],\"prompt_tokens\":{d},\"generated_tokens\":{d},\"wall_ns\":{d}}}\n",
        .{ record.prompt_tokens, record.generated_tokens, record.wall_ns },
    );
}

fn writeReason(writer: *std.Io.Writer, reason: ?contract_gate.FailureReason) !void {
    if (reason) |r| {
        try json_writer.writeString(writer, contract_gate.reasonLabel(r));
    } else {
        try writer.writeAll("null");
    }
}

/// Best-effort record destination. A sink failure must never replace or alter
/// a turn result, so `record` swallows the error. This mirrors
/// `CaptureSink.recordDiagnostics`.
pub const GateSink = struct {
    context: *anyopaque,
    record_fn: *const fn (context: *anyopaque, record: TurnRecord) anyerror!void,

    pub fn record(self: *GateSink, turn_record: TurnRecord) void {
        self.record_fn(self.context, turn_record) catch {};
    }
};

const testing = std.testing;

fn probe(name: []const u8, schema: []const u8) ToolDef {
    return .{
        .name = name,
        .label = "Probe",
        .description = "test tool",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = schema,
        .decode_json = undefined,
        .execute = undefined,
    };
}

test "every rejection shape maps to a gate failure or to no verdict" {
    // A fifteenth shape must fail here rather than be silently miscounted.
    inline for (std.enums.values(RejectionShape)) |shape| {
        const mapped = failureForRejection(shape);
        if (shape == .truncated) {
            try testing.expect(mapped == null);
        } else {
            try testing.expect(mapped != null);
        }
    }
}

test "a missing change content maps to missing_required" {
    try testing.expectEqual(
        contract_gate.FailureReason.missing_required,
        failureForRejection(.change_content_missing).?,
    );
}

test "truncation is a transport outcome, not a schema failure" {
    try testing.expect(failureForRejection(.truncated) == null);
}

test "a cardinality bound maps to type_mismatch and keeps its own tag" {
    try testing.expectEqual(
        contract_gate.FailureReason.type_mismatch,
        failureForRejection(.changes_empty).?,
    );
    try testing.expectEqual(
        contract_gate.FailureReason.type_mismatch,
        failureForRejection(.changes_too_many).?,
    );
}

test "tool set hash is stable under registration order" {
    const forward = [_]ToolDef{ probe("alpha", "{}"), probe("beta", "{\"type\":\"object\"}") };
    const reverse = [_]ToolDef{ probe("beta", "{\"type\":\"object\"}"), probe("alpha", "{}") };
    const a = try toolSetHash(testing.allocator, &forward);
    const b = try toolSetHash(testing.allocator, &reverse);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "tool set hash changes when a schema changes" {
    const before = [_]ToolDef{probe("alpha", "{}")};
    const after = [_]ToolDef{probe("alpha", "{\"type\":\"object\"}")};
    const a = try toolSetHash(testing.allocator, &before);
    const b = try toolSetHash(testing.allocator, &after);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "tool set hash changes when a tool is added" {
    const before = [_]ToolDef{probe("alpha", "{}")};
    const after = [_]ToolDef{ probe("alpha", "{}"), probe("beta", "{}") };
    const a = try toolSetHash(testing.allocator, &before);
    const b = try toolSetHash(testing.allocator, &after);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "tool set hash does not confuse a name boundary with a schema boundary" {
    // Without a separator, "ab" + "" and "a" + "b" would hash identically.
    const left = [_]ToolDef{probe("ab", "{}")};
    const right = [_]ToolDef{probe("a", "b{}")};
    const a = try toolSetHash(testing.allocator, &left);
    const b = try toolSetHash(testing.allocator, &right);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "hashToHex renders 64 lowercase hex characters" {
    var hash: ToolSetHash = undefined;
    @memset(&hash, 0xab);
    const hex = hashToHex(hash);
    try testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    try testing.expectEqualStrings("abab", hex[0..4]);
}

test "a turn with no tool call serializes as zero of zero with a null first failure" {
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    var hash: ToolSetHash = undefined;
    @memset(&hash, 0x00);

    try writeJsonl(.{
        .session_id = "s1",
        .turn_index = 0,
        .unix_ms = 1_700_000_000_000,
        .task_class = "unclassified",
        .tool_set_hash = hash,
        .model_id = "Youssofal/Qwen3.5-9B-MTPLX-Optimized-Speed",
        .adapter_id = null,
        .tool_calls_total = 0,
        .tool_calls_gate_passed = 0,
        .first_failure = null,
        .calls = &.{},
        .prompt_tokens = 12,
        .generated_tokens = 34,
        .wall_ns = 56,
    }, buf.writer());

    const line = buf.written();
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expect(std.mem.indexOf(u8, line, "\"tool_calls_total\":0") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"tool_calls_gate_passed\":0") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"first_failure\":null") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"adapter_id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"calls\":[]") != null);
}

test "a mixed turn records per-call verdicts and the first failure only" {
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    var hash: ToolSetHash = undefined;
    @memset(&hash, 0x11);

    const calls = [_]CallOutcome{
        .{ .tool_name = "workspace_read_file", .gate_pass = true, .failure = null, .execution_ok = true },
        .{ .tool_name = "zts_check", .gate_pass = false, .failure = .missing_required, .execution_ok = false },
        .{ .tool_name = "zts_check", .gate_pass = false, .failure = .enum_violation, .execution_ok = null },
    };

    try writeJsonl(.{
        .session_id = "s2",
        .turn_index = 3,
        .unix_ms = 1_700_000_000_000,
        .task_class = "tool_call",
        .tool_set_hash = hash,
        .model_id = "Youssofal/Qwen3.5-9B-MTPLX-Optimized-Speed",
        .adapter_id = "deadbeef",
        .tool_calls_total = 3,
        .tool_calls_gate_passed = 1,
        .first_failure = .missing_required,
        .calls = &calls,
        .prompt_tokens = 100,
        .generated_tokens = 20,
        .wall_ns = 999,
    }, buf.writer());

    const line = buf.written();
    try testing.expect(std.mem.indexOf(u8, line, "\"tool_calls_total\":3") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"tool_calls_gate_passed\":1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"first_failure\":\"missing_required\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"adapter_id\":\"deadbeef\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"failure\":\"enum_violation\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"execution_ok\":null") != null);
    // Exactly one newline, at the end: JSONL is one record per line.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "a record carries no argument text even when a tool name needs escaping" {
    var buf = TextBuffer.init(testing.allocator);
    defer buf.deinit();
    var hash: ToolSetHash = undefined;
    @memset(&hash, 0x00);
    const calls = [_]CallOutcome{
        .{ .tool_name = "quote\"name", .gate_pass = true, .failure = null, .execution_ok = true },
    };
    try writeJsonl(.{
        .session_id = "s3",
        .turn_index = 0,
        .unix_ms = 0,
        .task_class = "tool_call",
        .tool_set_hash = hash,
        .model_id = "m",
        .adapter_id = null,
        .tool_calls_total = 1,
        .tool_calls_gate_passed = 1,
        .first_failure = null,
        .calls = &calls,
        .prompt_tokens = 0,
        .generated_tokens = 0,
        .wall_ns = 0,
    }, buf.writer());
    try testing.expect(std.mem.indexOf(u8, buf.written(), "quote\\\"name") != null);
}

test "a sink failure is swallowed and never reaches the caller" {
    const Failing = struct {
        calls: usize = 0,
        fn record(context: *anyopaque, _: TurnRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return error.DiskFull;
        }
    };
    var failing = Failing{};
    var sink = GateSink{ .context = &failing, .record_fn = Failing.record };
    var hash: ToolSetHash = undefined;
    @memset(&hash, 0x00);
    sink.record(.{
        .session_id = "s4",
        .turn_index = 0,
        .unix_ms = 0,
        .task_class = "tool_call",
        .tool_set_hash = hash,
        .model_id = "m",
        .adapter_id = null,
        .tool_calls_total = 0,
        .tool_calls_gate_passed = 0,
        .first_failure = null,
        .calls = &.{},
        .prompt_tokens = 0,
        .generated_tokens = 0,
        .wall_ns = 0,
    });
    try testing.expectEqual(@as(usize, 1), failing.calls);
}
