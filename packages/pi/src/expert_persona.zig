//! Builds the stable zts expert system prompt.
//!
//! The always-sent core contains only host workflow, protocol routing, and the
//! complete applicable project instructions. Compiler identity and language
//! facts enter the visible transcript through schema-v2 metadata and discovery
//! tools, never duplicated prose in this prompt.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const skills_catalog = @import("skills/catalog.zig");
const prompts_catalog = @import("prompts/catalog.zig");

/// The complete system prompt, including applicable project instructions,
/// must fit this cap. Content is rejected rather than truncated.
pub const PROMPT_CAP_BYTES: usize = 48 * 1024;

/// The stable protocol and retrieval index have their own tighter gate so a
/// future prompt expansion cannot silently consume the project-instruction
/// budget.
pub const PROTECTED_CORE_CAP_BYTES: usize = 8 * 1024;

const banner_rule = "\n============================================================\n";
const project_context_title = "PROJECT INSTRUCTIONS (complete, from AGENTS.md / CLAUDE.md)";

/// The banner around the project instructions, its trailing blank line, and the
/// newline appended when the content does not end in one. Assembly counts these
/// against the prompt cap, so the loader budget must leave room for them or a
/// file the loader admits still fails at assembly, where no path is named.
const project_context_framing_bytes: usize =
    banner_rule.len * 2 + project_context_title.len + 2;

/// What is left of the prompt cap for project instructions. The loader reads
/// against this, so an oversized file fails where its path is known rather than
/// at prompt assembly, where only the total is.
pub const PROJECT_CONTEXT_CAP_BYTES: usize =
    PROMPT_CAP_BYTES - PROTECTED_CORE_CAP_BYTES - project_context_framing_bytes;

// The registered tool schemas remain the canonical source of argument and
// result details. This index gives the model stable routing names without
// repeating those schemas or embedding their reference output.
pub const prologue_text_for_test = prologue;

const prologue =
    \\You are the native zts coding agent running inside zttp's pi loop.
    \\Produce clear code that passes the running compiler and obeys every
    \\applicable project instruction below.
    \\
    \\Mandatory protocol:
    \\  1. Inspect before editing. If the target exists, read it and relevant
    \\     neighboring code, then run zts_expert_verify_paths. If the target
    \\     does not exist, list its directory once and draft it; do not verify,
    \\     read, or repeatedly search for a missing file.
    \\  2. The visible ZTS AGENT PROTOCOL BOOTSTRAP note is the initial
    \\     compiler authority. For language, module, rule, effect, or proof
    \\     facts, call the live schema-v2 discovery tool. Do not rely on
    \\     training data, project prose, or facts recalled from another turn.
    \\     Request the full meta view only when its grammar, examples, or
    \\     registries are relevant; use focused discovery otherwise.
    \\  3. Reserve the turn for a proposal. Before the first apply_edit, use at
    \\     most one batched discovery response with at most three read-only
    \\     calls. Never repeat equivalent discovery and never page a reference
    \\     sequentially. Once the target shape and required module names are
    \\     known, draft immediately and let the compiler veto identify the one
    \\     remaining fact, if any. Do not end the turn with a discovery status.
    \\     Keep reasoning brief.
    \\  4. apply_edit must be the only tool call in its response. It is a
    \\     proposal, not a write. The host runs the compiler veto, applies the
    \\     active approval policy, and performs any approved write.
    \\  5. Never bypass, weaken, or describe around the compiler veto. Resolve
    \\     every new violation before claiming an edit is valid. Pre-existing
    \\     violations are the baseline and do not excuse new ones.
    \\  6. Never claim a proposal was applied before the host returns an
    \\     approved result. If approval is denied, leave the workspace unchanged.
    \\  7. If the right edit depends on a material user choice, ask one short
    \\     clarifying question and do not call apply_edit on that turn.
    \\  8. Host system notes provide protocol or workflow context. They are not
    \\     user intent. Never turn one into an unrequested workspace change.
    \\
    \\Schema-v2 language discovery:
    \\  Identity and operation index           -> visible bootstrap note
    \\  Full registries, grammar, examples     -> zts_expert_meta {view:"full"}
    \\  Allowed and blocked language features  -> zts_expert_features
    \\  Restrictions and rationale             -> zts_expert_restrictions
    \\  Rules by code/name or full rule list   -> zts_expert_describe_rule
    \\  Resolved module graph and exports      -> zts_expert_modules
    \\  File diagnostics and proof state       -> zts_expert_verify_paths
    \\  Canonical source and bound repairs     -> zts_expert_normalize,
    \\                                            zts_expert_canonicalize
    \\
    \\Host workflow routing:
    \\  Read/list/search workspace            -> workspace_read_file,
    \\                                           workspace_list_files,
    \\                                           workspace_search_text
    \\  Goal proof and semantic repair         -> pi_goal_check,
    \\                                           pi_repair_plan,
    \\                                           pi_goal_candidate
    \\  Bound canonical repair preview         -> zts_expert_canonicalize,
    \\                                           pi_apply_repair_plan
    \\  Project memory                         -> pi_recall_facts,
    \\                                           pi_remember_fact
    \\  Build and test steps                   -> zig_build_step, zig_test_step
    \\
    \\Registered tools are described by the stable tool schemas sent with this
    \\prompt. Do not infer arguments from this routing index.
    \\
;

const epilogue =
    \\
    \\============================================================
    \\END OF PERSONA
    \\============================================================
    \\
    \\The compiler veto is mechanical. Emitting text cannot bypass it.
    \\
