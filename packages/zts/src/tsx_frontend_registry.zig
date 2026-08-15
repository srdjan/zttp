//! Machine-readable identity of the optional `zts-tsx-1` source frontend.
//!
//! The core grammar contains no JSX production. This registry describes the
//! only additional authored syntax accepted for `.tsx` files and binds it to
//! the core grammar it lowers into. A cache keyed only by these rows would be
//! stale when the target core changes, so the hash includes `grammarHash()`.

const std = @import("std");
const grammar_registry = @import("grammar_registry.zig");
const profile_identity = @import("zts-base").profile_identity;

pub const profile_id = profile_identity.tsx_frontend_profile.id();
pub const lowering_target = "h(tag, props, ...children)";

pub const Production = struct {
    name: []const u8,
    rhs: []const u8,
};

pub const productions = [_]Production{
    .{
        .name = "TsxSource",
        .rhs = "CoreSource with TsxElement or TsxFragment where PrimaryExpr is expected",
    },
    .{
        .name = "TsxElement",
        .rhs = "\"<\" TagName Attribute* (\"/>\" | \">\" TsxChild* \"</\" TagName \">\")",
    },
    .{
        .name = "TsxFragment",
        .rhs = "\"<>\" TsxChild* \"</>\"",
    },
    .{
        .name = "TagName",
        .rhs = "LowerTag | ComponentName",
    },
    .{
        .name = "LowerTag",
        .rhs = "LowerIdent (\"-\" Ident)*",
    },
    .{
        .name = "ComponentName",
        .rhs = "UpperIdent (\".\" Ident)*",
    },
    .{
        .name = "Attribute",
        .rhs = "AttributeName [\"=\" AttributeValue] | \"{\" \"...\" Expr \"}\"",
    },
    .{
        .name = "AttributeName",
        .rhs = "Ident (\"-\" Ident)*",
    },
    .{
        .name = "AttributeValue",
        .rhs = "String | \"{\" Expr \"}\"",
    },
    .{
        .name = "TsxChild",
        .rhs = "Text | \"{\" Expr \"}\" | TsxElement | TsxFragment",
    },
};

pub fn findByName(name: []const u8) ?*const Production {
    for (&productions) |*production| {
        if (std.mem.eql(u8, production.name, name)) return production;
    }
    return null;
}

fn hashProductions(rows: []const Production, core_hash: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(profile_id);
    hasher.update("\x00");
    hasher.update(lowering_target);
    hasher.update("\x00");
    hasher.update(core_hash);
    hasher.update("\x01");
    for (rows) |production| {
        hasher.update(production.name);
        hasher.update("\x00");
        hasher.update(production.rhs);
        hasher.update("\x01");
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

pub fn grammarHash() [64]u8 {
    const core_hash = grammar_registry.grammarHash();
    return hashProductions(&productions, &core_hash);
}

test "TSX frontend grammar identity is stable and bound to the core" {
    const first = grammarHash();
    try std.testing.expectEqualSlices(u8, &first, &grammarHash());
    for (first) |byte| {
        try std.testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }

    const core_hash = grammar_registry.grammarHash();
    var changed_core = core_hash;
    changed_core[0] = if (changed_core[0] == '0') '1' else '0';
    try std.testing.expect(!std.mem.eql(
        u8,
        &hashProductions(&productions, &core_hash),
        &hashProductions(&productions, &changed_core),
    ));
}

test "TSX frontend grammar identity covers every production field" {
    const core_hash = grammar_registry.grammarHash();
    const base = [_]Production{.{ .name = "A", .rhs = "B" }};
    const name_changed = [_]Production{.{ .name = "C", .rhs = "B" }};
    const rhs_changed = [_]Production{.{ .name = "A", .rhs = "D" }};
    const expected = hashProductions(&base, &core_hash);
    try std.testing.expect(!std.mem.eql(u8, &expected, &hashProductions(&name_changed, &core_hash)));
    try std.testing.expect(!std.mem.eql(u8, &expected, &hashProductions(&rhs_changed, &core_hash)));
}

test "TSX frontend grammar has a non-empty closed production table" {
    try std.testing.expect(productions.len >= 10);
    for (productions, 0..) |production, index| {
        try std.testing.expect(production.name.len > 0);
        try std.testing.expect(production.rhs.len > 0);
        for (productions[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, production.name, other.name));
        }
    }
}
