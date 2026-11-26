//! Counterexample witness replay (PI side).
//!
//! The PI agent host owns the witness pane, the autoloop, and the
//! verified-patch ledger - none of which can take a direct build
//! dependency on the runtime stack (PI is consumed by the runtime
//! binaries, so the dependency would invert). Instead, the binaries
//! that ship PI together with the runtime register a replay function
//! pointer at startup via `setReplayFn`. PI calls `replay()` against
//! that pointer; if it has not been registered the call returns
//! `error.WitnessReplayNotConfigured`, which callers surface as
//! "replay unavailable" without aborting.
//!
//! The wire protocol is trace-compatible JSONL, the same shape the
//! engine consumes via `--test`. Callers serialise a `WitnessBody`
//! through `writeWitnessJsonl` here and hand the bytes to `replay`.

const std = @import("std");
const zts = @import("zts");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const ui_payload = @import("ui_payload.zig");

pub const Verdict = struct {
    /// True when the engine ran the witness through to a response.
    /// False when the run errored (parse, interpreter, replay-state
    /// divergence, etc.); see `error_text`.
    ran: bool,
    actual_status: u16,
    actual_body: []u8,
    error_text: ?[]u8,

    pub fn deinit(self: *Verdict, allocator: std.mem.Allocator) void {
        if (self.actual_body.len > 0) allocator.free(self.actual_body);
        if (self.error_text) |t| allocator.free(t);
        self.* = .{ .ran = false, .actual_status = 0, .actual_body = &.{}, .error_text = null };
    }

    /// True when the run reproduced the violation the witness was built
    /// to demonstrate. The classifier is property-specific: for the
    /// flow-leak family (`no_secret_leakage`, `no_credential_leakage`)
    /// it looks for the stub sentinel string the solver planted in the
    /// IO script (e.g. `"secret-sentinel"` for an optional-string env
    /// return). Other property tags fall back to "ran without error" -
    /// good enough until per-property classifiers ship.
    pub fn reproducedViolation(self: Verdict, witness: ui_payload.WitnessBody) bool {
        if (!self.ran) return false;
        if (witness.io_stubs.len == 0) return self.actual_status >= 200 and self.actual_status < 300;

        for (witness.io_stubs) |stub| {
            const sentinel = unwrapJsonString(stub.result_json);
            if (sentinel.len > 0 and std.mem.find(u8, self.actual_body, sentinel) != null) return true;
        }
        return false;
    }
};

pub const ReplayFn = *const fn (
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    witness_jsonl: []const u8,
) anyerror!Verdict;

var replay_fn: ?ReplayFn = null;

/// Register the runtime-backed implementation. Called once at startup
/// from a binary that ships both PI and the runtime stack. Subsequent
/// calls overwrite the pointer (last-write-wins; the codebase only
/// registers from one boot path so the second call would be a bug).
pub fn setReplayFn(f: ReplayFn) void {
    replay_fn = f;
}

pub fn isConfigured() bool {
    return replay_fn != null;
}

/// Replay a witness body against a handler at `handler_path`. Returns
/// `error.WitnessReplayNotConfigured` when no implementation is wired
/// (e.g. unit tests that stub the agent layer without the runtime).
pub fn replay(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    witness: ui_payload.WitnessBody,
) !Verdict {
    const f = replay_fn orelse return error.WitnessReplayNotConfigured;

    var jsonl = TextBuffer.init(allocator);
    defer jsonl.deinit();
    try writeWitnessJsonl(jsonl.writer(), witness);

    return f(allocator, handler_path, jsonl.written());
}

