//! Provider-free recorder smoke test.
//!
//! The test uses the production local client, capture sink, cassette storage,
//! and replay path. Its HTTP endpoint stays on loopback.

const std = @import("std");
const local = @import("providers/local/client.zig");
const cassette_client = @import("providers/cassette_client.zig");
const cassette_record = @import("providers/cassette_record.zig");
const capture_sink = @import("providers/capture_sink.zig");
const model_request = @import("providers/model_request.zig");
const transcript_mod = @import("transcript.zig");

const testing = std.testing;

const SmokeCapture = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    request_sha256: ?model_request.Sha256Hex = null,

    fn record(
        context: *anyopaque,
        call_index: usize,
        snapshot: *const model_request.ModelRequestSnapshot,
        raw_response: []const u8,
    ) anyerror!void {
        const self: *SmokeCapture = @ptrCast(@alignCast(context));
        if (call_index != 0) return error.UnexpectedCallIndex;
        const request_sha256 = snapshot.wire_request_sha256 orelse
            return error.MissingRequestIdentity;

        try cassette_record.writeCassette(self.allocator, self.path, raw_response, .{
            .provider = .local,
            .scenario = "recorder-smoke",
            .stream = snapshot.config.stream,
            .model = snapshot.config.model,
            .request_sha256 = request_sha256.slice(),
        });
        self.request_sha256 = request_sha256;
    }
};

test "recorder captures stores identifies and replays a loopback response" {
    // The provider parser uses arena-backed JSON because one turn owns the
    // complete result. The smoke test uses the same lifetime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const response_body =
        "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"," ++
        "\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]," ++
        "\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";

    var server = try cassette_record.LocalHttpServer.init(
        allocator,
        response_body,
        "application/json",
    );
    try server.start();
    errdefer server.join() catch {};
    const endpoint = try server.url(allocator, "");
    defer allocator.free(endpoint);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const record_root = try std.fs.path.resolve(
        allocator,
        &.{ ".zig-cache", "tmp", tmp.sub_path[0..] },
    );
    defer allocator.free(record_root);
    const path = try std.fs.path.join(allocator, &.{ record_root, "recorder-smoke.jsonl" });
    defer allocator.free(path);

    var capture = SmokeCapture{
        .allocator = allocator,
        .path = path,
    };
    var sink = capture_sink.CaptureSink{
        .context = &capture,
        .record_fn = SmokeCapture.record,
    };
    var client = local.Client.initWithCapture(.{
        .system_prompt = "You are a terse assistant. Reply with exactly one word.",
        .model = "deterministic-recorder-smoke",
        .base_url = endpoint,
    }, &sink);

    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(allocator);
    try transcript.append(allocator, .{ .user_text = "Say OK." });

    const live = try client.sendTurn(allocator, &transcript, null);
    try server.join();

    try testing.expectEqual(@as(usize, 1), sink.next_call_index);
    switch (live.reply.response) {
        .final_text => |text| try testing.expectEqualStrings("OK", text),
        else => return error.ExpectedLiveFinalText,
    }
    const captured_request_sha256 = capture.request_sha256 orelse
        return error.MissingCapturedRequestIdentity;

    const cassette = try cassette_client.loadCassetteFromPath(allocator, path);
    try testing.expectEqualStrings(response_body, cassette.body);
    try testing.expectEqual(cassette_client.Provider.local, cassette.header.provider);
    try testing.expectEqualStrings("recorder-smoke", cassette.header.scenario orelse
        return error.MissingCassetteScenario);
    try testing.expect(!cassette.header.stream);
    try testing.expectEqualStrings(
        captured_request_sha256.slice(),
        cassette.header.request_sha256 orelse return error.MissingCassetteRequestIdentity,
    );

    const replayed = try cassette_client.replay(allocator, cassette);
    const live_kind = std.meta.activeTag(live.reply.response);
    const replay_kind = std.meta.activeTag(replayed.reply.response);
    try testing.expectEqual(live_kind, replay_kind);
    switch (replayed.reply.response) {
        .final_text => |text| try testing.expectEqualStrings("OK", text),
        else => return error.ExpectedFinalText,
    }
}