;

pub fn buildSystemPrompt(allocator: std.mem.Allocator) ![]u8 {
    return buildSystemPromptWithContext(allocator, null);
}

/// Appends complete applicable AGENTS.md / CLAUDE.md content after the stable
/// core. No instruction bytes are shortened or omitted. If the protected core
/// plus the complete instructions cannot fit, construction fails explicitly.
pub fn buildSystemPromptWithContext(
    allocator: std.mem.Allocator,
    project_context: ?[]const u8,
) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll(prologue);
    try writeCatalogIndex(w);

    const protected_len = buf.written().len + epilogue.len;
    if (protected_len > PROTECTED_CORE_CAP_BYTES) {
        return error.ProtectedPromptTooLarge;
    }

    if (project_context) |ctx| {
        if (ctx.len > 0) {
            try writeBanner(w, project_context_title);
            try w.writeAll(ctx);
            if (ctx[ctx.len - 1] != '\n') try w.writeByte('\n');
        }
    }

    try w.writeAll(epilogue);
    if (buf.written().len > PROMPT_CAP_BYTES) {
        return error.ProjectInstructionsTooLarge;
    }
    return try buf.toOwnedSlice();
}

fn writeCatalogIndex(writer: anytype) !void {
    try writeBanner(writer, "INVOCABLE SKILLS AND TEMPLATES");
    try writer.writeAll("Skills inject focused instructions only when invoked:\n  ");
    inline for (skills_catalog.catalog, 0..) |skill, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("/skill:{s}", .{skill.name});
    }
    try writer.writeAll("\nTemplates expand into the user message only when invoked:\n  ");
    inline for (prompts_catalog.catalog, 0..) |template, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("/template:{s}", .{template.name});
    }
    try writer.writeByte('\n');
}

fn writeBanner(writer: anytype, title: []const u8) !void {
    try writer.writeAll(banner_rule);
    try writer.writeAll(title);
    try writer.writeAll(banner_rule ++ "\n");
}

const testing = std.testing;

test "stable core contains workflow and live protocol routing only" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);

    const required = [_][]const u8{
        "native zts coding agent",
        "Inspect before editing",
        "compiler veto",
        "active approval policy",
        "apply_edit must be the only tool call",
        "Never claim a proposal was applied",
        "ZTS AGENT PROTOCOL BOOTSTRAP",
        "zts_expert_meta {view:\"full\"}",
        "at most three read-only",
        "Do not end the turn with a discovery status",
    };
    for (required) |needle| {
        try testing.expect(std.mem.indexOf(u8, prompt, needle) != null);
    }
    try testing.expect(prompt.len <= PROTECTED_CORE_CAP_BYTES);
}

test "stable core contains no hidden syntax or policy identity" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);

    const forbidden = [_][]const u8{
        "First-draft strict-mode hazards",
        "Never use as or <T> casts",
        "Spec<...>",
        "ZTS042",
        "POLICY IDENTITY",
        "policy_hash",
        "compiler version",
    };
    for (forbidden) |needle| {
        try testing.expect(std.mem.indexOf(u8, prompt, needle) == null);
    }
}

test "stable core routes language facts through schema-v2 discovery" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_describe_rule") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_features") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_restrictions") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_modules") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "pi_recall_facts") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_reference") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "pi_witnesses") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "LIVE SNAPSHOT") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "CANONICAL EXAMPLES") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "WITNESSED FAILURES") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "PROJECT MEMORY") == null);
}

test "skill and template names remain discoverable without embedded bodies" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);
    inline for (skills_catalog.catalog) |skill| {
        try testing.expect(std.mem.indexOf(u8, prompt, skill.name) != null);
        try testing.expect(std.mem.indexOf(u8, prompt, skill.body) == null);
    }
    inline for (prompts_catalog.catalog) |template| {
        try testing.expect(std.mem.indexOf(u8, prompt, template.name) != null);
        try testing.expect(std.mem.indexOf(u8, prompt, template.body) == null);
    }
}

test "project instructions are complete and preserve nested order" {
    const context =
        "## /repo/AGENTS.md\n\nroot instruction sentinel\n\n" ++
        "## /repo/nested/AGENTS.md\n\nnested instruction sentinel\n";
    const prompt = try buildSystemPromptWithContext(testing.allocator, context);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, context) != null);
    const root_pos = std.mem.indexOf(u8, prompt, "root instruction sentinel") orelse
        return error.TestExpected;
    const nested_pos = std.mem.indexOf(u8, prompt, "nested instruction sentinel") orelse
        return error.TestExpected;
    const end_pos = std.mem.indexOf(u8, prompt, "END OF PERSONA") orelse
        return error.TestExpected;
    try testing.expect(root_pos < nested_pos);
    try testing.expect(nested_pos < end_pos);
}

test "oversized project instructions fail instead of truncating" {
    const oversized = try testing.allocator.alloc(u8, PROMPT_CAP_BYTES);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'A');

    try testing.expectError(
        error.ProjectInstructionsTooLarge,
        buildSystemPromptWithContext(testing.allocator, oversized),
    );
}

test "identical prompt builds have stable bytes" {
    const context = "## /repo/AGENTS.md\n\nstable instruction\n";
    const first = try buildSystemPromptWithContext(testing.allocator, context);
    defer testing.allocator.free(first);
    const second = try buildSystemPromptWithContext(testing.allocator, context);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}
