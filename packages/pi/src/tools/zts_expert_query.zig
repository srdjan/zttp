//! One strict model-facing query over compiler-owned read-only facts.
//!
//! The individual implementation modules remain useful focused units and test
//! seams. This module is the only registered authority for their discovery
//! operations, so the provider catalog carries one closed ADT rather than ten
//! overlapping tool schemas.

const std = @import("std");
const registry_mod = @import("../registry/registry.zig");
const client = @import("zts_agent_client.zig");

const effects_tool = @import("zts_expert_effects.zig");
const holes_tool = @import("zts_expert_holes.zig");
const narrow_tool = @import("zts_expert_narrow.zig");

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
        "modules(file), or effects/holes/narrow(path); " ++
        "features and restrictions take no second field.",
    .input_schema = "{\"type\":\"object\",\"additionalProperties\":false," ++
        "\"properties\":{" ++
        "\"operation\":{\"type\":\"string\",\"enum\":[" ++
        "\"meta\",\"features\",\"restrictions\",\"describe_rule\"," ++
        "\"search_rules\",\"modules\",\"effects\",\"holes\",\"narrow\"]}," ++
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
        .effects, .holes, .narrow => decodeRequiredField(allocator, value.object, operation, "path"),
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
    const present = value orelse return registry_mod.helpers.singleArg(allocator, @tagName(operation));
    const args = try allocator.alloc([]const u8, 2);
    args[0] = @tagName(operation);
    args[1] = present;
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
        .meta => runProtocol(allocator, .meta, "view", if (tail.len == 1) tail[0] else null),
        .features => if (tail.len != 0)
            registry_mod.ToolResult.err(allocator, "zts_expert_features: takes no arguments\n")
        else
            runProtocol(allocator, .features, null, null),
        .restrictions => if (tail.len != 0)
            registry_mod.ToolResult.err(allocator, "zts_expert_restrictions: takes no arguments\n")
        else
            runProtocol(allocator, .restrictions, null, null),
        .describe_rule => runProtocol(
            allocator,
            .describe_rule,
            "rule",
            if (tail.len == 1) tail[0] else null,
        ),
        .search_rules => if (tail.len != 1)
            registry_mod.ToolResult.err(allocator, "zts_expert_search requires one keyword argument\n")
        else
            searchRules(allocator, tail[0]),
        .modules => if (tail.len != 1)
            registry_mod.ToolResult.err(allocator, "zts_expert_modules: requires one file\n")
        else
            runProtocol(allocator, .modules, "file", tail[0]),
        .effects => if (tail.len == 0)
            registry_mod.ToolResult.err(allocator, "zts_expert_effects: requires a path\n")
        else
            effects_tool.run(allocator, tail[0]),
        .holes => if (tail.len == 0)
            registry_mod.ToolResult.err(allocator, "zts_expert_holes: requires a path\n")
        else
            holes_tool.run(allocator, tail[0]),
        .narrow => if (tail.len == 0)
            registry_mod.ToolResult.err(allocator, "zts_expert_narrow: requires a path\n")
        else
            narrow_tool.run(allocator, tail[0]),
    };
}

fn runProtocol(
    allocator: std.mem.Allocator,
    operation: client.Operation,
    field: ?[]const u8,
    value: ?[]const u8,
) anyerror!registry_mod.ToolResult {
    const input_json = try protocolInput(allocator, field, value);
    defer allocator.free(input_json);
    const projection = try client.invokeForTool(allocator, .{
        .operation = operation,
        .input_json = input_json,
    });
    return .{ .ok = projection.ok, .llm_text = projection.llm_text };
}

fn protocolInput(
    allocator: std.mem.Allocator,
    field: ?[]const u8,
    value: ?[]const u8,
) ![]u8 {
    if (value == null) return allocator.dupe(u8, "{}");
    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.beginObject();
    try json.objectField(field.?);
    try json.write(value.?);
    try json.endObject();
    return out.toOwnedSlice();
}

