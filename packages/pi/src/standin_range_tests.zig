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

    // Derived, not a hand-bumped literal. A literal here means "somebody edited
    // a number" after a few rounds of growth; against the covered set it means
    // the playbook and the coverage decision agree.
    try testing.expectEqual(range.covered_kinds.len, playbook.kinds.len);
    for (range.covered_kinds) |kind| {
        try testing.expect(playbook.hasPlaybook(kind));
    }
}

// The range's edge is what the false-fire gates measure, and every one of them
// asserts an absence. Covering a reserved kind deletes the negative that stands
// on it; covering all of them leaves the gates iterating nothing and reporting a
// pass. This is the gate on the decision itself, so growth stays a choice rather
// than a side effect of adding an entry.
test "stand-in gate: every reserved kind stays outside the playbook and the range" {
    // Floor first: an empty reserved set makes every loop below vacuous, and it
    // is the state the range reaches by covering one kind at a time.
    try testing.expect(range.reserved_kinds.len >= 6);

    for (range.reserved_kinds) |kind| {
        try testing.expectEqual(range.Coverage.reserved, range.coverageOf(kind));
        try testing.expect(!range.hasKind(kind));
        try testing.expect(!playbook.hasPlaybook(kind));
    }

    // Both directions, so a kind cannot fall out of both lists. The exhaustive
    // switch already forces a decision per member; this proves the two derived
    // slices partition what it decided.
    const all = std.enums.values(expert_workflow.TaskKind);
    try testing.expectEqual(all.len, range.covered_kinds.len + range.reserved_kinds.len);
    for (all) |kind| {
        const expected: range.Coverage = if (playbook.hasPlaybook(kind)) .covered else .reserved;
        try testing.expectEqual(expected, range.coverageOf(kind));
    }

    std.debug.print(
        "[standin-gate] coverage decision {d} covered, {d} reserved of {d} kinds\n",
        .{ range.covered_kinds.len, range.reserved_kinds.len, all.len },
    );
}

test "stand-in gate: every negative and out-of-range kind is reserved, and every reserved kind keeps a probe" {
    try testing.expect(range.negative_corpus.len >= 4);
    try testing.expect(prompt_grammar.out_of_range.len >= 4);

    for (range.negative_corpus) |negative| {
        try testing.expectEqual(range.Coverage.reserved, range.coverageOf(negative.expected_kind));
    }
    for (prompt_grammar.out_of_range) |grammar| {
        try testing.expectEqual(range.Coverage.reserved, range.coverageOf(grammar.kind));
    }

    // The other direction, and the one that stops the negative side from
    // thinning as the range grows: a reserved kind with nothing probing it is
    // reserved in name only. `unknown` is exempt because it is the classifier's
    // fallback rather than a shape somebody asks for.
    var probed: usize = 0;
    for (range.reserved_kinds) |kind| {
        if (kind == .unknown) continue;
        var claims: usize = 0;
        for (prompt_grammar.out_of_range) |grammar| {
            if (grammar.kind == kind) claims += 1;
        }
        if (claims == 0) {
            std.debug.print(
                "[standin-gate] reserved kind {s} has no out-of-range grammar probing it\n",
                .{@tagName(kind)},
            );
            return error.ReservedKindUnprobed;
        }
        probed += 1;
    }
    try testing.expect(probed >= 5);
    std.debug.print("[standin-gate] reserved probes {d}/{d} kinds\n", .{ probed, probed });
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
    // A zero-length corpus makes every false-fire loop below iterate nothing
    // and report 0/0, which reads exactly like a clean run. Assert the corpus
    // has content before trusting any count taken over it.
    try testing.expect(range.negative_corpus.len >= 4);
    for (range.negative_corpus) |negative| {
        const eval_case = findEvalCase(negative.id) orelse return error.MissingNegativeEvalCase;
        try testing.expectEqualStrings(eval_case.prompt, negative.prompt);
        try testing.expectEqual(eval_case.expected_kind, negative.expected_kind);
        try testing.expectEqual(negative.expected_kind, expert_workflow.classify(negative.prompt).kind);
        try testing.expect(!range.hasKind(negative.expected_kind));
    }
}

