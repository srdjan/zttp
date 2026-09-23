//! The closed schema subset a tool catalog entry admits, and the validator that
//! checks a tool input against it without constructing a value.
//!
//! Three entry points, one per consumer:
//!
//! - `checkSubset` is what the build calls. It parses the schema text with
//!   duplicate-key refusal and returns one `SubsetRefusal` member per rule of
//!   the subset, with the JSON pointer of the offending schema node.
//! - `compile` accepts only bytes that `checkSubset` accepts and returns an
//!   owned tree that does not borrow the schema text.
//! - `validate` scans the input once with `std.json.Scanner` and checks each
//!   token against the compiled tree as it arrives. It refuses a duplicate or
//!   unknown key when it reads the key, before it scans the value, and it
//!   builds no object tree for the input.
//!
//! The subset is specified in docs/plans/2026-09-23-m4-t2-tool-catalog-design.md
//! section 3. `zttp:validate` is a different, wider surface and is not changed
//! by this file. This file imports `std` only, so it lives in `zts-base`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const JsonValue = std.json.Value;
const JsonObject = std.json.ObjectMap;

/// The maximum container nesting of a schema and of a value. The root object is
/// depth 1, and each nested object or array adds 1. Scalars add nothing.
pub const max_depth: u8 = 8;

/// The largest `maxInputBytes` a catalog entry may declare (1 MiB).
pub const max_input_bytes_ceiling: u32 = 1048576;

/// Why a schema is outside the closed subset. One member for each rule.
pub const SubsetRefusal = enum {
    /// The schema text is not one well-formed JSON document.
    invalid_json,
    /// An object in the schema text names the same key twice.
    duplicate_schema_key,
    /// The root is not a JSON object, or its `type` is not `"object"`.
    root_not_object,
    /// A keyword outside the subset, such as `$ref`, `oneOf`, or `pattern`.
    unknown_keyword,
    /// A schema node has no `type`.
    type_missing,
    /// `type` is not one string (a type array is refused).
    type_not_single_string,
    /// `type` names a type outside the subset, `"null"` among them.
    unsupported_type,
    /// An object schema has no `properties`.
    object_missing_properties,
    /// `additionalProperties` is absent or not literally `false`.
    object_not_closed,
    /// `required` is not an array of strings.
    required_not_array,
    /// A `required` name that `properties` does not declare.
    required_names_unknown_property,
    /// A `required` name that appears twice.
    required_duplicate,
    /// A string schema has no `maxLength`.
    string_missing_max_length,
    /// An array schema has no `items`.
    array_missing_items,
    /// An array schema has no `maxItems`.
    array_missing_max_items,
    /// A length or item bound is not a non-negative integer that fits `u32`.
    bound_not_integer,
    /// A minimum length or item bound is larger than its maximum.
    bound_inverted,
    /// `minimum` or `maximum` is not a finite JSON number.
    number_bound_not_finite_number,
    /// `minimum` is larger than `maximum`.
    number_bound_inverted,
    /// A keyword that does not apply to the node's type, or a keyword value of
    /// the wrong JSON type.
    keyword_wrong_type,
    /// `enum` holds no member.
    enum_empty,
    /// An `enum` member is not a value of the enclosing type.
    enum_member_wrong_type,
    /// Two `enum` members are equal.
    enum_duplicate,
    /// `format` is not one of `email`, `uuid`, `iso-date`, `iso-datetime`.
    format_unknown,
    /// Container nesting deeper than `max_depth`.
    too_deep,
};

/// The verdict of `checkSubset`. A refusal names the JSON pointer (RFC 6901
/// escaping) of the schema node or keyword that broke the rule; `""` is the
/// root. The path is allocated with the allocator given to `checkSubset`, and
/// the caller releases it with `deinit`.
pub const SubsetResult = union(enum) {
    ok,
    refused: Refused,

    pub const Refused = struct {
        reason: SubsetRefusal,
        path: []const u8,
    };

    pub fn deinit(self: SubsetResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .refused => |r| allocator.free(r.path),
        }
    }
};

/// Why an input does not match a compiled schema.
pub const ValidateRefusal = enum {
    /// The input is longer than the caller's byte bound. No byte was read.
    too_large,
    /// The input is not well-formed JSON (or not valid UTF-8).
    invalid_json,
    /// An object names the same key twice.
    duplicate_key,
    /// An object names a key its schema does not declare.
    unknown_field,
    /// An object closes without a key its schema requires.
    missing_required,
    /// A value of the wrong JSON type. `null` is always this.
    type_mismatch,
    /// A number outside the finite `f64` range, such as `1e400`.
    not_finite,
    /// An `integer` value that is not a whole number.
    not_integer,
    /// A number below `minimum`.
    below_minimum,
    /// A number above `maximum`.
    above_maximum,
    /// A string with fewer Unicode scalar values than `minLength`.
    string_too_short,
    /// A string with more Unicode scalar values than `maxLength`.
    string_too_long,
    /// An array with fewer items than `minItems`.
    array_too_short,
    /// An array with more items than `maxItems`.
    array_too_long,
    /// A value that is not one of the `enum` members.
    enum_mismatch,
    /// A string that does not match its `format`.
    format_mismatch,
    /// Container nesting deeper than `max_depth`.
    too_deep,
    /// Non-whitespace bytes after the root value.
    trailing_data,
};

/// The verdict of `validate`. `offset` is the byte offset into the input of
/// the token where the defect was found: the key for a duplicate or unknown
/// key, the closing brace for a missing required key, the value start for a
/// value defect, and the scanner position for malformed JSON.
pub const ValidateResult = union(enum) {
    ok,
    refused: Refused,

    pub const Refused = struct {
        reason: ValidateRefusal,
        offset: usize,
    };
};

/// The four string formats, with the spellings `zttp:validate` accepts.
pub const Format = enum {
    email,
    uuid,
    iso_date,
    iso_datetime,

    fn fromString(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "uuid")) return .uuid;
        if (std.mem.eql(u8, s, "iso-date")) return .iso_date;
        if (std.mem.eql(u8, s, "iso-datetime")) return .iso_datetime;
        return null;
    }
};

/// One node of a compiled schema.
pub const Node = union(enum) {
    object: ObjectNode,
    string: StringNode,
    number: NumberNode,
    boolean,
    array: ArrayNode,
};

pub const Property = struct {
    name: []const u8,
    required: bool,
    schema: *const Node,
};

pub const ObjectNode = struct {
    /// In the order the schema text declares them.
    properties: []const Property,
    /// The first index of this object's key-seen bits in the validator's
    /// scratch bit set. A node is open at most once at a time, because every
    /// node sits at one fixed depth, so each object owns a fixed range.
    slot_base: u32,
};

pub const StringNode = struct {
    min_length: u32,
    max_length: u32,
    format: ?Format,
    enum_values: ?[]const []const u8,
};

pub const NumberNode = struct {
    integer: bool,
    minimum: ?f64,
    maximum: ?f64,
    enum_values: ?[]const f64,
};

pub const ArrayNode = struct {
    items: *const Node,
    min_items: u32,
    max_items: u32,
};

