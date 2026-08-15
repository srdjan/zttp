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
const defect_seeds = @import("standin/defect_seeds.zig");
const hole_seeds = @import("standin/hole_seeds.zig");
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
        .{ .base_url = endpoint },
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

/// Drive one defect seed through the real server, the real loop, and the real
/// veto in its own workspace, and hand back the turn result plus the bytes on
/// disk afterwards.
fn runSeedArm(
    allocator: std.mem.Allocator,
    seed: *const defect_seeds.DefectSeed,
) !struct { result: loop.TurnResult, on_disk: []u8 } {
    var tmp = try IsolatedTmp.init(allocator, "standin-seed");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts", seed.seed_source);

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
        .{ .base_url = endpoint },
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
        seed.ask,
        .{
            .workspace_root = tmp.abs_path,
            // The retry arm needs at least two, and this is the only place in
            // the stand-in suite that spends a second attempt.
            .max_attempts = 3,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.stop();

    const handler_path = try tmp.childPath(allocator, "handler.ts");
    const on_disk = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    return .{ .result = result, .on_disk = on_disk };
}

// The rejection half of the loop, offline for the first time. Every stand-in
// draft before this was authored to pass the same veto that judges it, so a
// failed tool result, the retry nudge, and the second draft that follows were
// reachable only by spending live model turns.
//
// The negative observables carry these gates. `applied_edit` alone is satisfied
// by a first draft that simply passed, which is precisely the arm not running.
test "stand-in seeded arm: a rejected draft is repaired on the retry round trip" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var checked: usize = 0;
    for (&defect_seeds.seeds) |*seed| {
        if (seed.class != .model_retry) continue;
        checked += 1;

        const run = try runSeedArm(allocator, seed);
        try testing.expect(!run.result.first_draft_veto_pass);
        try testing.expectEqual(@as(u32, 1), run.result.veto_retry_count);
        try testing.expect(run.result.applied_edit);
        try testing.expectEqualStrings(seed.good_draft, run.on_disk);
    }

    // Floor: a class emptied upstream would leave this loop iterating nothing
    // and reporting a clean run over no rejection at all.
    try testing.expect(checked >= 2);
    std.debug.print("[standin-gate] seeded retry arm {d}/{d} seeds\n", .{ checked, checked });
}

test "stand-in seeded arm: compiler repair lands without a model retry" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var checked: usize = 0;
    for (&defect_seeds.seeds) |*seed| {
        if (seed.class != .compiler_repair) continue;
        checked += 1;

        const run = try runSeedArm(allocator, seed);
        try testing.expect(!run.result.first_draft_veto_pass);
        try testing.expect(run.result.compiler_authored_apply);
        try testing.expectEqual(@as(u32, 0), run.result.veto_retry_count);
        // Four loopback wire turns gather facts and submit the bad draft. The
        // compiler repair lands immediately after that rejection, with no fifth
        // turn asking a model to redraft it.
        try testing.expectEqual(@as(u8, 4), run.result.roundtrips);
        try testing.expect(run.result.applied_edit);
        try testing.expectEqualStrings(seed.good_draft, run.on_disk);
    }

    try testing.expect(checked >= 2);
    std.debug.print("[standin-gate] compiler repair arm {d}/{d} seeds\n", .{ checked, checked });
}

