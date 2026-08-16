//! Regression gate for the final static expert tool prefix.
//!
//! This compares the actual provider-visible JSON emitted from the live
//! registry with the pre-consolidation discovery catalog. Source literal
//! lengths are deliberately not used: provider framing and Anthropic's cache
//! marker are part of the measured prefix.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const registry_mod = @import("registry/registry.zig");
const tool_registry = @import("tool_registry.zig");
const tool_catalog = @import("providers/tool_catalog.zig");
const openai = @import("providers/openai/client.zig");
const anthropic = @import("providers/anthropic/tools_schema.zig");
const deepseek = @import("providers/deepseek/client.zig");
const local = @import("providers/local/client.zig");

const query_tool = @import("tools/zts_expert_query.zig");
const meta_tool = @import("tools/zts_expert_meta.zig");
const features_tool = @import("tools/zts_expert_features.zig");
const restrictions_tool = @import("tools/zts_expert_restrictions.zig");
const describe_rule_tool = @import("tools/zts_expert_describe_rule.zig");
const search_tool = @import("tools/zts_expert_search.zig");
const modules_tool = @import("tools/zts_expert_modules.zig");
const effects_tool = @import("tools/zts_expert_effects.zig");
const holes_tool = @import("tools/zts_expert_holes.zig");
const narrow_tool = @import("tools/zts_expert_narrow.zig");
const ratchet_tool = @import("tools/zts_expert_ratchet.zig");

const legacy_queries = [_]registry_mod.ToolDef{
    meta_tool.tool,
    features_tool.tool,
    restrictions_tool.tool,
    describe_rule_tool.tool,
    search_tool.tool,
    modules_tool.tool,
    effects_tool.tool,
    holes_tool.tool,
    narrow_tool.tool,
    ratchet_tool.tool,
};

const ProviderProjection = enum { openai, anthropic, deepseek, local };
const retired_model_routes: usize = 5;

const ExpectedPrefix = struct {
    /// Exact pre-cutover provider bytes measured at `ede92d63`, before any
    /// unified-query source edit. This is the denominator of the 40% gate.
    legacy_bytes: usize,
    live_bytes: usize,
    live_sha256: []const u8,
};

fn expectedPrefix(provider: ProviderProjection) ExpectedPrefix {
    return switch (provider) {
        .openai => .{
            .legacy_bytes = 19_722,
            .live_bytes = 11_502,
            .live_sha256 = "1515aa4db49bf7795ac004df02098782c153d1ef6dd7097e40424ff50d3ea3af",
        },
        .anthropic => .{
            .legacy_bytes = 19_199,
            .live_bytes = 11_203,
            .live_sha256 = "f7aedefe8ee88d20435b5a4e793c28ec4993b1835ec036f84e30035d024e795e",
        },
        .deepseek, .local => .{
            .legacy_bytes = 20_177,
            .live_bytes = 11_775,
            .live_sha256 = "537aaa9f6a8ecae607c68165de320a7fd5116c3deeb81b40c3dc2bb096ca2ab7",
        },
    };
}

fn buildLegacyRegistry(allocator: std.mem.Allocator) !registry_mod.Registry {
    var live = try tool_registry.buildRegistry(allocator);
    defer live.deinit(allocator);

    var legacy: registry_mod.Registry = .{};
    errdefer legacy.deinit(allocator);
    for (live.list()) |definition| {
        if (std.mem.eql(u8, definition.name, query_tool.tool.name)) continue;
        var legacy_definition = definition;
        legacy_definition.model_exposure = .visible;
        try legacy.register(allocator, legacy_definition);
    }
    for (legacy_queries) |definition| try legacy.register(allocator, definition);
    return legacy;
}

fn serialize(
    allocator: std.mem.Allocator,
    provider: ProviderProjection,
    registry: *const registry_mod.Registry,
) ![]u8 {
    var out = TextBuffer.init(allocator);
    defer out.deinit();
    switch (provider) {
        .openai => try openai.writeToolsArray(out.writer(), registry),
        .anthropic => try anthropic.writeToolsArray(out.writer(), registry),
        .deepseek => try deepseek.writeToolsArray(out.writer(), registry),
        .local => try local.writeToolsArray(out.writer(), registry),
    }
    return out.toOwnedSlice();
}

fn rawDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const testing = std.testing;

test "unified compiler query removes old model authority and at least forty percent of every provider prefix" {
    var live = try tool_registry.buildRegistry(testing.allocator);
    defer live.deinit(testing.allocator);
    var legacy = try buildLegacyRegistry(testing.allocator);
    defer legacy.deinit(testing.allocator);

    try testing.expect(live.findByName(query_tool.tool.name) != null);
    for (legacy_queries) |definition| try testing.expect(live.findByName(definition.name) == null);
    try testing.expectEqual(
        tool_catalog.count(&legacy) - (legacy_queries.len - 1) - retired_model_routes,
        tool_catalog.count(&live),
    );

    inline for (comptime std.enums.values(ProviderProjection)) |provider| {
        const after = try serialize(testing.allocator, provider, &live);
        defer testing.allocator.free(after);
        const digest = rawDigest(after);
        const expected = expectedPrefix(provider);
        try testing.expectEqual(expected.live_bytes, after.len);
        try testing.expectEqualStrings(expected.live_sha256, &digest);
        try testing.expect(after.len * 100 <= expected.legacy_bytes * 60);
    }

    const neutral_hash = tool_catalog.providerNeutralHash(&live);
    try testing.expectEqual(@as(usize, 21), tool_catalog.count(&live));
    try testing.expectEqualStrings(
        "b190e14269c9c021d71467bcdbc174141df2e7c5df5bbe5be3cb9e55092b354f",
        &neutral_hash,
    );
}
