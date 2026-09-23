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
/// Schema 2 (M4 T5) carries each entry's scope fields. The kernel decoder
/// accepts this one schema only.
pub const schema_version: u16 = 2;

comptime {
    if (schema_version != pcc.tool_catalog.schema_version) @compileError("ZTCAT1 encoder and kernel decoder disagree on the schema");
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

        try appendString(allocator, &out, tool.name);
        const upper = try std.ascii.allocUpperString(allocator, method);
        defer allocator.free(upper);
        try appendString(allocator, &out, upper);
        try appendString(allocator, &out, path);
        try appendString(allocator, &out, tool.description);
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
        try appendInt(allocator, &out, u16, std.math.cast(u16, tool.reachable_exports.items.len) orelse return error.CatalogRefused);
        for (tool.reachable_exports.items) |exp| {
            try appendString(allocator, &out, exp.module);
            try appendString(allocator, &out, exp.name);
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
