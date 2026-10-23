//! Golden-byte census of the contract wire.
//!
//! `contract_schema.zig` records one decision per field. This file holds the
//! evidence for the wire side of those decisions. A fully populated
//! `HandlerContract` goes through both writers. The bytes must equal the
//! committed goldens under `fixtures/contract/`, a parse of those bytes must
//! write the same bytes again, and every value in the goldens must be
//! populated. A field that the writer or the parser drops therefore shows up
//! as an empty value, a changed byte, or a missing key.
//!
//! The goldens were generated once from the writers as they stood before this
//! file existed. A byte change in the writers moves a golden. Regenerate a
//! golden only for a deliberate wire change.

const std = @import("std");
const contract_types = @import("contract_types.zig");
const handler_contract = @import("handler_contract.zig");
const contract_json_writer = @import("contract_json_writer.zig");
const contract_schema = @import("contract_schema.zig");
const module_authorization = @import("zts-base").module_authorization;

const HandlerContract = contract_types.HandlerContract;

const golden_v1 = @embedFile("fixtures/contract/full_v1.json");
const golden_v2 = @embedFile("fixtures/contract/full_v2.json");

const JsonVersion = enum { v1, v2 };

fn dupe(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

fn appendString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    try list.append(allocator, try dupe(allocator, text));
}

fn apiParam(
    allocator: std.mem.Allocator,
    name: []const u8,
    location: []const u8,
    schema_json: []const u8,
) !contract_types.ApiParamInfo {
    return .{
        .name = try dupe(allocator, name),
        .location = location,
        .required = true,
        .schema_json = try dupe(allocator, schema_json),
    };
}