/// A schema that passed `checkSubset`, as an owned tree. It holds its own
/// arena and does not borrow the schema text.
pub const CompiledToolSchema = struct {
    arena: *std.heap.ArenaAllocator,
    root: *const Node,
    /// The total number of object properties in the tree: the size of the
    /// key-seen bit set `validate` allocates.
    slot_count: u32,
    /// The `title` and `description` of the nodes that declare them. They
    /// constrain nothing, so `validate` ignores them, but they are what a
    /// reader of the schema is told about a field, and `canonicalize` keeps
    /// them.
    annotations: []const Annotation,

    pub fn deinit(self: *CompiledToolSchema) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

/// The descriptive keywords of one schema node.
pub const Annotation = struct {
    node: *const Node,
    title: ?[]const u8,
    description: ?[]const u8,
};

pub const CompileError = Allocator.Error || error{SchemaNotInSubset};

/// Check `schema_bytes` against the closed subset. Allocation failure is the
/// only Zig error; every schema defect is a `refused` result.
pub fn checkSubset(allocator: Allocator, schema_bytes: []const u8) Allocator.Error!SubsetResult {
    switch (try analyze(allocator, schema_bytes)) {
        .compiled => |c| {
            var compiled = c;
            compiled.deinit();
            return .ok;
        },
        .refused => |r| return .{ .refused = r },
    }
}

/// Compile `schema_bytes`. Returns `error.SchemaNotInSubset` exactly when
/// `checkSubset` would refuse the same bytes.
pub fn compile(allocator: Allocator, schema_bytes: []const u8) CompileError!CompiledToolSchema {
    switch (try analyze(allocator, schema_bytes)) {
        .compiled => |c| return c,
        .refused => |r| {
            allocator.free(r.path);
            return error.SchemaNotInSubset;
        },
    }
}

const Analysis = union(enum) {
    compiled: CompiledToolSchema,
    refused: SubsetResult.Refused,
};

fn analyze(allocator: Allocator, schema_bytes: []const u8) Allocator.Error!Analysis {
    const parsed = std.json.parseFromSlice(JsonValue, allocator, schema_bytes, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return refusedAtRoot(allocator, .duplicate_schema_key),
        else => return refusedAtRoot(allocator, .invalid_json),
    };
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |o| o,
        else => return refusedAtRoot(allocator, .root_not_object),
    };

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    var keep_arena = false;
    defer if (!keep_arena) {
        arena.deinit();
        allocator.destroy(arena);
    };

    var walker: Walker = .{ .gpa = allocator, .arena = arena.allocator() };
    defer walker.path.deinit(allocator);

    const root = walker.walkObjectNode(root_object, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = walker.refusal orelse unreachable },
    };
    keep_arena = true;
    return .{ .compiled = .{
        .arena = arena,
        .root = root,
        .slot_count = walker.slot_count,
        .annotations = try walker.annotations.toOwnedSlice(arena.allocator()),
    } };
}

fn refusedAtRoot(allocator: Allocator, reason: SubsetRefusal) Allocator.Error!Analysis {
    return .{ .refused = .{ .reason = reason, .path = try allocator.dupe(u8, "") } };
}

