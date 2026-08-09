//! Declared task range for the deterministic playbook server.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const expert_workflow = @import("../expert_workflow.zig");
const defect_seeds = @import("defect_seeds.zig");
const hole_seeds = @import("hole_seeds.zig");

pub const version = "step-6-v2";
// Covers the declared entries and the negative corpus. The corpus joined the
// hash after review found it outside: emptying it changed no published number
// while both false-fire gates silently fell to zero iterations. The declared
// range itself did not change when this value did.
pub const content_hash = "60fe2f0bf3de382e0d6c18445055773fe2d0b5ff7ec551007b6346d1e3cdb946";

pub const Action = enum {
    answer,
    edit,
};

pub const Entry = struct {
    id: []const u8,
    kind: expert_workflow.TaskKind,
    canonical_prompt: []const u8,
    paraphrases: []const []const u8,
    action: Action,
    description: []const u8,
};

pub const entries = [_]Entry{
    .{
        .id = "explain",
        .kind = .review_explain,
        .canonical_prompt = "Explain how Response.json works",
        .paraphrases = &.{
            "Explain the Response.json helper",
            "What does Response.json return?",
        },
        .action = .answer,
        .description = "Use live module facts and return a concise text explanation. Do not edit a file.",
    },
    .{
        .id = "review",
        .kind = .review_explain,
        .canonical_prompt = "Review handler.ts for correctness and compiler compliance",
        .paraphrases = &.{
            "Review handler.ts for compiler compliance",
            "How does handler.ts handle errors?",
        },
        .action = .answer,
        .description = "Read the handler and return a concise text review. Do not edit a file.",
    },
    .{
        .id = "add-route",
        .kind = .route_add,
        .canonical_prompt = "Create a handler in handler.ts that responds to GET /health with Response.json({ ok: true }).",
        .paraphrases = &.{
            "Create a GET /health route",
            "Add route POST /users to handler.ts",
        },
        .action = .edit,
        .description = "Read the handler, inspect module facts, and propose one complete route edit.",
    },
    .{
        .id = "add-env",
        .kind = .env_feature,
        .canonical_prompt = "Add the APP_NAME environment variable to handler.ts",
        .paraphrases = &.{
            "Add the APP_NAME environment variable",
            "Read configuration with zttp:env",
        },
        .action = .edit,
        .description = "Read the handler, inspect zttp:env, and propose one complete configuration edit.",
    },
    .{
        .id = "write-test",
        .kind = .test_generation,
        .canonical_prompt = "Write test case for the successful health response",
        .paraphrases = &.{
            "Add test coverage for the successful health response",
            "Add a jsonl test case for the health handler",
        },
        .action = .edit,
        .description = "Read the handler and its JSONL tests, then propose one complete test-file edit.",
    },
    .{
        .id = "fix",
        .kind = .violation_fix,
        .canonical_prompt = "Fix the ZTS300 compiler error in handler.ts",
        .paraphrases = &.{
            "Fix the ZTS300 compiler error",
            "Repair this handler's compiler error",
        },
        .action = .edit,
        .description = "Inspect the violation and repair facts, then propose one complete handler edit.",
    },
    .{
        .id = "fill-hole",
        .kind = .hole_fill,
        .canonical_prompt = "Fill the remaining hole in handler.ts",
        .paraphrases = &.{
            "Fill the hole on line 3 of handler.ts",
            "Replace the hole() in handler.ts with an expression",
        },
        .action = .edit,
        .description = "Read the compiler's typed-hole frame, fill one site through `zts_expert_fill_hole`, and apply what the tool returns.",
    },
};

pub const NegativeCase = struct {
    id: []const u8,
    prompt: []const u8,
    expected_kind: expert_workflow.TaskKind,
};

pub const negative_corpus = [_]NegativeCase{
    .{
        .id = "jwt-auth",
        .prompt = "Protect this handler with bearer JWT auth",
        .expected_kind = .auth_jwt,
    },
    .{
        .id = "sql-feature",
        .prompt = "Add a sqlite query for users",
        .expected_kind = .sql_feature,
    },
    .{
        .id = "proof-goal",
        .prompt = "Prove this endpoint is injection_safe",
        .expected_kind = .spec_goal,
    },
    .{
        .id = "workflow-authoring",
        .prompt = "Create a durable workflow handler that dispatches a greet child handler with workflow.call",
        .expected_kind = .workflow_authoring,
    },
};

