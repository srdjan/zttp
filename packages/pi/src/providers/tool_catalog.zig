//! Provider-neutral model tool catalog.
//!
//! Providers own their wire serialization. This module owns the ordered
//! `{name, description, input_schema}` inventory that every provider sees.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
const registry_mod = @import("../registry/registry.zig");

pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    /// Proof inputs the host writes into the raw transcript for this tool. They
    /// are never valid model-authored input and must not appear in the
    /// provider-visible projection.
    host_authoritative_keys: []const []const u8 = &.{},
};

pub const propose_change_set: Definition = .{
    .name = "propose_change_set",
    .description = "Propose one ordered source change set. The zttp compiler proves the " ++
        "aggregate result before one approval and one crash-safe commit; if new " ++
        "violations appear, you will be re-prompted with the diagnostic.",
    .input_schema = "{\"type\":\"object\"," ++
        "\"additionalProperties\":false," ++
        "\"properties\":{" ++
        "\"changes\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":32," ++
        "\"description\":\"Ordered complete source-file replacements.\"," ++
        "\"items\":{\"type\":\"object\",\"additionalProperties\":false," ++
        "\"properties\":{" ++
        "\"file\":{\"type\":\"string\",\"description\":\"Workspace-relative .ts or .tsx path.\"}," ++
        "\"content\":{\"type\":\"string\",\"description\":\"Full source bytes after the change.\"}" ++
        "},\"required\":[\"file\",\"content\"]}}" ++
        "}," ++
        "\"required\":[\"changes\"]}",
    .host_authoritative_keys = &.{ "before", "baseline_state", "baseline_sha256" },
};

/// Return owned model-visible arguments when a raw tool call needs projection.
/// Null means the raw arguments are already safe to borrow unchanged.
pub fn projectArgsForModel(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    raw_args_json: []const u8,
) !?[]u8 {
    if (!std.mem.eql(u8, tool_name, propose_change_set.name)) return null;
    // Only the host writes these keys, and it writes them into well-formed
    // JSON. Args without them carry nothing to hide, so they are borrowed
    // verbatim rather than re-encoded on every request.
    if (!mayCarryHostKeys(propose_change_set.host_authoritative_keys, raw_args_json)) return null;

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    var parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        parse_arena.allocator(),
        raw_args_json,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Args that do not parse are model-authored: `loop` records a raw tool
        // batch before rejecting it, and the host only ever writes valid JSON.
        // Refusing here would fail every later request in the session over one
        // off-spec call, so the raw bytes pass through unchanged instead.
        else => return null,
    };
    if (parsed != .object) return null;

    const changes_value = parsed.object.getPtr("changes") orelse return null;
    if (changes_value.* != .array) return null;
    var removed = false;
    for (changes_value.array.items) |*change| {
        if (change.* != .object) continue;
        for (propose_change_set.host_authoritative_keys) |key| {
            if (change.object.orderedRemove(key)) removed = true;
        }
    }
    if (!removed) return null;

    var out = TextBuffer.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed, .{}, out.writer());
    return try out.toOwnedSlice();
}

fn mayCarryHostKeys(keys: []const []const u8, raw_args_json: []const u8) bool {
    for (keys) |key| {
        if (std.mem.indexOf(u8, raw_args_json, key) != null) return true;
    }
    return false;
}

pub const Iterator = struct {
    registry: *const registry_mod.Registry,
    emitted_change_set: bool = false,
    registry_index: usize = 0,

    pub fn next(self: *Iterator) ?Definition {
        if (!self.emitted_change_set) {
            self.emitted_change_set = true;
            return propose_change_set;
        }
        const entries = self.registry.list();
        while (self.registry_index < entries.len) {
            const entry = entries[self.registry_index];
            self.registry_index += 1;
            if (!entry.allowedOn(.model)) continue;
            return .{
                .name = entry.name,
                .description = entry.description,
                .input_schema = entry.input_schema,
            };
        }
        return null;
    }
};

pub fn iterator(registry: *const registry_mod.Registry) Iterator {
    return .{ .registry = registry };
}

pub fn count(registry: *const registry_mod.Registry) usize {
    var total: usize = 1;
    for (registry.list()) |entry| {
        if (entry.allowedOn(.model)) total += 1;
    }
    return total;
}