/// Fill every serialized field of `contract` with a value that differs from
/// the default. The eight fields that the wire does not carry stay at their
/// defaults, because nothing reads them back.
fn populateFullContract(allocator: std.mem.Allocator, contract: *HandlerContract) !void {
    contract.handler.line = 12;
    contract.handler.column = 5;
    contract.source_identity = .{
        .core_grammar_hash = @as([32]u8, @splat(0x11)),
        .semantics_hash = @as([32]u8, @splat(0x22)),
    };

    try contract.routes.append(allocator, .{
        .pattern = try dupe(allocator, "/orders/:id"),
        .route_type = "prefix",
        .field = "url",
        .status = 202,
        .content_type = "text/html; charset=utf-8",
        .aot = true,
    });
    try contract.routes.append(allocator, .{
        .pattern = try dupe(allocator, "/health"),
        .route_type = "exact",
        .field = "path",
        .status = 200,
        .content_type = "application/json",
        .aot = true,
    });

    try appendString(allocator, &contract.modules, "zttp:fetch");
    try appendString(allocator, &contract.modules, "zttp:cache");

    {
        const module = try dupe(allocator, "zttp:fetch");
        var names: std.ArrayList([]const u8) = .empty;
        try appendString(allocator, &names, "fetchSync");
        try contract.functions.append(allocator, .{ .module = module, .names = names });
    }

    try appendString(allocator, &contract.env.literal, "ORDERS_TOKEN");
    contract.env.dynamic = true;

    try appendString(allocator, &contract.egress.endpoints, "https://api.example.com:443");
    try appendString(allocator, &contract.egress.urls, "https://api.example.com/orders");
    contract.egress.dynamic = true;

    try appendString(allocator, &contract.cache.namespaces, "orders");
    try appendString(allocator, &contract.cache.namespaces, "limits");
    contract.cache.dynamic = true;

    {
        var tables: std.ArrayList([]const u8) = .empty;
        try appendString(allocator, &tables, "orders");
        try appendString(allocator, &tables, "customers");
        try contract.sql.queries.append(allocator, .{
            .name = try dupe(allocator, "findOrder"),
            .statement = try dupe(allocator, "SELECT id FROM orders WHERE id = :id"),
            .operation = "select",
            .tables = tables,
        });
    }
    contract.sql.dynamic = true;

    try contract.api.schemas.append(allocator, .{
        .name = try dupe(allocator, "Order"),
        .schema_json = try dupe(allocator, "{\"type\":\"object\"}"),
    });
    try appendString(allocator, &contract.api.requests.schema_refs, "OrderCreate");
    contract.api.requests.dynamic = true;
    contract.api.auth = .{ .bearer = true, .jwt = true };
    contract.api.schemas_dynamic = true;
    contract.api.routes_dynamic = true;
    {
        var schema_refs: std.ArrayList([]const u8) = .empty;
        try appendString(allocator, &schema_refs, "OrderCreate");

        var path_params: std.ArrayList(contract_types.ApiParamInfo) = .empty;
        try path_params.append(allocator, try apiParam(allocator, "id", "path", "{\"type\":\"string\"}"));
        var query_params: std.ArrayList(contract_types.ApiParamInfo) = .empty;
        try query_params.append(allocator, try apiParam(allocator, "expand", "query", "{\"type\":\"boolean\"}"));
        var header_params: std.ArrayList(contract_types.ApiParamInfo) = .empty;
        try header_params.append(allocator, try apiParam(allocator, "x-request-id", "header", "{\"type\":\"string\"}"));

        // A schema spec holds one of ref, inline JSON, or dynamic, so three
        // bodies and three responses populate all three wire spellings.
        var request_bodies: std.ArrayList(contract_types.ApiBodyInfo) = .empty;
        try request_bodies.append(allocator, .{
            .content_type = try dupe(allocator, "application/json"),
            .schema = .{ .ref = try dupe(allocator, "OrderCreate") },
        });
        try request_bodies.append(allocator, .{
            .content_type = try dupe(allocator, "application/xml"),
            .schema = .{ .inline_json = try dupe(allocator, "{\"type\":\"object\"}") },
        });
        try request_bodies.append(allocator, .{
            .content_type = try dupe(allocator, "text/plain"),
            .schema = .dynamic,
        });

        var responses: std.ArrayList(contract_types.ApiResponseInfo) = .empty;
        try responses.append(allocator, .{
            .status = 201,
            .content_type = try dupe(allocator, "application/json"),
            .schema = .{ .ref = try dupe(allocator, "Order") },
        });
        try responses.append(allocator, .{
            .status = 202,
            .content_type = try dupe(allocator, "application/xml"),
            .schema = .{ .inline_json = try dupe(allocator, "{\"type\":\"string\"}") },
        });
        try responses.append(allocator, .{
            .status = 203,
            .content_type = try dupe(allocator, "text/plain"),
            .schema = .dynamic,
        });

        try contract.api.routes.append(allocator, .{
            .method = try dupe(allocator, "POST"),
            .path = try dupe(allocator, "/orders/:id"),
            .request_schema_refs = schema_refs,
            .request_schema_dynamic = true,
            .requires_bearer = true,
            .requires_jwt = true,
            .path_params = path_params,
            .query_params = query_params,
            .header_params = header_params,
            .query_params_dynamic = true,
            .header_params_dynamic = true,
            .request_bodies = request_bodies,
            .request_bodies_dynamic = true,
            .responses = responses,
            .responses_dynamic = true,
            .response_status = 201,
            .response_content_type = try dupe(allocator, "application/json"),
            .response_schema_ref = try dupe(allocator, "Order"),
            .response_schema_json = try dupe(allocator, "{\"type\":\"string\"}"),
            .response_schema_dynamic = true,
        });
    }

    contract.verification = .{
        .exhaustive_returns = true,
        .results_safe = true,
        .unreachable_code = true,
        .bytecode_verified = true,
    };
    contract.aot = .{ .pattern_count = 3, .has_default = true };
    contract.fault_coverage = .{
        .total_failable = 4,
        .covered = 4,
        .warnings = 1,
        .analysis_complete = true,
    };
    contract.rate_limiting = .{ .namespace = "limits", .dynamic = true };

    var properties = std.mem.zeroes(contract_types.HandlerProperties);
    inline for (@typeInfo(contract_types.HandlerProperties).@"struct".field_names) |field| {
        if (@FieldType(contract_types.HandlerProperties, field) == bool) @field(properties, field) = true;
    }
    properties.max_io_depth = 3;
    contract.properties = properties;

    {
        var intent = contract_types.IntentInfo{ .dynamic = true };
        var assertion = contract_types.IntentAssertion{
            .name = try dupe(allocator, "creates an order"),
            .method = try dupe(allocator, "POST"),
            .path = try dupe(allocator, "/orders/7"),
            .request_body_json = try dupe(allocator, "{\"item\":1}"),
            .expected_status = 201,
            .expected_body_json = try dupe(allocator, "{\"id\":7}"),
            .source_line = 30,
            .source_column = 9,
        };
        try assertion.expected_headers.append(allocator, .{
            .name = try dupe(allocator, "content-type"),
            .value = try dupe(allocator, "application/json"),
        });
        try intent.assertions.append(allocator, assertion);
        contract.intent = intent;
    }

    try appendString(allocator, &contract.declared_specs, "retry_safe");
    try appendString(allocator, &contract.declared_specs, "idempotent");

    {
        var extension = contract_types.ExtensionContract{};
        try appendString(allocator, &extension.egress_endpoints, "https://api.stripe.com:443");
        extension.egress_dynamic = true;
        var bucket = contract_types.ExtensionCategoryBucket{ .dynamic = true };
        try appendString(allocator, &bucket.literals, "stripe");
        try extension.categories.put(allocator, try dupe(allocator, "payment_gateway"), bucket);
        extension.contract_section = try dupe(allocator, "payments");
        try contract.extensions.put(allocator, try dupe(allocator, "zttp-ext:stripe"), extension);
    }

    try contract.spec_diagnostics.append(allocator, .{
        .kind = .incompatible_with_import,
        .spec_name = try dupe(allocator, "read_only"),
        .incompatible_module = try dupe(allocator, "zttp:cache"),
        .suggestion = try dupe(allocator, "remove the cache import"),
        .function = try dupe(allocator, "helper"),
    });

    {
        var path = contract_types.BehaviorPath{
            .route_method = try dupe(allocator, "POST"),
            .route_pattern = try dupe(allocator, "/orders/:id"),
            .conditions = .empty,
            .io_sequence = .empty,
            .response_status = 202,
            .io_depth = 2,
            .is_failure_path = true,
        };
        try path.conditions.append(allocator, .{
            .kind = .io_ok,
            .module = try dupe(allocator, "zttp:cache"),
            .func = try dupe(allocator, "cacheGet"),
        });
        try path.conditions.append(allocator, .{
            .kind = .io_fail,
            .module = try dupe(allocator, "zttp:fetch"),
            .func = try dupe(allocator, "fetchSync"),
        });
        try path.conditions.append(allocator, .{ .kind = .req_method, .value = try dupe(allocator, "POST") });
        try path.conditions.append(allocator, .{ .kind = .req_url, .value = try dupe(allocator, "/orders/7") });
        try path.io_sequence.append(allocator, .{
            .module = try dupe(allocator, "zttp:cache"),
            .func = try dupe(allocator, "cacheGet"),
            .arg_signature = try dupe(allocator, "lit:orders"),
        });
        try path.io_sequence.append(allocator, .{
            .module = try dupe(allocator, "zttp:fetch"),
            .func = try dupe(allocator, "fetchSync"),
            .arg_signature = try dupe(allocator, "?"),
        });
        try contract.behaviors.append(allocator, path);
    }
    contract.behaviors_exhaustive = true;

    {
        var envelope = contract_types.CostEnvelope{
            .total = .{ .linear = .{
                .coefficient = 3,
                .base = 2,
                .source = .{ .line = 4, .column = 6, .desc = try dupe(allocator, "items.length") },
            } },
            .exhaustive = true,
        };
        try envelope.entries.append(allocator, .{
            .module = try dupe(allocator, "zttp:cache"),
            .bound = .{ .constant = 2 },
        });
        try envelope.entries.append(allocator, .{
            .module = try dupe(allocator, "zttp:fetch"),
            .bound = .{ .unbounded = .{ .line = 8, .column = 2, .desc = try dupe(allocator, "dynamic url") } },
        });
        contract.cost_envelope = envelope;
    }

    {
        var capabilities = contract_types.CapabilityMatrix.empty;
        capabilities.items[0] = .clock;
        capabilities.items[1] = .network;
        capabilities.len = 2;
        capabilities.hash = module_authorization.capabilityHash(capabilities.slice());
        contract.capabilities = capabilities;

        var budget = contract_types.CapabilityMatrix.empty;
        budget.items[0] = .network;
        budget.len = 1;
        contract.capability_budget = budget;
    }
    contract.artifact_sha256 = @as([32]u8, @splat(0x33));
    contract.policy_hash = @as([32]u8, @splat(0x44));
    contract.wasm_policy_hash = @as([32]u8, @splat(0x55));
}