test "stand-in gate: negative corpus dispatches to misses without edit instructions" {
    try testing.expect(range.negative_corpus.len >= 4);
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
        .{ .entry_id = "add-route", .tools = &.{ "workspace_read_file", "zts_expert_verify_paths", "zts_expert_modules", "zts_expert_edit_simulate", "apply_edit" } },
        .{ .entry_id = "add-env", .tools = &.{ "zts_expert_modules", "workspace_read_file", "apply_edit" } },
        .{ .entry_id = "write-test", .tools = &.{ "workspace_read_file", "zts_expert_verify_paths", "workspace_read_file", "apply_edit" } },
        .{ .entry_id = "fix", .tools = &.{ "zts_expert_verify_paths", "pi_repair_plan", "workspace_read_file", "apply_edit" } },
    };

    // This is the only gate that checks tool ordering and the at-most-one-edit
    // rule, and it drives a hand-written row list. Without this the seventh
    // range entry would simply have no row and escape the check entirely,
    // while the gate still reported success.
    try testing.expectEqual(range.entries.len, cases.len);

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

// The stand-in test roots are compiled with the test filter pinned to
// "stand-in" (build.zig), so a test whose name omits that token is silently
// skipped while every gate still reports success. Nothing enforced the naming
// rule the filter depends on, so this reads both roots and does.
test "stand-in gate: every test in the stand-in roots is reachable through the pinned filter" {
    const sources = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "standin_tests.zig", .text = @embedFile("standin_tests.zig") },
        .{ .name = "standin_range_tests.zig", .text = @embedFile("standin_range_tests.zig") },
    };

    var checked: usize = 0;
    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        while (lines.next()) |line| {
            // Only declarations at column zero; a needle inside a string
            // literal (such as the one on this line) is not a declaration.
            if (!std.mem.startsWith(u8, line, "test \"")) continue;
            checked += 1;
            if (std.mem.indexOf(u8, line, "stand-in") == null) {
                std.debug.print(
                    "[standin-gate] {s}: test name omits \"stand-in\" and would never run: {s}\n",
                    .{ source.name, line },
                );
                return error.TestNameEscapesPinnedFilter;
            }
        }
    }

    // Guards the guard: an @embedFile that silently resolved to nothing would
    // otherwise make this pass while checking no declarations at all.
    try testing.expect(checked >= 15);
    std.debug.print("[standin-gate] filter reachability {d}/{d} test names\n", .{ checked, checked });
}

const prompt_grammar = @import("standin/prompt_grammar.zig");

test "stand-in gate: generated paraphrases route to their own range entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Floor first: an empty grammar set would make every loop below iterate
    // zero times and report a clean run over nothing.
    const total = prompt_grammar.totalIn(&prompt_grammar.in_range);
    try testing.expect(total >= 200);
    try testing.expectEqual(range.entries.len, prompt_grammar.in_range.len);

    // Equal lengths plus a findById that resolves is not one-grammar-per-entry:
    // two grammars sharing an id satisfy both while leaving a range entry with
    // no generated coverage at all. Assert every entry is claimed exactly once.
    for (range.entries) |entry| {
        var claims: usize = 0;
        for (prompt_grammar.in_range) |g| {
            if (std.mem.eql(u8, g.id, entry.id)) claims += 1;
        }
        try testing.expectEqual(@as(usize, 1), claims);
    }

    var checked: usize = 0;
    var misroutes: usize = 0;
    for (prompt_grammar.in_range) |grammar| {
        const entry = range.findById(grammar.id) orelse return error.MissingRangeEntry;
        try testing.expectEqual(entry.kind, grammar.kind);
        var i: usize = 0;
        while (i < grammar.count()) : (i += 1) {
            const prompt = try prompt_grammar.generate(allocator, grammar, i);
            checked += 1;
            const hint = expert_workflow.classify(prompt);
            if (hint.kind != grammar.kind) {
                misroutes += 1;
                std.debug.print(
                    "[standin-gate] misroute: \"{s}\" -> {s}, expected {s}\n",
                    .{ prompt, @tagName(hint.kind), @tagName(grammar.kind) },
                );
            }
        }
    }

    // Leads and tails carry no token `classify` searches for, so every
    // lead-by-tail variant of a core is the same routing decision. Report the
    // distinct decisions alongside the rendering count so the headline is not
    // read as breadth the corpus does not have.
    var decisions: usize = 0;
    for (prompt_grammar.in_range) |g| decisions += g.cores.len;
    std.debug.print(
        "[standin-gate] generated routing {d}/{d} renderings correct over {d} distinct cores; misroutes={d}\n",
        .{ checked - misroutes, checked, decisions, misroutes },
    );
    try testing.expectEqual(total, checked);
    try testing.expectEqual(@as(usize, 0), misroutes);
}