pub fn findById(id: []const u8) ?*const Entry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub fn findByPrompt(prompt: []const u8) ?*const Entry {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, entry.canonical_prompt, prompt)) return entry;
        for (entry.paraphrases) |paraphrase| {
            if (std.mem.eql(u8, paraphrase, prompt)) return entry;
        }
    }
    return null;
}

pub fn hasKind(kind: expert_workflow.TaskKind) bool {
    for (entries) |entry| {
        if (entry.kind == kind) return true;
    }
    return false;
}

pub const Coverage = enum {
    covered,
    reserved,
};

/// Whether a task kind may enter the declared range.
///
/// The negative corpus below and the out-of-range grammars in
/// `prompt_grammar.zig` are pinned on kinds this switch calls reserved, and
/// both false-fire gates assert an absence: `!hasKind(kind)` here and
/// `!playbook.hasPlaybook(kind)` there. Covering a reserved kind deletes its
/// own negative, and covering every one of them leaves both gates iterating
/// nothing while still reporting a pass. The range therefore grows by adding a
/// new task kind, or a new entry inside a covered one, and never by consuming a
/// reserved one.
///
/// Exhaustive with no `else` prong, so a new `TaskKind` member is a compile
/// error until somebody decides which side it belongs on.
pub fn coverageOf(kind: expert_workflow.TaskKind) Coverage {
    return switch (kind) {
        .route_add,
        .review_explain,
        .env_feature,
        .test_generation,
        .violation_fix,
        .hole_fill,
        => .covered,

        .unknown,
        .handler_scaffold,
        .spec_goal,
        .workflow_authoring,
        .sql_feature,
        .auth_jwt,
        => .reserved,
    };
}

pub const covered_kinds = kindsWithCoverage(.covered);
pub const reserved_kinds = kindsWithCoverage(.reserved);

fn kindsWithCoverage(comptime want: Coverage) []const expert_workflow.TaskKind {
    comptime {
        const all = std.enums.values(expert_workflow.TaskKind);
        var picked: [all.len]expert_workflow.TaskKind = undefined;
        var count: usize = 0;
        for (all) |kind| {
            if (coverageOf(kind) == want) {
                picked[count] = kind;
                count += 1;
            }
        }
        const frozen = picked[0..count].*;
        return &frozen;
    }
}

pub fn actionName(action: Action) []const u8 {
    return switch (action) {
        .answer => "text answer",
        .edit => "workspace edit",
    };
}

pub fn contentHash() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, version);
    hashUsize(&hasher, entries.len);
    for (entries) |entry| {
        hashField(&hasher, entry.id);
        hashField(&hasher, @tagName(entry.kind));
        hashField(&hasher, entry.canonical_prompt);
        hashUsize(&hasher, entry.paraphrases.len);
        for (entry.paraphrases) |paraphrase| hashField(&hasher, paraphrase);
        hashField(&hasher, @tagName(entry.action));
        hashField(&hasher, entry.description);
    }

    // The negative corpus is part of what the range claims, not a detail beside
    // it: it is the only thing asserting the range does not extend past its
    // declared edge. Leaving it out of the hash meant emptying it changed no
    // published number while both false-fire gates fell to zero iterations.
    hashUsize(&hasher, negative_corpus.len);
    for (negative_corpus) |negative| {
        hashField(&hasher, negative.id);
        hashField(&hasher, negative.prompt);
        hashField(&hasher, @tagName(negative.expected_kind));
    }

    // The reserved set is a claim about the range's edge for the same reason
    // the negative corpus is, and it outlives any single negative: a kind moved
    // from reserved to covered with no entry added yet changes nothing else the
    // hash can see.
    hashUsize(&hasher, reserved_kinds.len);
    for (reserved_kinds) |kind| hashField(&hasher, @tagName(kind));

    // The defect seeds are the only drafts the stand-in emits that the veto is
    // meant to reject, so they are part of what the range claims and not a
    // detail beside it. Their sources are hashed too: a seed edited until it no
    // longer introduces its own code would otherwise change the arm's behavior
    // while the published identity held still.
    hashUsize(&hasher, defect_seeds.seeds.len);
    for (defect_seeds.seeds) |seed| {
        hashField(&hasher, seed.id);
        hashField(&hasher, seed.code);
        hashField(&hasher, @tagName(seed.class));
        hashField(&hasher, seed.seed_source);
        hashField(&hasher, seed.bad_draft);
        hashField(&hasher, seed.good_draft);
        hashField(&hasher, seed.ask);
    }

    hashUsize(&hasher, hole_seeds.seeds.len);
    for (hole_seeds.seeds) |seed| {
        hashField(&hasher, seed.id);
        hashUsize(&hasher, seed.holes);
        hashField(&hasher, seed.source);
        hashUsize(&hasher, seed.expressions.len);
        for (seed.expressions) |expression| hashField(&hasher, expression);
        hashField(&hasher, seed.ask);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashUsize(hasher: *std.crypto.hash.sha2.Sha256, value: usize) void {
    var len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_bytes, value, .little);
    hasher.update(&len_bytes);
}

