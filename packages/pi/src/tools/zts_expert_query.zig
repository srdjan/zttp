//! One strict model-facing query over compiler-owned read-only facts.
//!
//! The individual implementation modules remain useful focused units and test
//! seams. This module is the only registered authority for their discovery
//! operations, so the provider catalog carries one closed ADT rather than ten
//! overlapping tool schemas.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");

const meta_tool = @import("zts_expert_meta.zig");
const features_tool = @import("zts_expert_features.zig");
const restrictions_tool = @import("zts_expert_restrictions.zig");
const describe_rule_tool = @import("zts_expert_describe_rule.zig");
const search_tool = @import("zts_expert_search.zig");
const modules_tool = @import("zts_expert_modules.zig");
const effects_tool = @import("zts_expert_effects.zig");
const holes_tool = @import("zts_expert_holes.zig");
const narrow_tool = @import("zts_expert_narrow.zig");
const ratchet_tool = @import("zts_expert_ratchet.zig");

const name = "zts_expert_query";

pub const Operation = enum {
    meta,
    features,
    restrictions,
    describe_rule,
    search_rules,
    modules,
    effects,
    holes,
    narrow,
    ratchet,
};

/// The schema closes the vocabulary provider-side. `decodeJson` applies the
/// stronger per-variant law: only the field belonging to the selected tag may
/// appear. This avoids a giant `oneOf` while preserving an actual ADT at the
/// host boundary.
pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "compiler query",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description = "Query compiler-owned facts through one closed operation. " ++
        "Use meta(view), describe_rule(rule), search_rules(query), " ++
        "modules(file), or effects/holes/narrow/ratchet(path); " ++
        "features and restrictions take no second field.",
    .input_schema = "{\"type\":\"object\",\"additionalProperties\":false," ++
        "\"properties\":{" ++
        "\"operation\":{\"type\":\"string\",\"enum\":[" ++
        "\"meta\",\"features\",\"restrictions\",\"describe_rule\"," ++
        "\"search_rules\",\"modules\",\"effects\",\"holes\",\"narrow\",\"ratchet\"]}," ++
        "\"view\":{\"type\":\"string\",\"enum\":[\"bootstrap\",\"full\"]}," ++
        "\"rule\":{\"type\":\"string\"}," ++
        "\"query\":{\"type\":\"string\"}," ++
        "\"file\":{\"type\":\"string\"}," ++
        "\"path\":{\"type\":\"string\"}" ++
        "},\"required\":[\"operation\"]}",
    .decode_json = decodeJson,
    .execute = execute,
};

fn decodeJson(allocator: std.mem.Allocator, args_json: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolArgsJson;
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        trimmed,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch return error.InvalidToolArgsJson;
    if (value != .object) return error.InvalidToolArgsJson;

    const operation_value = value.object.get("operation") orelse return error.InvalidToolArgsJson;
    if (operation_value != .string) return error.InvalidToolArgsJson;
    const operation = std.meta.stringToEnum(Operation, operation_value.string) orelse
        return error.InvalidToolArgsJson;

    return switch (operation) {
        .meta => decodeOptionalField(allocator, value.object, operation, "view", validateView),
        .features, .restrictions => decodeNoField(allocator, value.object, operation),
        .describe_rule => decodeOptionalField(allocator, value.object, operation, "rule", validateAnyString),
        .search_rules => decodeRequiredField(allocator, value.object, operation, "query"),
        .modules => decodeRequiredField(allocator, value.object, operation, "file"),
        .effects, .holes, .narrow, .ratchet => decodeRequiredField(allocator, value.object, operation, "path"),
    };
}

const StringValidator = *const fn ([]const u8) bool;

fn decodeNoField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    operation: Operation,
) ![]const []const u8 {
    if (object.count() != 1) return error.InvalidToolArgsJson;
    return operationArgs(allocator, operation, null);
}

fn decodeOptionalField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    operation: Operation,
    field: []const u8,
    validate: StringValidator,
) ![]const []const u8 {
    if (object.count() == 1) return operationArgs(allocator, operation, null);
    if (object.count() != 2) return error.InvalidToolArgsJson;
    const value = object.get(field) orelse return error.InvalidToolArgsJson;
    if (value != .string or !validate(value.string)) return error.InvalidToolArgsJson;
    return operationArgs(allocator, operation, value.string);
}

fn decodeRequiredField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    operation: Operation,
    field: []const u8,
) ![]const []const u8 {
    if (object.count() != 2) return error.InvalidToolArgsJson;
    const value = object.get(field) orelse return error.InvalidToolArgsJson;
    if (value != .string or value.string.len == 0) return error.InvalidToolArgsJson;
    return operationArgs(allocator, operation, value.string);
}

fn operationArgs(
    allocator: std.mem.Allocator,
    operation: Operation,
    value: ?[]const u8,
) ![]const []const u8 {
    const args = try allocator.alloc([]const u8, if (value == null) 1 else 2);
    args[0] = @tagName(operation);
    if (value) |present| args[1] = present;
    return args;
}

fn validateView(value: []const u8) bool {
    return std.mem.eql(u8, value, "bootstrap") or std.mem.eql(u8, value, "full");
}

fn validateAnyString(_: []const u8) bool {
    return true;
}

