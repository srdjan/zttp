//! Declared task range for the deterministic playbook server.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const expert_workflow = @import("../expert_workflow.zig");

pub const version = "step-4b-v1";
// Covers the declared entries and the negative corpus. The corpus joined the
// hash after review found it outside: emptying it changed no published number
// while both false-fire gates silently fell to zero iterations. The declared
// range itself did not change when this value did.
pub const content_hash = "970a6c41daae4f2a94dc009d35fef4d210d9849c011344496063926d7b2fb316";

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
            "Use `zig build zttp-standin -- --range` to print this document.\n\n",
    );

    for (entries, 0..) |entry, index| {
        try writer.print("## `{s}`\n\n", .{entry.id});
        try writer.print("- Task kind: `{s}`\n", .{@tagName(entry.kind)});
        try writer.print("- Result: {s}\n", .{actionName(entry.action)});
        try writer.print("- Behavior: {s}\n", .{entry.description});
        try writer.print("- Canonical prompt: {s}\n", .{entry.canonical_prompt});
        try writer.writeAll("- Example paraphrases:\n");
        for (entry.paraphrases) |paraphrase| {
            try writer.print("  - {s}\n", .{paraphrase});
        }
        if (index + 1 < entries.len) try writer.writeByte('\n');
    }

    return try buf.toOwnedSlice();
}
