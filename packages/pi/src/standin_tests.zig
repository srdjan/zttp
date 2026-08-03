//! End-to-end proof for the deterministic OpenAI wire stand-in.

const std = @import("std");
const agent = @import("agent.zig");
const app = @import("app.zig");
const expert_persona = @import("expert_persona.zig");
const expert_workflow = @import("expert_workflow.zig");
const loop = @import("loop.zig");
const openai_client = @import("providers/openai/client.zig");
const response_assembler = @import("providers/openai/response_assembler.zig");
const sse_parser = @import("providers/openai/sse_parser.zig");
const apply_edit = @import("providers/anthropic/apply_edit.zig");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const transcript_mod = @import("transcript.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("test_support/cwd.zig");
const playbook = @import("standin/playbook.zig");
const request = @import("standin/request.zig");
const range = @import("standin/range.zig");
const server_mod = @import("standin/server.zig");
const veto = @import("veto.zig");
const zts = @import("zts");

comptime {
    _ = request;
    _ = playbook;
    _ = server_mod;
    _ = @import("standin_main.zig");
    _ = @import("standin_range_tests.zig");
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

    var server = try server_mod.Server.init(allocator, 0, null);
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

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
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
    try server.stop();

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
    var server = try server_mod.Server.init(allocator, 0, null);
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
        "Protect this handler with bearer JWT auth",
        .{
            .workspace_root = tmp.abs_path,
            .max_attempts = 1,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.stop();

    try testing.expect(!result.applied_edit);
    try testing.expect(transcriptContains(&session.transcript, "[standin-miss]"));
    const handler_path = try tmp.childPath(allocator, "handler.ts");
    try testing.expectError(error.FileNotFound, zts.file_io.readFile(allocator, handler_path, 1024));
}

test "stand-in gate: every range entry completes through the real agent loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var passed: usize = 0;
    for (range.entries) |entry| {
        try runCoverageCase(allocator, entry);
        passed += 1;
    }

    std.debug.print("[standin-gate] coverage {d}/{d} entries green\n", .{ passed, range.entries.len });
    try testing.expectEqual(range.entries.len, passed);
}

test "stand-in gate: out-of-range asks have zero false fires through the real loop" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Same reason as the non-socket gate: 0/0 is indistinguishable from a
    // clean run, so the corpus must be known non-empty first.
    try testing.expect(range.negative_corpus.len >= 4);
    var false_fires: usize = 0;
    for (range.negative_corpus, 0..) |negative, index| {
        const label = try std.fmt.allocPrint(allocator, "standin-negative-{d}", .{index});
        var tmp = try IsolatedTmp.init(allocator, label);
        defer tmp.cleanup(allocator);
        const original = "function handler(req: Request): Response {\n    return Response.json({ ok: true });\n}\n";
        try tmp.writeFile(allocator, "handler.ts", original);

        var server = try server_mod.Server.init(allocator, 0, null);
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

        const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
        defer restoreCwd(saved_cwd);
        try std.Io.Threaded.chdir(tmp.abs_path);

        const result = try loop.runTurnWith(
            allocator,
            session.modelClient(),
            &registry,
            &session.transcript,
            negative.prompt,
            .{
                .workspace_root = tmp.abs_path,
                .max_attempts = 1,
                .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
                .replay_mode = false,
                .turn_timeout_ms = 0,
            },
        );
        try server.stop();

        const handler_path = try tmp.childPath(allocator, "handler.ts");
        const current = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
        if (result.applied_edit or !std.mem.eql(u8, current, original) or
            !transcriptContains(&session.transcript, "[standin-miss]"))
        {
            false_fires += 1;
        }
    }

    std.debug.print(
        "[standin-gate] false-fire {d}/{d}; required=0\n",
        .{ false_fires, range.negative_corpus.len },
    );
    try testing.expectEqual(@as(usize, 0), false_fires);
}

