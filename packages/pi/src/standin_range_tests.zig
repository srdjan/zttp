//! Data gates for the deterministic stand-in range.

const std = @import("std");
const expert_eval = @import("expert_eval.zig");
const expert_workflow = @import("expert_workflow.zig");
const prompt_catalog = @import("prompts/catalog.zig");
const response_assembler = @import("providers/openai/response_assembler.zig");
const sse_parser = @import("providers/openai/sse_parser.zig");
const playbook = @import("standin/playbook.zig");
const range = @import("standin/range.zig");
const standin_range_doc = @import("standin_range_doc");

const testing = std.testing;

test "stand-in gate: prompt catalog and playbooks map both ways" {
    try testing.expectEqual(prompt_catalog.catalog.len, range.entries.len);

    for (prompt_catalog.catalog) |template| {
        var matches: usize = 0;
        for (range.entries) |entry| {
            if (std.mem.eql(u8, entry.id, template.name)) matches += 1;
        }
        try testing.expectEqual(@as(usize, 1), matches);
    }

    for (range.entries) |entry| {
        try testing.expect(playbook.hasPlaybook(entry.kind));
    }
    for (playbook.kinds) |kind| {
        var matches: usize = 0;
        for (range.entries) |entry| {
            if (entry.kind == kind) matches += 1;
        }
        try testing.expect(matches > 0);
    }

    const explain = range.findById("explain") orelse return error.MissingRangeEntry;
    const review = range.findById("review") orelse return error.MissingRangeEntry;
    try testing.expectEqual(expert_workflow.TaskKind.review_explain, explain.kind);
    try testing.expectEqual(explain.kind, review.kind);
    try testing.expectEqual(@as(usize, 5), playbook.kinds.len);
}

test "stand-in gate: range identity and generated document are current" {
    const computed = range.contentHash();
    try testing.expectEqualStrings(range.content_hash, &computed);
    try testing.expectEqual(@as(usize, 64), range.content_hash.len);

    const rendered = try range.renderDocument(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        standin_range_doc.contents,
        rendered,
    );
}

test "stand-in gate: every range paraphrase routes to its declared kind" {
    var total: usize = 0;
    var correct: usize = 0;
    var misses: usize = 0;
    var misfires: usize = 0;

    for (range.entries) |entry| {
        try testing.expectEqual(entry.kind, expert_workflow.classify(entry.canonical_prompt).kind);
        const canonical_entry = range.findByPrompt(entry.canonical_prompt) orelse return error.MissingCanonicalPrompt;
        try testing.expectEqualStrings(entry.id, canonical_entry.id);
        try testing.expect(entry.paraphrases.len > 0);
        for (entry.paraphrases) |paraphrase| {
            total += 1;
            const routed_entry = range.findByPrompt(paraphrase) orelse return error.MissingParaphrase;
            try testing.expectEqualStrings(entry.id, routed_entry.id);
            const actual = expert_workflow.classify(paraphrase).kind;
            if (actual == entry.kind) {
                correct += 1;
            } else if (range.hasKind(actual)) {
                misfires += 1;
                std.debug.print(
                    "[standin-gate] paraphrase misfire entry={s} expected={s} actual={s} prompt=\"{s}\"\n",
                    .{ entry.id, @tagName(entry.kind), @tagName(actual), paraphrase },
                );
            } else {
                misses += 1;
                std.debug.print(
                    "[standin-gate] paraphrase miss entry={s} expected={s} actual={s} prompt=\"{s}\"\n",
                    .{ entry.id, @tagName(entry.kind), @tagName(actual), paraphrase },
                );
            }
        }
    }

    std.debug.print(
        "[standin-gate] paraphrase-routing {d}/{d} correct; misses={d}; misfires={d}\n",
        .{ correct, total, misses, misfires },
    );
    try testing.expectEqual(total, correct);
    try testing.expectEqual(@as(usize, 0), misses);
    try testing.expectEqual(@as(usize, 0), misfires);
}

test "stand-in gate: shared review kind keeps each entry behavior" {
    for (range.entries) |entry| {
        if (entry.kind != .review_explain) continue;
        const expected_tool = if (std.mem.eql(u8, entry.id, "review"))
            "workspace_read_file"
        else
            "zts_expert_modules";
        for (entry.paraphrases) |paraphrase| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const body = try playbook.renderResponse(allocator, .{
                .ask = paraphrase,
                .step_index = 0,
                .source = "",
            });
            const events = try sse_parser.parseAll(allocator, body);
            const outcome = try response_assembler.assemble(allocator, events);
            switch (outcome.reply.response) {
                .tool_calls => |calls| {
                    try testing.expectEqual(@as(usize, 1), calls.len);
                    try testing.expectEqualStrings(expected_tool, calls[0].name);
                },
                else => return error.ExpectedToolCall,
            }
        }
    }
}

