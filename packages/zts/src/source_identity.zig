//! Canonical source-profile identity stamped into compiled artifacts.
//!
//! This module is the single point that joins the closed profile names from
//! `zts-base` with the compiler-owned grammar and semantics registries.

const std = @import("std");

const contract_types = @import("zts-contracts").contract_types;
const grammar_registry = @import("grammar_registry.zig");
const semantics = @import("semantics.zig");

fn hashHexRaw(hex: [64]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &hex) catch unreachable;
    return out;
}

pub fn forPath(_: []const u8) contract_types.SourceIdentity {
    return .{
        .core_grammar_hash = hashHexRaw(grammar_registry.grammarHash()),
        .semantics_hash = hashHexRaw(semantics.semanticsHash()),
    };
}

test "source identity binds the core grammar and semantics" {
    const core = forPath("handler.ts");
    try std.testing.expect(core.isStamped());
    try std.testing.expectEqual(contract_types.CoreProfile.model_1, core.core_profile);
}