fn writeBytes(
    allocator: std.mem.Allocator,
    contract: *const HandlerContract,
    comptime json_version: JsonVersion,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    switch (json_version) {
        .v1 => try contract_json_writer.writeContractJson(contract, &output.writer),
        .v2 => try contract_json_writer.writeContractJsonV2(contract, &output.writer),
    }
    return output.toOwnedSlice();
}

fn goldenFor(comptime json_version: JsonVersion) []const u8 {
    return switch (json_version) {
        .v1 => golden_v1,
        .v2 => golden_v2,
    };
}

const versions = [_]JsonVersion{ .v1, .v2 };

test "the full fixture writes the committed golden bytes" {
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try dupe(allocator, "handler.ts"));
    defer contract.deinit(allocator);
    try populateFullContract(allocator, &contract);

    inline for (versions) |json_version| {
        const written = try writeBytes(allocator, &contract, json_version);
        defer allocator.free(written);
        try std.testing.expectEqualStrings(goldenFor(json_version), written);
    }
}

test "the full fixture writes, parses, and writes the same bytes" {
    const allocator = std.testing.allocator;
    var contract = handler_contract.emptyContract(try dupe(allocator, "handler.ts"));
    defer contract.deinit(allocator);
    try populateFullContract(allocator, &contract);

    inline for (versions) |json_version| {
        const first = try writeBytes(allocator, &contract, json_version);
        defer allocator.free(first);
        var parsed = try handler_contract.parseFromJson(allocator, first);
        defer parsed.deinit(allocator);
        const second = try writeBytes(allocator, &parsed, json_version);
        defer allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
        try std.testing.expectEqualStrings(goldenFor(json_version), second);
    }
}

