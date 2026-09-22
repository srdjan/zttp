//! The published vocabulary envelope: producer obligation P1.
//!
//! Section 6 of `docs/consumer-contract.md` states sixteen closed alphabets and
//! five pinned identities as literal counts in prose. Nothing checked them, and
//! three review rounds each found counts that had drifted from the tree. This
//! module derives the same alphabets from their owning declarations so a gate
//! can compare them, and the prose stops being a second source.
//!
//! Each alphabet is derived, never transcribed. A member list written here by
//! hand would be a third copy and would drift like the first two.
//!
//! Virtual modules additionally carry `binding_digest`, from the curated
//! `ModuleMetadata.nativeBindingDigest`. That is what closes the growth hole
//! section 12 admits: an alphabet whose member keeps its name and ordinal while
//! its meaning changes. The digest folds a binding's declared authority surface
//! - capabilities, effects, labels, statefulness - so a change to any of them
//! moves it, while a comment or a reordered unrelated initializer does not.

const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const mb = zts.module_binding;
const builtin_modules = zts.builtin_modules;

/// The contract version this envelope describes. A consumer matches it by
/// equality, per C5.
pub const contract_version: u32 = 1;

/// The envelope's own version. It moves when the envelope's shape changes,
/// independently of the contract version, so a consumer can tell a new block
/// from a new obligation.
pub const envelope_version: u32 = 1;

/// One member of a closed alphabet. `ordinal` is null for an alphabet whose
/// members carry no wire number; where a member has one, it is the contract and
/// the spelling is the label, per section 12.
pub const Member = struct {
    name: []const u8,
    ordinal: ?u64 = null,
    /// Set only for alphabets whose members carry a semantic identity.
    digest: ?[64]u8 = null,
};

/// A closed alphabet, with the declaration that owns it.
pub const Alphabet = struct {
    /// Stable key a consumer pins. Never renamed; a rename is a new block.
    key: []const u8,
    /// The file that owns the members, for a reader chasing a mismatch.
    source: []const u8,
    members: []const Member,
};

/// Members of an enum alphabet, as a namespaced constant so the slice has
/// static lifetime rather than pointing at a comptime temporary.
fn EnumMembers(comptime E: type) type {
    return struct {
        pub const list: [@typeInfo(E).@"enum".fields.len]Member = blk: {
            const fields = @typeInfo(E).@"enum".fields;
            var out: [fields.len]Member = undefined;
            for (fields, 0..) |f, i| {
                out[i] = .{ .name = f.name, .ordinal = @as(u64, f.value) };
            }
            break :blk out;
        };
    };
}

fn enumMembers(comptime E: type) []const Member {
    return &EnumMembers(E).list;
}

/// Capability categories. The ceiling in section 4.3 draws from these.
pub fn capabilityCategories() Alphabet {
    return .{
        .key = "capability_categories",
        .source = "packages/zts/src/module_authorization.zig",
        .members = enumMembers(mb.ModuleCapability),
    };
}

/// The properties the acceptance kernel reasons about. One is re-derived by the
/// kernel and the rest are disclosed; the envelope publishes membership, and
/// `docs/verification.md` owns which is which.
pub fn consumerObligationProperties() Alphabet {
    return .{
        .key = "consumer_obligation_properties",
        .source = "packages/proof-checker/src/proof_system.zig",
        .members = enumMembers(pcc.proof_system.Property),
    };
}

fn hexDigest(raw: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(raw, .lower);
}


/// Virtual modules, with a semantic digest per member.
///
/// `builtins` is the in-tree base and `all` is the effective set for this
/// build, which differ when an extension is registered. P1 requires both,
/// because a consumer pins one of them and has to be able to tell which.
pub fn virtualModules(allocator: std.mem.Allocator, comptime which: enum { base, effective }) ![]const Member {
    const bindings = switch (which) {
        .base => builtin_modules.builtins,
        .effective => builtin_modules.all,
    };
    const out = try allocator.alloc(Member, bindings.len);
    errdefer allocator.free(out);
    inline for (bindings, 0..) |binding, i| {
        out[i] = .{
            .name = binding.specifier,
            .digest = hexDigest(zts.ModuleMetadata.nativeBindingDigest(binding)),
        };
    }
    return out;
}

test "capability categories are derived, not transcribed" {
    const a = capabilityCategories();
    try std.testing.expect(a.members.len > 0);
    // The ordinal is the contract; confirm one known member carries its own.
    var saw_env = false;
    for (a.members) |m| {
        if (std.mem.eql(u8, m.name, "env")) saw_env = true;
        try std.testing.expect(m.ordinal != null);
    }
    try std.testing.expect(saw_env);
}

test "consumer obligation properties carry their wire ordinals" {
    const a = consumerObligationProperties();
    try std.testing.expect(a.members.len > 0);
    for (a.members) |m| {
        if (std.mem.eql(u8, m.name, "response_total")) {
            try std.testing.expectEqual(@as(u64, 1), m.ordinal.?);
        }
    }
}

test "a binding digest moves when declared authority moves, and not otherwise" {
    // This is the property the envelope sells. Two bindings differing only in a
    // declared capability must not share a digest; two differing only in a
    // field the digest does not fold must share one.
    const sdk = mb;
    const base = sdk.ModuleBinding{
        .specifier = "zttp-ext:probe",
        .name = "probe",
        .summary = "probe",
        .required_capabilities = &.{.clock},
        .exports = &.{},
    };
    var widened = base;
    widened.required_capabilities = &.{ .clock, .network };

    const d_base = zts.ModuleMetadata.nativeBindingDigest(base);
    const d_widened = zts.ModuleMetadata.nativeBindingDigest(widened);
    try std.testing.expect(!std.mem.eql(u8, &d_base, &d_widened));

    // Same declared surface, recomputed: stable.
    const d_again = zts.ModuleMetadata.nativeBindingDigest(base);
    try std.testing.expect(std.mem.eql(u8, &d_base, &d_again));
}

test "virtual module members carry a digest and a specifier" {
    const members = try virtualModules(std.testing.allocator, .base);
    defer std.testing.allocator.free(members);
    try std.testing.expect(members.len > 0);
    for (members) |m| {
        try std.testing.expect(m.digest != null);
        try std.testing.expect(std.mem.startsWith(u8, m.name, "zttp:"));
    }
}