fn execute(allocator: std.mem.Allocator, args: []const []const u8) anyerror!registry_mod.ToolResult {
    if (args.len == 0 or args.len > 2) {
        return registry_mod.ToolResult.err(allocator, name ++ ": requires one operation and at most one value\n");
    }
    const normalized = normalizeTrustedOperation(args[0]);
    const operation = std.meta.stringToEnum(Operation, normalized) orelse
        return registry_mod.ToolResult.errFmt(allocator, name ++ ": unknown operation {s}\n", .{args[0]});
    const tail = args[1..];
    return switch (operation) {
        .meta => meta_tool.tool.execute(allocator, tail),
        .features => features_tool.tool.execute(allocator, tail),
        .restrictions => restrictions_tool.tool.execute(allocator, tail),
        .describe_rule => describe_rule_tool.tool.execute(allocator, tail),
        .search_rules => search_tool.tool.execute(allocator, tail),
        .modules => modules_tool.tool.execute(allocator, tail),
        .effects => effects_tool.tool.execute(allocator, tail),
        .holes => holes_tool.tool.execute(allocator, tail),
        .narrow => narrow_tool.tool.execute(allocator, tail),
        .ratchet => ratchet_tool.tool.execute(allocator, tail),
    };
}

fn normalizeTrustedOperation(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "/meta")) return "meta";
    if (std.mem.eql(u8, value, "/features")) return "features";
    if (std.mem.eql(u8, value, "/restrictions")) return "restrictions";
    if (std.mem.eql(u8, value, "/rule")) return "describe_rule";
    if (std.mem.eql(u8, value, "describe-rule")) return "describe_rule";
    if (std.mem.eql(u8, value, "/search")) return "search_rules";
    if (std.mem.eql(u8, value, "search")) return "search_rules";
    if (std.mem.eql(u8, value, "/modules")) return "modules";
    return value;
}

const testing = std.testing;

test "query decoder rejects unknown duplicate extra and operation-irrelevant fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidToolArgsJson, decodeJson(a, "{}"));
    try testing.expectError(error.InvalidToolArgsJson, decodeJson(a, "{\"operation\":\"unknown\"}"));
    try testing.expectError(
        error.InvalidToolArgsJson,
        decodeJson(a, "{\"operation\":\"features\",\"operation\":\"restrictions\"}"),
    );
    try testing.expectError(
        error.InvalidToolArgsJson,
        decodeJson(a, "{\"operation\":\"features\",\"extra\":true}"),
    );
    try testing.expectError(
        error.InvalidToolArgsJson,
        decodeJson(a, "{\"operation\":\"features\",\"path\":\"handler.ts\"}"),
    );
    try testing.expectError(
        error.InvalidToolArgsJson,
        decodeJson(a, "{\"operation\":\"modules\",\"path\":\"handler.ts\"}"),
    );
    try testing.expectError(
        error.InvalidToolArgsJson,
        decodeJson(a, "{\"operation\":\"meta\",\"view\":\"brief\"}"),
    );
}

test "query decoder produces one exhaustive argv shape per operation" {
    const Case = struct { json: []const u8, expected: []const []const u8 };
    const cases = [_]Case{
        .{ .json = "{\"operation\":\"meta\"}", .expected = &.{"meta"} },
        .{ .json = "{\"operation\":\"meta\",\"view\":\"bootstrap\"}", .expected = &.{ "meta", "bootstrap" } },
        .{ .json = "{\"operation\":\"features\"}", .expected = &.{"features"} },
        .{ .json = "{\"operation\":\"restrictions\"}", .expected = &.{"restrictions"} },
        .{ .json = "{\"operation\":\"describe_rule\"}", .expected = &.{"describe_rule"} },
        .{ .json = "{\"operation\":\"describe_rule\",\"rule\":\"ZTS303\"}", .expected = &.{ "describe_rule", "ZTS303" } },
        .{ .json = "{\"operation\":\"search_rules\",\"query\":\"result\"}", .expected = &.{ "search_rules", "result" } },
        .{ .json = "{\"operation\":\"modules\",\"file\":\"handler.ts\"}", .expected = &.{ "modules", "handler.ts" } },
        .{ .json = "{\"operation\":\"effects\",\"path\":\"handler.ts\"}", .expected = &.{ "effects", "handler.ts" } },
        .{ .json = "{\"operation\":\"holes\",\"path\":\"handler.ts\"}", .expected = &.{ "holes", "handler.ts" } },
        .{ .json = "{\"operation\":\"narrow\",\"path\":\"handler.ts\"}", .expected = &.{ "narrow", "handler.ts" } },
        .{ .json = "{\"operation\":\"ratchet\",\"path\":\"handler.ts\"}", .expected = &.{ "ratchet", "handler.ts" } },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const actual = try decodeJson(arena.allocator(), case.json);
        try testing.expectEqual(case.expected.len, actual.len);
        for (case.expected, actual) |expected, value| try testing.expectEqualStrings(expected, value);
    }
}

test "query dispatch preserves schema-v2 envelopes" {
    var registry: registry_mod.Registry = .{};
    defer registry.deinit(testing.allocator);
    try registry.register(testing.allocator, tool);

    var features = try registry.invokeJson(testing.allocator, name, "{\"operation\":\"features\"}");
    defer features.deinit(testing.allocator);
    try testing.expect(features.ok);
    try testing.expect(std.mem.indexOf(u8, features.llm_text, "\"operation\":\"features\"") != null);

    var rule = try registry.invokeJson(
        testing.allocator,
        name,
        "{\"operation\":\"describe_rule\",\"rule\":\"ZTS303\"}",
    );
    defer rule.deinit(testing.allocator);
    try testing.expect(rule.ok);
    try testing.expect(std.mem.indexOf(u8, rule.llm_text, "\"ZTS303\"") != null);
}