fn searchRules(
    allocator: std.mem.Allocator,
    query: []const u8,
) anyerror!registry_mod.ToolResult {
    const projection = try client.invokeForTool(allocator, .{
        .operation = .describe_rule,
        .input_json = "{}",
    });
    if (!projection.ok) return .{ .ok = false, .llm_text = projection.llm_text };
    defer allocator.free(projection.llm_text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, projection.llm_text, .{}) catch
        return error.MalformedProtocolResponse;
    defer parsed.deinit();
    const payload = parsed.value.object.getPtr("payload") orelse return error.MalformedProtocolResponse;
    if (payload.* != .object) return error.MalformedProtocolResponse;
    const rules = payload.object.getPtr("rules") orelse return error.MalformedProtocolResponse;
    if (rules.* != .array) return error.MalformedProtocolResponse;

    var kept: usize = 0;
    for (rules.array.items) |rule| {
        if (!ruleMatches(rule, query)) continue;
        rules.array.items[kept] = rule;
        kept += 1;
    }
    rules.array.shrinkRetainingCapacity(kept);

    var out = registry_mod.helpers.TextBuffer.init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = out.writer() };
    try json.write(parsed.value);
    try out.writer().writeByte('\n');
    return .{ .ok = true, .llm_text = try out.toOwnedSlice() };
}

fn ruleMatches(value: std.json.Value, query: []const u8) bool {
    if (value != .object) return false;
    const fields = [_][]const u8{ "name", "description", "help" };
    for (fields) |field| {
        const candidate = value.object.get(field) orelse continue;
        if (candidate == .string and std.mem.indexOf(u8, candidate.string, query) != null) return true;
    }
    return false;
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

test "trusted operation aliases preserve canonical response bytes" {
    const Case = struct {
        alias: []const u8,
        canonical: []const u8,
        value: ?[]const u8 = null,
    };
    const fixture = "packages/tools/tests/fixtures/expert/clean_handler.ts";
    const cases = [_]Case{
        .{ .alias = "/meta", .canonical = "meta" },
        .{ .alias = "/features", .canonical = "features" },
        .{ .alias = "/restrictions", .canonical = "restrictions" },
        .{ .alias = "/rule", .canonical = "describe_rule", .value = "ZTS303" },
        .{ .alias = "describe-rule", .canonical = "describe_rule", .value = "ZTS303" },
        .{ .alias = "/search", .canonical = "search_rules", .value = "result" },
        .{ .alias = "search", .canonical = "search_rules", .value = "result" },
        .{ .alias = "/modules", .canonical = "modules", .value = fixture },
    };
    for (cases) |case| try expectAliasBytes(case.alias, case.canonical, case.value);
}

test "trusted argv errors preserve exact text and arity" {
    const Case = struct { args: []const []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{}, .expected = "zts_expert_query: requires one operation and at most one value\n" },
        .{ .args = &.{ "meta", "full", "extra" }, .expected = "zts_expert_query: requires one operation and at most one value\n" },
        .{ .args = &.{"unknown"}, .expected = "zts_expert_query: unknown operation unknown\n" },
        .{ .args = &.{ "features", "extra" }, .expected = "zts_expert_features: takes no arguments\n" },
        .{ .args = &.{ "restrictions", "extra" }, .expected = "zts_expert_restrictions: takes no arguments\n" },
        .{ .args = &.{"search_rules"}, .expected = "zts_expert_search requires one keyword argument\n" },
        .{ .args = &.{"modules"}, .expected = "zts_expert_modules: requires one file\n" },
        .{ .args = &.{"effects"}, .expected = "zts_expert_effects: requires a path\n" },
        .{ .args = &.{"holes"}, .expected = "zts_expert_holes: requires a path\n" },
        .{ .args = &.{"narrow"}, .expected = "zts_expert_narrow: requires a path\n" },
    };
    for (cases) |case| {
        var result = try tool.execute(testing.allocator, case.args);
        defer result.deinit(testing.allocator);
        try testing.expect(!result.ok);
        try testing.expectEqualStrings(case.expected, result.llm_text);
    }
}