const Kind = enum {
    object,
    string,
    number,
    integer,
    boolean,
    array,

    fn fromString(s: []const u8) ?Kind {
        inline for (std.meta.fields(Kind)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    fn isContainer(self: Kind) bool {
        return self == .object or self == .array;
    }
};

const Keyword = enum {
    type,
    title,
    description,
    properties,
    additionalProperties,
    required,
    maxLength,
    minLength,
    @"enum",
    format,
    minimum,
    maximum,
    items,
    maxItems,
    minItems,

    fn fromString(s: []const u8) ?Keyword {
        inline for (std.meta.fields(Keyword)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    fn appliesTo(self: Keyword, kind: Kind) bool {
        return switch (self) {
            .type, .title, .description => true,
            .properties, .additionalProperties, .required => kind == .object,
            .maxLength, .minLength, .format => kind == .string,
            .@"enum" => kind == .string or kind == .number or kind == .integer,
            .minimum, .maximum => kind == .number or kind == .integer,
            .items, .maxItems, .minItems => kind == .array,
        };
    }
};

const WalkError = Allocator.Error || error{Refused};

const Walker = struct {
    gpa: Allocator,
    arena: Allocator,
    path: std.ArrayList(u8) = .empty,
    slot_count: u32 = 0,
    refusal: ?SubsetResult.Refused = null,
    /// Allocated in `arena`, so it needs no cleanup of its own.
    annotations: std.ArrayList(Annotation) = .empty,

    /// Record `reason` at the current path and unwind.
    fn refuse(w: *Walker, reason: SubsetRefusal) WalkError {
        w.refusal = .{ .reason = reason, .path = try w.gpa.dupe(u8, w.path.items) };
        return error.Refused;
    }

    /// Record `reason` at the current path extended by `segment`.
    fn refuseAt(w: *Walker, reason: SubsetRefusal, segment: []const u8) WalkError {
        _ = try w.push(segment);
        return w.refuse(reason);
    }

    fn refuseAtIndex(w: *Walker, reason: SubsetRefusal, segment: []const u8, index: usize) WalkError {
        _ = try w.push(segment);
        _ = try w.pushIndex(index);
        return w.refuse(reason);
    }

    /// Append one RFC 6901 segment and return the previous length.
    fn push(w: *Walker, segment: []const u8) Allocator.Error!usize {
        const mark = w.path.items.len;
        try w.path.append(w.gpa, '/');
        for (segment) |c| switch (c) {
            '~' => try w.path.appendSlice(w.gpa, "~0"),
            '/' => try w.path.appendSlice(w.gpa, "~1"),
            else => try w.path.append(w.gpa, c),
        };
        return mark;
    }

    fn pushIndex(w: *Walker, index: usize) Allocator.Error!usize {
        const mark = w.path.items.len;
        try w.path.print(w.gpa, "/{d}", .{index});
        return mark;
    }

    fn pop(w: *Walker, mark: usize) void {
        w.path.shrinkRetainingCapacity(mark);
    }

    /// Walk one schema node. `parent_depth` is the container depth of the
    /// enclosing node; the root passes 0.
    fn walkNode(w: *Walker, value: JsonValue, parent_depth: u8) WalkError!*const Node {
        const obj = switch (value) {
            .object => |o| o,
            else => return w.refuse(.keyword_wrong_type),
        };
        return w.walkObjectNode(obj, parent_depth);
    }

    fn walkObjectNode(w: *Walker, obj: JsonObject, parent_depth: u8) WalkError!*const Node {
        const type_value = obj.get("type") orelse {
            if (parent_depth == 0) return w.refuse(.root_not_object);
            return w.refuse(.type_missing);
        };
        const type_name = switch (type_value) {
            .string => |s| s,
            else => return w.refuseAt(.type_not_single_string, "type"),
        };
        const kind = Kind.fromString(type_name) orelse return w.refuseAt(.unsupported_type, "type");
        if (parent_depth == 0 and kind != .object) return w.refuseAt(.root_not_object, "type");

        const depth: u8 = if (kind.isContainer()) parent_depth + 1 else parent_depth;
        if (depth > max_depth) return w.refuse(.too_deep);

        var it = obj.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const keyword = Keyword.fromString(name) orelse return w.refuseAt(.unknown_keyword, name);
            if (!keyword.appliesTo(kind)) return w.refuseAt(.keyword_wrong_type, name);
            switch (keyword) {
                .title, .description => if (entry.value_ptr.* != .string) {
                    return w.refuseAt(.keyword_wrong_type, name);
                },
                else => {},
            }
        }

        const node = try w.arena.create(Node);
        node.* = switch (kind) {
            .object => .{ .object = try w.walkObject(obj, depth) },
            .string => .{ .string = try w.walkString(obj) },
            .number => .{ .number = try w.walkNumber(obj, false) },
            .integer => .{ .number = try w.walkNumber(obj, true) },
            .boolean => .boolean,
            .array => .{ .array = try w.walkArray(obj, depth) },
        };
        // The keyword loop above already refused a non-string title or
        // description, so each is a string here when present.
        const title: ?[]const u8 = if (obj.get("title")) |v| try w.arena.dupe(u8, v.string) else null;
        const description: ?[]const u8 = if (obj.get("description")) |v| try w.arena.dupe(u8, v.string) else null;
        if (title != null or description != null) {
            try w.annotations.append(w.arena, .{ .node = node, .title = title, .description = description });
        }
        return node;
    }

    fn walkObject(w: *Walker, obj: JsonObject, depth: u8) WalkError!ObjectNode {
        const props_value = obj.get("properties") orelse return w.refuse(.object_missing_properties);
        const props = switch (props_value) {
            .object => |o| o,
            else => return w.refuseAt(.keyword_wrong_type, "properties"),
        };
        const closed = obj.get("additionalProperties") orelse return w.refuse(.object_not_closed);
        switch (closed) {
            .bool => |b| if (b) return w.refuseAt(.object_not_closed, "additionalProperties"),
            else => return w.refuseAt(.object_not_closed, "additionalProperties"),
        }

        const count = props.count();
        const required = try w.arena.alloc(bool, count);
        @memset(required, false);
        if (obj.get("required")) |required_value| {
            const names = switch (required_value) {
                .array => |a| a,
                else => return w.refuseAt(.required_not_array, "required"),
            };
            for (names.items, 0..) |item, i| {
                const name = switch (item) {
                    .string => |s| s,
                    else => return w.refuseAtIndex(.required_not_array, "required", i),
                };
                const index = props.getIndex(name) orelse
                    return w.refuseAtIndex(.required_names_unknown_property, "required", i);
                if (required[index]) return w.refuseAtIndex(.required_duplicate, "required", i);
                required[index] = true;
            }
        }

        const slot_base = w.slot_count;
        w.slot_count += @intCast(count);

        const properties = try w.arena.alloc(Property, count);
        const props_mark = try w.push("properties");
        for (props.keys(), props.values(), 0..) |name, child, i| {
            const mark = try w.push(name);
            properties[i] = .{
                .name = try w.arena.dupe(u8, name),
                .required = required[i],
                .schema = try w.walkNode(child, depth),
            };
            w.pop(mark);
        }
        w.pop(props_mark);
        return .{ .properties = properties, .slot_base = slot_base };
    }

    fn walkString(w: *Walker, obj: JsonObject) WalkError!StringNode {
        const max_value = obj.get("maxLength") orelse return w.refuse(.string_missing_max_length);
        const max_length = try w.bound(max_value, "maxLength");
        const min_length: u32 = if (obj.get("minLength")) |v| try w.bound(v, "minLength") else 0;
        if (min_length > max_length) return w.refuseAt(.bound_inverted, "minLength");

        var format: ?Format = null;
        if (obj.get("format")) |v| {
            const name = switch (v) {
                .string => |s| s,
                else => return w.refuseAt(.keyword_wrong_type, "format"),
            };
            format = Format.fromString(name) orelse return w.refuseAt(.format_unknown, "format");
        }

        var enum_values: ?[]const []const u8 = null;
        if (obj.get("enum")) |v| {
            const members = try w.enumArray(v);
            const out = try w.arena.alloc([]const u8, members.len);
            for (members, 0..) |member, i| {
                const s = switch (member) {
                    .string => |s| s,
                    else => return w.refuseAtIndex(.enum_member_wrong_type, "enum", i),
                };
                for (out[0..i]) |prior| {
                    if (std.mem.eql(u8, prior, s)) return w.refuseAtIndex(.enum_duplicate, "enum", i);
                }
                out[i] = try w.arena.dupe(u8, s);
            }
            enum_values = out;
        }

        return .{
            .min_length = min_length,
            .max_length = max_length,
            .format = format,
            .enum_values = enum_values,
        };
    }

    fn walkNumber(w: *Walker, obj: JsonObject, integer: bool) WalkError!NumberNode {
        const minimum: ?f64 = if (obj.get("minimum")) |v| try w.numberBound(v, "minimum") else null;
        const maximum: ?f64 = if (obj.get("maximum")) |v| try w.numberBound(v, "maximum") else null;
        if (minimum) |lo| if (maximum) |hi| if (lo > hi) return w.refuseAt(.number_bound_inverted, "minimum");

        var enum_values: ?[]const f64 = null;
        if (obj.get("enum")) |v| {
            const members = try w.enumArray(v);
            const out = try w.arena.alloc(f64, members.len);
            for (members, 0..) |member, i| {
                const n = finiteNumber(member) orelse
                    return w.refuseAtIndex(.enum_member_wrong_type, "enum", i);
                if (integer and @floor(n) != n) return w.refuseAtIndex(.enum_member_wrong_type, "enum", i);
                for (out[0..i]) |prior| {
                    if (prior == n) return w.refuseAtIndex(.enum_duplicate, "enum", i);
                }
                out[i] = n;
            }
            enum_values = out;
        }

        return .{ .integer = integer, .minimum = minimum, .maximum = maximum, .enum_values = enum_values };
    }

    fn walkArray(w: *Walker, obj: JsonObject, depth: u8) WalkError!ArrayNode {
        const items_value = obj.get("items") orelse return w.refuse(.array_missing_items);
        const max_value = obj.get("maxItems") orelse return w.refuse(.array_missing_max_items);
        const max_items = try w.bound(max_value, "maxItems");
        const min_items: u32 = if (obj.get("minItems")) |v| try w.bound(v, "minItems") else 0;
        if (min_items > max_items) return w.refuseAt(.bound_inverted, "minItems");

        const mark = try w.push("items");
        const items = try w.walkNode(items_value, depth);
        w.pop(mark);
        return .{ .items = items, .min_items = min_items, .max_items = max_items };
    }

    fn enumArray(w: *Walker, value: JsonValue) WalkError![]const JsonValue {
        const members = switch (value) {
            .array => |a| a.items,
            else => return w.refuseAt(.keyword_wrong_type, "enum"),
        };
        if (members.len == 0) return w.refuseAt(.enum_empty, "enum");
        return members;
    }

    /// A length or item bound: a JSON number written as a non-negative
    /// integer that fits `u32`.
    fn bound(w: *Walker, value: JsonValue, keyword: []const u8) WalkError!u32 {
        const text = switch (value) {
            .number_string => |s| s,
            else => return w.refuseAt(.bound_not_integer, keyword),
        };
        return std.fmt.parseInt(u32, text, 10) catch return w.refuseAt(.bound_not_integer, keyword);
    }

    fn numberBound(w: *Walker, value: JsonValue, keyword: []const u8) WalkError!f64 {
        return finiteNumber(value) orelse return w.refuseAt(.number_bound_not_finite_number, keyword);
    }
};

/// The finite `f64` a JSON number denotes, or null for a non-number or a
/// number outside the finite range.
fn finiteNumber(value: JsonValue) ?f64 {
    const text = switch (value) {
        .number_string => |s| s,
        else => return null,
    };
    const n = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(n)) return null;
    return n;
}

// ---------------------------------------------------------------------------
// Canonical form
// ---------------------------------------------------------------------------

/// Write `compiled` back out as the one canonical schema text for its meaning,
/// so authored whitespace, key order, and set order cannot move a digest (P4).
///
/// The rules, which docs/consumer-contract.md states for a reader who must
/// reproduce them without this code:
/// - no whitespace; strings are JSON-escaped (`"`, `\`, and control bytes
///   below 0x20 escaped, `\u00XX` for those without a short escape) and every
///   other byte is written as it is;
/// - keys per node in this order: `type`, `title`, `description`, then
///   object: `additionalProperties`, `properties`, `required`;
///   string: `minLength`, `maxLength`, `format`, `enum`;
///   number and integer: `minimum`, `maximum`, `enum`;
///   array: `items`, `maxItems`, `minItems`;
/// - `title` and `description` only when declared; `minLength` and `minItems`
///   only when not 0; `format`, `minimum`, `maximum`, and `enum` only when
///   declared; `required` always, possibly empty;
/// - `properties` sorted by name bytes, `required` sorted by name bytes, string
///   `enum` members sorted by bytes, number `enum` members sorted ascending;
/// - a number that is a whole value of magnitude below 2^53 is written as an
///   integer; any other is written in the shortest decimal form that reads
///   back to the same f64.
pub fn canonicalize(allocator: Allocator, compiled: *const CompiledToolSchema) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    canonicalNode(allocator, &out.writer, compiled, compiled.root) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const CanonicalError = std.Io.Writer.Error || Allocator.Error;

fn canonicalNode(allocator: Allocator, w: *std.Io.Writer, compiled: *const CompiledToolSchema, node: *const Node) CanonicalError!void {
    const type_name: []const u8 = switch (node.*) {
        .object => "object",
        .string => "string",
        .number => |n| if (n.integer) "integer" else "number",
        .boolean => "boolean",
        .array => "array",
    };
    try w.writeAll("{\"type\":");
    try canonicalString(w, type_name);
    for (compiled.annotations) |a| {
        if (a.node != node) continue;
        if (a.title) |t| {
            try w.writeAll(",\"title\":");
            try canonicalString(w, t);
        }
        if (a.description) |d| {
            try w.writeAll(",\"description\":");
            try canonicalString(w, d);
        }
        break;
    }
    switch (node.*) {
        .object => |o| {
            const order = try allocator.alloc(usize, o.properties.len);
            defer allocator.free(order);
            for (order, 0..) |*slot, i| slot.* = i;
            std.mem.sort(usize, order, o.properties, propertyNameLess);
            try w.writeAll(",\"additionalProperties\":false,\"properties\":{");
            for (order, 0..) |index, k| {
                if (k > 0) try w.writeByte(',');
                try canonicalString(w, o.properties[index].name);
                try w.writeByte(':');
                try canonicalNode(allocator, w, compiled, o.properties[index].schema);
            }
            try w.writeAll("},\"required\":[");
            var first = true;
            for (order) |index| {
                if (!o.properties[index].required) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try canonicalString(w, o.properties[index].name);
            }
            try w.writeByte(']');
        },
        .string => |s| {
            if (s.min_length != 0) try w.print(",\"minLength\":{d}", .{s.min_length});
            try w.print(",\"maxLength\":{d}", .{s.max_length});
            if (s.format) |f| {
                try w.writeAll(",\"format\":");
                try canonicalString(w, switch (f) {
                    .email => "email",
                    .uuid => "uuid",
                    .iso_date => "iso-date",
                    .iso_datetime => "iso-datetime",
                });
            }
            if (s.enum_values) |members| {
                const sorted = try allocator.dupe([]const u8, members);
                defer allocator.free(sorted);
                std.mem.sort([]const u8, sorted, {}, bytesLess);
                try w.writeAll(",\"enum\":[");
                for (sorted, 0..) |m, k| {
                    if (k > 0) try w.writeByte(',');
                    try canonicalString(w, m);
                }
                try w.writeByte(']');
            }
        },
        .number => |n| {
            if (n.minimum) |lo| {
                try w.writeAll(",\"minimum\":");
                try canonicalNumber(w, lo);
            }
            if (n.maximum) |hi| {
                try w.writeAll(",\"maximum\":");
                try canonicalNumber(w, hi);
            }
            if (n.enum_values) |members| {
                const sorted = try allocator.dupe(f64, members);
                defer allocator.free(sorted);
                std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
                try w.writeAll(",\"enum\":[");
                for (sorted, 0..) |m, k| {
                    if (k > 0) try w.writeByte(',');
                    try canonicalNumber(w, m);
                }
                try w.writeByte(']');
            }
        },
        .boolean => {},
        .array => |a| {
            try w.writeAll(",\"items\":");
            try canonicalNode(allocator, w, compiled, a.items);
            try w.print(",\"maxItems\":{d}", .{a.max_items});
            if (a.min_items != 0) try w.print(",\"minItems\":{d}", .{a.min_items});
        },
    }
    try w.writeByte('}');
}

fn propertyNameLess(properties: []const Property, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, properties[a].name, properties[b].name);
}

fn bytesLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn canonicalString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn canonicalNumber(w: *std.Io.Writer, n: f64) std.Io.Writer.Error!void {
    const limit: f64 = 9007199254740992.0; // 2^53
    if (@floor(n) == n and @abs(n) < limit) {
        // -0 is whole and writes as 0, which reads back as the same bound.
        const whole: i64 = @intFromFloat(n);
        return w.print("{d}", .{whole});
    }
    return w.print("{d}", .{n});
}

// ---------------------------------------------------------------------------
// Streaming validation
// ---------------------------------------------------------------------------

/// Validate `input` against `compiled` in one forward pass.
///
/// `scratch` holds the scanner's nesting stack, one key-seen bit per schema
/// property, and a decoded copy of a string token only when that token holds
/// an escape. Its failure is the only Zig error; it is never reported as `ok`.
/// An input longer than `max_bytes` is refused before any byte is read.
pub fn validate(
    scratch: Allocator,
    compiled: *const CompiledToolSchema,
    input: []const u8,
    max_bytes: u32,
) Allocator.Error!ValidateResult {
    if (input.len > max_bytes) return refusal(.too_large, 0);

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(scratch, compiled.slot_count);
    defer seen.deinit(scratch);
    var scanner = Scanner.initCompleteInput(scratch, input);
    defer scanner.deinit();

    const Frame = struct { node: *const Node, items: u32 };
    var frames: [max_depth]Frame = undefined;
    var depth: usize = 0;
    var pending: ?*const Node = compiled.root;

    while (true) {
        if (pending) |node| {
            pending = null;
            const token_type = scanner.peekNextTokenType() catch return refusal(.invalid_json, scanner.cursor);
            const at = scanner.cursor;
            switch (token_type) {
                .object_begin, .array_begin => {
                    if (depth == max_depth) return refusal(.too_deep, at);
                    const matches = if (token_type == .object_begin) node.* == .object else node.* == .array;
                    if (!matches) return refusal(.type_mismatch, at);
                    _ = scanner.next() catch |err| return scanFailure(err, &scanner);
                    switch (node.*) {
                        .object => |o| seen.setRangeValue(.{
                            .start = o.slot_base,
                            .end = o.slot_base + o.properties.len,
                        }, false),
                        else => {},
                    }
                    frames[depth] = .{ .node = node, .items = 0 };
                    depth += 1;
                },
                .true, .false => {
                    if (node.* != .boolean) return refusal(.type_mismatch, at);
                    _ = scanner.next() catch |err| return scanFailure(err, &scanner);
                },
                .number => {
                    const spec = switch (node.*) {
                        .number => |n| n,
                        else => return refusal(.type_mismatch, at),
                    };
                    const token = scanner.nextAllocMax(scratch, .alloc_if_needed, input.len) catch |err|
                        return allocFailure(err, &scanner);
                    defer freeToken(scratch, token);
                    const text = switch (token) {
                        .number, .string => |s| s,
                        .allocated_number, .allocated_string => |s| s,
                        else => return refusal(.invalid_json, at),
                    };
                    if (checkNumber(spec, text)) |reason| return refusal(reason, at);
                },
                .string => {
                    const spec = switch (node.*) {
                        .string => |s| s,
                        else => return refusal(.type_mismatch, at),
                    };
                    const token = scanner.nextAllocMax(scratch, .alloc_if_needed, input.len) catch |err|
                        return allocFailure(err, &scanner);
                    defer freeToken(scratch, token);
                    const text = switch (token) {
                        .number, .string => |s| s,
                        .allocated_number, .allocated_string => |s| s,
                        else => return refusal(.invalid_json, at),
                    };
                    if (checkString(spec, text)) |reason| return refusal(reason, at);
                },
                .null => return refusal(.type_mismatch, at),
                .object_end, .array_end, .end_of_document => return refusal(.invalid_json, at),
            }
            continue;
        }

        if (depth == 0) {
            var i = scanner.cursor;
            while (i < input.len and isJsonWhitespace(input[i])) : (i += 1) {}
            if (i < input.len) return refusal(.trailing_data, i);
            return .ok;
        }

        const frame = &frames[depth - 1];
        const token_type = scanner.peekNextTokenType() catch return refusal(.invalid_json, scanner.cursor);
        const at = scanner.cursor;
        switch (frame.node.*) {
            .object => |o| switch (token_type) {
                .object_end => {
                    for (o.properties, 0..) |prop, i| {
                        if (prop.required and !seen.isSet(o.slot_base + i)) return refusal(.missing_required, at);
                    }
                    _ = scanner.next() catch |err| return scanFailure(err, &scanner);
                    depth -= 1;
                },
                .string => {
                    const token = scanner.nextAllocMax(scratch, .alloc_if_needed, input.len) catch |err|
                        return allocFailure(err, &scanner);
                    defer freeToken(scratch, token);
                    const key = switch (token) {
                        .number, .string => |s| s,
                        .allocated_number, .allocated_string => |s| s,
                        else => return refusal(.invalid_json, at),
                    };
                    const index = findProperty(o.properties, key) orelse return refusal(.unknown_field, at);
                    const slot = o.slot_base + index;
                    if (seen.isSet(slot)) return refusal(.duplicate_key, at);
                    seen.set(slot);
                    pending = o.properties[index].schema;
                },
                else => return refusal(.invalid_json, at),
            },
            .array => |a| switch (token_type) {
                .array_end => {
                    if (frame.items < a.min_items) return refusal(.array_too_short, at);
                    _ = scanner.next() catch |err| return scanFailure(err, &scanner);
                    depth -= 1;
                },
                else => {
                    if (frame.items >= a.max_items) return refusal(.array_too_long, at);
                    frame.items += 1;
                    pending = a.items;
                },
            },
            else => unreachable,
        }
    }
}

fn refusal(reason: ValidateRefusal, offset: usize) ValidateResult {
    return .{ .refused = .{ .reason = reason, .offset = offset } };
}

fn scanFailure(err: Scanner.NextError, scanner: *const Scanner) Allocator.Error!ValidateResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => refusal(.invalid_json, scanner.cursor),
    };
}

