//! Canonical source-profile identity stamped into compiled artifacts.
//!
//! This module is the single point that joins the closed profile names from
//! `zts-base` with the compiler-owned grammar and semantics registries.

const std = @import("std");

const contract_types = @import("zts-contracts").contract_types;
const grammar_registry = @import("grammar_registry.zig");
const semantics = @import("semantics.zig");
const tsx_frontend_registry = @import("tsx_frontend_registry.zig");

fn hashHexRaw(hex: [64]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &hex) catch unreachable;
    return out;
}

pub fn forPath(path: []const u8) contract_types.SourceIdentity {
    return .{
        .core_grammar_hash = hashHexRaw(grammar_registry.grammarHash()),
        .semantics_hash = hashHexRaw(semantics.semanticsHash()),
        .frontend = if (std.mem.endsWith(u8, path, ".tsx")) .{
            .profile = .tsx_1,
            .grammar_hash = hashHexRaw(tsx_frontend_registry.grammarHash()),
        } else null,
    };
}

test "source identity binds core and optional TSX frontend" {
    const core = forPath("handler.ts");
    try std.testing.expect(core.isStamped());
    try std.testing.expectEqual(contract_types.CoreProfile.model_1, core.core_profile);
    try std.testing.expect(core.frontend == null);

    const tsx = forPath("handler.tsx");
    try std.testing.expect(tsx.isStamped());
    try std.testing.expectEqual(contract_types.SourceFrontendProfile.tsx_1, tsx.frontend.?.profile);
    try std.testing.expect(!std.mem.eql(u8, &tsx.frontend.?.grammar_hash, &core.core_grammar_hash));
}