/// Emit a witness body as trace-compatible JSONL: one `request` record
/// followed by one `io` record per stub. The format matches what
/// `zts.counterexample.writeJsonl` produces (minus the optional
/// `witness` header line, which the trace parser drops anyway).
pub fn writeWitnessJsonl(w: *std.Io.Writer, body: ui_payload.WitnessBody) !void {
    try w.writeAll("{\"type\":\"request\",\"method\":");
    try zts.writeJsonString(w, body.request_method);
    try w.writeAll(",\"url\":");
    try zts.writeJsonString(w, body.request_url);
    if (body.request_has_auth) {
        try w.writeAll(",\"headers\":{\"authorization\":\"Bearer counterexample-token\"}");
    } else {
        try w.writeAll(",\"headers\":{}");
    }
    if (body.request_body) |b| {
        try w.writeAll(",\"body\":");
        try zts.writeJsonString(w, b);
    } else {
        try w.writeAll(",\"body\":null");
    }
    try w.writeAll("}\n");

    for (body.io_stubs) |stub| {
        try w.print("{{\"type\":\"io\",\"seq\":{d},\"module\":", .{stub.seq});
        try zts.writeJsonString(w, stub.module);
        try w.writeAll(",\"fn\":");
        try zts.writeJsonString(w, stub.func);
        try w.print(",\"result\":{s}}}\n", .{stub.result_json});
    }
}

fn unwrapJsonString(text: []const u8) []const u8 {
    if (text.len < 2) return &.{};
    if (text[0] != '"' or text[text.len - 1] != '"') return &.{};
    return text[1 .. text.len - 1];
}

const testing = std.testing;

test "writeWitnessJsonl emits a parseable trace pair" {
    const allocator = testing.allocator;
    const stubs = [_]ui_payload.WitnessStub{
        .{
            .seq = 0,
            .module = @constCast("env"),
            .func = @constCast("env"),
            .result_json = @constCast("\"sentinel\""),
        },
    };
    const body = ui_payload.WitnessBody{
        .key = @constCast(&@as([64:0]u8, @splat('a'))),
        .property = @constCast("no_secret_leakage"),
        .summary = @constCast("test"),
        .origin_line = 1,
        .origin_column = 1,
        .sink_line = 2,
        .sink_column = 1,
        .request_method = @constCast("GET"),
        .request_url = @constCast("/"),
        .request_has_auth = false,
        .request_body = null,
        .io_stubs = @constCast(&stubs),
    };

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try writeWitnessJsonl(buf.writer(), body);

    try testing.expect(std.mem.find(u8, buf.written(), "\"type\":\"request\"") != null);
    try testing.expect(std.mem.find(u8, buf.written(), "\"method\":\"GET\"") != null);
    try testing.expect(std.mem.find(u8, buf.written(), "\"type\":\"io\"") != null);
    try testing.expect(std.mem.find(u8, buf.written(), "\"fn\":\"env\"") != null);
    try testing.expect(std.mem.find(u8, buf.written(), "\"result\":\"sentinel\"") != null);
}

test "Verdict.reproducedViolation matches sentinel substring" {
    const stubs = [_]ui_payload.WitnessStub{
        .{
            .seq = 0,
            .module = @constCast("env"),
            .func = @constCast("env"),
            .result_json = @constCast("\"secret-sentinel\""),
        },
    };
    const body = ui_payload.WitnessBody{
        .key = @constCast(""),
        .property = @constCast("no_secret_leakage"),
        .summary = @constCast(""),
        .origin_line = 1,
        .origin_column = 1,
        .sink_line = 1,
        .sink_column = 1,
        .request_method = @constCast("GET"),
        .request_url = @constCast("/"),
        .request_has_auth = false,
        .request_body = null,
        .io_stubs = @constCast(&stubs),
    };

    const reproducing = Verdict{
        .ran = true,
        .actual_status = 200,
        .actual_body = @constCast("{\"leaked\":\"secret-sentinel\"}"),
        .error_text = null,
    };
    try testing.expect(reproducing.reproducedViolation(body));

    const fixed = Verdict{
        .ran = true,
        .actual_status = 401,
        .actual_body = @constCast("Unauthorized"),
        .error_text = null,
    };
    try testing.expect(!fixed.reproducedViolation(body));

    const not_run = Verdict{ .ran = false, .actual_status = 0, .actual_body = &.{}, .error_text = null };
    try testing.expect(!not_run.reproducedViolation(body));
}