// Salvage is the other half, and it is a different claim: the draft is rejected
// by the checker and rescued by normalization, so the model never sees a
// rejection and the turn still counts as a first-draft pass. Asserting
// `veto_retry_count == 0` is what separates the two arms; without it a seed that
// quietly started being retried would pass here.
test "stand-in seeded arm: a canonical slip is salvaged without a retry" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var checked: usize = 0;
    for (&defect_seeds.seeds) |*seed| {
        if (seed.class != .salvaged) continue;
        checked += 1;

        const run = try runSeedArm(allocator, seed);
        try testing.expect(run.result.first_draft_veto_pass);
        try testing.expectEqual(@as(u32, 0), run.result.veto_retry_count);
        try testing.expect(run.result.applied_edit);

        // The exact claim, not "different from these bytes". A gate asserting
        // only difference passes when the arm submits a clean draft and no
        // salvage happens at all - which is the opposite of what it reports, and
        // is what the probe found. The bytes on disk must be precisely what
        // normalizing the bad draft produces.
        var normalized = try veto.runVeto(allocator, .{
            .file = "handler.ts",
            .content = seed.bad_draft,
            .before = seed.seed_source,
        });
        defer normalized.deinit(allocator);
        const canonical = normalized.report.normalized_content orelse {
            std.debug.print("[standin-gate] seed {s}: nothing was normalized\n", .{seed.id});
            return error.SeedNotSalvaged;
        };
        try testing.expectEqualStrings(canonical, run.on_disk);
        try testing.expect(!std.mem.eql(u8, run.on_disk, seed.bad_draft));
    }

    try testing.expect(checked >= 2);
    std.debug.print("[standin-gate] seeded salvage arm {d}/{d} seeds\n", .{ checked, checked });
}

// The arm fires on the code named in the ask, so it must refuse when the file is
// not the seed's own. Otherwise an ask mentioning ZTS604 would make the stand-in
// overwrite whatever handler happened to be there with a seed's defect.
test "stand-in seeded arm: a foreign source gets a miss, not a scripted defect" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seed = defect_seeds.findById("let-binding") orelse return error.MissingSeed;
    const foreign = "function handler(req: Request): Response & Spec<\"deterministic\"> {\n  const other = 7;\n  return Response.json({ other });\n}\n";

    var tmp = try IsolatedTmp.init(allocator, "standin-seed-foreign");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts", foreign);

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
        .{ .base_url = endpoint },
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
        seed.ask,
        .{
            .workspace_root = tmp.abs_path,
            .max_attempts = 3,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        },
    );
    try server.stop();

    try testing.expect(!result.applied_edit);
    const handler_path = try tmp.childPath(allocator, "handler.ts");
    const on_disk = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    try testing.expectEqualStrings(foreign, on_disk);
}

// The seed table has to describe the sources it carries, or a seed edited from
// two holes to one keeps its name and quietly stops testing what the name says.
test "stand-in hole seeds declare the holes their sources carry" {
    try testing.expect(hole_seeds.seeds.len >= 2);
    var with_two: usize = 0;
    for (hole_seeds.seeds) |seed| {
        try testing.expectEqual(seed.holes, hole_seeds.countHoles(seed.source));
        try testing.expectEqual(seed.holes, seed.expressions.len);
        const first_expression = try hole_seeds.nextExpressionForSource(testing.allocator, &seed, seed.source);
        try testing.expectEqualStrings(seed.expressions[0], first_expression.?);
        const selected = try hole_seeds.findBySource(testing.allocator, seed.source) orelse
            return error.HoleSeedSourceSelectsNothing;
        try testing.expectEqualStrings(seed.id, selected.id);
        try testing.expectEqual(
            expert_workflow.TaskKind.hole_fill,
            expert_workflow.classify(seed.ask).kind,
        );
        if (seed.holes >= 2) with_two += 1;
    }
    // The multi-turn composition gate below needs a multi-hole seed to exist.
    try testing.expect(with_two >= 1);

    const single = hole_seeds.findById("single-hole") orelse return error.MissingHoleSeed;
    const foreign =
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\  const other = 9;
        \\  return hole();
        \\}
    ;
    try testing.expect(try hole_seeds.nextExpressionForSource(testing.allocator, single, foreign) == null);
    try testing.expect(try hole_seeds.findBySource(testing.allocator, foreign) == null);
}