test "stand-in gate: generated out-of-range prompts never reach a playbook" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const total = prompt_grammar.totalIn(&prompt_grammar.out_of_range);
    try testing.expect(total >= 100);

    var checked: usize = 0;
    var false_fires: usize = 0;
    for (prompt_grammar.out_of_range) |grammar| {
        // The kind must be one the stand-in has no playbook for, or this
        // grammar is testing the wrong thing.
        try testing.expect(!playbook.hasPlaybook(grammar.kind));
        var i: usize = 0;
        while (i < grammar.count()) : (i += 1) {
            const prompt = try prompt_grammar.generate(allocator, grammar, i);
            checked += 1;
            const hint = expert_workflow.classify(prompt);
            if (hint.kind != grammar.kind) {
                std.debug.print(
                    "[standin-gate] out-of-range prompt drifted: \"{s}\" -> {s}\n",
                    .{ prompt, @tagName(hint.kind) },
                );
                return error.OutOfRangePromptDrifted;
            }
            const reply = try playbook.renderResponse(allocator, .{
                .ask = prompt,
                .step_index = 0,
                .source = "function handler(req: Request): Response { return Response.json({ ok: true }); }\n",
            });
            if (std.mem.indexOf(u8, reply, "[standin-miss]") == null) false_fires += 1;
            // The miss marker alone cannot fail here: renderResponse
            // re-classifies and returns renderMiss for any kind outside the
            // range table, so the counter above is structurally zero and the
            // `hasPlaybook` guard is what carries this gate. Assert the reply
            // is a usable refusal rather than merely a marker, which is the
            // part that can actually regress.
            try testing.expect(std.mem.indexOf(u8, reply, "supported range is") != null);
            try testing.expect(std.mem.indexOf(u8, reply, "apply_edit") == null);
        }
    }

    std.debug.print(
        "[standin-gate] generated out-of-range {d} prompts, all refused; false-fire {d}\n",
        .{ checked, false_fires },
    );
    try testing.expectEqual(total, checked);
    try testing.expectEqual(@as(usize, 0), false_fires);
}

test "stand-in gate: generated prompts stay disjoint from the frozen corpora" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A generated prompt that collides with a canonical range prompt or a
    // pinned negative case would make the routing number partly a measurement
    // of the corpus it is supposed to be independent of.
    var checked: usize = 0;
    for ([_][]const prompt_grammar.Grammar{ &prompt_grammar.in_range, &prompt_grammar.out_of_range }) |set| {
        for (set) |grammar| {
            var i: usize = 0;
            while (i < grammar.count()) : (i += 1) {
                const prompt = try prompt_grammar.generate(allocator, grammar, i);
                checked += 1;
                // Case-insensitive, and paraphrases count too: `classify`
                // matches with `containsFold`, so a core that differs from a
                // frozen prompt only in its first letter is the same routing
                // decision the frozen corpus already makes.
                for (range.entries) |entry| {
                    try testing.expect(!eqlFold(prompt, entry.canonical_prompt));
                    for (entry.paraphrases) |paraphrase| {
                        try testing.expect(!eqlFold(prompt, paraphrase));
                    }
                }
                for (range.negative_corpus) |negative| {
                    try testing.expect(!eqlFold(prompt, negative.prompt));
                }
            }
        }
    }
    try testing.expect(checked >= 300);
    std.debug.print("[standin-gate] disjointness {d} generated prompts\n", .{checked});
}

/// ASCII case-insensitive equality, matching how `classify` compares.
fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}