fn allocFailure(err: Scanner.AllocError, scanner: *const Scanner) Allocator.Error!ValidateResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // `max_value_len` is the input length, so no token can exceed it.
        error.SyntaxError, error.UnexpectedEndOfInput, error.ValueTooLong => refusal(.invalid_json, scanner.cursor),
    };
}

fn freeToken(allocator: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

fn findProperty(properties: []const Property, key: []const u8) ?usize {
    for (properties, 0..) |prop, i| {
        if (std.mem.eql(u8, prop.name, key)) return i;
    }
    return null;
}

fn isJsonWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn checkNumber(spec: NumberNode, text: []const u8) ?ValidateRefusal {
    const n = std.fmt.parseFloat(f64, text) catch return .invalid_json;
    if (!std.math.isFinite(n)) return .not_finite;
    if (spec.integer and @floor(n) != n) return .not_integer;
    if (spec.minimum) |lo| if (n < lo) return .below_minimum;
    if (spec.maximum) |hi| if (n > hi) return .above_maximum;
    if (spec.enum_values) |members| {
        for (members) |m| {
            if (m == n) return null;
        }
        return .enum_mismatch;
    }
    return null;
}

/// `text` is the decoded string. The scanner guarantees valid UTF-8 and
/// decodes a surrogate-pair escape to one scalar value.
fn checkString(spec: StringNode, text: []const u8) ?ValidateRefusal {
    const length = std.unicode.utf8CountCodepoints(text) catch return .invalid_json;
    if (length < spec.min_length) return .string_too_short;
    if (length > spec.max_length) return .string_too_long;
    if (spec.format) |f| {
        if (!matchesFormat(f, text)) return .format_mismatch;
    }
    if (spec.enum_values) |members| {
        for (members) |m| {
            if (std.mem.eql(u8, m, text)) return null;
        }
        return .enum_mismatch;
    }
    return null;
}

// The format rules below are copied from packages/modules/src/security/validate.zig
// so that `zts-base` imports nothing but `std`. Keep them in step.

fn matchesFormat(format: Format, str: []const u8) bool {
    return switch (format) {
        .email => isEmail(str),
        .uuid => isUuid(str),
        .iso_date => isIsoDate(str),
        .iso_datetime => isIsoDatetime(str),
    };
}

fn isEmail(str: []const u8) bool {
    var at_index: ?usize = null;
    for (str, 0..) |c, i| {
        if (c == '@') {
            if (at_index != null) return false;
            at_index = i;
        }
    }
    const at = at_index orelse return false;
    if (at == 0) return false;
    const domain = str[at + 1 ..];
    if (domain.len == 0) return false;
    return std.mem.indexOfScalar(u8, domain, '.') != null;
}

fn isUuid(str: []const u8) bool {
    if (str.len != 36) return false;
    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isIsoDate(str: []const u8) bool {
    if (str.len != 10) return false;
    if (!(isDigit(str[0]) and isDigit(str[1]) and isDigit(str[2]) and isDigit(str[3]) and
        str[4] == '-' and
        isDigit(str[5]) and isDigit(str[6]) and
        str[7] == '-' and
        isDigit(str[8]) and isDigit(str[9]))) return false;
    const year = std.fmt.parseInt(u16, str[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, str[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, str[8..10], 10) catch return false;
    if (month < 1 or month > 12 or day < 1) return false;
    return day <= daysInMonth(year, month);
}

fn isIsoDatetime(str: []const u8) bool {
    if (str.len < 19) return false;
    if (!isIsoDate(str[0..10])) return false;
    if (str[10] != 'T') return false;
    if (!isDigit(str[11]) or !isDigit(str[12])) return false;
    if (str[13] != ':') return false;
    if (!isDigit(str[14]) or !isDigit(str[15])) return false;
    if (str[16] != ':') return false;
    if (!isDigit(str[17]) or !isDigit(str[18])) return false;
    const hour = std.fmt.parseInt(u8, str[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, str[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, str[17..19], 10) catch return false;
    if (hour > 23 or minute > 59 or second > 59) return false;
    return isIsoTimeSuffix(str[19..]);
}

/// An optional `.` and digits, then optionally `Z`/`z` or `(+|-)HH:MM` /
/// `(+|-)HHMM`, then the end of the string.
fn isIsoTimeSuffix(suffix: []const u8) bool {
    var rest = suffix;
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and isDigit(rest[i])) : (i += 1) {}
        if (i == 1) return false;
        rest = rest[i..];
    }
    if (rest.len == 0) return true;
    if (rest[0] == 'Z' or rest[0] == 'z') return rest.len == 1;
    if (rest[0] != '+' and rest[0] != '-') return false;
    if (rest.len == 6) {
        return isDigit(rest[1]) and isDigit(rest[2]) and rest[3] == ':' and
            isDigit(rest[4]) and isDigit(rest[5]);
    }
    if (rest.len == 5) {
        return isDigit(rest[1]) and isDigit(rest[2]) and
            isDigit(rest[3]) and isDigit(rest[4]);
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `levels` closed objects nested through a property `a`, with `inner` as the
/// innermost `a`.
fn nestSchema(comptime levels: usize, comptime inner: []const u8) []const u8 {
    comptime var s: []const u8 = inner;
    inline for (0..levels) |_| {
        s = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"a\":" ++ s ++ "}}";
    }
    return s;
}

fn nestInput(comptime levels: usize, comptime inner: []const u8) []const u8 {
    comptime var s: []const u8 = inner;
    inline for (0..levels) |_| s = "{\"a\":" ++ s ++ "}";
    return s;
}

/// Wrap `props` as the `properties` of a closed root object.
fn rootWith(comptime props: []const u8) []const u8 {
    return "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ props ++ "}}";
}

const full_schema =
    \\{"type":"object","title":"order","description":"one order",
    \\ "additionalProperties":false,
    \\ "required":["name","count"],
    \\ "properties":{
    \\  "name":{"type":"string","minLength":1,"maxLength":8},
    \\  "kind":{"type":"string","maxLength":10,"enum":["a","b"]},
    \\  "email":{"type":"string","maxLength":64,"format":"email"},
    \\  "when":{"type":"string","maxLength":40,"format":"iso-datetime"},
    \\  "score":{"type":"number","minimum":0,"maximum":1.5},
    \\  "count":{"type":"integer","minimum":0,"maximum":10,"enum":[1,2,3]},
    \\  "flag":{"type":"boolean","description":"on or off"},
    \\  "tags":{"type":"array","minItems":1,"maxItems":3,"items":{"type":"string","maxLength":4}},
    \\  "nested":{"type":"object","additionalProperties":false,"properties":{"x":{"type":"integer"}}}
    \\ }}
;

const SubsetCase = struct {
    schema: []const u8,
    reason: SubsetRefusal,
    path: []const u8,
};

const str1 = "{\"type\":\"string\",\"maxLength\":1}";

const subset_cases = [_]SubsetCase{
    .{ .schema = "{\"type\":", .reason = .invalid_json, .path = "" },
    .{ .schema = rootWith("") ++ " x", .reason = .invalid_json, .path = "" },
    .{ .schema = "{\"type\":\"object\",\"type\":\"object\"}", .reason = .duplicate_schema_key, .path = "" },
    .{ .schema = rootWith("\"a\":" ++ str1 ++ ",\"a\":" ++ str1), .reason = .duplicate_schema_key, .path = "" },
    .{ .schema = "[1]", .reason = .root_not_object, .path = "" },
    .{ .schema = str1, .reason = .root_not_object, .path = "/type" },
    .{ .schema = "{\"properties\":{},\"additionalProperties\":false}", .reason = .root_not_object, .path = "" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"$ref\":\"#\"}", .reason = .unknown_keyword, .path = "/$ref" },
    .{ .schema = rootWith("\"a\":{\"oneOf\":[],\"type\":\"string\",\"maxLength\":1}"), .reason = .unknown_keyword, .path = "/properties/a/oneOf" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"pattern\":\"x\"}"), .reason = .unknown_keyword, .path = "/properties/a/pattern" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"const\":\"x\"}"), .reason = .unknown_keyword, .path = "/properties/a/const" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"maxItems\":1,\"items\":" ++ str1 ++ ",\"prefixItems\":[]}"), .reason = .unknown_keyword, .path = "/properties/a/prefixItems" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"anyOf\":[]}"), .reason = .unknown_keyword, .path = "/properties/a/anyOf" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"allOf\":[]}"), .reason = .unknown_keyword, .path = "/properties/a/allOf" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"not\":{}}"), .reason = .unknown_keyword, .path = "/properties/a/not" },
    .{ .schema = rootWith("\"a\":{\"maxLength\":1}"), .reason = .type_missing, .path = "/properties/a" },
    .{ .schema = rootWith("\"a\":{\"type\":[\"string\",\"null\"],\"maxLength\":1}"), .reason = .type_not_single_string, .path = "/properties/a/type" },
    .{ .schema = rootWith("\"a\":{\"type\":\"null\"}"), .reason = .unsupported_type, .path = "/properties/a/type" },
    .{ .schema = rootWith("\"a\":{\"type\":\"date\"}"), .reason = .unsupported_type, .path = "/properties/a/type" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false}", .reason = .object_missing_properties, .path = "" },
    .{ .schema = "{\"type\":\"object\",\"properties\":{}}", .reason = .object_not_closed, .path = "" },
    .{ .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":true}", .reason = .object_not_closed, .path = "/additionalProperties" },
    .{ .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":{}}", .reason = .object_not_closed, .path = "/additionalProperties" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"a\":" ++ str1 ++ "},\"required\":\"a\"}", .reason = .required_not_array, .path = "/required" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"a\":" ++ str1 ++ "},\"required\":[1]}", .reason = .required_not_array, .path = "/required/0" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"a\":" ++ str1 ++ "},\"required\":[\"a\",\"b\"]}", .reason = .required_names_unknown_property, .path = "/required/1" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"a\":" ++ str1 ++ "},\"required\":[\"a\",\"a\"]}", .reason = .required_duplicate, .path = "/required/1" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\"}"), .reason = .string_missing_max_length, .path = "/properties/a" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"maxItems\":1}"), .reason = .array_missing_items, .path = "/properties/a" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"items\":{\"type\":\"boolean\"}}"), .reason = .array_missing_max_items, .path = "/properties/a" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1.5}"), .reason = .bound_not_integer, .path = "/properties/a/maxLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":-1}"), .reason = .bound_not_integer, .path = "/properties/a/maxLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":4294967296}"), .reason = .bound_not_integer, .path = "/properties/a/maxLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":\"3\"}"), .reason = .bound_not_integer, .path = "/properties/a/maxLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"maxItems\":2,\"minItems\":1e0,\"items\":" ++ str1 ++ "}"), .reason = .bound_not_integer, .path = "/properties/a/minItems" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"minLength\":3,\"maxLength\":2}"), .reason = .bound_inverted, .path = "/properties/a/minLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"minItems\":3,\"maxItems\":2,\"items\":" ++ str1 ++ "}"), .reason = .bound_inverted, .path = "/properties/a/minItems" },
    .{ .schema = rootWith("\"a\":{\"type\":\"number\",\"minimum\":1e400}"), .reason = .number_bound_not_finite_number, .path = "/properties/a/minimum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"integer\",\"maximum\":\"5\"}"), .reason = .number_bound_not_finite_number, .path = "/properties/a/maximum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"number\",\"minimum\":2,\"maximum\":1}"), .reason = .number_bound_inverted, .path = "/properties/a/minimum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"number\",\"maxLength\":3}"), .reason = .keyword_wrong_type, .path = "/properties/a/maxLength" },
    .{ .schema = rootWith("\"a\":{\"type\":\"boolean\",\"enum\":[true]}"), .reason = .keyword_wrong_type, .path = "/properties/a/enum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"title\":5}"), .reason = .keyword_wrong_type, .path = "/properties/a/title" },
    .{ .schema = rootWith("\"a\":{\"type\":\"array\",\"maxItems\":1,\"items\":[" ++ str1 ++ "]}"), .reason = .keyword_wrong_type, .path = "/properties/a/items" },
    .{ .schema = rootWith("\"a\":5"), .reason = .keyword_wrong_type, .path = "/properties/a" },
    .{ .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":[]}", .reason = .keyword_wrong_type, .path = "/properties" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"format\":1}"), .reason = .keyword_wrong_type, .path = "/properties/a/format" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"enum\":\"x\"}"), .reason = .keyword_wrong_type, .path = "/properties/a/enum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[]}"), .reason = .enum_empty, .path = "/properties/a/enum" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"x\",1]}"), .reason = .enum_member_wrong_type, .path = "/properties/a/enum/1" },
    .{ .schema = rootWith("\"a\":{\"type\":\"integer\",\"enum\":[1,1.5]}"), .reason = .enum_member_wrong_type, .path = "/properties/a/enum/1" },
    .{ .schema = rootWith("\"a\":{\"type\":\"number\",\"enum\":[null]}"), .reason = .enum_member_wrong_type, .path = "/properties/a/enum/0" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"x\",\"x\"]}"), .reason = .enum_duplicate, .path = "/properties/a/enum/1" },
    .{ .schema = rootWith("\"a\":{\"type\":\"number\",\"enum\":[1,1.0]}"), .reason = .enum_duplicate, .path = "/properties/a/enum/1" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"format\":\"ipv4\"}"), .reason = .format_unknown, .path = "/properties/a/format" },
    .{ .schema = rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"format\":\"date\"}"), .reason = .format_unknown, .path = "/properties/a/format" },
    .{ .schema = nestSchema(9, str1), .reason = .too_deep, .path = "/properties/a/properties/a/properties/a/properties/a/properties/a/properties/a/properties/a/properties/a" },
    .{
        .schema = rootWith("\"a\":" ++ nestArray(8, "{\"type\":\"boolean\"}")),
        .reason = .too_deep,
        .path = "/properties/a/items/items/items/items/items/items/items",
    },
    .{ .schema = rootWith("\"a/b~c\":{\"type\":\"string\"}"), .reason = .string_missing_max_length, .path = "/properties/a~1b~0c" },
};

