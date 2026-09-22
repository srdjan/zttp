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
const agent_identity = @import("agent_identity.zig");

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

// ============================================================================
// Capability profiles
// ============================================================================

/// A named ceiling from section 4.3. The declaration is here rather than in the
/// document because a gate cannot check prose: while the profile table lived
/// only in Markdown it was the one alphabet with no source to compare against,
/// and it shipped twice with an error nobody could have caught mechanically.
/// The `adapter` row named `network` without `runtime_callback`, so it could not
/// reach a wrapped system at all, which is the arrangement section 9 exists for.
pub const Profile = struct {
    name: []const u8,
    /// Capability categories the profile admits.
    categories: []const mb.ModuleCapability,
    /// Modules refused by name despite falling inside `categories`. A category
    /// list alone does not deliver the no-store property: `zttp:cache` needs
    /// only `clock` and `policy_check`, and `cacheGet` returns a value a
    /// separate request wrote.
    excluded_modules: []const []const u8,
    /// Whether the profile requires the handler to carry `read_only`. This
    /// bounds effects and is a different question from retained storage.
    requires_read_only: bool,
};

pub const profiles = [_]Profile{
    .{
        .name = "boundary",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit" },
        .requires_read_only = true,
    },
    .{
        .name = "adapter",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check, .network, .runtime_callback },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit" },
        .requires_read_only = false,
    },
    .{
        .name = "ledger",
        .categories = &.{ .env, .clock, .random, .crypto, .stderr, .policy_check, .sqlite },
        .excluded_modules = &.{ "zttp:cache", "zttp:ratelimit", "zttp:sql" },
        .requires_read_only = false,
    },
};

/// Pinned identities, each compared by equality.
pub const Identities = struct {
    certificate_schema: u16,
    proof_system: u16,
    semantics_epoch: u32,
    handler_contract_version: u32,
    agent_protocol_schema: u32,
    policy_hash: [64]u8,
    module_registry_hash: [64]u8,
};

/// The declared default of `HandlerContract.version`, read through reflection
/// rather than by constructing a contract, which would need every field.
fn handlerContractVersion() u32 {
    const fields = @typeInfo(zts.handler_contract.HandlerContract).@"struct".fields;
    inline for (fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "version")) {
            const dv = f.defaultValue() orelse @compileError("HandlerContract.version lost its default");
            return dv;
        }
    }
    @compileError("HandlerContract has no version field");
}

pub fn identities() Identities {
    return .{
        .certificate_schema = pcc.proof_system.schema_version,
        .proof_system = @intFromEnum(pcc.proof_system.ProofSystem.zttp_pcc_v3),
        .semantics_epoch = pcc.proof_system.semantics_epoch,
        .handler_contract_version = handlerContractVersion(),
        .agent_protocol_schema = agent_identity.schema_version,
        .policy_hash = zts.policyHash(),
        .module_registry_hash = zts.ModuleMetadata.builtinRegistryHash(),
    };
}

test "every profile admits only real capability categories" {
    for (profiles) |p| {
        try std.testing.expect(p.categories.len > 0);
        try std.testing.expect(p.name.len > 0);
    }
}

test "the adapter profile can actually reach a wrapped system" {
    // The regression this encoding exists to prevent. `zttp:fetch` requires
    // `network` and `runtime_callback` together; a profile granting only the
    // first cannot call it, which makes section 9's arrangement unreachable.
    const fetch = builtin_modules.fromSpecifier("zttp:fetch") orelse
        return error.FetchBindingMissing;
    var adapter: ?Profile = null;
    for (profiles) |p| {
        if (std.mem.eql(u8, p.name, "adapter")) adapter = p;
    }
    const a = adapter orelse return error.AdapterProfileMissing;
    for (fetch.required_capabilities) |need| {
        var admitted = false;
        for (a.categories) |have| {
            if (have == need) admitted = true;
        }
        if (!admitted) {
            std.debug.print("adapter profile does not admit {s}, which zttp:fetch requires\n", .{@tagName(need)});
            return error.AdapterCannotReachWrappedSystem;
        }
    }
}

