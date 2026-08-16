//! One authority for the first-party expert tool registry and its presets.

const std = @import("std");
const registry_mod = @import("registry/registry.zig");

const query_tool = @import("tools/zts_expert_query.zig");
const verify_paths_tool = @import("tools/zts_expert_verify_paths.zig");
const canonicalize_tool = @import("tools/zts_expert_canonicalize.zig");
const normalize_tool = @import("tools/zts_expert_normalize.zig");
const review_patch_tool = @import("tools/zts_expert_review_patch.zig");
const prove_patch_tool = @import("tools/zts_expert_prove_patch.zig");
const system_proof_tool = @import("tools/zts_expert_system_proof.zig");
const verify_modules_tool = @import("tools/zts_expert_verify_modules.zig");
const workspace_list_files_tool = @import("tools/workspace_list_files.zig");
const workspace_read_file_tool = @import("tools/workspace_read_file.zig");
const workspace_search_text_tool = @import("tools/workspace_search_text.zig");
const zts_check_tool = @import("tools/zts_check.zig");
const zig_build_step_tool = @import("tools/zig_build_step.zig");
const zig_test_step_tool = @import("tools/zig_test_step.zig");
const gen_tests_tool = @import("tools/gen_tests.zig");
const pi_goal_check_tool = @import("tools/pi_goal_check.zig");
const pi_goal_candidate_tool = @import("tools/pi_goal_candidate.zig");
const pi_repair_plan_tool = @import("tools/pi_repair_plan.zig");
const pi_apply_repair_plan_tool = @import("tools/pi_apply_repair_plan.zig");
const ast_rewrite_tool = @import("tools/zts_expert_ast_rewrite.zig");
const pi_specs_status_tool = @import("tools/pi_specs_status.zig");
const pi_witnesses_tool = @import("tools/pi_witnesses.zig");
const pi_remember_fact_tool = @import("tools/pi_remember_fact.zig");
const pi_recall_facts_tool = @import("tools/pi_recall_facts.zig");
const pi_extension_catalog_tool = @import("tools/pi_extension_catalog.zig");
const fill_hole_tool = @import("tools/zts_expert_fill_hole.zig");

const Registry = registry_mod.Registry;
const ToolDef = registry_mod.ToolDef;

/// Group tools by user-facing capability. A bundle is not an authorization
/// boundary; each `ToolDef.effect` remains the authority for that decision.
pub const Bundle = enum {
    workspace,
    analysis,
    build,
    repair,
    memory,
    authoring,
};

const workspace_bundle = [_]ToolDef{
    workspace_read_file_tool.tool,
    workspace_list_files_tool.tool,
    workspace_search_text_tool.tool,
};

const analysis_bundle = [_]ToolDef{
    query_tool.tool,
    verify_paths_tool.tool,
    canonicalize_tool.tool,
    normalize_tool.tool,
    review_patch_tool.tool,
    prove_patch_tool.tool,
    system_proof_tool.tool,
    verify_modules_tool.tool,
    fill_hole_tool.tool,
};

const build_bundle = [_]ToolDef{
    zts_check_tool.tool,
    zig_build_step_tool.tool,
    zig_test_step_tool.tool,
    pi_specs_status_tool.tool,
};

const repair_bundle = [_]ToolDef{
    pi_goal_check_tool.tool,
    pi_goal_candidate_tool.tool,
    pi_repair_plan_tool.tool,
    pi_apply_repair_plan_tool.tool,
    ast_rewrite_tool.tool,
};

const memory_bundle = [_]ToolDef{
    pi_witnesses_tool.tool,
    pi_remember_fact_tool.tool,
    pi_recall_facts_tool.tool,
    pi_extension_catalog_tool.tool,
};

const authoring_bundle = [_]ToolDef{gen_tests_tool.tool};

pub fn bundleTools(bundle: Bundle) []const ToolDef {
    return switch (bundle) {
        .workspace => &workspace_bundle,
        .analysis => &analysis_bundle,
        .build => &build_bundle,
        .repair => &repair_bundle,
        .memory => &memory_bundle,
        .authoring => &authoring_bundle,
    };
}

fn registerBundle(registry: *Registry, allocator: std.mem.Allocator, bundle: Bundle) !void {
    for (bundleTools(bundle)) |tool| try registry.register(allocator, tool);
}

pub fn buildMinimalRegistry(allocator: std.mem.Allocator) !Registry {
    var registry: Registry = .{};
    errdefer registry.deinit(allocator);
    try registerBundle(&registry, allocator, .workspace);
    return registry;
}

pub fn buildRegistry(allocator: std.mem.Allocator) !Registry {
    var registry: Registry = .{};
    errdefer registry.deinit(allocator);
    inline for (comptime std.enums.values(Bundle)) |bundle| {
        try registerBundle(&registry, allocator, bundle);
    }
    return registry;
}

test "bundles partition the registered catalog" {
    var expected: usize = 0;
    inline for (comptime std.enums.values(Bundle)) |bundle| expected += bundleTools(bundle).len;
    var registry = try buildRegistry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, registry.count());
}