fn nestArray(comptime levels: usize, comptime inner: []const u8) []const u8 {
    comptime var s: []const u8 = inner;
    inline for (0..levels) |_| s = "{\"type\":\"array\",\"maxItems\":1,\"items\":" ++ s ++ "}";
    return s;
}

const ValidateCase = struct {
    schema: []const u8 = full_schema,
    input: []const u8,
    max_bytes: u32 = max_input_bytes_ceiling,
    reason: ValidateRefusal,
    offset: usize,
};

const deep_schema = nestSchema(8, str1);

const validate_cases = [_]ValidateCase{
    .{ .input = "{\"name\":\"a\",\"count\":1}", .max_bytes = 21, .reason = .too_large, .offset = 0 },
    .{ .input = "{\"name\":", .reason = .invalid_json, .offset = 8 },
    .{ .input = "", .reason = .invalid_json, .offset = 0 },
    .{ .input = "{\"name\":\"a\",\"count\":1,}", .reason = .invalid_json, .offset = 22 },
    .{ .input = "{\"name\":\"\xff\",\"count\":1}", .reason = .invalid_json, .offset = 9 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"name\":\"b\"}", .reason = .duplicate_key, .offset = 22 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"nested\":{\"x\":1,\"x\":2}}", .reason = .duplicate_key, .offset = 38 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"name\":{bad", .reason = .duplicate_key, .offset = 22 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"nested\":{\"x\":1,\"x\":[[[", .reason = .duplicate_key, .offset = 38 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"zzz\":1}", .reason = .unknown_field, .offset = 22 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"zzz\":{bad", .reason = .unknown_field, .offset = 22 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"nested\":{\"y\":1}}", .reason = .unknown_field, .offset = 32 },
    .{ .input = "{\"name\":\"a\"}", .reason = .missing_required, .offset = 11 },
    .{ .input = "{\"name\":5,\"count\":1}", .reason = .type_mismatch, .offset = 8 },
    .{ .input = "{\"name\":null,\"count\":1}", .reason = .type_mismatch, .offset = 8 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"flag\":null}", .reason = .type_mismatch, .offset = 29 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"flag\":\"true\"}", .reason = .type_mismatch, .offset = 29 },
    .{ .input = "[]", .reason = .type_mismatch, .offset = 0 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"score\":1e400}", .reason = .not_finite, .offset = 30 },
    .{ .input = "{\"name\":\"a\",\"count\":1.5}", .reason = .not_integer, .offset = 20 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"score\":-0.5}", .reason = .below_minimum, .offset = 30 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"score\":2}", .reason = .above_maximum, .offset = 30 },
    .{ .input = "{\"name\":\"\",\"count\":1}", .reason = .string_too_short, .offset = 8 },
    .{ .input = "{\"name\":\"abcdefghi\",\"count\":1}", .reason = .string_too_long, .offset = 8 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"tags\":[]}", .reason = .array_too_short, .offset = 30 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"tags\":[\"a\",\"b\",\"c\",\"d\"]}", .reason = .array_too_long, .offset = 42 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"kind\":\"c\"}", .reason = .enum_mismatch, .offset = 29 },
    .{ .input = "{\"name\":\"a\",\"count\":4}", .reason = .enum_mismatch, .offset = 20 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"email\":\"nope\"}", .reason = .format_mismatch, .offset = 30 },
    .{ .input = "{\"name\":\"a\",\"count\":1,\"when\":\"2026-02-30T00:00:00Z\"}", .reason = .format_mismatch, .offset = 29 },
    .{ .schema = deep_schema, .input = nestInput(8, "{}"), .reason = .too_deep, .offset = 40 },
    .{ .input = "{\"name\":\"a\",\"count\":1} x", .reason = .trailing_data, .offset = 23 },
    .{ .input = "{\"name\":\"a\",\"count\":1}{}", .reason = .trailing_data, .offset = 22 },
};