test "stand-in gate: every edit draft passes the real parser and compiler veto" {
    const DraftCase = struct {
        ask: []const u8,
        step_index: usize,
        source: []const u8,
        file: []const u8,
        must_contain: []const u8,
    };
    const normal_handler = "function handler(req: Request): Response {\n    return Response.json({ ok: true });\n}\n";
    const jsonl_tests =
        \\{"type":"test","name":"GET / returns 200"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":200,"bodyContains":"ok"}
        \\
    ;
    const violation_handler =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\    const result = validateJson("item", req.body);
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const cases = [_]DraftCase{
        .{
            .ask = "Create a handler in handler.ts that responds to GET /health with Response.json({ ok: true }).",
            // add-route dry-runs at 3 and applies at 4; both send the same bytes.
            .step_index = 4,
            .source = normal_handler,
            .file = "handler.ts",
            .must_contain = "\"GET /health\": handleGetHealth",
        },
        .{
            .ask = "Add the APP_NAME environment variable to handler.ts",
            .step_index = 2,
            .source = normal_handler,
            .file = "handler.ts",
            .must_contain = "env(\"APP_NAME\")",
        },
        .{
            .ask = "Write test case for the successful health response",
            .step_index = 3,
            .source = jsonl_tests,
            .file = "handler.test.jsonl",
            .must_contain = "GET /health returns 200",
        },
        .{
            .ask = "Fix the ZTS300 compiler error in handler.ts",
            .step_index = 3,
            .source = violation_handler,
            .file = "handler.ts",
            .must_contain = "if (!result.ok)",
        },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const body = try playbook.renderResponse(allocator, .{
            .ask = case.ask,
            .step_index = case.step_index,
            .source = case.source,
        });
        const events = try sse_parser.parseAll(allocator, body);
        const outcome = try response_assembler.assemble(allocator, events);
        const reply = try apply_edit.maybeRemap(allocator, outcome.reply, outcome.stop_reason);
        switch (reply.response) {
            .edit => |edit| {
                try testing.expectEqualStrings(case.file, edit.file);
                try testing.expectEqualStrings(case.source, edit.before orelse return error.MissingBeforeContent);
                try testing.expect(std.mem.indexOf(u8, edit.content, case.must_contain) != null);
                var veto_result = try veto.runVeto(allocator, edit);
                defer veto_result.deinit(allocator);
                try testing.expect(veto_result.outcome.ok);
                try testing.expectEqual(@as(u32, 0), veto_result.report.new);
                if (std.mem.endsWith(u8, case.file, ".jsonl")) {
                    try expectValidJsonLines(allocator, edit.content);
                }
            },
            else => return error.ExpectedEdit,
        }
    }
}

test "stand-in review reports source observations without a compiler verdict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response {
        \\    const result = validateJson("item", req.body);
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const body = try playbook.renderResponse(allocator, .{
        .ask = "Review handler.ts for correctness and compiler compliance",
        .step_index = 1,
        .source = source,
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    switch (outcome.reply.response) {
        .final_text => |text| {
            try testing.expect(std.mem.indexOf(u8, text, "missing visible `result.ok` guard") != null);
            try testing.expect(std.mem.indexOf(u8, text, "did not run the compiler") != null);
        },
        else => return error.ExpectedFinalText,
    }
}

test "stand-in environment edit preserves existing handler source and passes the veto" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\// KEEP: application-specific response marker
        \\function handler(req: Request): Response {
        \\    const marker = "preserve-me";
        \\    return Response.json({ marker, ok: true });
        \\}
        \\
    ;
    const body = try playbook.renderResponse(allocator, .{
        .ask = "Add the APP_NAME environment variable to handler.ts",
        .step_index = 2,
        .source = source,
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    const reply = try apply_edit.maybeRemap(allocator, outcome.reply, outcome.stop_reason);
    switch (reply.response) {
        .edit => |edit| {
            try testing.expectEqualStrings(source, edit.before orelse return error.MissingBeforeContent);
            try testing.expect(std.mem.indexOf(u8, edit.content, "// KEEP: application-specific response marker") != null);
            try testing.expect(std.mem.indexOf(u8, edit.content, "const marker = \"preserve-me\";") != null);
            try testing.expect(std.mem.indexOf(u8, edit.content, "import { env } from \"zttp:env\";") != null);
            const env_read = std.mem.indexOf(u8, edit.content, "env(\"APP_NAME\");") orelse return error.MissingEnvironmentRead;
            const marker = std.mem.indexOf(u8, edit.content, "const marker = \"preserve-me\";") orelse return error.MissingMarker;
            try testing.expect(env_read < marker);
            var veto_result = try veto.runVeto(allocator, edit);
            defer veto_result.deinit(allocator);
            try testing.expect(veto_result.outcome.ok);
            try testing.expectEqual(@as(u32, 0), veto_result.report.new);
        },
        else => return error.ExpectedEdit,
    }
}

test "stand-in environment edit returns a miss for unsupported handler sources" {
    const Case = struct {
        source: []const u8,
        reason: []const u8,
    };
    const cases = [_]Case{
        .{
            .source = "const noHandler = true;\n",
            .reason = "no supported `function handler` body",
        },
        .{
            .source =
            \\import { env } from "zttp:env";
            \\import { env as readEnv } from "zttp:env";
            \\
            \\function handler(req: Request): Response {
            \\    return Response.json({ ok: true });
            \\}
            \\
            ,
            .reason = "conflicting `zttp:env` import",
        },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const body = try playbook.renderResponse(allocator, .{
            .ask = "Add the APP_NAME environment variable to handler.ts",
            .step_index = 2,
            .source = case.source,
        });
        const events = try sse_parser.parseAll(allocator, body);
        const outcome = try response_assembler.assemble(allocator, events);
        switch (outcome.reply.response) {
            .final_text => |text| {
                try testing.expect(std.mem.indexOf(u8, text, "[standin-miss]") != null);
                try testing.expect(std.mem.indexOf(u8, text, case.reason) != null);
            },
            else => return error.ExpectedFinalText,
        }
    }
}

test "stand-in violation fix preserves source around the inserted guard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\import { validateJson } from "zttp:validate";
        \\
        \\// KEEP: application-specific validation behavior
        \\function handler(req: Request): Response {
        \\    const result = validateJson("item", req.body);
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const expected =
        \\import { validateJson } from "zttp:validate";
        \\
        \\// KEEP: application-specific validation behavior
        \\function handler(req: Request): Response {
        \\    const result = validateJson("item", req.body);
        \\    if (!result.ok) {
        \\        return Response.json({ error: result.error }, { status: 400 });
        \\    }
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const body = try playbook.renderResponse(allocator, .{
        .ask = "Fix the ZTS300 compiler error in handler.ts",
        .step_index = 3,
        .source = source,
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    const reply = try apply_edit.maybeRemap(allocator, outcome.reply, outcome.stop_reason);
    switch (reply.response) {
        .edit => |edit| {
            try testing.expectEqualStrings(expected, edit.content);
            var veto_result = try veto.runVeto(allocator, edit);
            defer veto_result.deinit(allocator);
            try testing.expect(veto_result.outcome.ok);
            try testing.expectEqual(@as(u32, 0), veto_result.report.new);
        },
        else => return error.ExpectedEdit,
    }
}

test "stand-in violation fix returns a miss for an already guarded source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response {
        \\    const result = validateJson("item", req.body);
        \\    if (!result.ok) {
        \\        return Response.json({ error: result.error }, { status: 400 });
        \\    }
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const body = try playbook.renderResponse(allocator, .{
        .ask = "Fix the ZTS300 compiler error in handler.ts",
        .step_index = 3,
        .source = source,
    });
    const events = try sse_parser.parseAll(allocator, body);
    const outcome = try response_assembler.assemble(allocator, events);
    switch (outcome.reply.response) {
        .final_text => |text| {
            try testing.expect(std.mem.indexOf(u8, text, "[standin-miss]") != null);
            try testing.expect(std.mem.indexOf(u8, text, "already has a visible `result.ok` guard") != null);
        },
        else => return error.ExpectedFinalText,
    }
}

fn runCoverageCase(allocator: std.mem.Allocator, entry: range.Entry) !void {
    const label = try std.fmt.allocPrint(allocator, "standin-range-{s}", .{entry.id});
    var tmp = try IsolatedTmp.init(allocator, label);
    defer tmp.cleanup(allocator);

    const original_handler = switch (entry.kind) {
        .violation_fix =>
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\    const result = validateJson("item", req.body);
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
        ,
        else => "function handler(req: Request): Response {\n    return Response.json({ ok: true });\n}\n",
    };
    try tmp.writeFile(allocator, "handler.ts", original_handler);

    const original_tests =
        \\{"type":"test","name":"GET / returns 200"}
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"expect","status":200,"bodyContains":"ok"}
        \\
    ;
    if (std.mem.eql(u8, entry.id, "write-test")) {
        try tmp.writeFile(allocator, "handler.test.jsonl", original_tests);
    }

    var server = try server_mod.Server.init(allocator, 0, null);
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

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer restoreCwd(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);

    const result = try loop.runTurnWith(
        allocator,
        session.modelClient(),
        &registry,
        &session.transcript,
        entry.canonical_prompt,
        .{
            .workspace_root = tmp.abs_path,
            .max_attempts = 1,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.stop();

    try testing.expectEqual(entry.kind, result.workflow_kind);
    try testing.expect(!transcriptContains(&session.transcript, "[standin-miss]"));

    const handler_path = try tmp.childPath(allocator, "handler.ts");
    const handler = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    switch (entry.action) {
        .answer => {
            try testing.expect(!result.applied_edit);
            try testing.expectEqualStrings(original_handler, handler);
            try testing.expect(transcriptContains(&session.transcript, "deterministic playbook server"));
            try testing.expect(transcriptTextBytes(&session.transcript) >= 120);
        },
        .edit => {
            try testing.expect(result.applied_edit);
            try testing.expect(result.first_draft_veto_pass);
            if (std.mem.eql(u8, entry.id, "add-route")) {
                try testing.expect(std.mem.indexOf(u8, handler, "\"GET /health\": handleGetHealth") != null);
            } else if (std.mem.eql(u8, entry.id, "add-env")) {
                try testing.expect(std.mem.indexOf(u8, handler, "from \"zttp:env\"") != null);
                try testing.expect(std.mem.indexOf(u8, handler, "env(\"APP_NAME\")") != null);
            } else if (std.mem.eql(u8, entry.id, "write-test")) {
                try testing.expectEqualStrings(original_handler, handler);
                const tests_path = try tmp.childPath(allocator, "handler.test.jsonl");
                const tests = try zts.file_io.readFile(allocator, tests_path, 1024 * 1024);
                try testing.expect(std.mem.indexOf(u8, tests, "GET /health returns 200") != null);
                try expectValidJsonLines(allocator, tests);
            } else if (std.mem.eql(u8, entry.id, "fix")) {
                try testing.expect(std.mem.indexOf(u8, handler, "if (!result.ok)") != null);
                try testing.expect(std.mem.indexOf(u8, handler, "result.error") != null);
            } else {
                return error.UncheckedRangeEntry;
            }
        },
    }
}

fn expectValidJsonLines(allocator: std.mem.Allocator, content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var parsed_lines: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try testing.expectEqual(std.json.Value.object, std.meta.activeTag(parsed.value));
        parsed_lines += 1;
    }
    try testing.expect(parsed_lines >= 6);
}

fn transcriptTextBytes(transcript: *const transcript_mod.Transcript) usize {
    var count: usize = 0;
    for (transcript.entries.items) |entry| {
        switch (entry) {
            .model_text => |value| count += value.len,
            .diagnostic_box => |value| count += value.llm_text.len,
            else => {},
        }
    }
    return count;
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

fn restoreCwd(path: []const u8) void {
    std.Io.Threaded.chdir(path) catch |err| {
        std.debug.panic("failed to restore test cwd: {s}", .{@errorName(err)});
    };
}
