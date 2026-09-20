//! Single source of truth for the `zts meta` v1 envelope.
//! See docs/zts-expert-contract.md.

const std = @import("std");
const zts = @import("zts");
const policy_catalog = zts.PolicyCatalog;
const moduleMetadata = zts.ModuleMetadata;

/// Identity of the analyzer surface a recording was made against, emitted as
/// the envelope's `compiler_version`.
///
/// Deliberately **not** `zts.version.string`. This value reaches the recorded
/// model transcript through the `zts_expert_query` meta tool result, so it is
/// covered by the cassette digests: changing it stales every cassette at once.
/// While it tracked the release version, shipping a release invalidated the
/// whole corpus and forced a re-record that measured nothing new about the
/// compiler - it only re-rolled the draw and moved the published convergence
/// number. `docs/internals/cassette-recording.md` records that going from
/// 0.18.0 to 0.19.0 staled 16 of 19 cases for exactly this reason.
///
/// Nothing is lost by decoupling, because the analyzer's observable surface is
/// already covered by content: the same manifest carries `metaHash`,
/// `grammarHash`, `semanticsHash`, `diagnosticHash`, `policyHash`,
/// `schemaHash` and `module_registry_hash`, each derived from the thing it
/// names. This string was the one hand-maintained identity among them, so it
/// contributed false staleness rather than detection.
///
/// Move it when the analyzer's observable surface moves in a way the hashes
/// above cannot express, and treat that move as owing a full re-record. Do not
/// move it to match a release.
pub const analyzer_surface_version = "0.19.0";

pub const compiler_version = analyzer_surface_version;
pub const policy_version = "2026.04.2";
pub const mode = "embedded";

pub const Categories = struct {
    verifier: usize,
    policy: usize,
    property: usize,
};

pub const MetaInfo = struct {
    compiler_version: []const u8,
    policy_version: []const u8,
    policy_hash: [64]u8,
    module_registry_hash: [64]u8,
    rule_count: usize,
    categories: Categories,
    mode: []const u8,
};

pub const category_counts: Categories = blk: {
    var v: usize = 0;
    var p: usize = 0;
    var pr: usize = 0;
    for (policy_catalog.rules()) |rule| {
        switch (rule.category) {
            .verifier => v += 1,
            .policy => p += 1,
            // The v1 `zts meta` envelope closes `categories` on three keys
            // (see docs/internals/zts-expert-contract.md line 102: "new
            // categories would be a v2 change"). FlowChecker rules carry the
            // `.flow` registry tag but project into the `property` bucket so
            // the v1 invariant `rule_count == verifier + policy + property`
            // holds. Surface `flow` as a distinct key only as part of a v2
            // contract bump, alongside the tripwire tests in expert.zig.
            //
            // The registry's own `.property` category is gone with PROP01-06,
            // which renamed findings that already carried codes. The `property`
            // key stays because the v1 envelope does, and is now flow-only.
            .flow => pr += 1,
        }
    }
    break :blk .{ .verifier = v, .policy = p, .property = pr };
};

pub fn compute() MetaInfo {
    return .{
        .compiler_version = compiler_version,
        .policy_version = policy_version,
        .policy_hash = zts.policyHash(),
        .module_registry_hash = moduleMetadata.builtinRegistryHash(),
        .rule_count = policy_catalog.rules().len,
        .categories = category_counts,
        .mode = mode,
    };
}

pub fn writeJson(writer: anytype, info: *const MetaInfo) !void {
    try writer.print(
        "{{\"compiler_version\":\"{s}\",\"policy_version\":\"{s}\",\"policy_hash\":\"{s}\",\"module_registry_hash\":\"{s}\",\"rule_count\":{d},\"categories\":{{\"verifier\":{d},\"policy\":{d},\"property\":{d}}},\"mode\":\"{s}\"}}\n",
        .{
            info.compiler_version,
            info.policy_version,
            info.policy_hash,
            info.module_registry_hash,
            info.rule_count,
            info.categories.verifier,
            info.categories.policy,
            info.categories.property,
            info.mode,
        },
    );
}

pub fn writeText(writer: anytype, info: *const MetaInfo) !void {
    try writer.print(
        \\zts policy
        \\  compiler: {s}
        \\  policy:   {s}
        \\  hash:     {s}
        \\  modules:  {s}
        \\  rules:    {d} ({d} verifier, {d} policy, {d} property)
        \\  mode:     {s}
        \\
    , .{
        info.compiler_version,
        info.policy_version,
        info.policy_hash,
        info.module_registry_hash,
        info.rule_count,
        info.categories.verifier,
        info.categories.policy,
        info.categories.property,
        info.mode,
    });
}

test "compute fills all fields" {
    const info = compute();
    try std.testing.expectEqualStrings(analyzer_surface_version, info.compiler_version);
    try std.testing.expectEqualStrings("2026.04.2", info.policy_version);
    try std.testing.expectEqualStrings("embedded", info.mode);
    try std.testing.expectEqual(@as(usize, 64), info.module_registry_hash.len);
    try std.testing.expect(info.rule_count > 0);
    try std.testing.expectEqual(info.rule_count, info.categories.verifier + info.categories.policy + info.categories.property);
}

test "writeJson produces parseable v1 envelope" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

    const info = compute();
    try writeJson(&aw.writer, &info);

    buf = aw.toArrayList();
    const s = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, s, "\"compiler_version\":\"" ++ analyzer_surface_version ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"policy_version\":\"2026.04.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"module_registry_hash\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"mode\":\"embedded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"categories\":{") != null);
    try std.testing.expectEqual(@as(u8, '\n'), s[s.len - 1]);
}

test "writeText emits the human-readable report with pinned versions" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

    const info = compute();
    try writeText(&aw.writer, &info);

    buf = aw.toArrayList();
    const s = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, s, "zts policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "compiler: " ++ analyzer_surface_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "policy:   2026.04.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "modules:  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mode:     embedded") != null);
}