fn expectSubset(case: SubsetCase) !void {
    const result = try checkSubset(testing.allocator, case.schema);
    defer result.deinit(testing.allocator);
    switch (result) {
        .ok => {
            std.debug.print("schema accepted, expected {s}: {s}\n", .{ @tagName(case.reason), case.schema });
            return error.TestExpectedRefusal;
        },
        .refused => |r| {
            if (r.reason != case.reason or !std.mem.eql(u8, r.path, case.path)) {
                std.debug.print("schema {s}\n  expected {s} at \"{s}\", got {s} at \"{s}\"\n", .{
                    case.schema, @tagName(case.reason), case.path, @tagName(r.reason), r.path,
                });
                return error.TestUnexpectedRefusal;
            }
        },
    }
}

fn validateBytes(schema: []const u8, input: []const u8, max_bytes: u32) !ValidateResult {
    var compiled = try compile(testing.allocator, schema);
    defer compiled.deinit();
    return validate(testing.allocator, &compiled, input, max_bytes);
}

fn expectRefused(result: ValidateResult, reason: ValidateRefusal, offset: usize) !void {
    try testing.expectEqualDeep(ValidateResult{ .refused = .{ .reason = reason, .offset = offset } }, result);
}

test "checkSubset accepts a schema that uses every construct" {
    const result = try checkSubset(testing.allocator, full_schema);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(SubsetResult.ok, result);

    const at_depth = try checkSubset(testing.allocator, deep_schema);
    defer at_depth.deinit(testing.allocator);
    try testing.expectEqual(SubsetResult.ok, at_depth);
}

