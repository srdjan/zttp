//! Pure contract gate for one model tool call.
//!
//! Six checks in cost order against the tool's declared `input_schema`. The
//! gate observes; it never blocks, retries, or rewrites a call. Its verdict is
//! recorded separately from the execution outcome and the two are never merged,
//! because a schema-satisfying call can still fail when it runs.
//!
//! Scope of the supported schema subset is deliberate and narrow:
//! - the root must be a JSON object schema;
//! - `properties` is the exact parameter allowlist, so an absent `properties`
//!   means no parameter is permitted;
//! - `required` is an array of names;
//! - `type` is checked at the top level only, not inside nested objects or
//!   array items;
//! - `enum` is checked for string and integer members.
//! Anything outside that subset in a tool's own schema is `malformed_schema`,
//! which is a defect in the tool, not in the model's call.

const std = @import("std");
const ToolDef = @import("registry/tool.zig").ToolDef;

pub const FailureReason = enum {
    /// The called name is not in the registry for this surface.
    undeclared_tool,
    /// The argument payload is empty or does not parse as JSON.
    args_not_json,
    /// The argument payload parses but is not a JSON object.
    args_not_object,
    /// A name listed in the schema's `required` array is absent.
    missing_required,
    /// A supplied parameter is not in the schema's `properties` allowlist.
    undeclared_parameter,
    /// A supplied value does not match its declared `type`.
    type_mismatch,
    /// A supplied value is not a member of its declared `enum`.
    enum_violation,
    /// The tool's own schema is outside the supported subset. This is a defect
    /// in the tool definition, not in the model's call.
    malformed_schema,
};

pub const Failure = struct {
    reason: FailureReason,
    /// The parameter the failure names. Empty when the failure concerns the
    /// call as a whole. Borrowed from the arena passed to `check`, so it does
    /// not outlive that arena.
    parameter: []const u8 = &.{},
};

pub const Verdict = union(enum) {
    pass,
    fail: Failure,
};

pub fn reasonLabel(reason: FailureReason) []const u8 {
    return switch (reason) {
        .undeclared_tool => "undeclared_tool",
        .args_not_json => "args_not_json",
        .args_not_object => "args_not_object",
        .missing_required => "missing_required",
        .undeclared_parameter => "undeclared_parameter",
        .type_mismatch => "type_mismatch",
        .enum_violation => "enum_violation",
        .malformed_schema => "malformed_schema",
    };
}

/// Grade one tool call. `tool` is null when the name is not declared.
///
/// `arena` is scratch. Every slice inside the returned `Verdict` borrows from
/// it, so the caller must read the verdict before the arena is released.
pub fn check(
    arena: std.mem.Allocator,
    tool: ?*const ToolDef,
    args_json: []const u8,
) error{OutOfMemory}!Verdict {
    // 1. declared tool name
    const def = tool orelse return .{ .fail = .{ .reason = .undeclared_tool } };

    // 2. JSON parse, then object shape
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len == 0) return .{ .fail = .{ .reason = .args_not_json } };
    const args_value = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .fail = .{ .reason = .args_not_json } },
    };
    if (args_value != .object) return .{ .fail = .{ .reason = .args_not_object } };
    const args = args_value.object;

    const schema_trimmed = std.mem.trim(u8, def.input_schema, " \t\r\n");
    if (schema_trimmed.len == 0) return .{ .fail = .{ .reason = .malformed_schema } };
    const schema_value = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .fail = .{ .reason = .malformed_schema } },
    };
    if (schema_value != .object) return .{ .fail = .{ .reason = .malformed_schema } };
    const schema = schema_value.object;

    const properties: ?std.json.ObjectMap = blk: {
        const raw = schema.get("properties") orelse break :blk null;
        if (raw != .object) return .{ .fail = .{ .reason = .malformed_schema } };
        break :blk raw.object;
    };

    // 3. required parameters present
    if (schema.get("required")) |raw_required| {
        if (raw_required != .array) return .{ .fail = .{ .reason = .malformed_schema } };
        for (raw_required.array.items) |item| {
            if (item != .string) return .{ .fail = .{ .reason = .malformed_schema } };
            if (args.get(item.string) == null) {
                return .{ .fail = .{ .reason = .missing_required, .parameter = item.string } };
            }
        }
    }

    // 4. no undeclared parameter
    var supplied = args.iterator();
    while (supplied.next()) |entry| {
        const props = properties orelse
            return .{ .fail = .{ .reason = .undeclared_parameter, .parameter = entry.key_ptr.* } };
        if (props.get(entry.key_ptr.*) == null) {
            return .{ .fail = .{ .reason = .undeclared_parameter, .parameter = entry.key_ptr.* } };
        }
    }

    // 5 and 6. type match, then enum membership, per supplied parameter
    const props = properties orelse return .pass;
    var typed = args.iterator();
    while (typed.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const spec = props.get(name) orelse unreachable; // check 4 proved membership
        if (spec != .object) return .{ .fail = .{ .reason = .malformed_schema } };

        if (spec.object.get("type")) |declared| {
            if (declared != .string) return .{ .fail = .{ .reason = .malformed_schema } };
            switch (try typeMatches(declared.string, value)) {
                .ok => {},
                .mismatch => return .{ .fail = .{ .reason = .type_mismatch, .parameter = name } },
                .unknown_type => return .{ .fail = .{ .reason = .malformed_schema, .parameter = name } },
            }
        }

        if (spec.object.get("enum")) |members| {
            if (members != .array) return .{ .fail = .{ .reason = .malformed_schema } };
            if (!enumContains(members.array.items, value)) {
                return .{ .fail = .{ .reason = .enum_violation, .parameter = name } };
            }
        }
    }

    return .pass;
}

