//! Identity of the complete model/compiler protocol persisted by a session.
//!
//! This intentionally excludes project instructions and workspace files: they
//! may evolve during one session. It includes every stable authority the model
//! reasons against, so resuming after a persona, catalog, schema, or compiler
//! registry change fails closed instead of silently mixing two protocols.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const expert_persona = @import("../expert_persona.zig");
const registry_mod = @import("../registry/registry.zig");
const tool_catalog = @import("../providers/tool_catalog.zig");

pub fn current(
    allocator: std.mem.Allocator,
    registry: ?*const registry_mod.Registry,
) ![64]u8 {
    const persona = try expert_persona.buildSystemPrompt(allocator);
    defer allocator.free(persona);

    const catalog_hash = if (registry) |active|
        tool_catalog.providerNeutralHash(active)
    else
        tool_catalog.providerNeutralHashForDefinitions(&.{});

    const schema_hash = zts_cli.agent_protocol.schemaHash();
    const policy_hash = zts.policyHash();
    const grammar_hash = zts.grammarHash();
    const tsx_grammar_hash = zts.tsxFrontendGrammarHash();
    const semantics_hash = zts.semanticsHash();
    const diagnostic_hash = zts.diagnosticCatalogHash();
    const idiom_hash = zts.idiomTableHash();
    const restriction_hash = zts.restrictionMatrixHash();
    const builtin_hash = zts.ModuleMetadata.builtinRegistryHash();
    const example_hash = zts_cli.agent_protocol.exampleRegistryHash();

    var hasher = ProtocolHasher.init();
    hasher.field("persona", persona);
    hasher.field("compiler-version", zts.version.string);
    hasher.field("agent-schema", &schema_hash);
    hasher.field("policy", &policy_hash);
    hasher.field("grammar", &grammar_hash);
    hasher.field("tsx-grammar", &tsx_grammar_hash);
    hasher.field("semantics", &semantics_hash);
    hasher.field("diagnostics", &diagnostic_hash);
    hasher.field("idioms", &idiom_hash);
    hasher.field("restrictions", &restriction_hash);
    hasher.field("builtins", &builtin_hash);
    hasher.field("examples", &example_hash);
    hasher.field("provider-neutral-catalog", &catalog_hash);
    return hasher.finish();
}

const ProtocolHasher = struct {
    state: std.crypto.hash.sha2.Sha256,

    fn init() ProtocolHasher {
        var out: ProtocolHasher = .{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        out.field("domain", "zttp-expert-session-protocol-v1");
        return out;
    }

    fn frame(self: *ProtocolHasher, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(value.len), .big);
        self.state.update(&length);
        self.state.update(value);
    }

    fn field(self: *ProtocolHasher, label: []const u8, value: []const u8) void {
        self.frame(label);
        self.frame(value);
    }

    fn finish(self: *ProtocolHasher) [64]u8 {
        return std.fmt.bytesToHex(self.state.finalResult(), .lower);
    }
};

const testing = std.testing;

test "protocol identity is deterministic and binds the live catalog" {
    var empty: registry_mod.Registry = .{};
    defer empty.deinit(testing.allocator);
    const baseline = try current(testing.allocator, &empty);
    const repeated = try current(testing.allocator, &empty);
    try testing.expectEqualStrings(&baseline, &repeated);

    var expanded: registry_mod.Registry = .{};
    defer expanded.deinit(testing.allocator);
    try expanded.register(testing.allocator, .{
        .name = "read",
        .label = "read",
        .effect = .analyze,
        .context_policy = .exact,
        .description = "read compiler data",
        .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        .decode_json = testDecode,
        .execute = testExecute,
    });
    const changed = try current(testing.allocator, &expanded);
    try testing.expect(!std.mem.eql(u8, &baseline, &changed));
}

fn testDecode(allocator: std.mem.Allocator, _: []const u8) ![]const []const u8 {
    return allocator.alloc([]const u8, 0);
}

fn testExecute(
    allocator: std.mem.Allocator,
    _: []const []const u8,
) anyerror!registry_mod.ToolResult {
    return .{ .ok = true, .llm_text = try allocator.dupe(u8, "ok") };
}