test "checkSubset refuses each subset rule with its reason and path" {
    for (subset_cases) |case| try expectSubset(case);
}

test "compile refuses exactly what checkSubset refuses" {
    for (subset_cases) |case| {
        try testing.expectError(error.SchemaNotInSubset, compile(testing.allocator, case.schema));
    }
    var compiled = try compile(testing.allocator, full_schema);
    compiled.deinit();
}

test "compiled schema does not borrow the schema text" {
    const copy = try testing.allocator.dupe(u8, full_schema);
    var compiled = compile(testing.allocator, copy) catch |err| {
        testing.allocator.free(copy);
        return err;
    };
    defer compiled.deinit();
    @memset(copy, ' ');
    testing.allocator.free(copy);
    try testing.expectEqual(ValidateResult.ok, try validate(testing.allocator, &compiled, "{\"name\":\"a\",\"count\":1,\"kind\":\"b\"}", 64));
}

test "validate accepts a bounded input the schema admits" {
    const input =
        \\{"name":"ab","kind":"a","email":"a@b.co","when":"2026-09-23T10:00:00Z",
        \\ "score":1.5,"count":3,"flag":true,"tags":["x","\u00e9"],"nested":{"x":-2}}
    ;
    try testing.expectEqual(ValidateResult.ok, try validateBytes(full_schema, input, input.len));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(full_schema, "  {\"count\":2,\"name\":\"z\"}\n", 64));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(deep_schema, nestInput(8, "\"q\""), 128));
}

test "validate refuses each defect with its reason and offset" {
    for (validate_cases) |case| {
        const result = try validateBytes(case.schema, case.input, case.max_bytes);
        expectRefused(result, case.reason, case.offset) catch |err| {
            std.debug.print("input {s}\n", .{case.input});
            return err;
        };
    }
}

test "validate refuses a duplicate key at the root and nested before scanning its value" {
    try expectRefused(try validateBytes(full_schema, "{\"count\":1,\"count\":1}", 64), .duplicate_key, 11);
    try expectRefused(try validateBytes(full_schema, "{\"name\":\"a\",\"count\":1,\"nested\":{\"x\":1,\"x\":1}}", 64), .duplicate_key, 38);
    // The second value is malformed; the refusal is still the duplicate.
    try expectRefused(try validateBytes(full_schema, "{\"count\":1,\"count\":tru", 64), .duplicate_key, 11);
    try expectRefused(try validateBytes(full_schema, "{\"count\":1,\"count\":\"\xff", 64), .duplicate_key, 11);
}

test "validate refuses an unknown key at the root and nested before scanning its value" {
    try expectRefused(try validateBytes(full_schema, "{\"count\":1,\"name\":\"a\",\"extra\":true}", 64), .unknown_field, 22);
    try expectRefused(try validateBytes(full_schema, "{\"name\":\"a\",\"count\":1,\"nested\":{\"y\":1}}", 64), .unknown_field, 32);
    // The unknown key's value is malformed; the refusal is still the unknown key.
    try expectRefused(try validateBytes(full_schema, "{\"count\":1,\"extra\":tru", 64), .unknown_field, 11);
}

test "validate counts string length in Unicode scalar values" {
    const schema = rootWith("\"s\":" ++ str1);
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"s\":\"\xc3\xa9\"}", 64));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"s\":\"\\u00e9\"}", 64));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"s\":\"\xf0\x9f\x98\x80\"}", 64));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"s\":\"\\ud83d\\ude00\"}", 64));
    try expectRefused(try validateBytes(schema, "{\"s\":\"\\ud83d\\ude00\\ud83d\\ude00\"}", 64), .string_too_long, 5);
    try expectRefused(try validateBytes(schema, "{\"s\":\"\xc3\xa9e\"}", 64), .string_too_long, 5);
}

test "validate treats an integer as a finite whole number" {
    const schema = rootWith("\"n\":{\"type\":\"integer\"}");
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"n\":2.0}", 64));
    try testing.expectEqual(ValidateResult.ok, try validateBytes(schema, "{\"n\":-1e3}", 64));
    try expectRefused(try validateBytes(schema, "{\"n\":1e-1}", 64), .not_integer, 5);
    try expectRefused(try validateBytes(schema, "{\"n\":-1e999}", 64), .not_finite, 5);
}