test "the golden bytes parse and write back unchanged" {
    const allocator = std.testing.allocator;
    inline for (versions) |json_version| {
        var parsed = try handler_contract.parseFromJson(allocator, goldenFor(json_version));
        defer parsed.deinit(allocator);
        const written = try writeBytes(allocator, &parsed, json_version);
        defer allocator.free(written);
        try std.testing.expectEqualStrings(goldenFor(json_version), written);
    }
}

// ---------------------------------------------------------------------------
// Population check
// ---------------------------------------------------------------------------

const Counts = struct { empty: usize = 0, populated: usize = 0 };

const Tally = struct {
    paths: std.StringArrayHashMapUnmanaged(Counts) = .empty,
    /// Every value the walk looked at, containers included.
    visited: usize = 0,
    /// Values that hold no children: scalars and empty containers.
    leaves: usize = 0,
};

/// One key path where an empty value is legitimate, with the reason.
/// The path spells keys in the version 1 style. Arrays appear as `[]`.
const Allowance = struct {
    path: []const u8,
    reason: []const u8,
};

const schema_spec_reason = "a schema spec holds one of ref, inline JSON, or dynamic, so the other two spellings stay null or false; another entry in the same array populates this one";

const population_allowlist = [_]Allowance{
    .{ .path = "api.routes[].requestBodies[].schemaRef", .reason = schema_spec_reason },
    .{ .path = "api.routes[].requestBodies[].schema", .reason = schema_spec_reason },
    .{ .path = "api.routes[].requestBodies[].dynamic", .reason = schema_spec_reason },
    .{ .path = "api.routes[].responses[].schemaRef", .reason = schema_spec_reason },
    .{ .path = "api.routes[].responses[].schema", .reason = schema_spec_reason },
    .{ .path = "api.routes[].responses[].dynamic", .reason = schema_spec_reason },
};

