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

test "stand-in gate: advertised diagnostic codes exist in the live registry" {
    for (range.entries) |entry| {
        try expectLiveDiagnosticCodes(entry.canonical_prompt);
        for (entry.paraphrases) |paraphrase| try expectLiveDiagnosticCodes(paraphrase);
    }
    for (expert_eval.cases) |case| try expectLiveDiagnosticCodes(case.prompt);
}

fn expectLiveDiagnosticCodes(text: []const u8) !void {
    var index: usize = 0;
    while (index + 3 < text.len) {
        const is_code = std.mem.startsWith(u8, text[index..], "ZTS") or
            std.mem.startsWith(u8, text[index..], "POL");
        if (!is_code) {
            index += 1;
            continue;
        }

        var end = index + 3;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end == index + 3) {
            index += 3;
            continue;
        }
        const code = text[index..end];
        if (zts.PolicyCatalog.findByCode(code) == null) {
            std.debug.print("[standin-gate] advertised diagnostic code is not live: {s}\n", .{code});
            return error.UnknownAdvertisedDiagnostic;
        }
        index = end;
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
            "zts_expert_query";
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
        /// Last tool output visible at each step. Empty for playbooks that only
        /// count round-trips; the hole arm consumes both publisher and fill
        /// results.
        outputs: []const ?[]const u8 = &.{},
    };
    const cases = [_]SequenceCase{
        .{ .entry_id = "explain", .tools = &.{"zts_expert_query"} },
        .{ .entry_id = "review", .tools = &.{"workspace_read_file"} },
        .{ .entry_id = "add-route", .tools = &.{ "workspace_read_file", "zts_expert_verify_paths", "zts_expert_query", "propose_change_set" } },
        .{ .entry_id = "add-env", .tools = &.{ "zts_expert_query", "workspace_read_file", "propose_change_set" } },
        .{ .entry_id = "write-test", .tools = &.{ "workspace_read_file", "zts_expert_verify_paths", "workspace_read_file" } },
        .{ .entry_id = "fix", .tools = &.{ "zts_expert_verify_paths", "pi_repair_plan", "workspace_read_file", "propose_change_set" } },
        .{
            .entry_id = "fill-hole",
            .tools = &.{ "workspace_read_file", "zts_expert_query", "zts_expert_fill_hole", "propose_change_set" },
            .outputs = &.{
                null,
                null,
                "{\"path\":\"handler.ts\",\"holes\":[{\"function\":\"handler\",\"line\":3,\"column\":10}]}",
                "{\"ok\":true,\"applied\":false,\"path\":\"handler.ts\",\"line\":3,\"column\":10,\"expression\":\"Response.json({ total: total })\",\"proposed_content\":\"function handler(req: Request): Proof<Response, \\\"deterministic\\\"> {\\n  const total = 1;\\n  return Response.json({ total: total });\\n}\\n\"}",
            },
        },
    };

    // This is the only gate that checks tool ordering and the at-most-one-edit
    // rule, and it drives a hand-written row list. Without this the seventh
    // range entry would simply have no row and escape the check entirely,
    // while the gate still reported success.
    try testing.expectEqual(range.entries.len, cases.len);

    for (cases) |case| {
        const entry = range.findById(case.entry_id) orelse return error.MissingRangeEntry;
        var propose_change_sets: usize = 0;
        for (case.tools, 0..) |expected_tool, step_index| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const body = try playbook.renderResponse(allocator, .{
                .ask = entry.canonical_prompt,
                .step_index = step_index,
                .source = sequenceSource(entry.id),
                .last_output = if (step_index < case.outputs.len) case.outputs[step_index] else null,
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
            if (std.mem.eql(u8, expected_tool, "propose_change_set")) {
                propose_change_sets += 1;
                try testing.expectEqual(case.tools.len - 1, step_index);
            }
        }

        switch (entry.action) {
            .answer => try testing.expectEqual(@as(usize, 0), propose_change_sets),
            .change_set => try testing.expectEqual(@as(usize, 1), propose_change_sets),
            .blocked => try testing.expectEqual(@as(usize, 0), propose_change_sets),
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
                .change_set => try testing.expect(text.len > 0),
                .blocked => try testing.expect(std.mem.indexOf(u8, text, "source-only") != null),
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
    if (std.mem.eql(u8, entry_id, "fill-hole")) {
        const seed = hole_seeds.findById("single-hole") orelse unreachable;
        return seed.source;
    }
    if (std.mem.eql(u8, entry_id, "add-env")) {
        return "function handler(req: Request): Response { return Response.json({ ok: true }); }\n";
    }
    if (std.mem.eql(u8, entry_id, "fix")) {
        return (defect_seeds.findById("unchecked-result") orelse unreachable).seed_source;
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
    // Every module compiled into the root, not only the two roots themselves.
    // The filter is applied to the whole test binary, so a test in
    // `standin/playbook.zig` named without the needle is skipped just as
    // silently - and those modules carry a third of the tests here.
    //
    // The residual gap is a new file: a module added under `standin/` and not
    // listed escapes this, and comptime cannot read a directory to close it.
    // The floor below is what makes the omission visible as the count stops
    // tracking the suite.
    const sources = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "standin_tests.zig", .text = @embedFile("standin_tests.zig") },
        .{ .name = "standin_range_tests.zig", .text = @embedFile("standin_range_tests.zig") },
        .{ .name = "standin/playbook.zig", .text = @embedFile("standin/playbook.zig") },
        .{ .name = "standin/request.zig", .text = @embedFile("standin/request.zig") },
        .{ .name = "standin/server.zig", .text = @embedFile("standin/server.zig") },
        .{ .name = "standin/range.zig", .text = @embedFile("standin/range.zig") },
        .{ .name = "standin/prompt_grammar.zig", .text = @embedFile("standin/prompt_grammar.zig") },
        .{ .name = "standin/defect_seeds.zig", .text = @embedFile("standin/defect_seeds.zig") },
        .{ .name = "standin/hole_seeds.zig", .text = @embedFile("standin/hole_seeds.zig") },
        .{ .name = "standin/source_grammar.zig", .text = @embedFile("standin/source_grammar.zig") },
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
    try testing.expect(checked >= 30);
    std.debug.print(
        "[standin-gate] filter reachability {d}/{d} test names over {d} sources\n",
        .{ checked, checked, sources.len },
    );
}

const loop = @import("loop.zig");
const model_request = @import("providers/model_request.zig");
const standin_request = @import("standin/request.zig");

// The stand-in reconstructs turn state from the request body, and every mid-turn
// message the loop authors reaches the wire as a user-role item. So the only
// thing telling a continuation from a new ask is its opening text, and the
// stand-in cannot import `loop.zig` to read it - that would drag the whole agent
// into the stand-in executable. It keeps copies, and this holds them to the
// authors in both directions.
//
// One direction alone is not enough. Equal contents with a missing row passes a
// subset check, and a row the loop no longer writes passes a superset check
// while the stand-in skips a message that never arrives.
test "stand-in gate: continuation prefixes match the messages the loop authors" {
    const authored = [_][]const u8{
        expert_workflow.workflow_note_prefix,
        loop.veto_retry_prefix,
        loop.compiler_repair_prefix,
    };

    // Floor first: an emptied table would make both loops below iterate nothing
    // and report agreement between two empty sets, which is the state that
    // reintroduces the turn reset.
    try testing.expect(standin_request.continuation_prefixes.len >= 3);
    try testing.expectEqual(authored.len, standin_request.continuation_prefixes.len);

    for (authored) |prefix| {
        var claims: usize = 0;
        for (standin_request.continuation_prefixes) |copy| {
            if (std.mem.eql(u8, copy, prefix)) claims += 1;
        }
        if (claims != 1) {
            std.debug.print(
                "[standin-gate] the loop authors \"{s}\" and the stand-in skips it {d} times\n",
                .{ prefix, claims },
            );
            return error.ContinuationPrefixDrifted;
        }
    }

    for (standin_request.continuation_prefixes) |copy| {
        var claims: usize = 0;
        for (authored) |prefix| {
            if (std.mem.eql(u8, copy, prefix)) claims += 1;
        }
        if (claims != 1) {
            std.debug.print(
                "[standin-gate] the stand-in skips \"{s}\", which nothing authors\n",
                .{copy},
            );
            return error.ContinuationPrefixDrifted;
        }
    }

    try testing.expectEqualStrings(loop.veto_reject_preamble, standin_request.veto_reject_preamble);
    try testing.expectEqualStrings(
        model_request.compaction_summary_marker,
        standin_request.compaction_summary_marker,
    );
    std.debug.print(
        "[standin-gate] continuation prefixes {d}/{d} agree with their authors\n",
        .{ authored.len, authored.len },
    );
}

const unseeded_rules = @import("unseeded_rules");
const defect_seeds = @import("standin/defect_seeds.zig");
const hole_seeds = @import("standin/hole_seeds.zig");
const pi_goal_candidate = @import("tools/pi_goal_candidate.zig");
const veto = @import("veto.zig");
const zts = @import("zts");
const edit_simulate = @import("zts_cli").edit_simulate;

test "stand-in gate: defect seeds are well formed and select by their own code" {
    // Floors first. Both loops below are per-seed and per-class, so an emptied
    // table reports agreement over nothing.
    try testing.expect(defect_seeds.seeds.len >= 4);
    inline for (comptime std.enums.values(defect_seeds.VetoClass)) |class| {
        const n = defect_seeds.countOfClass(class);
        if (n < 2) {
            std.debug.print(
                "[standin-gate] veto class {s} has {d} seeds; a class with fewer than two" ++
                    " cannot show the behavior is the class rather than the seed\n",
                .{ @tagName(class), n },
            );
            return error.VetoClassUnderseeded;
        }
    }

    var in_registry: usize = 0;
    for (defect_seeds.seeds) |seed| {
        // Each ask must reach the fix playbook, or the arm never starts.
        try testing.expectEqual(
            expert_workflow.TaskKind.violation_fix,
            expert_workflow.classify(seed.ask).kind,
        );

        // And must select its own seed, not a neighbour's.
        const selected = defect_seeds.findByAsk(seed.ask) orelse return error.SeedAskSelectsNothing;
        try testing.expectEqualStrings(seed.id, selected.id);

        var duplicates: usize = 0;
        for (defect_seeds.seeds) |other| {
            if (std.mem.eql(u8, other.code, seed.code)) duplicates += 1;
        }
        try testing.expectEqual(@as(usize, 1), duplicates);

        if (zts.PolicyCatalog.findByCode(seed.code) != null) in_registry += 1;
    }

    // Not a requirement, a report. The parser, stripper, and type-checker
    // families carry no registry row and are where the non-salvageable
    // rejections live, so demanding registry membership would exclude exactly
    // the seeds the retry arm needs. One inside is enough to say the seeds are
    // not wholly outside what the policy hash covers.
    try testing.expect(in_registry >= 1);
    std.debug.print(
        "[standin-gate] defect seeds {d}; {d} carry a registry code, {d} do not\n",
        .{ defect_seeds.seeds.len, in_registry, defect_seeds.seeds.len - in_registry },
    );
}

test "stand-in gate: every defect seed reproduces its declared veto class through the real veto" {
    for (defect_seeds.seeds) |seed| {
        // A seed whose drafts import `zttp:sql` needs a schema on disk: the
        // analyzer resolves query names against a file, and a schema-less
        // zttp:sql edit is refused with guidance before any rule can fire.
        // Written per seed and removed with it, so nothing leaks between seeds
        // and a seed without one is unaffected.
        var schema_dir: ?std.testing.TmpDir = null;
        defer if (schema_dir) |*dir| dir.cleanup();
        // `realPathFileAlloc` returns a sentinel-terminated slice; freeing it
        // as a plain `[]u8` drops the sentinel byte and trips the debug
        // allocator's size check.
        var schema_path_buf: ?[:0]u8 = null;
        defer if (schema_path_buf) |buf| testing.allocator.free(buf);
        if (seed.sql_schema) |schema_source| {
            schema_dir = std.testing.tmpDir(.{});
            try schema_dir.?.dir.writeFile(testing.io, .{ .sub_path = "schema.sql", .data = schema_source });
            schema_path_buf = try std.Io.Dir.realPathFileAlloc(schema_dir.?.dir, testing.io, "schema.sql", testing.allocator);
        }
        const schema_path: ?[]const u8 = schema_path_buf;

        // The seed must be clean. The veto is differential (`ok` is
        // `new_count == 0`), so a seed already carrying its own defect makes the
        // defect pre-existing, the bad draft passes, and the arm tests nothing
        // while reporting a clean run. This is the assertion that stops it.
        {
            var clean = try veto.runVetoWithSchema(testing.allocator, .{
                .file = "handler.ts",
                .content = seed.seed_source,
                .before = null,
                .policy_source = seed.policy_json,
            }, schema_path);
            defer clean.deinit(testing.allocator);
            // `ok` alone is too weak: salvage-on-reject normalizes a
            // canonical-band defect and reports a pass, so a baseline carrying
            // `let total = 1` would satisfy it while being exactly the
            // pre-existing defect this check exists to refuse. A clean baseline
            // is one nothing had to rewrite.
            if (!clean.outcome.ok or clean.report.normalized_content != null) {
                std.debug.print(
                    "[standin-gate] seed {s}: its baseline is not veto-clean (ok={} new={d} normalized={})\n",
                    .{ seed.id, clean.outcome.ok, clean.report.new, clean.report.normalized_content != null },
                );
                return error.DefectSeedBaselineDirty;
            }
        }

        // The good draft must land, whatever the class. A salvage seed never
        // reaches it in the arm, and leaving it unchecked is how a class change
        // ships a broken second draft.
        {
            var good = try veto.runVetoWithSchema(testing.allocator, .{
                .file = "handler.ts",
                .content = seed.good_draft,
                .before = seed.seed_source,
                .policy_source = seed.policy_json,
            }, schema_path);
            defer good.deinit(testing.allocator);
            if (!good.outcome.ok or good.report.new != 0) {
                std.debug.print(
                    "[standin-gate] seed {s}: its good draft does not pass ({d} new violations)\n",
                    .{ seed.id, good.report.new },
                );
                return error.DefectSeedGoodDraftFails;
            }
        }

        // What the bad draft introduces, read before the veto decides what to do
        // about it. The veto's own text cannot answer this for a salvaged seed:
        // normalization clears the diagnostic, so the code never appears in a
        // result that reads as a pass. Asking the simulator directly keeps the
        // claim "this draft introduces exactly this code" independent of the
        // outcome, which is the half the class switch below then checks.
        {
            var raw = try edit_simulate.simulate(testing.allocator, .{
                .file = "handler.ts",
                .content = seed.bad_draft,
                .before = seed.seed_source,
                .policy_source = seed.policy_json,
                .sql_schema_path = schema_path,
            });
            defer raw.deinit(testing.allocator);

            var introduced = false;
            for (raw.violations.items) |v| {
                if (v.introduced_by_patch and std.mem.eql(u8, v.code, seed.code)) introduced = true;
            }
            if (!introduced or raw.new_count == 0) {
                std.debug.print(
                    "[standin-gate] seed {s}: its bad draft does not introduce {s} ({d} new):\n",
                    .{ seed.id, seed.code, raw.new_count },
                );
                for (raw.violations.items) |v| {
                    std.debug.print("    {s} new={} {s}\n", .{ v.code, v.introduced_by_patch, v.message });
                }
                return error.DefectSeedCodeNotObserved;
            }
        }

        // The bad draft, measured against the seed as baseline: this is what the
        // arm actually submits.
        var bad = try veto.runVetoWithSchema(testing.allocator, .{
            .file = "handler.ts",
            .content = seed.bad_draft,
            .before = seed.seed_source,
            .policy_source = seed.policy_json,
        }, schema_path);
        defer bad.deinit(testing.allocator);

        switch (seed.class) {
            // Salvage is a positive claim, so it needs positive evidence rather
            // than the absence of a rejection: normalization must have produced
            // different bytes and named the rewrite it applied.
            .salvaged => {
                if (!bad.outcome.ok or bad.report.normalized_content == null or bad.report.rewrite_trace.len == 0) {
                    std.debug.print(
                        "[standin-gate] seed {s} declares salvaged: ok={} normalized={} rewrites={d}\n",
                        .{ seed.id, bad.outcome.ok, bad.report.normalized_content != null, bad.report.rewrite_trace.len },
                    );
                    return error.DefectSeedNotSalvaged;
                }
                try testing.expect(!std.mem.eql(u8, bad.report.normalized_content.?, seed.bad_draft));
            },
            // And a rejection must actually be one, with nothing salvaged behind
            // it. A seed that quietly starts being salvaged would otherwise make
            // the retry arm pass while never retrying.
            .model_retry => {
                if (bad.outcome.ok or bad.report.new == 0 or bad.report.normalized_content != null) {
                    std.debug.print(
                        "[standin-gate] seed {s} declares model_retry: ok={} new={d} normalized={}\n",
                        .{ seed.id, bad.outcome.ok, bad.report.new, bad.report.normalized_content != null },
                    );
                    return error.DefectSeedNotRejected;
                }
            },
            .compiler_repair => {
                if (bad.outcome.ok or bad.report.new == 0 or bad.report.normalized_content != null) {
                    std.debug.print(
                        "[standin-gate] seed {s} declares compiler_repair: ok={} new={d} normalized={}\n",
                        .{ seed.id, bad.outcome.ok, bad.report.new, bad.report.normalized_content != null },
                    );
                    return error.DefectSeedNotRejected;
                }

                var candidate = try pi_goal_candidate.candidateFromSource(
                    testing.allocator,
                    seed.bad_draft,
                    "handler.ts",
                    &.{},
                    4,
                );
                defer candidate.deinit(testing.allocator);
                if (!candidate.verified()) {
                    std.debug.print(
                        "[standin-gate] seed {s} declares compiler_repair: candidate reason={s}\n",
                        .{ seed.id, candidate.reason },
                    );
                    return error.DefectSeedNotCompilerRepairable;
                }
                try testing.expectEqualStrings(seed.good_draft, candidate.proposed_content.?);

                var repaired = try veto.runVetoWithSchema(testing.allocator, .{
                    .file = "handler.ts",
                    .content = candidate.proposed_content.?,
                    .before = seed.seed_source,
                    .policy_source = seed.policy_json,
                }, schema_path);
                defer repaired.deinit(testing.allocator);
                if (!repaired.outcome.ok or repaired.report.new != 0) {
                    return error.CompilerRepairCandidateFailsBindingVeto;
                }
            },
        }
    }

    std.debug.print(
        "[standin-gate] veto classes {d}/{d} seeds reproduce their declaration\n",
        .{ defect_seeds.seeds.len, defect_seeds.seeds.len },
    );

    // The repair table's `.status = .implemented` is an assertion that something
    // actually discharges an intent, and nothing tested it end to end. These
    // seeds do, from the outcome side: a code whose intent is implemented is one
    // the canonicalizer rewrites, which is exactly what `salvaged` means, and a
    // code whose intent is planned or absent has nothing to rewrite it. Measured
    // across all 16 seeds before it was written down, and it holds in both
    // directions with no exception.
    //
    // A repair that lands without its status moving, or a status that claims
    // more than it delivers, breaks this and is named here rather than
    // discovered later as a rule the corpus mysteriously never salvages.
    {
        var implemented_seeds: usize = 0;
        var unimplemented_seeds: usize = 0;
        for (defect_seeds.seeds) |seed| {
            const rule = zts.PolicyCatalog.findByCode(seed.code) orelse continue;
            const intent = rule.repair orelse {
                unimplemented_seeds += 1;
                if (seed.class == .salvaged) {
                    std.debug.print(
                        "[standin-gate] seed {s} ({s}) is salvaged but its rule declares no repair intent\n",
                        .{ seed.id, seed.code },
                    );
                    return error.SalvagedWithoutRepairIntent;
                }
                continue;
            };
            const implemented = zts.PolicyCatalog.repairIsImplemented(intent);
            if (implemented) implemented_seeds += 1 else unimplemented_seeds += 1;
            if (implemented != (seed.class == .salvaged)) {
                std.debug.print(
                    "[standin-gate] seed {s} ({s}): repair intent {s} implemented={} but the seed is {s}\n",
                    .{
                        seed.id,
                        seed.code,
                        @tagName(intent),
                        implemented,
                        @tagName(seed.class),
                    },
                );
                return error.RepairStatusDisagreesWithVetoClass;
            }
        }
        // Floors: one side empty would make the other direction vacuous.
        try testing.expect(implemented_seeds > 0);
        try testing.expect(unimplemented_seeds > 0);
        std.debug.print(
            "[standin-gate] repair status agrees with veto class for {d} implemented and {d} unimplemented seeds\n",
            .{ implemented_seeds, unimplemented_seeds },
        );
    }

    // The publishable figure, emitted only here and only after every assertion
    // above passed, so the marker means "these rules were observed firing"
    // rather than "this table lists them". `scripts/update-coverage.sh` lifts
    // it; `scripts/check-convergence-emitter.sh` holds it to this one producer.
    //
    // Deliberately not routed through `scripts/extract-evidence-marker.py`:
    // that validates a complete publishable *model run* and requires a runId,
    // provider, model and the identity hashes. This is a claim about the
    // compiler with no model in it, and borrowing that schema would dress it up
    // as something it is not.
    {
        var codes: std.ArrayList([]const u8) = .empty;
        defer codes.deinit(testing.allocator);
        for (defect_seeds.seeds) |seed| {
            if (zts.PolicyCatalog.findByCode(seed.code) == null) continue;
            var seen = false;
            for (codes.items) |existing| {
                if (std.mem.eql(u8, existing, seed.code)) seen = true;
            }
            if (!seen) try codes.append(testing.allocator, seed.code);
        }
        std.mem.sort([]const u8, codes.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);

        // Floor: an emptied seed table would otherwise publish "0 of 72
        // verified" as though that were a measurement rather than a broken run.
        try testing.expect(codes.items.len > 0);

        // Every advertised rule the seeds do not verify must be accounted for.
        //
        // The verified count alone leaves the remainder unexplained, and a
        // reader fills that in with "nobody has written those seeds yet". For
        // most of the remainder that is false: the code names a diagnostic
        // nothing in the tree ever constructs, so no draft can trip it and no
        // corpus draw can either. Publishing 53 of 72 without saying which of
        // the other 19 are unwritten and which are unreachable invites the
        // wrong reading of both halves.
        //
        // Enforced in both directions. An advertised rule that is neither
        // seeded nor listed fails, so the remainder can never grow silently;
        // and a listed code a seed now verifies fails, so closing a gap forces
        // the row out instead of leaving a stale claim behind.
        var unseeded = try parseUnseededAllow(testing.allocator);
        defer unseeded.deinit(testing.allocator);

        // Floors. Both checks below are set differences, and an empty input on
        // either side satisfies one of them while proving nothing.
        //
        // Both numbers moved when the registry shrank from 72 rules to 59 and
        // the list from nineteen rows to one. They are backstops against an
        // emptied input, not targets: the list is meant to keep shrinking, and
        // a floor set just under today's count would fail the next time it
        // does. One row still proves the file parses and is read.
        try testing.expect(unseeded.rows.items.len >= 1);
        try testing.expect(zts.PolicyCatalog.rules().len >= 40);

        for (zts.PolicyCatalog.rules()) |rule| {
            var seeded = false;
            for (codes.items) |code| {
                if (std.mem.eql(u8, code, rule.code)) seeded = true;
            }
            if (seeded) continue;
            if (unseeded.find(rule.code) == null) {
                std.debug.print(
                    "[standin-gate] {s} is advertised, no seed verifies it, and" ++
                        " scripts/unseeded-rules.allow does not say why\n",
                    .{rule.code},
                );
                return error.UnaccountedAdvertisedRule;
            }
        }

        for (unseeded.rows.items) |row| {
            if (zts.PolicyCatalog.findByCode(row.code) == null) {
                std.debug.print(
                    "[standin-gate] scripts/unseeded-rules.allow lists {s}," ++
                        " which is not an advertised rule\n",
                    .{row.code},
                );
                return error.UnseededRowIsNotARule;
            }
            for (codes.items) |code| {
                if (std.mem.eql(u8, code, row.code)) {
                    std.debug.print(
                        "[standin-gate] {s} is verified by a seed, so its row in" ++
                            " scripts/unseeded-rules.allow is stale; delete the row\n",
                        .{row.code},
                    );
                    return error.StaleUnseededRow;
                }
            }
        }

        std.debug.print(
            "[standin-gate] rule accounting {d} advertised = {d} seed-verified + {d} accounted unseeded\n",
            .{ zts.PolicyCatalog.rules().len, codes.items.len, unseeded.rows.items.len },
        );

        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try std.json.Stringify.value(.{
            .seedsTotal = defect_seeds.seeds.len,
            .rulesTotal = zts.PolicyCatalog.rules().len,
            .verifiedRules = codes.items.len,
            .verified = codes.items,
            .unseeded = unseeded.rows.items,
        }, .{}, &buf.writer);
        std.debug.print("[seed-coverage] {s}\n", .{buf.written()});
    }
}

/// One row of `scripts/unseeded-rules.allow`: an advertised rule no seed
/// verifies, and the slug naming what would have to change before one could.
const UnseededRow = struct {
    code: []const u8,
    reason: []const u8,
};

const UnseededAllow = struct {
    rows: std.ArrayList(UnseededRow),

    fn deinit(self: *UnseededAllow, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    fn find(self: *const UnseededAllow, code: []const u8) ?UnseededRow {
        for (self.rows.items) |row| {
            if (std.mem.eql(u8, row.code, code)) return row;
        }
        return null;
    }
};

/// Parse the allowlist. Slices point into the embedded file, which outlives
/// every caller, so the rows own nothing.
///
/// A malformed row is a hard error rather than a skip: a typo that silently
/// dropped a row would let an unaccounted rule pass as accounted, which is the
/// one thing this list exists to prevent.
fn parseUnseededAllow(allocator: std.mem.Allocator) !UnseededAllow {
    var rows: std.ArrayList(UnseededRow) = .empty;
    errdefer rows.deinit(allocator);

    var lines = std.mem.splitScalar(u8, unseeded_rules.contents, '\n');
    while (lines.next()) |raw| {
        const body = if (std.mem.indexOfScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
        const line = std.mem.trim(u8, body, " \t\r");
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const code = fields.next() orelse return error.MalformedUnseededRow;
        const reason = fields.next() orelse return error.MalformedUnseededRow;
        if (fields.next() != null) return error.MalformedUnseededRow;

        for (rows.items) |existing| {
            if (std.mem.eql(u8, existing.code, code)) return error.DuplicateUnseededRow;
        }
        try rows.append(allocator, .{ .code = code, .reason = reason });
    }

    return .{ .rows = rows };
}

const source_grammar = @import("standin/source_grammar.zig");

// The synthesizers branch on facts they read off the source, and every branch has
// been exercised by four hand-written fixtures. A synthesizer only ever seen
// against the shapes somebody thought to write down is the blind spot the
// file-destroying edit came from, and this crosses the branch conditions instead.
//
// The oracle is the real veto against the variant as baseline, which is how the
// loop judges an edit: differential, so a variant that is itself dirty does not
// make its synthesis look broken.
test "stand-in gate: every generated route source keeps the synthesized draft veto-clean" {
    try testing.expect(source_grammar.route_variants.len >= 16);

    const spec: playbook.RouteSpec = .{
        .file = "handler.ts",
        .method = "GET",
        .path = "/health",
    };

    var checked: usize = 0;
    // Both polarities of every predicate, counted rather than assumed: a
    // generator that collapsed to one value would still satisfy the floor above.
    var router_true: usize = 0;
    var routes_true: usize = 0;
    var spec_true: usize = 0;
    var alias_true: usize = 0;

    for (source_grammar.route_variants) |variant| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const source = try source_grammar.renderRouteSource(allocator, variant);
        const proposed = try playbook.synthesizeRoute(allocator, source, spec, "handleGetHealth");

        var result = try veto.runVeto(allocator, .{
            .file = "handler.ts",
            .content = proposed,
            .before = source,
        });
        defer result.deinit(allocator);

        if (!result.outcome.ok or result.report.new != 0) {
            std.debug.print(
                "[standin-gate] route variant router={} routes={} spec={} alias={} synthesizes {d} new violations:\n{s}\n",
                .{ variant.has_router, variant.has_routes, variant.has_spec_import, variant.has_guardrails_alias, result.report.new, proposed },
            );
            return error.SynthesizedRouteFailsVeto;
        }

        // And it must actually be the route that was asked for, not merely a
        // file the compiler accepts. A synthesizer that returned the source
        // unchanged would pass every assertion above.
        try testing.expect(std.mem.indexOf(u8, proposed, "\"GET /health\": handleGetHealth") != null);
        try testing.expect(std.mem.indexOf(u8, proposed, "function handleGetHealth") != null);

        if (variant.has_router) router_true += 1;
        if (variant.has_routes) routes_true += 1;
        if (variant.has_spec_import) spec_true += 1;
        if (variant.has_guardrails_alias) alias_true += 1;
        checked += 1;
    }

    try testing.expectEqual(source_grammar.route_variants.len, checked);
    const half = source_grammar.route_variants.len / 2;
    try testing.expectEqual(half, router_true);
    try testing.expectEqual(half, routes_true);
    try testing.expectEqual(half, spec_true);
    try testing.expectEqual(half, alias_true);
    std.debug.print("[standin-gate] route variants {d}/{d} synthesize clean\n", .{ checked, checked });
}

test "stand-in gate: every generated env source gets the answer its shape implies" {
    try testing.expect(source_grammar.env_variants.len >= 8);

    var edits: usize = 0;
    var existing: usize = 0;
    var refused: usize = 0;

    for (source_grammar.env_variants) |variant| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const source = try source_grammar.renderEnvSource(allocator, variant);
        const transform = try playbook.synthesizeEnvFeature(allocator, source, source_grammar.env_variable);

        // The answer is decided by the shape, so the mapping is asserted rather
        // than whatever came back being accepted. A source with no handler body
        // must be refused; one already carrying the read must be reported as
        // such; only the rest may be edited.
        if (!variant.has_handler_body) {
            try testing.expect(transform == .unsupported_handler);
            refused += 1;
            continue;
        }
        if (variant.has_existing_read) {
            try testing.expect(transform == .existing_read);
            existing += 1;
            continue;
        }

        const proposed = switch (transform) {
            .change_set => |bytes| bytes,
            else => {
                std.debug.print(
                    "[standin-gate] env variant import={} read={} body={} was refused, not edited\n",
                    .{ variant.has_env_import, variant.has_existing_read, variant.has_handler_body },
                );
                return error.SynthesizedEnvRefused;
            },
        };

        var result = try veto.runVeto(allocator, .{
            .file = "handler.ts",
            .content = proposed,
            .before = source,
        });
        defer result.deinit(allocator);
        if (!result.outcome.ok or result.report.new != 0) {
            std.debug.print(
                "[standin-gate] env variant import={} synthesizes {d} new violations:\n{s}\n",
                .{ variant.has_env_import, result.report.new, proposed },
            );
            return error.SynthesizedEnvFailsVeto;
        }

        // Exactly one import, whether or not the source already had one. A
        // second `import { env }` is the duplicate this branch exists to avoid.
        try testing.expectEqual(@as(usize, 1), countOccurrences(proposed, "import { env } from \"zttp:env\";"));
        try testing.expect(std.mem.indexOf(u8, proposed, "env(\"" ++ source_grammar.env_variable ++ "\")") != null);
        edits += 1;
    }

    // Each arm reached, so a generator collapsing onto one shape is visible.
    try testing.expect(edits >= 2);
    try testing.expect(existing >= 2);
    try testing.expect(refused >= 4);
    std.debug.print(
        "[standin-gate] env variants {d} edited, {d} already read, {d} refused\n",
        .{ edits, existing, refused },
    );
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| : (i = pos + needle.len) {
        n += 1;
    }
    return n;
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
            try testing.expect(std.mem.indexOf(u8, reply, "propose_change_set") == null);
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
