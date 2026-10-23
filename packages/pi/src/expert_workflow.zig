//! Deterministic task routing for `zttp expert`.
//!
//! This module does not decide whether an edit is safe. It only gives the
//! model a compiler-native route before the first model round-trip so common
//! tasks start with the right tools instead of spending attempts discovering
//! the process.

const std = @import("std");

/// Opening token of the workflow system note. It reaches the provider as a
/// user-role item, so anything reconstructing turn state from the wire needs it
/// to tell a mid-turn note from the start of a new ask.
pub const workflow_note_prefix = "[expert workflow]";

pub const TaskKind = enum {
    unknown,
    route_add,
    handler_scaffold,
    violation_fix,
    spec_goal,
    sql_feature,
    auth_jwt,
    env_feature,
    test_generation,
    review_explain,
    hole_fill,
};

pub const Confidence = enum {
    low,
    medium,
    high,
};

pub const WorkflowHint = struct {
    kind: TaskKind = .unknown,
    confidence: Confidence = .low,

    pub fn injectsSystemNote(self: WorkflowHint) bool {
        return self.kind != .unknown and self.confidence != .low;
    }
};

pub fn taskKindName(kind: TaskKind) []const u8 {
    return @tagName(kind);
}

pub fn confidenceName(confidence: Confidence) []const u8 {
    return @tagName(confidence);
}

const proof_property_needles = [_][]const u8{
    "spec<",
    "proof",
    "prove",
    "property goal",
    "injection_safe",
    "no_secret_leakage",
    "no_credential_leakage",
    "deterministic",
    "idempotent",
    "retry_safe",
    "retry safe",
    "fault_covered",
    "fault covered",
    "at-least-once",
    "safe to cache",
};

pub fn classify(user_text: []const u8) WorkflowHint {
    if (containsAny(user_text, &.{ "jwt", "bearer", "authorization" }) and
        containsAny(user_text, &.{ "auth", "verify", "token", "protect" }))
    {
        return .{ .kind = .auth_jwt, .confidence = .high };
    }

    if (containsAny(user_text, &.{ "zts", "violation", "diagnostic", "compiler error" }) and
        containsAny(user_text, &.{ "fix", "repair", "clean", "resolve" }))
    {
        return .{ .kind = .violation_fix, .confidence = .high };
    }

    // Narrow by necessity: `whole` contains `hole`, so a bare "hole" needle
    // routes "rewrite the whole file" here. Every needle below carries enough
    // context that the substring cannot appear inside `whole`.
    if (containsAny(user_text, &.{ "hole()", "typed hole", "fill the hole", "remaining hole", "unfilled hole" })) {
        return .{ .kind = .hole_fill, .confidence = .high };
    }

    if (containsAny(user_text, &.{ "sql", "sqlite", "database", "query", "select ", "insert ", "update ", "delete " })) {
        return .{ .kind = .sql_feature, .confidence = .high };
    }

    if (containsAny(user_text, &proof_property_needles)) {
        return .{ .kind = .spec_goal, .confidence = .high };
    }

    if (containsAny(user_text, &.{ "add route", "new route", "create route", "route table", "router", "get /", "post /", "put /", "patch /", "delete /" }) or
        (containsFold(user_text, "route") and containsAny(user_text, &.{ "add", "new", "create" })))
    {
        return .{ .kind = .route_add, .confidence = .high };
    }

    if (containsAny(user_text, &.{ "scaffold", "new handler", "create handler", "minimal handler" })) {
        return .{ .kind = .handler_scaffold, .confidence = .high };
    }

    if (containsAny(user_text, &.{ "env var", "environment variable", "zttp:env", "secret", "api key" })) {
        return .{ .kind = .env_feature, .confidence = .medium };
    }

    if (containsAny(user_text, &.{ "write test", "add test", "jsonl test", "test case" })) {
        return .{ .kind = .test_generation, .confidence = .medium };
    }

    if (containsAny(user_text, &.{ "explain", "review", "what does", "how does" })) {
        return .{ .kind = .review_explain, .confidence = .medium };
    }

    return .{};
}

pub fn renderSystemNote(
    allocator: std.mem.Allocator,
    hint: WorkflowHint,
) !?[]u8 {
    if (!hint.injectsSystemNote()) return null;

    const route = workflowRoute(hint.kind);
    return try allocator.print(workflow_note_prefix ++ " kind={s} confidence={s}\n{s}\n", .{ taskKindName(hint.kind), confidenceName(hint.confidence), route });
}