fn isZeroHex(text: []const u8) bool {
    if (text.len < 2 or text.len % 2 != 0) return false;
    for (text) |byte| {
        if (byte != '0') return false;
    }
    return true;
}

/// Name why a value counts as unpopulated, or return null when it is populated.
fn emptyKind(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .null => "null",
        .bool => |flag| if (flag) null else "false",
        .integer => |number| if (number == 0) "0" else null,
        .float => |number| if (number == 0) "0" else null,
        .number_string => |text| if (std.mem.eql(u8, text, "0")) "0" else null,
        .string => |text| if (text.len == 0)
            "empty string"
        else if (isZeroHex(text))
            "all-zero hex"
        else
            null,
        .array => |items| if (items.items.len == 0) "[]" else null,
        .object => |fields| if (fields.count() == 0) "{}" else null,
    };
}

fn record(arena: std.mem.Allocator, tally: *Tally, path: []const u8, value: std.json.Value) !void {
    tally.visited += 1;
    const entry = try tally.paths.getOrPut(arena, path);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    if (emptyKind(value) != null) {
        entry.value_ptr.empty += 1;
    } else {
        entry.value_ptr.populated += 1;
    }
    switch (value) {
        .object => |fields| {
            if (fields.count() == 0) tally.leaves += 1;
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                const child = if (path.len == 0)
                    try arena.dupe(u8, field.key_ptr.*)
                else
                    try arena.print("{s}.{s}", .{ path, field.key_ptr.* });
                try record(arena, tally, child, field.value_ptr.*);
            }
        },
        .array => |items| {
            if (items.items.len == 0) tally.leaves += 1;
            const child = try arena.print("{s}[]", .{path});
            for (items.items) |item| try record(arena, tally, child, item);
        },
        else => tally.leaves += 1,
    }
}

/// Spell a version 1 key path in the version 2 style.
fn snakePath(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |byte| {
        if (std.ascii.isUpper(byte)) {
            try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(byte));
        } else {
            try out.append(arena, byte);
        }
    }
    return out.toOwnedSlice(arena);
}

/// The fewest values the walk may visit. An empty or truncated golden would
/// satisfy the emptiness rule with nothing to check, so the walk must see
/// at least this many leaves. Measured from the committed goldens.
const min_leaves_v1: usize = 220;
const min_leaves_v2: usize = 220;