const TypeCheck = enum { ok, mismatch, unknown_type };

fn typeMatches(declared: []const u8, value: std.json.Value) error{OutOfMemory}!TypeCheck {
    const matched = if (std.mem.eql(u8, declared, "string"))
        value == .string
    else if (std.mem.eql(u8, declared, "integer"))
        value == .integer
    else if (std.mem.eql(u8, declared, "number"))
        value == .integer or value == .float
    else if (std.mem.eql(u8, declared, "boolean"))
        value == .bool
    else if (std.mem.eql(u8, declared, "array"))
        value == .array
    else if (std.mem.eql(u8, declared, "object"))
        value == .object
    else
        return .unknown_type;

    return if (matched) .ok else .mismatch;
}

fn enumContains(members: []const std.json.Value, value: std.json.Value) bool {
    for (members) |member| {
        switch (value) {
            .string => |s| if (member == .string and std.mem.eql(u8, member.string, s)) return true,
            .integer => |i| if (member == .integer and member.integer == i) return true,
            .bool => |b| if (member == .bool and member.bool == b) return true,
            else => {},
        }
    }
    return false;
}

const testing = std.testing;

fn expectPass(schema: []const u8, args_json: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tool = ToolDef{
        .name = "probe",
        .label = "Probe",
        .description = "test tool",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = schema,
        .decode_json = undefined,
        .execute = undefined,
    };
    const verdict = try check(arena.allocator(), &tool, args_json);
    switch (verdict) {
        .pass => {},
        .fail => |f| {
            std.debug.print("unexpected fail: {s} on '{s}'\n", .{ reasonLabel(f.reason), f.parameter });
            return error.TestUnexpectedFailure;
        },
    }
}

fn expectFail(schema: []const u8, args_json: []const u8, want: FailureReason) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tool = ToolDef{
        .name = "probe",
        .label = "Probe",
        .description = "test tool",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = schema,
        .decode_json = undefined,
        .execute = undefined,
    };
    const verdict = try check(arena.allocator(), &tool, args_json);
    switch (verdict) {
        .pass => return error.TestExpectedFailure,
        .fail => |f| try testing.expectEqual(want, f.reason),
    }
}

const object_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"depth":{"type":"integer"},"mode":{"type":"string","enum":["fast","full"]},"deep":{"type":"boolean"}},"required":["path"]}
;

test "contract gate: an undeclared tool name fails before anything is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const verdict = try check(arena.allocator(), null, "{\"path\":\"src\"}");
    switch (verdict) {
        .pass => return error.TestExpectedFailure,
        .fail => |f| try testing.expectEqual(FailureReason.undeclared_tool, f.reason),
    }
}

test "contract gate: unparsable arguments fail as args_not_json" {
    try expectFail(object_schema, "{\"path\":", .args_not_json);
}