test "stand-in gate: negative corpus stays outside the declared range" {
    for (range.negative_corpus) |negative| {
        const eval_case = findEvalCase(negative.id) orelse return error.MissingNegativeEvalCase;
        try testing.expectEqualStrings(eval_case.prompt, negative.prompt);
        try testing.expectEqual(eval_case.expected_kind, negative.expected_kind);
        try testing.expectEqual(negative.expected_kind, expert_workflow.classify(negative.prompt).kind);
        try testing.expect(!range.hasKind(negative.expected_kind));
    }
}

test "stand-in gate: negative corpus dispatches to misses without edit instructions" {
    var false_fires: usize = 0;
    for (range.negative_corpus) |negative| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const body = try playbook.renderResponse(allocator, .{
            .ask = negative.prompt,
            .step_index = 0,
            .source = "function handler(req: Request): Response { return Response.json({ ok: true }); }\n",
        });
        const events = try sse_parser.parseAll(allocator, body);
        const outcome = try response_assembler.assemble(allocator, events);
        switch (outcome.reply.response) {
            .final_text => |reply| {
                if (std.mem.indexOf(u8, reply, "[standin-miss]") == null) false_fires += 1;
            },
            else => false_fires += 1,
        }
    }

    std.debug.print(
        "[standin-gate] non-socket false-fire {d}/{d}; required=0\n",
        .{ false_fires, range.negative_corpus.len },
    );
    try testing.expectEqual(@as(usize, 0), false_fires);
}

test "stand-in gate: playbooks call facts first and apply at most one edit last" {
    const SequenceCase = struct {
        entry_id: []const u8,
        tools: []const []const u8,
    };
    const cases = [_]SequenceCase{
        .{ .entry_id = "explain", .tools = &.{"zts_expert_modules"} },
        .{ .entry_id = "review", .tools = &.{"workspace_read_file"} },
        .{ .entry_id = "add-route", .tools = &.{ "workspace_read_file", "zts_expert_modules", "apply_edit" } },
        .{ .entry_id = "add-env", .tools = &.{ "zts_expert_modules", "workspace_read_file", "apply_edit" } },
        .{ .entry_id = "write-test", .tools = &.{ "workspace_read_file", "zts_expert_verify_paths", "workspace_read_file", "apply_edit" } },
        .{ .entry_id = "fix", .tools = &.{ "zts_expert_verify_paths", "pi_repair_plan", "workspace_read_file", "apply_edit" } },
    };

    for (cases) |case| {
        const entry = range.findById(case.entry_id) orelse return error.MissingRangeEntry;
        var apply_edits: usize = 0;
        for (case.tools, 0..) |expected_tool, step_index| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const body = try playbook.renderResponse(allocator, .{
                .ask = entry.canonical_prompt,
                .step_index = step_index,
                .source = sequenceSource(entry.id),
            });
            const events = try sse_parser.parseAll(allocator, body);
            const outcome = try response_assembler.assemble(allocator, events);
            switch (outcome.reply.response) {
                .tool_calls => |calls| {
                    try testing.expectEqual(@as(usize, 1), calls.len);
                    try testing.expectEqualStrings(expected_tool, calls[0].name);
                },
                else => return error.ExpectedToolCall,
            }
            if (std.mem.eql(u8, expected_tool, "apply_edit")) {
                apply_edits += 1;
                try testing.expectEqual(case.tools.len - 1, step_index);
            }
        }

        switch (entry.action) {
            .answer => try testing.expectEqual(@as(usize, 0), apply_edits),
            .edit => try testing.expectEqual(@as(usize, 1), apply_edits),
        }

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const body = try playbook.renderResponse(allocator, .{
            .ask = entry.canonical_prompt,
            .step_index = case.tools.len,
            .source = sequenceSource(entry.id),
        });
        const events = try sse_parser.parseAll(allocator, body);
        const outcome = try response_assembler.assemble(allocator, events);
        switch (outcome.reply.response) {
            .final_text => |text| switch (entry.action) {
                .answer => try testing.expect(text.len >= 120),
                .edit => try testing.expect(text.len > 0),
            },
            else => return error.ExpectedFinalText,
        }
    }
}

fn findEvalCase(name: []const u8) ?*const expert_eval.EvalCase {
    for (&expert_eval.cases) |*case| {
        if (std.mem.eql(u8, case.name, name)) return case;
    }
    return null;
}

fn sequenceSource(entry_id: []const u8) []const u8 {
    if (std.mem.eql(u8, entry_id, "add-env")) {
        return "function handler(req: Request): Response { return Response.json({ ok: true }); }\n";
    }
    if (std.mem.eql(u8, entry_id, "fix")) {
        return
        \\import { validateJson } from "zttp:validate";
        \\
        \\function handler(req: Request): Response {
        \\    const result = validateJson("item", req.body);
        \\    const data = result.value;
        \\    return Response.json({ data });
        \\}
        \\
        ;
    }
    if (std.mem.eql(u8, entry_id, "explain") or std.mem.eql(u8, entry_id, "review")) {
        return "function handler(req: Request): Response { return Response.json({ ok: true }); }\n";
    }
    return
    \\{"type":"test","name":"GET / returns 200"}
    \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
    \\{"type":"expect","status":200,"bodyContains":"ok"}
    \\
    ;
}
