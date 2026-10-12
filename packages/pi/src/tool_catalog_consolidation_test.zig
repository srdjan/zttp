//! Regression gate for the final static expert tool prefix.
//!
//! This compares the actual provider-visible JSON emitted from the live
//! registry with the pre-consolidation discovery catalog. Source literal
//! lengths are deliberately not used: provider framing is part of the measured
//! prefix.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const registry_mod = @import("registry/registry.zig");
const tool_registry = @import("tool_registry.zig");
const tool_catalog = @import("providers/tool_catalog.zig");
const deepseek = @import("providers/deepseek/client.zig");
const local = @import("providers/local/client.zig");

const query_tool = @import("tools/zts_expert_query.zig");
const legacy_query_names = [_][]const u8{
    "zts_expert_meta",
    "zts_expert_features",
    "zts_expert_restrictions",
    "zts_expert_describe_rule",
    "zts_expert_search",
    "zts_expert_modules",
    "zts_expert_effects",
    "zts_expert_holes",
    "zts_expert_narrow",
    "zts_expert_ratchet",
};

const ProviderProjection = enum { deepseek, local };

const ExpectedPrefix = struct {
    /// Exact pre-cutover provider bytes measured at `ede92d63`, before any
    /// unified-query source edit. This is the denominator of the 40% gate.
    legacy_bytes: usize,
    live_bytes: usize,
    live_sha256: []const u8,
};

fn expectedPrefix(provider: ProviderProjection) ExpectedPrefix {
    return switch (provider) {
        .deepseek, .local => .{
            .legacy_bytes = 20_177,
            .live_bytes = 11_775,
            .live_sha256 = "537aaa9f6a8ecae607c68165de320a7fd5116c3deeb81b40c3dc2bb096ca2ab7",
        },
    };
}

fn serialize(
    allocator: std.mem.Allocator,
    provider: ProviderProjection,
    registry: *const registry_mod.Registry,
) ![]u8 {
    var out = TextBuffer.init(allocator);
    defer out.deinit();
    switch (provider) {
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

    try testing.expect(live.findByName(query_tool.tool.name) != null);
    for (legacy_query_names) |legacy_name| try testing.expect(live.findByName(legacy_name) == null);
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
