//! Builds the stable zts expert system prompt.
//!
//! The always-sent core contains only protocol, first-draft hazards, policy
//! identity, a compact retrieval index, and the complete applicable project
//! instructions. Large registries, reference documents, examples, witnesses,
//! and project memory stay behind read-only tools.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const zts_cli = @import("zts_cli");
const expert_meta = zts_cli.expert_meta;
const skills_catalog = @import("skills/catalog.zig");
const prompts_catalog = @import("prompts/catalog.zig");

/// The complete system prompt, including applicable project instructions,
/// must fit this cap. Content is rejected rather than truncated.
pub const PROMPT_CAP_BYTES: usize = 48 * 1024;

/// The stable protocol and retrieval index have their own tighter gate so a
/// future prompt expansion cannot silently consume the project-instruction
/// budget.
pub const PROTECTED_CORE_CAP_BYTES: usize = 16 * 1024;

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
    \\Produce elegant, idiomatic zts code that passes the running compiler's
    \\verification and obeys every applicable project instruction below.
    \\
    \\Mandatory protocol:
    \\  1. Inspect before editing. Read the current target, search nearby code,
    \\     and run zts_expert_verify_paths before proposing a change.
    \\  2. Prefer compiler-native evidence. For language, module, rule, effect,
    \\     or proof facts, call the live read-only tool instead of relying on
    \\     training data or prose recalled from an earlier turn.
    \\  3. Batch independent read-only calls when useful. Keep reasoning brief.
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
    \\  8. A host [expert workflow] system note is routing help, not user intent
    \\     or language evidence. Confirm its route with live tools.
    \\
    \\First-draft strict-mode hazards:
    \\  - Use canonical ZigTS: named functions for reused helpers; export
    \\    function for public functions; explicit Effects<...> / Proof<...>
    \\    capsules on public helpers; no ternary, compound assignment, call-site
    \\    spread, default parameters, destructure renames, or nested patterns;
    \\    leading object spread only; identifier-or-member template
    \\    interpolations only; ?? for nullish fallback; write
    \\    (a: T | undefined), not (a?: T).
    \\  - Never use as or <T> casts, including in type guards (ZTS042). Avoid
    \\    try/catch, classes, var, null, ==/!=, ++/--, while, and switch. Use
    \\    Result values, plain objects, let/const, undefined, ===/!==, for...of,
    \\    match, and explicit increments.
    \\  - Values returned by validateJson, decodeJson, JSON.parse, step, run,
    \\    and fetch do not need defensive type guards or computed property
    \\    access. Check Result.ok, then use .value and direct fields. Type-guard
    \\    scaffolds and v["key"] trigger ZTS601/ZTS605 and block convergence.
    \\  - fetch and serviceCall URLs must be plain string literals so the host
    \\    is statically known (ZTS602). Put dynamic values in the init object.
    \\  - Never return secret-labelled or credential-labelled values (ZTS400/
    \\    ZTS401). Return only specifically proven non-sensitive fields.
    \\  - A handler that writes durable, sql, or cache state, or returns unknown,
    \\    cannot hold the implicit default proof profile. Preserve an existing
    \\    Spec<...>, or run zts_expert_edit_simulate and declare exactly the
    \\    narrow properties it discharges. Do not claim read_only for a writer.
    \\  - When a file contains hole(), use zts_expert_holes and fill exactly one
    \\    expression with zts_expert_fill_hole. Re-read holes after each fill;
    \\    never regenerate the complete file around a compiler-owned frame.
    \\  - For durable workflows, keep workflow.call, saga, fanout, and follow
    \\    directly inside run(), never inside step() (ZTS509). Retrieve the
    \\    canonical workflow reference before drafting unfamiliar workflow code.
    \\
    \\Essential tool routing:
    \\  Rules by code/name or complete registry -> zts_expert_describe_rule
    \\  Rule keyword search                    -> zts_expert_search
    \\  Allowed and blocked language features -> zts_expert_features
    \\  Language restrictions and rationale   -> zts_expert_restrictions
    \\  Built-in module exports               -> zts_expert_modules
    \\  Compiler and policy metadata          -> zts_expert_meta
    \\  Embedded guide/references/examples    -> zts_expert_reference
    \\  Read/list/search workspace            -> workspace_read_file,
    \\                                           workspace_list_files,
    \\                                           workspace_search_text
    \\  Violation baseline                    -> zts_expert_verify_paths
    \\  Draft veto before apply               -> zts_expert_edit_simulate
    \\  Canonical source/refactor             -> zts_expert_normalize,
    \\                                           zts_expert_canonicalize,
    \\                                           zts_expert_ast_rewrite
    \\  Label paths and inferred effects      -> zts_expert_narrow,
    \\                                           zts_expert_effects
    \\  Holes and compiler-owned frames       -> zts_expert_holes,
    \\                                           zts_expert_fill_hole
    \\  Current property set                  -> zts_expert_ratchet, zts_check
    \\  Patch and system proofs               -> zts_expert_review_patch,
    \\                                           zts_expert_prove_patch,
    \\                                           zts_expert_system_proof,
    \\                                           zts_expert_verify_modules
    \\  Declared Spec state                   -> pi_specs_status
    \\  Goal proof and semantic repair        -> pi_goal_check,
    \\                                           pi_repair_plan,
    \\                                           pi_goal_candidate
    \\  Bound canonical repair preview        -> zts_expert_canonicalize,
    \\                                           pi_apply_repair_plan
    \\  Witness corpus                        -> pi_witnesses
    \\  Project memory                        -> pi_recall_facts,
    \\                                           pi_remember_fact
    \\  Extension availability               -> pi_extension_catalog
    \\  Build and test steps                  -> zig_build_step, zig_test_step
    \\  Generate proof-derived tests          -> workspace_gen_tests
    \\
    \\Registered tools are described by the stable tool schemas sent with this
    \\prompt. Do not infer arguments from this routing index. Retrieve large
    \\reference material only when it is relevant to the current request.
    \\
