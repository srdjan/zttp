//! Stable source-profile identifiers shared by compiler, contract codec,
//! runtime, and tooling. This leaf owns names only. Grammar and semantics
//! hashes are computed by the compiler registries and stored beside these
//! closed identifiers in artifacts.

const std = @import("std");

pub const CoreProfile = enum {
    model_1,

    pub fn id(self: CoreProfile) []const u8 {
        return switch (self) {
            .model_1 => "zts-model-1",
        };
    }

    pub fn parse(value: []const u8) ?CoreProfile {
        if (std.mem.eql(u8, value, CoreProfile.model_1.id())) return .model_1;
        return null;
    }
};

pub const core_profile = CoreProfile.model_1;

test "profile identifiers round trip through their closed enums" {
    try std.testing.expectEqual(CoreProfile.model_1, CoreProfile.parse(core_profile.id()).?);
    try std.testing.expect(CoreProfile.parse("zts-advanced-1") == null);
}