test "stand-in hole arm: two one-fill turns compose through publisher and apply" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seed = hole_seeds.findById("two-holes") orelse return error.MissingHoleSeed;
    const entry = range.findById("fill-hole") orelse return error.MissingRangeEntry;
    try testing.expectEqual(@as(usize, 2), entry.paraphrases.len);
    var tmp = try IsolatedTmp.init(allocator, "standin-hole-compose");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "handler.ts", seed.source);

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
        .{ .base_url = endpoint },
    );
    defer session.deinit(allocator);

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer restoreCwd(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);

    const options: loop.RunOptions = .{
        .workspace_root = tmp.abs_path,
        .max_attempts = 1,
        .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
        .replay_mode = false,
        .turn_timeout_ms = 0,
    };
    const first = try loop.runTurnWith(
        allocator,
        session.modelClient(),
        &registry,
        &session.transcript,
        entry.paraphrases[0],
        options,
    );
    try testing.expect(first.applied_edit);
    try testing.expectEqual(@as(u8, 4), first.roundtrips);

    const handler_path = try tmp.childPath(allocator, "handler.ts");
    const after_first = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    try testing.expectEqual(@as(usize, 1), hole_seeds.countHoles(after_first));
    try testing.expect(std.mem.indexOf(u8, after_first, seed.expressions[0]) != null);

    const second = try loop.runTurnWith(
        allocator,
        session.modelClient(),
        &registry,
        &session.transcript,
        entry.paraphrases[1],
        options,
    );
    try server.stop();
    try testing.expect(second.applied_edit);
    try testing.expectEqual(@as(u8, 4), second.roundtrips);

    const after_second = try zts.file_io.readFile(allocator, handler_path, 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), hole_seeds.countHoles(after_second));
    for (seed.expressions) |expression| {
        try testing.expect(std.mem.indexOf(u8, after_second, expression) != null);
    }
    try testing.expectEqual(@as(usize, 2), transcriptToolResultCount(&session.transcript, "zts_expert_holes"));

    // The second publisher result must describe the file after the first fill,
    // not replay the original two-hole frame. Its remaining hole is the return
    // expression on line 4, and the first fill makes `label` available as an
    // unannotated binding there.
    const second_frame = transcriptToolResultAt(&session.transcript, "zts_expert_holes", 1) orelse
        return error.MissingSecondHoleFrame;
    var parsed_frame = try std.json.parseFromSlice(std.json.Value, allocator, second_frame, .{});
    defer parsed_frame.deinit();
    if (parsed_frame.value != .object) return error.InvalidSecondHoleFrame;
    const holes = parsed_frame.value.object.get("holes") orelse return error.MissingSecondHoleFrameHoles;
    if (holes != .array) return error.InvalidSecondHoleFrameHoles;
    try testing.expectEqual(@as(usize, 1), holes.array.items.len);
    const hole = holes.array.items[0];
    if (hole != .object) return error.InvalidSecondHoleFrameHole;
    const line = hole.object.get("line") orelse return error.MissingSecondHoleFrameLine;
    const column = hole.object.get("column") orelse return error.MissingSecondHoleFrameColumn;
    if (line != .integer or column != .integer) return error.InvalidSecondHoleFrameCoordinates;
    try testing.expectEqual(@as(i64, 4), line.integer);
    try testing.expectEqual(@as(i64, 10), column.integer);
    try testing.expectEqualStrings("unknown", holeFrameBindingType(hole.object, "label") orelse
        return error.MissingPostFillLabelBinding);
    std.debug.print("[standin-gate] two hole fills compose across two offline turns\n", .{});
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
        .{ .base_url = endpoint },
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
            .{ .base_url = endpoint },
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
        \\    const result = validateJson("item", req.body ?? "");
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
    ;
    const cases = [_]DraftCase{
        .{
            .ask = "Create a handler in handler.ts that responds to GET /health with Response.json({ ok: true }).",
            .step_index = 3,
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
                try testing.expect(std.mem.indexOf(u8, edit.content, case.must_contain) != null);
                var veto_result = try veto.runVeto(allocator, .{
                    .file = edit.file,
                    .content = edit.content,
                    .before = case.source,
                });
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
        \\    const result = validateJson("item", req.body ?? "");
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
            try testing.expect(std.mem.indexOf(u8, edit.content, "// KEEP: application-specific response marker") != null);
            try testing.expect(std.mem.indexOf(u8, edit.content, "const marker = \"preserve-me\";") != null);
            try testing.expect(std.mem.indexOf(u8, edit.content, "import { env } from \"zttp:env\";") != null);
            const env_read = std.mem.indexOf(u8, edit.content, "env(\"APP_NAME\");") orelse return error.MissingEnvironmentRead;
            const marker = std.mem.indexOf(u8, edit.content, "const marker = \"preserve-me\";") orelse return error.MissingMarker;
            try testing.expect(env_read < marker);
            var veto_result = try veto.runVeto(allocator, .{
                .file = edit.file,
                .content = edit.content,
                .before = source,
            });
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
        \\    const result = validateJson("item", req.body ?? "");
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
        \\    const result = validateJson("item", req.body ?? "");
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
            var veto_result = try veto.runVeto(allocator, .{
                .file = edit.file,
                .content = edit.content,
                .before = source,
            });
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
        \\    const result = validateJson("item", req.body ?? "");
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
        // The hole arm needs a hole to fill, and the seed is the same source the
        // dedicated arm tests use, so the two cannot describe different files.
        .hole_fill => (hole_seeds.findById("single-hole") orelse return error.MissingHoleSeed).source,
        .violation_fix =>
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\    const result = validateJson("item", req.body ?? "");
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
        .{ .base_url = endpoint },
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
    if (transcriptContains(&session.transcript, "[standin-miss]")) {
        for (session.transcript.entries.items) |transcript_entry| {
            switch (transcript_entry) {
                .model_text => |value| std.debug.print("[standin-debug] model {s}\n", .{value}),
                .tool_result => |value| std.debug.print("[standin-debug] tool {s}: {s}\n", .{ value.tool_name, value.llm_text }),
                else => {},
            }
        }
        return error.StandinRangeMiss;
    }

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
            } else if (std.mem.eql(u8, entry.id, "fill-hole")) {
                const seed = hole_seeds.findById("single-hole") orelse return error.MissingHoleSeed;
                try testing.expect(std.mem.indexOf(u8, handler, seed.expressions[0]) != null);
                try testing.expectEqual(@as(usize, 0), hole_seeds.countHoles(handler));
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

fn transcriptToolResultCount(
    transcript: *const transcript_mod.Transcript,
    tool_name: []const u8,
) usize {
    var count: usize = 0;
    for (transcript.entries.items) |entry| {
        switch (entry) {
            .tool_result => |result| {
                if (std.mem.eql(u8, result.tool_name, tool_name)) count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn transcriptToolResultAt(
    transcript: *const transcript_mod.Transcript,
    tool_name: []const u8,
    ordinal: usize,
) ?[]const u8 {
    var found: usize = 0;
    for (transcript.entries.items) |entry| {
        switch (entry) {
            .tool_result => |result| {
                if (!std.mem.eql(u8, result.tool_name, tool_name)) continue;
                if (found == ordinal) return result.llm_text;
                found += 1;
            },
            else => {},
        }
    }
    return null;
}

fn holeFrameBindingType(
    hole: std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    const in_scope = hole.get("inScope") orelse return null;
    if (in_scope != .array) return null;
    for (in_scope.array.items) |binding| {
        if (binding != .object) continue;
        const binding_name = binding.object.get("name") orelse continue;
        const binding_type = binding.object.get("type") orelse continue;
        if (binding_name != .string or binding_type != .string) continue;
        if (std.mem.eql(u8, binding_name.string, name)) return binding_type.string;
    }
    return null;
}

fn restoreCwd(path: []const u8) void {
    std.Io.Threaded.chdir(path) catch |err| {
        std.debug.panic("failed to restore test cwd: {s}", .{@errorName(err)});
    };
}
