//! The canonical `ZTCAT1` encoding of a handler's tool catalog (M4 T3).
//!
//! The layout is specified in docs/plans/2026-09-23-m4-t3-catalog-binding-design.md
//! section 3 and in docs/consumer-contract.md, so a reader can compute the same
//! digest without this code. Entries are sorted by name; each route is split
//! into method and path; both schemas are rewritten in canonical form with
//! `tool_schema.canonicalize`, so authored whitespace and key order cannot move
//! the digest. The encoder ends by running the kernel's own decoder over its
//! output: the decoder is the authority on what the artifact may carry.
const std = @import("std");
const zts = @import("zts");
const pcc = @import("zttp_proof_checker");

const ToolEntry = zts.handler_contract.ToolEntry;
const tool_schema = zts.tool_schema;

pub const magic = "ZTCAT1\x00\x00";
/// Schema 4 (M5 A1) prefixes each entry with its kind and carries agent entries.
/// The kernel decoder accepts this one schema only.
pub const schema_version: u16 = 4;

comptime {
    if (schema_version != pcc.tool_catalog.schema_version) @compileError("ZTCAT1 encoder and kernel decoder disagree on the schema");
    if (!std.mem.eql(u8, magic, pcc.tool_catalog.magic)) @compileError("ZTCAT1 encoder and kernel decoder disagree on the magic");
    if (pcc.tool_catalog.max_endpoint_bytes != zts.handler_contract.max_agent_endpoint_bytes) @compileError("ZTCAT1 endpoint bounds disagree");
    if (pcc.tool_catalog.max_agent_rounds != zts.handler_contract.max_agent_rounds) @compileError("ZTCAT1 agent round bounds disagree");
    if (pcc.tool_catalog.max_agent_tool_calls != zts.handler_contract.max_agent_tool_calls) @compileError("ZTCAT1 agent tool-call bounds disagree");
    if (pcc.tool_catalog.max_agent_argument_bytes != zts.handler_contract.max_agent_argument_bytes) @compileError("ZTCAT1 agent argument bounds disagree");
    if (pcc.tool_catalog.max_agent_result_bytes != zts.handler_contract.max_agent_result_bytes) @compileError("ZTCAT1 agent result bounds disagree");
    if (pcc.tool_catalog.max_agent_turn_deadline_ms != zts.handler_contract.max_agent_turn_deadline_ms) @compileError("ZTCAT1 agent deadline bounds disagree");
}

pub const EncodeError = std.mem.Allocator.Error || error{
    /// A route key is not `METHOD /path`.
    RouteKeyInvalid,
    /// A schema the contract carries does not compile under the closed subset.
    SchemaNotInSubset,
    /// The encoded bytes are refused by the kernel decoder: a bound, an order,
    /// or a uniqueness rule the catalog breaks.
    CatalogRefused,
};