test "replay returns error.WitnessReplayNotConfigured when no fn is registered" {
    const allocator = testing.allocator;
    const body = ui_payload.WitnessBody{
        .key = @constCast(""),
        .property = @constCast(""),
        .summary = @constCast(""),
        .origin_line = 1,
        .origin_column = 1,
        .sink_line = 1,
        .sink_column = 1,
        .request_method = @constCast("GET"),
        .request_url = @constCast("/"),
        .request_has_auth = false,
        .request_body = null,
        .io_stubs = &.{},
    };

    // Save and restore so the test does not interfere with another run.
    const saved = replay_fn;
    defer replay_fn = saved;
    replay_fn = null;

    try testing.expectError(error.WitnessReplayNotConfigured, replay(allocator, "h.ts", body));
}

test "writeWitnessJsonl escapes JSON string fields" {
    const allocator = testing.allocator;
    const stubs = [_]ui_payload.WitnessStub{
        .{
            .seq = 0,
            .module = @constCast("mod\"a\\b"),
            .func = @constCast("fn\nname"),
            .result_json = @constCast("\"ok\""),
        },
    };
    const body = ui_payload.WitnessBody{
        .key = @constCast(""),
        .property = @constCast("no_secret_leakage"),
        .summary = @constCast(""),
        .origin_line = 1,
        .origin_column = 1,
        .sink_line = 1,
        .sink_column = 1,
        .request_method = @constCast("G\"E\\T"),
        .request_url = @constCast("/a?b=\"c\""),
        .request_has_auth = false,
        .request_body = null,
        .io_stubs = @constCast(&stubs),
    };

    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try writeWitnessJsonl(buf.writer(), body);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    const req_line = lines.next().?;
    const io_line = lines.next().?;
    try testing.expect(lines.next() == null);

    var req_parsed = try std.json.parseFromSlice(std.json.Value, allocator, req_line, .{});
    defer req_parsed.deinit();
    try testing.expectEqualStrings("G\"E\\T", req_parsed.value.object.get("method").?.string);
    try testing.expectEqualStrings("/a?b=\"c\"", req_parsed.value.object.get("url").?.string);

    var io_parsed = try std.json.parseFromSlice(std.json.Value, allocator, io_line, .{});
    defer io_parsed.deinit();
    try testing.expectEqualStrings("mod\"a\\b", io_parsed.value.object.get("module").?.string);
    try testing.expectEqualStrings("fn\nname", io_parsed.value.object.get("fn").?.string);
}

test "reproducedViolation checks all stub sentinels and rejects non-matching 200 OK" {
    const stub_first = ui_payload.WitnessStub{
        .seq = 0,
        .module = @constCast("zttp:env"),
        .func = @constCast("env"),
        .result_json = @constCast("\"\""),
    };
    const stub_second = ui_payload.WitnessStub{
        .seq = 1,
        .module = @constCast("zttp:env"),
        .func = @constCast("env"),
        .result_json = @constCast("\"TOP_SECRET\""),
    };
    var stubs = [_]ui_payload.WitnessStub{ stub_first, stub_second };
    const base_body = ui_payload.WitnessBody{
        .key = @constCast("k"),
        .property = @constCast("no_secret_leakage"),
        .summary = @constCast(""),
        .origin_line = 1,
        .origin_column = 1,
        .sink_line = 1,
        .sink_column = 1,
        .request_method = @constCast("GET"),
        .request_url = @constCast("/"),
        .request_has_auth = false,
        .request_body = null,
        .io_stubs = @constCast(&stubs),
    };

    const miss: Verdict = .{ .ran = true, .actual_status = 200, .actual_body = @constCast("ok"), .error_text = null };
    try testing.expect(!miss.reproducedViolation(base_body));

    const hit: Verdict = .{ .ran = true, .actual_status = 200, .actual_body = @constCast("leaked TOP_SECRET"), .error_text = null };
    try testing.expect(hit.reproducedViolation(base_body));

    var no_stubs_body = base_body;
    no_stubs_body.io_stubs = &.{};
    try testing.expect(miss.reproducedViolation(no_stubs_body));

    const not_run: Verdict = .{ .ran = false, .actual_status = 200, .actual_body = @constCast("leaked TOP_SECRET"), .error_text = null };
    try testing.expect(!not_run.reproducedViolation(base_body));
}