test "contract gate: a non-object argument payload fails as args_not_object" {
    try expectFail(object_schema, "[1,2,3]", .args_not_object);
}

test "contract gate: a missing required parameter fails and names it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tool = ToolDef{
        .name = "probe",
        .label = "Probe",
        .description = "test tool",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = object_schema,
        .decode_json = undefined,
        .execute = undefined,
    };
    const verdict = try check(arena.allocator(), &tool, "{\"depth\":2}");
    switch (verdict) {
        .pass => return error.TestExpectedFailure,
        .fail => |f| {
            try testing.expectEqual(FailureReason.missing_required, f.reason);
            try testing.expectEqualStrings("path", f.parameter);
        },
    }
}

test "contract gate: an undeclared parameter fails and names it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tool = ToolDef{
        .name = "probe",
        .label = "Probe",
        .description = "test tool",
        .effect = .analyze,
        .context_policy = .exact,
        .model_exposure = .visible,
        .input_schema = object_schema,
        .decode_json = undefined,
        .execute = undefined,
    };
    const verdict = try check(arena.allocator(), &tool, "{\"path\":\"src\",\"recurse\":true}");
    switch (verdict) {
        .pass => return error.TestExpectedFailure,
        .fail => |f| {
            try testing.expectEqual(FailureReason.undeclared_parameter, f.reason);
            try testing.expectEqualStrings("recurse", f.parameter);
        },
    }
}

test "contract gate: a wrong declared type fails as type_mismatch" {
    try expectFail(object_schema, "{\"path\":7}", .type_mismatch);
    try expectFail(object_schema, "{\"path\":\"src\",\"depth\":\"two\"}", .type_mismatch);
    try expectFail(object_schema, "{\"path\":\"src\",\"deep\":\"yes\"}", .type_mismatch);
    try expectFail(object_schema, "{\"path\":null}", .type_mismatch);
}

test "contract gate: a value outside its enum fails as enum_violation" {
    try expectFail(object_schema, "{\"path\":\"src\",\"mode\":\"turbo\"}", .enum_violation);
}

test "contract gate: a well-formed call passes with every optional present" {
    try expectPass(object_schema, "{\"path\":\"src\",\"depth\":2,\"mode\":\"full\",\"deep\":true}");
}

test "contract gate: a well-formed call passes with only the required parameter" {
    try expectPass(object_schema, "{\"path\":\"src\"}");
}

test "contract gate: a number type accepts both integer and float" {
    const schema =
        \\{"type":"object","properties":{"ratio":{"type":"number"}},"required":["ratio"]}
    ;
    try expectPass(schema, "{\"ratio\":2}");
    try expectPass(schema, "{\"ratio\":2.5}");
    try expectFail(schema, "{\"ratio\":\"2.5\"}", .type_mismatch);
}

test "contract gate: an empty schema permits an empty object and nothing else" {
    try expectPass("{}", "{}");
    try expectFail("{}", "{\"x\":1}", .undeclared_parameter);
}

test "contract gate: whitespace-only and empty argument payloads fail as args_not_json" {
    try expectFail(object_schema, "", .args_not_json);
    try expectFail(object_schema, "   \n\t ", .args_not_json);
}

test "contract gate: a tool schema that is not a JSON object is malformed_schema" {
    try expectFail("[1,2]", "{}", .malformed_schema);
    try expectFail("{\"type\":\"object\",\"properties\":5}", "{}", .malformed_schema);
    try expectFail(
        "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"quaternion\"}}}",
        "{\"p\":1}",
        .malformed_schema,
    );
}

test "contract gate: checks run in cost order, so a bad name beats bad JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const verdict = try check(arena.allocator(), null, "{not json");
    switch (verdict) {
        .pass => return error.TestExpectedFailure,
        .fail => |f| try testing.expectEqual(FailureReason.undeclared_tool, f.reason),
    }
}

test "contract gate: every failure reason has a distinct stable label" {
    const reasons = [_]FailureReason{
        .undeclared_tool,  .args_not_json,        .args_not_object,
        .missing_required, .undeclared_parameter, .type_mismatch,
        .enum_violation,   .malformed_schema,
    };
    for (reasons, 0..) |a, i| {
        try testing.expect(reasonLabel(a).len > 0);
        for (reasons[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, reasonLabel(a), reasonLabel(b)));
        }
    }
}