/// Encode `tools` as `ZTCAT1` bytes, or return null for an empty catalog: a
/// handler with no catalog ships no section and no graph member.
pub fn encode(allocator: std.mem.Allocator, tools: []const ToolEntry) EncodeError!?[]u8 {
    if (tools.len == 0) return null;

    const order = try allocator.alloc(usize, tools.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, tools, entryNameLess);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try appendInt(allocator, &out, u16, schema_version);
    try appendInt(allocator, &out, u16, std.math.cast(u16, tools.len) orelse return error.CatalogRefused);

    for (order) |index| {
        const tool = tools[index];
        const space = std.mem.indexOfScalar(u8, tool.route, ' ') orelse return error.RouteKeyInvalid;
        const method = tool.route[0..space];
        const path = tool.route[space + 1 ..];
        if (method.len == 0 or path.len == 0) return error.RouteKeyInvalid;

        try appendInt(allocator, &out, u8, if (tool.agent == null) @intFromEnum(pcc.tool_catalog.EntryKind.tool) else @intFromEnum(pcc.tool_catalog.EntryKind.agent));
        try appendString(allocator, &out, tool.name);
        const upper = try std.ascii.allocUpperString(allocator, method);
        defer allocator.free(upper);
        try appendString(allocator, &out, upper);
        try appendString(allocator, &out, path);
        try appendString(allocator, &out, tool.description);
        if (tool.agent) |agent| {
            try appendInt(allocator, &out, u32, tool.max_input_bytes);
            try appendExports(allocator, &out, tool.reachable_exports.items);
            try appendInt(allocator, &out, u16, std.math.cast(u16, agent.tools.items.len) orelse return error.CatalogRefused);
            for (agent.tools.items) |name| try appendString(allocator, &out, name);
            try appendString(allocator, &out, agent.provider_endpoint);
            try appendString(allocator, &out, agent.provider_credential);
            try appendInt(allocator, &out, u32, agent.limits.rounds);
            try appendInt(allocator, &out, u32, agent.limits.tool_calls);
            try appendInt(allocator, &out, u32, agent.limits.tool_calls_per_round);
            try appendInt(allocator, &out, u32, agent.limits.argument_bytes);
            try appendInt(allocator, &out, u32, agent.limits.result_bytes);
            try appendInt(allocator, &out, u32, agent.limits.turn_deadline_ms);
            continue;
        }
        try appendString(allocator, &out, tool.input_schema_name);
        try appendCanonicalSchema(allocator, &out, tool.input_schema_json);
        try appendString(allocator, &out, tool.output_schema_name);
        try appendCanonicalSchema(allocator, &out, tool.output_schema_json);
        try appendInt(allocator, &out, u32, tool.max_input_bytes);
        // Length 0 is absent. An empty field name the contract carried would
        // encode as absent and drop a binding, so it is refused instead.
        for ([_]?[]const u8{ tool.scope_tenant, tool.scope_subject }) |scope_field| {
            const field = scope_field orelse "";
            if (scope_field != null and field.len == 0) return error.CatalogRefused;
            try appendString(allocator, &out, field);
        }
        try appendExports(allocator, &out, tool.reachable_exports.items);
        // The grant is the distinct names. The contract sorts its credentials
        // by (name, endpoint), so equal names are adjacent.
        var distinct: usize = 0;
        for (tool.credentials.items, 0..) |cred, j| {
            if (j == 0 or !std.mem.eql(u8, tool.credentials.items[j - 1].name, cred.name)) distinct += 1;
        }
        try appendInt(allocator, &out, u16, std.math.cast(u16, distinct) orelse return error.CatalogRefused);
        for (tool.credentials.items, 0..) |cred, j| {
            if (j > 0 and std.mem.eql(u8, tool.credentials.items[j - 1].name, cred.name)) continue;
            try appendString(allocator, &out, cred.name);
        }
    }

    const bytes = try out.toOwnedSlice(allocator);
    errdefer allocator.free(bytes);
    _ = pcc.tool_catalog.decode(bytes) catch return error.CatalogRefused;
    return bytes;
}

fn entryNameLess(tools: []const ToolEntry, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, tools[a].name, tools[b].name);
}

fn appendExports(allocator: std.mem.Allocator, out: *std.ArrayList(u8), exports: []const zts.handler_contract.ToolExport) EncodeError!void {
    try appendInt(allocator, out, u16, std.math.cast(u16, exports.len) orelse return error.CatalogRefused);
    for (exports) |exp| {
        try appendString(allocator, out, exp.module);
        try appendString(allocator, out, exp.name);
    }
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    try appendInt(allocator, out, u32, std.math.cast(u32, s.len) orelse return error.CatalogRefused);
    try out.appendSlice(allocator, s);
}