test "the boundary profile excludes every module that retains request data" {
    // `zttp:cache` is the case a category list cannot catch. Assert it is
    // refused by name rather than trusting the category filter.
    var boundary: ?Profile = null;
    for (profiles) |p| {
        if (std.mem.eql(u8, p.name, "boundary")) boundary = p;
    }
    const b = boundary orelse return error.BoundaryProfileMissing;
    const cache = builtin_modules.fromSpecifier("zttp:cache") orelse
        return error.CacheBindingMissing;
    // It falls inside the categories, which is why the exclusion is needed.
    for (cache.required_capabilities) |need| {
        var admitted = false;
        for (b.categories) |have| {
            if (have == need) admitted = true;
        }
        try std.testing.expect(admitted);
    }
    var excluded = false;
    for (b.excluded_modules) |m| {
        if (std.mem.eql(u8, m, "zttp:cache")) excluded = true;
    }
    try std.testing.expect(excluded);
}

test "pinned identities match what the contract states" {
    const id = identities();
    try std.testing.expectEqual(@as(u16, 4), id.certificate_schema);
    try std.testing.expectEqual(@as(u16, 3), id.proof_system);
    try std.testing.expectEqual(@as(u32, 1), id.semantics_epoch);
    try std.testing.expectEqual(@as(u32, 18), id.handler_contract_version);
    try std.testing.expectEqual(@as(u32, 2), id.agent_protocol_schema);
}