test "validate verdicts survive a recompile of the same schema bytes" {
    const corpus = [_][]const u8{
        "{\"name\":\"a\",\"count\":1}",
        "{\"name\":\"a\",\"count\":1,\"tags\":[\"x\"],\"nested\":{\"x\":3}}",
        "{\"name\":\"a\",\"count\":1,\"name\":\"b\"}",
        "{\"name\":\"a\",\"count\":1,\"extra\":true}",
        "{\"name\":\"a\"}",
        "{\"name\":\"abcdefghij\",\"count\":1}",
        "{\"name\":\"a\",\"count\":1,\"score\":1e400}",
        "{\"name\":\"a\",\"count\":1,\"email\":\"x@y\"}",
        "{\"name\":\"a\",\"count\":2} trailing",
        "{\"name\":",
    };
    var first = try compile(testing.allocator, full_schema);
    defer first.deinit();
    var first_verdicts: [corpus.len]ValidateResult = undefined;
    for (corpus, 0..) |input, i| first_verdicts[i] = try validate(testing.allocator, &first, input, 1024);

    var second = try compile(testing.allocator, full_schema);
    defer second.deinit();
    for (corpus, 0..) |input, i| {
        try testing.expectEqualDeep(first_verdicts[i], try validate(testing.allocator, &second, input, 1024));
    }
    // The corpus is not vacuous: it holds both verdicts.
    try testing.expectEqual(ValidateResult.ok, first_verdicts[0]);
    try testing.expect(first_verdicts[2] == .refused);
}

test "every refusal member is driven by a case that observes it" {
    for (std.meta.tags(SubsetRefusal)) |tag| {
        var found = false;
        for (subset_cases) |case| {
            if (case.reason == tag) found = true;
        }
        if (!found) {
            std.debug.print("SubsetRefusal.{s} has no case\n", .{@tagName(tag)});
            return error.TestCensusGap;
        }
    }
    for (std.meta.tags(ValidateRefusal)) |tag| {
        var found = false;
        for (validate_cases) |case| {
            if (case.reason == tag) found = true;
        }
        if (!found) {
            std.debug.print("ValidateRefusal.{s} has no case\n", .{@tagName(tag)});
            return error.TestCensusGap;
        }
    }
}

fn checkSubsetUnderFailure(allocator: Allocator, schema: []const u8) !void {
    const result = try checkSubset(allocator, schema);
    result.deinit(allocator);
}

fn compileAndValidateUnderFailure(allocator: Allocator, schema: []const u8, input: []const u8) !void {
    var compiled = try compile(allocator, schema);
    defer compiled.deinit();
    _ = try validate(allocator, &compiled, input, 1024);
}

test "allocation failure is an error and never a verdict" {
    try testing.checkAllAllocationFailures(testing.allocator, checkSubsetUnderFailure, .{full_schema});
    try testing.checkAllAllocationFailures(testing.allocator, checkSubsetUnderFailure, .{rootWith("\"a\":{\"type\":\"string\",\"maxLength\":1,\"enum\":[\"x\",\"x\"]}")});
    try testing.checkAllAllocationFailures(testing.allocator, compileAndValidateUnderFailure, .{
        full_schema,
        "{\"name\":\"\\u00e9\",\"count\":1,\"tags\":[\"x\"]}",
    });
}

fn canonicalBytes(allocator: Allocator, schema: []const u8) ![]u8 {
    var compiled = try compile(allocator, schema);
    defer compiled.deinit();
    return canonicalize(allocator, &compiled);
}

test "canonicalize writes the documented key order and sorted sets" {
    const canonical = try canonicalBytes(testing.allocator, full_schema);
    defer testing.allocator.free(canonical);
    const expected =
        \\{"type":"object","title":"order","description":"one order","additionalProperties":false,"properties":{
    ++
        \\"count":{"type":"integer","minimum":0,"maximum":10,"enum":[1,2,3]},
    ++
        \\"email":{"type":"string","maxLength":64,"format":"email"},
    ++
        \\"flag":{"type":"boolean","description":"on or off"},
    ++
        \\"kind":{"type":"string","maxLength":10,"enum":["a","b"]},
    ++
        \\"name":{"type":"string","minLength":1,"maxLength":8},
    ++
        \\"nested":{"type":"object","additionalProperties":false,"properties":{"x":{"type":"integer"}},"required":[]},
    ++
        \\"score":{"type":"number","minimum":0,"maximum":1.5},
    ++
        \\"tags":{"type":"array","items":{"type":"string","maxLength":4},"maxItems":3,"minItems":1},
    ++
        \\"when":{"type":"string","maxLength":40,"format":"iso-datetime"}
    ++
        \\},"required":["count","name"]}
    ;
    try testing.expectEqualStrings(expected, canonical);
}

test "canonicalize is a fixed point and survives checkSubset" {
    const once = try canonicalBytes(testing.allocator, full_schema);
    defer testing.allocator.free(once);
    const verdict = try checkSubset(testing.allocator, once);
    defer verdict.deinit(testing.allocator);
    try testing.expectEqual(SubsetResult.ok, verdict);
    const twice = try canonicalBytes(testing.allocator, once);
    defer testing.allocator.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "authored whitespace, key order, and set order do not move the canonical bytes" {
    const a =
        \\{"type":"object","additionalProperties":false,"required":["b","a"],
        \\ "properties":{"b":{"maxLength":3,"type":"string","enum":["y","x"]},"a":{"type":"number","enum":[2,1.0,-3],"minimum":-3}}}
    ;
    const b =
        \\{ "properties" : { "a" : { "minimum" : -3.0, "enum" : [ -3, 1, 2 ], "type" : "number" },
        \\   "b" : { "enum" : [ "x", "y" ], "type" : "string", "maxLength" : 3, "minLength" : 0 } },
        \\  "required" : [ "a", "b" ], "type" : "object", "additionalProperties" : false }
    ;
    const ca = try canonicalBytes(testing.allocator, a);
    defer testing.allocator.free(ca);
    const cb = try canonicalBytes(testing.allocator, b);
    defer testing.allocator.free(cb);
    try testing.expectEqualStrings(ca, cb);
    try testing.expectEqualStrings(
        \\{"type":"object","additionalProperties":false,"properties":{"a":{"type":"number","minimum":-3,"enum":[-3,1,2]},"b":{"type":"string","maxLength":3,"enum":["x","y"]}},"required":["a","b"]}
    , ca);
}

test "canonicalize escapes strings and keeps non-ASCII bytes" {
    const schema =
        \\{"type":"object","additionalProperties":false,"description":"caf\u00e9 \"q\" \\ \t\u0001",
        \\ "properties":{"a\"b":{"type":"string","maxLength":1}}}
    ;
    const canonical = try canonicalBytes(testing.allocator, schema);
    defer testing.allocator.free(canonical);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"description\":\"caf\xc3\xa9 \\\"q\\\" \\\\ \\t\\u0001\",\"additionalProperties\":false,\"properties\":{\"a\\\"b\":{\"type\":\"string\",\"maxLength\":1}},\"required\":[]}",
        canonical,
    );
    const again = try canonicalBytes(testing.allocator, canonical);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(canonical, again);
}

test "the canonical schema gives the same verdicts as the authored one" {
    const canonical = try canonicalBytes(testing.allocator, full_schema);
    defer testing.allocator.free(canonical);
    var authored = try compile(testing.allocator, full_schema);
    defer authored.deinit();
    var reread = try compile(testing.allocator, canonical);
    defer reread.deinit();
    var accepted: usize = 0;
    for (validate_cases) |case| {
        if (!std.mem.eql(u8, case.schema, full_schema)) continue;
        const want = try validate(testing.allocator, &authored, case.input, case.max_bytes);
        const got = try validate(testing.allocator, &reread, case.input, case.max_bytes);
        try testing.expectEqualDeep(want, got);
    }
    const good = "{\"name\":\"a\",\"count\":1,\"tags\":[\"x\"],\"nested\":{\"x\":1}}";
    const want = try validate(testing.allocator, &authored, good, 1024);
    try testing.expectEqualDeep(want, try validate(testing.allocator, &reread, good, 1024));
    if (want == .ok) accepted += 1;
    // Floor: the comparison covered an accepted input, not only refusals.
    try testing.expectEqual(@as(usize, 1), accepted);
}

test "canonicalize under allocation failure is an error, never partial bytes" {
    try testing.checkAllAllocationFailures(testing.allocator, canonicalUnderFailure, .{full_schema});
}

fn canonicalUnderFailure(allocator: Allocator, schema: []const u8) !void {
    const bytes = try canonicalBytes(allocator, schema);
    allocator.free(bytes);
}
