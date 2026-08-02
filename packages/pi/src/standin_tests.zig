//! End-to-end proof for the deterministic OpenAI wire stand-in.

const std = @import("std");
const agent = @import("agent.zig");
const app = @import("app.zig");
const expert_persona = @import("expert_persona.zig");
const expert_workflow = @import("expert_workflow.zig");
const loop = @import("loop.zig");
const openai_client = @import("providers/openai/client.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const transcript_mod = @import("transcript.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const playbook = @import("standin/playbook.zig");
const request = @import("standin/request.zig");
const server_mod = @import("standin/server.zig");
const zts = @import("zts");

comptime {
    _ = request;
    _ = playbook;
    _ = server_mod;
}

const testing = std.testing;

test "stand-in add-route playbook applies an edit through the real OpenAI agent loop and veto" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = try IsolatedTmp.init(allocator, "standin-route");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(
        allocator,
        "handler.ts",
        "function handler(req: Request): Response {\n    return Response.json({ old: true });\n}\n",
    );

    var server = try server_mod.Server.init(allocator, 0, 3);
    defer server.deinit();
    try server.start();
    const endpoint = try server.url(allocator, "/v1/responses");

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    const tools_json = try buildOpenAIToolsJson(allocator, &registry);
    const system_prompt = try expert_persona.buildSystemPrompt(allocator);
    var session = try agent.AgentSession.initOpenAI(
        allocator,
        "unused-loopback-key",
        system_prompt,
        tools_json,
        .{ .base_url = endpoint, .model = "zttp-deterministic-playbook" },
    );
    defer session.deinit(allocator);

    const saved_cwd = try cwdPathAlloc(allocator);
    defer restoreCwd(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);

    const result = try loop.runTurnWith(
        allocator,
        session.modelClient(),
        &registry,
        &session.transcript,
        "Create a handler in handler.ts that responds to GET /health with Response.json({ ok: true }).",
        .{
            .workspace_root = tmp.abs_path,
            .max_attempts = 1,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.join();

    try testing.expect(result.applied_edit);
    try testing.expect(result.first_draft_veto_pass);
    try testing.expectEqual(expert_workflow.TaskKind.route_add, result.workflow_kind);

    const handler_path = try tmp.childPath(allocator, "handler.ts");
    const content = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    try testing.expect(std.mem.indexOf(u8, content, "\"GET /health\": handleGetHealth") != null);
    try testing.expect(std.mem.indexOf(u8, content, "function handleGetHealth") != null);
}

test "stand-in miss returns its marker through the real loop and applies no edit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = try IsolatedTmp.init(allocator, "standin-miss");
    defer tmp.cleanup(allocator);
    var server = try server_mod.Server.init(allocator, 0, 1);
    defer server.deinit();
    try server.start();
    const endpoint = try server.url(allocator, "/v1/responses");

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    const tools_json = try buildOpenAIToolsJson(allocator, &registry);
    var session = try agent.AgentSession.initOpenAI(
        allocator,
        "unused-loopback-key",
        "Use the deterministic playbook server.",
        tools_json,
        .{ .base_url = endpoint, .model = "zttp-deterministic-playbook" },
    );
    defer session.deinit(allocator);

    const result = try loop.runTurnWith(
        allocator,
        session.modelClient(),
        &registry,
        &session.transcript,
        "Explain how durable workflow retries work",
        .{
            .workspace_root = tmp.abs_path,
            .max_attempts = 1,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.join();

    try testing.expect(!result.applied_edit);
    try testing.expect(transcriptContains(&session.transcript, "[standin-miss]"));
    const handler_path = try tmp.childPath(allocator, "handler.ts");
    try testing.expectError(error.FileNotFound, zts.file_io.readFile(allocator, handler_path, 1024));
}

fn buildOpenAIToolsJson(
    allocator: std.mem.Allocator,
    registry: *const @import("registry/registry.zig").Registry,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try openai_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

fn transcriptContains(transcript: *const transcript_mod.Transcript, needle: []const u8) bool {
    for (transcript.entries.items) |entry| {
        const text: ?[]const u8 = switch (entry) {
            .model_text => |value| value,
            .diagnostic_box => |value| value.llm_text,
            else => null,
        };
        if (text) |value| {
            if (std.mem.indexOf(u8, value, needle) != null) return true;
        }
    }
    return false;
}

fn cwdPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io_backend.io(), ".", allocator);
}

fn restoreCwd(path: []const u8) void {
    std.Io.Threaded.chdir(path) catch |err| {
        std.debug.panic("failed to restore test cwd: {s}", .{@errorName(err)});
    };
}