test "protocol operations preserve direct response bytes" {
    const fixture = "packages/tools/tests/fixtures/expert/clean_handler.ts";
    try expectDirectProtocolBytes(&.{"meta"}, .meta, "{}", true);
    try expectDirectProtocolBytes(&.{ "meta", "full" }, .meta, "{\"view\":\"full\"}", true);
    try expectDirectProtocolBytes(&.{"features"}, .features, "{}", true);
    try expectDirectProtocolBytes(&.{"restrictions"}, .restrictions, "{}", true);
    try expectDirectProtocolBytes(&.{"describe_rule"}, .describe_rule, "{}", true);
    try expectDirectProtocolBytes(
        &.{ "describe_rule", "ZTS303" },
        .describe_rule,
        "{\"rule\":\"ZTS303\"}",
        true,
    );
    try expectDirectProtocolBytes(
        &.{ "describe_rule", "not-a-real-rule" },
        .describe_rule,
        "{\"rule\":\"not-a-real-rule\"}",
        true,
    );
    try expectDirectProtocolBytes(
        &.{ "modules", fixture },
        .modules,
        "{\"file\":\"packages/tools/tests/fixtures/expert/clean_handler.ts\"}",
        true,
    );
    try expectDirectProtocolBytes(
        &.{ "modules", "../outside.ts" },
        .modules,
        "{\"file\":\"../outside.ts\"}",
        false,
    );
}

test "search preserves frozen response bytes" {
    var query_result = try tool.execute(testing.allocator, &.{ "search_rules", "result" });
    defer query_result.deinit(testing.allocator);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(query_result.llm_text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try testing.expect(query_result.ok);
    try testing.expectEqual(@as(usize, 1017), query_result.llm_text.len);
    try testing.expectEqualStrings(
        "ba5fa5fd367bd783e37769ec5f39048367a87adef5d6eb946d798121e91dfeeb",
        &hex,
    );
    try testing.expect(query_result.llm_text[query_result.llm_text.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, query_result.llm_text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("describe_rule", parsed.value.object.get("operation").?.string);
    const rules = parsed.value.object.get("payload").?.object.get("rules").?.array;
    try testing.expect(rules.items.len >= 1);
    for (rules.items) |rule| try testing.expect(ruleMatches(rule, "result"));
}

test "custom operations run through query" {
    const fixture = "packages/tools/tests/fixtures/expert/clean_handler.ts";
    const cases = [_][]const u8{ "effects", "holes", "narrow" };
    for (cases) |operation| {
        var result = try tool.execute(testing.allocator, &.{ operation, fixture });
        defer result.deinit(testing.allocator);
        try testing.expect(result.ok);
        try testing.expect(std.mem.indexOf(u8, result.llm_text, fixture) != null);
    }
}

fn expectDirectProtocolBytes(
    query_args: []const []const u8,
    operation: client.Operation,
    input_json: []const u8,
    expected_ok: bool,
) !void {
    var query_result = try tool.execute(testing.allocator, query_args);
    defer query_result.deinit(testing.allocator);
    const projection = try client.invokeForTool(testing.allocator, .{
        .operation = operation,
        .input_json = input_json,
    });
    defer testing.allocator.free(projection.llm_text);

    try testing.expectEqual(expected_ok, query_result.ok);
    try testing.expectEqual(projection.ok, query_result.ok);
    try testing.expectEqualStrings(projection.llm_text, query_result.llm_text);
}

fn expectAliasBytes(
    alias: []const u8,
    canonical: []const u8,
    value: ?[]const u8,
) !void {
    var alias_result = if (value) |present|
        try tool.execute(testing.allocator, &.{ alias, present })
    else
        try tool.execute(testing.allocator, &.{alias});
    defer alias_result.deinit(testing.allocator);
    var canonical_result = if (value) |present|
        try tool.execute(testing.allocator, &.{ canonical, present })
    else
        try tool.execute(testing.allocator, &.{canonical});
    defer canonical_result.deinit(testing.allocator);

    try testing.expectEqual(canonical_result.ok, alias_result.ok);
    try testing.expectEqualStrings(canonical_result.llm_text, alias_result.llm_text);
}