fn appendCanonicalSchema(allocator: std.mem.Allocator, out: *std.ArrayList(u8), schema_json: []const u8) EncodeError!void {
    var compiled = tool_schema.compile(allocator, schema_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SchemaNotInSubset => return error.SchemaNotInSubset,
    };
    defer compiled.deinit();
    const canonical = try tool_schema.canonicalize(allocator, &compiled);
    defer allocator.free(canonical);
    try appendString(allocator, out, canonical);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const in_schema =
    \\{ "type": "object", "additionalProperties": false, "required": ["id"],
    \\  "properties": { "id": { "maxLength": 8, "type": "string" } } }
;
const out_schema =
    \\{"type":"object","additionalProperties":false,"properties":{}}
;

fn testEntry(allocator: std.mem.Allocator, name: []const u8, route: []const u8, exports: []const [2][]const u8) !ToolEntry {
    var entry = ToolEntry{
        .name = &.{},
        .route = &.{},
        .description = &.{},
        .input_schema_name = &.{},
        .input_schema_json = &.{},
        .output_schema_name = &.{},
        .output_schema_json = &.{},
        .max_input_bytes = 4096,
    };
    errdefer entry.deinit(allocator);
    entry.name = try allocator.dupe(u8, name);
    entry.route = try allocator.dupe(u8, route);
    entry.description = try allocator.dupe(u8, "Look up one order.");
    entry.input_schema_name = try allocator.dupe(u8, "In");
    entry.input_schema_json = try allocator.dupe(u8, in_schema);
    entry.output_schema_name = try allocator.dupe(u8, "Out");
    entry.output_schema_json = try allocator.dupe(u8, out_schema);
    for (exports) |pair| {
        const module = try allocator.dupe(u8, pair[0]);
        errdefer allocator.free(module);
        const exp_name = try allocator.dupe(u8, pair[1]);
        errdefer allocator.free(exp_name);
        try entry.reachable_exports.append(allocator, .{ .module = module, .name = exp_name });
    }
    return entry;
}

fn testAgentEntry(allocator: std.mem.Allocator, name: []const u8, route: []const u8, tools: []const []const u8, exports: []const [2][]const u8) !ToolEntry {
    var entry = try testEntry(allocator, name, route, exports);
    errdefer entry.deinit(allocator);
    allocator.free(entry.input_schema_name);
    entry.input_schema_name = &.{};
    allocator.free(entry.input_schema_json);
    entry.input_schema_json = &.{};
    allocator.free(entry.output_schema_name);
    entry.output_schema_name = &.{};
    allocator.free(entry.output_schema_json);
    entry.output_schema_json = &.{};

    var agent = zts.handler_contract.AgentEntry{
        .tools = .empty,
        .provider_endpoint = &.{},
        .provider_credential = &.{},
        .limits = .{
            .rounds = 4,
            .tool_calls = 8,
            .tool_calls_per_round = 4,
            .argument_bytes = 4096,
            .result_bytes = 16384,
            .turn_deadline_ms = 20000,
        },
    };
    errdefer agent.deinit(allocator);
    agent.provider_endpoint = try allocator.dupe(u8, "https://api.example.com:443");
    agent.provider_credential = try allocator.dupe(u8, "provider");
    for (tools) |tool| {
        const owned = try allocator.dupe(u8, tool);
        errdefer allocator.free(owned);
        try agent.tools.append(allocator, owned);
    }
    try entry.credentials.append(allocator, .{ .name = &.{}, .endpoint = &.{} });
    entry.credentials.items[0].name = try allocator.dupe(u8, agent.provider_credential);
    entry.credentials.items[0].endpoint = try allocator.dupe(u8, agent.provider_endpoint);
    entry.agent = agent;
    return entry;
}

test "an empty catalog encodes to nothing" {
    try testing.expectEqual(@as(?[]u8, null), try encode(testing.allocator, &.{}));
}

test "entries are sorted, routes split, and schemas canonical in the encoding" {
    const allocator = testing.allocator;
    var tools = [_]ToolEntry{
        try testEntry(allocator, "zeta", "post /z", &.{.{ "zttp:crypto", "sha256" }}),
        try testEntry(allocator, "alpha", "GET /a", &.{}),
    };
    defer for (&tools) |*t| t.deinit(allocator);

    const bytes = (try encode(allocator, &tools)) orelse return error.TestExpectedBytes;
    defer allocator.free(bytes);

    const catalog = try pcc.tool_catalog.decode(bytes);
    var it = catalog.entries();
    const first = (try it.next()) orelse return error.TestMissingEntry;
    try testing.expectEqualStrings("alpha", first.name);
    try testing.expectEqualStrings("GET", first.method);
    try testing.expectEqualStrings("/a", first.path);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"id\":{\"type\":\"string\",\"maxLength\":8}},\"required\":[\"id\"]}",
        first.input_schema,
    );
    const second = (try it.next()) orelse return error.TestMissingEntry;
    try testing.expectEqualStrings("zeta", second.name);
    try testing.expectEqualStrings("POST", second.method);
    var exports = second.exports;
    const exp = (try exports.next()) orelse return error.TestMissingExport;
    try testing.expectEqualStrings("zttp:crypto", exp.module);
    try testing.expectEqualStrings("sha256", exp.name);
    try testing.expect((try it.next()) == null);
}