fn checkPopulation(
    comptime json_version: JsonVersion,
    min_leaves: usize,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, goldenFor(json_version), .{});
    var tally = Tally{};
    try record(arena, &tally, "", parsed.value);

    var failures: usize = 0;
    var matched = @as([population_allowlist.len]bool, @splat(false));
    var iterator = tally.paths.iterator();
    while (iterator.next()) |entry| {
        const path = entry.key_ptr.*;
        if (path.len == 0) continue;
        const counts = entry.value_ptr.*;
        var allowance: ?usize = null;
        for (population_allowlist, 0..) |row, index| {
            const spelled = switch (json_version) {
                .v1 => row.path,
                .v2 => try snakePath(arena, row.path),
            };
            if (std.mem.eql(u8, spelled, path)) allowance = index;
        }
        if (allowance) |index| {
            matched[index] = true;
            // An allowed path must hold an empty value somewhere, or the row
            // is stale, and a populated value somewhere, or the field is
            // never exercised.
            if (counts.empty == 0 or counts.populated == 0) {
                std.debug.print("allowlist row does not fit the golden: {s} (empty {d}, populated {d})\n", .{ path, counts.empty, counts.populated });
                failures += 1;
            }
        } else if (counts.empty != 0) {
            std.debug.print("unpopulated value in the golden: {s} ({d} of {d} occurrences)\n", .{ path, counts.empty, counts.empty + counts.populated });
            failures += 1;
        }
    }
    for (matched, 0..) |hit, index| {
        if (!hit) {
            std.debug.print("allowlist row matches no path: {s}\n", .{population_allowlist[index].path});
            failures += 1;
        }
    }
    if (tally.leaves < min_leaves) {
        std.debug.print("the walk visited {d} leaves, below the floor of {d}\n", .{ tally.leaves, min_leaves });
        failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "the v1 golden holds no unpopulated value outside the allowlist" {
    try checkPopulation(.v1, min_leaves_v1);
}

test "the v2 golden holds no unpopulated value outside the allowlist" {
    try checkPopulation(.v2, min_leaves_v2);
}

test "the population allowlist gives every row a reason" {
    for (population_allowlist) |row| try std.testing.expect(row.reason.len > 0);
}

test "the emptiness rule refuses each empty shape" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "[]",
        "{}",
        "null",
        "false",
        "0",
        "0.0",
        "\"\"",
        "\"0000000000000000000000000000000000000000000000000000000000000000\"",
    };
    for (cases) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
        defer parsed.deinit();
        try std.testing.expect(emptyKind(parsed.value) != null);
    }
    const populated = [_][]const u8{ "[1]", "{\"a\":1}", "true", "7", "\"x\"", "\"0001\"" };
    for (populated) |source| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
        defer parsed.deinit();
        try std.testing.expect(emptyKind(parsed.value) == null);
    }
}

// ---------------------------------------------------------------------------
// Top-level keys against the schema
// ---------------------------------------------------------------------------

/// Root keys that the writer emits and that no `ContractWire` field reads.
const derived_root_keys = [_]Allowance{
    .{ .path = "payments", .reason = "the section that an extension names in contract_section; the writer mirrors the extension categories there and the parser reads them from extensions" },
    .{ .path = "provenSpecs", .reason = "a summary the writer derives from properties for ratchet consumers; the parser ignores it and the writer recomputes it" },
};

test "the golden root keys are the carried wire fields and the derived keys" {
    const allocator = std.testing.allocator;
    inline for (versions) |json_version| {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, goldenFor(json_version), .{});
        const root = parsed.value.object;

        var failures: usize = 0;
        for (contract_schema.wire_entries) |entry| {
            const key = switch (json_version) {
                .v1 => entry.wire_field,
                .v2 => try snakePath(arena, entry.wire_field),
            };
            const present = root.contains(key);
            switch (entry.kind) {
                .carries => if (!present) {
                    std.debug.print("the golden lacks the key of a carried wire field: {s}\n", .{key});
                    failures += 1;
                },
                .retired_refused => if (present) {
                    std.debug.print("the golden holds the key of a retired wire field: {s}\n", .{key});
                    failures += 1;
                },
            }
        }
        for (derived_root_keys) |derived| {
            const key = switch (json_version) {
                .v1 => derived.path,
                .v2 => try snakePath(arena, derived.path),
            };
            if (!root.contains(key)) {
                std.debug.print("the golden lacks a derived root key: {s}\n", .{key});
                failures += 1;
            }
        }
        var iterator = root.iterator();
        while (iterator.next()) |field| {
            const key = field.key_ptr.*;
            var known = false;
            for (derived_root_keys) |derived| {
                const expected = switch (json_version) {
                    .v1 => derived.path,
                    .v2 => try snakePath(arena, derived.path),
                };
                if (std.mem.eql(u8, expected, key)) known = true;
            }
            for (contract_schema.wire_entries) |entry| {
                const expected = switch (json_version) {
                    .v1 => entry.wire_field,
                    .v2 => try snakePath(arena, entry.wire_field),
                };
                if (entry.kind == .carries and std.mem.eql(u8, expected, key)) known = true;
            }
            if (!known) {
                std.debug.print("the golden holds a root key that no wire field maps: {s}\n", .{key});
                failures += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 0), failures);
    }
}

