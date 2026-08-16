//! Real-model gate for the developer-managed local MLX provider.
//!
//! This target is explicit and is not part of `zig build test`. It requires the
//! exact LFM server documented by the expert command to already be running.

const std = @import("std");
const zts = @import("zts");
const app = @import("app.zig");
const agent = @import("agent.zig");
const loop = @import("loop.zig");
const session_events = @import("session/events.zig");
const veto = @import("veto.zig");
const EnvOverride = @import("test_support/env.zig").EnvOverride;
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const cwdPathAlloc = @import("test_support/cwd.zig").cwdPathAlloc;

const initial_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> {\n" ++
    "  if (req.url === \"/old\") {\n" ++
    "    return Response.json({ legacy: true });\n" ++
    "  }\n" ++
    "  return Response.json({ error: \"not found\" }, { status: 404 });\n" ++
    "}\n";

const accepted_handler =
    "function handler(req: Request): Proof<Response, \"deterministic\"> {\n" ++
    "  if (req.url === \"/health\") {\n" ++
    "    return Response.json({ ok: true });\n" ++
    "  }\n" ++
    "  return Response.json({ error: \"not found\" }, { status: 404 });\n" ++
    "}\n";

const ApprovalProbe = struct {
    calls: usize = 0,

    fn approve(context: *anyopaque, preview: loop.ApprovalPreview) anyerror!bool {
        const self: *ApprovalProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (preview.file.len == 0 or preview.after.len == 0) return false;
        return true;
    }

    fn approvalFn(self: *ApprovalProbe) loop.ApprovalFn {
        return .{ .contextual = .{ .context = self, .func = approve } };
    }
};

const VetoThenLocalClient = struct {
    delegate: loop.ModelClient,
    injected: bool = false,

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const @import("transcript.zig").Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *VetoThenLocalClient = @ptrCast(@alignCast(context));
        if (!self.injected) {
            self.injected = true;
            return .{ .reply = .{ .response = .{ .change_set = .{
                .file = "handler.ts",
                .content = "import { sqlOne } from \"zttp:sql\";\n" ++
                    "function handler(req: Request): Response { const row = sqlOne(\"SELECT * FROM users\"); return Response.json({ row: row }); }\n",
            } } } };
        }
        return self.delegate.request(arena, transcript, extra_user_text);
    }

    fn asClient(self: *VetoThenLocalClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

test "local MLX expert flow" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = try IsolatedTmp.init(allocator, "mlx-e2e");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(
        allocator,
        "handler.ts",
        initial_handler,
    );

    const sessions_dir = try tmp.childPath(allocator, "sessions");
    defer allocator.free(sessions_dir);
    var sessions_env = try EnvOverride.set(allocator, "ZTTP_SESSIONS_DIR", sessions_dir);
    defer sessions_env.restore(allocator);
    var anthropic_env = try EnvOverride.unset(allocator, "ANTHROPIC_API_KEY");
    defer anthropic_env.restore(allocator);
    var openai_env = try EnvOverride.unset(allocator, "OPENAI_API_KEY");
    defer openai_env.restore(allocator);

    const saved_cwd = try cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    var target_check = try veto.runVeto(allocator, .{
        .file = "handler.ts",
        .content = accepted_handler,
        .before = initial_handler,
    });
    defer target_check.deinit(allocator);
    try std.testing.expect(target_check.outcome.ok);

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);

    var session = try agent.initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_context_files = true,
        .provider = .local,
    });
    const original_session_id = try allocator.dupe(
        u8,
        session.session_id orelse return error.TestUnexpectedResult,
    );
    defer allocator.free(original_session_id);

    var approval: ApprovalProbe = .{};
    const prompt =
        "A compatibility harness will inject a zttp:sql draft into this project, which deliberately has no SQL schema. " ++
        "After the compiler vetoes it, do not ask for a schema and do not keep SQL. You must use " ++
        "workspace_read_file to read handler.ts and inspect the veto feedback. Do not call zts_check because " ++
        "propose_change_set runs the compiler automatically. Then use propose_change_set to replace handler.ts with exactly this code:\n\n" ++
        accepted_handler ++
        "\nKeep working until accepted.";
    var client: VetoThenLocalClient = .{ .delegate = session.modelClient() };
    const rendered = try agent.runOneTurnWithClient(
        allocator,
        &session,
        &registry,
        client.asClient(),
        prompt,
        approval.approvalFn(),
    );
    defer allocator.free(rendered);

    if (session.metrics.verified_patch_count == 0) {
        std.debug.print(
            "[mlx-e2e] no verified patch: tools={d} veto_retries={d} outcome={s}\n",
            .{
                session.metrics.tool_call_count,
                session.metrics.veto_retry_count,
                @tagName(session.metrics.last_outcome),
            },
        );
        for (session.transcript.entries.items) |*entry| {
            switch (entry.*) {
                .assistant_tool_use => |calls| for (calls) |call| {
                    std.debug.print("[mlx-e2e] tool={s} args={s}\n", .{ call.name, call.args_json });
                },
                else => {},
            }
            const line = @import("transcript.zig").renderRichEntryToOwned(allocator, entry) catch continue;
            defer allocator.free(line);
            std.debug.print("{s}", .{line});
        }
    }

    try std.testing.expect(session.metrics.tool_call_count > 0);
    try std.testing.expect(session.metrics.veto_retry_count > 0);
    try std.testing.expectEqual(@as(u32, 1), session.metrics.verified_patch_count);
    try std.testing.expect(approval.calls > 0);

    var saw_read_call = false;
    var saw_read_result = false;
    var saw_failed_veto = false;
    for (session.transcript.entries.items) |entry| switch (entry) {
        .assistant_tool_use => |calls| for (calls) |call| {
            if (std.mem.eql(u8, call.name, "workspace_read_file")) saw_read_call = true;
        },
        .tool_result => |result| {
            if (std.mem.eql(u8, result.tool_name, "workspace_read_file")) saw_read_result = true;
            if (!result.ok) saw_failed_veto = true;
        },
        else => {},
    };
    try std.testing.expect(saw_read_call);
    try std.testing.expect(saw_read_result);
    try std.testing.expect(saw_failed_veto);

    const applied = try zts.file_io.readFile(allocator, "handler.ts", 1024 * 1024);
    defer allocator.free(applied);
    try std.testing.expect(std.mem.indexOf(u8, applied, "/health") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied, "req.body") == null);

    const meta_path = try allocator.dupe(
        u8,
        session.meta_path orelse return error.TestUnexpectedResult,
    );
    defer allocator.free(meta_path);
    session.deinit(allocator);

    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);
    try std.testing.expectEqualStrings(
        "local",
        meta.provider orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "LiquidAI/LFM2.5-2.6B-MLX-8bit",
        meta.model orelse return error.TestUnexpectedResult,
    );

    var resumed = try agent.initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_context_files = true,
        .resume_latest = true,
    });
    defer resumed.deinit(allocator);
    try std.testing.expectEqualStrings(
        original_session_id,
        resumed.session_id orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqual(
        agent.Provider.local,
        resumed.activeProvider() orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "LiquidAI/LFM2.5-2.6B-MLX-8bit",
        resumed.currentModel() orelse return error.TestUnexpectedResult,
    );
    try std.testing.expect(resumed.transcript.len() > 0);
}
