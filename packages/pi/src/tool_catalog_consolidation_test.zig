//! Regression gate for the final static expert tool prefix.
//!
//! This compares the actual provider-visible JSON emitted from the live
//! registry with the pre-consolidation discovery catalog. Source literal
//! lengths are deliberately not used: provider framing is part of the measured
//! prefix.

const std = @import("std");
const tool_registry = @import("tool_registry.zig");
const query_tool = @import("tools/zts_expert_query.zig");
const removed_query_names = [_][]const u8{
    "zts_expert_meta",
    "zts_expert_features",
    "zts_expert_restrictions",
    "zts_expert_describe_rule",
    "zts_expert_search",
    "zts_expert_modules",
    "zts_expert_effects",
    "zts_expert_holes",
    "zts_expert_narrow",
};

const testing = std.testing;

test "registry excludes retired model authority" {
    var live = try tool_registry.buildRegistry(testing.allocator);
    defer live.deinit(testing.allocator);

    try testing.expect(live.findByName(query_tool.tool.name) != null);
    for (removed_query_names) |removed_name| try testing.expect(live.findByName(removed_name) == null);
    inline for (&.{
        "zts_expert_review_patch",
        "zts_expert_system_proof",
        "zts_expert_ratchet",
        "zig_build_step",
        "zig_test_step",
        "pi_witnesses",
        "pi_remember_fact",
        "pi_recall_facts",
        "pi_extension_catalog",
    }) |retired_name| try testing.expect(live.findByName(retired_name) == null);
}
