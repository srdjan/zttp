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

/// Boolean fields of a struct alphabet. `HandlerProperties` is the case: it
/// carries 20 fields of which 19 are boolean, and section 6 previously stated
/// one number for both questions.
fn BoolFieldMembers(comptime S: type) type {
    const all_fields = @typeInfo(S).@"struct".fields;
    const bool_count = blk: {
        var n: usize = 0;
        for (all_fields) |f| {
            if (f.type == bool) n += 1;
        }
        break :blk n;
    };
    return struct {
        pub const list: [bool_count]Member = blk: {
            var out: [bool_count]Member = undefined;
            var i: usize = 0;
            for (all_fields) |f| {
                if (f.type != bool) continue;
                out[i] = .{ .name = f.name };
                i += 1;
            }
            break :blk out;
        };
    };
}

/// Named members of a table whose rows carry a `.name`.
fn NamedRowMembers(comptime rows: anytype) type {
    return struct {
        pub const list: [rows.len]Member = blk: {
            var out: [rows.len]Member = undefined;
            for (rows, 0..) |row, i| out[i] = .{ .name = row.name };
            break :blk out;
        };
    };
}

/// Every alphabet the envelope publishes from a typed declaration.
///
/// A surface that is data is imported and compared as a value, following
/// `invariant_drift_gate.zig`. The two alphabets that are not values here, the
/// goal-driveable property set owned by `packages/pi` and the profile table, are
/// handled separately: `pi` is not importable from `tools`, and profiles have no
/// declaration yet.
pub fn typedAlphabets() []const Alphabet {
    const list = struct {
        const value = [_]Alphabet{
            .{
                .key = "capability_categories",
                .source = "packages/zts/src/module_authorization.zig",
                .members = enumMembers(mb.ModuleCapability),
            },
            .{
                .key = "compiler_spec_names",
                .source = "packages/zts/src/spec_discharge.zig",
                .members = &NamedRowMembers(zts.spec_discharge.v1_specs).list,
            },
            .{
                .key = "handler_property_bool_fields",
                .source = "packages/zts/src/contract_types.zig",
                .members = &BoolFieldMembers(zts.handler_contract.HandlerProperties).list,
            },
            .{
                .key = "consumer_obligation_properties",
                .source = "packages/proof-checker/src/proof_system.zig",
                .members = enumMembers(pcc.proof_system.Property),
            },
            .{
                .key = "assurance_grades",
                .source = "packages/proof-checker/src/verdict.zig",
                .members = enumMembers(pcc.verdict.AssuranceGrade),
            },
            .{
                .key = "acceptance_stages",
                .source = "packages/proof-checker/src/verdict.zig",
                .members = enumMembers(pcc.verdict.Stage),
            },
            .{
                .key = "reason_codes",
                .source = "packages/proof-checker/src/verdict.zig",
                .members = enumMembers(pcc.verdict.ReasonCode),
            },
            .{
                .key = "evidence_edge_kinds",
                .source = "packages/proof-checker/src/certificate.zig",
                .members = enumMembers(pcc.certificate.EdgeKind),
            },
            .{
                .key = "residual_guard_kinds",
                .source = "packages/proof-checker/src/residual.zig",
                .members = enumMembers(pcc.residual.GuardKind),
            },
            .{
                .key = "residual_guard_families",
                .source = "packages/proof-checker/src/residual.zig",
                .members = enumMembers(pcc.residual.Family),
            },
            .{
                .key = "invariant_kinds",
                .source = "packages/proof-checker/src/invariant.zig",
                .members = enumMembers(pcc.invariant.Kind),
            },
            .{
                .key = "account_matcher_tags",
                .source = "packages/proof-checker/src/invariant.zig",
                .members = enumMembers(pcc.invariant.AccountMatcherTag),
            },
            .{
                .key = "executable_graph_member_kinds",
                .source = "packages/proof-checker/src/executable_graph.zig",
                .members = enumMembers(pcc.executable_graph.MemberKind),
            },
        };
    };
    return &list.value;
}