// ---------------------------------------------------------------------------
// Retired fields
// ---------------------------------------------------------------------------

const RetiredCase = struct {
    /// A `ContractWire` field classified `retired_refused`, in the version 1 spelling.
    wire_field: []const u8,
    /// The smallest JSON value that `rejectRetiredFields` must refuse.
    value: []const u8,
};

const retired_cases = [_]RetiredCase{
    .{ .wire_field = "serviceCalls", .value = "[{}]" },
    .{ .wire_field = "workflowCalls", .value = "[{}]" },
    .{ .wire_field = "affordances", .value = "[{}]" },
    .{ .wire_field = "affordancesDynamic", .value = "true" },
    .{ .wire_field = "tools", .value = "[{}]" },
    .{ .wire_field = "toolAuth", .value = "{}" },
    .{ .wire_field = "credentials", .value = "[]" },
    .{ .wire_field = "classifications", .value = "[{}]" },
    .{ .wire_field = "ceiling", .value = "{}" },
    .{ .wire_field = "durable", .value = "{\"used\":true}" },
    .{ .wire_field = "scope", .value = "{\"used\":true}" },
    .{ .wire_field = "sagas", .value = "[{}]" },
};

fn retiredDocument(
    arena: std.mem.Allocator,
    comptime json_version: JsonVersion,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    const version: u32 = if (json_version == .v1) 1 else 2;
    const spelled = switch (json_version) {
        .v1 => key,
        .v2 => try snakePath(arena, key),
    };
    return arena.print("{{\"version\":{d},\"handler\":{{\"path\":\"h.ts\",\"line\":1,\"column\":0}},\"{s}\":{s}}}", .{ version, spelled, value });
}

test "every retired wire field has a case and the parser refuses it in both versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var retired_count: usize = 0;
    for (contract_schema.wire_entries) |entry| {
        if (entry.kind != .retired_refused) continue;
        retired_count += 1;
        var has_case = false;
        for (retired_cases) |case| {
            if (std.mem.eql(u8, case.wire_field, entry.wire_field)) has_case = true;
        }
        if (!has_case) {
            std.debug.print("no refusal case for the retired wire field: {s}\n", .{entry.wire_field});
            return error.RetiredFieldHasNoCase;
        }
    }
    // The floor: a table with no retired field would pass the loop above.
    try std.testing.expectEqual(@as(usize, 12), retired_count);
    try std.testing.expectEqual(retired_count, retired_cases.len);

    inline for (versions) |json_version| {
        // The control: the same document without the retired key parses.
        const control = try retiredDocument(arena, json_version, "modules", "[]");
        var parsed = try handler_contract.parseFromJson(std.testing.allocator, control);
        parsed.deinit(std.testing.allocator);

        for (retired_cases) |case| {
            const document = try retiredDocument(arena, json_version, case.wire_field, case.value);
            const result = handler_contract.parseFromJson(std.testing.allocator, document);
            if (result) |*contract| {
                var owned = contract.*;
                owned.deinit(std.testing.allocator);
                std.debug.print("a retired wire field was accepted: {s}\n", .{case.wire_field});
                return error.RetiredFieldAccepted;
            } else |err| {
                try std.testing.expectEqual(error.UnsupportedRuntimeAuthority, err);
            }
        }
    }
}

test "the parser refuses a source identity that names a frontend" {
    const document =
        \\{"version":1,"handler":{"path":"h.ts","line":1,"column":0},"sourceIdentity":{"frontend":{}}}
    ;
    try std.testing.expectError(
        error.UnsupportedRuntimeAuthority,
        handler_contract.parseFromJson(std.testing.allocator, document),
    );
}