fn workflowRoute(kind: TaskKind) []const u8 {
    return switch (kind) {
        .route_add =>
        \\Read the target file, run `zts_expert_verify_paths`, and gather current module facts with `zts_expert_query` operation `modules`. Author the COMPLETE file content yourself, then submit exactly one `propose_change_set` call so the host veto checks the draft and the approval gate owns the write.
        ,
        .handler_scaffold =>
        \\Create the smallest canonical handler that satisfies the request. Read nearby handlers first, use live module/rule tools for imports and syntax, then let the compiler veto verify the complete scaffold before apply.
        ,
        .violation_fix =>
        \\Use compiler diagnostics as the source of truth. Read the target, run `zts_expert_verify_paths`, call `pi_repair_plan`, dry-run supported plans with `pi_apply_repair_plan` or `pi_goal_candidate`, and edit manually only for unsupported repair intents.
        ,
        .spec_goal =>
        \\Drive proof work through compiler diagnostics. Run `zts_expert_verify_paths`, then `pi_repair_plan`. Use `pi_goal_candidate` or `pi_apply_repair_plan` for supported repairs. Run `pi_goal_check` to confirm the requested goals.
        ,
        .sql_feature =>
        \\Check SQL support before drafting. Read the handler and `zttp.json`, verify the configured sqlite schema exists, use named parameters supported by the analyzer, and do not retry unchanged if the veto reports missing SQL schema configuration.
        ,
        .auth_jwt =>
        \\Use the auth module path deliberately. Check `zts_expert_query` operation `modules` for `zttp:auth`, keep bearer tokens and claims out of responses/logs, avoid fallback secrets, and verify no credential leakage after the edit.
        ,
        .env_feature =>
        \\Treat environment values as toxic. Check `zttp:env` with live module tools, avoid fallback secrets, redact in output, and verify no secret leakage before applying the edit.
        ,
        .test_generation =>
        \\Use the existing test shape. Read adjacent tests and handler proofs first, draft JSONL from compiler-proven behavior, then submit the complete test file through one `propose_change_set` call.
        ,
        .review_explain =>
        \\Do not edit unless the user asks for a change. Use live rule/module tools for ZigTS facts and cite compiler diagnostics or proof output rather than relying on memory.
        ,
        .hole_fill =>
        \\Read the frame with `zts_expert_query` operation `holes` and spend the turn on one hole. Call `zts_expert_fill_hole` with that hole's line, column, and one expression; the frame is the whole specification of it, and rewriting the file throws the frame away. Commit the returned `proposed_content` only when the tool reports `ok`.
        ,
        .unknown => "",
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsFold(haystack, needle)) return true;
    }
    return false;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (asciiLower(haystack[i + j]) != asciiLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + ('a' - 'A');
    return ch;
}

const testing = std.testing;

test "classify route additions before generic handler work" {
    const hint = classify("Add a GET /users route to this handler");
    try testing.expectEqual(TaskKind.route_add, hint.kind);
    try testing.expectEqual(Confidence.high, hint.confidence);
}

test "classify proof goals" {
    const hint = classify("prove this endpoint is injection_safe");
    try testing.expectEqual(TaskKind.spec_goal, hint.kind);
    try testing.expect(hint.injectsSystemNote());
}

test "classify JWT auth before env secrets" {
    const hint = classify("add bearer JWT auth using JWT_SECRET");
    try testing.expectEqual(TaskKind.auth_jwt, hint.kind);
}

test "hole routing does not fire on the word whole" {
    // `whole` contains `hole`, so a bare needle would send every "rewrite the
    // whole file" ask into the hole arm. The needles carry enough context that
    // the substring cannot appear inside `whole`, and this is what holds them to
    // it.
    try testing.expectEqual(TaskKind.hole_fill, classify("Fill the remaining hole in handler.ts").kind);
    try testing.expectEqual(TaskKind.hole_fill, classify("fill the hole on line 3").kind);
    try testing.expectEqual(TaskKind.hole_fill, classify("Replace the hole() with an expression").kind);

    try testing.expect(classify("Rewrite the whole file").kind != .hole_fill);
    try testing.expect(classify("Author the whole handler yourself").kind != .hole_fill);
    try testing.expect(classify("Explain the whole thing").kind != .hole_fill);
}

test "unknown prompt does not inject a note" {
    const hint = classify("make it nicer");
    try testing.expectEqual(TaskKind.unknown, hint.kind);
    try testing.expect(!hint.injectsSystemNote());
}

test "renderSystemNote names required compiler-native tool path" {
    const note = (try renderSystemNote(testing.allocator, classify("fix ZTS303 violation"))) orelse return error.TestExpected;
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "pi_repair_plan") != null);
    try testing.expect(std.mem.indexOf(u8, note, "kind=violation_fix") != null);
}