pub fn renderDocument(allocator: std.mem.Allocator) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    const hash = contentHash();

    try writer.writeAll(
        "<!-- Generated file. Do not edit. Run `zig build zttp-standin -- --range > packages/pi/docs/standin-range.md` to regenerate it. -->\n\n" ++
            "# Deterministic stand-in range\n\n",
    );
    try writer.print("Range version: `{s}`\n\n", .{version});
    try writer.print("Range hash: `{s}`\n\n", .{hash});
    try writer.writeAll(
        "The deterministic playbook server supports the entries below. " ++
            "Use `zig build zttp-standin -- --range` to print this document.\n\n" ++
            "This server is a scripted responder, not a model. Its drafts and defect seeds are " ++
            "authored by repo code to produce declared outcomes through the same veto and repair " ++
            "loop, so it can show that the harness runs correctly and can say nothing about what " ++
            "a model would draft. Convergence " ++
            "numbers come from recorded model turns only; see `docs/convergence.md`.\n\n",
    );

    for (entries) |entry| {
        try writer.print("## `{s}`\n\n", .{entry.id});
        try writer.print("- Task kind: `{s}`\n", .{@tagName(entry.kind)});
        try writer.print("- Result: {s}\n", .{actionName(entry.action)});
        try writer.print("- Behavior: {s}\n", .{entry.description});
        try writer.print("- Canonical prompt: {s}\n", .{entry.canonical_prompt});
        try writer.writeAll("- Example paraphrases:\n");
        for (entry.paraphrases) |paraphrase| {
            try writer.print("  - {s}\n", .{paraphrase});
        }
        try writer.writeByte('\n');
    }

    try writer.writeAll("## Reserved task kinds\n\n");
    try writer.writeAll(
        "These kinds stay outside the range on purpose. They are what the " ++
            "negative corpus and the out-of-range grammars assert an absence against, " ++
            "so covering one would delete its own gate.\n\n",
    );
    for (reserved_kinds) |kind| {
        try writer.print("- `{s}`\n", .{@tagName(kind)});
    }

    try writer.writeAll("\n## Defect seeds\n\n");
    try writer.writeAll(
        "Drafts the stand-in emits expecting the veto to reject them, so the rejection " ++
            "half of the loop is reachable with no live model. Each seed declares what the " ++
            "loop does with its bad draft; the declaration is re-derived by running the real " ++
            "veto, never trusted.\n\n",
    );
    try writer.writeAll("| Seed | Code | Outcome |\n|---|---|---|\n");
    for (defect_seeds.seeds) |seed| {
        try writer.print("| `{s}` | `{s}` | {s} |\n", .{ seed.id, seed.code, @tagName(seed.class) });
    }

    try writer.writeAll("\n## Hole seeds\n\n");
    try writer.writeAll(
        "Skeletons whose response expressions are holes. The arm reads the file, publishes the frame " ++
            "through the real in-process `zts_expert_holes`, fills one site through " ++
            "`zts_expert_fill_hole`, and applies what the tool returns. Multi-hole seeds repeat that " ++
            "sequence on the next turn, so each accepted proposal becomes the next frame's baseline.\n\n",
    );
    try writer.writeAll("| Seed | Holes |\n|---|---|\n");
    for (hole_seeds.seeds) |seed| {
        try writer.print("| `{s}` | {d} |\n", .{ seed.id, seed.holes });
    }

    return try buf.toOwnedSlice();
}