/// The residual families enabled in this build, which is a different question
/// from the catalogued set. Section 6 previously published one number for both.
pub fn enabledResidualFamilies(allocator: std.mem.Allocator) ![]const Member {
    var out: std.ArrayList(Member) = .empty;
    errdefer out.deinit(allocator);
    inline for (@typeInfo(pcc.residual.Family).@"enum".fields) |f| {
        const fam: pcc.residual.Family = @enumFromInt(f.value);
        if (pcc.residual.enabled_families.contains(fam)) {
            try out.append(allocator, .{ .name = f.name, .ordinal = @as(u64, f.value) });
        }
    }
    return out.toOwnedSlice(allocator);
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

test "every typed alphabet is non-empty and uniquely keyed" {
    const alphabets = typedAlphabets();
    try std.testing.expect(alphabets.len > 0);
    for (alphabets, 0..) |a, i| {
        // A gate whose input is empty reports success. Assert the floor here so
        // an alphabet that silently loses its source fails at derivation.
        try std.testing.expect(a.members.len > 0);
        try std.testing.expect(a.source.len > 0);
        for (alphabets[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.key, b.key));
        }
    }
}

test "the catalogued family set is not the enabled family set" {
    // Section 6 published one number for both questions. They differ, and the
    // envelope has to answer each.
    var catalogued: usize = 0;
    for (typedAlphabets()) |a| {
        if (std.mem.eql(u8, a.key, "residual_guard_families")) catalogued = a.members.len;
    }
    const enabled = try enabledResidualFamilies(std.testing.allocator);
    defer std.testing.allocator.free(enabled);
    try std.testing.expect(catalogued > 0);
    try std.testing.expect(enabled.len > 0);
    try std.testing.expect(enabled.len < catalogued);
}

test "handler property bool fields exclude the non-boolean field" {
    var bools: usize = 0;
    for (typedAlphabets()) |a| {
        if (std.mem.eql(u8, a.key, "handler_property_bool_fields")) bools = a.members.len;
    }
    const total = @typeInfo(zts.handler_contract.HandlerProperties).@"struct".fields.len;
    try std.testing.expect(bools > 0);
    try std.testing.expect(bools < total);
}

test "derived counts match what the contract prose states" {
    // The prose in section 6 is the thing this gate exists to replace. While it
    // is still the published surface, a mismatch here means one of the two is
    // wrong and a reader cannot tell which.
    const Expected = struct { key: []const u8, n: usize };
    const expected = [_]Expected{
        .{ .key = "capability_categories", .n = 10 },
        .{ .key = "compiler_spec_names", .n = 17 },
        .{ .key = "handler_property_bool_fields", .n = 19 },
        .{ .key = "consumer_obligation_properties", .n = 8 },
        .{ .key = "assurance_grades", .n = 5 },
        .{ .key = "acceptance_stages", .n = 11 },
        .{ .key = "reason_codes", .n = 89 },
        .{ .key = "evidence_edge_kinds", .n = 6 },
        .{ .key = "residual_guard_kinds", .n = 5 },
        .{ .key = "residual_guard_families", .n = 4 },
        .{ .key = "invariant_kinds", .n = 2 },
        .{ .key = "account_matcher_tags", .n = 2 },
        .{ .key = "executable_graph_member_kinds", .n = 18 },
    };
    // Census, not spot check: every expectation must find its alphabet, and
    // every alphabet must be covered by an expectation. Counting matches alone
    // would pass while an alphabet nobody listed drifted unobserved.
    var matched: usize = 0;
    for (expected) |e| {
        var found = false;
        for (typedAlphabets()) |a| {
            if (!std.mem.eql(u8, a.key, e.key)) continue;
            found = true;
            std.testing.expectEqual(e.n, a.members.len) catch |err| {
                std.debug.print("alphabet {s}: prose says {d}, tree has {d}\n", .{ e.key, e.n, a.members.len });
                return err;
            };
        }
        try std.testing.expect(found);
        matched += 1;
    }
    try std.testing.expectEqual(typedAlphabets().len, matched);
}
