//! The capability profiles: the named ceilings of `docs/consumer-contract.md`
//! section 4.3.
//!
//! The table is here, in `zts-base`, so that the compiler can enforce what the
//! vocabulary envelope publishes (M4 T5b). `packages/tools/src/vocab_envelope.zig`
//! reads the same table and publishes it; it holds no copy.
//!
//! The row order is a wire contract. `ZTDCL1` encodes a declaration's ceiling
//! profile as its index in `profiles`: 0 `boundary`, 1 `adapter`, 2 `ledger`.
//! Append a new profile; never reorder or remove one.
//!
//! This file is in the `zts-base` tier and imports `std` and
//! `module_authorization.zig`, a file of the same tier.

const std = @import("std");
const module_authorization = @import("module_authorization.zig");

pub const ModuleCapability = module_authorization.ModuleCapability;

/// A named ceiling from section 4.3. The declaration is in code rather than in
/// the document because a gate cannot check prose: while the profile table lived
/// only in Markdown it was the one alphabet with no source to compare against,
/// and it shipped twice with an error nobody could have caught mechanically.
/// The `adapter` row named `network` without `runtime_callback`, so it could not
/// reach a wrapped system at all, which is the arrangement section 9 exists for.
pub const Profile = struct {
    name: []const u8,
    /// Capability categories the profile admits.
    categories: []const ModuleCapability,
    /// Modules refused by name despite falling inside `categories`. A category
    /// list alone does not deliver the no-store property: `zttp:cache` needs
    /// only `clock` and `policy_check`, and `cacheGet` returns a value a
    /// separate request wrote.
    excluded_modules: []const []const u8,
    /// Whether the profile requires the handler to carry `read_only`. This
    /// bounds effects and is a different question from retained storage.
    requires_read_only: bool,
    /// What the profile is for. Prose, but it belongs beside the declaration
    /// rather than in the document, or the two drift the way the counts did.
    purpose: []const u8,
};

pub const profiles = [_]Profile{
    .{
        .name = "boundary",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit" },
        .requires_read_only = true,
        .purpose = "The no-store handler of section 8",
    },
    .{
        .name = "adapter",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check, .network, .runtime_callback },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit" },
        .requires_read_only = false,
        .purpose = "The proven adapter of section 9",
    },
    .{
        .name = "ledger",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check, .sqlite },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit", "zttp:sql" },
        .requires_read_only = false,
        .purpose = "A declaration naming an application invariant, which has nowhere else to live",
    },
};

/// The profile named `name`, or null. The comparison is exact and
/// case-sensitive.
pub fn findProfile(name: []const u8) ?*const Profile {
    for (&profiles) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// The index of `profile` in `profiles`, which is its `ZTDCL1` wire code.
/// `profile` must point into `profiles`; `findProfile` returns only such
/// pointers.
pub fn indexOf(profile: *const Profile) u8 {
    for (&profiles, 0..) |*p, i| {
        if (p == profile) return @intCast(i);
    }
    unreachable;
}

const testing = std.testing;

test "profile order is the ZTDCL1 wire order: boundary, adapter, ledger" {
    try testing.expectEqual(@as(usize, 3), profiles.len);
    try testing.expectEqualStrings("boundary", profiles[0].name);
    try testing.expectEqualStrings("adapter", profiles[1].name);
    try testing.expectEqualStrings("ledger", profiles[2].name);
    for (&profiles, 0..) |*p, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), indexOf(p));
        try testing.expectEqual(p, findProfile(p.name).?);
    }
}

test "findProfile refuses a name that is not in the table" {
    try testing.expectEqual(@as(?*const Profile, null), findProfile("Boundary"));
    try testing.expectEqual(@as(?*const Profile, null), findProfile(""));
    try testing.expectEqual(@as(?*const Profile, null), findProfile("store"));
}

test "every profile admits at least one category and names a purpose" {
    for (profiles) |p| {
        try testing.expect(p.categories.len > 0);
        try testing.expect(p.name.len > 0);
        try testing.expect(p.purpose.len > 0);
    }
}