test "schema 4 inserts only the kind byte before a tool's schema 3 body" {
    const allocator = testing.allocator;
    var tools = [_]ToolEntry{try testEntry(allocator, "alpha", "POST /a", &.{})};
    defer tools[0].deinit(allocator);
    const bytes = (try encode(allocator, &tools)) orelse return error.TestExpectedBytes;
    defer allocator.free(bytes);

    var legacy_buf: [1024]u8 = undefined;
    var legacy = pcc.tool_catalog.test_support.Writer{ .buf = &legacy_buf };
    legacy.raw(magic);
    legacy.int(u16, 3);
    legacy.int(u16, 1);
    legacy.string("alpha");
    legacy.string("POST");
    legacy.string("/a");
    legacy.string("Look up one order.");
    legacy.string("In");
    legacy.string("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"id\":{\"type\":\"string\",\"maxLength\":8}},\"required\":[\"id\"]}");
    legacy.string("Out");
    legacy.string("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}");
    legacy.int(u32, 4096);
    legacy.string("");
    legacy.string("");
    legacy.int(u16, 0);
    legacy.int(u16, 0);

    try testing.expectEqual(@as(u8, @intFromEnum(pcc.tool_catalog.EntryKind.tool)), bytes[pcc.tool_catalog.header_size]);
    try testing.expectEqualSlices(
        u8,
        legacy.bytes()[pcc.tool_catalog.header_size..],
        bytes[pcc.tool_catalog.header_size + 1 ..],
    );
}

test "an agent entry encodes its exports tools provider and limits" {
    const allocator = testing.allocator;
    const expected_exports = [_][2][]const u8{
        .{ "zttp:fetch", "fetch" },
        .{ "zttp:tool", "callTool" },
    };
    var tools = [_]ToolEntry{
        try testAgentEntry(allocator, "assistant", "POST /agent", &.{"lookup"}, &expected_exports),
        try testEntry(allocator, "lookup", "POST /lookup", &.{}),
    };
    defer for (&tools) |*entry| entry.deinit(allocator);

    const bytes = (try encode(allocator, &tools)) orelse return error.TestExpectedBytes;
    defer allocator.free(bytes);
    const catalog = try pcc.tool_catalog.decode(bytes);
    var entries = catalog.entries();
    const assistant = (try entries.next()) orelse return error.TestMissingEntry;
    try testing.expectEqual(pcc.tool_catalog.EntryKind.agent, assistant.kind);
    try testing.expectEqualStrings("", assistant.input_schema);
    var exports = assistant.exports;
    for (expected_exports) |pair| {
        const actual = (try exports.next()) orelse return error.TestMissingExport;
        try testing.expectEqualStrings(pair[0], actual.module);
        try testing.expectEqualStrings(pair[1], actual.name);
    }
    try testing.expectEqual(@as(?pcc.tool_catalog.Export, null), try exports.next());
    const agent = assistant.agent orelse return error.TestMissingAgent;
    var names = agent.tools;
    try testing.expectEqualStrings("lookup", (try names.next()) orelse return error.TestMissingName);
    try testing.expectEqual(@as(?[]const u8, null), try names.next());
    try testing.expectEqualStrings("https://api.example.com:443", agent.provider_endpoint);
    try testing.expectEqualStrings("provider", agent.provider_credential);
    try testing.expectEqual(@as(u32, 4), agent.limits.rounds);
    try testing.expectEqual(@as(u32, 8), agent.limits.tool_calls);
    try testing.expectEqual(@as(u32, 4), agent.limits.tool_calls_per_round);
    try testing.expectEqual(@as(u32, 4096), agent.limits.argument_bytes);
    try testing.expectEqual(@as(u32, 16384), agent.limits.result_bytes);
    try testing.expectEqual(@as(u32, 20000), agent.limits.turn_deadline_ms);
}

test "the encoding does not depend on source order or schema spelling" {
    const allocator = testing.allocator;
    var forward = [_]ToolEntry{
        try testEntry(allocator, "a", "POST /a", &.{}),
        try testEntry(allocator, "b", "POST /b", &.{}),
    };
    defer for (&forward) |*t| t.deinit(allocator);
    var backward = [_]ToolEntry{
        try testEntry(allocator, "b", "POST /b", &.{}),
        try testEntry(allocator, "a", "POST /a", &.{}),
    };
    defer for (&backward) |*t| t.deinit(allocator);
    allocator.free(backward[1].input_schema_json);
    backward[1].input_schema_json = try allocator.dupe(u8,
        \\{"properties":{"id":{"type":"string","maxLength":8}},"required":["id"],"additionalProperties":false,"type":"object"}
    );

    const a = (try encode(allocator, &forward)) orelse return error.TestExpectedBytes;
    defer allocator.free(a);
    const b = (try encode(allocator, &backward)) orelse return error.TestExpectedBytes;
    defer allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expectEqualSlices(u8, &pcc.tool_catalog.digest(a), &pcc.tool_catalog.digest(b));
}