// ============================================================================
// Serialization
// ============================================================================

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeMembers(w: *std.Io.Writer, members: []const Member) !void {
    try w.writeAll("[\n");
    for (members, 0..) |m, i| {
        try w.writeAll("      { \"name\": ");
        try writeJsonString(w, m.name);
        if (m.ordinal) |o| try w.print(", \"ordinal\": {d}", .{o});
        if (m.digest) |d| {
            try w.writeAll(", \"binding_digest\": ");
            try writeJsonString(w, &d);
        }
        try w.writeAll(" }");
        if (i + 1 != members.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try w.writeAll("    ]");
}

/// Render the envelope. The output is the published artifact a consumer reads
/// and the gate compares against, so it is deterministic: every list is emitted
/// in declaration order and nothing is formatted from a hash-map iteration.
pub fn render(allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    try w.print(
        \\{{
        \\  "contract_version": {d},
        \\  "envelope_version": {d},
        \\  "alphabets": {{
        \\
    , .{ contract_version, envelope_version });

    const typed = typedAlphabets();
    for (typed, 0..) |a, i| {
        try w.writeAll("    ");
        try writeJsonString(w, a.key);
        try w.writeAll(": { \"source\": ");
        try writeJsonString(w, a.source);
        try w.writeAll(", \"members\": ");
        try writeMembers(w, a.members);
        try w.writeAll(" }");
        if (i + 1 != typed.len) try w.writeByte(',');
        try w.writeByte('\n');
    }

    // Both the in-tree base and the effective set, per P1. A consumer pins one
    // of them and has to be able to tell which.
    const base = try virtualModules(allocator, .base);
    defer allocator.free(base);
    const effective = try virtualModules(allocator, .effective);
    defer allocator.free(effective);
    try w.writeAll(",\n    \"virtual_modules_base\": { \"source\": \"packages/zts/src/builtin_modules.zig\", \"members\": ");
    try writeMembers(w, base);
    try w.writeAll(" },\n    \"virtual_modules_effective\": { \"source\": \"packages/zts/src/builtin_modules.zig\", \"members\": ");
    try writeMembers(w, effective);
    try w.writeAll(" }");

    const enabled = try enabledResidualFamilies(allocator);
    defer allocator.free(enabled);
    try w.writeAll(",\n    \"residual_guard_families_enabled\": { \"source\": \"packages/proof-checker/src/residual.zig\", \"members\": ");
    try writeMembers(w, enabled);
    try w.writeAll(" }");

    // Read from source rather than imported, and cross-checked against the tag
    // enum. `goalDriveableProperties` refuses a disagreement, so a render that
    // succeeds has already established the two surfaces agree.
    const goals_src = try zts.file_io.readFile(allocator, goals_source_path, 1 << 20);
    defer allocator.free(goals_src);
    const tags_src = try zts.file_io.readFile(allocator, tags_source_path, 1 << 20);
    defer allocator.free(tags_src);
    const goals = try goalDriveableProperties(allocator, goals_src, tags_src);
    defer allocator.free(goals);
    try w.writeAll(",\n    \"goal_driveable_properties\": { \"source\": \"packages/pi/src/property_goals.zig\", \"members\": ");
    try writeMembers(w, goals);
    try w.writeAll(" }\n  },\n");

    try w.writeAll("  \"profiles\": [\n");
    for (profiles, 0..) |p, i| {
        try w.writeAll("    { \"name\": ");
        try writeJsonString(w, p.name);
        try w.writeAll(", \"categories\": [");
        for (p.categories, 0..) |c, j| {
            try writeJsonString(w, @tagName(c));
            if (j + 1 != p.categories.len) try w.writeAll(", ");
        }
        try w.writeAll("], \"excluded_modules\": [");
        for (p.excluded_modules, 0..) |m, j| {
            try writeJsonString(w, m);
            if (j + 1 != p.excluded_modules.len) try w.writeAll(", ");
        }
        try w.print("], \"requires_read_only\": {} }}", .{p.requires_read_only});
        if (i + 1 != profiles.len) try w.writeByte(',');
        try w.writeByte('\n');
    }
    try w.writeAll("  ],\n");

    const id = identities();
    try w.print(
        \\  "identities": {{
        \\    "certificate_schema": {d},
        \\    "proof_system": {d},
        \\    "semantics_epoch": {d},
        \\    "handler_contract_version": {d},
        \\    "agent_protocol_schema": {d},
        \\
    , .{
        id.certificate_schema,
        id.proof_system,
        id.semantics_epoch,
        id.handler_contract_version,
        id.agent_protocol_schema,
    });
    try w.writeAll("    \"policy_hash\": ");
    try writeJsonString(w, &id.policy_hash);
    try w.writeAll(",\n    \"module_registry_hash\": ");
    try writeJsonString(w, &id.module_registry_hash);
    try w.writeAll("\n  }\n}\n");
}

pub fn renderToOwned(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var adapter = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    defer buf = adapter.toArrayList();
    try render(allocator, &adapter.writer);
    buf = adapter.toArrayList();
    return buf.toOwnedSlice(allocator);
}

test "rendering is deterministic and carries every block" {
    const a = try renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);

    for ([_][]const u8{
        "\"contract_version\"",
        "\"capability_categories\"",
        "\"reason_codes\"",
        "\"virtual_modules_base\"",
        "\"virtual_modules_effective\"",
        "\"residual_guard_families_enabled\"",
        "\"binding_digest\"",
        "\"profiles\"",
        "\"identities\"",
        "\"module_registry_hash\"",
    }) |needle| {
        if (std.mem.indexOf(u8, a, needle) == null) {
            std.debug.print("rendered envelope is missing {s}\n", .{needle});
            return error.MissingBlock;
        }
    }
}

test "the rendered envelope parses as JSON" {
    const text = try renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

// ============================================================================
// Goal-driveable properties
// ============================================================================
//
// `packages/pi` is not importable from `tools`, and `counterexample` sits in the
// internal tier of `zts/src/root.zig` with no `tools` row in
// `scripts/module-boundary.allow`. So this alphabet is read as text rather than
// imported as a value, which `invariant_drift_gate.zig` establishes as the
// treatment for a surface that is code.
//
// Two files are scanned, not one. `pi` owns the driveable set and `zts` owns the
// tag enum the solver models, and the pi source states that the set is "the full
// set rather than a subset chosen for convenience". Requiring the two to agree
// turns that comment into a check: a tag added to the enum and not to the goal
// list, or a goal naming a tag the enum lost, fails here. Scanning one file
// alone would trust whichever it read.

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub const ScanError = error{
    AnchorMissing,
    Unterminated,
    EmptyList,
    GoalsDisagreeWithTags,
};

/// Parse a Zig list of enum literals (`.a,` `.b,`) between an anchor and the
/// closing `};`. Returns names without the leading dot, in source order.
pub fn scanTagList(
    allocator: std.mem.Allocator,
    text: []const u8,
    anchor: []const u8,
) ![]const []const u8 {
    const at = std.mem.indexOf(u8, text, anchor) orelse return ScanError.AnchorMissing;
    const body_start = at + anchor.len;
    const end_rel = std.mem.indexOf(u8, text[body_start..], "};") orelse return ScanError.Unterminated;
    const body = text[body_start .. body_start + end_rel];

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        // Two shapes reach here. A list entry is `.name,` and an enum member is
        // `name,` or `name = 3,`. Everything else in an enum body - methods,
        // their statements, closing braces - is skipped by the identifier check
        // below rather than by a pattern guessing at each one.
        const after_dot = if (line[0] == '.') line[1..] else line;
        const comma = std.mem.indexOfScalar(u8, after_dot, ',') orelse continue;
        const name = std.mem.trim(u8, after_dot[0..comma], " \t");
        const eq = std.mem.indexOfScalar(u8, name, '=');
        const ident = std.mem.trim(u8, if (eq) |e| name[0..e] else name, " \t");
        if (!isIdentifier(ident)) continue;
        try out.append(allocator, ident);
    }
    if (out.items.len == 0) return ScanError.EmptyList;
    return out.toOwnedSlice(allocator);
}

/// The driveable goal set, cross-checked against the tag enum the solver models.
/// `goals_src` is `packages/pi/src/property_goals.zig` and `tags_src` is
/// `packages/zts/src/counterexample.zig`.
pub fn goalDriveableProperties(
    allocator: std.mem.Allocator,
    goals_src: []const u8,
    tags_src: []const u8,
) ![]const Member {
    const goals = try scanTagList(allocator, goals_src, "pub const supported_goals = [_]counterexample.PropertyTag{");
    defer allocator.free(goals);
    const tags = try scanTagList(allocator, tags_src, "pub const PropertyTag = enum {");
    defer allocator.free(tags);

    // Set equality in both directions. A goal the enum does not carry is a stale
    // name; a tag no goal carries contradicts the pi source's own claim that the
    // list is the full set.
    if (goals.len != tags.len) return ScanError.GoalsDisagreeWithTags;
    for (goals) |g| {
        var found = false;
        for (tags) |t| {
            if (std.mem.eql(u8, g, t)) found = true;
        }
        if (!found) return ScanError.GoalsDisagreeWithTags;
    }
    for (tags) |t| {
        var found = false;
        for (goals) |g| {
            if (std.mem.eql(u8, g, t)) found = true;
        }
        if (!found) return ScanError.GoalsDisagreeWithTags;
    }

    const out = try allocator.alloc(Member, goals.len);
    errdefer allocator.free(out);
    for (goals, 0..) |g, i| out[i] = .{ .name = g };
    return out;
}

test "scanTagList reads a list and refuses a missing anchor" {
    const src =
        \\pub const supported_goals = [_]counterexample.PropertyTag{
        \\    .alpha,
        \\    // a comment line
        \\    .beta,
        \\};
    ;
    const got = try scanTagList(std.testing.allocator, src, "pub const supported_goals = [_]counterexample.PropertyTag{");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("alpha", got[0]);
    try std.testing.expectEqualStrings("beta", got[1]);

    try std.testing.expectError(
        ScanError.AnchorMissing,
        scanTagList(std.testing.allocator, src, "pub const absent = [_]T{"),
    );
}

test "scanTagList refuses an empty list rather than reporting success" {
    const src =
        \\pub const supported_goals = [_]counterexample.PropertyTag{
        \\};
    ;
    try std.testing.expectError(
        ScanError.EmptyList,
        scanTagList(std.testing.allocator, src, "pub const supported_goals = [_]counterexample.PropertyTag{"),
    );
}

test "a goal the tag enum does not carry is refused" {
    const goals =
        \\pub const supported_goals = [_]counterexample.PropertyTag{
        \\    .alpha,
        \\    .ghost,
        \\};
    ;
    const tags =
        \\pub const PropertyTag = enum {
        \\    alpha,
        \\    beta,
        \\};
    ;
    try std.testing.expectError(
        ScanError.GoalsDisagreeWithTags,
        goalDriveableProperties(std.testing.allocator, goals, tags),
    );
}

test "a tag no goal carries is refused" {
    const goals =
        \\pub const supported_goals = [_]counterexample.PropertyTag{
        \\    .alpha,
        \\};
    ;
    const tags =
        \\pub const PropertyTag = enum {
        \\    alpha,
        \\    beta,
        \\};
    ;
    try std.testing.expectError(
        ScanError.GoalsDisagreeWithTags,
        goalDriveableProperties(std.testing.allocator, goals, tags),
    );
}

pub const goals_source_path = "packages/pi/src/property_goals.zig";
pub const tags_source_path = "packages/zts/src/counterexample.zig";

test "the real pi goal list and zts tag enum agree" {
    // The cross-check against the actual tree, not a literal. If pi adds a goal
    // the solver does not model, or the enum grows a tag no goal drives, this
    // is where it surfaces.
    const file_io = zts.file_io;
    const goals_src = try file_io.readFile(std.testing.allocator, goals_source_path, 1 << 20);
    defer std.testing.allocator.free(goals_src);
    const tags_src = try file_io.readFile(std.testing.allocator, tags_source_path, 1 << 20);
    defer std.testing.allocator.free(tags_src);

    const members = try goalDriveableProperties(std.testing.allocator, goals_src, tags_src);
    defer std.testing.allocator.free(members);

    try std.testing.expectEqual(@as(usize, 5), members.len);
    for ([_][]const u8{
        "no_secret_leakage",
        "no_credential_leakage",
        "injection_safe",
        "input_validated",
        "pii_contained",
    }) |want| {
        var found = false;
        for (members) |m| {
            if (std.mem.eql(u8, m.name, want)) found = true;
        }
        if (!found) {
            std.debug.print("goal-driveable set is missing {s}\n", .{want});
            return error.MissingGoal;
        }
    }
}

test "every alphabet is a direct child of the alphabets object" {
    // A JSON-validity test is not enough. A block written inside the previous
    // block's object is still valid JSON, and the goal-driveable block shipped
    // that way once: nested under `residual_guard_families_enabled` rather than
    // beside it, accepted by `jq` and wrong. This asserts placement, which is
    // the property a consumer actually reads.
    const text = try renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const alphabets = (root.get("alphabets") orelse return error.NoAlphabetsObject).object;

    // Every typed alphabet, plus the four derived blocks, must be a direct key.
    for (typedAlphabets()) |a| {
        if (alphabets.get(a.key) == null) {
            std.debug.print("alphabet {s} is not a direct child of alphabets\n", .{a.key});
            return error.AlphabetMisplaced;
        }
    }
    for ([_][]const u8{
        "virtual_modules_base",
        "virtual_modules_effective",
        "residual_guard_families_enabled",
        "goal_driveable_properties",
    }) |key| {
        const block = alphabets.get(key) orelse {
            std.debug.print("block {s} is not a direct child of alphabets\n", .{key});
            return error.AlphabetMisplaced;
        };
        // Each block is an object carrying `source` and a non-empty `members`.
        const obj = block.object;
        _ = obj.get("source") orelse return error.BlockMissingSource;
        const members = (obj.get("members") orelse return error.BlockMissingMembers).array;
        if (members.items.len == 0) return error.BlockHasNoMembers;
        // And carries no nested alphabet block, which is how the bug looked.
        var it = obj.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!std.mem.eql(u8, k, "source") and !std.mem.eql(u8, k, "members")) {
                std.debug.print("block {s} carries an unexpected key {s}\n", .{ key, k });
                return error.BlockHasNestedKey;
            }
        }
    }
}