/// Stable identity of the exact ordered provider-neutral catalog. Provider
/// serializers may wrap these definitions differently, but every model sees
/// the same name, description, and schema bytes in this order.
pub fn providerNeutralHash(registry: *const registry_mod.Registry) [64]u8 {
    var hasher = CatalogHasher.init();
    hasher.u64Field("definition-count", count(registry));
    var definitions = iterator(registry);
    var index: usize = 0;
    while (definitions.next()) |definition| : (index += 1) {
        hasher.definition(index, definition);
    }
    std.debug.assert(index == count(registry));
    return hasher.finish();
}

/// Hash an explicit definition slice with the same identity used by the live
/// catalog. This keeps evaluation manifests and sessions on one authority.
pub fn providerNeutralHashForDefinitions(definitions: []const Definition) [64]u8 {
    var hasher = CatalogHasher.init();
    hasher.u64Field("definition-count", definitions.len);
    for (definitions, 0..) |definition, index| hasher.definition(index, definition);
    return hasher.finish();
}

const CatalogHasher = struct {
    state: std.crypto.hash.sha2.Sha256,

    fn init() CatalogHasher {
        var out: CatalogHasher = .{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        out.field("domain", "zttp-expert-provider-neutral-catalog-v1");
        return out;
    }

    fn frame(self: *CatalogHasher, value: []const u8) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(value.len), .big);
        self.state.update(&length);
        self.state.update(value);
    }

    fn field(self: *CatalogHasher, label: []const u8, value: []const u8) void {
        self.frame(label);
        self.frame(value);
    }

    fn u64Field(self: *CatalogHasher, label: []const u8, value: usize) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .big);
        self.field(label, &bytes);
    }

    fn definition(self: *CatalogHasher, index: usize, value: Definition) void {
        self.u64Field("definition-index", index);
        self.field("name", value.name);
        self.field("description", value.description);
        self.field("input-schema", value.input_schema);
    }

    fn finish(self: *CatalogHasher) [64]u8 {
        return std.fmt.bytesToHex(self.state.finalResult(), .lower);
    }
};

const testing = std.testing;

test "projectArgsForModel strips host keys and never refuses model-authored args" {
    const stripped = (try projectArgsForModel(
        testing.allocator,
        "propose_change_set",
        "{\"changes\":[{\"file\":\"handler.ts\",\"content\":\"new\",\"before\":\"old\"," ++
            "\"baseline_state\":\"present\",\"baseline_sha256\":\"0123\"}]}",
    )).?;
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings(
        "{\"changes\":[{\"file\":\"handler.ts\",\"content\":\"new\"}]}",
        stripped,
    );

    // Nothing to hide: borrowed verbatim rather than parsed and re-encoded.
    try testing.expectEqual(
        @as(?[]u8, null),
        try projectArgsForModel(testing.allocator, "propose_change_set", "{\"changes\":[{\"file\":\"a.ts\",\"content\":\"x\"}]}"),
    );
    // Another tool's args are never the host's to rewrite.
    try testing.expectEqual(
        @as(?[]u8, null),
        try projectArgsForModel(testing.allocator, "workspace_read_file", "{\"before\":\"x\"}"),
    );
    // Truncated model-authored args must not fail the request that carries
    // them: the host writes these keys only into well-formed JSON.
    try testing.expectEqual(
        @as(?[]u8, null),
        try projectArgsForModel(testing.allocator, "propose_change_set", "{\"changes\":[{\"file\":\"a.ts\",\"before\":"),
    );
    try testing.expectEqual(
        @as(?[]u8, null),
        try projectArgsForModel(testing.allocator, "propose_change_set", "[\"baseline_sha256\"]"),
    );
}

test "provider-neutral identity binds ordered model-visible fields only" {
    const definitions = [_]Definition{
        .{ .name = "read", .description = "read a file", .input_schema = "{}" },
    };
    const baseline = providerNeutralHashForDefinitions(&definitions);
    try testing.expectEqualStrings(&baseline, &providerNeutralHashForDefinitions(&definitions));

    var changed = definitions;
    changed[0].name = "write";
    try testing.expect(!std.mem.eql(u8, &baseline, &providerNeutralHashForDefinitions(&changed)));
    changed = definitions;
    changed[0].description = "changed";
    try testing.expect(!std.mem.eql(u8, &baseline, &providerNeutralHashForDefinitions(&changed)));
    changed = definitions;
    changed[0].input_schema = "{\"type\":\"object\"}";
    try testing.expect(!std.mem.eql(u8, &baseline, &providerNeutralHashForDefinitions(&changed)));
    changed = definitions;
    changed[0].host_authoritative_keys = &.{"before"};
    try testing.expectEqualStrings(&baseline, &providerNeutralHashForDefinitions(&changed));
}