;

const epilogue =
    \\
    \\============================================================
    \\END OF PERSONA
    \\============================================================
    \\
    \\The compiler veto is mechanical. Emitting text cannot bypass it. Make the
    \\first draft pass; the retry loop is insurance, not routine.
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
    try writePolicyIdentity(w);
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

fn writePolicyIdentity(writer: anytype) !void {
    try writeBanner(writer, "POLICY IDENTITY");
    const info = expert_meta.compute();
    try expert_meta.writeText(writer, &info);
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

test "stable core retains identity veto approval and first-draft rules" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);

    const required = [_][]const u8{
        "native zts coding agent",
        "Inspect before editing",
        "compiler veto",
        "active approval policy",
        "apply_edit must be the only tool call",
        "Never claim a proposal was applied",
        "First-draft strict-mode hazards",
        "Never use as or <T> casts",
        "Spec<...>",
        "POLICY IDENTITY",
    };
    for (required) |needle| {
        try testing.expect(std.mem.indexOf(u8, prompt, needle) != null);
    }
    try testing.expect(prompt.len <= PROTECTED_CORE_CAP_BYTES);
}

test "stable core routes removed reference material through read-only tools" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_describe_rule") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_features") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_restrictions") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_modules") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "zts_expert_reference") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "pi_witnesses") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "pi_recall_facts") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "LIVE SNAPSHOT") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "CANONICAL EXAMPLES") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "WITNESSED FAILURES") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "PROJECT MEMORY") == null);
}

test "policy identity stays in the stable core" {
    const prompt = try buildSystemPrompt(testing.allocator);
    defer testing.allocator.free(prompt);
    try testing.expect(std.mem.indexOf(u8, prompt, "0.18.0") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "2026.04.2") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "hash:") != null);
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