test "scope fields are encoded after the byte bound and decode as written" {
    const allocator = testing.allocator;
    var tools = [_]ToolEntry{
        try testEntry(allocator, "scoped", "POST /s", &.{}),
        try testEntry(allocator, "plain", "POST /p", &.{}),
    };
    defer for (&tools) |*t| t.deinit(allocator);
    tools[0].scope_tenant = try allocator.dupe(u8, "id");

    const bytes = (try encode(allocator, &tools)) orelse return error.TestExpectedBytes;
    defer allocator.free(bytes);
    const catalog = try pcc.tool_catalog.decode(bytes);
    var it = catalog.entries();
    const plain = (try it.next()) orelse return error.TestMissingEntry;
    try testing.expectEqualStrings("plain", plain.name);
    try testing.expect(plain.scope_tenant == null and plain.scope_subject == null);
    const scoped = (try it.next()) orelse return error.TestMissingEntry;
    try testing.expectEqualStrings("id", scoped.scope_tenant orelse return error.TestMissingScope);
    try testing.expect(scoped.scope_subject == null);

    // An empty bound field cannot pass for an absent one.
    tools[1].scope_subject = try allocator.dupe(u8, "");
    try testing.expectError(error.CatalogRefused, encode(allocator, &tools));
}

test "a tool's credential names are encoded once each and decode in order" {
    const allocator = testing.allocator;
    var tools = [_]ToolEntry{try testEntry(allocator, "lookup", "POST /l", &.{})};
    defer for (&tools) |*t| t.deinit(allocator);
    // The contract's order: by (name, endpoint). `weather` at two endpoints is
    // one grant.
    const pairs = [_][2][]const u8{
        .{ "billing", "https://billing.example:443" },
        .{ "weather", "https://a.example:443" },
        .{ "weather", "https://b.example:443" },
    };
    for (pairs) |pair| {
        const name = try allocator.dupe(u8, pair[0]);
        errdefer allocator.free(name);
        const endpoint = try allocator.dupe(u8, pair[1]);
        errdefer allocator.free(endpoint);
        try tools[0].credentials.append(allocator, .{ .name = name, .endpoint = endpoint });
    }

    const bytes = (try encode(allocator, &tools)) orelse return error.TestExpectedBytes;
    defer allocator.free(bytes);
    const catalog = try pcc.tool_catalog.decode(bytes);
    var it = catalog.entries();
    const entry = (try it.next()) orelse return error.TestMissingEntry;
    var names = entry.credentials;
    try testing.expectEqualStrings("billing", (try names.next()) orelse return error.TestMissingName);
    try testing.expectEqualStrings("weather", (try names.next()) orelse return error.TestMissingName);
    try testing.expectEqual(@as(?[]const u8, null), try names.next());
}

test "a catalog the kernel would refuse is not encoded" {
    const allocator = testing.allocator;
    var duplicate_route = [_]ToolEntry{
        try testEntry(allocator, "a", "POST /same", &.{}),
        try testEntry(allocator, "b", "POST /same", &.{}),
    };
    defer for (&duplicate_route) |*t| t.deinit(allocator);
    try testing.expectError(error.CatalogRefused, encode(allocator, &duplicate_route));

    var bad_route = [_]ToolEntry{try testEntry(allocator, "a", "POST", &.{})};
    defer for (&bad_route) |*t| t.deinit(allocator);
    try testing.expectError(error.RouteKeyInvalid, encode(allocator, &bad_route));

    var open_schema = [_]ToolEntry{try testEntry(allocator, "a", "POST /a", &.{})};
    defer for (&open_schema) |*t| t.deinit(allocator);
    allocator.free(open_schema[0].output_schema_json);
    open_schema[0].output_schema_json = try allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
    try testing.expectError(error.SchemaNotInSubset, encode(allocator, &open_schema));
}
